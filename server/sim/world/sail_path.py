"""``server.sim.world.sail_path`` — click-to-sail pathing (pure logic).

Python port of the frozen Godot-era ``scripts/world/sail_path.gd`` (parity
oracle until the M6 cutover; docs/IMPLEMENT-WebMigration.md M1). Contract
sources:

- ``docs/20-WORLD-AND-SAILING.md`` §4.2 — click-to-sail: an 8-directional,
  wind-blind, distance-optimal ``AStarGrid2D`` path over the 4320×2160 grid
  with ``DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`` (no corner cutting); the
  pinned two-stage architecture (near region Chebyshev ≤ ``NEAR_REGION_TILES``
  256 with ``REGION_MARGIN`` 24, else one full turn of the world in the
  local frame); the local-frame shift for seam-crossing queries.
- ``docs/90-ARCHITECTURE.md`` §9 — longitude wraps mod 4320 everywhere and
  the no-corner-cutting rule (a diagonal is blocked if either orthogonal
  neighbour of the target corner is impassable); §11 — the dateline edge
  case: a fleet at ``x = 4200`` clicking ``x = 50`` gets the short 170-step
  route across the ``4319 → 0`` seam, never the 4,150-step way round.
- Parity pins: ``tools/test_movement.gd`` (``_test_sail_path_module``,
  ``_test_corner_cut_impossible``, ``_test_dateline_click``);
  pytest port in ``server/tests/test_sail_path.py``.

The module is PURE: it never reads rasters, PNGs or data files. Passability
is injected as ``passable(x, y) -> bool`` over world coordinates with ``x``
already wrapped into ``[0, width)`` and ``y`` guaranteed in ``[0, height)``
— the module wraps and bounds before every call, mirroring the
``MapLoader.is_passable`` contract (§9), so the injected predicate can be a
plain grid lookup (the raster layer builds the real one from
``data/maps/world.png``).

Algorithm — the oracle's semantics over Godot's ``AStarGrid2D``:

- 8-directional A* with straight cost 1.0 and diagonal cost sqrt(2) — the
  engine defaults (``cell_size = (1, 1)`` and
  ``default_compute_heuristic = HEURISTIC_EUCLIDEAN``, i.e. the default
  per-step cost is the Euclidean distance between the cell ids) — and the
  engine's default estimate (``default_estimate_heuristic =
  HEURISTIC_EUCLIDEAN``), admissible and consistent under that cost model,
  so every returned path is cost-optimal (§4.2's "distance-optimal" pin;
  cost-optimal paths are exactly the tile-minimal ones under these costs).
  Open list: a binary heap with the engine's tie-break — lower ``f`` first,
  then the point FURTHER from the start (higher ``g``, the engine's
  ``SortPoints`` rule), then insertion order for full determinism.
- No corner cutting at expansion time, exactly the engine's
  ``DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`` neighbourhood rule: a diagonal is
  generated only when BOTH adjacent orthogonals are passable. The returned
  walk is then re-validated step-by-step with :func:`is_step_legal` — the
  oracle's pinned corner-cut guard — and a walk with any illegal step is
  discarded (stage ``illegal_step``) rather than returned.
- Two stages exactly as pinned (§4.2 locked decision 7): a near query on
  the endpoint bounding box expanded by ``margin`` whenever the local-frame
  Chebyshev span is ≤ ``near_tiles``, else — or when the near query finds
  no route inside its box — one full turn of the world (``width`` distinct
  columns, whole latitude range) in the local frame. The engine's
  ``jumping_enabled`` on the near stage is a search-granularity
  optimisation only: the oracle expands jumped segments back into unit
  steps before validating them, so the unit-step output contract here is
  identical without it.
- Seam handling (§4.2 / §11): both endpoints are shifted into a local
  frame — the fleet at local ``x = 0``, the target at the short-way signed
  :func:`short_dx` offset (``|dx| ≤ width / 2``, ties staying positive) —
  the search runs there, and the path is shifted back with ``posmod``.
- Result: the unit steps AFTER ``start`` (excludes ``start``, ends exactly
  on the wrapped ``goal``), world coordinates with ``x`` in ``[0, width)``.
  The documented no-path result is the EMPTY LIST — the same ``[]`` the
  GDScript returns for an unreachable target, a land/ice/off-grid endpoint,
  the fleet's own cell (``same_cell``) or a degenerate map; it never
  returns ``null``.

Stage tags (``same_cell`` / ``near_region`` / ``full_region`` / ``no_path``
/ ``illegal_step`` / ``bad_map``) mirror the oracle's ``last_stage``
diagnostics; pass a :class:`PathDiag` to read them.

Note on scale: the full-region stage means ``width × height`` passability
lookups per query (9.33 M cells on the shipped world). The oracle's
measured verdict (§4.2, Phase-6 re-benchmark) stands: every legal click is
answered by the near stage — the ``80-*`` viewport is ~40×23 tiles, so
chart-scale queries do not exist in the input surface. The ``BUDGET_MS``
constant is the task's path budget from the oracle (its measurement rides
the M1 day-tick spike, not this module).
"""

