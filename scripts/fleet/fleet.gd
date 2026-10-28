class_name Fleet
extends RefCounted
## Fleet composition and cargo-hold maths (docs/40-SHIPS-AND-FLEET.md §4).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4). Reads and
## mutates `GameState.fleet` through the singleton; every function is static so
## it is unit-testable from headless GDScript.
##
## Ownership: core maths authored with T16/T7's needs in mind; task T18 extends
## this file with `normalize_all()` truncation/promotion rules and the load-time
## capacity guard (docs/40 §6). Do not duplicate these formulas elsewhere.

## Locked constants (docs/40 §4.2, §4.4).
const CANNON_CARGO_UNITS := 5
const FLEET_MAX := 5

## A cannon occupies this many cargo units (docs/40 §4.2).
const STAT_KEYS := ["durability", "capacity", "speed", "crew_max", "armament_slots"]


## Creates a ship instance per docs/40 §4.1 with the §4.3 "buy ship" defaults:
## full durability, zero crew, no supplies, no cannons, empty hold.
static func new_ship(ship_type_id: String, crew: int = 0) -> Dictionary:
	var st: Dictionary = DataLoader.get_ship_type(ship_type_id)
	if st.is_empty():
		push_error("Fleet.new_ship: unknown ship_type_id '%s'" % ship_type_id)
		return {}
	return {
		"ship_type_id": ship_type_id,
		"durability": int(st["durability"]),
		"crew": clampi(crew, 0, int(st["crew_max"])),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"cargo": {},
	}


## The flagship is always `fleet[0]` (docs/40 §4.4).
static func flagship() -> Dictionary:
	var f: Array = GameState.fleet
	return f[0] if not f.is_empty() else {}


static func ship_stat(ship: Dictionary, key: String) -> int:
	var st: Dictionary = DataLoader.get_ship_type(String(ship.get("ship_type_id", "")))
	return int(st.get(key, 0))


## docs/40 §4.2: Σ cargo + provisions + water + cannons × 5.
static func used_capacity(ship: Dictionary) -> int:
	var used := int(ship.get("provisions", 0)) + int(ship.get("water", 0))
	used += int(ship.get("cannons", 0)) * CANNON_CARGO_UNITS
	var cargo: Dictionary = ship.get("cargo", {})
	for good_id in cargo:
		used += int(cargo[good_id])
	return used


static func free_capacity(ship: Dictionary) -> int:
	return ship_stat(ship, "capacity") - used_capacity(ship)


## Sum over the fleet (docs/40 §4.2 pooling).
static func fleet_capacity() -> int:
	var total := 0
	for ship in GameState.fleet:
		total += ship_stat(ship, "capacity")
	return total


static func fleet_free() -> int:
	var total := 0
	for ship in GameState.fleet:
		total += free_capacity(ship)
	return total


## Phase-1: all crew lives on the flagship (docs/40 §4.4).
static func total_crew() -> int:
	var f := flagship()
	return int(f.get("crew", 0)) if not f.is_empty() else 0


## Fleet speed uses the slowest hull; other factors come from the flagship
## (docs/20 §4.4 "Fleet-speed composition").
static func slowest_speed() -> int:
	var best := 0
	for ship in GameState.fleet:
		var s := ship_stat(ship, "speed")
		if best == 0 or (s > 0 and s < best):
			best = s
	return best


## Pooled holdings of a trade good across the fleet.
static func held(good_id: String) -> int:
	var total := 0
	for ship in GameState.fleet:
		total += int(ship.get("cargo", {}).get(good_id, 0))
	return total


## Pooled provisions or water (`kind` = "provisions" | "water").
static func supplies(kind: String) -> int:
	var total := 0
	for ship in GameState.fleet:
		total += int(ship.get(kind, 0))
	return total


## Adds goods flagship-first, then in fleet order, up to free capacity.
## Returns the quantity actually stored (docs/40 §4.2 distribution rule).
static func add_goods(good_id: String, qty: int) -> int:
	var remaining := maxi(qty, 0)
	for ship in GameState.fleet:
		if remaining <= 0:
			break
		var room := mini(remaining, free_capacity(ship))
		if room <= 0:
			continue
		var cargo: Dictionary = ship["cargo"]
		cargo[good_id] = int(cargo.get(good_id, 0)) + room
		remaining -= room
	return maxi(qty, 0) - remaining


## Removes goods flagship-first, then in fleet order. Returns qty removed.
static func remove_goods(good_id: String, qty: int) -> int:
	var remaining := maxi(qty, 0)
	for ship in GameState.fleet:
		if remaining <= 0:
			break
		var cargo: Dictionary = ship["cargo"]
		var have := int(cargo.get(good_id, 0))
		if have <= 0:
			continue
		var take := mini(remaining, have)
		if have - take == 0:
			cargo.erase(good_id)
		else:
			cargo[good_id] = have - take
		remaining -= take
	return maxi(qty, 0) - remaining


## Adds provisions or water flagship-first. Returns quantity actually stored.
static func add_supplies(kind: String, qty: int) -> int:
	var remaining := maxi(qty, 0)
	for ship in GameState.fleet:
		if remaining <= 0:
			break
		var room := mini(remaining, free_capacity(ship))
		if room <= 0:
			continue
		ship[kind] = int(ship.get(kind, 0)) + room
		remaining -= room
	return maxi(qty, 0) - remaining


## Removes provisions or water flagship-first. Returns quantity removed.
static func remove_supplies(kind: String, qty: int) -> int:
	var remaining := maxi(qty, 0)
	for ship in GameState.fleet:
		if remaining <= 0:
			break
		var have := int(ship.get(kind, 0))
		if have <= 0:
			continue
		var take := mini(remaining, have)
		ship[kind] = have - take
		remaining -= take
	return maxi(qty, 0) - remaining


## Emits the canonical change signal after a fleet mutation (docs/90 §5.1).
static func notify_changed() -> void:
	EventBus.fleet_changed.emit()


# --- Extension points owned by T18 (docs/40 §6) ------------------------------
# T18 adds: normalize_all() (distribution invariant + over-capacity truncation
# with logging), promote(index) (free, port-only), and the load-time guard.
# Keep core maths above intact so T7's speed/consumption code stays valid.
