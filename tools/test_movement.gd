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
const SailPathLib := preload("res://scripts/world/sail_path.gd")
const EncountersLib := preload("res://scripts/world/encounters.gd")

## Open-water cell whose 8 neighbours (and both orthogonals of each diagonal)
## are all passable, so every one of the 8 directions is legal from here. On the
## world map it sits in the variables band (lat ≈ 36.7°N), far from every harbor.
const OPEN_CELL := Vector2i(700, 320)
## Lisbon's harbor tile on the world map (derived from lat/lon, `10-*` §6.1) and
## its neighbours: (1023,309) is coastal sea, (1024,307) is land '#'.
const LISBON := Vector2i(1024, 308)
const SEA_BESIDE_LISBON := Vector2i(1023, 309)
const LAND_BESIDE_LISBON := Vector2i(1024, 307)
## A real corner cut on the shipped world: (62,201) → (61,200) is diagonal with
## (61,201) water but (62,200) land, so only one orthogonal exists. Found by
## searching the artifact for that exact shape (task G) — a data fact, not a
## hand-authored fixture like the retired P1 pair.
const CORNER_FROM := Vector2i(62, 201)
const CORNER_TO := Vector2i(61, 200)
## The dominant passable component the artifact reports (> 1 M tiles),
## `data/maps/world_report.json#components.over_1000000`; the in-game BFS must
## reach exactly this many tiles from Lisbon.
const DOMINANT_COMPONENT := 1168747

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
	_test_sail_path_module()
	_test_hold_to_repeat()
	_test_hold_blocked_no_banking()
	_test_click_to_sail()
	_test_corner_cut_impossible()
	_test_dateline_click()
	_test_battle_resume()
	_report()


# --- Fixtures --------------------------------------------------------------

