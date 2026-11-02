extends Control
## The right-click interaction menu (docs/80-UI-UX.md §4.10.1 fleet picker +
## §4.10.3 port context) — instanced as a modal child of the world scene
## (docs/90-* §7, the dialog_box/confirm_dialog pattern).
##
## Two modes over one chrome (dim + centered panel + rows):
##   * **Fleet picker** (`open_fleets`): one row per fleet on the clicked
##     tile — flag color / role icon / identified name / tier badge, plus a
##     verb button per `Interactions.verbs_for(fleet)`. A multi-fleet tile
##     lists them all (the rows are the pick list). Talk is grayed with the
##     distance reason beyond Chebyshev 2; a coaster renders no attack verb
##     (the §4.1.1 pin — the verb rule is read from `Interactions`, so the
##     surface and the rule cannot drift apart).
##   * **Port context** (`open_port_context`): 靠港 dock (the standard
##     walk-in edge — the world scene routes it through the existing
##     click-to-sail flow) and 委任航行 appoint voyage, grayed with the
##     `sail.autopilot` gate reason when the gate fails (80-* §4.10.3/§4.10.4).
##
## * Owns all input while open (§6 "modals consume all input"); `Esc` closes
##   (§4.3). Joins the `modal_overlay` group while open (docs/90-* §11).
## * Results leave through [signal verb_chosen] / [signal port_action] and
##   [signal closed] — never a callback into another scene (docs/90-* §7).
## * Placeholder art only: palette ColorRects + the default font (§4.8).

const PaletteLib := preload("res://scripts/palette.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
## The verb rule + the display name are the interaction layer's (W5-A): the
## picker renders what `Interactions` computes.
const InteractionsLib := preload("res://scripts/world/interactions.gd")

## Emitted when a fleet row's verb button is pressed.
signal verb_chosen(verb: String, fleet: Dictionary)
## Emitted when a port-context row is pressed (`"dock"` / `"appoint"`).
signal port_action(action: String, port_id: String)
## Emitted when the menu closes (a choice, `Esc`, or a programmatic close).
signal closed

const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## Row icon / badge size (§4.8 sizing grid: 3 base units).
const ICON_SIZE := 24

## The open menu's source state, kept so a locale change rebuilds exactly the
## same menu (the confirm_dialog `_source` convention).
var _fleets: Array = []
var _port_id: String = ""
var _appoint_enabled: bool = false
var _appoint_reason: String = ""

## verb → the row's Button for each built fleet row (index-aligned with the
## rendered rows; the test seam that pins the rendered surface — a coaster
## row simply has no "attack" key).
var _row_verbs: Array[Dictionary] = []
## The port-context mode's row buttons ({} in fleet mode).
var _port_buttons: Dictionary = {}

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _rows: VBoxContainer = $Center/Panel/Margin/Body/Rows
@onready var _status: Label = $Center/Panel/Margin/Body/Status


func _ready() -> void:
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 20)
	_status.add_theme_color_override("font_color", PaletteLib.WARN)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = float(PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN)
	EventBus.locale_changed.connect(_on_locale_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Modal: nothing underneath may react (§6).
	get_viewport().set_input_as_handled()
	if event.is_action_pressed("back"):
		close()
		return
	# lists: ↑↓ + Enter walk the rows (§4.3); the buttons' focus chain
	# handles it natively, Enter activates the focused verb.


## The fleet picker (§4.10.1): one row per fleet, sorted by id — the caller
## (the world scene) already gated the tile inside the sighting radius.
func open_fleets(fleets: Array) -> void:
	_fleets = (fleets as Array).duplicate()
	_port_id = ""
	_rebuild()
	_show()


## The port context menu (§4.10.3). `appoint_enabled` / `appoint_reason` are
## the `sail.autopilot` gate's answer (`Interactions.appoint_gate`).
func open_port_context(port_id: String, appoint_enabled: bool,
		appoint_reason: String) -> void:
	_fleets = []
	_port_id = port_id
	_appoint_enabled = appoint_enabled
	_appoint_reason = appoint_reason
	_rebuild()
	_show()


func is_open() -> bool:
	return visible


func close() -> void:
	if not visible:
		return
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit()


func _show() -> void:
	visible = true
	add_to_group(MODAL_GROUP)
	var first := _first_button()
	if first != null:
		first.grab_focus()


# --- Test/inspection seams ---------------------------------------------------

## The verb buttons of the `index`-th fleet row: `{verb: Button}` — a verb
## the row must not offer (a coaster's attack) has **no key** at all.
func row_verbs(index: int) -> Dictionary:
	return _row_verbs[index] if index >= 0 and index < _row_verbs.size() \
		else {}


## The rendered fleet-row count (the multi-fleet pick list's length).
func row_count() -> int:
	return _row_verbs.size()


## The status line under the rows (a gate/distance reason, "" when none).
func status_text() -> String:
	return _status.text if _status.visible else ""


## The port-context row buttons (`{"dock": Button, "appoint": Button}` —
## empty in fleet mode). The test seam that pins the §4.10.3 surface.
func port_buttons() -> Dictionary:
	return _port_buttons


## The menu title (a fleet pick or a port context).
func title_text() -> String:
	return _title.text


# --- Build -------------------------------------------------------------------

func _rebuild() -> void:
	_row_verbs.clear()
	_port_buttons = {}
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if not _port_id.is_empty():
		_rebuild_port()
	else:
		_rebuild_fleets()


func _rebuild_fleets() -> void:
	_title.text = I18n.t_key("interact.pick.title")
	_set_status("")
	var fleets: Array = _fleets.duplicate()
	fleets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str((a as Dictionary).get("id", "")) \
			< str((b as Dictionary).get("id", "")))
	for fleet in fleets:
		if not (fleet is Dictionary):
			continue
		_rows.add_child(_build_fleet_row(fleet))


