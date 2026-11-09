extends Node
## Phase-8 W5-D appointed-voyage acceptance tests
## (docs/20-WORLD-AND-SAILING.md §4.19 — THE contract; docs/80-UI-UX.md
## §4.10.4; docs/IMPLEMENT-Phase8.md W5-D + the Shared-A* rule; docs/90-*
## §13 contract: headless, exit 0, `ALL PASS (N checks)`).
##
##   godot --headless res://tools/test_autopilot.tscn
##
## Exits 0 when every check passes, 1 otherwise. Deterministic contract pins
## only — no Monte Carlo. Covers:
##   - the shared-A* weighted core (`fleet_path.gd` find_path_weighted):
##     unit-cost find_path untouched, the weighted search diverges exactly
##     when the cost fn says so, wrap + no-corner-cutting + guards, and
##     deterministic repeat queries;
##   - the gate matrix (no pilot / nav 39 vs 40 / unknown destination) with
##     the `skill_gates` `sail.autopilot` row as the reason source;
##   - appoint → save-v9 `player.autopilot` key + route (plain §4.2 path for
##     nav 40–69), no gold fee, ledger untouched by the appointment itself;
##   - cancel reasons (contact / manual / arrived; unknown reason refused);
##   - hostile contact auto-cancels, STORMS DO NOT (auto-reef fires and
##     restores, appointment survives the storm day);
##   - weighted (nav 70) vs plain (nav 50) MEASURABLY DIFFER on a real OD
##     pair (Lisbon → Goa, the Arabian-sea monsoon region, month 1): ≥ 15%
##     fewer model cost-days OR a different wind-region crossing set — the
##     closed comparison, plus legality (wrap/corner/ice) of the weighted
##     walk and deterministic re-plans;
##   - one seeded integration observation: appoint + simulated sail days
##     reach the berth, `tick()` reports arrived, `cancel("arrived")` clears;
##   - the HUD bar (setup/refresh/cancel-button, zh/en) and the chart's
##     §4.10.4 appoint row (gate-grayed, success flips to the HUD-line info,
##     Esc ordering, debug chart untouched).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetPathLib := preload("res://scripts/world/fleet_path.gd")
const SailPathLib := preload("res://scripts/world/sail_path.gd")
const AutopilotLib := preload("res://scripts/world/autopilot.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ChartScene := preload("res://scenes/world/chart_screen.tscn")
const HudScene := preload("res://scenes/world/autopilot_hud.tscn")

## Fixture pilots (the test_skills fake-officer pattern): stable ids,
## controlled navigation, removed again in _cleanup. Navigation is the ONLY
## varying field — the gate reads the pilot's own card value (§4.19).
const PILOTS := {
	"off_ap_pilot_39": 39,
	"off_ap_pilot_40": 40,
	"off_ap_pilot_50": 50,
	"off_ap_pilot_70": 70,
}

## The §4.19 weighted-vs-plain OD pair: Lisbon → Malacca, sailed in **month 1**
## (day 1 fixture — the NE monsoon: a following wind eastbound through the
## Arabian sea and the South-China-sea reversal band; the plain path is the
## pure shortest-water route). Measured (this suite's NOTE lines): the
## weighted route is the SAME tile distance but rides current/wind for
## ~7–8% fewer model cost-days, and crosses a DIFFERENT wind-region set
## (it stays inside the numbered regions and never touches unassigned `VAR`
## water, id 0) — the locked gate's second branch ("≥ 15% faster OR
## different wind-region crossings"). The 15% branch is bounded by the
## §4.14 monthly wind field itself: regions are flat (one token per region
## per month), so wind savings only exist at region boundaries and in the
## narrow §4.16 current corridors — the corridor-bounded weighted route
## cannot buy 15% on this OD without leaving the shortest-water ocean path,
## which is exactly why the gate carries the crossing-set branch.
const OD_FROM := "lisbon"
const OD_TO := "malacca"

var _failures: Array[String] = []
var _checks := 0


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
		print("FAIL  %s" % message)


func _ready() -> void:
	var map = MapLoaderLib.new()
	_check(map.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"map loads for the autopilot fixtures (%s)" % map.last_error)
	DataLoader.map = map
	var ocean = OceanLayersLib.instance()
	print("NOTE  ocean decode (wind): ok=%s %d ms (%s)"
		% [str(ocean.decode_ok), ocean.decode_ms, ocean.last_error])
	_check(ocean.decode_ok, "the ocean rasters decode (weighted lookups)")
	GameState.new_game("portugal", false)
	_inject_pilots()
	_to_sea(OD_FROM)

	_test_fleet_path_weighted_core()
	_test_gate_matrix()
	_test_appoint_and_key()
	_test_cancel_reasons()
	_test_contact_auto_cancel()
	_test_storm_no_cancel()
	_test_weighted_vs_plain()
	_test_integration_arrival()
	_test_hud_bar()
	_test_chart_appoint_row()

	_cleanup()
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d checks FAILED" % _checks)
		get_tree().quit(1)


# --- Fixtures ---------------------------------------------------------------

func _inject_pilots() -> void:
	for id in PILOTS:
		var card := _pilot_card(id, int(PILOTS[id]))
		DataLoader.officers[id] = card
		DataLoader.officers_list.append(card)


func _pilot_card(id: String, nav: int) -> Dictionary:
	return {
		"id": id, "role": "", "main_skill": "navigation",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": ["honest"],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 10},
		"skills": {"seamanship": 12, "navigation": nav, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·领航员%d" % nav, "en": "Test Pilot %d" % nav},
		"bio": {"zh": "测试", "en": "Fixture"},
	}


## Hires `id` into the pilot post (the roster + state block, the Skills API).
func _hire_pilot(id: String) -> void:
	GameState.player["officers"] = [id]
	GameState.officer_states[id] = {"loyalty": 50, "sea_days": 0,
		"post_id": "pilot", "ship_id": "", "talk_cd_day": 0,
		"gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0}


func _fire_pilot() -> void:
	GameState.player["officers"] = []


## Leaves port: the fleet stands on `port_id`'s berth at sea (not docked).
func _to_sea(port_id: String) -> void:
	GameState.current_port = null
	var berth: Vector2i = DataLoader.map.port_cell(port_id)
	if berth.x >= 0:
		GameState.set_world_tile(berth)


func _cleanup() -> void:
	for id in PILOTS:
		DataLoader.officers.erase(id)
		for index in range(DataLoader.officers_list.size() - 1, -1, -1):
			var entry = DataLoader.officers_list[index]
			if entry is Dictionary and str(entry.get("id", "")) == id:
				DataLoader.officers_list.remove_at(index)
	GameState.player["officers"] = []
	GameState.player.erase("autopilot")
	ChartViewLib.debug_row_override = -1
	if I18n.get_locale() != "en":
		I18n.set_locale("en")


# --- 1. The shared A* core: unit path untouched, weighted diverges ----------

func _test_fleet_path_weighted_core() -> void:
	# Synthetic 9×3 open grid; `passable` accepts everything in bounds. The
	# width keeps the fixtures OFF the seam (fleet_path is inherently
	# wrap-aware: on a 5-wide grid x=0 and x=4 are one step apart).
	var width := 9
	var height := 3
	var all: Callable = func(_cell: Vector2i) -> bool: return true
	# The unit-cost core returns the 4-step straight line (unchanged).
	var straight: Array = FleetPathLib.find_path(Vector2i(0, 1), Vector2i(4, 1),
		width, height, all)
	_check(straight.size() == 5 and straight[0] == Vector2i(0, 1)
		and straight[4] == Vector2i(4, 1),
		"unit find_path still returns the straight 4-step line")
	# Weighted with row 1 expensive (a head-wind band): the route detours
	# through the cheap row — distance is paid for cheaper days.
	var band: Callable = func(_a: Vector2i, b: Vector2i) -> float:
		return 10.0 if b.y == 1 else 1.0
	var detour: Array = FleetPathLib.find_path_weighted(Vector2i(0, 1),
		Vector2i(4, 1), width, height, all, band, {"min_step_cost": 0.5})
	_check(detour.size() == 5,
		"weighted search pays distance for cheap days (4-step detour, got %d)"
			% detour.size())
	var detour_cost := 0.0
	for index in range(1, detour.size()):
		detour_cost += float(band.call(detour[index - 1], detour[index]))
	_check(detour_cost < 40.0 + 0.001,
		"the weighted detour's cost is under the straight band-run's 40 (%0.1f)"
			% detour_cost)
	# Determinism: the same query twice, identical path.
	var again: Array = FleetPathLib.find_path_weighted(Vector2i(0, 1),
		Vector2i(4, 1), width, height, all, band, {"min_step_cost": 0.5})
	_check(again == detour, "weighted re-query is deterministic (same path)")
	# Wrap: (8,0) → (0,0) crosses the seam as one unit step.
	var wrap: Array = FleetPathLib.find_path_weighted(Vector2i(8, 0),
		Vector2i(0, 0), width, height, all,
		func(_a: Vector2i, _b: Vector2i) -> float: return 1.0,
		{"min_step_cost": 1.0})
	_check(wrap.size() == 2 and wrap[0] == Vector2i(8, 0)
		and wrap[1] == Vector2i(0, 0),
		"weighted search crosses the x-seam the short way")
	# No corner cutting: an L wall forces the walk round the corner.
	var wall: Dictionary = {Vector2i(1, 1): true, Vector2i(1, 0): true}
	var walled: Callable = func(cell: Vector2i) -> bool:
		return not wall.has(cell)
	var one: Callable = func(_a: Vector2i, _b: Vector2i) -> float: return 1.0
	var around: Array = FleetPathLib.find_path_weighted(Vector2i(0, 1),
		Vector2i(2, 1), width, height, walled, one, {"min_step_cost": 1.0})
	_check(_walk_is_legal(walled, one, around, width),
		"weighted walk stays legal (no corner cutting round the L wall)")
	_check(around.has(Vector2i(1, 2)),
		"the L-wall route goes round the corner through the open row")
	# Guards: same cell, impassable goal.
	_check(FleetPathLib.find_path_weighted(Vector2i(2, 1), Vector2i(2, 1),
		width, height, all, band) == [Vector2i(2, 1)],
		"weighted same-cell returns [from]")
	var blocked: Callable = func(cell: Vector2i) -> bool:
		return cell != Vector2i(3, 1)
	_check(FleetPathLib.find_path_weighted(Vector2i(0, 1), Vector2i(3, 1),
		width, height, blocked, band).is_empty(),
		"impassable goal returns [] (weighted)")
	# Expansion guard overflow returns [] instead of spinning.
	var tiny: Array = FleetPathLib.find_path_weighted(Vector2i(0, 1),
		Vector2i(4, 1), width, height, blocked, band,
		{"max_expansions": 3})
	_check(tiny.is_empty(), "the expansion guard bails out (weighted)")


## The §4.2 walking rule over a returned path (unit steps, passable targets,
## no corner cutting), wrap-aware in x — used for synthetic grids AND for the
## real weighted route below (with the in-month-ice passability composed in).
func _walk_is_legal(passable: Callable, cost_fn: Callable, path: Array,
		width: int) -> bool:
	if path.is_empty():
		return false
	for index in range(1, path.size()):
		var a: Vector2i = path[index - 1]
		var b: Vector2i = path[index]
		if float(cost_fn.call(a, b)) <= 0.0:
			return false
		var dx: int = b.x - a.x
		if dx > 1:
			dx -= width
		elif dx < -1:
			dx += width
		var dy: int = b.y - a.y
		if dx == 0 and dy == 0:
			return false
		if absi(dx) > 1 or absi(dy) > 1:
			return false
		if not bool(passable.call(b)):
			return false
		if dx != 0 and dy != 0:
			if not bool(passable.call(Vector2i(posmod(a.x + dx, width), a.y))):
				return false
			if not bool(passable.call(Vector2i(a.x, a.y + dy))):
				return false
	return true


# --- 2. Gate matrix (§4.19: pilot in post ∧ nav ≥ 40 ∧ dest known) ----------

func _test_gate_matrix() -> void:
	var row: Dictionary = DataLoader.get_skill_gate(AutopilotLib.GATE_FEATURE)
	_check(not row.is_empty() and int(row.get("threshold", 0)) == 40,
		"the skill_gates sail.autopilot row carries threshold 40")
	_check(AutopilotLib.gate_threshold() == 40,
		"gate_threshold reads the data row (40, doc fallback unused)")
	# No pilot in post.
	_fire_pilot()
	var none: Dictionary = AutopilotLib.gate(OD_FROM)
	_check(not bool(none.get("ok", true))
		and str(none.get("reason_key", "")) == "sail.autopilot"
		and int(none.get("threshold", 0)) == 40,
		"gate: no pilot → not ok, the sail.autopilot reason key, threshold 40")
	# Pilot at 39 (one under the threshold).
	_hire_pilot("off_ap_pilot_39")
	var low: Dictionary = AutopilotLib.gate(OD_FROM)
	_check(not bool(low.get("ok", true)) and int(low.get("pilot_nav", -1)) == 39,
		"gate: pilot navigation 39 fails")
	var low_text: String = AutopilotLib.reason_text(low)
	var en_text: String = I18n.t(row.get("reason", {}))
	_check(low_text == en_text and low_text.contains("40"),
		"reason_text resolves the skill_gates row through I18n (en, mentions 40)")
	# Pilot at exactly 40 — the gate opens; lisbon is the capital (known).
	_hire_pilot("off_ap_pilot_40")
	var ok: Dictionary = AutopilotLib.gate(OD_FROM)
	_check(bool(ok.get("ok", false)) and str(ok.get("reason_key", "")).is_empty()
		and bool(ok.get("dest_known", false)),
		"gate: pilot navigation 40 + known destination → ok, no reason key")
	# Unknown destination: a real but unvisited port, and a bogus id.
	var unknown: Dictionary = AutopilotLib.gate("nagasaki")
	_check(not bool(unknown.get("ok", true))
		and not bool(unknown.get("dest_known", true)),
		"gate: nagasaki (not in known_ports) fails on dest_known")
	_check(not bool(AutopilotLib.gate("atlantis").get("dest_known", true)),
		"gate: a bogus port id fails on dest_known")
	_check(AutopilotLib.reason_text(unknown).is_empty(),
		"an unknown destination has no gate reason row (renders plain-disabled)")
	# The gate never counts the PLAYER's navigation — the pilot's own (§4.19).
	GameState.player["skills"]["navigation"] = 100
	_fire_pilot()
	_check(not bool(AutopilotLib.gate(OD_FROM).get("ok", true)),
		"gate: a nav-100 PLAYER without a pilot still fails")
	GameState.player["skills"]["navigation"] = 0


# --- 3. Appoint → key + route (plain §4.2 path for nav 40–69) ---------------

func _test_appoint_and_key() -> void:
	_to_sea(OD_FROM)
	_hire_pilot("off_ap_pilot_40")
	var dest_berth: Vector2i = DataLoader.map.port_cell("seville")
	_check(dest_berth.x >= 0, "seville has a berth tile (the route's end)")
	# The appointment itself is free (§4.19: no gold fee) and touches no
	# ledger counter — provisions/water/wages consume on the day ticks the
	# WALK pays, never here.
	var gold_before := GameState.gold
	var prov_before: int = FleetLib.supplies("provisions")
	var water_before: int = FleetLib.supplies("water")
	var result: Dictionary = AutopilotLib.appoint("seville")
	_check(bool(result.get("ok", false)),
		"appoint(lisbon→seville) with a nav-40 pilot succeeds")
	var key = GameState.player.get("autopilot", null)
	_check(key is Dictionary and str(key.get("dest_port_id", "")) == "seville",
		"the save-v9 key player.autopilot = {dest_port_id} is written")
	_check(AutopilotLib.appointed() and AutopilotLib.dest_port_id() == "seville",
		"appointed()/dest_port_id() read the key")
	var route: Array = result.get("route", [])
	_check(not route.is_empty(), "a route was computed and stored")
	_check(route.back() == dest_berth,
		"the route ends on seville's berth tile (§4.11.1)")
	var map = DataLoader.map
	var width: int = int(map.width)
	var legal := true
	for index in range(1, route.size() + 1):
		var a: Vector2i = map.port_cell(OD_FROM) if index == 1 \
			else route[index - 2]
		var b: Vector2i = route[index - 1]
		if not SailPathLib.is_step_legal(map, a, b):
			legal = false
			break
	_check(legal, "the plain route is unit-legal §4.2 steps (sail_path core)")
	_check(not bool(result.get("weighted", true)),
		"a nav-40 pilot gets the plain wind-blind path (40–69 band)")
	var eta: float = AutopilotLib.eta_days(route)
	_check(eta > 0.0 and eta < 400.0,
		"the closed-form ETA is sane (%0.1f days for lisbon→seville)" % eta)
	_check(GameState.gold == gold_before,
		"no gold fee (§4.19): the purse is untouched by the appointment")
	_check(FleetLib.supplies("provisions") == prov_before
		and FleetLib.supplies("water") == water_before,
		"the ledger is untouched by the appointment (the walk pays the days)")
	# Refused appoint: the standing appointment is untouched (the gate is
	# checked BEFORE any state write), and a fresh call stores nothing.
	_fire_pilot()
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	var refused: Dictionary = AutopilotLib.appoint("seville")
	_check(not bool(refused.get("ok", true))
		and GameState.player.get("autopilot", null) == null,
		"a failed gate stores no key")
	_hire_pilot("off_ap_pilot_40")
	# Standing on the destination berth: legal appointment, immediate arrival.
	GameState.set_world_tile(dest_berth)
	var here: Dictionary = AutopilotLib.appoint("seville")
	_check(bool(here.get("ok", false))
		and (here.get("route", []) as Array).is_empty(),
		"appointing from the destination berth itself is legal (empty route)")
	var ticked: Dictionary = AutopilotLib.tick()
	_check(bool(ticked.get("arrived", false)),
		"tick() reports arrived when the fleet stands on the berth")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_ARRIVED),
		"the dock seam's cancel(\"arrived\") clears the appointment")
	_to_sea(OD_FROM)


# --- 4. Cancel reasons (§4.19 interrupts) -----------------------------------

func _test_cancel_reasons() -> void:
	_check(not AutopilotLib.cancel("storm"),
		"an unknown reason is refused")
	_check(not AutopilotLib.cancel(AutopilotLib.REASON_MANUAL),
		"cancel with nothing appointed returns false")
	_hire_pilot("off_ap_pilot_40")
	AutopilotLib.appoint("seville")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_MANUAL),
		"cancel(manual) clears a standing appointment")
	_check(GameState.player.get("autopilot", null) == null
		and not AutopilotLib.appointed(),
		"the key is gone after a manual cancel")
	_check((AutopilotLib.route() as Array).is_empty(),
		"the runtime route is dropped with the appointment")
	AutopilotLib.appoint("seville")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_CONTACT),
		"cancel(contact) clears a standing appointment")
	AutopilotLib.appoint("seville")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_ARRIVED),
		"cancel(arrived) clears a standing appointment")


