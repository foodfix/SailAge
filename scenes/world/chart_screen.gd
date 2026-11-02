extends Control
## Chart screen (S17) — docs/80-UI-UX.md §4.6 (normative wireframe), §4.2
## ("S3 ──Tab──► S17 ──Esc/Tab──► S3"), §4.3 (input rows), §4.7.5 (`chart.*`
## keys), §4.8 (palette); docs/20-WORLD-AND-SAILING.md §4.12.
##
## A **full-screen panel over S3** that shows the whole world at once: the
## 4320×2160 grid downscaled to fit (≈0.29× at 1280×720 — no scrolling, no
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
## |   known ports: 3px nation dots (+ names when the chart is big)|
## |   discovery leads: ACCENT crosses                             |
## |   fleet: white 5px square with black outline                  |
## |   [W] wind arrows · [C] current arrows · [I] ice tint         |
## |   [debug] omniscient map · ecology · lanes · scrubber         |
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
## [_draw] never walks the 9.3 M tiles again. [method last_open_ms] reports the
## measured build time.
##
## **Input:** `Tab` toggles, `Esc` closes; while open the panel owns every event
## (it joins `modal_overlay`, so the host's `_modal_open()` blocks movement and
## nothing underneath reacts). A modal already on screen blocks `Tab` (§6).
## Seasonal layer keys while open (`80-*` §4.3 S17 rows): `W` wind arrows,
## `C` current arrows, `I` ice tint — chart-local view state, default off.
##
## **Debug chart mode** (`80-*` §4.6 extension, `IMPLEMENT-Phase6.md` §2.12) —
## gated by the S19 调试图层 row via [method ChartView.debug_row_enabled]
## (the guard-read of C's pinned `SettingsPanel.debug_overlays` symbol). With
## the row on the chart adds, **all read-only**: `D` omniscient mode (whole
## map + every port: nation colors, `PORT_NEUTRAL` grey, capitals ringed),
## the live ecology (`NpcFleets.markers()` un-culled, wrecks, hunter-intel
## ring + cross), the lane network (17 lanes — active variant solid, spokes
## thin grey, chokepoint diamonds, lane ids in the side legend), the
## `,`/`.` month scrubber (pure view state — `GameState` untouched) and the
## side-legend role/lane names. With the
## row off none of that is reachable: `D`/`,`/`.` are ignored and no debug
## layer builds.
##
## **Redraw discipline** (`80-*` §4.6): the chart rebuilds only on open, a
## layer/month toggle, or `EventBus.day_advanced` (while open) — never per
## frame. [method build_count] exposes the counter the suite asserts on; the
## omniscient terrain image is additionally cached per instance (it is static
## map data), so a debug rebuild is overlays-only.
##
## Hosting: instance `chart_screen.tscn` anywhere above S3 (`world_map.tscn`
## adds it as the last child of `HUDLayer`). It needs no wiring — it reads the
## session itself — and [method attach_to] is the escape hatch for a host that
## builds its UI in code.
##
## `Palette`, [ChartView] and `NpcFleets` are preloaded rather than referenced
## through their global class names so this script also runs before Godot has
## written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## Task L: the lane-heat layer reads live fleet cells (flag-gated, OFF);
## the debug ecology renders `NpcFleets.markers()` (the only fleet source).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")

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
## 1280×720 (scale ≈ 0.29) the dots alone carry the information, which is what
## the wireframe shows.
const NAMES_MIN_SCALE := 0.75

## --- Phase-6 seasonal layers (`80-*` §4.6) ----------------------------------

## Seasonal layer colors (palette only): wind arrows in `TEXT` (the `WARN`/
## `ACCENT` amber is the discovery-lead color and would collide), current
## arrows in `GOOD`, ice tint in the `ICE` tile color at a fixed alpha.
const WIND_ARROW_COLOR := PaletteLib.TEXT
const WIND_VAR_COLOR := PaletteLib.WARN
const WIND_ARROW_PX := 12.0
const CURRENT_ARROW_COLOR := PaletteLib.GOOD
const ICE_TINT_ALPHA := 0.55

## --- Debug chart mode (`80-*` §4.6, IMPLEMENT-Phase6.md §2.12) --------------

## Side legend width subtracted from the world area while the debug panel is
## up (the whole world must stay visible, §4.6 "downscaled to fit").
const DEBUG_PANEL_W := 316.0
## Debug marker shapes.
const CAPITAL_RING_PX := 5.0
const WRECK_CROSS_PX := 5.0
const INTEL_RING_PX := 6.0
const INTEL_CROSS_PX := 5.0
const CHOKEPOINT_PX := 4.0
const DEBUG_FLEET_SQUARE_PX := 7.0
## Hunter-intel markers read as danger (`BAD`); chokepoint diamonds too.
const INTEL_COLOR := PaletteLib.BAD
## Inactive lane variants + spokes are the layer's dim shapes.
const INACTIVE_LANE_ALPHA := 0.35
const SPOKE_ALPHA := 0.45
## The debug side legend role rows (the §4.5.2 locked marker set + pirate).
const LEGEND_ROLES: Array[String] = ["trader", "coaster", "courier", "patrol",
	"privateer", "pirate", "hunter", "treasure"]

## `chart.*` keys (docs/80-* §4.7.5 — the only inventory this screen may use).
const KEY_TITLE := "chart.title"
const KEY_CLOSE := "chart.close"
const KEY_HINT := "chart.hint"
const KEY_LEGEND_PORT := "chart.legend.port"
const KEY_LEGEND_FLEET := "chart.legend.fleet"
const KEY_LEGEND_DISCOVERY := "chart.legend.discovery"
## Phase-6 keys (docs/80-* §4.7.10, orchestrator-merged — until then every
## label renders its literal key; the tests never assert label text).
const KEY_WIND := "chart.wind.title"
const KEY_CURRENT := "chart.current.title"
const KEY_ICE := "chart.ice.title"
const KEY_DEBUG_TITLE := "debug.title"
const KEY_DEBUG_OMNI := "debug.omniscient"
const KEY_LEGEND_NETWORK := "debug.legend.network"
const KEY_LEGEND_SPOKES := "debug.legend.spokes"
const KEY_LEGEND_CHOKEPOINTS := "debug.legend.chokepoints"
const KEY_LEGEND_FLEETS := "debug.legend.fleets"
const KEY_LEGEND_WRECKS := "debug.legend.wrecks"
const KEY_LEGEND_STALLS := "debug.legend.stalls"
const KEY_LEGEND_INTEL := "debug.legend.hunter_intel"
const KEY_LEGEND_NEUTRAL := "chart.debug.neutral"
## Task L (docs/80-* §4.6 "Lane heat dots"): the optional cosmetic layer —
## small `ACCENT` dots along the built lanes, denser where fleet traffic is
## higher. **Default OFF** per the doc flag; flipping this to true is the
## whole switch (the layer draws live fleets standing on lane tiles).
const LANE_HEAT := false
## Lane-heat dot size (px, screen space).
const LANE_HEAT_DOT_PX := 2.0

## --- Mouse view (§4.6, amended 2026-11-01) ----------------------------------

## Wheel-zoom bounds (× the fit view) and the per-notch multiplicative step.
const ZOOM_MIN := 1.0
## Unified-movement amendment (2026-11-01): 8 → 64 — fleet-level inspection
## (the stall diagnostics read per-fleet state, which needs per-tile zoom;
## the terrain texture is native-resolution, so deep zoom stays crisp).
const ZOOM_MAX := 64.0
const ZOOM_STEP := 1.25
## A hidden legend row dims to this alpha (§4.6 interactive legend rows).
const HIDDEN_ROW_ALPHA := 0.35

@onready var _top_bar: ColorRect = $TopBar
@onready var _title: Label = $TopBar/Title
@onready var _close: Button = $TopBar/Close
@onready var _bottom_bar: ColorRect = $BottomBar
@onready var _legend_note: Label = $BottomBar/Legend/Explored
@onready var _legend_port: Label = $BottomBar/Legend/Ports
@onready var _legend_fleet: Label = $BottomBar/Legend/Fleet
@onready var _legend_discovery: Label = $BottomBar/Legend/Discoveries
@onready var _legend_wind: Label = $BottomBar/Legend/Wind
@onready var _legend_current: Label = $BottomBar/Legend/Current
@onready var _legend_ice: Label = $BottomBar/Legend/Ice
@onready var _debug_panel: PanelContainer = $DebugPanel
@onready var _debug_rows: VBoxContainer = $DebugPanel/Scroll/Rows

