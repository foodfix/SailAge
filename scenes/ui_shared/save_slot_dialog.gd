extends Control
## Save/load slot dialog — the 3-slot picker shared by Save (S4 row / F5) and
## Load (S1 `title.load_game` / F9). Docs: 80-UI-UX.md §4.6, §4.7; 90-* §5.5.
##
## One row per slot in [constant SaveSystem.SLOT_COUNT] order:
##   * a summary line `Day · Nation · gold · timestamp` (built from the
##     `ui.day_nation_gold` / `ui.timestamp` keys, so it is fully localised),
##   * `ui.empty` for a free slot,
##   * `ui.save.invalid` for a corrupt or version-mismatched file — that row is
##     disabled and can never be chosen (docs/80-* §4.6).
##
## Behaviour by mode:
##   * **Save** — every slot is selectable; a non-empty one asks
##     `ui.overwrite_confirm` through `confirm_dialog.tscn` before writing, then
##     the host toasts `ui.saved`. Saving an empty slot writes directly.
##   * **Load** — only valid rows are selectable; choosing one loads and routes
##     (S4 when the save was taken in port, else S3 — docs/80-* §4.6).
##
## The dialog never touches `GameState` itself: it reports the choice through
## [signal slot_chosen] and `SaveSystem` (the owner of the write/load flow)
## performs it. Docs/90-* §7: results leave through signals.
##
## Modals consume all input while open (§4.7): `Esc` cancels, `Enter` activates
## the focused row. Re-binds on `EventBus.locale_changed`.
##
## Phase 12 (docs/80-* §4.8.9): the absolute-tile layout. The flow chain
## (`Center → Panel → Margin → Body → Rows/Footer`) is deleted; the plate is
## the fixed `20,10,20,14` tile rect and its children hang directly off the
## registered panel. The slot rows are the screen's list block `slots`
## (`slots.<i>` ids, `RegistryLib.list_rect` stacking inside the
## `panel.slots_viewport` scroll — the viewport survives only as the clipped
## list window, its content node a plain Control sized to the stacked
## extent). Activation at each OPEN; the committed data rects re-apply.

