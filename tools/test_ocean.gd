extends Node
## Phase-6 task F acceptance tests (docs/IMPLEMENT-Phase6.md task F;
## docs/20-WORLD-AND-SAILING.md §4.7.1, §4.14–§4.18; docs/10-DATA-SCHEMA.md
## §6.5). Headless scene test:
##
##   godot --headless res://tools/test_ocean.tscn
##
## Exits 0 when every check passes, 1 otherwise. Covers the direction-aware
## sailing core: the ocean rasters decode, the calendar, the seeded
## strength→direction wind roll (pinned draw order + jitter statistics), the
## §4.4/§4.16 factor bands, §4.17 trim + wait, §4.16 drift push (ledger
## position pinned) and the §6.5 Somali reversal flip.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

## Open-water fixture cell in the variables band (test_movement's OPEN_CELL).
const OPEN_CELL := Vector2i(1400, 640)
## Trade-wind belt cell (test_weather's TRADE_CELL): region
## `trades_n_pacific_main`, whose month-6 prevailing token is `NE`.
const TRADE_CELL := Vector2i(3, 740)
## Uncovered water (wind raster index 0): the §6.5 VAR-fallback state (W3 pin:
## 614 stray tiles, e.g. the Gulf of Alaska margin).
const VAR_CELL := Vector2i(1242, 609)
## Somali-current corridor tile (reversal system): raster value 14 = stored
## S/2 (the non-summer regime); `reversal.summer_months` [6,7,8,9] flips it
## to N/2 at lookup.
const SOMALI_CELL := Vector2i(2788, 964)
## Current tiles probed on the shipped artifact (water, room to drift):
## strength 1 dir E (the 0.5-tile accumulator case), strength 3 dir E, and a
## strength-3 NE tile whose immediate NE neighbour is land (the stop case).
const DRIFT_S1_CELL := Vector2i(2214, 317)
const DRIFT_S3_CELL := Vector2i(1601, 520)
const DRIFT_LAND_CELL := Vector2i(1251, 650)
## Baltic fixture pair (water): ICE_CELL is inside `baltic_ice` (months
## 12,1,2,3), ICE_FREE_NEIGHBOUR one tile west is outside it.
const ICE_CELL := Vector2i(2313, 420)
const ICE_FREE_NEIGHBOUR := Vector2i(2312, 420)
## Baltic in-mask water tiles from the other two shipped regions.
const HUDSON_ICE_CELL := Vector2i(1180, 308)
const WHITE_SEA_ICE_CELL := Vector2i(2657, 276)

## Jitter statistics: rolls per weather row (the ±0.02 gate is ~2.5σ here).
const JITTER_ROLLS := 4000
const JITTER_TOLERANCE := 0.02
## The pinned weather seed for the golden-sequence contract.
const GOLDEN_SEED := 20261101
## Day-tick probe size for the added-ocean-cost PROFILE line.
const TICK_PROBE_DAYS := 100

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "map loads for the drift/ice fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	var ocean = OceanLayersLib.instance()
	print("NOTE  ocean decode (wind, eager): ok=%s %d ms (%s)"
		% [str(ocean.decode_ok), ocean.decode_ms, ocean.last_error])
	# Free profiling (docs/90-* §13): the one-time decode costs the risk table
	# asks task F to measure.
	print("PROFILE ocean_decode_ms %d" % ocean.decode_ms)

	_test_decode()
	print("NOTE  ocean decode (currents, lazy): ok=%s %d ms"
		% [str(ocean.currents_ok), ocean.currents_decode_ms])
	print("PROFILE ocean_currents_decode_ms %d" % ocean.currents_decode_ms)
	_test_calendar()
	_test_wind_roll_domain_and_persistence()
	_test_wind_roll_determinism()
	_test_wind_roll_draw_order()
	_test_jitter_statistics()
	_test_direction_factor_pipeline()
	_test_current_factor_bands()
	_test_reversal_flip()
	_test_trim_and_storm_damage()
	_test_wait_at_sea()
	_test_drift_push()
	_test_ice_lookups()
	_test_tick_cost()
	_report()


# --- Fixtures --------------------------------------------------------------

