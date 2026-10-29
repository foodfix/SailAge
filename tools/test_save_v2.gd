extends Node
## Phase-2 task A acceptance tests: save migration v1 → v2
## (docs/IMPLEMENT-Phase2.md A; docs/90-* §8.1, §8.2; docs/60-* §2, §4.11.11,
## §4.11.12; docs/50-* §4.8; docs/40-* §4.1).
##
##   godot --headless --path . tools/test_save_v2.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved into
## memory and written back at the end; every file this suite creates is removed
## again (start AND end), exactly like `tools/test_save.gd`.

## The Phase-1 §8.1 payload keys — a v1 file carries exactly these and nothing
## from Phase 2 (`hostile_fleets`, `proximity_cooldowns`, `*.equipment`).
const V1_KEYS := [
	"save_version", "saved_at", "phase", "locale", "day", "gold", "player",
	"fleet", "morale", "world", "current_port", "known_ports",
	"port_investments", "quests", "discoveries_found",
]
const PLAYER_EQUIPMENT := {"weapon": "", "armor": ""}
const SHIP_EQUIPMENT := {"figurehead": "", "sail": ""}

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	_test_v1_load_and_resave()
	_test_v3_rejected()
	_test_wrong_types_rejected()
	_test_migration_table_is_reached_through_load()
	_test_migration_purity()
	_test_v2_new_fields_round_trip()
	_cleanup()
	_report()


# --- Fixture: a hand-written Phase-1 payload (docs/90-* §8.1) ---------------

## A Phase-1 save exactly as a 1.0 build wrote it: every §8.1 key, `phase: 1`,
## a real fleet of ship instances and a player block, **all without** the
## Phase-2 `equipment` blocks and without `hostile_fleets` /
## `proximity_cooldowns`.
##
## The fleet is capacity-compliant (flagship hold exactly full, no over-capacity
## cargo) so T18's `Fleet.normalize_all()` is a no-op on load and "nothing but
## `equipment` changed" can be asserted honestly.
func _v1_payload() -> Dictionary:
	return {
		"save_version": 1,
		"saved_at": 1793119712,
		"phase": 1,
		"locale": "en",
		"day": 37,
		"gold": 7830,
		"player": {
			"nation_id": "portugal",
			"stats": {
				"leadership": 11, "seamanship": 13, "combat": 10,
				"navigation": 20, "luck": 10,
			},
			"xp": 240,
			"level": 3,
			"officers": ["off_mateus_alvares"],
			"reputation": {
				"portugal": 26, "spain": 0, "england": 4, "holland": 0,
				"ottoman": 0, "italy": 0,
			},
			"profit_by_nation": {"england": 1100},
			"profit_rep_awarded": {"england": 1},
		},
		"fleet": [
			{
				"ship_type_id": "caravel",
				"durability": 71,
				"crew": 30,
				"provisions": 40,
				"water": 30,
				"cannons": 3,
				"cargo": {"wine": 25, "salt": 10},
			},
			{
				"ship_type_id": "nao",
				"durability": 133,
				"crew": 40,
				"provisions": 55,
				"water": 45,
				"cannons": 0,
				"cargo": {"silk": 12, "spices": 7},
			},
		],
		"morale": 43,
		"world": {"position": {"x": 21, "y": 44}, "weather": "storm"},
		"current_port": "lisbon",
		"known_ports": ["lisbon", "seville", "london"],
		"port_investments": {"lisbon": 500, "seville": 1200},
		"quests": [],
		"discoveries_found": [],
	}


# --- 1. The done-when: a Phase-1 save loads and re-saves as version 2 ------