## The whole-world image at grid resolution (4320×2160, one pixel per tile).
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

# --- Seasonal layer view state (chart-local, never persisted) ----------------

var _wind_on := false
var _current_on := false
var _ice_on := false

# --- Debug chart mode view state (chart-local, never persisted) --------------

## `D` — omniscient base map. Reachable only while the S19 row is on.
var _omni_on := false
## `,`/`.` scrubber preview: 0 = live month, else the previewed month 1..12.
## Reset on close; never written to any `GameState` field.
var _preview_month := 0
## True when the last build ran with the S19 row on (the debug layers state).
var _debug_active := false
## Read-only hover tooltip text ("" when nothing is under the cursor).
var _hover_text := ""
## Mouse view (§4.6, amended 2026-11-01): `_zoom` 1.0 = the fit view; `_pan`
## is the view-rect top-left offset from the fit rect (screen px). Reset on
## open, clamped to the map; event-driven redraws, never persisted.
var _zoom := ZOOM_MIN
var _pan := Vector2.ZERO
var _dragging := false
## Interactive legend rows (§4.6, amended 2026-11-01): row id → hidden.
## Draw-time visibility filters over the build caches — a flip is a
## `queue_redraw`, never a rebuild. Chart-local, session-only.
var _layer_hidden := {}

# --- Build caches ------------------------------------------------------------

## The omniscient terrain image — static map data, built once per instance and
## reused by every debug rebuild (only the overlays change per trigger).
var _omni_image: Image = null
## The ice tint overlay at display resolution (built per rebuild while `I` is
## on; a month-keyed view, never GameState state).
var _ice_texture: ImageTexture = null

## Overlay caches the last build filled ([_draw] only reads these).
var _wind_arrows: Array = []
var _current_arrows: Array = []
var _ice_cells: Array = []
var _fleet_markers: Array = []
var _wreck_markers: Array = []
var _intel_markers: Array = []
var _network := {}
## Standalone-host fallback fleet view (created lazily, never ticked).
var _view_sim = null

## Redraw-discipline counters (the suite's assertions).
var _build_count := 0
var _terrain_build_count := 0

## Side-legend rows created once, refreshed per build/locale:
## `row_id → {box, label, value, swatch}`.
var _panel_rows: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# The full-screen background is painted by the root [_draw] itself (layer 0):
	# an opaque full-rect *child* ColorRect would render above everything the
	# root draws and mask the whole map (the z-order rule that shipped the
	# chart blind — see the scene's node order).
	_top_bar.color = PaletteLib.PANEL_BG
	_bottom_bar.color = PaletteLib.PANEL_BG
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(PaletteLib.PANEL_BG, 0.92)
	panel_style.border_color = PaletteLib.PANEL_LINE
	panel_style.set_border_width_all(1)
	panel_style.set_content_margin_all(PaletteLib.MARGIN * 0.5)
	_debug_panel.add_theme_stylebox_override("panel", panel_style)
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 24)
	_close.custom_minimum_size = Vector2(240, PaletteLib.BUTTON_H)
	_close.pressed.connect(close_chart)
	for label in _legend_labels():
		label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	visible = false
	# Bars follow the viewport (a window resize moves/rescales the world image).
	resized.connect(_relayout)
	mouse_exited.connect(_clear_hover)
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.day_advanced.connect(_on_day_advanced)
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
## over input (`80-*` §4.6 "build + first frame < 0.5 s"). Idempotent. Opening
## restores the fit view (§4.6 mouse view) and — while the S19 row is on —
## lifts the fog (omniscient default-on, §4.6 amended 2026-11-01).
func open_chart() -> void:
	if visible:
		return
	var started := Time.get_ticks_usec()
	_zoom = ZOOM_MIN
	_pan = Vector2.ZERO
	_dragging = false
	_omni_on = debug_available()
	_rebuild()
	visible = true
	add_to_group(MODAL_GROUP)
	_open_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_close.grab_focus()
	queue_redraw()


## Closes the chart. **Mutates nothing**: the fleet tile and `clock_fraction` are
## whatever S3 left there (§4.6 "returns to S3 with the fleet unmoved").
## Chart-local view state: the `W`/`C`/`I` toggles and the legend visibility
## filters persist across opens, the month preview resets to the live month,
## the mouse view resets to fit (§4.6, amended 2026-11-01).
func close_chart() -> void:
	if not visible:
		return
	visible = false
	_preview_month = 0
	_hover_text = ""
	_dragging = false
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


## Screen pixels per world tile in the last build (≈0.29 at 1280×720).
func chart_scale() -> float:
	return _scale


## Screen rect the whole world occupies (inside the bars and margins).
func world_rect() -> Rect2:
	return _world_rect


## Size of the grid-resolution image the chart built (the full 4320×2160 grid).
func world_image_size() -> Vector2i:
	return _world_image.get_size() if _world_image != null else Vector2i.ZERO


## Size of the texture actually drawn (the downscaled world).
func display_size() -> Vector2i:
	return _texture.get_size() if _texture != null else Vector2i.ZERO


## The colour the chart shows for `cell`: the explored terrain colour, or
## `PANEL_BG` for an unexplored tile (`80-*` §4.6 layers); with `D` on, the
## plain terrain colour everywhere (the omniscient chart ignores the bitset).
## Read from the grid-resolution image, so this is exactly comparable with the
## minimap's [method Hud.minimap_pixel_color] — that equality is the §J
## acceptance (player mode).
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


## The port markers the chart draws: the known ports (`[{port_id, cell, color,
## name}]`) in player mode, **every** port in omniscient mode — the shared
## [ChartView] layers, so the minimap and the chart agree in player mode.
func port_markers() -> Array:
	return _port_dots.duplicate()


## The discovery leads the chart draws: `[{id, cell}]` (found + explored only).
func lead_markers() -> Array:
	return _lead_cells.duplicate()


## Fleet cell the last build centred on.
func fleet_cell() -> Vector2i:
	return _fleet_cell


## Every visible player-mode string, for the "zero `<key>` fallbacks" check
## (the debug legend may legitimately render literal keys until the
## orchestrator merges the `debug.*` family — see `_bind_labels`).
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


# --- Seasonal layer API (`80-*` §4.6; keys only while the chart is open) ----

func wind_layer_on() -> bool:
	return _wind_on


func current_layer_on() -> bool:
	return _current_on


func ice_layer_on() -> bool:
	return _ice_on


## Chart-local `W` toggle (current-month wind arrows per region).
func toggle_wind_layer() -> void:
	_wind_on = not _wind_on
	_rebuild_if_open()


## Chart-local `C` toggle (current arrows, reversal-applied).
func toggle_current_layer() -> void:
	_current_on = not _current_on
	_rebuild_if_open()


## Chart-local `I` toggle (ice tint on explored tiles).
func toggle_ice_layer() -> void:
	_ice_on = not _ice_on
	_rebuild_if_open()


# --- Debug chart mode API (`80-*` §4.6, IMPLEMENT-Phase6.md §2.12) ----------

## The S19 调试图层 row, guard-read live (C's pinned symbol contract). When
## false, none of the debug layers or keys are reachable.
func debug_available() -> bool:
	return ChartViewLib.debug_row_enabled()


## `true` when the last build rendered the debug layers (row on).
func debug_layers_active() -> bool:
	return _debug_active


## `D` — the omniscient base map toggle (chart-local, debug-gated).
func omniscient_on() -> bool:
	return _omni_on


func toggle_omniscient() -> void:
	if not debug_available():
		return
	_omni_on = not _omni_on
	_rebuild_if_open()


## The scrubber preview month: 0 = live month, else 1..12 (chart-local,
## debug-gated; reset on close; **never** written to `GameState`).
func preview_month() -> int:
	return _preview_month


## The month the chart's seasonal layers currently render.
func view_month() -> int:
	if _preview_month >= 1 and _preview_month <= 12:
		return _preview_month
	return _live_month()


func _live_month() -> int:
	return SailingSimLib.month_for(maxi(int(GameState.day), 1))


