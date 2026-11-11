"""``server.sim.world.npc_fleets`` — the living NPC fleet ecology (M1).

Python port of the frozen Godot-era ``scripts/world/npc_fleets.gd`` (the
parity oracle until the M6 cutover) plus the pursuit pathing half of
``scripts/world/fleet_path.gd``. Contract sources:

- ``docs/60-COMBAT.md`` §4.1 — the 8-role fleet ecology, the §4.1.1 role
  budgets, the §4.1.2 spawn flow (initial fill = half the core cap, daily
  trickle ``max(4, ceil(cap / 50))``, ``absolute_cap``); §4.11.11 — the
  ``npc_fleets`` save block, lane routing (junction-graph Dijkstra + legs),
  hunter intel, stepping, contact; §4.11.11.1 — the unified-movement
  amendment (per-move clock accrual, co-location, per-tile contact); the
  Phase-6 parity/seasons amendment (direction/current factors, monthly lane
  variants with endpoint-identity resolution); §4.11.11.2 — auto-resolve,
  wrecks, the player-contact table; §4.11.11.3 — the S10 contact handoff
  (``pending_encounter`` descriptor); §4.11.11.4 — convoys, named pirates,
  treasure fleets, canon captains, wake trails, the port-traffic log;
  §4.11.14 — NPC trade at ports (effective-alignment docking, nationless
  grey coasters, tariff crediting); §4.11.15 — the captain lifecycle.
- ``docs/10-DATA-SCHEMA.md`` §4.10 (``npc_config``), §4.14 (the built route
  artifact), §4.15 (the fleet/wreck save shapes).
- ``docs/90-ARCHITECTURE.md`` §0 (web-stack era: pure logic, injected
  state), §5.4 (day-tick order), §5.6 (contact stays with the caller — this
  module never opens battles), §8.1 (save keys, ``proximity_cooldowns``).
- ``docs/30-PORTS-AND-TRADE.md`` §4.4 (the trader decision), §4.9/§4.10
  (effective alignment + the unified tariff).

State convention (the M1 port rule): the GDScript statics read/mutate the
``GameState`` autoload. Here one explicit :class:`FleetEcologyState` owns
the four ecology blocks (``npc_fleets``, ``wrecks``, ``npc_port_log``,
``proximity_cooldowns``) plus the run clock (``day``/``world``), the player
reputation map and the ``captain_states`` return queue; the economy and
allegiance run states are injected (:class:`EconomyState` /
:class:`AllegianceState`) exactly as their own modules expect. Content
lookups read :mod:`server.sim.data` where the GDScript reads
``DataLoader``; the world raster/ocean lookups go through an injected
:class:`RasterWorld` adapter (default: the ``raster.py`` singletons).

RNG discipline (§4.11.11 / task-H pin 3): every draw is the Phase-2 seeded
formula family (``day × 1000003 + x × 7919 + y × 104729``) through the
bit-exact :class:`~server.sim.rng.GodotRng`, keyed by the fleet's own
persisted ``seed`` — there is no global RNG state and every draw replays
from saved fields alone. The instance stream (``reset_rng``) exists only as
the oracle's test seam (it is seeded but never drawn, exactly like the
GDScript). The call order is preserved verbatim (see the tests' pinned
draws).

The pursuit A* lives here (the oracle's ``fleet_path.gd`` was deliberately
left for this port): :func:`find_path` is the unit-cost, wrap-aware,
no-corner-cutting search the hunter chase consumes, and
:func:`find_path_weighted` is the §4.19 wind/current-weighted variant
(Weighted A*, ``HEURISTIC_WEIGHT`` 2.0, ``MAX_EXPANSIONS_WEIGHTED``
200000, ``min_step_cost = 1 / (1.30 × 1.25)``) the appointed-voyage caller
will consume. Both are pure: passability and the step cost arrive as
callables.

Not ported (render-side, retires with the runtime tree at M6): the
``Palette`` marker colour/owner helpers (``80-*`` §4.5.2) and the hover's
``dbg``/``dbg2``/``dbg3`` debug strings (``95-*``). ``marker_letter`` is
kept (pure, no palette). ``markers()`` carries the render dict fields the
aliveness rules own (sailing, wake, convoy grouping, stall state, dwell,
heading, ship type, speed).
"""

from __future__ import annotations

import copy
import heapq
import importlib.util
import math
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Final

from server.sim.data import DataStore, data
from server.sim.port import allegiance as allegiance_lib
from server.sim.port import economy as economy_lib
from server.sim.port import trade as trade_lib
from server.sim.port.allegiance import AllegianceState
from server.sim.port.economy import EconomyState, godot_string_hash
from server.sim.player import PersonState
from server.sim.rng import GodotRng
from server.sim.world import raster as raster_module

__all__ = [
    # fleet_path.gd (pursuit A* family)
    "MAX_EXPANSIONS",
    "MAX_EXPANSIONS_WEIGHTED",
    "HEURISTIC_WEIGHT",
    "MIN_STEP_FACTOR_BOUND",
    "NEIGHBOURS",
    "find_path",
    "find_path_weighted",
    # constants
    "TRADER", "COASTER", "PATROL", "COURIER", "PRIVATEER", "PIRATE",
    "HUNTER", "TREASURE", "FILL_ORDER", "ROLES", "KIND_TO_ROLE",
    "SPAWN_IMMUNITY_DAYS", "CONTACT_DISTANCE", "NAVY_HOSTILE_REPUTATION",
    "DWELL_DAYS", "WRECK_DESPAWN_DAYS", "PORT_LOG_MAX", "COASTER_DWELL_DAYS",
    "TREASURE_BASE_DAY", "TREASURE_NATION_STEP", "TREASURE_SEASON_DAYS",
    "WAKE_LENGTH", "STALL_HOLD_TICKS", "BUCKET_SIZE",
    "HUNTER_STATE_INTEL", "HUNTER_STATE_LOITER", "HUNTER_STATE_CHASE",
    "HUNTER_STATE_HOME", "HUNTER_CHASE_ON", "HUNTER_CHASE_OFF",
    "HUNTER_LOITER_DAYS", "ANCHOR_RADIUS", "CHASE_ON_RADIUS",
    "CHASE_OFF_RADIUS", "ZONE_RADIUS", "PREY_RADIUS", "ESCORT_RADIUS",
    "CONVOY_RADIUS", "CANDIDATE_RADIUS",
    # state + sim
    "FleetEcologyState",
    "RasterWorld",
    "NpcFleets",
    "reset_caches",
    # composition (ai_fleet.gd half)
    "HULL_IDS", "CANNON_BUDGET", "compose_enemy", "cannon_budget",
    "compose_fleet_ships", "salvage_for",
    # pure helpers
    "chebyshev", "position_of", "set_position", "cell_field",
    "marker_letter", "composition_kind", "is_hostile_fleet",
    "captain_card_of", "captain_tier_of", "captain_name",
    "famous_pirate_ids", "named_captain_of", "is_named_captain",
    "named_tier_of", "preferred_bounty_target", "treasure_due",
    "nation_index", "npc_direction_factor", "npc_current_factor",
    "month_for", "wind_factor", "heading_of_delta", "angle_between_dirs",
    "note_spawn_immunity", "spawn_allowed", "kind_role",
    "fleets_within",
]

# --- Locked numbers (docs/60-* §4.1, §4.11.11.1–.2) -------------------------

TRADER: Final[str] = "trader"
COASTER: Final[str] = "coaster"
PATROL: Final[str] = "patrol"
COURIER: Final[str] = "courier"
PRIVATEER: Final[str] = "privateer"
PIRATE: Final[str] = "pirate"
HUNTER: Final[str] = "hunter"
TREASURE: Final[str] = "treasure"

#: The 8 §4.1.1 roles (the fleet ``role`` domain).
ROLES: Final[tuple[str, ...]] = (
    TRADER, COASTER, PATROL, COURIER, PRIVATEER, PIRATE, HUNTER, TREASURE,
)

#: Spawn/trickle fill order (oracle task-owned): economy roles first,
#: raiders last, so the global cap can never starve traders for pirates.
FILL_ORDER: Final[tuple[str, ...]] = (
    TRADER, COASTER, PATROL, COURIER, PRIVATEER, PIRATE, HUNTER,
)

#: §4.1 kind → role map of the Phase-2 rename (``pirate``→``pirate``,
#: ``navy``→``hunter``). Retired marker kinds map onto the living roles.
KIND_TO_ROLE: Final[dict[str, str]] = {"pirate": PIRATE, "navy": HUNTER}

CONTACT_DISTANCE: Final[int] = 1
STALL_HOLD_TICKS: Final[int] = 3
NAVY_HOSTILE_REPUTATION: Final[int] = -50
PURSUIT_COOLDOWN_DAYS: Final[int] = 1
PIRACY_REPUTATION: Final[int] = -20
ZONE_RADIUS: Final[int] = 30
PREY_RADIUS: Final[int] = 10
ESCORT_RADIUS: Final[int] = 20
CONVOY_RADIUS: Final[int] = 3
ANCHOR_RADIUS: Final[int] = 6
CHASE_ON_RADIUS: Final[int] = 10
CHASE_OFF_RADIUS: Final[int] = 16
HUNTER_CHASE_ON: Final[int] = 30
HUNTER_CHASE_OFF: Final[int] = 40
HUNTER_LOITER_DAYS: Final[int] = 10

HUNTER_STATE_INTEL: Final[str] = "intel"
HUNTER_STATE_LOITER: Final[str] = "loiter"
HUNTER_STATE_CHASE: Final[str] = "chase"
HUNTER_STATE_HOME: Final[str] = "home"

CANDIDATE_RADIUS: Final[int] = 120
RISK_RADIUS: Final[int] = 5
RISK_MULT: Final[float] = 0.5
SPEC_MULT: Final[float] = 1.5
NOISE_MIN: Final[float] = 0.8
NOISE_MAX: Final[float] = 1.25
DWELL_DAYS: Final[int] = 2
RAIDER_WIN_CHANCE: Final[float] = 0.6
WRECK_DESPAWN_DAYS: Final[int] = 5
WARSHIP_WRECK_ROLES: Final[tuple[str, ...]] = (
    PATROL, PRIVATEER, HUNTER, PIRATE,
)
COMPOSITION_BUDGETS: Final[dict[str, int]] = {
    TRADER: 6, COASTER: 2, COURIER: 0, PATROL: 30, PRIVATEER: 20, PIRATE: 20,
}

TREASURE_BASE_DAY: Final[int] = 45
TREASURE_NATION_STEP: Final[int] = 15
TREASURE_SEASON_DAYS: Final[int] = 90
TREASURE_MERCHANT_HULLS: Final[int] = 3
TREASURE_CARGO_MULT: Final[int] = 3
WAKE_LENGTH: Final[int] = 5
PORT_LOG_MAX: Final[int] = 128

LANE_TILES_PER_DAY: Final[int] = 20
NPC_SAIL_CLASS: Final[str] = "sail"
TRADER_HOLD_CAPACITY: Final[int] = 40
COASTER_HOLD_CAPACITY: Final[int] = 10
RISK_SAMPLE_MAX: Final[int] = 8
GLOBAL_CAP_SLACK: Final[int] = 16
PIRATE_CORE_CAP: Final[int] = 25
BUCKET_SIZE: Final[int] = 16
ROUTE_SEP: Final[str] = ">"

SEED_DAY_MULT: Final[int] = 1000003
SEED_X_MULT: Final[int] = 7919
SEED_Y_MULT: Final[int] = 104729

NO_CELL: Final[tuple[int, int]] = (-1, -1)
RETREAT: Final[str] = "retreat"
CANDIDATE_SCAN_LIMIT: Final[int] = 512

#: §4.8 / 90-* §8.1: ``proximity_cooldowns`` stores the FIRST day a new
#: spawn of a hostile kind is legal again after a battle. The Phase-5
#: ecology retires the daily spawn rolls that consumed it (60-* §4.11.11.1
#: "Spawn immunity retired") — the save key survives present-but-empty and
#: the day math below is the pinned §4.8 rule for any caller that records it.
SPAWN_IMMUNITY_DAYS: Final[int] = 3

FLEET_EVENT_MAX: Final[int] = 8
COASTER_DWELL_DAYS: Final[int] = 4

#: §4.8 wreck despawn: ``despawn_day`` is always ``spawn_day + 5``.
WRECK_DESPAWN_DAYS = 5

#: The locked grid (docs/10-* §6.1) — the wrap modulus for every distance.
GRID_WIDTH: Final[int] = 4320
GRID_HEIGHT: Final[int] = 2160


# --- sailing_sim.gd factor/compass tables (lifted verbatim) ------------------
#
# These live in scripts/world/sailing_sim.gd in the oracle; the Python
# sailing module is another M1 wave, so the small pure tables the ecology
# consumes are carried here verbatim (same constants, same closed forms).

MONTH_DAYS: Final[int] = 30
YEAR_MONTHS: Final[int] = 12
COMPASS_DIRS: Final[tuple[str, ...]] = (
    "N", "NE", "E", "SE", "S", "SW", "W", "NW",
)
COMPASS_DELTAS: Final[tuple[tuple[int, int], ...]] = (
    (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1),
)
WIND_FACTORS: Final[dict[str, dict[str, float]]] = {
    "calm": {"sail": 0.8, "oar": 1.0, "hybrid": 1.0},
    "fair": {"sail": 1.0, "oar": 1.0, "hybrid": 1.0},
    "strong": {"sail": 1.25, "oar": 1.0, "hybrid": 1.1},
    "storm": {"sail": 1.5, "oar": 1.0, "hybrid": 1.2},
}
DEFAULT_WEATHER: Final[str] = "calm"
DIRECTION_FACTORS: Final[dict[int, dict[str, float]]] = {
    0: {"sail": 0.50, "hybrid": 0.85, "oar": 1.00},
    45: {"sail": 0.70, "hybrid": 0.95, "oar": 1.00},
    90: {"sail": 1.00, "hybrid": 1.00, "oar": 1.00},
    135: {"sail": 1.15, "hybrid": 1.05, "oar": 1.00},
    180: {"sail": 1.30, "hybrid": 1.10, "oar": 1.00},
}
CURRENT_ALIGN_FACTOR: Final[float] = 0.08
CURRENT_ALIGNED_DEG: Final[float] = 67.5
CURRENT_OPPOSED_DEG: Final[float] = 112.5


def month_for(day: int) -> int:
    """§4.15: ``floor(((day − 1) mod 360) / 30) + 1`` (posmod, day 1 = M1)."""
    return int(math.floor(
        ((day - 1) % (MONTH_DAYS * YEAR_MONTHS)) / float(MONTH_DAYS))) + 1


def wind_factor(weather: str, ship_class: str) -> float:
    """§4.7 weather × propulsion-class multiplier (unknown → 1.0)."""
    return float(WIND_FACTORS.get(weather, {}).get(ship_class, 1.0))


def heading_of_delta(delta: tuple[int, int]) -> str:
    """The 8-dir id of a one-tile delta; "" when it is not an 8-dir step."""
    try:
        index = COMPASS_DELTAS.index(delta)
    except ValueError:
        return ""
    return COMPASS_DIRS[index]


def heading_index(heading: str) -> int:
    """Index 0..7 of a compass id, −1 outside the domain."""
    try:
        return COMPASS_DIRS.index(heading)
    except ValueError:
        return -1


def angle_between_dirs(a: str, b: str) -> int:
    """Angle between two 8-dir ids in degrees (0/45/90/135/180); −1 unknown."""
    ia = heading_index(a)
    ib = heading_index(b)
    if ia < 0 or ib < 0:
        return -1
    diff = abs(ia - ib) % 8
    return min(diff, 8 - diff) * 45


# --- fleet_path.gd — the pursuit A* family (the weighted variant included) ---
#
# The oracle is scripts/world/fleet_path.gd. ``find_path`` is the ONLY
# runtime pathfinding of the unit-cost pursuit (the hunter chase); the
# lane traffic never pathfinds (§4.11.11.5 zero-A* gate). The weighted
# variant is the §4.19 appointed-voyage search — additive, same walk
# domain, f = g + HEURISTIC_WEIGHT × h, min_step_cost = 1/1.625.

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


# --- Composition (scripts/combat/ai_fleet.gd half, §4.11.3/§4.11.11.2) ------

#: §4.11.3 step 2: the locked hull order.
HULL_IDS: Final[tuple[str, ...]] = ("latin", "sloop", "caravel", "brigantine")

#: §4.11.3 step 3 cannon budgets (the §4.11.11.2 role map + treasure 30),
#: each ``+ floor(day / 30)``. Unknown kinds fall back to the pirate budget.
CANNON_BUDGET: Final[dict[str, int]] = {
    "pirate": 20, "navy": 30, "trader": 6, "coaster": 2, "courier": 0,
    "patrol": 30, "privateer": 20, "treasure": 30,
}
CANNON_BUDGET_PER_30_DAYS: Final[int] = 1
CARGO_CAPACITY_DIVISOR: Final[int] = 10
BROADSIDE_SPLIT_DIVISOR: Final[float] = 2.0

#: §4.11.10 single salvage implementation (``battle_rewards.gd``).
SALVAGE_FRACTION: Final[float] = 0.05


def _ship_count(kind: str, rng: GodotRng) -> int:
    """§4.11.3 step 1: 1–3 merchant / 2–4 navy-family; treasure 3–5 + escort."""
    if kind == "treasure":
        return 3 + rng.randi_range(0, 2) + 1
    base = 2 if kind in ("navy", "patrol", "privateer") else 1
    return base + rng.randi_range(0, 2)


def cannon_budget(kind: str, day: int) -> int:
    """§4.11.3 step 3: ``base + floor(max(day,0) / 30)``."""
    base = int(CANNON_BUDGET.get(kind, CANNON_BUDGET["pirate"]))
    return base + int(math.floor(float(max(day, 0)) / 30.0)) \
        * CANNON_BUDGET_PER_30_DAYS


def _base_ship(hull_id: str, store: DataStore | None = None) -> dict[str, Any]:
    """§4.11.3 step 4: ``crew = crew_min``, full durability, no cannons."""
    dst = store if store is not None else data()
    ship_type = dst.get_ship_type(hull_id)
    return {
        "ship_type_id": hull_id,
        "durability": int(ship_type.get("durability", 0)),
        "crew": int(ship_type.get("crew_min", 0)),
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "equipment": {"figurehead": "", "sail": ""},
        "cargo": {},
    }


def _deal_cannons(ships: list[dict[str, Any]], budget: int,
                  store: DataStore | None = None) -> None:
    """§4.11.3 step 3: round-robin one cannon per hull, skipping full slots."""
    dst = store if store is not None else data()
    remaining = max(int(budget), 0)
    while remaining > 0:
        dealt = 0
        for ship in ships:
            if remaining <= 0:
                break
            slots = int(dst.get_ship_type(str(ship.get("ship_type_id", "")))
                        .get("armament_slots", 0))
            if int(ship.get("cannons", 0)) >= slots:
                continue
            ship["cannons"] = int(ship.get("cannons", 0)) + 1
            remaining -= 1
            dealt += 1
        if dealt == 0:
            break


def _write_broadside_split(ships: list[dict[str, Any]]) -> None:
    """§4.4 broadside split: port = floor(cannons/2), starboard the rest."""
    for ship in ships:
        total = max(int(ship.get("cannons", 0)), 0)
        port = int(math.floor(float(total) / BROADSIDE_SPLIT_DIVISOR))
        ship["cannons_port"] = port
        ship["cannons_starboard"] = total - port


def _roll_cargo(ship: dict[str, Any], rng: GodotRng,
                store: DataStore | None = None) -> dict[str, int]:
    """§4.11.3 step 5: ``max(1, floor(capacity / 10))`` of one rolled good."""
    dst = store if store is not None else data()
    capacity = int(dst.get_ship_type(
        str(ship.get("ship_type_id", ""))).get("capacity", 0))
    quantity = max(1, int(math.floor(float(capacity) / CARGO_CAPACITY_DIVISOR)))
    goods = dst.goods_list
    if not goods:
        return {}
    index = rng.randi_range(0, len(goods) - 1)
    entry = goods[index]
    good_id = str(entry.get("id", "")) if isinstance(entry, dict) else ""
    if not good_id:
        return {}
    return {good_id: quantity}


def compose_enemy(kind: str, day: int, rng: GodotRng,
                  store: DataStore | None = None) -> list[dict[str, Any]]:
    """§4.11.3: ship count → hulls → cannons → crew → cargo (draw order)."""
    ships: list[dict[str, Any]] = []
    count = _ship_count(kind, rng)
    for _index in range(count):
        hull_id = HULL_IDS[rng.randi_range(0, len(HULL_IDS) - 1)]
        ships.append(_base_ship(hull_id, store))
    _deal_cannons(ships, cannon_budget(kind, day), store)
    _write_broadside_split(ships)
    for ship in ships:
        ship["cargo"] = _roll_cargo(ship, rng, store)
    return ships


def salvage_for(sunk_ship_type_ids: list[str],
                store: DataStore | None = None) -> int:
    """§4.11.10 the single salvage implementation:
    ``Σ floor(base_price × SALVAGE_FRACTION)`` over the lost hulls."""
    dst = store if store is not None else data()
    total = 0
    for hull_id in sunk_ship_type_ids:
        ship_type = dst.get_ship_type(str(hull_id))
        total += int(math.floor(
            float(ship_type.get("base_price", 0)) * SALVAGE_FRACTION))
    return total


def _treasure_hull(hull_id: str, store: DataStore | None = None) -> dict[str, Any]:
    return _base_ship(hull_id, store)


def compose_treasure_ships(fleet: dict[str, Any], day: int,
                           store: DataStore | None = None) -> list[dict[str, Any]]:
    """§4.11.11.2 detail: ``3 + rng(0..2)`` merchant hulls + 1 patrol escort,
    whole-fleet cannon budget ``30 + floor(day/30)`` (the patrol budget)."""
    dst = store if store is not None else data()
    rng = GodotRng(seed=int(fleet.get("seed", 0)) * 31
                   + godot_string_hash("treasure_compose"))
    ships: list[dict[str, Any]] = []
    count = TREASURE_MERCHANT_HULLS + rng.randi_range(0, 2)
    for _index in range(count):
        ships.append(_treasure_hull(
            HULL_IDS[rng.randi_range(0, 3)], dst))
    ships.append(_treasure_hull(
        HULL_IDS[rng.randi_range(0, len(HULL_IDS) - 1)], dst))
    _deal_cannons(ships, cannon_budget(PATROL, int(day)), dst)
    return ships


