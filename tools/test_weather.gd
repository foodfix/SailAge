extends Node
## T8 acceptance tests (docs/IMPLEMENT-Phase1.md T8; docs/20-* §4.5 step 3,
## §4.7, §4.8.1; docs/50-* §4.2; docs/80-* §4.5). Headless scene test:
##
##   godot --headless res://tools/test_weather.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Everything is seeded through `SailingSim.set_weather_seed()`, so each
## frequency check below is exactly repeatable: re-running this scene prints
## the same numbers.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")

## §4.7: "Atlantic strip = tiles with x ≤ 6". (3,57) is open Atlantic water
## west of Lisbon (x = 7); (60,50) is open water in the rest-of-map zone.
const ATLANTIC_CELL := Vector2i(3, 57)
const REST_OF_MAP_CELL := Vector2i(60, 50)

## Sample sizes / tolerances from the §4.7 "Reachability acceptance" note.
const ROLLS := 10000
const FREQUENCY_TOLERANCE := 0.02
const TRIALS := 10000
const DAYS_PER_TRIAL := 6
## §4.7 acceptance thresholds (supersede the unreachable "≥ 0.97 in 5 days").
const MIN_5_DAY_PROBABILITY := 0.96
const MIN_6_DAY_PROBABILITY := 0.98
## The milestone seed. Any fixed seed works; this one is pinned so the printed
## empirical rates are reproducible forever.
const WEATHER_SEED := 20261029

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/p1_mediterranean.txt", DataLoader.map_legend
	)
	_check(ok, "map loads for the zone/passability fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	_test_zone_table()
	_test_storm_frequency()
	_test_luck_scales_storm_chance()
	_test_redistribution_preserves_table()
	_test_damage_formula()
	_test_storm_damage_applied_to_fleet()
	_test_no_morale_change()
	_test_weather_persists()
	_test_reachability()
	_test_determinism()
	_test_ledger_order_weather()
	_test_hud_weather()
	_report()


# --- Fixtures --------------------------------------------------------------

func _make_run(
	weather: String = "fair",
	cell: Vector2i = ATLANTIC_CELL,
	luck: int = 10,
	ship_ids: Array = ["caravel"],
	crew: int = 15,
	gold: int = 100000
) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": luck,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.fleet = []
	for ship_id in ship_ids:
		var ship: Dictionary = FleetLib.new_ship(str(ship_id), crew)
		ship["provisions"] = 100
		ship["water"] = 100
		GameState.fleet.append(ship)
	GameState.day = 1
	GameState.gold = gold
	GameState.morale = SailingSimLib.MORALE_START
	GameState.current_port = null
	GameState.known_ports = []
	GameState.world = {
		"position": {"x": cell.x, "y": cell.y},
		"clock_fraction": 0.0,
		"weather": weather,
	}
	# T9's transient statics: counters, game-over flag, dialog buffer, mutiny
	# offer and the per-tick flags (a previous scenario's storm/death must never
	# freeze this one).
	SailingSimLib.reset_ledger_state()


func _one_day() -> int:
	return SailingSimLib.advance_clock(1.0)


## Samples `count` weather rolls at the current fleet tile, returning the number
## of storms. Calls the production [method SailingSim.roll_weather] on the tile
## read from GameState (so a zone bug is still caught) but deliberately skips
## the storm damage: 10,000 storm days would sink the fleet mid-measurement.
func _sample_storms(count: int) -> int:
	var storms := 0
	var tile := GameState.world_tile()
	for index in count:
		if SailingSimLib.roll_weather(tile) == "storm":
			storms += 1
	return storms


func _tile(x: int, y: int) -> Vector2i:
	GameState.world["position"] = {"x": x, "y": y}
	return Vector2i(x, y)


## Restores stores and hull for the long weather loops: T9's ledger would
## otherwise starve or sink the fixture before the loop finishes, and this
## suite measures the §4.7 roll, not the §4.9 fail states.
func _refill() -> void:
	for ship in GameState.fleet:
		ship["durability"] = FleetLib.ship_stat(ship, "durability")
		ship["provisions"] = 500
		ship["water"] = 500
	GameState.gold = 100000
	GameState.morale = 70


# --- §4.7 zone table -------------------------------------------------------

func _test_zone_table() -> void:
	# Zone definition: Atlantic strip is exactly x ≤ 6.
	_check(SailingSimLib.weather_zone_for(Vector2i(0, 0)) == "atlantic_strip",
		"x=0 is the Atlantic strip")
	_check(SailingSimLib.weather_zone_for(Vector2i(6, 57)) == "atlantic_strip",
		"x=6 is still the Atlantic strip (§4.7 x ≤ 6)")
	_check(SailingSimLib.weather_zone_for(Vector2i(7, 57)) == "rest_of_map",
		"x=7 (Lisbon) is rest of map")
	_check(SailingSimLib.weather_zone_for(REST_OF_MAP_CELL) == "rest_of_map",
		"x=60 is rest of map")

	# At luck 0 the luck multiplier is 1.0 → the table is the doc's verbatim.
	_make_run("fair", ATLANTIC_CELL, 0)
	var strip := SailingSimLib.zone_probabilities("atlantic_strip")
	_check(is_equal_approx(strip["calm"], 0.05) and is_equal_approx(strip["fair"], 0.30)
		and is_equal_approx(strip["strong"], 0.15) and is_equal_approx(strip["storm"], 0.50),
		"luck 0 strip table == 0.05/0.30/0.15/0.50 (got %s)" % str(strip))
	var rest := SailingSimLib.zone_probabilities("rest_of_map")
	_check(is_equal_approx(rest["calm"], 0.20) and is_equal_approx(rest["fair"], 0.55)
		and is_equal_approx(rest["strong"], 0.15) and is_equal_approx(rest["storm"], 0.10),
		"luck 0 rest table == 0.20/0.55/0.15/0.10 (got %s)" % str(rest))

	# And they are exactly normalised at every luck value.
	for luck in [0, 10, 50, 100, 399]:
		_make_run("fair", ATLANTIC_CELL, luck)
		for zone in ["atlantic_strip", "rest_of_map"]:
			var p := SailingSimLib.zone_probabilities(zone)
			var total := 0.0
			for outcome in SailingSimLib.WEATHER_OUTCOMES:
				total += float(p[outcome])
			_check(is_equal_approx(total, 1.0),
				"luck %d %s probabilities sum to 1.0 (got %.12f)" % [luck, zone, total])


# --- §4.7 storm frequency: 10,000 rolls, 0.5 ± 0.02 (strip) ----------------

func _test_storm_frequency() -> void:
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_make_run("fair", ATLANTIC_CELL, 10)
	var strip_storms := _sample_storms(ROLLS)
	var strip_rate := float(strip_storms) / float(ROLLS)
	print("  strip (x=3, luck 10): %d / %d storms = %.4f" % [
		strip_storms, ROLLS, strip_rate
	])
	_check(absf(strip_rate - 0.50) <= FREQUENCY_TOLERANCE,
		"Atlantic strip storm frequency 0.50±0.02 over %d rolls (got %.4f)"
		% [ROLLS, strip_rate])

	SailingSimLib.set_weather_seed(WEATHER_SEED + 1)
	_make_run("fair", REST_OF_MAP_CELL, 10)
	var rest_storms := _sample_storms(ROLLS)
	var rest_rate := float(rest_storms) / float(ROLLS)
	print("  rest  (x=60, luck 10): %d / %d storms = %.4f" % [
		rest_storms, ROLLS, rest_rate
	])
	_check(absf(rest_rate - 0.10) <= FREQUENCY_TOLERANCE,
		"rest-of-map storm frequency 0.10±0.02 over %d rolls (got %.4f)"
		% [ROLLS, rest_rate])

	# The strip is materially more dangerous, which is its whole purpose.
	_check(strip_rate > rest_rate * 3.0,
		"the Atlantic strip is at least 3× stormier than the rest of the map "
		+ "(%.4f vs %.4f)" % [strip_rate, rest_rate])


# --- docs/50-* §4.2: luck scales the storm chance only ---------------------

func _test_luck_scales_storm_chance() -> void:
	# 0.5 × (1 − luck/400): luck 0 → 0.5000, 10 → 0.4875, 100 → 0.3750.
	var rows := [
		[0, 0.5000],
		[10, 0.4875],
		[100, 0.3750],
	]
	for row in rows:
		var luck: int = row[0]
		var expected: float = row[1]
		SailingSimLib.set_weather_seed(WEATHER_SEED + luck)
		_make_run("fair", ATLANTIC_CELL, luck)
		var storms := _sample_storms(ROLLS)
		var rate := float(storms) / float(ROLLS)
		print("  luck %3d: %d / %d storms = %.4f (expected %.4f)" % [
			luck, storms, ROLLS, rate, expected
		])
		_check(absf(rate - expected) <= FREQUENCY_TOLERANCE,
			"luck %d storm frequency %.4f±0.02 (got %.4f)" % [luck, expected, rate])
		_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 1.0 - luck / 400.0),
			"Character.storm_chance_multiplier() == 1 − luck/400 at luck %d" % luck)

	# Monotone: more luck can never raise the storm probability.
	_make_run("fair", ATLANTIC_CELL, 0)
	var p0 := float(SailingSimLib.zone_probabilities("atlantic_strip")["storm"])
	_make_run("fair", ATLANTIC_CELL, 100)
	var p100 := float(SailingSimLib.zone_probabilities("atlantic_strip")["storm"])
	_check(p0 > p100, "luck 0 storm chance (%.4f) exceeds luck 100 (%.4f)" % [p0, p100])


