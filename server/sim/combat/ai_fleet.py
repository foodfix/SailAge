"""server.sim.combat.ai_fleet — enemy fleet composition and battle AI (M1).

Python port of ``scripts/combat/ai_fleet.gd`` (the frozen parity oracle
until the M6 cutover) — docs/60-COMBAT.md §4.4, §4.9a, §4.11.3, §4.11.8,
§4.12.1.1.

``compose_enemy`` builds a §4.11.11 ship-instance array from the battle RNG
— with the §4.4 broadside split written onto every ship — consuming the
RNG in the pinned §4.11.3 order (ship count → hulls → [cannon deal: no
RNG] → [crew/durability: no RNG] → one cargo good per ship). Same seed ⇒
identical fleet.

``decide`` returns the §4.12.1.1 ``{action, target, vel}`` decision dict
(``cell`` is derived by the executor as ``pos + vel``, never authored;
``side`` / ``shot`` ride the cannon decision explicitly per §4.11.8 pin
2). The T2 enemy AI is the §4.9a deterministic greedy priority list —
surrender roll → flee → fire → kite → board ≥ ram → close → hold —
consuming the per-kind profile from ``data/npc_config.json`` ``ai_profiles``
(§4.10, lookup correction 8). Every velocity choice enumerates
``BattleSim.legal_velocities(unit)`` in its (y, x) lexicographic order and
takes the FIRST candidate achieving the objective (§4.11.8 pin 1 — the
enumeration IS the tie-break). Distance math is judged on the §4.3a
sweep's LANDING cell (master W3-gate ruling — the §4.3a sweep can only
shorten a move, never lengthen it).

W4-B order consumption (§4.9b): ``decide`` takes an optional ``order`` —
the FleetCommander five-tuple (+ phase rider) for this ship this round.
Orders are FEED-FORWARD CONSTRAINTS inside the unchanged priority list,
never a replacement for it; the EMPTY order is the free T2,
byte-for-byte. (The order GENERATOR — ``scripts/combat/fleet_commander.gd``
— is another agent's ownership; this module only consumes the pinned
five-tuple shape.)

T3 seam: ``profile.ai_level == 1`` dispatches the §4.9c one-ply lookahead
to ``server.sim.combat.ai_search`` (another agent's module). The import is
the real production path, performed lazily at the dispatch point — the
exact mirror of the oracle's one-way preload arrow that keeps the pair
from closing a cyclic import at parse time (ai_search reaches THIS
module's helpers through a lazy load too). Tests that exercise the
dispatch use ``pytest.importorskip("server.sim.combat.ai_search")`` and
skip cleanly until that module merges.

Every formula that already exists in :mod:`server.sim.combat.battle_sim`
is called, never copied: the AI asks the sim for velocity legality,
per-side arc/range checks, the §4.4b shot rule and the §4.7 surrender
roll.
"""

from __future__ import annotations

import math
import sys
from typing import Any, Final

from server.sim.combat.battle_sim import (
    BROADSIDE_PORT,
    BROADSIDE_STARBOARD,
    BattleSim,
    HEADING_EAST,
    HEADING_RAYS,
    NO_CELL,
    SIDE_ENEMY,
    SIDE_PLAYER,
    MORALE_SURRENDER_GATE,
    bucket_distance,
    bresenham_cells,
    heading8_of,
    in_grid,
    to_cell,
    vel_length,
)

__all__ = [
    "HULL_IDS",
    "CANNON_BUDGET",
    "CANNON_BUDGET_PER_30_DAYS",
    "CARGO_CAPACITY_DIVISOR",
    "SURRENDER_DURABILITY_PERCENT",
    "SURRENDER_PLAYER_RANGE",
    "FLEE_AGGRESSION_MAX",
    "CLOSE_DECELERATION_RANGE",
    "HOOK_SPEED_MAX",
    "RAM_SPEED_MIN",
    "BOARD_DURABILITY_PERCENT",
    "SIDE_MORALE_FLEE",
    "SCREEN_RADIUS",
    "FOCUS_FIRE_AGGRESSION",
    "HEADING_HOLD_BUCKETS",
    "ORDER_PHASE_FORM",
    "ORDER_PHASE_CLOSE",
    "ORDER_PHASE_ENGAGE",
    "ORDER_PHASE_WEAR",
    "ORDER_PHASE_SCREEN",
    "DEFAULT_PROFILE",
    "EMPTY_EQUIPMENT",
    "profile_for",
    "compose_enemy",
    "cannon_budget",
    "decide",
]

# --- Composition constants (docs/60 §4.11.3, §4.11.11.2, §4.11.11.4) -------

#: §4.11.3 step 2: the locked hull order (§4.1 "latin…brigantine").
HULL_IDS: Final[tuple[str, ...]] = ("latin", "sloop", "caravel", "brigantine")

#: §4.11.3 step 3 cannon budgets; the Phase-5 role map replaces the value
#: for its kinds (§4.11.11.2: trader 6 / coaster 2 / courier 0 / patrol 30 /
#: privateer 20 / pirate 20, each ``+ floor(day / 30)``; §4.11.11.4: a
#: treasure fleet arms 30 whole-fleet cannons). Unknown kinds fall back to
#: the pirate budget.
CANNON_BUDGET: Final[dict[str, int]] = {
    "pirate": 20, "navy": 30, "trader": 6, "coaster": 2, "courier": 0,
    "patrol": 30, "privateer": 20, "treasure": 30,
}
CANNON_BUDGET_PER_30_DAYS: Final[int] = 1

