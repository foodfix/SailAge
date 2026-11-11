"""server.tests.test_facility — the three facility engines' parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_tavern.gd`` T14, ``tools/test_inn.gd`` T15,
``tools/test_palace.gd`` Phase-3 task D + Phase-7 task L,
``tools/test_tournament.gd`` Phase-3 task F) boot runs and walk the
autoloads; here the same pinned contracts are asserted as pure functions
over injected state on the real shipped ``data/`` tree (loaded through
:mod:`server.sim.data`).

Pinned contracts:
  * tavern crew (docs/30 §4.5/§4.6): the ``crew_wage_daily × 10 = 20g``
    signing bonus, the flagship ``crew_max`` cap / ``crew_min`` floor, the
    strict vs −1/−10-clamped fire variants, no severance, the §4.1b
    closed-door gate;
  * the §4.4 officer pool visibility (recruit_ports placement, employed
    officers vanish everywhere);
  * the Phase-8 W5-C sparring wager (100–1,000g stakes, the 40-swordplay
    champion chance formula clamped [0.10, 0.90], pot × 2, 3 swordplay
    usages per bout — feeding the §4.3 growth award);
  * the Rumors tab hints (docs/70 §4.4): the pinned
    ``day × 1000003 + port_ordinal × 7919`` GodotRng draw on the shipped
    discoveries (exact hint ids), the 100g purchase, no re-buy;
  * inn rest (docs/30 §4.7): 30g charged up front, the day + 3 @ 08:00 wake
    from any arrival fraction, the ledger seam called exactly once with
    ``Δ = 10/3 − clock_fraction``, refused at 29g;
  * harbor relief (docs/10 §5, docs/50 §4.7): the full condition matrix
    (each clause flips), ``+100g`` / ``+1 day``, and the anti-softlock
    arithmetic — exactly 12 odd jobs from 0g reach the 1,200g ``latin``
    hull and the 13th is refused;
  * palace royal missions (docs/70 §4.9.4): the rep-30 gate, capitals
    only, one per nation, the kind rotation, the patrol/chart completion
    counters and pinned deltas (8000/6000 gold, +25 fame, +10 rep, +1
    mission), the 3× delivery multiplier, the expiry tick (−10 rep);
  * the §4.9.2 title ceremony boundary via ``fame`` (grant at exact
    fame/mission thresholds, one rung at a time, per-nation independence);
  * permits (docs/30 §4.10): the home/foreign offer matrix, the title/rep
    gates, the buy → treasury credit → owned row flow, the void
    (bounty / rep < −20) and full-price re-buy matrix, the negotiation
    discounts (4,750g / 18,000g);
  * the commendation pull model (queued at the player's own palaces,
    dismissed once);
  * the tournament (docs/70 §4.6/§4.9.7): the §7.4 capital rotation, cycle
    maths, the days 1–5 window, one entry per cycle, the 1,000g fee, the
    brigantine → carrack → galleon bracket shape on shipped hull data, the
    10,000g + 100 fame prize, the 500g consolation with the free repair to
    ``ceil(effective_max × 0.5)`` (figurehead modifier included), and the
    scripted-builder bracket run. The oracle bracket is RNG-free (verified
    by grep at port time) — the bouts are the combat port's seam, so the
    "pinned seed" here is the deterministic closed-form arrangement itself.

Deterministic — no Monte Carlo, no engine boots; the only seeded stream is
the hint draw, pinned to the oracle's exact output.
"""

from __future__ import annotations

from typing import Any

import pytest

from server.sim.data import DataStore, data
from server.sim.player import character, fame, skills
from server.sim.player import PersonState
from server.sim.port import inn, palace, tavern

# data/ pins used literally below (docs/10-* §7.3).
CARAVEL_MIN = 15
CARAVEL_MAX = 45
GALLEON_MIN = 40
GALLEON_MAX = 150
CHEAPEST_HULL = 1200  # latin

CAPITALS = ["lisbon", "seville", "london", "amsterdam", "istanbul", "venice"]


# --- Fixtures ---------------------------------------------------------------


def make_person(nation: str = "portugal", gold: int = 10000,
                reputation: dict[str, int] | None = None,
                officers: list[str] | None = None,
                negotiation: int = 0,
                swordplay: int = 0) -> PersonState:
    """The v9 Person block fixture the GDScript harnesses build (tools/
    test_tavern.gd ``_make_run``), on the PersonState mirror."""
    st = PersonState()
    st.player = {
        "nation_id": nation,
        "background_id": "",
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": 10, "luck": 10},
        "skills": {key: (negotiation if key == "negotiation" else
                         swordplay if key == "swordplay" else 0)
                   for key in skills.KEYS},
        "skill_counters": {key: 0 for key in skills.KEYS},
        "alloc_pending": 0,
        "xp": 0,
        "level": 1,
        "officers": list(officers or []),
        "reputation": reputation
        or {"portugal": 20, "spain": 0, "england": 0, "holland": 0,
            "ottoman": 0, "italy": 0},
        "profit_by_nation": {},
        "profit_rep_awarded": {},
        "equipment": {"weapon": "", "armor": ""},
    }
    st.gold = gold
    st.day = 1
    return st


def make_ship(store: DataStore, ship_type_id: str, crew: int) -> dict[str, Any]:
    """``FleetLib.new_ship`` (scripts/fleet/fleet.gd:23) — the fixture shape
    the runtime's fleet entries carry."""
    ship_type = store.get_ship_type(ship_type_id)
    assert ship_type, f"unknown ship type {ship_type_id}"
    return {
        "ship_type_id": ship_type_id,
        "durability": int(ship_type["durability"]),
        "crew": max(0, min(crew, int(ship_type["crew_max"]))),
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "cargo": {},
    }


def make_hold(free: int) -> tuple[dict[str, Any], Any, Any, Any]:
    """A fleet-hold stand-in for the ``FleetLib`` seam (``fleet_free`` /
    ``add_goods`` / ``remove_goods`` over one pooled hold)."""
    hold: dict[str, Any] = {"free": free, "cargo": {}}

    def fleet_free() -> int:
        return hold["free"]

    def add_goods(good_id: str, qty: int) -> int:
        stored = min(qty, hold["free"])
        hold["free"] -= stored
        hold["cargo"][good_id] = hold["cargo"].get(good_id, 0) + stored
        return stored

    def remove_goods(good_id: str, qty: int) -> int:
        taken = min(qty, int(hold["cargo"].get(good_id, 0)))
        hold["cargo"][good_id] = int(hold["cargo"].get(good_id, 0)) - taken
        hold["free"] += taken
        return taken

    return hold, fleet_free, add_goods, remove_goods


def make_run(gold: int = 10000, day: int = 1) -> dict[str, Any]:
    """The run-state dict mirror (the GameState members the palace engine
    reads; keys verbatim)."""
    return {
        "active_quests": [],
        "fleet": [],
        "npc_fleets": [],
        "discovery_hints": {},
        "bounties": {},
        "retired": False,
        "retired_at": 0,
    }


def make_allegiance() -> tuple[dict[str, Any], dict[str, int], list[str],
                               dict[str, Any]]:
    """Fresh allegiance state (permits, treasuries, commendation queue +
    shown set) — the injected stance of ``allegiance.gd``'s statics."""
    permits: dict[str, Any] = {"home": False, "foreign": {}}
    treasuries: dict[str, int] = {nation: 5000 for nation in CAPITAL_NATIONS}
    pending: list[str] = []
    shown: dict[str, Any] = {}
    return permits, treasuries, pending, shown


CAPITAL_NATIONS = ["portugal", "spain", "england", "holland", "ottoman",
                   "italy"]


@pytest.fixture
def store() -> DataStore:
    return data()


# ===========================================================================
# Tavern — crew hire/fire (tools/test_tavern.gd §4.5, docs/30 §4.5/§4.6)
# ===========================================================================