# --- redistribution keeps the doc's non-storm ratios ----------------------

func _test_redistribution_preserves_table() -> void:
	# (1 − storm') / (1 − base_storm) scaling: at luck 10 the strip's non-storm
	# mass is scaled by 0.5125/0.50 = 1.025, so calm becomes 0.05125, etc.
	_make_run("fair", ATLANTIC_CELL, 10)
	var strip := SailingSimLib.zone_probabilities("atlantic_strip")
	_check(is_equal_approx(strip["storm"], 0.5 * (1.0 - 10.0 / 400.0)),
		"luck 10 strip storm = 0.5 × (1 − 10/400) = 0.4875 (got %.6f)"
		% strip["storm"])
	_check(is_equal_approx(strip["calm"], 0.05 * (1.025)),
		"the freed storm mass goes to calm by its base share: 0.05125 (got %.6f)"
		% strip["calm"])
	_check(is_equal_approx(strip["fair"], 0.30 * (1.025)),
		"…and to fair: 0.3075 (got %.6f)" % strip["fair"])
	_check(is_equal_approx(strip["strong"], 0.15 * (1.025)),
		"…and to strong: 0.15375 (got %.6f)" % strip["strong"])

	# Non-storm outcomes keep their relative shares at every luck value
	# (calm:fair:strong stays 1:6:3 in the strip, 4:11:3 in the rest).
	for luck in [0, 10, 50, 100, 300]:
		_make_run("fair", ATLANTIC_CELL, luck)
		var p := SailingSimLib.zone_probabilities("atlantic_strip")
		var ratio_fair := float(p["fair"]) / float(p["calm"])
		var ratio_strong := float(p["strong"]) / float(p["calm"])
		_check(is_equal_approx(ratio_fair, 6.0) and is_equal_approx(ratio_strong, 3.0),
			"luck %d: strip calm:fair:strong still 1:6:3 (got 1:%.4f:%.4f)"
			% [luck, ratio_fair, ratio_strong])
		var q := SailingSimLib.zone_probabilities("rest_of_map")
		_check(is_equal_approx(float(q["fair"]) / float(q["calm"]), 0.55 / 0.20)
			and is_equal_approx(float(q["strong"]) / float(q["calm"]), 0.15 / 0.20),
			"luck %d: rest calm:fair:strong still 4:11:3" % luck)

	# Luck cannot inflate a non-storm outcome past the sum check (already
	# asserted) and never exceeds the storm's own reduction.
	_check(strip["storm"] < 0.5, "the strip's storm chance drops below the base 0.50")


