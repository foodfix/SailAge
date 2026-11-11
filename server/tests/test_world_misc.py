"""server.tests.test_world_misc — the officer advice roll + the S3 arrow-field
sampler (M1).

Port of the guarantee, not the method (AGENTS.md test discipline). The
GDScript tree has no dedicated advice/arrow-field harness, so the pinned
contracts come from the owning docs and from live ``godot --headless``
probes of the pinned toolchain (Godot v4.7.stable.official.5b4e0cb0f) for
the hash-seeded roll:

  * advice (docs/IMPLEMENT-Phase8.md §2.5, docs/50-* §4.5.2, docs/10-*
    §4.21, oracle ``scripts/world/advice.gd``): the constant table, the
    hash roll replayed against captured Godot values, the trigger matrix
    (post filled/vacant × condition held/failed × roll won/lost), the
    queue order, the battle-start once-per-day gate, the drain/reset
    seams and the data-owned trigger thresholds (5 days / 50% / 40);
  * arrow field (docs/80-UI-UX.md §4.8 item 10 + item 6, oracle
    ``scripts/world/arrow_field.gd``): the pinned dir/heading tables and
    rotation map, the vector→bucket rule, the lattice (stride-4,
    world-anchored, x-wrapped, water-only, sorted), the descriptor shape
    (the M4 canvas contract) and the sampler on real shipped ocean tiles —
    a westerlies wind region, a Gulf-Stream current corridor, a no-current
    tile, a doldrums ``VAR`` tile, the Arabian-Sea monsoon flip and a land
    tile that yields no descriptor. The table/bucket/floor-div/lattice pins
    were cross-checked against a live ``godot --headless`` probe of
    ``arrow_field.gd`` driving the same fake ocean (identical 50-entry
    lattice for the 64,64 / 0×0 view, VAR cell and bucket matrix).

Deterministic: one pure replay (no RNG stream exists in either oracle) and
one sampler call per real fixture tile — no full-map walks, no Monte Carlo,
no engine boots at test time (the roll constants were captured once from
the live oracle and are pinned below).
"""

from __future__ import annotations

from typing import Any

import pytest

from server.sim.data import DataStore, data
from server.sim.fleet import fleet as fleet_lib
from server.sim.player import PersonState
from server.sim.world import advice, arrow_field
from server.sim.world.raster import GRID_HEIGHT, GRID_WIDTH, ocean_layers, raster
from server.sim.world.sailing import SailingState

# --- Advice fixtures --------------------------------------------------------

#: Six synthetic roster ids whose day-12 roll wins the 3% gate (buckets
#: 0, 1, 2, 0, 1, 2 — captured from the live Godot probe; the ids never need
#: officer cards: the advice roll reads the post table, not the roster card).
PILOT_FIRE = "off_adv_004"
BOATSWAIN_FIRE = "off_adv_005"
GUNNER_FIRE = "off_adv_006"
SURGEON_FIRE = "off_adv_035"
CARPENTER_FIRE = "off_adv_036"
COOK_FIRE = "off_adv_037"

#: The roll-winning sea day for every id above.
FIRE_DAY = 12

#: A tile one band north of the 30° boundary: y = 721 is lat 29.92
#: (trade_winds) and one degree north (y = 709, lat 30.92) is variables —
#: the pilot's "wind band changes tomorrow" condition holds.
PILOT_FLIP_CELL = (1400, 721)
#: The boundary row itself (y = 720, lat exactly 30.0 → variables) and the
#: tile one degree north of it stay in the same band: the condition fails.
PILOT_STABLE_CELL = (1400, 720)


def make_person(day: int = FIRE_DAY,
                officers: dict[str, str] | None = None) -> PersonState:
    """A bare Person block with the given ``{officer_id: post_id}`` roster
    (the appointment layer is test_person's; here the states are fixtures)."""
    st = PersonState()
    st.player = {
        "nation_id": "portugal",
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {},
        "skill_counters": {},
        "alloc_pending": 0,
        "xp": 0,
        "level": 1,
        "officers": sorted((officers or {}).keys()),
        "reputation": {},
    }
    st.officer_states = {
        officer_id: {"post_id": post_id, "ship_id": "", "loyalty": 50}
        for officer_id, post_id in (officers or {}).items()
    }
    st.day = day
    return st


