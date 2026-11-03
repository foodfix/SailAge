class_name OfficerRosterView
extends Control
## The 官员 view — docs/80-UI-UX.md §4.6.2 (amended 2026-11-03: the retired S18
## modal redesigned into this table + detail view, embedded as the intel
## window's 官员 tab).
##
## **Table form:** one row per employed officer, sorted by id, with the fixed
## columns name / post / loyalty / wage plus a switchable stat block — the
## §4.12.3 five attribute columns or the eight player skills + the three
## officer-only skills (medicine/carpentry/cooking), toggled by the
## 属性/技能 buttons. Clicking a row opens the **detail page**: the full §4.12
## officer card, the post · wage · recruit-port line and the actions —
## 交谈 / 赠礼 / 训练 / 任命 / 解雇 (the §4.6.2 action set, logic unchanged).
##
## Port vs sea: appoint and Dismiss are port actions (§4.6.2); talk / gift /
## train work anywhere, each with its cooldown shown on the buttons.
##
## Embeddable view contract: the intel window instantiates this scene and calls
## [method rebuild] when its tab becomes active; the view also refreshes itself
## on the EventBus signals while visible.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
## The §4.12 unified card (the detail page renders the full officer card).
const CardLib := preload("res://scenes/ui/character_card.gd")

const MODAL_GROUP := "modal_overlay"
## The residual merge fallback (W5-C pattern) — every key here also exists in
## `ui_strings.json` today; the table only guards a stray regression.
const FALLBACK_STRINGS := {
	"officer.post.occupied": {"zh": "在岗:{name}", "en": "In post: {name}"},
	"officer.post.to_idle": {"zh": "卸任(回闲置)", "en": "Unassign (to idle)"},
}
## The detail card's bounded viewport (the §4.12.1 sizing convention).
const DETAIL_CARD_H := 300.0
## Column widths (px) — the §4.8 sizing grid, 13px cell font.
const COL_NAME_W := 200.0
const COL_POST_W := 150.0
const COL_LOYALTY_W := 80.0
const COL_WAGE_W := 110.0
const COL_STAT_W := 78.0
const COL_DISMISS_W := 120.0
const COL_ACTION_W := 120.0
const CELL_FONT_SIZE := 13

## The table's stat block: the §4.12.3 attributes or the skills
## (8 player skills + the 3 officer-only ones).
const MODE_ATTRIBUTES := "attributes"
const MODE_SKILLS := "skills"

## Emitted after a dismissal (tests / hosts).
signal officer_dismissed(officer_id: String)

## `"table"` or `"detail"`.
var _mode: String = "table"
## The stat block the table currently shows.
var _stat_mode: String = MODE_ATTRIBUTES
## The officer the detail page shows (`""` = none).
var _detail_officer: String = ""
## The pending dismissal id (between the button press and the confirm).
var _pending_dismiss: String = ""
## The appoint dialog (the §4.12.3 post table), when open.
var _appoint_dialog: Control = null
## The last action's feedback line ("" = hidden).
var _result_text: String = ""
## One widget bundle per table row (test hooks keep the S18 names).
var _rows: Array = []

@onready var _slots: Label = $Body/Slots
@onready var _mode_note: Label = $Body/ModeNote
@onready var _result: Label = $Body/Result
@onready var _attributes_toggle: Button = $Body/Controls/AttributesToggle
@onready var _skills_toggle: Button = $Body/Controls/SkillsToggle
@onready var _table_scroll: ScrollContainer = $Body/TableScroll
@onready var _table: VBoxContainer = $Body/TableScroll/Table
@onready var _table_empty: Label = $Body/TableEmpty
@onready var _table_empty_hint: Label = $Body/TableEmptyHint
@onready var _detail: VBoxContainer = $Body/Detail
@onready var _detail_back: Button = $Body/Detail/DetailTop/DetailBack
@onready var _detail_card_scroll: ScrollContainer = $Body/Detail/DetailCardScroll
@onready var _detail_line: Label = $Body/Detail/DetailLine
@onready var _detail_actions: HBoxContainer = $Body/Detail/DetailActions
@onready var _confirm: Control = $ConfirmDialog

## The detail page's card + action widgets (rebuilt per open officer).
var _detail_card: Control = null
var _detail_action_map: Dictionary = {}
var _detail_dismiss: Button = null


func _ready() -> void:
	_slots.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_mode_note.add_theme_color_override("font_color", PaletteLib.WARN)
	_result.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_result.visible = false
	_table_empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_table_empty_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_detail_back.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_detail_back.pressed.connect(_on_detail_back)
	_attributes_toggle.pressed.connect(func() -> void: set_stat_mode(MODE_ATTRIBUTES))
	_skills_toggle.pressed.connect(func() -> void: set_stat_mode(MODE_SKILLS))
	_confirm.confirmed.connect(_on_dismiss_confirmed)
	_confirm.cancelled.connect(_on_dismiss_cancelled)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_data_changed)