# --- §4.7 / §5 storm damage formula ---------------------------------------

func _test_damage_formula() -> void:
	# Caravel 90 → ceil(4.5) = 5; luck ≥ 50 → ceil(3.375) = 4.
	_make_run("fair", ATLANTIC_CELL, 10)
	_check(SailingSimLib.storm_damage_for(90) == 5,
		"caravel (90) takes ceil(90×0.05) = 5 at luck 10 (got %d)"
		% SailingSimLib.storm_damage_for(90))
	_make_run("fair", ATLANTIC_CELL, 49)
	_check(SailingSimLib.storm_damage_for(90) == 5,
		"luck 49 is below the threshold: still 5 (got %d)"
		% SailingSimLib.storm_damage_for(90))
	_make_run("fair", ATLANTIC_CELL, 50)
	_check(SailingSimLib.storm_damage_for(90) == 4,
		"luck 50: ceil(90×0.05×0.75) = ceil(3.375) = 4 (got %d)"
		% SailingSimLib.storm_damage_for(90))
	_check(is_equal_approx(CharacterLib.storm_damage_multiplier(), 0.75),
		"Character.storm_damage_multiplier() == 0.75 at luck 50")

	# Luck is applied BEFORE ceil, not after (5 × 0.75 = 3.75 → 4, not 4 × 0.75).
	_check(SailingSimLib.storm_damage_for(90) == 4,
		"mitigation is applied before rounding (4, not floor(5×0.75)=3)")

	# Every hull in data/ship_types.json, both luck regimes, exact §4.7 values.
	_make_run("fair", ATLANTIC_CELL, 10)
	var expected_plain := {
		"latin": 2, "sloop": 3, "caravel": 5, "galley": 4,
		"brigantine": 6, "nao": 7, "carrack": 9, "galleon": 12,
	}
	for ship_id in expected_plain:
		var max_dur := int(DataLoader.get_ship_type(str(ship_id))["durability"])
		_check(SailingSimLib.storm_damage_for(max_dur) == int(expected_plain[ship_id]),
			"%s (%d) takes %d damage at luck < 50 (got %d)" % [
				ship_id, max_dur, int(expected_plain[ship_id]),
				SailingSimLib.storm_damage_for(max_dur)
			])
	_make_run("fair", ATLANTIC_CELL, 50)
	var expected_mitigated := {
		"latin": 2, "sloop": 3, "caravel": 4, "galley": 3,
		"brigantine": 5, "nao": 6, "carrack": 7, "galleon": 9,
	}
	for ship_id in expected_mitigated:
		var max_dur := int(DataLoader.get_ship_type(str(ship_id))["durability"])
		_check(SailingSimLib.storm_damage_for(max_dur) == int(expected_mitigated[ship_id]),
			"%s (%d) takes %d damage at luck ≥ 50 (got %d)" % [
				ship_id, max_dur, int(expected_mitigated[ship_id]),
				SailingSimLib.storm_damage_for(max_dur)
			])


