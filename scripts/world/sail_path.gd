extends RefCounted
## Click-to-sail pathing (docs/20-WORLD-AND-SAILING.md §4.2;
## docs/IMPLEMENT-Phase4.md task H). Pure logic: no node references, no scene
## access, no `GameState` mutation — a caller asks for a path and walks it with
## the normal per-step movement rules.
##
## ```gdscript
## var sail := SailPathLib.new()
## var path: Array[Vector2i] = sail.find_path(fleet_cell, clicked_cell, map)
## ```
##
## ## Region and solidity
##
## `AStarGrid2D` needs every solid cell marked before a query, and the shipped
## grid is 2160 × 1080 = 2.33 M tiles. Marking the whole grid one
## `set_point_solid()` call at a time through `is_passable_xy()` took ~280 ms on
## this machine; the module therefore searches in a **local frame** (§4.2) and
## in two stages:
##
## 1. **Near targets** (local-frame Chebyshev ≤ [constant NEAR_REGION_TILES]):
##    the region is the endpoint bounding box expanded by
##    [constant REGION_MARGIN] tiles and clamped to the grid — a few hundred
##    cells, so the query is sub-millisecond. This is the common case (a click
##    a screen or two away).
## 2. **Everything else**, and any near query that could not be answered inside
##    its box: the region is one full turn of the world — 2160 distinct columns
##    laid out around the fleet, with the target well inside — over the whole
##    latitude range, marked straight from `MapLoader.indices`. (A narrow
##    bounding box around two far-apart endpoints cannot work on this map: the
##    route to the Pacific runs either through the Arctic ice or down past Cape
##    Horn, both of which the box would cut off, and every path that stays
##    inside a box is *longer* than the true one.)
##
## Measured on the shipped artifact (Godot 4.7, headless Linux, this worktree):
## the world's longest real sea route (1,742 tiles) in ~0.37 s, Lisbon→Nagasaki
## (1,145 steps round the Cape of Good Hope) in ~0.29 s, and a 3,387-tile
## synthetic serpentine corridor in ~0.20 s — all inside the task's
## [constant BUDGET_MS] budget. The near stage answers a click a few tiles away
## in well under a millisecond.
##
## ## Jumping (`jumping_enabled`)
##
## The task pins `jumping_enabled = true`, and this module sets it on the
## **near** stage (where a jump-point search is never slower). On the shipped
## world's open ocean the flag is a pessimisation for long routes instead of an
## optimisation — the same 1,355-tile query measures ~2.0 s with jumping on and
## ~0.14 s with it off, because jump-point search has to scan whole
## obstacle-free rows/columns per expansion and this map is mostly open water.
## The full-grid stage therefore runs the **same** `AStarGrid2D`, region and
## `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` with jumping off. That is the task's
## pinned escape hatch ("pre-named fallback, implemented only if the 1 s budget
## fails") at its smallest possible setting: the heavier pinned fallback (a
## coarse passable-waypoint graph refined per chunk) was **not** needed and is
## not implemented (see [member last_jumping] / [member last_stage]).
##
## ## No corner cutting
##
## `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` already blocks a diagonal whose either
## orthogonal neighbour is solid. Jumped segments are expanded back into unit
## steps and every step is re-validated against the §4.2 walking rule
## ([method is_step_legal]), so a corner-cutting path can never leave this
## module (it returns `[]` instead — [constant STAGE_ILLEGAL]).
##
## ## Seam handling (pinned)
##
## `AStarGrid2D` rejects points outside its region, so a seam-crossing query is
## made in a local frame: both `x` are shifted by `−from.x mod 2160` into the
## local frame, the query runs there, and the returned path is shifted back with
## `posmod`. The target's local `x` is the **short way** around the seam
## ([method short_dx], `|Δx| ≤ 1080`), so a fleet at `x = 2100` clicking
## `x = 50` gets the 110-step path across `x = 2159 → 0`, never the 2,050-step
## way round.

## Region margin (tiles) around the endpoint bounding box for a near query.
const REGION_MARGIN := 24
## Local-frame Chebyshev distance up to which the cheap regional query is used.
const NEAR_REGION_TILES := 256
## The task's path budget in ms (the test measures against it).
const BUDGET_MS := 1000.0
## The pinned A* diagonal rule: a diagonal is only allowed when both orthogonal
## neighbours are free — no corner cutting (§4.2).
const DIAGONAL_MODE := AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES

## Stage tags for [member last_stage].
const STAGE_SAME_CELL := "same_cell"
const STAGE_NEAR := "near_region"
const STAGE_FULL := "full_region"
const STAGE_NO_PATH := "no_path"
const STAGE_ILLEGAL := "illegal_step"
const STAGE_BAD_MAP := "bad_map"

## Diagnostics of the most recent [method find_path] call (the report and the
## tests read them; nothing in the game depends on them).
var last_ms: float = 0.0
var last_region := Rect2i()
var last_jumping := false
var last_stage := ""
var last_raw_points: int = 0