#: §4.11.3 step 5 cargo: ``max(1, floor(capacity / 10))`` units of one good.
CARGO_CAPACITY_DIVISOR: Final[int] = 10

#: §4.7 gate half + the retired W3 proximity clause (kept as the doc
#: constants; the Phase-9 gate proper is morale ≤ 20 ∧ durability ≤ 25%).
SURRENDER_DURABILITY_PERCENT: Final[int] = 25
SURRENDER_PLAYER_RANGE: Final[int] = 3

#: §4.9a T2 pins — every non-profile number the priority list needs is one
#: of these or a sim constant.
FLEE_AGGRESSION_MAX: Final[int] = 25        # flee clause: "aggression < 25"
CLOSE_DECELERATION_RANGE: Final[int] = 2    # close clause: "Chebyshev ≤ 2"
HOOK_SPEED_MAX: Final[int] = 1              # the §4.6a hook window: ‖vel‖ ≤ 1
RAM_SPEED_MIN: Final[int] = 2               # ram clause: floor(‖vel‖) ≥ 2
BOARD_DURABILITY_PERCENT: Final[int] = 25   # board clause: "target hp% ≤ 25"

#: W4-B pins: the §4.9a pre-fleet-layer morale flee threshold ("side morale
#: ≤ 20"); the §4.9b flagship screen radius; the engage focus-fire
#: aggression (§4.9b, fleet-commander-owned); the ±1 heading-hold window.
SIDE_MORALE_FLEE: Final[int] = 20
SCREEN_RADIUS: Final[int] = 3
FOCUS_FIRE_AGGRESSION: Final[int] = 80
HEADING_HOLD_BUCKETS: Final[int] = 1

#: §4.9b phase vocabulary the order rider carries (steering dispatch).
ORDER_PHASE_FORM: Final[str] = "form"
ORDER_PHASE_CLOSE: Final[str] = "close"
ORDER_PHASE_ENGAGE: Final[str] = "engage"
ORDER_PHASE_WEAR: Final[str] = "wear"
ORDER_PHASE_SCREEN: Final[str] = "screen"

#: Correction-8 lookup: a ``hunter`` battle reads the ``navy`` row;
#: unknown kinds fall back to the ``pirate`` row.
PROFILE_HUNTER_KIND: Final[str] = "hunter"
PROFILE_NAVY_ROW: Final[str] = "navy"
PROFILE_PIRATE_ROW: Final[str] = "pirate"

#: The empty-safe profile (the §4.10 locked ``pirate`` row verbatim) —
#: returned when the whole ``ai_profiles`` block is missing so headless
#: tools never crash.
DEFAULT_PROFILE: Final[dict[str, Any]] = {
    "kind": "pirate",
    "archetype": "aggressive",
    "aggression": 90,
    "preferred_range": 2,
    "flee_below_hp_pct": 0,
    "focus": "weakest",
    "courage_mod": 5,
    "formation": "swarm",
    "ai_level": 1,
}

#: Per-ship equipment shape of §4.11.11 (both slots empty on spawn).
EMPTY_EQUIPMENT: Final[dict[str, str]] = {"figurehead": "", "sail": ""}


# --- Profiles (docs/60 §4.9a, 10-* §4.10) -------------------------------------


def profile_for(kind: str) -> dict[str, Any]:
    """The §4.9a profile row for a battle kind: ``npc_config.ai_profiles``.
    Correction 8: ``hunter`` reads the ``navy`` row; an unknown kind falls
    back to the ``pirate`` row; a missing config block degrades to
    :data:`DEFAULT_PROFILE`. Pure — no caching, no mutation."""
    resolved = PROFILE_NAVY_ROW if kind == PROFILE_HUNTER_KIND else kind
    config = _npc_config()
    profiles: dict[str, Any] = {}
    if isinstance(config, dict) and isinstance(config.get("ai_profiles", {}), dict):
        profiles = config["ai_profiles"]
    row = profiles.get(resolved, profiles.get(PROFILE_PIRATE_ROW, {}))
    if isinstance(row, dict) and row:
        return dict(row)
    return dict(DEFAULT_PROFILE)


def _npc_config() -> Any:
    from server.sim.data import data
    return data().npc_config


# --- Composition (docs/60 §4.11.3) ----------------------------------------------


def compose_enemy(kind: str, day: int, rng: Any,
                  store: Any = None) -> list[dict[str, Any]]:
    """Builds the enemy fleet exactly per §4.11.3, consuming ``rng`` in the
    pinned order: ship count → hulls → (cannon deal: no RNG) →
    (crew/durability: no RNG) → one cargo good id per ship. Same seed ⇒
    identical fleet."""
    ships: list[dict[str, Any]] = []
    if rng is None:
        print("AiFleet.compose_enemy: rng is null", file=sys.stderr)
        return ships
    count = _ship_count(kind, rng)
    for _index in range(count):
        hull_id = HULL_IDS[rng.randi_range(0, len(HULL_IDS) - 1)]
        ships.append(_base_ship(hull_id, store))
    _deal_cannons(ships, cannon_budget(kind, day), store)
    _write_broadside_split(ships)
    for ship in ships:
        ship["cargo"] = _roll_cargo(ship, rng, store)
    return ships