def make_sailing(cell: tuple[int, int] = PILOT_FLIP_CELL,
                 weather: str = "storm", sail_trim: str = "normal",
                 morale: int = 39, crew: int = 30, water: int = 0,
                 durability: int | None = None,
                 fleet: list[Any] | None = None) -> SailingState:
    """A sailing state whose defaults hold **every** advice condition true:
    the pilot's boundary tile, a storm with the wrong (normal) trim, morale
    39 < 40, dry water tanks and a caravel hull at 0 durability."""
    if fleet is None:
        ship = fleet_lib.new_ship("caravel", crew)
        ship["water"] = water
        ship["durability"] = (0 if durability is None else durability)
        fleet = [ship]
    return SailingState(
        world={"position": {"x": cell[0], "y": cell[1]},
               "weather": weather, "sail_trim": sail_trim},
        morale=morale,
        fleet=fleet,
    )


def make_sailing_all_false() -> SailingState:
    """The mirror fixture: no condition holds (stable band, fair weather,
    reefed trim, morale 60, a full water hold, a pristine hull)."""
    ship = fleet_lib.new_ship("caravel", 30)
    ship["water"] = 999
    return SailingState(
        world={"position": {"x": PILOT_STABLE_CELL[0],
                            "y": PILOT_STABLE_CELL[1]},
               "weather": "fair", "sail_trim": "reefed"},
        morale=60,
        fleet=[ship],
    )


def one_post(post_id: str, officer_id: str) -> dict[str, str]:
    """A roster with exactly one flagship post filled."""
    return {officer_id: post_id}


@pytest.fixture()
def store() -> DataStore:
    return data()


# ============================================================================
# Advice — constants, the hash roll, the data-owned thresholds
# ============================================================================


class TestAdviceConstants:
    """docs/IMPLEMENT-Phase8.md §2.5 + docs/10-* §4.21."""

    def test_locked_table(self) -> None:
        assert advice.FIRE_PCT == 3
        assert advice.SITUATIONS == {
            "pilot": "wind_band",
            "boatswain": "storm_sail",
            "gunner": "first_contact",
            "surgeon": "water_low",
            "carpenter": "durability_low",
            "cook": "morale_low",
        }
        # Declaration order is the queue order (the oracle iterates the
        # same literal).
        assert list(advice.SITUATIONS) == [
            "pilot", "boatswain", "gunner", "surgeon", "carpenter", "cook"]

    def test_every_situation_has_bilingual_ui_text(
            self, store: DataStore) -> None:
        for post_id, situation in advice.SITUATIONS.items():
            key = f"advice.{post_id}.{situation}"
            text = store.get_ui_string(key)
            assert isinstance(text.get("zh"), str) and text["zh"], key
            assert isinstance(text.get("en"), str) and text["en"], key

    def test_post_table_matches_the_six_situations(
            self, store: DataStore) -> None:
        """The six flagship posts carry exactly one advice row each; the
        captain seat carries none (10-* §4.21)."""
        with_advice = {
            str(post["post_id"]): list(post["advice"])
            for post in store.officer_posts_list
            if isinstance(post.get("advice"), dict)
        }
        assert with_advice == {
            post_id: [situation]
            for post_id, situation in advice.SITUATIONS.items()
        }

    def test_thresholds_are_data_owned_and_locked(
            self, store: DataStore) -> None:
        """10-* §4.21: the numeric trigger params sit in the table (5 days,
        50%, 40) — never in code."""
        surgeon = store.get_officer_post("surgeon")["advice"]["water_low"]
        carpenter = store.get_officer_post("carpenter")["advice"]["durability_low"]
        cook = store.get_officer_post("cook")["advice"]["morale_low"]
        assert surgeon == {"days": 5}
        assert carpenter == {"pct": 50}
        assert cook == {"threshold": 40}
        # And the module reads them (a missing key is a loud data error).
        with pytest.raises(KeyError):
            advice.condition_holds(
                "surgeon", _StoreMissingAdvice(), make_sailing())


class _StoreMissingAdvice(DataStore):
    """A DataStore double whose post table drops the surgeon params."""

    def __init__(self) -> None:  # no load: only the lookup is used
        super().__init__()

    def get_officer_post(self, post_id: str) -> dict[str, Any]:
        return {"post_id": post_id, "advice": {"water_low": {}}}


