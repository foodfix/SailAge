extends Control
## Port hub (S4) — header, facility rows and Set Sail.
## Docs: 20-* §4.11 (exit), 30-* §4.1/§4.7 (facilities + port hub wireframe),
## 80-* §4.1–§4.6 (routing, HUD, input), 90-* §7 (world ↔ port routing).
##
## What this screen *is*:
##   * the port header (name · nation) and the §4.11 arrival banner — the
##     localised `Port.flavor` line, which is the "greeting banner" the doc
##     asks for;
##   * the shared HUD (`hud.tscn`) so day / gold / morale / provisions stay
##     visible (§4.5 "S4 HUD: same bars", with the sea viewport replaced);
##   * the **facility rows**, rendered from the port's own `facilities` object
##     (§4.1) in the fixed wireframe order, then **Set Sail**, the S4 → S3
##     back edge (§4.2, §4.11).
##
## Facility rows are data-driven: a row exists iff `facilities` has that key,
## and is clickable iff its activation phase ≤ 1. Guild (phase 3) is therefore
## always a disabled stub, and Palace (phase 3, capitals only in the data)
## appears only where the port JSON lists it. Editing `data/ports.json` changes
## the hub with no code edit (§4.1, docs/90-* §12).
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
## T18: the fleet/cargo panel is a parent-agnostic modal, like S14; the port hub
## and the world map attach it and offer a row / the `F` key.
const FleetPanelLib := preload("res://scenes/ui_shared/fleet_panel.gd")

const WORLD_SCENE := "res://scenes/world/world_map.tscn"

## Facility id → screen path for the four Phase-1 facilities. Guild/Palace are
## Phase 3 and have no screen yet ([method open_facility] refuses them, and
## they render as disabled stubs).
const FACILITY_SCENES := {
	"market": "res://scenes/port/market_screen.tscn",
	"shipyard": "res://scenes/port/shipyard_screen.tscn",
	"tavern": "res://scenes/port/tavern_screen.tscn",
	"inn": "res://scenes/port/inn_screen.tscn",
}

## The §4.1 fixed display order. The *set* of rows comes from the port's
## `facilities` data (docs/10-* §4.4); this list only fixes the order and
## supplies the label key for each known facility id.
const FACILITY_ORDER: Array[String] = [
	"market", "shipyard", "tavern", "inn", "guild", "palace",
]

## Facility id → `ui_strings` label key (`port.<id>` for all six).
const FACILITY_LABEL_KEYS := {
	"market": "port.market",
	"shipyard": "port.shipyard",
	"tavern": "port.tavern",
	"inn": "port.inn",
	"guild": "port.guild",
	"palace": "port.palace",
}

## §4.1: a facility row is clickable iff its activation phase is ≤ 1. Phase-2/3
## facilities render as disabled rows carrying the stub label.
const FACILITY_ENABLED_MAX_PHASE := 1
## The label every disabled (future-phase) row shows, per §4.1.
const FACILITY_STUB_KEY := "port.stub.phase3"

## Emitted when a facility row (or anything else) asks for a facility screen;
## [method open_facility] emits it before deciding, so a test or a future stub
## can observe the intent without a scene swap.
signal facility_requested(facility_id: String)
## Emitted right before the S4 → S3 route, after the state is already reset.
## Tests observe this instead of swapping their own scene root.
signal sailed
## Emitted whenever the header/banner and the facility rows are rebuilt (ready,
## locale change, state change).
signal rebound

@onready var _background: ColorRect = $Background
@onready var _hud: Control = $HUD
@onready var _port_name: Label = $Layout/VBox/Header/TitleRow/PortName
@onready var _nation_swatch: ColorRect = $Layout/VBox/Header/TitleRow/NationSwatch
@onready var _nation_name: Label = $Layout/VBox/Header/TitleRow/NationName
@onready var _greeting: Label = $Layout/VBox/Header/Greeting
@onready var _day_greeting: Label = $Layout/VBox/Header/DayGreeting
@onready var _facility_heading: Label = $Layout/VBox/Facilities/Heading
@onready var _facility_rows: VBoxContainer = $Layout/VBox/Facilities/Rows
@onready var _set_sail_button: Button = $Layout/VBox/Footer/SetSail
@onready var _fleet_button: Button = $Layout/VBox/Footer/Fleet

@onready var _save_button: Button = $Layout/VBox/Footer/Save
@onready var _esc_hint: Label = $Layout/VBox/Footer/EscHint

