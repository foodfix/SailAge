extends Node
## Phase-8 W5-A interaction-layer contract tests (docs/60-COMBAT.md
## §4.11.15 + §4.11.11.2; docs/80-UI-UX.md §4.10; docs/90-* §13 contract:
## headless, exit 0, `ALL PASS (N checks)`).
##
##   godot --headless res://tools/test_interactions.tscn
##
## Exits 0 when every check passes, 1 otherwise. Deterministic contract pins
## only — no RNG sweeps, world-scene boots only where the surface needs one.
## The W5 gate pins live here: **a coaster is not attackable** (module verbs
## + the rendered picker surface), the intercept order (set / re-target /
## auto-cancel / delivery through the untouched §4.11.11.2 funnel), the
## right-click dispatch (picker / port context / no-op), the appointed-
## voyage gate read, and a seeded replay asserting the same scenario twice.

const InteractionsLib := preload("res://scripts/world/interactions.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const PickerScene := preload("res://scenes/world/fleet_picker.tscn")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

## Open water in the world map's variables band, far from every harbor and
## off every lane/spoke tile (the ecology suites' fixture cell).
const OPEN_CELL := Vector2i(1400, 640)
## The dateline seam columns (the wrap-targeting pins, `20-*` §4.1).
const SEAM_EAST := Vector2i(4319, 640)
const SEAM_WEST := Vector2i(0, 640)

## A canon pirate card for the identified-name fixtures (data-driven — the
## suite pins behavior, never a generated id).
const PIRATE_ID := "pirate_edward_bloodhand"
## The navigation officer the appoint-gate fixtures seat as pilot (the
## strongest canon navigation card; ≥ 40 is the data gate's threshold).
const PILOT_ID := "off_leg_willem_barentsz"

var _failures: Array[String] = []
var _checks := 0
var _section := "<startup>"


func _ready() -> void:
	_section = "map load"
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "map loads for the interaction fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	NpcFleetsLib.reset_caches()

	_section = "1 targeting + verbs"
	_test_targeting_and_verbs()
	_section = "2 inspect summary"
	_test_inspect_summary()
	_section = "3 intercept arithmetic"
	_test_intercept_arithmetic()
	_section = "4 appoint gate"
	_test_appoint_gate()
	_section = "5 picker surface"
	_test_picker_surface()
	_section = "6 world right-click dispatch"
	await _test_world_dispatch()
	_section = "7 intercept lifecycle (world)"
	await _test_world_intercept()
	_section = "8 port context (world)"
	await _test_world_port_context()
	_section = "9 seeded replay"
	_test_seeded_replay()
	_section = "report"
	_report()


# --- Fixtures -----------------------------------------------------------------

## A bare W3-Person-model run with an empty ecology; navigation 0 keeps the
## sighting radius at the pinned base `48 + floor(0/12) = 48` (20-* §4.11).
func _make_run() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"officers": [],
		"equipment": {"weapon": "", "armor": ""},
		"reputation": {},
	}
	for nation_id in NATIONS:
		GameState.player["reputation"][nation_id] = 0
	GameState.fleet = [_ship("caravel")]
	GameState.day = 10
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = null
	GameState.known_ports = []
	GameState.world = {
		"position": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
		"clock_fraction": 0.0, "map_id": "world", "weather": "fair",
		"last_departed_port": "", "hunter_intel_cell": null,
	}
	GameState.npc_fleets = []
	GameState.wrecks = []
	GameState.npc_preset = "normal"
	GameState.captain_states = {}
	GameState.officer_states = {}
	NpcFleetsLib.reset_caches()


