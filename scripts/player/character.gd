class_name Character
extends RefCounted
## Player stats, XP/level, officers and reputation
## (docs/50-CHARACTER-AND-PROGRESSION.md §4.2–§4.6, §5).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): every function
## is static and reads/mutates the `GameState.player` save block through the
## singleton, so the formulas are unit-testable from headless GDScript.
##
## The player block shape is owned by docs/50-* §4.8. This file never adds
## transient keys to it (the level-up flag is a class static, see
## [member pending_levelup]) so a save written by T17 stays schema-clean.

## Locked constants (docs/50-* §4.3–§4.5).
const OFFICER_MAX := 3
const LEVEL_CAP := 20
## `level = floor(sqrt(xp / XP_LEVEL_UNIT)) + 1` (docs/50-* §4.3).
const XP_LEVEL_UNIT := 50.0
## Base value of every stat at new game; the nation bonus is added on top.
const BASE_STAT := 10
## Flat +5 nation bonus (docs/50-* §4.2 table).
const NATION_BONUS_AMOUNT := 5
## Stat order used by the character panel / save block.
const STAT_KEYS: Array[String] = [
	"leadership", "seamanship", "combat", "navigation", "luck",
]

## docs/50-* §4.2: nation → the single stat that gets +5 at new game.
const NATION_BONUS_STAT := {
	"portugal": "navigation",
	"spain": "leadership",
	"england": "combat",
	"holland": "seamanship",
	"ottoman": "leadership",
	"italy": "luck",
}

## docs/50-* §4.5: assigned-officer role → flat effective-stat bonus.
## Multiple officers with the same role stack.
const ROLE_STAT_BONUS := {
	"navigator": {"navigation": 10},
	"boatswain": {"seamanship": 10},
	"gunner": {"combat": 10},
}

## Reputation is an integer −100…+100 per nation (docs/50-* §4.6).
const REPUTATION_MIN := -100
const REPUTATION_MAX := 100

## §4.6 "+1 per 1,000g cumulative profit sold at a nation's ports". The two
## player-block keys back the accumulator and must survive save/load (§4.8) —
## see [method add_profit_reputation].
const PROFIT_PER_REP := 1000
const PROFIT_KEY := "profit_by_nation"
const PROFIT_AWARDED_KEY := "profit_rep_awarded"

## Speed bonus clamp from docs/50-* §4.2 / docs/20-* §4.4.
const SPEED_BONUS_MIN := -0.10
const SPEED_BONUS_MAX := 0.20

## Set by [method award_xp] when a level was gained. The toast itself belongs
## to the HUD (T6); the side panel/HUD can read this flag and call
## [method consume_pending_levelup] to render `char.level_up` once. It is a
## class static rather than a `player` key so the T17 save block keeps exactly
## the §4.8 shape; a still-pending toast is not worth persisting.
static var pending_levelup: bool = false


# --- Stats (docs/50-* §4.2) ------------------------------------------------

## Raw stat without officer bonuses.
static func base_stat(stat_name: String) -> int:
	var p: Dictionary = _player()
	var stats: Dictionary = p.get("stats", {})
	return int(stats.get(stat_name, 0))


## `player.stats[name]` plus every assigned officer's role bonus (§4.5).
static func effective_stat(stat_name: String) -> int:
	var total := base_stat(stat_name)
	var p: Dictionary = _player()
	var officers: Array = p.get("officers", [])
	for officer_id in officers:
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		if officer.is_empty():
			continue
		var role := str(officer.get("role", ""))
		var bonuses: Dictionary = ROLE_STAT_BONUS.get(role, {})
		total += int(bonuses.get(stat_name, 0))
	return total


## docs/50-* §4.2: `(seamanship − 10) / 100`, clamped [−0.10, +0.20].
static func speed_bonus() -> float:
	var raw := (effective_stat("seamanship") - BASE_STAT) / 100.0
	return clampf(raw, SPEED_BONUS_MIN, SPEED_BONUS_MAX)


## docs/50-* §4.2 / docs/20-* §4.11: `8 + floor((navigation − 10) / 10)`.
static func sighting_radius() -> int:
	return 8 + int(floor((effective_stat("navigation") - BASE_STAT) / 10.0))


## docs/50-* §4.2: `1 − (leadership − 10) / 200`.
## The doc gives no lower clamp; a negative multiplier would turn a loss into
## a gain, so this implementation floors it at 0 (no desertion possible),
## which is also the reading of "losses × multiplier" at high leadership.
static func desertion_multiplier() -> float:
	return maxf(0.0, 1.0 - (effective_stat("leadership") - BASE_STAT) / 200.0)


## Same formula and clamp as [method desertion_multiplier] (docs/50-* §4.2).
static func mutiny_multiplier() -> float:
	return maxf(0.0, 1.0 - (effective_stat("leadership") - BASE_STAT) / 200.0)


## docs/50-* §4.2: storm damage is ×0.75 once luck reaches 50.
static func storm_damage_multiplier() -> float:
	return 0.75 if effective_stat("luck") >= 50 else 1.0


## docs/50-* §4.2: storm chance `× (1 − luck / 400)`.
static func storm_chance_multiplier() -> float:
	return 1.0 - effective_stat("luck") / 400.0


