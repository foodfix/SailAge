class_name AiFleet
extends RefCounted
## Enemy fleet composition and battle AI (docs/60-COMBAT.md §4.9, §4.11.3,
## §4.11.8).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): [method
## compose_enemy] builds a §4.11.11 ship-instance array from the battle RNG and
## [method decide] returns the §4.12.1.1 `{action, target, cell}` dict the S10
## screen and [method BattleSimLib.run_to_completion] apply.
##
## Every formula that already exists in `battle_sim.gd` is called, never
## copied: the AI asks the sim for range checks, MP and grid adjacency. The
## sim is referenced through this preload (not the `BattleSim` global class
## name) so the file also parses from a fresh checkout with no
## `.godot/global_script_class_cache.cfg` yet.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

## §4.11.3 step 2: the locked hull order (`§4.1 "latin…brigantine"`).
const HULL_IDS: Array[String] = ["latin", "sloop", "caravel", "brigantine"]

## §4.11.3 step 3 cannon budgets; the Phase-5 role map replaces the value for
## its kinds (§4.11.11.2: trader 6 / coaster 2 / courier 0 / patrol 30 /
## privateer 20 / pirate 20, each `+ floor(day / 30)`). Unknown kinds fall
## back to the pirate budget.
const CANNON_BUDGET := {
	"pirate": 20, "navy": 30, "trader": 6, "coaster": 2, "courier": 0,
	"patrol": 30, "privateer": 20,
}
const CANNON_BUDGET_PER_30_DAYS := 1

## §4.11.3 step 5 cargo: `max(1, floor(capacity / 10))` units of one good.
const CARGO_CAPACITY_DIVISOR := 10

## §4.9 rule 1 / §4.7: AI surrender threshold (percent of max durability) and
## the "player ship within N tiles" distance.
const SURRENDER_DURABILITY_PERCENT := 25
const SURRENDER_PLAYER_RANGE := 3

## Per-ship equipment shape of §4.11.11 (both slots empty on spawn).
const EMPTY_EQUIPMENT := {"figurehead": "", "sail": ""}


# --- Composition (docs/60-* §4.11.3) --------------------------------------

## Builds the enemy fleet exactly per §4.11.3, consuming `rng` in the pinned
## order: ship count → hulls → (cannon budget: no RNG) → (crew/durability: no
## RNG) → one cargo good id per ship. Same seed ⇒ identical fleet.
static func compose_enemy(kind: String, day: int, rng: RandomNumberGenerator) -> Array:
	var ships: Array = []
	if rng == null:
		push_error("AiFleet.compose_enemy: rng is null")
		return ships
	var count := _ship_count(kind, rng)
	for _index in count:
		var hull_id := HULL_IDS[rng.randi_range(0, HULL_IDS.size() - 1)]
		ships.append(_base_ship(hull_id))
	_deal_cannons(ships, cannon_budget(kind, day))
	for ship in ships:
		ship["cargo"] = _roll_cargo(ship, rng)
	return ships


## §4.11.3 step 1: pirate 1–3, navy 2–4; the Phase-5 warship roles share the
## navy band (§4.11.11.2: `patrol`/`privateer` roll 2–4, the merchant roles
## 1–3).
static func _ship_count(kind: String, rng: RandomNumberGenerator) -> int:
	var base := 2 if kind == "navy" or kind == "patrol" or kind == "privateer" else 1
	return base + rng.randi_range(0, 2)


## §4.11.3 step 3 cannon budget: `20 + floor(day / 30)` for pirates,
## `30 + floor(day / 30)` for navies. Public so encounter/AI tests can assert
## the bound without duplicating the constant.
static func cannon_budget(kind: String, day: int) -> int:
	var base := int(CANNON_BUDGET.get(kind, CANNON_BUDGET["pirate"]))
	return base + int(floor(float(maxi(day, 0)) / 30.0)) * CANNON_BUDGET_PER_30_DAYS


