extends Node
## Phase-2 task D (battle scene + HUD) acceptance tests
## (docs/IMPLEMENT-Phase2.md D; docs/60-COMBAT.md §4.2–§4.10, §4.11.2,
## §4.11.4, §4.11.9, §4.11.10, §4.12.4, §4.12.5; docs/80-UI-UX.md §4.3,
## §4.7.1, §4.8).
##
##   godot --headless --path . tools/test_battle_screen.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 the scene: 160 grid cells, one token per ship, palette/geometry;
##   2 open_battle deploys per §4.11.2 and starts on round 1;
##   3 click-to-move: highlights == BattleSim.legal_moves, legal moves move,
##     illegal clicks change nothing;
##   4 a full player-vs-AI battle driven only through the UI API;
##   5 the six §4.9 AI rules, each through the screen's own AI turn;
##   6 retreat and surrender through the `Esc` battle menu;
##   7 the after-action dialog: outcome numbers + both locales, no `<key>`;
##   8 the §4.12.4 guard behaviour when a sibling module is absent.

const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const AiLib := preload("res://scripts/combat/ai_fleet.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ScreenScene := preload("res://scenes/combat/battle_screen.tscn")
const PaletteLib := preload("res://scripts/palette.gd")

const BATTLE_RESULT_PATH := "res://scripts/combat/battle_result.gd"
const BATTLE_REWARDS_PATH := "res://scripts/combat/battle_rewards.gd"
## §4.11.2 deployment tiles (the table this screen must reproduce).
const PLAYER_CELLS: Array = [
	Vector2i(1, 4), Vector2i(1, 5), Vector2i(1, 3), Vector2i(1, 6), Vector2i(1, 2),
]
const ENEMY_CELLS: Array = [
	Vector2i(14, 4), Vector2i(14, 5), Vector2i(14, 3), Vector2i(14, 6), Vector2i(14, 2),
]
## §4.7.1: 16×10 tiles at 48px.
const EXPECTED_CELLS := 160
const TILE_PX := 48.0

var _failures: Array[String] = []
var _checks := 0
var _screen = null

## Observation flags for the driving loop (a lambda cannot write a local back).
var _u_i_used_cannon := false
var _ui_used_move := false


func _ready() -> void:
	await _test_scene()
	await _test_open_battle()
	await _test_click_to_move()
	await _test_full_battle()
	await _test_ai_rules()
	await _test_retreat_and_surrender()
	await _test_after_action()
	await _test_guards()
	_report()


# --- 1. Scene -------------------------------------------------------------

func _test_scene() -> void:
	_make_run()
	var screen = await _new_screen()
	_check(screen != null, "S10 instantiates from battle_screen.tscn")
	if screen == null:
		return
	_check(screen.get_node("GridArea/Cells").get_child_count() == EXPECTED_CELLS,
		"the grid is 16×10 = %d tiles (%d)"
		% [EXPECTED_CELLS, screen.get_node("GridArea/Cells").get_child_count()])
	_check(screen._tiles.size() == EXPECTED_CELLS,
		"every tile is a palette ColorRect in the row-major tile array (§4.8)")
	# Geometry: 768×480 at 48px a tile, centred in 1280×720 (§4.2/§4.7.1).
	_check(is_equal_approx(screen.get_node("GridArea").size.x, 16.0 * TILE_PX)
			and is_equal_approx(screen.get_node("GridArea").size.y, 10.0 * TILE_PX),
		"the grid area is 768×480 at 48px a tile")
	var first_cell: ColorRect = screen._tiles[0]
	_check(first_cell.color.is_equal_approx(PaletteLib.SEA),
		"open water uses the palette SEA colour (no textures, §4.8)")
	_check(is_equal_approx(first_cell.size.x, TILE_PX),
		"a tile is 48px wide (§4.2)")

	# One token per ship, once a battle exists.
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20}), _ship("sloop")])
	screen.route_to_world = false
	screen.open_battle(_pirate_encounter(2))
	await get_tree().process_frame
	var units: Array = screen.sim.units()
	var tokens: int = screen.get_node("GridArea/Tokens").get_child_count()
	_check(tokens == units.size(),
		"one token is drawn per ship (%d tokens, %d units)" % [tokens, units.size()])
	_check(screen.sim.living_units("player").size() == 2
			and screen.sim.living_units("enemy").size() == 2,
		"the fixture fields 2 player and 2 enemy ships")
	_check(screen.action_button("cannon") != null
			and screen.action_button("surrender") != null,
		"the six action buttons exist (§4.7.1)")
	var labels: Array = []
	for action_id in ["cannon", "ram", "board", "hold", "retreat", "surrender"]:
		labels.append(screen.action_button(action_id).text)
	_check(not labels.has("") and not _has_raw_key(labels),
		"every action button carries a localised label (%s)" % str(labels))

	# §4.8 token colours: player `TEXT` with a black outline, pirate `BAD`.
	var player_token = _token_for(screen, _unit(screen, "player", 0))
	var enemy_token = _token_for(screen, _unit(screen, "enemy", 0))
	_check(player_token is Dictionary
			and (player_token["square"] as ColorRect).color.is_equal_approx(PaletteLib.TEXT),
		"a player token is the palette TEXT square (§4.8)")
	_check(enemy_token != null
			and (enemy_token["square"] as ColorRect).color.is_equal_approx(PaletteLib.BAD),
		"a pirate token is the palette BAD square (§4.8)")
	var letter: Label = player_token["label"] if player_token is Dictionary else null
	_check(letter != null and letter.text != "",
		"a token carries a letter (%s)" % (letter.text if letter != null else ""))
	_check(player_token is Dictionary
			and is_equal_approx((player_token["root"] as Control).size.x, 24.0),
		"a token is a 24×24 square (§4.8)")
	await _free_screen(screen)

	# A navy token takes the owning nation's `Nation.color` (§4.8).
	_make_run()
	screen = await _new_screen()
	screen.route_to_world = false
	screen.open_battle({"id": "hf_navy", "kind": "navy", "nation_id": "spain",
		"position": {"x": 30, "y": 40}, "day": 9, "ships": [_ship("sloop")]})
	await get_tree().process_frame
	var navy = _token_for(screen, _unit(screen, "enemy", 0))
	var spain: Dictionary = DataLoader.get_nation("spain")
	_check(navy is Dictionary and (navy["square"] as ColorRect).color.is_equal_approx(
			PaletteLib.nation_color(str(spain.get("color", "#ffffff")))),
		"a navy token uses the owning nation's colour (%s)"
		% (str((navy["square"] as ColorRect).color) if navy is Dictionary else "no token"))
	await _free_screen(screen)


