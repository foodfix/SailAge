"""fleet_path.gd — the pursuit A* family (unit-cost + weighted), ported.

Canonical home of ``scripts/world/fleet_path.gd`` (M1 wave D): the
unit-cost search is the hunter chase's only runtime pathfinding, and the
weighted variant is the §4.19 appointed-voyage / wind-aware search
(``60-*`` §4.11.11.5 zero-A* gate for lane traffic). Pure functions over
injected passability/cost callables — no raster, no data, no RNG.

Split out of ``server/sim/world/npc_fleets.py`` in the post-wave
single-owner pass: ``npc_fleets`` and ``autopilot`` both consume it and
must not drift (one implementation, two callers).
"""

from __future__ import annotations

import heapq
from typing import Any, Callable, Final

#: Hard expansion ceiling of the unit-cost pursuit search (a guard only).
MAX_EXPANSIONS: Final[int] = 40000

#: Runaway guard of the weighted search (cross-ocean appointments).
MAX_EXPANSIONS_WEIGHTED: Final[int] = 200000

#: Bounded-suboptimality inflation of the weighted heuristic (Weighted A*).
HEURISTIC_WEIGHT: Final[float] = 2.0

#: §4.4 maximum propulsion bound: best direction factor 1.30 × best current
#: factor 1.25 (padded so the float bound can never dip under the minimum).
MIN_STEP_FACTOR_BOUND: Final[float] = 1.30 * 1.25

#: The oracle's neighbour push order (orthogonals, then diagonals).
NEIGHBOURS: Final[tuple[tuple[int, int], ...]] = (
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (1, -1), (-1, 1), (1, 1),
)


def _fp_h(a: tuple[int, int], b: tuple[int, int], width: int) -> int:
    """Wrap-aware Chebyshev heuristic (admissible for unit step costs)."""
    dx = abs(a[0] - b[0]) % width
    return max(min(dx, width - dx), abs(a[1] - b[1]))


def _fp_h_float(a: tuple[int, int], b: tuple[int, int], width: int) -> float:
    """The weighted search's float Chebyshev (same domain as :func:`_fp_h`)."""
    dx = abs(a[0] - b[0]) % width
    return float(max(min(dx, width - dx), abs(a[1] - b[1])))


def _fp_key(cell: tuple[int, int], width: int) -> int:
    return int(cell[1]) * width + int(cell[0] % width)


