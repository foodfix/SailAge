extends Node
## Intel-menu acceptance tests (docs/80-UI-UX.md §4.5, §4.2 amendment
## 2026-11-03, §4.3 click row). Headless scene test:
##
##   godot --headless res://tools/test_intel_menu.tscn
##
## Exits 0 when every check passes, 1 otherwise. Covers: the top-bar 情报
## MenuButton on the shared HUD (S3 *and* S4 — the port mode only hides the
## minimap, never the menu), the fixed five-entry dropdown in display order
## (船长 `char.title` · 官员 `officers.title` · 船队 `fleet.title` · 海图
## `chart.title` · 委托 `char.quests`, §4.4), each entry opening exactly the
## shared modal its hotkey opens — never a duplicate instance — the 委托
## entry landing S14 on the quests tab, the locale rebind (button + items,
## §4.4), and the §6 modal-ownership guard (a press under a modal is ignored).
## The chart entry shares ONE open/close with this suite (every `open_chart`
## rebuilds the whole 4320×2160 terrain image — the test_chart discipline).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const CharacterPanelLib := preload("res://scenes/ui_shared/character_panel.gd")
const FleetPanelLib := preload("res://scenes/ui_shared/fleet_panel.gd")
const OfficersPanelLib := preload("res://scenes/port/officers_panel.gd")
const ChartScreenLib := preload("res://scenes/world/chart_screen.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")

var _failures: Array[String] = []
var _checks := 0

