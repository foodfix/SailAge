extends Node
## Phase-9 W3-C (S10 rebuild) acceptance tests
## (docs/IMPLEMENT-Phase9.md W3-C slot; docs/60-COMBAT.md §4.2–§4.7, §4.3a,
## §4.4b, §4.11.2, §4.11.4, §4.11.9, §4.11.10, §4.12.1, §4.12.4; docs/80-UI-UX.md
## §4.3, §4.7.1, §4.8).
##
##   godot --headless --path . tools/test_battle_screen.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 the §4.7.1 camera pure functions — fixed-value assertions (world↔screen
##     round trip, clamp corners, zoom-anchor identity, minimap mapping of the
##     four corners + centre, edge-scroll band math, the 4 px threshold);
##   2 the scene: 1280×584 viewport over the 1536×960 world, the 192×120
##     minimap top-right, the 96 px bottom bar, the shot selector + [fit];
##   3 open_battle deploys per §4.11.2 (48×30), passes `wind_dir`/`current`
##     through, consumes the pending descriptor once;
##   4 the §4.3 velocity pick: highlighted endpoint cells ==
##     `legal_velocities` endpoints, click-a-vector moves, arrows cycle the
##     enumeration, `Enter` confirms, spent movement refuses;
##   5 the §4.7.1 shot selector: gates 25/50 grayed with `battle.shot.locked`,
##     grape range-1 only, `1`–`4` keys, the shot rides the cannon decision;
##   6 the §4.9 AI turn through the screen + the §4.7.1 AI-speed switch
##     (animate = one stepped turn per frame, instant = drain in one call);
##   7 a full player-vs-AI battle driven only through the UI API;
##   8 retreat and surrender through the `Esc` battle menu (with the
##     AI-speed switch buttons);
##   9 the after-action dialog: outcome numbers + both locales, no `<key>`;
##  10 the §4.12.4 guard behaviour when a sibling module is absent.
##  11 W4 — the §4.7.1 side-morale bars (guarded 100/100 pre-A seam, the
##     ≤ 20 WARN tier), the formation label + anchor-line seam (inactive
##     pre-B), the §4.9b fleet-dispatch guard (one AI turn without
##     fleet_commander.gd, exactly one warning), the fixture morale/
##     formation keys are byte-harmless pre-A, and the `battle.log.strike` /
##     `battle.log.surrender_enemy` surfacing through the generic pipeline.

const PaletteLib := preload("res://scripts/palette.gd")
const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const AiLib := preload("res://scripts/combat/ai_fleet.gd")
const SailingLib := preload("res://scripts/world/sailing_sim.gd")
const ScreenLib := preload("res://scenes/combat/battle_screen.gd")
const ScreenScene := preload("res://scenes/combat/battle_screen.tscn")

const BATTLE_RESULT_PATH := "res://scripts/combat/battle_result.gd"
const BATTLE_REWARDS_PATH := "res://scripts/combat/battle_rewards.gd"
## §4.11.2 deployment tiles (the table this screen must reproduce, 48×30).
const PLAYER_CELLS: Array = [
	Vector2i(2, 15), Vector2i(2, 14), Vector2i(2, 16), Vector2i(2, 13), Vector2i(2, 17),
]
const ENEMY_CELLS: Array = [
	Vector2i(45, 15), Vector2i(45, 14), Vector2i(45, 16), Vector2i(45, 13), Vector2i(45, 17),
]

var _failures: Array[String] = []
var _checks := 0

## Observation flags for the driving loop (a lambda cannot write a local back).
var _u_i_used_cannon := false
var _ui_used_move := false


func _ready() -> void:
	await _test_camera_functions()
	await _test_scene()
	await _test_open_battle()
	await _test_velocity_pick()
	await _test_shot_selector()
	await _test_ai_and_speed_switch()
	await _test_full_battle()
	await _test_retreat_and_surrender()
	await _test_after_action()
	await _test_guards()
	await _test_w4_morale_and_dispatch()
	_report()


# --- 1. Camera pure functions (docs/80-* §4.7.1) --------------------------