func _ship(ship_type_id: String) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	return {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0, "water": 0, "cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}


## A §4.15-shape fixture fleet; `captain_id` set directly (the lazy backfill
## seam is the day tick, and these fixtures never tick).
func _make_fleet(role: String, nation_id: String, cell: Vector2i,
		fleet_id: String = "", captain_id: String = "") -> Dictionary:
	var fleet := {
		"id": fleet_id if not fleet_id.is_empty() \
			else "fx_%s_%d" % [role, GameState.npc_fleets.size()],
		"role": role, "nation_id": nation_id,
		"cell": {"x": cell.x, "y": cell.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain_id": captain_id,
		"cooldown_until_day": 0, "seed": 424242, "dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
		"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
	}
	GameState.npc_fleets.append(fleet)
	return fleet


## Seats `officer_id` in the pilot post (the state the gate read walks).
## The canon card is never written — the below/above threshold halves use
## two different canon officers instead.
func _seat_pilot(officer_id: String) -> void:
	GameState.player["officers"] = [officer_id]
	GameState.officer_states[officer_id] = {
		"loyalty": 50, "sea_days": 0, "post_id": "pilot", "ship_id": "",
		"talk_cd_day": 0, "gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0,
	}


## A canon officer whose navigation is below the gate threshold (most cards
## carry navigation 0 — the first one found keeps the fixture data-driven).
func _find_low_navigation_officer() -> String:
	var gate: Dictionary = DataLoader.get_skill_gate("sail.autopilot")
	var threshold := int(gate.get("threshold", 40))
	for officer in DataLoader.officers_list:
		if int((officer as Dictionary).get("skills", {})
				.get("navigation", 0)) < threshold:
			return str((officer as Dictionary).get("id", ""))
	return ""


## Content equality for the verb lists (typed Array[String] vs literals).
func _verbs_equal(verbs, expected: Array) -> bool:
	if not (verbs is Array) or (verbs as Array).size() != expected.size():
		return false
	for index in range(expected.size()):
		if str((verbs as Array)[index]) != str(expected[index]):
			return false
	return true


## Dismisses every visible modal (HUD §4.7 queue included) — a day boundary
## rolled by a fixture move can queue weather dialogs that would otherwise
## gate the next input.
func _clear_modals() -> void:
	for pass_index in 64:
		var visible: Array = []
		for node in get_tree().get_nodes_in_group("modal_overlay"):
			if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
				visible.append(node)
		if visible.is_empty():
			return
		for node in visible:
			if node.has_method("close"):
				node.call("close")
			elif node.has_method("cancel"):
				node.call("cancel")


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


# --- 1. Targeting + verbs (docs/80-* §4.10.1, docs/60-* §4.11.15) -------------

func _test_targeting_and_verbs() -> void:
	_make_run()
	var trader := _make_fleet("trader", "portugal", OPEN_CELL,
		"fx_target_trader", "cap_trader_0001")
	_check(InteractionsLib.target_at(OPEN_CELL).get("id", "") \
			== str(trader["id"]),
		"target_at() resolves the fleet standing exactly on the tile")
	_check(InteractionsLib.fleets_at(OPEN_CELL).size() == 1,
		"fleets_at() lists the tile's fleet")
	# Two fleets share the tile: the pick list carries both, sorted by id.
	_make_fleet("pirate", "", OPEN_CELL, "fx_a_pirate", PIRATE_ID)
	var listed: Array = InteractionsLib.fleets_at(OPEN_CELL)
	_check(listed.size() == 2
		and str((listed[0] as Dictionary)["id"]) == "fx_a_pirate"
		and str((listed[1] as Dictionary)["id"]) == "fx_target_trader",
		"a multi-fleet tile lists every fleet, sorted by id ascending")
	_check(InteractionsLib.target_at(OPEN_CELL + Vector2i(3, 0)).is_empty(),
		"target_at() on an empty tile resolves {}")

	# Wrap targeting: x = 4319 and x = 0 are seam neighbours; an exact-tile
	# query normalises across the dateline both ways (20-* §4.1).
	_make_fleet("courier", "spain", SEAM_EAST, "fx_seam_courier")
	_check(InteractionsLib.target_at(SEAM_EAST).get("id", "") \
			== "fx_seam_courier",
		"a fleet at x = 4319 resolves from x = 4319 (no mod cut)")
	_check(InteractionsLib.target_at(Vector2i(-1, SEAM_EAST.y)) \
			.get("id", "") == "fx_seam_courier",
		"the exact-tile match wraps: a query at x = -1 resolves x = 4319")
	_check(InteractionsLib.target_at(Vector2i(8639, SEAM_EAST.y)) \
			.get("id", "") == "fx_seam_courier",
		"the exact-tile match wraps: a query at x = 8639 (2× the width) resolves x = 4319")
	_check(InteractionsLib.target_at(SEAM_WEST).is_empty(),
		"x = 4319 and x = 0 are different tiles (Chebyshev 1 apart)")
	_make_run()
	GameState.set_world_tile(SEAM_EAST)
	var west := _make_fleet("trader", "england", SEAM_WEST, "fx_west_trader")
	_check(InteractionsLib.in_range(west),
		"in_range() wraps: a fleet 1 tile across the seam is inside radius 48")
	_check(not InteractionsLib.in_range(west, 0),
		"in_range() with radius 0 still demands the exact tile across the seam")

	# Verbs: the §4.1.1 coaster pin — inspect/talk only, no attack.
	_make_run()
	var coaster := _make_fleet("coaster", "portugal", OPEN_CELL,
		"fx_verbs_coaster")
	_check(_verbs_equal(InteractionsLib.verbs_for(coaster),
			["inspect", "talk"]),
		"a coaster offers inspect + talk ONLY (no attack verb, §4.1.1)")
	for role in ["trader", "pirate", "privateer", "patrol", "courier",
			"hunter", "treasure"]:
		var fleet := _make_fleet(role, "portugal",
			OPEN_CELL + Vector2i(2, 0))
		_check(_verbs_equal(InteractionsLib.verbs_for(fleet),
				["inspect", "talk", "attack"]),
			"a %s offers inspect / talk / attack in row order" % role)
	_check(InteractionsLib.hail_in_range(coaster),
		"the hail gate is open at Chebyshev 0 (§4.11.15: ≤ 2)")
	GameState.set_world_tile(OPEN_CELL + Vector2i(2, 0))
	_check(InteractionsLib.hail_in_range(coaster),
		"the hail gate is open at Chebyshev 2")
	GameState.set_world_tile(OPEN_CELL + Vector2i(3, 0))
	_check(not InteractionsLib.hail_in_range(coaster),
		"the hail gate is shut at Chebyshev 3")


# --- 2. Inspect summary (docs/80-* §4.10.1; the unified card is W6's) ---------

func _test_inspect_summary() -> void:
	_make_run()
	var pirate := _make_fleet("pirate", "", OPEN_CELL, "fx_inspect_pirate",
		PIRATE_ID)
	var expected_name := I18n.t(CaptainsLib.captain(PIRATE_ID)
		.get("name", {}))
	var summary := InteractionsLib.inspect_summary(pirate)
	_check(summary.contains(expected_name),
		"the summary shows the canon captain's name")
	_check(summary.contains(I18n.t_key("captain.role.pirate")),
		"the summary shows the role name")
	_check(summary.contains(str(7)),
		"the summary shows the canon card level (7)")
	_check(summary == InteractionsLib.inspect_summary(pirate),
		"the summary is deterministic (same fleet → same card, §2.6)")
	CaptainsLib.adjust_stance(PIRATE_ID, 2)
	CaptainsLib.add_familiarity(PIRATE_ID, 4)
	summary = InteractionsLib.inspect_summary(pirate)
	_check(summary.contains(str(2)) and summary.contains(str(4)),
		"the summary reads stance/familiarity from Captains.state")
	var bare := _make_fleet("coaster", "portugal", OPEN_CELL + Vector2i(1, 0),
		"fx_inspect_bare")
	_check(InteractionsLib.display_name(bare) \
			== I18n.t_key("interact.unknown_name"),
		"a fleet with no canon card shows the unidentified fallback line")


# --- 3. Intercept arithmetic (docs/60-* §4.11.15) ------------------------------

func _test_intercept_arithmetic() -> void:
	_make_run()
	var pirate := _make_fleet("pirate", "", OPEN_CELL + Vector2i(20, 0),
		"fx_ic_pirate", PIRATE_ID)
	var order := InteractionsLib.intercept(pirate)
	_check(str(order.get("target_id", "")) == "fx_ic_pirate"
		and order.get("target_cell", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(20, 0),
		"intercept() stores {target_id, target_cell at set time}")
	_check(InteractionsLib.intercept_cancel_reason(order).is_empty(),
		"the order is valid while the target stands inside the sighting radius")
	_check(InteractionsLib.intercept_cancel_reason({}).is_empty(),
		"an empty order reads valid (the scene never asks without one)")
	# Beyond the sighting radius (48): one tile past the rim auto-cancels.
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(49, 0))
	_check(InteractionsLib.intercept_cancel_reason(order) == "left_sighting",
		"the target 49 tiles out (radius 48) answers left_sighting")
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(48, 0))
	_check(InteractionsLib.intercept_cancel_reason(order).is_empty(),
		"the target exactly on the radius rim stays chased (≤ 48)")
	# A target gone from the world entirely is out of sight too.
	GameState.npc_fleets.erase(pirate)
	_check(InteractionsLib.intercept_cancel_reason(order) == "left_sighting",
		"a vanished target answers left_sighting (nothing left in sight)")


# --- 4. The appointed-voyage gate (docs/20-* §4.19, 80-* §4.10.3) -------------

func _test_appoint_gate() -> void:
	_make_run()
	var gate := InteractionsLib.appoint_gate("lisbon")
	_check(not bool(gate.get("ok", true))
		and not str(gate.get("reason", "")).is_empty(),
		"without a pilot the gate fails with the data row's reason")
	_seat_pilot(_find_low_navigation_officer())
	gate = InteractionsLib.appoint_gate("lisbon")
	_check(not bool(gate.get("ok", true)),
		"a pilot below the threshold keeps the gate shut")
	_seat_pilot(PILOT_ID)
	GameState.known_ports = ["lisbon"]
	gate = InteractionsLib.appoint_gate("lisbon")
	_check(bool(gate.get("ok", false))
		and str(gate.get("reason", "")).is_empty(),
		"pilot ≥ 40 + a known port opens the gate")
	GameState.known_ports = []
	gate = InteractionsLib.appoint_gate("lisbon")
	_check(not bool(gate.get("ok", true)),
		"an unknown destination keeps the gate shut even with a pilot")


# --- 5. The picker surface (docs/80-* §4.10.1) ---------------------------------

func _test_picker_surface() -> void:
	_make_run()
	var coaster := _make_fleet("coaster", "portugal", OPEN_CELL,
		"fx_a_coaster")
	var pirate := _make_fleet("pirate", "", OPEN_CELL + Vector2i(1, 0),
		"fx_b_pirate", PIRATE_ID)
	var picker := PickerScene.instantiate()
	add_child(picker)
	picker.open_fleets([coaster, pirate])
	_check(picker.is_open(), "the picker opens over a fleet tile")
	_check(picker.row_count() == 2,
		"the pick list renders one row per fleet on the tile")
	_check(picker.title_text() == I18n.t_key("interact.pick.title"),
		"the picker title is the interact.pick.title line")
	var coaster_verbs: Dictionary = picker.row_verbs(0)
	var pirate_verbs: Dictionary = picker.row_verbs(1)
	_check(not coaster_verbs.has("attack"),
		"the coaster row renders NO attack button (the §4.1.1 surface pin)")
	_check(coaster_verbs.has("inspect") and coaster_verbs.has("talk"),
		"the coaster row still renders inspect + talk (intimidate lives there)")
	_check(pirate_verbs.has("attack") and pirate_verbs.has("inspect")
		and pirate_verbs.has("talk"),
		"the pirate row renders all three verbs")
	_check(picker.status_text().is_empty(),
		"no distance reason inside the hail range")
	_check(not (coaster_verbs["talk"] as Button).disabled,
		"talk is enabled within Chebyshev 2")
	# Beyond the hail range: talk grays with the distance reason (§4.10.1).
	GameState.set_world_tile(OPEN_CELL + Vector2i(9, 0))
	picker.open_fleets([coaster])
	_check((picker.row_verbs(0)["talk"] as Button).disabled,
		"talk grays beyond Chebyshev 2")
	_check(picker.status_text() == I18n.t_key("interact.talk.too_far"),
		"the distance reason is the interact.talk.too_far line")
	# `Esc` closes (§4.3); the menu leaves no modal behind in the same frame.
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	picker._unhandled_input(esc)
	_check(not picker.is_open(), "Esc closes the picker (§4.3)")
	_check(not _modals_visible(),
		"a closed picker leaves no modal behind")
	picker.queue_free()
	_make_run()


func _modals_visible() -> bool:
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	return false


# --- World-scene boots ----------------------------------------------------------

func _boot_world():
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	await get_tree().process_frame
	world.sync_from_state()
	return [host, world]


# --- 6. World-scene right-click dispatch (docs/80-* §4.10.1) -------------------

func _test_world_dispatch() -> void:
	_make_run()
	var pair: Array = await _boot_world()
	var host: Node2D = pair[0]
	var world = pair[1]
	var trader := _make_fleet("trader", "england", OPEN_CELL + Vector2i(12, 0),
		"fx_disp_trader", "cap_trader_0002")
	world.sync_from_state()
	# A fleet tile inside the sighting radius opens the picker.
	_check(world._open_interaction_at(OPEN_CELL + Vector2i(12, 0)),
		"right-click on an in-radius fleet tile opens the menu")
	var picker: Control = world.interaction_picker()
	_check(picker != null and picker.is_open() and picker.row_count() == 1,
		"the picker lists the tile's fleet")
	picker.close()
	# A fleet beyond the sighting radius is not a menu (§4.10.1 no-op).
	_check(not world._open_interaction_at(OPEN_CELL + Vector2i(60, 0)),
		"right-click beyond the sighting radius is a no-op (fleet invisible)")
	_check(not picker.is_open(), "the no-op leaves no menu open")
	# Empty water: no-op (no toast, no menu).
	_check(not world._open_interaction_at(OPEN_CELL + Vector2i(30, 5)),
		"right-click on empty water is a no-op")
	# Plain land: no-op — a genuinely solid, non-shore tile near Lisbon
	# (Iberia's interior; the search guard excludes every port's shore).
	var land := Vector2i(-1, -1)
	var lisbon: Vector2i = DataLoader.map.port_cell("lisbon")
	for dy in range(-30, 31):
		for dx in range(-30, 31):
			var candidate := lisbon + Vector2i(dx, dy)
			if candidate.y < 0 or candidate.y >= DataLoader.map.height:
				continue
			if not DataLoader.map.is_passable(candidate) \
					and DataLoader.map.shore_port_at(candidate).is_empty():
				land = candidate
				break
		if land.x >= 0:
			break
	_check(land.x >= 0 and not world._open_interaction_at(land),
		"right-click on plain land is a no-op (found %s)" % str(land))

	# The verb dispatch: inspect opens the summary message; talk far is
	# refused by the seam; talk near shows the hail placeholder title.
	world._on_picker_verb("inspect", trader)
	_check(world._message_dialog != null and world._message_dialog.is_open()
		and world._message_dialog.message_text()
			== InteractionsLib.inspect_summary(trader),
		"the inspect verb opens the summary line dialog (W6 card pending)")
	world._close_message()
	_check(not world._message_dialog.is_open(),
		"the message dialog closes and leaves no modal behind")
	world._on_picker_verb("talk", trader)
	_check(not world._message_dialog.is_open(),
		"talk beyond Chebyshev 2 is refused by the hail seam")
	world.npc_remove(str(trader["id"]))
	var near := _make_fleet("trader", "england", OPEN_CELL + Vector2i(2, 0),
		"fx_disp_near", "cap_trader_0001")
	world.sync_from_state()
	world._on_picker_verb("talk", near)
	_check(world._message_dialog.is_open()
		and world._message_dialog.message_text()
			== I18n.fmt("hail.title",
				{"name": InteractionsLib.display_name(near)}),
		"talk within range reaches the W5-B seam (placeholder = hail.title)")
	world._close_message()

	# The attack verb: adjacent coaster → refused at the surface (§4.1.1).
	var coaster := _make_fleet("coaster", "portugal", OPEN_CELL + Vector2i(1, 0),
		"fx_disp_coaster")
	world.sync_from_state()
	world._on_picker_verb("attack", coaster)
	_check(world._attack_confirm == null and not world.battle_in_progress()
		and world.pending_encounter_id().is_empty(),
		"a coaster is never dispatched (no confirm, no battle, §4.1.1)")
	# Adjacent pirate → straight into the funnel.
	var pirate := _make_fleet("pirate", "", OPEN_CELL + Vector2i(1, 0),
		"fx_disp_pirate", PIRATE_ID)
	world.sync_from_state()
	world._on_picker_verb("attack", pirate)
	_check(world.battle_in_progress()
		and world.pending_encounter_id() == "fx_disp_pirate"
		and world.intercept_order().is_empty(),
		"an adjacent pirate opens the battle straight through the funnel")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	world.cancel_sail()
	_clear_modals()
	# Adjacent national fleet → the piracy confirm first (the old funnel UX).
	var patrol := _make_fleet("patrol", "spain", OPEN_CELL + Vector2i(1, 0),
		"fx_disp_patrol")
	world.sync_from_state()
	world._on_picker_verb("attack", patrol)
	_check(world._attack_confirm != null and not world.battle_in_progress(),
		"an adjacent national fleet asks for the piracy confirm first")
	world._close_attack_confirm()
	host.queue_free()
	_make_run()


# --- 7. The intercept lifecycle in the world (docs/60-* §4.11.15) --------------

func _test_world_intercept() -> void:
	_make_run()
	var pair: Array = await _boot_world()
	var host: Node2D = pair[0]
	var world = pair[1]
	var pirate := _make_fleet("pirate", "", OPEN_CELL + Vector2i(20, 0),
		"fx_ic_pirate", PIRATE_ID)
	world.sync_from_state()
	# Attack beyond contact range → the intercept order + the click-to-sail
	# route onto the target's current cell.
	world._dispatch_attack(pirate)
	var order: Dictionary = world.intercept_order()
	_check(not order.is_empty()
		and str(order.get("target_id", "")) == "fx_ic_pirate"
		and order.get("target_cell", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(20, 0),
		"the attack verb beyond contact issues the intercept order")
	_check(world.sail_target() == OPEN_CELL + Vector2i(20, 0)
		and not world.sail_path().is_empty(),
		"the order rides the existing click-to-sail path")
	# An unmoved target re-targets nothing.
	world._tick_intercept()
	_check(world.intercept_order().get("target_cell", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(20, 0),
		"an unmoved target keeps the route as issued")
	# The target moves: the tick re-targets its CURRENT cell (§4.11.15).
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(23, 0))
	world._tick_intercept()
	_check(world.intercept_order().get("target_cell", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(23, 0)
		and world.sail_target() == OPEN_CELL + Vector2i(23, 0),
		"the tick re-targets the moving target's current cell")
	# The target leaves the sighting radius: auto-cancel + the whole order
	# (route included) drops.
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(50, 0))
	world._tick_intercept()
	_check(world.intercept_order().is_empty(),
		"the target outside the sighting radius auto-cancels the order")
	_check(world.sail_path().is_empty()
		and world.sail_target() == Vector2i(-1, -1),
		"the cancelled order drops its sail route too")
	# Manual input cancels: a direction press kills order + route.
	world._dispatch_attack(pirate)
	_check(not world.intercept_order().is_empty(),
		"a fresh order re-arms against the same target")
	world.press_direction("move_e")
	_clear_modals()
	_check(world.intercept_order().is_empty() and world.sail_path().is_empty(),
		"manual movement input cancels the intercept with its route")
	GameState.set_world_tile(OPEN_CELL)
	world.sync_from_state()
	world.cancel_sail()
	# Delivery: the order is armed while the target sits beyond contact,
	# then the chase closes and the UNCHANGED funnel opens the battle; the
	# order is consumed silently. The pirate's leap from 23 to 1 tile out is
	# the re-target tick's catch-up (the player never moved). The leap needs
	# the live sim's spatial index refreshed (the suites' fixture seam —
	# `NpcFleets.set_position` is the pure static; the index rebuild is the
	# caller's, exactly like `_make_fleet` in the ecology suites).
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(23, 0))
	world.sync_from_state()
	world._dispatch_attack(pirate)
	_check(not world.intercept_order().is_empty()
		and world.sail_target() == OPEN_CELL + Vector2i(23, 0),
		"the order re-arms for the delivery leg")
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(1, 0))
	world.fleet_sim().reset_index()
	world._tick_fleet_contacts()
	_check(world.battle_in_progress()
		and world.pending_encounter_id() == "fx_ic_pirate",
		"arrival fires the normal contact pipeline (single funnel)")
	_check(world.intercept_order().is_empty(),
		"the delivered order is consumed silently (no cancel notice)")
	_check(not (world.pending_encounter().get("ships", []) as Array).is_empty(),
		"the encounter carries the fleet's own seeded composition")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	world.cancel_sail()
	_clear_modals()
	host.queue_free()
	_make_run()


