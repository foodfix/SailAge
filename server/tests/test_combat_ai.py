"""server.tests.test_combat_ai — the §4.9b/§4.9c/§4.11.6 combat-AI suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline). Oracles:
``scripts/combat/ai_search.gd`` + ``fleet_commander.gd`` + ``duel.gd`` and
their GDScript suites (``tools/test_ai_search.gd``,
``tools/test_fleet_command.gd``, ``tools/test_duel.gd``); docs/60-COMBAT.md
§4.9b, §4.9c, §4.11.1, §4.11.6, §4.11.8, §4.12.1.2, §4.12.3.

Pinned contracts:
  * §4.9c θ — the three CEM-finalized integer tables verbatim (the
    θ-finalization record in ``docs/IMPLEMENT-Phase9.md``: aggressive
    ``{8,4,6,−6,−2,−3,−3,−8,7}`` / balanced ``{6,5,7,−2,−3,−3,−5,−9,6}``
    / cautious ``{10,7,2,−9,−2,−3,−6,−10,3}``) + the archetype mapping over
    the nine shipped §4.10 rows;
  * §4.9c the search leaves no trace — snapshot() before == after (the
    candidates' dice roll back with ``rng.state``), the stream state
    unchanged, and two ``decide`` calls on the same state agree;
  * §4.9c/§4.11.8 the deterministic decisions on the oracle's hand-built
    two-ship fixtures: the free T3 hold, the disciplined station hold, the
    board candidate and the engage-assignment fire pick;
  * §4.9c the normative φ table's hand-computed totals (φ1/φ3/φ5/φ9);
  * §4.9b the state machine — form settled + 3-round bail-out, close with
    the hysteresis hold, engage→wear, the wear LOCK, wear→engage, the
    morale-20 break and its boundary 21;
  * §4.9b the four formation vocabularies, round-robin/focus-fire target
    assignment and the frozen assignment through wear/break;
  * §4.9b anchor succession (lowest living index, inherited state machine);
  * §4.11.6/§4.12.1.2 the duel — the pinned §5 scripted seed sequence and a
    mirror defeat seed through the delegated single formula;
  * §4.12.1.2 the S11 payload's per-round rolls (player-then-defender draw
    order) explain the round verdicts.

Deterministic — no Monte Carlo, no soaks; every seeded fixture replays a
fixed seed through the bit-exact :class:`~server.sim.rng.GodotRng`.
"""

from __future__ import annotations

import copy
from typing import Any

from server.sim.combat import ai_fleet
from server.sim.combat import duel
from server.sim.combat import fleet_commander as fc
from server.sim.combat.ai_search import (
    ALIGNMENT_MAX,
    BLOCKED_LANE_CHEBYSHEV,
    BLOCKED_LANE_MAX_CELLS,
    BLOCKED_LANE_MIN_CELLS,
    CANNON_DIFF_DIVISOR,
    DURABILITY_DIFF_DIVISOR,
    FLAGSHIP_LOW_DURABILITY_PERCENT,
    THETA_AGGRESSIVE,
    THETA_BALANCED,
    THETA_CAUTIOUS,
    _evaluate,
    decide as ai_search_decide,
    theta_for,
)
from server.sim.combat.battle_sim import (
    BROADSIDE_PORT,
    HEADING_EAST,
    HEADING_WEST,
    BattleSim,
    resolve_duel,
)
from server.sim.data import data
from server.sim.rng import GodotRng

# --- Fixtures ---------------------------------------------------------------


def person(swordplay: int = 10, courage: int = 10,
           charisma: int = 10) -> dict[str, Any]:
    """The Phase-8 Person-model player block (the GDScript ``_person``)."""
    return {
        "attributes": {"constitution": 10, "intellect": 10, "charisma": charisma,
                       "courage": courage, "luck": 10},
        "skills": {"seamanship": 0, "navigation": 0, "swordplay": swordplay,
                   "gunnery": 10, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0},
        "equipment": {"weapon": "", "armor": ""},
    }


def ship(ship_type_id: str, overrides: dict[str, Any] | None = None) -> dict[str, Any]:
    """A §4.11.11 ship instance; ``crew`` defaults to the hull's ``crew_min``."""
    ship_type = data().get_ship_type(ship_type_id)
    base: dict[str, Any] = {
        "ship_type_id": ship_type_id,
        "durability": int(ship_type.get("durability", 0)),
        "crew": int(ship_type.get("crew_min", 0)),
        "provisions": 0, "water": 0, "cannons": 0,
        "equipment": {"figurehead": "", "sail": ""},
        "cargo": {},
    }
    base.update(overrides or {})
    return base


