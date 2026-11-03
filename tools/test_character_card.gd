extends Node
## W6-A acceptance suite (docs/80-UI-UX.md §4.12 the unified card, §4.12.3 the
## S14 three-tab rework, §4.11.3 the dossier; docs/50-* §4.4/§4.5).
##
##   godot --headless res://tools/test_character_card.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CardLib := preload("res://scenes/ui/character_card.gd")
const CardScene := preload("res://scenes/ui/character_card.tscn")
const DossierLib := preload("res://scenes/ui/dossier_panel.gd")
const OfficersPanelLib := preload("res://scenes/port/officers_panel.gd")
const PickerScene := preload("res://scenes/world/fleet_picker.tscn")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const HudScene := preload("res://scenes/ui_shared/hud.tscn")

## Fixed fixtures: the retained navigator (main skill navigation 58) and a
## canon legend captain with a home port (dossier tier-2 read).
const MATEUS := "off_mateus_alvares"
const CAPTAIN := "cap_leg_trader_05"

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_card_data_per_kind()
	_test_card_sections_per_kind()
	_test_identify_is_full_reveal()
	_test_player_split_math()
	_test_allocation_flow()
	_test_officer_actions_and_posts()
	_test_captain_seat_rows()
	_test_three_entry_card_identity()
	_test_dossier_tiers()
	_test_s14_tabs()
	_test_hud_badge()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A Portugal run docked at Lisbon: the v9 player block with navigation 5
## (the nation's signature +5 over the base 0) and `alloc_pending` points.
func _make_run(alloc_pending: int = 0, gold: int = 10000) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 5, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"alloc_pending": alloc_pending,
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	GameState.officer_states = {}
	GameState.captain_states = {}
	GameState.gold = gold
	GameState.day = 12
	GameState.morale = 70
	GameState.fleet = [FleetLib.new_ship("caravel", 15)]
	GameState.current_port = "lisbon"
	GameState.npc_fleets = []
	GameState.known_ports = ["lisbon"]
	GameState.world = {"position": {"x": 7, "y": 57}, "clock_fraction": 0.5,
		"explored": {}}
	GameState.locale = "en"


func _make_fleet(captain_id: String, cell := Vector2i(9, 57)) -> Dictionary:
	return {
		"id": "fx_%s" % captain_id,
		"role": "trader", "nation_id": "england",
		"cell": {"x": cell.x, "y": cell.y},
		"route": {"lanes": ["atlantic_north"], "leg": 0, "tile_index": 0,
			"legs": []},
		"cargo": {},
		"captain_id": captain_id,
		"cooldown_until_day": 0, "seed": 424242, "dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
		"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
	}


## Detaches a node from the tree so its EventBus connections drop.
func _drop(node: Node) -> void:
	if node != null and is_instance_valid(node):
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.free()


func _mount_card(kind: String, person_id: String,
		options: Dictionary = {}) -> Control:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var card: Control = CardScene.instantiate()
	host.add_child(card)
	card.setup_person(kind, CardLib.card_data(kind, person_id, options))
	card.set_meta("host", host)
	return card


func _unmount_card(card: Control) -> void:
	if card == null or not is_instance_valid(card):
		return
	var host: Node = card.get_meta("host")
	_drop(card)
	_drop(host)


# --- 1. The data contract per kind -------------------------------------------