## Routing switch for headless tests (the `GameState.new_game(..., route)`
## convention): with `false`, [method set_sail] runs the whole state transition
## and emits [signal sailed] but does not replace the scene.
var route_to_world: bool = true

## Routing switch for [method open_facility], same convention as
## [member route_to_world]: with `false` the call still emits
## [signal facility_requested] and returns whether the target exists, but does
## not replace the scene. T12–T15's acceptance tests and the hub's own extension
## hooks use it to observe the wiring without swapping their own scene root.
var route_to_facility: bool = true

## Port currently docked at ("" when the scene is opened standalone, e.g. from
## the editor with no run in progress).
var _port_id: String = ""

## Facility id → row Button for the rows currently rendered, in display order.
var _row_buttons: Dictionary = {}
## The rendered facility ids, in display order (empty when standalone).
var _row_ids: Array[String] = []
## `id:phase|…` snapshot of the data the rows were built from; a bind whose
## signature differs rebuilds them ([method _sync_facility_rows]).
var _rows_signature: String = ""


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_port_name, _nation_name, _greeting, _day_greeting, _facility_heading]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_greeting.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_day_greeting.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_facility_heading.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_port_name.add_theme_font_size_override("font_size", 32)
	_set_sail_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_set_sail_button.pressed.connect(_on_set_sail_pressed)
	# T18: one footer row that opens the fleet/cargo panel (docs/20 §4.10).
	_fleet_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_fleet_button.pressed.connect(open_fleet_panel)

	# T17 (docs/80-* §4.6): the S4 Save row. `F5` works on any screen but is
	# only *allowed* in port; this row is the discoverable entry point.
	_save_button.custom_minimum_size = Vector2(160, PaletteLib.BUTTON_H)
	_save_button.pressed.connect(open_save_dialog)

	# S4 keeps the same bars as S3, but the sea viewport (minimap + weather
	# glyph) is replaced by the port menu (docs/80-* §4.5).
	_hud.set_minimap_visible(false)

	_port_id = _read_current_port()
	_bind()

	# S14 over S4 (docs/80-* §4.3 "S3/S4 | C"). Parent-agnostic modal.
	CharacterPanelLib.attach_to(self)
	# T18: the fleet/cargo panel (same modal contract; `F`, or the Fleet button).
	FleetPanelLib.attach_to(self)

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
	var fleet_panel := get_node_or_null("FleetPanel")
	if fleet_panel != null and fleet_panel.has_method("has_modal") \
			and fleet_panel.has_modal():
		return true
	return false


# --- Public API (the facility rows + T12–T15 routing) -----------------------

## Port id currently docked at ("" when opened without a run).
func port_id() -> String:
	return _port_id


## The `Port` record for [method port_id] ({} when none).
func port_data() -> Dictionary:
	if _port_id.is_empty():
		return {}
	return DataLoader.get_port(_port_id)


## Container the facility rows live in, in the §4.7 wireframe order. It sits
## between the greeting banner and Set Sail.
func facility_container() -> VBoxContainer:
	return _facility_rows


## The facility ids currently rendered as rows, in display order (`[]` when
## standalone). Derived from [method port_data]'s `facilities` object — never
## from a hardcoded port list.
func facility_row_ids() -> Array[String]:
	return _row_ids.duplicate()


## The row Button for `facility_id` (null when that port has no such row).
func facility_row(facility_id: String) -> Button:
	var button = _row_buttons.get(facility_id, null)
	return button as Button


## Number of facility rows currently rendered.
func facility_row_count() -> int:
	return _row_ids.size()


## True when `facility_id` has a row and that row is clickable (phase ≤ 1).
func is_facility_enabled(facility_id: String) -> bool:
	var button := facility_row(facility_id)
	return button != null and not button.disabled


## Adds one facility row inside [method facility_container] and wires it to
## [method open_facility]. *Which* rows exist, and their enabled state, are
## decided by [method _sync_facility_rows] from the port's `facilities` data;
## this helper only guarantees the wiring, the palette and the button height.
func add_facility_row(facility_id: String, text_key: String, enabled: bool = true) -> Button:
	var button := _make_facility_button(facility_id, text_key, enabled)
	_facility_rows.add_child(button)
	return button


