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
## §4.12.1 (W6-A): the inspect verb renders the unified character card (the
## NPC entry) in place — that card IS the dossier's card section (§4.11.3).
const CardLib := preload("res://scenes/ui/character_card.gd")
## Phase 12 (docs/80-UI-UX.md §4.8.9): the menu's chrome registers under the
## absolute-tile registry; the fleet/port rows are the `fleet_rows` list
## block (computed stacking inside the fixed scroll viewport).
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

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

## Phase 12: the `fleet_rows` list block's geometry, in tiles (authored —
## the capture records them as the block's base/row_h/viewport). Rows stack
## at `base + i·row_h` inside the fixed scroll viewport; the card view (the
## §4.12.1 inspect entry) is the one mode outside the list — its card and
## back button hang off the panel at authored slots while the list is
## hidden.
const LIST_FLEET_ROWS := "fleet_rows"
const ROW_W := 16
const ROW_H := 2

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
## §4.12.1 (W6-A): the inspect verb's card view (the NPC entry). The fleet
## whose card is showing ({} = the pick list is up).
var _card_mode: bool = false
var _card_fleet: Dictionary = {}
## The card widget rendered in card mode (the card-identity pin's read seam).
var _card: Control = null

@onready var _dim: ColorRect = $Dim
@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _scroll: ScrollContainer = $Panel/Scroll
@onready var _rows: Control = $Panel/Scroll/Rows
@onready var _status: Label = $Panel/Status


func _ready() -> void:
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# Phase-10 sweep: the panel/title/status styling retired to the theme
	# (§4.9 Panel + Label rows — the window theme styles every Control here;
	# the gate reason reads in the theme's default ink).
	EventBus.locale_changed.connect(_on_locale_changed)
	# Phase 12 (docs/80-UI-UX.md §4.8.9): the menu's chrome registers its
	# ids at build; the activation applies the `fleet_picker` table at
	# [method _show] (the open path — rows are list members registered
	# where they build).
	_register_layout_ids()


## Phase 12 (docs/80-UI-UX.md §4.8.9): the menu's registered chrome. The
## scroll viewport and its content node are plumbing (no ids).
func _register_layout_ids() -> void:
	RegistryLib.register("fleet_picker", _dim, "dim")
	RegistryLib.register("fleet_picker", _panel, "panel", {"role": "panel"})
	RegistryLib.register("fleet_picker", _title, "panel.title")
	RegistryLib.register("fleet_picker", _status, "panel.status")


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Modal: nothing underneath may react (§6).
	get_viewport().set_input_as_handled()
	if event.is_action_pressed("back"):
		# In card mode `Esc` returns to the pick list first (§4.10.1 → §4.12.1).
		if _card_mode:
			close_card()
		else:
			close()
		return
	# lists: ↑↓ + Enter walk the rows (§4.3); the buttons' focus chain
	# handles it natively, Enter activates the focused verb.


## The fleet picker (§4.10.1): one row per fleet, sorted by id — the caller
## (the world scene) already gated the tile inside the sighting radius.
func open_fleets(fleets: Array) -> void:
	_fleets = (fleets as Array).duplicate()
	_port_id = ""
	_card_mode = false
	_card_fleet = {}
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
	_card_mode = false
	_card_fleet = {}
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
	# Phase 12 (docs/80-UI-UX.md §4.8.9): the activation applies the
	# `fleet_picker` table (idempotent — every open rebuilds the rows and
	# re-registers them) and notifies the bridge.
	RegistryLib.screen_active("fleet_picker", self)


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


## True while the inspect verb's card view is up (§4.12.1).
func is_card_mode() -> bool:
	return _card_mode


## The card rendered in card mode (null while the pick list is up).
func card_widget() -> Control:
	return _card if _card_mode else null


# --- Build -------------------------------------------------------------------