def test_hire_cost_formulas(store: DataStore) -> None:
    """20g per head (2 × 10), linear, never negative."""
    assert tavern.CREW_WAGE_DAILY == 2
    assert tavern.per_head() == 20
    assert tavern.hire_cost(1) == 20
    assert tavern.hire_cost(10) == 200
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=10000)
    assert tavern.hire_cost(tavern.max_hire(store, fleet)) \
        == 20 * tavern.max_hire(store, fleet)
    assert tavern.hire_cost(0) == 0
    assert tavern.hire_cost(-5) == 0


def test_hire_transactions(store: DataStore) -> None:
    """A hire deducts exactly 20g/head and adds exactly that many crew."""
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=100)
    assert tavern.hire(store, fleet, st, 1)
    assert st.gold == 80
    assert tavern.crew(fleet) == CARAVEL_MIN + 1

    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=1000)
    assert tavern.hire(store, fleet, st, 10)
    assert st.gold == 800
    assert tavern.crew(fleet) == CARAVEL_MIN + 10

    # A blocked hire is free.
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=0)
    assert not tavern.hire(store, fleet, st, 1)
    assert st.gold == 0
    assert tavern.crew(fleet) == CARAVEL_MIN


def test_hire_amounts_and_caps(store: DataStore) -> None:
    """max_hire / Fill amounts and the crew_max cap (docs/30 §4.5)."""
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=10000)
    assert tavern.max_hire(store, fleet) == CARAVEL_MAX - CARAVEL_MIN
    assert tavern.fill_heads(store, fleet, st.gold) == 30
    assert tavern.hire(store, fleet, st, tavern.fill_heads(store, fleet,
                                                           st.gold))
    assert tavern.crew(fleet) == CARAVEL_MAX
    assert st.gold == 10000 - 600  # Fill costs 30 × 20

    # Fill is purse-limited: 65g hires 3 head; 19g hires none.
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    assert tavern.fill_heads(store, fleet, 65) == 3
    assert tavern.fill_heads(store, fleet, 19) == 0
    st = make_person(gold=19)
    assert not tavern.hire(store, fleet, st, 0)
    assert not tavern.hire(store, fleet, st, -3)

    # +10 clamps at the cap: 4 berths left → can_hire(10) refused, +4 fits.
    fleet = [make_ship(store, "caravel", CARAVEL_MAX - 4)]
    st = make_person(gold=10000)
    assert not tavern.can_hire(store, fleet, st, 10)
    assert tavern.can_hire(store, fleet, st, 4)
    assert tavern.hire(store, fleet, st, 4)
    assert tavern.crew(fleet) == CARAVEL_MAX

    # At crew_max nothing is hireable and a capped hire costs nothing.
    fleet = [make_ship(store, "caravel", CARAVEL_MAX)]
    st = make_person(gold=10000)
    assert tavern.max_hire(store, fleet) == 0
    assert not tavern.can_hire(store, fleet, st, 1)
    assert not tavern.hire(store, fleet, st, 1)
    assert tavern.crew(fleet) == CARAVEL_MAX and st.gold == 10000
    assert tavern.fill_heads(store, fleet, st.gold) == 0

    # Gold boundary: 19g is short, exactly 20g is allowed.
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=19)
    assert not tavern.can_hire(store, fleet, st, 1)
    st = make_person(gold=20)
    assert tavern.can_hire(store, fleet, st, 1)
    assert tavern.hire(store, fleet, st, 1)
    assert st.gold == 0

    # crew_max/crew_min come from the flagship's ShipType (galleon).
    fleet = [make_ship(store, "galleon", 100)]
    st = make_person(gold=10000)
    assert tavern.crew_max(store, fleet) == GALLEON_MAX
    assert tavern.crew_min(store, fleet) == GALLEON_MIN
    assert not tavern.hire(store, fleet, st,
                           tavern.max_hire(store, fleet) + 1)
    assert tavern.hire(store, fleet, st, 50)
    assert tavern.crew(fleet) == GALLEON_MAX


def test_fire_floors_and_clamps(store: DataStore) -> None:
    """The crew_min floor, the strict vs clamped fire variants, no
    severance (docs/30 §4.5/§6)."""
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=1000)
    assert tavern.min_fire(store, fleet) == 0
    assert not tavern.can_fire(store, fleet, 1)
    assert not tavern.fire(store, fleet, 1)
    assert tavern.crew(fleet) == CARAVEL_MIN

    fleet = [make_ship(store, "caravel", CARAVEL_MAX)]
    st = make_person(gold=1000)
    assert tavern.min_fire(store, fleet) == CARAVEL_MAX - CARAVEL_MIN
    assert tavern.fire(store, fleet, 1)
    assert tavern.crew(fleet) == CARAVEL_MAX - 1
    assert tavern.fire(store, fleet, 10)
    assert tavern.crew(fleet) == CARAVEL_MAX - 11
    assert tavern.fire(store, fleet, tavern.min_fire(store, fleet))
    assert tavern.crew(fleet) == CARAVEL_MIN

    # −1/−10 clamp: fires what the floor allows and reports the number.
    fleet = [make_ship(store, "caravel", CARAVEL_MIN + 5)]
    assert tavern.fire_clamped(store, fleet, 10) == 5
    assert tavern.crew(fleet) == CARAVEL_MIN
    assert tavern.fire_clamped(store, fleet, 1) == 0
    assert tavern.crew(fleet) == CARAVEL_MIN

    # The strict variant refuses outright instead of partially firing.
    fleet = [make_ship(store, "caravel", CARAVEL_MIN + 5)]
    st = make_person(gold=1000)
    assert not tavern.fire(store, fleet, 10)
    assert tavern.crew(fleet) == CARAVEL_MIN + 5

    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    assert not tavern.fire(store, fleet, 0)
    assert not tavern.fire(store, fleet, -2)
    assert tavern.fire_clamped(store, fleet, 0) == 0
    assert tavern.fire_clamped(store, fleet, -2) == 0

    # No severance: gold is untouched by firing.
    fleet = [make_ship(store, "caravel", CARAVEL_MAX)]
    st = make_person(gold=777)
    assert tavern.fire(store, fleet, 10)
    assert st.gold == 777

    # The galleon floor is enforced too: 100 → 40, then refused.
    fleet = [make_ship(store, "galleon", 100)]
    st = make_person(gold=1000)
    assert tavern.fire(store, fleet, 60)
    assert tavern.crew(fleet) == GALLEON_MIN
    assert not tavern.fire(store, fleet, 1)


def test_hire_fire_morale_and_doors(store: DataStore) -> None:
    """§4.1b closed-door gate; hire/fire never touch morale or severance —
    structural: the engine functions receive no morale at all (docs/30
    §4.5 "morale unchanged" is untestable-by-construction here, so the pin
    is the signature + the untouched state)."""
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=100)
    assert not tavern.hire(store, fleet, st, 1, open_now=False)
    assert st.gold == 100 and tavern.crew(fleet) == CARAVEL_MIN
    fleet = [make_ship(store, "caravel", CARAVEL_MAX)]
    assert not tavern.fire(store, fleet, 1, open_now=False)
    assert tavern.fire_clamped(store, fleet, 10, open_now=False) == 0
    assert tavern.crew(fleet) == CARAVEL_MAX
    # A closed door blocks sparring too.
    st = make_person(gold=1000)
    assert not tavern.can_spar(st, 100, open_now=False)
    assert tavern.spar(st, store, 100, 0.0, open_now=False) == {}
    assert st.gold == 1000


# --- Officer pool visibility (tools/test_tavern.gd §4.4) --------------------


