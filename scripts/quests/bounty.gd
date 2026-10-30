class_name Bounty
extends RefCounted
## Piracy reputation, bounty issue/clearing, and the closed-port rule
## (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.5, §4.9.5, §4.9.6; `60-*` §4.1,
## §4.11.10; `30-*` §4.2).
##
## Pure static logic, the same shape as `Character`/`Fame`: it owns
## `GameState.bounties` and mutates `player.reputation` **only** through
## `Character.add_reputation()`, so the −100…+100 clamp is applied exactly once.
##
## The rival table is **data** (`data/nations.json#rivals`, §4.9.5), never a
## computed distance: a value left to code would be invented twice.

const CharacterLib := preload("res://scripts/player/character.gd")

## §4.9.5: a bounty is issued at or below this reputation.
const BOUNTY_THRESHOLD := -50
## §4.9.5: the bounty amount is `500 × |rep|`, fixed at issue time.
const BOUNTY_GOLD_PER_REP := 500
## §4.9.5: both clearing paths reset that nation's reputation to exactly −10.
const CLEARED_REPUTATION := -10
## §4.9.5: `60-*` §4.11.10 charges exactly one −20 per navy battle.
const PIRACY_REPUTATION := -20
## §4.9.5: the two rivals each gain +2 once per battle.
const RIVAL_REPUTATION := 2


# --- Piracy (docs/70-* §4.9.5) -------------------------------------------

## The two rival nations of `nation_id` (exactly 2, from the data file). An
## unknown nation has no rivals.
static func rivals(nation_id: String) -> Array:
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	var list = nation.get("rivals", [])
	return (list as Array).duplicate() if list is Array else []


## The full piracy rep-delta block for one act against `nation_id`:
## `{nation_id: -20, rival_a: +2, rival_b: +2}`. Charged **once per battle at
## battle start** by the same funnel that charges the −20 (`60-*` §4.11.10), so
## applying it twice is impossible by construction.
static func piracy_deltas(nation_id: String) -> Dictionary:
	var out: Dictionary = {}
	if nation_id.is_empty():
		return out
	out[nation_id] = PIRACY_REPUTATION
	for rival_id in rivals(nation_id):
		var id := str(rival_id)
		if id.is_empty() or id == nation_id:
			continue
		out[id] = int(out.get(id, 0)) + RIVAL_REPUTATION
	return out


## Applies [method piracy_deltas] through `Character.add_reputation()` and then
## re-evaluates the bounty threshold (a piracy act can both deepen a bounty and
## create a fresh one). Returns the applied deltas.
static func apply_piracy(nation_id: String) -> Dictionary:
	var deltas := piracy_deltas(nation_id)
	for id in deltas:
		CharacterLib.add_reputation(str(id), int(deltas[id]))
	evaluate_all()
	return deltas


# --- Issue (docs/70-* §4.9.5) --------------------------------------------

## `true` while `nation_id` holds a bounty against the player.
static func has_bounty(nation_id: String) -> bool:
	return GameState.bounties.has(nation_id)


## The bounty record `{amount, day}` for `nation_id` (`{}` when none).
static func record(nation_id: String) -> Dictionary:
	var raw = GameState.bounties.get(nation_id, null)
	return raw if raw is Dictionary else {}


## The amount the palace charges to clear `nation_id`'s bounty (0 when none).
## Fixed at issue time (§4.9.5), not recomputed from the live reputation.
static func amount(nation_id: String) -> int:
	return int(record(nation_id).get("amount", 0))


## Every nation currently holding a bounty, sorted for a stable UI order.
static func bountied_nations() -> Array:
	var out: Array = GameState.bounties.keys()
	out.sort()
	return out


## Issues a bounty for `nation_id` when the reputation is at or below −50 and
## none exists yet; returns the new record (`{}` when nothing was issued).
static func issue(nation_id: String) -> Dictionary:
	if nation_id.is_empty() or has_bounty(nation_id):
		return {}
	var reputation := CharacterLib.reputation(nation_id)
	if reputation > BOUNTY_THRESHOLD:
		return {}
	var entry := {
		"amount": BOUNTY_GOLD_PER_REP * absi(reputation),
		"day": int(GameState.day),
	}
	GameState.bounties[nation_id] = entry
	EventBus.bounty_issued.emit(nation_id)
	return entry


## Re-evaluates every nation's bounty after any reputation change. A nation
## that climbs back above the threshold **without** clearing does not lose its
## bounty (only the two §4.9.5 paths clear it), so this only ever issues.
static func evaluate_all() -> Array:
	var issued: Array = []
	for nation in DataLoader.nations_list:
		var nation_id := str((nation as Dictionary).get("id", ""))
		if not issue(nation_id).is_empty():
			issued.append(nation_id)
	return issued


# --- Clearing (docs/70-* §4.9.5) -----------------------------------------

## `true` when the player can pay `nation_id`'s bounty right now.
static func can_pay_off(nation_id: String) -> bool:
	return has_bounty(nation_id) and GameState.gold >= amount(nation_id)


## Palace path: charges the fixed amount and clears the bounty.
static func pay_off(nation_id: String) -> bool:
	if not can_pay_off(nation_id):
		return false
	GameState.add_gold(-amount(nation_id))
	_clear(nation_id)
	return true


## Surrender path (`60-*` §4.11.7): the flagship was taken by a hunter of
## `nation_id`; the bounty clears as well.
static func clear_by_surrender(nation_id: String) -> bool:
	if not has_bounty(nation_id):
		return false
	_clear(nation_id)
	return true


## The shared clearing body: rep → exactly −10, bounty removed, announced.
static func _clear(nation_id: String) -> void:
	var current := CharacterLib.reputation(nation_id)
	# `add_reputation` clamps, so the delta that lands exactly on −10 is
	# computed from the live value (a direct write would bypass the clamp and
	# the `player.reputation` shape rule).
	CharacterLib.add_reputation(nation_id, CLEARED_REPUTATION - current)
	GameState.bounties.erase(nation_id)
	EventBus.bounty_cleared.emit(nation_id)


# --- Closed ports (docs/70-* §4.9.6, 30-* §4.2) -------------------------

## `true` when every facility of `port_id` is closed: the player holds a
## bounty from the port's nation.
static func is_port_closed(port_id: String) -> bool:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return false
	return has_bounty(str(port.get("nation_id", "")))


## `true` when `facility_id` may open at `port_id`: normally every facility of
## an open port; for a closed port **only** the palace of the bountied
## nation's capital (the §4.9.5 pay-off path — the anti-lockout exception).
static func can_open_facility(port_id: String, facility_id: String) -> bool:
	if not is_port_closed(port_id):
		return true
	if facility_id != "palace":
		return false
	var port: Dictionary = DataLoader.get_port(port_id)
	var nation_id := str(port.get("nation_id", ""))
	return str(DataLoader.get_nation(nation_id).get("capital_port_id", "")) == port_id


## `true` when a closed port's palace offers the pay-off row.
static func can_pay_here(port_id: String) -> bool:
	return is_port_closed(port_id) and can_open_facility(port_id, "palace")
