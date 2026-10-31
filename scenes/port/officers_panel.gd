extends Control
## Officers panel (S18) — docs/80-UI-UX.md §4.6.2, docs/50-* §4.2/§4.4/§4.5.
##
## The **detail view** of the roster: one row per employed officer with the four
## stats, the daily wage, the **derived effect** that officer contributes, the
## recruit port and a `Dismiss` action. S14's right-hand officer *summary* stays
## as it is (§4.6.2: "this panel is the detail view").
##
## Opened three ways, all of them on S4:
##   * the `O` key (§4.3),
##   * the `port.officers` footer row on the hub,
##   * the `Officers` button on the S14 character panel.
##
## **Every rule lives in [CharacterLib]** — the roster (`employed_officers`),
## `OFFICER_MAX`, the wage bill (`officer_wages`), the derived formulas
## (`sighting_radius_for`, `speed_bonus_for`, `loss_multiplier_for`, the role →
## stat table) and the dismissal path (`dismiss`, the same one the tavern
## screen's officers tab calls). Nothing here invents a number.
##
## Derived effects, per `50-*` §4.2/§4.5 — each is the *difference* this officer
## makes to the player's effective stat, so a navigator reads "+10 navigation →
## +1 tile of sighting radius" and a boatswain "+10 seamanship → +10% speed":
##   * navigation  → sighting radius (`24 + floor((navigation − 10) / 10)`),
##   * seamanship  → speed bonus (`(seamanship − 10) / 100`, clamped ±),
##   * leadership  → mutiny/desertion multiplier (`1 − (leadership − 10) / 200`),
##   * combat      → the battle/duel base (`Duel.player_base`, a note here),
##   * luck        → the storm multipliers (`50-*` §4.2), qualitative.
##
## Read-only at sea (`officers.readonly_sea`): dismissal is a port action, the
## same rule as S15. No textures; 32px rows, §4.8 palette.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

const SCENE_PATH := "res://scenes/port/officers_panel.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## Officer role → localised tag (`80-*` §4.6.2 "role tag"). The tavern already
## owns these three labels and S14 reuses them, so S18 reuses them too — no new
## keys, no second wording for "Navigator".
const ROLE_KEYS := {
	"navigator": "tavern.role.navigator",
	"boatswain": "tavern.role.boatswain",
	"gunner": "tavern.role.gunner",
}
## The four stats S18 lists (§4.6.2), in the wireframe order.
const STAT_KEYS: Array[String] = [
	"leadership", "seamanship", "combat", "navigation",
]
## Column widths, on the §4.8 8px grid.
const COL_NAME_W := 220
const COL_ROLE_W := 130
const COL_STAT_W := 72
const COL_WAGE_W := 120
const COL_DISMISS_W := 140

## Emitted after a successful dismissal (tests / hosts).
signal officer_dismissed(officer_id: String)
## The node whose `set_sail()`/facility list can open this panel again.
var host: Node = null

## One widget bundle per officer row, in display order (`officer_id` included),
## so tests can walk exactly what is on screen.
var _rows: Array = []
## The officer awaiting confirmation (`""` = none).
var _pending_dismiss: String = ""

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _slots: Label = $Center/Panel/Margin/Body/Slots
@onready var _mode_note: Label = $Center/Panel/Margin/Body/ModeNote
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
	if _confirm.is_open():
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
	if _confirm != null and _confirm.is_open():
		_confirm.cancel()


func is_open() -> bool:
	return visible


func has_modal() -> bool:
	return visible or (_confirm != null and _confirm.is_open())


## True at sea, where dismissal is refused (`officers.readonly_sea`, same rule
## as S15's `is_read_only`).
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


## Total daily wage bill (`Σ wage_daily`, the §4.5 ledger step 2 number).
func total_wage() -> int:
	return CharacterLib.officer_wages()


## The `ui_strings` key explaining why `officer_id` cannot be dismissed, or `""`
## when it can. The single reason S18 states is the at-sea rule (§4.6.2).
func dismiss_block_reason(_officer_id: String = "") -> String:
	return "officers.readonly_sea" if is_read_only() else ""


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