func _rebuild() -> void:
	_row_verbs.clear()
	_port_buttons = {}
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	# The card view's panel children (a previous card mode's leftovers).
	for child in _panel.get_children():
		if child == _title or child == _scroll or child == _status:
			continue
		_panel.remove_child(child)
		child.queue_free()
	_scroll.visible = true
	_status.visible = false
	if _card_mode:
		_rebuild_card()
		# Card mode skips the apply walk: the panel is sized by hand around
		# the card (the §4.12.1 entry), and the next list-mode rebuild
		# re-applies the data rect.
		return
	elif not _port_id.is_empty():
		_rebuild_port()
	else:
		_rebuild_fleets()
	# Phase 12 (docs/80-UI-UX.md §4.8.9): the rebuild path re-applies the
	# data layout (the new rows' registered children take their rect rows).
	RegistryLib.apply_layout("fleet_picker")


## Builds one uniform list row at its stack slot — row *i* at
## `list_rect("fleet_picker", "fleet_rows", i)` (authored fallback
## `(0, i·64, 512, 64)` while the table is unshipped), registered as a
## `fleet_rows` list member under its stack-index id.
func _new_list_row(id: String) -> Control:
	var row := Control.new()
	row.name = "Row_%s" % id
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	var index := _rows.get_child_count()
	var rect := RegistryLib.list_rect("fleet_picker", LIST_FLEET_ROWS, index)
	if rect == Rect2():
		var tile := float(PaletteLib.CHROME_TILE)
		rect = Rect2(0.0, float(index * ROW_H) * tile,
			float(ROW_W * tile), float(ROW_H * tile))
	row.position = rect.position
	row.size = rect.size
	_rows.add_child(row)
	# The content node stacks to the list block's computed extent — a
	# custom minimum, so the ScrollContainer's own layout keeps it exactly
	# that tall (a manual `size` would be overwritten by the viewport).
	_rows.custom_minimum_size = Vector2(
		float(ROW_W * PaletteLib.CHROME_TILE),
		float(_rows.get_child_count() * ROW_H * PaletteLib.CHROME_TILE))
	RegistryLib.register("fleet_picker", row, "fleet_rows.%s" % id,
		{"list": LIST_FLEET_ROWS, "data_ordered": true})
	return row


## The inspect verb's card view (§4.12.1, the NPC entry): the unified card,
## identified = full reveal, and the way back to the pick list. No state is
## touched here (the §4.12 card-identity
## pin compares this card's data against the dossier's — a side effect here
## would break it). Phase 12: the card and back button hang off the PANEL
## at authored slots (the list viewport hides); the panel grows around the
## card — the one code-sized mode (never applied from the data table).
func _rebuild_card() -> void:
	var captain_id := str(_card_fleet.get("captain_id", ""))
	_title.text = I18n.fmt("dossier.title",
		{"name": InteractionsLib.display_name(_card_fleet)})
	_scroll.visible = false
	_status.visible = true
	if captain_id.is_empty() or DataLoader.get_captain(captain_id).is_empty():
		# An unidentified fleet has no canon card to render; the fallback
		# line is the same one the row already showed.
		_set_status(I18n.t_key("interact.unknown_name"))
		_panel.add_child(_back_button_at(Vector2(32, 32)))
		_panel.size = Vector2(576, 32 + 64 + 32)
		_card = null
		return
	_set_status("")
	var card_scene: PackedScene = load(CardLib.SCENE_PATH)
	_card = card_scene.instantiate()
	_card.name = "CaptainCard"
	_panel.add_child(_card)
	_card.position = Vector2(32, 32)
	_card.setup_person(CardLib.KIND_NPC, CardLib.card_data(
		CardLib.KIND_NPC, captain_id))
	_card.reset_size()
	var back := _back_button_at(Vector2(32, 32 + _card.size.y + 16))
	_panel.add_child(back)
	_panel.size = Vector2(576, back.position.y + back.size.y + 16)
	# No separate dossier button (amended 2026-11-03): the card above IS the
	# dossier's card section, and the header already names the captain, so a
	# `档案:<name>` button under it only repeated what was on screen. The
	# dossier's own entry points (§4.11.3: captain's table, bounty row, hail)
	# are unchanged.


