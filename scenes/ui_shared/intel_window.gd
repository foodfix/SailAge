class_name IntelWindow
extends Control
## The 情报 window — docs/80-UI-UX.md §4.5 (the 2026-11-03 amendment turned the
## HUD button's dropdown into this ONE dedicated modal, hosting the five
## information surfaces as tabs).
##
## Tabs (§4.5, in order): 船长 (`captain_view` — the retired S14 single page) ·
## 官员 (`officer_roster_view` — the retired S18 table + detail) · 船队
## (`fleet_view` — the retired S15 body) · 海图 (a launcher — the chart stays
## the fullscreen S17, `80-*` §4.6) · 委托 (the active-quest list, migrated
## from the retired S14 tab).
##
## Parent-agnostic modal, the [CharacterPanel] convention: a `Control` host
## gets it as a child; a `Node2D` host (the world map) gets it inside a
## `CanvasLayer`. While open it joins the `modal_overlay` group and consumes
## input (§6 "modals consume all input").
##
## Keys (§4.3): `C` opens the window on the 船长 tab, `O` on 官员, `F` on
## 船队 — pressed again on the same tab the window closes; a different key
## switches tabs in place. `Esc` closes. Opening is refused while another
## modal owns the screen; closing/switching always works (the window is the
## modal then). The `Tab` chart key stays with S17 and never fires while this
## window is up (the window swallows input, §6).

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const CardLib := preload("res://scenes/ui/character_card.gd")
## The S17 chart (the 海图 tab's launcher opens it fullscreen).
const ChartScreenLib := preload("res://scenes/world/chart_screen.gd")

const SCENE_PATH := "res://scenes/ui_shared/intel_window.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## Tab ids (docs/80-* §4.5; `char.quests` keeps its id from the retired S14).
const TAB_CAPTAIN := "captain"
const TAB_REPUTATION := "reputation"
const TAB_OFFICERS := "officers"
const TAB_FLEET := "fleet"
const TAB_CHART := "chart"
const TAB_QUESTS := "quests"

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/TitleRow/Title
@onready var _close_button: Button = $Center/Panel/Margin/Body/TitleRow/Close
@onready var _captain_tab: Button = $Center/Panel/Margin/Body/Tabs/CaptainTab
@onready var _reputation_tab: Button = $Center/Panel/Margin/Body/Tabs/ReputationTab
@onready var _officers_tab: Button = $Center/Panel/Margin/Body/Tabs/OfficersTab
@onready var _fleet_tab: Button = $Center/Panel/Margin/Body/Tabs/FleetTab
@onready var _chart_tab: Button = $Center/Panel/Margin/Body/Tabs/ChartTab
@onready var _quests_tab: Button = $Center/Panel/Margin/Body/Tabs/QuestsTab
@onready var _captain_view: Control = \
	$Center/Panel/Margin/Body/Content/CaptainView
@onready var _reputation_view: Control = \
	$Center/Panel/Margin/Body/Content/ReputationView
@onready var _officers_view: Control = \
	$Center/Panel/Margin/Body/Content/OfficerRosterView
@onready var _fleet_view: Control = $Center/Panel/Margin/Body/Content/FleetView
@onready var _quests_box: VBoxContainer = \
	$Center/Panel/Margin/Body/Content/QuestsBox
@onready var _quest_slots: Label = \
	$Center/Panel/Margin/Body/Content/QuestsBox/QuestSlots
@onready var _quest_rows: VBoxContainer = \
	$Center/Panel/Margin/Body/Content/QuestsBox/QuestScroll/QuestRows
@onready var _quest_empty: Label = \
	$Center/Panel/Margin/Body/Content/QuestsBox/QuestEmpty
@onready var _hint: Label = $Center/Panel/Margin/Body/Hint

## The active tab. The window remembers the last one (session-only) so the
## HUD button reopens where the player left off (§4.5 backlog item).
var _tab: String = TAB_CAPTAIN

