extends Control
## Chart screen (S17) — docs/80-UI-UX.md §4.6 (normative wireframe), §4.2
## ("S3 ──Tab──► S17 ──Esc/Tab──► S3"), §4.3 (input rows), §4.7.5 (`chart.*`
## keys), §4.8 (palette); docs/20-WORLD-AND-SAILING.md §4.12.
##
## A **full-screen panel over S3** that shows the whole world at once: the
## 2160×1080 grid downscaled to fit (≈0.57× at 1280×720 — no scrolling, no
## per-region tabs, and no seam crop, because a full-world image is inherently
## wrap-free).
##
## ```
## +---------------------------------------------------------------+
## | 海图 / Chart                                        [关闭海图] | top 40px
## +---------------------------------------------------------------+
## |  whole world downscaled to fit                                |
## |   explored tiles: SEA/COAST_SEA(/LAND/REEF/ICE) at full colour |
## |   unknown tiles: PANEL_BG                                     |
## |   known ports: 3px nation dots (+ names when the chart is big) |
## |   discovery leads: ACCENT crosses                             |
## |   fleet: white 5px square with black outline                  |
## +---------------------------------------------------------------+
## | 已探索海域 · 已知港口 · 船队 · 发现物线索            (legend)  | bottom 32px
## +---------------------------------------------------------------+
## ```
##
## **It never mutates state.** Every read goes through `GameState` /
## `DataLoader` / [ChartView]; closing returns to S3 with the fleet unmoved and
## the clock untouched. The explored overlay, the known-port set and the
## discovery markers come from [ChartView], the *same* functions the HUD
## minimap uses, so the two views cannot disagree (the §J acceptance).
##
## **Open budget < 0.5 s** (`80-*` §4.6): the downscaled world image is built
## **once** in [method open_chart] and drawn as one `ImageTexture` per frame —
## [_draw] never walks the 2.33 M tiles again. [method last_open_ms] reports the
## measured build time (the test asserts the budget).
##
## **Input:** `Tab` toggles, `Esc` closes; while open the panel owns every event
## (it joins `modal_overlay`, so the host's `_modal_open()` blocks movement and
## nothing underneath reacts). A modal already on screen blocks `Tab` (§6).
##
## Hosting: instance `chart_screen.tscn` anywhere above S3 (`world_map.tscn`
## adds it as the last child of `HUDLayer`). It needs no wiring — it reads the
## session itself — and [method attach_to] is the escape hatch for a host that
## builds its UI in code.
##
## `Palette` and [ChartView] are preloaded rather than referenced through their
## global class names so this script also runs before Godot has written its
## class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")

const SCENE_PATH := "res://scenes/world/chart_screen.tscn"
## Group every open modal joins (docs/90-* §11): the world scene's
## `_modal_open()` already treats a visible member as "movement is blocked", so
## the Chart needs no host-side edit for that rule.
const MODAL_GROUP := "modal_overlay"

## §4.6 geometry: top bar 40px, legend bar 32px, 16px margins (§4.8 grid).
const TOP_BAR_H := PaletteLib.TOP_BAR_H
const BOTTOM_BAR_H := PaletteLib.BOTTOM_BAR_H
const MARGIN := PaletteLib.MARGIN

## `80-*` §4.6: "explored tiles: SEA/COAST_SEA **at low alpha**". The alpha is a
## *presentation* blend applied when the texture is drawn, never baked into the
## grid-resolution image — so [method world_pixel_color] (and the identity check
## against the minimap) still reads the plain palette colour both views share.
const EXPLORED_ALPHA := 0.6

## §4.6 markers.
const PORT_DOT_PX := 3.0
const FLEET_SQUARE_PX := 5.0
const FLEET_OUTLINE_PX := 1.0
const LEAD_CROSS_PX := 5.0

## §4.6 "known ports … (+ names at zoom)". Task-owned threshold: the names are
## drawn when the whole world is rendered at least this many screen pixels wide
## (0.75 × 2160 = 1620 px), i.e. on any window wider than ~1660 px. At
## 1280×720 (scale ≈ 0.57) the dots alone carry the information, which is what
## the wireframe shows.
const NAMES_MIN_SCALE := 0.75

