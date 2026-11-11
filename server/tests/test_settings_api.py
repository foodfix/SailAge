"""The S19 settings rows over the frozen HTTP surface (docs/80-* §4.6.3).

The three GameState rows (`npc_preset`, `control_prefs.input_mode`,
`control_prefs.current_mode`) are live through `settings/*` (§0.4); each
adapter is a thin state write + one `state` broadcast, validated against
the data/pinned domains.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from server.app import create_app
from server.session import Session


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("SAILAGE_HOME", str(tmp_path))
    app = create_app()
    with TestClient(app) as test_client:
        test_client.app.state.session.new_game(
            "portugal", "background_deckhand", {}, {})
        yield test_client


def _settings(client: TestClient, verb: str, body: dict):
    return client.post(f"/api/settings/{verb}", json=body).json()


def test_npc_preset_live(client: TestClient) -> None:
    result = _settings(client, "npc_preset", {"preset": "high"})
    assert result["ok"] is True and result["preset"] == "high"
    state = client.get("/api/state").json()["state"]
    assert state["npc_preset"] == "high"


def test_npc_preset_refuses_unknown(client: TestClient) -> None:
    result = _settings(client, "npc_preset", {"preset": "bogus"})
    assert result["ok"] is False
    assert result["error"]["msg"] == "error.bad_request"


def test_control_prefs_live_and_domained(client: TestClient) -> None:
    assert _settings(client, "input_mode", {"mode": "helm"})["ok"] is True
    assert _settings(client, "current_mode", {"mode": "drift"})["ok"] is True
    prefs = client.get("/api/state").json()["state"]["control_prefs"]
    assert prefs == {"input_mode": "helm", "current_mode": "drift"}
    assert _settings(client, "input_mode", {"mode": "bogus"})["ok"] is False
    assert _settings(client, "current_mode", {"mode": "bogus"})["ok"] is False


def test_settings_pre_game_allowed(tmp_path, monkeypatch) -> None:
    """The S1 title entry sets the rows before any run exists."""
    monkeypatch.setenv("SAILAGE_HOME", str(tmp_path))
    app = create_app()
    with TestClient(app) as test_client:
        session: Session = test_client.app.state.session
        assert session.has_run() is False
        result = test_client.post("/api/settings/npc_preset",
                                  json={"preset": "low"}).json()
        assert result["ok"] is True
        assert session.gs.npc_preset == "low"
