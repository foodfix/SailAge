extends Node
## Phase-8 W3-A skills-layer acceptance tests
## (docs/50-CHARACTER-AND-PROGRESSION.md §4.3, §4.5; docs/90-* §13 contract:
## headless, exit 0, `ALL PASS (N checks)`).
##
##   godot --headless res://tools/test_skills.gd
##
## Exits 0 when every check passes, 1 otherwise. Deterministic contract pins
## only — no Monte Carlo, no scene boots beyond this one.

const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")

## A caravel fixture (the cheapest common hull; nothing here depends on it).
const CARAVEL_MIN := 15

## Fake officers injected into the loaded roster (data-only fixtures, the
## `test_tavern` pattern): stable ids, controlled skills/personality, removed
## again in `_cleanup`.
const FAKE_OFFICERS := [
	{
		"id": "off_test_pilot", "role": "", "main_skill": "navigation",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": ["honest"],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 10},
		"skills": {"seamanship": 12, "navigation": 40, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·舵手", "en": "Test Pilot"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_boatswain", "role": "", "main_skill": "seamanship",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": ["greedy"],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 40, "navigation": 12, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·水手长", "en": "Test Boatswain"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_nav_sig", "role": "", "main_skill": "seamanship",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": [],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 44, "navigation": 10, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·老水手", "en": "Test Signature"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_surgeon", "role": "", "main_skill": "medicine",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": ["loyal"],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 25, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·船医", "en": "Test Surgeon"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_surgeon_weak", "role": "", "main_skill": "medicine",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": [],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 10, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·见习医", "en": "Test Weak Surgeon"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_cook", "role": "", "main_skill": "cooking",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": [],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 30},
		"name": {"zh": "试·厨师", "en": "Test Cook"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_captain_ok", "role": "", "main_skill": "seamanship",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": [],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 10},
		"skills": {"seamanship": 30, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·船长", "en": "Test Captain OK"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
	{
		"id": "off_test_captain_timid", "role": "", "main_skill": "seamanship",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": [],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 20, "luck": 10},
		"skills": {"seamanship": 30, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·怯懦者", "en": "Test Captain Timid"},
		"bio": {"zh": "测试", "en": "Fixture"},
	},
]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_inject_fakes()
	_test_data_tables()
	_test_skill_reads_and_boundaries()
	_test_growth_thresholds()
	_test_counter_boundaries()
	_test_note_sea_day()
	_test_training_price()
	_test_training_cap_and_payment()
	_test_contribution()
	_test_appointment_prereqs()
	_test_appointment_occupancy()
	_test_captain_posts()
	_test_officer_day_tick_growth()
	_test_resign_and_raise()
	_test_talk_gift_cooldowns()
	_test_loyalty_multiplier()
	_cleanup()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A fresh-shape run: base Person (no nation bonus — attributes all 10),
## `gold`, `day`, a one-ship fleet at Lisbon.
func _make_run(gold: int = 10000, day: int = 10,
		intellect: int = 10, charisma: int = 10) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {"constitution": 10, "intellect": intellect,
			"charisma": charisma, "courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"alloc_pending": 0,
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	GameState.gold = gold
	GameState.day = day
	GameState.morale = 70
	GameState.fleet = []
	GameState.current_port = "lisbon"
	GameState.officer_states = {}
	CharacterLib.pending_levelup = false
	CharacterLib.set_pending_raise(false)


func _inject_fakes() -> void:
	for officer in FAKE_OFFICERS:
		# The const table is deep read-only; the loader cache must hold a
		# mutable copy (the growth rule writes the officer card, §4.3.2).
		var card: Dictionary = (officer as Dictionary).duplicate(true)
		DataLoader.officers_list.append(card)
		DataLoader.officers[card["id"]] = card


func _cleanup() -> void:
	for officer in FAKE_OFFICERS:
		var id := str((officer as Dictionary)["id"])
		DataLoader.officers_list.erase(DataLoader.officers.get(id, {}))
		DataLoader.officers.erase(id)
	GameState.officer_states = {}


## Recruits one of the fake officers (gold is always ample) and returns its id.
func _hire(officer_id: String) -> String:
	_check(CharacterLib.recruit(officer_id), "fixture: %s recruited" % officer_id)
	return officer_id


# --- 0. The data tables the layer reads (docs/10-* §4.20–§4.22) -------------

func _test_data_tables() -> void:
	_check(DataLoader.officer_posts_list.size() == 7,
		"officer_posts.json holds exactly the 7 posts (got %d)"
		% DataLoader.officer_posts_list.size())
	var captain: Dictionary = DataLoader.get_officer_post("captain")
	_check(int(captain.get("prereq", {}).get("seamanship", -1)) == 25
		and int(captain.get("prereq", {}).get("courage", -1)) == 30,
		"the captain post prereq is seamanship 25 ∧ courage 30 (from data)")
	var pilot: Dictionary = DataLoader.get_officer_post("pilot")
	_check(int(pilot.get("prereq", {}).get("navigation", -1)) == 20,
		"the pilot post prereq is navigation 20 (from data)")
	_check(DataLoader.backgrounds_list.size() == 6,
		"backgrounds.json holds exactly 6 backgrounds (got %d)"
		% DataLoader.backgrounds_list.size())
	var gate: Dictionary = DataLoader.get_skill_gate("sail.autopilot")
	_check(int(gate.get("threshold", -1)) == 40
		and str(gate.get("stat_or_skill", "")) == "navigation",
		"the sail.autopilot gate row reads navigation 40 (from data)")
	_check(DataLoader.get_officer_post("no_such_post").is_empty(),
		"an unknown post id resolves empty")


# --- 1. Reads and bounds (docs/50-* §4.3, §4.8) -----------------------------

func _test_skill_reads_and_boundaries() -> void:
	_make_run()
	for key in SkillsLib.KEYS:
		_check(SkillsLib.skill(key) == 0, "a fresh skill reads 0 (%s)" % key)
		_check(SkillsLib.effective_skill(key) == 0,
			"effective == base with an empty roster (%s)" % key)
	GameState.player["skills"]["seamanship"] = 55
	_check(SkillsLib.skill("seamanship") == 55, "skill() reads the stored value")
	GameState.player["skills"]["seamanship"] = 100
	GameState.player["skills"]["navigation"] = 300
	_check(SkillsLib.skill("seamanship") == 100, "the read clamps at 100")
	_check(SkillsLib.skill("navigation") == 100, "an over-range stored value reads 100")
	_check(SkillsLib.skill("not_a_skill") == 0, "an unknown key reads 0")
	_check(SkillsLib.KEYS.size() == 8, "exactly 8 player skills")
	_check(SkillsLib.OFFICER_KEYS == ["medicine", "carpentry", "cooking"],
		"the officer skill trio is pinned")


# --- 2. Growth thresholds are the §4.3.1 table (contract pins) --------------

func _test_growth_thresholds() -> void:
	var expected := {
		"seamanship": 30, "navigation": 30, "swordplay": 1, "gunnery": 10,
		"appraisal": 20, "negotiation": 15, "cartography": 5, "rumour": 10,
	}
	for key in expected:
		_check(SkillsLib.growth_threshold(key) == expected[key],
			"growth_threshold(%s) == %d (+1 per N uses, §4.3.1)"
			% [key, expected[key]])
	_check(SkillsLib.growth_threshold("nope") == 0,
		"an unknown key has no threshold")


# --- 3. Counter boundaries (docs/50-* §4.3.3) -------------------------------

func _test_counter_boundaries() -> void:
	_make_run()
	# Exactness: cartography awards on the 5th use only.
	for i in 4:
		SkillsLib.note_usage("cartography")
		SkillsLib.maybe_award("cartography")
	_check(SkillsLib.skill("cartography") == 0
		and SkillsLib.counters()["cartography"] == 4,
		"4 of 5 uses: no award, counter 4")
	SkillsLib.note_usage("cartography")
	SkillsLib.maybe_award("cartography")
	_check(SkillsLib.skill("cartography") == 1
		and SkillsLib.counters()["cartography"] == 0,
		"the 5th use awards +1 and resets the counter")

	# swordplay's threshold is 1 — one duel round, one +1.
	SkillsLib.note_usage("swordplay")
	SkillsLib.maybe_award("swordplay")
	_check(SkillsLib.skill("swordplay") == 1, "swordplay grows every duel round")

	# Below threshold nothing accrues.
	SkillsLib.note_usage("appraisal", 19)
	SkillsLib.maybe_award("appraisal")
	_check(SkillsLib.skill("appraisal") == 0, "19 of 20 trades: no award")
	SkillsLib.note_usage("appraisal")
	SkillsLib.maybe_award("appraisal")
	_check(SkillsLib.skill("appraisal") == 1, "the 20th profitable trade awards")

	# At skill 100 the counter stops counting (§4.3.3).
	GameState.player["skills"]["rumour"] = 100
	SkillsLib.note_usage("rumour", 50)
	SkillsLib.maybe_award("rumour")
	_check(int(SkillsLib.counters()["rumour"]) == 0,
		"a maxed skill leaves its counter at 0")
	_check(SkillsLib.skill("rumour") == 100, "a maxed skill never passes 100")


# --- 4. note_sea_day (docs/50-* §4.3.1: the 30 sea-day rows) ----------------

func _test_note_sea_day() -> void:
	_make_run()
	var pilot := _hire("off_test_pilot")
	_check(SkillsLib.appoint(pilot, "pilot"), "fixture: pilot takes the helm post")
	for i in 29:
		SkillsLib.note_sea_day()
	_check(SkillsLib.skill("seamanship") == 0 and SkillsLib.skill("navigation") == 0,
		"29 sea days: neither skill has grown")
	_check(int(GameState.officer_states[pilot]["sea_days"]) == 29,
		"the officer growth clock advanced with the same ticks (29)")
	SkillsLib.note_sea_day()
	_check(SkillsLib.skill("seamanship") == 1 and SkillsLib.skill("navigation") == 1,
		"30 sea days award both §4.3.1 sea-day skills")
	_check(int(GameState.officer_states[pilot]["sea_days"]) == 30,
		"the officer clock reads 30 (awards at its own 90)")
	# The counters reset on award and start the next cycle clean.
	_check(int(SkillsLib.counters()["seamanship"]) == 0,
		"the awarded counter reset to 0")


# --- 5. Paid training price (docs/50-* §4.3.4) ------------------------------

func _test_training_price() -> void:
	# INT boundaries at level 1: 60 × (1 − (INT−10)/200).
	_make_run(100000, 10, 10, 10)
	_check(SkillsLib.training_price("seamanship") == 60,
		"training at INT 10 is level × 60 = 60")
	_make_run(100000, 10, 60, 10)
	_check(SkillsLib.training_price("seamanship") == 45,
		"training at INT 60 is ceil(60 × 0.75) = 45")
	_make_run(100000, 10, 100, 10)
	_check(SkillsLib.training_price("seamanship") == 33,
		"training at INT 100 is ceil(60 × 0.55) = 33")
	# The §5 worked example: level 1, Portugal INT 17 → ceil(57.9) = 58.
	_make_run(100000, 10, 17, 10)
	_check(SkillsLib.training_price("seamanship") == 58,
		"the §5 example: level 1, INT 17 → 58g per +1")
	# Level scales the fee linearly: xp 200 → level 3.
	GameState.player["xp"] = 200
	_check(SkillsLib.training_price("seamanship") == 174,
		"level 3 at INT 17: ceil(3 × 60 × 0.965) = 174")


# --- 6. Training cap and payment (docs/50-* §4.3.4) -------------------------

func _test_training_cap_and_payment() -> void:
	_make_run(1000, 10, 10, 10)
	GameState.player["skills"]["negotiation"] = 30
	_check(SkillsLib.can_train("negotiation"), "a skill below 60 can train")
	_check(SkillsLib.train("negotiation"), "train() pays and raises")
	_check(GameState.gold == 1000 - 60 and SkillsLib.skill("negotiation") == 31,
		"the fee is deducted and the skill is 31 (got %d / %d)"
		% [GameState.gold, SkillsLib.skill("negotiation")])
	_make_run(59, 10, 10, 10)
	_check(not SkillsLib.can_train("negotiation"),
		"a short purse disables training (§6: price shown instead)")
	_check(not SkillsLib.train("negotiation"), "train() refuses without gold")
	_make_run(100000, 10, 10, 10)
	GameState.player["skills"]["negotiation"] = 60
	_check(not SkillsLib.can_train("negotiation"),
		"the training cap 60 refuses (usage growth still passes 60)")
	_check(not SkillsLib.train("negotiation"),
		"train() is a no-op at the cap")
	_check(GameState.gold == 100000, "a refused training pays nothing")
	_check(SkillsLib.skill("negotiation") == 60, "the cap holds the value at 60")


# --- 7. Contribution (docs/50-* §4.5.3) -------------------------------------

func _test_contribution() -> void:
	_make_run()
	# One in-post boatswain, true value 40, loyalty 50: 1:1, no stacking.
	var bosun := _hire("off_test_boatswain")
	_check(SkillsLib.appoint(bosun, "boatswain"), "the boatswain takes the post")
	GameState.player["skills"]["seamanship"] = 5
	_check(SkillsLib.effective_skill("seamanship") == 45,
		"effective 5 + 40 = 45 (the ONE in-post officer's true value)")
	_check(CharacterLib.speed_bonus_for(SkillsLib.effective_skill("seamanship"))
		== 0.15, "the pipeline reads the effective value (45/300 = +0.15)")
	# An idle officer contributes nothing (post, not presence).
	var cook := _hire("off_test_cook")
	_check(SkillsLib.effective_skill("cooking") == 0,
		"an employed but idle officer adds nothing")

	# Loyalty < 30: floor(true × 0.8).
	GameState.officer_states[bosun]["loyalty"] = 29
	_check(SkillsLib.officer_contribution("seamanship") == 32,
		"loyalty 29 derates floor(40 × 0.8) = 32")
	# Loyalty ≥ 80 on the NATIVE signature skill adds +5.
	GameState.officer_states[bosun]["loyalty"] = 80
	_check(SkillsLib.officer_contribution("seamanship") == 45,
		"loyalty 80 on the native skill: 40 + 5 = 45")
	# A qualified second officer cannot stack onto the boatswain's seat
	# (off_test_nav_sig: seamanship 44 passes the prereq, seat taken).
	var second_bosun := _hire("off_test_nav_sig")
	_check(not SkillsLib.appoint(second_bosun, "boatswain"),
		"one person per post: the occupied seat refuses (§4.5.3)")
	_check(SkillsLib.effective_skill("seamanship") == 50,
		"still exactly one contributor: 5 + 45 = 50")

	# The captain seat never feeds the player's skills (§4.5.3: captain → ship).
	_make_run()
	var cap := _hire("off_test_captain_ok")
	_check(SkillsLib.appoint(cap, "captain", "ship_escort_1"),
		"the captain seat takes a ship id")
	_check(SkillsLib.officer_contribution("seamanship") == 0,
		"a captain in post contributes 0 to the player's seamanship")


# --- 8. Appointment prereqs (docs/50-* §4.5.2, gray cases) ------------------

func _test_appointment_prereqs() -> void:
	_make_run()
	var weak := _hire("off_test_surgeon_weak")  # medicine 10 < 20
	_check(not SkillsLib.appoint(weak, "surgeon"),
		"prereq unmet: medicine 10 fails the surgeon's 20")
	var good := _hire("off_test_surgeon")  # medicine 25
	_check(SkillsLib.appoint(good, "surgeon"), "medicine 25 passes surgeon 20")
	_check(SkillsLib.post_holder("surgeon") == good,
		"post_holder reports the seated officer")
	_check(not SkillsLib.appoint("off_nobody", "pilot"),
		"an un-employed officer cannot be appointed")
	_check(not SkillsLib.appoint(good, "no_such_post"),
		"an unknown post id is refused")
	# Unassign moves back to idle (§4.5.2: post freed).
	_check(SkillsLib.appoint(good, ""), "unassigning returns the officer to idle")
	_check(SkillsLib.post_holder("surgeon") == "",
		"the post is free after unassign")
	var state: Dictionary = GameState.officer_states[good]
	_check(str(state["post_id"]) == "" and str(state["ship_id"]) == "",
		"the idle state is post_id '' + ship_id ''")


# --- 9. Occupancy (one person per post / per ship) --------------------------

func _test_appointment_occupancy() -> void:
	_make_run()
	var a := _hire("off_test_surgeon")
	var weak := _hire("off_test_surgeon_weak")
	_check(SkillsLib.appoint(a, "surgeon"), "the first surgeon sits")
	_check(not SkillsLib.appoint(weak, "surgeon"),
		"the second surgeon is refused even before prereqs (occupied seat)")
	# Moving seats re-checks the new post's prereqs: the surgeon has
	# seamanship 0, so the boatswain seat refuses the move.
	_check(not SkillsLib.appoint(a, "boatswain"),
		"moving seats re-checks the new post's prereqs (seamanship 0 < 20)")
	_check(SkillsLib.post_holder("surgeon") == a,
		"the failed move left the surgeon seated")


# --- 10. Captain posts (docs/50-* §4.5.2: seamanship 25 ∧ courage 30) -------

func _test_captain_posts() -> void:
	_make_run()
	var ok := _hire("off_test_captain_ok")      # sea 30 / cou 40
	var timid := _hire("off_test_captain_timid")  # sea 30 / cou 20
	_check(not SkillsLib.appoint(timid, "captain", "ship_a"),
		"courage 20 fails the captain's 30 (the attribute half of the prereq)")
	_check(SkillsLib.appoint(ok, "captain", "ship_a"),
		"seamanship 30 ∧ courage 40 takes the captain seat")
	_check(not SkillsLib.appoint(timid, "captain", "ship_a"),
		"a second captain on the SAME ship is refused")
	# An officer holds ONE seat: re-appointing moves him (ship_a frees).
	_check(SkillsLib.appoint(ok, "captain", "ship_b"),
		"re-appointing the same captain moves him to the other ship")
	_check(str(GameState.officer_states[ok]["ship_id"]) == "ship_b",
		"the captain's state carries its ship id (§4.8)")
	var second := _hire("off_test_boatswain")  # sea 40, courage 10 → fails
	_check(not SkillsLib.appoint(second, "captain", "ship_a"),
		"the boatswain lacks the courage prereq for the freed ship_a")
	_check(SkillsLib.post_holder("captain") == ok,
		"post_holder finds the seated captain")


# --- 11. The officer day tick (docs/50-* §4.3.2 growth clock) ---------------

func _test_officer_day_tick_growth() -> void:
	_make_run()
	# In post: the post's skill grows (surgeon → medicine).
	var doc := _hire("off_test_surgeon")
	_check(SkillsLib.appoint(doc, "surgeon"), "fixture: surgeon seated")
	GameState.officer_states[doc]["sea_days"] = 89
	SkillsLib.officer_day_tick()
	_check(int(GameState.officer_states[doc]["sea_days"]) == 90,
		"the clock ticks to 90")
	_check(int(DataLoader.get_officer(doc)["skills"]["medicine"]) == 26,
		"the 90th in-post day grows the post's skill 25 → 26")
	# The clock is modular: the next award is another 90 days later.
	SkillsLib.officer_day_tick()
	_check(int(DataLoader.get_officer(doc)["skills"]["medicine"]) == 26,
		"day 91 grows nothing (per-award counter resets, §4.3.2)")

	# Idle bench: the native main skill grows instead.
	var cook := _hire("off_test_cook")
	GameState.officer_states[cook]["sea_days"] = 89
	SkillsLib.officer_day_tick()
	_check(int(DataLoader.get_officer(cook)["skills"]["cooking"]) == 31,
		"the idle officer's 90th day grows the native main skill 30 → 31")


# --- 12. Resign and the raise event (docs/50-* §4.5.4) ----------------------

func _test_resign_and_raise() -> void:
	_make_run()
	# Loyalty < 15 → resign: roster + state cleared, post freed.
	var quitter := _hire("off_test_surgeon")
	_check(SkillsLib.appoint(quitter, "surgeon"), "fixture: seated")
	GameState.officer_states[quitter]["loyalty"] = 14
	SkillsLib.officer_day_tick()
	_check(not CharacterLib.is_employed(quitter),
		"loyalty 14 resigns (§4.5.4)")
	_check(not GameState.officer_states.has(quitter),
		"the resign cleared the state entry (a re-hire starts fresh at 50)")
	_check(SkillsLib.post_holder("surgeon") == "",
		"the post freed with the resignation")

	# Loyalty < 30 → the raise-demand flag; accept/reduce paths.
	var grumbler := _hire("off_test_cook")
	_check(SkillsLib.appoint(grumbler, "cook"), "fixture: cook seated")
	GameState.officer_states[grumbler]["loyalty"] = 29
	CharacterLib.set_pending_raise(false)
	SkillsLib.officer_day_tick()
	_check(CharacterLib.pending_raise,
		"loyalty 29 raises the session raise-demand flag")
	var wages_before := CharacterLib.officer_wages()
	_check(SkillsLib.accept_raise(grumbler),
		"accepting the raise (wage × 1.25 permanent, loyalty +10)")
	_check(is_equal_approx(
		float(GameState.officer_states[grumbler]["wage_mult"]), 1.25),
		"wage_mult is 1.25 after the raise")
	_check(int(GameState.officer_states[grumbler]["loyalty"]) == 39,
		"accepting pays +10 loyalty (29 → 39)")
	_check(not CharacterLib.pending_raise, "the resolved raise clears the flag")
	_check(CharacterLib.officer_wages() == int(round(wages_before * 1.25)),
		"the wage bill reads the ×1.25 multiplier (%d → %d)"
		% [wages_before, CharacterLib.officer_wages()])
	# Refusing costs −10 flat (no charisma multiplier on negatives).
	GameState.officer_states[grumbler]["loyalty"] = 25
	CharacterLib.set_pending_raise(true)
	_check(SkillsLib.refuse_raise(grumbler), "refusing the raise")
	_check(int(GameState.officer_states[grumbler]["loyalty"]) == 15,
		"refusal is a flat −10 (25 → 15)")
	_check(not CharacterLib.pending_raise, "the refused raise clears the flag")


# --- 13. Talk / gift cooldowns (docs/50-* §4.5.4) ---------------------------

func _test_talk_gift_cooldowns() -> void:
	_make_run(10000, 10, 10, 10)
	var friend := _hire("off_test_surgeon")  # personality ["loyal"]
	var greedy := _hire("off_test_boatswain")  # personality ["greedy"]

	_check(SkillsLib.talk(friend), "talk succeeds off cooldown")
	_check(int(GameState.officer_states[friend]["loyalty"]) == 51,
		"talk pays +1 (50 → 51)")
	_check(not SkillsLib.talk(friend), "the same day is inside the cooldown")
	_check(int(GameState.officer_states[friend]["talk_cd_day"]) == 20,
		"talk_cd_day = day + 10")
	GameState.day = 20
	_check(SkillsLib.talk(friend), "day 20 clears the 10-day cooldown")

	var gold_before := GameState.gold
	_check(SkillsLib.gift(friend), "gift succeeds off cooldown with 200g")
	_check(GameState.gold == gold_before - 200, "the gift costs exactly 200g")
	_check(int(GameState.officer_states[friend]["loyalty"]) == 51 + 3 + 1,
		"an honest/loyal officer gifts +3 (the +1 talk already landed)")
	_check(not SkillsLib.gift(friend), "the gift cooldown holds")
	GameState.day = 30
	_check(SkillsLib.gift(greedy), "the greedy officer accepts a gift")
	_check(int(GameState.officer_states[greedy]["loyalty"]) == 58,
		"a greedy officer gifts +8 (50 → 58)")
	_make_run(1000, 5, 10, 10)
	var poor := _hire("off_test_cook")
	GameState.gold = 150
	_check(not SkillsLib.gift(poor), "a short purse refuses the gift")
	_check(GameState.gold == 150, "a refused gift pays nothing")


# --- 14. The charisma loyalty multiplier (docs/50-* §4.5.4) -----------------

func _test_loyalty_multiplier() -> void:
	_make_run(10000, 10, 10, 10)
	var a := _hire("off_test_cook")
	_check(SkillsLib.cha_loyalty_multiplier() == 1, "CHA 10 multiplies ×1")
	_check(SkillsLib.adjust_loyalty(a, 5) == 55, "+5 at CHA 10 lands as +5")
	_make_run(10000, 10, 10, 100)
	var rich := _hire("off_test_cook")
	_check(SkillsLib.cha_loyalty_multiplier() == 3, "CHA 100 multiplies ×3")
	_check(SkillsLib.adjust_loyalty(rich, 5) == 65,
		"+5 at CHA 100 lands as +15 (the charisma gain multiplier)")
	_make_run(10000, 10, 10, 60)
	_check(SkillsLib.cha_loyalty_multiplier() == 2, "CHA 60 multiplies ×2")
	# Negative deltas are flat; the clamp holds both ends.
	_make_run(10000, 10, 10, 100)
	var b := _hire("off_test_cook")
	_check(SkillsLib.adjust_loyalty(b, -10) == 40, "−10 stays −10 at CHA 100")
	GameState.officer_states[b]["loyalty"] = 3
	_check(SkillsLib.adjust_loyalty(b, -50) == 0, "loyalty clamps at 0")
	GameState.officer_states[b]["loyalty"] = 99
	_check(SkillsLib.adjust_loyalty(b, 5) == 100, "loyalty clamps at 100")
	_check(SkillsLib.loyalty("off_nobody") == SkillsLib.LOYALTY_START,
		"an officer without state reads the start loyalty (50)")


# --- Harness (docs/90-* §13) ------------------------------------------------

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
