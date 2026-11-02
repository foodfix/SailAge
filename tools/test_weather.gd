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

## §4.7 latitude weather bands. A tile's latitude is `lat = 90 − y/12` (§4.1,
## Phase-6 grid), so the representative rows below are `y = round((90 − lat) * 12)`;
## `x` is irrelevant (the bands are zonal, not map columns).
const DOLDRUMS_CELL := Vector2i(3, 1080)    # lat 0.0
const TRADE_CELL := Vector2i(3, 740)        # lat 28.3 (Tenerife water)
const VARIABLES_CELL := Vector2i(3, 616)    # lat 38.7 (Lisbon)
const WESTERLIES_CELL := Vector2i(3, 480)   # lat 50.0
const BOREAL_CELL := Vector2i(3, 300)       # lat 65.0

## The five locked band tables (`20-*` §4.7), in **engine** ids. They are
## asserted **exactly** twice: `zone_probabilities()` equals `BAND_TABLES`
## verbatim at luck 0 (`_test_zone_table`), and at luck 10 it equals the §4.2
## closed form recomputed independently of the engine (`_expected_band_rates`,
## per band in `_test_storm_frequency`). The seeded draw keeps one ~500-roll
## spot sample per band table to prove `roll_weather` reads that table.
const BAND_TABLES := {
	"doldrums": {"calm": 0.30, "fair": 0.45, "strong": 0.15, "storm": 0.10},
	"trade_winds": {"calm": 0.15, "fair": 0.30, "strong": 0.20, "storm": 0.35},
	"variables": {"calm": 0.30, "fair": 0.40, "strong": 0.20, "storm": 0.10},
	"westerlies": {"calm": 0.10, "fair": 0.30, "strong": 0.35, "storm": 0.25},
	"boreal": {"calm": 0.15, "fair": 0.35, "strong": 0.30, "storm": 0.20},
}