func _test_v1_load_and_resave() -> void:
	var fixture := _v1_payload()
	_ensure_dir()
	_check(_write_json(1, fixture), "the v1 fixture is written to slot 1")

	# The fixture really is v1-shaped (otherwise the test would prove nothing).
	var on_disk := _read_json(1)
	_check(not on_disk.is_empty(), "the written fixture parses as JSON")
	_check(int(on_disk.get("save_version", -1)) == 1,
		"the fixture is save_version 1 (got %s)" % str(on_disk.get("save_version")))
	_check(int(on_disk.get("phase", -1)) == 1, "the fixture is phase 1")
	var missing := []
	for key in V1_KEYS:
		if not on_disk.has(key):
			missing.append(key)
	_check(missing.is_empty(), "the fixture has every Phase-1 §8.1 key (missing %s)"
		% str(missing))
	_check(not on_disk.has("hostile_fleets")
		and not on_disk.has("proximity_cooldowns"),
		"the fixture has no Phase-2 keys")
	_check(not (on_disk["player"] as Dictionary).has("equipment"),
		"the fixture player has no equipment block")
	var bare_ships := true
	for ship in (on_disk["fleet"] as Array):
		bare_ships = bare_ships and not (ship as Dictionary).has("equipment")
	_check(bare_ships, "the fixture's fleet ships have no equipment block")

	# Quit-and-restart: wipe the state, then load the Phase-1 file.
	_clobber_state()
	_check(SaveSystem.load(1), "a Phase-1 save loads in Phase-2 code")
	_check(SaveSystem.last_read_error.is_empty(),
		"the load reports no error (got '%s')" % SaveSystem.last_read_error)
	_check(GameState.hostile_fleets == [] and GameState.hostile_fleets is Array,
		"migration set hostile_fleets to []")
	_check(GameState.proximity_cooldowns == {}
		and GameState.proximity_cooldowns is Dictionary,
		"migration set proximity_cooldowns to {}")
	_check(GameState.player.get("equipment") == PLAYER_EQUIPMENT,
		"migration set player.equipment to %s (got %s)"
		% [str(PLAYER_EQUIPMENT), str(GameState.player.get("equipment"))])

	var ships_ok := GameState.fleet.size() == 2
	for ship in GameState.fleet:
		ships_ok = ships_ok and (ship as Dictionary).get("equipment") == SHIP_EQUIPMENT
	_check(ships_ok, "every migrated fleet ship has equipment %s (got %s)"
		% [str(SHIP_EQUIPMENT), str(GameState.fleet.map(
			func(ship: Dictionary) -> Variant: return ship.get("equipment")))])

	# Nothing else moved: every pre-existing value is byte-equal to the fixture.
	_check(GameState.day == 37 and typeof(GameState.day) == TYPE_INT,
		"day restored exactly (37, got %s)" % str(GameState.day))
	_check(GameState.gold == 7830, "gold restored exactly (7830)")
	_check(GameState.morale == 43, "morale restored exactly (43)")
	_check(GameState.locale == "en", "locale restored (en)")
	_check(GameState.current_port == "lisbon", "current_port restored (lisbon)")
	_check(GameState.world["position"] == {"x": 21, "y": 44},
		"world.position restored byte-equal (%s)" % str(GameState.world["position"]))
	_check(GameState.world["weather"] == "storm", "world.weather restored (storm)")
	_check(GameState.known_ports == fixture["known_ports"],
		"known_ports restored byte-equal (%s)" % str(GameState.known_ports))
	_check(GameState.port_investments == fixture["port_investments"],
		"port_investments restored byte-equal (%s)" % str(GameState.port_investments))

	# Fleet: only `equipment` was added, every original key/value survives.
	var fleet_untouched: bool = GameState.fleet.size() == (fixture["fleet"] as Array).size()
	var ship_index := 0
	while fleet_untouched and ship_index < GameState.fleet.size():
		var expected_ship: Dictionary = fixture["fleet"][ship_index]
		var actual_ship: Dictionary = GameState.fleet[ship_index]
		var keys: Array = actual_ship.keys()
		keys.erase("equipment")
		keys.sort()
		fleet_untouched = keys == _sorted_keys(expected_ship)
		for key in expected_ship:
			fleet_untouched = fleet_untouched and actual_ship[key] == expected_ship[key]
		ship_index += 1
	_check(fleet_untouched,
		"each ship keeps every Phase-1 field untouched (only 'equipment' added)")

	# Player: same rule.
	var player_untouched := true
	for key in fixture["player"]:
		player_untouched = player_untouched \
			and GameState.player.get(key) == (fixture["player"] as Dictionary)[key]
	var player_keys: Array = GameState.player.keys()
	player_keys.erase("equipment")
	player_keys.sort()
	_check(player_untouched and player_keys == _sorted_keys(fixture["player"]),
		"the player block keeps every Phase-1 field untouched (only 'equipment' added)")

	# --- Re-save: the migrated run is written as version 2 ------------------
	_check(SaveSystem.save(1), "the migrated run re-saves to slot 1")
	var resaved := _read_json(1)
	_check(not resaved.is_empty(), "the re-saved file parses as JSON")
	_check(int(resaved.get("save_version", -1)) == 2,
		"the re-saved file is save_version 2 (got %s)"
		% str(resaved.get("save_version")))
	_check(int(resaved.get("phase", -1)) == 2,
		"the re-saved file is phase 2 (got %s)" % str(resaved.get("phase")))
	_check(resaved.has("hostile_fleets") and resaved["hostile_fleets"] == [],
		"the re-saved file carries hostile_fleets: []")
	_check(resaved.has("proximity_cooldowns")
		and resaved["proximity_cooldowns"] == {},
		"the re-saved file carries proximity_cooldowns: {}")
	_check((resaved["player"] as Dictionary).get("equipment") == PLAYER_EQUIPMENT,
		"the re-saved player block carries the equipment defaults")
	var resaved_ships_ok: bool = (resaved["fleet"] as Array).size() == 2
	for ship in (resaved["fleet"] as Array):
		resaved_ships_ok = resaved_ships_ok \
			and (ship as Dictionary).get("equipment") == SHIP_EQUIPMENT
	_check(resaved_ships_ok, "the re-saved fleet ships carry the equipment defaults")
	_check(int(resaved.get("saved_at")) > 0, "the re-save refreshed saved_at")
	_check(not (resaved["world"] as Dictionary).has("clock_fraction")
		and not resaved.has("explored_tiles"),
		"the re-save still omits clock_fraction / explored_tiles")

	# …and the version-2 file re-loads to the same state (second cycle).
	var first_cycle := _loaded_values()
	_clobber_state()
	_check(SaveSystem.load(1), "the re-saved version-2 file loads")
	_check(_loaded_values() == first_cycle,
		"a second save/load cycle changes nothing")