def test_officer_pool_visibility(store: DataStore) -> None:
    """The §4.4 placement rule on shipped data: an officer lists at every
    one of its recruit_ports, at no other port, and vanishes everywhere
    while employed. The 96-officer v2 roster pin travels with it."""
    assert len(store.officers_list) == 96
    mateus = store.get_officer("off_mateus_alvares")
    assert mateus.get("recruit_ports") == ["lisbon", "madeira"]
    st = make_person()
    assert "off_mateus_alvares" in tavern.officers_at_port(store, st, "lisbon")
    assert "off_mateus_alvares" in tavern.officers_at_port(store, st,
                                                           "madeira")
    assert "off_thomas_reed" in tavern.officers_at_port(store, st, "london")
    # A port outside every recruit_ports list is empty; unknown ids too.
    assert tavern.officers_at_port(store, st, "barcelona") == []
    assert tavern.officers_at_port(store, st, "") == []
    assert tavern.officers_at_port(store, st, "not_a_port") == []

    # Every officer appears at each recruit port and nowhere else.
    for officer in store.officers_list:
        officer_id = str(officer.get("id", ""))
        ports = [str(p) for p in officer.get("recruit_ports", [])]
        assert ports, f"{officer_id} declares recruit_ports"
        for port_id in ports:
            assert officer_id in tavern.officers_at_port(store, st, port_id)
        for port in store.ports_list:
            port_id = str(port.get("id", ""))
            if port_id in ports:
                continue
            assert officer_id not in tavern.officers_at_port(store, st,
                                                             port_id)

    # Employed officers vanish from every tavern; dismissal repopulates.
    st = make_person(gold=5000)
    assert character.recruit(st, store, "off_mateus_alvares")
    for port_id in ["lisbon", "madeira", "london", "venice", "athens"]:
        assert "off_mateus_alvares" not in tavern.officers_at_port(store, st,
                                                                   port_id)
    assert character.dismiss(st, "off_mateus_alvares")
    for port_id in ["lisbon", "madeira"]:
        assert "off_mateus_alvares" in tavern.officers_at_port(store, st,
                                                               port_id)
    assert "off_mateus_alvares" not in tavern.officers_at_port(store, st,
                                                               "london")


# --- Sparring wager (docs/80-* §4.11.1) -------------------------------------


def test_spar_wager_math(store: DataStore) -> None:
    """The locked stake band, chance formula and pot."""
    assert tavern.spar_step(100, -1) == 100
    assert tavern.spar_step(100, 1) == 200
    assert tavern.spar_step(1000, 1) == 1000
    assert tavern.spar_step(950, 1) == 1000
    assert tavern.spar_valid_stake(100)
    assert tavern.spar_valid_stake(1000)
    assert not tavern.spar_valid_stake(0)
    assert not tavern.spar_valid_stake(99)
    assert not tavern.spar_valid_stake(150)
    assert not tavern.spar_valid_stake(1100)
    assert tavern.spar_pot(100) == 200
    # chance = clamp(0.5 + (swordplay − 40)/200, 0.10, 0.90)
    assert tavern.spar_win_chance(0) == pytest.approx(0.30)
    assert tavern.spar_win_chance(40) == pytest.approx(0.50)
    assert tavern.spar_win_chance(140) == pytest.approx(0.90)  # 1.0 clamped
    assert tavern.spar_win_chance(400) == pytest.approx(0.90)
    assert tavern.spar_win_chance(-200) == pytest.approx(0.10)  # formula low


def test_spar_bout_and_growth(store: DataStore) -> None:
    """A bout pays pot × 2 on a win, forfeits the stake on a loss, and
    every bout notes 3 swordplay usages — with swordplay's growth
    threshold 1 (skills.py), one bout immediately awards +1 skill
    (docs/50 §4.3)."""
    # Win: roll below the chance.
    fleet: list[Any] = []
    st = make_person(gold=1000, swordplay=0)
    result = tavern.spar(st, store, 100, 0.0)  # 0.0 < 0.30 → won
    assert result["won"] is True
    assert result["stake"] == 100
    assert result["chance"] == pytest.approx(0.30)
    assert result["uses"] == 3
    assert st.gold == 1000 - 100 + 200
    assert st.player["skills"]["swordplay"] == 1  # the §4.3 award fired
    assert st.player["skill_counters"]["swordplay"] == 0

    # Loss: roll at/above the chance.
    st = make_person(gold=1000, swordplay=0)
    result = tavern.spar(st, store, 100, 0.30)
    assert result["won"] is False
    assert st.gold == 900
    assert st.player["skills"]["swordplay"] == 1  # growth runs on losses too

    # Refusals leave the state untouched.
    st = make_person(gold=99)
    assert tavern.spar(st, store, 100, 0.0) == {}
    assert st.gold == 99
    st = make_person(gold=1000)
    assert tavern.spar(st, store, 150, 0.0) == {}  # off-step stake
    assert st.gold == 1000


# ===========================================================================
# Tavern — the Rumors tab (docs/70 §4.4; discovery.gd hints, GodotRng seam)
# ===========================================================================


def test_rumor_hints_pinned_seed(store: DataStore) -> None:
    """The seeded draw is deterministic per (port, day) and reproduces the
    oracle's exact hint ids (GodotRng, seed day×1000003 +
    port_ordinal×7919, randi_range per draw)."""
    lisbon_12 = tavern.hints(store, [], "lisbon", 12)
    assert len(lisbon_12) == tavern.HINTS_PER_VISIT == 3
    # The pinned draw (bit-exact PCG32 over the fame-sorted pool).
    assert lisbon_12 == ["disc_persepolis", "disc_sargasso",
                         "disc_atlas_cedars"]
    # Deterministic per (port, day); a different day draws differently, a
    # different port too.
    assert tavern.hints(store, [], "lisbon", 12) == lisbon_12
    assert tavern.hints(store, [], "lisbon", 13) != lisbon_12
    tunis_12 = tavern.hints(store, [], "tunis", 12)
    assert len(tunis_12) == 3
    assert tunis_12 == ["disc_andes_peaks", "disc_azores_whales",
                        "disc_patagonia"]
    # Found discoveries never appear; fewer than three remain → fewer rows.
    found = [str(entry["id"]) for entry in store.discoveries_list]
    assert tavern.hints(store, found, "lisbon", 12) == []
    partial = lisbon_12[:2]
    rows = tavern.hints(store, partial, "lisbon", 12)
    assert len(rows) == 3
    assert not set(partial) & set(rows)
    # Every row is a real discovery id.
    for discovery_id in lisbon_12:
        assert store.get_discovery(discovery_id)


def test_rumor_hint_purchase(store: DataStore) -> None:
    """100g per hint; the buy marks the hint and reveals the entry; the
    same hint cannot be bought twice; a short purse is refused."""
    hints_map: dict[str, Any] = {}
    st = make_person(gold=1000)
    discovery_id = tavern.hints(store, [], "lisbon", 12)[0]
    entry = tavern.buy_hint(store, st, hints_map, discovery_id)
    assert entry and entry["id"] == discovery_id
    assert st.gold == 900
    assert tavern.is_hinted(hints_map, discovery_id)
    # Re-buy refused, no further charge.
    assert tavern.buy_hint(store, st, hints_map, discovery_id) == {}
    assert st.gold == 900
    # Poor purse refused untouched.
    poor = make_person(gold=99)
    poor_map: dict[str, Any] = {}
    assert tavern.buy_hint(store, poor, poor_map, discovery_id) == {}
    assert poor.gold == 99 and not poor_map
    # Unknown id refused.
    assert tavern.buy_hint(store, st, hints_map, "disc_nowhere") == {}
    # The row text: the real region_hint L10n block (Phase 3 sells the
    # location and shows the rumour free).
    assert tavern.hint_text(store, discovery_id) \
        == store.get_discovery(discovery_id)["region_hint"]
    assert tavern.hint_text(store, "disc_nowhere") == {}


# ===========================================================================
# Inn — rest (tools/test_inn.gd §1–§2, docs/30 §4.7)
# ===========================================================================


