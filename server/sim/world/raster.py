"""server.sim.world.raster — the world-raster decode + lookup layer (M1).

Python port of the Godot decode half of ``scripts/world/map_loader.gd`` and
``scripts/world/ocean_layers.gd`` (the frozen parity oracle until the M6
cutover). DECODE + LOOKUP only: no rendering, no TileMaps, no scene code —
the Godot chunk/overlay/shore-art half of those files (§9 steps 4–6, §9.2,
§6.6 shore raster) is render-side and retires at M6 with the runtime tree.

Normative sources:
  * docs/90-ARCHITECTURE.md §9 / §9.1 — the loading pipeline and the
    harbor-pair contract (the runtime READS ``data/maps/harbors.json``,
    the builder's persisted §6.1 snap output; it never re-snaps lat/lon).
  * docs/10-DATA-SCHEMA.md §6.1–§6.7 — the locked grid constants, the tile
    legend, the four tool-owned rasters and their palette/RGB encodings,
    §4.16/§4.17/§4.18 wind/current/ice semantics via §6.5.
  * Oracle files: ``scripts/world/map_loader.gd`` (world.png decode,
    passability, harbor table), ``scripts/world/ocean_layers.gd`` (wind +
    currents decode, reversal flip at lookup, ice polygons).

Contracts ported verbatim:
  * ``WorldRaster`` — indexed-PNG decode of ``data/maps/world.png``
    (§6.3: colour type 3, 8-bit, non-interlaced, 4320×2160, palette
    indices ⊆ 0–4 = ``~ . # ^ I``), O(1) ``is_passable`` wrap-aware on x
    (x mod 4320), false for y out of range and for the ``#``/``^``/``I``
    indices; harbor pairs read from ``data/maps/harbors.json``
    (``port_cell`` = berth, ``shore_cell`` = shore, §9.1).
  * ``OceanLayers`` — ``wind_regions.png`` (index = region id, 0 = the
    ``VAR`` fallback, §6.5) and ``currents.png`` (index 0 = none,
    1–24 = ``dir_index × 3 + strength`` over the compass order
    ``N NE E SE S SW W NW``). The reversal flip is applied AT LOOKUP TIME
    (§6.5 "Reversal at lookup"): the raster stores the non-summer regime,
    so a tile's stored vector flips when the owning system's
    ``reversal.summer_months`` covers the query month. Membership for that
    check is rebuilt once at load — the ``tools/build_ocean.py``
    ``chain_between`` + Chebyshev-dilation corridor geometry ported from
    ``ocean_layers.gd`` — and flips only when the decoded strength equals
    the owning system's (a tile a stronger system won is never flipped).
  * ``DistLand`` — ``dist_land.png`` RGB8 decode (§6.7):
    ``enc = round(min(d,16)/16*65535)``, ``R = enc >> 8``, ``G = enc & 255``;
    decode ``d = (R*256+G)/4096`` tiles, saturated at 16.
  * Seasonal sea ice (§4.18) — NOT rasterized: the runtime polygon check
    with a month-keyed tile cache (even-odd scanline at tile centres,
    longitudes unwrapped across the antimeridian), exactly like
    ``ocean_layers.gd``.

Skipped as render-side (retire at M6): the 128×128 chunk TileMaps, the
port overlay nodes, ``world_shore.png`` codes (§6.6), the terrain-variant
cell hash, the wang coast tiles, and the water shader. The no-corner-cut
movement rule (§4.2) lives in the movement code, not in this layer.

Failure semantics: the shipped rasters are validator-gated (groups 6/9/13),
so any artifact violation raises :class:`RasterError` at construction —
the Python equivalent of the MapLoader startup error (§11), not a silent
degraded state. Decoded state is session-only and never saved (§6.5).

Singletons mirror the Godot autoload roles: :func:`raster` is the
``DataLoader.map`` equivalent, :func:`ocean_layers` the
``OceanLayers.instance()`` equivalent, :func:`dist_land` the raw-bytes
DATA-ARTIFACT pattern of ``dist_land.png`` (§6.7). Each decodes once per
process; :func:`reset_singletons` is the test seam.
"""

from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

# --- Locked constants (docs/10-DATA-SCHEMA.md §6.1–§6.7) --------------------

#: §6.1: the single world grid, 4320 × 2160 tiles at 12 tiles/degree.
GRID_WIDTH = 4320
GRID_HEIGHT = 2160

#: §6.3: palette index 0–4 = ``~ . # ^ I``, in that locked order (append-only).
PALETTE_CHARS = "~.#^I"

#: §6.2: only ``~`` (index 0) and ``.`` (index 1) are passable.
PASSABLE_INDICES = (0, 1)

#: §6.2/§6.3: palette index 2 = ``#`` — the only tile a shore tile may be.
LAND_INDEX = 2

#: §6.5 compass order of both ocean rasters' encodings (dir_index 0..7).
#: y grows southward, so ``N`` is (0, −1).
COMPASS_DIRS = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")