def _fp_cell(key: int, width: int) -> tuple[int, int]:
    return (int(key % width), int(key // width))


def _fp_rebuild(came: dict[int, int], end_key: int,
                width: int) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    key = end_key
    while True:
        out.insert(0, _fp_cell(key, width))
        parent = came.get(key)
        if parent is None:
            break
        key = parent
    return out


def find_path(frm: tuple[int, int], to: tuple[int, int], width: int,
              height: int, passable: Callable[[tuple[int, int]], bool],
              ) -> list[tuple[int, int]]:
    """Shortest passable path ``[from, …, to]`` (empty when none).

    The oracle's ``FleetPath.find_path``: 8-direction, x wraps mod
    ``width``, y bounded, diagonals never cut corners (both orthogonals
    must be passable). ``passable`` is injected over WRAPPED cells.
    Deterministic open-list order ``(f, then cell key)`` — the oracle's
    linear ``_pop_min`` made total by the unique cell key.
    """
    if width <= 0 or height <= 0:
        return []
    if frm == to:
        return [frm]
    to_y = to[1]
    if to_y < 0 or to_y >= height:
        return []
    to_wrapped = (to[0] % width, to_y)
    if not passable(to_wrapped):
        return []
    gscore: dict[int, float] = {_fp_key(frm, width): 0.0}
    came: dict[int, int] = {}
    open_heap: list[tuple[float, int]] = [
        (float(_fp_h(frm, to_wrapped, width)), _fp_key(frm, width))]
    closed: set[int] = set()
    expansions = 0
    while open_heap:
        _f, current_key = heapq.heappop(open_heap)
        if current_key in closed:
            continue
        closed.add(current_key)
        current = _fp_cell(current_key, width)
        expansions += 1
        if expansions > MAX_EXPANSIONS:
            return []
        if current == to_wrapped:
            return _fp_rebuild(came, current_key, width)
        for step in NEIGHBOURS:
            nxt = ((current[0] + step[0]) % width, current[1] + step[1])
            if nxt[1] < 0 or nxt[1] >= height:
                continue
            if not passable(nxt):
                continue
            if step[0] != 0 and step[1] != 0:
                # No corner cutting (the builder's shared walk rule).
                if not passable(((current[0] + step[0]) % width, current[1])):
                    continue
                if not passable((current[0], current[1] + step[1])):
                    continue
            next_key = _fp_key(nxt, width)
            if next_key in closed:
                continue
            tentative = gscore[_fp_key(current, width)] + 1.0
            known = gscore.get(next_key)
            if known is not None and known <= tentative:
                continue
            gscore[next_key] = tentative
            came[next_key] = current_key
            heapq.heappush(open_heap,
                           (tentative + float(_fp_h(nxt, to_wrapped, width)),
                            next_key))
    return []


def find_path_weighted(
        frm: tuple[int, int], to: tuple[int, int], width: int, height: int,
        passable: Callable[[tuple[int, int]], bool],
        cost_fn: Callable[[tuple[int, int], tuple[int, int]], float],
        opts: dict[str, Any] | None = None,
) -> list[tuple[int, int]]:
    """The §4.19 wind/current-weighted A* (Weighted A*).

    Identical search domain to :func:`find_path` (8-direction, x wraps,
    y bounded, no corner cutting) but each step costs
    ``cost_fn(from, to) > 0`` (the caller builds it as
    ``1 / (wind_factor × current_factor)`` — a head-wind step costs more
    days). ``opts``: ``min_step_cost`` (default
    ``1 / MIN_STEP_FACTOR_BOUND``), ``h_weight`` (default
    :data:`HEURISTIC_WEIGHT`), ``max_expansions`` (default
    :data:`MAX_EXPANSIONS_WEIGHTED`). Returns ``[from, …, to]`` or ``[]``
    on an unreachable/impassable goal or guard overflow. The open list is
    a binary heap ordered by the same deterministic ``(f, key)`` tuple as
    the unit core.
    """
    if width <= 0 or height <= 0:
        return []
    if frm == to:
        return [frm]
    to_y = to[1]
    if to_y < 0 or to_y >= height:
        return []
    to_wrapped = (to[0] % width, to_y)
    if not passable(to_wrapped):
        return []
    config = opts or {}
    min_step = float(config.get("min_step_cost", 1.0 / MIN_STEP_FACTOR_BOUND))
    h_weight = float(config.get("h_weight", HEURISTIC_WEIGHT))
    max_expansions = int(config.get("max_expansions", MAX_EXPANSIONS_WEIGHTED))
    from_wrapped = (frm[0] % width, frm[1])
    gscore: dict[int, float] = {_fp_key(from_wrapped, width): 0.0}
    came: dict[int, int] = {}
    open_heap: list[tuple[float, int]] = [(
        _fp_h_float(from_wrapped, to_wrapped, width) * min_step * h_weight,
        _fp_key(from_wrapped, width))]
    closed: set[int] = set()
    expansions = 0
    while open_heap:
        _f, current_key = heapq.heappop(open_heap)
        if current_key in closed:
            continue
        closed.add(current_key)
        current = _fp_cell(current_key, width)
        expansions += 1
        if expansions > max_expansions:
            return []
        if current == to_wrapped:
            return _fp_rebuild(came, current_key, width)
        g_current = gscore[current_key]
        for step in NEIGHBOURS:
            nxt = ((current[0] + step[0]) % width, current[1] + step[1])
            if nxt[1] < 0 or nxt[1] >= height:
                continue
            if not passable(nxt):
                continue
            if step[0] != 0 and step[1] != 0:
                if not passable(((current[0] + step[0]) % width, current[1])):
                    continue
                if not passable((current[0], current[1] + step[1])):
                    continue
            next_key = _fp_key(nxt, width)
            if next_key in closed:
                continue
            tentative = g_current + float(cost_fn(current, nxt))
            known = gscore.get(next_key)
            if known is not None and float(known) <= tentative:
                continue
            gscore[next_key] = tentative
            came[next_key] = current_key
            heapq.heappush(open_heap, (
                tentative + _fp_h_float(nxt, to_wrapped, width)
                * min_step * h_weight, next_key))
    return []