# --- 2. open_battle (§4.11.2) --------------------------------------------

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
	_check(decked, "§4.11.2: every ship deploys on its pinned tile")
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
	# The engine's own deployment table agrees with the doc table.
	_check(BattleLib.PLAYER_DEPLOYMENT == PLAYER_CELLS
			and BattleLib.ENEMY_DEPLOYMENT == ENEMY_CELLS,
		"BattleSim's deployment table is the §4.11.2 one")

	# `GameState.pending_encounter` is consumed exactly once (§4.11.11.3).
	if "pending_encounter" in GameState:
		# The screen is instanced **before** the queue is filled, so this
		# exercises the explicit `open_battle({})` consumption rather than
		# `_ready`'s production pickup.
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
		_check(_pending() == null or (_pending() is Dictionary
				and (_pending() as Dictionary).is_empty()),
			"_ready consumes the queue too, so a re-entrant contact cannot "
			+ "open a second battle")
		await _free_screen(routed)
	else:
		_check(true, "GameState.pending_encounter is absent on this base; "
			+ "the handoff is skipped (guarded, see the report)")
	_check(pending_before == null or pending_before is Dictionary,
		"the pending slot starts empty for this fixture")
	await _free_screen(screen)


# --- 3. Click-to-move (§4.3, §4.7.1) ------------------------------------

