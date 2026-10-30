extends Node
## Phase-3 task A acceptance tests: save migration v2 → v3
## (docs/IMPLEMENT-Phase3.md A; docs/90-* §8.1, §8.2; docs/70-* §2, §4.7,
## §4.9.2, §4.9.8).
##
##   godot --headless --path . tools/test_save_v3.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved
## into memory and written back at the end; every file this suite creates is
## removed again (start AND end), exactly like `tools/test_save.gd`.

## The Phase-2 §8.1 keys — a v2 file carries exactly these plus the Phase-1
## ones, and nothing from Phase 3.
const V2_KEYS := [
	"save_version", "saved_at", "phase", "locale", "day", "gold", "player",
	"fleet", "morale", "world", "current_port", "known_ports",
	"port_investments", "quests", "discoveries_found", "hostile_fleets",
	"proximity_cooldowns",
]
## Every Phase-3 key of docs/90-* §8.1 and its documented default.
const V3_DEFAULTS := {
	"fame": 0,
	"bounties": {},
	"active_quests": [],
	"discoveries_reported": [],
	"discovery_hints": {},
	"battles_won": 0,
	"retired": false,
	"retired_at": 0,
}
const NATION_IDS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	_test_v2_load_and_resave()
	_test_migration_shape()
	_test_migration_purity()
	_test_chain_is_v1_to_v3()
	_test_corrupt_phase3_field_rejected()
	_test_new_fields_round_trip()
	_test_retired_save()
	_cleanup()
	_report()


# --- Fixture: a hand-written Phase-2 payload (docs/90-* §8.1) --------------

## A Phase-2 save exactly as a 2.0 build wrote it: every §8.1 key including
## `hostile_fleets`/`proximity_cooldowns`/the equipment blocks, `phase: 2`,
## and **no** Phase-3 field and no `world.map_id`.
##
## The fleet is capacity-compliant (flagship hold exactly full) so
## `Fleet.normalize_all()` is a no-op on load and "only the Phase-3 keys
## changed" can be asserted honestly.
func _v2_payload() -> Dictionary:
	return {
		"save_version": 2,
		"saved_at": 1793119712,
		"phase": 2,
		"locale": "en",
		"day": 64,
		"gold": 12540,
		"player": {
			"nation_id": "portugal",
			"stats": {
				"leadership": 12, "seamanship": 14, "combat": 11,
				"navigation": 21, "luck": 10,
			},
			"xp": 400,
			"level": 3,
			"officers": ["off_mateus_alvares"],
			"reputation": {
				"portugal": 31, "spain": -4, "england": 6, "holland": 0,
				"ottoman": 0, "italy": 0,
			},
			"profit_by_nation": {"england": 2100},
			"profit_rep_awarded": {"england": 2},
			"equipment": {"weapon": "eq_cutlass", "armor": ""},
		},
		"fleet": [
			{
				"ship_type_id": "caravel",
				"durability": 78,
				"crew": 30,
				"provisions": 40,
				"water": 30,
				"cannons": 6,
				"cargo": {"wine": 20},
				"equipment": {"figurehead": "", "sail": "eq_cotton_sails"},
			},
		],
		"morale": 61,
		"world": {"position": {"x": 14, "y": 50}, "weather": "fair"},
		"current_port": "lisbon",
		"known_ports": ["lisbon", "seville", "london", "madeira"],
		"port_investments": {"lisbon": 1000},
		"quests": [],
		"discoveries_found": [],
		"hostile_fleets": [],
		"proximity_cooldowns": {"pirate": 61},
	}


# --- 1. The done-when: a Phase-2 save loads and re-saves as version 3 ------

