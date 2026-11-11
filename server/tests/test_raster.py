"""Parity suite for server/sim/world/raster.py (M1) — the world-raster
decode + lookup layer.

Port the guarantee, not the method (AGENTS.md test discipline): the
build-time validator (groups 6/9/13) already proved the full-map facts
(connectivity, byte-identical rebuilds, palette totality). This suite
decodes the four rasters ONCE (module-scope singletons) and asserts
targeted lookups against the §6.x pinned contracts and the oracle
(``scripts/world/map_loader.gd`` + ``scripts/world/ocean_layers.gd``):

  * §6.1 locked grid constants + §6.2/§6.3 legend semantics on known tiles
    (the Lisbon harbor pair from ``data/maps/harbors.json``, cross-checked
    against the builder's ``world_report.json``).
  * Wrap-awareness on x (tile (0, y) ≡ (4320, y)) and the closed latitude
    edges, plus the wrap-aware Chebyshev helper.
  * Currents decode round-trip for hand-picked corridor tiles of three
    authored systems (Gulf Stream / Canaries / Kuroshio — tiles taken from
    the ``data/ocean_currents.json`` paths), the Somali reversal flip AT
    LOOKUP TIME (months 6–9, strength-guarded), and no-current tiles.
  * Wind-region id of a known ocean area + the ``VAR`` fallback.
  * dist_land decode: a land texel is 0, mid-ocean reads the saturated
    16-tile ramp, and the pinned encode/decode formula round-trips.
  * §4.18 ice polygons: one Baltic tile, month-keyed, with the memoized
    cache observation.
  * The minimal PNG reader: synthetic indexed + RGB8 round-trips through
    filter types 0/1/2, loud failures on garbage/wrong-colour-type input,
    and a synthetic 4320×2160 world grid exercising the loader gates
    (the oracle's ``from_indices`` synthetic-grid seam).

Deterministic; no RNG, no full-map pixel walks.
"""

from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path

import pytest