func _rebuild_port() -> void:
	var port: Dictionary = DataLoader.get_port(_port_id)
	var port_name := I18n.t(port.get("name", {}))
	_title.text = port_name
	# 靠港 dock (§4.10.3): the standard docking edge — the world scene routes
	# it through the existing walk-in flow (click-to-sail onto the shore
	# tile; docking happens on arrival, or immediately when adjacent).
	var dock := _verb_button(I18n.fmt("world.enter_port", {"port": port_name}))
	dock.pressed.connect(func() -> void:
		close()
		port_action.emit("dock", _port_id))
	_rows.add_child(_wrap_row(dock))
	# 委任航行 appoint voyage (§4.10.3/§4.10.4): grayed with the
	# `sail.autopilot` gate reason when the gate fails.
	var appoint := _verb_button(I18n.t_key("sail.autopilot.appoint"))
	appoint.disabled = not _appoint_enabled
	appoint.pressed.connect(func() -> void:
		close()
		port_action.emit("appoint", _port_id))
	_rows.add_child(_wrap_row(appoint))
	_port_buttons = {"dock": dock, "appoint": appoint}
	_set_status("" if _appoint_enabled else _appoint_reason)


func _build_fleet_row(fleet: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	# Flag color (§4.10.1): the nation's color — the §4.5.2 marker rule is
	# the established placeholder (pirate red, the nationless coaster grey).
	var flag := ColorRect.new()
	flag.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	flag.color = NpcFleetsLib.marker_color(str(fleet.get("role", "")),
		str(fleet.get("nation_id", "")))
	flag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(flag)
	# Role icon (§4.5.2 marker letter) in a bordered tile.
	var role_tile := PanelContainer.new()
	role_tile.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	role_tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	role_tile.add_theme_stylebox_override("panel", _icon_style())
	var letter := Label.new()
	letter.text = NpcFleetsLib.marker_letter(str(fleet.get("role", "")))
	letter.add_theme_font_size_override("font_size", 14)
	letter.add_theme_color_override("font_color", PaletteLib.TEXT)
	letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	role_tile.add_child(letter)
	row.add_child(role_tile)
	# Identified name + tier badge (§4.10.1): the canon captain's name —
	# every Phase-8 captain carries one — or the unidentified fallback line.
	var name_label := Label.new()
	name_label.text = I18n.fmt("interact.pick.row", {
		"name": InteractionsLib.display_name(fleet),
		"tier": NpcFleetsLib.captain_tier_of(fleet),
	})
	name_label.add_theme_color_override("font_color", PaletteLib.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_label)
	row.add_child(_tier_badge(NpcFleetsLib.captain_tier_of(fleet)))
	# Verbs (§4.10.1): one button per `Interactions.verbs_for(fleet)` — the
	# coaster pin removes the attack key before a button can exist for it.
	var verbs := InteractionsLib.verbs_for(fleet)
	var verb_map := {}
	for verb in verbs:
		var button := _verb_button(I18n.t_key("interact.verb.%s" % verb))
		if verb == InteractionsLib.VERB_TALK \
				and not InteractionsLib.hail_in_range(fleet):
			# Grayed with the distance reason beyond Chebyshev 2 (§4.10.1).
			button.disabled = true
		var captured := fleet
		button.pressed.connect(func() -> void:
			close()
			verb_chosen.emit(verb, captured))
		verb_map[verb] = button
		row.add_child(button)
	_row_verbs.append(verb_map)
	# The talk gate's reason surfaces in the status line when any rendered
	# row cannot be hailed (§4.10.1 "grayed with the distance reason").
	if verb_map.has(InteractionsLib.VERB_TALK) \
			and (verb_map[InteractionsLib.VERB_TALK] as Button).disabled:
		_set_status(I18n.t_key("interact.talk.too_far"))
	return row


func _tier_badge(tier: int) -> Control:
	# Placeholder tier badge: the tier numeral on a palette color (1 grey /
	# 2 amber / 3 red — no textures, §4.8).
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_theme_stylebox_override("panel", _badge_style(tier))
	var label := Label.new()
	label.text = str(tier)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(label)
	return badge


func _wrap_row(button: Button) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(button)
	return row


func _verb_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(96, PaletteLib.BUTTON_H - 8)
	return button


func _set_status(text: String) -> void:
	_status.text = text
	_status.visible = not text.is_empty()


func _first_button() -> Button:
	for child in _rows.get_children():
		for node in (child as Control).get_children():
			if node is Button:
				return node
	return null


func _on_locale_changed(_locale: String) -> void:
	if visible:
		_rebuild()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


func _icon_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(1)
	return style


func _badge_style(tier: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_LINE if tier <= 1 \
		else (PaletteLib.WARN if tier == 2 else PaletteLib.BAD)
	style.set_border_width_all(0)
	return style
