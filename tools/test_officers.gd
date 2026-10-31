extends Node
## S18 acceptance tests — the Phase-5 officers panel (docs/80-UI-UX.md §4.6.2,
## docs/50-* §4.2/§4.4/§4.5, docs/80-* §4.3/§4.7/§4.8).
##
##   godot --headless res://tools/test_officers.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections
##   1 the row set: one row per employed officer, sorted by `id`, with the four
##     stats, the wage and the recruit port (all from `data/officers.json`);
##   2 the derived effects: each role's contribution read from `CharacterLib`'s
##     existing formulas (navigation → sighting radius, seamanship → speed
##     bonus, leadership → mutiny multiplier, combat → the battle/duel surface);
##   3 dismissal: the confirm dialog, the `CharacterLib.dismiss` path, the slot
##     and the wage bill updating immediately;
##   4 at-sea read-only (`officers.readonly_sea`), with the button disabled and
##     a stated reason — and a programmatic press that changes nothing;
##   5 header (`officers.slots` + total wage), empty state, locale rebind, the
##     `O` key and close/Esc ownership.

const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const OfficersScene := preload("res://scenes/port/officers_panel.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")

## The Portugal starter officer (`data/officers.json`, id order).
const MATEUS := "off_mateus_alvares"
const DIEGO := "off_diego_fernandez"
const KEMAL := "off_kemal_agha"

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_roster_rows()
	_test_derived_effects()
	await _test_dismiss()
	await _test_read_only_at_sea()
	await _test_header_empty_and_locale()
	await _test_entry_points()
	_report()


# --- Fixtures --------------------------------------------------------------

