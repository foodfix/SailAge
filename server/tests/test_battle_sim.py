"""server.tests.test_battle_sim — the battle-core parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_battle.gd`` W3-D/W4-D, the economy suite
``tools/test_battle_economy.gd`` and the composition/AI pins of the
Phase-9 slots) drive a scene tree and the autoloads; here the same pinned
contracts are asserted as closed forms and short deterministic battles on
the real shipped ``data/`` tree.

Pinned contracts (oracles: ``scripts/combat/battle_sim.gd`` +
``ai_fleet.gd`` + ``battle_result.gd`` + ``battle_rewards.gd``;
docs/60-COMBAT.md §4.2–§4.9a, §4.11.1–§4.11.15, §4.12.1–§4.12.4):
  * §4.11.2 deployment — 48×30, the five pinned cells per side, the
    closing start (flagship vel (±1,0), extras at rest), band overflow
    scan, 27 cells apart;
  * §4.3a velocity legality — the §4.11.4 constraint order, standstill
    any-direction, the (y, x) enumeration order + Chebyshev box bound,
    the overshoot clamp along the chosen direction;
  * §4.3a cap_eff — calm identity, the §4.4 direction columns, the
    current ±1 pins, the chain debuff −1 floored at 1, the sail delta
    applied after the clamp unclamped;
  * §4.3a heading8 — the 22.5° boundaries via integer dot scores, no
    integer tie;
  * §4.4 broadsides — floor(n/2)/rest split with the total retained, the
    SIGNED arcs {45,90,135}/{225,270,315}, independent per-side reload;
  * §4.4a reload — gunnery 0/50/100 → 2/1/1, low crew +1, the legacy
    10+10×tier fallback, ``reload_side = round + turns``;
  * §4.4b shot types — the gates 25/50 (data-driven), grape range 1 only
    with the halved hull+crew pair, the deterministic AI shot rule order;
  * §4.4/§4.11.5 damage — ONE floor after the weather term, storm ×0.75 /
    strong ×0.9, rake ×1.25 at the target-heading buckets 0°/180°, the
    §5 worked example, crew /20 and /10, the boarding 0.2, clamp at 0;
  * §4.5/§4.3a the sweep — enemy entry ram, friendly/out-of-bounds stop
    at the prior cell, the ram multiplier stack (speed, bow/stern ×1.15,
    oar ×1.25), the attacker resolves last;
  * §4.6a the hook — orthogonal adjacency + both ‖vel‖ ≤ 1 + weather ≠
    storm, both velocities zeroed on the hook;
  * §4.11.9 stall — 8 quiet rounds within the ±2 net window (round 8
    exactly), the drift breach (the wall case completes at round 32), any
    damage resets;
  * §4.11.4 initiative — built once (speed + sail delta desc, player
    first, fleet index), dead slots skipped, never re-sorted;
  * §4.11.1 determinism — the seed formula, the config override, and a
    same-seed full replay (compose_enemy + shared stream) with an
    identical log + outcome;
  * §4.11.6 the duel — the single ``resolve_duel`` formula, best-of-5,
    the defender-holds tie, the pinned seed sequences (33/19/2/14);
  * §4.8a side morale — the start formulas, the event table on both
    sides (flagship −30 TOTAL replacing −15), the clamps, the surrender
    widening, the ≤ 10 AI-only instant strike, the outcome delta;
  * §4.11.10 economy — salvage/XP/rep pre-computed in the outcome block,
    the 40-round cap, the menu outcomes, the engine deep-copies the
    caller's ships;
  * §4.11.3/§4.12.1.1 composition — the locked hull order, the count
    bands, the round-robin cannon deal under the budget, the broadside
    split written at composition, the cargo roll;
  * §4.9a T2 decisions — flee / fire (rake → focus → side tie → port) /
    board ≥ ram / close deceleration, all landing-judged; the T3
    dispatch seams to ``ai_search`` (skip-clean until that module merges);
  * §4.12.3 battle_result — the capture transform, the idle-officer gate
    + loot-convert fallback, both loss lists, the game-over report;
  * §4.11.10/§4.12.3 battle_rewards — the salvage/XP formulas on hand
    prices, the nearest-nations pins (Lisbon / same-nation / tie), the
    haul valuation clamp, the idempotency marker, the morale writeback,
    the §4.11.13 named-pirate drop flow.

Deterministic — no Monte Carlo, no soaks; every seeded battle replays a
fixed seed through the bit-exact :class:`~server.sim.rng.GodotRng`.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

from server.sim.combat import battle_result as battle_result_mod
from server.sim.combat import battle_rewards as rewards
from server.sim.combat.ai_fleet import (
    BOARD_DURABILITY_PERCENT,
    CARGO_CAPACITY_DIVISOR,
    FLEE_AGGRESSION_MAX,
    HULL_IDS,
    RAM_SPEED_MIN,
    cannon_budget,
    compose_enemy,
    decide,
    profile_for,
)
from server.sim.combat.battle_sim import (
    ARC_PORT_STEPS,
    ARC_STARBOARD_STEPS,
    BROADSIDE_PORT,
    BROADSIDE_STARBOARD,
    BattleSim,
    CANNON_RANGE_FACTOR,
    DEFAULT_ARMOR_PIERCING_GATE,
    DEFAULT_CHAIN_GATE,
    DUEL_ROUND_MAX_ROLL,
    ENEMY_BAND_MIN_X,
    ENEMY_DEPLOYMENT,
    FLEET_TIER,
    GRID_HEIGHT,
    GRID_WIDTH,
    HEADING_EAST,
    HEADING_WEST,
    MAX_ROUNDS,
    MORALE_EVENT_BOARDING_LOSS,
    MORALE_EVENT_BOARDING_WIN,
    MORALE_EVENT_CAPTURED,
    MORALE_EVENT_FLAGSHIP_SUNK,
    MORALE_EVENT_FRIENDLY_SUNK,
    MORALE_EVENT_RAKED,
    MORALE_INSTANT_STRIKE,
    MORALE_SURRENDER_GATE,
    NAVY_REP_PENALTY,
    PIRATE_REP_GAIN,
    PLAYER_BAND_MAX_X,
    PLAYER_DEPLOYMENT,
    RAKE_MULTIPLIER,
    SALVAGE_FRACTION,
    STALL_DISTANCE_DELTA,
    STALL_ROUNDS,
    XP_PER_ENEMY_NEUTRALIZED,
    XP_PER_ROUND,
    armor_piercing_gate,
    battle_seed_formula,
    bresenham_cells,
    bucket_distance,
    chain_shot_gate,
    defender_charisma_bonus,
    defender_duel_base,
    heading8_of,
    in_grid,
    month_for,
    morale_surrender_bonus,
    resolve_duel,
    surrender_chance_for_courage,
    to_cell,
    vel_length,
    wind_factor,
)
from server.sim.data import data
from server.sim.fleet.fleet import FLEET_MAX, hold_units
from server.sim.player import PersonState
from server.sim.rng import GodotRng

# --- Fixtures ---------------------------------------------------------------


def person(swordplay: int = 10, gunnery: int = 0,
           courage: int = 10, charisma: int = 10) -> dict[str, Any]:
    """The Phase-8 Person-model player block (50-* §4.8 shape) — the S21
    ``player_stats`` injection of the GDScript ``_person`` fixture."""
    return {
        "attributes": {
            "constitution": 10, "intellect": 10, "charisma": charisma,
            "courage": courage, "luck": 10,
        },
        "skills": {
            "seamanship": 0, "navigation": 0, "swordplay": swordplay,
            "gunnery": gunnery, "appraisal": 0, "negotiation": 0,
            "cartography": 0, "rumour": 0,
        },
        "equipment": {"weapon": "", "armor": ""},
    }


def ship(ship_type_id: str, overrides: dict[str, Any] | None = None,
         **kw: Any) -> dict[str, Any]:
    """A §4.11.11 ship instance (40-* §4.1 + the §4.11.12 equipment
    object); ``crew`` defaults to the hull's ``crew_min``. Both the
    GDScript positional-override form and keyword overrides work."""
    ship_type = data().get_ship_type(ship_type_id)
    base: dict[str, Any] = {
        "ship_type_id": ship_type_id,
        "durability": int(ship_type.get("durability", 0)),
        "crew": int(ship_type.get("crew_min", 0)),
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "equipment": {"figurehead": "", "sail": ""},
        "cargo": {},
    }
    base.update(overrides or {})
    base.update(kw)
    return base


def sim(config: dict[str, Any] | None = None) -> BattleSim:
    """A hermetic sim fixture: the contact-tile current defaults to
    strength 0 so no ±1 cap mod leaks from the real raster (the GDScript
    ``_sim`` seam); ``player_stats`` carries the standard person block."""
    full: dict[str, Any] = {
        "player_ships": [], "enemy_ships": [], "enemy_kind": "pirate",
        "enemy_nation": "", "day": 1, "gold": 0,
        "contact": (30, 40), "weather": "calm",
        "current": {"dir": "", "strength": 0},
        "player_stats": person(),
    }
    full.update(config or {})
    return BattleSim(full)


def unit_of(sim_: BattleSim, side: str, index: int) -> dict[str, Any]:
    for unit in sim_.units():
        if unit.get("side") == side and unit.get("index") == index:
            return unit
    raise AssertionError(f"no unit {side}/{index}")


def place(sim_: BattleSim, side: str, index: int, cell: tuple[int, int]) -> None:
    unit_of(sim_, side, index)["pos"] = cell


def face(unit: dict[str, Any], heading8: int) -> None:
    unit["heading8"] = heading8


def begin_turn(sim_: BattleSim, side: str, index: int) -> dict[str, Any]:
    """Ends turns until ``side``/``index`` is acting — direct action
    fixtures resolve exactly as in a battle (§4.11.4)."""
    for _guard in range(16):
        current = sim_.current_unit()
        if not current:
            return {}
        if current["side"] == side and current["index"] == index:
            return current
        sim_.end_turn()
    raise AssertionError(f"{side}/{index} never became the acting unit")


def order_of(sim_: BattleSim, count: int) -> list[str]:
    out: list[str] = []
    for _index in range(count):
        unit = sim_.current_unit()
        if not unit:
            break
        out.append(f"{unit['side']}:{unit['index']}")
        sim_.end_turn()
    return out


def cheb(a: tuple[int, int], b: tuple[int, int]) -> int:
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))


def landing(sim_: BattleSim, unit: dict[str, Any],
            step: tuple[int, int]) -> tuple[int, int]:
    """The cell the §4.3a sweep actually reaches (the same preview the
    harness uses)."""
    frm = sim_.unit_cell(unit)
    prior = frm
    for cell in bresenham_cells(frm, (frm[0] + step[0], frm[1] + step[1])):
        if not in_grid(cell):
            return prior
        if sim_._living_unit_at(cell, unit):
            return prior
        prior = cell
    return prior


def hold_policy(sim_: BattleSim, unit: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"action": "hold"}


def fire_and_close_policy(sim_: BattleSim, unit: dict[str, Any]) -> dict[str, Any]:
    """The GDScript harness's deterministic battle policy: ① fire a loaded
    side with an enemy in range+arc (round shot) ② else the first legal
    velocity whose bearing keeps the nearest enemy in a broadside arc
    ③ else the first legal velocity whose landing strictly reduces
    Chebyshev without entering an occupied cell ④ hold. Zero dice."""
    own_side = unit.get("side", "player")
    other = "enemy" if own_side == "player" else "player"
    enemies = sim_.living_units(other)
    if not enemies:
        return {"action": "hold"}
    for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
        for target in enemies:
            if sim_.can_cannon(unit, target, side):
                return {"action": "cannon", "target": target,
                        "side": side, "shot": "round"}
    frm = sim_.unit_cell(unit)
    nearest = enemies[0]
    for enemy in enemies:
        if cheb(frm, sim_.unit_cell(enemy)) < cheb(frm, sim_.unit_cell(nearest)):
            nearest = enemy
    bearing = heading8_of((sim_.unit_cell(nearest)[0] - frm[0],
                           sim_.unit_cell(nearest)[1] - frm[1]))
    for vel in sim_.legal_velocities(unit):
        if vel == (0, 0):
            continue
        steps = bucket_distance(bearing, heading8_of(vel))
        if steps in ARC_PORT_STEPS or steps in ARC_STARBOARD_STEPS:
            return {"action": "move", "vel": vel}
    distance = cheb(frm, sim_.unit_cell(nearest))
    for vel in sim_.legal_velocities(unit):
        if vel == (0, 0):
            continue
        reach = landing(sim_, unit, vel)
        if reach != frm and cheb(reach, sim_.unit_cell(nearest)) < distance:
            return {"action": "move", "vel": vel}
    return {"action": "hold"}


# --- 1. Grid + deployment (§4.2, §4.11.2) -------------------------------------


class TestGridAndDeployment:
    def test_grid_and_bands(self) -> None:
        assert (GRID_WIDTH, GRID_HEIGHT) == (48, 30)
        assert PLAYER_BAND_MAX_X == 12 and ENEMY_BAND_MIN_X == 35
        assert len(PLAYER_DEPLOYMENT) == 5 and len(ENEMY_DEPLOYMENT) == 5
        assert PLAYER_DEPLOYMENT[0][0] <= PLAYER_BAND_MAX_X
        assert ENEMY_DEPLOYMENT[0][0] >= ENEMY_BAND_MIN_X

    def test_pinned_cells_and_closing_start(self) -> None:
        assert PLAYER_DEPLOYMENT == (
            (10, 15), (10, 14), (10, 16), (10, 13), (10, 17))
        assert ENEMY_DEPLOYMENT == (
            (37, 15), (37, 14), (37, 16), (37, 13), (37, 17))
        assert ENEMY_DEPLOYMENT[0][0] - PLAYER_DEPLOYMENT[0][0] == 27
        s = sim({"player_ships": [ship("sloop"), ship("sloop")],
                 "enemy_ships": [ship("latin"), ship("latin")]})
        s.start()
        p0 = unit_of(s, "player", 0)
        e0 = unit_of(s, "enemy", 0)
        assert p0["vel"] == (1, 0) and e0["vel"] == (-1, 0)
        # Extras deploy at rest through the band scan.
        assert unit_of(s, "player", 1)["vel"] == (0, 0)
        assert unit_of(s, "enemy", 1)["vel"] == (0, 0)
        assert p0["heading8"] == HEADING_EAST and e0["heading8"] == HEADING_WEST

    def test_one_ship_per_cell_and_unit_count(self) -> None:
        for count in range(1, 6):
            s = sim({"player_ships": [ship("sloop") for _ in range(count)],
                     "enemy_ships": [ship("latin") for _ in range(count)]})
            s.start()
            cells = [s.unit_cell(u) for u in s.units()]
            assert len(cells) == count * 2
            assert len(set(cells)) == len(cells)
            for index in range(count):
                assert s.unit_cell(unit_of(s, "player", index)) == PLAYER_DEPLOYMENT[index]
                assert s.unit_cell(unit_of(s, "enemy", index)) == ENEMY_DEPLOYMENT[index]

    def test_band_overflow_continues_in_band_scan(self) -> None:
        s = sim({"player_ships": [ship("sloop") for _ in range(6)],
                 "enemy_ships": [ship("latin")]})
        s.start()
        sixth = s.unit_cell(unit_of(s, "player", 5))
        assert sixth == (0, 0)
        assert sixth[0] <= PLAYER_BAND_MAX_X
        cells = [s.unit_cell(u) for u in s.units()]
        assert len(set(cells)) == len(cells)

    def test_tournament_variant_maps_to_same_start(self) -> None:
        s = sim({"player_ships": [ship("brigantine")],
                 "enemy_ships": [ship("brigantine")],
                 "deployment": "tournament"})
        s.start()
        assert s.unit_cell(unit_of(s, "player", 0)) == (10, 15)
        assert unit_of(s, "player", 0)["vel"] == (1, 0)
        assert unit_of(s, "enemy", 0)["vel"] == (-1, 0)


# --- 2. heading8 (§4.3a, decision 1) --------------------------------------------


class TestHeading8:
    def test_compass_rays(self) -> None:
        compass = [((1, 0), 0), ((1, -1), 1), ((0, -1), 2), ((-1, -1), 3),
                   ((-1, 0), 4), ((-1, 1), 5), ((0, 1), 6), ((1, 1), 7)]
        for vel, expected in compass:
            assert heading8_of(vel) == expected

    def test_22_5_boundaries_have_no_integer_tie(self) -> None:
        # slope 12/29 ≈ 0.4138 < tan 22.5° stays E; 5/12 ≈ 0.4167 tips NE.
        assert heading8_of((29, -12)) == 0
        assert heading8_of((12, -5)) == 1
        assert heading8_of((-29, 12)) == 4  # symmetric

    def test_zero_keeps_last_heading(self) -> None:
        assert heading8_of((0, 0)) == HEADING_EAST  # the static default

    def test_bucket_distance(self) -> None:
        assert bucket_distance(0, 1) == 1
        assert bucket_distance(0, 4) == 4
        assert bucket_distance(1, 7) == 2
        assert bucket_distance(3, 7) == 4


# --- 3. Velocity legality (§4.3a / §4.11.4) ----------------------------------------


class TestVelocityLegality:
    def test_enumeration_is_yx_lexicographic_within_the_box(self) -> None:
        s = sim({"player_ships": [ship("brigantine")]})
        s.start()
        unit = unit_of(s, "player", 0)
        # From standstill any direction is legal with magnitude ≤ accel
        # (the angle constraint is relaxed; the cap still applies).
        unit["vel"] = (0, 0)
        legal = s.legal_velocities(unit)
        # The derived Chebyshev box bound: (2×battle_max_speed+1)² = 121
        # at the correction-15 speed-5 tier; the magnitude filters shrink
        # the count but never the ORDER.
        assert s.battle_max_speed(unit) == 5
        box = [(vy, vx) for vy in range(-5, 6) for vx in range(-5, 6)]
        assert legal == sorted(legal, key=lambda v: (v[1], v[0]))
        assert all(abs(v[0]) <= 5 and abs(v[1]) <= 5 for v in legal)
        assert len(box) == 121
        assert all(vel_length(v) <= s.battle_accel(unit) or v == (0, 0)
                   for v in legal)

    def test_turn_rate_constraint_order(self) -> None:
        s = sim({"player_ships": [ship("caravel")], "enemy_ships": [ship("latin")]})
        s.start()
        unit = unit_of(s, "player", 0)
        unit["vel"] = (1, 0)
        unit["heading8"] = HEADING_EAST
        legal = s.legal_velocities(unit)
        for vel in legal:
            if vel == (0, 0):
                continue
            assert bucket_distance(heading8_of(vel), HEADING_EAST) * 45 <= 45
            assert abs(vel_length(vel) - 1.0) <= s.battle_accel(unit)
        # NE (45°) is legal for a 45° hull; N (90°) is not.
        assert (1, -1) in legal
        assert (0, -1) not in legal

    def test_apply_velocity_rejects_then_clamps(self) -> None:
        s = sim({"player_ships": [ship("brigantine")],
                 "enemy_ships": [ship("sloop")],  # faster: acts first
                 "weather": "calm"})
        s.start()
        unit = unit_of(s, "player", 0)
        begin_turn(s, "player", 0)
        unit["vel"] = (1, 0)
        unit["heading8"] = HEADING_EAST
        # Illegal: the magnitude delta exceeds accel.
        assert not s.apply_velocity(unit, (3, 0))
        assert unit["vel"] == (1, 0) and s.unit_cell(unit) == (10, 15)
        # The magnitude-delta leg gates BEFORE the cap: (0,5) from mag 1
        # is refused outright (delta 4 > accel 1).
        assert not s.apply_velocity(unit, (0, 5))
        # The overshoot clamp only reaches a pick whose magnitude delta is
        # legal but whose magnitude exceeds cap_eff: latin at rest-mag 2
        # (its calm cap), picking (3,0) — delta 1, mag 3 > cap 2 → clamps
        # ALONG THE CHOSEN DIRECTION to (2,0).
        s2 = sim({"player_ships": [ship("latin")], "enemy_ships": [ship("latin")]})
        s2.start()
        clamper = unit_of(s2, "player", 0)
        begin_turn(s2, "player", 0)
        clamper["vel"] = (0, 2)   # ‖vel‖ 2 = the calm sail cap of the latin
        clamper["heading8"] = 2   # N
        assert s2.cap_eff(clamper) == 2
        assert s2.apply_velocity(clamper, (3, 0))
        assert clamper["vel"] == (2, 0)
        assert clamper["heading8"] == 0
        # Movement happens exactly once per turn.
        assert not s2.apply_velocity(clamper, (1, 0))

    def test_ninety_degree_hull_turns(self) -> None:
        latin = sim({"player_ships": [ship("latin")],
                     "enemy_ships": [ship("brigantine")]})  # faster: acts first
        latin.start()
        lu = unit_of(latin, "player", 0)
        begin_turn(latin, "player", 0)
        lu["vel"] = (1, 0)
        lu["heading8"] = HEADING_EAST
        assert latin.battle_turn_rate(lu) == 90
        assert latin.apply_velocity(lu, (0, -1))
        assert lu["vel"] == (0, -1)
        assert lu["heading8"] == heading8_of((0, -1))

    def test_zero_pick_keeps_heading_and_holds(self) -> None:
        s = sim({"player_ships": [ship("brigantine")],
                 "enemy_ships": [ship("latin")]})
        s.start()
        unit = unit_of(s, "player", 0)
        begin_turn(s, "player", 0)
        assert s.apply_velocity(unit, (0, 0))
        assert unit["vel"] == (0, 0)
        assert unit["heading8"] == HEADING_EAST  # the last heading
        assert s.unit_cell(unit) == (10, 15)     # position held


# --- 4. cap_eff (§4.3a, decision 2) ---------------------------------------------------


class TestCapEff:
    def test_calm_identity_and_sail_delta_after_clamp(self) -> None:
        s = sim({"player_ships": [ship("brigantine")]})
        s.start()
        unit = unit_of(s, "player", 0)
        # calm ⇒ direction identity 1.0; sail wind factor 0.8:
        # clamp(floor(5 × 0.8 × 1.0), 0, 5) = 4, no sail delta.
        assert s.cap_eff(unit) == 4
        # The sail delta applies AFTER the clamp and is NOT clamped back.
        unit["ship"]["equipment"]["sail"] = "eq_flemish_linen_sails"  # +2
        assert s.cap_eff(unit) == 6  # beyond battle_max_speed 5, unclamped

    def test_direction_factor_columns(self) -> None:
        s = sim({"player_ships": [ship("brigantine")], "weather": "fair",
                 "wind_dir": "W"})
        s.start()
        unit = unit_of(s, "player", 0)
        unit["vel"] = (1, 0)
        unit["heading8"] = HEADING_EAST  # running dead downwind: bucket 180
        # fair sail 1.0 × 180° sail 1.30 → floor(5 × 1.3) = 6 → clamp 5.
        assert s.cap_eff(unit) == 5
        face(unit, HEADING_WEST)  # beating into the wind: bucket 0
        # fair 1.0 × 0° sail 0.50 → floor(2.5) = 2.
        assert s.cap_eff(unit) == 2
        oar = sim({"player_ships": [ship("galley")], "weather": "fair",
                   "wind_dir": "W"})
        oar.start()
        gu = unit_of(oar, "player", 0)
        face(gu, HEADING_WEST)
        # Oar ignores direction: floor(5 × 1.0 × 1.0) = 5.
        assert oar.cap_eff(gu) == 5

    def test_current_mod_pins(self) -> None:
        # bucket ∈ {0°,45°} with strength ≥ 2 → +1; {135°,180°} with
        # strength 3 → −1; strength 1 never modifies.
        def cap_for(current: dict[str, Any], heading8: int) -> int:
            s = sim({"player_ships": [ship("brigantine")],
                     "weather": "calm", "current": dict(current)})
            s.start()
            unit = unit_of(s, "player", 0)
            unit["vel"] = (1, 0)
            face(unit, heading8)
            return s.cap_eff(unit)
        # Current flow E: heading E is bucket 0. strength 1 → no mod.
        assert cap_for({"dir": "E", "strength": 1}, HEADING_EAST) == 4
        assert cap_for({"dir": "E", "strength": 2}, HEADING_EAST) == 5  # +1
        assert cap_for({"dir": "E", "strength": 3}, HEADING_WEST) == 3  # −1
        assert cap_for({"dir": "E", "strength": 2}, HEADING_WEST) == 4  # 180°, s2

    def test_chain_debuff_floors_at_one(self) -> None:
        s = sim({"player_ships": [ship("latin")], "weather": "fair",
                 "wind_dir": "W"})
        s.start()
        unit = unit_of(s, "player", 0)
        unit["vel"] = (1, 0)
        face(unit, HEADING_WEST)  # bucket 0 sail: floor(3 × 1.0 × 0.5) = 1
        assert s.cap_eff(unit) == 1
        unit["speed_debuff_turns"] = 2
        assert s.cap_eff(unit) == 1  # the chain-shot cap floor


# --- 5. Broadsides & reload (§4.4, §4.4a) -----------------------------------------------


class TestBroadsidesAndReload:
    def test_split_floor_n_over_2_total_retained(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 7})],
                 "enemy_ships": [ship("latin")]})
        s.start()
        unit = unit_of(s, "player", 0)
        assert s.side_cannons(unit, BROADSIDE_PORT) == 3   # floor(7/2)
        assert s.side_cannons(unit, BROADSIDE_STARBOARD) == 4
        assert unit["ship"]["cannons"] == 7                # the total retained
        even = sim({"player_ships": [ship("brigantine", {"cannons": 8})],
                    "enemy_ships": [ship("latin")]})
        even.start()
        eu = unit_of(even, "player", 0)
        assert even.side_cannons(eu, BROADSIDE_PORT) == 4
        assert even.side_cannons(eu, BROADSIDE_STARBOARD) == 4

    def test_signed_arcs(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 6})],
                 "enemy_ships": [ship("latin", {"cannons": 6})]})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "enemy", 0, (13, 15))  # dead astern of the east-facing player
        assert not s.can_cannon(gunner, target, BROADSIDE_PORT)
        assert not s.can_cannon(gunner, target, BROADSIDE_STARBOARD)
        place(s, "enemy", 0, (11, 14))  # NE: bearing bucket 1 → port arc
        assert s.can_cannon(gunner, target, BROADSIDE_PORT)
        assert not s.can_cannon(gunner, target, BROADSIDE_STARBOARD)
        place(s, "enemy", 0, (10, 13))  # N: bucket 2 → port arc
        assert s.can_cannon(gunner, target, BROADSIDE_PORT)
        place(s, "enemy", 0, (9, 14))  # NW: bucket 3 → port arc
        assert s.can_cannon(gunner, target, BROADSIDE_PORT)
        place(s, "enemy", 0, (11, 16))  # SE: bucket 7 → starboard arc
        assert not s.can_cannon(gunner, target, BROADSIDE_PORT)
        assert s.can_cannon(gunner, target, BROADSIDE_STARBOARD)
        place(s, "enemy", 0, (9, 16))  # SW: bucket 5 → starboard arc
        assert s.can_cannon(gunner, target, BROADSIDE_STARBOARD)
        place(s, "enemy", 0, (14, 15))  # dead ahead: bucket 0, neither arc
        assert not s.can_cannon(gunner, target)

    def test_range_band_and_factor_table(self) -> None:
        assert CANNON_RANGE_FACTOR == {1: 1.0, 2: 0.75, 3: 0.5}
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")],
                 "player_stats": person(0, 0)})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))  # range 1, port arc
        assert s.cannon_damage(gunner, target, BROADSIDE_PORT) == 10
        place(s, "enemy", 0, (12, 13))  # range 2
        assert s.cannon_damage(gunner, target, BROADSIDE_PORT) == 7
        place(s, "enemy", 0, (13, 12))  # range 3
        assert s.cannon_damage(gunner, target, BROADSIDE_PORT) == 5
        place(s, "enemy", 0, (14, 11))  # range 4 → out of range
        assert not s.can_cannon(gunner, target)

    def test_reload_clocks_are_independent(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop", {"durability": 200}),
                                 ship("sloop", {"durability": 200})],
                 "player_stats": person(0, gunnery=0)})
        s.start()
        gunner = unit_of(s, "player", 0)
        port_target = unit_of(s, "enemy", 0)
        star_target = unit_of(s, "enemy", 1)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))  # NE → port arc
        place(s, "enemy", 1, (11, 16))  # SE → starboard arc
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, port_target, BROADSIDE_PORT)
        assert result["ok"] and result["side"] == BROADSIDE_PORT
        # reload_port = round 1 + 2 turns = 3; starboard untouched.
        assert gunner["reload_port"] == 3
        assert gunner["reload_starboard"] == 1
        s.end_turn()               # spend the brig's fired turn
        begin_turn(s, "player", 0)  # walk the enemy slots into round 2
        assert s.round_number() == 2
        assert not s.can_cannon(gunner, port_target, BROADSIDE_PORT)
        # The starboard side reloaded independently (round 2 ≥ 1).
        assert s.can_cannon(gunner, star_target, BROADSIDE_STARBOARD)

    def test_reload_formula_closed_form(self) -> None:
        # gunnery 0/50/100 → 2/1/1 (clamp(2 − floor(g/50), 1, 2)).
        for gunnery, expected in ((0, 2), (49, 2), (50, 1), (100, 1)):
            s = sim({"player_ships": [ship("brigantine")],
                     "enemy_ships": [ship("latin")],
                     "player_stats": person(10, gunnery=gunnery)})
            s.start()
            assert s.reload_turns_of(unit_of(s, "player", 0)) == expected
        # Low crew (ratio < 0.5 vs crew_min) adds +1.
        s = sim({"player_ships": [ship("brigantine", {"crew": 9})],  # min 20
                 "enemy_ships": [ship("latin")],
                 "player_stats": person(10, gunnery=50)})
        s.start()
        assert s.reload_turns_of(unit_of(s, "player", 0)) == 2

    def test_legacy_gunnery_fallback(self) -> None:
        # A card-less pirate fleet reads 10 + 10 × tier 1 = 20.
        s = sim({"player_ships": [ship("brigantine")],
                 "enemy_ships": [ship("latin")]})
        s.start()
        assert s.gunnery_of(unit_of(s, "enemy", 0)) == 20
        navy = sim({"player_ships": [ship("brigantine")],
                    "enemy_ships": [ship("latin")], "enemy_kind": "navy"})
        navy.start()
        assert navy.gunnery_of(unit_of(navy, "enemy", 0)) == 30  # 10 + 10×2


# --- 6. Damage stack (§4.4, §4.4b, §4.11.5) ------------------------------------------------


class TestDamageStack:
    def test_range_factor_and_gunnery_bonus_rides_inside_the_base(self) -> None:
        # §4.4: port 5 of the brigantine's 10, bonus 0 at gunnery 0 —
        # the GDScript table: range 1 → 10, 2 → 7, 3 → 5.
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")], "player_stats": person(0, 0)})
        s.start()
        brig = unit_of(s, "player", 0)
        enemy = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))
        assert s.cannon_damage(brig, enemy, BROADSIDE_PORT) == 10
        # Gunnery 30 → +floor(30/25) = +1 rides INSIDE the floored base.
        s2 = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                  "enemy_ships": [ship("sloop")], "player_stats": person(0, 30)})
        s2.start()
        place(s2, "player", 0, (10, 15))
        place(s2, "enemy", 0, (11, 14))
        assert s2.cannon_bonus(unit_of(s2, "player", 0)) == 1
        assert s2.cannon_damage(unit_of(s2, "player", 0),
                                unit_of(s2, "enemy", 0), BROADSIDE_PORT) == 11

    def test_one_floor_stack_weather_rake_shot(self) -> None:
        """§4.4/§4.11.5: weather × rake × shot multiply with ONE floor after
        the weather term — the GDScript case table from base 10 (port 5,
        range 1, bonus 0)."""
        cases = [
            # (weather, rake, shot, gunnery, expected)
            ("calm", False, "round", 0, 10),
            ("storm", False, "round", 0, 7),    # floor(10 × 0.75)
            ("strong", False, "round", 0, 9),   # floor(10 × 0.9)
            ("calm", True, "round", 0, 12),     # floor(10 × 1.25)
            ("storm", True, "round", 0, 9),     # floor(10 × .75 × 1.25)
            ("strong", True, "round", 0, 11),   # floor(10 × .9 × 1.25)
            ("calm", False, "chain", 25, 8),    # base 11 → floor(11 × 0.75)
            ("calm", False, "armor_piercing", 50, 15),  # base 12 → ×1.25
        ]
        for weather, rake, shot, gunnery, expected in cases:
            s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                     "enemy_ships": [ship("sloop")], "weather": weather,
                     "player_stats": person(0, gunnery)})
            s.start()
            gunner = unit_of(s, "player", 0)
            target = unit_of(s, "enemy", 0)
            place(s, "player", 0, (10, 15))
            place(s, "enemy", 0, (11, 14))
            if rake:
                # The target faces NE: the attacker bears 180° off its bow.
                face(target, 1)
            begin_turn(s, "player", 0)
            volley = s.cannon(gunner, target, BROADSIDE_PORT, shot)
            assert volley["ok"], (weather, rake, shot)
            assert volley["damage"] == expected, (weather, rake, shot)
            if rake:
                assert volley["rake"] is True

    def test_constants(self) -> None:
        assert RAKE_MULTIPLIER == 1.25
        assert SALVAGE_FRACTION == 0.05
        assert (XP_PER_ENEMY_NEUTRALIZED, XP_PER_ROUND) == (10, 5)
        assert PIRATE_REP_GAIN == 2 and NAVY_REP_PENALTY == -20

    def test_grape_range_gate_and_halved_pair(self) -> None:
        stats = person(0, gunnery=100)
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")],
                 "player_stats": stats})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))  # range 1, port arc, no rake
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT, "grape")
        assert result["ok"] and result["shot"] == "grape"
        # same-range round = 10 (base 10, no bonus at gunnery 100? No — the
        # bonus rides inside: floor(100/25) = +4 → base 14 → round 14;
        # grape halves BOTH the hull damage and the crew kill (the kill IS
        # the volley's casualty term).
        assert result["damage"] == 7
        assert result["crew_kill"] == 7
        assert target["crew"] == max(10 - 7, 0)

    def test_grape_beyond_range_1_is_refused(self) -> None:
        stats = person(0, gunnery=100)
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")],
                 "player_stats": stats})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (12, 13))  # range 2
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT, "grape")
        assert result["ok"] is False
        assert result["shot"] == "grape" and result["range"] == 2
        # The refused volley spends neither the action nor the reload.
        assert gunner["reload_port"] == 1

    def test_shot_gates_are_data_driven(self) -> None:
        # The shipped data rows win: shot.chain 25, shot.armor_piercing 50.
        assert chain_shot_gate() == 25 == DEFAULT_CHAIN_GATE
        assert armor_piercing_gate() == 50 == DEFAULT_ARMOR_PIERCING_GATE
        row = {g["feature_id"]: g["threshold"]
               for g in data().skill_gates_list}
        assert row["shot.chain"] == 25 and row["shot.armor_piercing"] == 50
        # The S10 selector's disable-state read (the §4.4b gate at the
        # player's effective gunnery).
        from server.sim.combat.battle_sim import shot_unlocked
        assert shot_unlocked("round", 0)
        assert not shot_unlocked("chain", 24) and shot_unlocked("chain", 25)
        assert not shot_unlocked("armor_piercing", 49)
        assert shot_unlocked("armor_piercing", 50)

    def test_chain_and_armor_piercing_gates(self) -> None:
        # Below the chain gate: the volley is refused with the gate named,
        # and neither the action nor the reload is spent.
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")], "player_stats": person(0, 0)})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT, "chain")
        assert result["ok"] is False and result["locked"] is True
        assert result["gate"] == 25
        assert gunner["reload_port"] == 1
        s.hold(gunner)

        # At gunnery 25+: chain fires (base 11 → floor(11 × 0.75) = 8) and
        # slows the target: +2 debuff turns (§4.4b).
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")], "player_stats": person(0, 25)})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT, "chain")
        assert result["ok"] and result["shot"] == "chain"
        assert result["damage"] == 8
        assert target["speed_debuff_turns"] == 2
        # The debuff counts down at the FIRED-UPON ship's own turn END
        # (§4.3a — it must cover its next two turns).
        s.end_turn()
        begin_turn(s, "enemy", 0)
        s.end_turn()
        assert target["speed_debuff_turns"] == 1

        # Armor-piercing needs 50 (base 12 → floor(12 × 1.25) = 15).
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop")], "player_stats": person(0, 50)})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT, "armor_piercing")
        assert result["ok"] and result["shot"] == "armor_piercing"
        assert result["damage"] == 15

    def test_crew_casualties_and_clamp(self) -> None:
        # Standard /20, rake /10, clamped at 0 (correction 7).
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop", {"crew": 3})],
                 "player_stats": person(0, 0)})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT)
        assert result["damage"] == 10
        assert result["crew_kill"] == 0  # floor(10 / 20)
        assert target["crew"] == 3       # clamped at 0, never negative
        # A 0-crew ship still sails (§4.6a).
        assert target["alive"]


# --- 7. AI shot rule (§4.4b) --------------------------------------------------------------


class TestAiShotRule:
    def _arrangement(self, target_vel: tuple[int, int],
                     target_heading: int, armor: str = "",
                     attacker_gunnery: int | None = None) -> tuple[BattleSim, Any, Any]:
        stats = person(10, gunnery=100)
        enemy_overrides: dict[str, Any] = {"cannons": 6}
        if attacker_gunnery is not None:
            # The ship-carried `gunnery` key wins in `_gunnery_source`
            # (the W4-B compose seam) — the fixture's gate control.
            enemy_overrides["gunnery"] = attacker_gunnery
        s = sim({"player_ships": [ship("brigantine", {
                    "cannons": 10,
                    "equipment": {"figurehead": "", "sail": "", "armor": armor}})],
                 "enemy_ships": [ship("latin", enemy_overrides)],
                 "player_stats": stats})
        s.start()
        attacker = unit_of(s, "enemy", 0)
        target = unit_of(s, "player", 0)
        place(s, "player", 0, (12, 15))
        place(s, "enemy", 0, (11, 15))  # adjacent, port arc of the enemy
        target["vel"] = target_vel
        face(target, target_heading)
        return s, attacker, target

    def test_chain_on_fleeing_fast_target(self) -> None:
        s, attacker, target = self._arrangement((0, -2), HEADING_WEST,
                                                attacker_gunnery=30)
        # The target's vel strictly increases the Chebyshev distance and
        # the attacker's gunnery clears the 25 gate.
        assert s.ai_shot_type(attacker, target) == "chain"

    def test_chain_needs_the_gate(self) -> None:
        s, attacker, target = self._arrangement((0, -2), HEADING_WEST,
                                                attacker_gunnery=20)
        # gunnery 20 < 25: the chain branch refuses and the rule falls
        # through to the rating race (lost) → round.
        assert s.ai_shot_type(attacker, target) == "round"

    def test_grape_in_close_window_with_rating_edge(self) -> None:
        s, attacker, target = self._arrangement((0, 0), HEADING_EAST)
        # Adjacent, standing still: crew 15 + captain rating (legacy 6) vs
        # the player's 20 crew + 0 → the enemy loses the rating race → round.
        shot = s.ai_shot_type(attacker, target)
        assert shot in ("round", "grape")
        # With a crew edge the rule answers grape.
        attacker["crew"] = 40
        assert s.ai_shot_type(attacker, target) == "grape"

    def test_grape_falls_through_beyond_range_1(self) -> None:
        stats = person(10, gunnery=100)
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("latin", {"cannons": 6})],
                 "player_stats": stats})
        s.start()
        attacker = unit_of(s, "enemy", 0)
        target = unit_of(s, "player", 0)
        place(s, "player", 0, (13, 15))
        place(s, "enemy", 0, (11, 15))  # Chebyshev 2, standing still
        target["vel"] = (0, 0)
        attacker["crew"] = 40
        # Grape would win the window but is range 1 only → round.
        assert s.ai_shot_type(attacker, target) == "round"

    def test_armor_piercing_into_plated_player_ship(self) -> None:
        s, attacker, target = self._arrangement(
            (0, 0), HEADING_EAST, armor="eq_breastplate_slot_probe",
            attacker_gunnery=50)
        # The rule reads the target's `equipment.armor` slot; the item id
        # itself is only checked for non-emptiness (§4.4b rule 3).
        attacker["crew"] = 0  # drop out of the grape window
        assert s.ai_shot_type(attacker, target) == "armor_piercing"

    def test_armor_piercing_needs_the_gate(self) -> None:
        s, attacker, target = self._arrangement(
            (0, 0), HEADING_EAST, armor="eq_breastplate_slot_probe",
            attacker_gunnery=49)
        attacker["crew"] = 0
        assert s.ai_shot_type(attacker, target) == "round"

    def test_round_fall_through(self) -> None:
        s, attacker, target = self._arrangement((0, 0), HEADING_EAST)
        attacker["crew"] = 0
        assert s.ai_shot_type(attacker, target) == "round"


# --- 8. Sweep + ram (§4.5, §4.3a, §4.11.5) -------------------------------------------------


class TestSweepAndRam:
    def test_sweep_stops_at_enemy_cell_and_rams(self) -> None:
        s = sim({"player_ships": [ship("galley", {"cannons": 4, "vel": (2, 0)})],
                 "enemy_ships": [ship("latin", {"durability": 100})]})
        s.start()
        rammer = unit_of(s, "player", 0)
        victim = unit_of(s, "enemy", 0)
        place(s, "player", 0, (20, 15))
        place(s, "enemy", 0, (22, 15))
        rammer["vel"] = (2, 0)
        face(rammer, HEADING_EAST)
        face(victim, HEADING_WEST)
        s._moved_this_turn = False
        assert s.apply_velocity(rammer, (2, 0))
        # The sweep entered the enemy cell → the ram resolved; the mover
        # stays at the PRIOR cell.
        assert s.unit_cell(rammer) == (21, 15)
        # Galley attacker: mult = (1 + 0.25×(2−1)) × 1.15 (bow/stern on the
        # W-facing target) × 1.25 (oar) = 1.796875; att_max 70.
        # target floor(70 × 0.25 × 1.796875) = 31; self floor(70 × 0.10 × …) = 12.
        assert victim["ship"]["durability"] == 100 - 31
        assert rammer["ship"]["durability"] == 70 - 12

    def test_sweep_stops_at_friend_or_wall_with_zero_damage(self) -> None:
        s = sim({"player_ships": [ship("sloop"), ship("sloop")],
                 "enemy_ships": [ship("latin")]})
        s.start()
        mover = unit_of(s, "player", 0)
        friend = unit_of(s, "player", 1)
        place(s, "player", 0, (5, 5))
        place(s, "player", 1, (6, 5))
        s._moved_this_turn = False
        assert s.apply_velocity(mover, (1, 0))
        assert s.unit_cell(mover) == (5, 5)  # the prior cell
        assert mover["ship"]["durability"] == 60  # zero damage
        # Out-of-bounds: the sweep never leaves the grid.
        mover["vel"] = (0, 0)
        place(s, "player", 0, (0, 0))
        s._moved_this_turn = False
        assert s.apply_velocity(mover, (-1, 0))
        assert s.unit_cell(mover) == (0, 0)

    def test_action_ram_attacker_resolves_last(self) -> None:
        # A ram that sinks BOTH ships resolves the attacker last.
        s = sim({"player_ships": [ship("latin", {"durability": 3, "cannons": 0})],
                 "enemy_ships": [ship("latin", {"durability": 3})]})
        s.start()
        rammer = unit_of(s, "player", 0)
        victim = unit_of(s, "enemy", 0)
        place(s, "player", 0, (20, 15))
        place(s, "enemy", 0, (20, 16))
        rammer["vel"] = (0, 1)  # ‖vel‖ 1 → mult 1.0 ×1.0 (beam approach)
        face(rammer, HEADING_EAST)
        face(victim, HEADING_EAST)
        begin_turn(s, "player", 0)
        result = s.ram(rammer, victim)
        assert result["ok"]
        # att_max 40: target floor(40 × 0.25 × 1.0) = 10 → sunk;
        # self floor(40 × 0.10 × 1.0) = 4 → sunk. The ram (unlike cannon/
        # board) leaves the over-check to the turn wheel (§4.11.4 parity).
        assert result["sunk"] and result["attacker_sunk"]
        assert not s.is_over()
        s.end_turn()
        # The player's last hull went down with the ram → gameover.sunk
        # (60-* §6 "both ships sink from a ram — the attacker resolves last").
        assert s.is_over() and s.outcome()["result"] == "defeat_sunk"

    def test_ram_speed_multiplier(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 0})],
                 "enemy_ships": [ship("latin", {"durability": 200})]})
        s.start()
        rammer = unit_of(s, "player", 0)
        victim = unit_of(s, "enemy", 0)
        place(s, "player", 0, (20, 15))
        place(s, "enemy", 0, (20, 16))
        rammer["vel"] = (0, 3)  # floor‖vel‖ = 3 → mult 1.5
        face(rammer, HEADING_WEST)
        face(victim, 6)  # the attacker bears dead off its bow: ×1.15 → 1.725
        begin_turn(s, "player", 0)
        result = s.ram(rammer, victim)
        # target floor(110 × 0.25 × 1.725) = 47; self floor(110 × 0.10 × 1.725) = 18.
        assert result["damage"] == 47
        assert result["attacker_damage"] == 18


# --- 9. Hook & board (§4.6a, §4.11.6) ----------------------------------------------------------


class TestHookAndBoard:
    def _hooked(self, weather: str = "calm") -> tuple[BattleSim, Any, Any]:
        s = sim({"player_ships": [ship("brigantine", {"crew": 40})],
                 "enemy_ships": [ship("latin")], "weather": weather})
        s.start()
        boarder = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (20, 15))
        place(s, "enemy", 0, (20, 16))
        boarder["vel"] = (0, 1)
        face(boarder, HEADING_EAST)
        target["vel"] = (0, 0)
        return s, boarder, target

    def test_hook_preconditions_and_zeroing(self) -> None:
        s, boarder, target = self._hooked()
        assert s.can_board(boarder, target)
        # A fast target breaks the window.
        target["vel"] = (0, 2)
        assert not s.can_board(boarder, target)
        target["vel"] = (0, 0)
        begin_turn(s, "player", 0)
        result = s.board(boarder, target)
        assert result["ok"]
        # The hook zeroes BOTH velocities (correction 7).
        assert boarder["vel"] == (0, 0) and target["vel"] == (0, 0)
        assert result["duel"]["result"] in ("capture", "defeat")

    def test_storm_forbids_hooking(self) -> None:
        s, boarder, target = self._hooked("storm")
        assert not s.can_board(boarder, target)
        begin_turn(s, "player", 0)
        result = s.board(boarder, target)
        assert result["ok"] is False

    def test_duel_single_formula_pinned_sequences(self) -> None:
        assert DUEL_ROUND_MAX_ROLL == 20
        capture = resolve_duel(15, 10, GodotRng(33))
        assert capture == {"result": "capture", "rounds": ["win", "loss", "win", "win"],
                           "player_wins": 3, "defender_wins": 1}
        assert resolve_duel(15, 10, GodotRng(33)) == capture  # replay identical
        defeat = resolve_duel(15, 10, GodotRng(19))
        assert defeat["result"] == "defeat"
        assert defeat["rounds"] == ["loss", "win", "loss", "loss"]
        tied = resolve_duel(15, 10, GodotRng(2))
        assert "tie" in tied["rounds"] and tied["defender_wins"] == 0
        stuck = resolve_duel(15, 10, GodotRng(14))
        assert len(stuck["rounds"]) == 5 and stuck["result"] == "defeat"

    def test_duel_base_closed_forms(self) -> None:
        assert defender_duel_base(50, 6) == 16
        assert defender_duel_base(500, 6) == 26  # the crew term caps at 20
        assert defender_duel_base(0, 7) == 7
        assert (defender_charisma_bonus(10), defender_charisma_bonus(45),
                defender_charisma_bonus(85)) == (0, 2, 4)
        # The player base: swordplay + floor(courage/20) + worn combat deltas.
        stats = person(12)
        s = sim({"player_ships": [ship("brigantine")], "player_stats": stats})
        assert s.player_duel_base() == 12
        for swordplay, courage, expected in ((0, 10, 0), (30, 50, 32), (60, 100, 65)):
            s = sim({"player_ships": [ship("brigantine")],
                     "player_stats": person(swordplay, courage=courage)})
            assert s.player_duel_base() == expected
        # Worn weapon/armor combat modifiers stack (§4.11.12).
        cutlass = data().get_equipment("eq_cutlass")
        assert cutlass, "eq_cutlass must exist in shipped data"
        if int(cutlass.get("modifiers", {}).get("combat", 0)) != 3:
            pytest.skip("eq_cutlass combat modifier is not the doc's +3")
        s = sim({"player_ships": [ship("brigantine")],
                 "player_stats": {**person(12),
                                  "equipment": {"weapon": "eq_cutlass",
                                                "armor": "eq_cutlass"}}})
        assert s.player_duel_base() == 12 + 6


# --- 10. Stall (§4.11.9) ------------------------------------------------------------------------


class TestStall:
    def test_eight_quiet_rounds_stall_at_round_8(self) -> None:
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")]})
        outcome = s.run_to_completion(hold_policy, 40)
        assert outcome["result"] == "stall"
        assert outcome["rounds"] == STALL_ROUNDS == 8
        assert outcome["xp"] == 8 * XP_PER_ROUND == 40
        assert outcome["salvage_gold"] == 0

    def test_drift_breach_then_wall_stall_at_round_32(self) -> None:
        # An enemy drifting +1/round breaches the ±2 net window every 4th
        # quiet round (the anchor restarts each breach); the wall freezes it
        # at x = 47 from round 28, so the 8th quiet round completes at 32.
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "weather": "fair"})
        s.start()
        place(s, "player", 0, (2, 15))
        place(s, "enemy", 0, (20, 15))
        face(unit_of(s, "enemy", 0), HEADING_EAST)

        def drift(sim_: BattleSim, unit: dict[str, Any]) -> dict[str, Any]:
            if unit["side"] == "enemy":
                return {"action": "move", "vel": (1, 0)}
            return {"action": "hold"}

        outcome = s.run_to_completion(drift, 40)
        assert outcome["result"] == "stall"
        assert outcome["rounds"] == 32
        assert STALL_DISTANCE_DELTA == 2

    def test_volley_damage_resets_and_decides(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop", {"cannons": 0})]})
        s.start()
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (12, 13))  # port arc, Chebyshev 2

        def fire(sim_: BattleSim, unit: dict[str, Any]) -> dict[str, Any]:
            if unit["side"] == "enemy":
                return {"action": "hold"}
            for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
                for target in sim_.living_units("enemy"):
                    if sim_.can_cannon(unit, target, side):
                        return {"action": "cannon", "target": target,
                                "side": side, "shot": "round"}
            return {"action": "hold"}

        outcome = s.run_to_completion(fire, 40)
        assert outcome["result"] == "victory"
        assert outcome["rounds"] > STALL_ROUNDS


# --- 11. Initiative (§4.11.4 / §4.3) ----------------------------------------------------------------


class TestInitiative:
    def test_built_once_desc_speed_player_first(self) -> None:
        # Speeds: brigantine 24, galley 24, sloop 20, caravel 20,
        # latin 16 (+1 cotton sail → 17), latin 16.
        s = sim({
            "player_ships": [
                ship("brigantine"), ship("sloop"),
                ship("latin", {"equipment": {"figurehead": "",
                                             "sail": "eq_cotton_sails"}}),
            ],
            "enemy_ships": [ship("galley"), ship("caravel"), ship("latin")],
        })
        s.start()
        assert order_of(s, 6) == [
            "player:0", "enemy:0", "player:1", "enemy:1", "player:2", "enemy:2"]
        latin_unit = unit_of(s, "player", 2)
        assert s.initiative_key(latin_unit) == 17  # 16 + 1 sail delta

    def test_dead_slots_skip_and_order_never_resorts(self) -> None:
        s = sim({"player_ships": [ship("brigantine"),
                                  ship("sloop", {"durability": 1})],
                 "enemy_ships": [ship("galley", {"cannons": 4}), ship("caravel")]})
        s.start()
        order_of(s, 4)  # round 1 plays out untouched
        place(s, "enemy", 0, (7, 15))
        place(s, "player", 1, (6, 14))
        doomed = unit_of(s, "player", 1)
        begin_turn(s, "enemy", 0)
        # The sloop sits NW of the west-facing galley — the STARBOARD side
        # (the signed ccw step is 7; the W3 arc fix made this doc-exact).
        volley = s.cannon(unit_of(s, "enemy", 0), doomed, "starboard")
        assert volley["ok"] and volley["sunk"]
        s.end_turn()
        s.end_turn()  # e1's slot, then the wrap into round 3
        assert s.round_number() == 3
        assert order_of(s, 3) == ["player:0", "enemy:0", "enemy:1"]


# --- 12. Determinism & seed (§4.11.1) ------------------------------------------------------------------


class TestDeterminism:
    def test_seed_formula_and_override(self) -> None:
        formula = battle_seed_formula(12, (30, 40), 3000, 1)
        assert formula == 12 * 1000003 + 30 * 7919 + 40 * 104729 + 3000 * 31 + 1 * 17
        s = sim({"player_ships": [], "enemy_ships": [], "seed": 99})
        assert s.seed_value() == 99
        s2 = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                  "day": 5, "gold": 100, "contact": (10, 20)})
        assert s2.seed_value() == battle_seed_formula(5, (10, 20), 100, 1)
        assert s2.rng.seed == s2.seed_value()

    def test_shared_stream_replays_identically(self) -> None:
        stats = person(14)
        runs: list[tuple[str, str, str]] = []
        for _attempt in range(2):
            rng = GodotRng(4242)
            enemy = compose_enemy("pirate", 12, rng)
            s = sim({"player_ships": [ship("brigantine", cannons=10, crew=40)],
                     "enemy_ships": enemy, "day": 12, "gold": 3000,
                     "contact": (30, 40), "seed": 4242, "rng": rng,
                     "player_stats": stats})
            outcome = s.run_to_completion(fire_and_close_policy, MAX_ROUNDS)
            runs.append((json.dumps(s.log_lines(), sort_keys=True),
                         json.dumps(outcome, sort_keys=True),
                         str(outcome.get("result", ""))))
        assert runs[0][2] in ("victory", "defeat_sunk", "defeat_captured",
                              "retreat", "surrender", "stall")
        assert runs[0][0] == runs[1][0], "the same seed replays an identical log"
        assert runs[0][1] == runs[1][1], "the same seed replays an identical outcome"

    def test_engine_never_mutates_caller_ships(self) -> None:
        caller_fleet = [ship("brigantine", {"cannons": 10})]
        frozen = json.dumps(caller_fleet, sort_keys=True)
        s = sim({"player_ships": caller_fleet, "enemy_ships": [ship("latin")]})
        s.run_to_completion(fire_and_close_policy, MAX_ROUNDS)
        assert json.dumps(caller_fleet, sort_keys=True) == frozen

    def test_outcome_empty_until_over_and_capped_run(self) -> None:
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")]})
        s.start()
        assert s.outcome() == {}
        capped = sim({"player_ships": [ship("sloop")],
                      "enemy_ships": [ship("latin")]})
        result = capped.run_to_completion(hold_policy, 3)
        assert not capped.is_over()
        assert result["result"] == "" and result["over"] is False
        assert MAX_ROUNDS == 40


# --- 13. Snapshot / restore (§4.12.1) ---------------------------------------------------------------


class TestSnapshotRestore:
    def test_exact_invertibility_including_rng_state(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10, "crew": 40})],
                 "enemy_ships": [ship("latin", {"cannons": 4})]})
        s.start()
        # Advance a few turns so every scalar is non-trivial.
        for _ in range(3):
            u = s.current_unit()
            if u:
                s.hold(u)
            s.end_turn()
        snap = s.snapshot()
        expected_units = 1 + len(s.units()) * 13 + 23
        assert len(snap) == expected_units
        # Mutate everything observable.
        u = s.units()[0]
        u["pos"] = (5, 5)
        u["vel"] = (2, 1)
        u["heading8"] = 1
        u["crew"] = 1
        u["reload_port"] = 9
        u["reload_starboard"] = 9
        u["speed_debuff_turns"] = 2
        s.rng.randi()
        s._morale_event("player", -30)
        s.restore(snap)
        assert s.snapshot() == snap
        assert s.unit_cell(s.units()[0]) == (snap[1], snap[2])
        assert s.units()[0]["vel"] == (snap[3], snap[4])
        assert s.rng.state == snap[-3]
        assert s.side_morale("player") == snap[-2]

    def test_restore_rejects_size_mismatch(self) -> None:
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")]})
        s.start()
        snap = s.snapshot()
        s.restore(snap[:-1])  # untouched on a size mismatch
        assert s.snapshot() == snap


# --- 14. Side morale (§4.8a, §4.7) --------------------------------------------------------------


class TestSideMorale:
    def test_starts_config_and_card_formula(self) -> None:
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "player_morale": 55, "enemy_morale": 33})
        s.start()
        assert s.side_morale("player") == 55
        assert s.side_morale("enemy") == 33
        # Card courage 25 → clamp(40 + 25, 20, 90) = 65.
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "captain": "cap_morale_probe_65"})
        # No canon card with that id → the legacy fallback 10 + 10×tier 1 = 20
        # → clamp(40 + 20, 20, 90) = 60.
        s.start()
        assert s.side_morale("enemy") == 60
        # With a REAL canon card: the highest-courage card prices the AI
        # start at clamp(40 + courage, 20, 90).
        card_id, max_courage = max(
            ((cid, int(card.get("attributes", {}).get("courage", 0)))
             for cid, card in data().captains.items()),
            key=lambda pair: pair[1])
        assert max_courage > 0, "the canon roster must carry courage attributes"
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "captain": card_id})
        s.start()
        assert s.side_morale("enemy") == min(90, max(20, 40 + max_courage))
        # The 90 ceiling: a ship-carried courage 60 clamps the start.
        s = sim({"player_ships": [ship("sloop")],
                 "enemy_ships": [ship("latin", {"captain_courage": 60})]})
        s.start()
        assert s.side_morale("enemy") == 90
        # The ship-carried captain_courage key wins (the compose seam).
        s = sim({"player_ships": [ship("sloop")],
                 "enemy_ships": [ship("latin", {"captain_courage": 5})]})
        s.start()
        assert s.side_morale("enemy") == 45

    def test_event_table_both_sides_and_flagship_minus_30_total(self) -> None:
        s = sim({"player_ships": [ship("brigantine"), ship("sloop")],
                 "enemy_ships": [ship("latin"), ship("latin")],
                 "player_morale": 70, "enemy_morale": 70})
        s.start()
        assert MORALE_EVENT_FRIENDLY_SUNK == -15
        assert MORALE_EVENT_CAPTURED == -20
        assert MORALE_EVENT_FLAGSHIP_SUNK == -30
        assert MORALE_EVENT_RAKED == -5
        assert MORALE_EVENT_BOARDING_WIN == 10
        assert MORALE_EVENT_BOARDING_LOSS == -10
        # Enemy flagship (deployed index 0) sinks → −30 TOTAL, not −45.
        victim = unit_of(s, "enemy", 0)
        s._sink(victim, "player", "cannon")
        assert s.side_morale("enemy") == 40
        # A non-flagship friendly sink is −15 on the sufferer's side.
        escort = unit_of(s, "enemy", 1)
        s._sink(escort, "player", "cannon")
        assert s.side_morale("enemy") == 25
        # Player flagship sunk → player −30; then succession promotes index 1.
        flagship = unit_of(s, "player", 0)
        s._sink(flagship, "enemy", "cannon")
        assert s.side_morale("player") == 40
        assert s.flagship_index() == 1

    def test_rake_morale_and_morale_delta(self) -> None:
        stats = person(10, gunnery=0)
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop", {"cannons": 6})],
                 "player_morale": 50, "enemy_morale": 50,
                 "player_stats": stats})
        s.start()
        gunner = unit_of(s, "player", 0)
        target = unit_of(s, "enemy", 0)
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))  # NE → port arc
        face(target, 1)  # the attacker bears 180° off the target's bow → rake
        begin_turn(s, "player", 0)
        result = s.cannon(gunner, target, BROADSIDE_PORT)
        assert result["rake"] is True
        assert s.side_morale("enemy") == 45  # the rake −5 event
        s.retreat()
        assert s.outcome()["morale_delta"] == 0  # the player side never moved

    def test_clamps_and_surrender_widening(self) -> None:
        assert surrender_chance_for_courage(0) == 25
        assert surrender_chance_for_courage(100) == 15
        assert surrender_chance_for_courage(1000) == 10  # the floor
        # Effective courage clamps at 0 BEFORE the formula (maxi(courage, 0)),
        # so a negative card never raises the chance past the base 25.
        assert surrender_chance_for_courage(-50) == 25
        assert morale_surrender_bonus(-1) == 0           # the compat default
        assert morale_surrender_bonus(20) == 0
        assert morale_surrender_bonus(10) == 5
        assert morale_surrender_bonus(0) == 10           # the 50% ceiling
        assert MORALE_SURRENDER_GATE == 20
        assert MORALE_INSTANT_STRIKE == 10
        # The morales clamp after every event (0/100 ends).
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "player_morale": 5, "enemy_morale": 95})
        s.start()
        s._morale_event("player", -30)
        assert s.side_morale("player") == 0
        s._morale_event("enemy", 30)
        assert s.side_morale("enemy") == 100

    def test_instant_strike_ai_only(self) -> None:
        # Enemy side at morale ≤ 10: the engine strikes the AI ship with NO
        # roll, resolved as a capture; the player side NEVER auto-strikes.
        s = sim({"player_ships": [ship("brigantine"), ship("sloop")],
                 "enemy_ships": [ship("galley")],
                 "player_morale": 5, "enemy_morale": 10})
        s.start()
        # Order: brigantine 24 (tie → player first), galley 24, sloop 20.
        player_unit = s.current_unit()
        assert player_unit["side"] == "player"
        s._apply_decision(player_unit, {"action": "hold"})  # no forced strike
        assert unit_of(s, "player", 0)["alive"]
        s.end_turn()
        # Now the AI ship's turn: the engine strikes it regardless of the
        # decision the policy produced.
        enemy_unit = s.current_unit()
        assert enemy_unit["side"] == "enemy"
        s._apply_decision(enemy_unit, {"action": "hold"})
        assert not unit_of(s, "enemy", 0)["alive"]
        assert s.outcome()["surrendered_enemy"] == 1
        assert len(s.outcome()["captured_enemy"]) == 1

    def test_surrender_roll_uses_the_battle_stream(self) -> None:
        # The roll draws randf() from the battle stream: a fixed seed
        # either always surrenders or never does (deterministic).
        rolls = []
        for _ in range(2):
            s = sim({"player_ships": [ship("sloop")],
                     "enemy_ships": [ship("latin")], "seed": 7})
            s.start()
            u = unit_of(s, "enemy", 0)
            rolls.append(s.roll_surrender(u, 0, 10))  # widened chance 40%
        assert rolls[0] == rolls[1]


# --- 15. Economy pins in the outcome block (§4.11.10, §4.10, §4.12.2) ---------------------------


class TestOutcomeEconomy:
    def test_salvage_only_over_player_sunk_ships(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10})],
                 "enemy_ships": [ship("sloop", {"durability": 4})]})
        s.start()
        gunner = unit_of(s, "player", 0)
        wreck = unit_of(s, "enemy", 0)
        place(s, "enemy", 0, (11, 14))
        begin_turn(s, "player", 0)
        assert s.cannon(gunner, wreck, BROADSIDE_PORT)["sunk"]
        outcome = s.outcome()
        assert outcome["salvage_gold"] == int(3000 * 0.05) == 150
        assert outcome["xp"] == 1 * XP_PER_ENEMY_NEUTRALIZED + 1 * XP_PER_ROUND == 15
        assert outcome["rep_deltas"] == {
            n: PIRATE_REP_GAIN for n in rewards.nearest_nations((30, 40))}

    def test_navy_outcome_carries_no_rep_deltas(self) -> None:
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10, "crew": 40})],
                 "enemy_ships": [ship("sloop", {"durability": 1})],
                 "enemy_kind": "navy", "enemy_nation": "spain"})
        s.start()
        gunner = unit_of(s, "player", 0)
        place(s, "enemy", 0, (11, 14))
        begin_turn(s, "player", 0)
        s.cannon(gunner, unit_of(s, "enemy", 0), BROADSIDE_PORT)
        assert s.outcome()["rep_deltas"] == {}

    def test_retreat_forfeits_everything(self) -> None:
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")]})
        s.start()
        outcome = s.retreat()
        assert outcome["result"] == "retreat"
        assert outcome["xp"] == 0 and outcome["salvage_gold"] == 0
        assert outcome["rep_deltas"] == {}

    def test_player_surrender_outcomes(self) -> None:
        # To pirates: the fleet is retained (the hold goes — the caller's).
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")]})
        s.start()
        outcome = s.offer_surrender()
        assert outcome["result"] == "surrender" and outcome["lost_player"] == []
        # To a navy with a bounty: the flagship hull itself is taken; an
        # emptied fleet is defeat_captured.
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "enemy_kind": "navy", "enemy_nation": "spain"})
        s.start()
        outcome = s.offer_surrender()
        assert outcome["result"] == "defeat_captured"
        assert len(outcome["lost_player"]) == 1

    def test_nearest_port_nations_engine_matches_rewards(self) -> None:
        # The engine's private `_nearest_port_nations` and the rewards
        # module's `nearest_nations` must agree everywhere (the GDScript
        # economy suite asserts the same pair).
        contacts = [(30, 40), (2054, 620), (2047, 620), (2190, 438), (0, 0)]
        s = sim()
        for contact in contacts:
            s.contact = contact
            assert s._nearest_port_nations() == rewards.nearest_nations(contact)


# --- 16. Composition (§4.11.3, §4.11.11.2) ----------------------------------------------------------


class TestComposeEnemy:
    @pytest.mark.parametrize("kind", ["pirate", "navy"])
    def test_deterministic_within_pins(self, kind: str) -> None:
        goods_ids = {str(g.get("id", "")) for g in data().goods_list}
        for seed in range(1, 5):
            fleet_a = compose_enemy(kind, 45, GodotRng(seed))
            fleet_b = compose_enemy(kind, 45, GodotRng(seed))
            assert fleet_a and json.dumps(fleet_a, sort_keys=True) == json.dumps(
                fleet_b, sort_keys=True)
            expected_budget = (20 if kind == "pirate" else 30) + 45 // 30
            total_cannons = 0
            for entry in fleet_a:
                ship_type = data().get_ship_type(str(entry["ship_type_id"]))
                assert entry["ship_type_id"] in HULL_IDS
                assert entry["cannons"] <= ship_type["armament_slots"]
                total_cannons += entry["cannons"]
                assert entry["crew"] == ship_type["crew_min"]
                assert entry["durability"] == ship_type["durability"]
                cargo = entry["cargo"]
                expected_qty = max(1, int(ship_type["capacity"]) // CARGO_CAPACITY_DIVISOR)
                assert len(cargo) == 1
                assert next(iter(cargo)) in goods_ids
                assert next(iter(cargo.values())) == expected_qty
                # The §4.4 split is written at composition and sums to the total.
                assert entry["cannons_port"] + entry["cannons_starboard"] == entry["cannons"]
                assert entry["cannons_port"] == entry["cannons"] // 2
            assert total_cannons <= expected_budget
            size = len(fleet_a)
            if kind == "pirate":
                assert 1 <= size <= 3
            else:
                assert 2 <= size <= 4

    def test_cannon_budget_closed_forms(self) -> None:
        assert cannon_budget("pirate", 0) == 20
        assert cannon_budget("pirate", 59) == 21
        assert cannon_budget("navy", 0) == 30
        assert cannon_budget("navy", 90) == 33
        # The Phase-5 role map (§4.11.11.2).
        assert cannon_budget("trader", 0) == 6
        assert cannon_budget("coaster", 0) == 2
        assert cannon_budget("courier", 0) == 0
        assert cannon_budget("patrol", 0) == 30
        assert cannon_budget("privateer", 0) == 20
        assert cannon_budget("treasure", 0) == 30

    def test_count_bands_and_ship_carried_ratings_survive_the_sim(self) -> None:
        # A composed fleet priced through the sim keeps the §4.4 split (the
        # ship-carried pair sums to the total — the compose seam).
        rng = GodotRng(11)
        enemy = compose_enemy("pirate", 1, rng)
        for entry in enemy:
            entry["duel_rating"] = 6
            entry["cannon_rating"] = 7
            entry["captain_courage"] = 12
        s = sim({"player_ships": [ship("brigantine")], "enemy_ships": enemy})
        s.start()
        for u in s.units():
            if u["side"] == "enemy":
                assert u["captain_rating"] == 6      # the ship-carried wins
                assert u["cannon_rating"] == 7
                assert s.captain_courage(u) == 12    # the ship-carried courage


# --- 17. Profiles & the T2 priority list (§4.9a, §4.11.8) -------------------------------------------


def ai_sim(config: dict[str, Any]) -> BattleSim:
    """A hermetic sim whose enemy profile is forced to `ai_level = 0` (the
    free T2) via the S21 profile_override seam — the shipped rows carry
    `ai_level = 1` for the battle kinds, which dispatches the T3 search
    (another agent's module)."""
    return sim(config)


class TestT2Decisions:
    def test_profile_rows_from_npc_config(self) -> None:
        # Correction 8: hunter reads the navy row; unknown falls to pirate.
        assert profile_for("pirate")["archetype"] == "aggressive"
        assert profile_for("pirate")["ai_level"] == 1
        assert profile_for("hunter") == profile_for("navy")
        assert profile_for("navy")["focus"] == "flagship"
        assert profile_for("trader")["ai_level"] == 0
        assert profile_for("no_such_kind") == profile_for("pirate")

    def test_the_exact_nine_kind_profile_set(self) -> None:
        """docs/10-* §4.10: nine kinds × nine keys; the §4.9c archetype→
        ai_level mapping is the shipped data."""
        profiles = data().npc_config["ai_profiles"]
        assert set(profiles) == {
            "pirate", "privateer", "patrol", "navy", "tournament",
            "treasure", "trader", "coaster", "courier",
        }
        expected_levels = {
            "pirate": 1, "privateer": 1, "patrol": 1, "navy": 1,
            "tournament": 1, "treasure": 0, "trader": 0, "coaster": 0,
            "courier": 0,
        }
        expected_archetypes = {
            "pirate": "aggressive", "privateer": "aggressive",
            "patrol": "balanced", "navy": "balanced",
            "tournament": "balanced", "treasure": "cautious",
            "trader": "cautious", "coaster": "cautious",
            "courier": "cautious",
        }
        for kind, row in profiles.items():
            assert row["kind"] == kind
            assert row["ai_level"] == expected_levels[kind]
            assert row["archetype"] == expected_archetypes[kind]
            assert profile_for(kind) == row

    def test_flee_first_legal_velocity_increasing_distance(self) -> None:
        # The treasure profile: aggression 10 < 25 → unconditional flee.
        s = ai_sim({"player_ships": [ship("brigantine")],
                    "enemy_ships": [ship("latin")], "enemy_kind": "treasure"})
        s.start()
        fleer = unit_of(s, "enemy", 0)
        place(s, "enemy", 0, (30, 15))
        place(s, "player", 0, (20, 15))
        fleer["vel"] = (0, 0)
        decision = decide(s, fleer, profile_override={"ai_level": 0})
        assert decision["action"] == "move"
        # The FIRST (y, x)-lexicographic legal velocity whose LANDING
        # strictly increases the Chebyshev distance to the player.
        legal = s.legal_velocities(fleer)
        expected = next(v for v in legal
                        if cheb(landing(s, fleer, v), (20, 15)) > 10)
        assert decision["vel"] == expected

    def test_cornered_fleer_holds(self) -> None:
        s = ai_sim({"player_ships": [ship("brigantine")],
                    "enemy_ships": [ship("latin")], "enemy_kind": "treasure"})
        s.start()
        fleer = unit_of(s, "enemy", 0)
        place(s, "enemy", 0, (47, 0))
        place(s, "player", 0, (40, 0))
        fleer["vel"] = (0, 0)
        decision = decide(s, fleer, profile_override={"ai_level": 0})
        # Every landing from the corner reads ≤ the current distance → hold.
        assert decision["action"] == "hold"

    def test_fire_pick_rake_focus_side_tie_port(self) -> None:
        stats = person(10, gunnery=0)
        s = ai_sim({"player_ships": [ship("brigantine", {"cannons": 4})],
                    "enemy_ships": [ship("latin", {"cannons": 6})],
                    "player_stats": stats})
        s.start()
        gunner = unit_of(s, "enemy", 0)
        target = unit_of(s, "player", 0)
        place(s, "player", 0, (36, 14))  # NW of the enemy
        face(gunner, HEADING_WEST)
        # The enemy faces W; the player bears NW (bucket 3) off its heading
        # → signed steps (3 − 4 + 8) % 8 = 7 → STARBOARD arc.
        decision = decide(s, gunner, profile_override={"ai_level": 0,
                                                       "aggression": 90})
        assert decision["action"] == "cannon"
        assert decision["target"] is target
        assert decision["side"] == BROADSIDE_STARBOARD
        # The §4.4b shot type rides the decision.
        assert decision["shot"] == s.ai_shot_type(gunner, target)

    def test_board_ranks_above_ram(self) -> None:
        s = ai_sim({"player_ships": [ship("sloop")],
                    "enemy_ships": [ship("galley", {"crew": 100})]})
        s.start()
        boarder = unit_of(s, "enemy", 0)
        target = unit_of(s, "player", 0)
        place(s, "player", 0, (30, 15))
        place(s, "enemy", 0, (30, 16))  # adjacent; both at rest
        boarder["vel"] = (0, 0)
        target["vel"] = (0, 0)
        decision = decide(s, boarder, profile_override={"ai_level": 0,
                                                        "aggression": 90})
        # Hook legal AND crew+duel 120+6 > 20+0 → board (above ram).
        assert decision["action"] == "board"
        assert decision["target"] is target

    def test_close_decelerates_into_the_hook_window(self) -> None:
        # The player hull outranks the closer's cannons+duel rating, so the
        # ⑤ ram decision cannot fire and the priority list reaches ⑥ close.
        s = ai_sim({"player_ships": [ship("sloop", {"cannons": 6})],
                    "enemy_ships": [ship("latin")]})
        s.start()
        closer = unit_of(s, "enemy", 0)
        place(s, "player", 0, (30, 15))
        place(s, "enemy", 0, (32, 15))  # Chebyshev 2
        closer["vel"] = (-1, 0)
        face(closer, HEADING_WEST)
        decision = decide(s, closer, profile_override={"ai_level": 0,
                                                       "aggression": 90})
        assert decision["action"] == "move"
        # At Chebyshev ≤ 2 the first ‖vel‖ ≤ 1 pick that does not increase
        # the distance wins (the §4.6a window opens).
        assert vel_length(decision["vel"]) <= 1

    def test_ai_level_1_dispatches_to_ai_search(self) -> None:
        pytest.importorskip(
            "server.sim.combat.ai_search",
            reason="the T3 lookahead (ai_search) is a sibling M1 module; "
                   "this case skips cleanly until it merges")
        from server.sim.combat.ai_search import decide as ai_search_decide
        s = sim({"player_ships": [ship("brigantine")],
                 "enemy_ships": [ship("latin")]})  # pirate: ai_level 1
        s.start()
        actor = unit_of(s, "enemy", 0)
        decision = decide(s, actor)
        # The dispatch must route through the real search module (same
        # decision for the same state).
        direct = ai_search_decide(
            s, actor,
            __import__("server.sim.combat.ai_search", fromlist=["theta_for"])
            .theta_for(profile_for("pirate")["archetype"]),
            {})
        assert decision == direct

    def test_constants_are_the_doc_pins(self) -> None:
        assert FLEE_AGGRESSION_MAX == 25
        assert RAM_SPEED_MIN == 2
        assert BOARD_DURABILITY_PERCENT == 25
        assert FLEET_TIER == {"pirate": 1, "navy": 2, "tournament": 2}


# --- 18. battle_result (§4.11.7, §4.12.3) --------------------------------------------------------------


class TestBattleResult:
    def _outcome_with_capture(self) -> dict[str, Any]:
        hull = ship("sloop", durability=13, cargo={"rum": 3})
        return {"result": "victory", "captured_enemy": [hull],
                "lost_player": [], "sunk_player": [], "sunk_enemy": ["sloop"]}

    def test_capture_joins_at_25_percent_crew_0_cargo_intact(self) -> None:
        fleet = [ship("brigantine")]
        outcome = battle_result_mod.apply(self._outcome_with_capture(), [], fleet,
                                          idle_officer_ids=["off_1"])
        assert outcome["captured_ships"] == ["sloop"]
        assert outcome["capture_gate_failed"] == ""
        prize = fleet[1]
        assert prize["durability"] == max(1, 13 // 4)  # floor(13 × 0.25)
        assert prize["crew"] == 0
        # The §4.11.7 hold guard runs after the join: the rum survives the
        # battle (normalize_all pools it flagship-first — the 40-* rule).
        total_rum = sum(int(s["cargo"].get("rum", 0)) for s in fleet)
        assert total_rum == 3
        assert outcome["cargo_overflow_lost"] == 0
        assert outcome["game_over"] == ""

    def test_capture_gate_fleet_full_loot_converts_and_scuttles(self) -> None:
        fleet = [ship("brigantine") for _ in range(FLEET_MAX)]
        outcome = battle_result_mod.apply(self._outcome_with_capture(), [], fleet,
                                          idle_officer_ids=["off_1"])
        assert outcome["capture_gate_failed"] == "fleet_full"
        assert outcome["scuttled_ships"] == ["sloop"]
        assert outcome["captured_ships"] == []
        assert len(fleet) == FLEET_MAX
        # The loot-convert moved the prize's cargo into the fleet.
        total_rum = sum(int(s["cargo"].get("rum", 0)) for s in fleet)
        assert total_rum == 3
        assert outcome["game_over"] == ""

    def test_capture_gate_no_idle_officer(self) -> None:
        fleet = [ship("brigantine")]
        outcome = battle_result_mod.apply(self._outcome_with_capture(), [], fleet,
                                          idle_officer_ids=[])
        assert outcome["capture_gate_failed"] == "no_idle_officer"
        assert outcome["scuttled_ships"] == ["sloop"]

    def test_both_loss_lists_apply_and_flagship_marker(self) -> None:
        lost_hull = ship("sloop", durability=8)
        fleet = [ship("brigantine"), ship("sloop", durability=8)]
        outcome = {
            "result": "defeat_sunk",
            "captured_enemy": [],
            "lost_player": [lost_hull],
            "sunk_player": ["caravel"],
            "sunk_enemy": [],
        }
        fleet.append(ship("caravel"))
        outcome = battle_result_mod.apply(outcome, [], fleet, idle_officer_ids=[])
        # The lost hull (the flagship) was fleet[0]-shaped? No — fleet[0] is
        # the brigantine, so no flagship marker; the sloop left by type.
        assert outcome["lost_ships"] == ["sloop"]
        assert outcome["sunk_ships"] == ["caravel"]
        assert [s["ship_type_id"] for s in fleet] == ["brigantine"]
        assert outcome[battle_result_mod.FLAGSHIP_DUEL_LOST_KEY] is False
        assert outcome["game_over"] == ""

    def test_flagship_loss_marker_and_game_over_strings(self) -> None:
        lost_flagship = ship("brigantine", durability=5)
        fleet = [lost_flagship]
        outcome = {
            "result": "defeat_captured",
            "captured_enemy": [],
            "lost_player": [dict(lost_flagship)],
            "sunk_player": [],
            "sunk_enemy": [],
        }
        outcome = battle_result_mod.apply(outcome, [], fleet, idle_officer_ids=[])
        assert outcome[battle_result_mod.FLAGSHIP_DUEL_LOST_KEY] is True
        assert fleet == []
        assert outcome["game_over"] == "captured"

        fleet = [ship("brigantine")]
        outcome = {
            "result": "defeat_sunk", "captured_enemy": [],
            "lost_player": [], "sunk_player": ["brigantine"], "sunk_enemy": [],
        }
        outcome = battle_result_mod.apply(outcome, [], fleet, idle_officer_ids=[])
        assert outcome["game_over"] == "sunk"

    def test_captured_units_carry_the_enemy_index(self) -> None:
        enemy_units = [{"side": "enemy", "index": 2,
                        "ship": self._outcome_with_capture()["captured_enemy"][0]}]
        fleet = [ship("brigantine")]
        outcome = battle_result_mod.apply(self._outcome_with_capture(), enemy_units,
                                          fleet, idle_officer_ids=["off_1"])
        assert outcome["captured_units"] == [{"index": 2, "ship_type_id": "sloop"}]

    def test_normalize_overflow_reported(self) -> None:
        # A capture whose cargo overflows the fleet's pooled hold reports
        # the dropped units (§4.11.7 "Fleet.normalize_all() truncates it").
        hull = ship("sloop", cargo={"sugar": 10_000})
        fleet = [ship("brigantine", cargo={"sugar": 10_000})]
        outcome = battle_result_mod.apply(
            {"result": "victory", "captured_enemy": [hull], "lost_player": [],
             "sunk_player": [], "sunk_enemy": []},
            [], fleet, idle_officer_ids=["off_1"])
        assert outcome["cargo_overflow_lost"] > 0


# --- 19. battle_rewards (§4.11.10, §4.8a, §4.12.3) ------------------------------------------------------


class TestBattleRewards:
    def test_salvage_formula_on_hand_built_prices(self) -> None:
        assert rewards.salvage_for([]) == 0
        assert rewards.salvage_for(["sloop"]) == 150      # floor(3000 × 0.05)
        assert rewards.salvage_for(["brigantine"]) == 750  # floor(15000 × 0.05)
        # Per-hull flooring, not one floor over the sum.
        assert rewards.salvage_for(["latin", "galley", "galleon"]) == 60 + 500 + 3000
        assert rewards.salvage_for(["sloop", "sloop"]) == 300
        for entry in data().ship_types_list:
            expected = int(entry["base_price"] * 0.05)
            assert rewards.salvage_for([entry["id"]]) == expected
        assert rewards.salvage_for(["no_such_hull"]) == 0

    def test_xp_and_neutralised_formulas(self) -> None:
        assert rewards.xp_for(0, 0) == 0
        assert rewards.xp_for(1, 1) == 15
        assert rewards.xp_for(3, 6) == 60
        assert rewards.neutralised_for(
            {"sunk_enemy": ["sloop"], "captured_enemy": [ship("latin")],
             "surrendered_enemy": 1}) == 2  # the sub-tally is never added

    def test_nearest_nations_pins(self) -> None:
        assert rewards.NEAREST_PORT_COUNT == 2
        assert rewards.nearest_nations((2054, 620)) == ["portugal", "spain"]
        # Both nearest ports Portuguese → the nation is credited once.
        assert rewards.nearest_nations((2047, 620)) == ["portugal"]
        # The distance tie breaks by port id: amsterdam < london.
        assert rewards.nearest_nations((2190, 438)) == ["holland", "england"]

    def test_haul_valuation_and_battle_xp_multipliers(self) -> None:
        assert rewards.haul_multiplier(0, 0) == 1.0
        assert rewards.haul_multiplier(100, 100) == 1.5    # clamp at 1.5
        assert rewards.haul_gold(150, 100, 100) == 225
        assert rewards.haul_gold(150, 0, 0) == 150
        assert rewards.battle_xp_for(65, 0) == 65
        assert rewards.battle_xp_for(65, 20) == 130        # ×(1 + 20/20)
        assert rewards.battle_xp_for(10, 10) == 15         # floored once

    def test_apply_is_idempotent_and_moves_state_once(self) -> None:
        person_state = PersonState()
        person_state.player = {
            "xp": 0, "level": 1, "alloc_pending": 0,
            "reputation": {"portugal": 99, "spain": 0},
        }
        outcome: dict[str, Any] = {
            "result": "victory", "salvage_gold": 150, "xp": 65,
            "rep_deltas": {"portugal": 2, "spain": 2},
            "morale_delta": 10,
        }
        applied = rewards.apply(outcome, person_state, appraisal=100,
                                negotiation=100, morale_before=50, day=12)
        assert outcome["rewards_applied"] is True
        assert applied["gold"] == 225              # haul valuation 1.5×
        assert applied["xp"] == 68                 # floor(65 × 1.05) @ level 1
        assert person_state.player["xp"] == 68
        # The +2 at 99 reputation reports +1 (the ±100 clamp).
        assert applied["rep_deltas"] == {"portugal": 1, "spain": 2}
        assert person_state.player["reputation"]["portugal"] == 100
        assert applied["morale"] == 10             # 50 + 10, inside the band
        # A retried call for the same block pays nothing.
        second = rewards.apply(outcome, person_state, appraisal=100,
                               negotiation=100, morale_before=60, day=12)
        assert second["gold"] == 0 and second["xp"] == 0
        assert second["rep_deltas"] == {} and second["morale"] == 0

    def test_morale_writeback_clamps_both_ways(self) -> None:
        outcome = {"result": "victory", "salvage_gold": 0, "xp": 0,
                   "rep_deltas": {}, "morale_delta": 30}
        person_state = PersonState()
        person_state.player = {"xp": 0, "level": 1, "alloc_pending": 0,
                               "reputation": {}}
        applied = rewards.apply(dict(outcome), person_state, morale_before=90)
        assert applied["morale"] == 10  # clamped at 100
        outcome["morale_delta"] = -30
        applied = rewards.apply(dict(outcome), person_state, morale_before=10)
        assert applied["morale"] == -10  # clamped at 0

    def test_captain_lifecycle_no_ops_without_the_module_or_id(self) -> None:
        # Without a captain_id the hooks skip (the legacy fleets).
        report = rewards.apply_captain_lifecycle({"result": "victory"}, 12)
        assert report == {"captain_id": "", "defeat": False, "crushed": False,
                          "win": False, "nemesis_stance": 0}
        # The captain_id resolution: the threaded key wins, else the first
        # captured hull's own id.
        assert rewards.outcome_captain_id({"captain_id": "cap_x"}) == "cap_x"
        assert rewards.outcome_captain_id(
            {"captured_enemy": [{"captain_id": "cap_y"}]}) == "cap_y"
        assert rewards.outcome_captain_id({}) == ""
        assert rewards.crushed_victory(
            {"captured_ships": [], "surrendered_enemy": 0}) is True
        assert rewards.crushed_victory(
            {"captured_ships": ["sloop"], "surrendered_enemy": 0}) is False

    def test_named_pirate_drop_flow(self) -> None:
        named = next(iter(data().named_pirates))
        item_id = str(data().get_named_pirate(named)["drop"])
        item = data().get_equipment(item_id)
        slot = item["slot"]
        outcome: dict[str, Any] = {"result": "victory"}
        person_state = PersonState()
        person_state.player = {"xp": 0, "level": 1, "alloc_pending": 0,
                               "reputation": {},
                               "equipment": {"weapon": "", "armor": ""}}
        fleet = [ship("brigantine", equipment={"figurehead": "", "sail": ""})]
        granted = rewards.apply_named_drop(outcome, named, person_state, fleet)
        assert granted == item_id
        assert outcome["drop_item"] == item_id
        assert outcome["drop_sold_back"] == ""  # the slot was empty
        if slot in ("weapon", "armor"):
            assert person_state.player["equipment"][slot] == item_id
        else:
            assert fleet[0]["equipment"][slot] == item_id
        # An occupied slot names the displaced item for the sell-back
        # (the caller credits floor(price × 0.5) — the M1 purse seam).
        other = next(e for e in data().equipment_list
                     if e["slot"] == slot and e["id"] != item_id)
        outcome = {"result": "victory"}
        if slot in ("weapon", "armor"):
            person_state.player["equipment"][slot] = other["id"]
        else:
            fleet[0]["equipment"][slot] = other["id"]
        granted = rewards.apply_named_drop(outcome, named, person_state, fleet)
        assert granted == item_id
        assert outcome["drop_sold_back"] == other["id"]
        assert rewards.drop_sell_back_gold(other["id"]) == int(other["price"] * 0.5)
        # A captain with no famous-id match drops nothing.
        assert rewards.apply_named_drop({"result": "victory"}, "cap_not_famous",
                                        person_state, fleet) == ""
        # An empty outcome block is refused (the GDScript contract).
        assert rewards.apply_named_drop({}, named, person_state, fleet) == ""

    def test_piracy_attack_seam_reports_deltas(self) -> None:
        applied = rewards.apply_piracy_attack("spain", "", fame_before=30)
        assert applied["fame"] == -20  # floored at 0 only below 20
        assert applied["stance"] == 0  # no captain id, no captains module seam
        assert rewards.apply_piracy_attack("") == {
            "rep_deltas": {}, "fame": 0, "stance": 0}


# --- 20. Live-oracle golden traces (§4.11.1, §4.12.1) ---------------------------------


def _fire_or_hold(sim_: BattleSim, unit: dict[str, Any]) -> dict[str, Any]:
    """The probe's decisive-combat policy: an enemy holds, the player fires
    the first loaded broadside with a target in arc, else holds."""
    if unit.get("side") == "enemy":
        return {"action": "hold"}
    for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
        for target in sim_.living_units("enemy"):
            if sim_.can_cannon(unit, target, side):
                return {"action": "cannon", "target": target,
                        "side": side, "shot": "round"}
    return {"action": "hold"}


def _digest(value: Any) -> str:
    import hashlib
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


class TestLiveOracleTraces:
    """Golden traces recorded from the LIVE GDScript oracle (Godot
    4.7.stable.official.5b4e0cb0f, 2026-11-11) over the exact fixtures
    below. The digests pin the whole structured object without a giant
    literal — the same discipline the M5 golden-trace gate uses. Every
    trace exercised the RNG streams in the pinned order (composition →
    duel ``randi_range`` → surrender ``randf``)."""

    def _committed_trace(self) -> tuple[BattleSim, dict[str, Any]]:
        rng = GodotRng(4242)
        enemy = compose_enemy("pirate", 12, rng)
        s = sim({"player_ships": [ship("brigantine", {"cannons": 10, "crew": 40})],
                 "enemy_ships": enemy, "day": 12, "gold": 3000,
                 "contact": (30, 40), "seed": 4242, "rng": rng,
                 "player_stats": person(14)})
        s.start()
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (11, 14))
        place(s, "enemy", 1, (11, 16))
        place(s, "enemy", 2, (9, 14))
        for u in s.units():
            u["vel"] = (0, 0)
        outcome = s.run_to_completion(_fire_or_hold, MAX_ROUNDS)
        return s, outcome

    def test_decisive_cannon_battle_outcome_and_log(self) -> None:
        s, outcome = self._committed_trace()
        # The oracle: victory in 39 rounds, 1550 salvage, 225 XP, the three
        # composed hulls sunk by the player, Holland +2.
        assert outcome["result"] == "victory"
        assert outcome["rounds"] == 39
        assert outcome["salvage_gold"] == 1550
        assert outcome["sunk_enemy"] == ["caravel", "caravel", "brigantine"]
        assert outcome["xp"] == 225
        assert outcome["rep_deltas"] == {"holland": 2}
        assert outcome["sunk_player"] == [] and outcome["lost_player"] == []
        assert _digest(outcome) == (
            "3dfd705fccc4e91321cbc511a045eb6dc89ce32fd58d8436082ce7ce6b8c80e6")
        # The full action log is byte-identical to the oracle run (110
        # entries) — the RNG call order and every damage number.
        assert len(s.log_lines()) == 110
        first = s.log_lines()[0]
        assert first["kind"] == "cannon"
        assert first["values"]["damage"] == 10
        assert first["values"]["range"] == 1
        assert first["values"]["shot"] == "round"
        assert _digest(s.log_lines()) == (
            "6a1cd0c69243070062f772c3ea1fc042dab25cbf6f070ba3aca087e4281e9e01")

    def test_boarding_duel_trace(self) -> None:
        rng = GodotRng(33)
        s = sim({"player_ships": [ship("brigantine", {"crew": 40})],
                 "enemy_ships": [ship("sloop")], "day": 3,
                 "contact": (30, 40), "seed": 33, "rng": rng,
                 "player_stats": person(14)})
        s.start()
        place(s, "player", 0, (10, 15))
        place(s, "enemy", 0, (10, 16))
        for u in s.units():
            u["vel"] = (0, 0)
        result = s.board(unit_of(s, "player", 0), unit_of(s, "enemy", 0))
        # The oracle duel: capture 3–1 with win/loss/win/win (the §4.11.6
        # pinned seed-33 sequence, drawn from the battle stream after the
        # composition order).
        assert result["duel"] == {
            "result": "capture", "rounds": ["win", "loss", "win", "win"],
            "player_wins": 3, "defender_wins": 1,
        }
        assert _digest(result["duel"]) == (
            "9a65c4a7ea0568b395e11990a8f0d8822fd0797655e887944e789934a2247d22")
        outcome = s.outcome()
        assert outcome["result"] == "victory"
        assert outcome["xp"] == 15          # 10 neutralised + 5 rounds
        assert outcome["rep_deltas"] == {"holland": 2}
        assert len(outcome["captured_enemy"]) == 1
        assert outcome["captured_enemy"][0]["crew"] == 10
        assert _digest(outcome) == (
            "1416fae1f9d915c3cd7f7c651148733d2bbeba8b3fd0ba4afea6ecd023acd91a")

    def test_surrender_randf_stream(self) -> None:
        rng = GodotRng(99)
        s = sim({"player_ships": [ship("sloop")], "enemy_ships": [ship("latin")],
                 "seed": 99, "rng": rng, "player_stats": person(14)})
        s.start()
        enemy = unit_of(s, "enemy", 0)
        rolls = [s.roll_surrender(enemy, 5, 20) for _ in range(3)]
        assert rolls == [False, False, False]
        # The stream state after three randf() draws — the oracle's value.
        assert s.rng.state == 5964311404184323799


# --- 21. §4.12.4 zero-write fixture contract (the sandbox seam) -------------------------


class TestSandboxZeroWriteContract:
    def test_engine_and_modules_touch_only_injected_state(self) -> None:
        """§4.12.4 decision 15: NOTHING outside the injected containers is
        written. The engine's purity is structural (no run-state module
        exists in this package); here we pin that a full battle + aftermath
        sequence mutates only the passed fleet list / PersonState, so the
        sandbox branch can simply skip the callers."""
        fleet = [ship("brigantine", {"cannons": 10, "crew": 40})]
        person_state = PersonState()
        person_state.player = {"xp": 0, "level": 1, "alloc_pending": 0,
                               "reputation": {}}
        fleet_json = json.dumps(fleet, sort_keys=True)
        player_json = json.dumps(person_state.player, sort_keys=True)
        rng = GodotRng(77)
        enemy = compose_enemy("pirate", 4, rng)
        s = sim({"player_ships": [dict(fleet[0])], "enemy_ships": enemy,
                 "day": 4, "gold": 0, "contact": (30, 40), "seed": 77,
                 "rng": rng, "player_stats": person()})
        outcome = s.run_to_completion(fire_and_close_policy, MAX_ROUNDS)
        # The engine never touched the caller's fleet or the person state.
        assert json.dumps(fleet, sort_keys=True) == fleet_json
        assert json.dumps(person_state.player, sort_keys=True) == player_json
        if outcome["result"] == "victory":
            applied_fleet = battle_result_mod.apply(
                outcome, s.units(), fleet, idle_officer_ids=["off_1"])
            rewards.apply(applied_fleet, person_state, day=4)
            assert json.dumps(person_state.player, sort_keys=True) != player_json