# --- 5. Hostile contact auto-cancels (the world funnel calls cancel) --------

func _test_contact_auto_cancel() -> void:
	_check(DataLoader.ui_strings.has(AutopilotLib.CANCELLED_CONTACT_KEY),
		"the §4.10.4 contact notice key exists in ui_strings (zh/en data)")
	_hire_pilot("off_ap_pilot_40")
	AutopilotLib.appoint("seville")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_CONTACT),
		"the contact funnel's cancel(contact) reports the notice-worthy true")
	_check(not AutopilotLib.appointed(),
		"a hostile contact cancels the appointment (§4.10.4)")


# --- 6. Storms do NOT cancel — auto-reef fires and restores (§4.19) ---------

func _test_storm_no_cancel() -> void:
	_hire_pilot("off_ap_pilot_40")
	_to_sea(OD_FROM)
	AutopilotLib.appoint("seville")
	# A storm day: trim auto-reefs, the appointment stands.
	GameState.world["weather"] = "storm"
	GameState.world["sail_trim"] = "full"
	var storm_tick: Dictionary = AutopilotLib.tick()
	_check(bool(storm_tick.get("appointed", false)),
		"a storm day does NOT cancel the appointment (§4.19)")
	_check(AutopilotLib.appointed(),
		"the key survives the storm day")
	_check(SailingSimLib.sail_trim() == "reefed",
		"the §4.19 auto-reef forces `reefed` on the storm day")
	# Restore on the first non-storm tick.
	GameState.world["weather"] = "fair"
	AutopilotLib.tick()
	_check(SailingSimLib.sail_trim() == "full",
		"the player's previous trim (`full`) is restored after the storm")
	# A trim the player changed meanwhile stays theirs.
	GameState.world["weather"] = "storm"
	GameState.world["sail_trim"] = "normal"
	AutopilotLib.tick()
	GameState.world["sail_trim"] = "full"  # the player cycled `[`/`]`
	GameState.world["weather"] = "fair"
	AutopilotLib.tick()
	_check(SailingSimLib.sail_trim() == "full",
		"a player-chosen trim during the storm is never overwritten")
	GameState.world["sail_trim"] = "normal"
	# Cancel mid-storm restores the saved trim too.
	GameState.world["weather"] = "storm"
	GameState.world["sail_trim"] = "full"
	AutopilotLib.tick()
	_check(SailingSimLib.sail_trim() == "reefed", "storm trim active pre-cancel")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
		and SailingSimLib.sail_trim() == "full",
		"cancelling mid-storm restores the saved trim")
	GameState.world["weather"] = "fair"
	GameState.world["sail_trim"] = "normal"
	# Without an appointment tick() is a no-op: no reef, no reads.
	GameState.world["weather"] = "storm"
	GameState.world["sail_trim"] = "normal"
	var idle: Dictionary = AutopilotLib.tick()
	_check(not bool(idle.get("appointed", true))
		and SailingSimLib.sail_trim() == "normal",
		"no appointment: tick() does nothing (no auto-reef, no cancel)")