## True while this view is the intel window's active tab.
func is_active() -> bool:
	return is_visible_in_tree()


func has_dialog() -> bool:
	return (_confirm != null and _confirm.is_open()) \
		or (_appoint_dialog != null and _appoint_dialog.is_open())


## True at sea, where dismissal/appointment are refused (`officers.readonly_sea`,
## the §4.5.1 port-action rule).
func is_read_only() -> bool:
	var port = GameState.current_port
	return not (port is String and not (port as String).is_empty())


## The stat block the table shows (`"attributes"` | `"skills"`).
func stat_mode() -> String:
	return _stat_mode


## Switches the table's stat block (§4.6.2 amendment: the 属性/技能 toggle).
func set_stat_mode(mode: String) -> void:
	if mode != MODE_ATTRIBUTES and mode != MODE_SKILLS:
		return
	_stat_mode = mode
	_bind_toggles()
	if is_active() and _mode == "table":
		rebuild()


## The officer the detail page currently shows (`""` = table view).
func detail_officer() -> String:
	return _detail_officer


## Opens the detail page for `officer_id` (the row-click path; the window and
## the tests call this directly).
func open_detail(officer_id: String) -> void:
	_on_row_pressed(officer_id)


## The officer ids currently rendered, in display order (§4.6.2: sorted by id).
func officer_ids() -> Array:
	var out: Array = []
	for entry in _rows:
		out.append(str(entry["officer_id"]))
	return out


## Widget bundle of the row for `officer_id` (`{}` when not rendered).
func row_widget(officer_id: String) -> Dictionary:
	for entry in _rows:
		if str(entry["officer_id"]) == officer_id:
			return entry
	return {}


## Every widget bundle, in display order.
func rows() -> Array:
	return _rows.duplicate()


## The Dismiss button of `officer_id` — on the detail page (the table rows open
## the detail instead of carrying actions).
func dismiss_button(_officer_id: String = "") -> Button:
	return _detail_dismiss if _mode == "detail" else null


## The four action buttons of the open detail page
## (`{"talk": …, "gift": …, "train": …, "appoint": …}`).
func action_buttons(_officer_id: String = "") -> Dictionary:
	return _detail_action_map.duplicate() if _mode == "detail" else {}


## Total daily wage bill (`Σ wage_daily × wage_mult`, the §4.5 ledger step 2).
func total_wage() -> int:
	return CharacterLib.officer_wages()


## The `ui_strings` key explaining why `officer_id` cannot be dismissed, or `""`
## when it can. The one reason this view states is the at-sea rule (§4.6.2).
func dismiss_block_reason(_officer_id: String = "") -> String:
	return "officers.readonly_sea" if is_read_only() else ""


## The last action's feedback line ("" when none).
func result_text() -> String:
	return _result_text


## Rebuilds the view from live state. Called when the tab becomes active, on a
## locale change and after a dismissal. Guarded against re-entry: the action
## handlers rebuild inside their own signals.
var _rebuilding := false

func rebuild() -> void:
	if _rebuilding:
		return
	_rebuilding = true
	_slots.text = I18n.fmt("officers.slots", {
		"used": CharacterLib.officer_count(),
		"max": CharacterLib.OFFICER_MAX,
		"wage": total_wage(),
	})
	_mode_note.visible = is_read_only()
	_mode_note.text = I18n.t_key("officers.readonly_sea") if is_read_only() else ""
	_result.visible = not _result_text.is_empty()
	_result.text = _result_text
	_bind_toggles()
	if _mode == "detail" and not _detail_officer.is_empty() \
			and CharacterLib.employed_officers().has(_detail_officer):
		_build_detail(_detail_officer)
	else:
		_mode = "table"
		_detail_officer = ""
		_build_table()
	_rebuilding = false


## The 属性/技能 toggle buttons: pressed states + localized labels (§4.3 lists).
func _bind_toggles() -> void:
	_attributes_toggle.text = I18n.t_key("char.stats")
	_skills_toggle.text = I18n.t_key("char.card.skills")
	_attributes_toggle.button_pressed = _stat_mode == MODE_ATTRIBUTES
	_skills_toggle.button_pressed = _stat_mode == MODE_SKILLS
	for pair in [[MODE_ATTRIBUTES, _attributes_toggle],
			[MODE_SKILLS, _skills_toggle]]:
		var button: Button = pair[1]
		button.add_theme_color_override("font_color",
			PaletteLib.ACCENT if _stat_mode == str(pair[0]) else PaletteLib.TEXT)