from server.sim.world import raster as ras
from server.sim.world.raster import (
    COMPASS_VECTORS,
    DIST_LAND_SATURATION_TILES,
    GRID_HEIGHT,
    GRID_WIDTH,
    LAND_INDEX,
    MAX_CURRENT_INDEX,
    MAX_WIND_REGIONS,
    PALETTE_CHARS,
    DistLand,
    OceanLayers,
    PngFormatError,
    RasterError,
    WorldRaster,
    chebyshev_wrap,
    decode_dist_land,
    decode_indexed_png,
    decode_rgb8_png,
    dist_land,
    encode_dist_land,
    ocean_layers,
    raster,
    tile_of_latlon,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


# --- Module-scope fixtures: decode all four rasters once --------------------

@pytest.fixture(scope="module")
def world() -> WorldRaster:
    return raster()


@pytest.fixture(scope="module")
def ocean() -> OceanLayers:
    return ocean_layers()


@pytest.fixture(scope="module")
def dist() -> DistLand:
    return dist_land()


@pytest.fixture(scope="module")
def harbors() -> dict:
    return json.loads((REPO_ROOT / "data/maps/harbors.json").read_text())


@pytest.fixture(scope="module")
def report_ports() -> list[dict]:
    report = json.loads((REPO_ROOT / "data/maps/world_report.json").read_text())
    return report["ports"]


# --- §6.1 locked constants + decode sizes -----------------------------------

def test_locked_grid_constants(world: WorldRaster, ocean: OceanLayers,
                               dist: DistLand) -> None:
    """§6.1: the grid is exactly 4320 × 2160 and every raster ships at it."""
    assert GRID_WIDTH == 4320
    assert GRID_HEIGHT == 2160
    assert (world.width, world.height) == (GRID_WIDTH, GRID_HEIGHT)
    assert (ocean.width, ocean.height) == (GRID_WIDTH, GRID_HEIGHT)
    assert (dist.width, dist.height) == (GRID_WIDTH, GRID_HEIGHT)


def test_locked_palette_and_bounds(world: WorldRaster) -> None:
    """§6.3: palette indices 0–4 = ``~ . # ^ I`` locked, append-only."""
    assert PALETTE_CHARS == "~.#^I"
    assert ras.PASSABLE_INDICES == (0, 1)
    assert LAND_INDEX == 2
    # §6.5 ocean-raster bounds (the decode already enforced them).
    assert MAX_WIND_REGIONS == 25
    assert MAX_CURRENT_INDEX == 24


# --- §6.2/§6.3 legend semantics on known tiles + the harbor pair ------------

def test_lisbon_harbor_pair(world: WorldRaster, harbors: dict,
                            report_ports: list[dict]) -> None:
    """§9.1: the runtime reads the builder's persisted harbor pair —
    berth water + passable, shore ``#`` + impassable, both halves agreeing
    with ``world_report.json`` for Lisbon."""
    entry = next(h for h in harbors["harbors"] if h["id"] == "lisbon")
    assert harbors["version"] == 1
    assert entry["berth"] == [2050, 615]
    assert entry["shore"] == [2051, 615]
    assert world.port_cell("lisbon") == (2050, 615)
    assert world.shore_cell("lisbon") == (2051, 615)
    # Berth: water (§6.2 ``.``/``~``), passable; shore: land ``#``, not.
    assert world.char_at(2050, 615) in ("~", ".")
    assert world.is_passable(2050, 615) is True
    assert world.terrain_kind(2050, 615) in ("sea", "coastal_sea")
    # A land tile straight from the builder's report is impassable.
    assert world.char_at(2051, 615) == "#"
    assert world.is_passable(2051, 615) is False
    assert world.terrain_kind(2051, 615) == "land"
    # The builder's report states the same pair (validator group 6's fact,
    # pinned here for the decode layer's data source).
    lisbon = next(p for p in report_ports if p["id"] == "lisbon")
    assert lisbon["harbor_tile"] == {"x": 2050, "y": 615}
    assert lisbon["shore_tile"] == {"x": 2051, "y": 615}
    # Inverse lookups (the docking path of §4.11.1).
    assert world.port_id_at(2050, 615) == "lisbon"
    assert world.shore_port_at(2051, 615) == "lisbon"
    assert world.port_id_at(2051, 615) == ""  # shore tile is not a berth
    # A mid-ocean tile from the report's sea is open water.
    gyre = tile_of_latlon(-30.0, -125.0)
    assert world.char_at(*gyre) == "~"
    assert world.is_passable(*gyre) is True


def test_harbor_table_complete(world: WorldRaster, harbors: dict,
                               report_ports: list[dict]) -> None:
    """§9 step 5 / §9.1: every persisted port carries a full pair, every
    berth decodes as water and every shore as ``#`` (targeted lookups —
    2 byte reads per port, no grid walk). One report cross-check beyond
    Lisbon pins the table-vs-report agreement shape."""
    ids = [entry["id"] for entry in harbors["harbors"]]
    assert len(ids) == len(set(ids))
    for entry in harbors["harbors"]:
        bx, by = entry["berth"]
        sx, sy = entry["shore"]
        assert world.port_cell(entry["id"]) == (bx, by)
        assert world.shore_cell(entry["id"]) == (sx, sy)
        assert world.is_passable(bx, by) is True   # berth is water
        assert world.char_at(sx, sy) == "#"        # shore is land
    # Report agreement for one more port (the table is the runtime source,
    # the report the builder's own record of the same rule).
    last = report_ports[-1]
    assert world.port_cell(last["id"]) == (last["harbor_tile"]["x"],
                                           last["harbor_tile"]["y"])
    assert world.shore_cell(last["id"]) == (last["shore_tile"]["x"],
                                            last["shore_tile"]["y"])


# --- Wrap + bounds (§6.1 longitude wrap) -------------------------------------

def test_x_wrap(world: WorldRaster) -> None:
    """§6.1: ``x`` is taken mod 4320 everywhere — tile (0, y) ≡ (4320, y)."""
    for y in (615, 1080):  # the Lisbon berth row + the equator row
        assert world.index_at(4320, y) == world.index_at(0, y)
        assert world.index_at(-1, y) == world.index_at(4319, y)
        assert world.is_passable(4320, y) == world.is_passable(0, y)
        assert world.is_passable(-1, y) == world.is_passable(4319, y)
    # A land tile keeps its passability through the wrap too.
    assert world.is_passable(2051 + GRID_WIDTH, 615) is False


def test_y_out_of_range_closed(world: WorldRaster, ocean: OceanLayers,
                               dist: DistLand) -> None:
    """§9 step 3: y out of range is false / -1 (the latitude edges are the
    locked §6.2 ice band)."""
    assert world.index_at(100, -1) == -1
    assert world.index_at(100, GRID_HEIGHT) == -1
    assert world.is_passable(100, -1) is False
    assert world.is_passable(100, GRID_HEIGHT) is False
    assert ocean.wind_region_at(100, -1) == 0
    assert ocean.current_at(100, -1, 3) is None
    assert ocean.current_at(100, GRID_HEIGHT, 3) is None
    assert dist.dist_at(100, -1) == float(DIST_LAND_SATURATION_TILES)
    assert dist.dist_at(100, GRID_HEIGHT) == float(DIST_LAND_SATURATION_TILES)


def test_chebyshev_wrap_helper() -> None:
    """The wrap-aware Chebyshev (the loader's seam-distance helper):
    x = 0 and x = 4319 are neighbours."""
    assert chebyshev_wrap(0, 0, GRID_WIDTH - 1, 0) == 1
    assert chebyshev_wrap(GRID_WIDTH - 1, 5, 0, 5) == 1
    assert chebyshev_wrap(0, 0, 3, 4) == 4
    assert chebyshev_wrap(10, 10, 10, 10) == 0


def test_tile_of_latlon_projection(report_ports: list[dict]) -> None:
    """§6.1 addressing: ``x = floor((lon+180)·12) mod w``,
    ``y = floor((90−lat)·12)`` clamped — Lisbon's projection is its report
    berth tile (report ``distance: 0``)."""
    lisbon = next(p for p in report_ports if p["id"] == "lisbon")
    assert tile_of_latlon(lisbon["lat"], lisbon["lon"]) == (2050, 615)
    assert tile_of_latlon(0.0, 180.0) == (0, 1080)      # antimeridian east
    assert tile_of_latlon(0.0, -180.0) == (0, 1080)     # antimeridian west
    assert tile_of_latlon(91.0, 0.0)[1] == 0            # y clamps at the top


# --- Currents (§4.17 via §6.5) -------------------------------------------------

def test_currents_decode_roundtrip(ocean: OceanLayers) -> None:
    """§6.5: a corridor tile decodes to its segment's dominant compass
    direction × the system strength — hand-picked tiles from the authored
    ``data/ocean_currents.json`` paths (``index = dir_index·3 + strength``),
    verified against the shipped raster."""
    # Gulf Stream: strength 3; the (24.5°N, 80.3°W) path vertex sits on the
    # Straits-of-Florida segment whose dominant bearing is NE.
    gulf = tile_of_latlon(24.5, -80.3)
    assert gulf == (1196, 786)
    assert ocean.current_at(*gulf, 1) == {"dir": "NE", "strength": 3}
    assert ocean.current_at(*gulf, 7) == {"dir": "NE", "strength": 3}
    assert ocean.current_at(*gulf, -1) == {"dir": "NE", "strength": 3}
    # The flow vector: unit NE (y grows southward, so NE has vy < 0) × 3.
    vx, vy = COMPASS_VECTORS[1]
    assert ocean.current_vector_at(*gulf, 1) == (vx * 3, vy * 3)
    # Canaries: strength 2, first segment (33.5°N, 9.8°W) → SW drift.
    canaries = tile_of_latlon(33.5, -9.8)
    assert canaries == (2042, 678)
    assert ocean.current_at(*canaries, 1) == {"dir": "SW", "strength": 2}
    # Kuroshio: strength 3, first segment (12.5°N, 127°E) → N.
    kuroshio = tile_of_latlon(12.5, 127.0)
    assert kuroshio == (3684, 930)
    assert ocean.current_at(*kuroshio, 7) == {"dir": "N", "strength": 3}
    # No-current tiles: the South Pacific gyre interior and a land tile
    # (the builder paints water only, §6.5 overlap rules).
    assert ocean.current_at(*tile_of_latlon(-30.0, -125.0), 3) is None
    assert ocean.current_at(*tile_of_latlon(25.0, 10.0), 3) is None
    assert ocean.current_vector_at(*tile_of_latlon(-30.0, -125.0), 3) == (0.0, 0.0)


def test_somali_reversal_flip_at_lookup(ocean: OceanLayers) -> None:
    """§6.5 "Reversal at lookup": the raster stores the non-summer regime;
    ``reversal.summer_months`` = [6, 7, 8, 9] flips the stored direction to
    its 8-compass opposite at lookup time, strength unchanged. One static
    PNG, seasonal Somali."""
    somali = tile_of_latlon(9.0, 52.0)  # a (9°N, 52°E) path vertex
    assert somali == (2784, 972)
    # Stored (winter / non-summer) drift is S at strength 2.
    assert ocean.current_at(*somali, 1) == {"dir": "S", "strength": 2}
    assert ocean.current_at(*somali, 5) == {"dir": "S", "strength": 2}
    assert ocean.current_at(*somali, 10) == {"dir": "S", "strength": 2}
    assert ocean.current_at(*somali, -1) == {"dir": "S", "strength": 2}
    # The summer jet: N at the same strength, exactly inside the window.
    for month in (6, 7, 8, 9):
        assert ocean.current_at(*somali, month) == {"dir": "N",
                                                    "strength": 2}
    # The flip's strength guard (§6.5 overlap rules): a tile the strongest-
    # then-id-order rule gave to a DIFFERENT system is never flipped. Use
    # the Canaries tile (Atlantic — provably outside every reversal
    # corridor) with an injected stronger phantom member.
    key = tile_of_latlon(33.5, -9.8)
    assert key not in ocean._reversal_members
    try:
        ocean._reversal_members[key] = (1, [7])   # strength ≠ decoded 2
        assert ocean.current_at(*key, 7) == {"dir": "SW", "strength": 2}
        ocean._reversal_members[key] = (2, [7])   # same strength → flips
        assert ocean.current_at(*key, 7) == {"dir": "NE", "strength": 2}
    finally:
        del ocean._reversal_members[key]


# --- Wind regions (§4.14/§4.16 via §6.5) ----------------------------------------

def test_wind_region_known_area(ocean: OceanLayers) -> None:
    """§6.5: palette index = region id in ``data/wind_regions.json`` file
    order — (50°N, 30°W) is mid-North-Atlantic water inside the FIRST
    authored region (``westerlies_n_atlantic``), whose July table entry is
    ``W`` and January entry ``SW``."""
    tile = tile_of_latlon(50.0, -30.0)
    assert tile == (1800, 480)
    assert ocean.wind_region_at(*tile) == 1
    assert ocean.prevailing_for(*tile, 7) == "W"
    assert ocean.prevailing_for(*tile, 1) == "SW"
    # The VAR fallback is an expected state: unassigned water (index 0) and
    # any out-of-range month decode to "VAR".
    land = tile_of_latlon(25.0, 10.0)  # the Sahara — water-only paint → 0
    assert ocean.wind_region_at(*land) == 0
    assert ocean.prevailing_for(*land, 7) == "VAR"
    assert ocean.prevailing_for(*tile, 0) == "VAR"
    assert ocean.prevailing_for(*tile, 13) == "VAR"


# --- dist_land (§6.7) -------------------------------------------------------------

def test_dist_land_decode(dist: DistLand) -> None:
    """§6.7: a land texel decodes 0; mid-ocean sits at the saturated ramp
    end; off-map y reads open water (the saturation cap); the pinned
    encode/decode formula round-trips."""
    # The Lisbon shore tile is land → distance 0 exactly.
    assert dist.dist_at(2051, 615) == 0.0
    assert dist.dist_at(2050, 615) > 0.0  # its berth water tile is not
    # Mid-North-Atlantic (50°N, 30°W) reads the saturation end: the encode
    # of 16 is 65535 → decode (255·256+255)/4096.
    assert dist.dist_at(1800, 480) == 65535 / 4096
    # The pinned formula: enc = round(min(d,16)/16·65535), R = enc>>8,
    # G = enc&255, B = 0; decode d = (R·256+G)/4096.
    assert encode_dist_land(0.0) == (0, 0, 0)
    assert encode_dist_land(16.0) == (255, 255, 0)
    assert encode_dist_land(1.0) == (16, 0, 0)  # round(4095.9375) = 4096
    assert decode_dist_land(255, 255) == 65535 / 4096
    assert decode_dist_land(16, 0) == 1.0
    assert encode_dist_land(64.0) == encode_dist_land(16.0)  # saturated
    for d in (0.0, 0.5, 3.25, 10.0, 16.0):
        r, g, _b = encode_dist_land(d)
        assert abs(decode_dist_land(r, g) - d) <= 1 / 4096  # 1/4096 precision


# --- Seasonal sea ice (§4.18) ------------------------------------------------------

def test_ice_polygon_check(ocean: OceanLayers) -> None:
    """§4.18 via ocean_layers.gd: the Baltic polygon blocks its interior in
    the active months (cyclic [12, 1, 2, 3]) and never outside them; the
    month mask is built lazily and memoized (the same set object)."""
    baltic = tile_of_latlon(60.0, 19.0)  # a vertex-enclosed Baltic Sea tile
    assert baltic == (2388, 360)
    assert ocean.ice_blocks(*baltic, 1) is True
    assert ocean.ice_blocks(*baltic, 3) is True
    assert ocean.ice_blocks(*baltic, 12) is True
    assert ocean.ice_blocks(*baltic, 7) is False
    assert ocean.ice_blocks(*baltic, 13) is False   # months outside 1..12
    assert ocean.ice_blocks(*baltic, 0) is False    # are never icy
    assert ocean.ice_active_regions(1) == ["baltic_ice", "hudson_bay_ice",
                                           "white_sea_ice"]
    assert ocean.ice_active_regions(7) == []
    assert ocean.ice_active(1) is True
    assert ocean.ice_active(7) is False
    mask = ocean.ice_mask_for(1)
    assert mask is ocean.ice_mask_for(1)            # memoized per month
    assert (2388, 360) in mask
    assert baltic not in ocean.ice_mask_for(7)      # July mask is empty


# --- The minimal PNG reader (stdlib zlib + struct) ---------------------------------


def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def _encode_rows(width: int, height: int, pixels: bytes, bpp: int,
                 row_filters: list[int] | None = None) -> bytes:
    """Rows with the filter INVERSE applied (so the reader's unfilter
    restores the original pixels)."""
    stride = width * bpp
    raw = bytearray()
    prev = bytearray(stride)
    for y in range(height):
        ft = row_filters[y] if row_filters else 0
        orig = bytes(pixels[y * stride:(y + 1) * stride])
        line = bytearray(orig)
        if ft == 1:  # Sub — forward transform reads ORIGINAL left pixels
            for i in range(bpp, stride):
                line[i] = (orig[i] - orig[i - bpp]) & 255
        elif ft == 2:  # Up — subtracts the previous row's unfiltered pixels
            for i in range(stride):
                line[i] = (orig[i] - prev[i]) & 255
        raw.append(ft)
        raw += line
        prev = bytearray(orig)
    return bytes(raw)


def _indexed_png(width: int, height: int, indices: bytes, palette: bytes,
                 row_filters: list[int] | None = None) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    return (ras._PNG_SIGNATURE + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"PLTE", palette)
            + _png_chunk(b"IDAT", zlib.compress(
                _encode_rows(width, height, indices, 1, row_filters)))
            + _png_chunk(b"IEND", b""))


