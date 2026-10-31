#!/usr/bin/env python3
"""build_ocean.py — deterministic ocean-raster builder (Phase 6, task E).

Rasterizes the two tool-owned ocean lookups of docs/10-DATA-SCHEMA.md §6.5
from their hand-authored JSON sources (Phase-6 task D):

  data/maps/wind_regions.png   palette index = region id order in
                               data/wind_regions.json (1..N); index 0 =
                               unassigned water -> the VAR + variable
                               fallback at runtime (20-* §4.14)
  data/maps/currents.png       index 0 = no current; indices 1..24 =
                               dir_index * 3 + strength over the compass
                               order N NE E SE S SW W NW (dir_index 0..7)
                               and strength 1..3 — so N/1 = 1 … NW/3 = 24

Both rasters are indexed-colour PNGs (colour type 3, bit depth 8), exactly
4320 x 2160, 1 px = 1 tile at the §6.1 grid — the same projection
``build_world.py`` pins. Only **water** tiles of ``data/maps/world.png``
(``~`` and ``.``) are ever painted: a polygon or corridor pixel that falls
on land, reef or the permanent ``I`` band is skipped and counted in the
build report (validator group 9 fails any non-zero index on such a tile,
so the builder never writes one).

Locked rules implemented here (docs/10-* §4.16–4.18, §6.5):

  wind polygon    painted by even-odd scanline fill sampled at tile
                  centres (the ``build_world.py`` land-fill rule),
                  wrap-aware in x — a ring may cross the antimeridian.
                  Regions are painted in file order; the shipped sources
                  tile the ocean without overlap (the report records the
                  overlap count, 0 for the shipped data).
  current corridor the system's ``path`` is stepped tile-by-tile
                  (1/20-tile sampling, diagonal bridging — the same
                  geometry as the route builder's segment walk, minus the
                  passability test), then dilated by Chebyshev radius
                  ``floor((width_tiles − 1) / 2)`` per side (wrap-aware in
                  x, clamped in y). Authored widths are odd, so the painted
                  corridor is exactly ``width_tiles`` tiles wide. Each
                  segment's tiles take that segment's compass direction
                  (the flow axis is downstream order); a tile covered by
                  several systems takes the strongest system's vector,
                  strength ties go to the system earliest in file order —
                  "strongest-then-id-order".
  determinism     no timestamps, no randomness, stable order everywhere:
                  two consecutive builds are **byte-identical**
                  (validator group 9 re-asserts it).

The rasters store each system's authored (stored, non-flipped) vector; a
``reversal`` system's summer flip happens at lookup time (20-* §4.16) —
one static PNG, seasonal Somali.

Usage
-----
    python3 tools/build_ocean.py              # build + write both rasters
    python3 tools/build_ocean.py --check      # rebuild in memory, byte-compare
    python3 tools/build_ocean.py --report     # build + print report JSON
    python3 tools/build_ocean.py --ascii      # debug export (stdout)
    python3 tools/build_ocean.py --ascii --rows 200:260 [--ascii-out PATH]

Exit codes: 0 ok; 1 usage/CLI failure; 2 BuildError (a named source
problem); 3 determinism drift (``--check`` mismatch).
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
WORLD_PNG = DATA / "maps" / "world.png"
WIND_JSON = DATA / "wind_regions.json"
CURRENTS_JSON = DATA / "ocean_currents.json"
WIND_PNG = DATA / "maps" / "wind_regions.png"
CURRENTS_PNG = DATA / "maps" / "currents.png"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_world as bw  # noqa: E402  (shared grid/projection/PNG pieces)

# --------------------------------------------------------------------------
# Locked encodings (docs/10-DATA-SCHEMA.md §6.5)
# --------------------------------------------------------------------------
COMPASS = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")  # dir_index 0..7
WIND_TOKENS = frozenset(COMPASS) | {"VAR"}
MAX_CURRENT_INDEX = 24  # 8 directions x 3 strengths

INPUT_SOURCES = (
    ("wind_regions", WIND_JSON),
    ("ocean_currents", CURRENTS_JSON),
    ("world_png", WORLD_PNG),
)

PNG_SIGNATURE = bw.PNG_SIGNATURE


class BuildError(Exception):
    """A loud, named build failure (exit code 2)."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Source loading + light structural checks (loud, named; group 9/10 re-check)