# --- The table --------------------------------------------------------------

func _build_table() -> void:
	_table.visible = true
	_table_scroll.visible = true
	_table_empty.visible = false
	_table_empty_hint.visible = false
	_detail.visible = false
	_clear(_table)
	_rows.clear()

	_add_table_header()

	var officer_ids: Array = CharacterLib.employed_officers().duplicate()
	# §4.6.2: "one per employed officer, sorted by `id`".
	officer_ids.sort_custom(func(a, b) -> bool: return str(a) < str(b))
	for officer_id in officer_ids:
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		if officer.is_empty():
			# A dismissed/unknown id in `player.officers` must not crash the
			# roster; the retired S14 summary skipped it the same way (gotcha 5).
			continue
		_table.add_child(_build_row(str(officer_id), officer))

	var empty := _rows.is_empty()
	_table.visible = not empty
	_table_scroll.visible = not empty
	_table_empty.visible = empty
	_table_empty.text = I18n.t_key("char.no_officers")
	_table_empty_hint.visible = empty
	_table_empty_hint.text = I18n.t_key("officers.empty_hint")


## The table's header row: the fixed columns + the active stat block's names.
func _add_table_header() -> void:
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_cell(header, I18n.t_key("intel.officers.name"), COL_NAME_W, PaletteLib.ACCENT)
	header.get_child(0).name = "NameHeader"
	_cell(header, I18n.t_key("officer.post.idle").rstrip(" ·"), COL_POST_W,
		PaletteLib.ACCENT)
	header.get_child(1).name = "PostHeader"
	_cell(header, I18n.fmt("char.card.loyalty", {"amount": ""}).strip_edges(),
		COL_LOYALTY_W, PaletteLib.ACCENT)
	header.get_child(2).name = "LoyaltyHeader"
	_cell(header, I18n.t_key("intel.officers.wage"),
		COL_WAGE_W, PaletteLib.ACCENT)
	header.get_child(3).name = "WageHeader"
	var stat_keys: Array = _stat_keys()
	for key in stat_keys:
		_cell(header, I18n.t_key("skill.%s" % str(key))
			if _stat_mode == MODE_SKILLS
			else I18n.t_key("char.attr.%s" % str(key)),
			COL_STAT_W, PaletteLib.ACCENT)
		var head: Label = header.get_child(header.get_child_count() - 1)
		head.name = "Stat_%s" % str(key)
		head.tooltip_text = _stat_desc(str(key))
		head.mouse_filter = Control.MOUSE_FILTER_STOP
	_table.add_child(header)


## The stat ids the table shows in the active mode.
func _stat_keys() -> Array:
	if _stat_mode == MODE_ATTRIBUTES:
		return Array(CharacterLib.ATTRIBUTES, TYPE_STRING, "", "")
	return Array(SkillsLib.KEYS, TYPE_STRING, "", "") \
		+ Array(SkillsLib.OFFICER_KEYS, TYPE_STRING, "", "")


## One officer table row: a flat clickable row Control (the full-width HBox of
## cells lives inside it) — clicking (or Enter/Space on the focused row) opens
## the detail page (§4.6.2). The row Control is named at construction and the
## caller adds it to the table exactly once.
func _build_row(officer_id: String, officer: Dictionary) -> Control:
	var widgets: Dictionary = {"officer_id": officer_id, "cells": {}}
	var row := Control.new()
	row.name = "Officer_%s" % officer_id
	row.custom_minimum_size.y = float(PaletteLib.ROW_H)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.focus_mode = Control.FOCUS_ALL
	row.mouse_filter = Control.MOUSE_FILTER_STOP

	var line := HBoxContainer.new()
	line.name = "Line"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_child(line)
	row.gui_input.connect(_on_row_gui_input.bind(officer_id))

	var name_cell := _cell(line, I18n.t(officer.get("name", {})),
		COL_NAME_W, PaletteLib.TEXT)
	name_cell.name = "Name"
	var post_cell := _cell(line, _post_text(officer_id), COL_POST_W,
		PaletteLib.ACCENT)
	post_cell.name = "Post"
	var loyalty := SkillsLib.loyalty(officer_id)
	var loyalty_cell := _cell(line, str(loyalty), COL_LOYALTY_W,
		PaletteLib.GOOD if loyalty >= 80
		else (PaletteLib.WARN if loyalty < 30 else PaletteLib.TEXT))
	loyalty_cell.name = "Loyalty"
	widgets["cells"]["loyalty"] = loyalty_cell
	var wage_cell := _cell(line, I18n.fmt("tavern.wage", {
		"price": int(round(int(officer.get("wage_daily", 0))
			* _wage_mult(officer_id))),
	}), COL_WAGE_W, PaletteLib.PANEL_LINE)
	wage_cell.name = "Wage"
	widgets["cells"]["wage"] = wage_cell
	for key in _stat_keys():
		var value := int((officer.get("skills", {}) as Dictionary).get(str(key), 0)) \
			if _stat_mode == MODE_SKILLS \
			else int((officer.get("attributes", {}) as Dictionary).get(str(key), 0))
		var cell := _cell(line, str(value), COL_STAT_W, PaletteLib.TEXT)
		cell.name = "Stat_%s" % str(key)
		# The table is the only place these numbers appear (the detail card
		# omits the stat blocks), so each column carries the same hover
		# explanation the card's rows use (§4.12.1 amended).
		cell.tooltip_text = _stat_desc(str(key))
		widgets["cells"][str(key)] = cell

	# The add lives at the CALL SITE (`_build_table`); `_build_row` only
	# builds and returns the row — a second add here would trip the engine's
	# re-parent check (the "already has a parent" noise).
	_rows.append(widgets)
	return row