func _test_v2_load_and_resave() -> void:
	var fixture := _v2_payload()
	_ensure_dir()
	_check(_write_json(1, fixture), "the v2 fixture is written to slot 1")

	# The fixture really is v2-shaped (otherwise the test would prove nothing).
	var on_disk := _read_json(1)
	_check(not on_disk.is_empty(), "the written fixture parses as JSON")
	_check(int(on_disk.get("save_version", -1)) == 2,
		"the fixture is save_version 2 (got %s)" % str(on_disk.get("save_version")))
	_check(int(on_disk.get("phase", -1)) == 2, "the fixture is phase 2")
	var missing := []
	for key in V2_KEYS:
		if not on_disk.has(key):
			missing.append(key)
	_check(missing.is_empty(), "the fixture has every Phase-2 §8.1 key (missing %s)"
		% str(missing))
	_check(not on_disk.has("fame") and not on_disk.has("active_quests")
		and not on_disk.has("titles"),
		"the fixture has no Phase-3 keys")
	_check(not (on_disk["world"] as Dictionary).has("map_id"),
		"the fixture's world block has no map_id yet")

	# Quit-and-restart: wipe the state, then load the Phase-2 file.
	_clobber_state()
	_check(SaveSystem.load(1), "a Phase-2 save loads in Phase-3 code")
	_check(SaveSystem.last_read_error.is_empty(),
		"the load reports no error (got '%s')" % SaveSystem.last_read_error)
	_check(GameState.fame == 0, "migration set fame to 0")
	_check(_nation_map_is(GameState.titles, "none"),
		"migration set every nation's title to 'none' (got %s)" % str(GameState.titles))
	_check(_nation_map_is(GameState.completed_royal_missions, 0),
		"migration zeroed every nation's royal-mission count")
	_check(GameState.bounties == {} and GameState.bounties is Dictionary,
		"migration set bounties to {}")
	_check(GameState.active_quests == [] and GameState.active_quests is Array,
		"migration set active_quests to []")
	_check(GameState.discoveries_reported == [], "migration set discoveries_reported to []")
	_check(GameState.discovery_hints == {} and GameState.discovery_hints is Dictionary,
		"migration set discovery_hints to {}")
	_check(GameState.battles_won == 0, "migration set battles_won to 0")
	_check(GameState.retired == false and GameState.retired_at == 0,
		"migration set retired/retired_at to false/0")
	# Phase 4 (docs/90-* §8.2 dev-stage scope): the migration writes the
	# *current* default map id, not a historical one.
	_check(GameState.world.get("map_id") == "world",
		"migration set world.map_id to the current default (got %s)"
		% str(GameState.world.get("map_id")))
	_check(GameState.quests == [], "the superseded quests list is empty")

	# Nothing else moved: every pre-existing value survives.
	_check(GameState.day == 64 and typeof(GameState.day) == TYPE_INT,
		"day restored exactly (64, got %s)" % str(GameState.day))
	_check(GameState.gold == 12540, "gold restored exactly (12540)")
	_check(GameState.morale == 61, "morale restored exactly (61)")
	_check(GameState.current_port == "lisbon", "current_port restored (lisbon)")
	_check(GameState.world["position"] == {"x": 14, "y": 50},
		"world.position restored byte-equal")
	_check(GameState.world["weather"] == "fair", "world.weather restored (fair)")
	_check(GameState.known_ports == fixture["known_ports"],
		"known_ports restored byte-equal")
	_check(GameState.port_investments == fixture["port_investments"],
		"port_investments restored byte-equal")
	_check(GameState.proximity_cooldowns == {"pirate": 61},
		"proximity_cooldowns untouched by the 2 → 3 step")
	_check(GameState.player.get("equipment") == {"weapon": "eq_cutlass", "armor": ""},
		"the player equipment block is untouched")
	_check((GameState.fleet[0] as Dictionary).get("equipment")
		== {"figurehead": "", "sail": "eq_cotton_sails"},
		"the ship equipment block is untouched")

	# --- Re-save: the migrated run is written as version 3 -----------------
	_check(SaveSystem.save(1), "the migrated run re-saves to slot 1")
	var resaved := _read_json(1)
	_check(not resaved.is_empty(), "the re-saved file parses as JSON")
	_check(int(resaved.get("save_version", -1)) == 3,
		"the re-saved file is save_version 3 (got %s)"
		% str(resaved.get("save_version")))
	_check(int(resaved.get("phase", -1)) == 3,
		"the re-saved file is phase 3 (got %s)" % str(resaved.get("phase")))
	for key in V3_DEFAULTS:
		_check(resaved.has(key),
			"the re-saved file carries '%s' (docs/90-* §8.1)" % key)
	_check(not resaved.has("quests"),
		"the re-saved file has no superseded 'quests' key")
	_check((resaved["world"] as Dictionary).get("map_id") == "world",
		"the re-saved world block carries the current map id")
	_check(not (resaved["world"] as Dictionary).has("clock_fraction")
		and not resaved.has("explored_tiles"),
		"the re-save still omits clock_fraction / explored_tiles")

	# …and the version-3 file re-loads to the same state (second cycle).
	var first_cycle := _loaded_values()
	_clobber_state()
	_check(SaveSystem.load(1), "the re-saved version-3 file loads")
	_check(_loaded_values() == first_cycle, "a second save/load cycle changes nothing")


