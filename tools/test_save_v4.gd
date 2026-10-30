extends Node
## Phase-4 task L acceptance tests: the v4 save schema and the identity-only
## load rule (docs/IMPLEMENT-Phase4.md L; docs/90-* §8.1, §8.2 development-stage
## scope; docs/70-* §2, §4.7, §4.9.2, §4.9.8).
##
##   godot --headless --path . tools/test_save_v4.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What this suite is.** Phase 4 deleted the `1 → 2 → 3` migration chain
## (pre-release saves need not load, `90-*` §8.2). This suite therefore tests
## the **current** schema: a v4 payload round-trips byte-equal, the documented
## guards still hold (corrupt payload refused, future `save_version` refused,
## older pre-release versions refused by name, retired runs summarised not
## resumed), and every Phase-2/Phase-3 field block is real saved state.
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved
## into memory and written back at the end; every file this suite creates is
## removed again (start AND end), exactly like `tools/test_save.gd`.

## Every Phase-4 §8.1 key and its documented default (the Phase-3 block is
## unchanged in v4 — only `world.map_id`/`world.position`/`phase` values move).
const V4_DEFAULTS := {
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
	_test_v4_round_trip()
	_test_fixture_shape()
	_test_no_migration_chain()
	_test_older_versions_refused()
	_test_future_version_refused()
	_test_corrupt_phase_fields_rejected()
	_test_optional_keys_default()
	_test_new_fields_round_trip()
	_test_retired_save()
	_cleanup()
	_report()


# --- Fixture: a hand-written v4 payload (docs/90-* §8.1) -------------------

## A complete v4 save: every §8.1 key, `phase: 4`, `world.map_id: "world"` on
## the 2160×1080 grid, and the Phase-2/Phase-3 state blocks the shipped build
## writes. The fleet is capacity-compliant (flagship hold exactly full) so
## `Fleet.normalize_all()` is a no-op on load and "only what changed" can be
## asserted honestly.
func _v4_payload() -> Dictionary:
	return {
		"save_version": 4,
		"saved_at": 1793119712,
		"phase": 4,
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
		"world": {
			"position": {"x": 1025, "y": 307},
			"weather": "fair",
			"map_id": "world",
		},
		"current_port": "lisbon",
		"known_ports": ["lisbon", "seville", "london", "madeira"],
		"port_investments": {"lisbon": 1000},
		"discoveries_found": [],
		"hostile_fleets": [],
		"proximity_cooldowns": {"pirate": 61},
		"fame": 0,
		"titles": {
			"portugal": "none", "spain": "none", "england": "none",
			"holland": "none", "ottoman": "none", "italy": "none",
		},
		"bounties": {},
		"active_quests": [],
		"completed_royal_missions": {
			"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0,
		},
		"discoveries_reported": [],
		"discovery_hints": {},
		"battles_won": 0,
		"retired": false,
		"retired_at": 0,
	}


# --- 1. The done-when: a v4 save loads and re-saves as v4 ------------------

func _test_v4_round_trip() -> void:
	var fixture := _v4_payload()
	_ensure_dir()
	_check(_write_json(1, fixture), "the v4 fixture is written to slot 1")

	# Quit-and-restart: wipe the state, then load the v4 file.
	_clobber_state()
	_check(SaveSystem.load(1), "a v4 save loads")
	_check(SaveSystem.last_read_error.is_empty(),
		"the load reports no error (got '%s')" % SaveSystem.last_read_error)
	_check(GameState.fame == 0, "fame restored (0)")
	_check(_nation_map_is(GameState.titles, "none"),
		"every nation's title restored as 'none' (got %s)" % str(GameState.titles))
	_check(_nation_map_is(GameState.completed_royal_missions, 0),
		"every nation's royal-mission count restored as 0")
	_check(GameState.bounties == {} and GameState.bounties is Dictionary,
		"bounties restored as {}")
	_check(GameState.active_quests == [] and GameState.active_quests is Array,
		"active_quests restored as []")
	_check(GameState.discoveries_reported == [], "discoveries_reported restored as []")
	_check(GameState.discovery_hints == {} and GameState.discovery_hints is Dictionary,
		"discovery_hints restored as {}")
	_check(GameState.battles_won == 0, "battles_won restored as 0")
	_check(GameState.retired == false and GameState.retired_at == 0,
		"retired/retired_at restored as false/0")
	_check(GameState.world.get("map_id") == "world",
		"world.map_id restored as the shipped id (got %s)"
		% str(GameState.world.get("map_id")))
	_check(GameState.quests == [], "the superseded quests list is empty")

	# Nothing else moved: every pre-existing value survives.
	_check(GameState.day == 64 and typeof(GameState.day) == TYPE_INT,
		"day restored exactly (64, got %s)" % str(GameState.day))
	_check(GameState.gold == 12540, "gold restored exactly (12540)")
	_check(GameState.morale == 61, "morale restored exactly (61)")
	_check(GameState.current_port == "lisbon", "current_port restored (lisbon)")
	_check(GameState.world["position"] == {"x": 1025, "y": 307},
		"world.position restored byte-equal")
	_check(GameState.world["weather"] == "fair", "world.weather restored (fair)")
	_check(GameState.known_ports == fixture["known_ports"],
		"known_ports restored byte-equal")
	_check(GameState.port_investments == fixture["port_investments"],
		"port_investments restored byte-equal")
	_check(GameState.proximity_cooldowns == {"pirate": 61},
		"proximity_cooldowns restored byte-equal")
	_check(GameState.player.get("equipment") == {"weapon": "eq_cutlass", "armor": ""},
		"the player equipment block is restored")
	_check((GameState.fleet[0] as Dictionary).get("equipment")
		== {"figurehead": "", "sail": "eq_cotton_sails"},
		"the ship equipment block is restored")

	# --- Re-save: the run is written as version 4 -------------------------
	_check(SaveSystem.save(1), "the run re-saves to slot 1")
	var resaved := _read_json(1)
	_check(not resaved.is_empty(), "the re-saved file parses as JSON")
	_check(int(resaved.get("save_version", -1)) == 4,
		"the re-saved file is save_version 4 (got %s)"
		% str(resaved.get("save_version")))
	_check(int(resaved.get("phase", -1)) == 4,
		"the re-saved file is phase 4 (got %s)" % str(resaved.get("phase")))
	for key in V4_DEFAULTS:
		_check(resaved.has(key),
			"the re-saved file carries '%s' (docs/90-* §8.1)" % key)
	_check(not resaved.has("quests"),
		"the re-saved file has no superseded 'quests' key")
	_check((resaved["world"] as Dictionary).get("map_id") == "world",
		"the re-saved world block carries the shipped map id")
	_check(not (resaved["world"] as Dictionary).has("clock_fraction")
		and not resaved.has("explored_tiles"),
		"the re-save still omits clock_fraction / explored_tiles")

	# …and the v4 file re-loads to the same state (second cycle).
	var first_cycle := _loaded_values()
	_clobber_state()
	_check(SaveSystem.load(1), "the re-saved v4 file loads")
	_check(_loaded_values() == first_cycle, "a second save/load cycle changes nothing")


# --- 2. The fixture really is the v4 §8.1 shape ----------------------------

func _test_fixture_shape() -> void:
	var fixture := _v4_payload()
	_check(int(fixture["save_version"]) == SaveSystem.SAVE_VERSION,
		"the fixture is save_version %d" % SaveSystem.SAVE_VERSION)
	_check(int(fixture["phase"]) == SaveSystem.PHASE,
		"the fixture is phase %d" % SaveSystem.PHASE)
	_check(SaveSystem.validate_payload(fixture).is_empty(),
		"validate_payload() accepts the fixture (%s)"
		% SaveSystem.validate_payload(fixture))
	_check(SaveSystem.SAVE_VERSION == 4 and SaveSystem.PHASE == 4,
		"this build ships save_version 4 / phase 4")
	_check(SaveSystem.DEFAULT_MAP_ID == "world",
		"the shipped map id is 'world' (docs/90-* §9.1)")


# --- 3. No migration chain survives (docs/90-* §8.2 dev scope) -------------

func _test_no_migration_chain() -> void:
	_check(not ("MIGRATIONS" in SaveSystem),
		"SaveSystem carries no MIGRATIONS table any more (dev-stage scope)")
	for name in ["migrate_v1_to_v2", "migrate_v2_to_v3", "migrate_v3_to_v4"]:
		_check(not SaveSystem.has_method(name),
			"the historical migration step %s() is gone" % name)


# --- 4. Older (pre-release) versions are refused by name -------------------

func _test_older_versions_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	for version in [1, 2, 3]:
		var older := _v4_payload()
		older["save_version"] = version
		older["phase"] = version
		_write_json(1, older)
		_check(SaveSystem.load(1) == false,
			"a save_version %d payload fails to load (pre-release)" % version)
		_check(SaveSystem.last_read_error.contains("pre-release")
			and SaveSystem.last_read_error.contains(str(version)),
			"the reason names the pre-release version %d (got '%s')"
			% [version, SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting save_version %d" % version)
		_check(not bool(SaveSystem.list_saves()[0]["valid"]),
			"list_saves() reports the v%d slot invalid" % version)


# --- 5. A future version is refused ---------------------------------------

func _test_future_version_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	var future := _v4_payload()
	future["save_version"] = SaveSystem.SAVE_VERSION + 1
	future["phase"] = SaveSystem.PHASE + 1
	_write_json(1, future)
	_check(SaveSystem.load(1) == false, "a future save_version fails to load")
	_check(SaveSystem.last_read_error.contains("newer than"),
		"the reason names a newer version (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the future-version rejection")


# --- 6. A wrong-typed Phase-2/3 field is rejected --------------------------

func _test_corrupt_phase_fields_rejected() -> void:
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
		{"key": "hostile_fleets", "value": {}, "why": "hostile_fleets as an object"},
		{"key": "proximity_cooldowns", "value": [], "why":
			"proximity_cooldowns as an array"},
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

	# read_save() applies the same rule without touching GameState.
	_check(SaveSystem.read_save(1).is_empty(),
		"read_save() rejects the same wrong-typed payload")


# --- 7. Every Phase-2/3 field is real saved state --------------------------

## docs/90-* §8.1 "Default when absent": the optional blocks may be omitted by
## a hand-edited payload and are then restored from the documented default.
## (This replaces the old `test_save_v2` coverage of the same rule — the
## defaults are now `_apply()`'s job, not a migration's.)
func _test_optional_keys_default() -> void:
	_load_fixture_into_memory()
	var payload := _v4_payload()
	for key in ["hostile_fleets", "proximity_cooldowns", "fame", "titles",
			"bounties", "active_quests", "completed_royal_missions",
			"discoveries_reported", "discovery_hints", "battles_won",
			"retired", "retired_at", "discoveries_found"]:
		payload.erase(key)
	_write_json(1, payload)
	_clobber_state()
	_check(SaveSystem.load(1), "a payload omitting the optional keys loads")
	_check(GameState.hostile_fleets == [] and GameState.hostile_fleets is Array,
		"an absent hostile_fleets defaults to []")
	_check(GameState.proximity_cooldowns == {}
		and GameState.proximity_cooldowns is Dictionary,
		"an absent proximity_cooldowns defaults to {}")
	_check(GameState.fame == 0, "an absent fame defaults to 0")
	_check(GameState.titles == {}, "an absent titles defaults to {}")
	_check(GameState.bounties == {}, "an absent bounties defaults to {}")
	_check(GameState.active_quests == [], "an absent active_quests defaults to []")
	_check(GameState.completed_royal_missions == {},
		"an absent completed_royal_missions defaults to {}")
	_check(GameState.discoveries_reported == [],
		"an absent discoveries_reported defaults to []")
	_check(GameState.discovery_hints == {}, "an absent discovery_hints defaults to {}")
	_check(GameState.battles_won == 0, "an absent battles_won defaults to 0")
	_check(GameState.retired == false and GameState.retired_at == 0,
		"absent retired/retired_at default to false/0")
	_check(GameState.discoveries_found == [],
		"an absent discoveries_found defaults to []")
	_check(GameState.day == 64 and GameState.gold == 12540,
		"the required fields still restore around the defaults")


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
	GameState.hostile_fleets = [{
		"id": "hf_7_30_40_pirate",
		"kind": "pirate",
		"nation_id": "",
		"position": {"x": 30, "y": 40},
		"anchor_port_id": "lisbon",
		"ships": [{
			"ship_type_id": "sloop", "durability": 60, "crew": 10,
			"provisions": 0, "water": 0, "cannons": 4,
			"equipment": {"figurehead": "", "sail": ""},
			"cargo": {"wine": 6},
		}],
		"spawn_day": 7,
		"cooldown_until_day": 0,
	}]
	GameState.proximity_cooldowns = {"pirate": 12}
	var expected := _loaded_values()

	_check(SaveSystem.save(1), "a run with Phase-2/3 state saves")
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
	_check((on_disk.get("hostile_fleets") as Array).size() == 1
		and (on_disk["hostile_fleets"] as Array)[0]["id"] == "hf_7_30_40_pirate",
		"snapshot() writes the hostile marker (docs/90-* §8.1)")
	_check(on_disk.get("proximity_cooldowns") == {"pirate": 12},
		"snapshot() writes proximity_cooldowns")

	_clobber_state()
	_check(SaveSystem.load(1), "the v4 file with Phase-2/3 state loads")
	_check(_loaded_values() == expected,
		"every Phase-2/3 field restores byte-equal after a v4 round trip")
	_check(typeof(((GameState.bounties["spain"] as Dictionary)["amount"])) == TYPE_INT,
		"the bounty amount comes back as an int, not a json float")
	_check(typeof((GameState.hostile_fleets[0] as Dictionary)["position"]["x"])
		== TYPE_INT, "marker coordinates come back as ints, not json floats")

	# The snapshot deep-copies: mutating live state cannot rewrite a save.
	var snap := SaveSystem.snapshot()
	GameState.titles["portugal"] = "duke"
	GameState.active_quests[0]["status"] = "failed"
	GameState.discoveries_reported.append("disc_mutated")
	GameState.hostile_fleets[0]["id"] = "mutated"
	GameState.proximity_cooldowns["pirate"] = 999
	_check((snap["titles"] as Dictionary)["portugal"] == "baron",
		"snapshot() deep-copies titles")
	_check(((snap["active_quests"] as Array)[0] as Dictionary)["status"] == "active",
		"snapshot() deep-copies active_quests")
	_check((snap["discoveries_reported"] as Array).size() == 2,
		"snapshot() deep-copies discoveries_reported")
	_check((snap["hostile_fleets"] as Array)[0]["id"] == "hf_7_30_40_pirate",
		"snapshot() deep-copies hostile_fleets")
	_check(snap["proximity_cooldowns"] == {"pirate": 12},
		"snapshot() deep-copies proximity_cooldowns")


# --- 8. A retired save is never playable ----------------------------------

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
## loaded run rather than the clobbered sentinel.
func _load_fixture_into_memory() -> void:
	_ensure_dir()
	_write_json(1, _v4_payload())
	_clobber_state()
	if not SaveSystem.load(1):
		_check(false, "setup: the v4 fixture loads before the rejection test")


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
