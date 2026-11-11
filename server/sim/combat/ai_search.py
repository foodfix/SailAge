"""server.sim.combat.ai_search — the §4.9c T3 one-ply lookahead (M1).

Python port of ``scripts/combat/ai_search.gd`` (the frozen parity oracle
until the M6 cutover) — docs/60-COMBAT.md §4.9c (normative φ table), §4.9a,
§4.9b, §4.4b, §4.11.8.

``ai_level = 1`` ships decide by enumerating every legal velocity
(:meth:`BattleSim.legal_velocities`, the §4.3a (y, x) lexicographic order)
× the candidate action set {steer/hold, cannon per loaded side, ram, board}
on the live sim behind :meth:`BattleSim.snapshot` / :meth:`BattleSim.restore`,
scoring each applied candidate with ``score = θ·φ`` over NINE integer
features and returning the FIRST maximum (the enumeration order IS the
tie-break — §4.11.8 pin 1).

ZERO DICE by construction: a candidate's application (velocity + cannon /
ram / board) draws from the §4.11.1 stream exactly as a real turn would —
but every candidate starts from ``restore(snapshot)`` and ``restore()`` puts
``rng.state`` back (§4.12.1), so the search leaves the sim byte-identical to
its pre-search state. The search never rolls a decision, never logs, never
persists: the executor replays the winning decision through the ordinary
§4.3 turn seam and the dice (if any) fall there.

The hard-rule layer STAYS OUTSIDE this file (§4.9c amendment): the §4.9a
① surrender roll and ② flee rule fire before the dispatch for BOTH AI
levels; this module ranks the remaining candidates ③+ (fire / board ≥ ram /
steering). The shot type is NEVER an enumerated dimension (§4.4b, decision
4): a cannon candidate derives it from :meth:`BattleSim.ai_shot_type` at
application time, exactly as the executor will.

Reuse rule (never a second copy): the §4.9a profile row, the §4.11.8 focus
ordering, the board gate, the rake predicate, the nearest-enemy pick and the
Chebyshev helper all come from :mod:`server.sim.combat.ai_fleet` — imported
here as a module and reached through its functions. (The oracle needs a lazy
``load()`` only because GDScript preloads close a cyclic-preload loop; the
Python import is one-way — ``ai_fleet`` imports this module lazily at its
dispatch point — so a plain module import is cycle-free.)
"""

from __future__ import annotations

import math
from typing import Any, Final, Sequence

from server.sim.combat import ai_fleet
from server.sim.combat.battle_sim import (
    ARC_PORT_STEPS,
    ARC_STARBOARD_STEPS,
    BROADSIDE_PORT,
    BROADSIDE_STARBOARD,
    CANNON_RANGE_MAX,
    CANNON_RANGE_MIN,
    HEADING_EAST,
    HEADING_RAYS,
    NO_CELL,
    SIDE_ENEMY,
    SIDE_PLAYER,
    BattleSim,
    Cell,
    bucket_distance,
    heading8_of,
    to_cell,
    vel_length,
)

__all__ = [
    "THETA_AGGRESSIVE",
    "THETA_BALANCED",
    "THETA_CAUTIOUS",
    "ARCHETYPE_AGGRESSIVE",
    "ARCHETYPE_BALANCED",
    "ARCHETYPE_CAUTIOUS",
    "DURABILITY_DIFF_DIVISOR",
    "CANNON_DIFF_DIVISOR",
    "FLAGSHIP_LOW_DURABILITY_PERCENT",
    "BLOCKED_LANE_CHEBYSHEV",
    "BLOCKED_LANE_MIN_CELLS",
    "BLOCKED_LANE_MAX_CELLS",
    "ALIGNMENT_MAX",
    "theta_for",
    "decide",
]