def test_inn_constants(store: DataStore) -> None:
    assert inn.REST_DAYS == 3
    assert inn.REST_COST_PER_DAY == 10
    assert inn.REST_COST == 30
    assert inn.REST_WAKE_DAYS == 3
    assert inn.REST_WAKE_HOUR == 8
    assert inn.ODD_JOB_GOLD == 100
    assert inn.RELIEF_GOLD_THRESHOLD == CHEAPEST_HULL
    # The threshold IS the cheapest hull price on shipped data.
    assert int(store.get_ship_type("latin")["base_price"]) == CHEAPEST_HULL
    assert inn.REASON_HAS_SHIP == "inn.odd_job.has_ship"
    assert inn.REASON_NOT_BROKE == "inn.odd_job.not_broke"
    assert inn.REASON_OFFICERS == "inn.odd_job.officers"


def test_rest_cost_and_wake(store: DataStore) -> None:
    """The 30g up-front charge and the day + 3 @ 08:00 wake from any
    arrival fraction (docs/30 §4.7 amendment)."""
    st = make_person(gold=1000)
    st.day = 10
    world = {"position": {"x": 7, "y": 57}, "clock_fraction": 0.5}
    assert inn.can_rest(st)
    result = inn.rest(st, world)
    assert result is not None
    assert result.charged == 30
    assert st.gold == 970
    assert st.day == 13
    assert result.wake_day == 13
    assert result.wake_hour == 8
    assert world["clock_fraction"] == pytest.approx(8 / 24)
    # Δ = 10/3 − fraction, exact.
    assert result.delta_days == pytest.approx(3 + 8 / 24 - 0.5)

    # Any arrival fraction lands on the same wake point.
    for fraction in (0.0, 0.25, 0.9, 23 / 24):
        st = make_person(gold=1000)
        st.day = 10
        world = {"clock_fraction": fraction}
        result = inn.rest(st, world)
        assert result is not None
        assert st.day == 13
        assert result.wake_hour == 8
        assert result.delta_days == pytest.approx(3 + 8 / 24 - fraction)

    # Refused at 29g: state untouched.
    st = make_person(gold=29)
    st.day = 10
    world = {"clock_fraction": 0.5}
    assert not inn.can_rest(st)
    assert inn.rest(st, world) is None
    assert st.gold == 29 and st.day == 10
    assert world["clock_fraction"] == 0.5
    # Exactly 30g is affordable.
    assert inn.can_rest(make_person(gold=30))


def test_rest_orders_charge_before_ledger(store: DataStore) -> None:
    """The lodging is charged BEFORE the ledger day runs (the button's
    advertised total is charged up front), and the ledger seam receives
    exactly one advance_clock(Δ) call (docs/30 §4.7)."""
    st = make_person(gold=1000)
    st.day = 10
    world = {"clock_fraction": 0.0}
    calls: list[tuple[float, int]] = []

    def ledger(delta: float) -> None:
        # The sailing port's stand-in: ``advance_clock(Δ)`` from an
        # in-port arrival crosses exactly THREE day boundaries (the §4.7
        # pin), each paying the docked ledger day — 15 crew × 2g wages —
        # and applying the in-port morale +5/day capped at 80 (20-* §4.8.1;
        # the wage/morale rows are the ledger's own pinned content, cited
        # here only to prove the inn's ordering).
        calls.append((delta, st.gold))
        st.gold -= 3 * (15 * tavern.CREW_WAGE_DAILY)
        st.day += 3

    result = inn.rest(st, world, advance_clock=ledger)
    assert result is not None
    assert len(calls) == 1
    delta, gold_at_ledger = calls[0]
    assert delta == pytest.approx(3 + 8 / 24)
    # The lodging was already gone when the ledger ran.
    assert gold_at_ledger == 970
    # The composite split the T15 harness pins: 1000 − 30 lodging − 3×30
    # wages = 880 (the ledger's own pinned row, cited 20-* §4.5).
    assert st.gold == 1000 - inn.REST_COST - 3 * 30
    assert st.day == 13

    # The officer's wage rides the same ledger days (the inn adds nothing).
    st = make_person(gold=1000, officers=["off_mateus_alvares"])
    st.day = 10
    world = {"clock_fraction": 0.0}

    def ledger2(_delta: float) -> None:
        st.gold -= 3 * (15 * tavern.CREW_WAGE_DAILY
                        + character.officer_wages(st, store))
        st.day += 3

    inn.rest(st, world, advance_clock=ledger2)
    assert st.gold == 1000 - 30 - 3 * 60
    assert character.officer_count(st) == 1  # rest dismisses nobody


# ===========================================================================
# Inn — harbor relief (tools/test_inn.gd §3–§4b, docs/10 §5, docs/50 §4.7)
# ===========================================================================


def test_odd_job_condition_matrix(store: DataStore) -> None:
    """Each clause flips the gate; the reason order is fixed (no ship →
    purse → officers)."""
    # (a) With a ship: ineligible, whatever the purse.
    fleet = [make_ship(store, "caravel", CARAVEL_MIN)]
    st = make_person(gold=0)
    assert not inn.odd_job_eligible(fleet, st)
    assert inn.ineligible_reason(fleet, st) == inn.REASON_HAS_SHIP
    st = make_person(gold=50)
    assert inn.ineligible_reason(fleet, st) == inn.REASON_HAS_SHIP

    # (b) Shipless but able to buy the cheapest hull: ineligible (strict <).
    st = make_person(gold=CHEAPEST_HULL)
    assert not inn.odd_job_eligible([], st)
    assert inn.ineligible_reason([], st) == inn.REASON_NOT_BROKE
    st = make_person(gold=5000)
    assert not inn.odd_job_eligible([], st)
    # Just below the hull price is still eligible — the whole point.
    st = make_person(gold=CHEAPEST_HULL - 1)
    assert inn.odd_job_eligible([], st)
    assert inn.ineligible_reason([], st) == ""

    # (c) Shipless + broke but with an officer: the lockout wins.
    st = make_person(gold=0, officers=["off_mateus_alvares"])
    assert not inn.odd_job_eligible([], st)
    assert inn.ineligible_reason([], st) == inn.REASON_OFFICERS
    # (d) Dismissed → eligible.
    assert character.dismiss(st, "off_mateus_alvares")
    assert inn.odd_job_eligible([], st)
    assert inn.ineligible_reason([], st) == ""

    # (e) The all-clear boundary.
    st = make_person(gold=99)
    assert inn.odd_job_eligible([], st)
    assert inn.ineligible_reason([], st) == ""


def test_odd_job_effect_and_twelve_to_latin(store: DataStore) -> None:
    """+100g and +1 day per job, re-evaluated after each; from 0g exactly
    12 consecutive jobs reach the 1,200g latin and the 13th is refused
    (docs/10 §5 anti-softlock arithmetic)."""
    st = make_person(gold=0)
    st.day = 10
    fleet: list[Any] = []
    assert inn.work_odd_job(st, fleet)
    assert st.gold == 100 and st.day == 11
    # At 100g the offer must remain available (the amended threshold).
    assert inn.odd_job_eligible(fleet, st)
    assert inn.work_odd_job(st, fleet)
    assert st.gold == 200 and st.day == 12

    # The escape run: no purse reset, relief alone carries to a hull.
    st = make_person(gold=0)
    st.day = 10
    clicks = 0
    while inn.odd_job_eligible(fleet, st) and inn.work_odd_job(st, fleet):
        clicks += 1
    assert clicks == 12
    assert st.gold == CHEAPEST_HULL
    assert st.day == 10 + 12
    # The gate closes exactly at the hull price; a 13th click changes
    # nothing.
    assert not inn.odd_job_eligible(fleet, st)
    assert not inn.work_odd_job(st, fleet)
    assert st.gold == CHEAPEST_HULL and st.day == 22
    # And the earned purse covers the hull it exists to buy.
    assert st.gold >= int(store.get_ship_type("latin")["base_price"])


# ===========================================================================
# Palace — access & royal missions (tools/test_palace.gd §7–§10, 70-* §4.9.4)
# ===========================================================================