# --- 2. A version 3 payload is rejected ------------------------------------

func _test_v3_rejected() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()

	var payload := _v1_payload()
	payload["save_version"] = 3
	payload["phase"] = 3
	_write_json(1, payload)
	_check(SaveSystem.load(1) == false, "a save_version 3 payload fails to load")
	_check(SaveSystem.last_read_error.contains("newer than"),
		"the reason names a newer version (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the v3 rejection (every field)")
	_check(not bool(SaveSystem.list_saves()[0]["valid"]),
		"the v3 slot is reported invalid by list_saves()")


# --- 3. A v2 payload with a wrong-typed new field is rejected ---------------

func _test_wrong_types_rejected() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()

	var bad_fleets: Dictionary = SaveSystem.snapshot()
	bad_fleets["hostile_fleets"] = {}
	_write_json(1, bad_fleets)
	_check(SaveSystem.load(1) == false,
		"hostile_fleets as an object (not []object) is rejected")
	_check(SaveSystem.last_read_error.contains("hostile_fleets"),
		"the reason names hostile_fleets (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before, "state untouched after the type rejection")

	var bad_cooldowns: Dictionary = SaveSystem.snapshot()
	bad_cooldowns["proximity_cooldowns"] = []
	_write_json(1, bad_cooldowns)
	_check(SaveSystem.load(1) == false,
		"proximity_cooldowns as an array (not an object) is rejected")
	_check(SaveSystem.last_read_error.contains("proximity_cooldowns"),
		"the reason names proximity_cooldowns (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before, "state untouched after the second rejection")

	# read_save() applies the same rule without touching GameState.
	_check(SaveSystem.read_save(1).is_empty(),
		"read_save() rejects the same wrong-typed payload")


# --- 4. `load` really routes through the migration table -------------------

func _test_migration_table_is_reached_through_load() -> void:
	_check(SaveSystem.MIGRATIONS.has(1) and SaveSystem.MIGRATIONS[1] is Callable,
		"MIGRATIONS has the 1 → 2 step as a Callable")
	_check(SaveSystem.MIGRATIONS.size() == 1,
		"MIGRATIONS has exactly one step (got %d)" % SaveSystem.MIGRATIONS.size())

	# A test-only step for the *same* version is merged over the shipped table:
	# if `load` consults the table, the counter fires exactly once.
	_ensure_dir()
	_write_json(1, _v1_payload())
	_clobber_state()
	var calls := [0]
	var probe := {
		1: func(data: Dictionary) -> Dictionary:
			calls[0] += 1
			return SaveSystem.migrate_v1_to_v2(data),
	}
	_check(SaveSystem.load(1, probe), "a v1 file loads through the supplied table")
	_check(calls[0] == 1, "load() ran the migration step exactly once (got %d)"
		% calls[0])

	# A table whose step produces an unusable payload must fail cleanly —
	# proving the migrated dict is validated again before anything is applied.
	_write_json(1, _v1_payload())
	_clobber_state()
	var before := _loaded_values()
	var broken := {
		1: func(data: Dictionary) -> Dictionary:
			data["save_version"] = 2
			data["fleet"] = {}
			return data,
	}
	_check(SaveSystem.load(1, broken) == false,
		"a migration that yields a broken shape fails the load")
	_check(SaveSystem.last_read_error.contains("after migration"),
		"the failure is reported as a post-migration shape error (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched when a migration result is unusable")

	# A version with no step at all still fails cleanly (no v3→v4 step exists).
	_check(not SaveSystem.MIGRATIONS.has(2) and not SaveSystem.MIGRATIONS.has(0),
		"there is no migration step for any other version")
	var future: Dictionary = _v1_payload()
	future["save_version"] = 0
	_write_json(1, future)
	before = _loaded_values()
	_check(SaveSystem.load(1) == false,
		"a v0 file (no MIGRATIONS[0]) fails to load")
	_check(SaveSystem.last_read_error.contains("no migration from save_version 0"),
		"the reason names the missing step (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before, "state untouched when the step is missing")


# --- 5. The migration function is pure -------------------------------------

func _test_migration_purity() -> void:
	var input := _v1_payload()
	var before := input.duplicate(true)
	var out: Dictionary = SaveSystem.MIGRATIONS[1].call(input)
	_check(input == before, "MIGRATIONS[1] does not mutate its argument")
	_check(out != input or out.hash() != input.hash(),
		"MIGRATIONS[1] returns a different dict")
	_check(out["player"] != input["player"],
		"the returned player block is a copy, not the input's object")
	_check(out["fleet"] != input["fleet"],
		"the returned fleet is a copy, not the input's array")
	_check(out["hostile_fleets"] == [] and out["proximity_cooldowns"] == {},
		"MIGRATIONS[1] adds the two Phase-2 keys")
	_check(int(out["phase"]) == 2, "MIGRATIONS[1] sets phase = 2")
	_check(not input.has("phase") or int(input["phase"]) == 1,
		"the input still says phase 1 (the doc's version-1 payload)")
	_check(int(out.get("save_version", 1)) == 1,
		"MIGRATIONS[1] leaves save_version to _migrate() (still 1 here)")

	# An empty player object must not be synthesised into a non-empty one.
	var no_player := _v1_payload()
	no_player["player"] = {}
	var migrated_empty: Dictionary = SaveSystem.MIGRATIONS[1].call(no_player)
	_check(migrated_empty["player"] == {},
		"an empty player stays empty (equipment is not added)")

	# Non-dict fleet entries are left for the capacity guard to report.
	var odd_fleet := _v1_payload()
	odd_fleet["fleet"] = ["not a ship", {"ship_type_id": "caravel"}]
	var migrated_odd: Dictionary = SaveSystem.MIGRATIONS[1].call(odd_fleet)
	_check((migrated_odd["fleet"] as Array)[0] == "not a ship",
		"MIGRATIONS[1] leaves a non-dict fleet entry alone")
	_check((migrated_odd["fleet"] as Array)[1].get("equipment") == SHIP_EQUIPMENT,
		"MIGRATIONS[1] still equips the dict entry next to it")
	_check(not odd_fleet["fleet"][1].has("equipment"),
		"the odd fleet input is not mutated either")


# --- 6. The new fields are real saved state --------------------------------

## docs/60-* §4.11.11: `hostile_fleets` is a saved array of markers and
## `proximity_cooldowns` a `{kind: day}` map; both must survive a v2 round trip
## (snapshot writes them, `_apply` restores them).
func _test_v2_new_fields_round_trip() -> void:
	_load_fixture_into_memory()
	GameState.hostile_fleets = [{
		"id": "hf_7_30_40_pirate",
		"kind": "pirate",
		"nation_id": "",
		"position": {"x": 30, "y": 40},
		"anchor_port_id": "lisbon",
		"ships": [{
			"ship_type_id": "sloop", "durability": 60, "crew": 10,
			"provisions": 0, "water": 0, "cannons": 4,
			"equipment": SHIP_EQUIPMENT.duplicate(true),
			"cargo": {"wine": 6},
		}],
		"spawn_day": 7,
		"cooldown_until_day": 0,
	}]
	GameState.proximity_cooldowns = {"pirate": 12}
	var expected_markers := GameState.hostile_fleets.duplicate(true)
	var expected_cooldowns := GameState.proximity_cooldowns.duplicate(true)

	_check(SaveSystem.save(1), "a run with hostile markers saves")
	var on_disk := _read_json(1)
	_check((on_disk.get("hostile_fleets") as Array).size() == 1
		and (on_disk["hostile_fleets"] as Array)[0]["id"] == "hf_7_30_40_pirate",
		"snapshot() writes the hostile marker (docs/90-* §8.1)")
	_check(on_disk.get("proximity_cooldowns") == {"pirate": 12},
		"snapshot() writes proximity_cooldowns")

	_clobber_state()
	_check(SaveSystem.load(1), "the v2 file with markers loads")
	_check(GameState.hostile_fleets == expected_markers,
		"hostile_fleets restored byte-equal after a v2 round trip")
	_check(GameState.proximity_cooldowns == expected_cooldowns,
		"proximity_cooldowns restored byte-equal after a v2 round trip")
	_check(typeof((GameState.hostile_fleets[0] as Dictionary)["position"]["x"])
		== TYPE_INT, "marker coordinates come back as ints, not json floats")

	# The snapshot deep-copies: mutating the live array cannot rewrite a save
	# already in memory.
	var snap := SaveSystem.snapshot()
	GameState.hostile_fleets[0]["id"] = "mutated"
	GameState.proximity_cooldowns["pirate"] = 999
	_check((snap["hostile_fleets"] as Array)[0]["id"] == "hf_7_30_40_pirate",
		"snapshot() deep-copies hostile_fleets")
	_check(snap["proximity_cooldowns"] == {"pirate": 12},
		"snapshot() deep-copies proximity_cooldowns")


# --- Helpers --------------------------------------------------------------

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
	}


## Loads the fixture once so the "before" state of a rejection test is a real
## migrated run rather than the clobbered sentinel.
func _load_fixture_into_memory() -> void:
	_ensure_dir()
	_write_json(1, _v1_payload())
	_clobber_state()
	if not SaveSystem.load(1):
		_check(false, "setup: the v1 fixture loads before the rejection test")


func _sorted_keys(dict: Dictionary) -> Array:
	var keys: Array = dict.keys()
	keys.sort()
	return keys


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
