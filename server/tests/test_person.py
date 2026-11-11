"""server.tests.test_person — the Person-model trio parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline), mirroring
the pinned inputs/outputs of the frozen GDScript harnesses:

  * ``tools/test_character.gd``  — Person/XP/allocation/reputation/officers
    (docs/50-CHARACTER-AND-PROGRESSION.md §4.1–§4.6, §4.8, §5, §7).
  * ``tools/test_skills.gd``     — skill counters, training, contribution,
    appointments, the officer day tick and loyalty (§4.3, §4.5).
  * ``tools/test_palace.gd`` / ``tools/test_retirement.gd`` — the fame +
    title-ladder pins (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.9.2; only the
    fame-module halves port here — the trade/shipyard/screen halves belong
    to their owning modules).

Deterministic contract pins only — no Monte Carlo, no scene boots (the
oracle modules are RNG-free, verified at port time). Fixture officers are
injected into a module-local ``DataStore`` instance (the ``test_tavern``
data-only fixture pattern), never into ``data/``.

State convention: every stateful call takes the run-scoped
:class:`~server.sim.player.PersonState` explicitly (the GDScript statics
read the ``GameState`` singleton; the server will hold a ``PersonState``
-shaped object in its GameState equivalent).
"""

from __future__ import annotations

import math
from typing import Any

import pytest

from server.sim.data import DataStore
from server.sim.player import PersonState
from server.sim.player import character, fame, skills

# --- Pinned constants (docs/70-* §4.9.2 ladder; 50-* §4.x) --------------------

LADDER: list[tuple[str, int, int]] = [
    ("knight", 100, 1),
    ("baron", 300, 2),
    ("viscount", 700, 3),
    ("count", 1500, 5),
    ("duke", 3000, 8),
]
NATION_ORDER = ["portugal", "spain", "england", "holland", "ottoman", "italy"]


# --- Fixtures (the GDScript suites' injected data-only fakes) -----------------

## Fake officers for the skills tests (tools/test_skills.gd FAKE_OFFICERS):
## stable ids, controlled skills/personality.
FAKE_OFFICERS: list[dict[str, Any]] = [
    {
        "id": "off_test_pilot", "role": "", "main_skill": "navigation",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": ["honest"],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 40, "luck": 10},
        "skills": {"seamanship": 12, "navigation": 40, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 0,
                   "carpentry": 0, "cooking": 0},
    },
    {
        "id": "off_test_boatswain", "role": "", "main_skill": "seamanship",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": ["greedy"],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {"seamanship": 40, "navigation": 12, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 0,
                   "carpentry": 0, "cooking": 0},
    },
    {
        "id": "off_test_nav_sig", "role": "", "main_skill": "seamanship",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": [],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {"seamanship": 44, "navigation": 10, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 0,
                   "carpentry": 0, "cooking": 0},
    },
    {
        "id": "off_test_surgeon", "role": "", "main_skill": "medicine",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": ["loyal"],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 25,
                   "carpentry": 0, "cooking": 0},
    },
    {
        "id": "off_test_surgeon_weak", "role": "", "main_skill": "medicine",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": [],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 10,
                   "carpentry": 0, "cooking": 0},
    },
    {
        "id": "off_test_cook", "role": "", "main_skill": "cooking",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": [],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 0,
                   "carpentry": 0, "cooking": 30},
    },
    {
        "id": "off_test_captain_ok", "role": "", "main_skill": "seamanship",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": [],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 40, "luck": 10},
        "skills": {"seamanship": 30, "navigation": 0, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 0,
                   "carpentry": 0, "cooking": 0},
    },
    {
        "id": "off_test_captain_timid", "role": "", "main_skill": "seamanship",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": [],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 20, "luck": 10},
        "skills": {"seamanship": 30, "navigation": 0, "swordplay": 0,
                   "gunnery": 0, "appraisal": 0, "negotiation": 0,
                   "cartography": 0, "rumour": 0, "medicine": 0,
                   "carpentry": 0, "cooking": 0},
    },
]

FILLERS = 13  # fake filler officers for the OFFICER_MAX = 12 capacity test


@pytest.fixture(scope="module")
def store() -> DataStore:
    """The real shipped ``data/`` tree plus the suite's fake officer cards,
    on a module-local store instance (never touching ``data/``)."""
    st = DataStore()
    st.load_all()
    for card in FAKE_OFFICERS:
        st.officers_list.append(card)
        st.officers[card["id"]] = card
    for i in range(FILLERS):
        filler = {
            "id": f"off_test_fill_{i:02d}", "role": "",
            "main_skill": "seamanship", "wage_daily": 20,
            "recruit_ports": ["lisbon"], "personality": [],
            "attributes": {"constitution": 10, "intellect": 10,
                           "charisma": 10, "courage": 40, "luck": 10},
            "skills": {"seamanship": 30, "navigation": 0, "swordplay": 0,
                       "gunnery": 0, "appraisal": 0, "negotiation": 0,
                       "cartography": 0, "rumour": 0, "medicine": 0,
                       "carpentry": 0, "cooking": 0},
            "name": {"zh": f"试·补充 {i}", "en": f"Test Filler {i}"},
            "bio": {"zh": "测试", "en": "Fixture"},
        }
        st.officers_list.append(filler)
        st.officers[filler["id"]] = filler
    return st


def make_run(gold: int = 10000, day: int = 10, intellect: int = 10,
             charisma: int = 10, attributes: dict[str, int] | None = None,
             skill_values: dict[str, int] | None = None,
             officers: list[str] | None = None) -> PersonState:
    """A fresh-shape run: the base Person block (tools/test_character.gd
    ``_set_player`` / tools/test_skills.gd ``_make_run``)."""
    player: dict[str, Any] = {
        "nation_id": "portugal",
        "background_id": "",
        "attributes": {"constitution": 10, "intellect": intellect,
                       "charisma": charisma, "courage": 10, "luck": 10},
        "skills": {key: 0 for key in skills.KEYS},
        "skill_counters": {key: 0 for key in skills.KEYS},
        "alloc_pending": 0,
        "xp": 0,
        "level": 1,
        "officers": list(officers or []),
        "reputation": {"portugal": 20, "spain": 0, "england": 0,
                       "holland": 0, "ottoman": 0, "italy": 0},
        "profit_by_nation": {},
        "profit_rep_awarded": {},
        "equipment": {"weapon": "", "armor": ""},
    }
    player["attributes"].update(attributes or {})
    player["skills"].update(skill_values or {})
    return PersonState(player=player, officer_states={}, gold=gold, day=day)


