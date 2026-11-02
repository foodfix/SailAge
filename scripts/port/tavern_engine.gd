class_name TavernEngine
extends RefCounted
## Tavern crew hire/fire maths and officer availability
## (docs/30-PORTS-AND-TRADE.md §4.5, docs/50-CHARACTER-AND-PROGRESSION.md §4.4,
## docs/40-SHIPS-AND-FLEET.md §4.4).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): every function
## is static, reads/mutates `GameState` through the singleton and is therefore
## unit-testable headless.
##
## What lives here vs. elsewhere:
##   * crew counts, crew_min/crew_max and the hire/fire transactions — this
##     file (T14);
##   * officer signing/dismissal, OFFICER_MAX and role bonuses — `character.gd`
##     (T16), reused here, never duplicated. [method officers_at_port] only
##     decides *visibility*, which is what the tavern tab needs.
##
## Phase-1 crew simplification (docs/40-* §4.4): all crew lives on the
## flagship, so `crew_min`/`crew_max` come from the flagship's ShipType.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## Phase-8 W5-C (docs/80-UI-UX.md §4.11.1): the befriend stance delta and the
## sparring usage note go through the shared constants/engine.
const CaptainsLib := preload("res://scripts/world/captains.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")

# --- Phase-8 W5-C tavern verbs (docs/80-UI-UX.md §4.11.1) ---------------------

## 切磋 sparring bet — the locked numbers: stake 100–1,000g in 100g steps
## (the stake IS the pot), the tavern champion's swordplay is 40, a win pays
## `pot × 2`, and each bout counts as 3 swordplay usages (growth counter,
## docs/50-* §4.3).
const SPAR_STAKE_MIN := 100
const SPAR_STAKE_MAX := 1000
const SPAR_STAKE_STEP := 100
const SPAR_CHAMPION_SWORDPLAY := 40
const SPAR_CHANCE_BASE := 0.5
const SPAR_CHANCE_DIVISOR := 200.0
const SPAR_CHANCE_MIN := 0.10
const SPAR_CHANCE_MAX := 0.90
const SPAR_USES_PER_BOUT := 3

## Session-static visit guards (runtime-only, never saved — the same
## discipline as `Captains.reset_deployments`): one befriend per captain per
## port-visit day (the hail rule §4.11.1 "once per captain per day").
static var _befriended: Dictionary = {}


## The guard key of one (captain, port, visit-day) triple.
static func _visit_key(captain_id: String, port_id: String) -> String:
	return "%s|%s|%d" % [captain_id, port_id, int(GameState.day)]


## Clears the session-static befriend guards (the suites' re-fixture seam;
## a new run never needs it — a fresh `GameState` starts unguarded and the
## keys carry the day).
static func reset_visit_guards() -> void:
	_befriended.clear()


## True when `captain_id` may still be befriended at `port_id` this visit-day.
static func can_befriend(captain_id: String, port_id: String) -> bool:
	if captain_id.is_empty():
		return false
	return not _befriended.has(_visit_key(captain_id, port_id))


## 交好 befriend (§4.11.1): `Captains.adjust_stance(id, STANCE_BEFRIEND)` —
## +1, once per captain per port-visit day. Consumes the guard only on
## success; returns the new stance (or the untouched one when refused).
static func befriend(captain_id: String, port_id: String) -> int:
	if not can_befriend(captain_id, port_id):
		return CaptainsLib.stance(captain_id)
	_befriended[_visit_key(captain_id, port_id)] = true
	return CaptainsLib.adjust_stance(captain_id, CaptainsLib.STANCE_BEFRIEND)


## The stake the stepper offers after `stake` (clamped to the 100–1,000 band,
## always on a 100g step).
static func spar_step(stake: int, direction: int) -> int:
	return clampi(stake + direction * SPAR_STAKE_STEP,
		SPAR_STAKE_MIN, SPAR_STAKE_MAX)


## 100–1,000g in 100g steps (§4.11.1).
static func spar_valid_stake(stake: int) -> bool:
	if stake < SPAR_STAKE_MIN or stake > SPAR_STAKE_MAX:
		return false
	return stake % SPAR_STAKE_STEP == 0


## `p = clamp(0.5 + (effective_swordplay − 40) / 200, 0.10, 0.90)` — the
## locked win chance against the 40-swordplay tavern champion.
static func spar_win_chance(effective_swordplay: int) -> float:
	return clampf(SPAR_CHANCE_BASE
		+ (float(effective_swordplay) - float(SPAR_CHAMPION_SWORDPLAY))
			/ SPAR_CHANCE_DIVISOR,
		SPAR_CHANCE_MIN, SPAR_CHANCE_MAX)


## A win pays `pot × 2` (the stake is the pot; §4.11.1).
static func spar_pot(stake: int) -> int:
	return stake * 2


## True when a bout may start: a valid stake, the purse covers it, and the
## tavern is open at the current time (§4.1b closed rule — the same guard
## every other timed tavern action runs).
static func can_spar(stake: int) -> bool:
	if not spar_valid_stake(stake):
		return false
	if GameState.gold < stake:
		return false
	return SailingSimLib.facility_open(SailingSimLib.docked_port_id(), "tavern")


