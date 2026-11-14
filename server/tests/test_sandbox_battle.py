"""The §4.12.4 zero-write sandbox battle seam (90-* §0.4, 2026-11-14).

Pins the S21 proving-ground contract end-to-end: ``POST /api/sandbox/battle``
opens a real :class:`BattleSim` flagged ``encounter.sandbox`` with **no run
required**, the ``battle_tick`` frame carries the acting-unit id and the
reachable-set endpoints, the battle intents work without the run guard, the
``hold`` verb is the pure-move action, the ending writes nothing, and
``leave`` abandons the battle without an outcome.
"""
from __future__ import annotations

from typing import Any

import pytest
from starlette.testclient import TestClient

from server import save
from server.app import create_app
from server.session import SIM_DT, BattleSession, Session
from server.sim.combat import ai_fleet

# --- Fixtures ----------------------------------------------------------------


def canonical_config() -> dict[str, Any]:
    """The §4.7.16 canonical export shape (the doc's own example numbers)."""
    return {
        "version": 1,
        "kind": "sailage_sandbox",
        "player": {
            "stats": {"constitution": 10, "intellect": 10, "charisma": 10,
                      "courage": 10, "luck": 10, "weapon": "", "armor": ""},
            "morale": 50,
            "ships": [{"ship_type_id": "brigantine", "cannons": 12,
                       "crew": 30, "durability": 90,
                       "equipment": {"figurehead": "", "sail": ""},
                       "captain_id": ""}],
        },
        "enemy": {
            "kind": "pirate", "ai_level": 1, "archetype": "aggressive",
            "formation": "swarm", "morale": 50, "compose": False,
            "ships": [{"ship_type_id": "sloop", "cannons": 8,
                       "crew": 20, "durability": 60,
                       "equipment": {"figurehead": "", "sail": ""},
                       "captain_id": ""}],
        },
        "conditions": {"day": 1, "seed_mode": "fixed", "seed": 1,
                       "weather": "fair", "wind_dir": "E",
                       "current": {"dir": "E", "strength": 0},
                       "deployment": "standard"},
    }


