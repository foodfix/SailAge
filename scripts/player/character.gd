class_name Character
extends RefCounted
## Player Person, XP/level/`alloc_pending`, officers and reputation
## (docs/50-CHARACTER-AND-PROGRESSION.md §4.1–§4.6, §4.8, §5).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): every function
## is static and reads/mutates the `GameState.player` save block through the
## singleton, so the formulas are unit-testable from headless GDScript.
##
## The player block shape is the v9 Person block (docs/50-* §4.8):
## `{nation_id, background_id, attributes{5}, skills{8}, skill_counters{8},
## alloc_pending, xp, level, officers[], reputation, profit_by_nation,
## profit_rep_awarded, equipment}` — `autopilot` stays absent until W5 writes
## it. This file never adds transient keys to the block (the level-up toast
## flag is a class static, see [member pending_levelup]).
##
## Skill values/counters and the officer contribution live in
## `scripts/player/skills.gd` (`SkillsLib` below — preloaded, the KEYS table
## is single-sourced there; skills.gd must never preload this file back).

## The skill layer (docs/50-* §4.3): keys, thresholds, contribution, loyalty.
const SkillsLib := preload("res://scripts/player/skills.gd")

## Locked constants (docs/50-* §4.1–§4.5).
const OFFICER_MAX := 12
const LEVEL_CAP := 20
## `level = floor(sqrt(xp / XP_LEVEL_UNIT)) + 1` (docs/50-* §4.4).
const XP_LEVEL_UNIT := 50.0
## Base value of every attribute at new game (docs/50-* §4.2).
const BASE_ATTRIBUTE := 10
## Attribute bounds (docs/50-* §4.4: allocation clamps to [1, 100]; every
## attribute/skill write clamps everywhere, §6).
const ATTR_MIN := 1
const ATTR_MAX := 100
## Flat +5 nation bonus on one attribute and one signature skill
## (docs/50-* §4.2.2; the pair per nation lives in `data/nations.json`
## `bonus_attribute`/`bonus_skill` — nothing hardcoded here).
const NATION_BONUS_AMOUNT := 5
## Background bonuses (docs/50-* §4.1 step ①): one attribute +3, one skill +5,
## from `data/backgrounds.json`.
const BACKGROUND_ATTR_BONUS := 3
const BACKGROUND_SKILL_BONUS := 5

## Attribute order used by the character card / save block (docs/50-* §4.2).
const ATTRIBUTES: Array[String] = [
	"constitution", "intellect", "charisma", "courage", "luck",
]
## The 8 player skills, single-sourced in skills.gd (docs/50-* §4.3).
const SKILL_KEYS: Array[String] = SkillsLib.KEYS

## Creation free points (docs/50-* §4.1 step ②): attributes +5 total and
## skills +3 total, single-item cap +3, must spend all before confirm.
const ATTR_ALLOC_TOTAL := 5
const SKILL_ALLOC_TOTAL := 3
const ALLOC_ITEM_CAP := 3

## Creation extremes (docs/50-* §4.1 step 4, normative): the closed forms
## `10 + 5 (nation) + 3 (background) + 3 (cap) = 21` and
## `0 + 5 + 5 + 3 = 13`.
const CREATION_ATTR_MAX := 21
const CREATION_SKILL_MAX := 13

## Level-up allocation (docs/50-* §4.4): +2 pending points per level gained,
## persisted in the player block; the toast flag below stays session-transient.
const ALLOC_PER_LEVEL := 2

## Signing cost / loyalty-gain price multiplier (docs/50-* §4.2.1 charisma row,
## §4.5.2): `clamp(1 − (CHA−10)/200, 0.5, 1.0)` — CHA 10 → ×1.0, 60 → ×0.75,
## 100 → ×0.5. Also applied to rumour purchases and bounty pinpoints (their
## base prices live in `30-*`/`70-*`; this doc owns the multiplier).
const CHA_PRICE_DIVISOR := 200.0
const CHA_PRICE_MULT_MIN := 0.5