def make_fame_run() -> PersonState:
    """A fresh title state: every nation at rank ``none``, zero missions
    (tools/test_palace.gd ``_new_run`` seeding)."""
    st = make_run()
    st.fame = 0
    for nation in NATION_ORDER:
        st.titles[nation] = "none"
        st.completed_royal_missions[nation] = 0
    return st


def hire(st: PersonState, store: DataStore, officer_id: str) -> str:
    assert character.recruit(st, store, officer_id), f"fixture: {officer_id}"
    return officer_id


# ============================================================================
# character.py — tools/test_character.gd pins
# ============================================================================

class TestLevelFormula:
    """§4.4: ``level = floor(sqrt(xp/50)) + 1``, cap 20."""

    def test_pinned_rows(self) -> None:
        rows = [(0, 1), (49, 1), (50, 2), (200, 3), (450, 4),
                (800, 5), (1250, 6), (18050, 20), (999999, 20)]
        for xp, level in rows:
            assert character.level_for_xp(xp) == level, xp

    def test_round_trip_all_levels(self) -> None:
        for level in range(1, 21):
            assert character.level_for_xp(character.xp_for_level(level)) == level

    def test_thresholds(self) -> None:
        assert character.xp_for_level(2) == 50  # next_at after xp 0 is 50
        assert character.xp_for_level(20) == 18050

    def test_ladder_boundaries_from_the_closed_form(self) -> None:
        """The §5 table as a closed form: xp_for_level(L) = 50·(L−1)²."""
        assert [character.xp_for_level(l) for l in (2, 3, 4, 5, 6)] == \
            [50, 200, 450, 800, 1250]

    def test_derivation_wins_over_the_stored_cache(self) -> None:
        st = make_run()
        st.player["xp"] = 200
        st.player["level"] = 1  # a stale cache
        assert character.current_level(st) == 3

    def test_xp_to_next_level(self) -> None:
        st = make_run()
        assert character.xp_to_next_level(st) == 50
        st.player["xp"] = 50
        assert character.xp_to_next_level(st) == 150  # 200 − 50
        st.player["xp"] = 18100  # level clamps at 20
        assert character.xp_to_next_level(st) == -1


class TestAttributeReads:
    """§4.2: base 10, the five pinned keys, verbatim stored reads."""

    def test_base_reads(self, store: DataStore) -> None:
        st = make_run()
        for key in character.ATTRIBUTES:
            assert character.attribute(st, key) == 10
        assert character.ATTRIBUTES == ("constitution", "intellect",
                                        "charisma", "courage", "luck")
        assert character.SKILL_KEYS == skills.KEYS
        assert character.BASE_ATTRIBUTE == 10 and character.ATTR_MAX == 100

    def test_copy_and_verbatim_reads(self) -> None:
        st = make_run(attributes={"charisma": 20, "luck": 100})
        attrs = character.attributes(st)
        assert attrs["charisma"] == 20 and attrs["luck"] == 100
        assert len(attrs) == 5
        st.player["attributes"]["luck"] = 500
        # Over-range reads verbatim — 1–100 is a WRITE-side rule only.
        assert character.attribute(st, "luck") == 500
        del st.player["attributes"]["courage"]
        assert character.attribute(st, "courage") == 10  # missing → base 10


class TestAllocation:
    """§4.4: draft → confirm / refuse-whole; ``alloc_pending`` bookkeeping."""

    def test_confirm_moves_and_spends(self) -> None:
        st = make_run(attributes={"charisma": 40})
        st.player["alloc_pending"] = 3
        draft = {"charisma": 2}
        assert character.attribute(st, "charisma") == 40  # draft is data
        assert character.allocate(st, draft)
        assert character.attribute(st, "charisma") == 42
        assert character.attribute(st, "courage") == 10
        assert character.alloc_pending(st) == 1
        assert st.player["alloc_pending"] == 1  # the persisted §4.8 key

    def test_oversized_draft_refused_whole(self) -> None:
        st = make_run(attributes={"charisma": 40})
        st.player["alloc_pending"] = 1
        assert not character.allocate(st, {"charisma": 2})
        assert character.attribute(st, "charisma") == 40  # rollback = no-op

    def test_overflow_over_100_refuses_whole(self) -> None:
        st = make_run(attributes={"charisma": 99})
        st.player["alloc_pending"] = 5
        assert not character.allocate(st, {"charisma": 2})
        assert character.attribute(st, "charisma") == 99
        assert character.alloc_pending(st) == 5  # no points spent
        assert character.allocate(st, {"charisma": 1})  # exactly 100 is fine
        assert character.attribute(st, "charisma") == 100

    def test_malformed_drafts_refused(self) -> None:
        st = make_run()
        st.player["alloc_pending"] = 5
        assert not character.allocate(st, {})
        assert not character.allocate(st, {"not_an_attr": 1})
        assert not character.allocate(st, {"luck": 0})
        assert not character.allocate(st, {"luck": -1})


class TestAwardXp:
    """§4.4: +2 alloc_pending per level gained; no auto stat/skill grants."""

    def test_one_level_grants_two_points(self) -> None:
        st = make_run(skill_values={"seamanship": 8})
        st.player["xp"] = 49
        st.player["level"] = 1
        st.pending_levelup = False
        character.award_xp(st, 1)
        assert character.current_level(st) == 2
        assert st.player["level"] == 2  # the stored cache is written (§4.8)
        assert character.alloc_pending(st) == 2
        assert character.attribute(st, "charisma") == 10  # no auto stat grant
        assert skills.skill(st, "seamanship") == 8  # skills never allocate
        assert st.pending_levelup
        assert character.consume_pending_levelup(st)
        assert not st.pending_levelup  # consumed exactly once

    def test_multi_level_grants_once_per_level(self) -> None:
        st = make_run()
        character.award_xp(st, 450)  # level 1 → 4
        assert character.current_level(st) == 4
        assert character.alloc_pending(st) == 6

    def test_cap_grants_nothing(self) -> None:
        st = make_run()
        st.player["xp"] = 999999
        st.pending_levelup = False
        character.award_xp(st, 1000)
        assert character.current_level(st) == 20
        assert character.alloc_pending(st) == 0
        assert not st.pending_levelup  # a capped award fires no toast

    def test_non_positive_is_a_noop(self) -> None:
        st = make_run()
        character.award_xp(st, 0)
        character.award_xp(st, -5)
        assert character.current_xp(st) == 0
        assert character.alloc_pending(st) == 0