# --- 7. Weighted (nav 70) vs plain (nav 50) — the measurable difference -----

func _test_weighted_vs_plain() -> void:
	_to_sea(OD_FROM)
	GameState.day = 1  # month 1 — the NE-monsoon season (§4.15 lattice)
	if not (OD_TO in (GameState.known_ports as Array)):
		GameState.known_ports.append(OD_TO)
	var from_cell: Vector2i = DataLoader.map.port_cell(OD_FROM)
	var dest_berth: Vector2i = DataLoader.map.port_cell(OD_TO)
	_check(from_cell.x >= 0 and dest_berth.x >= 0,
		"OD endpoints have berth tiles (lisbon → malacca)")
	_check(SailingSimLib.month_for(GameState.day) == 1,
		"the fixture day sits in month 1 (the NE-monsoon season)")
	# Nav 70: the weighted search.
	_hire_pilot("off_ap_pilot_70")
	var t_w := Time.get_ticks_usec()
	var weighted: Dictionary = AutopilotLib.appoint(OD_TO)
	var weighted_ms := float(Time.get_ticks_usec() - t_w) / 1000.0
	_check(bool(weighted.get("ok", false)) and bool(weighted.get("weighted", false)),
		"nav-70 appoint uses the weighted A* (§4.19 route quality)")
	var w_route: Array = weighted.get("route", [])
	_check(not w_route.is_empty() and w_route.back() == dest_berth,
		"the weighted route ends on malacca's berth (%d steps)" % w_route.size())
	# Nav 50: the plain §4.2 path for the same OD.
	_hire_pilot("off_ap_pilot_50")
	var t_p := Time.get_ticks_usec()
	var plain: Dictionary = AutopilotLib.appoint(OD_TO)
	var plain_ms := float(Time.get_ticks_usec() - t_p) / 1000.0
	_check(bool(plain.get("ok", false)) and not bool(plain.get("weighted", true)),
		"nav-50 appoint uses the plain shortest-water A*")
	var p_route: Array = plain.get("route", [])
	_check(not p_route.is_empty() and p_route.back() == dest_berth,
		"the plain route ends on malacca's berth too (%d steps)" % p_route.size())
	print("NOTE  route search: weighted %.0f ms (%d steps) · plain %.0f ms (%d steps)"
		% [weighted_ms, w_route.size(), plain_ms, p_route.size()])
	_check(weighted_ms < 30000.0 and plain_ms < 30000.0,
		"both one-off appointment searches stay interactive (< 30 s)")
	# The §4.19 model cost over each route (the SAME closed function —
	# base × month-prevailing-wind heading factor × current vector factor,
	# expressed as days): the weighted route must win by ≥ 15% OR cross a
	# different set of wind regions (the locked "measurably differs").
	var w_cost: float = AutopilotLib.route_cost_days(from_cell, w_route)
	var p_cost: float = AutopilotLib.route_cost_days(from_cell, p_route)
	var w_regions: Array = AutopilotLib.route_wind_regions(from_cell, w_route)
	var p_regions: Array = AutopilotLib.route_wind_regions(from_cell, p_route)
	print("NOTE  model cost-days: weighted %0.1f vs plain %0.1f (ratio %0.3f) · regions differ: %s"
		% [w_cost, p_cost, w_cost / p_cost, str(w_regions != p_regions)])
	print("NOTE  weighted regions: %s" % str(w_regions))
	print("NOTE  plain regions:    %s" % str(p_regions))
	_check(w_cost > 0.0 and p_cost > 0.0, "model cost-days are positive")
	var cheaper_by_15 := w_cost <= p_cost * 0.85
	_check(cheaper_by_15 or w_regions != p_regions,
		"weighted measurably differs from plain: ≥15%% fewer cost-days (%s) or different wind-region crossings (%s)"
			% [str(cheaper_by_15), str(w_regions != p_regions)])
	# Legality of the weighted walk: §4.2 steps over map passability AND the
	# month's seasonal ice (the weighted route must avoid in-month ice).
	var ocean = OceanLayersLib.instance()
	var month := SailingSimLib.month_for(GameState.day)
	var width: int = int(DataLoader.map.width)
	var w_passable: Callable = func(cell: Vector2i) -> bool:
		if not DataLoader.map.is_passable(cell):
			return false
		return not ocean.ice_blocks(cell, month)
	var w_cost_fn: Callable = func(_a: Vector2i, _b: Vector2i) -> float:
		return 1.0
	_check(_walk_is_legal(w_passable, w_cost_fn, w_route, width),
		"the weighted walk is legal: unit §4.2 steps, passable, ice-free")
	# The plain route stays the distance baseline: the weighted route may
	# pay EXTRA tiles for cheaper days, but the trade stays bounded by the
	# corridor radius (the §4.19 corridor seeds the search on the plain path).
	_check(w_route.size() < p_route.size() * 13 / 10,
		"the weighted detour stays corridor-bounded (plain %d vs weighted %d steps)"
			% [p_route.size(), w_route.size()])
	# Determinism: recompute the weighted route twice, identical steps.
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	_hire_pilot("off_ap_pilot_70")
	var replay: Dictionary = AutopilotLib.appoint(OD_TO)
	_check((replay.get("route", []) as Array) == w_route,
		"the weighted route replays deterministically (same seed, same day)")
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)