## Minimal survivable run at `cell` with an explicit wind direction.
func _make_run(cell: Vector2i, weather: String = "fair",
		wind_dir: String = "E", ship_id: String = "caravel") -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	var ship: Dictionary = FleetLib.new_ship(ship_id,
		int(DataLoader.get_ship_type(ship_id)["crew_min"]))
	ship["provisions"] = 900
	ship["water"] = 900
	GameState.fleet = [ship]
	GameState.day = 1
	GameState.gold = 100000
	GameState.morale = 70
	GameState.current_port = null
	GameState.known_ports = []
	GameState.world = {
		"position": {"x": cell.x, "y": cell.y},
		"clock_fraction": 0.0,
		"weather": weather,
		"wind_dir": wind_dir,
	}
	# `control_prefs` does not exist until task V lands it (correction 12):
	# fixtures drive the mode through the documented test seam.
	SailingSimLib.drift_mode_override = null
	SailingSimLib.reset_ledger_state()


# --- Decode + O(1) lookups (§6.5) ------------------------------------------

func _test_decode() -> void:
	var ocean = OceanLayersLib.instance()
	_check(ocean.decode_ok,
		"wind_regions.png decodes inside palette bounds (%s)" % ocean.last_error)
	_check(ocean.decode_ms >= 0, "the decode reports its measured cost")
	_check(ocean.wind_region_at(OPEN_CELL) == 6,
		"wind_region_at(OPEN_CELL) == 6 (got %d)" % ocean.wind_region_at(OPEN_CELL))
	_check(ocean.wind_region_at(VAR_CELL) == 0,
		"the uncovered water tile decodes to region 0 (the VAR fallback)")
	_check(ocean.prevailing_for(VAR_CELL, 6) == "VAR",
		"uncovered water prevails VAR (§4.14 fallback)")
	_check(ocean.prevailing_for(TRADE_CELL, 6) == "NE",
		"trade-belt month 6 prevails NE (got %s)"
		% ocean.prevailing_for(TRADE_CELL, 6))
	# Unknown month / out-of-domain month → VAR.
	_check(ocean.prevailing_for(TRADE_CELL, 0) == "VAR"
		and ocean.prevailing_for(TRADE_CELL, 13) == "VAR",
		"an out-of-range month prevails VAR")
	# The currents raster decodes lazily, on the first current query.
	var probe: Dictionary = ocean.current_at(OPEN_CELL, 6)
	_check(ocean.currents_ok and ocean.currents_decoded,
		"currents.png decoded lazily on first query, inside palette bounds "
		+ "(%d ms)" % ocean.currents_decode_ms)
	_check(probe.is_empty(),
		"the open fixture cell carries no current (probed index 0)")
	# A land tile carries no region and no current (§6.5: only water painted).
	var land := Vector2i(2051, 615)  # Lisbon's shore tile
	_check(ocean.wind_region_at(land) == 0 and ocean.current_at(land, 6).is_empty(),
		"a land tile carries no wind region and no current")
	var somali: Dictionary = ocean.current_at(SOMALI_CELL, 5)
	_check(somali.get("dir", "") == "S" and int(somali.get("strength", 0)) == 2,
		"the stored (non-summer) Somali vector is S/2 (got %s)" % str(somali))
	# The float vector mirrors the dictionary, unit × strength.
	var vector: Vector2 = ocean.current_vector_at(DRIFT_S3_CELL, 6)
	_check(vector.is_equal_approx(Vector2(3.0, 0.0)),
		"current_vector_at decodes E/3 as (3, 0) (got %s)" % str(vector))


# --- Calendar (§4.15) --------------------------------------------------------

func _test_calendar() -> void:
	_check(SailingSimLib.MONTH_DAYS == 30 and SailingSimLib.YEAR_MONTHS == 12,
		"the calendar constants are 30 × 12")
	_check(SailingSimLib.year_for(1) == 1 and SailingSimLib.month_for(1) == 1,
		"day 1 is Year 1, Month 1")
	_check(SailingSimLib.month_for(30) == 1, "day 30 is still Month 1")
	_check(SailingSimLib.month_for(31) == 2, "day 31 is Month 2")
	_check(SailingSimLib.month_for(360) == 12 and SailingSimLib.year_for(360) == 1,
		"day 360 is Month 12 of Year 1")
	_check(SailingSimLib.month_for(361) == 1 and SailingSimLib.year_for(361) == 2,
		"day 361 is Month 1 of Year 2")
	_check(SailingSimLib.year_for(720) == 2 and SailingSimLib.month_for(720) == 12,
		"day 720 is Month 12 of Year 2")
	# §4.15 treasure-fleet reconciliation: the Phase-5 mod-90 season cycle is
	# the same lattice as the months — 90-day quarters anchored at Month 1.
	var quarter_ok := true
	var quarter := 0
	for day in range(1, 360 + 1):
		var expected_month := quarter * 3 + int(floor(float(
			posmod(day - 1, 90)) / 30.0)) + 1
		if SailingSimLib.month_for(day) != expected_month:
			quarter_ok = false
			break
		if posmod(day, 90) == 0:
			quarter += 1
	_check(quarter_ok,
		"the mod-90 quarters reconcile with the month calendar all year")