# --- θ (docs/60-* §4.9c; correction 11) --------------------------------------
#
#: The §4.9c FINAL θ (θ-finalization task, 2026-11-04): the offline CEM run
#: (``tools/battle_tune.py``, W5-B; the report lives in
#: ``docs/IMPLEMENT-Phase9.md`` — W5 "θ-finalization" block: 94,752 battles,
#: stdlib CEM on the correction-14/15 pacing, frozen 64+64 seed table,
#: side-swapped CRN; learning gain +22.3 / +12.9 / +12.5 pp, perturbation
#: ≤ 1.6 pp, distinctness distance gap 1.06 ≥ 1 and flee gap 42.2 pp ≥ 10).
#: These integers are VERBATIM copies of the CEM output — never re-tune,
#: never re-derive. The doc-first prior ``{10, 4, 2, 3, −5, −6, −2, −4, 2}``
#: stays recorded in §4.9c as the historical init. Position i weights
#: feature φ(i+1); these constants are the runtime's ONLY θ source.
THETA_AGGRESSIVE: Final[tuple[int, ...]] = (8, 4, 6, -6, -2, -3, -3, -8, 7)
THETA_BALANCED: Final[tuple[int, ...]] = (6, 5, 7, -2, -3, -3, -5, -9, 6)
THETA_CAUTIOUS: Final[tuple[int, ...]] = (10, 7, 2, -9, -2, -3, -6, -10, 3)

#: §4.9c archetype vocabulary: pirate/privateer rows carry ``aggressive``,
#: patrol/navy/tournament ``balanced``, treasure/trader/coaster/courier
#: ``cautious``; an unknown archetype reads balanced (the middle row).
ARCHETYPE_AGGRESSIVE: Final[str] = "aggressive"
ARCHETYPE_BALANCED: Final[str] = "balanced"
ARCHETYPE_CAUTIOUS: Final[str] = "cautious"

#: The §4.9c feature-table integers (the φ formulas' own numbers):
#: φ1 divides the durability difference by 20, φ2 the cannon difference by 4,
#: φ6's flagship term reads ≤ 25 % of the effective max durability
#: (the §4.11.8 percentage family), φ8 counts blockers within Chebyshev 3
#: (the cannon range family) at 1..3 cells along the heading-ray, and φ9
#: saturates the alignment at 4 buckets (the ``bucket_distance`` maximum).
DURABILITY_DIFF_DIVISOR: Final[int] = 20
CANNON_DIFF_DIVISOR: Final[int] = 4
FLAGSHIP_LOW_DURABILITY_PERCENT: Final[int] = 25
BLOCKED_LANE_CHEBYSHEV: Final[int] = 3
BLOCKED_LANE_MIN_CELLS: Final[int] = 1
BLOCKED_LANE_MAX_CELLS: Final[int] = 3
ALIGNMENT_MAX: Final[int] = 4


def theta_for(archetype: str) -> list[int]:
    """The §4.9c θ weight array for ``archetype`` (the §4.10 mapping).

    Returns a fresh list so a caller can never mutate the module constants
    (the oracle returns its ``const`` array; the values are what matters).
    """
    if archetype == ARCHETYPE_AGGRESSIVE:
        return list(THETA_AGGRESSIVE)
    if archetype == ARCHETYPE_CAUTIOUS:
        return list(THETA_CAUTIOUS)
    return list(THETA_BALANCED)


# --- The search (docs/60-* §4.9c) --------------------------------------------