def _ship_count(kind: str, rng: Any) -> int:
    """§4.11.3 step 1: pirate 1–3, navy 2–4; the Phase-5 warship roles
    share the navy band (§4.11.11.2: ``patrol``/``privateer`` roll 2–4, the
    merchant roles 1–3); a ``treasure`` fleet rolls 3–5 merchants plus one
    escort (§4.11.11.4)."""
    if kind == "treasure":
        return 3 + rng.randi_range(0, 2) + 1
    base = 2 if kind in ("navy", "patrol", "privateer") else 1
    return base + rng.randi_range(0, 2)


def cannon_budget(kind: str, day: int) -> int:
    """§4.11.3 step 3 cannon budget: ``20 + floor(day / 30)`` for pirates,
    ``30 + floor(day / 30)`` for navies (the role map for the rest)."""
    base = int(CANNON_BUDGET.get(kind, CANNON_BUDGET["pirate"]))
    return base + int(math.floor(max(day, 0) / 30.0)) * CANNON_BUDGET_PER_30_DAYS


def _base_ship(hull_id: str, store: Any = None) -> dict[str, Any]:
    """§4.11.3 step 4: ``crew = crew_min``, ``durability = durability``,
    ``provisions = water = 0``, no cannons yet (§4.11.11 instance shape)."""
    from server.sim.data import data
    dst = store if store is not None else data()
    ship_type = dst.get_ship_type(hull_id)
    return {
        "ship_type_id": hull_id,
        "durability": int(ship_type.get("durability", 0)),
        "crew": int(ship_type.get("crew_min", 0)),
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "equipment": dict(EMPTY_EQUIPMENT),
        "cargo": {},
    }


def _deal_cannons(ships: list[dict[str, Any]], budget: int,
                  store: Any = None) -> None:
    """§4.11.3 step 3: one cannon at a time, round-robin in fleet order,
    skipping a hull at its ``armament_slots``, until the budget is
    exhausted or all full. A whole pass that dealt nothing means every hull
    is at its slots — the rest of the budget is dropped."""
    from server.sim.data import data
    dst = store if store is not None else data()
    remaining = max(budget, 0)
    while remaining > 0:
        dealt = 0
        for ship in ships:
            if remaining <= 0:
                break
            slots = int(dst.get_ship_type(
                str(ship.get("ship_type_id", ""))).get("armament_slots", 0))
            if int(ship.get("cannons", 0)) >= slots:
                continue
            ship["cannons"] = int(ship.get("cannons", 0)) + 1
            remaining -= 1
            dealt += 1
        if dealt == 0:
            break


def _write_broadside_split(ships: list[dict[str, Any]]) -> None:
    """§4.4 broadside split (decision 3/14), written at composition:
    ``cannons_port = floor(cannons / 2)``, starboard the rest. The TOTAL
    ``cannons`` is retained on the ship (decision 14)."""
    for ship in ships:
        total = max(int(ship.get("cannons", 0)), 0)
        port = int(math.floor(float(total) / 2.0))
        ship["cannons_port"] = port
        ship["cannons_starboard"] = total - port


def _roll_cargo(ship: dict[str, Any], rng: Any,
                store: Any = None) -> dict[str, int]:
    """§4.11.3 step 5: ``max(1, floor(capacity / 10))`` units of one
    uniformly rolled good id (the 20 locked goods)."""
    from server.sim.data import data
    dst = store if store is not None else data()
    capacity = int(dst.get_ship_type(
        str(ship.get("ship_type_id", ""))).get("capacity", 0))
    quantity = max(1, int(math.floor(float(capacity) / CARGO_CAPACITY_DIVISOR)))
    goods = dst.goods_list
    if not goods:
        return {}
    index = rng.randi_range(0, len(goods) - 1)
    good_id = str(goods[index].get("id", "")) if isinstance(goods[index], dict) else ""
    if not good_id:
        return {}
    return {good_id: quantity}


# --- Decisions (docs/60 §4.9a, §4.11.8) ------------------------------------------