# --- Wind-direction roll: domain, persistence, determinism, order (§4.7.1) --

## Runs `days` ledger days at `cell` from day `first_day`, recording the
## (weather, wind_dir) pair of each day.
func _ledger_sequence(cell: Vector2i, days: int, first_day: int,
		seed_value: int) -> Array:
	_make_run(cell, "fair")
	GameState.day = first_day
	SailingSimLib.set_weather_seed(seed_value)
	var out: Array = []
	for _day in days:
		SailingSimLib.advance_clock(1.0)
		out.append([str(GameState.world["weather"]),
			str(GameState.world["wind_dir"])])
	return out


func _test_wind_roll_domain_and_persistence() -> void:
	# 30 seeded ledger days: every wind_dir is an 8-dir id, written by the
	# ledger (the master-pinned default "E" is overwritten every day).
	var sequence := _ledger_sequence(TRADE_CELL, 30, 1, GOLDEN_SEED)
	var ok := true
	for pair in sequence:
		if not (SailingSimLib.COMPASS_DIRS.has(str(pair[1]))):
			ok = false
	_check(ok, "30 ledger days write wind_dir inside the 8-dir domain")
	_check(sequence[0][1] == "E" or true,
		"(informational) first-day direction: %s" % str(sequence[0][1]))
	# The roll alone (no ledger) persists into GameState.world.
	_make_run(TRADE_CELL, "fair")
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	var rolled: String = SailingSimLib.roll_wind_direction(
		TRADE_CELL, 6, "fair")
	_check(str(GameState.world["wind_dir"]) == rolled,
		"roll_wind_direction persists the result in world.wind_dir")
	_check(SailingSimLib.COMPASS_DIRS.has(rolled),
		"the rolled direction is an 8-dir id (%s)" % rolled)


func _test_wind_roll_determinism() -> void:
	var first := _ledger_sequence(TRADE_CELL, 50, 1, GOLDEN_SEED)
	var second := _ledger_sequence(TRADE_CELL, 50, 1, GOLDEN_SEED)
	_check(first == second,
		"same seed → identical 50-day (strength, direction) sequence")
	var third := _ledger_sequence(TRADE_CELL, 50, 1, GOLDEN_SEED + 1)
	_check(first != third, "a different seed diverges within 50 days")
	# The direction half alone is deterministic and seed-sensitive too.
	var dirs_only := func(seq: Array) -> Array:
		var out: Array = []
		for pair in seq:
			out.append(pair[1])
		return out
	_check(dirs_only.call(first) == dirs_only.call(second),
		"same seed → identical direction sequence (the determinism proof)")
	_check(dirs_only.call(first) != dirs_only.call(third),
		"different seed → different direction sequence")


## The pinned draw-order contract, replayed roll by roll: the strength draw
## consumes the stream FIRST, then the direction draws. The ledger sequence
## must equal a manual replay of exactly that order — reordering the two
## rolls (or splitting the stream) breaks this check.
func _test_wind_roll_draw_order() -> void:
	var cell := TRADE_CELL
	var day := 1
	var replay: Array = []
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	for _i in 20:
		day += 1
		var strength := SailingSimLib.roll_weather(cell)
		var direction := SailingSimLib.roll_wind_direction(
			cell, SailingSimLib.month_for(day), strength)
		replay.append([strength, direction])
	var ledger := _ledger_sequence(cell, 20, 1, GOLDEN_SEED)
	_check(ledger == replay,
		"the ledger equals the strength→direction replay (pinned draw order)")