func _test_camera_functions() -> void:
	# world_to_screen: the camera centre lands at the viewport centre at
	# zoom 1.0; the world origin is offset by the half-extents.
	_check(ScreenLib.world_to_screen(Vector2(768, 480), Vector2(768, 480), 1.0)
			.is_equal_approx(Vector2(640, 292)),
		"world_to_screen: the camera centre maps to the viewport centre "
			+ "(768,480 → 640,292 @ zoom 1)")
	_check(ScreenLib.world_to_screen(Vector2.ZERO, Vector2(768, 480), 1.0)
			.is_equal_approx(Vector2(-128, -188)),
		"world_to_screen: the world origin maps to (-128,-188) @ cam "
			+ "(768,480) zoom 1")
	# screen_to_world is the exact inverse: round trip on three states.
	var round_trip_ok := true
	for state in [
		[Vector2(123, 456), Vector2(800, 300), 1.25],
		[Vector2.ZERO, Vector2(768, 480), 0.6],
		[Vector2(1536, 960), Vector2(700, 500), 1.5],
	]:
		var p: Vector2 = state[0]
		var cam: Vector2 = state[1]
		var zoom: float = state[2]
		var back := ScreenLib.screen_to_world(
			ScreenLib.world_to_screen(p, cam, zoom), cam, zoom)
		if back.distance_to(p) > 0.001:
			round_trip_ok = false
	_check(round_trip_ok,
		"screen_to_world inverts world_to_screen (three cam/zoom states, "
			+ "zoom 0.6 / 1.25 / 1.5, within 0.001 px)")

	# clamp_cam: both corners clamp inward; a fitted zoom centres.
	_check(ScreenLib.clamp_cam(Vector2.ZERO, 1.0).is_equal_approx(Vector2(640, 292)),
		"clamp_cam: the top-left corner clamps to the half-extents (640,292)")
	_check(ScreenLib.clamp_cam(Vector2(2000, 2000), 1.0)
			.is_equal_approx(Vector2(896, 668)),
		"clamp_cam: the bottom-right corner clamps to world − half (896,668)")
	_check(ScreenLib.clamp_cam(Vector2(500, 500), 0.6).is_equal_approx(Vector2(768, 480)),
		"clamp_cam: at zoom 0.6 the whole world fits, so any cam centres (768,480)")
	_check(ScreenLib.clamp_cam(Vector2(768, 100), 1.0).is_equal_approx(Vector2(768, 292)),
		"clamp_cam: only the offending axis clamps (768,100 → 768,292)")
	_check(ScreenLib.clamp_cam(Vector2(768, 480), 1.0).is_equal_approx(Vector2(768, 480)),
		"clamp_cam: a centred camera is a fixed point")

	# zoom_at: one notch in = ×1.25, cursor-anchored.
	var zoom_center := ScreenLib.zoom_at(1.0, 1.0, Vector2(640, 292), Vector2(768, 480))
	_check(is_equal_approx(float(zoom_center["zoom"]), 1.25)
			and (zoom_center["cam"] as Vector2).is_equal_approx(Vector2(768, 480)),
		"zoom_at: a notch at the viewport centre zooms ×1.25 and keeps the cam")
	var zoom_corner := ScreenLib.zoom_at(1.0, 1.0, Vector2.ZERO, Vector2(768, 480))
	_check((zoom_corner["cam"] as Vector2).is_equal_approx(Vector2(640, 421.6)),
		"zoom_at: a notch at the screen corner re-anchors the cam (640,421.6)")
	var anchored := ScreenLib.zoom_at(1.0, 1.0, Vector2(500, 400), Vector2(768, 480))
	var anchor_world := ScreenLib.screen_to_world(Vector2(500, 400),
		Vector2(768, 480), 1.0)
	var stays := ScreenLib.world_to_screen(anchor_world,
		anchored["cam"], anchored["zoom"])
	_check(stays.is_equal_approx(Vector2(500, 400)),
		"zoom_at: the world point under the cursor stays put (anchor identity "
			+ "at screen (500,400))")
	_check(is_equal_approx(float(ScreenLib.zoom_at(1.5, 1.0,
			Vector2(640, 292), Vector2(768, 480))["zoom"]), 1.5),
		"zoom_at: the zoom clamps at the 1.5× ceiling")
	_check(is_equal_approx(float(ScreenLib.zoom_at(0.6, -1.0,
			Vector2(640, 292), Vector2(768, 480))["zoom"]), 0.6),
		"zoom_at: the zoom clamps at the 0.6× floor")
	var zoom_out := ScreenLib.zoom_at(1.0, -1.0, Vector2(640, 292), Vector2(768, 480))
	_check(is_equal_approx(float(zoom_out["zoom"]), 0.8)
			and (zoom_out["cam"] as Vector2).is_equal_approx(Vector2(768, 480)),
		"zoom_at: a notch out divides by 1.25 (1.0 → 0.8)")

	# fit_zoom: 584/960 — height-bound (0.6083…), inside the zoom window.
	_check(is_equal_approx(ScreenLib.fit_zoom(), 584.0 / 960.0),
		"fit_zoom is the height-bound 584/960 (the [fit]/Home view)")

	# minimap_map: 4 px per cell ⇒ world px × 0.125; corners + centre.
	_check(ScreenLib.minimap_map(Vector2.ZERO).is_equal_approx(Vector2.ZERO),
		"minimap_map: the world's top-left maps to the minimap's top-left")
	_check(ScreenLib.minimap_map(Vector2(1536, 960)).is_equal_approx(Vector2(192, 120)),
		"minimap_map: the world's bottom-right maps to (192,120)")
	_check(ScreenLib.minimap_map(Vector2(768, 480)).is_equal_approx(Vector2(96, 60)),
		"minimap_map: the world centre maps to the minimap centre (96,60)")
	_check(ScreenLib.minimap_map(Vector2(45 * 32, 15 * 32)).is_equal_approx(
			Vector2(180, 60)),
		"minimap_map: enemy deployment cell (45,15) maps to (180,60) at 4 px/cell")

	# edge_scroll: 16 px band at 600 px/s, per axis.
	_check(ScreenLib.edge_scroll(Vector2(768, 480), Vector2(5, 300), 0.5)
			.is_equal_approx(Vector2(-300, 0)),
		"edge_scroll: the left band scrolls −600 px/s (5,300 × 0.5s → −300,0)")
	_check(ScreenLib.edge_scroll(Vector2(768, 480), Vector2(1275, 579), 0.5)
			.is_equal_approx(Vector2(300, 300)),
		"edge_scroll: the bottom-right corner scrolls both axes (+300,+300)")
	_check(ScreenLib.edge_scroll(Vector2(768, 480), Vector2(640, 292), 0.5)
			.is_equal_approx(Vector2.ZERO),
		"edge_scroll: the viewport centre is dead — no scroll")
	_check(ScreenLib.edge_scroll(Vector2(768, 480), Vector2(16, 16), 0.5)
			.is_equal_approx(Vector2.ZERO),
		"edge_scroll: exactly 16 px off the edge is outside the band")
	_check(ScreenLib.edge_scroll(Vector2(768, 480), Vector2(1270, 292), 0.25)
			.is_equal_approx(Vector2(150, 0)),
		"edge_scroll: the right band scales with delta_time (0.25s → 150)")

	# The 4 px click/drag threshold (§4.3).
	_check(ScreenLib.is_click(Vector2.ZERO, Vector2(4, 0)),
		"is_click: a 4 px move is a click")
	_check(not ScreenLib.is_click(Vector2.ZERO, Vector2(5, 0)),
		"is_click: a 5 px move is a drag")
	_check(not ScreenLib.is_click(Vector2.ZERO, Vector2(3, 3)),
		"is_click: the diagonal (3,3) ≈ 4.24 px is a drag")
	_check(ScreenLib.is_click(Vector2.ZERO, Vector2(2, 2)),
		"is_click: the diagonal (2,2) ≈ 2.83 px is a click")
	_check(is_equal_approx(ScreenLib.CLICK_THRESHOLD_PX, 4.0)
			and is_equal_approx(ScreenLib.EDGE_BAND_PX, 16.0)
			and is_equal_approx(ScreenLib.EDGE_SPEED, 600.0)
			and is_equal_approx(ScreenLib.ZOOM_MIN, 0.6)
			and is_equal_approx(ScreenLib.ZOOM_MAX, 1.5),
		"the §4.3 constants are pinned: 4 px threshold, 16 px band, 600 px/s, "
			+ "zoom 0.6×–1.5×")


# --- 2. Scene boot & layout (§4.7.1 wireframe) ----------------------------

func _test_scene() -> void:
	_make_run()
	var screen = await _new_screen()
	_check(screen != null, "S10 instantiates from battle_screen.tscn (headless boot)")
	if screen == null:
		return
	# §4.7.1: viewport 1280×584 under the 40 px top bar; bottom bar 96 px.
	var view: Control = screen.get_node("GridView")
	_check(view.size.is_equal_approx(Vector2(1280, 584)) and view.position.y == 40.0,
		"the camera viewport is 1280×584 under the 40 px top bar (§4.7.1)")
	var minimap: Control = screen.get_node("Minimap")
	_check(minimap.size.is_equal_approx(Vector2(192, 120))
			and minimap.position.is_equal_approx(Vector2(1080, 48)),
		"the minimap is 192×120 at the viewport's top-right (§4.7.1)")
	var bottom: ColorRect = screen.get_node("BottomPanel")
	_check(bottom.position.y == 624.0 and bottom.size.y == 96.0,
		"the bottom bar takes the rest of 1280×720 (96 px, §4.7.1)")
	_check(ScreenLib.WORLD_PX.is_equal_approx(Vector2(1536, 960))
			and is_equal_approx(ScreenLib.TILE_PX, 32.0)
			and ScreenLib.TOKEN_PX == 24,
		"the world is 48×30 tiles at 32 px = 1536×960; tokens are 24×24 (§4.2/§4.8)")
	_check(screen._overlay != null and screen._overlay.has_method("pick_velocity"),
		"the overlay carries the §4.7.1 velocity-pick pick")
	_check(is_equal_approx(screen.camera_state()["zoom"], ScreenLib.fit_zoom())
			and (screen.camera_state()["cam"] as Vector2).is_equal_approx(
				ScreenLib.clamp_cam(ScreenLib.WORLD_PX * 0.5, ScreenLib.fit_zoom())),
		"the camera opens fitted to the whole world (§4.3 [fit] default)")

	# The §4.7.1 shot selector + [fit] + bottom-bar labels exist and localise.
	var shot_labels: Array = []
	for shot_id in ["round", "chain", "armor_piercing", "grape"]:
		var button: Button = screen._shot_buttons.get(shot_id, null)
		if button == null:
			shot_labels.append("")
		else:
			shot_labels.append(button.text)
	_check(not shot_labels.has("") and shot_labels.size() == 4,
		"the four shot-selector buttons exist (§4.7.1)")
	_check(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/Fit") != null,
		"the [fit] button exists (§4.3 Home/[fit])")
	_check(screen.menu_button("ai_animate") != null
			and screen.menu_button("ai_instant") != null,
		"the battle menu carries the AI-turn speed switch (§4.3/§4.7.1)")
	_check(screen.action_button("cannon") != null
			and screen.action_button("hold") != null
			and screen.menu_button("retreat") != null
			and screen.menu_button("surrender") != null,
		"the four action buttons + the menu's Retreat/Surrender exist")

	# Open a battle: the bottom bar localises and the minimap draws a fixture.
	screen.route_to_world = false
	screen.open_battle(_pirate_encounter(2))
	await get_tree().process_frame
	var units: Array = screen.sim.units()
	_check(units.size() == 3,
		"the fixture fields 3 ships (1 player flagship + 2 enemies)")
	_check(not _has_raw_key(_bottom_bar_texts(screen)),
		"every bottom-bar label is localised, no raw <key> (%s)"
			% str(_bottom_bar_texts(screen)))
	_check(not _has_raw_key(_shot_labels_after(screen)),
		"the shot-selector labels are localised (%s)" % str(_shot_labels_after(screen)))
	_check(screen.get_node("TopRow/Title").text == screen._t("battle.title"),
		"the top bar carries battle.title")
	_check(screen.ai_instant_mode() == false,
		"the AI-turn speed defaults to animate (§4.7.1)")
	await _free_screen(screen)


