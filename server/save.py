"""server.save — save v1: profile dir + payload round-trip.

Frozen contract (``docs/90-ARCHITECTURE.md``):

  * §0.5 — files live under the profile dir ``~/.sailage/`` (the
    ``SAILAGE_HOME`` env var overrides it — the test seam); slots
    ``<profile>/saves/save_{1..3}.json``. ``SAVE_VERSION`` is **1** (the
    web era restarts the counter) and **no migration chain** exists.
  * §8.1 — the payload is the ``GameState.snapshot_keys()`` block (the
    •-marked fields, 36 keys) plus the three header keys
    ``save_version`` / ``saved_at`` / ``phase``; ``explored_tiles`` rides
    as the v8 RLE/base64 string (base64 of 6-byte little-endian runs
    ``[u16 y][u16 x0][u16 len−1]``, sorted strictly by ``(y, x0)``,
    non-overlapping/non-touching within a row, ``y < 2160``,
    ``x0 + len ≤ 4320``; empty = ``""``).
  * §8.2 — the whole load contract is the identity: a payload whose
    ``save_version`` is not exactly 1 is a **pre-release save** and is
    refused (``load`` returns ``False``, logs the standard reason, state
    untouched). Nothing is back-filled.

The parity oracle is ``autoload/save_system.gd`` (frozen read-only until
the M6 cutover): :func:`validate_payload` ports its per-block type/shape
rules, :func:`encode_explored` / :func:`decode_explored` port its run
builder/codec, and :func:`list_saves` emits the §0.3 ``hello.saves`` entry
shape. The five Phase-7 allegiance keys restore through the documented
``allegiance.restore_state`` seam, exactly as the oracle hands its payload
to ``Allegiance.restore_state``.

M2 seam: :func:`save` / :func:`load` / :func:`list_saves` are the API the
FastAPI layer (``server/api/``, ``server/ws.py``) calls; this module owns
**no HTTP** and no request/response shape. Tests and tools inject the
profile through ``SAILAGE_HOME``; nothing here writes outside that root.
"""

from __future__ import annotations

import base64
import binascii
import copy
import json
import logging
import os
import struct
import tempfile
import time
from pathlib import Path
from typing import Any, Final

from server.sim.player import character, skills
from server.sim.port import allegiance
from server.sim.state import GameState, SNAPSHOT_KEYS
from server.sim.world import captains, sailing
from server.sim.world.raster import GRID_HEIGHT, GRID_WIDTH

__all__ = [
    "SAVE_VERSION",
    "SLOT_MIN",
    "SLOT_COUNT",
    "PHASE",
    "PROFILE_DIR",
    "STATE_KEYS",
    "WORLD_KEYS",
    "profile_dir",
    "saves_dir",
    "slot_path",
    "save",
    "load",
    "list_saves",
    "validate_payload",
    "encode_explored",
    "decode_explored",
]

logger = logging.getLogger(__name__)

# --- Frozen numbers (docs/90-* §0.5) -----------------------------------------

## The web era restarts the save counter at 1 (``90-*`` §0.5): the §8.2
## no-migration discipline carries over verbatim — any other value is a
## pre-release save.
SAVE_VERSION: Final[int] = 1
## Three slots, the Godot UX count (``90-*`` §0.5, ``80-*`` §4.6).
SLOT_MIN: Final[int] = 1
SLOT_COUNT: Final[int] = 3
## The payload's phase stamp. The web stack writes the string ``"web"``
## (the oracle wrote its integer phase); it is display-only.
PHASE: Final[str] = "web"

## The profile root (``90-*`` §0.5). ``SAILAGE_HOME`` overrides it; the
## constant is the default and remains patchable for a test that prefers
## monkeypatching over the env seam.
PROFILE_DIR: Final[Path] = Path.home() / ".sailage"
SAVES_DIR_NAME: Final[str] = "saves"
SAVE_PREFIX: Final[str] = "save_"
SAVE_EXT: Final[str] = ".json"
ENV_HOME: Final[str] = "SAILAGE_HOME"

## The 36 §8.1 state keys (exactly ``GameState.snapshot_keys()``), in the
## oracle's order minus the three header keys.
STATE_KEYS: Final[tuple[str, ...]] = SNAPSHOT_KEYS
## The eight persisted ``world`` keys (``clock_fraction`` is runtime-only,
## ``20-*`` §4.3).
WORLD_KEYS: Final[tuple[str, ...]] = (
    "position", "weather", "map_id", "last_departed_port",
    "hunter_intel_cell", "sail_trim", "heading", "wind_dir",
)
## Header keys a loadable payload must carry. ``saved_at`` is display-only
## (the oracle defaults it to 0) and is therefore not required.
REQUIRED_HEADERS: Final[tuple[str, ...]] = ("save_version", "phase")

