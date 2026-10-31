#!/usr/bin/env python3
"""build_world.py — deterministic world-map generator (Phase 4, task C).

Rasterizes the public-domain Natural Earth 10 m shorelines in ``tools/assets/``
into ``data/maps/world.png`` (indexed PNG, 1 px = 1 tile) plus
``data/maps/world_report.json``, then snaps every port's harbor tile.

Everything is locked by ``docs/10-DATA-SCHEMA.md`` §6 and the *Locked
constants* table of ``docs/IMPLEMENT-Phase4.md``:

  grid            2160 x 1080 tiles, 6 tiles/degree, lon = x/6 - 180,
                  lat = 90 - y/6 (origin top-left, x east, y south)
  charset         ``~`` sea, ``.`` coastal sea, ``#`` land, ``^`` reef,
                  ``I`` polar ice
  ice rule        ``I`` iff lat >= 70N or lat <= 60S
  coastal band    ``.`` iff within 3 tiles (Chebyshev, wrap-aware in x) of a
                  passable-adjacent land/ice tile
  harbor snap     nearest water tile within 2 tiles (Chebyshev), with >= 1
                  orthogonally adjacent water tile, ties -> smallest (y, x)
  lakes           ``ne_10m_lakes`` rasterized as land (the Caspian is land)

Raster passes, in this exact order (doc-pinned):

  1. land polygon fill      -> ``#`` on land, ``~`` on water
  2. lakes pass             -> lakes also ``#``
  3. ice rule pass          -> ``I``
  4. coastal band pass      -> ``.``
  5. waterway carve pass    -> ``tools/map_overrides.json`` (optional)
     + band refresh        -> ``.`` again, because carving moved the coast
  6. harbor snap pass       -> per-port ``harbor_tile`` in the report

Notes that matter for determinism (``docs/IMPLEMENT-Phase4.md`` -> Risks):

* polygons are consumed in a stable order: shapefile record index, then ring
  index inside the record; nothing is sorted by a hash or iterated out of a
  ``set``/``dict`` where order changes pixels;
* no timestamps, no random data, no machine paths are written to the artifact;
* the vendor inputs are SHA-256 checked on every run and recorded in the
  report, so a drifted shoreline file fails loudly instead of silently
  changing the map.

Pure Python 3 stdlib + the vendored pyshp reader (``tools/vendor/pyshp.py``,
MIT). No numpy, no Pillow; PNG encoding and decoding are hand-rolled with
``zlib`` + ``struct``.

Usage
-----
    python3 tools/build_world.py                     # build the artifact
    python3 tools/build_world.py --report            # build + print the report
    python3 tools/build_world.py --verify            # build + decode the PNG
    python3 tools/build_world.py --ascii             # print the 2160-wide map
    python3 tools/build_world.py --ascii --rows 300:340
    python3 tools/build_world.py --check-snaps data/ports.json
    python3 tools/build_world.py --check-snaps docs/10-DATA-SCHEMA.md  # §7.1 table
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import struct
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
ASSETS = TOOLS / "assets"
VENDOR = TOOLS / "vendor"
DATA_MAPS = ROOT / "data" / "maps"
OVERRIDES_PATH = TOOLS / "map_overrides.json"
PORTS_PATH = ROOT / "data" / "ports.json"
PNG_PATH = DATA_MAPS / "world.png"
REPORT_PATH = DATA_MAPS / "world_report.json"

sys.path.insert(0, str(VENDOR))
import pyshp as shapefile  # noqa: E402  (vendored, MIT — see tools/vendor/)


# --------------------------------------------------------------------------
# Locked constants (docs/10-DATA-SCHEMA.md §6)
# --------------------------------------------------------------------------
DEFAULT_DEGREES_PER_TILE = 1.0 / 6.0  # 6 tiles per degree
LOCKED_GRID_W = 2160
LOCKED_GRID_H = 1080
COASTAL_BAND_TILES = 3
HARBOR_SNAP_TILES = 2
ICE_NORTH_MIN_LAT = 70.0
ICE_SOUTH_MAX_LAT = -60.0

# Palette indices 0-4 are locked and append-only (§6.3): ~ . # ^ I
SEA, COAST, LAND, REEF, ICE = 0, 1, 2, 3, 4
CHARS = "~.#^I"
PALETTE = [
    (0x16, 0x44, 0x6E),  # ~ SEA        docs/80-UI-UX.md §4.8
    (0x2F, 0x6F, 0x9E),  # . COAST_SEA
    (0x7A, 0x5C, 0x2E),  # # LAND
    (0x3D, 0x3D, 0x3D),  # ^ REEF       (no reefs this phase; index reserved)
    (0xC9, 0xD6, 0xDF),  # I ICE
]
PASSABLE = (SEA, COAST)
LAND_OR_ICE = (LAND, ICE)

# Locked waterway must-list (docs/IMPLEMENT-Phase4.md task D, `10-*` §6.1).
# Every one of these must have an entry in ``tools/map_overrides.json``: a
# missing entry seals a sea the 100 ports are required to reach, so the build
# refuses to run rather than shipping an unreachable harbor. Names are the
# report keys and the words every failure message uses.
LOCKED_WATERWAYS = (
    "gibraltar",
    "bosphorus",
    "dardanelles",
    "kerch",
    "messina",
    "oresund",
    "great_belt",
    "bab_el_mandeb",
    "malacca",
    "sunda",
    "magellan",
)

# Source shapefiles, in the fixed order they are rasterized (record order is
# stable inside a file; files are concatenated in this order).
SOURCES = [
    ("ne_10m_land", "land polygon fill"),
    ("ne_10m_minor_islands", "land polygon fill"),
    ("ne_10m_lakes", "lakes pass (as land)"),
]

# SHA-256 of the vendored geometry files — recorded in
# tools/assets/LICENSE-NOTES.md. A mismatch fails the build (drift guard).
EXPECTED_SHA256 = {
    "ne_10m_land.shp": "4cad3a49bc75c1a4c2f3d7efae04f2f8e63151c96764b2658effabf524331fa6",
    "ne_10m_land.shx": "f3b02a190c3020eeafd0f48de982619826b57ecd853cbc68e4fc049652891a04",
    "ne_10m_land.dbf": "e422520372e65c6fb8220888580e5331d04699bcd71c27e53ad42e241a531cbd",
    "ne_10m_minor_islands.shp": "efc446b18c3496c88ccec8cfe937f1af3f3f8c2dd1b63d9722a153b0744f0b48",
    "ne_10m_minor_islands.shx": "6bbc71e9fce78dca5e7b811155a488358250ab72bf66dd0deb9a697e1f572c59",
    "ne_10m_minor_islands.dbf": "f3ecdcdffe964cfbb855c107c0ea39fff38072ad2d5362a06544145a386bc81b",
    "ne_10m_lakes.shp": "11064fa55ed91b56a0d86733643c1a5bfcc137fdf044e83f471978a5b86617e1",
    "ne_10m_lakes.shx": "a11ffb02e862b6c4ec8c015e6e0c70502f21bc71dcd79312b8dbc676f7e4c557",
    "ne_10m_lakes.dbf": "0edaa87f76c2221c986f0796ce0b54b1c418e9032afba46f8e302edc41193495",
}


class BuildError(Exception):
    """A loud, named build failure (exit code 2)."""


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def wrap_x(x: int, width: int) -> int:
    return x % width


def chebyshev_wrap(dx: int, dy: int, width: int) -> int:
    dx = abs(dx) % width
    dx = min(dx, width - dx)
    return max(dx, abs(dy))


class Grid:
    """The tile grid: one ``bytearray`` per row of palette indices."""

    def __init__(self, width: int = LOCKED_GRID_W, height: int = LOCKED_GRID_H):
        self.w = width
        self.h = height
        self.rows = [bytearray([SEA]) * width for _ in range(height)]

    # -- conversion -------------------------------------------------------
    def x_of_lon(self, lon: float) -> float:
        return (lon + 180.0) * self.tiles_per_degree()

    def y_of_lat(self, lat: float) -> float:
        return (90.0 - lat) * self.tiles_per_degree()

    def lat_of_y(self, y: int) -> float:
        return 90.0 - y / self.tiles_per_degree()

    def lon_of_x(self, x: int) -> float:
        return x / self.tiles_per_degree() - 180.0

    def tiles_per_degree(self) -> float:
        return self.w / 360.0

    def tile_of_latlon(self, lat: float, lon: float) -> tuple[int, int]:
        """Grid cell containing a WGS84 point (floor, x wrapped, y clamped)."""
        x = int(math.floor((lon + 180.0) * self.tiles_per_degree())) % self.w
        y = int(math.floor((90.0 - lat) * self.tiles_per_degree()))
        y = min(max(y, 0), self.h - 1)
        return x, y

    # -- access -----------------------------------------------------------
    def get(self, x: int, y: int) -> int:
        return self.rows[y][x % self.w]

    def set(self, x: int, y: int, value: int) -> None:
        self.rows[y][x % self.w] = value

    def is_water(self, x: int, y: int) -> bool:
        return self.rows[y][x % self.w] in PASSABLE

    def has_adjacent_water(self, x: int, y: int) -> bool:
        """>= 1 orthogonally adjacent passable tile (x wraps, y clamps)."""
        if self.is_water(x - 1, y) or self.is_water(x + 1, y):
            return True
        if y > 0 and self.is_water(x, y - 1):
            return True
        if y < self.h - 1 and self.is_water(x, y + 1):
            return True
        return False

    def flat(self) -> bytes:
        return b"".join(self.rows)

    def counts(self) -> list[int]:
        flat = self.flat()
        return [flat.count(bytes([v])) for v in range(5)]

    def ascii_lines(self) -> list[str]:
        table = bytes(
            (ord(CHARS[i]) if i < len(CHARS) else ord("?")) for i in range(256)
        )
        return [bytes(row).translate(table).decode("ascii") for row in self.rows]


# --------------------------------------------------------------------------
# Polygons: rings, unwrapping, scanline fill
# --------------------------------------------------------------------------
def rings_of(shape) -> list:
    """Split a pyshp Polygon into its ``parts`` rings (stable order)."""
    parts = list(shape.parts) + [len(shape.points)]
    return [
        list(shape.points[parts[i]:parts[i + 1]]) for i in range(len(parts) - 1)
    ]


def unwrap_ring(ring) -> list[float]:
    """Longitudes of a ring, made continuous across the antimeridian.

    A polygon that crosses +/-180 is stored with longitudes jumping from
    +179.9 to -179.9; unwrapping picks the nearest continuation (edges are
    always shorter than 180 deg), so the ring can be rasterized in one frame
    and its spans wrapped back into [0, width) at write time.
    """
    lons: list[float] = []
    prev = None
    offset = 0.0
    for lon, _lat in ring:
        value = lon + offset
        if prev is not None:
            while value - prev > 180.0:
                value -= 360.0
                offset -= 360.0
            while value - prev < -180.0:
                value += 360.0
                offset += 360.0
        lons.append(value)
        prev = value
    return lons


def _fill_span(row: bytearray, start: int, width: int, value: int) -> None:
    """Fill ``width`` cells starting at ``start``, wrapping modulo len(row)."""
    size = len(row)
    if width >= size:
        row[:] = bytes([value]) * size
        return
    start %= size
    if start + width <= size:
        row[start:start + width] = bytes([value]) * width
    else:
        head = size - start
        row[start:] = bytes([value]) * head
        row[: width - head] = bytes([value]) * (width - head)


def fill_ring(grid: Grid, ring, value: int) -> int:
    """Scanline-fill the interior of one ring at 1 px = 1 tile.

    Sample points are tile centres (x + 0.5, y + 0.5); every polygon edge
    contributes to each row band it crosses. Spans are written with wrap in x,
    so an antimeridian-crossing ring paints correctly on both sides of the
    seam. Returns the number of row spans written (a rough work measure).
    """
    n = len(ring)
    if n < 3:
        return 0
    lons = unwrap_ring(ring)
    tpd = grid.tiles_per_degree()
    xs = [(lons[i] + 180.0) * tpd for i in range(n)]
    ys = [(90.0 - ring[i][1]) * tpd for i in range(n)]

    y_lo = max(0.0, min(ys))
    y_hi = min(float(grid.h), max(ys))
    if y_hi <= y_lo:
        return 0
    row_lo = max(0, int(math.floor(y_lo - 0.5)))
    row_hi = min(grid.h - 1, int(math.ceil(y_hi - 0.5)))

    # Edges that are not horizontal, normalised top -> bottom.
    edges = []  # (x_at_top, y_top, dx/dy)
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

    spans = 0
    for r in sorted(buckets):
        py = r + 0.5
        crossings = [xa + (py - ya) * slope for (xa, ya, slope) in
                     (edges[i] for i in buckets[r])]
        crossings.sort()
        row = grid.rows[r]
        for i in range(0, len(crossings) - 1, 2):
            c0 = int(math.ceil(crossings[i] - 0.5))
            c1 = int(math.ceil(crossings[i + 1] - 0.5)) - 1
            if c1 < c0:
                continue
            _fill_span(row, c0, c1 - c0 + 1, value)
            spans += 1
    return spans


def rasterize_source(grid: Grid, name: str, value: int) -> dict:
    """Rasterize every polygon of one shapefile as ``value``.

    Rings are filled **individually and OR-ed** (union of ring interiors),
    never with a combined even-odd rule: Natural Earth encodes inland water
    bodies as hole rings inside a land record, and the locked lake rule says
    lakes are land. OR-ing therefore yields "solid land with lakes filled",
    which is exactly the locked rule, and it keeps islands-in-lakes as land
    too. Record/ring order is the shapefile's own (stable for a fixed file).
    """
    path = ASSETS / name
    reader = shapefile.Reader(str(path))
    shapes = reader.shapes()  # record order == file order, stable
    spans = 0
    rings = 0
    before_land = grid.counts()[LAND]
    for shape in shapes:
        for ring in rings_of(shape):
            rings += 1
            spans += fill_ring(grid, ring, value)
    return {"shapefile": name + ".shp", "records": len(shapes),
            "rings": rings, "spans_filled": spans,
            "cells_changed": grid.counts()[LAND] - before_land}


# --------------------------------------------------------------------------
# Bit-plane helpers (fast Chebyshev dilation / masks over 2.3 M tiles)
# --------------------------------------------------------------------------
def row_bits(rows, width: int, wanted) -> list[int]:
    """One big int per row: bit (width-1-x) set iff row[x] in ``wanted``."""
    table = bytes(0x31 if i in wanted else 0x30 for i in range(256))
    bits = []
    for row in rows:
        bits.append(int(bytes(row).translate(table), 2))
    return bits


def rotate_bits(value: int, shift: int, width: int, mask: int) -> int:
    """Rotate a row of bits by ``shift`` (circular in x = longitude wrap)."""
    shift %= width
    if shift == 0:
        return value
    return ((value << shift) | (value >> (width - shift))) & mask


def dilate_bits(bits: list[int], radius: int, width: int) -> list[int]:
    """Chebyshev dilation: wrap-aware in x, clamped in y (no pole wrap)."""
    mask = (1 << width) - 1
    # horizontal, circular
    horiz = []
    for value in bits:
        grown = value
        for _ in range(radius):
            grown |= rotate_bits(grown, 1, width, mask) | rotate_bits(
                grown, width - 1, width, mask
            )
        horiz.append(grown)
    # vertical, clamped
    out = []
    height = len(bits)
    for y in range(height):
        grown = 0
        for dy in range(-radius, radius + 1):
            yy = y + dy
            if 0 <= yy < height:
                grown |= horiz[yy]
        out.append(grown)
    return out


# --------------------------------------------------------------------------
# Raster passes
# --------------------------------------------------------------------------
def pass_ice(grid: Grid) -> dict:
    """``I`` iff lat >= 70N or lat <= 60S, exactly from y (locked).

    Latitude is derived from ``y`` per the locked projection: the tile's
    latitude is ``90 - y/6`` (its north edge), so the 70N boundary lands on
    row 120 inclusive and the 60S boundary on row 900 inclusive. Both
    boundaries are checked exactly, no fudge rows.
    """
    tpd = grid.tiles_per_degree()
    # lat = 90 - y/tpd  =>  y = (90 - lat) * tpd
    north_last = int(math.floor((90.0 - ICE_NORTH_MIN_LAT) * tpd))  # y <= 120
    south_first = int(math.ceil((90.0 - ICE_SOUTH_MAX_LAT) * tpd))  # y >= 900
    north_rows = list(range(0, min(grid.h, north_last + 1)))
    south_rows = list(range(min(grid.h, south_first), grid.h))
    ice_row = bytes([ICE]) * grid.w
    for y in north_rows + south_rows:
        grid.rows[y][:] = ice_row
    return {
        "rule": "lat >= 70.0 or lat <= -60.0",
        "north_rows_inclusive": [north_rows[0], north_rows[-1]] if north_rows else None,
        "south_rows_inclusive": [south_rows[0], south_rows[-1]] if south_rows else None,
        "north_rows": len(north_rows),
        "south_rows": len(south_rows),
        "rows": len(north_rows) + len(south_rows),
        "ice_tiles": (len(north_rows) + len(south_rows)) * grid.w,
    }


def pass_coastal_band(grid: Grid, radius: int = COASTAL_BAND_TILES,
                      exact: bool = False) -> dict:
    """``.`` iff within ``radius`` tiles of a passable-adjacent land/ice tile.

    ``exact`` recomputes both directions (``.`` -> ``~`` where the band moved
    away as well as ``~`` -> ``.`` where it arrived). The first pass only adds,
    which is right for a grid that starts all-sea; the post-carve refresh uses
    ``exact`` so the artifact still satisfies the locked definition after a
    carve has removed land.
    """
    width = grid.w
    landice = row_bits(grid.rows, width, LAND_OR_ICE)
    water = row_bits(grid.rows, width, PASSABLE)
    mask = (1 << width) - 1
    # A "coast source" tile is land/ice with >= 1 orthogonally adjacent water.
    coast = []
    for y in range(grid.h):
        near = rotate_bits(water[y], 1, width, mask) | rotate_bits(
            water[y], width - 1, width, mask
        )
        if y > 0:
            near |= water[y - 1]
        if y < grid.h - 1:
            near |= water[y + 1]
        coast.append(landice[y] & near)
    band = dilate_bits(coast, radius, width)

    added = 0
    reverted = 0
    for y in range(grid.h):
        value = band[y]
        row = grid.rows[y]
        if not exact and not value:
            continue
        if exact:
            for x in range(width):
                if row[x] not in PASSABLE:
                    continue
                inside = (value >> (width - 1 - x)) & 1
                if inside and row[x] == SEA:
                    row[x] = COAST
                    added += 1
                elif not inside and row[x] == COAST:
                    row[x] = SEA
                    reverted += 1
            continue
        while value:
            low = value & -value
            x = width - 1 - (low.bit_length() - 1)
            value ^= low
            if row[x] == SEA:
                row[x] = COAST
                added += 1
    result = {"band_tiles": radius, "cells_changed": added}
    if exact:
        result["cells_reverted"] = reverted
    return result


# --------------------------------------------------------------------------
# Waterway overrides
# --------------------------------------------------------------------------
def load_overrides(path: Path) -> list[dict]:
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BuildError(f"map_overrides: {path} is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("overrides"), list):
        raise BuildError(
            f"map_overrides: {path} must be an object with an 'overrides' array"
        )
    entries = []
    seen = set()
    for i, raw in enumerate(payload["overrides"]):
        if not isinstance(raw, dict):
            raise BuildError(f"map_overrides: entry #{i} is not an object")
        name = raw.get("name")
        if not isinstance(name, str) or not name:
            raise BuildError(f"map_overrides: entry #{i} has no non-empty 'name'")
        if name in seen:
            raise BuildError(f"map_overrides: duplicate override name '{name}'")
        seen.add(name)
        path_pts = raw.get("path")
        if not isinstance(path_pts, list) or len(path_pts) < 2:
            raise BuildError(
                f"map_overrides: '{name}' needs 'path' with >= 2 [lat, lon] points"
            )
        pts = []
        for j, point in enumerate(path_pts):
            if (
                not isinstance(point, list)
                or len(point) != 2
                or not all(isinstance(v, (int, float)) for v in point)
            ):
                raise BuildError(
                    f"map_overrides: '{name}' path point #{j} must be [lat, lon]"
                )
            lat, lon = float(point[0]), float(point[1])
            if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                raise BuildError(
                    f"map_overrides: '{name}' path point #{j} out of range: {point}"
                )
            pts.append((lat, lon))
        width = raw.get("min_width_tiles", 1)
        if not isinstance(width, int) or isinstance(width, bool) or width < 1:
            raise BuildError(
                f"map_overrides: '{name}' min_width_tiles must be an int >= 1"
            )
        entries.append({"name": name, "path": pts, "min_width_tiles": width})
    return entries


def _segments_xy(grid: Grid, pts):
    tpd = grid.tiles_per_degree()
    xy = [((lon + 180.0) * tpd, (90.0 - lat) * tpd) for lat, lon in pts]
    # unwrap the polyline in x so a dateline-crossing path stays continuous
    out = [xy[0]]
    for i in range(1, len(xy)):
        x, y = xy[i]
        prev = out[-1][0]
        while x - prev > grid.w / 2.0:
            x -= grid.w
        while x - prev < -grid.w / 2.0:
            x += grid.w
        out.append((x, y))
    return out


def _channel_radius(width: int) -> int:
    """Chebyshev radius realising at least ``width`` tiles: 2r+1 >= width."""
    return width // 2


def _chain_tiles(grid: Grid, xy) -> list[tuple[int, int]]:
    """Ordered, 4-connected tile chain that follows the polyline.

    The polyline is walked at 1/20-tile resolution and mapped to tiles; when
    the tile changes diagonally the intermediate orthogonal tile is inserted,
    so consecutive chain tiles are always 4-adjacent. That makes a
    ``min_width_tiles = 1`` channel contiguous by construction instead of
    hoping a sampled point lands in every tile the line clips.
    """
    chain: list[tuple[int, int]] = []

    def add(x: int, y: int) -> None:
        x %= grid.w
        y = min(max(y, 0), grid.h - 1)
        if not chain or chain[-1] != (x, y):
            chain.append((x, y))

    def walk(cx: float, cy: float) -> None:
        add(int(math.floor(cx)), int(math.floor(cy)))

    prev = (int(math.floor(xy[0][0])), int(math.floor(xy[0][1])))
    walk(xy[0][0], xy[0][1])
    for i in range(len(xy) - 1):
        x0, y0 = xy[i]
        x1, y1 = xy[i + 1]
        steps = max(1, int(math.ceil(max(abs(x1 - x0), abs(y1 - y0)) * 20)))
        for step in range(1, steps + 1):
            t = step / steps
            cx = x0 + (x1 - x0) * t
            cy = y0 + (y1 - y0) * t
            tile = (int(math.floor(cx)), int(math.floor(cy)))
            if tile == prev:
                continue
            # bridge diagonals with an orthogonal step (4-connectivity)
            tx, ty = tile
            px, py = prev
            if tx != px and ty != py:
                add(tx, py)
            add(tx, ty)
            prev = tile
    return chain


def channel_tiles(grid: Grid, entry: dict) -> list[tuple[int, int]]:
    """Every tile the override's channel occupies (chain dilated by radius)."""
    radius = _channel_radius(entry["min_width_tiles"])
    chain = _chain_tiles(grid, _segments_xy(grid, entry["path"]))
    if radius == 0:
        return chain
    cells: list[tuple[int, int]] = []
    seen: set[tuple[int, int]] = set()
    for x, y in chain:
        for dy in range(-radius, radius + 1):
            yy = y + dy
            if not (0 <= yy < grid.h):
                continue
            for dx in range(-radius, radius + 1):
                key = ((x + dx) % grid.w, yy)
                if key not in seen:
                    seen.add(key)
                    cells.append(key)
    return cells


