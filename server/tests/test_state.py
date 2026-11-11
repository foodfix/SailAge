"""Parity suite for ``server/sim/state.py`` — the GameState keystone (M1).

Oracle: ``autoload/game_state.gd`` (frozen read-only until the M6 cutover).
Normative contract: ``docs/90-ARCHITECTURE.md`` §5.4 (the field list, the
pinned defaults, ``new_game`` and the day-tick listener order), §8.1 (the
save payload key set this state is cut from) and §0.5 (web-era save v1).

Port the guarantee, not the method: every assertion below pins a documented
number or shape, not an internal call sequence the oracle left free. The
day-tick order is observed by monkeypatching the owning modules' step
functions (the sailing engine owns the ledger/economy/month pipeline; this
suite records the whole listener chain and asserts the §5.4 order).
"""

from __future__ import annotations

import copy

import pytest

from server.sim.data import data
from server.sim.player import PersonState, character
from server.sim.port import allegiance, economy
from server.sim.port.allegiance import AllegianceState
from server.sim.quests import phase3_hooks
from server.sim.state import (
    DEFAULT_CONTROL_PREFS,
    SNAPSHOT_KEYS,
    GameState,
)
from server.sim.world import captains, npc_fleets, sailing
from server.sim.world.sailing import SailingState

#: Every §5.4 field, including the five Phase-7 keys the oracle kept in the
#: allegiance runtime (exposed here as aliases/derived properties) and the
#: declared transients.
SECTION_54_FIELDS = (
    "locale", "day", "gold", "player", "fleet", "world", "morale",
    "current_port", "port_investments", "known_ports", "npc_fleets",
    "market_stocks", "wrecks", "npc_preset", "control_prefs", "market_events",
    "permits", "port_allegiance", "month_invested", "nation_treasuries",
    "fame_commended", "officer_states", "captain_states",
    "proximity_cooldowns", "quests", "discoveries_found", "fame", "titles",
    "bounties", "active_quests", "completed_royal_missions",
    "discoveries_reported", "discovery_hints", "battles_won", "retired",
    "retired_at",
)

#: The declared transients (never saved).
TRANSIENT_FIELDS = (
    "npc_port_log", "pending_encounter", "pending_tournament_round",
    "last_tournament_outcome", "pending_levelup",
)

#: The §8.1 v9 payload keys this state cuts (``tools/test_save_v9.gd``
#: ``V9_PAYLOAD_KEYS`` minus the three header keys), in oracle order.
V9_STATE_KEYS = (
    "locale", "day", "gold", "player", "fleet", "morale", "world",
    "current_port", "known_ports", "explored_tiles", "port_investments",
    "discoveries_found", "npc_fleets", "officer_states", "captain_states",
    "proximity_cooldowns", "market_stocks", "wrecks", "npc_preset",
    "control_prefs", "market_events", "fame", "titles", "bounties",
    "active_quests", "completed_royal_missions", "discoveries_reported",
    "discovery_hints", "battles_won", "retired", "retired_at", "permits",
    "port_allegiance", "month_invested", "nation_treasuries",
    "fame_commended",
)

#: The v9 Person block's interior keys (docs/50-* §4.8).
PERSON_BLOCK_KEYS = {
    "nation_id", "background_id", "attributes", "skills", "skill_counters",
    "alloc_pending", "xp", "level", "officers", "reputation",
    "profit_by_nation", "profit_rep_awarded", "equipment",
}

#: The eight persisted ``world`` keys (``clock_fraction`` is runtime-only).
WORLD_PAYLOAD_KEYS = {
    "position", "weather", "map_id", "last_departed_port",
    "hunter_intel_cell", "sail_trim", "heading", "wind_dir",
}

#: The §4.15 ``captain_states`` save shape.
CAPTAIN_STATE_KEYS = {
    "status", "return_day", "tier_now", "stance", "familiarity",
    "dossier_seen", "defeats", "wins",
}


def _new_game(nation_id: str = "portugal", background_id: str = "",
              attr_alloc: dict[str, int] | None = None,
              skill_alloc: dict[str, int] | None = None) -> GameState:
    """A fresh run on the real data tree (deterministic — no seeded stream
    is consumed by ``new_game``)."""
    return GameState().new_game(
        nation_id, background_id, attr_alloc, skill_alloc)


# --- §5.4 field inventory & pinned defaults ---------------------------------