## A facility row Button, not yet parented. Row text/tooltip for stubs is
## applied by [method _sync_facility_rows] and [method _relabel_facility_rows].
func _make_facility_button(facility_id: String, text_key: String,
		enabled: bool) -> Button:
	var button := Button.new()
	button.name = "Facility_%s" % facility_id
	button.text = I18n.t_key(text_key)
	button.disabled = not enabled
	button.custom_minimum_size = Vector2(240, PaletteLib.BUTTON_H)
	button.set_meta("text_key", text_key)
	button.set_meta("facility_id", facility_id)
	button.set_meta("stub", not enabled)
	# A disabled stub has no target: `pressed` never fires on a disabled
	# Button, and the phase check in [method open_facility] is the second
	# line of defence.
	button.pressed.connect(func() -> void: _on_facility_row_pressed(facility_id))
	return button


## Every facility row Button in the container, recursively (the wireframe pairs
## open facilities inside `HBoxContainer`s), in display order. Public so tests
## and future screens can walk the rows without knowing the layout.
func facility_buttons() -> Array:
	var buttons: Array = []
	for child in _facility_rows.get_children():
		if child is Button and child.has_meta("facility_id"):
			buttons.append(child)
		elif child is Container:
			for grandchild in child.get_children():
				if grandchild is Button and grandchild.has_meta("facility_id"):
					buttons.append(grandchild)
	return buttons


## Routes to a facility screen when it exists **and** the docked port offers it
## at Phase 1. Returns true when the target exists (and a route was started,
## unless [member route_to_facility] is off); false (with a warning, no crash)
## otherwise. Always emits [signal facility_requested] so callers can observe
## the intent.
##
## Phase-3 facilities (guild/palace) and facilities absent from this port's
## `facilities` data are refused here: their rows are disabled stubs, so a
## click on them changes nothing (§4.1).
func open_facility(facility_id: String) -> bool:
	facility_requested.emit(facility_id)
	if not _facility_available(facility_id):
		push_warning("PortScreen: facility '%s' is not available in Phase 1" % facility_id)
		return false
	var path := str(FACILITY_SCENES.get(facility_id, ""))
	if path.is_empty():
		push_warning("PortScreen: no screen for facility '%s'" % facility_id)
		return false
	if not ResourceLoader.exists(path):
		push_warning("PortScreen: %s missing; staying in port" % path)
		return false
	if route_to_facility:
		GameState.change_scene(path)
	return true


## Opens the T18 fleet/cargo panel (promote + jettison, docs/40 §4.4/§6). The
## panel is a modal over S4, same contract as the S14 character panel.
## Returns the panel (null only if `fleet_panel.tscn` failed to load).
func open_fleet_panel() -> Control:
	var panel := get_node_or_null("FleetPanel")
	if panel == null:
		panel = FleetPanelLib.attach_to(self)
	if panel != null and panel.has_method("open"):
		panel.open()
	return panel


## The attached fleet panel (tests / hosts), or null.
func fleet_panel() -> Control:
	return get_node_or_null("FleetPanel")

## Open the 3-slot save dialog (docs/80-* §4.6). Returns the dialog so a test can
## drive it; null when the shared scene is missing. The button is enabled only
## while the screen has a run and a docked port (its own precondition).
func open_save_dialog() -> Control:
	if _read_current_port().is_empty():
		return null
	return SaveSystem.open_save_dialog(self)


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
	_fleet_button.text = I18n.t_key("fleet.title")
	_facility_heading.text = I18n.t_key("port.facilities")

	# T17: docs/80-* §4.6 "Save: available only at port". The row lives on S4,
	# so it is enabled whenever there is a run docked here; `F5` elsewhere shows
	# `ui.cant_save_here` through SaveSystem.
	_save_button.text = I18n.t_key("port.save")
	_save_button.disabled = port.is_empty()
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	_esc_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	# Nothing to leave when not docked (standalone load): the button stays
	# visible for layout but disabled, so no input can start a bogus route.
	_set_sail_button.disabled = port.is_empty()
	_sync_facility_rows(port)
	rebound.emit()


## Activation phase of `facility_id` at the docked port (§4.1), or 0 when the
## port's `facilities` object does not list it (no row / no route for it). JSON
## numbers parse as floats, hence the `int(...)` (repo gotcha).
func _facility_phase(facility_id: String) -> int:
	var facilities = port_data().get("facilities", {})
	if not facilities is Dictionary:
		return 0
	if not (facilities as Dictionary).has(facility_id):
		return 0
	var phase = (facilities as Dictionary)[facility_id]
	if phase == null:
		return 0
	return int(phase)


## §4.1 gate: a facility is open in Phase 1 iff the port lists it **and** its
## activation phase is exactly in `[1, FACILITY_ENABLED_MAX_PHASE]`.
## Phase-3 rows are visible but disabled stubs.
func _facility_available(facility_id: String) -> bool:
	var phase := _facility_phase(facility_id)
	return phase >= 1 and phase <= FACILITY_ENABLED_MAX_PHASE