class TestProfitXp:
    """§4.4: per-unit = max(0, sell − floor(base × 0.7)); xp = floor(profit/100)."""

    def test_profit_rows(self) -> None:
        st = make_run()
        character.add_profit_xp(st, 31, 30, 10)
        assert character.current_xp(st) == 1
        st = make_run()
        st.player["xp"] = 37
        character.add_profit_xp(st, 10, 30, 10)  # loss-making
        assert character.current_xp(st) == 37  # sales never remove XP
        st = make_run()
        character.add_profit_xp(st, 55, 30, 9)  # per-unit 34, profit 306
        assert character.current_xp(st) == 3


class TestProfitReputation:
    """§4.6: the 1,000g cumulative threshold + the −100…+100 clamp."""

    def test_threshold_carries_across_transactions(self) -> None:
        st = make_run()
        assert character.add_profit_reputation(st, "spain", 600) == 0
        assert character.add_profit_reputation(st, "spain", 400) == 1
        assert character.reputation(st, "spain") == 1
        assert character.profit_by_nation(st, "spain") == 1000
        assert st.player["profit_rep_awarded"]["spain"] == 1
        assert character.add_profit_reputation(st, "spain", 999) == 0  # idempotent
        assert character.add_profit_reputation(st, "spain", 1) == 1

    def test_clamps(self) -> None:
        st = make_run()
        assert character.add_reputation(st, "spain", 200) == 100
        assert character.add_reputation(st, "spain", -500) == -100

    def test_loss_and_unknown_nation_pay_nothing(self) -> None:
        st = make_run()
        assert character.add_profit_reputation(st, "spain", 0) == 0
        assert character.add_profit_reputation(st, "spain", -5) == 0
        assert character.add_profit_reputation(st, "", 500) == 0


class TestLegacyShims:
    """§4.2.3: the legacy stat names read the new model; ROLE_STAT_BONUS dead."""

    def test_stat_map(self) -> None:
        st = make_run(attributes={"charisma": 40, "luck": 10},
                      skill_values={"swordplay": 22, "seamanship": 30,
                                    "navigation": 24})
        assert character.base_stat(st, "leadership") == 40
        assert character.effective_stat(st, "leadership") == 40
        assert character.base_stat(st, "combat") == 22
        assert character.base_stat(st, "seamanship") == 30
        assert character.base_stat(st, "navigation") == 24
        assert character.base_stat(st, "luck") == 10
        assert character.base_stat(st, "not_a_stat") == 0
        assert character.officer_bonus("navigation") == 0
        assert character.officer_bonus_excluding("navigation", "x") == 0

    def test_speed_bonus_rows(self) -> None:
        for seamanship, expected in [(0, 0.0), (15, 0.05), (45, 0.15),
                                     (90, 0.30), (300, 0.30)]:
            assert character.speed_bonus_for(seamanship) \
                == pytest.approx(expected, abs=1e-9), seamanship

    def test_sighting_rows(self) -> None:
        for navigation, expected in [(0, 48), (11, 48), (12, 49), (24, 50),
                                     (96, 56)]:
            assert character.sighting_radius_for(navigation) == expected

    def test_loss_multiplier_rows(self) -> None:
        for charisma, expected in [(10, 1.0), (30, 0.9), (100, 0.55),
                                   (1, 1.045)]:
            assert character.loss_multiplier_for(charisma) \
                == pytest.approx(expected, abs=1e-9), charisma
        st = make_run()
        assert character.desertion_multiplier(st) \
            == character.mutiny_multiplier(st)

    def test_storm_damage_is_continuous(self) -> None:
        for luck, expected in [(10, 0.96), (49, 0.804), (50, 0.80),
                               (100, 0.60)]:
            st = make_run(attributes={"luck": luck})
            assert character.storm_damage_multiplier(st) \
                == pytest.approx(expected, abs=1e-9), luck  # no ≥ 50 step

    def test_storm_chance_rows(self) -> None:
        st = make_run(attributes={"luck": 10})
        assert character.storm_chance_multiplier(st) == pytest.approx(0.975)
        st = make_run(attributes={"luck": 100})
        assert character.storm_chance_multiplier(st) == pytest.approx(0.75)

    def test_effective_wrappers(self, store: DataStore) -> None:
        st = make_run(skill_values={"seamanship": 30, "navigation": 24})
        assert character.speed_bonus(st, store) == pytest.approx(0.10)
        assert character.sighting_radius(st, store) == 50  # 48 + 24/12