## Stats granted at new game: base 10 plus the nation's +5 on its own stat.
## Kept here so the §4.2 table lives in one place (GameState.new_game calls it).
static func starting_stats(nation_id: String) -> Dictionary:
	var stats: Dictionary = {}
	for key in STAT_KEYS:
		stats[key] = BASE_STAT
	var bonus_stat := nation_bonus_stat(nation_id)
	if not bonus_stat.is_empty():
		stats[bonus_stat] = int(stats[bonus_stat]) + NATION_BONUS_AMOUNT
	return stats


## The stat boosted for a nation, or "" when the id is unknown
## (docs/50-* §4.2).
static func nation_bonus_stat(nation_id: String) -> String:
	return str(NATION_BONUS_STAT.get(nation_id, ""))


# --- XP & levels (docs/50-* §4.3) ------------------------------------------

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
	# cache; derivation wins on mismatch"); the panel therefore can never show
	# a level that disagrees with the XP it prints next to it.
	return level_for_xp(current_xp())


## XP still needed for the next level, or −1 at the cap (panel hides the row).
static func xp_to_next_level() -> int:
	var xp := current_xp()
	var level := level_for_xp(xp)
	if level >= LEVEL_CAP:
		return -1
	return xp_for_level(level + 1) - xp


## Adds XP and applies the §4.3 level-up rewards. Non-positive amounts are
## ignored (a loss-making sale awards 0 XP and must not touch the level cache).
##
## On each level gained: +1 seamanship and +1 to the player's nation-bonus
## stat, clamped to the §4.2 1–100 stat range. Gaining several levels at once
## applies the reward once per level, matching "on each level-up".
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
	_apply_level_up(p, gained)
	pending_levelup = true
	# Toast rendering lands with the HUD (T6, docs/80-* §4.7); log meanwhile.
	print("Character: level up to %d (xp %d)" % [after, int(p["xp"])])


## Reads and clears the pending-level-up flag; true exactly once per award.
static func consume_pending_levelup() -> bool:
	var was_pending := pending_levelup
	pending_levelup = false
	return was_pending


## docs/50-* §4.3 locked profit-XP rule:
## per-unit profit = max(0, sell_price − floor(base_price × 0.7)),
## profit = qty × per-unit, XP = floor(profit / 100).
static func add_profit_xp(sell_price: int, base_price: int, qty: int) -> void:
	var per_unit := maxi(0, sell_price - int(floor(base_price * 0.7)))
	var profit := maxi(qty, 0) * per_unit
	award_xp(int(floor(profit / 100.0)))


static func _apply_level_up(p: Dictionary, gained: int) -> void:
	var stats: Dictionary = p.get("stats", {})
	if stats.is_empty():
		return
	stats["seamanship"] = clampi(
		int(stats.get("seamanship", BASE_STAT)) + gained, 1, 100
	)
	var bonus_stat := nation_bonus_stat(str(p.get("nation_id", "")))
	if not bonus_stat.is_empty():
		stats[bonus_stat] = clampi(
			int(stats.get(bonus_stat, BASE_STAT)) + gained, 1, 100
		)
	p["stats"] = stats


# --- Officers (docs/50-* §4.4–§4.5) ----------------------------------------

static func employed_officers() -> Array:
	var officers: Array = _player().get("officers", [])
	return officers


static func officer_count() -> int:
	return employed_officers().size()


static func is_employed(officer_id: String) -> bool:
	return officer_id in employed_officers()


## One-time signing cost, `wage_daily × 10` (docs/50-* §4.4).
static func recruit_cost(officer_id: String) -> int:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		return 0
	return int(officer.get("wage_daily", 0)) * 10


## True when the officer exists, is not already aboard, there is roster room
## (OFFICER_MAX = 3) and the signing cost is affordable — the §6 edge rule
## makes the recruit button disabled (with the price shown) when gold is short.
static func can_recruit(officer_id: String) -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		return false
	if is_employed(officer_id):
		return false
	if officer_count() >= OFFICER_MAX:
		return false
	return GameState.gold >= recruit_cost(officer_id)


## Adds the officer to `player.officers` and pays the signing cost.
## Returns false (state untouched) whenever [method can_recruit] is false.
static func recruit(officer_id: String) -> bool:
	if not can_recruit(officer_id):
		return false
	var cost := recruit_cost(officer_id)
	GameState.add_gold(-cost)
	var p: Dictionary = _player()
	var officers: Array = p.get("officers", [])
	officers.append(officer_id)
	p["officers"] = officers
	print("Character: recruited %s for %dg" % [officer_id, cost])
	return true


## Removes the officer; no severance (docs/50-* §4.4).
static func dismiss(officer_id: String) -> bool:
	var p: Dictionary = _player()
	var officers: Array = p.get("officers", [])
	var index := officers.find(officer_id)
	if index < 0:
		return false
	officers.remove_at(index)
	p["officers"] = officers
	print("Character: dismissed %s" % officer_id)
	return true


## Σ `wage_daily` for the daily ledger (docs/50-* §4.4; consumed by T7).
static func officer_wages() -> int:
	var total := 0
	for officer_id in employed_officers():
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		total += int(officer.get("wage_daily", 0))
	return total


# --- Reputation (docs/50-* §4.6) -------------------------------------------

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