def carve_override(grid: Grid, entry: dict) -> dict:
    """Carve water over the override's channel tiles."""
    cells = channel_tiles(grid, entry)
    changed = 0
    for x, y in cells:
        row = grid.rows[y]
        if row[x] not in PASSABLE:
            row[x] = SEA
            changed += 1
    return {"cells_changed": changed, "channel_tiles": len(cells)}


def verify_override(grid: Grid, entry: dict) -> dict:
    """Assert the carved channel is water, wide enough, and joins a real sea.

    Named failures:
    * a channel tile that is not water (the carve did not take);
    * a channel tile whose perpendicular water run is narrower than
      ``min_width_tiles`` (a neighbouring override or coastline ate it);
    * a channel tile that does not reach the open sea — i.e. the carve made an
      inland lake instead of a waterway.

    The caller also checks, *before* carving, that the path is anchored in
    water at one end (``verify_anchor``); together with the open-sea check that
    is what stops a path drawn through the middle of a continent from passing:
    carving it would otherwise manufacture a corridor that "connects" its own
    two ends and prove nothing.
    """
    width = entry["min_width_tiles"]
    name = entry["name"]
    cells = channel_tiles(grid, entry)
    for x, y in cells:
        if not grid.is_water(x, y):
            raise BuildError(
                f"override '{name}': waterway is not water at tile ({x}, {y}) "
                f"[{CHARS[grid.rows[y][x]]}], lat {grid.lat_of_y(y):.2f} "
                f"lon {grid.lon_of_x(x):.2f}"
            )

    # width: perpendicular water run through each channel tile
    for x, y in cells:
        best = 0
        for dx, dy in ((1, 0), (0, 1)):
            run = 1
            for sign in (1, -1):
                k = 1
                while k <= width + 2:
                    yy = y + dy * k * sign
                    if yy < 0 or yy >= grid.h:
                        break
                    if not grid.is_water((x + dx * k * sign) % grid.w, yy):
                        break
                    k += 1
                run += k - 1
            best = max(best, run)
        if best < width:
            raise BuildError(
                f"override '{name}': channel narrower than {width} tiles at "
                f"tile ({x}, {y}) [width {best}]"
            )

    ocean = open_sea_mask(grid)
    for x, y in cells:
        if not ocean[y * grid.w + x]:
            raise BuildError(
                f"override '{name}': carved channel does not reach open sea at "
                f"tile ({x}, {y}), lat {grid.lat_of_y(y):.2f} "
                f"lon {grid.lon_of_x(x):.2f} — the entry makes an inland lake, "
                f"not a waterway"
            )
    return {
        "name": name,
        "min_width_tiles": width,
        "realised_width_tiles": 2 * _channel_radius(width) + 1,
        "path_points": len(entry["path"]),
        "channel_tiles": len(cells),
        "reaches_open_sea": True,
    }


