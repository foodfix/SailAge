extends Node
## T17 acceptance tests (docs/IMPLEMENT-Phase1.md T17; docs/90-* §5.5, §8.1,
## §8.2, §11; docs/80-* §4.3, §4.6; docs/50-* §4.8; docs/40-* §4.1, §6).
##
##   godot --headless res://tools/test_save.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Test isolation: the suite never depends on saves that happen to exist. Any
## `user://saves/save_*.json` found at startup is moved into memory and written
## back at the end, and every file this suite creates is removed again.
## (`user://saves/` itself is left in place, empty, exactly as a fresh install
## would have it.)

const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")
const SlotDialogScene := preload("res://scenes/ui_shared/save_slot_dialog.tscn")
const SlotDialogLib := preload("res://scenes/ui_shared/save_slot_dialog.gd")
const TitleScene := preload("res://scenes/title/title_screen.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]
## §8.1 keys the payload must carry, in the doc's order (minus nothing).
## Phase 2 (save_version 2) appended the fleet block (renamed `npc_fleets`
## at v5) / `proximity_cooldowns`;
## Phase 3 appended the fame/title/quest/discovery/retirement block and
## **dropped** the superseded `quests` key; Phase 4 added no key — only the
## `save_version`/`phase` values and `world.map_id`/`world.position` moved;
## Phase 5 (save_version 5) appended the economy/density blocks
## `market_stocks` / `wrecks` / `npc_preset` / `market_events`
## (docs/90-* §8.1, §8.2).
const PAYLOAD_KEYS := [
	"save_version", "saved_at", "phase", "locale", "day", "gold", "player",
	"fleet", "morale", "world", "current_port", "known_ports",
	"port_investments", "discoveries_found", "npc_fleets",
	"proximity_cooldowns", "market_stocks", "wrecks", "npc_preset",
	"market_events", "fame", "titles", "bounties", "active_quests",
	"completed_royal_missions", "discoveries_reported", "discovery_hints",
	"battles_won", "retired", "retired_at",
]
## Keys a current-version payload must **not** carry any more.
const FORBIDDEN_KEYS := ["quests"]

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}
## HUD used for toast assertions (attached/removed per test).
var _hud: Control = null


func _ready() -> void:
	_backup_saves()
	_test_full_round_trip()
	_test_three_independent_slots()
	_test_corrupt_files()
	_test_version_mismatch()
	_test_version_window()
	_test_market_stocks_derived_default()
	await _test_f5_at_sea()
	_test_f5_in_port_and_keys()
	_test_routing_on_load()
	_test_no_autosave()
	_test_fleet_guard_hook()
	_test_slot_dialog()
	_test_title_and_port_wiring()
	_cleanup()
	_report()


# --- Fixtures --------------------------------------------------------------

## Deterministic, rich, *valid* run docked at Lisbon (docs/90-* §8.1 fields).
##
## Every ship stays inside its own hold/cannon limits so T18's
## `Fleet.normalize_all()` is a no-op on this fixture and the round-trip
## comparison is exact.
func _make_rich_run() -> void:
	GameState.locale = "zh"
	GameState.day = 37
	GameState.gold = 7830
	GameState.morale = 43
	GameState.current_port = "lisbon"

	var reputation: Dictionary = {}
	for nation_id in NATIONS:
		reputation[nation_id] = 0
	reputation["portugal"] = 26
	reputation["england"] = 4

	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 11, "seamanship": 13, "combat": 10,
			"navigation": 20, "luck": 10,
		},
		"xp": 240,
		"level": 3,
		"officers": ["off_mateus_alvares", "off_diego_fernandez"],
		"reputation": reputation,
		"profit_by_nation": {"england": 1100, "holland": 250},
		"profit_rep_awarded": {"england": 1, "holland": 0},
	}

	# The flagship's hold must be FULL before an escort carries anything
	# (docs/40-* §4.2 distribution invariant), otherwise T18's
	# Fleet.normalize_all() legitimately moves the escort's cargo forward on
	# load and a byte-equal assertion would be testing non-compliant data.
	# 45 provisions + 30 water + 35 goods + 3 cannons × 5 = 125 > 120, so use
	# 40 + 30 + 35 + 15 = 120 exactly (free 0).
	var caravel: Dictionary = FleetLib.new_ship("caravel", 30)
	caravel["durability"] = 71
	caravel["provisions"] = 40
	caravel["water"] = 30
	caravel["cannons"] = 3
	caravel["cargo"] = {"wine": 25, "salt": 10}
	var nao: Dictionary = FleetLib.new_ship("nao", 40)
	nao["durability"] = 133
	nao["provisions"] = 55
	nao["water"] = 45
	nao["cargo"] = {"silk": 12, "spices": 7}
	GameState.fleet = [caravel, nao]

	GameState.world = {
		"position": {"x": 21, "y": 44},
		"clock_fraction": 0.42,
		"weather": "storm",
	}
	GameState.known_ports = ["lisbon", "seville", "london"]
	GameState.port_investments = {"lisbon": 500, "seville": 1200}
	GameState.quests = []
	GameState.discoveries_found = []
	GameState.explored_tiles = {"1,2": true}
	# Phase-5 blocks (docs/90-* §8.1): a displaced stock, a wreck, a
	# non-default preset and one active event instance.
	var stocks := EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	stocks["lisbon"]["wine"] = 87
	GameState.market_stocks = stocks
	GameState.wrecks = [{
		"id": "wreck_5_30_40", "position": {"x": 30, "y": 40},
		"day": 5, "cargo": {"wine": 6},
	}]
	GameState.npc_preset = "high"
	GameState.market_events = [{
		"template_id": "ev_harvest_festival", "port_id": "lisbon",
		"start_day": 30, "end_day": 40, "shifts": {"wine": 30},
	}]


