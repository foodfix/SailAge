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

#: The frozen facility inventory (the M2 record's table, §0.4).
EXPECTED_INVENTORY: dict[str, tuple[str, ...]] = {
    "market": ("buy", "sell", "invest"),
    "shipyard": ("buy", "repair", "sell", "refit", "equip", "unequip",
                 "promote"),
    "tavern": ("hire", "fire", "spar", "hint"),
    "inn": ("rest", "odd_job"),
    "guild": ("offers", "accept", "complete", "abandon", "report"),
    "palace": ("mission", "ceremony", "permit", "commend",
               "tournament_enter"),
    "provisions": ("set_sail", "buy_supplies"),
    "people": ("inspect", "talk", "gift", "befriend", "attack", "hail",
               "appoint"),
    "fleet": ("jettison", "promote"),
}

#: The §0.3 hello frame keys, verbatim.
HELLO_KEYS = {"save_version", "tick_hz", "broadcast_hz", "locale", "has_run",
              "current_screen", "saves"}
#: The §0.3 tick frame keys, verbatim.
TICK_KEYS = {"day", "clock_min", "position", "heading", "sail_trim",
             "wind_dir", "weather", "speed", "gold", "morale", "autopilot",
             "contact_hint"}
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


# --- Static mounts -----------------------------------------------------------


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