def decide(sim: BattleSim, unit: dict[str, Any], order: dict[str, Any] | None = None,
           profile_override: dict[str, Any] | None = None) -> dict[str, Any]:
    """The §4.9a T2 priority list, top-down first match: ① surrender roll
    ② flee ③ fire ④ kite ⑤ board ≥ ram ⑥ close ⑦ hold. Returns the
    §4.12.1.1 decision dict. Deterministic and pure — the only RNG is the
    sim's own §4.7 roll stream.

    ``order`` (default empty) is the §4.9b five-tuple + phase rider from
    ``FleetCommander.generate_orders`` for this ship this round; it
    constrains candidate sets and targets INSIDE the unchanged list. The
    empty order reproduces the free T2 exactly. ``profile_override`` (the
    S21 ai_level/archetype seam, W5-C) merges over the profile key-by-key.
    """
    order = order or {}
    profile_override = profile_override or {}
    hold: dict[str, Any] = {"action": "hold", "target": {}, "vel": (0, 0)}
    if sim is None or not isinstance(unit, dict) or not bool(unit.get("alive", False)):
        return hold
    player_ships = sim.living_units(SIDE_PLAYER)
    if not player_ships:
        return hold

    # The §4.9a row (§4.10 lookup, correction 8), merged with the caller
    # override so the sandbox overrides reach every consumer below.
    profile = profile_for(str(sim.enemy_kind))
    if profile_override:
        profile = {**profile, **profile_override}
    courage_mod = int(profile.get("courage_mod", 0))
    own_ship: dict[str, Any] = unit.get("ship", {})
    max_durability = sim.effective_max_durability(own_ship)
    origin = sim.unit_cell(unit)
    nearest = _nearest(sim, player_ships, origin)
    nearest_cell = sim.unit_cell(nearest["unit"])
    distance = int(nearest["distance"])
    legal: list[tuple[int, int]] = sim.legal_velocities(unit)

    # W4-B order decode. The empty order leaves every constraint inert.
    has_order = bool(order)
    phase = str(order.get("phase", ""))
    station = to_cell(order.get("station", NO_CELL))
    assigned = int(order.get("assigned_target", -1)) if has_order else -1
    discipline = has_order and bool(order.get("discipline", False))
    band_lo = 0
    band_hi = 0
    band_ok = False
    band = order.get("desired_speed_band")
    if has_order and isinstance(band, list) and len(band) >= 2:
        band_lo = int(band[0])
        band_hi = int(band[1])
        band_ok = True
    # §4.9b hard constraint: `discipline` removes off-station candidates —
    # picks whose §4.3a landing WORSENS the Chebyshev deviation to the
    # station — from the consideration set before every objective ranking
    # (hold-in-place landings survive; the ship never willingly drifts).
    considered: list[tuple[int, int]] = legal
    if discipline and station != NO_CELL:
        considered = [vel for vel in legal
                      if _keeps_station(sim, unit, origin, vel, station)]

    # ① §4.7/§4.8a surrender roll: SIDE morale ≤ 20 AND the ship at
    #    ≤ 25 % max durability. The chance is the sim's §4.7 roll with the
    #    profile `courage_mod` folded in plus the morale modifier; a failed
    #    roll re-rolls next turn. Orders never touch this priority.
    side_morale = sim.side_morale(SIDE_ENEMY)
    if (max_durability > 0
            and int(own_ship.get("durability", 0)) * 100
            <= SURRENDER_DURABILITY_PERCENT * max_durability
            and side_morale <= MORALE_SURRENDER_GATE):
        if sim.roll_surrender(unit, courage_mod, side_morale):
            return {"action": "surrender", "target": {}, "vel": (0, 0)}

    # ② §4.9a flee: hp% below the profile gate, or aggression < 25, or —
    #    the §4.9a pre-fleet-layer widening — side morale ≤ 20. The first
    #    legal velocity strictly increasing the Chebyshev distance to the
    #    nearest player ship, judged on the sweep's landing cell; hold when
    #    none — a cornered fleer does not fall through to the guns.
    flee_hp = int(profile.get("flee_below_hp_pct", 0))
    wants_flee = (max_durability > 0
                  and int(own_ship.get("durability", 0)) * 100 < flee_hp * max_durability)
    if int(profile.get("aggression", 0)) < FLEE_AGGRESSION_MAX:
        wants_flee = True
    if not wants_flee:
        morale = sim.side_morale(SIDE_ENEMY)
        if 0 <= morale <= SIDE_MORALE_FLEE:
            wants_flee = True
    if wants_flee:
        for vel in considered:
            if _chebyshev(_landing(sim, unit, origin, vel), nearest_cell) > distance:
                return {"action": "move", "target": {}, "vel": vel}
        return hold

    # ②→T3 §4.9c dispatch: `ai_level = 1` ranks the remaining candidates ③+
    #    with the one-ply search — θ from the profile `archetype` (§4.9c
    #    mapping), the §4.9b order consumed inside the search. The hard-rule
    #    layer above (① surrender roll, ② flee) is level-agnostic: it fired
    #    BEFORE this dispatch for both levels. The import is the real
    #    production path, performed lazily at the dispatch point (the
    #    oracle's one-way preload arrow — no parse-time cycle).
    if int(profile.get("ai_level", 0)) == 1:
        from server.sim.combat.ai_search import decide as ai_search_decide
        from server.sim.combat.ai_search import theta_for
        return ai_search_decide(
            sim, unit, theta_for(str(profile.get("archetype", "balanced"))), order)

    # ③ §4.11.8 pin 2 fire: rake preference → profile focus → loaded side
    #    with more cannons (tie → port); the shot type is the §4.4b rule's.
    #    W4-B: `assigned_target ≥ 0` restricts the ranking to that player
    #    ship (free ranking only when the assignment is dead/absent).
    fire = _fire_decision(sim, unit, profile, player_ships, assigned)
    if fire:
        return fire

    # ③½ §4.9b engage/wear steering: develop the broadside bucket. While
    #    the ship is outside the desired_heading8 ±1 window the maneuver
    #    outranks the remaining priorities; once inside the window the list
    #    resumes below.
    if has_order and phase in (ORDER_PHASE_ENGAGE, ORDER_PHASE_WEAR):
        desired = int(order.get("desired_heading8", 0)) % len(HEADING_RAYS)
        if bucket_distance(int(unit.get("heading8", 0)) % len(HEADING_RAYS),
                           desired) > HEADING_HOLD_BUCKETS:
            turn = _heading_hold_step(sim, unit, considered, station, desired, nearest_cell)
            if turn != NO_CELL:
                return {"action": "move", "target": {}, "vel": turn}

    # ④ §4.9a kite: both broadside reload windows active → steer so the
    #    resulting Chebyshev distance (the landing cell) meets the profile
    #    `preferred_range` (§4.11.8 pin 3). Ordered engage/wear ships yield
    #    this step to ③½.
    round_no = sim.round_number()
    if (round_no < int(unit.get("reload_port", 1))
            and round_no < int(unit.get("reload_starboard", 1))
            and not (has_order and phase in (ORDER_PHASE_ENGAGE, ORDER_PHASE_WEAR))):
        kite = _kite_step(sim, unit, considered, nearest,
                          int(profile.get("preferred_range", 0)))
        if kite != NO_CELL:
            return {"action": "move", "target": {}, "vel": kite}

    # ⑤ Board ranks above ram (decision 13). Board: the §4.6a hook legal
    #    AND (own crew + duel rating > the target's OR target hp% ≤ 25).
    #    Ram: floor(‖vel‖) ≥ 2 possible AND own cannons + duel rating > the
    #    target's — delivered either as the adjacent-action ram or as the
    #    first legal velocity whose §4.3a sweep enters the target (the
    #    sweep IS the §4.5 ram; authoring it as a move keeps the executor
    #    from re-striking a ram survivor).
    boarding = _boarding_target(sim, unit, player_ships)
    if boarding:
        return {"action": "board", "target": boarding, "vel": (0, 0)}
    ram_move = _ram_decision(sim, unit, considered, player_ships)
    if ram_move:
        return ram_move

    # ⑥ §4.9b-ordered steering: form/close/engage/wear close onto the
    #    order's `station` (speed band as a first-stage preference); screen
    #    orders close on the nearest enemy while preferring landings inside
    #    the flagship's Chebyshev SCREEN_RADIUS. An ordered ship with no
    #    surviving candidate holds — it never falls back to the free close.
    phase_is_ordered = (has_order and station != NO_CELL
                        and phase in (ORDER_PHASE_FORM, ORDER_PHASE_CLOSE,
                                      ORDER_PHASE_ENGAGE, ORDER_PHASE_WEAR,
                                      ORDER_PHASE_SCREEN))
    if phase_is_ordered:
        if phase == ORDER_PHASE_SCREEN:
            ordered = _screen_close_step(sim, unit, considered, station, nearest)
        else:
            ordered = _station_step(sim, unit, considered, station,
                                    band_lo, band_hi, band_ok)
        if ordered != NO_CELL:
            return {"action": "move", "target": {}, "vel": ordered}
        return hold

    # ⑥ §4.9a close: the first legal velocity minimizing the resulting
    #    Chebyshev distance to the nearest player ship, decelerating to
    #    ‖vel‖ ≤ 1 at Chebyshev ≤ 2 so the §4.6a hook window opens. Also
    #    the swarm/break-order steering leg.
    step = _close_step(sim, unit, legal, nearest)
    if step != NO_CELL:
        return {"action": "move", "target": {}, "vel": step}

    # ⑦ Hold.
    return hold


