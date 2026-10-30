extends Node
## T15 acceptance tests (docs/IMPLEMENT-Phase1.md T15; docs/30-* §4.6–§4.7;
## docs/50-* §4.7, §6; docs/20-* §4.5, §4.8.1; docs/10-* §5; docs/80-* §4.7).
## Headless scene test:
##
##   godot --headless res://tools/test_inn.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections
##   0 the locked numbers (rest 30g, payout 100g, threshold 100g, latin 1200g);
##   1 rest: exactly 3 ledger days, cost split (30g lodging + 3 × wages),
##     morale `min(M+15, 80)` incl. the "already above 80 keeps it" rule;
##   2 rest unaffordable (29g): refused, nothing changes;
##   3 odd-job gate: ship / gold < 100 / officer lockout / all-clear;
##   4 odd-job effect: +100g and +1 day per click, re-evaluated after each;
##   4b the anti-softlock arithmetic (12 × 100g = the 1200g `latin`) **and**
##      the `gold < 100` gate that makes the documented 12-click recovery
##      unreachable — reported as a design gap, pinned so a doc fix is noticed;
##   5 debug_strip_fleet();
##   6 menu wiring: `port_screen.open_facility("inn")` → inn scene;
##   7 the scene itself: status box, button states, reason keys, locale rebind,
##     standalone load, Back/Esc route to S4.

