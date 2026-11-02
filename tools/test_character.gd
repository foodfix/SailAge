extends Node
## Phase-8 W3-A Person-model acceptance tests
## (docs/50-CHARACTER-AND-PROGRESSION.md §4.1–§4.6, §4.8, §5, §7).
##
##   godot --headless res://tools/test_character.tscn
##
## Exits 0 when every check passes, 1 otherwise. The S14/S18 panel and S2
## scene sections that lived here through Phase 7 are re-homed with the W5/W6
## UI rebuilds; this suite pins the model only.

const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const TavernEngineLib := preload("res://scripts/port/tavern_engine.gd")

## Six capitals known at new game (docs/20-* §4.11).
const CAPITALS := ["lisbon", "seville", "london", "amsterdam", "istanbul", "venice"]
const NATION_ORDER := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

var _failures: Array[String] = []
var _checks := 0

## Fake filler officers for the OFFICER_MAX = 12 capacity test (data-only
## fixtures, injected and removed by the suite).
const FILLERS := 13


func _ready() -> void:
	_inject_fillers()
	_test_level_formula()
	_test_attribute_reads()
	_test_allocation()
	_test_award_xp_alloc()
	_test_profit_xp()
	_test_profit_reputation()
	_test_legacy_shims()
	_test_new_game_person()
	_test_creation_extremes()
	_test_new_game_all_nations()
	_test_officers_cap_and_states()
	_test_signing_price_mult()
	_remove_fillers()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A new-shape Person block with explicit attributes/skills.
func _set_player(attributes: Dictionary = {}, skills: Dictionary = {},
		officers: Array = []) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"alloc_pending": 0,
		"xp": 0,
		"level": 1,
		"officers": officers.duplicate(),
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	for key in attributes:
		GameState.player["attributes"][key] = attributes[key]
	for key in skills:
		GameState.player["skills"][key] = skills[key]
	GameState.officer_states = {}


func _inject_fillers() -> void:
	for i in FILLERS:
		var officer := {
			"id": "off_test_fill_%02d" % i, "role": "",
			"main_skill": "seamanship", "wage_daily": 20,
			"recruit_ports": ["lisbon"], "personality": [],
			"attributes": {"constitution": 10, "intellect": 10,
				"charisma": 10, "courage": 40, "luck": 10},
			"skills": {"seamanship": 30, "navigation": 0, "swordplay": 0,
				"gunnery": 0, "appraisal": 0, "negotiation": 0,
				"cartography": 0, "rumour": 0, "medicine": 0, "carpentry": 0,
				"cooking": 0},
			"name": {"zh": "试·补充 %d" % i, "en": "Test Filler %d" % i},
			"bio": {"zh": "测试", "en": "Fixture"},
		}
		var card: Dictionary = (officer as Dictionary).duplicate(true)
		DataLoader.officers_list.append(card)
		DataLoader.officers[card["id"]] = card


func _remove_fillers() -> void:
	for i in FILLERS:
		var id := "off_test_fill_%02d" % i
		DataLoader.officers_list.erase(DataLoader.officers.get(id, {}))
		DataLoader.officers.erase(id)
		GameState.officer_states.erase(id)


# --- §4.4 level formula (unchanged from Phase 1) ----------------------------

func _test_level_formula() -> void:
	var rows := [
		[0, 1], [49, 1], [50, 2], [200, 3], [450, 4],
		[800, 5], [1250, 6], [18050, 20], [999999, 20],
	]
	for row in rows:
		_check(
			CharacterLib.level_for_xp(row[0]) == row[1],
			"level_for_xp(%d) == %d (got %d)" % [
				row[0], row[1], CharacterLib.level_for_xp(row[0])
			]
		)
	for level in range(1, 21):
		_check(
			CharacterLib.level_for_xp(CharacterLib.xp_for_level(level)) == level,
			"xp_for_level(%d) = %d round-trips" % [
				level, CharacterLib.xp_for_level(level)
			]
		)
	_check(CharacterLib.xp_for_level(2) == 50, "next_at after xp 0 is 50")
	_check(CharacterLib.xp_for_level(20) == 18050, "level 20 needs 18050 xp")


