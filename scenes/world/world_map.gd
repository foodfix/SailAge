extends Node2D
## World map scene (S3) — docs/80-UI-UX.md §4.1, docs/90-ARCHITECTURE.md §9.
##
## T5 scope: render the ASCII map through MapLoader, hand the loader to
## DataLoader, and park a clamped Camera2D (behaviour `80-*` §4.5). T6 adds the
## fleet marker and movement input; this script therefore only reads
## `GameState.world.position` when it already exists and falls back to Lisbon's
## tile.
##
## The map is never re-parsed here: the scene asks MapLoader once and lets it
## build the TileMap (docs/90-* §9 step 6).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const PaletteLib := preload("res://scripts/palette.gd")

## Phase-1 map file (docs/10-* §6.1). Swapping maps is a path change only.
const MAP_PATH := "res://data/maps/p1_mediterranean.txt"
## Overridable copy of [constant MAP_PATH]: a different legend-conformant map
## file is a data-only swap (docs/90-* §9 last paragraph), so the path is an
## inspector property rather than a hard-coded read.
@export var map_path: String = MAP_PATH
## Fallback camera target before a game exists (Lisbon's harbor tile).
const FALLBACK_CELL := Vector2i(7, 57)

@onready var _camera: Camera2D = $Camera2D
@onready var _error_layer: CanvasLayer = $Overlay
@onready var _error_label: Label = $Overlay/ErrorLabel

var _loader = null
var _map_pixels := Vector2.ZERO
var _cell_pixels := 32


func _ready() -> void:
	_loader = MapLoaderLib.new()
	var loaded: bool = _loader.load_map(map_path, DataLoader.map_legend)
	# Handoff for DataLoader.is_passable()/port_id_at() (docs/90-* §5.2, §9).
	DataLoader.map = _loader if loaded else null

	if not loaded:
		_show_error(_loader.last_error)
		return

	_map_pixels = Vector2(_loader.width * _loader.tile_size_px, _loader.height * _loader.tile_size_px)
	_cell_pixels = _loader.tile_size_px
	_loader.build_tilemap(self, DataLoader.ports, DataLoader.nations)
	_error_layer.visible = false

	_camera.zoom = Vector2.ONE
	_camera.make_current()
	_update_camera()


func _process(_delta: float) -> void:
	if _loader == null or not _is_loaded():
		return
	_update_camera()


## Centers the camera on the fleet tile (`20-*` §4.1) and clamps the view to
## the map so no void past the 128×96 grid is ever shown (`80-*` §4.5).
func _update_camera() -> void:
	_camera.position = _clamp_to_map(_camera_target())


func _camera_target() -> Vector2:
	var cell := FALLBACK_CELL
	var position = GameState.world.get("position", null)
	if position is Vector2:
		cell = Vector2i(position)
	elif position is Dictionary:
		var x = position.get("x", null)
		var y = position.get("y", null)
		if (x is int or x is float) and (y is int or y is float):
			cell = Vector2i(int(x), int(y))
	# Cell coordinates name a tile; the camera aims at that tile's center.
	return Vector2(cell.x * _cell_pixels, cell.y * _cell_pixels) + Vector2(_cell_pixels, _cell_pixels) * 0.5


## Clamps a world-space camera center so the 1280×720 view stays inside the map.
## Public so the T6 camera test can call it without a running scene.
func _clamp_to_map(target: Vector2) -> Vector2:
	var half_view := get_viewport_rect().size * 0.5 / _camera.zoom
	var out := target
	if _map_pixels.x <= half_view.x * 2.0:
		out.x = _map_pixels.x * 0.5
	else:
		out.x = clampf(target.x, half_view.x, _map_pixels.x - half_view.x)
	if _map_pixels.y <= half_view.y * 2.0:
		out.y = _map_pixels.y * 0.5
	else:
		out.y = clampf(target.y, half_view.y, _map_pixels.y - half_view.y)
	return out


func _is_loaded() -> bool:
	return _loader != null and not _map_pixels.is_zero_approx()


## Data error path (docs/90-* §11): print the reason and show it centered
## instead of crashing; the rest of the app stays usable.
func _show_error(reason: String) -> void:
	var detail := reason
	if detail.is_empty():
		detail = " / ".join(DataLoader.load_errors)
	if detail.is_empty():
		detail = map_path
	push_error("WorldMap: cannot load the world map: " + detail)
	var text := "Data error: %s" % detail
	# Autoloads are lookup-by-name so this also survives a partial autoload set
	# (the same defensive pattern I18n uses for GameState).
	var i18n := get_node_or_null("/root/I18n")
	if i18n != null and i18n.has_method("fmt"):
		text = i18n.fmt("title.data_error", {"reason": detail})
	_error_label.text = text
	_error_label.add_theme_color_override("font_color", PaletteLib.BAD)
	_error_layer.visible = true