## §4.11.3 steps 4: `crew = crew_min`, `durability = durability`,
## `provisions = water = 0`, no cannons yet (§4.11.11 instance shape).
static func _base_ship(hull_id: String) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(hull_id)
	return {
		"ship_type_id": hull_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"equipment": EMPTY_EQUIPMENT.duplicate(),
		"cargo": {},
	}


## §4.11.3 step 3: one cannon at a time, round-robin in fleet order, skipping
## a hull at its `armament_slots`, until the budget is exhausted or all full.
static func _deal_cannons(ships: Array, budget: int) -> void:
	var remaining := maxi(budget, 0)
	while remaining > 0:
		var dealt := 0
		for ship in ships:
			if remaining <= 0:
				break
			var slots := int(DataLoader.get_ship_type(
				str(ship.get("ship_type_id", ""))).get("armament_slots", 0))
			if int(ship.get("cannons", 0)) >= slots:
				continue
			ship["cannons"] = int(ship.get("cannons", 0)) + 1
			remaining -= 1
			dealt += 1
		# A whole pass that dealt nothing means every hull is at its
		# `armament_slots`, so the rest of the budget is dropped (§4.11.3).
		if dealt == 0:
			break


## §4.11.3 step 5: `max(1, floor(capacity / 10))` units of one uniformly
## rolled good id (the 20 locked goods).
static func _roll_cargo(ship: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var capacity := int(DataLoader.get_ship_type(
		str(ship.get("ship_type_id", ""))).get("capacity", 0))
	var quantity := maxi(1, int(floor(float(capacity) / CARGO_CAPACITY_DIVISOR)))
	var goods: Array = DataLoader.goods_list
	if goods.is_empty():
		return {}
	var index := rng.randi_range(0, goods.size() - 1)
	var good_id := str(goods[index].get("id", "")) if goods[index] is Dictionary else ""
	if good_id.is_empty():
		return {}
	return {good_id: quantity}


# --- Decisions (docs/60-* §4.9, §4.11.8) ----------------------------------

## The §4.9 priority list, top-down first match, with the §4.11.8 tie-breaks.
## Returns `{action, target, cell}` (§4.12.1.1).
static func decide(sim: BattleSimLib, unit: Dictionary) -> Dictionary:
	var hold := {"action": "hold", "target": {}, "cell": BattleSimLib.NO_CELL}
	if sim == null or not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return hold
	var player_ships := sim.living_units(BattleSimLib.SIDE_PLAYER)
	if player_ships.is_empty():
		return hold

	# 1. Below 25% max durability with a player ship within 3 → surrender.
	var own_ship: Dictionary = unit.get("ship", {})
	var max_durability := sim.effective_max_durability(own_ship)
	if max_durability > 0 \
			and int(own_ship.get("durability", 0)) * 100 < SURRENDER_DURABILITY_PERCENT * max_durability \
			and _nearest(player_ships, sim.unit_cell(unit))["distance"] <= SURRENDER_PLAYER_RANGE:
		return {"action": "surrender", "target": {}, "cell": BattleSimLib.NO_CELL}

	# 2. Cannons ≥ 1, loaded, a player ship in range → fire at the lowest
	#    current durability among the ships in range (ties to the lower fleet
	#    index, §4.11.8).
	var in_range: Array = []
	for candidate in player_ships:
		if sim.can_cannon(unit, candidate):
			in_range.append(candidate)
	var target := _lowest_durability(in_range)
	if not target.is_empty():
		return {"action": "cannon", "target": target, "cell": BattleSimLib.NO_CELL}

	# 3. Own cannons > total player cannons and orthogonally adjacent to the
	#    player flagship → board.
	var own_cannons := int(own_ship.get("cannons", 0))
	var player_cannons := _total_cannons(player_ships)
	var flagship: Dictionary = sim.flagship_unit()
	if flagship.is_empty() or not bool(flagship.get("alive", false)):
		flagship = player_ships[0]  # living_units() is index-ordered
	if own_cannons > player_cannons and _orthogonally_adjacent(sim, unit, flagship):
		return {"action": "board", "target": flagship, "cell": BattleSimLib.NO_CELL}

	# 4. Orthogonally adjacent to a player ship with weaker guns → ram the
	#    adjacent ship with the lowest durability (§4.11.8 tie-break).
	if own_cannons < player_cannons:
		var adjacent: Array = []
		for candidate in player_ships:
			if _orthogonally_adjacent(sim, unit, candidate):
				adjacent.append(candidate)
		var ram_target := _lowest_durability(adjacent)
		if not ram_target.is_empty():
			return {"action": "ram", "target": ram_target, "cell": BattleSimLib.NO_CELL}

	# 5. Move toward the nearest player ship, spending MP greedily.
	var destination := _best_step(sim, unit, player_ships)
	if destination != BattleSimLib.NO_CELL:
		return {"action": "move", "target": {}, "cell": destination}

	# 6. Hold.
	return hold


## §4.11.8 rule 2: lowest current durability, ties to the lower fleet index.
## An empty candidate list yields `{}`.
static func _lowest_durability(candidates: Array) -> Dictionary:
	var best := {}
	var best_durability := 0
	for candidate in candidates:
		var durability := int(candidate.get("ship", {}).get("durability", 0))
		if best.is_empty() or durability < best_durability \
				or (durability == best_durability and int(candidate.index) < int(best.index)):
			best = candidate
			best_durability = durability
	return best


## §4.11.8: the "total player cannons" term uses current cannon counts.
static func _total_cannons(player_ships: Array) -> int:
	var total := 0
	for ship in player_ships:
		total += int(ship.get("ship", {}).get("cannons", 0))
	return total


static func _orthogonally_adjacent(sim: BattleSimLib, unit: Dictionary, other: Dictionary) -> bool:
	var a := sim.unit_cell(unit)
	var b := sim.unit_cell(other)
	return absi(a.x - b.x) + absi(a.y - b.y) == 1


## The nearest player ship by Chebyshev distance (ties to the lower fleet
## index), with the distance attached.
static func _nearest(player_ships: Array, from: Vector2i) -> Dictionary:
	var best := {}
	var best_distance := 0
	for ship in player_ships:
		var cell: Vector2i = ship.get("cell", BattleSimLib.NO_CELL)
		var distance := maxi(absi(cell.x - from.x), absi(cell.y - from.y))
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and int(ship.index) < int(best["unit"].index)):
			best = {"unit": ship, "distance": distance}
			best_distance = distance
	return best