func _test_click_to_move() -> void:
	_make_run()
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	# A latin (speed 4) enemy and a caravel (speed 5) player: the player opens
	# round 1, so the movement assertions never race an AI turn.
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	var unit: Dictionary = screen.selected_unit()
	_check(not unit.is_empty(), "the player's flagship opens the round")
	if unit.is_empty():
		await _free_screen(screen)
		return

	var legal: Array = screen.sim.legal_moves(unit)
	var highlighted: Array = screen.highlighted_cells()
	_check(str(highlighted) == str(legal),
		"highlighted_cells() is BattleSim.legal_moves() verbatim (%d cells)"
		% legal.size())
	_check(not legal.is_empty(), "the opener has reachable tiles")

	# Clicking a highlighted tile moves the ship and its token.
	var destination: Vector2i = legal[legal.size() / 2]
	var before_cell: Vector2i = screen.sim.unit_cell(unit)
	screen.click_cell(destination)
	await get_tree().process_frame
	_check(screen.sim.unit_cell(unit) == destination,
		"clicking a highlighted cell moves the ship (%s → %s)"
		% [str(before_cell), str(destination)])
	var token = _token_for(screen, unit)
	_check(token != null and _token_cell(screen, token) == destination,
		"the ship's token follows the move (token at %s)"
		% (str(_token_cell(screen, token)) if token != null else "no token"))
	_check(screen.sim.round_number() == 1 and not screen.is_over(),
		"a move does not end the turn (§4.3 \"up to MOVE followed by an action\")")

	# Clicking an unreachable tile changes nothing at all.
	var illegal := _unreachable_cell(screen, screen.sim.unit_cell(unit))
	var held_cell: Vector2i = screen.sim.unit_cell(unit)
	var mp_before := int(unit.get("mp", 0))
	screen.click_cell(illegal)
	await get_tree().process_frame
	_check(screen.sim.unit_cell(unit) == held_cell,
		"clicking an illegal cell changes nothing (still %s)" % str(held_cell))
	_check(int(unit.get("mp", 0)) == mp_before,
		"an illegal click costs no MP (%d)" % int(unit.get("mp", 0)))
	_check(screen.is_over() == false,
		"neither click ended the battle")
	await _free_screen(screen)

	# Keyboard (§4.3): arrows move the cursor, Enter confirms a move, Tab
	# cycles own ships, and clicking an enemy token is the default action.
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20}),
		_ship("brigantine", {"cannons": 6, "crew": 20})])
	screen = await _new_screen()
	screen.route_to_world = false
	# A slow enemy (latin, speed 4) so the player's brigantine opens the round.
	screen.open_battle(_pirate_encounter(1, "latin"))
	await get_tree().process_frame
	unit = screen.selected_unit()
	var cursor_before: Vector2i = screen._cursor
	screen._unhandled_input(_key(KEY_RIGHT))
	_check(screen._cursor != cursor_before,
		"an arrow key moves the targeting cursor (%s → %s)"
		% [str(cursor_before), str(screen._cursor)])
	var cursor: Vector2i = screen._cursor
	_check(screen.highlighted_cells().has(cursor),
		"the cursor lands on a highlighted tile (%s)" % str(cursor))
	screen._unhandled_input(_key(KEY_ENTER))
	await get_tree().process_frame
	_check(screen.sim.unit_cell(unit) == cursor,
		"Enter confirms the highlighted move (%s)" % str(cursor))
	_check(not screen.is_over() and screen.sim.round_number() == 1,
		"Enter's move did not also spend the turn's action")

	# Tab cycles the player's living ships via the cursor (§4.3).
	screen._unhandled_input(_key(KEY_TAB))
	_check(screen._cursor == screen.sim.unit_cell(_unit(screen, "player", 1)),
		"Tab cycles own ships to the next hull's cell (%s)" % str(screen._cursor))

	# Clicking an enemy token in range is the default action (§4.7.1).
	screen.select_unit(screen.selected_unit())
	var shooter: Dictionary = screen.selected_unit()
	if not shooter.is_empty():
		screen.sim.end_turn()
		screen._pump_enemy_turns()
		screen._bind()
		var gunner: Dictionary = screen.selected_unit()
		if not gunner.is_empty():
			# Put an enemy beside the shooter so a default action is available.
			_place(screen.sim, "enemy", 0,
				screen.sim.unit_cell(gunner) + Vector2i(2, 0))
			screen._bind()
			var enemy_cell: Vector2i = screen.sim.unit_cell(_unit(screen, "enemy", 0))
			_check(screen.target_cells().has(enemy_cell),
				"an in-range enemy cell is highlighted as a target (%s)"
				% str(enemy_cell))
			screen.click_cell(enemy_cell)
			await get_tree().process_frame
			_check(_has_log_kind(screen, "cannon") or _has_log_kind(screen, "board")
					or _has_log_kind(screen, "ram"),
				"clicking an enemy token performed the default action")
	await _free_screen(screen)