## The per-band spot sample: ~500 seeded rolls prove the draw reads the
## luck-adjusted table; ±0.06 is ~3σ at 500 rolls (the table itself is pinned
## exactly, so the spot check only catches "draws from the wrong table").
const SPOT_ROLLS := 500
const SPOT_TOLERANCE := 0.06
const DAYS_PER_TRIAL := 6
## §4.7 acceptance threshold: "storm within 6 day ticks in-band ≥ 0.90".
const MIN_6_DAY_PROBABILITY := 0.90
## The milestone seed. Any fixed seed works; this one is pinned so the printed
## empirical rates are reproducible forever.
const WEATHER_SEED := 20261029

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the HUD/label fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	_test_zone_table()
	_test_band_edges()
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
	cell: Vector2i = TRADE_CELL,
	luck: int = 10,
	ship_ids: Array = ["caravel"],
	crew: int = 15,
	gold: int = 100000,
	constitution: int = 10,
) -> void:
	GameState.player = {
		"nation_id": "portugal",
		# Phase-8 v9 shape (50-* §4.8) + the legacy stats block the pre-merge
		# character.gd fallbacks read.
		"attributes": {
			"constitution": constitution, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": luck,
		},
		"skills": {
			"seamanship": 10, "navigation": 60, "swordplay": 0, "gunnery": 0,
			"appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0,
		},
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 60, "luck": luck,
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


func _tile(x: int, y: int) -> Vector2i:
	GameState.world["position"] = {"x": x, "y": y}
	return Vector2i(x, y)


## Finds a weather seed whose first trade-wind roll is a storm (the
## test_morale pattern, on this suite's fixture cell), for the deterministic
## storm-day observations.
func _seed_for_storm() -> int:
	for candidate in 500:
		SailingSimLib.set_weather_seed(candidate)
		if SailingSimLib.roll_weather(TRADE_CELL) == "storm":
			return candidate
	return 0


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


# --- §4.7 latitude bands: the table ---------------------------------------
#
# The band table is asserted twice:
#   1. `zone_probabilities()` at luck 0 equals `BAND_TABLES` verbatim (the
#      multiplier is 1.0 there, so no redistribution).
#   2. every band row is normalised at luck 0/10/50/100/399.
# Band selection itself (`weather_zone_for`) is `_test_band_edges()`.

func _test_zone_table() -> void:
	_make_run("fair", TRADE_CELL, 0)
	for band in BAND_TABLES:
		var table: Dictionary = BAND_TABLES[band]
		var got := SailingSimLib.zone_probabilities(band)
		_check(is_equal_approx(got["calm"], float(table["calm"]))
			and is_equal_approx(got["fair"], float(table["fair"]))
			and is_equal_approx(got["strong"], float(table["strong"]))
			and is_equal_approx(got["storm"], float(table["storm"])),
			"luck 0 %s table == %.2f/%.2f/%.2f/%.2f (got %s)" % [
				band, table["calm"], table["fair"], table["strong"], table["storm"],
				str(got),
			])

	# And they are exactly normalised at every luck value.
	for luck in [0, 10, 50, 100, 399]:
		_make_run("fair", TRADE_CELL, luck)
		for band in BAND_TABLES:
			var p := SailingSimLib.zone_probabilities(band)
			var total := 0.0
			for outcome in SailingSimLib.WEATHER_OUTCOMES:
				total += float(p[outcome])
			_check(is_equal_approx(total, 1.0),
				"luck %d %s probabilities sum to 1.0 (got %.12f)" % [luck, band, total])


# --- §4.7 latitude bands: band selection ----------------------------------

## `y = round((90 − lat) * 6)` at 6 tiles/degree (`20-*` §4.1). Every edge is
## checked on both sides, and the bands are zonal: `x` never matters.
func _test_band_edges() -> void:
	# y = (90 − lat) × 6: the exact row for a latitude.
	var cases := [
		# [latitude, expected band, label]
		[0.0, "doldrums", "equator"],
		[7.9, "doldrums", "|lat| 7.9"],
		[8.0, "trade_winds", "|lat| 8.0 (locked edge)"],
		[20.0, "trade_winds", "lat 20"],
		[28.3, "trade_winds", "Tenerife (28.3)"],
		[29.9, "trade_winds", "|lat| 29.9"],
		[30.0, "variables", "|lat| 30.0 (locked edge)"],
		[35.0, "variables", "lat 35"],
		[38.7, "variables", "Lisbon (38.7)"],
		[39.9, "variables", "|lat| 39.9"],
		[40.0, "westerlies", "|lat| 40.0 (locked edge)"],
		[50.0, "westerlies", "lat 50"],
		[59.9, "westerlies", "|lat| 59.9"],
		[60.0, "boreal", "|lat| 60.0 (locked edge)"],
		[65.0, "boreal", "lat 65"],
		[69.9, "boreal", "|lat| 69.9 (below the ice line)"],
		# Total behaviour beyond the ice: |lat| ≥ 70 is still `boreal`.
		[70.0, "boreal", "|lat| 70.0 (ice band, still boreal)"],
		[85.0, "boreal", "|lat| 85.0 (ice band, still boreal)"],
	]
	for row in cases:
		var latitude: float = row[0]
		var expected: String = row[1]
		var y := int(round((90.0 - latitude) * 12.0))
		# Both a sea-column and a far-east column: the bands are zonal.
		for x in [3, 4319]:
			_check(SailingSimLib.weather_zone_for(Vector2i(x, y)) == expected,
				"%s → y=%d, x=%d is %s (got %s)" % [
					str(row[2]), y, x, expected,
					SailingSimLib.weather_zone_for(Vector2i(x, y)),
				])

	# The exact positive fixtures the task names.
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 616)) == "variables",
		"Lisbon row (lat 38.7 → y≈616) is variables")
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 740)) == "trade_winds",
		"Tenerife row (lat 28.3 → y≈740) is trade_winds")
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 300)) == "boreal",
		"lat 65 (y=300) is boreal")

	# South mirror: the same band for the same |lat|, and the ice-band
	# latitudes stay `boreal` even though the tile would be impassable ice.
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 1320)) == "trade_winds",
		"lat −20 (y=1320) mirrors the northern trade winds")
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 1680)) == "westerlies",
		"lat −50 (y=1680) mirrors the northern westerlies")
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 1860)) == "boreal",
		"lat −65 (y=1860) is boreal by the symmetric table (its tile is ice)")
	_check(SailingSimLib.weather_zone_for(Vector2i(3, 2159)) == "boreal",
		"the southern ice rows (|lat| ≥ 70) still answer boreal (total function)")

	# Locked band ids only, and `x` is irrelevant (the old strip rule is gone).
	var seen := {}
	for y in range(0, 2160, 3):
		seen[SailingSimLib.weather_zone_for(Vector2i(0, y))] = true
	for band in BAND_TABLES:
		seen.erase(band)
	_check(seen.is_empty(),
		"only the five locked band ids occur (stray: %s)" % str(seen.keys()))
	_check(SailingSimLib.weather_zone_for(Vector2i(0, 1080))
		== SailingSimLib.weather_zone_for(Vector2i(4319, 1080)),
		"x=0 and x=4319 at the equator are the same band (zonal, not a strip)")


