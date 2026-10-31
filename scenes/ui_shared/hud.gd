extends Control
## Shared sailing HUD (S3/S4) — docs/80-UI-UX.md §4.5, §4.3, §4.7;
## docs/90-ARCHITECTURE.md §7 ("HUD only reads GameState + EventBus signals,
## never mutates").
##
## Layout (1280×720):
##   * top bar 40px    — day · gold · morale + tier · area · [中文/EN]
##   * bottom bar 32px — provisions · water · crew · cargo · speed
##   * minimap 256×192 — a **wrap-aware 128×96-tile crop** around the fleet at
##     2 px/tile, explored tiles only; the weather label sits underneath (§4.5,
##     `20-*` §4.12). The whole world lives on the separate Chart screen (S17,
##     `80-*` §4.6, `scenes/world/chart_screen.gd`); the Phase-1 `M` enlarged
##     minimap is retired (`80-*` §4.3).
##
## **Update contract.** `_ready` reads GameState once, then every bar is
## refreshed *only* from `EventBus` signals — there is no `_process` and no
## polling anywhere in this file. Hosts that changed state without a matching
## signal call [method refresh] explicitly (movement does this: the fleet dot
## and the area label follow `GameState.world.position`, which has no signal).
##
## The HUD hosts the modal dialog queue (§4.7) so chained events from the daily
## ledger (weather damage → mutiny → desertion → greeting) are shown one at a
## time in fixed order. T9/T10 call [method show_dialogs]; results are
## delivered by each dialog's own signals (docs/90-* §7).

