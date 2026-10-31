extends Node
## Phase-5 Task G acceptance tests: the v5 save schema and the identity-only
## load rule (docs/IMPLEMENT-Phase5.md G, decision 5; docs/90-* §8.1, §8.2
## development-stage scope; docs/70-* §2, §4.7, §4.9.2, §4.9.8).
##
##   godot --headless --path . tools/test_save_v5.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What this suite is.** Phase 4 deleted the migration chain and Phase 5
## keeps it removed (decision 5: no migration; a v4 payload is refused like
## any older pre-release save). This suite therefore tests the **current**
## schema: a v5 payload round-trips byte-equal — including the new
## `market_stocks` / `wrecks` / `npc_preset` / `market_events` blocks — the
## documented guards still hold (corrupt payload refused, future
## `save_version` refused, v4 and older refused by name, retired runs
## summarised not resumed), and every Phase-2/3/5 field block is real saved
## state. `npc_fleets` is task J's v5 rename of Phase-2's `hostile_fleets`
## rename).
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved
## into memory and written back at the end; every file this suite creates is
## removed again (start AND end), exactly like `tools/test_save.gd`.

## Every Phase-5 §8.1 key and its documented default (the Phase-2/3 blocks
## are unchanged; `market_stocks`' documented default is the derived
## resting stock, asserted through the loader in the defaults test).
const V5_DEFAULTS := {
	"wrecks": [],
	"npc_preset": "normal",
	"market_events": [],
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
const EconomyLib := preload("res://scripts/port/economy.gd")

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	_test_v5_round_trip()
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

## A complete v5 save: every §8.1 key, `phase: 4`, `world.map_id: "world"` on
## the 2160×1080 grid, and the Phase-2/Phase-3 state blocks the shipped build
## writes. The fleet is capacity-compliant (flagship hold exactly full) so
## `Fleet.normalize_all()` is a no-op on load and "only what changed" can be
## asserted honestly.
func _v5_payload() -> Dictionary:
	return {
		"save_version": 5,
		"saved_at": 1793119712,
		"phase": 5,
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
		"npc_fleets": [],
		"proximity_cooldowns": {"pirate": 61},
		"market_stocks": {"lisbon": {"wine": 87, "salt": 12}},
		"wrecks": [],
		"npc_preset": "normal",
		"market_events": [],
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


# --- 1. The done-when: a v5 save loads and re-saves as v5 ------------------

func _test_v5_round_trip() -> void:
	var fixture := _v5_payload()
	_ensure_dir()
	_check(_write_json(1, fixture), "the v5 fixture is written to slot 1")

	# Quit-and-restart: wipe the state, then load the v5 file.
	_clobber_state()
	_check(SaveSystem.load(1), "a v5 save loads")
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

	# The Phase-5 blocks restore byte-equal too.
	_check(GameState.market_stocks == fixture["market_stocks"],
		"market_stocks restored byte-equal")
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 87,
		"a displaced stock restores its exact value (87)")
	_check(GameState.wrecks == [] and GameState.npc_preset == "normal"
		and GameState.market_events == [],
		"wrecks/npc_preset/market_events restore from the fixture")

	# --- Re-save: the run is written as version 5 -------------------------
	_check(SaveSystem.save(1), "the run re-saves to slot 1")
	var resaved := _read_json(1)
	_check(not resaved.is_empty(), "the re-saved file parses as JSON")
	_check(int(resaved.get("save_version", -1)) == 5,
		"the re-saved file is save_version 5 (got %s)"
		% str(resaved.get("save_version")))
	_check(int(resaved.get("phase", -1)) == 5,
		"the re-saved file is phase 5 (got %s)" % str(resaved.get("phase")))
	for key in V5_DEFAULTS:
		_check(resaved.has(key),
			"the re-saved file carries '%s' (docs/90-* §8.1)" % key)
	_check(resaved.has("market_stocks"),
		"the re-saved file carries 'market_stocks' (docs/90-* §8.1)")
	_check(not resaved.has("quests"),
		"the re-saved file has no superseded 'quests' key")
	_check((resaved["world"] as Dictionary).get("map_id") == "world",
		"the re-saved world block carries the shipped map id")
	_check(not (resaved["world"] as Dictionary).has("clock_fraction")
		and not resaved.has("explored_tiles"),
		"the re-save still omits clock_fraction / explored_tiles")

	# …and the v5 file re-loads to the same state (second cycle).
	var first_cycle := _loaded_values()
	_clobber_state()
	_check(SaveSystem.load(1), "the re-saved v5 file loads")
	_check(_loaded_values() == first_cycle, "a second save/load cycle changes nothing")


# --- 2. The fixture really is the v5 §8.1 shape ----------------------------

func _test_fixture_shape() -> void:
	var fixture := _v5_payload()
	_check(int(fixture["save_version"]) == SaveSystem.SAVE_VERSION,
		"the fixture is save_version %d" % SaveSystem.SAVE_VERSION)
	_check(int(fixture["phase"]) == SaveSystem.PHASE,
		"the fixture is phase %d" % SaveSystem.PHASE)
	_check(SaveSystem.validate_payload(fixture).is_empty(),
		"validate_payload() accepts the fixture (%s)"
		% SaveSystem.validate_payload(fixture))
	_check(SaveSystem.SAVE_VERSION == 5 and SaveSystem.PHASE == 5,
		"this build ships save_version 5 / phase 5")
	_check(SaveSystem.DEFAULT_MAP_ID == "world",
		"the shipped map id is 'world' (docs/90-* §9.1)")


# --- 3. No migration chain survives (docs/90-* §8.2 dev scope) -------------

func _test_no_migration_chain() -> void:
	_check(not ("MIGRATIONS" in SaveSystem),
		"SaveSystem carries no MIGRATIONS table any more (dev-stage scope)")
	for name in ["migrate_v1_to_v2", "migrate_v2_to_v3", "migrate_v3_to_v4",
			"migrate_v4_to_v5"]:
		_check(not SaveSystem.has_method(name),
			"the historical migration step %s() is gone" % name)


# --- 4. Older (pre-release) versions are refused by name -------------------

func _test_older_versions_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	for version in [1, 2, 3, 4]:
		var older := _v5_payload()
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
	var future := _v5_payload()
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
		{"key": "npc_fleets", "value": {}, "why": "npc_fleets as an object"},
		{"key": "proximity_cooldowns", "value": [], "why":
			"proximity_cooldowns as an array"},
		{"key": "market_stocks", "value": [], "why":
			"market_stocks as an array"},
		{"key": "wrecks", "value": {}, "why": "wrecks as an object"},
		{"key": "npc_preset", "value": 3, "why": "npc_preset as a number"},
		{"key": "market_events", "value": {}, "why":
			"market_events as an object"},
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
	var payload := _v5_payload()
	for key in ["npc_fleets", "proximity_cooldowns", "market_stocks",
			"wrecks", "npc_preset", "market_events", "fame", "titles",
			"bounties", "active_quests", "completed_royal_missions",
			"discoveries_reported", "discovery_hints", "battles_won",
			"retired", "retired_at", "discoveries_found"]:
		payload.erase(key)
	_write_json(1, payload)
	_clobber_state()
	_check(SaveSystem.load(1), "a payload omitting the optional keys loads")
	_check(GameState.npc_fleets == [] and GameState.npc_fleets is Array,
		"an absent npc_fleets defaults to []")
	_check(GameState.proximity_cooldowns == {}
		and GameState.proximity_cooldowns is Dictionary,
		"an absent proximity_cooldowns defaults to {}")
	# `market_stocks`' documented default is the DERIVED resting stock
	# (docs/30-* §4.2, no RNG) — computed at load, not a literal.
	_check(GameState.market_stocks.size() == DataLoader.ports_list.size(),
		"an absent market_stocks defaults to the derived resting stock "
		+ "(all %d ports)" % GameState.market_stocks.size())
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 160,
		"the derived default stocks lisbon wine at 160 (got %d)"
		% int(GameState.market_stocks["lisbon"]["wine"]))
	_check(GameState.wrecks == [] and GameState.wrecks is Array,
		"an absent wrecks defaults to []")
	_check(GameState.npc_preset == "normal",
		"an absent npc_preset defaults to 'normal' (got '%s')"
		% GameState.npc_preset)
	_check(GameState.market_events == [] and GameState.market_events is Array,
		"an absent market_events defaults to []")
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
	GameState.market_stocks = {}
	var stocks := EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	stocks["lisbon"]["wine"] = 12
	stocks["seville"]["spices"] = 200
	GameState.market_stocks = stocks
	GameState.wrecks = [{
		"id": "wreck_64_100_200", "position": {"x": 100, "y": 200},
		"day": 64, "cargo": {"silk": 12},
	}]
	GameState.npc_preset = "extreme"
	GameState.market_events = [{
		"template_id": "ev_war_provisioning", "port_id": "seville",
		"start_day": 64, "end_day": 124,
		"shifts": {"timber": -30, "cannons": -30},
	}]
	# The §4.15 fleet shape (docs/10-* §4.15): the pirate's saved fields are
	# exactly the pinned set plus the task-owned extensions.
	GameState.npc_fleets = [{
		"id": "nf_7_0000_pirate",
		"role": "pirate",
		"nation_id": "",
		"cell": {"x": 30, "y": 40},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": "", "name_index": 0},
		"cooldown_until_day": 0,
		"seed": 7 * 1000003 + 30 * 7919 + 40 * 104729,
		"dest_port_id": "",
		"dwell_until_day": 0,
		"anchor_cell": null,
		"target_fleet_id": "",
		"hunter_state": "",
		"loiter_until_day": 0,
		"home_port_id": "",
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
	_check((on_disk.get("npc_fleets") as Array).size() == 1
		and (on_disk["npc_fleets"] as Array)[0]["id"] == "nf_7_0000_pirate",
		"snapshot() writes the fleet (docs/90-* §8.1)")
	_check(on_disk.get("proximity_cooldowns") == {"pirate": 12},
		"snapshot() writes proximity_cooldowns")
	_check((on_disk.get("market_stocks") as Dictionary)["lisbon"]["wine"] == 12,
		"snapshot() writes market_stocks")
	_check((on_disk.get("wrecks") as Array).size() == 1,
		"snapshot() writes wrecks")
	_check(str(on_disk.get("npc_preset")) == "extreme",
		"snapshot() writes npc_preset")
	_check((on_disk.get("market_events") as Array).size() == 1,
		"snapshot() writes market_events")

	_clobber_state()
	_check(SaveSystem.load(1), "the v5 file with Phase-2/3/5 state loads")
	_check(_loaded_values() == expected,
		"every Phase-2/3/5 field restores byte-equal after a v5 round trip")
	_check(typeof(GameState.market_stocks["lisbon"]["wine"]) == TYPE_INT,
		"stock counts come back as ints, not json floats")
	_check(typeof(GameState.wrecks[0]["position"]["x"]) == TYPE_INT,
		"wreck coordinates come back as ints, not json floats")
	_check(typeof(((GameState.bounties["spain"] as Dictionary)["amount"])) == TYPE_INT,
		"the bounty amount comes back as an int, not a json float")
	_check(typeof((GameState.npc_fleets[0] as Dictionary)["cell"]["x"])
		== TYPE_INT, "fleet coordinates come back as ints, not json floats")

	# The snapshot deep-copies: mutating live state cannot rewrite a save.
	var snap := SaveSystem.snapshot()
	GameState.titles["portugal"] = "duke"
	GameState.active_quests[0]["status"] = "failed"
	GameState.discoveries_reported.append("disc_mutated")
	GameState.npc_fleets[0]["id"] = "mutated"
	GameState.proximity_cooldowns["pirate"] = 999
	GameState.market_stocks["lisbon"]["wine"] = 999
	GameState.wrecks[0]["id"] = "mutated"
	GameState.npc_preset = "mutated"
	GameState.market_events[0]["template_id"] = "mutated"
	_check((snap["titles"] as Dictionary)["portugal"] == "baron",
		"snapshot() deep-copies titles")
	_check(((snap["active_quests"] as Array)[0] as Dictionary)["status"] == "active",
		"snapshot() deep-copies active_quests")
	_check((snap["discoveries_reported"] as Array).size() == 2,
		"snapshot() deep-copies discoveries_reported")
	_check((snap["npc_fleets"] as Array)[0]["id"] == "nf_7_0000_pirate",
		"snapshot() deep-copies npc_fleets")
	_check(snap["proximity_cooldowns"] == {"pirate": 12},
		"snapshot() deep-copies proximity_cooldowns")
	_check((snap["market_stocks"] as Dictionary)["lisbon"]["wine"] == 12,
		"snapshot() deep-copies market_stocks")
	_check((snap["wrecks"] as Array)[0]["id"] == "wreck_64_100_200",
		"snapshot() deep-copies wrecks")
	_check(snap["npc_preset"] == "extreme", "snapshot() copies npc_preset")
	_check((snap["market_events"] as Array)[0]["template_id"]
		== "ev_war_provisioning", "snapshot() deep-copies market_events")


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
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.market_stocks = {"clobber": {"clobber": 1}}
	GameState.wrecks = ["clobber"]
	GameState.npc_preset = "clobbered"
	GameState.market_events = ["clobber"]
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
		"npc_fleets": GameState.npc_fleets.duplicate(true),
		"proximity_cooldowns": GameState.proximity_cooldowns.duplicate(true),
		"market_stocks": GameState.market_stocks.duplicate(true),
		"wrecks": GameState.wrecks.duplicate(true),
		"npc_preset": GameState.npc_preset,
		"market_events": GameState.market_events.duplicate(true),
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
	_write_json(1, _v5_payload())
	_clobber_state()
	if not SaveSystem.load(1):
		_check(false, "setup: the v5 fixture loads before the rejection test")


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