# --- 3. open_battle (§4.11.2 + the §4.12.1 wind/current pass-through) -----

func _test_open_battle() -> void:
	_make_run()
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	var pending_before = _pending()
	screen.open_battle(_pirate_encounter(3))
	await get_tree().process_frame

	var decked := true
	for unit in screen.sim.units():
		var expected: Vector2i = PLAYER_CELLS[int(unit["index"])] \
			if str(unit["side"]) == "player" else ENEMY_CELLS[int(unit["index"])]
		if screen.sim.unit_cell(unit) != expected:
			decked = false
			print("      deployment mismatch: %s at %s (expected %s)"
				% [unit["side"], str(screen.sim.unit_cell(unit)), str(expected)])
	_check(decked, "§4.11.2: every ship deploys on its pinned 48×30 tile")
	_check(BattleLib.PLAYER_DEPLOYMENT == PLAYER_CELLS
			and BattleLib.ENEMY_DEPLOYMENT == ENEMY_CELLS,
		"BattleSim's deployment table is the §4.11.2 one")
	_check(screen.sim.round_number() == 1,
		"the battle starts on round 1 (%d)" % screen.sim.round_number())
	_check(not screen.is_over(),
		"open_battle sets up without running: no outcome yet")
	_check(screen.last_outcome.is_empty(),
		"open_battle leaves last_outcome empty")
	_check(screen.encounter.get("id") == "hf_9_30_40_pirate",
		"the encounter descriptor is retained (%s)"
		% str(screen.encounter.get("id")))
	_check(screen.sim.enemy_kind == "pirate" and screen.sim.contact == Vector2i(30, 40),
		"the engine gets the encounter kind and contact tile")

	# §4.12.1 pass-through: the encounter's locked battle conditions ride the
	# config verbatim; without them the engine defaults apply.
	var screened = await _new_screen_with_encounter({
		"id": "hf_wind_current", "kind": "pirate", "nation_id": "",
		"position": {"x": 30, "y": 40}, "day": 9, "ships": [_ship("sloop")],
		"wind_dir": "SW", "current": {"dir": "W", "strength": 2},
	})
	_check(str(screened.sim.wind_dir) == "SW",
		"a wind_dir-carrying encounter locks the battle's wind (SW)")
	_check((screened.sim.current as Dictionary).get("dir", "") == "W"
			and int((screened.sim.current as Dictionary).get("strength", -1)) == 2,
		"a current-carrying encounter locks the battle's current (W ×2)")
	await _free_screen(screened)
	_make_run()
	var defaults = await _new_screen_with_encounter(_pirate_encounter(1))
	_check(str(defaults.sim.wind_dir) == "E"
			and SailingLib.heading_index(str(defaults.sim.wind_dir)) >= 0,
		"without the key the engine defaults the wind (E, a valid 8-token id)")
	var default_current: Dictionary = defaults.sim.current
	_check(default_current.has("dir") and default_current.has("strength")
			and int(default_current.get("strength", -1)) in [0, 1, 2, 3],
		"without the key the engine defaults the current ({dir, strength 0..3})")
	await _free_screen(defaults)

	# `GameState.pending_encounter` is consumed exactly once (§4.11.11.3).
	if "pending_encounter" in GameState:
		var second = await _new_screen()
		second.route_to_world = false
		GameState.set("pending_encounter", {"id": "hf_pending", "kind": "pirate",
			"position": {"x": 30, "y": 40}, "ships": []})
		second.open_battle({})
		_check(second.encounter.get("id") == "hf_pending",
			"open_battle({}) consumes GameState.pending_encounter (%s)"
			% str(second.encounter.get("id")))
		_check(_pending() == null or (_pending() is Dictionary
				and (_pending() as Dictionary).is_empty()),
			"the pending descriptor is cleared on battle start (§4.11.11.3)")
		await _free_screen(second)
		# Production drops the descriptor on `GameState` and *then* routes, so
		# a freshly instanced screen picks the battle up in `_ready`.
		GameState.set("pending_encounter", {"id": "hf_routed", "kind": "navy",
			"nation_id": "spain", "position": {"x": 30, "y": 40}, "ships": []})
		var routed = await _new_screen()
		routed.route_to_world = false
		_check(routed.encounter.get("id") == "hf_routed",
			"a screen routed to with a queued encounter opens it in _ready (%s)"
			% str(routed.encounter.get("id")))
		_check(routed.sim.enemy_kind == "navy" and routed.sim.enemy_nation == "spain",
			"the routed encounter keeps its kind and nation")
		await _free_screen(routed)
	else:
		_check(true, "GameState.pending_encounter is absent on this base; "
			+ "the handoff is skipped (guarded, see the report)")
	_check(pending_before == null or pending_before is Dictionary,
		"the pending slot starts empty for this fixture")
	await _free_screen(screen)


# --- 4. The §4.3 velocity pick --------------------------------------------