class TestStartingPerson:
    """§4.1/§4.2.2: bonuses, caps, the §5 worked example."""

    def test_worked_example(self, store: DataStore) -> None:
        person = character.starting_person(
            store, "portugal", "background_deckhand",
            {"constitution": 3, "intellect": 2}, {"seamanship": 3})
        attrs = person["attributes"]
        assert attrs["constitution"] == 16 and attrs["intellect"] == 17
        assert attrs["charisma"] == 10 and attrs["luck"] == 10 \
            and attrs["courage"] == 10
        sk = person["skills"]
        assert sk["seamanship"] == 8 and sk["navigation"] == 5
        assert sk["swordplay"] == 0
        assert all(v == 0 for v in person["skill_counters"].values())
        assert person["alloc_pending"] == 0 and person["xp"] == 0 \
            and person["level"] == 1
        assert person["officers"] == []
        assert person[character.PROFIT_KEY] == {}
        assert person[character.PROFIT_AWARDED_KEY] == {}
        assert person["equipment"] == {"weapon": "", "armor": ""}
        assert "autopilot" not in person  # absent until a voyage is appointed
        assert person["reputation"]["portugal"] == 20
        assert person["reputation"]["spain"] == 0
        assert person["background_id"] == "background_deckhand"

    def test_free_point_caps(self, store: DataStore) -> None:
        capped = character.starting_person(store, "holland", "",
                                           {"charisma": 9},
                                           {"negotiation": 9})
        assert capped["attributes"]["charisma"] == 13  # per-item cap +3
        assert capped["attributes"]["luck"] == 15  # holland's +5 is luck
        assert capped["skills"]["negotiation"] == 8  # 0 + 5 nation + 3

    def test_unknown_background_grants_nothing(self, store: DataStore) -> None:
        legacy = character.starting_person(store, "spain", "world")
        assert legacy["attributes"]["courage"] == 15
        assert legacy["skills"]["swordplay"] == 5
        assert legacy["attributes"]["luck"] == 10

    def test_alloc_totals(self) -> None:
        draft = {"a": 3, "b": 2, "c": -4}
        assert character.attr_alloc_total(draft) == 5  # negatives clamp to 0
        assert character.skill_alloc_total(draft) == 5

    def test_nation_bonus_all_six(self, store: DataStore) -> None:
        """§4.2.2: each nation's +5 attribute +5 signature skill are baked in;
        the roster order is the fixed six-nation order."""
        assert len(store.nations_list) == 6
        for index, nation_id in enumerate(NATION_ORDER):
            assert store.nations_list[index]["id"] == nation_id
            nation = store.get_nation(nation_id)
            person = character.starting_person(store, nation_id, "")
            for key in character.ATTRIBUTES:
                expected = 15 if key == nation["bonus_attribute"] else 10
                assert person["attributes"][key] == expected, (nation_id, key)
            for key in skills.KEYS:
                expected = 5 if key == nation["bonus_skill"] else 0
                assert person["skills"][key] == expected, (nation_id, key)
            rep = person["reputation"]
            assert len(rep) == 6
            assert rep[nation_id] == nation["start_reputation"]


class TestCreationExtremes:
    """§4.1 step 4 (normative): attribute ≤ 21, skill ≤ 13."""

    def test_constants(self) -> None:
        assert character.CREATION_ATTR_MAX == 21
        assert character.CREATION_SKILL_MAX == 13

    def test_attribute_extreme_is_exactly_21(self, store: DataStore) -> None:
        # 10 + 5 (ottoman courage) + 3 (fencing student) + 3 (alloc cap).
        person = character.starting_person(store, "ottoman",
                                           "background_fencing_student",
                                           {"courage": 3}, {})
        assert person["attributes"]["courage"] == 21

    def test_skill_extreme_is_exactly_13(self, store: DataStore) -> None:
        # 0 + 5 (portugal navigation) + 5 (naval cadet) + 3 (alloc cap).
        person = character.starting_person(store, "portugal",
                                           "background_navy_cadet",
                                           {}, {"navigation": 3})
        assert person["skills"]["navigation"] == 13

    def test_no_build_exceeds_the_extremes(self, store: DataStore) -> None:
        mixed = character.starting_person(store, "italy",
                                          "background_tavern_errand",
                                          {"luck": 3, "charisma": 2},
                                          {"rumour": 3, "appraisal": 0})
        assert mixed["attributes"]["luck"] == 21
        assert mixed["skills"]["rumour"] == 8  # italy appraisal 5 + bg 5 + 3
        assert mixed["skills"]["appraisal"] == 5


class TestOfficersCapAndStates:
    """§4.5.2/§4.5.5: OFFICER_MAX 12, state seeding, dismissal, wages."""

    def test_capacity_and_state_seeding(self, store: DataStore) -> None:
        st = make_run(gold=100000)
        assert character.OFFICER_MAX == 12
        for i in range(12):
            assert character.recruit(st, store, f"off_test_fill_{i:02d}")
        assert character.officer_count(st) == 12
        assert not character.can_recruit(st, store, "off_test_fill_12")
        assert not character.recruit(st, store, "off_test_fill_12")
        assert character.officer_count(st) == 12
        state = st.officer_states["off_test_fill_00"]
        assert state["loyalty"] == 50  # hire loyalty starts at 50 (§4.5.4)
        assert state["sea_days"] == 0 and state["post_id"] == "" \
            and state["ship_id"] == ""
        assert state["talk_cd_day"] == 0 and state["gift_cd_day"] == 0 \
            and state["defeats"] == 0
        assert state["wage_mult"] == pytest.approx(1.0)
        # Dismissal clears the state and frees any post.
        assert skills.appoint(st, store, "off_test_fill_00", "boatswain")
        assert skills.post_holder(st, "boatswain") == "off_test_fill_00"
        assert character.dismiss(st, "off_test_fill_00")
        assert "off_test_fill_00" not in st.officer_states
        assert skills.post_holder(st, "boatswain") == ""
        assert character.can_recruit(st, store, "off_test_fill_00")
        assert not character.dismiss(st, "off_test_fill_00")  # un-employed

    def test_wages_read_the_wage_mult(self, store: DataStore) -> None:
        st = make_run(gold=100000)
        character.recruit(st, store, "off_mateus_alvares")  # wage_daily 30
        assert character.officer_wages(st, store) == 30
        assert skills.accept_raise(st, "off_mateus_alvares")
        assert character.officer_wages(st, store) == 38  # 30 × 1.25 → 38


class TestSigningPriceMult:
    """§4.5.2/§4.2.1: ``clamp(1 − (CHA−10)/200, 0.5, 1.0)`` on wage × 10."""

    def test_multiplier_rows(self, store: DataStore) -> None:
        for charisma, mult in [(10, 1.0), (60, 0.75), (100, 0.55),
                               (300, 0.5), (1, 1.0)]:
            st = make_run(attributes={"charisma": charisma})
            assert character.charisma_price_multiplier(st) \
                == pytest.approx(mult), charisma

    def test_costs(self, store: DataStore) -> None:
        st = make_run(attributes={"charisma": 10})
        assert character.recruit_cost(st, store, "off_mateus_alvares") == 300
        st = make_run(attributes={"charisma": 60})
        assert character.recruit_cost(st, store, "off_mateus_alvares") == 225
        st = make_run(attributes={"charisma": 100})
        assert character.recruit_cost(st, store, "off_mateus_alvares") == 165

    def test_gold_shortfall_reads_the_multiplied_cost(self,
                                                      store: DataStore) -> None:
        st = make_run(attributes={"charisma": 60})
        st.gold = 224
        assert not character.can_recruit(st, store, "off_mateus_alvares")
        st.gold = 225
        assert character.can_recruit(st, store, "off_mateus_alvares")
        assert character.recruit(st, store, "off_mateus_alvares")
        assert st.gold == 0  # the multiplied fee is deducted exactly
        assert not character.can_recruit(st, store, "off_mateus_alvares")
        assert not character.can_recruit(st, store, "off_nobody")


