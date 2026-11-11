"""server.tests.test_sailing — the sailing-core parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_sailing.gd`` T6/T7, ``tools/test_weather.gd``
T8, ``tools/test_morale.gd`` T9, ``tools/test_movement.gd`` G/H/F, and
``tools/test_port_hours.gd``) boot runs and walk the autoloads; here the
same pinned contracts are asserted as pure functions over injected state on
the real shipped ``data/`` tree (loaded through :mod:`server.sim.data`) and
the real world/ocean rasters (:mod:`server.sim.world.raster`).

Pinned contracts — ledger (oracle: ``scripts/world/sailing_sim.gd``;
docs/20 §4.5/§4.8/§4.9):
  * the §5 constants block verbatim (wage 2, ration 5, prices 2/1,
    sighting 48/÷12, discovery 36/÷15, morale 70/80, starvation 7, mutiny
    20/0.25, desertion 40/0.10, storm 0.05/÷250/÷400/÷300, charisma ÷200,
    scurvy grace ÷10, the Phase-8 hooks ×0.8/−2, at-sea repair 10/60/÷20);
  * step 1 consumption per ``RATION_SIZE`` across a hand-built fleet (15 →
    3+3, 16 → 4+4, the shortfall clamp + flags, flagship-first pooling,
    crew 0, the empty fleet);
  * step 2 wages (15×2 = 30, officer +30 → 60, the purse clamp → unpaid
    flag + one ``gold_changed`` with 0, exactly-affordable pays);
  * the §4.8.1 delta matrix — sea −1, shortfall −5+−5, storm −5 (−4 at CON
    100, round-half-away), captain-less −2, in-port +5 capped at 80 (never
    capped up, never suppressing a sea loss), unpaid −5 anywhere, the [0,
    100] clamp;
  * §4.9 fail states — the starvation trace [14..8] with game over exactly
    on tick 7, the scurvy grace thresholds (8 at CON 10, 17 at CON 100,
    10 with a medicine-30 surgeon), the counter reset on the first
    supplied day, the crew-loss floor at 1, sinking (sunk / relocation /
    escort loss with the §4.7 dialog order);
  * §4.8.3 mutiny — the 0.7627 closed form, the strict < 20 threshold, no
    mutiny in port, the charisma multiplier table, the three resolutions
    (pay/suppress/fizzle) on pinned offers, the one-modal-per-hit dialog
    queue.

Pinned contracts — weather (docs/20 §4.7/§4.7.1):
  * the five locked band tables exact at luck 0, normalised at every luck;
  * band classification by latitude (every locked edge, both hemispheres,
    the total ≥ 70 behaviour);
  * the luck-10 table == the §4.2 closed form (storm' = storm × (1 −
    luck/400), the freed mass redistributed by base weight) — exact, plus
    the seeded 500-roll spot sample per band (±0.06 ≈ 3σ);
  * storm damage: caravel 90 → 5/5/3 at luck 0/10/100, the before-rounding
    pin (luck 49 → 4), the whole-hull table, the two-ship fleet
    application (5 + 7 = 12), the durability clamp;
  * the strength → direction roll ORDER pinned by seeded GodotRng replay
    (the same seed replays the same sequence; a swapped roll order
    produces different directions);
  * the §4.7 reachability arithmetic (1 − 0.65⁶ = 0.9246 ≥ 0.90).

Pinned contracts — movement (docs/20 §4.2/§4.4/§4.18):
  * the §4.4 speed table (fair/calm/storm × classes, the storm headway at
    COU 10/100, the skeleton-crew 0.25 floor, the slowest-hull scan with
    the captain-less ×0.8, the oar exemption, hybrid 1.1);
  * the direction-factor buckets × classes, the trim speed matrix, furled
    0 with the oar rowing exemption, the heading-aware move_cost, night
    sail 2× with the navigation ≥ 40 exemption;
  * 8-dir legality: wrap, no corner cutting (the real-map corner), the
    §4.18 ice refusal matrix (in-month/out-month/standing-fleet/month
    wrap), the day-boundary clock (20 moves = 1 tick; three thirds = 1;
    a 3.5 batch = 3 in order);
  * docking on a synthetic harbor placement (harbors injected through the
    raster seam) + the real Lisbon pair: the orthogonal dock charging
    move_cost + 1h, the fleet parked on the berth, discovery on entry, the
    diagonal refusal, crossing a berth docks nothing, Set Sail's §4.11.2
    gate + the +1h continuous clock;
  * the §4.11 sighting reveal (wrap-aware square, berth-distance ports)
    and the §4.2 click-to-sail route consumption through sail_path.

Pinned contracts — port hours / ordering (docs/20 §4.3/§4.1b, docs/90
§5.4):
  * facility_open edges ([open, close), the 24:00 tavern roll, the 24h
    inn, the always-open fallback);
  * advance_port_hours: a sub-day hour runs no ledger, the midnight
    crossing runs the full tick, a dead run's clock is frozen;
  * the day-tick order: ledger → economy step (market hooks) → allegiance
    month boundary (day % 30 == 1) → day_advanced hook — with the ecology
    tick declared as the caller's hook seam.

Deterministic seeds everywhere (weather 20261029, mutiny 90210 — the
GDScript harness seeds; per-band offsets derived by the same rule).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

import pytest

from server.sim.data import DataStore, data
from server.sim.fleet import fleet as fleet_lib
from server.sim.player import PersonState, character, skills
from server.sim.port.allegiance import AllegianceState
from server.sim.port.economy import EconomyState, build_initial_stocks
from server.sim.rng import GodotRng
from server.sim.world import sail_path
from server.sim.world import sailing as sim
from server.sim.world.raster import ocean_layers, raster

# --- Fixture tiles (the GDScript harness constants, on the shipped map) ----

OPEN_CELL = (1400, 640)           # test_sailing.gd / test_movement.gd
TRADE_CELL = (3, 740)             # test_weather.gd: lat 28.3
VARIABLES_CELL = (3, 616)         # lat 38.7 (Lisbon row)
DOLDRUMS_CELL = (3, 1080)         # lat 0.0
WESTERLIES_CELL = (3, 480)        # lat 50.0
BOREAL_CELL = (3, 300)            # lat 65.0
CALM_CELL = (500, 505)            # test_morale.gd
CORNER_FROM = (693, 636)          # test_movement.gd's real corner cut
CORNER_TO = (692, 635)
ICE_CELL = (2313, 420)            # Baltic, in-month on day 1
ICE_FREE_NEIGHBOUR = (2312, 420)
CURRENT_STRONG = (1308, 600)      # Gulf Stream, NE strength 3
CURRENT_WEAK = (2208, 320)        # E strength 1, open corridor east
NO_PATH_CELL = (1486, 484)        # an isolated water tile (no sea route)

WEATHER_SEED = 20261029           # test_weather.gd's pinned seed
MUTINY_SEED = 90210               # test_morale.gd's pinned seed

BAND_TABLES = {
    "doldrums": {"calm": 0.30, "fair": 0.45, "strong": 0.15, "storm": 0.10},
    "trade_winds": {"calm": 0.15, "fair": 0.30, "strong": 0.20, "storm": 0.35},
    "variables": {"calm": 0.30, "fair": 0.40, "strong": 0.20, "storm": 0.10},
    "westerlies": {"calm": 0.10, "fair": 0.30, "strong": 0.35, "storm": 0.25},
    "boreal": {"calm": 0.15, "fair": 0.35, "strong": 0.30, "storm": 0.20},
}


# --- Harness -----------------------------------------------------------------


@dataclass
class Run:
    """One fixture run: every state object the sailing sim touches, plus
    the recorded hook calls (the EventBus mirrors)."""

    state: sim.SailingState = None  # type: ignore[assignment]
    motion: sim.SailingMotion = None  # type: ignore[assignment]
    st: PersonState = None  # type: ignore[assignment]
    store: DataStore = None  # type: ignore[assignment]
    economy: EconomyState = None  # type: ignore[assignment]
    allegiance: AllegianceState = None  # type: ignore[assignment]
    world: Any = None
    ocean: Any = None
    events: list[tuple[str, Any]] = field(default_factory=list)

    def advance(self, days: float) -> int:
        return sim.advance_clock(self.state, self.st, self.store, self.economy,
                                 days, allegiance_state=self.allegiance,
                                 world=self.world, ocean=self.ocean)

    def one_day(self) -> int:
        return self.advance(1.0)


def make_run(
    crew: int = 15,
    provisions: int = 0,
    water: int = 0,
    gold: int = 1000,
    weather: str = "fair",
    seamanship: int = 10,
    navigation: int = 60,
    courage: int = 10,
    constitution: int = 10,
    charisma: int = 10,
    luck: int = 10,
    cell: tuple[int, int] = OPEN_CELL,
    ship_ids: tuple[str, ...] = ("caravel",),
    morale: int = sim.MORALE_START,
    day: int = 1,
    store: DataStore | None = None,
    clock_fraction: float = 0.0,
    docked: str | None = None,
) -> Run:
    """The GDScript ``_make_run`` fixtures, on injected state (the v9
    player shape, a hand-built fleet, the pinned defaults). A caravel at
    full crew with seamanship 10 and fair weather runs at exactly speed 20
    (the §4.4 worked case); navigation 60 clears the night threshold; the
    fixture wind is S so east–west walks are the beam bucket."""
    run = Run()
    run.store = store if store is not None else data()
    run.world = raster()
    run.ocean = ocean_layers()
    run.st = PersonState(
        player={
            "nation_id": "portugal",
            "attributes": {
                "constitution": constitution, "intellect": 10,
                "charisma": charisma, "courage": courage, "luck": luck,
            },
            "skills": {
                "seamanship": seamanship, "navigation": navigation,
                "swordplay": 0, "gunnery": 0, "appraisal": 0,
                "negotiation": 0, "cartography": 0, "rumour": 0,
            },
            "skill_counters": {},
            "xp": 0,
            "level": 1,
            "officers": [],
            "reputation": {},
        },
        officer_states={},
        gold=gold,
        day=day,
    )
    run.state = sim.SailingState(
        world={
            "position": {"x": cell[0], "y": cell[1]},
            "clock_fraction": clock_fraction,
            "weather": weather,
            # Phase-6 fixture pin: a southerly wind makes the east–west
            # clock walks the beam bucket (factor 1.0, §4.4).
            "wind_dir": "S",
        },
        morale=morale,
        current_port=docked,
    )
    run.state.fleet = []
    for ship_id in ship_ids:
        ship = fleet_lib.new_ship(str(ship_id), crew if ship_ids[0] == ship_id
                                  else 0)
        ship["provisions"] = provisions if not run.state.fleet else 0
        ship["water"] = water if not run.state.fleet else 0
        run.state.fleet.append(ship)
    # The GDScript fixtures overwrite the flagship crew after new_ship (which
    # clamps to crew_max); the crew-100 contract cases need exactly that.
    if run.state.fleet:
        run.state.fleet[0]["crew"] = crew
    run.motion = sim.SailingMotion()
    run.economy = EconomyState(day=day)
    run.allegiance = AllegianceState()
    events = run.events

    state = run.state
    st = run.st
    state.on_gold_changed = lambda value: events.append(("gold", value))
    state.on_fleet_changed = lambda: events.append(("fleet", None))
    state.on_market_changed = lambda port_id: events.append(
        ("market", str(port_id)))
    state.on_day_advanced = lambda day_: events.append(("day", day_))
    state.on_clock_changed = lambda: events.append(("clock", None))
    state.on_game_over = lambda reason: events.append(("game_over", reason))
    state.on_port_entered = lambda port_id: events.append(
        ("port_entered", port_id))
    sim.reset_ledger_state(run.state)
    # Deterministic streams: the harness seeds every pinned sequence; these
    # are the defaults a test overrides when it pins its own.
    sim.set_weather_seed(run.state, WEATHER_SEED)
    sim.set_mutiny_seed(run.state, MUTINY_SEED)
    return run


class OfficerStubStore:
    """A DataStore-shaped double for the officer-skill seams (the GDScript
    harness's ``skills_script_override`` doubles): ``get_officer`` serves a
    canned roster, everything else defers to the real store (the economy
    day tick still runs on the real data)."""

    def __init__(self, real: DataStore, roster: dict[str, Any]) -> None:
        self._real = real
        self._roster = roster

    def get_officer(self, officer_id: str) -> dict[str, Any]:
        if str(officer_id) in self._roster:
            return self._roster[str(officer_id)]
        return self._real.get_officer(str(officer_id))

    def __getattr__(self, name: str) -> Any:
        return getattr(self._real, name)


def seed_for_first_outcome(run: Run, tile: tuple[int, int],
                           wanted: str = "strong", limit: int = 500) -> int:
    """Finds a weather seed whose first roll at ``tile`` is ``wanted``
    (the harness's ``_seed_for_storm`` pattern — deterministic search)."""
    for candidate in range(limit):
        sim.set_weather_seed(run.state, candidate)
        if sim.roll_weather(run.state, run.st, tile) == wanted:
            return candidate
    return 0


def drain_dialog_keys(run: Run) -> list[str]:
    return [str(entry.get("key", "")) for entry in
            sim.take_last_day_dialogs(run.state)]


# --- §5 constants (tools/test_sailing.gd _test_constants) --------------------


class TestConstants:
    def test_ledger_constants(self) -> None:
        assert sim.CREW_WAGE_DAILY == 2
        assert sim.RATION_SIZE == 5
        assert sim.PROVISIONS_PRICE == 2
        assert sim.WATER_PRICE == 1
        assert sim.SIGHTING_RADIUS == 48
        assert sim.DISCOVERY_RADIUS == 36
        assert sim.MORALE_START == 70
        assert sim.MORALE_PORT_CAP == 80
        assert sim.STARVATION_LIMIT_DAYS == 7
        assert sim.MUTINY_THRESHOLD == 20
        assert sim.DESERTION_THRESHOLD == 40
        assert sim.STORM_DAMAGE_FRACTION == pytest.approx(0.05)
        assert sim.MUTINY_CHANCE_PER_DAY == pytest.approx(0.25)
        assert sim.DESERTION_FRACTION == pytest.approx(0.10)
        assert sim.MIN_SPEED == 1
        assert sim.CREW_FACTOR_MIN == pytest.approx(0.25)

    def test_phase8_constants(self) -> None:
        assert sim.SEAMANSHIP_SPEED_DIVISOR == 300
        assert sim.SEAMANSHIP_SPEED_CAP == pytest.approx(0.30)
        assert sim.SIGHTING_NAVIGATION_DIVISOR == 12
        assert sim.DISCOVERY_CARTOGRAPHY_DIVISOR == 15
        assert sim.NIGHT_WINDOW_START_HOUR == 22
        assert sim.NIGHT_WINDOW_END_HOUR == 6
        assert sim.NIGHT_MOVE_COST_MULTIPLIER == pytest.approx(2.0)
        assert sim.NIGHT_SAIL_NAVIGATION_THRESHOLD == 40
        assert sim.STORM_DAMAGE_LUCK_DIVISOR == 250
        assert sim.STORM_HEADWAY_BASE_LOSS == pytest.approx(0.5)
        assert sim.STORM_HEADWAY_DIVISOR == 400
        assert sim.STORM_MORALE_CON_DIVISOR == 300
        assert sim.MUTINY_CHARISMA_DIVISOR == 200
        assert sim.SCURVY_GRACE_DIVISOR == 10
        assert sim.CAPTAIN_LESS_SPEED_FACTOR == pytest.approx(0.8)
        assert sim.MORALE_CAPTAIN_LESS == -2
        assert sim.AT_SEA_REPAIR_POINTS == 10
        assert sim.AT_SEA_REPAIR_CARPENTRY_GATE == 60
        assert sim.AT_SEA_REPAIR_CARPENTRY_DIVISOR == 20

    def test_morale_and_mutiny_tables(self) -> None:
        assert sim.MORALE_SEA_DAILY == -1
        assert sim.MORALE_SHORTFALL == -5
        assert sim.MORALE_STORM == -5
        assert sim.MORALE_UNPAID_WAGES == -5
        assert sim.MORALE_PORT_DAILY == 5
        assert sim.MUTINY_PAY_PER_CREW == 20
        assert sim.MUTINY_SUPPRESS_FRACTION == pytest.approx(0.30)
        assert sim.MUTINY_PAY_MORALE == 50
        assert sim.MUTINY_SUPPRESS_MORALE == 40
        assert sim.MUTINY_FIZZLE_MORALE == 5
        order = sim.DIALOG_ORDER
        assert order["weather"] < order["sinking"] < order["mutiny"] \
            < order["desertion"] < order["greeting"]

    def test_sighting_radius_formula(self) -> None:
        # `48 + floor(effective_navigation / 12)` at nav 0/40/100 → 48/51/56.
        for nav, expected in ((0, 48), (40, 51), (100, 56)):
            run = make_run(navigation=nav)
            assert sim.sighting_radius(run.st, run.store) == expected
            assert sim.sighting_radius_for(nav) == expected


# --- §4.5 step 1: consumption (tools/test_sailing.gd _test_consumption) -----


class TestConsumption:
    def test_worked_case_15_crew(self) -> None:
        run = make_run(crew=15, provisions=10, water=10)
        assert run.one_day() == 1
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 7
        assert fleet_lib.supplies(run.state.fleet, "water") == 7
        assert run.state.last_day_shortfalls == {
            "provisions": False, "water": False}

    def test_ceiling_16_crew(self) -> None:
        run = make_run(crew=16, provisions=10, water=10)
        run.one_day()
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 6
        assert fleet_lib.supplies(run.state.fleet, "water") == 6

    def test_shortfall_clamps_and_flags(self) -> None:
        run = make_run(crew=15, provisions=2, water=10)
        run.one_day()
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 0
        assert run.state.last_day_shortfalls["provisions"] is True
        assert run.state.last_day_shortfalls["water"] is False
        assert fleet_lib.supplies(run.state.fleet, "water") == 7

        run = make_run(crew=15, provisions=1, water=0)
        run.one_day()
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 0
        assert fleet_lib.supplies(run.state.fleet, "water") == 0
        assert run.state.last_day_shortfalls == {
            "provisions": True, "water": True}

    def test_flagship_first_pooling(self) -> None:
        run = make_run(crew=15, provisions=4, water=4)
        run.state.fleet[0]["provisions"] = 1
        run.state.fleet[0]["water"] = 1
        second = fleet_lib.new_ship("caravel", 0)
        second["provisions"] = 5
        second["water"] = 5
        run.state.fleet.append(second)
        run.one_day()
        assert run.state.fleet[0]["provisions"] == 0
        assert run.state.fleet[1]["provisions"] == 3
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 3

    def test_crew_zero_and_empty_fleet(self) -> None:
        run = make_run(crew=0, provisions=5, water=5)
        assert run.one_day() == 1
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 5
        assert fleet_lib.supplies(run.state.fleet, "water") == 5
        assert run.state.last_day_shortfalls == {
            "provisions": False, "water": False}

        run = make_run(crew=0, provisions=0, water=0)
        run.state.fleet = []
        assert run.one_day() == 1 and run.st.gold == 1000

    def test_port_day_consumes_nothing(self) -> None:
        # The port-day amendment (§4.5, 2026-11-02): wages still run.
        run = make_run(crew=15, provisions=10, water=10, docked="lisbon")
        assert sim.in_port(run.state)
        assert sim.advance_port_day(
            run.state, run.st, run.store, run.economy) == 1
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 10
        assert fleet_lib.supplies(run.state.fleet, "water") == 10
        assert run.st.gold == 970
        assert sim.in_port(run.state)  # the port day leaves the fleet docked


# --- §4.5 step 2: wages (tools/test_sailing.gd _test_wages/_test_gold_clamp)


class TestWages:
    def test_crew_wages(self) -> None:
        run = make_run(crew=15, provisions=10, water=10, gold=1000)
        run.one_day()
        assert run.st.gold == 970
        assert run.state.last_day_wages == 30

    def test_officer_wages(self) -> None:
        run = make_run(crew=15, provisions=10, water=10, gold=1000)
        run.st.player["officers"] = ["off_mateus_alvares"]
        assert character.officer_wages(run.st, run.store) == 30
        run.one_day()
        assert run.st.gold == 940
        assert run.state.last_day_wages == 60

    def test_no_crew_officer_only(self) -> None:
        run = make_run(crew=0, provisions=0, water=0, gold=100)
        run.st.player["officers"] = ["off_mateus_alvares"]
        run.one_day()
        assert run.st.gold == 70

    def test_gold_clamp_unpaid_flag(self) -> None:
        run = make_run(crew=15, provisions=10, water=10, gold=10)
        run.st.player["officers"] = ["off_mateus_alvares"]
        run.one_day()
        assert run.st.gold == 0
        assert run.state.last_day_unpaid_wages is True
        assert run.events.count(("gold", 0)) == 1

    def test_exactly_affordable_is_paid(self) -> None:
        run = make_run(crew=15, provisions=10, water=10, gold=30)
        run.one_day()
        assert run.st.gold == 0
        assert run.state.last_day_unpaid_wages is False

    def test_zero_wages_no_signal(self) -> None:
        run = make_run(crew=0, provisions=0, water=0, gold=100)
        run.one_day()
        assert run.st.gold == 100
        assert not [kind for kind, _ in run.events if kind == "gold"]


# --- §4.3 day boundary (tools/test_sailing.gd _test_clock_boundaries) -------


class TestClockBoundaries:
    def test_twenty_moves_one_tick(self) -> None:
        run = make_run(crew=15, provisions=100, water=100, gold=1000)
        for step in range(20):
            target = (OPEN_CELL[0] + (1 if step % 2 == 0 else 0),
                      OPEN_CELL[1])
            assert sim.try_move(run.state, run.st, run.store, run.economy,
                                target, world=run.world, ocean=run.ocean)
        assert [day for kind, day in run.events if kind == "day"] == [2]
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 97
        assert run.st.gold == 970

    def test_three_thirds_one_tick(self) -> None:
        run = make_run(crew=15, provisions=100, water=100, gold=1000, day=10)
        assert run.advance(1.0 / 3.0) == 0
        assert run.advance(1.0 / 3.0) == 0
        assert run.advance(1.0 / 3.0) == 1
        assert [day for kind, day in run.events if kind == "day"] == [11]
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 97

    def test_batch_spans_three_boundaries(self) -> None:
        run = make_run(crew=15, provisions=100, water=100, gold=940, day=20)
        assert run.advance(3.5) == 3
        assert [day for kind, day in run.events if kind == "day"] == \
            [21, 22, 23]
        assert fleet_lib.supplies(run.state.fleet, "provisions") == 91
        assert run.st.gold == 850  # 940 − 3 × 30

    def test_dead_run_clock_frozen(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70)
        sim.set_weather_seed(run.state, seed_for_first_outcome(run, CALM_CELL))
        for _ in range(sim.STARVATION_LIMIT_DAYS):
            run.one_day()
        assert sim.is_game_over(run.state)
        day_at_death = run.st.day
        crew_at_death = fleet_lib.total_crew(run.state.fleet)
        assert run.advance(3.0) == 0
        assert run.st.day == day_at_death
        assert fleet_lib.total_crew(run.state.fleet) == crew_at_death


# --- Display formats (tools/test_sailing.gd _test_display_formats) ----------


class TestDisplayFormats:
    def test_clock_text(self) -> None:
        run = make_run()
        run.state.world["clock_fraction"] = 0.0
        assert sim.time_of_day_minutes(run.state) == 0
        assert sim.clock_text(run.state) == "00:00"
        run.state.world["clock_fraction"] = 0.5
        assert sim.time_of_day_minutes(run.state) == 720
        assert sim.clock_text(run.state) == "12:00"
        run.state.world["clock_fraction"] = 0.999999999
        assert sim.time_of_day_minutes(run.state) == 1439
        assert sim.clock_text(run.state) == "23:59"

    def test_knots_conversion(self) -> None:
        assert sim.knots_text_for(16) == "3.3"
        assert sim.knots_text_for(20) == "4.2"
        assert sim.knots_text_for(24) == "5.0"
        run = make_run(crew=15, provisions=60, water=45)
        assert sim.speed_knots(run.state, run.st, run.store) == \
            pytest.approx(4.2)

    def test_kind_supply_days(self) -> None:
        run = make_run(crew=15, provisions=60, water=45)
        assert sim.kind_supply_days(run.state, "provisions") == 20
        assert sim.kind_supply_days(run.state, "water") == 15
        run.state.fleet[0]["crew"] = 0
        assert sim.kind_supply_days(run.state, "provisions") == 0

    def test_supply_block_reason(self) -> None:
        run = make_run(crew=0)
        assert sim.supply_block_reason(run.state) == "port.sail.no_crew"
        run = make_run(crew=15, provisions=0, water=0)
        assert sim.supply_block_reason(run.state) == "port.sail.no_supply"
        run = make_run(crew=15, provisions=5, water=5)
        assert sim.supply_block_reason(run.state) == ""
        assert sim.daily_need(15) == 3
        assert sim.supply_days(45, 45, 15) == 15


# --- §4.4 speed table (tools/test_sailing.gd _test_speed_table) -------------


class TestSpeedTable:
    def test_worked_case_and_weather(self) -> None:
        run = make_run(crew=15)
        assert sim.effective_speed(run.state, run.st, run.store) == 20
        assert sim.move_cost(run.state, run.st, run.store) == \
            pytest.approx(0.05)

        run = make_run(crew=15, weather="calm")
        assert sim.effective_speed(run.state, run.st, run.store) == 16

        run = make_run(crew=15, weather="storm", courage=10)
        assert sim.effective_speed(run.state, run.st, run.store) == 15

        run = make_run(crew=15, weather="storm", courage=100)
        assert sim.effective_speed(run.state, run.st, run.store) == 18

    def test_skeleton_crew_floor(self) -> None:
        run = make_run(crew=1)
        assert sim.crew_factor(run.state) == pytest.approx(0.25)
        assert sim.effective_speed(run.state, run.st, run.store) == 5
        run = make_run(crew=1, weather="calm")
        assert sim.effective_speed(run.state, run.st, run.store) == 4

    def test_captain_less_slowest_hull(self) -> None:
        run = make_run(crew=15)
        nao = fleet_lib.new_ship("nao", 25)
        run.state.fleet.append(nao)
        assert fleet_lib.slowest_speed(run.state.fleet) == 16
        # The unappointed escort contributes 16 × 0.8 = 12.8 → 12.
        assert sim.effective_speed(run.state, run.st, run.store) == 12
        # Appointing a captain for that hull restores the full 16-scan.
        run.st.player["officers"] = ["off_leg_vicente_gouveia"]
        run.st.officer_states["off_leg_vicente_gouveia"] = {
            "post_id": "captain", "ship_id": "nao", "loyalty": 50,
            "sea_days": 0,
        }
        assert sim.captain_less_count(run.state, run.st) == 0
        # The appointed escort now contributes its real 16: the slowest
        # hull is the nao's 16 (floor(16 × 1.0333) = 16).
        assert sim.effective_speed(run.state, run.st, run.store) == 16

    def test_oar_ignores_wind_but_not_headway(self) -> None:
        run = make_run(crew=40, weather="storm")
        run.state.fleet = [fleet_lib.new_ship("galley", 40)]
        assert sim.wind_factor("storm", "oar") == 1.0
        assert sim.wind_factor("calm", "oar") == 1.0
        # floor(24 × 1.0 × 1.0333 × 0.5) = 12 at COU 10.
        assert sim.effective_speed(run.state, run.st, run.store,
                                   ocean=run.ocean) == 12
        run.state.world["weather"] = "calm"
        assert sim.effective_speed(run.state, run.st, run.store) == 24

    def test_hybrid_strong(self) -> None:
        run = make_run(crew=40, weather="strong")
        run.state.fleet = [fleet_lib.new_ship("galleon", 40)]
        assert sim.effective_speed(run.state, run.st, run.store) == 22


# --- §4.4 heading pipeline (tools/test_sailing.gd _test_heading_pipeline) ---


class TestHeadingPipeline:
    def test_data_speed_range(self) -> None:
        store = data()
        for ship_id, speed in (("latin", 16), ("nao", 16), ("carrack", 16),
                               ("sloop", 20), ("caravel", 20),
                               ("galleon", 20), ("galley", 24),
                               ("brigantine", 24)):
            assert int(store.get_ship_type(ship_id)["speed"]) == speed

    def test_direction_aware_move_cost(self) -> None:
        run = make_run(crew=15)
        run.state.world["wind_dir"] = "E"
        assert sim.move_cost(run.state, run.st, run.store, "E") == \
            pytest.approx(0.1)  # into the wind: floor(20 × 0.5) = 10
        assert sim.move_cost(run.state, run.st, run.store, "W") == \
            pytest.approx(1.0 / 26.0)  # running: floor(20 × 1.3) = 26
        assert sim.move_cost(run.state, run.st, run.store, "N") == \
            pytest.approx(0.05)  # beam
        assert sim.move_cost(run.state, run.st, run.store) == \
            pytest.approx(0.05)  # the heading-less average stays beam

    def test_beam_try_move_cost(self) -> None:
        run = make_run(crew=15)
        fraction = float(run.state.world["clock_fraction"])
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            (OPEN_CELL[0] + 1, OPEN_CELL[1]),
                            world=run.world, ocean=run.ocean)
        assert float(run.state.world["clock_fraction"]) - fraction == \
            pytest.approx(0.05)

    def test_trim_in_pipeline(self) -> None:
        run = make_run(crew=15)
        run.state.world["wind_dir"] = "E"
        run.state.world["sail_trim"] = "full"
        assert sim.effective_speed(run.state, run.st, run.store, "W",
                                   run.ocean) == 30
        run.state.world["sail_trim"] = "reefed"
        assert sim.effective_speed(run.state, run.st, run.store, "E",
                                   run.ocean) == 7

    def test_ledger_writes_both_roll_halves(self) -> None:
        run = make_run(crew=15, provisions=10, water=10, weather="fair")
        sim.set_weather_seed(run.state, 7)
        run.one_day()
        assert str(run.state.world["weather"]) in sim.WEATHER_OUTCOMES
        assert str(run.state.world["wind_dir"]) in sim.COMPASS_DIRS


class TestDirectionAndTrimTables:
    def test_direction_factor_buckets(self) -> None:
        for bucket in (0, 45, 90, 135, 180):
            for ship_class in ("sail", "hybrid", "oar"):
                expected = sim.DIRECTION_FACTORS[bucket][ship_class]
                wind = sim.COMPASS_DIRS[(bucket // 45) % 8]
                got = sim.direction_factor("N", wind, ship_class, "fair")
                assert got == pytest.approx(expected)
                assert 0.0 < got <= 1.30

    def test_calm_has_no_direction_effect(self) -> None:
        assert sim.direction_factor("S", "S", "sail", "calm") == 1.0
        run = make_run(weather="calm")
        assert sim.effective_speed(run.state, run.st, run.store, "S",
                                   run.ocean) == 16

    def test_furled_cannot_move_oar_rows(self) -> None:
        run = make_run()
        run.state.world["sail_trim"] = "furled"
        assert sim.effective_speed(run.state, run.st, run.store, "E",
                                   run.ocean) == 0
        assert not sim.try_move(run.state, run.st, run.store, run.economy,
                                (OPEN_CELL[0] + 1, OPEN_CELL[1]),
                                world=run.world, ocean=run.ocean)
        assert sim.world_tile(run.state) == OPEN_CELL
        assert float(run.state.world["clock_fraction"]) == 0.0
        # Oar ignores trim entirely: a furled galley still rows at 24.
        run.state.fleet = [fleet_lib.new_ship("galley", 40)]
        assert sim.trim_factor("furled", "oar") == 1.0
        assert sim.effective_speed(run.state, run.st, run.store, "E",
                                   run.ocean) == 24

    def test_trim_speed_matrix(self) -> None:
        for trim, expected in (("reefed", 15), ("normal", 20), ("full", 23)):
            run = make_run()
            run.state.world["sail_trim"] = trim
            assert sim.effective_speed(run.state, run.st, run.store, "E",
                                       run.ocean) == expected

    def test_trim_storm_damage_matrix(self) -> None:
        run = make_run(luck=0)
        assert sim.trim_storm_multiplier("furled", "sail") == 0.5
        assert sim.trim_storm_multiplier("reefed", "sail") == 0.75
        assert sim.trim_storm_multiplier("full", "sail") == 1.5
        # Caravel 90: normal 5, reefed ceil(4.5×0.75) = 4, full ceil(6.75) = 7.
        assert sim.storm_damage_for(90, run.st) == 5
        assert sim.storm_damage_for(90, run.st, 0.75) == 4
        assert sim.storm_damage_for(90, run.st, 1.5) == 7
        # Oar ignores trim: the galley multiplier is forced 1.0.
        assert sim.trim_storm_multiplier("full", "oar") == 1.0

    def test_compass_domain(self) -> None:
        for index, heading in enumerate(sim.COMPASS_DIRS):
            assert sim.heading_index(heading) == index
            assert sim.heading_of_delta(sim.COMPASS_DELTAS[index]) == heading
        for bad in ((0, 0), (2, 0), (1, 2)):
            assert sim.heading_of_delta(bad) == ""
        assert sim.angle_between_dirs("N", "S") == 180
        assert sim.angle_between_dirs("NE", "SW") == 180
        assert sim.angle_between_dirs("E", "E") == 0
        assert sim.angle_between_dirs("N", "E") == 90

    def test_calendar(self) -> None:
        assert sim.year_for(1) == 1
        assert sim.year_for(360) == 1
        assert sim.year_for(361) == 2
        assert sim.month_for(1) == 1
        assert sim.month_for(30) == 1
        assert sim.month_for(31) == 2
        assert sim.month_for(360) == 12
        assert sim.month_for(361) == 1
        assert sim.month_for(181) == 7


# --- §4.2 night sail (tools/test_movement.gd _test_night_sail) --------------


class TestNightSail:
    def test_window_bounds(self) -> None:
        for fraction, night in ((21.0 / 24.0, False), (22.0 / 24.0, True),
                                (359.0 / 1440.0, True),
                                (360.0 / 1440.0, False)):
            run = make_run(navigation=10)
            run.state.world["clock_fraction"] = fraction
            assert sim.is_night_watch(run.state) is night
            assert sim.night_slow_applies(run.state, run.st,
                                          run.store) is night

    def test_night_step_doubles_the_cost(self) -> None:
        run = make_run(navigation=10)
        run.state.world["clock_fraction"] = 23.0 / 24.0
        start_day = run.st.day
        start_fraction = float(run.state.world["clock_fraction"])
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            (OPEN_CELL[0] + 1, OPEN_CELL[1]),
                            world=run.world, ocean=run.ocean)
        cost = float(run.st.day - start_day) \
            + float(run.state.world["clock_fraction"]) - start_fraction
        assert cost == pytest.approx(0.1)
        assert sim.step_move_cost(run.state, run.st, run.store, "E") == \
            pytest.approx(2.0 * sim.move_cost(run.state, run.st, run.store,
                                              "E"))

    def test_day_time_step_unchanged(self) -> None:
        run = make_run(navigation=10, provisions=200, water=200)
        run.one_day()  # the night walk above re-rolls weather/wind in some
        run.state.world["weather"] = "fair"
        run.state.world["wind_dir"] = "S"
        run.state.world["clock_fraction"] = 0.5
        run.state.world["position"] = {"x": OPEN_CELL[0], "y": OPEN_CELL[1]}
        fraction = float(run.state.world["clock_fraction"])
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            (OPEN_CELL[0] + 1, OPEN_CELL[1]),
                            world=run.world, ocean=run.ocean)
        assert float(run.state.world["clock_fraction"]) - fraction == \
            pytest.approx(0.05)

    def test_navigation_exemption(self) -> None:
        for nav, slow in ((39, True), (40, False), (60, False)):
            run = make_run(navigation=nav)
            run.state.world["clock_fraction"] = 23.0 / 24.0
            assert sim.night_slow_applies(run.state, run.st,
                                          run.store) is slow

    def test_docking_charge_not_doubled(self) -> None:
        run = make_run(navigation=10)
        run.state.world["clock_fraction"] = 23.0 / 24.0
        assert sim.move_cost(run.state, run.st, run.store) == \
            pytest.approx(0.05)


# --- §4.7 latitude bands (tools/test_weather.gd) -----------------------------


class TestWeatherBands:
    def test_band_tables_exact_at_luck_zero(self) -> None:
        run = make_run(luck=0, cell=TRADE_CELL)
        for band, table in BAND_TABLES.items():
            got = sim.zone_probabilities(band, run.st)
            for outcome, value in table.items():
                assert got[outcome] == pytest.approx(value), (band, outcome)

    def test_tables_normalized(self) -> None:
        for luck in (0, 10, 50, 100, 399):
            run = make_run(luck=luck, cell=TRADE_CELL)
            for band in BAND_TABLES:
                total = sum(sim.zone_probabilities(band, run.st).values())
                assert total == pytest.approx(1.0), (luck, band)

    def test_band_edges(self) -> None:
        cases = [
            (0.0, "doldrums"), (7.9, "doldrums"), (8.0, "trade_winds"),
            (20.0, "trade_winds"), (28.3, "trade_winds"),
            (29.9, "trade_winds"), (30.0, "variables"), (35.0, "variables"),
            (38.7, "variables"), (39.9, "variables"), (40.0, "westerlies"),
            (50.0, "westerlies"), (59.9, "westerlies"), (60.0, "boreal"),
            (65.0, "boreal"), (69.9, "boreal"), (70.0, "boreal"),
            (85.0, "boreal"),
        ]
        for latitude, expected in cases:
            y = int(round((90.0 - latitude) * 12.0))
            for x in (3, 4319):
                assert sim.weather_zone_for((x, y)) == expected, \
                    (latitude, x)
        assert sim.weather_zone_for(VARIABLES_CELL) == "variables"
        assert sim.weather_zone_for(TRADE_CELL) == "trade_winds"
        assert sim.weather_zone_for(BOREAL_CELL) == "boreal"
        assert sim.weather_zone_for((3, 1320)) == "trade_winds"
        assert sim.weather_zone_for((3, 1680)) == "westerlies"
        assert sim.weather_zone_for((3, 1860)) == "boreal"
        assert sim.weather_zone_for((3, 2159)) == "boreal"
        assert sim.weather_zone_for((0, 1080)) == \
            sim.weather_zone_for((4319, 1080))
        # Only the five locked band ids ever occur.
        seen = {sim.weather_zone_for((0, y)) for y in range(0, 2160, 3)}
        assert seen == set(BAND_TABLES)

    def test_luck10_closed_form(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL)
        for band in BAND_TABLES:
            base = BAND_TABLES[band]
            base_storm = float(base["storm"])
            storm = base_storm * (1.0 - 10.0 / 400.0)
            scale = (1.0 - storm) / (1.0 - base_storm)
            got = sim.zone_probabilities(band, run.st)
            assert got["storm"] == pytest.approx(storm)
            for outcome in ("calm", "fair", "strong"):
                assert got[outcome] == \
                    pytest.approx(float(base[outcome]) * scale)

    def test_storm_chance_rows(self) -> None:
        for luck, expected in ((0, 0.35), (10, 0.34125), (100, 0.2625)):
            run = make_run(luck=luck, cell=TRADE_CELL)
            got = sim.zone_probabilities("trade_winds", run.st)["storm"]
            assert got == pytest.approx(expected)
            assert character.storm_chance_multiplier(run.st) == \
                pytest.approx(1.0 - luck / 400.0)
        run0 = make_run(luck=0, cell=TRADE_CELL)
        run100 = make_run(luck=100, cell=TRADE_CELL)
        assert sim.zone_probabilities("trade_winds", run0.st)["storm"] > \
            sim.zone_probabilities("trade_winds", run100.st)["storm"]

    def test_redistribution_keeps_non_storm_shares(self) -> None:
        for luck in (0, 10, 50, 100, 300):
            run = make_run(luck=luck, cell=TRADE_CELL)
            for band, base in BAND_TABLES.items():
                probs = sim.zone_probabilities(band, run.st)
                assert probs["fair"] / probs["calm"] == \
                    pytest.approx(base["fair"] / base["calm"])
                assert probs["strong"] / probs["calm"] == \
                    pytest.approx(base["strong"] / base["calm"])
                assert probs["storm"] < base["storm"] or luck == 0

    def test_seeded_spot_samples(self) -> None:
        bands = {
            "doldrums": DOLDRUMS_CELL,
            "trade_winds": TRADE_CELL,
            "variables": VARIABLES_CELL,
            "westerlies": WESTERLIES_CELL,
            "boreal": BOREAL_CELL,
        }
        rolls = 500
        tolerance = 0.06
        rates: dict[str, float] = {}
        for offset, (band, cell) in enumerate(bands.items()):
            run = make_run(luck=10, cell=cell)
            expected = {}
            base = BAND_TABLES[band]
            storm = float(base["storm"]) * (1.0 - 10.0 / 400.0)
            scale = (1.0 - storm) / (1.0 - float(base["storm"]))
            for outcome in ("calm", "fair", "strong"):
                expected[outcome] = float(base[outcome]) * scale
            expected["storm"] = storm
            sim.set_weather_seed(run.state, WEATHER_SEED + offset)
            counts = {"calm": 0, "fair": 0, "strong": 0, "storm": 0}
            for _ in range(rolls):
                outcome = sim.roll_weather(run.state, run.st, cell)
                counts[outcome] += 1
            for outcome, count in counts.items():
                rate = count / rolls
                rates[f"{band}.{outcome}"] = rate
                assert abs(rate - expected[outcome]) <= tolerance, \
                    (band, outcome, rate, expected[outcome])
        assert rates["trade_winds.storm"] > rates["variables.storm"] * 2.0
        assert rates["doldrums.fair"] > rates["westerlies.fair"]

    def test_reachability_closed_form(self) -> None:
        p = 0.35 * (1.0 - 10.0 / 400.0)
        assert p == pytest.approx(0.34125)
        six = 1.0 - (1.0 - p) ** 6
        six_no_luck = 1.0 - 0.65 ** 6
        assert abs(six - 0.9183) < 0.0005
        assert abs(six_no_luck - 0.9246) < 0.0005
        assert six >= 0.90 and six_no_luck >= 0.90

    def test_determinism(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL)
        sim.set_weather_seed(run.state, WEATHER_SEED)
        first = [sim.roll_weather(run.state, run.st, TRADE_CELL)
                 for _ in range(50)]
        sim.set_weather_seed(run.state, WEATHER_SEED)
        second = [sim.roll_weather(run.state, run.st, TRADE_CELL)
                  for _ in range(50)]
        assert first == second
        sim.set_weather_seed(run.state, WEATHER_SEED + 1)
        third = [sim.roll_weather(run.state, run.st, TRADE_CELL)
                 for _ in range(50)]
        assert first != third

    def test_ledger_replay_is_deterministic(self) -> None:
        sequences = []
        for _ in range(2):
            run = make_run(crew=15, provisions=500, water=500, gold=100000,
                           luck=10, cell=TRADE_CELL)
            sim.set_weather_seed(run.state, WEATHER_SEED)
            days = []
            for _ in range(10):
                run.one_day()
                days.append(str(run.state.world["weather"]))
            sequences.append(days)
        assert sequences[0] == sequences[1]


class TestWeatherLedgerIntegration:
    def test_storm_damage_on_two_ship_fleet(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL,
                       ship_ids=("caravel", "nao"))
        assert run.state.fleet[0]["durability"] == 90
        assert run.state.fleet[1]["durability"] == 140
        dealt = sim.apply_storm_damage(run.state, run.st, run.store)
        assert run.state.fleet[0]["durability"] == 85
        assert run.state.fleet[1]["durability"] == 133
        assert dealt == 12
        assert ("fleet", None) in run.events
        assert run.state.last_day_storm_damage == [
            {"ship_type_id": "caravel", "points": 5},
            {"ship_type_id": "nao", "points": 7},
        ]

    def test_luck50_fleet(self) -> None:
        run = make_run(luck=50, cell=TRADE_CELL,
                       ship_ids=("caravel", "nao"))
        sim.apply_storm_damage(run.state, run.st, run.store)
        assert run.state.fleet[0]["durability"] == 86
        assert run.state.fleet[1]["durability"] == 134

    def test_ledger_storm_day_applies_once(self) -> None:
        storm_seed = -1
        for candidate in range(500):
            sim.set_weather_seed(make_run(luck=10).state, candidate)
            probe = make_run(luck=10, cell=TRADE_CELL)
            sim.set_weather_seed(probe.state, candidate)
            if sim.roll_weather(probe.state, probe.st, TRADE_CELL) == "storm":
                storm_seed = candidate
                break
        assert storm_seed >= 0
        run = make_run(luck=10, cell=TRADE_CELL)
        sim.set_weather_seed(run.state, storm_seed)
        run.one_day()
        assert str(run.state.world["weather"]) == "storm"
        assert run.state.last_day_storm is True
        assert run.state.fleet[0]["durability"] == 85

    def test_durability_clamps_at_zero(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL)
        run.state.fleet[0]["durability"] = 2
        dealt = sim.apply_storm_damage(run.state, run.st, run.store)
        assert run.state.fleet[0]["durability"] == 0
        assert dealt == 2

    def test_no_damage_no_fleet_signal(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL)
        run.state.fleet[0]["durability"] = 0
        sim.apply_storm_damage(run.state, run.st, run.store)
        assert run.state.fleet[0]["durability"] == 0
        assert not [kind for kind, _ in run.events if kind == "fleet"]

    def test_damage_formula_pinned(self) -> None:
        run = make_run(luck=0, cell=TRADE_CELL)
        assert sim.storm_luck_multiplier(run.st) == pytest.approx(1.0)
        assert sim.storm_damage_for(90, run.st) == 5
        run = make_run(luck=10, cell=TRADE_CELL)
        assert sim.storm_luck_multiplier(run.st) == pytest.approx(0.96)
        assert sim.storm_damage_for(90, run.st) == 5
        run = make_run(luck=100, cell=TRADE_CELL)
        assert sim.storm_luck_multiplier(run.st) == pytest.approx(0.60)
        assert sim.storm_damage_for(90, run.st) == 3
        # The retired luck ≥ 50 step is gone: the curve is continuous.
        run = make_run(luck=49, cell=TRADE_CELL)
        assert sim.storm_luck_multiplier(run.st) == \
            pytest.approx(1.0 - 49.0 / 250.0)
        assert sim.storm_damage_for(90, run.st) == 4  # before rounding
        run = make_run(luck=50, cell=TRADE_CELL)
        assert sim.storm_luck_multiplier(run.st) == pytest.approx(0.80)

    def test_whole_hull_table(self) -> None:
        expected_plain = {"latin": 2, "sloop": 3, "caravel": 5, "galley": 4,
                          "brigantine": 6, "nao": 7, "carrack": 9,
                          "galleon": 12}
        run = make_run(luck=0, cell=TRADE_CELL)
        for ship_id, points in expected_plain.items():
            max_dur = int(data().get_ship_type(ship_id)["durability"])
            assert sim.storm_damage_for(max_dur, run.st) == points, ship_id
        expected_mitigated = {"latin": 2, "sloop": 2, "caravel": 3,
                              "galley": 3, "brigantine": 4, "nao": 5,
                              "carrack": 6, "galleon": 8}
        run = make_run(luck=100, cell=TRADE_CELL)
        for ship_id, points in expected_mitigated.items():
            max_dur = int(data().get_ship_type(ship_id)["durability"])
            assert sim.storm_damage_for(max_dur, run.st) == points, ship_id

    def test_ledger_order_weather_after_consumption(self) -> None:
        run = make_run(crew=15, provisions=10, water=10, gold=1000,
                       luck=10, cell=TRADE_CELL, morale=70)
        provisions_before = fleet_lib.supplies(run.state.fleet, "provisions")
        gold_before = run.st.gold
        sim.set_weather_seed(run.state, WEATHER_SEED)
        run.one_day()
        assert fleet_lib.supplies(run.state.fleet, "provisions") == \
            provisions_before - 3
        assert run.st.gold == gold_before - 30
        assert str(run.state.world["weather"]) in sim.WEATHER_OUTCOMES
        assert run.state.last_day_shortfalls["provisions"] is False

    def test_weather_persists_and_band_follows_tile(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL, provisions=500, water=500,
                       gold=100000)
        sim.set_weather_seed(run.state, WEATHER_SEED)
        seen: set[str] = set()
        for _ in range(60):
            for ship in run.state.fleet:
                ship["durability"] = fleet_lib.ship_stat(ship, "durability")
                ship["provisions"] = 500
                ship["water"] = 500
            run.st.gold = 100000
            run.state.morale = 70
            run.one_day()
            seen.add(str(run.state.world["weather"]))
        assert seen <= set(sim.WEATHER_OUTCOMES)
        assert "storm" in seen and "calm" in seen

        run = make_run(luck=10, cell=TRADE_CELL)
        sim.set_weather_seed(run.state, WEATHER_SEED)
        run.one_day()
        assert run.state.last_weather_zone == "trade_winds"
        run.state.world["position"] = {"x": 3, "y": 480}
        run.one_day()
        assert run.state.last_weather_zone == "westerlies"

    def test_no_transient_keys_leak_into_world(self) -> None:
        run = make_run(luck=10, cell=TRADE_CELL)
        sim.set_weather_seed(run.state, WEATHER_SEED)
        run.one_day()
        allowed = {"position", "clock_fraction", "weather", "wind_dir",
                   "heading", "sail_trim", "map_id", "last_departed_port"}
        assert set(run.state.world) <= allowed


# --- §4.7.1 wind-direction roll: seeded replay pins the ORDER ----------------


class TestWindDirectionRoll:
    def test_replay_var_tile_matches_pinned_sequence(self) -> None:
        # TRADE_CELL has no authored wind region → VAR → exactly ONE
        # uniform draw over the 8 compass directions, after the strength
        # roll. Replay the two draws independently and require the same
        # outcome — a swapped roll order changes the direction value.
        var_cell = (2040, 720)  # uncovered water → VAR (probed on the map)
        run = make_run(luck=10, cell=var_cell)
        sim.set_weather_seed(run.state, 1234)
        strength = sim.roll_weather(run.state, run.st, var_cell)
        direction = sim.roll_wind_direction(run.state, var_cell,
                                            sim.month_for(run.st.day),
                                            strength, run.ocean)
        assert run.state.last_wind_prevailing == "VAR"
        assert run.state.world["wind_dir"] == direction

        replay = GodotRng(seed=1234)
        replay.randf()  # the strength draw
        expected = sim.COMPASS_DIRS[replay.randi_range(0, 7)]
        assert direction == expected

    def test_replay_region_tile_keep_and_jitter(self) -> None:
        # OPEN_CELL sits in an authored region (prevailing NE). Replay the
        # full pinned sequence for both branches: the keep branch (draw A
        # below keep) and the jitter branch (draw A above keep, draw B
        # indexes the calm offsets [+1, −1, +2, −2]).
        prevailing = run_prevailing = ocean_layers().prevailing_for(
            OPEN_CELL[0], OPEN_CELL[1], 1)
        assert prevailing == "NE"
        assert run_prevailing == prevailing

        # Replay the pinned keep/jitter branch for whatever strength landed.
        seed = 424242
        run = make_run(luck=10, cell=OPEN_CELL)
        sim.set_weather_seed(run.state, seed)
        strength = sim.roll_weather(run.state, run.st, OPEN_CELL)
        direction = sim.roll_wind_direction(run.state, OPEN_CELL,
                                            sim.month_for(run.st.day),
                                            strength, run.ocean)
        replay = GodotRng(seed=seed)
        replay.randf()  # the strength draw
        if strength == "storm":
            expected = sim.COMPASS_DIRS[replay.randi_range(0, 7)]
        else:
            jitter = sim.WIND_JITTER[strength]
            if replay.randf() < float(jitter["keep"]):
                expected = "NE"
            else:
                offsets = jitter["offsets"]
                offset = offsets[replay.randi_range(0, len(offsets) - 1)]
                expected = sim.COMPASS_DIRS[
                    (sim.heading_index("NE") + int(offset)) % 8]
        assert direction == expected

    def test_storm_never_keeps_prevailing(self) -> None:
        seed = seed_for_first_outcome(make_run(luck=10, cell=OPEN_CELL),
                                      OPEN_CELL, wanted="storm")
        run = make_run(luck=10, cell=OPEN_CELL)
        sim.set_weather_seed(run.state, seed)
        strength = sim.roll_weather(run.state, run.st, OPEN_CELL)
        assert strength == "storm"
        direction = sim.roll_wind_direction(run.state, OPEN_CELL,
                                            sim.month_for(run.st.day),
                                            strength, run.ocean)
        replay = GodotRng(seed=seed)
        replay.randf()
        assert direction == sim.COMPASS_DIRS[replay.randi_range(0, 7)]
        assert sim.COMPASS_DIRS[replay.randi_range(0, 7)]  # noqa: B018


# --- §4.8.1 morale deltas (tools/test_morale.gd _test_morale_deltas) --------


class TestMoraleDeltas:
    def seed_calm(self, run: Run, cell: tuple[int, int] = CALM_CELL) -> None:
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, cell, wanted="strong"))

    def test_fully_supplied_sea_day(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL)
        self.seed_calm(run)
        run.one_day()
        assert run.state.morale == 69
        assert run.state.last_morale_delta == -1

    def test_provisions_short(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        self.seed_calm(run)
        run.one_day()
        assert run.state.morale == 64
        assert run.state.last_morale_delta == -6

    def test_water_short_mirrors(self) -> None:
        run = make_run(crew=15, provisions=200, water=0, gold=100000,
                       morale=70, cell=CALM_CELL)
        self.seed_calm(run)
        run.one_day()
        assert run.state.last_morale_delta == -6

    def test_storm_stacks(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "storm"))
        run.one_day()
        assert run.state.last_day_storm is True
        assert run.state.morale == 59
        assert run.state.last_morale_delta == -11

    def test_unpaid_wages_stack(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=0, morale=70,
                       cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "storm"))
        run.one_day()
        assert run.state.last_day_unpaid_wages is True
        assert run.state.morale == 54
        assert run.state.last_morale_delta == -16

    def test_port_replaces_sea_rows(self) -> None:
        run = make_run(crew=15, provisions=0, water=0, gold=100000,
                       morale=70, docked="lisbon")
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "storm"))
        sim.advance_port_day(run.state, run.st, run.store, run.economy)
        assert run.state.last_morale_delta == 5
        assert run.state.morale == 75

    def test_port_cap(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=79, docked="lisbon")
        sim.advance_port_day(run.state, run.st, run.store, run.economy)
        assert run.state.morale == 80
        sim.advance_port_day(run.state, run.st, run.store, run.economy)
        assert run.state.morale == 80

        run = make_run(morale=10, docked="lisbon")
        sim.advance_port_day(run.state, run.st, run.store, run.economy)
        assert run.state.morale == 15  # never capped up

        run = make_run(morale=99, docked="lisbon")
        sim.advance_port_day(run.state, run.st, run.store, run.economy)
        assert run.state.morale == 99  # a fixture above the cap stays put

    def test_cap_never_suppresses_sea_loss(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=55, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "storm"))
        run.one_day()
        assert run.state.morale == 44

    def test_clamp_at_zero(self) -> None:
        run = make_run(crew=15, provisions=0, water=0, gold=0, morale=3,
                       cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "storm"))
        run.one_day()
        assert run.state.morale == 0

    def test_storm_morale_con_multiplier(self) -> None:
        run = make_run(constitution=100, provisions=50, water=50,
                       cell=CALM_CELL)
        assert sim.storm_morale_multiplier(run.st) == pytest.approx(0.7)
        assert sim.storm_morale_delta(run.st) == -4  # round(−3.5) away
        seed = seed_for_first_outcome(run, CALM_CELL, "storm")
        run = make_run(constitution=100, provisions=50, water=50,
                       cell=CALM_CELL)
        sim.set_weather_seed(run.state, seed)
        run.state.morale = 70
        run.one_day()
        assert run.state.last_day_storm is True
        assert run.state.morale == 70 - 1 - 4
        assert run.state.last_morale_delta == -5