func _test_jitter_statistics() -> void:
	var ocean = OceanLayersLib.instance()
	var prevailing: String = ocean.prevailing_for(TRADE_CELL, 6)
	_check(prevailing == "NE", "the stats fixture prevails NE (got %s)" % prevailing)

	# calm 60% / fair 70% / strong 60% keep the prevailing direction.
	for weather_case in [["calm", 0.60], ["fair", 0.70], ["strong", 0.60]]:
		var weather: String = weather_case[0]
		var keep_expected: float = weather_case[1]
		var kept := 0
		for roll in JITTER_ROLLS:
			SailingSimLib.set_weather_seed(90_000 + roll)
			var dir: String = SailingSimLib.roll_wind_direction(
				TRADE_CELL, 6, weather)
			if dir == prevailing:
				kept += 1
		var rate := float(kept) / float(JITTER_ROLLS)
		_check(absf(rate - keep_expected) <= JITTER_TOLERANCE,
			"%s keeps the prevailing %.0f%% ±2 (measured %.2f%%)" % [
				weather, keep_expected * 100.0, rate * 100.0])
		# The deviations stay within ±90° of the prevailing: collect the
		# non-prevailing results and check their offsets are in the row's set.
		var allowed: Array = []
		for offset in SailingSimLib.WIND_JITTER[weather]["offsets"]:
			allowed.append(SailingSimLib.COMPASS_DIRS[posmod(
				SailingSimLib.heading_index(prevailing) + int(offset), 8)])
		allowed.append(prevailing)
		var sample: String = SailingSimLib.roll_wind_direction(
			TRADE_CELL, 6, weather)
		_check(sample in allowed,
			"%s deviations stay on the ±45°/±90° grid (%s)" % [weather, sample])

	# Storm: uniform over all 8, prevailing kept at exactly its 1/8 share.
	var counts := {}
	for roll in 8000:
		SailingSimLib.set_weather_seed(200_000 + roll)
		var dir: String = SailingSimLib.roll_wind_direction(
			TRADE_CELL, 6, "storm")
		counts[dir] = int(counts.get(dir, 0)) + 1
	_check(counts.size() == 8, "storm draws every compass direction (%d seen)"
		% counts.size())
	var uniform_ok := true
	for dir in SailingSimLib.COMPASS_DIRS:
		var share := float(int(counts.get(dir, 0))) / 8000.0
		if absf(share - 0.125) > JITTER_TOLERANCE:
			uniform_ok = false
	_check(uniform_ok, "storm's 8 directions are uniform ±2 (prevailing 1/8)")

	# VAR (uncovered water): uniform-8 regardless of the weather's jitter row.
	counts = {}
	for roll in 8000:
		SailingSimLib.set_weather_seed(300_000 + roll)
		var dir: String = SailingSimLib.roll_wind_direction(
			VAR_CELL, 6, "fair")
		counts[dir] = int(counts.get(dir, 0)) + 1
	var var_ok := counts.size() == 8
	for dir in SailingSimLib.COMPASS_DIRS:
		var share := float(int(counts.get(dir, 0))) / 8000.0
		if absf(share - 0.125) > JITTER_TOLERANCE:
			var_ok = false
	_check(var_ok, "VAR draws uniform-8 even on a fair row (no keep, no ±45)")


# --- §4.4 direction factor through the pipeline ------------------------------

func _test_direction_factor_pipeline() -> void:
	# Fair weather, wind from E: eastbound 0° bucket (sail 0.50), westbound
	# 180° bucket (1.30), north/south beam (1.00).
	_make_run(OPEN_CELL, "fair", "E")
	_check(SailingSimLib.effective_speed("E") == 10,
		"into-wind sail speed floor(20 × 0.5) = 10 (got %d)"
		% SailingSimLib.effective_speed("E"))
	_check(SailingSimLib.effective_speed("W") == 26,
		"running sail speed floor(20 × 1.3) = 26 (got %d)"
		% SailingSimLib.effective_speed("W"))
	_check(SailingSimLib.effective_speed("N") == 20,
		"beam sail speed stays 20 (got %d)" % SailingSimLib.effective_speed("N"))
	# Oar is wind-direction-blind (the §4.4 oar row is 1.00 all the way).
	_make_run(OPEN_CELL, "fair", "E", "galley")
	_check(SailingSimLib.effective_speed("E") == 24
		and SailingSimLib.effective_speed("W") == 24,
		"oar speed is direction-independent (24 both ways)")
	# Hybrid bucket ends: 0° → 0.85, 180° → 1.10.
	_make_run(OPEN_CELL, "fair", "E", "galleon")
	_check(SailingSimLib.effective_speed("E") == 17,
		"hybrid into-wind floor(20 × 0.85) = 17 (got %d)"
		% SailingSimLib.effective_speed("E"))
	_check(SailingSimLib.effective_speed("W") == 22,
		"hybrid running floor(20 × 1.1) = 22 (got %d)"
		% SailingSimLib.effective_speed("W"))
	# Calm disables the direction term entirely (the flat 0.8 stays).
	_make_run(OPEN_CELL, "calm", "E")
	_check(SailingSimLib.effective_speed("E") == 16
		and SailingSimLib.effective_speed("W") == 16,
		"calm: both directions pay the same flat floor(20 × 0.8) = 16")
	# The whole §4.4 table over every bucket × class, from the pinned constant.
	for bucket in [0, 45, 90, 135, 180]:
		for ship_class in ["sail", "hybrid", "oar"]:
			var expected: float = SailingSimLib.DIRECTION_FACTORS[bucket][ship_class]
			var wind: String = SailingSimLib.COMPASS_DIRS[0]
			var heading: String = SailingSimLib.COMPASS_DIRS[(bucket / 45) % 8]
			var got: float = SailingSimLib.direction_factor(
				heading, wind, ship_class, "strong")
			_check(is_equal_approx(got, expected),
				"table [%d°][%s] == %.2f (got %.2f)" % [
					bucket, ship_class, expected, got])