func _test_card_data_per_kind() -> void:
	_make_run()
	var player := CardLib.card_data(CardLib.KIND_PLAYER, "")
	_check(str(player["kind"]) == "player", "the player contract is kinded")
	_check((player["attributes"] as Dictionary).size() == 5,
		"the player contract carries the five attributes")
	_check((player["skill_keys"] as Array).size() == 11,
		"the player renders 11 skill rows: 8 player + 3 grayed officer skills")
	_check((player["grayed_skill_keys"] as Array).size() == 3,
		"the player's 3 officer-only skills render grayed-labelled (§4.12.1)")
	_check(int(player["level"]) == 1 and int(player["xp"]) == 0,
		"level/XP derive from the block (1 / 0)")
	_check((player["effective"] as Array).size() == 8,
		"the effective split carries one row per player skill")

	var officer := CardLib.card_data(CardLib.KIND_OFFICER, MATEUS)
	_check(str(officer["main_skill"]) == "navigation",
		"the officer contract names the native role (main_skill)")
	_check((officer["skill_keys"] as Array).size() == 11,
		"the officer renders all 11 skills")
	_check(int(officer["loyalty"]) == SkillsLib.LOYALTY_START,
		"an un-employed read still carries the start loyalty 50")

	var npc := CardLib.card_data(CardLib.KIND_NPC, CAPTAIN)
	_check(str(npc["role_id"]) == "trader" and int(npc["tier"]) >= 1,
		"the NPC contract carries role + canon tier")
	_check((npc["skill_keys"] as Array).size() == 8,
		"the NPC renders the 8 skills")
	_check(int(npc["stance"]) == 0 and int(npc["familiarity"]) == 0,
		"an unmet captain reads the §4.15 defaults (nothing created)")
	_check(GameState.captain_states.is_empty(),
		"a card-data read creates no captain_states entry (the W4-A rule)")
	# Deterministic portrait: the same tags always paint the same block.
	var again := CardLib.card_data(CardLib.KIND_NPC, CAPTAIN)
	_check(again == npc, "card_data is a pure function (byte-identical repeat)")
	var other := CardLib.card_data(CardLib.KIND_NPC, "cap_trader_0001")
	_check(other.is_empty() == false and other != npc,
		"a different captain renders different data")


# --- 2. The locked layout renders per kind -----------------------------------

func _test_card_sections_per_kind() -> void:
	_make_run(4)
	var player := _mount_card(CardLib.KIND_PLAYER, "", {"alloc": true})
	_check(player.section("Identity/Names/Name") != null,
		"the identity row renders the name")
	_check(player.section("Identity/Flag") != null,
		"the flag block renders the nation color")
	_check(player.section("Identity/Portrait") != null,
		"the portrait is a color block (placeholder art, §4.8)")
	_check(player.section("Attributes/Attr_constitution") != null
		and player.section("Attributes/Attr_luck") != null,
		"the five attribute bars render (values 1–100)")
	_check(player.section("Skills/Skill_navigation") != null
		and player.section("Skills/Skill_medicine") != null,
		"the skill bars render incl. the grayed officer skills")
	_check(player.section("Relations") != null
		and player.section("Career/Xp") != null,
		"the relation and career blocks render")
	_check(player.section("Effective/Eff_navigation") != null,
		"the player card renders the effective-values split (§4.12.1)")
	_check(player.section("Allocation") != null
		and player.section("Allocation/Buttons/Confirm") != null,
		"the allocation footer renders with alloc data set (§4.12.2)")
	_check(player.section("Attributes/Attr_constitution/Plus") != null,
		"the per-attribute + stepper renders (enabled iff pending > 0)")
	var skill_plus: Node = player.section("Skills/Skill_navigation/Plus")
	_check(skill_plus == null, "skills never allocate (§4.12.2)")
	_unmount_card(player)

	_make_run()
	var officer := _mount_card(CardLib.KIND_OFFICER, MATEUS)
	_check(officer.section("Skills").get_child_count() == 11,
		"the officer card shows all 11 skill bars")
	_check(officer.section("Tags/Personality") != null,
		"the officer card renders the personality tags")
	_check(officer.section("Tags/Appearance") != null,
		"the appearance sentence assembles from the part keys (§4.15)")
	_check(officer.section("Relations/Loyalty") != null,
		"the officer relation block renders loyalty")
	var role_text: String = officer.section("Identity/Names/Role").text
	_check(role_text.contains(I18n.t_key("skill.navigation")),
		"the officer header names the native role (main_skill)")
	_check(officer.section("Allocation") == null,
		"no allocation block on a non-player card")
	_unmount_card(officer)

	var npc := _mount_card(CardLib.KIND_NPC, CAPTAIN)
	_check(npc.section("Skills").get_child_count() == 8,
		"the NPC card shows the 8 skills")
	_check(npc.section("Identity/TierBadge") != null,
		"the tier badge renders on the NPC card")
	_check(npc.section("Relations/Stance") != null,
		"the NPC relation block renders stance + familiarity")
	_check(npc.section("Career/Record") != null,
		"the NPC career block renders wins/defeats")
	_check(npc.section("Allocation") == null
		and npc.section("Effective") == null,
		"no player-only blocks on the NPC card")
	_unmount_card(npc)


