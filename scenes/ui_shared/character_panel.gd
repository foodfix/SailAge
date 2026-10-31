class_name CharacterPanel
extends Control
## Character / status panel (S14) — docs/80-UI-UX.md §4.1, §4.2, §4.3;
## docs/50-* §4.2–§4.6.
##
## Parent-agnostic modal: it can be dropped into any scene with
## [method attach_to], and from then on it owns the `C` key
## (`toggle_character`) and `Esc` (`back`) while open. The T6/T11 screens only
## need to call `CharacterPanel.attach_to(self)` in their `_ready`.
##
## Shows LIVE state: the panel rebuilds from `GameState` every time it opens
## and again on `EventBus.fleet_changed` / `gold_changed` while open, so a
## mid-panel change can never show stale numbers.
##
## Host wiring: the panel registers as `class_name CharacterPanel` (used by
## T6/T11 as `CharacterPanel.attach_to(self)`), which needs Godot's global
## class cache — open the project in the editor once before running. A host
## that must survive a cold cache can instead use
## `preload("res://scenes/ui_shared/character_panel.gd").attach_to(self)`.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
## S18 officers detail panel (docs/80-* §4.6.2): the footer button opens it, so
## the roster has the two entry points the doc names (S4's facility list and the
## character panel). Preloaded by path so a cold class cache is harmless.
const OfficersPanelLib := preload("res://scenes/port/officers_panel.gd")

const SCENE_PATH := "res://scenes/ui_shared/character_panel.tscn"
## Dim strength for modals (docs/80-* §4.7: "dimming the background by 40% black").
const DIM_ALPHA := 0.4

## Tab ids (docs/80-* §4.7.3: the Phase-3 `Quests` tab sits beside the stats).
const TAB_STATS := "stats"
const TAB_QUESTS := "quests"

const STAT_KEYS: Array[String] = [
	"leadership", "seamanship", "combat", "navigation", "luck",
]
## docs/50-* §4.5: Phase-1 hint that gunner bonuses are combat-only (P2).
const ROLE_KEYS := {
	"navigator": "tavern.role.navigator",
	"boatswain": "tavern.role.boatswain",
	"gunner": "tavern.role.gunner",
}

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _nation: Label = $Center/Panel/Margin/Body/Nation
@onready var _level: Label = $Center/Panel/Margin/Body/Columns/Left/Level
@onready var _xp: Label = $Center/Panel/Margin/Body/Columns/Left/Xp
@onready var _next: Label = $Center/Panel/Margin/Body/Columns/Left/Next
@onready var _stats_header: Label = $Center/Panel/Margin/Body/Columns/Left/StatsHeader
@onready var _stats_rows: VBoxContainer = $Center/Panel/Margin/Body/Columns/Left/StatsRows
@onready var _officers_header: Label = \
	$Center/Panel/Margin/Body/Columns/Right/OfficersHeader
@onready var _officers_rows: VBoxContainer = \
	$Center/Panel/Margin/Body/Columns/Right/OfficersRows
@onready var _wage: Label = $Center/Panel/Margin/Body/Columns/Right/Wage
@onready var _reputation_header: Label = \
	$Center/Panel/Margin/Body/Columns/Right/ReputationHeader
@onready var _reputation_rows: GridContainer = \
	$Center/Panel/Margin/Body/Columns/Right/ReputationRows
@onready var _levelup: Label = $Center/Panel/Margin/Body/LevelUp
@onready var _stats_tab: Button = $Center/Panel/Margin/Body/Tabs/StatsTab
@onready var _quests_tab: Button = $Center/Panel/Margin/Body/Tabs/QuestsTab
@onready var _columns: HBoxContainer = $Center/Panel/Margin/Body/Columns
@onready var _quests_panel: VBoxContainer = $Center/Panel/Margin/Body/QuestsPanel
@onready var _quest_slots: Label = $Center/Panel/Margin/Body/QuestsPanel/Slots
@onready var _quest_rows: VBoxContainer = \
	$Center/Panel/Margin/Body/QuestsPanel/Scroll/Rows
@onready var _quest_empty: Label = $Center/Panel/Margin/Body/QuestsPanel/Empty
@onready var _close_button: Button = $Center/Panel/Margin/Body/Footer/Close
@onready var _officers_button: Button = $Center/Panel/Margin/Body/Footer/Officers
@onready var _hint: Label = $Center/Panel/Margin/Body/Footer/Hint

## The visible tab ([constant TAB_STATS] / [constant TAB_QUESTS]).
var _tab: String = TAB_STATS


