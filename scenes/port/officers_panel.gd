extends Control
## Officers panel (S18, the roster detail view) — docs/80-UI-UX.md §4.6.2
## (Phase-8 amendment) and §4.12.3; docs/50-* §4.5.
##
## One row per employed officer, sorted by id. The Phase-5 four-stat line and
## its derived-effect text are RETIRED with the old model (§4.6.2): each row
## renders the §4.12 character-card component in compact mode (attribute /
## skill bars, native-role tag, loyalty + current post in the relation block)
## plus the post column, `wage_daily`, the recruit port, the **four actions**
## talk / gift / train / appoint and `Dismiss`:
##   * talk  — loyalty +1, 10-day cooldown (`SkillsLib.talk`);
##   * gift  — 200g → +5 / greedy +8 / honest +3, 10-day cooldown
##     (`SkillsLib.gift`);
##   * train — the §4.3.4 paid-training formula against the officer's native
##     main skill, cap 60, fee from `SkillsLib.training_price` (the player's
##     level and INT own the fee);
##   * appoint — the post table (`data/officer_posts.json`), port-only,
##     prereq-gray with its `gate.requires` reason; the captain seat carries
##     a ship picker row per escort ship beyond the flagship;
##   * Dismiss — port-only, confirm dialog (the shared one-shot funnel).
##
## `appoint` / `Dismiss` are port actions (§4.5.1 promotion rule) and render
## disabled at sea with `officers.readonly_sea`; talk / gift / train work
## anywhere, each with its own cooldown shown on the row.
##
## Every rule lives in `scripts/player/skills.gd` / `character.gd` — the
## roster, OFFICER_MAX, the wage bill, the loyalty actions, the appointments.
## Nothing here invents a number.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
## The §4.12 card component (compact officer rows).
const CardLib := preload("res://scenes/ui/character_card.gd")

const SCENE_PATH := "res://scenes/port/officers_panel.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## ui_strings keys this panel needs that the shared table does not carry yet
## (the W5-C `FALLBACK_STRINGS` pattern — W6-D owns the residual merge).
## `char.attr.*` is the card's §4.2 attribute-name family, shared here for
## the `gate.requires` lines on prereqs that read an attribute (courage).
const FALLBACK_STRINGS := {
	"officer.post.occupied": {
		"zh": "在岗:{name}",
		"en": "In post: {name}",
	},
	"officer.post.to_idle": {
		"zh": "卸任(回闲置)",
		"en": "Unassign (to idle)",
	},
	"char.attr.constitution": {"zh": "体魄", "en": "Constitution"},
	"char.attr.intellect": {"zh": "悟性", "en": "Intellect"},
	"char.attr.charisma": {"zh": "魅力", "en": "Charisma"},
	"char.attr.courage": {"zh": "胆识", "en": "Courage"},
	"char.attr.luck": {"zh": "运气", "en": "Luck"},
}

## Column widths, on the §4.8 8px grid.
const COL_DISMISS_W := 140

## Emitted after a successful dismissal (tests / hosts).
signal officer_dismissed(officer_id: String)
## The node whose `set_sail()`/facility list can open this panel again.
var host: Node = null

## One widget bundle per officer row, in display order (`officer_id` included),
## so tests can walk exactly what is on screen.
var _rows: Array = []
## The officer awaiting dismissal confirmation (`""` = none).
var _pending_dismiss: String = ""
## The officer the appoint dialog is working for (`""` = closed).
var _pending_appoint: String = ""
## The appoint dialog (code-built over the panel chrome, {}-row pattern).
var _appoint_dialog: Control = null
## The last action's feedback line ("" = hidden).
var _result_text: String = ""

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _slots: Label = $Center/Panel/Margin/Body/Slots
@onready var _mode_note: Label = $Center/Panel/Margin/Body/ModeNote
@onready var _result: Label = $Center/Panel/Margin/Body/Result
@onready var _rows_box: VBoxContainer = $Center/Panel/Margin/Body/Scroll/Rows
@onready var _empty: Label = $Center/Panel/Margin/Body/Empty
@onready var _empty_hint: Label = $Center/Panel/Margin/Body/EmptyHint
@onready var _close_button: Button = $Center/Panel/Margin/Body/Footer/Close
@onready var _hint: Label = $Center/Panel/Margin/Body/Footer/Hint
@onready var _confirm: Control = $ConfirmDialog