def test_mission_gate(store: DataStore) -> None:
    """Rep ≥ 30 at capitals only; one mission per nation; the bounty
    close-out."""
    run = make_run()
    st = make_person(gold=50000,
                     reputation={"portugal": 29, "spain": 0, "england": 0,
                                 "holland": 0, "ottoman": 0, "italy": 0})
    assert not palace.offers_missions(store, st, "lisbon")
    assert palace.offer(store, st, run, "lisbon", 1) == {}
    st.player["reputation"]["portugal"] = 30
    assert palace.offers_missions(store, st, "lisbon")
    assert palace.offer(store, st, run, "lisbon", 1)
    # A non-capital never offers and reports the reason key.
    assert palace.offer(store, st, run, "athens", 1) == {}
    assert palace.open_block_reason(store, "athens") == "palace.not_capital"
    assert palace.nation_of(store, "athens") == ""
    assert palace.nation_of(store, "lisbon") == "portugal"
    # One mission per nation at a time.
    accepted = palace.accept(store, st, run, "lisbon", 1)
    assert accepted
    assert palace.active_mission(run, store, "portugal")
    assert palace.offer(store, st, run, "lisbon", 2) == {}
    assert palace.accept(store, st, run, "lisbon", 2) == {}
    # A different nation is independent.
    st.player["reputation"]["spain"] = 40
    assert palace.offers_missions(store, st, "seville")
    assert not palace.active_mission(run, store, "spain")
    # A bountied nation's palace is shut unless the bounty is payable here.
    assert not palace.offers_missions(store, st, "lisbon", port_closed=True,
                                      can_pay_here=False)
    assert palace.open_block_reason(store, "lisbon", port_closed=True,
                                    can_pay_here=False) == "port.closed_bounty"
    assert palace.offers_missions(store, st, "lisbon", port_closed=True,
                                  can_pay_here=True)


def test_mission_kind_rotation(store: DataStore) -> None:
    """The rotation visits all three kinds over three month starts
    (70-* §4.9.4; the pure cycle sampled at 3 consecutive month starts)."""
    seen = {palace.offered_kind(store, "lisbon", day)
            for day in range(1, 91, 30)}
    assert len(seen) == 3
    assert seen == set(palace.KINDS)
    # Lisbon's months: patrol → chart → delivery (ordinal 4 of 6 nations).
    assert palace.offered_kind(store, "lisbon", 1) == "royal_patrol"
    assert palace.offered_kind(store, "lisbon", 31) == "royal_chart"
    assert palace.offered_kind(store, "lisbon", 61) == "royal_delivery"


def _royal_of_kind(store: DataStore, st: PersonState, run: dict[str, Any],
                   kind_fragment: str, delivery_stream=None) -> dict[str, Any]:
    """The first day whose offer is ``kind`` (the harness's closed-form
    month locator, tools/test_palace.gd ``_mission_of_kind``)."""
    for day in range(1, 91):
        if kind_fragment not in palace.offered_kind(store, "lisbon", day):
            continue
        run["active_quests"] = []
        candidate = palace.offer(store, st, run, "lisbon", day,
                                 delivery_stream)
        if candidate:
            return {"day": day, "offer": candidate}
    return {}


def test_patrol_accept_and_completion(store: DataStore) -> None:
    """Two victories complete a patrol: +8000g, +25 fame, +10 rep, +1
    mission; accepting spawned two tagged rival warships."""
    run = make_run()
    run["fleet"] = []
    st = make_person(gold=50000,
                     reputation={"portugal": 40, "spain": 0, "england": 0,
                                 "holland": 0, "ottoman": 0, "italy": 0})
    mission = _royal_of_kind(store, st, run, "patrol")
    assert mission, "a royal_patrol month exists"

    def spawn(role: str, nation_id: str, day: int) -> dict[str, Any]:
        marker = {"id": f"npc_{len(run['npc_fleets'])}", "role": role,
                  "nation_id": nation_id}
        run["npc_fleets"].append(marker)
        return marker

    accepted = palace.accept_offer(store, st, run, "lisbon", mission["day"],
                                   mission["offer"], spawn_fleet=spawn)
    assert accepted
    requirements = accepted["requirements"]
    assert int(requirements["count"]) == palace.PATROL_COUNT == 2
    assert requirements["nation_id"] != "portugal"
    assert requirements["nation_id"] == "spain"  # portugal's first rival
    assert int(requirements.get("killed", 0)) == 0
    assert accepted["accepted_day"] == mission["day"]
    assert accepted["deadline_day"] == mission["day"] + 60
    tagged = [m for m in run["npc_fleets"]
              if m.get("quest_id") == accepted["instance_id"]]
    assert len(tagged) == 2
    for marker in tagged:
        assert marker["royal_mission"] is True
        assert marker["role"] == "privateer"
    assert accepted in run["active_quests"]

    gold_before, fame_before = st.gold, st.fame
    assert palace.on_patrol_kill(store, st, accepted, mission["day"]) == {}
    assert int(accepted["requirements"]["killed"]) == 1
    completed = palace.on_patrol_kill(store, st, accepted, mission["day"])
    assert completed
    assert st.gold == gold_before + palace.PATROL_GOLD == gold_before + 8000
    assert st.fame == fame_before + palace.ROYAL_FAME == fame_before + 25
    assert fame.royal_missions(st, "portugal") == 1
    assert character.reputation(st, "portugal") == 50  # 40 + 10
    assert accepted["status"] == "completed"
    # A completed mission cannot be credited twice.
    assert palace.on_patrol_kill(store, st, accepted, mission["day"]) == {}
    assert fame.royal_missions(st, "portugal") == 1


def test_chart_completion(store: DataStore) -> None:
    """Two reports complete a chart: +6000g and one mission."""
    run = make_run()
    st = make_person(gold=50000,
                     reputation={"portugal": 40, "spain": 0, "england": 0,
                                 "holland": 0, "ottoman": 0, "italy": 0})
    mission = _royal_of_kind(store, st, run, "chart")
    assert mission
    quest = palace.accept_offer(store, st, run, "lisbon", mission["day"],
                                mission["offer"])
    assert int(quest["requirements"]["count"]) == 2
    gold_before = st.gold
    assert palace.on_discovery_reported(store, st, quest,
                                        mission["day"]) == {}
    assert int(quest["requirements"]["reported"]) == 1
    assert palace.on_discovery_reported(store, st, quest, mission["day"])
    assert st.gold == gold_before + palace.CHART_GOLD == gold_before + 6000
    assert fame.royal_missions(st, "portugal") == 1