## One bout (§4.11.1). `roll` ∈ [0, 1) — the screen draws it from its seeded
## stream (`80-*` W5 gate: interactions seeded-replayable); the engine stays
## pure given the roll. Wins pay [method spar_pot], losses forfeit the stake;
## **every** bout notes 3 swordplay usages and runs the growth award.
## Returns `{won, stake, chance, uses}` (`{}` untouched when refused).
static func spar(stake: int, roll: float) -> Dictionary:
	if not can_spar(stake):
		return {}
	GameState.add_gold(-stake)
	var chance := spar_win_chance(SkillsLib.effective_skill("swordplay"))
	var won := roll < chance
	if won:
		GameState.add_gold(spar_pot(stake))
	SkillsLib.note_usage("swordplay", SPAR_USES_PER_BOUT)
	SkillsLib.maybe_award("swordplay")
	return {
		"won": won,
		"stake": stake,
		"chance": chance,
		"uses": SPAR_USES_PER_BOUT,
	}


## Locked signing bonus (docs/30-* §4.5: `crew_wage_daily × 10`, 2 × 10 = 20).
## Derived from the sailing ledger constant so there is exactly one `2`.
static func per_head() -> int:
	return SailingSimLib.CREW_WAGE_DAILY * 10


## Signing bonus for `heads` crew; never negative (a bad call costs nothing).
static func hire_cost(heads: int) -> int:
	return maxi(heads, 0) * per_head()


## Crew aboard the flagship (docs/40-* §4.4).
static func crew() -> int:
	return FleetLib.total_crew()


static func crew_max() -> int:
	return FleetLib.ship_stat(FleetLib.flagship(), "crew_max")


static func crew_min() -> int:
	return FleetLib.ship_stat(FleetLib.flagship(), "crew_min")


## How many more hands fit before `crew_max` (0 when no flagship).
static func max_hire() -> int:
	return maxi(crew_max() - crew(), 0)


## The "Fill" button amount: as many as fit *and* as the purse can pay for.
## At the cap this is 0, so the button disables with the cap reason.
static func fill_heads() -> int:
	var cost := per_head()
	if cost <= 0:
		return 0
	return mini(max_hire(), maxi(GameState.gold, 0) / cost)


## docs/30-* §4.5 + §6: positive heads, within `crew_max`, affordable.
static func can_hire(heads: int) -> bool:
	if heads <= 0:
		return false
	if heads > max_hire():
		return false
	return GameState.gold >= hire_cost(heads)


## Pays the signing bonus and adds the crew to the flagship.
## Returns false (state untouched) whenever [method can_hire] is false, or
## when the tavern is closed at the current time (`30-*` §4.1b closed rule —
## an action may only *start* inside the window). A completed hire charges
## one hour (§4.1b).
static func hire(heads: int) -> bool:
	if not can_hire(heads):
		return false
	if not SailingSimLib.facility_open(SailingSimLib.docked_port_id(), "tavern"):
		return false
	var ship: Dictionary = FleetLib.flagship()
	GameState.add_gold(-hire_cost(heads))
	ship["crew"] = int(ship.get("crew", 0)) + heads
	FleetLib.notify_changed()
	SailingSimLib.advance_port_hours(1)
	return true


## How many hands can be let go before `crew_min` (0 at the floor).
static func min_fire() -> int:
	return maxi(crew() - crew_min(), 0)


## docs/30-* §4.5: cannot go below `crew_min`; no severance, morale untouched.
static func can_fire(heads: int) -> bool:
	if heads <= 0:
		return false
	if heads > crew():
		return false
	return crew() - heads >= crew_min()


## Lets `heads` crew go. Gold and morale are deliberately untouched: the doc
## locks "fired crew leaves with no severance; morale unchanged".
##
## Strict transaction: refuses (false, nothing fired) when the request would
## cross the floor, so an engine/test caller can never silently lose fewer
## hands than it asked for. The screen's −1/−10 buttons use [method
## fire_clamped] instead, which is the §6 "−1/−10 clamp likewise" reading.
static func fire(heads: int) -> bool:
	if not can_fire(heads):
		return false
	if not SailingSimLib.facility_open(SailingSimLib.docked_port_id(), "tavern"):
		return false
	_apply_fire(heads)
	SailingSimLib.advance_port_hours(1)
	return true


## Clamping variant used by the −1 / −10 buttons (docs/30-* §6 "−1/−10 clamp
## likewise", §4.5 "cannot go below crew_min"): fires as many as the floor
## allows and returns the number actually let go (0 at the floor). Same §4.1b
## window guard and one-hour cost as [method fire].
static func fire_clamped(heads: int) -> int:
	var actual := mini(maxi(heads, 0), min_fire())
	if actual <= 0:
		return 0
	if not SailingSimLib.facility_open(SailingSimLib.docked_port_id(), "tavern"):
		return 0
	_apply_fire(actual)
	SailingSimLib.advance_port_hours(1)
	return actual


static func _apply_fire(heads: int) -> void:
	var ship: Dictionary = FleetLib.flagship()
	ship["crew"] = int(ship.get("crew", 0)) - heads
	FleetLib.notify_changed()


## Officer ids seeking a berth at `port_id`, in `officers.json` order
## (docs/50-* §4.4): the port must be in `recruit_ports` and the officer must
## not be employed. An employed officer therefore vanishes from *every*
## tavern and reappears in the pool on dismissal.
static func officers_at_port(port_id: String) -> Array:
	var result: Array = []
	if port_id.is_empty() or DataLoader.get_port(port_id).is_empty():
		return result
	for officer in DataLoader.officers_list:
		var officer_id := str(officer.get("id", ""))
		if officer_id.is_empty():
			continue
		var ports: Array = officer.get("recruit_ports", [])
		if not ports.has(port_id):
			continue
		if CharacterLib.is_employed(officer_id):
			continue
		result.append(officer_id)
	return result