## Reputation is an integer −100…+100 per nation (docs/50-* §4.6).
const REPUTATION_MIN := -100
const REPUTATION_MAX := 100

## §4.6 "+1 per 1,000g cumulative profit sold at a nation's ports". The two
## player-block keys back the accumulator and must survive save/load (§4.8) —
## see [method add_profit_reputation].
const PROFIT_PER_REP := 1000
const PROFIT_KEY := "profit_by_nation"
const PROFIT_AWARDED_KEY := "profit_rep_awarded"

## Speed bonus clamp from docs/50-* §4.3.1 / docs/20-* §4.4: `skill/300`,
## clamp [0, +0.30] (the old `(S−10)/100` clamp [−0.10, +0.20] is deleted).
const SPEED_BONUS_MIN := 0.0
const SPEED_BONUS_MAX := 0.30
const SPEED_BONUS_DIVISOR := 300.0

## Set by [method award_xp] when a level was gained. The toast itself belongs
## to the HUD; the panel/HUD can read this flag and call
## [method consume_pending_levelup] to render the level-up banner. It is a
## class static rather than a `player` key so the save block keeps exactly
## the §4.8 shape; a still-pending toast is not worth persisting
## (docs/50-* §4.4, §4.8).
static var pending_levelup: bool = false

## Set by the officer day-tick (`SkillsLib.officer_day_tick`) while any
## employed officer's loyalty sits below 30 — the §4.5.4 raise-demand event.
## Session-transient like [member pending_levelup] (the decision lives in
## `Skills.accept_raise`/`refuse_raise`; never saved, docs/50-* §4.8).
static var pending_raise: bool = false


## The raise-demand flag setters used by `Skills.officer_day_tick` (this file
## is lazily loaded there — a parse-time cycle is a GDScript error — and
## statics are called through the loaded script, not `.set()`).
static func set_pending_raise(value: bool) -> void:
	pending_raise = value


# --- Person attributes (docs/50-* §4.2) -------------------------------------

## The player's own attribute value for `key`, clamped to 1–100.
static func attribute(key: String) -> int:
	var values: Dictionary = _player().get("attributes", {})
	# No read-side clamp: 1–100 is a WRITE-side rule (allocate/starting_person
	# clamp); formulas consume the stored value verbatim so the §4.2 pinned
	# formulas stay exact at fixture boundaries.
	return int(values.get(key, BASE_ATTRIBUTE))


## A copy of the player's five attributes (the §4.8 block; missing keys read
## as the base 10).
static func attributes() -> Dictionary:
	var out: Dictionary = {}
	for key in ATTRIBUTES:
		out[key] = attribute(key)
	return out


# --- New-game Person (docs/50-* §4.1) ---------------------------------------

