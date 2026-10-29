extends Node
## T6 acceptance tests (docs/IMPLEMENT-Phase1.md T6; docs/20-* §4.1–§4.3,
## §4.11–§4.12; docs/80-* §4.3, §4.5, §4.7). Headless scene test:
##
##   godot --headless res://tools/test_movement.tscn
##
## Exits 0 when every check passes, 1 otherwise. Kept as a proper
## `tools/test_*.gd` + `.tscn` pair so the T6 done-when list can be re-run.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const DialogScene := preload("res://scenes/ui_shared/dialog_box.tscn")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")

## Open-water cell whose 8 neighbours (and both orthogonals of each diagonal)
## are all passable, so every one of the 8 directions is legal from here.
const OPEN_CELL := Vector2i(20, 20)
## Lisbon marker (7,57); (8,57) is coastal sea, (9,57) is land '#'.
const LISBON := Vector2i(7, 57)
const SEA_BESIDE_LISBON := Vector2i(8, 57)
const LAND_BESIDE_LISBON := Vector2i(9, 57)
## Real corner cut on the shipped map: (8,1) → (7,0) is diagonal and
## (8,0) is impassable, so only the (7,1) orthogonal exists.
const CORNER_FROM := Vector2i(8, 1)
const CORNER_TO := Vector2i(7, 0)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_map_loads()
	_test_effective_speed()
	_test_diagonal_rule()
	_test_eight_direction_stepping()
	_test_land_and_edge_block()
	_test_corner_cut_zero_clock()
	_test_clock_and_day_boundary()
	_test_port_entry()
	_test_no_game_and_modal_block()
	_test_camera_clamp()
	_test_hud_signal_only()
	_test_dialog_queue_order()
	_test_dialogs()
	_report()


# --- Fixtures --------------------------------------------------------------

## Minimal run: caravel (speed 5, crew_min 15) at full crew, base stats, fair
## weather → effective speed exactly 5 (§4.4 worked case).
func _make_run(weather: String = "fair", ship_ids: Array = ["caravel"]) -> void:
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
	GameState.fleet = []
	for ship_id in ship_ids:
		var ship_type: Dictionary = DataLoader.get_ship_type(str(ship_id))
		var ship: Dictionary = FleetLib.new_ship(str(ship_id), int(ship_type["crew_min"]))
		# T9's ledger consumes supplies and checks fail states, so the movement
		# fixture has to be a survivable run: ample stores and a healthy morale.
		ship["provisions"] = 100
		ship["water"] = 100
		GameState.fleet.append(ship)
	GameState.day = 1
	GameState.gold = 1000
	GameState.morale = 70
	GameState.current_port = null
	GameState.known_ports = []
	GameState.explored_tiles = {}
	GameState.world = {
		"position": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
		"clock_fraction": 0.0,
		"weather": weather,
	}
	# Clear T9's transient ledger statics so one scenario cannot leak into the
	# next (counters, game-over flag, dialog buffer).
	SailingSimLib.reset_ledger_state()


## Dismisses every queued HUD dialog on `world` (T9 raises weather-damage /
## mutiny / desertion modals from a day tick, and a modal correctly freezes
## movement — these tests are about movement, so they close them first).
## Also closes any modal left over from an earlier test: `queue_free()` is
## deferred, so a previous host's dialog can still be visible in this frame.
func _clear_dialogs(world = null) -> void:
	# Dismiss repeatedly: closing one modal can immediately show the next one
	# from the §4.7 queue (and free() is deferred inside a single `_ready`), so
	# a single pass over the group can miss the successor.
	for pass_index in 64:
		var visible := []
		for node in get_tree().get_nodes_in_group("modal_overlay"):
			if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
				visible.append(node)
		if visible.is_empty():
			break
		for node in visible:
			# `confirm_dialog` (the §4.8.3 mutiny modal) has cancel() instead of
			# close(); both unregister the modal and advance the queue.
			if node.has_method("close"):
				node.close()
			elif node.has_method("cancel"):
				node.cancel()
	if world != null:
		var hud = world.get_node_or_null("HUDLayer/HUD")
		if hud != null and hud.has_method("has_modal"):
			var guard := 0
			while hud.has_modal() and guard < 32:
				guard += 1
				var dialog = hud.current_dialog()
				if dialog == null:
					break
				if dialog.has_method("close"):
					dialog.close()
				else:
					dialog.cancel()


