extends Node
## Phase-8 W6-B acceptance tests: the creation screen (S20), the S2 handoff
## and the retirement screen's Phase-8 RPG companion checks live in
## `test_retirement.gd` (docs/80-UI-UX.md §4.13; docs/50-* §4.1;
## docs/IMPLEMENT-Phase8.md §2.8).
##
##   godot --headless res://tools/test_creation.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const CreationLib := preload("res://scenes/title/creation_screen.gd")
const CreationScene := preload("res://scenes/title/creation_screen.tscn")
const NationalityScene := preload("res://scenes/title/nationality_select.tscn")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_model_constants()
	await _test_handoff()
	await _test_background_step()
	await _test_steppers_and_counters()
	await _test_spread_evenly()
	await _test_must_spend_all()
	await _test_extremes()
	await _test_preview()
	await _test_confirm_new_game()
	await _test_back_navigation()
	await _test_locales()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A fresh S20 opened through the §4.13 handoff carrier, before any input.
func _open_creation(nation_id: String) -> Control:
	CreationLib.pending_nation_id = nation_id
	var screen: Control = CreationScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	return screen


## Enters step ② (the free points) on a fresh screen.
func _open_points(nation_id: String, background_index: int = 0) -> Control:
	var screen: Control = await _open_creation(nation_id)
	var grid: GridContainer = screen.get_node("Layout/StepBackground")
	(grid.get_child(background_index) as Button).pressed.emit()
	screen.confirm_selection()
	await get_tree().process_frame
	return screen


func _ui(key: String, locale: String) -> String:
	return str((DataLoader.ui_strings.get(key, {}) as Dictionary).get(locale, ""))


# --- 1. The model constants behind the screen -------------------------------

func _test_model_constants() -> void:
	_check(CharacterLib.ATTR_ALLOC_TOTAL == 5, "attribute free points total is 5")
	_check(CharacterLib.SKILL_ALLOC_TOTAL == 3, "skill free points total is 3")
	_check(CharacterLib.ALLOC_ITEM_CAP == 3, "the single-item cap is +3")
	_check(CharacterLib.CREATION_ATTR_MAX == CharacterLib.BASE_ATTRIBUTE
		+ CharacterLib.NATION_BONUS_AMOUNT + CharacterLib.BACKGROUND_ATTR_BONUS
		+ CharacterLib.ALLOC_ITEM_CAP
		and CharacterLib.CREATION_ATTR_MAX == 21,
		"the attribute extreme is the closed form 10+5+3+3 = 21")
	_check(CharacterLib.CREATION_SKILL_MAX == CharacterLib.NATION_BONUS_AMOUNT
		+ CharacterLib.BACKGROUND_SKILL_BONUS + CharacterLib.ALLOC_ITEM_CAP
		and CharacterLib.CREATION_SKILL_MAX == 13,
		"the skill extreme is the closed form 0+5+5+3 = 13")
	var spread_skills: Array = SkillsLib.KEYS.slice(0, 3)
	var spread_ok := spread_skills.size() == 3 \
		and str(spread_skills[0]) == "seamanship" \
		and str(spread_skills[1]) == "navigation" \
		and str(spread_skills[2]) == "swordplay"
	_check(spread_ok,
		"spread evenly covers the first three skills (%s)" % str(spread_skills))


# --- 2. The S2 → S20 handoff (docs/80-* §4.2, §4.13) ------------------------

func _test_handoff() -> void:
	# The default confirm stores the nation and routes to the creation screen.
	var pick: Control = NationalityScene.instantiate()
	add_child(pick)
	await get_tree().process_frame
	pick._on_card_pressed("spain")
	var routed: Array = []
	pick.route_sink = func(path: String) -> void: routed.append(path)
	pick.confirm_selection()
	_check(routed.size() == 1
		and str(routed[0]).ends_with("creation_screen.tscn"),
		"the S2 confirm routes to S20 (%s)" % str(routed))
	_check(CreationLib.pending_nation_id == "spain",
		"the S2 confirm carries the nation to S20")
	pick.queue_free()
	await get_tree().process_frame

	# `route_after_confirm = false` keeps the legacy path (test_density's
	# contract): the run builds, nothing routes, the carrier is untouched.
	var pick2: Control = NationalityScene.instantiate()
	add_child(pick2)
	await get_tree().process_frame
	pick2._on_card_pressed("portugal")
	var routed2: Array = []
	pick2.route_sink = func(path: String) -> void: routed2.append(path)
	pick2.route_after_confirm = false
	pick2.confirm_selection()
	_check(routed2.is_empty(), "the false switch never routes")
	_check(GameState.day == 1, "the false switch still builds the run")
	_check(CreationLib.pending_nation_id == "spain",
		"the legacy path does not touch the handoff carrier")
	pick2.queue_free()
	await get_tree().process_frame

	# The S19 density dial is GameState run input: it survives the two screen
	# swaps (S2 → S20 → new_game) and reaches the fill untouched.
	GameState.npc_preset = "deserted"
	var screen: Control = await _open_points("portugal")
	screen.route_after_confirm = false
	screen._on_spread()
	screen.confirm_selection()
	_check(GameState.day == 1, "the S20 confirm starts the run")
	_check(GameState.npc_preset == "deserted",
		"the S19 preset survives the S2 → S20 handoff (80-* §4.6.3)")
	_check(GameState.npc_fleets.is_empty(),
		"the deserted preset filled zero fleets")
	screen.queue_free()
	await get_tree().process_frame
	GameState.npc_preset = "normal"