const PaletteLib := preload("res://scripts/palette.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
## Shared map-view rules (explored state, terrain colours, port/discovery dots):
## the minimap crop and the Chart screen must agree by construction
## (docs/80-* §4.6, docs/20-* §4.12).
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const DialogBoxScene := preload("res://scenes/ui_shared/dialog_box.tscn")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")

## docs/80-* §4.5 / §20-* §4.12: the minimap box is 256×192 px showing a
## **wrap-aware 128×96-tile crop** around the fleet at 2 px/tile.
const MINIMAP_SIZE := Vector2(256, 192)
const MINIMAP_PX_PER_TILE := 2
## The crop size in tiles, derived from the box and the pixel scale (never
## typed separately, so the two can never disagree).
const MINIMAP_CROP_TILES := Vector2i(
	int(MINIMAP_SIZE.x) / MINIMAP_PX_PER_TILE,
	int(MINIMAP_SIZE.y) / MINIMAP_PX_PER_TILE
)
## Minimap port/fleet/discovery dots are 2×2 px (§4.12).
const DOT_NORMAL := 2
## docs/80-* §4.5: "nearest known port within 16 tiles".
const AREA_RADIUS := 16
## docs/80-* §4.7: toasts are transient (2.5s), max one visible.
const TOAST_SECONDS := 2.5
## docs/80-* §4.5: "in storm it flashes (0.5s cycle)" — a *cycle* is one full
## fade-out + fade-in, so each half lasts 0.25s.
const STORM_FLASH_CYCLE_SECONDS := 0.5
const STORM_FLASH_HALF_SECONDS := STORM_FLASH_CYCLE_SECONDS * 0.5

## Emitted when the last queued dialog has been dismissed.
signal dialogs_finished
## §4.8.3 mutiny modal result: `"pay"`, `"suppress"` or `"fizzle"`. The HUD
## only renders the choice; the host (world scene) calls the matching
## `SailingSim.resolve_mutiny_*` (docs/90-* §7: the HUD never mutates state).
signal mutiny_choice(choice: String)
## Phase 3: the in-range **Explore** button was pressed (`70-*` §4.4, `80-*`
## §4.3). Same contract as [signal mutiny_choice]: the host runs the action.
signal explore_requested

@onready var _top_bar: ColorRect = $TopBar
@onready var _bottom_bar: ColorRect = $BottomBar
@onready var _day_label: Label = $TopRow/Day
@onready var _gold_label: Label = $TopRow/Gold
@onready var _morale_label: Label = $TopRow/Morale
@onready var _area_label: Label = $TopRow/Area
@onready var _provisions_label: Label = $BottomRow/Provisions
@onready var _water_label: Label = $BottomRow/Water
@onready var _crew_label: Label = $BottomRow/Crew
@onready var _cargo_label: Label = $BottomRow/Cargo
@onready var _speed_label: Label = $BottomRow/Speed
@onready var _minimap: Control = $Minimap
@onready var _minimap_title: Label = $MinimapTitle
@onready var _weather_label: Label = $Weather
@onready var _toast: PanelContainer = $Toast
@onready var _toast_label: Label = $Toast/ToastLabel
@onready var _modal_host: Control = $ModalHost
@onready var _explore_hint: Label = $ExploreHint
@onready var _explore_button: Button = $Explore

## Fleet dot position override for hosts that show the map before a run exists
## (the world scene falls back to Lisbon's berth tile). `(-1,-1)` means "read
## `GameState.world_tile()`".
var fleet_cell := Vector2i(-1, -1)

## Cached minimap crop image (docs/20-* §4.12): 256×192 px = 128×96 tiles at
## 2 px/tile around the fleet. Rebuilt from `GameState.explored_tiles` whenever
## a newly explored tile falls inside the current crop, so `_draw()` never walks
## 12k cells per frame and a normal move usually rebuilds nothing.
var _minimap_image: Image = null
var _minimap_texture: ImageTexture = null
## The crop's top-left tile for the cached image (x already normalised into
## `[0, width)`; the crop wraps, so `origin.x + crop.x` may pass the seam).
var _minimap_origin := Vector2i.ZERO
## True when [member _minimap_image] must be rebuilt from scratch on the next
## sync (first build, a fresh explored set, a map swap, or a crop move).
var _minimap_dirty := true
## World grid size the cached image was built for (a swapped map rebuilds it).
var _minimap_tiles := Vector2i.ZERO
## Number of explored tiles seen at the last rebuild; a larger count means
## something new was revealed (the explored set only ever grows within a run).
var _minimap_explored_count := -1
## Identity of the `GameState.explored_tiles` dictionary the crop was painted
## from. A new game / save load **replaces** that dict (`explored_tiles = {}`),
## so identity is what catches a reset whose size happens to match.
var _minimap_explored_ref: Dictionary = {}

## False on S4, where the port menu replaces the sea viewport (docs/80-* §4.5).
var _minimap_visible := true

## Dialog queue (§4.7): `[{key, values}]`, one modal at a time.
var _dialog_queue: Array = []
var _dialog = null
## §4.8.3 mutiny modal (a `confirm_dialog` with Pay/Suppress), its offer copy
## and the resolved choice. `_mutiny_dialog == _dialog` while it is up.
var _mutiny_dialog = null
var _mutiny_offer: Dictionary = {}
## Toast generation counter so a replaced toast does not hide its successor.
var _toast_generation := 0
## Storm-flash tween (created/destroyed by [_apply_weather]).
var _weather_tween: Tween = null
## The weather value currently rendered ("calm"|"fair"|"strong"|"storm"), so a
## test can assert the label follows `day_advanced` and not GameState.
var _displayed_weather: String = ""


func _ready() -> void:
	_top_bar.color = PaletteLib.PANEL_BG
	_bottom_bar.color = PaletteLib.PANEL_BG
	for label in [
		_day_label, _gold_label, _morale_label, _area_label, _provisions_label,
		_water_label, _crew_label, _cargo_label, _speed_label, _weather_label,
	]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_toast.visible = false
	_toast_label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_toast.add_theme_stylebox_override("panel", _toast_style())
	# The bars/minimap swallow clicks so a click on the HUD never steps the
	# fleet; the root stays IGNORE so the rest of the map receives clicks.
	_minimap.mouse_filter = Control.MOUSE_FILTER_STOP
	_minimap_title.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_explore_hint.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_explore_hint.text = I18n.t_key("discovery.something_near")
	_explore_button.text = I18n.t_key("discovery.explore")
	_explore_button.custom_minimum_size.y = float(PaletteLib.BUTTON_H)
	_explore_button.pressed.connect(_on_explore_pressed)
	_apply_minimap_rect()

	# The only update path for the bars (docs/80-* §7 acceptance).
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.port_entered.connect(_on_port_entered)

	refresh()


func _unhandled_input(event: InputEvent) -> void:
	# A modal owns all input while it is up (docs/80-* §6), including the
	# HUD's own hotkeys.
	if has_modal():
		return
	# No minimap on S4 (the port menu replaces the sea viewport), but the
	if not _minimap_visible:
		return


# --- Public API (hosts + later tasks) ---------------------------------------

## Re-reads everything once. Called from `_ready` ("refresh on open", the one
## allowed full read) and from `locale_changed`. Hosts never call it from their
## movement path: the bars exist only for EventBus-driven updates (docs/80-* §7),
## and position-derived bits go through [method set_fleet_cell].
func refresh() -> void:
	_refresh_top()
	_refresh_bottom()
	_refresh_weather()
	_sync_minimap_image()
	queue_redraw()


## Sets the fleet dot source and refreshes the position-derived parts only:
## the area label and the minimap. The bars are deliberately **not** touched
## here — they change only on EventBus signals (docs/80-* §7), so a host that
## moves the fleet cannot smuggle in a poll.
func set_fleet_cell(cell: Vector2i) -> void:
	fleet_cell = cell
	_area_label.text = _area_text()
	# Exploration moves with the fleet, so the chart cache is refreshed here
	# (still once per step, not per frame).
	_sync_minimap_image()
	queue_redraw()


## Phase 3: shows/hides the in-range Explore affordance (`70-*` §4.4). The
## world scene drives it from `WorldMap.something_near()` on every move/open,
## so the button only ever exists while a discovery is within Chebyshev 3.
func set_explore_available(available: bool) -> void:
	_explore_hint.visible = available
	_explore_button.visible = available
	if available:
		_explore_hint.text = I18n.t_key("discovery.something_near")
		_explore_button.text = I18n.t_key("discovery.explore")


## `true` while the Explore affordance is on screen (test hook).
func explore_available() -> bool:
	return _explore_button.visible


## The Explore button's current label (test hook).
func explore_button_text() -> String:
	return _explore_button.text


## Clicks the Explore button (test hook for the `E`-equivalent path).
func press_explore() -> void:
	if _explore_button != null and not _explore_button.disabled:
		_explore_button.pressed.emit()


func _on_explore_pressed() -> void:
	explore_requested.emit()


func toggle_minimap() -> void:
	# Phase 4 retired the `M` enlarged minimap (`80-*` §4.3): the Chart screen
	# (S17) replaced it. A no-op seam, because stale callers and the old
	# Phase-1 suites still call it; `chart_screen.gd#toggle_chart` is the real
	# whole-world view now.
	pass


## Queues one or more modals, shown strictly one at a time in the given order
## (docs/80-* §4.7). Each entry is `{"key": "<ui key>", "values": {...}}`.
## Entries queued while a dialog is open are appended, never shown twice.
func show_dialogs(entries: Array) -> void:
	for entry in entries:
		if entry is Dictionary:
			_dialog_queue.append(entry)
	_show_next_dialog()


## Convenience for one message.
func show_dialog(key: String, values: Dictionary = {}) -> void:
	show_dialogs([{"key": key, "values": values}])


## Drops every queued dialog and closes the one on screen without showing the
## rest. Used when a higher-priority modal takes over the screen (S9 game over:
## the run is over, so a pending storm-damage report must not underlay it —
## §4.7 "never simultaneously"). `dialogs_finished` still fires so a host
## waiting to route is not left hanging.
func clear_dialogs() -> void:
	_dialog_queue.clear()
	var open = _dialog
	_dialog = null
	_mutiny_dialog = null
	_mutiny_offer = {}
	if open != null:
		if open.has_method("close"):
			open.close()
		elif open.has_method("cancel"):
			open.cancel()
		open.queue_free()
	dialogs_finished.emit()


## The dialog currently on screen (null when none). Tests/T9 read this.
func current_dialog():
	return _dialog


## The §4.8.3 mutiny offer currently on screen (`{}` when none). Read-only.
func current_mutiny_offer() -> Dictionary:
	if _mutiny_dialog == null or not _mutiny_dialog.is_open():
		return {}
	return _mutiny_offer


## Disables the buttons the offer cannot satisfy: "Pay" needs `can_pay`,
## "Suppress" needs `can_suppress` (§4.8.3).
func _apply_mutiny_offer() -> void:
	if _mutiny_dialog == null:
		return
	var confirm: Button = _mutiny_dialog.get_node("Center/Panel/Margin/Body/Footer/Confirm")
	var cancel: Button = _mutiny_dialog.get_node("Center/Panel/Margin/Body/Footer/Cancel")
	confirm.disabled = not bool(_mutiny_offer.get("can_pay", false))
	cancel.disabled = not bool(_mutiny_offer.get("can_suppress", false))
	confirm.text = I18n.fmt(
		"world.mutiny.pay", {"gold": int(_mutiny_offer.get("cost", 0))}
	)
	cancel.text = I18n.t_key("world.mutiny.suppress")


## True while a modal dialog is on screen or still queued; the world scene
## stops accepting movement input then (docs/90-* §11).
func has_modal() -> bool:
	return _dialog != null or not _dialog_queue.is_empty()


## Transient bottom-center toast (2.5s, max one; docs/80-* §4.7).
func toast_text(text: String) -> void:
	_toast_generation += 1
	var generation := _toast_generation
	_toast_label.text = text
	_toast.visible = true
	await get_tree().create_timer(TOAST_SECONDS).timeout
	# A newer toast replaced this one; leave it alone.
	if generation == _toast_generation:
		_toast.visible = false


## Toast from a ui_strings key. Returns false (and shows nothing) when the key
## does not exist yet, so a not-yet-merged key never spams errors.
func toast_key(key: String, values: Dictionary = {}) -> bool:
	if not DataLoader.ui_strings.has(key):
		return false
	toast_text(I18n.fmt(key, values))
	return true


## Formatted numbers in the bars; the L10nString supplies the unit.
static func format_thousands(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		out = digits[index] + out
		count += 1
		if count % 3 == 0 and index > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out


## docs/20-* §4.8 tier id for a morale value.
static func morale_tier(value: int) -> String:
	if value >= 80:
		return "excellent"
	if value >= 60:
		return "good"
	if value >= 40:
		return "strained"
	if value >= 20:
		return "dangerous"
	return "mutinous"


## Tier color (docs/80-* §4.5, docs/20-* §4.8): green when healthy, yellow
## under 40 (`WARN`), red under 20 (`BAD`). "Strained" (40–59) is still a
## healthy tier, so it keeps `GOOD` — the doc's rule is a two-step warning,
## not a third colour.
static func morale_color(value: int) -> Color:
	match morale_tier(value):
		"excellent", "good", "strained":
			return PaletteLib.GOOD
		"dangerous":
			return PaletteLib.WARN
		_:
			return PaletteLib.BAD


# --- Bars ------------------------------------------------------------------

func _refresh_top() -> void:
	var has_game: bool = not GameState.player.is_empty()
	if GameState.day > 0:
		_day_label.text = I18n.fmt("world.day", {"day": GameState.day})
	else:
		_day_label.text = I18n.fmt("world.day", {"day": "-"})

	_gold_label.text = I18n.fmt(
		"ui.gold_amount", {"gold": format_thousands(GameState.gold)}
	)

	if has_game:
		_morale_label.text = "%s (%s)" % [
			I18n.fmt("world.morale", {"amount": GameState.morale}),
			I18n.t_key("world.morale.%s" % morale_tier(GameState.morale)),
		]
		_morale_label.add_theme_color_override(
			"font_color", morale_color(GameState.morale)
		)
	else:
		_morale_label.text = I18n.fmt("world.morale", {"amount": "-"})
		_morale_label.add_theme_color_override("font_color", PaletteLib.TEXT)

	_area_label.text = _area_text()


func _refresh_bottom() -> void:
	var has_game: bool = not GameState.fleet.is_empty()
	if not has_game:
		_provisions_label.text = I18n.fmt("world.provisions", {"amount": "-"})
		_water_label.text = I18n.fmt("world.water", {"amount": "-"})
		_crew_label.text = I18n.fmt("world.crew", {"crew": "-", "max": "-"})
		_cargo_label.text = I18n.fmt(
			"world.cargo", {"amount": "-", "capacity": "-"}
		)
		_speed_label.text = I18n.fmt("world.speed", {"speed": "-"})
		return

	_provisions_label.text = I18n.fmt(
		"world.provisions", {"amount": FleetLib.supplies("provisions")}
	)
	_water_label.text = I18n.fmt(
		"world.water", {"amount": FleetLib.supplies("water")}
	)
	var crew_max := 0
	var used := 0
	for ship in GameState.fleet:
		crew_max += FleetLib.ship_stat(ship, "crew_max")
		used += FleetLib.used_capacity(ship)
	_crew_label.text = I18n.fmt(
		"world.crew", {"crew": FleetLib.total_crew(), "max": crew_max}
	)
	_cargo_label.text = I18n.fmt(
		"world.cargo", {"amount": used, "capacity": FleetLib.fleet_capacity()}
	)
	_speed_label.text = I18n.fmt(
		"world.speed", {"speed": SailingSimLib.effective_speed()}
	)


func _refresh_weather() -> void:
	_apply_weather(str(GameState.world.get("weather", SailingSimLib.DEFAULT_WEATHER)))


## Renders one weather value. Split from [_refresh_weather] so the label logic
## has exactly one GameState read (at the signal handler) and the flash is a
## pure visibility effect.
func _apply_weather(weather: String) -> void:
	_displayed_weather = weather
	_weather_label.text = I18n.t_key("world.weather.%s" % weather)
	# §4.5: in storm the weather glyph flashes (0.5s cycle); otherwise steady.
	_weather_label.add_theme_color_override(
		"font_color",
		PaletteLib.BAD if weather == "storm" else PaletteLib.TEXT
	)
	if weather == "storm":
		_start_storm_flash()
	else:
		_stop_storm_flash()


## Looping 0.5s flash *cycle* for the storm state (§4.5): 0.25s out, 0.25s in.
## The node is the placeholder glyph (default font), never a texture
## (docs/80-* §4.8), and the tween is purely visual — it reads no game state.
func _start_storm_flash() -> void:
	if _weather_tween != null and _weather_tween.is_valid():
		return
	_weather_tween = create_tween().set_loops()
	_weather_tween.tween_property(
		_weather_label, "modulate:a", 0.25, STORM_FLASH_HALF_SECONDS
	)
	_weather_tween.tween_property(
		_weather_label, "modulate:a", 1.0, STORM_FLASH_HALF_SECONDS
	)


## True while the storm glyph is flashing (tests read this instead of polling
## the tween's internals).
func is_storm_flashing() -> bool:
	return _weather_tween != null and _weather_tween.is_valid()


## The weather string the HUD is currently displaying, without touching
## GameState again (test helper for the "signal-only" contract).
func displayed_weather_key() -> String:
	return _displayed_weather


func _stop_storm_flash() -> void:
	if _weather_tween != null and _weather_tween.is_valid():
		_weather_tween.kill()
	_weather_tween = null
	if _weather_label != null:
		_weather_label.modulate.a = 1.0


## Current area: the docked port, else the nearest known port within 16 tiles,
## else `world.open_sea` (docs/80-* §4.5).
func _area_text() -> String:
	var port_id := ""
	if GameState.current_port is String and not (GameState.current_port as String).is_empty():
		port_id = GameState.current_port
	else:
		port_id = _nearest_known_port()
	if port_id.is_empty():
		return I18n.t_key("world.open_sea")
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return I18n.t_key("world.open_sea")
	return I18n.t(port.get("name", {}))


func _nearest_known_port() -> String:
	var map = DataLoader.map
	if map == null:
		return ""
	var here: Vector2i = fleet_cell if fleet_cell.x >= 0 else GameState.world_tile()
	var best := ""
	var best_distance := AREA_RADIUS + 1
	for port_id in GameState.known_ports:
		var cell: Vector2i = map.port_cell(str(port_id))
		if cell.x < 0:
			continue
		var distance: int = maxi(absi(cell.x - here.x), absi(cell.y - here.y))
		if distance <= AREA_RADIUS and distance < best_distance:
			best_distance = distance
			best = str(port_id)
	return best


# --- Signals (docs/90-* §5.1) ----------------------------------------------

func _on_day_advanced(_new_day: int) -> void:
	# The ledger ran before this signal, so morale/weather/speed may have
	# changed too.
	_refresh_top()
	_refresh_bottom()
	_refresh_weather()


func _on_gold_changed(_new_gold: int) -> void:
	_refresh_top()


func _on_fleet_changed() -> void:
	_refresh_bottom()
	_refresh_top()


func _on_locale_changed(_locale: String) -> void:
	refresh()
	# The minimap caption is localised too (`world.minimap`).
	_apply_minimap_rect()
	# The Phase-3 Explore affordance re-binds with the rest of the HUD.
	if _explore_button.visible:
		set_explore_available(true)
	# The mutiny dialog re-binds its own labels on the same signal; re-apply the
	# formatted Pay price (with `{gold}` filled) after it, next idle frame.
	if _mutiny_dialog != null:
		call_deferred("_apply_mutiny_offer")


func _on_port_entered(_port_id: String) -> void:
	_refresh_top()
	queue_redraw()


# --- Minimap (docs/20-* §4.12, docs/80-* §4.5) ----------------------------

## Places the fixed 256×192 box (16px margin under the 40px top bar, §4.8) and
## the weather/title captions underneath it. Phase 4 has one mode: the crop
## (`M`'s 512×384 enlarged view is retired, `80-*` §4.3).
func _apply_minimap_rect() -> void:
	var size := MINIMAP_SIZE
	_minimap.size = size
	_minimap.position = Vector2(PaletteLib.MARGIN, PaletteLib.TOP_BAR_H + PaletteLib.MARGIN)
	_weather_label.position = _minimap.position + Vector2(0, size.y + PaletteLib.BASE_UNIT)
	_minimap_title.position = _weather_label.position + Vector2(0, 24)
	_minimap_title.text = I18n.t_key("world.minimap")


## **Phase-4 compatibility shim.** The enlarged `M` minimap is gone (`80-*`
## §4.3: the Chart screen replaced it), but `scenes/world/world_map.gd`'s
## `_modal_open()` still asks (`has_method("is_minimap_enlarged") and
## is_minimap_enlarged()`). That file's movement/input section is owned by task
## H in this same wave, so this returns a constant `false` instead of deleting
## the seam out from under it: the call site is harmless and the master can drop
## both together after H merges. Always false — there is no enlarged mode.
func is_minimap_enlarged() -> bool:
	return false


## Hides the minimap (and its weather/title captions) on screens where the
## viewport is not the sea map — S4 replaces it with the port menu
## (docs/80-* §4.5 "S4 HUD: same top/bottom bars, viewport replaced").
func set_minimap_visible(value: bool) -> void:
	_minimap_visible = value
	_minimap.visible = value
	_weather_label.visible = value
	_minimap_title.visible = value
	queue_redraw()


func is_minimap_visible() -> bool:
	return _minimap_visible


## The minimap box's screen rect. Tests read it instead of recomputing the
## layout rules.
func minimap_rect() -> Rect2:
	return Rect2(_minimap.position, _minimap.size)


## Source pixels per tile in the minimap crop (docs/20-* §4.12: 2 px).
func minimap_px_per_tile() -> int:
	return MINIMAP_PX_PER_TILE


## The crop's size in tiles (128×96 at 2 px/tile over the 256×192 box).
func minimap_crop_tiles() -> Vector2i:
	return MINIMAP_CROP_TILES


## World tile coordinate of the crop's top-left column/row. `x` is normalised
## into `[0, width)`; the crop wraps, so `column + i` may pass the seam.
func minimap_crop_origin() -> Vector2i:
	return _minimap_origin


## The ordered world column for each of the [constant MINIMAP_CROP_TILES] crop
## columns, wrap-aware (`20-*` §4.1) and normalised into `[0, width)`: column 65
## of a fleet at `x = 2159` is `x = 0`, not `x = 2160`. Column 0 is the leftmost
## pixel column. Exposed so a test can assert the dateline rule without sampling
## pixels.
func minimap_crop_columns() -> Array:
	var out: Array = []
	var tiles := _map_size()
	if _fleet_source_cell().x < 0 or tiles.x <= 0:
		return out
	var origin := _crop_origin(_fleet_source_cell(), tiles)
	for column in MINIMAP_CROP_TILES.x:
		out.append(posmod(origin.x + column, tiles.x))
	return out


## `true` when `cell` is inside the current crop (wrap-aware on x).
func minimap_contains(cell: Vector2i) -> bool:
	return _crop_index_of(cell) != Vector2i(-1, -1)


# --- Minimap image cache (docs/20-* §4.12) --------------------------------

## Rebuilds the 256×192 crop image when the fleet moved, the map changed, the
## explored set grew, or a new run replaced it. Otherwise it is a no-op: called
## from [method refresh] and [method set_fleet_cell], i.e. at most once per
## movement step, never per frame.
func _sync_minimap_image() -> void:
	var map = DataLoader.map
	if map == null:
		_minimap_image = null
		_minimap_texture = null
		_minimap_tiles = Vector2i.ZERO
		_minimap_dirty = true
		return
	var tiles := Vector2i(int(map.width), int(map.height))
	var cell := _fleet_source_cell()
	var origin := _crop_origin(cell, tiles)
	# A swapped map, a new run's explored set, a rebuild request, or the fleet
	# leaving the crop's top-left all invalidate the image. A growing explored
	# set is caught by the count (explored_tiles only ever grows within a run).
	var explored_count: int = ChartViewLib.explored_count()
	var replaced: bool = not is_same(_minimap_explored_ref, GameState.explored_tiles)
	if _minimap_image == null or _minimap_tiles != tiles or _minimap_dirty \
			or origin != _minimap_origin or explored_count != _minimap_explored_count \
			or replaced:
		_minimap_tiles = tiles
		_minimap_origin = origin
		_minimap_explored_count = explored_count
		_minimap_explored_ref = GameState.explored_tiles
		_minimap_dirty = false
		if _minimap_image == null \
				or _minimap_image.get_size() != Vector2i(MINIMAP_SIZE):
			_minimap_image = Image.create_empty(
				int(MINIMAP_SIZE.x), int(MINIMAP_SIZE.y), false, Image.FORMAT_RGBA8
			)
			_minimap_texture = ImageTexture.create_from_image(_minimap_image)
		_paint_minimap(map, origin)
		_minimap_texture.update(_minimap_image)
	queue_redraw()


## Paints all 128×96 crop tiles. Unexplored tiles stay `PANEL_BG` (fog), which
## is exactly the Chart's unknown-tile colour — both views go through
## [ChartView.is_explored]/[ChartView.index_color] so the content is identical
## by construction, not by two matching implementations.
func _paint_minimap(map, origin: Vector2i) -> void:
	_minimap_image.fill(ChartViewLib.UNKNOWN_COLOR)
	var colors: Array = ChartViewLib.palette_colors(map)
	for row in MINIMAP_CROP_TILES.y:
		var y: int = origin.y + row
		if y < 0 or y >= int(map.height):
			continue
		for column in MINIMAP_CROP_TILES.x:
			var x := posmod(origin.x + column, int(map.width))
			if not ChartViewLib.is_explored(Vector2i(x, y), map):
				continue
			_minimap_image.fill_rect(
				Rect2i(
					column * MINIMAP_PX_PER_TILE, row * MINIMAP_PX_PER_TILE,
					MINIMAP_PX_PER_TILE, MINIMAP_PX_PER_TILE
				),
				ChartViewLib.index_color(colors, map, x, y)
			)


func _draw() -> void:
	if not _minimap_visible:
		return
	var rect := Rect2(_minimap.position, _minimap.size)
	draw_rect(rect, PaletteLib.PANEL_BG, true)
	if _minimap_texture == null:
		draw_rect(rect, PaletteLib.PANEL_LINE, false, 2.0)
		return
	# 1 screen pixel per image pixel: the image already is 2 px/tile.
	draw_texture_rect(_minimap_texture, rect, false)

	var dot := Vector2(DOT_NORMAL, DOT_NORMAL)
	# Known ports: 2×2 px nation-coloured dots (§4.12).
	for entry in minimap_known_ports():
		var at := _crop_screen_pos(entry["cell"], dot)
		if at.x < 0.0:
			continue
		draw_rect(Rect2(rect.position + at, dot), entry["color"], true)

	# Found discoveries whose tile is explored: 2×2 px `ACCENT` dots (§4.12).
	for entry in minimap_discovery_dots():
		var at := _crop_screen_pos(entry["cell"], dot)
		if at.x < 0.0:
			continue
		draw_rect(Rect2(rect.position + at, dot), PaletteLib.ACCENT, true)

	# Fleet: a 2×2 px white dot at the crop's centre (§4.12).
	var fleet := _fleet_source_cell()
	var centre := Vector2(MINIMAP_CROP_TILES.x / 2, MINIMAP_CROP_TILES.y / 2) \
		* float(MINIMAP_PX_PER_TILE)
	draw_rect(Rect2(rect.position + centre, dot), Color.WHITE, true)

	draw_rect(rect, PaletteLib.PANEL_LINE, false, 2.0)


## Screen offset (inside the box) of a 2×2 marker centred on `cell`, or
## `(-1,-1)` when the cell is outside the crop (nothing to draw then).
func _crop_screen_pos(cell: Vector2i, dot: Vector2) -> Vector2:
	var index := _crop_index_of(cell)
	if index == Vector2i(-1, -1):
		return Vector2(-1, -1)
	var tile := float(MINIMAP_PX_PER_TILE)
	return Vector2(index) * tile + (Vector2(tile, tile) - dot) * 0.5


## Crop-local (column, row) of `cell`, or `(-1,-1)` when it is outside.
func _crop_index_of(cell: Vector2i) -> Vector2i:
	var map = DataLoader.map
	if map == null:
		return Vector2i(-1, -1)
	var width := int(map.width)
	var row := cell.y - _minimap_origin.y
	if row < 0 or row >= MINIMAP_CROP_TILES.y:
		return Vector2i(-1, -1)
	var column := posmod(cell.x - _minimap_origin.x, maxi(width, 1))
	if column >= MINIMAP_CROP_TILES.x:
		return Vector2i(-1, -1)
	return Vector2i(column, row)


## Top-left tile of the crop: centred on the fleet, x wrapping (`20-*` §4.12:
## "a wrap-aware 128×96-tile crop around the fleet"). A fleet at `x = 2159`
## therefore samples `x ∈ [2095..2159] ∪ [0..62]` with no void at the seam.
func _crop_origin(cell: Vector2i, tiles: Vector2i) -> Vector2i:
	if tiles.x <= 0:
		return cell
	var x := posmod(cell.x - MINIMAP_CROP_TILES.x / 2, tiles.x)
	if tiles.y <= 0:
		return Vector2i(x, cell.y)
	# y does not wrap: the crop is clamped to the latitude edges instead.
	var y := mini(cell.y - MINIMAP_CROP_TILES.y / 2, tiles.y - MINIMAP_CROP_TILES.y)
	return Vector2i(x, maxi(y, 0))


func _fleet_source_cell() -> Vector2i:
	return fleet_cell if fleet_cell.x >= 0 else GameState.world_tile()


func _map_size() -> Vector2i:
	var map = DataLoader.map
	if map == null:
		return Vector2i.ZERO
	return Vector2i(int(map.width), int(map.height))


## The port dots the minimap draws: `[{port_id, cell, color}]` for **known**
## ports only, from the shared [ChartView] layer list — so the Chart and the
## minimap can never disagree about which ports are known or what colour they
## are (`20-*` §4.12, `80-*` §4.6).
func minimap_known_ports() -> Array:
	var out: Array = []
	for entry in ChartViewLib.port_dots(DataLoader.map):
		out.append({
			"port_id": str(entry["port_id"]),
			"cell": entry["cell"],
			"berth_cell": entry.get("berth_cell", entry["cell"]),
			"color": entry["color"],
		})
	return out


## The discovery dots the minimap draws (`[{id, cell}]`, found + explored only).
func minimap_discovery_dots() -> Array:
	return ChartViewLib.lead_cells(DataLoader.map)


## Color of the minimap pixel for `cell`: the explored terrain colour, or
## `PANEL_BG` when the cell is unexplored **or outside the crop** (the minimap
## is a crop, so it has no opinion about a tile it does not show). Test hook for
## the explored-only rule; reads the same cache [_draw] draws.
func minimap_pixel_color(cell: Vector2i) -> Color:
	var map = DataLoader.map
	if _minimap_image == null or map == null:
		return PaletteLib.PANEL_BG
	var index := _crop_index_of(cell)
	if index == Vector2i(-1, -1):
		return PaletteLib.PANEL_BG
	return _minimap_image.get_pixelv(index * MINIMAP_PX_PER_TILE)


## Size of the cached minimap image in pixels (the locked 256×192 crop box).
func minimap_image_size() -> Vector2i:
	return _minimap_image.get_size() if _minimap_image != null else Vector2i.ZERO


## Chart colors per terrain kind (docs/80-* §4.8 palette) — the shared
## implementation, so tests can assert the minimap and the Chart agree.
static func minimap_terrain_color(kind: String) -> Color:
	return ChartViewLib.terrain_color(kind)



# --- Dialog queue (docs/80-* §4.7, docs/90-* §7) ---------------------------

func _show_next_dialog() -> void:
	if _dialog != null:
		return
	if _dialog_queue.is_empty():
		dialogs_finished.emit()
		return
	var entry: Dictionary = _dialog_queue.pop_front()
	if bool(entry.get("mutiny", false)):
		_show_mutiny_dialog(entry)
		return
	var dialog = DialogBoxScene.instantiate()
	dialog.name = "DialogBox"
	_modal_host.add_child(dialog)
	_dialog = dialog
	dialog.closed.connect(_on_dialog_closed)
	dialog.open_key(str(entry.get("key", "")), entry.get("values", {}))


## §4.8.3 mutiny modal: one message (`world.mutiny.text`) with the two
## resolutions as buttons. The buttons are disabled from the offer, and the
## result leaves through [signal mutiny_choice] — the HUD itself never changes
## crew, gold or morale.
func _show_mutiny_dialog(entry: Dictionary) -> void:
	_mutiny_offer = entry.get("offer", {}).duplicate()
	var dialog = ConfirmScene.instantiate()
	dialog.name = "MutinyDialog"
	_modal_host.add_child(dialog)
	_dialog = dialog
	_mutiny_dialog = dialog
	dialog.closed.connect(_on_mutiny_dialog_closed)
	dialog.open_key(
		str(entry.get("key", "world.mutiny.text")),
		entry.get("values", {}),
		"world.mutiny.pay",
		"world.mutiny.suppress"
	)
	_apply_mutiny_offer()


func _on_mutiny_dialog_closed(accepted: bool) -> void:
	if _dialog == null:
		return
	var offer := _mutiny_offer
	var choice := "pay" if accepted else "suppress"
	# A disabled button cannot be pressed, but a stray key (Enter/N) can reach
	# a disabled control: route an impossible choice to the §4.8.3 fizzle.
	if accepted and not bool(offer.get("can_pay", false)):
		choice = "fizzle"
	elif not accepted and not bool(offer.get("can_suppress", false)):
		choice = "fizzle"
	_mutiny_dialog = null
	_mutiny_offer = {}
	# Emit **before** clearing the modal: the host's resolution may produce a
	# follow-up message (the §4.8.3 fizzle report), which then queues behind the
	# closed mutiny dialog and is shown as the next modal — never lost to the
	# "queue drained" signal that `_close_dialog()` can raise.
	mutiny_choice.emit(choice)
	_close_dialog()


func _on_dialog_closed() -> void:
	_close_dialog()


## Shared teardown: drop the current modal, then show the next queued one (never
## two at once, but the chain reads as one sequence — §4.7).
func _close_dialog() -> void:
	if _dialog == null:
		return
	_dialog.queue_free()
	_dialog = null
	_show_next_dialog()


func _toast_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	style.set_content_margin_all(PaletteLib.BASE_UNIT)
	return style
