class_name Skills
extends RefCounted
## Phase-8 skill layer (docs/50-CHARACTER-AND-PROGRESSION.md §4.3, §4.5;
## docs/90-ARCHITECTURE.md §4: pure statics, no node references).
##
## Owns the 11-skill space (8 player + 3 officer-only), the usage-growth
## counters, paid training, the in-post officer contribution (§4.5.3),
## appointments against `data/officer_posts.json` (§4.5.2), the officer
## day-tick (growth clock + loyalty events, §4.5.4) and the loyalty actions.
##
## State ownership (§4.8 / `90-*` §8): the player's own values live in
## `GameState.player.skills` / `.skill_counters`; every employed officer's
## relation lives in `GameState.officer_states` — the officer CARD itself
## (`data/officers.json` v2) is save-independent canon and is only written by
## the growth rule (§4.3.2: +1 per 90 in-post sea-days), exactly as pinned.
##
## Dependency note: `character.gd` preloads THIS file (the KEYS table is
## single-sourced here), so this file must not preload it back — the three
## Character-backed reads (`current_level`, `attribute`, the session raise
## flag) go through a lazy `load()` at call time. A parse-time cycle is a
## GDScript error (verified on Godot 4.7).

## Player skills (docs/50-* §4.3): 8 keys, 0–100, start 0.
const KEYS: Array[String] = [
	"seamanship", "navigation", "swordplay", "gunnery", "appraisal",
	"negotiation", "cartography", "rumour",
]
## Officer-only skills (docs/50-* §4.3.2): carried by officer cards only.
const OFFICER_KEYS: Array[String] = ["medicine", "carpentry", "cooking"]

## Skill bounds.
const SKILL_MIN := 0
const SKILL_MAX := 100

## §4.3.1 growth thresholds: +1 per N uses (counter resets on award; counters
## stop counting at skill 100, §4.3.3).
const GROWTH_THRESHOLD := {
	"seamanship": 30,
	"navigation": 30,
	"swordplay": 1,
	"gunnery": 10,
	"appraisal": 20,
	"negotiation": 15,
	"cartography": 5,
	"rumour": 10,
}

## §4.3.4 paid training: one +1 costs `ceil(level × 60 × (1 − (INT−10)/200))`;
## a skill at ≥ 60 cannot be trained (usage growth still passes 60).
const TRAIN_BASE_FEE := 60.0
const TRAIN_INT_DIVISOR := 200.0
const TRAIN_CAP := 60

## §4.5.3 contribution: the ONE in-post officer's true value, derated
## `floor(value × 0.8)` while loyalty < 30, plus +5 on the native signature
## skill while loyalty ≥ 80. Captain posts feed their ship, never the player.
const POST_SKILL := {
	"pilot": "navigation",
	"boatswain": "seamanship",
	"gunner": "gunnery",
	"surgeon": "medicine",
	"carpenter": "carpentry",
	"cook": "cooking",
}
const CONTRIBUTION_DERATE := 0.8
const SIGNATURE_BONUS := 5

## §4.5.4 loyalty: 0–100, starts 50 at hire; every positive delta is
## multiplied by `1 + floor((CHA−10)/45)`; negative deltas are flat.
const LOYALTY_MIN := 0
const LOYALTY_MAX := 100
const LOYALTY_START := 50
const LOYALTY_DERATE_BELOW := 30
const LOYALTY_RESIGN_BELOW := 15
const LOYALTY_SIGNATURE_AT := 80
const CHA_LOYALTY_DIVISOR := 45.0

## Officer 4 actions (§4.5.4, `80-*`): talk/gift share the 10-day cooldown;
## the raise event swaps ±10 loyalty against a permanent ×1.25 wage.
const COOLDOWN_DAYS := 10
const TALK_GAIN := 1
const GIFT_COST := 200
const GIFT_BASE := 5
const GIFT_GREEDY := 8
const GIFT_HONEST := 3
const RAISE_WAGE_MULT := 1.25
const RAISE_ACCEPT_LOYALTY := 10
const RAISE_REFUSE_LOYALTY := -10