# --- 2. The migration's own output shape ----------------------------------

func _test_migration_shape() -> void:
	var input := _v2_payload()
	var out: Dictionary = SaveSystem.MIGRATIONS[2].call(input)
	_check(out != input, "MIGRATIONS[2] returns a different dict")
	_check(int(out["phase"]) == 3, "MIGRATIONS[2] sets phase = 3")
	_check(int(out.get("save_version", 2)) == 2,
		"MIGRATIONS[2] leaves save_version to _migrate() (still 2 here)")
	for key in ["fame", "bounties", "active_quests", "discoveries_reported",
			"discovery_hints", "battles_won", "retired", "retired_at"]:
		_check(key in out, "MIGRATIONS[2] adds '%s'" % key)
	_check(out["titles"] is Dictionary
		and (out["titles"] as Dictionary).size() == 6,
		"titles covers all six nations (got %s)" % str(out["titles"]))
	_check(_nation_map_is(out["titles"], "none"), "every title defaults to none")
	_check(_nation_map_is(out["completed_royal_missions"], 0),
		"every royal-mission count defaults to 0")
	_check(not out.has("quests"), "MIGRATIONS[2] drops the superseded 'quests' key")
	_check((out["world"] as Dictionary).get("map_id") == "world",
		"MIGRATIONS[2] adds world.map_id at the current default")

	# An absent/empty world block must not be synthesised.
	var no_world := _v2_payload()
	no_world["world"] = {}
	no_world["current_port"] = null
	var migrated: Dictionary = SaveSystem.MIGRATIONS[2].call(no_world)
	_check(migrated["world"] == {},
		"an empty world stays empty (map_id is not invented)")


# --- 3. The 2 → 3 function is pure ----------------------------------------

func _test_migration_purity() -> void:
	var input := _v2_payload()
	var before := input.duplicate(true)
	var out: Dictionary = SaveSystem.MIGRATIONS[2].call(input)
	_check(input == before, "MIGRATIONS[2] does not mutate its argument")
	# Dictionary equality is by value in Godot 4, so identity is asserted with
	# `is_same` — a shared reference would let a caller mutate the input.
	_check(not is_same(out["player"], input["player"]),
		"the returned player block is a copy, not the input's object")
	_check(not is_same(out["fleet"], input["fleet"]),
		"the returned fleet is a copy, not the input's array")
	_check(not is_same(out["world"], input["world"]),
		"the returned world block is a copy")

	# Titles/completed maps are fresh objects, never shared table state.
	var second: Dictionary = SaveSystem.MIGRATIONS[2].call(_v2_payload())
	(second["titles"] as Dictionary)["portugal"] = "duke"
	_check(str((out["titles"] as Dictionary)["portugal"]) == "none",
		"two migration calls never share the titles map")


# --- 4. A Phase-1 save climbs the whole chain ------------------------------

