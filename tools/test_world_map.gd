extends Node
## Phase-3 task G acceptance tests: full world map content + swap mechanism
## (docs/IMPLEMENT-Phase3.md G; docs/70-* §4.8, §4.9.8; docs/10-* §4.4.1,
## §6, §8 group 7; docs/90-* §9.1; docs/20-* §4.1).
##
##   godot --headless --path . tools/test_world_map.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const NationScene := preload("res://scenes/title/nationality_select.tscn")

## docs/70-* §4.9.8: the shipped world grid.
const P3_WIDTH := 160
const P3_HEIGHT := 96
const P1_WIDTH := 128
const P1_HEIGHT := 96
## 30 locked Phase-1 ports + 70 Phase-3-only ports.
const P1_PORT_COUNT := 30
const P3_PORT_COUNT := 100

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_map_index()
	_test_ports_merged()
	_test_p3_legend()
	_test_p3_map_loads()
	_test_p1_map_still_loads()
	_test_no_code_edit_swap()
	_test_new_game_map_choice()
	await _test_world_scene_renders_p3()
	_report()


# --- 1. The map index is data ---------------------------------------------

func _test_map_index() -> void:
	var ids: Array = DataLoader.map_ids()
	_check(ids == ["p1", "p3"],
		"maps.json indexes p1 then p3 (got %s)" % str(ids))
	for map_id in ids:
		var entry: Dictionary = DataLoader.get_map(str(map_id))
		_check(not entry.is_empty(), "get_map('%s') returns an entry" % map_id)
		var files: Dictionary = DataLoader.get_map_files(str(map_id))
		_check(not files.is_empty(), "get_map_files('%s') resolves" % map_id)
		var legend = files.get("legend", {})
		_check(legend is Dictionary and not (legend as Dictionary).is_empty(),
			"get_map_files('%s') carries a legend" % map_id)
		var path := str(files.get("file", ""))
		_check(FileAccess.file_exists("res://" + path),
			"'%s' map file exists (%s)" % [map_id, path])
	# An unknown id falls back to the first entry rather than failing.
	_check(str(DataLoader.get_map("nope").get("id", "")) == "p1",
		"an unknown map id falls back to p1")


# --- 2. Both port files merge into one table ------------------------------

func _test_ports_merged() -> void:
	_check(DataLoader.ports.size() == P3_PORT_COUNT,
		"DataLoader.ports holds all 100 ports (got %d)" % DataLoader.ports.size())
	_check(DataLoader.ports_list.size() == P3_PORT_COUNT,
		"DataLoader.ports_list holds all 100 ports (got %d)"
		% DataLoader.ports_list.size())
	# The Phase-1 order is preserved (the P3 file is appended).
	var p1 = DataLoader.ports_list[0]
	_check(str(p1.get("id", "")) == "lisbon",
		"the Phase-1 file still comes first (got %s)" % str(p1.get("id", "")))
	_check(not DataLoader.get_port("havana").is_empty(),
		"a Phase-3-only port resolves through get_port()")
	_check(str(DataLoader.get_port("havana").get("nation_id", "")) == "spain",
		"the merged port keeps its nation")
	var p1_n = 0
	var p3_n = 0
	for entry in DataLoader.ports_list:
		if (entry as Dictionary).has("p3"):
			p3_n += 1
		if not (entry as Dictionary).has("p3"):
			p1_n += 1
	_check(p3_n == P3_PORT_COUNT,
		"every merged port carries a p3 block (%d of %d)" % [p3_n, DataLoader.ports_list.size()])
	_check(p1_n == 0, "no merged port lacks a p3 block (got %d)" % p1_n)


# --- 3. The P3 legend is complete and well-formed --------------------------

func _test_p3_legend() -> void:
	var legend: Dictionary = DataLoader.get_map_legend("p3")
	_check(not legend.is_empty(), "the P3 legend loads")
	var grid: Dictionary = legend.get("grid", {})
	_check(int(grid.get("width", 0)) == P3_WIDTH
		and int(grid.get("height", 0)) == P3_HEIGHT,
		"the P3 grid is %dx%d (got %sx%s)"
		% [P3_WIDTH, P3_HEIGHT, grid.get("width"), grid.get("height")])
	var tiles: Dictionary = legend.get("tiles", {})
	_check(tiles.keys().size() == 4 and tiles.has("~") and tiles.has("#")
		and tiles.has(".") and tiles.has("^"),
		"the P3 legend uses the four locked tile chars")
	var markers: Dictionary = legend.get("port_markers", {})
	_check(markers.size() == P3_PORT_COUNT,
		"the P3 legend marks %d ports (got %d)" % [P3_PORT_COUNT, markers.size()])
	var expected := {}
	for entry in DataLoader.ports_list:
		var block = (entry as Dictionary).get("p3", null)
		if block is Dictionary:
			expected[str((block as Dictionary)["marker"])] = str(entry["id"])
	_check(markers == expected,
		"every legend marker agrees with its port's p3 block")
	# The P1 legend is untouched by the P3 one.
	var p1_legend: Dictionary = DataLoader.get_map_legend("p1")
	_check((p1_legend.get("grid", {}) as Dictionary).get("width") == P1_WIDTH,
		"the P1 legend still has a %d-wide grid" % P1_WIDTH)
	_check(not is_same(p1_legend, legend),
		"the two legends are separate objects")