# --- 8. Seeded integration: sail the appointment to the berth ---------------

func _test_integration_arrival() -> void:
	_to_sea("seville")
	var dest_berth: Vector2i = DataLoader.map.port_cell("seville")
	# Anchor one orthogonal step from the berth (a real 1–3 day sail).
	var start := Vector2i(-1, -1)
	for offset: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0),
			Vector2i(1, 0)]:
		var candidate := Vector2i(dest_berth.x + offset.x,
			dest_berth.y + offset.y)
		if candidate.y >= 0 and candidate.y < int(DataLoader.map.height) \
				and DataLoader.map.is_passable(candidate):
			start = candidate
			break
	_check(start.x >= 0, "seville's berth has a water neighbour to start from")
	GameState.set_world_tile(start)
	_hire_pilot("off_ap_pilot_40")
	var result: Dictionary = AutopilotLib.appoint("seville")
	_check(bool(result.get("ok", false)), "integration: the appointment stands")
	var route: Array = result.get("route", [])
	_check(not route.is_empty(), "integration: a route to the berth exists")
	# Walk it day by day through tick() — the appointment must survive every
	# intermediate tick and flip to `arrived` exactly on the berth.
	var walked := 0
	var arrived := false
	for guard in range(route.size() + 2):
		# The world's movement tick: step onto the route's head, one sea day.
		var state: Dictionary = AutopilotLib.tick()
		if bool(state.get("arrived", false)):
			arrived = true
			break
		var steps: Array = state.get("route", [])
		_check(not steps.is_empty(),
			"integration tick %d hands the world a non-empty route" % walked)
		if steps.is_empty():
			break
		GameState.set_world_tile(steps[0])
		GameState.day += 1
		walked += 1
	_check(arrived, "integration: the appointed sail reaches the berth (%d steps)"
		% walked)
	_check(walked == route.size(),
		"integration: tick() reported arrival exactly at the route's end")
	_check(GameState.world_tile() == dest_berth,
		"integration: the fleet stands on seville's berth")
	# The world's dock sequence clears the appointment (§4.19 "clears").
	_check(AutopilotLib.cancel(AutopilotLib.REASON_ARRIVED)
		and GameState.player.get("autopilot", null) == null,
		"integration: cancel(arrived) clears the key on docking")
	_to_sea(OD_FROM)