func _test_chain_is_v1_to_v3() -> void:
	# The v1 fixture from the Phase-2 suite, rebuilt here minimally: the point
	# is the chain, not the Phase-1 fields (test_save_v2 proves those).
	var v1 := _v2_payload()
	v1["save_version"] = 1
	v1["phase"] = 1
	v1.erase("hostile_fleets")
	v1.erase("proximity_cooldowns")
	(v1["player"] as Dictionary).erase("equipment")
	((v1["fleet"] as Array)[0] as Dictionary).erase("equipment")
	_ensure_dir()
	_write_json(1, v1)
	_clobber_state()
	_check(SaveSystem.load(1), "a Phase-1 save climbs 1 → 2 → 3")
	_check(SaveSystem.last_read_error.is_empty(),
		"the chained load reports no error (got '%s')" % SaveSystem.last_read_error)
	_check(SaveSystem.snapshot()["save_version"] == 3,
		"the chained run snapshots as version 3")
	_check(GameState.hostile_fleets == [] and GameState.proximity_cooldowns == {},
		"the 1 → 2 step still ran inside the chain")
	_check(GameState.player.get("equipment") == {"weapon": "", "armor": ""},
		"the 1 → 2 equipment default survives the chain")
	_check(_nation_map_is(GameState.titles, "none"),
		"the 2 → 3 title defaults survive the chain")


# --- 5. A wrong-typed Phase-3 field is rejected ----------------------------