# --------------------------------------------------------------------------
def _point(pair, where: str) -> tuple[float, float]:
    if (not isinstance(pair, (list, tuple)) or len(pair) != 2
            or not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                       for v in pair)):
        raise BuildError(f"{where}: polygon/path entry {pair!r} must be [lat, lon]")
    lat, lon = float(pair[0]), float(pair[1])
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        raise BuildError(f"{where}: vertex out of range: {pair}")
    return lat, lon


def load_wind_regions() -> list[dict]:
    """Read + structurally check data/wind_regions.json (§4.16)."""
    doc = json.loads(WIND_JSON.read_text(encoding="utf-8"))
    regions = doc.get("wind_regions")
    if not isinstance(regions, list) or not regions:
        raise BuildError("wind_regions.json: missing non-empty 'wind_regions'")
    if not isinstance(doc.get("version"), int):
        raise BuildError("wind_regions.json: missing integer 'version'")
    seen: set[str] = set()
    for index, region in enumerate(regions):
        where = f"wind_regions.json: wind_regions[{index}] ({region.get('id')!r})"
        region_id = region.get("id")
        if not isinstance(region_id, str) or not region_id:
            raise BuildError(f"{where}: missing string 'id'")
        if region_id in seen:
            raise BuildError(f"{where}: duplicate region id")
        seen.add(region_id)
        polygon = region.get("polygon")
        if not isinstance(polygon, list) or len(polygon) < 3:
            raise BuildError(f"{where}: polygon needs >= 3 [lat, lon] vertices")
        for pair in polygon:
            _point(pair, where)
        months = region.get("months")
        if not isinstance(months, dict) or set(months) != {
                str(m) for m in range(1, 13)}:
            raise BuildError(
                f"{where}: months must have exactly the keys '1'..'12'")
        for key, token in months.items():
            if token not in WIND_TOKENS:
                raise BuildError(
                    f"{where}: months['{key}'] {token!r} is not a compass "
                    "token or 'VAR' (§4.16)")
        if region.get("variability") not in ("steady", "variable"):
            raise BuildError(f"{where}: variability must be steady|variable")
    return regions


def load_currents() -> list[dict]:
    """Read + structurally check data/ocean_currents.json (§4.17)."""
    doc = json.loads(CURRENTS_JSON.read_text(encoding="utf-8"))
    systems = doc.get("ocean_currents")
    if not isinstance(systems, list) or not systems:
        raise BuildError("ocean_currents.json: missing non-empty 'ocean_currents'")
    if not isinstance(doc.get("version"), int):
        raise BuildError("ocean_currents.json: missing integer 'version'")
    seen: set[str] = set()
    for index, system in enumerate(systems):
        where = (f"ocean_currents.json: ocean_currents[{index}] "
                 f"({system.get('id')!r})")
        system_id = system.get("id")
        if not isinstance(system_id, str) or not system_id:
            raise BuildError(f"{where}: missing string 'id'")
        if system_id in seen:
            raise BuildError(f"{where}: duplicate system id")
        seen.add(system_id)
        strength = system.get("strength")
        if not isinstance(strength, int) or isinstance(strength, bool) \
                or not (1 <= strength <= 3):
            raise BuildError(f"{where}: strength must be 1|2|3")
        path = system.get("path")
        if not isinstance(path, list) or len(path) < 2:
            raise BuildError(f"{where}: path needs >= 2 [lat, lon] points")
        for pair in path:
            _point(pair, where)
        width = system.get("width_tiles")
        if not isinstance(width, int) or isinstance(width, bool) or width <= 0:
            raise BuildError(f"{where}: width_tiles must be an int > 0")
        reversal = system.get("reversal")
        if reversal is not None:
            if not isinstance(reversal, dict) or set(reversal) != {
                    "summer_months", "direction"}:
                raise BuildError(
                    f"{where}: reversal must be exactly "
                    "{\"summer_months\": [...], \"direction\": \"reverse\"}")
            months = reversal["summer_months"]
            if (not isinstance(months, list) or not months
                    or not all(isinstance(m, int) and not isinstance(m, bool)
                               and 1 <= m <= 12 for m in months)):
                raise BuildError(
                    f"{where}: reversal.summer_months must be non-empty "
                    "month ints 1..12")
            if reversal["direction"] != "reverse":
                raise BuildError(f"{where}: reversal.direction must be \"reverse\"")
    return systems


