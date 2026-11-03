extends Node
## Intel-window acceptance tests (docs/80-UI-UX.md §4.5, §4.2/§4.12/§4.6.2
## amendments 2026-11-03). Headless scene test:
##
##   godot --headless res://tools/test_intel_window.tscn
##
## Exits 0 when every check passes, 1 otherwise. The §4.5 intel button opens
## the ONE dedicated modal hosting the five surfaces — 船长 (the retired S14
## single page: card + reputation + gates) · 官员 (the retired S18, now a
## table + detail) · 船队 (the retired S15 body) · 海图 (a direct entry into
## the fullscreen S17) · 委托 (the quest list migrated from S14), plus the
## 声望 tab (the six-nation table split out of the captain page). Covers: the
## button wiring, the five-tab order and localized labels (§4.4), tab
## switching + the remembered tab, the C/O/F key mapping (same tab closes,
## another key switches, §6 refusal under another modal, Esc closes), the
## 委托 migration (abandon path lands here, never a raw "<key>"), the officers
## table columns + detail actions, the fleet view read-only rows, and the
## gate rows carrying localized names (§4.20). The chart entry shares ONE
## open/close with this suite (every `open_chart` rebuilds the whole
## 4320×2160 terrain image — the test_chart discipline).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const IntelWindowLib := preload("res://scenes/ui_shared/intel_window.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const ChartScreenLib := preload("res://scenes/world/chart_screen.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")
const IntelScene := preload("res://scenes/ui_shared/intel_window.tscn")

var _failures: Array[String] = []
var _checks := 0