def sim(config: dict[str, Any]) -> BattleSim:
    """A hermetic sim (current strength 0, calm — no raster leakage)."""
    full: dict[str, Any] = {
        "player_ships": [], "enemy_ships": [], "enemy_kind": "pirate",
        "enemy_nation": "", "day": 1, "gold": 0, "contact": (30, 40),
        "weather": "calm", "current": {"dir": "", "strength": 0},
        "player_stats": person(),
    }
    full.update(config)
    return BattleSim(full)


def unit_of(sim_: BattleSim, side: str, index: int) -> dict[str, Any]:
    return next(u for u in sim_.units()
                if u.get("side") == side and u.get("index") == index)


def place(sim_: BattleSim, side: str, index: int, cell: tuple[int, int]) -> None:
    unit_of(sim_, side, index)["pos"] = cell


def begin_turn(sim_: BattleSim, side: str, index: int) -> None:
    """Ends turns until ``side``/``index`` is acting — the T3 search applies
    its candidates through the live engine seam, which owns the §4.11.4
    acting cursor."""
    for _guard in range(16):
        current = sim_.current_unit()
        if not current:
            return
        if current["side"] == side and current["index"] == index:
            return
        sim_.end_turn()
    raise AssertionError(f"{side}/{index} never became the acting unit")


def hunter_fixture(seed_value: int = 911,
                   enemy_morale: int | None = None) -> BattleSim:
    """The oracle's ``_hunter_fixture``: an ai_level-1 latin at (10,15)
    heading east against an unarmed brigantine at (14,17) — off every hard
    gate, in T3 territory."""
    config: dict[str, Any] = {
        "player_ships": [ship("brigantine", {"cannons": 0})],
        "enemy_ships": [ship("latin", {"cannons": 4})], "seed": seed_value,
    }
    if enemy_morale is not None:
        config["enemy_morale"] = enemy_morale
    sim_ = sim(config)
    sim_.start()
    place(sim_, "player", 0, (14, 17))
    hunter = unit_of(sim_, "enemy", 0)
    place(sim_, "enemy", 0, (10, 15))
    hunter["heading8"] = HEADING_EAST
    hunter["vel"] = (0, 0)
    begin_turn(sim_, "enemy", 0)
    return sim_


def engage_order(station: tuple[int, int], assigned: int) -> dict[str, Any]:
    return {"station": station, "desired_heading8": 0,
            "desired_speed_band": [0, 2], "assigned_target": assigned,
            "discipline": True, "phase": "engage"}


# --- 1. θ (docs/60-* §4.9c) -------------------------------------------------


class TestThetaTables:
    def test_theta_tables_are_the_cem_final_constants(self) -> None:
        # Verbatim CEM output (docs/IMPLEMENT-Phase9.md θ-finalization /
        # §4.9c final table) — never re-tuned, never re-derived.
        assert THETA_AGGRESSIVE == (8, 4, 6, -6, -2, -3, -3, -8, 7)
        assert THETA_BALANCED == (6, 5, 7, -2, -3, -3, -5, -9, 6)
        assert THETA_CAUTIOUS == (10, 7, 2, -9, -2, -3, -6, -10, 3)

    def test_theta_for_maps_the_nine_shipped_rows(self) -> None:
        expected = {
            "pirate": THETA_AGGRESSIVE, "privateer": THETA_AGGRESSIVE,
            "patrol": THETA_BALANCED, "navy": THETA_BALANCED,
            "tournament": THETA_BALANCED,
            "treasure": THETA_CAUTIOUS, "trader": THETA_CAUTIOUS,
            "coaster": THETA_CAUTIOUS, "courier": THETA_CAUTIOUS,
        }
        for kind, theta in expected.items():
            archetype = str(ai_fleet.profile_for(kind).get("archetype", ""))
            assert theta_for(archetype) == list(theta), kind
        assert theta_for("no_such_archetype") == list(THETA_BALANCED)

    def test_feature_table_integers_are_the_doc_pins(self) -> None:
        # The φ formulas' own numbers (the §4.9c table).
        assert DURABILITY_DIFF_DIVISOR == 20
        assert CANNON_DIFF_DIVISOR == 4
        assert FLAGSHIP_LOW_DURABILITY_PERCENT == 25
        assert (BLOCKED_LANE_CHEBYSHEV, BLOCKED_LANE_MIN_CELLS,
                BLOCKED_LANE_MAX_CELLS) == (3, 1, 3)
        assert ALIGNMENT_MAX == 4