## `chart.*` keys (docs/80-* §4.7.5 — the only inventory this screen may use).
const KEY_TITLE := "chart.title"
const KEY_CLOSE := "chart.close"
const KEY_HINT := "chart.hint"
const KEY_LEGEND_PORT := "chart.legend.port"
const KEY_LEGEND_FLEET := "chart.legend.fleet"
const KEY_LEGEND_DISCOVERY := "chart.legend.discovery"

@onready var _background: ColorRect = $Background
@onready var _top_bar: ColorRect = $TopBar
@onready var _title: Label = $TopBar/Title
@onready var _close: Button = $TopBar/Close
@onready var _bottom_bar: ColorRect = $BottomBar
@onready var _legend_note: Label = $BottomBar/Legend/Explored
@onready var _legend_port: Label = $BottomBar/Legend/Ports
@onready var _legend_fleet: Label = $BottomBar/Legend/Fleet
@onready var _legend_discovery: Label = $BottomBar/Legend/Discoveries

## The whole-world image at grid resolution (2160×1080, one pixel per tile).
## Kept so [method world_pixel_color] can answer "what does the chart show for
## this tile?" exactly, without rounding through the downscale.
var _world_image: Image = null
## The downscaled texture actually drawn (built once per open).
var _texture: ImageTexture = null
## `Rect2` the world image occupies on screen (centred between the bars).
var _world_rect := Rect2()
## Screen pixels per world tile.
var _scale := 0.0
## Measured build time of the last [method open_chart], in milliseconds.
var _open_ms := 0.0
## Fleet cell the last build used (`(-1,-1)` before any build).
var _fleet_cell := Vector2i(-1, -1)
## The shared port/discovery/marker layers the last build drew.
var _port_dots: Array = []
var _lead_cells: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_background.color = PaletteLib.PANEL_BG
	_top_bar.color = PaletteLib.PANEL_BG
	_bottom_bar.color = PaletteLib.PANEL_BG
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 24)
	_close.custom_minimum_size = Vector2(240, PaletteLib.BUTTON_H)
	_close.pressed.connect(close_chart)
	for label in _legend_labels():
		label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	visible = false
	# Bars follow the viewport (a window resize moves/rescales the world image).
	resized.connect(_relayout)
	EventBus.locale_changed.connect(_on_locale_changed)
	_bind_labels()
	_relayout()


# --- Hosting ---------------------------------------------------------------

## Escape hatch for a host that builds its UI in code (the world scene instances
## the scene in `world_map.tscn` instead, so this is not on the production
## path). Idempotent: a second call returns the existing child.
static func attach_to(parent: Node) -> Control:
	if parent == null:
		return null
	var existing := parent.get_node_or_null("ChartScreen")
	if existing != null:
		return existing
	if not ResourceLoader.exists(SCENE_PATH):
		push_error("ChartScreen.attach_to: missing %s" % SCENE_PATH)
		return null
	var chart: Control = load(SCENE_PATH).instantiate()
	chart.name = "ChartScreen"
	parent.add_child(chart)
	return chart


# --- Public API ------------------------------------------------------------

## `true` while the chart is on screen.
func is_open() -> bool:
	return visible


## Opens the chart: rebuilds the world image once, measures the time, and takes
## over input (`80-*` §4.6 "build + first frame < 0.5 s"). Idempotent.
func open_chart() -> void:
	if visible:
		return
	var started := Time.get_ticks_usec()
	_rebuild()
	visible = true
	add_to_group(MODAL_GROUP)
	_open_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_close.grab_focus()
	queue_redraw()


## Closes the chart. **Mutates nothing**: the fleet tile and `clock_fraction` are
## whatever S3 left there (§4.6 "returns to S3 with the fleet unmoved").
func close_chart() -> void:
	if not visible:
		return
	visible = false
	remove_from_group(MODAL_GROUP)
	queue_redraw()