# --------------------------------------------------------------------------
# Polygon fill at tile centres (the build_world land-fill rule, span-callback)
# --------------------------------------------------------------------------
def _ring_spans(grid: bw.Grid, ring: list[tuple[float, float]]):
    """Yield ``(row, start, width)`` spans covering the ring's interior.

    Even-odd scanline fill sampled at tile centres (x + 0.5, y + 0.5) — the
    exact algorithm of ``build_world.fill_ring``, refactored to hand each
    span to the caller instead of writing a constant value. Longitudes are
    unwrapped across the antimeridian first, and spans wrap modulo the grid
    width, so a ring may cross the dateline.
    """
    n = len(ring)
    if n < 3:
        return
    lons = bw.unwrap_ring([(lon, lat) for lon, lat in ring])
    tpd = grid.tiles_per_degree()
    xs = [(lons[i] + 180.0) * tpd for i in range(n)]
    ys = [(90.0 - ring[i][1]) * tpd for i in range(n)]

    y_lo = max(0.0, min(ys))
    y_hi = min(float(grid.h), max(ys))
    if y_hi <= y_lo:
        return
    row_lo = max(0, int(math.floor(y_lo - 0.5)))
    row_hi = min(grid.h - 1, int(math.ceil(y_hi - 0.5)))

    edges = []  # (x_at_top, y_top, dx/dy), normalised top -> bottom
    buckets: dict[int, list[int]] = {}
    for i in range(n):
        x0, y0 = xs[i], ys[i]
        x1, y1 = xs[(i + 1) % n], ys[(i + 1) % n]
        if y0 == y1:
            continue
        if y0 < y1:
            xa, ya, xb, yb = x0, y0, x1, y1
        else:
            xa, ya, xb, yb = x1, y1, x0, y0
        r_start = max(row_lo, int(math.ceil(ya - 0.5)))
        r_end = min(row_hi, int(math.ceil(yb - 0.5)) - 1)
        if r_start > r_end:
            continue
        idx = len(edges)
        edges.append((xa, ya, (xb - xa) / (yb - ya)))
        for r in range(r_start, r_end + 1):
            buckets.setdefault(r, []).append(idx)

    for r in sorted(buckets):
        py = r + 0.5
        crossings = [xa + (py - ya) * slope for (xa, ya, slope) in
                     (edges[i] for i in buckets[r])]
        crossings.sort()
        for i in range(0, len(crossings) - 1, 2):
            c0 = int(math.ceil(crossings[i] - 0.5))
            c1 = int(math.ceil(crossings[i + 1] - 0.5)) - 1
            if c1 < c0:
                continue
            yield r, c0, c1 - c0 + 1


def fill_ring_callback(grid: bw.Grid, ring: list[tuple[float, float]],
                       paint) -> int:
    """Paint the ring interior span-by-span through ``paint(x, y)``."""
    spans = 0
    size = grid.w
    for row, start, width in _ring_spans(grid, ring):
        for dx in range(width):
            paint((start + dx) % size, row)
        spans += 1
    return spans


# --------------------------------------------------------------------------
# Current corridor geometry (tile stepping + Chebyshev dilation)
# --------------------------------------------------------------------------
def unwrap_target(a: tuple[int, int], b: tuple[int, int],
                  width: int) -> tuple[float, float]:
    """``b``'s x shifted to the nearest continuation of ``a`` (|dx| <= w/2)."""
    ux = float(b[0])
    while ux - a[0] > width / 2.0:
        ux -= width
    while ux - a[0] < -width / 2.0:
        ux += width
    return ux, float(b[1])


def chain_between(grid: bw.Grid, a: tuple[int, int], b: tuple[int, int]
                  ) -> list[tuple[int, int]]:
    """Tile chain from ``a`` to ``b`` (no passability test — pure geometry).

    The polyline is sampled at 1/20-tile resolution; diagonal sample moves
    insert the bridging orthogonal tile, so consecutive chain tiles are
    4-adjacent (the route builder's ``walk_segment`` geometry). x wraps.
    """
    (x0, y0), (x1, y1) = a, b
    ux1, yy1 = unwrap_target(a, b, grid.w)
    yy0 = float(y0)
    steps = max(1, int(math.ceil(max(abs(ux1 - x0), abs(yy1 - yy0)) * 20)))
    chain: list[tuple[int, int]] = [(x0 % grid.w, y0)]
    prev = chain[0]

    def add(x: int, y: int) -> None:
        x %= grid.w
        y = min(max(y, 0), grid.h - 1)
        if not chain or chain[-1] != (x, y):
            chain.append((x, y))

    for step in range(1, steps + 1):
        t = step / steps
        cx = x0 + (ux1 - x0) * t
        cy = yy0 + (yy1 - yy0) * t
        tile = (int(math.floor(cx)) % grid.w,
                min(max(int(math.floor(cy)), 0), grid.h - 1))
        if tile == prev:
            continue
        tx, ty = tile
        px, py = prev
        if tx != px and ty != py:
            add(tx, py)  # bridge the diagonal orthogonally
        add(tx, ty)
        prev = tile
    return chain