# --- §4.7 band tables: exact closed form + one seeded spot sample per band --
#
# The old 10,000-roll-per-band frequency harness re-derived (within ±0.02)
# numbers the suite already asserts exactly: `_test_zone_table` pins
# `zone_probabilities()` == `BAND_TABLES` at luck 0, and the luck term is
# arithmetic (`20-*` §4.2). So the luck-10 table per band is now asserted in
# closed form — storm' = storm × (1 − luck/400), the freed mass returned to
# calm/fair/strong in proportion to their base weights — against
# `_expected_band_rates()`, which recomputes it independently of the engine
# (no tautology). One ~500-roll seeded spot sample per band then proves the
# draw actually reads that table on the band's own tile.

## The §4.7 table for `band` with the luck term applied, computed independently
## of the engine: `storm' = storm × (1 − luck/400)`,
## `scale = (1 − storm') / (1 − storm)`, the three non-storm entries × scale.
func _expected_band_rates(band: String, luck: int) -> Dictionary:
	var base: Dictionary = BAND_TABLES[band]
	var base_storm := float(base["storm"])
	var storm := base_storm * (1.0 - float(luck) / 400.0)
	var scale := (1.0 - storm) / (1.0 - base_storm)
	return {
		"calm": float(base["calm"]) * scale,
		"fair": float(base["fair"]) * scale,
		"strong": float(base["strong"]) * scale,
		"storm": storm,
	}

## Rolls `count` weather outcomes at the current fleet tile and returns the
## per-outcome counts.
func _sample_outcomes(count: int) -> Dictionary:
	var counts := {"calm": 0, "fair": 0, "strong": 0, "storm": 0}
	var tile := GameState.world_tile()
	for index in count:
		var outcome := SailingSimLib.roll_weather(tile)
		counts[outcome] = int(counts.get(outcome, 0)) + 1
	return counts


func _test_storm_frequency() -> void:
	var bands := {
		"doldrums": DOLDRUMS_CELL,
		"trade_winds": TRADE_CELL,
		"variables": VARIABLES_CELL,
		"westerlies": WESTERLIES_CELL,
		"boreal": BOREAL_CELL,
	}
	var rates := {}
	var offset := 0
	for band in ["doldrums", "trade_winds", "variables", "westerlies", "boreal"]:
		var cell: Vector2i = bands[band]
		# Exact arithmetic: the luck-10 table IS the closed form — no sampling,
		# no tolerance.
		_make_run("fair", cell, 10)
		var expected := _expected_band_rates(band, 10)
		var got := SailingSimLib.zone_probabilities(band)
		for outcome in SailingSimLib.WEATHER_OUTCOMES:
			_check(is_equal_approx(float(got[outcome]), float(expected[outcome])),
				"luck 10 %s %s == closed form %.6f (got %.6f)"
					% [band, outcome, float(expected[outcome]), float(got[outcome])])
		# The seeded spot sample (~500 rolls) on the band's own tile.
		SailingSimLib.set_weather_seed(WEATHER_SEED + offset)
		offset += 1
		var counts := _sample_outcomes(SPOT_ROLLS)
		var parts: Array[String] = []
		for outcome in SailingSimLib.WEATHER_OUTCOMES:
			var rate := float(counts[outcome]) / float(SPOT_ROLLS)
			rates["%s.%s" % [band, outcome]] = rate
			parts.append("%s %.4f" % [outcome, rate])
		print("  %-12s y=%4d luck 10: %s" % [band, cell.y, "  ".join(parts)])
		for outcome in SailingSimLib.WEATHER_OUTCOMES:
			var rate: float = rates["%s.%s" % [band, outcome]]
			var want := float(expected[outcome])
			_check(absf(rate - want) <= SPOT_TOLERANCE,
				"%s %s %.4f±%.2f over %d rolls (got %.4f)"
					% [band, outcome, want, SPOT_TOLERANCE, SPOT_ROLLS, rate])

	# Sanity that the bands are materially different: the trade winds are the
	# storm belt (0.35 base), the variables the calmest (0.10), so the seeded
	# samples must order the same way by a wide margin.
	_check(float(rates["trade_winds.storm"]) > float(rates["variables.storm"]) * 2.0,
		"trade winds are at least 2× stormier than the variables (%.4f vs %.4f)"
		% [rates["trade_winds.storm"], rates["variables.storm"]])
	_check(float(rates["doldrums.fair"]) > float(rates["westerlies.fair"]),
		"the doldrums are the fair-weather band (%.4f vs %.4f)"
		% [rates["doldrums.fair"], rates["westerlies.fair"]])