def test_every_section_5_4_field_exists_with_its_pinned_default() -> None:
    gs = _new_game()
    for name in SECTION_54_FIELDS + TRANSIENT_FIELDS:
        assert hasattr(gs, name), f"missing §5.4 field {name}"

    # Header / clock / purse.
    assert gs.locale == "en"
    assert gs.day == 1
    assert gs.gold == 5000  # portugal.start_gold
    assert gs.morale == 70  # 20-* §4.8: "New game: 70."
    assert gs.current_port == "lisbon"
    assert gs.port_investments == {}
    assert gs.explored_tiles == set()

    # The Person block is the full v9 shape and starts at its §4.8 defaults.
    assert set(gs.player) == PERSON_BLOCK_KEYS
    assert gs.player["nation_id"] == "portugal"
    assert gs.player["background_id"] == ""
    assert gs.player["alloc_pending"] == 0 and gs.player["xp"] == 0
    assert gs.player["level"] == 1
    assert gs.player["officers"] == []

    # Phase-3 tail.
    assert gs.quests == []
    assert gs.discoveries_found == []
    assert gs.fame == 0
    assert gs.titles == {
        "portugal": "none", "spain": "none", "england": "none",
        "holland": "none", "ottoman": "none", "italy": "none"}
    assert gs.bounties == {}
    assert gs.active_quests == []
    assert gs.completed_royal_missions == {
        "portugal": 0, "spain": 0, "england": 0, "holland": 0,
        "ottoman": 0, "italy": 0}
    assert gs.discoveries_reported == []
    assert gs.discovery_hints == {}
    assert gs.battles_won == 0
    assert gs.retired is False and gs.retired_at == 0

    # Phase-5/6/7/8 blocks at their fresh-run defaults.
    assert gs.officer_states == {}
    assert gs.proximity_cooldowns == {}
    assert gs.wrecks == []
    assert gs.npc_preset == "normal"
    assert gs.control_prefs == {"input_mode": "step",
                                "current_mode": "modifier"}
    assert gs.market_events == []
    assert gs.permits == {"home": False, "foreign": {}}
    assert gs.month_invested == {}
    assert gs.fame_commended == {}
    assert gs.nation_treasuries == {
        "portugal": 5000, "spain": 5000, "england": 5000,
        "holland": 5000, "ottoman": 5000, "italy": 5000}  # 30-* §4.9

    # Declared transients start empty/neutral.
    assert gs.npc_port_log == []
    assert gs.pending_encounter is None
    assert gs.pending_tournament_round == 0
    assert gs.last_tournament_outcome == {}
    assert gs.pending_levelup is False and gs.pending_raise is False

    # The world block carries every key at its pinned default.
    assert set(gs.world) == WORLD_PAYLOAD_KEYS | {"clock_fraction"}
    assert gs.world["map_id"] == "world"
    assert gs.world["weather"] == "calm"
    assert gs.world["sail_trim"] == "normal"
    assert gs.world["heading"] == "E"
    assert gs.world["wind_dir"] == "E"
    assert gs.world["last_departed_port"] == ""
    assert gs.world["hunter_intel_cell"] is None
    assert gs.world["clock_fraction"] == 0.0


# --- Portugal / Lisbon starter state (docs/50-* §4.1 step 5) ----------------