# --- §4.8.1 captain-less row (tools/test_morale.gd _test_captain_less) ------


class TestCaptainLessMorale:
    def test_escort_penalty_and_appointment(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL,
                       ship_ids=("caravel", "nao"))
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        assert sim.captain_less_count(run.state, run.st) == 1
        run.one_day()
        assert run.state.morale == 67
        assert run.state.last_morale_delta == -3

        run.st.player["officers"] = ["off_leg_vicente_gouveia"]
        run.st.officer_states["off_leg_vicente_gouveia"] = {
            "post_id": "captain", "ship_id": "nao", "loyalty": 50,
            "sea_days": 0,
        }
        assert sim.captain_less_count(run.state, run.st) == 0
        run.state.morale = 70
        run.one_day()
        assert run.state.morale == 69
        assert run.state.last_morale_delta == -1

        # A captain tied to the wrong hull does not clear it.
        run.st.officer_states["off_leg_vicente_gouveia"] = {
            "post_id": "captain", "ship_id": "latin", "loyalty": 50,
            "sea_days": 0,
        }
        assert sim.captain_less_count(run.state, run.st) == 1

    def test_one_ship_fleet_never_fires(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL)
        assert sim.captain_less_count(run.state, run.st) == 0
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.one_day()
        assert run.state.morale == 69