## `,`/`.` — step the preview month (wraps 1..12). A no-op while the S19 row
## is off (`80-*` §4.3: the scrubber is debug-only).
func scrub_month(delta: int) -> void:
	if not debug_available():
		return
	var base := _preview_month if (_preview_month >= 1 and _preview_month <= 12) \
		else _live_month()
	_preview_month = posmod(base - 1 + delta, 12) + 1
	_rebuild_if_open()


## Direct preview set (tests / a future month-picker); `0` returns to live.
func set_preview_month(month: int) -> void:
	if not debug_available():
		return
	_preview_month = clampi(month, 0, 12)
	_rebuild_if_open()


## The debug layers the last build prepared (empty unless the row is on):
## `{"fleets": …, "wrecks": …, "intel": …, "network": …}`.
func ecology_markers() -> Array:
	return _fleet_markers.duplicate()


func wreck_markers() -> Array:
	return _wreck_markers.duplicate()


func intel_layer() -> Array:
	return _intel_markers.duplicate()


func network_layer() -> Dictionary:
	return _network.duplicate(true)


## The wind/current arrow + ice-tint overlay caches (structure-assert targets).
func wind_markers() -> Array:
	return _wind_arrows.duplicate()


func current_markers() -> Array:
	return _current_arrows.duplicate()


func ice_marker_cells() -> Array:
	return _ice_cells.duplicate()


## Read-only hover tooltip (debug mode only). The fleet debug info shows in
## a floating window at the cursor — every fleet on the hovered tile gets
## its own block (id · role · nation · stall×holds · port); wrecks, ports
## and intel keep single-line entries. The side panel's hover row carries
## the first line as a summary.
func hover_text() -> String:
	return _hover_text


## Redraw-discipline counters: overlay builds (open, layer/month toggle,
## `day_advanced`) and terrain-image builds (open, `D` flips).
func build_count() -> int:
	return _build_count


func terrain_build_count() -> int:
	return _terrain_build_count


# --- Input (`80-*` §4.3) ---------------------------------------------------

## The Tab edge lives in `_input`, ABOVE the GUI layer: Tab is Godot's UI
## focus-cycle key, so with any focused Control on screen (the port hub's
## footer, the chart's own close button) the viewport consumed Tab before
## `_unhandled_input` ever saw it — the chart would not open at port (§4.3,
## amended 2026-11-01). Esc and the layer keys stay in `_unhandled_input`.
func _input(event: InputEvent) -> void:
	if not _wants_toggle(event):
		return
	if visible:
		get_viewport().set_input_as_handled()
		close_chart()
		return
	# Closed: open — unless a modal already owns the screen (`80-*` §6:
	# "Tab does nothing while any modal is up").
	if _other_modal_open():
		return
	get_viewport().set_input_as_handled()
	open_chart()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Open: the panel owns all input (§4.6); `Esc` closes.
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close_chart()
		return
	# Seasonal layers + debug keys (raw keys — no InputMap actions are bound
	# for the chart, the same style as its `Tab`).
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		if not key.echo:
			var code := key.physical_keycode \
				if key.physical_keycode != KEY_NONE else key.keycode
			match code:
				KEY_W:
					toggle_wind_layer()
				KEY_C:
					toggle_current_layer()
				KEY_I:
					toggle_ice_layer()
				KEY_D:
					toggle_omniscient()  # self-gated: no-op while the row is off
				KEY_COMMA:
					scrub_month(-1)  # self-gated
				KEY_PERIOD:
					scrub_month(1)  # self-gated
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


## Read-only hover tooltips (debug mode): nearest cached marker within 8 px.
## Updates a Label only — never a rebuild (the redraw-trigger discipline).
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			_pan -= mm.relative
			_clamp_pan()
			queue_redraw()
		else:
			_update_hover(mm.position)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP \
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_zoom_at(mb.position,
				ZOOM_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP \
					else 1.0 / ZOOM_STEP)
			return
		if mb.button_index == MOUSE_BUTTON_LEFT \
				or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed and _zoom > ZOOM_MIN


# --- Mouse view (§4.6, amended 2026-11-01) ----------------------------------

## The rect the world occupies on screen right now: the fit rect plus the
## view transform (pan + zoom). Every draw/coordinate mapping goes through
## this, so zooming never touches the caches.
func _view_rect() -> Rect2:
	return Rect2(_world_rect.position + _pan, _world_rect.size * _zoom)


## Keeps the map covering the view: the pan offset is bounded by the zoom
## surplus, so at fit zoom there is nothing to pan (§4.6 "clamped to the map").
func _clamp_pan() -> void:
	var limit := _world_rect.size * (_zoom - 1.0)
	_pan = _pan.clamp(-limit, Vector2.ZERO)


## Wheel zoom anchored at `screen_at`: the world point under the cursor stays
## under the cursor (§4.6). Pure view state — a `queue_redraw`, no rebuild.
func _zoom_at(screen_at: Vector2, factor: float) -> void:
	var world_pt := (screen_at - _view_rect().position) / (_scale * _zoom)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_pan = screen_at - _world_rect.position - world_pt * _scale * _zoom
	_clamp_pan()
	queue_redraw()


func _clear_hover() -> void:
	if not _hover_text.is_empty():
		_hover_text = ""
		_refresh_panel()
	if _hover_window != null:
		_hover_window.visible = false


func _update_hover(at: Vector2) -> void:
	if not visible or not _debug_active:
		return
	# The hovered TILE (the inverse of `_to_screen`'s centre mapping): every
	# fleet standing on it gets its own debug block in the floating window
	# (unified-movement amendment — stacked fleets all report).
	var width := _world_image.get_width() if _world_image != null else 4320
	var u := (at - _view_rect().position) / (_scale * _zoom)
	var cell := Vector2i(posmod(int(floor(u.x)), width), int(floor(u.y)))
	var ships: Array = []
	for entry in _fleet_markers:
		var c: Vector2i = entry["cell"]
		if Vector2i(posmod(c.x, width), c.y) == cell:
			ships.append(entry)
	var text := ""
	if not ships.is_empty():
		# Localized blocks (unified-movement amendment; the §4.7.10 rule —
		# debug surfaces speak the ui_strings locale): `id` stays raw (an
		# identifier), every other term resolves — `debug.role.*`,
		# the nation's L10n name, `debug.stall.*`, `debug.info.*` labels,
		# the mooring/destination port's L10n name. `holds` shows only
		# where it means something (blocked).
		for ship in ships:
			var role := str(ship.get("role", ""))
			var stall := str(ship.get("stall", ""))
			var holds := int(ship.get("holds", 0))
			var line := str(ship.get("id", ""))
			var parts: Array = [I18n.t_key("debug.role." + role)]
			var nation := str(ship.get("nation_id", ""))
			if not nation.is_empty():
				var n = DataLoader.nations.get(nation, null)
				if n is Dictionary:
					parts.append(I18n.t(n.get("name", {})))
			if not stall.is_empty():
				parts.append(I18n.t_key("debug.stall." + stall))
				if stall == "blocked":
					parts.append("×%d" % holds)
					# The why: heading + rate for the blocked fleet.
					var b_heading := str(ship.get("heading", ""))
					if not b_heading.is_empty():
						parts.append(I18n.t_key("debug.info.heading") + " "
							+ b_heading)
					var b_speed := float(ship.get("speed", 0.0))
					parts.append(I18n.t_key("debug.info.speed") + " "
						+ str(int(round(b_speed))) + " "
						+ I18n.t_key("debug.info.speed_unit"))
				elif stall == "camping":
					parts.append("@ " + str((ship.get("cell",
						Vector2i.ZERO) as Vector2i)))
				elif stall == "docked" and ship.has("port") \
						and not str(ship.get("port", "")).is_empty():
					var mooring: Dictionary = DataLoader.get_port(
						str(ship.get("port", "")))
					if not mooring.is_empty():
						parts.append("@ " + I18n.t(mooring.get("name", {})))
				elif stall == "stranded":
					# Docked in name only: the fleet stands in open water.
					# Show where it actually is, never a port name it is
					# nowhere near (the false-mooring report); the [raw3]
					# `mooring=`/`ev=` lines carry the rest.
					var here := ship.get("cell", Vector2i.ZERO) as Vector2i
					parts.append("@ %d,%d" % [here.x, here.y])
			var heading := str(ship.get("heading", ""))
			var speed := float(ship.get("speed", 0.0))
			var dest := str(ship.get("dest", ""))
			if not heading.is_empty():
				# Under-way detail: heading · speed · destination.
				parts.append(I18n.t_key("debug.info.heading") + " " + heading)
				if speed > 0.0:
					parts.append(I18n.t_key("debug.info.speed") + " "
						+ str(int(round(speed))) + " "
						+ I18n.t_key("debug.info.speed_unit"))
				if not dest.is_empty():
					var port: Dictionary = DataLoader.get_port(dest)
					if not port.is_empty():
						parts.append(I18n.t_key("debug.info.dest") + " "
							+ I18n.t(port.get("name", {})))
			var lanes: Array = ship.get("lanes", []) \
				if ship.get("lanes", []) is Array else []
			if parts.size() < 2 and not lanes.is_empty():
				# The drop/re-depart gap state (no heading/speed yet): show
				# the fleet's patrol circuit so the entry is never bare.
				var lane_names: Array = []
				for lane_id in lanes:
					lane_names.append(I18n.t_key("debug.lane." + str(lane_id)))
				parts.append(I18n.t_key("debug.info.circuit") + " "
					+ " · ".join(lane_names))
			line += "\n  " + " · ".join(parts)
			line += "\n  " + _annotate_raw_line("[raw]",
				str(ship.get("dbg", "")), "state", false)
			var raw2 := str(ship.get("dbg2", ""))
			if not raw2.is_empty():
				line += "\n  " + _annotate_raw_line("[raw2]", raw2,
					"accrual", false)
			var raw3 := str(ship.get("dbg3", ""))
			if not raw3.is_empty():
				line += "\n  " + _annotate_raw_line("[raw3]", raw3,
					"journey", true)
			text += line + "\n"
	else:
		# No fleet on the tile: the nearest wreck / intel / port entry.
		var best := ""
		var best_d := 8.0
		for entry in _wreck_markers:
			var d := _to_screen(entry["cell"]).distance_to(at)
			if d < best_d:
				best_d = d
				best = str(entry.get("id", ""))
		for entry in _intel_markers:
			var d := _to_screen(entry["cell"]).distance_to(at)
			if d < best_d:
				best_d = d
				best = "intel → %s" % str(entry.get("port_id", "")) \
					if str(entry.get("kind", "")) == "ring" \
					else "intel cell"
		for entry in _port_dots:
			var d := _to_screen(entry["cell"]).distance_to(at)
			if d < best_d:
				best_d = d
				best = str(entry.get("port_id", ""))
		text = best
	if text != _hover_text:
		# The side row carries the FIRST line only — the full multi-ship
		# report lives in the floating window.
		_hover_text = text.split("\n")[0] if not text.is_empty() else ""
		_refresh_panel()
	_show_hover_window(text, at)