## §4.3.2 officer growth clock: +1 per 90 employed sea-days to the post's
## skill (idle bench → the native main skill), clamped at 100.
const OFFICER_GROWTH_DAYS := 90


# --- Reads (docs/50-* §4.8: stored player values; contribution at read time) -

## The player's own skill value for `key` (0 when never written).
static func skill(key: String) -> int:
	var value: Dictionary = GameState.player.get("skills", {})
	return clampi(int(value.get(key, SKILL_MIN)), SKILL_MIN, SKILL_MAX)


## §4.5.3: `player skill + the one in-post officer's true value`.
static func effective_skill(key: String) -> int:
	return skill(key) + officer_contribution(key)


## The contribution of the single officer holding the post that maps to
## `key` (0 when the post is vacant — one person per post, no stacking;
## `ROLE_STAT_BONUS`-style flat bonuses are deleted, §4.5.3).
static func officer_contribution(key: String) -> int:
	var post_id := ""
	for candidate in POST_SKILL:
		if str(POST_SKILL[candidate]) == key:
			post_id = str(candidate)
			break
	if post_id.is_empty():
		return 0
	var holder := post_holder(post_id)
	if holder.is_empty():
		return 0
	var officer: Dictionary = DataLoader.get_officer(holder)
	if officer.is_empty():
		return 0
	var value := int(officer.get("skills", {}).get(key, SKILL_MIN))
	var loyal := loyalty(holder)
	if loyal < LOYALTY_DERATE_BELOW:
		value = int(floor(value * CONTRIBUTION_DERATE))
	if loyal >= LOYALTY_SIGNATURE_AT \
			and str(officer.get("main_skill", "")) == key:
		value += SIGNATURE_BONUS
	return value


# --- Usage growth (docs/50-* §4.3.1–§4.3.3) ---------------------------------

## The player's `skill_counters` block (the §4.8 save shape; missing keys
## read as 0).
static func counters() -> Dictionary:
	return GameState.player.get("skill_counters", {})


## Adds `uses` to the usage counter of `key` (§4.3.3). Counters stop counting
## at skill 100: a maxed skill accrues nothing and its counter stays 0.
## The award itself is the caller's `maybe_award` — the two halves of the rule
## stay separable for the storm-survival bypass (immediate award, §4.3.3).
static func note_usage(key: String, uses: int = 1) -> void:
	if not (key in KEYS) or uses <= 0:
		return
	var p: Dictionary = GameState.player
	var counter: Dictionary = p.get("skill_counters", {})
	if skill(key) >= SKILL_MAX:
		counter[key] = 0
	else:
		counter[key] = int(counter.get(key, 0)) + uses
	p["skill_counters"] = counter


## The §4.3.1 threshold of `key` (+1 per N uses; 0 for an unknown key).
static func growth_threshold(key: String) -> int:
	return int(GROWTH_THRESHOLD.get(key, 0))


## Awards the usage growth for `key`: when the counter reached the threshold
## and the skill is below 100, skill +1 and the counter resets (§4.3.3).
static func maybe_award(key: String) -> void:
	if not (key in KEYS):
		return
	var p: Dictionary = GameState.player
	var counter: Dictionary = p.get("skill_counters", {})
	if skill(key) >= SKILL_MAX:
		counter[key] = 0
		p["skill_counters"] = counter
		return
	if int(counter.get(key, 0)) >= growth_threshold(key):
		var skills: Dictionary = p.get("skills", {})
		skills[key] = clampi(skill(key) + 1, SKILL_MIN, SKILL_MAX)
		p["skills"] = skills
		counter[key] = 0
		p["skill_counters"] = counter