# --- 3. Identify = full reveal (§4.12.1, locked) -----------------------------

func _test_identify_is_full_reveal() -> void:
	_make_run()
	CaptainsLib.ensure(CAPTAIN)
	# An UNMET-tier captain (familiarity 0): every card number renders anyway.
	var npc := _mount_card(CardLib.KIND_NPC, CAPTAIN)
	var skills_box: Container = npc.section("Skills")
	for child in skills_box.get_children():
		var value: String = (child.get_node("Value") as Label).text
		_check(not value.begins_with("<") and not value.contains("??"),
			"the %s value renders ungated (%s)" % [child.name, value])
	_check(npc.section("Relations/Stance") != null,
		"the stance line renders at familiarity 0 (card numbers never gated)")
	var raw: Dictionary = npc.rendered_data()
	_check(int(raw["familiarity"]) == 0,
		"the rendered data carries the live familiarity (0)")
	_unmount_card(npc)


# --- 4. The effective-values split (§4.5.3 + §4.12.1) -----------------------

func _test_player_split_math() -> void:
	_make_run()
	CharacterLib.recruit(MATEUS)
	_check(SkillsLib.appoint(MATEUS, "pilot"), "Mateus takes the pilot post")
	var player := _mount_card(CardLib.KIND_PLAYER, "")
	var rows: Array = player.rendered_data()["effective"]
	var navigation := {}
	for row in rows:
		if str(row["key"]) == "navigation":
			navigation = row
	_check(int(navigation["base"]) == 5,
		"the navigation base is the stored 5 (nation signature included)")
	_check(int(navigation["officer_add"]) == 30,
		"the in-post pilot contributes his true 30 (loyalty 50: no derate)")
	_check(int(navigation["total"]) == 35 and int(navigation["without"]) == 5,
		"total 35 = base 5 + 30; without-this-officer reads 5 (§4.12.1)")
	_check(bool(navigation["native"]),
		"the native +5 tag sits on Portugal's signature skill")
	_check(str(navigation["holder"]).contains(
		I18n.t(DataLoader.get_officer(MATEUS)["name"])),
		"the contribution row names the in-post officer")
	var seamanship := {}
	for row in rows:
		if str(row["key"]) == "seamanship":
			seamanship = row
	_check(int(seamanship["officer_add"]) == 0
		and int(seamanship["total"]) == int(seamanship["base"]),
		"an empty post contributes nothing (no stacking, §4.5.3)")
	# The loyalty derate and the signature bonus flow through the same read.
	GameState.officer_states[MATEUS]["loyalty"] = 20
	var derated := CardLib.card_data(CardLib.KIND_PLAYER, "")
	for row in derated["effective"]:
		if str(row["key"]) == "navigation":
			_check(int(row["officer_add"]) == int(floor(30 * 0.8)),
				"loyalty < 30 derates the contribution ×0.8 (§4.5.3)")
	GameState.officer_states[MATEUS]["loyalty"] = 80
	var signature := CardLib.card_data(CardLib.KIND_PLAYER, "")
	for row in signature["effective"]:
		if str(row["key"]) == "navigation":
			_check(int(row["officer_add"]) == 30 + 5,
				"loyalty ≥ 80 adds the native +5 (§4.5.4)")
	_unmount_card(player)


# --- 5. The allocation flow (§4.12.2, locked) --------------------------------

