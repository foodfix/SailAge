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
##     `armament_slots`. Phase 1 had **no** refit UI (§4.3 "present but
##     disabled"); Phase 2 enables the row (`80-*` §4.7.2).
##   * Equipment works per `60-*` §4.11.12: `weapon`/`armor` live on the
##     player, `figurehead`/`sail` on one hull. Buying into an occupied slot
##     sells the old item back at `floor(price × 0.5)` in the same transaction.
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
## docs/40-* §4.1: repairs use the **effective** max durability, so a worn
## figurehead raises the cap exactly as it raises the hull's maximum.
static func max_repair_points(index: int) -> int:
	var ship := _ship(index)
	if ship.is_empty():
		return 0
	return maxi(0, ship_max_durability(index) - int(ship.get("durability", 0)))


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
## durability is restored and exactly `cost` gold is paid. The cap is the
## **effective** max (§4.1), so a worn figurehead can be repaired onto.
static func repair(index: int, points: int) -> bool:
	if not can_repair(index, points):
		return false
	var ship: Dictionary = GameState.fleet[index]
	var durability := int(ship.get("durability", 0))
	ship["durability"] = mini(durability + points, ship_max_durability(index))
	GameState.add_gold(-repair_cost(index, points))
	FleetLib.notify_changed()
	return true


# --- Sell ------------------------------------------------------------------

## §4.3: `floor(base_price × 0.5 × durability / max_durability)`.
##
## `max_durability` is the **effective** max of §4.1: a worn figurehead can
## raise a hull above its `ShipType.durability`, and since equipment leaves
## with the ship the ratio must stay `≤ 1` (otherwise a figurehead would let a
## hull sell for more than half its base price). Without equipment this is
## exactly the Phase-1 formula.
static func sell_price(index: int) -> int:
	var ship := _ship(index)
	if ship.is_empty():
		return 0
	var max_durability := ship_max_durability(index)
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


# --- Refit (Phase 2: the UI row is live, `80-*` §4.7.2) ---------------------

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
	return refit_block_reason(index, cannons).is_empty()


## Why a refit of `cannons` is refused, as a `ui_strings.json` key (`""` =
## allowed). The UI disables the button and shows this as the tooltip (§4.7.2,
## `80-*` §4.7 "disabled with tooltip-reason").
static func refit_block_reason(index: int, cannons: int) -> String:
	if _ship(index).is_empty():
		return "shipyard.no_selection"
	if cannons <= 0 or cannons > max_refit(index):
		return "shipyard.invalid_points"
	if GameState.gold < refit_cost(cannons):
		return "shipyard.no_gold"
	return ""


## §4.3 "Refit (armament)". Live in Phase 2 (`80-*` §4.7.2); the battle
## effect is `60-*` §4.11.4.
static func refit(index: int, cannons: int) -> bool:
	if not can_refit(index, cannons):
		return false
	var ship: Dictionary = GameState.fleet[index]
	ship["cannons"] = int(ship.get("cannons", 0)) + cannons
	GameState.add_gold(-refit_cost(cannons))
	FleetLib.notify_changed()
	return true


# --- Equipment (Phase 2; `60-*` §4.11.12, `40-*` §4.3, `50-*` §4.8) --------

## `60-*` §4.11.12: `weapon`/`armor` are worn by the player, `figurehead`/`sail`
## are bound to one hull.
const PLAYER_SLOTS: Array[String] = ["weapon", "armor"]
const SHIP_SLOTS: Array[String] = ["figurehead", "sail"]
## `40-*` §4.3 / `60-*` §4.11.12: selling an item back pays
## `floor(price × 0.5)`, the same fraction as a hull.
const EQUIP_SELL_FRACTION := 0.5


## `60-*` §4.11.12: every `data/equipment.json` item of `slot`, in **data
## order** (the shipyard list order, `80-*` §4.7.2). An unknown slot is empty.
static func equipment_list(slot: String) -> Array:
	var items: Array = []
	if not (slot in PLAYER_SLOTS or slot in SHIP_SLOTS):
		return items
	for item in DataLoader.equipment_list:
		if item is Dictionary and str(item.get("slot", "")) == slot:
			items.append(item)
	return items