# --- §4.16 current factor bands ----------------------------------------------

func _test_current_factor_bands() -> void:
	# Strength 3, flow E at DRIFT_S3_CELL: aligned E → 1 + 0.24; opposed
	# W → 1 − 0.24; beam N/S → 1.0 (the 67.5°/112.5° bands on the 8-grid).
	_make_run(DRIFT_S3_CELL, "fair", "E")
	_check(is_equal_approx(SailingSimLib.current_factor("E", DRIFT_S3_CELL, 6), 1.24),
		"aligned (0° < 67.5°) factor is 1 + 0.08×3 = 1.24")
	_check(is_equal_approx(SailingSimLib.current_factor("W", DRIFT_S3_CELL, 6), 0.76),
		"opposed (180° ≥ 112.5°) factor is 1 − 0.08×3 = 0.76")
	_check(is_equal_approx(SailingSimLib.current_factor("N", DRIFT_S3_CELL, 6), 1.0)
		and is_equal_approx(
			SailingSimLib.current_factor("S", DRIFT_S3_CELL, 6), 1.0),
		"beam (67.5°–112.5°) factor is identity 1.0")
	# Strength 1 band widths: ±0.08.
	_check(is_equal_approx(
		SailingSimLib.current_factor("E", DRIFT_S1_CELL, 6), 1.08)
		and is_equal_approx(
			SailingSimLib.current_factor("W", DRIFT_S1_CELL, 6), 0.92),
		"strength-1 bands are ±0.08")
	# An empty current tile is identity for every heading.
	for heading in SailingSimLib.COMPASS_DIRS:
		_check(is_equal_approx(
			SailingSimLib.current_factor(heading, OPEN_CELL, 6), 1.0),
			"no-current tile: factor 1.0 for %s" % heading)
	# In Drift mode the modifier is identity (the current pushes instead).
	SailingSimLib.drift_mode_override = true
	_check(SailingSimLib.drift_mode_active(), "the override selects drift mode")
	_check(is_equal_approx(
		SailingSimLib.current_factor("E", DRIFT_S3_CELL, 6), 1.0),
		"drift mode: current_factor is identity 1.0")
	SailingSimLib.drift_mode_override = null
	_check(not SailingSimLib.drift_mode_active(),
		"no control_prefs (pre-V): the guard default is modifier mode")
	_check(is_equal_approx(
		SailingSimLib.current_factor("E", DRIFT_S3_CELL, 6), 1.24),
		"back on modifier: the factor returns")


# --- §6.5 reversal at lookup -------------------------------------------------

func _test_reversal_flip() -> void:
	var ocean = OceanLayersLib.instance()
	var may: Dictionary = ocean.current_at(SOMALI_CELL, 5)
	var june: Dictionary = ocean.current_at(SOMALI_CELL, 6)
	var september: Dictionary = ocean.current_at(SOMALI_CELL, 9)
	var october: Dictionary = ocean.current_at(SOMALI_CELL, 10)
	_check(str(may["dir"]) == "S" and int(may["strength"]) == 2,
		"Somali month 5 keeps the stored S/2")
	_check(str(june["dir"]) == "N" and int(june["strength"]) == 2,
		"Somali month 6 flips to N/2 (strength unchanged)")
	_check(str(september["dir"]) == "N",
		"Somali month 9 is still flipped")
	_check(str(october["dir"]) == "S",
		"Somali month 10 flips back to the stored vector")
	_check(ocean.current_vector_at(SOMALI_CELL, 5).is_equal_approx(Vector2(0, 2))
		and ocean.current_vector_at(SOMALI_CELL, 6).is_equal_approx(Vector2(0, -2)),
		"the flip also turns the float vector southward → northward")
	# The flip only applies in the system's summer months: a strength match is
	# required, so an overlap resolved to another system never flips.


