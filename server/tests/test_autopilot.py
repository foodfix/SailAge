"""Parity tests for ``server.sim.world.autopilot`` + ``.discovery`` (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_autopilot.gd`` W5-D, ``tools/
test_discovery.gd`` T10 §5d + the discovery contract) boot scenes and walk
the autoloads; here the same pinned contracts are asserted as pure functions
over injected state on the real shipped ``data/`` tree (loaded through
:mod:`server.sim.data`).

Pinned contracts:

  * autopilot (docs/20-* §4.19, docs/80-* §4.10.4, docs/90-* §5.4): the
    ``sail.autopilot`` gate matrix (no pilot / navigation 39 / 59 / unknown
    destination; the player's own navigation never counts), the save-v9
    ``player.autopilot = {dest_port_id}`` key, the plain §4.2 route for a
    nav-59 pilot (unit-legal, ending on the berth), the route-quality split
    (nav ≥ 70 → weighted), the weighted A* core on a synthetic grid (detour
    for cheap days, determinism, seam wrap, no corner cutting, same-cell /
    impassable-goal / expansion-guard contracts), the interrupt matrix
    (contact and manual cancel; a storm does NOT — auto-reef then restore,
    never overwriting a trim the player changed), the arrival docking
    handoff, the closed-form ETA and the structured HUD payload;
  * discovery (docs/70-* §4.4): the ``36 + floor(cartography / 15)`` radius
    boundary, the pinned seeded Explore scenario (``disc_atlas_cedars`` at
    Chebyshev 18 in range / 37 out), found ≠ reported, the guild report
    payout once ever (cedars: 2000 gold + 150 fame), and the hint half
    delegated to ``server.sim.port.tavern`` (no duplicated implementation).

Deterministic — no Monte Carlo, no engine boots, no RNG in either module
(the oracle's only ``rand*`` call is the tavern hint draw, owned by
``tavern.py``).
"""

from __future__ import annotations

import math

import pytest

from server.sim.data import DataStore
from server.sim.player import PersonState, skills
from server.sim.port import tavern
from server.sim.world import autopilot as ap
from server.sim.world import discovery as disc
from server.sim.world.raster import ocean_layers, raster
from server.sim.world.sail_path import is_step_legal

NATIONS = ["portugal", "spain", "england", "holland", "ottoman", "italy"]

#: Real canon pilot cards: ``off_leg_willem_barentsz`` navigation 59 (≥ 40,
#: < 70 → the plain route); ``off_reg_pilot_07`` navigation 39 (one under the
#: gate threshold).
PILOT_OK = "off_leg_willem_barentsz"
PILOT_LOW = "off_reg_pilot_07"
#: The injected nav-70 fixture (the GDScript ``off_ap_pilot_70`` pattern) —
#: no shipped card reaches 70, so the weighted split needs one.
PILOT_70 = "fx_ap_pilot_70"

#: The pinned discovery fixtures (tools/test_discovery.gd §5d): the Atlas
#: cedars at (2046, 695); (2028, 677) is exactly Chebyshev 18 away (in range
#: at cartography 0), (2009, 658) exactly 37 away (out of the 36-tile base).
CEDARS = "disc_atlas_cedars"
CEDARS_TILE = (2046, 695)
AT_18 = (2028, 677)
AT_37 = (2009, 658)
CEDARS_GOLD = 2000
CEDARS_FAME = 150


# --- Fixtures ---------------------------------------------------------------

@pytest.fixture(scope="module")
def store() -> DataStore:
    loaded = DataStore()
    loaded.load_all()
    assert loaded.load_ok, loaded.load_errors
    return loaded


@pytest.fixture(scope="module")
def world():
    return raster()


@pytest.fixture(scope="module")
def ocean():
    return ocean_layers()