func _test_allocation_flow() -> void:
	_make_run(4)
	var player := _mount_card(CardLib.KIND_PLAYER, "", {"alloc": true})
	var luck_plus: Button = player.section("Attributes/Attr_luck/Plus")
	var con_plus: Button = player.section("Attributes/Attr_constitution/Plus")
	_check(not luck_plus.disabled, "steppers enable iff alloc_pending > 0")
	luck_plus.pressed.emit()
	luck_plus.pressed.emit()
	_check(player.alloc_draft() == {"luck": 2},
		"the local draft gains one point per press (%s)"
		% str(player.alloc_draft()))
	var luck_value: Label = player.section("Attributes/Attr_luck/Value")
	_check(luck_value.text == "12 +2",
		"the row shows the drafted value with its delta (%s)" % luck_value.text)
	# Cancel rolls the draft back; live state untouched.
	var cancel: Button = player.section("Allocation/Buttons/Cancel")
	cancel.pressed.emit()
	_check(player.alloc_draft().is_empty(), "cancel clears the draft")
	_check(int(GameState.player["attributes"]["luck"]) == 10,
		"cancel wrote nothing to the block (the rollback, §4.12.2)")
	# Confirm spends through Character.allocate — no second confirm.
	luck_plus.pressed.emit()
	var confirm: Button = player.section("Allocation/Buttons/Confirm")
	confirm.pressed.emit()
	_check(int(GameState.player["attributes"]["luck"]) == 11,
		"confirm raises the attribute by the drafted point")
	_check(int(GameState.player["alloc_pending"]) == 3,
		"the spent point left alloc_pending (4 → 3)")
	_check(player.alloc_draft().is_empty(),
		"a committed draft is cleared (the card re-renders)")
	# The 100 clamp: the stepper disables at the cap with the clamp message.
	GameState.player["alloc_pending"] = 2
	GameState.player["attributes"]["constitution"] = 100
	player.setup_person(CardLib.KIND_PLAYER, CardLib.card_data(
		CardLib.KIND_PLAYER, "", {"alloc": true}))
	var con_plus2: Button = player.section("Attributes/Attr_constitution/Plus")
	_check(con_plus2.disabled,
		"an attribute at 100 disables its stepper (the clamp)")
	_check(con_plus2.tooltip_text == I18n.t_key("creation.cap_reached"),
		"the clamp message sits on the disabled stepper")
	_check(not CharacterLib.allocate({"constitution": 1}),
		"the model refuses a draft that would pass 100 (§4.4)")
	# Pending 0 disables every stepper.
	GameState.player["alloc_pending"] = 0
	player.setup_person(CardLib.KIND_PLAYER, CardLib.card_data(
		CardLib.KIND_PLAYER, "", {"alloc": true}))
	var luck_plus2: Button = player.section("Attributes/Attr_luck/Plus")
	_check(luck_plus2.disabled, "pending 0 disables the steppers (deferrable)")
	_unmount_card(player)


# --- 6. The officer rows + the four actions + the post table -----------------