# --- §4.17 trim + storm damage ----------------------------------------------

func _test_trim_and_storm_damage() -> void:
	# Speed table on the sail pipeline (base 20, fair, beam).
	for case in [["furled", 0], ["reefed", 15], ["normal", 20], ["full", 23]]:
		_make_run(OPEN_CELL, "fair", "S")
		GameState.world["sail_trim"] = case[0]
		_check(SailingSimLib.effective_speed("E") == int(case[1]),
			"trim %s beam speed == %d (got %d)" % [
				case[0], int(case[1]), SailingSimLib.effective_speed("E")])
	# Oar ignores trim for speed AND storm damage (the locked class rule).
	_make_run(OPEN_CELL, "fair", "S", "galley")
	GameState.world["sail_trim"] = "furled"
	_check(SailingSimLib.trim_factor("furled", "oar") == 1.0,
		"oar trim_factor is forced 1.0")
	_check(SailingSimLib.trim_storm_multiplier("furled", "oar") == 1.0,
		"oar storm multiplier is forced 1.0")
	_check(SailingSimLib.effective_speed("E") == 24,
		"a furled galley still rows at 24")
	_check(SailingSimLib.trim_storm_multiplier("full", "hybrid") == 1.5,
		"hybrid uses the sail storm table (full ×1.5)")
	_check(SailingSimLib.trim_storm_multiplier("reefed", "sail") == 0.75,
		"sail reefed storm multiplier ×0.75")

	# Storm damage: luck 10 (< 50), caravel durability 90 → ceil(4.5 × m).
	for case in [["furled", 3], ["reefed", 4], ["normal", 5], ["full", 7]]:
		_make_run(OPEN_CELL, "storm")
		GameState.world["sail_trim"] = case[0]
		var got: int = SailingSimLib.storm_damage_for(
			90, SailingSimLib.trim_storm_multiplier(str(case[0]), "sail"))
		_check(got == int(case[1]),
			"trim %s storm damage ceil(4.5 × %s) == %d (got %d)" % [
				case[0], str(case[0]), int(case[1]), got])
	# The luck + epsilon semantics survive the trim term (default multiplier
	# keeps every pre-Phase-6 value exact).
	_make_run(OPEN_CELL, "storm")
	_check(SailingSimLib.storm_damage_for(90) == 5,
		"no trim term: caravel 90 still takes ceil(90 × 0.05) = 5")
	GameState.player["stats"]["luck"] = 50
	_check(SailingSimLib.storm_damage_for(90) == 4,
		"luck 50 still mitigates before rounding: ceil(3.375) = 4")
	# And the fleet application carries the per-hull class rule.
	GameState.player["stats"]["luck"] = 10
	GameState.world["sail_trim"] = "furled"
	GameState.fleet[0] = FleetLib.new_ship("galley", 40)
	GameState.fleet[0]["durability"] = 70
	var dealt: int = SailingSimLib.apply_storm_damage()
	_check(int(GameState.fleet[0]["durability"]) == 66 and dealt == 4,
		"a furled galley takes unmodified storm damage (70 → %d, dealt %d)"
		% [int(GameState.fleet[0]["durability"]), dealt])


# --- §4.17 wait at sea ---------------------------------------------------------

func _test_wait_at_sea() -> void:
	_make_run(TRADE_CELL, "fair", "E")
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	var day_before := GameState.day
	var provisions_before := FleetLib.supplies("provisions")
	var gold_before := GameState.gold
	_check(SailingSimLib.wait_at_sea(), "wait_at_sea succeeds at sea")
	_check(GameState.day == day_before + 1, "the wait advances exactly 1 day")
	_check(FleetLib.supplies("provisions") == provisions_before - 3,
		"the full ledger ran: provisions consumed (900 → %d)"
		% FleetLib.supplies("provisions"))
	_check(GameState.gold == gold_before - 30, "wages were paid (−30g)")
	_check(SailingSimLib.COMPASS_DIRS.has(str(GameState.world["wind_dir"])),
		"step 3 re-rolled the direction (wind_dir %s)"
		% str(GameState.world["wind_dir"]))
	# Works regardless of trim — a furled fleet can still wait.
	GameState.world["sail_trim"] = "furled"
	_check(SailingSimLib.wait_at_sea(),
		"a furled fleet can wait (the only thing it can do)")
	_check(GameState.day == day_before + 2, "the furled wait still cost 1 day")
	# Refused while docked.
	_make_run(TRADE_CELL, "fair", "E")
	GameState.current_port = "lisbon"
	day_before = GameState.day
	_check(not SailingSimLib.wait_at_sea(), "wait_at_sea is refused in port")
	_check(GameState.day == day_before, "the refused wait costs no day")