def dir_index_of(dx: float, dy: float) -> int:
    """Compass dir_index 0..7 of a tile-space vector (y grows southward)."""
    bearing = math.degrees(math.atan2(dx, -dy))  # 0 = N, 90 = E
    bearing %= 360.0
    return int(round(bearing / 45.0)) % 8


def corridor_tiles(grid: bw.Grid, path: list[tuple[int, int]],
                   width_tiles: int) -> dict[tuple[int, int], int]:
    """Corridor tiles of one system: per-segment chains, dilated, directed.

    Returns ``{(x, y): dir_index}``. Each segment's tiles (its chain dilated
    by Chebyshev radius ``floor((width_tiles − 1) / 2)`` per side, wrap-aware
    in x, clamped in y) take that segment's compass direction. A degenerate
    segment (both endpoints in one tile) inherits the previous segment's
    direction — falling back to the path's net displacement — so the corridor
    stays the exact dilation of the path while every tile keeps a direction.
    """
    radius = (width_tiles - 1) // 2
    snapped = [grid.tile_of_latlon(lat, lon) for lat, lon in path]
    out: dict[tuple[int, int], int] = {}
    net_x, net_y = unwrap_target(snapped[0], snapped[-1], grid.w)
    fallback = dir_index_of(net_x - snapped[0][0], net_y - snapped[0][1])
    previous = fallback
    for i in range(len(snapped) - 1):
        a, b = snapped[i], snapped[i + 1]
        chain = chain_between(grid, a, b)
        if len(chain) <= 1:
            direction = previous  # degenerate segment inherits upstream
        else:
            ux, uy = unwrap_target(a, b, grid.w)
            direction = dir_index_of(ux - a[0], uy - a[1])
            previous = direction
        marked: set[tuple[int, int]] = set()
        for x, y in chain:
            for ddy in range(-radius, radius + 1):
                yy = y + ddy
                if not (0 <= yy < grid.h):
                    continue
                for ddx in range(-radius, radius + 1):
                    marked.add(((x + ddx) % grid.w, yy))
        # later segments overwrite earlier ones inside one system
        out.update({tile: direction for tile in marked})
    return out


# --------------------------------------------------------------------------
# Raster painting
# --------------------------------------------------------------------------
# Fast zero-under-mask counting (the build_world row_bits trick: one int AND
# + popcount per row instead of a 9.3M-iteration Python loop).
_WATER_TABLE = bytes(1 if i in bw.PASSABLE else 0 for i in range(256))
_ZERO_TABLE = bytes(1 if i == 0 else 0 for i in range(256))


def count_zero_on_water(grid: bw.Grid, raster: bw.Grid) -> int:
    """Tiles where ``world.png`` is passable but ``raster`` is index 0."""
    total = 0
    for y in range(grid.h):
        water = int.from_bytes(
            bytes(grid.rows[y]).translate(_WATER_TABLE), "big")
        zero = int.from_bytes(
            bytes(raster.rows[y]).translate(_ZERO_TABLE), "big")
        total += bin(water & zero).count("1")
    return total


def paint_wind(grid: bw.Grid, regions: list[dict]) -> tuple[bw.Grid, dict]:
    """Rasterize the wind regions (index = file order 1..N, water only)."""
    raster = bw.Grid()
    stats = {
        "regions": [],
        "painted": 0,
        "fallback_tiles": 0,
        "overlap_tiles": 0,
        "land_skipped": 0,
    }
    for index, region in enumerate(regions, start=1):
        ring = [(float(p[1]), float(p[0])) for p in region["polygon"]]
        painted = 0

        def paint(x: int, y: int, _index: int = index) -> None:
            nonlocal painted
            if not grid.is_water(x, y):
                stats["land_skipped"] += 1
                return
            if raster.get(x, y) != 0:
                stats["overlap_tiles"] += 1
            raster.set(x, y, _index)
            painted += 1

        fill_ring_callback(grid, ring, paint)
        stats["regions"].append({"id": region["id"], "index": index,
                                 "tiles": painted})
        stats["painted"] += painted
    stats["fallback_tiles"] = count_zero_on_water(grid, raster)
    return raster, stats