func _test_corrupt_phase3_field_rejected() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	for probe in [
		{"key": "fame", "value": "lots", "why": "fame as a string"},
		{"key": "titles", "value": [], "why": "titles as an array"},
		{"key": "bounties", "value": 3, "why": "bounties as a number"},
		{"key": "active_quests", "value": {}, "why": "active_quests as an object"},
		{"key": "completed_royal_missions", "value": [], "why":
			"completed_royal_missions as an array"},
		{"key": "discoveries_reported", "value": {}, "why":
			"discoveries_reported as an object"},
		{"key": "discovery_hints", "value": [], "why": "discovery_hints as an array"},
		{"key": "battles_won", "value": "3", "why": "battles_won as a string"},
		{"key": "retired", "value": 1, "why": "retired as a number"},
		{"key": "retired_at", "value": "now", "why": "retired_at as a string"},
	]:
		var bad: Dictionary = SaveSystem.snapshot()
		bad[probe["key"]] = probe["value"]
		_write_json(1, bad)
		_check(SaveSystem.load(1) == false, "%s is rejected" % probe["why"])
		_check(SaveSystem.last_read_error.contains(str(probe["key"])),
			"the reason names %s (got '%s')"
			% [probe["key"], SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting %s" % probe["why"])

	# An unknown map id is rejected too (§8.1/§9.1: "world" is the only id).
	var bad_map: Dictionary = SaveSystem.snapshot()
	bad_map["world"] = {"position": {"x": 1, "y": 1}, "weather": "calm",
		"map_id": "p9"}
	_write_json(1, bad_map)
	_check(SaveSystem.load(1) == false, "an unknown world.map_id is rejected")
	_check(SaveSystem.last_read_error.contains("map_id"),
		"the reason names map_id (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before, "state untouched after the map-id rejection")


# --- 6. Every Phase-3 field is real saved state ----------------------------

func _test_new_fields_round_trip() -> void:
	_load_fixture_into_memory()
	GameState.fame = 480
	GameState.titles = {
		"portugal": "baron", "spain": "none", "england": "knight",
		"holland": "none", "ottoman": "none", "italy": "none",
	}
	GameState.bounties = {"spain": {"amount": 2350, "day": 66}}
	GameState.active_quests = [{
		"instance_id": "q_lisbon_9_0",
		"template_id": "qt_delivery_timber",
		"type": "delivery",
		"giver": "guild",
		"origin_port_id": "lisbon",
		"requirements": {"good_id": "timber", "quantity": 40,
			"dest_port_id": "tunis"},
		"rewards": {"gold": 1200, "reputation": {"ottoman": 5}, "fame": 10},
		"expiry_days": 20,
		"accepted_day": 64,
		"deadline_day": 84,
		"status": "active",
	}]
	GameState.completed_royal_missions = {
		"portugal": 2, "spain": 0, "england": 0,
		"holland": 0, "ottoman": 0, "italy": 0,
	}
	GameState.discoveries_reported = ["disc_atlas_cedars", "disc_red_sea_corals"]
	GameState.discovery_hints = {"disc_atlas_cedars": true}
	GameState.battles_won = 7
	var expected := _loaded_values()

	_check(SaveSystem.save(1), "a run with Phase-3 state saves")
	var on_disk := _read_json(1)
	_check(int(on_disk.get("fame", -1)) == 480, "snapshot() writes fame")
	_check((on_disk.get("titles") as Dictionary).get("portugal") == "baron",
		"snapshot() writes titles")
	_check(((on_disk.get("bounties") as Dictionary).get("spain") as Dictionary)
		.get("amount") == 2350, "snapshot() writes the bounty amount")
	_check((on_disk.get("active_quests") as Array).size() == 1,
		"snapshot() writes active_quests")
	_check((on_disk.get("discoveries_reported") as Array).size() == 2,
		"snapshot() writes discoveries_reported")
	_check((on_disk.get("discovery_hints") as Dictionary).has("disc_atlas_cedars"),
		"snapshot() writes discovery_hints")
	_check(int(on_disk.get("battles_won", -1)) == 7, "snapshot() writes battles_won")

	_clobber_state()
	_check(SaveSystem.load(1), "the v3 file with Phase-3 state loads")
	_check(_loaded_values() == expected,
		"every Phase-3 field restores byte-equal after a v3 round trip")
	_check(typeof(((GameState.bounties["spain"] as Dictionary)["amount"])) == TYPE_INT,
		"the bounty amount comes back as an int, not a json float")

	# The snapshot deep-copies: mutating live state cannot rewrite a save.
	var snap := SaveSystem.snapshot()
	GameState.titles["portugal"] = "duke"
	GameState.active_quests[0]["status"] = "failed"
	GameState.discoveries_reported.append("disc_mutated")
	_check((snap["titles"] as Dictionary)["portugal"] == "baron",
		"snapshot() deep-copies titles")
	_check(((snap["active_quests"] as Array)[0] as Dictionary)["status"] == "active",
		"snapshot() deep-copies active_quests")
	_check((snap["discoveries_reported"] as Array).size() == 2,
		"snapshot() deep-copies discoveries_reported")


# --- 7. A retired save is never playable ----------------------------------

func _test_retired_save() -> void:
	_load_fixture_into_memory()
	GameState.fame = 3100
	GameState.titles["portugal"] = "duke"
	GameState.completed_royal_missions["portugal"] = 8
	GameState.discoveries_reported = ["disc_atlas_cedars"]
	GameState.battles_won = 12
	GameState.retired = true
	GameState.retired_at = 1793120000
	_check(SaveSystem.save(1), "a retired run saves")
	var on_disk := _read_json(1)
	_check(bool(on_disk.get("retired", false)) is bool and on_disk["retired"] == true,
		"snapshot() writes retired: true (docs/70-* §4.7)")
	_check(int(on_disk.get("retired_at", 0)) == 1793120000,
		"snapshot() writes retired_at")

	_clobber_state()
	var before := _loaded_values()
	_check(SaveSystem.load(1), "a retired save still loads (as a summary)")
	_check(SaveSystem.last_loaded_retired,
		"load() reports the slot as retired")
	_check(_loaded_values() == before,
		"a retired load restores no play state (GameState untouched)")

	var summary: Dictionary = SaveSystem.last_retired_summary
	_check(int(summary.get("day", -1)) == 64, "the summary carries the day count")
	_check(int(summary.get("gold", -1)) == 12540, "the summary carries the gold")
	_check(int(summary.get("fame", -1)) == 3100, "the summary carries the fame")
	_check(int(summary.get("discoveries", -1)) == 1,
		"the summary counts reported discoveries")
	_check(int(summary.get("battles", -1)) == 12, "the summary carries battles won")
	_check((summary.get("titles") as Array) == [["portugal", "duke"]],
		"the summary lists every non-none title (got %s)" % str(summary.get("titles")))

	# list_saves/slot_summary keep reporting a retired slot as a valid save.
	_check(bool(SaveSystem.list_saves()[0]["valid"]),
		"a retired slot is still a valid, summarisable save")

	# …and a playable save clears the retired flags on the next load.
	_load_fixture_into_memory()
	_check(GameState.retired == false, "the fixture loads as a playable run")
	_check(SaveSystem.save(1), "the run re-saves as playable")
	_clobber_state()
	_check(SaveSystem.load(1), "the playable save loads")
	_check(not SaveSystem.last_loaded_retired,
		"a playable slot reports last_loaded_retired = false")
	_check(GameState.day == 64 and GameState.player.is_empty() == false,
		"a playable load restores state again")


# --- Helpers --------------------------------------------------------------

func _nation_map_is(map: Dictionary, value) -> bool:
	for nation_id in NATION_IDS:
		if not map.has(nation_id) or map[nation_id] != value:
			return false
	return map.size() == NATION_IDS.size()


## Wipes every GameState field with values that cannot be confused with the
## fixture, so a load that silently did nothing is visible.
func _clobber_state() -> void:
	GameState.locale = "zh"
	GameState.day = 1
	GameState.gold = 1
	GameState.morale = 99
	GameState.current_port = null
	GameState.player = {
		"nation_id": "spain", "stats": {}, "xp": 0, "level": 1,
		"officers": [], "reputation": {},
	}
	GameState.fleet = []
	GameState.world = {"position": {"x": 0, "y": 0}, "clock_fraction": 0.0}
	GameState.known_ports = []
	GameState.port_investments = {}
	GameState.quests = []
	GameState.discoveries_found = []
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.fame = -1
	GameState.titles = {}
	GameState.bounties = {}
	GameState.active_quests = []
	GameState.completed_royal_missions = {}
	GameState.discoveries_reported = []
	GameState.discovery_hints = {}
	GameState.battles_won = -1
	GameState.retired = false
	GameState.retired_at = -1


## Everything a load must reproduce (used for "state untouched" comparisons).
func _loaded_values() -> Dictionary:
	return {
		"locale": GameState.locale,
		"day": GameState.day,
		"gold": GameState.gold,
		"morale": GameState.morale,
		"current_port": GameState.current_port,
		"player": GameState.player.duplicate(true),
		"fleet": GameState.fleet.duplicate(true),
		"world": GameState.world.duplicate(true),
		"known_ports": GameState.known_ports.duplicate(),
		"port_investments": GameState.port_investments.duplicate(true),
		"hostile_fleets": GameState.hostile_fleets.duplicate(true),
		"proximity_cooldowns": GameState.proximity_cooldowns.duplicate(true),
		"fame": GameState.fame,
		"titles": GameState.titles.duplicate(true),
		"bounties": GameState.bounties.duplicate(true),
		"active_quests": GameState.active_quests.duplicate(true),
		"completed_royal_missions":
			GameState.completed_royal_missions.duplicate(true),
		"discoveries_reported": GameState.discoveries_reported.duplicate(),
		"discovery_hints": GameState.discovery_hints.duplicate(true),
		"battles_won": GameState.battles_won,
		"retired": GameState.retired,
		"retired_at": GameState.retired_at,
	}


## Loads the fixture once so the "before" state of a rejection test is a real
## migrated run rather than the clobbered sentinel.
func _load_fixture_into_memory() -> void:
	_ensure_dir()
	_write_json(1, _v2_payload())
	_clobber_state()
	if not SaveSystem.load(1):
		_check(false, "setup: the v2 fixture loads before the rejection test")


func _read_json(slot: int) -> Dictionary:
	var text := FileAccess.get_file_as_string(SaveSystem.slot_path(slot))
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	return SaveSystem.normalize_numbers(parsed)


func _write_json(slot: int, data: Dictionary) -> bool:
	_ensure_dir()
	var file := FileAccess.open(SaveSystem.slot_path(slot), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(SaveSystem.SLOT_DIR):
		DirAccess.make_dir_recursive_absolute(SaveSystem.SLOT_DIR)


func _delete_all_slots() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")


## Moves any pre-existing save into [member _backup] so the suite never depends
## on (or destroys) the developer's own saves.
func _backup_saves() -> void:
	_backup.clear()
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_bytes(path)
			DirAccess.remove_absolute(path)
	_delete_all_slots()


func _cleanup() -> void:
	_delete_all_slots()
	if not _backup.is_empty():
		_ensure_dir()
		for slot in _backup:
			var file := FileAccess.open(SaveSystem.slot_path(int(slot)), FileAccess.WRITE)
			if file != null:
				file.store_buffer(_backup[slot])
				file.close()
		_backup.clear()
	DirAccess.remove_absolute(SaveSystem.SLOT_DIR)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