## Installs a panel under `parent` (idempotent) and returns it. T6/T11 call
## this from their `_ready`; the panel then handles `C`/Esc itself.
##
## When `parent` is a `Control` (port screen) the panel becomes its child and
## fills it. When it is not (the world map is a `Node2D`), the panel is placed
## in a `CanvasLayer` so it neither inherits the camera transform nor collapses
## to a zero-size rect — a `Control` under a `Node2D` has no parent geometry to
## anchor against.
static func attach_to(parent: Node) -> Control:
	var existing := _find_panel(parent)
	if existing != null:
		return existing
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("CharacterPanel.attach_to: missing %s" % SCENE_PATH)
		return null
	var panel := scene.instantiate()
	panel.name = "CharacterPanel"
	if parent is Control:
		parent.add_child(panel)
	else:
		var layer := parent.get_node_or_null("CharacterPanelLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "CharacterPanelLayer"
			# Above the host screen's own canvas so the modal dims everything.
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(panel)
	return panel


## Finds an already-attached panel under `parent`, whether it sits directly
## there (Control host) or inside the CanvasLayer wrapper (Node2D host).
static func _find_panel(parent: Node) -> Control:
	var direct := parent.get_node_or_null("CharacterPanel")
	if direct is Control:
		return direct
	var layer := parent.get_node_or_null("CharacterPanelLayer")
	if layer != null:
		var nested := layer.get_node_or_null("CharacterPanel")
		if nested is Control:
			return nested
	return null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	for label in [_title, _nation, _level, _xp, _next, _wage, _levelup]:
		label.add_theme_color_override(
			"font_color",
			PaletteLib.ACCENT if label == _levelup else PaletteLib.TEXT
		)
	for header in [_stats_header, _officers_header, _reputation_header]:
		header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_quest_empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_quest_slots.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_close_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_close_button.pressed.connect(close)
	_officers_button.custom_minimum_size = Vector2(160, PaletteLib.BUTTON_H)
	_officers_button.pressed.connect(open_officers_panel)
	_stats_tab.pressed.connect(select_tab.bind(TAB_STATS))
	_quests_tab.pressed.connect(select_tab.bind(TAB_QUESTS))
	_levelup.visible = false

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_data_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.quests_changed.connect(_on_data_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_character"):
		get_viewport().set_input_as_handled()
		toggle()
		return
	if not visible:
		return
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	# Modal behaviour (docs/80-* §6 "modals consume all input"): while open the
	# panel swallows the remaining events so the host screen's keyboard
	# handling (movement, hotkeys) cannot act underneath it. Input reached
	# through `_input` rather than `_unhandled_input` is the host's contract to
	# guard; the panel documents this at [method attach_to].
	get_viewport().set_input_as_handled()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	if GameState.player.is_empty():
		# No run in progress (e.g. dropped into the title screen): nothing to
		# show, and opening an empty panel would be worse than a no-op.
		return
	visible = true
	_refresh()
	_close_button.grab_focus()


func close() -> void:
	visible = false
	_levelup.visible = false


func is_open() -> bool:
	return visible


## Opens the S18 officers detail panel (docs/80-* §4.6.2: "opened from S4's
## facility list and from the character panel"). The panel is parent-agnostic and
## attaches itself to whichever host is showing; S14 closes so the two modals
## never stack.
func open_officers_panel() -> Control:
	var host := get_parent()
	var panel := OfficersPanelLib.attach_to(host if host != null else self)
	if panel != null and panel.has_method("open"):
		close()
		panel.open_on(host)
	return panel


func active_tab() -> String:
	return _tab


## Switches between the stats column and the Phase-3 quest list (docs/80-*
## §4.7.3). Unknown ids are ignored; the choice is not persisted.
func select_tab(tab: String) -> void:
	if tab != TAB_STATS and tab != TAB_QUESTS:
		return
	_tab = tab
	if visible:
		_refresh()
	else:
		_bind_tabs()


# --- Rendering -------------------------------------------------------------

func _refresh() -> void:
	_bind_tabs()
	_columns.visible = _tab == TAB_STATS
	_quests_panel.visible = _tab == TAB_QUESTS
	var player: Dictionary = GameState.player
	var nation_id := str(player.get("nation_id", ""))
	var nation: Dictionary = DataLoader.get_nation(nation_id)

	_title.text = I18n.t_key("char.title")
	_nation.text = "%s · %s" % [
		I18n.t(nation.get("name", {})),
		I18n.fmt("char.day", {"day": GameState.day}),
	]

	var level := CharacterLib.current_level()
	var xp := CharacterLib.current_xp()
	_level.text = I18n.fmt("char.level", {"level": level})
	_xp.text = I18n.fmt("char.xp", {"xp": xp})
	var remaining := CharacterLib.xp_to_next_level()
	_next.visible = remaining >= 0
	if remaining >= 0:
		_next.text = I18n.fmt("char.next_level", {"xp": remaining})

	_stats_header.text = I18n.t_key("char.stats")
	_build_stats()
	_build_officers()
	_build_reputation(nation_id)
	_build_quests()

	_wage.text = I18n.fmt("char.officer_wage", {"gold": CharacterLib.officer_wages()})
	_close_button.text = I18n.t_key("ui.close")
	_officers_button.text = I18n.t_key("officers.title")
	_hint.text = I18n.t_key("ui.esc_hint")
	_levelup.visible = CharacterLib.pending_levelup
	if _levelup.visible:
		_levelup.text = I18n.fmt("char.level_up", {"level": level})
		# Read-only on purpose: the toast owner (HUD, T6) consumes the flag via
		# CharacterLib.consume_pending_levelup(), so showing the banner here
		# must not swallow the HUD toast.


func _bind_tabs() -> void:
	_stats_tab.text = I18n.t_key("char.stats")
	_quests_tab.text = I18n.t_key("char.quests")
	for pair in [[TAB_STATS, _stats_tab], [TAB_QUESTS, _quests_tab]]:
		var active: bool = _tab == str(pair[0])
		var button: Button = pair[1]
		button.button_pressed = active
		button.add_theme_color_override(
			"font_color", PaletteLib.ACCENT if active else PaletteLib.TEXT
		)


## Stats table: one row per §4.2 stat with base and effective values.
func _build_stats() -> void:
	_clear(_stats_rows)
	for stat_key in STAT_KEYS:
		var row := HBoxContainer.new()
		row.name = "Stat_%s" % stat_key
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var name_label := _make_label(I18n.t_key("char.%s" % stat_key))
		name_label.custom_minimum_size.x = 160
		name_label.name = "Name"
		# Base cell reads "10 →" so the unlabelled number is unambiguous next to
		# the localised "Effective N" cell (no `char.base` key exists; adding
		# one is listed in the T16 report for the orchestrator).
		var base_label := _make_label("%d →" % CharacterLib.base_stat(stat_key))
		base_label.name = "Base"
		base_label.custom_minimum_size.x = 64
		base_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		base_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		var effective := CharacterLib.effective_stat(stat_key)
		var effective_label := _make_label(
			I18n.fmt("char.effective", {"amount": effective})
		)
		effective_label.name = "Effective"
		effective_label.custom_minimum_size.x = 200
		effective_label.add_theme_color_override(
			"font_color",
			PaletteLib.ACCENT if effective > CharacterLib.base_stat(stat_key)
			else PaletteLib.TEXT
		)
		row.add_child(name_label)
		row.add_child(base_label)
		row.add_child(effective_label)
		_stats_rows.add_child(row)


## Officer roster: name, role and daily wage per §4.4/§4.5.
func _build_officers() -> void:
	_officers_header.text = I18n.t_key("char.officers")
	_clear(_officers_rows)
	var officers: Array = CharacterLib.employed_officers()
	if officers.is_empty():
		_officers_rows.add_child(_make_label(I18n.t_key("char.no_officers")))
		return
	for officer_id in officers:
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		if officer.is_empty():
			continue
		var row := HBoxContainer.new()
		row.name = "Officer_%s" % str(officer_id)
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var name_label := _make_label(I18n.t(officer.get("name", {})))
		name_label.custom_minimum_size.x = 200
		var role_key := str(ROLE_KEYS.get(str(officer.get("role", "")), "char.none"))
		var role_label := _make_label(I18n.t_key(role_key))
		role_label.custom_minimum_size.x = 110
		role_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		var wage_label := _make_label(I18n.fmt(
			"tavern.wage", {"price": int(officer.get("wage_daily", 0))}
		))
		wage_label.custom_minimum_size.x = 120
		row.add_child(name_label)
		row.add_child(role_label)
		row.add_child(wage_label)
		_officers_rows.add_child(row)


## Reputation table: all six nations, own row highlighted (docs/50-* §4.6,
## §6 "no Nation rows hidden").
func _build_reputation(nation_id: String) -> void:
	_reputation_header.text = I18n.t_key("char.reputation")
	_reputation_rows.columns = 2
	_clear(_reputation_rows)
	for nation in DataLoader.nations_list:
		var other_id := str(nation.get("id", ""))
		var value := CharacterLib.reputation(other_id)
		var name_label := _make_label(I18n.t(nation.get("name", {})))
		name_label.name = "Rep_%s" % other_id
		if other_id == nation_id:
			name_label.add_theme_color_override("font_color", PaletteLib.ACCENT)
		var value_label := _make_label(format_signed(value))
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.custom_minimum_size.x = 96
		value_label.add_theme_color_override(
			"font_color",
			PaletteLib.GOOD if value > 0
			else (PaletteLib.BAD if value < 0 else PaletteLib.TEXT)
		)
		_reputation_rows.add_child(name_label)
		_reputation_rows.add_child(value_label)


## The Phase-3 `Quests` tab (docs/80-* §4.7.3): slot counter plus one row per
## active quest — type tag, objective, destination and days left, with
## `quest.abandon` on each row (the same −5 rep failure path as expiry).
func _build_quests() -> void:
	_clear(_quest_rows)
	var quests: Array = QuestGenLib.active_quests()
	_quest_slots.text = I18n.fmt("quest.slots", {
		"used": QuestGenLib.active_count(),
		"max": QuestGenLib.max_active_quests(),
	})
	_quest_empty.visible = quests.is_empty()
	_quest_empty.text = I18n.t_key("ui.empty")
	for quest in quests:
		_quest_rows.add_child(_build_quest_row(quest))


func _build_quest_row(quest: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.name = "Quest_%s" % str(quest.get("instance_id", ""))
	row.add_theme_constant_override("separation", 4)

	var top := HBoxContainer.new()
	top.name = "Top"
	top.add_theme_constant_override("separation", PaletteLib.MARGIN)
	var tag := _make_label(I18n.t_key(QuestGenLib.type_key(quest)))
	tag.name = "Tag"
	tag.custom_minimum_size.x = 120
	tag.add_theme_color_override("font_color", PaletteLib.ACCENT)
	top.add_child(tag)
	var objective := _make_label(QuestGenLib.objective_text(quest))
	objective.name = "Objective"
	objective.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(objective)
	var days := _make_label(I18n.fmt("quest.days_left", {
		"days": maxi(0, int(quest.get("deadline_day", 0)) - int(GameState.day)),
	}))
	days.name = "Days"
	days.custom_minimum_size.x = 140
	days.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	top.add_child(days)
	row.add_child(top)

	var bottom := HBoxContainer.new()
	bottom.name = "Bottom"
	bottom.add_theme_constant_override("separation", PaletteLib.MARGIN)
	# `quest.dest` always names the port, even when the player has never been
	# there (docs/80-* §4.7.3).
	var destination := _make_label(I18n.fmt("quest.dest", {
		"port": _destination_name(quest),
	}))
	destination.name = "Destination"
	destination.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	destination.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	bottom.add_child(destination)
	var abandon := Button.new()
	abandon.name = "Abandon"
	abandon.text = I18n.t_key("quest.abandon")
	abandon.custom_minimum_size = Vector2(180, PaletteLib.BUTTON_H)
	abandon.pressed.connect(func() -> void: abandon_quest(quest))
	bottom.add_child(abandon)
	row.add_child(bottom)
	return row


## The port a quest names: its delivery destination, else its origin.
static func _destination_name(quest: Dictionary) -> String:
	var requirements: Dictionary = quest.get("requirements", {})
	var port_id := str(requirements.get("dest_port_id", ""))
	if port_id.is_empty():
		port_id = str(quest.get("origin_port_id", ""))
	return I18n.t(DataLoader.get_port(port_id).get("name", {}))


## Abandons `quest` from the panel: the §4.2 failure path (−5 rep with the
## origin port's nation), then the list rebuilds. Returns whether it failed.
func abandon_quest(quest: Dictionary) -> bool:
	var ok := QuestGenLib.abandon(quest)
	if ok:
		EventBus.quests_changed.emit()
	if visible:
		_refresh()
	return ok


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	return label


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


## `+20` / `0` / `-5`: the sign is composed by the UI, not baked into an
## L10nString (docs/10-* §3.3 rule 5).
static func format_signed(value: int) -> String:
	if value > 0:
		return "+%d" % value
	return str(value)


func _on_locale_changed(_locale: String) -> void:
	# Rebuild while open so a locale toggle mid-panel is instant
	# (docs/80-* §6).
	if visible:
		_refresh()


func _on_data_changed() -> void:
	if visible:
		_refresh()


func _on_gold_changed(_new_gold: int) -> void:
	if visible:
		_refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_data_changed):
		EventBus.fleet_changed.disconnect(_on_data_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.quests_changed.is_connected(_on_data_changed):
		EventBus.quests_changed.disconnect(_on_data_changed)