func _test_officer_actions_and_posts() -> void:
	_make_run(0, 10000)
	CharacterLib.recruit(MATEUS)
	var panel: Control = OfficersPanelLib.attach_to(self, self)
	panel.open()
	_check(panel.is_open() and panel.officer_ids() == [MATEUS],
		"S18 lists the employed officer")
	var card: Control = panel.row_widget(MATEUS)["card"]
	_check(card != null and (card.rendered_data() as Dictionary).has("skills"),
		"the officer row renders the §4.12 card (compact)")
	# Talk: +1 loyalty, then the cooldown grays the row's button.
	var actions: Dictionary = panel.action_buttons(MATEUS)
	_check(actions.has("talk") and actions.has("gift")
		and actions.has("train") and actions.has("appoint"),
		"the row carries the four actions (§4.12.3)")
	(actions["talk"] as Button).pressed.emit()
	_check(SkillsLib.loyalty(MATEUS) == 51, "talk grants loyalty +1 (§4.5.4)")
	var talk: Button = panel.action_buttons(MATEUS)["talk"]
	_check(talk.disabled
		and talk.tooltip_text.contains(str(SkillsLib.COOLDOWN_DAYS)),
		"the 10-day cooldown grays talk with its reason")
	# Gift: 200g, keyed by personality — Mateus is patient: the base +5 line.
	# Talk and gift each carry their OWN 10-day cooldown (§4.5.4).
	var gift: Button = panel.action_buttons(MATEUS)["gift"]
	_check(not gift.disabled, "gift has its own cooldown (talk's is separate)")
	gift.pressed.emit()
	_check(SkillsLib.loyalty(MATEUS) == 51 + 5,
		"gift pays 200g for the base loyalty +5 (§4.5.4)")
	_check(GameState.gold == 10000 - 300 - 200,
		"the gift cost 200g left the purse")
	# Train: the §4.3.4 fee formula against the native main skill, cap 60.
	var train: Button = panel.action_buttons(MATEUS)["train"]
	_check(not train.disabled, "train is enabled below the cap 60")
	_check(panel._train_blocked_reason(MATEUS).is_empty(),
		"no block reason under the cap with gold")
	var fee := SkillsLib.training_price("navigation")
	(train as Button).pressed.emit()
	_check(int(DataLoader.get_officer(MATEUS)["skills"]["navigation"]) == 31,
		"train lands +1 on the officer card (canon-with-growth)")
	_check(GameState.gold == 10000 - 300 - 200 - fee,
		"train charged the §4.3.4 fee from player gold (%dg)" % fee)
	# Appoint: the post table carries the 6 flagship seats + prereq reasons.
	var appoint: Button = panel.action_buttons(MATEUS)["appoint"]
	appoint.pressed.emit()
	var dialog: Control = panel.appoint_dialog()
	_check(dialog != null and dialog.is_open(), "appoint opens the post table")
	var rows: Array = dialog.rows()
	_check(rows.size() == 6,
		"one row per flagship post (no escort seats on a one-ship fleet) "
		+ "(%d rows)" % rows.size())
	# Mateus's carpentry is 0: the carpenter seat grays with its threshold.
	var carpenter: Dictionary = {}
	for row in rows:
		if str(row["post_id"]) == "carpenter":
			carpenter = row
	_check((carpenter["button"] as Button).disabled,
		"a prereq-failing seat renders grayed (§4.12.3)")
	_check(str(carpenter["reason"]).contains("20"),
		"the grayed row carries its gate.requires threshold (%s)"
		% str(carpenter["reason"]))
	var pilot: Dictionary = {}
	for row in rows:
		if str(row["post_id"]) == "pilot":
			pilot = row
	_check(not (pilot["button"] as Button).disabled
		and str(pilot["reason"]).is_empty(),
		"an appointable row carries no reason (Mateus passes navigation ≥ 20)")
	panel.close()
	_check(not panel.is_open(), "the panel closes")
	_drop(panel)


# --- 6b. The captain seat: ship rows, prereq, occupancy (§4.5.2) -------------

func _test_captain_seat_rows() -> void:
	_make_run(0, 100000)
	CharacterLib.recruit(MATEUS)
	GameState.fleet.append(FleetLib.new_ship("caravel", 15))
	var panel: Control = OfficersPanelLib.attach_to(self, self)
	panel.open()
	# Mateus (seamanship 18) fails the captain prereq: the seat grays with it.
	var appoint: Button = panel.action_buttons(MATEUS)["appoint"]
	appoint.pressed.emit()
	var rows: Array = panel.appoint_dialog().rows()
	var seat: Dictionary = {}
	for row in rows:
		if str(row["post_id"]) == "captain":
			seat = row
	_check(not seat.is_empty() and str(seat["ship_id"]) == "caravel",
		"the captain seat carries a ship picker row per escort (§4.12.3)")
	_check((seat["button"] as Button).disabled
		and str(seat["reason"]).contains("25"),
		"the failing captain seat grays with its seamanship ≥ 25 reason")
	panel.close()
	_drop(panel)

	# An eligible officer takes the seat; the next dialog shows the occupancy.
	var eligible := ""
	for officer in DataLoader.officers_list:
		var skills: Dictionary = officer.get("skills", {})
		var attributes: Dictionary = officer.get("attributes", {})
		if int(skills.get("seamanship", 0)) >= 25 \
				and int(attributes.get("courage", 0)) >= 30 \
				and str(officer["id"]) != MATEUS:
			eligible = str(officer["id"])
			break
	_check(not eligible.is_empty(), "an eligible captain candidate exists")
	if eligible.is_empty():
		return
	CharacterLib.recruit(eligible)
	_check(SkillsLib.appoint(eligible, "captain", "caravel"),
		"the eligible officer takes the captain seat of the escort")
	# A second eligible candidate: the model refuses the occupied seat, and
	# the dialog grays it with the holder's name (§4.5.2 one captain per ship).
	var eligible2 := ""
	for officer in DataLoader.officers_list:
		var skills: Dictionary = officer.get("skills", {})
		var attributes: Dictionary = officer.get("attributes", {})
		if int(skills.get("seamanship", 0)) >= 25 \
				and int(attributes.get("courage", 0)) >= 30 \
				and str(officer["id"]) != MATEUS \
				and str(officer["id"]) != eligible:
			eligible2 = str(officer["id"])
			break
	_check(not eligible2.is_empty(), "a second captain candidate exists")
	_check(not SkillsLib.appoint(eligible2, "captain", "caravel"),
		"the model refuses a second captain on the same ship (§4.5.2)")
	CharacterLib.recruit(eligible2)
	panel = OfficersPanelLib.attach_to(self, self)
	panel.open()
	appoint = panel.action_buttons(eligible2)["appoint"]
	appoint.pressed.emit()
	rows = panel.appoint_dialog().rows()
	for row in rows:
		if str(row["post_id"]) == "captain" \
				and str(row["ship_id"]) == "caravel":
			_check(str(row["reason"]).contains(
				I18n.t(DataLoader.get_officer(eligible)["name"])),
				"an occupied seat names its holder (%s)" % str(row["reason"]))
	panel.close()
	_drop(panel)


