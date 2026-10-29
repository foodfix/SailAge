extends Control
## Shared sailing HUD (S3/S4) — docs/80-UI-UX.md §4.5, §4.3, §4.7;
## docs/90-ARCHITECTURE.md §7 ("HUD only reads GameState + EventBus signals,
## never mutates").
##
## Layout (1280×720):
##   * top bar 40px    — day · gold · morale + tier · area · [中文/EN]
##   * bottom bar 32px — provisions · water · crew · cargo · speed
##   * minimap 256×192 (2px per tile, explored tiles only), `M` enlarges it to
##     512×384 centered; weather label sits underneath (§4.5).
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
const DialogBoxScene := preload("res://scenes/ui_shared/dialog_box.tscn")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")

## docs/80-* §4.5: minimap 256×192 (2 px/tile); `M` → 512×384 centered.
const MINIMAP_NORMAL := Vector2(256, 192)
const MINIMAP_ENLARGED := Vector2(512, 384)
## Minimap port/fleet dots are 2×2 px (§4.12), in both minimap modes.
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

@onready var _top_bar: ColorRect = $TopBar
@onready var _bottom_bar: ColorRect = $BottomBar
@onready var _day_label: Label = $TopRow/Day
@onready var _gold_label: Label = $TopRow/Gold
@onready var _morale_label: Label = $TopRow/Morale
@onready var _area_label: Label = $TopRow/Area
@onready var _lang_button: Button = $TopRow/LangButton
@onready var _provisions_label: Label = $BottomRow/Provisions
@onready var _water_label: Label = $BottomRow/Water
@onready var _crew_label: Label = $BottomRow/Crew
@onready var _cargo_label: Label = $BottomRow/Cargo
@onready var _speed_label: Label = $BottomRow/Speed
@onready var _minimap: Control = $Minimap
@onready var _weather_label: Label = $Weather
@onready var _toast: PanelContainer = $Toast
@onready var _toast_label: Label = $Toast/ToastLabel
@onready var _modal_host: Control = $ModalHost

## Fleet dot position override for hosts that show the map before a run exists
## (the world scene falls back to Lisbon's harbor tile). `(-1,-1)` means "read
## `GameState.world_tile()`".
var fleet_cell := Vector2i(-1, -1)

## Minimap state (`M` toggle, docs/80-* §4.3).
var _minimap_enlarged := false
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
	_lang_button.custom_minimum_size.y = PaletteLib.TOP_BAR_H
	_lang_button.text = I18n.t_key("ui.language_toggle")
	_lang_button.pressed.connect(_on_language_pressed)
	_toast.visible = false
	_toast_label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_toast.add_theme_stylebox_override("panel", _toast_style())
	# The bars/minimap swallow clicks so a click on the HUD never steps the
	# fleet; the root stays IGNORE so the rest of the map receives clicks.
	_minimap.mouse_filter = Control.MOUSE_FILTER_STOP
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
	if event.is_action_pressed("toggle_minimap"):
		get_viewport().set_input_as_handled()
		toggle_minimap()
		return
	if event.is_action_pressed("toggle_locale"):
		get_viewport().set_input_as_handled()
		I18n.toggle_locale()


# --- Public API (hosts + later tasks) ---------------------------------------

## Re-reads everything once. Called from `_ready` ("refresh on open", the one
## allowed full read) and from `locale_changed`. Hosts never call it from their
## movement path: the bars exist only for EventBus-driven updates (docs/80-* §7),
## and position-derived bits go through [method set_fleet_cell].
func refresh() -> void:
	_refresh_top()
	_refresh_bottom()
	_refresh_weather()
	queue_redraw()


## Sets the fleet dot source and refreshes the position-derived parts only:
## the area label and the minimap. The bars are deliberately **not** touched
## here — they change only on EventBus signals (docs/80-* §7), so a host that
## moves the fleet cannot smuggle in a poll.
func set_fleet_cell(cell: Vector2i) -> void:
	fleet_cell = cell
	_area_label.text = _area_text()
	queue_redraw()