## Renders the facility rows for the current port from its `facilities` data:
## a row per present key, in the fixed §4.1 order, enabled iff its phase ≤ 1;
## Phase-3 rows are disabled stubs labelled `port.stub.phase3`.
##
## Layout follows the §4.7 wireframe: the open Phase-1 facilities sit two per
## line ([Market][Shipyard] / [Tavern][Inn]), while a disabled stub gets a line
## of its own ([Guild — opens in Phase 3]). The grouping is derived from the
## row list, so it adapts to whatever the port data contains (a port missing
## `inn`, or offering an extra phase-1 key, still lays out sensibly).
##
## Rebuilds only when the underlying data changed (docked port or phases), so
## locale/state rebinds stay cheap and keep button focus.
func _sync_facility_rows(port: Dictionary) -> void:
	var facilities = port.get("facilities", {})
	if not facilities is Dictionary:
		facilities = {}
	# Signature of the data the rows depend on, in display order.
	var parts: Array[String] = []
	for facility_id in FACILITY_ORDER:
		if (facilities as Dictionary).has(facility_id):
			parts.append("%s:%d" % [facility_id, int((facilities as Dictionary)[facility_id])])
	for key in (facilities as Dictionary).keys():
		# Keys outside the fixed order are data errors; include them in the
		# signature anyway so a data edit still refreshes the rows.
		if not str(key) in FACILITY_ORDER:
			parts.append("%s:?" % str(key))
	var signature := "|".join(parts)
	if signature == _rows_signature and _facility_rows.get_child_count() > 0:
		return
	_rows_signature = signature
	_clear_facility_rows()

	var pair: HBoxContainer = null
	for facility_id in FACILITY_ORDER:
		if not (facilities as Dictionary).has(facility_id):
			continue
		var phase := int((facilities as Dictionary)[facility_id])
		var enabled := phase >= 1 and phase <= FACILITY_ENABLED_MAX_PHASE
		var label_key := str(FACILITY_LABEL_KEYS.get(
			facility_id, "port.%s" % facility_id))
		var button := _make_facility_button(facility_id, label_key, enabled)
		if enabled:
			# Two open facilities per wireframe line.
			if pair == null or pair.get_child_count() >= 2:
				pair = HBoxContainer.new()
				pair.name = "Pair_%d" % _facility_rows.get_child_count()
				pair.add_theme_constant_override("separation", 8)
				_facility_rows.add_child(pair)
			pair.add_child(button)
		else:
			# A stub owns its line (full-width), as in the wireframe.
			pair = null
			_facility_rows.add_child(button)
			# §4.1: disabled rows carry the stub label, e.g.
			# "Guild — opens in Phase 3". The noun and the note are both
			# localised; only the separator is punctuation.
			button.text = "%s — %s" % [
				I18n.t_key(label_key), I18n.t_key(FACILITY_STUB_KEY),
			]
			button.tooltip_text = I18n.t_key(FACILITY_STUB_KEY)
		_row_buttons[facility_id] = button
		_row_ids.append(facility_id)


func _clear_facility_rows() -> void:
	for child in _facility_rows.get_children():
		_facility_rows.remove_child(child)
		child.queue_free()
	_row_buttons.clear()
	_row_ids.clear()


## Re-labels every rendered row from its stored key, keeping the stub note for
## disabled rows (docs/80-* §6: locale change rebinds without a reload). Walks
## the container rather than the row cache so a row added through
## [method add_facility_row] by a caller also rebinds.
func _relabel_facility_rows() -> void:
	for child in facility_buttons():
		var button := child as Button
		var label_key := str(button.get_meta("text_key"))
		if bool(button.get_meta("stub", false)):
			button.text = "%s — %s" % [
				I18n.t_key(label_key), I18n.t_key(FACILITY_STUB_KEY),
			]
			button.tooltip_text = I18n.t_key(FACILITY_STUB_KEY)
		else:
			button.text = I18n.t_key(label_key)


## A row was clicked: disabled stubs never emit `pressed` (Button.disabled), so
## this only ever sees an enabled row; the phase check in [method open_facility]
## is the second guard.
func _on_facility_row_pressed(facility_id: String) -> void:
	if has_modal():
		return
	if not _facility_available(facility_id):
		return
	open_facility(facility_id)


func _on_set_sail_pressed() -> void:
	set_sail()


func _on_locale_changed(_locale: String) -> void:
	_bind()
	_relabel_facility_rows()


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
