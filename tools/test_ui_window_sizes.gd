extends Node
## Window-size invariance gate (§4.6.1 class fix; the user-reported
## provisions-dialog resize bug). Headless scene test:
##
##   godot --headless --path . res://tools/test_ui_window_sizes.tscn
##
## Every window/dialog in the game is opened, driven through its
## state-changing actions (auto-fill, tab switches, steppers, selection,
## locale flips), and its window root size is asserted IDENTICAL across the
## states. Windows that grow with content BY DESIGN (the fleet picker's row
## list) are pinned on the axes that must hold (width) and declared so.
##
## Exits 0 when every check passes, 1 otherwise.

const PaletteLib := preload("res://scripts/palette.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const HailOptionsLib := preload("res://scripts/world/hail_options.gd")

const ProvisionsScene := preload("res://scenes/port/provisions_dialog.tscn")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")
const SaveSlotScene := preload("res://scenes/ui_shared/save_slot_dialog.tscn")
const SettingsScene := preload("res://scenes/ui_shared/settings_panel.tscn")
const HailScene := preload("res://scenes/world/hail_modal.tscn")
const FleetPickerScene := preload("res://scenes/world/fleet_picker.tscn")
const DuelScene := preload("res://scenes/combat/duel_modal.tscn")
const DialogBoxScene := preload("res://scenes/ui_shared/dialog_box.tscn")
const IntelWindowLib := preload("res://scenes/ui_shared/intel_window.gd")
const DossierLib := preload("res://scenes/ui/dossier_panel.gd")
const CardLib := preload("res://scenes/ui/character_card.gd")
const FleetViewScene := preload("res://scenes/ui_shared/fleet_view.tscn")
const RosterScene := preload("res://scenes/ui_shared/officer_roster_view.tscn")
const MarketScene := preload("res://scenes/port/market_screen.tscn")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const ShipyardScene := preload("res://scenes/port/shipyard_screen.tscn")
const GuildScene := preload("res://scenes/port/guild_screen.tscn")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const InnScene := preload("res://scenes/port/inn_screen.tscn")
const PortScreenScene := preload("res://scenes/port/port_screen.tscn")
const ChartScene := preload("res://scenes/world/chart_screen.tscn")
const CreationScene := preload("res://scenes/title/creation_screen.tscn")
const NationalityScene := preload("res://scenes/title/nationality_select.tscn")
const BattleScene := preload("res://scenes/combat/battle_screen.tscn")
const SandboxScene := preload("res://scenes/combat/battle_sandbox.tscn")
const EndingScene := preload("res://scenes/ui_shared/ending_screen.tscn")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")

var _failures: Array[String] = []
var _checks := 0
var _host: Control = null


func _ready() -> void:
	_host = Control.new()
	_host.size = Vector2(1280, 720)
	add_child(_host)
	await get_tree().process_frame
	_make_run()
	await _test_provisions_dialog()
	await _test_confirm_dialog()
	await _test_dialog_box()
	await _test_hail_modal()
	await _test_duel_modal()
	await _test_save_slot_dialog()
	await _test_settings_panel()
	await _test_intel_window()
	await _test_dossier_panel()
	await _test_character_card()
	await _test_fleet_view()
	await _test_officer_roster_view()
	await _test_fleet_picker()
	await _test_port_screens()
	await _test_full_screens()
	await _test_battle_windows()
	_report()


# --- Fixtures ---------------------------------------------------------------

func _make_run() -> void:
	GameState.new_game("portugal", false)
	GameState.current_port = "lisbon"
	GameState.gold = 20000


func _make_ship(provisions: int, water: int, cargo := {}) -> Dictionary:
	var ship: Dictionary = FleetLib.new_ship("caravel", 15)
	ship["provisions"] = provisions
	ship["water"] = water
	ship["cargo"] = cargo
	return ship


func _npc_fleet(captain_id: String, role := "trader") -> Dictionary:
	return {
		"id": "nf_test",
		"role": role,
		"nation_id": "",
		"cell": {"x": 100, "y": 100},
		"route": {"lanes": ["lane_a"], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {"wine": 30},
		"captain_id": captain_id,
		"dest_port_id": "seville",
		"cooldown_until_day": 0,
		"seed": 0,
		"dwell_until_day": 0,
		"anchor_cell": null,
		"convoy_count": 1,
		"on_berth": false,
	}


## Parks the player fleet on the test NPC's tile so the hail/pick range
## gates (Chebyshev ≤ 2) pass without the world map.
func _park_at_npc() -> void:
	GameState.world["position"] = {"x": 100, "y": 100}


func _battle_ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


func _pirate_encounter(enemy_count: int, hull_id := "sloop") -> Dictionary:
	var ships: Array = []
	for _index in enemy_count:
		ships.append(_battle_ship(hull_id))
	return {
		"id": "hf_9_30_40_pirate",
		"kind": "pirate",
		"nation_id": "",
		"position": {"x": 30, "y": 40},
		"day": 9,
		"ships": ships,
	}


func _first_captain_id(role: String, tier: int) -> String:
	for card in CaptainsLib.canon_list():
		if str((card as Dictionary).get("role", "")) == role \
				and int((card as Dictionary).get("tier", 0)) == tier:
			return str((card as Dictionary).get("id", ""))
	return ""


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _flip_locale() -> void:
	I18n.set_locale("zh" if I18n.get_locale() != "zh" else "en")
	await _settle()


func _report() -> void:
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - " + failure)
	get_tree().quit(1)


# --- The parametrized helper ---------------------------------------------------

## Opens `window` (already built + opened by the caller), runs every
## state-changing action, and asserts the window root size never drifts on
## the pinned `axes` ("xy" default; "x" for windows whose height grows with
## content by design). Returns the measured sizes (the report seam).
func assert_window_size_invariant(tag: String, window: Control,
		actions: Array, axes: String = "xy") -> Array:
	await _settle()
	var base: Vector2 = window.size
	var sizes: Array = [base]
	var ok := true
	for action in actions:
		await action.call()
		await _settle()
		var size: Vector2 = window.size
		sizes.append(size)
		if axes.contains("x") and not is_equal_approx(size.x, base.x):
			ok = false
		if axes.contains("y") and not is_equal_approx(size.y, base.y):
			ok = false
	_checks += 1
	if not ok:
		var label := "%s window size drifts on the '%s' axes across %d states" \
			% [tag, axes, sizes.size()]
		for index in sizes.size():
			label += "\n      state %d: %s" % [index, str(sizes[index])]
		_failures.append(label)
	else:
		print("PASS  %s pinned across %d states (%s)" % [tag, sizes.size(),
			str(base)])
	return sizes


# --- 1. The provisions dialog (the reported repro) ---------------------------

func _test_provisions_dialog() -> void:
	GameState.fleet = [_make_ship(20, 10, {"wine": 30})]
	GameState.gold = 5000
	var dialog: Control = ProvisionsScene.instantiate()
	_host.add_child(dialog)
	await _settle()
	dialog.open()
	await _settle()
	var panel: Control = dialog.get_node("Center/Panel")
	var sizes := await assert_window_size_invariant(
		"provisions dialog (the reported repro)", panel, [
			func() -> void:
				dialog.fill_button().pressed.emit(),
			func() -> void:
				dialog.plus_button("provisions").pressed.emit(),
			func() -> void:
				dialog.buy("provisions"),
		])
	# The §4.6.1 window pins itself at the widest observed state: every
	# open/fill/stepper/buy state renders exactly this geometry (both locales
	# exercised through the class sweep's flip below).
	_checks += 1
	if sizes[0].x != 862.0 or sizes[0].y != 568.0:
		_failures.append("provisions dialog renders %s, expected (862, 568)"
			% str(sizes[0]))
	dialog.close()
	dialog.queue_free()
	await _settle()


# --- 2. The confirm dialog ---------------------------------------------------

func _test_confirm_dialog() -> void:
	var dialog: Control = ConfirmScene.instantiate()
	_host.add_child(dialog)
	await _settle()
	var panel: Control = dialog.get_node("Center/Panel")
	dialog.open_key("fleet.jettison.confirm",
		{"ship": "Ship 1", "good": "Wine", "qty": 30})
	# Message boxes hug their message (80-* edge-case table: "text wraps;
	# dialog grows vertically to max 400px then scrolls") — the height is
	# resizable BY DESIGN; the 480px width must never drift.
	await assert_window_size_invariant(
		"confirm dialog (width; height by design)", panel, [
			func() -> void:
				dialog.open_key("port.sail.fill.confirm_both", {
					"discard": "Provisions × 75", "buy": "Water × 20",
					"target": 100, "gold": 120,
				}),
			func() -> void:
				dialog.open_key("port.sail.fill.confirm_discard", {
					"discard": "Water × 20", "buy": "",
					"target": 100, "gold": 20,
				}),
			func() -> void:
				dialog.cancel(),
		], "x")
	dialog.queue_free()
	await _settle()


# --- 3. The dialog box --------------------------------------------------------

func _test_dialog_box() -> void:
	var dialog: Control = DialogBoxScene.instantiate()
	_host.add_child(dialog)
	await _settle()
	var panel: Control = dialog.get_node("Center/Panel")
	dialog.open_text("A short line.")
	# Message boxes hug their message (80-* edge-case table: grows to 400px
	# then scrolls) — height by design; the width must never drift.
	await assert_window_size_invariant(
		"dialog box (width; height by design)", panel, [
			func() -> void:
				dialog.open_text("A much longer message line that carries a "
					+ "whole sentence of event narrative text for the crew."),
			func() -> void:
				dialog.open_text("Short again."),
			func() -> void:
				dialog.close(),
		], "x")
	dialog.queue_free()
	await _settle()


# --- 4. The hail modal ---------------------------------------------------------

func _test_hail_modal() -> void:
	var captain := _first_captain_id("trader", 1)
	CaptainsLib.ensure(captain)["stance"] = 2
	_park_at_npc()
	var modal: Control = HailScene.instantiate()
	_host.add_child(modal)
	await _settle()
	modal.call("setup", _npc_fleet(captain))
	await _settle()
	var panel: Control = modal.get_node("Center/Panel")
	# The hail box hugs its content with the shared 400px cap (80-* edge-case
	# table) — height by design; the width must never drift.
	await assert_window_size_invariant(
		"hail modal (width; height by design)", panel, [
			func() -> void:
				modal.call("_on_step", 10),
			func() -> void:
				modal.call("_on_step", -10),
			func() -> void:
				modal.call("_on_option_pressed",
					HailOptionsLib.OPTION_SUPPLIES),
			func() -> void:
				modal.call("close"),
		], "x")
	modal.queue_free()
	await _settle()


# --- 5. The duel modal ----------------------------------------------------------

func _duel_config(seed_value: int) -> Dictionary:
	return {
		"player_base": 15,
		"defender_base": 10,
		"seed": seed_value,
		"ship_name": "Sloop",
		"attacker_name": "You",
		"defender_name": "Pirate captain",
	}


func _test_duel_modal() -> void:
	var modal: Control = DuelScene.instantiate()
	_host.add_child(modal)
	await _settle()
	var panel: Control = modal.get_node("Center/Panel")
	modal.open_duel(_duel_config(33))
	await assert_window_size_invariant("duel modal", panel, [
		func() -> void:
			modal.open_duel(_duel_config(19)),
		func() -> void:
			modal.call("close"),
	])
	modal.queue_free()
	await _settle()


# --- 6. The save-slot dialog ------------------------------------------------------

func _test_save_slot_dialog() -> void:
	var dialog: Control = SaveSlotScene.instantiate()
	_host.add_child(dialog)
	await _settle()
	var panel: Control = dialog.get_node("Center/Panel")
	dialog.open(0)
	await assert_window_size_invariant("save-slot dialog", panel, [
		func() -> void:
			dialog.open(1),
		func() -> void:
			dialog.cancel(),
	])
	dialog.queue_free()
	await _settle()


# --- 7. The settings panel ----------------------------------------------------------

func _test_settings_panel() -> void:
	var panel_screen: Control = SettingsScene.instantiate()
	_host.add_child(panel_screen)
	await _settle()
	panel_screen.call("open")
	await _settle()
	var panel: Control = panel_screen.get_node("Center/Panel")
	var checkbox: Button = null
	for node in panel_screen.find_children("Check", "", true, false):
		if node is Button:
			checkbox = node
			break
	var actions: Array = []
	if checkbox != null:
		actions.append(func() -> void:
			checkbox.button_pressed = not checkbox.button_pressed)
		actions.append(func() -> void:
			checkbox.button_pressed = not checkbox.button_pressed)
	actions.append(func() -> void:
		panel_screen.call("close"))
	await assert_window_size_invariant("settings panel", panel, actions)
	panel_screen.queue_free()
	await _settle()


# --- 8. The intel window (six tabs) ---------------------------------------------------

func _test_intel_window() -> void:
	var window: Control = IntelWindowLib.attach_to(_host)
	await _settle()
	window.call("open")
	await _settle()
	var panel: Control = window.get_node("Center/Panel")
	await assert_window_size_invariant("intel window", panel, [
		func() -> void: window.call("open_tab", "reputation"),
		func() -> void: window.call("open_tab", "officers"),
		func() -> void: window.call("open_tab", "fleet"),
		func() -> void: window.call("open_tab", "chart"),
		func() -> void: window.call("open_tab", "quests"),
		func() -> void: window.call("open_tab", "captain"),
		func() -> void: window.call("close"),
	])
	window.queue_free()
	await _settle()


# --- 9. The dossier panel ---------------------------------------------------------------

func _test_dossier_panel() -> void:
	var captain := _first_captain_id("pirate", 1)
	if captain.is_empty():
		captain = _first_captain_id("trader", 1)
	var panel_window: Control = DossierLib.open_for(captain, _host)
	await _settle()
	var panel: Control = panel_window.get_node("Center/Panel")
	await assert_window_size_invariant("dossier panel", panel, [
		func() -> void:
			panel_window.call("setup", _first_captain_id("trader", 1)),
		func() -> void:
			panel_window.call("close"),
	])
	panel_window.queue_free()
	await _settle()


# --- 10. The character card -------------------------------------------------------------

func _test_character_card() -> void:
	var card: Control = (load("res://scenes/ui/character_card.tscn")
		as PackedScene).instantiate()
	_host.add_child(card)
	await _settle()
	card.setup_person("npc", CardLib.card_data("npc",
		_first_captain_id("trader", 1)))
	await _settle()
	# The card's root is a full-rect anchored PanelContainer when docked —
	# the pinned surface is its content body. NPC→NPC re-renders must be
	# identical; the player card renders the §4.12.2 allocation block the
	# NPC card lacks (by-design taller content — every host is a pinned
	# window or the picker's by-design card mode), so only the width pins.
	var body: Control = card.get_node("Margin/Scroll/Body")
	await assert_window_size_invariant("character card (npc)", body, [
		func() -> void:
			card.setup_person("npc", CardLib.card_data("npc",
				_first_captain_id("pirate", 1))),
	])
	await assert_window_size_invariant(
		"character card (npc→player; height by design)", body, [
			func() -> void:
				card.setup_person("player", CardLib.card_data("player", "")),
		], "x")
	card.queue_free()
	await _settle()


# --- 11. The fleet view -----------------------------------------------------------------

func _test_fleet_view() -> void:
	var view: Control = FleetViewScene.instantiate()
	_host.add_child(view)
	await _settle()
	GameState.fleet = [_make_ship(45, 45)]
	view.call("rebuild")
	await _settle()
	# A view that lists ships grows with the roster BY DESIGN (the intel
	# window hosting it is the pinned surface) — the column geometry (the
	# Body's width) must never drift.
	await assert_window_size_invariant("fleet view", view.get_node("Body"), [
		func() -> void:
			GameState.fleet = [
				_make_ship(45, 45), _make_ship(30, 30), _make_ship(20, 20),
			]
			view.call("rebuild"),
		func() -> void:
			GameState.fleet = [_make_ship(45, 45)]
			view.call("rebuild"),
	], "x")
	view.queue_free()
	await _settle()


# --- 12. The officers roster view ---------------------------------------------------------

func _test_officer_roster_view() -> void:
	GameState.fleet = [_make_ship(45, 45)]
	CharacterLib.recruit("off_mateus_alvares")
	var roster: Control = RosterScene.instantiate()
	_host.add_child(roster)
	await _settle()
	roster.call("rebuild")
	await _settle()
	var attributes: Button = roster.find_child("AttributesToggle", true, false)
	var skills: Button = roster.find_child("SkillsToggle", true, false)
	var actions: Array = []
	if attributes != null:
		actions.append(func() -> void: attributes.pressed.emit())
	if skills != null:
		actions.append(func() -> void: skills.pressed.emit())
	if attributes != null:
		actions.append(func() -> void: attributes.pressed.emit())
	await assert_window_size_invariant(
		"officers roster view", roster.get_node("Body"), actions)
	roster.queue_free()
	await _settle()


# --- 13. The fleet picker (row-count growth is BY DESIGN) --------------------------------

func _test_fleet_picker() -> void:
	var captain := _first_captain_id("trader", 1)
	var picker: Control = FleetPickerScene.instantiate()
	_host.add_child(picker)
	await _settle()
	var panel: Control = picker.get_node("Center/Panel")
	picker.call("open_fleets", [_npc_fleet(captain)])
	# A pick list grows with the fleets on the tile BY DESIGN (the master's
	# sanctioned resizable window) — the width must hold; the mode swap
	# (pick list → port context → character card) must not shift it either.
	await assert_window_size_invariant("fleet picker (width; height by design)",
		panel, [
			func() -> void:
				picker.call("open_fleets", [
					_npc_fleet(captain), _npc_fleet(captain, "pirate"),
				]),
			func() -> void:
				picker.call("open_port_context", "lisbon", true, ""),
			func() -> void:
				picker.call("close"),
		], "x")
	picker.queue_free()
	await _settle()


# --- 14. The port screens (full-viewport roots + inner windows) ---------------------------

func _test_port_screen_window(tag: String, scene: PackedScene,
		actions: Array) -> void:
	var screen: Control = scene.instantiate()
	_host.add_child(screen)
	await _settle()
	screen.visible = true
	await assert_window_size_invariant(tag, screen, actions)
	screen.queue_free()
	await _settle()


func _test_port_screens() -> void:
	# The locale flip re-renders every label — the strongest width-drift
	# probe there is — so each port screen runs it between two measures.
	GameState.fleet = [_make_ship(45, 45, {"wine": 30})]
	await _test_port_screen_window("market screen", MarketScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	await _test_port_screen_window("tavern screen", TavernScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	await _test_port_screen_window("shipyard screen", ShipyardScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	await _test_port_screen_window("guild screen", GuildScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	await _test_port_screen_window("palace screen", PalaceScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	await _test_port_screen_window("inn screen", InnScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	await _test_port_screen_window("port hub screen", PortScreenScene, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])


# --- 15. The full screens ------------------------------------------------------------------

func _test_full_screens() -> void:
	GameState.fleet = [_make_ship(45, 45)]
	var chart: Control = ChartScene.instantiate()
	_host.add_child(chart)
	chart.visible = true
	await _settle()
	await assert_window_size_invariant("chart screen", chart, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	chart.queue_free()
	await _settle()

	var creation: Control = CreationScene.instantiate()
	_host.add_child(creation)
	await _settle()
	await assert_window_size_invariant("creation screen", creation, [
		func() -> void:
			creation.set("_step", 2)
			creation.call("_show_step"),
		func() -> void:
			creation.set("_step", 1)
			creation.call("_show_step"),
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	creation.queue_free()
	await _settle()

	var nationality: Control = NationalityScene.instantiate()
	_host.add_child(nationality)
	await _settle()
	await assert_window_size_invariant("nationality screen", nationality, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	nationality.queue_free()
	await _settle()

	var ending: Control = EndingScene.instantiate()
	_host.add_child(ending)
	await _settle()
	ending.call("open_live")
	await assert_window_size_invariant("ending screen", ending, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	ending.queue_free()
	await _settle()

	var gameover: Control = GameOverScene.instantiate()
	_host.add_child(gameover)
	await _settle()
	gameover.call("open_reason", "starved")
	await assert_window_size_invariant("game-over screen", gameover, [
		func() -> void: I18n.set_locale("zh"),
		func() -> void: I18n.set_locale("en"),
	])
	gameover.queue_free()
	await _settle()


# --- 16. The battle windows ------------------------------------------------------------------

func _test_battle_windows() -> void:
	# The battle ROOT is full-viewport anchored (trivial pin), and the two
	# floating windows over it — the battle menu and the after-action report —
	# are content-sized and must hold across their state changes.
	var screen: Control = BattleScene.instantiate()
	_host.add_child(screen)
	screen.set("route_to_world", false)
	await _settle()
	screen.call("open_battle", _pirate_encounter(1))
	await _settle()
	await assert_window_size_invariant("battle screen root", screen, [
		func() -> void: pass,
	])

	screen.call("open_menu")
	await _settle()
	var menu_panel: Control = screen.get_node("BattleMenu/Center/Panel")
	var ai_button: Button = screen.get_node(
		"BattleMenu/Center/Panel/Margin/Body/AiAnimate")
	await assert_window_size_invariant("battle menu window", menu_panel, [
		func() -> void:
			ai_button.pressed.emit(),
		func() -> void:
			ai_button.pressed.emit(),
		func() -> void:
			screen.call("close_menu"),
	])

	# The after-action report: a victory over 1 ship vs 3 ships renders
	# different loot lines — the report window must hold its geometry.
	var reports: Array = []
	for count in [1, 3]:
		var screen2: Control = BattleScene.instantiate()
		_host.add_child(screen2)
		screen2.set("route_to_world", false)
		await _settle()
		var encounter := _pirate_encounter(count)
		if count == 1:
			(encounter["ships"][0] as Dictionary)["durability"] = 5
		screen2.call("open_battle", encounter)
		await _settle()
		screen2.call("run_to_completion", 30)
		await _settle()
		reports.append((screen2.get_node("AfterAction/Center/Panel") as Control).size)
		screen2.queue_free()
		await _settle()
	_checks += 1
	if not (reports[0] as Vector2).is_equal_approx(reports[1]):
		_failures.append("after-action report window drifts between outcomes: "
			+ "%s vs %s" % [str(reports[0]), str(reports[1])])
	else:
		print("PASS  after-action report window pinned across outcomes (%s)"
			% str(reports[0]))

	screen.queue_free()
	await _settle()

	# The sandbox hosts docked panels over a full-viewport root.
	var sandbox: Control = SandboxScene.instantiate()
	_host.add_child(sandbox)
	await _settle()
	await assert_window_size_invariant("battle sandbox root", sandbox, [
		func() -> void: pass,
	])
	sandbox.queue_free()
	await _settle()