def paint_currents(grid: bw.Grid, systems: list[dict]) -> tuple[bw.Grid, dict]:
    """Rasterize the current systems (index = dir_index*3 + strength)."""
    raster = bw.Grid()
    stats = {
        "systems": [],
        "painted": 0,
        "none_tiles": 0,
        "overlap_tiles": 0,
        "land_skipped": 0,
    }
    for order, system in enumerate(systems, start=1):
        corridor = corridor_tiles(grid, system["path"],
                                  int(system["width_tiles"]))
        strength = int(system["strength"])
        painted = 0
        land = 0
        for (x, y), direction in corridor.items():
            if not grid.is_water(x, y):
                land += 1
                continue
            index = direction * 3 + strength
            existing = raster.get(x, y)
            if existing == 0:
                raster.set(x, y, index)
                painted += 1
            else:
                stats["overlap_tiles"] += 1
                if strength > ((existing - 1) % 3) + 1:
                    # strongest-then-id-order: strictly stronger wins; a
                    # strength tie keeps the earlier file-order system.
                    raster.set(x, y, index)
                    painted += 1
        stats["systems"].append({
            "id": system["id"], "order": order, "strength": strength,
            "width_tiles": system["width_tiles"],
            "corridor_tiles": len(corridor), "tiles": painted,
            "land_skipped": land,
        })
        stats["painted"] += painted
        stats["land_skipped"] += land
    stats["none_tiles"] = count_zero_on_water(grid, raster)
    return raster, stats


# --------------------------------------------------------------------------
# PNG encoding (build_world's deterministic chunk layout, own palettes)
# --------------------------------------------------------------------------
def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def _hue_rgb(hue_deg: float, lightness: float, saturation: float) -> tuple[int, int, int]:
    r, g, b = colorsys.hls_to_rgb(hue_deg / 360.0, lightness, saturation)
    return (int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))


def wind_palette(region_count: int) -> list[tuple[int, int, int]]:
    """Index 0 = unassigned water; 1..N = one golden-angle hue per region."""
    palette = [(0x21, 0x2A, 0x38)]
    for i in range(1, region_count + 1):
        palette.append(_hue_rgb((i * 137.508) % 360.0, 0.55, 0.65))
    return palette


def currents_palette() -> list[tuple[int, int, int]]:
    """Index 0 = none; 1..24 = hue by direction, lightness by strength."""
    palette = [(0x0A, 0x0C, 0x10)]
    for index in range(1, MAX_CURRENT_INDEX + 1):
        direction = (index - 1) // 3
        strength = ((index - 1) % 3) + 1
        palette.append(
            _hue_rgb(direction * 45.0, 0.30 + 0.15 * strength, 0.85))
    return palette


def encode_raster(grid: bw.Grid, palette: list[tuple[int, int, int]]) -> bytes:
    """Indexed-colour PNG: colour type 3, bit depth 8, filter 0, zlib 9.

    Deterministic for a given raster: no tIME/text chunks, fixed palette
    order, one fixed compression setting (build_world's ``encode_png``
    layout with a caller-supplied palette — §6.5: the ocean rasters carry
    their own palettes, not world.png's five colours).
    """
    raw = bytearray()
    for row in grid.rows:
        raw.append(0)  # filter type 0 (None) per scanline
        raw += row
    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", grid.w, grid.h, 8, 3, 0, 0, 0)
    plte = bytes(channel for rgb in palette for channel in rgb)
    if len(plte) > 768:
        raise BuildError(f"palette has {len(palette)} entries (max 256)")
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"PLTE", plte)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


