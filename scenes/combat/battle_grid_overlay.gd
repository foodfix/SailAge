extends Control
## Highlight overlay for the S10 battle grid (docs/80-UI-UX.md §4.7.1: reachable
## tiles in `ACCENT`, target tiles in `BAD`, plus a keyboard cursor outline).
##
## Kept in its own tiny script because the overlay must draw **above** the 160
## opaque `ColorRect` tiles and the ship tokens, while clicks still reach the
## screen's own hit-testing: every node here is mouse-transparent. Placeholder
## art only — `_draw` rectangles, no textures (§4.8).

const PaletteLib := preload("res://scripts/palette.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

## 48px per tile (§4.2 "rendered at 48px", §4.7.1 wireframe).
const TILE_PX := 48.0
## 3px highlight outline, 2px keyboard cursor (§4.8 "focus outline 2px accent").
const OUTLINE_W := 3.0
const CURSOR_W := 2.0
## 1px grid line between tiles so the open sea still reads as a grid.
const LINE_W := 1.0

var _reachable: Array[Vector2i] = []
var _targets: Array[Vector2i] = []
var _cursor := BattleSimLib.NO_CELL
var _cursor_visible := false


## Replaces the whole overlay state and repaints. Cells outside the grid are
## rejected by the caller (the engine only ever reports legal tiles).
func set_state(reachable: Array, targets: Array, cursor: Vector2i,
		cursor_visible: bool) -> void:
	_reachable.clear()
	for cell in reachable:
		if cell is Vector2i:
			_reachable.append(cell)
	_targets.clear()
	for cell in targets:
		if cell is Vector2i:
			_targets.append(cell)
	_cursor = cursor
	_cursor_visible = cursor_visible
	queue_redraw()


## The reachable tiles currently outlined (tests read this through the screen's
## `highlighted_cells()`).
func reachable_cells() -> Array[Vector2i]:
	return _reachable.duplicate()


func target_cells() -> Array[Vector2i]:
	return _targets.duplicate()


func _draw() -> void:
	# Grid lines first: everything else is an outline on top of them.
	var line := PaletteLib.PANEL_LINE
	for x in range(1, BattleSimLib.GRID_WIDTH):
		draw_rect(Rect2(Vector2(x * TILE_PX, 0),
			Vector2(LINE_W, TILE_PX * BattleSimLib.GRID_HEIGHT)), line, true)
	for y in range(1, BattleSimLib.GRID_HEIGHT):
		draw_rect(Rect2(Vector2(0, y * TILE_PX),
			Vector2(TILE_PX * BattleSimLib.GRID_WIDTH, LINE_W)), line, true)
	for cell in _reachable:
		_outline(cell, PaletteLib.ACCENT, OUTLINE_W)
	for cell in _targets:
		_outline(cell, PaletteLib.BAD, OUTLINE_W)
	if _cursor_visible and BattleSimLib.in_grid(_cursor):
		_outline(_cursor, PaletteLib.ACCENT, CURSOR_W)


## An unfilled tile-sized rectangle just inside the cell, so the outline never
## spills onto the neighbouring tile.
func _outline(cell: Vector2i, color: Color, width: float) -> void:
	var origin := Vector2(cell) * TILE_PX + Vector2(width * 0.5, width * 0.5)
	var size := Vector2(TILE_PX - width, TILE_PX - width)
	draw_rect(Rect2(origin, size), color, false, width)