# --- §4.2 attribute reads and bounds ----------------------------------------

func _test_attribute_reads() -> void:
	_set_player()
	for key in CharacterLib.ATTRIBUTES:
		_check(CharacterLib.attribute(key) == 10,
			"a base attribute reads 10 (%s)" % key)
	_check(CharacterLib.ATTRIBUTES == ["constitution", "intellect", "charisma",
			"courage", "luck"], "the five attribute keys are pinned")
	_check(CharacterLib.SKILL_KEYS == SkillsLib.KEYS,
		"SKILL_KEYS is single-sourced through Skills")
	_check(CharacterLib.BASE_ATTRIBUTE == 10 and CharacterLib.ATTR_MAX == 100,
		"the attribute bounds are base 10 / max 100")
	_set_player({"charisma": 20, "luck": 100})
	var attrs: Dictionary = CharacterLib.attributes()
	_check(attrs["charisma"] == 20 and attrs["luck"] == 100
		and attrs.size() == 5, "attributes() copies the five values")
	_check(CharacterLib.attribute("charisma") == 20,
		"attribute() reads the stored 20")
	GameState.player["attributes"]["luck"] = 500
	_check(CharacterLib.attribute("luck") == 500,
		"an over-range stored attribute reads verbatim — 1–100 is a "
		+ "write-side rule (the allocation/creation steppers clamp writes; "
		+ "the §4.2 formulas consume the stored value exactly)")
	GameState.player["attributes"].erase("courage")
	_check(CharacterLib.attribute("courage") == 10,
		"a missing attribute key reads the base 10")


# --- §4.4 allocation: draft / confirm / refuse / alloc_pending --------------

func _test_allocation() -> void:
	_set_player({"charisma": 40})
	GameState.player["alloc_pending"] = 3
	# A draft is data: nothing moves until allocate() confirms it.
	var draft := {"charisma": 2}
	_check(CharacterLib.attribute("charisma") == 40,
		"building a draft does not move attributes")
	_check(CharacterLib.allocate(draft), "a fitting draft allocates")
	_check(CharacterLib.attribute("charisma") == 42
		and CharacterLib.attribute("courage") == 10,
		"the confirmed draft moved exactly its own attribute")
	_check(CharacterLib.alloc_pending() == 1, "spent points left alloc_pending")
	_check(int(GameState.player["alloc_pending"]) == 1,
		"alloc_pending is the persisted player-block key (§4.8)")
	# Insufficient pending: refused whole.
	_check(not CharacterLib.allocate({"charisma": 2}),
		"a draft larger than the pending counter is refused")
	_check(CharacterLib.attribute("charisma") == 42,
		"a refused draft changes nothing (§4.4 rollback = no-op)")
	# Any attribute passing 100 refuses the WHOLE draft.
	_set_player({"charisma": 99})
	GameState.player["alloc_pending"] = 5
	_check(not CharacterLib.allocate({"charisma": 2}),
		"a +2 over 100 refuses the whole draft")
	_check(CharacterLib.attribute("charisma") == 99
		and CharacterLib.alloc_pending() == 5,
		"the refused overflow spent no points")
	_check(CharacterLib.allocate({"charisma": 1}),
		"a +1 that lands exactly on 100 is allowed")
	_check(CharacterLib.attribute("charisma") == 100,
		"the attribute sits at its 100 clamp (§6: the stepper disables)")
	# Malformed drafts are refused.
	_check(not CharacterLib.allocate({}), "an empty draft is refused")
	_check(not CharacterLib.allocate({"not_an_attr": 1}),
		"an unknown attribute key is refused")
	_check(not CharacterLib.allocate({"luck": 0}), "a zero amount is refused")
	_check(not CharacterLib.allocate({"luck": -1}), "a negative amount is refused")


# --- §4.4 level-up grants +2 alloc_pending ----------------------------------