## A Portugal run docked at Lisbon with a plain 10-stat captain and `officers`.
func _make_run(officers: Array = [], port = "lisbon",
		navigation: int = 15) -> void:
	GameState.player = {
		"nation_id": "portugal",
		# `navigation` defaults to 15: the Portugal start's base 10 + the nation
		# bonus (`50-*` §4.2), i.e. the run a new game actually creates.
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": navigation, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": officers.duplicate(),
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.gold = 10000
	GameState.day = 12
	GameState.morale = 70
	GameState.fleet = [FleetLib.new_ship("caravel", 15)]
	GameState.current_port = port
	GameState.world = {"position": {"x": 7, "y": 57}, "clock_fraction": 0.0}
	GameState.locale = "en"


func _mount() -> Control:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var panel: Control = OfficersScene.instantiate()
	host.add_child(panel)
	return panel


# --- 1. The roster rows ----------------------------------------------------

func _test_roster_rows() -> void:
	_make_run([KEMAL, MATEUS, DIEGO])
	var panel := _mount()
	panel.open()

	# §4.6.2: one row per employed officer, sorted by `id`.
	_check(panel.officer_ids() == [DIEGO, KEMAL, MATEUS],
		"rows are sorted by officer id (%s)" % str(panel.officer_ids()))
	_check(panel.officer_ids() == ["off_diego_fernandez",
			"off_kemal_agha", "off_mateus_alvares"],
		"the sorted order matches the data ids (diego < kemal < mateus)")

	var mateus: Dictionary = DataLoader.get_officer(MATEUS)
	var row: Dictionary = panel.row_widget(MATEUS)
	_check(not row.is_empty(), "Mateus Álvares has a row widget")
	_check((row["name"] as Label).text == I18n.t(mateus["name"]),
		"the row name is the localised data name (%s)"
		% (row["name"] as Label).text)
	# The role tag reuses the tavern's existing labels — no second wording.
	_check((row["role"] as Label).text == I18n.t_key("tavern.role.navigator"),
		"the role tag is tavern.role.navigator (%s)"
		% (row["role"] as Label).text)
	_check(I18n.t_key("tavern.role.navigator") == "Navigator",
		"tavern.role.navigator reads 'Navigator' in en")

	# The four stats, in the §4.6.2 order, from `data/officers.json`.
	var stats: HBoxContainer = row["stats"]
	_check(stats.get_child_count() == 5,
		"the stats line holds the four stat cells plus the wage cell (got %d)"
		% stats.get_child_count())
	var expected := [
		["leadership", 10], ["seamanship", 14], ["combat", 6], ["navigation", 16],
	]
	var stat_cells := 0
	for child in stats.get_children():
		if child is Label and str(child.name).begins_with("Stat_"):
			stat_cells += 1
	_check(stat_cells == 4,
		"exactly four stat cells are rendered (got %d)" % stat_cells)
	for index in expected.size():
		var stat_key := str(expected[index][0])
		var value := int(expected[index][1])
		var cell: Label = stats.get_node("Stat_%s" % stat_key)
		_check(cell != null and cell.text.contains(str(value)),
			"the %s cell shows the data value %d (%s)"
			% [stat_key, value, "" if cell == null else cell.text])
		_check(cell != null and cell.text.contains(I18n.t_key("char.%s" % stat_key)),
			"the %s cell is localised through char.%s" % [stat_key, stat_key])
	_check((row["wage"] as Label).text == I18n.fmt(
			"tavern.wage", {"price": int(mateus["wage_daily"])}),
		"the row shows wage_daily through tavern.wage (%s)"
		% (row["wage"] as Label).text)

	# §4.6.2: the recruit port is `recruit_ports[0]`, localised.
	var lisbon_name := I18n.t(DataLoader.get_port("lisbon")["name"])
	_check((row["recruited"] as Label).text == I18n.fmt(
			"officers.recruited_at", {"port": lisbon_name}),
		"the row uses officers.recruited_at with Lisbon (%s)"
		% (row["recruited"] as Label).text)
	_check(str(mateus["recruit_ports"][0]) == "lisbon",
		"fixture: Mateus's recruit_ports[0] is lisbon")

	# Every officer row is a 32px-line table row (§4.8) with a Dismiss button.
	var dismiss: Button = panel.dismiss_button(MATEUS)
	_check(dismiss != null and dismiss.text == I18n.t_key("officers.dismiss"),
		"the row has a Dismiss button (%s)"
		% ("-" if dismiss == null else dismiss.text))
	_check(dismiss != null and not dismiss.disabled,
		"Dismiss is enabled at port")
	_check(row["node"] is Control and (row["node"] as Control)
		.custom_minimum_size.y >= 0.0, "the row is a laid-out control")

	# An unknown id in `player.officers` is skipped, not fatal (gotcha 5).
	GameState.player["officers"] = [MATEUS, "off_nobody"]
	panel.rebuild()
	_check(panel.officer_ids() == [MATEUS],
		"an unknown officer id is skipped, not rendered (%s)"
		% str(panel.officer_ids()))

	panel.get_parent().queue_free()


# --- 2. The derived effects ------------------------------------------------

func _test_derived_effects() -> void:
	_make_run([MATEUS, DIEGO, KEMAL])
	var panel := _mount()
	panel.open()

	# Navigation → sighting radius. `24 + floor((navigation − 10) / 10)`;
	# Mateus's role adds +10 navigation, so the radius gains one tile.
	# navigation 15 + the navigator's 10 = 25 effective ⇒ 24 + floor(15/10) = 25.
	_check(CharacterLib.sighting_radius() == 25,
		"the navigator's +10 navigation moves the radius 24 → 25 (got %d)"
		% CharacterLib.sighting_radius())
	var mateus_effect: String = panel.effect_text(MATEUS)
	_check(mateus_effect.contains(I18n.t_key("char.navigation")),
		"the navigator's effect names navigation (%s)" % mateus_effect)
	_check(mateus_effect.contains("+10"),
		"…with the +10 role bonus (%s)" % mateus_effect)
	_check(mateus_effect.contains("25"),
		"…and the resulting sighting radius 25 (%s)" % mateus_effect)
	_check((panel.row_widget(MATEUS)["effect"] as Label).text == I18n.fmt(
			"officers.effect", {"effect": mateus_effect}),
		"the row renders it through officers.effect")

	# Seamanship → speed bonus. Boatswain +10 seamanship = +10% speed.
	var diego_effect: String = panel.effect_text(DIEGO)
	_check(diego_effect.contains(I18n.t_key("char.seamanship")),
		"the boatswain's effect names seamanship (%s)" % diego_effect)
	_check(diego_effect.contains("+10%"),
		"…and the +10% speed bonus its +10 buys (%s)" % diego_effect)
	_check(is_equal_approx(CharacterLib.speed_bonus(), 0.10),
		"seamanship 10 + the boatswain's 10 → +10%% speed (%.2f)"
		% CharacterLib.speed_bonus())

	# Leadership → mutiny/desertion (`50-*` §4.2: `1 − (leadership − 10) / 200`).
	# `50-*` §4.5's role table grants **no** leadership bonus, so no per-officer
	# row may claim one; the roster's aggregate multiplier is still reachable
	# from the panel through `CharacterLib.mutiny_multiplier()`.
	var officers_panel_script := load("res://scenes/port/officers_panel.gd")
	_check(not mateus_effect.contains(I18n.t_key("world.mutiny.title")),
		"no row claims a leadership effect the role table does not grant (%s)"
		% mateus_effect)
	_check(officers_panel_script.mutiny_multiplier_text().begins_with(
			I18n.t_key("world.mutiny.title")),
		"the roster's mutiny multiplier is reachable (%s)"
		% officers_panel_script.mutiny_multiplier_text())
	_check(is_equal_approx(CharacterLib.loss_multiplier_for(20), 0.95),
		"leadership 20 → losses ×0.95 (%s)"
		% str(CharacterLib.loss_multiplier_for(20)))

	# Combat → the battle/duel surface (the gunner's +10 combat).
	var kemal_effect: String = panel.effect_text(KEMAL)
	_check(kemal_effect.contains(I18n.t_key("char.combat")),
		"the gunner's effect names combat (%s)" % kemal_effect)
	_check(kemal_effect.contains(I18n.t_key("battle.title")),
		"…and names the battle/duel it feeds (%s)" % kemal_effect)
	_check(CharacterLib.effective_stat("combat") == 20,
		"the gunner's +10 combat lands 10 → 20 (got %d)"
		% CharacterLib.effective_stat("combat"))

	# No effect renders a raw <key> or a stray {placeholder} (§6).
	var unresolved: Array[String] = []
	for officer_id in panel.officer_ids():
		var text: String = panel.effect_text(officer_id)
		_check(not text.contains("<") and not text.contains("{"),
			"the '%s' effect is fully localised (%s)" % [officer_id, text])
	_check(unresolved.is_empty(), "no unresolved keys in the effects")

	# Solo officer: the same formulas with no stacking.
	_make_run([MATEUS])
	panel.rebuild()
	_check(CharacterLib.sighting_radius() == 25,
		"a solo navigator still gives 24 + floor(15/10) = 25 (got %d)"
		% CharacterLib.sighting_radius())
	_check(CharacterLib.effective_stat("navigation") == 25,
		"§5's worked example: navigation 15 + 10 = 25 (got %d)"
		% CharacterLib.effective_stat("navigation"))
	_check(CharacterLib.sighting_radius_for(25) == 25,
		"§5: sighting 24 + floor((25-10)/10) = 25")

	panel.get_parent().queue_free()


# --- 3. Dismissal ----------------------------------------------------------

func _test_dismiss() -> void:
	await get_tree().process_frame
	_make_run([MATEUS, DIEGO])
	var panel := _mount()
	panel.open()
	await get_tree().process_frame

	var wage_before: int = CharacterLib.officer_wages()
	_check(wage_before == 58, "wage bill starts at 30 + 28 = 58 (got %d)"
		% wage_before)
	_check(panel.total_wage() == wage_before,
		"total_wage() reports the same bill (%d)" % panel.total_wage())

	var dismiss: Button = panel.dismiss_button(MATEUS)
	_check(dismiss != null and not dismiss.disabled, "Dismiss is available")
	dismiss.pressed.emit()
	await get_tree().process_frame
	var confirm: Control = panel.get_node("ConfirmDialog")
	_check(confirm.is_open(), "Dismiss opens a confirm dialog (§4.7)")
	_check(confirm.message_text() == I18n.fmt(
			"officers.dismiss.confirm",
			{"name": I18n.t(DataLoader.get_officer(MATEUS)["name"])}),
		"the confirm uses officers.dismiss.confirm with {name} (%s)"
		% confirm.message_text())
	_check(CharacterLib.is_employed(MATEUS),
		"nothing happens before the player confirms")

	# Cancel keeps the officer.
	confirm.cancel()
	await get_tree().process_frame
	_check(CharacterLib.is_employed(MATEUS), "cancelling keeps the officer")
	_check(CharacterLib.officer_wages() == wage_before,
		"cancelling keeps the wage bill")

	# Confirm goes through `CharacterLib.dismiss` — the tavern's own path.
	var dismissed: Array = []
	panel.officer_dismissed.connect(func(oid: String) -> void:
		dismissed.append(oid))
	panel.dismiss_button(MATEUS).pressed.emit()
	await get_tree().process_frame
	confirm.accept()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not CharacterLib.is_employed(MATEUS), "confirming dismisses the officer")
	_check(dismissed == [MATEUS],
		"the panel emits officer_dismissed(%s) (%s)" % [MATEUS, str(dismissed)])
	_check(panel.officer_ids() == [DIEGO],
		"the roster drops the dismissed row (%s)" % str(panel.officer_ids()))
	_check(CharacterLib.officer_wages() == 28,
		"the wage bill drops 58 → 28 immediately (got %d)"
		% CharacterLib.officer_wages())
	var slots: Label = panel.get_node("Center/Panel/Margin/Body/Slots")
	_check(slots.text.contains("28"),
		"the header's wage figure follows the dismissal (%s)" % slots.text)
	_check(slots.text.contains("1") and slots.text.contains("3"),
		"the header slot count is 1 / 3 (%s)" % slots.text)

	# The dismissed officer is recruitable again (`50-*` §4.4: the officer
	# returns to its recruit pool) — i.e. the same `CharacterLib` state the
	# tavern reads was updated, not a panel-local copy.
	_check(CharacterLib.can_recruit(MATEUS),
		"a dismissed officer is recruitable again (the shared pool)")

	# A stale confirm (panel closed) never dismisses anyone.
	_make_run([MATEUS])
	panel.rebuild()
	await get_tree().process_frame
	panel.dismiss_button(MATEUS).pressed.emit()
	await get_tree().process_frame
	_check(confirm.is_open(), "the confirm is up before the panel closes")
	panel.close()
	await get_tree().process_frame
	_check(not confirm.is_open(),
		"closing the panel dismisses its pending confirm (§6)")
	_check(CharacterLib.is_employed(MATEUS),
		"the abandoned confirm did not dismiss the officer")

	panel.get_parent().queue_free()
	await get_tree().process_frame