# --- 9. The HUD bar (§4.10.4; master instancing calls setup()) --------------

func _test_hud_bar() -> void:
	var hud = HudScene.instantiate()
	add_child(hud)
	hud.setup()
	_check(not hud.is_showing(), "the HUD bar hides while nothing is appointed")
	_hire_pilot("off_ap_pilot_40")
	_to_sea(OD_FROM)
	AutopilotLib.appoint("seville")
	hud.refresh()
	_check(hud.is_showing(), "the HUD bar shows while appointed")
	var port: Dictionary = DataLoader.get_port("seville")
	var text: String = hud.get_node("Info").text
	_check(text.contains(I18n.t(port.get("name", {}))),
		"the bar names the destination (%s)" % I18n.t(port.get("name", {})))
	_check(text == I18n.fmt("sail.autopilot.hud.bar",
			{"port": I18n.t(port.get("name", {})),
			"days": ceili(AutopilotLib.eta_days(AutopilotLib.route()))}),
		"the bar renders sail.autopilot.hud.bar with the closed-form ETA")
	# zh flip: the same read re-renders in the other locale.
	I18n.set_locale("zh")
	hud.refresh()
	_check(hud.get_node("Info").text.contains(
		I18n.t(port.get("name", {}))),
		"the bar re-renders on a locale flip (zh)")
	I18n.set_locale("en")
	# The cancel button is a manual cancel.
	hud.get_node("Cancel").pressed.emit()
	_check(not AutopilotLib.appointed() and not hud.is_showing(),
		"the bar's [取消委任] is a manual cancel: key cleared, bar hides")
	hud.free()


