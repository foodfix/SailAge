"""M3 contract suite: the screen-projection channel (``GET /api/view/<id>``).

Normative contract: ``docs/90-ARCHITECTURE.md`` §0.4 — the
"no-rules-in-TS" channel. Each test boots one real ``new_game("portugal")``
run (docked at Lisbon) and spot-pins the projection against the owning sim
function's closed form (``server.sim.port.*`` / ``server.sim.world.*``) —
never a re-derivation of a rule (those live in the M1 suites).

Everything is deterministic: the ``state`` snapshot is a fixed new-game
state, the sim tick does not advance while docked, and every expected value
is read through the same owning module function the view calls.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from starlette.testclient import TestClient

from server import save
from server.app import create_app
from server.sim import fleet as fleet_lib
from server.sim.player import character, fame, skills
from server.sim.port import allegiance, economy, inn, palace, shipyard, tavern, trade
from server.sim.quests import bounty, quest_gen
from server.sim.world import sailing

PORT = "lisbon"
NATION = "portugal"
ERROR_KEYS = {"code", "msg"}


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    """One isolated app + game per test; saves under ``tmp_path``."""
    monkeypatch.setenv(save.ENV_HOME, str(tmp_path))
    app = create_app()
    with TestClient(app) as test_client:
        yield test_client


def _session(client: TestClient) -> Any:
    return client.app.state.session


def _new_game(client: TestClient) -> None:
    response = client.post("/api/new_game", json={
        "nation_id": NATION,
        "background_id": "background_deckhand",
        "attr_alloc": {},
        "skill_alloc": {},
    })
    assert response.status_code == 200, response.text
    assert response.json()["ok"] is True
    assert response.json()["port_id"] == PORT


def _view(client: TestClient, screen: str) -> dict[str, Any]:
    response = client.get(f"/api/view/{screen}")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["ok"] is True, body
    assert body["screen"] == screen
    return body["views"]


def _stock(session: Any, port_id: str, good_id: str) -> int:
    return economy.stock_of(
        session.gs, session.store, port_id, good_id,
        dev_of=lambda pid: allegiance.dev(session.store, session.gs, pid))


# --- The eight projections ----------------------------------------------------


def test_port_projection_facility_cards(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "port")
    facilities = session.store.get_port(PORT)["facilities"]

    assert view["portId"] == PORT
    assert view["nationId"] == NATION
    ids = [row["id"] for row in view["facilities"]]
    assert ids == ["market", "shipyard", "tavern", "inn", "guild", "palace"]
    by_id = {row["id"]: row for row in view["facilities"]}
    assert by_id["market"]["phase"] == 1
    assert by_id["shipyard"]["phase"] == 1  # the stock-list payload counts as 1
    assert by_id["guild"]["phase"] == 3
    assert by_id["palace"]["phase"] == 3

    # New games start at day 1 00:00: the inn (24h) is open, the rest closed.
    for facility in ("market", "shipyard", "tavern", "guild", "palace"):
        assert sailing.facility_open(
            session.store, session.gs, PORT, facility) is False
        row = by_id[facility]
        assert row["enabled"] is False
        assert row["status"]["kind"] == "closed"
        window = sailing.facility_window_text(session.store, PORT, facility)
        assert row["status"]["open"] == window["open"]
        assert row["status"]["close"] == window["close"]
    assert by_id["inn"]["enabled"] is True
    assert by_id["inn"]["status"] == {"kind": "always"}

    # Rest to day 4 08:00 opens the working-day facilities.
    assert client.post("/api/inn/rest", json={}).json()["ok"] is True
    reopened = {row["id"]: row for row in _view(client, "port")["facilities"]}
    assert reopened["market"]["enabled"] is True
    assert reopened["market"]["status"]["kind"] == "open"
    assert reopened["tavern"]["enabled"] is False  # opens at 10:00
    assert reopened["palace"]["enabled"] is False  # opens at 09:00


def test_market_projection_prices_match_trade(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "market")
    assert view["portId"] == PORT

    # Listing rule: produce ∪ demand, specialty rows first in display order.
    listed = [str(good["id"]) for good in trade.goods_rows(PORT)]
    assert {row["goodId"] for row in view["rows"]} == set(listed)
    produced = set(session.store.get_port(PORT)["produces"])
    assert view["specialtyGoodIds"] == list(session.store.get_port(PORT)["produces"])
    first_non_specialty = next(i for i, row in enumerate(view["rows"])
                               if not row["specialty"])
    assert all(row["specialty"] for row in view["rows"][:first_non_specialty])
    assert not any(row["specialty"] for row in view["rows"][first_non_specialty:])

    invested = trade.invested(session.gs.port_investments, PORT)
    for row in view["rows"]:
        good_id = row["goodId"]
        stock = _stock(session, PORT, good_id)
        assert row["stock"] == stock
        assert row["marginal"] == trade.buy_price(PORT, good_id, stock,
                                                  invested_gold=invested)
        assert row["buyPrice"] == trade.buy_price(
            PORT, good_id, stock, invested_gold=invested)
        assert row["sellPrice"] == trade.sell_price(
            PORT, good_id, stock, invested_gold=invested,
            title_units=trade.title_units_from_bonus(
                fame.title_bonus(session.gs, NATION)))
        assert row["owned"] == fleet_lib.held(session.gs.fleet, good_id)
        assert row["notBought"] is (not trade.port_buys_good(PORT, good_id))
        assert row["specialty"] is (good_id in produced)

    # Spot-pin the two named rows: wheat is demanded (draining), wine produced
    # at capacity (flat at day 1; the new-game producer starts full).
    wheat = next(row for row in view["rows"] if row["goodId"] == "wheat")
    wine = next(row for row in view["rows"] if row["goodId"] == "wine")
    assert wheat["trend"] == "down"
    assert wine["trend"] == "flat"
    assert wheat["notBought"] is False
    assert wine["notBought"] is True

    # Tax badge / rates (aligned home port → 5%, mille 500).
    assert view["taxBadge"] == "in_sphere"
    assert view["taxRatePct"] == 5
    assert view["investAmount"] == trade.INVEST_CHUNK == 500
    assert view["investedGold"] == 0
    assert view["investedPct"] == trade.investment_percent(0) == 0
    assert view["investCapPct"] == 10
    assert view["investGate"]["kind"] == "ok"


def test_provisions_projection_supply_table_and_gate(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "provisions")
    assert view["portId"] == PORT

    # The pinned §4.10 supply price table: provisions 2g, water 1g.
    assert view["provisions"]["price"] == trade.supplies_price(
        "provisions") == 2
    assert view["water"]["price"] == trade.supplies_price("water") == 1
    assert view["provisions"]["qty"] == fleet_lib.supplies(
        session.gs.fleet, "provisions") == 0
    assert view["water"]["qty"] == fleet_lib.supplies(
        session.gs.fleet, "water") == 0
    assert view["provisions"]["days"] == sailing.kind_supply_days(
        session.gs, "provisions") == 0
    assert view["days"] == sailing.fleet_supply_days(session.gs) == 0
    assert view["gateReasonKey"] == sailing.supply_block_reason(session.gs)
    assert view["gateReasonKey"] == "port.sail.no_supply"
    assert view["holdCapacity"] == fleet_lib.fleet_capacity(session.gs.fleet)
    assert view["holdFree"] == fleet_lib.fleet_free(session.gs.fleet)
    assert view["holdUsed"] == (
        view["holdCapacity"] - view["holdFree"])
    assert view["daysBarMax"] == 10
    assert view["daysGoodMin"] == 10
    assert view["daysWarnMin"] == 3
    assert "shortWarningDays" not in view  # 0 days is the "no supply" gate
    assert view["cargo"] == []
    # A zero-supply prompt can buy, so the fill plan is not empty.
    assert view["fillBlocked"] is False


def test_shipyard_projection_stock_states_and_repairs(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "shipyard")
    assert view["portId"] == PORT

    expected_ids = shipyard.shipyard_stock(PORT)
    assert [row["shipTypeId"] for row in view["catalog"]] == expected_ids
    for row in view["catalog"]:
        ship_type_id = row["shipTypeId"]
        assert row["price"] == shipyard.buy_price(ship_type_id)
        assert row["rowState"] == shipyard.row_state(
            PORT, ship_type_id, session.allegiance_view)
        reason = shipyard.buy_block_reason(
            ship_type_id, current_port=PORT, fleet_size=len(session.gs.fleet),
            gold=session.gs.gold, allegiance=session.allegiance_view)
        assert row["canBuy"] is (not reason)
        if reason:
            assert row["requirementKey"] == reason
    caravel = next(row for row in view["catalog"]
                   if row["shipTypeId"] == "caravel")
    assert caravel["rowState"] == "available"
    assert caravel["canBuy"] is False
    assert caravel["requirementKey"] == "shipyard.no_gold"
    # Lisbon is dev 3: every stocked tier fits, so no gray row exists here.
    assert all(row["rowState"] == "available" for row in view["catalog"])

    assert len(view["fleet"]) == 1
    ship = view["fleet"][0]
    hull = session.gs.fleet[0]
    title_discount, carpenter = session._repair_factors(PORT)
    assert ship["index"] == 0
    assert ship["shipTypeId"] == hull["ship_type_id"] == "caravel"
    assert ship["durability"] == hull["durability"]
    assert ship["maxDurability"] == shipyard.ship_max_durability(
        session.gs.fleet, 0) == 90
    assert ship["canRepair"] is False  # full durability → 0 repairable points
    assert ship["maxRepairPoints"] == 0
    assert ship["repairCostPerPoint"] == shipyard.repair_cost(
        session.gs.fleet, 0, 1, title_repair_discount=title_discount,
        carpenter_discount=carpenter) == 20
    assert ship["canSell"] is False  # the only hull is the flagship
    assert ship["sellReasonKey"] == "shipyard.no_sell_last"

    # Equipment stock rows carry the §4.7.12 state + the equip price.
    slots = view["equipmentSlots"]
    player_weapon = next(row for row in slots
                         if row["slot"] == "weapon" and row["shipIndex"] == -1)
    stock_ids = [str(item) for item in shipyard.equipment_stock(PORT)]
    assert {item["equipmentId"] for item in player_weapon["items"]} <= set(
        stock_ids)
    for item in player_weapon["items"]:
        assert item["price"] == shipyard.equip_price("weapon",
                                                     item["equipmentId"])
        assert item["rowState"] == shipyard.row_state(
            PORT, item["equipmentId"], session.allegiance_view)
    assert view["equipment"]["weapon"] == ""


def test_inn_projection_rest_and_odd_job(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "inn")
    assert view["rest"]["days"] == inn.REST_DAYS == 3
    assert view["rest"]["price"] == inn.REST_COST == 30
    assert view["rest"]["canRest"] is inn.can_rest(session.gs)
    assert view["moraleTier"] == "good"  # new-game morale 70 ≥ 40
    assert view["moraleMax"] == 100
    assert view["oddJob"]["eligible"] is False
    assert view["oddJob"]["reasonKey"] == inn.ineligible_reason(
        session.gs.fleet, session.gs) == "inn.odd_job.has_ship"
    assert view["captains"] == []


def test_guild_projection_offers_and_reports(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "guild")
    assert view["portId"] == PORT
    assert view["offersRefreshDay"] == quest_gen.next_refresh_day(
        int(session.gs.day))
    day = int(session.gs.day)

    expected = quest_gen.available_offers(session.gs, PORT, day,
                                          session.world_view)
    assert expected, "a Lisbon guild always posts offers"
    assert [row["id"] for row in view["offers"]] == [
        str(offer.get("instance_id", "")) for offer in expected]
    for row, offer in zip(view["offers"], expected):
        rewards = offer.get("rewards", {})
        assert row["type"] == str(offer.get("type", ""))
        assert row["rewardGold"] == int(rewards.get("gold", 0))
        assert row["daysLeft"] == int(offer.get("expiry_days", 0))
        reason = quest_gen.accept_block_reason(session.gs, session.gs,
                                               offer, session.gs.fleet)
        assert row["canAccept"] is (not reason)
        if reason:
            assert row["reasonKey"] == reason
    delivery = view["offers"][0]
    assert delivery["lineKey"] == "quest.line.delivery"
    assert delivery["lineValues"]["good"]  # an L10nString name
    assert view["offersBlockedKey"] == ""
    assert view["active"] == []
    assert view["reports"] == []
    assert view["tournament"]


def test_palace_projection_permits_and_tournament(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "palace")
    gs = session.gs
    assert view["portId"] == PORT
    assert view["nationId"] == palace.nation_of(session.store, PORT) == NATION
    assert view["rank"] == fame.title(gs, NATION) == "none"
    assert view["nextRank"]["rank"] == fame.next_rank(gs, NATION)
    assert view["ceremonyAvailable"] is fame.can_promote(gs, NATION)
    assert view["repairAvailable"] is True

    negotiation = skills.effective_skill(gs, session.store, "negotiation")
    home = view["permits"]["home"]
    assert home["price"] == palace.permit_price(
        session.store, negotiation, "home") == 5000
    assert home["owned"] is False
    assert home["canBuy"] is True
    assert home["noteKey"] == "palace.permit.home.coverage"
    foreign = view["permits"]["foreign"]
    assert foreign["price"] == palace.permit_price(
        session.store, negotiation, "foreign") == 20000
    assert foreign["canBuy"] is False
    assert foreign["noteKey"] == "ui.not_available"  # not sold here

    status = palace.status(session.store, gs, session.run_view, PORT,
                           int(gs.day), bounty.is_port_closed(gs, PORT))
    tournament = view["tournament"]
    assert tournament["hostPortId"] == str(status["host"])
    assert tournament["firstDay"] == int(status["window_first"])
    assert tournament["lastDay"] == int(status["window_last"])
    assert tournament["entered"] is bool(status["entered"])
    assert tournament["canEnter"] is (bool(status["open"])
                                      and not bool(status["entered"]))
    assert tournament["prizeGold"] == palace.PRIZE_GOLD
    assert tournament["fame"] == palace.PRIZE_FAME
    assert view["board"] == []
    assert "bounty" not in view
    assert view["canRetire"] is False


def test_tavern_projection_crew_officers_and_rumors(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    view = _view(client, "tavern")
    gs = session.gs
    store = session.store
    assert view["portId"] == PORT

    # The locked §4.5 signing bonus: 2g/day × 10 days = 20g per head.
    assert view["crew"]["perHead"] == tavern.per_head() == 20
    assert view["crew"]["hireCost"] == tavern.hire_cost(1) == 20
    assert view["crew"]["count"] == tavern.crew(gs.fleet)
    assert view["crew"]["max"] == tavern.crew_max(store, gs.fleet)
    assert view["crew"]["min"] == tavern.crew_min(store, gs.fleet)
    open_now = sailing.facility_open(store, gs, PORT, "tavern")
    assert open_now is False  # day 1 00:00
    assert view["crew"]["canHire"] is (
        tavern.can_hire(store, gs.fleet, gs, 1) and open_now)
    assert view["crew"]["canFire"] is False

    assert [row["officerId"] for row in view["recruitable"]] == [
        str(officer) for officer in tavern.officers_at_port(store, gs, PORT)]
    for row in view["recruitable"]:
        assert row["wage"] == int(
            store.get_officer(row["officerId"]).get("wage_daily", 0))
        assert row["signingFee"] == character.recruit_cost(
            gs, store, row["officerId"])
    assert view["roster"] == []

    hints = tavern.hints(store, gs.discoveries_found, PORT, int(gs.day))
    purchasable = [row for row in view["rumors"]["rows"]
                   if row.get("purchasable")]
    assert [row["id"] for row in purchasable] == [str(h) for h in hints]
    assert view["rumors"]["price"] == tavern.HINT_PRICE == 100
    assert view["rumors"]["tournament"]
    assert view["spar"]["stake"] == tavern.SPAR_STAKE_MIN == 100
    assert view["spar"]["step"] == tavern.SPAR_STAKE_STEP == 100
    assert view["spar"]["winPct"] == int(round(tavern.spar_win_chance(
        skills.effective_skill(gs, store, "swordplay")) * 100.0))
    assert view["spar"]["canSpar"] is False  # closed tavern


# --- The channel's refusal matrix -------------------------------------------


def test_unknown_screen_is_a_404_refusal(client: TestClient) -> None:
    _new_game(client)
    response = client.get("/api/view/unknown")
    assert response.status_code == 404
    body = response.json()
    assert body["ok"] is False
    assert set(body["error"].keys()) == ERROR_KEYS
    assert body["error"]["code"] == "unknown_screen"
    assert body["error"]["msg"] == "error.unknown_screen"


def test_view_refuses_without_a_run_and_at_sea(client: TestClient) -> None:
    # No run: the no_run refusal (200 in-game refusal, §0.4 status semantics).
    response = client.get("/api/view/port")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert body["error"]["code"] == "no_run"

    _new_game(client)
    for kind in ("provisions", "water"):
        assert client.post("/api/provisions/buy_supplies",
                           json={"kind": kind, "qty": 10}).json()["ok"] is True
    assert client.post("/api/provisions/set_sail", json={}).json()["ok"] is True
    response = client.get("/api/view/market")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert body["error"]["code"] == "not_in_port"


def test_view_is_a_pure_read(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    before = client.get("/api/state").json()["state"]
    for screen in ("port", "market", "provisions", "shipyard", "inn",
                   "guild", "palace", "tavern"):
        _view(client, screen)
    after = client.get("/api/state").json()["state"]
    # A projection refresh never mutates the run (no familiarity accrual,
    # no commendation pop, no clock advance).
    assert after == before