def test_delivery_offer_and_accept(store: DataStore) -> None:
    """royal_delivery = the guild delivery ×3 gold, +10 rep, +25 fame,
    expiry 30; the cargo rides the injected fleet hooks with the
    all-or-nothing rollback."""
    run = make_run()
    st = make_person(gold=50000,
                     reputation={"portugal": 40, "spain": 0, "england": 0,
                                 "holland": 0, "ottoman": 0, "italy": 0})
    guild_delivery = {
        "instance_id": "q_guild_x",
        "template_id": "qt_delivery_wine",
        "type": "delivery",
        "requirements": {"good_id": "wine", "quantity": 20,
                         "dest_port_id": "seville"},
        "rewards": {"gold": 500},
        "status": "active",
    }

    def stream(port_id: str, day: int) -> list[dict[str, Any]]:
        return [guild_delivery]

    mission = _royal_of_kind(store, st, run, "delivery", delivery_stream=stream)
    assert mission
    offer = mission["offer"]
    rewards = offer["rewards"]
    assert rewards["gold"] == 500 * palace.ROYAL_DELIVERY_GOLD_FACTOR == 1500
    assert rewards["fame"] == 25
    assert rewards["reputation"] == {"portugal": 10}
    assert offer["requirements"]["kind"] == "royal_delivery"
    assert offer["requirements"]["good_id"] == "wine"
    assert offer["requirements"]["quantity"] == 20
    assert offer["requirements"]["dest_port_id"] == "seville"
    assert offer["expiry_days"] == 30  # the guild delivery's expiry cap

    # Accept stores the cargo through the fleet hooks.
    run["fleet"] = [make_ship(store, "caravel", CARAVEL_MIN)]
    hold, fleet_free, add_goods, remove_goods = make_hold(120)
    quest = palace.accept_offer(store, st, run, "lisbon", mission["day"],
                                mission["offer"], fleet_free=fleet_free,
                                add_goods=add_goods, remove_goods=remove_goods)
    assert quest
    assert hold["cargo"]["wine"] == 20 and hold["free"] == 100
    assert quest in run["active_quests"]

    # A short hold refuses whole before storing (all-or-nothing): nothing
    # is appended and the cargo is untouched.
    run["active_quests"] = []
    hold["free"] = 10
    hold["cargo"] = {}
    assert palace.accept_offer(store, st, run, "lisbon", mission["day"],
                               mission["offer"], fleet_free=fleet_free,
                               add_goods=add_goods,
                               remove_goods=remove_goods) == {}
    assert hold["cargo"].get("wine", 0) == 0 and hold["free"] == 10
    assert run["active_quests"] == []

    # A PARTIAL store (the fleet handed back fewer units than asked) rolls
    # back exactly what was stored and refuses whole — the
    # palace_engine.gd:239-243 branch.
    hold["free"] = 100
    hold["cargo"] = {}
    run["active_quests"] = []
    removed: list[tuple[str, int]] = []

    def partial_add(good_id: str, qty: int) -> int:
        return qty // 2  # stores only half

    def tracking_remove(good_id: str, qty: int) -> int:
        removed.append((good_id, qty))
        hold["free"] += qty
        return qty

    assert palace.accept_offer(store, st, run, "lisbon", mission["day"],
                               mission["offer"], fleet_free=fleet_free,
                               add_goods=partial_add,
                               remove_goods=tracking_remove) == {}
    assert removed == [("wine", 10)]
    assert hold["free"] == 110
    assert run["active_quests"] == []

    # Without the fleet hooks a delivery month offers nothing acceptable.
    assert palace.offer(store, st, run, "lisbon", mission["day"]) == {}


def test_mission_completion_ladder_boundary(store: DataStore) -> None:
    """The §4.9.2 ceremony boundary via fame: both requirements at their
    exact values, one rung at a time; completing a mission only evaluates
    the ladder (docs/70 §4.9.4)."""
    st = make_person(gold=50000)
    nation = "portugal"
    # Fame for duke alone does not promote (0 missions).
    st.fame = 3000
    assert not fame.can_promote(st, nation)
    assert fame.grant(st, nation) == ""
    assert fame.title(st, nation) == "none"
    for rank, need_fame, need_missions in (
            ("knight", 100, 1), ("baron", 300, 2), ("viscount", 700, 3),
            ("count", 1500, 5), ("duke", 3000, 8)):
        # Fame short by one: still no. Missions short by one: still no.
        st.fame = need_fame - 1
        st.completed_royal_missions[nation] = need_missions
        assert not fame.can_promote(st, nation)
        st.fame = need_fame
        st.completed_royal_missions[nation] = need_missions - 1
        assert not fame.can_promote(st, nation)
        # Both exactly met: grant, one step.
        st.completed_royal_missions[nation] = need_missions
        assert fame.can_promote(st, nation)
        assert fame.next_rank(st, nation) == rank
        assert fame.grant(st, nation) == rank
        assert fame.title(st, nation) == rank
    assert fame.next_rank(st, nation) == ""
    assert fame.grant(st, nation) == ""  # never regresses
    assert fame.is_duke(st, nation)


def test_mission_failure_tick(store: DataStore) -> None:
    """Expiry costs −10 rep with the giver nation, no fame, no mission
    credit; the deadline day itself does not fail (70-* §4.9.4)."""
    run = make_run()
    st = make_person(gold=50000,
                     reputation={"portugal": 40, "spain": 0, "england": 0,
                                 "holland": 0, "ottoman": 0, "italy": 0})
    guild_delivery = {
        "type": "delivery",
        "template_id": "qt_delivery_wine",
        "requirements": {"good_id": "wine", "quantity": 20,
                         "dest_port_id": "seville"},
        "rewards": {"gold": 500},
    }
    mission = _royal_of_kind(store, st, run, "delivery",
                             delivery_stream=lambda p, d: [guild_delivery])
    assert mission
    hold, fleet_free, add_goods, remove_goods = make_hold(120)
    quest = palace.accept_offer(store, st, run, "lisbon", mission["day"],
                                mission["offer"], fleet_free=fleet_free,
                                add_goods=add_goods, remove_goods=remove_goods)
    assert quest
    deadline = int(quest["deadline_day"])
    assert palace.tick(store, st, run, deadline) == []
    failed = palace.tick(store, st, run, deadline + 1)
    assert len(failed) == 1
    assert quest["status"] == "failed"
    assert quest["failed_day"] == deadline + 1
    assert character.reputation(st, "portugal") == 30  # 40 − 10
    assert fame.royal_missions(st, "portugal") == 0
    assert st.fame == 0


def test_ceremony_and_retirement(store: DataStore) -> None:
    """The ceremony is palace-bound and one hour; retirement is duke-gated
    (70-* §4.7)."""
    st = make_person(gold=50000)
    st.fame = 3000
    for nation in CAPITAL_NATIONS:
        st.completed_royal_missions[nation] = 8
    # Venice's palace promotes only italy; a non-capital has no ceremony.
    assert palace.attend_ceremony(store, st, "venice") == "knight"
    assert fame.title(st, "italy") == "knight"
    # A closed door refuses.
    assert palace.attend_ceremony(store, st, "seville", open_now=False) == ""
    # Spain's own ceremony grants its own first rank (per-nation ladders).
    assert palace.attend_ceremony(store, st, "seville") == "knight"
    assert fame.title(st, "spain") == "knight"
    assert fame.title(st, "portugal") == "none"
    assert not palace.can_retire(store, st, "seville")

    # Duke → the retire row exists; retiring marks the run once.
    st.titles["portugal"] = "duke"
    assert palace.can_retire(store, st, "lisbon")
    assert palace.can_retire(store, st, "seville") is False  # spain: knight
    run = make_run()
    assert palace.retire(store, st, run, "lisbon", now=1700000000)
    assert run["retired"] is True
    assert run["retired_at"] == 1700000000
    assert not palace.retire(store, st, run, "athens", now=1)


# ===========================================================================
# Palace — permits (tools/test_palace.gd §11, docs/30 §4.10)
# ===========================================================================


def test_permit_offer_matrix(store: DataStore) -> None:
    """Home charter at the player's own palaces, foreign permit elsewhere,
    nothing at non-capitals; the title/rep locks."""
    permits, _treasuries, _pending, _shown = make_allegiance()
    run = make_run()
    st = make_person(gold=100000)
    row = palace.permit_offer(store, st, run, permits, "lisbon")
    assert row["kind"] == "home"
    assert row["price"] == 5000
    assert row["title_locked"] is False and row["rep_locked"] is False
    assert row["coverage_key"] == "palace.permit.home.coverage"
    assert row["void_key"] == ""
    assert row["owned"] is False
    assert palace.permit_offer(store, st, run, permits, "madeira") == {}
    foreign = palace.permit_offer(store, st, run, permits, "london")
    assert foreign["kind"] == "foreign"
    assert foreign["price"] == 20000
    assert foreign["nation_id"] == "england"
    assert foreign["title_locked"] is True  # a commoner
    assert foreign["rep_locked"] is True  # rep 0 < 20
    assert foreign["coverage_key"] == "palace.permit.foreign.coverage"