## The v8 explored grid (``90-*`` §8.1 version 8): the single shipped map.
EXPLORED_RUN_BYTES: Final[int] = 6

## Enum domains mirrored from the owning runtime modules (the oracle's
## ``TRIM_STATES`` / ``COMPASS_DIRS`` / ``INPUT_MODES`` / ``CURRENT_MODES``).
_INPUT_MODES: Final[tuple[str, ...]] = ("step", "helm")
_CURRENT_MODES: Final[tuple[str, ...]] = ("modifier", "drift")
_TRIM_STATES: Final[tuple[str, ...]] = sailing.TRIM_STATES
_COMPASS_DIRS: Final[tuple[str, ...]] = sailing.COMPASS_DIRS
_MAP_ID: Final[str] = "world"


# --- Profile paths (docs/90-* §0.5) ------------------------------------------


def profile_dir() -> Path:
    """The profile root: ``$SAILAGE_HOME`` when set, else ``PROFILE_DIR``.

    Read at call time so the env override is a real test seam and a
    long-lived server process never caches a stale root.
    """
    override = os.environ.get(ENV_HOME)
    if override:
        return Path(override).expanduser()
    return PROFILE_DIR


def saves_dir() -> Path:
    """``<profile>/saves`` (``90-*`` §0.5)."""
    return profile_dir() / SAVES_DIR_NAME


def slot_path(slot: int) -> Path:
    """``<profile>/saves/save_<slot>.json`` — the only path a write uses."""
    return saves_dir() / f"{SAVE_PREFIX}{int(slot)}{SAVE_EXT}"


def _check_slot(slot: int) -> None:
    """Raises ``ValueError`` for a slot outside 1…3."""
    if (not isinstance(slot, int) or isinstance(slot, bool)
            or not (SLOT_MIN <= slot < SLOT_MIN + SLOT_COUNT)):
        raise ValueError(
            f"slot {slot!r} out of range {SLOT_MIN}..{SLOT_MIN + SLOT_COUNT - 1}")


# --- Save (docs/90-* §8.1) ---------------------------------------------------


def save(state: GameState, slot: int) -> None:
    """Writes slot ``slot`` from ``state`` (``90-*`` §8.1/§8.2).

    The payload is :meth:`GameState.snapshot_keys` plus the three header
    keys; ``explored_tiles`` is encoded by :func:`encode_explored`.
    Serialization is byte-deterministic (``sort_keys=True, indent=2`` plus
    one trailing newline) and the write is atomic: a temp file in the same
    directory is ``os.replace``d over the slot, so a crash never leaves a
    half-written save.

    The caller owns the "saving only at port" UX rule (``80-*`` §4.6) —
    this low-level writer snapshots any state so tools/tests can use it.
    Raises ``ValueError`` for an out-of-range slot.
    """
    _check_slot(slot)
    payload: dict[str, Any] = state.snapshot_keys()
    payload["explored_tiles"] = encode_explored(payload["explored_tiles"])
    payload["save_version"] = SAVE_VERSION
    payload["saved_at"] = int(time.time())
    payload["phase"] = PHASE

    text = json.dumps(payload, sort_keys=True, indent=2) + "\n"
    path = slot_path(slot)
    path.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(path, text)


def _atomic_write(path: Path, text: str) -> None:
    """Writes ``text`` to ``path`` via a same-directory temp file."""
    handle, temp_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as file:
            file.write(text)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp_path, path)
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        raise


# --- Load (docs/90-* §8.1, §8.2) ---------------------------------------------


def load(state: GameState, slot: int) -> bool:
    """Reads, validates and restores slot ``slot`` into ``state``.

    Returns ``True`` only after a fully validated payload was applied. On
    any failure — bad slot, missing/unreadable/corrupt file, wrong
    ``save_version`` (the §8.2 pre-release refusal), missing key or a
    malformed block — returns ``False`` and leaves ``state`` untouched:
    :func:`validate_payload` runs to completion before the first write.
    """
    try:
        _check_slot(slot)
    except ValueError as error:
        logger.error("save.load: %s", error)
        return False
    payload = _read_slot(slot)
    if payload is None:
        logger.error("save.load: slot %d is not readable", slot)
        return False
    reason = validate_payload(payload)
    if reason:
        logger.error("save.load: slot %d refused: %s", slot, reason)
        return False
    _apply(state, payload)
    return True


def _read_slot(slot: int) -> dict[str, Any] | None:
    """Parses one slot without touching state; ``None`` on any read error."""
    path = slot_path(slot)
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        logger.error("save.load: no save file at %s", path)
        return None
    except OSError as error:
        logger.error("save.load: cannot read %s (%s)", path, error)
        return None
    if not text.strip():
        logger.error("save.load: %s is empty", path)
        return None
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        logger.error("save.load: corrupt JSON in %s (%s)", path, error)
        return None
    if not isinstance(data, dict):
        logger.error("save.load: top level of %s is not an object", path)
        return None
    return data