func _test_velocity_pick() -> void:
	# Click-a-vector (§4.3 "click a legal vector").
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	var unit: Dictionary = screen.selected_unit()
	_check(not unit.is_empty(), "the player's flagship opens the round")
	if unit.is_empty():
		await _free_screen(screen)
		return

	var legal: Array = screen.sim.legal_velocities(unit)
	# A standstill accel-1 hull (the caravel) may pick ‖vel‖ ≤ 1: the zero
	# vector plus the four orthogonal unit vectors, (y, x)-ordered.
	_check(legal.size() == 5,
		"the standstill flagship enumerates the 5 (y,x)-ordered legal velocities "
			+ "at accel 1 (%d)" % legal.size())
	var endpoints: Array = screen.highlighted_cells()
	var expected_endpoints: Array = []
	for vel in legal:
		expected_endpoints.append(screen.sim.unit_cell(unit) + (vel as Vector2i))
	_check(str(endpoints) == str(expected_endpoints),
		"highlighted_cells() is the pos+vel endpoint set of legal_velocities()")
	_check(not endpoints.is_empty(), "the opener has reachable vectors")

	# Clicking a vector's endpoint cell applies that velocity (§4.3).
	var destination: Vector2i = Vector2i(3, 15)  # the endpoint of vel (1,0)
	var before_cell: Vector2i = screen.sim.unit_cell(unit)
	screen.click_cell(destination)
	await get_tree().process_frame
	_check(screen.sim.unit_cell(unit) == destination,
		"clicking a velocity endpoint moves the ship (%s → %s)"
			% [str(before_cell), str(destination)])
	_check((unit.get("vel", Vector2i.ZERO) as Vector2i) == Vector2i(1, 0),
		"the applied velocity rides the unit ((1,0))")
	_check(screen.sim.round_number() == 1 and not screen.is_over(),
		"a move does not end the turn (§4.3: movement once, then one action)")
	_check(screen.highlighted_cells().is_empty(),
		"the vectors clear once the turn's movement is spent")

	# The spent movement refuses a second pick (§4.3: movement once per turn).
	var spent: bool = screen.apply_selected_velocity(Vector2i(1, 0))
	_check(not spent, "a second velocity pick on the same turn is refused")
	screen.click_cell(destination)
	await get_tree().process_frame
	_check(screen.sim.unit_cell(unit) == destination,
		"a click with spent movement changes nothing (still %s)" % str(destination))
	await _free_screen(screen)

	# Keyboard: arrows cycle the enumeration, Enter confirms (§4.3).
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	unit = screen.selected_unit()
	legal = screen.sim.legal_velocities(unit)
	screen._unhandled_input(_key(KEY_RIGHT))
	_check(screen.cycled_velocity() == legal[0],
		"arrow-right cycles to the first enumeration entry (%s)"
			% str(legal[0]))
	screen._unhandled_input(_key(KEY_LEFT))
	_check(screen.cycled_velocity() == legal[legal.size() - 1],
		"arrow-left wraps to the last enumeration entry (%s)"
			% str(legal[legal.size() - 1]))
	screen._unhandled_input(_key(KEY_RIGHT))
	var cursor: Vector2i = screen.cycled_velocity()
	_check(cursor != BattleLib.NO_CELL, "a cycled velocity is armed for Enter")
	screen._unhandled_input(_key(KEY_ENTER))
	await get_tree().process_frame
	_check((unit.get("vel", Vector2i.ZERO) as Vector2i) == cursor,
		"Enter confirms the cycled velocity (vel %s)" % str(cursor))
	await _free_screen(screen)

	# An out-of-reach click parks the cursor and changes nothing.
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	unit = screen.selected_unit()
	var held_cell: Vector2i = screen.sim.unit_cell(unit)
	var log_before: int = screen.engine_log().size()
	screen.click_cell(Vector2i(47, 29))
	await get_tree().process_frame
	_check(screen.sim.unit_cell(unit) == held_cell,
		"a click off every vector parks the cursor (still %s)" % str(held_cell))
	_check(screen.engine_log().size() == log_before and not screen.is_over(),
		"a stray click logs nothing and ends nothing")
	await _free_screen(screen)

	# Clicking an enemy token in arc range is the default action (§4.7.1).
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	unit = screen.selected_unit()
	_place(screen.sim, "enemy", 0, Vector2i(2, 12))  # port-arc bearing, range 3
	screen._bind()
	var enemy_cell: Vector2i = screen.sim.unit_cell(_unit(screen, "enemy", 0))
	var enemy_durability: int = int(_unit(screen, "enemy", 0)["ship"]["durability"])
	_check(screen.target_cells().has(enemy_cell),
		"an in-arc-range enemy cell is highlighted as a target (%s)" % str(enemy_cell))
	_check(not screen.highlighted_cells().is_empty(),
		"the acting ship still shows its velocity vectors beside a target")
	screen.click_cell(enemy_cell)
	await get_tree().process_frame
	_check(_has_log_kind(screen, "cannon"),
		"clicking an enemy token fired the default cannon action")
	_check(int(_unit(screen, "enemy", 0)["ship"]["durability"]) < enemy_durability,
		"the volley landed on that hull (%d → %d)" % [enemy_durability,
			int(_unit(screen, "enemy", 0)["ship"]["durability"])])
	await _free_screen(screen)

	# An enemy outside every arc/range is not a target and takes no action.
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	var far_cell: Vector2i = screen.sim.unit_cell(_unit(screen, "enemy", 0))
	_check(not screen.target_cells().has(far_cell),
		"the deployment-distance enemy is not a target (§4.4 range 1..3)")
	var logs: int = screen.engine_log().size()
	screen.click_cell(far_cell)
	await get_tree().process_frame
	_check(screen.engine_log().size() == logs,
		"clicking an out-of-range enemy performs no action")
	await _free_screen(screen)


# --- 5. The §4.7.1 shot selector -------------------------------------------

func _test_shot_selector() -> void:
	# Gate states read the player's effective gunnery through the engine's
	# §4.4b accessors: chain 25 / armor-piercing 50 (the skill_gates data).
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})], {"gunnery": 2})
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	_check(screen.selected_shot() == BattleLib.ROUND_SHOT,
		"the selector defaults to round shot")
	var chain: Button = screen._shot_buttons[BattleLib.CHAIN_SHOT]
	var ap: Button = screen._shot_buttons[BattleLib.ARMOR_PIERCING_SHOT]
	var grape: Button = screen._shot_buttons[BattleLib.GRAPE_SHOT]
	_check(chain.disabled and str(chain.tooltip_text).contains("25"),
		"chain is grayed with battle.shot.locked {value: 25} at gunnery 2 (%s)"
			% str(chain.tooltip_text))
	_check(ap.disabled and str(ap.tooltip_text).contains("50"),
		"armor-piercing is grayed with battle.shot.locked {value: 50} at gunnery 2")
	_check(grape.disabled,
		"grape is disabled beyond Chebyshev range 1 (no adjacent target)")
	_check(not screen.select_shot("bogus"),
		"an unknown shot id is refused")

	# Gunnery 30 unlocks chain (≥ 25), not armor-piercing (< 50).
	screen.queue_free()
	await get_tree().process_frame
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})], {"gunnery": 30})
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	_check(not (screen._shot_buttons[BattleLib.CHAIN_SHOT] as Button).disabled,
		"chain unlocks at gunnery 30 (the §4.4b gate ≥ 25)")
	_check((screen._shot_buttons[BattleLib.ARMOR_PIERCING_SHOT] as Button).disabled,
		"armor-piercing stays locked at gunnery 30 (the gate is 50)")

	# The keys 1–4 pick the shot (§4.3).
	screen._unhandled_input(_key(KEY_2))
	_check(screen.selected_shot() == BattleLib.CHAIN_SHOT,
		"key 2 picks chain shot")
	screen._unhandled_input(_key(KEY_3))
	_check(screen.selected_shot() == BattleLib.ARMOR_PIERCING_SHOT,
		"key 3 picks armor-piercing")
	screen._unhandled_input(_key(KEY_4))
	_check(screen.selected_shot() == BattleLib.GRAPE_SHOT,
		"key 4 picks grape")
	screen._unhandled_input(_key(KEY_1))
	_check(screen.selected_shot() == BattleLib.ROUND_SHOT,
		"key 1 picks round shot")

	# The selected shot rides the cannon decision (§4.12.1.1 `shot`).
	screen._unhandled_input(_key(KEY_2))
	var unit: Dictionary = screen.selected_unit()
	_place(screen.sim, "enemy", 0, Vector2i(2, 13))  # port arc, range 2
	screen._bind()
	var result: Dictionary = screen.perform_action("cannon",
		_unit(screen, "enemy", 0))
	_check(bool(result.get("ok", false)) and str(result.get("shot", "")) == "chain",
		"the cannon decision carries the selected shot (chain, %s)"
			% str(result.get("shot")))
	await _free_screen(screen)

	# Grape enables at Chebyshev 1 (with a target in arc at range 1).
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})], {"gunnery": 2})
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	_place(screen.sim, "enemy", 0, Vector2i(2, 14))  # port arc, range 1
	screen._bind()
	_check(not (screen._shot_buttons[BattleLib.GRAPE_SHOT] as Button).disabled,
		"grape enables at Chebyshev range 1 (§4.4b)")
	await _free_screen(screen)