## Builds the fresh §4.1 player block: attributes base 10 + the nation's
## `bonus_attribute` +5 + the background's attribute +3 + `attr_alloc`;
## skills 0 + the nation's `bonus_skill` +5 + the background's skill +5 +
## `skill_alloc`; `skill_counters` all 0, `alloc_pending` 0, xp 0 / level 1,
## no officers, the §4.6 reputation map, the two profit accumulators empty
## and the §4.8 equipment block. `autopilot` is deliberately absent (§4.8:
## present only while an appointed voyage is active — W5 writes it).
##
## Free-point allocations are capped here (§4.1 step ②: per-item +3, totals
## +5/+3) so a caller cannot break the §4.1 step-4 creation extremes
## (attribute ≤ 21, skill ≤ 13). An unknown nation/background id simply
## contributes no bonus.
static func starting_person(nation_id: String, background_id: String,
		attr_alloc: Dictionary = {}, skill_alloc: Dictionary = {}) -> Dictionary:
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	var background: Dictionary = DataLoader.get_background(background_id)
	var bonus_attribute := str(nation.get("bonus_attribute", ""))
	var bonus_skill := str(nation.get("bonus_skill", ""))

	var attributes: Dictionary = {}
	for key in ATTRIBUTES:
		var value := BASE_ATTRIBUTE
		if key == bonus_attribute:
			value += NATION_BONUS_AMOUNT
		value += _capped_alloc(attr_alloc, key, ATTR_ALLOC_TOTAL, attr_alloc_total(attr_alloc))
		attributes[key] = clampi(value, ATTR_MIN, ATTR_MAX)

	var skills: Dictionary = {}
	var bg_skill_key := str(
		(background.get("skill_bonus", {}) as Dictionary).keys()[0]
	) if not (background.get("skill_bonus", {}) as Dictionary).is_empty() else ""
	for key in SKILL_KEYS:
		var value := 0
		if key == bonus_skill:
			value += NATION_BONUS_AMOUNT
		if key == bg_skill_key:
			value += BACKGROUND_SKILL_BONUS
		value += _capped_alloc(skill_alloc, key, SKILL_ALLOC_TOTAL, skill_alloc_total(skill_alloc))
		skills[key] = clampi(value, 0, SkillsLib.SKILL_MAX)
	# The background's attribute +3 lands on exactly the one key the data names.
	var bg_attr_key := str(
		(background.get("attribute_bonus", {}) as Dictionary).keys()[0]
	) if not (background.get("attribute_bonus", {}) as Dictionary).is_empty() else ""
	if not bg_attr_key.is_empty() and attributes.has(bg_attr_key):
		attributes[bg_attr_key] = clampi(
			int(attributes[bg_attr_key]) + BACKGROUND_ATTR_BONUS,
			ATTR_MIN, ATTR_MAX)

	var reputation: Dictionary = {}
	for entry in DataLoader.nations_list:
		reputation[str(entry.get("id", ""))] = 0
	if not nation.is_empty():
		reputation[nation_id] = int(nation.get("start_reputation", 0))

	return {
		"nation_id": nation_id,
		"background_id": background_id,
		"attributes": attributes,
		"skills": skills,
		"skill_counters": _zero_counters(),
		"alloc_pending": 0,
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": reputation,
		PROFIT_KEY: {},
		PROFIT_AWARDED_KEY: {},
		"equipment": {"weapon": "", "armor": ""},
	}


## The total free points in an allocation draft (§4.1 step ② bookkeeping).
static func attr_alloc_total(alloc: Dictionary) -> int:
	return _alloc_sum(alloc)


static func skill_alloc_total(alloc: Dictionary) -> int:
	return _alloc_sum(alloc)


static func _alloc_sum(alloc: Dictionary) -> int:
	var total := 0
	for key in alloc:
		total += maxi(0, int(alloc[key]))
	return total


## One item of a creation draft, capped per-item at +3 and (when the whole
## draft exceeds its total budget) trimmed proportionally to the budget —
## the creation UI enforces "spend all"; this keeps any caller inside §4.1.
static func _capped_alloc(alloc: Dictionary, key: String, budget: int,
		draft_total: int) -> int:
	var requested := maxi(0, int(alloc.get(key, 0)))
	var capped := mini(requested, ALLOC_ITEM_CAP)
	if draft_total > budget:
		capped = mini(capped, requested - (draft_total - budget))
	return maxi(0, capped)


static func _zero_counters() -> Dictionary:
	var counters: Dictionary = {}
	for key in SKILL_KEYS:
		counters[key] = 0
	return counters


# --- Legacy stat shims (docs/50-* §4.2.3 migration) -------------------------
#
# The four-stat "leadership/seamanship/combat/navigation/luck" block is
# REMOVED from the save (v9, no migration) — but un-owned consumers
# (`battle_sim.gd`, `duel.gd`, the S14/S18 panels) still call these names.
# Each shim reads the new model through one table:
#   leadership → attribute charisma; combat → skill swordplay;
#   seamanship/navigation → the same-named skills; luck → attribute luck.
# W5/W6 retire the panel callers; W3-C rewires the combat callers to Skills.