@pytest.fixture()
def pilot_70(store: DataStore):
    """Injects (and removes) the nav-70 pilot card on the shared store."""
    card = {
        "id": PILOT_70, "role": "", "main_skill": "navigation",
        "wage_daily": 20, "recruit_ports": ["lisbon"],
        "personality": ["honest"],
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 40, "luck": 10},
        "skills": {key: (70 if key == "navigation" else 0)
                   for key in skills.KEYS},
        "name": {"zh": "试·领航员70", "en": "Test Pilot 70"},
        "bio": {"zh": "测试", "en": "Fixture"},
    }
    store.officers[PILOT_70] = card
    store.officers_list.append(card)
    try:
        yield PILOT_70
    finally:
        store.officers.pop(PILOT_70, None)
        store.officers_list[:] = [entry for entry in store.officers_list
                                  if entry is not card]


def make_person(cartography: int = 0, gold: int = 0, day: int = 1,
                officers: list[str] | None = None) -> PersonState:
    """The bare-run Person fixture (``tools/test_autopilot.gd`` ``_make_run``
    / ``tools/test_discovery.gd`` ``_make_run``) on PersonState."""
    st = PersonState()
    st.player = {
        "nation_id": "portugal",
        "background_id": "",
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {key: (cartography if key == "cartography" else 0)
                   for key in skills.KEYS},
        "skill_counters": {key: 0 for key in skills.KEYS},
        "alloc_pending": 0,
        "xp": 0,
        "level": 1,
        "officers": list(officers or []),
        "reputation": {nation: 0 for nation in NATIONS},
        "profit_by_nation": {},
        "profit_rep_awarded": {},
        "equipment": {"weapon": "", "armor": ""},
    }
    st.gold = gold
    st.day = day
    st.fame = 0
    return st


def make_run(pos: tuple[int, int] = (2050, 615),
             known: list[str] | None = None,
             fleet: list[dict] | None = None) -> dict:
    """The injected run dict: the GameState members the autopilot reads
    (keys mirror the autoload members verbatim)."""
    return {
        "world": {"position": {"x": pos[0], "y": pos[1]},
                  "weather": "fair", "sail_trim": "normal",
                  "wind_dir": "NE"},
        "known_ports": list(known if known is not None
                            else ["lisbon", "seville"]),
        "fleet": fleet if fleet is not None else [],
    }


def put_pilot(store: DataStore, st: PersonState, officer_id: str) -> None:
    """Hires ``officer_id`` into the pilot post (the roster + state block)."""
    assert store.get_officer(officer_id), f"unknown officer {officer_id}"
    st.player["officers"] = [officer_id]
    st.officer_states[officer_id] = {
        "loyalty": 50, "sea_days": 0, "post_id": "pilot", "ship_id": "",
        "talk_cd_day": 0, "gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0,
    }


def speed_five(_heading: str = "") -> int:
    return 5


def identity_current(_heading: str, _cell: tuple[int, int],
                     _month: int) -> float:
    return 1.0


def legal_route(world, start: tuple[int, int],
                steps: list[tuple[int, int]]) -> bool:
    cursor = start
    for step in steps:
        if not is_step_legal(world.is_passable, world.width, world.height,
                             cursor, step):
            return False
        cursor = step
    return True


# --- 1. Locked constants + pure closed forms --------------------------------

def test_locked_constants() -> None:
    """§4.19/§4.10.4 constants and the §4.4/§4.15 closed forms, verbatim."""
    assert ap.GATE_FEATURE == "sail.autopilot"
    assert ap.GATE_THRESHOLD_FALLBACK == 40
    assert ap.WEIGHTED_NAV_THRESHOLD == 70
    assert ap.PILOT_POST == "pilot"
    assert ap.CANCEL_REASONS == ("contact", "manual", "arrived")
    assert ap.CANCELLED_CONTACT_KEY == "sail.autopilot.cancelled_contact"
    assert ap.HUD_BAR_KEY == "sail.autopilot.hud.bar"
    assert ap.WEIGHTED_CORRIDOR_RADIUS == 32
    assert ap.MAX_EXPANSIONS_WEIGHTED == 200000
    assert ap.HEURISTIC_WEIGHT == 2.0
    # §4.4 compass domain + direction table.
    assert ap.COMPASS_DIRS == ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
    assert ap.heading_of_delta((1, 0)) == "E"
    assert ap.heading_of_delta((0, -1)) == "N"
    assert ap.heading_of_delta((-1, 1)) == "SW"
    assert ap.heading_of_delta((0, 0)) == ""
    assert ap.heading_of_delta((2, 0)) == ""
    assert ap.angle_between_dirs("N", "S") == 180
    assert ap.angle_between_dirs("N", "E") == 90
    assert ap.angle_between_dirs("N", "NE") == 45
    assert ap.angle_between_dirs("N", "N") == 0
    assert ap.angle_between_dirs("N", "bogus") == -1
    assert ap.DIRECTION_FACTORS[0]["sail"] == 0.50
    assert ap.DIRECTION_FACTORS[180]["sail"] == 1.30
    assert ap.DIRECTION_FACTORS[90]["oar"] == 1.00
    # §4.15 month lattice (day 1 = Month 1, 30-day months).
    assert ap.month_for(1) == 1
    assert ap.month_for(30) == 1
    assert ap.month_for(31) == 2
    assert ap.month_for(360) == 12
    assert ap.month_for(361) == 1