def composition_kind(role: str) -> str:
    """§4.11.11.3: ``hunter`` battles keep ``kind = "navy"``; others their role."""
    return "navy" if role == HUNTER else role


def compose_fleet_ships(fleet: dict[str, Any], day: int,
                        store: DataStore | None = None) -> list[dict[str, Any]]:
    """§4.11.11.2: per-fleet seeded composition (save/load exact)."""
    if str(fleet.get("role", "")) == TREASURE:
        return compose_treasure_ships(fleet, day, store)
    dst = store if store is not None else data()
    rng = GodotRng(seed=int(fleet.get("seed", 0)))
    return compose_enemy(
        composition_kind(str(fleet.get("role", PIRATE))), int(day), rng, dst)


# --- Geometry & fleet-shape helpers -----------------------------------------


def chebyshev(a: tuple[int, int], b: tuple[int, int],
              width: int = GRID_WIDTH) -> int:
    """Wrap-aware Chebyshev distance (``20-*`` §4.1: ``min(|dx|, width−|dx|)``)."""
    dx = abs(a[0] - b[0]) % width
    return max(min(dx, width - dx), abs(a[1] - b[1]))


def position_of(fleet: dict[str, Any]) -> tuple[int, int]:
    """The fleet's cell from the ``{"x","y"}`` save shape (tolerates tuples)."""
    pos = fleet.get("cell")
    if isinstance(pos, (tuple, list)) and len(pos) == 2:
        return (int(pos[0]), int(pos[1]))
    if isinstance(pos, dict):
        return (int(pos.get("x", 0)), int(pos.get("y", 0)))
    return NO_CELL


def set_position(fleet: dict[str, Any], cell: tuple[int, int]) -> None:
    """Writes the cell back in the §4.11.11 ``{"x","y"}`` save shape."""
    fleet["cell"] = {"x": int(cell[0]), "y": int(cell[1])}


def cell_field(value: Any) -> tuple[int, int]:
    """Reads a bare saved cell (``anchor_cell`` / ``hunter_intel_cell``)."""
    if isinstance(value, (tuple, list)) and len(value) == 2:
        return (int(value[0]), int(value[1]))
    if isinstance(value, dict):
        return (int(value.get("x", -1)), int(value.get("y", -1)))
    return NO_CELL


def marker_letter(role: str) -> str:
    """The role letter inside the marker square (``80-*`` §4.5.2)."""
    return {
        TRADER: "T", COASTER: "c", COURIER: "k", PATROL: "P",
        PRIVATEER: "p", HUNTER: "N", TREASURE: "X",
    }.get(role, "")


def kind_role(kind: str) -> str:
    """§4.1: the retired marker kind → living role (``navy`` → ``hunter``)."""
    return KIND_TO_ROLE.get(kind, kind)


def note_spawn_immunity(state: "FleetEcologyState", kind: str,
                        battle_day: int) -> int:
    """§4.8 / 90-* §8.1: record the first day a new spawn of ``kind`` is
    legal after a battle (``battle_day + SPAWN_IMMUNITY_DAYS``). Returns it."""
    first_day = int(battle_day) + SPAWN_IMMUNITY_DAYS
    state.proximity_cooldowns[str(kind)] = first_day
    return first_day


def spawn_allowed(state: "FleetEcologyState", kind: str, day: int) -> bool:
    """True while ``day`` is at/after the kind's recorded first legal day."""
    return int(day) >= int(state.proximity_cooldowns.get(str(kind), 0))


# --- State -----------------------------------------------------------------


@dataclass
class FleetEcologyState:
    """The run-scoped ecology state (the ``GameState`` blocks it owns).

    Field names mirror the GDScript autoload members verbatim (``90-*``
    §8.1): ``npc_fleets`` / ``wrecks`` / ``npc_port_log`` (transient,
    ≤ 128) / ``proximity_cooldowns`` (present-but-empty after Phase 5) /
    ``day`` / ``world`` (position, ``clock_fraction``, weather,
    ``wind_dir``, ``last_departed_port``, ``hunter_intel_cell``) /
    ``reputation`` (``player.reputation``) / ``captain_states``.
    """

    npc_fleets: list[dict[str, Any]] = field(default_factory=list)
    wrecks: list[dict[str, Any]] = field(default_factory=list)
    npc_port_log: list[dict[str, Any]] = field(default_factory=list)
    proximity_cooldowns: dict[str, int] = field(default_factory=dict)
    day: int = 1
    world: dict[str, Any] = field(default_factory=dict)
    reputation: dict[str, int] = field(default_factory=dict)
    captain_states: dict[str, dict[str, Any]] = field(default_factory=dict)
    #: ``GameState.retired`` — the sailing module's game-over guard
    #: (``SailingSimLib.is_game_over()`` in the oracle's accrual gate).
    retired: bool = False

    def player_tile(self) -> tuple[int, int]:
        """``GameState.world_tile()`` — ``world.position`` as a cell."""
        return cell_field(self.world.get("position"))

    def clock_now(self) -> float:
        """The absolute world clock ``day + clock_fraction``."""
        return float(self.day) + float(self.world.get("clock_fraction", 0.0))


class RasterWorld:
    """The default ``DataLoader.map`` + ``OceanLayers`` adapter.

    Wraps the :mod:`server.sim.world.raster` singletons: berth lookup
    (``data/maps/harbors.json``), passability (``world.png``), prevailing
    wind, decoded currents (reversal applied) and in-month sea ice.
    """

    def __init__(self, data_root: Any = None) -> None:
        self._world = raster_module.raster(data_root)
        self._ocean = raster_module.ocean_layers(data_root)
        self.width = self._world.width
        self.height = self._world.height

    def is_passable(self, x: int, y: int) -> bool:
        return self._world.is_passable(x, y)

    def port_cell(self, port_id: str) -> tuple[int, int]:
        return self._world.port_cell(port_id)

    def port_id_at(self, x: int, y: int) -> str:
        return self._world.port_id_at(x, y)

    def ice_blocks(self, x: int, y: int, month: int) -> bool:
        return self._ocean.ice_blocks(x, y, month)

    def prevailing_for(self, x: int, y: int, month: int) -> str:
        return self._ocean.prevailing_for(x, y, month)

    def current_at(self, x: int, y: int,
                   month: int = -1) -> dict[str, Any] | None:
        return self._ocean.current_at(x, y, month)


# --- Module-level caches (the GDScript static vars) --------------------------

@dataclass
class _NetCache:
    ready: bool = False
    width: int = GRID_WIDTH
    height: int = GRID_HEIGHT
    lane_paths: dict[str, list[tuple[int, int]]] = field(default_factory=dict)
    lane_variants: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    lane_ids_sorted: list[str] = field(default_factory=list)
    spoke_paths: dict[str, list[tuple[int, int]]] = field(default_factory=dict)
    spoke_lane: dict[str, str] = field(default_factory=dict)
    tile_lanes: dict[int, list[str]] = field(default_factory=dict)
    path_tiles: set[int] = field(default_factory=set)
    node_tiles: list[tuple[int, int]] = field(default_factory=list)
    node_index: dict[int, int] = field(default_factory=dict)
    adjacency: dict[int, list[list[Any]]] = field(default_factory=dict)


_NET: Final[_NetCache] = _NetCache()
_ROUTE_CACHE: dict[str, dict[str, Any]] = {}
_PORTS_CACHE: dict[str, list[str]] = {}
_GOODS_CACHE: dict[str, list[str]] = {}
_SCOPE_GOODS: list[str] = []
_CANON_BY_ROLE: dict[str, list[dict[str, Any]]] = {}
_CANON_TIERS: dict[str, list[int]] = {}
_CANON_WARNED: bool = False
_ANCHOR_CACHE: dict[str, list[tuple[int, int]]] = {}
_PREVAILING_MEMO: dict[tuple[int, int], str] = {}
_CURRENT_MEMO: dict[tuple[int, int], dict[str, Any] | None] = {}
_FACTOR_MEMO_MONTH: int = -1

#: The lazy Phase-8 captains seam: ``server/sim/world/captains.py`` may not
#: be merged yet — see :class:`_CaptainsBridge`.
_CAPTAINS_SPEC = importlib.util.find_spec("server.sim.world.captains")


def reset_caches() -> None:
    """Drops the shared lane-network / route / canon caches (the oracle's
    static ``reset_caches`` — a fixture that swaps the data tables calls it)."""
    global _CANON_WARNED
    _NET.ready = False
    _NET.width = GRID_WIDTH
    _NET.height = GRID_HEIGHT
    _NET.lane_paths = {}
    _NET.lane_variants = {}
    _NET.lane_ids_sorted = []
    _NET.spoke_paths = {}
    _NET.spoke_lane = {}
    _NET.tile_lanes = {}
    _NET.path_tiles = set()
    _NET.node_tiles = []
    _NET.node_index = {}
    _NET.adjacency = {}
    _ROUTE_CACHE.clear()
    _PORTS_CACHE.clear()
    _GOODS_CACHE.clear()
    _SCOPE_GOODS.clear()
    _CANON_BY_ROLE.clear()
    _CANON_TIERS.clear()
    _CANON_WARNED = False
    _ANCHOR_CACHE.clear()
    _PREVAILING_MEMO.clear()
    _CURRENT_MEMO.clear()


# --- Captains seam (`scripts/world/captains.gd`) ----------------------------


class _CaptainsBridge:
    """The Phase-8 captain canon/return-queue seam.

    The GDScript preloads ``scripts/world/captains.gd``. The Python
    ``server/sim/world/captains.py`` module may not be merged when this
    wave lands (the ``importlib.util.find_spec`` guard above records
    that), so the bridge mirrors the oracle's semantics against the
    injected ``captain_states`` dict (``10-*`` §4.15):

    - a read of an UNMET captain returns fresh defaults (no entry created);
    - ``deploy``/``release``/``reset_deployments`` maintain the runtime-only
      ``deployed`` flag (never saved);
    - ``is_spawnable`` = card exists ∧ not deployed ∧ status active;
    - ``defeat`` books ``returning(return_day = day + 60)``; ``day_tick``
      reactivates due captains; ``is_nemesis`` = stance ≤ −3 on a
      pirate/privateer card;
    - ``speed_jitter`` is the stable ±10% hash quantization.

    When the real module lands, only this class changes (the rest of the
    ecology calls through it).
    """

    RETURN_QUEUE_DAYS: Final[int] = 60
    STATUS_ACTIVE: Final[str] = "active"
    STATUS_RETURNING: Final[str] = "returning"
    TIER_MIN: Final[int] = 1
    TIER_MAX: Final[int] = 3
    NEMESIS_STANCE: Final[int] = -3
    NEMESIS_ROLES: Final[tuple[str, ...]] = (PIRATE, PRIVATEER)
    FAMILIARITY_MIN: Final[int] = 0
    FAMILIARITY_MAX: Final[int] = 99
    SPEED_JITTER_MAX: Final[float] = 0.10
    _JITTER_STEPS: Final[int] = 201

    def __init__(self, captain_states: dict[str, dict[str, Any]],
                 store: DataStore) -> None:
        self._states = captain_states
        self._store = store
        self._module: Any = None
        if _CAPTAINS_SPEC is not None:
            import server.sim.world.captains as captains_mod  # noqa: F401
            self._module = captains_mod

    # -- canon reads -------------------------------------------------------

    def canon_list(self) -> list[Any]:
        if self._module is not None and hasattr(self._module, "canon_list"):
            try:
                return list(self._module.canon_list())
            except TypeError:
                pass
        return self._store.captains_list

    def captain(self, captain_id: str) -> dict[str, Any]:
        if self._module is not None and hasattr(self._module, "captain"):
            try:
                return dict(self._module.captain(captain_id))
            except TypeError:
                pass
        return self._store.get_captain(captain_id)

    # -- §4.15 state -------------------------------------------------------

    def _default_state(self, canon: dict[str, Any]) -> dict[str, Any]:
        return {
            "status": self.STATUS_ACTIVE,
            "return_day": 0,
            "tier_now": _clampi(int(canon.get("tier", self.TIER_MIN)),
                                self.TIER_MIN, self.TIER_MAX),
            "stance": 0,
            "familiarity": 0,
            "dossier_seen": False,
            "defeats": 0,
            "wins": 0,
        }

    def state(self, captain_id: str) -> dict[str, Any]:
        entry = self._states.get(captain_id)
        if isinstance(entry, dict):
            return entry
        return self._default_state(self.captain(captain_id))

    def ensure(self, captain_id: str) -> dict[str, Any]:
        entry = self._states.get(captain_id)
        if not isinstance(entry, dict):
            entry = self._default_state(self.captain(captain_id))
            self._states[captain_id] = entry
        return entry

    # -- deployment (runtime-only) ----------------------------------------

    def deploy(self, captain_id: str) -> None:
        self.ensure(captain_id)["deployed"] = True

    def release(self, captain_id: str) -> None:
        entry = self._states.get(captain_id)
        if isinstance(entry, dict):
            entry.pop("deployed", None)

    def reset_deployments(self) -> None:
        for entry in self._states.values():
            if isinstance(entry, dict):
                entry.pop("deployed", None)

    def is_deployed(self, captain_id: str) -> bool:
        return bool(self.state(captain_id).get("deployed", False))

    def is_spawnable(self, captain_id: str, day: int) -> bool:
        if not self.captain(captain_id):
            return False
        if self.is_deployed(captain_id):
            return False
        return str(self.state(captain_id).get("status", self.STATUS_ACTIVE)) \
            == self.STATUS_ACTIVE

    # -- lifecycle (§4.11.15) ---------------------------------------------

    def defeat(self, captain_id: str, day: int,
               crushed: bool = False) -> dict[str, Any]:
        state = self.ensure(captain_id)
        state["status"] = self.STATUS_RETURNING
        state["return_day"] = int(day) + self.RETURN_QUEUE_DAYS
        state["defeats"] = int(state.get("defeats", 0)) + 1
        state["deployed"] = False
        if crushed:
            state["tier_now"] = _clampi(
                int(state.get("tier_now", self.TIER_MIN)) - 1,
                self.TIER_MIN, self.TIER_MAX)
        return state

    def win(self, captain_id: str, _day: int) -> dict[str, Any]:
        state = self.ensure(captain_id)
        state["wins"] = int(state.get("wins", 0)) + 1
        state["tier_now"] = _clampi(
            int(state.get("tier_now", self.TIER_MIN)) + 1,
            self.TIER_MIN, self.TIER_MAX)
        return state

    def day_tick(self, day: int) -> None:
        for entry in self._states.values():
            if not isinstance(entry, dict):
                continue
            if str(entry.get("status", "")) == self.STATUS_RETURNING \
                    and int(day) >= int(entry.get("return_day", 0)):
                entry["status"] = self.STATUS_ACTIVE
                entry["return_day"] = 0

    def is_nemesis(self, captain_id: str) -> bool:
        if int(self.state(captain_id).get("stance", 0)) > self.NEMESIS_STANCE:
            return False
        return str(self.captain(captain_id).get("role", "")) \
            in self.NEMESIS_ROLES

    def add_familiarity(self, captain_id: str, amount: int = 1) -> int:
        state = self.ensure(captain_id)
        state["familiarity"] = _clampi(
            int(state.get("familiarity", 0)) + amount,
            self.FAMILIARITY_MIN, self.FAMILIARITY_MAX)
        return int(state["familiarity"])

    # -- speed jitter ------------------------------------------------------

    def speed_jitter(self, captain_id: str) -> float:
        if self._module is not None and hasattr(self._module, "speed_jitter"):
            try:
                return float(self._module.speed_jitter(captain_id))
            except TypeError:
                pass
        bucket = godot_string_hash(captain_id) % self._JITTER_STEPS  # 0..200
        half = self._JITTER_STEPS // 2  # 100
        return (float(bucket - half) / float(half)) * self.SPEED_JITTER_MAX


# --- Small numeric helpers --------------------------------------------------


def _clampi(value: int, low: int, high: int) -> int:
    return low if value < low else high if value > high else value


def _clampf(value: float, low: float, high: float) -> float:
    return low if value < low else high if value > high else value


def _roundi_half_away(value: float) -> int:
    """Godot ``roundi``: nearest integer, halfway cases away from zero."""
    if value >= 0.0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


def _godot_hash(text: str) -> int:
    return godot_string_hash(text)


# --- The ecology sim -------------------------------------------------------


