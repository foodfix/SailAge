extends Control
## Port hub (S4) — shell owned by T10; T11 fills in the facility rows.
## Docs: 20-* §4.11 (exit), 30-* §4.7 (port hub wireframe),
## 80-* §4.1–§4.6 (routing, HUD, input), 90-* §7 (world ↔ port routing).
##
## What this shell *is*:
##   * the port header (name · nation) and the §4.11 arrival banner — the
##     localised `Port.flavor` line, which is the "greeting banner" the doc
##     asks for;
##   * the shared HUD (`hud.tscn`) so day / gold / morale / provisions stay
##     visible (§4.5 "S4 HUD: same bars", with the sea viewport replaced);
##   * **Set Sail**, the S4 → S3 back edge (§4.2, §4.11).
##
## What it deliberately is **not** (T11+): the six facility rows. T11 renders
## them from the port's `facilities` data; the marked placeholder below is the
## slot it fills, and [method add_facility_row] is the pre-wired way in.
##
## Exit contract (docs/20-* §4.11, docs/80-* §4.3 "Esc = step back one edge;
## S4's back edge is S3"):
##   * `GameState.current_port = null`
##   * `GameState.world.clock_fraction = 0.0`
##   * `GameState.world.position` stays on the harbor tile
##   * route to `world_map.tscn`
## `Esc` performs exactly the same transition as the button: the port screen
## has no other back edge, so "step back" is "set sail" — documented here
## because the doc's Esc rule is generic and this is its S4 reading.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterPanelLib := preload("res://scenes/ui_shared/character_panel.gd")

const WORLD_SCENE := "res://scenes/world/world_map.tscn"

## Facility id → screen path. T12–T15 own those scenes; T11's rows call
## [method open_facility], which stays a no-op (with a logged warning) while a
## path does not exist yet, so the shell is usable before they land.
const FACILITY_SCENES := {
	"market": "res://scenes/port/market_screen.tscn",
	"shipyard": "res://scenes/port/shipyard_screen.tscn",
	"tavern": "res://scenes/port/tavern_screen.tscn",
	"inn": "res://scenes/port/inn_screen.tscn",
}

## Emitted when T11's rows (or anything else) ask for a facility screen. Not
## needed for the four P1 facilities — [method open_facility] routes them — but
## it lets a test or a future stub observe the intent without a scene swap.
signal facility_requested(facility_id: String)
## Emitted right before the S4 → S3 route, after the state is already reset.
## Tests observe this instead of swapping their own scene root.
signal sailed
## Emitted whenever the header/banner is rebuilt (ready, locale change, state
## change). T11's rows can use it to keep their own values in sync.
signal rebound

@onready var _background: ColorRect = $Background
@onready var _hud: Control = $HUD
@onready var _port_name: Label = $Layout/VBox/Header/TitleRow/PortName
@onready var _nation_swatch: ColorRect = $Layout/VBox/Header/TitleRow/NationSwatch
@onready var _nation_name: Label = $Layout/VBox/Header/TitleRow/NationName
@onready var _greeting: Label = $Layout/VBox/Header/Greeting
@onready var _day_greeting: Label = $Layout/VBox/Header/DayGreeting
@onready var _facility_rows: VBoxContainer = $Layout/VBox/Facilities/Rows
@onready var _facility_placeholder: Label = $Layout/VBox/Facilities/Placeholder
@onready var _set_sail_button: Button = $Layout/VBox/Footer/SetSail
@onready var _esc_hint: Label = $Layout/VBox/Footer/EscHint

## Routing switch for headless tests (the `GameState.new_game(..., route)`
## convention): with `false`, [method set_sail] runs the whole state transition
## and emits [signal sailed] but does not replace the scene.
var route_to_world: bool = true

## Routing switch for [method open_facility], same convention as
## [member route_to_world]: with `false` the call still emits
## [signal facility_requested] and returns whether the target exists, but does
## not replace the scene. T12–T15's acceptance tests and T10's extension-point
## test use it to observe the wiring without swapping their own scene root.
var route_to_facility: bool = true