func toggle_chart() -> void:
	if visible:
		close_chart()
	else:
		open_chart()


## Build time of the last open, in milliseconds (the < 0.5 s budget hook).
func last_open_ms() -> float:
	return _open_ms


## Screen pixels per world tile in the last build (≈0.57 at 1280×720).
func chart_scale() -> float:
	return _scale


## Screen rect the whole world occupies (inside the bars and margins).
func world_rect() -> Rect2:
	return _world_rect


## Size of the grid-resolution image the chart built (the full 2160×1080 grid).
func world_image_size() -> Vector2i:
	return _world_image.get_size() if _world_image != null else Vector2i.ZERO


## Size of the texture actually drawn (the downscaled world).
func display_size() -> Vector2i:
	return _texture.get_size() if _texture != null else Vector2i.ZERO


## The colour the chart shows for `cell`: the explored terrain colour, or
## `PANEL_BG` for an unexplored tile (`80-*` §4.6 layers). Read from the
## grid-resolution image, so this is exactly comparable with the minimap's
## [method Hud.minimap_pixel_color] — that equality is the §J acceptance.
func world_pixel_color(cell: Vector2i) -> Color:
	if _world_image == null:
		return ChartViewLib.UNKNOWN_COLOR
	var map = DataLoader.map
	if map == null:
		return ChartViewLib.UNKNOWN_COLOR
	var x := posmod(cell.x, int(map.width))
	if cell.y < 0 or cell.y >= int(map.height):
		return ChartViewLib.UNKNOWN_COLOR
	return _world_image.get_pixel(x, cell.y)


## The known-port markers the chart draws: `[{port_id, cell, color, name}]` —
## the shared [ChartView] layer, so the minimap and the chart agree.
func port_markers() -> Array:
	return _port_dots.duplicate()


## The discovery leads the chart draws: `[{id, cell}]` (found + explored only).
func lead_markers() -> Array:
	return _lead_cells.duplicate()


## Fleet cell the last build centred on.
func fleet_cell() -> Vector2i:
	return _fleet_cell


## Every visible string, for the "zero `<key>` fallbacks" check.
func legend_texts() -> Array:
	return [_title.text, _close.text, _legend_note.text,
		_legend_port.text, _legend_fleet.text, _legend_discovery.text]


## `true` when the chart is rendered wide enough for port names (§4.6 "at
## zoom"). Static so the rule is testable without a 2560px window.
static func names_shown(scale: float) -> bool:
	return scale >= NAMES_MIN_SCALE


## `true` when the port names are on screen right now.
func labels_visible() -> bool:
	return names_shown(_scale)


# --- Input (`80-*` §4.3) ---------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		# `Tab` opens the chart from S3 — unless a modal already owns the
		# screen (`80-*` §6: "Tab does nothing while any modal is up").
		if _wants_toggle(event):
			if _other_modal_open():
				return
			get_viewport().set_input_as_handled()
			open_chart()
		return
	# Open: the panel owns all input (§4.6). `Tab` toggles back, `Esc` closes.
	if _wants_toggle(event) or event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close_chart()
		return
	# Swallow everything else so movement/hotkeys underneath never react.
	if event is InputEventKey or event is InputEventMouseButton \
			or event is InputEventMouseMotion or event is InputEventJoypadButton:
		get_viewport().set_input_as_handled()


## `true` for the `Tab` edge. `project.godot` binds no `toggle_chart` action in
## Phase 4 (`input/` belongs to the movement task), so the chart recognises the
## physical key itself — the same style S10 uses for its `Tab` — and honours a
## `toggle_chart` action if one is ever bound (`InputMap.has_action` first, so an
## unbound name never logs an engine error).
static func _wants_toggle(event: InputEvent) -> bool:
	if _is_tab(event):
		return true
	return InputMap.has_action("toggle_chart") and event.is_action_pressed("toggle_chart")