## A completely different state, as if the game had been quit and restarted.
func _clobber_state() -> void:
	GameState.locale = "en"
	GameState.day = 1
	GameState.gold = 0
	GameState.morale = 70
	GameState.current_port = null
	GameState.market_stocks = {"clobber": {"clobber": 1}}
	GameState.wrecks = ["clobber"]
	GameState.npc_preset = "clobbered"
	GameState.market_events = ["clobber"]
	GameState.player = {
		"nation_id": "spain", "stats": {"leadership": 10}, "xp": 0,
		"level": 1, "officers": [], "reputation": {},
	}
	GameState.fleet = []
	GameState.world = {"position": {"x": 0, "y": 0}, "clock_fraction": 0.0}
	GameState.known_ports = []
	GameState.port_investments = {}
	GameState.quests = []
	GameState.discoveries_found = []


## The values a save must reproduce exactly, read straight from GameState.
func _expected() -> Dictionary:
	return {
		"locale": GameState.locale,
		"day": GameState.day,
		"gold": GameState.gold,
		"morale": GameState.morale,
		"current_port": GameState.current_port,
		"player": GameState.player.duplicate(true),
		"fleet": GameState.fleet.duplicate(true),
		"position": GameState.world["position"].duplicate(),
		"weather": GameState.world["weather"],
		"known_ports": GameState.known_ports.duplicate(),
		"port_investments": GameState.port_investments.duplicate(true),
		"market_stocks": GameState.market_stocks.duplicate(true),
		"wrecks": GameState.wrecks.duplicate(true),
		"npc_preset": GameState.npc_preset,
		"market_events": GameState.market_events.duplicate(true),
	}


# --- 1. Full round trip ----------------------------------------------------

func _test_full_round_trip() -> void:
	_make_rich_run()
	var expected := _expected()
	_check(SaveSystem.save(1), "save(1) succeeds")
	_check(FileAccess.file_exists(SaveSystem.slot_path(1)),
		"save_1.json exists at %s" % SaveSystem.slot_path(1))

	# The written file is exactly the §8.1 shape (and nothing else).
	var parser := JSON.new()
	_check(parser.parse(FileAccess.get_file_as_string(SaveSystem.slot_path(1))) == OK,
		"the save file is valid JSON")
	var raw: Dictionary = parser.data
	var missing: Array = []
	for key in PAYLOAD_KEYS:
		if not raw.has(key):
			missing.append(key)
	_check(missing.is_empty(), "payload has every §8.1 key (missing: %s)" % str(missing))
	var unexpected: Array = []
	for key in FORBIDDEN_KEYS:
		if raw.has(key):
			unexpected.append(key)
	_check(unexpected.is_empty(),
		"payload drops the superseded keys (%s)" % str(unexpected))
	_check(int(raw.get("save_version", 0)) == SaveSystem.SAVE_VERSION,
		"save_version is %d" % SaveSystem.SAVE_VERSION)
	_check(int(raw.get("phase", 0)) == SaveSystem.PHASE,
		"phase is %d" % SaveSystem.PHASE)
	_check(typeof(raw.get("saved_at")) in [TYPE_FLOAT, TYPE_INT],
		"saved_at is numeric")
	_check(not (raw.get("world", {}) as Dictionary).has("clock_fraction"),
		"world.clock_fraction is not persisted (docs/20-* §4.3)")
	_check(not raw.has("explored_tiles"),
		"explored_tiles is not persisted (docs/20-* §4.12)")
	_check((raw.get("player", {}) as Dictionary).has("profit_by_nation")
		and (raw.get("player", {}) as Dictionary).has("profit_rep_awarded"),
		"both reputation accumulators are in the payload (docs/50-* §4.8)")

	# Simulate a quit: wipe every field, then load.
	_clobber_state()
	_check(SaveSystem.load(1), "load(1) succeeds")
	_check(GameState.day == expected["day"] and typeof(GameState.day) == TYPE_INT,
		"day restored exactly and still an int (%s / %s)"
		% [str(GameState.day), type_string(typeof(GameState.day))])
	_check(GameState.gold == expected["gold"] and typeof(GameState.gold) == TYPE_INT,
		"gold restored exactly and still an int (%s)" % str(GameState.gold))
	_check(GameState.locale == expected["locale"], "locale restored (%s)" % GameState.locale)
	_check(GameState.morale == expected["morale"] and typeof(GameState.morale) == TYPE_INT,
		"morale restored exactly and still an int (%d)" % GameState.morale)
	_check(GameState.current_port == expected["current_port"],
		"current_port restored (%s)" % str(GameState.current_port))
	_check(GameState.world["position"] == expected["position"],
		"world.position restored byte-equal (%s)" % str(GameState.world["position"]))
	_check(typeof(GameState.world["position"]["x"]) == TYPE_INT
		and typeof(GameState.world["position"]["y"]) == TYPE_INT,
		"world.position axes are ints, not json floats")
	_check(GameState.world["weather"] == expected["weather"],
		"world.weather restored (%s)" % str(GameState.world["weather"]))
	_check(GameState.world["clock_fraction"] == 0.0,
		"clock_fraction resets to 0 on load (was 0.42 at save time)")
	_check(GameState.fleet.size() == 2 and GameState.fleet == expected["fleet"],
		"fleet restored byte-equal (ships/cargo/supplies/cannons)")
	_check(typeof((GameState.fleet[0]["cargo"] as Dictionary)["wine"]) == TYPE_INT,
		"fleet cargo counts are ints after a json round trip")
	_check(typeof((GameState.fleet[0] as Dictionary)["cannons"]) == TYPE_INT,
		"fleet cannon counts are ints after a json round trip")
	_check(GameState.player == expected["player"], "player block restored byte-equal")
	_check(GameState.player["officers"] == ["off_mateus_alvares", "off_diego_fernandez"],
		"officer ids restored in order")
	_check(typeof(GameState.player["xp"]) == TYPE_INT
		and int(GameState.player["xp"]) == 240, "player.xp restored as an int (240)")
	_check(typeof(GameState.player["level"]) == TYPE_INT,
		"player.level is an int (derived %d)" % int(GameState.player["level"]))
	_check(CharacterLib.reputation("england") == 4, "reputation map restored (england 4)")
	_check(CharacterLib.profit_by_nation("england") == 1100,
		"profit accumulator restored (england 1100)")
	_check(int(GameState.player["profit_rep_awarded"]["england"]) == 1,
		"awarded-points marker restored (england 1)")
	_check(GameState.known_ports == expected["known_ports"],
		"known_ports restored byte-equal (%s)" % str(GameState.known_ports))
	_check(GameState.port_investments == expected["port_investments"],
		"port_investments restored byte-equal (%s)" % str(GameState.port_investments))
	_check(typeof(GameState.port_investments["lisbon"]) == TYPE_INT,
		"investment totals are ints after a json round trip")
	_check(GameState.market_stocks == expected["market_stocks"],
		"market_stocks restored byte-equal (100 ports × 20 goods, lisbon wine 87)")
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 87
		and typeof(GameState.market_stocks["lisbon"]["wine"]) == TYPE_INT,
		"stock counts come back as ints, not json floats")
	_check(GameState.wrecks == expected["wrecks"]
		and int(GameState.wrecks[0]["position"]["x"]) == 30,
		"wrecks restored byte-equal with int coordinates")
	_check(GameState.npc_preset == "high",
		"npc_preset restored ('%s')" % GameState.npc_preset)
	_check(GameState.market_events == expected["market_events"]
		and int(GameState.market_events[0]["start_day"]) == 30,
		"market_events restored byte-equal with int days")
	_check(GameState.explored_tiles.is_empty(),
		"explored_tiles stays empty after a load (not saved)")

	# A second save/load cycle must be idempotent (no accumulation/drift).
	var before := _expected()
	_check(SaveSystem.save(1) and SaveSystem.load(1), "save/load cycle 2 succeeds")
	_check(_expected() == before, "a second round trip changes nothing")