def verify_anchor(grid: Grid, entry: dict) -> bool:
    """Pre-carve check: at least one end of the path must already be water.

    A waterway carve is a correction of a too-narrow real strait, so it must
    start (or finish) in a real sea. A path with both ends on land is either a
    typo or an invented passage; carving it would "succeed" at every later
    check and silently be wrong. Tidal-river entries deliberately keep their
    inland end on land (the river is the point) — hence "at least one".
    """
    chain = _chain_tiles(grid, _segments_xy(grid, entry["path"]))
    ends = (chain[0], chain[-1])
    if not any(grid.is_water(x, y) for x, y in ends):
        raise BuildError(
            f"override '{entry['name']}': neither end of the path is water "
            f"({ends[0]} and {ends[1]} are both land) — a waterway must be "
            f"anchored in a real sea"
        )
    return True


def assert_locked_waterways(overrides: list[dict]) -> None:
    """Every locked waterway must be present in ``map_overrides.json``.

    The must-list is pinned by the docs: each of those straits is narrower than
    one 10 nm tile in the source shoreline, so *removing* its entry seals a sea
    that locked ports sit in (Bosphorus -> Istanbul, Oresund/Great Belt ->
    Danzig/Stockholm, Bab-el-Mandeb -> Aden, Malacca/Sunda -> Nagasaki, ...).
    This is the "builder asserts every locked waterway" half of task D: a build
    that silently ships a sealed sea is worse than a failed build.

    ``tools/map_overrides.json`` may legitimately hold **extra** entries (the
    tidal-river clauses); only the must-list is mandatory.
    """
    present = {entry["name"] for entry in overrides}
    missing = [name for name in LOCKED_WATERWAYS if name not in present]
    if missing:
        raise BuildError(
            "map_overrides: locked waterway(s) missing from "
            f"{OVERRIDES_PATH.relative_to(ROOT)}: {', '.join(missing)} — each "
            "one is a sea passage narrower than a tile, so omitting it seals a "
            "sea that locked ports must be able to reach"
        )