## Port currently docked at ("" when the scene is opened standalone, e.g. from
## the editor with no run in progress).
var _port_id: String = ""


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_port_name, _nation_name, _greeting, _day_greeting, _facility_placeholder]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_greeting.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_day_greeting.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_facility_placeholder.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_port_name.add_theme_font_size_override("font_size", 32)
	_set_sail_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_set_sail_button.pressed.connect(_on_set_sail_pressed)

	# S4 keeps the same bars as S3, but the sea viewport (minimap + weather
	# glyph) is replaced by the port menu (docs/80-* §4.5).
	_hud.set_minimap_visible(false)

	_port_id = _read_current_port()
	_bind()

	# S14 over S4 (docs/80-* §4.3 "S3/S4 | C"). Parent-agnostic modal.
	CharacterPanelLib.attach_to(self)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_state_changed)
	# A save load can change `current_port` under us; re-bind the header when
	# the day signal fires (the only event a load always produces).
	EventBus.day_advanced.connect(_on_day_advanced)


func _unhandled_input(event: InputEvent) -> void:
	# §4.3 "Esc = back / close modal"; S4's only back edge is Set Sail (§4.2).
	# A modal owns input first (§6 "modals consume all input"), so Esc with a
	# dialog or the S14 panel up closes that instead of leaving harbour.
	if event.is_action_pressed("back"):
		if has_modal():
			return
		get_viewport().set_input_as_handled()
		set_sail()
		return
	# Locale toggle lives in the HUD top bar; keep the key working here too when
	# the HUD is not the focus owner.
	if event.is_action_pressed("toggle_locale"):
		if has_modal():
			return
		get_viewport().set_input_as_handled()
		I18n.toggle_locale()


## True while a modal is up on this screen: the HUD's queued dialogs, any
## dialog in the `modal_overlay` group, or the S14 character panel. Set Sail is
## never triggered from behind a modal (docs/80-* §6).
func has_modal() -> bool:
	if _hud != null and _hud.has_method("has_modal") and _hud.has_modal():
		return true
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	var panel := get_node_or_null("CharacterPanel")
	if panel != null and panel.has_method("is_open") and panel.is_open():
		return true
	return false


# --- Public API (T11–T15 extension points) ---------------------------------

## Port id currently docked at ("" when opened without a run).
func port_id() -> String:
	return _port_id


## The `Port` record for [method port_id] ({} when none).
func port_data() -> Dictionary:
	if _port_id.is_empty():
		return {}
	return DataLoader.get_port(_port_id)


## Container T11 fills with the six facility rows (Market … Palace), in the
## §4.7 wireframe order. It sits between the greeting banner and Set Sail.
func facility_container() -> VBoxContainer:
	return _facility_rows


## Adds one facility row inside [method facility_container] and wires it to
## [method open_facility]. T11 owns *which* rows exist (the port's `facilities`
## data) and their enabled state (`guild`/`palace` are Phase-3 stubs); this
## helper only guarantees the wiring, the palette and the button height.
func add_facility_row(facility_id: String, text_key: String, enabled: bool = true) -> Button:
	var button := Button.new()
	button.name = "Facility_%s" % facility_id
	button.text = I18n.t_key(text_key)
	button.disabled = not enabled
	button.custom_minimum_size = Vector2(240, PaletteLib.BUTTON_H)
	button.set_meta("text_key", text_key)
	button.pressed.connect(func() -> void: open_facility(facility_id))
	_facility_rows.add_child(button)
	return button


## Routes to a facility screen when it exists. Returns true when the target
## exists (and a route was started, unless [member route_to_facility] is off);
## false (with a warning, no crash) while T12–T15 have not landed the screen
## yet. Always emits [signal facility_requested] so callers can observe the
## intent.
func open_facility(facility_id: String) -> bool:
	facility_requested.emit(facility_id)
	var path := str(FACILITY_SCENES.get(facility_id, ""))
	if path.is_empty():
		push_warning("PortScreen: unknown facility '%s'" % facility_id)
		return false
	if not ResourceLoader.exists(path):
		push_warning("PortScreen: %s missing (T12–T15); staying in port" % path)
		return false
	if route_to_facility:
		GameState.change_scene(path)
	return true


