class_name ShipyardEngine
extends RefCounted
## Shipyard transactions — docs/40-SHIPS-AND-FLEET.md §4.3 (the four actions),
## §4.4 (fleet composition/flagship rules), §5 (worked numbers), §6 (fail
## states) and §7 (acceptance).
##
## Pure static logic over `GameState` (gold + fleet) and `DataLoader` ship
## types, exactly like `scripts/fleet/fleet.gd`: no node references, so every
## formula is unit-tested headless (`tools/test_shipyard.gd`). The screen
## (`scenes/port/shipyard_screen.gd`) only renders and delegates — it must not
## re-implement a price, a cap or a rule.
##
## Rules enforced here (never in the UI):
##   * `FLEET_MAX = 5` ships; buying the 6th is refused (`shipyard.fleet_full`).
##   * A bought ship starts at full durability, zero crew, no supplies, no
##     cannons, empty hold (§4.3).
##   * Repair costs `ceil(base_price / 400)` per durability point; partial
##     repair is allowed and capped by both damage and gold.
##   * Sell price is `floor(base_price × 0.5 × durability / max_durability)`;
##     the flagship can never be sold and the last ship can never be sold.
##   * Refit is 100g/cannon, 50g sell-back, 5 cargo units each and capped by
##     `armament_slots`. Phase 1 has **no** refit UI (§4.3 "present but
##     disabled"): the maths is unit-tested and ready for Phase 2.
##   * Promotion to flagship is free and port-only; it moves the row to
##     `fleet[0]` and keeps the order of every other ship.

const FleetLib := preload("res://scripts/fleet/fleet.gd")

## §4.4: locked fleet size (also the buy cap of §4.3).
const FLEET_MAX := FleetLib.FLEET_MAX
## §4.2/§4.3: one cannon occupies this many cargo units.
const CANNON_CARGO_UNITS := FleetLib.CANNON_CARGO_UNITS
## §4.3 refit: 100g per cannon, 50g sell-back each.
const CANNON_PRICE := 100
const CANNON_SELLBACK_PRICE := 50
## §4.3 repair: `ceil(base_price / 400)` per durability point.
const REPAIR_DIVISOR := 400
## §4.3 sell: `floor(base_price × 0.5 × dur / max_dur)`.
const SELL_FRACTION := 0.5

# --- Buy -------------------------------------------------------------------

## §4.3: `ShipType.base_price` is the whole cost.
static func buy_price(ship_type_id: String) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	return int(ship_type.get("base_price", 0))


## §4.3: `gold ≥ price` and `fleet.size() < FLEET_MAX`.
static func can_buy(ship_type_id: String) -> bool:
	return buy_block_reason(ship_type_id).is_empty()


## Why the Buy button of `ship_type_id` is disabled, as a `ui_strings.json`
## key (`""` = allowed). Order matters for the §6 message: the fleet cap wins
## over affordability, because buying at 5 ships is impossible at any price.
static func buy_block_reason(ship_type_id: String) -> String:
	if DataLoader.get_ship_type(ship_type_id).is_empty():
		return "ui.not_available"
	if GameState.fleet.size() >= FLEET_MAX:
		return "shipyard.fleet_full"
	if GameState.gold < buy_price(ship_type_id):
		return "shipyard.no_gold"
	return ""


## §4.3 "Buy ship": pays the price and appends the §4.1 instance with the
## §4.3 defaults (full durability, crew 0, supplies 0, cannons 0, empty hold).
## Returns false without touching gold/fleet when [method can_buy] is false.
static func buy(ship_type_id: String) -> bool:
	if not can_buy(ship_type_id):
		return false
	var ship: Dictionary = FleetLib.new_ship(ship_type_id, 0)
	if ship.is_empty():
		# Unknown type — [method can_buy] already rejects it; belt and braces.
		return false
	GameState.fleet.append(ship)
	GameState.add_gold(-buy_price(ship_type_id))
	FleetLib.notify_changed()
	return true


# --- Repair ----------------------------------------------------------------