# --- §4.9 starvation / scurvy (tools/test_morale.gd) -------------------------


class TestFailStates:
    def test_starvation_path(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        start_day = run.st.day
        crew_trace: list[int] = []
        counter_trace: list[int] = []
        for _ in range(7):
            run.one_day()
            crew_trace.append(fleet_lib.total_crew(run.state.fleet))
            counter_trace.append(run.state.starvation_days)
        assert counter_trace == [1, 2, 3, 4, 5, 6, 7]
        assert [reason for kind, reason in run.events
                if kind == "game_over"] == ["starvation"]
        assert run.st.day - start_day == 7
        assert crew_trace == [14, 13, 12, 11, 10, 9, 8]
        assert run.state.game_over_reason == "starvation"

    def test_morale_once_per_shortfall_day(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        self_seed = seed_for_first_outcome(run, CALM_CELL, "strong")
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(run.state, self_seed)
        run.one_day()
        assert run.state.morale == 64  # −1 −5, applied by step 4 only

    def test_scurvy_path_base(self) -> None:
        run = make_run(crew=15, provisions=200, water=0, gold=100000,
                       morale=70, cell=CALM_CELL)
        assert sim.scurvy_limit_days(run.st, run.store) == 8
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        start_day = run.st.day
        counter_trace: list[int] = []
        for _ in range(8):
            run.one_day()
            counter_trace.append(run.state.scurvy_days)
        assert counter_trace == [1, 2, 3, 4, 5, 6, 7, 8]
        assert [reason for kind, reason in run.events
                if kind == "game_over"] == ["scurvy"]
        assert run.st.day - start_day == 8
        assert run.state.starvation_days == 0

    def test_both_short_reports_starvation_first(self) -> None:
        run = make_run(crew=15, provisions=0, water=0, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        for _ in range(7):
            run.one_day()
        assert run.state.game_over_reason == "starvation"
        assert run.state.scurvy_days == 7

    def test_scurvy_grace_con100(self) -> None:
        run = make_run(crew=15, provisions=200, water=0, gold=100000,
                       morale=70, cell=CALM_CELL, constitution=100)
        assert sim.scurvy_limit_days(run.st, run.store) == 17

    def test_scurvy_grace_surgeon(self) -> None:
        # medicine 30 (the GDScript double's value) → threshold 10; the
        # 10th water-short day ends the run, the 9th does not.
        stub = OfficerStubStore(data(), {
            "off_surgeon": {"id": "off_surgeon", "skills": {"medicine": 30},
                            "main_skill": "medicine"},
        })
        run = make_run(crew=15, provisions=200, water=0, gold=100000,
                       morale=70, cell=CALM_CELL, store=stub)
        run.st.player["officers"] = ["off_surgeon"]
        run.st.officer_states["off_surgeon"] = {
            "post_id": "surgeon", "ship_id": "", "loyalty": 50, "sea_days": 0,
        }
        assert sim.scurvy_limit_days(run.st, run.store) == 10
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        for _ in range(9):
            run.one_day()
        assert not sim.is_game_over(run.state)
        assert run.state.scurvy_days == 9
        run.one_day()
        assert run.state.game_over_reason == "scurvy"

    def test_counter_reset_on_supplied_day(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=90, cell=CALM_CELL)
        seed = seed_for_first_outcome(run, CALM_CELL, "strong")
        sim.set_weather_seed(run.state, seed)
        for _ in range(3):
            run.one_day()
        assert run.state.starvation_days == 3
        for _ in range(2):
            run.state.fleet[0]["provisions"] = 50
            run.one_day()
        assert run.state.starvation_days == 0
        day_before = run.st.day
        for _ in range(6):
            run.state.fleet[0]["provisions"] = 0
            run.one_day()
        assert not sim.is_game_over(run.state)
        assert run.state.starvation_days == 6
        run.state.fleet[0]["provisions"] = 0
        run.one_day()
        assert run.state.game_over_reason == "starvation"
        assert run.st.day == day_before + 7

    def test_crew_loss_formula(self) -> None:
        run = make_run(crew=100, provisions=0, water=200, gold=100000,
                       morale=90, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.one_day()
        assert fleet_lib.total_crew(run.state.fleet) == 95

        run = make_run(crew=1, provisions=0, water=200, gold=100000,
                       morale=90, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.one_day()
        run.one_day()
        assert fleet_lib.total_crew(run.state.fleet) == 1
        assert run.state.starvation_days == 2
        assert sim.CREW_FLOOR == 1


# --- §4.8.3 mutiny (tools/test_morale.gd) ------------------------------------


class TestMutiny:
    def test_closed_form(self) -> None:
        expected = 1.0 - (1.0 - sim.MUTINY_CHANCE_PER_DAY) ** 5
        assert abs(expected - 0.7627) < 0.00005

    def test_threshold_is_strict(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=20, cell=CALM_CELL)
        assert sim.mutiny_is_possible(run.state) is False
        run.state.morale = 19
        assert sim.mutiny_is_possible(run.state) is True

    def test_never_in_port(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=0, cell=CALM_CELL, docked="lisbon")
        sim.set_mutiny_seed(run.state, MUTINY_SEED)
        hits = 0
        for _ in range(15):
            run.state.morale = 0
            sim.advance_port_day(run.state, run.st, run.store, run.economy)
            if run.state.pending_mutiny:
                hits += 1
        assert hits == 0
        assert sim.mutiny_is_possible(run.state) is False

    def test_charisma_multiplier_table(self) -> None:
        for charisma, multiplier in ((10, 1.0), (20, 0.95), (30, 0.90),
                                     (100, 0.55)):
            run = make_run(crew=15, provisions=50, water=50, gold=100000,
                           morale=10, cell=CALM_CELL, charisma=charisma)
            assert sim.charisma_loss_multiplier(run.st) == \
                pytest.approx(multiplier)
        run = make_run(charisma=100, cell=CALM_CELL)
        assert sim.MUTINY_CHANCE_PER_DAY \
            * sim.charisma_loss_multiplier(run.st) == pytest.approx(0.1375)

    def test_mutiny_at_low_morale_fires(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=20, cell=CALM_CELL)
        sim.set_mutiny_seed(run.state, MUTINY_SEED + 9)
        events = 0
        for _ in range(12):
            run.state.morale = 20
            run.one_day()
            if run.state.pending_mutiny:
                events += 1
                sim.resolve_mutiny_suppress(run.state, run.st)
        assert events > 0

    def test_no_mutiny_at_or_above_threshold(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=21, cell=CALM_CELL)
        sim.set_mutiny_seed(run.state, MUTINY_SEED)
        sim.set_weather_seed(run.state, WEATHER_SEED)
        wrongly = 0
        for _ in range(15):
            run.state.morale = 21
            run.one_day()
            if run.state.pending_mutiny:
                if run.state.morale >= sim.MUTINY_THRESHOLD:
                    wrongly += 1
                if not sim.resolve_mutiny_suppress(run.state, run.st):
                    sim.resolve_mutiny_pay(run.state, run.st)
        assert wrongly == 0

    def test_mutiny_stream_independent_of_weather(self) -> None:
        # The mutiny draw count is exactly one per eligible day: a pending
        # offer blocks the check (no draws), and a port day draws nothing.
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=10, cell=CALM_CELL)
        sim.set_mutiny_seed(run.state, 7)
        before = run.state.mutiny_rng.state
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        run.one_day()
        assert run.state.mutiny_rng.state == before  # blocked: no draw
        run.state.pending_mutiny = {}
        run.one_day()
        assert run.state.mutiny_rng.state != before  # one draw

    def test_resolve_pay(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=1000,
                       morale=10, cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        offer = sim.mutiny_offer(run.state, run.st)
        assert offer["crew"] == 15 and offer["cost"] == 300
        assert offer["can_pay"] is True
        assert sim.resolve_mutiny_pay(run.state, run.st) is True
        assert run.st.gold == 700
        assert run.state.morale == 50
        assert run.state.pending_mutiny == {}
        assert sim.resolve_mutiny_pay(run.state, run.st) is False

    def test_pay_disabled_when_short(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=299,
                       morale=10, cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        offer = sim.mutiny_offer(run.state, run.st)
        assert offer["can_pay"] is False
        assert sim.resolve_mutiny_pay(run.state, run.st) is False
        assert run.st.gold == 299
        assert run.state.morale == 10

    def test_pay_exactly_affordable(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=300,
                       morale=10, cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        assert sim.resolve_mutiny_pay(run.state, run.st) is True
        assert run.st.gold == 0

    def test_resolve_suppress(self) -> None:
        run = make_run(crew=20, provisions=50, water=50, gold=0, morale=10,
                       cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        assert sim.resolve_mutiny_suppress(run.state, run.st) is True
        assert fleet_lib.total_crew(run.state.fleet) == 14
        assert run.state.morale == 40

        run = make_run(crew=2, provisions=50, water=50, gold=0, morale=10,
                       cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        sim.resolve_mutiny_suppress(run.state, run.st)
        assert fleet_lib.total_crew(run.state.fleet) == 1

    def test_resolve_fizzle(self) -> None:
        run = make_run(crew=1, provisions=50, water=50, gold=0, morale=10,
                       cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        offer = sim.mutiny_offer(run.state, run.st)
        assert offer["can_pay"] is False
        assert offer["can_suppress"] is False
        assert offer["can_fizzle"] is True
        assert sim.resolve_mutiny_pay(run.state, run.st) is False
        assert sim.resolve_mutiny_suppress(run.state, run.st) is False
        sim.resolve_mutiny_fizzle(run.state, run.st)
        assert run.state.morale == 15
        assert run.state.pending_mutiny == {}
        assert fleet_lib.total_crew(run.state.fleet) == 1

        run = make_run(crew=1, provisions=50, water=50, gold=0, morale=99,
                       cell=CALM_CELL)
        run.state.pending_mutiny = sim.mutiny_offer(run.state, run.st)
        sim.resolve_mutiny_fizzle(run.state, run.st)
        assert run.state.morale == 100

    def test_ledger_queues_one_modal_per_hit(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=10, cell=CALM_CELL)
        sim.set_mutiny_seed(run.state, MUTINY_SEED)
        hits = 0
        for _ in range(60):
            run.state.morale = 10
            run.one_day()
            mutinies = [entry for entry in
                        sim.take_last_day_dialogs(run.state)
                        if entry.get("kind") == "mutiny"
                        and entry.get("key") == "world.mutiny.text"]
            if run.state.pending_mutiny:
                hits += 1
                assert len(mutinies) == 1
                assert mutinies[0]["offer"] == run.state.pending_mutiny
                sim.resolve_mutiny_pay(run.state, run.st)
            else:
                assert len(mutinies) == 0
        assert hits > 0

    def test_take_dialogs_drains(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=5, cell=CALM_CELL)
        seed = seed_for_first_outcome(run, CALM_CELL, "storm")
        sim.set_weather_seed(run.state, seed)
        sim.set_mutiny_seed(run.state, 4)
        run.state.morale = 5
        run.one_day()
        if run.state.pending_mutiny:
            buffer = sim.take_last_day_dialogs(run.state)
            assert len(buffer) == 1
            assert buffer[0]["kind"] == "mutiny"
        assert sim.take_last_day_dialogs(run.state) == []


# --- §4.8.2 desertion (tools/test_morale.gd _test_desertion) -----------------


class TestDesertion:
    def test_matrix(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=1000,
                       morale=39, cell=CALM_CELL)
        assert sim.apply_desertion(run.state, run.st) == 1
        assert fleet_lib.total_crew(run.state.fleet) == 14

        run = make_run(crew=15, provisions=50, water=50, gold=1000,
                       morale=40, cell=CALM_CELL)
        assert sim.apply_desertion(run.state, run.st) == 0

        run = make_run(crew=100, provisions=50, water=50, gold=1000,
                       morale=39, cell=CALM_CELL)
        assert sim.apply_desertion(run.state, run.st) == 10

        run = make_run(crew=1, provisions=50, water=50, gold=1000,
                       morale=0, cell=CALM_CELL)
        assert sim.apply_desertion(run.state, run.st) == 0

    def test_charisma_scales_the_loss(self) -> None:
        run = make_run(crew=100, provisions=50, water=50, gold=1000,
                       morale=39, cell=CALM_CELL, charisma=20)
        assert sim.charisma_loss_multiplier(run.st) == pytest.approx(0.95)
        assert sim.apply_desertion(run.state, run.st) == 9
        assert fleet_lib.total_crew(run.state.fleet) == 91

        run = make_run(crew=100, provisions=50, water=50, gold=1000,
                       morale=39, cell=CALM_CELL, charisma=10)
        assert sim.apply_desertion(run.state, run.st) == 10

        run = make_run(crew=100, provisions=50, water=50, gold=1000,
                       morale=39, cell=CALM_CELL, charisma=100)
        assert sim.apply_desertion(run.state, run.st) == 5


# --- §4.9 sinking (tools/test_morale.gd _test_sinking) -----------------------


class TestSinking:
    def test_single_ship_game_over(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.state.fleet[0]["durability"] = 0
        run.one_day()
        assert [reason for kind, reason in run.events
                if kind == "game_over"] == ["sunk"]
        assert run.state.game_over_reason == "sunk"
        assert run.st.day == 2  # the sinking day still completes its tick

    def test_no_second_game_over(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.state.fleet[0]["durability"] = 0
        run.one_day()
        overs = [reason for kind, reason in run.events
                 if kind == "game_over"]
        run.advance(2.0)
        assert [reason for kind, reason in run.events
                if kind == "game_over"] == overs

    def test_flagship_relocation(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL,
                       ship_ids=("caravel", "nao"))
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        flagship = run.state.fleet[0]
        flagship["durability"] = 0
        flagship["cargo"] = {"wine": 10}
        run.state.fleet[1]["provisions"] = 0
        run.state.fleet[1]["water"] = 0
        run.one_day()
        assert run.state.game_over_reason == ""
        assert len(run.state.fleet) == 1
        assert str(run.state.fleet[0].get("ship_type_id", "")) == "nao"
        assert fleet_lib.flagship(run.state.fleet)["crew"] == 15
        assert fleet_lib.supplies(run.state.fleet, "provisions") > 0
        assert fleet_lib.held(run.state.fleet, "wine") == 10
        assert drain_dialog_keys(run) == ["world.flagship_lost"]

    def test_overflow_lost_with_the_hull(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL,
                       ship_ids=("caravel", "latin"))
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.state.fleet[0]["durability"] = 0
        run.one_day()
        assert len(run.state.fleet) == 1
        assert str(run.state.fleet[0].get("ship_type_id", "")) == "latin"
        moved = fleet_lib.supplies(run.state.fleet, "provisions") \
            + fleet_lib.supplies(run.state.fleet, "water")
        assert moved <= fleet_lib.ship_stat(run.state.fleet[0], "capacity")
        assert moved < 400

    def test_escort_lost_with_cargo(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL,
                       ship_ids=("caravel", "nao"))
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.state.fleet[1]["cargo"] = {"wine": 20}
        run.state.fleet[1]["durability"] = 0
        run.one_day()
        assert run.state.game_over_reason == ""
        assert len(run.state.fleet) == 1
        assert fleet_lib.held(run.state.fleet, "wine") == 0
        assert drain_dialog_keys(run) == ["world.ship_lost"]


# --- §4.7 dialog queue order (tools/test_morale.gd _test_dialog_order) ------


class TestDialogOrder:
    def test_sort_restores_documented_order(self) -> None:
        entries = [
            {"kind": "greeting", "key": "world.arrive"},
            {"kind": "desertion", "key": "world.desertion"},
            {"kind": "mutiny", "key": "world.mutiny.text"},
            {"kind": "weather", "key": "world.storm_damage"},
        ]
        assert drain_keys_of(sim.sort_dialogs(entries)) == [
            "world.storm_damage", "world.mutiny.text", "world.desertion",
            "world.arrive",
        ]
        sinking = [
            {"kind": "greeting", "key": "world.arrive"},
            {"kind": "mutiny", "key": "world.mutiny.text"},
            {"kind": "sinking", "key": "world.ship_lost"},
            {"kind": "weather", "key": "world.storm_damage"},
        ]
        assert drain_keys_of(sim.sort_dialogs(sinking)) == [
            "world.storm_damage", "world.ship_lost", "world.mutiny.text",
            "world.arrive",
        ]

    def test_stable_within_kind(self) -> None:
        two_weather = [
            {"kind": "weather", "key": "world.storm_notice"},
            {"kind": "weather", "key": "world.storm_damage"},
        ]
        assert drain_keys_of(sim.sort_dialogs(two_weather)) == [
            "world.storm_notice", "world.storm_damage",
        ]


def drain_keys_of(entries: list[dict[str, Any]]) -> list[str]:
    return [str(entry.get("key", "")) for entry in entries]


# --- Port hours (tools/test_port_hours.gd) -----------------------------------


class TestPortHours:
    def test_facility_open_edges(self) -> None:
        run = make_run(docked="lisbon", clock_fraction=7.0 * 3600 / 1440.0)
        store = run.store

        def clock(hh: int, mm: int = 0) -> None:
            run.state.world["clock_fraction"] = (hh * 60 + mm) / 1440.0

        clock(7, 59)
        assert sim.facility_open(store, run.state, "lisbon", "market") \
            is False
        clock(8, 0)
        assert sim.facility_open(store, run.state, "lisbon", "market") is True
        clock(17, 59)
        assert sim.facility_open(store, run.state, "lisbon", "market") is True
        clock(18, 0)
        assert sim.facility_open(store, run.state, "lisbon", "market") \
            is False
        clock(23, 59)
        assert sim.facility_open(store, run.state, "lisbon", "tavern") is True
        clock(0, 1)
        assert sim.facility_open(store, run.state, "lisbon", "tavern") \
            is False
        clock(3, 30)
        assert sim.facility_open(store, run.state, "lisbon", "inn") is True
        assert sim.facility_open(store, run.state, "lisbon", "no_such_hall") \
            is True
        window = sim.facility_window_text(store, "lisbon", "market")
        assert window == {"open": "08:00", "close": "18:00"}
        assert sim.facility_window_text(store, "lisbon", "inn") == {}

    def test_sub_day_hour_runs_no_ledger(self) -> None:
        run = make_run(gold=1000, day=10, morale=70, clock_fraction=0.5,
                       docked="lisbon")
        ledger_day = run.st.day
        morale = run.state.morale
        gold = run.st.gold
        sim.advance_port_hours(run.state, run.st, run.store, run.economy, 1)
        assert sim.time_of_day_minutes(run.state) == 13 * 60
        assert run.st.day == ledger_day
        assert run.state.morale == morale
        assert run.st.gold == gold
        assert not [kind for kind, _ in run.events if kind == "day"]

    def test_midnight_crossing_runs_the_ledger(self) -> None:
        run = make_run(gold=1000, day=10, morale=70,
                       clock_fraction=23.0 / 24.0 + 59.0 / 1440.0,
                       docked="lisbon")
        wages_before = run.st.gold
        sim.advance_port_hours(run.state, run.st, run.store, run.economy, 1)
        assert run.st.day == 11
        assert sim.time_of_day_minutes(run.state) in (58, 59)
        assert run.st.gold < wages_before

    def test_dead_run_clock_frozen_port(self) -> None:
        run = make_run(gold=1000, day=10, morale=0, clock_fraction=0.5,
                       docked="lisbon")
        run.state.game_over_reason = "starvation"
        sim.advance_port_hours(run.state, run.st, run.store, run.economy, 1)
        assert sim.time_of_day_minutes(run.state) == 12 * 60
        assert run.st.day == 10

    def test_port_day_feeds_no_one(self) -> None:
        # Docked at 23:59 with two days of rations and ACTIVE counters: the
        # midnight roll charges wages, resets both counters, no crew loss.
        run = make_run(gold=1000, day=10, morale=70,
                       clock_fraction=23.0 / 24.0 + 59.0 / 1440.0,
                       docked="lisbon", provisions=2, water=2)
        flagship = run.state.fleet[0]
        run.state.starvation_days = 5
        run.state.scurvy_days = 3
        gold_before = run.st.gold
        crew_before = int(flagship["crew"])
        sim.advance_port_hours(run.state, run.st, run.store, run.economy, 1)
        assert run.st.day == 11
        assert int(flagship["provisions"]) == 2
        assert int(flagship["water"]) == 2
        assert run.state.starvation_days == 0
        assert run.state.scurvy_days == 0
        assert int(flagship["crew"]) == crew_before
        assert run.st.gold < gold_before
        assert run.state.game_over_reason == ""

    def test_set_sail_gate_and_clock(self) -> None:
        run = make_run(gold=1000, day=10, morale=70, clock_fraction=14.5 / 24.0,
                       docked="lisbon", provisions=20, water=20)
        assert sim.set_sail(run.state, run.st, run.store, run.economy) is True
        assert run.state.current_port is None
        assert float(run.state.world["clock_fraction"]) == \
            pytest.approx(15.5 / 24.0)
        assert run.state.world["last_departed_port"] == "lisbon"

    def test_set_sail_gates(self) -> None:
        # No run at all.
        run = make_run()
        run.st.player = {}
        run.state.fleet = []
        assert sim.set_sail(run.state, run.st, run.store, run.economy) is False
        # Not docked.
        run = make_run(docked=None)
        assert sim.set_sail(run.state, run.st, run.store, run.economy) is False
        # No supply (§4.11.2 hard gate — state untouched).
        run = make_run(docked="lisbon", provisions=0, water=0)
        fraction = run.state.world["clock_fraction"]
        assert sim.set_sail(run.state, run.st, run.store, run.economy) is False
        assert run.state.current_port == "lisbon"
        assert run.state.world["clock_fraction"] == fraction
        # No crew.
        run = make_run(docked="lisbon", crew=0)
        assert sim.set_sail(run.state, run.st, run.store, run.economy) is False
        assert run.state.current_port == "lisbon"


# --- Month-tick ordering (docs/90 §5.4; the declared ecology seam) -----------


class TestDayTickOrdering:
    def test_economy_then_month_then_day_advanced(self, monkeypatch) -> None:
        run = make_run(crew=15, provisions=100, water=100, gold=100000,
                       day=30, docked="lisbon")
        run.economy.market_stocks = build_initial_stocks(
            data().ports_list, data().goods_list)
        # A pre-existing investment: the month tick must clear it AFTER the
        # economy step ran (the recorded order proves the sequence).
        run.allegiance.month_invested = {"lisbon": 100}
        order: list[str] = []
        real_month_tick = sim.month_tick

        def spy_month_tick(store: DataStore, alg: AllegianceState,
                           st: PersonState) -> None:
            order.append("month")
            real_month_tick(store, alg, st)

        monkeypatch.setattr(sim, "month_tick", spy_month_tick)
        assert run.advance(1.0) == 1
        kinds = [kind for kind, _ in run.events]
        order.insert(0, "market")  # market hooks fire inside the economy step
        order.append("day")        # the day_advanced hook fires last
        assert "market" in kinds
        assert "day" in kinds
        assert run.allegiance.month_invested == {}
        # economy step → allegiance month tick → day_advanced hook.
        assert order == ["market", "month", "day"]
        assert run.st.day == 31
        assert run.st.day % 30 == 1

    def test_no_month_tick_off_boundary(self, monkeypatch) -> None:
        run = make_run(day=31, docked="lisbon")
        run.economy.market_stocks = build_initial_stocks(
            data().ports_list, data().goods_list)
        run.allegiance.month_invested = {"lisbon": 100}
        called = []
        monkeypatch.setattr(sim, "month_tick",
                            lambda *a, **k: called.append(True))
        run.advance(1.0)
        assert called == []
        assert run.allegiance.month_invested == {"lisbon": 100}

    def test_ecology_tick_is_the_caller_hook(self) -> None:
        # The 90-§5.4 step-5 listener seam: the day_advanced hook carries
        # the post-drift day, and sailing.py imports no ecology module.
        run = make_run(day=5)
        seen: list[int] = []
        run.state.on_day_advanced = seen.append
        run.advance(2.0)
        assert seen == [6, 7]
        import sys
        assert "server.sim.world.npc_fleets" not in sys.modules
        assert not hasattr(sim, "npc_fleets")


# --- Movement: legality, wrap, corner cut, ice (tools/test_movement.gd) ------


class TestMovementLegality:
    def test_open_diagonal_and_refusals(self) -> None:
        run = make_run()
        world = run.world
        st = run.st
        assert sim.is_move_legal(run.state, st, OPEN_CELL,
                                 (OPEN_CELL[0] + 1, OPEN_CELL[1] + 1),
                                 world) is True
        assert sim.is_move_legal(run.state, st, CORNER_FROM, CORNER_TO,
                                 world) is False
        assert sim.is_move_legal(run.state, st, CORNER_FROM,
                                 (CORNER_FROM[0] - 1, CORNER_FROM[1] - 1),
                                 world) is False
        assert sim.is_move_legal(
            run.state, st, CORNER_FROM,
            (CORNER_FROM[0] - 1, CORNER_FROM[1]), world) is True
        assert sim.is_move_legal(
            run.state, st, CORNER_FROM,
            (CORNER_FROM[0], CORNER_FROM[1] - 1), world) is False
        assert sim.is_move_legal(run.state, st, OPEN_CELL,
                                 (OPEN_CELL[0] + 2, OPEN_CELL[1]),
                                 world) is False
        assert sim.is_move_legal(run.state, st, OPEN_CELL, OPEN_CELL,
                                 world) is False

    def test_try_move_refused_costs_nothing(self) -> None:
        run = make_run()
        fraction = float(run.state.world["clock_fraction"])
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            CORNER_TO, world=run.world) is False
        assert sim.world_tile(run.state) == OPEN_CELL
        assert float(run.state.world["clock_fraction"]) == fraction
        assert run.st.day == 1

    def test_wrap_step(self) -> None:
        # x wraps mod 4320: the tile east of x = 4319 is x = 0 (§4.1); the
        # seam row y = 300 is water on both sides of the map.
        run = make_run(cell=(4319, 300))
        world = run.world
        st = run.st
        assert world.is_passable(4319, 300) and world.is_passable(0, 300)
        # The scene path (wrapped_delta → short step) crosses the seam; the
        # stored shape is normalised back inside the grid.
        assert sim.wrapped_delta((4319, 300), (0, 300),
                                 world.width) == (1, 0)
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (0, 300), world, run.ocean) is True
        assert sim.world_tile(run.state) == (0, 300)
        # And the stored shape stays inside the grid at the seam.
        assert 0 <= sim.world_tile(run.state)[0] < world.width

    def test_ice_refusal_matrix(self) -> None:
        run = make_run(cell=ICE_FREE_NEIGHBOUR)
        ocean = run.ocean
        assert sim.month_for(run.st.day) == 1
        assert sim.ice_blocks_entry(run.state, run.st, ICE_CELL, ocean) \
            is True
        before_clock = float(run.state.world["clock_fraction"])
        assert sim.is_move_legal(run.state, run.st, ICE_FREE_NEIGHBOUR,
                                 ICE_CELL, run.world, ocean) is False
        assert run.state.last_move_blocked_key == "world.ice_blocked"
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            ICE_CELL, world=run.world, ocean=ocean) is False
        assert sim.world_tile(run.state) == ICE_FREE_NEIGHBOUR
        assert float(run.state.world["clock_fraction"]) == before_clock

        # Out-of-month (July, day 181): the same tile is ordinary water.
        run = make_run(day=181, cell=ICE_FREE_NEIGHBOUR)
        assert sim.month_for(run.st.day) == 7
        assert sim.ice_blocks_entry(run.state, run.st, ICE_CELL, ocean) \
            is False
        assert run.state.last_move_blocked_key == ""
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            ICE_CELL, world=run.world, ocean=ocean) is True
        assert sim.world_tile(run.state) == ICE_CELL

        # A standing fleet is never trapped: only entry is gated.
        run = make_run(day=1, cell=ICE_CELL)
        assert sim.ice_blocks_entry(run.state, run.st, ICE_CELL, ocean) is True
        assert sim.try_move(run.state, run.st, run.store, run.economy,
                            ICE_FREE_NEIGHBOUR, world=run.world,
                            ocean=ocean) is True
        assert sim.world_tile(run.state) == ICE_FREE_NEIGHBOUR

        # The window wraps the year end: month 12 icy, month 4 open.
        run = make_run(day=360, cell=ICE_FREE_NEIGHBOUR)
        assert sim.month_for(run.st.day) == 12
        assert sim.ice_blocks_entry(run.state, run.st, ICE_CELL, ocean) is True
        run = make_run(day=361 + 3 * 30 + 15, cell=ICE_FREE_NEIGHBOUR)
        assert sim.month_for(run.st.day) == 4
        assert sim.ice_blocks_entry(run.state, run.st, ICE_CELL, ocean) \
            is False

    def test_blocked_key_resets_each_evaluation(self) -> None:
        run = make_run(cell=ICE_FREE_NEIGHBOUR)
        sim.is_move_legal(run.state, run.st, ICE_FREE_NEIGHBOUR, ICE_CELL,
                          run.world, run.ocean)
        assert run.state.last_move_blocked_key == "world.ice_blocked"
        sim.is_move_legal(run.state, run.st, ICE_FREE_NEIGHBOUR,
                          (ICE_FREE_NEIGHBOUR[0], ICE_FREE_NEIGHBOUR[1] - 1),
                          run.world, run.ocean)
        assert run.state.last_move_blocked_key == ""


# --- §4.4 storm headway / current factor on pinned raster tiles --------------


class TestCurrents:
    def test_current_factor_matrix(self) -> None:
        run = make_run(cell=CURRENT_STRONG)
        # Gulf Stream tile: NE, strength 3.
        month = sim.month_for(run.st.day)
        assert run.ocean.current_at(*CURRENT_STRONG, month) == \
            {"dir": "NE", "strength": 3}
        assert sim.current_factor(run.state, "NE", CURRENT_STRONG, month,
                                  run.ocean) == pytest.approx(1.24)
        assert sim.current_factor(run.state, "SW", CURRENT_STRONG, month,
                                  run.ocean) == pytest.approx(0.76)
        # E is 45° off NE → aligned (1.24); SE is the 90° identity bucket.
        assert sim.current_factor(run.state, "E", CURRENT_STRONG, month,
                                  run.ocean) == pytest.approx(1.24)
        assert sim.current_factor(run.state, "SE", CURRENT_STRONG, month,
                                  run.ocean) == pytest.approx(1.0)
        assert sim.current_factor(run.state, "", CURRENT_STRONG, month,
                                  run.ocean) == pytest.approx(1.0)

    def test_drift_mode_identity_factor(self) -> None:
        run = make_run(cell=CURRENT_STRONG)
        run.state.control_prefs["current_mode"] = "drift"
        assert sim.drift_mode_active(run.state) is True
        assert sim.current_factor(run.state, "NE", CURRENT_STRONG, 1,
                                  run.ocean) == 1.0

    def test_drift_push_strength3(self) -> None:
        run = make_run(cell=CURRENT_STRONG)
        run.state.control_prefs["current_mode"] = "drift"
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CURRENT_STRONG, "strong"))
        run.one_day()
        # 4 tiles/day along NE, wrap-aware, stop-before-land.
        assert sim.world_tile(run.state) == (CURRENT_STRONG[0] + 4,
                                             CURRENT_STRONG[1] - 4)
        assert run.state.fleet[0]["durability"] == 90  # drift deals nothing

    def test_drift_push_accumulates_half_tiles(self) -> None:
        run = make_run(cell=CURRENT_WEAK)
        month = sim.month_for(run.st.day)
        assert run.ocean.current_at(*CURRENT_WEAK, month) == \
            {"dir": "E", "strength": 1}
        run.state.control_prefs["current_mode"] = "drift"
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CURRENT_WEAK, "strong"))
        run.one_day()
        # Strength 1 pushes 0.5 tiles/day: two days for one tile.
        assert sim.world_tile(run.state) == CURRENT_WEAK
        run.one_day()
        assert sim.world_tile(run.state) == (CURRENT_WEAK[0] + 1,
                                             CURRENT_WEAK[1])

    def test_modifier_mode_does_not_push(self) -> None:
        run = make_run(cell=CURRENT_STRONG)  # modifier is the default mode
        run.one_day()
        assert sim.world_tile(run.state) == CURRENT_STRONG

    def test_drift_suppressed_while_docked(self) -> None:
        run = make_run(cell=CURRENT_STRONG, docked="lisbon")
        run.state.control_prefs["current_mode"] = "drift"
        run.state.drift_accumulator = 3.0
        run.one_day()
        assert sim.world_tile(run.state) == CURRENT_STRONG
        assert run.state.drift_accumulator == 0.0


# --- Docking + port entry (tools/test_movement.gd harbor-pair pins) ----------


def harbor_fixture(world: Any, port_id: str, berth: tuple[int, int],
                   shore: tuple[int, int]) -> None:
    """The raster's harbor-table test seam: inject a synthetic pair (the
    lazy tile indexes are invalidated so the lookups rebuild)."""
    world._harbors[port_id] = berth
    world._shores[port_id] = shore
    world._port_at = None
    world._shore_at = None


class TestDocking:
    def test_orthogonal_dock_real_lisbon(self) -> None:
        run = make_run(cell=(2050, 615))
        world = run.world
        assert world.port_cell("lisbon") == (2050, 615)
        assert world.shore_cell("lisbon") == (2051, 615)
        run.state.known_ports = []
        run.state.world["clock_fraction"] = 0.0
        entered: list[str] = []
        run.state.on_port_entered = entered.append
        cost = sim.move_cost(run.state, run.st, run.store)
        assert cost == pytest.approx(0.05)
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (2051, 615), world, run.ocean) is True
        assert entered == ["lisbon"]
        assert float(run.state.world["clock_fraction"]) == \
            pytest.approx(cost + 1.0 / 24.0)
        assert sim.world_tile(run.state) == (2050, 615)  # parked on the berth
        assert world.is_passable(*sim.world_tile(run.state))
        assert "lisbon" in run.state.known_ports  # discovered by entering
        assert run.state.current_port == "lisbon"
        entries = drain_dialog_keys(run)
        assert "world.arrive" in entries

    def test_synthetic_harbor_dock(self) -> None:
        # A synthetic pair on open water: (1400,640) berth + (1401,640)
        # shore injected through the raster seam (the shore tile is land by
        # declaration; the docking rule reads the pair table, not terrain).
        run = make_run(cell=(1400, 640))
        world = run.world
        harbor_fixture(world, "testport", (1400, 640), (1401, 640))
        try:
            run.state.world["clock_fraction"] = 0.0
            assert sim.try_step(run.state, run.st, run.store, run.economy,
                                run.motion, (1401, 640), world,
                                run.ocean) is True
            assert run.state.current_port == "testport"
            assert "testport" in run.state.known_ports
            assert sim.world_tile(run.state) == (1400, 640)
            assert run.state.world["heading"] == "E"
        finally:
            world._harbors.pop("testport", None)
            world._shores.pop("testport", None)
            world._port_at = None
            world._shore_at = None
            run.state.known_ports.remove("testport")

    def test_diagonal_into_shore_refused(self) -> None:
        # Marseille's shore tile has a water diagonal, but the target is
        # land: the diagonal stays an illegal move (no corner cutting) and
        # docks nothing.
        run = make_run(cell=(2223, 561))
        world = run.world
        assert world.shore_port_at(2224, 560) == "marseille"
        assert world.is_passable(2223, 561)
        clock = float(run.state.world["clock_fraction"])
        day = run.st.day
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (2224, 560), world,
                            run.ocean) is False
        assert run.state.current_port is None
        assert sim.world_tile(run.state) == (2223, 561)
        assert float(run.state.world["clock_fraction"]) == clock
        assert run.st.day == day

    def test_crossing_a_berth_docks_nothing(self) -> None:
        run = make_run(cell=(2049, 615))
        world = run.world
        assert world.is_passable(2049, 615)
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (2050, 615), world,
                            run.ocean) is True
        assert run.state.current_port is None
        assert sim.world_tile(run.state) == (2050, 615)

    def test_non_shore_land_is_a_blocked_move(self) -> None:
        run = make_run(cell=(2049, 617), clock_fraction=0.25)
        world = run.world
        assert world.is_passable(2049, 617)
        assert world.shore_port_at(2050, 617) == ""
        assert world.char_at(2050, 617) == "#"
        clock = float(run.state.world["clock_fraction"])
        day = run.st.day
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (2050, 617), world,
                            run.ocean) is False
        assert run.state.current_port is None
        assert float(run.state.world["clock_fraction"]) == clock
        assert run.st.day == day
        assert sim.world_tile(run.state) == (2049, 617)

    def test_dock_records_heading_and_ends_cadence(self) -> None:
        run = make_run(cell=(2050, 615))
        run.motion.helm_stepping = True
        run.motion.sail_path = [(2049, 615)]
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (2051, 615), run.world,
                            run.ocean) is True
        assert run.state.world["heading"] == "E"
        assert run.motion.helm_stepping is False
        assert run.motion.sail_path == []

    def test_try_step_rejects_non_adjacent(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (OPEN_CELL[0] + 5, OPEN_CELL[1]),
                            run.world, run.ocean) is False

    def test_furled_fleet_cannot_step(self) -> None:
        run = make_run(cell=OPEN_CELL)
        run.state.world["sail_trim"] = "furled"
        fraction = float(run.state.world["clock_fraction"])
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (OPEN_CELL[0] + 1, OPEN_CELL[1]),
                            run.world, run.ocean) is False
        assert sim.world_tile(run.state) == OPEN_CELL
        assert float(run.state.world["clock_fraction"]) == fraction

    def test_step_records_heading(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.try_step(run.state, run.st, run.store, run.economy,
                            run.motion, (OPEN_CELL[0], OPEN_CELL[1] + 1),
                            run.world, run.ocean) is True
        assert run.state.world["heading"] == "S"
        # A blocked move records nothing.
        run.state.world["heading"] = "E"
        sim.try_step(run.state, run.st, run.store, run.economy, run.motion,
                     CORNER_TO, run.world, run.ocean)
        assert run.state.world["heading"] == "E"


# --- Sighting reveal (§4.11/§4.12) -------------------------------------------


class TestReveal:
    def test_sighting_discovers_and_explores(self) -> None:
        run = make_run(cell=(2049, 615))  # the water tile beside Lisbon
        newly = sim.reveal(run.state, run.st, run.store, run.world, run.ocean)
        assert "lisbon" in run.state.known_ports
        assert "lisbon" in newly
        assert (2049, 615) in run.state.explored_tiles
        # The explored set == the wrap-aware sighting square.
        radius = sim.sighting_radius(run.st, run.store)  # nav 60 → 53
        assert radius == 53
        expected = 0
        for dy in range(-radius, radius + 1):
            y = 615 + dy
            if 0 <= y < 2160:
                expected += 2 * radius + 1
        assert len(run.state.explored_tiles) == expected
        assert (2049 + radius + 1, 615) not in run.state.explored_tiles

    def test_far_port_stays_unknown(self) -> None:
        run = make_run(cell=OPEN_CELL)
        newly = sim.reveal(run.state, run.st, run.store, run.world, run.ocean)
        assert "lisbon" not in run.state.known_ports
        assert newly == []
        assert OPEN_CELL in run.state.explored_tiles


# --- Click-to-sail (§4.2 task H) ---------------------------------------------


class TestClickToSail:
    def test_route_is_walked_through_the_normal_rules(self) -> None:
        run = make_run(cell=OPEN_CELL)
        target = (OPEN_CELL[0] + 9, OPEN_CELL[1] + 6)
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, target, run.world,
                           run.ocean) is True
        assert sim.sail_active(run.motion) is True
        assert run.motion.sail_target == target
        # The route walks on the hold cadence: N steps at 0.125 s each.
        sim.advance_motion(run.state, run.st, run.store, run.economy,
                           run.motion, sim.HOLD_DELAY_SECONDS
                           + 40 * sim.SAIL_STEP_SECONDS,
                           run.world, run.ocean)
        assert sim.world_tile(run.state) == target
        assert sim.sail_active(run.motion) is False

    def test_each_route_step_charges_the_clock(self) -> None:
        run = make_run(cell=OPEN_CELL)
        target = (OPEN_CELL[0] + 3, OPEN_CELL[1])
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, target, run.world, run.ocean) is True
        fraction = float(run.state.world["clock_fraction"])
        sim.advance_motion(run.state, run.st, run.store, run.economy,
                           run.motion, 20 * sim.SAIL_STEP_SECONDS,
                           run.world, run.ocean)
        assert sim.world_tile(run.state) == target
        assert float(run.state.world["clock_fraction"]) - fraction == \
            pytest.approx(0.05 * 3)

    def test_land_click_refused(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, (2050, 616), run.world,
                           run.ocean) is False
        assert sim.sail_active(run.motion) is False

    def test_own_tile_click_is_a_noop(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, OPEN_CELL, run.world,
                           run.ocean) is False

    def test_no_path_click_refused(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, NO_PATH_CELL, run.world,
                           run.ocean) is False
        assert sim.sail_active(run.motion) is False

    def test_shore_click_docks_on_arrival(self) -> None:
        run = make_run(cell=(2048, 615))
        assert run.world.is_passable(2048, 615)
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, (2051, 615), run.world,
                           run.ocean) is True
        assert run.motion.sail_dock_port == "lisbon"
        sim.advance_motion(run.state, run.st, run.store, run.economy,
                           run.motion, sim.HOLD_DELAY_SECONDS
                           + 20 * sim.SAIL_STEP_SECONDS,
                           run.world, run.ocean)
        assert run.state.current_port == "lisbon"
        assert sim.world_tile(run.state) == (2050, 615)
        assert sim.sail_active(run.motion) is False

    def test_manual_input_cancels_the_route(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.sail_to(run.state, run.st, run.store, run.economy,
                           run.motion, (OPEN_CELL[0] + 9, OPEN_CELL[1] + 6),
                           run.world, run.ocean) is True
        sim.press_direction(run.state, run.st, run.store, run.economy,
                            run.motion, "move_e", run.world, run.ocean)
        assert sim.sail_active(run.motion) is False


# --- §4.2 input modes: hold, helm, wait, trim --------------------------------


class TestInputModes:
    def test_hold_to_repeat_cadence(self) -> None:
        run = make_run(cell=OPEN_CELL, provisions=200, water=200)
        assert sim.press_direction(run.state, run.st, run.store,
                                   run.economy, run.motion, "move_e",
                                   run.world, run.ocean) is True
        assert sim.world_tile(run.state) == (OPEN_CELL[0] + 1, OPEN_CELL[1])
        # 0.25 s delay, then ~8 tiles/s: 100 held steps exactly.
        sim.advance_motion(run.state, run.st, run.store, run.economy,
                           run.motion, sim.HOLD_DELAY_SECONDS
                           + 99 * sim.SAIL_STEP_SECONDS,
                           run.world, run.ocean)
        assert sim.world_tile(run.state) == \
            (OPEN_CELL[0] + 100, OPEN_CELL[1])
        sim.release_direction(run.motion)
        assert run.motion.hold_action == ""

    def test_blocked_held_step_banks_nothing(self) -> None:
        run = make_run(cell=OPEN_CELL)
        # Hold east into the long open run, then verify a blocked slot
        # produces no move and no banked catch-up: walk to the reef-free
        # corner fixture and hold into land.
        run = make_run(cell=(CORNER_FROM[0], CORNER_FROM[1]))
        assert sim.press_direction(run.state, run.st, run.store,
                                   run.economy, run.motion, "move_n",
                                   run.world, run.ocean) is False
        assert sim.world_tile(run.state) == (CORNER_FROM[0], CORNER_FROM[1])
        sim.advance_motion(run.state, run.st, run.store, run.economy,
                           run.motion, 5.0, run.world, run.ocean)
        # Every repeat was refused (the tile north is land): the fleet
        # never moved, and nothing was banked for later.
        assert sim.world_tile(run.state) == (CORNER_FROM[0], CORNER_FROM[1])
        assert run.motion.hold_action == "move_n"

    def test_helm_steer_persists_and_auto_steps(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.helm_steer(run.state, run.motion, "move_e") is True
        assert sim.helm_active(run.motion) is True
        assert sim.helm_heading(run.state) == "E"
        interval = sim.helm_interval(run.state, run.st, run.store, run.world,
                                     run.ocean)
        assert interval == pytest.approx(0.12)  # 1/20 clamped to the 0.12 floor
        sim.advance_motion(run.state, run.st, run.store, run.economy,
                           run.motion, interval * 5 + 0.001, run.world,
                           run.ocean)
        assert sim.world_tile(run.state)[0] > OPEN_CELL[0]
        # A course change retargets without stopping.
        assert sim.helm_steer(run.state, run.motion, "move_s") is True
        assert sim.helm_heading(run.state) == "S"
        assert sim.helm_active(run.motion) is True
        sim.helm_stop(run.motion)
        assert sim.helm_active(run.motion) is False
        assert sim.helm_heading(run.state) == "S"  # the heading persists

    def test_helm_refused_while_docked(self) -> None:
        run = make_run(docked="lisbon")
        assert sim.helm_steer(run.state, run.motion, "move_e") is False
        assert sim.helm_active(run.motion) is False

    def test_press_wait_two_helm_presses(self) -> None:
        run = make_run(cell=OPEN_CELL)
        run.state.control_prefs["input_mode"] = "helm"
        sim.helm_steer(run.state, run.motion, "move_e")
        first = sim.press_wait(run.state, run.st, run.store, run.economy,
                               run.motion)
        assert first == {"stopped": True, "waited": False}
        assert sim.helm_active(run.motion) is False
        second = sim.press_wait(run.state, run.st, run.store, run.economy,
                                run.motion)
        assert second == {"stopped": False, "waited": True}
        assert run.st.day == 2  # the wait ran the full ledger
        # A furled fleet can still wait (§4.17).
        run = make_run(cell=OPEN_CELL)
        run.state.world["sail_trim"] = "furled"
        assert sim.press_wait(run.state, run.st, run.store, run.economy,
                              run.motion)["waited"] is True
        # Docked: the wait is refused (a port day is advance_port_day's).
        run = make_run(docked="lisbon")
        assert sim.press_wait(run.state, run.st, run.store, run.economy,
                              run.motion)["waited"] is False

    def test_wait_at_sea_advances_one_day(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.wait_at_sea(run.state, run.st, run.store,
                               run.economy) is True
        assert run.st.day == 2
        assert float(run.state.world["clock_fraction"]) == pytest.approx(0.0)
        assert sim.world_tile(run.state) == OPEN_CELL

    def test_cycle_trim(self) -> None:
        run = make_run()
        assert sim.cycle_trim(run.state, True) == "full"
        assert sim.cycle_trim(run.state, True) == "furled"
        assert sim.cycle_trim(run.state, True) == "reefed"
        assert sim.cycle_trim(run.state, True) == "normal"
        assert sim.cycle_trim(run.state, False) == "reefed"


# --- At-sea minor repair (40-* §4.5) -----------------------------------------


class TestAtSeaRepair:
    def test_gate_requires_carpenter(self) -> None:
        run = make_run(cell=CALM_CELL)
        run.state.fleet[0]["durability"] = 80
        assert sim.at_sea_repair_gate_met(run.st, run.store) is False
        assert sim.at_sea_repair_available(run.state, run.st,
                                           run.store) is False

    def test_carpenter_gate_and_fee(self) -> None:
        stub = OfficerStubStore(data(), {
            "off_carpenter": {"id": "off_carpenter",
                              "skills": {"carpentry": 80},
                              "main_skill": "carpentry"},
        })
        run = make_run(cell=CALM_CELL, gold=100000, store=stub)
        run.st.player["officers"] = ["off_carpenter"]
        run.st.officer_states["off_carpenter"] = {
            "post_id": "carpenter", "ship_id": "", "loyalty": 50,
            "sea_days": 0,
        }
        run.state.fleet[0]["durability"] = 80
        assert sim.at_sea_repair_gate_met(run.st, run.store) is True
        # Caravel base_price 8000 → ceil(8000/400) = 20 per point; the
        # carpenter discount at 80 is 1 − floor(80/20)/100 = 0.96 →
        # floor(10 × 20 × 0.96) = 192.
        fee = sim.at_sea_repair_fee(run.state, run.st, run.store)
        assert fee == 192
        assert sim.at_sea_repair_available(run.state, run.st,
                                           run.store) is True
        assert sim.at_sea_repair(run.state, run.st, run.store) is True
        assert run.state.fleet[0]["durability"] == 90
        assert run.st.gold == 100000 - fee
        # Once per fleet-day.
        assert sim.at_sea_repair_available(run.state, run.st,
                                           run.store) is False
        # No clock cost.
        assert run.st.day == 1

    def test_refused_when_hull_intact(self) -> None:
        stub = OfficerStubStore(data(), {
            "off_carpenter": {"id": "off_carpenter",
                              "skills": {"carpentry": 80},
                              "main_skill": "carpentry"},
        })
        run = make_run(cell=CALM_CELL, store=stub)
        run.st.player["officers"] = ["off_carpenter"]
        run.st.officer_states["off_carpenter"] = {
            "post_id": "carpenter", "ship_id": "", "loyalty": 50,
            "sea_days": 0,
        }
        assert sim.at_sea_repair_available(run.state, run.st,
                                           run.store) is False

    def test_refused_in_port(self) -> None:
        stub = OfficerStubStore(data(), {
            "off_carpenter": {"id": "off_carpenter",
                              "skills": {"carpentry": 80},
                              "main_skill": "carpentry"},
        })
        run = make_run(docked="lisbon", store=stub)
        run.st.player["officers"] = ["off_carpenter"]
        run.st.officer_states["off_carpenter"] = {
            "post_id": "carpenter", "ship_id": "", "loyalty": 50,
            "sea_days": 0,
        }
        run.state.fleet[0]["durability"] = 10
        assert sim.at_sea_repair_available(run.state, run.st,
                                           run.store) is False


# --- Officer sea-day growth seam (50-* §4.3; the advice roll is a seam) ------


class TestSeaDayGrowth:
    def test_sea_day_awards_xp_and_usage(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.one_day()
        assert character.current_xp(run.st) == 2
        run.one_day()
        assert character.current_xp(run.st) == 4
        assert run.st.player["skill_counters"]["seamanship"] == 2

    def test_port_day_awards_nothing(self) -> None:
        run = make_run(crew=15, provisions=50, water=50, gold=100000,
                       morale=70, docked="lisbon")
        sim.advance_port_day(run.state, run.st, run.store, run.economy)
        assert character.current_xp(run.st) == 0
        sim.advance_clock(run.state, run.st, run.store, run.economy, 1.0)
        assert character.current_xp(run.st) == 0


# --- Transient lifecycle ------------------------------------------------------


class TestTransientLifecycle:
    def test_reset_ledger_state_clears_everything(self) -> None:
        run = make_run()
        run.state.starvation_days = 4
        run.state.scurvy_days = 2
        run.state.game_over_reason = "scurvy"
        run.state.pending_mutiny = {"crew": 1}
        run.state.last_day_storm = True
        run.state.drift_accumulator = 2.5
        sim.reset_ledger_state(run.state)
        assert run.state.starvation_days == 0
        assert run.state.scurvy_days == 0
        assert run.state.game_over_reason == ""
        assert run.state.pending_mutiny == {}
        assert run.state.last_day_storm is False
        assert run.state.drift_accumulator == 0.0

    def test_backwards_day_resets_transients(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        for _ in range(7):
            run.one_day()
        assert sim.is_game_over(run.state)
        # A save load / new game rewinds the day: the sticky flag clears.
        run.st.day = 1
        run.one_day()
        assert not sim.is_game_over(run.state)

    def test_no_ledger_after_game_over(self) -> None:
        run = make_run(crew=15, provisions=0, water=200, gold=100000,
                       morale=70, cell=CALM_CELL)
        sim.set_weather_seed(
            run.state, seed_for_first_outcome(run, CALM_CELL, "strong"))
        run.state.fleet[0]["durability"] = 0
        run.one_day()
        assert sim.is_game_over(run.state)
        overs = [reason for kind, reason in run.events
                 if kind == "game_over"]
        assert run.advance(1.0) == 0
        assert [reason for kind, reason in run.events
                if kind == "game_over"] == overs


# --- Explore seam (§4.11 discovery radius; the module is another agent's) ----


class TestExploreSeam:
    def test_explore_hands_off_the_fleet_cell(self) -> None:
        run = make_run(cell=OPEN_CELL)
        seen: list[tuple[int, int]] = []

        def fake_explore(cell: tuple[int, int]) -> list[str]:
            seen.append(cell)
            return ["disc_a", "disc_b"]

        found = sim.explore_here(run.state, run.st, run.store, fake_explore)
        assert seen == [OPEN_CELL]
        assert found == ["disc_a", "disc_b"]

    def test_explore_without_module_finds_nothing(self) -> None:
        run = make_run(cell=OPEN_CELL)
        assert sim.explore_here(run.state, run.st, run.store) == []

    def test_radius_constants_agree_with_section5(self) -> None:
        assert sim.DISCOVERY_RADIUS == 36
        assert sim.DISCOVERY_CARTOGRAPHY_DIVISOR == 15
        # The discovery port's formula (36 + floor(cartography / 15)) —
        # re-derived here on the injected skills seam.
        run = make_run()
        run.st.player["skills"]["cartography"] = 30
        expected = 36 + int(math.floor(30 / 15.0))
        assert expected == 38
        assert skills.skill(run.st, "cartography") == 30


# --- sail_path delegation seam (§4.2: the A* is sail_path's) -----------------


class TestSailPathSeam:
    def test_wrapped_delta_uses_short_dx(self) -> None:
        assert sim.wrapped_delta((4319, 10), (0, 10), 4320) == (1, 0)
        assert sim.wrapped_delta((0, 10), (4319, 10), 4320) == (-1, 0)
        assert sim.wrapped_delta((100, 10), (1100, 10), 4320) == (1000, 0)
        assert sim.wrapped_delta((0, 10), (2160, 10), 4320) == (2160, 0)

    def test_step_is_legal_is_seam_aware(self) -> None:
        run = make_run()
        assert sim.step_is_legal(run.state, run.st, (4319, 300), (0, 300),
                                 run.world, run.ocean) is True
        assert sim.step_is_legal(run.state, run.st, OPEN_CELL,
                                 (OPEN_CELL[0] + 2, OPEN_CELL[1]),
                                 run.world, run.ocean) is False

    def test_sail_path_module_owned_by_the_other_port(self) -> None:
        # The delegation seam: sailing calls sail_path.find_path (the
        # two-stage A* port), never its own re-implementation.
        assert sim.sail_path is sail_path
        assert hasattr(sail_path, "find_path")
        assert hasattr(sail_path, "short_dx")