## One sea ledger day (§4.3.1: seamanship and navigation grow per sea-day;
## `20-*` §4.5 step 1 calls this once per day at sea). Completes the cycle —
## note, then award, then run the officer day-tick (§4.3.2 growth clock and
## §4.5.4 loyalty events).
static func note_sea_day() -> void:
	for key in ["seamanship", "navigation"]:
		note_usage(key)
		maybe_award(key)
	officer_day_tick()


# --- Paid training (docs/50-* §4.3.4) ---------------------------------------

## `ceil(level × 60 × (1 − (INT−10)/200))` — the player's level and the
## player's INT, identical for the player's own skill and an officer's
## (the §5 worked example: level 1, INT 17 → ceil(57.9) = 58). Computed in
## exact integer arithmetic (`level × 3 × (210 − INT) / 10`, the closed form
## multiplied out) so float noise can never bump an integral fee up a gold.
static func training_price(_key: String) -> int:
	var character := _character_lib()
	var level := int(character.current_level())
	var intellect := int(character.attribute("intellect"))
	var product := level * 3 * (210 - intellect)
	return (product + 9) / 10  # integer ceil(product / 10)


## Training is refused at the §4.3.4 cap (skill ≥ 60) or when the purse is
## short (§6: the button shows the price instead).
static func can_train(key: String) -> bool:
	if skill(key) >= TRAIN_CAP:
		return false
	return GameState.gold >= training_price(key)


## Pays the fee and raises `key` by one, capped at the training cap 60
## (usage growth can still pass 60). State untouched when refused.
static func train(key: String) -> bool:
	if not (key in KEYS) or not can_train(key):
		return false
	GameState.add_gold(-training_price(key))
	var p: Dictionary = GameState.player
	var skills: Dictionary = p.get("skills", {})
	skills[key] = clampi(skill(key) + 1, SKILL_MIN, TRAIN_CAP)
	p["skills"] = skills
	return true


# --- Officer post helpers (docs/50-* §4.5.2, data/officer_posts.json) -------

## Employed officer ids whose `officer_states.post_id == post_id`.
## At most one per flagship post (appoint enforces it); a captain post is
## one holder per `ship_id`.
static func officers_in_post(post_id: String) -> Array[String]:
	var out: Array[String] = []
	for officer_id in GameState.player.get("officers", []):
		var state: Dictionary = _states().get(str(officer_id), {})
		if str(state.get("post_id", "")) == post_id:
			out.append(str(officer_id))
	return out


## The first holder of `post_id`, or "" when vacant.
static func post_holder(post_id: String) -> String:
	var holders := officers_in_post(post_id)
	return holders[0] if not holders.is_empty() else ""


## Appoints an employed officer to `post_id` ("" = back to idle), checking
## the post's prereqs straight from `data/officer_posts.json` (§4.5.2:
## flagship = the matching skill ≥ 20 — captain = seamanship ≥ 25 ∧
## courage ≥ 30, with `courage` read from the officer's attributes).
## One person per post (per ship for the captain seat). Prereqs apply only
## to taking a post — unassigning is always allowed.
static func appoint(officer_id: String, post_id: String, ship_id: String = "") -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty() or not _employed(officer_id):
		return false
	var state := _ensure_state(officer_id)
	if post_id.is_empty():
		state["post_id"] = ""
		state["ship_id"] = ""
		return true
	var post: Dictionary = DataLoader.get_officer_post(post_id)
	if post.is_empty():
		return false
	for req_key in post.get("prereq", {}):
		var value := int(officer.get("skills", {}).get(req_key,
			officer.get("attributes", {}).get(req_key, 0)))
		if value < int(post["prereq"][req_key]):
			return false
	# Occupancy: flagship seats are unique; the captain seat is unique per ship.
	var wanted_ship := ship_id if str(post.get("slot_type", "")) == "captain" else ""
	for other_id in GameState.player.get("officers", []):
		if str(other_id) == officer_id:
			continue
		var other: Dictionary = _states().get(str(other_id), {})
		if str(other.get("post_id", "")) != post_id:
			continue
		if str(post.get("slot_type", "")) != "captain" \
				or str(other.get("ship_id", "")) == wanted_ship:
			return false
	state["post_id"] = post_id
	state["ship_id"] = wanted_ship
	return true


