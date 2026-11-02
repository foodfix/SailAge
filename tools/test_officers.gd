extends Node
## Phase-8 W3-A officer-model re-baseline (docs/50-CHARACTER-AND-PROGRESSION.md
## §4.5; the Phase-5 S18 panel sections are re-homed with the W5/W6 UI
## rebuilds — this suite pins the shared officer APIs the panel will read).
##
##   godot --headless res://tools/test_officers.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const TavernEngineLib := preload("res://scripts/port/tavern_engine.gd")

## The retained Phase-1 starters (`data/officers.json` v2 keeps the ids).
const MATEUS := "off_mateus_alvares"  # navigator, wage 30, lisbon/madeira
const DIEGO := "off_diego_fernandez"  # wage 28, seville/ceuta
const REED := "off_thomas_reed"       # wage 32, london

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_roster_v2_data()
	_test_recruit_seeds_state()
	_test_recruit_blocked()
	_test_dismiss_clears_state()
	_test_wages_and_posts()
	_test_pool_roundtrip()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A Portugal run docked at Lisbon with a fresh-shape Person block.
func _make_run(officers: Array = [], gold: int = 10000) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
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
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	GameState.officer_states = {}
	GameState.gold = gold
	GameState.day = 12
	GameState.morale = 70
	GameState.fleet = [FleetLib.new_ship("caravel", 15)]
	GameState.current_port = "lisbon"
	GameState.world = {"position": {"x": 7, "y": 57}, "clock_fraction": 0.0}
	GameState.locale = "en"


# --- 1. The v2 roster keeps the Phase-1 starters' contract ------------------

func _test_roster_v2_data() -> void:
	_check(DataLoader.officers_list.size() == 96,
		"the v2 roster holds exactly 96 officers (24 + 72, got %d)"
		% DataLoader.officers_list.size())
	var mateus: Dictionary = DataLoader.get_officer(MATEUS)
	_check(not mateus.is_empty(), "Mateus Álvares is retained in v2")
	_check(str(mateus["main_skill"]) == "navigation"
		and int(mateus["wage_daily"]) == 30,
		"his card carries main_skill navigation and wage 30")
	_check(mateus.has("attributes") and mateus.has("skills")
		and (mateus["skills"] as Dictionary).size() == 11,
		"the v2 card is the Person shape: 5 attributes + 11 skills")
	_check(not mateus.has("role") and not mateus.has("stats"),
		"the retired role/stats fields are gone from the v2 card")


# --- 2. Recruit seeds the §8 state (docs/50-* §4.5.5) -----------------------

func _test_recruit_seeds_state() -> void:
	_make_run()
	_check(CharacterLib.recruit_cost(MATEUS) == 300,
		"Mateus signs for ceil(30 × 10 × 1.0) = 300g at CHA 10")
	_check(CharacterLib.can_recruit(MATEUS), "can recruit when rich")
	_check(CharacterLib.recruit(MATEUS), "recruit succeeds")
	_check(GameState.gold == 10000 - 300, "the signing fee is deducted")
	_check(CharacterLib.is_employed(MATEUS), "the officer is employed")
	_check(GameState.player["officers"] == [MATEUS],
		"player.officers stores the id (§4.8)")
	var state: Dictionary = GameState.officer_states[MATEUS]
	_check(not state.is_empty(), "recruit seeded an officer_states entry")
	_check(int(state["loyalty"]) == 50, "hire loyalty is 50 (§4.5.4)")
	_check(int(state["sea_days"]) == 0 and str(state["post_id"]) == ""
		and str(state["ship_id"]) == "", "the entry starts idle with a fresh clock")
	_check(int(state["talk_cd_day"]) == 0 and int(state["gift_cd_day"]) == 0
		and int(state["defeats"]) == 0
		and is_equal_approx(float(state["wage_mult"]), 1.0),
		"fresh cooldowns, defeats and wage_mult 1.0")
	_check(not CharacterLib.can_recruit(MATEUS),
		"an employed officer cannot be re-recruited")
	_check(not CharacterLib.recruit(MATEUS), "recruit() refuses a second signing")
	# The employed officer vanishes from the tavern pools while aboard.
	for port_id in ["lisbon", "madeira"]:
		_check(not TavernEngineLib.officers_at_port(port_id).has(MATEUS),
			"%s no longer lists the employed officer" % port_id)


# --- 3. OFFICER_MAX = 12 blocks the 13th (docs/50-* §4.5.2) -----------------

func _test_recruit_blocked() -> void:
	_make_run([], 100000)
	# Fill the roster from the real 96-officer pool; the first officer that
	# no longer fits is refused by the cap (OFFICER_MAX = 12), not by gold.
	for officer in DataLoader.officers_list:
		if CharacterLib.officer_count() >= CharacterLib.OFFICER_MAX:
			break
		CharacterLib.recruit(str(officer["id"]))
	_check(CharacterLib.officer_count() == 12,
		"the roster filled to exactly 12 (got %d)" % CharacterLib.officer_count())
	var thirteenth := ""
	for officer in DataLoader.officers_list:
		if not CharacterLib.is_employed(str(officer["id"])):
			thirteenth = str(officer["id"])
			break
	_check(thirteenth != "", "a 13th candidate exists in the 96-officer pool")
	_check(not CharacterLib.can_recruit(thirteenth),
		"the 13th officer is blocked by OFFICER_MAX (§6: roster full)")
	_check(not CharacterLib.recruit(thirteenth), "recruit() refuses the 13th")
	_check(not CharacterLib.can_recruit("off_nobody_at_all"),
		"an unknown id is refused regardless of space")
	# Gold shortfall still blocks before the cap matters (§6).
	_make_run([], 100)
	_check(not CharacterLib.can_recruit(MATEUS),
		"recruit disabled at 100g for a 300g signing fee")
	_make_run([], 300)
	_check(CharacterLib.can_recruit(MATEUS), "gold exactly == the fee is allowed")
	_check(CharacterLib.recruit(MATEUS), "recruit at exactly 300g")
	_check(GameState.gold == 0, "gold becomes 0 after the signing fee")