# --- 8. The port context (docs/80-* §4.10.3) -----------------------------------

func _test_world_port_context() -> void:
	_make_run()
	var pair: Array = await _boot_world()
	var host: Node2D = pair[0]
	var world = pair[1]
	var shore: Vector2i = DataLoader.map.shore_cell("lisbon")
	var berth: Vector2i = DataLoader.map.port_cell("lisbon")
	# The shore tile opens the port context (§4.10.3); a docked fleet would
	# resolve as a fleet first, so the empty berth is the clean fixture.
	_check(world._open_interaction_at(shore),
		"right-click on a port shore tile opens the port context")
	var picker: Control = world.interaction_picker()
	_check(picker.is_open()
		and picker.title_text() == I18n.t(
			DataLoader.get_port("lisbon").get("name", {})),
		"the port context titles itself with the port's name")
	var buttons: Dictionary = picker.port_buttons()
	_check(buttons.has("dock") and buttons.has("appoint"),
		"the context renders the dock + appoint-voyage rows (§4.10.3)")
	# Gate failing (no pilot): the appoint row grays with the reason.
	var appoint: Button = buttons["appoint"]
	_check(appoint.disabled and picker.status_text()
		== InteractionsLib.appoint_gate("lisbon").get("reason", ""),
		"the appoint row is disabled with the sail.autopilot gate reason")
	# The appoint row fires the W5-D seam (a certified no-op placeholder).
	GameState.known_ports = ["lisbon"]
	_seat_pilot(PILOT_ID)
	picker.close()
	_check(world._open_interaction_at(shore),
		"the context re-opens for the gate-pass fixture")
	buttons = picker.port_buttons()
	_check(not (buttons["appoint"] as Button).disabled
		and picker.status_text().is_empty(),
		"the gate passing enables the appoint row (placeholder for W5-D)")
	picker.close()
	var fleet_before: Array = GameState.fleet.duplicate(true)
	var day_before := int(GameState.day)
	world._on_port_action("appoint", "lisbon")
	_check(not GameState.player.has("autopilot")
		and int(GameState.day) == day_before
		and GameState.fleet.size() == fleet_before.size(),
		"the appoint seam is a W5-D placeholder (no state change)")
	# The dock row IS the walk-in flow: standing on the berth, it docks.
	GameState.set_world_tile(berth)
	world.sync_from_state()
	world._on_port_action("dock", "lisbon")
	_clear_modals()
	_check(GameState.current_port == "lisbon",
		"the dock row runs the existing walk-in flow (docked into S4 state)")
	host.queue_free()
	_make_run()