# --- Officer day tick (docs/50-* §4.3.2 growth, §4.5.4 loyalty) -------------

## One sea ledger day for the whole roster (called by [method note_sea_day]):
## +1 `sea_days` per employed officer; each multiple of 90 days pays +1 to
## the post's skill (idle/captain → the native main skill), clamped at 100,
## on the officer card. Loyalty < 15 resigns (roster + state entry cleared —
## the post frees with it); loyalty < 30 raises the session raise-demand flag
## (the §4.5.4 event; `Character.pending_raise`, never saved).
static func officer_day_tick() -> void:
	var roster: Array = (GameState.player.get("officers", []) as Array).duplicate()
	for officer_id in roster:
		var id := str(officer_id)
		var state := _ensure_state(id)
		state["sea_days"] = int(state.get("sea_days", 0)) + 1
		if int(state.get("loyalty", LOYALTY_START)) < LOYALTY_RESIGN_BELOW:
			_resign(id)
			continue
		if int(state.get("loyalty", LOYALTY_START)) < LOYALTY_DERATE_BELOW:
			_character_lib().set_pending_raise(true)
		if int(state["sea_days"]) % OFFICER_GROWTH_DAYS == 0:
			_grow_officer_skill(id, str(state.get("post_id", "")))


## The §4.3.2 growth award: the post's skill while in post (the §2.7 post →
## pipeline map; a captain seat grows the native main skill — captains feed
## their ship, not the player), else the native main skill on the bench.
## The officer card is canon-with-growth: the +1 lands on the loaded record
## (save persistence of the grown value is W6-C's officer_states scope).
static func _grow_officer_skill(officer_id: String, post_id: String) -> void:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		return
	var growth_key := str(POST_SKILL.get(post_id, officer.get("main_skill", "")))
	if growth_key.is_empty():
		return
	var skills: Dictionary = officer.get("skills", {})
	skills[growth_key] = clampi(int(skills.get(growth_key, 0)) + 1,
		SKILL_MIN, SKILL_MAX)
	officer["skills"] = skills


## The §4.5.4 resign path: roster + state entry cleared (a re-hire starts
## fresh at 50 — the state is gone, not archived).
static func _resign(officer_id: String) -> void:
	var p: Dictionary = GameState.player
	var officers: Array = p.get("officers", [])
	var index := officers.find(officer_id)
	if index >= 0:
		officers.remove_at(index)
	p["officers"] = officers
	_states().erase(officer_id)


# --- Loyalty (docs/50-* §4.5.4) ---------------------------------------------

## The officer's loyalty (the §4.8 state block; the start value when the
## entry has not been created yet — call sites are employed officers).
static func loyalty(officer_id: String) -> int:
	var state: Dictionary = _states().get(officer_id, {})
	return int(state.get("loyalty", LOYALTY_START))


## Applies a delta through the §4.5.4 rules: every **positive** delta is
## multiplied by `1 + floor((CHA−10)/45)`, negative deltas are flat; the
## result clamps to 0–100. Returns the new value (or the old one when the
## officer is not employed).
static func adjust_loyalty(officer_id: String, delta: int) -> int:
	if not _employed(officer_id):
		return loyalty(officer_id)
	var state := _ensure_state(officer_id)
	if delta > 0:
		delta *= cha_loyalty_multiplier()
	var value := clampi(int(state.get("loyalty", LOYALTY_START)) + delta,
		LOYALTY_MIN, LOYALTY_MAX)
	state["loyalty"] = value
	return value


## The charisma gain multiplier `1 + floor((CHA−10)/45)` (§4.5.4):
## CHA 10 → ×1, CHA 100 → ×3.
static func cha_loyalty_multiplier() -> int:
	var charisma := int(_character_lib().attribute("charisma"))
	return 1 + int(floor((charisma - 10) / CHA_LOYALTY_DIVISOR))