func _test_award_xp_alloc() -> void:
	_set_player({}, {"seamanship": 8})
	GameState.player["xp"] = 49
	GameState.player["level"] = 1
	CharacterLib.pending_levelup = false
	CharacterLib.award_xp(1)
	_check(CharacterLib.current_level() == 2, "xp 49 → 50 gives level 2")
	_check(int(GameState.player.get("level", 0)) == 2,
		"the stored level cache is written (§4.8)")
	_check(CharacterLib.alloc_pending() == 2,
		"one level grants exactly +2 alloc_pending (§4.4)")
	_check(CharacterLib.attribute("charisma") == 10,
		"level-up no longer auto-grants the Phase-1 stat points (§4.4)")
	_check(SkillsLib.skill("seamanship") == 8,
		"skills never allocate from levels (§4.3)")
	_check(CharacterLib.pending_levelup, "pending_levelup raised for the toast")
	_check(CharacterLib.consume_pending_levelup()
		and not CharacterLib.pending_levelup, "pending_levelup consumed once")
	# The auto-grant is per level gained, once each.
	_set_player()
	CharacterLib.award_xp(450)  # level 1 → 4
	_check(CharacterLib.current_level() == 4, "450 xp → level 4")
	_check(CharacterLib.alloc_pending() == 6, "3 level-ups grant 6 points")
	# At the cap no further points accrue.
	_set_player()
	GameState.player["xp"] = 999999  # level 20
	CharacterLib.pending_levelup = false
	CharacterLib.award_xp(1000)
	_check(CharacterLib.current_level() == 20, "the level clamps at 20")
	_check(CharacterLib.alloc_pending() == 0,
		"past the cap no alloc_pending is granted (§4.4)")
	_check(not CharacterLib.pending_levelup, "a capped award fires no toast")
	# Non-positive amounts are ignored.
	_set_player()
	CharacterLib.award_xp(0)
	CharacterLib.award_xp(-5)
	_check(CharacterLib.current_xp() == 0 and CharacterLib.alloc_pending() == 0,
		"award_xp(0/negative) is a no-op")


# --- §4.4 profit XP (unchanged) ---------------------------------------------

func _test_profit_xp() -> void:
	_set_player()
	CharacterLib.add_profit_xp(31, 30, 10)
	_check(CharacterLib.current_xp() == 1,
		"add_profit_xp(31,30,10) awards 1 XP (got %d)" % CharacterLib.current_xp())
	_set_player()
	GameState.player["xp"] = 37
	CharacterLib.add_profit_xp(10, 30, 10)
	_check(CharacterLib.current_xp() == 37,
		"a loss-making sale leaves xp at 37 (got %d)" % CharacterLib.current_xp())
	_set_player()
	CharacterLib.add_profit_xp(55, 30, 9)  # per-unit 34, profit 306 → 3
	_check(CharacterLib.current_xp() == 3,
		"add_profit_xp(55,30,9) awards 3 XP (got %d)" % CharacterLib.current_xp())


# --- §4.6 reputation ---------------------------------------------------------

func _test_profit_reputation() -> void:
	_set_player()
	# The 1,000g threshold carries across transactions.
	_check(CharacterLib.add_profit_reputation("spain", 600) == 0,
		"600g pays nothing yet")
	_check(CharacterLib.add_profit_reputation("spain", 400) == 1,
		"the next 400g completes the 1,000g threshold")
	_check(CharacterLib.reputation("spain") == 1
		and CharacterLib.profit_by_nation("spain") == 1000
		and int(GameState.player["profit_rep_awarded"]["spain"]) == 1,
		"the accumulator and the paid marker are both stored (§4.6)")
	_check(CharacterLib.add_profit_reputation("spain", 999) == 0,
		"a sub-threshold repeat pays nothing (idempotent)")
	_check(CharacterLib.add_profit_reputation("spain", 1) == 1,
		"the stored counter makes the next point exact")
	_check(CharacterLib.add_reputation("spain", 200) == 100,
		"add_reputation clamps at +100")
	_check(CharacterLib.add_reputation("spain", -500) == -100,
		"add_reputation clamps at −100")


# --- §4.2.3 legacy shims -----------------------------------------------------