# --- 4. Full battle through the UI API (§4.11.9) -------------------------

func _test_full_battle() -> void:
	_make_run()
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
	var opened := {"count": 0}
	var closed := {"count": 0, "outcome": {}}
	screen.battle_opened.connect(func(_e: Dictionary) -> void:
		opened["count"] = int(opened["count"]) + 1)
	screen.battle_closed.connect(func(outcome: Dictionary) -> void:
		closed["count"] = int(closed["count"]) + 1
		closed["outcome"] = outcome)

	# A strong fleet vs. a seeded 3-ship pirate encounter: the fight resolves.
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20}), _ship("sloop")])
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
		# Nothing to shoot: step toward the enemy with the click handler.
		var cell := _approach(screen, unit)
		if cell != BattleLib.NO_CELL:
			var before: Vector2i = screen.sim.unit_cell(unit)
			screen.click_cell(cell)
			if screen.sim.unit_cell(unit) != before:
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


# --- 5. The six §4.9 AI rules, through the screen ------------------------

func _test_ai_rules() -> void:
	# 1. Below 25% max durability with a player ship within 3 → surrender.
	var r1 = await _ai_fixture(
		[_ship("sloop")],
		[_ship("sloop", {"durability": 14})],
		Vector2i(8, 4), Vector2i(5, 4), "sloop")
	var decision := _enemy_turn(r1)
	_check(str(decision.get("action", "")) == "surrender",
		"§4.9 rule 1: 14/60 durability with a player 3 tiles away surrenders (got %s)"
		% str(decision.get("action")))
	var enemy := _unit(r1, "enemy", 0)
	_check(not bool(enemy.get("alive", true)),
		"the surrendering hull leaves the battle (§4.7)")
	_check(r1.is_over() and int(r1.last_outcome.get("surrendered_enemy", 0)) == 1,
		"the surrender is counted in the outcome (%d)"
		% int(r1.last_outcome.get("surrendered_enemy", 0)))
	_check(r1.last_outcome.get("captured_enemy", []).size() == 1,
		"a surrender is a capture for the fleet seam (§4.11.7)")
	await _free_screen(r1)

	# 1b. The boundary: exactly 25% is not below the threshold.
	var r1b = await _ai_fixture(
		[_ship("sloop")],
		[_ship("sloop", {"durability": 15})],
		Vector2i(8, 4), Vector2i(5, 4), "sloop")
	_check(str(_enemy_turn(r1b).get("action", "")) != "surrender",
		"§4.9 rule 1 boundary: 15/60 = 25% does not surrender")
	await _free_screen(r1b)

	# 2. Cannons loaded, a target in range → fire at the lowest durability.
	var r2 = await _ai_fixture(
		[_ship("sloop", {"durability": 50}), _ship("latin", {"durability": 12})],
		[_ship("caravel", {"cannons": 6})],
		Vector2i(8, 4), Vector2i(6, 4), "caravel", Vector2i(7, 6))
	var fire := _enemy_turn(r2)
	_check(str(fire.get("action", "")) == "cannon",
		"§4.9 rule 2: a loaded cannon with a target in range fires (got %s)"
		% str(fire.get("action")))
	var fire_target: Dictionary = fire.get("target", {})
	_check(not fire_target.is_empty() and int(fire_target.get("index", -1)) == 1,
		"§4.9 rule 2 fires at the lowest-durability ship (index %d)"
		% int(fire_target.get("index", -1)))
	_check(int(_unit(r2, "player", 1)["ship"]["durability"]) < 12,
		"the volley landed on that hull (%d durability)"
		% int(_unit(r2, "player", 1)["ship"]["durability"]))
	_check(_has_log_kind(r2, "cannon"),
		"the volley produced a cannon log entry (§4.11.4)")
	await _free_screen(r2)

	# 3. Own cannons > total player cannons and adjacent to the flagship → board.
	var r3 = await _ai_fixture(
		[_ship("sloop", {"cannons": 1})],
		[_ship("brigantine", {"cannons": 6})],
		Vector2i(2, 4), Vector2i(1, 4), "brigantine")
	# Reloading, so rule 2 cannot fire first (the engine's own fixture trick).
	_unit(r3, "enemy", 0)["reload_until_round"] = 99
	var board := _enemy_turn(r3)
	_check(str(board.get("action", "")) == "board",
		"§4.9 rule 3: 6 cannons > 1 player cannon, adjacent to the flagship → board "
		+ "(got %s)" % str(board.get("action")))
	_check(int((board.get("target", {}) as Dictionary).get("index", -1)) == 0,
		"§4.9 rule 3 boards the player flagship (index 0)")
	_check(_has_log_kind(r3, "board"),
		"the boarding resolved through the engine's duel (§4.6)")
	await _free_screen(r3)

	# 4. Adjacent with weaker guns → ram.
	var r4 = await _ai_fixture(
		[_ship("caravel", {"cannons": 6})],
		[_ship("sloop", {"cannons": 2})],
		Vector2i(2, 4), Vector2i(1, 4), "sloop")
	_unit(r4, "enemy", 0)["reload_until_round"] = 99
	var ram := _enemy_turn(r4)
	_check(str(ram.get("action", "")) == "ram",
		"§4.9 rule 4: weaker guns, adjacent → ram (got %s)" % str(ram.get("action")))
	_check(int(_unit(r4, "player", 0)["ship"]["durability"]) < 90,
		"the ram damaged the player hull (%d/90)"
		% int(_unit(r4, "player", 0)["ship"]["durability"]))
	_check(_has_log_kind(r4, "ram"),
		"the ram produced a ram log entry")
	await _free_screen(r4)

	# 5. Move toward the nearest player ship, spending MP.
	var r5 = await _ai_fixture(
		[_ship("sloop")],
		[_ship("brigantine", {"cannons": 0})],
		Vector2i(14, 4), Vector2i(1, 4), "brigantine")
	var mover := _unit(r5, "enemy", 0)
	var before: Vector2i = r5.sim.unit_cell(mover)
	var advance := _enemy_turn(r5)
	_check(str(advance.get("action", "")) == "move",
		"§4.9 rule 5: no shot and no adjacency → move (got %s)"
		% str(advance.get("action")))
	var destination: Vector2i = advance.get("cell", BattleLib.NO_CELL)
	_check(destination != BattleLib.NO_CELL,
		"§4.9 rule 5 returns a destination cell")
	_check(r5.sim.unit_cell(_unit(r5, "enemy", 0)) == destination,
		"the screen applied the AI move (%s)" % str(destination))
	_check(_chebyshev(destination, r5.sim.unit_cell(_unit(r5, "player", 0)))
			< _chebyshev(before, r5.sim.unit_cell(_unit(r5, "player", 0))),
		"§4.9 rule 5 closed the Chebyshev distance (%s → %s)"
		% [str(before), str(destination)])
	await _free_screen(r5)

	# 6. Nothing improves → hold.
	var r6 = await _ai_fixture(
		[_ship("sloop", {"cannons": 0})],
		[_ship("sloop", {"cannons": 0})],
		Vector2i(2, 4), Vector2i(1, 4), "sloop")
	_check(str(_enemy_turn(r6).get("action", "")) == "hold",
		"§4.9 rule 6: zero cannons, already adjacent, no improvement → hold")
	await _free_screen(r6)


