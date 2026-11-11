"""Parity tests for the M1 living-sea ecology port (``server.sim.world``).

Ported guarantees from the frozen Godot-era suites
``tools/test_npc_fleets.gd``, ``tools/test_ecology.gd`` and
``tools/test_density.gd`` (the parity oracles until the M6 cutover), plus
the ``scripts/world/fleet_path.gd`` pursuit-A* family.

Test discipline (AGENTS.md): assert the contract directly — the constant,
the closed form, the pinned formula, or one fixed-seed integration
observation. No Monte-Carlo soaks: the only statistical check is the
pinned 60% auto-resolve band over the oracle's own 200 seeded trials
(±0.12 around 0.60, the GDScript's deterministic stream), which cannot
approach its bounds. No full-map BFS or 318-fleet scale probe (that is a
separate milestone task).

Real data only: ``data/npc_config.json``, ``data/ports.json``,
``data/trade_routes_built.json`` (the built artifact), the shipped world
raster and canon. Fixtures that need a hostile pair are seeded with pinned
fleet seeds.
"""

from __future__ import annotations

import copy
import math

import pytest

from server.sim.data import data
from server.sim.port import allegiance as allegiance_lib
from server.sim.port import economy as economy_lib
from server.sim.port.allegiance import AllegianceState
from server.sim.port.economy import EconomyState
from server.sim.quests.quest_gen import BOUNTY_GOLD_BY_TIER
from server.sim.world import npc_fleets as ec
from server.sim.world import npc_intel as intel
from server.sim.world import raster as raster_module

NATIONS = ("portugal", "spain", "england", "holland", "ottoman", "italy")

#: Open water in the variables band, far from every harbor / lane tile
#: (the oracle's OPEN_CELL).
OPEN_CELL = (1400, 640)


# --- Fixtures ---------------------------------------------------------------


def _new_state(day: int = 10) -> ec.FleetEcologyState:
    return ec.FleetEcologyState(
        day=day,
        world={
            "position": {"x": OPEN_CELL[0], "y": OPEN_CELL[1]},
            "clock_fraction": 0.0,
            "map_id": "world",
            "weather": "fair",
            "wind_dir": "E",
            "last_departed_port": "",
            "hunter_intel_cell": None,
        },
        reputation={nation: 0 for nation in NATIONS},
    )


def _make_run(preset: str = "normal", day: int = 10, *,
              state: ec.FleetEcologyState | None = None,
              economy: EconomyState | None = None,
              allegiance: AllegianceState | None = None,
              config: dict | None = None) -> ec.NpcFleets:
    """A livable run with the ecology emptied; sections seed their fleets."""
    store = data()
    run_state = state if state is not None else _new_state(day)
    run_state.day = day
    run_econ = economy if economy is not None else EconomyState(
        market_stocks=economy_lib.build_initial_stocks(
            store.ports_list, store.goods_list),
        day=day)
    run_alg = allegiance if allegiance is not None else AllegianceState()
    if allegiance is None:
        allegiance_lib.seed_new_game(store, run_alg)
    run_config = config if config is not None else {
        "npc_config": store.npc_config, "preset": preset}
    return ec.NpcFleets(run_config, state=run_state, economy=run_econ,
                        allegiance=run_alg, store=store)


def _make_fleet(sim: ec.NpcFleets, role: str, nation_id: str,
                cell: tuple[int, int], seed_value: int = 0) -> dict:
    fleet = {
        "id": "fx_%s_%s_%d" % (role, nation_id, len(sim.state.npc_fleets)),
        "role": role,
        "nation_id": nation_id,
        "cell": {"x": cell[0], "y": cell[1]},
        "route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
        "cargo": {},
        "captain_id": "",
        "cooldown_until_day": 0,
        "seed": seed_value,
        "dest_port_id": "",
        "dwell_until_day": 0,
        "anchor_cell": None,
        "target_fleet_id": "",
        "hunter_state": "",
        "loiter_until_day": 0,
        "home_port_id": "",
    }
    if seed_value == 0:
        fleet["seed"] = ec.godot_string_hash(fleet["id"]) % 100000000
    sim.state.npc_fleets.append(fleet)
    sim.reset_index()
    return fleet


def _stationary(fleet: dict, day: int, days: int = 60) -> dict:
    fleet["dwell_until_day"] = day + days
    return fleet


def _tick(sim: ec.NpcFleets, day: int) -> list[dict]:
    sim.state.day = day
    sim.economy.day = day
    return sim.tick(day)


def _lane_route(fleet: dict, lane_id: str = "west_indies_flota") -> dict:
    fleet["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
                      "legs": []}
    return fleet


# --- 1. Budgets & caps (docs/60-* §4.1.1, §4.1.2; 10-* §4.10) --------------


def test_budget_closed_forms():
    sim = _make_run()
    assert sim.multiplier() == 1.0
    # The §4.1.1 column re-derived over the shipped data: 105 sovereign
    # ports across 6 nations + the 45-neutral tier.
    want = {"trader": 134, "coaster": 81, "patrol": 20, "courier": 12,
            "privateer": 12}
    for role, total in want.items():
        assert sum(sim.budget_for(role, nation) for nation in NATIONS) == total
    assert sim.neutral_port_count() == 45
    assert sim.budget_for(ec.COASTER, "") == 34          # ceil(45 × 0.75)
    assert sim.budget_for(ec.PIRATE, "") == 25           # the 25-core share
    assert sim.budget_for(ec.HUNTER, "spain") == 0
    sim.state.reputation["spain"] = -50
    assert sim.budget_for(ec.HUNTER, "spain") == 1
    # Cap arithmetic (§4.1.1 / §4.1.2): 134+81+20+12+12+34+25 = 318 core,
    # +16 slack = 334 global, trickle max(4, ceil(334/50)) = 7.
    assert sim.core_cap() == 318
    assert sim.global_cap() == 334
    assert sim.trickle_per_day() == 7

    deserted = _make_run("deserted")
    assert deserted.is_deserted()
    assert deserted.budget_for(ec.TRADER, "portugal") == 0
    assert deserted.core_cap() == 0
    assert deserted.trickle_per_day() == 0

    extreme = _make_run("extreme")
    # ceil-per-role at the multiplied demand: 20 ports × 1.25 × 4.
    assert extreme.budget_for(ec.TRADER, "portugal") == math.ceil(20 * 1.25 * 4)
    assert extreme.global_cap() <= 2048
    # Unknown preset falls back to the default id.
    assert (ec.NpcFleets({"npc_config": data().npc_config, "preset": "low"},
                         store=data()).set_preset("bogus")) == "normal"