class NpcFleets:
    """One ecology simulation (the oracle's ``NpcFleets`` RefCounted).

    ``config`` = ``{"npc_config": {...}, "preset": id}`` (an empty config
    reads ``data().npc_config`` + the passed/default preset). The injected
    ``state`` / ``economy`` / ``allegiance`` / ``person`` / ``world`` make
    every read explicit; ``store`` defaults to the ``data()`` singleton.
    """

    def __init__(self, config: dict[str, Any] | None = None, *,
                 state: FleetEcologyState | None = None,
                 economy: EconomyState | None = None,
                 allegiance: AllegianceState | None = None,
                 person: PersonState | None = None,
                 world: Any = None,
                 store: DataStore | None = None,
                 rng: GodotRng | None = None) -> None:
        self._store = store if store is not None else data()
        self._config = copy.deepcopy(config) if config else {}
        self._state = state if state is not None else FleetEcologyState()
        self._economy = economy if economy is not None else EconomyState()
        self._allegiance = allegiance
        self._person = person if person is not None else PersonState()
        self._world = world if world is not None else RasterWorld()
        self._captains = _CaptainsBridge(self._state.captain_states,
                                         self._store)
        self._preset = str(
            self._config.get("preset", "normal"))

        # Instance state (the oracle's instance var block).
        self.last_tick_day = -1
        self.moved_ports: list[str] = []
        self._rng = rng if rng is not None else GodotRng()
        self._rng_seeded = rng is not None
        self._id_seq = 0
        self._unpatrolled_zones = 0
        self._zones_day = -1
        self._skip: dict[str, int] = {}
        self._port_counts_cache: dict[str, int] = {}
        self._neutral_port_count = -1
        self._deficit_day = -1
        self._deficit_list: list[dict[str, Any]] = []
        self._align_cache: dict[str, list[Any]] = {}
        self._hunter_paths: dict[str, dict[str, Any]] = {}
        self._step_carry: dict[str, float] = {}
        self._pass_contacts: list[str] = []
        self._geo_cache: dict[int, dict[str, Any]] = {}
        self._geo_cache_day = -1
        self._lane_path_ids: dict[str, int] = {}
        self._spoke_path_ids: dict[str, int] = {}
        self._passable_cache: dict[tuple[int, int], bool] = {}
        self._passable_day = -1
        self._tick_player_tile = NO_CELL
        self._tick_scoped = False
        self._last_clock = -1.0
        self._pending_delta = 0.0
        self._fleet_mark: dict[str, float] = {}
        self._hold_ticks: dict[str, int] = {}
        self._accrual_dbg: dict[str, dict[str, Any]] = {}
        self._fleet_events: dict[str, list[str]] = {}
        self.moved_fleet_moves: list[dict[str, Any]] = []
        self._accrual_paths: dict[str, list[tuple[int, int]]] = {}
        self._leg_active: dict[str, dict[str, Any]] = {}
        self._wake_trails: dict[str, list[tuple[int, int]]] = {}
        self._buckets: dict[int, list[str]] = {}
        self._by_id: dict[str, dict[str, Any]] = {}
        self._index_dirty = True
        self._anchor_cache: dict[str, list[tuple[int, int]]] = {}
        self._hunter_home = ""

    # -- state accessors ---------------------------------------------------

    @property
    def state(self) -> FleetEcologyState:
        return self._state

    @property
    def store(self) -> DataStore:
        return self._store

    @property
    def economy(self) -> EconomyState:
        return self._economy

    @property
    def world_source(self) -> Any:
        return self._world

    def _sync_day(self, day: int | None = None) -> int:
        """Keeps the injected run clocks on the ecology day (one clock)."""
        today = int(self._state.day if day is None else day)
        self._state.day = today
        self._economy.day = today
        self._person.day = today
        return today

    # --- Preset & budgets (docs/60-* §4.1.1, 10-* §4.10) ------------------

    def _npc_config(self) -> dict[str, Any]:
        cfg = self._config.get("npc_config")
        return cfg if isinstance(cfg, dict) and cfg else self._store.npc_config

    def _budgets(self) -> dict[str, Any]:
        budgets = self._npc_config().get("budgets")
        return budgets if isinstance(budgets, dict) else {}

    def _flow(self) -> dict[str, Any]:
        flow = self._npc_config().get("flow")
        return flow if isinstance(flow, dict) else {}

    def multiplier(self) -> float:
        """The live preset multiplier (``deserted`` = 0.0)."""
        presets = self._npc_config().get("presets")
        value = presets.get(self._preset, 1.0) if isinstance(presets, dict) \
            else 1.0
        return float(value) if isinstance(value, (int, float)) \
            and not isinstance(value, bool) else 1.0

    def is_deserted(self) -> bool:
        return self.multiplier() <= 0.0

    def set_preset(self, preset: str) -> str:
        """Density-dial seam: raise refills via the trickle, lower never
        culls (the trickle only spawns on a deficit); ``deserted`` stops
        every spawn. Returns the applied preset id."""
        presets = self._npc_config().get("presets")
        presets = presets if isinstance(presets, dict) else {}
        self._preset = str(preset) if str(preset) in presets else str(
            self._npc_config().get("default_preset", "normal"))
        self._config["preset"] = self._preset
        return self._preset

    def _port_counts(self) -> dict[str, int]:
        if self._port_counts_cache:
            return self._port_counts_cache
        counts: dict[str, int] = {}
        for port in self._store.ports_list:
            nation_id = str(port.get("nation_id", ""))
            if not nation_id:
                continue
            counts[nation_id] = int(counts.get(nation_id, 0)) + 1
        self._port_counts_cache = counts
        return counts

    # --- Phase-7 allegiance guard (60-* §4.11.14) -------------------------

    def port_alignment(self, port_id: str) -> str:
        """The port's effective alignment (docs/30-* §4.9) through the guard;
        the guard default (no allegiance module) is the data ``nation_id``."""
        if self._allegiance is not None:
            return allegiance_lib.effective_alignment(
                self._store, self._allegiance, port_id)
        return str(self._store.get_port(port_id).get("nation_id", ""))

    def _tariff_mille_for(self, port_id: str, payer_nation: str) -> int:
        if self._allegiance is not None:
            return max(0, int(allegiance_lib.tariff_mille(
                self._store, self._allegiance, self._person, {}, port_id,
                payer_nation)))
        return 500 if self.port_alignment(port_id) == payer_nation else 2000

    def _credit_port_tax(self, port_id: str, fleet: dict[str, Any],
                         units: int, price: int) -> None:
        """Credits the unified tariff of one NPC port-call trade (decisions
        19/20). A nationless payer is exempt; a module-less world is a no-op."""
        payer = str(fleet.get("nation_id", ""))
        if not payer or units <= 0 or price <= 0:
            return
        mille = self._tariff_mille_for(port_id, payer)
        if mille <= 0:
            return
        tax = units * price * mille // 10000
        if tax <= 0:
            return
        if self._allegiance is not None:
            allegiance_lib.credit_tax(self._store, self._allegiance,
                                      self._person, port_id, payer, tax)

    def neutral_port_count(self) -> int:
        """The data ``nation_id == ""`` tier (45 ports)."""
        if self._neutral_port_count >= 0:
            return self._neutral_port_count
        count = 0
        for port in self._store.ports_list:
            if not str(port.get("id", "")):
                continue
            if str(port.get("nation_id", "")) == "":
                count += 1
        self._neutral_port_count = count
        return count

    def nation_ports(self, nation_id: str) -> list[str]:
        """The nation's own ports, ids sorted (cached per run)."""
        cached = _PORTS_CACHE.get(nation_id)
        if cached:
            return list(cached)
        out: list[str] = []
        for port in self._store.ports_list:
            port_id = str(port.get("id", ""))
            if not port_id or str(port.get("nation_id", "")) != nation_id:
                continue
            if self._port_cell(port_id)[0] < 0:
                continue
            out.append(port_id)
        out.sort()
        _PORTS_CACHE[nation_id] = list(out)
        return out

    def nation_goods(self, nation_id: str) -> list[str]:
        """The union of the nation's ports' ``produces``, id-sorted."""
        cached = _GOODS_CACHE.get(nation_id)
        if cached:
            return list(cached)
        seen: dict[str, bool] = {}
        for port in self._store.ports_list:
            if str(port.get("nation_id", "")) != nation_id:
                continue
            for good_id in port.get("produces", []):
                seen[str(good_id)] = True
        out = sorted(seen)
        _GOODS_CACHE[nation_id] = list(out)
        return out

    def alignment_ports(self, nation_id: str) -> list[str]:
        """Ports whose effective alignment == ``nation_id``, ids sorted.
        Day-keyed cache (the ledger only changes between day ticks)."""
        if not nation_id:
            return []
        cached = self._align_cache.get(nation_id)
        if cached:
            if int(cached[0]) == int(self._state.day):
                return [str(x) for x in cached[1:]]
        out: list[str] = []
        for port in self._store.ports_list:
            port_id = str(port.get("id", ""))
            if not port_id or self._port_cell(port_id)[0] < 0:
                continue
            if self.port_alignment(port_id) == nation_id:
                out.append(port_id)
        out.sort()
        self._align_cache[nation_id] = [int(self._state.day)] + out
        return out

    def rivalry_pairs(self) -> list[str]:
        """Undirected rivalry pairs, sorted (``nations.json`` rivals)."""
        seen: dict[str, bool] = {}
        for nation in self._store.nations_list:
            nation_id = str(nation.get("id", ""))
            for rival in nation.get("rivals", []):
                a, b = nation_id, str(rival)
                seen[(a if a < b else b) + "|" + (b if a < b else a)] = True
        return sorted(seen)

    def _pair_of(self, nation_id: str) -> str:
        for pair in self.rivalry_pairs():
            parts = pair.split("|")
            if parts[0] == nation_id or parts[1] == nation_id:
                return pair
        return ""

    def bountied_nations(self) -> list[str]:
        """Nations the player holds a bounty against (rep ≤ −50), sorted."""
        out = [str(nation_id) for nation_id, value in
               self._state.reputation.items()
               if int(value) <= NAVY_HOSTILE_REPUTATION]
        out.sort()
        return out

    def budget_for(self, role: str, nation_id: str) -> int:
        """§4.1.1 per-role budget at the live preset (``ceil`` per role)."""
        mult = self.multiplier()
        if mult <= 0.0:
            return 0
        budgets = self._budgets()
        own = int(self._port_counts().get(nation_id, 0))
        npc_config = self._npc_config()
        if role == TRADER:
            return math.ceil(
                own * float(budgets.get("traders_mult_per_port", 1.25)) * mult)
        if role == COASTER:
            if not nation_id:
                return math.ceil(
                    self.neutral_port_count()
                    * float(npc_config.get("neutral_coasters_mult", 0.75))
                    * mult)
            return math.ceil(
                own * float(budgets.get("coasters_mult_per_port", 0.75)) * mult)
        if role == PATROL:
            div = float(budgets.get("patrols_div_ports", 6))
            raw = math.ceil(own / div * mult) if div > 0.0 else 1
            return max(int(budgets.get("patrols_min", 1)), int(raw))
        if role == COURIER:
            return math.ceil(float(budgets.get("couriers_per_nation", 2)) * mult)
        if role == PRIVATEER:
            return math.ceil(
                float(budgets.get("privateers_per_rivalry", 2)) * mult) \
                if self._pair_of(nation_id) else 0
        if role == PIRATE:
            base = float(budgets.get("pirate_base", 8))
            per_zone = float(budgets.get("pirates_per_unpatrolled_zone", 1))
            self._recount_zones(self._state.day)
            demand = base + float(self._unpatrolled_zones) * per_zone
            return min(PIRATE_CORE_CAP, math.ceil(demand * mult))
        if role == HUNTER:
            return 1 if nation_id in self.bountied_nations() else 0
        if role == TREASURE:
            return 0  # task L's seasonal scheduler owns it
        return 0

    def core_cap(self) -> int:
        """The sum of the persistent role budgets across all owners."""
        total = 0
        for nation_id in self._port_counts():
            for role in (TRADER, COASTER, PATROL, COURIER, PRIVATEER):
                total += self.budget_for(role, nation_id)
        total += self.budget_for(COASTER, "")
        total += self.budget_for(PIRATE, "")
        return total

    def global_cap(self) -> int:
        """The core cap + slack, bounded by ``absolute_cap`` (2048)."""
        absolute = int(self._npc_config().get("absolute_cap", 2048))
        return min(self.core_cap() + GLOBAL_CAP_SLACK, absolute)

    def trickle_per_day(self) -> int:
        """§4.1.2: ``max(4, ceil(cap / 50))`` fleets/day; deserted trickles 0."""
        if self.is_deserted():
            return 0
        base = float(self._flow().get("spawns_per_day_base", 4))
        scaled = math.ceil(float(self.global_cap()) / 50.0)
        return int(max(base, float(scaled)))

    # --- Public API (docs/60-* §4.12.3) ----------------------------------

    def initial_fill(self, day: int) -> None:
        """The new-game fill: half the core cap, seeded, on lanes near ports."""
        self._sync_day(day)
        self.last_tick_day = int(day)
        self._captains.reset_deployments()
        self._wake_trails = {}
        self._step_carry = {}
        self._leg_active = {}
        self._pass_contacts = []
        self._last_clock = -1.0
        self._pending_delta = 0.0
        self._fleet_mark = {}
        self._hold_ticks = {}
        self._accrual_dbg = {}
        self.moved_fleet_moves = []
        self._geo_cache = {}
        self._passable_cache = {}
        if self.is_deserted():
            return
        target = self.core_cap() // 2
        spawned = 0
        for role in FILL_ORDER:
            if spawned >= target:
                return
            if role == PIRATE:
                want = self.budget_for(PIRATE, "") // 2
                for _index in range(want):
                    if spawned >= target:
                        break
                    if self.spawn(PIRATE, "", int(day)):
                        spawned += 1
            elif role == COASTER:
                grey_want = self.budget_for(COASTER, "") // 2
                for _index in range(grey_want):
                    if spawned >= target:
                        break
                    if self.spawn(COASTER, "", int(day)):
                        spawned += 1
                for nation_id in self._port_counts():
                    if spawned >= target:
                        return
                    nation_want = self.budget_for(role, nation_id) // 2
                    for _index in range(nation_want):
                        if spawned >= target:
                            break
                        if self.spawn(role, nation_id, int(day)):
                            spawned += 1
            elif role == HUNTER:
                continue  # bounty-only: the trickle owns transient hunters
            else:
                for nation_id in self._port_counts():
                    if spawned >= target:
                        return
                    want = self.budget_for(role, nation_id) // 2
                    for _index in range(want):
                        if spawned >= target:
                            break
                        if self.spawn(role, nation_id, int(day)):
                            spawned += 1

    def tick(self, day: int) -> list[dict[str, Any]]:
        """One daily ecology tick (§4.3 order: zone recount → stepping +
        dwell + decisions → trickle). Returns the fleets spawned this tick;
        a repeat call within one day returns ``[]``."""
        if int(day) == self.last_tick_day:
            return []
        self._sync_day(day)
        self.last_tick_day = int(day)
        self.moved_ports = []
        self._age_wrecks(int(day))
        self.backfill_captains()
        if self.is_deserted():
            return []
        self._ensure_rng()
        self._tick_scoped = True
        self._tick_player_tile = self._state.player_tile()
        self._step_fleets(int(day))
        self.advance_clock()
        self._recount_zones(int(day))
        self._schedule_treasure(int(day))
        self._captain_return_tick(int(day))
        out = self._trickle(int(day))
        self._tick_scoped = False
        return out

    def accrue(self) -> None:
        """Per-move accrual alias (``90-*`` §5.6 ``FleetSim.accrue()``)."""
        self.advance_clock()

    def advance_clock(self) -> None:
        """Movement accrual (§4.11.11 unified movement): every fleet accrues
        ``Δ × base × wind × direction × current`` tiles and steps one tile per
        accrued tile. Idempotent on the world clock; the sync mark is
        runtime-only (a fresh sim catches nothing up)."""
        now = self._state.clock_now()
        if self._last_clock < 0.0:
            self._last_clock = now
            self._pending_delta = 0.0
            return
        delta = now - self._last_clock
        prev_clock = self._last_clock
        self._last_clock = now
        self._pending_delta = delta
        if delta <= 0.0 or self.is_deserted() or self._state.retired:
            return
        day = int(self._state.day)
        remove_ids: list[str] = []
        wrecks: list[dict[str, Any]] = []
        doomed: dict[str, bool] = {}
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            if int(fleet.get("cooldown_until_day", 0)) >= day:
                self._accrual_dbg[str(fleet.get("id", ""))] = {
                    "delta": 0.0, "skip": "cooldown"}
                continue
            fleet_id = str(fleet.get("id", ""))
            mark = float(self._fleet_mark.get(fleet_id, prev_clock))
            fleet_delta = now - mark
            if fleet_delta <= 0.0:
                self._fleet_mark[fleet_id] = now
                self._accrual_dbg[fleet_id] = {
                    "delta": fleet_delta, "skip": "stale_mark"}
                continue
            self._fleet_mark[fleet_id] = now
            self._accrual_dbg[fleet_id] = {"delta": fleet_delta}
            moved_from = position_of(fleet)
            self._accrual_paths[fleet_id] = []
            role = str(fleet.get("role", ""))
            if role in (PIRATE, PRIVATEER):
                self._accrue_raider(fleet, day, fleet_delta, doomed,
                                    remove_ids, wrecks)
            elif role == HUNTER:
                self._accrue_hunter(fleet, day, fleet_delta)
            else:
                self._accrue_lane(fleet, day, fleet_delta)
            moved_to = position_of(fleet)
            if fleet_id in self._accrual_dbg:
                self._accrual_dbg[fleet_id]["moved"] = moved_to != moved_from
            if moved_to != moved_from:
                self.moved_fleet_moves.append({
                    "id": fleet_id, "from": moved_from,
                    "path": self._accrual_paths.get(fleet_id, []),
                    "to": moved_to})
        for fleet_id in remove_ids:
            self.remove(fleet_id)
        for wreck in wrecks:
            self._state.wrecks.append(wreck)

    def fleets(self) -> list[dict[str, Any]]:
        """Every live fleet dict (the §4.11.11 save payload; shallow copy)."""
        return list(self._state.npc_fleets)

    def take_fleet_moves(self) -> list[dict[str, Any]]:
        """Drains the render-move report since the last take."""
        out = self.moved_fleet_moves
        self.moved_fleet_moves = []
        return out

    # --- Lane accrual (unified movement) ----------------------------------

    def _accrue_lane(self, fleet: dict[str, Any], day: int,
                     delta: float) -> None:
        fleet_id = str(fleet.get("id", ""))
        route = fleet.get("route")
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if not legs or int(fleet.get("dwell_until_day", 0)) > day:
            self._accrual_dbg[fleet_id] = {"delta": delta, "skip": "docked"}
            return
        committed_total = 0
        for _d in range(int(math.floor(delta))):
            committed_total += self._walk_lane(
                fleet, day, self._lane_tiles_today(fleet))
        fraction = delta - math.floor(delta)
        if fraction > 0.0 and self._lane_step_heading(fleet):
            raw = self._lane_pipe(fleet) * fraction \
                + float(self._step_carry.get(fleet_id, 0.0))
            tiles = int(math.floor(raw))
            self._step_carry[fleet_id] = raw - float(tiles)
            committed_total += self._walk_lane(fleet, day, tiles)
        if committed_total > 0:
            self._hold_ticks[fleet_id] = 0
        else:
            self._hold_ticks[fleet_id] = \
                int(self._hold_ticks.get(fleet_id, 0)) + 1
        telemetry = self._accrual_dbg.get(fleet_id, {})
        if not telemetry:
            self._accrual_dbg[fleet_id] = telemetry
        telemetry["delta"] = delta
        telemetry["committed"] = committed_total
        telemetry["budget"] = self._lane_tiles_today(fleet)
        telemetry["pipe"] = self._lane_pipe(fleet)

    def _lane_pipe(self, fleet: dict[str, Any]) -> float:
        """The §4.4 lane pipeline for the current leg heading (tiles/day)."""
        heading = self._lane_step_heading(fleet)
        if not heading:
            return 0.0
        base = self._fleet_base(fleet)
        ship_class = str(base[1])
        month = month_for(self._state.day)
        weather = str(self._state.world.get("weather", DEFAULT_WEATHER))
        cell = position_of(fleet)
        return float(base[0]) \
            * wind_factor(weather, ship_class) \
            * npc_direction_factor(heading, cell, month, ship_class) \
            * npc_current_factor(heading, cell, month)

    def _accrue_raider(self, fleet: dict[str, Any], day: int, delta: float,
                       doomed: dict[str, bool], remove_ids: list[str],
                       wrecks: list[dict[str, Any]]) -> None:
        target = self._find(str(fleet.get("target_fleet_id", "")))
        if target and (doomed.get(str(target.get("id", "")))
                       or chebyshev(position_of(fleet),
                                    position_of(target)) > CHASE_OFF_RADIUS):
            fleet["target_fleet_id"] = ""
            target = {}
        if not target:
            cell = position_of(fleet)
            anchor = cell_field(fleet.get("anchor_cell"))
            if anchor != NO_CELL and (chebyshev(cell, anchor) > ANCHOR_RADIUS
                                      or self._is_path_tile(cell)):
                for _i in range(self._chase_budget(fleet, anchor, delta)):
                    self._step_toward(fleet, anchor)
            return
        prey_cell = position_of(target)
        tiles = self._chase_budget(fleet, prey_cell, delta)
        for _i in range(tiles):
            target = self._find(str(fleet.get("target_fleet_id", "")))
            if not target:
                break
            prey_cell = position_of(target)
            if chebyshev(position_of(fleet), prey_cell) <= CONTACT_DISTANCE:
                self._engage(fleet, target, day, doomed, remove_ids, wrecks)
                break
            self._step_toward(fleet, prey_cell)

    def _accrue_hunter(self, fleet: dict[str, Any], day: int,
                       delta: float) -> None:
        if str(fleet.get("hunter_state", HUNTER_STATE_INTEL)) \
                == HUNTER_STATE_CHASE:
            target = self._state.player_tile()
            if chebyshev(position_of(fleet), target) <= HUNTER_CHASE_OFF:
                self._pursue(fleet, target, 0.0, delta)
                return
        self._accrue_lane(fleet, day, delta)

    # --- Render markers ---------------------------------------------------

    def markers(self) -> list[dict[str, Any]]:
        """Render dicts for the world scene (``80-*`` §4.5.2): the aliveness
        fields this module owns (sailing/wake/convoy/stall/dwell/heading/
        ship type/speed). Read-only over the fleets; no RNG."""
        out: list[dict[str, Any]] = []
        convoy_leaders = self._convoy_leaders()
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            fleet_id = str(fleet.get("id", ""))
            route = fleet.get("route")
            legs = route.get("legs", []) if isinstance(route, dict) else []
            sailing = bool(legs)
            wake = list(self._wake_trails.get(fleet_id, [])) if sailing else []
            leader_id = str(convoy_leaders.get(fleet_id, ""))
            holds = int(self._hold_ticks.get(fleet_id, 0))
            stall = self.stall_state(fleet, holds)
            if stall == "sailing":
                stall = ""
            ships = self._fleet_ships(fleet)
            ship_type = str(ships[0].get("ship_type_id", "")) if ships else ""
            entry = {
                "id": fleet_id,
                "role": str(fleet.get("role", "")),
                "nation_id": str(fleet.get("nation_id", "")),
                "cell": position_of(fleet),
                "letter": marker_letter(str(fleet.get("role", ""))),
                "sailing": sailing,
                "wake": wake,
                "convoy_count": int(convoy_leaders.get(fleet_id + "#count", 0))
                if leader_id == fleet_id else 0,
                "convoy_leader": leader_id,
                "holds": holds,
                "stall": stall,
                "dwell": int(fleet.get("dwell_until_day", 0)),
                "heading": self._lane_step_heading(fleet),
                "ship_type": ship_type,
                "speed": self._lane_pipe(fleet),
                "dest": str(fleet.get("dest_port_id", "")),
                "lanes": (route.get("lanes", []) if isinstance(route, dict)
                          else []),
            }
            if stall == "docked":
                mooring = self._port_at_cell(position_of(fleet))
                entry["port"] = mooring if mooring else str(
                    fleet.get("dest_port_id", ""))
                entry["on_berth"] = bool(mooring)
                if not entry["on_berth"]:
                    entry["stall"] = "stranded"
                    entry["port"] = ""
            out.append(entry)
        return out

    # --- Diagnostics ------------------------------------------------------

    def stall_state(self, fleet: dict[str, Any], holds: int) -> str:
        """The one-word stall state, priority: docked → cooldown → camping →
        chasing/pursuing → blocked → sailing. Read-only."""
        day = int(self._state.day)
        role = str(fleet.get("role", ""))
        route = fleet.get("route")
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if int(fleet.get("dwell_until_day", 0)) > day:
            if self._port_at_cell(position_of(fleet)):
                return "docked"
            return "stranded"
        if int(fleet.get("cooldown_until_day", 0)) >= day:
            return "cooldown"
        if role in (PIRATE, PRIVATEER) \
                and not str(fleet.get("target_fleet_id", "")):
            anchor = cell_field(fleet.get("anchor_cell"))
            cell = position_of(fleet)
            if anchor != NO_CELL and chebyshev(cell, anchor) <= ANCHOR_RADIUS \
                    and not self._is_path_tile(cell):
                return "camping"
        if role in (PIRATE, PRIVATEER) \
                and str(fleet.get("target_fleet_id", "")):
            return "chasing"
        if role == HUNTER \
                and str(fleet.get("hunter_state", "")) == HUNTER_STATE_CHASE:
            return "pursuing"
        if holds >= STALL_HOLD_TICKS and legs:
            return "blocked"
        return "sailing"

    def stall_reason(self, fleet: dict[str, Any]) -> dict[str, Any]:
        """The full stall record for one fleet. Read-only."""
        fleet_id = str(fleet.get("id", ""))
        holds = int(self._hold_ticks.get(fleet_id, 0))
        state = self.stall_state(fleet, holds)
        out: dict[str, Any] = {
            "id": fleet_id,
            "role": str(fleet.get("role", "")),
            "cell": position_of(fleet),
            "state": state,
            "holds": holds,
            "heading": self._lane_step_heading(fleet),
            "speed": self._lane_pipe(fleet),
            "dest": str(fleet.get("dest_port_id", "")),
        }
        if state == "docked":
            out["until"] = int(fleet.get("dwell_until_day", 0))
            mooring = self._port_at_cell(position_of(fleet))
            out["port"] = mooring if mooring \
                else str(fleet.get("dest_port_id", ""))
            out["on_berth"] = bool(mooring)
        elif state == "stranded":
            out["until"] = int(fleet.get("dwell_until_day", 0))
            out["on_berth"] = False
            out["dest"] = str(fleet.get("dest_port_id", ""))
        elif state == "cooldown":
            out["until"] = int(fleet.get("cooldown_until_day", 0))
        elif state == "camping":
            anchor = cell_field(fleet.get("anchor_cell"))
            if anchor != NO_CELL:
                out["radius"] = chebyshev(position_of(fleet), anchor)
        elif state == "sailing":
            out["pipe"] = self._lane_pipe(fleet)
        return out

    def stalled_fleets(self, min_hold: int = STALL_HOLD_TICKS) \
            -> list[dict[str, Any]]:
        """Every fleet in a suspicious state (blocked ≥ min_hold, or camping)."""
        out: list[dict[str, Any]] = []
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            holds = int(self._hold_ticks.get(str(fleet.get("id", "")), 0))
            state = self.stall_state(fleet, holds)
            if state == "blocked" and holds >= min_hold:
                out.append({
                    "id": str(fleet.get("id", "")),
                    "role": str(fleet.get("role", "")),
                    "cell": position_of(fleet),
                    "state": state,
                    "holds": holds,
                })
            elif state == "camping":
                reason = self.stall_reason(fleet)
                reason["holds"] = holds
                out.append(reason)
        return out

    def _convoy_leaders(self) -> dict[str, Any]:
        """Greedy convoy grouping over traders in fleet-id order."""
        leaders: dict[str, Any] = {}
        grouped: dict[str, bool] = {}
        traders = [f for f in self._state.npc_fleets
                   if isinstance(f, dict) and str(f.get("role", "")) == TRADER]
        traders.sort(key=lambda f: str(f.get("id", "")))
        for fleet in traders:
            fleet_id = str(fleet.get("id", ""))
            if fleet_id in grouped:
                continue
            members = self.convoy_members(fleet)
            for member in members:
                grouped[str(member.get("id", ""))] = True
            if len(members) >= 2:
                leaders[fleet_id] = fleet_id
                leaders[fleet_id + "#count"] = len(members)
                for member in members:
                    if member is not fleet:
                        leaders[str(member.get("id", ""))] = fleet_id
            else:
                leaders[fleet_id] = ""
        return leaders

    # --- Contact (never opens battles — 90-* §5.6) ------------------------

    def nearest_contact(self, cell: tuple[int, int]) -> dict[str, Any]:
        """The nearest hostile fleet within Chebyshev 1 (§4.11.11.2)."""
        found = self.contacts(cell)
        passed = list(self._pass_contacts)
        self._pass_contacts.clear()
        for fleet_id in passed:
            fleet = self._find(str(fleet_id))
            if not fleet or not is_hostile_fleet(self._state, fleet):
                continue
            if int(fleet.get("cooldown_until_day", 0)) >= self._state.day:
                continue
            found.append(fleet)
        if not found:
            return {}
        found.sort(key=lambda f: (chebyshev(cell, position_of(f)),
                                  str(f.get("id", ""))))
        return found[0]

    def contacts(self, cell: tuple[int, int]) -> list[dict[str, Any]]:
        """Every hostile fleet within Chebyshev 1, nearest first (ties by id).
        ``deserted`` raises nothing even though living fleets stay."""
        if self.is_deserted():
            return []
        day = self._state.day
        out: list[dict[str, Any]] = []
        for fleet in self.within(cell, CONTACT_DISTANCE):
            if not is_hostile_fleet(self._state, fleet):
                continue
            if int(fleet.get("cooldown_until_day", 0)) >= day:
                continue
            out.append(fleet)
        out.sort(key=lambda f: (chebyshev(cell, position_of(f)),
                                str(f.get("id", ""))))
        return out

    def fleet_at(self, cell: tuple[int, int]) -> dict[str, Any]:
        """Any fleet whose cell matches (the right-click attack target)."""
        found = self.within(cell, 0)
        return found[0] if found else {}

    def contact_encounter(self, cell: tuple[int, int] | None = None) -> dict[str, Any]:
        """The §4.11.11.3 S10 descriptor of the nearest contact (``{}`` if
        none). Builds the descriptor; the caller queues ``pending_encounter``
        and opens the battle (this module never does)."""
        target = cell if cell is not None else self._state.player_tile()
        # The world scene's seam: record the at-sea intel on contact, then
        # read the nearest hostile (the module never opens the battle).
        self.note_contacts(target)
        fleet = self.nearest_contact(target)
        if not fleet:
            return {}
        return self.attack_encounter(fleet)

    def attack_encounter(self, fleet: dict[str, Any]) -> dict[str, Any]:
        """The interaction layer's descriptor (``interactions.gd``
        ``attack_encounter``): the fleet's saved fields + S10 ``kind`` /
        ``encounter_id`` / composed ``ships`` / ``contact`` / ``wind_dir`` /
        ``weather`` / decoded ``current``."""
        encounter = copy.deepcopy(fleet)
        encounter["kind"] = composition_kind(str(fleet.get("role", "")))
        encounter["encounter_id"] = str(fleet.get("id", ""))
        if not fleet.get("ships"):
            encounter["ships"] = compose_fleet_ships(
                fleet, int(self._state.day), self._store)
        contact = self._state.player_tile()
        encounter["contact"] = {"x": contact[0], "y": contact[1]}
        encounter["wind_dir"] = str(self._state.world.get("wind_dir", "E"))
        encounter["weather"] = str(
            self._state.world.get("weather", "calm"))
        decoded = self._world.current_at(
            contact[0], contact[1], month_for(int(self._state.day)))
        encounter["current"] = {"dir": "", "strength": 0} if not decoded \
            else {"dir": str(decoded.get("dir", "")),
                  "strength": _clampi(int(decoded.get("strength", 0)), 0, 3)}
        return encounter

    # --- Fleet removal / spawn --------------------------------------------

    def remove(self, fleet_id: str) -> None:
        """Removes fleet ``id`` (the §4.12.4 aftermath call). Always releases
        the canon captain (a player defeat is booked by the battle caller)."""
        for index in range(len(self._state.npc_fleets) - 1, -1, -1):
            fleet = self._state.npc_fleets[index]
            if isinstance(fleet, dict) \
                    and str(fleet.get("id", "")) == fleet_id:
                captain_id = str(fleet.get("captain_id", ""))
                if captain_id:
                    self._captains.release(captain_id)
                self._state.npc_fleets.pop(index)
                self._wake_trails.pop(fleet_id, None)
                self._step_carry.pop(fleet_id, None)
                self._leg_active.pop(fleet_id, None)
                self._deficit_day = -1
                self.reset_index()
                return

    def set_pursuit_cooldown(self, fleet_id: str, until_day: int) -> None:
        """§4.10 pursuit cooldown (``cooldown_until_day`` = last idle day)."""
        fleet = self._find(fleet_id)
        if not fleet:
            return
        fleet["cooldown_until_day"] = int(until_day)

    def spawn(self, role: str, nation_id: str, day: int) -> dict[str, Any]:
        """Single seeded spawn (the test/quest seam). ``{}`` when deserted,
        at the absolute cap, or no legal placement exists."""
        if self.is_deserted():
            return {}
        if role not in FILL_ORDER and role != TREASURE:
            return {}
        absolute = int(self._npc_config().get("absolute_cap", 2048))
        if len(self._state.npc_fleets) >= absolute:
            return {}
        fleet = self._build_fleet(role, nation_id, int(day))
        if not fleet:
            return {}
        self._state.npc_fleets.append(fleet)
        self._index_add(fleet)
        self._note_event(str(fleet.get("id", "")), "spawn")
        self._fleet_mark[str(fleet.get("id", ""))] = self._state.clock_now()
        return fleet

    def reset_rng(self, seed_value: int) -> None:
        """Reseeds the instance stream (the pinned test seam) and clears the
        day-ticked mark."""
        self._rng.seed = seed_value
        self._rng_seeded = True
        self.last_tick_day = -1

    def _ensure_rng(self) -> None:
        if self._rng_seeded:
            return
        tile = self._state.player_tile()
        self._rng.seed = self._state.day * SEED_DAY_MULT \
            + tile[0] * SEED_X_MULT + tile[1] * SEED_Y_MULT
        self._rng_seeded = True

    # --- Fleet shape & ids ------------------------------------------------

    def next_fleet_id(self, day: int, role: str) -> str:
        """The §4.11.11 ``nf_<day>_<seq>_<role>`` id (unique per run)."""
        fleet_id = "nf_%d_%04d_%s" % (int(day), self._id_seq, role)
        while self._find(fleet_id):
            self._id_seq += 1
            fleet_id = "nf_%d_%04d_%s" % (int(day), self._id_seq, role)
        return fleet_id

    def _build_fleet(self, role: str, nation_id: str, day: int) \
            -> dict[str, Any]:
        self._refresh_net()
        cell = NO_CELL
        fleet: dict[str, Any] = {
            "id": "",
            "role": role,
            "nation_id": nation_id if role != PIRATE else "",
            "cell": {"x": 0, "y": 0},
            "route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
            "cargo": {},
            "captain_id": "",
            "cooldown_until_day": 0,
            "seed": 0,
            "dest_port_id": "",
            "dwell_until_day": 0,
            "anchor_cell": None,
            "target_fleet_id": "",
            "hunter_state": "",
            "loiter_until_day": 0,
            "home_port_id": "",
        }
        if role in (PIRATE, PRIVATEER):
            anchor = self._raider_anchor(role, fleet["nation_id"], day)
            if anchor == NO_CELL:
                return {}
            cell = anchor
            fleet["anchor_cell"] = {"x": cell[0], "y": cell[1]}
        elif role == HUNTER:
            cell = self._hunter_anchor(nation_id, day)
            if cell == NO_CELL:
                return {}
            fleet["home_port_id"] = self._hunter_home
            fleet["hunter_state"] = HUNTER_STATE_INTEL
            intel_port = self._intel_port()
            fleet["dest_port_id"] = intel_port if intel_port \
                else self._hunter_home
            fleet["dwell_until_day"] = int(day) + DWELL_DAYS
        elif role == TREASURE:
            treasure = self._treasure_journey(nation_id, day)
            if not treasure:
                return {}
            fleet["route"] = treasure["route"]
            cell = treasure["cell"]
            fleet["cargo"] = treasure["cargo"]
            fleet["dest_port_id"] = ""
            fleet["dwell_until_day"] = 0
        else:
            journey = self._role_journey(role, nation_id, day)
            if not journey:
                return {}
            return self._finish_lane_fleet(fleet, journey, nation_id, day)
        fleet["id"] = self.next_fleet_id(day, role)
        fleet["seed"] = _fleet_seed(day, cell)
        self._draw_captain(fleet)
        fleet["ships"] = compose_fleet_ships(fleet, int(day), self._store)
        self._fleet_base(fleet)
        set_position(fleet, cell)
        self._sync_route_progress(fleet)
        self._record_wake(fleet, cell)
        if role == TRADER:
            fleet["specialty"] = self._draw_specialty(
                nation_id, int(fleet["seed"]))
        return fleet

    def _finish_lane_fleet(self, fleet: dict[str, Any], journey: dict[str, Any],
                           nation_id: str, day: int) -> dict[str, Any]:
        role = str(fleet["role"])
        fleet["id"] = self.next_fleet_id(day, role)
        fleet["seed"] = _fleet_seed(day, journey["cell"])
        self._draw_captain(fleet)
        fleet["ships"] = compose_fleet_ships(fleet, int(day), self._store)
        self._fleet_base(fleet)
        fleet["route"] = journey["route"]
        fleet["dest_port_id"] = str(journey.get("dest", ""))
        set_position(fleet, journey["cell"])
        self._sync_route_progress(fleet)
        first_legs = fleet.get("route", {}).get("legs", [])
        if first_legs:
            first_geo = self._leg_geometry(first_legs[0])
            if first_geo:
                walked = first_geo["path"]
                seat_index = int(fleet["route"].get("tile_index", 0))
                cursor = (int(first_geo["end"]) - seat_index) \
                    if first_geo["reverse"] \
                    else (int(first_geo["start"]) + seat_index)
                cursor = _clampi(cursor, 0, len(walked) - 1)
                seat = walked[cursor]
                if seat != position_of(fleet):
                    set_position(fleet, seat)
        self._record_wake(fleet, journey["cell"])
        if int(journey.get("dwell_until_day", 0)) > 0:
            fleet["dwell_until_day"] = int(journey["dwell_until_day"])
        if role == TRADER:
            fleet["specialty"] = self._draw_specialty(
                nation_id, int(fleet["seed"]))
        return fleet

    # --- Captains (§4.11.11.4 / §4.11.15) ---------------------------------

    def _draw_captain(self, fleet: dict[str, Any]) -> None:
        if str(fleet.get("captain_id", "")):
            return
        rng = _fleet_rng(fleet, "captain")
        tier = 2 if str(fleet.get("role", "")) == TREASURE else 0
        captain_id = self._draw_canon_captain(fleet, rng, tier)
        if captain_id:
            self._captains.deploy(captain_id)
        fleet["captain_id"] = captain_id

    @staticmethod
    def _captain_card_role(fleet: dict[str, Any]) -> str:
        if str(fleet.get("role", "")) == TREASURE:
            return TRADER
        return str(fleet.get("role", ""))

    def _role_cards(self, card_role: str) -> list[dict[str, Any]]:
        if not _CANON_BY_ROLE:
            self._rebuild_canon_buckets()
        return _CANON_BY_ROLE.get(card_role, [])

    def _role_tiers(self, card_role: str) -> list[int]:
        if not _CANON_TIERS:
            self._rebuild_canon_buckets()
        return _CANON_TIERS.get(card_role, [])

    def _rebuild_canon_buckets(self) -> None:
        by_role: dict[str, list[dict[str, Any]]] = {}
        tiers: dict[str, dict[int, bool]] = {}
        for card in self._captains.canon_list():
            if not isinstance(card, dict):
                continue
            role = str(card.get("role", ""))
            if not role:
                continue
            by_role.setdefault(role, []).append({
                "id": str(card.get("id", "")),
                "tier": int(card.get("tier", 1)),
                "nation_id": str(card.get("nation_id", "")),
            })
            tiers.setdefault(role, {})[int(card.get("tier", 1))] = True
        for role, tier_map in tiers.items():
            _CANON_TIERS[role] = sorted(tier_map)
        _CANON_BY_ROLE.clear()
        _CANON_BY_ROLE.update(by_role)

    def _spawnable_canon(self, card_role: str, tier_set: list[int],
                         nation_id: str, current: str) -> list[str]:
        out: list[str] = []
        for card in self._role_cards(card_role):
            captain_id = str(card.get("id", ""))
            if not captain_id or int(card.get("tier", 1)) not in tier_set:
                continue
            if str(card.get("nation_id", "")) != nation_id:
                continue
            if captain_id != current and not self._captains.is_spawnable(
                    captain_id, int(self._state.day)):
                continue
            out.append(captain_id)
        return out

    def _draw_canon_captain(self, fleet: dict[str, Any], rng: GodotRng,
                            tier_override: int = 0) -> str:
        card_role = self._captain_card_role(fleet)
        nation = str(fleet.get("nation_id", ""))
        current = str(fleet.get("captain_id", ""))
        tiers = self._role_tiers(card_role)
        if not tiers:
            return ""
        tier = tier_override if tier_override > 0 \
            else int(tiers[rng.randi_range(0, len(tiers) - 1)])
        passes: list[tuple[list[int], str]] = [([tier], nation)]
        nearby: list[int] = []
        if tier - 1 in tiers:
            nearby.append(tier - 1)
        if tier + 1 in tiers:
            nearby.append(tier + 1)
        if nearby:
            passes.append((nearby, nation))
        if nation:
            passes.append((list(tiers), ""))
        passes.append((list(tiers), ""))
        relaxed = False
        for pass_index, (tier_set, pass_nation) in enumerate(passes):
            if pass_index >= 2:
                relaxed = True
            candidates = self._spawnable_canon(
                card_role, tier_set, pass_nation, current)
            if not candidates:
                continue
            if relaxed:
                self._warn_canon_relaxation(card_role, tier, nation)
            return candidates[rng.randi_range(0, len(candidates) - 1)]
        self._warn_canon_starvation(card_role)
        return ""

    @staticmethod
    def _warn_canon_relaxation(card_role: str, tier: int,
                               nation_id: str) -> None:
        global _CANON_WARNED
        if _CANON_WARNED:
            return
        _CANON_WARNED = True
        print(f"NpcFleets: canon cell exhausted — {card_role} tier {tier} "
              f"nation '{nation_id}' relaxed to a nearby spawnable card")

    @staticmethod
    def _warn_canon_starvation(card_role: str) -> None:
        global _CANON_WARNED
        if _CANON_WARNED:
            return
        _CANON_WARNED = True
        print("NpcFleets: no spawnable canon card left for role "
              + card_role + " — this fleet sails without a captain")

    def _ensure_captain(self, fleet: dict[str, Any]) -> None:
        captain_id = str(fleet.get("captain_id", ""))
        legacy = fleet.get("captain") if isinstance(
            fleet.get("captain"), dict) else {}
        if not captain_id:
            captain_id = str(legacy.get("named_id", ""))
            if not captain_id or not self._captains.captain(captain_id) \
                    or not self._captains.is_spawnable(
                        captain_id, int(self._state.day)):
                rng = GodotRng(seed=_godot_hash(
                    str(fleet.get("id", "")) + "|captain_backfill"))
                captain_id = self._draw_canon_captain(fleet, rng)
            if captain_id:
                self._captains.deploy(captain_id)
            fleet["captain_id"] = captain_id
        else:
            self._captains.deploy(captain_id)
        if "captain" in fleet:
            fleet.pop("captain")

    def backfill_captains(self) -> int:
        """Backfills/refreshes every living fleet's canon captain."""
        adjusted = 0
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            before = str(fleet.get("captain_id", ""))
            self._ensure_captain(fleet)
            if str(fleet.get("captain_id", "")) != before \
                    or "captain" in fleet:
                adjusted += 1
        return adjusted

    def _draw_specialty(self, nation_id: str, seed_value: int) -> str:
        goods = self.nation_goods(nation_id)
        if not goods:
            return ""
        rng = GodotRng(seed=int(seed_value) * 31 + _godot_hash("specialty"))
        return goods[rng.randi_range(0, len(goods) - 1)]

    # --- Placement helpers ------------------------------------------------

    def _raider_anchor(self, role: str, nation_id: str,
                       day: int) -> tuple[int, int]:
        rng = GodotRng(seed=int(day) * SEED_DAY_MULT
                       + self._id_seq * SEED_X_MULT
                       + _godot_hash(role + "|" + nation_id))
        candidates = self._anchor_tiles(role, nation_id)
        for attempt in range(32):
            if not candidates:
                break
            pick = candidates[rng.randi_range(0, len(candidates) - 1)]
            off_lane = attempt < 16
            cell = self._free_tile_near(pick, rng, ANCHOR_RADIUS, off_lane)
            if cell != NO_CELL:
                return cell
        return NO_CELL

    def _anchor_tiles(self, role: str, nation_id: str) \
            -> list[tuple[int, int]]:
        cache_key = role + "|" + nation_id
        cached = self._anchor_cache.get(cache_key)
        if cached:
            return list(cached)
        lane_filter: dict[str, bool] = {}
        if role == PRIVATEER:
            for rival_id in self._rivals_of(nation_id):
                for lane_id in self.nation_lanes(rival_id):
                    lane_filter[lane_id] = True
            if not lane_filter:
                for lane_id in _NET.lane_ids_sorted:
                    lane_filter[lane_id] = True
        out: list[tuple[int, int]] = []
        for key, lanes in _NET.tile_lanes.items():
            if len(lanes) < 2:
                continue
            if lane_filter:
                if not any(lane_id in lane_filter for lane_id in lanes):
                    continue
            out.append(_key_to_cell(key))
        out.sort(key=lambda c: (c[1], c[0]))
        self._anchor_cache[cache_key] = list(out)
        return out

    def _hunter_anchor(self, nation_id: str, day: int) -> tuple[int, int]:
        ports = self.nation_ports(nation_id)
        if not ports:
            self._hunter_home = ""
            return self._nemesis_hunter_anchor(day)
        rng = GodotRng(seed=int(day) * SEED_DAY_MULT
                       + self._id_seq * SEED_X_MULT
                       + _godot_hash("hunter|" + nation_id))
        port_id = ports[rng.randi_range(0, len(ports) - 1)]
        center = self._port_cell(port_id)
        if center[0] < 0:
            return NO_CELL
        self._hunter_home = port_id
        return center

    def _nemesis_hunter_anchor(self, _day: int) -> tuple[int, int]:
        centers: list[tuple[int, int]] = []
        intel = self._intel_port()
        if intel:
            berth = self._port_cell(intel)
            if berth[0] >= 0:
                centers.append(berth)
        centers.append(self._state.player_tile())
        for center in centers:
            for dy in range(-ANCHOR_RADIUS, ANCHOR_RADIUS + 1):
                for dx in range(-ANCHOR_RADIUS, ANCHOR_RADIUS + 1):
                    y = center[1] + dy
                    if y < 0 or y >= _NET.height:
                        continue
                    cell = ((center[0] + dx) % _NET.width, y)
                    if not self._passable(cell):
                        continue
                    if self._is_occupied(cell, ""):
                        continue
                    return cell
        return NO_CELL

    def _free_tile_near(self, center: tuple[int, int], rng: GodotRng,
                        radius: int, avoid_paths: bool = False) \
            -> tuple[int, int]:
        offsets: list[tuple[int, int]] = []
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                offsets.append((dx, dy))
        for index in range(len(offsets) - 1, 0, -1):
            pick = rng.randi_range(0, index)
            offsets[index], offsets[pick] = offsets[pick], offsets[index]
        for offset in offsets:
            y = center[1] + offset[1]
            if y < 0 or y >= _NET.height:
                continue
            cell = ((center[0] + offset[0]) % _NET.width, y)
            if not self._passable(cell):
                continue
            if avoid_paths and self._is_path_tile(cell):
                continue
            if not self._is_occupied(cell, ""):
                return cell
        return NO_CELL

    def _is_path_tile(self, cell: tuple[int, int]) -> bool:
        return _cell_key(cell) in _NET.path_tiles

    def _role_journey(self, role: str, nation_id: str, day: int) \
            -> dict[str, Any]:
        if role == COASTER and not nation_id:
            return self._grey_coaster_journey(day)
        ports = self.alignment_ports(nation_id) if role == TRADER \
            else self.nation_ports(nation_id)
        if not ports:
            return {}
        rng = GodotRng(seed=int(day) * SEED_DAY_MULT
                       + self._id_seq * SEED_X_MULT
                       + _godot_hash(role + "|" + nation_id))
        origin = ports[rng.randi_range(0, len(ports) - 1)]
        dest = ""
        if role == PATROL:
            origin = self._patrol_home_port(nation_id)
        else:
            for _attempt in range(6):
                origin = ports[rng.randi_range(0, len(ports) - 1)]
                if role == TRADER:
                    dest = self._nearest_aligned_port_excluding(
                        origin, nation_id)
                elif role == COASTER:
                    dest = self._nearest_own_port_excluding(origin, nation_id)
                elif role == COURIER:
                    dest = self._capital_of(nation_id)
                    if dest == origin:
                        dest = self._nearest_own_port_excluding(
                            origin, nation_id)
                if not dest or dest == origin:
                    continue
                route_check = self.route_between(origin, dest)
                if route_check:
                    return {
                        "origin": origin, "dest": dest,
                        "cell": self._port_cell(origin),
                        "dwell_until_day": int(day) + (
                            self._coaster_dwell_days()
                            if role == COASTER else DWELL_DAYS),
                        "route": copy.deepcopy(route_check["legs_save"]),
                    }
            return {}
        if role == PATROL:
            lanes = self.nation_lanes(nation_id)
            if not lanes:
                return {}
            lane_id = lanes[rng.randi_range(0, len(lanes) - 1)]
            harbor = self._port_cell(origin)
            if harbor[0] < 0:
                return {}
            boarded = self._lane_board_route(lane_id, harbor)
            if not boarded:
                return {}
            return {
                "origin": origin, "dest": "",
                "cell": boarded["cell"],
                "dwell_until_day": 0,
                "route": boarded["route"],
            }
        route = self.route_between(origin, dest)
        if not route:
            return {}
        return {
            "origin": origin, "dest": dest, "cell": self._port_cell(origin),
            "dwell_until_day": int(day) + DWELL_DAYS,
            "route": copy.deepcopy(route["legs_save"]),
        }

    def _grey_coaster_journey(self, day: int) -> dict[str, Any]:
        neutrals = self.nation_ports("")
        if not neutrals:
            return {}
        rng = GodotRng(seed=int(day) * SEED_DAY_MULT
                       + self._id_seq * SEED_X_MULT
                       + _godot_hash("coaster|"))
        origin = neutrals[rng.randi_range(0, len(neutrals) - 1)]
        dest = self._nearest_port_excluding(origin)
        if not dest or dest == origin:
            return {}
        route_check = self.route_between(origin, dest)
        if not route_check:
            return {}
        return {
            "origin": origin, "dest": dest, "cell": self._port_cell(origin),
            "dwell_until_day": int(day) + self._coaster_dwell_days(),
            "route": copy.deepcopy(route_check["legs_save"]),
        }

    def _nearest_port_excluding(self, port_id: str) -> str:
        best = ""
        best_distance = 0
        center = self._port_cell(port_id)
        if center[0] < 0:
            return ""
        for port in self._store.ports_list:
            other = str(port.get("id", ""))
            if not other or other == port_id:
                continue
            cell = self._port_cell(other)
            if cell[0] < 0:
                continue
            distance = chebyshev(center, cell)
            if not best or distance < best_distance \
                    or (distance == best_distance and other < best):
                best = other
                best_distance = distance
        return best

    def _nearest_aligned_port_excluding(self, origin: str,
                                        nation_id: str) -> str:
        best = ""
        best_distance = 0
        center = self._port_cell(origin)
        for other in self.alignment_ports(nation_id):
            if other == origin:
                continue
            distance = chebyshev(center, self._port_cell(other))
            if not best or distance < best_distance \
                    or (distance == best_distance and other < best):
                best = other
                best_distance = distance
        return best

    def _patrol_home_port(self, nation_id: str) -> str:
        best = ""
        best_count = -1
        for port_id in self.nation_ports(nation_id):
            center = self._port_cell(port_id)
            if center[0] < 0:
                continue
            count = 0
            for other_id in self.nation_ports(nation_id):
                if chebyshev(center, self._port_cell(other_id)) <= ZONE_RADIUS:
                    count += 1
            if count > best_count or (count == best_count and port_id < best):
                best = port_id
                best_count = count
        return best

    def _nearest_own_port_excluding(self, port_id: str,
                                    nation_id: str) -> str:
        best = ""
        best_distance = 0
        center = self._port_cell(port_id)
        for other_id in self.nation_ports(nation_id):
            if other_id == port_id:
                continue
            distance = chebyshev(center, self._port_cell(other_id))
            if not best or distance < best_distance \
                    or (distance == best_distance and other_id < best):
                best = other_id
                best_distance = distance
        return best

    def _capital_of(self, nation_id: str) -> str:
        return str(self._store.get_nation(nation_id).get(
            "capital_port_id", ""))

    def _nearest_own_berth(self, fleet: dict[str, Any]) -> tuple[int, int]:
        nation_id = str(fleet.get("nation_id", ""))
        cell = position_of(fleet)
        best = NO_CELL
        best_distance = 0
        ids = self._all_port_ids() if not nation_id \
            else self.nation_ports(nation_id)
        for port_id in ids:
            berth = self._port_cell(str(port_id))
            if berth == NO_CELL:
                continue
            distance = chebyshev(cell, berth)
            if best == NO_CELL or distance < best_distance:
                best = berth
                best_distance = distance
        return best

    def _all_port_ids(self) -> list[str]:
        out: list[str] = []
        for port in self._store.ports_list:
            port_id = str(port.get("id", ""))
            if not port_id or self._port_cell(port_id)[0] < 0:
                continue
            out.append(port_id)
        out.sort()
        return out

    def _rivals_of(self, nation_id: str) -> list[str]:
        out = [str(rival) for rival in
               self._store.get_nation(nation_id).get("rivals", [])]
        out.sort()
        return out

    def nation_lanes(self, nation_id: str) -> list[str]:
        """The lanes the nation's ports' spokes attach to, id-sorted."""
        self._refresh_net()
        seen: dict[str, bool] = {}
        for port_id in self.nation_ports(nation_id):
            lane_id = str(_NET.spoke_lane.get(port_id, ""))
            if lane_id:
                seen[lane_id] = True
        return sorted(seen)

    # --- Lane routing (junction-graph Dijkstra) ---------------------------

    def _refresh_net(self) -> None:
        if _NET.ready:
            return
        _NET.ready = True
        grid = self._store.map_legend.get("grid", {}) \
            if isinstance(self._store.map_legend, dict) else {}
        _NET.width = int(grid.get("width", GRID_WIDTH))
        _NET.height = int(grid.get("height", GRID_HEIGHT))
        _NET.lane_paths = {}
        _NET.lane_variants = {}
        _NET.lane_ids_sorted = []
        for lane_id, lane in self._store.route_lanes.items():
            path = [(int(tile[0]), int(tile[1]))
                    for tile in lane.get("tile_path", [])]
            _NET.lane_paths[str(lane_id)] = path
            _NET.lane_ids_sorted.append(str(lane_id))
            variants: list[dict[str, Any]] = []
            for variant in lane.get("variants", []):
                if not isinstance(variant, dict):
                    continue
                vpath = [(int(tile[0]), int(tile[1]))
                         for tile in variant.get("tile_path", [])]
                variants.append({
                    "id": str(variant.get("id", "")),
                    "months": list(variant.get("months", [])),
                    "path": vpath,
                })
            _NET.lane_variants[str(lane_id)] = variants
        _NET.lane_ids_sorted.sort()
        _NET.spoke_paths = {}
        _NET.spoke_lane = {}
        for port_id, spoke in self._store.route_spokes.items():
            path = [(int(tile[0]), int(tile[1]))
                    for tile in spoke.get("tile_path", [])]
            _NET.spoke_paths[str(port_id)] = path
            _NET.spoke_lane[str(port_id)] = self._spoke_lane_id(spoke)
        _NET.tile_lanes = {}
        _NET.path_tiles = set()
        for lane_id in _NET.lane_ids_sorted:
            for tile in _NET.lane_paths[lane_id]:
                key = _cell_key(tile)
                _NET.tile_lanes.setdefault(key, [])
                if lane_id not in _NET.tile_lanes[key]:
                    _NET.tile_lanes[key].append(lane_id)
                _NET.path_tiles.add(key)
        for path in _NET.spoke_paths.values():
            for tile in path:
                _NET.path_tiles.add(_cell_key(tile))
        self._build_graph()

    def _spoke_lane_id(self, spoke: dict[str, Any]) -> str:
        lane_id = str(spoke.get("lane", ""))
        if lane_id:
            return lane_id
        connect = spoke.get("connect") if isinstance(
            spoke.get("connect"), dict) else {}
        lane_id = str(connect.get("lane", ""))
        if lane_id:
            return lane_id
        path = _NET.spoke_paths.get(str(spoke.get("port", "")), [])
        if path:
            lanes = _NET.tile_lanes.get(_cell_key(path[-1]), [])
            if lanes:
                return str(sorted(lanes)[0])
        return ""

    def _build_graph(self) -> None:
        junctions = self._store.route_junction_graph()
        _NET.node_tiles = [(int(node[0]), int(node[1]))
                           for node in junctions.get("nodes", [])]
        _NET.node_index = {}
        for index, tile in enumerate(_NET.node_tiles):
            _NET.node_index[_cell_key(tile)] = index
        edge_min: dict[str, list[Any]] = {}
        path_keys = ["lane:" + lane_id for lane_id in _NET.lane_ids_sorted]
        spoke_ids = sorted(_NET.spoke_paths)
        path_keys.extend("spoke:" + str(port_id) for port_id in spoke_ids)
        for path_key in path_keys:
            path = self._path_of(path_key)
            marked: list[tuple[int, int]] = []
            for index, tile in enumerate(path):
                node = _NET.node_index.get(_cell_key(tile))
                if node is not None:
                    marked.append((index, int(node)))
            for k in range(len(marked) - 1):
                i, a = marked[k]
                j, b = marked[k + 1]
                if a == b or i == j:
                    continue
                pair_key = "%d|%d" % (min(a, b), max(a, b))
                length = abs(j - i)
                rank = 0 if path_key.startswith("lane:") else 1
                previous = edge_min.get(pair_key)
                better = previous is None
                if isinstance(previous, list):
                    better = length < int(previous[0]) \
                        or (length == int(previous[0])
                            and rank < int(previous[1]))
                if better:
                    edge_min[pair_key] = [length, rank, path_key, i, j]
        _NET.adjacency = {}
        for entry in edge_min.values():
            path_key = str(entry[2])
            i = int(entry[3])
            j = int(entry[4])
            length = abs(j - i)
            path = self._path_of(path_key)
            node_i = _NET.node_index.get(_cell_key(path[i]), -1)
            node_j = _NET.node_index.get(_cell_key(path[j]), -1)
            if int(node_i) < 0 or int(node_j) < 0 or int(node_i) == int(node_j):
                continue
            _NET.adjacency.setdefault(int(node_i), []).append(
                [int(node_j), length, path_key, i, j])
            _NET.adjacency.setdefault(int(node_j), []).append(
                [int(node_i), length, path_key, j, i])

    def _path_of(self, path_key: str) -> list[tuple[int, int]]:
        if path_key.startswith("lane:"):
            return _NET.lane_paths.get(path_key[len("lane:"):], [])
        return _NET.spoke_paths.get(path_key[len("spoke:"):], [])

    def route_between(self, origin: str, dest: str) -> dict[str, Any]:
        """The tile route between two ports (cached): junction-graph
        Dijkstra expanded into legs. ``{}`` when no route exists."""
        if not origin or not dest or origin == dest:
            return {}
        self._refresh_net()
        cache_key = origin + ROUTE_SEP + dest
        cached = _ROUTE_CACHE.get(cache_key)
        if isinstance(cached, dict):
            return cached
        start_tile = self._port_cell(origin)
        end_tile = self._port_cell(dest)
        if start_tile[0] < 0 or end_tile[0] < 0:
            _ROUTE_CACHE[cache_key] = {}
            return {}
        start = _NET.node_index.get(_cell_key(start_tile))
        end = _NET.node_index.get(_cell_key(end_tile))
        if start is None or end is None:
            _ROUTE_CACHE[cache_key] = {}
            return {}
        node_path = self._dijkstra(int(start), int(end))
        if not node_path:
            _ROUTE_CACHE[cache_key] = {}
            return {}
        route = self._legs_from_nodes(node_path)
        _ROUTE_CACHE[cache_key] = route
        return route

    def _dijkstra(self, start: int, end: int) -> list[int]:
        dist: dict[int, int] = {start: 0}
        prev: dict[int, tuple[int, list[Any]]] = {}
        visited: set[int] = set()
        heap: list[tuple[int, int, str, int]] = [(0, 0, "", start)]
        while heap:
            _cost, _rank, _key, current = heapq.heappop(heap)
            if current in visited:
                continue
            visited.add(current)
            if current == end:
                break
            for edge in _NET.adjacency.get(current, []):
                nxt = int(edge[0])
                if nxt in visited:
                    continue
                cost = int(dist[current]) + int(edge[1])
                known = dist.get(nxt)
                if known is not None and int(known) <= cost:
                    continue
                dist[nxt] = cost
                prev[nxt] = (current, edge)
                heapq.heappush(heap, (cost,
                                      0 if str(edge[2]).startswith("lane:")
                                      else 1, str(edge[2]), nxt))
        if end not in visited:
            return []
        path: list[int] = []
        walk = end
        while walk != start:
            if walk not in prev:
                return []
            path.insert(0, walk)
            walk = prev[walk][0]
        path.insert(0, start)
        return path

    def _legs_from_nodes(self, node_path: list[int]) -> dict[str, Any]:
        legs: list[dict[str, Any]] = []
        for index in range(len(node_path) - 1):
            a = int(node_path[index])
            b = int(node_path[index + 1])
            chosen = [edge for edge in _NET.adjacency.get(a, [])
                      if int(edge[0]) == b]
            if not chosen:
                return {}
            chosen.sort(key=lambda edge: (
                0 if str(edge[2]).startswith("lane:") else 1,
                str(edge[2]), int(edge[1])))
            edge = chosen[0]
            path_key = str(edge[2])
            i = int(edge[3])
            j = int(edge[4])
            kind = "lane" if path_key.startswith("lane:") else "spoke"
            leg_id = path_key[len("lane:"):] if kind == "lane" \
                else path_key[len("spoke:"):]
            forward = j > i
            lo = min(i, j)
            hi = max(i, j)
            walked_start = lo if forward else hi
            last = legs[-1] if legs else {}
            last_walked_end = -1
            if last:
                last_walked_end = int(last["a"]) if last["reverse"] \
                    else int(last["b"])
            if last and str(last["id"]) == leg_id \
                    and bool(last["reverse"]) == (not forward) \
                    and last_walked_end == walked_start:
                if forward:
                    last["b"] = hi
                else:
                    last["a"] = lo
                continue
            legs.append({"kind": kind, "id": leg_id,
                         "reverse": not forward, "a": lo, "b": hi})
        legs_save: list[dict[str, Any]] = []
        full_path: list[tuple[int, int]] = []
        length = 0
        for leg in legs:
            path = self._path_of(
                ("lane:" if leg["kind"] == "lane" else "spoke:")
                + str(leg["id"]))
            walked = _walked_path(path, int(leg["a"]), int(leg["b"]),
                                  bool(leg["reverse"]))
            if not full_path:
                full_path.extend(walked)
            else:
                for tile in walked:
                    if tile != full_path[-1]:
                        full_path.append(tile)
            if len(walked) > 1:
                length += len(walked) - 1
            legs_save.append({"kind": leg["kind"], "id": leg["id"],
                              "reverse": leg["reverse"], "a": leg["a"],
                              "b": leg["b"]})
        lanes: list[str] = []
        for leg in legs_save:
            if leg["kind"] == "lane" and leg["id"] not in lanes:
                lanes.append(leg["id"])
        return {"legs_save": {"lanes": lanes, "leg": 0, "tile_index": 0,
                              "legs": legs_save},
                "length": length, "path": full_path}

    def _leg_path(self, leg: dict[str, Any]) -> list[tuple[int, int]]:
        """The base walked tiles of a saved leg (route construction)."""
        path = self._path_of(
            ("lane:" if str(leg.get("kind", "")) == "lane" else "spoke:")
            + str(leg.get("id", "")))
        if not path:
            return []
        a = _clampi(int(leg.get("a", 0)), 0, len(path) - 1)
        b = _clampi(int(leg.get("b", len(path) - 1)), 0, len(path) - 1)
        return _walked_path(path, a, b, bool(leg.get("reverse", False)))

    def _leg_geometry(self, leg: dict[str, Any]) -> dict[str, Any]:
        """The ACTIVE walked geometry of a saved leg (task-H §2.8).

        ``{path, start, end, reverse, walked_len, key, saved_walked_len}`` —
        the tile path the fleet walks NOW (base or in-month variant). Every
        lane leg anchors on ENDPOINT IDENTITY (bug report 2026-11-02): both
        walked end tiles must exist on the variant path, and the leg walks
        the variant between them; otherwise it keeps the base geometry.
        """
        kind = str(leg.get("kind", ""))
        leg_id = str(leg.get("id", ""))
        table = _NET.lane_paths if kind == "lane" else _NET.spoke_paths
        base = table.get(leg_id, [])
        if not base:
            return {}
        if self._geo_cache_day != int(self._state.day):
            self._geo_cache = {}
            self._geo_cache_day = int(self._state.day)
        a = _clampi(int(leg.get("a", 0)), 0, len(base) - 1)
        b = _clampi(int(leg.get("b", len(base) - 1)), 0, len(base) - 1)
        ids = self._lane_path_ids if kind == "lane" else self._spoke_path_ids
        pid = int(ids.get(leg_id, 0))
        if pid == 0:
            pid = len(ids) + 1
            ids[leg_id] = pid
        cache_key = pid * 1125899906842624 \
            + (562949953421312 if kind == "lane" else 0) \
            + a * 33554432 + b * 2 \
            + (1 if bool(leg.get("reverse", False)) else 0)
        cached = self._geo_cache.get(cache_key)
        if cached is not None:
            return cached
        out: dict[str, Any] = {
            "path": base,
            "start": a,
            "end": b,
            "reverse": bool(leg.get("reverse", False)),
            "walked_len": b - a + 1,
            "key": "%s:%s|" % (kind, leg_id),
            "saved_walked_len": b - a + 1,
        }
        if kind != "lane":
            out["key"] = "%s:%s" % (kind, leg_id)
            self._geo_cache[cache_key] = out
            return out
        month = month_for(self._state.day)
        variant = self._active_lane_variant(leg_id, month)
        if not variant:
            self._geo_cache[cache_key] = out
            return out
        vpath = variant["path"]
        if len(vpath) < 2 or len(base) < 2:
            self._geo_cache[cache_key] = out
            return out
        try:
            va = vpath.index(base[a])
            vb = vpath.index(base[b])
        except ValueError:
            self._geo_cache[cache_key] = out
            return out
        if va == vb:
            self._geo_cache[cache_key] = out
            return out
        stored_reverse = bool(leg.get("reverse", False))
        ascending = va < vb
        out["path"] = vpath
        out["start"] = min(va, vb)
        out["end"] = max(va, vb)
        out["walked_len"] = max(va, vb) - min(va, vb) + 1
        out["reverse"] = stored_reverse == ascending
        out["key"] = "%s:%s|%s" % (kind, leg_id, str(variant["id"]))
        self._geo_cache[cache_key] = out
        return out

    def _active_lane_variant(self, lane_id: str, month: int) -> dict[str, Any]:
        """The in-month built variant of ``lane_id`` (``{}`` = base path)."""
        for variant in _NET.lane_variants.get(lane_id, []):
            if month in variant.get("months", []):
                return variant
        return {}

    def _leg_path_active(self, leg: dict[str, Any]) -> list[tuple[int, int]]:
        """The walked tiles of a leg's ACTIVE geometry (this month)."""
        geo = self._leg_geometry(leg)
        if not geo:
            return []
        return _walked_path(geo["path"], int(geo["start"]), int(geo["end"]),
                            bool(geo["reverse"]))

    def _leg_progress(self, fleet: dict[str, Any], route: dict[str, Any],
                      geo: dict[str, Any]) -> int:
        """Progress bookkeeping for the active geometry (task-H pin 4): a new
        geometry identity remaps the saved ``tile_index`` by fraction and
        re-seats the fleet on the remapped tile (the §2.8 rollover pin)."""
        fleet_id = str(fleet.get("id", ""))
        walked_len = int(geo["walked_len"])
        index = int(route.get("tile_index", 0))
        state = self._leg_active.get(fleet_id, {}) \
            if fleet_id in self._leg_active else {}
        if str(state.get("key", "")) != str(geo["key"]):
            fraction = -1.0
            prev_len = int(state.get("walked_len", 0))
            if prev_len > 1 and index > 1:
                fraction = _clampf(float(index) / float(prev_len - 1),
                                   0.0, 1.0)
            elif prev_len == 0 and index > 1:
                saved_len = int(geo["saved_walked_len"])
                if saved_len > 1:
                    fraction = _clampf(float(index) / float(saved_len - 1),
                                       0.0, 1.0)
            if fraction >= 0.0:
                index = _clampi(_roundi_half_away(
                    fraction * float(walked_len - 1)), 0, walked_len - 1)
                route["tile_index"] = index
                seat_path = geo["path"]
                seat_cursor = (int(geo["end"]) - index) \
                    if geo["reverse"] else (int(geo["start"]) + index)
                seat_cursor = _clampi(seat_cursor, 0, len(seat_path) - 1)
                seat = seat_path[seat_cursor]
                if seat != position_of(fleet):
                    set_position(fleet, seat)
            self._leg_active[fleet_id] = {
                "key": str(geo["key"]), "walked_len": walked_len}
        if index < 0 or index >= walked_len:
            index = 0
            route["tile_index"] = 0
        return index

    # --- Raiders (chokepoint camping & auto-resolve) ----------------------

    def _raider_tick(self, fleet: dict[str, Any], _day: int,
                     doomed: dict[str, bool], _remove_ids: list[str],
                     _wrecks: list[dict[str, Any]]) -> None:
        cell = position_of(fleet)
        target = self._find(str(fleet.get("target_fleet_id", "")))
        if target and (doomed.get(str(target.get("id", "")))
                       or chebyshev(cell, position_of(target))
                       > CHASE_OFF_RADIUS):
            target = {}
            fleet["target_fleet_id"] = ""
        if not target:
            prey = self._nearest_prey_within(fleet, CHASE_ON_RADIUS, doomed)
            if prey:
                fleet["target_fleet_id"] = str(prey.get("id", ""))

    def _nearest_prey_within(self, fleet: dict[str, Any], radius: int,
                             doomed: dict[str, bool]) -> dict[str, Any]:
        best: dict[str, Any] = {}
        best_distance = -1
        for candidate in self.prey_candidates(fleet):
            if doomed.get(str(candidate.get("id", ""))):
                continue
            distance = chebyshev(position_of(fleet), position_of(candidate))
            if distance > radius:
                continue
            candidate_id = str(candidate.get("id", ""))
            if not best or distance < best_distance \
                    or (distance == best_distance
                        and candidate_id < str(best.get("id", ""))):
                best = candidate
                best_distance = distance
        return best

    def _step_toward(self, fleet: dict[str, Any], target: tuple[int, int]) \
            -> None:
        cell = position_of(fleet)
        dx = (target[0] - cell[0]) % _NET.width
        if dx > _NET.width / 2:
            dx -= _NET.width
        dy = target[1] - cell[1]
        sx = 1 if dx > 0 else -1
        sy = 1 if dy > 0 else -1
        offsets: list[tuple[int, int]] = []
        if abs(dx) >= abs(dy):
            if dx != 0:
                offsets.append((sx, 0))
            if dy != 0:
                offsets.append((0, sy))
        else:
            if dy != 0:
                offsets.append((0, sy))
            if dx != 0:
                offsets.append((sx, 0))
        if dx != 0 and dy != 0:
            offsets.append((sx, sy))
        for offset in offsets:
            y = cell[1] + offset[1]
            if y < 0 or y >= _NET.height:
                continue
            nxt = ((cell[0] + offset[0]) % _NET.width, y)
            if self._can_enter(fleet, nxt):
                self._commit_cell(fleet, nxt)
                return

    def resolve_engagement(self, raider: dict[str, Any],
                           prey: dict[str, Any], day: int) -> bool:
        """§4.11.11.2 auto-resolve (rows + the seeded 60%)."""
        if str(prey.get("role", "")) == PATROL:
            return False
        if self.is_escorted(prey):
            return False
        if self.is_convoyed(prey):
            return False
        rng = _fleet_rng(raider, "resolve|%d|%s" % (int(day),
                                                   str(prey.get("id", ""))))
        return rng.randf() < RAIDER_WIN_CHANCE

    def _engage(self, raider: dict[str, Any], prey: dict[str, Any], day: int,
                doomed: dict[str, bool], remove_ids: list[str],
                wrecks: list[dict[str, Any]]) -> None:
        raider_wins = self.resolve_engagement(raider, prey, day)
        loser = prey if raider_wins else raider
        loser_id = str(loser.get("id", ""))
        doomed[loser_id] = True
        remove_ids.append(loser_id)
        wrecks.append(self._make_wreck(loser, day))
        if raider_wins:
            raider["target_fleet_id"] = ""

    def _make_wreck(self, fleet: dict[str, Any], day: int) -> dict[str, Any]:
        cell = position_of(fleet)
        wreck: dict[str, Any] = {
            "id": self._wreck_id(int(day), cell),
            "cell": {"x": cell[0], "y": cell[1]},
            "cargo": {},
            "salvage_gold": 0,
            "spawn_day": int(day),
        }
        if str(fleet.get("role", "")) in WARSHIP_WRECK_ROLES:
            hull_ids = [str(ship.get("ship_type_id", ""))
                        for ship in self._fleet_ships(fleet)]
            wreck["salvage_gold"] = salvage_for(hull_ids, self._store)
        else:
            cargo = fleet.get("cargo") \
                if isinstance(fleet.get("cargo"), dict) else {}
            wreck["cargo"] = copy.deepcopy(cargo)
        return wreck

    def _wreck_id(self, day: int, cell: tuple[int, int]) -> str:
        wreck_id = "wk_%d_%04d_%04d" % (day, cell[0] % _NET.width, cell[1])
        seq = 2
        taken = {str(wreck.get("id", "")) for wreck in self._state.wrecks
                 if isinstance(wreck, dict)}
        while wreck_id in taken:
            wreck_id = "wk_%d_%04d_%04d_%d" % (
                day, cell[0] % _NET.width, cell[1], seq)
            seq += 1
        return wreck_id

    def _age_wrecks(self, day: int) -> None:
        if not self._state.wrecks:
            return
        for index in range(len(self._state.wrecks) - 1, -1, -1):
            wreck = self._state.wrecks[index]
            if isinstance(wreck, dict) \
                    and int(wreck.get("spawn_day", 0)) \
                    + WRECK_DESPAWN_DAYS <= int(day):
                self._state.wrecks.pop(index)

    def wrecks(self) -> list[dict[str, Any]]:
        return list(self._state.wrecks)

    def wreck_at(self, cell: tuple[int, int]) -> dict[str, Any]:
        for wreck in self._state.wrecks:
            if isinstance(wreck, dict) and position_of(wreck) == cell:
                return wreck
        return {}

    def collect_wreck(self, wreck_id: str, free_capacity: int) \
            -> dict[str, Any]:
        """Player collect: cargo up to ``free_capacity`` (id-ascending) plus
        salvage gold; the wreck is consumed; leftovers reported."""
        for index in range(len(self._state.wrecks)):
            wreck = self._state.wrecks[index]
            if not isinstance(wreck, dict) \
                    or str(wreck.get("id", "")) != wreck_id:
                continue
            cargo = wreck.get("cargo") if isinstance(
                wreck.get("cargo"), dict) else {}
            room = max(int(free_capacity), 0)
            taken: dict[str, int] = {}
            leftover = 0
            for good_id in sorted(cargo):
                held = max(int(cargo[good_id]), 0)
                qty = min(held, room)
                if qty > 0:
                    taken[str(good_id)] = qty
                    room -= qty
                leftover += held - qty
            result = {
                "id": wreck_id,
                "cargo": taken,
                "gold": max(int(wreck.get("salvage_gold", 0)), 0),
                "leftover": leftover,
            }
            self._state.wrecks.pop(index)
            return result
        return {}

    # --- Convoys ----------------------------------------------------------

    def convoy_members(self, fleet: dict[str, Any]) -> list[dict[str, Any]]:
        """§4.11.11.4: same-lane traders within Chebyshev 3 (incl. itself)."""
        out: list[dict[str, Any]] = []
        if str(fleet.get("role", "")) != TRADER:
            return out
        for other in self.within(position_of(fleet), CONVOY_RADIUS):
            if str(other.get("role", "")) != TRADER:
                continue
            if not _share_lane(fleet, other):
                continue
            out.append(other)
        return out

    def is_convoyed(self, fleet: dict[str, Any]) -> bool:
        return len(self.convoy_members(fleet)) >= 2

    # --- Phase-6 parity factors -------------------------------------------

    def _lane_tiles_today(self, fleet: dict[str, Any]) -> int:
        fleet_id = str(fleet.get("id", ""))
        carry = float(self._step_carry.get(fleet_id, 0.0))
        heading = self._lane_step_heading(fleet)
        if not heading:
            route = fleet.get("route", {})
            if isinstance(route, dict) and route.get("legs"):
                wedged = route.get("legs", [])
                self._note_event(fleet_id, "drop wedge:%s ti=%d" % (
                    str(wedged[0].get("id", "?")),
                    int(route.get("tile_index", -1))))
                route["legs"] = []
            self._step_carry[fleet_id] = carry
            return 0
        raw = self._lane_pipe(fleet) + carry
        tiles = int(math.floor(raw))
        self._step_carry[fleet_id] = raw - float(tiles)
        return tiles

    def _fleet_ships(self, fleet: dict[str, Any]) -> list[dict[str, Any]]:
        ships = fleet.get("ships") if isinstance(
            fleet.get("ships"), list) else []
        if not ships:
            ships = compose_fleet_ships(fleet, int(self._state.day), self._store)
            fleet["ships"] = ships
        return ships

    def _fleet_base(self, fleet: dict[str, Any]) -> list[Any]:
        """``[base_speed, flagship_class]`` — the slowest composed hull speed
        (floored at 1) times the captain's stable ±10% jitter, cached."""
        if "speed" in fleet and "speed_class" in fleet:
            return [float(fleet["speed"]), str(fleet["speed_class"])]
        ships = self._fleet_ships(fleet)
        slowest = 0
        flagship_class = NPC_SAIL_CLASS
        if ships:
            flagship = self._store.get_ship_type(
                str(ships[0].get("ship_type_id", "")))
            cls = str(flagship.get("class", ""))
            if cls:
                flagship_class = cls
        for ship in ships:
            ship_type = self._store.get_ship_type(
                str(ship.get("ship_type_id", "")))
            speed = int(ship_type.get("speed", 0))
            if speed > 0 and (slowest == 0 or speed < slowest):
                slowest = speed
        base = float(max(slowest, 1))
        captain_id = str(fleet.get("captain_id", ""))
        if captain_id:
            base *= 1.0 + _clampf(
                self._captains.speed_jitter(captain_id),
                -self._captains.SPEED_JITTER_MAX,
                self._captains.SPEED_JITTER_MAX)
        fleet["speed"] = base
        fleet["speed_class"] = flagship_class
        return [base, flagship_class]

    def _step_allowance(self, fleet: dict[str, Any],
                        target: tuple[int, int]) -> float:
        cell = position_of(fleet)
        heading = _heading_to(cell, target)
        if not heading:
            return 0.0
        base = self._fleet_base(fleet)
        ship_class = str(base[1])
        month = month_for(self._state.day)
        weather = str(self._state.world.get("weather", DEFAULT_WEATHER))
        return float(base[0]) \
            * wind_factor(weather, ship_class) \
            * npc_direction_factor(heading, cell, month, ship_class) \
            * npc_current_factor(heading, cell, month)

    def _lane_step_heading(self, fleet: dict[str, Any]) -> str:
        route = fleet.get("route", {})
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if not legs:
            return ""
        geo = self._leg_geometry(legs[0])
        if not geo:
            return ""
        cell = position_of(fleet)
        index = int(route.get("tile_index", 0))
        walked_len = int(geo["walked_len"])
        reverse = bool(geo["reverse"])
        if index < walked_len - 1:
            artifact = (int(geo["end"]) - index - 1) if reverse \
                else (int(geo["start"]) + index + 1)
            return _heading_to(cell, geo["path"][artifact])
        if len(legs) > 1:
            head_geo = self._leg_geometry(legs[1])
            if head_geo:
                head = head_geo["path"][int(head_geo["end"])
                                         if head_geo["reverse"]
                                         else int(head_geo["start"])]
                if head != cell:
                    return _heading_to(cell, head)
                next_len = int(head_geo["walked_len"])
                if next_len > 1:
                    head_artifact = (int(head_geo["end"]) - 1) \
                        if head_geo["reverse"] else (int(head_geo["start"]) + 1)
                    return _heading_to(cell, head_geo["path"][head_artifact])
                return _heading_to(cell, head)
        berth = self._port_cell(str(fleet.get("dest_port_id", "")))
        if berth[0] >= 0:
            return _heading_to(cell, berth)
        return _heading_to(cell, geo["path"][int(geo["end"]) if reverse
                                             else int(geo["start"])])

    def _chase_step(self, fleet: dict[str, Any], target: tuple[int, int],
                    delta: float = 1.0) -> None:
        for _i in range(self._chase_budget(fleet, target, delta)):
            self._step_toward(fleet, target)

    def _chase_budget(self, fleet: dict[str, Any], target: tuple[int, int],
                      delta: float) -> int:
        fleet_id = str(fleet.get("id", ""))
        self._step_carry[fleet_id] = float(
            self._step_carry.get(fleet_id, 0.0)) \
            + self._step_allowance(fleet, target) * delta
        carry = float(self._step_carry[fleet_id])
        tiles = int(math.floor(carry))
        self._step_carry[fleet_id] = carry - float(tiles)
        return tiles

    # --- The daily step ---------------------------------------------------

    def _step_fleets(self, day: int) -> None:
        remove_ids: list[str] = []
        doomed: dict[str, bool] = {}
        wrecks: list[dict[str, Any]] = []
        pursuit_ms = 0.0
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            fleet_id = str(fleet.get("id", ""))
            if doomed.get(fleet_id):
                continue
            if int(fleet.get("cooldown_until_day", 0)) >= day:
                continue
            role = str(fleet.get("role", ""))
            if role == HUNTER and str(fleet.get("nation_id", "")) \
                    and str(fleet.get("nation_id", "")) \
                    not in self.bountied_nations():
                remove_ids.append(fleet_id)
                self._hunter_paths.pop(fleet_id, None)
                continue
            if role == HUNTER:
                pursuit_ms += self._hunter_tick(fleet, day, pursuit_ms)
                continue
            if role in (PIRATE, PRIVATEER):
                self._raider_tick(fleet, day, doomed, remove_ids, wrecks)
                continue
            route = fleet.get("route")
            legs = route.get("legs", []) if isinstance(route, dict) else []
            dwell_expired = int(fleet.get("dwell_until_day", 0)) <= day
            if not legs or not dwell_expired:
                if not legs:
                    mooring = self._port_at_cell(position_of(fleet))
                    lane_end_hold = role == PATROL \
                        and self._is_path_tile(position_of(fleet))
                    if not mooring and dwell_expired and not lane_end_hold:
                        dest = str(fleet.get("dest_port_id", ""))
                        berth = self._port_cell(dest) if dest else NO_CELL
                        if berth == NO_CELL:
                            berth = self._nearest_own_berth(fleet)
                        if berth != NO_CELL:
                            self._commit_cell(fleet, berth)
                if dwell_expired:
                    if role == TREASURE:
                        remove_ids.append(fleet_id)
                        continue
                    self._depart(fleet, day)
                continue
        for fleet_id in remove_ids:
            self.remove(fleet_id)
        for wreck in wrecks:
            self._state.wrecks.append(wreck)

    def _hunter_tick(self, fleet: dict[str, Any], _day: int,
                     _budget_used_ms: float) -> float:
        cell = position_of(fleet)
        target = self._state.player_tile()
        distance = chebyshev(cell, target)
        if str(fleet.get("hunter_state", HUNTER_STATE_INTEL)) \
                == HUNTER_STATE_CHASE:
            if distance > HUNTER_CHASE_OFF:
                self._hunter_route_to_intel(fleet)
                return 0.0
            return 0.0
        if distance <= HUNTER_CHASE_ON:
            fleet["hunter_state"] = HUNTER_STATE_CHASE
            self._hunter_paths.pop(str(fleet.get("id", "")), None)
            return 0.0
        intel_port = self._intel_port()
        state = str(fleet.get("hunter_state", HUNTER_STATE_INTEL))
        if state == HUNTER_STATE_INTEL and intel_port \
                and str(fleet.get("dest_port_id", "")) != intel_port:
            self._hunter_route_to_intel(fleet)
            return 0.0
        route = fleet.get("route")
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if legs:
            return 0.0
        if int(fleet.get("dwell_until_day", 0)) > int(self._state.day):
            return 0.0
        if state == HUNTER_STATE_INTEL:
            fleet["hunter_state"] = HUNTER_STATE_LOITER
            fleet["loiter_until_day"] = int(self._state.day) \
                + HUNTER_LOITER_DAYS
            self._camp_approaches(fleet, str(fleet.get("dest_port_id", "")))
        elif state == HUNTER_STATE_LOITER:
            self._hunter_route_home(fleet)
        elif state == HUNTER_STATE_HOME:
            self._hunter_route_to_intel(fleet)
        else:
            self._hunter_route_to_intel(fleet)
        return 0.0

    def _hunter_route_to_intel(self, fleet: dict[str, Any]) -> None:
        fleet["hunter_state"] = HUNTER_STATE_INTEL
        fleet["loiter_until_day"] = 0
        origin = self._port_at_cell(position_of(fleet))
        if not origin:
            origin = str(fleet.get("dest_port_id", ""))
        intel_port = self._intel_port()
        if not intel_port:
            intel_port = str(fleet.get("home_port_id", ""))
        if not origin or not intel_port or origin == intel_port:
            fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0,
                              "legs": []}
            fleet["dwell_until_day"] = int(self._state.day) + DWELL_DAYS
            return
        route = self.route_between(origin, intel_port)
        if not route:
            fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0,
                              "legs": []}
            fleet["dwell_until_day"] = int(self._state.day) + DWELL_DAYS
            return
        fleet["route"] = copy.deepcopy(route["legs_save"])
        fleet["dest_port_id"] = intel_port
        fleet["dwell_until_day"] = 0
        self._sync_route_progress(fleet)

    def _hunter_route_home(self, fleet: dict[str, Any]) -> None:
        fleet["hunter_state"] = HUNTER_STATE_HOME
        fleet["loiter_until_day"] = 0
        origin = self._port_at_cell(position_of(fleet))
        if not origin:
            origin = str(fleet.get("dest_port_id", ""))
        home = str(fleet.get("home_port_id", ""))
        if not origin or not home or origin == home:
            self._hunter_route_to_intel(fleet)
            return
        route = self.route_between(origin, home)
        if not route:
            self._hunter_route_to_intel(fleet)
            return
        fleet["route"] = copy.deepcopy(route["legs_save"])
        fleet["dest_port_id"] = home
        fleet["dwell_until_day"] = 0
        self._sync_route_progress(fleet)

    def _camp_approaches(self, fleet: dict[str, Any], port_id: str) -> None:
        berth = self._port_cell(port_id)
        if berth[0] < 0:
            return
        for offset in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
            y = berth[1] + offset[1]
            if y < 0 or y >= _NET.height:
                continue
            cell = ((berth[0] + offset[0]) % _NET.width, y)
            if not self._passable(cell):
                continue
            if self._is_occupied(cell, str(fleet.get("id", ""))):
                continue
            self._commit_cell(fleet, cell)
            return

    def _pursue(self, fleet: dict[str, Any], target: tuple[int, int],
                budget_used_ms: float, delta: float = 1.0) -> float:
        fleet_id = str(fleet.get("id", ""))
        plan = self._hunter_paths.get(fleet_id, {})
        path = plan.get("path", []) if isinstance(plan.get("path"), list) else []
        needs_plan = len(path) < 2 or chebyshev(
            (int(plan.get("target_x", -99999)),
             int(plan.get("target_y", -99999))), target) > 2
        if needs_plan:
            budget_left = float(self.path_budget_ms()) - budget_used_ms
            if budget_left <= 0.0:
                return 0.0
            started = time.perf_counter()
            path = find_path(position_of(fleet), target, _NET.width,
                             _NET.height, self._passable)
            elapsed = (time.perf_counter() - started) * 1000.0
            self._hunter_paths[fleet_id] = {
                "target_x": target[0], "target_y": target[1], "path": path}
            if elapsed > budget_left:
                return elapsed
            if len(path) < 2:
                return elapsed
        while len(path) >= 2 and delta > 0.0:
            nxt = path[1]
            if not self._can_enter(fleet, nxt):
                self._hunter_paths.pop(fleet_id, None)
                break
            allowance = self._step_allowance(fleet, nxt)
            carry = float(self._step_carry.get(fleet_id, 0.0)) \
                + allowance * delta
            if carry < 1.0:
                self._step_carry[fleet_id] = carry
                break
            tiles = int(math.floor(carry))
            self._step_carry[fleet_id] = carry - float(tiles)
            for _i in range(tiles):
                if len(path) < 2:
                    break
                step_tile = path[1]
                if not self._can_enter(fleet, step_tile):
                    self._hunter_paths.pop(fleet_id, None)
                    break
                path.pop(0)
                self._commit_cell(fleet, step_tile)
            delta = 0.0
        return 0.0

    def _walk_lane(self, fleet: dict[str, Any], day: int,
                   budget: int) -> int:
        walked = 0
        committed = 0
        while walked < budget:
            route = fleet.get("route", {})
            legs = route.get("legs", []) if isinstance(route, dict) else []
            if not legs:
                return committed
            geo = self._leg_geometry(legs[0])
            if not geo:
                self._note_event(str(fleet.get("id", "")),
                                 "drop leg:%s" % str(legs[0].get("id", "?")))
                route["legs"] = []
                return committed
            path = geo["path"]
            walked_len = int(geo["walked_len"])
            reverse = bool(geo["reverse"])
            index = self._leg_progress(fleet, route, geo)
            if index + 1 >= walked_len:
                pre = position_of(fleet)
                self._advance(fleet, day)
                walked += 1
                if position_of(fleet) != pre:
                    committed += 1
                continue
            direction = -1 if reverse else 1
            artifact = (int(geo["end"]) - index) if reverse \
                else (int(geo["start"]) + index)
            target = path[artifact + direction]
            if not self._passable(target):
                walked += 1
                continue
            route["tile_index"] = index + 1
            self._commit_cell(fleet, target)
            committed += 1
            walked += 1
        return committed

    def _docked_berth(self, fleet: dict[str, Any]) -> tuple[int, int]:
        mooring = self._port_at_cell(position_of(fleet))
        if mooring:
            return self._port_cell(mooring)
        dest = str(fleet.get("dest_port_id", ""))
        if not dest:
            return NO_CELL
        return self._port_cell(dest)

    def _advance(self, fleet: dict[str, Any], day: int) -> None:
        route = fleet.get("route", {})
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if not legs:
            return
        leg = legs[0]
        geo = self._leg_geometry(leg)
        if not geo:
            self._note_event(str(fleet.get("id", "")),
                             "drop leg:%s" % str(leg.get("id", "?")))
            route["legs"] = []
            return
        path = geo["path"]
        walked_len = int(geo["walked_len"])
        reverse = bool(geo["reverse"])
        index = self._leg_progress(fleet, route, geo)
        artifact = (int(geo["end"]) - index) if reverse \
            else (int(geo["start"]) + index)
        if index + 1 >= walked_len:
            if len(legs) > 1:
                head_geo = self._leg_geometry(legs[1])
                if not head_geo:
                    self._note_event(str(fleet.get("id", "")),
                                     "drop seam:%s"
                                     % str(legs[1].get("id", "?")))
                    route["legs"] = []
                    return
                head_path = head_geo["path"]
                head_tile = head_path[int(head_geo["end"])
                                      if head_geo["reverse"]
                                      else int(head_geo["start"])]
                if not self._passable(head_tile):
                    return
                stood_on_head = head_tile == position_of(fleet)
                legs.pop(0)
                route["leg"] = int(route.get("leg", 0)) + 1
                route["tile_index"] = 0
                self._commit_cell(fleet, head_tile)
                if stood_on_head:
                    next_len = int(head_geo["walked_len"])
                    if next_len > 1:
                        na = (int(head_geo["end"]) - 1) \
                            if head_geo["reverse"] \
                            else (int(head_geo["start"]) + 1)
                        next_tile = head_geo["path"][na]
                        if self._passable(next_tile) \
                                and next_tile != position_of(fleet):
                            route["tile_index"] = 1
                            self._commit_cell(fleet, next_tile)
                return
            legs.pop(0)
            route["leg"] = int(route.get("leg", 0)) + 1
            route["tile_index"] = 0
            self._arrive(fleet, day)
            return
        direction = -1 if reverse else 1
        target = path[artifact + direction]
        if not self._passable(target):
            return
        route["tile_index"] = index + 1
        self._commit_cell(fleet, target)

    def _can_enter(self, fleet: dict[str, Any], cell: tuple[int, int]) -> bool:
        """Co-location: entry is gated by passability only."""
        return self._passable(cell)

    def _record_wake(self, fleet: dict[str, Any],
                     cell: tuple[int, int]) -> None:
        if cell == NO_CELL:
            return
        fleet_id = str(fleet.get("id", ""))
        if not fleet_id:
            return
        trail = self._wake_trails.get(fleet_id, [])
        if trail and trail[0] == cell:
            return
        trail.insert(0, cell)
        while len(trail) > WAKE_LENGTH:
            trail.pop()
        self._wake_trails[fleet_id] = trail

    def _commit_cell(self, fleet: dict[str, Any],
                     cell: tuple[int, int]) -> None:
        before = position_of(fleet)
        set_position(fleet, cell)
        fleet_id = str(fleet.get("id", ""))
        if cell != before and fleet_id in self._accrual_paths:
            self._accrual_paths[fleet_id].append(cell)
        self._note_pass_contact(fleet, cell)
        if before != NO_CELL and before != cell:
            self._record_wake(fleet, before)
        if before != NO_CELL and fleet_id in self._by_id:
            self._move_bucket(fleet_id, before, cell)

    def _note_pass_contact(self, fleet: dict[str, Any],
                            cell: tuple[int, int]) -> None:
        if chebyshev(cell, self._player_tile_now()) > CONTACT_DISTANCE:
            return
        fleet_id = str(fleet.get("id", ""))
        if fleet_id and fleet_id not in self._pass_contacts:
            self._pass_contacts.append(fleet_id)
        nation_id = str(fleet.get("nation_id", ""))
        if not nation_id:
            return
        if int(self._state.reputation.get(nation_id, 0)) \
                > NAVY_HOSTILE_REPUTATION:
            return
        self._state.world["hunter_intel_cell"] = {"x": cell[0], "y": cell[1]}

    def _sync_route_progress(self, fleet: dict[str, Any]) -> None:
        route = fleet.get("route", {})
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if not legs:
            return
        geo = self._leg_geometry(legs[0])
        if not geo:
            return
        route["tile_index"] = self._leg_progress(fleet, route, geo)

    def _arrive(self, fleet: dict[str, Any], day: int) -> None:
        port_id = str(fleet.get("dest_port_id", ""))
        self._note_event(str(fleet.get("id", "")), "arr %s" % port_id)
        if port_id:
            berth = self._port_cell(port_id)
            if berth[0] >= 0:
                self._commit_cell(fleet, berth)
            self._log_port_traffic(port_id, "arrival", fleet, day)
        dwell = self._coaster_dwell_days() \
            if str(fleet.get("role", "")) == COASTER else DWELL_DAYS
        fleet["dwell_until_day"] = int(day) + dwell

    def _log_port_traffic(self, port_id: str, kind: str,
                           fleet: dict[str, Any], day: int) -> None:
        if not port_id:
            return
        self._state.npc_port_log.append({
            "port_id": port_id,
            "kind": kind,
            "role": str(fleet.get("role", "")),
            "nation_id": str(fleet.get("nation_id", "")),
            "fleet_id": str(fleet.get("id", "")),
            "day": int(day),
        })
        while len(self._state.npc_port_log) > PORT_LOG_MAX:
            self._state.npc_port_log.pop(0)

    def _depart(self, fleet: dict[str, Any], day: int) -> None:
        role = str(fleet.get("role", ""))
        nation_id = str(fleet.get("nation_id", ""))
        if role == TRADER:
            self._depart_trader(fleet, nation_id, day)
        elif role == COASTER:
            self._depart_coaster(fleet, nation_id, day)
        elif role == COURIER:
            self._depart_courier(fleet, nation_id, day)
        elif role == PATROL:
            self._depart_patrol(fleet, day)
        route = fleet.get("route")
        legs = route.get("legs", []) if isinstance(route, dict) else []
        if legs:
            self._sync_route_progress(fleet)
            self._fleet_mark[str(fleet.get("id", ""))] = \
                self._state.clock_now()
            moved_from = position_of(fleet)
            walker = str(fleet.get("id", ""))
            self._accrual_paths[walker] = []
            self._accrue_lane(fleet, day, self._pending_delta)
            moved_to = position_of(fleet)
            if moved_to != moved_from:
                self.moved_fleet_moves.append({
                    "id": walker, "from": moved_from,
                    "path": self._accrual_paths.get(walker, []),
                    "to": moved_to})

    # --- Port calls (NPC trade) -------------------------------------------

    def _sell_cargo(self, fleet: dict[str, Any], port_id: str,
                    cap: int) -> int:
        scope_limited = str(fleet.get("role", "")) == COASTER
        sold = 0
        cargo = fleet.get("cargo") if isinstance(
            fleet.get("cargo"), dict) else {}
        for good_id in list(cargo.keys()):
            good = str(good_id)
            held = int(cargo[good])
            if held <= 0:
                continue
            if scope_limited and not self.in_coaster_scope(good):
                continue
            if economy_lib.factor_units(
                    self._economy, self._store, port_id, good) <= 1000:
                continue
            qty = held if cap <= 0 else min(held, cap - sold)
            if qty <= 0:
                break
            stock = economy_lib.stock_of(
                self._economy, self._store, port_id, good)
            price = trade_lib.sell_price(port_id, good, stock)
            economy_lib.apply_trade(
                self._economy, self._store, port_id, good, -qty)
            self._credit_port_tax(port_id, fleet, qty, price)
            self._note_moved(port_id)
            cargo.pop(good)
            sold += qty
        return sold

    def in_coaster_scope(self, good_id: str) -> bool:
        """Decision 21: staples ∪ middle only (never luxury/specialty)."""
        tiers = _tiers(self._store)
        return economy_lib.tier_of(tiers, good_id) != "luxury"

    def coaster_scope_goods(self) -> list[str]:
        if _SCOPE_GOODS:
            return _SCOPE_GOODS
        for good in self._store.goods_list:
            good_id = str(good.get("id", ""))
            if not good_id or not self.in_coaster_scope(good_id):
                continue
            _SCOPE_GOODS.append(good_id)
        _SCOPE_GOODS.sort()
        return _SCOPE_GOODS

    def _note_moved(self, port_id: str) -> None:
        if port_id not in self.moved_ports:
            self.moved_ports.append(port_id)

    def _free_hold(self, fleet: dict[str, Any], capacity: int) -> int:
        used = 0
        cargo = fleet.get("cargo") if isinstance(
            fleet.get("cargo"), dict) else {}
        for good_id in cargo:
            used += int(cargo[good_id])
        return max(0, capacity - used)

    def _depart_trader(self, fleet: dict[str, Any], nation_id: str,
                       day: int) -> None:
        origin = self._docking_port_at_cell(fleet, position_of(fleet))
        if not origin:
            origin = str(fleet.get("dest_port_id", ""))
        if not origin:
            fleet["dwell_until_day"] = int(day) + DWELL_DAYS
            return
        self._sell_cargo(fleet, origin, 0)
        decision = self.decide_trade(fleet, origin, day)
        if not decision:
            fleet["dwell_until_day"] = int(day) + DWELL_DAYS
            return
        good = str(decision["good"])
        dest = str(decision["dest"])
        qty = int(decision["qty"])
        if qty > 0 and good:
            stock = economy_lib.stock_of(
                self._economy, self._store, origin, good)
            price = trade_lib.buy_price(origin, good, stock)
            economy_lib.apply_trade(
                self._economy, self._store, origin, good, qty)
            self._credit_port_tax(origin, fleet, qty, price)
            self._note_moved(origin)
            cargo = fleet.setdefault("cargo", {})
            cargo[good] = int(cargo.get(good, 0)) + qty
        self._set_route_to(fleet, origin, dest)

    def _depart_coaster(self, fleet: dict[str, Any], nation_id: str,
                        day: int) -> None:
        nationless = not nation_id
        if nationless:
            origin = self._port_at_cell(position_of(fleet))
        else:
            origin = self._docking_port_at_cell(fleet, position_of(fleet))
        if not origin:
            origin = str(fleet.get("dest_port_id", ""))
        if not origin:
            fleet["dwell_until_day"] = int(day) + self._coaster_dwell_days()
            return
        self._sell_cargo(fleet, origin, self.coaster_units())
        if nationless:
            dest = self._nearest_port_excluding(origin)
        else:
            dest = self._nearest_own_port_excluding(origin, nation_id)
        if not dest:
            fleet["dwell_until_day"] = int(day) + self._coaster_dwell_days()
            return
        pool = self.coaster_scope_goods() if nationless \
            else self.nation_goods(nation_id)
        best_good = ""
        best_margin = 0
        for good_id in pool:
            good = str(good_id)
            if not self.in_coaster_scope(good):
                continue
            dest_stock = economy_lib.stock_of(
                self._economy, self._store, dest, good)
            origin_stock = economy_lib.stock_of(
                self._economy, self._store, origin, good)
            margin = trade_lib.sell_price(dest, good, dest_stock) \
                - trade_lib.buy_price(origin, good, origin_stock)
            if margin > best_margin:
                best_margin = margin
                best_good = good
        if best_good and best_margin > 0:
            saturation = self._saturation_bound(dest, best_good)
            qty = min(self.coaster_units(),
                      self._free_hold(fleet, COASTER_HOLD_CAPACITY))
            qty = min(qty, saturation)
            if qty > 0:
                stock = economy_lib.stock_of(
                    self._economy, self._store, origin, best_good)
                price = trade_lib.buy_price(origin, best_good, stock)
                economy_lib.apply_trade(
                    self._economy, self._store, origin, best_good, qty)
                self._credit_port_tax(origin, fleet, qty, price)
                self._note_moved(origin)
                cargo = fleet.setdefault("cargo", {})
                cargo[best_good] = int(cargo.get(best_good, 0)) + qty
        self._set_route_to(fleet, origin, dest)

    def _depart_courier(self, fleet: dict[str, Any], nation_id: str,
                        day: int) -> None:
        origin = str(fleet.get("dest_port_id", ""))
        capital = self._capital_of(nation_id)
        dest = capital
        if origin == capital or not origin:
            rng = _fleet_rng(fleet, "courier|%d" % day)
            ports = self.nation_ports(nation_id)
            if not ports:
                fleet["dwell_until_day"] = int(day) + DWELL_DAYS
                return
            dest = ports[rng.randi_range(0, len(ports) - 1)]
        self._set_route_to(fleet, origin if origin else capital, dest)

    def _depart_patrol(self, fleet: dict[str, Any], _day: int) -> None:
        route = fleet.get("route", {})
        lanes = route.get("lanes", []) if isinstance(route, dict) else []
        if not lanes:
            return
        lane_id = str(lanes[0])
        base = _NET.lane_paths.get(lane_id, [])
        if not base:
            return
        geo = self._leg_geometry({"kind": "lane", "id": lane_id,
                                  "reverse": False, "a": 0,
                                  "b": len(base) - 1})
        if not geo:
            return
        path = geo["path"]
        far_end = int(geo["end"])
        cell = position_of(fleet)
        nearest = 0
        best_d = -1
        for index, tile in enumerate(path):
            d = chebyshev(cell, tile)
            if best_d < 0 or d < best_d:
                best_d = d
                nearest = index
        if best_d > 1:
            self._note_event(str(fleet.get("id", "")),
                             "depX off-lane %s" % lane_id)
            fleet["dwell_until_day"] = int(self._state.day) + DWELL_DAYS
            return
        reverse = chebyshev(cell, path[0]) > chebyshev(cell, path[far_end])
        ti = nearest
        if reverse:
            ti = far_end - nearest
        route["leg"] = 0
        route["tile_index"] = ti
        route["legs"] = [{"kind": "lane", "id": lane_id,
                          "reverse": reverse, "a": 0,
                          "b": len(base) - 1}]
        fleet["route"] = route
        fleet["dwell_until_day"] = 0

    def _set_route_to(self, fleet: dict[str, Any], origin: str,
                      dest: str) -> None:
        route = self.route_between(origin, dest)
        if not route:
            self._note_event(str(fleet.get("id", "")),
                             "depX %s->%s" % (origin, dest))
            fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0,
                              "legs": []}
            fleet["dwell_until_day"] = int(self._state.day) + (
                self._coaster_dwell_days()
                if str(fleet.get("role", "")) == COASTER else DWELL_DAYS)
            return
        fleet["route"] = copy.deepcopy(route["legs_save"])
        fleet["dest_port_id"] = dest
        fleet["dwell_until_day"] = 0
        self._note_event(str(fleet.get("id", "")),
                         "dep %s->%s" % (origin, dest))
        self._log_port_traffic(origin, "departure", fleet,
                               int(self._state.day))

    def decide_trade(self, fleet: dict[str, Any], origin: str,
                     day: int) -> dict[str, Any]:
        """The trader decision (``30-*`` §4.4): the top-scored candidate."""
        candidates = self.score_all_candidates(fleet, origin, day)
        return candidates[0] if candidates else {}

    def score_all_candidates(self, fleet: dict[str, Any], origin: str,
                             day: int) -> list[dict[str, Any]]:
        """Every live (good, destination) candidate with its §4.4 score."""
        nation_id = str(fleet.get("nation_id", ""))
        goods = self.nation_goods(nation_id)
        if not goods or not origin:
            return []
        specialty = str(fleet.get("specialty", ""))
        if not specialty:
            specialty = self._draw_specialty(nation_id,
                                             int(fleet.get("seed", 0)))
            fleet["specialty"] = specialty
        rng = _fleet_rng(fleet, "decision|%d" % day)
        free = self._free_hold(fleet, TRADER_HOLD_CAPACITY)
        out: list[dict[str, Any]] = []
        draws = 0
        dests = self._candidate_destinations(origin, nation_id)
        buy_prices: dict[str, int] = {}
        for good in goods:
            stock = economy_lib.stock_of(
                self._economy, self._store, origin, str(good))
            buy_prices[good] = trade_lib.buy_price(origin, str(good), stock)
        for dest in dests:
            route = self.route_between(origin, str(dest))
            if not route:
                continue
            lane_days = float(int(route["length"])) \
                / float(LANE_TILES_PER_DAY)
            risk = self._route_risk(route, nation_id)
            for good in goods:
                draws += 1
                if draws > CANDIDATE_SCAN_LIMIT:
                    break
                qty = min(self.trade_units_per_call(), free)
                qty = min(qty, self._saturation_bound(str(dest), str(good)))
                if qty <= 0:
                    continue
                dest_stock = economy_lib.stock_of(
                    self._economy, self._store, str(dest), str(good))
                est_sell = trade_lib.sell_price(str(dest), str(good),
                                                dest_stock)
                buy = int(buy_prices[good])
                spec = SPEC_MULT if str(good) == specialty else 1.0
                noise = NOISE_MIN + (NOISE_MAX - NOISE_MIN) * rng.randf()
                margin = float(est_sell - buy)
                score = margin * float(qty) * spec * noise * risk \
                    / (lane_days + 2.0)
                out.append({"good": str(good), "dest": str(dest), "qty": qty,
                            "score": score, "lane_days": lane_days,
                            "risk": risk, "est_sell": est_sell, "buy": buy})
        out.sort(key=lambda entry: float(entry["score"]), reverse=True)
        return out

    def _candidate_destinations(self, origin: str, nation_id: str) \
            -> list[str]:
        out: list[str] = []
        center = self._port_cell(origin)
        if center[0] < 0:
            return out
        for port_id in self.alignment_ports(nation_id):
            if port_id == origin:
                continue
            if chebyshev(center, self._port_cell(port_id)) <= CANDIDATE_RADIUS:
                out.append(port_id)
        return out

    def _saturation_bound(self, dest: str, good: str) -> int:
        return max(0, 100 - economy_lib.stock_of(
            self._economy, self._store, dest, good))

    def _route_risk(self, route: dict[str, Any], _nation_id: str) -> float:
        path = route.get("path", [])
        if len(path) < 2:
            return 1.0
        stride = max(1, math.ceil(float(len(path)) / float(RISK_SAMPLE_MAX)))
        index = 0
        while index < RISK_SAMPLE_MAX:
            at = min(len(path) - 1, index * stride)
            tile = path[at]
            for fleet in self.within(tile, RISK_RADIUS):
                role = str(fleet.get("role", ""))
                if role in (PIRATE, PRIVATEER):
                    return RISK_MULT
            index += 1
            if at == len(path) - 1:
                break
        return 1.0

    def trade_units_per_call(self) -> int:
        return int(self._flow().get("trade_units_per_port_call", 30))

    def coaster_units(self) -> int:
        return int(self._flow().get("coaster_trade_units", 5))

    def _coaster_dwell_days(self) -> int:
        return COASTER_DWELL_DAYS

    def path_budget_ms(self) -> int:
        return int(self._flow().get("path_budget_ms_per_day", 250))

    # --- Task L schedulers: treasure fleets & captains --------------------

    def _schedule_treasure(self, day: int) -> None:
        for nation in self._store.nations_list:
            nation_id = str(nation.get("id", ""))
            if not nation_id:
                continue
            if not treasure_due(nation_id, int(day), self._store):
                continue
            if self._count_role(TREASURE, nation_id) > 0:
                continue
            self.spawn(TREASURE, nation_id, int(day))

    def _lane_board_route(self, lane_id: str,
                          harbor: tuple[int, int]) -> dict[str, Any]:
        self._refresh_net()
        lane_path = _NET.lane_paths.get(lane_id, [])
        if not lane_path or harbor[0] < 0:
            return {}
        best_index = 0
        best_distance = -1
        for index, tile in enumerate(lane_path):
            distance = chebyshev(harbor, tile)
            if best_distance < 0 or distance < best_distance:
                best_distance = distance
                best_index = index
        if self._is_occupied(lane_path[best_index], ""):
            step = -1 if best_index > len(lane_path) // 2 else 1
            scan = best_index + step
            free = -1
            while 0 <= scan < len(lane_path):
                if not self._is_occupied(lane_path[scan], ""):
                    free = scan
                    break
                scan += step
            if free < 0:
                return {}
            best_index = free
        reverse = best_index > len(lane_path) // 2
        ti = (len(lane_path) - 1 - best_index) if reverse else best_index
        return {
            "cell": lane_path[best_index],
            "route": {"lanes": [lane_id], "leg": 0, "tile_index": ti,
                      "legs": [{"kind": "lane", "id": lane_id,
                                "reverse": reverse, "a": 0,
                                "b": len(lane_path) - 1}]},
        }

    def _treasure_journey(self, nation_id: str, day: int) \
            -> dict[str, Any]:
        self._refresh_net()
        capital = self._capital_of(nation_id)
        lane_id = str(_NET.spoke_lane.get(capital, ""))
        if not capital or not lane_id:
            return {}
        harbor = self._port_cell(capital)
        if harbor[0] < 0:
            return {}
        boarded = self._lane_board_route(lane_id, harbor)
        if not boarded:
            return {}
        return {
            "cell": boarded["cell"],
            "route": boarded["route"],
            "cargo": self._treasure_cargo(nation_id, day),
        }

    def _treasure_cargo(self, nation_id: str, day: int) -> dict[str, int]:
        goods = self.nation_goods(nation_id)
        if not goods:
            return {}
        rng = GodotRng(seed=int(day) * SEED_DAY_MULT
                       + nation_index(nation_id, self._store) * SEED_X_MULT
                       + _godot_hash("treasure|" + nation_id))
        good = goods[rng.randi_range(0, len(goods) - 1)]
        units = TREASURE_CARGO_MULT * self.trade_units_per_call()
        return {good: units}

    def _captain_return_tick(self, day: int) -> None:
        nemesis: list[str] = []
        states = self._state.captain_states
        for captain_id, entry in states.items():
            if not isinstance(entry, dict):
                continue
            if str(entry.get("status", "")) != "returning":
                continue
            if int(day) < int(entry.get("return_day", 0)):
                continue
            if self._captains.is_nemesis(str(captain_id)):
                nemesis.append(str(captain_id))
        nemesis.sort()
        self._captains.day_tick(int(day))
        absolute = int(self._npc_config().get("absolute_cap", 2048))
        for captain_id in nemesis:
            if self._captains.is_deployed(captain_id):
                continue
            if len(self._state.npc_fleets) >= absolute:
                break
            fleet = self.spawn(HUNTER, "", int(day))
            if not fleet:
                continue
            drawn = str(fleet.get("captain_id", ""))
            if drawn and drawn != captain_id:
                self._captains.release(drawn)
            fleet["captain_id"] = captain_id
            self._captains.deploy(captain_id)

    # --- Trickle & budgets ------------------------------------------------

    def _trickle(self, day: int) -> list[dict[str, Any]]:
        spawned: list[dict[str, Any]] = []
        budget = self.trickle_per_day()
        absolute = int(self._npc_config().get("absolute_cap", 2048))
        cap = self.global_cap()
        for _attempt in range(budget * 4):
            if len(spawned) >= budget:
                break
            if len(self._state.npc_fleets) >= absolute:
                break
            if len(self._state.npc_fleets) >= cap:
                break
            deficit = self._largest_deficit()
            if not deficit:
                break
            fleet = self.spawn(str(deficit["role"]),
                               str(deficit["nation_id"]), day)
            if fleet:
                spawned.append(fleet)
                deficit["deficit"] = int(deficit["deficit"]) - 1
                if int(deficit["deficit"]) <= 0:
                    self._deficit_list.pop(0)
            else:
                self._skip[str(deficit["role"]) + "|"
                           + str(deficit["nation_id"])] = int(day)
        return spawned

    def _largest_deficit(self) -> dict[str, Any]:
        day = self.last_tick_day
        if self._deficit_day != day:
            self._deficit_day = day
            self._deficit_list = self._compute_deficit_list()
        while self._deficit_list:
            head = self._deficit_list[0]
            owner = str(head["role"]) + "|" + str(head["nation_id"])
            if not (owner in self._skip and int(self._skip[owner]) == day):
                return head
            self._deficit_list.pop(0)
        return {}

    def _compute_deficit_list(self) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        for role in FILL_ORDER:
            if role == PIRATE:
                live = self._count_role(role, "")
                want = self.budget_for(role, "")
                if want > live:
                    entries.append({"role": role, "nation_id": "",
                                    "deficit": want - live,
                                    "index": len(entries)})
                continue
            if role == COASTER:
                grey_live = self._count_role_nationless(role)
                grey_want = self.budget_for(role, "")
                if grey_want > grey_live:
                    entries.append({"role": role, "nation_id": "",
                                    "deficit": grey_want - grey_live,
                                    "index": len(entries)})
            if role == HUNTER:
                for nation_id in self.bountied_nations():
                    if self._count_role(role, nation_id) == 0:
                        entries.append({"role": role,
                                        "nation_id": nation_id,
                                        "deficit": 1,
                                        "index": len(entries)})
                continue
            for nation_id in self._port_counts():
                want = self.budget_for(role, nation_id)
                live = self._count_role(role, nation_id)
                if want > live:
                    entries.append({"role": role, "nation_id": nation_id,
                                    "deficit": want - live,
                                    "index": len(entries)})
        entries.sort(key=lambda entry: (-int(entry["deficit"]),
                                        int(entry["index"])))
        return entries

    def _count_role(self, role: str, nation_id: str) -> int:
        count = 0
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            if str(fleet.get("role", "")) != role:
                continue
            if nation_id and str(fleet.get("nation_id", "")) != nation_id:
                continue
            count += 1
        return count

    def _count_role_nationless(self, role: str) -> int:
        count = 0
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            if str(fleet.get("role", "")) != role:
                continue
            if str(fleet.get("nation_id", "")) != "":
                continue
            count += 1
        return count

    def _recount_zones(self, day: int) -> None:
        if self._zones_day == int(day) and self._unpatrolled_zones >= 0:
            return
        self._zones_day = int(day)
        unpatrolled = 0
        for port in self._store.ports_list:
            port_id = str(port.get("id", ""))
            nation_id = str(port.get("nation_id", ""))
            if not port_id or not nation_id:
                continue
            cell = self._port_cell(port_id)
            if cell[0] < 0:
                continue
            if not self._zone_has_patrol(cell, nation_id):
                unpatrolled += 1
        self._unpatrolled_zones = unpatrolled

    def _zone_has_patrol(self, cell: tuple[int, int], nation_id: str) -> bool:
        for fleet in self.within(cell, ZONE_RADIUS):
            if str(fleet.get("role", "")) != PATROL:
                continue
            if str(fleet.get("nation_id", "")) == nation_id:
                return True
        return False

    def is_escorted(self, fleet: dict[str, Any]) -> bool:
        """Same-nation patrol within Chebyshev 20 (§4.1.1 patrol row)."""
        for other in self.within(position_of(fleet), ESCORT_RADIUS):
            if other is fleet:
                continue
            if str(other.get("role", "")) != PATROL:
                continue
            if str(other.get("nation_id", "")) \
                    == str(fleet.get("nation_id", "")):
                return True
        return False

    def _intel_port(self) -> str:
        return str(self._state.world.get("last_departed_port", ""))

    def note_contacts(self, cell: tuple[int, int]) -> bool:
        """§4.11.11.1 at-sea intel: contact with a hunting nation (rep ≤ −50)
        sets ``world.hunter_intel_cell``. One assignment per contact."""
        for fleet in self.within(cell, CONTACT_DISTANCE):
            nation_id = str(fleet.get("nation_id", ""))
            if not nation_id:
                continue
            if int(self._state.reputation.get(nation_id, 0)) \
                    > NAVY_HOSTILE_REPUTATION:
                continue
            self._state.world["hunter_intel_cell"] = {
                "x": cell[0], "y": cell[1]}
            return True
        return False

    def prey_candidates(self, fleet: dict[str, Any]) -> list[dict[str, Any]]:
        """Raider prey within Chebyshev 10: traders + patrols, never coasters;
        a privateer hunts only its sponsor's rivals."""
        out: list[dict[str, Any]] = []
        for other in self.within(position_of(fleet), PREY_RADIUS):
            if other is fleet:
                continue
            role = str(other.get("role", ""))
            if role not in (TRADER, PATROL):
                continue
            if str(fleet.get("role", "")) == PRIVATEER \
                    and str(other.get("nation_id", "")) \
                    not in self._rivals_of(str(fleet.get("nation_id", ""))):
                continue
            out.append(other)
        return out

    # --- Spatial index (wrap-aware cell-bucket hash) ----------------------

    def reset_index(self) -> None:
        self._index_dirty = True

    def _refresh_index(self) -> None:
        if not self._index_dirty:
            return
        self._index_dirty = False
        self._buckets = {}
        self._by_id = {}
        for fleet in self._state.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            self._index_add(fleet)

    def _index_add(self, fleet: dict[str, Any]) -> None:
        fleet_id = str(fleet.get("id", ""))
        if not fleet_id:
            return
        self._by_id[fleet_id] = fleet
        bucket = _bucket_of(position_of(fleet))
        self._buckets.setdefault(bucket, []).append(fleet_id)

    def _index_remove(self, fleet_id: str) -> None:
        self._by_id.pop(fleet_id, None)

    def _move_bucket(self, fleet_id: str, from_cell: tuple[int, int],
                     to_cell: tuple[int, int]) -> None:
        from_bucket = _bucket_of(from_cell)
        to_bucket = _bucket_of(to_cell)
        if from_bucket == to_bucket:
            return
        entries = self._buckets.get(from_bucket, [])
        if fleet_id in entries:
            entries.remove(fleet_id)
        if not entries:
            self._buckets.pop(from_bucket, None)
        self._buckets.setdefault(to_bucket, []).append(fleet_id)

    def within(self, cell: tuple[int, int], radius: int) \
            -> list[dict[str, Any]]:
        """EVERY "within N tiles" query rides the wrap-aware bucket hash."""
        self._refresh_index()
        return _bucket_query(self._buckets, self._by_id, cell, radius)

    def _is_occupied(self, cell: tuple[int, int], ignore_id: str) -> bool:
        """Spawn/camp spread preference (not a movement rule): a cell is
        taken by the player or an under-way fleet."""
        if cell == self._player_tile_now():
            return True
        self._refresh_index()
        for fleet_id in self._buckets.get(_bucket_of(cell), []):
            if str(fleet_id) == ignore_id:
                continue
            fleet = self._by_id.get(fleet_id, {})
            if not fleet:
                continue
            if int(fleet.get("dwell_until_day", 0)) > 0:
                continue  # docked fleets share port tiles
            if position_of(fleet) == cell:
                return True
        return False

    # --- Small helpers ----------------------------------------------------

    def _player_tile_now(self) -> tuple[int, int]:
        return self._tick_player_tile if self._tick_scoped \
            else self._state.player_tile()

    def _find(self, fleet_id: str) -> dict[str, Any]:
        for fleet in self._state.npc_fleets:
            if isinstance(fleet, dict) \
                    and str(fleet.get("id", "")) == fleet_id:
                return fleet
        return {}

    def _port_at_cell(self, cell: tuple[int, int]) -> str:
        return self._world.port_id_at(cell[0], cell[1])

    def _docking_port_at_cell(self, fleet: dict[str, Any],
                              cell: tuple[int, int]) -> str:
        port_id = self._port_at_cell(cell)
        if not port_id:
            return ""
        role = str(fleet.get("role", ""))
        nation_id = str(fleet.get("nation_id", ""))
        if role == COASTER and not nation_id:
            return port_id
        if not nation_id:
            return ""
        if role == TRADER:
            return port_id if self.port_alignment(port_id) == nation_id else ""
        if str(self._store.get_port(port_id).get("nation_id", "")) \
                != nation_id:
            return ""
        return port_id

    def _port_cell(self, port_id: str) -> tuple[int, int]:
        cell = self._world.port_cell(port_id)
        return cell if cell[0] >= 0 else NO_CELL

    def _passable(self, cell: tuple[int, int]) -> bool:
        """Entry gate: water + not in-month seasonal ice (memoized per day)."""
        if self._passable_day != int(self._state.day):
            self._passable_cache = {}
            self._passable_day = int(self._state.day)
        cached = self._passable_cache.get(cell)
        if cached is not None:
            return cached
        out = False
        if self._world.is_passable(cell[0], cell[1]):
            out = not self._world.ice_blocks(
                cell[0], cell[1], month_for(self._state.day))
        self._passable_cache[cell] = out
        return out

    # --- Event ring (runtime only, 80-* §4.6 [raw3]) ----------------------

    def _note_event(self, fleet_id: str, text: str) -> None:
        ring = self._fleet_events.get(fleet_id)
        if ring is None:
            ring = []
            self._fleet_events[fleet_id] = ring
        ring.append("%s@%d" % (text, int(self._state.day)))
        while len(ring) > FLEET_EVENT_MAX:
            ring.pop(0)