# --- 2. Pilot gate matrix (pilot in post ∧ navigation ≥ 40 ∧ dest known) -----

def test_pilot_gate_matrix(store: DataStore) -> None:
    st = make_person()
    run = make_run()
    assert ap.gate_threshold(store) == 40
    # No pilot in post: the row's reason key, threshold 40, nav 0.
    none = ap.gate(store, st, run, "seville")
    assert none == {"ok": False, "reason_key": "sail.autopilot",
                    "threshold": 40, "pilot_nav": 0, "dest_known": True}
    text = ap.reason_text(store, none)
    assert set(text) == {"zh", "en"} and "40" in text["en"]
    # Pilot at 39 (one under the threshold).
    put_pilot(store, st, PILOT_LOW)
    low = ap.gate(store, st, run, "seville")
    assert low["ok"] is False and low["pilot_nav"] == 39
    assert low["reason_key"] == "sail.autopilot"
    # Pilot at 59, a known destination: the gate opens, no reason key.
    put_pilot(store, st, PILOT_OK)
    ok = ap.gate(store, st, run, "seville")
    assert ok["ok"] is True and ok["reason_key"] == ""
    assert ok["pilot_nav"] == 59 and ok["dest_known"] is True
    assert ap.reason_text(store, ok) == {}
    # Unknown destination (a real but unvisited port, then a bogus id): the
    # gate closes on dest_known with NO reason key (no reason row exists).
    unknown = ap.gate(store, st, run, "nagasaki")
    assert unknown["ok"] is False and unknown["dest_known"] is False
    assert unknown["reason_key"] == ""
    assert ap.reason_text(store, unknown) == {}
    assert ap.gate(store, st, run, "atlantis")["dest_known"] is False
    # The gate never counts the PLAYER's navigation — the pilot's own.
    st.player["skills"]["navigation"] = 100
    st.player["officers"] = []
    st.officer_states = {}
    assert ap.gate(store, st, run, "seville")["ok"] is False
    # The bare pilot/nav question (no destination) still answers.
    put_pilot(store, st, PILOT_OK)
    assert ap.gate(store, st, run)["ok"] is True


# --- 3. Appoint → save-v9 key + the plain §4.2 route ------------------------

def test_appoint_writes_key_and_plain_route(store: DataStore, world,
                                            ocean) -> None:
    st = make_person(gold=5000)
    run = make_run(pos=world.port_cell("lisbon"))
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    gold_before = st.gold
    result = ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert result["ok"] is True
    # The save-v9 key, present exactly as {dest_port_id}.
    assert st.player["autopilot"] == {"dest_port_id": "seville"}
    assert ap.appointed(st) and ap.dest_port_id(st) == "seville"
    steps = result["route"]
    # The shipped-artifact observation: lisbon → seville is 51 unit steps.
    assert len(steps) == 51
    assert steps[-1] == world.port_cell("seville")
    assert legal_route(world, world.port_cell("lisbon"), steps)
    # A nav-59 pilot gets the plain wind-blind path (40–69 band).
    assert result["weighted"] is False
    # No sailing view → the §4.4 floor (1 tile/day) stands in for the ETA.
    assert result["eta_days"] == float(len(steps))
    # No gold fee (§4.19): the purse is untouched by the appointment.
    assert st.gold == gold_before
    # route() serves the stored route (a fresh copy, not the live list).
    assert ap.route(store, st, run, world, ocean, rt) == steps
    assert ap.route(store, st, run, world, ocean, rt) is not rt.route


