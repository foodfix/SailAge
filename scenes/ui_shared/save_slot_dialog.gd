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

const PaletteLib := preload("res://scripts/palette.gd")
## Mode ids, mirrored by `SaveSystem` (which preloads this script).
const MODE_SAVE := 0
const MODE_LOAD := 1

## Emitted with the chosen slot number; the host owns what happens next.
signal slot_chosen(slot: int)
## Emitted when the dialog closes without a choice (Cancel / Esc / post-choice).
signal closed

const DIM_ALPHA := 0.4
const MODAL_GROUP := "modal_overlay"
const DIALOG_W := 640
const ROW_H := 64

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _prompt: Label = $Center/Panel/Margin/Body/Prompt
@onready var _rows: VBoxContainer = $Center/Panel/Margin/Body/Rows
@onready var _cancel_button: Button = $Center/Panel/Margin/Body/Footer/Cancel

## [constant MODE_SAVE] or [constant MODE_LOAD]; set by [method open].
var _mode: int = MODE_SAVE
## Slot buttons in slot order (index 0 = slot 1).
var _buttons: Array[Button] = []


func _ready() -> void:
	visible = false
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_panel.custom_minimum_size.x = float(DIALOG_W)
	for label in [_title, _prompt]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_prompt.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_title.add_theme_font_size_override("font_size", 28)
	_cancel_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_cancel_button.pressed.connect(cancel)
	EventBus.locale_changed.connect(_on_locale_changed)
	if _buttons.is_empty():
		_build_rows()


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

func _build_rows() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var button := Button.new()
		button.name = "Slot%d" % slot
		button.custom_minimum_size = Vector2(0, ROW_H)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void: _on_row_pressed(slot))
		_rows.add_child(button)
		_buttons.append(button)


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


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
