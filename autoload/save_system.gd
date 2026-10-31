extends Node
## SaveSystem — full-state persistence in three slots
## (docs/90-ARCHITECTURE.md §5.5, §8.1, §8.2; UX: docs/80-UI-UX.md §4.6).
##
## Autoload #5 (last), so it may read every other singleton. It owns:
##   * `user://saves/save_%d.json` for slots 1…3 (write / read / list / delete);
##   * the §8.1 payload shape and the §8.2 version rule;
##   * the global `F5` quick-save / `F9` quick-load keys plus the slot dialog
##     flow, so every screen (world, port hub, facility screens, title) gets
##     the same behaviour from one place (docs/80-* §4.3, §4.6).
##
## Shape discipline (docs/90-* §8.1): the payload is exactly the •-marked
## `GameState` fields plus `save_version` / `saved_at` / `phase`. `player` and
## `fleet` are treated **opaquely** — their interior shapes belong to docs/50-*
## §4.8 and docs/40-* §4.1. `world.clock_fraction` is deliberately not written
## (docs/20-* §4.3: saving only happens in port, where it is 0) and
## `explored_tiles` is deliberately not written (docs/20-* §4.12).
##
## Load safety: a corrupt payload, a missing key, a version newer than this
## build or a payload from an older (pre-release) version all return `false`,
## log the reason and leave `GameState` **untouched** (the payload is validated
## in full before a single field is written).
##
## JSON gotcha: Godot's parser turns every number into a float, so a naive
## load would make `day`/`gold` floats and break the "byte-equal round trip"
## requirement. [method normalize_numbers] applies the same integral-float rule
## as `DataLoader._normalize_numbers` before anything is validated or applied.
##
## Quirk: this script defines a method named `load` (the §5.5 API). Inside this
## file the engine's global `load()` is therefore never called — scripts and
## scenes are fetched with `ResourceLoader.load()`.
##
## Versioning (docs/90-* §8.2 "development-stage scope"): Phase 5 ships
## [constant SAVE_VERSION] 5 and there is **no migration chain** (decision 5,
## `IMPLEMENT-Phase5.md`). SailAge has not shipped, so a payload whose
## `save_version` is anything but 5 — v4 included — is a pre-release save and
## is refused by name; the only migration that exists is the identity. The
## historical `1 → 2` / `2 → 3` steps lived here through Phase 3 and were
## deleted in Phase 4 rather than carried as dead weight.

# Preloaded rather than referenced through their global class names so this
# autoload parses before the editor has written Godot's class cache.
const CharacterLib := preload("res://scripts/player/character.gd")
## The v5 `market_stocks` derived-rest default (docs/30-* §4.2) is built
## through the economy module on load.
const EconomyLib := preload("res://scripts/port/economy.gd")
const SlotDialogLib := preload("res://scenes/ui_shared/save_slot_dialog.gd")

## Smallest/largest usable slot number (docs/90-* §5.5: three slots).
const SLOT_MIN := 1
const SLOT_COUNT := 3
## `user://saves/save_1.json` … `save_3.json` (docs/90-* §2, §5.5).
const SLOT_DIR := "user://saves"
const SAVE_PREFIX := "save_"
const SAVE_EXT := ".json"
## Written next to the real file, then renamed over it (atomic-ish).
const TEMP_EXT := ".tmp"

## Current payload version (docs/90-* §8.2: Phase 5 ships version 5).
const SAVE_VERSION := 5
## `phase` marker in the payload (docs/90-* §8.1).
const PHASE := 5

## Phase rank ids (docs/70-* §4.9.2), lowest first. A fresh game starts every
## nation at [constant RANK_NONE].
const RANK_NONE := "none"
const RANK_ORDER: Array[String] = [
	"none", "knight", "baron", "viscount", "count", "duke",
]
## The single shipped map id (docs/90-* §9.1, docs/10-* §6).
const DEFAULT_MAP_ID := "world"
## The §4.7 default weather a payload without a `world.weather` restores.
const DEFAULT_WEATHER := "calm"

## The •-marked GameState fields, in §8.1 order (minus the three header keys).
## v5 appends the four Phase-5 blocks after the Phase-2 pair (docs/90-* §8.1
## order); `hostile_fleets` keeps its key until task J's rename sweep.
const STATE_KEYS: Array[String] = [
	"locale", "day", "gold", "player", "fleet", "morale", "world",
	"current_port", "known_ports", "port_investments", "quests",
	"discoveries_found", "hostile_fleets", "proximity_cooldowns",
	"market_stocks", "wrecks", "npc_preset", "market_events",
	"fame", "titles", "bounties", "active_quests",
	"completed_royal_missions", "discoveries_reported", "discovery_hints",
	"battles_won", "retired", "retired_at",
]
## Keys every payload must carry for a load to be attempted. `quests` /
## `discoveries_found` are optional-but-known fields, `hostile_fleets` /
## `proximity_cooldowns` are optional Phase-2 fields (docs/90-* §8.1) and
## `saved_at` is display-only, so those five default instead of failing the
## load (docs/90-* §12 "load tolerates missing optional keys only where a
## default is documented").
const REQUIRED_KEYS: Array[String] = [
	"save_version", "phase", "locale", "day", "gold", "player", "fleet",
	"morale", "world", "current_port", "known_ports", "port_investments",
]
## Documented defaults for the optional keys (docs/90-* §12 "load tolerates
## missing optional keys only where a default is documented"). Every value here
## mirrors docs/90-* §8.1's "Default when absent" column; [method _apply] reads
## the absent-key value from it. A `const` dictionary is shared state, so every
## caller `.duplicate(true)`s the value on the way out.
##
## `market_stocks` is deliberately absent here: its documented default is the
## **derived resting stock** (docs/30-* §4.2, no RNG) — computed, not a
## literal — so `_apply` builds it through `Economy.build_initial_stocks`.
const OPTIONAL_DEFAULTS := {
	"saved_at": 0,
	"quests": [],
	"discoveries_found": [],
	"hostile_fleets": [],
	"proximity_cooldowns": {},
	"wrecks": [],
	"npc_preset": "normal",
	"market_events": [],
	"fame": 0,
	"titles": {},
	"bounties": {},
	"active_quests": [],
	"completed_royal_missions": {},
	"discoveries_reported": [],
	"discovery_hints": {},
	"battles_won": 0,
	"retired": false,
	"retired_at": 0,
}

