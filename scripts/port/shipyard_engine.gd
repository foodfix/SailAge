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
##
## Phase 7 (docs/40-* §4.3.1, docs/60-* §4.11.13, docs/80-* §4.7.12): the
## global catalog rows are replaced by **per-port stock** (`facilities.shipyard`
## / `facilities.equipment_stock` id lists) under the universal filter
## `purchasable = in_stock ∧ tier ≤ effective_dev(port)`. Rows render in
## exactly **three states** — available / tier-gray 需发展度 / allegiance-gray
## 同盟专营 (correction 11: an unallied neutral shows its full list
## allegiance-locked, never an empty catalog). Rare equipment (`rare: true`)
## is drop-only (60-* §4.11.13) and is filtered out defensively even if a
## stock list ever carried one.
##
## `effective_dev` / `effective_alignment` **guard-read** the allegiance
## module (task L, `scripts/port/allegiance.gd`, the C contract of 80-* §4.9)
## with the safe fallbacks: the port's authored data floor (`ports.json` `dev`)
## and the port's data `nation_id`. The guard (order-independent merges) is the
## Phase-6 pattern: `ResourceLoader.exists` + `has_method` before any call.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const FameLib := preload("res://scripts/player/fame.gd")

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

# --- Per-port stock & tier gating (Phase 7; 40-* §4.3.1, 80-* §4.7.12) ------

## The three §4.7.12 row states (strings so screens and suites can switch on
## them without an enum registry).
const ROW_AVAILABLE := "available"
const ROW_TIER_GRAY := "tier_gray"
const ROW_ALLEGIANCE_GRAY := "allegiance_gray"
## The gray-state notes (`80-*` §4.7.15 inventory — the master merges them;
## until then the screens fall back, never printing a raw "<key>").
const TIER_NEED_DEV_KEY := "shipyard.tier.need_dev"
const ALLEGIANCE_LOCKED_KEY := "shipyard.tier.allegiance_locked"
## The allegiance module guard-read path (the C contract, `80-*` §4.9).
const ALLEGIANCE_PATH := "res://scripts/port/allegiance.gd"


## The allegiance module when task L's file has landed, else `null`. Loads by
## path (not `preload`) so this module merges green before it exists.
static func _allegiance():
	if not ResourceLoader.exists(ALLEGIANCE_PATH):
		return null
	return ResourceLoader.load(ALLEGIANCE_PATH)


## Guarded one-argument allegiance call: `fallback` when the module or the
## method is absent (the 80-* §4.9 guard convention).
static func _allegiance_call(method: String, port_id: String,
		fallback: Variant) -> Variant:
	var module = _allegiance()
	if module == null or not module.has_method(method):
		return fallback
	return module.call(method, port_id)


## `port_id` when given, else the docked port (`""` at sea / standalone).
static func _resolve_port(port_id: String) -> String:
	if not port_id.is_empty():
		return port_id
	var value = GameState.current_port
	return value if value is String else ""


## The authored development floor of `ports.json` (`30-*` §4.9: capitals and
## protected ports 3, sovereign majors 2, the rest 1, neutrals 0). This IS the
## guard fallback for [method effective_dev].
static func authored_dev(port_id: String) -> int:
	return int(DataLoader.get_port(port_id).get("dev", 0))


## §4.9 effective development: the allegiance module's derived level
## (authored floor vs ledger thresholds) when present, else the authored
## floor itself.
static func effective_dev(port_id: String) -> int:
	var guarded = _allegiance_call("dev", port_id, null)
	return int(guarded) if guarded != null else authored_dev(port_id)


## §4.9 effective alignment: the allegiance module's answer when present,
## else the port's data `nation_id`.
static func effective_alignment(port_id: String) -> String:
	var guarded = _allegiance_call("effective_alignment", port_id, null)
	if guarded is String:
		return guarded
	return str(DataLoader.get_port(port_id).get("nation_id", ""))


## An **unallied neutral**: `nation_id: ""` and no allegiance either (the
## §4.7.12 allegiance-gray condition).
static func is_unallied_neutral(port_id: String) -> bool:
	var port: Dictionary = DataLoader.get_port(port_id)
	if str(port.get("nation_id", "")) != "":
		return false
	return effective_alignment(port_id) == ""