# --- 3. Step ① — the background cards (docs/50-* §4.1 step 1) ---------------

func _test_background_step() -> void:
	var screen: Control = await _open_creation("portugal")
	var grid: GridContainer = screen.get_node("Layout/StepBackground")
	_check(grid.get_child_count() == 6, "step ① shows exactly 6 background cards")
	var names_ok := true
	for index in DataLoader.backgrounds_list.size():
		var card: Control = grid.get_child(index)
		var label: Label = card.get_node("Content/BackgroundName")
		if label.text != I18n.t(DataLoader.backgrounds_list[index]["name"]):
			names_ok = false
	_check(names_ok, "every card renders its data name")
	# Data-driven bonus line on the first card (deckhand: +3/+5).
	var first: Button = grid.get_child(0)
	_check(first.button_pressed, "the first card starts selected")
	var bonus_text: String = (first.get_node("Content/Bonus") as Label).text
	_check(bonus_text.contains("+3") and bonus_text.contains("+5"),
		"the bonus line shows the +3 attribute / +5 skill grants (%s)" % bonus_text)
	_check(not (first.get_node("Content/Bio") as Label).text.is_empty(),
		"each card carries the data bio")
	_check(screen.get_node("Layout/Header/Title").text
		== I18n.t_key("creation.step.background"),
		"step ① title is creation.step.background")
	# Selecting a card and confirming advances to the free points.
	var second: Button = grid.get_child(1)
	second.pressed.emit()
	_check(screen._background_id == str(DataLoader.backgrounds_list[1]["id"]),
		"selecting a card picks its background (%s)" % screen._background_id)
	screen.confirm_selection()
	_check(screen._step == 2, "step ① confirm advances to the free points")
	_check(screen.get_node("Layout/Header/Title").text
		== I18n.t_key("creation.step.points"),
		"step ② title is creation.step.points")
	_check(not screen.get_node("Layout/StepBackground").visible
		and screen.get_node("Layout/StepPoints").visible,
		"the two steps swap visibility")
	screen.queue_free()
	await get_tree().process_frame


# --- 4. Step ② — steppers, caps and counters (docs/50-* §4.1 step 2) --------

func _test_steppers_and_counters() -> void:
	# portugal × deckhand (the default first card): constitution base 10+3,
	# seamanship/navigation base 5.
	var screen: Control = await _open_points("portugal")
	var points: Control = screen.get_node("Layout/StepPoints")
	var attr_header: Label = points.get_node("Columns/Attributes/AttrHeader")
	_check(attr_header.text == I18n.fmt("creation.points.attributes", {"count": 5}),
		"the attribute counter starts at 5 left (%s)" % attr_header.text)
	var skill_header: Label = points.get_node("Columns/Skills/SkillHeader")
	_check(skill_header.text == I18n.fmt("creation.points.skills", {"count": 3}),
		"the skill counter starts at 3 left")
	var con_row: Control = points.get_node("Columns/Attributes/Row_constitution")
	_check((con_row.get_node("StatValue") as Label).text == "13",
		"the stepper shows base + bonuses before spending (10+3)")
	var add: Button = con_row.get_node("Add")
	for _i in 4:
		add.pressed.emit()
	_check(int(screen._attr_alloc.get("constitution", 0)) == 3,
		"the per-item cap stops the + at 3 (got %d)"
		% int(screen._attr_alloc.get("constitution", 0)))
	_check(add.disabled, "the + button disables at the per-item cap")
	_check((con_row.get_node("StatValue") as Label).text == "16",
		"the value label tracks 13 + 3")
	_check(attr_header.text == I18n.fmt("creation.points.attributes", {"count": 2}),
		"the counter tracks the remaining 2 points")
	(con_row.get_node("Sub") as Button).pressed.emit()
	_check(int(screen._attr_alloc.get("constitution", 0)) == 2,
		"the − unwinds one point")
	# A skill row: navigation base 5 (nation), + one spend.
	var nav_row: Control = points.get_node("Columns/Skills/Row_navigation")
	_check((nav_row.get_node("StatValue") as Label).text == "5",
		"the skill stepper shows base + bonuses (nation +5)")
	(nav_row.get_node("Add") as Button).pressed.emit()
	_check((nav_row.get_node("StatValue") as Label).text == "6",
		"the skill value label tracks base + alloc")
	_check(skill_header.text == I18n.fmt("creation.points.skills", {"count": 2}),
		"the skill counter tracks its own budget")
	# Spend the attribute budget out (constitution holds 2, intellect takes
	# the remaining 3): the + disables everywhere once the budget is gone.
	var int_add: Button = points.get_node("Columns/Attributes/Row_intellect/Add")
	for _i in 3:
		int_add.pressed.emit()
	_check(attr_header.text == I18n.fmt("creation.points.attributes", {"count": 0}),
		"the counter reaches 0")
	_check(add.disabled, "an exhausted budget disables the spent row's +")
	_check(not (points.get_node("Columns/Skills/Row_seamanship/Add") as Button).disabled,
		"the skill budget is independent of the attribute budget")
	screen.queue_free()
	await get_tree().process_frame