func _test_legacy_shims() -> void:
	_set_player({"charisma": 40, "luck": 10}, {"swordplay": 22,
		"seamanship": 30, "navigation": 24})
	_check(CharacterLib.base_stat("leadership") == 40,
		"legacy leadership reads the charisma attribute")
	_check(CharacterLib.effective_stat("leadership") == 40,
		"effective_stat == base_stat (the officer term is gone, §4.5.3)")
	_check(CharacterLib.base_stat("combat") == 22,
		"legacy combat reads the swordplay skill")
	_check(CharacterLib.base_stat("seamanship") == 30
		and CharacterLib.base_stat("navigation") == 24,
		"legacy seamanship/navigation read the same-named skills")
	_check(CharacterLib.base_stat("luck") == 10, "legacy luck reads the attribute")
	_check(CharacterLib.base_stat("not_a_stat") == 0, "an unknown name reads 0")
	_check(CharacterLib.officer_bonus("navigation") == 0,
		"officer_bonus() returns 0 (ROLE_STAT_BONUS deleted, §4.5.3)")
	_check(CharacterLib.officer_bonus_excluding("navigation", "x") == 0,
		"officer_bonus_excluding() returns 0")
	# The pure formulas with their new shapes.
	for row in [[0, 0.0], [15, 0.05], [45, 0.15], [90, 0.30], [300, 0.30]]:
		var got := CharacterLib.speed_bonus_for(row[0])
		_check(is_equal_approx(got, row[1]),
			"speed_bonus_for(%d) == %.2f clamp [0, +0.30] (got %.4f)"
			% [row[0], row[1], got])
	for row in [[0, 48], [11, 48], [12, 49], [24, 50], [96, 56]]:
		_check(CharacterLib.sighting_radius_for(row[0]) == row[1],
			"sighting_radius_for(%d) == %d = 48 + floor(skill/12)"
			% [row[0], row[1]])
	for row in [[10, 1.0], [30, 0.9], [100, 0.55], [1, 1.045]]:
		_check(is_equal_approx(CharacterLib.loss_multiplier_for(row[0]), row[1]),
			"loss_multiplier_for(%d) == %.3f (formula unchanged, charisma now)"
			% [row[0], row[1]])
	_check(CharacterLib.desertion_multiplier() == CharacterLib.mutiny_multiplier(),
		"desertion and mutiny share the charisma multiplier")
	# Storm damage is CONTINUOUS now — no luck ≥ 50 step (§4.2.1).
	for row in [[10, 0.96], [49, 0.804], [50, 0.80], [100, 0.60]]:
		_set_player({"luck": row[0]})
		_check(is_equal_approx(CharacterLib.storm_damage_multiplier(), row[1]),
			"storm damage ×(1 − luck/250) at luck %d == %.3f (continuous)"
			% [row[0], row[1]])
	# The effective-value wrappers read the skills (re-set: the storm rows
	# above rebuilt the fixture).
	_set_player({}, {"seamanship": 30, "navigation": 24})
	_storm_chance_rows()
	_set_player({}, {"seamanship": 30, "navigation": 24})
	_check(is_equal_approx(CharacterLib.speed_bonus(), 0.10),
		"speed_bonus() reads the effective seamanship (30/300)")
	_check(CharacterLib.sighting_radius() == 50,
		"sighting_radius() reads the effective navigation (48 + 24/12)")


func _storm_chance_rows() -> void:
	_set_player({"luck": 10})
	_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 0.975),
		"storm chance ×0.975 at luck 10 (unchanged)")
	_set_player({"luck": 100})
	_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 0.75),
		"storm chance ×0.75 at luck 100 (unchanged)")


# --- §4.1 starting_person: the worked example, bonuses and alloc caps -------