# ============================================================================
# skills.py — tools/test_skills.gd pins
# ============================================================================

class TestSkillDataTables:
    """docs/10-* §4.20–§4.22: the data tables the layer reads."""

    def test_posts_backgrounds_gates(self, store: DataStore) -> None:
        assert len(store.officer_posts_list) == 7
        captain = store.get_officer_post("captain")
        assert captain["prereq"]["seamanship"] == 25
        assert captain["prereq"]["courage"] == 30
        pilot = store.get_officer_post("pilot")
        assert pilot["prereq"]["navigation"] == 20
        assert len(store.backgrounds_list) == 6
        gate = store.get_skill_gate("sail.autopilot")
        assert gate["threshold"] == 40
        assert gate["stat_or_skill"] == "navigation"
        assert store.get_officer_post("no_such_post") == {}


class TestSkillReads:
    """§4.3/§4.8: stored values, read-side clamp 0–100, unknown key 0."""

    def test_reads_and_boundaries(self, store: DataStore) -> None:
        st = make_run()
        for key in skills.KEYS:
            assert skills.skill(st, key) == 0
            assert skills.effective_skill(st, store, key) == 0
        st.player["skills"]["seamanship"] = 55
        assert skills.skill(st, "seamanship") == 55
        st.player["skills"]["seamanship"] = 100
        st.player["skills"]["navigation"] = 300
        assert skills.skill(st, "seamanship") == 100
        assert skills.skill(st, "navigation") == 100  # read clamps
        assert skills.skill(st, "not_a_skill") == 0
        assert len(skills.KEYS) == 8
        assert skills.OFFICER_KEYS == ("medicine", "carpentry", "cooking")


class TestGrowthThresholds:
    """§4.3.1: the +1-per-N-uses table is a contract pin."""

    def test_table(self) -> None:
        expected = {"seamanship": 30, "navigation": 30, "swordplay": 1,
                    "gunnery": 10, "appraisal": 20, "negotiation": 15,
                    "cartography": 5, "rumour": 10}
        for key, threshold in expected.items():
            assert skills.growth_threshold(key) == threshold, key
        assert skills.growth_threshold("nope") == 0


class TestCounterBoundaries:
    """§4.3.3: award at the threshold, reset on award, stop at skill 100."""

    def test_exactness_and_reset(self) -> None:
        st = make_run()
        for _ in range(4):
            skills.note_usage(st, "cartography")
            skills.maybe_award(st, "cartography")
        assert skills.skill(st, "cartography") == 0
        assert skills.counters(st)["cartography"] == 4
        skills.note_usage(st, "cartography")
        skills.maybe_award(st, "cartography")
        assert skills.skill(st, "cartography") == 1
        assert skills.counters(st)["cartography"] == 0  # reset on award

    def test_swordplay_grows_every_round(self) -> None:
        st = make_run()
        skills.note_usage(st, "swordplay")
        skills.maybe_award(st, "swordplay")
        assert skills.skill(st, "swordplay") == 1

    def test_below_threshold_nothing_accrues(self) -> None:
        st = make_run()
        skills.note_usage(st, "appraisal", 19)
        skills.maybe_award(st, "appraisal")
        assert skills.skill(st, "appraisal") == 0
        skills.note_usage(st, "appraisal")
        skills.maybe_award(st, "appraisal")
        assert skills.skill(st, "appraisal") == 1

    def test_maxed_skill_stops_counting(self) -> None:
        st = make_run(skill_values={"rumour": 100})
        skills.note_usage(st, "rumour", 50)
        skills.maybe_award(st, "rumour")
        assert skills.counters(st)["rumour"] == 0
        assert skills.skill(st, "rumour") == 100  # never passes 100

    def test_note_usage_guards(self) -> None:
        st = make_run()
        skills.note_usage(st, "not_a_skill", 5)
        skills.note_usage(st, "gunnery", 0)
        skills.note_usage(st, "gunnery", -3)
        assert sum(skills.counters(st).values()) == 0


class TestNoteSeaDay:
    """§4.3.1: seamanship and navigation award on the 30th sea-day."""

    def test_thirty_sea_days(self, store: DataStore) -> None:
        st = make_run()
        pilot = hire(st, store, "off_test_pilot")
        assert skills.appoint(st, store, pilot, "pilot")
        for _ in range(29):
            skills.note_sea_day(st, store)
        assert skills.skill(st, "seamanship") == 0
        assert skills.skill(st, "navigation") == 0
        assert st.officer_states[pilot]["sea_days"] == 29
        skills.note_sea_day(st, store)
        assert skills.skill(st, "seamanship") == 1
        assert skills.skill(st, "navigation") == 1
        assert st.officer_states[pilot]["sea_days"] == 30
        assert skills.counters(st)["seamanship"] == 0  # reset on award