# --- 4. At-sea read-only ---------------------------------------------------

func _test_read_only_at_sea() -> void:
	await get_tree().process_frame
	_make_run([MATEUS], null)
	var panel := _mount()
	panel.open()
	await get_tree().process_frame

	_check(panel.is_read_only(), "the panel is read-only at sea (§4.6.2)")
	var dismiss: Button = panel.dismiss_button(MATEUS)
	_check(dismiss != null and dismiss.disabled, "Dismiss is disabled at sea")
	_check(dismiss != null and dismiss.tooltip_text
		== I18n.t_key("officers.readonly_sea"),
		"the disabled reason is officers.readonly_sea (%s)"
		% ("-" if dismiss == null else dismiss.tooltip_text))
	var note: Label = panel.get_node("Center/Panel/Margin/Body/ModeNote")
	_check(note.visible and note.text == I18n.t_key("officers.readonly_sea"),
		"the panel explains the at-sea rule (%s)" % note.text)
	_check(panel.dismiss_block_reason(MATEUS) == "officers.readonly_sea",
		"dismiss_block_reason() returns the key at sea")

	# A programmatic press still changes nothing.
	if dismiss != null:
		dismiss.pressed.emit()
	await get_tree().process_frame
	_check(CharacterLib.is_employed(MATEUS),
		"a sea Dismiss click leaves the roster untouched")
	_check(not (panel.get_node("ConfirmDialog") as Control).is_open(),
		"no confirm opens for a disabled sea Dismiss")

	panel.get_parent().queue_free()
	await get_tree().process_frame