func _test_new_game_person() -> void:
	# The §5 worked Person: Portugal + deckhand + full alloc.
	var person: Dictionary = CharacterLib.starting_person("portugal",
		"background_deckhand", {"constitution": 3, "intellect": 2},
		{"seamanship": 3})
	var attrs: Dictionary = person["attributes"]
	_check(int(attrs["constitution"]) == 16 and int(attrs["intellect"]) == 17,
		"§5 example: CON 16, INT 17 (base 10 + nation 5 + bg 3 + alloc)")
	_check(int(attrs["charisma"]) == 10 and int(attrs["luck"]) == 10
		and int(attrs["courage"]) == 10, "§5 example: untouched attributes at 10")
	var skills: Dictionary = person["skills"]
	_check(int(skills["seamanship"]) == 8 and int(skills["navigation"]) == 5,
		"§5 example: seamanship 8, navigation 5 (0 + nation 5 + bg 5 + alloc 3)")
	_check(int(skills["swordplay"]) == 0, "§5 example: all other skills 0")
	_check((person["skill_counters"] as Dictionary).values().all(
		func(v): return int(v) == 0), "counters all 0 (§4.1)")
	_check(int(person["alloc_pending"]) == 0 and int(person["xp"]) == 0
		and int(person["level"]) == 1, "xp 0, level 1, alloc_pending 0")
	_check((person["officers"] as Array).is_empty()
		and (person[CharacterLib.PROFIT_KEY] as Dictionary).is_empty()
		and (person[CharacterLib.PROFIT_AWARDED_KEY] as Dictionary).is_empty(),
		"empty roster and empty profit accumulators")
	_check(person["equipment"] == {"weapon": "", "armor": ""},
		"the §4.8 equipment block starts empty")
	_check(not person.has("autopilot"),
		"autopilot is absent until W5 appoints a voyage (§4.8)")
	_check(int(person["reputation"]["portugal"]) == 20
		and int(person["reputation"]["spain"]) == 0,
		"own-nation start reputation 20, others 0 (§4.6)")
	_check(str(person["background_id"]) == "background_deckhand",
		"background_id persists in the player block (§4.1 step 5)")

	# Free-point caps: per-item +3 and totals +5/+3 are enforced here, so no
	# caller can break the creation extremes (§4.1 step ②).
	var capped: Dictionary = CharacterLib.starting_person("holland",
		"", {"charisma": 9}, {"negotiation": 9})
	_check(int(capped["attributes"]["charisma"]) == 13,
		"a per-item attribute alloc clamps at +3 (10 + 3; holland's +5 is luck)")
	_check(int(capped["attributes"]["luck"]) == 15,
		"holland's luck reads 10 + 5 (the nation bonus)")
	_check(int(capped["skills"]["negotiation"]) == 8,
		"a skill alloc clamps at +3 (0 + 5 nation + 3; no background)")
	# An unknown background id grants nothing (the legacy 2-arg caller).
	var legacy: Dictionary = CharacterLib.starting_person("spain", "world")
	_check(int(legacy["attributes"]["courage"]) == 15
		and int(legacy["skills"]["swordplay"]) == 5
		and int(legacy["attributes"]["luck"]) == 10,
		"an unknown background_id (the retired map-id positional) adds no bonus")


# --- §4.1 step 4: creation extremes (normative 21 / 13) ---------------------

func _test_creation_extremes() -> void:
	# Attribute 21 = 10 + 5 (ottoman courage) + 3 (fencing student courage)
	# + 3 (the per-item alloc cap).
	var max_attr: Dictionary = CharacterLib.starting_person("ottoman",
		"background_fencing_student", {"courage": 3}, {})
	_check(int(max_attr["attributes"]["courage"]) == 21,
		"the attribute extreme is exactly 21 (§4.1 step 4)")
	# Skill 13 = 0 + 5 (portugal navigation) + 5 (naval cadet navigation)
	# + 3 (the per-item alloc cap).
	var max_skill: Dictionary = CharacterLib.starting_person("portugal",
		"background_navy_cadet", {}, {"navigation": 3})
	_check(int(max_skill["skills"]["navigation"]) == 13,
		"the skill extreme is exactly 13 (§4.1 step 4)")
	_check(CharacterLib.CREATION_ATTR_MAX == 21
		and CharacterLib.CREATION_SKILL_MAX == 13,
		"the extreme constants match the §4.1 closed forms")
	# No build can exceed them: max nation+background misalignment stays ≤ 21/13.
	var mixed: Dictionary = CharacterLib.starting_person("italy",
		"background_tavern_errand", {"luck": 3, "charisma": 2},
		{"rumour": 3, "appraisal": 0})
	_check(int(mixed["attributes"]["luck"]) == 21
		and int(mixed["skills"]["rumour"]) == 8
		and int(mixed["skills"]["appraisal"]) == 5,
		"the aligned-attribute build hits the 21 cap; the skill side reads "
		+ "italy's appraisal 5 + the background's rumour 5 + alloc 3 = 8")