def test_appoint_from_destination_berth_arrives(store: DataStore, world,
                                                ocean) -> None:
    berth = world.port_cell("seville")
    st = make_person()
    run = make_run(pos=berth)
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    here = ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert here["ok"] is True and here["route"] == []
    ticked = ap.tick(store, st, run, world, ocean, rt)
    assert ticked["appointed"] is True and ticked["arrived"] is True
    assert ticked["route"] == []
    assert ap.cancel(st, run, rt, ap.REASON_ARRIVED) is True
    assert "autopilot" not in st.player


def test_failed_gate_stores_nothing(store: DataStore, world, ocean) -> None:
    st = make_person()
    run = make_run()
    rt = ap.AutopilotRuntime()
    refused = ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert refused["ok"] is False and "autopilot" not in st.player
    assert rt.route == []
    # A known destination with no berth fails on the route, not the gate —
    # and still stores nothing (no_route).
    put_pilot(store, st, PILOT_OK)
    run["known_ports"] = ["atlantis"]
    no_route = ap.appoint(store, st, run, world, ocean, rt, "atlantis")
    assert no_route["ok"] is False and no_route.get("no_route") is True
    assert "autopilot" not in st.player


# --- 4. Cancel reasons + the interrupt matrix -------------------------------

def test_cancel_reasons(store: DataStore, world, ocean) -> None:
    st = make_person()
    run = make_run()
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    assert ap.cancel(st, run, rt, "storm") is False  # unknown reason
    assert ap.cancel(st, run, rt, ap.REASON_MANUAL) is False  # nothing on
    ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert ap.cancel(st, run, rt, ap.REASON_MANUAL) is True
    assert not ap.appointed(st) and "autopilot" not in st.player
    assert rt.route == [] and ap.route(store, st, run, world, ocean, rt) == []
    ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert ap.cancel(st, run, rt, ap.REASON_CONTACT) is True
    ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert ap.cancel(st, run, rt, ap.REASON_ARRIVED) is True


def test_contact_and_manual_interrupts(store: DataStore, world,
                                       ocean) -> None:
    # The §4.10.4 contact notice exists in ui_strings (zh/en data).
    notice = store.get_ui_string(ap.CANCELLED_CONTACT_KEY)
    assert notice and set(notice) >= {"zh", "en"}
    st = make_person()
    run = make_run()
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    # Hostile contact: the world's contact funnel cancels before the battle.
    ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert ap.cancel(st, run, rt, ap.REASON_CONTACT) is True
    assert not ap.appointed(st)
    # Any manual move input cancels too.
    ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert ap.cancel(st, run, rt, ap.REASON_MANUAL) is True
    assert not ap.appointed(st)


def test_storm_does_not_cancel(store: DataStore, world, ocean) -> None:
    st = make_person()
    run = make_run(pos=world.port_cell("lisbon"))
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    ap.appoint(store, st, run, world, ocean, rt, "seville")
    # A storm day: trim auto-reefs, the appointment stands.
    run["world"]["weather"] = "storm"
    run["world"]["sail_trim"] = "full"
    storm = ap.tick(store, st, run, world, ocean, rt)
    assert storm["appointed"] is True and ap.appointed(st)
    assert run["world"]["sail_trim"] == "reefed"
    # Restore the player's previous trim on the first non-storm tick.
    run["world"]["weather"] = "fair"
    ap.tick(store, st, run, world, ocean, rt)
    assert run["world"]["sail_trim"] == "full"
    # A trim the player changed during the storm stays theirs.
    run["world"]["weather"] = "storm"
    run["world"]["sail_trim"] = "normal"
    ap.tick(store, st, run, world, ocean, rt)
    run["world"]["sail_trim"] = "full"  # the player cycled [/]
    run["world"]["weather"] = "fair"
    ap.tick(store, st, run, world, ocean, rt)
    assert run["world"]["sail_trim"] == "full"
    # Cancelling mid-storm restores the saved trim too.
    run["world"]["weather"] = "storm"
    run["world"]["sail_trim"] = "full"
    ap.tick(store, st, run, world, ocean, rt)
    assert run["world"]["sail_trim"] == "reefed"
    assert ap.cancel(st, run, rt, ap.REASON_MANUAL) is True
    assert run["world"]["sail_trim"] == "full"
    # Without an appointment tick() is a no-op: no reef, no reads.
    run["world"]["weather"] = "storm"
    run["world"]["sail_trim"] = "normal"
    idle = ap.tick(store, st, run, world, ocean, rt)
    assert idle == {"appointed": False}
    assert run["world"]["sail_trim"] == "normal"