@pytest.fixture
def client(tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    monkeypatch.setenv(save.ENV_HOME, str(tmp_path))
    with TestClient(create_app()) as test_client:
        yield test_client


def _session(client: Any) -> Session:
    return client.app.state.session


def _open(session: Session, **overrides: Any) -> dict[str, Any]:
    config = canonical_config()
    for key, value in overrides.items():
        config[key] = value
    return session._sandbox_battle(config)


# --- Opening -----------------------------------------------------------------


def test_sandbox_battle_opens_without_run(client: Any) -> None:
    """The editor lives off the title: the seam opens a live sandbox battle
    with no run, and the state slice flags it."""
    response = client.post("/api/sandbox/battle", json=canonical_config())
    assert response.status_code == 200
    assert response.json() == {"ok": True, "encounter_id": "sandbox"}
    session = _session(client)
    assert session.has_run() is False
    assert session.state_payload()["battle"] == {
        "active": True, "encounter_id": "sandbox", "sandbox": True}


def test_sandbox_battle_refuses_while_active(client: Any) -> None:
    _open(_session(client))
    response = client.post("/api/sandbox/battle", json=canonical_config())
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert body["error"]["code"] == "battle_active"
    assert body["error"]["msg"] == "error.battle_active"


@pytest.mark.parametrize("mutate", [
    lambda cfg: cfg.pop("kind"),
    lambda cfg: cfg.__setitem__("kind", "other"),
    lambda cfg: cfg["player"].__setitem__("ships", []),
    lambda cfg: cfg["player"]["ships"].extend(
        [{"ship_type_id": "sloop"} for _ in range(6)]),
    lambda cfg: cfg["enemy"].__setitem__("ships", "nope"),
    lambda cfg: cfg.pop("conditions"),
])
def test_sandbox_battle_refuses_malformed_config(client: Any, mutate: Any) -> None:
    config = canonical_config()
    mutate(config)
    response = client.post("/api/sandbox/battle", json=config)
    assert response.status_code == 400
    body = response.json()
    assert body["ok"] is False
    assert body["error"]["msg"] == "error.sandbox_config"


def test_sandbox_battle_clamps_editor_rows(client: Any) -> None:
    """The §4.7.16 clamp rule: out-of-range fields never reach 开战."""
    session = _session(client)
    ship = session._sandbox_ship("brigantine", cannons=99, crew=0,
                                 durability=0, figurehead="x", sail="y")
    ship_type = session.store.get_ship_type("brigantine")
    assert ship["cannons"] == ship_type["armament_slots"]
    assert ship["crew"] == ship_type["crew_min"]
    assert ship["durability"] == ship_type["durability"]
    assert ship["equipment"] == {"figurehead": "x", "sail": "y"}
    assert ship["cargo"] == {}


def test_sandbox_fixed_seed_is_deterministic(tmp_path: Any) -> None:
    """Same seed ⇒ byte-identical opening frame (the §4.11.1 discipline)."""
    first, second = Session(), Session()
    _open(first)
    _open(second)
    assert first.battle_frame() == second.battle_frame()


def test_sandbox_profile_override_reaches_the_ai(
        tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """The editor's ai_level / archetype / formation ride the §4.9a
    ``profile_override`` seam (the S21 override the oracle documents)."""
    seen: list[Any] = []
    original = ai_fleet.decide
    monkeypatch.setattr(ai_fleet, "decide",
                        lambda *args, **kw: seen.append(args[3])
                        or original(*args, **kw))
    session = Session()
    config = canonical_config()
    config["enemy"].update({"ai_level": 0, "archetype": "cautious",
                            "formation": "line_ahead"})
    session._sandbox_battle(config)
    # Round 1 opens on the player flagship — end the turn so the sim loop
    # pumps an enemy decision.
    session.intent({"type": "battle_order", "station": [10, 15],
                    "desired_heading8": 0, "desired_speed_band": [1, 1],
                    "assigned_target": 0, "discipline": False})
    session.intent({"type": "battle_action", "verb": "hold"})
    session.tick(SIM_DT)
    assert seen, "the opening pump decided at least one enemy turn"
    assert seen[0] == {"ai_level": 0, "archetype": "cautious",
                       "formation": "line_ahead"}
    # The live path keeps the field at its None default — the pre-amendment
    # call shape `decide(sim, unit, {}, None)` is byte-identical there.
    assert BattleSession.__dataclass_fields__["profile"].default is None


# --- The battle_tick seams (90-* §0.3, 2026-11-14 amendment) ------------------


def _end_player_turn(session: Session) -> None:
    session.intent({"type": "battle_order", "station": [10, 15],
                    "desired_heading8": 0, "desired_speed_band": [1, 1],
                    "assigned_target": 0, "discipline": False})
    session.intent({"type": "battle_action", "verb": "hold"})
    session.tick(SIM_DT)  # the sim loop pumps the enemy turns


def test_battle_tick_carries_acting_id_and_move_range(tmp_path: Any) -> None:
    session = Session()
    _open(session)
    frame = session.battle_frame()
    assert frame["phase"] == "player"
    assert frame["orders_due"] is True
    assert frame["acting_id"] == "player_0"
    sim = session.battle.sim
    acting = sim.current_unit()
    origin = sim.unit_cell(acting)
    expected = sorted((origin[0] + vel[0], origin[1] + vel[1])
                      for vel in sim.legal_velocities(acting))
    assert sorted((cell["x"], cell["y"]) for cell in frame["move_range"]) \
        == expected
    # A player action hands the turn over: the sim loop resolves the enemy
    # turns inside the same tick (the M2 pump), so the next broadcast frame
    # is back on the player actor — with the reachable set recomputed for
    # the moved position.
    _end_player_turn(session)
    assert session.battle is not None
    frame = session.battle_frame()
    assert frame["acting_id"].startswith("player_")
    assert frame["phase"] == "player"
    sim = session.battle.sim
    acting = sim.current_unit()
    origin = sim.unit_cell(acting)
    expected = sorted((origin[0] + vel[0], origin[1] + vel[1])
                      for vel in sim.legal_velocities(acting))
    assert sorted((cell["x"], cell["y"]) for cell in frame["move_range"]) \
        == expected


def test_sandbox_hold_is_the_pure_move(tmp_path: Any) -> None:
    """The 2026-11-14 `hold` verb: the stored order's movement rides, the
    ship holds, the turn ends."""
    session = Session()
    _open(session)
    sim = session.battle.sim
    unit = sim.current_unit()
    before = sim.unit_cell(unit)
    session.intent({"type": "battle_order", "station": list(before),
                    "desired_heading8": 0, "desired_speed_band": [1, 1],
                    "assigned_target": 0, "discipline": False})
    session.intent({"type": "battle_action", "verb": "hold"})
    after = sim.unit_cell(unit)
    # The §4.11.2 closing start is vel (1, 0): the east/band-[1,1] order
    # re-picks that legal velocity — one cell east, same row.
    assert after == (before[0] + 1, before[1])


# --- Intents without a run ---------------------------------------------------


def test_sandbox_intents_work_without_a_run(tmp_path: Any) -> None:
    session = Session()
    _open(session)
    session.intent({"type": "battle_order", "station": [10, 15],
                    "desired_heading8": 0, "desired_speed_band": [1, 1],
                    "assigned_target": 0, "discipline": False})
    session.intent({"type": "battle_action", "verb": "hold"})
    # The run guard never fired (no `no_run` refusal) and the battle moved.
    assert session.battle is not None
    assert session.battle.sim.round_number() >= 1


# --- Endings: read-only, zero-write -------------------------------------------


def test_sandbox_finish_is_readonly_and_zero_write(
        client: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """Even with a live run, the sandbox ending skips §4.12.4 steps 2/3/4:
    no fleet, gold, morale or pending-encounter write; the outcome rides
    the read-only ``battle_finished`` event."""
    from server.sim.combat.battle_sim import BattleSim  # noqa: F401
    response = client.post("/api/new_game", json={
        "nation_id": "portugal", "background_id": "background_navy_cadet",
        "attr_alloc": {"constitution": 3, "courage": 2},
        "skill_alloc": {"navigation": 3},
    })
    assert response.json()["ok"] is True
    session = _session(client)
    fleet_before = [dict(ship) for ship in session.gs.fleet]
    gold_before = int(session.gs.gold)
    morale_before = int(session.gs.morale)
    events: list[tuple[str, dict[str, Any]]] = []
    monkeypatch.setattr(session, "emit_event",
                        lambda name, args: events.append((name, args)))
    _open(session)
    session.intent({"type": "battle_action", "verb": "surrender"})
    names = [name for name, _ in events]
    assert "battle_finished" in names
    finished = next(args for name, args in events
                    if name == "battle_finished")
    assert finished["sandbox"] is True
    assert finished["result"] == "surrender"
    assert finished["outcome"]["result"] == "surrender"
    # Zero-write: the run is exactly as it was before the battle.
    assert [dict(ship) for ship in session.gs.fleet] == fleet_before
    assert int(session.gs.gold) == gold_before
    assert int(session.gs.morale) == morale_before
    assert session.gs.pending_encounter is None
    assert session.state_payload()["battle"]["active"] is False


def test_sandbox_leave_abandons_without_an_outcome(
        client: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    session = _session(client)
    events: list[tuple[str, dict[str, Any]]] = []
    monkeypatch.setattr(session, "emit_event",
                        lambda name, args: events.append((name, args)))
    _open(session)
    response = client.post("/api/sandbox/leave", json={})
    assert response.status_code == 200
    assert response.json() == {"ok": True}
    assert session.battle is None
    assert session.state_payload()["battle"]["active"] is False
    assert [name for name, _ in events] == ["battle_started"]


def test_sandbox_leave_refuses_without_a_battle(client: Any) -> None:
    response = client.post("/api/sandbox/leave", json={})
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert body["error"]["code"] == "not_in_battle"