from __future__ import annotations

import heapq
import math
import time
from collections.abc import Callable
from dataclasses import dataclass

Cell = tuple[int, int]
Passable = Callable[[int, int], bool]

# The §6.1 locked grid constants (Phase-6 rescale) and the §4.2 architecture
# constants — mirrored verbatim from the oracle module.
WORLD_WIDTH = 4320
WORLD_HEIGHT = 2160
REGION_MARGIN = 24
NEAR_REGION_TILES = 256
BUDGET_MS = 1000.0

_SQRT2 = math.sqrt(2.0)

# Stage tags for PathDiag.stage (oracle last_stage values, verbatim).
STAGE_SAME_CELL = "same_cell"
STAGE_NEAR = "near_region"
STAGE_FULL = "full_region"
STAGE_NO_PATH = "no_path"
STAGE_ILLEGAL = "illegal_step"
STAGE_BAD_MAP = "bad_map"

# Neighbour push order of AStarGrid2D._get_nbors: orthogonals (top, right,
# bottom, left), then diagonals (top-left, top-right, bottom-right,
# bottom-left), each diagonal gated on both adjacent orthogonals being
# free — DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES.
_ORTHOGONAL: tuple[tuple[str, int, int], ...] = (
    ("top", 0, -1),
    ("right", 1, 0),
    ("bottom", 0, 1),
    ("left", -1, 0),
)
_DIAGONAL: tuple[tuple[tuple[str, str], int, int], ...] = (
    (("left", "top"), -1, -1),
    (("top", "right"), 1, -1),
    (("right", "bottom"), 1, 1),
    (("bottom", "left"), -1, 1),
)


@dataclass
class PathDiag:
    """Diagnostics of the most recent :func:`find_path` call.

    Mirrors the oracle's ``last_stage`` / ``last_region`` / ``last_raw_points``
    / ``last_ms`` instance fields (``last_jumping`` has no analogue: the
    engine's jump-point mode only changes internal segment granularity, and
    this port always emits unit steps).
    """

    stage: str = ""
    region: tuple[int, int, int, int] | None = None  # Rect2i (x, y, w, h)
    raw_points: int = 0
    ms: float = 0.0


def short_dx(from_x: int, to_x: int, width: int = WORLD_WIDTH) -> int:
    """Shortest signed ``dx`` between two columns on a wrapping grid.

    ``|result| ≤ width // 2`` and ``to_x == (from_x + result) % width``;
    a half-turn offset (``dx == width // 2`` exactly) stays positive —
    ties do not flip (pinned in ``tools/test_movement.gd``).
    """
    if width <= 0:
        return to_x - from_x
    dx = (to_x - from_x) % width  # posmod: non-negative for width > 0
    if dx > width // 2:
        dx -= width
    return dx


def local_to_world(origin: Cell, local_cell: Cell,
                   width: int = WORLD_WIDTH) -> Cell:
    """Local-frame cell → world cell; :func:`world_to_local` is the inverse."""
    return ((origin[0] + local_cell[0]) % width, local_cell[1])


def world_to_local(origin: Cell, world_cell: Cell,
                   width: int = WORLD_WIDTH) -> Cell:
    """The inverse of :func:`local_to_world`."""
    return ((world_cell[0] - origin[0]) % width, world_cell[1])