## Talk: loyalty +1 (charisma-multiplied), 10-day cooldown via
## `talk_cd_day`. False on cooldown or when not employed.
static func talk(officer_id: String) -> bool:
	if not _employed(officer_id):
		return false
	var state := _ensure_state(officer_id)
	if GameState.day < int(state.get("talk_cd_day", 0)):
		return false
	adjust_loyalty(officer_id, TALK_GAIN)
	state["talk_cd_day"] = GameState.day + COOLDOWN_DAYS
	return true


## Gift (200g): +5, greedy 贪婪 +8, honest 诚实 / loyal 忠诚 +3 (§4.5.4),
## 10-day cooldown via `gift_cd_day`. False when not employed, on cooldown
## or with a short purse — nothing is paid in those cases.
static func gift(officer_id: String) -> bool:
	if not _employed(officer_id):
		return false
	var state := _ensure_state(officer_id)
	if GameState.day < int(state.get("gift_cd_day", 0)):
		return false
	if GameState.gold < GIFT_COST:
		return false
	GameState.add_gold(-GIFT_COST)
	var personality: Array = DataLoader.get_officer(officer_id).get(
		"personality", [])
	var amount := GIFT_BASE
	if "greedy" in personality:
		amount = GIFT_GREEDY
	elif "honest" in personality or "loyal" in personality:
		amount = GIFT_HONEST
	adjust_loyalty(officer_id, amount)
	state["gift_cd_day"] = GameState.day + COOLDOWN_DAYS
	return true


## The raise event, accepted: `wage_mult` × 1.25 permanent, loyalty +10.
static func accept_raise(officer_id: String) -> bool:
	if not _employed(officer_id):
		return false
	var state := _ensure_state(officer_id)
	state["wage_mult"] = float(state.get("wage_mult", 1.0)) * RAISE_WAGE_MULT
	adjust_loyalty(officer_id, RAISE_ACCEPT_LOYALTY)
	_character_lib().set_pending_raise(false)
	return true


## The raise event, refused: loyalty −10 (flat — negative deltas skip the
## charisma multiplier, §4.5.4).
static func refuse_raise(officer_id: String) -> bool:
	if not _employed(officer_id):
		return false
	adjust_loyalty(officer_id, RAISE_REFUSE_LOYALTY)
	_character_lib().set_pending_raise(false)
	return true


# --- State helpers ----------------------------------------------------------

## The `officer_states` block (`90-*` §8: a top-level save block owned by
## the run; entries `{loyalty, sea_days, post_id, ship_id, talk_cd_day,
## gift_cd_day, defeats, wage_mult}`).
static func _states() -> Dictionary:
	return GameState.officer_states


## Creates the seeded state entry for an employed officer when missing
## (loyalty 50, idle, fresh cooldowns and clocks). Never creates one for an
## un-employed id — the callers guard on employment first.
static func _ensure_state(officer_id: String) -> Dictionary:
	var states := _states()
	if not states.has(officer_id):
		states[officer_id] = {
			"loyalty": LOYALTY_START,
			"sea_days": 0,
			"post_id": "",
			"ship_id": "",
			"talk_cd_day": 0,
			"gift_cd_day": 0,
			"defeats": 0,
			"wage_mult": 1.0,
		}
	return states[officer_id]


## Employment check without a parse-time Character preload (see the header):
## the roster is `player.officers`, the §4.8 id list.
static func _employed(officer_id: String) -> bool:
	return officer_id in (GameState.player.get("officers", []) as Array)


## `scripts/player/character.gd`, loaded lazily: this file is preloaded BY
## character.gd (the KEYS table), so a parse-time preload back would be a
## cyclic reference (a GDScript error). Everything this file needs from
## Character is static — a call-time load resolves it.
static func _character_lib() -> GDScript:
	return load("res://scripts/player/character.gd")