func _test_map_loads() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/p1_mediterranean.txt", DataLoader.map_legend
	)
	_check(ok, "map loads for the movement tests (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	if ok:
		_check(map.width == 128 and map.height == 96,
			"grid is 128×96 (got %d×%d)" % [map.width, map.height])
		_check(map.is_passable(OPEN_CELL), "fixture cell (20,20) is sea")
		_check(map.is_passable(SEA_BESIDE_LISBON),
			"(8,57) beside Lisbon is passable sea")
		_check(not map.is_passable(LAND_BESIDE_LISBON),
			"(9,57) beside Lisbon is land and blocks")
		_check(not map.is_passable(Vector2i(-1, 0)),
			"map edge is impassable (§6)")
		_check(map.is_passable(LISBON), "port marker tiles are passable")


# --- §4.4 effective speed --------------------------------------------------

func _test_effective_speed() -> void:
	_make_run("fair", ["caravel"])
	_check(SailingSimLib.effective_speed() == 5,
		"fair, full crew, seamanship 10: 5 (got %d)"
		% SailingSimLib.effective_speed())
	_check(is_equal_approx(SailingSimLib.move_cost(), 0.2),
		"move_cost = 1/5 = 0.2 days (got %.4f)" % SailingSimLib.move_cost())

	_make_run("calm", ["caravel"])
	_check(SailingSimLib.effective_speed() == 4,
		"calm sail: floor(5 × 0.8) = 4 (got %d)"
		% SailingSimLib.effective_speed())

	_make_run("storm", ["caravel"])
	_check(SailingSimLib.effective_speed() == 7,
		"storm sail: floor(5 × 1.5) = 7 (got %d)"
		% SailingSimLib.effective_speed())

	# Skeleton crew: 1 of crew_min 15 → factor 0.25 → floor(1.25) = 1, never 0.
	_make_run("fair", ["caravel"])
	GameState.fleet[0]["crew"] = 1
	_check(is_equal_approx(SailingSimLib.crew_factor(), 0.25),
		"crew 1/15 → factor 0.25 (got %.4f)" % SailingSimLib.crew_factor())
	_check(SailingSimLib.effective_speed() == 1,
		"skeleton crew floors to 1, never 0 (got %d)"
		% SailingSimLib.effective_speed())

	# Slowest-hull rule (§4.4 composition): caravel 5 + nao 4 → base 4.
	_make_run("fair", ["caravel", "nao"])
	_check(FleetLib.slowest_speed() == 4,
		"fleet slowest hull speed is the nao's 4 (got %d)"
		% FleetLib.slowest_speed())
	_check(SailingSimLib.effective_speed() == 4,
		"fleet speed uses the slowest hull: 4 (got %d)"
		% SailingSimLib.effective_speed())

	# Seamanship bonus: 20 → +0.10 → floor(5.5) = 5.
	_make_run("fair", ["caravel"])
	GameState.player["stats"]["seamanship"] = 20
	_check(is_equal_approx(SailingSimLib.move_cost(), 0.2),
		"seamanship 20 gives speed 5 (got %d)" % SailingSimLib.effective_speed())
	# 25 → +0.15 → floor(5 × 1.15) = 5.
	GameState.player["stats"]["seamanship"] = 25
	_check(SailingSimLib.effective_speed() == 5,
		"seamanship 25 → floor(5 × 1.15) = 5 (got %d)"
		% SailingSimLib.effective_speed())
	# 30 → clamped +0.20 → floor(6.0) = 6.
	GameState.player["stats"]["seamanship"] = 30
	_check(SailingSimLib.effective_speed() == 6,
		"seamanship 30 → floor(5 × 1.2) = 6 (got %d)"
		% SailingSimLib.effective_speed())


# --- §4.2 no corner cutting -----------------------------------------------

func _test_diagonal_rule() -> void:
	var map = DataLoader.map
	_check(SailingSimLib.is_move_legal(OPEN_CELL, OPEN_CELL + Vector2i(1, 1), map),
		"open-water diagonal is legal")
	_check(not SailingSimLib.is_move_legal(CORNER_FROM, CORNER_TO, map),
		"real corner cut (8,1)→(7,0) is rejected")
	_check(SailingSimLib.is_move_legal(
		CORNER_FROM, CORNER_FROM + Vector2i(-1, -1), map) == false,
		"the same corner is rejected for the other orthogonal too")
	_check(SailingSimLib.is_move_legal(
		CORNER_FROM, CORNER_FROM + Vector2i(-1, 0), map)
		and not SailingSimLib.is_move_legal(
			CORNER_FROM, CORNER_FROM + Vector2i(0, -1), map),
		"the straight alternatives behave per the map (7,1) sea, (8,0) land")
	_check(not SailingSimLib.is_move_legal(OPEN_CELL, OPEN_CELL + Vector2i(2, 0), map),
		"a two-tile jump is not a move")
	_check(not SailingSimLib.is_move_legal(OPEN_CELL, OPEN_CELL, map),
		"standing still is not a move")

	# Soak: BFS the whole map through the movement rule alone. It must reach
	# exactly the validator's single sea component (4109 passable tiles,
	# tools/validate_data.py group 6) from Lisbon — proof the in-game rule is
	# the same "no corner cutting" rule the data validator enforces.
	var reached := {LISBON: true}
	var queue: Array[Vector2i] = [LISBON]
	var head := 0
	while head < queue.size():
		var here: Vector2i = queue[head]
		head += 1
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var next := here + Vector2i(dx, dy)
				if reached.has(next):
					continue
				if not SailingSimLib.is_move_legal(here, next, map):
					continue
				reached[next] = true
				queue.append(next)
	_check(reached.size() == 4109,
		"BFS through movement rules reaches all 4109 sea tiles from Lisbon (got %d)"
		% reached.size())
	for cell in reached:
		if not map.is_passable(cell):
			_check(false, "BFS reached an impassable cell %s" % str(cell))
			break


# --- §4.2 8-directional stepping -----------------------------------------

func _test_eight_direction_stepping() -> void:
	_make_run("fair")
	var host := Node2D.new()
	host.name = "WorldHost"
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)
	_check(world.fleet_cell() == OPEN_CELL,
		"world scene starts on GameState's tile (got %s)" % str(world.fleet_cell()))

	var steps := {
		"move_nw": Vector2i(-1, -1), "move_n": Vector2i(0, -1),
		"move_ne": Vector2i(1, -1), "move_w": Vector2i(-1, 0),
		"move_e": Vector2i(1, 0), "move_sw": Vector2i(-1, 1),
		"move_s": Vector2i(0, 1), "move_se": Vector2i(1, 1),
	}
	for action in steps:
		_clear_dialogs(world)
		var delta: Vector2i = steps[action]
		var before: Vector2i = world.fleet_cell()
		var event := InputEventAction.new()
		event.action = action
		event.pressed = true
		world._unhandled_input(event)
		var after: Vector2i = world.fleet_cell()
		_check(after == before + delta and GameState.world_tile() == after,
			"%s steps %s (got %s, state %s)" % [
				action, str(delta), str(after - before), str(GameState.world_tile())
			])
		# Step back so every direction starts from the open fixture cell.
		_clear_dialogs(world)
		var back: Vector2i = before
		_check(world.try_step(back), "%s: return step succeeds" % action)

	# Click-to-step mapping: the tile under the cursor is `floor(px / 32)`.
	_check(world._cell_at(Vector2(OPEN_CELL) * 32.0 + Vector2(16, 16)) == OPEN_CELL,
		"click maps pixel → the tile under the cursor")
	_check(world._cell_at(Vector2(OPEN_CELL + Vector2i(1, 0)) * 32.0 + Vector2(4, 4))
		== OPEN_CELL + Vector2i(1, 0), "click on an adjacent tile maps to it")
	_clear_dialogs(world)
	_check(world.try_step(OPEN_CELL + Vector2i(1, 0)),
		"click-to-step path (try_step) moves east")
	_check(not world.try_step(OPEN_CELL + Vector2i(5, 5)),
		"click on a non-adjacent tile is a no-op")

	host.queue_free()