# --- 2. Three independent slots --------------------------------------------

func _test_three_independent_slots() -> void:
	_make_rich_run()
	GameState.day = 11
	GameState.gold = 111
	GameState.current_port = "lisbon"
	_check(SaveSystem.save(1), "slot 1 written (day 11)")
	GameState.day = 22
	GameState.gold = 222
	GameState.current_port = "seville"
	GameState.player["nation_id"] = "spain"
	_check(SaveSystem.save(2), "slot 2 written (day 22)")
	GameState.day = 33
	GameState.gold = 333
	GameState.current_port = "london"
	GameState.player["nation_id"] = "england"
	_check(SaveSystem.save(3), "slot 3 written (day 33)")

	var list: Array[Dictionary] = SaveSystem.list_saves()
	_check(list.size() == 3, "list_saves() returns 3 entries")
	_check(list[0]["slot"] == 1 and list[1]["slot"] == 2 and list[2]["slot"] == 3,
		"list_saves() is in slot order")
	_check(list[0]["day"] == 11 and list[1]["day"] == 22 and list[2]["day"] == 33,
		"each entry reports its own day (%s)"
		% str([list[0]["day"], list[1]["day"], list[2]["day"]]))
	_check(list[0]["gold"] == 111 and list[1]["gold"] == 222 and list[2]["gold"] == 333,
		"each entry reports its own gold")
	_check(list[0]["port"] == "lisbon" and list[1]["port"] == "seville"
		and list[2]["port"] == "london", "each entry reports its own port")
	_check(list[0]["nation"] == "portugal" and list[1]["nation"] == "spain"
		and list[2]["nation"] == "england", "each entry reports its own nation")
	var stamps_ok := true
	for entry in list:
		stamps_ok = stamps_ok and bool(entry["valid"]) \
			and int(entry["timestamp"]) > 0
	_check(stamps_ok, "every entry is valid and carries a timestamp")
	_check(list[0]["timestamp"] >= 1793250076,
		"timestamp is a real unix time (%d)" % int(list[0]["timestamp"]))

	# Loads are independent.
	_check(SaveSystem.load(2), "load(2) succeeds")
	_check(GameState.day == 22 and GameState.gold == 222
		and GameState.current_port == "seville",
		"slot 2 restores its own state (day 22, 222g, seville)")
	_check(SaveSystem.load(1) and GameState.day == 11, "slot 1 still day 11")
	_check(SaveSystem.load(3) and GameState.day == 33, "slot 3 still day 33")

	# A load also clears transient, non-persisted ledger state: without that, a
	# run that ended in a game over could never sail again after loading a
	# *later-day* save (the sim's own new-run detector only fires on a
	# backwards day jump).
	SailingSimLib.game_over_reason = "starvation"
	SailingSimLib.starvation_days = 4
	_check(SaveSystem.load(1), "load clears the transient fail-state")
	_check(SailingSimLib.game_over_reason.is_empty(),
		"game_over_reason is cleared by a load (got '%s')"
		% SailingSimLib.game_over_reason)
	_check(SailingSimLib.starvation_days == 0, "starvation_days is cleared by a load")
	_check(not SailingSimLib.is_game_over(), "the loaded run is alive again")

	# Deleting one leaves the others.
	_check(SaveSystem.delete_save(2), "delete_save(2) succeeds")
	_check(not SaveSystem.has_save(2), "slot 2 file is gone")
	_check(SaveSystem.has_save(1) and SaveSystem.has_save(3),
		"slots 1 and 3 survive the delete")
	var after := SaveSystem.list_saves()
	_check(bool(after[1]["empty"]) and not bool(after[1]["valid"]),
		"the deleted slot reports empty + invalid")
	_check(after[0]["day"] == 11 and after[2]["day"] == 33,
		"the surviving summaries are unchanged")
	_check(not SaveSystem.delete_save(2), "deleting an already empty slot returns false")
	_check(not SaveSystem.save(0) and not SaveSystem.save(4),
		"slots outside 1..3 are refused")
	_check(SaveSystem.load(0) == false and SaveSystem.load(4) == false,
		"loading slots outside 1..3 returns false")