# --- 6. The §4.9 AI turn + the §4.7.1 AI-speed switch ----------------------

func _test_ai_and_speed_switch() -> void:
	# The switch: scene state only, toggled from the menu buttons.
	_make_run()
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	_check(not screen.ai_instant_mode(),
		"the AI speed starts on animate (跟随动画)")
	_check((screen.menu_button("ai_animate") as Button).disabled
			and not (screen.menu_button("ai_instant") as Button).disabled,
		"the active mode's menu button is disabled")
	_check(not _has_raw_key([screen.menu_button("ai_animate").text,
			screen.menu_button("ai_instant").text]),
		"the AI-speed buttons carry battle.ai_speed.* labels (%s/%s)"
			% [screen.menu_button("ai_animate").text,
			screen.menu_button("ai_instant").text])
	screen.menu_button("ai_instant").pressed.emit()
	_check(screen.ai_instant_mode(), "pressing 即时结算 switches to instant")
	_check((screen.menu_button("ai_instant") as Button).disabled,
		"the instant button disables while instant is active")
	screen.menu_button("ai_animate").pressed.emit()
	_check(not screen.ai_instant_mode(),
		"pressing 跟随动画 switches back to animate")
	await _free_screen(screen)

	# Instant mode: begin() drains every AI turn before the player's ship.
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)  # brigantine 24 kn out-runs the caravel's 20.
	screen.open_battle(_pirate_encounter(2, "brigantine"))
	await get_tree().process_frame
	screen.begin()
	_check(not screen.selected_unit().is_empty(),
		"instant mode drains the opening AI turns to the player's ship")
	await _free_screen(screen)

	# Animate mode: begin() applies ONE stepped AI turn per call (§4.7.1).
	# No await between open and begin: the animate `_process` stepper must not
	# advance the presentation mid-assertion.
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	screen = await _new_screen()
	screen.route_to_world = false
	screen.open_battle(_pirate_encounter(2, "brigantine"))
	screen.begin()
	var after_begin: Dictionary = screen.sim.current_unit()
	_check(not after_begin.is_empty()
			and str(after_begin.get("side", "")) == "enemy",
		"animate mode leaves the second enemy's turn pending after begin()")
	# run_ai_turn applies a decision and advances the cursor.
	var decision: Dictionary = screen.run_ai_turn()
	_check(decision.has("action"),
		"run_ai_turn returns the applied decision (%s)"
			% str(decision.get("action")))
	await _free_screen(screen)


# --- 7. Full battle through the UI API (§4.11.9) --------------------------

func _test_full_battle() -> void:
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20}), _ship("sloop")])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	screen.set_ai_speed(true)
	var opened := {"count": 0}
	var closed := {"count": 0, "outcome": {}}
	screen.battle_opened.connect(func(_e: Dictionary) -> void:
		opened["count"] = int(opened["count"]) + 1)
	screen.battle_closed.connect(func(outcome: Dictionary) -> void:
		closed["count"] = int(closed["count"]) + 1
		closed["outcome"] = outcome)

	# A strong fleet vs. a seeded 3-ship pirate encounter: the fight resolves.
	screen.open_battle(_pirate_encounter(3))
	await get_tree().process_frame
	screen.begin()
	_check(int(opened["count"]) == 1,
		"battle_opened fires exactly once per open_battle")

	_u_i_used_cannon = false
	_ui_used_move = false
	var guard := 0
	while not screen.is_over() and guard < 4000:
		guard += 1
		var unit: Dictionary = screen.selected_unit()
		if unit.is_empty():
			# The AI's turn: let the screen play it, then look again.
			screen._pump_enemy_turns()
			await get_tree().process_frame
			continue
		screen.select_unit(unit)
		if _press_any(screen, ["cannon", "board", "ram"]):
			continue
		# Nothing to shoot: close in through the click-a-vector handler.
		var cell := _approach(screen, unit)
		if cell != BattleLib.NO_CELL:
			screen.click_cell(cell)
			if bool(screen.get("_movement_spent")):
				_ui_used_move = true
				continue
		screen.action_button("hold").pressed.emit()
	await get_tree().process_frame

	_check(screen.is_over(), "the UI-driven battle reaches is_over() (%d steps)" % guard)
	var outcome: Dictionary = screen.last_outcome
	_check(not outcome.is_empty() and screen.battle_finished(),
		"last_outcome is filled at battle end")
	_check(str(outcome.get("result", "")) in BattleLib.RESULT_VALUES,
		"last_outcome.result is a §4.11.9 value (%s)" % str(outcome.get("result")))
	_check(int(closed["count"]) == 1 and closed["outcome"] == outcome,
		"battle_closed fires once, with the same outcome block")
	_check(_u_i_used_cannon, "the driving loop actually fired the cannon button")
	_check(_ui_used_move, "the driving loop actually moved through the click handler")
	_check(not screen.log_lines().is_empty() and not screen.engine_log().is_empty(),
		"the log is non-empty at the end (%d engine entries)"
			% screen.engine_log().size())
	_check(_joined_text(screen.log_lines()) != "",
		"the 3-line log panel is rendered (%s)" % str(screen.log_lines()))
	_check(screen.after_action_dialog().visible,
		"the after-action dialog is up at battle end (§4.7.1)")
	_check(outcome.has("salvage_gold") and outcome.has("xp")
			and outcome.has("rep_deltas") and outcome.has("captured_enemy"),
		"the outcome block carries the §4.12.2 payload")
	await _free_screen(screen)


# --- 8. Retreat & surrender through the menu (§4.3, §4.10, §4.11.7) -------

func _test_retreat_and_surrender() -> void:
	_make_run()
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	screen.begin()
	await get_tree().process_frame

	# Esc opens the menu; Retreat asks for `battle.retreat.confirm` first.
	screen.open_menu()
	_check(screen.menu_open(), "`Esc` opens the battle menu (§4.3)")
	_check(screen.menu_button("retreat") != null
			and screen.menu_button("surrender") != null
			and screen.menu_button("back") != null,
		"the menu offers Retreat / Surrender / back (§4.3)")
	_check(screen.has_modal(), "the open menu counts as a modal (§6)")
	screen.menu_button("back").pressed.emit()
	_check(not screen.menu_open(), "Back closes the menu without ending the battle")
	_check(not screen.is_over(), "the battle is still running after Back")

	screen.open_menu()
	screen.menu_button("retreat").pressed.emit()
	var confirm: Control = screen.confirm_dialog()
	_check(confirm != null and confirm.visible,
		"Retreat asks for confirmation first (§4.12.5)")
	_check(not screen.is_over(), "no outcome is applied before the confirmation")
	confirm.accept()
	await get_tree().process_frame
	_check(str(screen.last_outcome.get("result", "")) == "retreat",
		"the confirmed retreat ends the battle with result `retreat` (%s)"
		% str(screen.last_outcome.get("result", "")))
	_check(int(screen.last_outcome.get("xp", -1)) == 0,
		"a retreat awards no XP (§4.10): %d" % int(screen.last_outcome.get("xp", -1)))
	_check(screen.after_action_dialog().visible,
		"the retreat still shows the after-action dialog (§4.12.4 step 5)")
	await _free_screen(screen)

	# Surrender: the pirate path keeps every hull (§4.11.7).
	_make_run()
	screen = await _new_screen()
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	screen.begin()
	screen.open_menu()
	screen.menu_button("surrender").pressed.emit()
	_check(screen.confirm_dialog().visible,
		"Surrender asks for confirmation first (§4.12.5)")
	screen.confirm_dialog().accept()
	await get_tree().process_frame
	_check(str(screen.last_outcome.get("result", "")) == "surrender",
		"the confirmed surrender ends the battle with result `surrender` (%s)"
		% str(screen.last_outcome.get("result", "")))
	_check(screen.last_outcome.get("lost_player", []).is_empty(),
		"a pirate surrender takes the hold, not the hulls (§4.11.7)")
	await _free_screen(screen)


