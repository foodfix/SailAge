"""server.tests.test_quests — the quest-layer parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_quests.gd`` Phase-3 task B and
``tools/test_bounty.gd`` Phase-3 task E) boot a run and walk the
autoloads; here the same pinned contracts are asserted as pure functions
over injected state on the real shipped ``data/`` tree (loaded through
:mod:`server.sim.data`, positions through the real ``harbors.json`` berth
table).

Oracle parity: the pinned offer lists below were cross-checked row-for-
row against the live Godot 4.7 oracle (``scripts/quests/quest_gen.gd``
probed headless, 2026-11-11) — 4 ports × 6 days identical, so the seed
formula + GodotRng draw order port is bit-exact, not just shape-equal.

Pinned contracts (oracles: ``scripts/quests/quest_gen.gd`` +
``scripts/quests/bounty.gd`` + ``scripts/quests/phase3_hooks.gd``;
docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.2, §4.5, §4.9.2, §4.9.3, §4.9.5,
§4.9.6):
  * the §4.9.3 seed formula ``(day//7)×1000003 + ordinal×7919`` and the
    one-draw-order offer lists, pinned to the oracle's exact ids;
  * the §4.9.3 draw bands on every offer over 60 weeks (quantity tiers,
    destination distance/expiry, reward gold/rep/fame, bounty tiers);
  * offer lifecycle — derived list, accept removes, slots cap 3 with the
    §4.9.2 viscount grant to 4, the ``quest.no_hold`` / ``quest.slots_full``
    refusals, free delivery goods;
  * completion/failure — delivery at the destination (goods removed,
    reward, +5 rep, +10 fame), the §4.2 −5 rep failure paths (cargo lost,
    expiry, abandon, day tick), ``day > deadline_day``, goods never
    reclaimed, exploration on report (+10 fame), bounty on victory
    (+15 fame, tier gold);
  * the §4.9.5 rival table (data), the piracy block (−20/+2/+2, clamped,
    once per battle), the bounty threshold boundary (exactly −50), the
    amount ``500 × |rep|`` fixed at issue time, both clearing paths
    landing on exactly −10, the closed-port matrix with the §4.9.6
    capital-palace pay exception, no lockout with all six bountied;
  * the phase3_hooks wiring order (day tick → prune → bounty
    re-evaluation; port entry; cargo mutation; battle aftermath incl. the
    surrender clearing and the win counter) with the unported modules
    (palace/tournament) asserted as the injected seam contract.

Deterministic seeds — the offer lists ride the §4.9.3 pinned seed
formula, everything else is closed-form or a fixed fixture.
"""

from __future__ import annotations

from typing import Any

import pytest

from server.sim import fleet as fleet_lib
from server.sim.data import data
from server.sim.player import PersonState
from server.sim.player import character as character_lib
from server.sim.player import fame as fame_lib
from server.sim.quests import QuestState, RasterWorld
from server.sim.quests import bounty as bounty_lib
from server.sim.quests import phase3_hooks
from server.sim.quests import quest_gen
from server.sim.world.raster import WorldRaster, chebyshev_wrap

# docs/70-* §4.9.5: the pinned rival table (mirrored in the data file).
RIVALS: dict[str, list[str]] = {
    "portugal": ["spain", "england"],
    "spain": ["portugal", "italy"],
    "england": ["holland", "portugal"],
    "holland": ["england", "portugal"],
    "italy": ["ottoman", "spain"],
    "ottoman": ["italy", "spain"],
}

NATIONS = ["portugal", "spain", "england", "holland", "ottoman", "italy"]

# The live-oracle offer rows (probed headless 2026-11-11; see the module
# docstring). lisbon week 1 = day 12: the delivery's first-band [6, 30]
# different-nation candidate set is EMPTY (every Iberian neighbour is
# portugal), so the oracle exercises its drop-the-nation-filter fallback —
# dest oporto, same nation, reputation {portugal: 5}.
LISBON_WEEK1 = [
    {"instance_id": "q_lisbon_1_0", "template_id": "qt_delivery_timber",
     "type": "delivery", "giver": "guild", "origin_port_id": "lisbon",
     "requirements": {"good_id": "timber", "quantity": 40,
                      "dest_port_id": "oporto"},
     "rewards": {"gold": 1200, "reputation": {"portugal": 5}, "fame": 10},
     "expiry_days": 13, "status": "active"},
    {"instance_id": "q_lisbon_1_1", "template_id": "qt_exploration_rumor",
     "type": "exploration", "giver": "guild", "origin_port_id": "lisbon",
     "requirements": {"discovery_id": "disc_atlas_cedars"},
     "rewards": {"gold": 0, "reputation": {"portugal": 5}, "fame": 10},
     "expiry_days": 30, "status": "active"},
    {"instance_id": "q_lisbon_1_2", "template_id": "qt_bounty_hunt",
     "type": "bounty", "giver": "guild", "origin_port_id": "lisbon",
     "requirements": {"tier": 3, "target_fleet_id": ""},
     "rewards": {"gold": 20000, "reputation": {}, "fame": 15},
     "expiry_days": 30, "status": "active"},
]


# --- Fixtures ---------------------------------------------------------------


@pytest.fixture(scope="module")
def world() -> RasterWorld:
    """The real berth table (``data/maps/harbors.json``) behind the
    WorldView seam."""
    return RasterWorld(WorldRaster())


def new_run(port_id: str = "lisbon", day: int = 12) -> tuple[PersonState,
                                                             QuestState,
                                                             list[Any]]:
    """A fresh run (the ``_new_run`` fixture): empty reputation map, the
    §4.9.2 all-``none`` titles, a clear pooled hold (two caravels = 240
    units, so every accepted delivery fits)."""
    st = PersonState(day=day, gold=5000, fame=0,
                     titles={nation: "none" for nation in NATIONS})
    st.player = {"reputation": {nation: 0 for nation in NATIONS}}
    qs = QuestState()
    fleet = [fleet_lib.new_ship("caravel", 0) for _ in range(2)]
    return st, qs, fleet