# --- 9. Seeded replay (the W5 gate pin) ----------------------------------------

## The replayed scenario: a two-fleet tile (multi-pick) with a pirate 12
## tiles east of the player — open the picker, list the rows, issue the
## intercept, chase two re-targets, lose the target past the radius rim.
## Every step is a pure function of the fixture (no RNG anywhere in the
## layer), so the signature must be identical on every replay.
func _scenario_signature() -> Dictionary:
	_make_run()
	_make_fleet("coaster", "portugal", OPEN_CELL + Vector2i(12, 0),
		"fx_rp_a_coaster")
	var pirate := _make_fleet("pirate", "", OPEN_CELL + Vector2i(12, 0),
		"fx_rp_b_pirate", PIRATE_ID)
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	world.sync_from_state()
	var signature := {}
	# 1. The multi-fleet pick: verb keys per row (coaster first by id).
	world._open_interaction_at(OPEN_CELL + Vector2i(12, 0))
	var picker: Control = world.interaction_picker()
	var rows := []
	for index in range(picker.row_count()):
		var verbs: Dictionary = picker.row_verbs(index)
		var keys := []
		for verb in ["inspect", "talk", "attack"]:
			if verbs.has(verb):
				keys.append(verb)
		rows.append(keys)
	signature["rows"] = rows
	_check(rows == [["inspect", "talk"], ["inspect", "talk", "attack"]],
		"replay: the coaster row carries no attack verb, the pirate row all three")
	picker.close()
	# 2. The intercept sets onto the shared tile.
	world._dispatch_attack(pirate)
	signature["intercept"] = world.intercept_order() \
		.get("target_cell", Vector2i(-9, -9))
	signature["sail_target"] = world.sail_target()
	# 3. Two chase legs (the target flees east), then past the rim.
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(14, 0))
	world._tick_intercept()
	signature["retarget_1"] = world.sail_target()
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(15, 0))
	world._tick_intercept()
	signature["retarget_2"] = world.intercept_order() \
		.get("target_cell", Vector2i(-9, -9))
	NpcFleetsLib.set_position(pirate, OPEN_CELL + Vector2i(61, 0))
	world._tick_intercept()
	signature["order_after_rim"] = world.intercept_order().is_empty()
	signature["route_after_rim"] = world.sail_path().is_empty()
	host.queue_free()
	_make_run()
	return signature


func _test_seeded_replay() -> void:
	var first := _scenario_signature()
	var second := _scenario_signature()
	_check(first.get("intercept", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(12, 0)
		and first.get("sail_target", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(12, 0),
		"replay fixture: the intercept sets onto the target's set-time cell")
	_check(first.get("retarget_1", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(14, 0)
		and first.get("retarget_2", Vector2i(-9, -9))
			== OPEN_CELL + Vector2i(15, 0),
		"replay fixture: the chase re-targets each moved cell")
	_check(bool(first.get("order_after_rim", false))
		and bool(first.get("route_after_rim", false)),
		"replay fixture: past the rim both the order and the route drop")
	_check(first == second,
		"the seeded replay is identical: same fixture → same signature")