def test_small_preset_quota_closed_forms_and_absolute_cap():
    """The per-role ``ceil`` formulas at a genuinely small preset + the
    ``absolute_cap`` refusal (no invented numbers — the pinned formulas)."""
    store = data()
    small = {
        "version": 1,
        "presets": {"deserted": 0.0, "low": 0.5, "normal": 1.0,
                    "high": 2.0, "extreme": 4.0},
        "default_preset": "normal",
        "budgets": {
            "traders_mult_per_port": 0.1, "coasters_mult_per_port": 0.1,
            "patrols_div_ports": 10, "patrols_min": 1,
            "couriers_per_nation": 1, "privateers_per_rivalry": 1,
            "pirate_base": 1, "pirates_per_unpatrolled_zone": 0,
        },
        "flow": {"spawns_per_day_base": 2, "path_budget_ms_per_day": 250,
                 "trade_units_per_port_call": 30, "coaster_trade_units": 5},
        "absolute_cap": 5,
    }
    sim = _make_run(config={"npc_config": small, "preset": "normal"})
    # portugal owns 20 ports: trader ceil(20 × 0.1) = 2, coaster 2,
    # patrol max(1, ceil(20/10)) = 2, courier 1, privateer 1 (rivalry pair),
    # pirate min(25, ceil(1 + 0 zones)) = 1.
    assert sim.budget_for(ec.TRADER, "portugal") == 2
    assert sim.budget_for(ec.COASTER, "portugal") == 2
    assert sim.budget_for(ec.PATROL, "portugal") == 2
    assert sim.budget_for(ec.COURIER, "portugal") == 1
    assert sim.budget_for(ec.PRIVATEER, "portugal") == 1
    assert sim.budget_for(ec.PIRATE, "") == 1
    # The neutral coaster tier has its own 0.75 data line (default).
    assert sim.budget_for(ec.COASTER, "") == math.ceil(45 * 0.75)
    # low (×0.5): ceil(20 × 0.1 × 0.5) = 1; the patrol floor stays 1.
    sim.set_preset("low")
    assert sim.budget_for(ec.TRADER, "portugal") == 1
    assert sim.budget_for(ec.PATROL, "portugal") == 1
    assert sim.budget_for(ec.COURIER, "portugal") == 1  # ceil(1 × 0.5)
    # Absolute cap: the fifth live fleet blocks the sixth spawn.
    sim.set_preset("normal")
    while len(sim.state.npc_fleets) < 5 and sim.spawn(
            ec.TRADER, "portugal", sim.state.day):
        pass
    assert len(sim.state.npc_fleets) == 5
    assert sim.spawn(ec.TRADER, "portugal", sim.state.day) == {}


def test_treasure_schedule_closed_form():
    # §4.11.11.4: 45 + 15 × nation_index (65-* nations.json order), mod 90.
    for index, nation in enumerate(NATIONS):
        first = 45 + 15 * index
        assert ec.treasure_due(nation, first)
        assert ec.treasure_due(nation, first + 90)
        assert not ec.treasure_due(nation, first + 1)
        assert not ec.treasure_due(nation, first - 90)
    assert not ec.treasure_due("atlantis", 45)


# --- 2. Initial fill, determinism & the docking replay ----------------------


def test_initial_fill_determinism_and_docking_replay():
    sim = _make_run(day=1)
    stocks_before = copy.deepcopy(sim.economy.market_stocks)
    sim.initial_fill(1)
    fleets = sim.state.npc_fleets
    counts: dict[str, int] = {}
    for fleet in fleets:
        counts[fleet["role"]] = counts.get(fleet["role"], 0) + 1
    # The half-cap fill is role-major with integer halves per owner:
    # trader 65 + coaster (17 grey + 39 national) 56 + patrol 9 + courier 6
    # + privateer 6 + pirate 12 = 154 of the 318 core.
    assert len(fleets) == 154
    assert counts == {"trader": 65, "coaster": 56, "patrol": 9,
                      "courier": 6, "privateer": 6, "pirate": 12}
    grey = [f for f in fleets if f["role"] == "coaster"
            and f["nation_id"] == ""]
    assert len(grey) == 17
    # Every fleet has a unique id + captain id (deployment exclusivity).
    ids = [f["id"] for f in fleets]
    assert len(set(ids)) == len(ids)
    captains = [f["captain_id"] for f in fleets]
    assert all(captains) and len(set(captains)) == len(captains)
    # The fill never moves stocks (docs/30 §4.2 rest at new_game).
    assert sim.economy.market_stocks == stocks_before

    # Same seed ⇒ identical ids, cells and route legs on a fresh run.
    replay = _make_run(day=1)
    replay.initial_fill(1)
    again = replay.state.npc_fleets
    assert len(again) == len(fleets)
    for first, second in zip(fleets, again):
        assert first["id"] == second["id"]
        assert first["cell"] == second["cell"]
        assert first["route"] == second["route"]

    # Same seed ⇒ the same docking sequence incl. the grey coasters.
    def dock_log() -> list:
        run = _make_run(day=1)
        run.initial_fill(1)
        for day in range(2, 9):
            _tick(run, day)
        return copy.deepcopy(run.state.npc_port_log)

    log_a = dock_log()
    log_b = dock_log()
    assert len(log_a) > 20
    assert log_a == log_b

    # Deserted fills nothing.
    empty = _make_run("deserted", day=1)
    empty.initial_fill(1)
    assert empty.state.npc_fleets == []


# --- 3. Preset semantics: raise trickle, lower never culls ------------------