def validate_payload(data: object) -> str:
    """Returns ``""`` when ``data`` is a loadable save-v1 payload.

    Port of ``SaveSystem.validate_payload`` (the oracle): the version
    window runs first (an older payload is honestly a "pre-release save",
    not a missing-key error), then the §8.1 key inventory, then every
    block's type/shape rule. This is a **pure** function — the caller may
    apply only after it returns ``""``, which is what makes "state
    untouched" true by construction.
    """
    if not isinstance(data, dict):
        return "payload is not an object"
    if not data:
        return "empty payload"

    # §8.2: the version window comes first — the shape of another version
    # may legitimately differ, so "pre-release save" is the honest reason.
    version = data.get("save_version")
    if not _is_int(version):
        return (f"pre-release save (invalid save_version {version!r}; "
                f"this build reads {SAVE_VERSION})")
    if version != SAVE_VERSION:
        return (f"pre-release save_version {int(version)} "
                f"(this build reads {SAVE_VERSION})")

    for key in REQUIRED_HEADERS:
        if key not in data:
            return f"missing required key {key!r}"
    if not isinstance(data["phase"], str):
        return "'phase' is not a string"
    if "saved_at" in data and not _is_int(data["saved_at"]):
        return "'saved_at' is not an integer"

    # The 36 §8.1 state keys are all written by this build, so a missing
    # one is a refusal (no back-fill; §8.2).
    for key in STATE_KEYS:
        if key not in data:
            return f"missing required key {key!r}"

    # -- header-ish scalar fields ------------------------------------------
    if not isinstance(data["locale"], str):
        return "'locale' is not a string"
    for key in ("day", "gold", "morale"):
        if not _is_int(data[key]):
            return f"'{key}' is not an integer"

    # -- opaque-but-typed blocks (the oracle treats player/fleet so) --------
    if not isinstance(data["player"], dict):
        return "'player' is not an object"
    player_error = _player_error(data["player"])
    if player_error:
        return player_error
    if not isinstance(data["fleet"], list):
        return "'fleet' is not an array"
    if not isinstance(data["known_ports"], list):
        return "'known_ports' is not an array"
    if not isinstance(data["port_investments"], dict):
        return "'port_investments' is not an object"
    for port_id, amount in data["port_investments"].items():
        if not _is_int(amount):
            return f"'port_investments.{port_id}' is not an integer"
    port = data["current_port"]
    if port is not None and not isinstance(port, str):
        return "'current_port' is neither a port id nor null"

    # -- v8 explored-state amendment (90-* §8.1 version 8) ------------------
    explored_error = _explored_error(data["explored_tiles"])
    if explored_error:
        return explored_error

    # -- world: the eight persisted keys, typed (90-* §8.1) -----------------
    if not isinstance(data["world"], dict):
        return "'world' is not an object"
    world_error = _world_error(data["world"])
    if world_error:
        return world_error

    # -- Phase-1/2/3 array/object blocks ------------------------------------
    for key in (
        "discoveries_found", "npc_fleets", "wrecks", "market_events",
        "active_quests", "discoveries_reported",
    ):
        if not isinstance(data[key], list):
            return f"'{key}' is not an array"
    for key in (
        "proximity_cooldowns", "market_stocks", "titles", "bounties",
        "completed_royal_missions", "discovery_hints",
    ):
        if not isinstance(data[key], dict):
            return f"'{key}' is not an object"
    if not isinstance(data["npc_preset"], str):
        return "'npc_preset' is not a string"
    for key in ("fame", "battles_won", "retired_at"):
        if not _is_int(data[key]):
            return f"'{key}' is not an integer"
    if not isinstance(data["retired"], bool):
        return "'retired' is not a boolean"

    # -- Phase-6 control preferences (90-* §8.1) ----------------------------
    if not isinstance(data["control_prefs"], dict):
        return "'control_prefs' is not an object"
    prefs = data["control_prefs"]
    if "input_mode" in prefs:
        if (not isinstance(prefs["input_mode"], str)
                or prefs["input_mode"] not in _INPUT_MODES):
            return "'control_prefs.input_mode' is not an input-mode id"
    if "current_mode" in prefs:
        if (not isinstance(prefs["current_mode"], str)
                or prefs["current_mode"] not in _CURRENT_MODES):
            return "'control_prefs.current_mode' is not a current-mode id"

    # -- Phase-8 officer/captain state blocks (90-* §8.1 version 9) --------
    if not isinstance(data["officer_states"], dict):
        return "'officer_states' is not an object"
    for officer_id, entry in data["officer_states"].items():
        officer_error = _officer_state_error(str(officer_id), entry)
        if officer_error:
            return officer_error
    if not isinstance(data["captain_states"], dict):
        return "'captain_states' is not an object"
    for captain_id, entry in data["captain_states"].items():
        captain_error = _captain_state_error(str(captain_id), entry)
        if captain_error:
            return captain_error

    # -- Phase-7 allegiance keys (90-* §8.1 Phase-7 additions) -------------
    permits_error = _permits_error(data["permits"])
    if permits_error:
        return permits_error
    if not isinstance(data["port_allegiance"], dict):
        return "'port_allegiance' is not an object"
    for port_id, entry in data["port_allegiance"].items():
        allegiance_error = _port_allegiance_error(str(port_id), entry)
        if allegiance_error:
            return allegiance_error
    for key in ("month_invested", "nation_treasuries"):
        if not isinstance(data[key], dict):
            return f"'{key}' is not an object"
        for map_key, value in data[key].items():
            if not _is_int(value):
                return f"'{key}.{map_key}' is not an integer"
    if not isinstance(data["fame_commended"], dict):
        return "'fame_commended' is not an object"
    for port_id, value in data["fame_commended"].items():
        if not isinstance(value, bool):
            return f"'fame_commended.{port_id}' is not a boolean"

    return ""