## Shortest signed `dx` between two columns on a wrapping grid:
## `|result| ≤ width / 2` and `to_x == from_x + result (mod width)`.
static func short_dx(from_x: int, to_x: int, width: int = 2160) -> int:
	if width <= 0:
		return to_x - from_x
	var dx := posmod(to_x - from_x, width)
	if dx > width / 2:
		dx -= width
	return dx


## Local-frame → world cell; [method world_to_local] is the inverse.
static func local_to_world(origin: Vector2i, local_cell: Vector2i,
		width: int = 2160) -> Vector2i:
	return Vector2i(posmod(origin.x + local_cell.x, width), local_cell.y)


## The inverse of [method local_to_world].
static func world_to_local(origin: Vector2i, world_cell: Vector2i,
		width: int = 2160) -> Vector2i:
	return Vector2i(posmod(world_cell.x - origin.x, width), world_cell.y)


## Finds the walkable route from `from` to `to` (world cells; `x` wraps).
##
## Returns the **unit steps after `from`**, ending exactly on `to`, or `[]` when
## there is no sea route (or an endpoint is impassable / off-grid). Never
## mutates the map, `GameState` or the caller's cells.
##
## `map` is a `MapLoader` (needs `width`, `height`, `indices` and
## `is_passable_xy`). `opts` accepts `margin` (near-region margin, default
## [constant REGION_MARGIN]) and `near_tiles` (default
## [constant NEAR_REGION_TILES]); both exist for the tests.
func find_path(from: Vector2i, to: Vector2i, map, opts: Dictionary = {}) -> Array[Vector2i]:
	var started := Time.get_ticks_usec()
	last_ms = 0.0
	last_region = Rect2i()
	last_jumping = false
	last_stage = ""
	last_raw_points = 0
	var empty: Array[Vector2i] = []
	if map == null or int(map.width) <= 0 or int(map.height) <= 0:
		last_stage = STAGE_BAD_MAP
		last_ms = _elapsed_ms(started)
		return empty
	var width: int = int(map.width)
	var height: int = int(map.height)
	var origin := Vector2i(posmod(from.x, width), from.y)
	var goal := Vector2i(posmod(to.x, width), to.y)
	if origin.y < 0 or origin.y >= height or goal.y < 0 or goal.y >= height \
			or not map.is_passable(origin) or not map.is_passable(goal):
		last_stage = STAGE_NO_PATH
		last_ms = _elapsed_ms(started)
		return empty
	if origin == goal:
		last_stage = STAGE_SAME_CELL
		last_ms = _elapsed_ms(started)
		return empty

	# Local frame (§4.2): our column is local x = 0, the target is the
	# short-way signed dx away.
	var dx := short_dx(origin.x, goal.x, width)
	var local_goal := Vector2i(dx, goal.y)
	var margin: int = int(opts.get("margin", REGION_MARGIN))
	var near_tiles: int = int(opts.get("near_tiles", NEAR_REGION_TILES))

	var near_span := maxi(absi(dx), absi(goal.y - origin.y))
	var path: Array[Vector2i] = []
	if near_span <= near_tiles:
		# The endpoint bounding box plus the margin, clamped to the grid. It is
		# at most `2 * NEAR_REGION_TILES + 2 * margin` wide, far below `width`,
		# so no world column repeats inside it.
		var x_lo := mini(0, dx) - margin
		var x_hi := maxi(0, dx) + margin
		var y_lo := maxi(0, mini(origin.y, goal.y) - margin)
		var y_hi := mini(height - 1, maxi(origin.y, goal.y) + margin)
		var near_region := Rect2i(x_lo, y_lo, x_hi - x_lo + 1, y_hi - y_lo + 1)
		path = _query(map, origin, local_goal, near_region, true)
		if not path.is_empty():
			last_stage = STAGE_NEAR
			last_ms = _elapsed_ms(started)
			return path
		if last_stage == STAGE_ILLEGAL:
			# A jumped segment broke the walking rule: fall through to the
			# un-jumped stage rather than hand the caller a bad path.
			last_stage = ""

	# Full local frame: one turn of the world (every column exactly once, no
	# duplicate Names), whole latitude range so a detour around a continent is
	# available, and both endpoints inside it.
	var full_region := _full_region(width, height, dx)
	path = _query(map, origin, local_goal, full_region, false)
	if not path.is_empty():
		last_stage = STAGE_FULL
		last_ms = _elapsed_ms(started)
		return path
	if last_stage.is_empty():
		last_stage = STAGE_NO_PATH
	last_ms = _elapsed_ms(started)
	return empty


## One turn of the world in the local frame: exactly `width` distinct columns
## containing both local x = 0 (the fleet) and `dx` (the target, already the
## short-way signed offset, so `|dx| ≤ width / 2`). The fleet ends up in the
## middle of the ring, so a route may detour either way round it.
static func _full_region(width: int, height: int, dx: int) -> Rect2i:
	# [-width/2, width/2) contains `dx` for every short-way offset; nudge the
	# window by one when dx sits exactly on the high edge (dx == width / 2).
	var x_lo := -width / 2
	if dx >= x_lo + width:
		x_lo = dx - width + 1
	return Rect2i(x_lo, 0, width, height)