def test_preset_raise_trickle_and_no_cull():
    sim = _make_run("normal", day=2)
    sim.initial_fill(2)
    before = [f["id"] for f in sim.state.npc_fleets]
    assert len(before) == 154

    # Lower (normal → low): living fleets are never culled. Coasters are
    # ignored by raiders and couriers are not prey, so they are the
    # population that MUST survive the window (the oracle's no-cull pins).
    keep = [_make_fleet(sim, "coaster", "portugal", (OPEN_CELL[0] + 30, 300)),
            _make_fleet(sim, "courier", "spain", (OPEN_CELL[0] + 32, 300))]
    sim.set_preset("low")
    assert sim.multiplier() == 0.5
    at_low = len(sim.state.npc_fleets)
    for day in range(3, 8):
        _tick(sim, day)
    alive = {f["id"] for f in sim.state.npc_fleets}
    assert all(fleet["id"] in alive for fleet in keep)
    after_low = len(sim.state.npc_fleets)
    assert after_low <= at_low + 25

    # Raise (low → high): the daily trickle refills toward the new budgets.
    sim.set_preset("high")
    assert sim.multiplier() == 2.0
    assert sim.trickle_per_day() >= 4
    for day in range(8, 13):
        _tick(sim, day)
    assert len(sim.state.npc_fleets) >= at_low + 30

    # Deserted freezes the ecology (no spawns, no removals) and silences
    # every contact beside a live hostile fleet.
    sim.set_preset("deserted")
    _make_fleet(sim, "pirate", "", (OPEN_CELL[0] + 1, OPEN_CELL[1]))
    sim.reset_index()
    pre = [f["id"] for f in sim.state.npc_fleets]
    for day in range(13, 16):
        assert _tick(sim, day) == []
    assert [f["id"] for f in sim.state.npc_fleets] == pre
    assert sim.contacts(OPEN_CELL) == []
    assert sim.nearest_contact(OPEN_CELL) == {}


# --- 4. Lane routing over the built artifact (60-* §4.11.11.1) --------------


def test_lane_routing_pins():
    sim = _make_run()
    route = sim.route_between("lisbon", "seville")
    assert route
    assert route == sim.route_between("lisbon", "seville")
    # The graph is undirected in tile length (the oracle's pin: 84 tiles).
    assert route["length"] == 84
    assert sim.route_between("seville", "lisbon")["length"] == 84
    legs = route["legs_save"]["legs"]
    assert legs
    # The routed tile path is step-connected and never touches land.
    path = route["path"]
    for index in range(1, len(path)):
        a, b = path[index - 1], path[index]
        dx = abs(a[0] - b[0])
        dy = abs(a[1] - b[1])
        assert max(min(dx, 4320 - dx), dy) <= 1
    assert all(sim.world_source.is_passable(x, y) for x, y in path)
    # The Phase-6 sweep joined the network: every nation reaches its lanes.
    for nation in NATIONS:
        assert sim.nation_lanes(nation)
    assert sim.route_between("lisbon", "london")
    assert sim.route_between("lisbon", "lisbon") == {}


# --- 5. The wrap-aware cell-bucket index (60-* §4.11.11.5) ------------------


def test_spatial_index_wraps_and_occupancy():
    sim = _make_run()
    seam_west = _make_fleet(sim, "trader", "portugal", (4318, 300))
    seam_east = _make_fleet(sim, "trader", "portugal", (2, 300))
    far = _make_fleet(sim, "trader", "portugal", (1000, 300))
    got = {f["id"] for f in sim.within((0, 300), 4)}
    assert seam_west["id"] in got and seam_east["id"] in got
    assert far["id"] not in got
    assert ec.chebyshev((4318, 300), (2, 300)) == 4
    # Occupancy is a spawn preference: a docked fleet's tile never blocks.
    assert sim._is_occupied((2, 300), "")
    assert not sim._is_occupied((2, 300), seam_east["id"])
    seam_east["dwell_until_day"] = 99
    assert not sim._is_occupied((2, 300), "")
    # Fleet-at is the exact-cell read.
    assert sim.fleet_at((2, 300))["id"] == seam_east["id"]
    assert sim.fleet_at((3, 300)) == {}


# --- 6. Unified movement: exact lane-tile progression -----------------------


def test_lane_stepping_exact_tiles():
    sim = _make_run(day=10)
    sim._refresh_net()
    lane_id = "west_indies_flota"
    path = ec._NET.lane_paths[lane_id]
    # A one-hull latin fleet: base 16 (latin.speed), no captain jitter.
    fleet = _make_fleet(sim, "trader", "portugal", path[0])
    fleet["ships"] = [ec._base_ship("latin", data())]
    fleet["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
                      "legs": [{"kind": "lane", "id": lane_id,
                                "reverse": False, "a": 0,
                                "b": len(path) - 1}]}
    fleet["dest_port_id"] = ""
    fleet["dwell_until_day"] = 0
    sim._leg_active.pop(fleet["id"], None)
    sim.advance_clock()          # clock sync (a fresh sim catches nothing up)

    # First-day closed form: floor(base × wind × direction × current).
    sim.state.day = 11
    heading = sim._lane_step_heading(fleet)
    cell = ec.position_of(fleet)
    month = ec.month_for(11)
    base, ship_class = sim._fleet_base(fleet)
    pipe = base * ec.wind_factor("fair", ship_class) \
        * ec.npc_direction_factor(heading, cell, month, ship_class) \
        * ec.npc_current_factor(heading, cell, month)
    assert int(math.floor(pipe)) == 18
    # Golden per-day progression (the oracle's exact accrual call order,
    # incl. the telemetry `_lane_tiles_today` bank — npc_fleets.gd L1157).
    expected = {11: 18, 12: 37, 13: 55}
    for day in (11, 12, 13):
        sim.state.day = day
        sim.advance_clock()
        assert fleet["route"]["tile_index"] == expected[day]
        assert ec.position_of(fleet) == path[expected[day]]
    committed = expected[13]
    assert 0 < committed < len(path) - 1
    # The accrual is reported for the renderer (stepwise glide).
    moves = sim.take_fleet_moves()
    assert moves and moves[0]["id"] == fleet["id"]
    assert moves[0]["to"] == path[18]
    assert moves[-1]["to"] == path[committed]