# --- 3. Corrupt files ------------------------------------------------------

func _test_corrupt_files() -> void:
	_make_rich_run()
	_check(SaveSystem.save(1), "a good baseline save exists in slot 1")
	_check(SaveSystem.load(1), "baseline loads")
	var untouched := _expected()

	# Garbage (unparseable JSON) and a truncated file, one per slot.
	_write_raw(2, "this is definitely not json {{{")
	_write_raw(3, "{\"save_version\": 1, \"day\": 4, \"gold\": 9")

	var before_load := _expected()
	_check(SaveSystem.load(2) == false, "load(garbage slot 2) returns false")
	_check(SaveSystem.load(3) == false, "load(truncated slot 3) returns false")
	_check(_expected() == before_load,
		"a corrupt load leaves every GameState field untouched")
	_check(_expected() == untouched,
		"and the baseline state is still the pre-corruption one")

	var list: Array[Dictionary] = SaveSystem.list_saves()
	_check(not bool(list[1]["valid"]) and not bool(list[2]["valid"]),
		"list_saves() reports the corrupt slots as valid=false")
	_check(not bool(list[1]["empty"]) and not bool(list[2]["empty"]),
		"corrupt slots are not reported as empty (the file exists)")
	_check(bool(list[0]["valid"]), "the good slot is still valid")

	# A syntactically valid file with a broken shape is also rejected.
	var broken: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(SaveSystem.slot_path(1)))
	broken.erase("player")
	_write_json(2, broken)
	before_load = _expected()
	_check(SaveSystem.load(2) == false, "a payload missing 'player' is rejected")
	_check(_expected() == before_load, "state untouched after the shape rejection")

	# An empty file is corrupt too, and must not crash.
	var empty_file := FileAccess.open(SaveSystem.slot_path(2), FileAccess.WRITE)
	empty_file.close()
	_check(SaveSystem.load(2) == false, "an empty file is rejected")

	# Nothing above may have truncated or rewritten the good slot.
	_check(SaveSystem.load(1) and GameState.day == untouched["day"],
		"slot 1 is still loadable after all the corruption")


# --- 4. Version mismatch ---------------------------------------------------

func _test_version_mismatch() -> void:
	_make_rich_run()
	var before := _expected()

	var newer: Dictionary = SaveSystem.snapshot()
	newer["save_version"] = 999
	_write_json(1, newer)
	_check(SaveSystem.load(1) == false,
		"a save_version newer than the build (999) fails to load")
	_check(_expected() == before, "state untouched after the newer-version rejection")
	_check(not bool(SaveSystem.list_saves()[0]["valid"]),
		"the newer-version slot is reported invalid")

	var older: Dictionary = SaveSystem.snapshot()
	older["save_version"] = 0
	_write_json(1, older)
	_check(SaveSystem.load(1) == false,
		"save_version 0 is refused as a pre-release save")
	_check(_expected() == before, "state untouched after the v0 rejection")

	var missing: Dictionary = SaveSystem.snapshot()
	missing.erase("save_version")
	_write_json(1, missing)
	_check(SaveSystem.load(1) == false, "a payload with no save_version is rejected")
	_check(_expected() == before, "state untouched after the missing-version rejection")


# --- 5. Version window: there is no migration chain ------------------------

## docs/90-* §8.2 development-stage scope: `load()` accepts exactly the current
## `save_version`. An older payload is a pre-release save and is refused by
## name — there is no `MIGRATIONS` table and no test seam that could add one.
func _test_version_window() -> void:
	_make_rich_run()
	var zero: Dictionary = SaveSystem.snapshot()
	zero["save_version"] = 0
	_write_json(1, zero)

	_check(not ("MIGRATIONS" in SaveSystem),
		"the shipped system has no MIGRATIONS table (dev-stage scope)")
	_check(not SaveSystem.has_method("_migrate"),
		"the migration walker is gone with the chain")
	# `save_version` 0 is not a save this project ever wrote: still refused.
	var before := _expected()
	_check(SaveSystem.load(1) == false, "a v0 file fails to load")
	_check(SaveSystem.last_read_error.contains("invalid save_version"),
		"the reason names an invalid version (got '%s')" % SaveSystem.last_read_error)
	_check(_expected() == before, "state untouched when a v0 save is refused")

	# A complete payload from an older phase is refused on its version alone —
	# nothing migrates it (docs/90-* §8.2 development-stage scope).
	for version in [1, 2, 3, 4]:
		var older: Dictionary = SaveSystem.snapshot()
		older["save_version"] = version
		_write_json(1, older)
		before = _expected()
		_check(SaveSystem.load(1) == false,
			"a save_version %d file fails to load" % version)
		_check(SaveSystem.last_read_error.contains("pre-release")
			and SaveSystem.last_read_error.contains(str(version)),
			"the reason names the pre-release version %d (got '%s')"
			% [version, SaveSystem.last_read_error])
		_check(_expected() == before,
			"state untouched after the v%d rejection" % version)

	# A pre-release payload is refused on its version alone, so the shape of an
	# old file never has to match today's — that is the whole dev-stage rule.
	var shapeless: Dictionary = SaveSystem.snapshot()
	shapeless["save_version"] = 1
	shapeless.erase("morale")
	_write_json(1, shapeless)
	before = _expected()
	_check(SaveSystem.load(1) == false,
		"an incomplete v1 file is still refused")
	_check(SaveSystem.last_read_error.contains("pre-release"),
		"the reason is the version, not the missing key (got '%s')"
		% SaveSystem.last_read_error)
	_check(_expected() == before, "state untouched after the incomplete v1 rejection")

	# A current-version file loads unchanged.
	_check(SaveSystem.save(1), "a current-version save is written")
	_check(SaveSystem.load(1), "a current-version file still loads")
	_check(GameState.day == before["day"], "the current-version payload is unchanged")