# --- 2. The search (docs/60-* §4.9c) ---------------------------------------


class TestSearch:
    def _board_fixture(self) -> BattleSim:
        """The §4.6a hook legal — a board candidate resolves a full §4.11.6
        duel with dice INSIDE the search."""
        sim_ = sim({
            "player_ships": [ship("sloop", {"cannons": 0, "crew": 10})],
            "enemy_ships": [ship("latin", {"cannons": 4, "crew": 40})],
            "seed": 99})
        sim_.start()
        place(sim_, "player", 0, (10, 16))
        boarder = unit_of(sim_, "enemy", 0)
        place(sim_, "enemy", 0, (10, 15))
        boarder["heading8"] = HEADING_EAST
        boarder["vel"] = (0, 0)
        begin_turn(sim_, "enemy", 0)
        return sim_

    def test_search_leaves_no_trace(self) -> None:
        sim_ = self._board_fixture()
        boarder = unit_of(sim_, "enemy", 0)
        assert sim_.can_board(boarder, unit_of(sim_, "player", 0))
        rng_before = sim_.rng.state
        pre = sim_.snapshot()
        decision = ai_fleet.decide(sim_, boarder)
        decision_again = ai_fleet.decide(sim_, boarder)
        # §4.9c: the candidates' dice are rolled back with rng.state — the
        # snapshot (which carries the stream) and the stream itself are
        # byte-identical, and the decision is deterministic.
        assert sim_.snapshot() == pre
        assert sim_.rng.state == rng_before
        assert decision == decision_again

    def test_free_t3_holds_in_the_hunter_fixture(self) -> None:
        # The oracle's pinned free-T3 pick under the finalized aggressive θ:
        # HOLD at the fixture cell (the learned φ trade scores holding best).
        sim_ = hunter_fixture()
        hunter = unit_of(sim_, "enemy", 0)
        station = sim_.unit_cell(hunter)
        decision = ai_fleet.decide(sim_, hunter)
        assert (decision["action"], decision["vel"]) == ("hold", (0, 0))
        assert (station[0] + decision["vel"][0],
                station[1] + decision["vel"][1]) == station

    def test_discipline_removes_off_station_candidates(self) -> None:
        sim_ = hunter_fixture()
        hunter = unit_of(sim_, "enemy", 0)
        station = sim_.unit_cell(hunter)
        disciplined = ai_fleet.decide(sim_, hunter, engage_order(station, -1))
        landing = (station[0] + disciplined["vel"][0],
                   station[1] + disciplined["vel"][1])
        # §4.9b: the disciplined engage ship holds its post exactly.
        assert landing == station

    def test_board_candidate_wins_the_hook_fixture(self) -> None:
        sim_ = self._board_fixture()
        boarder = unit_of(sim_, "enemy", 0)
        target = unit_of(sim_, "player", 0)
        decision = ai_fleet.decide(sim_, boarder)
        assert decision["action"] == "board"
        assert decision["target"] is target
        assert decision["vel"] == (0, 0)

    def test_engage_assignment_concentrates_the_guns(self) -> None:
        # The oracle's broadside-on fire-forcing fixture: a 14-cannon latin
        # at (10,15) heading east; player 0 dead-ahead at (13,15) (no arc),
        # the weak player 1 at (13,13) (port arc, range 3).
        sim_ = sim({
            "player_ships": [
                ship("sloop", {"cannons": 0, "durability": 60}),
                ship("sloop", {"cannons": 0, "durability": 20})],
            "enemy_ships": [ship("latin", {"cannons": 14})], "seed": 912})
        sim_.start()
        place(sim_, "player", 0, (13, 15))
        place(sim_, "player", 1, (13, 13))
        gunner = unit_of(sim_, "enemy", 0)
        place(sim_, "enemy", 0, (10, 15))
        gunner["heading8"] = HEADING_EAST
        gunner["vel"] = (0, 0)
        begin_turn(sim_, "enemy", 0)
        station = sim_.unit_cell(gunner)
        on_target = ai_fleet.decide(sim_, gunner, engage_order(station, 1))
        # The exact chosen candidate: hold + the port volley at ship 1.
        assert (on_target["action"], on_target["side"], on_target["vel"]) == (
            "cannon", BROADSIDE_PORT, (0, 0))
        assert on_target["target"]["index"] == 1
        # A dead assignment falls back to the free ranking.
        dead = ai_fleet.decide(sim_, gunner, engage_order(station, 7))
        assert dead["action"] == "cannon"
        assert dead["target"]["index"] in (0, 1)

    def test_phi_table_hand_computed_totals(self) -> None:
        # Fixture A (φ1/φ3): enemy sloop durability 20 of 60, 4 cannons both
        # sides loaded; player sloop 60 durability, starboard reloading.
        #   φ1 = (20 − 60)/20 = −2 → 6 × −2 = −12
        #   φ3 = (2 loaded − 1 loaded) → 7 × +1 = +7
        #   φ9 = bearing S (6) vs heading E (0) → 4 − 2 = 2 → 6 × 2 = +12
        #   Total: +7 (the finalized THETA_BALANCED).
        sim_a = sim({
            "player_ships": [ship("sloop", {"durability": 60, "cannons": 4})],
            "enemy_ships": [ship("sloop", {"durability": 20, "cannons": 4})],
            "seed": 7})
        sim_a.start()
        enemy_a = unit_of(sim_a, "enemy", 0)
        player_a = unit_of(sim_a, "player", 0)
        place(sim_a, "enemy", 0, (24, 15))
        place(sim_a, "player", 0, (24, 18))
        enemy_a["heading8"] = HEADING_EAST
        player_a["heading8"] = HEADING_EAST
        player_a["reload_starboard"] = 5
        assert _evaluate(sim_a, enemy_a, THETA_BALANCED, "enemy", "player",
                         False, (0, 0)) == 7
        # Restoring the player's starboard load zeroes φ3 → 7 − 7·1 = 0.
        player_a["reload_starboard"] = 1
        assert _evaluate(sim_a, enemy_a, THETA_BALANCED, "enemy", "player",
                         False, (0, 0)) == 0
        # Fixture B (φ5/φ9): player dead north at Chebyshev 3. Heading south
        # holds the deck line (φ5 = 1) with alignment 0 → −3. Heading west
        # escapes exposure (φ5 = 0) at 2 buckets off → 6 × 2 = +12.
        sim_b = sim({
            "player_ships": [ship("sloop", {"cannons": 0})],
            "enemy_ships": [ship("sloop", {"cannons": 0})], "seed": 7})
        sim_b.start()
        enemy_b = unit_of(sim_b, "enemy", 0)
        player_b = unit_of(sim_b, "player", 0)
        place(sim_b, "enemy", 0, (24, 15))
        place(sim_b, "player", 0, (24, 12))
        player_b["heading8"] = HEADING_EAST
        enemy_b["heading8"] = 6  # S
        assert _evaluate(sim_b, enemy_b, THETA_BALANCED, "enemy", "player",
                         False, (0, 0)) == -3
        enemy_b["heading8"] = HEADING_WEST
        assert _evaluate(sim_b, enemy_b, THETA_BALANCED, "enemy", "player",
                         False, (0, 0)) == 12

    def test_ai_fleet_dispatch_collects_and_matches_the_direct_call(self) -> None:
        # The previously skipped ai_fleet seam: ai_level 1 routes through the
        # real search module (same decision for the same state).
        sim_ = sim({"player_ships": [ship("brigantine")],
                    "enemy_ships": [ship("latin")]})  # pirate: ai_level 1
        sim_.start()
        actor = unit_of(sim_, "enemy", 0)
        dispatched = ai_fleet.decide(sim_, actor)
        direct = ai_search_decide(
            sim_, actor,
            theta_for(str(ai_fleet.profile_for("pirate")["archetype"])), {})
        assert dispatched == direct