#: Unit flow vectors per compass index (tile space, diagonals normalized;
#: literal constants — the ``ocean_layers.gd`` COMPASS_VECTORS verbatim).
COMPASS_VECTORS = (
    (0.0, -1.0), (0.7071067811865476, -0.7071067811865476),
    (1.0, 0.0), (0.7071067811865476, 0.7071067811865476),
    (0.0, 1.0), (-0.7071067811865476, 0.7071067811865476),
    (-1.0, 0.0), (-0.7071067811865476, -0.7071067811865476),
)

#: The 8-compass opposite of every direction — the reversal flip, one
#: lookup (``N↔S``, ``NE↔SW``, ``E↔W``, ``SE↔NW``).
COMPASS_OPPOSITE = ("S", "SW", "W", "NW", "N", "NE", "E", "SE")

#: §4.14 direction tokens: the 8 compass directions plus ``VAR``.
WIND_TOKENS = ("N", "NE", "E", "SE", "S", "SW", "W", "NW", "VAR")

#: §6.5 palette bounds: wind index ≤ region count (the shipped cap is 25
#: regions), current index ≤ 24 (8 dirs × 3 strengths).
MAX_WIND_REGIONS = 25
MAX_CURRENT_INDEX = 24

#: §6.7 land-distance encode: saturated at 16 tiles, 16-bit across R/G.
DIST_LAND_SATURATION_TILES = 16


class RasterError(RuntimeError):
    """A world-raster artifact violates its §6.x contract (startup error)."""


# --- Minimal stdlib PNG decode (zlib + struct) ------------------------------
#
# Same reader pattern as ``tools/validate_data.py`` ``decode_indexed_png``
# (chunk walk with CRC, IHDR checks, all five filter types reversed
# defensively), extended to RGB8 (colour type 2) for ``dist_land.png``
# (§6.7). The builder tools write filter 0, so the shipped artifacts take
# the memcpy path; filters 1–4 stay supported so a hand-rebuilt artifact
# cannot silently misread.


class PngFormatError(RasterError):
    """A structural problem with a PNG artifact."""