# --- 6. Retreat & surrender through the menu (§4.3, §4.10, §4.11.7) -----

func _test_retreat_and_surrender() -> void:
	_make_run()
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
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


# --- 7. After-action dialog (§4.7.1, §4.12.5) ---------------------------

func _test_after_action() -> void:
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
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
		for action_id in ["cannon", "ram", "board", "hold", "retreat", "surrender"]:
			rendered.append(screen.action_button(action_id).text)
		rendered.append(screen.get_node("TopRow/Title").text)
		rendered.append(screen.get_node("TopRow/Round").text)
		rendered.append(screen.get_node("BottomPanel/Margin/VBox/StatsRow/Flagship").text)
		rendered.append(screen.get_node("BottomPanel/Margin/VBox/StatsRow/Durability").text)
		rendered.append(screen.get_node("BottomPanel/Margin/VBox/StatsRow/Crew").text)
		rendered.append(screen.get_node("BottomPanel/Margin/VBox/StatsRow/Cannons").text)
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

	# The dialog lists every §4.12.5 outcome row: captures, scuttles, overflow
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


# --- 8. §4.12.4 guard behaviour -----------------------------------------

func _test_guards() -> void:
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
	var screen = await _new_screen()
	if screen == null:
		return
	screen.route_to_world = false
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