# --- 3. The fleet-commander state machine (docs/60-* §4.9b) -----------------


def view_unit(side: str, index: int, cell: tuple[int, int], heading: int,
              durability: int, alive: bool = True) -> dict[str, Any]:
    return {"side": side, "index": index, "pos": cell, "vel": (0, 0),
            "heading8": heading,
            "ship": {"ship_type_id": "latin", "durability": durability},
            "alive": alive}


def view(units: list[dict[str, Any]], round_no: int = 1,
         side_morale: int | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"units": units, "round": round_no,
                           "enemy_kind": "navy"}
    if side_morale is not None:
        out["side_morale"] = side_morale
    return out


def line_view(side_morale: int | None = None) -> dict[str, Any]:
    """Three-ship AI line heading west, two player ships east of them."""
    return view([
        view_unit("enemy", 0, (40, 15), 4, 40),
        view_unit("enemy", 1, (41, 15), 4, 40),
        view_unit("enemy", 2, (42, 15), 4, 40),
        view_unit("player", 0, (20, 15), 0, 50),
        view_unit("player", 1, (22, 15), 0, 50),
    ], 1, side_morale)


def navy_profile(focus: str = "weakest", aggression: int = 60) -> dict[str, Any]:
    return {"kind": "navy", "archetype": "balanced", "aggression": aggression,
            "preferred_range": 3, "flee_below_hp_pct": 0, "focus": focus,
            "courage_mod": 0, "formation": "line_ahead", "ai_level": 1}