# --- §4.2 land / reef block ----------------------------------------------

func _test_land_and_edge_block() -> void:
	var map = DataLoader.map
	_make_run("fair")
	GameState.world["position"] = {
		"x": SEA_BESIDE_LISBON.x, "y": SEA_BESIDE_LISBON.y,
	}
	GameState.world["clock_fraction"] = 0.125
	var before_cell := GameState.world_tile()
	var before_clock := float(GameState.world["clock_fraction"])

	_check(not SailingSimLib.try_move(LAND_BESIDE_LISBON, map),
		"stepping into land '#' is rejected")
	_check(GameState.world_tile() == before_cell,
		"land move leaves the position unchanged (%s)" % str(GameState.world_tile()))
	_check(float(GameState.world["clock_fraction"]) == before_clock,
		"land move costs no clock (%.6f)" % float(GameState.world["clock_fraction"]))

	# Out of bounds (map edge, §6).
	var edge := Vector2i(0, 0)
	GameState.world["position"] = {"x": edge.x, "y": edge.y}
	_check(not SailingSimLib.try_move(Vector2i(-1, 0), map),
		"moving off the west edge is rejected")
	_check(GameState.world_tile() == edge, "edge rejection keeps the position")

	# Reef: the shipped Phase-1 map has no '^' tiles, so the rule is proven on
	# a synthetic legend-conformant map with the same loader (data-driven).
	var reef_map = MapLoaderLib.parse(
		"~~~~\n~^~~\n~~~~",
		{
			"grid": {"width": 4, "height": 3},
			"tile_size_px": 32,
			"tiles": {
				"~": {"kind": "sea", "passable": true},
				"^": {"kind": "reef", "passable": false},
			},
			"port_markers": {},
		}
	)
	_check(reef_map != null, "synthetic reef map parses")
	if reef_map != null:
		_check(not reef_map.is_passable(Vector2i(1, 1)), "reef '^' is impassable")
		_check(not SailingSimLib.is_move_legal(Vector2i(1, 0), Vector2i(1, 1), reef_map),
			"stepping onto a reef is rejected")
		_check(not SailingSimLib.is_move_legal(Vector2i(0, 1), Vector2i(1, 1), reef_map),
			"reef blocks the orthogonal step too")