class TestAdviceRoll:
    """The hash-seeded 3% roll (``advice.gd`` day_tick) — pinned against
    live ``godot --headless`` probes of the pinned toolchain."""

    def test_pinned_godot_hash_rolls(self) -> None:
        # Captured verbatim: abs(hash("{day}|{id}")) % 100 in Godot 4.7.
        assert advice.roll_for(1, "off_test_pilot") == 83
        assert advice.roll_for(10, "off_test_pilot") == 3
        assert advice.roll_for(12, "off_test_pilot") == 1
        assert advice.roll_for(24, "off_test_pilot") == 0
        assert advice.roll_for(32, "off_test_surgeon") == 2
        assert advice.roll_for(33, "off_test_cook") == 0
        assert advice.roll_for(15, "off_test_carpenter") == 0
        assert advice.roll_for(34, "off_test_boatswain") == 1
        assert advice.roll_for(4, "off_test_gunner") == 1
        assert advice.roll_for(18, "off_test_gunner") == 2
        assert advice.roll_for(1, "off_leg_duarte_silveira") == 34

    def test_fire_gate_is_strictly_below_three(self) -> None:
        assert advice.fires(12, "off_test_pilot") is True     # roll 1
        assert advice.fires(10, "off_test_pilot") is False    # roll 3
        assert advice.fires(1, "off_test_pilot") is False     # roll 83
        # Buckets stay in range for every id/day (the hash is a uint32).
        for day in (1, 12, 360, 361):
            assert 0 <= advice.roll_for(day, "off_adv_004") < 100


# ============================================================================
# Advice — the situation conditions (the oracle's _condition_holds)
# ============================================================================


