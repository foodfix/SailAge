extends Node
## Port-hours acceptance tests (added 2026-11-02; docs/30-* §4.1b, §4.6–§4.7;
## docs/20-* §4.3; docs/10-* §4.19; docs/90-* §5.6). Headless scene test:
##
##   godot --headless res://tools/test_port_hours.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections
##   0 the shipped hours data (defaults per facility, inn "24h");
##   1 `facility_open`: window edges `[open, close)`, 24:00 close, the inn's
##     always-open rule, the always-open fallback for unknown data;
##   2 `advance_port_hours`: a sub-day hour runs no ledger; the midnight
##     crossing runs the full day tick; a dead run's clock is frozen;
##   3 the hub's Space wait: one hour per press, echo ignored, modal blocks;
##   4 rest semantics: any arrival hour lands on day + 3 at 08:00 with exactly
##     three ledger days (wages ×3, morale +15 to the cap), 30g up front;
##   5 Set Sail: +1h, the fraction carries (the retired reset is gone);
##   6 the ecology keeps moving in port: the FleetSim autoload ticks on every
##     port day-advance (`last_tick_day` follows), and the closed rule gates
##     the market engine at the closed hour but passes inside the window;
##   7 hub rows: a closed facility renders disabled with its window label and
##     re-enables once the Space wait reaches the opening hour.