# --- §4.1 new game through GameState (all six nations) ----------------------

func _test_new_game_all_nations() -> void:
	_check(DataLoader.nations_list.size() == 6, "six nations in data")
	for index in DataLoader.nations_list.size():
		_check(str(DataLoader.nations_list[index].get("id", "")) == NATION_ORDER[index],
			"nation order slot %d is %s" % [index, NATION_ORDER[index]])

	for nation_id in NATION_ORDER:
		var nation: Dictionary = DataLoader.get_nation(nation_id)
		GameState.locale = "zh"
		GameState.new_game(nation_id, false)

		_check(GameState.day == 1, "%s: day == 1" % nation_id)
		_check(GameState.gold == int(nation["start_gold"]),
			"%s: gold == start_gold %d (got %d)"
			% [nation_id, int(nation["start_gold"]), GameState.gold])
		_check(GameState.morale == 70, "%s: morale == 70" % nation_id)
		_check(GameState.locale == "zh", "%s: locale untouched" % nation_id)
		_check(GameState.port_investments.is_empty(),
			"%s: investments cleared" % nation_id)
		_check(GameState.current_port == str(nation["start_port_id"]),
			"%s: current_port == %s (got %s)" % [
				nation_id, nation["start_port_id"], str(GameState.current_port)
			])

		# Fleet: exactly one starter hull, crew_min aboard, full durability.
		_check(GameState.fleet.size() == 1, "%s: one starter ship" % nation_id)
		var ship: Dictionary = GameState.fleet[0]
		var ship_type: Dictionary = DataLoader.get_ship_type(
			str(nation["start_ship_type_id"]))
		_check(str(ship.get("ship_type_id", "")) == str(nation["start_ship_type_id"]),
			"%s: ship_type_id == %s" % [nation_id, nation["start_ship_type_id"]])
		_check(int(ship.get("crew", -1)) == int(ship_type["crew_min"]),
			"%s: crew == crew_min %d" % [nation_id, int(ship_type["crew_min"])])

		# The v9 Person block: attributes = 10 + the nation's bonus attribute
		# (+5); skills = 0 everywhere except the signature skill (+5).
		var bonus_attribute := str(nation["bonus_attribute"])
		var bonus_skill := str(nation["bonus_skill"])
		for key in CharacterLib.ATTRIBUTES:
			var expected_attr := 10
			if key == bonus_attribute:
				expected_attr = 15
			_check(CharacterLib.attribute(key) == expected_attr,
				"%s: %s == %d (got %d)" % [nation_id, key, expected_attr,
					CharacterLib.attribute(key)])
		for key in SkillsLib.KEYS:
			var expected_skill := 0
			if key == bonus_skill:
				expected_skill = 5
			_check(SkillsLib.skill(key) == expected_skill,
				"%s: skill %s == %d" % [nation_id, key, expected_skill])
		for key in SkillsLib.KEYS:
			_check(int(GameState.player["skill_counters"][key]) == 0,
				"%s: counter %s starts 0" % [nation_id, key])
		_check(int(GameState.player["alloc_pending"]) == 0,
			"%s: alloc_pending 0" % nation_id)
		_check(str(GameState.player["background_id"]) == "",
			"%s: the legacy 2-arg new_game leaves background_id empty" % nation_id)
		_check(not GameState.player.has("autopilot"),
			"%s: no autopilot key on a fresh block" % nation_id)
		_check((GameState.player["officers"] as Array).is_empty(),
			"%s: no officers" % nation_id)
		var rep: Dictionary = GameState.player["reputation"]
		_check(rep.size() == 6, "%s: reputation covers all 6 nations" % nation_id)
		_check(int(rep.get(nation_id, -999)) == int(nation["start_reputation"]),
			"%s: own reputation == start_reputation %d" % [
				nation_id, int(nation["start_reputation"])])

		# The Phase-8 state blocks seed empty on every fresh run (§8.2).
		_check(GameState.officer_states.is_empty(),
			"%s: officer_states == {}" % nation_id)
		_check(GameState.captain_states.is_empty(),
			"%s: captain_states == {}" % nation_id)

		# World position is the start port's berth tile in the save shape.
		var pos = GameState.world.get("position", null)
		_check(pos is Dictionary and pos.has("x") and pos.has("y"),
			"%s: world.position is a tilePos dict" % nation_id)
		var expected: Vector2i = DataLoader.port_cell(str(nation["start_port_id"]))
		_check(GameState.world_tile() == expected,
			"%s: world.position == %s (got %s)" % [
				nation_id, str(expected), str(GameState.world_tile())])

	# The two-step creation signature: background + free points ride through.
	GameState.new_game("portugal", false, "background_deckhand",
		{"constitution": 3, "intellect": 2}, {"seamanship": 3})
	_check(str(GameState.player["background_id"]) == "background_deckhand"
		and CharacterLib.attribute("constitution") == 16
		and SkillsLib.skill("seamanship") == 8,
		"new_game(nation, route, background, attr_alloc, skill_alloc) builds §4.1")
	# The spread-evenly shortcut's draft behaves like any other draft.
	GameState.new_game("portugal", false, "", {"constitution": 1, "intellect": 1,
		"charisma": 1, "courage": 1, "luck": 1},
		{"seamanship": 1, "navigation": 1, "swordplay": 1})
	_check(CharacterLib.attribute("constitution") == 11
		and CharacterLib.attribute("intellect") == 16
		and SkillsLib.skill("seamanship") == 1
		and SkillsLib.skill("navigation") == 6
		and SkillsLib.skill("swordplay") == 1,
		"the spread-evenly draft allocates +1 attributes / first three skills "
		+ "(portugal's navigation rides to 5 + 1)")