# --- Module-level geometry / index helpers ----------------------------------


def _cell_key(cell: tuple[int, int]) -> int:
    return int(cell[1]) * _NET.width + int(cell[0] % _NET.width)


def _key_to_cell(key: int) -> tuple[int, int]:
    return (int(key % _NET.width), int(key // _NET.width))


def _bucket_of(cell: tuple[int, int]) -> int:
    return (cell[1] // BUCKET_SIZE) * _buckets_x() \
        + (cell[0] % _NET.width) // BUCKET_SIZE


def _buckets_x() -> int:
    return (_NET.width - 1) // BUCKET_SIZE + 1


def fleets_within(state: FleetEcologyState, cell: tuple[int, int],
                  radius: int, store: DataStore | None = None) \
        -> list[dict[str, Any]]:
    """Stateless wrap-aware bucket query over a state's fleets (the intel
    module's read path — the sim keeps its own incremental index)."""
    dst = store if store is not None else data()
    grid = dst.map_legend.get("grid", {}) \
        if isinstance(dst.map_legend, dict) else {}
    _NET.width = int(grid.get("width", GRID_WIDTH)) or GRID_WIDTH
    _NET.height = int(grid.get("height", GRID_HEIGHT)) or GRID_HEIGHT
    buckets: dict[int, list[str]] = {}
    by_id: dict[str, dict[str, Any]] = {}
    for fleet in state.npc_fleets:
        if not isinstance(fleet, dict):
            continue
        fleet_id = str(fleet.get("id", ""))
        if not fleet_id:
            continue
        by_id[fleet_id] = fleet
        buckets.setdefault(_bucket_of(position_of(fleet)), []).append(fleet_id)
    return _bucket_query(buckets, by_id, cell, radius)


def _bucket_query(buckets: dict[int, list[str]],
                  by_id: dict[str, dict[str, Any]],
                  cell: tuple[int, int], radius: int) -> list[dict[str, Any]]:
    """The wrap-aware bucket scan (the §4.11.11.5 review-gate query body)."""
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    buckets_x = _buckets_x()
    max_bucket_y = (_NET.height - 1) // BUCKET_SIZE
    min_bx = ((cell[0] - radius) % _NET.width) // BUCKET_SIZE
    max_bx = ((cell[0] + radius) % _NET.width) // BUCKET_SIZE
    by = (cell[1] % _NET.height) // BUCKET_SIZE
    span_y = (radius + BUCKET_SIZE - 1) // BUCKET_SIZE
    min_by = max(0, by - span_y)
    max_by = min(max_bucket_y, by + span_y)
    bx = min_bx
    while True:
        bucket_y = min_by
        while bucket_y <= max_by:
            bucket = bucket_y * buckets_x + bx
            for fleet_id in buckets.get(bucket, []):
                if fleet_id in seen:
                    continue
                seen.add(fleet_id)
                fleet = by_id.get(fleet_id, {})
                if not fleet:
                    continue
                if chebyshev(cell, position_of(fleet)) <= radius:
                    out.append(fleet)
            bucket_y += 1
        if bx == max_bx:
            break
        bx = (bx + 1) % buckets_x
    return out


def _walked_path(path: list[tuple[int, int]], i: int, j: int,
                 reverse: bool) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    if reverse:
        k = j
        while k >= i:
            out.append(path[k])
            k -= 1
    else:
        k = i
        while k <= j:
            out.append(path[k])
            k += 1
    return out


def _share_lane(a: dict[str, Any], b: dict[str, Any]) -> bool:
    lanes_a = a.get("route", {}).get("lanes", []) \
        if isinstance(a.get("route"), dict) else []
    lanes_b = b.get("route", {}).get("lanes", []) \
        if isinstance(b.get("route"), dict) else []
    return any(lane_id in lanes_b for lane_id in lanes_a)


def _fleet_seed(day: int, cell: tuple[int, int]) -> int:
    return int(day) * SEED_DAY_MULT + cell[0] * SEED_X_MULT \
        + cell[1] * SEED_Y_MULT


def _fleet_rng(fleet: dict[str, Any], purpose: str) -> GodotRng:
    """The per-fleet deterministic stream (seed + purpose-tag hash)."""
    seed_value = int(fleet.get("seed", 0))
    tag = _godot_hash(str(seed_value) + "|" + purpose)
    return GodotRng(seed=seed_value * 31 + tag)


_TIERS: dict[str, dict[str, int]] = {}


def _tiers(store: DataStore) -> dict[str, dict[str, int]]:
    if not _TIERS:
        _TIERS.update(economy_lib.build_tiers(store.goods_list))
    return _TIERS


def _heading_to(frm: tuple[int, int], to: tuple[int, int]) -> str:
    """The wrapped 8-dir heading from ``from`` toward ``to`` ("" if equal)."""
    dx = (to[0] - frm[0]) % _NET.width
    if dx > _NET.width / 2:
        dx -= _NET.width
    dy = to[1] - frm[1]
    exact = heading_of_delta((dx, dy))
    if exact:
        return exact
    sx = 1 if dx > 0 else -1
    sy = 1 if dy > 0 else -1
    if abs(dx) >= abs(dy):
        if dx != 0:
            return heading_of_delta((sx, 0))
        if dy != 0:
            return heading_of_delta((0, sy))
    else:
        if dy != 0:
            return heading_of_delta((0, sy))
        if dx != 0:
            return heading_of_delta((sx, 0))
    return ""


# --- Phase-6 parity factors (docs/60-* §4.11.11 amendment) ------------------


def npc_direction_factor(heading: str, cell: tuple[int, int], month: int,
                         ship_class: str = NPC_SAIL_CLASS) -> float:
    """The §4.4 direction factor for an NPC step of ``heading`` at ``cell``:
    the region's PREVAILING wind token for the month (no jitter/calm gate —
    a pure day+cell function), read from ``DIRECTION_FACTORS`` at the
    fleet's flagship class. ``VAR`` / unknown headings → 1.0."""
    global _FACTOR_MEMO_MONTH
    if _FACTOR_MEMO_MONTH != month:
        _PREVAILING_MEMO.clear()
        _CURRENT_MEMO.clear()
        _FACTOR_MEMO_MONTH = month
    wind_from = _PREVAILING_MEMO.get(cell, "")
    if not wind_from:
        wind_from = raster_module.ocean_layers().prevailing_for(
            cell[0], cell[1], month)
        _PREVAILING_MEMO[cell] = wind_from
    if wind_from == "VAR":
        return 1.0
    angle = angle_between_dirs(heading, wind_from)
    if angle < 0:
        return 1.0
    table = DIRECTION_FACTORS.get(angle, {})
    return float(table.get(ship_class, table.get(NPC_SAIL_CLASS, 1.0)))


def npc_current_factor(heading: str, cell: tuple[int, int],
                       month: int) -> float:
    """The §4.16 current modifier for an NPC step of ``heading`` at ``cell``
    (unconditional — not gated on the player's current mode):
    aligned < 67.5° → ``1 + 0.08 × strength``, opposed > 112.5° → the
    negative, else 1.0. Empty current/unknown heading → 1.0."""
    global _FACTOR_MEMO_MONTH
    if _FACTOR_MEMO_MONTH != month:
        _PREVAILING_MEMO.clear()
        _CURRENT_MEMO.clear()
        _FACTOR_MEMO_MONTH = month
    if cell in _CURRENT_MEMO:
        current = _CURRENT_MEMO[cell]
    else:
        current = raster_module.ocean_layers().current_at(
            cell[0], cell[1], month)
        _CURRENT_MEMO[cell] = current
    if not current:
        return 1.0
    angle = angle_between_dirs(heading, str(current["dir"]))
    if angle < 0:
        return 1.0
    strength = float(current["strength"])
    if float(angle) < CURRENT_ALIGNED_DEG:
        return 1.0 + CURRENT_ALIGN_FACTOR * strength
    if float(angle) > CURRENT_OPPOSED_DEG:
        return 1.0 - CURRENT_ALIGN_FACTOR * strength
    return 1.0


# --- Hostility & captain reads (module-level, no instance state) ------------


def is_hostile_fleet(state: FleetEcologyState, fleet: dict[str, Any]) -> bool:
    """§4.11.11.1 hostility: pirates + privateers always; a hunter while the
    player holds its nation's bounty (rep ≤ −50) or when nationless (nemesis)."""
    role = str(fleet.get("role", ""))
    if role in (PIRATE, PRIVATEER):
        return True
    if role != HUNTER:
        return False
    nation_id = str(fleet.get("nation_id", ""))
    if not nation_id:
        return True
    return int(state.reputation.get(nation_id, 0)) <= NAVY_HOSTILE_REPUTATION


def captain_card_of(fleet: dict[str, Any],
                    store: DataStore | None = None) -> dict[str, Any]:
    """The fleet captain's canon card (``{}`` without one)."""
    dst = store if store is not None else data()
    return dst.get_captain(str(fleet.get("captain_id", "")))


def captain_tier_of(fleet: dict[str, Any],
                    store: DataStore | None = None) -> int:
    return int(captain_card_of(fleet, store).get("tier", 0))


def captain_name(fleet: dict[str, Any],
                 t: Callable[[Any], str] | None = None,
                 store: DataStore | None = None) -> Any:
    """The captain card's localized name through the injected ``t`` view;
    the raw L10nString dict when no view is wired (web UI formats it)."""
    card = captain_card_of(fleet, store)
    if not card:
        return "" if t is None else t({})
    name = card.get("name", {})
    return t(name) if t is not None else name


def famous_pirate_ids(store: DataStore | None = None) -> list[str]:
    """The 4 famous named-pirate canon ids (``named_pirates.json`` order)."""
    dst = store if store is not None else data()
    out: list[str] = []
    for entry in dst.named_pirates_list:
        entry_id = str(entry.get("id", ""))
        if entry_id:
            out.append(entry_id)
    return out


def named_captain_of(fleet: dict[str, Any],
                     store: DataStore | None = None) -> dict[str, Any]:
    """The famous-pirate card a fleet's captain carries (``{}`` otherwise)."""
    dst = store if store is not None else data()
    captain_id = str(fleet.get("captain_id", ""))
    if not captain_id or captain_id not in famous_pirate_ids(dst):
        return {}
    card = dst.get_captain(captain_id)
    if not card:
        return dst.get_named_pirate(captain_id)
    return card


def is_named_captain(fleet: dict[str, Any],
                     store: DataStore | None = None) -> bool:
    return bool(named_captain_of(fleet, store))


def named_tier_of(fleet: dict[str, Any],
                  store: DataStore | None = None) -> int:
    return captain_tier_of(fleet, store)


def preferred_bounty_target(state: FleetEcologyState,
                            store: DataStore | None = None) \
        -> dict[str, Any]:
    """The first famous-pirate entry with a live pirate carrier (else ``{}``)."""
    dst = store if store is not None else data()
    for entry in dst.named_pirates_list:
        named_id = str(entry.get("id", ""))
        if not named_id:
            continue
        best: dict[str, Any] = {}
        for fleet in state.npc_fleets:
            if not isinstance(fleet, dict) \
                    or str(fleet.get("role", "")) != PIRATE:
                continue
            if str(fleet.get("captain_id", "")) != named_id:
                continue
            if not best or str(fleet.get("id", "")) < str(best.get("id", "")):
                best = fleet
        if best:
            return best
    return {}


# --- Task L schedulers (module-level) ---------------------------------------


def nation_index(nation_id: str, store: DataStore | None = None) -> int:
    """``nation_index`` = the nation's position in ``nations.json`` order."""
    dst = store if store is not None else data()
    for index, nation in enumerate(dst.nations_list):
        if str(nation.get("id", "")) == nation_id:
            return index
    return -1


def treasure_due(nation_id: str, day: int,
                 store: DataStore | None = None) -> bool:
    """True on the nation's treasure day (``45 + 15 × index`` mod 90)."""
    index = nation_index(nation_id, store)
    if index < 0:
        return False
    due = int(day) - (TREASURE_BASE_DAY + TREASURE_NATION_STEP * index)
    return due >= 0 and due % TREASURE_SEASON_DAYS == 0