_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _unfilter_scanlines(raw: bytes, width: int, height: int,
                        bpp: int) -> bytearray:
    """Reverse PNG filter types 0–4 for an 8-bit-per-channel image."""
    stride = width * bpp
    if len(raw) != (stride + 1) * height:
        raise PngFormatError(
            f"IDAT inflates to {len(raw)} bytes, expected {(stride + 1) * height} "
            f"for {width}x{height} at {bpp} byte(s) per pixel"
        )
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filter_type == 0:  # None
            pass
        elif filter_type == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = prev[i]
                up_left = prev[i - bpp] if i >= bpp else 0
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = up_left
                line[i] = (line[i] + predictor) & 0xFF
        else:
            raise PngFormatError(
                f"row {y} uses undefined PNG filter type {filter_type} (0-4 defined)"
            )
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def _decode_png(data: bytes, colour_type: int, label: str,
                require_palette: bool) -> tuple[int, int, bytearray, bytes]:
    """Decode one 8-bit non-interlaced PNG; return (w, h, pixels, palette).

    ``pixels`` holds raw channel bytes row-major (1 byte per pixel for
    colour type 3, 3 bytes for colour type 2). Every structural problem
    raises :class:`PngFormatError`.
    """
    if not data.startswith(_PNG_SIGNATURE):
        raise PngFormatError(f"{label}: not a PNG (bad signature)")
    total = len(data)
    pos = len(_PNG_SIGNATURE)
    header = None
    palette = b""
    idat = bytearray()
    saw_iend = False
    while pos < total:
        if pos + 8 > total:
            raise PngFormatError(f"{label}: truncated chunk header")
        chunk_length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        if pos + 12 + chunk_length > total:
            raise PngFormatError(f"{label}: truncated {tag!r} chunk")
        payload = data[pos + 8:pos + 8 + chunk_length]
        crc = struct.unpack(">I",
                            data[pos + 8 + chunk_length:pos + 12 + chunk_length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise PngFormatError(f"{label}: bad CRC in chunk {tag!r}")
        pos += 12 + chunk_length
        if tag == b"IHDR":
            if chunk_length != 13:
                raise PngFormatError(
                    f"{label}: IHDR chunk is {chunk_length} bytes, expected 13")
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            saw_iend = True
            break
    if header is None:
        raise PngFormatError(f"{label}: no IHDR chunk")
    if not saw_iend:
        raise PngFormatError(f"{label}: no IEND chunk (truncated file)")
    width, height, depth, colour, compression, filter_method, interlace = header
    if colour != colour_type:
        raise PngFormatError(
            f"{label}: IHDR colour type {colour}, expected {colour_type} "
            f"(§6.3/§6.5/§6.7 artifact contract)"
        )
    if depth != 8:
        raise PngFormatError(f"{label}: bit depth is {depth}, expected 8")
    if compression != 0 or filter_method != 0:
        raise PngFormatError(
            f"{label}: unsupported PNG compression/filter method "
            f"{compression}/{filter_method}"
        )
    if interlace != 0:
        raise PngFormatError(f"{label}: interlaced PNG not supported")
    if require_palette and not palette:
        raise PngFormatError(
            f"{label}: no PLTE chunk (an indexed PNG needs a palette)")
    if width == 0 or height == 0:
        raise PngFormatError(f"{label}: zero image dimension {width}x{height}")
    if not idat:
        raise PngFormatError(f"{label}: no IDAT chunk (image data is empty)")
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as exc:
        raise PngFormatError(
            f"{label}: IDAT stream does not inflate: {exc}") from exc
    bpp = 1 if colour_type == 3 else 3
    pixels = _unfilter_scanlines(raw, width, height, bpp)
    if colour_type == 3:
        palette_entries = len(palette) // 3
        highest = max(pixels)
        if highest >= palette_entries:
            raise PngFormatError(
                f"{label}: palette index {highest} is used but PLTE holds only "
                f"{palette_entries} entries"
            )
    return width, height, pixels, palette


def decode_indexed_png(data: bytes, label: str) -> tuple[int, int, bytearray]:
    """Decode an 8-bit indexed PNG (colour type 3); return (w, h, indices)."""
    width, height, pixels, _palette = _decode_png(
        data, 3, label, require_palette=True)
    return width, height, pixels


def decode_rgb8_png(data: bytes, label: str) -> tuple[int, int, bytearray]:
    """Decode an 8-bit truecolour PNG (colour type 2); return (w, h, rgb)."""
    width, height, pixels, _palette = _decode_png(
        data, 2, label, require_palette=False)
    return width, height, pixels


# --- Data-root resolution ---------------------------------------------------

#: ``server/sim/world/raster.py`` → parents[3] is the repo root; ``data/``
#: and every raster path below live there (90-ARCHITECTURE.md §0.2 layout).
REPO_ROOT = Path(__file__).resolve().parents[3]

WORLD_PNG = "data/maps/world.png"
WIND_PNG = "data/maps/wind_regions.png"
CURRENTS_PNG = "data/maps/currents.png"
DIST_LAND_PNG = "data/maps/dist_land.png"
HARBORS_JSON = "data/maps/harbors.json"
MAPS_JSON = "data/maps/maps.json"
MAP_LEGEND_JSON = "data/map_legend.json"
WIND_REGIONS_JSON = "data/wind_regions.json"
OCEAN_CURRENTS_JSON = "data/ocean_currents.json"
ICE_REGIONS_JSON = "data/ice_regions.json"


def _load_json(path: Path, label: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RasterError(f"{label}: cannot read {path}: {exc}") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise RasterError(f"{label}: {path} is not valid JSON: {exc}") from exc


def _read_bytes(path: Path, label: str) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise RasterError(f"{label}: cannot read {path}: {exc}") from exc
    if not data:
        raise RasterError(f"{label}: {path} is empty")
    return data


# --- Shared helpers ---------------------------------------------------------

def tile_of_latlon(lat: float, lon: float) -> tuple[int, int]:
    """Grid cell containing a WGS84 point (§6.1): ``x = floor((lon+180)·12)``
    mod the width, ``y = floor((90−lat)·12)`` clamped — the same projection
    as ``tools/build_world.py`` / the oracle loaders."""
    tpd = GRID_WIDTH / 360.0
    x = int(math.floor((lon + 180.0) * tpd)) % GRID_WIDTH
    y = min(max(int(math.floor((90.0 - lat) * tpd)), 0), GRID_HEIGHT - 1)
    return x, y


def chebyshev_wrap(ax: int, ay: int, bx: int, by: int) -> int:
    """Chebyshev distance with longitude wrap (§6.1):
    ``min(|dx|, width − |dx|)`` on the x axis."""
    dx = abs(ax - bx) % GRID_WIDTH
    return max(min(dx, GRID_WIDTH - dx), abs(ay - by))


# --- World raster (world.png + the harbor-pair table) -----------------------


class WorldRaster:
    """Decoded ``data/maps/world.png`` + the persisted harbor-pair table.

    The oracle is ``map_loader.gd``'s decode half (§9 steps 1–3 and step 5's
    table read): passability is a byte lookup on one palette index per tile,
    wrap-aware on x, closed at the latitude edges; ``port_cell``/``shore_cell``
    read ``data/maps/harbors.json`` (the builder's §6.1 snap output) and never
    re-snap lat/lon (§9.1 harbor-pair contract, unified-movement amendment).
    """

    def __init__(self, data_root: Path | None = None) -> None:
        root = data_root if data_root is not None else REPO_ROOT
        legend = self._load_legend(root)
        width, height, indices = decode_indexed_png(
            _read_bytes(root / WORLD_PNG, "world.png"), "data/maps/world.png")
        if width != legend[0] or height != legend[1]:
            raise RasterError(
                f"data/maps/world.png is {width}x{height} pixels, the locked "
                f"legend grid is {legend[0]}x{legend[1]} (§6.3)"
            )
        if width != GRID_WIDTH or height != GRID_HEIGHT:
            raise RasterError(
                f"data/maps/world.png is {width}x{height} pixels, the locked "
                f"grid is {GRID_WIDTH}x{GRID_HEIGHT} (§6.1)"
            )
        highest = max(indices)
        if highest > len(PALETTE_CHARS) - 1:
            offset = indices.index(highest)
            raise RasterError(
                f"data/maps/world.png: palette index {highest} at tile "
                f"({offset % width}, {offset // width}) is outside the locked "
                f"0-4 set (~ . # ^ I, §6.3)"
            )
        self.width = width
        self.height = height
        #: One palette index per tile, row-major (§9 step 3).
        self.indices = indices
        #: Normalized legend tiles: ``char -> {"kind", "passable"}``.
        self.legend_tiles = legend[2]
        self._harbors: dict[str, tuple[int, int]] = {}
        self._shores: dict[str, tuple[int, int]] = {}
        self._port_at: dict[tuple[int, int], str] | None = None
        self._shore_at: dict[tuple[int, int], str] | None = None
        self._load_harbors(root)

    def _load_legend(self, root: Path
                     ) -> tuple[int, int, dict[str, dict[str, object]]]:
        """Resolve the single map index (§9.1) → (width, height, tiles)."""
        maps = _load_json(root / MAPS_JSON, "maps.json")
        if not isinstance(maps, dict) or not isinstance(maps.get("maps"), list):
            raise RasterError("maps.json: missing the 'maps' array")
        entry = None
        for candidate in maps["maps"]:
            if isinstance(candidate, dict) and candidate.get("id") == "world":
                entry = candidate
                break
        if entry is None:
            raise RasterError("maps.json: no 'world' entry (§9.1: exactly one)")
        legend = _load_json(root / MAP_LEGEND_JSON, "map_legend.json")
        if not isinstance(legend, dict) or not isinstance(legend.get("grid"), dict):
            raise RasterError("map_legend.json: missing the 'grid' object")
        grid = legend["grid"]
        width = int(grid.get("width", 0))
        height = int(grid.get("height", 0))
        if width <= 0 or height <= 0:
            raise RasterError("map_legend.json: grid.width/height must be positive")
        tiles_raw = legend.get("tiles")
        if not isinstance(tiles_raw, dict) or not tiles_raw:
            raise RasterError("map_legend.json: missing the 'tiles' table")
        tiles: dict[str, dict[str, object]] = {}
        for ch, raw in tiles_raw.items():
            if isinstance(raw, dict):
                tiles[str(ch)] = {
                    "kind": str(raw.get("kind", "")),
                    "passable": raw.get("passable") is True,
                }
        for index, ch in enumerate(PALETTE_CHARS):
            if ch not in tiles:
                raise RasterError(
                    f"map_legend.json: tiles has no {ch!r} entry "
                    f"(palette index {index}, §6.3)"
                )
        return width, height, tiles

    def _load_harbors(self, root: Path) -> None:
        """Read the persisted harbor-pair table (§9.1). Every REAL port comes
        from this build output; the oracle's synthetic-fixture re-snap
        fallback (``ports_override``) has no Python counterpart yet."""
        parsed = _load_json(root / HARBORS_JSON, "harbors.json")
        if not isinstance(parsed, dict) or not isinstance(parsed.get("harbors"), list):
            raise RasterError("harbors.json: missing the 'harbors' array")
        for entry in parsed["harbors"]:
            if not isinstance(entry, dict):
                continue
            port_id = str(entry.get("id", ""))
            berth = entry.get("berth")
            shore = entry.get("shore")
            if not (isinstance(berth, list) and len(berth) == 2):
                continue
            self._harbors[port_id] = (int(berth[0]), int(berth[1]))
            if isinstance(shore, list) and len(shore) == 2:
                self._shores[port_id] = (int(shore[0]), int(shore[1]))

    # -- Grid queries (§9 step 3) --------------------------------------------

    def index_at(self, x: int, y: int) -> int:
        """Palette index at (x, y) — x wraps, y bounded; -1 out of bounds."""
        if y < 0 or y >= self.height or self.width <= 0:
            return -1
        return self.indices[y * self.width + x % self.width]

    def char_at(self, x: int, y: int) -> str:
        """Legend character at (x, y) (``~`` ``.`` ``#`` ``^`` ``I``), or ""."""
        value = self.index_at(x, y)
        if value < 0:
            return ""
        return PALETTE_CHARS[value]

    def is_passable(self, x: int, y: int) -> bool:
        """True when a fleet may enter (§4.1): x wraps, y must be on the
        grid, and the palette index must be ``~`` or ``.`` (§6.2)."""
        value = self.index_at(x, y)
        return 0 <= value <= 1

    def terrain_kind(self, x: int, y: int) -> str:
        """Legend ``kind`` string at (x, y), or "" out of bounds."""
        ch = self.char_at(x, y)
        definition = self.legend_tiles.get(ch)
        if isinstance(definition, dict):
            kind = definition.get("kind", "")
            if isinstance(kind, str):
                return kind
        return ""

    # -- Harbor pair (§9 step 5, §9.1) ---------------------------------------

    def harbor_tiles(self) -> dict[str, tuple[int, int]]:
        """``{port_id: (x, y)}`` berth tiles — the water tile the fleet stands on."""
        return dict(self._harbors)

    def shore_tiles(self) -> dict[str, tuple[int, int]]:
        """``{port_id: (x, y)}`` shore tiles — the ``#`` tile the port is drawn
        on and docked into (§4.11.1)."""
        return dict(self._shores)

    def port_cell(self, port_id: str) -> tuple[int, int]:
        """Berth tile of ``port_id``, or ``(-1, -1)`` when the id has none.
        Unchanged meaning: ``port_cell`` is the berth."""
        return self._harbors.get(port_id, (-1, -1))

    def shore_cell(self, port_id: str) -> tuple[int, int]:
        """Shore tile of ``port_id``, or ``(-1, -1)`` when the id has none."""
        return self._shores.get(port_id, (-1, -1))

    def port_id_at(self, x: int, y: int) -> str:
        """Port id whose berth tile is (x, y) (x wraps), or "" when none."""
        if y < 0 or y >= self.height:
            return ""
        if self._port_at is None:
            self._port_at = self._tile_index(self._harbors)
        return self._port_at.get((x % self.width, y), "")

    def shore_port_at(self, x: int, y: int) -> str:
        """Port id whose shore tile is (x, y) (x wraps), or "" — the docking
        lookup of §4.11.1."""
        if y < 0 or y >= self.height:
            return ""
        if self._shore_at is None:
            self._shore_at = self._tile_index(self._shores)
        return self._shore_at.get((x % self.width, y), "")

    @staticmethod
    def _tile_index(tiles: dict[str, tuple[int, int]]
                    ) -> dict[tuple[int, int], str]:
        """``{(x, y): port_id}`` inverse; first id wins a duplicate cell."""
        index: dict[tuple[int, int], str] = {}
        for port_id, (x, y) in tiles.items():
            index.setdefault((x, y), port_id)
        return index


# --- Ocean layers (wind + currents + reversal + ice, §6.5/§4.18) ------------


class OceanLayers:
    """Decoded ``wind_regions.png`` + ``currents.png`` + the §4.18 ice check.

    The oracle is ``ocean_layers.gd`` (the single owner of every ocean
    lookup). The reversal flip is applied at lookup time (§6.5 "Reversal at
    lookup"): the raster stores each system's stored (non-flipped, non-summer)
    vector, so ``current_at`` flips the stored direction to its 8-compass
    opposite exactly when the query month is inside the owning system's
    ``reversal.summer_months`` AND the decoded strength equals that system's
    strength. Membership comes from rebuilding the builder's corridor
    geometry once at load (the ``chain_between`` + Chebyshev-dilation port).
    """

    def __init__(self, data_root: Path | None = None) -> None:
        root = data_root if data_root is not None else REPO_ROOT
        self._wind_regions = self._load_regions(
            root, WIND_REGIONS_JSON, "wind_regions")
        self._currents_systems = self._load_regions(
            root, OCEAN_CURRENTS_JSON, "ocean_currents")
        self._ice_regions = self._load_regions(
            root, ICE_REGIONS_JSON, "ice_regions")
        self.width = GRID_WIDTH
        self.height = GRID_HEIGHT
        self._wind_indices = self._decode_raster(
            root, WIND_PNG, "data/maps/wind_regions.png", MAX_WIND_REGIONS)
        self._current_indices = self._decode_raster(
            root, CURRENTS_PNG, "data/maps/currents.png", MAX_CURRENT_INDEX)
        #: ``(x, y) -> (strength, summer_months)`` for every tile of every
        #: system carrying a ``reversal`` block (built once at load).
        self._reversal_members: dict[tuple[int, int], tuple[int, list[int]]] = {}
        self._build_reversal_index()
        #: §4.18 month-keyed tile caches, built lazily + memoized.
        self._ice_masks: dict[int, set[tuple[int, int]]] = {}

    @staticmethod
    def _load_regions(root: Path, rel: str, key: str) -> list[dict]:
        parsed = _load_json(root / rel, key)
        if not isinstance(parsed, dict) or not isinstance(parsed.get(key), list):
            raise RasterError(f"{rel}: missing the {key!r} array")
        return [entry for entry in parsed[key] if isinstance(entry, dict)]

    @staticmethod
    def _decode_raster(root: Path, rel: str, label: str,
                       max_index: int) -> bytearray:
        width, height, indices = decode_indexed_png(
            _read_bytes(root / rel, label), label)
        if width != GRID_WIDTH or height != GRID_HEIGHT:
            raise RasterError(
                f"{label} is {width}x{height}, the locked grid is "
                f"{GRID_WIDTH}x{GRID_HEIGHT} (§6.5)"
            )
        highest = max(indices)
        if highest > max_index:
            offset = indices.index(highest)
            raise RasterError(
                f"{label}: palette index {highest} at tile "
                f"({offset % width}, {offset // width}) is above the §6.5 "
                f"bound {max_index}"
            )
        return indices

    # -- Wind (§4.14/§4.16 via §6.5) ------------------------------------------

    def wind_region_at(self, x: int, y: int) -> int:
        """Wind-region id at (x, y) (1..N, ``data/wind_regions.json`` file
        order), 0 for unassigned water / off-grid — the ``VAR`` fallback."""
        if y < 0 or y >= GRID_HEIGHT:
            return 0
        return self._wind_indices[y * GRID_WIDTH + x % GRID_WIDTH]

    def prevailing_for(self, x: int, y: int, month: int) -> str:
        """Prevailing wind-FROM token at (x, y) in ``month`` (1..12), per the
        region's month table. Index 0 / uncovered water / an unknown month /
        a token outside §4.14's set → ``"VAR"`` (draws uniformly over the 8
        compass directions; the roll itself lives in the sailing sim)."""
        region_id = self.wind_region_at(x, y)
        if region_id <= 0 or region_id > len(self._wind_regions):
            return "VAR"
        if month < 1 or month > 12:
            return "VAR"
        region = self._wind_regions[region_id - 1]
        months = region.get("months")
        token = months.get(str(month), "") if isinstance(months, dict) else ""
        return token if token in WIND_TOKENS else "VAR"

    # -- Currents (§4.17 via §6.5) ---------------------------------------------

    def current_at(self, x: int, y: int,
                   month: int = -1) -> dict[str, object] | None:
        """Decoded current at (x, y): ``{"dir": "N".."NW", "strength": 1..3}``
        keyed by the §6.5 encoding, or ``None`` on no current / off-grid.
        The reversal flip is applied here when ``month`` falls in the owning
        system's ``reversal.summer_months``; pass ``month <= 0`` to read the
        raw stored (non-flipped) vector — gameplay always passes the real
        month."""
        if y < 0 or y >= GRID_HEIGHT:
            return None
        index = self._current_indices[y * GRID_WIDTH + x % GRID_WIDTH]
        if index <= 0 or index > MAX_CURRENT_INDEX:
            return None
        dir_index = (index - 1) // 3
        strength = (index - 1) % 3 + 1
        dir_name = COMPASS_DIRS[dir_index]
        if 1 <= month <= 12:
            member = self._reversal_members.get((x % GRID_WIDTH, y))
            if member is not None and member[0] == strength \
                    and month in member[1]:
                dir_name = COMPASS_OPPOSITE[dir_index]
        return {"dir": dir_name, "strength": strength}

    def current_vector_at(self, x: int, y: int,
                          month: int = -1) -> tuple[float, float]:
        """Flow of the current at (x, y): the unit compass vector scaled by
        the strength (magnitude 1..3, downstream, reversal applied). The
        per-strength daily drift table lives in the sailing sim (§4.16)."""
        current = self.current_at(x, y, month)
        if current is None:
            return (0.0, 0.0)
        dir_index = COMPASS_DIRS.index(str(current["dir"]))
        vx, vy = COMPASS_VECTORS[dir_index]
        scale = float(int(current["strength"]))  # type: ignore[arg-type]
        return (vx * scale, vy * scale)

    # -- Seasonal sea ice (§4.18) -----------------------------------------------

    def ice_active(self, month: int) -> bool:
        """True when at least one ice region is active in ``month`` (1..12)."""
        return bool(self.ice_active_regions(month))

    def ice_active_regions(self, month: int) -> list[str]:
        """Ids of the ice regions whose ``months`` window contains ``month``."""
        out: list[str] = []
        if month < 1 or month > 12:
            return out
        for region in self._ice_regions:
            months = region.get("months", [])
            if isinstance(months, list) and month in months:
                out.append(str(region.get("id", "")))
        return out

    def ice_blocks(self, x: int, y: int, month: int) -> bool:
        """True when (x, y) is water inside an ice polygon whose window
        contains ``month`` (§4.18: impassable to entering fleets in that
        month). Wrap-aware on x; y bounded; a month outside 1..12 is never
        icy."""
        if month < 1 or month > 12 or y < 0 or y >= GRID_HEIGHT:
            return False
        return (x % GRID_WIDTH, y) in self.ice_mask_for(month)

    def ice_mask_for(self, month: int) -> set[tuple[int, int]]:
        """The memoized month mask over the polygon interiors (built lazily
        on first query of each month, exactly like ``ocean_layers.gd``)."""
        if month < 1 or month > 12:
            return set()
        cached = self._ice_masks.get(month)
        if cached is not None:
            return cached
        mask: set[tuple[int, int]] = set()
        for region in self._ice_regions:
            months = region.get("months", [])
            if not (isinstance(months, list) and month in months):
                continue
            polygon = region.get("polygon", [])
            for row, x0, span in self._ring_spans(polygon):
                if row < 0 or row >= GRID_HEIGHT:
                    continue
                for i in range(span):
                    mask.add(((x0 + i) % GRID_WIDTH, row))
        self._ice_masks[month] = mask
        return mask

    # -- Reversal membership (built once at load) -------------------------------

    def _build_reversal_index(self) -> None:
        """Rebuilds the corridor geometry of every reversal system so a
        lookup can tell which raster tile belongs to one. The
        ``tools/build_ocean.py`` ``chain_between`` + Chebyshev-dilation port
        minus the water test (a land tile's raster index is 0 and
        ``current_at`` returns before the flip is consulted)."""
        self._reversal_members = {}
        for system in self._currents_systems:
            reversal = system.get("reversal")
            if not isinstance(reversal, dict) or not reversal:
                continue
            summer = reversal.get("summer_months", [])
            if not isinstance(summer, list) or not summer:
                continue
            strength = int(system.get("strength", 0))
            path = system.get("path", [])
            width_tiles = int(system.get("width_tiles", 1))
            radius = max(0, (width_tiles - 1) // 2)
            for tile_x, tile_y in self._corridor_chain(path):
                for dy in range(-radius, radius + 1):
                    yy = tile_y + dy
                    if yy < 0 or yy >= GRID_HEIGHT:
                        continue
                    for dx in range(-radius, radius + 1):
                        self._reversal_members[
                            ((tile_x + dx) % GRID_WIDTH, yy)
                        ] = (strength, summer)

    @staticmethod
    def _corridor_chain(path: list) -> list[tuple[int, int]]:
        """The builder's per-segment tile chain: every path segment stepped
        tile by tile (1/20-tile sampling, diagonal moves bridged
        orthogonally), x wrapping."""
        out: list[tuple[int, int]] = []
        if len(path) < 1:
            return out
        ax, ay = tile_of_latlon(float(path[0][0]), float(path[0][1]))
        out.append((ax, ay))
        prev_x, prev_y = ax, ay
        for i in range(len(path) - 1):
            bx, by = tile_of_latlon(float(path[i + 1][0]), float(path[i + 1][1]))
            # b's x shifted to the nearest continuation of a (|dx| ≤ w/2).
            ux = float(bx)
            while ux - ax > GRID_WIDTH / 2.0:
                ux -= GRID_WIDTH
            while ux - ax < -GRID_WIDTH / 2.0:
                ux += GRID_WIDTH
            steps = max(1, int(math.ceil(
                max(abs(ux - ax), abs(by - ay)) * 20.0)))
            for step in range(1, steps + 1):
                t = step / steps
                cx = ax + (ux - ax) * t
                cy = ay + (by - ay) * t
                tile_x = int(math.floor(cx)) % GRID_WIDTH
                tile_y = min(max(int(math.floor(cy)), 0), GRID_HEIGHT - 1)
                if (tile_x, tile_y) == (prev_x, prev_y):
                    continue
                if tile_x != prev_x and tile_y != prev_y:
                    bridge = (tile_x, prev_y)
                    if not out or out[-1] != bridge:
                        out.append(bridge)
                if not out or out[-1] != (tile_x, tile_y):
                    out.append((tile_x, tile_y))
                prev_x, prev_y = tile_x, tile_y
        return out

    # -- Polygon rasterization (the builder's even-odd scanline) ----------------

    @classmethod
    def _ring_spans(cls, ring: list) -> list[tuple[int, int, int]]:
        """Even-odd scanline fill sampled at tile centres: ``ring`` is a
        closed ``[[lat, lon], …]`` polygon (first pair repeated last),
        longitudes unwrapped across the antimeridian, spans wrapped modulo
        the grid width by the caller. Returns ``(y, x0, width)`` rows in
        unwrapped tile coordinates."""
        out: list[tuple[int, int, int]] = []
        n = len(ring)
        if n < 3:
            return out
        lons = cls._unwrap_ring(ring)
        tpd = GRID_WIDTH / 360.0
        xs = [(lons[i] + 180.0) * tpd for i in range(n)]
        ys = [(90.0 - float(ring[i][0])) * tpd for i in range(n)]
        y_lo = max(0.0, min(ys))
        y_hi = min(float(GRID_HEIGHT), max(ys))
        if y_hi <= y_lo:
            return out
        row_lo = max(0, int(math.ceil(y_lo - 0.5)))
        row_hi = min(GRID_HEIGHT - 1, int(math.ceil(y_hi - 0.5)) - 1)

        edges: list[list[float]] = []  # [x_at_top, y_top, dx/dy], top → bottom
        buckets: dict[int, list[int]] = {}
        for i in range(n):
            j = (i + 1) % n
            x0, y0 = xs[i], ys[i]
            x1, y1 = xs[j], ys[j]
            if y0 == y1:
                continue
            if y0 < y1:
                cls._push_edge(edges, buckets, x0, y0, x1, y1, row_lo, row_hi)
            else:
                cls._push_edge(edges, buckets, x1, y1, x0, y0, row_lo, row_hi)

        for row, edge_indices in buckets.items():
            py = row + 0.5
            crossings = sorted(
                edges[k][0] + (py - edges[k][1]) * edges[k][2]
                for k in edge_indices
            )
            k = 0
            while k + 1 < len(crossings):
                c0 = int(math.ceil(crossings[k] - 0.5))
                c1 = int(math.ceil(crossings[k + 1] - 0.5)) - 1
                if c1 >= c0:
                    out.append((row, c0, c1 - c0 + 1))
                k += 2
        return out

    @staticmethod
    def _push_edge(edges: list[list[float]], buckets: dict[int, list[int]],
                   xa: float, ya: float, xb: float, yb: float,
                   row_lo: int, row_hi: int) -> None:
        r_start = max(row_lo, int(math.ceil(ya - 0.5)))
        r_end = min(row_hi, int(math.ceil(yb - 0.5)) - 1)
        if r_start > r_end:
            return
        index = len(edges)
        edges.append([xa, ya, (xb - xa) / (yb - ya)])
        for r in range(r_start, r_end + 1):
            buckets.setdefault(r, []).append(index)

    @staticmethod
    def _unwrap_ring(ring: list) -> list[float]:
        """Longitudes of a ring made continuous across the antimeridian: each
        vertex takes the nearest continuation of the previous one, so a
        dateline-crossing ring rasterizes in one frame."""
        lons: list[float] = []
        prev = 0.0
        offset = 0.0
        first = True
        for pair in ring:
            value = float(pair[1]) + offset
            if not first:
                while value - prev > 180.0:
                    value -= 360.0
                    offset -= 360.0
                while value - prev < -180.0:
                    value += 360.0
                    offset += 360.0
            lons.append(value)
            prev = value
            first = False
        return lons


# --- Land-distance raster (§6.7) ---------------------------------------------


def encode_dist_land(d: float) -> tuple[int, int, int]:
    """The §6.7 encode (pinned): ``enc = round(min(d,16)/16*65535)`` split
    across R (high byte) and G (low byte), B = 0."""
    enc = int(round(min(d, DIST_LAND_SATURATION_TILES)
                    / DIST_LAND_SATURATION_TILES * 65535))
    return (enc >> 8, enc & 255, 0)


def decode_dist_land(r: int, g: int) -> float:
    """The §6.7 decode (pinned): ``d = (R*256+G)/4096`` tiles."""
    return (r * 256 + g) / 4096


class DistLand:
    """Decoded ``data/maps/dist_land.png`` — per-tile Euclidean distance to
    land (§6.7, RGB8, one texel per tile). Render-only in the Godot runtime
    (the water shader's pixel-depth factor); carried here as the decoded
    lookup so the web era consumes the same field without the shader."""

    def __init__(self, data_root: Path | None = None) -> None:
        root = data_root if data_root is not None else REPO_ROOT
        width, height, rgb = decode_rgb8_png(
            _read_bytes(root / DIST_LAND_PNG, "dist_land.png"),
            "data/maps/dist_land.png")
        if width != GRID_WIDTH or height != GRID_HEIGHT:
            raise RasterError(
                f"data/maps/dist_land.png is {width}x{height}, the locked "
                f"grid is {GRID_WIDTH}x{GRID_HEIGHT} (§6.1/§6.7)"
            )
        self.width = width
        self.height = height
        #: Raw RGB bytes, 3 per texel, row-major.
        self.rgb = rgb

    def dist_at(self, x: int, y: int) -> float:
        """Distance to land in tiles at (x, y): ``d = (R*256+G)/4096``.
        x wraps; y out of range reads open water (§6.7) → the saturation
        cap ``16.0``."""
        if y < 0 or y >= self.height:
            return float(DIST_LAND_SATURATION_TILES)
        offset = (y * self.width + x % self.width) * 3
        return decode_dist_land(self.rgb[offset], self.rgb[offset + 1])


# --- Module-level singletons (the DataLoader.map role) -----------------------

_world: WorldRaster | None = None
_ocean: OceanLayers | None = None
_dist: DistLand | None = None


def raster(data_root: Path | None = None) -> WorldRaster:
    """The world raster singleton — the ``DataLoader.map`` equivalent
    (decodes once per process)."""
    global _world
    if _world is None:
        _world = WorldRaster(data_root)
    return _world


def ocean_layers(data_root: Path | None = None) -> OceanLayers:
    """The ocean-layer singleton — the ``OceanLayers.instance()`` equivalent
    (decodes once per process; wind + currents + reversal + ice)."""
    global _ocean
    if _ocean is None:
        _ocean = OceanLayers(data_root)
    return _ocean


def dist_land(data_root: Path | None = None) -> DistLand:
    """The land-distance singleton (decodes once per process)."""
    global _dist
    if _dist is None:
        _dist = DistLand(data_root)
    return _dist


def reset_singletons() -> None:
    """Test seam: drops the decoded singletons so a later accessor call
    re-decodes (the oracle's ``reset_instance``)."""
    global _world, _ocean, _dist
    _world = None
    _ocean = None
    _dist = None
