"""M2 contract suite: the FastAPI shell, WS protocol and save round-trip.

Normative contract: ``docs/90-ARCHITECTURE.md`` §0.3 (the frozen one-client
WS table), §0.4 (``POST /api/<facility>/<action>`` + the six fixed
endpoints), §0.5 (``SIM_TICK_HZ`` / ``WS_BROADCAST_HZ`` = 10,
``SAVE_VERSION`` = 1, the ``~/.sailage`` profile with the
``SAILAGE_HOME`` test seam).

The tests exercise the HTTP/WS contracts directly — never a re-derivation of
sim rules (those live in the M1 suites). Every profile write lands in a
per-test ``tmp_path`` (``SAILAGE_HOME``), never the real home.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import pytest
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from server import save
from server.app import create_app
from server.session import FACILITY_INVENTORY, SIM_TICK_HZ, WS_BROADCAST_HZ
from server.sim import fleet as fleet_lib
from server.sim.player import fame
from server.sim.port import shipyard, trade
from server.sim.world import npc_fleets
from server.sim.quests import bounty

#: The frozen facility inventory (the M2 record's table, §0.4; the M3
#: wiring appended the screen verbs that had no adapter yet).
EXPECTED_INVENTORY: dict[str, tuple[str, ...]] = {
    "market": ("buy", "sell", "invest"),
    "shipyard": ("buy", "repair", "sell", "refit", "equip", "unequip",
                 "promote"),
    "tavern": ("hire", "fire", "spar", "hint", "fill_crew", "down_to_min",
               "dismiss"),
    "inn": ("rest", "odd_job"),
    "guild": ("offers", "accept", "complete", "abandon", "report"),
    "palace": ("mission", "ceremony", "permit", "commend",
               "tournament_enter", "repair_fleet", "pay_bounty", "inform",
               "retire"),
    "provisions": ("set_sail", "buy_supplies", "fill", "jettison"),
    "people": ("inspect", "talk", "gift", "befriend", "attack", "hail",
               "appoint", "allocate"),
    "fleet": ("jettison", "promote"),
    "settings": ("npc_preset", "input_mode", "current_mode"),
}

#: The §0.3 hello frame keys, verbatim.
HELLO_KEYS = {"save_version", "tick_hz", "broadcast_hz", "locale", "has_run",
              "current_screen", "saves"}
#: The §0.3 tick frame keys, verbatim.
TICK_KEYS = {"day", "clock_min", "position", "heading", "sail_trim",
             "wind_dir", "weather", "speed", "gold", "morale", "autopilot",
             "contact_hint", "markers"}
#: The §0.3 tick.markers row shape (the §4.5.2 marker projection slice;
#: heading + ship_type ride since the 2026-11-14 NPC hull-token amendment).
TICK_MARKER_KEYS = {"id", "role", "nation_id", "cell", "sailing",
                    "heading", "ship_type", "wake"}
#: The §4.4 dir ids a marker row's ``heading`` may carry ("" when docked).
MARKER_HEADINGS = {"N", "NE", "E", "SE", "S", "SW", "W", "NW", ""}
#: §0.3 `tick.markers` radius (Chebyshev, wrap-aware on x).
MARKER_VIEW_RADIUS_TILES = 32
#: The §0.3 battle_tick frame keys, verbatim.
BATTLE_TICK_KEYS = {"round", "phase", "ships", "wind", "weather",
                    "orders_due"}
#: The §0.3 hello.saves entry shape.
SLOT_KEYS = {"slot", "day", "nation_id", "port_id", "gold", "saved_at"}
#: The frozen refusal shape (§0.4).
ERROR_KEYS = {"code", "msg"}


# --- Fixtures ---------------------------------------------------------------


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    """One isolated app + game per test; saves under ``tmp_path``."""
    monkeypatch.setenv(save.ENV_HOME, str(tmp_path))
    app = create_app()
    with TestClient(app) as test_client:
        yield test_client


def _session(client: TestClient) -> Any:
    return client.app.state.session


def _new_game(client: TestClient, nation_id: str = "portugal",
              background_id: str = "background_navy_cadet") -> dict[str, Any]:
    response = client.post("/api/new_game", json={
        "nation_id": nation_id,
        "background_id": background_id,
        "attr_alloc": {"constitution": 3, "courage": 2},
        "skill_alloc": {"navigation": 3},
    })
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["ok"] is True
    return body


def _rest(client: TestClient) -> None:
    """Rest to day + 3, 08:00 — the market/shipyard/guild windows open."""
    response = client.post("/api/inn/rest", json={})
    assert response.status_code == 200, response.text
    assert response.json()["ok"] is True


def _buy_supplies(client: TestClient) -> None:
    for kind in ("provisions", "water"):
        response = client.post("/api/provisions/buy_supplies",
                               json={"kind": kind, "qty": 10})
        assert response.status_code == 200, response.text
        assert response.json()["ok"] is True


def _set_sail(client: TestClient) -> None:
    _buy_supplies(client)
    response = client.post("/api/provisions/set_sail", json={})
    assert response.status_code == 200, response.text
    assert response.json()["ok"] is True


def _refusal(response: Any) -> dict[str, Any]:
    body = response.json()
    assert body["ok"] is False, body
    assert set(body["error"].keys()) == ERROR_KEYS, body
    assert isinstance(body["error"]["code"], str) and body["error"]["code"]
    assert isinstance(body["error"]["msg"], str) and body["error"]["msg"]
    return body


def _at_hour(client: TestClient, hour: int, minute: int = 0) -> None:
    """Pins the wall clock (a test fixture, not a rule re-derivation): the
    facility windows are the only reader of ``world.clock_fraction``."""
    _session(client).gs.world["clock_fraction"] = \
        (hour * 60 + minute) / 1440.0


def _view(client: TestClient, screen: str) -> dict[str, Any]:
    response = client.get(f"/api/view/{screen}")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["ok"] is True, body
    assert body["screen"] == screen
    return body["views"]


def _receive_until(ws: Any, frame_type: str, limit: int = 200
                   ) -> dict[str, Any]:
    """Reads frames until ``frame_type`` arrives (ticks interleave with
    state/event frames; the frozen table guarantees neither is dropped)."""
    for _ in range(limit):
        frame = ws.receive_json()
        if frame.get("type") == frame_type:
            return frame
    raise AssertionError(f"no {frame_type} frame in {limit} frames")


# --- (a) the six endpoints ---------------------------------------------------


def test_six_endpoints_happy_paths(client: TestClient) -> None:
    # GET /api/state — before any run.
    response = client.get("/api/state")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["hello"]["current_screen"] == "title"
    assert body["hello"]["save_version"] == save.SAVE_VERSION == 1
    assert body["hello"]["tick_hz"] == SIM_TICK_HZ == 10
    assert body["hello"]["broadcast_hz"] == WS_BROADCAST_HZ == 10

    # GET /api/saves — three empty slots.
    response = client.get("/api/saves")
    assert response.status_code == 200
    slots = response.json()["saves"]
    assert len(slots) == 3
    assert all(set(row.keys()) == SLOT_KEYS for row in slots)
    assert all(row["day"] == 0 for row in slots)

    # POST /api/new_game.
    created = _new_game(client)
    assert created["port_id"] == "lisbon"
    state = client.get("/api/state").json()["state"]
    assert state["player"]["nation_id"] == "portugal"
    assert state["day"] == 1 and state["gold"] > 0
    assert state["save_version"] == 1 and state["phase"] == "web"
    assert state["in_port"] is True
    assert client.get("/api/state").json()["hello"]["current_screen"] == "port"

    # POST /api/save + POST /api/load.
    response = client.post("/api/save", json={"slot": 1})
    assert response.status_code == 200 and response.json()["ok"] is True
    assert save.slot_path(1).is_file()
    response = client.post("/api/load", json={"slot": 1})
    assert response.status_code == 200 and response.json()["ok"] is True
    assert client.get("/api/saves").json()["saves"][0]["nation_id"] == "portugal"

    # POST /api/locale.
    response = client.post("/api/locale", json={"locale": "zh"})
    assert response.status_code == 200 and response.json()["ok"] is True
    assert client.get("/api/state").json()["state"]["locale"] == "zh"
    assert client.get("/api/state").json()["hello"]["locale"] == "zh"

    # Refusals hold the frozen shape (§0.4).
    _refusal(client.post("/api/new_game", json={"background_id": "x"}))
    _refusal(client.post("/api/locale", json={"locale": "fr"}))
    _refusal(client.post("/api/save", json={"slot": 9}))
    _refusal(client.post("/api/load", json={"slot": 3}))
    _refusal(client.post("/api/load", json={"slot": "two"}))


# --- (b) the save round-trip over HTTP --------------------------------------


def test_save_roundtrip_over_http(client: TestClient) -> None:
    _new_game(client)
    _rest(client)
    before = client.get("/api/state").json()["state"]

    bought = client.post("/api/market/buy", json={"good_id": "wheat", "qty": 2})
    assert bought.status_code == 200 and bought.json()["ok"] is True
    assert bought.json()["total"] > 0
    saved_state = client.get("/api/state").json()["state"]
    saved_gold = saved_state["gold"]
    saved_day = saved_state["day"]
    saved_stock = saved_state["market_stocks"]["lisbon"]["wheat"]
    assert saved_gold < before["gold"]

    response = client.post("/api/save", json={"slot": 2})
    assert response.status_code == 200 and response.json()["ok"] is True
    assert save.slot_path(2).is_file()
    payload = json.loads(save.slot_path(2).read_text(encoding="utf-8"))
    assert payload["save_version"] == 1 and payload["phase"] == "web"
    assert payload["day"] == saved_day and payload["gold"] == saved_gold

    # Mutate the live run, then restore slot 2.
    again = client.post("/api/market/buy", json={"good_id": "wheat", "qty": 3})
    assert again.status_code == 200 and again.json()["ok"] is True
    mutated = client.get("/api/state").json()["state"]
    assert mutated["gold"] < saved_gold

    loaded = client.post("/api/load", json={"slot": 2})
    assert loaded.status_code == 200 and loaded.json()["ok"] is True
    restored = client.get("/api/state").json()["state"]
    assert restored["gold"] == saved_gold
    assert restored["day"] == saved_day
    assert restored["market_stocks"]["lisbon"]["wheat"] == saved_stock
    assert restored["player"] == saved_state["player"]
    assert restored["fleet"] == saved_state["fleet"]


# --- (c) the frozen facility inventory --------------------------------------


def test_facility_inventory_frozen(client: TestClient) -> None:
    assert set(FACILITY_INVENTORY.keys()) == set(EXPECTED_INVENTORY.keys())
    assert dict(FACILITY_INVENTORY) == EXPECTED_INVENTORY
    for facility, actions in EXPECTED_INVENTORY.items():
        assert FACILITY_INVENTORY[facility] == actions


def test_every_inventory_action_refuses_without_a_run(client: TestClient
                                                      ) -> None:
    for facility, actions in EXPECTED_INVENTORY.items():
        for action in actions:
            response = client.post(f"/api/{facility}/{action}", json={})
            assert response.status_code < 500, (facility, action, response.text)
            _refusal(response)
    unknown = client.post("/api/market/nope", json={})
    assert unknown.status_code == 404
    _refusal(unknown)


# --- (d) the WS smoke -------------------------------------------------------


def test_ws_hello_state_tick_helm_error(client: TestClient) -> None:
    _new_game(client)
    _set_sail(client)
    start = client.get("/api/state").json()["state"]["world"]["position"]

    with client.websocket_connect("/ws") as ws:
        hello = ws.receive_json()
        assert hello["type"] == "hello"
        assert set(hello.keys()) - {"type"} == HELLO_KEYS
        assert hello["has_run"] is True
        assert hello["current_screen"] == "world"
        assert len(hello["saves"]) == 3

        state = ws.receive_json()
        assert state["type"] == "state"
        assert state["in_port"] is False
        assert "pending_encounter" in state and "npc_port_log" in state
        assert "pending_levelup" in state

        # A tick frame arrives while the run is live at sea (~10 Hz).
        started = time.monotonic()
        tick = _receive_until(ws, "tick", limit=20)
        assert time.monotonic() - started < 1.0
        assert TICK_KEYS <= set(tick.keys())
        assert tick["position"]["x"] == start["x"]

        # §0.3 tick.markers: every row is the frozen shape, within the
        # frozen radius of the fleet tile (the §4.5.2 marker projection).
        for marker in tick["markers"]:
            assert set(marker.keys()) == TICK_MARKER_KEYS
            assert marker["heading"] in MARKER_HEADINGS
            assert npc_fleets.chebyshev(
                (int(marker["cell"]["x"]), int(marker["cell"]["y"])),
                (int(start["x"]), int(start["y"])),
            ) <= MARKER_VIEW_RADIUS_TILES
            assert 0 <= len(marker["wake"]) <= 5

        # A helm intent produces motion (the next tick shows a new tile).
        from server.sim.world.raster import raster
        world = raster()
        x, y = _session(client).gs.world_tile()
        direction = None
        for name, (dx, dy) in {
            "N": (0, -1), "S": (0, 1), "E": (1, 0), "W": (-1, 0),
            "NE": (1, -1), "NW": (-1, -1), "SE": (1, 1), "SW": (-1, 1),
        }.items():
            if world.is_passable((x + dx) % world.width, y + dy):
                direction = name
                break
        assert direction is not None
        ws.send_json({"type": "helm", "dir": direction})
        moved = False
        for _ in range(40):
            frame = ws.receive_json()
            if frame.get("type") == "tick" and \
                    frame["position"] != {"x": x, "y": y}:
                moved = True
                break
        assert moved, "the helm intent produced no motion"

        # An unknown intent is one error frame; the run continues.
        ws.send_json({"type": "not_a_real_intent"})
        error = _receive_until(ws, "error", limit=20)
        assert set(error.keys()) == {"type", "code", "msg"}
        assert error["code"] == "unknown_intent"
        ws.send_json({"type": "helm", "dir": "sideways"})
        error = _receive_until(ws, "error", limit=20)
        assert error["code"] == "bad_intent"
        assert _receive_until(ws, "tick", limit=20)["type"] == "tick"


def test_ws_second_connection_closed_4001(client: TestClient) -> None:
    with client.websocket_connect("/ws") as first:
        assert first.receive_json()["type"] == "hello"
        with client.websocket_connect("/ws") as second:
            with pytest.raises(WebSocketDisconnect) as caught:
                second.receive_json()
            assert caught.value.code == 4001
        # The first connection is still authoritative after the refusal.
        first.send_json({"type": "locale", "locale": "en"})
        assert _receive_until(first, "state", limit=5)["type"] == "state"


def test_tick_markers_slice(client: TestClient) -> None:
    """§0.3 ``tick.markers`` (the 2026-11-12 amendment): the §4.5.2
    marker projection rides the sailing tick — fleets inside the frozen
    radius ride as compact rows, fleets outside are absent, and an idle
    sea returns the cached slice unchanged."""
    _new_game(client)
    _set_sail(client)
    session = _session(client)
    gs = session.gs
    cell = gs.world_tile()
    ecology = session._ensure_ecology()

    def fleet(fleet_id: str, x: int, y: int) -> dict[str, Any]:
        # ``dwell_until_day`` pins the fixture against the live loop's
        # accrual (the same pin the npc_fleets tests' ``_stationary`` uses).
        return {
            "id": fleet_id, "role": "trader", "nation_id": "portugal",
            "cell": {"x": x % 4320, "y": y},
            "route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
            "cargo": {}, "captain_id": "", "cooldown_until_day": 0,
            "seed": 12345, "dest_port_id": "", "dwell_until_day": gs.day + 30,
            "anchor_cell": None, "target_fleet_id": "", "hunter_state": "",
            "loiter_until_day": 0, "home_port_id": "",
        }

    near = fleet("fx_near", cell[0] + 5, cell[1])
    far = fleet("fx_far", cell[0] + 300, cell[1])
    gs.npc_fleets.append(near)
    gs.npc_fleets.append(far)

    frame = session.tick_frame()
    ids = [str(row["id"]) for row in frame["markers"]]
    assert "fx_near" in ids
    assert "fx_far" not in ids
    row = next(row for row in frame["markers"] if row["id"] == "fx_near")
    assert set(row.keys()) == TICK_MARKER_KEYS
    assert row["cell"] == {"x": (cell[0] + 5) % 4320, "y": cell[1]}
    assert row["sailing"] is False and row["wake"] == []
    assert row["heading"] == ""
    assert isinstance(row["ship_type"], str)

    # The ecology move counter keys the cache: no motion ⇒ the same slice.
    assert session.tick_frame()["markers"] == frame["markers"]

    # One accrued step toward the near fleet's lane refreshes the slice key
    # (the day/cell/fleet-count/move-count 5-tuple), the rows stay in shape.
    ecology.moved_fleet_moves.append({"id": "fx_near"})
    refreshed = session.tick_frame()["markers"]
    assert [str(row["id"]) for row in refreshed] == ids
    for row in refreshed:
        assert set(row.keys()) == TICK_MARKER_KEYS


def test_ws_intent_gates(client: TestClient) -> None:
    # No run: sea intents are refused, never crash the socket.
    with client.websocket_connect("/ws") as ws:
        assert ws.receive_json()["type"] == "hello"
        assert ws.receive_json()["type"] == "state"
        ws.send_json({"type": "sail_to", "x": 1, "y": 2})
        error = _receive_until(ws, "error", limit=10)
        assert error["code"] == "no_run"
        ws.send_json({"type": "battle_action", "verb": "broadside"})
        assert _receive_until(ws, "error", limit=10)["code"] == "no_run"
    # In port: helm is refused with the at-sea gate.
    _new_game(client)
    with client.websocket_connect("/ws") as ws:
        ws.receive_json()
        ws.receive_json()
        ws.send_json({"type": "helm", "dir": "N"})
        assert _receive_until(ws, "error", limit=10)["code"] == "not_at_sea"


# --- (e) the locale toggle ---------------------------------------------------


def test_locale_toggle_reflects_in_state_and_hello(client: TestClient) -> None:
    _new_game(client)
    with client.websocket_connect("/ws") as ws:
        hello = ws.receive_json()
        assert hello["locale"] == "en"
        ws.receive_json()  # state
        ws.send_json({"type": "locale", "locale": "zh"})
        state = _receive_until(ws, "state", limit=10)
        assert state["locale"] == "zh"
    assert client.get("/api/state").json()["state"]["locale"] == "zh"
    with client.websocket_connect("/ws") as ws:
        assert ws.receive_json()["locale"] == "zh"


# --- (f) game-over and refusal paths never 500 -------------------------------


def test_refusal_paths_never_500(client: TestClient) -> None:
    _new_game(client)
    # Closed facility at 00:00 (the market opens at 08:00).
    _refusal(client.post("/api/market/buy", json={"good_id": "wheat",
                                                  "qty": 1}))
    _refusal(client.post("/api/market/buy", json={"good_id": "nope",
                                                  "qty": 1}))
    _rest(client)
    _refusal(client.post("/api/market/buy", json={"good_id": "wheat",
                                                  "qty": 0}))
    _refusal(client.post("/api/market/sell", json={"good_id": "wine",
                                                   "qty": 1}))
    _refusal(client.post("/api/shipyard/repair",
                         json={"index": 9, "points": 1}))
    _refusal(client.post("/api/inn/odd_job", json={}))
    _refusal(client.post("/api/guild/accept", json={"index": 99}))
    _refusal(client.post("/api/palace/ceremony", json={}))
    _refusal(client.post("/api/people/hail", json={"fleet_id": "missing"}))
    response = client.post("/api/market/buy", data="not json",
                           headers={"content-type": "application/json"})
    assert response.status_code < 500
    _refusal(response)

    # A game-over run refuses every action without a 500 (§4.9 freeze).
    session = _session(client)
    session.gs.game_over_reason = "sunk"
    assert client.get("/api/state").status_code == 200
    _refusal(client.post("/api/market/buy", json={"good_id": "wheat",
                                                  "qty": 1}))
    _refusal(client.post("/api/provisions/set_sail", json={}))
    assert client.get("/api/state").json()["state"]["game_over_reason"] == "sunk"

    # A retired run likewise.
    session.gs.game_over_reason = ""
    session.gs.retired = True
    _refusal(client.post("/api/market/buy", json={"good_id": "wheat",
                                                  "qty": 1}))


# --- (g) the M3 screen verbs (the M2 inventory, wired) ----------------------


def test_provisions_fill_executes_the_auto_fill_plan(client: TestClient
                                                     ) -> None:
    _new_game(client)
    _at_hour(client, 8)
    before = client.get("/api/state").json()["state"]
    response = client.post("/api/provisions/fill", json={})
    body = response.json()
    assert response.status_code == 200 and body["ok"] is True, body
    plan = body["plan"]
    # Empty hold, 120 t capacity, 5 000g: T = (120 + 0 + 0) // 2 = 60.
    assert plan["target"] == 60
    assert plan["buy_provisions"] == plan["buy_water"] == 60
    assert plan["discard_provisions"] == plan["discard_water"] == 0
    assert body["bought"] == {"provisions": 60, "water": 60}
    assert plan["cost"] == (60 * trade.PROVISIONS_PRICE
                            + 60 * trade.WATER_PRICE)
    state = client.get("/api/state").json()["state"]
    assert state["fleet"][0]["provisions"] == 60
    assert state["fleet"][0]["water"] == 60
    assert state["gold"] == before["gold"] - plan["cost"]
    # Nothing left to plan: the prompt's own disabled-reason key.
    empty = _refusal(client.post("/api/provisions/fill", json={}))
    assert empty["error"]["msg"] == "port.sail.fill.done"


def test_provisions_jettison_removes_pooled_supplies(client: TestClient
                                                     ) -> None:
    _new_game(client)
    _buy_supplies(client)  # 10 provisions + 10 water, one hour each
    body = client.post("/api/provisions/jettison",
                       json={"kind": "provisions", "qty": 4}).json()
    assert body["ok"] is True and body["removed"] == 4
    state = client.get("/api/state").json()["state"]
    assert state["fleet"][0]["provisions"] == 6
    assert state["fleet"][0]["water"] == 10
    # A zero quantity is the market's invalid-quantity refusal.
    zero = _refusal(client.post("/api/provisions/jettison",
                                json={"kind": "provisions", "qty": 0}))
    assert zero["error"]["msg"] == "market.invalid_qty"


def test_tavern_fill_crew_and_down_to_min(client: TestClient) -> None:
    _new_game(client)
    _at_hour(client, 10)
    filled = client.post("/api/tavern/fill_crew", json={}).json()
    assert filled["ok"] is True
    # fill_heads = min(crew_max 45 − crew 15, gold // 20) = 30.
    assert filled["heads"] == 30 and filled["crew"] == 45
    # At the cap the Fill plan is empty: the crew row's own reason key.
    full = _refusal(client.post("/api/tavern/fill_crew", json={}))
    assert full["error"]["msg"] == "tavern.crew_full"
    down = client.post("/api/tavern/down_to_min", json={}).json()
    assert down["ok"] is True and down["fired"] == 30 and down["crew"] == 15
    # At the floor the fire path refuses.
    floor = _refusal(client.post("/api/tavern/down_to_min", json={}))
    assert floor["error"]["msg"] == "tavern.fire_refused"


def test_tavern_dismiss_officer(client: TestClient) -> None:
    _new_game(client)
    _at_hour(client, 10)
    officer_id = _view(client, "tavern")["recruitable"][0]["officerId"]
    assert client.post("/api/tavern/hire",
                       json={"officer_id": officer_id}).json()["ok"] is True
    assert officer_id in _session(client).gs.player["officers"]
    body = client.post("/api/tavern/dismiss",
                       json={"officer_id": officer_id}).json()
    assert body["ok"] is True
    assert officer_id not in _session(client).gs.player["officers"]
    assert officer_id not in _session(client).gs.officer_states
    again = _refusal(client.post("/api/tavern/dismiss",
                                 json={"officer_id": officer_id}))
    assert again["error"]["msg"] == "tavern.fire_refused"


def test_palace_repair_fleet_charges_the_bay_visit_once(client: TestClient
                                                        ) -> None:
    _new_game(client)
    session = _session(client)
    session.gs.fleet[0]["durability"] = 40
    _at_hour(client, 9)
    gold_before = int(session.gs.gold)
    body = client.post("/api/palace/repair_fleet", json={}).json()
    assert body["ok"] is True and body["restored"] == 50
    cost = 50 * shipyard.repair_cost_per_point("caravel")
    assert body["gold"] == gold_before - cost
    state = client.get("/api/state").json()["state"]
    assert state["fleet"][0]["durability"] == 90
    # An undamaged fleet has nothing to repair.
    clean = _refusal(client.post("/api/palace/repair_fleet", json={}))
    assert clean["error"]["msg"] == "shipyard.no_damage"


def test_palace_pay_bounty_resets_reputation(client: TestClient) -> None:
    _new_game(client)
    session = _session(client)
    _at_hour(client, 9)
    session.gs.player["reputation"]["portugal"] = -55
    session.gs.bounties["portugal"] = {"amount": 500, "day": 1}
    # The pay-off must name the port's nation.
    wrong = _refusal(client.post("/api/palace/pay_bounty",
                                 json={"nation_id": "spain"}))
    assert wrong["error"]["msg"] == "bounty.none"
    body = client.post("/api/palace/pay_bounty",
                       json={"nation_id": "portugal"}).json()
    assert body["ok"] is True
    assert body["reputation"] == bounty.CLEARED_REPUTATION == -10
    assert session.gs.bounties == {}
    assert session.gs.player["reputation"]["portugal"] == -10
    gone = _refusal(client.post("/api/palace/pay_bounty",
                                json={"nation_id": "portugal"}))
    assert gone["error"]["msg"] == "bounty.none"


def test_palace_inform_reveals_a_wanted_captain(client: TestClient) -> None:
    _new_game(client)
    _at_hour(client, 9)
    inform = _view(client, "palace")["inform"]
    assert inform, "Lisbon should post at least one wanted captain"
    row = inform[0]
    gold_before = int(_session(client).gs.gold)
    body = client.post("/api/palace/inform",
                       json={"captain_id": row["captainId"]}).json()
    assert body["ok"] is True, body
    assert body["gold"] == gold_before - 500
    reveal = body["reveal"]
    assert reveal["id"] and len(reveal["cell"]) == 2
    assert reveal["nearest_port"]
    unknown = _refusal(client.post("/api/palace/inform",
                                   json={"captain_id": "cap_nope"}))
    assert unknown["error"]["msg"] == "ui.not_available"


def test_palace_retire_marks_the_win_state(client: TestClient) -> None:
    _new_game(client)
    _at_hour(client, 9)
    locked = _refusal(client.post("/api/palace/retire", json={}))
    assert locked["error"]["msg"] == "ui.not_available"
    _session(client).gs.titles["portugal"] = fame.RANK_DUKE
    body = client.post("/api/palace/retire", json={}).json()
    assert body["ok"] is True and body["retired_at"] > 0
    state = client.get("/api/state").json()["state"]
    assert state["retired"] is True
    # A retired run refuses every further action (§4.7).
    after = _refusal(client.post("/api/palace/retire", json={}))
    assert after["error"]["msg"] == "error.retired"


def test_guild_complete_and_abandon(client: TestClient) -> None:
    _new_game(client)
    _rest(client)  # day + 3, 08:00: the guild window is open
    offers = _view(client, "guild")["offers"]
    assert len(offers) >= 2
    delivery = offers[0]
    assert delivery["type"] == "delivery"  # slot 0 is always a delivery
    accepted = client.post("/api/guild/accept",
                           json={"instance_id": delivery["id"]}).json()
    assert accepted["ok"] is True
    session = _session(client)
    quest = session.gs.active_quests[0]
    requirements = quest["requirements"]
    # Turn the commission in at the docked port (the fixture redirects the
    # destination; accept() already moved the cargo into the hold).
    requirements["dest_port_id"] = "lisbon"
    good_id = str(requirements["good_id"])
    quantity = int(requirements["quantity"])
    assert fleet_lib.held(session.gs.fleet, good_id) >= quantity
    gold_before = int(session.gs.gold)
    turned = client.post("/api/guild/complete",
                         json={"instance_id": delivery["id"]}).json()
    assert turned["ok"] is True and turned["completed"], turned
    assert fleet_lib.held(session.gs.fleet, good_id) == 0
    assert int(session.gs.gold) > gold_before
    repeat = _refusal(client.post("/api/guild/complete",
                                  json={"instance_id": delivery["id"]}))
    assert repeat["error"]["msg"] == "quest.not_completable"
    # Abandon the second offer: the same failure path (status failed).
    second = client.post("/api/guild/accept",
                         json={"instance_id": offers[1]["id"]}).json()
    assert second["ok"] is True
    abandoned = client.post("/api/guild/abandon",
                            json={"instance_id": offers[1]["id"]}).json()
    assert abandoned["ok"] is True
    repeat = _refusal(client.post("/api/guild/abandon",
                                  json={"instance_id": offers[1]["id"]}))
    assert repeat["error"]["msg"] == "quest.not_completable"


def test_bounty_closed_port_refuses_the_hub_actions(client: TestClient
                                                    ) -> None:
    """The M3 wiring gap 4: the action gate mirrors the hub projection —
    ``port.closed_bounty`` first, then the hours window (§4.9.6)."""
    _new_game(client)
    _rest(client)  # day + 3, 08:00 — hub windows otherwise open
    session = _session(client)
    session.gs.player["reputation"]["portugal"] = bounty.BOUNTY_THRESHOLD - 10
    assert bounty.evaluate_all(session.gs, session.gs) == ["portugal"]
    assert bounty.is_port_closed(session.gs, "lisbon") is True
    _at_hour(client, 9, 30)  # inside every hub window except the tavern's

    hub = {row["id"]: row for row in _view(client, "port")["facilities"]}
    for facility in ("market", "shipyard", "tavern", "inn", "guild"):
        assert hub[facility]["enabled"] is False, facility
        assert hub[facility]["status"]["reasonKey"] == "port.closed_bounty"
    # §4.9.6: the bountied nation's capital palace stays open (Pay bounty).
    assert hub["palace"]["enabled"] is True

    for path, payload in (
        ("/api/market/buy", {"good_id": "wheat", "qty": 1}),
        ("/api/shipyard/repair", {"index": 0, "points": 1}),
        ("/api/tavern/hire", {"heads": 1}),
        ("/api/inn/rest", {}),
        ("/api/guild/offers", {}),
        ("/api/palace/ceremony", {}),
        ("/api/palace/inform", {"captain_id": "cap_nope"}),
    ):
        response = client.post(path, json=payload)
        assert response.status_code == 200, (path, response.text)
        refusal = _refusal(response)
        assert refusal["error"]["msg"] == "port.closed_bounty", path

    # §4.9.6: Set Sail (and its provisioning prompt) always works.
    for kind in ("provisions", "water"):
        assert client.post("/api/provisions/buy_supplies",
                           json={"kind": kind, "qty": 10}).json()["ok"] is True
    assert client.post("/api/provisions/set_sail",
                       json={}).json()["ok"] is True





def test_static_mounts_and_spa_fallback(client: TestClient) -> None:
    response = client.get("/data/ports.json")
    assert response.status_code == 200
    assert isinstance(response.json(), (dict, list))
    assert client.get("/data/maps/world.png").status_code == 404
    assert client.get("/data/nope.json").status_code == 404
    spa = client.get("/")
    if spa.status_code == 200:
        assert "text/html" in spa.headers.get("content-type", "")
    else:
        assert spa.status_code == 503
        _refusal(spa)