# --------------------------------------------------------------------------
# Build + report
# --------------------------------------------------------------------------
def build(verbose: bool = False) -> tuple[dict, dict]:
    """Build both rasters; return ``({"wind": png, "currents": png}, report)``."""
    if not WORLD_PNG.is_file():
        raise BuildError(
            "data/maps/world.png not found — run tools/build_world.py first")
    grid = bw.Grid()
    decoded = bw.decode_png(WORLD_PNG.read_bytes())
    if (decoded["width"], decoded["height"]) != (grid.w, grid.h):
        raise BuildError(
            f"world.png is {decoded['width']}x{decoded['height']}, expected "
            f"{grid.w}x{grid.h}")
    for y in range(grid.h):
        grid.rows[y][:] = decoded["rows"][y]

    regions = load_wind_regions()
    systems = load_currents()

    if verbose:
        print(f"build_ocean: {len(regions)} wind regions, {len(systems)} "
              "current systems", file=sys.stderr)
    wind_raster, wind_stats = paint_wind(grid, regions)
    if verbose:
        print(f"build_ocean: wind painted {wind_stats['painted']} tiles "
              f"({wind_stats['fallback_tiles']} VAR fallback, "
              f"{wind_stats['land_skipped']} land skipped)", file=sys.stderr)
    current_raster, current_stats = paint_currents(grid, systems)
    if verbose:
        print(f"build_ocean: currents painted {current_stats['painted']} tiles "
              f"({current_stats['none_tiles']} none, "
              f"{current_stats['land_skipped']} land skipped)", file=sys.stderr)

    wind_png = encode_raster(wind_raster, wind_palette(len(regions)))
    currents_png = encode_raster(current_raster, currents_palette())

    water_tiles = 0
    for y in range(grid.h):
        water_tiles += bin(int.from_bytes(
            bytes(grid.rows[y]).translate(_WATER_TABLE), "big")).count("1")
    report = {
        "report": "build_ocean",
        "wind_raster": "data/maps/wind_regions.png",
        "currents_raster": "data/maps/currents.png",
        "grid": {"width": grid.w, "height": grid.h},
        "encoding": {
            "wind": "palette index = wind_regions.json file order 1..N; "
                    "0 = unassigned water (VAR fallback)",
            "currents": "index = dir_index * 3 + strength; compass order "
                        "N NE E SE S SW W NW; 0 = none",
            "overlap_rule": "currents: strongest-then-id-order; wind: file "
                            "order (shipped sources do not overlap)",
            "water_mask": "only '~'/''.' tiles of world.png are painted",
        },
        "water_tiles": water_tiles,
        "wind": wind_stats,
        "currents": current_stats,
        "sources": {
            name: {"path": str(path.relative_to(ROOT)),
                   "sha256": sha256_file(path)}
            for name, path in INPUT_SOURCES
        },
    }
    pngs = {"wind": wind_png, "currents": currents_png}
    return pngs, report


def serialize_report(report: dict) -> str:
    return json.dumps(report, indent=2, ensure_ascii=False)


# --------------------------------------------------------------------------
# CLI commands
# --------------------------------------------------------------------------
def cmd_build(args) -> int:
    pngs, report = build(verbose=args.verbose)
    for path, blob in ((WIND_PNG, pngs["wind"]),
                       (CURRENTS_PNG, pngs["currents"])):
        path.write_bytes(blob)
        print(
            f"build_ocean: wrote {path.relative_to(ROOT)} ({len(blob)} bytes, "
            f"sha256 {hashlib.sha256(blob).hexdigest()})",
            file=sys.stderr,
        )
    wind = report["wind"]
    currents = report["currents"]
    print(
        "build_ocean: "
        f"wind {wind['painted']} tiles over {len(wind['regions'])} regions "
        f"(VAR fallback {wind['fallback_tiles']}, overlap "
        f"{wind['overlap_tiles']}, land skipped {wind['land_skipped']}) | "
        f"currents {currents['painted']} tiles over "
        f"{len(currents['systems'])} systems (none {currents['none_tiles']}, "
        f"overlap {currents['overlap_tiles']}, land skipped "
        f"{currents['land_skipped']})",
        file=sys.stderr,
    )
    if args.report:
        print(serialize_report(report))
    return 0


def cmd_check(args) -> int:
    """Rebuild in memory and byte-compare against the committed rasters."""
    pngs, _report = build(verbose=args.verbose)
    drift = []
    for path, blob in ((WIND_PNG, pngs["wind"]),
                       (CURRENTS_PNG, pngs["currents"])):
        if path.read_bytes() != blob:
            drift.append(path)
    if not drift:
        if args.verbose:
            print(
                "build_ocean: check OK — both rasters rebuild byte-identical",
                file=sys.stderr)
        return 0
    for path in drift:
        print(
            f"build_ocean: check FAILED — {path.relative_to(ROOT)} differs "
            f"from the rebuild; fix the JSON sources and regenerate — never "
            f"hand-edit the rasters",
            file=sys.stderr,
        )
    return 3