# --- Fixtures -------------------------------------------------------------

func _make_run(fleet: Array = []) -> void:
	GameState.locale = "en"
	GameState.day = 12
	GameState.gold = 3000
	GameState.current_port = null
	GameState.world = {"position": {"x": 30, "y": 40}, "clock_fraction": 0.0,
		"weather": "calm"}
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 12,
			"navigation": 10, "luck": 10},
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
	_screen = screen
	await get_tree().process_frame
	return screen


func _free_screen(screen) -> void:
	if screen != null and is_instance_valid(screen):
		screen.queue_free()
	_screen = null
	await get_tree().process_frame


## Builds a battle for one AI fixture: `player_ships` and the single enemy hull,
## then puts the two ships on the fixture tiles (the §4.11.2 deployment opens
## every battle 13 tiles apart, so close-quarters fixtures are placed by hand —
## the same convention `tools/test_battle.gd` uses).
func _ai_fixture(player_ships: Array, enemy_ships: Array,
		enemy_cell: Vector2i, player_cell: Vector2i, hull_id: String,
		player_extra_cell = null):
	_make_run(player_ships)
	var screen = await _new_screen()
	screen.route_to_world = false
	screen.open_battle({
		"id": "hf_ai_30_40_pirate", "kind": "pirate", "nation_id": "",
		"position": {"x": 30, "y": 40}, "day": 9,
		"ships": enemy_ships,
	})
	await get_tree().process_frame
	_place(screen.sim, "enemy", 0, enemy_cell)
	_place(screen.sim, "player", 0, player_cell)
	if player_extra_cell != null and player_ships.size() > 1:
		_place(screen.sim, "player", 1, player_extra_cell)
	screen._bind()
	return screen


## Ends turns until the enemy flagship acts, then runs the screen's own AI turn
## and returns the applied decision (§4.9). Player slots are simply passed.
func _enemy_turn(screen) -> Dictionary:
	for _guard in 24:
		var current: Dictionary = screen.sim.current_unit()
		if current.is_empty():
			return {}
		if str(current.get("side", "")) == "enemy" and int(current.get("index", -1)) == 0:
			return screen.run_ai_turn()
		screen.sim.end_turn()
	return {}


func _place(sim, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit_dict(sim, side, index)
	if not unit.is_empty():
		unit["cell"] = cell


func _unit_dict(sim, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


func _unit(screen, side: String, index: int) -> Dictionary:
	return _unit_dict(screen.sim, side, index)


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


## The reachable cell that closes the distance to the nearest enemy.
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


## A grid cell the acting ship cannot reach (top-right corner is 13+ tiles from
## the §4.11.2 player band and always outside one ship's MP).
func _unreachable_cell(screen, _from: Vector2i) -> Vector2i:
	var legal: Array = screen.highlighted_cells()
	for y in BattleLib.GRID_HEIGHT:
		for x in BattleLib.GRID_WIDTH:
			var cell := Vector2i(x, y)
			if not legal.has(cell):
				return cell
	return BattleLib.NO_CELL


func _token_for(screen, unit: Dictionary):
	var key := "%s:%d" % [str(unit.get("side", "")), int(unit.get("index", -1))]
	return screen._token_widgets.get(key, null)


## The cell a token widget currently sits on, derived from its 24×24 square
## centred in its 48px tile (§4.7.1, §4.8).
func _token_cell(screen, token: Dictionary) -> Vector2i:
	var root: Control = token["root"]
	var offset := (TILE_PX - 24.0) * 0.5
	return Vector2i(
		int(round((root.position.x - offset) / TILE_PX)),
		int(round((root.position.y - offset) / TILE_PX)))


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