# --- 5. Spread evenly (docs/50-* §4.1 step ②) -------------------------------

func _test_spread_evenly() -> void:
	var screen: Control = await _open_points("spain")
	screen._on_spread()
	_check(screen._attr_alloc == {
			"constitution": 1, "intellect": 1, "charisma": 1,
			"courage": 1, "luck": 1},
		"spread spends +1 on each of the five attributes (%s)"
		% str(screen._attr_alloc))
	_check(screen._skill_alloc == {
			"seamanship": 1, "navigation": 1, "swordplay": 1},
		"spread spends +1 on the first three skills (%s)"
		% str(screen._skill_alloc))
	_check(screen._remaining_attr() == 0 and screen._remaining_skill() == 0,
		"spread spends exactly the +5/+3 budget")
	_check(not (screen.get_node("Layout/Footer/Confirm") as Button).disabled,
		"spend-all arms the confirm")
	screen.queue_free()
	await get_tree().process_frame


# --- 6. Must-spend-all gating (docs/80-* §4.13) -----------------------------

func _test_must_spend_all() -> void:
	var screen: Control = await _open_points("holland")
	var confirm: Button = screen.get_node("Layout/Footer/Confirm")
	_check(confirm.disabled, "confirm is disabled while points remain")
	_check((screen.get_node("Layout/StepPoints/SpreadRow/SpendHint") as Label).text
		== I18n.t_key("creation.points.must_spend"),
		"the must-spend hint shows while points remain")
	(screen.get_node("Layout/StepPoints/Columns/Attributes/Row_luck/Add")
		as Button).pressed.emit()
	_check(confirm.disabled, "a partial spend keeps confirm disabled")
	screen._on_spread()
	_check(not confirm.disabled, "spend-all arms the confirm")
	(screen.get_node("Layout/StepPoints/Columns/Attributes/Row_luck/Sub")
		as Button).pressed.emit()
	_check(confirm.disabled, "un-spending a point re-locks the confirm")
	_check(not (screen.get_node("Layout/StepPoints/SpreadRow/SpendHint")
		as Label).text.is_empty(), "the hint returns with the un-spent point")
	screen.queue_free()
	await get_tree().process_frame


# --- 7. The creation extremes 21 / 13 (docs/50-* §4.1 step 4, normative) ----