def assert_harbors_on_ocean(grid: Grid, port_results: list[dict]) -> None:
    """Every harbor tile must be on the dominant component (sailable sea).

    The snap rule only promises *water next to water*: a harbor in a sealed
    basin satisfies it while no fleet can ever reach it. That is exactly the
    "straits narrower than a tile seal seas" risk, so the builder asserts it
    here and names the stranded port — F's validator then re-proves the same
    property with its own BFS from Lisbon.
    """
    ocean = open_sea_mask(grid)
    stranded = []
    for entry in port_results:
        tile = entry.get("harbor_tile")
        if not tile:
            continue
        if not ocean[tile["y"] * grid.w + tile["x"]]:
            stranded.append(f"{entry['id']} at ({tile['x']}, {tile['y']})")
    if stranded:
        raise BuildError(
            "harbor snap: "
            f"{len(stranded)} harbor tile(s) are not on the open sea — a "
            "sealed basin (a missing or too-narrow waterway carve): "
            + ", ".join(stranded)
        )


# --------------------------------------------------------------------------
# Components (passable tiles)
# --------------------------------------------------------------------------
_OPEN_SEA_ATTR = "_open_sea_mask"


def open_sea_mask(grid: Grid) -> bytearray:
    """Bitmask of the dominant passable component (the world ocean).

    Every waterway carve must land in this component: a carved channel that
    only reaches a landlocked puddle — or a basin that some *other* missing
    waterway has sealed off — is not a passage. The mask is memoised on the
    grid because the waterway pass asks once per entry.
    """
    cached = getattr(grid, _OPEN_SEA_ATTR, None)
    if cached is not None:
        return cached
    width, height = grid.w, grid.h
    rows = grid.rows
    components = passable_components(grid, min_report=0)
    dominant = components["largest_example_tile"]
    mask = bytearray(width * height)
    if dominant is None:
        setattr(grid, _OPEN_SEA_ATTR, mask)
        return mask
    y0, x0 = dominant["y"], dominant["x"]
    mask[y0 * width + x0] = 1
    stack = [(x0, y0)]
    while stack:
        x, y = stack.pop()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            xx = (x + dx) % width
            yy = y + dy
            if yy < 0 or yy >= height:
                continue
            idx = yy * width + xx
            if mask[idx] or rows[yy][xx] not in PASSABLE:
                continue
            mask[idx] = 1
            stack.append((xx, yy))
    setattr(grid, _OPEN_SEA_ATTR, mask)
    return mask


def passable_components(grid: Grid, min_report: int = 2000) -> dict:
    """Connected components of passable tiles, wrap-aware in x.

    Connectivity law: 4-connected. That is *identical* to the runtime rule
    (8-directional with corner-cutting forbidden) for the purpose of "which
    tiles can a fleet reach": a legal diagonal step only happens when both
    orthogonal neighbours of the corner are passable, so the two diagonal
    neighbours are already joined through one of them. 4-connectivity is
    therefore the same partition and much cheaper to compute.

    Run-length union-find over rows, with the x = 0 / x = w-1 join applied per
    row (and the vertical join only where runs overlap).
    """
    width = grid.w
    parent: list[int] = []
    size: list[int] = []
    example: list[tuple[int, int]] = []

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if size[ra] < size[rb]:
            ra, rb = rb, ra
        parent[rb] = ra
        size[ra] += size[rb]
        if example[rb] < example[ra]:
            example[ra] = example[rb]

    def runs_of(row: bytearray) -> list[tuple[int, int]]:
        runs = []
        x = 0
        while x < width:
            if row[x] in PASSABLE:
                start = x
                while x < width and row[x] in PASSABLE:
                    x += 1
                runs.append((start, x - 1))
            else:
                x += 1
        return runs

    prev: list[tuple[int, int]] = []
    prev_labels: list[int] = []
    for y in range(grid.h):
        runs = runs_of(grid.rows[y])
        labels = []
        for (a, b) in runs:
            parent.append(len(parent))
            size.append(b - a + 1)
            example.append((y, a))
            labels.append(len(parent) - 1)

        # vertical joins: runs of consecutive rows overlap in at least one column
        j = 0
        for r, (a, b) in enumerate(runs):
            while j < len(prev) and prev[j][1] < a:
                j += 1
            k = j
            while k < len(prev) and prev[k][0] <= b:
                union(labels[r], prev_labels[k])
                k += 1

        # horizontal wrap: first and last run of a row are neighbours
        if len(runs) > 1 and runs[0][0] == 0 and runs[-1][1] == width - 1:
            union(labels[0], labels[-1])

        prev, prev_labels = runs, labels

    roots: dict[int, int] = {}
    for i in range(len(parent)):
        root = find(i)
        if root not in roots:
            roots[root] = size[root]

    components = []
    for root, total in roots.items():
        if total > min_report:
            components.append(
                {"size": total,
                 "example_tile": {"x": example[root][1], "y": example[root][0]}}
            )
    components.sort(key=lambda c: (-c["size"], c["example_tile"]["y"],
                                   c["example_tile"]["x"]))
    largest = components[0]["example_tile"] if components else None
    if roots and largest is None:
        root = max(roots, key=lambda r: roots[r])
        y, x = example[root]
        largest = {"x": x, "y": y}
    return {
        "count": len(roots),
        "passable_tiles": sum(roots.values()),
        "over_2000": components,
        "over_1000000": [c for c in components if c["size"] > 1_000_000],
        "largest_example_tile": largest,
    }