# --- docs/50-* §4.2: luck scales the storm chance only ---------------------

func _test_luck_scales_storm_chance() -> void:
	# Trade winds (base 0.35) × (1 − luck/400): 0 → 0.3500, 10 → 0.34125,
	# 100 → 0.2625 — asserted as exact arithmetic on the luck-adjusted table
	# (the seeded draw reading that table is spot-checked per band in
	# `_test_storm_frequency`).
	var rows := [
		[0, 0.3500],
		[10, 0.34125],
		[100, 0.2625],
	]
	for row in rows:
		var luck: int = row[0]
		var expected: float = row[1]
		_make_run("fair", TRADE_CELL, luck)
		var storm := float(SailingSimLib.zone_probabilities("trade_winds")["storm"])
		_check(is_equal_approx(storm, expected),
			"luck %d trade-wind storm chance == %.5f (got %.6f)"
				% [luck, expected, storm])
		_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 1.0 - luck / 400.0),
			"Character.storm_chance_multiplier() == 1 − luck/400 at luck %d" % luck)

	# Monotone: more luck can never raise the storm probability.
	_make_run("fair", TRADE_CELL, 0)
	var p0 := float(SailingSimLib.zone_probabilities("trade_winds")["storm"])
	_make_run("fair", TRADE_CELL, 100)
	var p100 := float(SailingSimLib.zone_probabilities("trade_winds")["storm"])
	_check(p0 > p100, "luck 0 storm chance (%.4f) exceeds luck 100 (%.4f)" % [p0, p100])


# --- redistribution keeps the doc's non-storm ratios ----------------------

func _test_redistribution_preserves_table() -> void:
	# (1 − storm') / (1 − base_storm) scaling on the trade winds at luck 10:
	# storm' = 0.35 × 0.975 = 0.34125, scale = 0.65875 / 0.65 = 1.0134615…,
	# so calm 0.15 → 0.152019, fair 0.30 → 0.304038, strong 0.20 → 0.202692.
	_make_run("fair", TRADE_CELL, 10)
	var trade := SailingSimLib.zone_probabilities("trade_winds")
	var scale := (1.0 - 0.34125) / (1.0 - 0.35)
	_check(is_equal_approx(trade["storm"], 0.35 * (1.0 - 10.0 / 400.0)),
		"luck 10 trade-wind storm = 0.35 × (1 − 10/400) = 0.34125 (got %.6f)"
		% trade["storm"])
	_check(is_equal_approx(trade["calm"], 0.15 * scale),
		"the freed storm mass goes to calm by its base share: 0.15 × %.6f (got %.6f)"
		% [scale, trade["calm"]])
	_check(is_equal_approx(trade["fair"], 0.30 * scale),
		"…and to fair: 0.30 × %.6f (got %.6f)" % [scale, trade["fair"]])
	_check(is_equal_approx(trade["strong"], 0.20 * scale),
		"…and to strong: 0.20 × %.6f (got %.6f)" % [scale, trade["strong"]])

	# Non-storm outcomes keep their relative shares at every luck value, in
	# every band (each band's own calm:fair:strong ratio).
	for luck in [0, 10, 50, 100, 300]:
		_make_run("fair", TRADE_CELL, luck)
		for band in BAND_TABLES:
			var base: Dictionary = BAND_TABLES[band]
			var p := SailingSimLib.zone_probabilities(band)
			var ratio_fair := float(p["fair"]) / float(p["calm"])
			var ratio_strong := float(p["strong"]) / float(p["calm"])
			var want_fair := float(base["fair"]) / float(base["calm"])
			var want_strong := float(base["strong"]) / float(base["calm"])
			_check(is_equal_approx(ratio_fair, want_fair)
				and is_equal_approx(ratio_strong, want_strong),
				"luck %d: %s calm:fair:strong still %.4f:%.4f:1 (got 1:%.4f:%.4f)"
				% [luck, band, want_fair, want_strong, ratio_fair, ratio_strong])

	# Luck never inflates a band's storm chance above its base.
	for band in BAND_TABLES:
		var base: Dictionary = BAND_TABLES[band]
		_make_run("fair", TRADE_CELL, 10)
		var p := SailingSimLib.zone_probabilities(band)
		_check(float(p["storm"]) < float(base["storm"]),
			"%s storm chance drops below its base at luck 10 (got %.6f)"
			% [band, p["storm"]])