def _fire_decision(sim: BattleSim, unit: dict[str, Any], profile: dict[str, Any],
                   player_ships: list[dict[str, Any]], assigned: int = -1) -> dict[str, Any]:
    """§4.11.8 pin 2 fire pick among the loaded-side/target pairs: a
    rake-position volley beats a non-rake, then the profile ``focus`` picks
    the target, then the loaded side with more cannons, tie → port (the
    side array visits port first and only a strictly larger count replaces
    it). The shot type comes from ``sim.ai_shot_type`` — the §4.4b rule,
    never a second copy. ``{}`` when no loaded side has a target in arc and
    range. ``assigned ≥ 0`` restricts the candidate pool to that player
    fleet index (§4.9b engage assignment); an assignment that is
    dead/absent falls back to the free ranking."""
    origin = sim.unit_cell(unit)
    pairs: list[dict[str, Any]] = []  # {target, side, rake} — target-major, port first
    for target in player_ships:
        rake = _is_rake_on(sim.unit_cell(target),
                           int(target.get("heading8", HEADING_EAST)), origin)
        for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
            if sim.can_cannon(unit, target, side):
                pairs.append({"target": target, "side": side, "rake": rake})
    if not pairs:
        return {}
    if assigned >= 0:
        restricted = [pair for pair in pairs
                      if int(pair["target"]["index"]) == assigned]
        if restricted:
            pairs = restricted
        elif _has_fleet_index(player_ships, assigned):
            return {}  # assigned and alive, but no fireable geometry: hold fire
        # dead/absent assignment → free ranking (the §4.9b fallback)
    # Rake preference: raked volleys confine the candidate pool when any exist.
    raked = [pair for pair in pairs if bool(pair["rake"])]
    pool = raked if raked else pairs
    # The focus pick runs over the pool's targets (fleet-index order).
    candidates: list[dict[str, Any]] = []
    for pair in pool:
        if not any(pair["target"] is c for c in candidates):
            candidates.append(pair["target"])
    target = _focus_target(profile, unit, candidates, sim)
    if not target:
        return {}
    # Side choice: the loaded side with more cannons, tie → port.
    side = ""
    cannons = -1
    for pair in pool:
        if pair["target"] is target:
            count = sim.side_cannons(unit, str(pair["side"]))
            if not side or count > cannons:
                side = str(pair["side"])
                cannons = count
    return {
        "action": "cannon",
        "target": target,
        "side": side,
        "shot": sim.ai_shot_type(unit, target),
        "vel": (0, 0),
    }