# --- 5b. An absent market_stocks defaults to derived rest -----------------
## docs/90-* §8.1: the documented default of an absent `market_stocks` is
## the DERIVED resting stock (docs/30-* §4.2, no RNG) — computed at load,
## not a literal.
func _test_market_stocks_derived_default() -> void:
	_make_rich_run()
	var payload: Dictionary = SaveSystem.snapshot()
	payload.erase("market_stocks")
	_write_json(1, payload)
	_clobber_state()
	_check(SaveSystem.load(1), "a v5 payload without market_stocks loads")
	_check(GameState.market_stocks.size() == DataLoader.ports_list.size(),
		"the default stocks every port (%d)" % GameState.market_stocks.size())
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 160,
		"lisbon wine defaults to its derived rest 160 (got %d)"
		% int(GameState.market_stocks["lisbon"]["wine"]))
	_check(int(GameState.market_stocks["london"]["wine"]) == 40,
		"london wine defaults to its derived rest 40")
	# The other Phase-5 keys still restore around the default.
	_check(GameState.npc_preset == "high" and GameState.wrecks.size() == 1,
		"npc_preset and wrecks restore alongside the stock default")


# --- 6. F5 at sea ----------------------------------------------------------

func _test_f5_at_sea() -> void:
	_attach_hud()
	_make_rich_run()
	GameState.current_port = null
	_delete_all_slots()
	_check(not SaveSystem.can_save_here(), "can_save_here() is false at sea")

	# Through the real input path: the autoload owns F5.
	var event := InputEventAction.new()
	event.action = "quick_save"
	event.pressed = true
	SaveSystem._unhandled_input(event)

	_check(not SaveSystem.has_save(1), "F5 at sea writes no file")
	var toast := hud_toast_text()
	_check(toast == I18n.t_key("ui.cant_save_here"),
		"F5 at sea toasts ui.cant_save_here (got '%s')" % toast)
	_check(GameState.day != 0, "F5 at sea leaves the run alone")

	# The API path behaves identically (a host may call it directly).
	var day_before := GameState.day
	_check(SaveSystem.quick_save(1) == false, "quick_save() returns false at sea")
	_check(not SaveSystem.has_save(1), "quick_save() at sea writes no file")
	_check(GameState.day == day_before, "quick_save() at sea does not mutate state")

	# And through the real input pipeline: a physical F5 key press reaches the
	# autoload's global `_unhandled_input` (proves the project action wiring).
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F5
	key.pressed = true
	Input.parse_input_event(key)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not SaveSystem.has_save(1), "a dispatched F5 key press at sea writes no file")
	_check(hud_toast_text() == I18n.t_key("ui.cant_save_here"),
		"a dispatched F5 key press toasts ui.cant_save_here")

	_detach_hud()


# --- 7. F5 in port + save_completed ---------------------------------------

func _test_f5_in_port_and_keys() -> void:
	_attach_hud()
	_make_rich_run()
	GameState.current_port = "lisbon"
	_delete_all_slots()

	var slots: Array = []
	var handler := func(slot: int) -> void: slots.append(slot)
	EventBus.save_completed.connect(handler)
	_check(SaveSystem.quick_save(1), "quick_save() in port succeeds")
	EventBus.save_completed.disconnect(handler)
	_check(SaveSystem.has_save(1), "F5 in port writes slot 1")
	_check(slots == [1], "EventBus.save_completed(1) fired once (got %s)" % str(slots))
	var toast := hud_toast_text()
	_check(toast == I18n.t_key("ui.saved"),
		"F5 in port toasts ui.saved (got '%s')" % toast)

	# An existing slot asks before overwriting (docs/80-* §4.6).
	var file_before := FileAccess.get_file_as_string(SaveSystem.slot_path(1))
	GameState.day = 99
	_check(SaveSystem.quick_save(1), "F5 over a filled slot accepts the request")
	_dismiss_modals()
	_check(FileAccess.get_file_as_string(SaveSystem.slot_path(1)) == file_before,
		"nothing is written until the overwrite confirm is accepted")
	_check(SaveSystem.load(1) and GameState.day != 99,
		"the old save is intact after a cancelled overwrite")

	# Accepting the confirm writes and toasts.
	GameState.day = 99
	_check(SaveSystem.quick_save(1), "F5 over a filled slot again")
	var confirms := _confirm_dialogs()
	_check(confirms.size() == 1, "the overwrite confirm is up (got %d)" % confirms.size())
	if confirms.size() == 1:
		confirms[0].accept()
	_check(SaveSystem.load(1) and GameState.day == 99,
		"accepting the confirm overwrites the slot (day 99)")
	_check(hud_toast_text() == I18n.t_key("ui.saved"),
		"the accepted overwrite toasts ui.saved")

	# F9: quick-load slot 1 asks first, then restores and reports routing.
	_make_rich_run()
	GameState.day = 5
	_check(SaveSystem.save(2), "a second slot for the quick-load test")
	GameState.day = 77
	SaveSystem.route_after_load = false
	_check(SaveSystem.quick_load(1), "F9 accepts the request")
	_dismiss_modals()
	_check(GameState.day == 77, "a cancelled F9 confirm loads nothing")
	_check(SaveSystem.quick_load(1), "F9 requested again")
	confirms = _confirm_dialogs()
	_check(confirms.size() == 1, "F9 shows a confirm dialog")
	if confirms.size() == 1:
		confirms[0].accept()
	_check(GameState.day == 99, "accepting the F9 confirm loads slot 1 (day 99)")
	SaveSystem.route_after_load = true

	# F9 on an empty/corrupt slot is refused without a confirm.
	_delete_all_slots()
	_write_raw(1, "not json")
	_check(SaveSystem.quick_load(1) == false,
		"F9 on a corrupt slot returns false")
	_check(_confirm_dialogs().is_empty(), "a corrupt F9 shows no confirm")
	_check(hud_toast_text() == I18n.t_key("ui.invalid_slot"),
		"F9 on a corrupt slot toasts ui.invalid_slot")

	_detach_hud()