# --- 5. The weighted A* core (fleet_path.gd guarantee, synthetic grid) ------

def test_weighted_core_synthetic() -> None:
    width, height = 9, 3  # wide enough that x=0 and x=8 are one step apart

    def all_passable(_cell: tuple[int, int]) -> bool:
        return True

    def band(_a: tuple[int, int], b: tuple[int, int]) -> float:
        # Row 1 is the expensive head-wind band.
        return 10.0 if b[1] == 1 else 1.0

    # The weighted search pays distance for cheap days: detour via row 0.
    detour = ap._find_path_weighted((0, 1), (4, 1), width, height,
                                    all_passable, band)
    assert len(detour) == 5
    assert detour[0] == (0, 1) and detour[-1] == (4, 1)
    assert all(cell[1] != 1 for cell in detour[1:-1])
    cost = sum(band(a, b) for a, b in zip(detour, detour[1:]))
    assert cost < 40.001  # the straight band-run would cost 40
    # Determinism: the same query twice, identical path.
    again = ap._find_path_weighted((0, 1), (4, 1), width, height,
                                   all_passable, band)
    assert again == detour
    # Same cell → [from]; impassable goal → [].
    assert ap._find_path_weighted((2, 1), (2, 1), width, height,
                                  all_passable, band) == [(2, 1)]
    blocked = lambda cell: cell != (3, 1)  # noqa: E731
    assert ap._find_path_weighted((0, 1), (3, 1), width, height,
                                  blocked, band) == []
    # Wrap: (8, 0) → (0, 0) crosses the seam as one unit step.
    wrap = ap._find_path_weighted((8, 0), (0, 0), width, height,
                                  all_passable, lambda _a, _b: 1.0)
    assert wrap == [(8, 0), (0, 0)]
    # No corner cutting: an L wall forces the walk round the corner.
    wall = {(1, 1), (1, 0)}
    walled = lambda cell: cell not in wall  # noqa: E731
    around = ap._find_path_weighted((0, 1), (2, 1), width, height,
                                    walled, lambda _a, _b: 1.0)
    assert around[0] == (0, 1) and around[-1] == (2, 1)
    assert (1, 2) in around  # goes round through the open row
    # The expansion guard bails out instead of spinning.
    assert ap._find_path_weighted((0, 1), (4, 1), width, height, blocked,
                                  band, max_expansions=3) == []


def test_step_multiplier_wind_model(ocean) -> None:
    """The §4.19 step-cost model: ``1 / (wind_f × current_f)`` — head-wind
    steps cost more days, downwind steps the least."""
    cell = (2050, 615)  # Lisbon's berth tile
    assert ocean.prevailing_for(cell[0], cell[1], 1) == "SW"
    head = ap._step_multiplier("SW", cell, 1, "sail", ocean, None)
    down = ap._step_multiplier("NE", cell, 1, "sail", ocean, None)
    assert head == pytest.approx(1.0 / 0.50)   # into the wind: ×2 the base
    assert down == pytest.approx(1.0 / 1.30)   # downwind: the cheapest
    assert head > down
    # No ocean decode / neutral water: identity 1.0 (the §6.5 fallback).
    assert ap._step_multiplier("SW", cell, 1, "sail", None, None) == 1.0
    # The injected §4.16 current factor divides the cost.
    boosted = ap._step_multiplier("NE", cell, 1, "sail", ocean,
                                  lambda _h, _c, _m: 1.25)
    assert boosted == pytest.approx(1.0 / (1.30 * 1.25))
    # The oar class ignores the direction table (all buckets 1.00).
    assert ap._step_multiplier("SW", cell, 1, "oar", ocean,
                               None) == pytest.approx(1.0)


