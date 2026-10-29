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
## Returns false (state untouched) whenever [method can_hire] is false.
static func hire(heads: int) -> bool:
	if not can_hire(heads):
		return false
	var ship: Dictionary = FleetLib.flagship()
	GameState.add_gold(-hire_cost(heads))
	ship["crew"] = int(ship.get("crew", 0)) + heads
	FleetLib.notify_changed()
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
	_apply_fire(heads)
	return true


## Clamping variant used by the −1 / −10 buttons (docs/30-* §6 "−1/−10 clamp
## likewise", §4.5 "cannot go below crew_min"): fires as many as the floor
## allows and returns the number actually let go (0 at the floor).
static func fire_clamped(heads: int) -> int:
	var actual := mini(maxi(heads, 0), min_fire())
	if actual <= 0:
		return 0
	_apply_fire(actual)
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