# --- §4.2/§6 corner cut costs nothing ------------------------------------

func _test_corner_cut_zero_clock() -> void:
	var map = DataLoader.map
	_make_run("fair")
	GameState.world["position"] = {"x": CORNER_FROM.x, "y": CORNER_FROM.y}
	GameState.world["clock_fraction"] = 0.7777777777
	var before_clock := float(GameState.world["clock_fraction"])
	var before_day := GameState.day
	var ticks := [0]
	var counter := func(_day: int) -> void: ticks[0] += 1
	EventBus.day_advanced.connect(counter)

	var moved: bool = SailingSimLib.try_move(CORNER_TO, map)
	EventBus.day_advanced.disconnect(counter)

	_check(not moved, "corner-cut move returns false")
	_check(GameState.world_tile() == CORNER_FROM,
		"corner cut leaves the position at %s (got %s)"
		% [str(CORNER_FROM), str(GameState.world_tile())])
	# Bit-identical: no float arithmetic happens on the accumulator at all.
	_check(float(GameState.world["clock_fraction"]) == before_clock,
		"corner cut leaves clock_fraction bit-identical (%.10f)"
		% float(GameState.world["clock_fraction"]))
	_check(GameState.day == before_day, "corner cut advances no day")
	_check(ticks[0] == 0, "corner cut emits no day_advanced")


# --- §4.3 clock & day boundary ------------------------------------------

func _test_clock_and_day_boundary() -> void:
	_make_run("fair")  # effective speed 5 → 0.2 days per tile
	GameState.world["position"] = {"x": OPEN_CELL.x, "y": OPEN_CELL.y}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1

	var ticks: Array = []
	var counter := func(day: int) -> void: ticks.append(day)
	EventBus.day_advanced.connect(counter)

	# 5 moves × 0.2 = exactly one day, emitted once, with the new day number.
	# Alternating east/west keeps every step legal on real sea.
	for step in 5:
		var target := Vector2i(
			OPEN_CELL.x + (1 if step % 2 == 0 else 0),
			OPEN_CELL.y
		)
		_check(SailingSimLib.try_move(target, DataLoader.map),
			"clock test: move %d succeeds" % (step + 1))
	_check(ticks.size() == 1,
		"5 moves at speed 5 emit day_advanced exactly once (got %d)" % ticks.size())
	_check(ticks == [2], "day_advanced reports day 2 (got %s)" % str(ticks))
	_check(GameState.day == 2, "GameState.day == 2 (got %d)" % GameState.day)
	var fraction := float(GameState.world["clock_fraction"])
	_check(fraction >= 0.0 and fraction < 1.0,
		"clock_fraction stays in [0,1) (%.12f)" % fraction)
	_check(absf(fraction) < 1.0e-6, "fraction resets to ~0 after the tick (%.12f)" % fraction)

	# Direct accumulator cases, including thirds that do not add to 1 exactly.
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 10
	ticks.clear()
	_check(SailingSimLib.advance_clock(1.0 / 3.0) == 0, "one third of a day: no tick")
	_check(SailingSimLib.advance_clock(1.0 / 3.0) == 0, "two thirds: no tick")
	_check(SailingSimLib.advance_clock(1.0 / 3.0) == 1,
		"three thirds tick exactly one day (float tolerance)")
	_check(GameState.day == 11, "day is 11 after the third third (got %d)" % GameState.day)

	# Multi-day batch (a very fast fleet): the while loop ticks once per day.
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 20
	ticks.clear()
	var ticked: int = SailingSimLib.advance_clock(3.5)
	_check(ticked == 3, "3.5 days ticks 3 times (got %d)" % ticked)
	_check(ticks == [21, 22, 23], "day_advanced fired for 21, 22, 23 (got %s)" % str(ticks))
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), 0.5),
		"half a day remains (%.6f)" % float(GameState.world["clock_fraction"]))
	EventBus.day_advanced.disconnect(counter)


# --- §4.11 port entry ---------------------------------------------------