def _rgb8_png(width: int, height: int, rgb: bytes,
              row_filters: list[int] | None = None) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (ras._PNG_SIGNATURE + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"IDAT", zlib.compress(
                _encode_rows(width, height, rgb, 3, row_filters)))
            + _png_chunk(b"IEND", b""))


def test_png_reader_indexed_roundtrip() -> None:
    """The reader restores exact indices through filter types 0/1/2 and
    fails loudly on garbage / wrong colour type."""
    palette = bytes([0, 0, 0, 255, 255, 255, 128, 64, 0, 10, 200, 10,
                     200, 10, 200])
    grid = bytes([0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 0, 1])  # 4×3
    w, h, out = decode_indexed_png(
        _indexed_png(4, 3, grid, palette, row_filters=[0, 1, 2]), "t")
    assert (w, h) == (4, 3)
    assert bytes(out) == grid
    # RGB8 round-trip (the dist_land.png colour type).
    rgb = bytes(range(36))
    w, h, out = decode_rgb8_png(
        _rgb8_png(4, 3, rgb, row_filters=[0, 1, 2]), "t")
    assert (w, h) == (4, 3)
    assert bytes(out) == rgb
    # Loud failures.
    with pytest.raises(PngFormatError):
        decode_indexed_png(b"not a png at all", "t")
    with pytest.raises(PngFormatError):
        decode_rgb8_png(_indexed_png(4, 3, grid, palette), "t")  # type 3 ≠ 2
    with pytest.raises(PngFormatError):
        decode_indexed_png(_rgb8_png(4, 3, rgb), "t")  # type 2 ≠ 3