def _passable_at(passable: Passable, width: int, height: int,
                 x: int, y: int) -> bool:
    """Wrap-aware, y-bounded passability (the §9 ``is_passable`` contract)."""
    if y < 0 or y >= height:
        return False
    return bool(passable(x % width, y))


def is_step_legal(passable: Passable, width: int, height: int,
                  frm: Cell, to: Cell) -> bool:
    """The §4.2 single-step rule, wrap-aware in ``x``.

    8-directional, passable target, and a diagonal needs BOTH orthogonals
    passable (no corner cutting). Mirrors the oracle's ``is_step_legal``
    (and ``SailingSim.is_move_legal`` for a returned path walk).
    """
    if width <= 0 or height <= 0:
        return False
    dx = short_dx(frm[0], to[0], width)
    dy = to[1] - frm[1]
    if (dx == 0 and dy == 0) or abs(dx) > 1 or abs(dy) > 1:
        return False
    if not _passable_at(passable, width, height, to[0], to[1]):
        return False
    if dx != 0 and dy != 0:
        if not _passable_at(passable, width, height, frm[0] + dx, frm[1]):
            return False
        if not _passable_at(passable, width, height, frm[0], frm[1] + dy):
            return False
    return True


def _illegal_steps(passable: Passable, width: int, height: int,
                   path: list[Cell]) -> bool:
    """True when any consecutive pair of ``path`` is not one legal §4.2 step."""
    for index in range(1, len(path)):
        if not is_step_legal(passable, width, height,
                             path[index - 1], path[index]):
            return True
    return False