class TestTraining:
    """§4.3.4: ``ceil(level × 60 × (1 − (INT−10)/200))``, cap 60."""

    def test_price_int_boundaries(self, store: DataStore) -> None:
        st = make_run(100000, 10, 10, 10)
        assert skills.training_price(st, "seamanship") == 60  # INT 10
        st = make_run(100000, 10, 60, 10)
        assert skills.training_price(st, "seamanship") == 45  # ceil(45.0)
        st = make_run(100000, 10, 100, 10)
        assert skills.training_price(st, "seamanship") == 33  # ceil(33.0)

    def test_price_worked_example_and_level_scale(self) -> None:
        st = make_run(100000, 10, 17, 10)
        assert skills.training_price(st, "seamanship") == 58  # ceil(57.9)
        st.player["xp"] = 200  # level 3
        assert skills.training_price(st, "seamanship") == 174

    def test_payment(self, store: DataStore) -> None:
        st = make_run(1000, 10, 10, 10)
        st.player["skills"]["negotiation"] = 30
        assert skills.can_train(st, "negotiation")
        assert skills.train(st, "negotiation")
        assert st.gold == 1000 - 60
        assert skills.skill(st, "negotiation") == 31

    def test_short_purse_refuses(self, store: DataStore) -> None:
        st = make_run(59, 10, 10, 10)
        assert not skills.can_train(st, "negotiation")
        assert not skills.train(st, "negotiation")
        assert st.gold == 59  # nothing paid

    def test_cap_60_refuses(self, store: DataStore) -> None:
        st = make_run(100000, 10, 10, 10)
        st.player["skills"]["negotiation"] = 60
        assert not skills.can_train(st, "negotiation")
        assert not skills.train(st, "negotiation")
        assert st.gold == 100000
        assert skills.skill(st, "negotiation") == 60


class TestContribution:
    """§4.5.3: one in-post officer, derate < 30, signature ≥ 80, no stacking."""

    def test_one_in_post_officer(self, store: DataStore) -> None:
        st = make_run()
        bosun = hire(st, store, "off_test_boatswain")
        assert skills.appoint(st, store, bosun, "boatswain")
        st.player["skills"]["seamanship"] = 5
        assert skills.effective_skill(st, store, "seamanship") == 45
        assert character.speed_bonus_for(
            skills.effective_skill(st, store, "seamanship")) \
            == pytest.approx(0.15)

    def test_idle_officer_adds_nothing(self, store: DataStore) -> None:
        st = make_run()
        hire(st, store, "off_test_cook")
        assert skills.effective_skill(st, store, "cooking") == 0

    def test_loyalty_derate_and_signature(self, store: DataStore) -> None:
        st = make_run()
        bosun = hire(st, store, "off_test_boatswain")
        skills.appoint(st, store, bosun, "boatswain")
        st.officer_states[bosun]["loyalty"] = 29
        assert skills.officer_contribution(st, store, "seamanship") == 32
        st.officer_states[bosun]["loyalty"] = 80
        assert skills.officer_contribution(st, store, "seamanship") == 45

    def test_no_stacking(self, store: DataStore) -> None:
        st = make_run()
        bosun = hire(st, store, "off_test_boatswain")
        skills.appoint(st, store, bosun, "boatswain")
        st.player["skills"]["seamanship"] = 5
        st.officer_states[bosun]["loyalty"] = 80  # the GDScript fixture state
        second = hire(st, store, "off_test_nav_sig")  # seamanship 44 ≥ 20
        assert not skills.appoint(st, store, second, "boatswain")
        assert skills.effective_skill(st, store, "seamanship") == 50  # 5 + 45

    def test_captain_never_feeds_the_player(self, store: DataStore) -> None:
        st = make_run()
        cap = hire(st, store, "off_test_captain_ok")
        assert skills.appoint(st, store, cap, "captain", "ship_escort_1")
        assert skills.officer_contribution(st, store, "seamanship") == 0


class TestAppointments:
    """§4.5.2: prereqs, occupancy, captain seats (seamanship 25 ∧ cour 30)."""

    def test_prereq_gray_cases(self, store: DataStore) -> None:
        st = make_run()
        weak = hire(st, store, "off_test_surgeon_weak")  # medicine 10 < 20
        assert not skills.appoint(st, store, weak, "surgeon")
        good = hire(st, store, "off_test_surgeon")  # medicine 25
        assert skills.appoint(st, store, good, "surgeon")
        assert skills.post_holder(st, "surgeon") == good
        assert not skills.appoint(st, store, "off_nobody", "pilot")
        assert not skills.appoint(st, store, good, "no_such_post")
        assert skills.appoint(st, store, good, "")  # unassign always allowed
        assert skills.post_holder(st, "surgeon") == ""
        state = st.officer_states[good]
        assert state["post_id"] == "" and state["ship_id"] == ""

    def test_occupancy_one_person_per_post(self, store: DataStore) -> None:
        st = make_run()
        a = hire(st, store, "off_test_surgeon")
        weak = hire(st, store, "off_test_surgeon_weak")
        assert skills.appoint(st, store, a, "surgeon")
        assert not skills.appoint(st, store, weak, "surgeon")
        assert not skills.appoint(st, store, a, "boatswain")  # sea 0 < 20
        assert skills.post_holder(st, "surgeon") == a  # the failed move sat

    def test_captain_posts(self, store: DataStore) -> None:
        st = make_run()
        ok = hire(st, store, "off_test_captain_ok")      # sea 30 / cou 40
        timid = hire(st, store, "off_test_captain_timid")  # sea 30 / cou 20
        assert not skills.appoint(st, store, timid, "captain", "ship_a")
        assert skills.appoint(st, store, ok, "captain", "ship_a")
        assert not skills.appoint(st, store, timid, "captain", "ship_a")
        assert skills.appoint(st, store, ok, "captain", "ship_b")  # moves
        assert st.officer_states[ok]["ship_id"] == "ship_b"
        second = hire(st, store, "off_test_boatswain")  # sea 40 / cou 10
        assert not skills.appoint(st, store, second, "captain", "ship_a")
        assert skills.post_holder(st, "captain") == ok


class TestOfficerDayTick:
    """§4.3.2: +1 per 90 sea-days to the post's skill (idle → main skill)."""

    def test_in_post_growth_is_modular(self, store: DataStore) -> None:
        st = make_run()
        doc = hire(st, store, "off_test_surgeon")
        assert skills.appoint(st, store, doc, "surgeon")
        st.officer_states[doc]["sea_days"] = 89
        skills.officer_day_tick(st, store)
        assert st.officer_states[doc]["sea_days"] == 90
        assert store.get_officer(doc)["skills"]["medicine"] == 26
        skills.officer_day_tick(st, store)  # day 91
        assert store.get_officer(doc)["skills"]["medicine"] == 26  # resets

    def test_idle_bench_grows_the_main_skill(self, store: DataStore) -> None:
        st = make_run()
        cook = hire(st, store, "off_test_cook")
        st.officer_states[cook]["sea_days"] = 89
        skills.officer_day_tick(st, store)
        assert store.get_officer(cook)["skills"]["cooking"] == 31