## The item id worn in the player's `slot` ("" when empty/absent). Missing
## `equipment` blocks read as empty slots (`60-*` §4.11.12) — never a crash.
static func equipped_player(slot: String) -> String:
	if not (slot in PLAYER_SLOTS):
		return ""
	var block = _player_equipment(false)
	return _slot_value(block, slot)


## The item id worn in `fleet[ship_index]`'s `slot` ("" when empty/absent).
static func equipped_ship(index: int, slot: String) -> String:
	if not (slot in SHIP_SLOTS):
		return ""
	var ship := _ship(index)
	if ship.is_empty():
		return ""
	var block = _ship_equipment(ship, false)
	return _slot_value(block, slot)


## §4.3: the item's `price` (0 for an unknown item).
static func equip_price(_slot: String, equipment_id: String) -> int:
	return int(DataLoader.get_equipment(equipment_id).get("price", 0))


## §4.3: `floor(price × 0.5)` when selling the item back.
static func equip_sellback(_slot: String, equipment_id: String) -> int:
	return int(floor(float(equip_price(_slot, equipment_id)) * EQUIP_SELL_FRACTION))


## Why buying `equipment_id` into `slot` is refused, as a `ui_strings.json`
## key (`""` = allowed): an unknown item or a slot mismatch is
## `ui.not_available`; an unaffordable net cost is `shipyard.no_gold`.
##
## The net cost is `-new_price + old_sellback` (§4.3: the replaced item sells
## back "in the same action"), so replacing a 400g cutlass with a 1200g rapier
## only needs 1000g in the purse.
static func equip_block_reason(slot: String, equipment_id: String,
		ship_index: int = 0) -> String:
	var item: Dictionary = DataLoader.get_equipment(equipment_id)
	if item.is_empty() or str(item.get("slot", "")) != slot:
		return "ui.not_available"
	if slot in SHIP_SLOTS and _ship(ship_index).is_empty():
		return "ui.not_available"
	# The purse must survive the **net** delta, which is negative for a normal
	# buy and may even be positive when the replaced item is worth more.
	if GameState.gold + equip_net_cost(slot, equipment_id, ship_index) < 0:
		return "shipyard.no_gold"
	return ""


## The gold change of [method equip]'s whole transaction:
## `−new_price + old_sellback` (§4.3, "in the same action").
static func equip_net_cost(slot: String, equipment_id: String,
		ship_index: int = 0) -> int:
	var old_id := _worn_id(slot, ship_index)
	var sellback := equip_sellback(slot, old_id) if not old_id.is_empty() else 0
	return -equip_price(slot, equipment_id) + sellback


## §4.3 "Buy equipment": buys `equipment_id` into `slot`, selling whatever the
## slot held back at half price **in the same transaction** (one
## `add_gold(net)` call, so the HUD sees one `gold_changed`).
##
## `weapon`/`armor` write `GameState.player.equipment`;
## `figurehead`/`sail` write `GameState.fleet[ship_index].equipment`. The blocks
## are created when absent (`60-*` §4.11.12: old saves default to empty slots).
## Returns false without touching gold/state when blocked.
static func equip(slot: String, equipment_id: String, ship_index: int = 0) -> bool:
	if not equip_block_reason(slot, equipment_id, ship_index).is_empty():
		return false
	var block: Dictionary = _equipment_block(slot, ship_index, true)
	if block.is_empty():
		return false
	var net := equip_net_cost(slot, equipment_id, ship_index)
	block[slot] = equipment_id
	GameState.add_gold(net)
	_clamp_durability(slot, ship_index)
	_notify_equipped()
	return true


## Clears `slot` and pays the half-price sell-back (§4.3). Returns false when
## the slot is already empty (nothing to do, nothing to pay).
static func unequip(slot: String, ship_index: int = 0) -> bool:
	var worn := _worn_id(slot, ship_index)
	if worn.is_empty():
		return false
	var block: Dictionary = _equipment_block(slot, ship_index, false)
	if block.is_empty():
		return false
	block[slot] = ""
	GameState.add_gold(equip_sellback(slot, worn))
	_clamp_durability(slot, ship_index)
	_notify_equipped()
	return true


## True when `slot` holds nothing ([method unequip] would be a no-op).
static func can_unequip(slot: String, ship_index: int = 0) -> bool:
	return not _worn_id(slot, ship_index).is_empty()