# --- §4.7 / §5 storm damage formula ---------------------------------------

func _test_damage_formula() -> void:
	# §4.7 Phase 8: damage × (1 − luck/250), continuous, applied before ceil.
	# Caravel 90 → ceil(4.5) = 5 at luck 0; ceil(4.5 × 0.96) = 5 at luck 10;
	# ceil(4.5 × 0.60) = ceil(2.7) = 3 at luck 100 (×1.00 / ×0.60).
	_make_run("fair", TRADE_CELL, 0)
	_check(is_equal_approx(SailingSimLib.storm_luck_multiplier(), 1.0),
		"storm_luck_multiplier at luck 0 is ×1.00 (got %.4f)"
		% SailingSimLib.storm_luck_multiplier())
	_check(SailingSimLib.storm_damage_for(90) == 5,
		"caravel (90) takes ceil(90×0.05) = 5 at luck 0 (got %d)"
		% SailingSimLib.storm_damage_for(90))
	_make_run("fair", TRADE_CELL, 10)
	_check(is_equal_approx(SailingSimLib.storm_luck_multiplier(), 0.96),
		"storm_luck_multiplier at luck 10 is ×0.96 (got %.4f)"
		% SailingSimLib.storm_luck_multiplier())
	_check(SailingSimLib.storm_damage_for(90) == 5,
		"caravel (90) takes ceil(4.5×0.96) = 5 at luck 10 (got %d)"
		% SailingSimLib.storm_damage_for(90))
	_make_run("fair", TRADE_CELL, 100)
	_check(is_equal_approx(SailingSimLib.storm_luck_multiplier(), 0.60),
		"storm_luck_multiplier at luck 100 is ×0.60 (got %.4f)"
		% SailingSimLib.storm_luck_multiplier())
	_check(SailingSimLib.storm_damage_for(90) == 3,
		"caravel (90) takes ceil(4.5×0.6) = 3 at luck 100 (got %d)"
		% SailingSimLib.storm_damage_for(90))
	# The retired `luck ≥ 50 → ×0.75` step is gone: the multiplier is
	# continuous — luck 49 → ×0.804, luck 50 → ×0.80 (the ×0.8 value the old
	# step produced at exactly 50 is now just the continuous curve).
	_make_run("fair", TRADE_CELL, 49)
	_check(is_equal_approx(SailingSimLib.storm_luck_multiplier(), 1.0 - 49.0 / 250.0),
		"luck 49 sits on the continuous curve ×0.804 (got %.4f)"
		% SailingSimLib.storm_luck_multiplier())
	_make_run("fair", TRADE_CELL, 50)
	_check(is_equal_approx(SailingSimLib.storm_luck_multiplier(), 0.80),
		"luck 50 is ×0.80, the same continuous curve (got %.4f)"
		% SailingSimLib.storm_luck_multiplier())

	# Luck is applied BEFORE ceil, not after (4.5 × 0.6 = 2.7 → 3, not
	# ceil(5) × 0.6 → 3 either way at luck 100; luck 49 separates them:
	# 4.5 × 0.804 = 3.618 → 4, while floor(ceil(4.5) × 0.804) = 3).
	_make_run("fair", TRADE_CELL, 49)
	_check(SailingSimLib.storm_damage_for(90) == 4,
		"mitigation is applied before rounding (4, not floor(5×0.804)=3)")

	# Every hull in data/ship_types.json at luck 0 (×1.00) and luck 100
	# (×0.60), exact §4.7 values.
	_make_run("fair", TRADE_CELL, 0)
	var expected_plain := {
		"latin": 2, "sloop": 3, "caravel": 5, "galley": 4,
		"brigantine": 6, "nao": 7, "carrack": 9, "galleon": 12,
	}
	for ship_id in expected_plain:
		var max_dur := int(DataLoader.get_ship_type(str(ship_id))["durability"])
		_check(SailingSimLib.storm_damage_for(max_dur) == int(expected_plain[ship_id]),
			"%s (%d) takes %d damage at luck 0 (got %d)" % [
				ship_id, max_dur, int(expected_plain[ship_id]),
				SailingSimLib.storm_damage_for(max_dur)
			])
	_make_run("fair", TRADE_CELL, 100)
	var expected_mitigated := {
		"latin": 2, "sloop": 2, "caravel": 3, "galley": 3,
		"brigantine": 4, "nao": 5, "carrack": 6, "galleon": 8,
	}
	for ship_id in expected_mitigated:
		var max_dur := int(DataLoader.get_ship_type(str(ship_id))["durability"])
		_check(SailingSimLib.storm_damage_for(max_dur) == int(expected_mitigated[ship_id]),
			"%s (%d) takes %d damage at luck 100 (got %d)" % [
				ship_id, max_dur, int(expected_mitigated[ship_id]),
				SailingSimLib.storm_damage_for(max_dur)
			])