def decide(sim: BattleSim, unit: dict[str, Any], theta: Sequence[int],
           order: dict[str, Any] | None = None) -> dict[str, Any]:
    """The T3 one-ply search for ``unit``'s turn (§4.9c).

    ``theta`` is the §4.9c integer 9-array for the ship's archetype;
    ``order`` is the §4.9b five-tuple + phase rider (``None``/``{}`` = the
    free T3 — no discipline, no station term). Returns the §4.12.1.1
    decision dict (``cell`` is derived by the executor, never authored;
    ``side`` / ``shot`` ride the cannon winner explicitly). An empty
    candidate set ⇒ hold.

    Candidate enumeration: velocities in ``legal_velocities`` order; within
    a velocity the actions rank steer/hold → cannon-port →
    cannon-starboard → ram → board. The FIRST strictly-greater score wins;
    ties keep the earlier candidate. ``discipline = true`` (with a station)
    removes off-station velocity candidates OUTRIGHT before the action
    pairing (§4.9b's keeps-station test, judged on the §4.3a sweep's real
    landing — the candidate IS applied on the sim, so the landing is the
    engine's own).
    """
    order = order or {}
    hold: dict[str, Any] = {"action": "hold", "target": {}, "vel": (0, 0)}
    if sim is None or not theta or not isinstance(unit, dict) \
            or not bool(unit.get("alive", False)):
        return hold
    my_side = str(unit.get("side", ""))
    their_side = SIDE_PLAYER if my_side == SIDE_ENEMY else SIDE_ENEMY
    foes = sim.living_units(their_side)
    if not foes:
        return hold
    profile = ai_fleet.profile_for(str(sim.enemy_kind))
    origin = sim.unit_cell(unit)
    legal = sim.legal_velocities(unit)
    if not legal:
        return hold

    # W4-B order decode (the empty order = the free T3).
    has_order = bool(order)
    phase = str(order.get("phase", ""))
    station = to_cell(order.get("station", NO_CELL))
    discipline = (has_order and bool(order.get("discipline", False))
                  and station != NO_CELL)
    # §4.9b engage assignment: ``-1``/absent = free ranking (the T2
    # consumer's exact fallback semantics).
    assigned_target = int(order.get("assigned_target", -1)) if has_order else -1
    # φ7's station exists for the §4.9b line phases only (form/close/engage/
    # wear — screen/swarm/break carry no station term).
    station_valid = (
        has_order and station != NO_CELL
        and phase in (ai_fleet.ORDER_PHASE_FORM, ai_fleet.ORDER_PHASE_CLOSE,
                      ai_fleet.ORDER_PHASE_ENGAGE, ai_fleet.ORDER_PHASE_WEAR))

    # Move-invariant gates, priced once (§4.11.8 pin 4's ram capability:
    # floor(‖vel‖) ≥ 2 must be reachable at all) and the move-invariant half
    # of the cannon candidates (a side loaded at the turn's start — reload
    # does not move).
    ram_capable = any(
        int(math.floor(vel_length(vel))) >= ai_fleet.RAM_SPEED_MIN
        for vel in legal)
    round_no = sim.round_number()
    fire_sides = [side for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD)
                  if _side_loaded(sim, unit, side, round_no)]

    pre = sim.snapshot()
    best_score = 0
    best: dict[str, Any] = {}
    first = True

    for vel in legal:
        # --- steer/hold: the velocity with no action. ----------------------
        sim.restore(pre)
        sim.apply_velocity(unit, vel)
        landing = sim.unit_cell(unit)
        # §4.9c discipline removal — off-station velocities leave the
        # enumeration outright (before the action pairing).
        if discipline and _cheb(landing, station) > _cheb(origin, station):
            continue
        score = _evaluate(sim, unit, theta, my_side, their_side,
                          station_valid, station)
        if first or score > best_score:
            first = False
            best_score = score
            best = _steer_decision(vel)

        # --- cannon per loaded side, §4.11.8-best target for the side. -----
        for side in fire_sides:
            sim.restore(pre)
            sim.apply_velocity(unit, vel)
            target = _fire_target_for_side(sim, unit, side, foes, profile,
                                           assigned_target)
            if not target:
                continue
            # §4.4b: the shot type is rule-derived OUTSIDE the enumeration.
            shot = str(sim.ai_shot_type(unit, target))
            sim.cannon(unit, target, side, shot)
            score = _evaluate(sim, unit, theta, my_side, their_side,
                              station_valid, station)
            if score > best_score:
                best_score = score
                best = {"action": "cannon", "target": target,
                        "side": side, "shot": shot, "vel": vel}

        # --- ram: the first legal target (§4.11.8 pin 4's rating gate). ----
        if ram_capable:
            sim.restore(pre)
            sim.apply_velocity(unit, vel)
            ram_target = _ram_target(sim, unit, foes)
            if ram_target:
                sim.ram(unit, ram_target)
                score = _evaluate(sim, unit, theta, my_side, their_side,
                                  station_valid, station)
                if score > best_score:
                    best_score = score
                    best = {"action": "ram", "target": ram_target, "vel": vel}

        # --- board: the §4.6a hook + the §4.11.8 pin 4 board gate. ---------
        sim.restore(pre)
        sim.apply_velocity(unit, vel)
        board_target = ai_fleet._boarding_target(sim, unit, foes)
        if board_target:
            sim.board(unit, board_target)
            score = _evaluate(sim, unit, theta, my_side, their_side,
                              station_valid, station)
            if score > best_score:
                best_score = score
                best = {"action": "board", "target": board_target, "vel": vel}

    sim.restore(pre)
    if not best:
        return hold
    return best


def _steer_decision(vel: Cell) -> dict[str, Any]:
    """The no-action candidate's decision: a (0,0) pick is the §4.9a hold,
    any other velocity is a ``move`` (the T2 steering dict shape)."""
    if vel == (0, 0):
        return {"action": "hold", "target": {}, "vel": (0, 0)}
    return {"action": "move", "target": {}, "vel": vel}