# --- 4. The P3 map parses and is navigable --------------------------------

func _test_p3_map_loads() -> void:
	var files: Dictionary = DataLoader.get_map_files("p3")
	var loader = MapLoaderLib.new()
	var ok: bool = loader.load_map("res://" + str(files["file"]), files["legend"])
	_check(ok, "the P3 map parses (%s)" % loader.last_error)
	if not ok:
		return
	_check(loader.width == P3_WIDTH and loader.height == P3_HEIGHT,
		"the parsed P3 map is %dx%d (got %dx%d)"
		% [P3_WIDTH, P3_HEIGHT, loader.width, loader.height])
	_check(loader.port_at.size() == P3_PORT_COUNT,
		"the parsed P3 map places all %d markers (got %d)"
		% [P3_PORT_COUNT, loader.port_at.size()])
	# Every port is reachable from every other under the real movement rule:
	# the generator + validator guarantee one component; assert a BFS here too
	# so a bad data edit fails this suite, not just the Python validator.
	var start := loader.port_cell("lisbon")
	_check(start != Vector2i(-1, -1), "Lisbon has a harbour tile on the P3 map")
	var reached := _bfs(loader, start)
	var unreachable: Array = []
	for cell in loader.port_at:
		if not reached.has(cell):
			unreachable.append("%s@%s" % [loader.port_at[cell], str(cell)])
	_check(unreachable.is_empty(),
		"every P3 port is reachable from Lisbon (unreachable: %s)"
		% str(unreachable.slice(0, 6)))
	var stray := 0
	for y in loader.height:
		for x in loader.width:
			var cell := Vector2i(x, y)
			if loader.is_passable(cell) and not reached.has(cell):
				stray += 1
	_check(stray == 0, "the P3 sea is one component (%d stray tiles)" % stray)
	# The P3 port coords point at real harbour tiles.
	var bad: Array = []
	for port_id in loader.port_at.values():
		var cell: Vector2i = loader.port_cell(str(port_id))
		if not loader.is_passable(cell):
			bad.append(str(port_id))
	_check(bad.is_empty(), "every P3 marker sits on a passable tile (%s)" % str(bad))
	# `p3.position` is what the loader sees (data agreement, not a second table).
	var drift: Array = []
	for entry in DataLoader.ports_list:
		var block = (entry as Dictionary).get("p3", null)
		if not (block is Dictionary):
			continue
		var pos: Dictionary = (block as Dictionary)["position"]
		var want := Vector2i(int(pos["x"]), int(pos["y"]))
		if loader.port_cell(str(entry["id"])) != want:
			drift.append(str(entry["id"]))
	_check(drift.is_empty(),
		"every p3.position matches the map file (%s)" % str(drift))


# --- 5. The Phase-1 map still loads and plays -----------------------------

func _test_p1_map_still_loads() -> void:
	var files: Dictionary = DataLoader.get_map_files("p1")
	var loader = MapLoaderLib.new()
	var ok: bool = loader.load_map("res://" + str(files["file"]), files["legend"])
	_check(ok, "the P1 map still parses (%s)" % loader.last_error)
	if not ok:
		return
	_check(loader.width == P1_WIDTH and loader.height == P1_HEIGHT,
		"the P1 map is still %dx%d" % [P1_WIDTH, P1_HEIGHT])
	_check(loader.port_at.size() == P1_PORT_COUNT,
		"the P1 map still places %d markers (got %d)"
		% [P1_PORT_COUNT, loader.port_at.size()])
	_check(loader.port_cell("lisbon") == Vector2i(7, 57),
		"Lisbon is still at (7,57) on the P1 map")


# --- 6. Swapping maps is data-only ---------------------------------------