const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const InnEngineLib := preload("res://scripts/port/inn_engine.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const PortScene := preload("res://scenes/port/port_screen.tscn")
const InnScene := preload("res://scenes/port/inn_screen.tscn")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
const INN_SCENE := "res://scenes/port/inn_screen.tscn"

## Lisbon's harbor tile (docs/10-* §7.1): a docked fixture so `in_port()` holds.
const LISBON := Vector2i(7, 57)
## §5 / §7.3: cheapest hull (`latin`) — the anti-softlock target price.
const CHEAPEST_HULL := 1200
## §4.7 shorthand "gold < 100": one coin below the threshold.
const BELOW_THRESHOLD := 99
## Pinned weather seed so a fixture's port days are reproducible (a storm day
## would add damage/fail-state noise to the wage arithmetic; in port the +5
## morale row is storm-independent either way).
const WEATHER_FAIR_SEED := 20261029

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the port fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	_test_constants()
	_test_rest_days_and_gold()
	_test_rest_morale_cap()
	_test_rest_unaffordable()
	_test_odd_job_gate()
	_test_odd_job_effect()
	_test_anti_softlock_arithmetic()
	_test_debug_strip_fleet()
	_test_menu_wiring()
	await _test_scene_states()
	await _test_scene_locale_rebind()
	await _test_scene_standalone()
	await _test_scene_back_route()
	_report()


# --- Fixtures --------------------------------------------------------------

## Docked run at Lisbon: `crew` crew on a caravel, `gold`, `day` and `morale`
## as given, `officers` employed. Supplies are ample so no §4.9 fail state can
## interfere; `weather_seed`/`mutiny_seed` are pinned so the printed numbers
## are reproducible (a port day never rolls a mutiny, but a storm still rolls).
func _make_run(
	crew: int = 15,
	gold: int = 1000,
	day: int = 10,
	morale: int = 70,
	officers: Array = [],
	ship_type_id: String = "caravel"
) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": officers.duplicate(),
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.gold = gold
	GameState.day = day
	GameState.morale = morale
	GameState.fleet = [FleetLib.new_ship(ship_type_id, crew)]
	var flagship: Dictionary = GameState.fleet[0]
	if crew > 0:
		flagship["provisions"] = 200
		flagship["water"] = 200
	GameState.current_port = "lisbon"
	GameState.world = {"position": {"x": LISBON.x, "y": LISBON.y}, "clock_fraction": 0.0}
	GameState.known_ports = ["lisbon"]
	SailingSimLib.reset_ledger_state()
	# Pinned weather/mutiny streams so a fixture's port days are reproducible
	# forever (§4.7 step 3 rolls in port too). The assertions below cover only
	# gold, day and morale, which a port day's weather cannot change (no sea
	# morale rows in port; 3 storm days cannot sink a 90-durability hull), so
	# the seed is a reproducibility pin, not a weather dependency.
	SailingSimLib.set_weather_seed(WEATHER_FAIR_SEED)
	SailingSimLib.set_mutiny_seed(1)


# --- 0. Constants (docs/10-* §5, docs/30-* §4.6) ---------------------------

func _test_constants() -> void:
	_check(InnEngineLib.REST_DAYS == 3, "rest is 3 days (got %d)"
		% InnEngineLib.REST_DAYS)
	_check(InnEngineLib.REST_COST_PER_DAY == 10,
		"lodging is 10g/day (got %d)" % InnEngineLib.REST_COST_PER_DAY)
	_check(InnEngineLib.REST_COST == 30,
		"rest price is 10g × 3 = 30g (got %d)" % InnEngineLib.REST_COST)
	_check(InnEngineLib.ODD_JOB_GOLD == 100,
		"odd job pays 100g (got %d)" % InnEngineLib.ODD_JOB_GOLD)
	# docs/10-* §5: the threshold is the cheapest hull price, not 100 — gating
	# on `gold < 100` while paying +100 would close the gate after one job.
	_check(InnEngineLib.RELIEF_GOLD_THRESHOLD == CHEAPEST_HULL,
		"relief threshold is the cheapest hull, %dg (got %d)"
		% [CHEAPEST_HULL, InnEngineLib.RELIEF_GOLD_THRESHOLD])
	var latin: Dictionary = DataLoader.get_ship_type("latin")
	_check(int(latin.get("base_price", 0)) == CHEAPEST_HULL,
		"cheapest hull is latin at %dg (got %d)"
		% [CHEAPEST_HULL, int(latin.get("base_price", 0))])


# --- 1. Rest: exactly 3 ledger days ---------------------------------------

## `rest()` must advance exactly three days, charge 30g lodging *plus* the
## three days of wages the ledger pays, and let the ledger apply the morale
## delta. With 15 crew and no officers wages are `15 × 2 = 30g/day`, so the
## rest costs `30 + 90 = 120g` in total — the split is asserted separately.
func _test_rest_days_and_gold() -> void:
	_make_run(15, 1000, 10, 70)
	var daily_wages := FleetLib.total_crew() * SailingSimLib.CREW_WAGE_DAILY \
		+ CharacterLib.officer_wages()
	_check(daily_wages == 30, "15 crew, no officers: daily wages 30g (got %d)"
		% daily_wages)

	var ok: bool = InnEngineLib.rest()
	var expected := 1000 - InnEngineLib.REST_COST - InnEngineLib.REST_DAYS * daily_wages
	_check(ok, "rest() succeeds with 1000g")
	_check(GameState.day == 13,
		"rest advanced exactly 3 days (10 → %d)" % GameState.day)
	_check(GameState.gold == expected,
		"rest gold: 1000 − 30 lodging − 3×30 wages = %d (got %d)"
		% [expected, GameState.gold])
	_check(1000 - GameState.gold - InnEngineLib.REST_COST == 3 * daily_wages,
		"wages component is exactly 3 × 30 = 90g (got %d)"
		% (1000 - GameState.gold - InnEngineLib.REST_COST))

	# An officer's wage must be paid too, and the officer stays aboard.
	_make_run(15, 1000, 10, 70, ["off_mateus_alvares"])
	daily_wages = FleetLib.total_crew() * SailingSimLib.CREW_WAGE_DAILY \
		+ CharacterLib.officer_wages()
	_check(daily_wages == 60, "15 crew + officer: daily wages 60g (got %d)"
		% daily_wages)
	ok = InnEngineLib.rest()
	expected = 1000 - 30 - 3 * 60
	_check(ok, "rest() succeeds with an officer employed")
	_check(GameState.day == 13,
		"officer rest advanced exactly 3 days (got %d)" % GameState.day)
	_check(GameState.gold == expected,
		"officer rest gold: 1000 − 30 − 3×60 = %d (got %d)"
		% [expected, GameState.gold])
	_check(CharacterLib.officer_count() == 1,
		"rest does not dismiss officers (got %d)" % CharacterLib.officer_count())


# --- 1b. Rest: morale +5/day, capped at 80 (docs/20-* §4.8.1) -------------

func _test_rest_morale_cap() -> void:
	# M = 10 → 25 (three full +5s).
	_make_run(15, 1000, 10, 10)
	InnEngineLib.rest()
	_check(GameState.morale == 25,
		"morale 10 rested 3 days → 25 (got %d)" % GameState.morale)

	# M = 70 → 80 (70 → 75 → 80 → capped at 80).
	_make_run(15, 1000, 10, 70)
	InnEngineLib.rest()
	_check(GameState.morale == 80,
		"morale 70 rested 3 days → 80, capped (got %d)" % GameState.morale)

	# M = 79 → 80 (the cap binds on the very first day).
	_make_run(15, 1000, 10, 79)
	InnEngineLib.rest()
	_check(GameState.morale == 80,
		"morale 79 rested 3 days → 80, capped (got %d)" % GameState.morale)

	# M = 85 stays 85: §4.8.1 clarification 1 — the port cap never pulls a
	# fleet above 80 back down.
	_make_run(15, 1000, 10, 85)
	InnEngineLib.rest()
	_check(GameState.morale == 85,
		"morale 85 stays 85 (no forced decay to the cap) (got %d)"
		% GameState.morale)

	# The delta is the ledger's, not the inn's: exactly +5 per day, no doubling.
	_make_run(15, 1000, 10, 20)
	InnEngineLib.rest()
	_check(GameState.morale == 35,
		"morale 20 → 35: +5/day once, no double-apply (got %d)" % GameState.morale)


# --- 2. Rest unaffordable -------------------------------------------------

func _test_rest_unaffordable() -> void:
	_make_run(15, 29, 10, 60)
	var ok: bool = InnEngineLib.rest()
	_check(not ok, "rest() at 29g is refused")
	_check(GameState.day == 10, "refused rest leaves the day at 10 (got %d)"
		% GameState.day)
	_check(GameState.gold == 29, "refused rest leaves gold at 29 (got %d)"
		% GameState.gold)
	_check(GameState.morale == 60, "refused rest leaves morale at 60 (got %d)"
		% GameState.morale)

	_check(not InnEngineLib.can_rest(), "can_rest() is false at 29g")
	# Exactly 30g is affordable (the boundary).
	_make_run(15, 30, 10, 60)
	_check(InnEngineLib.can_rest(), "can_rest() is true at exactly 30g")


# --- 3. Odd-job gate (docs/50-* §4.7 step 1, §6) ---------------------------

func _test_odd_job_gate() -> void:
	# (a) With a ship: ineligible, whatever the purse.
	_make_run(15, 0, 10, 70)
	_check(not InnEngineLib.odd_job_eligible(),
		"ineligible with a ship (gold 0)")
	_check(InnEngineLib.ineligible_reason() == InnEngineLib.REASON_HAS_SHIP,
		"reason is 'has ship' (got '%s')" % InnEngineLib.ineligible_reason())
	_make_run(15, 50, 10, 70)
	_check(not InnEngineLib.odd_job_eligible(),
		"ineligible with a ship (gold 50)")
	_check(InnEngineLib.ineligible_reason() == InnEngineLib.REASON_HAS_SHIP,
		"reason is still 'has ship' with a ship (got '%s')"
		% InnEngineLib.ineligible_reason())

	# (b) Shipless but able to buy the cheapest hull: ineligible (strict `<`).
	_make_run(0, CHEAPEST_HULL, 10, 70)
	GameState.debug_strip_fleet()
	_check(not InnEngineLib.odd_job_eligible(),
		"shipless at exactly %dg (a latin) is ineligible (strict <)" % CHEAPEST_HULL)
	_check(InnEngineLib.ineligible_reason() == InnEngineLib.REASON_NOT_BROKE,
		"reason is 'not broke' at %dg (got '%s')"
		% [CHEAPEST_HULL, InnEngineLib.ineligible_reason()])
	_make_run(0, 5000, 10, 70)
	GameState.debug_strip_fleet()
	_check(not InnEngineLib.odd_job_eligible(), "shipless at 5000g is ineligible")
	# Still eligible below the hull price — that is the whole point of relief.
	_make_run(0, CHEAPEST_HULL - 1, 10, 70)
	GameState.debug_strip_fleet()
	_check(InnEngineLib.odd_job_eligible(),
		"shipless at %dg (just short of a latin) is still eligible" % (CHEAPEST_HULL - 1))

	# (c) Shipless + broke but with an officer: §6 lockout wins.
	_make_run(0, 0, 10, 70, ["off_mateus_alvares"])
	GameState.debug_strip_fleet()
	_check(not InnEngineLib.odd_job_eligible(),
		"officer employed blocks relief even when shipless and broke")
	_check(InnEngineLib.ineligible_reason() == InnEngineLib.REASON_OFFICERS,
		"reason is the officer lockout (got '%s')"
		% InnEngineLib.ineligible_reason())

	# (d) Officer dismissed → eligible (the §6 "dismiss first" resolution).
	CharacterLib.dismiss("off_mateus_alvares")
	_check(InnEngineLib.odd_job_eligible(),
		"dismissing the officer makes relief eligible")
	_check(InnEngineLib.ineligible_reason() == "",
		"eligible → empty reason (got '%s')" % InnEngineLib.ineligible_reason())

	# (e) The all-clear boundary: shipless + just under the hull price.
	_make_run(0, BELOW_THRESHOLD, 10, 70)
	GameState.debug_strip_fleet()
	_check(InnEngineLib.odd_job_eligible(),
		"shipless + %dg + no officers is eligible" % BELOW_THRESHOLD)
	_check(InnEngineLib.ineligible_reason() == "",
		"eligible at 99g → empty reason (got '%s')"
		% InnEngineLib.ineligible_reason())


# --- 4. Odd-job effect: +100g, +1 day, repeatable --------------------------

func _test_odd_job_effect() -> void:
	_make_run(0, 0, 10, 70)
	GameState.debug_strip_fleet()
	var day_before := GameState.day
	var ok: bool = InnEngineLib.work_odd_job()
	_check(ok, "first odd job succeeds from 0g")
	_check(GameState.gold == 100, "odd job pays exactly +100g (0 → %d)"
		% GameState.gold)
	_check(GameState.day == day_before + 1,
		"odd job advances exactly 1 day (10 → %d)" % GameState.day)
	# With no fleet there is no crew/officer wage to eat the payout.
	_check(SailingSimLib.last_day_wages == 0,
		"shipless day pays no wages (got %d)" % SailingSimLib.last_day_wages)

	# The condition is re-evaluated after the job. At 100g the player is still
	# far short of a latin (1,200g), so the offer must remain available — this
	# is what makes relief an actual escape rather than a one-shot (docs/10-*
	# §5 "Why the threshold is 1,200, not 100").
	_check(InnEngineLib.odd_job_eligible(),
		"after one payout (100g) the odd job is still available")
	ok = InnEngineLib.work_odd_job()
	_check(ok, "a second odd job succeeds at 100g")
	_check(GameState.gold == 200 and GameState.day == day_before + 2,
		"second job pays +100g and +1 day (%dg, day %d)"
		% [GameState.gold, GameState.day])


# --- 4b. Anti-softlock arithmetic (docs/10-* §5) ---------------------------

## docs/10-* §5: "cheapest hull is `latin` at 1,200g, so at most 12 odd jobs
## restore a shipless player to sailing." The earlier text gated the offer on
## `gold < 100` while paying +100, which closed the gate after one payout and
## made the 1,200g hull unreachable — the fallback caused the softlock it
## exists to prevent. The doc now gates on the cheapest hull price, so this
## section asserts the *working* escape: from 0g, exactly 12 consecutive odd
## jobs reach 1,200g with no fixture reset in between.
func _test_anti_softlock_arithmetic() -> void:
	_make_run(0, 0, 10, 70)
	GameState.debug_strip_fleet()
	var start_day := GameState.day
	var clicks := 0
	# No purse reset: relief alone must carry the player to a hull.
	for _click in range(12):
		if not InnEngineLib.odd_job_eligible():
			break
		if InnEngineLib.work_odd_job():
			clicks += 1
	_check(clicks == 12,
		"12 consecutive odd jobs are possible from 0g (got %d)" % clicks)
	_check(GameState.gold == CHEAPEST_HULL,
		"relief alone reaches the %dg `latin` price (got %d)"
		% [CHEAPEST_HULL, GameState.gold])
	_check(GameState.day == start_day + 12,
		"12 odd jobs advance 12 days (%d → %d)" % [start_day, GameState.day])

	# The gate closes exactly at the hull price: one more job is refused and a
	# 13th click changes nothing (a 13th would be pure profit, not relief).
	_check(not InnEngineLib.odd_job_eligible(),
		"at exactly the hull price the offer is gone")
	_check(not InnEngineLib.work_odd_job(),
		"a 13th odd job is refused")
	_check(GameState.gold == CHEAPEST_HULL and GameState.day == start_day + 12,
		"the refused job changes neither gold nor day (%dg, day %d)"
		% [GameState.gold, GameState.day])

	# And the player can actually buy the hull they just earned.
	_check(GameState.gold >= int(DataLoader.get_ship_type("latin").get("base_price", 0)),
		"the earned purse covers a latin (%dg ≥ %dg)"
		% [GameState.gold, int(DataLoader.get_ship_type("latin").get("base_price", 0))])


# --- 5. debug_strip_fleet() ------------------------------------------------

func _test_debug_strip_fleet() -> void:
	_make_run(15, 0, 10, 70)
	_check(GameState.fleet.size() == 1, "fixture starts with one ship")
	var pending: Array = []
	var listener := func() -> void: pending.append(true)
	EventBus.fleet_changed.connect(listener)
	var stripped: bool = GameState.debug_strip_fleet()
	EventBus.fleet_changed.disconnect(listener)

	_check(stripped, "debug_strip_fleet() reports success in a debug build")
	_check(GameState.fleet.is_empty(), "debug_strip_fleet() empties the fleet (%d)"
		% GameState.fleet.size())
	_check(not pending.is_empty(), "debug_strip_fleet() emits fleet_changed")
	_check(InnEngineLib.odd_job_eligible(),
		"shipless + 0g after strip → odd job eligible")
	_check(GameState.gold == 0, "debug_strip_fleet() leaves gold untouched (got %d)"
		% GameState.gold)
	_check(GameState.day == 10, "debug_strip_fleet() leaves the day untouched (got %d)"
		% GameState.day)
	_check(GameState.morale == 70, "debug_strip_fleet() leaves morale untouched (got %d)"
		% GameState.morale)
	_check(not GameState.player.is_empty(), "debug_strip_fleet() leaves the player block")


# --- 6. Menu wiring (S4 → S8) ---------------------------------------------

func _test_menu_wiring() -> void:
	# FACILITY_SCENES is the routing table T11's rows call through; the inn
	# entry must point at the scene this task created and the file must exist.
	var port = PortScene.instantiate()
	var scenes: Dictionary = port.FACILITY_SCENES
	_check(str(scenes.get("inn", "")) == INN_SCENE,
		"port_screen.FACILITY_SCENES[inn] == %s (got '%s')"
		% [INN_SCENE, str(scenes.get("inn", ""))])
	_check(ResourceLoader.exists(str(scenes.get("inn", ""))),
		"the inn scene exists on disk")

	# Route for real: `open_facility("inn")` must swap to inn_screen.tscn.
	_make_run(15, 1000, 10, 70)
	var tree := get_tree()
	tree.current_scene = null
	tree.change_scene_to_file(PORT_SCENE)
	await tree.process_frame
	await tree.process_frame
	var hub = tree.current_scene
	_check(hub != null and hub.scene_file_path == PORT_SCENE,
		"port hub is the active scene (got %s)"
		% ("null" if hub == null else hub.scene_file_path))
	if hub == null or hub.scene_file_path != PORT_SCENE:
		port.free()
		return
	var routed: bool = hub.open_facility("inn")
	_check(routed, "open_facility('inn') reports a started route")
	await tree.process_frame
	await tree.process_frame
	var inn = tree.current_scene
	_check(inn != null and inn.scene_file_path == INN_SCENE,
		"open_facility('inn') routes to inn_screen.tscn (got %s)"
		% ("null" if inn == null else inn.scene_file_path))
	if inn != null and inn.scene_file_path == INN_SCENE:
		_check((inn.get_node("Layout/VBox/Header/Title") as Label).text
			== I18n.fmt("inn.title", {"port": I18n.t(
				DataLoader.get_port("lisbon")["name"])}),
			"the routed screen titles itself with the docked port")
	if tree.current_scene != null:
		tree.current_scene.queue_free()
		tree.current_scene = null
	port.free()
	await tree.process_frame


# --- 7. The screen itself --------------------------------------------------

## Mounts the inn scene under a Control host and drives the real buttons.
func _mount_inn(host: Control):
	var inn = InnScene.instantiate()
	inn.route_to_port = false
	host.add_child(inn)
	return inn


func _test_scene_states() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)

	# (a) A normal docked run: rest affordable, relief unavailable (has ship).
	_make_run(15, 1000, 10, 70)
	var inn = _mount_inn(host)
	await get_tree().process_frame

	var title: Label = inn.get_node("Layout/VBox/Header/Title")
	_check(title.text == I18n.fmt("inn.title", {"port": "Lisbon"}),
		"title shows the docked port (%s)" % title.text)
	var morale: Label = inn.get_node("Layout/VBox/Status/Margin/StatusVBox/Morale")
	_check(morale.text.contains("70") and morale.text.contains(
		I18n.t_key("world.morale.good")),
		"status box shows morale 70 (Good): %s" % morale.text)
	var gold: Label = inn.get_node("Layout/VBox/Status/Margin/StatusVBox/Gold")
	_check(gold.text == I18n.fmt("ui.gold_amount", {"gold": "1,000"}),
		"status box shows 1,000g (%s)" % gold.text)
	var day: Label = inn.get_node("Layout/VBox/Status/Margin/StatusVBox/Day")
	_check(day.text == I18n.fmt("world.day", {"day": 10}),
		"status box shows day 10 (%s)" % day.text)

	var rest: Button = inn.get_node("Layout/VBox/Actions/RestButton")
	_check(rest.text == I18n.fmt("inn.rest_cost", {"day": 3, "price": 30}),
		"rest button labels the 3-day price (30g): %s" % rest.text)
	_check(not rest.disabled, "rest is enabled at 1000g")
	var odd: Button = inn.get_node("Layout/VBox/Actions/OddJobButton")
	var hint: Label = inn.get_node("Layout/VBox/Actions/OddJobHint")
	_check(odd.disabled, "odd job is disabled with a ship")
	_check(odd.text == I18n.t_key("inn.odd_job.ineligible"),
		"disabled odd job shows the generic ineligible label (%s)" % odd.text)
	_check(not inn.odd_job_enabled(), "odd_job_enabled() is false with a ship")
	_check(inn.odd_job_reason() == InnEngineLib.REASON_HAS_SHIP,
		"the disabled reason key is the has-ship one (got '%s')"
		% inn.odd_job_reason())
	_check(hint.visible, "the disabled reason line is visible")

	# (b) Rest through the button: 3 days, the 30g + 90g breakdown, morale +15.
	rest.pressed.emit()
	await get_tree().process_frame
	_check(GameState.day == 13, "the rest button advanced 3 days (got day %d)"
		% GameState.day)
	_check(GameState.gold == 1000 - 30 - 90,
		"the rest button: 1000 − 30 − 3×30 = %d (got %d)"
		% [1000 - 30 - 90, GameState.gold])
	_check(GameState.morale == 80,
		"the rest button raised morale 70 → 80 (got %d)" % GameState.morale)
	_check(inn.last_message_key == "inn.rest_done",
		"the rest button reports inn.rest_done (got '%s')" % inn.last_message_key)
	_check(day.text == I18n.fmt("world.day", {"day": 13}),
		"the status box day follows the ledger (%s)" % day.text)

	# (c) Empty purse: rest disabled with inn.no_gold.
	GameState.gold = 29
	inn.refresh()
	_check(rest.disabled, "rest is disabled at 29g")
	var rest_hint: Label = inn.get_node("Layout/VBox/Actions/RestHint")
	_check(rest_hint.visible, "the gold reason line is visible at 29g")
	_check(rest_hint.text == I18n.t_key("inn.no_gold"),
		"the gold reason is inn.no_gold (%s)" % rest_hint.text)
	inn.queue_free()
	await get_tree().process_frame

	# (d) Harbor relief: shipless + broke + no officers → button enabled, and
	# one click gives +100g/+1 day; the state machine then flips to disabled
	# *in the same action* because 100g is no longer `< 100`.
	_make_run(0, 0, 10, 70)
	GameState.debug_strip_fleet()
	inn = _mount_inn(host)
	await get_tree().process_frame
	odd = inn.get_node("Layout/VBox/Actions/OddJobButton")
	hint = inn.get_node("Layout/VBox/Actions/OddJobHint")
	_check(inn.odd_job_enabled(), "relief is enabled when shipless + broke")
	_check(odd.text == I18n.t_key("inn.odd_job.offer"),
		"the enabled button shows inn.odd_job.offer (%s)" % odd.text)
	_check(not hint.visible, "no reason line while eligible")
	_check(inn.odd_job_reason() == "", "no reason key while eligible")

	var states: Array = []
	var listener := func(eligible: bool) -> void: states.append(eligible)
	inn.odd_job_state_changed.connect(listener)
	odd.pressed.emit()
	_check(GameState.gold == 100, "the odd job button paid +100g (got %d)"
		% GameState.gold)
	_check(GameState.day == 11, "the odd job button advanced 1 day (got %d)"
		% GameState.day)
	_check(inn.last_message_key == "inn.odd_job.result",
		"the job reports inn.odd_job.result (got '%s')" % inn.last_message_key)
	# Still short of a latin (1,200g), so the state machine must report
	# *enabled* after the payout (docs/10-* §5 amended threshold).
	_check(not states.is_empty() and bool(states[-1]),
		"the state machine re-evaluated after the job and stays enabled (got %s)"
		% str(states))
	_check(not odd.disabled, "the button stays on while short of a hull (100g)")
	_check(inn.odd_job_reason() == "",
		"no reason line while still eligible (got '%s')" % inn.odd_job_reason())

	# Re-evaluation on (re)open: back to a broke purse, a refresh must re-arm.
	GameState.gold = 0
	states.clear()
	inn.refresh()
	inn.odd_job_state_changed.disconnect(listener)
	await get_tree().process_frame
	_check(states.has(true), "refreshing the screen re-evaluates to eligible (%s)"
		% str(states))
	_check(inn.odd_job_enabled(), "the button re-arms after the state changes")
	inn.queue_free()
	await get_tree().process_frame

	# (e) Officer lockout surfaced in the UI.
	_make_run(0, 0, 10, 70, ["off_mateus_alvares"])
	GameState.debug_strip_fleet()
	inn = _mount_inn(host)
	await get_tree().process_frame
	_check(not inn.odd_job_enabled(), "an employed officer disables relief in the UI")
	_check(inn.odd_job_reason() == InnEngineLib.REASON_OFFICERS,
		"the UI reason is the officer lockout (got '%s')" % inn.odd_job_reason())
	inn.queue_free()
	await get_tree().process_frame

	host.queue_free()
	await get_tree().process_frame