func _test_port_entry() -> void:
	_make_run("fair")
	GameState.world["position"] = {
		"x": SEA_BESIDE_LISBON.x, "y": SEA_BESIDE_LISBON.y,
	}
	GameState.known_ports = []
	GameState.current_port = null

	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)

	# The scene's ready-time sighting already knows Lisbon (it is 1 tile away);
	# forget it again to exercise the "unknown port discovered by entering"
	# branch of §4.11.
	GameState.known_ports = []
	var entered: Array = []
	var listener := func(port_id: String) -> void: entered.append(port_id)
	EventBus.port_entered.connect(listener)

	var ahead := float(GameState.world["clock_fraction"])
	_check(not GameState.known_ports.has("lisbon"), "lisbon starts unknown in this fixture")
	_clear_dialogs(world)
	_check(world.try_step(LISBON), "moving onto Lisbon's harbor tile succeeds")
	EventBus.port_entered.disconnect(listener)

	_check(entered == ["lisbon"], "port_entered('lisbon') emitted (got %s)" % str(entered))
	# Clock cost of the harbor tile applies normally (§4.2).
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), ahead + 0.2),
		"harbor tile still costs its 1/speed day (%.4f)"
		% float(GameState.world["clock_fraction"]))
	_check(GameState.known_ports.has("lisbon"),
		"entering an unknown port discovers it (§4.11)")
	_check(GameState.current_port == "lisbon",
		"current_port set to lisbon (got %s)" % str(GameState.current_port))
	_clear_dialogs(world)
	host.queue_free()

	# Sighting: a nearby port is known without entering it; far ones are not.
	_make_run("fair")
	GameState.world["position"] = {"x": OPEN_CELL.x, "y": OPEN_CELL.y}
	var host2 := Node2D.new()
	add_child(host2)
	var world2 = WorldScene.instantiate()
	host2.add_child(world2)
	_check(GameState.known_ports.has("lisbon") == false,
		"sighting at open sea does not know far-away capitals")
	_check(GameState.explored_tiles.has(OPEN_CELL),
		"scene ready marks the fleet tile explored")
	# Moving near a port reveals it (sighting radius, §4.11).
	GameState.explored_tiles = {}
	GameState.world["position"] = {"x": SEA_BESIDE_LISBON.x, "y": SEA_BESIDE_LISBON.y}
	world2.sync_from_state()
	_check(GameState.known_ports.has("lisbon"),
		"moving within the sighting radius discovers Lisbon without docking")
	_check(GameState.explored_tiles.has(SEA_BESIDE_LISBON),
		"explored_tiles follows the fleet")
	# Explored set == the clipped sighting square (§4.12), nothing more.
	var radius: int = CharacterLib.sighting_radius()
	var expected := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var cell := Vector2i(SEA_BESIDE_LISBON.x + dx, SEA_BESIDE_LISBON.y + dy)
			if cell.x >= 0 and cell.y >= 0 and cell.x < 128 and cell.y < 96:
				expected += 1
	_check(GameState.explored_tiles.size() == expected,
		"explored tiles = the sighting square (%d, got %d)"
		% [expected, GameState.explored_tiles.size()])
	_check(not GameState.explored_tiles.has(
		SEA_BESIDE_LISBON + Vector2i(radius + 1, 0)),
		"tiles outside the sighting radius stay unexplored")

	# Fleet marker: 24×24 white square with a black outline (docs/80-* §4.8).
	var square: Control = world2.get_node("FleetMarker/Square")
	_check(square.size == Vector2(24, 24),
		"fleet marker is 24×24 (got %s)" % str(square.size))
	_check(is_equal_approx(square.position.x, -12.0) and
		is_equal_approx(square.position.y, -12.0),
		"marker square is centered on its tile (%s)" % str(square.position))
	var style = square.get_theme_stylebox("panel")
	_check(style is StyleBoxFlat, "marker square uses a StyleBoxFlat")
	if style is StyleBoxFlat:
		_check((style as StyleBoxFlat).bg_color == Color.WHITE,
			"marker fill is white")
		_check((style as StyleBoxFlat).border_color == Color.BLACK,
			"marker outline is black")
		_check((style as StyleBoxFlat).border_width_left == 2,
			"marker outline is 2px")
	host2.queue_free()


# --- T6-D no-game fallback + modal input block ---------------------------