def _focus_target(profile: dict[str, Any], unit: dict[str, Any],
                  candidates: list[dict[str, Any]], sim: BattleSim) -> dict[str, Any]:
    """§4.11.8 pin 2's focus ordering: ``weakest`` = lowest current
    durability, ``nearest`` = minimum Chebyshev (ties → the lower fleet
    index — candidates arrive in fleet-index order and only a strict win
    replaces the holder); ``flagship`` = player index 0, falling back to
    ``weakest`` while the flagship is sunk. ``{}`` for an empty list."""
    if not candidates:
        return {}
    focus = str(profile.get("focus", "weakest"))
    if focus == "flagship":
        for candidate in candidates:
            if int(candidate["index"]) == 0:
                return candidate
    if focus == "nearest":
        origin = sim.unit_cell(unit)
        best: dict[str, Any] = {}
        best_distance = 0
        for candidate in candidates:
            current = _chebyshev(origin, sim.unit_cell(candidate))
            if not best or current < best_distance:
                best = candidate
                best_distance = current
        return best
    return _lowest_durability(candidates)


def _landing(sim: BattleSim, unit: dict[str, Any], origin: tuple[int, int],
             vel: tuple[int, int]) -> tuple[int, int]:
    """The cell the §4.3a sweep actually reaches for ``vel`` from ``origin``:
    the Bresenham walk (the engine's own generator, so the preview is
    exact) stops at the first out-of-grid or occupied cell and the ship
    stays at the PRIOR cell in both cases. Every §4.9a velocity pick is
    judged on this landing cell (master W3-gate ruling)."""
    target = (origin[0] + vel[0], origin[1] + vel[1])
    if target == origin:
        return origin
    occupied: set[tuple[int, int]] = set()
    for other in sim.units():
        if other is unit or not bool(other.get("alive", False)):
            continue
        occupied.add(sim.unit_cell(other))
    prior = origin
    for cell in bresenham_cells(origin, target):
        if not in_grid(cell) or cell in occupied:
            return prior
        prior = cell
    return prior


def _kite_step(sim: BattleSim, unit: dict[str, Any], legal: list[tuple[int, int]],
               nearest: dict[str, Any], preferred_range: int) -> tuple[int, int]:
    """§4.11.8 pin 3 kite step: the FIRST legal velocity whose resulting
    Chebyshev distance (the landing cell) to the nearest player ship equals
    ``preferred_range``; if none achieves it exactly, the first minimizing
    ``|distance − preferred_range|``. ``NO_CELL`` when no velocity exists."""
    if not legal:
        return NO_CELL
    origin = sim.unit_cell(unit)
    target_cell = sim.unit_cell(nearest["unit"])
    best: tuple[int, int] = NO_CELL
    best_gap = 0
    for vel in legal:
        gap = abs(_chebyshev(_landing(sim, unit, origin, vel), target_cell)
                  - preferred_range)
        if best == NO_CELL or gap < best_gap:
            best = vel
            best_gap = gap
            if gap == 0:
                break  # first exact hit wins (§4.11.8 pin 1)
    return best


def _boarding_target(sim: BattleSim, unit: dict[str, Any],
                     player_ships: list[dict[str, Any]]) -> dict[str, Any]:
    """§4.11.8 pin 4's board candidate: the first (fleet-index order)
    player ship the §4.6a hook allows AND (own crew + duel rating > the
    target's OR the target's durability ≤ 25% max). ``{}`` when none."""
    own_rating = int(unit.get("crew", 0)) + int(unit.get("captain_rating", 0))
    for target in player_ships:
        if not sim.can_board(unit, target):
            continue
        theirs = int(target.get("crew", 0)) + int(target.get("captain_rating", 0))
        if own_rating > theirs:
            return target
        ship: dict[str, Any] = target.get("ship", {})
        max_durability = sim.effective_max_durability(ship)
        if (max_durability > 0
                and int(ship.get("durability", 0)) * 100
                <= BOARD_DURABILITY_PERCENT * max_durability):
            return target
    return {}