# --- Annotated raw lines (§4.6, amended 2026-11-02) --------------------------

## The raw hover payload keys that carry a localized gloss
## (`debug.raw.f.<key>`, ui_strings.json — §4.7.10).
const RAW_GLOSS_KEYS: Array[String] = ["cell", "dwell", "day", "legs", "ti",
	"holds", "carry", "mark", "now", "pend", "last", "lastd", "moved",
	"skip", "committed", "budget", "pipe", "cd", "leg0", "dest", "mooring"]

## `[raw3]`'s `ev=` tail spans tokens with its own event grammar — split
## off before the generic `key=value` pass.
const EV_TAG := "ev="


## Renders one raw line as `<tag>·<section> <gloss> key=value ...`: every
## `key=value` token is prefixed with its localized gloss (the raw payload
## stays verbatim for doc/test cross-reference), `_raw_value_gloss` appends
## the value-side annotations, non-key continuation tokens (`leg0`'s
## `ti/walked_len` tail) extend the previous field, and — for `[raw3]` —
## the trailing `ev=` event ring is translated event-wise.
func _annotate_raw_line(tag: String, raw: String, section: String,
		with_ev: bool) -> String:
	var head := raw
	var ev := ""
	if with_ev:
		var cut := raw.find(" " + EV_TAG)
		if cut >= 0:
			head = raw.substr(0, cut)
			ev = raw.substr(cut + 1 + EV_TAG.length())
	var out: Array = ["%s·%s" % [tag, I18n.t_key("debug.raw.sec." + section)]]
	for token in head.split(" ", false):
		var eq := token.find("=")
		var key := token.substr(0, eq) if eq > 0 else ""
		if key in RAW_GLOSS_KEYS:
			var field := "%s %s" % [I18n.t_key("debug.raw.f." + key), token]
			field += _raw_value_gloss(key, token.substr(eq + 1))
			out.append(field)
		elif not out.is_empty():
			# Continuation of the previous field's value.
			out[out.size() - 1] += " " + token
		else:
			out.append(token)
	if not ev.is_empty():
		out.append("%s %s%s" % [I18n.t_key("debug.raw.f.ev"), EV_TAG,
			_annotate_ev_stream(ev)])
	return " ".join(out)


## The value-side annotation of one raw field: the localized port/lane
## name in parentheses (`dest` / `mooring` are port ids; `leg0`'s id is a
## lane id on lane legs, a port id on spokes) or the §4.6 value hints
## (`pend < 0` ⇒ frozen, `mark < 0` ⇒ unset). "" when nothing applies.
func _raw_value_gloss(key: String, value: String) -> String:
	if key == "dest" or key == "mooring":
		return _paren(_port_name(value))
	if key == "leg0":
		var br := value.find("[")
		return _paren(_leg_name(value.substr(0, br) if br >= 0 else value))
	if key == "pend" or key == "mark":
		if value.is_valid_float() and float(value) < 0.0:
			return "(%s)" % I18n.t_key("debug.raw.hint."
				+ ("frozen" if key == "pend" else "no_mark"))
	return ""


## The ev ring stream (`spawn@1 dep a->b@5 ...`): appends the localized
## names per event token — `a->b` pairs (`dep`/`depX` carry them as the
## following token), the port after a bare `arr`, and `wedge|leg|seam:<id>`
## (the `drop` verb is the preceding bare token). Unknown tokens pass
## through untouched.
func _annotate_ev_stream(ev: String) -> String:
	var out: Array = []
	var prev_arr := false
	for tok in ev.split(" ", false):
		var head := tok
		var at := tok.rfind("@")
		if at > 0:
			head = tok.substr(0, at)  # strip the `@<day>` stamp
		var gloss := ""
		if head.contains("->"):
			var arrow := head.find("->")
			var a := _port_name(head.substr(0, arrow))
			var b := _port_name(head.substr(arrow + 2))
			if not (a.is_empty() and b.is_empty()):
				gloss = "(%s→%s)" % [a, b]
		elif prev_arr:
			gloss = _paren(_port_name(head))
		elif head.contains(":"):
			gloss = _paren(_leg_name(head.substr(head.find(":") + 1)))
		prev_arr = head == "arr"
		out.append(tok + gloss)
	return " ".join(out)


## The localized port name for a raw port id ("" when the id resolves to
## no known port — the annotation is then omitted, the legend's raw-id
## fallback rule).
func _port_name(port_id: String) -> String:
	if port_id.is_empty() or port_id == "-":
		return ""
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return ""
	return I18n.t(port.get("name", {}))


## The localized name for a raw leg id — a lane id on lane legs
## (`debug.lane.<id>`, the §4.6 network legend), a port id on spokes; ""
## when neither resolves.
func _leg_name(id: String) -> String:
	if id.is_empty() or id == "-":
		return ""
	var lane_key := "debug.lane." + id
	if DataLoader.ui_strings.has(lane_key):
		return I18n.t_key(lane_key)
	return _port_name(id)


## `(名)` wrapper — "" stays "".
func _paren(name: String) -> String:
	return "" if name.is_empty() else "(%s)" % name


## The floating hover window (unified-movement amendment): a bordered
## panel at the cursor, mouse-transparent, clipped to the viewport.
## §4.6 (amended 2026-11-02): the label folds at
## `min(HOVER_WINDOW_MAX_W, viewport width × 0.5)` px.
const HOVER_WINDOW_MAX_W := 560.0
var _hover_window: PanelContainer = null
var _hover_window_label: Label = null


func _ensure_hover_window() -> void:
	if _hover_window != null:
		return
	_hover_window = PanelContainer.new()
	_hover_window.name = "HoverWindow"
	_hover_window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_window.z_index = 100
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(1.0)
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	_hover_window.add_theme_stylebox_override("panel", style)
	_hover_window_label = Label.new()
	_hover_window_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_window.add_child(_hover_window_label)
	add_child(_hover_window)
	_hover_window.visible = false


## Shows/hides + positions the floating window (clamped to the viewport).
## §4.6 (amended 2026-11-02): a report wider than the fold cap wraps
## (word-smart) instead of spanning the screen; short entries keep their
## natural width.
func _show_hover_window(text: String, at: Vector2) -> void:
	_ensure_hover_window()
	if text.is_empty():
		_hover_window.visible = false
		return
	_hover_window_label.text = text
	var view := get_viewport_rect().size
	var max_w := minf(HOVER_WINDOW_MAX_W, view.x * 0.5)
	_hover_window_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hover_window_label.custom_minimum_size.x = 0.0
	if _hover_window_label.get_minimum_size().x > max_w:
		_hover_window_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_hover_window_label.custom_minimum_size.x = max_w
	_hover_window.visible = true
	var size := _hover_window.get_minimum_size()
	var pos := at + Vector2(14.0, 14.0)
	_hover_window.position = pos.clamp(Vector2.ZERO,
		(view - size).clamp(Vector2.ZERO, view))


# --- Rebuild triggers (`80-*` §4.6: open, layer/month toggle, day_advanced) -

func _rebuild_if_open() -> void:
	if visible:
		_rebuild()


## The pinned `day_advanced` redraw trigger — only while open (the chart is a
## modal, so in real play the world is frozen while it shows; a test may emit
## the signal directly).
func _on_day_advanced(_new_day: int) -> void:
	_rebuild_if_open()


func _on_locale_changed(_locale: String) -> void:
	_bind_labels()


# --- Layout ------------------------------------------------------------------

## Lays out the world rect. Cheap (no image work) so a resize is not a rebuild;
## the texture is stretched to the new rect by [_draw]. The two bars are
## anchor-driven in the scene file, so only the world rect is computed here.
## While the debug side legend is up, the world shrinks left of it — the whole
## world always stays visible (§4.6 "downscaled to fit", no scrolling).
func _relayout() -> void:
	var view := get_viewport_rect().size
	var panel_w := DEBUG_PANEL_W if _debug_panel.visible else 0.0
	# World area: between the bars, inset by the §4.8 16px margin.
	var avail := Vector2(
		maxf(view.x - MARGIN * 2.0 - panel_w, 1.0),
		maxf(view.y - TOP_BAR_H - BOTTOM_BAR_H - MARGIN * 2.0, 1.0)
	)
	var map = DataLoader.map
	var grid := Vector2i(4320, 2160)
	if map != null and int(map.width) > 0:
		grid = Vector2i(int(map.width), int(map.height))
	_scale = minf(avail.x / grid.x, avail.y / grid.y)
	var size := Vector2(grid) * _scale
	var centre_w := view.x - panel_w
	_world_rect = Rect2(
		Vector2(
			(centre_w - size.x) * 0.5,
			TOP_BAR_H + (view.y - TOP_BAR_H - BOTTOM_BAR_H - size.y) * 0.5
		),
		size
	)
	_clamp_pan()  # a resize moves the fit rect — re-bound the mouse view
	queue_redraw()


# --- Build (docs/80-* §4.6 layers + §2.12 debug layers) ---------------------

## Builds the world image + every overlay cache once per trigger. This is the
## only function that walks the grid; [_draw] uses the results.
func _rebuild() -> void:
	_build_count += 1
	# The S19 row is read live at every trigger: turning it off makes the
	# debug layers unreachable at the next build.
	_debug_active = debug_available()
	if not _debug_active:
		_omni_on = false
		_preview_month = 0
		_hover_text = ""
		_layer_hidden.clear()
	_debug_panel.visible = _debug_active
	var map = DataLoader.map
	_lead_cells = []
	_fleet_cell = _fleet_source_cell()
	if map == null or int(map.width) <= 0 or int(map.height) <= 0:
		_world_image = null
		_texture = null
		_port_dots = []
		_wind_arrows = []
		_current_arrows = []
		_ice_cells = []
		_ice_texture = null
		_fleet_markers = []
		_wreck_markers = []
		_intel_markers = []
		_network = {}
		_refresh_panel()
		queue_redraw()
		return
	_relayout()
	var month := view_month()
	var omniscient := _debug_active and _omni_on

	# Layer 1/2: the terrain — explored-only in player mode, the whole map in
	# omniscient mode (cached: static map data, built once per instance).
	_world_image = _terrain_image(map, omniscient)
	_texture = _downscaled_texture(_world_image)

	# Layer 3: ports — known only (player) or every port with the neutral
	# grey + capital flags (omniscient); both are shared [ChartView] layers.
	_port_dots = ChartViewLib.port_dots(map) if not omniscient \
		else ChartViewLib.all_port_dots(map)
	_lead_cells = ChartViewLib.lead_cells(map)

	# Seasonal overlays (current month, or the debug preview month).
	_wind_arrows = ChartViewLib.wind_arrows(month) if _wind_on else []
	_current_arrows = ChartViewLib.current_arrows(month) if _current_on else []
	_ice_cells = ChartViewLib.ice_cells(month, omniscient, map) if _ice_on else []
	_ice_texture = _ice_overlay_texture() if _ice_on else null

	# Debug layers: live ecology, wrecks, hunter intel, the lane network.
	if _debug_active:
		_fleet_markers = ChartViewLib.fleet_markers(_fleet_sim())
		_wreck_markers = ChartViewLib.wreck_cells()
		_intel_markers = ChartViewLib.intel_markers(map)
		_network = ChartViewLib.lane_network(month)
	else:
		_fleet_markers = []
		_wreck_markers = []
		_intel_markers = []
		_network = {}

	_refresh_panel()
	queue_redraw()


## The terrain image for this build: the session's explored overlay, or the
## omniscient whole-map render (cached per instance — map data never changes).
func _terrain_image(map, omniscient: bool) -> Image:
	if omniscient:
		if _omni_image == null:
			_omni_image = _full_terrain_image(map)
			_terrain_build_count += 1
		return _omni_image
	_terrain_build_count += 1
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
	return image


## The omniscient terrain: every tile in its palette colour (a LUT pass over
## the decoded indices, ~0.4 s once — the debug chart's one heavy build).
func _full_terrain_image(map) -> Image:
	var colors: Array = ChartViewLib.palette_colors(map)
	var width := int(map.width)
	var height := int(map.height)
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		for x in width:
			image.set_pixel(x, y, ChartViewLib.index_color(colors, map, x, y))
	return image


## The ice tint overlay at display resolution (a month view, rebuilt per
## trigger while `I` is on — the mask walks ~10^5 tiles at most).
func _ice_overlay_texture() -> ImageTexture:
	if _world_rect.size.x <= 0.0 or _world_rect.size.y <= 0.0:
		return null
	var size := Vector2i(
		maxi(int(round(_world_rect.size.x)), 1),
		maxi(int(round(_world_rect.size.y)), 1))
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var tint := Color(PaletteLib.ICE, ICE_TINT_ALPHA)
	for cell in _ice_cells:
		var at := (Vector2(cell) + Vector2(0.5, 0.5)) * _scale
		var px := Vector2i(at)
		if px.x < 0 or px.y < 0 or px.x >= size.x or px.y >= size.y:
			continue
		image.set_pixel(px.x, px.y, tint)
	return ImageTexture.create_from_image(image)


## Nearest-neighbour downscale to the on-screen world rect (crisp tiles: the
## same look the minimap has, `80-*` §4.6 "downscaled to fit").
## The terrain texture at the MAP's NATIVE resolution (4320×2160) — the GPU
## scales it per the view rect, so deep zoom-in (the unified-movement
## amendment raised ZOOM_MAX to 64 for fleet-level inspection) stays crisp
## instead of magnifying a fit-view downscale. ~37 MB VRAM per texture;
## desktop debug tool only, event-driven redraws.
func _downscaled_texture(image: Image) -> ImageTexture:
	return ImageTexture.create_from_image(image)


## The fleet sim the debug ecology reads: the host world scene's sim when the
## chart is hosted by one (its `fleet_sim()` seam), else a fresh **never-ticked**
## read-only view over the same `GameState.npc_fleets`. Neither path mutates
## sim or session state.
func _fleet_sim():
	var node: Node = self
	while node != null:
		if node != self and node.has_method("fleet_sim"):
			var sim = node.call("fleet_sim")
			if sim != null:
				return sim
		node = node.get_parent()
	if _view_sim == null:
		_view_sim = NpcFleetsLib.new({
			"npc_config": DataLoader.npc_config,
			"preset": GameState.npc_preset,
		})
	return _view_sim


# --- Drawing (docs/80-* §4.6 layers, bottom to top) -----------------------

func _draw() -> void:
	if not visible:
		return
	var view := get_viewport_rect().size
	# Layer 0: the canvas background (§4.6).
	draw_rect(Rect2(Vector2.ZERO, view), PaletteLib.PANEL_BG, true)
	var view_rect := _view_rect()
	if _texture != null:
		# Layer 1/2: explored tiles (or the omniscient whole map) over the
		# unknown background, at the §4.6 "low alpha" (the texture carries the
		# plain palette colours, so the identity read-back stays exact). Drawn
		# into the view rect — zoom stretches it nearest-neighbour (§4.6).
		draw_texture_rect(_texture, view_rect, false,
			Color(1, 1, 1, EXPLORED_ALPHA))
	draw_rect(view_rect, PaletteLib.PANEL_LINE, false, 2.0)

	# Ice tint (the `I` layer; explored-only in player mode).
	if _ice_texture != null:
		draw_texture_rect(_ice_texture, view_rect, false)

	# Debug network (below the ecology, above the terrain).
	if _debug_active:
		_draw_network()

	# The seasonal arrow layers (`W`/`C`).
	if _wind_on:
		_draw_wind_arrows()
	if _current_on:
		_draw_current_arrows()

	# Layer 3: ports as nation-coloured dots (+ names at zoom); omniscient
	# mode adds the neutral grey and capital rings.
	var show_names := names_shown(_scale)
	for entry in _port_dots:
		if entry.get("neutral", false) and _layer_hidden.get("neutral", false):
			continue
		var at := _to_screen(entry["cell"])
		draw_rect(Rect2(
			at - Vector2(PORT_DOT_PX, PORT_DOT_PX) * 0.5,
			Vector2(PORT_DOT_PX, PORT_DOT_PX)
		), entry["color"], true)
		if _debug_active and not str(entry.get("capital", "")).is_empty():
			draw_arc(at, CAPITAL_RING_PX, 0.0, TAU, 24, PaletteLib.TEXT, 1.5)
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

	# Debug ecology: wrecks (ACCENT ×), fleets (§4.5.2 role colors, un-culled),
	# hunter-intel ring + cross (`60-*` §4.11.11.1 shapes). Legend rows hide
	# their category draw-time (§4.6 interactive legend rows).
	if _debug_active:
		if not _layer_hidden.get("wrecks", false):
			for entry in _wreck_markers:
				_draw_cross(_to_screen(entry["cell"]), WRECK_CROSS_PX, PaletteLib.ACCENT)
		for entry in _fleet_markers:
			if _layer_hidden.get("role_" + str(entry.get("role", "")), false):
				continue
			_draw_fleet_marker(entry)
		if not _layer_hidden.get("intel", false):
			for entry in _intel_markers:
				var at := _to_screen(entry["cell"])
				if str(entry.get("kind", "")) == "ring":
					draw_arc(at, INTEL_RING_PX, 0.0, TAU, 24, INTEL_COLOR, 2.0)
				else:
					_draw_cross(at, INTEL_CROSS_PX, INTEL_COLOR)

	# Layer 4.5 (task L, docs/80-* §4.6 flag — default OFF): lane heat dots.
	# Purely cosmetic: an `ACCENT` dot per live fleet standing on a lane or
	# spoke tile, so traffic-dense stretches read denser. Read-only.
	if LANE_HEAT:
		for fleet in GameState.npc_fleets:
			if not (fleet is Dictionary):
				continue
			var cell := NpcFleetsLib.position_of(fleet)
			if cell.x < 0 or not _is_path_tile(cell):
				continue
			var heat := _to_screen(cell)
			draw_rect(Rect2(
				heat - Vector2(LANE_HEAT_DOT_PX, LANE_HEAT_DOT_PX) * 0.5,
				Vector2(LANE_HEAT_DOT_PX, LANE_HEAT_DOT_PX)
			), PaletteLib.ACCENT, true)

	# Layer 5: the fleet — a white 5px square with a black 1px outline (§4.6).
	if _fleet_cell.x >= 0:
		var at := _to_screen(_fleet_cell)
		var outline := FLEET_SQUARE_PX + FLEET_OUTLINE_PX * 2.0
		draw_rect(Rect2(at - Vector2(outline, outline) * 0.5,
			Vector2(outline, outline)), Color.BLACK, true)
		draw_rect(Rect2(at - Vector2(FLEET_SQUARE_PX, FLEET_SQUARE_PX) * 0.5,
			Vector2(FLEET_SQUARE_PX, FLEET_SQUARE_PX)), Color.WHITE, true)


## The §2.12 network layer: spokes thin grey, inactive lane variants dim, the
## active path solid in the lane's legend color, chokepoint diamonds. Legend
## rows hide their category draw-time (§4.6 interactive legend rows).
func _draw_network() -> void:
	if _network.is_empty():
		return
	var width := 4320
	var map = DataLoader.map
	if map != null and int(map.width) > 0:
		width = int(map.width)
	# Spokes: thin grey (the dimmest network shape).
	if not _layer_hidden.get("spokes", false):
		var spoke_color := Color(PaletteLib.PANEL_LINE, SPOKE_ALPHA)
		for spoke in _network.get("spokes", []):
			for run in _screen_runs(spoke.get("path", []), width):
				draw_polyline(run, spoke_color, 1.0, false)
	for lane in _network.get("lanes", []):
		if _layer_hidden.get("lane_" + str(lane["id"]), false):
			continue
		var lane_color: Color = lane["color"]
		# Inactive seasonal variants: dim dots of the lane color.
		var dim := Color(lane_color, INACTIVE_LANE_ALPHA)
		for variant in lane.get("inactive_paths", []):
			for run in _screen_runs(variant.get("path", []), width):
				_draw_dotted_run(run, dim)
		# The active path solid.
		for run in _screen_runs(lane.get("active_path", []), width):
			draw_polyline(run, lane_color, 1.5, false)
	# Chokepoint diamonds (hollow, rotated squares).
	if _layer_hidden.get("chokepoints", false):
		return
	for choke in _network.get("chokepoints", []):
		var at := _to_screen(choke["cell"])
		var r := CHOKEPOINT_PX
		var points := PackedVector2Array([
			at + Vector2(0, -r), at + Vector2(r, 0),
			at + Vector2(0, r), at + Vector2(-r, 0), at + Vector2(0, -r),
		])
		draw_polyline(points, PaletteLib.BAD, 1.5, false)


## Dots every ~6 px along a run (the "dotted" inactive-variant rendering).
func _draw_dotted_run(points: PackedVector2Array, color: Color) -> void:
	var carry := 0.0
	for index in range(1, points.size()):
		var a := points[index - 1]
		var b := points[index]
		var seg := a.distance_to(b)
		if seg <= 0.0:
			continue
		var step := 6.0
		var t := carry
		while t <= seg:
			draw_rect(Rect2(a.lerp(b, t / seg) - Vector2(1, 1) * 0.5,
				Vector2(1, 1)), color, true)
			t += step
		carry = t - seg


func _draw_wind_arrows() -> void:
	for arrow in _wind_arrows:
		var at := _to_screen(arrow["cell"])
		if arrow.get("variable", false):
			# The `VAR` region glyph: a hollow amber diamond (distinctive
			# against every directional arrow).
			var r := WIND_ARROW_PX * 0.5
			var points := PackedVector2Array([
				at + Vector2(0, -r), at + Vector2(r, 0),
				at + Vector2(0, r), at + Vector2(-r, 0), at + Vector2(0, -r),
			])
			draw_polyline(points, WIND_VAR_COLOR, 1.5, false)
			continue
		var dir := _compass_vector(str(arrow["token"]))
		if dir == Vector2.ZERO:
			continue
		_draw_arrow(at, dir, WIND_ARROW_PX, WIND_ARROW_COLOR, 1.5)


func _draw_current_arrows() -> void:
	for arrow in _current_arrows:
		var dir := _compass_vector(str(arrow["dir"]))
		if dir == Vector2.ZERO:
			continue
		var strength := int(arrow.get("strength", 1))
		# Length/width scale with the decoded strength (§4.16 bands 1..3).
		_draw_arrow(_to_screen(arrow["cell"]), dir,
			7.0 + 4.0 * strength, CURRENT_ARROW_COLOR, 1.0 + 0.5 * (strength - 1))


## One arrow: shaft along `dir`, a V head at the tip.
func _draw_arrow(at: Vector2, dir: Vector2, length_px: float,
		color: Color, width: float) -> void:
	var tip := at + dir * (length_px * 0.5)
	var tail := at - dir * (length_px * 0.5)
	draw_line(tail, tip, color, width)
	var head := dir.rotated(PI * 0.75) * (length_px * 0.3)
	draw_line(tip, tip + head, color, width)
	draw_line(tip, tip + dir.rotated(-PI * 0.75) * (length_px * 0.3), color, width)


func _draw_cross(at: Vector2, size_px: float, color: Color) -> void:
	var half := size_px * 0.5
	draw_line(at - Vector2(half, 0), at + Vector2(half, 0), color, 1.5)
	draw_line(at - Vector2(0, half), at + Vector2(0, half), color, 1.5)


## The §4.5.2 role marker: a nation-coloured square with the role letter
## (pirate `BAD`, a hunter its nation's colour with the navy letter).
func _draw_fleet_marker(entry: Dictionary) -> void:
	var at := _to_screen(entry["cell"])
	var color := _role_color(str(entry.get("role", "")), str(entry.get("nation_id", "")))
	# Zoom-scaled square (unified-movement amendment): deep inspection zoom
	# keeps the marker readable — half a screen-tile, at least the base px.
	var sq := maxf(float(DEBUG_FLEET_SQUARE_PX), _scale * _zoom * 0.5)
	draw_rect(Rect2(
		at - Vector2(sq, sq) * 0.5,
		Vector2(sq, sq)
	), color, true)
	var letter := str(entry.get("letter", ""))
	if not letter.is_empty():
		draw_string(ThemeDB.fallback_font,
			at + Vector2(sq, sq) * 0.3,
			letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, PaletteLib.TEXT)


## §4.5.2 role colors: pirate is `BAD`; every other role wears its nation's
## colour (an unknown nation falls back to `ACCENT`, the shared-layer rule).
func _role_color(role: String, nation_id: String) -> Color:
	if role == "pirate":
		return PaletteLib.BAD
	var nation = DataLoader.nations.get(nation_id, null)
	if nation is Dictionary:
		var hex = (nation as Dictionary).get("color", "")
		if hex is String and Color.html_is_valid(hex):
			return PaletteLib.nation_color(hex)
	return PaletteLib.ACCENT


func _compass_vector(token: String) -> Vector2:
	var index := OceanLayersLib.COMPASS_DIRS.find(token)
	if index < 0:
		return Vector2.ZERO
	return OceanLayersLib.COMPASS_VECTORS[index]


## Tile path → screen-space polyline runs, thinned to ~1 screen px per point
## (a 20k-tile lane at 0.29 px/tile needs no more).
func _screen_runs(path: Array, width: int) -> Array:
	var stride := maxi(1, int(floor(1.0 / maxf(_scale, 0.0001))))
	var runs := []
	for run in ChartViewLib.path_runs(path, width):
		var points := PackedVector2Array()
		for index in range(0, run.size(), stride):
			points.append(_to_screen(run[index]))
		if (run.size() - 1) % stride != 0:
			points.append(_to_screen(run[run.size() - 1]))
		if points.size() >= 2:
			runs.append(points)
	return runs


func _to_screen(cell: Vector2i) -> Vector2:
	var vr := _view_rect()
	return vr.position + (Vector2(cell) + Vector2(0.5, 0.5)) * _scale * _zoom


## `true` when `cell` carries a lane or spoke tile (the lane-heat flag's
## filter; the same built-data membership the ecology indexes).
func _is_path_tile(cell: Vector2i) -> bool:
	if _network.is_empty():
		return false
	var width := 4320
	var map = DataLoader.map
	if map != null and int(map.width) > 0:
		width = int(map.width)
	for lane in _network.get("lanes", []):
		if (lane.get("active_path", []) as Array).has(
				Vector2i(posmod(cell.x, width), cell.y)):
			return true
	for spoke in _network.get("spokes", []):
		if (spoke.get("path", []) as Array).has(
				Vector2i(posmod(cell.x, width), cell.y)):
			return true
	return false


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


# --- Strings (docs/80-* §4.7.5 + §4.7.10) -----------------------------------

func _legend_labels() -> Array:
	return [_legend_note, _legend_port, _legend_fleet, _legend_discovery,
		_legend_wind, _legend_current, _legend_ice]


func _bind_labels() -> void:
	_title.text = I18n.t_key(KEY_TITLE)
	_close.text = I18n.t_key(KEY_CLOSE)
	_legend_note.text = I18n.t_key(KEY_HINT)
	_legend_port.text = "· " + I18n.t_key(KEY_LEGEND_PORT)
	_legend_fleet.text = "· " + I18n.t_key(KEY_LEGEND_FLEET)
	_legend_discovery.text = "· " + I18n.t_key(KEY_LEGEND_DISCOVERY)
	_legend_wind.text = "· " + I18n.t_key(KEY_WIND)
	_legend_current.text = "· " + I18n.t_key(KEY_CURRENT)
	_legend_ice.text = "· " + I18n.t_key(KEY_ICE)
	_refresh_panel()


## Every debug side-legend string, for the suite (these MAY be literal
## `<key>`s until the orchestrator merges the `debug.*` family — the suite
## only asserts they are non-empty and locale-reactive).
func debug_legend_texts() -> Array:
	var out: Array = []
	for row_id in _panel_rows:
		var row: Dictionary = _panel_rows[row_id]
		out.append(str(row["label"].text))
		out.append(str(row["value"].text))
	return out


# --- Debug side legend (`80-*` §4.6: lane ids + role names in a side legend) -

## Creates the panel rows once (structure is static; values refresh per build).
func _ensure_panel_rows() -> void:
	if not _panel_rows.is_empty():
		return
	_panel_rows["title"] = _panel_section(KEY_DEBUG_TITLE)
	_panel_rows["omni"] = _panel_row(KEY_DEBUG_OMNI, true)
	_panel_rows["wind"] = _panel_row(KEY_WIND, true)
	_panel_rows["current"] = _panel_row(KEY_CURRENT, true)
	_panel_rows["ice"] = _panel_row(KEY_ICE, true)
	_panel_rows["sec_network"] = _panel_section(KEY_LEGEND_NETWORK)
	for lane in _network.get("lanes", []):
		_panel_rows["lane_" + str(lane["id"])] = _panel_swatch_row(
			_lane_row_key(str(lane["id"])), lane["color"])
	_panel_rows["spokes"] = _panel_swatch_row(KEY_LEGEND_SPOKES, PaletteLib.PANEL_LINE)
	_panel_rows["chokepoints"] = _panel_swatch_row(KEY_LEGEND_CHOKEPOINTS, PaletteLib.BAD)
	_panel_rows["sec_fleets"] = _panel_section(KEY_LEGEND_FLEETS)
	for role in LEGEND_ROLES:
		_panel_rows["role_" + role] = _panel_swatch_row(
			_role_row_key(role), _legend_role_color(role))
		# §4.7.10 (amended 2026-11-01): the row reads "<marker letter> <name>"
		# — the prefix is chart-owned, the name is the debug.role.* string.
		_panel_rows["role_" + role]["prefix"] = _role_letter(role) + " "
	_panel_rows["wrecks"] = _panel_swatch_row(KEY_LEGEND_WRECKS, PaletteLib.ACCENT)
	_panel_rows["stalls"] = _panel_swatch_row(KEY_LEGEND_STALLS, PaletteLib.BAD)
	_panel_rows["intel"] = _panel_swatch_row(KEY_LEGEND_INTEL, PaletteLib.BAD)
	_panel_rows["neutral"] = _panel_swatch_row(KEY_LEGEND_NEUTRAL,
		ChartViewLib.port_neutral_color())
	_panel_rows["hover"] = _panel_row("", false)  # value-only tooltip row
	# §4.6 interactive legend rows (amended 2026-11-01): a click shows/hides
	# what the row depicts. The children ignore the mouse, so the row box
	# receives the whole click.
	for row_id in _panel_rows:
		if not _row_clickable(str(row_id)):
			continue
		var box: Control = _panel_rows[row_id]["box"]
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.gui_input.connect(_on_row_gui_input.bind(str(row_id)))


## The row ids a click may toggle (§4.6 interactive legend rows): the four
## key-toggle rows, the network shape rows, and every lane/role row.
func _row_clickable(row_id: String) -> bool:
	if row_id in ["omni", "wind", "current", "ice", "spokes", "chokepoints",
			"wrecks", "intel", "neutral"]:
		return true
	return row_id.begins_with("lane_") or row_id.begins_with("role_")


## What a legend row depicts — `true` when shown. The toggle rows read their
## key state; every other clickable row reads the visibility filters.
func _row_shown(row_id: String) -> bool:
	match row_id:
		"omni":
			return _omni_on
		"wind":
			return _wind_on
		"current":
			return _current_on
		"ice":
			return _ice_on
		_:
			return not _layer_hidden.get(row_id, false)


## A click on a side-legend row (§4.6, amended 2026-11-01). The toggle rows
## reuse their key handlers (a rebuild); every other row flips a draw-time
## visibility filter — a redraw, never a rebuild.
func _on_row_gui_input(event: InputEvent, row_id: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	match row_id:
		"omni":
			toggle_omniscient()
		"wind":
			toggle_wind_layer()
		"current":
			toggle_current_layer()
		"ice":
			toggle_ice_layer()
		_:
			_layer_hidden[row_id] = not _layer_hidden.get(row_id, false)
			_refresh_panel()
			queue_redraw()


static func _role_letter(role: String) -> String:
	var letter := NpcFleetsLib.marker_letter(role)
	return letter if not letter.is_empty() else "·"


## The side-legend row text for a lane id: the `debug.lane.<id>` key when the
## string exists (§4.7.10 — localized §7.6 names, locale-reactive), else the
## raw `id` fallback (a missing key must not render as `<debug.lane.…>`).
static func _lane_row_key(lane_id: String) -> String:
	var key := "debug.lane." + lane_id
	return key if DataLoader.ui_strings.has(key) else lane_id


## The side-legend row key for a fleet role: the `debug.role.<role>` name
## (§4.7.10, amended 2026-11-01) when the string exists, else the bare marker
## letter (the chart prefixes the marker letter either way).
static func _role_row_key(role: String) -> String:
	var key := "debug.role." + role
	return key if DataLoader.ui_strings.has(key) else _role_letter(role)


## §4.7.10 "role-color rows": pirate wears `BAD` on its own; every other role
## marker takes its *fleet's* nation colour at draw time, so the legend row
## carries the letter in `TEXT` (the color legend is the fleet itself).
static func _legend_role_color(role: String) -> Color:
	return PaletteLib.BAD if role == "pirate" else PaletteLib.TEXT


## `true` for the i18n row families (`debug.*`/`chart.*`/`world.*` keys —
## literal keys render until the orchestrator merges the phase-6 strings).
static func _is_string_key(text: String) -> bool:
	return text.begins_with("debug.") or text.begins_with("chart.") \
		or text.begins_with("world.")


## A section header row (accent, no value).
func _panel_section(text_key: String) -> Dictionary:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", PaletteLib.ACCENT)
	label.text = I18n.t_key(text_key)
	_debug_rows.add_child(label)
	return {"label": label, "value": label, "swatch": null, "box": null,
		"key": text_key}


## A label + state-dot row (the dot is `ACCENT` when the row's thing is on).
## An empty key makes a value-only row (the hover tooltip).
func _panel_row(text_key: String, with_dot: bool) -> Dictionary:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = PaletteLib.PANEL_LINE
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if with_dot:
		box.add_child(dot)
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if _is_string_key(text_key):
		label.text = I18n.t_key(text_key)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(label)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 12)
	value.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	value.clip_text = true
	value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(value)
	_debug_rows.add_child(box)
	return {"label": label, "value": value, "swatch": dot if with_dot else null,
		"box": box, "key": text_key}


## A color-swatch + text row (lane ids, role letters, shape colors). `text`
## is either a data literal (lane id, role letter) or an i18n key.
func _panel_swatch_row(text: String, color: Color) -> Dictionary:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(8, 8)
	swatch.color = color
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(swatch)
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if _is_string_key(text):
		label.text = I18n.t_key(text)
	else:
		label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(label)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 12)
	value.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	value.clip_text = true
	value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(value)
	_debug_rows.add_child(box)
	return {"label": label, "value": value, "swatch": swatch, "box": box,
		"key": text}


## Refreshes the panel from the last build's caches (locale-safe: every i18n
## row rebinds, so a locale flip mid-session never leaves a stale language).
func _refresh_panel() -> void:
	if _debug_panel == null or _debug_rows == null:
		return
	if _panel_rows.is_empty() and _debug_active:
		_ensure_panel_rows()
	if _panel_rows.is_empty():
		return
	for row_id in _panel_rows:
		var row: Dictionary = _panel_rows[row_id]
		var key := str(row.get("key", ""))
		if _is_string_key(key):
			(row["label"] as Label).text = str(row.get("prefix", "")) \
				+ I18n.t_key(key)
	_set_dot("omni", _omni_on)
	_set_dot("wind", _wind_on)
	_set_dot("current", _current_on)
	_set_dot("ice", _ice_on)
	# Unified-movement diagnostics row: the stall census over the last
	# marker pass (`B blocked · C camping · D docked · K cooldown` counts).
	var stall_row: Dictionary = _panel_rows.get("stalls", {})
	if not stall_row.is_empty():
		var census := {}
		for entry in _fleet_markers:
			var state := str(entry.get("stall", ""))
			if not state.is_empty():
				census[state] = int(census.get(state, 0)) + 1
		var parts: Array = []
		for state in ["blocked", "camping", "docked", "cooldown"]:
			if census.has(state):
				parts.append("%s×%d" % [state, int(census[state])])
		(stall_row["value"] as Label).text = " · ".join(parts)
	# §4.6 interactive legend rows: a hidden row dims (HIDDEN_ROW_ALPHA).
	for row_id in _panel_rows:
		if not _row_clickable(str(row_id)):
			continue
		var row: Dictionary = _panel_rows[row_id]
		var shown := _row_shown(str(row_id))
		(row["box"] as Control).modulate = Color(1, 1, 1,
			1.0 if shown else HIDDEN_ROW_ALPHA)
	# Lane rows: the active variant for the viewed month (or "" for the base).
	for lane in _network.get("lanes", []):
		var row: Dictionary = _panel_rows.get("lane_" + str(lane["id"]), {})
		if row.is_empty():
			continue
		(row["value"] as Label).text = str(lane.get("active_variant", ""))
	(_panel_rows["spokes"]["value"] as Label).text = str(
		(_network.get("spokes", []) as Array).size())
	(_panel_rows["chokepoints"]["value"] as Label).text = str(
		(_network.get("chokepoints", []) as Array).size())
	var counts := _fleet_counts()
	for role in LEGEND_ROLES:
		var row: Dictionary = _panel_rows.get("role_" + role, {})
		if not row.is_empty():
			(row["value"] as Label).text = str(int(counts.get(role, 0)))
	(_panel_rows["wrecks"]["value"] as Label).text = str(_wreck_markers.size())
	var intel_text := ""
	for entry in _intel_markers:
		if str(entry.get("kind", "")) == "ring":
			intel_text = str(entry.get("port_id", ""))
		else:
			intel_text = str(entry.get("cell", ""))
	(_panel_rows["intel"]["value"] as Label).text = intel_text
	var neutral := 0
	for entry in _port_dots:
		if entry.get("neutral", false):
			neutral += 1
	(_panel_rows["neutral"]["value"] as Label).text = str(neutral)
	(_panel_rows["hover"]["value"] as Label).text = _hover_text


func _set_dot(row_id: String, on: bool) -> void:
	var row: Dictionary = _panel_rows.get(row_id, {})
	if row.is_empty() or row["swatch"] == null:
		return
	(row["swatch"] as ColorRect).color = PaletteLib.ACCENT if on \
		else PaletteLib.PANEL_LINE


## `role → live fleet count`, straight off `NpcFleets.markers()`.
func _fleet_counts() -> Dictionary:
	var out: Dictionary = {}
	for entry in _fleet_markers:
		var role := str(entry.get("role", ""))
		out[role] = int(out.get(role, 0)) + 1
	return out