# --------------------------------------------------------------------------
# Harbor snap
# --------------------------------------------------------------------------
def snap_harbor(grid: Grid, lat: float, lon: float,
                radius: int = HARBOR_SNAP_TILES):
    """Locked harbor rule (§6.1): water, adjacent water, ties -> smallest (y, x).

    Returns ``(x, y, distance)`` or ``None`` when nothing satisfies the rule.
    This is the **berth** half only; [func snap_harbor_with_shore] adds the
    harbor-pair requirement (20-* §4.11.1).
    """
    px, py = grid.tile_of_latlon(lat, lon)
    candidates = []
    for dy in range(-radius, radius + 1):
        y = py + dy
        if not (0 <= y < grid.h):
            continue
        for dx in range(-radius, radius + 1):
            x = (px + dx) % grid.w
            distance = chebyshev_wrap(dx, dy, grid.w)
            candidates.append((distance, y, x))
    # exact locked order: distance, then smallest y, then smallest x
    candidates.sort()
    for distance, y, x in candidates:
        if grid.is_water(x, y) and grid.has_adjacent_water(x, y):
            return x, y, distance
    return None


def shore_of_berth(grid: Grid, x: int, y: int, origin: tuple[int, int]):
    """Shore tile of a berth (20-* §4.11.1): ``(sx, sy, distance)`` or ``None``.

    The nearest orthogonally adjacent ``#`` tile to the port's derived origin
    tile (wrap-aware Chebyshev in x), tie-breaking to the smallest ``(y, x)``.
    """
    ox, oy = origin
    candidates = []
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        yy = y + dy
        if not (0 <= yy < grid.h):
            continue
        xx = (x + dx) % grid.w
        if grid.get(xx, yy) != LAND:
            continue
        candidates.append((chebyshev_wrap(xx - ox, yy - oy, grid.w), yy, xx))
    if not candidates:
        return None
    candidates.sort()
    distance, sy, sx = candidates[0]
    return sx, sy, distance


def snap_harbor_with_shore(grid: Grid, lat: float, lon: float,
                           radius: int = HARBOR_SNAP_TILES):
    """The harbor-pair snap (20-* §4.11.1): the §6.1 berth plus a shore tile.

    Candidates keep the locked ``(distance, y, x)`` order, so every port whose
    plain §6.1 berth already has an orthogonally adjacent ``#`` keeps exactly
    that tile. Returns ``(x, y, distance, shore)`` (``shore`` = ``(sx, sy)``) or
    ``None`` when nothing inside the radius has a shore tile.
    """
    px, py = grid.tile_of_latlon(lat, lon)
    candidates = []
    for dy in range(-radius, radius + 1):
        y = py + dy
        if not (0 <= y < grid.h):
            continue
        for dx in range(-radius, radius + 1):
            x = (px + dx) % grid.w
            candidates.append((chebyshev_wrap(dx, dy, grid.w), y, x))
    candidates.sort()
    for distance, y, x in candidates:
        if not (grid.is_water(x, y) and grid.has_adjacent_water(x, y)):
            continue
        shore = shore_of_berth(grid, x, y, (px, py))
        if shore is None:
            continue
        return x, y, distance, (shore[0], shore[1])
    return None


def snap_ports(grid: Grid, ports: list[dict]) -> tuple[list[dict], list[str]]:
    results = []
    failures = []
    for port in ports:
        pid = port.get("id", "<no-id>")
        lat = port.get("lat")
        lon = port.get("lon")
        if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
            failures.append(f"{pid}  missing lat/lon")
            results.append({"id": pid, "lat": lat, "lon": lon,
                            "harbor_tile": None, "shore_tile": None,
                            "distance": None})
            continue
        snapped = snap_harbor_with_shore(grid, float(lat), float(lon))
        if snapped is None:
            px, py = grid.tile_of_latlon(float(lat), float(lon))
            plain = snap_harbor(grid, float(lat), float(lon))
            if plain is not None:
                # The precise failure the harbor-pair rule exists to catch.
                failures.append(
                    f"{pid}  berth ({plain[0]}, {plain[1]}) has no "
                    f"orthogonally adjacent '#' shore tile within "
                    f"{HARBOR_SNAP_TILES} tiles of port tile ({px}, {py})"
                )
            else:
                failures.append(
                    f"{pid}  no water within {HARBOR_SNAP_TILES} tiles "
                    f"(port tile {px}, {py})"
                )
            results.append({"id": pid, "lat": lat, "lon": lon,
                            "harbor_tile": None, "shore_tile": None,
                            "distance": None})
        else:
            x, y, distance, shore = snapped
            results.append({"id": pid, "lat": lat, "lon": lon,
                            "harbor_tile": {"x": x, "y": y},
                            "shore_tile": {"x": shore[0], "y": shore[1]},
                            "distance": distance})
    return results, failures


def duplicate_harbors(results: list[dict]) -> list[str]:
    seen: dict[tuple[int, int], str] = {}
    dupes = []
    for entry in results:
        tile = entry.get("harbor_tile")
        if not tile:
            continue
        key = (tile["x"], tile["y"])
        if key in seen:
            dupes.append(f"{entry['id']} and {seen[key]} share harbor tile {key}")
        else:
            seen[key] = entry["id"]
    return dupes


def duplicate_shores(results: list[dict]) -> list[str]:
    """Two ports may not share a shore tile: only one could be docked into."""
    seen: dict[tuple[int, int], str] = {}
    dupes = []
    for entry in results:
        tile = entry.get("shore_tile")
        if not tile:
            continue
        key = (tile["x"], tile["y"])
        if key in seen:
            dupes.append(f"{entry['id']} and {seen[key]} share shore tile {key}")
        else:
            seen[key] = entry["id"]
    return dupes


# --------------------------------------------------------------------------
# PNG encoding / decoding (hand-rolled, stdlib only)
# --------------------------------------------------------------------------
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def encode_png(grid: Grid) -> bytes:
    """Indexed-colour PNG: colour type 3, bit depth 8, no interlace, filter 0.

    Bytes are deterministic for a given grid: no tIME chunk, no text chunks,
    a fixed palette order and one fixed zlib compression setting.
    """
    raw = bytearray()
    for row in grid.rows:
        raw.append(0)  # filter type 0 (None) per scanline
        raw += row
    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(
        ">IIBBBBB", grid.w, grid.h, 8, 3, 0, 0, 0  # depth, colour, comp, filt, ilace
    )
    plte = bytes(channel for rgb in PALETTE for channel in rgb)
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"PLTE", plte)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def decode_png(data: bytes) -> dict:
    """Minimal indexed-PNG reader (stdlib only), used by ``--verify``."""
    if not data.startswith(PNG_SIGNATURE):
        raise BuildError("png: bad signature")
    pos = len(PNG_SIGNATURE)
    header = None
    palette = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise BuildError(f"png: bad CRC in chunk {tag!r}")
        pos += 12 + length
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break
    if header is None:
        raise BuildError("png: no IHDR")
    width, height, depth, colour, compression, filt, interlace = header
    if colour != 3 or depth != 8:
        raise BuildError(f"png: expected indexed 8-bit, got type {colour} depth {depth}")
    if compression != 0 or filt != 0 or interlace != 0:
        raise BuildError("png: unsupported compression/filter/interlace")
    raw = zlib.decompress(bytes(idat))
    stride = width + 1
    if len(raw) != stride * height:
        raise BuildError(
            f"png: IDAT length {len(raw)} != {stride * height} for {width}x{height}"
        )
    rows = []
    for y in range(height):
        start = y * stride
        if raw[start] != 0:
            raise BuildError(f"png: row {y} uses filter {raw[start]}, expected 0")
        rows.append(bytearray(raw[start + 1:start + stride]))
    return {"width": width, "height": height, "colour_type": colour,
            "bit_depth": depth, "interlace": interlace,
            "palette": [tuple(palette[i:i + 3]) for i in range(0, len(palette), 3)],
            "rows": rows}


