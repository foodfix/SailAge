class_name BattleResult
extends RefCounted
## Battle-end fleet effects (docs/60-COMBAT.md §4.11.7, §4.11.9, §4.12.3;
## owner: task C). The one module allowed to move ships between a battle's
## outcome block and `GameState.fleet`.
##
## Layering (docs/60-* §4.12.4): `BattleSim` produced the raw outcome and never
## touched `GameState`; [method apply] is step 2 of the battle-end sequence.
## It touches **only** `GameState.fleet` and emits `fleet_changed` /
## `game_over` — gold, XP and reputation belong to `BattleRewards` (task G).
##
## Duplicated rules: none. The cargo-hold maths ([method Fleet.free_capacity],
## [method Fleet.add_goods], [method Fleet.normalize_all]) lives in
## `scripts/fleet/fleet.gd`; the 25%-durability capture transform is the one
## number §4.11.7 pins and is applied here (the sim deliberately reports the
## hull intact).
##
## Two doc-visible behaviours worth stating up front:
##   * **Nothing is dropped silently.** Every hold unit that cannot be carried
##     is summed into `cargo_overflow_lost` (§4.12.2, `battle.after.overflow`).
##   * **A capture is not a sinking.** A lost player hull is removed without
##     touching the rest of the fleet's holds; the next ship is simply
##     `fleet[0]` afterwards (§4.11.7 "order preserved").
##   * Both player loss lists are applied: `lost_player` (captured hull
##     instances) and `sunk_player` (ship_type_ids). A sunk hull leaves the
##     fleet here because §4.12.4 makes this seam the only fleet mutator, and
##     §4.7 says a hull at durability 0 leaves the battle immediately.

const FleetLib := preload("res://scripts/fleet/fleet.gd")

## §4.11.7 capture transform: `max(1, floor(current durability × 0.25))`.
const CAPTURE_DURABILITY_FRACTION := 0.25

## §4.11.7: the two game-over reasons this module can produce (`60-*` §6
## "game-over reason set becomes {starvation, scurvy, sunk, captured}").
const GAME_OVER_CAPTURED := "captured"
const GAME_OVER_SUNK := "sunk"


