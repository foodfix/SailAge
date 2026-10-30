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

## Open-water cell whose 8 neighbours are passable (same fixture as T6).
const OPEN_CELL := Vector2i(20, 20)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/p1_mediterranean.txt", DataLoader.map_legend
	)
	_check(ok, "map loads for the movement-driven clock checks (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	_test_constants()
	_test_consumption()
	_test_wages()
	_test_gold_clamp()
	_test_crew_zero()
	_test_clock_boundaries()
	_test_speed_table()
	_test_port_day()
	_test_no_weather_or_morale_mutation()
	_report()


# --- Fixtures --------------------------------------------------------------

## Caravel (speed 10, crew_min 15, crew_max 45) at full crew, base stats, fair
## weather → effective speed exactly 10 (§4.4 worked case; Phase-4 ×2 speeds,
## `10-*` §7.3). The hold defaults to
## empty; each test loads what it needs.
func _make_run(
	crew: int = 15, provisions: int = 0, water: int = 0,
	gold: int = 1000, weather: String = "fair"
) -> void:
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
	_check(SailingSimLib.SIGHTING_RADIUS == 24,
		"§5 sighting_radius == 24 (got %d)" % SailingSimLib.SIGHTING_RADIUS)
	_check(SailingSimLib.DISCOVERY_RADIUS == 18,
		"§5 discovery_radius == 18 (got %d)" % SailingSimLib.DISCOVERY_RADIUS)
	# The engine value lives in `DiscoverySight.RADIUS` (70-* §4.4); §5 is the
	# single documented constants location, so the two must never drift.
	_check(DiscoveryLib.RADIUS == SailingSimLib.DISCOVERY_RADIUS,
		"DiscoverySight.RADIUS (%d) == §5 discovery_radius (%d)"
		% [DiscoveryLib.RADIUS, SailingSimLib.DISCOVERY_RADIUS])
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

	# §4.11 / `70-*` §4.4: the discovery range check is wrap-aware on x and
	# takes the grid width from the loaded legend (128 on this suite's p1
	# fixture), so the seam is 1 tile wide, not 127.
	_check(DiscoveryLib.map_width() == 128,
		"discovery wrap uses the loaded legend width (got %d)"
		% DiscoveryLib.map_width())
	_check(DiscoveryLib.chebyshev_to_cell(Vector2i(127, 10), Vector2i(0, 10)) == 1,
		"x=127 and x=0 are 1 tile apart across the seam (got %d)"
		% DiscoveryLib.chebyshev_to_cell(Vector2i(127, 10), Vector2i(0, 10)))
	_check(DiscoveryLib.chebyshev_to_cell(Vector2i(64, 10), Vector2i(0, 10)) == 64,
		"the far side of the seam stays far (got %d)"
		% DiscoveryLib.chebyshev_to_cell(Vector2i(64, 10), Vector2i(0, 10)))


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
	# 6a. Ten 0.1-day moves (speed 10) → exactly one day, i.e. one ledger run.
	_make_run(15, 100, 100, 1000)
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	var ticks: Array = []
	var counter := func(day: int) -> void: ticks.append(day)
	EventBus.day_advanced.connect(counter)

	for step in 10:
		var target := Vector2i(
			OPEN_CELL.x + (1 if step % 2 == 0 else 0),
			OPEN_CELL.y
		)
		_check(SailingSimLib.try_move(target, DataLoader.map),
			"10-move sequence: move %d succeeds" % (step + 1))
	_check(ticks == [2],
		"10 moves at speed 10 emit day_advanced exactly once for day 2 (got %s)"
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


# --- §4.4 speed table (re-asserted: it is a T7 done-when) -----------------

func _test_speed_table() -> void:
	# fair / sail / full crew / seamanship 10 → 10.
	_make_run(15)
	_check(SailingSimLib.effective_speed() == 10,
		"fair, sail, full crew, seamanship 10 → 10 (got %d)"
		% SailingSimLib.effective_speed())
	_check(is_equal_approx(SailingSimLib.move_cost(), 0.1),
		"move_cost 1/10 = 0.1 days (got %.4f)" % SailingSimLib.move_cost())

	# calm / sail → floor(10 × 0.8) = 8.
	_make_run(15, 0, 0, 1000, "calm")
	_check(SailingSimLib.effective_speed() == 8,
		"calm sail: floor(10 × 0.8) = 8 (got %d)" % SailingSimLib.effective_speed())

	# storm / sail → floor(10 × 1.5) = 15.
	_make_run(15, 0, 0, 1000, "storm")
	_check(SailingSimLib.effective_speed() == 15,
		"storm sail: floor(10 × 1.5) = 15 (got %d)" % SailingSimLib.effective_speed())

	# Skeleton crew 1/15 → factor floor 0.25 → floor(10 × 0.25) = 2, never 0.
	_make_run(1)
	_check(is_equal_approx(SailingSimLib.crew_factor(), 0.25),
		"skeleton crew 1/15 → factor 0.25 (got %.4f)" % SailingSimLib.crew_factor())
	_check(SailingSimLib.effective_speed() == 2,
		"skeleton crew floors to max(1, floor(10 × 0.25)) = 2 (got %d)"
		% SailingSimLib.effective_speed())
	# Same in the worst wind (calm): floor(10 × 0.8 × 0.25) = 2, never 0.
	_make_run(1, 0, 0, 1000, "calm")
	_check(SailingSimLib.effective_speed() == 2,
		"skeleton crew in calm is floor(10 × 0.8 × 0.25) = 2 (got %d)"
		% SailingSimLib.effective_speed())

	# Slowest hull: caravel 10 + nao 8 → base 8.
	_make_run(15)
	GameState.fleet.append(FleetLib.new_ship("nao", 25))
	_check(FleetLib.slowest_speed() == 8,
		"fleet slowest hull is the nao's 8 (got %d)" % FleetLib.slowest_speed())
	_check(SailingSimLib.effective_speed() == 8,
		"fleet speed uses the slowest hull → 8 (got %d)"
		% SailingSimLib.effective_speed())

	# Oar ignores wind: galley (base 12, crew_min 40) in storm → floor(12 × 1.0) = 12.
	_make_run(40, 0, 0, 1000, "storm")
	GameState.fleet[0] = FleetLib.new_ship("galley", 40)
	_check(SailingSimLib.effective_speed() == 12,
		"oar in storm is wind-independent: floor(12 × 1.0) = 12 (got %d)"
		% SailingSimLib.effective_speed())
	# …and matches the calm case exactly.
	GameState.world["weather"] = "calm"
	_check(SailingSimLib.effective_speed() == 12,
		"oar in calm is the same 12 (got %d)" % SailingSimLib.effective_speed())

	# Hybrid in strong wind: galleon (base 10, crew_min 40) → floor(10 × 1.1) = 11.
	_make_run(40, 0, 0, 1000, "strong")
	GameState.fleet[0] = FleetLib.new_ship("galleon", 40)
	_check(SailingSimLib.effective_speed() == 11,
		"hybrid strong: floor(10 × 1.1) = 11 (got %d)" % SailingSimLib.effective_speed())


# --- §4.3 / §4.5 in-port day advance shares the ledger --------------------

func _test_port_day() -> void:
	# 8. Dock at Lisbon: the day advance consumes and pays exactly like at sea.
	_make_run(15, 10, 10, 1000)
	GameState.current_port = "lisbon"
	_check(SailingSimLib.in_port(), "in_port() is true while docked")
	_check(SailingSimLib.advance_port_day() == 1,
		"advance_port_day() ticks one day")
	_check(FleetLib.supplies("provisions") == 7 and FleetLib.supplies("water") == 7,
		"in-port day consumes 3 + 3 (got %d/%d)"
		% [FleetLib.supplies("provisions"), FleetLib.supplies("water")])
	_check(GameState.gold == 970,
		"in-port day pays 30g wages (1000 → %d)" % GameState.gold)

	# The doc's literal path also works: a port action calls advance_clock(1.0).
	GameState.gold = 1000
	SailingSimLib.advance_clock(1.0)
	_check(GameState.gold == 970 and FleetLib.supplies("provisions") == 4,
		"advance_clock(1.0) in port consumes and pays too (gold %d, provisions %d)"
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