def test_permit_buy_void_rebuy_matrix(store: DataStore) -> None:
    """Buy → held → re-buy refused; void by bounty or rep < −20 → a
    full-price re-buy; the treasury credit (decision 19)."""
    permits, treasuries, _pending, _shown = make_allegiance()
    run = make_run()
    st = make_person(gold=100000)
    portugal_start = treasuries["portugal"]

    assert palace.buy_permit(store, st, run, permits, treasuries, "lisbon")
    assert st.gold == 100000 - 5000
    assert palace.has_permit_home(permits)
    assert treasuries["portugal"] == portugal_start + 5000
    row = palace.permit_offer(store, st, run, permits, "lisbon")
    assert row["owned"] is True
    # Re-buying a held charter is refused and no gold moves.
    gold_before = st.gold
    assert not palace.buy_permit(store, st, run, permits, treasuries,
                                 "lisbon")
    assert st.gold == gold_before

    # Void while a bounty stands: the row shows it and a re-buy is allowed
    # at the full price (docs/30 §4.10).
    run["bounties"]["portugal"] = {"amount": 5000, "day": 1}
    row = palace.permit_offer(store, st, run, permits, "lisbon")
    assert row["void_key"] == "palace.permit.void_bounty"
    gold_before = st.gold
    assert palace.buy_permit(store, st, run, permits, treasuries, "lisbon")
    assert st.gold == gold_before - 5000
    run["bounties"] = {}
    # Void below −20 reputation as well.
    character.add_reputation(st, "portugal", -41)  # +20 → −21
    row = palace.permit_offer(store, st, run, permits, "lisbon")
    assert row["void_key"] == "palace.permit.void_rep"
    character.add_reputation(st, "portugal", 21)  # back to 0
    assert palace.permit_offer(store, st, run, permits,
                               "lisbon")["void_key"] == ""


def test_permit_foreign_gates(store: DataStore) -> None:
    """The foreign permit needs knight + rep ≥ 20 + the purse; the sale
    credits england's treasury."""
    permits, treasuries, _pending, _shown = make_allegiance()
    run = make_run()
    st = make_person(gold=50000)
    england_start = treasuries["england"]

    assert not palace.buy_permit(store, st, run, permits, treasuries,
                                 "london")  # commoner at rep 0
    character.add_reputation(st, "england", 19)
    assert not palace.buy_permit(store, st, run, permits, treasuries,
                                 "london")  # rep +19 still locked
    character.add_reputation(st, "england", 1)  # rep +20 exactly
    assert not palace.buy_permit(store, st, run, permits, treasuries,
                                 "london")  # still no knight title
    st.titles["england"] = "knight"
    row = palace.permit_offer(store, st, run, permits, "london")
    assert row["title_locked"] is False and row["rep_locked"] is False
    st.gold = 19999
    assert not palace.buy_permit(store, st, run, permits, treasuries,
                                 "london")
    st.gold = 20000
    gold_before = st.gold
    assert palace.buy_permit(store, st, run, permits, treasuries, "london")
    assert st.gold == gold_before - 20000
    assert palace.has_permit_foreign(permits, "england")
    assert treasuries["england"] == england_start + 20000
    assert palace.permit_offer(store, st, run, permits, "london")["owned"]

    # A closed-door audience refuses whole.
    permits2, treasuries2, _p2, _s2 = make_allegiance()
    st2 = make_person(gold=50000)
    st2.titles["england"] = "knight"
    character.add_reputation(st2, "england", 20)
    assert not palace.buy_permit(store, st2, make_run(), permits2,
                                 treasuries2, "london", open_now=False)
    assert st2.gold == 50000


def test_permit_negotiation_discounts(store: DataStore) -> None:
    """The §4.10 negotiation gates: home 5,000 → 4,750 at negotiation ≥ 40,
    foreign 20,000 → 18,000 at ≥ 70 (thresholds from
    ``data/skill_gates.json``; the exact products 5000×95/100 and
    20000×90/100)."""
    permits, _t, _p, _s = make_allegiance()
    run = make_run()
    st = make_person(gold=100000, negotiation=39)
    assert palace.permit_offer(store, st, run, permits, "lisbon")["price"] \
        == 5000
    st.player["skills"]["negotiation"] = 40
    assert palace.permit_offer(store, st, run, permits, "lisbon")["price"] \
        == 4750
    st.player["skills"]["negotiation"] = 69
    assert palace.permit_offer(store, st, run, permits, "london")["price"] \
        == 20000
    st.player["skills"]["negotiation"] = 70
    assert palace.permit_offer(store, st, run, permits, "london")["price"] \
        == 18000
    # The discounted home charter actually buys at 4,750.
    st.player["skills"]["negotiation"] = 40
    permits2, treasuries2, _p2, _s2 = make_allegiance()
    st2 = make_person(gold=100000, negotiation=40)
    assert palace.buy_permit(store, st2, make_run(), permits2, treasuries2,
                             "lisbon")
    assert st2.gold == 100000 - 4750


# ===========================================================================
# Palace — the commendation hook (docs/70 §4.1; 80-* §4.7.13)
# ===========================================================================


def test_commendation_pull_model(store: DataStore) -> None:
    """Queued at the player's own palaces only; dismissed once."""
    permits, _t, pending, shown = make_allegiance()
    run = make_run()
    st = make_person(gold=50000)  # portugal
    assert palace.pending_commendation(store, st, pending, shown,
                                       "lisbon") == {}
    # A contestable port flips to portugal → the queue holds it.
    pending.append("quanzhou")
    row = palace.pending_commendation(store, st, pending, shown, "lisbon")
    assert row == {"port_id": "quanzhou", "nation_id": "portugal"}
    # A foreign palace plays nothing.
    assert palace.pending_commendation(store, st, pending, shown,
                                       "london") == {}
    # Dismissal consumes it once.
    palace.dismiss_commendation(pending, shown)
    assert palace.pending_commendation(store, st, pending, shown,
                                       "lisbon") == {}
    assert shown == {"quanzhou": True}
    # A nationless run plays nothing anywhere.
    nobody = make_person()
    nobody.player["nation_id"] = ""
    pending.append("malacca")
    assert palace.pending_commendation(store, nobody, pending, shown,
                                       "lisbon") == {}


# ===========================================================================
# Tournament (tools/test_tournament.gd, 70-* §4.6/§4.9.7)
# ===========================================================================


def test_tournament_rotation_and_cycles(store: DataStore) -> None:
    assert palace.CYCLE_DAYS == 30
    assert palace.capitals(store) == CAPITALS
    assert palace.cycle_of(1) == 0
    assert palace.cycle_of(30) == 0
    assert palace.cycle_of(31) == 1
    assert palace.day_of_cycle(1) == 1
    assert palace.day_of_cycle(30) == 30
    assert palace.day_of_cycle(31) == 1
    hosts = [palace.host(store, cycle * 30 + 1) for cycle in range(6)]
    assert hosts == CAPITALS
    assert palace.host(store, 180 + 1) == CAPITALS[0]
    assert palace.host(store, 61) == "london"


def test_tournament_entry_window_and_status(store: DataStore) -> None:
    """The window is exactly cycle days 1–5; status reasons."""
    run = make_run()
    st = make_person(gold=50000)
    open_days = [day for day in range(1, 31) if palace.in_entry_window(day)]
    assert open_days == [1, 2, 3, 4, 5]
    assert palace.in_entry_window(31)
    assert not palace.in_entry_window(36)

    status = palace.status(store, st, run, "lisbon", 3)
    assert status["open"] is True
    assert status["host"] == "lisbon"
    assert status["window_first"] == 1 and status["window_last"] == 5
    assert status["fee"] == 1000
    assert status["round_hulls"] == ["brigantine", "carrack", "galleon"]

    late = palace.status(store, st, run, "lisbon", 7)
    assert late["open"] is False and late["blocked"] == "tournament.closed"
    elsewhere = palace.status(store, st, run, "seville", 3)
    assert elsewhere["open"] is False
    assert elsewhere["blocked"] == "tournament.not_host"
    assert elsewhere["window_first"] == 1  # a non-host still learns the window
    # A bountied host refuses entry.
    bountied = palace.status(store, st, run, "lisbon", 3, port_closed=True)
    assert bountied["blocked"] == "tournament.blocked_bounty"
    # A short purse reports market.no_gold.
    poor = make_person(gold=999)
    assert palace.status(store, poor, run, "lisbon", 3)["blocked"] \
        == "market.no_gold"