def _player_error(player: dict[str, Any]) -> str:
    """The v9 Person block's malformed cases (``50-*`` §4.8).

    The interior is otherwise opaque, but ``player.stats`` is deleted at
    v9 with no migration (a payload still carrying it is malformed) and
    the typed sub-blocks are checked whenever present — the same
    refuse-loudly rule as every other block in the oracle.
    """
    if "stats" in player:
        return "'player.stats' is removed at save v9 (docs/50-* §4.8)"
    if not _is_dict_or_missing(player, "attributes"):
        return "'player.attributes' is not an object"
    attributes = player.get("attributes")
    if isinstance(attributes, dict):
        if len(attributes) != len(character.ATTRIBUTES):
            return "'player.attributes' is not the 5-attribute block"
        for key, value in attributes.items():
            if key not in character.ATTRIBUTES:
                return f"'player.attributes' carries unknown attribute {key!r}"
            if (not _is_int(value) or value < character.ATTR_MIN
                    or value > character.ATTR_MAX):
                return (f"'player.attributes.{key}' is not an integer in "
                        f"{character.ATTR_MIN}..{character.ATTR_MAX}")
    if not _is_dict_or_missing(player, "skills"):
        return "'player.skills' is not an object"
    if isinstance(player.get("skills"), dict):
        if not _is_skill_block(
                player["skills"], skills.SKILL_MIN, skills.SKILL_MAX):
            return (f"'player.skills' is not the 8-skill block "
                    f"(0..{skills.SKILL_MAX})")
    if not _is_dict_or_missing(player, "skill_counters"):
        return "'player.skill_counters' is not an object"
    if isinstance(player.get("skill_counters"), dict):
        if not _is_skill_block(player["skill_counters"], 0, -1):
            return "'player.skill_counters' is not the 8-counter block (>= 0)"
    if "alloc_pending" in player:
        if not _is_int(player["alloc_pending"]) or player["alloc_pending"] < 0:
            return "'player.alloc_pending' is not a non-negative integer"
    if not _is_dict_or_missing(player, "autopilot"):
        return "'player.autopilot' is not an object"
    autopilot = player.get("autopilot")
    if isinstance(autopilot, dict):
        if len(autopilot) != 1 or "dest_port_id" not in autopilot:
            return "'player.autopilot' is not the {dest_port_id} shape"
        if not isinstance(autopilot["dest_port_id"], str):
            return "'player.autopilot.dest_port_id' is not a port id"
    return ""


def _world_error(world: dict[str, Any]) -> str:
    """The eight persisted ``world`` keys, typed (``90-*`` §8.1)."""
    for key in WORLD_KEYS:
        if key not in world:
            return f"'world' is missing the persisted key {key!r}"
    position = world["position"]
    if not isinstance(position, dict):
        return "'world.position' is not an object"
    for axis in ("x", "y"):
        if not _is_int(position.get(axis)):
            return f"'world.position.{axis}' is not an integer"
    if not isinstance(world["weather"], str):
        return "'world.weather' is not a weather id"
    if not isinstance(world["map_id"], str) or world["map_id"] != _MAP_ID:
        return "'world.map_id' is not the shipped map id"
    if not isinstance(world["last_departed_port"], str):
        return "'world.last_departed_port' is not a string"
    intel = world["hunter_intel_cell"]
    if intel is not None and not isinstance(intel, dict):
        return "'world.hunter_intel_cell' is neither a tile object nor null"
    if isinstance(intel, dict):
        for axis in ("x", "y"):
            if axis in intel and not _is_int(intel[axis]):
                return f"'world.hunter_intel_cell.{axis}' is not an integer"
    for key in ("sail_trim", "heading", "wind_dir"):
        if not isinstance(world[key], str):
            return f"'world.{key}' is not a direction/trim id"
    if world["sail_trim"] not in _TRIM_STATES:
        return "'world.sail_trim' is not a sail-trim state"
    for key in ("heading", "wind_dir"):
        if world[key] not in _COMPASS_DIRS:
            return f"'world.{key}' is not an 8-dir id"
    return ""


