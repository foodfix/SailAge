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
	if f.is_empty() or not (f[0] is Dictionary):
		return {}
	return f[0]


static func ship_stat(ship: Dictionary, key: String) -> int:
	var st: Dictionary = DataLoader.get_ship_type(String(ship.get("ship_type_id", "")))
	return int(st.get(key, 0))


## docs/40 §4.2: Σ cargo + provisions + water + cannons × 5.
## Defensive on missing/null fields and a non-dictionary `cargo` (gotcha 5).
static func used_capacity(ship: Dictionary) -> int:
	var used := int(ship.get("provisions", 0)) + int(ship.get("water", 0))
	used += int(ship.get("cannons", 0)) * CANNON_CARGO_UNITS
	var cargo = ship.get("cargo", {})
	if cargo is Dictionary:
		for good_id in cargo:
			used += int(cargo[good_id])
	return used


static func free_capacity(ship: Dictionary) -> int:
	return ship_stat(ship, "capacity") - used_capacity(ship)


## Sum over the fleet (docs/40 §4.2 pooling).
static func fleet_capacity() -> int:
	var total := 0
	for ship in GameState.fleet:
		if ship is Dictionary:
			total += ship_stat(ship, "capacity")
	return total


static func fleet_free() -> int:
	var total := 0
	for ship in GameState.fleet:
		if ship is Dictionary:
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
		if not (ship is Dictionary):
			continue
		var s := ship_stat(ship, "speed")
		if best == 0 or (s > 0 and s < best):
			best = s
	return best


## Pooled holdings of a trade good across the fleet.
static func held(good_id: String) -> int:
	var total := 0
	for ship in GameState.fleet:
		if not (ship is Dictionary):
			continue
		var cargo = ship.get("cargo", {})
		if cargo is Dictionary:
			total += int(cargo.get(good_id, 0))
	return total


## Pooled provisions or water (`kind` = "provisions" | "water").
static func supplies(kind: String) -> int:
	var total := 0
	for ship in GameState.fleet:
		if ship is Dictionary:
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


# --- Fleet panel actions (T18; docs/40 §4.4, §6; docs/20 §4.10) -------------
#
# The panel (`scenes/ui_shared/fleet_panel.gd`) is pure UI: every rule below is
# the single implementation, and `SaveSystem` calls [method normalize_all] after
# deserialization (the T17‖T18 interface pin).

## The two cargo-hold supply kinds (docs/40 §4.1: separate fields, both occupy
## capacity 1 unit per unit; docs/20 §4.10).
const SUPPLY_KINDS: Array[String] = ["provisions", "water"]

## Shipyard engine (promotion lives there — see [method can_promote]).
## Loaded lazily and by path, not `preload`: `shipyard_engine.gd` preloads this
## file, and a static preload cycle makes GDScript fail to resolve either.
static var _shipyard_lib: Script = null


## True while docked (docs/40 §4.4: promotion is a port action; `current_port`
## is null/empty at sea, docs/90 §5.4).
static func at_port() -> bool:
	var port = GameState.current_port
	return port is String and not (port as String).is_empty()


## Why promoting `fleet[index]` is refused, as a `ui_strings.json` key (`""` =
## allowed). Promotion is free and port-only, and the flagship is already
## `fleet[0]` (§4.4).
##
## `fleet.port_only` is requested for the next `ui_strings.json` merge. Like
## every other engine here it returns the **key**, not text; the panel resolves
## it and falls back to `ui.not_available` while the key is pending, so no
## caller can ever render a raw "<fleet.port_only>" (`80-*` §6).
static func promote_block_reason(index: int) -> String:
	if not at_port():
		return "fleet.port_only"
	if index <= 0 or index >= GameState.fleet.size():
		return "ui.not_available"
	return ""


## §4.4: free, port-only, non-flagship row. Delegates to [ShipyardEngine] so
## the rule exists once (shipyard screen + fleet panel share it).
static func can_promote(index: int) -> bool:
	return _shipyard().can_promote(index)


## §4.4 "Promote": `fleet[index]` becomes the flagship for free; every other
## ship keeps its relative order. Delegated to [ShipyardEngine.promote].
static func promote(index: int) -> bool:
	return _shipyard().promote(index)


