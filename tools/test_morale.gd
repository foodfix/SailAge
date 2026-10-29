extends Node
## T9 acceptance tests (docs/IMPLEMENT-Phase1.md T9; docs/20-* §4.5, §4.8–§4.9,
## §6; docs/40-* §4.4; docs/50-* §4.2–§4.3; docs/80-* §4.5, §4.7). Headless:
##
##   godot --headless res://tools/test_morale.tscn
##
## Exits 0 when every check passes, 1 otherwise. Every random check is seeded
## through `SailingSim.set_weather_seed()` (weather) and
## `SailingSim.set_mutiny_seed()` (mutiny, a **separate** stream), so the
## printed numbers are reproducible forever.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")
const WorldScene := preload("res://scenes/world/world_map.tscn")

## Rest-of-map open water (x = 60 > 6): storm chance 0.10, so a fail-state test
## is not disturbed by Atlantic storms. (72,48) and its neighbours are sea.
const CALM_CELL := Vector2i(72, 48)

## §4.9: game over on the 7th consecutive shortfall day.
const LIMIT := 7
## §4.8.3: `1 − 0.75⁵ = 0.7627` within this tolerance (§4.7 style).
const MUTINY_TOLERANCE := 0.02
## Sample sizes: 4000 trials of 5 days each.
const MUTINY_TRIALS := 4000
const MUTINY_DAYS := 5
## Pinned seeds (any fixed value works; these make the printed rates stable).
const WEATHER_SEED := 20261029
const MUTINY_SEED := 90210

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/p1_mediterranean.txt", DataLoader.map_legend
	)
	_check(ok, "map loads for the movement/passability fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	_check(DataLoader.map.is_passable(CALM_CELL),
		"fixture cell %s is open sea" % str(CALM_CELL))

	_test_constants()
	_test_starvation_path()
	_test_scurvy_path()
	_test_counter_reset()
	_test_crew_loss_formula()
	_test_mutiny_probability()
	_test_mutiny_resolutions()
	_test_desertion()
	_test_morale_deltas()
	_test_xp()
	_test_sinking()
	_test_dialog_order()
	_test_world_queue_order()
	_test_hud_mutiny_modal()
	_test_world_game_over_overlay()
	_test_gameover_screen()
	_test_hud_morale_tiers()
	_report()


# --- Fixtures --------------------------------------------------------------

## Caravel (speed 5, durability 90, capacity 120, crew_max 45) at `crew` crew on
## open water, morale 70 unless overridden, ample gold so wages never clamp.
func _make_run(
	crew: int = 15,
	provisions: int = 50,
	water: int = 50,
	gold: int = 100000,
	morale: int = 70,
	cell: Vector2i = CALM_CELL,
	leadership: int = 10,
	ship_ids: Array = ["caravel"]
) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": leadership, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.fleet = []
	for ship_id in ship_ids:
		var ship: Dictionary = FleetLib.new_ship(str(ship_id), 0)
		# Supplies only on the flagship unless an escort fixture fills its own.
		ship["provisions"] = provisions if GameState.fleet.is_empty() else 0
		ship["water"] = water if GameState.fleet.is_empty() else 0
		GameState.fleet.append(ship)
	GameState.fleet[0]["crew"] = crew
	GameState.day = 1
	GameState.gold = gold
	GameState.morale = morale
	GameState.current_port = null
	GameState.known_ports = []
	GameState.explored_tiles = {}
	GameState.world = {
		"position": {"x": cell.x, "y": cell.y},
		"clock_fraction": 0.0,
		"weather": "fair",
	}
	SailingSimLib.reset_ledger_state()


## One ledger day through the production clock path.
func _one_day() -> int:
	return SailingSimLib.advance_clock(1.0)


## Records every `game_over` reason emitted while connected. Returns
## `[reasons: Array, listener: Callable]`; `_stop_game_over_log` disconnects it.
func _start_game_over_log() -> Array:
	var reasons: Array = []
	var listener := func(reason: String) -> void: reasons.append(reason)
	EventBus.game_over.connect(listener)
	return [reasons, listener]


func _stop_game_over_log(log: Array) -> void:
	EventBus.game_over.disconnect(log[1])


func _tile(x: int, y: int) -> void:
	GameState.world["position"] = {"x": x, "y": y}


# --- §5 / §4.8–§4.9 constants ---------------------------------------------

func _test_constants() -> void:
	_check(SailingSimLib.MORALE_PORT_CAP == 80, "morale_port_cap == 80")
	_check(SailingSimLib.STARVATION_LIMIT_DAYS == 7, "starvation_limit_days == 7")
	_check(SailingSimLib.MUTINY_THRESHOLD == 20, "mutiny_threshold == 20")
	_check(is_equal_approx(SailingSimLib.MUTINY_CHANCE_PER_DAY, 0.25),
		"mutiny_chance_per_day == 0.25")
	_check(SailingSimLib.DESERTION_THRESHOLD == 40, "desertion_threshold == 40")
	_check(is_equal_approx(SailingSimLib.DESERTION_FRACTION, 0.10),
		"desertion_fraction == 0.10")
	_check(SailingSimLib.MORALE_SEA_DAILY == -1 and SailingSimLib.MORALE_SHORTFALL == -5
		and SailingSimLib.MORALE_STORM == -5 and SailingSimLib.MORALE_UNPAID_WAGES == -5,
		"§4.8.1 deltas are −1 / −5 / −5 / −5")
	_check(SailingSimLib.MORALE_PORT_DAILY == 5, "§4.8.1 in-port delta is +5")
	_check(SailingSimLib.MUTINY_PAY_PER_CREW == 20 and
		is_equal_approx(SailingSimLib.MUTINY_SUPPRESS_FRACTION, 0.30),
		"§4.8.3 pay = crew×20 / suppress = 30% crew")
	_check(SailingSimLib.MUTINY_PAY_MORALE == 50
		and SailingSimLib.MUTINY_SUPPRESS_MORALE == 40
		and SailingSimLib.MUTINY_FIZZLE_MORALE == 5,
		"§4.8.3 morale outcomes 50 / 40 / +5")
	_check(SailingSimLib.DIALOG_ORDER["weather"] < SailingSimLib.DIALOG_ORDER["mutiny"]
		and SailingSimLib.DIALOG_ORDER["mutiny"] < SailingSimLib.DIALOG_ORDER["desertion"]
		and SailingSimLib.DIALOG_ORDER["desertion"] < SailingSimLib.DIALOG_ORDER["greeting"],
		"§4.7 dialog order: weather → mutiny → desertion → greeting")
	_check(SailingSimLib.DIALOG_ORDER["weather"] < SailingSimLib.DIALOG_ORDER["sinking"]
		and SailingSimLib.DIALOG_ORDER["sinking"] < SailingSimLib.DIALOG_ORDER["mutiny"],
		"a ship-loss report sits after its storm and before the crew's reaction")

	# A sinking report sorts right after the weather entries that caused it.
	_check(_dialog_keys(SailingSimLib.sort_dialogs([
		{"kind": "greeting", "key": "world.arrive"},
		{"kind": "mutiny", "key": "world.mutiny.text"},
		{"kind": "sinking", "key": "world.ship_lost"},
		{"kind": "weather", "key": "world.storm_damage"},
	])) == ["world.storm_damage", "world.ship_lost", "world.mutiny.text",
		"world.arrive"],
		"weather damage → ship lost → mutiny → greeting")