const PaletteLib := preload("res://scripts/palette.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## This modal's layout screen id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "save_slot"

## Mode ids, mirrored by `SaveSystem` (which preloads this script).
const MODE_SAVE := 0
const MODE_LOAD := 1

## Emitted with the chosen slot number; the host owns what happens next.
signal slot_chosen(slot: int)
## Emitted when the dialog closes without a choice (Cancel / Esc / post-choice).
signal closed

const DIM_ALPHA := 0.4
const MODAL_GROUP := "modal_overlay"

## The slot rows' list block (docs/10-* §4.23 — tiles, content-node space):
## rows stack at `base.y + i·row_h` inside the `panel.slots_viewport`
## viewport; the shipped data row mirrors these constants exactly.
const LIST_SLOTS := "slots"
const SLOTS_BASE_TILES := Rect2i(0, 0, 18, 2)
const SLOTS_ROW_H_TILES := 2

## The id pass runs once per instance (records persist across closes).
var _ids_registered := false

@onready var _dim: ColorRect = $Dim
@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _prompt: Label = $Panel/Prompt
@onready var _viewport: ScrollContainer = $Panel/SlotsViewport
@onready var _slots: Control = $Panel/SlotsViewport/Slots
@onready var _cancel_button: Button = $Panel/Cancel

## [constant MODE_SAVE] or [constant MODE_LOAD]; set by [method open].
var _mode: int = MODE_SAVE
## Slot buttons in slot order (index 0 = slot 1).
var _buttons: Array[Button] = []


func _ready() -> void:
	visible = false
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 sweep (W4-B): panel chrome from the theme; the prompt is secondary
	# text → the `Dim` variation. The title's 28px is the scene's own pin
	# (`save_slot_dialog.tscn`).
	_prompt.theme_type_variation = "Dim"
	_cancel_button.pressed.connect(cancel)
	EventBus.locale_changed.connect(_on_locale_changed)
	if _buttons.is_empty():
		_build_rows()


## The id pass — every persistent control under its stable hierarchical id.
## Modals register AT OPEN (host scenes embed idle dialog instances that
## must stay unregistered until they show); see confirm_dialog.gd.
func _register_ids() -> void:
	RegistryLib.register(SCREEN_ID, _dim, "dim")
	RegistryLib.register(SCREEN_ID, _panel, "panel", {"role": "panel"})
	RegistryLib.register(SCREEN_ID, _title, "panel.title")
	RegistryLib.register(SCREEN_ID, _prompt, "panel.prompt")
	RegistryLib.register(SCREEN_ID, _viewport, "panel.slots_viewport")
	RegistryLib.register(SCREEN_ID, _slots, "panel.slots")
	RegistryLib.register(SCREEN_ID, _cancel_button, "panel.cancel",
		{"role": "button"})
	for index in _buttons.size():
		RegistryLib.register(SCREEN_ID, _buttons[index], "slots.%d" % index,
			{"list": LIST_SLOTS, "data_ordered": true, "role": "button"})


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Modal: swallow everything (docs/80-* §4.7/§6). `Esc` cancels; Enter/Space
	# activate the focused row through the normal Button path.
	get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.physical_keycode == KEY_ESCAPE:
			cancel()


## Shows the dialog in `mode` with freshly rebuilt summaries.
func open(mode: int = MODE_SAVE) -> void:
	_mode = mode
	if not _ids_registered:
		_register_ids()
		_ids_registered = true
	RegistryLib.screen_active(SCREEN_ID, self)
	_bind()
	visible = true
	add_to_group(MODAL_GROUP)
	if not _buttons.is_empty() and not _buttons[0].disabled:
		_buttons[0].grab_focus()
	else:
		_cancel_button.grab_focus()


func mode() -> int:
	return _mode


func is_open() -> bool:
	return visible


## Slot button for `slot` (1-based); tests read `text`/`disabled` from it.
func slot_button(slot: int) -> Button:
	var index := slot - 1
	if index < 0 or index >= _buttons.size():
		return null
	return _buttons[index]


## Summary text the dialog would show for `slot` — the single place the §4.6
## "Day · Nation · gold · timestamp" line is composed, used by the rows and by
## tests (`save_slot_summary` mirrors it for callers without a scene).
func row_text(entry: Dictionary) -> String:
	var slot := int(entry.get("slot", 0))
	var slot_label := I18n.fmt("ui.slot_n", {"slot": slot})
	if bool(entry.get("empty", true)):
		return "%s — %s" % [slot_label, I18n.t_key("ui.empty")]
	if not bool(entry.get("valid", false)):
		return "%s — %s" % [slot_label, I18n.t_key("ui.save.invalid")]
	var nation := _nation_name(str(entry.get("nation", "")))
	var summary := I18n.fmt("ui.day_nation_gold", {
		"day": int(entry.get("day", 0)),
		"nation": nation,
		"gold": int(entry.get("gold", 0)),
	})
	# `ui.timestamp` = "Saved {amount}"; the amount itself is locale-neutral
	# (ISO-like date, matching the save file's unix value).
	var stamp := I18n.fmt("ui.timestamp", {
		"amount": format_timestamp(int(entry.get("timestamp", 0))),
	})
	return "%s — %s — %s" % [slot_label, summary, stamp]


## `"2026-10-27 16:48"`; 0 (absent `saved_at`) renders as "-" rather than 1970.
static func format_timestamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "-"
	var parts := Time.get_datetime_dict_from_unix_time(unix_time)
	return "%04d-%02d-%02d %02d:%02d" % [
		int(parts.get("year", 0)), int(parts.get("month", 0)),
		int(parts.get("day", 0)), int(parts.get("hour", 0)),
		int(parts.get("minute", 0)),
	]


# --- Selection -------------------------------------------------------------

func _on_row_pressed(slot: int) -> void:
	var entry := SaveSystem.slot_summary(slot)
	if _mode == MODE_LOAD and not bool(entry.get("valid", false)):
		return
	if _mode == MODE_SAVE and not bool(entry.get("empty", true)):
		_ask_overwrite(slot)
		return
	_choose(slot)


func _ask_overwrite(slot: int) -> void:
	var scene: PackedScene = ResourceLoader.load(SaveSystem.CONFIRM_DIALOG_SCENE)
	if scene == null:
		push_error("SaveSlotDialog: missing confirm dialog; overwriting slot %d without asking" % slot)
		_choose(slot)
		return
	var confirm_dialog: Control = scene.instantiate()
	add_child(confirm_dialog)
	confirm_dialog.open_key("ui.overwrite_confirm", {"slot": slot})
	confirm_dialog.confirmed.connect(func() -> void: _choose(slot))


func _choose(slot: int) -> void:
	_close()
	slot_chosen.emit(slot)


func cancel() -> void:
	_close()
	closed.emit()


func _close() -> void:
	if not visible:
		return
	visible = false
	remove_from_group(MODAL_GROUP)


# --- Binding ---------------------------------------------------------------

## Row *i*'s rect: the list block's `list_rect` when the screen's v2 table
## is live, else the same authored constants (the interim pre-merge state —
## the shipped data row mirrors them exactly, so both paths agree).
func _slot_rect(index: int) -> Rect2:
	var rect := RegistryLib.list_rect(SCREEN_ID, LIST_SLOTS, index)
	if rect != Rect2():
		return rect
	var tile := float(PaletteLib.CHROME_TILE)
	return Rect2(
		float(SLOTS_BASE_TILES.position.x) * tile,
		float(index * SLOTS_ROW_H_TILES) * tile,
		float(SLOTS_BASE_TILES.size.x) * tile,
		float(SLOTS_BASE_TILES.size.y) * tile)


func _build_rows() -> void:
	var slot_index := 0
	for slot in range(SaveSystem.SLOT_MIN,
			SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var button := Button.new()
		button.name = "Slot%d" % slot
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void: _on_row_pressed(slot))
		# Computed stacking (docs/10-* §4.23): row *i* at `base + i·row_h`
		# inside the viewport's content node — no flow underneath.
		button.position = _slot_rect(slot_index).position
		button.size = _slot_rect(slot_index).size
		_slots.add_child(button)
		_buttons.append(button)
		slot_index += 1
	# The content node's stacked extent (the plain-Control scroll content).
	_slots.custom_minimum_size = Vector2(
		_viewport.size.x,
		float(SaveSystem.SLOT_COUNT * SLOTS_ROW_H_TILES
			* PaletteLib.CHROME_TILE))


func _bind() -> void:
	_title.text = I18n.t_key(
		"ui.save.title" if _mode == MODE_SAVE else "ui.load.title"
	)
	_prompt.text = I18n.t_key(
		"ui.save.select_slot" if _mode == MODE_SAVE else "ui.load.select_slot"
	)
	_cancel_button.text = I18n.t_key("ui.cancel")
	var entries: Array[Dictionary] = SaveSystem.list_saves()
	for index in _buttons.size():
		var button := _buttons[index]
		if index >= entries.size():
			button.visible = false
			continue
		var entry: Dictionary = entries[index]
		var valid := bool(entry.get("valid", false))
		var empty := bool(entry.get("empty", true))
		button.text = row_text(entry)
		# Load: a corrupt row is not selectable (§4.6). Save: everything is,
		# with a confirm for the non-empty ones.
		button.disabled = _mode == MODE_LOAD and not valid
		button.modulate = Color(1, 1, 1) if valid or empty else Color(1, 0.6, 0.6)


func _on_locale_changed(_locale: String) -> void:
	if not _buttons.is_empty():
		_bind()


func _nation_name(nation_id: String) -> String:
	if nation_id.is_empty():
		return "-"
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	if nation.is_empty():
		return nation_id
	return I18n.t(nation.get("name", {}))