## One HUD + one window shared by every section (the window is stateless).
var _hud = null
var _window: Control = null
## The Control wrapper the HUD lives in (1280×720, the §4.5 canvas).
var _host: Control = null
## Locale is a global: saved here and restored in `_report`.
var _locale_before: String = "en"


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the chart fixture (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	GameState.new_game("portugal", false)
	_check(not GameState.player.is_empty(), "fixture run has a player")
	# The suite drives the window at sea (the fleet tab's read-only pin); the
	# fresh run is docked at the start port until this clears it.
	GameState.current_port = null
	_locale_before = I18n.get_locale()

	_host = Control.new()
	_host.name = "IntelHost"
	_host.size = Vector2(1280, 720)
	add_child(_host)
	_hud = HUDScene.instantiate()
	_host.add_child(_hud)
	# The window attaches where the HUD's `_panel_host()` resolves — the
	# scene root (the modal convention; `attach_to` is idempotent).
	_window = IntelWindowLib.attach_to(self)

	var _sections: Array = [
		["_test_button_presence"], ["_test_tabs_and_labels"],
		["_test_captain_tab"], ["_test_reputation_tab"], ["_test_quests_tab"],
		["_test_fleet_tab"], ["_test_officers_table"],
		["_test_officers_detail"], ["_test_chart_tab"],
		["_test_key_mapping"], ["_test_blocked_under_modal"],
		["_test_locale_rebind"],
	]
	for section in _sections:
		call(section[0])
	_report()


# --- Sections --------------------------------------------------------------

## §4.5: the 情报 Button rides the top bar's right end on the shared HUD —
## visible at sea (S3) and equally present in port mode (S4) — and opens the
## dedicated window (no dropdown, no MenuButton popup).
func _test_button_presence() -> void:
	var button: Button = _hud.intel_button()
	_check(button != null and button is Button and not button is MenuButton,
		"the intel button is a plain Button (no dropdown popup)")
	_check(button.get_parent() == _hud.get_node("TopRow"),
		"the intel button lives in the HUD top bar")
	_check(button.get_index() == button.get_parent().get_child_count() - 1,
		"the intel button is the top bar's last (rightmost) entry")
	_check(button.visible and button.text == I18n.t_key("ui.intel"),
		"the button reads ui.intel in the current locale (%s)" % button.text)
	# S4 (port hub): the sea viewport is replaced, the top bar is not.
	_hud.set_minimap_visible(false)
	_check(button.visible and button.get_parent().visible,
		"the intel button stays visible in port mode (S4)")
	_hud.set_minimap_visible(true)
	# The button opens the window through the host resolution.
	button.pressed.emit()
	_check(_window.is_open(), "pressing the intel button opens the window")
	_window.close()
	_check(not _window.is_open(), "the window closes again")


## §4.5: the five tabs in order, each rendered from its own ui_strings key
## (char.title / officers.title / fleet.title / chart.title / char.quests —
## no new per-tab strings), one content area visible at a time.
func _test_tabs_and_labels() -> void:
	_window.open_tab(IntelWindowLib.TAB_CAPTAIN)
	var order: Array = [
		["char.title", _window.get_node("Center/Panel/Margin/Body/Tabs/CaptainTab")],
		["char.reputation", _window.get_node("Center/Panel/Margin/Body/Tabs/ReputationTab")],
		["officers.title", _window.get_node("Center/Panel/Margin/Body/Tabs/OfficersTab")],
		["fleet.title", _window.get_node("Center/Panel/Margin/Body/Tabs/FleetTab")],
		["chart.title", _window.get_node("Center/Panel/Margin/Body/Tabs/ChartTab")],
		["char.quests", _window.get_node("Center/Panel/Margin/Body/Tabs/QuestsTab")],
	]
	var mismatch := ""
	for pair in order:
		var button: Button = pair[1]
		if button.text != I18n.t_key(str(pair[0])):
			mismatch = "%s:%s" % [str(pair[0]), button.text]
			break
	_check(mismatch.is_empty(),
		"the five tabs carry their ui_strings labels in order (%s)" % mismatch)
	_check(_window.get_node("Center/Panel/Margin/Body/TitleRow/Title").text
		== I18n.t_key("ui.intel"),
		"the window title reads ui.intel")
	# One content area visible at a time.
	_window.select_tab(IntelWindowLib.TAB_OFFICERS)
	var content := _window.get_node("Center/Panel/Margin/Body/Content")
	var visible_count := 0
	for child in content.get_children():
		if child is Control and child.visible:
			visible_count += 1
	_check(visible_count == 1,
		"exactly one tab content is visible (%d)" % visible_count)
	_window.close()


## The 船长 tab: the merged single page — the player card (ONE instance, the
## §4.12 draft survives), the reputation table and the localized gate rows.
func _test_captain_tab() -> void:
	_window.open_tab(IntelWindowLib.TAB_CAPTAIN)
	var view: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/CaptainView")
	_check(view.visible, "the 船长 tab shows the captain view")
	var card: Control = view.player_card()
	_check(card != null and card.visible,
		"the captain view renders the §4.12 player card")
	# The §4.12.2 draft: stage a point, refresh, the draft survives.
	var draft_before: Dictionary = card.alloc_draft()
	view.refresh()
	_check(card.alloc_draft() == draft_before,
		"an in-progress allocation draft survives the view refresh")
	var gates: Container = view.get_node("Body/Page/Sections/GateRows")
	_check(gates.get_child_count() == DataLoader.skill_gates_list.size(),
		"the gates table renders every skill_gates row (%d)"
		% gates.get_child_count())
	var first_gate: Control = gates.get_child(0)
	_check((first_gate.get_node("Top/Feature") as Label).text
		== I18n.t(DataLoader.skill_gates_list[0]["name"]),
		"the gate row shows the localized name (§4.20)")
	_check((first_gate.get_node("Reason") as Label).text
		== I18n.t(DataLoader.skill_gates_list[0]["reason"]),
		"the gate row shows its reason line")
	_window.close()


## The 声望 tab (amended 2026-11-03): the six-nation table split out of the
## 船长 page into its own tab, so the captain page holds only the card + gates.
func _test_reputation_tab() -> void:
	_window.open_tab(IntelWindowLib.TAB_REPUTATION)
	var view: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/ReputationView")
	_check(view.visible, "the 声望 tab shows the reputation view")
	_check(view.row_count() == DataLoader.nations_list.size() * 2,
		"the reputation table renders all six nations (%d cells)"
		% view.row_count())
	# Every nation appears — none hidden (docs/50-* §6).
	var found := 0
	for nation in DataLoader.nations_list:
		if view.get_node_or_null(
				"Body/Page/Sections/Rows/Rep_%s" % str(nation.get("id", ""))) != null:
			found += 1
	_check(found == DataLoader.nations_list.size(),
		"no nation row is hidden (%d/%d)" % [found, DataLoader.nations_list.size()])
	# The captain page no longer carries the table (the split is real).
	var captain: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/CaptainView")
	_check(captain.get_node_or_null("Body/Page/Sections/ReputationRows") == null,
		"the 船长 page no longer duplicates the reputation table")
	_window.close()


## The 委托 tab: the quest list migrated from the retired S14 tab — slots
## counter, one row per active quest with the abandon path.
func _test_quests_tab() -> void:
	_window.open_tab(IntelWindowLib.TAB_QUESTS)
	var box: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/QuestsBox")
	_check(box.visible, "the 委托 tab shows the quest list")
	var slots: Label = box.get_node("QuestSlots")
	_check(slots.text == I18n.fmt("quest.slots", {
		"used": QuestGenLib.active_count(),
		"max": QuestGenLib.max_active_quests(),
	}), "the slots counter reads quest.slots (%s)" % slots.text)
	var rows: Container = box.get_node("QuestScroll/QuestRows")
	_check(rows.get_child_count() == QuestGenLib.active_quests().size(),
		"one row per active quest (%d)" % rows.get_child_count())
	# The abandon path: a fresh run has no quest to abandon without accepting
	# one; the view's funnel still exists and is wired to quest_gen.
	_check(_window.has_method("abandon_quest"),
		"the window carries the abandon funnel (the S14 path)")
	_window.close()


## The 船队 tab: the retired S15 body — summary, ships header, one row per
## hull, totals; at sea the read-only banner shows (the fixture run is at sea).
func _test_fleet_tab() -> void:
	_window.open_tab(IntelWindowLib.TAB_FLEET)
	var view: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/FleetView")
	_check(view.visible, "the 船队 tab shows the fleet view")
	_check(view.is_read_only(),
		"the fixture run (at sea) renders the view read-only")
	var rows: Container = view.get_node("Body/Scroll/Rows")
	_check(rows.get_child_count() == GameState.fleet.size(),
		"one ship row per hull (%d)" % rows.get_child_count())
	var totals: Container = view.get_node("Body/Totals")
	_check(totals.get_child_count() >= 2,
		"the totals block renders (title row + supplies row)")
	_check(view.row_widget(0).get("promote", null) == null,
		"the flagship row carries no promote button (§4.4)")
	_window.close()


## The 官员 table: the fixed columns + the stat block, toggled 属性/技能;
## the empty state for a run with no officers.
func _test_officers_table() -> void:
	_window.open_tab(IntelWindowLib.TAB_OFFICERS)
	var view: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/OfficerRosterView")
	_check(view.visible, "the 官员 tab shows the roster view")
	_check(view.stat_mode() == "attributes",
		"the table starts on the attribute columns")
	# Toggle to the skills columns: 8 player skills + 3 officer-only.
	view.set_stat_mode("skills")
	_check(view.stat_mode() == "skills", "the 技能 toggle switches the columns")
	var header: Control = view.get_node("Body/TableScroll/Table/Header")
	var stat_headers := 0
	for child in header.get_children():
		if str(child.name).begins_with("Stat_"):
			stat_headers += 1
	_check(stat_headers == SkillsLib.KEYS.size() + SkillsLib.OFFICER_KEYS.size(),
		"the skills table carries the 8+3 columns (%d)" % stat_headers)
	view.set_stat_mode("attributes")
	header = view.get_node("Body/TableScroll/Table/Header")
	var attr_headers := 0
	for child in header.get_children():
		if str(child.name).begins_with("Stat_"):
			attr_headers += 1
	_check(attr_headers == 5, "the attributes table carries the 5 columns")
	# The fresh run employs nobody: the empty state shows (§4.6.2).
	_check(view.officer_ids().is_empty(),
		"a fresh run lists no officers")
	_check(view.get_node("Body/TableEmpty").visible,
		"the empty state shows for a run with no officers")
	_window.close()


## The detail page: a row click opens it; the full card renders and the five
## actions exist (§4.6.2). A hired officer is staged through the roster data.
func _test_officers_detail() -> void:
	# Stage one employed officer with a pilot post (the data file's id).
	var roster_ids: Array = []
	for officer in DataLoader.officers_list:
		roster_ids.append(str(officer.get("id", "")))
	var hire_id := ""
	for id in roster_ids:
		if CharacterLib.recruit(id):
			hire_id = id
			break
	_check(not hire_id.is_empty(), "fixture: one officer recruited (%s)" % hire_id)
	SkillsLib.appoint(hire_id, "pilot", "")

	_window.open_tab(IntelWindowLib.TAB_OFFICERS)
	var view: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/OfficerRosterView")
	_check(view.officer_ids() == [hire_id],
		"the table lists the employed officer (%s)" % str(view.officer_ids()))
	# Click the row (the row Control's gui_input activation) → the detail page.
	var row: Control = view.get_node("Body/TableScroll/Table/Officer_%s" % hire_id)
	row.call("_on_row_pressed", hire_id)
	_check(view.detail_officer() == hire_id,
		"clicking the row opens the detail page")
	_check(view.get_node("Body/Detail").visible,
		"the detail page replaces the table")
	var actions: Dictionary = view.action_buttons(hire_id)
	for action in ["talk", "gift", "train", "appoint"]:
		_check(actions.has(action) and actions[action] is Button,
			"the detail page carries the %s action (§4.6.2)" % action)
	_check(view.dismiss_button(hire_id) is Button,
		"the detail page carries the dismiss action")
	# Back returns to the table.
	view.get_node("Body/Detail/DetailTop/DetailBack").pressed.emit()
	_check(view.detail_officer() == "" and not view.get_node("Body/Detail").visible,
		"back returns to the table")
	_window.close()
	# Cleanup: dismiss through the model funnel.
	CharacterLib.dismiss(hire_id)


## The 海图 tab is a direct entry (amended 2026-11-03): pressing it closes the
## window and enters the fullscreen S17 — no launcher page in between (one
## chart instance; one open + one close per suite).
func _test_chart_tab() -> void:
	var chart: Control = ChartScreenLib.attach_to(_host)
	_check(not chart.is_open(), "fixture: the chart starts closed")
	_window.open_tab(IntelWindowLib.TAB_CAPTAIN)
	_check(_window.has_node(
		"Center/Panel/Margin/Body/Content/ChartBox") == false,
		"the chart launcher page is gone (the tab is an action)")
	var tab: Button = _window.get_node(
		"Center/Panel/Margin/Body/Tabs/ChartTab")
	tab.pressed.emit()
	_check(chart.is_open() and not _window.is_open(),
		"pressing the 海图 tab enters S17 directly and closes the window")
	_check(_window.active_tab() != IntelWindowLib.TAB_CHART,
		"海图 never becomes the remembered tab (it is an action)")
	chart.call("close_chart")
	_check(not chart.is_open(), "the chart closes (one open+close per suite)")


## §4.3: C / O / F open the window on their tab; pressed again on the same tab
## the window closes; a different key switches tabs in place; Esc closes.
func _test_key_mapping() -> void:
	_window.close()
	_key("toggle_character")
	_check(_window.is_open() and _window.active_tab() == "captain",
		"C opens the window on the 船长 tab")
	_key("toggle_fleet")
	_check(_window.is_open() and _window.active_tab() == "fleet",
		"F switches the open window to the 船队 tab")
	_key("toggle_fleet")
	_check(not _window.is_open(),
		"F on the active tab closes the window")
	_key("toggle_officers")
	_check(_window.is_open() and _window.active_tab() == "officers",
		"O opens the window on the 官员 tab")
	_key("back")
	_check(not _window.is_open(), "Esc closes the window")


func _key(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	_window._unhandled_input(event)


## §6: with another modal up, a closed window refuses to open on a key; an
## open window still switches/closes (it is the modal then).
func _test_blocked_under_modal() -> void:
	_window.close()
	_hud.show_dialog("world.arrive", {"port": "Lisbon", "day": 1})
	_check(_hud.has_modal(), "fixture: a HUD dialog is on screen")
	_key("toggle_character")
	_check(not _window.is_open(),
		"C under a modal does not open the window (§6)")
	_window.open_tab(IntelWindowLib.TAB_CAPTAIN)
	_key("toggle_fleet")
	_check(_window.is_open() and _window.active_tab() == "fleet",
		"switching tabs inside the open window still works")
	_hud.clear_dialogs()
	_check(not _hud.has_modal(), "the fixture dialog drains cleanly")
	_window.close()


## §4.4: button label, window title, tab labels and view content re-bind on
## locale change. The locale is restored afterwards (global state).
func _test_locale_rebind() -> void:
	var other := "zh" if _locale_before == "en" else "en"
	I18n.set_locale(other)
	_check(_hud.intel_button().text == I18n.t_key("ui.intel"),
		"the intel button re-labels on locale change (%s)"
		% _hud.intel_button().text)
	_check(_window.get_node("Center/Panel/Margin/Body/TitleRow/Title").text
		== I18n.t_key("ui.intel"), "the window title re-binds")
	_window.open_tab(IntelWindowLib.TAB_OFFICERS)
	var view: Control = _window.get_node(
		"Center/Panel/Margin/Body/Content/OfficerRosterView")
	_check(view.get_node("Body/Controls/AttributesToggle").text
		== I18n.t_key("char.stats"), "the toggle labels re-bind")
	I18n.set_locale(_locale_before)
	_check(_hud.intel_button().text == I18n.t_key("ui.intel"),
		"the intel button re-labels back (%s)" % _hud.intel_button().text)
	_window.close()


# --- Harness ---------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	if I18n.get_locale() != _locale_before:
		I18n.set_locale(_locale_before)
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