## `tier: 1|2|3` of a ship type or equipment item (1 when absent — never a
## crash on hand-edited data).
static func item_tier(item_id: String) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(item_id)
	if not ship_type.is_empty():
		return maxi(1, int(ship_type.get("tier", 1)))
	return maxi(1, int(DataLoader.get_equipment(item_id).get("tier", 1)))


## `60-*` §4.11.13: rare items are drop-only and never stocked.
static func is_rare_equipment(equipment_id: String) -> bool:
	return bool(DataLoader.get_equipment(equipment_id).get("rare", false))


## The §4.7.12 state of `item_id` (ship or equipment) at `port_id`.
static func row_state(port_id: String, item_id: String) -> String:
	if is_unallied_neutral(port_id):
		return ROW_ALLEGIANCE_GRAY
	if item_tier(item_id) > effective_dev(port_id):
		return ROW_TIER_GRAY
	return ROW_AVAILABLE


## The `ui_strings` note of the gray state (`""` when available).
static func row_note_key(port_id: String, item_id: String) -> String:
	match row_state(port_id, item_id):
		ROW_TIER_GRAY:
			return TIER_NEED_DEV_KEY
		ROW_ALLEGIANCE_GRAY:
			return ALLEGIANCE_LOCKED_KEY
	return ""


## The ids this port's `facility` (`shipyard` / `equipment_stock`) stocks, in
## the port's data order, filtered to known ids (and to non-rare equipment —
## `60-*` §4.11.13 "never in any stock list", defensively). An empty
## `resolved` port (standalone / at sea) returns the full catalog minus rares,
## so a standalone screen never renders an empty crash state.
static func _stock_ids(port_id: String, facility: String, catalog: Array,
		rare_gated: bool) -> Array[String]:
	var ids: Array[String] = []
	var known := {}
	for entry in catalog:
		if entry is Dictionary:
			var entry_id := str((entry as Dictionary).get("id", ""))
			if rare_gated and is_rare_equipment(entry_id):
				continue
			known[entry_id] = true
	if port_id.is_empty():
		# Insertion order = the catalog's data order (Dictionary keeps it).
		for id in known:
			ids.append(str(id))
		return ids
	var facilities = DataLoader.get_port(port_id).get("facilities", {})
	if not (facilities is Dictionary):
		return ids
	var payload = (facilities as Dictionary).get(facility, null)
	if not (payload is Array):
		return ids
	for entry in payload:
		var id := str(entry)
		if known.has(id) and not (rare_gated and is_rare_equipment(id)):
			ids.append(id)
	return ids


## The hull ids stocked at `port_id` ("" = docked port; no port = the full
## catalog fallback, `40-*` §4.3.1).
static func shipyard_stock(port_id: String = "") -> Array[String]:
	return _stock_ids(_resolve_port(port_id), "shipyard",
		DataLoader.ship_types_list, false)


## The equipment ids stocked at `port_id` ("" = docked port; no port = the
## full non-rare catalog fallback, `60-*` §4.11.13).
static func equipment_stock(port_id: String = "") -> Array[String]:
	return _stock_ids(_resolve_port(port_id), "equipment_stock",
		DataLoader.equipment_list, true)


## `60-*` §4.11.12: every item of `slot` the docked port stocks (its
## `equipment_stock` order), non-rare only. With no docked port the fallback
## is every non-rare item of the slot in data order (standalone screens).
## Above-dev and allegiance-locked items stay in the list — graying them is
## the screen's §4.7.12 job; refusing them is [method equip_block_reason]'s.
static func equipment_list(slot: String, port_id: String = "") -> Array:
	var items: Array = []
	if not (slot in PLAYER_SLOTS or slot in SHIP_SLOTS):
		return items
	var stock := equipment_stock(port_id)
	var by_id := {}
	for item in DataLoader.equipment_list:
		if item is Dictionary and str((item as Dictionary).get("slot", "")) == slot:
			by_id[str((item as Dictionary).get("id", ""))] = item
	for id in stock:
		if by_id.has(id):
			items.append(by_id[id])
	return items


# --- Buy -------------------------------------------------------------------

## §4.3: `ShipType.base_price` is the whole cost.
static func buy_price(ship_type_id: String) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	return int(ship_type.get("base_price", 0))


## §4.3: `gold ≥ price` and `fleet.size() < FLEET_MAX`.
static func can_buy(ship_type_id: String) -> bool:
	return buy_block_reason(ship_type_id).is_empty()