def _permits_error(permits: Any) -> str:
    """The Phase-7 ``permits`` shape ``{home: bool, foreign: {id: bool}}``."""
    if not isinstance(permits, dict):
        return "'permits' is not an object"
    if not isinstance(permits.get("home", False), bool):
        return "'permits.home' is not a boolean"
    foreign = permits.get("foreign", {})
    if not isinstance(foreign, dict):
        return "'permits.foreign' is not an object"
    for nation_id, value in foreign.items():
        if not isinstance(value, bool):
            return f"'permits.foreign.{nation_id}' is not a boolean"
    return ""


def _port_allegiance_error(port_id: str, entry: Any) -> str:
    """The correction-8 shape: exactly ``{ledger, allegiance}`` (dev is
    derived, never serialized — ``30-*`` §4.9)."""
    if not isinstance(entry, dict):
        return f"'port_allegiance.{port_id}' is not an object"
    if (len(entry) != 2 or "ledger" not in entry
            or "allegiance" not in entry):
        return (f"'port_allegiance.{port_id}' is not the correction-8 shape "
                "{ledger, allegiance}")
    ledger = entry["ledger"]
    if not isinstance(ledger, dict):
        return f"'port_allegiance.{port_id}.ledger' is not an object"
    for nation_id, amount in ledger.items():
        if not _is_int(amount):
            return (f"'port_allegiance.{port_id}.ledger.{nation_id}' "
                    "is not an integer")
    if not isinstance(entry["allegiance"], str):
        return f"'port_allegiance.{port_id}.allegiance' is not a nation id"
    return ""


def _officer_state_error(officer_id: str, entry: Any) -> str:
    """The v9 ``officer_states`` entry shape (``10-*`` §4.15, ``50-*`` §4.8):
    the seven base keys plus the two optional ones (``wage_mult``,
    ``skill_deltas``); any runtime-only extra key is a rejection."""
    if not isinstance(entry, dict):
        return f"'officer_states.{officer_id}' is not an object"
    base_keys = (
        "loyalty", "sea_days", "post_id", "ship_id", "talk_cd_day",
        "gift_cd_day", "defeats",
    )
    for key in base_keys:
        if key not in entry:
            return (f"'officer_states.{officer_id}' is not the v9 entry "
                    f"shape — missing {key!r}")
    allowed = set(base_keys) | {"wage_mult", "skill_deltas"}
    for key in entry:
        if key not in allowed:
            return (f"'officer_states.{officer_id}' carries the non-save "
                    f"key {key!r}")
    loyalty = entry["loyalty"]
    if (not _is_int(loyalty) or loyalty < skills.LOYALTY_MIN
            or loyalty > skills.LOYALTY_MAX):
        return (f"'officer_states.{officer_id}.loyalty' is not an integer "
                f"in {skills.LOYALTY_MIN}..{skills.LOYALTY_MAX}")
    for key in ("sea_days", "talk_cd_day", "gift_cd_day", "defeats"):
        value = entry[key]
        if not _is_int(value) or value < 0:
            return (f"'officer_states.{officer_id}.{key}' is not a "
                    "non-negative integer")
    for key in ("post_id", "ship_id"):
        if not isinstance(entry[key], str):
            return f"'officer_states.{officer_id}.{key}' is not a string"
    if "wage_mult" in entry:
        value = entry["wage_mult"]
        if not _is_number(value) or float(value) <= 0.0:
            return (f"'officer_states.{officer_id}.wage_mult' is not a "
                    "positive wage multiplier")
    if "skill_deltas" in entry:
        deltas = entry["skill_deltas"]
        if not isinstance(deltas, dict):
            return f"'officer_states.{officer_id}.skill_deltas' is not an object"
        skill_space = set(skills.KEYS) | set(skills.OFFICER_KEYS)
        for skill_id, value in deltas.items():
            if skill_id not in skill_space:
                return (f"'officer_states.{officer_id}.skill_deltas' names "
                        f"the unknown skill {skill_id!r}")
            if not _is_int(value) or value <= 0:
                return (f"'officer_states.{officer_id}.skill_deltas."
                        f"{skill_id}' is not a positive integer")
    return ""