func _test_extremes() -> void:
	# (a) `starting_person` clamps any over-cap draft to the closed forms.
	var person: Dictionary = CharacterLib.starting_person(
		"spain", "background_navy_cadet", {"courage": 99}, {"swordplay": 99})
	_check(int(person["attributes"]["courage"]) == 21,
		"starting_person clamps courage to 10+5+3+3 = 21 (got %d)"
		% int(person["attributes"]["courage"]))
	_check(int(person["skills"]["swordplay"]) == 8,
		"the over-cap skill draft trims to the per-item +3 (5+3 = 8, got %d)"
		% int(person["skills"]["swordplay"]))
	var person2: Dictionary = CharacterLib.starting_person(
		"portugal", "background_navy_cadet", {}, {"navigation": 99})
	_check(int(person2["skills"]["navigation"]) == 13,
		"starting_person clamps navigation to 0+5+5+3 = 13 (got %d)"
		% int(person2["skills"]["navigation"]))
	# (b) The steppers cannot exceed the extremes: spain × navy_cadet puts
	# base+bonuses 18 on courage; three + clicks are the ceiling.
	var screen: Control = await _open_points("spain", 1)
	var cou_row: Control = screen.get_node("Layout/StepPoints/Columns/Attributes/Row_courage")
	_check((cou_row.get_node("StatValue") as Label).text == "18",
		"the extreme base shows 10+5+3 = 18")
	for _i in 6:
		(cou_row.get_node("Add") as Button).pressed.emit()
	_check((cou_row.get_node("StatValue") as Label).text == "21",
		"the stepper tops out at the normative extreme 21")
	var screen2: Control = await _open_points("portugal", 1)
	var nav_row: Control = screen2.get_node("Layout/StepPoints/Columns/Skills/Row_navigation")
	for _i in 6:
		(nav_row.get_node("Add") as Button).pressed.emit()
	_check((nav_row.get_node("StatValue") as Label).text == "13",
		"the skill stepper tops out at the normative extreme 13 (10+3)")
	# (c) Mashing every + on the screen can never break a cap or a budget.
	for add_button in screen2.get_node("Layout/StepPoints/Columns") \
			.find_children("Add", "Button", true, false):
		for _i in 6:
			(add_button as Button).pressed.emit()
	_check(CharacterLib.attr_alloc_total(screen2._attr_alloc) <= 5
		and CharacterLib.skill_alloc_total(screen2._skill_alloc) <= 3,
		"mashing every stepper respects both budgets (attr %d, skill %d)"
		% [CharacterLib.attr_alloc_total(screen2._attr_alloc),
		CharacterLib.skill_alloc_total(screen2._skill_alloc)])
	var caps_ok := true
	for key in screen2._attr_alloc:
		if int(screen2._attr_alloc[key]) > 3:
			caps_ok = false
	for key in screen2._skill_alloc:
		if int(screen2._skill_alloc[key]) > 3:
			caps_ok = false
	_check(caps_ok, "no single item ever exceeds the +3 cap")
	screen.queue_free()
	screen2.queue_free()
	await get_tree().process_frame


# --- 8. The live derived preview (docs/80-* §4.13: same-source formulas) ----

func _test_preview() -> void:
	# portugal × navy_cadet: base nav 10, seamanship 0, courage 13.
	var screen: Control = await _open_points("portugal", 1)
	var values: Dictionary = screen.preview_values()
	_check(int(values["sighting_base"]) == 48,
		"base sighting is the closed form 48 + floor(10/12)")
	_check(int(values["sighting_value"]) == 48,
		"with nothing spent the value equals the base")
	_check(is_equal_approx(float(values["speed_base"]), 0.0),
		"base speed bonus is 0/300")
	_check(int(values["duel_base"]) == 0,
		"base duel is swordplay 0 + floor(13/20)")
	# Navigation +2 (of the 3-point skill budget): 12 → 48 + floor(12/12) = 49.
	for _i in 2:
		(screen.get_node("Layout/StepPoints/Columns/Skills/Row_navigation/Add")
			as Button).pressed.emit()
	values = screen.preview_values()
	_check(int(values["sighting_value"]) == 49
		and int(values["sighting_base"]) == 48,
		"nav 12 → sighting 49 against the unchanged base (48 → 49)")
	# The last skill point on seamanship: the closed form 1/300; the line
	# renders the percent pair.
	var seam_add: Button = screen.get_node("Layout/StepPoints/Columns/Skills/Row_seamanship/Add")
	seam_add.pressed.emit()
	values = screen.preview_values()
	_check(is_equal_approx(float(values["speed_value"]), 1.0 / 300.0),
		"the speed value is the closed form seamanship/300")
	var speed_label: Label = screen.get_node("Layout/StepPoints/Preview/Preview_speed")
	_check(speed_label.text.contains("0.0% → 0.3%"),
		"the speed line shows base → value in percent (%s)" % speed_label.text)
	var sighting_label: Label = screen.get_node("Layout/StepPoints/Preview/Preview_sighting")
	_check(sighting_label.text == "%s %s" % [
			I18n.t_key("creation.preview.sighting"),
			I18n.fmt("creation.preview.base_value", {"base": "48", "value": "49"})],
		"the sighting line is the keyed base → value pair (%s)" % sighting_label.text)
	screen.queue_free()
	await get_tree().process_frame
	# The duel courage term: spain × navy_cadet — spain's signature swordplay
	# +5 puts the base at 5 + floor(18/20); three courage points reach 21.
	var screen2: Control = await _open_points("spain", 1)
	var cou_add: Button = screen2.get_node("Layout/StepPoints/Columns/Attributes/Row_courage/Add")
	for _i in 3:
		cou_add.pressed.emit()
	var values2: Dictionary = screen2.preview_values()
	_check(int(values2["duel_base"]) == 5,
		"the base draft duels at swordplay 5 + floor(18/20) = 5")
	_check(int(values2["duel_value"]) == 6,
		"courage 21 → duel 5 + floor(21/20) = 6")
	screen2.queue_free()
	await get_tree().process_frame