## Minimal run: caravel (speed 10, crew_min 15) at full crew, base stats, fair
## weather → effective speed exactly 10 (§4.4 worked case; Phase-4 speeds are
## the ×2 rescale on 10 nm tiles, `10-*` §7.3).
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
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the movement tests (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	if ok:
		_check(map.width == 2160 and map.height == 1080,
			"grid is 2160×1080 (got %d×%d)" % [map.width, map.height])
		_check(map.is_passable(OPEN_CELL),
			"fixture cell %s is sea" % str(OPEN_CELL))
		_check(map.is_passable(SEA_BESIDE_LISBON),
			"%s beside Lisbon is passable sea" % str(SEA_BESIDE_LISBON))
		_check(not map.is_passable(LAND_BESIDE_LISBON),
			"%s beside Lisbon is land and blocks" % str(LAND_BESIDE_LISBON))
		_check(not map.is_passable(Vector2i(OPEN_CELL.x, -1)),
			"the latitude edge is impassable (§4.1)")
		_check(map.is_passable(Vector2i(-1, OPEN_CELL.y)),
			"x = -1 wraps to the last column and is sea (§4.1)")
		_check(map.is_passable(LISBON),
			"a harbor tile is passable water (§4.11)")


# --- §4.4 effective speed --------------------------------------------------

func _test_effective_speed() -> void:
	_make_run("fair", ["caravel"])
	_check(SailingSimLib.effective_speed() == 10,
		"fair, full crew, seamanship 10: 10 (got %d)"
		% SailingSimLib.effective_speed())
	_check(is_equal_approx(SailingSimLib.move_cost(), 0.1),
		"move_cost = 1/10 = 0.1 days (got %.4f)" % SailingSimLib.move_cost())

	_make_run("calm", ["caravel"])
	_check(SailingSimLib.effective_speed() == 8,
		"calm sail: floor(10 × 0.8) = 8 (got %d)"
		% SailingSimLib.effective_speed())

	_make_run("storm", ["caravel"])
	_check(SailingSimLib.effective_speed() == 15,
		"storm sail: floor(10 × 1.5) = 15 (got %d)"
		% SailingSimLib.effective_speed())

	# Skeleton crew: 1 of crew_min 15 → factor 0.25 → floor(2.5) = 2, never 0.
	_make_run("fair", ["caravel"])
	GameState.fleet[0]["crew"] = 1
	_check(is_equal_approx(SailingSimLib.crew_factor(), 0.25),
		"crew 1/15 → factor 0.25 (got %.4f)" % SailingSimLib.crew_factor())
	_check(SailingSimLib.effective_speed() == 2,
		"skeleton crew floors to max(1, floor(10 × 0.25)) = 2 (got %d)"
		% SailingSimLib.effective_speed())

	# Slowest-hull rule (§4.4 composition): caravel 10 + nao 8 → base 8.
	_make_run("fair", ["caravel", "nao"])
	_check(FleetLib.slowest_speed() == 8,
		"fleet slowest hull speed is the nao's 8 (got %d)"
		% FleetLib.slowest_speed())
	_check(SailingSimLib.effective_speed() == 8,
		"fleet speed uses the slowest hull: 8 (got %d)"
		% SailingSimLib.effective_speed())

	# Seamanship bonus: 20 → +0.10 → floor(11.0) = 11.
	_make_run("fair", ["caravel"])
	GameState.player["stats"]["seamanship"] = 20
	_check(SailingSimLib.effective_speed() == 11,
		"seamanship 20 gives speed 11 (got %d)" % SailingSimLib.effective_speed())
	# 25 → +0.15 → floor(11.5) = 11.
	GameState.player["stats"]["seamanship"] = 25
	_check(SailingSimLib.effective_speed() == 11,
		"seamanship 25 → floor(10 × 1.15) = 11 (got %d)"
		% SailingSimLib.effective_speed())
	# 30 → clamped +0.20 → floor(12.0) = 12.
	GameState.player["stats"]["seamanship"] = 30
	_check(SailingSimLib.effective_speed() == 12,
		"seamanship 30 → floor(10 × 1.2) = 12 (got %d)"
		% SailingSimLib.effective_speed())


# --- §4.2 no corner cutting -----------------------------------------------

func _test_diagonal_rule() -> void:
	var map = DataLoader.map
	_check(SailingSimLib.is_move_legal(OPEN_CELL, OPEN_CELL + Vector2i(1, 1), map),
		"open-water diagonal is legal")
	_check(not SailingSimLib.is_move_legal(CORNER_FROM, CORNER_TO, map),
		"real corner cut (62,201)→(61,200) is rejected")
	_check(SailingSimLib.is_move_legal(
		CORNER_FROM, CORNER_FROM + Vector2i(-1, -1), map) == false,
		"the same corner is rejected for the other orthogonal too")
	_check(SailingSimLib.is_move_legal(
		CORNER_FROM, CORNER_FROM + Vector2i(-1, 0), map)
		and not SailingSimLib.is_move_legal(
			CORNER_FROM, CORNER_FROM + Vector2i(0, -1), map),
		"the straight alternatives behave per the map ((61,201) sea, (62,200) land)")
	_check(not SailingSimLib.is_move_legal(OPEN_CELL, OPEN_CELL + Vector2i(2, 0), map),
		"a two-tile jump is not a move")
	_check(not SailingSimLib.is_move_legal(OPEN_CELL, OPEN_CELL, map),
		"standing still is not a move")

	# Soak: BFS the whole world through the movement rule, from Lisbon. It must
	# reach exactly the dominant sea component the validator reports (> 1 M
	# tiles, `data/maps/world_report.json#components.over_1000000`) — proof the
	# in-game rule is the same "no corner cutting, wrap-aware" rule the data
	# validator enforces. (Re-anchored from the retired 128×96 P1 map's 4109.)
	#
	# The walk uses the int passability API (`is_passable_xy`) because 1.17 M
	# `Vector2i` moves through `is_move_legal` is minutes of GDScript; the rules
	# are the same and [method _legal_int] below is asserted to agree with
	# `SailingSim.is_move_legal` on a large sample, so the soak still measures
	# the production rule.
	var reached := _bfs_reachable(map, LISBON)
	_check(reached == DOMINANT_COMPONENT,
		"BFS through movement rules reaches all %d sea tiles from Lisbon (got %d)"
		% [DOMINANT_COMPONENT, reached])
	var disagreements := 0
	var samples := 0
	var sample_rng := RandomNumberGenerator.new()
	sample_rng.seed = 4242
	for _index in 4000:
		var here := Vector2i(
			sample_rng.randi_range(0, int(map.width) - 1),
			sample_rng.randi_range(1, int(map.height) - 2)
		)
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var next := here + Vector2i(dx, dy)
				samples += 1
				if SailingSimLib.is_move_legal(here, next, map) \
						!= _legal_int(map, here, next):
					disagreements += 1
	_check(disagreements == 0,
		"is_move_legal agrees with the int BFS rule on %d sampled moves (%d differ)"
		% [samples, disagreements])


## Single-step legality on ints: the same §4.2 rule as
## `SailingSim.is_move_legal(from, to, map)` — 8-neighbour, passable target, and
## no corner cutting (both orthogonals of the corner passable). x wraps.
func _legal_int(world_map, from: Vector2i, to: Vector2i) -> bool:
	var dx := to.x - from.x
	var dy := to.y - from.y
	if dx < -1 or dx > 1 or dy < -1 or dy > 1:
		return false
	if dx == 0 and dy == 0:
		return false
	if not world_map.is_passable_xy(to.x, to.y):
		return false
	if dx != 0 and dy != 0:
		if not world_map.is_passable_xy(from.x + dx, from.y):
			return false
		if not world_map.is_passable_xy(from.x, from.y + dy):
			return false
	return true


## Every tile reachable from `start` under [method _legal_int] (x wraps, y is
## bounded). Returns the count.
func _bfs_reachable(world_map, start: Vector2i) -> int:
	var width: int = int(world_map.width)
	var height: int = int(world_map.height)
	var visited := PackedByteArray()
	visited.resize(width * height)
	var queue := PackedInt32Array()
	var start_index := start.y * width + posmod(start.x, width)
	visited[start_index] = 1
	queue.append(start_index)
	var head := 0
	var count := 1
	while head < queue.size():
		var node: int = queue[head]
		head += 1
		var x: int = node % width
		var y: int = node / width
		for dy in [-1, 0, 1]:
			var ny: int = y + dy
			if ny < 0 or ny >= height:
				continue
			for dx in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				var nx: int = posmod(x + dx, width)
				var index: int = ny * width + nx
				if visited[index] == 1:
					continue
				if not world_map.is_passable_xy(nx, ny):
					continue
				if dx != 0 and dy != 0:
					if not world_map.is_passable_xy(x + dx, y):
						continue
					if not world_map.is_passable_xy(x, y + dy):
						continue
				visited[index] = 1
				queue.append(index)
				count += 1
	return count


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

	# Reef: the shipped world has no '^' tiles this phase (`^` count may be 0,
	# build_world.py's done-when), so the rule is proven on a synthetic
	# index-grid map with the same loader (data-driven, `MapLoader.from_indices`).
	var reef_legend := {
		"grid": {"width": 4, "height": 3},
		"tile_size_px": 32,
		"tiles": {
			"~": {"kind": "sea", "passable": true},
			"^": {"kind": "reef", "passable": false},
		},
	}
	# Palette indices are the locked §6.3 ones: 0 = `~`, 3 = `^` (reef).
	var reef_map = MapLoaderLib.from_indices(4, 3,
		PackedByteArray([0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0]), reef_legend)
	_check(reef_map != null, "synthetic reef map builds")
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
	_make_run("fair")  # effective speed 10 → 0.1 days per tile
	GameState.world["position"] = {"x": OPEN_CELL.x, "y": OPEN_CELL.y}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1

	var ticks: Array = []
	var counter := func(day: int) -> void: ticks.append(day)
	EventBus.day_advanced.connect(counter)

	# 10 moves × 0.1 = exactly one day, emitted once, with the new day number.
	# Alternating east/west keeps every step legal on real sea.
	for step in 10:
		var target := Vector2i(
			OPEN_CELL.x + (1 if step % 2 == 0 else 0),
			OPEN_CELL.y
		)
		_check(SailingSimLib.try_move(target, DataLoader.map),
			"clock test: move %d succeeds" % (step + 1))
	_check(ticks.size() == 1,
		"10 moves at speed 10 emit day_advanced exactly once (got %d)" % ticks.size())
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
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), ahead + 0.1),
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
	# Explored set == the wrap-aware sighting square (§4.12), nothing more.
	# Re-anchored in task G: the square wraps on x and clips only at the
	# latitude edges (the retired P1 test clipped at both x edges).
	var radius: int = CharacterLib.sighting_radius()
	var expected := 0
	for dy in range(-radius, radius + 1):
		var y := SEA_BESIDE_LISBON.y + dy
		if y >= 0 and y < 1080:
			expected += 2 * radius + 1
	_check(GameState.explored_tiles.size() == expected,
		"explored tiles = the wrap-aware sighting square (%d, got %d)"
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



## §4.5 as amended (Phase 4): **x wraps, y clamps.** The visible rect's x may
## run past the map width at the seam (the chunk layer renders wrapped content),
## but its y never leaves the grid and the live chunks always cover the view.
func _test_camera_clamp() -> void:
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	host.add_child(world)

	var bounds := Rect2(Vector2.ZERO, world.map_pixels())
	# Re-anchored corners: the retired grid's (127,95) became the world's
	# (2159,1079); the south row is polar ice, so the fixture uses row 900
	# (60°S, still sea) for the "no void" probe there.
	var corners := [
		Vector2i(0, 0), Vector2i(2159, 0), Vector2i(0, 900), Vector2i(2159, 900),
	]
	for corner in corners:
		GameState.world["position"] = {"x": corner.x, "y": corner.y}
		world.sync_from_state()
		var visible: Rect2 = world.visible_world_rect()
		_check(visible.position.y >= bounds.position.y - 0.001
			and visible.end.y <= bounds.end.y + 0.001,
			"camera at %s keeps y inside the grid (visible y %.1f..%.1f, map 0..%.1f)"
			% [str(corner), visible.position.y, visible.end.y, bounds.end.y])
		# The seam rule: x is allowed to run past the map, but the wrapped
		# content must be there — the chunk layer covers the whole view.
		_check(DataLoader.map.covers_rect_world(visible),
			"camera at %s shows wrapped content, never void (visible %s)"
			% [str(corner), str(visible)])

	# Mid-map: the camera centers exactly on the fleet tile (x is not clamped).
	GameState.world["position"] = {"x": 1080, "y": 540}
	world.sync_from_state()
	var center: Vector2 = world.get_node("Camera2D").position
	_check(is_equal_approx(center.x, 1080.0 * 32.0 + 16.0)
		and is_equal_approx(center.y, 540.0 * 32.0 + 16.0),
		"camera centers on the fleet tile mid-map (%s)" % str(center))
	# At the west seam the camera stays on the fleet (x not clamped): a fleet at
	# x = 2 shows x = 2159..2, which is the wrapped world.
	GameState.world["position"] = {"x": 2, "y": 540}
	world.sync_from_state()
	var seam_center: Vector2 = world.get_node("Camera2D").position
	_check(is_equal_approx(seam_center.x, 2.0 * 32.0 + 16.0),
		"camera is not x-clamped at the seam (got %.1f, fleet x=2)"
		% seam_center.x)
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
	hud.set_fleet_cell(Vector2i(1080, 540))
	var area: Label = hud.get_node("TopRow/Area")
	_check(area.text == I18n.t_key("world.open_sea"),
		"area label is open sea when no known port is within 16 tiles (%s)"
		% area.text)
	hud.set_fleet_cell(SEA_BESIDE_LISBON)
	_check(area.text == I18n.t(DataLoader.get_port("lisbon")["name"]),
		"area label names the nearest known port inside 16 tiles (%s)" % area.text)
	GameState.known_ports = []
	hud.set_fleet_cell(SEA_BESIDE_LISBON)
	_check(area.text == I18n.t_key("world.open_sea"),
		"an unknown port does not name the area (%s)" % area.text)
	GameState.current_port = "lisbon"
	hud.set_fleet_cell(Vector2i(1080, 540))
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

	# Phase 4 (`80-*` §4.3, task J): the `M` enlarged minimap is retired — the
	# HUD's box is a fixed 256×192 wrap-aware crop and the whole world is the
	# separate Chart screen (S17). `toggle_minimap()` survives as a no-op seam.
	var minimap: Control = hud.get_node("Minimap")
	_check(minimap.size == Vector2(256, 192),
		"minimap default 256×192 (got %s)" % str(minimap.size))
	_check(hud.minimap_crop_tiles() == Vector2i(128, 96),
		"the minimap is a 128×96-tile crop at 2 px/tile (got %s)"
		% str(hud.minimap_crop_tiles()))
	_check(minimap.position == Vector2(PaletteLib.MARGIN,
		PaletteLib.TOP_BAR_H + PaletteLib.MARGIN),
		"the crop keeps its fixed under-the-top-bar position (got %s)"
		% str(minimap.position))
	hud.toggle_minimap()
	_check(minimap.size == Vector2(256, 192) and not hud.is_minimap_enlarged(),
		"the retired `M` toggle leaves the crop at 256×192 (got %s)"
		% str(minimap.size))

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


# --- Task H: click-to-sail path module (docs/20-* §4.2) --------------------

## The A* module's own contract: no mutation, `[]` on failure, endpoints exact,
## the seam rule, the no-corner-cut guard, and the 2000-tile / 1 s budget.
func _test_sail_path_module() -> void:
	var map = DataLoader.map
	var sail = SailPathLib.new()

	# --- the 2000-tile / 1 s budget -------------------------------------
	# A synthetic 2160×1080 map whose only water is a serpentine corridor: the
	# route must snake four 700-tile bands (≈3,400 steps), so a "straight line"
	# answer or a region clamp would show up as a short path. (The shipped
	# ocean's longest sea route is ~1,743 tiles — an archipelago is in the way —
	# so the 2,000-tile gate is met on this map, which uses the same loader and
	# the same A* module.)
	var wide = _corridor_map()
	_check(wide != null, "the 2000-tile corridor map builds (MapLoader.from_indices)")
	if wide != null:
		var from := Vector2i(601, 100)
		var to := Vector2i(602, 701)
		var started := Time.get_ticks_usec()
		var path: Array[Vector2i] = sail.find_path(from, to, wide)
		var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
		var length := _path_length(path)
		_check(length >= 2000,
			"the synthetic route is a real 2000-tile path (got %d tiles)" % length)
		_check(not path.is_empty() and path[path.size() - 1] == to,
			"the 2000-tile path starts next to %s and ends on %s (got %s..%s)"
			% [str(from), str(to), str(path[0] if not path.is_empty() else "none"),
				str(path[path.size() - 1] if not path.is_empty() else "none")])
		_check(not path.is_empty()
			and maxi(absi(path[0].x - from.x), absi(path[0].y - from.y)) == 1,
			"the first step is one tile from the fleet (%s → %s)"
			% [str(from), str(path[0] if not path.is_empty() else "none")])
		_check(elapsed_ms < SailPathLib.BUDGET_MS,
			"the 2000-tile path computes in %.1f ms (< %.0f ms)" % [
				elapsed_ms, SailPathLib.BUDGET_MS])
		print("NOTE  2000-tile path measured %.1f ms for %d tiles" % [elapsed_ms, length])

	# The two Phase-4 sail toasts (`80-*` §4.7.5). They must exist for the
	# player to see "no route"/"arrived"; if data/ui_strings.json lacks them the
	# module falls back to a console line instead of inventing copy (reported to
	# the master rather than authored here), so this is a NOTE, not a check.
	for key in ["world.sail.no_path", "world.sail.arrived"]:
		var present: bool = DataLoader.ui_strings.has(key)
		if present:
			print("NOTE  %s is present in data/ui_strings.json" % key)
		else:
			print("NOTE  %s is MISSING from data/ui_strings.json: task H "
				% key + "falls back to a console line instead of inventing copy")

	# The shipped world's **longest** sea route (a BFS diameter search puts the
	# two ends 1,743 tiles apart; the grid is 2,160 columns wide but every path
	# has to go round the continents, so 2,000 is unreachable on real water —
	# the synthetic map above is what exercises the budget at that length).
	var long_from := Vector2i(510, 185)
	var long_to := Vector2i(2139, 121)
	var long_started := Time.get_ticks_usec()
	var long_path: Array[Vector2i] = sail.find_path(long_from, long_to, map)
	var long_ms := float(Time.get_ticks_usec() - long_started) / 1000.0
	_check(_path_length(long_path) >= 1700,
		"the world's longest real sea route is ~1,743 tiles (got %d)"
		% _path_length(long_path))
	_check(long_ms < SailPathLib.BUDGET_MS,
		"the longest real sea route computes in %.1f ms (< %.0f ms)" % [
			long_ms, SailPathLib.BUDGET_MS])
	print("NOTE  longest real sea route measured %.1f ms for %d tiles" % [
		long_ms, _path_length(long_path)])

	# An interocean route over 1,000 tiles, also inside the budget
	# (Lisbon → Nagasaki: the Cape of Good Hope route).
	var lisbon: Vector2i = map.port_cell("lisbon")
	var nagasaki: Vector2i = map.port_cell("nagasaki")
	var world_started := Time.get_ticks_usec()
	var world_path: Array[Vector2i] = sail.find_path(lisbon, nagasaki, map)
	var world_ms := float(Time.get_ticks_usec() - world_started) / 1000.0
	_check(world_path.size() > 1000,
		"Lisbon→Nagasaki is a >1000-tile world path (got %d steps)" % world_path.size())
	_check(world_ms < SailPathLib.BUDGET_MS,
		"Lisbon→Nagasaki computes in %.1f ms (< %.0f ms)" % [
			world_ms, SailPathLib.BUDGET_MS])
	print("NOTE  Lisbon→Nagasaki measured %.1f ms for %d steps" % [
		world_ms, world_path.size()])

	# --- endpoint / failure contract ------------------------------------
	_check(sail.find_path(OPEN_CELL, OPEN_CELL, map).is_empty(),
		"a click on the fleet's own tile is not a path (%s)" % sail.last_stage)
	_check(sail.find_path(OPEN_CELL, LAND_BESIDE_LISBON, map).is_empty(),
		"a click on land returns [] (%s)" % sail.last_stage)
	_check(sail.find_path(OPEN_CELL, Vector2i(OPEN_CELL.x, -1), map).is_empty(),
		"a click off the north edge returns [] (%s)" % sail.last_stage)
	var before: Vector2i = GameState.world_tile()
	var before_clock := float(GameState.world.get("clock_fraction", 0.0))
	sail.find_path(lisbon, nagasaki, map)
	_check(GameState.world_tile() == before
		and float(GameState.world.get("clock_fraction", 0.0)) == before_clock,
		"find_path never moves the fleet or touches the clock (pure logic)")
	# A near click is answered on the cheap regional stage.
	var near_path: Array[Vector2i] = sail.find_path(OPEN_CELL, OPEN_CELL + Vector2i(9, 6), map)
	_check(near_path.size() > 0 and sail.last_stage == SailPathLib.STAGE_NEAR,
		"a near click uses the regional stage (%s, %d steps)" % [
			sail.last_stage, near_path.size()])
	_check(_path_end(near_path, OPEN_CELL) == OPEN_CELL + Vector2i(9, 6),
		"the near path ends exactly on the clicked tile")

	# --- no corner cutting ----------------------------------------------
	# Every step of both long paths must satisfy the §4.2 walking rule: that is
	# the no-corner-cut guard, and it is what makes A*'s diagonal mode safe.
	_check(not SailPathLib._illegal_steps(map, world_path),
		"every step of the world path is a legal §4.2 step (no corner cut)")
	_check(not SailPathLib._illegal_steps(map, near_path),
		"every step of the near path is a legal §4.2 step")

	# --- the seam rule ---------------------------------------------------
	_check(SailPathLib.short_dx(2100, 50, 2160) == 110,
		"x=2100 → x=50 is +110 east, not 2,050 (short_dx)")
	_check(SailPathLib.short_dx(50, 2100, 2160) == -110,
		"x=50 → x=2100 is −110 west (short_dx)")
	_check(SailPathLib.short_dx(0, 1080, 2160) == 1080,
		"a half turn stays +1080 (ties do not flip)")
	# The half-turn edge is still inside the full-frame region (an off-by-one
	# there would make exactly the 1,080-tile queries unroutable).
	var half_region: Rect2i = SailPathLib._full_region(2160, 1080, 1080)
	_check(half_region.has_point(Vector2i(1080, 500))
		and half_region.has_point(Vector2i(0, 500))
		and half_region.size.x == 2160,
		"the full region contains a half-turn target and the fleet (%s)"
		% str(half_region))
	var wrapped_region: Rect2i = SailPathLib._full_region(2160, 1080, -1080)
	_check(wrapped_region.has_point(Vector2i(-1080, 500)),
		"the full region contains a negative half-turn target (%s)"
		% str(wrapped_region))
	_check(SailPathLib.local_to_world(Vector2i(2100, 7), Vector2i(60, 7), 2160)
		== Vector2i(0, 7), "local 60 from x=2100 wraps to world x=0")
	var round_trip: Vector2i = SailPathLib.world_to_local(
		Vector2i(2100, 7), Vector2i(0, 7), 2160)
	_check(round_trip == Vector2i(60, 7)
		and SailPathLib.local_to_world(Vector2i(2100, 7), round_trip, 2160)
			== Vector2i(0, 7),
		"world_to_local inverts local_to_world across the seam (%s)"
		% str(round_trip))

	# --- the real dateline crossing --------------------------------------
	# Fleet at x = 2100, click x = 50: |Δx| = 2,050 > 1,080, so §4.2's short-way
	# rule picks the 110-tile route that crosses the x = 2159 → x = 0 seam
	# instead of the 2,050-tile way round. (The doc calls this "the short way
	# west through the seam"; on the grid it is the short way *towards* the
	# seam, i.e. east from 2100 to 2159 and then 0 to 50. This test asserts the
	# normative property — one seam crossing, short length — not a compass
	# label, and the mirror case below covers the 0 → 2159 crossing.)
	var dateline_from := Vector2i(2100, 500)
	var dateline_to := Vector2i(50, 500)
	_check(map.is_passable(dateline_from) and map.is_passable(dateline_to),
		"the dateline fixture cells are open water")
	var dateline: Array[Vector2i] = sail.find_path(dateline_from, dateline_to, map)
	_check(dateline.size() >= 100 and dateline.size() <= 200,
		"the dateline route is the short way (%d steps, long way would be ~2050)"
		% dateline.size())
	var crossings := 0
	var direction := 0
	for index in range(1, dateline.size()):
		var a: Vector2i = dateline[index - 1]
		var b: Vector2i = dateline[index]
		if a.x == 2159 and b.x == 0:
			crossings += 1
			direction = 1
		elif a.x == 0 and b.x == 2159:
			crossings += 1
			direction = -1
	_check(crossings == 1,
		"the dateline route crosses the seam exactly once (%d crossings, dir %d)"
		% [crossings, direction])
	_check(_path_end(dateline, dateline_from) == dateline_to,
		"the dateline route ends on x = 50")
	_check(not SailPathLib._illegal_steps(map, dateline),
		"the dateline route is a legal §4.2 walk")

	# Water with no sea route: a synthetic two-basin map (two puddles with land
	# between) — the same loader, so this is the production "no route" path.
	var split = _split_basin_map()
	_check(split != null, "the split-basin map builds")
	if split != null:
		var unreachable: Array[Vector2i] = sail.find_path(
			Vector2i(2, 2), Vector2i(13, 2), split)
		_check(unreachable.is_empty()
			and sail.last_stage == SailPathLib.STAGE_NO_PATH,
			"a water click with no sea route returns [] and reports no_path (%s)"
			% sail.last_stage)

	# A long way round is never chosen: x = 700 → x = 900 is +200 east.
	var eastward: Array[Vector2i] = sail.find_path(
		Vector2i(700, 320), Vector2i(900, 340), map)
	_check(eastward.size() < 400,
		"a +200 east click is not sent the 1,960-tile way round (%d steps)"
		% eastward.size())


## A 16×5 map whose water is two basins split by land columns at x = 0 and
## x = 8: a legal water click that simply has no route. (x = 0 is land too, so
## the wrap 15 → 0 cannot join them — on a wrapping grid that would otherwise
## be a real route.)
func _split_basin_map():
	var width := 16
	var height := 5
	var indices := PackedByteArray()
	indices.resize(width * height)
	for y in height:
		for x in width:
			indices[y * width + x] = 2 if x == 0 or x == 8 else 0
	var legend := {
		"grid": {"width": width, "height": height},
		"tile_size_px": 32,
		"tiles": {
			"~": {"kind": "sea", "passable": true},
			"#": {"kind": "land", "passable": false},
		},
	}
	return MapLoaderLib.from_indices(width, height, indices, legend)


## The synthetic 2160×1080 corridor map of the 2,000-tile budget check.
func _corridor_map():
	var width := 2160
	var height := 1080
	var indices := PackedByteArray()
	indices.resize(width * height)
	indices.fill(2)  # land everywhere
	var bands := [100, 300, 500, 700]
	for band in bands:
		for dy in 2:
			for x in range(600, 1300):
				indices[(band + dy) * width + x] = 0
	for band_index in range(bands.size() - 1):
		var y0: int = bands[band_index]
		var y1: int = bands[band_index + 1]
		# Connector at alternating ends: the route must snake.
		var link_x := 1299 if band_index % 2 == 0 else 600
		for y in range(y0, y1 + 2):
			for dx in 2:
				indices[y * width + link_x + dx] = 0
	var legend := {
		"grid": {"width": width, "height": height},
		"tile_size_px": 32,
		"tiles": {
			"~": {"kind": "sea", "passable": true},
			"#": {"kind": "land", "passable": false},
		},
	}
	return MapLoaderLib.from_indices(width, height, indices, legend)


## Total Chebyshev length of a path (wrap-aware in x).
func _path_length(path: Array) -> int:
	var total := 0
	for index in range(1, path.size()):
		var a: Vector2i = path[index - 1]
		var b: Vector2i = path[index]
		total += maxi(absi(SailPathLib.short_dx(a.x, b.x, 2160)), absi(b.y - a.y))
	return total


## The cell a path ends on, starting from `from`.
func _path_end(path: Array, from: Vector2i) -> Vector2i:
	return from if path.is_empty() else Vector2i(path[path.size() - 1])


# --- Task H: hold-to-repeat (docs/20-* §4.2) -------------------------------

## A held key: 0.25 s delay, then ~8 steps/s, each a normal move. 20 held
## repeats must equal 20 normal moves in position, day and provisions.
func _test_hold_to_repeat() -> void:
	var map = DataLoader.map
	_make_run("fair")  # effective speed 10 → 0.1 days per tile
	# A long open east–west run at row 320 (probed above: 60 tiles clear).
	GameState.world["position"] = {"x": 700, "y": 320}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	_clear_dialogs(world)

	# Reference: 20 normal moves on a twin fixture, for the clock/provisions
	# math. The weather RNG is seeded identically for both runs, so the day
	# ticks roll the same weather and the speed stays comparable.
	var reference := _twenty_normal_moves(map)
	_make_run("fair")
	SailingSimLib.set_weather_seed(424242)
	# Re-apply the reference stocks so both runs start identically.
	for ship in GameState.fleet:
		ship["provisions"] = reference["provisions0"]
		ship["water"] = reference["water0"]
	GameState.world["position"] = {"x": 700, "y": 320}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	world.sync_from_state()
	_clear_dialogs(world)

	# 1 immediate move on press + 19 more from the cadence over 19 × 0.125 s
	# after the 0.25 s delay.
	var before: Vector2i = world.fleet_cell()
	_check(world.press_direction("move_e"),
		"a held key still steps once immediately (%s)" % str(world.fleet_cell()))
	var state: Dictionary = world.hold_state()
	_check(state["action"] == "move_e" and is_equal_approx(state["delay"], 0.25)
		and is_equal_approx(state["tiles_per_second"], 8.0),
		"the cadence is 0.25 s then 8 tiles/s (%s)" % str(state))
	# Inside the delay: no repeat at all.
	world.advance_movement(0.24)
	_check(world.fleet_cell() == before + Vector2i(1, 0),
		"no repeat inside the 0.25 s delay (got %s)" % str(world.fleet_cell()))
	# Cross the delay; the remainder of the frame (0.01 s) is not a step yet.
	world.advance_movement(0.01)
	_check(world.fleet_cell() == before + Vector2i(1, 0),
		"crossing the delay does not step without a full 0.125 s interval")
	# 19 further intervals = 19 repeats (the 20th move was the press).
	for step in 19:
		world.advance_movement(1.0 / 8.0)
		_clear_dialogs(world)
	var after: Vector2i = world.fleet_cell()
	_check(after == before + Vector2i(20, 0),
		"held-key 20 moves step 20 tiles east (got %s)" % str(after - before))
	world.release_direction("move_e")
	# One more interval after the release must not move.
	world.advance_movement(1.0)
	_check(world.fleet_cell() == after,
		"releasing the key stops the repeat (got %s)" % str(world.fleet_cell()))

	# Clock: 20 moves × 0.1 days = 2.0 days → 2 day ticks, day 3, fraction 0.
	_check(GameState.day == reference["day"],
		"held-key 20 moves reach day %d like 20 normal moves (got %d)"
		% [reference["day"], GameState.day])
	_check(absf(float(GameState.world["clock_fraction"]) - reference["fraction"]) < 1.0e-6,
		"held-key clock_fraction %.9f matches 20 normal moves (%.9f)" % [
			float(GameState.world["clock_fraction"]), reference["fraction"]])
	# Provisions / water: the same daily ledger, so the same stock.
	_check(FleetLib.supplies("provisions") == reference["provisions"],
		"held-key provisions %d match 20 normal moves (%d)" % [
			FleetLib.supplies("provisions"), reference["provisions"]])
	_check(FleetLib.supplies("water") == reference["water"],
		"held-key water %d match 20 normal moves (%d)" % [
			FleetLib.supplies("water"), reference["water"]])
	print("NOTE  hold-to-repeat: 20 steps, day %d, provisions %d→%d, water %d→%d" % [
		GameState.day, reference["provisions0"], FleetLib.supplies("provisions"),
		reference["water0"], FleetLib.supplies("water")])

	# The documented accumulator seam: setting it past the delay makes the very
	# next tick step, with no real time at all.
	world.press_direction("move_e")
	world.set_hold_accumulator(world.HOLD_DELAY_SECONDS,
		world.SAIL_STEP_SECONDS)
	_check(is_equal_approx(world.hold_state()["since_step"],
		world.SAIL_STEP_SECONDS),
		"set_hold_accumulator stores the phase (%.4f)"
		% world.hold_state()["since_step"])
	var seam_before: Vector2i = world.fleet_cell()
	# A hair of simulated time completes the stored 0.125 s exactly once.
	world.advance_movement(0.001)
	_check(world.fleet_cell() == seam_before + Vector2i(1, 0),
		"the accumulator seam produces one deterministic step (got %s)"
		% str(world.fleet_cell() - seam_before))
	world.release_direction("move_e")

	# A press that arrives as a real input event (not the forced seam) is
	# re-verified against `Input.is_action_pressed` every tick: with no key
	# actually held, the next tick clears it instead of sailing on forever.
	var event_base: Vector2i = world.fleet_cell()
	var key_press := InputEventAction.new()
	key_press.action = "move_e"
	key_press.pressed = true
	world._unhandled_input(key_press)
	var after_event: Vector2i = world.fleet_cell()
	_check(after_event == event_base + Vector2i(1, 0),
		"an input-event press steps once immediately (got %s)"
		% str(after_event - event_base))
	world.advance_movement(1.0)
	_check(world.fleet_cell() == after_event
		and world.hold_state()["action"] == "",
		"a press whose key is not actually down stops at the next tick "
		+ "(got %s, held '%s')" % [
			str(world.fleet_cell()), str(world.hold_state()["action"])])

	# A real engine hold (`Input.action_press`, which is what a key-down does):
	# the repeat runs, and ending the hold with `Input.action_release` stops it.
	Input.action_press("move_e")
	var held_start: Vector2i = world.fleet_cell()
	var hold_press := InputEventAction.new()
	hold_press.action = "move_e"
	hold_press.pressed = true
	world._unhandled_input(hold_press)
	_check(world.hold_state()["action"] == "move_e",
		"a real engine hold arms the repeat")
	world.advance_movement(0.25 + 0.125 * 3.0)
	_check(world.fleet_cell().x - held_start.x >= 4,
		"a real engine hold repeats after the delay (%d tiles)"
		% (world.fleet_cell().x - held_start.x))
	var held_at: Vector2i = world.fleet_cell()
	Input.action_release("move_e")
	world.advance_movement(0.5)
	_check(world.fleet_cell() == held_at and world.hold_state()["action"] == "",
		"releasing the engine hold stops the repeat (got %s)" % str(world.fleet_cell()))

	# A release event ends a forced hold too.
	world.press_direction("move_e")
	var before_release: Vector2i = world.fleet_cell()
	var key_up := InputEventAction.new()
	key_up.action = "move_e"
	key_up.pressed = false
	world._unhandled_input(key_up)
	_check(world.hold_state()["action"] == "",
		"an input-event release ends the hold")
	world.advance_movement(1.0)
	_check(world.fleet_cell() == before_release,
		"no repeat after the release event (got %s)" % str(world.fleet_cell()))
	host.queue_free()


## Clock outcome of `count` plain moves from the same start clock, with the
## same weather seed as the scene runs (the day ticks must line up).
func _normal_move_clock(count: int, start_fraction: float) -> Dictionary:
	_make_run("fair")
	SailingSimLib.set_weather_seed(424242)
	GameState.world["clock_fraction"] = start_fraction
	for step in count:
		GameState.set_world_tile(Vector2i(700 + step % 20, 320))
		SailingSimLib.advance_clock(SailingSimLib.move_cost())
	return {"day": GameState.day,
		"fraction": float(GameState.world["clock_fraction"])}


## Baseline for the hold test: 20 plain `SailingSim.advance_clock(move_cost())`
## calls from the same cell/day — the clock side of a normal move — returning
## the resulting clock/provisions/water.
func _twenty_normal_moves(_map) -> Dictionary:
	_make_run("fair")
	SailingSimLib.set_weather_seed(424242)
	var start_provisions := FleetLib.supplies("provisions")
	var start_water := FleetLib.supplies("water")
	for step in 20:
		GameState.set_world_tile(Vector2i(700 + step, 320))
		SailingSimLib.advance_clock(SailingSimLib.move_cost())
	return {
		"day": GameState.day,
		"fraction": float(GameState.world["clock_fraction"]),
		"provisions": FleetLib.supplies("provisions"),
		"water": FleetLib.supplies("water"),
		"provisions0": start_provisions,
		"water0": start_water,
	}


## A blocked step costs nothing and banks nothing: holding into land for a full
## second must not give the fleet a burst of moves when the way clears.
func _test_hold_blocked_no_banking() -> void:
	_make_run("fair")
	GameState.world["position"] = {"x": CORNER_FROM.x, "y": CORNER_FROM.y}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	host.add_child(world)
	_clear_dialogs(world)
	var before: Vector2i = world.fleet_cell()
	var before_clock := float(GameState.world["clock_fraction"])

	# Hold north-west into the real corner ((61,200) land): rejected, no clock.
	world.press_direction("move_nw")
	_check(world.fleet_cell() == before,
		"the corner press is rejected (fleet stays on %s)" % str(world.fleet_cell()))
	_check(float(GameState.world["clock_fraction"]) == before_clock,
		"the rejected press costs no clock (%.9f)"
		% float(GameState.world["clock_fraction"]))
	# Keep holding for 2 s of simulated time: ~16 rejections, still no moves.
	for tick in 16:
		world.advance_movement(1.0 / 8.0)
	_check(world.fleet_cell() == before,
		"16 blocked repeats still do not move the fleet (got %s)" % str(world.fleet_cell()))
	_check(float(GameState.world["clock_fraction"]) == before_clock,
		"16 blocked repeats cost no clock (%.9f)"
		% float(GameState.world["clock_fraction"]))
	world.release_direction("move_nw")

	# Bank check: the phase is not a queue. After the blocked hold, a fresh
	# press on a clear direction moves exactly the 1 immediate step; one
	# interval later exactly one more — never a burst from the blocked time.
	world.press_direction("move_s")
	var after_press: Vector2i = world.fleet_cell()
	_check(after_press == before + Vector2i(0, 1),
		"the fresh press still steps once immediately (%s)" % str(after_press))
	world.advance_movement(1.0 / 8.0)
	_check(world.fleet_cell() == after_press,
		"the blocked hold banked no free moves (got %s)" % str(world.fleet_cell()))
	# 0.125 + 0.10 = 0.225 s < the 0.25 s delay: still no repeat.
	world.advance_movement(0.10)
	_check(world.fleet_cell() == after_press,
		"the fresh press's own delay still applies (got %s)" % str(world.fleet_cell()))
	world.advance_movement(0.025)
	_check(world.fleet_cell() == after_press,
		"crossing the delay alone is not a step (got %s)" % str(world.fleet_cell()))
	world.advance_movement(1.0 / 8.0)
	_check(world.fleet_cell() == after_press + Vector2i(0, 1),
		"exactly one held step after the delay (got %s)" % str(world.fleet_cell()))
	world.release_direction("move_s")
	host.queue_free()


# --- Task H: click-to-sail (docs/20-* §4.2) --------------------------------

func _test_click_to_sail() -> void:
	var map = DataLoader.map
	_make_run("fair")
	GameState.world["position"] = {"x": 700, "y": 320}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	_clear_dialogs(world)

	# Land: rejected, no clock, no order.
	var before_clock := float(GameState.world["clock_fraction"])
	var before_day := GameState.day
	_check(not world.sail_to(LAND_BESIDE_LISBON),
		"a click on land is rejected")
	_check(not world.sail_active(),
		"a rejected land click starts no route")
	_check(float(GameState.world["clock_fraction"]) == before_clock
		and GameState.day == before_day,
		"a rejected land click costs no clock")

	# Off the north edge: rejected.
	_check(not world.sail_to(Vector2i(700, -3)),
		"a click above the grid is rejected")
	# The land-click toast: `world.move_blocked` exists, so it is shown.
	var hud_for_toast = world.get_node("HUDLayer/HUD")
	_check(hud_for_toast.toast_key("world.move_blocked"),
		"the land-click toast key world.move_blocked exists")
	_check((hud_for_toast.get_node("Toast/ToastLabel") as Label).text
		== I18n.t_key("world.move_blocked"),
		"the land-click toast shows the move_blocked copy (%s)"
		% (hud_for_toast.get_node("Toast/ToastLabel") as Label).text)

	# The fleet's own tile: a no-op, no toast, no order.
	_check(not world.sail_to(Vector2i(700, 320)),
		"a click on the fleet's own tile is a no-op")

	# Water: order stored, but the click itself does not move the fleet.
	var target := Vector2i(730, 330)
	_check(world.sail_to(target), "a click on water stores a route")
	_check(world.fleet_cell() == Vector2i(700, 320),
		"storing the route does not move the fleet")
	_check(world.sail_target() == target, "the route remembers its destination")
	var path: Array = world.sail_path()
	_check(not path.is_empty() and path[path.size() - 1] == target,
		"the stored route ends on the clicked tile (%d steps)" % path.size())
	_check(world.sail_pathing().last_stage == SailPathLib.STAGE_NEAR,
		"a nearby click was answered by the regional stage")

	# Walk it on the same cadence as hold-to-repeat: N steps = N moves.
	var steps := path.size()
	var clock_at_click := float(GameState.world["clock_fraction"])
	# Pin the weather stream so the twin reference rolls the same days.
	SailingSimLib.set_weather_seed(424242)
	for step in steps:
		world.advance_movement(1.0 / 8.0)
		_clear_dialogs(world)
	_check(world.fleet_cell() == target,
		"the route walks every step to the target (got %s, target %s)"
		% [str(world.fleet_cell()), str(target)])
	_check(not world.sail_active(), "reaching the target clears the order")
	_check(world.fleet_cell() == target and world.sail_target() == Vector2i(-1, -1),
		"the finished order forgets its target (sail_target %s)"
		% str(world.sail_target()))
	# N moves: the clock advanced by N × 1/speed days. Day ticks change the
	# weather (and therefore the speed), so the reference run is N normal moves
	# on a twin fixture with identical weather rolls.
	var reference := _normal_move_clock(steps, clock_at_click)
	_check(GameState.day == reference["day"]
		and absf(float(GameState.world["clock_fraction"])
			- reference["fraction"]) < 1.0e-6,
		"the route's %d steps cost the same clock as %d normal moves (day %d, fraction %.9f)"
		% [steps, steps, GameState.day, float(GameState.world["clock_fraction"])])

	# Manual input cancels an active route.
	_check(world.sail_to(Vector2i(700, 340)), "a second route is stored")
	world.advance_movement(1.0 / 8.0)
	_check(world.sail_active(), "the second route is walking")
	world.press_direction("move_w")
	_check(not world.sail_active(),
		"a manual direction press cancels the click route")
	world.release_direction("move_w")

	# A modal cancels nothing but freezes the cadence (docs/80-* §4.3).
	_check(world.sail_to(Vector2i(705, 322)), "a third route is stored")
	var frozen_at: Vector2i = world.fleet_cell()
	var hud = world.get_node("HUDLayer/HUD")
	hud.show_dialog("ui.cant_save_here")
	for tick in 8:
		world.advance_movement(1.0 / 8.0)
	_check(world.fleet_cell() == frozen_at,
		"a modal freezes the route (got %s)" % str(world.fleet_cell()))
	hud.current_dialog().close()
	_clear_dialogs(world)
	world.advance_movement(1.0 / 8.0)
	_check(world.fleet_cell() != frozen_at,
		"the route resumes when the modal closes")
	world.cancel_sail()
	host.queue_free()


# --- Task H: corner-cut injection is impossible ---------------------------

func _test_corner_cut_impossible() -> void:
	var map = DataLoader.map
	# 1. The mode itself: the module pins the no-corner-cut diagonal rule.
	_check(SailPathLib.DIAGONAL_MODE
		== AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES,
		"the A* diagonal mode is DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES")
	# 2. Every diagonal of every returned path has both orthogonals passable.
	var sail = SailPathLib.new()
	var cases := [
		[Vector2i(700, 320), Vector2i(820, 300)],
		[Vector2i(1024, 308), Vector2i(1275, 360)],
		[Vector2i(479, 438), Vector2i(1275, 360)],
		[Vector2i(2100, 500), Vector2i(50, 500)],
	]
	var diagonals := 0
	var violations := 0
	for c in cases:
		var path: Array[Vector2i] = sail.find_path(c[0], c[1], map)
		_check(not path.is_empty() and not SailPathLib._illegal_steps(map, path),
			"auto path %s→%s has no illegal step (%d steps)"
			% [str(c[0]), str(c[1]), path.size()])
		var cursor: Vector2i = c[0]
		for step in path:
			var dx := SailPathLib.short_dx(cursor.x, step.x, 2160)
			var dy := step.y - cursor.y
			if dx != 0 and dy != 0:
				diagonals += 1
				if not map.is_passable_xy(cursor.x + dx, cursor.y) \
						or not map.is_passable_xy(cursor.x, cursor.y + dy):
					violations += 1
			cursor = step
	_check(diagonals > 0, "the auto paths really contain diagonals (%d)" % diagonals)
	_check(violations == 0,
		"every diagonal of the auto paths has both orthogonals passable (%d checked)"
		% diagonals)
	print("NOTE  corner-cut proof: %d diagonals across %d auto paths, %d violations"
		% [diagonals, cases.size(), violations])

	# 3. The guard rejects a doctored path: a hand-built corner cut cannot leave
	#    the module's validator either.
	var doctored: Array = [CORNER_FROM, CORNER_TO]
	_check(SailPathLib._illegal_steps(map, doctored),
		"the validator flags the real corner cut (%s→%s)"
		% [str(CORNER_FROM), str(CORNER_TO)])
	_check(not SailPathLib.is_step_legal(map, CORNER_FROM, CORNER_TO),
		"is_step_legal rejects the real corner cut")

	# 4. Manual diagonal spam at the real corner through the scene: 20 presses
	#    never move the fleet and never cost clock.
	_make_run("fair")
	GameState.world["position"] = {"x": CORNER_FROM.x, "y": CORNER_FROM.y}
	GameState.world["clock_fraction"] = 0.0
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	_clear_dialogs(world)
	var clock_before := float(GameState.world["clock_fraction"])
	var day_before := GameState.day
	for press in 20:
		world.press_direction("move_nw")
		world.advance_movement(1.0 / 8.0)
	world.release_direction("move_nw")
	_check(world.fleet_cell() == CORNER_FROM,
		"20 manual diagonal presses at the corner never move the fleet (got %s)"
		% str(world.fleet_cell()))
	_check(float(GameState.world["clock_fraction"]) == clock_before
		and GameState.day == day_before,
		"corner-cut spam costs no clock and no day")
	host.queue_free()


# --- Task H: dateline click through the scene -----------------------------

func _test_dateline_click() -> void:
	var map = DataLoader.map
	_make_run("fair")
	GameState.world["position"] = {"x": 2100, "y": 500}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	_clear_dialogs(world)
	_check(world.fleet_cell() == Vector2i(2100, 500),
		"the dateline fixture starts at x = 2100")

	# Click x = 50: |Δx| = 2050 > 1080, so the short way is +110 (east).
	var target := Vector2i(50, 500)
	_check(world.sail_to(target), "a dateline click stores a route")
	var path: Array = world.sail_path()
	var long_way := 2160 - 110
	_check(path.size() >= 100 and path.size() <= 200,
		"the dateline route is %d steps, the short way (long way ≈ %d)"
		% [path.size(), long_way])
	_check(path[path.size() - 1] == target,
		"the dateline route ends on x = 50 (got %s)"
		% str(path[path.size() - 1]))
	var crossed_east := false
	var cursor: Vector2i = world.fleet_cell()
	for step in path:
		if cursor.x == 2159 and step.x == 0:
			crossed_east = true
		cursor = step
	_check(crossed_east, "the dateline route crosses x = 2159 → x = 0")
	# Walk it: exactly one seam crossing, and the fleet lands on the target.
	var seam_crossings := 0
	for step in path.size():
		cursor = world.fleet_cell()
		world.advance_movement(1.0 / 8.0)
		_clear_dialogs(world)
		if cursor.x == 2159 and world.fleet_cell().x == 0:
			seam_crossings += 1
	_check(world.fleet_cell() == target,
		"the fleet sails through the seam to x = 50 (got %s)"
		% str(world.fleet_cell()))
	_check(seam_crossings >= 1, "the walk crossed the seam (%d)" % seam_crossings)

	# The mirror case: fleet at x = 50 clicking x = 2100 is the short −110 west,
	# crossing x = 0 → x = 2159 (the other seam direction).
	GameState.set_world_tile(Vector2i(50, 500))
	world.sync_from_state()
	var west_target := Vector2i(2100, 500)
	_check(world.sail_to(west_target), "the mirrored dateline click stores a route")
	var west_path: Array = world.sail_path()
	_check(west_path.size() >= 100 and west_path.size() <= 200,
		"the mirrored route is the short way (%d steps)" % west_path.size())
	var west_crossed := false
	var west_cursor: Vector2i = world.fleet_cell()
	for step in west_path:
		if west_cursor.x == 0 and step.x == 2159:
			west_crossed = true
		west_cursor = step
	_check(west_crossed, "the mirrored route crosses x = 0 → x = 2159 (westward)")
	print("NOTE  dateline paths: x2100→x50 %d steps, x50→x2100 %d steps "
		% [path.size(), west_path.size()] + "(long way round would be ~2050 each)")
	world.cancel_sail()

	# A held direction also steps across the seam (the move rule works on the
	# short delta, and the stored cell is normalised to [0, 2160)).
	GameState.set_world_tile(Vector2i(2159, 500))
	world.sync_from_state()
	_check(world.press_direction("move_e"),
		"a held east step from x = 2159 is legal")
	_check(world.fleet_cell() == Vector2i(0, 500)
		and GameState.world_tile() == Vector2i(0, 500),
		"the seam step lands on x = 0 and stores the wrapped cell (got %s / %s)"
		% [str(world.fleet_cell()), str(GameState.world_tile())])
	world.release_direction("move_e")
	GameState.set_world_tile(Vector2i(0, 500))
	world.sync_from_state()
	_check(world.press_direction("move_w"),
		"a held west step from x = 0 is legal")
	_check(world.fleet_cell() == Vector2i(2159, 500),
		"the westward seam step lands on x = 2159 (got %s)"
		% str(world.fleet_cell()))
	world.release_direction("move_w")
	host.queue_free()


# --- Task H: battle interruption resumes the route ------------------------

func _test_battle_resume() -> void:
	var map = DataLoader.map
	_make_run("fair")
	GameState.world["position"] = {"x": 700, "y": 320}
	GameState.world["clock_fraction"] = 0.0
	GameState.day = 1
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {EncountersLib.PIRATE: 999999,
		EncountersLib.NAVY: 999999}
	GameState.pending_encounter = null
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	_clear_dialogs(world)

	# A pirate marker 1 tile off the route opens contact on the first step that
	# lands beside it (§4.11.11.1).
	var marker_cell := Vector2i(702, 321)
	GameState.hostile_fleets.append({
		"id": "pirate_resume",
		"kind": EncountersLib.PIRATE,
		"nation_id": "",
		"position": {"x": marker_cell.x, "y": marker_cell.y},
		"anchor_port_id": "lisbon",
		"ships": EncountersLib.compose_ships(EncountersLib.PIRATE, 1, marker_cell),
		"spawn_day": 1,
		"cooldown_until_day": 0,
	})
	world.encounters().last_tick_day = GameState.day

	var target := Vector2i(712, 320)
	_check(world.sail_to(target), "a route is stored before the battle")
	var original_target: Vector2i = world.sail_target()
	# Step until contact: the first step to (701,320) is beside the marker.
	world.advance_movement(1.0 / 8.0)
	_check(world.battle_in_progress(),
		"the route is interrupted by a battle on the way")
	_check(world.sail_suspended() and world.sail_target() == original_target,
		"the order is suspended but keeps its original target (%s)"
		% str(world.sail_target()))
	var position_at_battle: Vector2i = world.fleet_cell()

	# Nothing walks while the battle is unresolved.
	for tick in 8:
		world.advance_movement(1.0 / 8.0)
	_check(world.fleet_cell() == position_at_battle,
		"the route never walks during the battle (got %s)"
		% str(world.fleet_cell()))

	# Dismiss the battle: the remaining path is recomputed to the same target.
	EventBus.battle_finished.emit({
		"result": "victory", "encounter_id": "pirate_resume",
	})
	_check(not world.battle_in_progress(), "the battle is over after dismissal")
	_check(not world.sail_suspended(),
		"dismissing the battle resumes the route (suspended flag cleared)")
	_check(world.sail_target() == original_target,
		"the resumed route still targets the original click (%s)"
		% str(world.sail_target()))
	var resumed: Array = world.sail_path()
	_check(not resumed.is_empty() and resumed[resumed.size() - 1] == original_target,
		"the recomputed remaining path ends on the original target (%s, %d steps)"
		% [str(resumed[resumed.size() - 1] if not resumed.is_empty() else "none"),
			resumed.size()])

	# Walk the rest: the fleet must actually end on the clicked tile.
	for tick in 64:
		if not world.sail_active():
			break
		world.advance_movement(1.0 / 8.0)
		_clear_dialogs(world)
	_check(world.fleet_cell() == original_target,
		"the fleet reaches the original target after the battle (got %s, want %s)"
		% [str(world.fleet_cell()), str(original_target)])

	# A manual press during the suspension cancels it for good.
	var second_marker: Vector2i = world.fleet_cell() + Vector2i(2, 1)
	GameState.hostile_fleets = [{
		"id": "pirate_resume2",
		"kind": EncountersLib.PIRATE,
		"nation_id": "",
		"position": {"x": second_marker.x, "y": second_marker.y},
		"anchor_port_id": "lisbon",
		"ships": EncountersLib.compose_ships(
			EncountersLib.PIRATE, GameState.day, second_marker),
		"spawn_day": GameState.day,
		"cooldown_until_day": 0,
	}]
	# Same day: only the contact check runs (no spawn/move pass).
	world.encounters().last_tick_day = GameState.day
	var far_target := Vector2i(world.fleet_cell().x + 8, world.fleet_cell().y)
	_check(world.sail_to(far_target), "a second route is stored")
	world.advance_movement(1.0 / 8.0)
	_check(world.battle_in_progress(), "the second battle interrupts it")
	world.press_direction("move_w")
	world.release_direction("move_w")
	_check(not world.sail_active(),
		"manual input cancels a suspended route permanently")
	EventBus.battle_finished.emit({
		"result": "victory", "encounter_id": "pirate_resume2",
	})
	_check(not world.sail_active(),
		"dismissing the battle does not resurrect a cancelled route")

	# A chained battle (§4.11.11.1 "battles chain") keeps the route suspended:
	# a second marker still in contact opens before the route resumes.
	GameState.hostile_fleets = []
	GameState.set_world_tile(Vector2i(700, 320))
	world.sync_from_state()
	_clear_dialogs(world)
	var chain_markers := [Vector2i(701, 321), Vector2i(700, 321)]
	for index in chain_markers.size():
		var cell: Vector2i = chain_markers[index]
		GameState.hostile_fleets.append({
			"id": "chain_%d" % index,
			"kind": EncountersLib.PIRATE,
			"nation_id": "",
			"position": {"x": cell.x, "y": cell.y},
			"anchor_port_id": "lisbon",
			"ships": EncountersLib.compose_ships(
				EncountersLib.PIRATE, GameState.day, cell),
			"spawn_day": GameState.day,
			"cooldown_until_day": 0,
		})
	world.encounters().last_tick_day = GameState.day
	var chain_target := Vector2i(712, 320)
	_check(world.sail_to(chain_target), "a third route is stored")
	world.advance_movement(1.0 / 8.0)
	_check(world.battle_in_progress(), "the first of the pair opens a battle")
	var first_id: String = world.pending_encounter_id()
	_check(not first_id.is_empty(), "the battle names the marker it opened (%s)"
		% first_id)
	# Finish the first battle: the second marker is still in contact.
	EventBus.battle_finished.emit({
		"result": "victory", "encounter_id": first_id,
	})
	_check(world.battle_in_progress(),
		"a chained battle opens from the second marker in contact")
	_check(world.sail_suspended(),
		"the route stays suspended through the chained battle")
	GameState.hostile_fleets = []
	world.encounters().last_tick_day = GameState.day
	EventBus.battle_finished.emit({
		"result": "victory", "encounter_id": world.pending_encounter_id(),
	})
	_check(not world.battle_in_progress() and not world.sail_suspended(),
		"the route resumes once the chain is over (%s / %s)" % [
			str(world.battle_in_progress()), str(world.sail_suspended())])
	_check(world.sail_target() == chain_target,
		"the chained-battle resume keeps the original target")
	world.cancel_sail()
	host.queue_free()


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