def _fire_target_for_side(sim: BattleSim, unit: dict[str, Any], side: str,
                          foes: list[dict[str, Any]],
                          profile: dict[str, Any],
                          fleet_order_target: int = -1) -> dict[str, Any]:
    """The §4.11.8-best fire target for the NAMED side from the current
    state: among the side's fireable foes (arc + Chebyshev 1..3, §4.4) a
    rake-position pool wins when any exists, then the profile ``focus``
    picks (:func:`server.sim.combat.ai_fleet._focus_target` — the single
    focus implementation). ``{}`` when the side has no fireable target.

    §4.9b engage assignment (W5 master bounce): an ``assigned_target ≥ 0``
    restricts the fire pool to that ship. DEAD/absent ⇒ the free-ranking
    fallback (the T2 consumer's exact rule); ALIVE but not fireable on this
    side ⇒ the pool is EMPTY ⇒ hold fire — the same semantics on both
    levels (unified W5-D gate).
    """
    fireable: list[dict[str, Any]] = []
    raked: list[dict[str, Any]] = []
    for foe in foes:
        if not sim.can_cannon(unit, foe, side):
            continue
        fireable.append(foe)
        if ai_fleet._is_rake_on(sim.unit_cell(foe),
                                int(foe.get("heading8", HEADING_EAST)),
                                sim.unit_cell(unit)):
            raked.append(foe)
    if not fireable:
        return {}
    pool = raked if raked else fireable
    assigned = int(fleet_order_target)
    if assigned >= 0:
        assigned_foe: dict[str, Any] = {}
        for foe in foes:
            if int(foe.get("index", -1)) == assigned and bool(foe.get("alive", False)):
                assigned_foe = foe
                break
        if not assigned_foe:
            return ai_fleet._focus_target(profile, unit, pool, sim)
        pinned = [foe for foe in pool if int(foe.get("index", -1)) == assigned]
        if not pinned:
            return {}
        pool = pinned
    return ai_fleet._focus_target(profile, unit, pool, sim)


def _ram_target(sim: BattleSim, unit: dict[str, Any],
                foes: list[dict[str, Any]]) -> dict[str, Any]:
    """The §4.11.8 pin 4 ram target: the first foe (fleet-index order) that
    is orthogonally adjacent AND loses the cannon+duel-rating comparison
    (own cannons + duel rating > the target's). ``{}`` when none qualifies.
    """
    own_rating = (int(unit.get("ship", {}).get("cannons", 0))
                  + int(unit.get("captain_rating", 0)))
    for foe in foes:
        if not sim.can_ram(unit, foe):
            continue
        theirs = (int(foe.get("ship", {}).get("cannons", 0))
                  + int(foe.get("captain_rating", 0)))
        if own_rating > theirs:
            return foe
    return {}


def _side_loaded(sim: BattleSim, unit: dict[str, Any], side: str,
                 round_no: int) -> bool:
    """§4.4 side firing readiness (the "loaded" reading shared by φ3/φ4/φ6):
    ``round >= reload_side`` AND the side carries ≥ 1 cannon."""
    if sim.side_cannons(unit, side) < 1:
        return False
    key = "reload_port" if side == BROADSIDE_PORT else "reload_starboard"
    return round_no >= int(unit.get(key, 1))


# --- The nine features (docs/60-* §4.9c — the normative φ table) -------------
#
# φ1 durability diff  (friendly total durability − enemy total) / 20
# φ2 cannon diff      (friendly total cannons − enemy total) / 4
# φ3 reload diff      (friendly loaded side-count − enemy loaded side-count)
# φ4 arc fit          friendly loaded sides with a living enemy in arc+range
#                     minus the enemy's mirror
# φ5 rake exposure    friendly ships sitting in an enemy's rake position
#                     minus the enemy's mirror
# φ6 flagship danger  my flagship's two danger terms minus the enemy
#                     flagship's
# φ7 station deviation  Chebyshev(pos_after, order.station) — 0 without a
#                     station (the §4.9b line phases only)
# φ8 friendly-blocked line  friendly pairs (a, b) with b on a's heading-ray
#                     within Chebyshev 3
# φ9 heading alignment  4 − min(bucket_distance(heading_after, bearing to
#                     the nearest enemy), 4)
#
# "friendly" is the deciding ship's side, "enemy" the opposing side; totals
# run over LIVING ships; every feature is a small deterministic integer.