class TestAdviceConditions:
    """docs/IMPLEMENT-Phase8.md §2.5's six situation rows."""

    def test_pilot_wind_band_lookahead(self, store: DataStore) -> None:
        # One degree north (12 tiles) crosses the 30° band boundary.
        assert advice.condition_holds("pilot", store, make_sailing()) is True
        stable = make_sailing(cell=PILOT_STABLE_CELL)
        assert advice.condition_holds("pilot", store, stable) is False
        # Deep westerlies: same band here and one degree north.
        deep = make_sailing(cell=(1400, 480))
        assert advice.condition_holds("pilot", store, deep) is False

    def test_boatswain_storm_and_trim(self, store: DataStore) -> None:
        assert advice.condition_holds(
            "boatswain", store, make_sailing(weather="storm",
                                             sail_trim="normal")) is True
        assert advice.condition_holds(
            "boatswain", store, make_sailing(weather="storm",
                                             sail_trim="reefed")) is False
        assert advice.condition_holds(
            "boatswain", store, make_sailing(weather="fair",
                                             sail_trim="normal")) is False

    def test_surgeon_water_days_boundary(self, store: DataStore) -> None:
        # crew 30 and RATION_SIZE 5: 30 units = exactly 5 days (fires);
        # 31 units is over the line (does not).
        at_line = make_sailing(crew=30, water=30)
        assert advice.condition_holds("surgeon", store, at_line) is True
        over = make_sailing(crew=30, water=31)
        assert advice.condition_holds("surgeon", store, over) is False
        empty = make_sailing(crew=30, water=0)
        assert advice.condition_holds("surgeon", store, empty) is True

    def test_carpenter_half_durability_boundary(self, store: DataStore) -> None:
        caravel = store.get_ship_type("caravel")
        max_dur = int(caravel["durability"])
        assert max_dur == 90  # the fixture the oracle suite uses
        below = make_sailing(durability=max_dur // 2 - 1)  # 44 < 45
        assert advice.condition_holds("carpenter", store, below) is True
        at_half = make_sailing(durability=max_dur // 2)    # 45 is not < 45
        assert advice.condition_holds("carpenter", store, at_half) is False
        full = make_sailing(durability=max_dur)
        assert advice.condition_holds("carpenter", store, full) is False

    def test_cook_morale_threshold(self, store: DataStore) -> None:
        assert advice.condition_holds(
            "cook", store, make_sailing(morale=39)) is True
        assert advice.condition_holds(
            "cook", store, make_sailing(morale=40)) is False
        assert advice.condition_holds(
            "cook", store, make_sailing(morale=0)) is True

    def test_gunner_and_captain_never_fire_on_a_day_tick(
            self, store: DataStore) -> None:
        assert advice.condition_holds("gunner", store, make_sailing()) is False
        assert advice.condition_holds("captain", store, make_sailing()) is False
        assert advice.condition_holds("nobody", store, make_sailing()) is False


# ============================================================================
# Advice — the day tick, the queue and the battle gate
# ============================================================================


class TestAdviceDayTick:
    """The sea-day roll's pure decision + the session queue."""

    def test_vacant_posts_never_fire(self, store: DataStore) -> None:
        state = advice.AdviceState()
        st = make_person()
        assert advice.day_tick(state, st, store, make_sailing()) == 0
        assert state.pending == []

    @pytest.mark.parametrize("post_id,officer_id", [
        ("pilot", PILOT_FIRE),
        ("boatswain", BOATSWAIN_FIRE),
        ("surgeon", SURGEON_FIRE),
        ("carpenter", CARPENTER_FIRE),
        ("cook", COOK_FIRE),
    ])
    def test_trigger_matrix_one_post(
            self, store: DataStore, post_id: str, officer_id: str) -> None:
        """Condition held + roll won → the exact payload; condition failed
        on the same day → nothing; roll lost with the condition held →
        nothing."""
        state = advice.AdviceState()
        st = make_person(officers=one_post(post_id, officer_id))
        assert advice.day_tick(state, st, store, make_sailing()) == 1
        assert state.pending == [{
            "key": f"advice.{post_id}.{advice.SITUATIONS[post_id]}",
            "post": post_id,
            "officer_id": officer_id,
        }]
        # Same day, same winning roll, condition now false.
        failed = advice.AdviceState()
        assert advice.day_tick(failed, st, store,
                               make_sailing_all_false()) == 0
        assert failed.pending == []
        # Condition held, but a losing day for every fixture id (day 1).
        lost = advice.AdviceState()
        assert advice.day_tick(lost, make_person(day=1, officers=one_post(
            post_id, officer_id)), store, make_sailing()) == 0
        assert lost.pending == []

    def test_gunner_is_not_a_day_tick_situation(self, store: DataStore) -> None:
        state = advice.AdviceState()
        st = make_person(officers=one_post("gunner", GUNNER_FIRE))
        assert advice.day_tick(state, st, store, make_sailing()) == 0

    def test_queue_order_is_the_declaration_order(self, store: DataStore) -> None:
        state = advice.AdviceState()
        st = make_person(officers={
            PILOT_FIRE: "pilot",
            BOATSWAIN_FIRE: "boatswain",
            GUNNER_FIRE: "gunner",
            SURGEON_FIRE: "surgeon",
            CARPENTER_FIRE: "carpenter",
            COOK_FIRE: "cook",
        })
        # Every condition holds in make_sailing()'s default world; the
        # gunner row is silent by design.
        assert advice.day_tick(state, st, store, make_sailing()) == 5
        assert [entry["post"] for entry in state.pending] == [
            "pilot", "boatswain", "surgeon", "carpenter", "cook"]

    def test_pinned_day_replay(self, store: DataStore) -> None:
        """The deterministic replay: the same fixture on the same day yields
        the same exact queue on both runs (no RNG state to preserve)."""
        expected = [
            {"key": "advice.pilot.wind_band", "post": "pilot",
             "officer_id": PILOT_FIRE},
            {"key": "advice.boatswain.storm_sail", "post": "boatswain",
             "officer_id": BOATSWAIN_FIRE},
            {"key": "advice.surgeon.water_low", "post": "surgeon",
             "officer_id": SURGEON_FIRE},
            {"key": "advice.carpenter.durability_low", "post": "carpenter",
             "officer_id": CARPENTER_FIRE},
            {"key": "advice.cook.morale_low", "post": "cook",
             "officer_id": COOK_FIRE},
        ]
        officers = {entry["officer_id"]: entry["post"] for entry in expected}

        def run_once() -> list[dict[str, Any]]:
            state = advice.AdviceState()
            st = make_person(officers=officers)
            advice.day_tick(state, st, store, make_sailing())
            return advice.drain(state)

        first = run_once()
        assert first == expected
        assert run_once() == first

    def test_drain_clears_and_reset_clears_everything(
            self, store: DataStore) -> None:
        state = advice.AdviceState()
        st = make_person(officers={PILOT_FIRE: "pilot",
                                   GUNNER_FIRE: "gunner"})
        advice.day_tick(state, st, store, make_sailing())
        advice.battle_start(state, st)
        assert len(state.pending) == 1
        drained = advice.drain(state)
        assert drained == [{
            "key": "advice.pilot.wind_band", "post": "pilot",
            "officer_id": PILOT_FIRE}]
        assert state.pending == []
        # The battle gate is NOT part of the queue; reset clears both.
        advice.reset(state)
        assert state.pending == [] and state.fired_battles == set()
        assert advice.drain(state) == []


class TestAdviceBattleStart:
    """The gunner's first-contact row (§2.5): once per day, no roll."""

    def test_once_per_day_gate(self) -> None:
        state = advice.AdviceState()
        st = make_person(day=12, officers={GUNNER_FIRE: "gunner"})
        entry = advice.battle_start(state, st)
        assert entry == {"key": "advice.gunner.first_contact",
                         "post": "gunner", "officer_id": GUNNER_FIRE}
        assert advice.battle_start(state, st) == {}   # second battle, same day
        st.day = 13
        assert advice.battle_start(state, st) == entry  # next day fires again
        assert state.fired_battles == {12, 13}
        # The queue is untouched: the caller queues the returned entry.
        assert state.pending == []

    def test_vacant_gunner_post_returns_empty(self) -> None:
        state = advice.AdviceState()
        assert advice.battle_start(state, make_person()) == {}
        assert state.fired_battles == set()


# ============================================================================
# Arrow field — tables, decode and the sampler
# ============================================================================


class TestArrowTables:
    """docs/80-UI-UX.md §4.8 item 6 (dir ids / bucket order) + the
    2026-11-07 rotation amendment."""

    def test_constants(self) -> None:
        assert arrow_field.STRIDE == 4
        assert arrow_field.APRON_TILES == 8
        assert arrow_field.DIR_IDS == (
            "e", "ne", "n", "nw", "w", "sw", "s", "se")
        assert arrow_field.HEADING_TOKENS == (
            "E", "NE", "N", "NW", "W", "SW", "S", "SE")
        assert arrow_field.HEADING_RAYS == (
            (1.0, 0.0), (1.0, -1.0), (0.0, -1.0), (-1.0, -1.0),
            (-1.0, 0.0), (-1.0, 1.0), (0.0, 1.0), (1.0, 1.0))
        assert arrow_field.DIR_ROTATION_DEGREES == {
            "n": 0.0, "ne": 45.0, "e": 90.0, "se": 135.0,
            "s": 180.0, "sw": 225.0, "w": 270.0, "nw": 315.0,
        }

    def test_bucket_and_dir_decode(self) -> None:
        rotation = {"e": 90.0, "ne": 45.0, "n": 0.0, "nw": 315.0,
                    "w": 270.0, "sw": 225.0, "s": 180.0, "se": 135.0}
        for bucket, (dir_id, token) in enumerate(zip(
                arrow_field.DIR_IDS, arrow_field.HEADING_TOKENS,
                strict=True)):
            assert arrow_field.dir_id_of_bucket(bucket) == dir_id
            assert arrow_field.bucket_of_compass(token) == bucket
            assert arrow_field.dir_id_of_compass(token) == dir_id
            assert arrow_field.dir_id_of_heading(token) == dir_id
            assert arrow_field.dir_id_of_heading(token.lower()) == dir_id
            assert arrow_field.rotation_degrees_of_dir(dir_id) \
                == rotation[dir_id]
        # Out of the §4.4 domain.
        assert arrow_field.bucket_of_compass("") == -1
        assert arrow_field.bucket_of_compass("E ") == -1
        assert arrow_field.dir_id_of_heading("nne") == ""
        assert arrow_field.dir_id_of_heading("") == ""
        assert arrow_field.dir_id_of_bucket(-1) == ""
        assert arrow_field.dir_id_of_bucket(8) == ""
        assert arrow_field.rotation_degrees_of_dir("") == 0.0
        assert arrow_field.rotation_degrees_of_dir("xx") == 0.0

    def test_bucket_of_vector_nearest_ray(self) -> None:
        # Each compass ray is its own bucket.
        for bucket, ray in enumerate(arrow_field.HEADING_RAYS):
            assert arrow_field.bucket_of_vector(ray) == bucket
        assert arrow_field.bucket_of_vector((0.0, 0.0)) == -1
        # The 22.5° boundary (tan 22.5° = 0.4142): a shallower rise stays
        # on east, a steeper one swings to NE.
        assert arrow_field.bucket_of_vector((1.0, -0.4)) == 0
        assert arrow_field.bucket_of_vector((1.0, -0.42)) == 1
        # Axis normalization: the axis ray scores 2·dot². A 2:1 east vector
        # swings NE (dot 6 → 36 beats the east ray's 2·16 = 32); a 2.67:1
        # vector stays east (dot 5.5 → 30.25 < 32).
        assert arrow_field.bucket_of_vector((4.0, -2.0)) == 1
        assert arrow_field.bucket_of_vector((4.0, -1.5)) == 0
        # The decoded current vectors (unit compass scaled by strength).
        assert arrow_field.bucket_of_vector((0.0, -3.0)) == 2   # N
        assert arrow_field.bucket_of_vector((0.0, 2.0)) == 6    # S
        assert arrow_field.bucket_of_vector((1.0, 0.0)) == 0    # E

    def test_floor_div(self) -> None:
        rows = [(3, 4, 0), (4, 4, 1), (-1, 4, -1), (-4, 4, -1),
                (-5, 4, -2), (7, 4, 1), (-7, 4, -2)]
        for value, divisor, expected in rows:
            assert arrow_field.floor_div(value, divisor) == expected
            assert arrow_field.floor_div(value, divisor) == value // divisor


class FakeOcean:
    """A decode double: one wind token (or a ``VAR`` cell set) and one
    current vector everywhere."""

    def __init__(self, wind: str = "W", current: tuple[float, float] = (1.0, 0.0),
                 var_cells: frozenset[tuple[int, int]] = frozenset()) -> None:
        self.wind = wind
        self.current = current
        self.var_cells = var_cells

    def prevailing_for(self, x: int, y: int, month: int) -> str:
        return "VAR" if (x, y) in self.var_cells else self.wind

    def current_vector_at(self, x: int, y: int,
                          month: int = -1) -> tuple[float, float]:
        return self.current


class TestArrowSamplerLattice:
    """§4.8 item 10: stride 4×4, world-anchored, water cells only."""

    def sample(self, center: tuple[int, int], ocean: Any,
               is_water: Any, view: tuple[int, int] = (0, 0),
               grid: tuple[int, int] = (GRID_WIDTH, GRID_HEIGHT)
               ) -> list[arrow_field.ArrowEntry]:
        return arrow_field.sample(center, view, 1, ocean, is_water,
                                  grid[0], grid[1])

    def test_anchor_and_stride(self) -> None:
        entries = self.sample((64, 64), FakeOcean(), lambda cell: True)
        cells = {entry["cell"] for entry in entries}
        expected = {(x, y) for y in range(56, 73, 4)
                    for x in range(56, 73, 4)}
        assert cells == expected
        assert all(x % arrow_field.STRIDE == 0 for x, _ in cells)
        assert all(y % arrow_field.STRIDE == 0 for _, y in cells)
        # 25 cells × (wind + current).
        assert len(entries) == 2 * len(expected)

    def test_camera_shift_within_a_stride_band_is_stable(self) -> None:
        a = self.sample((64, 64), FakeOcean(), lambda cell: True)
        b = self.sample((65, 64), FakeOcean(), lambda cell: True)
        c = self.sample((67, 64), FakeOcean(), lambda cell: True)
        assert a == b == c
        # Crossing the stride boundary moves the anchor.
        d = self.sample((68, 64), FakeOcean(), lambda cell: True)
        assert d != a
        assert min(cell[0] for cell in {e["cell"] for e in d}) == 60

    def test_water_filter_and_missing_predicate(self) -> None:
        def is_water(cell: tuple[int, int]) -> bool:
            return cell[0] != cell[1]

        entries = self.sample((64, 64), FakeOcean(), is_water)
        assert entries
        assert all(entry["cell"][0] != entry["cell"][1] for entry in entries)
        # The oracle's invalid-callable guard samples nothing.
        assert self.sample((64, 64), FakeOcean(), None) == []

    def test_grid_dimensions_guard(self) -> None:
        assert self.sample((64, 64), FakeOcean(), lambda c: True,
                           grid=(0, GRID_HEIGHT)) == []
        assert self.sample((64, 64), FakeOcean(), lambda c: True,
                           grid=(GRID_WIDTH, 0)) == []

    def test_x_wraps_into_the_grid(self) -> None:
        entries = self.sample((2, 64), FakeOcean(), lambda cell: True,
                              view=(4, 4))
        row = {entry["cell"][0] for entry in entries
               if entry["cell"][1] == 56}
        # first_x = floor((2 − 10)/4)·4 = −8 → wrapped 4312, 4316, 0, 4, 8, 12.
        assert row == {4312, 4316, 0, 4, 8, 12}

    def test_sort_order_and_kind_precedence(self) -> None:
        entries = self.sample((64, 64), FakeOcean(), lambda cell: True)
        keys = [(e["cell"][1], e["cell"][0], e["kind"]) for e in entries]
        assert keys == sorted(keys)
        # "current" sorts before "wind" at the same cell.
        pair = [entry["kind"] for entry in entries
                if entry["cell"] == (56, 56)]
        assert pair == ["current", "wind"]

    def test_descriptor_shape(self) -> None:
        entries = self.sample((64, 64), FakeOcean(), lambda cell: True)
        assert {entry["kind"] for entry in entries} == {"wind", "current"}
        for entry in entries:
            assert set(entry) == {"cell", "kind", "dir_id", "variable"}
            assert isinstance(entry["cell"], tuple)
            assert len(entry["cell"]) == 2
            assert all(isinstance(part, int) for part in entry["cell"])
            assert isinstance(entry["dir_id"], str)
            assert entry["variable"] is False

    def test_var_wind_cell(self) -> None:
        ocean = FakeOcean(var_cells=frozenset({(56, 56)}))
        entries = self.sample((64, 64), ocean, lambda cell: True)
        wind = [entry for entry in entries
                if entry["cell"] == (56, 56) and entry["kind"] == "wind"]
        assert wind == [{"cell": (56, 56), "kind": "wind", "dir_id": "",
                         "variable": True}]
        # The current arrow still samples on a VAR wind cell.
        current = [entry for entry in entries
                   if entry["cell"] == (56, 56) and entry["kind"] == "current"]
        assert current and current[0]["dir_id"] == "e"


# --- Real shipped ocean tiles (docs/10-* §6.5, docs/20-* §4.14/§4.16) ------

#: westerlies_n_atlantic region 1: SW in January, W from April on.
WESTERLIES_CELL = (1804, 540)
#: The Gulf Stream corridor: N, strength 3 (no reversal).
GULF_STREAM_CELL = (1208, 760)
#: Open Atlantic next to the corridor: same NE trades, no current.
NO_CURRENT_CELL = (1680, 720)
#: monsoon_arabian_sea region 14: NE in January, SW from June.
MONSOON_CELL = (2796, 940)
#: The Somali Current (reversal.summer_months 6–9): S in January, N in July.
SOMALI_CELL = (2796, 944)
#: doldrums_pacific region 10: VAR all year.
DOLDRUMS_CELL = (480, 1044)
#: Sahara interior: land, no descriptor.
LAND_CELL = (2280, 804)


@pytest.fixture(scope="module")
def ocean() -> Any:
    return ocean_layers()


@pytest.fixture(scope="module")
def world() -> Any:
    return raster()


def sample_cell(ocean: Any, world: Any, cell: tuple[int, int], month: int,
                view: tuple[int, int] = (4, 4)
                ) -> dict[tuple[tuple[int, int], str], arrow_field.ArrowEntry]:
    """Samples a small window and indexes the descriptors by (cell, kind).
    Every fixture cell is a multiple of the stride, so it is on the
    world-anchored lattice."""
    entries = arrow_field.sample(
        cell, view, month, ocean, lambda c: world.is_passable(c[0], c[1]),
        GRID_WIDTH, GRID_HEIGHT)
    return {(entry["cell"], entry["kind"]): entry for entry in entries}


class TestArrowSamplerShippedOcean:
    """The sampler against the real decoded rasters (no decode duplicated
    here — :mod:`server.sim.world.raster` owns it)."""

    def test_westerlies_wind_region_and_month_dependence(
            self, ocean: Any, world: Any) -> None:
        april = sample_cell(ocean, world, WESTERLIES_CELL, 4)
        january = sample_cell(ocean, world, WESTERLIES_CELL, 1)
        assert april[(WESTERLIES_CELL, "wind")] == {
            "cell": WESTERLIES_CELL, "kind": "wind", "dir_id": "w",
            "variable": False}
        # The region's January row is SW — the same tile, another month.
        assert january[(WESTERLIES_CELL, "wind")]["dir_id"] == "sw"
        # This region carries no current.
        assert (WESTERLIES_CELL, "current") not in april

    def test_current_corridor_tile(self, ocean: Any, world: Any) -> None:
        assert ocean.current_vector_at(
            GULF_STREAM_CELL[0], GULF_STREAM_CELL[1], 1) == (0.0, -3.0)
        entries = sample_cell(ocean, world, GULF_STREAM_CELL, 1)
        assert entries[(GULF_STREAM_CELL, "current")] == {
            "cell": GULF_STREAM_CELL, "kind": "current", "dir_id": "n",
            "variable": False}
        # The NE trades blow over the corridor too.
        assert entries[(GULF_STREAM_CELL, "wind")]["dir_id"] == "ne"

    def test_no_current_tile(self, ocean: Any, world: Any) -> None:
        entries = sample_cell(ocean, world, NO_CURRENT_CELL, 1)
        assert (NO_CURRENT_CELL, "current") not in entries
        assert entries[(NO_CURRENT_CELL, "wind")]["dir_id"] == "ne"

    def test_monsoon_flip(self, ocean: Any, world: Any) -> None:
        winter = sample_cell(ocean, world, MONSOON_CELL, 1)
        summer = sample_cell(ocean, world, MONSOON_CELL, 7)
        assert winter[(MONSOON_CELL, "wind")]["dir_id"] == "ne"
        assert summer[(MONSOON_CELL, "wind")]["dir_id"] == "sw"
        # The Somali Current's reversal is applied AT LOOKUP (§6.5): the
        # sampled arrow flips S → N with the summer months.
        somali_winter = sample_cell(ocean, world, SOMALI_CELL, 1)
        somali_summer = sample_cell(ocean, world, SOMALI_CELL, 7)
        assert somali_winter[(SOMALI_CELL, "current")]["dir_id"] == "s"
        assert somali_summer[(SOMALI_CELL, "current")]["dir_id"] == "n"
        assert ocean.current_at(
            *SOMALI_CELL, 1) == {"dir": "S", "strength": 2}
        assert ocean.current_at(
            *SOMALI_CELL, 7) == {"dir": "N", "strength": 2}

    def test_doldrums_var_wind(self, ocean: Any, world: Any) -> None:
        entries = sample_cell(ocean, world, DOLDRUMS_CELL, 1)
        assert entries[(DOLDRUMS_CELL, "wind")] == {
            "cell": DOLDRUMS_CELL, "kind": "wind", "dir_id": "",
            "variable": True}

    def test_land_tile_yields_no_descriptor(
            self, ocean: Any, world: Any) -> None:
        assert world.is_passable(*LAND_CELL) is False
        entries = sample_cell(ocean, world, LAND_CELL, 1)
        assert (LAND_CELL, "wind") not in entries
        assert (LAND_CELL, "current") not in entries
        # Every sampled descriptor sits on a water cell.
        assert all(world.is_passable(*cell) for cell, _kind in entries)


class TestArrowSamplerOceanGuards:
    def test_missing_ocean_yields_nothing(self) -> None:
        entries = arrow_field.sample(
            (64, 64), (0, 0), 1, None, lambda cell: True,
            GRID_WIDTH, GRID_HEIGHT)
        assert entries == []

    def test_zero_current_vector_is_skipped(self) -> None:
        ocean = FakeOcean(current=(0.0, 0.0))
        entries = arrow_field.sample(
            (64, 64), (0, 0), 1, ocean, lambda cell: True,
            GRID_WIDTH, GRID_HEIGHT)
        assert entries
        assert all(entry["kind"] == "wind" for entry in entries)