## §4.11.8 rule 5: among reachable tiles prefer the one minimising
## `max(|dx|, |dy|)` to the nearest player ship, then `|dx| + |dy|`, then the
## lowest `(y, x)` cell. Only a strict reduction of the Chebyshev distance
## counts as an improvement; otherwise the ship spends nothing and holds.
static func _best_step(sim: BattleSimLib, unit: Dictionary, player_ships: Array) -> Vector2i:
	var origin := sim.unit_cell(unit)
	var current_distance := int(_nearest(player_ships, origin)["distance"])
	var best := BattleSimLib.NO_CELL
	var best_distance := current_distance
	var best_manhattan := 0
	for cell in sim.legal_moves(unit):
		var nearest := _nearest(player_ships, cell)
		var distance := int(nearest["distance"])
		if distance >= current_distance:
			continue  # no Chebyshev improvement → not a step (§4.11.8)
		var target_cell: Vector2i = nearest["unit"].get("cell", BattleSimLib.NO_CELL)
		var manhattan := absi(cell.x - target_cell.x) + absi(cell.y - target_cell.y)
		if best == BattleSimLib.NO_CELL or distance < best_distance \
				or (distance == best_distance and manhattan < best_manhattan) \
				or (distance == best_distance and manhattan == best_manhattan
					and _cell_before(cell, best)):
			best = cell
			best_distance = distance
			best_manhattan = manhattan
	return best


static func _cell_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x