## Installs a panel under `parent` (idempotent) and returns it, following the
## [FleetPanel]/[CharacterPanel] convention (a `Control` host gets it directly, a
## `Node2D` host gets it inside a `CanvasLayer`).
static func attach_to(parent: Node, panel_host: Node = null) -> Control:
	var existing := _find_panel(parent)
	if existing != null:
		if panel_host != null:
			existing.host = panel_host
		return existing
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("OfficersPanel.attach_to: missing %s" % SCENE_PATH)
		return null
	var panel := scene.instantiate()
	panel.name = "OfficersPanel"
	if panel_host != null:
		panel.host = panel_host
	if parent is Control:
		parent.add_child(panel)
	else:
		var layer := parent.get_node_or_null("OfficersLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "OfficersLayer"
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(panel)
	return panel


static func _find_panel(parent: Node) -> Control:
	var direct := parent.get_node_or_null("OfficersPanel")
	if direct is Control:
		return direct
	var layer := parent.get_node_or_null("OfficersLayer")
	if layer != null:
		var nested := layer.get_node_or_null("OfficersPanel")
		if nested is Control:
			return nested
	return null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 32)
	_slots.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_mode_note.add_theme_color_override("font_color", PaletteLib.WARN)
	_result.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_result.visible = false
	_empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_empty_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_close_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_close_button.pressed.connect(close)
	_confirm.confirmed.connect(_on_dismiss_confirmed)
	_confirm.cancelled.connect(_on_dismiss_cancelled)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_data_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _confirm.is_open() or (_appoint_dialog != null
			and _appoint_dialog.is_open()):
		return
	# `O` toggles the panel (§4.3 "S4 | O | open/close the officers panel").
	if event.is_action_pressed("toggle_officers"):
		get_viewport().set_input_as_handled()
		close()
		return
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	# Modal behaviour (§6 "modals consume all input").
	get_viewport().set_input_as_handled()


# --- Public API ------------------------------------------------------------

func open_on(panel_host: Node = null) -> void:
	if panel_host != null:
		host = panel_host
	open()


func open() -> void:
	if GameState.player.is_empty():
		# No run in progress (editor / title): an empty roster is not worth a
		# modal of its own.
		return
	visible = true
	add_to_group(MODAL_GROUP)
	rebuild()
	_close_button.grab_focus()


func close() -> void:
	visible = false
	remove_from_group(MODAL_GROUP)
	_pending_dismiss = ""
	_close_appoint_dialog()
	if _confirm != null and _confirm.is_open():
		_confirm.cancel()


func is_open() -> bool:
	return visible


func has_modal() -> bool:
	return visible or (_confirm != null and _confirm.is_open()) \
		or (_appoint_dialog != null and _appoint_dialog.is_open())


## True at sea, where dismissal/appointment are refused (`officers.readonly_sea`,
## the §4.5.1 port-action rule).
func is_read_only() -> bool:
	var port = GameState.current_port
	return not (port is String and not (port as String).is_empty())


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


## The Dismiss button of `officer_id` (null when not rendered).
func dismiss_button(officer_id: String) -> Button:
	var entry := row_widget(officer_id)
	return entry.get("dismiss", null)


## The four action buttons of `officer_id`
## (`{"talk": …, "gift": …, "train": …, "appoint": …}`).
func action_buttons(officer_id: String) -> Dictionary:
	var entry := row_widget(officer_id)
	return entry.get("actions", {})


## Total daily wage bill (`Σ wage_daily × wage_mult`, the §4.5 ledger step 2).
func total_wage() -> int:
	return CharacterLib.officer_wages()


## The `ui_strings` key explaining why `officer_id` cannot be dismissed, or `""`
## when it can. The single reason S18 states is the at-sea rule (§4.6.2).
func dismiss_block_reason(_officer_id: String = "") -> String:
	return "officers.readonly_sea" if is_read_only() else ""


## The last action's feedback line ("" when none).
func result_text() -> String:
	return _result_text