def order_by_index(orders: list[dict[str, Any]], index: int) -> dict[str, Any]:
    for entry in orders:
        if entry.get("index") == index:
            return entry["order"]
    return {}


def drive(state: dict[str, Any], view_: dict[str, Any],
          profile: dict[str, Any], rounds: int) -> list[str]:
    phases: list[str] = []
    for _index in range(rounds):
        fc.generate_orders(view_, profile, state)
        phases.append(str(state["phase"]))
    return phases


class TestFleetCommander:
    def test_five_tuple_determinism_and_purity(self) -> None:
        profile = navy_profile()
        state_a = fc.initial_state("line_ahead", (40, 15), 4)
        state_b = copy.deepcopy(state_a)
        view_a = line_view()
        view_b = copy.deepcopy(view_a)
        orders_a = fc.generate_orders(view_a, profile, state_a)
        orders_b = fc.generate_orders(view_b, profile, state_b)
        assert len(orders_a) == 3
        assert orders_a == orders_b
        assert state_a == state_b
        assert (state_a["phase"], state_a["phase_rounds"]) == ("form", 1)
        assert view_a == view_b
        first = order_by_index(orders_a, 0)
        assert set(first) == {"station", "desired_heading8",
                              "desired_speed_band", "assigned_target",
                              "discipline", "phase"}

    def test_form_close_engage_wear_transfer_table(self) -> None:
        profile = navy_profile()
        # form→close, settled: the exit needs the deviation ≤ 2 test AND the
        # ≥ 2-round hysteresis hold.
        settled = fc.initial_state("line_ahead", (40, 15), 4)
        assert drive(settled, line_view(), profile, 3) == [
            "form", "form", "close"]
        # form→close: the 3-round bail-out with ships scattered past
        # deviation 2 (the boundary lands on the 4th call).
        scattered = view([
            view_unit("enemy", 0, (30, 15), 4, 40),
            view_unit("enemy", 1, (40, 10), 4, 40),
            view_unit("enemy", 2, (40, 20), 4, 40),
            view_unit("player", 0, (20, 15), 0, 50),
            view_unit("player", 1, (22, 15), 0, 50),
        ])
        bailout = fc.initial_state("line_ahead", (40, 15), 4)
        assert drive(bailout, scattered, profile, 4) == [
            "form", "form", "form", "close"]
        # close→engage: within 5 from the first call, engage waits for the
        # ≥ 2-round hold; the anchor cruises one cell per round.
        closing = fc.initial_state("line_ahead", (40, 15), 4)
        closing["phase"] = fc.PHASE_CLOSE
        closing["phase_rounds"] = 0
        closing["anchor_pos"] = (40, 15)
        closing["anchor_heading"] = 4
        close_view = view([
            view_unit("enemy", 0, (40, 15), 4, 40),
            view_unit("enemy", 1, (41, 15), 4, 40),
            view_unit("enemy", 2, (42, 15), 4, 40),
            view_unit("player", 0, (36, 15), 0, 50),
            view_unit("player", 1, (22, 15), 0, 50),
        ])
        phases: list[str] = []
        anchor_track: list[int] = []
        for _index in range(3):
            fc.generate_orders(close_view, profile, closing)
            phases.append(str(closing["phase"]))
            anchor_track.append(closing["anchor_pos"][0])
        assert phases == ["close", "close", "engage"]
        assert anchor_track == [39, 38, 37]
        # Engage entry: perpendicular to the bearing W (4), tie → +90° → S.
        assert closing["anchor_heading"] == 6
        # engage→wear: the bearing turns parallel (N off the anchor); the
        # line_ahead exit is non-forced ⇒ hysteresis ≥ 2 first.
        engage_view = line_view()
        for unit in engage_view["units"]:
            if unit["side"] == "player" and unit["index"] == 0:
                unit["pos"] = (37, 10)  # bearing N off anchor (37,15)
        assert drive(closing, engage_view, profile, 3) == [
            "engage", "engage", "wear"]
        # Wear entry: old S (6), bearing N (2) → tie → clockwise E (0).
        assert closing["anchor_heading"] == 0

    def test_wear_lock_is_uninterruptible(self) -> None:
        profile = navy_profile()
        wear = fc.initial_state("line_ahead", (40, 15), 4)
        wear["phase"] = fc.PHASE_WEAR
        wear["phase_rounds"] = 1
        wear["anchor_heading"] = 0
        lock_view = line_view()
        for unit in lock_view["units"]:
            if unit["side"] == "enemy":
                unit["heading8"] = 4  # far from the wear heading 0
        assert drive(wear, lock_view, profile, 1) == ["wear"]
        for unit in lock_view["units"]:
            if unit["side"] == "player" and unit["index"] == 0:
                unit["pos"] = (31, 11)  # the bearing flips mid-wear
        assert drive(wear, lock_view, profile, 1) == ["wear"]
        # Every living ship within ±1 bucket ⇒ back to engage, heading
        # perpendicular to the NEW bearing.
        for unit in lock_view["units"]:
            if unit["side"] == "enemy":
                unit["heading8"] = 0
        assert drive(wear, lock_view, profile, 1) == ["engage"]
        assert wear["anchor_heading"] == 1

    def test_morale_break_is_forced_terminal_and_bounded(self) -> None:
        # side morale ≤ 20 ⇒ break, forced from any line state, terminal.
        for phase in (fc.PHASE_FORM, fc.PHASE_CLOSE, fc.PHASE_ENGAGE,
                      fc.PHASE_WEAR):
            broken = fc.initial_state("line_ahead", (40, 15), 4)
            broken["phase"] = phase
            fc.generate_orders(line_view(20), navy_profile(), broken)
            assert broken["phase"] == fc.PHASE_BREAK, phase
        terminal = fc.initial_state("line_ahead", (40, 15), 4)
        terminal["phase"] = fc.PHASE_BREAK
        fc.generate_orders(line_view(80), navy_profile(), terminal)
        assert terminal["phase"] == fc.PHASE_BREAK
        # The boundary: morale 21 stays short of the break gate.
        boundary = fc.initial_state("line_ahead", (40, 15), 4)
        boundary["phase"] = fc.PHASE_CLOSE
        fc.generate_orders(line_view(21), navy_profile(), boundary)
        assert boundary["phase"] == fc.PHASE_CLOSE

    def test_formations(self) -> None:
        profile = navy_profile()
        # line_ahead: stations trail the anchor on the reciprocal ray.
        line = fc.initial_state("line_ahead", (40, 15), 4)
        line_orders = fc.generate_orders(line_view(), profile, line)
        assert [order_by_index(line_orders, i)["station"]
                for i in range(3)] == [(40, 15), (41, 15), (42, 15)]
        assert order_by_index(line_orders, 1)["desired_heading8"] == 4
        assert order_by_index(line_orders, 1)["discipline"] is False
        # column: lateral spacing (the ray turns +90°).
        column = fc.initial_state("column", (40, 15), 4)
        column_orders = fc.generate_orders(line_view(), profile, column)
        assert order_by_index(column_orders, 1)["station"] == (40, 14)
        # screen: never walks the line states — not even the morale break;
        # the station is the screen center (the anchor), free fire.
        screen = fc.initial_state("screen", (40, 15), 4)
        assert drive(screen, line_view(10), profile, 3) == [
            "screen", "screen", "screen"]
        screen_order = order_by_index(
            fc.generate_orders(line_view(), profile, screen), 2)
        assert screen_order["station"] == (40, 15)
        assert screen_order["discipline"] is False
        assert screen_order["assigned_target"] == -1
        # swarm: assignment only — station = own cell, no discipline.
        swarm = fc.initial_state("swarm", (40, 15), 4)
        swarm_order = order_by_index(
            fc.generate_orders(line_view(), profile, swarm), 1)
        assert swarm["phase"] == fc.PHASE_SWARM
        assert swarm_order["station"] == (41, 15)
        assert swarm_order["discipline"] is False
        assert swarm_order["assigned_target"] >= 0

    def _assignment_view(self) -> dict[str, Any]:
        return view([
            view_unit("enemy", 0, (40, 15), 4, 40),
            view_unit("enemy", 1, (41, 15), 4, 40),
            view_unit("enemy", 2, (42, 15), 4, 40),
            view_unit("enemy", 3, (43, 15), 4, 40),
            view_unit("player", 0, (36, 15), 0, 50),
            view_unit("player", 1, (38, 12), 0, 40),
            view_unit("player", 2, (30, 18), 0, 30),
        ])

    def test_target_assignment_round_robin_focus_fire_and_freeze(self) -> None:
        # Round-robin over the focus order (weakest: durability 30, 40, 50 →
        # indices 2, 1, 0), ships in fleet-index order, wrapping.
        engage = fc.initial_state("line_ahead", (40, 15), 4)
        engage["phase"] = fc.PHASE_ENGAGE
        orders = fc.generate_orders(self._assignment_view(),
                                    navy_profile("weakest", 60), engage)
        assert engage["assignments"] == {0: 2, 1: 1, 2: 0, 3: 2}
        assert order_by_index(orders, 2)["assigned_target"] == 0
        # aggression ≥ 80: the whole fleet focus-fires the focus-top target.
        focus = fc.initial_state("line_ahead", (40, 15), 4)
        focus["phase"] = fc.PHASE_ENGAGE
        fc.generate_orders(self._assignment_view(),
                           navy_profile("weakest", 85), focus)
        assert focus["assignments"] == {0: 2, 1: 2, 2: 2, 3: 2}
        # Assignments freeze through wear and break.
        engaged = dict(engage["assignments"])
        frozen = copy.deepcopy(engage)
        frozen["phase"] = fc.PHASE_WEAR
        wear_view = self._assignment_view()
        for unit in wear_view["units"]:
            if unit["side"] == "enemy":
                unit["heading8"] = 4  # misaligned ⇒ the wear lock holds
        fc.generate_orders(wear_view, navy_profile(), frozen)
        assert frozen["assignments"] == engaged
        broken = copy.deepcopy(engage)
        broken["phase"] = fc.PHASE_BREAK
        break_orders = fc.generate_orders(self._assignment_view(),
                                          navy_profile(), broken)
        assert broken["assignments"] == engaged
        assert order_by_index(break_orders, 1)["assigned_target"] == engaged[1]

    def test_anchor_succession(self) -> None:
        profile = navy_profile()
        state = fc.initial_state("line_ahead", (40, 15), 4)
        state["phase"] = fc.PHASE_ENGAGE
        battle_view = view([
            view_unit("enemy", 0, (40, 15), 4, 40),
            view_unit("enemy", 1, (41, 15), 4, 40),
            view_unit("enemy", 2, (42, 15), 4, 40),
            view_unit("player", 0, (36, 15), 0, 30),
            view_unit("player", 1, (38, 12), 0, 50),
            view_unit("player", 2, (30, 18), 0, 50),
        ])
        fc.generate_orders(battle_view, profile, state)
        assignments = dict(state["assignments"])
        assert len(assignments) == 3
        # Forced break keeps the distribution, then the flagship sinks: the
        # LOWEST living index takes anchor pos + heading8 and the state
        # machine inherits unchanged.
        morale_view = view(copy.deepcopy(battle_view["units"]), 1, 15)
        fc.generate_orders(morale_view, profile, state)
        assert (state["phase"], state["assignments"]) == (
            fc.PHASE_BREAK, assignments)
        successor_view = view(copy.deepcopy(battle_view["units"]), 1, 15)
        for unit in successor_view["units"]:
            if unit["side"] == "enemy" and unit["index"] == 0:
                unit["alive"] = False
            if unit["side"] == "enemy" and unit["index"] == 1:
                unit["heading8"] = 2  # N — distinguishable from the old anchor
        fc.generate_orders(successor_view, profile, state)
        assert state["flagship_down"] is True
        assert (state["anchor_pos"], state["anchor_heading"]) == ((41, 14), 2)
        assert (state["phase"], state["assignments"]) == (
            fc.PHASE_BREAK, assignments)
        # Stable while the holder lives.
        held = order_by_index(
            fc.generate_orders(successor_view, profile, state), 1)
        held_again = order_by_index(
            fc.generate_orders(successor_view, profile, state), 1)
        assert held["assigned_target"] == assignments[1]
        assert held_again["assigned_target"] == assignments[1]
        # The successor dies too → the anchor re-reads onto the next lowest.
        for unit in successor_view["units"]:
            if unit["side"] == "enemy" and unit["index"] == 1:
                unit["alive"] = False
            if unit["side"] == "enemy" and unit["index"] == 2:
                unit["heading8"] = 6  # S
        fc.generate_orders(successor_view, profile, state)
        assert (state["anchor_pos"], state["anchor_heading"]) == ((42, 16), 6)