def _write_synthetic_world(root: Path) -> None:
    """A synthetic 4320×2160 all-water grid with land at (100,100) — the
    oracle's ``from_indices`` synthetic-grid seam, via a tmp data root."""
    maps = root / "data/maps"
    maps.mkdir(parents=True, exist_ok=True)
    (root / "data/map_legend.json").write_text(json.dumps({
        "version": 1, "tile_size_px": 32,
        "grid": {"width": GRID_WIDTH, "height": GRID_HEIGHT},
        "tiles": {
            "~": {"kind": "sea", "passable": True},
            ".": {"kind": "coastal_sea", "passable": True},
            "#": {"kind": "land", "passable": False},
            "^": {"kind": "reef", "passable": False},
            "I": {"kind": "polar_ice", "passable": False},
        },
    }))
    (maps / "maps.json").write_text(json.dumps({
        "version": 1,
        "maps": [{"id": "world", "file": "data/maps/world.png",
                  "legend": "data/map_legend.json",
                  "name": {"zh": "世界地图", "en": "World map"}}],
    }))
    indices = bytearray(GRID_WIDTH * GRID_HEIGHT)  # index 0 = `~` water
    indices[100 * GRID_WIDTH + 100] = LAND_INDEX
    palette = bytes([1, 20, 60, 30, 90, 160, 90, 60, 30, 230, 230, 230,
                     200, 200, 255])
    (maps / "world.png").write_bytes(
        _indexed_png(GRID_WIDTH, GRID_HEIGHT, bytes(indices), palette))