## The legacy-name → new-model map (§4.2.3 migration table).
const LEGACY_STAT_MAP := {
	"leadership": "charisma",
	"combat": "swordplay",
	"seamanship": "seamanship",
	"navigation": "navigation",
	"luck": "luck",
}

## The Phase-1 role table, kept only so un-owned panel code keeps parsing;
## nothing in the new model reads it (§4.5.3: flat role bonuses are deleted).
const ROLE_STAT_BONUS := {
	"navigator": {"navigation": 10},
	"boatswain": {"seamanship": 10},
	"gunner": {"gunnery": 10},
}


## Legacy read: the new-model value behind an old stat name (0 for an unknown
## name). Officers no longer add anything here (§4.5.3 — contribution is
## per-post and lives in `SkillsLib.officer_contribution`).
static func base_stat(stat_name: String) -> int:
	var mapped := str(LEGACY_STAT_MAP.get(stat_name, ""))
	if mapped.is_empty():
		return 0
	if mapped in ATTRIBUTES:
		return attribute(mapped)
	return SkillsLib.skill(mapped)


## Legacy read: `base_stat` (the officer term is gone; see the shim header).
static func effective_stat(stat_name: String) -> int:
	return base_stat(stat_name)


## Legacy: the officer contribution to a legacy stat — always 0 (§4.5.3).
static func officer_bonus(_stat_name: String) -> int:
	return 0


## Legacy twin of [method officer_bonus] (the "without this officer" diff).
static func officer_bonus_excluding(_stat_name: String, _officer_id: String) -> int:
	return 0


## docs/50-* §4.3.1 / `20-*` §4.4: `skill/300`, clamped [0, +0.30].
static func speed_bonus() -> float:
	return speed_bonus_for(SkillsLib.effective_skill("seamanship"))


## [method speed_bonus] for an explicit effective seamanship value — the pure
## formula, so derived-effect rows can difference "with" against "without"
## one officer without a second copy of the rule.
static func speed_bonus_for(seamanship: int) -> float:
	var raw := seamanship / SPEED_BONUS_DIVISOR
	return clampf(raw, SPEED_BONUS_MIN, SPEED_BONUS_MAX)


## docs/50-* §4.3.1 / `20-*` §4.11: `48 + floor(navigation skill / 12)`
## (the Phase-1 `48 + floor((nav − 10)/10)` is migrated, §4.2.3).
static func sighting_radius() -> int:
	return sighting_radius_for(SkillsLib.effective_skill("navigation"))


## [method sighting_radius] for an explicit effective navigation value.
static func sighting_radius_for(navigation: int) -> int:
	return 48 + int(floor(navigation / 12.0))


## docs/50-* §4.2.1 charisma row: desertion × `(1 − (CHA−10)/200)` — the
## formula is unchanged from the leadership era; only the source moved.
## The doc gives no lower clamp; a negative multiplier would turn a loss into
## a gain, so this implementation floors it at 0 (no desertion possible).
static func desertion_multiplier() -> float:
	return loss_multiplier_for(attribute("charisma"))


## [method desertion_multiplier] for an explicit charisma value (pure formula).
static func loss_multiplier_for(charisma: int) -> float:
	return maxf(0.0, 1.0 - (charisma - BASE_ATTRIBUTE) / 200.0)


## Same formula and clamp as [method desertion_multiplier] (docs/50-* §4.2.1).
static func mutiny_multiplier() -> float:
	return loss_multiplier_for(attribute("charisma"))


## docs/50-* §4.2.1 luck row: storm damage × `(1 − luck/250)` — CONTINUOUS
## (the Phase-1 `luck ≥ 50 → ×0.75` step is deleted; player-only).
static func storm_damage_multiplier() -> float:
	return 1.0 - attribute("luck") / 250.0