# --------------------------------------------------------------------------
# Ports loading (JSON or the §7.1 markdown table)
# --------------------------------------------------------------------------
_ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")


def load_ports(path: Path) -> list[dict]:
    """Read ports as ``[{id, lat, lon}]`` from JSON or the §7.1 markdown table.

    The markdown form is the §7.1 locked table itself (``docs/10-DATA-SCHEMA.md``),
    so the W2 preflight can run before `ports.json` is migrated by task E:
    columns are ``id | zh | en | nation | lat | lon | produces | demands``.
    """
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() in (".md", ".markdown"):
        # Limit to the §7.1 ports table: other §7 tables also look tabular.
        match = re.search(r"^###\s*7\.1\b.*?(?=^###\s|\Z)", text,
                          re.MULTILINE | re.DOTALL)
        section = match.group(0) if match else text
        ports = []
        for line in section.splitlines():
            row = line.strip()
            if not row.startswith("|"):
                continue
            cells = [c.strip() for c in row.strip("|").split("|")]
            if len(cells) < 6 or not _ID_RE.match(cells[0]):
                continue
            try:
                lat, lon = float(cells[4]), float(cells[5])
            except ValueError:
                continue
            ports.append({"id": cells[0], "lat": lat, "lon": lon})
        if not ports:
            raise BuildError(f"ports: no §7.1 table rows found in {path}")
        return ports
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise BuildError(f"ports: {path} is not valid JSON: {exc}") from exc
    if isinstance(payload, dict):
        ports = payload.get("ports")
        if ports is None:
            ports = payload.get("data")
    else:
        ports = payload
    if not isinstance(ports, list) or not ports:
        raise BuildError(f"ports: {path} has no 'ports' array")
    out = []
    for entry in ports:
        if not isinstance(entry, dict):
            raise BuildError(f"ports: {path} contains a non-object entry")
        out.append({"id": entry.get("id"), "lat": entry.get("lat"),
                    "lon": entry.get("lon")})
    return out


def ports_have_coords(ports: list[dict]) -> bool:
    return bool(ports) and all(
        isinstance(p.get("lat"), (int, float))
        and isinstance(p.get("lon"), (int, float))
        for p in ports
    )


def resolve_build_ports(verbose: bool = False) -> tuple[list[dict], str]:
    """Ports for the harbor-snap pass, with the W2 fallback made explicit.

    ``data/ports.json`` is the shipped truth once task E adds ``lat``/``lon``.
    Until then the file still carries the pre-Phase-4 schema (no coordinates),
    and the locked source of coordinates is ``docs/10-DATA-SCHEMA.md`` §7.1 —
    so the builder falls back to that table and says so. This keeps the world
    artifact buildable in W2 and disappears on its own when E lands.
    """
    if PORTS_PATH.exists():
        ports = load_ports(PORTS_PATH)
        if ports_have_coords(ports):
            return ports, "data/ports.json"
        print(
            f"build_world: {PORTS_PATH.relative_to(ROOT)} has no lat/lon yet "
            f"(task E migrates it); falling back to the §7.1 table in "
            f"docs/10-DATA-SCHEMA.md for the harbor-snap pass",
            file=sys.stderr,
        )
    else:
        print(f"build_world: {PORTS_PATH.relative_to(ROOT)} missing; using the "
              f"§7.1 table in docs/10-DATA-SCHEMA.md", file=sys.stderr)
    table = ROOT / "docs" / "10-DATA-SCHEMA.md"
    ports = load_ports(table)
    if verbose:
        print(f"  ports source: {table.relative_to(ROOT)} "
              f"({len(ports)} rows)", file=sys.stderr)
    return ports, "docs/10-DATA-SCHEMA.md#7.1"


# --------------------------------------------------------------------------
# Grid build (the six passes)
# --------------------------------------------------------------------------
def grid_dimensions(degrees_per_tile: float) -> tuple[int, int]:
    """Grid size for a tiles-per-degree value, validated against the lock."""
    if not math.isfinite(degrees_per_tile) or degrees_per_tile <= 0.0:
        raise BuildError(f"--degrees-per-tile must be a positive number, got "
                         f"{degrees_per_tile!r}")
    width = round(360.0 / degrees_per_tile)
    height = round(180.0 / degrees_per_tile)
    # accept values that round to the locked grid (e.g. 0.16666666666), reject
    # anything that genuinely yields another size
    if (width, height) != (LOCKED_GRID_W, LOCKED_GRID_H):
        raise BuildError(
            f"--degrees-per-tile {degrees_per_tile!r} does not produce the locked "
            f"{LOCKED_GRID_W}x{LOCKED_GRID_H} grid (got {width}x{height}); the "
            f"only valid value is 1/6 (= {1.0 / 6.0!r})"
        )
    if abs(degrees_per_tile * LOCKED_GRID_W - 360.0) > 1e-4:
        raise BuildError(
            f"--degrees-per-tile {degrees_per_tile!r} is not within 1e-4 of "
            f"1/6 (= {1.0 / 6.0!r}); the grid spacing would drift from the "
            f"locked projection"
        )
    return width, height