class TestResignAndRaise:
    """§4.5.4: < 15 resigns; < 30 raise demand (accept ×1.25 +10 / refuse −10)."""

    def test_resign_frees_the_post(self, store: DataStore) -> None:
        st = make_run()
        quitter = hire(st, store, "off_test_surgeon")
        assert skills.appoint(st, store, quitter, "surgeon")
        st.officer_states[quitter]["loyalty"] = 14
        skills.officer_day_tick(st, store)
        assert not character.is_employed(st, quitter)
        assert quitter not in st.officer_states  # a re-hire starts fresh at 50
        assert skills.post_holder(st, "surgeon") == ""

    def test_raise_demand_paths(self, store: DataStore) -> None:
        st = make_run()
        grumbler = hire(st, store, "off_test_cook")
        assert skills.appoint(st, store, grumbler, "cook")
        st.officer_states[grumbler]["loyalty"] = 29
        st.pending_raise = False
        skills.officer_day_tick(st, store)
        assert st.pending_raise
        wages_before = character.officer_wages(st, store)
        assert skills.accept_raise(st, grumbler)
        assert st.officer_states[grumbler]["wage_mult"] == pytest.approx(1.25)
        assert st.officer_states[grumbler]["loyalty"] == 39  # 29 + 10
        assert not st.pending_raise
        assert character.officer_wages(st, store) \
            == int(math.floor(wages_before * 1.25 + 0.5))  # half away from 0
        st.officer_states[grumbler]["loyalty"] = 25
        st.pending_raise = True
        assert skills.refuse_raise(st, grumbler)
        assert st.officer_states[grumbler]["loyalty"] == 15  # flat −10
        assert not st.pending_raise


class TestTalkGiftCooldowns:
    """§4.5.4: talk +1 / gift 200g (+8 greedy, +3 honest/loyal), 10-day cds."""

    def test_talk_and_gift_flow(self, store: DataStore) -> None:
        st = make_run(10000, 10, 10, 10)
        friend = hire(st, store, "off_test_surgeon")   # personality ["loyal"]
        greedy = hire(st, store, "off_test_boatswain")  # personality ["greedy"]
        assert skills.talk(st, friend)
        assert st.officer_states[friend]["loyalty"] == 51
        assert not skills.talk(st, friend)  # same day is inside the cooldown
        assert st.officer_states[friend]["talk_cd_day"] == 20  # day + 10
        st.day = 20
        assert skills.talk(st, friend)  # the cooldown cleared
        gold_before = st.gold
        assert skills.gift(st, store, friend)
        assert st.gold == gold_before - 200
        # loyal +3 on top of the two talks (50 → 52 → 55)
        assert st.officer_states[friend]["loyalty"] == 55
        assert not skills.gift(st, store, friend)  # gift cooldown holds
        st.day = 30
        assert skills.gift(st, store, greedy)
        assert st.officer_states[greedy]["loyalty"] == 58  # greedy +8

    def test_short_purse_refuses_the_gift(self, store: DataStore) -> None:
        st = make_run(1000, 5, 10, 10)
        poor = hire(st, store, "off_test_cook")
        st.gold = 150
        assert not skills.gift(st, store, poor)
        assert st.gold == 150  # a refused gift pays nothing


class TestLoyaltyMultiplier:
    """§4.5.4: ``1 + floor((CHA−10)/45)`` on positives; negatives flat; clamps."""

    def test_multiplier_rows(self, store: DataStore) -> None:
        st = make_run(10000, 10, 10, 10)
        a = hire(st, store, "off_test_cook")
        assert skills.cha_loyalty_multiplier(st) == 1
        assert skills.adjust_loyalty(st, a, 5) == 55
        st = make_run(10000, 10, 10, 100)
        rich = hire(st, store, "off_test_cook")
        assert skills.cha_loyalty_multiplier(st) == 3
        assert skills.adjust_loyalty(st, rich, 5) == 65  # +5 lands as +15
        st = make_run(10000, 10, 10, 60)
        assert skills.cha_loyalty_multiplier(st) == 2

    def test_negative_flat_and_clamps(self, store: DataStore) -> None:
        st = make_run(10000, 10, 10, 100)
        b = hire(st, store, "off_test_cook")
        assert skills.adjust_loyalty(st, b, -10) == 40  # no charisma multiply
        st.officer_states[b]["loyalty"] = 3
        assert skills.adjust_loyalty(st, b, -50) == 0
        st.officer_states[b]["loyalty"] = 99
        assert skills.adjust_loyalty(st, b, 5) == 100
        assert skills.loyalty(st, "off_nobody") == skills.LOYALTY_START

    def test_unemployed_officers_ignore_deltas(self, store: DataStore) -> None:
        st = make_run()
        assert skills.adjust_loyalty(st, "off_nobody", 50) == 50
        assert not skills.talk(st, "off_nobody")
        assert not skills.gift(st, store, "off_nobody")
        assert not skills.accept_raise(st, "off_nobody")
        assert not skills.refuse_raise(st, "off_nobody")


# ============================================================================
# fame.py — tools/test_palace.gd / test_retirement.gd pins
# ============================================================================

class TestFameValue:
    """70-* §4.1/§4.9.1: fame never decreases, never negative."""

    def test_add_and_noop(self) -> None:
        st = make_fame_run()
        assert fame.add(st, 100) == 100
        assert fame.add(st, 25) == 125
        assert fame.add(st, 0) == 125  # non-positive is a no-op
        assert fame.add(st, -5) == 125
        assert fame.value(st) == 125

    def test_value_clamps_negative_state(self) -> None:
        st = make_fame_run()
        st.fame = -10  # a hand-corrupted state must read 0
        assert fame.value(st) == 0