## The card view's way-back button, authored at `at` in panel space
## (unregistered — the card view is outside the data list).
func _back_button_at(at: Vector2) -> Button:
	var button := _verb_button(I18n.t_key("ui.back"))
	button.position = at
	button.size = Vector2(512, float(PaletteLib.BUTTON_H))
	button.pressed.connect(close_card)
	return button


## Switches the picker into the inspect card view (the inspect verb's action).
func open_card(fleet: Dictionary) -> void:
	_card_mode = true
	_card_fleet = fleet.duplicate(true)
	_rebuild()


## Back to the pick list.
func close_card() -> void:
	_card_mode = false
	_card_fleet = {}
	_card = null
	_rebuild()


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
		_build_fleet_row(fleet)


func _rebuild_port() -> void:
	var port: Dictionary = DataLoader.get_port(_port_id)
	var port_name := I18n.t(port.get("name", {}))
	_title.text = port_name
	# 靠港 dock (§4.10.3): the standard docking edge — the world scene routes
	# it through the existing walk-in flow (click-to-sail onto the shore
	# tile; docking happens on arrival, or immediately when adjacent).
	var dock_row := _new_list_row("dock")
	var dock := _verb_button(I18n.fmt("world.enter_port", {"port": port_name}))
	dock.position = Vector2.ZERO
	dock.size = Vector2(float(ROW_W * PaletteLib.CHROME_TILE),
		float(ROW_H * PaletteLib.CHROME_TILE))
	dock.pressed.connect(func() -> void:
		close()
		port_action.emit("dock", _port_id))
	dock_row.add_child(dock)
	RegistryLib.register("fleet_picker", dock,
		"fleet_rows.dock.button", {"role": "button"})
	# 委任航行 appoint voyage (§4.10.3/§4.10.4): grayed with the
	# `sail.autopilot` gate reason when the gate fails.
	var appoint_row := _new_list_row("appoint")
	var appoint := _verb_button(I18n.t_key("sail.autopilot.appoint"))
	appoint.disabled = not _appoint_enabled
	appoint.position = Vector2(0, float(ROW_H * PaletteLib.CHROME_TILE))
	appoint.size = Vector2(float(ROW_W * PaletteLib.CHROME_TILE),
		float(ROW_H * PaletteLib.CHROME_TILE))
	appoint.pressed.connect(func() -> void:
		close()
		port_action.emit("appoint", _port_id))
	appoint_row.add_child(appoint)
	RegistryLib.register("fleet_picker", appoint,
		"fleet_rows.appoint.button", {"role": "button"})
	_port_buttons = {"dock": dock, "appoint": appoint}
	_set_status("" if _appoint_enabled else _appoint_reason)