## One 32px officer row (a VBox of three 32px lines, as in the §4.6.2
## wireframe):
##   1. name + role tag
##   2. the four stats + `wage_daily`
##   3. derived effect + recruit port + `Dismiss`
func _build_row(officer_id: String, officer: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Officer_%s" % officer_id
	box.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	header.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var name_label := _label(I18n.t(officer.get("name", {})), PaletteLib.TEXT)
	name_label.name = "Name"
	name_label.custom_minimum_size.x = float(COL_NAME_W)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)
	var role_label := _label(I18n.t_key(_role_key(officer)), PaletteLib.ACCENT)
	role_label.name = "Role"
	role_label.custom_minimum_size.x = float(COL_ROLE_W)
	role_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(role_label)
	box.add_child(header)

	var stats := HBoxContainer.new()
	stats.name = "Stats"
	stats.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	stats.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	for stat_key in STAT_KEYS:
		var value := int((officer.get("stats", {}) as Dictionary).get(stat_key, 0))
		var cell := _label("%s %d" % [I18n.t_key("char.%s" % stat_key), value],
			PaletteLib.TEXT)
		cell.name = "Stat_%s" % stat_key
		cell.custom_minimum_size.x = float(COL_STAT_W)
		stats.add_child(cell)
	var wage := _label(I18n.fmt("tavern.wage", {
		"price": int(officer.get("wage_daily", 0)),
	}), PaletteLib.PANEL_LINE)
	wage.name = "Wage"
	wage.custom_minimum_size.x = float(COL_WAGE_W)
	wage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wage.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stats.add_child(wage)
	box.add_child(stats)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	footer.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var effect := _label(I18n.fmt("officers.effect", {
		"effect": effect_text(str(officer_id)),
	}), PaletteLib.TEXT)
	effect.name = "Effect"
	effect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(effect)
	var recruited := _label(I18n.fmt("officers.recruited_at", {
		"port": recruit_port_name(officer),
	}), PaletteLib.PANEL_LINE)
	recruited.name = "RecruitedAt"
	recruited.custom_minimum_size.x = float(COL_NAME_W)
	footer.add_child(recruited)

	var button := Button.new()
	button.name = "Dismiss_%s" % officer_id
	button.text = I18n.t_key("officers.dismiss")
	button.custom_minimum_size = Vector2(float(COL_DISMISS_W), float(PaletteLib.BUTTON_H))
	var reason_key := dismiss_block_reason(officer_id)
	button.disabled = not reason_key.is_empty()
	button.tooltip_text = "" if reason_key.is_empty() else I18n.t_key(reason_key)
	button.pressed.connect(_on_dismiss_pressed.bind(officer_id))
	footer.add_child(button)
	box.add_child(footer)

	_rows.append({
		"officer_id": officer_id,
		"node": box,
		"name": name_label,
		"role": role_label,
		"stats": stats,
		"wage": wage,
		"effect": effect,
		"recruited": recruited,
		"dismiss": button,
	})
	return box


# --- Derived effects (docs/50-* §4.2, §4.5) --------------------------------

## The localised role tag for `officer` (`tavern.role.*` — the same three labels
## the tavern and S14 already use, so "Navigator" is never worded twice;
## `char.none` for an unknown role rather than a raw key).
static func _role_key(officer: Dictionary) -> String:
	return str(ROLE_KEYS.get(str(officer.get("role", "")), "char.none"))


## What this officer's role contributes, in the §4.6.2 wireframe's form
## ("侦察半径 +0 · 航行加成 +0%").
##
## Every role grants a flat **+10** to one stat (`CharacterLib.ROLE_STAT_BONUS`,
## `50-*` §4.5). The effect is that bonus run through the **existing** derived
## formula, then differenced against the roster without this officer:
##
## | role | derived formula (`50-*` §4.2) | what the row shows |
## |---|---|---|
## | navigator | `sighting_radius_for(nav)` = `24 + floor((nav − 10) / 10)` | the tiles of sighting radius the +10 buys |
## | boatswain | `speed_bonus_for(sm)` = `(sm − 10) / 100`, clamped | the % of speed the +10 buys |
## | gunner | `effective_stat("combat")` — the battle/duel base (`60-*` §4.11.5) | the +combat, labelled as a battle/duel effect |
##
## `leadership` and `luck` are **not** role bonuses (`50-*` §4.5's table grants
## only navigation / seamanship / combat), so an officer's own `leadership` and
## `luck` numbers are displayed as data but contribute nothing to the player's
## effective stats. The row therefore makes no leadership claim — inventing one
## would be a mechanic the docs do not have. The mutiny/desertion formula stays
## reachable from the roster through [method mutiny_multiplier_text], where it is
## a fact about the whole roster rather than a per-officer credit.
##
## Strings: every noun is an existing `ui_strings` key. The effect reads as
## "<stat name> +N (<derived value>)" — no new key has to be minted here.
func effect_text(officer_id: String) -> String:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		return I18n.t_key("char.none")
	var role := str(officer.get("role", ""))
	var bonus: Dictionary = CharacterLib.ROLE_STAT_BONUS.get(role, {})
	var parts: Array[String] = []
	for stat_key in bonus:
		var amount := int(bonus[stat_key])
		parts.append("%s +%d" % [I18n.t_key("char.%s" % stat_key), amount])
		parts.append(_derived_for(role, stat_key))
	var text := " · ".join(parts)
	return I18n.t_key("char.none") if text.is_empty() else text