## A single modifier of one item (`0` for an unknown item or stat).
static func equipment_modifier(equipment_id: String, stat_name: String) -> int:
	var item: Dictionary = DataLoader.get_equipment(equipment_id)
	if item.is_empty():
		return 0
	var modifiers = item.get("modifiers", {})
	if not (modifiers is Dictionary):
		return 0
	return int((modifiers as Dictionary).get(stat_name, 0))


## `60-*` §4.11.6: the player's duel roll adds Σ `combat` across the two worn
## player items (`weapon` + `armor`). This is the duel-roll hook `battle_sim`
## reads; `battle_sim.gd` is a different task's file, so no logic lands there.
static func player_combat_bonus() -> int:
	var total := 0
	for slot in PLAYER_SLOTS:
		total += equipment_modifier(equipped_player(slot), "combat")
	return total


## `40-*` §4.1 / `60-*` §4.11.12: `ShipType.durability` plus the worn
## figurehead's `durability` modifier — the effective maximum, which also caps
## repairs and current durability.
static func ship_max_durability(index: int) -> int:
	var ship := _ship(index)
	if ship.is_empty():
		return 0
	return FleetLib.ship_stat(ship, "durability") \
		+ equipment_modifier(equipped_ship(index, "figurehead"), "durability")


## `60-*` §4.11.12: the sail `speed` modifier (MP + initiative in `60-*`
## §4.11.4).
static func ship_speed_bonus(index: int) -> int:
	return equipment_modifier(equipped_ship(index, "sail"), "speed")


## The id worn in `slot` on the player (weapon/armor) or on `ship_index`
## (figurehead/sail); "" for an unknown slot or empty/missing block.
static func _worn_id(slot: String, ship_index: int) -> String:
	if slot in PLAYER_SLOTS:
		return equipped_player(slot)
	if slot in SHIP_SLOTS:
		return equipped_ship(ship_index, slot)
	return ""


## Reads the `equipment` block for `slot`'s owner without creating anything.
static func _equipment_block(slot: String, ship_index: int,
		create: bool) -> Dictionary:
	if slot in PLAYER_SLOTS:
		return _player_equipment(create)
	if slot in SHIP_SLOTS:
		var ship := _ship(ship_index)
		if ship.is_empty():
			return {}
		return _ship_equipment(ship, create)
	return {}


## `GameState.player.equipment`, read-only unless `create` (then written in
## place when absent/invalid — `60-*` §4.11.12 "the accessors default").
static func _player_equipment(create: bool) -> Dictionary:
	var player = GameState.player
	if not (player is Dictionary):
		return {}
	var block = (player as Dictionary).get("equipment", null)
	if block is Dictionary:
		return block
	if not create:
		return {}
	var fresh := {"weapon": "", "armor": ""}
	(player as Dictionary)["equipment"] = fresh
	return fresh


## `ship.equipment`, same contract as [method _player_equipment].
static func _ship_equipment(ship: Dictionary, create: bool) -> Dictionary:
	var block = ship.get("equipment", null)
	if block is Dictionary:
		return block
	if not create:
		return {}
	var fresh := {"figurehead": "", "sail": ""}
	ship["equipment"] = fresh
	return fresh


## Tolerant slot read: a missing key, a null or a non-string all read as empty.
static func _slot_value(block: Dictionary, slot: String) -> String:
	var value = block.get(slot, "")
	if not (value is String):
		return ""
	return value


## `40-*` §4.1: "`durability` is clamped to" the effective max. Swapping or
## removing a figurehead can lower that cap, so the hull is clamped here — the
## only place equipment can shrink it. Equipping never *heals*: current
## durability is left where it was when the cap rises.
static func _clamp_durability(slot: String, ship_index: int) -> void:
	if not (slot in SHIP_SLOTS) or slot == "sail":
		return
	var ship := _ship(ship_index)
	if ship.is_empty():
		return
	var current := int(ship.get("durability", 0))
	var maximum := ship_max_durability(ship_index)
	if current > maximum:
		ship["durability"] = maximum


## Both equipment owners are shown on the shipyard screen (`80-*` §4.7.2), so
## either change announces `fleet_changed` to repaint every equipment row
## (`90-*` §5.1). Gold rides its own single `gold_changed` from `add_gold`.
static func _notify_equipped() -> void:
	FleetLib.notify_changed()


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