## docs/50-* §4.2.1: storm chance `× (1 − luck / 400)` (unchanged).
static func storm_chance_multiplier() -> float:
	return 1.0 - attribute("luck") / 400.0


## The charisma price multiplier `clamp(1 − (CHA−10)/200, 0.5, 1.0)`
## (§4.2.1): applied to the officer signing fee (§4.5.2), rumour purchases
## and bounty pinpoints (`70-*` §4.5 owns those base prices).
static func charisma_price_multiplier() -> float:
	return clampf(1.0 - (attribute("charisma") - BASE_ATTRIBUTE) / CHA_PRICE_DIVISOR,
		CHA_PRICE_MULT_MIN, 1.0)


# --- XP, levels & allocation (docs/50-* §4.4) -------------------------------

## `floor(sqrt(xp / 50)) + 1`, capped at 20.
static func level_for_xp(xp: int) -> int:
	var value := int(floor(sqrt(maxi(xp, 0) / XP_LEVEL_UNIT))) + 1
	return clampi(value, 1, LEVEL_CAP)


## Inverse of [method level_for_xp]: XP required to *reach* `level`.
## Level 1 = 0 XP; level 20 = 18050 XP (docs/50-* §5).
static func xp_for_level(level: int) -> int:
	var target := clampi(level, 1, LEVEL_CAP)
	return int(XP_LEVEL_UNIT) * (target - 1) * (target - 1)


static func current_xp() -> int:
	return int(_player().get("xp", 0))


static func current_level() -> int:
	# Derivation wins over the stored cache (docs/50-* §4.8: "stored value is a
	# cache; derivation wins on mismatch"); the card therefore can never show
	# a level that disagrees with the XP it prints next to it.
	return level_for_xp(current_xp())


## XP still needed for the next level, or −1 at the cap (the card hides the row).
static func xp_to_next_level() -> int:
	var xp := current_xp()
	var level := level_for_xp(xp)
	if level >= LEVEL_CAP:
		return -1
	return xp_for_level(level + 1) - xp


## The persisted free-point counter (docs/50-* §4.4/§4.8: `alloc_pending`).
static func alloc_pending() -> int:
	return maxi(0, int(_player().get("alloc_pending", 0)))


## Adds XP and applies the §4.4 level rule. Non-positive amounts are ignored
## (a loss-making sale awards 0 XP and must not touch the level cache).
##
## On each level gained: `alloc_pending += 2` (the Phase-1 auto-grant of
## +1 seamanship / +1 nation stat is deleted, §4.4). Gaining several levels
## at once applies the grant once per level, matching "on each level-up";
## past the level cap no further points are granted (the derivation clamps).
static func award_xp(amount: int) -> void:
	if amount <= 0:
		return
	var p: Dictionary = _player()
	if p.is_empty():
		push_error("Character.award_xp: GameState.player is empty")
		return
	var before := level_for_xp(int(p.get("xp", 0)))
	p["xp"] = int(p.get("xp", 0)) + amount
	var after := level_for_xp(int(p["xp"]))
	p["level"] = after
	var gained := after - before
	if gained <= 0:
		return
	p["alloc_pending"] = alloc_pending() + ALLOC_PER_LEVEL * gained
	pending_levelup = true
	# Toast + badge rendering lands with the W6 UI (`char.level_up.alloc`).
	print("Character: level up to %d (xp %d, alloc_pending %d)"
		% [after, int(p["xp"]), int(p["alloc_pending"])])


## Reads and clears the pending-level-up flag; true exactly once per award.
static func consume_pending_levelup() -> bool:
	var was_pending := pending_levelup
	pending_levelup = false
	return was_pending