## Locale toggle must rebind every label without a scene reload (docs/80-* §6).
func _test_scene_locale_rebind() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run(0, 0, 10, 70)
	GameState.debug_strip_fleet()
	GameState.locale = "en"
	var inn = _mount_inn(host)
	await get_tree().process_frame

	var rest: Button = inn.get_node("Layout/VBox/Actions/RestButton")
	var odd: Button = inn.get_node("Layout/VBox/Actions/OddJobButton")
	var title: Label = inn.get_node("Layout/VBox/Header/Title")
	var back: Button = inn.get_node("Layout/VBox/Footer/Back")
	var english := {
		"title": title.text, "rest": rest.text, "odd": odd.text, "back": back.text,
	}
	I18n.set_locale("zh")
	await get_tree().process_frame
	_check(title.text != english["title"] and title.text.contains("旅店"),
		"zh locale rebinds the title (%s)" % title.text)
	_check(rest.text != english["rest"] and rest.text.contains("休息"),
		"zh locale rebinds the rest button (%s)" % rest.text)
	_check(odd.text != english["odd"],
		"zh locale rebinds the odd-job button (%s)" % odd.text)
	_check(back.text == I18n.t_key("ui.back") and back.text != english["back"],
		"zh locale rebinds Back (%s)" % back.text)
	I18n.set_locale("en")
	await get_tree().process_frame
	_check(title.text == english["title"], "en restores the title (%s)" % title.text)
	inn.queue_free()
	host.queue_free()
	await get_tree().process_frame