# --- 8. Routing on load ----------------------------------------------------

func _test_routing_on_load() -> void:
	_make_rich_run()
	_check(SaveSystem.save(1), "save for the routing test")
	var routed: Array = []
	var handler := func(slot: int) -> void: routed.append(slot)
	SaveSystem.load_completed.connect(handler)
	SaveSystem.route_after_load = false

	GameState.current_port = "lisbon"
	_check(SaveSystem.load(1), "load with a docked save succeeds")
	_check(SaveSystem.load_route_target() == SaveSystem.PORT_SCENE,
		"a port save routes to port_screen.tscn (S4)")
	_check(SaveSystem.load_route_target().ends_with("port_screen.tscn"),
		"the S4 route is the real port scene")
	_check(ResourceLoader.exists(SaveSystem.PORT_SCENE),
		"port_screen.tscn exists")

	GameState.current_port = null
	_check(SaveSystem.save(2), "save at sea")
	_clobber_state()
	_check(SaveSystem.load(2), "load an at-sea save succeeds")
	_check(GameState.current_port == null, "current_port is null after an at-sea load")
	_check(SaveSystem.load_route_target() == SaveSystem.WORLD_SCENE,
		"an at-sea save routes to world_map.tscn (S3)")
	_check(ResourceLoader.exists(SaveSystem.WORLD_SCENE),
		"world_map.tscn exists")
	_check(routed == [1, 2], "load_completed fired once per load (got %s)" % str(routed))

	SaveSystem.load_completed.disconnect(handler)
	SaveSystem.route_after_load = true
	_check(SaveSystem.route_after_load, "routing is re-enabled for production use")


# --- 9. No autosave -------------------------------------------------------

func _test_no_autosave() -> void:
	_delete_all_slots()
	# A brand-new game must not write anything (docs/80-* §4.6 "no autosave").
	GameState.new_game("portugal", false)
	_check(SaveSystem.list_saves().all(func(entry: Dictionary) -> bool:
		return bool(entry["empty"])), "new_game writes no save")
	_check(not SaveSystem.has_save(1) and not SaveSystem.has_save(2)
		and not SaveSystem.has_save(3), "no slot file exists after new_game")

	# Entering / leaving port and loading do not autosave either.
	GameState.current_port = "lisbon"
	_check(SaveSystem.load_route_target() == SaveSystem.PORT_SCENE,
		"a new run in port would route to S4")
	_check(SaveSystem.list_saves().all(func(entry: Dictionary) -> bool:
		return bool(entry["empty"])), "no save appeared while idling in port")


# --- 9b. Fleet capacity guard hook (docs/40-* §6, T18) --------------------

## `Fleet.normalize_all()` is T18's and is **not** edited here. The load path
## reaches it through a dynamic call, so this suite proves the hook with a
## stand-in script: `${path}.gd`-free, defined in `user://` so no repo file is
## added.
func _test_fleet_guard_hook() -> void:
	var stand_in_path := "user://test_t17_fleet_guard.gd"
	var source := """extends RefCounted

static var calls: int = 0
static var truncate: bool = false

static func normalize_all() -> bool:
	calls += 1
	return truncate
"""
	DirAccess.make_dir_recursive_absolute("user://")
	var file := FileAccess.open(stand_in_path, FileAccess.WRITE)
	_check(file != null, "the stand-in fleet script can be written")
	if file == null:
		return
	file.store_string(source)
	file.close()
	var stand_in = ResourceLoader.load(stand_in_path)
	_check(stand_in != null and stand_in.has_method("normalize_all"),
		"the stand-in script exposes normalize_all()")

	# Not truncating: reported, not logged as damage.
	stand_in.set("truncate", false)
	var result: Dictionary = SaveSystem.apply_fleet_guard(stand_in)
	_check(int(stand_in.get("calls")) == 1, "the guard calls normalize_all() once")
	_check(bool(result.get("available")), "the guard reports the function as available")
	_check(bool(result.get("truncated")) == false, "a clean fleet reports no truncation")

	# Truncating: the return value is surfaced so the load path can log it.
	stand_in.set("truncate", true)
	result = SaveSystem.apply_fleet_guard(stand_in)
	_check(int(stand_in.get("calls")) == 2, "a second load calls it again")
	_check(bool(result.get("truncated")), "a truncating normalize_all() is reported")

	# The real `fleet.gd` in this worktree has no normalize_all() yet: that is
	# the documented T18 dependency, and it must degrade to "skipped", not crash.
	var real := SaveSystem.apply_fleet_guard()
	if real.get("available") is bool and not bool(real.get("available")):
		print("NOTE  T18 dependency: fleet.gd has no normalize_all() yet; the "
			+ "guard is inert until it lands (docs/40-* §6)")
	_check(real.has("available") and real.has("truncated"),
		"the real fleet guard degrades gracefully while T18 is pending")
	_check(last_norm_rt_ok(), "the guard never throws into the load path")

	DirAccess.remove_absolute(stand_in_path)