## Why the Buy button of `ship_type_id` is disabled, as a `ui_strings.json`
## key (`""` = allowed). Order matters for the §6 message: the port gates come
## first (an unstocked or above-dev hull is unbuyable at any price or fleet
## size), then the fleet cap (buying at 5 ships is impossible at any price),
## then affordability.
##
## The gray-state keys (`shipyard.tier.need_dev` / `.allegiance_locked`) carry
## a `{dev}` placeholder in the first case — the screen renders the note
## (80-* §4.7.12) rather than the raw key.
static func buy_block_reason(ship_type_id: String) -> String:
	if DataLoader.get_ship_type(ship_type_id).is_empty():
		return "ui.not_available"
	var port := _resolve_port("")
	if not port.is_empty():
		if not shipyard_stock(port).has(ship_type_id):
			return "ui.not_available"
		var note := row_note_key(port, ship_type_id)
		if not note.is_empty():
			return note
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
## Phase 3: at a port of a nation whose title is count or higher the total is
## multiplied by `0.8` and floored once (`70-*` §4.9.2). `port_id` defaults to
## the docked port; the palace bays pass their own port explicitly.
static func repair_cost(index: int, points: int, port_id: String = "") -> int:
	var raw := raw_repair_cost(index, points)
	if raw <= 0:
		return 0
	var discounted := float(raw) * FameLib.repair_discount(_port_nation(port_id))
	return maxi(0, int(ceil(discounted)))


## The undiscounted §4.3 price of `points` (`points × ceil(base_price / 400)`).
static func raw_repair_cost(index: int, points: int) -> int:
	var ship := _ship(index)
	if ship.is_empty() or points <= 0:
		return 0
	return points * repair_cost_per_point(str(ship.get("ship_type_id", "")))


## The nation of `port_id` (default: the docked port); `""` outside a port.
static func _port_nation(port_id: String) -> String:
	var resolved := port_id
	if resolved.is_empty():
		resolved = str(GameState.current_port) if GameState.current_port is String else ""
	if resolved.is_empty():
		return ""
	return str(DataLoader.get_port(resolved).get("nation_id", ""))


## Why a repair of `points` is refused, as a `ui_strings.json` key (`""` =
## allowed). §6: 0 points and unaffordable repairs are validation failures, so
## the UI disables the button instead of showing a dialog.
static func repair_block_reason(index: int, points: int,
		port_id: String = "") -> String:
	if _ship(index).is_empty():
		return "shipyard.no_selection"
	if points <= 0:
		return "shipyard.invalid_points"
	if points > max_repair_points(index):
		return "shipyard.invalid_points"
	if GameState.gold < repair_cost(index, points, port_id):
		return "shipyard.no_gold"
	return ""


## §4.3: `points > 0`, `≤` damage, `gold ≥ cost`.
static func can_repair(index: int, points: int, port_id: String = "") -> bool:
	return repair_block_reason(index, points, port_id).is_empty()


## §4.3 "Repair ship": partial repair is the only kind — exactly `points`
## durability is restored and exactly `cost` gold is paid. The cap is the
## **effective** max (§4.1), so a worn figurehead can be repaired onto.
static func repair(index: int, points: int, port_id: String = "") -> bool:
	if not can_repair(index, points, port_id):
		return false
	var ship: Dictionary = GameState.fleet[index]
	var durability := int(ship.get("durability", 0))
	ship["durability"] = mini(durability + points, ship_max_durability(index))
	GameState.add_gold(-repair_cost(index, points, port_id))
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


## `60-*` §4.11.12: the item id worn in the player's `slot` ("" when empty/absent). Missing
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
## `ui.not_available`; a missing hull for a ship slot likewise; Phase 7 adds
## the stock gates — a rare item, an item not on this port's
## `equipment_stock`, or a gray-state row (`ui.not_available` /
## `shipyard.tier.*` note keys) — and finally an unaffordable net cost is
## `shipyard.no_gold`.
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
	var port := _resolve_port("")
	if not port.is_empty():
		# Rare items are drop-only (60-* §4.11.13) and never stocked; the
		# rare flag is checked first so a corrupt stock list cannot leak one.
		if is_rare_equipment(equipment_id) \
				or not equipment_stock(port).has(equipment_id):
			return "ui.not_available"
		var note := row_note_key(port, equipment_id)
		if not note.is_empty():
			return note
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