def _captain_state_error(captain_id: str, entry: Any) -> str:
    """The v9 ``captain_states`` entry shape (``10-*`` §4.15): exactly the
    eight save keys (the runtime-only ``deployed`` flag is a rejection)."""
    if not isinstance(entry, dict):
        return f"'captain_states.{captain_id}' is not an object"
    keys = (
        "status", "return_day", "tier_now", "stance", "familiarity",
        "dossier_seen", "defeats", "wins",
    )
    if len(entry) != len(keys):
        return (f"'captain_states.{captain_id}' is not the v9 entry shape "
                "{status, return_day, tier_now, stance, familiarity, "
                "dossier_seen, defeats, wins}")
    for key in keys:
        if key not in entry:
            return (f"'captain_states.{captain_id}' is missing the save "
                    f"key {key!r}")
    status = entry["status"]
    if status not in (captains.STATUS_ACTIVE, captains.STATUS_RETURNING):
        return f"'captain_states.{captain_id}.status' is not a captain status id"
    return_day = entry["return_day"]
    if not _is_int(return_day) or return_day < 0:
        return (f"'captain_states.{captain_id}.return_day' is not a "
                "non-negative integer")
    tier = entry["tier_now"]
    if (not _is_int(tier) or tier < captains.TIER_MIN
            or tier > captains.TIER_MAX):
        return (f"'captain_states.{captain_id}.tier_now' is not a tier "
                f"{captains.TIER_MIN}..{captains.TIER_MAX}")
    stance = entry["stance"]
    if (not _is_int(stance) or stance < captains.STANCE_MIN
            or stance > captains.STANCE_MAX):
        return (f"'captain_states.{captain_id}.stance' is not a stance in "
                f"{captains.STANCE_MIN}..{captains.STANCE_MAX}")
    familiarity = entry["familiarity"]
    if (not _is_int(familiarity) or familiarity < captains.FAMILIARITY_MIN
            or familiarity > captains.FAMILIARITY_MAX):
        return (f"'captain_states.{captain_id}.familiarity' is not an "
                f"integer in {captains.FAMILIARITY_MIN}.."
                f"{captains.FAMILIARITY_MAX}")
    if not isinstance(entry["dossier_seen"], bool):
        return f"'captain_states.{captain_id}.dossier_seen' is not a boolean"
    for key in ("defeats", "wins"):
        value = entry[key]
        if not _is_int(value) or value < 0:
            return (f"'captain_states.{captain_id}.{key}' is not a "
                    "non-negative integer")
    return ""


def _apply(state: GameState, data: dict[str, Any]) -> None:
    """Copies a **validated** payload into ``state`` (the oracle's ``_apply``).

    Every conversion is computed *before* the first assignment, so an
    invalid payload can never leave a partially restored state; the
    explored container is always a fresh ``set`` (the HUD/minimap
    reference-identity reset rule, ``90-*`` §8.1 version 8).
    """
    # Pure pre-computation (no state write yet).
    world = _world_block(data["world"])
    explored = decode_explored(data["explored_tiles"])
    prefs = data["control_prefs"]
    control_prefs = {
        "input_mode": str(prefs.get("input_mode", "step")),
        "current_mode": str(prefs.get("current_mode", "modifier")),
    }
    current_port = data["current_port"]
    current_port = (
        str(current_port) if isinstance(current_port, str)
        and current_port else None
    )

    state.locale = _as_locale(str(data["locale"]))
    state.day = int(data["day"])
    state.gold = int(data["gold"])
    state.player = copy.deepcopy(data["player"])
    state.fleet = copy.deepcopy(data["fleet"])
    state.morale = max(0, min(sailing.MORALE_MAX, int(data["morale"])))
    state.world = world
    state.current_port = current_port
    state.known_ports = [str(port_id) for port_id in data["known_ports"]]
    state.explored_tiles = explored
    state.port_investments = {
        str(port_id): int(amount)
        for port_id, amount in data["port_investments"].items()
    }
    state.discoveries_found = copy.deepcopy(data["discoveries_found"])
    state.npc_fleets = copy.deepcopy(data["npc_fleets"])
    state.officer_states = copy.deepcopy(data["officer_states"])
    state.captain_states = copy.deepcopy(data["captain_states"])
    state.proximity_cooldowns = copy.deepcopy(data["proximity_cooldowns"])
    state.market_stocks = copy.deepcopy(data["market_stocks"])
    state.wrecks = copy.deepcopy(data["wrecks"])
    state.npc_preset = str(data["npc_preset"])
    state.control_prefs = control_prefs
    state.market_events = copy.deepcopy(data["market_events"])
    state.fame = int(data["fame"])
    state.titles = copy.deepcopy(data["titles"])
    state.bounties = copy.deepcopy(data["bounties"])
    state.active_quests = copy.deepcopy(data["active_quests"])
    state.completed_royal_missions = copy.deepcopy(
        data["completed_royal_missions"])
    state.discoveries_reported = copy.deepcopy(data["discoveries_reported"])
    state.discovery_hints = copy.deepcopy(data["discovery_hints"])
    state.battles_won = int(data["battles_won"])
    state.retired = bool(data["retired"])
    state.retired_at = int(data["retired_at"])

    # The Phase-7 keys restore through the documented allegiance seam: it
    # seeds first and re-derives the transient trackers, which is what
    # keeps a mid-month save/load replaying the month identically.
    allegiance.restore_state(state.store_or_default(), state, {
        "permits": data["permits"],
        "port_allegiance": data["port_allegiance"],
        "month_invested": data["month_invested"],
        "nation_treasuries": data["nation_treasuries"],
        "fame_commended": data["fame_commended"],
    })

    # The superseded Phase-1 placeholder is never saved and is cleared on
    # load even if a hand-edited payload carries it (``90-*`` §8.1).
    state.quests = []