# --- 9. Confirm → new_game (docs/50-* §4.1 step 5) --------------------------

func _test_confirm_new_game() -> void:
	var screen: Control = await _open_points("portugal", 1)
	screen.route_after_confirm = false
	# A deliberate draft: navigation +3 (the skill extreme), courage +2,
	# constitution +3 — exactly the +5 attribute budget spent.
	for _i in 3:
		(screen.get_node("Layout/StepPoints/Columns/Skills/Row_navigation/Add")
			as Button).pressed.emit()
	for _i in 2:
		(screen.get_node("Layout/StepPoints/Columns/Attributes/Row_courage/Add")
			as Button).pressed.emit()
	for _i in 3:
		(screen.get_node("Layout/StepPoints/Columns/Attributes/Row_constitution/Add")
			as Button).pressed.emit()
	_check(not (screen.get_node("Layout/Footer/Confirm") as Button).disabled,
		"the fully-spent draft arms the confirm")
	var preview: Dictionary = screen.preview_values()
	screen.confirm_selection()
	_check(GameState.day == 1 and GameState.gold == 5000,
		"the confirm starts the Portugal run")
	_check(str(GameState.player["nation_id"]) == "portugal"
		and str(GameState.player["background_id"]) == "background_navy_cadet",
		"nation and background land in the player block")
	var attributes: Dictionary = GameState.player["attributes"]
	_check(int(attributes["constitution"]) == 13
		and int(attributes["intellect"]) == 15
		and int(attributes["charisma"]) == 10
		and int(attributes["courage"]) == 15
		and int(attributes["luck"]) == 10,
		"attributes = base + nation + background + alloc (%s)" % str(attributes))
	var skills: Dictionary = GameState.player["skills"]
	_check(int(skills["navigation"]) == 13,
		"navigation lands at the creation extreme 13")
	var others_ok := true
	for key in SkillsLib.KEYS:
		if key != "navigation" and int(skills[key]) != 0:
			others_ok = false
	_check(others_ok, "un-spent skills start at 0")
	_check(int(GameState.player["alloc_pending"]) == 0,
		"alloc_pending starts at 0")
	# Same-source proof: the stored block derives exactly what the preview
	# showed (no officer contribution exists yet).
	_check(CharacterLib.sighting_radius() == int(preview["sighting_value"]),
		"the stored block derives the previewed sighting radius (%d)"
		% CharacterLib.sighting_radius())
	_check(is_equal_approx(
			CharacterLib.speed_bonus(), float(preview["speed_value"])),
		"the stored block derives the previewed speed bonus")
	_check(BattleSimLib.player_duel_base() == int(preview["duel_value"]),
		"the stored block derives the previewed duel value")
	screen.queue_free()
	await get_tree().process_frame


# --- 10. Back navigation (docs/80-* §4.2: S20's back edge is S2) ------------

func _test_back_navigation() -> void:
	var screen: Control = await _open_points("italy")
	var routed: Array = []
	screen.route_sink = func(path: String) -> void: routed.append(path)
	(screen.get_node("Layout/Footer/Back") as Button).pressed.emit()
	_check(routed.size() == 1
		and str(routed[0]).ends_with("nationality_select.tscn"),
		"the S20 back control routes to S2 (%s)" % str(routed))
	screen.queue_free()
	await get_tree().process_frame


# --- 11. Both locales, no raw keys (docs/80-* §4.4) -------------------------

func _test_locales() -> void:
	var screen: Control = await _open_points("portugal", 1)
	var leaked: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		var title: Label = screen.get_node("Layout/Header/Title")
		_check(title.text == _ui("creation.step.points", locale),
			"the %s step title is the ui_strings value (%s)"
			% [locale, title.text])
		for line in screen.lines():
			if str(line).contains("<"):
				leaked.append("%s: %s" % [locale, str(line)])
	_check(leaked.is_empty(),
		"S20 prints no raw <key> in either locale (%s)"
		% str(leaked.slice(0, 3)))
	I18n.set_locale("en")
	screen.queue_free()
	await get_tree().process_frame


# --- Report -----------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


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