func _test_storm_damage_applied_to_fleet() -> void:
	# Multi-ship fleet: caravel 90 + nao 140 → 5 and 7 damage (§4.7).
	_make_run("fair", ATLANTIC_CELL, 10, ["caravel", "nao"])
	_check(int(GameState.fleet[0]["durability"]) == 90
		and int(GameState.fleet[1]["durability"]) == 140,
		"fixture starts at full durability (90/140)")
	var changes: Array = []
	var listener := func() -> void: changes.append(true)
	EventBus.fleet_changed.connect(listener)
	var dealt := SailingSimLib.apply_storm_damage()
	EventBus.fleet_changed.disconnect(listener)
	_check(int(GameState.fleet[0]["durability"]) == 85,
		"caravel 90 → 85 (got %d)" % int(GameState.fleet[0]["durability"]))
	_check(int(GameState.fleet[1]["durability"]) == 133,
		"nao 140 → 133 (got %d)" % int(GameState.fleet[1]["durability"]))
	_check(dealt == 12, "total damage dealt is 5 + 7 = 12 (got %d)" % dealt)
	_check(changes.size() == 1,
		"fleet_changed emitted exactly once per storm day (got %d)" % changes.size())

	# Luck ≥ 50 lets the same fleet ride it out with less damage: 4 and 6.
	_make_run("fair", ATLANTIC_CELL, 50, ["caravel", "nao"])
	SailingSimLib.apply_storm_damage()
	_check(int(GameState.fleet[0]["durability"]) == 86
		and int(GameState.fleet[1]["durability"]) == 134,
		"luck 50 fleet: caravel 90 → 86, nao 140 → 134 (got %d/%d)" % [
			int(GameState.fleet[0]["durability"]),
			int(GameState.fleet[1]["durability"]),
		])

	# A storm day through the *ledger*: find a seed whose first roll is a storm,
	# then assert exactly the §4.7 damage landed once (no double application).
	var storm_seed := -1
	for candidate in 500:
		SailingSimLib.set_weather_seed(candidate)
		_make_run("fair", ATLANTIC_CELL, 10)
		if SailingSimLib.roll_weather(ATLANTIC_CELL) == "storm":
			storm_seed = candidate
			break
	_check(storm_seed >= 0,
		"found a seed whose first Atlantic roll is a storm (found %d)" % storm_seed)
	if storm_seed >= 0:
		SailingSimLib.set_weather_seed(storm_seed)
		_make_run("fair", ATLANTIC_CELL, 10)
		_one_day()
		_check(str(GameState.world["weather"]) == "storm",
			"the seeded ledger day is a storm (%s)" % str(GameState.world["weather"]))
		_check(SailingSimLib.last_day_storm, "last_day_storm is true after that day")
		_check(int(GameState.fleet[0]["durability"]) == 85,
			"a storm ledger day removes exactly 5 durability once (90 → %d)"
			% int(GameState.fleet[0]["durability"]))

	# Durability clamps at 0 and never goes negative; damage stops there.
	_make_run("fair", ATLANTIC_CELL, 10)
	GameState.fleet[0]["durability"] = 2
	var quiet: Array = []
	var quiet_listener := func() -> void: quiet.append(true)
	EventBus.fleet_changed.connect(quiet_listener)
	var clamped := SailingSimLib.apply_storm_damage()
	EventBus.fleet_changed.disconnect(quiet_listener)
	_check(int(GameState.fleet[0]["durability"]) == 0,
		"durability 2 − 5 clamps at 0, never negative (got %d)"
		% int(GameState.fleet[0]["durability"]))
	_check(clamped == 2, "only the 2 points actually removed are counted (got %d)" % clamped)

	# Already at 0: no change, so no spurious fleet_changed (T9 owns sinking).
	_make_run("fair", ATLANTIC_CELL, 10)
	GameState.fleet[0]["durability"] = 0
	var silent: Array = []
	var silent_listener := func() -> void: silent.append(true)
	EventBus.fleet_changed.connect(silent_listener)
	SailingSimLib.apply_storm_damage()
	EventBus.fleet_changed.disconnect(silent_listener)
	_check(silent.is_empty() and int(GameState.fleet[0]["durability"]) == 0,
		"a hull already at 0 emits nothing and stays 0")