def _ram_decision(sim: BattleSim, unit: dict[str, Any],
                  legal: list[tuple[int, int]],
                  player_ships: list[dict[str, Any]]) -> dict[str, Any]:
    """§4.11.8 pin 4's ram decision: ``floor(‖vel‖) ≥ 2`` must be reachable
    at all (the gate), own cannons + duel rating > the target's, then per
    target in fleet-index order either the §4.5 adjacent-action ram
    (``can_ram``) or the first legal velocity whose §4.3a sweep enters the
    target — authored as a ``move``, because the sweep itself resolves the
    ram and a follow-up ``ram`` action would strike a survivor twice. The
    adjacent-action ram OMITS ``vel`` — no movement phase, the retained
    closing velocity prices the §4.5 impact. ``{}`` when nothing rams."""
    capable = any(int(math.floor(vel_length(vel))) >= RAM_SPEED_MIN for vel in legal)
    if not capable:
        return {}
    own_ship: dict[str, Any] = unit.get("ship", {})
    own_rating = int(own_ship.get("cannons", 0)) + int(unit.get("captain_rating", 0))
    origin = sim.unit_cell(unit)
    for target in player_ships:
        ship: dict[str, Any] = target.get("ship", {})
        theirs = int(ship.get("cannons", 0)) + int(target.get("captain_rating", 0))
        if own_rating <= theirs:
            continue
        if sim.can_ram(unit, target):
            return {"action": "ram", "target": target}
        target_cell = sim.unit_cell(target)
        for vel in legal:
            if _sweep_enters(sim, unit, origin, vel, target_cell):
                return {"action": "move", "target": {}, "vel": vel}
    return {}


def _close_step(sim: BattleSim, unit: dict[str, Any], legal: list[tuple[int, int]],
                nearest: dict[str, Any]) -> tuple[int, int]:
    """§4.9a close step: the first legal velocity minimizing the resulting
    Chebyshev distance (the landing cell) to the nearest player ship
    (§4.11.8 pin 1 — enumeration order is the tie-break). At Chebyshev ≤ 2
    the §4.9a deceleration takes precedence: the first ``‖vel‖ ≤ 1`` pick
    that does not increase the distance, so the §4.6a hook window opens.
    ``NO_CELL`` when no velocity exists at all."""
    if not legal:
        return NO_CELL
    origin = sim.unit_cell(unit)
    target_cell = sim.unit_cell(nearest["unit"])
    distance = int(nearest["distance"])
    if distance <= CLOSE_DECELERATION_RANGE:
        for vel in legal:
            if (vel_length(vel) <= float(HOOK_SPEED_MAX)
                    and _chebyshev(_landing(sim, unit, origin, vel), target_cell) <= distance):
                return vel
    best: tuple[int, int] = NO_CELL
    best_distance = 0
    for vel in legal:
        current = _chebyshev(_landing(sim, unit, origin, vel), target_cell)
        if best == NO_CELL or current < best_distance:
            best = vel
            best_distance = current
    return best


def _keeps_station(sim: BattleSim, unit: dict[str, Any], origin: tuple[int, int],
                   vel: tuple[int, int], station: tuple[int, int]) -> bool:
    """W4-B §4.9b discipline test for one candidate: its §4.3a landing cell
    must not WORSEN the Chebyshev deviation to the station."""
    return (_chebyshev(_landing(sim, unit, origin, vel), station)
            <= _chebyshev(origin, station))


def _heading_hold_step(sim: BattleSim, unit: dict[str, Any],
                       candidates: list[tuple[int, int]], station: tuple[int, int],
                       desired: int, enemy_cell: tuple[int, int]) -> tuple[int, int]:
    """W4-B §4.9b engage/wear steering step: the first candidate achieving
    the best lexicographic objective (§4.11.8 pin 1 — enumeration is the
    tie-break): ① heading-bucket gap to ``desired`` (a (0,0) pick keeps the
    current heading), ② arc penalty — 0 when the landing cell + landing
    heading keep the nearest enemy in a fireable broadside arc, ③ station
    deviation (skipped without a station). All landings judged through
    ``_landing``."""
    if not candidates:
        return NO_CELL
    origin = sim.unit_cell(unit)
    current = int(unit.get("heading8", 0)) % len(HEADING_RAYS)
    best: tuple[int, int] = NO_CELL
    best_gap = 0
    best_arc = 0
    best_dev = 0
    for vel in candidates:
        landing = _landing(sim, unit, origin, vel)
        heading = (current if vel == (0, 0)
                   else heading8_of(vel) % len(HEADING_RAYS))
        gap = bucket_distance(heading, desired)
        arc = 0 if _bearing_in_arc(landing, heading, enemy_cell) else 1
        dev = _chebyshev(landing, station) if station != NO_CELL else 0
        if (best == NO_CELL or gap < best_gap
                or (gap == best_gap and arc < best_arc)
                or (gap == best_gap and arc == best_arc and dev < best_dev)):
            best = vel
            best_gap = gap
            best_arc = arc
            best_dev = dev
    return best


def _bearing_in_arc(from_cell: tuple[int, int], heading: int,
                    to_cell: tuple[int, int]) -> bool:
    """Whether a ship at ``from_cell`` facing ``heading`` has ``to_cell`` in
    a fireable broadside arc: the §4.4 arcs are the SIGNED counterclockwise
    steps off the heading — port {1,2,3} ∪ starboard {5,6,7} — i.e. neither
    dead-ahead (0) nor dead-astern (4)."""
    if from_cell == to_cell:
        return False
    bearing = heading8_of((to_cell[0] - from_cell[0], to_cell[1] - from_cell[1])) % 8
    steps = (bearing - heading % 8) % 8
    return steps != 0 and steps != 4


