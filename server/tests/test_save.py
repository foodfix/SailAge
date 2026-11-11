"""Parity suite for ``server/save.py`` — save v1 (M1).

Oracle: ``autoload/save_system.gd`` (frozen read-only until the M6
cutover). Normative contract: ``docs/90-ARCHITECTURE.md`` §0.5 (the
``~/.sailage/`` profile root, ``SAILAGE_HOME`` test seam, 3 slots,
``SAVE_VERSION = 1`` and no migration chain), §8.1 (the payload shape and
the v8 explored-state RLE/base64 encoding) and §8.2 (a wrong version is a
"pre-release save" — refused, never migrated).

Port the guarantee, not the method: the round-trip test compares every
§8.1 field against the state's own snapshot; the codec test pins the
hand-computed run bytes/strings from the spec; the refusal matrix proves
each malformed payload returns ``False`` with the state untouched. The
profile is always a per-test ``tmp_path`` (the ``SAILAGE_HOME`` seam), so
this suite can never write ``~/.sailage``.
"""

from __future__ import annotations

import base64
import copy
import json
import logging
import struct
from pathlib import Path
from typing import Any, Callable

import pytest

from server import save
from server.sim.data import data
from server.sim.state import SNAPSHOT_KEYS, GameState

#: The exact §0.3 WS ``hello.saves`` entry shape.
SLOT_ENTRY_KEYS = {"slot", "day", "nation_id", "port_id", "gold", "saved_at"}


@pytest.fixture(autouse=True)
def _isolated_profile(tmp_path: Path,
                      monkeypatch: pytest.MonkeyPatch) -> Path:
    """Every test writes under its own tmp dir (never the real home)."""
    monkeypatch.setenv(save.ENV_HOME, str(tmp_path))
    return tmp_path


# --- Helpers -----------------------------------------------------------------


def _new_game() -> GameState:
    """The docs/50-* §4.1 worked creation (Portugal + naval cadet)."""
    return GameState().new_game(
        "portugal", "background_navy_cadet",
        {"constitution": 3, "courage": 2}, {"navigation": 3})


def _read_payload(slot: int) -> dict[str, Any]:
    return json.loads(save.slot_path(slot).read_text(encoding="utf-8"))


def _write_payload(slot: int, payload: Any) -> None:
    path = save.slot_path(slot)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, sort_keys=True, indent=2) + "\n",
        encoding="utf-8")


def _write_text(slot: int, text: str) -> None:
    path = save.slot_path(slot)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _run(y: int, x0: int, span: int) -> bytes:
    """One §8.1 run record (``[u16 y][u16 x0][u16 len−1]``)."""
    return struct.pack("<HHH", y, x0, span - 1)


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _mutate_away(gs: GameState) -> set[tuple[int, int]]:
    """Replaces every §8.1 field with a distinctive wrong value.

    Returns the *new* explored set object, so the caller can prove load
    installs a fresh container instead of mutating this one.
    """
    store = data()
    officer_id = str(store.officers_list[0]["id"])
    captain_id = str(store.captains_list[0]["id"])

    gs.locale = "zh"
    gs.day = 77
    gs.gold = 123_456
    gs.player = {"nation_id": "spain", "xp": 1}
    gs.fleet = [{"ship_type_id": "caravel", "crew": 1, "cargo": {}}]
    gs.morale = 3
    gs.world = {
        "position": {"x": 1, "y": 2},
        "clock_fraction": 0.75,
        "weather": "storm",
        "map_id": "world",
        "last_departed_port": "cadiz",
        "hunter_intel_cell": {"x": 9, "y": 9},
        "sail_trim": "furled",
        "heading": "W",
        "wind_dir": "S",
    }
    gs.current_port = "cadiz"
    gs.known_ports = ["cadiz"]
    gs.explored_tiles = {(1, 1), (4319, 2)}
    gs.port_investments = {"cadiz": 1}
    gs.discoveries_found = ["wrong_discovery"]
    gs.npc_fleets = [{"id": "wrong_fleet"}]
    gs.officer_states = {
        officer_id: {
            "loyalty": 77, "sea_days": 3, "post_id": "pilot",
            "ship_id": "ship_1", "talk_cd_day": 1, "gift_cd_day": 2,
            "defeats": 1, "wage_mult": 1.25,
            "skill_deltas": {"navigation": 2},
        },
    }
    gs.captain_states = {
        captain_id: {
            "status": "returning", "return_day": 99, "tier_now": 2,
            "stance": -4, "familiarity": 7, "dossier_seen": True,
            "defeats": 2, "wins": 1,
        },
    }
    gs.proximity_cooldowns = {"pirate": 99}
    gs.market_stocks = {"cadiz": {"wine": 1}}
    gs.wrecks = [{"id": "wrong_wreck"}]
    gs.npc_preset = "dense"
    gs.control_prefs = {"input_mode": "helm", "current_mode": "drift"}
    gs.market_events = [{"id": "wrong_event"}]
    gs.fame = 321
    gs.titles = {"spain": "duke"}
    gs.bounties = {"spain": {"amount": 1, "day": 2}}
    gs.active_quests = [{"id": "wrong_quest"}]
    gs.completed_royal_missions = {"spain": 3}
    gs.discoveries_reported = ["wrong_reported"]
    gs.discovery_hints = {"wrong_hint": True}
    gs.battles_won = 9
    gs.retired = True
    gs.retired_at = 123
    gs.permits = {"home": True, "foreign": {"spain": True}}
    gs.ledgers["lisbon"] = {"spain": 12_345}
    gs.allegiances["lisbon"] = "spain"
    gs.month_invested = {"cadiz": 2_000}
    gs.treasuries = {"portugal": 1}
    gs.fame_commended = {"cadiz": True}
    gs.quests = [{"stale": True}]
    return gs.explored_tiles