## Scene paths (docs/90-* §4, §7).
const PORT_SCENE := "res://scenes/port/port_screen.tscn"
const WORLD_SCENE := "res://scenes/world/world_map.tscn"
const SLOT_DIALOG_SCENE := "res://scenes/ui_shared/save_slot_dialog.tscn"
const CONFIRM_DIALOG_SCENE := "res://scenes/ui_shared/confirm_dialog.tscn"
const DIALOG_BOX_SCENE := "res://scenes/ui_shared/dialog_box.tscn"
## S16 retirement summary (docs/70-* §4.7, docs/80-* §4.1).
const ENDING_SCENE := "res://scenes/ui_shared/ending_screen.tscn"
## T18 owns `normalize_all()` in this file (docs/40-* §6); the load path calls
## it dynamically so this script also runs while that function is still absent.
const FLEET_PATH := "res://scripts/fleet/fleet.gd"
## Transient ledger state (not persisted) is cleared through this path on load.
const SAILING_SIM_PATH := "res://scripts/world/sailing_sim.gd"

## Slider of the post-load capacity guard (docs/40-* §6). `available` mirrors
## whether `fleet.gd` defines `normalize_all()`; `truncated` is what it reported.
## Public so a test can assert the integration point honestly.
var last_normalize: Dictionary = {"available": false, "truncated": false}

## Last failure reason of [method read_save] / [method load] ("" when OK).
var last_read_error: String = ""

## True when the payload the last [method load] read was a **retired** save
## (`90-*` §8.1 `retired`, `70-*` §4.7): the run is over, so `load` restores
## nothing playable and the caller shows S16 in summary mode instead.
var last_loaded_retired: bool = false
## Summary block of the retired payload read last (`{}` while not retired):
## `{day, gold, fame, titles, discoveries, battles}` — exactly the six
## `ending.*` rows of `70-*` §4.7, so the screen never reads a stale GameState.
var last_retired_summary: Dictionary = {}

## Routing switch for [method load]'s UI flow, the same convention as
## `PortScreen.route_to_world`: with `false` a successful load still restores
## state and emits [signal load_completed] but does not replace the scene.
var route_after_load: bool = true

## Emitted after [method load] restored state (UI/tests observe the flow).
## Not an EventBus signal: docs/90-* §5.1 lists the cross-screen events it
## owns, and "a load finished" is local to SaveSystem + its caller.
signal load_completed(slot: int)


# --- Paths & queries (docs/90-* §5.5) ---------------------------------------

func is_valid_slot(slot: int) -> bool:
	return slot >= SLOT_MIN and slot < SLOT_MIN + SLOT_COUNT


## `user://saves/save_%d.json`; out-of-range slots still return a path so a
## caller can log it, but [method is_valid_slot] gates every public entry.
func slot_path(slot: int) -> String:
	return SLOT_DIR.path_join("%s%d%s" % [SAVE_PREFIX, slot, SAVE_EXT])


## True when a file exists for `slot` — it may still be unreadable; use
## [method read_save] before offering it as loadable.
func has_save(slot: int) -> bool:
	return is_valid_slot(slot) and FileAccess.file_exists(slot_path(slot))


## docs/80-* §4.6: saving is offered only while docked at a port. The UI keys
## (`F5`, the S4 Save row) consult this before touching a slot.
func can_save_here() -> bool:
	var port = GameState.current_port
	return port is String and not (port as String).is_empty()


## True when a run exists (the title screen has nothing to save).
func has_run() -> bool:
	return not GameState.player.is_empty() or not GameState.fleet.is_empty()


## Where a load routes: S4 when the save was taken in port, else S3
## (docs/80-* §4.6; docs/90-* §7).
func load_route_target() -> String:
	return PORT_SCENE if can_save_here() else WORLD_SCENE


# --- Save (docs/90-* §8.1) --------------------------------------------------