def _station_step(sim: BattleSim, unit: dict[str, Any],
                  candidates: list[tuple[int, int]], station: tuple[int, int],
                  band_lo: int, band_hi: int, band_ok: bool) -> tuple[int, int]:
    """W4-B §4.9b ordered ⑥: the first candidate minimizing the
    landing-cell Chebyshev distance to the order's ``station``, preferring
    in-band magnitudes (``desired_speed_band``) as a first-stage pool — a
    preference, never a filter (an empty in-band pool falls back to all
    candidates). No §4.9a hook deceleration — stations are not hook
    windows."""
    if not candidates:
        return NO_CELL
    pool = candidates
    if band_ok:
        in_band = [vel for vel in candidates
                   if float(band_lo) <= vel_length(vel) <= float(band_hi)]
        if in_band:
            pool = in_band
    origin = sim.unit_cell(unit)
    best: tuple[int, int] = NO_CELL
    best_distance = 0
    for vel in pool:
        distance = _chebyshev(_landing(sim, unit, origin, vel), station)
        if best == NO_CELL or distance < best_distance:
            best = vel
            best_distance = distance
    return best


def _screen_close_step(sim: BattleSim, unit: dict[str, Any],
                       candidates: list[tuple[int, int]], station: tuple[int, int],
                       nearest: dict[str, Any]) -> tuple[int, int]:
    """W4-B §4.9b screen ⑥: close on the nearest enemy while preferring
    landings within the §4.9b flagship screen radius (Chebyshev
    SCREEN_RADIUS of ``station``). Objective: (outside-radius penalty,
    resulting distance to the enemy), first-best by enumeration. ``NO_CELL``
    only when no candidate exists."""
    if not candidates:
        return NO_CELL
    origin = sim.unit_cell(unit)
    target_cell = sim.unit_cell(nearest["unit"])
    best: tuple[int, int] = NO_CELL
    best_outside = 0
    best_distance = 0
    for vel in candidates:
        landing = _landing(sim, unit, origin, vel)
        outside = 0 if _chebyshev(landing, station) <= SCREEN_RADIUS else 1
        distance = _chebyshev(landing, target_cell)
        if (best == NO_CELL or outside < best_outside
                or (outside == best_outside and distance < best_distance)):
            best = vel
            best_outside = outside
            best_distance = distance
    return best


def _has_fleet_index(player_ships: list[dict[str, Any]], index: int) -> bool:
    """Whether ``player_ships`` (living, fleet-index order) carries ``index``."""
    return any(int(ship.get("index", -1)) == index for ship in player_ships)


def _lowest_durability(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    """§4.11.8 rule 2's weakest fallback: lowest current durability, ties
    to the lower fleet index (candidates arrive in fleet-index order)."""
    best: dict[str, Any] = {}
    best_durability = 0
    for candidate in candidates:
        ship = candidate.get("ship", {})
        durability = int(ship.get("durability", 0)) if isinstance(ship, dict) else 0
        if not best or durability < best_durability:
            best = candidate
            best_durability = durability
    return best


def _nearest(sim: BattleSim, player_ships: list[dict[str, Any]],
             from_cell: tuple[int, int]) -> dict[str, Any]:
    """The nearest player ship by Chebyshev distance, ties to the lower
    fleet index, with the unit and distance attached."""
    best: dict[str, Any] = {}
    best_distance = 0
    for ship in player_ships:
        distance = _chebyshev(from_cell, sim.unit_cell(ship))
        if (not best or distance < best_distance
                or (distance == best_distance
                    and int(ship["index"]) < int(best["unit"]["index"]))):
            best = {"unit": ship, "distance": distance}
            best_distance = distance
    return best


def _is_rake_on(target_cell: tuple[int, int], target_heading: int,
                attacker_cell: tuple[int, int]) -> bool:
    """§4.4 rake, recomputed with the sim's own statics because the
    engine's predicate is private: the bearing bucket from TARGET to
    ATTACKER relative to the TARGET's heading8 ∈ {0°, 180°} — the shot
    runs the target's deck line. Side-independent."""
    bearing = heading8_of((attacker_cell[0] - target_cell[0],
                           attacker_cell[1] - target_cell[1]))
    steps = bucket_distance(bearing, target_heading)
    return steps == 0 or steps == 4


def _sweep_enters(sim: BattleSim, unit: dict[str, Any], from_cell: tuple[int, int],
                  vel: tuple[int, int], target_cell: tuple[int, int]) -> bool:
    """Whether the §4.3a sweep of ``vel`` from ``from_cell`` would enter
    ``target_cell``: the walk stops at the first out-of-bounds or occupied
    cell, and the §4.5 sweep ram fires only when THAT first occupant is
    the target. A pure preview over public reads — the executor re-resolves
    the real sweep."""
    for cell in bresenham_cells(from_cell, (from_cell[0] + vel[0], from_cell[1] + vel[1])):
        if not in_grid(cell):
            return False
        for other in sim.units():
            if other is unit or not bool(other.get("alive", False)):
                continue
            if sim.unit_cell(other) == cell:
                return sim.unit_cell(other) == target_cell
    return False


def _chebyshev(a: tuple[int, int], b: tuple[int, int]) -> int:
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))