# --- Payload inventory & the byte rule (docs/90-* §8.1) ----------------------


def test_saved_payload_is_the_section_8_1_block_plus_the_three_headers() -> None:
    gs = _new_game()
    save.save(gs, 1)
    payload = _read_payload(1)

    assert len(SNAPSHOT_KEYS) == 36
    assert set(payload) == set(SNAPSHOT_KEYS) | {
        "save_version", "saved_at", "phase"}
    assert len(payload) == 39
    assert payload["save_version"] == save.SAVE_VERSION == 1
    assert payload["phase"] == "web"
    assert isinstance(payload["saved_at"], int)
    assert isinstance(payload["explored_tiles"], str)
    assert set(payload["world"]) == set(save.WORLD_KEYS)
    assert "clock_fraction" not in payload["world"]
    assert "quests" not in payload
    assert save.validate_payload(payload) == ""


def test_save_file_is_deterministic_sorted_json_with_a_trailing_newline(
        monkeypatch: pytest.MonkeyPatch) -> None:
    gs = _new_game()
    monkeypatch.setattr(save.time, "time", lambda: 1_793_119_712)
    save.save(gs, 1)
    first = save.slot_path(1).read_text(encoding="utf-8")
    save.save(gs, 1)
    second = save.slot_path(1).read_text(encoding="utf-8")

    assert first == second
    payload = json.loads(first)
    assert first == json.dumps(payload, sort_keys=True, indent=2) + "\n"
    assert first.endswith("\n")
    assert "\r" not in first
    assert first.splitlines()[1].strip().startswith('"active_quests":')
    assert payload["saved_at"] == 1_793_119_712


def test_save_creates_the_profile_and_leaves_no_temp_file() -> None:
    gs = _new_game()
    save.save(gs, 3)
    assert save.saves_dir().is_dir()
    assert [path.name for path in save.saves_dir().iterdir()] == [
        "save_3.json"]


# --- Profile-dir resolution (docs/90-* §0.5) --------------------------------