# --- 4. The duel (docs/60-* §4.11.6, §4.12.1.2) -----------------------------


class TestDuel:
    #: The §5 scripted duel: player base 15 vs defender base 10, seed 33 →
    #: win/loss/win/win, 3–1.
    DOC_PLAYER_BASE = 15
    DOC_DEFENDER_BASE = 10
    DOC_SEED = 33
    DOC_ROUNDS = ["win", "loss", "win", "win"]

    def test_bases_and_legacy_captain_rating(self) -> None:
        stats = person(swordplay=12)
        stats["equipment"] = {"weapon": "eq_cutlass", "armor": "eq_breastplate"}
        assert duel.player_base(stats) == 12 + 3 + 2  # swordplay + combat mods
        # §4.11.6 defender base: min(floor(crew / 5), 20) + captain rating.
        assert duel.defender_base(20, 6) == 10
        assert duel.defender_base(100, 6) == 26
        assert duel.defender_base(19, 6) == 9
        assert duel.defender_charisma_bonus(85) == 4
        # §4.6 legacy 5 + fleet tier (pirate 1, navy 2).
        assert duel.captain_rating(1) == 6
        assert duel.captain_rating(2) == 7

    def test_scripted_capture_seed_and_mirror_defeat_seed(self) -> None:
        outcome = duel.start({"player_base": self.DOC_PLAYER_BASE,
                              "defender_base": self.DOC_DEFENDER_BASE,
                              "seed": self.DOC_SEED})
        assert outcome["rounds"] == self.DOC_ROUNDS
        assert (outcome["result"], outcome["player_wins"],
                outcome["defender_wins"]) == ("capture", 3, 1)
        # Best-of-N on the pinned mirror seed: loss/win/loss/loss, 3–1 the
        # other way → defeat.
        defeat = duel.start({"player_base": self.DOC_PLAYER_BASE,
                             "defender_base": self.DOC_DEFENDER_BASE,
                             "seed": 19})
        assert defeat["rounds"] == ["loss", "win", "loss", "loss"]
        assert (defeat["result"], defeat["player_wins"],
                defeat["defender_wins"]) == ("defeat", 1, 3)

    def test_start_is_the_delegated_single_formula(self) -> None:
        expected = resolve_duel(self.DOC_PLAYER_BASE, self.DOC_DEFENDER_BASE,
                                GodotRng(self.DOC_SEED))
        via_start = duel.start({"player_base": self.DOC_PLAYER_BASE,
                                "defender_base": self.DOC_DEFENDER_BASE,
                                "seed": self.DOC_SEED})
        assert via_start == expected
        # A handed-over stream continues instead of reseeding (§4.11.1).
        via_rng = duel.start({"player_base": self.DOC_PLAYER_BASE,
                              "defender_base": self.DOC_DEFENDER_BASE,
                              "rng": GodotRng(self.DOC_SEED)})
        assert via_rng == expected

    def test_preview_rolls_explain_the_round_verdicts(self) -> None:
        payload = duel.preview({"player_base": self.DOC_PLAYER_BASE,
                                "defender_base": self.DOC_DEFENDER_BASE,
                                "seed": self.DOC_SEED,
                                "attacker_name": "You",
                                "defender_name": "Pirate captain",
                                "ship_name": "Sloop"})
        assert payload["outcome"]["rounds"] == self.DOC_ROUNDS
        rolls = payload["rolls"]
        assert len(rolls) == len(self.DOC_ROUNDS)
        for roll, verdict in zip(rolls, self.DOC_ROUNDS):
            assert self.DOC_PLAYER_BASE <= roll["player"] <= self.DOC_PLAYER_BASE + 20
            assert self.DOC_DEFENDER_BASE <= roll["defender"] \
                <= self.DOC_DEFENDER_BASE + 20
            expected = ("win" if roll["player"] > roll["defender"]
                        else "loss" if roll["defender"] > roll["player"]
                        else "tie")
            assert verdict == expected
        assert (payload["player_base"], payload["defender_base"]) == (
            self.DOC_PLAYER_BASE, self.DOC_DEFENDER_BASE)
        assert (payload["attacker_name"], payload["defender_name"],
                payload["ship_name"]) == ("You", "Pirate captain", "Sloop")
        # The presentation payload never re-runs the duel: the outcome is
        # the same dictionary a direct call produces.
        assert payload["outcome"] == resolve_duel(
            self.DOC_PLAYER_BASE, self.DOC_DEFENDER_BASE,
            GodotRng(self.DOC_SEED))
