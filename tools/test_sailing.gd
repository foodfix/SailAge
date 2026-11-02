extends Node
## T7 acceptance tests (docs/IMPLEMENT-Phase1.md T7; docs/20-* §4.3–§4.6,
## §4.9–§4.10, §5; docs/40-* §4.2; docs/50-* §4.5). Headless scene test:
##
##   godot --headless res://tools/test_sailing.tscn
##
## Exits 0 when every check passes, 1 otherwise. Re-asserts the T6 speed table
## because the ledger now runs inside the day tick: those numbers must not have
## moved.
##
## Scope: ledger step 1 (consumption) and step 2 (wages) only. There is
## deliberately no weather/morale assertion beyond "unchanged", which is the
## proof that the T8/T9 hooks are still empty.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
## `character.gd` is preloaded like every other engine: a bare `Character.`
## reference needs the editor's global-class cache and fails to parse in a
## fresh checkout / CI worktree (Phase-2 finding).
const CharacterLib := preload("res://scripts/player/character.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")

## Open-water cell whose 8 neighbours are passable, in the world map's variables
## band (lat ≈ 36.7°N) and far from every harbor. Phase 4: the fixture moved
## from the retired P1 grid to the real Earth (task G).
const OPEN_CELL := Vector2i(1400, 640)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the movement-driven clock checks (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	_test_constants()
	_test_phase8_constants()
	_test_sighting_radius()
	_test_officer_day_seam()
	_test_consumption()
	_test_wages()
	_test_gold_clamp()
	_test_crew_zero()
	_test_clock_boundaries()
	_test_speed_table()
	_test_heading_pipeline()
	_test_display_formats()
	_test_port_day()
	_test_no_weather_or_morale_mutation()
	_report()


# --- Fixtures --------------------------------------------------------------

## Caravel (speed 20, crew_min 15, crew_max 45) at full crew, base stats, fair
## weather → effective speed exactly 20 (§4.4 worked case; Phase-6 ×2 speeds on
## 5 nm tiles, `10-*` §7.3; the Phase-8 seamanship-10 bonus is +0.0333 and
## floor(20 × 1.0333) = 20). The hold defaults to
## empty; each test loads what it needs. Default navigation is 60 (above the
## night-sail threshold) so the suite's clock walks keep their day arithmetic;
## the night rule is pinned in test_movement.
func _make_run(
	crew: int = 15, provisions: int = 0, water: int = 0,
	gold: int = 1000, weather: String = "fair",
	seamanship: int = 10, navigation: int = 60,
	courage: int = 10, constitution: int = 10, charisma: int = 10,
	luck: int = 10,
) -> void:
	GameState.player = {
		"nation_id": "portugal",
		# Phase-8 v9 shape (50-* §4.8) + the legacy stats block the pre-merge
		# character.gd fallbacks read.
		"attributes": {
			"constitution": constitution, "intellect": 10, "charisma": charisma,
			"courage": courage, "luck": luck,
		},
		"skills": {
			"seamanship": seamanship, "navigation": navigation,
			"swordplay": 0, "gunnery": 0, "appraisal": 0, "negotiation": 0,
			"cartography": 0, "rumour": 0,
		},
		"stats": {
			"leadership": charisma, "seamanship": seamanship, "combat": 10,
			"navigation": navigation, "luck": luck,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	var ship: Dictionary = FleetLib.new_ship("caravel", crew)
	ship["provisions"] = provisions
	ship["water"] = water
	GameState.fleet = [ship]
	GameState.day = 1
	GameState.gold = gold
	GameState.morale = SailingSimLib.MORALE_START
	GameState.current_port = null
	GameState.known_ports = []
	GameState.world = {
		"position": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
		"clock_fraction": 0.0,
		"weather": weather,
		# Phase-6 fixture pin: a southerly wind makes this suite's east–west
		# clock walks the beam bucket (factor 1.0, §4.4), so their "speed 20 =
		# 0.05 days per move" arithmetic stays the exact W3 semantics; the
		# heading effects themselves are asserted in _test_heading_pipeline.
		"wind_dir": "S",
	}
	# Reset the ledger's per-tick statics so one test cannot leak into another.
	SailingSimLib.last_day_shortfalls = {"provisions": false, "water": false}
	SailingSimLib.last_day_unpaid_wages = false
	SailingSimLib.last_day_wages = 0
	SailingSimLib.last_day_storm = false


## Runs exactly one ledger day through the production path (the clock), so the
## test exercises `advance_clock` → `_run_daily_ledger`, not a private call.
func _one_day() -> int:
	return SailingSimLib.advance_clock(1.0)


# --- §5 constants ----------------------------------------------------------

func _test_constants() -> void:
	# Integer constants written out explicitly: GDScript constants are not
	# enumerable on a preloaded script class, so each §5 entry is asserted here.
	_check(SailingSimLib.CREW_WAGE_DAILY == 2,
		"§5 crew_wage_daily == 2 (got %d)" % SailingSimLib.CREW_WAGE_DAILY)
	_check(SailingSimLib.RATION_SIZE == 5,
		"§5 ration_size == 5 (got %d)" % SailingSimLib.RATION_SIZE)
	_check(SailingSimLib.PROVISIONS_PRICE == 2,
		"§5 provisions_price == 2 (got %d)" % SailingSimLib.PROVISIONS_PRICE)
	_check(SailingSimLib.WATER_PRICE == 1,
		"§5 water_price == 1 (got %d)" % SailingSimLib.WATER_PRICE)
	_check(SailingSimLib.SIGHTING_RADIUS == 48,
		"§5 sighting_radius == 48 (got %d)" % SailingSimLib.SIGHTING_RADIUS)
	_check(SailingSimLib.DISCOVERY_RADIUS == 36,
		"§5 discovery_radius == 36 (got %d)" % SailingSimLib.DISCOVERY_RADIUS)
	# The engine base lives in `DiscoverySight.RADIUS_BASE` (70-* §4.4 — the
	# cartography-0 floor of `36 + floor(cartography/15)`); §5 is the
	# single documented constants location, so the two must never drift.
	_check(DiscoveryLib.RADIUS_BASE == SailingSimLib.DISCOVERY_RADIUS,
		"DiscoverySight.RADIUS_BASE (%d) == §5 discovery_radius base (%d)"
		% [DiscoveryLib.RADIUS_BASE, SailingSimLib.DISCOVERY_RADIUS])
	_check(SailingSimLib.MORALE_START == 70,
		"§5 morale_start == 70 (got %d)" % SailingSimLib.MORALE_START)
	_check(SailingSimLib.MORALE_PORT_CAP == 80,
		"§5 morale_port_cap == 80 (got %d)" % SailingSimLib.MORALE_PORT_CAP)
	_check(SailingSimLib.STARVATION_LIMIT_DAYS == 7,
		"§5 starvation_limit_days == 7 (got %d)" % SailingSimLib.STARVATION_LIMIT_DAYS)
	_check(SailingSimLib.MUTINY_THRESHOLD == 20,
		"§5 mutiny_threshold == 20 (got %d)" % SailingSimLib.MUTINY_THRESHOLD)
	_check(SailingSimLib.DESERTION_THRESHOLD == 40,
		"§5 desertion_threshold == 40 (got %d)" % SailingSimLib.DESERTION_THRESHOLD)
	_check(is_equal_approx(SailingSimLib.STORM_DAMAGE_FRACTION, 0.05),
		"§5 storm_damage_fraction == 0.05 (got %.2f)"
		% SailingSimLib.STORM_DAMAGE_FRACTION)
	_check(is_equal_approx(SailingSimLib.MUTINY_CHANCE_PER_DAY, 0.25),
		"§5 mutiny_chance_per_day == 0.25 (got %.2f)"
		% SailingSimLib.MUTINY_CHANCE_PER_DAY)
	_check(is_equal_approx(SailingSimLib.DESERTION_FRACTION, 0.10),
		"§5 desertion_fraction == 0.10 (got %.2f)"
		% SailingSimLib.DESERTION_FRACTION)
	# T6 speed constants must survive T7 (no renumbering).
	_check(SailingSimLib.MIN_SPEED == 1 and
		is_equal_approx(SailingSimLib.CREW_FACTOR_MIN, 0.25),
		"T6 MIN_SPEED/CREW_FACTOR_MIN unchanged")

	# §4.11 / `70-*` §4.4: the discovery range check is wrap-aware on x and takes
	# the grid width from the loaded legend — 4320 on the single world map
	# (Phase-6 rescale), so
	# the seam is 1 tile wide, not 4319. (Re-anchored from the retired P1 grid's
	# 128 in task G: the assertion's intent — "seam distance is 1, not width−1" —
	# is unchanged, the width comes from the shipped world.)
	_check(DiscoveryLib.map_width() == 4320,
		"discovery wrap uses the loaded legend width (got %d)"
		% DiscoveryLib.map_width())
	_check(DiscoveryLib.chebyshev_to_cell(Vector2i(4319, 10), Vector2i(0, 10)) == 1,
		"x=4319 and x=0 are 1 tile apart across the seam (got %d)"
		% DiscoveryLib.chebyshev_to_cell(Vector2i(4319, 10), Vector2i(0, 10)))
	_check(DiscoveryLib.chebyshev_to_cell(Vector2i(2160, 10), Vector2i(0, 10)) == 2160,
		"the far side of the seam stays far (got %d)"
		% DiscoveryLib.chebyshev_to_cell(Vector2i(2160, 10), Vector2i(0, 10)))


# --- §5 Phase-8 constants (20-* §5 "sailing_constants") --------------------

func _test_phase8_constants() -> void:
	_check(SailingSimLib.SEAMANSHIP_SPEED_DIVISOR == 300
		and is_equal_approx(SailingSimLib.SEAMANSHIP_SPEED_CAP, 0.30),
		"§5 seamanship_speed_divisor/cap == 300 / +0.30 (got %d / %.2f)" % [
			SailingSimLib.SEAMANSHIP_SPEED_DIVISOR, SailingSimLib.SEAMANSHIP_SPEED_CAP])
	_check(SailingSimLib.SIGHTING_NAVIGATION_DIVISOR == 12,
		"§5 sighting_navigation_divisor == 12 (got %d)"
		% SailingSimLib.SIGHTING_NAVIGATION_DIVISOR)
	_check(SailingSimLib.DISCOVERY_CARTOGRAPHY_DIVISOR == 15,
		"§5 discovery_cartography_divisor == 15 (the formula itself lives in "
		+ "DiscoverySight, got %d)" % SailingSimLib.DISCOVERY_CARTOGRAPHY_DIVISOR)
	_check(SailingSimLib.NIGHT_WINDOW_START_HOUR == 22
		and SailingSimLib.NIGHT_WINDOW_END_HOUR == 6,
		"§5 night window == 22:00–06:00 (got %d–%d)" % [
			SailingSimLib.NIGHT_WINDOW_START_HOUR, SailingSimLib.NIGHT_WINDOW_END_HOUR])
	_check(is_equal_approx(SailingSimLib.NIGHT_MOVE_COST_MULTIPLIER, 2.0)
		and SailingSimLib.NIGHT_SAIL_NAVIGATION_THRESHOLD == 40,
		"§5 night multiplier / navigation threshold == 2.0 / 40")
	_check(SailingSimLib.STORM_DAMAGE_LUCK_DIVISOR == 250,
		"§5 storm_damage_luck_divisor == 250 (got %d)"
		% SailingSimLib.STORM_DAMAGE_LUCK_DIVISOR)
	_check(is_equal_approx(SailingSimLib.STORM_HEADWAY_BASE_LOSS, 0.5)
		and SailingSimLib.STORM_HEADWAY_DIVISOR == 400,
		"§5 storm headway == base loss 0.5 over COU divisor 400")
	_check(SailingSimLib.STORM_MORALE_CON_DIVISOR == 300,
		"§5 storm morale CON divisor == 300 (got %d)"
		% SailingSimLib.STORM_MORALE_CON_DIVISOR)
	_check(SailingSimLib.MUTINY_CHARISMA_DIVISOR == 200,
		"§5 mutiny_charisma_divisor == 200 (got %d)"
		% SailingSimLib.MUTINY_CHARISMA_DIVISOR)
	_check(SailingSimLib.SCURVY_GRACE_DIVISOR == 10,
		"§5 scurvy_grace_divisor == 10 (got %d)" % SailingSimLib.SCURVY_GRACE_DIVISOR)
	_check(SailingSimLib.CAPTAIN_LESS_SPEED_FACTOR == 0.8
		and SailingSimLib.MORALE_CAPTAIN_LESS == -2,
		"§5/40-* captain-less hooks == speed ×0.8, morale −2")
	_check(SailingSimLib.AT_SEA_REPAIR_POINTS == 10
		and SailingSimLib.AT_SEA_REPAIR_CARPENTRY_GATE == 60
		and SailingSimLib.AT_SEA_REPAIR_CARPENTRY_DIVISOR == 20,
		"40-* §4.5 at-sea minor repair == +10 dur / carpentry gate 60 / −skill/20%%")


# --- §4.11 sighting radius (Phase 8) ---------------------------------------

## `48 + floor(effective_navigation / 12)` at navigation 0/40/100 → 48/51/56.
## (The base-48 agreement with `DiscoverySight.RADIUS`'s separate constant is
## pinned in `_test_constants`; the discovery radius formula itself is
## `DiscoverySight`'s — `70-*` §4.4 — not this file's.)
func _test_sighting_radius() -> void:
	for row in [[0, 48], [40, 51], [100, 56]]:
		_make_run(15, 0, 0, 1000, "fair", 10, int(row[0]))
		_check(SailingSimLib.sighting_radius() == int(row[1]),
			"navigation %d sighting radius == %d (got %d)" % [
				int(row[0]), int(row[1]), SailingSimLib.sighting_radius()])
		_check(SailingSimLib.sighting_radius_for(int(row[0])) == int(row[1]),
			"sighting_radius_for(%d) == %d (the pure formula)" % [
				int(row[0]), int(row[1])])


# --- §4.8.1 officer sea-day growth seam (Phase 8) --------------------------

## The ledger calls `Skills.note_sea_day()` + `Skills.officer_day_tick()` at
## the sea-day growth point (after consumption/wages, with the +2 XP award),
## and nothing on a port day. The double is a runtime GDScript standing in for
## slot A's `skills.gd` (which owns the real growth rules and their own tests);
## this pins the sailing-side seam only. Never set `skills_script_override`
## outside a test.
func _test_officer_day_seam() -> void:
	var calls_log := "extends RefCounted\nstatic var calls := []\n" \
		+ "static func note_sea_day() -> void:\n\tcalls.append(\"sea\")\n" \
		+ "static func officer_day_tick() -> void:\n\tcalls.append(\"tick\")\n"
	var double := GDScript.new()
	double.source_code = calls_log
	_check(double.reload() == OK, "the skills double compiles")
	_make_run(15, 10, 10)
	double.calls = []
	SailingSimLib.skills_script_override = double
	_one_day()
	var sea_calls: Array = double.calls
	_check(sea_calls == ["sea", "tick"],
		"a sea day fires note_sea_day then officer_day_tick (got %s)" % str(sea_calls))
	# A port day-advance runs no growth (the seam sits in the at-sea branch).
	double.calls = []
	GameState.current_port = "lisbon"
	_one_day()
	var port_calls: Array = double.calls
	_check(port_calls.is_empty(),
		"a port day fires no sea-day growth (got %s)" % str(port_calls))
	SailingSimLib.skills_script_override = null
	GameState.current_port = null


# --- §4.5 step 1 consumption ----------------------------------------------

func _test_consumption() -> void:
	# 1. Worked case: 15 crew → ceil(15/5) = 3 provisions + 3 water.
	_make_run(15, 10, 10)
	_check(_one_day() == 1, "15-crew ledger day ticks once")
	_check(FleetLib.supplies("provisions") == 7,
		"15 crew eats exactly 3 provisions (10 → %d)" % FleetLib.supplies("provisions"))
	_check(FleetLib.supplies("water") == 7,
		"15 crew drinks exactly 3 water (10 → %d)" % FleetLib.supplies("water"))
	_check(SailingSimLib.last_day_shortfalls == {"provisions": false, "water": false},
		"fully supplied day records no shortfall (got %s)"
		% str(SailingSimLib.last_day_shortfalls))

	# 2. Ceiling: 16 crew → ceil(16/5) = 4 each.
	_make_run(16, 10, 10)
	_one_day()
	_check(FleetLib.supplies("provisions") == 6,
		"16 crew eats ceil(16/5)=4 provisions (10 → %d)"
		% FleetLib.supplies("provisions"))
	_check(FleetLib.supplies("water") == 6,
		"16 crew drinks ceil(16/5)=4 water (10 → %d)" % FleetLib.supplies("water"))

	# 3. Shortage: stock 2 < need 3 → clamped to 0, flag raised, water unaffected.
	_make_run(15, 2, 10)
	_one_day()
	_check(FleetLib.supplies("provisions") == 0,
		"short provisions clamp to 0 (got %d)" % FleetLib.supplies("provisions"))
	_check(SailingSimLib.last_day_shortfalls["provisions"] == true,
		"provisions shortfall flag set (got %s)"
		% str(SailingSimLib.last_day_shortfalls))
	_check(SailingSimLib.last_day_shortfalls["water"] == false,
		"water shortfall flag stays clear when water is sufficient")
	_check(FleetLib.supplies("water") == 7,
		"water still consumed normally during a provisions shortage (10 → %d)"
		% FleetLib.supplies("water"))

	# Shortage on both sides, and neither goes negative.
	_make_run(15, 1, 0)
	_one_day()
	_check(FleetLib.supplies("provisions") == 0 and FleetLib.supplies("water") == 0,
		"both supplies clamp at 0, never negative (%d/%d)"
		% [FleetLib.supplies("provisions"), FleetLib.supplies("water")])
	_check(SailingSimLib.last_day_shortfalls == {"provisions": true, "water": true},
		"both shortage flags set (got %s)" % str(SailingSimLib.last_day_shortfalls))

	# Draining is flagship-first, then fleet order (docs/40-* §4.2 pooling).
	_make_run(15, 4, 4)
	GameState.fleet[0]["provisions"] = 1
	GameState.fleet[0]["water"] = 1
	var second: Dictionary = FleetLib.new_ship("caravel", 0)
	second["provisions"] = 5
	second["water"] = 5
	GameState.fleet.append(second)
	_one_day()
	_check(int(GameState.fleet[0]["provisions"]) == 0,
		"flagship provisions drain first (got %d)" % int(GameState.fleet[0]["provisions"]))
	_check(int(GameState.fleet[1]["provisions"]) == 3,
		"the escort supplies the remaining 2 (5 → %d)"
		% int(GameState.fleet[1]["provisions"]))
	_check(FleetLib.supplies("provisions") == 3,
		"pooled 6 − need 3 = 3 (got %d)" % FleetLib.supplies("provisions"))


# --- §4.5 step 2 wages ----------------------------------------------------

func _test_wages() -> void:
	# 4. Crew 15, no officers → 15 × 2 = 30g/day ("−2g/crew/day", demo step 4).
	_make_run(15, 10, 10, 1000)
	_one_day()
	_check(GameState.gold == 970,
		"crew 15, no officers: −30g (1000 → %d)" % GameState.gold)
	_check(SailingSimLib.last_day_wages == 30,
		"last_day_wages == 30 (got %d)" % SailingSimLib.last_day_wages)

	# Officer Mateus Álvares (wage_daily 30) → 15 × 2 + 30 = 60g/day.
	_make_run(15, 10, 10, 1000)
	GameState.player["officers"] = ["off_mateus_alvares"]
	_check(CharacterLib.officer_wages() == 30,
		"off_mateus_alvares wage is 30g/day (got %d)" % CharacterLib.officer_wages())
	_one_day()
	_check(GameState.gold == 940,
		"crew 15 + officer 30: −60g (1000 → %d)" % GameState.gold)
	_check(SailingSimLib.last_day_wages == 60,
		"last_day_wages == crew×2 + Σ officer wages = 60 (got %d)"
		% SailingSimLib.last_day_wages)

	# No crew, one officer: only the officer is paid.
	_make_run(0, 0, 0, 100)
	GameState.player["officers"] = ["off_mateus_alvares"]
	_one_day()
	_check(GameState.gold == 70,
		"crew 0 + one officer: −30g only (100 → %d)" % GameState.gold)


# --- §4.5 step 2 clamp / §4.8.1 unpaid flag --------------------------------

func _test_gold_clamp() -> void:
	# 5. gold 10, wages 60 → clamp to 0, unpaid flag, gold_changed(0).
	_make_run(15, 10, 10, 10)
	GameState.player["officers"] = ["off_mateus_alvares"]
	var emitted: Array = []
	var listener := func(new_gold: int) -> void: emitted.append(new_gold)
	EventBus.gold_changed.connect(listener)
	_one_day()
	EventBus.gold_changed.disconnect(listener)

	_check(GameState.gold == 0,
		"gold 10 with wages 60 clamps to 0 (got %d)" % GameState.gold)
	_check(SailingSimLib.last_day_unpaid_wages == true,
		"unpaid_wages flag set (got %s)" % str(SailingSimLib.last_day_unpaid_wages))
	_check(emitted == [0],
		"gold_changed emits exactly once with the clamped 0 (got %s)" % str(emitted))

	# Exactly affordable: gold == wages is still a paid day (the doc says < 0).
	_make_run(15, 10, 10, 30)
	_one_day()
	_check(GameState.gold == 0 and not SailingSimLib.last_day_unpaid_wages,
		"gold exactly == wages is paid, not unpaid (%d, flag %s)"
		% [GameState.gold, str(SailingSimLib.last_day_unpaid_wages)])

	# No change → no spurious signal (crew 0, no officers).
	_make_run(0, 0, 0, 100)
	var quiet: Array = []
	var quiet_listener := func(new_gold: int) -> void: quiet.append(new_gold)
	EventBus.gold_changed.connect(quiet_listener)
	_one_day()
	EventBus.gold_changed.disconnect(quiet_listener)
	_check(quiet.is_empty() and GameState.gold == 100,
		"zero wages emit no gold_changed and leave gold alone (got %s)" % str(quiet))


# --- §4.9 crew = 0 edge ---------------------------------------------------

func _test_crew_zero() -> void:
	# 15-crew fixture, then empty the ship: need 0, no shortfall, no drain.
	_make_run(0, 5, 5)
	_check(_one_day() == 1, "crew-0 ledger day still ticks")
	_check(FleetLib.supplies("provisions") == 5 and FleetLib.supplies("water") == 5,
		"crew 0 consumes nothing (%d/%d)"
		% [FleetLib.supplies("provisions"), FleetLib.supplies("water")])
	_check(SailingSimLib.last_day_shortfalls == {"provisions": false, "water": false},
		"crew 0 raises no shortfall (got %s)" % str(SailingSimLib.last_day_shortfalls))

	# Empty fleet: same no-op, no crash.
	_make_run(0, 0, 0)
	GameState.fleet = []
	_check(_one_day() == 1 and GameState.gold == 1000,
		"empty fleet: day ticks with no consumption and no wages (gold %d)"
		% GameState.gold)


# --- §4.3 day boundary fires once (ledger now runs inside the tick) -------

func _test_clock_boundaries() -> void:
	# 6a. Twenty 0.05-day moves (speed 20) → exactly one day, i.e. one ledger run.
	_make_run(15, 100, 100, 1000)
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	var ticks: Array = []
	var counter := func(day: int) -> void: ticks.append(day)
	EventBus.day_advanced.connect(counter)

	for step in 20:
		var target := Vector2i(
			OPEN_CELL.x + (1 if step % 2 == 0 else 0),
			OPEN_CELL.y
		)
		_check(SailingSimLib.try_move(target, DataLoader.map),
			"20-move sequence: move %d succeeds" % (step + 1))
	_check(ticks == [2],
		"20 moves at speed 20 emit day_advanced exactly once for day 2 (got %s)"
		% str(ticks))
	_check(FleetLib.supplies("provisions") == 97,
		"the single tick ran the ledger once: 100 − 3 = %d"
		% FleetLib.supplies("provisions"))
	_check(GameState.gold == 970,
		"the single tick paid wages once: 1000 − 30 = %d" % GameState.gold)

	# 6b. Three exact thirds → one day.
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 10
	ticks.clear()
	_check(SailingSimLib.advance_clock(1.0 / 3.0) == 0, "first third: no tick")
	_check(SailingSimLib.advance_clock(1.0 / 3.0) == 0, "second third: no tick")
	_check(SailingSimLib.advance_clock(1.0 / 3.0) == 1, "third third: one tick")
	_check(ticks == [11],
		"three thirds emit day_advanced once for day 11 (got %s)" % str(ticks))
	_check(FleetLib.supplies("provisions") == 94,
		"one ledger run across the three thirds (100 → %d)"
		% FleetLib.supplies("provisions"))

	# 6c. A batch spanning 3 boundaries runs the ledger 3 times, in order.
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 20
	ticks.clear()
	_check(SailingSimLib.advance_clock(3.5) == 3, "3.5 days ticks 3 times")
	_check(ticks == [21, 22, 23],
		"day_advanced fired for 21, 22, 23 (got %s)" % str(ticks))
	_check(FleetLib.supplies("provisions") == 85,
		"3 ticks consumed 9 provisions (100 → %d)"
		% FleetLib.supplies("provisions"))
	_check(GameState.gold == 850,
		"3 ticks paid 3 × 30g (940 → %d)" % GameState.gold)
	EventBus.day_advanced.disconnect(counter)


# --- Display formats (20-* §4.3 amended, 40-* §4.4 amended, 10-* §3.1) -----

## The wall-clock text, the knot conversion and the per-kind days-of-supply —
## the display layer over the unchanged simulation numbers.
func _test_display_formats() -> void:
	_make_run(15, 60, 45, 1000)

	# Wall clock: `floor(fraction × 1440)`; the sub-1.0 clamp tops out at 23:59.
	GameState.world["clock_fraction"] = 0.0
	_check(SailingSimLib.time_of_day_minutes() == 0
		and SailingSimLib.clock_text() == "00:00",
		"clock_text: fraction 0 renders 00:00")
	GameState.world["clock_fraction"] = 0.5
	_check(SailingSimLib.time_of_day_minutes() == 720
		and SailingSimLib.clock_text() == "12:00",
		"clock_text: half a day renders 12:00")
	GameState.world["clock_fraction"] = 0.999999999
	_check(SailingSimLib.time_of_day_minutes() == 1439
		and SailingSimLib.clock_text() == "23:59",
		"clock_text: the sub-1.0 clamp renders 23:59, never 24:00")
	GameState.world["clock_fraction"] = 0.0

	# Knots: tiles/day × 5 nm ÷ 24 h, one decimal — base 16/20/24.
	_check(SailingSimLib.knots_text_for(16) == "3.3"
		and SailingSimLib.knots_text_for(20) == "4.2"
		and SailingSimLib.knots_text_for(24) == "5.0",
		"knots_text_for: base 16/20/24 tiles/day = 3.3/4.2/5.0 kn")
	# The fair-weather full-crew caravel run above is the §4.4 worked case
	# (effective speed 20), so the HUD figure is 4.2 kn.
	_check(SailingSimLib.speed_knots_text() == "4.2",
		"speed_knots_text: the worked-case fleet shows 4.2 kn")

	# Per-kind days-of-supply: need = ceil(15/5) = 3 → 60 food = 20 days,
	# 45 water = 15 days (the §4.10 numbers, via the single implementation).
	_check(SailingSimLib.kind_supply_days("provisions") == 20,
		"kind_supply_days: 60 provisions at need 3 = 20 days")
	_check(SailingSimLib.kind_supply_days("water") == 15,
		"kind_supply_days: 45 water at need 3 = 15 days")
	# No crew → 0 (nothing consumed; the sailing gate refuses anyway), the
	# same convention as the pooled `supply_days`.
	GameState.fleet[0]["crew"] = 0
	_check(SailingSimLib.kind_supply_days("provisions") == 0,
		"kind_supply_days: no crew reads 0 days")
	GameState.fleet[0]["crew"] = 15


# --- §4.4 speed table (re-asserted: it is a T7 done-when) -----------------

func _test_speed_table() -> void:
	# fair / sail / full crew / seamanship 10 → 20.
	_make_run(15)
	_check(SailingSimLib.effective_speed() == 20,
		"fair, sail, full crew, seamanship 10 → 20 (got %d)"
		% SailingSimLib.effective_speed())
	_check(is_equal_approx(SailingSimLib.move_cost(), 0.05),
		"move_cost 1/20 = 0.05 days (got %.4f)" % SailingSimLib.move_cost())

	# calm / sail → floor(20 × 0.8) = 16.
	_make_run(15, 0, 0, 1000, "calm")
	_check(SailingSimLib.effective_speed() == 16,
		"calm sail: floor(20 × 0.8) = 16 (got %d)" % SailingSimLib.effective_speed())

	# storm / sail (Phase 8 headway): COU 10 → floor(20 × 1.5 × 0.5) = 15.
	_make_run(15, 0, 0, 1000, "storm")
	_check(SailingSimLib.effective_speed() == 15,
		"storm sail at COU 10: floor(20 × 1.5 × 0.5) = 15 (got %d)"
		% SailingSimLib.effective_speed())
	# …at COU 100 the retention is ×0.6125: floor(20 × 1.5 × 0.6125) = 18.
	_make_run(15, 0, 0, 1000, "storm", 10, 60, 100)
	_check(SailingSimLib.effective_speed() == 18,
		"storm sail at COU 100: floor(20 × 1.5 × 0.6125) = 18 (got %d)"
		% SailingSimLib.effective_speed())

	# Skeleton crew 1/15 → factor floor 0.25 → floor(20 × 0.25) = 5, never 0.
	_make_run(1)
	_check(is_equal_approx(SailingSimLib.crew_factor(), 0.25),
		"skeleton crew 1/15 → factor 0.25 (got %.4f)" % SailingSimLib.crew_factor())
	_check(SailingSimLib.effective_speed() == 5,
		"skeleton crew floors to max(1, floor(20 × 0.25)) = 5 (got %d)"
		% SailingSimLib.effective_speed())
	# Same in the worst wind (calm): floor(20 × 0.8 × 0.25) = 4, never 0.
	_make_run(1, 0, 0, 1000, "calm")
	_check(SailingSimLib.effective_speed() == 4,
		"skeleton crew in calm is floor(20 × 0.8 × 0.25) = 4 (got %d)"
		% SailingSimLib.effective_speed())

	# Slowest hull: caravel 20 + nao 16 → the escort is captain-less (the
	# default roster has no appointments), so its §4.4 scan value is
	# 16 × 0.8 = 12.8 → 12 (the `40-*` §4.4 hook; the appointed-captain
	# restore is pinned in test_movement).
	_make_run(15)
	GameState.fleet.append(FleetLib.new_ship("nao", 25))
	_check(FleetLib.slowest_speed() == 16,
		"fleet slowest hull is the nao's 16 (got %d)" % FleetLib.slowest_speed())
	_check(SailingSimLib.effective_speed() == 12,
		"the captain-less escort drags the scan to 12 (got %d)"
		% SailingSimLib.effective_speed())

	# Oar ignores wind (wind_factor 1.0 in every weather — the class table),
	# but the Phase-8 storm headway still applies: storm at COU 10 gives
	# floor(24 × 1.0(wind) × 1.5 × 0.5) = 18; calm has no headway → 24.
	_make_run(40, 0, 0, 1000, "storm")
	GameState.fleet[0] = FleetLib.new_ship("galley", 40)
	_check(SailingSimLib.wind_factor("storm", "oar") == 1.0
		and SailingSimLib.wind_factor("calm", "oar") == 1.0,
		"oar wind_factor is 1.0 in storm and calm alike (the class table)")
	_check(SailingSimLib.effective_speed() == 12,
		"oar in storm at COU 10: floor(24 × 1.0 × 0.5 × 1.0333) = 12 (got %d)"
		% SailingSimLib.effective_speed())
	# …and the calm case has no headway term.
	GameState.world["weather"] = "calm"
	_check(SailingSimLib.effective_speed() == 24,
		"oar in calm is the full 24 (got %d)" % SailingSimLib.effective_speed())

	# Hybrid in strong wind: galleon (base 20, crew_min 40) → floor(20 × 1.1) = 22.
	_make_run(40, 0, 0, 1000, "strong")
	GameState.fleet[0] = FleetLib.new_ship("galleon", 40)
	_check(SailingSimLib.effective_speed() == 22,
		"hybrid strong: floor(20 × 1.1) = 22 (got %d)" % SailingSimLib.effective_speed())


# --- §4.4 Phase-6 heading pipeline (docs/20-* §4.4, §4.14–§4.17) -----------

## The direction-aware speed core, at the suite level: the rescaled speed
## data, the heading-aware `move_cost(heading)`, the full §4.4 pipeline
## (wind × direction × current × crew × seamanship × trim), and the ledger's
## second weather roll persisting `world.wind_dir`.
func _test_heading_pipeline() -> void:
	# The §2.0 sweep: ShipType.speed is tiles/day at 5 nm — {16, 20, 24}.
	var speeds := {}
	for ship_id in ["latin", "sloop", "caravel", "galley", "brigantine",
			"nao", "carrack", "galleon"]:
		speeds[ship_id] = int(DataLoader.get_ship_type(ship_id)["speed"])
	_check(speeds["latin"] == 16 and speeds["nao"] == 16
		and speeds["carrack"] == 16,
		"the slow hulls sail 16 tiles/day (got %s)" % str(speeds))
	_check(speeds["sloop"] == 20 and speeds["caravel"] == 20
		and speeds["galleon"] == 20,
		"the mid hulls sail 20 tiles/day")
	_check(speeds["galley"] == 24 and speeds["brigantine"] == 24,
		"the fast hulls sail 24 tiles/day")
	var data_min := 99
	for ship_id in speeds:
		data_min = mini(data_min, speeds[ship_id])
	_check(data_min == 16,
		"the §7.3 speed range starts at 16 tiles/day (got %d)" % data_min)

	# move_cost(heading) with an explicit easterly wind (fair weather).
	_make_run(15)
	GameState.world["wind_dir"] = "E"
	_check(is_equal_approx(SailingSimLib.move_cost("E"), 0.1),
		"into-wind move_cost(E) == 1/floor(20 × 0.5) = 0.1 (got %.4f)"
		% SailingSimLib.move_cost("E"))
	_check(is_equal_approx(SailingSimLib.move_cost("W"), 1.0 / 26.0),
		"running move_cost(W) == 1/floor(20 × 1.3) (got %.4f)"
		% SailingSimLib.move_cost("W"))
	_check(is_equal_approx(SailingSimLib.move_cost("N"), 0.05),
		"beam move_cost(N) == 1/20 (got %.4f)" % SailingSimLib.move_cost("N"))
	# The parameterless form (the HUD/docking average) is beam for both new
	# terms — exactly its W3 value.
	_check(is_equal_approx(SailingSimLib.move_cost(), 0.05),
		"heading-less move_cost() stays 1/20 (got %.4f)"
		% SailingSimLib.move_cost())

	# The default-path claim: with the pinned defaults (wind E) a BEAM move
	# costs exactly what it cost at the W3 gate.
	var fraction := float(GameState.world["clock_fraction"])
	_check(SailingSimLib.try_move(Vector2i(OPEN_CELL.x, OPEN_CELL.y + 1),
		DataLoader.map), "a beam step succeeds")
	var beam_cost := float(GameState.world["clock_fraction"]) - fraction
	_check(is_equal_approx(beam_cost, 0.05),
		"a beam try_move costs the W3 0.05 days (got %.4f)" % beam_cost)

	# The full §4.4 pipeline multiplies trim too: full sail, running, fair →
	# floor(20 × 1.0 × 1.3 × 1.15 × 1.0333) = floor(30.887) = 30 (the +10/300
	# seamanship bonus rides the pipeline since Phase 8).
	GameState.world["sail_trim"] = "full"
	_check(SailingSimLib.effective_speed("W") == 30,
		"full-sail running speed floor(20 × 1.3 × 1.15 × 1.0333) = 30 (got %d)"
		% SailingSimLib.effective_speed("W"))
	# …and reefed into the wind: floor(20 × 0.5 × 0.75) = floor(7.5) = 7.
	GameState.world["sail_trim"] = "reefed"
	_check(SailingSimLib.effective_speed("E") == 7,
		"reefed into-wind speed floor(20 × 0.5 × 0.75) = 7 (got %d)"
		% SailingSimLib.effective_speed("E"))

	# Ledger step 3 is a two-part roll: a day tick leaves both halves in the
	# world block — the strength id and an 8-dir wind_dir.
	_make_run(15, 10, 10, 1000, "fair")
	SailingSimLib.set_weather_seed(7)
	_one_day()
	_check(str(GameState.world["weather"]) in SailingSimLib.WEATHER_OUTCOMES,
		"step 3 part 1 wrote the strength id (%s)"
		% str(GameState.world["weather"]))
	_check(SailingSimLib.COMPASS_DIRS.has(str(GameState.world["wind_dir"])),
		"step 3 part 2 wrote an 8-dir wind_dir (%s)"
		% str(GameState.world["wind_dir"]))


# --- §4.3 / §4.5 in-port day advance shares the ledger --------------------


func _test_port_day() -> void:
	# 8. Dock at Lisbon: the port-day amendment (20-* §4.5, 2026-11-02) — a
	# docked ledger day consumes NOTHING (supplies are bought ashore; the
	# no-shortfall shape resets the §4.9 counters) while wages still run.
	_make_run(15, 10, 10, 1000)
	GameState.current_port = "lisbon"
	_check(SailingSimLib.in_port(), "in_port() is true while docked")
	_check(SailingSimLib.advance_port_day() == 1,
		"advance_port_day() ticks one day")
	_check(FleetLib.supplies("provisions") == 10 and FleetLib.supplies("water") == 10,
		"in-port day consumes nothing (got %d/%d)"
		% [FleetLib.supplies("provisions"), FleetLib.supplies("water")])
	_check(GameState.gold == 970,
		"in-port day pays 30g wages (1000 → %d)" % GameState.gold)

	# The doc's literal path also works: a port action calls advance_clock(1.0)
	# — same amendment: wages yes, consumption no.
	GameState.gold = 1000
	SailingSimLib.advance_clock(1.0)
	_check(GameState.gold == 970 and FleetLib.supplies("provisions") == 10,
		"advance_clock(1.0) in port pays but does not consume (gold %d, provisions %d)"
		% [GameState.gold, FleetLib.supplies("provisions")])

	# At sea, in_port() is false — the T9 branch point.
	GameState.current_port = null
	_check(not SailingSimLib.in_port(), "in_port() is false at sea")


# --- T7 boundary: steps 3–6 (T8/T9) --------------------------------------
# T8 landed the weather roll at step 3 and T9 landed morale/fail states/mutiny
# at steps 4–6, so the T7-era "no mutation" contract is superseded by the exact
# §4.8.1 deltas (T9 owns the full matrix in `tools/test_morale.tscn`). What
# this T7 suite still proves: step 3 writes `world.weather`, step 4 applies the
# *documented* delta (−1 at sea, +5 in port), and no transient ledger key leaks
# into the §8.1 save block.

func _test_no_weather_or_morale_mutation() -> void:
	# 9. One fully-supplied sea day: §4.8.1 "at sea, fully supplied −1".
	_make_run(15, 10, 10, 1000, "fair")
	GameState.morale = 63
	SailingSimLib.set_weather_seed(7)
	SailingSimLib.last_day_storm = false
	_one_day()
	_check(str(GameState.world["weather"]) in SailingSimLib.WEATHER_OUTCOMES,
		"ledger step 3 rolls a §4.7 weather outcome (T8) (got '%s')"
		% str(GameState.world["weather"]))
	var expected := 63 - 1 - (5 if SailingSimLib.last_day_storm else 0)
	_check(GameState.morale == expected,
		"step 4 applies the §4.8.1 sea delta (−1, −5 on a storm day): 63 → %d (got %d)"
		% [expected, GameState.morale])
	_check(not GameState.world.has("last_ledger_day"),
		"no transient ledger keys leak into GameState.world")

	# Same in port: step 4 applies the §4.8.1 "+5, up to the port cap 80".
	_make_run(15, 10, 10, 1000)
	GameState.current_port = "lisbon"
	GameState.morale = 63
	SailingSimLib.advance_port_day()
	_check(GameState.morale == 68,
		"in-port day applies the +5 (63 → %d)" % GameState.morale)


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