func _test_no_game_and_modal_block() -> void:
	# A fresh world scene with no run: falls back to Lisbon, HUD shows "-".
	GameState.player = {}
	GameState.fleet = []
	GameState.world = {}
	GameState.day = 0
	GameState.gold = 0
	GameState.known_ports = []
	GameState.explored_tiles = {}

	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)
	_check(world.fleet_cell() == LISBON,
		"no game: fleet starts on Lisbon's fallback tile (got %s)"
		% str(world.fleet_cell()))
	_check(GameState.world.has("clock_fraction") and GameState.world.has("weather"),
		"no game: world state defaults are created (no crash)")
	var hud = world.get_node_or_null("HUDLayer/HUD")
	_check(hud != null, "world scene instantiates the HUD (docs/90-* §7)")
	if hud != null:
		_check((hud.get_node("TopRow/Gold") as Label).text
			== I18n.fmt("ui.gold_amount", {"gold": "0"}),
			"no game: gold bar still renders a number")
		_check((hud.get_node("TopRow/Morale") as Label).text
			== I18n.fmt("world.morale", {"amount": "-"}),
			"HUD renders '-' for missing values (got %s)"
			% (hud.get_node("TopRow/Morale") as Label).text)
		_check((hud.get_node("BottomRow/Crew") as Label).text
			== I18n.fmt("world.crew", {"crew": "-", "max": "-"}),
			"no game: crew bar renders '-'")

	# A move with no run still steps (inspection) but cannot touch a clock.
	_clear_dialogs(world)
	var before: Vector2i = world.fleet_cell()
	_check(world.try_step(before + Vector2i(1, 0))
		or world.try_step(before + Vector2i(0, 1)),
		"no game: legal steps still work for inspection")
	host.queue_free()

	# Modal block: with a dialog open, movement input does nothing (§11).
	_make_run("fair")
	var host2 := Node2D.new()
	add_child(host2)
	var world2 = WorldScene.instantiate()
	host2.add_child(world2)
	var hud2 = world2.get_node("HUDLayer/HUD")
	hud2.show_dialog("ui.cant_save_here")
	_check(hud2.has_modal(), "a HUD dialog makes has_modal() true")
	var before_cell: Vector2i = world2.fleet_cell()
	var before_clock := float(GameState.world["clock_fraction"])
	var event := InputEventAction.new()
	event.action = "move_e"
	event.pressed = true
	world2._unhandled_input(event)
	_check(world2.fleet_cell() == before_cell,
		"movement input is ignored while a modal is open")
	_check(float(GameState.world["clock_fraction"]) == before_clock,
		"modal-blocked input costs no clock")
	hud2.current_dialog().close()
	# `closed` drains the queue synchronously: no dialog, nothing queued.
	_check(not hud2.has_modal(),
		"closing the only dialog clears has_modal() in the same frame")
	var after_cell := Vector2i(before_cell.x + 1, before_cell.y)
	_clear_dialogs(world2)
	_check(world2.try_step(after_cell), "movement works again after the dialog")
	host2.queue_free()



func _test_camera_clamp() -> void:
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)

	var bounds := Rect2(Vector2.ZERO, world.map_pixels())
	var corners := [
		Vector2i(0, 0), Vector2i(127, 0), Vector2i(0, 95), Vector2i(127, 95),
	]
	for corner in corners:
		GameState.world["position"] = {"x": corner.x, "y": corner.y}
		world.sync_from_state()
		var visible: Rect2 = world.visible_world_rect()
		var inside: bool = bounds.encloses(visible) \
			or (visible.position.x >= bounds.position.x - 0.001
				and visible.position.y >= bounds.position.y - 0.001
				and visible.end.x <= bounds.end.x + 0.001
				and visible.end.y <= bounds.end.y + 0.001)
		_check(inside, "camera at corner %s shows no void (visible %s, map %s)" % [
			str(corner), str(visible), str(bounds)
		])

	# Mid-map: the camera centers on the fleet tile while staying clamped.
	GameState.world["position"] = {"x": 64, "y": 48}
	world.sync_from_state()
	var center: Vector2 = world.get_node("Camera2D").position
	_check(is_equal_approx(center.x, 64.0 * 32.0 + 16.0)
		and is_equal_approx(center.y, 48.0 * 32.0 + 16.0),
		"camera centers on the fleet tile mid-map (%s)" % str(center))
	_check(is_equal_approx(world.get_node("Camera2D").zoom.x, 1.0),
		"camera zoom locked at 1.0")
	host.queue_free()


# --- §4.5 / §7 HUD updates from signals only ---------------------------