## Drops the **whole** trade-good stack `good_id` from `fleet[ship_index]`
## (docs/20 §4.10: jettison is per stack, freeing capacity immediately).
## Returns the units removed (0 for an unknown ship/good, never negative) and
## announces `fleet_changed` when something actually left the hold.
static func jettison_good(ship_index: int, good_id: String) -> int:
	var ship := _ship(ship_index)
	if ship.is_empty() or good_id.is_empty():
		return 0
	var cargo: Dictionary = _cargo(ship)
	var have := _as_int(cargo.get(good_id, 0))
	if have <= 0:
		cargo.erase(good_id)
		return 0
	cargo.erase(good_id)
	notify_changed()
	return have


## Drops the whole provisions or water stack of `fleet[ship_index]`
## (`kind` = "provisions" | "water", docs/20 §4.10). Returns the units removed.
static func jettison_supplies(ship_index: int, kind: String) -> int:
	if not (kind in SUPPLY_KINDS):
		push_warning("Fleet.jettison_supplies: unknown kind '%s'" % kind)
		return 0
	var ship := _ship(ship_index)
	if ship.is_empty():
		return 0
	var have := _as_int(ship.get(kind, 0))
	if have <= 0:
		ship[kind] = 0
		return 0
	ship[kind] = 0
	notify_changed()
	return have


# --- Load-time guard (T17‖T18 pin; docs/40 §4.2, §6) -----------------------

## Repairs `GameState.fleet` to the §4.2 distribution invariant and truncates
## any over-capacity hold, as `SaveSystem` does after deserialization (§6
## "Capacity invariant violation found at load → logs and truncates cargo to
## fit").
##
## Invariants enforced, in this order:
##   1. every numeric hold field is a non-negative int, every `cargo` a dict
##      (JSON may hand us floats, nulls or missing keys — gotcha 1/5);
##   2. `used_capacity(ship) <= ShipType.capacity` — excess is dropped and
##      **logged** (trade goods first, in id order, then supplies), so the
##      player keeps the survival resources as long as possible;
##   3. flagship-first distribution: `fleet[i]` may only be non-empty while
##      every earlier hull is full; stranded units move flagship-first.
##
## Returns `true` when anything was truncated or repaired (the caller logs it),
## `false` when the fleet was already valid. Safe on an empty fleet, a single
## ship, unknown ship types and non-dictionary entries (logged, never a crash).
static func normalize_all() -> bool:
	if not (GameState.fleet is Array):
		push_warning("Fleet.normalize_all: GameState.fleet is not an Array; nothing to normalise")
		return false
	var repaired := false
	var fleet: Array = GameState.fleet
	for index in fleet.size():
		if not (fleet[index] is Dictionary):
			push_warning(
				"Fleet.normalize_all: fleet[%d] is not a ship instance (%s); skipped"
				% [index, type_string(typeof(fleet[index]))]
			)
			repaired = true
			continue
		var ship: Dictionary = fleet[index]
		if _normalize_fields(ship, index):
			repaired = true
		if _truncate_to_capacity(ship, index):
			repaired = true
	if _normalize_distribution():
		repaired = true
	if repaired:
		notify_changed()
	return repaired