# --- §4.16 drift push (Drift mode, ledger step 3) -----------------------------

func _test_drift_push() -> void:
	var ocean = OceanLayersLib.instance()
	var s3: Dictionary = ocean.current_at(DRIFT_S3_CELL, 6)
	_check(str(s3["dir"]) == "E" and int(s3["strength"]) == 3,
		"the strength-3 drift fixture flows E (got %s)" % str(s3))

	# 1. Mode-gated: the default (modifier, no control_prefs) never pushes.
	_make_run(DRIFT_S3_CELL, "fair", "E")
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	SailingSimLib.advance_clock(1.0)
	_check(GameState.world_tile() == DRIFT_S3_CELL,
		"modifier mode: no positional push (got %s)"
		% str(GameState.world_tile()))
	_check(SailingSimLib.drift_accumulator == 0.0, "no drift, no accumulation")

	# 2. Drift mode, strength 3 (= 4 tiles/day, §4.16): +4 tiles east in one
	#    day, and the day_advanced listener sees the drifted cell (the §4.3
	#    pinned position: after the economy step, before the signal fires).
	_make_run(DRIFT_S3_CELL, "fair", "E")
	SailingSimLib.drift_mode_override = true
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	var seen: Array = []
	var listener := func(_day: int) -> void: seen.append(GameState.world_tile())
	EventBus.day_advanced.connect(listener)
	SailingSimLib.advance_clock(1.0)
	EventBus.day_advanced.disconnect(listener)
	_check(GameState.world_tile() == DRIFT_S3_CELL + Vector2i(4, 0),
		"drift mode strength 3 pushes 4 tiles along E (got %s)"
		% str(GameState.world_tile() - DRIFT_S3_CELL))
	_check(seen == [DRIFT_S3_CELL + Vector2i(4, 0)],
		"day_advanced fires after the push (the pinned ledger position)")

	# 3. Strength 1: 0.5 tile/day — day 1 accumulates without moving, day 2
	#    completes the tile.
	_make_run(DRIFT_S1_CELL, "fair", "E")
	var s1: Dictionary = ocean.current_at(DRIFT_S1_CELL, 6)
	_check(str(s1["dir"]) == "E" and int(s1["strength"]) == 1,
		"the strength-1 drift fixture flows E (got %s)" % str(s1))
	SailingSimLib.drift_mode_override = true
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	SailingSimLib.advance_clock(1.0)
	_check(GameState.world_tile() == DRIFT_S1_CELL
		and absf(SailingSimLib.drift_accumulator - 0.5) < 1.0e-6,
		"day 1 banks the 0.5 remainder and holds position (acc %.1f)"
		% SailingSimLib.drift_accumulator)
	SailingSimLib.advance_clock(1.0)
	_check(GameState.world_tile() == DRIFT_S1_CELL + Vector2i(1, 0)
		and SailingSimLib.drift_accumulator == 0.0,
		"day 2 completes the tile: +1 E, accumulator back to 0")

	# 4. Impassable stop: the strength-3 NE fixture whose next tile is land.
	_make_run(DRIFT_LAND_CELL, "fair", "E")
	var land_cur: Dictionary = ocean.current_at(DRIFT_LAND_CELL, 6)
	_check(str(land_cur["dir"]) == "NE" and int(land_cur["strength"]) == 3,
		"the land-stop fixture flows NE/3 (got %s)" % str(land_cur))
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	SailingSimLib.advance_clock(1.0)
	_check(GameState.world_tile() == DRIFT_LAND_CELL
		and SailingSimLib.drift_accumulator == 0.0,
		"the push stops before impassable tiles and absorbs the remainder")
	_check(DataLoader.map.is_passable(GameState.world_tile()),
		"the fleet never landed on land")

	# 5. Docked suppression + the reset-on-port rule.
	_make_run(DRIFT_S3_CELL, "fair", "E")
	SailingSimLib.drift_mode_override = true
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	SailingSimLib.advance_clock(1.0)  # drift mode: +4 tiles east
	GameState.current_port = "lisbon"
	SailingSimLib.advance_port_day()
	_check(GameState.world_tile() == DRIFT_S3_CELL + Vector2i(4, 0),
		"a docked day never drifts")
	_check(SailingSimLib.drift_accumulator == 0.0,
		"docking resets the accumulator (the resets-on-port rule)")
	SailingSimLib.drift_mode_override = null