def offer_of_type(port_id: str, day: int, type_id: str,
                  world: RasterWorld) -> dict[str, Any]:
    """The first offer of ``type_id`` across 60 weeks (the oracle's scan)."""
    for week in range(60):
        for offer in quest_gen.offers(port_id, week * 7 + 1, world):
            if str(offer.get("type")) == type_id:
                return offer
    raise AssertionError(f"no {type_id} offer found in 60 weeks at {port_id}")


def ids_of(offers: list[dict[str, Any]]) -> list[str]:
    return [str(offer.get("instance_id", "")) for offer in offers]


# --- 1. The §4.9.3 seed formula (tools/test_quests.gd §1) -------------------


class TestOfferSeed:
    def test_seed_formula_is_the_pinned_closed_form(self) -> None:
        # lisbon's 0-based ordinal in the ascending id order (150 ports).
        assert quest_gen.port_ordinal("lisbon") == 70
        assert quest_gen.offer_seed("lisbon", 12) == \
            (12 // 7) * quest_gen.SEED_WEEK_MULT + 70 * quest_gen.SEED_PORT_MULT
        assert quest_gen.offer_seed("lisbon", 12) == 1000003 + 70 * 7919

    def test_different_ports_seed_different_lists(self) -> None:
        assert quest_gen.offer_seed("lisbon", 12) \
            != quest_gen.offer_seed("tunis", 12)

    def test_week_and_refresh_arithmetic(self) -> None:
        assert quest_gen.week_of(12) == 1
        assert quest_gen.week_of(13) == 1
        assert quest_gen.week_of(14) == 2
        assert quest_gen.next_refresh_day(12) == 14
        assert quest_gen.next_refresh_day(13) == 14
        assert quest_gen.next_refresh_day(14) == 21


# --- 2. The pinned offer lists (live-oracle rows) ---------------------------


class TestPinnedOffers:
    def test_lisbon_week1_matches_the_live_oracle(self,
                                                  world: RasterWorld) -> None:
        offers = quest_gen.offers("lisbon", 12, world)
        assert offers == LISBON_WEEK1
        # The same list twice — the derivation is pure.
        assert quest_gen.offers("lisbon", 12, world) == offers

    def test_stable_within_a_week_changes_next_week(self,
                                                    world: RasterWorld) -> None:
        a = quest_gen.offers("lisbon", 12, world)
        assert ids_of(quest_gen.offers("lisbon", 13, world)) == ids_of(a)
        assert ids_of(quest_gen.offers("lisbon", 19, world)) != ids_of(a)

    def test_slot0_is_always_a_delivery(self, world: RasterWorld) -> None:
        for day in (1, 12, 19, 57):
            offers = quest_gen.offers("lisbon", day, world)
            assert len(offers) == quest_gen.OFFERS_PER_GUILD == 3
            assert offers[0]["type"] == "delivery"
            assert offers[0]["instance_id"].endswith("_0")

    def test_unknown_port_offers_nothing(self, world: RasterWorld) -> None:
        assert quest_gen.offers("atlantis", 12, world) == []

    def test_lisbon_week0_row_pins(self, world: RasterWorld) -> None:
        # week 0 (day 1): the live-oracle row set — a different dest nation
        # band, the other in-range discovery, a tier-2 bounty.
        offers = quest_gen.offers("lisbon", 1, world)
        assert ids_of(offers) == ["q_lisbon_0_0", "q_lisbon_0_1",
                                  "q_lisbon_0_2"]
        assert offers[0]["requirements"] == {
            "good_id": "spices", "quantity": 30, "dest_port_id": "oporto"}
        assert offers[0]["rewards"]["gold"] == 9000
        assert offers[1]["requirements"] == {
            "discovery_id": "disc_jebel_musa"}
        assert offers[2]["requirements"] == {"tier": 2,
                                             "target_fleet_id": ""}
        assert offers[2]["rewards"]["gold"] == 10000

    def test_found_discoveries_leave_the_exploration_draw(self,
                                                         world: RasterWorld,
                                                         ) -> None:
        # The live-oracle rows (probed headless 2026-11-11): a found
        # discovery leaves the draw band, which can shift the LATER slots'
        # stream too (a single-candidate draw is the equal-bounds call
        # that consumes nothing — §4.9.3 + the GodotRng semantics).
        offers = quest_gen.offers("lisbon", 12, world,
                                  ["disc_atlas_cedars"])
        assert ids_of(offers) == ["q_lisbon_1_0", "q_lisbon_1_1",
                                  "q_lisbon_1_2"]
        assert offers[1]["requirements"] == {"discovery_id": "disc_jebel_musa"}
        assert offers[2]["type"] == "exploration"
        assert offers[2]["requirements"] == {
            "discovery_id": "disc_jebel_musa"}
        # With every in-range discovery found, the exploration slot
        # degenerates to a delivery (§4.9.3) — the oracle's exact row.
        degenerated = quest_gen.offers(
            "lisbon", 12, world, ["disc_atlas_cedars", "disc_jebel_musa"])
        assert degenerated[0] == LISBON_WEEK1[0]
        assert degenerated[1]["type"] == "delivery"
        assert degenerated[1]["requirements"] == {
            "good_id": "spices", "quantity": 40, "dest_port_id": "oporto"}
        assert degenerated[2]["type"] == "bounty"
        assert degenerated[2]["requirements"] == {
            "tier": 2, "target_fleet_id": ""}

    def test_hint_candidates_wrap_and_sort(self, world: RasterWorld) -> None:
        # lisbon's in-range (Chebyshev ≤ 80) unfound discoveries, ascending.
        from server.sim.quests.quest_gen import _hint_candidates
        candidates = _hint_candidates(data(), set(), "lisbon", 80, world)
        assert candidates == sorted(candidates)
        assert "disc_atlas_cedars" in candidates
        # Found ids drop out.
        assert "disc_atlas_cedars" not in _hint_candidates(
            data(), {"disc_atlas_cedars"}, "lisbon", 80, world)


# --- 3. The §4.9.3 draw bands on every offer (tools/test_quests.gd §2) ------


class TestOfferBands:
    def test_every_draw_is_in_the_pinned_bands(self, world: RasterWorld) -> None:
        types: set[str] = set()
        for week in range(60):
            day = week * 7 + 1
            for offer in quest_gen.offers("lisbon", day, world):
                type_id = str(offer["type"])
                types.add(type_id)
                rewards = offer["rewards"]
                if type_id == "delivery":
                    req = offer["requirements"]
                    quantity = int(req["quantity"])
                    base = int(data().get_good(str(req["good_id"]))
                               .get("base_price", 0))
                    assert quantity in (20, 30, 40, 50)
                    assert str(req["dest_port_id"]) not in ("", "lisbon")
                    assert int(rewards["gold"]) == 2 * base * quantity
                    assert int(rewards["fame"]) == 10
                    assert rewards["reputation"] == {
                        str(data().get_port(str(req["dest_port_id"]))
                            .get("nation_id", "")): 5}
                elif type_id == "bounty":
                    tier = int(offer["requirements"]["tier"])
                    assert tier in (1, 2, 3)
                    assert int(rewards["gold"]) \
                        == quest_gen.BOUNTY_GOLD_BY_TIER[tier]
                    assert int(rewards["fame"]) == 15
                    assert int(offer["expiry_days"]) == 30
                    assert rewards["reputation"] == {}
                else:
                    assert str(offer["requirements"]["discovery_id"])
                    assert int(rewards["fame"]) == 10
                    assert int(rewards["gold"]) == 0
                    assert int(offer["expiry_days"]) == 30
        assert types == {"delivery", "bounty", "exploration"}

    def test_delivery_distance_and_expiry_bands(self,
                                                world: RasterWorld) -> None:
        origin = world.port_cell("lisbon")
        for week in range(60):
            for offer in quest_gen.offers("lisbon", week * 7 + 1, world):
                if str(offer["type"]) != "delivery":
                    continue
                dest = world.port_cell(
                    str(offer["requirements"]["dest_port_id"]))
                distance = chebyshev_wrap(origin[0], origin[1],
                                          dest[0], dest[1])
                assert 3 <= distance <= 60
                assert int(offer["expiry_days"]) == min(
                    max(-(-distance // quest_gen.DELIVERY_EXPIRY_DIVISOR)
                        + quest_gen.DELIVERY_EXPIRY_PAD, 7), 30)


# --- 4. Acceptance (tools/test_quests.gd §3, §4) -----------------------------


class TestAcceptance:
    def test_accepted_offer_leaves_the_derived_list(self,
                                                    world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        before = quest_gen.available_offers(qs, "lisbon", 12, world)
        assert len(before) == 3
        accepted = quest_gen.accept(before[0], qs, st, "lisbon", 12,
                                    fleet=fleet)
        assert accepted
        assert len(qs.active_quests) == 1
        after = quest_gen.available_offers(qs, "lisbon", 12, world)
        assert ids_of(after) == ids_of(before)[1:]
        assert str(accepted["instance_id"]) not in ids_of(after)
        assert int(accepted["accepted_day"]) == 12
        assert int(accepted["deadline_day"]) \
            == 12 + int(accepted["expiry_days"])

    def test_accept_delivery_moves_goods_free(self, world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        req = offer["requirements"]
        good_id = str(req["good_id"])
        quantity = int(req["quantity"])
        assert fleet_lib.held(fleet, good_id) == 0
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        assert accepted
        assert fleet_lib.held(fleet, good_id) == quantity
        assert st.gold == 5000  # the goods are granted free
        assert int(accepted["rewards"]["gold"]) \
            == 2 * int(data().get_good(good_id)["base_price"]) * quantity

    def test_full_hold_refuses_with_no_hold(self, world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        fleet_lib.add_goods(fleet, "amber", fleet_lib.fleet_free(fleet))
        assert fleet_lib.fleet_free(fleet) == 0
        blocked = quest_gen.offers("lisbon", 12, world)[0]
        assert quest_gen.accept_block_reason(qs, st, blocked, fleet) \
            == "quest.no_hold"
        assert quest_gen.accept(blocked, qs, st, "lisbon", 12, fleet=fleet) \
            == {}
        assert qs.active_quests == []

    def test_bounty_accept_spawns_and_tags_the_target(
            self, world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[2]  # the tier-3 bounty
        assert str(offer["type"]) == "bounty"

        def spawn_target(quest: dict[str, Any], day: int) -> str:
            assert day == 12
            tier = int(quest["requirements"]["tier"])
            assert tier == 3
            qs.npc_fleets.append({"id": "hf_7_1_pirate", "role": "pirate",
                                  "tier": tier})
            return "hf_7_1_pirate"

        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet,
                                    spawn_target=spawn_target)
        assert str(accepted["requirements"]["target_fleet_id"]) \
            == "hf_7_1_pirate"
        marker = quest_gen.find_marker(qs, "hf_7_1_pirate")
        assert str(marker.get("quest_id")) == "q_lisbon_1_2"
        assert int(marker.get("tier", 0)) == 3

    def test_bounty_accept_without_the_ecology_module(
            self, world: RasterWorld) -> None:
        # The GDScript ResourceLoader guard: no NpcFleets → no target
        # materialises, the offer still accepts.
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[2]
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        assert accepted
        assert str(accepted["requirements"]["target_fleet_id"]) == ""


# --- 5. Slots & the §4.9.2 viscount grant (tools/test_quests.gd §5) ----------


class TestSlots:
    def test_base_cap_is_three(self) -> None:
        st, _qs, _fleet = new_run()
        assert quest_gen.max_active_quests(st) == 3

    def test_three_active_then_the_fourth_is_refused(self,
                                                     world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        filled = 0
        for week in range(20):
            day = week * 7 + 1
            for offer in quest_gen.offers("lisbon", day, world):
                if filled >= 3:
                    break
                if str(offer["type"]) == "bounty":
                    continue
                if quest_gen.accept(offer, qs, st, "lisbon", day,
                                    fleet=fleet):
                    filled += 1
        assert quest_gen.active_count(qs) == 3
        fourth: dict[str, Any] = {}
        for week in range(20):
            for offer in quest_gen.offers("lisbon", week * 7 + 1, world):
                if quest_gen.accept_block_reason(qs, st, offer, fleet) \
                        == "quest.slots_full":
                    fourth = offer
                    break
            if fourth:
                break
        assert fourth
        assert quest_gen.accept(fourth, qs, st, "lisbon", 12, fleet=fleet) \
            == {}

    def test_title_bonus_raises_and_restores_the_cap(self) -> None:
        st, _qs, _fleet = new_run()
        st.titles["spain"] = "viscount"
        assert quest_gen.max_active_quests(st) == 4
        assert fame_lib.quest_slots_bonus(st) == 1
        st.titles["spain"] = "count"
        assert quest_gen.max_active_quests(st) == 4
        st.titles["spain"] = "duke"
        assert quest_gen.max_active_quests(st) == 4
        st.titles["spain"] = "none"
        assert quest_gen.max_active_quests(st) == 3
        # knight/baron do not hold the viscount grant (§4.9.2 ladder).
        st.titles["spain"] = "knight"
        assert quest_gen.max_active_quests(st) == 3
        st.titles["spain"] = "baron"
        assert quest_gen.max_active_quests(st) == 3

    def test_active_count_and_prune_see_only_live_quests(self) -> None:
        _st, qs, _fleet = new_run()
        qs.active_quests = [
            {"instance_id": "a", "status": "active"},
            {"instance_id": "b", "status": "completed"},
            {"instance_id": "c", "status": "failed"},
            "junk",
        ]
        assert quest_gen.active_count(qs) == 1
        assert [q["instance_id"] for q in quest_gen.active_quests(qs)] == ["a"]
        assert quest_gen.prune(qs) == 3
        assert qs.active_quests == [{"instance_id": "a", "status": "active"}]


# --- 6. Completion (tools/test_quests.gd §6, §9, §10) ------------------------


class TestCompletion:
    def test_delivery_completes_at_its_destination(self,
                                                   world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        req = offer["requirements"]
        dest = str(req["dest_port_id"])
        nation = str(data().get_port(dest)["nation_id"])
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        reward = int(accepted["rewards"]["gold"])

        assert quest_gen.complete_delivery_quests(qs, st, "madeira", fleet) \
            == []
        assert st.gold == 5000  # no reward is paid early

        done = quest_gen.complete_delivery_quests(qs, st, dest, fleet)
        assert len(done) == 1
        assert st.gold == 5000 + reward
        assert fleet_lib.held(fleet, str(req["good_id"])) == 0
        assert st.fame == 10
        assert character_lib.reputation(st, nation) == 5
        assert str(done[0]["status"]) == "completed"
        assert int(done[0]["completed_day"]) == 12
        assert quest_gen.active_count(qs) == 0

    def test_exploration_completes_on_the_report(self,
                                                 world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        chosen = offer_of_type("lisbon", 1, "exploration", world)
        discovery_id = str(chosen["requirements"]["discovery_id"])
        assert data().get_discovery(discovery_id).get("region_hint")
        accepted = quest_gen.accept(chosen, qs, st, "lisbon", 12, fleet=fleet)
        assert accepted
        done = quest_gen.complete_exploration_quests(qs, st, discovery_id)
        assert len(done) == 1
        assert st.fame == 10  # on top of the report's own reward (§4.4)
        assert str(done[0]["status"]) == "completed"
        # A different discovery completes nothing.
        _st2, qs2, _f2 = new_run()
        quest_gen.accept(chosen, qs2, _st2, "lisbon", 12, fleet=_f2)
        assert quest_gen.complete_exploration_quests(qs2, _st2,
                                                     "disc_other") == []

    def test_bounty_completes_on_a_victory_against_the_target(
            self, world: RasterWorld) -> None:
        st, qs, fleet = new_run("lisbon", 1)
        chosen = offer_of_type("lisbon", 1, "bounty", world)
        accepted = quest_gen.accept(chosen, qs, st, "lisbon", 1, fleet=fleet,
                                    spawn_target=_spawn_with_id(
                                        qs, "hf_1_1_pirate"))
        target_id = str(accepted["requirements"]["target_fleet_id"])
        assert target_id == "hf_1_1_pirate"
        reward = int(accepted["rewards"]["gold"])

        done = quest_gen.complete_bounty_quests(qs, st, target_id)
        assert len(done) == 1
        assert st.gold == 5000 + reward
        assert st.fame == 15
        # An unrelated fleet id does nothing.
        _st2, qs2, _f2 = new_run("lisbon", 1)
        again = quest_gen.accept(chosen, qs2, _st2, "lisbon", 1, fleet=_f2,
                                 spawn_target=_spawn_with_id(qs2, "hf_2_9"))
        assert quest_gen.complete_bounty_quests(qs2, _st2,
                                                "hf_999_1_1_pirate") == []
        assert str(again["requirements"]["target_fleet_id"]) == "hf_2_9"
        # A completed bounty is never completed twice.
        assert quest_gen.complete_bounty_quests(qs, st, target_id) == []
        assert st.gold == 5000 + reward


def _spawn_with_id(qs: QuestState, fleet_id: str):
    """A closure spawner that registers the marker (the NpcFleets.spawn
    half of the seam) and returns its id."""

    def spawn(quest: dict[str, Any], _day: int) -> str:
        qs.npc_fleets.append({"id": fleet_id, "role": "pirate",
                              "tier": int(quest["requirements"]["tier"])})
        return fleet_id

    return spawn


# --- 7. Failure paths (tools/test_quests.gd §7, §8) ---------------------------


class TestFailure:
    def test_cargo_sold_fails_with_the_pinned_delta(self,
                                                    world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        req = offer["requirements"]
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        origin_nation = str(data().get_port("lisbon")["nation_id"])

        fleet_lib.remove_goods(fleet, str(req["good_id"]),
                               int(req["quantity"]))
        assert quest_gen.delivery_cargo_lost(accepted, fleet)
        failed = quest_gen.tick(qs, st, 12, fleet)
        assert len(failed) == 1
        assert character_lib.reputation(st, origin_nation) == -5
        assert st.fame == 0
        assert st.gold == 5000
        assert str(failed[0]["status"]) == "failed"
        assert int(failed[0]["failed_day"]) == 12
        # A failed quest is never failed twice.
        assert quest_gen.tick(qs, st, 12, fleet) == []

    def test_abandon_uses_the_same_path(self, world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        second = quest_gen.accept(quest_gen.offers("lisbon", 12, world)[2],
                                  qs, st, "lisbon", 12, fleet=fleet)
        assert second
        origin_nation = str(data().get_port("lisbon")["nation_id"])
        assert quest_gen.abandon(qs, st, second)
        assert str(second["status"]) == "failed"
        assert character_lib.reputation(st, origin_nation) == -5

    def test_expiry_boundary_is_day_after_deadline(self,
                                                   world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        req = offer["requirements"]
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        deadline = int(accepted["deadline_day"])
        assert not quest_gen.is_expired(accepted, deadline)
        assert quest_gen.is_expired(accepted, deadline + 1)
        origin_nation = str(data().get_port("lisbon")["nation_id"])
        failed = quest_gen.tick(qs, st, deadline + 1, fleet)
        assert len(failed) == 1
        assert character_lib.reputation(st, origin_nation) == -5
        # Expiry does not reclaim the goods (§4.9.3).
        assert fleet_lib.held(fleet, str(req["good_id"])) \
            == int(req["quantity"])

    def test_zero_deadline_never_expires(self) -> None:
        assert not quest_gen.is_expired({"deadline_day": 0}, 9999)
        assert not quest_gen.is_expired({}, 9999)

    def test_fail_refuses_a_non_active_instance(self) -> None:
        st, qs, _fleet = new_run()
        quest = {"status": "completed"}
        assert not quest_gen.fail(qs, st, quest)


# --- 8. Presentation keys (the quest.line frames) -----------------------------


class TestPresentation:
    def test_type_keys(self) -> None:
        assert quest_gen.type_key({"type": "delivery"}) == "quest.type.delivery"
        assert quest_gen.type_key({}) == "quest.type."

    def test_objective_text_lines(self, world: RasterWorld) -> None:
        i18n = _TestI18n()
        delivery = quest_gen.objective_text(LISBON_WEEK1[0], QuestState(),
                                            i18n)
        assert delivery == "Carry 40 Timber to Oporto"
        bounty = quest_gen.objective_text(LISBON_WEEK1[2], QuestState(), i18n)
        assert bounty == "Hunt Pirate fleet (tier 3)"
        exploration = quest_gen.objective_text(LISBON_WEEK1[1], QuestState(),
                                               i18n)
        assert exploration == "Follow a rumour to a discovery"
        # The named-pirate captain read rides the injected resolver.
        qs = QuestState(npc_fleets=[{"id": "hf_1", "captain_id": "drake"}])
        named = dict(LISBON_WEEK1[2])
        named["requirements"] = {"tier": 3, "target_fleet_id": "hf_1"}
        line = quest_gen.objective_text(named, qs, i18n,
                                        captain_name_of=lambda _m: "Drake")
        assert line == "Hunt Drake (tier 3)"
        # An unnamed target keeps the generic label.
        line2 = quest_gen.objective_text(LISBON_WEEK1[2], QuestState(), i18n,
                                         captain_name_of=lambda _m: "")
        assert line2 == "Hunt Pirate fleet (tier 3)"
        # Royal missions name their objective from the template (§4.9.4).
        royal = {"template_id": "qt_royal_delivery", "type": "royal",
                 "requirements": {}}
        assert quest_gen.objective_text(royal, QuestState(), i18n) \
            == "Carry the king's dispatches"


class _TestI18n:
    """The i18n seam stand-in over ``ui_strings.json`` (autoload/i18n.gd's
    t/t_key/fmt, locale pinned to en)."""

    LOCALE = "en"

    def t(self, l10n: dict[str, Any]) -> str:
        text = l10n.get(self.LOCALE)
        if isinstance(text, str) and text:
            return text
        return "<missing>"

    def t_key(self, key: str) -> str:
        l10n = data().ui_strings.get(key, {})
        if not l10n:
            return f"<{key}>"
        return self.t(l10n)

    def fmt(self, key: str, values: dict[str, Any] | None = None) -> str:
        text = self.t_key(key)
        for name, value in (values or {}).items():
            text = text.replace("{%s}" % name, str(value))
        return text


# --- 9. The §4.9.5 piracy block (tools/test_bounty.gd §1, §2) -----------------


class TestPiracy:
    def test_rival_table_is_the_pinned_data(self) -> None:
        bad: list[str] = []
        for nation_id, expected in RIVALS.items():
            got = bounty_lib.rivals(nation_id)
            if got != expected:
                bad.append(f"{nation_id} got {got}")
        assert not bad, bad
        for nation_id, rivals in RIVALS.items():
            assert nation_id not in rivals
            assert len(rivals) == 2

    def test_piracy_deltas_block(self) -> None:
        deltas = bounty_lib.piracy_deltas("spain")
        assert deltas == {"spain": -20, "portugal": 2, "italy": 2}
        assert bounty_lib.piracy_deltas("") == {}

    def test_apply_piracy_moves_reputation_through_the_clamp(self) -> None:
        st, qs, _fleet = new_run()
        before = character_lib.reputation(st, "spain")
        assert bounty_lib.apply_piracy(st, qs, "spain") \
            == {"spain": -20, "portugal": 2, "italy": 2}
        assert character_lib.reputation(st, "spain") == before - 20
        assert character_lib.reputation(st, "portugal") == 2
        assert character_lib.reputation(st, "england") == 0
        # Clamping still applies at the floor.
        st.player["reputation"]["spain"] = -95
        bounty_lib.apply_piracy(st, qs, "spain")
        assert character_lib.reputation(st, "spain") == -100


# --- 10. Bounty issue: the −50 boundary & the fixed amount -------------------


class TestBountyIssue:
    def test_no_bounty_above_the_threshold(self) -> None:
        st, qs, _fleet = new_run()
        st.player["reputation"]["spain"] = -30
        assert bounty_lib.evaluate_all(st, qs) == []
        assert not bounty_lib.has_bounty(qs, "spain")

    def test_exactly_minus_fifty_issues(self) -> None:
        st, qs, _fleet = new_run()
        character_lib.add_reputation(st, "spain", -50)
        assert bounty_lib.evaluate_all(st, qs) == ["spain"]
        assert bounty_lib.has_bounty(qs, "spain")
        assert bounty_lib.amount(qs, "spain") == 25_000
        assert bounty_lib.record(qs, "spain") == {"amount": 25_000, "day": 12}
        assert bounty_lib.bountied_nations(qs) == ["spain"]

    def test_minus_forty_nine_stays_clear(self) -> None:
        st, qs, _fleet = new_run()
        character_lib.add_reputation(st, "spain", -49)
        assert bounty_lib.evaluate_all(st, qs) == []
        assert not bounty_lib.has_bounty(qs, "spain")

    def test_amount_is_fixed_at_issue_time(self) -> None:
        st, qs, _fleet = new_run()
        character_lib.add_reputation(st, "spain", -50)
        bounty_lib.evaluate_all(st, qs)
        character_lib.add_reputation(st, "spain", -30)  # now −80
        bounty_lib.evaluate_all(st, qs)
        assert bounty_lib.amount(qs, "spain") == 25_000

    def test_fresh_deeper_issue_prices_the_live_rep(self) -> None:
        st, qs, _fleet = new_run()
        st.player["reputation"]["italy"] = -70
        bounty_lib.evaluate_all(st, qs)
        assert bounty_lib.amount(qs, "italy") == 35_000

    def test_amount_boundary_at_the_floor(self) -> None:
        st, qs, _fleet = new_run()
        st.player["reputation"]["england"] = -100
        bounty_lib.evaluate_all(st, qs)
        assert bounty_lib.amount(qs, "england") == 50_000

    def test_issue_records_the_run_day(self) -> None:
        st, qs, _fleet = new_run("lisbon", 40)
        character_lib.add_reputation(st, "spain", -55)
        bounty_lib.evaluate_all(st, qs)
        assert int(bounty_lib.record(qs, "spain")["day"]) == 40


# --- 11. Closed ports (tools/test_bounty.gd §4, docs/70-* §4.9.6) -------------


class TestClosedPorts:
    def _bounty_spain(self, st: PersonState, qs: QuestState,
                      rep: int) -> None:
        st.player["reputation"]["spain"] = rep
        bounty_lib.evaluate_all(st, qs)

    def test_closed_port_matrix(self) -> None:
        st, qs, _fleet = new_run("seville")
        self._bounty_spain(st, qs, -60)
        assert bounty_lib.is_port_closed(qs, "seville")
        assert bounty_lib.is_port_closed(qs, "valencia")
        assert bounty_lib.is_port_closed(qs, "barcelona")
        assert not bounty_lib.is_port_closed(qs, "lisbon")
        assert not bounty_lib.is_port_closed(qs, "atlantis")

    def test_facilities_shut_except_the_bountied_capital_palace(self) -> None:
        st, qs, _fleet = new_run("seville")
        self._bounty_spain(st, qs, -60)
        assert not bounty_lib.can_open_facility(qs, "seville", "market")
        assert not bounty_lib.can_open_facility(qs, "seville", "guild")
        assert not bounty_lib.can_open_facility(qs, "seville", "tavern")
        assert bounty_lib.can_open_facility(qs, "seville", "palace")
        assert bounty_lib.can_pay_here(qs, "seville")
        # A non-capital closed port has no pay row.
        assert not bounty_lib.can_open_facility(qs, "valencia", "palace")
        assert not bounty_lib.can_pay_here(qs, "valencia")

    def test_open_port_opens_every_facility(self) -> None:
        st, qs, _fleet = new_run("seville")
        for facility in ("market", "guild", "palace", "tavern"):
            assert bounty_lib.can_open_facility(qs, "seville", facility)


# --- 12. Clearing: pay-off & surrender (tools/test_bounty.gd §5, §6) ----------


class TestClearing:
    def test_pay_off_charges_exactly_and_resets_to_minus_ten(self) -> None:
        st, qs, _fleet = new_run("seville")
        st.player["reputation"]["spain"] = -60
        bounty_lib.evaluate_all(st, qs)
        amount = bounty_lib.amount(qs, "spain")
        st.gold = amount + 500
        assert bounty_lib.can_pay_off(qs, st, "spain")
        assert bounty_lib.pay_off(qs, st, "spain")
        assert st.gold == amount + 500 - amount
        assert character_lib.reputation(st, "spain") == -10
        assert not bounty_lib.has_bounty(qs, "spain")
        assert not bounty_lib.is_port_closed(qs, "seville")
        assert bounty_lib.can_open_facility(qs, "seville", "market")
        assert not bounty_lib.can_pay_off(qs, st, "spain")

    def test_unaffordable_bounty_refuses_without_changes(self) -> None:
        st, qs, _fleet = new_run("seville")
        st.player["reputation"]["spain"] = -70
        bounty_lib.evaluate_all(st, qs)
        st.gold = 100
        rep_before = character_lib.reputation(st, "spain")
        assert not bounty_lib.can_pay_off(qs, st, "spain")
        assert not bounty_lib.pay_off(qs, st, "spain")
        assert character_lib.reputation(st, "spain") == rep_before
        assert bounty_lib.has_bounty(qs, "spain")

    def test_surrender_clears_without_gold(self) -> None:
        st, qs, _fleet = new_run("seville")
        st.player["reputation"]["spain"] = -55
        bounty_lib.evaluate_all(st, qs)
        assert bounty_lib.has_bounty(qs, "spain")
        assert bounty_lib.clear_by_surrender(qs, st, "spain")
        assert character_lib.reputation(st, "spain") == -10
        assert st.gold == 5000
        assert not bounty_lib.has_bounty(qs, "spain")

    def test_clearing_an_absent_bounty_refuses(self) -> None:
        st, qs, _fleet = new_run()
        assert not bounty_lib.clear_by_surrender(qs, st, "spain")
        assert not bounty_lib.pay_off(qs, st, "spain")

    def test_a_climbing_rep_does_not_drop_the_bounty(self) -> None:
        # Only the two §4.9.5 clearing paths remove a bounty; a nation that
        # climbs back above −50 keeps it (evaluate_all only ever issues).
        st, qs, _fleet = new_run()
        st.player["reputation"]["spain"] = -60
        bounty_lib.evaluate_all(st, qs)
        st.player["reputation"]["spain"] = 0
        assert bounty_lib.evaluate_all(st, qs) == []
        assert bounty_lib.has_bounty(qs, "spain")


# --- 13. No lockout (tools/test_bounty.gd §8, §9) -----------------------------


class TestNoLockout:
    def test_all_six_nations_can_be_bountied_at_once(self) -> None:
        st, qs, _fleet = new_run("lisbon")
        for nation in NATIONS:
            st.player["reputation"][nation] = -100
        issued = bounty_lib.evaluate_all(st, qs)
        assert len(issued) == 6
        assert len(qs.bounties) == 6
        assert bounty_lib.bountied_nations(qs) == sorted(NATIONS)
        st.gold = 0
        # The own capital's palace stays reachable (the §4.9.6 exception).
        assert bounty_lib.can_open_facility(qs, "lisbon", "palace")
        assert bounty_lib.can_pay_here(qs, "lisbon")

    def test_own_nation_bounty_round_trip(self) -> None:
        st, qs, _fleet = new_run("lisbon", 40)
        st.player["reputation"]["portugal"] = -55
        bounty_lib.evaluate_all(st, qs)
        assert bounty_lib.has_bounty(qs, "portugal")
        assert bounty_lib.is_port_closed(qs, "lisbon")
        assert bounty_lib.can_pay_here(qs, "lisbon")
        st.gold = bounty_lib.amount(qs, "portugal")
        assert bounty_lib.pay_off(qs, st, "portugal")
        assert character_lib.reputation(st, "portugal") == -10
        assert not bounty_lib.is_port_closed(qs, "lisbon")


# --- 14. The phase3_hooks wiring order ----------------------------------------


class TestPhase3Hooks:
    def test_on_day_tick_reports_and_prunes(self, world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        deadline = int(accepted["deadline_day"])
        st.day = deadline + 1
        report = phase3_hooks.on_day_tick(st, qs, deadline + 1, fleet=fleet)
        assert str(accepted["status"]) == "failed"
        assert report["failed_quests"] == [accepted]
        assert report["failed_missions"] == []
        assert report["bounties_issued"] == []
        assert quest_gen.active_count(qs) == 0  # pruned
        # With the palace seam wired, its report flows through unchanged.
        st2, qs2, fleet2 = new_run()
        report2 = phase3_hooks.on_day_tick(
            st2, qs2, 13, fleet=fleet2,
            palace_tick=lambda _st, _qs, _day: [{"mission": "x"}])
        assert report2["failed_missions"] == [{"mission": "x"}]

    def test_on_day_tick_issues_a_crossed_bounty(self) -> None:
        # The rep moved elsewhere (a piracy act, a sale) below the §4.9.5
        # threshold without a bounty scan; the tick re-evaluates every
        # nation and issues.
        st, qs, fleet = new_run()
        st.player["reputation"]["spain"] = -55
        report = phase3_hooks.on_day_tick(st, qs, 13, fleet=fleet)
        assert report["bounties_issued"] == ["spain"]
        assert bounty_lib.has_bounty(qs, "spain")

    def test_on_port_entered_completes_the_delivery(self,
                                                    world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        dest = str(offer["requirements"]["dest_port_id"])
        done = phase3_hooks.on_port_entered(qs, st, dest, fleet)
        assert done == [accepted]
        assert str(accepted["status"]) == "completed"
        assert phase3_hooks.on_port_entered(qs, st, "", fleet) == []

    def test_on_cargo_changed_fails_at_once(self, world: RasterWorld) -> None:
        st, qs, fleet = new_run()
        offer = quest_gen.offers("lisbon", 12, world)[0]
        accepted = quest_gen.accept(offer, qs, st, "lisbon", 12, fleet=fleet)
        origin_nation = str(data().get_port("lisbon")["nation_id"])
        fleet_lib.remove_goods(fleet, str(offer["requirements"]["good_id"]),
                               int(offer["requirements"]["quantity"]))
        failed = phase3_hooks.on_cargo_changed(qs, st, fleet)
        assert failed == [accepted]
        assert str(accepted["status"]) == "failed"
        assert character_lib.reputation(st, origin_nation) == -5

    def test_on_battle_finished_bounty_victory(self, world: RasterWorld) -> None:
        st, qs, fleet = new_run("lisbon", 1)
        chosen = offer_of_type("lisbon", 1, "bounty", world)
        accepted = quest_gen.accept(chosen, qs, st, "lisbon", 1, fleet=fleet,
                                    spawn_target=_spawn_with_marker(qs))
        target_id = str(accepted["requirements"]["target_fleet_id"])
        report = phase3_hooks.on_battle_finished(st, qs, {
            "result": "victory", "kind": "pirate", "nation_id": "",
            "encounter_id": target_id})
        assert report["won"] is True
        assert qs.battles_won == 1
        assert report["completed_quests"] == [accepted]
        assert report["cleared_bounty"] == ""
        assert report["patrol_completed"] == []
        assert st.gold == 5000 + int(accepted["rewards"]["gold"])
        assert st.fame == 15

    def test_on_battle_finished_unrelated_victory(self) -> None:
        st, qs, _fleet = new_run("lisbon", 1)
        report = phase3_hooks.on_battle_finished(st, qs, {
            "result": "victory", "kind": "pirate", "nation_id": "",
            "encounter_id": "hf_999_1_1_pirate"})
        assert report["won"] is True
        assert qs.battles_won == 1
        assert report["completed_quests"] == []

    def test_on_battle_finished_counts_one_win_per_outcome(self) -> None:
        st, qs, _fleet = new_run()
        for _ in range(3):
            phase3_hooks.on_battle_finished(st, qs, {"result": "victory"})
        assert qs.battles_won == 3
        defeat = phase3_hooks.on_battle_finished(st, qs, {"result": "defeat"})
        assert qs.battles_won == 3
        assert defeat["won"] is False

    def test_on_battle_finished_surrender_clears_the_bounty(self) -> None:
        st, qs, _fleet = new_run()
        st.player["reputation"]["spain"] = -55
        bounty_lib.evaluate_all(st, qs)
        report = phase3_hooks.on_battle_finished(st, qs, {
            "result": "surrender", "kind": "navy", "nation_id": "spain",
            "encounter_id": "hf_2_1_hunter"})
        assert report["cleared_bounty"] == "spain"
        assert character_lib.reputation(st, "spain") == -10
        assert not bounty_lib.has_bounty(qs, "spain")

    def test_on_battle_finished_palace_giver_routes_to_the_seam(self) -> None:
        st, qs, _fleet = new_run()
        qs.npc_fleets.append({"id": "nv_1", "quest_id": "q_seville_1_0"})
        qs.active_quests.append({
            "instance_id": "q_seville_1_0", "type": "royal_patrol",
            "giver": "palace", "origin_port_id": "seville", "status": "active",
            "requirements": {}, "rewards": {}})
        seen: dict[str, Any] = {}

        def patrol_kill(quest: dict[str, Any]) -> dict[str, Any]:
            seen["quest"] = quest
            return {"mission": "royal_patrol", "gold": 8000}

        report = phase3_hooks.on_battle_finished(
            st, qs, {"result": "victory", "encounter_id": "nv_1"},
            palace_patrol_kill=patrol_kill)
        assert str(seen["quest"]["instance_id"]) == "q_seville_1_0"
        assert report["patrol_completed"] == [
            {"mission": "royal_patrol", "gold": 8000}]
        assert report["completed_quests"] == []

    def test_on_battle_finished_empty_outcome(self) -> None:
        st, qs, _fleet = new_run()
        assert phase3_hooks.on_battle_finished(st, qs, {}) == {
            "won": False, "completed_quests": [], "cleared_bounty": "",
            "patrol_completed": []}
        assert qs.battles_won == 0

    def test_explore_seams(self) -> None:
        assert phase3_hooks.explore_here((10, 10)) == []
        assert phase3_hooks.something_near((10, 10)) is False
        assert phase3_hooks.explore_here((10, 10),
                                         explore=lambda _c: ["disc_x"]) \
            == ["disc_x"]
        assert phase3_hooks.something_near((10, 10),
                                           something_near_fn=lambda _c: True)

    def test_tournament_glue(self) -> None:
        st, qs, _fleet = new_run()
        assert not phase3_hooks.is_tournament("hf_1_1_pirate")
        assert phase3_hooks.is_tournament("tournament_venice_1")
        # Round 1 won: advance, no settlement.
        first = phase3_hooks.on_tournament_bout(
            st, qs, {"result": "victory", "encounter_id": "tournament_venice_1"},
            tournament_settle=lambda won, reached: {"settled": True})
        assert first == {"won": True, "round_reached": 1, "next_round": 2}
        assert phase3_hooks.take_pending_bout(qs) == 2
        assert phase3_hooks.take_pending_bout(qs) == 0
        # Round 3 won (the pinned bracket length): settle + stash.
        settles: list[tuple[bool, int]] = []
        final = phase3_hooks.on_tournament_bout(
            st, qs,
            {"result": "victory", "encounter_id": "tournament_venice_3"},
            tournament_settle=lambda won, reached: settles.append(
                (won, reached)) or {"prize": 10000, "fame": 100})
        assert final == {"prize": 10000, "fame": 100}
        assert settles == [(True, 3)]
        assert phase3_hooks.take_tournament_outcome(qs) \
            == {"prize": 10000, "fame": 100}
        assert phase3_hooks.take_tournament_outcome(qs) == {}
        # A lost round settles the consolation immediately.
        consolation = phase3_hooks.on_tournament_bout(
            st, qs,
            {"result": "defeat", "encounter_id": "tournament_london_2"},
            tournament_settle=lambda won, reached: {"consolation": 500})
        assert consolation == {"consolation": 500}
        assert phase3_hooks.take_pending_bout(qs) == 0
        # A non-tournament encounter settles nothing.
        assert phase3_hooks.on_tournament_bout(
            st, qs, {"result": "victory", "encounter_id": "hf_1_1_pirate"},
            tournament_settle=lambda won, reached: {}) == {}


def _spawn_with_marker(qs: QuestState):
    """A closure spawner that registers the marker (the NpcFleets.spawn
    half of the seam) and returns its id."""

    def spawn(quest: dict[str, Any], _day: int) -> str:
        qs.npc_fleets.append({"id": "hf_1_1_pirate", "role": "pirate",
                              "tier": int(quest["requirements"]["tier"])})
        return "hf_1_1_pirate"

    return spawn