## Set Sail (docs/20-* §4.11 exit; docs/80-* §4.2 S4 → S3):
## clears `current_port`, resets `clock_fraction` to 0, keeps the fleet on the
## harbor tile, then routes to the world map.
##
## Returns false (state untouched) when there is nothing to sail: no run, or no
## harbor tile to leave from. That only happens when the scene is opened
## standalone from the editor.
func set_sail() -> bool:
	if GameState.player.is_empty() and GameState.fleet.is_empty():
		# No run at all (the scene opened from the editor): nothing to leave,
		# and no route — S4's back edge is the world map of a live run.
		return false
	if _read_current_port().is_empty():
		# A save that was taken in port always has `current_port`; a missing one
		# means the scene was opened without docking (editor / test).
		push_warning("PortScreen: set_sail() with no current_port; nothing to exit")
		return false

	# §4.11 exit order: leave the harbor tile in place, drop the docked flag,
	# and reset the fractional clock (a port visit never carries sub-day time
	# back to sea — §4.3 "saving happens only in port, where the fraction is
	# always reset to 0").
	GameState.current_port = null
	GameState.world["clock_fraction"] = 0.0
	sailed.emit()
	if route_to_world:
		GameState.change_scene(WORLD_SCENE)
	return true


# --- Binding ---------------------------------------------------------------

## The docked port id, else "" (standalone).
func _read_current_port() -> String:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return value
	return ""


func _bind() -> void:
	# Re-read the docked port every bind: a save load can change `current_port`
	# while this screen is up, and the header must follow it.
	_port_id = _read_current_port()
	var port := port_data()
	var nation: Dictionary = {}
	if not port.is_empty():
		nation = DataLoader.get_nation(str(port.get("nation_id", "")))
		_nation_swatch.color = PaletteLib.nation_color(str(nation.get("color", "#ffffff")))
	else:
		_nation_swatch.color = PaletteLib.PANEL_LINE

	_port_name.text = I18n.t(port.get("name", {})) if not port.is_empty() else "-"
	_nation_name.text = I18n.t(nation.get("name", {})) if not nation.is_empty() else ""
	_greeting.text = I18n.t(port.get("flavor", {})) if not port.is_empty() else ""
	# `port.day_greeting` = "{port}, day {day}." — the §4.11 arrival report is
	# already a dialog; this line keeps the day visible on the banner itself.
	_day_greeting.visible = not port.is_empty()
	if not port.is_empty():
		_day_greeting.text = I18n.fmt("port.day_greeting", {
			"port": I18n.t(port.get("name", {})),
			"day": GameState.day,
		})
	_set_sail_button.text = I18n.t_key("port.set_sail")
	_facility_placeholder.text = I18n.t_key("port.facilities")
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	_esc_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	# Nothing to leave when not docked (standalone load): the button stays
	# visible for layout but disabled, so no input can start a bogus route.
	_set_sail_button.disabled = port.is_empty()
	rebound.emit()


func _on_set_sail_pressed() -> void:
	set_sail()


func _on_locale_changed(_locale: String) -> void:
	_bind()
	# T11's rows own their labels; give them the same locale event by rebuilding
	# from the stored key when they are ours (add_facility_row stamps it).
	for child in _facility_rows.get_children():
		if child is Button and child.has_meta("text_key"):
			(child as Button).text = I18n.t_key(str(child.get_meta("text_key")))


func _on_state_changed() -> void:
	_bind()


func _on_day_advanced(_new_day: int) -> void:
	_bind()


func _exit_tree() -> void:
	# EventBus autoloads outlive every screen; drop the connections so a freed
	# port screen never re-binds onto a dead node on a later locale toggle.
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_state_changed):
		EventBus.fleet_changed.disconnect(_on_state_changed)
	if EventBus.day_advanced.is_connected(_on_day_advanced):
		EventBus.day_advanced.disconnect(_on_day_advanced)
