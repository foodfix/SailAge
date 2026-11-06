#!/usr/bin/env python3
"""build_routes.py — deterministic trade-route builder (Phase 5, task F).

Turns the hand-authored historical lanes (``data/trade_routes.json``, 21
locked ids per ``docs/10-DATA-SCHEMA.md`` §7.6) plus the 145 ports (the
sovereign 100 + the Phase-6 neutral tier) and the hand fixes in
``tools/route_overrides.json`` into the tool-owned artifact
``data/trade_routes_built.json``: per-lane tile paths (base + seasonal
``variants``), the junction graph the runtime routes over, and exactly one
minor spoke per port. Mirror of
``build_world.py`` governance: pure stdlib, no timestamps, no randomness,
stable sort everywhere — two consecutive builds are **byte-identical**
(docs/10-* §4.14; validator group 8 re-asserts it).

Locked rules implemented here (docs/10-* §4.14, §6.1, §8.3):

  grid            4320 x 2160 tiles, 12 tiles/degree (shared with build_world;
                  Phase-6 rescale, `10-*` §6.1)
  waypoint snap   water within 2 tiles (Chebyshev, wrap-aware) with >= 1
                  orthogonally adjacent water tile, ties -> smallest (y, x)
                  — the §6.1 harbor-snap rule, applied to every lane waypoint
                  and to every variant waypoint
  segment walk    every consecutive waypoint pair is walked on the raster:
                  8-direction straight-line walk, corner cutting forbidden,
                  x wraps mod 4320; stepping on an impassable tile is a hard
                  build error naming the lane
  month windows   per lane and month 1..12 the active path (a variant whose
                  `months` contain the month, else the base waypoints) must
                  be walkable with that month's seasonal-ice mask active
                  (water tiles inside an in-force data/ice_regions.json
                  polygon are impassable; §4.18) — a violation is a hard
                  build error naming the lane and month. This is what makes
                  `hanseatic_north` (base 4-11, winter variant 12-3) build
                  green: base legs walkable unfrozen, variant legs walkable
                  while the Baltic is frozen.
  spokes          exactly one per port, in this order:
                    1. walk-aware lane rule: among the lane waypoints within
                       Chebyshev 40 of the port harbor tile (wrap-aware) in
                       Chebyshev order (ties smallest (y, x), then lane file
                       order, then waypoint index), the FIRST whose straight
                       walk succeeds; walk-failed candidates are skipped;
                    2. else the passable direct walk to the port's national
                       capital harbor tile (sovereign ports only);
                    3. else the spoke declared for the port in
                       ``tools/route_overrides.json`` (A*-pathfound on the
                       grid through the declared via points to the declared
                       lane-waypoint connect);
                    4. else, for a neutral port (`nation_id: ""`) with no
                       declared override: the nearest lane waypoint
                       UNBOUNDED (A*; a hard build error when no water path
                       exists at all);
                    5. a port with none is a hard build error naming the
                       port.
                  An override is superseded (an error naming the port)
                  exactly when rule 1 succeeds for that port; an override
                  whose rule-1 walk fails stays legal.
  junction graph  a junction node is a tile shared by >= 2 distinct paths
                  (base lanes + spokes) or a path endpoint; node key = wrapped
                  (x, y); every path is split at its nodes into edges whose
                  weight is the tile step count. Runtime Dijkstra walks this
                  graph (edge weight = tile length; tie-breaks are 60-* §4.1
                  material, not the builder's). Variant paths are carried
                  per lane for the runtime's in-month selection and do not
                  join the graph (the graph stays month-blind).

Artifact: envelope ``{"version", "generated_by", "artifact", ...}`` — a tool
output like ``maps/world_report.json`` (group 1 exempts it). Never hand-edit
it; fix ``data/trade_routes.json`` / ``tools/route_overrides.json`` and
regenerate. Input SHA-256s are recorded in ``build.sources`` so a drifted
input fails the next ``--check`` loudly.

Usage
-----
    python3 tools/build_routes.py              # build + write the artifact
    python3 tools/build_routes.py --check      # rebuild in memory, byte-compare
    python3 tools/build_routes.py --report     # build + print report JSON
    python3 tools/build_routes.py --ascii      # debug export with route overlay
    python3 tools/build_routes.py --ascii --rows 200:260 [--ascii-out PATH]

Exit codes: 0 ok; 1 usage/CLI failure; 2 BuildError (a named lane/port);
3 determinism drift (``--check`` mismatch).
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
TOOLS = ROOT / "tools"
LANES_PATH = DATA / "trade_routes.json"
PORTS_PATH = DATA / "ports.json"
NATIONS_PATH = DATA / "nations.json"
ICE_PATH = DATA / "ice_regions.json"
OVERRIDES_PATH = TOOLS / "route_overrides.json"
WORLD_PNG = DATA / "maps" / "world.png"
BUILT_PATH = DATA / "trade_routes_built.json"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_world as bw  # noqa: E402  (shared PNG decoder + grid + snap rule)

# --------------------------------------------------------------------------
# Locked constants (docs/10-DATA-SCHEMA.md §4.14, §6.1)
# --------------------------------------------------------------------------
WAYPOINT_SNAP_TILES = 2  # §6.1 harbor-snap radius, applied to lane waypoints
SPOKE_RADIUS_TILES = 40  # §4.14 minor-spoke Chebyshev radius (Phase-6 sweep: 20 → 40)
# 8-direction neighbour order, fixed for determinism; diagonals last.
DELTAS = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))
SQRT2 = math.sqrt(2.0)

INPUT_SOURCES = (
    ("trade_routes", LANES_PATH),
    ("ports", PORTS_PATH),
    ("nations", NATIONS_PATH),
    ("ice_regions", ICE_PATH),
    ("route_overrides", OVERRIDES_PATH),
    ("world_png", WORLD_PNG),
)


class BuildError(Exception):
    """A loud, named build failure (exit code 2)."""


# --------------------------------------------------------------------------
# Grid + input loading
# --------------------------------------------------------------------------
def load_world_grid() -> bw.Grid:
    """Decode data/maps/world.png into the shared Grid (build_world reader)."""
    data = WORLD_PNG.read_bytes()
    decoded = bw.decode_png(data)
    grid = bw.Grid(decoded["width"], decoded["height"])
    for y in range(decoded["height"]):
        grid.rows[y][:] = decoded["rows"][y]
    return grid


def load_inputs() -> tuple[list[dict], list[dict], list[dict], dict]:
    """Read the four JSON inputs in their file order (stable)."""
    lanes = json.loads(LANES_PATH.read_text(encoding="utf-8"))["lanes"]
    ports = json.loads(PORTS_PATH.read_text(encoding="utf-8"))["ports"]
    nations = json.loads(NATIONS_PATH.read_text(encoding="utf-8"))["nations"]
    overrides_payload = json.loads(OVERRIDES_PATH.read_text(encoding="utf-8"))
    return lanes, ports, nations, overrides_payload


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Waypoint snap (§6.1 harbor-snap rule, applied to lane waypoints)
# --------------------------------------------------------------------------
def snap_waypoint(grid: bw.Grid, lat: float, lon: float,
                  radius: int = WAYPOINT_SNAP_TILES):
    """Locked snap rule: water + orthogonally adjacent water, ties (y, x).

    Returns ``(x, y, distance)`` (x wrapped) or ``None`` when no candidate
    within ``radius`` satisfies the rule.
    """
    px, py = grid.tile_of_latlon(lat, lon)
    candidates = []
    for dy in range(-radius, radius + 1):
        y = py + dy
        if not (0 <= y < grid.h):
            continue
        for dx in range(-radius, radius + 1):
            x = (px + dx) % grid.w
            candidates.append((bw.chebyshev_wrap(dx, dy, grid.w), y, x))
    candidates.sort()  # locked order: distance, then smallest (y, x)
    for distance, y, x in candidates:
        if grid.is_water(x, y) and grid.has_adjacent_water(x, y):
            return x, y, distance
    return None


# --------------------------------------------------------------------------
# Segment walk (8-dir, corner cutting forbidden, wrap-aware)
# --------------------------------------------------------------------------
def walk_segment(grid: bw.Grid, a: tuple[int, int], b: tuple[int, int],
                 blocked: frozenset | None = None):
    """Straight-line tile chain from ``a`` to ``b`` (4-connected output).

    The polyline is sampled at 1/20-tile resolution; when the sample moves
    diagonally the intermediate orthogonal tile is inserted, so consecutive
    chain tiles are always 4-adjacent (build_world's ``_chain_tiles`` rule).
    Corner cutting is therefore forbidden by construction: the bridged
    orthogonal tile is part of the chain and must be water too.

    ``blocked`` (a set of wrapped ``(x, y)`` tiles) marks extra impassable
    tiles on top of the raster — the month's seasonal-ice mask for the
    §4.14 month-window passability rule; ``None`` keeps the plain walk.

    Returns ``(chain, None)`` with every tile passable, or ``(None, bad)``
    where ``bad`` is the first impassable tile.
    """
    (x0, y0), (x1, y1) = a, b
    ux1 = float(x1)
    while ux1 - x0 > grid.w / 2.0:
        ux1 -= grid.w
    while ux1 - x0 < -grid.w / 2.0:
        ux1 += grid.w
    yy0, yy1 = float(y0), float(y1)
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
    for x, y in chain:
        if not grid.is_water(x, y):
            return None, (x, y)
        if blocked is not None and (x, y) in blocked:
            return None, (x, y)
    return chain, None


def lane_tile_path(grid: bw.Grid, lane_id: str,
                   snapped: list[tuple[int, int]],
                   variant_id: str = "") -> list[tuple[int, int]]:
    """Rasterized lane path: the per-segment chains concatenated.

    ``variant_id`` (empty for the base waypoints) only sharpens the error
    messages; the geometry is identical.
    """
    label = f"lane '{lane_id}'" + (f" variant '{variant_id}'" if variant_id
                                   else "")
    path: list[tuple[int, int]] = []
    for i in range(len(snapped) - 1):
        seg, bad = walk_segment(grid, snapped[i], snapped[i + 1])
        if seg is None:
            raise BuildError(
                f"{label} segment {i} "
                f"({snapped[i]}) -> ({snapped[i + 1]}) walks onto an "
                f"impassable tile at {bad} "
                f"[{bw.CHARS[grid.rows[bad[1]][bad[0]]]}], lat "
                f"{grid.lat_of_y(bad[1]):.2f} lon {grid.lon_of_x(bad[0]):.2f}"
            )
        if path and seg[0] == path[-1]:
            seg = seg[1:]
        path.extend(seg)
    return path


# --------------------------------------------------------------------------
# Seasonal ice masks + month-window passability (docs/10-* §4.14, §4.18)
# --------------------------------------------------------------------------
def load_ice_masks(grid: bw.Grid) -> tuple[dict[int, frozenset], list[dict]]:
    """Month-keyed impassable-water sets from data/ice_regions.json.

    For every region, its polygon interior (tile-centre scanline fill, the
    same primitive build_world uses) is collected once; a month's mask is
    the union of the regions whose ``months`` include that month. Returns
    ``(masks, region_sources)`` where ``masks[month]`` is a frozenset of
    wrapped ``(x, y)`` water-impassable tiles and ``region_sources`` keeps
    ``{id, months, tiles}`` for error messages and the report.
    """
    if not ICE_PATH.is_file():
        raise BuildError(
            f"{ICE_PATH.relative_to(ROOT)} not found — the §4.18 seasonal "
            "ice data is required for the month-window passability rule")
    doc = json.loads(ICE_PATH.read_text(encoding="utf-8"))
    regions = doc.get("ice_regions")
    if not isinstance(regions, list) or not regions:
        raise BuildError("ice_regions.json: missing non-empty 'ice_regions'")
    if not isinstance(doc.get("version"), int):
        raise BuildError("ice_regions.json: missing integer 'version'")

    per_region: list[tuple[set[int], set[tuple[int, int]]]] = []
    sources: list[dict] = []
    for index, region in enumerate(regions):
        where = f"ice_regions.json: ice_regions[{index}] ({region.get('id')!r})"
        region_id = region.get("id")
        months = region.get("months")
        polygon = region.get("polygon")
        if not isinstance(region_id, str) or not region_id:
            raise BuildError(f"{where}: missing string 'id'")
        if (not isinstance(months, list) or not months
                or not all(isinstance(m, int) and not isinstance(m, bool)
                           and 1 <= m <= 12 for m in months)):
            raise BuildError(
                f"{where}: months must be a non-empty list of ints 1..12")
        if len(set(months)) != len(months):
            raise BuildError(f"{where}: months repeats a month")
        if not isinstance(polygon, list) or len(polygon) < 3:
            raise BuildError(f"{where}: polygon needs >= 3 [lat, lon] vertices")
        ring = []
        for pair in polygon:
            if (not isinstance(pair, list) or len(pair) != 2
                    or not all(isinstance(v, (int, float))
                               and not isinstance(v, bool) for v in pair)):
                raise BuildError(f"{where}: polygon entry {pair!r} must be "
                                 "[lat, lon]")
            lat, lon = float(pair[0]), float(pair[1])
            if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                raise BuildError(f"{where}: vertex out of range: {pair}")
            ring.append((lon, lat))
        tiles = _ring_water_tiles(grid, ring)
        per_region.append((set(months), tiles))
        sources.append({"id": region_id, "months": sorted(set(months)),
                        "tiles": len(tiles)})

    masks: dict[int, frozenset] = {}
    for month in range(1, 13):
        combined: set[tuple[int, int]] = set()
        for months, tiles in per_region:
            if month in months:
                combined |= tiles
        masks[month] = frozenset(combined)
    return masks, sources


def _ring_water_tiles(grid: bw.Grid, ring: list[tuple[float, float]]
                      ) -> set[tuple[int, int]]:
    """Water tiles inside one ring (tile-centre scanline fill, wrap-aware).

    Uses ``build_world.fill_ring`` — the same primitive the world builder
    rasterizes land with — on a scratch grid, then keeps only the tiles the
    world raster marks passable (only water freezes, §4.18).
    """
    scratch = bw.Grid(grid.w, grid.h)
    bw.fill_ring(scratch, ring, 1)
    tiles: set[tuple[int, int]] = set()
    for y in range(grid.h):
        line = grid.rows[y]
        row = scratch.rows[y]
        pos = row.find(1)
        while pos != -1:
            if line[pos] in bw.PASSABLE:
                tiles.add((pos, y))
            pos = row.find(1, pos + 1)
    return tiles


def validate_month_windows(grid: bw.Grid, lanes: list[dict],
                           lane_path_sets: dict, variants_by_lane: dict,
                           masks: dict) -> list[dict]:
    """The §4.14/§8.5 month-window rule, lane by lane, month by month.

    For every month 1..12 the active path (a variant whose ``months``
    contain the month, else the base waypoints) must not touch the month's
    ice mask. The geometric chains are month-invariant, so each path is
    walked once and checked against 12 masks. Violations are hard build
    errors naming the lane (and variant) and month. Returns per-lane stats
    for the report.
    """
    stats = []
    for lane in lanes:
        lane_id = lane["id"]
        variants = variants_by_lane.get(lane_id, [])
        covered = sorted({m for variant in variants
                          for m in variant["months"]})
        base_months = [m for m in range(1, 13) if m not in covered]
        checked = 0
        for month in base_months:
            checked += 1
            bad = lane_path_sets[lane_id].intersection(masks[month])
            if bad:
                tile = min(bad)
                raise BuildError(
                    f"lane '{lane_id}' month-window {month}: the base path "
                    f"crosses in-force seasonal ice at {tile} (lat "
                    f"{grid.lat_of_y(tile[1]):.2f} lon "
                    f"{grid.lon_of_x(tile[0]):.2f}); the lane must avoid ice "
                    "year-round or carry a covering variant set (§4.14, "
                    "§4.18)")
        for variant in variants:
            for month in sorted(variant["months"]):
                checked += 1
                bad = variant["path_set"].intersection(masks[month])
                if bad:
                    tile = min(bad)
                    raise BuildError(
                        f"lane '{lane_id}' variant '{variant['id']}' "
                        f"month-window {month}: the variant path crosses "
                        f"in-force seasonal ice at {tile} (lat "
                        f"{grid.lat_of_y(tile[1]):.2f} lon "
                        f"{grid.lon_of_x(tile[0]):.2f}) (§4.14)")
        stats.append({"lane": lane_id, "months_checked": checked,
                      "variant_months": covered,
                      "base_months": base_months})
    return stats


def build_lane_variants(grid: bw.Grid, lanes: list[dict]) -> dict:
    """Rasterize every lane ``variants`` entry (§4.14): snap <= 2 + walk.

    Returns ``{lane_id: [{"id", "months", "tile_path", "path_set"}]}``.
    A waypoint with no water inside the snap radius, a walk onto an
    impassable tile, or a malformed structure is a hard build error naming
    the lane and the variant. (The month-window ice check runs later, over
    every lane including these variants — see validate_month_windows.)
    """
    variants_by_lane: dict[str, list[dict]] = {}
    for lane in lanes:
        raw = lane.get("variants") or []
        if not raw:
            continue
        lane_id = lane["id"]
        if not isinstance(raw, list):
            raise BuildError(
                f"lane '{lane_id}': variants must be an array of "
                "{\"id\", \"months\", \"waypoints\"} objects")
        seen_ids: set[str] = set()
        seen_months: set[int] = set()
        out: list[dict] = []
        for v_index, variant in enumerate(raw):
            where = f"lane '{lane_id}' variants[{v_index}]"
            if not isinstance(variant, dict):
                raise BuildError(f"{where} must be an object")
            unknown = set(variant) - {"id", "months", "waypoints"}
            if unknown:
                raise BuildError(
                    f"{where} has unknown key(s): "
                    f"{', '.join(sorted(unknown))}")
            variant_id = variant.get("id")
            if not isinstance(variant_id, str) or not variant_id:
                raise BuildError(f"{where}: missing string 'id'")
            if variant_id in seen_ids:
                raise BuildError(
                    f"{where}: duplicate variant id within the lane")
            seen_ids.add(variant_id)
            months = variant.get("months")
            if (not isinstance(months, list) or not months
                    or not all(isinstance(m, int) and not isinstance(m, bool)
                               and 1 <= m <= 12 for m in months)):
                raise BuildError(
                    f"{where} ('{variant_id}'): months must be a non-empty "
                    "list of ints 1..12")
            if len(set(months)) != len(months):
                raise BuildError(
                    f"{where} ('{variant_id}'): months repeats a month")
            overlap = seen_months & set(months)
            if overlap:
                raise BuildError(
                    f"{where} ('{variant_id}'): months "
                    f"{sorted(overlap)} overlap another variant's months "
                    "(§4.14: variant months are pairwise disjoint)")
            seen_months |= set(months)
            waypoints = variant.get("waypoints")
            if (not isinstance(waypoints, list) or len(waypoints) < 2):
                raise BuildError(
                    f"{where} ('{variant_id}'): needs >= 2 [lat, lon] "
                    "waypoints")
            snapped: list[tuple[int, int]] = []
            for w_index, point in enumerate(waypoints):
                if (not isinstance(point, list) or len(point) != 2
                        or not all(isinstance(v, (int, float))
                                   and not isinstance(v, bool)
                                   for v in point)):
                    raise BuildError(
                        f"{where} ('{variant_id}') waypoint {w_index} must "
                        "be [lat, lon]")
                lat, lon = float(point[0]), float(point[1])
                if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                    raise BuildError(
                        f"{where} ('{variant_id}') waypoint {w_index} out of "
                        f"range: {point}")
                hit = snap_waypoint(grid, lat, lon)
                if hit is None:
                    px, py = grid.tile_of_latlon(lat, lon)
                    raise BuildError(
                        f"lane '{lane_id}' variant '{variant_id}' waypoint "
                        f"{w_index} ({lat}, {lon}) has no water tile within "
                        f"{WAYPOINT_SNAP_TILES} tiles of ({px}, {py})")
                snapped.append((hit[0], hit[1]))
            path = lane_tile_path(grid, lane_id, snapped, variant_id)
            out.append({
                "id": variant_id,
                "months": list(months),
                "tile_path": path,
                "path_set": frozenset(path),
            })
        variants_by_lane[lane_id] = out
    return variants_by_lane


# --------------------------------------------------------------------------
# A* spoke pathfinding (overrides only — build-time pathfinding, a tool)
# --------------------------------------------------------------------------
def astar_path(grid: bw.Grid, start: tuple[int, int], goal: tuple[int, int]):
    """Deterministic 8-direction A*, corner cutting forbidden, wrap-aware.

    Tie-breaks: heap entries are ``(f, g, y, x)`` tuples and the neighbour
    order is the fixed DELTAS order, so the same inputs always yield the same
    path. Returns the tile list (start..goal) or ``None`` when unreachable.
    """
    (sx, sy), (gx, gy) = start, goal
    ux = float(gx)
    while ux - sx > grid.w / 2.0:
        ux -= grid.w
    while ux - sx < -grid.w / 2.0:
        ux += grid.w

    def heuristic(x: int, y: int) -> float:
        dx = abs(x - ux)
        dy = abs(y - gy)
        return (dx + dy) + (SQRT2 - 2.0) * min(dx, dy)  # octile, admissible

    g_best = {(sx, sy): 0.0}
    parent: dict[tuple[int, int], tuple[int, int]] = {}
    open_heap = [(heuristic(sx, sy), 0.0, sy, sx, (sx, sy))]
    while open_heap:
        _f, g_cur, y, x, node = heapq.heappop(open_heap)
        if g_cur > g_best.get(node, math.inf):
            continue
        if node == (gx, gy):
            path = [node]
            while node in parent:
                node = parent[node]
                path.append(node)
            path.reverse()
            return path
        for dx, dy in DELTAS:
            ny = y + dy
            if not (0 <= ny < grid.h):
                continue
            wx = (x + dx) % grid.w
            if not grid.is_water(wx, ny):
                continue
            if dx and dy:  # no corner cutting: both orthogonals must be water
                if not (grid.is_water((x + dx) % grid.w, y)
                        and grid.is_water(x, ny)):
                    continue
            ng = g_cur + (SQRT2 if (dx and dy) else 1.0)
            nb = (wx, ny)
            if ng < g_best.get(nb, math.inf):
                g_best[nb] = ng
                parent[nb] = node
                heapq.heappush(open_heap, (ng + heuristic(wx, ny), ng, ny, wx, nb))
    return None


# --------------------------------------------------------------------------
# Lanes: snap + rasterize
# --------------------------------------------------------------------------
def build_lanes(grid: bw.Grid, lanes: list[dict]) -> tuple[
        dict[str, list[tuple[int, int]]], dict[str, list[tuple[int, int]]],
        list[dict]]:
    """Snap every waypoint and rasterize every lane.

    Returns ``(snapped_by_lane, tile_path_by_lane, snap_stats)``. A waypoint
    with no water inside the snap radius is a hard build error naming the
    lane and waypoint.
    """
    snapped_by_lane: dict[str, list[tuple[int, int]]] = {}
    paths: dict[str, list[tuple[int, int]]] = {}
    snap_stats: list[dict] = []
    for lane in lanes:
        lane_id = lane["id"]
        snapped: list[tuple[int, int]] = []
        max_distance = 0
        at_limit = 0
        for index, (lat, lon) in enumerate(lane["waypoints"]):
            hit = snap_waypoint(grid, float(lat), float(lon))
            if hit is None:
                px, py = grid.tile_of_latlon(float(lat), float(lon))
                raise BuildError(
                    f"lane '{lane_id}' waypoint {index} "
                    f"({lat}, {lon}) has no water tile within "
                    f"{WAYPOINT_SNAP_TILES} tiles of ({px}, {py}) "
                    f"(landlocked; fix via tools/route_overrides.json or a "
                    f"reported waypoint amendment in data/trade_routes.json)"
                )
            x, y, distance = hit
            snapped.append((x, y))
            max_distance = max(max_distance, distance)
            if distance == WAYPOINT_SNAP_TILES:
                at_limit += 1
        paths[lane_id] = lane_tile_path(grid, lane_id, snapped)
        snapped_by_lane[lane_id] = snapped
        snap_stats.append({
            "lane": lane_id,
            "waypoints": len(snapped),
            "max_snap_distance": max_distance,
            "waypoints_at_snap_radius": at_limit,
            "tile_count": len(paths[lane_id]),
        })
    return snapped_by_lane, paths, snap_stats


# --------------------------------------------------------------------------
# Overrides
# --------------------------------------------------------------------------
def load_overrides(overrides_payload: dict, lanes: list[dict],
                   ports: list[dict]) -> dict[str, dict]:
    """Validate tools/route_overrides.json into {port_id: entry}.

    Schema (task-owned, docs/10-* §4.14 pins none):
      {"version": 1, "overrides": [{"kind": "spoke", "port": "<port id>",
        "connect": {"lane": "<lane id>", "waypoint_index": int},
        "via": [[lat, lon], ...],          # optional, A*-joined
        "note": "why this spoke exists"}]}  # optional
    Unknown ports/lanes, out-of-range indexes, duplicates and unknown keys
    are build errors — a typo must fail loudly, not silently reroute.
    """
    if not isinstance(overrides_payload, dict) or not isinstance(
            overrides_payload.get("overrides"), list):
        raise BuildError(
            "route_overrides: tools/route_overrides.json must be an object "
            "with an 'overrides' array")
    if not isinstance(overrides_payload.get("version"), int):
        raise BuildError("route_overrides: missing integer 'version'")
    lane_ids = {lane["id"] for lane in lanes}
    lane_waypoints = {lane["id"]: len(lane["waypoints"]) for lane in lanes}
    port_ids = {port["id"] for port in ports}
    table: dict[str, dict] = {}
    for index, entry in enumerate(overrides_payload["overrides"]):
        where = f"route_overrides: overrides[{index}]"
        if not isinstance(entry, dict):
            raise BuildError(f"{where} must be an object")
        unknown = set(entry) - {"kind", "port", "connect", "via", "note"}
        if unknown:
            raise BuildError(
                f"{where} has unknown key(s): {', '.join(sorted(unknown))}")
        if entry.get("kind") != "spoke":
            raise BuildError(f"{where} kind must be \"spoke\"")
        port_id = entry.get("port")
        if port_id not in port_ids:
            raise BuildError(
                f"{where} names unknown port {port_id!r}")
        if port_id in table:
            raise BuildError(
                f"{where}: duplicate override for port '{port_id}'")
        connect = entry.get("connect")
        if not isinstance(connect, dict) or set(connect) != {
                "lane", "waypoint_index"}:
            raise BuildError(
                f"{where} connect must be "
                "{\"lane\": <lane id>, \"waypoint_index\": int}")
        if connect["lane"] not in lane_ids:
            raise BuildError(
                f"{where} connect names unknown lane {connect['lane']!r}")
        wp_index = connect["waypoint_index"]
        if not isinstance(wp_index, int) or isinstance(wp_index, bool) or not (
                0 <= wp_index < lane_waypoints[connect["lane"]]):
            raise BuildError(
                f"{where} connect.waypoint_index {wp_index!r} out of range "
                f"for lane '{connect['lane']}' "
                f"(0..{lane_waypoints[connect['lane']] - 1})")
        via = entry.get("via", [])
        if not isinstance(via, list):
            raise BuildError(f"{where} via must be an array of [lat, lon]")
        parsed_via = []
        for j, point in enumerate(via):
            if (not isinstance(point, list) or len(point) != 2
                    or not all(isinstance(v, (int, float)) for v in point)):
                raise BuildError(
                    f"{where} via[{j}] must be [lat, lon]")
            lat, lon = float(point[0]), float(point[1])
            if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                raise BuildError(f"{where} via[{j}] out of range: {point}")
            parsed_via.append((lat, lon))
        table[port_id] = {
            "port": port_id,
            "connect": {"lane": connect["lane"],
                        "waypoint_index": wp_index},
            "via": parsed_via,
            "note": entry.get("note", ""),
        }
    return table


# --------------------------------------------------------------------------
# Spokes
# --------------------------------------------------------------------------
def chebyshev_wrap_tiles(grid: bw.Grid, a: tuple[int, int],
                         b: tuple[int, int]) -> int:
    return bw.chebyshev_wrap(b[0] - a[0], b[1] - a[1], grid.w)


def lane_waypoint_candidates(grid: bw.Grid, harbor: tuple[int, int],
                             snapped_by_lane: dict[str, list[tuple[int, int]]],
                             lane_order: list[str]) -> list[tuple]:
    """In-radius snapped lane waypoints in locked Chebyshev order.

    Order: ``(distance, y, x, lane_rank, waypoint_index)`` — the §4.14
    tie-break, restricted to waypoints within ``SPOKE_RADIUS_TILES`` of the
    port harbor tile (wrap-aware).
    """
    out = []
    for lane_rank, lane_id in enumerate(lane_order):
        for index, (x, y) in enumerate(snapped_by_lane[lane_id]):
            distance = chebyshev_wrap_tiles(grid, harbor, (x, y))
            if distance > SPOKE_RADIUS_TILES:
                continue
            out.append((distance, y, x, lane_rank, lane_id, index))
    out.sort()
    return out


def first_walkable_waypoint(grid: bw.Grid, harbor: tuple[int, int],
                            candidates: list[tuple],
                            snapped_by_lane: dict[str, list[tuple[int, int]]]):
    """Rule 1 (walk-aware, pinned at the W2 gate): the first candidate whose
    straight spoke walk succeeds; walk-failed candidates are skipped.

    Returns ``(lane_id, waypoint_index, tile, distance, chain)`` or ``None``
    when no in-radius candidate has a walk (the rule then falls through to
    the capital/override fallbacks).
    """
    for distance, _y, _x, _rank, lane_id, index in candidates:
        tile = snapped_by_lane[lane_id][index]
        chain, _bad = walk_segment(grid, harbor, tile)
        if chain is not None:
            return lane_id, index, tile, distance, chain
    return None


def nearest_lane_waypoint(grid: bw.Grid, harbor: tuple[int, int],
                          snapped_by_lane: dict[str, list[tuple[int, int]]],
                          lane_order: list[str]):
    """Nearest in-radius lane waypoint (legacy single-nearest probe).

    Tie-break: smallest (distance, y, x), then lane file order, then waypoint
    index. Returns ``(lane_id, index, tile, distance)`` or ``None``. The
    spoke rule itself is walk-aware now (first_walkable_waypoint); this
    helper remains for diagnostics and the validator's probes.
    """
    best = None
    for lane_rank, lane_id in enumerate(lane_order):
        for index, (x, y) in enumerate(snapped_by_lane[lane_id]):
            distance = chebyshev_wrap_tiles(grid, harbor, (x, y))
            if distance > SPOKE_RADIUS_TILES:
                continue
            key = (distance, y, x, lane_rank, index)
            if best is None or key < best[0]:
                best = (key, lane_id, index, (x, y), distance)
    if best is None:
        return None
    _key, lane_id, index, tile, distance = best
    return lane_id, index, tile, distance


def build_spokes(grid: bw.Grid, ports: list[dict], nations: list[dict],
                 snapped_by_lane: dict[str, list[tuple[int, int]]],
                 lane_order: list[str],
                 overrides: dict[str, dict]) -> tuple[list[dict], dict]:
    """Exactly one spoke per port (§4.14): lane, capital, override or the
    neutral nationless fallback.

    Rule 1 is walk-aware (pinned at the W2 gate): among the in-radius lane
    waypoints in Chebyshev order the first whose walk succeeds wins; only
    when no in-radius candidate has a walk do the capital/override
    fallbacks apply. An override is superseded (a build error naming the
    port) exactly when rule 1 succeeds. A neutral port (`nation_id: ""`)
    has no capital; with no override declared it takes rule 4 — the nearest
    lane waypoint unbounded, A*-pathfound.

    Returns ``(spoke_records, resolution_summary)``. A port with no possible
    spoke is a hard build error naming the port.
    """
    capital_of = {nation["id"]: nation["capital_port_id"]
                  for nation in nations}
    harbors: dict[str, tuple[int, int]] = {}
    for port in ports:
        snapped = bw.snap_harbor_with_shore(grid, float(port["lat"]),
                                            float(port["lon"]))
        if snapped is None:  # unreachable: validator group 6 guards this
            raise BuildError(
                f"port '{port['id']}' has no harbor tile (§6.1 snap failed)")
        harbors[port["id"]] = (snapped[0], snapped[1])
    nation_of = {port["id"]: port["nation_id"] for port in ports}
    capital_tiles = {pid: harbors[capital_of[nation_of[pid]]]
                     for pid in harbors if nation_of[pid]}

    records: list[dict] = []
    counts = {"lane": 0, "capital": 0, "override": 0, "fallback": 0,
              "completion": 0}
    for port in ports:
        port_id = port["id"]
        harbor = harbors[port_id]
        override = overrides.pop(port_id, None)
        is_neutral = port["nation_id"] == ""

        # Rule 1: walk-aware lane rule — first in-radius candidate that walks.
        candidates = lane_waypoint_candidates(grid, harbor, snapped_by_lane,
                                              lane_order)
        resolved = first_walkable_waypoint(grid, harbor, candidates,
                                           snapped_by_lane)
        if resolved is not None:
            lane_id, wp_index, tile, distance, chain = resolved
            if override is not None:
                raise BuildError(
                    f"port '{port_id}': superseded override — the port "
                    f"resolves by the §4.14 lane rule (lane waypoint "
                    f"'{lane_id}' #{wp_index} within "
                    f"{SPOKE_RADIUS_TILES} tiles, walk passable); remove "
                    f"the entry from tools/route_overrides.json")
            records.append({
                "port": port_id,
                "nation_id": port["nation_id"],
                "kind": "lane",
                "lane": lane_id,
                "waypoint_index": wp_index,
                "distance": distance,
                "tile_path": [[x, y] for x, y in chain],
            })
            counts["lane"] += 1
            continue

        # No in-radius candidate has a walk: the fallbacks apply (§4.14).
        # Rule 2: capital fallback — sovereign ports only; the direct walk
        # must be passable.
        if not is_neutral:
            capital_id = capital_of[port["nation_id"]]
            capital_tile = capital_tiles[capital_id]
            cap_chain, _bad = walk_segment(grid, harbor, capital_tile)
            if cap_chain is not None:
                if override is not None:
                    raise BuildError(
                        f"port '{port_id}': superseded override — the port "
                        f"resolves by the §4.14 capital fallback (direct "
                        f"walk to capital '{capital_id}' is passable); "
                        f"remove the entry from tools/route_overrides.json")
                records.append({
                    "port": port_id,
                    "nation_id": port["nation_id"],
                    "kind": "capital",
                    "capital": capital_id,
                    "tile_path": [[x, y] for x, y in cap_chain],
                })
                counts["capital"] += 1
                continue

        # Rule 3: the declared override spoke.
        if override is not None:
            path = _override_spoke_path(grid, harbors, snapped_by_lane,
                                        override)
            records.append({
                "port": port_id,
                "nation_id": port["nation_id"],
                "kind": "override",
                "connect": dict(override["connect"]),
                "via": [list(point) for point in override["via"]],
                "tile_path": [[x, y] for x, y in path],
            })
            counts["override"] += 1
            continue

        # Rule 4: the neutral nationless fallback — nearest lane waypoint
        # unbounded, A*-pathfound (§4.14; expected unused on the shipped
        # sources, implemented so a frontier port can never stall the build
        # silently).
        if is_neutral:
            nearest = None
            for lane_rank, lane_id in enumerate(lane_order):
                for index, (x, y) in enumerate(snapped_by_lane[lane_id]):
                    distance = chebyshev_wrap_tiles(grid, harbor, (x, y))
                    key = (distance, y, x, lane_rank, index)
                    if nearest is None or key < nearest[0]:
                        nearest = (key, lane_id, index, (x, y), distance)
            if nearest is not None:
                _key, lane_id, index, tile, distance = nearest
                path = astar_path(grid, harbor, tile)
                if path is None:
                    raise BuildError(
                        f"port '{port_id}': nationless fallback failed — no "
                        f"passable water path at all from its harbor "
                        f"{harbor} to the nearest lane waypoint '{lane_id}' "
                        f"#{index} {tile}")
                records.append({
                    "port": port_id,
                    "nation_id": "",
                    "kind": "fallback",
                    "lane": lane_id,
                    "waypoint_index": index,
                    "distance": distance,
                    "tile_path": [[x, y] for x, y in path],
                })
                counts["fallback"] += 1
                continue

        # Nothing applies: the §4.14 hard error, naming the port.
        if candidates:
            distance, _y, _x, _rank, lane_id, wp_index = candidates[0]
            raise BuildError(
                f"port '{port_id}': no spoke — the in-radius lane waypoint "
                f"'{lane_id}' #{wp_index} (distance {distance}) and every "
                f"other candidate within {SPOKE_RADIUS_TILES} tiles fails "
                f"its straight walk and no override is declared in "
                f"tools/route_overrides.json")
        if is_neutral:
            raise BuildError(
                f"port '{port_id}': no spoke — no lane waypoint within "
                f"{SPOKE_RADIUS_TILES} tiles or anywhere on the network, "
                "and no override declared in tools/route_overrides.json")
        raise BuildError(
            f"port '{port_id}': no spoke — no lane waypoint within "
            f"{SPOKE_RADIUS_TILES} tiles and the direct walk to capital "
            f"'{capital_of[port['nation_id']]}' is blocked; declare a spoke "
            f"override in tools/route_overrides.json")

    if overrides:
        stale = ", ".join(sorted(overrides))
        raise BuildError(
            f"route_overrides: entries for unknown or resolvable ports "
            f"(no such port needs a spoke): {stale}")
    summary = dict(counts)
    return records, summary


def _override_spoke_path(grid: bw.Grid, harbors, snapped_by_lane,
                         override) -> list[tuple[int, int]]:
    """Rasterize an override spoke: harbor -> via... -> connect, A*-joined."""
    lane_id = override["connect"]["lane"]
    wp_index = override["connect"]["waypoint_index"]
    connect = snapped_by_lane[lane_id][wp_index]
    waypoints = [harbors[override["port"]]]
    for lat, lon in override["via"]:
        hit = snap_waypoint(grid, lat, lon)
        if hit is None:
            raise BuildError(
                f"route_overrides: port '{override['port']}' via point "
                f"({lat}, {lon}) has no water within "
                f"{WAYPOINT_SNAP_TILES} tiles")
        waypoints.append((hit[0], hit[1]))
    waypoints.append(connect)
    path: list[tuple[int, int]] = []
    for i in range(len(waypoints) - 1):
        seg = astar_path(grid, waypoints[i], waypoints[i + 1])
        if seg is None:
            raise BuildError(
                f"route_overrides: port '{override['port']}' spoke leg {i} "
                f"({waypoints[i]}) -> ({waypoints[i + 1]}) has no passable "
                f"water path on the raster")
        if path and seg[0] == path[-1]:
            seg = seg[1:]
        path.extend(seg)
    return path


# --------------------------------------------------------------------------
# Junction graph
# --------------------------------------------------------------------------
# Spoke attachments pinned by the §8.3 item 7 probes: the completion pass
# (§4.14 rule 5) must never rewrite these — they are contracts, not
# incidental resolutions.
PINNED_SPOKE_PORTS = frozenset((
    "lima", "valparaiso", "guayaquil", "panama",      # pacific_america_spokes
    "safi", "elmina", "luanda",                       # west_africa_spokes
))


def complete_connectivity(grid: bw.Grid, paths_by_key: dict,
                          spoke_records: list[dict],
                          snapped_by_lane: dict, lane_order: list,
                          counts: dict, max_passes: int = 10) -> int:
    """§4.14 rule 5: re-attach detached junction-graph components by
    rewriting the bridge spoke as resolution kind "completion". Returns
    the number of completion passes that fired. Raises BuildError when a
    component cannot be attached by any candidate walk."""
    passes = 0
    for _ in range(max_passes):
        nodes, _edges, tile_to_node = build_junction_graph(paths_by_key)
        adj = graph_adjacency(_edges)
        comps = _graph_components(len(nodes), adj)
        if len(comps) <= 1:
            return passes
        comps.sort(key=len, reverse=True)
        main = comps[0]
        main_tiles = {nodes[i] for i in main}
        # lanes anchored in the main component: their waypoint tiles are
        # legal completion targets.
        main_lanes = [lane_id for lane_id in lane_order
                      if tuple(lane_tile(paths_by_key, f"lane:{lane_id}", 0))
                      in main_tiles]
        best = None  # (key, port_id, lane_id, wp_index, tile)
        for key, path in paths_by_key.items():
            if not key.startswith("spoke:"):
                continue
            port_id = key[len("spoke:"):]
            if port_id in PINNED_SPOKE_PORTS:
                continue
            harbor = path[0]
            node = tile_to_node.get(harbor)
            if node is None or node in main:
                continue
            for rank, lane_id in enumerate(main_lanes):
                for wp_index, tile in enumerate(snapped_by_lane[lane_id]):
                    distance = chebyshev_wrap_tiles(grid, harbor, tile)
                    key = (distance, tile[1], tile[0], rank, wp_index,
                           port_id)
                    if best is None or key < best[0]:
                        best = (key, port_id, lane_id, wp_index, tile)
        if best is None:
            raise BuildError(
                "junction graph has detached components but no spoke/"
                "waypoint completion candidate exists (§4.14 rule 5)")
        _key, port_id, lane_id, wp_index, tile = best
        chain = astar_path(grid, paths_by_key[f"spoke:{port_id}"][0], tile)
        if chain is None:
            raise BuildError(
                f"§4.14 rule 5 completion: no A* water path from port "
                f"'{port_id}' to {lane_id} waypoint #{wp_index} {tile}")
        record = next(r for r in spoke_records if r["port"] == port_id)
        record["kind"] = "completion"
        record["lane"] = lane_id
        record["waypoint_index"] = wp_index
        record["tile_path"] = [[x, y] for x, y in chain]
        record["distance"] = chebyshev_wrap_tiles(
            grid, tuple(chain[0]), tile)
        paths_by_key[f"spoke:{port_id}"] = [(x, y) for x, y in chain]
        counts["completion"] += 1
        passes += 1
    raise BuildError(
        "§4.14 rule 5 connectivity completion did not converge within "
        f"{max_passes} passes")


def lane_tile(paths_by_key: dict, key: str, index: int) -> tuple:
    return paths_by_key[key][index]


def _graph_components(node_count: int, adj: dict) -> list[set]:
    seen: set = set()
    comps: list[set] = []
    for s in range(node_count):
        if s in seen:
            continue
        comp, stack = set(), [s]
        while stack:
            n = stack.pop()
            if n in comp:
                continue
            comp.add(n)
            seen.add(n)
            stack.extend(adj.get(n, ()))
        comps.append(comp)
    return comps


def build_junction_graph(paths_by_key: dict[str, list[tuple[int, int]]]):
    """Extract the runtime routing graph from every tile path.

    Node = tile shared by >= 2 distinct paths, or any path endpoint (a path
    touching itself adds no connectivity, so within-path repeats are not
    nodes). Edges split each path at its nodes; weight = tile steps.
    Returns (nodes, edges, tile_to_node): nodes sorted by (y, x); edges
    [a, b, length] with a < b, sorted by (a, b).
    """
    occupancy: dict[tuple[int, int], set[str]] = {}
    endpoints: set[tuple[int, int]] = set()
    for key, path in paths_by_key.items():
        for tile in path:
            occupancy.setdefault(tile, set()).add(key)
        endpoints.add(path[0])
        endpoints.add(path[-1])

    junctions = {tile for tile, users in occupancy.items() if len(users) >= 2}
    node_tiles = junctions | endpoints
    nodes = sorted(node_tiles, key=lambda t: (t[1], t[0]))  # (y, x)
    tile_to_node = {tile: i for i, tile in enumerate(nodes)}

    edge_min: dict[tuple[int, int], int] = {}
    for path in paths_by_key.values():
        marked = [i for i, tile in enumerate(path) if tile in tile_to_node]
        for k in range(len(marked) - 1):
            i, j = marked[k], marked[k + 1]
            a = tile_to_node[path[i]]
            b = tile_to_node[path[j]]
            if a == b:
                continue
            key = (a, b) if a < b else (b, a)
            length = j - i
            if length < edge_min.get(key, math.inf):
                edge_min[key] = length
    edges = [[a, b, edge_min[(a, b)]] for a, b in sorted(edge_min)]
    return nodes, edges, tile_to_node


# --------------------------------------------------------------------------
# Connectivity probes (§8.3 item 7; the validator re-runs these)
# --------------------------------------------------------------------------
def graph_adjacency(edges: list[list[int]]) -> dict[int, list[int]]:
    adj: dict[int, list[int]] = {}
    for a, b, _length in edges:
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)
    return adj


def reachable_from(adj: dict[int, list[int]], start: int) -> set[int]:
    seen = {start}
    stack = [start]
    while stack:
        node = stack.pop()
        for nb in adj.get(node, ()):
            if nb not in seen:
                seen.add(nb)
                stack.append(nb)
    return seen


# --------------------------------------------------------------------------
# Artifact assembly
# --------------------------------------------------------------------------
def build_artifact(grid: bw.Grid, lanes: list[dict], ports: list[dict],
                   nations: list[dict],
                   overrides_payload: dict) -> tuple[dict, dict, dict]:
    """Full deterministic build.

    Returns ``(artifact_dict, report_dict, paths_by_key)`` — the third value
    is the lane/spoke path map the ASCII overlay renders.
    """
    snapped_by_lane, lane_paths, snap_stats = build_lanes(grid, lanes)
    lane_order = [lane["id"] for lane in lanes]

    # §4.14 variants: rasterized like lanes, then the §4.14/§8.5 month-window
    # rule over every lane's active path (hard build error naming lane+month).
    variants_by_lane = build_lane_variants(grid, lanes)
    masks, ice_sources = load_ice_masks(grid)
    lane_path_sets = {lane_id: frozenset(lane_paths[lane_id])
                      for lane_id in lane_order}
    month_stats = validate_month_windows(grid, lanes, lane_path_sets,
                                         variants_by_lane, masks)

    overrides = load_overrides(overrides_payload, lanes, ports)
    spoke_records, spoke_counts = build_spokes(
        grid, ports, nations, snapped_by_lane, lane_order, overrides)

    paths_by_key: dict[str, list[tuple[int, int]]] = {}
    for lane_id in lane_order:
        paths_by_key[f"lane:{lane_id}"] = lane_paths[lane_id]
    for record in spoke_records:
        paths_by_key[f"spoke:{record['port']}"] = [
            (x, y) for x, y in record["tile_path"]]
    # §4.14 rule 5 — connectivity completion (2026-11-06): the contract
    # (§8.3 item 7) is ONE connected junction graph, but rules 1-4 attach
    # spokes locally and the strict coast cleanup can re-open a walk that
    # moves a bridge spoke (Canton's override spoke used to bridge the
    # Pacific cluster to manila_galleon; once rule 1 resolved canton to
    # canton_country_trade the cluster detached). Completion re-attaches
    # every detached component: the spoke whose port harbor is closest
    # (wrapped Chebyshev) to any waypoint tile of a lane in the main
    # component is re-pathfound there with A* and rewritten as resolution
    # kind "completion". Deterministic candidate order (chebyshev, y, x,
    # lane rank, waypoint index, port id); a failed walk tries the next
    # candidate; one attachment per pass, passes repeated to fixpoint.
    completion_passes = complete_connectivity(
        grid, paths_by_key, spoke_records, snapped_by_lane, lane_order,
        spoke_counts)

    nodes, edges, tile_to_node = build_junction_graph(paths_by_key)

    # Port harbor tiles -> graph nodes; lane first tiles -> graph nodes.
    harbors = {record["port"]: tuple(record["tile_path"][0])
               for record in spoke_records}
    port_nodes = {pid: tile_to_node[tile] for pid, tile in harbors.items()}
    lane_nodes = {lane_id: tile_to_node[lane_paths[lane_id][0]]
                  for lane_id in lane_order}

    # Probes (§8.3 item 7 + the W3 gate's E-probes): over the built graph
    # and the built spoke records.
    adj = graph_adjacency(edges)
    acapulco = reachable_from(adj, port_nodes["acapulco"])
    hirado = reachable_from(adj, port_nodes["hirado"])
    spoke_by_port = {record["port"]: record for record in spoke_records}

    def spoke_onto(port_id: str, lane_id: str, max_distance=None) -> bool:
        record = spoke_by_port.get(port_id)
        if record is None or record.get("kind") != "lane":
            return False
        if record.get("lane") != lane_id:
            return False
        if max_distance is not None and record.get("distance", 10**9) > max_distance:
            return False
        return True

    pacific_ports = tuple(k for k in PINNED_SPOKE_PORTS
                          if k in ("lima", "valparaiso", "guayaquil",
                                   "panama"))
    africa_ports = tuple(k for k in PINNED_SPOKE_PORTS
                         if k in ("safi", "elmina", "luanda"))
    probes = {
        "acapulco_manila_wrap": port_nodes["manila"] in acapulco,
        "hanseatic_reaches_danzig": port_nodes["danzig"] in reachable_from(
            adj, lane_nodes["hanseatic_north"]),
        "carreira_reaches_goa": port_nodes["goa"] in reachable_from(
            adj, lane_nodes["carreira_da_india"]),
        "macau_hirado_via_canton": (
            port_nodes["macau"] in hirado
            and port_nodes["hirado"] in hirado
            and (spoke_onto("macau", "canton_country_trade")
                 or spoke_onto("hirado", "canton_country_trade"))
        ),
        "busan_spoke_on_canton": spoke_onto("busan", "canton_country_trade"),
        "mombasa_spoke_le_40_on_swahili": spoke_onto(
            "mombasa", "swahili_coast", SPOKE_RADIUS_TILES),
        "pacific_america_spokes": all(
            spoke_onto(port_id, "pacific_america") for port_id in pacific_ports),
        "west_africa_spokes": all(
            spoke_onto(port_id, "west_africa") for port_id in africa_ports),
    }
    if not all(probes.values()):
        failed = [name for name, ok in probes.items() if not ok]
        raise BuildError(
            f"junction graph probes failed: {', '.join(failed)} — the built "
            f"network does not connect the named port/lane pairs")

    lane_records = []
    for lane in lanes:
        lane_id = lane["id"]
        lane_records.append({
            "id": lane_id,
            "class": lane["class"],
            "waypoint_count": len(lane["waypoints"]),
            "tile_count": len(lane_paths[lane_id]),
            "tile_path": [[x, y] for x, y in lane_paths[lane_id]],
            "variants": [
                {
                    "id": variant["id"],
                    "months": variant["months"],
                    "tile_count": len(variant["tile_path"]),
                    "tile_path": [[x, y] for x, y in variant["tile_path"]],
                }
                for variant in variants_by_lane.get(lane_id, [])
            ],
        })

    tile_total = sum(len(record["tile_path"]) for record in lane_records)
    tile_total += sum(len(record["tile_path"]) for record in spoke_records)
    artifact = {
        "version": 1,
        "generated_by": "tools/build_routes.py",
        "artifact": "data/trade_routes_built.json",
        "build": {
            "grid": {"width": grid.w, "height": grid.h},
            "tiles_per_degree": grid.tiles_per_degree(),
            "waypoint_snap_radius_tiles": WAYPOINT_SNAP_TILES,
            "spoke_radius_tiles": SPOKE_RADIUS_TILES,
            "walk_rule": "8-direction straight-line raster walk, corner "
                         "cutting forbidden, x wraps mod 4320; per-segment "
                         "passability is a hard build error",
            "spoke_rule": "one spoke per port: walk-aware lane rule — the "
                          "first in-radius (Chebyshev "
                          f"{SPOKE_RADIUS_TILES}, wrap-aware; ties smallest "
                          "(y, x), then lane file order, then waypoint "
                          "index) lane waypoint whose straight walk "
                          "succeeds, else the passable direct walk to the "
                          "national capital, else the "
                          "tools/route_overrides.json spoke (A*-pathfound), "
                          "else for a neutral port the nearest lane "
                          "waypoint unbounded (A*); a port with none is a "
                          "hard error; an override is superseded exactly "
                          "when the lane rule succeeds",
            "junction_rule": "node = tile shared by >= 2 distinct paths or a "
                             "path endpoint, keyed (x mod 4320, y); each path "
                             "splits at its nodes into edges weighted by "
                             "tile steps",
            "month_rule": "per lane and month 1..12 the active path (a "
                          "variant whose months contain the month, else the "
                          "base waypoints) must walk with that month's "
                          "seasonal-ice mask active (data/ice_regions.json "
                          "polygons; §4.14, §4.18); variant paths are "
                          "carried per lane for the runtime's in-month "
                          "selection and do not join the junction graph",
            "sources": {
                name: {"path": str(path.relative_to(ROOT)),
                       "sha256": sha256_file(path)}
                for name, path in INPUT_SOURCES
            },
        },
        "lanes": lane_records,
        "spokes": spoke_records,
        "junctions": {
            "node_count": len(nodes),
            "nodes": [[x, y] for x, y in nodes],
            "edge_count": len(edges),
            "edges": edges,
        },
    }

    report = {
        "report": "build_routes",
        "artifact": "data/trade_routes_built.json",
        "counts": {
            "lanes": len(lanes),
            "waypoints": sum(len(lane["waypoints"]) for lane in lanes),
            "variant_waypoints": sum(
                len(lane.get("variants") or []) for lane in lanes),
            "ports": len(ports),
            "spokes": spoke_counts,
            "junction_nodes": len(nodes),
            "junction_edges": len(edges),
            "route_tiles": tile_total,
        },
        "snap": {
            "radius_tiles": WAYPOINT_SNAP_TILES,
            "max_distance": max(s["max_snap_distance"] for s in snap_stats),
            "at_radius": sum(s["waypoints_at_snap_radius"] for s in snap_stats),
            "per_lane": snap_stats,
        },
        "segments": {
            "count": sum(len(lane["waypoints"]) - 1 for lane in lanes),
            "failed": [],
        },
        "months": {
            "ice_regions": ice_sources,
            "per_lane": month_stats,
        },
        "spokes": {
            "by_kind": spoke_counts,
            "capital": [r["port"] for r in spoke_records
                        if r["kind"] == "capital"],
            "overrides": [
                {"port": r["port"], "connect": r["connect"],
                 "via_points": len(r["via"]),
                 "path_tiles": len(r["tile_path"])}
                for r in spoke_records if r["kind"] == "override"
            ],
            "lengths": spoke_length_report(spoke_records),
        },
        "probes": probes,
    }
    return artifact, report, paths_by_key


def spoke_length_report(records: list[dict], top: int = 20) -> dict:
    """Spoke-length distribution: histogram + the longest spokes, named.

    The pinned intentional fringes (Oceania/``botany_bay``, the spice
    fringe, the North-American east coast, ``portobelo``'s portage) must top
    the longest list — the data input for any future lane decision
    (IMPLEMENT-Phase6 §2.11.1 fringe policy).
    """
    buckets = (
        ("1", lambda n: n == 1),
        ("2-5", lambda n: 2 <= n <= 5),
        ("6-10", lambda n: 6 <= n <= 10),
        ("11-20", lambda n: 11 <= n <= 20),
        ("21-40", lambda n: 21 <= n <= 40),
        ("41-80", lambda n: 41 <= n <= 80),
        ("81-160", lambda n: 81 <= n <= 160),
        ("161+", lambda n: n >= 161),
    )
    histogram = {name: 0 for name, _ in buckets}
    for record in records:
        length = len(record["tile_path"])
        for name, inside in buckets:
            if inside(length):
                histogram[name] += 1
                break
    longest = sorted(
        records, key=lambda r: (-len(r["tile_path"]), r["port"]))[:top]
    return {
        "histogram": histogram,
        "longest": [
            {
                "port": r["port"],
                "kind": r["kind"],
                "lane": r.get("lane", r.get("capital", "")),
                "tiles": len(r["tile_path"]),
            }
            for r in longest
        ],
    }


# --------------------------------------------------------------------------
# Serialization (deterministic) + the --check differ
# --------------------------------------------------------------------------
def serialize(artifact: dict) -> bytes:
    return (json.dumps(artifact, indent=2, ensure_ascii=False) + "\n").encode(
        "utf-8")


def diff_json_path(a, b, path: str = "$"):
    """First differing JSON path between two parsed documents, or None."""
    if type(a) is not type(b):
        return (path, _brief(a), _brief(b))
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a:
                return (f"{path}.{key}", "<missing>", _brief(b[key]))
            if key not in b:
                return (f"{path}.{key}", _brief(a[key]), "<missing>")
            hit = diff_json_path(a[key], b[key], f"{path}.{key}")
            if hit:
                return hit
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return (path, f"length {len(a)}", f"length {len(b)}")
        for i, (xa, xb) in enumerate(zip(a, b)):
            hit = diff_json_path(xa, xb, f"{path}[{i}]")
            if hit:
                return hit
        return None
    return None if a == b else (path, _brief(a), _brief(b))


def _brief(value, limit: int = 60) -> str:
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "…"


# --------------------------------------------------------------------------
# CLI commands
# --------------------------------------------------------------------------
def cmd_build(args) -> int:
    grid = load_world_grid()
    lanes, ports, nations, overrides_payload = load_inputs()
    artifact, report, _paths = build_artifact(grid, lanes, ports, nations,
                                              overrides_payload)
    blob = serialize(artifact)
    BUILT_PATH.write_bytes(blob)
    counts = report["counts"]
    print(
        f"build_routes: wrote {BUILT_PATH.relative_to(ROOT)} ({len(blob)} "
        f"bytes, sha256 {hashlib.sha256(blob).hexdigest()})",
        file=sys.stderr,
    )
    print(
        "build_routes: "
        f"{counts['lanes']} lanes / {counts['waypoints']} waypoints "
        f"(max snap {report['snap']['max_distance']}) / "
        f"{counts['ports']} spokes "
        f"({counts['spokes']['lane']} lane, {counts['spokes']['capital']} "
        f"capital, {counts['spokes']['override']} override, "
        f"{counts['spokes'].get('fallback', 0)} fallback) / "
        f"{counts['junction_nodes']} junction nodes, "
        f"{counts['junction_edges']} edges | probes "
        f"{'ok' if all(report['probes'].values()) else 'FAILED'}",
        file=sys.stderr,
    )
    if args.report:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


def cmd_check(args) -> int:
    """Rebuild in memory and byte-compare against the committed artifact."""
    grid = load_world_grid()
    lanes, ports, nations, overrides_payload = load_inputs()
    artifact, _report, _paths = build_artifact(grid, lanes, ports, nations,
                                               overrides_payload)
    fresh = serialize(artifact)
    committed = BUILT_PATH.read_bytes()
    if fresh == committed:
        if args.verbose:
            print(
                f"build_routes: check OK — rebuild is byte-identical "
                f"({len(committed)} bytes)", file=sys.stderr)
        return 0
    where = diff_json_path(json.loads(committed.decode("utf-8")),
                           json.loads(fresh.decode("utf-8")))
    if where:
        print(
            f"build_routes: check FAILED — {BUILT_PATH.relative_to(ROOT)} "
            f"differs from the rebuild at {where[0]}: committed "
            f"{where[1]} vs rebuilt {where[2]}; fix "
            f"data/trade_routes.json or tools/route_overrides.json and "
            f"regenerate — never hand-edit the built file",
            file=sys.stderr,
        )
    else:
        print(
            f"build_routes: check FAILED — {BUILT_PATH.relative_to(ROOT)} "
            f"is byte-different from the rebuild but JSON-identical "
            f"(reformatting drift); regenerate with tools/build_routes.py",
            file=sys.stderr,
        )
    return 3


# --------------------------------------------------------------------------
# ASCII debug export (route overlay over the world map)
# --------------------------------------------------------------------------
def ascii_lines(grid: bw.Grid, paths_by_key: dict[str, list[tuple[int, int]]]
                ) -> list[str]:
    """Map rows with route overlay: X shared, * lane, + spoke, P endpoint."""
    table = bytes((ord(bw.CHARS[i]) if i < len(bw.CHARS) else ord("?"))
                  for i in range(256))
    lanes_tiles: set[tuple[int, int]] = set()
    spokes_tiles: set[tuple[int, int]] = set()
    shared_tiles: set[tuple[int, int]] = set()
    for key, path in paths_by_key.items():
        target = lanes_tiles if key.startswith("lane:") else spokes_tiles
        for tile in path:
            if tile in lanes_tiles or tile in spokes_tiles:
                shared_tiles.add(tile)
            target.add(tile)
    chars = []
    for row in grid.rows:
        chars.append(list(bytes(row).translate(table).decode("ascii")))
    for x, y in spokes_tiles:
        chars[y][x] = "+"
    for x, y in lanes_tiles:
        chars[y][x] = "*"
    for x, y in shared_tiles:
        chars[y][x] = "X"
    return ["".join(row) for row in chars]


def cmd_ascii(args) -> int:
    grid = load_world_grid()
    lanes, ports, nations, overrides_payload = load_inputs()
    _artifact, _report, paths_by_key = build_artifact(
        grid, lanes, ports, nations, overrides_payload)
    start, end = (parse_rows(args.rows, grid.h) if args.rows
                  else (1, grid.h))
    lines = ascii_lines(grid, paths_by_key)
    text = "\n".join(lines[start - 1:end]) + "\n"
    if args.ascii_out:
        out = Path(args.ascii_out)
        if DATA.resolve() in out.resolve().parents:
            print(
                "build_routes: refusing to write the ASCII debug export "
                f"under data/ ({out}); use a temp path", file=sys.stderr)
            return 2
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8", newline="\n")
        print(f"build_routes: wrote {end - start + 1} ASCII rows to {out}",
              file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


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
        description="Build data/trade_routes_built.json from the historical "
                    "lanes, the ports and tools/route_overrides.json "
                    "(deterministic; two builds are byte-identical).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--check", action="store_true",
        help="rebuild in memory and byte-compare against the committed "
             "artifact; exit 3 naming the first differing JSON path on drift",
    )
    parser.add_argument(
        "--ascii", action="store_true",
        help="debug export: the world map with the route overlay "
             "('X' shared tile, '*' lane, '+' spoke; stdout unless "
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
        print(f"build_routes: FAIL: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