def test_corridor_mask_synthetic() -> None:
    """The §4.19 corridor band: per-row wrap-split intervals, merged."""
    seed = [(2, 5), (3, 5)]
    mask = ap._corridor_mask((1, 5), seed, 1, 10, 10)
    assert mask["y0"] == 4 and mask["rows"] == 3 and mask["width"] == 10

    def inside(cell: tuple[int, int]) -> bool:
        y0, rows = mask["y0"], mask["rows"]
        if cell[1] < y0 or cell[1] >= y0 + rows:
            return False
        return mask["data"][(cell[1] - y0) * mask["width"]
                            + cell[0] % mask["width"]] == 1

    assert inside((1, 5)) and inside((3, 4)) and inside((4, 6))
    assert not inside((5, 5)) and not inside((1, 3))
    # Wrap-split intervals + interval merge.
    assert ap._wrap_interval(8, 11, 10) == [[8, 9], [0, 1]]
    assert ap._wrap_interval(0, 15, 10) == [[0, 9]]
    assert ap._merge_intervals([[0, 2], [1, 4], [6, 7]]) == [[0, 4], [6, 7]]


# --- 6. The route-quality split on the real raster --------------------------

def test_real_route_quality_split(store: DataStore, world, ocean,
                                  pilot_70: str) -> None:
    lisbon = world.port_cell("lisbon")
    seville = world.port_cell("seville")
    run = make_run(pos=lisbon)

    st_plain = make_person()
    put_pilot(store, st_plain, PILOT_OK)  # navigation 59 → plain
    rt_plain = ap.AutopilotRuntime()
    plain = ap.appoint(store, st_plain, run, world, ocean, rt_plain,
                       "seville", effective_speed=speed_five,
                       current_factor=identity_current)
    assert plain["ok"] is True and plain["weighted"] is False
    assert legal_route(world, lisbon, plain["route"])
    assert plain["route"][-1] == seville
    # The crossed wind regions are sorted distinct ids (the suite's second
    # weighted-vs-plain discriminator).
    regions = ap.route_wind_regions(ocean, plain["route"])
    assert regions == sorted(set(regions))
    assert all(isinstance(region, int) for region in regions)

    st_weighted = make_person(officers=[pilot_70])
    put_pilot(store, st_weighted, pilot_70)  # navigation 70 → weighted
    rt_weighted = ap.AutopilotRuntime()
    weighted = ap.appoint(store, st_weighted, run, world, ocean, rt_weighted,
                          "seville", effective_speed=speed_five,
                          current_factor=identity_current)
    assert weighted["ok"] is True and weighted["weighted"] is True
    assert legal_route(world, lisbon, weighted["route"])
    assert weighted["route"][-1] == seville
    # The weighted model cost never exceeds the plain one on the same OD, and
    # the detour stays corridor-bounded (autopilot.gd's route-quality pin).
    assert weighted["cost_days"] <= plain["cost_days"] + 1e-9
    assert len(weighted["route"]) < len(plain["route"]) * 13 / 10
    # Determinism: recompute the weighted route twice, identical steps.
    rt_replay = ap.AutopilotRuntime()
    replay = ap.appoint(store, st_weighted, run, world, ocean, rt_replay,
                        "seville", effective_speed=speed_five,
                        current_factor=identity_current)
    assert replay["route"] == weighted["route"]


# --- 7. ETA + the structured HUD payload ------------------------------------