def build_grid(degrees_per_tile: float, verbose: bool = False) -> tuple[Grid, dict]:
    width, height = grid_dimensions(degrees_per_tile)

    started = time.time()
    sources = []
    for filename in sorted(EXPECTED_SHA256):
        path = ASSETS / filename
        if not path.exists():
            raise BuildError(f"missing vendored source {path}")
        digest = sha256_file(path)
        if digest != EXPECTED_SHA256[filename]:
            raise BuildError(
                f"vendor drift: {filename} sha256 {digest} != expected "
                f"{EXPECTED_SHA256[filename]} (see tools/assets/LICENSE-NOTES.md)"
            )
        sources.append({"file": filename, "bytes": path.stat().st_size,
                        "sha256": digest})

    grid = Grid(width, height)

    # Pass 1 + 2: land fill, then lakes as land.
    source_runs = []
    for name, purpose in SOURCES:
        if name == "ne_10m_lakes":
            continue
        stats = rasterize_source(grid, name, LAND)
        stats["pass"] = purpose
        source_runs.append(stats)
        if verbose:
            print(f"  land: {name}: {stats['records']} records, "
                  f"{stats['rings']} rings, {stats['cells_changed']} cells",
                  file=sys.stderr)
    # Snapshot the coastline mask before the ice/band passes: the doc's
    # land-fraction sanity gate (25-35 %) is about the shoreline rasterization,
    # and the ice pass deliberately overwrites polar land.
    land_before_ice = grid.counts()[LAND]
    lakes = rasterize_source(grid, "ne_10m_lakes", LAND)
    lakes["pass"] = "lakes pass (as land)"
    lakes["cells_changed"] = grid.counts()[LAND] - land_before_ice
    if lakes["cells_changed"] == 0:
        lakes["note"] = (
            "no cells changed: Natural Earth encodes inland water as hole rings "
            "inside the land records and the fill unions ring interiors, so "
            "lakes are already land before this pass (the locked lake rule). "
            "The pass still runs and re-asserts them."
        )
    land_mask_tiles = grid.counts()[LAND]
    source_runs.append(lakes)
    if verbose:
        print(f"  lakes: {lakes['records']} records, {lakes['rings']} rings, "
              f"{lakes['cells_changed']} cells re-asserted land", file=sys.stderr)

    # Pass 3: ice.
    ice = pass_ice(grid)
    # Pass 4: coastal band.
    band = pass_coastal_band(grid, COASTAL_BAND_TILES)
    # Pass 5: waterway carves, then a band refresh: carving turns land into
    # water, so the coast moved and the locked `.` band must follow it before
    # the harbor snap runs (a carved channel through a headland would
    # otherwise stay open-sea `~` while the doc says shallow `.`).
    overrides = load_overrides(OVERRIDES_PATH)
    assert_locked_waterways(overrides)
    # Pre-carve anchor check: every waterway must start or end in water that
    # already exists, so a path drawn across a continent cannot "succeed".
    for entry in overrides:
        verify_anchor(grid, entry)
    override_cells: dict[str, int] = {}
    override_details = []
    for entry in overrides:
        carved = carve_override(grid, entry)
        override_cells[entry["name"]] = carved["cells_changed"]
        override_details.append({"name": entry["name"], **carved})
    # Asserts run after *every* carve so one channel may lean on another (the
    # Dardanelles' Aegean end, say, may only be water once a neighbour lands).
    for entry, detail in zip(overrides, override_details):
        detail.update(verify_override(grid, entry))
        if verbose:
            print(f"  override {entry['name']}: "
                  f"{detail['cells_changed']} cells carved, path ok",
                  file=sys.stderr)
    band_refresh = pass_coastal_band(grid, COASTAL_BAND_TILES, exact=True)
    if verbose:
        print(f"  band refresh after carves: {band_refresh['cells_changed']} "
              f"cells became coastal", file=sys.stderr)


    elapsed = time.time() - started
    meta = {
        "degrees_per_tile": degrees_per_tile,
        "grid": {"width": width, "height": height},
        "tiles_per_degree": grid.tiles_per_degree(),
        "charset": CHARS,
        "palette_index_order": list(CHARS),
        "ice": ice,
        "coastal_band": band,
        "coastal_band_refresh": band_refresh,
        "harbor_snap_radius_tiles": HARBOR_SNAP_TILES,
        "lakes_as_land": True,
        "sources": sources,
        "source_passes": source_runs,
        "overrides": override_cells,
        "override_details": override_details,
        "land_mask_tiles": land_mask_tiles,
        "raster_seconds": elapsed,  # stderr only — never written to the report
    }
    return grid, meta


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
def build_report(grid: Grid, meta: dict, ports: list[dict],
                 port_results: list[dict]) -> dict:
    counts = grid.counts()
    total = grid.w * grid.h
    components = passable_components(grid)

    def frac(value: int) -> float:
        return round(value / total, 6)

    return {
        "version": 1,
        "generated_by": "tools/build_world.py",
        "artifact": "data/maps/world.png",
        "build": {
            "degrees_per_tile": meta["degrees_per_tile"],
            "grid": meta["grid"],
            "tiles_per_degree": meta["tiles_per_degree"],
            "charset": meta["charset"],
            "palette_index_order": meta["palette_index_order"],
            "ice_rule": {
                "expression": "lat >= 70.0 or lat <= -60.0",
                "north_rows_inclusive": meta["ice"]["north_rows_inclusive"],
                "south_rows_inclusive": meta["ice"]["south_rows_inclusive"],
                "rows": meta["ice"]["rows"],
            },
            "coastal_band_tiles": meta["coastal_band"]["band_tiles"],
            "coastal_band_refresh_cells":
                meta["coastal_band_refresh"]["cells_changed"],
            "coastal_band_refresh_reverted": meta["coastal_band_refresh"].get(
                "cells_reverted", 0),
            "locked_waterways": list(LOCKED_WATERWAYS),
            "harbor_snap_radius_tiles": meta["harbor_snap_radius_tiles"],
            "lakes_as_land": meta["lakes_as_land"],
            "source_sha256": {s["file"]: s["sha256"] for s in meta["sources"]},
            "source_passes": meta["source_passes"],
        },
        "tile_counts": {CHARS[i]: counts[i] for i in range(5)},
        "tiles_total": total,
        "sea_fraction": frac(counts[SEA] + counts[COAST]),
        "land_fraction": frac(meta["land_mask_tiles"]),
        "ice_fraction": frac(counts[ICE]),
        "reef_fraction": frac(counts[REEF]),
        "fractions": {
            "sea": frac(counts[SEA]),
            "coastal_sea": frac(counts[COAST]),
            "land_tiles": frac(counts[LAND]),
            "reef": frac(counts[REEF]),
            "ice": frac(counts[ICE]),
        },
        "land_mask": {
            "note": "coastline mask (land fill + lakes pass) sampled before the "
                    "ice pass overwrites polar land; this is the number the "
                    "25-35 % land-fraction sanity gate refers to",
            "tiles": meta["land_mask_tiles"],
            "fraction": frac(meta["land_mask_tiles"]),
            "land_tiles_after_ice": counts[LAND],
            "land_tiles_after_ice_fraction": frac(counts[LAND]),
        },
        "components": {
            "law": "4-connected passable tiles, wrap-aware in x "
                   "(== 8-dir with corner-cutting forbidden)",
            "count": components["count"],
            "passable_tiles": components["passable_tiles"],
            "over_2000": components["over_2000"],
            "over_1000000": components["over_1000000"],
        },
        "overrides": meta["overrides"],
        "override_details": meta["override_details"],
        "ports": port_results,
        "port_count": len(port_results),
    }


def write_report(report: dict) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    REPORT_PATH.write_text(text, encoding="utf-8")


# --------------------------------------------------------------------------
# Grid cache (for --check-snaps; never under data/)
# --------------------------------------------------------------------------
CACHE_MAGIC = b"SAILAGE-WORLD-GRID-1\n"


def cache_path(degrees_per_tile: float, overrides_text: str) -> Path:
    digest = hashlib.sha256()
    digest.update(repr(degrees_per_tile).encode())
    for name in sorted(EXPECTED_SHA256):
        digest.update(EXPECTED_SHA256[name].encode())
    digest.update(overrides_text.encode("utf-8"))
    # The builder's own source is an input too: a cache written by an older
    # pass order must never be served to a newer builder (the band refresh
    # after the carves, for one, changes the raster without changing any
    # other input).
    digest.update(Path(__file__).read_bytes())
    return Path(tempfile.gettempdir()) / f"sailage-world-grid-{digest.hexdigest()[:16]}.bin"


def load_cached_grid(path: Path) -> Grid | None:
    try:
        with open(path, "rb") as fh:
            blob = fh.read()
    except OSError:
        return None
    if not blob.startswith(CACHE_MAGIC):
        return None
    pos = len(CACHE_MAGIC)
    header_len = struct.unpack(">I", blob[pos:pos + 4])[0]
    pos += 4
    try:
        header = json.loads(blob[pos:pos + header_len].decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    pos += header_len
    width, height = header.get("width"), header.get("height")
    payload = blob[pos:]
    if not width or not height or len(payload) != width * height:
        return None
    grid = Grid(width, height)
    for y in range(height):
        grid.rows[y][:] = payload[y * width:(y + 1) * width]
    return grid


def save_cached_grid(path: Path, grid: Grid) -> None:
    header = json.dumps({"width": grid.w, "height": grid.h},
                        separators=(",", ":")).encode("utf-8")
    tmp = path.with_suffix(".tmp")
    try:
        with open(tmp, "wb") as fh:
            fh.write(CACHE_MAGIC)
            fh.write(struct.pack(">I", len(header)))
            fh.write(header)
            fh.write(grid.flat())
        os.replace(tmp, path)
    except OSError:
        pass  # cache is an optimization only


def grid_for_snaps(degrees_per_tile: float, no_cache: bool,
                   verbose: bool) -> Grid:
    """Build (or reuse) the final post-carve grid without writing artifacts."""
    overrides_text = ""
    if OVERRIDES_PATH.exists():
        overrides_text = OVERRIDES_PATH.read_text(encoding="utf-8")
    path = cache_path(degrees_per_tile, overrides_text)
    if not no_cache:
        cached = load_cached_grid(path)
        if cached is not None:
            if verbose:
                print(f"  using cached grid {path}", file=sys.stderr)
            return cached
    grid, _meta = build_grid(degrees_per_tile, verbose=verbose)
    if not no_cache:
        save_cached_grid(path, grid)
    return grid


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def parse_rows(spec: str, height: int) -> tuple[int, int]:
    if ":" not in spec:
        raise argparse.ArgumentTypeError("--rows wants A:B (1-based, inclusive)")
    left, right = spec.split(":", 1)
    try:
        start = int(left)
        end = int(right)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"--rows wants integers, got {spec!r}") from exc
    if start < 1 or end < start or end > height:
        raise argparse.ArgumentTypeError(
            f"--rows {spec!r} outside 1..{height}"
        )
    return start, end