# --- 7. The three-entry card-identity pin (§4.12 acceptance) -----------------

## The card data without the render flags (`compact`/`alloc` are presentation,
## not content): the identity pin compares what the card SAYS.
func _data_only(data: Dictionary) -> Dictionary:
	var out := data.duplicate(true)
	out.erase("compact")
	out.erase("alloc")
	return out


func _test_three_entry_card_identity() -> void:
	# NPC captain: the picker's inspect card vs the dossier's card.
	_make_run()
	var fleet := _make_fleet(CAPTAIN)
	var picker: Control = PickerScene.instantiate()
	add_child(picker)
	picker.open_fleets([fleet])
	_check(picker.is_open() and picker.row_count() == 1,
		"the picker opens on the fleet tile")
	(picker.row_verbs(0)["inspect"] as Button).pressed.emit()
	_check(picker.is_card_mode(), "the inspect verb renders the card in place")
	var picker_data: Dictionary = _data_only(
		picker.card_widget().rendered_data())
	_check(str(picker_data["person_id"]) == CAPTAIN,
		"the picker card is the captain's NPC entry")
	var dossier: Control = DossierLib.open_for(CAPTAIN, self)
	_check(dossier != null and dossier.is_open(), "the dossier opens")
	var dossier_data: Dictionary = _data_only(
		dossier.card_widget().rendered_data())
	_check(picker_data == dossier_data,
		"THE SAME CAPTAIN'S CARD IS IDENTICAL FROM EVERY ENTRY (§2.6/§4.12)")
	# A second inspect (after closing the card) renders the same data again.
	picker.close_card()
	_check(not picker.is_card_mode(), "Esc/back returns the picker to the list")
	(picker.row_verbs(0)["inspect"] as Button).pressed.emit()
	_check(_data_only(picker.card_widget().rendered_data()) == picker_data,
		"re-inspecting the same fleet renders the identical card (no drift)")
	dossier.close()
	_drop(dossier)
	_drop(picker)

	# Officer: the tavern recruit dialog vs the S18 row.
	_make_run(0, 10000)
	GameState.npc_fleets = []
	var tavern: Control = TavernScene.instantiate()
	tavern.route_to_port = false
	add_child(tavern)
	tavern.open_recruit_dialog(MATEUS)
	var dialog: Control = tavern.recruit_dialog()
	_check(dialog != null and dialog.is_open(),
		"the recruit dialog opens (the officer entry)")
	var recruit_data: Dictionary = _data_only(tavern.recruit_card_data())
	_check(str(recruit_data["person_id"]) == MATEUS
		and str(recruit_data["kind"]) == "officer",
		"the recruit dialog renders the §4.12 officer card")
	CharacterLib.recruit(MATEUS)
	tavern.close_recruit_dialog()
	var panel: Control = OfficersPanelLib.attach_to(self, self)
	panel.open()
	var row_card: Control = panel.row_widget(MATEUS)["card"]
	_check(str(row_card.rendered_data()["person_id"]) == MATEUS,
		"the S18 row renders the same officer card data")
	_check(_data_only(row_card.rendered_data()) == recruit_data,
		"the same OFFICER's card is identical from the recruit dialog and S18")
	panel.close()
	_drop(panel)
	_drop(tavern)