# --- 4. Dismiss clears the state and frees the post (§4.5.5) ----------------

func _test_dismiss_clears_state() -> void:
	_make_run([], 20000)
	CharacterLib.recruit(MATEUS)
	CharacterLib.recruit(DIEGO)
	_check(GameState.player["officers"].size() == 2, "two officers aboard")
	_check(SkillsLib.appoint(MATEUS, "pilot"), "Mateus takes the pilot post")
	_check(SkillsLib.post_holder("pilot") == MATEUS, "the post is seated")
	_check(CharacterLib.dismiss(MATEUS), "dismiss succeeds")
	_check(GameState.player["officers"] == [DIEGO],
		"player.officers shrinks to the remaining officer")
	_check(not GameState.officer_states.has(MATEUS),
		"the dismissal cleared the state entry (§4.5.5)")
	_check(SkillsLib.post_holder("pilot") == "",
		"the post freed with the dismissal")
	_check(GameState.gold == 20000 - 300 - 280,
		"dismissal pays no severance (§4.5.5)")
	_check(not CharacterLib.dismiss(REED), "dismissing an absent officer is false")
	# Re-hire starts fresh at 50 (the state was erased, not archived).
	CharacterLib.recruit(MATEUS)
	_check(int(GameState.officer_states[MATEUS]["loyalty"]) == 50,
		"a re-hire starts fresh at loyalty 50 (§4.5.4)")


# --- 5. Wages and the post pipeline read the same roster --------------------

func _test_wages_and_posts() -> void:
	_make_run([MATEUS, DIEGO])
	GameState.officer_states[MATEUS] = {"loyalty": 50, "sea_days": 0,
		"post_id": "", "ship_id": "", "talk_cd_day": 0, "gift_cd_day": 0,
		"defeats": 0, "wage_mult": 1.0}
	GameState.officer_states[DIEGO] = {"loyalty": 50, "sea_days": 0,
		"post_id": "", "ship_id": "", "talk_cd_day": 0, "gift_cd_day": 0,
		"defeats": 0, "wage_mult": 1.0}
	_check(CharacterLib.officer_wages() == 58,
		"the wage bill is Σ wage_daily: 30 + 28 = 58 (got %d)"
		% CharacterLib.officer_wages())
	# The pilot's true value feeds the pipeline through the post (§4.5.3).
	GameState.player["skills"]["navigation"] = 15
	_check(SkillsLib.appoint(MATEUS, "pilot"), "the navigator takes the pilot post")
	_check(SkillsLib.effective_skill("navigation") == 45,
		"effective navigation 15 + 30 = 45 (the post's true value)")
	_check(CharacterLib.sighting_radius() == 51,
		"sighting 48 + floor(45/12) = 51 (the §4.3.1 formula)")
	# Diego is employed but idle — no post, no contribution (§4.5.3).
	_check(SkillsLib.effective_skill("seamanship") == 0,
		"an employed officer without a post contributes nothing")


# --- 6. The pool round trip: hire → vanish → dismiss → reappear (§4.5.5) ----

func _test_pool_roundtrip() -> void:
	_make_run([], 5000)
	_check(TavernEngineLib.officers_at_port("london").has(REED),
		"london lists Reed (retained starter band, plus the legend layer)")
	_check(TavernEngineLib.officers_at_port("madeira").has(MATEUS),
		"madeira lists Mateus (the retained starter band)")
	_check(CharacterLib.recruit(REED), "Reed signs at London")
	_check(not TavernEngineLib.officers_at_port("london").has(REED),
		"london's pool drops him while he is employed")
	_check(CharacterLib.dismiss(REED), "dismiss him")
	_check(TavernEngineLib.officers_at_port("london").has(REED),
		"he is back in the pool after dismissal")
	# Data-only proof: a fake officer appears with no code edit.
	var fake := {
		"id": "off_test_fake", "role": "", "main_skill": "navigation",
		"wage_daily": 1, "recruit_ports": ["barcelona"],
		"name": {"zh": "测试", "en": "Test"},
		"bio": {"zh": "测试", "en": "Test"},
		"attributes": {}, "skills": {}, "personality": [],
	}
	var fake_card: Dictionary = fake.duplicate(true)
	DataLoader.officers_list.append(fake_card)
	DataLoader.officers["off_test_fake"] = fake_card
	_check(TavernEngineLib.officers_at_port("barcelona") == ["off_test_fake"],
		"a data-only officer shows up at its port")
	DataLoader.officers_list.pop_back()
	DataLoader.officers.erase("off_test_fake")
	_check(TavernEngineLib.officers_at_port("not_a_port").is_empty(),
		"an unknown port id lists nobody")


# --- Harness ----------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	if description.is_empty():
		return
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