## Re-reads the real `fleet.gd` (for the assertion above) so "missing" is
## reported rather than assumed.
func last_norm_rt_ok() -> bool:
	var script = ResourceLoader.load("res://scripts/fleet/fleet.gd")
	if script == null:
		return false
	var available: bool = script.has_method("normalize_all")
	var reported: Dictionary = SaveSystem.last_normalize
	return bool(reported.get("available", false)) == available


# --- 10. Slot dialog ------------------------------------------------------

func _test_slot_dialog() -> void:
	_delete_all_slots()
	_make_rich_run()
	GameState.day = 12
	GameState.gold = 7830
	_check(SaveSystem.save(1), "one filled slot for the dialog test")
	_write_raw(2, "garbage not json")

	var dialog: Control = SlotDialogScene.instantiate()
	add_child(dialog)
	dialog.open(SlotDialogLib.MODE_LOAD)
	_check(dialog.is_open(), "the dialog opens")
	_check(dialog.mode() == SlotDialogLib.MODE_LOAD, "the dialog is in Load mode")

	var slot1: Button = dialog.slot_button(1)
	var slot2: Button = dialog.slot_button(2)
	var slot3: Button = dialog.slot_button(3)
	_check(slot1 != null and slot2 != null and slot3 != null,
		"the dialog has three slot rows")
	_check(slot1.text.contains(I18n.t_key("ui.empty")) == false
		and slot1.text.contains(str(12)), "slot 1 shows the Day/gold summary")
	_check(slot1.text.contains("7,830") == false,
		"the summary uses the raw gold value from the data (/ doesn't add separators)")
	_check(slot2.text.contains(I18n.t_key("ui.save.invalid")),
		"a corrupt slot shows ui.save.invalid (got '%s')" % slot2.text)
	_check(slot3.text.contains(I18n.t_key("ui.empty")),
		"an unused slot shows ui.empty (got '%s')" % slot3.text)
	_check(dialog.slot_button(2).disabled,
		"a corrupt slot cannot be selected in Load mode")
	_check(slot1.disabled == false, "a valid slot is selectable in Load mode")
	_check(slot3.disabled, "an empty slot is not selectable in Load mode")

	# Choosing slot 1 reports through the signal.
	var chosen: Array = []
	dialog.slot_chosen.connect(func(slot: int) -> void: chosen.append(slot))
	dialog._on_row_pressed(1)
	_check(chosen == [1], "choosing a valid row emits slot_chosen(1)")
	_check(not dialog.is_open(), "the dialog closes after a choice")

	# Save mode: every row is selectable, the filled one asks first.
	dialog.open(SlotDialogLib.MODE_SAVE)
	_check(dialog.slot_button(2).disabled == false,
		"Save mode keeps even a corrupt row selectable")
	chosen.clear()
	# (one `slot_chosen` connection only — a second would double-report)
	dialog._on_row_pressed(1)
	_check(chosen.is_empty(), "choosing a filled slot in Save mode emits nothing yet")
	_check(dialog.is_open(), "the slot dialog stays open behind the confirm")
	var confirms: Array = []
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		# `confirmed` is a *signal*, so this needs `has_signal`, not
		# `has_method` (signals are not methods in Godot 4).
		if node is Control and node.has_signal("confirmed"):
			confirms.append(node)
	_check(confirms.size() == 1, "an overwrite confirm is shown (got %d)" % confirms.size())
	if confirms.size() == 1:
		var confirm_dialog: Control = confirms[0]
		_check(confirm_dialog.message_text()
			== I18n.fmt("ui.overwrite_confirm", {"slot": 1}),
			"the confirm asks ui.overwrite_confirm for slot 1")
		confirm_dialog.accept()
	_check(chosen == [1], "accepting the confirm emits slot_chosen(1)")

	# Free slot in Save mode: no confirm at all.
	dialog.open(SlotDialogLib.MODE_SAVE)
	chosen.clear()
	dialog._on_row_pressed(3)
	_check(chosen == [3], "an empty slot in Save mode is chosen directly")
	_check(get_tree().get_nodes_in_group("modal_overlay").is_empty(),
		"no confirm was left behind")

	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node.get_parent() == dialog:
			node.queue_free()
	dialog.queue_free()

	# Hosting: on a screen that has the shared HUD (the world map is a Node2D),
	# the dialog must land under the HUD's ModalHost so it dims the map correctly
	# instead of collapsing inside a Node2D (docs/80-* §4.7, docs/90-* §7).
	_attach_hud()
	var hosted: Control = SaveSystem.open_load_dialog()
	_check(hosted != null, "open_load_dialog() works with no explicit host")
	_check(hosted != null and hosted.get_parent() != null
		and hosted.get_parent().name == "ModalHost",
		"the dialog is parented to the HUD's ModalHost (got '%s')"
		% (hosted.get_parent().name if hosted != null and hosted.get_parent() != null else "-"))
	if hosted != null:
		hosted.cancel()
		hosted.queue_free()
	# And it is modal while open: a second F5 must not stack another dialog.
	var modal_check: Control = SaveSystem.open_load_dialog()
	_check(modal_check != null and SaveSystem._modal_open(),
		"an open slot dialog registers as a modal")
	SaveSystem._unhandled_input(_key_event("quick_save"))
	_check(_confirm_dialogs().is_empty(),
		"F5 is ignored while a modal is open (no confirm was stacked)")
	if modal_check != null:
		modal_check.cancel()
		modal_check.queue_free()
	_detach_hud()

	# The S14 character panel is modal but not in `modal_overlay`: F5 must not
	# open a save dialog underneath it either.
	_make_rich_run()
	var panel_script := load("res://scenes/ui_shared/character_panel.gd")
	var panel: Control = panel_script.attach_to(self)
	panel.toggle()
	_check(panel.is_open(), "the S14 panel is open")
	_check(SaveSystem._modal_open(), "the open character panel counts as a modal")
	SaveSystem._unhandled_input(_key_event("quick_save"))
	_check(_confirm_dialogs().is_empty(), "F5 is ignored behind the character panel")
	panel.close()
	remove_child(panel)
	panel.queue_free()