## Applies the fleet-only part of a finished battle and returns the outcome
## block with the report fields filled in.
##
## `sim_outcome` is `BattleSim.outcome()` (§4.12.2) — read, never mutated.
## `enemy_units` is `BattleSim.units()`; it is used only to tag each capture
## with the enemy fleet index it came from (diagnostics for S10's log), so an
## outcome replayed without units still applies correctly.
## `player_fleet_ref` is normally `GameState.fleet` itself. When it is a
## different array this function points `GameState.fleet` at it for the call —
## `Fleet.normalize_all()` and `Fleet.add_goods()` read the singleton — and
## restores the previous array before returning.
##
## Order (§4.12.3/§4.11.7): captures → hold guard → losses → flagship
## promotion / game over → `fleet_changed`. Returns a copy of `sim_outcome`
## plus:
##
##   `cargo_overflow_lost`  hold units lost for lack of space (§4.12.2)
##   `captured_ships`       ship_type_ids that joined the fleet
##   `scuttled_ships`       ship_type_ids looted and scuttled (fleet was full)
##   `lost_ships`           ship_type_ids the player lost this battle
##   `sunk_ships`           ship_type_ids removed because they sank
##   `captured_units`       `[{index, ship_type_id}]`, enemy index per capture
##   `game_over`            `""`/`"captured"`/`"sunk"` (what was emitted)
static func apply(sim_outcome: Dictionary, enemy_units: Array,
		player_fleet_ref: Array) -> Dictionary:
	var outcome: Dictionary = sim_outcome.duplicate(true)
	var report := {
		"cargo_overflow_lost": 0,
		"captured_ships": [],
		"scuttled_ships": [],
		"lost_ships": [],
		"sunk_ships": [],
		"captured_units": [],
		"game_over": "",
	}
	var fleet: Array = player_fleet_ref
	var previous_fleet: Array = GameState.fleet
	var swapped := not is_same(previous_fleet, fleet)
	if swapped:
		GameState.fleet = fleet

	var changed := false
	var joined := false

	# --- a. captures join the fleet, or are looted and scuttled ------------
	var captured: Array = outcome.get("captured_enemy", [])
	if captured is Array:
		for ship in captured:
			if not (ship is Dictionary):
				continue
			var hull: Dictionary = ship
			var ship_type_id := str(hull.get("ship_type_id", ""))
			var enemy_index := _enemy_index(enemy_units, hull)
			if fleet.size() < FleetLib.FLEET_MAX:
				fleet.append(_capture_copy(hull))
				(report["captured_ships"] as Array).append(ship_type_id)
				(report["captured_units"] as Array).append(
					{"index": enemy_index, "ship_type_id": ship_type_id})
				joined = true
				changed = true
			else:
				# §4.11.7: fleet full → cargo to capacity flagship-first, the
				# rest reported lost, then the hull is scuttled.
				report["cargo_overflow_lost"] = \
					int(report["cargo_overflow_lost"]) + _loot_cargo(hull)
				(report["scuttled_ships"] as Array).append(ship_type_id)
				changed = true

	# §4.11.7: "If the hold is then over capacity, Fleet.normalize_all()
	# truncates it and the after-action dialog reports the overflow" — the
	# guard runs once, and whatever it drops is added to the report.
	if joined:
		report["cargo_overflow_lost"] = \
			int(report["cargo_overflow_lost"]) + _normalize_reporting_drops()

	# --- b. the player's lost ships leave the fleet -----------------------
	# `lost_player` (§4.12.2) carries the captured/taken instances; `sunk_player`
	# carries ship_type_ids only, but a sunk hull must leave the fleet too
	# (§4.7 "durability 0 → the ship sinks immediately"). §4.12.4 makes this
	# seam the one fleet mutator, so both lists are applied here.
	var lost: Array = outcome.get("lost_player", [])
	if lost is Array:
		for ship in lost:
			if not (ship is Dictionary):
				continue
			if _remove_first_match(fleet, ship):
				(report["lost_ships"] as Array).append(
					str((ship as Dictionary).get("ship_type_id", "")))
				changed = true

	var sunk: Array = outcome.get("sunk_player", [])
	if sunk is Array:
		for ship_type_value in sunk:
			if _remove_first_of_type(fleet, str(ship_type_value)):
				(report["sunk_ships"] as Array).append(str(ship_type_value))
				changed = true

	# --- c. flagship promotion / game over --------------------------------
	if changed:
		report["game_over"] = _publish_fleet_state(outcome, fleet)

	if swapped:
		GameState.fleet = previous_fleet
	outcome.merge(report, true)
	return outcome


# --- Capture / loot --------------------------------------------------------

## §4.11.7: `max(1, floor(current durability × 0.25))`, `crew = 0`, and the
## hold, cannons and equipment travel with the hull untouched.
static func _capture_copy(hull: Dictionary) -> Dictionary:
	var ship: Dictionary = hull.duplicate(true)
	var current := int(ship.get("durability", 0))
	ship["durability"] = maxi(1, int(floor(float(current) * CAPTURE_DURABILITY_FRACTION)))
	ship["crew"] = 0
	return ship


## §4.11.7 full-fleet path: move as much of the scuttled hull's trade goods
## as the fleet can hold (flagship-first, [method Fleet.add_goods]), and return
## the number of hold units destroyed with her — the untaken goods plus the
## provisions and water that had no room. A capture is not a sinking, so
## nothing relocates from the player's own ships.
static func _loot_cargo(hull: Dictionary) -> int:
	var lost := 0
	var cargo = hull.get("cargo", {})
	if cargo is Dictionary:
		for good_id in (cargo as Dictionary).keys():
			var qty := maxi(int((cargo as Dictionary).get(good_id, 0)), 0)
			if qty <= 0:
				continue
			lost += qty - FleetLib.add_goods(str(good_id), qty)
	# Provisions and water are their own fields (§4.2), so `add_goods` cannot
	# take them; they burn with the hull. Reported, never silent.
	lost += maxi(int(hull.get("provisions", 0)), 0)
	lost += maxi(int(hull.get("water", 0)), 0)
	return lost