## Rebuilds the roster from live state. Called on open, on a locale change and
## after a dismissal.
func rebuild() -> void:
	_title.text = I18n.t_key("officers.title")
	_slots.text = I18n.fmt("officers.slots", {
		"used": CharacterLib.officer_count(),
		"max": CharacterLib.OFFICER_MAX,
		"wage": total_wage(),
	})
	_mode_note.visible = is_read_only()
	_mode_note.text = I18n.t_key("officers.readonly_sea") if is_read_only() else ""
	_result.visible = not _result_text.is_empty()
	_result.text = _result_text
	_close_button.text = I18n.t_key("ui.close")

	_clear(_rows_box)
	_rows.clear()
	var officer_ids: Array = CharacterLib.employed_officers().duplicate()
	# §4.6.2: "one per employed officer, sorted by `id`".
	officer_ids.sort_custom(func(a, b) -> bool: return str(a) < str(b))
	for officer_id in officer_ids:
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		if officer.is_empty():
			# A dismissed/unknown id in `player.officers` must not crash the
			# roster; the character panel skips it the same way (gotcha 5).
			continue
		_rows_box.add_child(_build_row(str(officer_id), officer))

	var empty := _rows.is_empty()
	_empty.visible = empty
	_empty.text = I18n.t_key("char.no_officers")
	_empty_hint.visible = empty
	_empty_hint.text = I18n.t_key("officers.empty_hint")


# --- Row construction ------------------------------------------------------