def test_eta_and_hud_payload(store: DataStore, world, ocean) -> None:
    st = make_person()
    run = make_run(pos=world.port_cell("lisbon"))
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    assert ap.hud_state(store, st, run, world, ocean, rt) == {"visible": False}
    result = ap.appoint(store, st, run, world, ocean, rt, "seville",
                        effective_speed=speed_five,
                        current_factor=identity_current)
    steps = result["route"]
    start = world.port_cell("lisbon")
    # Σ 1 / speed over the legs: speed 5 → len / 5.
    assert ap.eta_days(steps, start, effective_speed=speed_five) \
        == pytest.approx(len(steps) / 5.0)
    # The §4.4 floor keeps the divisor ≥ 1 (a 0-speed leg = 1 tile/day).
    assert ap.eta_days(steps, start, effective_speed=lambda _h: 0) \
        == float(len(steps))
    assert ap.eta_days([], start) == 0.0
    hud = ap.hud_state(store, st, run, world, ocean, rt,
                       effective_speed=speed_five,
                       current_factor=identity_current)
    assert hud["visible"] is True and hud["dest_port_id"] == "seville"
    assert hud["bar_key"] == "sail.autopilot.hud.bar"
    assert hud["cancel_key"] == "sail.autopilot.cancel"
    # Structured descriptors, not composed strings: the port name stays an
    # L10nString and the day count is the ceiling of the ETA.
    assert hud["values"]["port"] == store.get_port("seville")["name"]
    assert hud["values"]["days"] == math.ceil(len(steps) / 5.0)


# --- 8. Arrival docking handoff (the seeded integration observation) --------

def test_arrival_docking_handoff(store: DataStore, world, ocean) -> None:
    berth = world.port_cell("seville")
    start = None
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        candidate = (berth[0] + dx, berth[1] + dy)
        if 0 <= candidate[1] < world.height \
                and world.is_passable(*candidate):
            start = candidate
            break
    assert start is not None, "seville's berth has a water neighbour"
    st = make_person()
    run = make_run(pos=start)
    put_pilot(store, st, PILOT_OK)
    rt = ap.AutopilotRuntime()
    result = ap.appoint(store, st, run, world, ocean, rt, "seville")
    assert result["ok"] is True
    steps = result["route"]
    assert steps, "a route to the berth exists"
    # Walk it tick by tick — the appointment survives every intermediate tick
    # and flips to `arrived` exactly on the berth.
    walked = 0
    arrived = False
    for _guard in range(len(steps) + 2):
        state = ap.tick(store, st, run, world, ocean, rt)
        if state["arrived"]:
            arrived = True
            break
        assert state["route"], "each tick hands the world a non-empty route"
        run["world"]["position"] = {"x": state["route"][0][0],
                                    "y": state["route"][0][1]}
        st.day += 1
        walked += 1
    assert arrived, "the appointed sail reaches the berth"
    assert walked == len(steps)
    assert ap.world_tile(run) == berth
    # The dock sequence clears the appointment (§4.19 "clears").
    assert ap.cancel(st, run, rt, ap.REASON_ARRIVED) is True
    assert "autopilot" not in st.player


# --- 9. Discovery: radius, Explore, report, hint delegation -----------------

def test_discovery_constants(store: DataStore) -> None:
    assert disc.RADIUS_BASE == 36
    assert disc.CARTOGRAPHY_DIVISOR == 15
    assert disc.MAP_WIDTH_FALLBACK == 4320
    assert disc.MAP_HEIGHT_FALLBACK == 2160
    assert disc.map_width(store) == 4320
    assert disc.map_height(store) == 2160


def test_discovery_radius_formula(store: DataStore) -> None:
    """§4.4/§4.3: ``36 + floor(cartography / 15)`` at the boundaries."""
    for cartography, expected in ((0, 36), (14, 36), (15, 37), (30, 38),
                                  (45, 39), (100, 42)):
        st = make_person(cartography=cartography)
        assert disc.radius(st, store) == expected, cartography


def test_discovery_position_and_wrap(store: DataStore) -> None:
    assert disc.position_of(store, CEDARS) == CEDARS_TILE
    # discovery entries carry lat/lon; the §6.1 floor projection derives the
    # tile (x wraps mod width, y clamps).
    assert disc.tile_of_latlon(store, 32.08, -9.42) == (2046, 695)
    # Wrap-aware Chebyshev: x=4319 and x=1 are two tiles apart.
    assert disc.chebyshev_to_cell(store, (4319, 100), (1, 100)) == 2
    assert disc.chebyshev_to_cell(store, (10, 10), (10, 10)) == 0