## Runs the canonical capacity guard over `GameState.fleet` and returns the
## hold units it dropped (goods + provisions + water), measured before/after so
## the truncation rule itself stays in `fleet.gd`.
static func _normalize_reporting_drops() -> int:
	var before := _fleet_hold_units()
	FleetLib.normalize_all()
	return maxi(before - _fleet_hold_units(), 0)


static func _fleet_hold_units() -> int:
	var total := 0
	for ship in GameState.fleet:
		if not (ship is Dictionary):
			continue
		total += int((ship as Dictionary).get("provisions", 0))
		total += int((ship as Dictionary).get("water", 0))
		var cargo = (ship as Dictionary).get("cargo", {})
		if cargo is Dictionary:
			for good_id in (cargo as Dictionary):
				total += maxi(int((cargo as Dictionary).get(good_id, 0)), 0)
	return total


# --- Loss / promotion ------------------------------------------------------

## Removes one fleet entry for `ship` and returns whether one was found.
##
## The outcome block carries full ship instances, not fleet indices (§4.12.2),
## so matching has two passes:
##
##   1. **Deep equality** (`==` on the dict) — exact, the common case, because
##      `BattleSim` deep-copies the instance on capture and an untouched hull
##      compares equal to its fleet original.
##   2. **Same hull type, first unconsumed occurrence** — the fallback for a
##      ship the battle changed before it was taken (durability from cannon
##      fire, crew from a ram): the instance no longer equals the fleet copy,
##      but exactly one fleet entry of that `ship_type_id` is still owed to
##      this loss, in fleet order. This keeps the *count* right and never
##      touches a hull of a different type; with two identical hulls of the
##      same type the removed entry is indistinguishable, which changes neither
##      the remaining types nor their holds.
static func _remove_first_match(fleet: Array, ship: Dictionary) -> bool:
	for index in fleet.size():
		if fleet[index] is Dictionary and fleet[index] == ship:
			fleet.remove_at(index)
			return true
	var ship_type_id := str(ship.get("ship_type_id", ""))
	if ship_type_id.is_empty():
		return false
	return _remove_first_of_type(fleet, ship_type_id)


## Removes the first fleet hull of `ship_type_id`; returns whether one existed.
static func _remove_first_of_type(fleet: Array, ship_type_id: String) -> bool:
	if ship_type_id.is_empty():
		return false
	for index in fleet.size():
		if fleet[index] is Dictionary \
				and str((fleet[index] as Dictionary).get("ship_type_id", "")) == ship_type_id:
			fleet.remove_at(index)
			return true
	return false


## §4.11.7/§4.11.9: with hulls left, `fleet[0]` is the flagship again (order
## already preserved by the removals). An empty fleet ends the run with
## `captured` for a capture-caused defeat and `sunk` for a sinking (§4.12.4:
## the screen routes to S9 on a `game_over`).
static func _publish_fleet_state(outcome: Dictionary, fleet: Array) -> String:
	FleetLib.notify_changed()
	if not fleet.is_empty():
		return ""
	var reason := GAME_OVER_SUNK if str(outcome.get("result", "")) == "defeat_sunk" \
		else GAME_OVER_CAPTURED
	EventBus.game_over.emit(reason)
	return reason


## Enemy fleet index of a captured hull, `-1` when `enemy_units` is absent or
## no unit matches. Diagnostic only: never affects what is applied.
static func _enemy_index(enemy_units: Array, hull: Dictionary) -> int:
	for unit in enemy_units:
		if not (unit is Dictionary):
			continue
		var unit_ship = (unit as Dictionary).get("ship", null)
		if unit_ship is Dictionary and unit_ship == hull:
			return int((unit as Dictionary).get("index", -1))
	return -1