func _build_fleet_row(fleet: Dictionary) -> Control:
	var index := _rows.get_child_count()
	var row := _new_list_row(str(index))
	# Flag color (§4.10.1): the nation's color — the §4.5.2 marker rule is
	# the established placeholder (pirate red, the nationless coaster grey).
	var flag := ColorRect.new()
	flag.position = Vector2.ZERO
	flag.size = Vector2(32, 32)
	flag.color = NpcFleetsLib.marker_color(str(fleet.get("role", "")),
		str(fleet.get("nation_id", "")))
	flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(flag)
	RegistryLib.register("fleet_picker", flag, "fleet_rows.%d.flag" % index)
	# Role icon (§4.5.2 marker letter) in a bordered tile — the theme's
	# Panel style (§4.9 Panel row) owns the chrome.
	var role_tile := Panel.new()
	role_tile.position = Vector2(32, 0)
	role_tile.size = Vector2(32, 32)
	role_tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var letter := Label.new()
	letter.position = Vector2.ZERO
	letter.size = Vector2(32, 32)
	letter.text = NpcFleetsLib.marker_letter(str(fleet.get("role", "")))
	letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	role_tile.add_child(letter)
	row.add_child(role_tile)
	RegistryLib.register("fleet_picker", role_tile,
		"fleet_rows.%d.role" % index, {"role": "panel"})
	RegistryLib.register("fleet_picker", letter,
		"fleet_rows.%d.role_letter" % index)
	# Identified name + tier badge (§4.10.1): the canon captain's name —
	# every Phase-8 captain carries one — or the unidentified fallback line.
	# The name rides a fixed-width clipped column (§4.6.1 class fix: a long
	# captain name must not widen the menu — the window is pinned by the
	# data table).
	var name_label := Label.new()
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.text = I18n.fmt("interact.pick.row", {
		"name": InteractionsLib.display_name(fleet),
		"tier": NpcFleetsLib.captain_tier_of(fleet),
	})
	name_label.position = Vector2(64, 0)
	name_label.size = Vector2(128, 32)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	RegistryLib.register("fleet_picker", name_label,
		"fleet_rows.%d.name" % index)
	var tier := _tier_badge(NpcFleetsLib.captain_tier_of(fleet))
	tier.position = Vector2(192, 0)
	row.add_child(tier)
	RegistryLib.register("fleet_picker", tier,
		"fleet_rows.%d.tier" % index, {"role": "panel"})
	# Verbs (§4.10.1): one button per `Interactions.verbs_for(fleet)` — the
	# coaster pin removes the attack key before a button can exist for it.
	# The verb slots are fixed (inspect/talk/attack at tiles 7/10/13 of the
	# row), so a coaster's missing attack leaves its slot empty and the
	# rendered surface never shifts.
	var verbs := InteractionsLib.verbs_for(fleet)
	var verb_map := {}
	var verb_x := {
		InteractionsLib.VERB_INSPECT: 224.0,
		InteractionsLib.VERB_TALK: 320.0,
		InteractionsLib.VERB_ATTACK: 416.0,
	}
	for verb in verbs:
		var button := _verb_button(I18n.t_key("interact.verb.%s" % verb))
		button.position = Vector2(float(verb_x[verb]), 0)
		button.size = Vector2(96, PaletteLib.BUTTON_H - 8)
		if verb == InteractionsLib.VERB_TALK \
				and not InteractionsLib.hail_in_range(fleet):
			# Grayed with the distance reason beyond Chebyshev 2 (§4.10.1).
			button.disabled = true
		var captured := fleet
		if verb == InteractionsLib.VERB_INSPECT:
			# §4.12.1 (W6-A): inspect renders the unified card in place; the
			# verb stays on the row (the surface pin), only its action moved.
			button.pressed.connect(func() -> void: open_card(captured))
		else:
			button.pressed.connect(func() -> void:
				close()
				verb_chosen.emit(verb, captured))
		verb_map[verb] = button
		row.add_child(button)
		RegistryLib.register("fleet_picker", button,
			"fleet_rows.%d.verb.%s" % [index, verb], {"role": "button"})
	_row_verbs.append(verb_map)
	# The talk gate's reason surfaces in the status line when any rendered
	# row cannot be hailed (§4.10.1 "grayed with the distance reason").
	if verb_map.has(InteractionsLib.VERB_TALK) \
			and (verb_map[InteractionsLib.VERB_TALK] as Button).disabled:
		_set_status(I18n.t_key("interact.talk.too_far"))
	return row


func _tier_badge(tier: int) -> Control:
	# Tier badge: the tier numeral on the theme's panel chrome (§4.9) — the
	# per-tier placeholder backgrounds retired with the Phase-10 sweep; the
	# numeral is the encoding (§4.10.1 "tier badge").
	var badge := Panel.new()
	badge.size = Vector2(32, 32)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.position = Vector2.ZERO
	label.size = Vector2(32, 32)
	label.text = str(tier)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(label)
	return badge


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
		if child is Button:
			return child
		for node in (child as Control).get_children():
			if node is Button:
				return node
	# The card view's back button lives on the panel (outside the list).
	for node in _panel.get_children():
		if node is Button:
			return node
	return null


func _on_locale_changed(_locale: String) -> void:
	if visible:
		_rebuild()