# --- 9. After-action dialog (§4.7.1, §4.12.2/§4.12.5) ---------------------

func _test_after_action() -> void:
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	screen.set_ai_speed(true)
	# A nearly-wrecked enemy: one volley sinks her, so the fixture is a
	# deterministic victory with real salvage gold (§4.11.10).
	var encounter := _pirate_encounter(1, "latin")
	(encounter["ships"][0] as Dictionary)["durability"] = 5
	screen.open_battle(encounter)
	await get_tree().process_frame
	screen.run_to_completion(30)
	_check(screen.is_over() and not screen.last_outcome.is_empty(),
		"the fixture battle finished (%s)" % str(screen.last_outcome.get("result")))
	_check(str(screen.last_outcome.get("result", "")) == "victory",
		"the fixture is a victory (%s)" % str(screen.last_outcome.get("result")))
	_check(int(screen.last_outcome.get("salvage_gold", 0)) > 0,
		"the outcome carries the §4.11.10 salvage gold (%d)"
		% int(screen.last_outcome.get("salvage_gold", 0)))
	var lines: Array = screen.after_action_lines()
	var joined := _joined_text(lines)
	_check(lines.size() >= 4,
		"the dialog lists the result, loot, XP and the rest (%d lines)"
		% lines.size())
	_check(screen.world_route_target() == "",
		"the S3 route waits for the dialog's Continue (§4.7.1)")
	_check(joined.contains(str(int(screen.last_outcome.get("salvage_gold", 0)))),
		"the dialog prints the salvage gold number (%d)"
		% int(screen.last_outcome.get("salvage_gold", 0)))
	_check(joined.contains(str(int(screen.last_outcome.get("xp", 0)))),
		"the dialog prints the XP number (%d)"
		% int(screen.last_outcome.get("xp", 0)))
	_check(lines[0] == screen._t("battle.after.title"),
		"the dialog is titled %s" % str(lines[0]))
	_check(lines[1] == screen._t("battle.result.victory"),
		"the dialog's first body line is the localised victory line (%s)"
		% str(lines[1]))
	_check(joined.contains(str(int((screen.last_outcome.get("rep_deltas", {})
		as Dictionary).values()[0])) if not (screen.last_outcome.get("rep_deltas", {})
		as Dictionary).is_empty() else true),
		"the reputation delta the engine computed is shown (%s)" % joined)

	# Both locales, no raw `<key>` anywhere the screen renders.
	var locale_before: String = GameState.locale
	var seen: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		var rendered: Array = []
		rendered.append_array(screen.after_action_lines())
		rendered.append_array(screen.log_lines())
		for action_id in ["cannon", "ram", "board", "hold"]:
			rendered.append(screen.action_button(action_id).text)
		for shot_id in [BattleLib.ROUND_SHOT, BattleLib.CHAIN_SHOT,
				BattleLib.ARMOR_PIERCING_SHOT, BattleLib.GRAPE_SHOT]:
			rendered.append((screen._shot_buttons[shot_id] as Button).text)
		rendered.append_array(_bottom_bar_texts(screen))
		rendered.append(screen.get_node("TopRow/Title").text)
		rendered.append(screen.get_node("TopRow/Round").text)
		_check(not _has_raw_key(rendered),
			"no rendered label prints a raw <key> in locale '%s' (%s)"
			% [locale, str(_raw_keys(rendered))])
		_check(_joined_text(rendered) != "",
			"the screen renders text in locale '%s'" % locale)
		seen.append(_joined_text(screen.after_action_lines()))
	_check(str(seen[0]) != str(seen[1]),
		"the after-action dialog switches language on a locale change")
	I18n.set_locale(locale_before)
	await get_tree().process_frame
	_check(screen.world_route_target() == "",
		"the route target stays empty while the dialog is open")

	# The dialog lists every outcome row: captures, scuttles, overflow
	# and losses, all read from the outcome block (never recomputed).
	screen.last_outcome = {
		"result": "victory", "salvage_gold": 150, "xp": 65,
		"captured_enemy": [_ship("sloop")], "captured_ships": ["sloop"],
		"scuttled_enemy": [_ship("latin")], "scuttled_ships": ["latin"],
		"cargo_overflow_lost": 4,
		"lost_player": [_ship("caravel")], "lost_ships": ["caravel"],
		"rep_deltas": {"portugal": 2, "spain": 2},
	}
	screen._show_after_action()
	await get_tree().process_frame
	var full := _joined_text(screen.after_action_lines())
	var sloop_name := I18n.t(DataLoader.get_ship_type("sloop")["name"])
	var latin_name := I18n.t(DataLoader.get_ship_type("latin")["name"])
	var caravel_name := I18n.t(DataLoader.get_ship_type("caravel")["name"])
	_check(full.contains(sloop_name), "a captured hull is named in the dialog (%s)" % full)
	_check(full.contains(latin_name), "a scuttled hull is named in the dialog")
	_check(full.contains("4"), "the cargo overflow count is printed (§4.11.7)")
	_check(full.contains(caravel_name), "a lost player hull is named in the dialog")
	_check(full.contains("+2"), "the reputation deltas the engine computed are shown")
	_check(not _has_raw_key(screen.after_action_lines()),
		"the full dialog still prints no raw <key>")
	# Continue closes the dialog and exposes the S3 edge (§4.7.1, §4.12.4).
	screen._continue_after_battle()
	await get_tree().process_frame
	_check(not screen.after_action_dialog().visible, "Continue closes the dialog")
	screen.route_to_world = true
	_check(screen.world_route_target() == "res://scenes/world/world_map.tscn",
		"Continue exposes the S3 route when routing is allowed (%s)"
		% screen.world_route_target())
	_check(not screen.game_over_open(),
		"a live run shows no S9 overlay")
	await _free_screen(screen)

	# A `gameover.*` during the sequence means S9, never S3 (§4.12.4 step 5).
	_make_run([_ship("sloop")])
	screen = await _new_screen()
	screen.route_to_world = true
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "sloop"))
	await get_tree().process_frame
	screen.sim.retreat()
	screen._finish_battle()
	await get_tree().process_frame
	EventBus.game_over.emit("captured")
	await get_tree().process_frame
	_check(screen.game_over_raised, "a gameover.* signal sets the terminal flag")
	screen._continue_after_battle()
	await get_tree().process_frame
	_check(screen.game_over_open(),
		"a gameover.* shows S9 over S10 instead of routing to S3")
	_check(screen.world_route_target() == "",
		"no S3 route exists once a gameover fired (%s)"
		% screen.world_route_target())
	screen.route_to_world = false
	await _free_screen(screen)