## docs/50-* §4.4 locked profit-XP rule:
## per-unit profit = max(0, sell_price − floor(base_price × 0.7)),
## profit = qty × per-unit, XP = floor(profit / 100).
static func add_profit_xp(sell_price: int, base_price: int, qty: int) -> void:
	var per_unit := maxi(0, sell_price - int(floor(base_price * 0.7)))
	var profit := maxi(qty, 0) * per_unit
	award_xp(int(floor(profit / 100.0)))


## The §4.4 allocation draft: `{attribute_key: +n}`. Accepted only when every
## key is a real attribute, every amount is positive, the total fits the
## pending counter AND no attribute would pass 100 — a draft that would
## overflow any attribute is refused whole (the caller reports it; points
## are never partially spent, §4.4/§6). On success the attributes move and
## the spent points leave `alloc_pending`.
static func allocate(draft: Dictionary) -> bool:
	if draft.is_empty():
		return false
	var pending := alloc_pending()
	var total := 0
	for key in draft:
		if not (key in ATTRIBUTES):
			return false
		var amount := int(draft[key])
		if amount <= 0:
			return false
		total += amount
		if attribute(key) + amount > ATTR_MAX:
			return false
	if total > pending:
		return false
	var p: Dictionary = _player()
	var values: Dictionary = p.get("attributes", {})
	for key in draft:
		values[key] = clampi(int(values.get(key, BASE_ATTRIBUTE))
			+ int(draft[key]), ATTR_MIN, ATTR_MAX)
	p["attributes"] = values
	p["alloc_pending"] = pending - total
	return true


# --- Officers (docs/50-* §4.5) ----------------------------------------------

static func employed_officers() -> Array:
	var officers: Array = _player().get("officers", [])
	return officers


static func officer_count() -> int:
	return employed_officers().size()


static func is_employed(officer_id: String) -> bool:
	return officer_id in employed_officers()


## The §4.2.1 charisma price multiplier applied to the one-time signing cost
## `ceil(wage_daily × 10)` (docs/50-* §4.5.2). Computed in exact integer
## arithmetic (`wage × 10 × (210 − CHA) / 200` after the multiplier's clamps)
## so float noise can never bump a boundary fee up a whole gold.
static func recruit_cost(officer_id: String) -> int:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		return 0
	# multiplier = clamp(1 − (CHA−10)/200, 0.5, 1.0) → numerator ∈ [100, 200].
	var numerator := clampi(210 - attribute("charisma"), 100, 200)
	var product := int(officer.get("wage_daily", 0)) * 10 * numerator
	return (product + 199) / 200  # integer ceil(product / 200)


## True when the officer exists, is not already aboard, there is roster room
## (OFFICER_MAX = 12, §4.5.2) and the signing cost is affordable — the §6
## edge rule keeps the recruit button disabled (with the price shown) when
## gold is short.
static func can_recruit(officer_id: String) -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		return false
	if is_employed(officer_id):
		return false
	if officer_count() >= OFFICER_MAX:
		return false
	return GameState.gold >= recruit_cost(officer_id)


## Adds the officer to `player.officers` and pays the signing cost (§4.5.5).
## Seeds the §4.8/`90-*` §8 `officer_states` entry: loyalty 50, fresh clocks,
## idle (`post_id = ""`), `wage_mult` 1.0. Returns false (state untouched)
## whenever [method can_recruit] is false.
static func recruit(officer_id: String) -> bool:
	if not can_recruit(officer_id):
		return false
	var cost := recruit_cost(officer_id)
	GameState.add_gold(-cost)
	var p: Dictionary = _player()
	var officers: Array = p.get("officers", [])
	officers.append(officer_id)
	p["officers"] = officers
	GameState.officer_states[officer_id] = {
		"loyalty": SkillsLib.LOYALTY_START,
		"sea_days": 0,
		"post_id": "",
		"ship_id": "",
		"talk_cd_day": 0,
		"gift_cd_day": 0,
		"defeats": 0,
		"wage_mult": 1.0,
	}
	print("Character: recruited %s for %dg" % [officer_id, cost])
	return true


