"""server.tests.test_golden_traces — the M5 golden-trace acceptance gate.

docs/IMPLEMENT-WebMigration.md §3 M5 ("golden traces recorded from the
GDScript harness act as oracle") and docs/90-ARCHITECTURE.md §0.1 (the
Godot tree is the parity oracle until the M6 cutover).

The gate is a REAL diff, never a re-derivation. The oracle trace is stored
at ``server/tests/fixtures/battle_golden_trace.jsonl`` — captured from the
frozen Godot 4.7 runtime via ``tools/battle_golden_trace.gd`` before the M6
cutover (when the harness still exists, ``test_oracle_fixture_matches_harness``
re-verifies the stored bytes against a fresh run). The gate itself needs no
Godot: the stored trace is the oracle. Original harness: ``tools/battle_golden_trace.gd``
runs one pinned battle through the frozen GDScript oracle
(``battle_sim.gd`` + ``ai_fleet.gd`` + ``fleet_commander.gd`` +
``ai_search.gd`` via the ``ai_level = 1`` dispatch) and prints JSON lines;
this test replays the SAME pinned scenario through the Python port and diffs
the two line streams field-for-field.

Scenario constants are pinned twice — inside the harness (byte-stable
across runs) and here (the frozen contract). The first trace line carries
the whole scenario, so a silent harness edit fails the contract assertion
before any battle replay happens. Determinism is asserted by running the
harness twice and diffing its raw stdout.

Skipped cleanly when ``godot`` is not on PATH (CI containers without the
frozen oracle); the rest of the combat suite keeps covering the port.
"""

from __future__ import annotations

import json
import math
import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest

from server.sim.combat import ai_fleet, fleet_commander
from server.sim.combat import ai_search
from server.sim.combat.battle_sim import (
    BROADSIDE_PORT,
    BROADSIDE_STARBOARD,
    ROUND_SHOT,
    BattleSim,
    heading8_of,
    vel_length,
)
from server.sim.data import data
from server.sim.rng import GodotRng

REPO_ROOT = Path(__file__).resolve().parents[2]
HARNESS = REPO_ROOT / "tools" / "battle_golden_trace.gd"
ORACLE_FIXTURE = (REPO_ROOT / "server" / "tests" / "fixtures"
                  / "battle_golden_trace.jsonl")

# --- The frozen scenario (mirrors the harness constants verbatim) -----------

SEED = 7000001
DAY = 30
GOLD = 0
CONTACT = (100, 100)
WEATHER = "fair"
WIND_DIR = "W"
CURRENT = {"dir": "", "strength": 0}
ENEMY_KIND = "navy"
ENEMY_NATION = "spain"
PLAYER_MORALE = 60
ENEMY_MORALE = 70
MAX_ROUNDS = 40

HULL_ID = "brigantine"
PLAYER_SHIP_COUNT = 2
ENEMY_SHIP_COUNT = 3

PLAYER_STATS: dict[str, Any] = {
    "attributes": {
        "constitution": 10, "intellect": 10, "charisma": 10,
        "courage": 10, "luck": 10,
    },
    "skills": {
        "seamanship": 0, "navigation": 0, "swordplay": 40,
        "gunnery": 60, "appraisal": 0, "negotiation": 0,
        "cartography": 0, "rumour": 0,
    },
    "equipment": {"weapon": "", "armor": ""},
}

PLAYER_ORDERS: list[dict[str, Any]] = [
    {
        "until_round": 2,
        "order": {
            "station": [10, 15], "desired_heading8": 0,
            "desired_speed_band": [1, 1], "assigned_target": 0,
            "discipline": False,
        },
    },
    {
        "until_round": 5,
        "order": {
            "station": [10, 15], "desired_heading8": 0,
            "desired_speed_band": [2, 5], "assigned_target": 0,
            "discipline": False,
        },
    },
    {
        "until_round": 999,
        "order": {
            "station": [10, 15], "desired_heading8": 0,
            "desired_speed_band": [1, 3], "assigned_target": 1,
            "discipline": False,
        },
    },
]