## Installs the window under `parent` (idempotent) and returns it. A `Control`
## host gets it as a child; a `Node2D` host gets it inside an `IntelWindowLayer`
## CanvasLayer (the modal-convention wrapper).
static func attach_to(parent: Node) -> Control:
	var existing := _find_window(parent)
	if existing != null:
		return existing
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("IntelWindow.attach_to: missing %s" % SCENE_PATH)
		return null
	var window := scene.instantiate()
	window.name = "IntelWindow"
	if parent is Control:
		parent.add_child(window)
	else:
		var layer := parent.get_node_or_null("IntelWindowLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "IntelWindowLayer"
			# Above the host screen's own canvas so the modal dims everything.
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(window)
	return window


## Finds an already-attached window under `parent`, whether it sits directly
## there (Control host) or inside the CanvasLayer wrapper (Node2D host).
static func _find_window(parent: Node) -> Control:
	var direct := parent.get_node_or_null("IntelWindow")
	if direct is Control:
		return direct
	var layer := parent.get_node_or_null("IntelWindowLayer")
	if layer != null:
		var nested := layer.get_node_or_null("IntelWindow")
		if nested is Control:
			return nested
	return null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 sweep (W4-B): panel + tab chrome come from the theme; secondary
	# text uses the `Dim` variation. The active tab keeps its ACCENT mark via
	# `modulate` (see [_bind_tabs]).
	_quest_empty.theme_type_variation = "Dim"
	_hint.theme_type_variation = "Dim"
	_close_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_close_button.pressed.connect(close)
	_captain_tab.pressed.connect(select_tab.bind(TAB_CAPTAIN))
	_reputation_tab.pressed.connect(select_tab.bind(TAB_REPUTATION))
	_officers_tab.pressed.connect(select_tab.bind(TAB_OFFICERS))
	_fleet_tab.pressed.connect(select_tab.bind(TAB_FLEET))
	# 海图 is an ACTION tab (amended 2026-11-03): pressing it closes this
	# window and enters the fullscreen chart directly — it is not a page.
	_chart_tab.pressed.connect(_on_chart_tab_pressed)
	_quests_tab.pressed.connect(select_tab.bind(TAB_QUESTS))

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_data_changed)
	EventBus.gold_changed.connect(_on_data_changed)
	EventBus.quests_changed.connect(_on_data_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		# The §6 keys: C / O / F open the window on their tab — but never
		# while another modal owns the screen (the window is not in the group
		# while closed, so the walk sees exactly the others).
		var tab := _key_tab(event)
		if tab.is_empty() or _other_modal_open() or GameState.player.is_empty():
			return
		get_viewport().set_input_as_handled()
		open_tab(tab)
		return
	# While open the window owns the keys (§6): C/O/F switch tabs (the active
	# one closes), Esc closes, everything else is swallowed.
	var tab := _key_tab(event)
	if not tab.is_empty():
		get_viewport().set_input_as_handled()
		if tab == _tab:
			close()
		else:
			select_tab(tab)
		return
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	get_viewport().set_input_as_handled()


## The tab id the pressed key maps to (`""` = not an intel key):
## `toggle_character` → 船长, `toggle_officers` → 官员, `toggle_fleet` → 船队.
## A nested confirm/appoint dialog keeps the keys (its own Esc closes it).
func _key_tab(event: InputEvent) -> String:
	if _fleet_view != null and _fleet_view.has_method("has_dialog") \
			and _fleet_view.call("has_dialog"):
		return ""
	if _officers_view != null and _officers_view.has_method("has_dialog") \
			and _officers_view.call("has_dialog"):
		return ""
	if event.is_action_pressed("toggle_character"):
		return TAB_CAPTAIN
	if event.is_action_pressed("toggle_officers"):
		return TAB_OFFICERS
	if event.is_action_pressed("toggle_fleet"):
		return TAB_FLEET
	return ""


## True while any *other* modal is up (a HUD dialog, a confirm, the chart…).
func _other_modal_open() -> bool:
	for node in get_tree().get_nodes_in_group(MODAL_GROUP):
		if node == self or not (node is CanvasItem):
			continue
		if (node as CanvasItem).is_visible_in_tree():
			return true
	return false


# --- Public API ------------------------------------------------------------

func toggle() -> void:
	if visible:
		close()
	else:
		open_tab(_tab)


func open() -> void:
	open_tab(_tab)


## Opens the window on `tab` (the §4.5 order's five ids; anything else reopens
## the remembered tab).
func open_tab(tab: String) -> void:
	if GameState.player.is_empty():
		# No run in progress (title/editor): an empty window is worse than a
		# no-op, exactly like the retired panels' open() guard.
		return
	if tab in [TAB_CAPTAIN, TAB_REPUTATION, TAB_OFFICERS, TAB_FLEET,
			TAB_CHART, TAB_QUESTS]:
		_tab = tab
	visible = true
	add_to_group(MODAL_GROUP)
	# 海图 in the whitelist is on purpose: `select_tab` treats it as the action
	# (it closes the window and enters S17), so `open_tab(TAB_CHART)` must not
	# first remember it as a page.
	if _tab == TAB_CHART:
		_tab = TAB_CAPTAIN
	select_tab(_tab)
	_close_button.grab_focus()


func close() -> void:
	visible = false
	remove_from_group(MODAL_GROUP)
	# A pending jettison confirm dies with the view: never leave a modal
	# hovering over a hidden owner (§6).
	if _fleet_view != null and _fleet_view.has_method("has_dialog") \
			and _fleet_view.call("has_dialog"):
		_fleet_view.call("cancel_dialog")


func is_open() -> bool:
	return visible


func has_modal() -> bool:
	return visible or _other_dialog_open()


## True while a nested view dialog (jettison confirm / appoint dialog) is up.
func _other_dialog_open() -> bool:
	if _fleet_view != null and _fleet_view.has_method("has_dialog") \
			and _fleet_view.call("has_dialog"):
		return true
	if _officers_view != null and _officers_view.has_method("has_dialog") \
			and _officers_view.call("has_dialog"):
		return true
	return false


func active_tab() -> String:
	return _tab


## Switches tabs (§4.5). Unknown ids are ignored; the choice is session-only.
## 海图 is not a page (amended 2026-11-03): it is an ACTION that closes this
## window and enters the fullscreen chart, so it never becomes the active tab.
func select_tab(tab: String) -> void:
	if tab == TAB_CHART:
		_on_chart_tab_pressed()
		return
	if tab not in [TAB_CAPTAIN, TAB_REPUTATION, TAB_OFFICERS, TAB_FLEET,
			TAB_QUESTS]:
		return
	_tab = tab
	_captain_view.visible = tab == TAB_CAPTAIN
	_reputation_view.visible = tab == TAB_REPUTATION
	_officers_view.visible = tab == TAB_OFFICERS
	_fleet_view.visible = tab == TAB_FLEET
	_quests_box.visible = tab == TAB_QUESTS
	_bind_tabs()
	if visible:
		_refresh()


# --- Rendering -------------------------------------------------------------

func _refresh() -> void:
	_title.text = I18n.t_key("ui.intel")
	_hint.text = I18n.t_key("intel.hint")
	_close_button.text = I18n.t_key("ui.close")
	match _tab:
		TAB_CAPTAIN:
			if _captain_view.has_method("refresh"):
				_captain_view.call("refresh")
		TAB_REPUTATION:
			if _reputation_view.has_method("refresh"):
				_reputation_view.call("refresh")
		TAB_OFFICERS:
			if _officers_view.has_method("rebuild"):
				_officers_view.call("rebuild")
		TAB_FLEET:
			if _fleet_view.has_method("rebuild"):
				_fleet_view.call("rebuild")
		TAB_QUESTS:
			_build_quests()


func _bind_tabs() -> void:
	for pair in [
		[TAB_CAPTAIN, _captain_tab, "char.title"],
		[TAB_REPUTATION, _reputation_tab, "char.reputation"],
		[TAB_OFFICERS, _officers_tab, "officers.title"],
		[TAB_FLEET, _fleet_tab, "fleet.title"],
		[TAB_CHART, _chart_tab, "chart.title"],
		[TAB_QUESTS, _quests_tab, "char.quests"],
	]:
		var button: Button = pair[1]
		button.text = I18n.t_key(str(pair[2]))
		# 海图 is an action, never "active" (§4.5 amended).
		var active: bool = _tab == str(pair[0]) and str(pair[0]) != TAB_CHART
		button.button_pressed = active
		# The active-tab ACCENT mark rides `modulate` (§4.9 sweep): WHITE
		# leaves the theme's Button ink untouched.
		button.modulate = PaletteLib.ACCENT if active else Color.WHITE


## The 海图 entry: closes this window (the chart is a fullscreen modal of its
## own, §4.6 — never stacked) and enters S17. Amended 2026-11-03: the tab is a
## direct entry, not a launcher page.
func _on_chart_tab_pressed() -> void:
	var chart := _find_chart()
	if chart == null or not chart.has_method("toggle_chart"):
		return
	close()
	chart.call("toggle_chart")


## The shared S17 instance. The production hosts instance it as a direct child
## of the world HUD layer or the port root, so the recursive-by-name lookup
## finds the one instance; the `attach_to` fallback only serves a host that
## builds its UI in code (§4.6 hosting seam).
func _find_chart() -> Control:
	var tree := get_tree()
	var root: Node = null
	if tree != null and tree.current_scene != null:
		root = tree.current_scene
	elif get_parent() != null:
		root = get_parent()
	if root != null:
		var chart := root.find_child("ChartScreen", true, false)
		if chart is Control:
			return chart
	return ChartScreenLib.attach_to(root if root != null else self)


# --- The 委托 tab (migrated from the retired S14 quests tab, §4.7.3) --------

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

	var top := HBoxContainer.new()
	top.name = "Top"
	var tag := _make_label(I18n.t_key(QuestGenLib.type_key(quest)))
	tag.name = "Tag"
	tag.custom_minimum_size.x = 120
	tag.modulate = PaletteLib.ACCENT
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
	days.theme_type_variation = "Dim"
	top.add_child(days)
	row.add_child(top)

	var bottom := HBoxContainer.new()
	bottom.name = "Bottom"
	# `quest.dest` always names the port, even when the player has never been
	# there (docs/80-* §4.7.3).
	var destination := _make_label(I18n.fmt("quest.dest", {
		"port": _destination_name(quest),
	}))
	destination.name = "Destination"
	destination.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	destination.theme_type_variation = "Dim"
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


## Abandons `quest`: the §4.2 failure path (−5 rep with the origin port's
## nation), then the list rebuilds. Returns whether it failed.
func abandon_quest(quest: Dictionary) -> bool:
	var ok := QuestGenLib.abandon(quest)
	if ok:
		EventBus.quests_changed.emit()
	if visible:
		_refresh()
	return ok


# --- Helpers ---------------------------------------------------------------

func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	# Ink is the theme's TEXT (§4.9 sweep); callers add `Dim`/`modulate` for
	# secondary/state text.
	return label


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _on_locale_changed(_locale: String) -> void:
	# The static labels re-bind even while closed (cheap — the next open would
	# otherwise show one stale locale frame); the active tab's content
	# rebuilds through the views' own locale handlers.
	_title.text = I18n.t_key("ui.intel")
	_hint.text = I18n.t_key("intel.hint")
	_close_button.text = I18n.t_key("ui.close")
	_bind_tabs()
	# Rebuild the content while open so a locale toggle mid-window is instant
	# (§6).
	if visible:
		_refresh()


func _on_data_changed(_value: int = 0) -> void:
	if visible:
		_refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_data_changed):
		EventBus.fleet_changed.disconnect(_on_data_changed)
	if EventBus.gold_changed.is_connected(_on_data_changed):
		EventBus.gold_changed.disconnect(_on_data_changed)
	if EventBus.quests_changed.is_connected(_on_data_changed):
		EventBus.quests_changed.disconnect(_on_data_changed)