## Removes the officer; no severance (docs/50-* §4.5.5). The state entry is
## cleared with the roster row, which also frees any post the officer held
## (the post is derived from the state, §4.8) and resets a re-hire to 50.
static func dismiss(officer_id: String) -> bool:
	var p: Dictionary = _player()
	var officers: Array = p.get("officers", [])
	var index := officers.find(officer_id)
	if index < 0:
		return false
	officers.remove_at(index)
	p["officers"] = officers
	GameState.officer_states.erase(officer_id)
	print("Character: dismissed %s" % officer_id)
	return true


## Σ `wage_daily × wage_mult` for the daily ledger (docs/50-* §4.5.2; the
## ×1.25 raise event lives in the §4.5.4 `wage_mult`). Officer skills,
## loyalty and posts live in `SkillsLib`.
static func officer_wages() -> int:
	var total := 0
	for officer_id in employed_officers():
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		var mult := 1.0
		var state: Dictionary = GameState.officer_states.get(str(officer_id), {})
		if not state.is_empty():
			mult = float(state.get("wage_mult", 1.0))
		total += int(round(int(officer.get("wage_daily", 0)) * mult))
	return total


# --- Reputation (docs/50-* §4.6) --------------------------------------------

static func reputation(nation_id: String) -> int:
	var rep: Dictionary = _player().get("reputation", {})
	return int(rep.get(nation_id, 0))


## Applies a delta, clamped to −100…+100, and returns the new value.
static func add_reputation(nation_id: String, delta: int) -> int:
	var p: Dictionary = _player()
	if p.is_empty():
		push_error("Character.add_reputation: GameState.player is empty")
		return 0
	var rep: Dictionary = p.get("reputation", {})
	var value := clampi(
		int(rep.get(nation_id, 0)) + delta, REPUTATION_MIN, REPUTATION_MAX
	)
	rep[nation_id] = value
	p["reputation"] = rep
	return value


## docs/50-* §4.6 Phase-1 source: +1 per 1,000g of **cumulative** sale profit
## at that nation's ports, clamped by [method add_reputation].
##
## Two `player`-block keys track it — `profit_by_nation` (lifetime profit) and
## `profit_rep_awarded` (points already paid out) — so the threshold carries
## across transactions (600g then 400g grants the point neither earns alone),
## the rule survives save/load, and it can never double-award. Reputation from
## other sources is left untouched.
##
## Returns the reputation points granted (0 for a loss or a sub-threshold gain).
static func add_profit_reputation(nation_id: String, profit: int) -> int:
	if nation_id.is_empty() or profit <= 0:
		return 0
	var p: Dictionary = _player()
	if p.is_empty():
		push_error("Character.add_profit_reputation: GameState.player is empty")
		return 0
	var totals: Dictionary = p.get(PROFIT_KEY, {})
	var total := int(totals.get(nation_id, 0)) + profit
	totals[nation_id] = total
	p[PROFIT_KEY] = totals

	var awarded: Dictionary = p.get(PROFIT_AWARDED_KEY, {})
	var earned := int(floor(total / float(PROFIT_PER_REP)))
	var already := int(awarded.get(nation_id, 0))
	if earned <= already:
		awarded[nation_id] = already
		p[PROFIT_AWARDED_KEY] = awarded
		return 0
	awarded[nation_id] = earned
	p[PROFIT_AWARDED_KEY] = awarded
	add_reputation(nation_id, earned - already)
	return earned - already


## Lifetime sale profit booked against a nation (§4.6; 0 when never traded
## there). Backed by `player.profit_by_nation`.
static func profit_by_nation(nation_id: String) -> int:
	var totals: Dictionary = _player().get(PROFIT_KEY, {})
	return int(totals.get(nation_id, 0))


# --- Helpers ---------------------------------------------------------------

static func _player() -> Dictionary:
	return GameState.player