def cmd_check_snaps(args) -> int:
    path = Path(args.check_snaps)
    if not path.exists():
        print(f"build_world: ports file not found: {path}", file=sys.stderr)
        return 2
    ports = load_ports(path)
    if not ports_have_coords(ports):
        # W3 preflight path: `data/ports.json` still carries the pre-Phase-4
        # schema until task E adds lat/lon. The locked coordinate source is
        # then the §7.1 table, exactly as the build path falls back — and only
        # for the shipped file, so a hand-written negative-test JSON (a port
        # in the Caspian, say) can never be silently swapped out.
        if path.resolve() != PORTS_PATH.resolve():
            print(
                f"build_world: {path} has no lat/lon; --check-snaps needs "
                f"coordinates (only the shipped {PORTS_PATH.name} falls back "
                f"to the §7.1 table)",
                file=sys.stderr,
            )
            return 2
        ports, _source = resolve_build_ports(False)
    grid = grid_for_snaps(args.degrees_per_tile, args.no_cache, args.verbose)
    results, failures = snap_ports(grid, ports)
    for entry in results:
        tile = entry["harbor_tile"]
        if tile is None:
            continue
        print(
            f"{entry['id']:<16} {entry['lat']:>8.3f} {entry['lon']:>9.3f}"
            f"  ->  {tile['x']:>4}, {tile['y']:>4}"
            f"  shore {entry['shore_tile']['x']:>4}, {entry['shore_tile']['y']:>4}"
            f"  (distance {entry['distance']})"
        )
    for dupe in duplicate_harbors(results) + duplicate_shores(results):
        print(f"warning: {dupe}", file=sys.stderr)
    if failures:
        print(
            f"build_world: CHECK-SNAPS FAILED for {len(failures)} of {len(ports)} "
            f"ports (file {path}):",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  FAIL {failure}", file=sys.stderr)
        return 1
    print(
        f"build_world: check-snaps OK — {len(ports)} ports snapped within "
        f"{HARBOR_SNAP_TILES} tiles with a shore tile (file {path})",
        file=sys.stderr,
    )
    return 0


def cmd_ascii(args, grid: Grid) -> int:
    start, end = parse_rows(args.rows, grid.h) if args.rows else (1, grid.h)
    lines = grid.ascii_lines()
    text = "\n".join(lines[start - 1:end]) + "\n"
    if args.ascii_out:
        out = Path(args.ascii_out)
        if DATA_MAPS.resolve() in out.resolve().parents:
            print(
                "build_world: refusing to write the ASCII debug export under "
                f"data/ ({out}); use a temp path",
                file=sys.stderr,
            )
            return 2
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8", newline="\n")
        print(f"build_world: wrote {end - start + 1} ASCII rows to {out}",
              file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def cmd_build(args) -> int:
    grid, meta = build_grid(args.degrees_per_tile, verbose=args.verbose)
    ports, ports_source = resolve_build_ports(args.verbose)
    port_results, failures = snap_ports(grid, ports)
    if failures:
        print(
            f"build_world: harbor snap FAILED for {len(failures)} of "
            f"{len(ports)} ports (source {ports_source}):",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  FAIL {failure}", file=sys.stderr)
        return 1
    for dupe in duplicate_harbors(port_results):
        print(f"build_world: warning: {dupe}", file=sys.stderr)
    shared_shores = duplicate_shores(port_results)
    if shared_shores:
        # Two ports cannot share a shore tile: only one of them could be docked
        # into (20-* §4.11.1). This is a data error, not a warning.
        print(
            "build_world: harbor pair FAILED — a shore tile is shared:",
            file=sys.stderr,
        )
        for dupe in shared_shores:
            print(f"  FAIL {dupe}", file=sys.stderr)
        return 1
    assert_harbors_on_ocean(grid, port_results)

    report = build_report(grid, meta, ports, port_results)
    report["build"]["ports_source"] = ports_source
    PNG_PATH.parent.mkdir(parents=True, exist_ok=True)
    png = encode_png(grid)
    PNG_PATH.write_bytes(png)
    write_report(report)
    save_cached_grid(cache_path(args.degrees_per_tile,
                                OVERRIDES_PATH.read_text(encoding="utf-8")
                                if OVERRIDES_PATH.exists() else ""), grid)

    if args.verify:
        decoded = decode_png(png)
        problems = []
        if (decoded["width"], decoded["height"]) != (grid.w, grid.h):
            problems.append(f"size {decoded['width']}x{decoded['height']}")
        if decoded["colour_type"] != 3:
            problems.append(f"colour type {decoded['colour_type']}")
        if len(decoded["palette"]) != len(PALETTE):
            problems.append(f"palette entries {len(decoded['palette'])}")
        if decoded["interlace"] != 0:
            problems.append("interlaced")
        if decoded["rows"] != grid.rows:
            problems.append("decoded rows differ from the raster")
        expected = {CHARS[i]: report["tile_counts"][CHARS[i]] for i in range(5)}
        flat = b"".join(decoded["rows"])
        actual = {CHARS[i]: flat.count(bytes([i])) for i in range(5)}
        if actual != expected:
            problems.append(f"index histogram {actual} != {expected}")
        if problems:
            print("build_world: VERIFY FAILED: " + "; ".join(problems),
                  file=sys.stderr)
            return 2
        print("build_world: verify OK — indexed PNG, palette 5, histogram matches",
              file=sys.stderr)

    print(
        f"build_world: wrote {PNG_PATH.relative_to(ROOT)} "
        f"({len(png)} bytes, sha256 {hashlib.sha256(png).hexdigest()}) "
        f"and {REPORT_PATH.relative_to(ROOT)}",
        file=sys.stderr,
    )
    print(
        "build_world: "
        f"land mask {report['land_mask']['fraction']:.4f} "
        f"('#' {report['fractions']['land_tiles']:.4f}) "
        f"sea {report['sea_fraction']:.4f} ice {report['ice_fraction']:.4f} | "
        f"components>2000 {len(report['components']['over_2000'])} | "
        f"ports {report['port_count']} | {meta['raster_seconds']:.2f}s raster",
        file=sys.stderr,
    )
    if args.report:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate data/maps/world.png from the vendored Natural "
                    "Earth shorelines (deterministic, offline).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--degrees-per-tile", type=float, default=DEFAULT_DEGREES_PER_TILE,
        help="tiles per degree (default %(default)s = 1/6; only 1/6 yields the "
             "locked 2160x1080 grid)",
    )
    parser.add_argument(
        "--ascii", action="store_true",
        help="debug export: 2160-char lines of '~ . # ^ I' (stdout unless "
             "--ascii-out is given; never under data/)",
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
        help="print the JSON report to stdout after the build",
    )
    parser.add_argument(
        "--check-snaps", metavar="PORTS_JSON",
        help="dry run: apply the locked harbor-snap rule to a ports file "
             "(JSON with id/lat/lon, or the §7.1 markdown table) and exit "
             "non-zero naming every port that cannot snap; writes no artifact",
    )
    parser.add_argument(
        "--verify", action="store_true",
        help="after writing, decode world.png with the stdlib reader and "
             "assert size/colour type/palette/histogram",
    )
    parser.add_argument("--no-cache", action="store_true",
                        help="ignore the /tmp grid cache used by --check-snaps")
    parser.add_argument("--verbose", action="store_true",
                        help="per-pass progress on stderr")
    args = parser.parse_args(argv)

    try:
        if args.check_snaps:
            if args.ascii or args.report:
                parser.error("--check-snaps cannot be combined with --ascii/--report")
            return cmd_check_snaps(args)
        if args.ascii:
            grid, _meta = build_grid(args.degrees_per_tile, verbose=args.verbose)
            return cmd_ascii(args, grid)
        if args.rows and not args.ascii:
            parser.error("--rows requires --ascii")
        return cmd_build(args)
    except BuildError as exc:
        print(f"build_world: FAIL: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