const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const InnEngineLib := preload("res://scripts/port/inn_engine.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const PortScene := preload("res://scenes/port/port_screen.tscn")

## Lisbon's harbor tile (docs/10-* §7.1): a docked fixture so `in_port()` holds.
const LISBON := Vector2i(7, 57)
## Pinned weather seed so a fixture's port days are reproducible (§4.7).
const WEATHER_FAIR_SEED := 20261102
## The shipped default windows (docs/30-* §4.1b table; data §4.19).
const MARKET_OPEN := "08:00"
const MARKET_CLOSE := "18:00"
const TAVERN_CLOSE := "24:00"

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_hours_data()
	_test_facility_open_edges()
	_test_advance_port_hours()
	await _test_space_wait()
	_test_rest_lands_at_8am()
	_test_set_sail_carries_the_clock()
	_test_ecology_ticks_in_port()
	_test_port_day_feeds_no_one()
	_test_hub_closed_rows()
	_report()


# --- Fixture ---------------------------------------------------------------

func _make_run(gold: int = 1000, day: int = 10, morale: int = 70,
		clock_fraction: float = 0.5) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.gold = gold
	GameState.day = day
	GameState.morale = morale
	GameState.fleet = [FleetLib.new_ship("caravel", 15)]
	var flagship: Dictionary = GameState.fleet[0]
	# Light supplies: the §4.1b market section buys goods, so the hold must
	# have room (200/200 would fill a caravel and refuse every buy).
	flagship["provisions"] = 20
	flagship["water"] = 20
	GameState.current_port = "lisbon"
	GameState.world = {
		"position": {"x": LISBON.x, "y": LISBON.y},
		"clock_fraction": clock_fraction,
	}
	GameState.known_ports = ["lisbon"]
	GameState.npc_fleets = []
	# A deserted ecology: this suite pins the *tick cadence*, not the spawn
	# maths (the lane-driven suites own those) — no map, no spawns.
	GameState.npc_preset = "deserted"
	# Lisbon's wine carries a real resting stock so the §4.1b closed-rule
	# section exercises a live row (the economy suite owns stock drift).
	EconomyLib.set_stock("lisbon", "wine", 40)
	SailingSimLib.reset_ledger_state()
	SailingSimLib.set_weather_seed(WEATHER_FAIR_SEED)
	SailingSimLib.set_mutiny_seed(1)


## Sets the wall clock to `hh:mm` (the fraction is the only clock input).
func _clock(hh: int, mm: int = 0) -> void:
	GameState.world["clock_fraction"] = (hh * 60 + mm) / 1440.0


func _reads(hh: int, mm: int = 0) -> bool:
	return SailingSimLib.time_of_day_minutes() == hh * 60 + mm


func _check(condition: bool, description: String) -> void:
	if description.is_empty():
		return
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


# --- 7. Port ledger days feed no one (20-* §4.5 port-day amendment) --------

func _test_port_day_feeds_no_one() -> void:
	# Docked at 23:59 with two days of rations and an ACTIVE starvation and
	# scurvy counter: the midnight roll charges wages but never touches
	# supplies, and the port day reads as the fully-supplied day — both
	# counters reset, no crew loss, no game over. (The frozen-port regression:
	# waiting ashore used to starve the crew invisibly and then freeze every
	# clock surface at the death midnight.)
	_make_run(1000, 10, 70, 23.0 / 24.0 + 59.0 / 1440.0)
	var flagship: Dictionary = GameState.fleet[0]
	flagship["provisions"] = 2
	flagship["water"] = 2
	SailingSimLib.starvation_days = 5
	SailingSimLib.scurvy_days = 3
	var gold_before := GameState.gold
	var crew_before := int(flagship["crew"])
	SailingSimLib.advance_port_hours(1)
	_check(int(GameState.day) == 11, "the midnight crossing rolled day 11")
	_check(int(flagship["provisions"]) == 2 and int(flagship["water"]) == 2,
		"a port ledger day consumed no provisions and no water (got %d/%d)"
		% [int(flagship["provisions"]), int(flagship["water"])])
	_check(SailingSimLib.starvation_days == 0 and SailingSimLib.scurvy_days == 0,
		"the port day reset both fail-state counters (starvation %d, scurvy %d)"
		% [SailingSimLib.starvation_days, SailingSimLib.scurvy_days])
	_check(int(flagship["crew"]) == crew_before,
		"the port day ran no crew loss (crew %d)" % int(flagship["crew"]))
	_check(GameState.gold < gold_before,
		"wages still ran on the port day (gold %d → %d)"
		% [gold_before, GameState.gold])
	_check(SailingSimLib.game_over_reason.is_empty(),
		"no game over fired on a docked roll (reason '%s')"
		% SailingSimLib.game_over_reason)
	SailingSimLib.reset_ledger_state()


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


# --- 0. The shipped hours data (docs/10-* §4.19) ---------------------------

func _test_hours_data() -> void:
	var table: Dictionary = DataLoader.facility_hours
	_check(not table.is_empty() and int(table.get("version", 0)) == 1,
		"facility_hours.json loads with version 1")
	var default: Dictionary = table.get("default", {})
	_check(str(default.get("market", "")) == str([MARKET_OPEN, MARKET_CLOSE]),
		"market ships 08:00–18:00")
	_check(str(default.get("tavern", "")) == str(["10:00", TAVERN_CLOSE]),
		"tavern ships 10:00–24:00")
	_check(default.get("inn", "") == "24h", "the inn ships 24h")
	for facility_id in ["shipyard", "guild", "palace"]:
		_check((default as Dictionary).has(facility_id),
			"%s ships a default window" % facility_id)


# --- 1. The closed rule's edges (docs/30-* §4.1b) --------------------------

func _test_facility_open_edges() -> void:
	_make_run()
	_clock(7, 59)
	_check(not SailingSimLib.facility_open("lisbon", "market"),
		"07:59 the market is still closed")
	_clock(8, 0)
	_check(SailingSimLib.facility_open("lisbon", "market"),
		"08:00 the market opens ([open, close) reads closed at the minute)")
	_clock(17, 59)
	_check(SailingSimLib.facility_open("lisbon", "market"),
		"17:59 the last order still starts")
	_clock(18, 0)
	_check(not SailingSimLib.facility_open("lisbon", "market"),
		"18:00 the market is closed")
	_clock(23, 59)
	_check(SailingSimLib.facility_open("lisbon", "tavern"),
		"23:59 the tavern still pours (close 24:00)")
	_clock(0, 1)
	_check(not SailingSimLib.facility_open("lisbon", "tavern"),
		"00:01 the tavern is closed (past the 24:00 roll)")
	_clock(3, 30)
	_check(SailingSimLib.facility_open("lisbon", "inn"),
		"03:30 the inn never closes (24h)")
	_check(SailingSimLib.facility_open("lisbon", "no_such_hall"),
		"an unknown facility id falls back to always open (data gap ≠ lockdown)")
	var window: Dictionary = SailingSimLib.facility_window_text(
		"lisbon", "market")
	_check(str(window.get("open", "")) == MARKET_OPEN
		and str(window.get("close", "")) == MARKET_CLOSE,
		"the market window renders as {open} 08:00 / {close} 18:00")
	_check(SailingSimLib.facility_window_text("lisbon", "inn").is_empty(),
		"the 24h inn renders no window (never closed)")


# --- 2. advance_port_hours (docs/20-* §4.3) --------------------------------

func _test_advance_port_hours() -> void:
	# A sub-day hour: the fraction moves, no ledger runs.
	_make_run(1000, 10, 70, 0.5)
	var ledger_day := int(GameState.day)
	var morale := GameState.morale
	var gold := GameState.gold
	SailingSimLib.advance_port_hours(1)
	_check(_reads(13, 0), "one hour passes 12:00 → 13:00")
	_check(int(GameState.day) == ledger_day and GameState.morale == morale
		and GameState.gold == gold,
		"a sub-day hour runs no ledger (day/gold/morale frozen)")

	# Crossing midnight: the full day tick (wages 15 crew × 1g... the locked
	# wage rule) — assert day +1 and the ledger's gold delta ran.
	_make_run(1000, 10, 70, 23.0 / 24.0 + 59.0 / 1440.0)
	_check(int(GameState.day) == 10 and _reads(23, 59), "23:59 fixture")
	var wages_before := GameState.gold
	SailingSimLib.advance_port_hours(1)
	_check(int(GameState.day) == 11
			and SailingSimLib.time_of_day_minutes() >= 58 * 60 / 60
			and SailingSimLib.time_of_day_minutes() in [58, 59],
		"23:59 + 1h crosses midnight: day 11 at 00:58–00:59 (got day %d, %s)"
		% [GameState.day, SailingSimLib.clock_text()])
	_check(GameState.gold < wages_before,
		"the midnight crossing ran the ledger (wages paid)")

	# A dead run's clock is frozen (§4.9).
	_make_run(1000, 10, 0, 0.5)
	SailingSimLib.game_over_reason = "starvation"
	SailingSimLib.advance_port_hours(1)
	_check(_reads(12, 0) and int(GameState.day) == 10,
		"a dead run's clock does not move")
	SailingSimLib.reset_ledger_state()


# --- 3. The hub's Space wait (docs/80-* §4.3; 30-* §4.1b) ------------------

func _test_space_wait() -> void:
	_make_run()
	var host := Control.new()
	add_child(host)
	var hub = PortScene.instantiate()
	hub.route_to_facility = false
	hub.route_to_world = false
	host.add_child(hub)
	await get_tree().process_frame

	_clock(7, 0)
	var press := InputEventKey.new()
	press.physical_keycode = KEY_SPACE
	press.pressed = true
	hub._unhandled_input(press)
	_check(_reads(8, 0), "Space on the hub passes exactly one hour (07:00→08:00)")
	var echo := InputEventKey.new()
	echo.physical_keycode = KEY_SPACE
	echo.pressed = true
	echo.echo = true
	hub._unhandled_input(echo)
	_check(_reads(8, 0), "a key-repeat echo is ignored")

	# A modal owns input: the wait must not fire underneath the prompt.
	hub.open_provisions()
	await get_tree().process_frame
	hub._unhandled_input(press)
	_check(_reads(8, 0), "a modal up, the Space wait is refused")
	var prompt = hub.provisions_dialog()
	if prompt != null and prompt.has_method("close"):
		prompt.close()
	await get_tree().process_frame
	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 4. Rest lands on day + 3 at 08:00 (docs/30-* §4.7) --------------------

func _test_rest_lands_at_8am() -> void:
	# Late-evening arrival: day 10 at 22:37 → wake day 13 at 08:00.
	_make_run(1000, 10, 70)
	_clock(22, 37)
	var daily_wages := FleetLib.total_crew() * SailingSimLib.CREW_WAGE_DAILY
	var wages_base := GameState.gold
	_check(daily_wages == 30, "15 crew: daily wages 30g (got %d)" % daily_wages)
	_check(InnEngineLib.rest(), "rest (30g up front) succeeds at 22:37")
	_check(int(GameState.day) == 13 and _reads(8, 0),
		"22:37 + rest wakes day 13 at 08:00 (got day %d, %s)"
		% [GameState.day, SailingSimLib.clock_text()])
	_check(GameState.gold == wages_base - 30 - 3 * daily_wages,
		"exactly three ledger days charged (30g lodging + 3 × %dg wages)"
		% daily_wages)
	_check(GameState.morale == 80, "morale +15 capped at 80 (70 → 80)")

	# Early-morning arrival lands on the same 08:00, three days later.
	_make_run(1000, 10, 70)
	_clock(5, 10)
	_check(InnEngineLib.rest(), "rest succeeds at 05:10")
	_check(int(GameState.day) == 13 and _reads(8, 0),
		"05:10 + rest wakes day 13 at 08:00 too (got day %d, %s)"
		% [GameState.day, SailingSimLib.clock_text()])

	# An 07:59 arrival (fp-sharp edge against the landing minute).
	_make_run(1000, 10, 70)
	_clock(7, 59)
	_check(InnEngineLib.rest(), "rest succeeds at 07:59")
	_check(int(GameState.day) == 13 and _reads(8, 0),
		"07:59 + rest lands exactly on 08:00 day 13 (fp-safe)")


# --- 5. Set Sail carries the clock (docs/20-* §4.11) -----------------------

func _test_set_sail_carries_the_clock() -> void:
	_make_run()
	var host := Control.new()
	add_child(host)
	var hub = PortScene.instantiate()
	hub.route_to_facility = false
	hub.route_to_world = false
	host.add_child(hub)
	await get_tree().process_frame
	_clock(14, 30)
	_check(hub.set_sail(), "set_sail() succeeds while docked")
	_check(GameState.current_port == null, "the docked flag drops")
	_check(is_equal_approx(
			float(GameState.world["clock_fraction"]), 15.5 / 24.0),
		"sail-out charges +1h: 14:30 leaves at 15:30 (got %s)"
		% SailingSimLib.clock_text())
	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 6. The ecology keeps moving in port (docs/60-* §4.11.11) --------------

func _test_ecology_ticks_in_port() -> void:
	_make_run()
	var sim = FleetSim.ensure()
	_check(sim != null, "the FleetSim autoload adopts a docked run")
	if sim == null:
		return
	_check(int(sim.last_tick_day) == int(GameState.day),
		"adoption pins last_tick_day to today (no re-tick)")
	# Three port days (a rest) tick the ecology three times — the old
	# scene-owned sim skipped them entirely (the frozen-harbor regression).
	var market_events: Array = []
	var listener := func(port_id: String) -> void: market_events.append(port_id)
	EventBus.market_changed.connect(listener)
	_make_run(1000, 20, 70)
	sim = FleetSim.ensure()
	var ticks_before := int(sim.last_tick_day)
	_clock(22, 0)
	SailingSimLib.advance_port_day()
	SailingSimLib.advance_port_day()
	SailingSimLib.advance_port_day()
	_check(int(sim.last_tick_day) == int(GameState.day)
		and int(GameState.day) == ticks_before + 3,
		"three port days tick the ecology three times (last_tick_day %d → %d)"
		% [ticks_before, sim.last_tick_day])
	_check((sim.moved_ports as Array).is_empty(),
		"a deserted store moves no NPC trades (empty moved_ports)")
	EventBus.market_changed.disconnect(listener)
	# The per-action hour (sub-day, no midnight) does NOT tick a day.
	_clock(12, 0)
	SailingSimLib.advance_port_hours(1)
	_check(int(sim.last_tick_day) == int(GameState.day),
		"a sub-day hour runs no ecology tick")

	# §4.1b closed rule in the engine: the market refuses a closed-door buy.
	_make_run(1000, 10, 70)
	_clock(7, 59)
	_check(not TradeEngineLib.buy("lisbon", "wine", 1),
		"07:59 a market buy is refused (closed rule)")
	_check(GameState.gold == 1000, "the refused buy changed nothing")
	_clock(8, 0)
	var wine_before := FleetLib.held("wine")
	_check(TradeEngineLib.buy("lisbon", "wine", 1),
		"08:00 the same buy goes through")
	_check(FleetLib.held("wine") == wine_before + 1,
		"the open-door buy stored the wine")
	_check(GameState.gold < 1000, "the open-door buy charged price + tax")
	_check(_reads(9, 0), "the purchase charged its §4.1b hour")


# --- 7. Hub rows follow the hours (docs/80-* §4.2; 30-* §4.1b) -------------

func _test_hub_closed_rows() -> void:
	_make_run()
	var host := Control.new()
	add_child(host)
	var hub = PortScene.instantiate()
	hub.route_to_facility = false
	hub.route_to_world = false
	host.add_child(hub)
	await get_tree().process_frame

	_clock(6, 0)
	hub._bind()
	var gate_hits: Array = []
	hub.facility_requested.connect(func(facility_id: String) -> void:
		gate_hits.append(facility_id))
	var market = hub.facility_row("market")
	var inn = hub.facility_row("inn")
	_check(market != null and market.disabled,
		"06:00 the market row is disabled (closed)")
	_check(str(market.text).contains("08:00") and str(market.text).contains("18:00"),
		"the closed row names its window (%s)" % market.text)
	_check(inn != null and not inn.disabled,
		"06:00 the inn row stays open (24h)")
	_check(not hub.open_facility("market") and gate_hits == ["market"],
		"the entry gate refuses a closed facility (signal still emitted)")

	# Space-wait to opening: the rows rebuild with the market enabled.
	var press := InputEventKey.new()
	press.physical_keycode = KEY_SPACE
	press.pressed = true
	for _minute in range(120):
		hub._unhandled_input(press)
		if hub.is_facility_enabled("market"):
			break
	_check(hub.is_facility_enabled("market"),
		"waiting to 08:00 re-enables the market row")
	_check(hub.open_facility("market"), "the entry gate opens it after opening")

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame
