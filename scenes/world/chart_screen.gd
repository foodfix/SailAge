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
## W5-D: the appointed-voyage gate/route engine behind the §4.10.4
## 委任航行 entry (docs/80-* §4.10.4).
const AutopilotLib := preload("res://scripts/world/autopilot.gd")

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
## W5-D (docs/80-* §4.15 `sail.autopilot.*` family): the §4.10.4 chart
## entry — select a known port → 委任航行.
const KEY_APPOINT := "sail.autopilot.appoint"
const KEY_APPOINT_CANCEL := "sail.autopilot.cancel"
const KEY_APPOINT_HUD_BAR := "sail.autopilot.hud.bar"
const KEY_APPOINT_GATED := "sail.autopilot.gated"
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
	_close_port_panel()
	_close_appoint_panel()
	_port_payloads.clear()
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
	# Open: the panel owns all input (§4.6); `Esc` closes — the pinned port
	# report first (§4.6 Phase-8), the appoint panel likewise (§4.10.4), the
	# chart itself on a later press.
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		if _appoint_panel != null and _appoint_panel.visible:
			_close_appoint_panel()
			return
		if _port_panel != null and _port_panel.visible:
			_close_port_panel()
			return
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
			# §4.6 Phase-8: a left press that lands on a port is a CLICK —
			# it toggles the pinned report and never starts a pan. A press
			# elsewhere closes the pinned panel, then pans as before.
			# §4.10.4 (W5-D): in PLAYER mode the same click on a KNOWN port
			# opens the appointed-voyage panel instead (the chart's 委任航行
			# entry; `_port_dots` is the known-port set in player mode, so a
			# hit is always a known port). The debug branch is unchanged.
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				var width := _world_image.get_width() \
					if _world_image != null else 4320
				var u := (mb.position - _view_rect().position) \
					/ (_scale * _zoom)
				var cell := Vector2i(posmod(int(floor(u.x)), width),
					int(floor(u.y)))
				var port_id := _port_hit(mb.position, cell)
				if not port_id.is_empty():
					if _debug_active:
						_open_port_panel(port_id)
					else:
						_open_appoint_panel(port_id)
					_dragging = false
					return
			if mb.pressed and _port_panel != null \
					and _port_panel.visible:
				_close_port_panel()
			if mb.pressed and _appoint_panel != null \
					and _appoint_panel.visible:
				_close_appoint_panel()
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


## The port under `at` (screen px), or "" — the §4.6 Phase-8 hit rule:
## within 8 px of the port dot, or standing on its shore/berth tile. The
## hovered-tile form needs `cell` (the inverse-mapped tile) so a deep-zoom
## click away from the tiny dot still lands.
func _port_hit(at: Vector2, cell := Vector2i(-1, -1)) -> String:
	var best := ""
	var best_d := 8.0
	for entry in _port_dots:
		var d := _to_screen(entry["cell"]).distance_to(at)
		if d < best_d:
			best_d = d
			best = str(entry.get("port_id", ""))
		var berth: Vector2i = entry.get("berth_cell", Vector2i(-1, -1))
		if cell.x >= 0 and (cell == (entry["cell"] as Vector2i) \
				or cell == berth):
			return str(entry.get("port_id", ""))
	return best


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
	# The §4.6 Phase-8 port hit: the hovered dot/tile's port (may be empty).
	var port_id := _port_hit(at, cell)
	var text := ""
	if not ships.is_empty():
		# Localized blocks (unified-movement amendment; the §4.7.10 rule —
		# debug surfaces speak the ui_strings locale): `id` stays raw (an
		# identifier), every other term resolves — `debug.role.*`,
		# the nation's L10n name, `debug.stall.*`, `debug.info.*` labels,
		# the mooring/destination port's L10n name. `holds` shows only
		# where it means something (blocked).
		_ensure_hover_window()
		var font := _hover_window_label.get_theme_font("font")
		var font_size := _hover_window_label.get_theme_font_size(
			"font_size")
		var max_w := minf(HOVER_WINDOW_MAX_W,
			get_viewport_rect().size.x * 0.5)
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
			line += "\n  " + _annotate_raw_line(
				str(ship.get("dbg", "")), "state", false,
				font, font_size, max_w)
			var raw2 := str(ship.get("dbg2", ""))
			if not raw2.is_empty():
				line += "\n  " + _annotate_raw_line(raw2, "accrual",
					false, font, font_size, max_w)
			var raw3 := str(ship.get("dbg3", ""))
			if not raw3.is_empty():
				line += "\n  " + _annotate_raw_line(raw3, "journey",
					true, font, font_size, max_w)
			# A blank line keeps stacked fleet blocks apart (§4.6).
			text += line + "\n\n"
	else:
		# No fleet on the tile: the nearest wreck / intel entry (the bare
		# port-id fallback is gone — ports report through the §4.6 Phase-8
		# port block below).
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
		text = best
	# The §4.6 Phase-8 port block: appended after any fleet blocks — docked
	# fleets stand on the port's berth tile, so a port hover reports both.
	if not port_id.is_empty():
		var port_block := _port_summary_text(port_id)
		if not port_block.is_empty():
			text += ("\n\n" if not text.is_empty() else "") + port_block
	if text != _hover_text:
		# The side row carries the FIRST line only — the full multi-ship
		# report lives in the floating window.
		_hover_text = text.split("\n")[0] if not text.is_empty() else ""
		_refresh_panel()
	_show_hover_window(text, at)


# --- Localized raw lines (§4.6, amended 2026-11-02) --------------------------

## The raw hover payload keys that carry a localized gloss
## (`debug.raw.f.<key>`, ui_strings.json — §4.7.10).
const RAW_GLOSS_KEYS: Array[String] = ["cell", "dwell", "day", "legs", "ti",
	"holds", "carry", "mark", "now", "pend", "last", "lastd", "moved",
	"skip", "committed", "budget", "pipe", "cd", "leg0", "dest", "mooring"]

## The journey payload's `ev=` tail spans tokens with its own event
## grammar — split off before the generic `key=value` pass. (The
## `[raw*]` telemetry names live in the §4.6 prose and `markers()`,
## never in the window.)
const EV_TAG := "ev="


## Renders one payload line fully localized (§4.6, amended 2026-11-02):
## `<section title> · <gloss> <value> · …` — every `key=value` token
## becomes a `gloss value` field (ids replaced by their localized names
## via `_raw_value_text`, `_raw_value_hint` appending the `pend`/`mark`
## hints, non-key continuation tokens (`leg0`'s `ti/walked_len` tail)
## extending the previous field, the journey payload's trailing `ev=`
## ring becoming one field per event). The fields then greedy-fill
## physical lines to `max_w`, measured with the window's own font — a
## wrap lands BETWEEN fields, never mid-gloss or mid-value.
func _annotate_raw_line(raw: String, section: String, with_ev: bool,
		font: Font, font_size: int, max_w: float) -> String:
	var head := raw
	var ev := ""
	if with_ev:
		var cut := raw.find(" " + EV_TAG)
		if cut >= 0:
			head = raw.substr(0, cut)
			ev = raw.substr(cut + 1 + EV_TAG.length())
	var fields: Array = []
	for token in head.split(" ", false):
		var eq := token.find("=")
		var key := token.substr(0, eq) if eq > 0 else ""
		if key in RAW_GLOSS_KEYS:
			var value := token.substr(eq + 1)
			var field := "%s %s" % [I18n.t_key("debug.raw.f." + key),
				_raw_value_text(key, value)]
			field += _raw_value_hint(key, value)
			fields.append(field)
		elif not fields.is_empty():
			# Continuation of the previous field's value.
			fields[fields.size() - 1] += " " + token
		else:
			fields.append(token)
	if not ev.is_empty():
		var first_ev := true
		for ev_text in _annotate_ev_events(ev):
			# The gloss labels the first event; the rest read as its
			# continuations (each still wraps as its own field).
			fields.append(((I18n.t_key("debug.raw.f.ev") + " ")
				if first_ev else "") + str(ev_text))
			first_ev = false
	# Greedy fill: a physical line carries as many fields as fit the
	# §4.6 fold cap; the wrap always falls between two fields.
	var lines: Array = []
	var cur := I18n.t_key("debug.raw.sec." + section)
	for field in fields:
		var candidate := cur + " · " + str(field)
		if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT,
				-1, font_size).x > max_w:
			lines.append(cur)
			cur = str(field)
		else:
			cur = candidate
	lines.append(cur)
	return "\n  ".join(lines)


## The displayed value of one raw field (§4.6, amended 2026-11-02): ids
## render as their localized names when they resolve, else the raw id
## (the legend's fallback rule) — `dest`/`mooring` ports, `leg0`'s lane/
## spoke id (its `[a..b]R<>` tail keeps the numbers), `skip` reasons.
## Everything else passes through verbatim.
func _raw_value_text(key: String, value: String) -> String:
	if key == "dest" or key == "mooring":
		return _display(_port_name(value), value)
	if key == "leg0":
		var br := value.find("[")
		var id := value.substr(0, br) if br >= 0 else value
		return _display(_leg_name(id), id) \
			+ (value.substr(br) if br >= 0 else "")
	if key == "skip":
		var l10n := "debug.raw.skip." + value
		if DataLoader.ui_strings.has(l10n):
			return I18n.t_key(l10n)
	return value


## The value hint of one raw field (§4.6, amended 2026-11-02): `pend < 0`
## ⇒ frozen (the mark is ahead of the clock — the §4.6 discriminator),
## `mark < 0` ⇒ unset. "" when nothing applies.
func _raw_value_hint(key: String, value: String) -> String:
	if (key == "pend" or key == "mark") and value.is_valid_float() \
			and float(value) < 0.0:
		return " (%s)" % I18n.t_key("debug.raw.hint."
			+ ("frozen" if key == "pend" else "no_mark"))
	return ""


## The ev ring (`spawn@1 dep a->b@3 arr x@12 drop wedge:lane ti=2@15 …`)
## localized, one STRING per event (each becomes its own wrap field).
## Event boundaries: every event's last token carries the `@<day>` stamp
## (`_note_event` stamps the whole text).
func _annotate_ev_events(ev: String) -> Array:
	var events: Array = []
	var cur_tokens: Array = []
	for tok in ev.split(" ", false):
		cur_tokens.append(tok)
		if tok.contains("@"):
			events.append(_annotate_ev_event(cur_tokens))
			cur_tokens = []
	if not cur_tokens.is_empty():
		events.append(_annotate_ev_event(cur_tokens))
	return events


## One raw ev event (its tokens) → one localized string; the `@<day>`
## stamps ride their tokens untouched. Event verbs (`debug.raw.ev.*`),
## the `a->b` port pairs, the port after a bare `arr`, the
## `wedge|leg|seam:<id>` causes and the `ti=<n>` detail all localize;
## unknown tokens pass through verbatim.
func _annotate_ev_event(tokens: Array) -> String:
	var out: Array = []
	var prev_arr := false
	for tok: String in tokens:
		var head := tok
		var stamp := ""
		var at := tok.rfind("@")
		if at > 0:
			head = tok.substr(0, at)
			stamp = tok.substr(at)
		var text := ""
		if head.contains("->"):
			var arrow := head.find("->")
			text = "%s→%s" % [_display_port(head.substr(0, arrow)),
				_display_port(head.substr(arrow + 2))]
		elif prev_arr:
			text = _display_port(head)
		elif head == "dep":
			text = I18n.t_key("debug.raw.ev.dep")
		elif head == "depX":
			text = I18n.t_key("debug.raw.ev.depx")
		elif head == "arr":
			text = I18n.t_key("debug.raw.ev.arr")
		elif head == "drop":
			text = I18n.t_key("debug.raw.ev.drop")
		elif head == "spawn":
			text = I18n.t_key("debug.raw.ev.spawn")
		elif head.begins_with("wedge:"):
			text = "%s:%s" % [I18n.t_key("debug.raw.ev.wedge"),
				_display_leg(head.substr(6))]
		elif head.begins_with("leg:"):
			text = "%s:%s" % [I18n.t_key("debug.raw.ev.leg"),
				_display_leg(head.substr(4))]
		elif head.begins_with("seam:"):
			text = "%s:%s" % [I18n.t_key("debug.raw.ev.seam"),
				_display_leg(head.substr(5))]
		elif head.begins_with("ti="):
			text = "%s%s" % [I18n.t_key("debug.raw.ev.ti"), head.substr(3)]
		else:
			text = head
		out.append(text + stamp)
		prev_arr = head == "arr"
	return " ".join(out)


## The localized port name for a raw port id ("" when the id resolves to
## no known port).
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


## A display value with raw-id fallback: the localized name when it
## resolved, else the raw id itself.
func _display(name: String, raw_id: String) -> String:
	return name if not name.is_empty() else raw_id


## A display port id (localized name, else the raw id).
func _display_port(port_id: String) -> String:
	return _display(_port_name(port_id), port_id)


## A display leg id (localized name, else the raw id).
func _display_leg(id: String) -> String:
	return _display(_leg_name(id), id)


## The floating hover window (unified-movement amendment): a bordered
## panel at the cursor, mouse-transparent, clipped to the viewport.
## §4.6 (amended 2026-11-02): fleet reports pre-wrap at field boundaries
## to `min(HOVER_WINDOW_MAX_W, viewport width × 0.5)` px and read at a
## dedicated 13 px font (smaller than the default 16 — stacked reports
## must stay compact).
const HOVER_WINDOW_MAX_W := 560.0
const HOVER_WINDOW_FONT_SIZE := 13
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
	_hover_window_label.add_theme_font_size_override("font_size",
		HOVER_WINDOW_FONT_SIZE)
	_hover_window.add_child(_hover_window_label)
	add_child(_hover_window)
	_hover_window.visible = false


## Shows/hides + positions the floating window (clamped to the viewport).
## §4.6 (amended 2026-11-02): fleet reports pre-wrap at field boundaries
## (`_annotate_raw_line`), so the label keeps autowrap OFF and the panel
## simply re-fits — and shrinks — to its natural size on every show,
## never relying on Label wrap minimums (whose stale-width shape once
## blew the panel up to a screen-filling empty block).
func _show_hover_window(text: String, at: Vector2) -> void:
	_ensure_hover_window()
	if text.is_empty():
		_hover_window.visible = false
		return
	_hover_window_label.text = text
	_hover_window.reset_size()
	_hover_window.visible = true
	var view := get_viewport_rect().size
	var size := _hover_window.size
	var pos := at + Vector2(14.0, 14.0)
	_hover_window.position = pos.clamp(Vector2.ZERO,
		(view - size).clamp(Vector2.ZERO, view))


# --- Port debug hover + panel (`80-*` §4.6 Phase-8, docs/95-* §7) -----------

## The pinned port report panel's fixed width (the fold target; the text
## pre-wraps to it with the panel's own font — the hover window's
## no-autowrap discipline, `80-*` §4.6: Label wrap minimums once blew a
## panel up to a screen-filling empty block) and its height cap (a fraction
## of the viewport — the world stays visible behind it).
const PORT_PANEL_W := 440.0
const PORT_PANEL_H_RATIO := 0.62
const PORT_PANEL_FONT_SIZE := 13
## The fold width minus the stylebox margins and the scrollbar slack.
const PORT_PANEL_FOLD_W := PORT_PANEL_W - 36.0

## The payload cache (port_id → payload), rebuilt per `_rebuild` — stocks
## and ledgers move on a day tick, so a stale snapshot must not survive one.
var _port_payloads: Dictionary = {}
## The pinned panel (built lazily like the hover window) and its port.
var _port_panel: PanelContainer = null
var _port_panel_label: Label = null
var _port_panel_port := ""

## --- Appointed-voyage panel (§4.10.4, W5-D; player mode) --------------------

## The player-mode 委任航行 panel: a KNOWN-port click opens it, the appoint
## button carries the `sail.autopilot` gate (disabled + the skill_gates
## reason), a success flips the panel to the HUD-line info + cancel. Built
## lazily in code (the hover/port-panel pattern); debug mode never opens it,
## so the pinned debug report behavior is byte-identical.
var _appoint_panel: PanelContainer = null
var _appoint_name: Label = null
var _appoint_status: Label = null
var _appoint_button: Button = null
var _appoint_cancel_button: Button = null
var _appoint_port := ""


## The hover summary block (docs/95-* §7.1): the ≤ 6 localized lines. ""
## for an unknown port.
func _port_summary_text(port_id: String) -> String:
	var p := _port_payload(port_id)
	if p.is_empty():
		return ""
	return "\n".join(_port_summary_lines(p))


## The cached payload for `port_id` ("" when the port is unknown) — one
## `port_debug_payload` read per build, not per mouse motion.
func _port_payload(port_id: String) -> Dictionary:
	if _port_payloads.has(port_id):
		return _port_payloads[port_id]
	var payload: Dictionary = ChartViewLib.port_debug_payload(port_id,
		_fleet_markers, DataLoader.map)
	_port_payloads[port_id] = payload
	return payload


## The summary lines shared by the hover block and the panel's 概览 section.
func _port_summary_lines(p: Dictionary) -> Array:
	var port: Dictionary = DataLoader.get_port(str(p.get("id", "")))
	if port.is_empty():
		return []
	var lines: Array = []
	# 1 · name (L10n) + raw id (ids never localize, §4.7.10).
	lines.append("%s %s" % [I18n.t(port.get("name", {})), p["id"]])
	# 2 · nation · class · capital · alignment · derived dev.
	var parts: Array = []
	if bool(p.get("neutral", false)):
		parts.append(I18n.t_key("debug.port.neutral"))
	else:
		var nation: Dictionary = DataLoader.nations.get(
			str(p.get("nation_id", "")), {})
		if nation is Dictionary and not nation.is_empty():
			parts.append(I18n.t(nation.get("name", {})))
	parts.append(I18n.t_key("debug.port.class.protected"
		if bool(p.get("protected", false))
		else "debug.port.class.contestable"))
	if not str(p.get("capital_of", "")).is_empty():
		parts.append(I18n.t_key("debug.port.f.capital"))
	var alignment := str(p.get("alignment", ""))
	if alignment.is_empty():
		parts.append(I18n.t_key("debug.port.unaligned"))
	else:
		parts.append(I18n.t_key("debug.port.f.alignment") + " "
			+ _port_nation_name(alignment))
	parts.append(I18n.t_key("debug.port.f.dev") + " " + str(p.get("dev", 0)))
	lines.append(" · ".join(parts))
	# 3 · the market pulse + the active demand event.
	var market: Dictionary = p.get("market", {})
	var pulse: Array = [
		"%s %d" % [I18n.t_key("debug.port.f.produces"),
			int(market.get("produces", 0))],
		"%s %d" % [I18n.t_key("debug.port.f.demands"),
			int(market.get("demands", 0))],
		"%s %d" % [I18n.t_key("debug.port.f.starved"),
			int(market.get("starved", 0))],
		"%s %d" % [I18n.t_key("debug.port.f.capped"),
			int(market.get("capped", 0))],
	]
	var event: Dictionary = market.get("event", {})
	pulse.append(I18n.t_key("debug.port.f.event") + " "
		+ (I18n.t_key("debug.port.f.event_none") if event.is_empty()
			else "%s (%s)" % [I18n.t(event.get("name", {})),
				I18n.fmt("debug.port.f.remaining",
					{"days": int(event.get("days_left", 0))})]))
	lines.append(" · ".join(pulse))
	# 4 · the fleet counts off the same markers pass the map drew.
	lines.append("%s %d · %s %d" % [
		I18n.t_key("debug.port.f.docked"), (p.get("docked", []) as Array).size(),
		I18n.t_key("debug.port.f.inbound"), (p.get("inbound", []) as Array).size()])
	# 5 · the player line: tariff badge · discount · month allowance · closed.
	var player: Dictionary = p.get("player", {})
	var pp: Array = [I18n.t_key("debug.port.f.tariff") + " "
		+ _port_tariff_text(player)]
	pp.append("%s −%d%%" % [I18n.t_key("debug.port.f.discount"),
		int(player.get("discount_percent", 0))])
	if bool(player.get("month_capped", false)):
		pp.append("%s %d/%dg" % [I18n.t_key("debug.port.f.month_invested"),
			int(player.get("month_invested", 0)),
			ChartViewLib.AllegianceLib.MONTHLY_INVEST_CAP])
	if bool(player.get("closed", false)):
		pp.append(I18n.t_key("debug.port.closed_for_player"))
	lines.append(" · ".join(pp))
	# 6 · the harbor tiles (grep-compatible with a fleet's 所在格).
	var berth: Vector2i = p.get("berth_cell", Vector2i(-1, -1))
	var shore: Vector2i = p.get("shore_cell", Vector2i(-1, -1))
	lines.append("%s (%d,%d) · %s (%d,%d)" % [
		I18n.t_key("debug.port.f.berth_cell"), berth.x, berth.y,
		I18n.t_key("debug.port.f.shore_cell"), shore.x, shore.y])
	return lines


## A nation id → localized name (the raw id fallback, the legend rule).
func _port_nation_name(nation_id: String) -> String:
	var nation: Dictionary = DataLoader.nations.get(nation_id, {})
	if nation is Dictionary and not nation.is_empty():
		return I18n.t(nation.get("name", {}))
	return nation_id


## The tariff badge (the `market.tax.badge.*` wording — mille → badge key;
## 2000 splits foreign vs unallied on the alignment).
func _port_tariff_text(player: Dictionary) -> String:
	var mille := int(player.get("tariff_mille", 0))
	if mille <= 0:
		return I18n.t_key("market.tax.badge.exempt")
	if mille <= 500:
		return I18n.t_key("market.tax.badge.in_sphere")
	return I18n.t_key("market.tax.badge.unallied"
		if str(player.get("alignment", "")).is_empty()
		else "market.tax.badge.foreign")


## A good id → localized name (raw id fallback).
func _port_good_name(good_id: String) -> String:
	var good: Dictionary = DataLoader.get_good(good_id)
	if good.is_empty():
		return good_id
	return I18n.t(good.get("name", {}))


## The full report text (the panel's body, docs/95-* §7.2): the eight
## `debug.port.sec.*` sections, one line per field — pre-folded by
## `_fold_text` to the panel width (the no-autowrap discipline).
func _port_panel_text(port_id: String) -> String:
	var p := _port_payload(port_id)
	if p.is_empty():
		return ""
	var out: Array = _port_summary_lines(p)
	# 市场 — every listed port-good, one line (produces first stock desc,
	# demands by factor desc; the §4.2 marginal prices).
	var market_lines: Array = []
	for row in p.get("market_rows", []):
		var line := "%s %s %d/%d · %s ×%0.2f · %s %d" % [
			_port_good_name(str(row.get("good_id", ""))),
			I18n.t_key("debug.port.side.prod" if str(row.get("side", "")) == "prod"
				else "debug.port.side.demand"),
			int(row.get("stock", 0)), int(row.get("capacity", 0)),
			I18n.t_key("debug.port.factor"),
			float(row.get("factor_units", 1000)) / 1000.0,
			I18n.t_key("debug.port.buy"), int(row.get("buy", 0)),
		]
		if int(row.get("sell", -1)) >= 0:
			line += " · %s %d" % [I18n.t_key("debug.port.sell"),
				int(row.get("sell", 0))]
		else:
			line += " · %s" % I18n.t_key("debug.port.no_buy")
		if bool(row.get("surged", false)):
			line += " · %s" % I18n.t_key("debug.port.surge")
		market_lines.append(line)
	# 账本 — per-nation raw → effective (owner ×1.25), the 5,000g line state.
	var ledger_lines: Array = []
	var ledger: Dictionary = p.get("ledger", {})
	if bool(ledger.get("protected", false)):
		ledger_lines.append(I18n.t_key("debug.port.ledger_none"))
	else:
		for entry in ledger.get("entries", []):
			ledger_lines.append("%s %d (%s %d)" % [
				_port_nation_name(str(entry.get("nation_id", ""))),
				int(entry.get("raw", 0)),
				I18n.t_key("debug.port.f.effective"),
				int(entry.get("effective", 0))])
		ledger_lines.append("%s %d · %s" % [
			I18n.t_key("debug.port.f.total"), int(ledger.get("total", 0)),
			I18n.t_key("debug.port.f.aligned" if bool(ledger.get("aligned", false))
				else "debug.port.f.unaligned")])
	# 设施 — open/closed right now + the hours window.
	var facility_lines: Array = []
	for facility in p.get("facilities", []):
		var window: Dictionary = facility.get("window", {})
		var hours := "24h" if window.is_empty() \
			else "%s–%s" % [window.get("open", ""), window.get("close", "")]
		facility_lines.append("%s %s %s" % [
			I18n.t_key("port." + str(facility.get("id", ""))),
			I18n.t_key("debug.port.open" if bool(facility.get("open", false))
				else "debug.port.closed"),
			hours])
	var shipyard_ships: Array = p.get("shipyard_ships", [])
	if not shipyard_ships.is_empty():
		facility_lines.append("%s: %s" % [I18n.t_key("debug.port.f.ships"),
			", ".join(shipyard_ships)])
	var equipment: Array = p.get("equipment", [])
	if not equipment.is_empty():
		facility_lines.append("%s: %s" % [I18n.t_key("debug.port.f.equipment"),
			", ".join(equipment)])
	# 舰队 — docked then inbound, one line each (the raw blocks stay
	# tile-hover-only).
	var fleet_lines: Array = []
	for docked in p.get("docked", []):
		fleet_lines.append(_port_fleet_line(docked, true))
	for inbound in p.get("inbound", []):
		fleet_lines.append(_port_fleet_line(inbound, false))
	# 几何 — tiles, lat/lon, band.
	var berth: Vector2i = p.get("berth_cell", Vector2i(-1, -1))
	var shore: Vector2i = p.get("shore_cell", Vector2i(-1, -1))
	var lat := float(p.get("lat", 0.0))
	var lon := float(p.get("lon", 0.0))
	var geometry_lines: Array = [
		"%s (%d,%d) · %s (%d,%d)" % [
			I18n.t_key("debug.port.f.berth_cell"), berth.x, berth.y,
			I18n.t_key("debug.port.f.shore_cell"), shore.x, shore.y],
		"%s %0.2f°%s %0.2f°%s · %s %s" % [
			I18n.t_key("debug.port.f.latlon"), absf(lat),
			"N" if lat >= 0.0 else "S", absf(lon),
			"E" if lon >= 0.0 else "W",
			I18n.t_key("debug.port.f.band"), str(p.get("band", ""))],
	]
	# 数据 — raw id lists + the dev floor vs the derived dev.
	var data_lines: Array = [
		"%s: %s" % [I18n.t_key("debug.port.f.produces"),
			", ".join(p.get("produces", []))],
		"%s: %s" % [I18n.t_key("debug.port.f.demands"),
			", ".join(p.get("demands", []))],
	]
	var sphere: Array = p.get("sphere", [])
	data_lines.append("%s: %s" % [I18n.t_key("debug.port.f.sphere"),
		", ".join(sphere) if not sphere.is_empty() else "-"])
	data_lines.append("%s %d · %s %d" % [
		I18n.t_key("debug.port.f.dev_floor"), int(p.get("dev_floor", 0)),
		I18n.t_key("debug.port.f.dev"), int(p.get("dev", 0))])
	# 玩家 — rep · permits · title bonus (+ the closed state rides the 概览).
	var player: Dictionary = p.get("player", {})
	var player_lines: Array = []
	var alignment := str(p.get("alignment", ""))
	if not alignment.is_empty():
		player_lines.append("%s(%s) %+d" % [I18n.t_key("debug.port.f.rep"),
			_port_nation_name(alignment), int(player.get("rep", 0))])
	player_lines.append("%s ×%0.2f" % [I18n.t_key("debug.port.f.title"),
		float(player.get("title_units", 1000)) / 1000.0])
	var permit_text := "%s %s · %s %s" % [
		I18n.t_key("debug.port.f.permits"),
		I18n.t_key("debug.port.permit_home")
			+ ("✓" if bool(player.get("permit_home", false)) else "✗"),
		I18n.t_key("debug.port.permit_foreign")
			+ ("✓" if bool(player.get("permit_foreign", false)) else "✗"),
		I18n.t_key("debug.port.permit_void")
			if bool(player.get("permit_void", false)) else ""]
	player_lines.append(permit_text.strip_edges())
	for section in [
		["debug.port.sec.overview", []],
		["debug.port.sec.market", market_lines],
		["debug.port.sec.ledger", ledger_lines],
		["debug.port.sec.facilities", facility_lines],
		["debug.port.sec.fleets", fleet_lines],
		["debug.port.sec.geometry", geometry_lines],
		["debug.port.sec.data", data_lines],
		["debug.port.sec.player", player_lines],
	]:
		# The 概览 body is the summary lines already in `out` — every other
		# non-empty section prints its title first.
		var body: Array = section[1]
		if body.is_empty():
			continue
		if str(section[0]) != "debug.port.sec.overview":
			out.append(I18n.t_key(str(section[0])))
		out.append_array(body)
	return "\n".join(out)


## One 舰队 section line: `id · role · nation · dwell-deadline` (docked)
## or `id · role · nation` (inbound) — the same localization rules as the
## hover window's fleet blocks.
func _port_fleet_line(marker: Dictionary, docked: bool) -> String:
	var parts: Array = [str(marker.get("id", "")),
		I18n.t_key("debug.role." + str(marker.get("role", "")))]
	var nation := str(marker.get("nation_id", ""))
	if not nation.is_empty():
		parts.append(_port_nation_name(nation))
	if docked:
		parts.append(I18n.t_key("debug.raw.f.dwell") + " "
			+ str(int(marker.get("dwell", 0))))
	return " · ".join(parts)


## Lazily builds the pinned panel (a bordered panel like the hover window,
## but interactive — the ScrollContainer must own its wheel events).
func _ensure_port_panel() -> void:
	if _port_panel != null:
		return
	_port_panel = PanelContainer.new()
	_port_panel.name = "PortPanel"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(PaletteLib.PANEL_BG, 0.94)
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(1.0)
	style.set_content_margin_all(6.0)
	_port_panel.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_port_panel_label = Label.new()
	_port_panel_label.name = "Report"
	_port_panel_label.add_theme_font_size_override("font_size",
		PORT_PANEL_FONT_SIZE)
	_port_panel_label.add_theme_color_override("font_color", PaletteLib.TEXT)
	# The hover-window discipline: autowrap stays OFF — the fold is done in
	# `_fold_text` with the panel's own font, so no Label wrap minimum can
	# ever drive the panel's geometry.
	_port_panel_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_port_panel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_port_panel_label)
	_port_panel.add_child(scroll)
	add_child(_port_panel)
	_port_panel.visible = false


## Greedy word-fold to `max_w`, measured with `font` (the §4.6 wrap
## discipline — a wrap always falls between two words, never mid-word).
## Continuation lines indent two spaces (the raw-section convention).
func _fold_text(text: String, font: Font, font_size: int,
		max_w: float) -> String:
	var out: Array = []
	for line in text.split("\n"):
		var cur := ""
		for word in str(line).split(" ", false):
			var candidate := word if cur.is_empty() else cur + " " + word
			var width := font.get_string_size(candidate,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			if cur.is_empty() or width <= max_w:
				cur = candidate
			else:
				out.append(cur)
				cur = "  " + word
		out.append(cur)
	return "\n".join(out)


## Opens (or toggles closed) the pinned report at the port's screen position.
## `toggle` false re-renders in place (the rebuild refresh path).
func _open_port_panel(port_id: String, toggle := true) -> void:
	_ensure_port_panel()
	if toggle and _port_panel.visible and _port_panel_port == port_id:
		_close_port_panel()
		return
	var text := _port_panel_text(port_id)
	if text.is_empty():
		# An unknown port (or a build with no map) closes rather than
		# leaving a stale report pinned.
		_close_port_panel()
		return
	_port_panel_port = port_id
	# The geometry is set EXPLICITLY — never from a Label wrap minimum:
	# fold to the panel width with the panel's own font, then size the
	# panel to the folded height, capped (the world stays visible).
	var font := _port_panel_label.get_theme_font("font")
	var font_size := _port_panel_label.get_theme_font_size("font_size")
	var folded := _fold_text(text, font, font_size, PORT_PANEL_FOLD_W)
	_port_panel_label.text = folded
	var view := get_viewport_rect().size
	var line_h := font.get_height(font_size)
	var natural := float(folded.split("\n").size()) * line_h + 14.0
	_port_panel.size = Vector2(PORT_PANEL_W,
		minf(natural, view.y * PORT_PANEL_H_RATIO))
	_port_panel.visible = true
	# Clamp the position next to the port dot.
	var dot := Vector2.ZERO
	for entry in _port_dots:
		if str(entry.get("port_id", "")) == port_id:
			dot = _to_screen(entry["cell"])
			break
	var pos := dot + Vector2(14.0, 14.0)
	_port_panel.position = pos.clamp(Vector2.ZERO,
		(view - _port_panel.size).clamp(Vector2.ZERO, view))


func _close_port_panel() -> void:
	_port_panel_port = ""
	if _port_panel != null:
		_port_panel.visible = false


## --- Appointed-voyage panel (§4.10.4; docs/50-* gates renderer) -------------

## Builds the player-mode 委任航行 panel once (the hover/port-panel pattern:
## code-built, autowrap discipline, explicit geometry).
func _ensure_appoint_panel() -> void:
	if _appoint_panel != null:
		return
	_appoint_panel = PanelContainer.new()
	_appoint_panel.name = "AppointPanel"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(PaletteLib.PANEL_BG, 0.94)
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(1.0)
	style.set_content_margin_all(8.0)
	_appoint_panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.name = "Rows"
	box.add_theme_constant_override("separation", 6)
	_appoint_name = Label.new()
	_appoint_name.add_theme_font_size_override("font_size", 16)
	_appoint_name.add_theme_color_override("font_color", PaletteLib.TEXT)
	_appoint_name.autowrap_mode = TextServer.AUTOWRAP_OFF
	_appoint_status = Label.new()
	_appoint_status.add_theme_font_size_override("font_size", 13)
	_appoint_status.add_theme_color_override("font_color", PaletteLib.WARN)
	_appoint_status.autowrap_mode = TextServer.AUTOWRAP_OFF
	_appoint_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_appoint_button = Button.new()
	_appoint_button.text = I18n.t_key(KEY_APPOINT)
	_appoint_button.custom_minimum_size = Vector2(160, PaletteLib.BUTTON_H * 0.7)
	_appoint_button.pressed.connect(_on_appoint_pressed)
	_appoint_cancel_button = Button.new()
	_appoint_cancel_button.text = I18n.t_key(KEY_APPOINT_CANCEL)
	_appoint_cancel_button.custom_minimum_size = Vector2(140,
		PaletteLib.BUTTON_H * 0.7)
	_appoint_cancel_button.pressed.connect(_on_appoint_cancel_pressed)
	row.add_child(_appoint_button)
	row.add_child(_appoint_cancel_button)
	box.add_child(_appoint_name)
	box.add_child(_appoint_status)
	box.add_child(row)
	_appoint_panel.add_child(box)
	add_child(_appoint_panel)
	_appoint_panel.visible = false


## Opens (or toggles closed) the 委任航行 panel at the port's screen position.
## Always reads the LIVE gate + appointment state.
func _open_appoint_panel(port_id: String, toggle := true) -> void:
	_ensure_appoint_panel()
	if toggle and _appoint_panel.visible and _appoint_port == port_id:
		_close_appoint_panel()
		return
	_appoint_port = port_id
	_refresh_appoint_panel()
	if _appoint_panel.visible:
		return
	var dot := Vector2.ZERO
	for entry in _port_dots:
		if str(entry.get("port_id", "")) == port_id:
			dot = _to_screen(entry["cell"])
			break
	_appoint_panel.reset_size()
	var view := get_viewport_rect().size
	var pos := dot + Vector2(14.0, 14.0)
	_appoint_panel.position = pos.clamp(Vector2.ZERO,
		(view - _appoint_panel.size).clamp(Vector2.ZERO, view))
	_appoint_panel.visible = true


## Re-reads the gate + appointment into the panel: name line, status line
## (the gate reason when the appoint button is disabled, the HUD bar line
## when this port is already appointed to), and the button states.
func _refresh_appoint_panel() -> void:
	if _appoint_panel == null or _appoint_port.is_empty():
		return
	var port: Dictionary = DataLoader.get_port(_appoint_port)
	var name_text := _appoint_port
	if not port.is_empty():
		name_text = I18n.t(port.get("name", {})) + " " + _appoint_port
	_appoint_name.text = name_text
	var verdict: Dictionary = AutopilotLib.gate(_appoint_port)
	var appointed_here: bool = AutopilotLib.appointed() \
		and AutopilotLib.dest_port_id() == _appoint_port
	_appoint_button.visible = not appointed_here
	_appoint_cancel_button.visible = appointed_here
	if appointed_here:
		# §4.10.4: a success (or a re-open over the standing appointment)
		# shows the HUD-line info (destination / ETA).
		var steps := AutopilotLib.route()
		var days := ceili(AutopilotLib.eta_days(steps)) \
				if not steps.is_empty() else 0
		_appoint_status.add_theme_color_override("font_color",
			PaletteLib.TEXT)
		_appoint_status.text = I18n.fmt(KEY_APPOINT_HUD_BAR,
			{"port": I18n.t(port.get("name", {})) if not port.is_empty()
				else _appoint_port, "days": days})
		return
	var reason: String = AutopilotLib.reason_text(verdict)
	if not bool(verdict.get("ok", false)):
		_appoint_button.disabled = true
		if not reason.is_empty():
			_appoint_status.add_theme_color_override("font_color",
				PaletteLib.WARN)
			_appoint_status.text = I18n.fmt(KEY_APPOINT_GATED,
				{"reason": reason})
		else:
			_appoint_status.text = ""
		return
	_appoint_button.disabled = false
	_appoint_status.add_theme_color_override("font_color", PaletteLib.TEXT)
	_appoint_status.text = ""


## The 委任航行 action: gate → appoint → the panel flips to the HUD-line
## info (§4.10.4). A refused appoint (no sea route — a data-broken edge)
## leaves the panel disabled with the gate reason empty.
func _on_appoint_pressed() -> void:
	var result: Dictionary = AutopilotLib.appoint(_appoint_port)
	if bool(result.get("ok", false)):
		_refresh_appoint_panel()
	else:
		_appoint_button.disabled = true


func _on_appoint_cancel_pressed() -> void:
	# The panel's cancel is a manual cancel (§4.19 "any manual input
	# cancels"; §4.10.4 "Cancel returns control immediately").
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	_refresh_appoint_panel()


func _close_appoint_panel() -> void:
	_appoint_port = ""
	if _appoint_panel != null:
		_appoint_panel.visible = false


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
	if _appoint_panel != null and _appoint_panel.visible:
		_refresh_appoint_panel()


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
		_close_port_panel()
	# Stocks/ledgers/fleets move between builds — the port payload cache
	# (and an open report) must re-read after every trigger.
	_port_payloads.clear()
	if _port_panel != null and _port_panel.visible \
			and not _port_panel_port.is_empty():
		_open_port_panel(_port_panel_port, false)
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