## Coerces the hold fields of `ship` (`fleet[index]`) to non-negative ints and
## `cargo` to a Dictionary. Returns true when a value had to be **repaired**
## (truncated, clamped, dropped or replaced).
##
## JSON numbers arrive as floats (repo gotcha 1), and `45.0` is exactly what a
## save holds for `45`; converting an integral float to int is therefore a
## silent shape fix, *not* a repair — otherwise every healthy loaded save would
## report "normalised". A fractional value (`45.7`) *is* a repair and is logged.
static func _normalize_fields(ship: Dictionary, index: int) -> bool:
	var repaired := false
	for key in ["provisions", "water", "cannons"]:
		if not ship.has(key):
			# Missing field = 0 (gotcha 5). The schema says it must exist, so
			# this is a repair worth reporting, but it changes no numbers.
			ship[key] = 0
			push_warning("Fleet.normalize_all: fleet[%d] had no '%s'; set to 0" % [index, key])
			repaired = true
			continue
		var raw = ship[key]
		var value := _as_int(raw)
		if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
			ship[key] = value
			push_warning("Fleet.normalize_all: fleet[%d].%s was %s; coerced to %d"
				% [index, key, type_string(typeof(raw)), value])
			repaired = true
		elif value < 0:
			ship[key] = 0
			push_warning("Fleet.normalize_all: fleet[%d].%s was %d; clamped to 0"
				% [index, key, value])
			repaired = true
		elif float(value) != float(raw):
			ship[key] = value
			push_warning("Fleet.normalize_all: fleet[%d].%s was %s; truncated to %d"
				% [index, key, str(raw), value])
			repaired = true
		elif typeof(raw) == TYPE_FLOAT:
			ship[key] = value  # 45.0 -> 45, silently (JSON parse artifact)

	if ship.has("cargo") and not (ship["cargo"] is Dictionary):
		push_warning("Fleet.normalize_all: fleet[%d].cargo was %s; replaced with {}"
			% [index, type_string(typeof(ship["cargo"]))])
		ship["cargo"] = {}
		repaired = true
	elif not ship.has("cargo"):
		ship["cargo"] = {}
		push_warning("Fleet.normalize_all: fleet[%d] had no 'cargo'; set to {}" % index)
		repaired = true

	var cargo: Dictionary = ship["cargo"]
	for good_id in cargo.keys():
		var raw_qty = cargo[good_id]
		var qty := _as_int(raw_qty)
		if qty == 0 and (typeof(raw_qty) == TYPE_INT or (raw_qty is float and float(raw_qty) == 0.0)):
			# An explicit 0 carries no units: drop it silently (gotcha 5). It is
			# a shape cleanup, not a repair — a valid save may contain one.
			cargo.erase(good_id)
			continue
		if qty <= 0:
			cargo.erase(good_id)
			push_warning("Fleet.normalize_all: fleet[%d] carried %s of '%s'; dropped"
				% [index, str(raw_qty), str(good_id)])
			repaired = true
			continue
		if not (typeof(raw_qty) == TYPE_INT or typeof(raw_qty) == TYPE_FLOAT):
			cargo[good_id] = qty
			push_warning("Fleet.normalize_all: fleet[%d].cargo['%s'] was %s; coerced to %d"
				% [index, str(good_id), str(raw_qty), qty])
			repaired = true
		elif float(qty) != float(raw_qty):
			cargo[good_id] = qty
			push_warning("Fleet.normalize_all: fleet[%d].cargo['%s'] was %s; truncated to %d"
				% [index, str(good_id), str(raw_qty), qty])
			repaired = true
		elif typeof(raw_qty) == TYPE_FLOAT:
			cargo[good_id] = qty  # 30.0 -> 30, silently (JSON parse artifact)
	return repaired


## §4.2/§6 truncation guard: drops hold units until
## `used_capacity(ship) <= ShipType.capacity`. Trade goods go first (in id
## order), then provisions, then water — supplies are survival resources, so
## they are the last thing a corrupt save loses. Every drop is logged with the
## ship index. Returns true when anything was dropped.
static func _truncate_to_capacity(ship: Dictionary, index: int) -> bool:
	var ship_type_id := str(ship.get("ship_type_id", ""))
	var capacity := ship_stat(ship, "capacity")
	if capacity <= 0:
		# An unknown/missing hull has no known capacity: dropping the whole hold
		# to fit 0 would destroy resources the player may still recover from an
		# otherwise readable save. Log loudly and leave it alone (§6 guard).
		if DataLoader.get_ship_type(ship_type_id).is_empty():
			push_warning(
				"Fleet.normalize_all: fleet[%d] has unknown ship_type_id '%s'; capacity guard skipped"
				% [index, ship_type_id]
			)
		return false
	var over := used_capacity(ship) - capacity
	if over <= 0:
		return false
	push_warning(
		"Fleet.normalize_all: fleet[%d] (%s) holds %d units in a %d-unit hold; truncating %d"
		% [index, ship_type_id, used_capacity(ship), capacity, over]
	)

	var cargo: Dictionary = _cargo(ship)
	for good_id in _sorted_keys(cargo):
		if over <= 0:
			break
		var have := _as_int(cargo.get(good_id, 0))
		if have <= 0:
			continue
		var take := mini(have, over)
		if have - take <= 0:
			cargo.erase(good_id)
		else:
			cargo[good_id] = have - take
		over -= take
		push_warning("Fleet.normalize_all: fleet[%d] dropped %d '%s' (over capacity)"
			% [index, take, str(good_id)])

	for kind in SUPPLY_KINDS:
		if over <= 0:
			break
		var have := _as_int(ship.get(kind, 0))
		if have <= 0:
			continue
		var take := mini(have, over)
		ship[kind] = have - take
		over -= take
		push_warning("Fleet.normalize_all: fleet[%d] dropped %d '%s' (over capacity)"
			% [index, take, kind])
	return true