def test_explore_pinned_scenario(store: DataStore) -> None:
    st = make_person(cartography=0)
    found: list[str] = []
    # Chebyshev 18 ≤ 36: the pinned Explore fixture is in range.
    assert disc.something_near(st, store, found, AT_18) is True
    assert disc.explore(st, store, found, AT_18) == [CEDARS]
    assert found == [CEDARS]
    # Chebyshev 37 > 36: the control fixture is out of range (cartography 0).
    assert disc.something_near(st, store, found, AT_37) is False
    assert disc.explore(st, store, found, AT_37) == []
    # Radius boundary: cartography 15 → radius 37 reaches the control;
    # cartography 14 → radius 36 does not (fresh found sets).
    assert disc.explore(make_person(cartography=15), store, [], AT_37) \
        == [CEDARS]
    assert disc.in_range(make_person(cartography=14), store, [], AT_37) == []
    # Re-explore of an already-found discovery finds nothing (first only).
    assert disc.explore(st, store, found, AT_18) == []


def test_report_payout_once(store: DataStore) -> None:
    st = make_person(gold=0)
    found = [CEDARS]
    reported: list[str] = []
    block = disc.report(store, st, found, reported, CEDARS)
    assert block == {"id": CEDARS, "gold": CEDARS_GOLD, "fame": CEDARS_FAME}
    assert st.gold == CEDARS_GOLD and st.fame == CEDARS_FAME
    assert reported == [CEDARS]
    # A second report refuses: no re-pay, the reported list is unchanged.
    assert disc.report(store, st, found, reported, CEDARS) == {}
    assert st.gold == CEDARS_GOLD and st.fame == CEDARS_FAME
    assert reported == [CEDARS]
    # Not found / unknown id refuse too.
    assert disc.report(store, st, [], [], CEDARS) == {}
    assert disc.report(store, st, ["nope"], [], "nope") == {}
    assert st.gold == CEDARS_GOLD and st.fame == CEDARS_FAME


def test_found_versus_reported(store: DataStore) -> None:
    found = [CEDARS, "disc_nile_cataracts"]
    assert disc.unreported(store, found, []) == sorted(found)
    assert disc.unreported(store, found, [CEDARS]) == ["disc_nile_cataracts"]
    assert disc.unreported(store, found, found) == []


def test_hint_half_delegates_to_tavern(store: DataStore) -> None:
    """The overlap resolution: one implementation, re-exported here."""
    assert disc.hints is tavern.hints
    assert disc.is_hinted is tavern.is_hinted
    assert disc.buy_hint is tavern.buy_hint
    assert disc.hint_text is tavern.hint_text
    assert disc.port_ordinal is tavern.port_ordinal
    assert disc.HINT_PRICE == tavern.HINT_PRICE == 100
    assert disc.HINTS_PER_VISIT == tavern.HINTS_PER_VISIT == 3
    assert disc.SEED_DAY_MULT == tavern.SEED_DAY_MULT == 1000003
    assert disc.SEED_PORT_MULT == tavern.SEED_PORT_MULT == 7919
    # The re-exported helpers run on this module's store/state convention.
    st = make_person(gold=100)
    hints_map: dict[str, bool] = {}
    entry = disc.buy_hint(store, st, hints_map, CEDARS)
    assert entry["id"] == CEDARS and st.gold == 0
    assert disc.is_hinted(hints_map, CEDARS) is True
    assert disc.buy_hint(store, st, hints_map, CEDARS) == {}  # never twice
    assert disc.hint_text(store, CEDARS) == \
        store.get_discovery(CEDARS)["region_hint"]
    # The hint draw is deterministic for a pinned (port, day).
    first = disc.hints(store, [], "lisbon", 100)
    assert first == disc.hints(store, [], "lisbon", 100)
    assert 0 < len(first) <= disc.HINTS_PER_VISIT