# --- 5. Header, empty state, locale, entry points --------------------------

func _test_header_empty_and_locale() -> void:
	await get_tree().process_frame
	_make_run([])
	var panel := _mount()
	panel.open()
	await get_tree().process_frame

	# Header: `officers.slots` with {used}/{max} and the total wage.
	var slots: Label = panel.get_node("Center/Panel/Margin/Body/Slots")
	_check(slots.text == I18n.fmt("officers.slots", {
			"used": 0, "max": CharacterLib.OFFICER_MAX, "wage": 0,
		}),
		"the header uses officers.slots with {used}/{max} and {wage} (%s)"
		% slots.text)
	_check(slots.text.contains("0 / 3"),
		"the empty roster reads 0 / 3 (%s)" % slots.text)
	var title: Label = panel.get_node("Center/Panel/Margin/Body/Title")
	_check(title.text == I18n.t_key("officers.title"),
		"the title uses officers.title (%s)" % title.text)

	# Empty state: `char.no_officers` + the tavern hint (§4.6.2).
	var empty: Label = panel.get_node("Center/Panel/Margin/Body/Empty")
	var hint: Label = panel.get_node("Center/Panel/Margin/Body/EmptyHint")
	_check(empty.visible and empty.text == I18n.t_key("char.no_officers"),
		"the empty state uses char.no_officers (%s)" % empty.text)
	_check(hint.visible and hint.text == I18n.t_key("officers.empty_hint"),
		"…plus officers.empty_hint (%s)" % hint.text)
	_check(panel.officer_ids().is_empty(), "no officer rows are rendered")

	# With an officer, the empty state hides and the header follows.
	GameState.player["officers"] = [MATEUS]
	panel.rebuild()
	await get_tree().process_frame
	_check(not empty.visible and not hint.visible,
		"the empty state hides once the roster has an officer")
	_check(slots.text.contains("1 / 3") and slots.text.contains("30"),
		"the header shows 1 / 3 and 30g/day (%s)" % slots.text)

	# Locale rebind: every string follows zh↔en.
	I18n.set_locale("zh")
	await get_tree().process_frame
	_check((panel.get_node("Center/Panel/Margin/Body/Title") as Label).text
		== "官员", "the title rebinds to zh (%s)"
		% (panel.get_node("Center/Panel/Margin/Body/Title") as Label).text)
	var zh_row: Dictionary = panel.row_widget(MATEUS)
	_check((zh_row["role"] as Label).text == I18n.t_key("tavern.role.navigator"),
		"the role tag rebinds to zh (%s)" % (zh_row["role"] as Label).text)
	_check((zh_row["recruited"] as Label).text.contains("里斯本"),
		"the recruit port rebinds to zh (%s)"
		% (zh_row["recruited"] as Label).text)
	_check((zh_row["dismiss"] as Button).text == "解雇",
		"the Dismiss button rebinds to zh (%s)"
		% (zh_row["dismiss"] as Button).text)
	_check(panel.effect_text(MATEUS).contains(I18n.t_key("char.navigation")),
		"the derived effect rebinds to zh (%s)" % panel.effect_text(MATEUS))
	I18n.set_locale("en")
	await get_tree().process_frame
	_check((panel.get_node("Center/Panel/Margin/Body/Title") as Label).text
		== "Officers", "the panel returns to en cleanly")

	# No raw "<key>" or stray "{placeholder}" anywhere in the rendered panel.
	var unresolved: Array[String] = []
	_collect_unresolved(panel, unresolved)
	_check(unresolved.is_empty(),
		"no unresolved <key> text in the officers panel (%s)"
		% str(unresolved))

	# Esc / the Close button leave the panel; the modal registry is clean.
	panel.close()
	await get_tree().process_frame
	_check(not panel.is_open(), "close() hides the panel")
	_check(not panel.has_modal(), "no modal is left behind by close()")
	_check(not get_tree().get_nodes_in_group("modal_overlay").has(panel),
		"a closed panel leaves modal_overlay")

	panel.get_parent().queue_free()
	await get_tree().process_frame