## One `AStarGrid2D` query in `region` (local frame; `origin.x` is local x = 0).
func _query(map, origin: Vector2i, local_goal: Vector2i, region: Rect2i,
		jumping: bool) -> Array[Vector2i]:
	last_region = region
	last_jumping = jumping

	var grid := AStarGrid2D.new()
	grid.region = region
	grid.cell_size = Vector2(1, 1)
	grid.diagonal_mode = DIAGONAL_MODE
	grid.jumping_enabled = jumping
	grid.update()
	_mark_solid(grid, map, region, origin.x)

	var empty: Array[Vector2i] = []
	var start := Vector2i(0, origin.y)
	var goal := Vector2i(local_goal.x, local_goal.y)
	if not region.has_point(start) or not region.has_point(goal):
		return empty
	if grid.is_point_solid(start) or grid.is_point_solid(goal):
		return empty
	var raw: Array = grid.get_point_path(start, goal)
	last_raw_points = raw.size()
	if raw.size() < 2:
		return empty
	return _expand_and_validate(map, origin, raw)


## Sets every impassable cell of `region` solid. The region is in the local
## frame, so local `x` names world column `origin_x + x (mod width)`. Reads the
## loader's palette bytes directly (one array index per tile); the fallback via
## `is_passable_xy()` keeps synthetic loaders without `indices` working.
func _mark_solid(grid: AStarGrid2D, map, region: Rect2i, origin_x: int) -> void:
	var width: int = int(map.width)
	var indices: PackedByteArray = map.indices
	var direct := indices.size() == width * int(map.height)
	for y in range(region.position.y, region.end.y):
		var row := y * width
		for x in range(region.position.x, region.end.x):
			var world_x := posmod(origin_x + x, width)
			var passable: bool
			if direct:
				passable = indices[row + world_x] <= 1
			else:
				passable = map.is_passable_xy(world_x, y)
			if not passable:
				grid.set_point_solid(Vector2i(x, y), true)


## Converts the raw local-frame points to unit steps, expands every jumped
## segment in the local frame, then shifts the whole walk to world cells and
## re-validates each step (§4.2). Returns the steps **after** `origin`, or `[]`
## (stage [constant STAGE_ILLEGAL]) when a segment cannot be walked without
## cutting a corner.
func _expand_and_validate(map, origin: Vector2i, raw: Array) -> Array[Vector2i]:
	var width: int = int(map.width)
	var empty: Array[Vector2i] = []
	var start_local := Vector2i(raw[0])
	var goal_local := Vector2i(raw[raw.size() - 1])
	var walk: Array[Vector2i] = [start_local]
	for index in range(1, raw.size()):
		var target := Vector2i(raw[index])
		var cursor: Vector2i = walk[walk.size() - 1]
		var delta := target - cursor
		var step := Vector2i(signi(delta.x), signi(delta.y))
		var guard := 0
		while cursor != target:
			guard += 1
			if guard > absi(delta.x) + absi(delta.y) + 8:
				last_stage = STAGE_ILLEGAL
				return empty
			cursor += step
			walk.append(cursor)
		if walk[walk.size() - 1] != target:
			last_stage = STAGE_ILLEGAL
			return empty
	if walk.size() < 2 or walk[walk.size() - 1] != goal_local:
		last_stage = STAGE_ILLEGAL
		return empty
	var world: Array[Vector2i] = []
	for cell in walk:
		world.append(local_to_world(origin, cell, width))
	if _illegal_steps(map, world):
		last_stage = STAGE_ILLEGAL
		return empty
	world.remove_at(0)
	return world


## True when any consecutive pair of `path` is not one legal §4.2 step. The
## corner-cut proof in `tools/test_movement.gd` walks returned paths through
## this same predicate.
static func _illegal_steps(map, path: Array) -> bool:
	for index in range(1, path.size()):
		if not is_step_legal(map, Vector2i(path[index - 1]), Vector2i(path[index])):
			return true
	return false


## The §4.2 single-step rule, wrap-aware in `x`: 8-directional, passable
## target, and a diagonal needs **both** orthogonals passable (no corner
## cutting). Mirrors `SailingSim.is_move_legal` for a returned path walk.
static func is_step_legal(map, from: Vector2i, to: Vector2i) -> bool:
	if map == null:
		return false
	var width: int = int(map.width) if int(map.width) > 0 else 2160
	var dx := short_dx(from.x, to.x, width)
	var dy := to.y - from.y
	if (dx == 0 and dy == 0) or absi(dx) > 1 or absi(dy) > 1:
		return false
	if not map.is_passable(to):
		return false
	if dx != 0 and dy != 0:
		if not map.is_passable_xy(from.x + dx, from.y):
			return false
		if not map.is_passable_xy(from.x, from.y + dy):
			return false
	return true


static func _elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0