## The row's click/keyboard activation → the detail page (§4.6.2).
func _on_row_gui_input(event: InputEvent, officer_id: String) -> void:
	var clicked: bool = event is InputEventMouseButton \
		and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	var keyed: bool = event is InputEventKey and event.pressed \
		and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER \
			or event.keycode == KEY_SPACE)
	if clicked or keyed:
		_on_row_pressed(officer_id)


## The hover explanation for a stat id (`char.attr.<key>.desc` /
## `skill.<key>.desc`; amended 2026-11-03). Empty when absent, so a missing
## string degrades to "no tooltip" rather than to a raw "<key>".
func _stat_desc(key: String) -> String:
	var ui_key := "char.attr.%s.desc" % key \
		if key in CharacterLib.ATTRIBUTES else "skill.%s.desc" % key
	if not DataLoader.ui_strings.has(ui_key):
		return ""
	return I18n.t_key(ui_key)


## One table cell: a 13px label with a fixed width (the §4.8 sizing grid).
func _cell(parent: Container, text: String, width: float, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = width
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", CELL_FONT_SIZE)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


# --- The detail page --------------------------------------------------------

func _on_row_pressed(officer_id: String) -> void:
	_detail_officer = officer_id
	_mode = "detail"
	rebuild()


func _on_detail_back() -> void:
	_mode = "table"
	_detail_officer = ""
	rebuild()


func _build_detail(officer_id: String) -> void:
	_table.visible = false
	_table_scroll.visible = false
	_table_empty.visible = false
	_table_empty_hint.visible = false
	_detail.visible = true
	_detail_back.text = I18n.t_key("ui.back")
	_detail_back.grab_focus()

	# The §4.12 officer card (amended 2026-11-03: the stat blocks are omitted
	# here — the table above already owns the attribute/skill columns, and
	# repeating them pushed the actions below the fold).
	if _detail_card != null:
		_detail_card.queue_free()
	var card: Control = (load(CardLib.SCENE_PATH) as PackedScene).instantiate()
	card.name = "DetailCard"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_card_scroll.add_child(card)
	_detail_card = card
	card.setup_person(CardLib.KIND_OFFICER, CardLib.card_data(
		CardLib.KIND_OFFICER, officer_id, {"stat_blocks": false}))

	var officer: Dictionary = DataLoader.get_officer(officer_id)
	_detail_line.name = "DetailLine"
	_detail_line.text = "%s · %s · %s" % [
		_post_text(officer_id),
		I18n.fmt("tavern.wage", {
			"price": int(round(int(officer.get("wage_daily", 0))
				* _wage_mult(officer_id))),
		}),
		I18n.fmt("officers.recruited_at", {"port": recruit_port_name(officer)}),
	]

	_clear(_detail_actions)
	_detail_action_map = {}
	_detail_action_map["talk"] = _action_button(_detail_actions, officer_id,
		"talk", _talk_blocked_reason(officer_id))
	_detail_action_map["gift"] = _action_button(_detail_actions, officer_id,
		"gift", _gift_blocked_reason(officer_id))
	_detail_action_map["train"] = _action_button(_detail_actions, officer_id,
		"train", _train_blocked_reason(officer_id))
	_detail_action_map["appoint"] = _action_button(_detail_actions, officer_id,
		"appoint", I18n.t_key("officers.readonly_sea") if is_read_only() else "")
	_detail_dismiss = Button.new()
	_detail_dismiss.name = "Dismiss_%s" % officer_id
	_detail_dismiss.text = I18n.t_key("officers.dismiss")
	_detail_dismiss.custom_minimum_size = Vector2(float(COL_DISMISS_W),
		PaletteLib.BUTTON_H)
	var reason_key := dismiss_block_reason(officer_id)
	_detail_dismiss.disabled = not reason_key.is_empty()
	_detail_dismiss.tooltip_text = "" if reason_key.is_empty() \
		else I18n.t_key(reason_key)
	_detail_dismiss.pressed.connect(_on_dismiss_pressed.bind(officer_id))
	_detail_actions.add_child(_detail_dismiss)


func _action_button(parent: Container, officer_id: String, action: String,
		reason_text: String) -> Button:
	var button := Button.new()
	button.name = "%s_%s" % [action.capitalize(), officer_id]
	button.text = I18n.t_key("char.action.%s" % action)
	button.custom_minimum_size = Vector2(float(COL_ACTION_W), PaletteLib.BUTTON_H)
	button.disabled = not reason_text.is_empty()
	button.tooltip_text = reason_text
	match action:
		"talk":
			button.pressed.connect(_on_talk_pressed.bind(officer_id))
		"gift":
			button.pressed.connect(_on_gift_pressed.bind(officer_id))
		"train":
			button.pressed.connect(_on_train_pressed.bind(officer_id))
		"appoint":
			button.pressed.connect(_on_appoint_pressed.bind(officer_id))
	parent.add_child(button)
	return button


## Re-renders the open detail page in place (post/loyalty/cooldowns/gold moved).
func refresh_row(officer_id: String) -> void:
	if _mode == "detail" and _detail_officer == officer_id:
		_build_detail(officer_id)
	elif _mode == "table":
		_build_table()
	_slots.text = I18n.fmt("officers.slots", {
		"used": CharacterLib.officer_count(),
		"max": CharacterLib.OFFICER_MAX,
		"wage": total_wage(),
	})


# --- Post / wage data (the retired S18 row data, unchanged) -----------------

## The post column's text: the current post's name (with its ship for a
## captain seat) or the idle state (§4.6.2).
func _post_text(officer_id: String) -> String:
	var state: Dictionary = GameState.officer_states.get(officer_id, {})
	var post_id := str(state.get("post_id", ""))
	if post_id.is_empty():
		return I18n.t_key("officer.post.idle")
	var text := I18n.t_key("officer.post.%s" % post_id)
	if post_id == "captain":
		var ship_id := str(state.get("ship_id", ""))
		if not ship_id.is_empty():
			text += " · %s" % ship_id
	return text


func _wage_mult(officer_id: String) -> float:
	var state: Dictionary = GameState.officer_states.get(officer_id, {})
	return float(state.get("wage_mult", 1.0))


static func recruit_port_name(officer: Dictionary) -> String:
	var ports = officer.get("recruit_ports", [])
	if not (ports is Array) or (ports as Array).is_empty():
		return "-"
	var port: Dictionary = DataLoader.get_port(str((ports as Array)[0]))
	if port.is_empty():
		return "-"
	return I18n.t(port.get("name", {}))


# --- Action gating (§4.5.4 cooldowns, §4.3.4 training, §4.5.1 port rules) ---

func _cooldown_reason(officer_id: String, state_key: String) -> String:
	var state: Dictionary = GameState.officer_states.get(officer_id, {})
	var until := int(state.get(state_key, 0))
	if GameState.day < until:
		return I18n.fmt("char.action.cooldown", {"days": until - GameState.day})
	return ""


func _talk_blocked_reason(officer_id: String) -> String:
	return _cooldown_reason(officer_id, "talk_cd_day")


func _gift_blocked_reason(officer_id: String) -> String:
	var cooldown := _cooldown_reason(officer_id, "gift_cd_day")
	if not cooldown.is_empty():
		return cooldown
	return I18n.t_key("market.no_gold") \
		if GameState.gold < SkillsLib.GIFT_COST else ""


## The train action targets the officer's native main skill (the §4.5.2
## signature); the fee is the §4.3.4 formula (the player's level and INT,
## `SkillsLib.training_price`), the cap 60 blocks the raise.
func _train_blocked_reason(officer_id: String) -> String:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var main := str(officer.get("main_skill", ""))
	if int(officer.get("skills", {}).get(main, 0)) >= SkillsLib.TRAIN_CAP:
		return I18n.t_key("skill.train.capped")
	return I18n.t_key("market.no_gold") \
		if GameState.gold < SkillsLib.training_price(main) else ""


# --- Actions ---------------------------------------------------------------

func _on_talk_pressed(officer_id: String) -> void:
	if not _cooldown_reason(officer_id, "talk_cd_day").is_empty():
		return
	if not SkillsLib.talk(officer_id):
		return
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	_set_result(I18n.fmt("char.talk.result",
		{"name": I18n.t(officer.get("name", {}))}))
	refresh_row(officer_id)


func _on_gift_pressed(officer_id: String) -> void:
	if not _gift_blocked_reason(officer_id).is_empty():
		return
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var personality: Array = officer.get("personality", [])
	# The result line is keyed by the §4.5.4 gift table before the roll.
	var key := "char.gift.result"
	if "greedy" in personality:
		key = "char.gift.greedy"
	elif "honest" in personality or "loyal" in personality:
		key = "char.gift.loyal"
	if not SkillsLib.gift(officer_id):
		return
	_set_result(I18n.fmt(key, {"name": I18n.t(officer.get("name", {}))}))
	refresh_row(officer_id)


## §4.3.4 paid training against the officer's native main skill: the fee is
## `SkillsLib.training_price` (the player's level and INT own it — identical
## for the player's own skills), charged from the player gold; the +1 lands
## on the loaded officer card capped at the training cap 60 (the same
## canon-with-growth write the §4.3.2 growth clock performs). NOTE: `SkillsLib`
## carries no officer-side train function — this funnel implements the locked
## formula inline until a model home lands.
func _on_train_pressed(officer_id: String) -> void:
	if not _train_blocked_reason(officer_id).is_empty():
		return
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var main := str(officer.get("main_skill", ""))
	var fee := SkillsLib.training_price(main)
	GameState.add_gold(-fee)
	var skills: Dictionary = officer.get("skills", {})
	skills[main] = clampi(int(skills.get(main, 0)) + 1, 0, SkillsLib.TRAIN_CAP)
	officer["skills"] = skills
	_set_result(I18n.fmt("skill.train.done",
		{"name": _t("skill.%s" % main)}))
	refresh_row(officer_id)


func _on_appoint_pressed(officer_id: String) -> void:
	if is_read_only():
		return
	_open_appoint_dialog(officer_id)


func _set_result(text: String) -> void:
	_result_text = text
	_result.visible = not text.is_empty()
	_result.text = text


# --- The appoint dialog (§4.12.3 post table, prereq-gray + reasons) --------

## Opens the post table for `officer_id`: one row per flagship post, then one
## captain row per escort ship beyond the flagship (the §4.5.2 seat rule).
## Every row carries its prereq state — grayed with the per-item
## `gate.requires` reason, or the occupancy line when another officer holds
## the seat — plus the unassign row (always allowed).
func _open_appoint_dialog(officer_id: String) -> void:
	if _appoint_dialog != null:
		_appoint_dialog.queue_free()
	_appoint_dialog = AppointDialog.new()
	_appoint_dialog.roster_view = self
	add_child(_appoint_dialog)
	_appoint_dialog.open(officer_id)


func _close_appoint_dialog() -> void:
	if _appoint_dialog != null:
		_appoint_dialog.queue_free()
	_appoint_dialog = null


func appoint_dialog() -> Control:
	return _appoint_dialog


## The appoint dialog's data read (the tests walk the rows through this).
func appoint_rows() -> Array:
	if _appoint_dialog == null or not _appoint_dialog.is_open():
		return []
	return _appoint_dialog.rows()


# --- Dismissal (the shared funnel) -----------------------------------------

func _on_dismiss_pressed(officer_id: String) -> void:
	if not dismiss_block_reason(officer_id).is_empty():
		return
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var name_text := I18n.t(officer.get("name", {}))
	_pending_dismiss = officer_id
	# Destructive → confirm (§4.7 "one action per dialog"), through the shared
	# `confirm_dialog.tscn`.
	_confirm.open_key("officers.dismiss.confirm", {"name": name_text})


## The one dismissal path: [CharacterLib.dismiss] (the tavern screen's officers
## tab calls the same function), so "frees the slot and stops the wage from the
## next day tick" (§4.6.2) happens in one place.
func _on_dismiss_confirmed() -> void:
	var officer_id := _pending_dismiss
	_pending_dismiss = ""
	if officer_id.is_empty():
		return
	if not dismiss_block_reason(officer_id).is_empty():
		return
	if CharacterLib.dismiss(officer_id):
		officer_dismissed.emit(officer_id)
		_result_text = ""
		# The detail page of a dismissed officer is gone — back to the table.
		if _detail_officer == officer_id:
			_mode = "table"
			_detail_officer = ""
		rebuild()


func _on_dismiss_cancelled() -> void:
	_pending_dismiss = ""


# --- Helpers ---------------------------------------------------------------

## `ui_strings` key first, the panel's fallback table second (the W5-C
## `_inform_text` pattern).
static func _t(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return I18n.t(FALLBACK_STRINGS.get(key, {}))


func _label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _clear(container: Node) -> void:
	# Immediate `free()` (not queue_free): this view's rebuild never runs
	# inside one of its own row signals (the actions rebuild the DETAIL page,
	# whose widgets are replaced wholesale), so the queued-free ghost of a
	# removed row would trip Godot's add_child re-parent check on the next
	# same-frame rebuild.
	for child in container.get_children():
		container.remove_child(child)
		child.free()


func _on_locale_changed(_locale: String) -> void:
	if is_active():
		rebuild()


func _on_data_changed(_value: int = 0) -> void:
	if is_active():
		rebuild()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_data_changed):
		EventBus.gold_changed.disconnect(_on_data_changed)


# --- The appoint dialog (inner class; the view owns every rule above) -------

## The post-table modal: dim + panel + one row per appointable seat, each
## grayed with its reason when blocked. Data comes straight from
## `data/officer_posts.json`; the appointment goes through
## `SkillsLib.appoint` (the single funnel).
class AppointDialog:
	extends Control

	const DIM_ALPHA := 0.4
	const MODAL_GROUP := "modal_overlay"
	const COL_DISMISS_W := 140.0
	# Inner classes see autoloads and global classes but NOT the outer
	# script's consts — the preloads are re-declared here.
	const PaletteLib := preload("res://scripts/palette.gd")
	const CharacterLib := preload("res://scripts/player/character.gd")
	const SkillsLib := preload("res://scripts/player/skills.gd")

	## `FALLBACK_STRINGS` lives on the outer script; the dialog reads it
	## through the view instance (inner classes cannot see outer consts).
	var roster_view: Control = null
	var _open := false
	var _dialog_rows: Array = []
	var _officer_id := ""
	var _dim: ColorRect
	var _panel: PanelContainer
	var _title: Label
	var _rows_box: VBoxContainer
	var _close: Button

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_anchors_preset(Control.PRESET_FULL_RECT)
		_dim = ColorRect.new()
		_dim.name = "Dim"
		_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		_dim.color = Color(0, 0, 0, DIM_ALPHA)
		add_child(_dim)
		var center := CenterContainer.new()
		center.name = "Center"
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(center)
		_panel = PanelContainer.new()
		_panel.name = "Panel"
		_panel.custom_minimum_size = Vector2(720, 0)
		var style := StyleBoxFlat.new()
		style.bg_color = PaletteLib.PANEL_BG
		style.border_color = PaletteLib.PANEL_LINE
		style.set_border_width_all(2)
		_panel.add_theme_stylebox_override("panel", style)
		center.add_child(_panel)
		var margin := MarginContainer.new()
		margin.name = "Margin"
		for side in ["margin_left", "margin_top", "margin_right",
				"margin_bottom"]:
			margin.add_theme_constant_override(side, PaletteLib.MARGIN)
		_panel.add_child(margin)
		var body := VBoxContainer.new()
		body.name = "Body"
		body.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		margin.add_child(body)
		_title = Label.new()
		_title.name = "Title"
		_title.add_theme_color_override("font_color", PaletteLib.TEXT)
		_title.add_theme_font_size_override("font_size", 20)
		body.add_child(_title)
		var scroll := ScrollContainer.new()
		scroll.name = "Scroll"
		scroll.custom_minimum_size = Vector2(0, 360)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		body.add_child(scroll)
		_rows_box = VBoxContainer.new()
		_rows_box.name = "Rows"
		_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_rows_box.add_theme_constant_override("separation", 4)
		scroll.add_child(_rows_box)
		var footer := HBoxContainer.new()
		footer.name = "Footer"
		footer.alignment = BoxContainer.ALIGNMENT_END
		body.add_child(footer)
		_close = Button.new()
		_close.name = "Close"
		_close.text = I18n.t_key("ui.close")
		_close.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
		_close.pressed.connect(close)
		footer.add_child(_close)

	func open(id: String) -> void:
		_officer_id = id
		var officer: Dictionary = DataLoader.get_officer(id)
		var officer_name := I18n.t(officer.get("name", {}))
		_title.text = "%s · %s" % [officer_name, I18n.t_key("char.action.appoint")]
		_open = true
		visible = true
		add_to_group(MODAL_GROUP)
		_rebuild(id)
		_close.grab_focus()

	func close() -> void:
		if not _open:
			return
		_open = false
		visible = false
		remove_from_group(MODAL_GROUP)

	func is_open() -> bool:
		return _open

	func rows() -> Array:
		return _dialog_rows.duplicate()

	func _unhandled_input(event: InputEvent) -> void:
		if not _open:
			return
		if event.is_action_pressed("back"):
			get_viewport().set_input_as_handled()
			close()
			return
		get_viewport().set_input_as_handled()

	## The outer view's `_t` (inner classes cannot call outer statics by
	## bare name; going through the instance keeps the one fallback table).
	func _t(key: String) -> String:
		if roster_view != null:
			return roster_view._t(key)
		return I18n.t_key(key)

	func _rebuild(id: String) -> void:
		for child in _rows_box.get_children():
			_rows_box.remove_child(child)
			child.queue_free()
		_dialog_rows.clear()

		# The unassign row first (always allowed — §4.5.2).
		var state: Dictionary = GameState.officer_states.get(id, {})
		if not str(state.get("post_id", "")).is_empty():
			_add_post_row(id, "officer.post.to_idle", {}, "", "")

		# The flagship posts, in the data file's order (§4.5.2).
		for post in DataLoader.officer_posts_list:
			if str(post.get("slot_type", "")) != "flagship":
				continue
			_add_post_row(id, "officer.post.%s"
				% str(post.get("post_id", "")), post.get("prereq", {}),
				str(post.get("post_id", "")), "")

		# One captain seat per escort ship beyond the flagship (§4.5.2);
		# ship identity is the instance's `ship_type_id` today (the same
		# convention `SailingSim.captain_ship_ids` pins).
		for index in range(1, GameState.fleet.size()):
			var ship = GameState.fleet[index]
			if not (ship is Dictionary):
				continue
			_add_post_row(id, "officer.post.captain",
				DataLoader.get_officer_post("captain").get("prereq", {}),
				"captain", str(ship.get("ship_type_id", "")))

	func _add_post_row(id: String, label_key: String, prereq: Dictionary,
			post_id: String, ship_id: String) -> void:
		var row := HBoxContainer.new()
		row.name = "PostRow_%s_%s" % [post_id, ship_id]
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var reason := _blocked_reason(id, post_id, ship_id, prereq)
		var text := Label.new()
		text.name = "Label"
		text.text = _t(label_key) \
			+ (" · %s" % ship_id if not ship_id.is_empty() else "")
		text.add_theme_color_override("font_color",
			PaletteLib.TEXT if reason.is_empty() else PaletteLib.PANEL_LINE)
		text.custom_minimum_size.x = 260.0
		row.add_child(text)
		var reason_label := Label.new()
		reason_label.name = "Reason"
		reason_label.text = reason
		reason_label.add_theme_color_override("font_color", PaletteLib.WARN)
		reason_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(reason_label)
		var button := Button.new()
		button.name = "Appoint"
		button.text = _t("officer.post.to_idle") \
			if post_id.is_empty() else I18n.t_key("char.action.appoint")
		button.custom_minimum_size = Vector2(COL_DISMISS_W, PaletteLib.BUTTON_H)
		button.disabled = not reason.is_empty()
		button.pressed.connect(func() -> void:
			_do_appoint(id, post_id, ship_id))
		row.add_child(button)
		_rows_box.add_child(row)
		_dialog_rows.append({
			"post_id": post_id,
			"ship_id": ship_id,
			"button": button,
			"reason": reason,
			"label": text,
		})

	## The row's block reason: "" when appointable, else the localized line.
	func _blocked_reason(id: String, post_id: String, ship_id: String,
			prereq: Dictionary) -> String:
		if post_id.is_empty():
			return ""  # Unassign is always allowed (§4.5.2).
		var officer: Dictionary = DataLoader.get_officer(id)
		var failed: Array[String] = []
		for req_key in prereq:
			var value := int((officer.get("skills", {}) as Dictionary)
				.get(str(req_key),
					(officer.get("attributes", {}) as Dictionary)
					.get(str(req_key), 0)))
			if value < int(prereq[req_key]):
				failed.append(I18n.fmt("gate.requires", {
					"stat": _t("char.attr.%s" % str(req_key))
						if str(req_key) in CharacterLib.ATTRIBUTES
						else _t("skill.%s" % str(req_key)),
					"n": int(prereq[req_key]),
				}))
		if not failed.is_empty():
			return " · ".join(failed)
		# Occupancy: one person per flagship seat, one captain per ship.
		for other_id in GameState.player.get("officers", []):
			if str(other_id) == id:
				continue
			var other: Dictionary = GameState.officer_states.get(
				str(other_id), {})
			if str(other.get("post_id", "")) != post_id:
				continue
			if post_id != "captain" \
					or str(other.get("ship_id", "")) == ship_id:
				var other_officer: Dictionary = DataLoader.get_officer(
					str(other_id))
				return _t("officer.post.occupied").replace(
					"{name}", I18n.t(other_officer.get("name", {})))
		return ""

	func _do_appoint(id: String, post_id: String, ship_id: String) -> void:
		if not SkillsLib.appoint(id, post_id, ship_id):
			return
		if roster_view != null:
			roster_view.refresh_row(id)
			roster_view.rebuild()
		close()