# --- T8 rolls the storm; T9's step 4 prices it ----------------------------
# T8 owns the roll and the damage only. Since T9 landed step 4, a storm day now
# *does* cost morale (−5) on top of the −1 sea baseline; this suite asserts the
# §4.8.1 arithmetic so a regression in either step is visible here.

func _test_no_morale_change() -> void:
	# Force a storm day deterministically by driving the ledger until one lands;
	# then assert the flag is set and morale followed the §4.8.1 delta.
	_make_run("fair", ATLANTIC_CELL, 10)
	GameState.morale = 70
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var storm_days := 0
	for day in 6:
		var before := GameState.morale
		_one_day()
		# The flag read *after* the tick describes the day just run.
		var expected := before - 1 - (5 if SailingSimLib.last_day_storm else 0)
		if SailingSimLib.last_day_storm:
			storm_days += 1
		_check(GameState.morale == expected,
			"day %d: §4.8.1 delta −1%s → %d (got %d)"
			% [day + 1, " −5 (storm)" if SailingSimLib.last_day_storm else "", expected, GameState.morale])
	_check(storm_days > 0,
		"the seeded 6-day Atlantic run contains at least one storm (got %d)" % storm_days)

	# The flag itself: true on a storm, false on the next non-storm day.
	_make_run("fair", ATLANTIC_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var saw_flag_true := false
	var saw_flag_false_after_storm := false
	var previous_was_storm := false
	var mismatches := 0
	for day in 40:
		# Weather-only fixture: keep T9's fail states (T9 suffix of the ledger)
		# out of the measurement by restoring stores and hull each day.
		_refill()
		_one_day()
		var now_storm: bool = str(GameState.world["weather"]) == "storm"
		if SailingSimLib.last_day_storm != now_storm:
			mismatches += 1
		if SailingSimLib.last_day_storm:
			saw_flag_true = true
			previous_was_storm = true
		elif previous_was_storm:
			saw_flag_false_after_storm = true
			previous_was_storm = false
	_check(mismatches == 0,
		"last_day_storm mirrors world.weather on all 40 days (got %d mismatches)"
		% mismatches)
	_check(saw_flag_true, "last_day_storm is raised on storm days")
	_check(saw_flag_false_after_storm,
		"last_day_storm is cleared again on the next non-storm day")

	# In port too: the roll still happens (zone-based), and step 4 applies the
	# in-port +5 up to the port cap 80 (§4.8.1) — never a sea delta.
	_make_run("fair", ATLANTIC_CELL, 10)
	GameState.current_port = "lisbon"
	GameState.morale = 70
	for day in 20:
		SailingSimLib.advance_port_day()
	_check(GameState.morale == SailingSimLib.MORALE_PORT_CAP,
		"port day-advances climb +5 to the cap 80 (70 → %d)" % GameState.morale)


# --- Persistence: the roll is written into GameState.world ----------------

func _test_weather_persists() -> void:
	_make_run("fair", ATLANTIC_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var seen := {}
	var invalid: Array[String] = []
	for day in 200:
		_refill()
		_one_day()
		var weather := str(GameState.world["weather"])
		seen[weather] = true
		if not (weather in SailingSimLib.WEATHER_OUTCOMES):
			invalid.append(weather)
	_check(invalid.is_empty(),
		"world.weather holds a §4.7 outcome on all 200 days (bad: %s)" % str(invalid))
	# One storm-free counter-check: the roll overwrote the pre-set "fair".
	_check(seen.has("storm") and seen.has("calm"),
		"200 Atlantic days produce several outcomes (saw %s)" % str(seen.keys()))

	# The zone follows the tile: same seed, x=60 → rest-of-map table.
	_make_run("fair", REST_OF_MAP_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_one_day()
	_check(SailingSimLib.last_weather_zone == "rest_of_map",
		"the roll reads the fleet's current tile, not a cached zone (got %s)"
		% SailingSimLib.last_weather_zone)
	_tile(3, 57)
	_one_day()
	_check(SailingSimLib.last_weather_zone == "atlantic_strip",
		"moving to x=3 switches the next roll to the strip (got %s)"
		% SailingSimLib.last_weather_zone)

	# No transient keys leak into GameState.world (T17 save-block hygiene):
	# the storm flags are class statics, exactly like last_day_shortfalls.
	var allowed := ["position", "clock_fraction", "weather"]
	for key in GameState.world:
		_check(str(key) in allowed,
			"GameState.world carries no transient ledger key ('%s')" % str(key))
	_check(not GameState.world.has("last_weather_zone")
		and not GameState.world.has("last_day_storm"),
		"zone/storm flags stay off the save block")


# --- §4.7 "Reachability acceptance" ---------------------------------------

func _closed_form(p: float, days: int) -> float:
	return 1.0 - pow(1.0 - p, days)


func _test_reachability() -> void:
	# 1. Closed form, exact to 4 dp (§4.7 table).
	var p := 0.5 * (1.0 - 10.0 / 400.0)  # luck 10 → 0.4875
	_check(is_equal_approx(p, 0.4875), "p at luck 10 is 0.4875 (got %.6f)" % p)
	var five := _closed_form(p, 5)
	var six := _closed_form(p, 6)
	print("  closed form: p=%.4f  1−(1−p)^5=%.4f  1−(1−p)^6=%.4f" % [p, five, six])
	_check(absf(five - 0.9646) < 0.00005,
		"1 − (1−p)^5 = 0.9646 to 4 dp (got %.4f)" % five)
	# §4.7 prints this row as 0.98195; the exact value of 1 − 0.5125⁶ is
	# 0.981879784…, i.e. 0.9819 at 4 dp (0.982 at 3 dp). The doc's 5th decimal
	# is a rounding slip, not a different formula — asserted at both precisions.
	_check(absf(six - 0.98188) < 0.00005,
		"1 − (1−p)^6 = 0.9819 to 4 dp (got %.4f)" % six)
	_check(absf(six - 0.982) <= 0.0005,
		"…which is the doc's 0.982 at the table's 3-dp precision")
	_check(five >= MIN_5_DAY_PROBABILITY and six >= MIN_6_DAY_PROBABILITY,
		"closed form clears the amended thresholds (≥0.96 in 5, ≥0.98 in 6)")

	# 2. Empirical: 10,000 seeded 6-day trials at x ≤ 6, luck 10. The fleet is
	#    kept at the Atlantic cell and the trial samples only the roll, so a
	#    trial cannot be cut short by storm damage or starvation.
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_make_run("fair", ATLANTIC_CELL, 10)
	var by_day: Array[int] = [0, 0, 0, 0, 0, 0]
	var atlantic_tile := GameState.world_tile()
	_check(atlantic_tile.x <= SailingSimLib.ATLANTIC_STRIP_MAX_X,
		"the reachability trials sit at x=%d (the Atlantic strip)" % atlantic_tile.x)
	for trial in TRIALS:
		var hit := false
		for day in DAYS_PER_TRIAL:
			var weather := SailingSimLib.roll_weather(atlantic_tile)
			if weather == "storm":
				if not hit:
					by_day[day] += 1
				hit = true
	var within_5 := 0
	for day in 5:
		within_5 += by_day[day]
	var within_6 := within_5 + by_day[5]
	var rate_5 := float(within_5) / float(TRIALS)
	var rate_6 := float(within_6) / float(TRIALS)
	print("  empirical: %d trials of %d days at x=3, luck 10" % [TRIALS, DAYS_PER_TRIAL])
	print("    first storm on day 1..6: %s" % str(by_day))
	print("    P(within 5) = %.4f (%d/%d)" % [rate_5, within_5, TRIALS])
	print("    P(within 6) = %.4f (%d/%d)" % [rate_6, within_6, TRIALS])
	_check(rate_5 >= MIN_5_DAY_PROBABILITY,
		"empirical P(storm within 5 days) ≥ 0.96 (got %.4f)" % rate_5)
	_check(rate_6 >= MIN_6_DAY_PROBABILITY,
		"empirical P(storm within 6 days) ≥ 0.98 (got %.4f)" % rate_6)
	_check(absf(rate_6 - six) <= FREQUENCY_TOLERANCE,
		"empirical 6-day rate tracks the closed form 0.9819 (±0.02, got %.4f)" % rate_6)

	# 3. Through the production path (real ledger days, storm damage included):
	#    a caravel survives 6 storm days (6 × 5 = 30 < 90), so the day loop can
	#    run to completion and the milestone still lands.
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_make_run("fair", ATLANTIC_CELL, 10)
	var production_hit := false
	for day in DAYS_PER_TRIAL:
		_one_day()
		if SailingSimLib.last_day_storm:
			production_hit = true
			break
	_check(production_hit,
		"the production ledger path reaches a storm within 6 days at x≤6 "
		+ "(damage applied along the way, durability %d)"
		% int(GameState.fleet[0]["durability"]))


# --- Determinism ----------------------------------------------------------

func _test_determinism() -> void:
	_make_run("fair", ATLANTIC_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var first: Array[String] = []
	for day in 50:
		first.append(SailingSimLib.roll_weather(ATLANTIC_CELL))
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var second: Array[String] = []
	for day in 50:
		second.append(SailingSimLib.roll_weather(ATLANTIC_CELL))
	_check(first == second, "same seed → identical 50-roll weather sequence")

	SailingSimLib.set_weather_seed(WEATHER_SEED + 1)
	var third: Array[String] = []
	for day in 50:
		third.append(SailingSimLib.roll_weather(ATLANTIC_CELL))
	_check(first != third, "a different seed produces a different sequence")

	# Determinism also holds through the ledger (the roll is the only RNG use
	# in step 3, and step 1/2 are deterministic).
	_make_run("fair", ATLANTIC_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var ledger_a: Array[String] = []
	for day in 10:
		_one_day()
		ledger_a.append(str(GameState.world["weather"]))
	_make_run("fair", ATLANTIC_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var ledger_b: Array[String] = []
	for day in 10:
		_one_day()
		ledger_b.append(str(GameState.world["weather"]))
	_check(ledger_a == ledger_b,
		"same seed → identical ledger weather sequence (%s)" % str(ledger_a))


# --- §4.5 order: weather is step 3, after consumption and wages ----------

func _test_ledger_order_weather() -> void:
	# A storm day still eats (step 1) and pays (step 2) first, then rolls.
	# The observed ledger effects are independent of the roll outcome, which is
	# what "step 3 runs after 1–2" means for T8's observable contract.
	_make_run("fair", ATLANTIC_CELL, 10)
	GameState.morale = 70
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var provisions_before := FleetLib.supplies("provisions")
	var gold_before := GameState.gold
	_one_day()
	_check(FleetLib.supplies("provisions") == provisions_before - 3,
		"step 1 still eats on a day whose step 3 rolled '%s' (%d → %d)" % [
			str(GameState.world["weather"]),
			provisions_before,
			FleetLib.supplies("provisions"),
		])
	_check(GameState.gold == gold_before - 30,
		"step 2 still pays wages before the roll (%d → %d)"
		% [gold_before, GameState.gold])
	_check(str(GameState.world["weather"]) in SailingSimLib.WEATHER_OUTCOMES,
		"step 3 wrote world.weather inside the same tick (%s)"
		% str(GameState.world["weather"]))

	# Roll for the *coming* day: the value the HUD shows at `day_advanced` is
	# the one step 3 just wrote, and it is what `effective_speed` then uses.
	if str(GameState.world["weather"]) == "storm":
		_check(SailingSimLib.wind_factor("storm", "sail") == 1.5,
			"a storm day feeds wind_factor 1.5 into the next movement")
	_check(not SailingSimLib.last_day_shortfalls["provisions"],
		"a well-supplied storm day records no shortfall")


# --- docs/80-* §4.5: HUD label under the minimap, signal-only -------------

func _test_hud_weather() -> void:
	_make_run("fair", ATLANTIC_CELL, 10)

	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)

	var weather_label: Label = hud.get_node("Weather")
	var minimap: Control = hud.get_node("Minimap")
	_check(weather_label.text == I18n.t_key("world.weather.fair"),
		"weather label renders the current weather on open (%s)" % weather_label.text)
	_check(weather_label.position.y > minimap.position.y + minimap.size.y - 1.0,
		"weather label sits under the minimap (label y %.0f, minimap bottom %.0f)" % [
			weather_label.position.y, minimap.position.y + minimap.size.y
		])

	# Change GameState without emitting → the label must not move (no polling).
	GameState.world["weather"] = "strong"
	_check(hud.displayed_weather_key() == "fair"
		and weather_label.text == I18n.t_key("world.weather.fair"),
		"HUD does not poll GameState.world.weather (still %s)" % weather_label.text)

	# Emit day_advanced → the label follows.
	EventBus.day_advanced.emit(GameState.day)
	_check(hud.displayed_weather_key() == "strong"
		and weather_label.text == I18n.t_key("world.weather.strong"),
		"HUD weather label follows day_advanced (%s)" % weather_label.text)
	_check(not hud.is_storm_flashing(),
		"a strong-wind day does not flash")

	# Storm: warning colour + the 0.5s flash cycle.
	GameState.world["weather"] = "storm"
	EventBus.day_advanced.emit(GameState.day)
	_check(weather_label.text == I18n.t_key("world.weather.storm"),
		"storm renders the world.weather.storm string (%s)" % weather_label.text)
	_check(weather_label.get_theme_color("font_color") == PaletteLib.BAD,
		"the storm glyph is warning-coloured")
	_check(hud.is_storm_flashing(), "the storm glyph starts flashing")
	_check(is_equal_approx(HudLib.STORM_FLASH_CYCLE_SECONDS, 0.5),
		"the flash cycle is exactly 0.5s (got %.2fs)" % HudLib.STORM_FLASH_CYCLE_SECONDS)
	_check(is_equal_approx(HudLib.STORM_FLASH_HALF_SECONDS, 0.25),
		"…i.e. 0.25s out + 0.25s in (got %.2fs)" % HudLib.STORM_FLASH_HALF_SECONDS)

	# Back to calm: flash stops and alpha is restored.
	GameState.world["weather"] = "calm"
	EventBus.day_advanced.emit(GameState.day)
	_check(not hud.is_storm_flashing() and is_equal_approx(weather_label.modulate.a, 1.0),
		"leaving storm kills the tween and restores full alpha")

	# Locale rebind: both weather strings come from ui_strings (zh + en).
	I18n.set_locale("zh")
	_check(weather_label.text == I18n.t_key("world.weather.calm")
		and weather_label.text == "无风",
		"weather label rebinds on locale_changed (%s)" % weather_label.text)
	I18n.set_locale("en")
	_check(weather_label.text == "Calm",
		"…and back to English (%s)" % weather_label.text)

	# The four keys exist in both locales (validator's rule, asserted here so a
	# future data edit cannot silently drop one).
	for weather in SailingSimLib.WEATHER_OUTCOMES:
		var key := "world.weather.%s" % weather
		var entry: Dictionary = DataLoader.ui_strings.get(key, {})
		_check(not str(entry.get("zh", "")).is_empty()
			and not str(entry.get("en", "")).is_empty(),
			"%s exists with both locales (%s / %s)" % [
				key, str(entry.get("zh", "")), str(entry.get("en", ""))
			])

	host.queue_free()


# --- Harness --------------------------------------------------------------

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