def _world_block(world: dict[str, Any]) -> dict[str, Any]:
    """The runtime ``world`` dict: the eight persisted keys plus the
    runtime-only ``clock_fraction = 0.0`` (``20-*`` §4.3)."""
    position = world["position"]
    intel = world["hunter_intel_cell"]
    if isinstance(intel, dict):
        intel_payload: dict[str, int] | None = {
            "x": int(intel.get("x", 0)),
            "y": int(intel.get("y", 0)),
        }
    else:
        intel_payload = None
    return {
        "position": {"x": int(position["x"]), "y": int(position["y"])},
        "clock_fraction": 0.0,
        "weather": str(world["weather"]),
        "map_id": str(world["map_id"]),
        "last_departed_port": str(world["last_departed_port"]),
        "hunter_intel_cell": intel_payload,
        "sail_trim": str(world["sail_trim"]),
        "heading": str(world["heading"]),
        "wind_dir": str(world["wind_dir"]),
    }


def _as_locale(value: str) -> str:
    """The two locked locales, else the default ``"en"`` (``80-*`` §4.4)."""
    return value if value in ("zh", "en") else "en"


# --- Slot summaries (docs/90-* §0.3 hello.saves) -----------------------------


def list_saves() -> list[dict[str, Any]]:
    """The three slot summaries, in slot order.

    Each entry is exactly the §0.3 WS ``hello.saves`` shape
    ``{slot, day, nation_id, port_id, gold, saved_at}``. A missing,
    unreadable or corrupt slot is an all-zero/empty marker — never a
    crash and never a partially parsed row (``90-*`` §11).
    """
    return [_slot_summary(slot)
            for slot in range(SLOT_MIN, SLOT_MIN + SLOT_COUNT)]


def _slot_summary(slot: int) -> dict[str, Any]:
    empty: dict[str, Any] = {
        "slot": slot,
        "day": 0,
        "nation_id": "",
        "port_id": "",
        "gold": 0,
        "saved_at": 0,
    }
    try:
        if not slot_path(slot).exists():
            return empty
        data = _read_slot(slot)
        if data is None:
            return empty
        reason = validate_payload(data)
        if reason:
            logger.warning("save.list_saves: slot %d is invalid (%s)",
                           slot, reason)
            return empty
        player = data.get("player")
        player = player if isinstance(player, dict) else {}
        port_id = data.get("current_port")
        return {
            "slot": slot,
            "day": int(data.get("day", 0)),
            "nation_id": str(player.get("nation_id", "")),
            "port_id": str(port_id) if isinstance(port_id, str) else "",
            "gold": int(data.get("gold", 0)),
            "saved_at": int(data.get("saved_at", 0)),
        }
    except Exception:  # noqa: BLE001 - a corrupt slot must never crash the list
        logger.exception("save.list_saves: slot %d is unreadable", slot)
        return empty


# --- v8 explored-state codec (docs/90-* §8.1 version 8) ----------------------

_STRUCT_RUN = struct.Struct("<HHH")