# --- 11. Title / port wiring ---------------------------------------------

func _test_title_and_port_wiring() -> void:
	_delete_all_slots()

	var title: Control = TitleScene.instantiate()
	add_child(title)
	_check(title.get_node("Center/Stack/Buttons/Load") != null,
		"the title screen has a Load row")
	var load_button: Button = title.get_node("Center/Stack/Buttons/Load")
	_check(load_button.text == I18n.t_key("title.load_game"),
		"the Load row is localised (got '%s')" % load_button.text)
	var dialog: Control = title.open_load_dialog()
	_check(dialog != null, "the title Load row opens the slot dialog")
	_check(dialog != null and dialog.is_open(), "the dialog is visible")
	_check(dialog != null and dialog.mode() == SlotDialogLib.MODE_LOAD,
		"the title opens it in Load mode")
	if dialog != null:
		dialog.queue_free()
	# Locale rebind.
	I18n.set_locale("zh")
	_check(load_button.text == I18n.t_key("title.load_game"),
		"the Load row rebinds on locale_changed")
	I18n.set_locale("en")
	title.queue_free()

	_make_rich_run()
	var port: Control = PortScene.instantiate()
	add_child(port)
	port.route_to_world = false
	var save_button: Button = port.get_node("Layout/VBox/Footer/Save")
	_check(save_button != null, "the port hub has a Save row")
	_check(save_button.text == I18n.t_key("port.save"),
		"the Save row is localised (got '%s')" % save_button.text)
	_check(save_button.disabled == false, "the Save row is enabled while docked")
	var save_dialog: Control = port.open_save_dialog()
	_check(save_dialog != null and save_dialog.is_open(),
		"the port Save row opens the slot dialog")
	_check(save_dialog != null and save_dialog.mode() == SlotDialogLib.MODE_SAVE,
		"the port opens it in Save mode")
	# Choosing a slot in that dialog must actually write through SaveSystem
	# (the dialog only reports; the owner performs the write — docs/90-* §7).
	if save_dialog != null:
		GameState.day = 64
		save_dialog._on_row_pressed(1)
		_check(SaveSystem.has_save(1), "choosing slot 1 in the port dialog writes it")
		_check(SaveSystem.slot_summary(1)["day"] == 64,
			"the written slot reports the current day (64)")
		save_dialog.queue_free()

	# With no docked port the row is disabled and refuses to open.
	GameState.current_port = null
	port._bind()
	_check(save_button.disabled, "the Save row is disabled with no docked port")
	_check(port.open_save_dialog() == null, "open_save_dialog() refuses without a port")
	port.queue_free()

	# The project maps F5/F9 to the documented actions (docs/80-* §4.3).
	_check(InputMap.has_action("quick_save"), "the quick_save action exists")
	_check(InputMap.has_action("quick_load"), "the quick_load action exists")
	_check(_action_has_key("quick_save", KEY_F5), "quick_save is bound to F5")
	_check(_action_has_key("quick_load", KEY_F9), "quick_load is bound to F9")


# --- Helpers --------------------------------------------------------------

func _action_has_key(action: String, physical_key: int) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			if (event as InputEventKey).physical_keycode == physical_key:
				return true
	return false


func _attach_hud() -> void:
	_hud = HUDScene.instantiate()
	add_child(_hud)


func _detach_hud() -> void:
	if _hud != null:
		# Detach immediately (the suite runs inside one frame, so `queue_free()`
		# alone would leave the old HUD in the tree for `_find_hud` to find).
		remove_child(_hud)
		_hud.queue_free()
		_hud = null
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is Control and node.has_method("cancel"):
			node.cancel()
		elif node is Control and node.has_method("close"):
			node.close()


func hud_toast_text() -> String:
	if _hud == null:
		return ""
	var label: Label = _hud.get_node_or_null("Toast/ToastLabel")
	return label.text if label != null else ""


## Every confirm dialog currently in the `modal_overlay` group (`confirmed` is
## a signal, hence `has_signal`, not `has_method`).
func _confirm_dialogs() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is Control and node.has_signal("confirmed"):
			out.append(node)
	return out


## A synthetic pressed action event for `action` (same shape `_unhandled_input`
## tests use elsewhere in `tools/`).
func _key_event(action: String) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event


func _dismiss_modals() -> void:
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is Control and node.has_method("cancel"):
			node.cancel()


func _write_raw(slot: int, text: String) -> void:
	_ensure_dir()
	var file := FileAccess.open(SaveSystem.slot_path(slot), FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _write_json(slot: int, data: Dictionary) -> void:
	_write_raw(slot, JSON.stringify(data, "\t"))


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
	# Remove the slot directory itself when this suite created it (a fresh
	# install has no `user://saves/`). `remove_absolute` on a non-empty dir
	# fails harmlessly; an existing dev directory with saves stays.
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