## `Tab` as a raw key event.
static func _is_tab(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key := event as InputEventKey
	return key.pressed and not key.echo \
		and (key.physical_keycode == KEY_TAB or key.keycode == KEY_TAB)


## True while some *other* modal is on screen (a HUD dialog, S14, S15…).
func _other_modal_open() -> bool:
	for node in get_tree().get_nodes_in_group(MODAL_GROUP):
		if node == self or not (node is CanvasItem):
			continue
		if (node as CanvasItem).is_visible_in_tree():
			return true
	# Controls that follow the same contract without joining the group (S14).
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling == self or not (sibling is CanvasItem):
				continue
			if sibling.has_method("is_open") and sibling.is_open():
				return true
	return false


# --- Build (docs/80-* §4.6 layers) -----------------------------------------

## Lays out the world rect. Cheap (no image work) so a resize is not a rebuild;
## the texture is stretched to the new rect by [_draw]. The two bars are
## anchor-driven in the scene file, so only the world rect is computed here.
func _relayout() -> void:
	var view := get_viewport_rect().size
	# World area: between the bars, inset by the §4.8 16px margin.
	var avail := Vector2(
		maxf(view.x - MARGIN * 2.0, 1.0),
		maxf(view.y - TOP_BAR_H - BOTTOM_BAR_H - MARGIN * 2.0, 1.0)
	)
	var map = DataLoader.map
	var grid := Vector2(2160, 1080)
	if map != null and int(map.width) > 0:
		grid = Vector2(int(map.width), int(map.height))
	_scale = minf(avail.x / grid.x, avail.y / grid.y)
	var size := grid * _scale
	_world_rect = Rect2(
		Vector2(
			(view.x - size.x) * 0.5,
			TOP_BAR_H + (view.y - TOP_BAR_H - BOTTOM_BAR_H - size.y) * 0.5
		),
		size
	)
	queue_redraw()


## Builds the whole-world image (and its downscaled texture) once. This is the
## only function that walks the grid; [_draw] uses the result.
func _rebuild() -> void:
	var map = DataLoader.map
	_world_image = null
	_texture = null
	_port_dots = []
	_lead_cells = []
	_fleet_cell = _fleet_source_cell()
	if map == null or int(map.width) <= 0 or int(map.height) <= 0:
		return
	_relayout()
	var width := int(map.width)
	var height := int(map.height)
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	# Layer 1: unknown tiles are `PANEL_BG` (§4.6) — a fresh run with zero
	# explored tiles paints exactly this and nothing else (§6 edge case).
	image.fill(ChartViewLib.UNKNOWN_COLOR)
	# Layer 2: the explored overlay, painted from the session explored set only
	# (never the whole terrain — that would leak the undiscovered world).
	var colors: Array = ChartViewLib.palette_colors(map)
	for raw_cell in GameState.explored_tiles:
		if not (raw_cell is Vector2i):
			continue
		var cell: Vector2i = raw_cell
		if cell.x < 0 or cell.y < 0 or cell.x >= width or cell.y >= height:
			continue
		image.set_pixel(cell.x, cell.y, ChartViewLib.index_color(colors, map, cell.x, cell.y))
	_world_image = image
	# Layers 3–5 are vector overlays drawn at screen scale by [_draw], so a dot
	# stays 3px and the fleet square 5px at every window size.
	_port_dots = ChartViewLib.port_dots(map)
	_lead_cells = ChartViewLib.lead_cells(map)
	_texture = _downscaled_texture(image)


## Nearest-neighbour downscale to the on-screen world rect (crisp tiles: the
## same look the minimap has, `80-*` §4.6 "downscaled to fit").
func _downscaled_texture(image: Image) -> ImageTexture:
	var target := Vector2i(
		maxi(int(round(_world_rect.size.x)), 1), maxi(int(round(_world_rect.size.y)), 1)
	)
	var scaled := image.duplicate()
	scaled.resize(target.x, target.y, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(scaled)


# --- Drawing (docs/80-* §4.6 layers, bottom to top) -----------------------

func _draw() -> void:
	if not visible:
		return
	var view := get_viewport_rect().size
	# Layer 0: the canvas background (§4.6).
	draw_rect(Rect2(Vector2.ZERO, view), PaletteLib.PANEL_BG, true)
	if _texture != null:
		# Layer 1/2: explored tiles over the unknown background, at the §4.6
		# "low alpha" (the texture carries the plain palette colours, so the
		# identity read-back stays exact — see [constant EXPLORED_ALPHA]).
		draw_texture_rect(_texture, _world_rect, false,
			Color(1, 1, 1, EXPLORED_ALPHA))
	draw_rect(_world_rect, PaletteLib.PANEL_LINE, false, 2.0)

	# Layer 3: known ports as nation-coloured dots (+ names at zoom).
	var show_names := names_shown(_scale)
	for entry in _port_dots:
		var at := _to_screen(entry["cell"])
		draw_rect(Rect2(
			at - Vector2(PORT_DOT_PX, PORT_DOT_PX) * 0.5,
			Vector2(PORT_DOT_PX, PORT_DOT_PX)
		), entry["color"], true)
		if show_names and not str(entry.get("name", "")).is_empty():
			draw_string(
				ThemeDB.fallback_font, at + Vector2(PORT_DOT_PX, -PORT_DOT_PX),
				str(entry["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, PaletteLib.TEXT
			)

	# Layer 4: discovery leads as `ACCENT` crosses.
	for entry in _lead_cells:
		var at := _to_screen(entry["cell"])
		var half := LEAD_CROSS_PX * 0.5
		draw_line(at - Vector2(half, 0), at + Vector2(half, 0), PaletteLib.ACCENT, 1.0)
		draw_line(at - Vector2(0, half), at + Vector2(0, half), PaletteLib.ACCENT, 1.0)

	# Layer 5: the fleet — a white 5px square with a black 1px outline (§4.6).
	if _fleet_cell.x >= 0:
		var at := _to_screen(_fleet_cell)
		var outline := FLEET_SQUARE_PX + FLEET_OUTLINE_PX * 2.0
		draw_rect(Rect2(at - Vector2(outline, outline) * 0.5,
			Vector2(outline, outline)), Color.BLACK, true)
		draw_rect(Rect2(at - Vector2(FLEET_SQUARE_PX, FLEET_SQUARE_PX) * 0.5,
			Vector2(FLEET_SQUARE_PX, FLEET_SQUARE_PX)), Color.WHITE, true)


## Screen position (centre of the tile) for a world cell.
func _to_screen(cell: Vector2i) -> Vector2:
	return _world_rect.position + (Vector2(cell) + Vector2(0.5, 0.5)) * _scale


## The fleet position the chart shows: the HUD's cell when the host has one
## (it carries the pre-run fallback), else the session's. **Read-only.**
func _fleet_source_cell() -> Vector2i:
	var hud := get_parent().get_node_or_null("HUD") if get_parent() != null else null
	if hud != null and hud.get("fleet_cell") is Vector2i:
		var cell: Vector2i = hud.get("fleet_cell")
		if cell.x >= 0:
			return cell
	if not GameState.world.is_empty():
		return GameState.world_tile()
	return Vector2i(-1, -1)


# --- Strings (docs/80-* §4.7.5) -------------------------------------------

func _legend_labels() -> Array:
	return [_legend_note, _legend_port, _legend_fleet, _legend_discovery]


func _bind_labels() -> void:
	_title.text = I18n.t_key(KEY_TITLE)
	_close.text = I18n.t_key(KEY_CLOSE)
	_legend_note.text = I18n.t_key(KEY_HINT)
	_legend_port.text = "· " + I18n.t_key(KEY_LEGEND_PORT)
	_legend_fleet.text = "· " + I18n.t_key(KEY_LEGEND_FLEET)
	_legend_discovery.text = "· " + I18n.t_key(KEY_LEGEND_DISCOVERY)


func _on_locale_changed(_locale: String) -> void:
	_bind_labels()