def encode_explored(tiles: set[tuple[int, int]]) -> str:
    """The §8.1 ``explored_tiles`` string for a runtime explored set.

    Standard base64 (with padding) of 6-byte little-endian runs
    ``[u16 y][u16 x0][u16 len−1]``, sorted by ``(y, x0)``, merging
    touching/overlapping same-row tiles into one canonical run. ``x`` is
    wrap-normalized (``x mod 4320``, the ``20-*`` §4.12 convention) and
    tiles outside the latitude band are dropped. The empty set is ``""``.
    Deterministic: the same set always encodes to the same string, so a
    re-save stays byte-equal.

    (The oracle's keys are already wrap-normalized; normalizing here keeps
    the codec total for a tool/test that hands it an unwrapped tile.)
    """
    rows: dict[int, list[int]] = {}
    for cell in tiles:
        if not isinstance(cell, (tuple, list)) or len(cell) != 2:
            continue
        x, y = cell
        if (not _is_int(x) or not _is_int(y)
                or y < 0 or y >= GRID_HEIGHT):
            continue
        rows.setdefault(int(y), []).append(int(x) % GRID_WIDTH)

    encoded = bytearray()
    for y in sorted(rows):
        xs = sorted(set(rows[y]))
        index = 0
        while index < len(xs):
            start = xs[index]
            end = start
            index += 1
            while index < len(xs) and xs[index] <= end + 1:
                end = max(end, xs[index])
                index += 1
            encoded += _STRUCT_RUN.pack(y, start, end - start)
    if not encoded:
        return ""
    return base64.b64encode(bytes(encoded)).decode("ascii")


def decode_explored(text: str) -> set[tuple[int, int]]:
    """The runtime explored set for a §8.1 ``explored_tiles`` string.

    Raises ``ValueError`` for anything but the canonical encoding
    (invalid base64, a length that is not a multiple of 6, an
    out-of-domain run, or runs that are unsorted/overlapping/touching) —
    the validator turns that into the refuse-loudly reason. The empty
    string is the empty set; the returned set is always fresh.
    """
    if not isinstance(text, str):
        raise ValueError("explored_tiles is not a string")
    if text == "":
        return set()
    raw = _decode_base64(text)
    if len(raw) % EXPLORED_RUN_BYTES != 0:
        raise ValueError(
            f"explored_tiles is not a multiple of {EXPLORED_RUN_BYTES} bytes")
    tiles: set[tuple[int, int]] = set()
    previous_y = -1
    previous_end = -1
    for offset in range(0, len(raw), EXPLORED_RUN_BYTES):
        y, x0, span_minus_one = _STRUCT_RUN.unpack_from(raw, offset)
        span = span_minus_one + 1
        if y >= GRID_HEIGHT:
            raise ValueError(f"explored_tiles y {y} outside the grid")
        if x0 + span > GRID_WIDTH:
            raise ValueError(
                f"explored_tiles x-range {x0}..{x0 + span - 1} "
                "outside the grid")
        if y < previous_y or (y == previous_y and x0 <= previous_end + 1):
            raise ValueError("explored_tiles runs are not sorted/disjoint")
        previous_y = y
        previous_end = x0 + span - 1
        for dx in range(span):
            tiles.add((x0 + dx, y))
    return tiles


def _explored_error(value: Any) -> str:
    """``""`` when ``value`` is a loadable ``explored_tiles`` string."""
    if not isinstance(value, str):
        return "'explored_tiles' is not a string"
    try:
        decode_explored(value)
    except ValueError as error:
        return f"'explored_tiles' is invalid: {error}"
    return ""


def _decode_base64(text: str) -> bytes:
    """Strict standard base64 (the oracle's ``_is_strict_base64``): the
    § alphabet, padding only in the last one or two positions, a
    multiple-of-four length. ``base64.b64decode`` alone is too forgiving."""
    if not text or len(text) % 4 != 0:
        raise ValueError("not valid base64")
    alphabet = set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    for index, char in enumerate(text):
        if char == "=":
            if index < len(text) - 2:
                raise ValueError("not valid base64")
        elif char not in alphabet:
            raise ValueError("not valid base64")
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("not valid base64") from error


# --- Small type helpers (the oracle's _is_int/_is_dict_or_missing) -----------


def _is_int(value: object) -> bool:
    """True for a JSON integer; ``bool`` is its own type and never counts."""
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: object) -> bool:
    """True for a JSON number that is not a bool (``wage_mult`` floats)."""
    return (isinstance(value, (int, float))
            and not isinstance(value, bool))


def _is_dict_or_missing(data: dict[str, Any], key: str) -> bool:
    return key not in data or isinstance(data[key], dict)


def _is_skill_block(block: dict[str, Any], min_value: int,
                    max_value: int) -> bool:
    """Exactly the 8-skill key space with an integer in the given band;
    ``max_value < 0`` means no upper bound (the ≥ 0 counters)."""
    if len(block) != len(skills.KEYS):
        return False
    for skill_id, value in block.items():
        if skill_id not in skills.KEYS:
            return False
        if not _is_int(value) or value < min_value:
            return False
        if max_value >= 0 and value > max_value:
            return False
    return True