def test_portugal_new_game_produces_the_documented_starter_state() -> None:
    store = data()
    gs = _new_game("portugal")

    # Purse, hull, port, berth (the §8.1 Lisbon example tile 2050/615).
    assert gs.gold == store.get_nation("portugal")["start_gold"] == 5000
    assert len(gs.fleet) == 1
    ship = gs.fleet[0]
    caravel = store.get_ship_type("caravel")
    assert ship["ship_type_id"] == "caravel"
    assert ship["crew"] == caravel["crew_min"] == 15
    assert ship["durability"] == caravel["durability"]
    assert gs.current_port == "lisbon"
    assert gs.world["position"] == {"x": 2050, "y": 615}
    assert gs.world_tile() == (2050, 615)

    # Known ports: every nation's capital (the §4.1 start package).
    assert gs.known_ports == [
        "lisbon", "seville", "london", "amsterdam", "istanbul", "venice"]

    # Market stocks: one row per port, the listing rule's goods per row.
    ports = store.ports_list
    assert set(gs.market_stocks) == {str(p["id"]) for p in ports}
    assert len(gs.market_stocks) == 150
    lisbon = store.get_port("lisbon")
    listed = {str(g["id"]) for g in store.goods_list
              if economy.is_listed_in(lisbon, str(g["id"]))}
    assert set(gs.market_stocks["lisbon"]) == listed
    # A producer starts at capacity scaled by the authored dev floor (3),
    # a consumer at the pinned 60, an unlisted good is absent (30-* §4.2).
    tiers = economy.build_tiers(store.goods_list)
    expected_wine = economy.capacity_for(
        economy.tier_capacity(tiers, "wine"), 3)
    assert gs.market_stocks["lisbon"]["wine"] == expected_wine
    assert gs.market_stocks["lisbon"]["wheat"] == 60
    unlisted = sorted({str(g["id"]) for g in store.goods_list} - listed)[0]
    assert unlisted not in gs.market_stocks["lisbon"]

    # Allegiance seeding: every contestable port, protected ports absent,
    # sovereigns {owner: 6,000}, neutrals empty (30-* §4.9 / 90-* §8.1).
    contestable = [p for p in ports if not p.get("protected", False)]
    protected = [p for p in ports if p.get("protected", False)]
    assert len(contestable) == 133 and len(protected) == 17
    assert len(gs.port_allegiance) == len(contestable)
    for port in protected:
        assert str(port["id"]) not in gs.port_allegiance
    for port in contestable:
        entry = gs.port_allegiance[str(port["id"])]
        owner = str(port.get("nation_id", ""))
        if owner:
            assert entry == {"ledger": {owner: 6000}, "allegiance": owner}
        else:
            assert entry == {"ledger": {}, "allegiance": ""}
    # Spot checks on the real data (a sovereign and a neutral).
    assert gs.port_allegiance["malacca"] == {
        "ledger": {"portugal": 6000}, "allegiance": "portugal"}
    assert gs.port_allegiance["quanzhou"] == {
        "ledger": {}, "allegiance": ""}

    # The ecology initial fill: half the core cap at most, met captains
    # deployed into captain_states (the W4 gate amendment, 90-* §8.2).
    probe = npc_fleets.NpcFleets(
        {"npc_config": store.npc_config, "preset": "normal"},
        state=npc_fleets.FleetEcologyState(), store=store)
    assert 0 < len(gs.npc_fleets) <= probe.core_cap() // 2
    assert 0 < len(gs.captain_states) <= len(gs.npc_fleets)
    pointed = {str(f["captain_id"]) for f in gs.npc_fleets
               if str(f.get("captain_id", ""))}
    assert pointed and pointed <= set(gs.captain_states)
    for entry in gs.captain_states.values():
        assert set(entry) == CAPTAIN_STATE_KEYS | {"deployed"}
        assert entry["deployed"] is True


def test_new_game_plumbs_background_and_free_point_allocations() -> None:
    # The docs/50-* §4.1 step-5 worked extreme (test_creation.gd fixture):
    # Portugal + naval cadet + constitution +3 / courage +2, navigation +3.
    gs = _new_game(
        "portugal", "background_navy_cadet",
        {"constitution": 3, "courage": 2}, {"navigation": 3})
    attrs = gs.player["attributes"]
    assert attrs["constitution"] == 13
    assert attrs["intellect"] == 10 + 5  # Portugal's nation bonus
    assert attrs["courage"] == 10 + 3 + 2
    assert attrs["charisma"] == 10 and attrs["luck"] == 10
    assert gs.player["skills"]["navigation"] == 5 + 5 + 3  # creation extreme 13
    assert gs.player["background_id"] == "background_navy_cadet"


def test_new_game_rejects_an_unknown_nation() -> None:
    gs = GameState()
    with pytest.raises(ValueError):
        gs.new_game("atlantis")
    # Nothing was mutated by the refused call.
    assert gs.day == 1 and gs.gold == 0 and gs.player == {}


def test_new_game_carries_run_inputs_and_drops_out_of_domain_ones() -> None:
    gs = GameState()
    gs.locale = "zh"
    gs.npc_preset = "low"
    gs.control_prefs = {"input_mode": "helm", "current_mode": "drift"}
    gs.new_game("portugal")
    assert gs.locale == "zh"  # the language choice survives a new game
    assert gs.npc_preset == "low"
    assert gs.control_prefs == {"input_mode": "helm", "current_mode": "drift"}

    bad = GameState()
    bad.npc_preset = "bogus"
    bad.control_prefs = {"input_mode": "wat", "current_mode": "wat"}
    bad.new_game("portugal")
    assert bad.npc_preset == "normal"
    assert bad.control_prefs == DEFAULT_CONTROL_PREFS