## The §8.1 payload for the current `GameState` (no file I/O).
func snapshot() -> Dictionary:
	# `world.position` is stored as the save-block `{"x","y"}` object; use the
	# tolerant `world_tile()` so a Vector2i left by movement code also works.
	var tile: Vector2i = GameState.world_tile()
	var world_payload := {
		"position": {"x": tile.x, "y": tile.y},
		"weather": str(GameState.world.get("weather", DEFAULT_WEATHER)),
		"map_id": str(GameState.world.get("map_id", DEFAULT_MAP_ID)),
	}
	return {
		"save_version": SAVE_VERSION,
		"saved_at": int(Time.get_unix_time_from_system()),
		"phase": PHASE,
		"locale": GameState.locale,
		"day": GameState.day,
		"gold": GameState.gold,
		"player": GameState.player.duplicate(true),
		"fleet": GameState.fleet.duplicate(true),
		"morale": GameState.morale,
		"world": world_payload,
		"current_port": GameState.current_port,
		"known_ports": GameState.known_ports.duplicate(),
		"port_investments": GameState.port_investments.duplicate(true),
		"discoveries_found": GameState.discoveries_found.duplicate(true),
		"hostile_fleets": GameState.hostile_fleets.duplicate(true),
		"proximity_cooldowns": GameState.proximity_cooldowns.duplicate(true),
		"market_stocks": GameState.market_stocks.duplicate(true),
		"wrecks": GameState.wrecks.duplicate(true),
		"npc_preset": GameState.npc_preset,
		"market_events": GameState.market_events.duplicate(true),
		"fame": GameState.fame,
		"titles": GameState.titles.duplicate(true),
		"bounties": GameState.bounties.duplicate(true),
		"active_quests": GameState.active_quests.duplicate(true),
		"completed_royal_missions": \
			GameState.completed_royal_missions.duplicate(true),
		"discoveries_reported": GameState.discoveries_reported.duplicate(),
		"discovery_hints": GameState.discovery_hints.duplicate(true),
		"battles_won": GameState.battles_won,
		"retired": GameState.retired,
		"retired_at": GameState.retired_at,
	}


## Writes slot `slot` and emits `EventBus.save_completed` (docs/90-* §5.1).
## Returns false (no signal) on any I/O failure.
##
## **Precondition:** the *callers* enforce docs/80-* §4.6 "saving only at port"
## — [method quick_save] toasts `ui.cant_save_here` when at sea, and the S4 row
## only exists on the port screen. This low-level writer performs no such check
## so a tool/test can snapshot an arbitrary state (and so a future autosave
## point, if the design ever gains one, would not have to fake a port).
##
## The payload is written to `save_%d.json.tmp` and renamed over the real file,
## so a crash mid-write can never leave a half-written save behind.
func save(slot: int) -> bool:
	if not is_valid_slot(slot):
		push_error("SaveSystem.save: slot %d out of range %d..%d"
			% [slot, SLOT_MIN, SLOT_MIN + SLOT_COUNT - 1])
		return false
	if not _ensure_slot_dir():
		push_error("SaveSystem.save: cannot create %s" % SLOT_DIR)
		return false
	var path := slot_path(slot)
	var temp_path := path + TEMP_EXT
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		push_error("SaveSystem.save: cannot open %s (error %d)"
			% [temp_path, FileAccess.get_open_error()])
		return false
	# Tab-indented JSON keeps a save diff-able and readable while still being
	# plain `JSON.parse_string` input for the round trip.
	file.store_string(JSON.stringify(snapshot(), "\t"))
	file.close()
	if DirAccess.rename_absolute(temp_path, path) != OK:
		push_error("SaveSystem.save: cannot move %s onto %s" % [temp_path, path])
		DirAccess.remove_absolute(temp_path)
		return false
	EventBus.save_completed.emit(slot)
	return true


## Removes slot `slot`. Returns false when there was nothing to remove.
func delete_save(slot: int) -> bool:
	if not is_valid_slot(slot):
		push_error("SaveSystem.delete_save: slot %d out of range" % slot)
		return false
	if not has_save(slot):
		return false
	return DirAccess.remove_absolute(slot_path(slot)) == OK


# --- Load (docs/90-* §8.2) --------------------------------------------------

## Reads, validates and restores slot `slot`.
##
## On any failure: returns false, logs the reason into [member last_read_error],
## pushes an error, and **never** writes to `GameState`. There is no migration
## chain (docs/90-* §8.2 development-stage scope): a payload whose version is
## not [constant SAVE_VERSION] is a pre-release save and is refused.
func load(slot: int) -> bool:
	last_read_error = ""
	last_loaded_retired = false
	last_retired_summary = {}
	if not is_valid_slot(slot):
		last_read_error = "slot %d out of range %d..%d" % [
			slot, SLOT_MIN, SLOT_MIN + SLOT_COUNT - 1
		]
		push_error("SaveSystem.load: " + last_read_error)
		return false
	var payload := _parse_slot(slot)
	if payload.is_empty():
		push_error("SaveSystem.load: slot %d is not readable (%s)"
			% [slot, last_read_error])
		return false
	var data := _accept(payload)
	if data.is_empty():
		push_error("SaveSystem.load: slot %d is unusable (%s)"
			% [slot, last_read_error])
		return false
	# docs/70-* §4.7: a retired run is not playable, and restoring it would let
	# the player resume a finished voyage. Report it instead; the caller routes
	# to S16 (`ending.retired_title`) and GameState is left untouched.
	if bool(data.get("retired", false)):
		last_loaded_retired = true
		last_retired_summary = retired_summary(data)
		load_completed.emit(slot)
		return true
	_apply(data)
	_normalize_fleet()
	load_completed.emit(slot)
	return true


## The six `ending.*` numbers of a payload (docs/70-* §4.7, §5 example). Pure:
## it reads the dict it is handed, so a retired slot can be summarised without
## touching `GameState`.
func retired_summary(data: Dictionary) -> Dictionary:
	var titles: Dictionary = _rank_map(data.get("titles", {}))
	var earned: Array = []
	for nation_id in titles:
		if str(titles[nation_id]) != RANK_NONE:
			earned.append([str(nation_id), str(titles[nation_id])])
	earned.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return {
		"day": int(data.get("day", 0)),
		"gold": int(data.get("gold", 0)),
		"fame": int(data.get("fame", 0)),
		"titles": earned,
		"discoveries": (data.get("discoveries_reported", []) as Array).size()
			if data.get("discoveries_reported", []) is Array else 0,
		"battles": int(data.get("battles_won", 0)),
		"retired_at": int(data.get("retired_at", 0)),
	}


