extends Control
## S10 battle overlay (docs/80-UI-UX.md §4.7.1 Phase-9 rewrite; §4.8 pins).
##
## Drawn over the camera-transformed world view, for the ACTING PLAYER UNIT:
##   * the reachable-set velocity vectors — one line per
##     `BattleSim.legal_velocities()` entry (§4.3a), endpoints pickable
##     (§4.3 "click a legal vector");
##   * the two broadside arc fans — wedge outlines for the port steps
##     {45°, 90°, 135°} and the starboard steps {225°, 270°, 315°} relative
##     to the acting unit's `heading8`, range 3 (§4.4);
##   * the target side indicators — a marker on the arc side that can fire
##     at each enemy in cannon range;
##   * the hook-highlight rings on enemies satisfying the §4.6a hook
##     condition (`battle.ring.hook`).
##
## Everything is camera-transformed through the screen's own pure camera
## functions (the single camera-math source, §4.7.1). Placeholder primitives
## only — `_draw` lines/arcs/rects, no textures (§4.8). Every node here is
## mouse-transparent: clicks reach the screen's hit-testing, which asks this
## overlay which velocity a click picked ([method pick_velocity]).

const PaletteLib := preload("res://scripts/palette.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
## The camera math lives on the screen script (§4.7.1); no cycle — the screen
## never preloads this file (the .tscn wires the node).
const ScreenLib := preload("res://scenes/combat/battle_screen.gd")

## 64 px per tile (§4.2 as amended 2026-11-08 — mirrors the screen
## constant; the tokens render 1:1 64 on 64px tiles).
const TILE_PX := 64.0
## A click within this distance of a vector's endpoint picks it.
const ENDPOINT_PICK_RADIUS := 12.0
## A click within this distance of the vector's line picks it too.
const SEGMENT_PICK_RADIUS := 8.0
## The arc fans are drawn at the §4.4 cannon range: 3 cells.
const ARC_RANGE_CELLS := 3
## The hook-highlight ring radius (§4.8 pin: GOOD).
const HOOK_RING_RADIUS := 18.0
## The side-fire marker sits 2 cells out along the target's bearing.
const SIDE_MARK_DISTANCE_PX := 64.0

var _cam := Vector2.ZERO
var _zoom := 1.0
var _has_actor := false
## The acting unit's world-pixel position (cell top-left × TILE_PX).
var _origin := Vector2.ZERO
var _heading8 := 0
var _vectors: Array[Vector2i] = []
## The keyboard-cycled velocity (NO_CELL = none highlighted).
var _selected := BattleSimLib.NO_CELL
## `{cell: Vector2i, side: String}` — enemies a named side can fire at.
var _side_marks: Array = []
## Enemies satisfying the §4.6a hook condition (cells).
var _hook_cells: Array[Vector2i] = []
var _cursor := BattleSimLib.NO_CELL
var _cursor_visible := false


## The camera state the world view draws with (set every repaint by the
## screen; both values already clamped by the screen's own camera math).
func set_camera(cam: Vector2, zoom: float) -> void:
	_cam = cam
	_zoom = zoom
	queue_redraw()


## Replaces the whole overlay state and repaints. `origin` is the acting
## unit's world-pixel position, `vectors` its `legal_velocities()` array in
## (y, x) enumeration order, `selected` the keyboard-cycled entry (or
## NO_CELL), `side_marks` the `{cell, side}` fireable-enemy markers,
## `hook_cells` the §4.6a-hookable enemies, `cursor` the keyboard cursor.
func set_state(origin: Vector2, heading8: int, vectors: Array,
		selected: Vector2i, side_marks: Array, hook_cells: Array,
		cursor: Vector2i, cursor_visible: bool) -> void:
	_has_actor = true
	_origin = origin
	_heading8 = heading8
	_vectors.clear()
	for vel in vectors:
		if vel is Vector2i:
			_vectors.append(vel)
	_selected = selected
	_side_marks = (side_marks as Array).duplicate()
	_hook_cells.clear()
	for cell in hook_cells:
		if cell is Vector2i:
			_hook_cells.append(cell)
	_cursor = cursor
	_cursor_visible = cursor_visible
	queue_redraw()


## Clears the acting-unit layer (AI turns / battle over); the cursor persists.
func clear_actor() -> void:
	_has_actor = false
	_vectors.clear()
	_selected = BattleSimLib.NO_CELL
	_side_marks = []
	_hook_cells.clear()
	queue_redraw()


## The velocity whose endpoint (within ENDPOINT_PICK_RADIUS), line (within
## SEGMENT_PICK_RADIUS) or landing CELL covers `world_pos` — checked in
## enumeration order so the pick is the deterministic §4.11.8 tie-break. The
## cell pass is what makes "click a vector's endpoint" forgiving: the drawn
## endpoint sits on the landing cell's corner, so a click anywhere in that
## 32 px cell picks the vector. NO_CELL when none.
func pick_velocity(world_pos: Vector2) -> Vector2i:
	for vel in _vectors:
		var endpoint := _origin + Vector2(vel) * TILE_PX
		if world_pos.distance_to(endpoint) <= ENDPOINT_PICK_RADIUS:
			return vel
	for vel in _vectors:
		if vel == Vector2i.ZERO:
			continue
		if _segment_distance(world_pos, _origin,
				_origin + Vector2(vel) * TILE_PX) <= SEGMENT_PICK_RADIUS:
			return vel
	for vel in _vectors:
		var cell := Vector2i(int(floor((_origin.x + float(vel.x) * TILE_PX)
			/ TILE_PX)), int(floor((_origin.y + float(vel.y) * TILE_PX) / TILE_PX)))
		if Rect2(Vector2(cell) * TILE_PX, Vector2(TILE_PX, TILE_PX)).has_point(world_pos):
			return vel
	return BattleSimLib.NO_CELL


## The endpoint cells of the drawn vectors (`pos + vel`, enumeration order).
func velocity_cells() -> Array[Vector2i]:
	var cell := Vector2i(int(floor(_origin.x / TILE_PX)),
		int(floor(_origin.y / TILE_PX)))
	var out: Array[Vector2i] = []
	for vel in _vectors:
		out.append(cell + vel)
	return out


## The keyboard-cycled velocity (NO_CELL = none).
func selected_velocity() -> Vector2i:
	return _selected


func _draw() -> void:
	# Broadside arc fans (§4.4): the two 3-bucket wedges at range 3.
	if _has_actor:
		for step in BattleSimLib.ARC_PORT_STEPS:
			_draw_wedge(step, PaletteLib.PANEL_LINE)
		for step in BattleSimLib.ARC_STARBOARD_STEPS:
			_draw_wedge(step, PaletteLib.PANEL_LINE)
	# Target side indicators (§4.8: BAD marker on the firing arc side).
	for mark in _side_marks:
		if not (mark is Dictionary):
			continue
		var cell := BattleSimLib.to_cell((mark as Dictionary).get("cell", BattleSimLib.NO_CELL))
		if not BattleSimLib.in_grid(cell):
			continue
		var actor_cell := Vector2i(int(floor(_origin.x / TILE_PX)),
			int(floor(_origin.y / TILE_PX)))
		var bearing := BattleSimLib.heading8_of(cell - actor_cell)
		var ray := Vector2(BattleSimLib.HEADING_RAYS[posmod(bearing, 8)])
		var pos := _to_screen(_origin + ray * SIDE_MARK_DISTANCE_PX)
		_draw_diamond(pos, 6.0, PaletteLib.BAD)
	# Hook-highlight rings (§4.6a / §4.8 GOOD pin, `battle.ring.hook`).
	for cell in _hook_cells:
		var center := _to_screen(Vector2(cell) * TILE_PX
			+ Vector2(TILE_PX, TILE_PX) * 0.5)
		draw_arc(center, HOOK_RING_RADIUS, 0.0, TAU, 32, PaletteLib.GOOD, 2.0)
	# Reachable velocity vectors (§4.3a endpoints; §4.3 "click a legal vector").
	if _has_actor:
		for vel in _vectors:
			var selected: bool = vel == _selected
			var from := _to_screen(_origin)
			var to := _to_screen(_origin + Vector2(vel) * TILE_PX)
			if vel != Vector2i.ZERO:
				draw_line(from, to, PaletteLib.ACCENT, 3.0 if selected else 2.0)
			var endpoint := _to_screen(_origin + Vector2(vel) * TILE_PX)
			draw_circle(endpoint, 5.0 if selected else 3.0, PaletteLib.ACCENT)
	# Keyboard cursor (§4.8 "focus outline 2px accent").
	if _cursor_visible and BattleSimLib.in_grid(_cursor):
		var rect := Rect2(_to_screen(Vector2(_cursor) * TILE_PX),
			Vector2(TILE_PX, TILE_PX) * _zoom)
		draw_rect(rect, PaletteLib.ACCENT, false, 2.0)


## One broadside wedge outline: the bucket `heading8 + step`'s ±22.5° fan at
## ARC_RANGE_CELLS. Screen-space direction of bucket b sits at standard angle
## −b·45° (HEADING_RAYS increase counterclockwise on screen, i.e. the
## standard rotation is negative), so the edges are ∓22.5° around that.
func _draw_wedge(step: int, color: Color) -> void:
	var bucket := posmod(_heading8 + step, 8)
	var center_angle := -float(bucket) * PI / 4.0
	var spread := PI / 8.0
	var radius := ARC_RANGE_CELLS * TILE_PX * _zoom
	var origin := _to_screen(_origin)
	var a0 := center_angle - spread
	var a1 := center_angle + spread
	draw_line(origin, origin + Vector2(cos(a0), sin(a0)) * radius, color, 1.0)
	draw_line(origin, origin + Vector2(cos(a1), sin(a1)) * radius, color, 1.0)
	draw_arc(origin, radius, a0, a1, 10, color, 1.0)


func _draw_diamond(center: Vector2, radius: float, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -radius), center + Vector2(radius, 0),
		center + Vector2(0, radius), center + Vector2(-radius, 0),
		center + Vector2(0, -radius),
	])
	draw_polyline(points, color, 1.5)


## World px → view-local screen px through the screen's camera functions.
func _to_screen(world_pos: Vector2) -> Vector2:
	return ScreenLib.world_to_screen(world_pos, _cam, _zoom)


## Point → segment distance (the vector-line pick).
static func _segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.0:
		return point.distance_to(a)
	var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)