# --- §4.5.5 roster capacity, state seeding and dismissal --------------------

func _test_officers_cap_and_states() -> void:
	_set_player()
	GameState.gold = 100000
	_check(CharacterLib.OFFICER_MAX == 12, "OFFICER_MAX is 12 (§4.5.2)")
	# 12 recruits fit; the 13th is refused.
	for i in 12:
		_check(CharacterLib.recruit("off_test_fill_%02d" % i),
			"recruit %d/12 succeeds" % (i + 1))
	_check(CharacterLib.officer_count() == 12, "the roster holds 12 officers")
	_check(not CharacterLib.can_recruit("off_test_fill_12"),
		"the 13th recruit is blocked by OFFICER_MAX (§6)")
	_check(not CharacterLib.recruit("off_test_fill_12"),
		"recruit() refuses the 13th")
	_check(CharacterLib.officer_count() == 12, "the roster stays at 12")
	# A recruited officer seeds the §8 officer_states entry.
	var state: Dictionary = GameState.officer_states["off_test_fill_00"]
	_check(int(state["loyalty"]) == 50, "hire loyalty starts at 50 (§4.5.4)")
	_check(int(state["sea_days"]) == 0 and str(state["post_id"]) == ""
		and str(state["ship_id"]) == "", "idle, fresh growth clock (§4.8)")
	_check(int(state["talk_cd_day"]) == 0 and int(state["gift_cd_day"]) == 0
		and int(state["defeats"]) == 0, "fresh cooldowns and defeat counter")
	_check(is_equal_approx(float(state["wage_mult"]), 1.0),
		"wage_mult defaults to 1.0 (the master-approved §8 extension)")
	# Dismissal clears the state and frees any post.
	_check(SkillsLib.appoint("off_test_fill_00", "boatswain"),
		"fixture: filler 00 takes the boatswain post")
	_check(SkillsLib.post_holder("boatswain") == "off_test_fill_00",
		"the post holder is seated")
	_check(CharacterLib.dismiss("off_test_fill_00"), "dismiss succeeds")
	_check(not GameState.officer_states.has("off_test_fill_00"),
		"dismissal cleared the state entry (post freed with it, §4.5.5)")
	_check(SkillsLib.post_holder("boatswain") == "",
		"the freed post has no holder")
	_check(CharacterLib.can_recruit("off_test_fill_00"),
		"a dismissed officer is recruitable again")
	_check(not CharacterLib.dismiss("off_test_fill_00"),
		"dismissing an un-employed officer returns false")
	# Wages read the roster Σ wage_daily (× wage_mult).
	_set_player()
	GameState.gold = 100000
	CharacterLib.recruit("off_mateus_alvares")  # wage_daily 30
	_check(CharacterLib.officer_wages() == 30, "one officer: 30g/day")
	_check(SkillsLib.accept_raise("off_mateus_alvares"),
		"the officer accepts a raise")
	_check(CharacterLib.officer_wages() == 38,
		"the wage bill reads ×1.25 (30 × 1.25 → 38)")