## Parses + validates one slot without touching `GameState`. Returns `{}` and
## sets [member last_read_error] for a missing, unreadable, corrupt or
## version-incompatible file — the caller decides how loudly to complain
## ([method load] errors, [method list_saves] only warns).
func read_save(slot: int) -> Dictionary:
	var data := _parse_slot(slot)
	if data.is_empty():
		return {}
	var reason := validate_payload(data)
	if not reason.is_empty():
		last_read_error = reason
		return {}
	return data


## File → parsed dictionary, with only the "is this even a save file?" checks
## (exists, non-empty, parseable, top-level object, normalized numbers). The
## version window and shape belong to [method validate_payload].
func _parse_slot(slot: int) -> Dictionary:
	if not is_valid_slot(slot):
		last_read_error = "slot %d out of range" % slot
		return {}
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		last_read_error = "no save file at %s" % path
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		last_read_error = "%s is empty or unreadable" % path
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		last_read_error = "corrupt JSON at line %d: %s" % [
			parser.get_error_line(), parser.get_error_message()
		]
		return {}
	if not (parser.data is Dictionary):
		last_read_error = "top level of %s is not an object" % path
		return {}
	return normalize_numbers(parser.data)


## Returns "" when `data` is a loadable payload, else a short reason string.
## Runs **before** any `GameState` write, which is what makes "state untouched"
## on a bad file true by construction.
func validate_payload(data: Dictionary) -> String:
	if data.is_empty():
		return "empty payload"
	# The version window comes first: an old payload is a pre-release save and
	# its shape may legitimately differ (docs/90-* §8.2 dev-stage scope), so
	# "pre-release save_version N" is the honest reason, not a missing key.
	var version := int(data.get("save_version", 0))
	if version < 1:
		return "invalid save_version %d" % version
	if version > SAVE_VERSION:
		return "save_version %d is newer than %d" % [version, SAVE_VERSION]
	if version < SAVE_VERSION:
		return "pre-release save_version %d (this build reads %d)" % [
			version, SAVE_VERSION
		]
	for key in REQUIRED_KEYS:
		if not data.has(key):
			return "missing required key '%s'" % key
	if not (data["player"] is Dictionary):
		return "'player' is not an object"
	if not (data["fleet"] is Array):
		return "'fleet' is not an array"
	if not (data["world"] is Dictionary):
		return "'world' is not an object"
	if not (data["known_ports"] is Array):
		return "'known_ports' is not an array"
	if not (data["port_investments"] is Dictionary):
		return "'port_investments' is not an object"
	if not (data["current_port"] == null or data["current_port"] is String):
		return "'current_port' is neither a port id nor null"
	if not _is_array_or_missing(data, "quests"):
		return "'quests' is not an array"
	if not _is_array_or_missing(data, "discoveries_found"):
		return "'discoveries_found' is not an array"
	# Phase-2 keys: optional (absent → documented default) but type-checked
	# whenever they are present, so a hand-edited `hostile_fleets: {}` is a
	# rejection rather than a silent default (docs/90-* §8.1).
	if not _is_array_or_missing(data, "hostile_fleets"):
		return "'hostile_fleets' is not an array"
	if not _is_dict_or_missing(data, "proximity_cooldowns"):
		return "'proximity_cooldowns' is not an object"
	# Phase-5 keys (§8.1): optional (absent → documented default) but
	# type-checked whenever present, the same rule as the older blocks.
	# `market_stocks` absent defaults to the derived resting stock, so only a
	# *wrong-typed* value is a rejection here.
	if not _is_dict_or_missing(data, "market_stocks"):
		return "'market_stocks' is not an object"
	if not _is_array_or_missing(data, "wrecks"):
		return "'wrecks' is not an array"
	if not (not data.has("npc_preset") or data["npc_preset"] is String):
		return "'npc_preset' is not a string"
	if not _is_array_or_missing(data, "market_events"):
		return "'market_events' is not an array"
	# Phase-3 keys (§8.1): optional (absent → documented default) but
	# type-checked whenever present, the same rule as the Phase-2 pair above.
	if not _is_int_or_missing(data, "fame"):
		return "'fame' is not an integer"
	if not _is_dict_or_missing(data, "titles"):
		return "'titles' is not an object"
	if not _is_dict_or_missing(data, "bounties"):
		return "'bounties' is not an object"
	if not _is_array_or_missing(data, "active_quests"):
		return "'active_quests' is not an array"
	if not _is_dict_or_missing(data, "completed_royal_missions"):
		return "'completed_royal_missions' is not an object"
	if not _is_array_or_missing(data, "discoveries_reported"):
		return "'discoveries_reported' is not an array"
	if not _is_dict_or_missing(data, "discovery_hints"):
		return "'discovery_hints' is not an object"
	if not _is_int_or_missing(data, "battles_won"):
		return "'battles_won' is not an integer"
	if not (not data.has("retired") or data["retired"] is bool):
		return "'retired' is not a boolean"
	if not _is_int_or_missing(data, "retired_at"):
		return "'retired_at' is not an integer"
	var position = (data["world"] as Dictionary).get("position", null)
	if not (position is Dictionary):
		return "'world.position' is not an object"
	for axis in ["x", "y"]:
		if not (position as Dictionary).get(axis) is int:
			return "'world.position.%s' is not an integer" % axis
	# §8.1/§9.1: the single shipped map id. Phase 4 retired the dual-map pair,
	# so a payload naming either old id is a pre-release save and is refused
	# (docs/90-* §8.2 development-stage scope).
	var map_id = (data["world"] as Dictionary).get("map_id", DEFAULT_MAP_ID)
	if not (map_id is String) or (map_id as String) != "world":
		return "'world.map_id' is not the shipped map id"
	return ""