# --- 1. Starvation path ----------------------------------------------------

func _test_starvation_path() -> void:
	# Caravel, 15 crew, provisions 0, water ample, rest-of-map (few storms).
	# Freeze the weather to "strong" via a seed search so no storm morale −5 or
	# damage interferes with the pure starvation arithmetic.
	_make_run(15, 0, 200, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var start_day: int = GameState.day
	var log := _start_game_over_log()
	var crew_trace: Array[int] = []
	var counter_trace: Array[int] = []
	for day in LIMIT:
		_one_day()
		crew_trace.append(FleetLib.total_crew())
		counter_trace.append(SailingSimLib.starvation_days)
	_stop_game_over_log(log)

	print("  starvation: crew per day %s, counter %s, game over %s" % [
		str(crew_trace), str(counter_trace), str(log[0])
	])
	_check(counter_trace == [1, 2, 3, 4, 5, 6, 7],
		"the starvation counter increments once per shortfall day (got %s)"
		% str(counter_trace))
	_check(log[0] == ["starvation"],
		"game_over('starvation') fires exactly once, on day %d (got %s)"
		% [LIMIT, str(log[0])])
	_check(GameState.day - start_day == LIMIT,
		"it lands on the 7th day tick, not 6 or 8 (%d ticks)" % (GameState.day - start_day))
	# Crew per §4.9: max(1, floor(crew × 0.05)) lost each day.
	var expected_crew := 15
	var crew_ok := true
	for index in LIMIT:
		expected_crew -= maxi(1, int(floor(float(expected_crew) * 0.05)))
		expected_crew = maxi(1, expected_crew)
		if crew_trace[index] != expected_crew:
			crew_ok = false
	_check(crew_ok, "crew follows max(1, floor(crew×0.05)) floored at 1 (got %s, expected 14,13,12,11,10,9,8)"
		% str(crew_trace))
	_check(crew_trace == [14, 13, 12, 11, 10, 9, 8],
		"the 15-crew trace is exactly 14,13,12,11,10,9,8 (got %s)" % str(crew_trace))

	# No further tick after the game over (§4.9): the clock is frozen.
	var day_at_death := GameState.day
	var crew_at_death := FleetLib.total_crew()
	var later := SailingSimLib.advance_clock(3.0)
	_check(later == 0 and GameState.day == day_at_death
		and FleetLib.total_crew() == crew_at_death,
		"a dead run does not tick further days (ticks %d, day %d)" % [later, GameState.day])

	# The morale −5 of the shortfall row is applied by step 4 exactly once a day
	# (not doubled by step 5): 70 → 65 → 60 → … −5 per shortfall day.
	_make_run(15, 0, 200, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	_one_day()
	_check(GameState.morale == 64,
		"a provisions-short sea day costs −1 −5 = −6, once: 70 → %d" % GameState.morale)


# --- 2. Scurvy mirror ------------------------------------------------------

func _test_scurvy_path() -> void:
	_make_run(15, 200, 0, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var start_day: int = GameState.day
	var log := _start_game_over_log()
	var counter_trace: Array[int] = []
	for day in LIMIT:
		_one_day()
		counter_trace.append(SailingSimLib.scurvy_days)
	_stop_game_over_log(log)

	print("  scurvy: counter %s, game over %s" % [str(counter_trace), str(log[0])])
	_check(counter_trace == [1, 2, 3, 4, 5, 6, 7],
		"the scurvy counter increments once per water-short day (got %s)"
		% str(counter_trace))
	_check(log[0] == ["scurvy"],
		"game_over('scurvy') fires exactly once (got %s)" % str(log[0]))
	_check(GameState.day - start_day == LIMIT,
		"scurvy ends the run on the 7th tick (%d ticks)" % (GameState.day - start_day))
	_check(SailingSimLib.starvation_days == 0,
		"a water-only shortage never advances the starvation counter (got %d)"
		% SailingSimLib.starvation_days)

	# Both short at once: the starved counter is checked first (`20-*` §4.9
	# order), so the reason is "starvation" — and neither counter is doubled.
	_make_run(15, 0, 0, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var both_log := _start_game_over_log()
	for day in LIMIT:
		_one_day()
	_stop_game_over_log(both_log)
	_check(both_log[0] == ["starvation"],
		"both short → the documented check order reports 'starvation' (got %s)"
		% str(both_log[0]))
	_check(SailingSimLib.scurvy_days == LIMIT,
		"…while the scurvy counter also reached 7 (got %d)"
		% SailingSimLib.scurvy_days)


# --- 3. Counter reset ------------------------------------------------------

func _test_counter_reset() -> void:
	# 3 shortfall days, then 2 fully-supplied days, then shortfalls again: the
	# counter restarts, so the run dies on the 7th *consecutive* shortfall day.
	_make_run(15, 0, 200, 100000, 90)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var log := _start_game_over_log()
	for day in 3:
		_one_day()
	_check(SailingSimLib.starvation_days == 3,
		"3 shortfall days → counter 3 (got %d)" % SailingSimLib.starvation_days)

	# Two supplied days (refill each morning so step 1 never runs dry).
	for day in 2:
		GameState.fleet[0]["provisions"] = 50
		_one_day()
	_check(SailingSimLib.starvation_days == 0,
		"the first fully-supplied day resets the counter (got %d)"
		% SailingSimLib.starvation_days)

	var day_before := GameState.day
	for day in 6:
		GameState.fleet[0]["provisions"] = 0  # run dry again
		_one_day()
	_check(not SailingSimLib.is_game_over(),
		"6 shortfall days after the reset do not end the run (counter %d)"
		% SailingSimLib.starvation_days)
	_check(SailingSimLib.starvation_days == 6,
		"…the restarted counter is at 6 (got %d)" % SailingSimLib.starvation_days)
	GameState.fleet[0]["provisions"] = 0
	_one_day()
	_stop_game_over_log(log)
	_check(SailingSimLib.game_over_reason == "starvation" and GameState.day == day_before + 7,
		"the 7th consecutive shortfall day ends it (%d ticks, reason '%s')"
		% [GameState.day - day_before, SailingSimLib.game_over_reason])
	_check(log[0] == ["starvation"],
		"…and only then does game_over fire (got %s)" % str(log[0]))


# --- 4. Crew-loss formula + the 1-crew floor -------------------------------

func _test_crew_loss_formula() -> void:
	# crew 100 → 5 lost per starved day (floor(5.0)).
	_make_run(100, 0, 200, 100000, 90)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	_one_day()
	_check(FleetLib.total_crew() == 95,
		"crew 100 loses max(1, floor(100×0.05)) = 5 (got %d)" % FleetLib.total_crew())

	# crew 1 → floor(0.05) = 0 → the max(1, …) floor would take the last sailor,
	# but §6 forbids crew 0, so 1 stays 1 and the timer still runs out.
	_make_run(1, 0, 200, 100000, 90)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var log := _start_game_over_log()
	for day in LIMIT:
		_one_day()
	_stop_game_over_log(log)
	_check(FleetLib.total_crew() == 1,
		"crew 1 cannot be reduced below 1 (§6) (got %d)" % FleetLib.total_crew())
	_check(log[0] == ["starvation"],
		"…and starvation still fires at 7 days (§4.9 'regardless') (got %s)"
		% str(log[0]))
	_check(SailingSimLib.CREW_FLOOR == 1, "the crew floor constant is 1")


# --- 5. Mutiny probability -------------------------------------------------

## `1 − 0.75^5` (0.25 chance per day over 5 days).
func _mutiny_closed_form() -> float:
	return 1.0 - pow(1.0 - SailingSimLib.MUTINY_CHANCE_PER_DAY, MUTINY_DAYS)


func _test_mutiny_probability() -> void:
	var expected := _mutiny_closed_form()
	print("  closed form: 1 − 0.75^5 = %.4f" % expected)
	_check(absf(expected - 0.7627) < 0.00005,
		"1 − 0.75^5 = 0.7627 to 4 dp (got %.4f)" % expected)

	# Empirical: morale 10, leadership 10 (multiplier 1.0) → 0.25/day.
	SailingSimLib.set_mutiny_seed(MUTINY_SEED)
	var hits := 0
	for trial in MUTINY_TRIALS:
		_make_run(15, 50, 50, 100000, 10)
		var mutinied := false
		for day in MUTINY_DAYS:
			# Drive only step 6's RNG: the offer is resolved (suppress) each day
			# so a pending modal never blocks the next roll, and step 4's −1 is
			# cancelled by resetting morale before the roll.
			GameState.morale = 10
			_one_day()
			if not SailingSimLib.pending_mutiny.is_empty():
				mutinied = true
				break
		if mutinied:
			hits += 1
	var rate := float(hits) / float(MUTINY_TRIALS)
	print("  empirical: %d / %d trials mutinied within %d days = %.4f (expected %.4f)" % [
		hits, MUTINY_TRIALS, MUTINY_DAYS, rate, expected
	])
	# Tolerance-based per docs/20-* §4.8.1 clarification 3: a bare `>= 0.76`
	# gate is flaky (SE 0.0067 at n=4000 fails it ~1/3 of the time by chance).
	_check(absf(rate - expected) <= MUTINY_TOLERANCE,
		"empirical P(mutiny within 5 days) matches %.4f within ±%.2f (got %.4f)"
		% [expected, MUTINY_TOLERANCE, rate])
	# Sanity floor: catches an implementation that never (or rarely) fires,
	# which a pure |rate − expected| check with a large tolerance could miss.
	_check(rate > 0.70,
		"…and mutiny actually fires at a plausible rate (> 0.70, got %.4f)" % rate)

	# Threshold is strict (`< 20`). Rather than assume a day's weather (a storm
	# adds another −5 to step 4), this observes the *post-step-4* morale on 200
	# real sea days and asserts the invariant: a day that checks the roll at 20
	# or above never raises a mutiny, and at least one such day exists.
	_make_run(15, 50, 50, 100000, 21)
	SailingSimLib.set_mutiny_seed(MUTINY_SEED)
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var at_or_above := 0
	var wrongly_mutinied := 0
	for day in 200:
		GameState.morale = 21  # step 4 lands on 20, or 15 after a storm
		_one_day()
		if SailingSimLib.pending_mutiny.is_empty():
			if GameState.morale >= SailingSimLib.MUTINY_THRESHOLD:
				at_or_above += 1
		elif GameState.morale >= SailingSimLib.MUTINY_THRESHOLD:
			wrongly_mutinied += 1
		if not SailingSimLib.pending_mutiny.is_empty():
			SailingSimLib.resolve_mutiny_suppress()
	_check(at_or_above > 0,
		"%d observed days checked the roll at morale ≥ 20" % at_or_above)
	_check(wrongly_mutinied == 0,
		"no mutiny at morale ≥ 20 (%d wrongly mutinied days)" % wrongly_mutinied)
	_make_run(15, 50, 50, 100000, 20)
	_check(not SailingSimLib.mutiny_is_possible(),
		"mutiny_is_possible() is false at morale exactly 20")
	GameState.morale = 19
	_check(SailingSimLib.mutiny_is_possible(),
		"mutiny_is_possible() is true at morale 19")
	_check(_mutiny_days_in(19, 60) > 0,
		"morale 19 does mutiny (got %d events)" % _mutiny_days_in(19, 60))

	# Never in port, however low the morale.
	_make_run(15, 50, 50, 100000, 0)
	GameState.current_port = "lisbon"
	SailingSimLib.set_mutiny_seed(MUTINY_SEED)
	var port_hits := 0
	for day in 40:
		GameState.morale = 0
		SailingSimLib.advance_port_day()
		if not SailingSimLib.pending_mutiny.is_empty():
			port_hits += 1
	_check(port_hits == 0, "no mutiny in port across 40 days at morale 0 (got %d)" % port_hits)
	_check(not SailingSimLib.mutiny_is_possible(),
		"mutiny_is_possible() is false while docked")

	# Leadership lowers the chance: leadership 30 → ×0.90.
	_make_run(15, 50, 50, 100000, 10, CALM_CELL, 30)
	_check(is_equal_approx(CharacterLib.mutiny_multiplier(), 0.90),
		"leadership 30 → mutiny multiplier 0.90 (got %.4f)"
		% CharacterLib.mutiny_multiplier())
	var high_lead := _mutiny_rate(30, 1000)
	print("  leadership 30: mutiny rate %.4f (expected %.4f)" % [
		high_lead, 1.0 - pow(1.0 - 0.25 * 0.90, MUTINY_DAYS)
	])
	_check(absf(high_lead - (1.0 - pow(1.0 - 0.25 * 0.90, MUTINY_DAYS))) <= MUTINY_TOLERANCE,
		"leadership 30 scales the chance by ×0.90 (got %.4f)" % high_lead)


## Number of mutiny events raised in `days` days whose post-step-4 morale is
## `morale` (each resolved so the modal never blocks the next roll). The
## supplied sea day costs −1, so the value is re-pinned from `morale + 1`.
func _mutiny_days_in(morale: int, days: int) -> int:
	_make_run(15, 50, 50, 100000, morale + 1)
	SailingSimLib.set_mutiny_seed(MUTINY_SEED + morale)
	var events := 0
	for day in days:
		GameState.morale = morale + 1
		_one_day()
		if not SailingSimLib.pending_mutiny.is_empty():
			events += 1
			SailingSimLib.resolve_mutiny_suppress()
	return events


func _mutiny_rate(leadership: int, trials: int) -> float:
	SailingSimLib.set_mutiny_seed(MUTINY_SEED + leadership)
	var hits := 0
	for trial in trials:
		_make_run(15, 50, 50, 100000, 10, CALM_CELL, leadership)
		for day in MUTINY_DAYS:
			GameState.morale = 10
			_one_day()
			if not SailingSimLib.pending_mutiny.is_empty():
				hits += 1
				break
	return float(hits) / float(trials)


# --- 6. Mutiny resolutions -------------------------------------------------

func _test_mutiny_resolutions() -> void:
	# Pay: gold ≥ crew×20 → gold − crew×20, morale 50.
	_make_run(15, 50, 50, 1000, 10)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	var offer := SailingSimLib.mutiny_offer()
	_check(offer["crew"] == 15 and offer["cost"] == 300 and offer["can_pay"],
		"offer: crew 15, cost 15×20 = 300, affordable (got %s)" % str(offer))
	_check(SailingSimLib.resolve_mutiny_pay(), "resolve_mutiny_pay() succeeds")
	_check(GameState.gold == 700, "gold 1000 − 300 = 700 (got %d)" % GameState.gold)
	_check(GameState.morale == 50, "morale = 50 (got %d)" % GameState.morale)
	_check(SailingSimLib.pending_mutiny.is_empty(), "the offer is cleared")
	_check(not SailingSimLib.resolve_mutiny_pay(),
		"a second pay with no pending offer is a no-op")

	# Pay disabled when gold < cost.
	_make_run(15, 50, 50, 299, 10)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	offer = SailingSimLib.mutiny_offer()
	_check(not offer["can_pay"], "gold 299 < 300 disables Pay (got %s)" % str(offer))
	_check(not SailingSimLib.resolve_mutiny_pay() and GameState.gold == 299,
		"paying anyway leaves gold untouched (%d)" % GameState.gold)
	_check(GameState.morale == 10, "…and morale untouched (%d)" % GameState.morale)

	# Exactly the cost is affordable (`≥`).
	_make_run(15, 50, 50, 300, 10)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	_check(SailingSimLib.resolve_mutiny_pay() and GameState.gold == 0,
		"gold exactly == cost pays to 0 (got %d)" % GameState.gold)

	# Suppress: crew − max(1, floor(crew×0.30)), morale 40.
	_make_run(20, 50, 50, 0, 10)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	_check(SailingSimLib.resolve_mutiny_suppress(), "resolve_mutiny_suppress() succeeds")
	_check(FleetLib.total_crew() == 14,
		"crew 20 − floor(20×0.30)=6 → 14 (got %d)" % FleetLib.total_crew())
	_check(GameState.morale == 40, "morale = 40 (got %d)" % GameState.morale)

	# Suppress keeps at least 1 crew (crew 2 → loss max(1, 0) = 1 → 1).
	_make_run(2, 50, 50, 0, 10)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	SailingSimLib.resolve_mutiny_suppress()
	_check(FleetLib.total_crew() == 1,
		"suppress at crew 2 leaves 1, not 0 (got %d)" % FleetLib.total_crew())

	# Fizzle: crew 1 and no gold → neither option is possible.
	_make_run(1, 50, 50, 0, 10)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	offer = SailingSimLib.mutiny_offer()
	_check(not offer["can_pay"] and not offer["can_suppress"] and offer["can_fizzle"],
		"crew 1 + no gold: neither pay nor suppress is possible (got %s)" % str(offer))
	_check(not SailingSimLib.resolve_mutiny_pay(), "pay returns false")
	_check(not SailingSimLib.resolve_mutiny_suppress(), "suppress returns false")
	SailingSimLib.resolve_mutiny_fizzle()
	_check(GameState.morale == 15, "fizzle raises morale by 5: 10 → %d" % GameState.morale)
	_check(SailingSimLib.pending_mutiny.is_empty(), "the fizzle clears the offer")
	_check(FleetLib.total_crew() == 1, "fizzle costs no crew")

	# Fizzle clamps at 100.
	_make_run(1, 50, 50, 0, 99)
	SailingSimLib.pending_mutiny = SailingSimLib.mutiny_offer()
	SailingSimLib.resolve_mutiny_fizzle()
	_check(GameState.morale == 100, "fizzle clamps at 100 (got %d)" % GameState.morale)

	# The ledger raises the modal through the dialog buffer (§4.7): one entry per
	# hit, none on a miss, across 60 days.
	_make_run(15, 50, 50, 100000, 10)
	SailingSimLib.set_mutiny_seed(MUTINY_SEED)
	var hits := 0
	var queued := 0
	for day in 60:
		GameState.morale = 10
		_one_day()
		var entries := SailingSimLib.take_last_day_dialogs()
		var mutinies := 0
		for entry in entries:
			if str(entry.get("kind", "")) == "mutiny" and entry.get("key", "") == "world.mutiny.text":
				mutinies += 1
		if not SailingSimLib.pending_mutiny.is_empty():
			hits += 1
			_check(mutinies == 1,
				"a mutiny day %d queues exactly one world.mutiny.text modal (got %d)"
				% [day + 1, mutinies])
			SailingSimLib.resolve_mutiny_pay()
		else:
			_check(mutinies == 0,
				"a non-mutiny day %d queues no mutiny modal (got %d)" % [day + 1, mutinies])
		queued += mutinies
	_check(hits > 0 and queued == hits,
		"60 days produced %d mutinies through the modal (%d queued)" % [hits, queued])


# --- 7. Desertion ----------------------------------------------------------

func _test_desertion() -> void:
	# morale 39 (< 40), crew 15 → max(1, floor(15×0.10)) = 1.
	_make_run(15, 50, 50, 1000, 39)
	_check(SailingSimLib.apply_desertion() == 1,
		"morale 39, crew 15 → 1 deserter")
	_check(FleetLib.total_crew() == 14, "crew 15 → 14 (got %d)" % FleetLib.total_crew())

	# morale 40 (the threshold itself) → nobody leaves.
	_make_run(15, 50, 50, 1000, 40)
	_check(SailingSimLib.apply_desertion() == 0,
		"morale 40 is at the threshold: no desertion (the check is < 40)")

	# crew 100 → 10.
	_make_run(100, 50, 50, 1000, 39)
	_check(SailingSimLib.apply_desertion() == 10,
		"crew 100 → loses floor(100×0.10) = 10 (got %d)" % FleetLib.total_crew())

	# crew 1 → cannot drop below 1.
	_make_run(1, 50, 50, 1000, 0)
	_check(SailingSimLib.apply_desertion() == 0,
		"crew 1 is protected by the §6 floor (lost 0)")

	# Leadership halves: leadership 20 → ×0.95 → floor(15 × 0.10 × 0.95) = 1
	# both times, so use crew 100 to see the multiplier: 100 × 0.10 × 0.95 = 9.5
	# → 9 (vs 10 at leadership 10).
	_make_run(100, 50, 50, 1000, 39, CALM_CELL, 20)
	_check(is_equal_approx(CharacterLib.desertion_multiplier(), 0.95),
		"leadership 20 → desertion multiplier 0.95 (got %.4f)"
		% CharacterLib.desertion_multiplier())
	var lost := SailingSimLib.apply_desertion()
	_check(lost == 9,
		"leadership 20: floor(100×0.10×0.95) = 9 (got %d)" % lost)
	_check(FleetLib.total_crew() == 91, "crew 100 → 91 (got %d)" % FleetLib.total_crew())

	# Leadership 10 baseline for the same crew: 10.
	_make_run(100, 50, 50, 1000, 39, CALM_CELL, 10)
	_check(SailingSimLib.apply_desertion() == 10,
		"leadership 10: floor(100×0.10×1.00) = 10 → the multiplier is really applied")

	# The world scene reports it as `world.desertion` with the count (§4.8.2).
	var logged := _dialog_keys(SailingSimLib.sort_dialogs([
		{"kind": "desertion", "key": "world.desertion", "values": {"count": 9}},
	]))
	_check(logged == ["world.desertion"], "the desertion message key is world.desertion")


func _dialog_keys(entries: Array) -> Array:
	var keys: Array = []
	for entry in entries:
		keys.append(str(entry.get("key", "")))
	return keys


# --- 8. Morale deltas ------------------------------------------------------

func _test_morale_deltas() -> void:
	# At sea, fully supplied, non-storm: −1.
	_make_run(15, 50, 50, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	_one_day()
	_check(GameState.morale == 69 and SailingSimLib.last_morale_delta == -1,
		"at sea fully supplied: −1 (70 → %d, delta %d)"
		% [GameState.morale, SailingSimLib.last_morale_delta])

	# + provisions short: −1 −5 = −6.
	_make_run(15, 0, 200, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	_one_day()
	_check(GameState.morale == 64 and SailingSimLib.last_morale_delta == -6,
		"provisions short stacks −5: −6 (70 → %d, delta %d)"
		% [GameState.morale, SailingSimLib.last_morale_delta])

	# + storm: −1 −5 −5 = −11.
	_make_run(15, 0, 200, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_storm())
	_one_day()
	_check(SailingSimLib.last_day_storm, "the fixture seed really rolls a storm")
	_check(GameState.morale == 59 and SailingSimLib.last_morale_delta == -11,
		"short + storm: −11 (70 → %d, delta %d)"
		% [GameState.morale, SailingSimLib.last_morale_delta])

	# + unpaid wages: the full stacked case −1 −5 (provisions) −5 (storm) −5
	# (unpaid) = −16.
	_make_run(15, 0, 200, 0, 70)
	SailingSimLib.set_weather_seed(_seed_for_storm())
	_one_day()
	_check(SailingSimLib.last_day_unpaid_wages,
		"gold 0 with crew 15 really is an unpaid day")
	_check(GameState.morale == 54 and SailingSimLib.last_morale_delta == -16,
		"stacked short + storm + unpaid: −16 (70 → %d, delta %d)"
		% [GameState.morale, SailingSimLib.last_morale_delta])

	# Water short is the mirror of provisions short: −6.
	_make_run(15, 200, 0, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	_one_day()
	_check(SailingSimLib.last_morale_delta == -6,
		"water short stacks −5 too (delta %d)" % SailingSimLib.last_morale_delta)

	# In port: +5, and the at-sea rows do not apply (no −1, no shortfall).
	_make_run(15, 0, 0, 100000, 70)
	GameState.current_port = "lisbon"
	SailingSimLib.set_weather_seed(_seed_for_storm())
	SailingSimLib.advance_port_day()
	_check(SailingSimLib.last_morale_delta == 5,
		"in port the delta is +5 even when short and stormy (delta %d)"
		% SailingSimLib.last_morale_delta)
	_check(GameState.morale == 75, "70 → 75 (got %d)" % GameState.morale)

	# Port cap: 79 → 80 (not 84); 80 → 80.
	_make_run(15, 50, 50, 100000, 79)
	GameState.current_port = "lisbon"
	SailingSimLib.advance_port_day()
	_check(GameState.morale == 80, "in port 79 → 80 (capped) (got %d)" % GameState.morale)
	SailingSimLib.advance_port_day()
	_check(GameState.morale == 80, "in port 80 → 80 (got %d)" % GameState.morale)

	# The cap is a ceiling on the *gain*: it never lifts a low value to 80.
	_make_run(15, 50, 50, 100000, 10)
	GameState.current_port = "lisbon"
	SailingSimLib.advance_port_day()
	_check(GameState.morale == 15, "in port 10 → 15, not capped up (got %d)"
		% GameState.morale)
	# …and it never suppresses an at-sea decrease below it.
	_make_run(15, 0, 200, 100000, 55)
	SailingSimLib.set_weather_seed(_seed_for_storm())
	_one_day()
	_check(GameState.morale == 44, "at-sea loss below the cap applies fully (55 → %d)"
		% GameState.morale)

	# Clamp at 0 (never negative).
	_make_run(15, 0, 0, 0, 3)
	SailingSimLib.set_weather_seed(_seed_for_storm())
	_one_day()
	_check(GameState.morale == 0, "morale clamps at 0 (got %d)" % GameState.morale)

	# The port cap is a ceiling on port *gains*: a fixture already above 80 does
	# not climb further (§4.8.1 "up to the port cap 80"), and the general 0–100
	# clamp is asserted on the fizzle path (morale 99 → 100) below.
	_make_run(15, 50, 50, 100000, 99)
	GameState.current_port = "lisbon"
	SailingSimLib.advance_port_day()
	_check(GameState.morale == 99,
		"in port at 99 the gain is capped: stays 99 (got %d)" % GameState.morale)
	_check(SailingSimLib.MORALE_MAX == 100, "the general clamp ceiling is 100")


# --- 9. XP ----------------------------------------------------------------

func _test_xp() -> void:
	# +2 per sea day.
	_make_run(15, 50, 50, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	_one_day()
	_check(CharacterLib.current_xp() == 2,
		"a sea day awards +2 XP (got %d)" % CharacterLib.current_xp())
	_one_day()
	_check(CharacterLib.current_xp() == 4, "two sea days → 4 XP (got %d)"
		% CharacterLib.current_xp())

	# 0 per port day-advance (docs/50-* §4.3 "not in-port day advances").
	_make_run(15, 50, 50, 100000, 70)
	GameState.current_port = "lisbon"
	SailingSimLib.advance_port_day()
	_check(CharacterLib.current_xp() == 0,
		"a port day-advance awards no XP (got %d)" % CharacterLib.current_xp())
	SailingSimLib.advance_clock(1.0)
	_check(CharacterLib.current_xp() == 0,
		"advance_clock in port also awards no XP (got %d)" % CharacterLib.current_xp())


# --- 10. Sinking -----------------------------------------------------------

func _test_sinking() -> void:
	# Single ship at durability 0 → game_over("sunk").
	_make_run(15, 50, 50, 100000, 70)
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	GameState.fleet[0]["durability"] = 0
	var log := _start_game_over_log()
	_one_day()
	_stop_game_over_log(log)
	_check(log[0] == ["sunk"], "single ship at 0 → game_over('sunk') (got %s)"
		% str(log[0]))
	_check(SailingSimLib.game_over_reason == "sunk" and SailingSimLib.is_game_over(),
		"the sim records the reason (got '%s')" % SailingSimLib.game_over_reason)
	_check(GameState.day == 2,
		"the sinking day still completes its tick (day %d)" % GameState.day)

	# No further game over for the same run.
	log = _start_game_over_log()
	SailingSimLib.advance_clock(2.0)
	_stop_game_over_log(log)
	_check(log[0].is_empty(), "a dead run never emits a second game over (got %s)"
		% str(log[0]))

	# Flagship at 0 with an escort: the escort takes command, crew/supplies move.
	_make_run(15, 50, 50, 100000, 70, CALM_CELL, 10, ["caravel", "nao"])
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var flagship: Dictionary = GameState.fleet[0]
	flagship["durability"] = 0
	flagship["cargo"] = {"wine": 10}
	GameState.fleet[1]["provisions"] = 0
	GameState.fleet[1]["water"] = 0
	log = _start_game_over_log()
	_one_day()
	_stop_game_over_log(log)
	_check(log[0].is_empty(), "flagship sinking with an escort is not a game over (got %s)"
		% str(log[0]))
	_check(GameState.fleet.size() == 1 and
		str(GameState.fleet[0].get("ship_type_id", "")) == "nao",
		"the nao becomes fleet[0] (fleet %s)" % str(GameState.fleet))
	_check(FleetLib.flagship()["crew"] == 15,
		"crew relocates to the new flagship (got %d)" % int(FleetLib.flagship()["crew"]))
	_check(FleetLib.supplies("provisions") > 0,
		"provisions relocate up to capacity (got %d)" % FleetLib.supplies("provisions"))
	_check(int(FleetLib.held("wine")) == 10,
		"cargo relocates (got %d wine)" % FleetLib.held("wine"))
	var keys := _dialog_keys(SailingSimLib.take_last_day_dialogs())
	_check(keys == ["world.flagship_lost"],
		"the loss reports world.flagship_lost (got %s)" % str(keys))

	# Overflow is lost, not silently kept: a latin (capacity 30) cannot hold a
	# caravel's 200+200 supplies.
	_make_run(15, 50, 50, 100000, 70, CALM_CELL, 10, ["caravel", "latin"])
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	GameState.fleet[0]["durability"] = 0
	_one_day()
	_check(GameState.fleet.size() == 1 and
		str(GameState.fleet[0].get("ship_type_id", "")) == "latin",
		"the latin takes command (fleet size %d)" % GameState.fleet.size())
	var moved := FleetLib.supplies("provisions") + FleetLib.supplies("water")
	_check(moved <= FleetLib.ship_stat(GameState.fleet[0], "capacity"),
		"relocated supplies fit the new hull's capacity (%d ≤ %d)"
		% [moved, FleetLib.ship_stat(GameState.fleet[0], "capacity")])
	_check(moved < 400, "…so the overflow is lost (%d of 400 units moved)" % moved)

	# A non-flagship at 0 is lost with its cargo; the run continues.
	_make_run(15, 50, 50, 100000, 70, CALM_CELL, 10, ["caravel", "nao"])
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	GameState.fleet[1]["cargo"] = {"wine": 20}
	GameState.fleet[1]["durability"] = 0
	log = _start_game_over_log()
	_one_day()
	_stop_game_over_log(log)
	_check(log[0].is_empty() and GameState.fleet.size() == 1,
		"an escort sinking is not a game over (fleet %d)" % GameState.fleet.size())
	_check(FleetLib.held("wine") == 0, "its cargo is lost (§4.4)")
	keys = _dialog_keys(SailingSimLib.take_last_day_dialogs())
	_check(keys == ["world.ship_lost"],
		"the loss reports world.ship_lost (got %s)" % str(keys))


# --- 11. §4.7 dialog queue order ------------------------------------------

func _test_dialog_order() -> void:
	# Deliberately enqueued out of order; sort_dialogs must restore §4.7's.
	var entries := [
		{"kind": "greeting", "key": "world.arrive", "values": {"port": "Lisbon", "day": 9}},
		{"kind": "desertion", "key": "world.desertion", "values": {"count": 2}},
		{"kind": "mutiny", "key": "world.mutiny.text"},
		{"kind": "weather", "key": "world.storm_damage", "values": {"name": "Caravel", "points": 5}},
	]
	_check(_dialog_keys(SailingSimLib.sort_dialogs(entries)) == [
		"world.storm_damage", "world.mutiny.text", "world.desertion", "world.arrive",
	], "sort_dialogs restores weather → mutiny → desertion → greeting (got %s)"
		% str(_dialog_keys(SailingSimLib.sort_dialogs(entries))))

	# Stable within a kind: two weather entries keep their raising order.
	var two_weather := [
		{"kind": "weather", "key": "world.storm_notice"},
		{"kind": "weather", "key": "world.storm_damage"},
	]
	_check(_dialog_keys(SailingSimLib.sort_dialogs(two_weather))
		== ["world.storm_notice", "world.storm_damage"],
		"same-kind entries keep their original order (stable sort)")

	# The HUD shows them one at a time, in exactly that order.
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)
	var shown: Array = []
	hud.show_dialogs(SailingSimLib.sort_dialogs(entries))
	var guard := 0
	while hud.has_modal() and guard < 8:
		guard += 1
		var dialog = hud.current_dialog()
		if dialog == null:
			break
		shown.append(dialog.name)
		dialog.close()
	_check(shown.size() == 4,
		"all four dialogs are shown (§4.7) (got %d: %s)" % [shown.size(), str(shown)])
	_check(not hud.has_modal(), "the queue drains to nothing")
	var all_modals := 0
	for child in hud.get_node("ModalHost").get_children():
		if child.is_open():
			all_modals += 1
	_check(all_modals == 0, "never two modals at once (open modals: %d)" % all_modals)
	host.queue_free()

	# A day tick with a storm + low morale produces the weather entry first and
	# the mutiny entry second in the sim's own buffer.
	_make_run(15, 50, 50, 100000, 5)
	SailingSimLib.set_weather_seed(_seed_for_storm())
	SailingSimLib.set_mutiny_seed(_seed_for_mutiny_hit())
	# `_seed_for_mutiny_hit()` makes the first roll a hit, so the first tick
	# queues the mutiny entry; the buffer is drained (shown once) by the world
	# scene, which `_test_world_queue_order` asserts end to end.
	GameState.morale = 5
	_one_day()
	var buffer := SailingSimLib.take_last_day_dialogs()
	_check(buffer.size() == 1 and str(buffer[0].get("kind", "")) == "mutiny",
		"a mutiny day queues exactly one sim dialog entry (got %s)" % str(buffer))
	_check(SailingSimLib.take_last_day_dialogs().is_empty(),
		"take_last_day_dialogs() empties the buffer (shown only once)")


# --- 11b. §4.7 order through the world scene (S3) -------------------------

## The real wiring: a day tick that rolls a storm **and** a mutiny, immediately
## followed by a port entry with desertion, must show
## weather damage → mutiny → desertion → greeting, one at a time.
func _test_world_queue_order() -> void:
	_make_run(15, 50, 50, 100000, 5)
	GameState.world["position"] = {"x": _sea_beside_lisbon().x, "y": _sea_beside_lisbon().y}
	GameState.known_ports = []
	GameState.explored_tiles = {}
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)
	var hud = world.get_node("HUDLayer/HUD")
	_check(hud != null, "the world scene hosts the §4.7 dialog queue")

	var shown: Array[String] = []
	var drain := func() -> void:
		var guard := 0
		while hud.has_modal() and guard < 16:
			guard += 1
			var dialog = hud.current_dialog()
			if dialog == null:
				break
			shown.append(dialog.message_text())
			# Resolve the mutiny through the HUD's own buttons, exactly like a
			# player would; other modals are plain messages.
			if dialog.has_method("cancel"):
				dialog.accept()
			else:
				dialog.close()

	# 1. A storm + mutiny day tick.
	SailingSimLib.set_weather_seed(_seed_for_storm())
	SailingSimLib.set_mutiny_seed(_seed_for_mutiny_hit())
	GameState.morale = 5
	SailingSimLib.advance_clock(1.0)
	drain.call()
	_check(shown.size() >= 3,
		"the storm+mutiny tick shows weather notice, weather damage, mutiny (%d dialogs)"
		% shown.size())
	var weather_first := shown.size() >= 1 and shown[0] == I18n.fmt(
		"world.storm_notice", {"weather": I18n.t_key("world.weather.storm")})
	_check(weather_first, "weather damage comes first in the queue (%s)"
		% (shown[0] if not shown.is_empty() else "<none>"))
	var mutiny_at := -1
	for index in shown.size():
		if shown[index] == I18n.t_key("world.mutiny.text"):
			mutiny_at = index
	_check(mutiny_at > 0, "the mutiny modal follows the weather entries (index %d)" % mutiny_at)
	_check(shown[shown.size() - 1] == I18n.t_key("world.mutiny.text")
		or mutiny_at == shown.size() - 1,
		"…and is the last of the day-tick batch (got %s)" % str(shown))

	# 2. Port entry at morale 39: desertion then greeting.
	shown.clear()
	GameState.morale = 39
	var crew_before := FleetLib.total_crew()
	world._enter_port("lisbon")
	drain.call()
	_check(shown.size() == 2,
		"port entry at morale 39 shows desertion + greeting (%d dialogs)" % shown.size())
	if shown.size() == 2:
		_check(shown[0].begins_with("Low morale"),
			"desertion is shown before the arrival greeting (%s)" % shown[0])
		_check(shown[1].begins_with("Arrived at"),
			"the greeting comes last (%s)" % shown[1])
	_check(GameState.current_port == "lisbon",
		"the entry still completes (current_port %s)" % str(GameState.current_port))
	_check(FleetLib.total_crew() == crew_before - maxi(
		1, int(floor(float(crew_before) * 0.10))),
		"crew %d → %d on this entry (desertion applied once, got %d)"
		% [crew_before, crew_before - maxi(1, int(floor(float(crew_before) * 0.10))),
			FleetLib.total_crew()])
	_check(not hud.has_modal(), "the queue is fully drained")
	host.queue_free()


## True while `world`'s HUD still has a modal open or queued.
func hud_has_modal(world) -> bool:
	var hud = world.get_node_or_null("HUDLayer/HUD")
	return hud != null and hud.has_modal()


## (8,57) beside Lisbon (7,57): the entry tile used by the queue test.
func _sea_beside_lisbon() -> Vector2i:
	return Vector2i(7, 57) + Vector2i(1, 0)


# --- 11c. HUD mutiny modal (§4.8.3, §4.7) ---------------------------------

func _test_hud_mutiny_modal() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)
	var choices: Array = []
	hud.mutiny_choice.connect(func(choice: String) -> void: choices.append(choice))

	# Affordable: both buttons are live and labelled from ui_strings.
	hud.show_dialogs([{
		"kind": "mutiny", "key": "world.mutiny.text", "mutiny": true,
		"offer": {"crew": 15, "cost": 300, "can_pay": true, "can_suppress": true},
	}])
	var dialog = hud.current_dialog()
	_check(dialog != null and dialog.name == "MutinyDialog",
		"the mutiny entry shows a confirm dialog (%s)" % str(dialog))
	var confirm: Button = dialog.get_node("Center/Panel/Margin/Body/Footer/Confirm")
	var cancel: Button = dialog.get_node("Center/Panel/Margin/Body/Footer/Cancel")
	_check(confirm.text == I18n.fmt("world.mutiny.pay", {"gold": 300})
		and not confirm.disabled,
		"Pay is enabled and shows the price (%s)" % confirm.text)
	_check(cancel.text == I18n.t_key("world.mutiny.suppress") and not cancel.disabled,
		"Suppress is enabled (%s)" % cancel.text)
	_check(dialog.message_text() == I18n.t_key("world.mutiny.text"),
		"the modal body is world.mutiny.text")
	confirm.pressed.emit()
	_check(choices == ["pay"], "pressing Pay emits mutiny_choice('pay') (got %s)"
		% str(choices))
	_check(not hud.has_modal(), "the mutiny modal closes on a choice")

	# Unaffordable but suppressible: Pay is disabled, Suppress is not.
	choices.clear()
	hud.show_dialogs([{
		"kind": "mutiny", "key": "world.mutiny.text", "mutiny": true,
		"offer": {"crew": 15, "cost": 300, "can_pay": false, "can_suppress": true},
	}])
	dialog = hud.current_dialog()
	confirm = dialog.get_node("Center/Panel/Margin/Body/Footer/Confirm")
	cancel = dialog.get_node("Center/Panel/Margin/Body/Footer/Cancel")
	_check(confirm.disabled and not cancel.disabled,
		"Pay is disabled when gold < crew×20 (disabled=%s)" % str(confirm.disabled))
	# Enter on a disabled Pay is the "impossible choice" path → fizzle.
	dialog.accept()
	_check(choices == ["fizzle"],
		"an impossible Pay routes to the §4.8.3 fizzle (got %s)" % str(choices))

	# Neither possible (crew 1, no gold): both disabled, Suppress → fizzle.
	choices.clear()
	hud.show_dialogs([{
		"kind": "mutiny", "key": "world.mutiny.text", "mutiny": true,
		"offer": {"crew": 1, "cost": 20, "can_pay": false, "can_suppress": false},
	}])
	dialog = hud.current_dialog()
	confirm = dialog.get_node("Center/Panel/Margin/Body/Footer/Confirm")
	cancel = dialog.get_node("Center/Panel/Margin/Body/Footer/Cancel")
	_check(confirm.disabled and cancel.disabled,
		"both buttons are disabled when neither option is possible")
	dialog.cancel()
	_check(choices == ["fizzle"],
		"an impossible Suppress also fizzles (got %s)" % str(choices))
	host.queue_free()


# --- 11d. S9 over the world scene (EventBus.game_over) --------------------

func _test_world_game_over_overlay() -> void:
	_make_run(15, 50, 50, 100000, 70)
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)

	_check(world.get_node_or_null("GameOverLayer") == null,
		"no S9 overlay before a game over")
	# Queue a message first: the death must take over the screen, not stack.
	var hud = world.get_node("HUDLayer/HUD")
	hud.show_dialog("world.storm_notice", {"weather": "storm"})
	_check(hud.has_modal(), "a report is queued before the death")
	# Starve to death through the production ledger.
	SailingSimLib.set_weather_seed(_seed_for_first_non_storm())
	var guard := 0
	while not SailingSimLib.is_game_over() and guard < 20:
		guard += 1
		GameState.fleet[0]["provisions"] = 0
		SailingSimLib.advance_clock(1.0)
	var overlay = world.get_node_or_null("GameOverLayer/GameOverScreen")
	_check(overlay != null,
		"EventBus.game_over makes the world scene show S9 (got %s)" % str(overlay))
	if overlay != null:
		_check(overlay.is_open(), "the overlay is open")
		_check(overlay.reason_text() == I18n.fmt(
			"gameover.reason", {"reason": I18n.t_key("gameover.starvation")}),
			"it reports the starvation reason (%s)" % overlay.reason_text())
		_check((overlay.get_parent() as CanvasLayer).layer
			> (world.get_node("HUDLayer") as CanvasLayer).layer,
			"the overlay sits above the HUD")
		_check(not hud_has_modal(world),
			"S9 takes the screen alone: pending dialogs are cleared (§4.7)")
		# A second game_over signal must not stack a second S9.
		EventBus.game_over.emit("starvation")
		var overlays := 0
		for child in world.get_node("GameOverLayer").get_children():
			if child.name == "GameOverScreen":
				overlays += 1
		_check(overlays == 1, "a repeated signal never stacks a second S9 (%d)" % overlays)
	host.queue_free()


# --- 12. S9 game over screen ----------------------------------------------

func _test_gameover_screen() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var screen = GameOverScene.instantiate()
	host.add_child(screen)
	_check(screen.is_open(), "the game over screen opens")
	screen.open_reason("starvation")
	_check((screen.get_node("Center/Panel/Margin/Body/Title") as Label).text
		== I18n.t_key("gameover.title"),
		"the title uses gameover.title")
	_check(screen.reason_text() == I18n.fmt(
		"gameover.reason", {"reason": I18n.t_key("gameover.starvation")}),
		"the reason uses gameover.starvation (%s)" % screen.reason_text())
	_check((screen.get_node("Center/Panel/Margin/Body/Footer/Return") as Button).text
		== I18n.t_key("gameover.return"),
		"the button uses gameover.return")
	var dim: ColorRect = screen.get_node("Dim")
	_check(is_equal_approx(dim.color.a, 0.4),
		"the modal dims the background by 40%% (got %.2f)" % dim.color.a)
	_check((screen.get_node("Center/Panel") as Control).custom_minimum_size.x == 480.0,
		"the panel is 480px wide (§4.8)")

	# Locale rebinding.
	I18n.set_locale("zh")
	_check(screen.reason_text().contains("坏血病") == false
		and screen.reason_text().contains("饿死"),
		"the reason rebinds on locale_changed (%s)" % screen.reason_text())
	I18n.set_locale("en")
	_check(screen.reason_text().contains("starved"),
		"…and back to English (%s)" % screen.reason_text())

	# Every §4.9 reason renders; "any key" returns to the title.
	for reason in ["scurvy", "sunk"]:
		screen.open_reason(reason)
		_check(screen.reason_text() == I18n.fmt(
			"gameover.reason", {"reason": I18n.t_key("gameover.%s" % reason)}),
			"reason '%s' renders (got %s)" % [reason, screen.reason_text()])
	# Standalone / no reason: the row hides instead of printing `<key>`.
	screen.open_reason("")
	_check(not (screen.get_node("Center/Panel/Margin/Body/Reason") as Label).visible,
		"an empty reason hides the reason row (standalone load)")
	_check(ResourceLoader.exists(screen.TITLE_SCENE),
		"S9's return target exists (%s)" % screen.TITLE_SCENE)

	var returned := [0]
	screen.returning_to_title.connect(func() -> void: returned[0] += 1)
	# Do not swap the test scene (the `route` seam, like new_game(route=false)).
	screen.route_to_title = false
	var key := InputEventKey.new()
	key.pressed = true
	key.physical_keycode = KEY_SPACE
	screen._unhandled_input(key)
	_check(returned[0] == 1, "any key returns to the title (emits once)")
	screen._unhandled_input(key)
	_check(returned[0] == 1, "the double-route guard prevents a second return")
	host.queue_free()


# --- 13. HUD morale tiers (§4.5, §4.8) ------------------------------------

func _test_hud_morale_tiers() -> void:
	_make_run(15, 50, 50, 100000, 70)
	GameState.new_game("portugal", false)
	GameState.morale = 70
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)
	var label: Label = hud.get_node("TopRow/Morale")

	var rows := [
		[100, "excellent", PaletteLib.GOOD],
		[80, "excellent", PaletteLib.GOOD],
		[79, "good", PaletteLib.GOOD],
		[60, "good", PaletteLib.GOOD],
		[59, "strained", PaletteLib.GOOD],
		[40, "strained", PaletteLib.GOOD],
		[39, "dangerous", PaletteLib.WARN],
		[20, "dangerous", PaletteLib.WARN],
		[19, "mutinous", PaletteLib.BAD],
		[0, "mutinous", PaletteLib.BAD],
	]
	for row in rows:
		var value: int = row[0]
		GameState.morale = value
		EventBus.day_advanced.emit(GameState.day)
		var tier: String = row[1]
		_check(label.text == "%s (%s)" % [
			I18n.fmt("world.morale", {"amount": value}),
			I18n.t_key("world.morale.%s" % tier),
		], "morale %d reads %s (%s)" % [value, tier, label.text])
		_check(HudLib.morale_tier(value) == tier,
			"morale_tier(%d) == %s (got %s)" % [value, tier, HudLib.morale_tier(value)])
		_check(label.get_theme_color("font_color") == row[2],
			"morale %d is %s-colored" % [value, tier])

	# The §4.5 rule in words: yellow < 40, red < 20.
	_check(HudLib.morale_color(39) == PaletteLib.WARN
		and HudLib.morale_color(40) == PaletteLib.GOOD,
		"yellow starts strictly below 40")
	_check(HudLib.morale_color(19) == PaletteLib.BAD
		and HudLib.morale_color(20) == PaletteLib.WARN,
		"red starts strictly below 20")
	host.queue_free()


# --- Helpers --------------------------------------------------------------

## Finds a weather seed whose first rest-of-map roll is not a storm, so the
## morale/fail-state arithmetic is measured without storm noise.
func _seed_for_first_non_storm() -> int:
	for candidate in 500:
		SailingSimLib.set_weather_seed(candidate)
		var saved_tile := GameState.world_tile()
		_tile(CALM_CELL.x, CALM_CELL.y)
		var weather := SailingSimLib.roll_weather(CALM_CELL)
		GameState.set_world_tile(saved_tile)
		if weather != "storm":
			return candidate
	return 0


## Finds a weather seed whose first rest-of-map roll *is* a storm.
func _seed_for_storm() -> int:
	for candidate in 500:
		SailingSimLib.set_weather_seed(candidate)
		if SailingSimLib.roll_weather(CALM_CELL) == "storm":
			return candidate
	return 0


## Finds a mutiny seed whose first draw hits (0.25 chance) so the modal path is
## deterministic in the queue test.
func _seed_for_mutiny_hit() -> int:
	for candidate in 500:
		SailingSimLib.set_mutiny_seed(candidate)
		if SailingSimLib.mutiny_rng.randf() < SailingSimLib.MUTINY_CHANCE_PER_DAY:
			return candidate
	return 0


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