def test_month_variant_selection_and_endpoint_flip():
    sim = _make_run()
    sim._refresh_net()
    lane_id = "hanseatic_north"
    base = ec._NET.lane_paths[lane_id]
    variant = ec._NET.lane_variants[lane_id][0]
    # The in-month selection rule: only months 12/1/2/3 pick the winter run.
    assert sim._active_lane_variant(lane_id, 12)["id"] \
        == "hanseatic_north_winter"
    assert sim._active_lane_variant(lane_id, 7) == {}

    # Endpoint identity (the 2026-11-02 amendment): a leg whose walked ends
    # both sit on the variant rides it; everything else keeps the base.
    shared = [tile for tile in base if tile in variant["path"]]
    assert shared
    a = base.index(shared[0])
    b = base.index(shared[-1])
    leg = {"kind": "lane", "id": lane_id, "reverse": False, "a": a, "b": b}

    sim.state.day = 200  # month 7 — base geometry
    sim._geo_cache_day = -1
    base_geo = sim._leg_geometry(leg)
    assert base_geo["key"] == "lane:hanseatic_north|"
    assert base_geo["path"] is base

    sim.state.day = 341  # month 12 — the Bergenfahrer winter run
    sim._geo_cache_day = -1
    winter = sim._leg_geometry(leg)
    assert winter["key"] == "lane:hanseatic_north|hanseatic_north_winter"
    assert winter["path"] is variant["path"]
    assert winter["walked_len"] == winter["end"] - winter["start"] + 1

    # Progress remaps by fraction on the identity flip (task-H pin 4), and
    # the fleet is re-seated on the remapped tile (no straight-line jump).
    fleet = _make_fleet(sim, "trader", "portugal", base[a])
    fleet["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
                      "legs": [dict(leg)]}
    sim.state.day = 200
    sim._geo_cache_day = -1
    sim._leg_active.pop(fleet["id"], None)
    sim._sync_route_progress(fleet)
    base_len = base_geo["walked_len"]
    fleet["route"]["tile_index"] = (base_len - 1) // 2
    sim.state.day = 341
    sim._geo_cache_day = -1
    index = sim._leg_progress(fleet, fleet["route"], winter)
    expected = ec._roundi_half_away(
        ((base_len - 1) // 2) / float(base_len - 1)
        * float(winter["walked_len"] - 1))
    assert index == expected
    assert ec.position_of(fleet) == \
        winter["path"][winter["start"] + index]


# --- 7. Convoys (60-* §4.11.11.4) -------------------------------------------


def test_convoy_grouping():
    sim = _make_run(day=20)
    trader = _make_fleet(sim, "trader", "portugal", (OPEN_CELL[0], OPEN_CELL[1]))
    partner = _make_fleet(sim, "trader", "spain",
                          (OPEN_CELL[0] + 3, OPEN_CELL[1]))
    _lane_route(trader)
    _lane_route(partner)
    members = sim.convoy_members(trader)
    assert len(members) == 2 and trader in members and partner in members
    assert sim.is_convoyed(trader) and sim.is_convoyed(partner)
    leaders = sim._convoy_leaders()
    leader = min(trader["id"], partner["id"])
    assert leaders[leader] == leader
    assert leaders[leader + "#count"] == 2
    marker = next(m for m in sim.markers() if m["id"] == leader)
    assert marker["convoy_count"] == 2
    # Different lane or beyond Chebyshev 3 is no convoy.
    _lane_route(partner, "venice_flanders")
    assert not sim.is_convoyed(trader)
    _lane_route(partner)
    partner["cell"] = {"x": OPEN_CELL[0] + 5, "y": OPEN_CELL[1]}
    sim.reset_index()
    assert not sim.is_convoyed(trader)


# --- 8. Wrecks: spawn, contents, expiry, collect (60-* §4.11.11.2) ----------


def test_wreck_lifecycle_and_collect():
    sim = _make_run(day=20)
    raider = _make_fleet(sim, "pirate", "", OPEN_CELL, 777)
    trader = _make_fleet(sim, "trader", "portugal",
                         (OPEN_CELL[0] + 1, OPEN_CELL[1]))
    trader["cargo"] = {"wool": 14, "wine": 8}
    doomed: dict = {}
    remove_ids: list = []
    wrecks: list = []
    sim._engage(raider, trader, 20, doomed, remove_ids, wrecks)
    assert len(wrecks) == 1 and trader["id"] in remove_ids
    wreck = wrecks[0]
    assert wreck["id"].startswith("wk_")
    assert ec.position_of(wreck) == ec.position_of(trader)
    assert wreck["cargo"] == {"wool": 14, "wine": 8}
    assert wreck["salvage_gold"] == 0
    assert wreck["spawn_day"] == 20
    assert raider["target_fleet_id"] == ""

    # A warship wreck pays the single salvage implementation over its hulls.
    patrol = _make_fleet(sim, "patrol", "portugal",
                         (OPEN_CELL[0] + 2, OPEN_CELL[1]), 31337)
    pirate_loser = _make_fleet(sim, "pirate", "",
                              (OPEN_CELL[0] + 2, OPEN_CELL[1] + 1), 777)
    doomed, remove_ids, wrecks = {}, [], []
    sim._engage(pirate_loser, patrol, 20, doomed, remove_ids, wrecks)
    assert pirate_loser["id"] in remove_ids
    hulls = [s["ship_type_id"] for s in sim._fleet_ships(pirate_loser)]
    assert wrecks[0]["salvage_gold"] == ec.salvage_for(hulls, data())
    assert wrecks[0]["cargo"] == {}

    # Expiry: alive through spawn_day+4, gone from spawn_day+5's tick.
    sim.state.wrecks = [copy.deepcopy(wreck)]
    sim.state.npc_fleets = []
    sim.reset_index()
    sim.last_tick_day = -1
    _tick(sim, 24)
    assert sim.wrecks() and sim.wrecks()[0]["id"] == wreck["id"]
    sim.last_tick_day = -1
    _tick(sim, 25)
    assert sim.wrecks() == []

    # Collect-on-entry: cargo up to free capacity (id-ascending) + gold.
    gold_wreck = {"id": "wk_x", "cell": {"x": 1, "y": 1},
                  "cargo": {"wine": 8, "wool": 14},
                  "salvage_gold": 125, "spawn_day": 25}
    sim.state.wrecks = [gold_wreck]
    result = sim.collect_wreck("wk_x", 10)
    # Cargo id-ascending up to free capacity: wine 8, then 2 of the wool.
    assert result["cargo"] == {"wine": 8, "wool": 2}
    assert result["leftover"] == 12
    assert result["gold"] == 125
    assert sim.wrecks() == []
    assert sim.collect_wreck("wk_x", 10) == {}


# --- 9. Contact rules & the S10 encounter descriptor ------------------------


def test_contact_rules_and_encounter_descriptor():
    sim = _make_run(day=20)
    pirate = _make_fleet(sim, "pirate", "",
                         (OPEN_CELL[0] + 1, OPEN_CELL[1]))
    contact = sim.nearest_contact(OPEN_CELL)
    assert contact and contact["id"] == pirate["id"]
    encounter = sim.attack_encounter(contact)
    assert encounter["kind"] == "pirate"
    assert encounter["encounter_id"] == pirate["id"]
    assert encounter["contact"] == {"x": OPEN_CELL[0], "y": OPEN_CELL[1]}
    assert encounter["weather"] == "fair"
    assert encounter["wind_dir"] == "E"
    assert set(encounter["current"]) == {"dir", "strength"}
    assert encounter["ships"]

    # One descriptor per hostile kind; hunter battles keep kind = "navy".
    for role, nation, kind, rep in (
            ("privateer", "spain", "privateer", 0),
            ("hunter", "spain", "navy", -60)):
        sim.state.npc_fleets = []
        sim.reset_index()
        sim.state.reputation["spain"] = rep
        fleet = _make_fleet(sim, role, nation,
                            (OPEN_CELL[0] + 1, OPEN_CELL[1]))
        got = sim.contact_encounter(OPEN_CELL)
        assert got["kind"] == kind
        assert got["encounter_id"] == fleet["id"]
    sim.state.reputation["spain"] = 0

    # Traders/patrols sail past; a hunter needs a bounty.
    for role, nation, rep in (("trader", "portugal", 0),
                              ("patrol", "portugal", 0),
                              ("hunter", "spain", 0)):
        sim.state.npc_fleets = []
        sim.reset_index()
        sim.state.reputation["spain"] = rep
        _make_fleet(sim, role, nation, (OPEN_CELL[0] + 1, OPEN_CELL[1]))
        assert sim.nearest_contact(OPEN_CELL) == {}
    sim.state.reputation["spain"] = 0

    # The inclusive pursuit cooldown suppresses contact.
    sim.state.npc_fleets = []
    sim.reset_index()
    cooled = _make_fleet(sim, "pirate", "",
                         (OPEN_CELL[0] + 1, OPEN_CELL[1]))
    sim.set_pursuit_cooldown(cooled["id"], sim.state.day + 1)
    assert sim.nearest_contact(OPEN_CELL) == {}
    assert sim.fleet_at((OPEN_CELL[0] + 1, OPEN_CELL[1]))
    sim.set_pursuit_cooldown(cooled["id"], sim.state.day - 1)
    assert sim.nearest_contact(OPEN_CELL)
    assert sim.contact_encounter(OPEN_CELL)["encounter_id"] == cooled["id"]


def test_hunter_intel_state_machine():
    """§4.11.11.1 hunter intel: lane travel to the intel port, the 30/40
    chase hysteresis, the 10-day loiter and the bounty-only despawn."""
    sim = _make_run(day=20)
    lisbon = raster_module.raster().port_cell("lisbon")
    seville = raster_module.raster().port_cell("seville")
    sim.state.world["last_departed_port"] = "seville"
    hunter = _make_fleet(sim, "hunter", "", lisbon)
    hunter["hunter_state"] = ec.HUNTER_STATE_INTEL
    hunter["home_port_id"] = "lisbon"
    hunter["dest_port_id"] = ""
    hunter["dwell_until_day"] = 0
    sim.reset_index()
    # En route: a new intel port re-targets the under-way hunter (zero A*).
    _tick(sim, 21)
    assert hunter["hunter_state"] == ec.HUNTER_STATE_INTEL
    assert hunter["dest_port_id"] == "seville"
    assert hunter["route"]["legs"]

    # Chase trigger: the player within Chebyshev 30 opens direct pursuit.
    hunter["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
    hunter["cell"] = {"x": OPEN_CELL[0] + 5, "y": OPEN_CELL[1]}
    sim.reset_index()
    _tick(sim, 22)
    assert hunter["hunter_state"] == ec.HUNTER_STATE_CHASE

    # Losing the player beyond Chebyshev 40 returns it to the lane network.
    sim.state.world["position"] = {"x": OPEN_CELL[0] + 200,
                                   "y": OPEN_CELL[1] + 200}
    _tick(sim, 23)
    assert hunter["hunter_state"] == ec.HUNTER_STATE_INTEL
    assert hunter["dest_port_id"] == "seville"

    # Arrived at the intel port: camp its approaches for 10 days.
    hunter["cell"] = {"x": seville[0], "y": seville[1]}
    hunter["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
    hunter["dest_port_id"] = "seville"
    hunter["hunter_state"] = ec.HUNTER_STATE_INTEL
    hunter["dwell_until_day"] = 0
    sim.reset_index()
    _tick(sim, 24)
    assert hunter["hunter_state"] == ec.HUNTER_STATE_LOITER
    assert hunter["loiter_until_day"] == 24 + ec.HUNTER_LOITER_DAYS
    assert ec.chebyshev(ec.position_of(hunter), seville) <= 1

    # A national hunter despawns when its bounty no longer stands (the
    # nationless nemesis hunter persists).
    sim.state.npc_fleets = []
    sim.reset_index()
    national = _make_fleet(sim, "hunter", "spain", lisbon)
    national["hunter_state"] = ec.HUNTER_STATE_INTEL
    sim.reset_index()
    sim.state.reputation["spain"] = 0
    _tick(sim, 25)
    assert sim._find(national["id"]) == {}
    nemesis = _make_fleet(sim, "hunter", "", lisbon)
    nemesis["hunter_state"] = ec.HUNTER_STATE_INTEL
    sim.reset_index()
    _tick(sim, 26)
    assert sim._find(nemesis["id"]) is nemesis


# --- 10. Spawn immunity day math + the kind→role map (60-* §4.8; 90-* §8.1) -


def test_spawn_immunity_and_kind_map():
    state = _new_state(day=20)
    assert ec.spawn_allowed(state, "pirate", 1)   # absent → allowed
    assert ec.note_spawn_immunity(state, "pirate", 20) == 23
    assert state.proximity_cooldowns["pirate"] == 23
    assert not ec.spawn_allowed(state, "pirate", 22)
    assert ec.spawn_allowed(state, "pirate", 23)
    assert ec.kind_role("pirate") == ec.PIRATE
    assert ec.kind_role("navy") == ec.HUNTER
    assert ec.kind_role("hunter") == "hunter"     # not a retired kind


# --- 11. Seeded auto-resolve & the deterministic rows -----------------------


def test_seeded_auto_resolve_and_rows():
    sim = _make_run(day=20)
    trader = _make_fleet(sim, "trader", "portugal",
                         (OPEN_CELL[0], OPEN_CELL[1]))
    # Determinism: the same (seed, prey, day) triple resolves identically.
    raider = _make_fleet(sim, "pirate", "", (OPEN_CELL[0] + 3, OPEN_CELL[1]),
                         424242)
    first = sim.resolve_engagement(raider, trader, 20)
    assert all(sim.resolve_engagement(raider, trader, 20) == first
               for _ in range(5))

    # The pinned 60% band over the oracle's 200 seeded trials (±0.12).
    wins = 0
    for index in range(200):
        seed_raider = _make_fleet(
            sim, "pirate", "", (OPEN_CELL[0] + 50 + index, OPEN_CELL[1]),
            9000 + index * 7919)
        if sim.resolve_engagement(seed_raider, trader, 20):
            wins += 1
    assert 0.48 <= wins / 200.0 <= 0.72

    # Raider vs patrol / escorted trader / convoy always loses.
    sim.state.npc_fleets = [trader]
    sim.reset_index()
    patrol = _make_fleet(sim, "patrol", "portugal",
                         (OPEN_CELL[0] + 1, OPEN_CELL[1]))
    for index in range(25):
        raider["seed"] = 500 + index * 104729
        assert not sim.resolve_engagement(raider, patrol, 20)
    sim.state.npc_fleets = [trader, patrol]
    sim.reset_index()
    escort = _make_fleet(sim, "patrol", "portugal",
                         (OPEN_CELL[0] + 5, OPEN_CELL[1] + 5))
    sim.state.npc_fleets = [trader, escort]
    sim.reset_index()
    assert sim.is_escorted(trader)
    for index in range(25):
        raider["seed"] = 500 + index * 104729
        assert not sim.resolve_engagement(raider, trader, 20)
    escort["nation_id"] = "ottoman"
    assert not sim.is_escorted(trader)
    escort["nation_id"] = "portugal"
    escort["cell"] = {"x": OPEN_CELL[0] + 22, "y": OPEN_CELL[1]}
    sim.reset_index()
    assert not sim.is_escorted(trader)

    # A privateer preys only on its sponsor's rivals; raiders never prey on
    # raiders, hunters or coasters (§4.1.1).
    sim.state.npc_fleets = []
    sim.reset_index()
    privateer = _make_fleet(sim, "privateer", "spain",
                            (OPEN_CELL[0], OPEN_CELL[1]))
    rival_trader = _make_fleet(sim, "trader", "portugal",
                              (OPEN_CELL[0] + 2, OPEN_CELL[1]))
    _make_fleet(sim, "pirate", "", (OPEN_CELL[0] + 3, OPEN_CELL[1]))
    _make_fleet(sim, "coaster", "portugal", (OPEN_CELL[0] + 1, OPEN_CELL[1] + 1))
    prey = sim.prey_candidates(privateer)
    assert [f["id"] for f in prey] == [rival_trader["id"]]


# --- 12. Golden captain/specialty/composition draws (RNG call order) --------


def test_captain_specialty_and_composition_golden():
    sim = _make_run()
    fleet = {"id": "fx_trader_portugal_0", "role": "trader",
             "nation_id": "portugal", "seed": 424242,
             "cell": {"x": OPEN_CELL[0], "y": OPEN_CELL[1]},
             "captain_id": ""}
    sim._draw_captain(fleet)
    # The canon draw from the fleet's "captain" purpose stream (pinned).
    assert fleet["captain_id"] == "cap_trader_0433"
    # The specialty draw from seed*31 + hash("specialty").
    assert sim._draw_specialty("portugal", 424242) == "rice"
    # The composition keys off the fleet seed only (day changes cannons only).
    ships = ec.compose_fleet_ships(fleet, 20, data())
    assert [s["ship_type_id"] for s in ships] == ["sloop", "latin"]
    assert [s["cargo"] for s in ships] == [{"silk": 6}, {"salt": 3}]
    # The ±10% captain speed jitter is the stable hash quantization.
    bucket = ec.godot_string_hash("cap_trader_0433") % 201
    expected = 16.0 * (1.0 + ((bucket - 100) / 100.0) * 0.10)
    assert sim._fleet_base(dict(fleet))[0] == pytest.approx(expected)


# --- 13. NPC trade moves the real stock table (30-* §4.4; 60-* §4.11.14) ---


def test_npc_trade_moves_stock_and_credits_tax():
    sim = _make_run(day=20)
    port_id = "lisbon"
    good = next(good for good in data().goods_list
                if economy_lib.stock_of(sim.economy, data(), port_id,
                                        str(good.get("id", ""))) < 100)
    good_id = str(good["id"])
    stock_before = economy_lib.stock_of(sim.economy, data(), port_id, good_id)
    fleet = _make_fleet(sim, "trader", "portugal",
                        raster_module.raster().port_cell(port_id))
    fleet["cargo"] = {good_id: 5}
    treasury_before = int(sim._allegiance.treasuries.get("portugal", 0))
    sold = sim._sell_cargo(fleet, port_id, 0)
    assert sold == 5
    assert economy_lib.stock_of(
        sim.economy, data(), port_id, good_id) == stock_before + 5
    assert port_id in sim.moved_ports
    # The unified tariff reaches the host treasury (NPC-sourced, capped).
    assert int(sim._allegiance.treasuries.get("portugal", 0)) \
        > treasury_before
    # Selling into factor ≤ 1.0 is refused (the stock stays put).
    saturated = next(good for good in data().goods_list
                     if economy_lib.stock_of(
                         sim.economy, data(), port_id,
                         str(good.get("id", ""))) >= 100)
    fleet["cargo"] = {str(saturated["id"]): 3}
    assert sim._sell_cargo(fleet, port_id, 0) == 0


# --- 14. Markers & stall diagnostics (60-* §4.12.x) -------------------------


def test_markers_and_stall_diagnostics():
    sim = _make_run(day=20)
    fleet = _make_fleet(sim, "trader", "portugal",
                        raster_module.raster().port_cell("lisbon"))
    fleet["dwell_until_day"] = 22
    marker = next(m for m in sim.markers() if m["id"] == fleet["id"])
    assert marker["role"] == "trader"
    assert marker["letter"] == "T"
    assert marker["sailing"] is False
    assert marker["dwell"] == 22
    assert marker["stall"] == "docked"
    assert marker["on_berth"] is True
    assert sim.stall_state(fleet, 0) == "docked"
    fleet["dwell_until_day"] = 0
    assert sim.stall_state(fleet, 0) == "sailing"
    # A raider camping off-lane inside its anchor radius reports camping.
    pirate = _make_fleet(sim, "pirate", "", (OPEN_CELL[0], OPEN_CELL[1]))
    pirate["anchor_cell"] = {"x": OPEN_CELL[0] + 2, "y": OPEN_CELL[1]}
    if not sim._is_path_tile(ec.position_of(pirate)):
        assert sim.stall_state(pirate, 0) == "camping"
    pirate["target_fleet_id"] = "someone"
    assert sim.stall_state(pirate, 0) == "chasing"
    pirate["target_fleet_id"] = ""
    assert sim.stall_state(fleet, ec.STALL_HOLD_TICKS) == "blocked" \
        or not fleet.get("route", {}).get("legs")


# --- 15. Intel: sightings, posters, reveal (80-* §4.7.8) --------------------


def test_intel_sightings_and_gone_ashore():
    sim = _make_run(day=20)
    port_id = "lisbon"
    berth = raster_module.raster().port_cell(port_id)
    trader_cards = [str(card["id"]) for card in data().captains_list
                    if card.get("role") == "trader"][:6]
    for index in range(6):
        fleet = _make_fleet(sim, "trader", "portugal",
                            (berth[0], berth[1]))
        fleet["id"] = "dock_%02d" % index
        fleet["captain_id"] = trader_cards[index]
        fleet["dwell_until_day"] = 24
    sim.reset_index()
    docked = intel.docked_fleets(sim, port_id)
    assert len(docked) == 6
    present = [f for f in docked if intel.is_present(f, port_id)]
    absent = [f for f in docked if not intel.is_present(f, port_id)]
    assert present, "the seeded visit rolls leave at least one captain sighted"
    # Sightings are stable within the visit day and partitioned by facility.
    seen: list[str] = []
    for facility in (intel.FACILITY_MARKET, intel.FACILITY_TAVERN,
                     intel.FACILITY_INN):
        rows = intel.sightings(sim, port_id, facility)
        again = intel.sightings(sim, port_id, facility)
        assert [r["id"] for r in rows] == [r["id"] for r in again]
        seen.extend(r["id"] for r in rows)
        for row in rows:
            assert row["captain_id"]
            assert row["role"] == "trader"
    assert sorted(seen) == sorted(f["id"] for f in present)
    assert sorted(r["id"] for r in intel.gone_ashore(sim, port_id)) \
        == sorted(f["id"] for f in absent)
    # A hunter is palace-only.
    hunter = _make_fleet(sim, "hunter", "spain", (berth[0], berth[1]))
    hunter["id"] = "dock_hunter"
    hunter["dwell_until_day"] = 24
    sim.reset_index()
    assert intel.facility_of(hunter, port_id) == intel.FACILITY_PALACE


def test_intel_posters_reveal_and_rumors():
    sim = _make_run(day=20)
    port_id = "lisbon"
    berth = raster_module.raster().port_cell(port_id)
    # An at-sea pirate within Chebyshev 40, carrying a known canon card.
    pirate_cards = [card for card in data().captains_list
                    if card.get("role") == "pirate"]
    card = pirate_cards[0]
    cell = next(((berth[0] + dx, berth[1] + dy)
                 for dy in range(0, 6) for dx in range(0, 6)
                 if sim.world_source.is_passable(berth[0] + dx, berth[1] + dy)
                 and (berth[0] + dx, berth[1] + dy) != berth),
                None)
    assert cell is not None
    pirate = _make_fleet(sim, "pirate", "", cell, 99)
    pirate["captain_id"] = card["id"]
    sim.reset_index()
    posters = intel.wanted_posters(sim, port_id)
    assert [row["id"] for row in posters] == [pirate["id"]]
    row = posters[0]
    assert row["captain_id"] == card["id"]
    assert row["tier"] == int(card.get("tier", 1))
    assert row["reward_gold"] == int(
        BOUNTY_GOLD_BY_TIER.get(int(card.get("tier", 1)), 5000))
    assert row["cell"] == cell
    assert row["nearest_port"] == port_id
    # The paid reveal returns the exact live position; unknown ids are {}.
    reveal = intel.reveal_position(sim, pirate["id"])
    assert reveal["cell"] == cell
    assert reveal["nearest_port"] == port_id
    assert intel.reveal_position(sim, "missing") == {}
    # A docked pirate posts nothing (at-sea posters only).
    pirate["dwell_until_day"] = 24
    sim.reset_index()
    assert intel.wanted_posters(sim, port_id) == []

    # Rumor rows: the port log's last-3-days traffic, then nearby fleets.
    pirate["dwell_until_day"] = 0
    sim.state.npc_port_log.extend([
        {"port_id": port_id, "kind": "departure", "role": "trader",
         "nation_id": "portugal", "fleet_id": "old", "day": 10},
        {"port_id": port_id, "kind": "departure", "role": "trader",
         "nation_id": "portugal", "fleet_id": "gone", "day": 18},
        {"port_id": port_id, "kind": "arrival", "role": "courier",
         "nation_id": "spain", "fleet_id": "came", "day": 19},
        {"port_id": "seville", "kind": "arrival", "role": "trader",
         "nation_id": "spain", "fleet_id": "elsewhere", "day": 19},
    ])
    sim.reset_index()
    rows = intel.rumor_rows(sim, port_id)
    kinds = [row["kind"] for row in rows]
    assert "departed" in kinds and "arrived" in kinds and "fleet" in kinds
    departed = next(row for row in rows if row["kind"] == "departed")
    assert departed["id"] == "gone"
    arrived = next(row for row in rows if row["kind"] == "arrived")
    assert arrived["id"] == "came"
    # The 4-day-old record is outside the 3-day window; the other port's
    # record never leaks across.
    assert all(row.get("id") not in ("old", "elsewhere") for row in rows)
    fleet_rows = [row for row in rows if row["kind"] == "fleet"]
    assert [row["id"] for row in fleet_rows] == [pirate["id"]]
    # Hunter-intel cell queries round-trip the world block.
    assert intel.hunter_intel_port(sim.state) == ""
    assert intel.hunter_intel_cell(sim.state) is None
    sim.state.world["last_departed_port"] = "lisbon"
    _make_fleet(sim, "patrol", "spain", cell)
    sim.state.reputation["spain"] = -60
    sim.reset_index()
    assert sim.note_contacts(cell)
    assert intel.hunter_intel_port(sim.state) == "lisbon"
    assert intel.hunter_intel_cell(sim.state) == cell
    assert intel.hunter_intel_known(sim.state)


def test_intel_investment_telegraphs():
    sim = _make_run(day=20)
    here = "lisbon"                       # band europe_atlantic
    same_band = next(str(port["id"]) for port in data().ports_list
                     if port.get("band") == "europe_atlantic"
                     and port["id"] != here)
    other_band = next(str(port["id"]) for port in data().ports_list
                      if port.get("band") not in ("", "europe_atlantic"))
    sim._allegiance.telegraphs.extend([
        {"nation_id": "spain", "port_id": same_band, "band":
         "europe_atlantic", "amount": 1200, "day": 19},
        {"nation_id": "italy", "port_id": other_band, "band":
         "europe_med", "amount": 900, "day": 19},
    ])
    rows = intel.investment_rows(here, sim._allegiance, sim._person)
    assert [row["port_id"] for row in rows] == [same_band]
    assert rows[0]["kind"] == "investment"
    assert rows[0]["amount"] == 1200
    assert rows[0]["days_left"] == -1        # no day count reported = visible


# --- 16. The pursuit A* family (fleet_path.gd) ------------------------------


def test_unit_and_weighted_pathing():
    raster = raster_module.raster()
    start = OPEN_CELL
    goal = (OPEN_CELL[0] + 20, OPEN_CELL[1] + 20)
    passable = lambda cell: raster.is_passable(cell[0], cell[1])

    # Degenerate cases: same cell, impassable goal, empty map.
    assert ec.find_path(start, start, 4320, 2160, passable) == [start]
    assert ec.find_path(start, (0, 0), 4320, 2160, passable) == []
    assert ec.find_path(start, goal, 0, 0, passable) == []

    path = ec.find_path(start, goal, 4320, 2160, passable)
    assert path and path[0] == start and path[-1] == goal
    for index in range(1, len(path)):
        a, b = path[index - 1], path[index]
        assert max(abs(a[0] - b[0]), abs(a[1] - b[1])) <= 1
        assert passable(b)

    # Weighted: uniform cost stays a valid walk; guard overflow returns [].
    weighted = ec.find_path_weighted(
        start, goal, 4320, 2160, passable, lambda a, b: 1.0)
    assert weighted and weighted[0] == start and weighted[-1] == goal
    for index in range(1, len(weighted)):
        assert passable(weighted[index])
    assert ec.find_path_weighted(
        start, goal, 4320, 2160, passable, lambda a, b: 1.0,
        {"max_expansions": 1}) == []
    # An impassable endpoint is refused before the search.
    assert ec.find_path_weighted(
        start, (0, 0), 4320, 2160, passable, lambda a, b: 1.0) == []
    # The pinned weighted constants (60-* §4.19 / fleet_path.gd).
    assert ec.MAX_EXPANSIONS == 40000
    assert ec.MAX_EXPANSIONS_WEIGHTED == 200000
    assert ec.HEURISTIC_WEIGHT == 2.0
    assert ec.MIN_STEP_FACTOR_BOUND == 1.30 * 1.25


# --- 17. The daily tick runs clean on the real ecology ----------------------


def test_daily_tick_smoke():
    """One fixed-seed integration observation: a fresh fill survives five
    day ticks with every fleet on a legal tile, the port log bounded, and
    the clock accrual actually walking lane fleets."""
    sim = _make_run(day=1)
    sim.initial_fill(1)
    sailing = {f["id"]: ec.position_of(f) for f in sim.state.npc_fleets
               if f.get("route", {}).get("legs")}
    for day in range(2, 7):
        _tick(sim, day)
    assert sim.state.npc_fleets
    for fleet in sim.state.npc_fleets:
        cell = ec.position_of(fleet)
        assert sim.world_source.is_passable(cell[0], cell[1])
        if fleet.get("dwell_until_day", 0) <= sim.state.day:
            assert ec.position_of(fleet) != ec.NO_CELL
    # The day tick's clock catch-up moved at least one lane fleet.
    moved = any(fleet["id"] in sailing
                and ec.position_of(fleet) != sailing[fleet["id"]]
                for fleet in sim.state.npc_fleets)
    assert moved
    assert len(sim.state.npc_port_log) <= ec.PORT_LOG_MAX