## §4.3: repair cost per durability point = `ceil(base_price / 400)`.
static func repair_cost_per_point(ship_type_id: String) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	if ship_type.is_empty():
		return 0
	var base_price := int(ship_type.get("base_price", 0))
	return int(ceil(float(base_price) / float(REPAIR_DIVISOR)))


## §4.3/§6: the damage a hull can still take, i.e. the repair cap.
static func max_repair_points(index: int) -> int:
	var ship := _ship(index)
	if ship.is_empty():
		return 0
	var max_durability := FleetLib.ship_stat(ship, "durability")
	return maxi(0, max_durability - int(ship.get("durability", 0)))


## Cost of `points` on `fleet[index]` (0 for a non-positive/invalid request).
static func repair_cost(index: int, points: int) -> int:
	var ship := _ship(index)
	if ship.is_empty() or points <= 0:
		return 0
	return points * repair_cost_per_point(str(ship.get("ship_type_id", "")))


## Why a repair of `points` is refused, as a `ui_strings.json` key (`""` =
## allowed). §6: 0 points and unaffordable repairs are validation failures, so
## the UI disables the button instead of showing a dialog.
static func repair_block_reason(index: int, points: int) -> String:
	if _ship(index).is_empty():
		return "shipyard.no_selection"
	if points <= 0:
		return "shipyard.invalid_points"
	if points > max_repair_points(index):
		return "shipyard.invalid_points"
	if GameState.gold < repair_cost(index, points):
		return "shipyard.no_gold"
	return ""


## §4.3: `points > 0`, `≤` damage, `gold ≥ cost`.
static func can_repair(index: int, points: int) -> bool:
	return repair_block_reason(index, points).is_empty()


## §4.3 "Repair ship": partial repair is the only kind — exactly `points`
## durability is restored and exactly `cost` gold is paid.
static func repair(index: int, points: int) -> bool:
	if not can_repair(index, points):
		return false
	var ship: Dictionary = GameState.fleet[index]
	var durability := int(ship.get("durability", 0))
	ship["durability"] = mini(
		durability + points, FleetLib.ship_stat(ship, "durability")
	)
	GameState.add_gold(-repair_cost(index, points))
	FleetLib.notify_changed()
	return true


# --- Sell ------------------------------------------------------------------

## §4.3: `floor(base_price × 0.5 × durability / max_durability)`.
static func sell_price(index: int) -> int:
	var ship := _ship(index)
	if ship.is_empty():
		return 0
	var max_durability := FleetLib.ship_stat(ship, "durability")
	if max_durability <= 0:
		return 0
	var base_price := buy_price(str(ship.get("ship_type_id", "")))
	var durability := clampi(int(ship.get("durability", 0)), 0, max_durability)
	return int(floor(
		float(base_price) * SELL_FRACTION * float(durability) / float(max_durability)
	))


## Why `fleet[index]` cannot be sold, as a `ui_strings.json` key (`""` =
## allowed). The last-ship check comes first: when the fleet has one hull it is
## by definition the flagship, and §6 names that case `shipyard.no_sell_last`.
##
## "Cargo aboard must be 0" (§4.3) is enforced over the whole **pooled hold**
## of §4.2 — trade goods *and* provisions/water — because §4.2 pools all three
## across the fleet: a sale that dropped supplies would silently destroy fleet
## resources, which §6 forbids ("never silently"). Cannons are P2's business
## (they have their own 50g sell-back, §4.3) and never exist in Phase 1.
static func sell_block_reason(index: int) -> String:
	var ship := _ship(index)
	if ship.is_empty():
		return "shipyard.no_selection"
	if GameState.fleet.size() <= 1:
		return "shipyard.no_sell_last"
	if index == 0:
		return "shipyard.no_sell_flagship"
	if _hold_units(ship) > 0:
		return "shipyard.cargo_not_empty"
	return ""


## §4.3: not the flagship, not the last ship, empty (pooled) cargo hold.
static func can_sell(index: int) -> bool:
	return sell_block_reason(index).is_empty()