## The two S4 entry points (§4.6.2): the `O` key and the footer row; plus the
## character panel's button, which opens the same S18 panel.
func _test_entry_points() -> void:
	await get_tree().process_frame
	_make_run([MATEUS])
	var tree := get_tree()
	tree.current_scene = null
	tree.change_scene_to_file("res://scenes/port/port_screen.tscn")
	await tree.process_frame
	await tree.process_frame
	var hub = tree.current_scene
	_check(hub != null and hub.scene_file_path == "res://scenes/port/port_screen.tscn",
		"the port hub is the active scene")
	if hub == null:
		return
	hub.route_to_world = false
	hub.route_to_facility = false

	var panel = hub.officers_panel()
	_check(panel != null, "the hub attaches the S18 panel (entry point 1)")
	var key := InputEventAction.new()
	key.action = "toggle_officers"
	key.pressed = true
	hub._unhandled_input(key)
	await tree.process_frame
	_check(panel.is_open(), "`O` opens the panel from S4 (§4.3)")
	panel._unhandled_input(key)
	await tree.process_frame
	_check(not panel.is_open(), "`O` closes it again")

	var row: Button = hub.officers_row()
	_check(row != null, "S4's footer has an Officers button (entry point 2)")
	if row != null:
		_check(row.text == I18n.t_key("officers.title"),
			"the button is localised (%s)" % row.text)
		_check(row.get_parent().name == "Footer",
			"the button lives in the footer, beside Fleet (§4.6.2)")
		row.pressed.emit()
		await tree.process_frame
		_check(panel.is_open(), "the footer Officers button opens the panel")
		panel.close()

	# The character panel's button (entry point 3, §4.6.2).
	var char_panel = hub.get_node_or_null("CharacterPanel")
	_check(char_panel != null, "S4 attaches the S14 character panel")
	if char_panel != null:
		_check(char_panel.has_method("open_officers_panel"),
			"the character panel exposes open_officers_panel()")
		char_panel.open()
		await tree.process_frame
		var button: Button = char_panel.get_node_or_null(
			"Center/Panel/Margin/Body/Footer/Officers"
		)
		_check(button != null, "the character panel has an Officers button")
		if button != null:
			_check(button.text == I18n.t_key("officers.title"),
				"the button is localised (%s)" % button.text)
			button.pressed.emit()
			await tree.process_frame
			_check(panel.is_open(),
				"the character panel's button opens the S18 roster")
			_check(not char_panel.is_open(),
				"…and closes S14 so the two modals never stack")
			panel.close()
			char_panel.close()

	# Esc with the panel up closes it, never Set Sail.
	panel.open()
	await tree.process_frame
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	hub._unhandled_input(esc)
	await tree.process_frame
	_check(panel.is_open(),
		"Esc behind the officers panel does not reach the Set Sail edge")
	_check(GameState.current_port == "lisbon",
		"…and the fleet stays in port (%s)" % str(GameState.current_port))
	panel._unhandled_input(esc)
	await tree.process_frame
	_check(not panel.is_open(), "Esc closes the officers panel itself")

	if tree.current_scene != null:
		tree.current_scene.queue_free()
		tree.current_scene = null
	await tree.process_frame


# --- Harness ---------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	if description.is_empty():
		return
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


## Collects any text still shaped like "<a.b.c>" — the `I18n.t_key` missing-key
## marker (§6), which must never reach a player.
func _collect_unresolved(node: Node, found: Array[String]) -> void:
	if node is Label:
		var text := (node as Label).text
		if text.begins_with("<") and text.ends_with(">") and not found.has(text):
			found.append("%s: %s" % [node.get_path(), text])
	elif node is Button:
		var button_text := (node as Button).text
		if button_text.begins_with("<") and button_text.ends_with(">") \
				and not found.has(button_text):
			found.append("%s: %s" % [node.get_path(), button_text])
	for child in node.get_children():
		_collect_unresolved(child, found)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