## One HUD instance shared by every section (the §4.5 menu is stateless).
var _hud = null
## The Control wrapper the HUD lives in (1280×720, the §4.5 canvas).
var _host: Control = null
## Locale is a global: saved here and restored in `_report` so a failure
## halfway cannot leak zh/en into later suites of the same gate run.
var _locale_before: String = "en"


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the chart fallback fixture (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	GameState.new_game("portugal", false)
	_check(not GameState.player.is_empty(), "fixture run has a player")
	_locale_before = I18n.get_locale()

	_host = Control.new()
	_host.name = "IntelHost"
	_host.size = Vector2(1280, 720)
	add_child(_host)
	_hud = HUDScene.instantiate()
	_host.add_child(_hud)

	var _sections: Array = [
		["_test_button_presence"], ["_test_menu_items"],
		["_test_captain_item"], ["_test_quests_item"],
		["_test_fleet_item"], ["_test_officers_item"],
		["_test_chart_item"], ["_test_blocked_under_modal"],
		["_test_locale_rebind"],
	]
	for section in _sections:
		call(section[0])
	_report()


# --- Sections --------------------------------------------------------------

## §4.5: the 情报 MenuButton sits at the top bar's right end on the shared
## HUD — visible at sea (S3) and equally present in port mode (S4, where only
## the minimap is replaced).
func _test_button_presence() -> void:
	var button: MenuButton = _hud.intel_button()
	_check(button != null and button is MenuButton,
		"the HUD exposes the intel MenuButton")
	_check(button.get_parent() == _hud.get_node("TopRow"),
		"the intel button lives in the HUD top bar")
	_check(button.get_index() == button.get_parent().get_child_count() - 1,
		"the intel button is the top bar's last (rightmost) entry")
	_check(button.visible and button.text == I18n.t_key("ui.intel"),
		"the button reads ui.intel in the current locale (%s)" % button.text)
	_check(button.custom_minimum_size.y == 32.0,
		"the button matches the top bar's 32px button height")
	# S4 (port hub): the sea viewport is replaced, the top bar is not.
	_hud.set_minimap_visible(false)
	_check(button.visible and button.get_parent().visible,
		"the intel button stays visible in port mode (S4)")
	_hud.set_minimap_visible(true)


## §4.5: exactly five entries, display order captain → officers → fleet →
## chart → 委托, each rendered from its own ui_strings key (§4.4). The popup
## itself is a native sub-window headless suites never open, so the labels are
## asserted both through the hook and off the popup's items.
func _test_menu_items() -> void:
	var texts: Array = _hud.intel_menu_texts()
	_check(texts.size() == 5,
		"the intel menu has exactly five entries (%d)" % texts.size())
	for index in HudLib.INTEL_ITEM_KEYS.size():
		var key: String = HudLib.INTEL_ITEM_KEYS[index]
		_check(str(texts[index]) == I18n.t_key(key),
			"intel item %d reads %s (%s)" % [index, key, str(texts[index])])
	var popup: PopupMenu = _hud.intel_button().get_popup()
	_check(popup != null and popup.item_count == 5,
		"the popup carries all five items (%s)"
		% str(popup.item_count if popup != null else -1))
	if popup != null:
		var mismatch := ""
		for index in popup.item_count:
			if popup.get_item_text(index) != I18n.t_key(
					HudLib.INTEL_ITEM_KEYS[index]):
				mismatch = "%d:%s" % [index, popup.get_item_text(index)]
				break
		_check(mismatch.is_empty(),
			"popup item labels match the ui_strings keys (%s)" % mismatch)


## 船长 → S14 toggle, the same modal instance the host's own `C` attach made
## room for (the panel is found under the host root's CanvasLayer, §4.5).
func _test_captain_item() -> void:
	_hud.press_intel_item(HudLib.INTEL_CAPTAIN)
	var panel: Control = CharacterPanelLib._find_panel(_panel_host())
	_check(panel != null and bool(panel.call("is_open")),
		"the captain entry opens the S14 character panel")
	_check(_panel_host().find_children("CharacterPanel", "", true, false).size() == 1,
		"the captain entry reuses one S14 instance (no duplicate)")
	# A second press toggles it closed, exactly like `C`.
	_hud.press_intel_item(HudLib.INTEL_CAPTAIN)
	_check(panel == null or not bool(panel.call("is_open")),
		"a second captain press closes S14 (the C toggle contract)")


## 委托 → S14 on the quests tab (§4.5); already-open S14 keeps open and only
## switches the tab (the tab choice itself is not persisted, §4.12.3).
func _test_quests_item() -> void:
	var host := _panel_host()
	_hud.press_intel_item(HudLib.INTEL_QUESTS)
	var panel: Control = CharacterPanelLib._find_panel(host)
	_check(panel != null and bool(panel.call("is_open")),
		"the 委托 entry opens S14")
	_check(panel != null and str(panel.call("active_tab")) == "quests",
		"the 委托 entry lands S14 on the quests tab (%s)"
		% str(panel.call("active_tab") if panel != null else "-"))
	# Open S14 on another tab, then 委托 again: the tab switches in place.
	panel.call("select_tab", "attributes")
	_hud.press_intel_item(HudLib.INTEL_QUESTS)
	_check(bool(panel.call("is_open")),
		"委托 with S14 already open keeps the panel open")
	_check(str(panel.call("active_tab")) == "quests",
		"委托 switches an open S14 to the quests tab")
	panel.call("close")


## 船队 → S15 toggle (the `F` contract; at sea the panel is read-only but the
## menu opens it all the same — §4.5.1).
func _test_fleet_item() -> void:
	_hud.press_intel_item(HudLib.INTEL_FLEET)
	var panel: Control = FleetPanelLib._find_panel(_panel_host())
	_check(panel != null and bool(panel.call("is_open")),
		"the fleet entry opens the S15 fleet panel")
	_hud.press_intel_item(HudLib.INTEL_FLEET)
	_check(panel == null or not bool(panel.call("is_open")),
		"a second fleet press closes S15 (the F toggle contract)")


## 官员 → S18 toggle (`O`). The run is at sea here (no `current_port`), which
## is the Phase-8 sea case: the panel opens, its own rules gate the actions.
func _test_officers_item() -> void:
	_hud.press_intel_item(HudLib.INTEL_OFFICERS)
	var panel: Control = OfficersPanelLib._find_panel(_panel_host())
	_check(panel != null and bool(panel.call("is_open")),
		"the officers entry opens the S18 officers panel at sea")
	_hud.press_intel_item(HudLib.INTEL_OFFICERS)
	_check(panel == null or not bool(panel.call("is_open")),
		"a second officers press closes S18 (the O toggle contract)")


## 海图 → S17 toggle (`Tab`). The shared chart instance is pre-attached to the
## HUD's parent (the production hosting shape, §4.6) and the entry must find —
## never duplicate — it. One open + close only: every open rebuilds the
## whole-world image (the test_chart discipline).
func _test_chart_item() -> void:
	var chart: Control = ChartScreenLib.attach_to(_host)
	_check(chart == _hud.get_node_or_null("../ChartScreen"),
		"the chart entry resolves the HUD-parent sibling instance")
	_hud.press_intel_item(HudLib.INTEL_CHART)
	_check(chart.is_open(), "the chart entry opens S17")
	var chart_count := 0
	for child in _host.get_children():
		if child.name.begins_with("ChartScreen"):
			chart_count += 1
	_check(chart_count == 1, "exactly one S17 instance exists (%d)" % chart_count)
	_hud.press_intel_item(HudLib.INTEL_CHART)
	_check(not chart.is_open(), "a second chart press closes S17 (Tab contract)")


## §6 modal ownership: with a HUD dialog up, a dropdown press must open
## nothing (the popup cannot legally be up over a modal).
func _test_blocked_under_modal() -> void:
	_hud.show_dialog("world.arrive", {"port": "Lisbon", "day": 1})
	_check(_hud.has_modal(), "fixture: a HUD dialog is on screen")
	_hud.press_intel_item(HudLib.INTEL_CAPTAIN)
	var panel: Control = CharacterPanelLib._find_panel(_panel_host())
	_check(panel == null or not bool(panel.call("is_open")),
		"a dropdown press under a modal opens nothing (§6)")
	_hud.clear_dialogs()
	_check(not _hud.has_modal(), "the fixture dialog drains cleanly")


## §4.4: the button label re-binds on locale change; the item labels re-bind
## on the next open (`about_to_popup` → `_rebind_intel_menu`), mirrored here
## by the hook. The locale is restored afterwards (global state).
func _test_locale_rebind() -> void:
	var other := "zh" if _locale_before == "en" else "en"
	I18n.set_locale(other)
	_check(_hud.intel_button().text == I18n.t_key("ui.intel"),
		"the intel button re-labels on locale change (%s)"
		% _hud.intel_button().text)
	var texts: Array = _hud.intel_menu_texts()
	var mismatch := ""
	for index in texts.size():
		if str(texts[index]) != I18n.t_key(HudLib.INTEL_ITEM_KEYS[index]):
			mismatch = str(index)
			break
	_check(mismatch.is_empty(),
		"the intel item labels re-read ui_strings in the new locale (%s)"
		% mismatch)
	_check(_hud.intel_menu_texts().size() == 5,
		"the re-bound menu still has five entries")
	I18n.set_locale(_locale_before)
	_check(_hud.intel_button().text == I18n.t_key("ui.intel"),
		"the intel button re-labels back (%s)" % _hud.intel_button().text)


# --- Harness ---------------------------------------------------------------

func _panel_host() -> Node:
	return get_tree().current_scene if get_tree().current_scene != null \
		else self


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