func _test_hud_signal_only() -> void:
	GameState.new_game("portugal", false)
	GameState.gold = 5000
	GameState.day = 3

	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)

	var gold_label: Label = hud.get_node("TopRow/Gold")
	var day_label: Label = hud.get_node("TopRow/Day")
	_check(gold_label.text == I18n.fmt("ui.gold_amount", {"gold": "5,000"}),
		"gold bar renders the live value (%s)" % gold_label.text)
	_check(day_label.text == I18n.fmt("world.day", {"day": 3}),
		"day bar renders the live value (%s)" % day_label.text)

	# Gold: change + emit → updates.
	GameState.gold = 7830
	EventBus.gold_changed.emit(GameState.gold)
	_check(gold_label.text == I18n.fmt("ui.gold_amount", {"gold": "7,830"}),
		"HUD follows gold_changed (%s)" % gold_label.text)
	# Gold: change WITHOUT emitting → must not update (proves no polling).
	GameState.gold = 9999
	_check(gold_label.text == I18n.fmt("ui.gold_amount", {"gold": "7,830"}),
		"HUD does not poll GameState.gold (%s)" % gold_label.text)

	# Day: same pair of checks.
	GameState.day = 4
	EventBus.day_advanced.emit(GameState.day)
	_check(day_label.text == I18n.fmt("world.day", {"day": 4}),
		"HUD follows day_advanced (%s)" % day_label.text)
	GameState.day = 12
	_check(day_label.text == I18n.fmt("world.day", {"day": 4}),
		"HUD does not poll GameState.day (%s)" % day_label.text)

	# Morale tier color + label (docs/20-* §4.8 thresholds).
	GameState.morale = 35
	EventBus.fleet_changed.emit()
	var morale_label: Label = hud.get_node("TopRow/Morale")
	_check(morale_label.text == "%s (%s)" % [
		I18n.fmt("world.morale", {"amount": 35}),
		I18n.t_key("world.morale.dangerous"),
	], "morale 35 reads Dangerous (%s)" % morale_label.text)
	_check(morale_label.get_theme_color("font_color") == PaletteLib.WARN,
		"morale 35 is tier-colored WARN")
	GameState.morale = 10
	EventBus.fleet_changed.emit()
	_check(morale_label.get_theme_color("font_color") == PaletteLib.BAD,
		"morale 10 is tier-colored BAD")
	GameState.morale = 70
	EventBus.fleet_changed.emit()
	_check(morale_label.get_theme_color("font_color") == PaletteLib.GOOD,
		"morale 70 is tier-colored GOOD")

	# Area label: nearest known port within 16 tiles, else world.open_sea.
	GameState.known_ports = ["lisbon"]
	GameState.current_port = null
	hud.set_fleet_cell(Vector2i(64, 48))
	var area: Label = hud.get_node("TopRow/Area")
	_check(area.text == I18n.t_key("world.open_sea"),
		"area label is open sea when no known port is within 16 tiles (%s)"
		% area.text)
	hud.set_fleet_cell(Vector2i(8, 57))
	_check(area.text == I18n.t(DataLoader.get_port("lisbon")["name"]),
		"area label names the nearest known port inside 16 tiles (%s)" % area.text)
	GameState.known_ports = []
	hud.set_fleet_cell(Vector2i(8, 57))
	_check(area.text == I18n.t_key("world.open_sea"),
		"an unknown port does not name the area (%s)" % area.text)
	GameState.current_port = "lisbon"
	hud.set_fleet_cell(Vector2i(64, 48))
	_check(area.text == I18n.t(DataLoader.get_port("lisbon")["name"]),
		"while docked the area label shows the port (%s)" % area.text)
	GameState.current_port = null

	# Locale rebind.
	GameState.day = 4
	EventBus.day_advanced.emit(GameState.day)
	I18n.set_locale("zh")
	_check(day_label.text == I18n.fmt("world.day", {"day": 4}),
		"HUD rebinds on locale_changed (%s)" % day_label.text)
	I18n.set_locale("en")

	# Weather label under the minimap (docs/80-* §4.5), driven by day_advanced.
	var weather_label: Label = hud.get_node("Weather")
	GameState.world["weather"] = "storm"
	EventBus.day_advanced.emit(GameState.day)
	_check(weather_label.text == I18n.t_key("world.weather.storm"),
		"weather label follows the storm roll (%s)" % weather_label.text)
	_check(weather_label.get_theme_color("font_color") == PaletteLib.BAD,
		"storm weather glyph is warning-colored")
	_check(weather_label.modulate.a <= 1.0 and hud._weather_tween != null,
		"storm glyph starts its 0.5s flash tween")
	GameState.world["weather"] = "fair"
	EventBus.day_advanced.emit(GameState.day)
	_check(weather_label.text == I18n.t_key("world.weather.fair"),
		"weather label returns to fair (%s)" % weather_label.text)
	_check(hud._weather_tween == null and is_equal_approx(weather_label.modulate.a, 1.0),
		"leaving storm stops the flash and restores alpha")

	# Minimap toggle (M): 256×192 → 512×384 centered.
	var minimap: Control = hud.get_node("Minimap")
	_check(minimap.size == Vector2(256, 192),
		"minimap default 256×192 (got %s)" % str(minimap.size))
	hud.toggle_minimap()
	_check(minimap.size == Vector2(512, 384),
		"minimap enlarged 512×384 (got %s)" % str(minimap.size))
	_check(is_equal_approx(minimap.position.x, (1280.0 - 512.0) * 0.5)
		and is_equal_approx(minimap.position.y, (720.0 - 384.0) * 0.5),
		"enlarged minimap is centered (got %s)" % str(minimap.position))
	hud.toggle_minimap()
	_check(minimap.size == Vector2(256, 192), "minimap toggles back to 256×192")

	# The HUD source contains no `_process` (behavioural proof above, textual
	# proof here so a future edit cannot quietly reintroduce polling).
	var source := FileAccess.get_file_as_string("res://scenes/ui_shared/hud.gd")
	_check(not source.contains("func _process"),
		"hud.gd defines no _process (no polling)")

	host.queue_free()