func _test_storm_damage_applied_to_fleet() -> void:
	# Multi-ship fleet: caravel 90 + nao 140 → 5 and 7 damage (§4.7).
	_make_run("fair", TRADE_CELL, 10, ["caravel", "nao"])
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

	# The continuous luck curve lets the same fleet ride it out with less
	# damage: at luck 50 (×0.80) caravel ceil(4.5×0.8) = 4 and nao
	# ceil(7×0.8) = ceil(5.6) = 6.
	_make_run("fair", TRADE_CELL, 50, ["caravel", "nao"])
	SailingSimLib.apply_storm_damage()
	_check(int(GameState.fleet[0]["durability"]) == 86
		and int(GameState.fleet[1]["durability"]) == 134,
		"luck 50 fleet (×0.80 continuous): caravel 90 → 86, nao 140 → 134 (got %d/%d)" % [
			int(GameState.fleet[0]["durability"]),
			int(GameState.fleet[1]["durability"]),
		])

	# A storm day through the *ledger*: find a seed whose first roll is a storm,
	# then assert exactly the §4.7 damage landed once (no double application).
	var storm_seed := -1
	for candidate in 500:
		SailingSimLib.set_weather_seed(candidate)
		_make_run("fair", TRADE_CELL, 10)
		if SailingSimLib.roll_weather(TRADE_CELL) == "storm":
			storm_seed = candidate
			break
	_check(storm_seed >= 0,
		"found a seed whose first trade-wind roll is a storm (found %d)" % storm_seed)
	if storm_seed >= 0:
		SailingSimLib.set_weather_seed(storm_seed)
		_make_run("fair", TRADE_CELL, 10)
		_one_day()
		_check(str(GameState.world["weather"]) == "storm",
			"the seeded ledger day is a storm (%s)" % str(GameState.world["weather"]))
		_check(SailingSimLib.last_day_storm, "last_day_storm is true after that day")
		_check(int(GameState.fleet[0]["durability"]) == 85,
			"a storm ledger day removes exactly 5 durability once (90 → %d)"
			% int(GameState.fleet[0]["durability"]))

	# Durability clamps at 0 and never goes negative; damage stops there.
	_make_run("fair", TRADE_CELL, 10)
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
	_make_run("fair", TRADE_CELL, 10)
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
	_make_run("fair", TRADE_CELL, 10)
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
		"the seeded 6-day trade-wind run contains at least one storm (got %d)" % storm_days)

	# §4.8.1 storm-day morale (Phase 8): the storm −5 itself is
	# × (1 − (CON−10)/300). At CON 10 the multiplier is 1.0 (−5, the pin
	# above); at CON 100 it is 0.7 → −5 × 0.7 = −3.5, rounded half away from
	# zero to the integral −4. One seeded storm day at CON 100 pins it.
	_make_run("fair", TRADE_CELL, 10, ["caravel"], 15, 100000, 100)
	_check(is_equal_approx(SailingSimLib.storm_morale_multiplier(), 0.7),
		"storm_morale_multiplier at CON 100 is ×0.7 (got %.4f)"
		% SailingSimLib.storm_morale_multiplier())
	_check(SailingSimLib.storm_morale_delta() == -4,
		"the CON-100 storm morale delta is round(−3.5) = −4 (got %d)"
		% SailingSimLib.storm_morale_delta())
	SailingSimLib.set_weather_seed(_seed_for_storm())
	GameState.morale = 70
	_one_day()
	_check(SailingSimLib.last_day_storm, "the CON-100 fixture seeded a storm day")
	_check(GameState.morale == 70 - 1 - 4 and SailingSimLib.last_morale_delta == -5,
		"a CON-100 storm day costs −1 −4 = −5 (70 → %d, delta %d)" % [
			GameState.morale, SailingSimLib.last_morale_delta])

	# The flag itself: true on a storm, false on the next non-storm day.
	_make_run("fair", TRADE_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var saw_flag_true := false
	var saw_flag_false_after_storm := false
	var previous_was_storm := false
	var mismatches := 0
	var days_mirrored := 0
	# 20 seeded days is far more than both flag states need (storm p≈0.34, so
	# a storm and a clear day after it land within the first handful); the loop
	# breaks once both were observed.
	for day in 20:
		# Weather-only fixture: keep T9's fail states (T9 suffix of the ledger)
		# out of the measurement by restoring stores and hull each day.
		_refill()
		_one_day()
		days_mirrored += 1
		var now_storm: bool = str(GameState.world["weather"]) == "storm"
		if SailingSimLib.last_day_storm != now_storm:
			mismatches += 1
		if SailingSimLib.last_day_storm:
			saw_flag_true = true
			previous_was_storm = true
		elif previous_was_storm:
			saw_flag_false_after_storm = true
			previous_was_storm = false
		if saw_flag_true and saw_flag_false_after_storm:
			break
	_check(mismatches == 0,
		"last_day_storm mirrors world.weather on all %d mirrored days (got %d mismatches)"
			% [days_mirrored, mismatches])
	_check(saw_flag_true, "last_day_storm is raised on storm days")
	_check(saw_flag_false_after_storm,
		"last_day_storm is cleared again on the next non-storm day")

	# In port too: the roll still happens (zone-based), and step 4 applies the
	# in-port +5 up to the port cap 80 (§4.8.1) — never a sea delta. Three
	# ticks cover the whole climb: 70 → 75 → 80 → 80 (the cap pins).
	_make_run("fair", TRADE_CELL, 10)
	GameState.current_port = "lisbon"
	GameState.morale = 70
	for day in 3:
		SailingSimLib.advance_port_day()
	_check(GameState.morale == SailingSimLib.MORALE_PORT_CAP,
		"port day-advances climb +5 to the cap 80 (70 → %d)" % GameState.morale)


# --- Persistence: the roll is written into GameState.world ----------------

func _test_weather_persists() -> void:
	_make_run("fair", TRADE_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var seen := {}
	var invalid: Array[String] = []
	for day in 60:
		_refill()
		_one_day()
		var weather := str(GameState.world["weather"])
		seen[weather] = true
		if not (weather in SailingSimLib.WEATHER_OUTCOMES):
			invalid.append(weather)
	_check(invalid.is_empty(),
		"world.weather holds a §4.7 outcome on all 60 days (bad: %s)" % str(invalid))
	# One storm-free counter-check: the roll overwrote the pre-set "fair".
	_check(seen.has("storm") and seen.has("calm"),
		"60 trade-wind days (storm p≈0.34, seeded) produce several outcomes (saw %s)"
			% str(seen.keys()))

	# The band follows the tile: same seed, a variables-band tile (tropical
	# row y=740) vs a westerlies tile (y=480).
	_make_run("fair", TRADE_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_one_day()
	_check(SailingSimLib.last_weather_zone == "trade_winds",
		"the roll reads the fleet's current tile, not a cached band (got %s)"
		% SailingSimLib.last_weather_zone)
	_tile(3, 480)
	_one_day()
	_check(SailingSimLib.last_weather_zone == "westerlies",
		"moving to lat 50 (y=480) switches the next roll to the westerlies (got %s)"
		% SailingSimLib.last_weather_zone)

	# No transient keys leak into GameState.world (T17 save-block hygiene):
	# the storm flags are class statics, exactly like last_day_shortfalls.
	# Phase 6: `wind_dir` is a *persisted* world key (docs/90-* §5.4, written
	# by ledger step 3's second roll), not a transient leak.
	var allowed := ["position", "clock_fraction", "weather", "wind_dir"]
	for key in GameState.world:
		_check(str(key) in allowed,
			"GameState.world carries no transient ledger key ('%s')" % str(key))
	_check(not GameState.world.has("last_weather_zone")
		and not GameState.world.has("last_day_storm"),
		"zone/storm flags stay off the save block")


# --- §4.7 "Reachability acceptance": the Tenerife demo gate ----------------
#
# Demo-loop step 5 (re-anchored): Lisbon (38.7°N, variables) → the open water
# off Santa Cruz de Tenerife (≈28.3°N, trade winds) — a **coordinate
# destination**, not a port. Arrival means crossing the 30°N band edge and
# sampling weather there. The gate: "storm within 6 day ticks in-band ≥ 0.90".
#
# Arithmetic (`20-*` §4.7): the trade-wind base storm chance is 0.35, and the
# luck term scales it by (1 − luck/400), so at the default luck 10 the
# per-day chance is p = 0.35 × 0.975 = 0.34125. Six independent in-band ticks
# therefore give P(at least one storm) = 1 − (1 − 0.34125)^6 = 0.9183…; the
# no-luck form is 1 − 0.65^6 = 0.9246. Both clear the 0.90 gate; a "≥ 0.98 in
# 12 days" claim is NOT made and is not asserted.

func _closed_form(p: float, days: int) -> float:
	return 1.0 - pow(1.0 - p, days)


func _test_reachability() -> void:
	# 1. Closed form, exact to 4 dp (§4.7 arithmetic above).
	var p := 0.35 * (1.0 - 10.0 / 400.0)  # luck 10 → 0.34125
	_check(is_equal_approx(p, 0.34125), "p at luck 10 is 0.34125 (got %.6f)" % p)
	var six := _closed_form(p, 6)
	var six_no_luck := _closed_form(0.35, 6)
	print("  closed form: p=%.5f  1−(1−p)^6=%.4f  1−0.65^6=%.4f" % [p, six, six_no_luck])
	_check(absf(six - 0.9183) < 0.0005,
		"1 − (1−0.34125)^6 = 0.9183 to 4 dp (got %.6f)" % six)
	_check(absf(six_no_luck - 0.9246) < 0.0005,
		"…and the no-luck 1 − 0.65^6 = 0.9246 (got %.6f)" % six_no_luck)
	_check(six >= MIN_6_DAY_PROBABILITY and six_no_luck >= MIN_6_DAY_PROBABILITY,
		"both closed forms clear the ≥0.90 / 6-day gate")

	# 2. Through the production path (real ledger days, storm damage included):
	#    a caravel survives 6 storm days (6 × 5 = 30 < 90), so the day loop can
	#    run to completion and the milestone still lands. (The old empirical
	#    10,000-window re-derivation of the same number was replaced by the
	#    per-band seeded spot samples in `_test_storm_frequency`, 2026-11-02.)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_make_run("fair", TRADE_CELL, 10)
	var production_hit := false
	for day in DAYS_PER_TRIAL:
		_one_day()
		if SailingSimLib.last_day_storm:
			production_hit = true
			break
	_check(production_hit,
		"the production ledger path reaches a storm within 6 days in the trade "
		+ "belt (damage applied along the way, durability %d)"
		% int(GameState.fleet[0]["durability"]))


# --- Determinism ----------------------------------------------------------

func _test_determinism() -> void:
	_make_run("fair", TRADE_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var first: Array[String] = []
	for day in 50:
		first.append(SailingSimLib.roll_weather(TRADE_CELL))
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var second: Array[String] = []
	for day in 50:
		second.append(SailingSimLib.roll_weather(TRADE_CELL))
	_check(first == second, "same seed → identical 50-roll weather sequence")

	SailingSimLib.set_weather_seed(WEATHER_SEED + 1)
	var third: Array[String] = []
	for day in 50:
		third.append(SailingSimLib.roll_weather(TRADE_CELL))
	_check(first != third, "a different seed produces a different sequence")

	# Determinism also holds through the ledger (the roll is the only RNG use
	# in step 3, and step 1/2 are deterministic).
	_make_run("fair", TRADE_CELL, 10)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var ledger_a: Array[String] = []
	for day in 10:
		_one_day()
		ledger_a.append(str(GameState.world["weather"]))
	_make_run("fair", TRADE_CELL, 10)
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
	_make_run("fair", TRADE_CELL, 10)
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
	_make_run("fair", TRADE_CELL, 10)

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