class TestLadderTable:
    """70-* §4.9.2: the pinned rank order and (fame, missions) table."""

    def test_rank_order(self) -> None:
        assert fame.RANKS == ("none", "knight", "baron", "viscount",
                              "count", "duke")

    def test_ladder_rows(self) -> None:
        for rank, need_fame, need_missions in LADDER:
            assert fame.LADDER[rank]["fame"] == need_fame, rank
            assert fame.LADDER[rank]["missions"] == need_missions, rank
        assert "none" not in fame.LADDER  # the starting rung is never granted
        assert len(fame.RANKS) == len(LADDER) + 1  # exactly five grantable

    def test_rank_index(self) -> None:
        assert fame.rank_index("none") == 0
        assert fame.rank_index("knight") == 1
        assert fame.rank_index("duke") == 5
        assert fame.rank_index("not_a_rank") == 0


class TestLadderThresholds:
    """70-* §4.9.2: both requirements, one rung at a time, boundary values."""

    def test_fame_alone_promotes_nothing(self) -> None:
        st = make_fame_run()
        st.fame = 3000
        assert not fame.can_promote(st, "portugal")
        assert fame.grant(st, "portugal") == ""
        assert fame.title(st, "portugal") == "none"

    def test_each_rung_boundary(self) -> None:
        st = make_fame_run()
        nation = "portugal"
        for rank, need_fame, need_missions in LADDER:
            st.completed_royal_missions[nation] = need_missions
            st.fame = need_fame - 1  # fame short by one: still no
            assert not fame.can_promote(st, nation), rank
            st.fame = need_fame
            st.completed_royal_missions[nation] = need_missions - 1
            assert not fame.can_promote(st, nation), rank  # missions short
            st.completed_royal_missions[nation] = need_missions
            assert fame.can_promote(st, nation), rank
            assert fame.next_rank(st, nation) == rank
            assert fame.grant(st, nation) == rank
            assert fame.title(st, nation) == rank

    def test_duke_is_the_top(self) -> None:
        st = make_fame_run()
        st.titles["portugal"] = "duke"
        assert fame.next_rank(st, "portugal") == ""
        assert fame.next_fame_required(st, "portugal") == -1
        assert fame.next_missions_required(st, "portugal") == -1
        assert fame.grant(st, "portugal") == ""  # no grant above duke
        assert fame.is_duke(st, "portugal")
        assert fame.any_duke(st)

    def test_next_requirements(self) -> None:
        st = make_fame_run()
        assert fame.next_requirements(st, "portugal") == {
            "rank": "knight", "fame": 100, "missions": 1}
        st.titles["portugal"] = "count"
        assert fame.next_requirements(st, "portugal") == {
            "rank": "duke", "fame": 3000, "missions": 8}

    def test_hand_edited_rank_reads_none(self) -> None:
        st = make_fame_run()
        st.titles["portugal"] = "emperor"  # not a rank id
        assert fame.title(st, "portugal") == "none"
        assert fame.title(st, "never_heard_of_it") == "none"


class TestPerNationIndependence:
    """70-* §4.9.2: grants never regress and never transfer between nations."""

    def test_independent_ladders(self) -> None:
        st = make_fame_run()
        st.fame = 3000
        for nation in NATION_ORDER:
            st.completed_royal_missions[nation] = 8
        assert fame.grant(st, "portugal") == "knight"
        for _ in range(4):
            fame.grant(st, "portugal")
        assert fame.title(st, "portugal") == "duke"
        for other in ("spain", "england", "holland", "ottoman", "italy"):
            assert fame.title(st, other) == "none"
            assert not fame.is_duke(st, other)
        assert fame.royal_missions(st, "portugal") == 8
        assert fame.grant(st, "spain") == "knight"  # spain's own ceremony
        assert fame.title(st, "portugal") == "duke"  # untouched
        assert fame.grant(st, "portugal") == ""  # grants never regress

    def test_mission_counter(self) -> None:
        st = make_fame_run()
        assert fame.add_royal_mission(st, "portugal") == 1
        assert fame.add_royal_mission(st, "portugal") == 2
        assert fame.royal_missions(st, "spain") == 0  # per nation
        assert fame.royal_missions(st, "portugal") == 2


class TestTitleGrants:
    """70-* §4.9.2: the three derived grants and their boundary ranks."""

    def test_sell_bonus_rows(self) -> None:
        st = make_fame_run()
        assert fame.title_bonus(st, "england") == pytest.approx(1.0)  # none
        st.titles["england"] = "knight"
        assert fame.title_bonus(st, "england") == pytest.approx(1.05)
        st.titles["england"] = "baron"
        assert fame.title_bonus(st, "england") == pytest.approx(1.10)
        for rank in ("viscount", "count", "duke"):
            st.titles["england"] = rank
            assert fame.title_bonus(st, "england") == pytest.approx(1.10)

    def test_sell_bonus_is_the_ports_own_nation(self) -> None:
        st = make_fame_run()
        st.titles["portugal"] = "duke"
        st.titles["england"] = "none"
        assert fame.title_bonus(st, "england") == pytest.approx(1.0)
        assert fame.title_bonus(st, "portugal") == pytest.approx(1.10)

    def test_repair_discount_rows(self) -> None:
        st = make_fame_run()
        assert fame.repair_discount(st, "portugal") == pytest.approx(1.0)
        st.titles["portugal"] = "viscount"
        assert fame.repair_discount(st, "portugal") == pytest.approx(1.0)
        st.titles["portugal"] = "count"
        assert fame.repair_discount(st, "portugal") == pytest.approx(0.8)
        st.titles["portugal"] = "duke"
        assert fame.repair_discount(st, "portugal") == pytest.approx(0.8)
        # Other nations' ports are unaffected (spain's own title is none).
        assert fame.repair_discount(st, "spain") == pytest.approx(1.0)

    def test_quest_slot_grant_is_a_max(self) -> None:
        st = make_fame_run()
        assert fame.quest_slots_bonus(st) == 0
        st.titles["portugal"] = "baron"
        assert fame.quest_slots_bonus(st) == 0
        st.titles["portugal"] = "viscount"
        assert fame.quest_slots_bonus(st) == 1
        st.titles["spain"] = "viscount"
        st.titles["italy"] = "duke"  # a max over nations, never a sum
        assert fame.quest_slots_bonus(st) == 1

    def test_earned_titles_sorted(self) -> None:
        st = make_fame_run()
        st.titles["spain"] = "baron"
        st.titles["portugal"] = "duke"
        assert fame.earned_titles(st) == [("portugal", "duke"),
                                          ("spain", "baron")]