# --------------------------------------------------------------------------
# ASCII debug export (never a data source; never written under data/)
# --------------------------------------------------------------------------
WIND_ASCII_CHARS = ".abcdefghijklmnopqrstuvwxyz"
CURRENT_ASCII_CHARS = ".123456789ABCDEFGHIJKLMNOP"  # index 1..24


def ascii_lines(raster: bw.Grid, chars: str) -> list[str]:
    table = bytes((ord(chars[i]) if i < len(chars) else ord("?"))
                  for i in range(256))
    return [bytes(row).translate(table).decode("ascii") for row in raster.rows]


def cmd_ascii(args) -> int:
    which = args.layer
    if which not in ("wind", "currents", "both"):
        raise BuildError(f"--layer must be wind|currents|both, got {which!r}")
    layers: list[tuple[str, bw.Grid, str]] = []
    if which in ("wind", "both"):
        regions = load_wind_regions()
        grid = _world_grid()
        wind_raster, _stats = paint_wind(grid, regions)
        layers.append(("wind_regions", wind_raster, WIND_ASCII_CHARS))
    if which in ("currents", "both"):
        systems = load_currents()
        grid = _world_grid()
        current_raster, _stats = paint_currents(grid, systems)
        layers.append(("currents", current_raster, CURRENT_ASCII_CHARS))

    height = layers[0][1].h
    start, end = (parse_rows(args.rows, height) if args.rows
                  else (1, height))
    for name, raster, chars in layers:
        header = f"# {name} (rows {start}-{end}, chars: '{chars[0]}' none)"
        text = header + "\n" + "\n".join(
            ascii_lines(raster, chars)[start - 1:end]) + "\n"
        if args.ascii_out:
            out = Path(args.ascii_out)
            if DATA.resolve() in out.resolve().parents:
                print(
                    "build_ocean: refusing to write the ASCII debug export "
                    f"under data/ ({out}); use a temp path", file=sys.stderr)
                return 2
            out = out.with_name(f"{out.stem}.{name}{out.suffix}")
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text, encoding="utf-8", newline="\n")
            print(f"build_ocean: wrote {end - start + 1} ASCII rows to {out}",
                  file=sys.stderr)
        else:
            sys.stdout.write(text)
    return 0


def _world_grid() -> bw.Grid:
    decoded = bw.decode_png(WORLD_PNG.read_bytes())
    grid = bw.Grid(decoded["width"], decoded["height"])
    for y in range(decoded["height"]):
        grid.rows[y][:] = decoded["rows"][y]
    return grid


def parse_rows(spec: str, height: int) -> tuple[int, int]:
    if ":" not in spec:
        raise argparse.ArgumentTypeError("--rows wants A:B (1-based, inclusive)")
    left, right = spec.split(":", 1)
    try:
        start, end = int(left), int(right)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"--rows wants integers, got {spec!r}") from exc
    if start < 1 or end < start or end > height:
        raise argparse.ArgumentTypeError(f"--rows {spec!r} outside 1..{height}")
    return start, end


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Build data/maps/wind_regions.png + currents.png from the "
                    "hand-authored ocean sources (deterministic; two builds "
                    "are byte-identical).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--check", action="store_true",
        help="rebuild in memory and byte-compare against the committed "
             "rasters; exit 3 naming the drifted file",
    )
    parser.add_argument(
        "--ascii", action="store_true",
        help="debug export: the raster as one character per tile (stdout "
             "unless --ascii-out is given; never under data/)",
    )
    parser.add_argument(
        "--layer", default="both", metavar="wind|currents|both",
        help="which raster --ascii exports (default: both)",
    )
    parser.add_argument(
        "--rows", metavar="A:B",
        help="1-based inclusive row range for --ascii (default: all rows)",
    )
    parser.add_argument(
        "--ascii-out", metavar="PATH", help="write the ASCII export to PATH",
    )
    parser.add_argument(
        "--report", action="store_true",
        help="print the JSON build report to stdout after the build",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="progress on stderr")
    args = parser.parse_args(argv)

    try:
        if args.ascii:
            return cmd_ascii(args)
        if args.check:
            return cmd_check(args)
        return cmd_build(args)
    except BuildError as exc:
        print(f"build_ocean: FAIL: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