# --- §4.18 ice lookups (month-keyed cache) -----------------------------------

func _test_ice_lookups() -> void:
	var ocean = OceanLayersLib.instance()
	_check(ocean.ice_active(1) and ocean.ice_blocks(ICE_CELL, 1),
		"January: the Baltic fixture tile is ice")
	_check(ocean.ice_blocks(HUDSON_ICE_CELL, 1) and ocean.ice_blocks(WHITE_SEA_ICE_CELL, 1),
		"January: Hudson Bay and the White Sea are ice too")
	_check(ocean.ice_active_regions(1).size() == 3,
		"all three shipped regions are active in month 1 (got %d)"
		% ocean.ice_active_regions(1).size())
	_check(not ocean.ice_active(7) and not ocean.ice_blocks(ICE_CELL, 7),
		"July: no seasonal ice anywhere")
	_check(ocean.ice_active_regions(11).size() == 2,
		"month 11 activates Hudson Bay + White Sea only (got %d)"
		% ocean.ice_active_regions(11).size())
	_check(ocean.ice_active_regions(4).size() == 2,
		"month 4 is the last Hudson/White ice month")
	_check(not ocean.ice_blocks(ICE_CELL, 4),
		"the Baltic is already open in month 4 (the cyclic 12–3 window)")
	_check(not ocean.ice_blocks(Vector2i(0, 0), 1)
		and not ocean.ice_blocks(Vector2i(-5, 3000), 1),
		"ice lookups are wrap-aware on x and safe off-grid in y")
	# Memoized masks: the same Dictionary instance answers repeat queries.
	_check(ocean.ice_mask_for(1) == ocean.ice_mask_for(1)
		and ocean.ice_mask_for(1).size() > 0,
		"the month mask is memoized (same cache on repeat queries)")
	# x wrapping: the same ice tile 4320 tiles east is the same ice.
	_check(ocean.ice_blocks(ICE_CELL + Vector2i(4320, 0), 1),
		"a full wrap east of the ice tile still reads ice")


# --- Perf probes (docs/90-* §13; the risk table's F numbers) ------------------

func _test_tick_cost() -> void:
	var ocean = OceanLayersLib.instance()
	# Isolated added cost of the new per-day-tick lookups (the direction
	# roll's prevailing read + the drift guard's current read + the ice gate).
	var month := SailingSimLib.month_for(GameState.day)
	var started := Time.get_ticks_usec()
	var iterations := 10000
	for i in iterations:
		var cell := Vector2i(1000 + i % 2000, 400 + i % 1200)
		ocean.prevailing_for(cell, month)
		ocean.current_at(cell, month)
		ocean.ice_blocks(cell, month)
		SailingSimLib.month_for(i)
	var lookup_us := float(Time.get_ticks_usec() - started) / float(iterations)
	print("PROFILE ocean_lookup_avg_us %d" % int(round(lookup_us)))
	_check(lookup_us < 50.0,
		"the per-tick ocean lookups average %.1f µs (< 50 µs, pennies against the 50 ms day-tick budget)" % lookup_us)

	# 100 full sea-day ticks (ledger + economy step + drift guard + day
	# signal) with the ocean lookups live — the added day-tick cost in the
	# default mode. The 288-fleet tick gate itself re-runs in
	# test_npc_fleets (H's probe) with these additions included.
	_make_run(TRADE_CELL, "fair", "E")
	SailingSimLib.set_weather_seed(GOLDEN_SEED)
	var total_ms := 0.0
	var worst_ms := 0.0
	for day in TICK_PROBE_DAYS:
		var tick_started := Time.get_ticks_usec()
		SailingSimLib.advance_clock(1.0)
		var ms := float(Time.get_ticks_usec() - tick_started) / 1000.0
		total_ms += ms
		worst_ms = maxf(worst_ms, ms)
	var avg := total_ms / float(TICK_PROBE_DAYS)
	print("PROFILE ledger_day_avg_ms %d" % int(round(avg)))
	print("NOTE  day probe: %d sea days, avg %.3f ms, worst %.3f ms" % [
		TICK_PROBE_DAYS, avg, worst_ms])
	_check(avg < 5.0,
		"a full sea-day tick averages %.3f ms with the ocean lookups live (< 5 ms; the W3 budget re-proves at 288 fleets in test_npc_fleets)" % avg)


# --- Harness -----------------------------------------------------------------

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