# --- 10. §4.12.4 guard behaviour -------------------------------------------

func _test_guards() -> void:
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	screen.set_ai_speed(true)
	screen.open_battle(_pirate_encounter(1, "sloop"))
	await get_tree().process_frame
	screen.run_to_completion(30)
	await get_tree().process_frame
	_check(screen.is_over() and not screen.last_outcome.is_empty(),
		"the battle ends cleanly even with sibling modules absent (%s)"
		% str(screen.last_outcome.get("result")))
	var expected_result := 0 if ResourceLoader.exists(BATTLE_RESULT_PATH) else 1
	_check(screen.warning_count(BATTLE_RESULT_PATH) == expected_result,
		"BattleResult guard warns exactly %d time(s) (module %s) — got %d"
		% [expected_result, "present" if expected_result == 0 else "absent",
			screen.warning_count(BATTLE_RESULT_PATH)])
	var expected_rewards := 0 if ResourceLoader.exists(BATTLE_REWARDS_PATH) else 1
	_check(screen.warning_count(BATTLE_REWARDS_PATH) == expected_rewards,
		"BattleRewards guard warns exactly %d time(s) (module %s) — got %d"
		% [expected_rewards, "present" if expected_rewards == 0 else "absent",
			screen.warning_count(BATTLE_REWARDS_PATH)])
	_check(screen.warning_count("duel") <= 1,
		"the Duel guard never warns twice (%d)" % screen.warning_count("duel"))
	_check(screen.after_action_dialog().visible,
		"the after-action dialog is still shown when the seams are missing")
	_check(screen.last_outcome.has("cargo_overflow_lost"),
		"the outcome keeps the §4.12.2 shape without BattleResult")
	await _free_screen(screen)


# --- 11. W4: morale bars, formation display, §4.9b dispatch guard ----------

func _test_w4_morale_and_dispatch() -> void:
	# The §4.7.1 W4 HUD: bar presence + the guarded 100/100 pre-A seam.
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	_check(screen.get_node_or_null("TopBar/MoraleBox") != null,
		"W4: the morale bar block exists in the §4.7.1 top area")
	_check(screen.morale_label("player") != null
			and screen.morale_label("enemy") != null,
		"W4: both side-morale labels exist (player left, enemy right)")
	_check(screen.morale_fill("player") != null
			and screen.morale_fill("enemy") != null
			and screen.morale_track("player") != null,
		"W4: both side-morale bars (fill + track) exist")
	_check(screen.formation_label() != null,
		"W4: the formation label node exists near the minimap (§4.7.1)")

	screen.open_battle(_pirate_encounter(2, "brigantine"))
	await get_tree().process_frame

	# MERGED SEAM (W3-A + W4-A are in): the sim carries `side_morale`, so the
	# bars render the REAL side values — the guarded 100/100 fallback only
	# existed on the pre-A base (the guard-era pins are superseded here).
	_check(screen.sim.has_method("side_morale"),
		"W4 merged precondition: the engine carries side_morale")
	var shown_p: int = screen.side_morale_shown("player")
	var shown_e: int = screen.side_morale_shown("enemy")
	_check(shown_p == int(screen.sim.side_morale("player"))
			and shown_e == int(screen.sim.side_morale("enemy")),
		"W4 merged: the bars read the sim's real side morales (%d/%d)"
			% [shown_p, shown_e])
	var player_label: Label = screen.morale_label("player")
	var enemy_label: Label = screen.morale_label("enemy")
	_check(player_label.text == "%s %d" % [screen._t("battle.morale"), shown_p]
			and enemy_label.text == "%s %d" % [screen._t("battle.morale"), shown_e],
		"the morale labels read battle.morale + the value (%s / %s)"
			% [player_label.text, enemy_label.text])
	var fill: ColorRect = screen.morale_fill("player")
	var track: ColorRect = screen.morale_track("player")
	var expected_tier: Color = PaletteLib.WARN if shown_p <= 20 \
		else PaletteLib.GOOD
	_check(is_equal_approx(fill.size.x, track.size.x * float(shown_p) / 100.0)
			and fill.color.is_equal_approx(expected_tier),
		"the fill is value/100 of the track in the %s tier at %d"
			% [("WARN" if shown_p <= 20 else "GOOD"), shown_p])

	# The ≤ 20 tier is the §4.8a HUD-warning pin (display only) — exercised
	# directly here because a pre-A sim cannot produce a real low value.
	screen._set_morale_fill(fill, track, 15)
	_check(fill.color.is_equal_approx(PaletteLib.WARN)
			and is_equal_approx(fill.size.x, track.size.x * 0.15),
		"a side at/below the §4.8a gate (15 ≤ 20) fills WARN at value/100 "
			+ "(display only — player ships never auto-strike)")
	screen._set_morale_fill(fill, track, 100)

	# The §4.9b layer is MERGED (W4-B): the commander instantiates, but the
	# display stays LAYER × FORMATION gated — a pirate (swarm row) never
	# shows an anchor line or label even with the commander live.
	_check(screen.fleet_commander_active(),
		"W4 merged: the fleet-commander instance is live (post-B)")
	_check(screen.formation_anchor_line().is_empty(),
		"W4 merged: a swarm-profile battle keeps the anchor-line datum empty")
	_check(not screen.formation_label().visible,
		"W4 merged: the formation label stays hidden for non-line formations")

	# The dispatch path: one full AI turn WITH the commander — the §4.12.1.1
	# decision still returns, and the absent-module warning never fired.
	var decision: Dictionary = screen.run_ai_turn()
	_check(decision.has("action"),
		"W4 merged: run_ai_turn returns a §4.12.1.1 decision with the "
			+ "commander live (%s)" % str(decision.get("action")))
	_check(screen.warning_count(ScreenLib.FLEET_COMMANDER_PATH) == 0,
		"W4 merged: no absent-module warning (got %d)"
			% screen.warning_count(ScreenLib.FLEET_COMMANDER_PATH))
	await _free_screen(screen)

	# The S21 fixture keys are byte-harmless pre-A: two identical SANDBOX
	# fixtures — the only path the keys ever ride — differing only in
	# player_morale / enemy_morale / formation play byte-identical battles
	# (sandbox battles skip the aftermath, so no shared-GameState drift).
	_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
	var plain_fixture := {
		"sandbox": true, "id": "sandbox", "kind": "pirate", "nation_id": "",
		"day": 9, "gold": 0, "weather": "calm", "seed": 4242,
		"player_ships": [_ship("caravel", {"cannons": 4, "crew": 15})],
		"enemy_ships": [_ship("latin")],
	}
	var plain = await _new_screen_with_encounter(plain_fixture)
	if plain == null:
		return
	var keyed_fixture := plain_fixture.duplicate(true)
	keyed_fixture["player_morale"] = 13
	keyed_fixture["enemy_morale"] = 87
	keyed_fixture["formation"] = "column"  # ≠ the pirate row's swarm
	var keyed = await _new_screen_with_encounter(keyed_fixture)
	# MERGED: the keys TAKE EFFECT — the fixture morale values ride the
	# §4.12.1 config (the byte-harmless pre-A pin is superseded: with the
	# keys live, different morale fixtures legitimately diverge).
	_check(int(keyed.sim.side_morale("enemy")) == 87
			and int(keyed.sim.side_morale("player")) == 13,
		"the fixture morale keys reach the sim config (%d/%d)"
			% [int(keyed.sim.side_morale("player")),
				int(keyed.sim.side_morale("enemy"))])
	_check(str(keyed._enemy_profile.get("formation", "")) == "column",
		"the fixture formation override folds into the battle's profile row "
			+ "(%s)" % str(keyed._enemy_profile.get("formation")))
	_check(str(plain._enemy_profile.get("formation", "")) == "swarm",
		"without the override the profile keeps the §4.10 row's formation "
			+ "(%s)" % str(plain._enemy_profile.get("formation")))
	# The formation display is gated on the fleet LAYER × a line formation ×
	# a LIVE battle (`sim.is_over()` clears the datum): fire the round-start
	# dispatch seam directly (run_ai_turn would no-op on the player-first
	# turn), then the column datum must be live while the swarm-profile
	# plain battle keeps it empty.
	keyed._ensure_fleet_orders()
	var keyed_line: Dictionary = keyed.formation_anchor_line()
	_check(not keyed_line.is_empty()
			and str(keyed_line.get("formation", "")) == "column",
		"the column-profile battle carries a live anchor-ray datum (%s)"
			% str(keyed_line))
	_check(plain.formation_anchor_line().is_empty(),
		"the swarm-profile battle keeps the datum empty")
	var outcome_keyed: Dictionary = keyed.run_to_completion(20)
	# log.strike surfacing (§4.8a presentation, task item 5): the generic
	# pipeline already renders the engine's strike / surrender_enemy kinds —
	# nothing new added here.
	var rendered: Array = []
	keyed._present(rendered, {"kind": "strike",
		"values": {"side": "enemy", "unit": 0}})
	keyed._present(rendered, {"kind": "surrender_enemy",
		"values": {"side": "enemy", "unit": 0}})
	_check(rendered.size() == 2
			and str((rendered[0] as Dictionary).get("key")) == "battle.log.strike"
			and str((rendered[1] as Dictionary).get("key")) == "battle.log.surrender_enemy",
		"the pipeline renders strike → battle.log.strike and surrender_enemy "
			+ "→ battle.log.surrender_enemy (keys consumed, none invented)")
	await _free_screen(plain)
	await _free_screen(keyed)