def test_synthetic_world_grid(tmp_path: Path) -> None:
    """The loader gates hold on a synthetic grid: known tiles decode
    exactly, the wrap works, and a missing harbor table is a startup
    error (§11) — never a silent empty table."""
    _write_synthetic_world(tmp_path)
    (tmp_path / "data/maps/harbors.json").write_text(json.dumps({
        "version": 1,
        "harbors": [{"id": "fixture", "berth": [101, 100],
                     "shore": [100, 100]}],
    }))
    world = WorldRaster(tmp_path)
    assert (world.width, world.height) == (GRID_WIDTH, GRID_HEIGHT)
    assert world.char_at(0, 0) == "~"
    assert world.is_passable(0, 0) is True
    assert world.char_at(100, 100) == "#"
    assert world.is_passable(100, 100) is False
    assert world.is_passable(100 + GRID_WIDTH, 100) is False   # wraps to land
    assert world.is_passable(-1, 100) == world.is_passable(4319, 100)
    # Both harbor columns load from the table (synthetic fixture port).
    assert world.port_cell("fixture") == (101, 100)
    assert world.shore_cell("fixture") == (100, 100)
    assert world.port_cell("missing") == (-1, -1)
    assert world.shore_cell("missing") == (-1, -1)
    assert world.port_id_at(101, 100) == "fixture"
    assert world.shore_port_at(100, 100) == "fixture"
    # A grid whose PNG is the wrong colour type is a startup error.
    (tmp_path / "data/maps/world.png").write_bytes(
        _rgb8_png(GRID_WIDTH, GRID_HEIGHT,
                  bytes(GRID_WIDTH * GRID_HEIGHT * 3)))
    with pytest.raises(RasterError):
        WorldRaster(tmp_path)
    # A missing harbor table is loud too.
    _write_synthetic_world(tmp_path)  # restores a valid world.png
    (tmp_path / "data/maps/harbors.json").unlink()
    with pytest.raises(RasterError):
        WorldRaster(tmp_path)


# --- Singleton discipline ------------------------------------------------------------

def test_singletons_decode_once() -> None:
    """The module-level accessors return the same decoded objects — the
    load-once role of ``DataLoader.map`` / ``OceanLayers.instance()``."""
    assert raster() is raster()
    assert ocean_layers() is ocean_layers()
    assert dist_land() is dist_land()
    assert isinstance(raster(), WorldRaster)
    assert isinstance(ocean_layers(), OceanLayers)
    assert isinstance(dist_land(), DistLand)