# --- 8. The dossier career-log tiers (§4.11.3, locked) -----------------------

func _log_rows(dossier: Control) -> Dictionary:
	var out: Dictionary = {}
	var content: Container = dossier.get_node(
		"Center/Panel/Margin/Body/Scroll/Content")
	for child in content.get_children():
		if str(child.name).begins_with("Log_"):
			out[str(child.name)] = child
	return out


func _test_dossier_tiers() -> void:
	_make_run()
	GameState.npc_fleets = [_make_fleet(CAPTAIN)]
	# Tier 0 (< 3): every career-log section locked, the card numbers free.
	var dossier: Control = DossierLib.open_for(CAPTAIN, self)
	_check(CaptainsLib.dossier_seen(CAPTAIN),
		"opening the dossier marks it seen (§4.11.3)")
	var rows := _log_rows(dossier)
	_check(rows.size() == 3, "the career log carries the three sections")
	for gate in [1, 2, 3]:
		var row: Control = rows["Log_%d" % gate]
		_check(row.get_node_or_null("Locked") != null
			and row.get_node_or_null("Data") == null,
			"tier %d's section is locked below its threshold" % gate)
		var locked: Label = row.get_node("Locked")
		_check(locked.text == I18n.fmt("dossier.locked.tier",
			{"tier": [3, 6, 10][gate - 1]}),
			"the locked line names the familiarity threshold (%s)"
			% locked.text)
	dossier.close()
	_drop(dossier)
	# Tier 1 (≥ 3): the fleet composition unlocks.
	CaptainsLib.add_familiarity(CAPTAIN, 3)
	dossier = DossierLib.open_for(CAPTAIN, self)
	rows = _log_rows(dossier)
	_check(rows["Log_1"].get_node_or_null("Data") != null,
		"familiarity 3 unlocks the last fleet composition")
	_check(rows["Log_2"].get_node_or_null("Locked") != null,
		"familiarity 3 still locks home port + sighting history")
	dossier.close()
	_drop(dossier)
	# Tier 2 (≥ 6): home port + sighting history.
	CaptainsLib.add_familiarity(CAPTAIN, 3)
	dossier = DossierLib.open_for(CAPTAIN, self)
	rows = _log_rows(dossier)
	var home_data: Label = rows["Log_2"].get_node("Data")
	_check(home_data.text.contains(
		I18n.t(DataLoader.get_port("london")["name"])),
		"familiarity 6 unlocks the home port line (%s)" % home_data.text)
	dossier.close()
	_drop(dossier)
	# Tier 3 (≥ 10): the full lanes incl. month variants.
	CaptainsLib.add_familiarity(CAPTAIN, 4)
	dossier = DossierLib.open_for(CAPTAIN, self)
	rows = _log_rows(dossier)
	var lanes: Label = rows["Log_3"].get_node("Data")
	_check(lanes.text.contains("atlantic_north"),
		"familiarity 10 unlocks the lane picture (%s)" % lanes.text)
	_check(not lanes.text.begins_with("<"), "no raw keys on the lanes line")
	dossier.close()
	_drop(dossier)

	# Stance ≥ +2 adds the tier + status to the header (§4.11.3).
	CaptainsLib.adjust_stance(CAPTAIN, 2)
	dossier = DossierLib.open_for(CAPTAIN, self)
	var header: Label = dossier.get_node("Center/Panel/Margin/Body/Header")
	_check(header.text.contains(I18n.fmt("dossier.header.tier", {"tier": 2})),
		"stance ≥ +2 adds the current tier to the header (%s)" % header.text)
	_check(header.text.contains(I18n.t_key("dossier.status.at_sea")),
		"the active captain reads 在航/at sea in the header")
	dossier.close()
	_drop(dossier)


# --- 9. The S14 three-tab rework (§4.12.3) -----------------------------------