# --- Fixtures --------------------------------------------------------------

func _make_run(fleet: Array = [], skills: Dictionary = {}) -> void:
	GameState.locale = "en"
	GameState.day = 12
	GameState.gold = 3000
	GameState.current_port = null
	GameState.world = {"position": {"x": 30, "y": 40}, "clock_fraction": 0.0,
		"weather": "calm"}
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 10},
		"skills": {
			"swordplay": 8, "seamanship": 9, "gunnery": int(skills.get("gunnery", 2)),
			"navigation": 5, "appraisal": 5, "negotiation": 5,
		},
		"xp": 0, "level": 1, "officers": [],
		"equipment": {"weapon": "", "armor": ""},
		"reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0,
			"ottoman": 0, "italy": 0},
	}
	GameState.fleet = fleet.duplicate(true) if not fleet.is_empty() \
		else [_ship("caravel", {"cannons": 4, "crew": 15})]
	if "pending_encounter" in GameState:
		GameState.set("pending_encounter", null)


## A §4.11.11 ship instance (the `40-*` §4.1 shape + §4.11.12 equipment).
func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


## A §4.11.11 encounter descriptor. `enemy_count` ships, all of `hull_id` (so a
## fixture knows the initiative order), plus the normalised §4.11.3 defaults.
func _pirate_encounter(enemy_count: int, hull_id: String = "sloop") -> Dictionary:
	var ships: Array = []
	for _index in enemy_count:
		ships.append(_ship(hull_id))
	return {
		"id": "hf_9_30_40_pirate",
		"kind": "pirate",
		"nation_id": "",
		"position": {"x": 30, "y": 40},
		"day": 9,
		"ships": ships,
	}


func _new_screen():
	var screen = ScreenScene.instantiate()
	add_child(screen)
	screen.route_to_world = false
	await get_tree().process_frame
	return screen


func _new_screen_with_encounter(encounter: Dictionary):
	var screen = await _new_screen()
	if screen != null:
		screen.open_battle(encounter)
		await get_tree().process_frame
	return screen


func _free_screen(screen) -> void:
	if screen != null and is_instance_valid(screen):
		screen.queue_free()
	await get_tree().process_frame


## Places a unit on `cell` — the §4.3a authoritative field (`pos`; the MP-era
## `cell` read is a compat fallback only).
func _place(sim, side: String, index: int, cell: Vector2i) -> void:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			unit["pos"] = cell
			return


func _unit(screen, side: String, index: int) -> Dictionary:
	for unit in screen.sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


func _pending():
	return GameState.get("pending_encounter") if "pending_encounter" in GameState else null


func _has_log_kind(screen, kind: String) -> bool:
	for entry in screen.engine_log():
		if entry is Dictionary and str(entry.get("kind", "")) == kind:
			return true
	return false


func _press_any(screen, action_ids: Array) -> bool:
	for action_id in action_ids:
		var button: Button = screen.action_button(action_id)
		if button == null or button.disabled:
			continue
		button.pressed.emit()
		if action_id == "cannon":
			_u_i_used_cannon = true
		return true
	return false


## The highlighted endpoint cell that closes the distance to the nearest enemy.
func _approach(screen, unit: Dictionary) -> Vector2i:
	var enemies: Array = screen.sim.living_units("enemy")
	if enemies.is_empty():
		return BattleLib.NO_CELL
	var target_cell: Vector2i = screen.sim.unit_cell(enemies[0])
	var best := _chebyshev(screen.sim.unit_cell(unit), target_cell)
	var best_cell := BattleLib.NO_CELL
	for cell in screen.highlighted_cells():
		var distance := _chebyshev(cell, target_cell)
		if distance < best:
			best = distance
			best_cell = cell
	return best_cell


## A synthetic `pressed` key event, the `tools/test_shipyard.gd` convention for
## driving `_unhandled_input`.
func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	return event


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## The bottom-bar label texts (the localisation sweep walks these).
func _bottom_bar_texts(screen) -> Array:
	return [
		(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/Speed") as Label).text,
		(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/Heading") as Label).text,
		(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/ReloadPort") as Label).text,
		(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/ReloadStarboard") as Label).text,
		(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/Wind") as Label).text,
		(screen.get_node("BottomPanel/Margin/Columns/LeftCol/StatsRow/WeatherLabel") as Label).text,
		(screen.get_node("BottomPanel/Margin/Columns/RightCol/ActionRow/Target") as Label).text,
	]


func _shot_labels_after(screen) -> Array:
	var out: Array = []
	for shot_id in [BattleLib.ROUND_SHOT, BattleLib.CHAIN_SHOT,
			BattleLib.ARMOR_PIERCING_SHOT, BattleLib.GRAPE_SHOT]:
		var button: Button = screen._shot_buttons.get(shot_id, null)
		out.append(button.text if button != null else "")
	return out


func _joined_text(values: Array) -> String:
	var parts: Array[String] = []
	for value in values:
		parts.append(str(value))
	return " | ".join(parts)


## Every string shaped like the `I18n.t_key` missing-entry marker (§6).
func _raw_keys(values: Array) -> Array[String]:
	var out: Array[String] = []
	for value in values:
		var text := str(value)
		if text.begins_with("<") and text.ends_with(">") and text.length() > 2 \
				and not text.contains(" "):
			out.append(text)
	return out


func _has_raw_key(values: Array) -> bool:
	return not _raw_keys(values).is_empty()


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
	else:
		print("%d of %d checks FAILED:" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - " + failure)
	get_tree().quit(0 if _failures.is_empty() else 1)