## §4.3 "Sell ship": pays the formula price and removes the hull. Her crew is
## lost — the UI confirms first (§4.3/`80-*` §4.7) — and nothing is transferred
## to another ship: [method can_sell] already requires an empty pooled hold, so
## no goods, provisions or water can vanish here (§6 "never silently").
static func sell(index: int) -> bool:
	if not can_sell(index):
		return false
	var price := sell_price(index)
	GameState.fleet.remove_at(index)
	GameState.add_gold(price)
	FleetLib.notify_changed()
	return true


# --- Refit (Phase 2 maths; the Phase-1 UI row is disabled) ------------------

## §4.3: 100g per cannon.
static func refit_cost(cannons: int) -> int:
	return maxi(cannons, 0) * CANNON_PRICE


## §4.3: 50g back per cannon removed.
static func refit_sellback(cannons: int) -> int:
	return maxi(cannons, 0) * CANNON_SELLBACK_PRICE


## §4.2/§4.3: `cannons × 5` cargo units consumed by an armament refit.
static func refit_cargo_units(cannons: int) -> int:
	return maxi(cannons, 0) * CANNON_CARGO_UNITS


## Spare `armament_slots` and cargo room on `fleet[index]` (§4.3 "≤
## armament_slots", §4.2 cannons share the hold).
static func max_refit(index: int) -> int:
	var ship := _ship(index)
	if ship.is_empty():
		return 0
	var spare_slots := FleetLib.ship_stat(ship, "armament_slots") \
		- int(ship.get("cannons", 0))
	var cargo_room := FleetLib.free_capacity(ship) / CANNON_CARGO_UNITS
	return maxi(0, mini(spare_slots, cargo_room))


## §4.3: at least one cannon, within the slots/cargo cap, affordable.
static func can_refit(index: int, cannons: int) -> bool:
	if cannons <= 0 or cannons > max_refit(index):
		return false
	return GameState.gold >= refit_cost(cannons)


## §4.3 "Refit (armament)". Phase 2 uses this; Phase 1 keeps it unreachable
## from the UI (label `shipyard.cannons.phase2`).
static func refit(index: int, cannons: int) -> bool:
	if not can_refit(index, cannons):
		return false
	var ship: Dictionary = GameState.fleet[index]
	ship["cannons"] = int(ship.get("cannons", 0)) + cannons
	GameState.add_gold(-refit_cost(cannons))
	FleetLib.notify_changed()
	return true


# --- Flagship promotion ----------------------------------------------------

## §4.4: free, port-only, and only meaningful for a non-flagship row.
static func can_promote(index: int) -> bool:
	if _at_sea():
		return false
	return index > 0 and index < GameState.fleet.size()


## §4.4 "Promote": moves `fleet[index]` to `fleet[0]` for free, preserving the
## relative order of every other ship.
static func promote(index: int) -> bool:
	if not can_promote(index):
		return false
	var ship: Dictionary = GameState.fleet[index]
	GameState.fleet.remove_at(index)
	GameState.fleet.insert(0, ship)
	FleetLib.notify_changed()
	return true


# --- Helpers ---------------------------------------------------------------

## `fleet[index]`, or `{}` for an out-of-range index (callers never crash).
static func _ship(index: int) -> Dictionary:
	if index < 0 or index >= GameState.fleet.size():
		return {}
	var ship = GameState.fleet[index]
	return ship if ship is Dictionary else {}


## Everything occupying a ship's hold — the §4.2 "used capacity" minus the
## cannon term, i.e. trade goods + provisions + water. Used by the sell rule so
## no pooled resource is ever dropped silently (§6).
static func _hold_units(ship: Dictionary) -> int:
	var total := int(ship.get("provisions", 0)) + int(ship.get("water", 0))
	var cargo: Dictionary = ship.get("cargo", {})
	for good_id in cargo:
		total += maxi(0, int(cargo[good_id]))
	return total


## §4.4 promotion is a port action: `current_port` is null/empty at sea.
static func _at_sea() -> bool:
	var port = GameState.current_port
	return not (port is String and not (port as String).is_empty())