def _full_region(width: int, height: int, dx: int) -> tuple[int, int, int, int]:
    """One turn of the world in the local frame: Rect2i (x, y, w, h).

    Exactly ``width`` distinct columns containing both local x = 0 (the
    fleet) and ``dx`` (the target, the short-way signed offset, so
    ``|dx| ≤ width // 2``); the fleet ends up mid-ring so a route may
    detour either way round it. The window ``[-width // 2, width // 2)``
    is nudged by one when ``dx`` sits exactly on the high edge.
    """
    x_lo = -(width // 2)
    if dx >= x_lo + width:
        x_lo = dx - width + 1
    return (x_lo, 0, width, height)


def _astar(passable: Passable, width: int, height: int, origin_x: int,
           region: tuple[int, int, int, int], start: Cell,
           goal: Cell) -> list[Cell] | None:
    """One region-bounded A* in the local frame, or ``None`` (no route).

    Costs and heuristic are the AStarGrid2D defaults (Euclidean per-step
    cost 1.0 / sqrt(2), Euclidean estimate — admissible), the expansion
    neighbourhood is DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES, and the open list
    is a binary heap with the engine's ``(f, then higher g)`` priority made
    total by insertion order. Solidity is marked straight from the injected
    predicate over the whole region first (the oracle's ``_mark_solid``
    running-index pattern; one wrap check per row, no per-cell posmod).
    """
    rx, ry, rw, rh = region
    x_end = rx + rw - 1
    y_end = ry + rh - 1

    solid: set[Cell] = set()
    for y in range(ry, y_end + 1):
        world_x = (origin_x + rx) % width
        for x in range(rx, x_end + 1):
            if not passable(world_x, y):
                solid.add((x, y))
            world_x += 1
            if world_x == width:
                world_x = 0

    if start in solid or goal in solid:
        return None

    g_score: dict[Cell, float] = {start: 0.0}
    came: dict[Cell, Cell] = {}
    closed: set[Cell] = set()
    goal_x, goal_y = goal
    # Heap entries (f, -g, order, cell): the engine's SortPoints order —
    # lower f first; on an f tie the point FURTHER from the start wins —
    # made a strict total order by the insertion counter.
    open_heap: list[tuple[float, float, int, Cell]] = [
        (math.hypot(goal_x - start[0], goal_y - start[1]), 0.0, 0, start)
    ]
    counter = 1
    while open_heap:
        _f, _neg_g, _order, current = heapq.heappop(open_heap)
        if current in closed:
            continue
        closed.add(current)
        if current == goal:
            path = [current]
            while current in came:
                current = came[current]
                path.append(current)
            path.reverse()
            return path
        cx, cy = current
        g_current = g_score[current]
        flags: dict[str, bool] = {}
        candidates: list[tuple[int, int, int, int]] = []
        for name, ddx, ddy in _ORTHOGONAL:
            nx, ny = cx + ddx, cy + ddy
            ok = (rx <= nx <= x_end and ry <= ny <= y_end
                  and (nx, ny) not in solid)
            flags[name] = ok
            if ok:
                candidates.append((nx, ny, ddx, ddy))
        for gates, ddx, ddy in _DIAGONAL:
            nx, ny = cx + ddx, cy + ddy
            # No corner cutting: both orthogonals of the diagonal must be
            # free (in-region and passable) — the ONLY_IF_NO_OBSTACLES rule
            # — and the diagonal cell itself must be passable.
            if flags[gates[0]] and flags[gates[1]] and (nx, ny) not in solid:
                candidates.append((nx, ny, ddx, ddy))
        for nx, ny, ddx, ddy in candidates:
            nxt = (nx, ny)
            if nxt in closed:
                continue
            step_cost = _SQRT2 if (ddx != 0 and ddy != 0) else 1.0
            tentative = g_current + step_cost
            known = g_score.get(nxt)
            if known is not None and known <= tentative:
                continue
            g_score[nxt] = tentative
            came[nxt] = current
            heapq.heappush(open_heap, (
                tentative + math.hypot(goal_x - nx, goal_y - ny),
                -tentative, counter, nxt))
            counter += 1
    return None


def _query(passable: Passable, width: int, height: int, origin: Cell,
           local_goal: Cell, region: tuple[int, int, int, int],
           ) -> tuple[list[Cell] | None, str, int]:
    """One AStarGrid2D query in ``region`` (local frame; fleet at local x=0).

    Returns ``(path, stage, raw_points)`` where a silent failure (endpoints
    outside the region / solid, empty raw path) carries stage ``""`` — the
    caller decides the final tag — and a walk that broke the §4.2 rule
    carries ``illegal_step``.
    """
    rx, ry, rw, rh = region
    start = (0, origin[1])
    goal = (local_goal[0], local_goal[1])
    if not (rx <= start[0] <= rx + rw - 1 and ry <= start[1] <= ry + rh - 1):
        return None, "", 0
    if not (rx <= goal[0] <= rx + rw - 1 and ry <= goal[1] <= ry + rh - 1):
        return None, "", 0
    raw = _astar(passable, width, height, origin[0], region, start, goal)
    if raw is None or len(raw) < 2:
        return None, "", 0
    path, stage = _expand_and_validate(passable, width, height, origin,
                                       raw, goal)
    return path, stage, len(raw)


def _expand_and_validate(passable: Passable, width: int, height: int,
                         origin: Cell, raw: list[Cell], goal_local: Cell,
                         ) -> tuple[list[Cell] | None, str]:
    """Raw local-frame points → validated world unit steps after ``origin``.

    Expands every (jumped) segment into unit steps in the local frame,
    shifts the whole walk to world cells, and re-validates each step (§4.2).
    Returns ``([], illegal_step)`` when a segment cannot be walked without
    cutting a corner — with unit-step A* output this is a dead guard, kept
    because it is the oracle's pinned corner-cut proof.
    """
    walk: list[Cell] = [raw[0]]
    for index in range(1, len(raw)):
        target = raw[index]
        cursor = walk[-1]
        ddx = target[0] - cursor[0]
        ddy = target[1] - cursor[1]
        sx = (ddx > 0) - (ddx < 0)
        sy = (ddy > 0) - (ddy < 0)
        guard = 0
        while cursor != target:
            guard += 1
            if guard > abs(ddx) + abs(ddy) + 8:
                return [], STAGE_ILLEGAL
            cursor = (cursor[0] + sx, cursor[1] + sy)
            walk.append(cursor)
        if walk[-1] != target:
            return [], STAGE_ILLEGAL
    if len(walk) < 2 or walk[-1] != goal_local:
        return [], STAGE_ILLEGAL
    world = [local_to_world(origin, cell, width) for cell in walk]
    if _illegal_steps(passable, width, height, world):
        return [], STAGE_ILLEGAL
    return world[1:], ""


def find_path(passable: Passable, width: int, height: int,
              start: Cell, goal: Cell, *,
              margin: int = REGION_MARGIN,
              near_tiles: int = NEAR_REGION_TILES,
              diag: PathDiag | None = None) -> list[Cell]:
    """The walkable route from ``start`` to ``goal`` (world cells; x wraps).

    Returns the unit steps AFTER ``start``, ending exactly on the wrapped
    ``goal`` — or the empty list when there is no sea route, an endpoint is
    impassable or off-grid (y), both cells are the same (after wrapping) or
    the map is degenerate; never mutates the caller's data. ``margin`` and
    ``near_tiles`` shape the near region exactly like the oracle's ``opts``
    (they exist for the tests). ``diag``, when given, receives the
    ``last_*`` diagnostics.

    Pure: reads nothing but the injected ``passable`` predicate.
    """
    started = time.perf_counter()
    empty: list[Cell] = []
    stage = ""
    region: tuple[int, int, int, int] | None = None
    raw_points = 0

    def finish(result: list[Cell], final_stage: str) -> list[Cell]:
        if diag is not None:
            diag.stage = final_stage
            diag.region = region
            diag.raw_points = raw_points
            diag.ms = (time.perf_counter() - started) * 1000.0
        return result

    if width <= 0 or height <= 0:
        return finish(empty, STAGE_BAD_MAP)
    origin = (start[0] % width, start[1])
    goal_c = (goal[0] % width, goal[1])
    if (origin[1] < 0 or origin[1] >= height
            or goal_c[1] < 0 or goal_c[1] >= height
            or not _passable_at(passable, width, height, origin[0], origin[1])
            or not _passable_at(passable, width, height, goal_c[0], goal_c[1])):
        return finish(empty, STAGE_NO_PATH)
    if origin == goal_c:
        return finish(empty, STAGE_SAME_CELL)

    # Local frame (§4.2 / §11): the fleet's column is local x = 0, the
    # target sits at the short-way signed dx.
    dx = short_dx(origin[0], goal_c[0], width)
    local_goal = (dx, goal_c[1])

    if max(abs(dx), abs(goal_c[1] - origin[1])) <= near_tiles:
        # The endpoint bounding box plus the margin, clamped to the grid in
        # y (never in x — this is the local frame). At most
        # 2 * NEAR_REGION_TILES + 2 * REGION_MARGIN columns, far below the
        # shipped width, so no world column repeats inside it.
        x_lo = min(0, dx) - margin
        x_hi = max(0, dx) + margin
        y_lo = max(0, min(origin[1], goal_c[1]) - margin)
        y_hi = min(height - 1, max(origin[1], goal_c[1]) + margin)
        region = (x_lo, y_lo, x_hi - x_lo + 1, y_hi - y_lo + 1)
        path, stage, raw_points = _query(passable, width, height, origin,
                                         local_goal, region)
        if path:
            return finish(path, STAGE_NEAR)
        if stage == STAGE_ILLEGAL:
            # A segment broke the walking rule: fall through to the full
            # stage rather than hand the caller a bad path.
            stage = ""

    # Full local frame: one turn of the world (every column exactly once),
    # whole latitude range, both endpoints inside it.
    region = _full_region(width, height, dx)
    path, stage, raw_points = _query(passable, width, height, origin,
                                     local_goal, region)
    if path:
        return finish(path, STAGE_FULL)
    return finish(empty, stage if stage else STAGE_NO_PATH)


__all__ = [
    "BUDGET_MS",
    "NEAR_REGION_TILES",
    "REGION_MARGIN",
    "STAGE_BAD_MAP",
    "STAGE_FULL",
    "STAGE_ILLEGAL",
    "STAGE_NEAR",
    "STAGE_NO_PATH",
    "STAGE_SAME_CELL",
    "WORLD_HEIGHT",
    "WORLD_WIDTH",
    "Cell",
    "Passable",
    "PathDiag",
    "find_path",
    "is_step_legal",
    "local_to_world",
    "short_dx",
    "world_to_local",
]