## The derived value a role's +10 buys, as a short phrase. One place per role,
## each reading an **existing** [CharacterLib] formula (§4.2) — never a second
## implementation of it.
##
## The nouns are borrowed from keys that already name the thing, because this
## task may add only the §4.7.6 keys:
##   * sighting radius → `chart.hint` ("Explored waters"): the radius is the
##     number of tiles of water/ports your navigator reveals;
##   * speed          → `world.speed` with the placeholder emptied ("Speed");
##   * battle/duel    → `battle.title` ("Battle"), the surface combat feeds
##     (`50-*` §4.2: "no Phase-1 effect (consumed by `60-*`)").
static func _derived_for(role: String, stat_key: String) -> String:
	var amount := int(
		(CharacterLib.ROLE_STAT_BONUS.get(role, {}) as Dictionary).get(stat_key, 0)
	)
	match stat_key:
		"navigation":
			# `24 + floor((navigation − 10) / 10)`: the +10 buys one tile. Shown
			# as the contribution *and* the resulting radius, so the row answers
			# both "what does this officer add?" and "what is it now?".
			var with_radius := CharacterLib.sighting_radius_for(
				CharacterLib.effective_stat("navigation")
			)
			var without_radius := CharacterLib.sighting_radius_for(
				CharacterLib.effective_stat("navigation") - amount
			)
			return "%s %+d (%d)" % [
				_noun("chart.hint"), with_radius - without_radius, with_radius,
			]
		"seamanship":
			# `(seamanship − 10) / 100`, clamped: the +10 buys ten per cent.
			var with_speed := CharacterLib.speed_bonus_for(
				CharacterLib.effective_stat("seamanship")
			)
			var without_speed := CharacterLib.speed_bonus_for(
				CharacterLib.effective_stat("seamanship") - amount
			)
			return "%s %+d%%" % [
				_noun("world.speed"),
				int(round((with_speed - without_speed) * 100.0)),
			]
		"combat":
			return _noun("battle.title")
		"leadership":
			# Reachable only if `50-*` §4.5 ever grants a leadership bonus; the
			# formula is `CharacterLib.loss_multiplier_for`, never re-derived.
			var with_loss := CharacterLib.loss_multiplier_for(
				CharacterLib.effective_stat("leadership")
			)
			var without_loss := CharacterLib.loss_multiplier_for(
				CharacterLib.effective_stat("leadership") - amount
			)
			return "%s %+d%%" % [
				_noun("world.mutiny.title"),
				int(round((with_loss - without_loss) * 100.0)),
			]
		_:
			return ""


## A lone noun from a formatted `ui_strings` key: the key is formatted with an
## empty `amount`/`speed`/… and stripped, so "航速 {speed}" yields "航速" and
## "Speed {speed}" yields "Speed". No key is minted for a bare noun.
static func _noun(fmt_key: String) -> String:
	var values := {}
	for name in ["amount", "speed", "crew", "max", "capacity", "gold", "port",
			"day", "qty", "name", "days", "price", "current", "used", "free",
			"cannons", "slots", "wind", "kind"]:
		values[name] = ""
	return I18n.fmt(fmt_key, values).strip_edges()


## The roster's aggregate mutiny/desertion multiplier, as `50-*` §4.2 gives it
## (`1 − (leadership − 10) / 200`, floored at 0), rendered for any host that
## wants to show it. The per-officer rows deliberately do **not** credit it: the
## §4.5 role table grants no leadership bonus.
static func mutiny_multiplier_text() -> String:
	return "%s %d%%" % [
		I18n.t_key("world.mutiny.title"),
		int(round(CharacterLib.mutiny_multiplier() * 100.0)),
	]


## The officer's own first recruit port, localised (§4.6.2 "the recruit port").
## A missing list renders "-": the panel must never print a raw id.
static func recruit_port_name(officer: Dictionary) -> String:
	var ports = officer.get("recruit_ports", [])
	if not (ports is Array) or (ports as Array).is_empty():
		return "-"
	var port: Dictionary = DataLoader.get_port(str((ports as Array)[0]))
	if port.is_empty():
		return "-"
	return I18n.t(port.get("name", {}))


# --- Actions ---------------------------------------------------------------

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
		rebuild()


func _on_dismiss_cancelled() -> void:
	_pending_dismiss = ""


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


# --- Helpers ---------------------------------------------------------------

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