# --- Determinism ------------------------------------------------------------


def test_two_identical_new_games_have_identical_snapshots() -> None:
    first = _new_game()
    second = _new_game()
    assert first.snapshot_keys() == second.snapshot_keys()


def test_a_seeded_day_tick_is_deterministic() -> None:
    first = _new_game()
    second = _new_game()
    for gs in (first, second):
        sailing.set_weather_seed(gs, 20261029)
        sailing.set_mutiny_seed(gs, 90210)
        assert gs.advance_day() == 1
        assert gs.advance_day() == 1
    assert first.day == second.day == 3
    assert first.snapshot_keys() == second.snapshot_keys()


# --- Day-tick order (docs/90-* §5.4; docs/20-* §4.3) ------------------------


def _spy_tick_steps(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Record every §5.4 step by wrapping its owning module function.

    ``ledger`` and the ``economy``/``month`` steps are the sailing engine's
    pipeline; the NPC/quest/captain listeners are GameState's chain.
    """
    observed: list[str] = []

    real_ledger = sailing._run_daily_ledger

    def spy_ledger(*args, **kwargs):
        observed.append("ledger")
        return real_ledger(*args, **kwargs)

    monkeypatch.setattr(sailing, "_run_daily_ledger", spy_ledger)

    real_economy = sailing.economy_day_tick

    def spy_economy(*args, **kwargs):
        observed.append("economy")
        return real_economy(*args, **kwargs)

    monkeypatch.setattr(sailing, "economy_day_tick", spy_economy)

    real_month = sailing.month_tick

    def spy_month(*args, **kwargs):
        observed.append("month")
        return real_month(*args, **kwargs)

    monkeypatch.setattr(sailing, "month_tick", spy_month)

    real_tick = npc_fleets.NpcFleets.tick

    def spy_tick(self, day: int):
        observed.append("npc_fleets")
        return real_tick(self, day)

    monkeypatch.setattr(npc_fleets.NpcFleets, "tick", spy_tick)

    real_quests = phase3_hooks.on_day_tick

    def spy_quests(*args, **kwargs):
        observed.append("quests")
        return real_quests(*args, **kwargs)

    monkeypatch.setattr(phase3_hooks, "on_day_tick", spy_quests)

    real_captains = captains.day_tick

    def spy_captains(*args, **kwargs):
        observed.append("captains")
        return real_captains(*args, **kwargs)

    monkeypatch.setattr(captains, "day_tick", spy_captains)
    return observed


def test_day_tick_runs_the_pinned_listener_order(
        monkeypatch: pytest.MonkeyPatch) -> None:
    gs = _new_game()
    sailing.set_weather_seed(gs, 20261029)
    sailing.set_mutiny_seed(gs, 90210)
    observed = _spy_tick_steps(monkeypatch)

    assert gs.advance_day() == 1
    assert gs.day == 2
    # The executed steps: the ledger, the economy drift, no month tick on a
    # non-boundary day, then the post-`day_advanced` listeners in order.
    assert observed == [
        "ledger", "economy", "npc_fleets", "quests", "captains"]
    # And the recorded seam: `day_advanced` sits between the economy step
    # and the ecology tick.
    assert gs.last_tick_order == [
        "ledger", "economy", "day_advanced", "npc_fleets", "quests",
        "captains"]


def test_month_tick_fires_once_on_the_boundary_and_resets_the_counter(
        monkeypatch: pytest.MonkeyPatch) -> None:
    gs = _new_game()
    gs.day = 30
    gs.month_invested = {"malacca": 100}
    sailing.set_weather_seed(gs, 20261029)
    sailing.set_mutiny_seed(gs, 90210)
    observed = _spy_tick_steps(monkeypatch)

    assert gs.advance_day() == 1
    assert gs.day == 31
    assert gs.day % 30 == 1
    assert observed.count("month") == 1
    assert observed == [
        "ledger", "economy", "month", "npc_fleets", "quests", "captains"]
    assert gs.last_tick_order == [
        "ledger", "economy", "month", "day_advanced", "npc_fleets",
        "quests", "captains"]
    # The month tick (docs/30-* §4.9) clears the monthly allowance.
    assert gs.month_invested == {}


def test_no_month_tick_off_the_boundary(
        monkeypatch: pytest.MonkeyPatch) -> None:
    gs = _new_game()
    gs.day = 31
    gs.month_invested = {"malacca": 100}
    sailing.set_weather_seed(gs, 20261029)
    sailing.set_mutiny_seed(gs, 90210)
    observed = _spy_tick_steps(monkeypatch)

    gs.advance_day()
    assert gs.day == 32
    assert "month" not in observed
    assert gs.month_invested == {"malacca": 100}
    assert "month" not in gs.last_tick_order


# --- Save shape (docs/90-* §8.1) --------------------------------------------


def test_snapshot_keys_is_exactly_the_section_8_1_state_block() -> None:
    gs = _new_game()
    payload = gs.snapshot_keys()
    assert tuple(payload) == SNAPSHOT_KEYS
    assert tuple(payload) == V9_STATE_KEYS
    # The caller adds the three header keys; the state never writes them.
    for header in ("save_version", "saved_at", "phase"):
        assert header not in payload
    # The superseded Phase-1 placeholder never reaches a payload.
    assert "quests" not in payload
    # `world` carries the eight persisted keys only.
    assert set(payload["world"]) == WORLD_PAYLOAD_KEYS
    assert "clock_fraction" not in payload["world"]


def test_snapshot_strips_the_runtime_only_captain_deployment_flag() -> None:
    gs = _new_game()
    assert gs.captain_states  # the initial fill deployed captains
    assert all("deployed" in entry for entry in gs.captain_states.values())
    payload = gs.snapshot_keys()
    for entry in payload["captain_states"].values():
        assert "deployed" not in entry
        assert set(entry) == CAPTAIN_STATE_KEYS
    # The snapshot is a copy: the live entries keep their runtime flag.
    assert all("deployed" in entry for entry in gs.captain_states.values())


def test_midday_snapshot_round_trips_through_deepcopy_unchanged() -> None:
    gs = _new_game()
    # A distinctive mid-day state: half a day elapsed, some exploration and
    # every mutable block carrying a value.
    gs.world["clock_fraction"] = 0.5
    gs.explored_tiles = {(2050, 615), (2051, 615)}
    gs.port_investments = {"malacca": 500}
    gs.fame = 100
    gs.titles["portugal"] = "knight"
    gs.bounties = {"spain": {"amount": 2000, "day": 1}}
    gs.discovery_hints = {"disc_x": True}
    gs.market_events = [{"template_id": "evt", "port_id": "lisbon",
                         "start_day": 1}]

    payload = gs.snapshot_keys()
    clone = copy.deepcopy(payload)
    assert clone == payload
    assert gs.snapshot_keys() == payload  # snapshotting is not lossy
    # Deep copy: mutating the payload never reaches the live state.
    clone["player"]["attributes"]["constitution"] = 99
    clone["explored_tiles"].add((1, 1))
    assert gs.player["attributes"]["constitution"] != 99
    assert (1, 1) not in gs.explored_tiles
    # The runtime-only accumulator is excluded from the payload.
    assert "clock_fraction" not in payload["world"]
    # Every declared transient is absent.
    for name in TRANSIENT_FIELDS + (
            "pending_raise", "last_tick_order", "cons_surges",
            "last_started"):
        assert name not in payload


# --- The keystone: one object flows into every ported module ----------------


def test_gamestate_is_the_state_object_every_engine_takes() -> None:
    store = data()
    gs = _new_game()

    # The composition is explicit: the three state dataclasses are bases.
    assert isinstance(gs, SailingState)
    assert isinstance(gs, PersonState)
    assert isinstance(gs, AllegianceState)

    # Person model reads the same object.
    assert character.reputation(gs, "portugal") == 20
    assert character.officer_wages(gs, store) == 0
    assert character.current_level(gs) == 1

    # Sailing / economy / allegiance take it in place.
    assert sailing.in_port(gs) is True
    assert sailing.docked_port_id(gs) == "lisbon"
    assert economy.stock_of(gs, store, "lisbon", "wine") == \
        gs.market_stocks["lisbon"]["wine"]
    assert allegiance.treasury(gs, "portugal") == 5000
    assert allegiance.has_permit_home(gs) is False
    # The ecology state members the FleetEcologyState adapter expects.
    assert gs.player_tile() == (2050, 615)
    assert gs.clock_now() == 1.0


def test_add_gold_announces_the_new_purse() -> None:
    gs = _new_game()
    seen: list[int] = []
    gs.on_gold_changed = seen.append
    assert gs.add_gold(-25) == 4975
    assert seen == [4975]