## One officer row (§4.6.2 Phase-8 shape): the compact §4.12 card (attribute /
## skill bars, native-role tag, loyalty + post relation line) and, beneath it,
## the post column + wage + recruit port line and the four actions + Dismiss.
func _build_row(officer_id: String, officer: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Officer_%s" % officer_id
	box.add_theme_constant_override("separation", 4)

	# The §4.12 card, compact.
	var card: Control = (load(CardLib.SCENE_PATH) as PackedScene).instantiate()
	card.name = "Card"
	box.add_child(card)
	card.setup_person(CardLib.KIND_OFFICER, CardLib.card_data(
		CardLib.KIND_OFFICER, officer_id, {"compact": true}))

	# Post column + wage + recruit port (§4.6.2 row data).
	var line := HBoxContainer.new()
	line.name = "PostLine"
	line.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var post := _label(_post_text(officer_id), PaletteLib.ACCENT)
	post.name = "Post"
	post.custom_minimum_size.x = 220.0
	line.add_child(post)
	var wage := _label(I18n.fmt("tavern.wage", {
		"price": int(round(int(officer.get("wage_daily", 0))
			* _wage_mult(officer_id))),
	}), PaletteLib.PANEL_LINE)
	wage.name = "Wage"
	wage.custom_minimum_size.x = 160.0
	line.add_child(wage)
	var recruited := _label(I18n.fmt("officers.recruited_at", {
		"port": recruit_port_name(officer),
	}), PaletteLib.PANEL_LINE)
	recruited.name = "RecruitedAt"
	recruited.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(recruited)
	box.add_child(line)

	# The four actions + Dismiss (§4.6.2 / §4.12.3).
	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var action_map := {}
	action_map["talk"] = _action_button(actions, officer_id, "talk",
		_talk_blocked_reason(officer_id))
	action_map["gift"] = _action_button(actions, officer_id, "gift",
		_gift_blocked_reason(officer_id))
	action_map["train"] = _action_button(actions, officer_id, "train",
		_train_blocked_reason(officer_id))
	action_map["appoint"] = _action_button(actions, officer_id, "appoint",
		I18n.t_key("officers.readonly_sea") if is_read_only() else "")
	var dismiss := Button.new()
	dismiss.name = "Dismiss_%s" % officer_id
	dismiss.text = I18n.t_key("officers.dismiss")
	dismiss.custom_minimum_size = Vector2(float(COL_DISMISS_W),
		PaletteLib.BUTTON_H)
	var reason_key := dismiss_block_reason(officer_id)
	dismiss.disabled = not reason_key.is_empty()
	dismiss.tooltip_text = "" if reason_key.is_empty() \
		else I18n.t_key(reason_key)
	dismiss.pressed.connect(_on_dismiss_pressed.bind(officer_id))
	actions.add_child(dismiss)
	box.add_child(actions)

	_rows.append({
		"officer_id": officer_id,
		"node": box,
		"card": card,
		"post": post,
		"wage": wage,
		"recruited": recruited,
		"actions": action_map,
		"dismiss": dismiss,
	})
	return box


func _action_button(parent: Container, officer_id: String, action: String,
		reason_text: String) -> Button:
	var button := Button.new()
	button.name = "%s_%s" % [action.capitalize(), officer_id]
	button.text = I18n.t_key("char.action.%s" % action)
	button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
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
## canon-with-growth write the §4.3.2 growth clock performs). NOTE for the
## report: `SkillsLib` carries no officer-side train function yet — this
## funnel implements the locked formula inline until a model home lands.
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


## Re-renders one officer row in place (post/loyalty/cooldowns/gold moved).
func refresh_row(officer_id: String) -> void:
	var entry := row_widget(officer_id)
	if entry.is_empty():
		return
	var post: Label = entry["post"]
	post.text = _post_text(officer_id)
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var wage: Label = entry["wage"]
	wage.text = I18n.fmt("tavern.wage", {
		"price": int(round(int(officer.get("wage_daily", 0))
			* _wage_mult(officer_id))),
	})
	var card: Control = entry["card"]
	card.setup_person(CardLib.KIND_OFFICER, CardLib.card_data(
		CardLib.KIND_OFFICER, officer_id, {"compact": true}))
	var actions: Dictionary = entry["actions"]
	for pair in [["talk", _talk_blocked_reason(officer_id)],
			["gift", _gift_blocked_reason(officer_id)],
			["train", _train_blocked_reason(officer_id)],
			["appoint", I18n.t_key("officers.readonly_sea")
				if is_read_only() else ""]]:
		var button: Button = actions.get(str(pair[0]), null)
		if button == null:
			continue
		var reason := str(pair[1])
		button.disabled = not reason.is_empty()
		button.tooltip_text = reason
	_slots.text = I18n.fmt("officers.slots", {
		"used": CharacterLib.officer_count(),
		"max": CharacterLib.OFFICER_MAX,
		"wage": total_wage(),
	})


# --- The appoint dialog (§4.12.3 post table, prereq-gray + reasons) --------

## Opens the post table for `officer_id`: one row per flagship post, then one
## captain row per escort ship beyond the flagship (the §4.5.2 seat rule).
## Every row carries its prereq state — grayed with the per-item
## `gate.requires` reason, or the occupancy line when another officer holds
## the seat — plus the unassign row (always allowed).
func _open_appoint_dialog(officer_id: String) -> void:
	_pending_appoint = officer_id
	if _appoint_dialog != null:
		_appoint_dialog.queue_free()
	_appoint_dialog = _make_dialog_shell()
	add_child(_appoint_dialog)
	_appoint_dialog.open(officer_id)


func _close_appoint_dialog() -> void:
	if _appoint_dialog != null:
		_appoint_dialog.queue_free()
	_appoint_dialog = null
	_pending_appoint = ""


func appoint_dialog() -> Control:
	return _appoint_dialog


## The code-built dialog shell (the confirm-dialog chrome pattern, one
## action per dialog — §4.7).
func _make_dialog_shell() -> Control:
	var dialog := AppointDialog.new()
	dialog.officers_panel = self
	return dialog


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
		rebuild()


func _on_dismiss_cancelled() -> void:
	_pending_dismiss = ""


# --- Helpers ---------------------------------------------------------------

## `ui_strings` key first, the panel's fallback table second (the W5-C
## `_inform_text` pattern — the residual merge is W6-D's).
static func _t(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return I18n.t(FALLBACK_STRINGS.get(key, {}))


## `_t` plus `{name}` substitution for a fallback key (the I18n.fmt shape).
static func _fmt(key: String, values: Dictionary = {}) -> String:
	var text := _t(key)
	for name in values:
		text = text.replace("{%s}" % name, str(values[name]))
	return text


func _label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _on_locale_changed(_locale: String) -> void:
	if visible:
		rebuild()


func _on_data_changed(_value: int = 0) -> void:
	if visible:
		rebuild()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_data_changed):
		EventBus.gold_changed.disconnect(_on_data_changed)


# --- The appoint dialog (inner class; the panel owns every rule above) ------

## The post-table modal: dim + panel + one row per appointable seat, each
## grayed with its reason when blocked. Data comes straight from
## `data/officer_posts.json`; the appointment goes through
## `SkillsLib.appoint` (the single funnel).
class AppointDialog:
	extends Control

	const DIM_ALPHA := 0.4
	const MODAL_GROUP := "modal_overlay"
	# Inner classes see autoloads and global classes but NOT the outer
	# script's consts — the preloads are re-declared here.
	const PaletteLib := preload("res://scripts/palette.gd")
	const CharacterLib := preload("res://scripts/player/character.gd")
	const SkillsLib := preload("res://scripts/player/skills.gd")

	var officers_panel: Control = null
	var _open := false
	var _dialog_rows: Array = []
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

	func open(officer_id: String) -> void:
		var officer: Dictionary = DataLoader.get_officer(officer_id)
		var name := I18n.t(officer.get("name", {}))
		_title.text = "%s · %s" % [name, I18n.t_key("char.action.appoint")]
		_open = true
		visible = true
		add_to_group(MODAL_GROUP)
		_rebuild(officer_id)
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

	func _rebuild(officer_id: String) -> void:
		for child in _rows_box.get_children():
			_rows_box.remove_child(child)
			child.queue_free()
		_dialog_rows.clear()

		# The unassign row first (always allowed — §4.5.2).
		var state: Dictionary = GameState.officer_states.get(officer_id, {})
		if not str(state.get("post_id", "")).is_empty():
			_add_post_row(officer_id, "officer.post.to_idle", {}, "", "")

		# The flagship posts, in the data file's order (§4.5.2).
		for post in DataLoader.officer_posts_list:
			if str(post.get("slot_type", "")) != "flagship":
				continue
			_add_post_row(officer_id, "officer.post.%s"
				% str(post.get("post_id", "")), post.get("prereq", {}),
				str(post.get("post_id", "")), "")

		# One captain seat per escort ship beyond the flagship (§4.5.2);
		# ship identity is the instance's `ship_type_id` today (the same
		# convention `SailingSim.captain_ship_ids` pins).
		for index in range(1, GameState.fleet.size()):
			var ship = GameState.fleet[index]
			if not (ship is Dictionary):
				continue
			_add_post_row(officer_id, "officer.post.captain",
				DataLoader.get_officer_post("captain").get("prereq", {}),
				"captain", str(ship.get("ship_type_id", "")))

	func _add_post_row(officer_id: String, label_key: String, prereq: Dictionary,
			post_id: String, ship_id: String) -> void:
		var row := HBoxContainer.new()
		row.name = "PostRow_%s_%s" % [post_id, ship_id]
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var reason := _blocked_reason(officer_id, post_id, ship_id, prereq)
		var text := Label.new()
		text.name = "Label"
		text.text = officers_panel._t(label_key) \
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
		button.text = officers_panel._t("officer.post.to_idle") \
			if post_id.is_empty() else I18n.t_key("char.action.appoint")
		button.custom_minimum_size = Vector2(140, PaletteLib.BUTTON_H)
		button.disabled = not reason.is_empty()
		button.pressed.connect(func() -> void:
			_do_appoint(officer_id, post_id, ship_id))
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
	func _blocked_reason(officer_id: String, post_id: String, ship_id: String,
			prereq: Dictionary) -> String:
		if post_id.is_empty():
			return ""  # Unassign is always allowed (§4.5.2).
		var officer: Dictionary = DataLoader.get_officer(officer_id)
		var failed: Array[String] = []
		for req_key in prereq:
			var value := int((officer.get("skills", {}) as Dictionary)
				.get(str(req_key),
					(officer.get("attributes", {}) as Dictionary)
					.get(str(req_key), 0)))
			if value < int(prereq[req_key]):
				failed.append(I18n.fmt("gate.requires", {
					"stat": officers_panel._t("char.attr.%s" % str(req_key))
						if str(req_key) in CharacterLib.ATTRIBUTES
						else officers_panel._t("skill.%s" % str(req_key)),
					"n": int(prereq[req_key]),
				}))
		if not failed.is_empty():
			return " · ".join(failed)
		# Occupancy: one person per flagship seat, one captain per ship.
		for other_id in GameState.player.get("officers", []):
			if str(other_id) == officer_id:
				continue
			var other: Dictionary = GameState.officer_states.get(
				str(other_id), {})
			if str(other.get("post_id", "")) != post_id:
				continue
			if post_id != "captain" \
					or str(other.get("ship_id", "")) == ship_id:
				var other_officer: Dictionary = DataLoader.get_officer(
					str(other_id))
				return officers_panel._fmt("officer.post.occupied", {"name":
					I18n.t(other_officer.get("name", {}))})
		return ""

	func _do_appoint(officer_id: String, post_id: String, ship_id: String) -> void:
		if not SkillsLib.appoint(officer_id, post_id, ship_id):
			return
		if officers_panel != null:
			officers_panel.refresh_row(officer_id)
			officers_panel.rebuild()
		close()