# --- §4.7 dialog queue --------------------------------------------------

func _test_dialog_queue_order() -> void:
	GameState.new_game("portugal", false)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)

	var finished := [0]
	var on_finished := func() -> void: finished[0] += 1
	hud.dialogs_finished.connect(on_finished)

	hud.show_dialogs([
		{"key": "world.storm_notice", "values": {"weather": "storm"}},
		{"key": "ui.cant_save_here"},
		{"key": "ui.saved"},
	])

	var first = hud.current_dialog()
	_check(first != null, "queue shows the first dialog immediately")
	_check(first.message_text() == I18n.fmt("world.storm_notice", {"weather": "storm"}),
		"first dialog is storm_notice (%s)" % first.message_text())
	var visible_dialogs := 0
	for child in hud.get_node("ModalHost").get_children():
		if child.is_open():
			visible_dialogs += 1
	_check(visible_dialogs == 1, "exactly one modal on screen (got %d)" % visible_dialogs)

	first.close()
	var second = hud.current_dialog()
	_check(second != null and second != first,
		"second dialog appears once the first is dismissed")
	_check(second.message_text() == I18n.t_key("ui.cant_save_here"),
		"second dialog is ui.cant_save_here (%s)" % second.message_text())
	_check(finished[0] == 0, "dialogs_finished does not fire early")

	second.close()
	var third = hud.current_dialog()
	_check(third.message_text() == I18n.t_key("ui.saved"),
		"third dialog is ui.saved (%s)" % third.message_text())
	third.close()
	_check(hud.current_dialog() == null, "queue drains to no dialog")
	_check(finished[0] == 1, "dialogs_finished fires once after the last dialog")
	_check(not hud.has_modal(), "has_modal() is false when the queue is empty")

	hud.dialogs_finished.disconnect(on_finished)
	host.queue_free()


# --- Dialog chrome ------------------------------------------------------

func _test_dialogs() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)

	var box = DialogScene.instantiate()
	host.add_child(box)
	box.open_key("world.desertion", {"count": 3})
	_check(box.is_open(), "dialog_box opens")
	_check(box.message_text() == I18n.fmt("world.desertion", {"count": 3}),
		"dialog_box formats placeholders (%s)" % box.message_text())
	_check((box.get_node("Center/Panel") as Control).custom_minimum_size.x == 480.0,
		"dialog width is 480px (docs/80-* §4.8)")
	var dim: ColorRect = box.get_node("Dim")
	_check(is_equal_approx(dim.color.a, 0.4), "dialog dims the background 40%")
	var closed := [0]
	box.closed.connect(func() -> void: closed[0] += 1)
	I18n.set_locale("zh")
	_check(box.message_text() == I18n.fmt("world.desertion", {"count": 3}),
		"dialog_box rebinds on locale_changed (%s)" % box.message_text())
	I18n.set_locale("en")
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	box._unhandled_input(esc)
	_check(not box.is_open() and closed[0] == 1, "Esc closes dialog_box once")
	box.queue_free()

	var confirm = ConfirmScene.instantiate()
	host.add_child(confirm)
	confirm.open_key("ui.overwrite_confirm", {"slot": 2})
	_check(confirm.is_open(), "confirm_dialog opens")
	var result := [-1]
	confirm.closed.connect(func(accepted: bool) -> void: result[0] = 1 if accepted else 0)
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.physical_keycode = KEY_ENTER
	confirm._unhandled_input(enter)
	_check(not confirm.is_open() and result[0] == 1, "Enter confirms")

	confirm.open_key("ui.overwrite_confirm", {"slot": 2})
	var n_key := InputEventKey.new()
	n_key.pressed = true
	n_key.physical_keycode = KEY_N
	confirm._unhandled_input(n_key)
	_check(not confirm.is_open() and result[0] == 0, "N cancels")
	check_y_cancels(confirm, result)
	confirm.queue_free()
	host.queue_free()


func check_y_cancels(confirm, result: Array) -> void:
	confirm.open_key("ui.overwrite_confirm", {"slot": 3})
	var y_key := InputEventKey.new()
	y_key.pressed = true
	y_key.physical_keycode = KEY_Y
	confirm._unhandled_input(y_key)
	_check(result[0] == 1, "Y confirms too")


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