def _trunc_div(numerator: int, denominator: int) -> int:
    """Integer division truncating toward zero (GDScript ``int / int``)."""
    if numerator < 0:
        return -((-numerator) // denominator)
    return numerator // denominator


def _evaluate(sim: BattleSim, unit: dict[str, Any], theta: Sequence[int],
              my_side: str, their_side: str, station_valid: bool,
              station: Cell) -> int:
    """The §4.9c ``score = θ·φ`` over the nine integer features, on the
    CURRENT (candidate-applied) sim state."""
    round_no = sim.round_number()
    mine = sim.living_units(my_side)
    theirs = sim.living_units(their_side)

    durability = 0
    durability_theirs = 0
    cannons = 0
    cannons_theirs = 0
    loaded = 0
    loaded_theirs = 0
    arc_fit = 0
    rake_exposure = 0
    blocked = 0
    for u in mine:
        durability += int(u.get("ship", {}).get("durability", 0))
        cannons += (sim.side_cannons(u, BROADSIDE_PORT)
                    + sim.side_cannons(u, BROADSIDE_STARBOARD))
        loaded += _loaded_side_count(sim, u, round_no)
        arc_fit += _loaded_arcs_with_target(sim, u, theirs, round_no)
        if _is_exposed(sim, u, theirs):
            rake_exposure += 1
        blocked += _blocked_count(mine, u)
    for u in theirs:
        durability_theirs += int(u.get("ship", {}).get("durability", 0))
        cannons_theirs += (sim.side_cannons(u, BROADSIDE_PORT)
                           + sim.side_cannons(u, BROADSIDE_STARBOARD))
        loaded_theirs += _loaded_side_count(sim, u, round_no)
        arc_fit -= _loaded_arcs_with_target(sim, u, mine, round_no)
        if _is_exposed(sim, u, mine):
            rake_exposure -= 1
    flagship_danger = (
        _flagship_danger(sim, my_side, mine, theirs, round_no)
        - _flagship_danger(sim, their_side, theirs, mine, round_no))
    station_deviation = (_cheb(sim.unit_cell(unit), station)
                         if station_valid else 0)
    nearest = ai_fleet._nearest(sim, theirs, sim.unit_cell(unit))
    unit_cell = sim.unit_cell(unit)
    bearing = HEADING_EAST
    if nearest:
        nearest_cell = sim.unit_cell(nearest["unit"])
        bearing = heading8_of((nearest_cell[0] - unit_cell[0],
                               nearest_cell[1] - unit_cell[1]))
    alignment = ALIGNMENT_MAX - min(bucket_distance(
        int(unit.get("heading8", 0)) % 8, bearing), ALIGNMENT_MAX)

    features = (
        _trunc_div(durability - durability_theirs, DURABILITY_DIFF_DIVISOR),
        _trunc_div(cannons - cannons_theirs, CANNON_DIFF_DIVISOR),
        loaded - loaded_theirs,
        arc_fit,
        rake_exposure,
        flagship_danger,
        station_deviation,
        blocked,
        alignment,
    )
    score = 0
    for index, feature in enumerate(features):
        if index >= len(theta):
            break
        score += int(theta[index]) * int(feature)
    return score


def _loaded_side_count(sim: BattleSim, unit: dict[str, Any],
                       round_no: int) -> int:
    """φ3's per-ship half: how many of the ship's sides are loaded (0..2)."""
    count = 0
    for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
        if _side_loaded(sim, unit, side, round_no):
            count += 1
    return count


def _in_loaded_arc(sim: BattleSim, ship: dict[str, Any],
                   target: dict[str, Any], round_no: int) -> bool:
    """True when ``ship`` has a LOADED side whose §4.4 arc contains
    ``target`` within cannon range (Chebyshev 1..3), judged on the current
    state. The φ6 "inside some enemy loaded arc within range" term and the
    φ4 per-side scan both read through here.
    """
    origin = sim.unit_cell(ship)
    target_cell = sim.unit_cell(target)
    distance = _cheb(origin, target_cell)
    if distance < CANNON_RANGE_MIN or distance > CANNON_RANGE_MAX:
        return False
    steps = (heading8_of((target_cell[0] - origin[0],
                          target_cell[1] - origin[1]))
             - int(ship.get("heading8", HEADING_EAST))) % 8
    for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
        if not _side_loaded(sim, ship, side, round_no):
            continue
        arc = _arc_steps(side)
        if steps in arc:
            return True
    return False


def _arc_steps(side: str) -> tuple[int, ...]:
    """The §4.4 SIGNED arc steps for ``side`` (port {1,2,3} / starboard
    {5,6,7} — the engine's own constants, never a second copy)."""
    return ARC_PORT_STEPS if side == BROADSIDE_PORT else ARC_STARBOARD_STEPS


def _loaded_arcs_with_target(sim: BattleSim, ship: dict[str, Any],
                             foes: list[dict[str, Any]], round_no: int) -> int:
    """φ4's per-ship half: how many of the ship's loaded sides (0..2) have a
    living opponent in arc + range."""
    count = 0
    for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
        if not _side_loaded(sim, ship, side, round_no):
            continue
        origin = sim.unit_cell(ship)
        heading = int(ship.get("heading8", HEADING_EAST))
        arc = _arc_steps(side)
        for foe in foes:
            foe_cell = sim.unit_cell(foe)
            distance = _cheb(origin, foe_cell)
            if distance < CANNON_RANGE_MIN or distance > CANNON_RANGE_MAX:
                continue
            steps = (heading8_of((foe_cell[0] - origin[0],
                                  foe_cell[1] - origin[1])) - heading) % 8
            if steps in arc:
                count += 1
                break
    return count


def _is_exposed(sim: BattleSim, ship: dict[str, Any],
                foes: list[dict[str, Any]]) -> bool:
    """φ5's predicate: ``ship`` sits in a rake position of some living
    opponent — the bearing bucket between them ∈ {0°, 180°} relative to
    SHIP's heading8 (AiFleet's rake predicate — the shot would run the
    ship's deck line)."""
    cell = sim.unit_cell(ship)
    heading = int(ship.get("heading8", HEADING_EAST))
    for foe in foes:
        if ai_fleet._is_rake_on(cell, heading, sim.unit_cell(foe)):
            return True
    return False


def _flagship_danger(sim: BattleSim, side: str,
                     units: list[dict[str, Any]],
                     foes: list[dict[str, Any]], round_no: int) -> int:
    """φ6 for one side: the side flagship's two danger terms (≤ 25%
    durability; inside some opponent loaded arc within range), 0 when the
    flagship is sunk. The flagship is the engine's: fleet index 0 for the AI
    side, the §4.6 succession index (``flagship_index``) for the player side.
    """
    want = 0
    if side == SIDE_PLAYER and hasattr(sim, "flagship_index"):
        want = int(sim.flagship_index())
    flagship: dict[str, Any] = {}
    for u in units:
        if int(u.get("index", -1)) == want:
            flagship = u
            break
    if not flagship:
        return 0
    danger = 0
    ship: dict[str, Any] = flagship.get("ship", {})
    max_durability = sim.effective_max_durability(ship)
    if max_durability > 0 and int(ship.get("durability", 0)) * 100 \
            <= FLAGSHIP_LOW_DURABILITY_PERCENT * max_durability:
        danger += 1
    for foe in foes:
        if _in_loaded_arc(sim, foe, flagship, round_no):
            danger += 1
            break
    return danger


def _blocked_count(units: list[dict[str, Any]], ship: dict[str, Any]) -> int:
    """φ8: the friendly ships sitting on ``ship``'s own heading-ray within
    Chebyshev 3 — the broadside lane blocked ahead (1..3 cells along
    ``heading8``)."""
    origin = _cell_of(ship)
    ray = HEADING_RAYS[int(ship.get("heading8", 0)) % 8]
    count = 0
    for other in units:
        if other is ship:
            continue
        other_cell = _cell_of(other)
        delta = (other_cell[0] - origin[0], other_cell[1] - origin[1])
        for k in range(BLOCKED_LANE_MIN_CELLS, BLOCKED_LANE_MAX_CELLS + 1):
            if delta == (ray[0] * k, ray[1] * k):
                count += 1
                break
    return count


def _cell_of(unit: dict[str, Any]) -> Cell:
    return to_cell(unit.get("pos", unit.get("cell", NO_CELL)))


def _cheb(a: Cell, b: Cell) -> int:
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))