func _is_array_or_missing(data: Dictionary, key: String) -> bool:
	return not data.has(key) or data[key] is Array


func _is_dict_or_missing(data: Dictionary, key: String) -> bool:
	return not data.has(key) or data[key] is Dictionary


func _is_int_or_missing(data: Dictionary, key: String) -> bool:
	if not data.has(key):
		return true
	return data[key] is int and not (data[key] is bool)


## A `{nation_id: rank}` map with an unknown rank repaired to `"none"` (a
## hand-edited file must not wedge the ladder, `70-*` §4.9.2).
static func _rank_map(raw) -> Dictionary:
	var out: Dictionary = {}
	if raw is Dictionary:
		for nation_id in (raw as Dictionary):
			var rank := str((raw as Dictionary)[nation_id])
			out[str(nation_id)] = rank if rank in RANK_ORDER else RANK_NONE
	return out


## A `{nation_id: int}` map (royal-mission counters), values coerced to ≥ 0.
static func _int_map(raw) -> Dictionary:
	var out: Dictionary = {}
	if raw is Dictionary:
		for key in (raw as Dictionary):
			out[str(key)] = maxi(0, int((raw as Dictionary)[key]))
	return out


## An `[]id` payload key, coerced to strings.
static func _string_list(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for entry in (raw as Array):
			out.append(str(entry))
	return out


## Returns the payload when this build can load it, else `{}` with the reason in
## [member last_read_error]. docs/90-* §8.2 development-stage scope: the only
## migration is the identity, so a payload must carry exactly
## [constant SAVE_VERSION] and pass [method validate_payload] — which checks the
## version window (older = pre-release, newer = unknown build) before the shape.
func _accept(data: Dictionary) -> Dictionary:
	var reason := validate_payload(data)
	if not reason.is_empty():
		last_read_error = reason
		return {}
	return data


## Copies a validated payload into `GameState`. Only reached from [method load]
## after every check passed, so it can assume the §8.1 shape.
func _apply(data: Dictionary) -> void:
	# `locale` is a •-marked §5.4 field, so it is restored — through
	# `I18n.set_locale()` rather than a raw write, so every screen re-binds.
	# (A locale the build does not know falls back to the locked default.)
	I18n.set_locale(_as_locale(str(data.get("locale", "en"))))
	GameState.day = int(data.get("day", 0))
	GameState.gold = int(data.get("gold", 0))
	GameState.player = (data["player"] as Dictionary).duplicate(true)
	GameState.fleet = (data["fleet"] as Array).duplicate(true)
	# §4.8: morale is 0–100; a hand-edited file outside the band is repaired.
	GameState.morale = clampi(int(data.get("morale", 70)), 0, 100)
	_repair_level()

	# docs/20-* §4.3: `clock_fraction` is not saved; a load restarts the
	# sub-day clock at 0. `weather` and the Phase-3 `map_id` are §8.1 fields
	# and are restored.
	var world: Dictionary = data["world"]
	var position: Dictionary = world.get("position", {})
	GameState.world = {
		"position": {"x": int(position.get("x", 0)), "y": int(position.get("y", 0))},
		"clock_fraction": 0.0,
		"weather": str(world.get("weather", DEFAULT_WEATHER)),
		"map_id": str(world.get("map_id", DEFAULT_MAP_ID)),
	}

	var port = data.get("current_port", null)
	GameState.current_port = (
		str(port) if port is String and not (port as String).is_empty() else null
	)

	GameState.known_ports = []
	for entry in (data["known_ports"] as Array):
		GameState.known_ports.append(str(entry))

	var investments: Dictionary = {}
	var raw_investments: Dictionary = data["port_investments"]
	for port_id in raw_investments:
		investments[str(port_id)] = int(raw_investments[port_id])
	GameState.port_investments = investments

	# The Phase-1 `quests` placeholder is tolerated on read (§8.1 "Default when
	# absent") but is permanently empty from Phase 3 on — cleared at the end of
	# this method, so the payload value never survives.
	GameState.quests = []
	GameState.discoveries_found = \
		(data.get("discoveries_found", OPTIONAL_DEFAULTS["discoveries_found"]) \
			as Array).duplicate(true)
	# Phase-2 saved state (docs/90-* §8.1). A save this build wrote always
	# carries them, but a hand-edited file may omit them: the documented
	# defaults keep those loads working (§8.1 "Default when absent").
	GameState.hostile_fleets = \
		(data.get("hostile_fleets", OPTIONAL_DEFAULTS["hostile_fleets"]) as Array) \
			.duplicate(true)
	GameState.proximity_cooldowns = \
		(data.get("proximity_cooldowns", OPTIONAL_DEFAULTS["proximity_cooldowns"]) \
			as Dictionary).duplicate(true)
	# Phase-5 saved state (docs/90-* §8.1). `market_stocks` absent → the
	# documented derived-resting-stock default (docs/30-* §4.2, no RNG); the
	# other three default through OPTIONAL_DEFAULTS. All type-checked in
	# validate_payload before we get here.
	if data.get("market_stocks", null) is Dictionary:
		GameState.market_stocks = (data["market_stocks"] as Dictionary) \
			.duplicate(true)
	else:
		GameState.market_stocks = EconomyLib.build_initial_stocks(
			DataLoader.ports_list, DataLoader.goods_list
		)
	GameState.wrecks = \
		(data.get("wrecks", OPTIONAL_DEFAULTS["wrecks"]) as Array).duplicate(true)
	GameState.npc_preset = str(data.get("npc_preset",
		OPTIONAL_DEFAULTS["npc_preset"]))
	GameState.market_events = \
		(data.get("market_events", OPTIONAL_DEFAULTS["market_events"]) as Array) \
			.duplicate(true)
	# Phase-3 saved state (docs/90-* §8.1), same optional-with-documented-default
	# rule as the Phase-2 pair above.
	GameState.fame = maxi(0, int(data.get("fame", OPTIONAL_DEFAULTS["fame"])))
	GameState.titles = _rank_map(data.get("titles",
		OPTIONAL_DEFAULTS["titles"]))
	GameState.completed_royal_missions = _int_map(data.get(
		"completed_royal_missions", OPTIONAL_DEFAULTS["completed_royal_missions"]))
	GameState.bounties = \
		(data.get("bounties", OPTIONAL_DEFAULTS["bounties"]) as Dictionary) \
			.duplicate(true)
	GameState.active_quests = \
		(data.get("active_quests", OPTIONAL_DEFAULTS["active_quests"]) as Array) \
			.duplicate(true)
	GameState.discoveries_reported = _string_list(data.get(
		"discoveries_reported", OPTIONAL_DEFAULTS["discoveries_reported"]))
	GameState.discovery_hints = (data.get("discovery_hints",
		OPTIONAL_DEFAULTS["discovery_hints"]) as Dictionary).duplicate(true)
	GameState.battles_won = maxi(0, int(data.get("battles_won",
		OPTIONAL_DEFAULTS["battles_won"])))
	GameState.retired = bool(data.get("retired", OPTIONAL_DEFAULTS["retired"]))
	GameState.retired_at = int(data.get("retired_at",
		OPTIONAL_DEFAULTS["retired_at"]))
	# The superseded `quests` placeholder is never saved (§8.1: `active_quests`
	# is the one quest list) and is cleared on load even if a payload carries it.
	GameState.quests = []
	# docs/20-* §4.12: explored tiles are not part of the save (known Phase-1
	# limitation); the minimap re-reveals from the loaded position.
	GameState.explored_tiles = {}
	_reset_transient_sim_state()


## A load is "a new run, or a save load" for the sailing sim
## (`sailing_sim.gd#_maybe_reset_for_new_run`), but that automatic guess only
## fires when the day moves *backwards*: loading a save from a later day would
## otherwise inherit the previous run's starvation counters and its sticky
## `game_over_reason` (which freezes the clock). Resetting here is explicit and
## covers both directions. None of that state is persisted by design.
func _reset_transient_sim_state() -> void:
	var sim = ResourceLoader.load(SAILING_SIM_PATH)
	if sim == null or not sim.has_method("reset_ledger_state"):
		push_warning("SaveSystem: SailingSim.reset_ledger_state() unavailable; transient fail-state counters not cleared")
		return
	sim.call("reset_ledger_state")


## docs/50-* §4.8: `player.level` is a cache and "derivation wins on mismatch".
## The corrected value is logged, never silently dropped.
func _repair_level() -> void:
	if not GameState.player.has("level"):
		GameState.player["level"] = CharacterLib.level_for_xp(
			int(GameState.player.get("xp", 0))
		)
		return
	var stored := int(GameState.player.get("level", 1))
	var derived: int = CharacterLib.level_for_xp(int(GameState.player.get("xp", 0)))
	if stored != derived:
		push_warning("SaveSystem: player.level %d disagrees with xp (derived %d); xp wins (docs/50-* §4.8)"
			% [stored, derived])
		GameState.player["level"] = derived


## docs/40-* §6 capacity guard: T18's `Fleet.normalize_all()` runs after every
## successful deserialisation and reports whether it truncated anything.
##
## **Integration point.** `normalize_all()` is owned by T18 and does not exist in
## this worktree yet; a `preload(FLEET_PATH).normalize_all()` reference would not
## even compile before it lands. The call therefore goes through the *loaded*
## script, so the day T18 adds the function this path picks it up with **zero**
## edits to this file. Until then a load still succeeds (one logged warning): the
## guard is a corruption repair, not a validity rule.
##
## [method apply_fleet_guard] takes the script explicitly (default: `fleet.gd`)
## so the test suite can prove the call happens with a stand-in script while
## `fleet.gd` is untouched.
func _normalize_fleet() -> void:
	apply_fleet_guard()


## Runs the §6 guard against `fleet_script` (null → the real `fleet.gd`) and
## returns [member last_normalize].
func apply_fleet_guard(fleet_script = null) -> Dictionary:
	last_normalize = {"available": false, "truncated": false}
	var script = fleet_script
	if script == null:
		script = ResourceLoader.load(FLEET_PATH)
	if script == null:
		push_error("SaveSystem: cannot load %s; fleet capacity guard skipped" % FLEET_PATH)
		return last_normalize
	if not script.has_method("normalize_all"):
		push_warning("SaveSystem: Fleet.normalize_all() is missing (T18); over-capacity saves load without the capacity guard")
		return last_normalize
	var reported = script.call("normalize_all")
	var truncated := reported is bool and bool(reported)
	last_normalize = {"available": true, "truncated": truncated}
	if truncated:
		push_warning("SaveSystem: fleet capacity guard truncated cargo while loading (docs/40-* §6)")
	return last_normalize


# --- Slot summaries (docs/90-* §5.5, docs/80-* §4.6) ------------------------

## `[{slot, day, nation, port, gold, timestamp, valid, empty}]`, always three
## entries in slot order so the dialog can render rows 1…3 unconditionally.
## `valid == false` means "show `ui.save.invalid` and never select" (docs/80-*
## §4.6); `empty == true` means "show `ui.empty`".
func list_saves() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in range(SLOT_MIN, SLOT_MIN + SLOT_COUNT):
		out.append(slot_summary(slot))
	return out


func slot_summary(slot: int) -> Dictionary:
	var exists := has_save(slot)
	var entry := {
		"slot": slot,
		"day": 0,
		"nation": "",
		"port": "",
		"gold": 0,
		"timestamp": 0,
		"valid": false,
		# No file → free slot. A file that exists but does not load is NOT empty:
		# the dialog shows `ui.save.invalid` and disables the row in Load mode
		# (docs/80-* §4.6).
		"empty": not exists,
	}
	if not exists:
		return entry
	var data := read_save(slot)
	if data.is_empty():
		push_warning("SaveSystem: slot %d is invalid (%s)" % [slot, last_read_error])
		return entry
	var player: Dictionary = data.get("player", {})
	var port = data.get("current_port", null)
	entry["valid"] = true
	entry["day"] = int(data.get("day", 0))
	entry["nation"] = str(player.get("nation_id", ""))
	entry["port"] = str(port) if port is String else ""
	entry["gold"] = int(data.get("gold", 0))
	entry["timestamp"] = int(data.get("saved_at", 0))
	return entry


# --- UI flow (docs/80-* §4.6, §4.3) -----------------------------------------

## Opens the 3-slot dialog in Save or Load mode under `host` (default: the
## current scene). Returns the dialog control so a test/host can drive it.
func open_dialog(mode: int, host: Node = null) -> Control:
	var scene: PackedScene = ResourceLoader.load(SLOT_DIALOG_SCENE)
	if scene == null:
		push_error("SaveSystem: missing %s" % SLOT_DIALOG_SCENE)
		return null
	var dialog: Control = scene.instantiate()
	var parent := _dialog_parent(host)
	parent.add_child(dialog)
	dialog.slot_chosen.connect(func(slot: int) -> void: _on_slot_chosen(mode, slot))
	dialog.open(mode)
	return dialog


## S4 Save row / `F5` follow-up: the slot dialog in Save mode.
func open_save_dialog(host: Node = null) -> Control:
	return open_dialog(SlotDialogLib.MODE_SAVE, host)


## Title-screen Load: the slot dialog in Load mode.
func open_load_dialog(host: Node = null) -> Control:
	return open_dialog(SlotDialogLib.MODE_LOAD, host)


## `F5` (docs/80-* §4.3): quick-save to `slot`.
##
## * Not in port → toast `ui.cant_save_here`, **nothing is written**.
## * No run (title screen) → ignored silently.
## * Slot already holds a file → confirm overwrite first (docs/80-* §4.6;
##   applied to F5 too so the hotkey can never silently destroy a save).
## * Otherwise writes immediately and toasts `ui.saved`.
##
## Returns true when the request was accepted (written, or a confirm is up).
func quick_save(slot: int = SLOT_MIN) -> bool:
	if not has_run():
		return false
	if not can_save_here():
		_notify("ui.cant_save_here")
		return false
	if not is_valid_slot(slot):
		_notify("ui.invalid_slot")
		return false
	if has_save(slot):
		_confirm("ui.overwrite_confirm", {"slot": slot},
			func() -> void: _write_and_report(slot))
		return true
	return _write_and_report(slot)


## `F9` (docs/80-* §4.3): quick-load slot `slot` after a confirm.
## Returns true when the request was accepted (confirm shown or load started).
func quick_load(slot: int = SLOT_MIN) -> bool:
	if not is_valid_slot(slot):
		_notify("ui.invalid_slot")
		return false
	# A missing or unusable slot is reported immediately; there is nothing to
	# confirm and nothing to lose.
	if read_save(slot).is_empty():
		_notify("ui.invalid_slot")
		return false
	# Design gap: `ui_strings.json` has no "load slot N?" copy and T17 must not
	# add data keys (that file is owned elsewhere), so the confirm composes the
	# existing `ui.slot_n` + `ui.load.title` strings: "Slot 1 · Load game".
	_confirm_text(
		"%s · %s" % [I18n.fmt("ui.slot_n", {"slot": slot}), I18n.t_key("ui.load.title")],
		func() -> void: _load_and_route(slot)
	)
	return true


func _on_slot_chosen(mode: int, slot: int) -> void:
	if mode == SlotDialogLib.MODE_SAVE:
		# The dialog is normally only reachable from S4, but `open_save_dialog()`
		# is public API: never write from at sea (docs/80-* §4.6).
		if not can_save_here():
			_notify("ui.cant_save_here")
			return
		_write_and_report(slot)
	else:
		_load_and_route(slot)


func _write_and_report(slot: int) -> bool:
	var ok := save(slot)
	_notify("ui.saved" if ok else "ui.save_failed")
	return ok


func _load_and_route(slot: int) -> bool:
	# `self.` is required: unqualified `load()` resolves to the engine's global
	# resource loader, not this autoload's §5.5 `load(slot)` API.
	if not self.load(slot):
		_notify("ui.load_failed")
		return false
	if last_loaded_retired:
		# docs/70-* §4.7 / docs/80-* §4.2: a retired slot opens S16 in summary
		# mode and never re-enters play.
		if route_after_load:
			GameState.change_scene(ENDING_SCENE)
		return true
	if route_after_load:
		GameState.change_scene(load_route_target())
	return true


# --- Global input wiring (docs/80-* §4.3) -----------------------------------

## `F5` / `F9` are global: the autoload handles them so the hotkeys work on S3,
## S4, the facility screens and S1 with one implementation. A modal owns input
## first (docs/80-* §4.7 "modals consume all input"), so the keys are ignored
## while any dialog is up.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("quick_save"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		quick_save(SLOT_MIN)
		return
	if event.is_action_pressed("quick_load"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		quick_load(SLOT_MIN)


## True while any modal owns the screen (docs/80-* §4.7 "modals consume all
## input"): anything in the `modal_overlay` group, the HUD's queued dialog, or
## the S14 character panel (which is parent-agnostic and not in that group).
func _modal_open() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	for node in tree.get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	var scene := tree.current_scene
	if scene == null:
		return false
	for path in ["CharacterPanel", "CharacterPanelLayer/CharacterPanel"]:
		var panel := scene.get_node_or_null(path)
		if panel != null and panel.has_method("is_open") and panel.is_open():
			return true
	var hud := _find_hud(scene)
	return hud != null and hud.has_method("has_modal") and hud.has_modal()


# --- UI helpers -------------------------------------------------------------

## Picks the parent for a modal: the HUD's `ModalHost` when the current screen
## has a HUD (so the dialog dims the world map, a Node2D, correctly), else the
## current scene when it is a Control (title/port), else a dedicated high
## CanvasLayer (same trick as `CharacterPanel.attach_to`).
func _dialog_parent(host: Node = null) -> Node:
	if host != null:
		return host
	var tree := get_tree()
	var scene := tree.current_scene if tree != null else null
	if scene == null:
		return self
	var hud := _find_hud(scene)
	if hud != null:
		var modal_host := hud.get_node_or_null("ModalHost")
		if modal_host != null:
			return modal_host
	if scene is Control:
		return scene
	var layer := scene.get_node_or_null("SaveDialogLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "SaveDialogLayer"
		layer.layer = 100
		scene.add_child(layer)
	return layer


## First node under `root` (inclusive) that can show a toast (the shared HUD).
func _find_hud(root: Node) -> Node:
	if root == null:
		return null
	if root.has_method("toast_key"):
		return root
	for child in root.get_children():
		var found := _find_hud(child)
		if found != null:
			return found
	return null


## Transient feedback (docs/80-* §4.7: toast, 2.5s, max one). Falls back to a
## modal message when the screen has no HUD (the title screen), so a failure is
## never silent.
func _notify(key: String, values: Dictionary = {}) -> void:
	var hud := _find_hud(get_tree().current_scene if get_tree() != null else null)
	if hud != null:
		hud.toast_key(key, values)
		return
	var scene: PackedScene = ResourceLoader.load(DIALOG_BOX_SCENE)
	if scene == null:
		push_warning("SaveSystem: %s (no HUD and no dialog box to show it)" % key)
		return
	var box: Control = scene.instantiate()
	_dialog_parent().add_child(box)
	box.open_key(key, values)


## Shows a yes/no modal; `on_confirm` runs on confirm only (docs/80-* §4.7
## results leave through signals, never callbacks into another scene — this is
## a local closure owned by the dialog's own signal).
func _confirm(key: String, values: Dictionary, on_confirm: Callable) -> Control:
	var scene: PackedScene = ResourceLoader.load(CONFIRM_DIALOG_SCENE)
	if scene == null:
		push_error("SaveSystem: missing %s; cannot confirm" % CONFIRM_DIALOG_SCENE)
		return null
	var dialog: Control = scene.instantiate()
	_dialog_parent().add_child(dialog)
	dialog.open_key(key, values)
	dialog.confirmed.connect(on_confirm)
	return dialog


## [method _confirm] for an already-formatted (localised) line, used where the
## keys cannot express the sentence (see [method quick_load]).
func _confirm_text(text: String, on_confirm: Callable) -> Control:
	var scene: PackedScene = ResourceLoader.load(CONFIRM_DIALOG_SCENE)
	if scene == null:
		push_error("SaveSystem: missing %s; cannot confirm" % CONFIRM_DIALOG_SCENE)
		return null
	var dialog: Control = scene.instantiate()
	_dialog_parent().add_child(dialog)
	dialog.open_text(text)
	dialog.confirmed.connect(on_confirm)
	return dialog


# --- Small utilities --------------------------------------------------------

## Godot's JSON parser yields floats for every number; an integral float becomes
## an int so `day`, `gold`, ids-in-cargo and friends survive the round trip with
## their original `typeof` (the same rule as `DataLoader._normalize_numbers`).
static func normalize_numbers(node):
	if node is float:
		var value := node as float
		if is_finite(value) and value == floor(value) and absf(value) < 9.0e15:
			return int(value)
		return value
	if node is Array:
		var out: Array = []
		out.resize((node as Array).size())
		var index := 0
		for entry in (node as Array):
			out[index] = normalize_numbers(entry)
			index += 1
		return out
	if node is Dictionary:
		var out_dict: Dictionary = {}
		for key in (node as Dictionary):
			out_dict[key] = normalize_numbers((node as Dictionary)[key])
		return out_dict
	return node


static func _as_locale(value: String) -> String:
	# docs/80-* §4.4: only the two locked locales exist; anything else is a
	# hand-edited file and falls back to the locked default (§5.4).
	return value if value in ["zh", "en"] else "en"


func _ensure_slot_dir() -> bool:
	if DirAccess.dir_exists_absolute(SLOT_DIR):
		return true
	return DirAccess.make_dir_recursive_absolute(SLOT_DIR) == OK