func _test_s14_tabs() -> void:
	_make_run(2)
	CharacterLib.recruit(MATEUS)
	SkillsLib.appoint(MATEUS, "pilot")
	var panel_script := load("res://scenes/ui_shared/character_panel.gd")
	var s14: Control = panel_script.attach_to(self)
	s14.open()
	_check(s14.is_open(), "S14 opens (the C/Esc contract unchanged)")
	_check(s14.active_tab() == "attributes", "the attributes tab is default")
	var card: Control = s14.get_node(
		"Center/Panel/Margin/Body/AttributesPanel/CardHost/CardScroll/PlayerCard")
	_check(card != null, "the player card hosts on the attributes tab")
	_check(card.section("Allocation") != null,
		"the attributes tab carries the allocation steppers (§4.12.2)")
	# Stage a draft, then switch to the skills tab: the same card instance
	# moves and the draft survives the refresh.
	var luck_plus: Button = card.section("Attributes/Attr_luck/Plus")
	luck_plus.pressed.emit()
	s14.select_tab("skills")
	_check(s14.active_tab() == "skills", "the skills tab selects")
	var moved: Control = s14.get_node(
		"Center/Panel/Margin/Body/SkillsPanel/CardScroll/PlayerCard")
	_check(moved == card,
		"the SAME card instance feeds both person tabs (identical data)")
	_check(moved.alloc_draft() == {"luck": 1},
		"an in-progress draft survives the tab switch (§4.12.2)")
	var gates: Container = s14.get_node(
		"Center/Panel/Margin/Body/SkillsPanel/Scroll/Rows")
	_check(gates.get_child_count() == DataLoader.skill_gates_list.size(),
		"the skills tab renders every skill_gates row (§4.12.3)")
	var first_gate: Control = gates.get_child(0)
	_check(first_gate.get_node("Reason") != null,
		"each gate row renders its reason line (the shared renderer)")
	s14.select_tab("officers")
	var roster: Container = s14.get_node(
		"Center/Panel/Margin/Body/OfficersTabPanel/Scroll/Rows")
	_check(roster.get_child_count() == 1,
		"the officers tab lists the employed officer")
	var officer_row: Control = roster.get_child(0)
	_check(officer_row.get_node("Post") != null,
		"the officers tab carries the post column (§4.12.3)")
	_check((officer_row.get_node("Post") as Label).text
		== I18n.t_key("officer.post.pilot"),
		"the post column names the current post")
	s14.select_tab("quests")
	_check(s14.active_tab() == "quests", "the Phase-3 quests tab is kept")
	s14.close()
	_check(not s14.is_open(), "S14 closes")
	s14.queue_free()


# --- 10. The HUD badge (§4.12.2) ---------------------------------------------

func _test_hud_badge() -> void:
	_make_run(0)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud: Control = HudScene.instantiate()
	host.add_child(hud)
	var badge: Control = hud.get_node(
		"TopRow/CharacterButton/CharBadge")
	var count: Label = hud.get_node(
		"TopRow/CharacterButton/CharBadge/BadgeCount")
	_check(not badge.visible, "pending 0 hides the badge")
	GameState.player["alloc_pending"] = 3
	hud._apply_alloc_badge()
	_check(badge.visible and count.text == "3",
		"pending 3 shows the badge with its count (%s)" % count.text)
	_check(badge.tooltip_text == I18n.t_key("char.points_pending"),
		"the badge tooltip is char.points_pending")
	GameState.player["alloc_pending"] = 0
	hud._apply_alloc_badge()
	_check(not badge.visible, "the badge clears when pending hits 0")
	# The character button opens (and toggles) the S14 panel on the host.
	var button: Button = hud.get_node("TopRow/CharacterButton")
	button.pressed.emit()
	var panel := host.get_node_or_null("CharacterPanel")
	_check(panel != null and panel.is_open(),
		"the character button opens the S14 panel (§4.12.2)")
	button.pressed.emit()
	_check(not panel.is_open(), "the button toggles the panel closed")
	_drop(hud)
	_drop(host)


# --- Harness -----------------------------------------------------------------

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append(message)
	push_error("FAIL: %s" % message)


func _report() -> void:
	# Free every node the sections left behind (cards/panels/drops) — a
	# leak-free exit keeps the runner's exit-code contract clean.
	for child in get_children():
		child.free()
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		set_exit_code(0)
	else:
		print("%d of %d checks FAILED" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - %s" % failure)
		set_exit_code(1)


func set_exit_code(code: int) -> void:
	(get_tree() as SceneTree).quit(code)