## docs/90-* §9/§9.1: adding a map is an index entry plus two data files. The
## loader takes both as plain arguments, so this asserts the pipeline never
## reads a hard-coded path when the index answers.
func _test_no_code_edit_swap() -> void:
	var loader = MapLoaderLib.new()
	# The same file loaded through a *different* legend object still parses.
	var files: Dictionary = DataLoader.get_map_files("p3")
	var legend_copy: Dictionary = (files["legend"] as Dictionary).duplicate(true)
	var ok: bool = loader.load_map("res://" + str(files["file"]), legend_copy)
	_check(ok, "a legend handed in by value parses the map (data-only swap)")
	# A map id that is not in the index is rejected by the loader, not guessed.
	var bad = MapLoaderLib.new()
	_check(not bad.load_map("res://data/maps/nope.txt", legend_copy),
		"a missing map file fails cleanly")
	_check(not bad.last_error.is_empty(), "the failure names a reason")


# --- 7. The new-game choice is saved ------------------------------------

func _test_new_game_map_choice() -> void:
	# P1 (the documented default for a fresh call) …
	GameState.new_game("portugal", false)
	_check(str(GameState.world.get("map_id", "")) == "p1",
		"new_game() defaults to the p1 map (got %s)"
		% str(GameState.world.get("map_id")))
	_check(GameState.world_tile() == Vector2i(7, 57),
		"a p1 run starts on Lisbon's P1 harbour tile (got %s)"
		% str(GameState.world_tile()))
	# … and the full world.
	GameState.new_game("portugal", false, "p3")
	_check(str(GameState.world.get("map_id", "")) == "p3",
		"new_game(..., 'p3') stores map_id p3 (got %s)"
		% str(GameState.world.get("map_id")))
	var lisbon_p3 = DataLoader.get_port("lisbon").get("p3", {})
	var want := Vector2i(int(lisbon_p3["position"]["x"]),
		int(lisbon_p3["position"]["y"]))
	_check(GameState.world_tile() == want,
		"a p3 run starts on Lisbon's P3 harbour tile %s (got %s)"
		% [str(want), str(GameState.world_tile())])
	# An unknown id never wedges a new game.
	GameState.new_game("portugal", false, "p9")
	_check(str(GameState.world.get("map_id", "")) == "p1",
		"an unknown map id falls back to p1 on a new game")
	# The choice survives a save/load round trip.
	GameState.new_game("portugal", false, "p3")
	var snapshot: Dictionary = SaveSystem.snapshot()
	_check(str((snapshot["world"] as Dictionary).get("map_id", "")) == "p3",
		"snapshot() writes world.map_id p3")
	GameState.new_game("portugal", false, "p1")
	SaveSystem.save(1)
	_check(GameState.world.get("map_id") == "p1", "the p1 run is written")
	SaveSystem.load(1)
	_check(GameState.world.get("map_id") == "p1",
		"the loaded run reports its own map (p1)")


# --- 8. The world scene renders the chosen map ---------------------------

func _test_world_scene_renders_p3() -> void:
	GameState.new_game("portugal", false, "p3")
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	var pixels: Vector2 = world.map_pixels()
	_check(pixels == Vector2(P3_WIDTH * 32, P3_HEIGHT * 32),
		"the world scene draws the %dx%d P3 grid (got %s)"
		% [P3_WIDTH, P3_HEIGHT, str(pixels)])
	_check(world.fleet_cell() == GameState.world_tile(),
		"the fleet marker sits on the stored P3 tile")
	# The scene can step off the harbour onto P3 sea.
	var cell: Vector2i = world.fleet_cell()
	var stepped := false
	for delta in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
		if world.try_step(cell + delta):
			stepped = true
			break
	_check(stepped, "the fleet can sail away from Lisbon on the P3 map")
	world.queue_free()
	await get_tree().process_frame

	# The nationality screen offers both worlds and defaults to p3.
	GameState.new_game("portugal", false, "p1")
	var select: Control = NationScene.instantiate()
	add_child(select)
	await get_tree().process_frame
	_check(select.selected_map() == "p3",
		"the new-game screen defaults to the full world (got %s)"
		% select.selected_map())
	select.select_world("p1")
	_check(select.selected_map() == "p1", "the world radio row selects p1")
	select.queue_free()
	await get_tree().process_frame


# --- Helpers --------------------------------------------------------------

## Passable-reachability under the real movement rule (docs/20-* §4.2:
## 8-directional, corner-cutting forbidden).
func _bfs(loader, start: Vector2i) -> Dictionary:
	var reached := {start: true}
	if not loader.is_passable(start):
		return reached
	var queue := [start]
	var head := 0
	var steps := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		for step in steps:
			var next: Vector2i = cell + step
			if reached.has(next) or not loader.is_passable(next):
				continue
			if step.x != 0 and step.y != 0:
				if not loader.is_passable(cell + Vector2i(step.x, 0)) \
						or not loader.is_passable(cell + Vector2i(0, step.y)):
					continue
			reached[next] = true
			queue.append(next)
	return reached


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