def _fixture_ship() -> dict[str, Any]:
    """The §4.11.11 ship instance at the hull's data defaults (the harness's
    ``_fixture_ship``)."""
    ship_type = data().get_ship_type(HULL_ID)
    return {
        "ship_type_id": HULL_ID,
        "durability": int(ship_type.get("durability", 0)),
        "crew": int(ship_type.get("crew_min", 0)),
        "provisions": 0,
        "water": 0,
        "cannons": int(ship_type.get("armament_slots", 0)),
        "equipment": {"figurehead": "", "sail": ""},
        "cargo": {},
    }


def _player_order(round_no: int) -> dict[str, Any]:
    for entry in PLAYER_ORDERS:
        if round_no <= int(entry["until_round"]):
            return entry["order"]
    return PLAYER_ORDERS[-1]["order"]


def _encoded_orders(orders: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for entry in orders:
        order = entry["order"]
        station = order.get("station", (0, 0))
        band = order.get("desired_speed_band", [0, 0])
        out.append({
            "index": int(entry["index"]),
            "order": {
                "station": [int(station[0]), int(station[1])],
                "desired_heading8": int(order.get("desired_heading8", 0)),
                "desired_speed_band": [int(band[0]), int(band[1])],
                "assigned_target": int(order.get("assigned_target", -1)),
                "discipline": bool(order.get("discipline", False)),
                "phase": str(order.get("phase", "")),
            },
        })
    return out


def _ships_state(sim: BattleSim) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for unit in sim.units():
        ship = unit.get("ship", {})
        cell = sim.unit_cell(unit)
        velocity = unit.get("vel", (0, 0))
        out.append({
            "id": f"{unit.get('side', '')}_{int(unit.get('index', 0))}",
            "side": str(unit.get("side", "")),
            "index": int(unit.get("index", 0)),
            "pos": {"x": int(cell[0]), "y": int(cell[1])},
            "vel": {"x": int(velocity[0]), "y": int(velocity[1])},
            "heading8": int(unit.get("heading8", 0)),
            "reload": {
                "port": int(unit.get("reload_port", 0)),
                "starboard": int(unit.get("reload_starboard", 0)),
            },
            "hull": int(ship.get("durability", 0)),
            "crew": int(unit.get("crew", 0)),
            "alive": bool(unit.get("alive", False)),
        })
    return out


def _target_for(sim: BattleSim, unit: dict[str, Any],
                assigned_index: int) -> dict[str, Any]:
    living = sim.living_units("enemy")
    if assigned_index >= 0:
        for enemy in living:
            if int(enemy.get("index", -1)) == assigned_index:
                return enemy
    if not living:
        return {}
    origin = sim.unit_cell(unit)

    def key(enemy: dict[str, Any]) -> tuple[int, int]:
        cell = sim.unit_cell(enemy)
        distance = max(abs(cell[0] - origin[0]), abs(cell[1] - origin[1]))
        return (distance, int(enemy.get("index", 0)))

    return sorted(living, key=key)[0]


def _player_turn(sim: BattleSim, unit: dict[str, Any],
                 order: dict[str, Any]) -> None:
    """server/session.py's player ``battle_action`` seam: the first legal
    velocity matching the order's heading + speed band, then fire at the
    assigned target with the first loaded side (port, then starboard), else
    hold. Round shot for a player actor (§4.12.1.1)."""
    heading = int(order.get("desired_heading8", -1))
    band = order.get("desired_speed_band", [])
    if heading >= 0 and len(band) >= 2:
        for velocity in sim.legal_velocities(unit):
            magnitude = int(math.floor(vel_length(velocity)))
            if heading8_of(velocity) == heading \
                    and int(band[0]) <= magnitude <= int(band[1]):
                sim.apply_velocity(unit, velocity)
                break
    target = _target_for(sim, unit, int(order.get("assigned_target", -1)))
    if not target:
        sim.hold(unit)
    elif sim.can_cannon(unit, target, BROADSIDE_PORT):
        sim.cannon(unit, target, BROADSIDE_PORT, ROUND_SHOT)
    elif sim.can_cannon(unit, target, BROADSIDE_STARBOARD):
        sim.cannon(unit, target, BROADSIDE_STARBOARD, ROUND_SHOT)
    else:
        sim.hold(unit)


# --- The Python replay ------------------------------------------------------


def scenario_record() -> dict[str, Any]:
    """The pinned scenario line the harness must print verbatim."""
    return {
        "type": "scenario",
        "seed": SEED,
        "day": DAY,
        "gold": GOLD,
        "contact": {"x": CONTACT[0], "y": CONTACT[1]},
        "weather": WEATHER,
        "wind_dir": WIND_DIR,
        "current": dict(CURRENT),
        "enemy_kind": ENEMY_KIND,
        "enemy_nation": ENEMY_NATION,
        "player_morale": PLAYER_MORALE,
        "enemy_morale": ENEMY_MORALE,
        "max_rounds": MAX_ROUNDS,
        "hull_id": HULL_ID,
        "player_ships": [_fixture_ship() for _ in range(PLAYER_SHIP_COUNT)],
        "enemy_ships": [_fixture_ship() for _ in range(ENEMY_SHIP_COUNT)],
        "player_stats": json.loads(json.dumps(PLAYER_STATS)),
        "profile": ai_fleet.profile_for(ENEMY_KIND),
        "theta": list(ai_search.THETA_BALANCED),
        "orders": json.loads(json.dumps(PLAYER_ORDERS)),
    }


def replay() -> list[dict[str, Any]]:
    """Drives the Python port through the pinned scenario and produces the
    same line stream the GDScript harness prints."""
    records: list[dict[str, Any]] = [scenario_record()]
    sim = BattleSim({
        "player_ships": [_fixture_ship() for _ in range(PLAYER_SHIP_COUNT)],
        "enemy_ships": [_fixture_ship() for _ in range(ENEMY_SHIP_COUNT)],
        "enemy_kind": ENEMY_KIND,
        "enemy_nation": ENEMY_NATION,
        "day": DAY,
        "gold": GOLD,
        "contact": CONTACT,
        "weather": WEATHER,
        "seed": SEED,
        "rng": GodotRng(SEED),
        "wind_dir": WIND_DIR,
        "current": dict(CURRENT),
        "player_stats": json.loads(json.dumps(PLAYER_STATS)),
        "player_morale": PLAYER_MORALE,
        "enemy_morale": ENEMY_MORALE,
    })
    profile = ai_fleet.profile_for(ENEMY_KIND)
    sim.start()
    anchor = sim.living_units("enemy")[0]
    state = fleet_commander.initial_state(
        str(profile.get("formation", "swarm")),
        sim.unit_cell(anchor),
        int(anchor.get("heading8", 4)),
    )
    orders: list[dict[str, Any]] = []
    record: dict[str, Any] = {}
    fc_round = -1
    log_seen = 0
    guard = 0

    while not sim.is_over() and sim.round_number() <= MAX_ROUNDS:
        guard += 1
        if guard > MAX_ROUNDS * len(sim.units()) * 2 + 10:
            break
        round_no = sim.round_number()
        if round_no != fc_round:
            if record:
                lines = sim.log_lines()
                record["log"] = lines[log_seen:]
                log_seen = len(lines)
                records.append(record)
            fc_round = round_no
            orders = fleet_commander.generate_orders(
                {
                    "units": sim.units(),
                    "round": round_no,
                    "enemy_kind": ENEMY_KIND,
                    "side_morale": int(sim.side_morale("enemy")),
                },
                profile, state,
            )
            record = {
                "type": "round",
                "round": round_no,
                "phase": str(state.get("phase", "")),
                "orders": {
                    "player": json.loads(json.dumps(_player_order(round_no))),
                    "enemy": _encoded_orders(orders),
                },
                "ships": _ships_state(sim),
            }
        unit = sim.current_unit()
        if not unit:
            sim.end_turn()
            continue
        if str(unit.get("side", "")) == "enemy":
            order = next(
                (entry["order"] for entry in orders
                 if int(entry["index"]) == int(unit.get("index", -1))),
                {},
            )
            sim._apply_decision(unit, ai_fleet.decide(sim, unit, order, {}))
        else:
            _player_turn(sim, unit, _player_order(round_no))
        if not sim.is_over():
            sim.end_turn()

    if record:
        lines = sim.log_lines()
        record["log"] = lines[log_seen:]
        log_seen = len(lines)
        records.append(record)

    outcome = sim.outcome()
    records.append({
        "type": "final",
        "result": str(outcome.get("result", "")),
        "rounds": int(outcome.get("rounds", sim.round_number())),
        "kind": str(outcome.get("kind", "")),
        "nation_id": str(outcome.get("nation_id", "")),
        "surrendered_enemy": int(outcome.get("surrendered_enemy", 0)),
        "sunk_enemy": list(outcome.get("sunk_enemy", [])),
        "captured_enemy": [
            str(ship.get("ship_type_id", ""))
            for ship in outcome.get("captured_enemy", [])
        ],
        "sunk_player": list(outcome.get("sunk_player", [])),
        "lost_player": [
            str(ship.get("ship_type_id", ""))
            for ship in outcome.get("lost_player", [])
        ],
        "salvage_gold": int(outcome.get("salvage_gold", 0)),
        "xp": int(outcome.get("xp", 0)),
        "morale_delta": int(outcome.get("morale_delta", 0)),
        "rep_deltas": dict(outcome.get("rep_deltas", {})),
        "rng_state": int(sim.rng.state),
        "log": sim.log_lines(),
    })
    return records


# --- Harness execution ------------------------------------------------------


def run_harness() -> tuple[str, list[dict[str, Any]]]:
    result = subprocess.run(
        ["godot", "--headless", "--path", ".", "--script",
         "res://tools/battle_golden_trace.gd"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, (
        "battle_golden_trace.gd failed:\n"
        f"stdout tail:\n{result.stdout[-2000:]}\n"
        f"stderr tail:\n{result.stderr[-2000:]}"
    )
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"harness printed no JSON lines; stderr:\n{result.stderr[-2000:]}"
    return result.stdout, [json.loads(line) for line in lines]


def _canonical(payload: Any) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def _first_difference(actual: dict[str, Any],
                      expected: dict[str, Any]) -> str:
    """Reports the path of the first differing field (round/field fidelity)."""
    missing = sorted(set(actual) - set(expected))
    extra = sorted(set(expected) - set(actual))
    if missing:
        return f"fields missing from the Python replay: {missing}"
    if extra:
        return f"fields extra in the Python replay: {extra}"
    for key in actual:
        if actual[key] != expected[key]:
            return (f"field '{key}': harness={_canonical(actual[key])} "
                    f"python={_canonical(expected[key])}")
    return "records differ (unknown field)"


def load_oracle_trace() -> tuple[str, list[dict[str, Any]]]:
    """The stored oracle trace (captured from the frozen Godot runtime)."""
    text = ORACLE_FIXTURE.read_text(encoding="utf-8")
    records = [json.loads(line) for line in text.splitlines() if line.strip()]
    assert records, "the stored oracle trace is empty"
    return text, records


@pytest.mark.skipif(
    shutil.which("godot") is None or not HARNESS.exists(),
    reason="the frozen Godot oracle/harness is gone (post-cutover) — the "
           "stored fixture is the oracle",
)
def test_oracle_fixture_matches_harness() -> None:
    """While the Godot tree exists, the stored fixture must be its output."""
    stdout_one, fresh = run_harness()
    stdout_two, fresh_two = run_harness()
    assert stdout_one == stdout_two, "battle_golden_trace.gd is not deterministic"
    assert fresh == fresh_two
    _stored_text, stored = load_oracle_trace()
    assert fresh == stored, (
        "the stored oracle trace drifted from a fresh harness run:\n"
        + _first_difference(fresh[0], stored[0])
    )


def test_golden_trace_matches_python_port() -> None:
    _oracle_text, harness_records = load_oracle_trace()

    # 1. The stored oracle trace carries the frozen scenario contract.
    assert harness_records[0]["type"] == "scenario"
    assert harness_records[0] == scenario_record(), (
        "harness scenario drifted from the pinned contract:\n"
        + _first_difference(harness_records[0], scenario_record())
    )

    # 3. Real line-for-line diff against the Python replay.
    python_records = replay()
    if len(harness_records) != len(python_records):
        assert False, (
            f"trace length mismatch: harness={len(harness_records)} "
            f"python={len(python_records)} lines "
            f"(types: harness={[r['type'] for r in harness_records]}, "
            f"python={[r['type'] for r in python_records]})"
        )
    for index, (actual, expected) in enumerate(
            zip(harness_records, python_records)):
        if actual == expected:
            continue
        label = actual.get("round", actual.get("type", index))
        assert False, (
            f"golden trace diverges at line {index} ({label}): "
            + _first_difference(actual, expected)
        )