def test_sailage_home_overrides_the_profile_root(
        tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    custom = tmp_path / "elsewhere" / "profile"
    monkeypatch.setenv(save.ENV_HOME, str(custom))

    assert save.profile_dir() == custom
    assert save.saves_dir() == custom / "saves"
    assert save.slot_path(2) == custom / "saves" / "save_2.json"

    save.save(_new_game(), 2)
    assert save.slot_path(2).is_file()
    assert save.slot_path(2).is_relative_to(custom)


def test_default_profile_root_is_home_dot_sailage(
        monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(save.ENV_HOME, raising=False)
    assert save.PROFILE_DIR == Path.home() / ".sailage"
    assert save.profile_dir() == save.PROFILE_DIR


# --- Full round trip (docs/90-* §8.1) ---------------------------------------


def test_full_round_trip_restores_every_section_8_1_field() -> None:
    gs = _new_game()
    expected = gs.snapshot_keys()
    save.save(gs, 2)

    mutated_explored = _mutate_away(gs)
    assert gs.day == 77 and gs.gold == 123_456  # the mutation took

    assert save.load(gs, 2) is True

    after = gs.snapshot_keys()
    assert tuple(after) == SNAPSHOT_KEYS
    for key in SNAPSHOT_KEYS:
        assert after[key] == expected[key], key

    # The explored container is a FRESH set every load (the HUD/minimap
    # reference-identity reset rule) and holds the saved tiles again.
    assert gs.explored_tiles is not mutated_explored
    assert gs.explored_tiles is not expected["explored_tiles"]
    assert isinstance(gs.explored_tiles, set)
    assert gs.explored_tiles == expected["explored_tiles"]

    # Runtime-only world keys restart; `quests` is cleared on load.
    assert gs.world["clock_fraction"] == 0.0
    assert set(gs.world) == set(save.WORLD_KEYS) | {"clock_fraction"}
    assert gs.quests == []
    assert gs.locale == "en"
    assert "deployed" not in next(iter(gs.captain_states.values()))


# --- Refusal matrix (docs/90-* §8.2) ----------------------------------------


def test_refusal_matrix_returns_false_and_leaves_state_untouched(
        caplog: pytest.LogCaptureFixture) -> None:
    gs = _new_game()
    save.save(gs, 2)
    good = _read_payload(2)
    before = gs.snapshot_keys()
    before_explored = gs.explored_tiles

    def _drop_state_key(payload: dict[str, Any]) -> None:
        del payload["gold"]

    def _drop_world_key(payload: dict[str, Any]) -> None:
        del payload["world"]["wind_dir"]

    cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("version 0", lambda p: p.__setitem__("save_version", 0)),
        ("version 9", lambda p: p.__setitem__("save_version", 9)),
        ("version missing", lambda p: p.pop("save_version")),
        ("version string", lambda p: p.__setitem__("save_version", "1")),
        ("missing state key", _drop_state_key),
        ("missing world key", _drop_world_key),
        ("explored not base64",
         lambda p: p.__setitem__("explored_tiles", "not base64!")),
        ("explored not a string",
         lambda p: p.__setitem__("explored_tiles", 5)),
        ("explored wrong run length",
         lambda p: p.__setitem__("explored_tiles",
                                 _b64(b"\x00\x00\x00\x00\x00"))),
        ("explored unsorted",
         lambda p: p.__setitem__(
             "explored_tiles", _b64(_run(5, 0, 1) + _run(4, 0, 1)))),
        ("explored out of bounds",
         lambda p: p.__setitem__("explored_tiles", _b64(_run(2160, 0, 1)))),
        ("player.stats removed",
         lambda p: p["player"].__setitem__("stats", {})),
        ("player not an object", lambda p: p.__setitem__("player", [])),
        ("world x not an int",
         lambda p: p["world"]["position"].__setitem__("x", 1.5)),
        ("officer entry shape",
         lambda p: p.__setitem__(
             "officer_states", {"off": {"loyalty": 50}})),
        ("captain entry shape",
         lambda p: p.__setitem__(
             "captain_states", {"cap": {"status": "active"}})),
        ("permit flag not bool",
         lambda p: p["permits"].__setitem__("home", "yes")),
    ]

    with caplog.at_level(logging.ERROR, logger="server.save"):
        for name, mutate in cases:
            bad = copy.deepcopy(good)
            mutate(bad)
            _write_payload(2, bad)
            assert save.load(gs, 2) is False, name
            assert gs.snapshot_keys() == before, name
            assert gs.explored_tiles is before_explored, name

    messages = [record.getMessage() for record in caplog.records]
    assert sum("pre-release save" in message for message in messages) >= 4


def test_malformed_json_and_non_object_payloads_are_refused() -> None:
    gs = _new_game()
    save.save(gs, 2)
    before = gs.snapshot_keys()

    _write_text(2, "{ this is not JSON")
    assert save.load(gs, 2) is False
    assert gs.snapshot_keys() == before

    _write_text(2, "[]")
    assert save.load(gs, 2) is False
    assert gs.snapshot_keys() == before

    _write_text(2, "   \n")
    assert save.load(gs, 2) is False
    assert gs.snapshot_keys() == before

    save.slot_path(2).unlink()
    assert save.load(gs, 2) is False
    assert gs.snapshot_keys() == before


def test_out_of_range_slots_are_refused() -> None:
    gs = _new_game()
    before = gs.snapshot_keys()
    for slot in (-1, 0, 4):
        with pytest.raises(ValueError):
            save.save(gs, slot)
        assert save.load(gs, slot) is False
        assert gs.snapshot_keys() == before


# --- v8 explored-state codec (docs/90-* §8.1 version 8) ---------------------


def test_encode_explored_pins_the_hand_computed_run_bytes() -> None:
    # Empty set -> "" (the oracle's documented encoding).
    assert save.encode_explored(set()) == ""
    # One row, one run: [y=0][x0=0][len-1=2].
    assert _b64(_run(0, 0, 3)) == "AAAAAAIA"
    assert save.encode_explored({(0, 0), (1, 0), (2, 0)}) == "AAAAAAIA"
    # Two sorted rows: [y=1][x0=0][len-1=0] + [y=2][x0=5][len-1=1].
    assert _b64(_run(1, 0, 1) + _run(2, 5, 2)) == "AQAAAAAAAgAFAAEA"
    assert save.encode_explored({(5, 2), (6, 2), (0, 1)}) == \
        "AQAAAAAAAgAFAAEA"


def test_explored_round_trip_sorts_and_canonicalizes_rows() -> None:
    tiles = {(7, 3), (6, 3), (0, 1), (4319, 2), (0, 2)}
    text = save.encode_explored(tiles)
    assert save.decode_explored(text) == tiles

    raw = base64.b64decode(text)
    runs = [
        struct.unpack_from("<HHH", raw, offset)
        for offset in range(0, len(raw), save.EXPLORED_RUN_BYTES)
    ]
    assert runs == [(1, 0, 0), (2, 0, 0), (2, 4319, 0), (3, 6, 1)]


def test_encode_explored_wrap_normalizes_x() -> None:
    assert save.encode_explored({(4320, 7)}) == \
        save.encode_explored({(0, 7)})
    assert save.encode_explored({(-1, 7)}) == \
        save.encode_explored({(4319, 7)})
    # Seam neighbours stay two runs (x is not unwrapped/merged).
    seam = save.encode_explored({(4319, 7), (0, 7)})
    assert save.decode_explored(seam) == {(4319, 7), (0, 7)}


@pytest.mark.parametrize("text", [
    "not base64!",
    "AAA",
    "!!!!",
    _b64(b"\x00\x00\x00\x00\x00"),          # five bytes, not a run record
    _b64(_run(5, 0, 1) + _run(4, 0, 1)),    # rows unsorted
    _b64(_run(1, 0, 5) + _run(1, 3, 2)),    # overlapping runs
    _b64(_run(1, 0, 5) + _run(1, 5, 1)),    # touching runs
    _b64(_run(2160, 0, 1)),                 # y out of the 2160 band
    _b64(_run(0, 4319, 2)),                 # x0 + len > 4320
])
def test_decode_explored_rejects_invalid_runs(text: str) -> None:
    with pytest.raises(ValueError):
        save.decode_explored(text)


# --- Slot summaries (docs/90-* §0.3 hello.saves) ----------------------------


def test_list_saves_reports_the_hello_shape_and_empty_markers() -> None:
    gs = _new_game()
    empty = {"day": 0, "nation_id": "", "port_id": "", "gold": 0,
             "saved_at": 0}
    assert save.list_saves() == [
        {"slot": 1, **empty}, {"slot": 2, **empty}, {"slot": 3, **empty}]

    save.save(gs, 1)
    save.save(gs, 3)
    payload_one = _read_payload(1)
    entries = save.list_saves()

    assert [entry["slot"] for entry in entries] == [1, 2, 3]
    for entry in entries:
        assert set(entry) == SLOT_ENTRY_KEYS
    assert entries[0] == {
        "slot": 1,
        "day": gs.day,
        "nation_id": "portugal",
        "port_id": "lisbon",
        "gold": gs.gold,
        "saved_at": payload_one["saved_at"],
    }
    assert entries[1] == {"slot": 2, **empty}
    assert entries[2]["saved_at"] == _read_payload(3)["saved_at"]


def test_list_saves_treats_a_corrupt_slot_as_empty() -> None:
    gs = _new_game()
    save.save(gs, 1)

    _write_text(2, "{ broken")
    non_object = _read_payload(1)
    non_object["save_version"] = 9
    _write_payload(3, non_object)

    entries = save.list_saves()
    assert set(entries[1]) == SLOT_ENTRY_KEYS
    assert entries[1]["day"] == 0 and entries[1]["nation_id"] == ""
    assert set(entries[2]) == SLOT_ENTRY_KEYS
    assert entries[2]["saved_at"] == 0
    assert entries[0]["nation_id"] == "portugal"