def test_tournament_entry(store: DataStore) -> None:
    """The 1,000g fee, one entry per cycle, the fresh next cycle."""
    run = make_run()
    st = make_person(gold=5000)
    assert palace.enter(store, st, run, "lisbon", 2)
    assert st.gold == 4000
    assert palace.already_entered(run, 2)
    again = palace.status(store, st, run, "lisbon", 2)
    assert again["open"] is False and again["blocked"] == "tournament.entered"
    assert not palace.enter(store, st, run, "lisbon", 2)
    assert st.gold == 4000
    assert not palace.already_entered(run, 31)
    # A closed door charges nothing.
    run2 = make_run()
    st2 = make_person(gold=5000)
    assert not palace.enter(store, st2, run2, "lisbon", 2, open_now=False)
    assert st2.gold == 5000
    assert not palace.already_entered(run2, 2)


def test_tournament_round_fleets(store: DataStore) -> None:
    """The bracket shape: one hull per round — brigantine → carrack →
    galleon, at full durability, crew_min crew, armament_slots cannons."""
    assert palace.ROUND_HULLS == ("brigantine", "carrack", "galleon")
    assert palace.ROUNDS == 3
    for round_number, hull in ((1, "brigantine"), (2, "carrack"),
                               (3, "galleon")):
        ships = palace.round_fleet(store, round_number)
        assert len(ships) == 1
        ship = ships[0]
        ship_type = store.get_ship_type(hull)
        assert ship["ship_type_id"] == hull
        assert ship["durability"] == ship_type["durability"]
        assert ship["crew"] == ship_type["crew_min"]
        assert ship["cannons"] == ship_type["armament_slots"]
    # The encounter descriptor: tournament kind (no reputation deltas),
    # id tagged tournament_<cycle>_<round>.
    block = palace.encounter(store, 2, 40)
    assert block["kind"] == "tournament"
    assert block["nation_id"] == ""
    assert block["id"] == "tournament_1_2"
    assert block["ships"] == palace.round_fleet(store, 2)
    # Round clamps: 0 → the first hull, 4 → the last.
    assert palace.round_fleet(store, 0)[0]["ship_type_id"] == "brigantine"
    assert palace.round_fleet(store, 4)[0]["ship_type_id"] == "galleon"


def test_tournament_winner_payout(store: DataStore) -> None:
    """Win all three: 10,000g + 100 fame, nothing repaired."""
    run = make_run()
    st = make_person(gold=1000)
    st.fame = 50
    outcome = palace.settle(store, st, run, True, 0)
    assert outcome["won"] is True
    assert outcome["gold"] == 10000
    assert outcome["fame"] == 100
    assert outcome["repaired"] == 0
    assert outcome["round_reached"] == 0
    assert st.gold == 11000
    assert st.fame == 150


def test_tournament_loser_payout_and_repair(store: DataStore) -> None:
    """Lose any round: 500g, no fame, the free repair to half."""
    for round_reached in (1, 2, 3):
        run = make_run()
        ship = make_ship(store, "galleon", 40)
        run["fleet"] = [ship]
        st = make_person(gold=1000)
        st.fame = 50
        max_durability = int(ship["durability"])
        ship["durability"] = 1
        outcome = palace.settle(store, st, run, False, round_reached)
        assert outcome["won"] is False
        assert outcome["gold"] == 500
        assert outcome["fame"] == 0
        assert outcome["round_reached"] == round_reached
        assert outcome["repaired"] > 0
        assert ship["durability"] == -(-max_durability // 2)  # ceil(max/2)
        assert st.gold == 1500
        assert st.fame == 50


def test_repair_to_half_rules(store: DataStore) -> None:
    """max(current, ceil(effective_max × 0.5)), free, never a pull-down —
    and the figurehead's durability modifier raises the effective max
    (§4.12.4)."""
    run = make_run()
    ship = make_ship(store, "galleon", 40)
    run["fleet"] = [ship]
    st = make_person(gold=777)
    max_durability = int(ship["durability"])
    half = -(-max_durability // 2)  # ceil(max × 0.5)

    ship["durability"] = max_durability
    assert palace.repair_to_half(store, run["fleet"]) == 0
    assert ship["durability"] == max_durability
    ship["durability"] = half
    assert palace.repair_to_half(store, run["fleet"]) == 0
    ship["durability"] = 1
    assert palace.repair_to_half(store, run["fleet"]) == half - 1
    assert ship["durability"] == half
    assert st.gold == 777  # the consolation repair costs nothing

    # A mermaid figurehead (+10 durability) lifts the floor.
    ship["equipment"] = {"figurehead": "eq_mermaid_figurehead", "sail": ""}
    ship["durability"] = 1
    effective_half = -(-(max_durability + 10) // 2)
    restored = palace.repair_to_half(store, run["fleet"])
    assert restored == effective_half - 1
    assert ship["durability"] == effective_half


class _ScriptedBout:
    """The combat seam's stand-in: a built 'screen' answering
    ``run_to_completion()`` with a scripted §4.11.9 result string."""

    def __init__(self, result: str, damage: int = 0) -> None:
        self._result = result
        self._damage = damage

    def run_to_completion(self) -> dict[str, Any]:
        return {"result": self._result}


def test_tournament_bracket_run(store: DataStore) -> None:
    """The bracket arrangement on a scripted builder: three victories take
    the prize; any non-victory settles the consolation at the bout it was
    lost; an unbuilt bout (None) is a bout-1 loss."""
    # The clean sweep.
    run = make_run()
    ship = make_ship(store, "galleon", 120)
    ship["cannons"] = 24
    run["fleet"] = [ship]
    st = make_person(gold=1000)
    st.fame = 0
    bouts = ["victory", "victory", "victory"]
    outcomes = iter(bouts)

    def builder(encounter: dict[str, Any]) -> _ScriptedBout:
        assert encounter["kind"] == "tournament"
        assert encounter["id"].startswith("tournament_")
        assert len(encounter["ships"]) == 1
        return _ScriptedBout(next(outcomes))

    won = palace.run_bracket(store, st, run, builder, 2)
    assert won["won"] is True
    assert won["results"] == ["victory", "victory", "victory"]
    assert won["gold"] == 10000 and won["fame"] == 100
    assert won["round_reached"] == 0
    assert st.gold == 11000 and st.fame == 100

    # A bout-2 loss settles immediately with the consolation; the 500g +
    # half-repair ride the same run state. The builder's write-back carries
    # heavy damage (below half) so the consolation repair has work to do.
    run = make_run()
    ship = make_ship(store, "galleon", 120)
    ship["cannons"] = 24
    run["fleet"] = [ship]
    st = make_person(gold=1000)
    max_durability = int(ship["durability"])
    results = iter(["victory", "stall"])

    def builder2(encounter: dict[str, Any]) -> _ScriptedBout:
        bout = next(results)
        ship["durability"] = max(1, ship["durability"] - 70)  # carry damage
        return _ScriptedBout(bout)

    lost = palace.run_bracket(store, st, run, builder2, 2)
    assert lost["won"] is False
    assert lost["results"] == ["victory", "stall"]
    assert lost["round_reached"] == 2
    assert lost["gold"] == 500 and lost["fame"] == 0
    assert lost["repaired"] == -(-max_durability // 2) \
        - (max_durability - 140)  # 120 − 100: the carried damage lifts
    assert st.gold == 1500
    assert ship["durability"] == -(-max_durability // 2)

    # No battle could be built → the bracket is lost at bout 1.
    run = make_run()
    st = make_person(gold=1000)
    none_outcome = palace.run_bracket(store, st, run,
                                      lambda encounter: None, 2)
    assert none_outcome["won"] is False
    assert none_outcome["results"] == []
    assert none_outcome["round_reached"] == 1
    assert none_outcome["gold"] == 500