## The scene must run standalone (editor load, no run): neutral placeholders,
## both actions disabled, no crash, Esc does not route.
func _test_scene_standalone() -> void:
	GameState.player = {}
	GameState.fleet = []
	GameState.current_port = null
	GameState.world = {}
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var inn = _mount_inn(host)
	await get_tree().process_frame

	var title: Label = inn.get_node("Layout/VBox/Header/Title")
	_check(title.text == I18n.fmt("inn.title", {"port": "-"}),
		"standalone: the title falls back to a placeholder (%s)" % title.text)
	var rest: Button = inn.get_node("Layout/VBox/Actions/RestButton")
	var odd: Button = inn.get_node("Layout/VBox/Actions/OddJobButton")
	_check(rest.disabled, "standalone: rest is disabled (no run)")
	_check(odd.disabled, "standalone: the odd job is disabled (no run)")
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	inn._unhandled_input(esc)
	_check(inn.is_inside_tree(), "standalone: Esc leaves the scene in place")
	inn.queue_free()
	host.queue_free()
	await get_tree().process_frame


## Back / Esc → the port hub (S4) in a live run.
func _test_scene_back_route() -> void:
	_make_run(15, 1000, 10, 70)
	var tree := get_tree()
	tree.current_scene = null
	tree.change_scene_to_file(INN_SCENE)
	await tree.process_frame
	await tree.process_frame
	var inn = tree.current_scene
	_check(inn != null and inn.scene_file_path == INN_SCENE,
		"inn_screen.tscn loads as the active scene (got %s)"
		% ("null" if inn == null else inn.scene_file_path))
	if inn == null or inn.scene_file_path != INN_SCENE:
		return
	await tree.process_frame

	# The default routing flag must be on for the real scene.
	_check(inn.route_to_port, "the routed inn screen keeps its routing enabled")
	inn.leave()
	await tree.process_frame
	await tree.process_frame
	var back = tree.current_scene
	_check(back != null and back.scene_file_path == PORT_SCENE,
		"the inherited leave() route returns to port_screen.tscn (got %s)"
		% ("null" if back == null else back.scene_file_path))
	if tree.current_scene != null:
		tree.current_scene.queue_free()
		tree.current_scene = null
	await tree.process_frame


# --- Harness ---------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	if description.is_empty():
		return
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