func toggle_minimap() -> void:
	_minimap_enlarged = not _minimap_enlarged
	_apply_minimap_rect()
	queue_redraw()


func is_minimap_enlarged() -> bool:
	return _minimap_enlarged


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
	_lang_button.text = I18n.t_key("ui.language_toggle")
	refresh()
	# The mutiny dialog re-binds its own labels on the same signal; re-apply the
	# formatted Pay price (with `{gold}` filled) after it, next idle frame.
	if _mutiny_dialog != null:
		call_deferred("_apply_mutiny_offer")


func _on_port_entered(_port_id: String) -> void:
	_refresh_top()
	queue_redraw()


func _on_language_pressed() -> void:
	I18n.toggle_locale()


# --- Minimap (docs/20-* §4.12, docs/80-* §4.5) ----------------------------

func _apply_minimap_rect() -> void:
	var size := MINIMAP_ENLARGED if _minimap_enlarged else MINIMAP_NORMAL
	_minimap.size = size
	if _minimap_enlarged:
		# Centered in the 1280×720 viewport.
		_minimap.position = (get_viewport_rect().size - size) * 0.5
	else:
		# 16px margin under the 40px top bar (docs/80-* §4.8 sizing grid).
		_minimap.position = Vector2(PaletteLib.MARGIN, PaletteLib.TOP_BAR_H + PaletteLib.MARGIN)
	_weather_label.position = _minimap.position + Vector2(0, size.y + PaletteLib.BASE_UNIT)


func _draw() -> void:
	var rect := Rect2(_minimap.position, _minimap.size)
	draw_rect(rect, PaletteLib.PANEL_BG, true)
	var map = DataLoader.map
	if map == null:
		draw_rect(rect, PaletteLib.PANEL_LINE, false, 2.0)
		return
	var scale: float = rect.size.x / float(map.width)
	var tile := Vector2(scale, scale)

	# Explored tiles only (§4.12); unexplored stays PANEL_BG (fog).
	for cell in GameState.explored_tiles:
		if not (cell is Vector2i):
			continue
		var kind: String = map.terrain_kind(cell)
		draw_rect(Rect2(rect.position + Vector2(cell) * scale, tile), _terrain_color(kind), true)

	# Known ports: 2×2 px nation-colored dots (§4.12 fixes the size; enlarged
	# mode changes tile density, not the dot size).
	var dot := DOT_NORMAL
	for port_id in GameState.known_ports:
		var cell: Vector2i = map.port_cell(str(port_id))
		if cell.x < 0:
			continue
		var port: Dictionary = DataLoader.get_port(str(port_id))
		var nation: Dictionary = DataLoader.get_nation(str(port.get("nation_id", "")))
		var color := PaletteLib.nation_color(str(nation.get("color", "#ffffff")))
		draw_rect(Rect2(
			rect.position + Vector2(cell) * scale + (tile - Vector2(dot, dot)) * 0.5,
			Vector2(dot, dot)
		), color, true)

	# Fleet: a 2×2 px white dot (§4.12).
	var fleet: Vector2i = fleet_cell if fleet_cell.x >= 0 else GameState.world_tile()
	draw_rect(Rect2(
		rect.position + Vector2(fleet) * scale + (tile - Vector2(dot, dot)) * 0.5,
		Vector2(dot, dot)
	), Color.WHITE, true)

	draw_rect(rect, PaletteLib.PANEL_LINE, false, 2.0)


static func _terrain_color(kind: String) -> Color:
	match kind:
		"sea":
			return PaletteLib.SEA
		"coastal_sea":
			return PaletteLib.COAST_SEA
		"land":
			return PaletteLib.LAND
		"reef":
			return PaletteLib.REEF
		_:
			return PaletteLib.PANEL_LINE


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