# --- 10. The chart's §4.10.4 appoint row (player mode; debug untouched) -----

func _test_chart_appoint_row() -> void:
	var chart = ChartScene.instantiate()
	add_child(chart)
	# Player mode (the S19 debug row OFF, the documented test seam).
	ChartViewLib.debug_row_override = 0
	chart.open_chart()
	_check(chart.is_open(), "the chart opens in player mode")
	var dot := Vector2i(-1, -1)
	for entry in chart.port_markers():
		if str(entry.get("port_id", "")) == OD_FROM:
			dot = entry["cell"]
	_check(dot.x >= 0, "lisbon draws as a known-port dot in player mode")
	var at: Vector2 = chart._to_screen(dot)
	# Gate grayed: no pilot → the appoint button is disabled with the reason.
	_fire_pilot()
	_press_at(chart, at)
	_check(chart._appoint_panel != null and chart._appoint_panel.visible,
		"a player-mode click on lisbon opens the appoint panel")
	_check(chart._appoint_port == OD_FROM, "the panel binds the clicked port")
	_check(chart._appoint_button != null and chart._appoint_button.disabled,
		"the gate grayed: the appoint button is disabled without a pilot")
	var reason: String = chart._appoint_status.text
	_check(not reason.is_empty()
		and reason.contains(I18n.t(DataLoader.get_skill_gate(
			AutopilotLib.GATE_FEATURE).get("reason", {}))),
		"the disabled button shows the skill_gates reason (%s)" % reason)
	# Esc closes the panel first, the chart on a second press.
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	chart._unhandled_input(esc)
	_check(chart._appoint_panel == null or not chart._appoint_panel.visible,
		"Esc closes the appoint panel first")
	_check(chart.is_open(), "the chart stays open behind the panel")
	# Success: a qualified pilot enables the row; appointing flips the panel
	# to the HUD-line info (destination / ETA).
	_hire_pilot("off_ap_pilot_40")
	_press_at(chart, at)
	_check(chart._appoint_panel.visible and not chart._appoint_button.disabled,
		"with a nav-40 pilot the appoint button is enabled")
	chart._appoint_button.pressed.emit()
	_check(AutopilotLib.appointed()
		and AutopilotLib.dest_port_id() == OD_FROM,
		"the chart row appointed lisbon through Autopilot.appoint")
	_check(chart._appoint_cancel_button.visible
		and not chart._appoint_button.visible,
		"the panel flipped to the HUD-line info (cancel shown, appoint gone)")
	var status: String = chart._appoint_status.text
	var port: Dictionary = DataLoader.get_port(OD_FROM)
	_check(status.contains(I18n.t(port.get("name", {}))),
		"the panel's status line is the sail.autopilot.hud.bar info")
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	chart.close_chart()
	# Debug mode byte-identical: the same click opens the DEBUG report, never
	# the appoint panel. The debug side panel shifts the world rect, so the
	# lisbon dot's screen position is re-read from the debug build.
	ChartViewLib.debug_row_override = 1
	chart.open_chart()
	var debug_dot := Vector2i(-1, -1)
	for entry in chart.port_markers():
		if str(entry.get("port_id", "")) == OD_FROM:
			debug_dot = entry["cell"]
	_check(debug_dot.x >= 0, "debug build carries the lisbon dot")
	_press_at(chart, chart._to_screen(debug_dot))
	_check(chart._port_panel != null and chart._port_panel.visible,
		"debug mode: the lisbon click still opens the pinned debug report")
	_check(chart._appoint_panel == null or not chart._appoint_panel.visible,
		"debug mode: the appoint panel is never opened")
	chart.close_chart()
	chart.free()


## A synthetic left-press on the chart at `at` (the test_chart drag style).
func _press_at(chart, at: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	chart._gui_input(press)