## §4.2 distribution invariant: `fleet[i]` non-empty ⟹ `fleet[0..i-1]` full.
## Walks the fleet flagship-first and moves stranded units into earlier free
## room (goods first, then supplies), leaving whatever the earlier hulls cannot
## take where it is — after which every earlier hull is full, so the invariant
## holds. Returns true when anything moved.
static func _normalize_distribution() -> bool:
	var fleet: Array = GameState.fleet
	var repaired := false
	for index in range(1, fleet.size()):
		if not (fleet[index] is Dictionary):
			continue
		var ship: Dictionary = fleet[index]
		var held_units := _hold_units(ship)
		if held_units <= 0:
			continue
		var moved := 0
		for target_index in index:
			if not (fleet[target_index] is Dictionary):
				continue
			moved += _move_hold(fleet[target_index], ship, free_capacity(fleet[target_index]))
			if _hold_units(ship) <= 0:
				break
		if moved <= 0:
			continue
		repaired = true
		push_warning(
			"Fleet.normalize_all: fleet[%d] held %d units while earlier hulls had room; moved %d flagship-first, %d left"
			% [index, held_units, moved, _hold_units(ship)]
		)
	return repaired


## Moves up to `room` units of `source`'s hold into `target` (goods first, then
## provisions/water). Returns the units moved.
static func _move_hold(target: Dictionary, source: Dictionary, room: int) -> int:
	var moved := 0
	if room <= 0:
		return 0
	var source_cargo: Dictionary = _cargo(source)
	var target_cargo: Dictionary = _cargo(target)
	for good_id in _sorted_keys(source_cargo):
		if room <= 0:
			break
		var have := _as_int(source_cargo.get(good_id, 0))
		if have <= 0:
			continue
		var take := mini(have, room)
		if have - take <= 0:
			source_cargo.erase(good_id)
		else:
			source_cargo[good_id] = have - take
		target_cargo[good_id] = _as_int(target_cargo.get(good_id, 0)) + take
		room -= take
		moved += take
	for kind in SUPPLY_KINDS:
		if room <= 0:
			break
		var have := _as_int(source.get(kind, 0))
		if have <= 0:
			continue
		var take := mini(have, room)
		source[kind] = have - take
		target[kind] = _as_int(target.get(kind, 0)) + take
		room -= take
		moved += take
	return moved


# --- Helpers ---------------------------------------------------------------

## `fleet[index]` as a non-empty Dictionary, else `{}` (callers never crash).
static func _ship(index: int) -> Dictionary:
	if index < 0 or index >= GameState.fleet.size():
		return {}
	var ship = GameState.fleet[index]
	return ship if ship is Dictionary else {}


## The ship's `cargo` dict, created in place when missing/invalid.
static func _cargo(ship: Dictionary) -> Dictionary:
	var cargo = ship.get("cargo", {})
	if not (cargo is Dictionary):
		cargo = {}
		ship["cargo"] = cargo
	return cargo


## Everything in the hold: goods + provisions + water (the §4.2 used capacity
## without the cannon term).
static func _hold_units(ship: Dictionary) -> int:
	var total := int(ship.get("provisions", 0)) + int(ship.get("water", 0))
	var cargo: Dictionary = _cargo(ship)
	for good_id in cargo:
		total += maxi(0, int(cargo[good_id]))
	return total


## Deterministic id order for truncation/transfer decisions.
static func _sorted_keys(dict: Dictionary) -> Array:
	var keys: Array = dict.keys()
	keys.sort_custom(func(a, b) -> bool: return str(a) < str(b))
	return keys


## Safe numeric coercion: JSON floats, ints and numeric strings only; anything
## else (null, bool, dict…) becomes 0 so no comparison ever crashes (gotcha 1).
static func _as_int(value) -> int:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return int(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return (value as String).to_int()
		_:
			return 0


## Resolves the shipyard engine lazily (see [member _shipyard_lib]).
static func _shipyard() -> Script:
	if _shipyard_lib == null:
		_shipyard_lib = load("res://scripts/port/shipyard_engine.gd")
	return _shipyard_lib