# --- §4.5.2 / §4.2.1 signing cost with the charisma multiplier --------------

func _test_signing_price_mult() -> void:
	_set_player({"charisma": 10})
	_check(is_equal_approx(CharacterLib.charisma_price_multiplier(), 1.0),
		"the price multiplier at CHA 10 is ×1.0")
	_check(CharacterLib.recruit_cost("off_mateus_alvares") == 300,
		"wage 30 × 10 × 1.0 = 300g at CHA 10")
	_set_player({"charisma": 60})
	_check(is_equal_approx(CharacterLib.charisma_price_multiplier(), 0.75),
		"the price multiplier at CHA 60 is ×0.75")
	_check(CharacterLib.recruit_cost("off_mateus_alvares") == 225,
		"wage 30 × 10 × 0.75 = 225g at CHA 60")
	_set_player({"charisma": 100})
	_check(is_equal_approx(CharacterLib.charisma_price_multiplier(), 0.55),
		"the multiplier at CHA 100 is ×0.55 (the normative closed form "
		+ "1 − 90/200; the doc's illustrative ×0.5 disagrees)")
	_check(CharacterLib.recruit_cost("off_mateus_alvares") == 165,
		"wage 30 × 10 × 0.55 = 165g at CHA 100")
	_set_player({"charisma": 300})
	_check(is_equal_approx(CharacterLib.charisma_price_multiplier(), 0.5),
		"the formula's own clamp bounds the multiplier at ×0.5 — the "
		+ "1 − (CHA−10)/200 straight line bottoms out there")
	_set_player({"charisma": 1})
	_check(is_equal_approx(CharacterLib.charisma_price_multiplier(), 1.0),
		"the multiplier clamps at its 1.0 ceiling")
	# Gold shortfall: can_recruit reads the multiplied cost (§6).
	_set_player({"charisma": 60})
	GameState.gold = 224
	_check(not CharacterLib.can_recruit("off_mateus_alvares"),
		"224g is short for the 225g CHA-60 fee")
	GameState.gold = 225
	_check(CharacterLib.can_recruit("off_mateus_alvares"),
		"gold exactly == the multiplied fee is allowed")
	_check(CharacterLib.recruit("off_mateus_alvares"), "the signing succeeds")
	_check(GameState.gold == 0, "the multiplied fee is deducted exactly")
	# An employed officer cannot be re-recruited; an unknown id never signs.
	_check(not CharacterLib.can_recruit("off_mateus_alvares"),
		"an employed officer is not recruitable")
	_check(not CharacterLib.can_recruit("off_nobody"),
		"an unknown officer id is never recruitable")
	_check(not TavernEngineLib.officers_at_port("lisbon").has("off_mateus_alvares"),
		"an employed officer left every tavern pool (§4.5.5)")


# --- Harness ----------------------------------------------------------------

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
