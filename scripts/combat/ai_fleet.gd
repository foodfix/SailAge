class_name AiFleet
extends RefCounted
## Enemy fleet composition and battle AI (docs/60-COMBAT.md §4.4, §4.9a,
## §4.11.3, §4.11.8).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): [method
## compose_enemy] builds a §4.11.11 ship-instance array from the battle RNG —
## with the §4.4 broadside split written onto every ship — and [method decide]
## returns the §4.12.1.1 `{action, target, vel}` decision dict the S10 screen
## and [method BattleSimLib.run_to_completion] apply (`cell` is derived by the
## executor as `pos + vel`, never authored; `side` / `shot` ride the cannon
## decision explicitly per §4.11.8 pin 2).
##
## The T2 enemy AI is the §4.9a deterministic greedy priority list —
## surrender roll → flee → fire → kite → board ≥ ram → close → hold —
## consuming the per-kind profile from `data/npc_config.json` `ai_profiles`
## (§4.10, lookup correction 8). Every velocity choice enumerates
## `BattleSimLib.legal_velocities(unit)` in its (y, x) lexicographic order and
## takes the FIRST candidate achieving the objective (§4.11.8 pin 1 — the
## enumeration IS the tie-break). Distance math is judged on `pos + vel`
## without a sweep preview: the §4.3a sweep can only shorten a move, never
## lengthen it.
##
## Every formula that already exists in `battle_sim.gd` is called, never
## copied: the AI asks the sim for velocity legality, per-side arc/range
## checks, the §4.4b shot rule and the §4.7 surrender roll. The sim is
## referenced through this preload (not the `BattleSim` global class name) so
## the file also parses from a fresh checkout with no
## `.godot/global_script_class_cache.cfg` yet.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

## §4.11.3 step 2: the locked hull order (`§4.1 "latin…brigantine"`).
const HULL_IDS: Array[String] = ["latin", "sloop", "caravel", "brigantine"]

## §4.11.3 step 3 cannon budgets; the Phase-5 role map replaces the value for
## its kinds (§4.11.11.2: trader 6 / coaster 2 / courier 0 / patrol 30 /
## privateer 20 / pirate 20, each `+ floor(day / 30)`; §4.11.11.4: a treasure
## fleet arms 30 whole-fleet cannons). Unknown kinds fall back to the pirate
## budget.
const CANNON_BUDGET := {
	"pirate": 20, "navy": 30, "trader": 6, "coaster": 2, "courier": 0,
	"patrol": 30, "privateer": 20, "treasure": 30,
}
const CANNON_BUDGET_PER_30_DAYS := 1

## §4.11.3 step 5 cargo: `max(1, floor(capacity / 10))` units of one good.
const CARGO_CAPACITY_DIVISOR := 10

## §4.9 rule 1 / §4.7: AI surrender threshold (percent of max durability) and
## the "player ship within N tiles" distance. (The Phase-9 §4.7 gate proper
## is morale ≤ 20 ∧ durability ≤ 25% — the morale half lands with W4; the
## proximity clause stays as the W3-era trigger until then.)
const SURRENDER_DURABILITY_PERCENT := 25
const SURRENDER_PLAYER_RANGE := 3

## §4.9a T2 pins. Every non-profile number the priority list needs is one of
## these or a sim constant — nothing invented:
const FLEE_AGGRESSION_MAX := 25        # flee clause: "aggression < 25"
const CLOSE_DECELERATION_RANGE := 2    # close clause: "Chebyshev ≤ 2"
const HOOK_SPEED_MAX := 1              # the §4.6a hook window: ‖vel‖ ≤ 1
const RAM_SPEED_MIN := 2               # ram clause: floor(‖vel‖) ≥ 2
const BOARD_DURABILITY_PERCENT := 25   # board clause: "target hp% ≤ 25"

## Correction-8 lookup: a `hunter` battle reads the `navy` row (mirrors
## `NpcFleets.composition_kind`). `coaster` never battles — the row is
## forward-compat + sandbox-only, so no special handling beyond the lookup.
const PROFILE_HUNTER_KIND := "hunter"
const PROFILE_NAVY_ROW := "navy"
const PROFILE_PIRATE_ROW := "pirate"

## The empty-safe profile (the §4.10 locked `pirate` row verbatim): returned
## when the whole `ai_profiles` block is missing so headless tools never crash.
const DEFAULT_PROFILE := {
	"kind": "pirate",
	"archetype": "aggressive",
	"aggression": 90,
	"preferred_range": 2,
	"flee_below_hp_pct": 0,
	"focus": "weakest",
	"courage_mod": 5,
	"formation": "swarm",
	"ai_level": 1,
}

## Per-ship equipment shape of §4.11.11 (both slots empty on spawn).
const EMPTY_EQUIPMENT := {"figurehead": "", "sail": ""}


# --- Profiles (docs/60-* §4.9a, 10-* §4.10) ---------------------------------

## The §4.9a profile row for a battle kind: `DataLoader.npc_config`'s
## `ai_profiles[kind]`. Correction 8: `hunter` reads the `navy` row; an
## unknown kind falls back to the `pirate` row; a missing config block
## degrades to [constant DEFAULT_PROFILE]. Pure — no caching, no mutation.
static func profile_for(kind: String) -> Dictionary:
	var resolved := kind
	if resolved == PROFILE_HUNTER_KIND:
		resolved = PROFILE_NAVY_ROW
	var config = DataLoader.npc_config
	var profiles := {}
	if config is Dictionary and (config.get("ai_profiles", {}) is Dictionary):
		profiles = config["ai_profiles"]
	var row = profiles.get(resolved, profiles.get(PROFILE_PIRATE_ROW, {}))
	if row is Dictionary and not (row as Dictionary).is_empty():
		return (row as Dictionary).duplicate()
	return DEFAULT_PROFILE.duplicate()


# --- Composition (docs/60-* §4.11.3) ----------------------------------------

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
	_write_broadside_split(ships)
	for ship in ships:
		ship["cargo"] = _roll_cargo(ship, rng)
	return ships


## §4.11.3 step 1: pirate 1–3, navy 2–4; the Phase-5 warship roles share the
## navy band (§4.11.11.2: `patrol`/`privateer` roll 2–4, the merchant roles
## 1–3); a `treasure` fleet rolls 3–5 merchants plus one escort (§4.11.11.4).
static func _ship_count(kind: String, rng: RandomNumberGenerator) -> int:
	if kind == "treasure":
		return 3 + rng.randi_range(0, 2) + 1
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


## §4.4 broadside split (decision 3/14), written at composition:
## `cannons_port = floor(cannons / 2)`, `cannons_starboard` the rest. The
## TOTAL `cannons` is retained on the ship — the outcome/rewards blocks
## consume it. The sim derives the same split itself at battle start when the
## fields are absent and accepts a ship-carried pair that sums to the total,
## so composition and engine agree by construction.
static func _write_broadside_split(ships: Array) -> void:
	for ship in ships:
		var total := maxi(int(ship.get("cannons", 0)), 0)
		var port := int(floor(float(total) / BattleSimLib.BROADSIDE_SPLIT_DIVISOR))
		ship["cannons_port"] = port
		ship["cannons_starboard"] = total - port


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


# --- Decisions (docs/60-* §4.9a, §4.11.8) -----------------------------------

## The §4.9a T2 priority list, top-down first match: ① surrender roll
## ② flee ③ fire ④ kite ⑤ board ≥ ram ⑥ close ⑦ hold. Returns the
## §4.12.1.1 decision dict (`cell` derived by the executor, never authored).
## Deterministic and pure — the only RNG is the sim's own §4.7 roll stream.
static func decide(sim: BattleSimLib, unit: Dictionary) -> Dictionary:
	var hold := {"action": "hold", "target": {}, "vel": Vector2i.ZERO}
	if sim == null or not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return hold
	var player_ships: Array = sim.living_units(BattleSimLib.SIDE_PLAYER)
	if player_ships.is_empty():
		return hold

	var profile := profile_for(str(sim.enemy_kind))
	var courage_mod := int(profile.get("courage_mod", 0))
	var own_ship: Dictionary = unit.get("ship", {})
	var max_durability := sim.effective_max_durability(own_ship)
	var origin := sim.unit_cell(unit)
	var nearest: Dictionary = _nearest(sim, player_ships, origin)
	var nearest_cell: Vector2i = sim.unit_cell(nearest["unit"])
	var distance := int(nearest["distance"])
	var legal: Array = sim.legal_velocities(unit)

	# ① §4.7 surrender roll: below the durability gate with a player ship
	#    within 3 (the W3-era trigger). The chance is the sim's §4.7
	#    `surrender_chance(unit, courage_mod)` — the profile `courage_mod`
	#    folded into the effective courage (§4.9a) — and the roll is drawn
	#    from the battle's §4.11.1 stream; a failed roll re-rolls next turn.
	#    W4: gate widens to side morale ≤ 20 (§4.7/§4.8a).
	if max_durability > 0 \
			and int(own_ship.get("durability", 0)) * 100 \
				< SURRENDER_DURABILITY_PERCENT * max_durability \
			and distance <= SURRENDER_PLAYER_RANGE:
		if sim.roll_surrender(unit, courage_mod):
			return {"action": "surrender", "target": {}, "vel": Vector2i.ZERO}

	# ② §4.9a flee: hp% below the profile gate, or aggression < 25. The first
	#    legal velocity strictly increasing the Chebyshev distance to the
	#    nearest player ship, judged on `pos + vel` (§4.11.8 pin 5); hold when
	#    none — a cornered fleer does not fall through to the guns.
	#    W4: gate widens to side morale ≤ 20 (§4.8a, the pre-fleet-layer reading).
	var flee_hp := int(profile.get("flee_below_hp_pct", 0))
	var wants_flee := max_durability > 0 \
		and int(own_ship.get("durability", 0)) * 100 < flee_hp * max_durability
	if int(profile.get("aggression", 0)) < FLEE_AGGRESSION_MAX:
		wants_flee = true
	if wants_flee:
		for vel in legal:
			if _chebyshev(origin + vel, nearest_cell) > distance:
				return {"action": "move", "target": {}, "vel": vel}
		return hold

	# ③ §4.11.8 pin 2 fire: rake preference → profile focus → loaded side
	#    with more cannons (tie → port); the shot type is the §4.4b rule's.
	var fire := _fire_decision(sim, unit, profile, player_ships)
	if not fire.is_empty():
		return fire

	# ④ §4.9a kite: both broadside reload windows active → steer so the
	#    resulting Chebyshev distance (pos + vel) meets the profile
	#    `preferred_range` (§4.11.8 pin 3).
	var round_no := sim.round_number()
	if round_no < int(unit.get("reload_port", 1)) \
			and round_no < int(unit.get("reload_starboard", 1)):
		var kite := _kite_step(sim, unit, legal, nearest,
			int(profile.get("preferred_range", 0)))
		if kite != BattleSimLib.NO_CELL:
			return {"action": "move", "target": {}, "vel": kite}

	# ⑤ Board ranks above ram (decision 13). Board: the §4.6a hook legal AND
	#    (own crew + duel rating > the target's OR target hp% ≤ 25).
	#    Ram: floor(‖vel‖) ≥ 2 possible AND own cannons + duel rating > the
	#    target's — delivered either as the adjacent-action ram or as the
	#    first legal velocity whose §4.3a sweep enters the target (the sweep
	#    IS the §4.5 ram; authoring it as a move keeps the executor from
	#    re-striking a ram survivor).
	var boarding := _boarding_target(sim, unit, player_ships)
	if not boarding.is_empty():
		return {"action": "board", "target": boarding, "vel": Vector2i.ZERO}
	var ram_move := _ram_decision(sim, unit, legal, player_ships)
	if not ram_move.is_empty():
		return ram_move

	# ⑥ §4.9a close: the first legal velocity minimizing the resulting
	#    Chebyshev distance to the nearest player ship (enumeration order is
	#    the tie-break), decelerating to ‖vel‖ ≤ 1 at Chebyshev ≤ 2 so the
	#    §4.6a hook window opens.
	var step := _close_step(sim, unit, legal, nearest)
	if step != BattleSimLib.NO_CELL:
		return {"action": "move", "target": {}, "vel": step}

	# ⑦ Hold.
	return hold


## §4.11.8 pin 2 fire pick among the loaded-side/target pairs: a rake-position
## volley beats a non-rake, then the profile `focus` picks the target, then
## the loaded side with more cannons, tie → port (the side array visits port
## first and only a strictly larger count replaces it). The shot type comes
## from `sim.ai_shot_type` — the §4.4b rule, never a second copy. `{}` when
## no loaded side has a target in arc and range.
static func _fire_decision(sim: BattleSimLib, unit: Dictionary,
		profile: Dictionary, player_ships: Array) -> Dictionary:
	var origin := sim.unit_cell(unit)
	var pairs: Array = []  # {target, side, rake} — target-major, port first
	for target in player_ships:
		var rake := _is_rake_on(sim.unit_cell(target),
			int(target.get("heading8", BattleSimLib.HEADING_EAST)), origin)
		for side in [BattleSimLib.BROADSIDE_PORT, BattleSimLib.BROADSIDE_STARBOARD]:
			if sim.can_cannon(unit, target, side):
				pairs.append({"target": target, "side": side, "rake": rake})
	if pairs.is_empty():
		return {}
	# Rake preference: raked volleys confine the candidate pool when any exist.
	var raked := pairs.filter(func(pair: Dictionary) -> bool: return bool(pair["rake"]))
	var pool: Array = raked if not raked.is_empty() else pairs
	# The focus pick runs over the pool's targets (fleet-index order).
	var candidates: Array = []
	for pair in pool:
		if not candidates.has(pair["target"]):
			candidates.append(pair["target"])
	var target: Dictionary = _focus_target(profile, unit, candidates, sim)
	if target.is_empty():
		return {}
	# Side choice: the loaded side with more cannons, tie → port.
	var side := ""
	var cannons := -1
	for pair in pool:
		if is_same(pair["target"], target):
			var count := sim.side_cannons(unit, str(pair["side"]))
			if side.is_empty() or count > cannons:
				side = str(pair["side"])
				cannons = count
	return {
		"action": "cannon",
		"target": target,
		"side": side,
		"shot": sim.ai_shot_type(unit, target),
		"vel": Vector2i.ZERO,
	}


## §4.11.8 pin 2's focus ordering: `weakest` = lowest current durability,
## `nearest` = minimum Chebyshev (ties → the lower fleet index — candidates
## arrive in fleet-index order and only a strict win replaces the holder);
## `flagship` = player index 0, falling back to `weakest` while the flagship
## is sunk. An empty candidate list yields `{}`.
static func _focus_target(profile: Dictionary, unit: Dictionary,
		candidates: Array, sim: BattleSimLib) -> Dictionary:
	if candidates.is_empty():
		return {}
	var focus := str(profile.get("focus", "weakest"))
	if focus == "flagship":
		for candidate in candidates:
			if int(candidate.index) == 0:
				return candidate
	if focus == "nearest":
		var origin := sim.unit_cell(unit)
		var best := {}
		var best_distance := 0
		for candidate in candidates:
			var current := _chebyshev(origin, sim.unit_cell(candidate))
			if best.is_empty() or current < best_distance:
				best = candidate
				best_distance = current
		return best
	return _lowest_durability(candidates)


## §4.11.8 pin 3 kite step: the FIRST legal velocity whose resulting Chebyshev
## distance (pos + vel) to the nearest player ship equals `preferred_range`;
## if none achieves it exactly, the first minimizing `|distance −
## preferred_range|`. `NO_CELL` when no velocity exists at all.
static func _kite_step(sim: BattleSimLib, unit: Dictionary, legal: Array,
		nearest: Dictionary, preferred_range: int) -> Vector2i:
	if legal.is_empty():
		return BattleSimLib.NO_CELL
	var origin := sim.unit_cell(unit)
	var target_cell: Vector2i = sim.unit_cell(nearest["unit"])
	var best := BattleSimLib.NO_CELL
	var best_gap := 0
	for vel in legal:
		var gap := absi(_chebyshev(origin + vel, target_cell) - preferred_range)
		if best == BattleSimLib.NO_CELL or gap < best_gap:
			best = vel
			best_gap = gap
			if gap == 0:
				break  # first exact hit wins (§4.11.8 pin 1)
	return best


## §4.11.8 pin 4's board candidate: the first (fleet-index order) player ship
## the §4.6a hook allows AND (own crew + duel rating > the target's OR the
## target's durability ≤ 25% max). `{}` when none qualifies.
static func _boarding_target(sim: BattleSimLib, unit: Dictionary,
		player_ships: Array) -> Dictionary:
	var own_rating := int(unit.get("crew", 0)) + int(unit.get("captain_rating", 0))
	for target in player_ships:
		if not sim.can_board(unit, target):
			continue
		var theirs := int(target.get("crew", 0)) + int(target.get("captain_rating", 0))
		if own_rating > theirs:
			return target
		var ship: Dictionary = target.get("ship", {})
		var max_durability := sim.effective_max_durability(ship)
		if max_durability > 0 and int(ship.get("durability", 0)) * 100 \
				<= BOARD_DURABILITY_PERCENT * max_durability:
			return target
	return {}


## §4.11.8 pin 4's ram decision: `floor(‖vel‖) ≥ 2` must be reachable at all
## (the gate), own cannons + duel rating > the target's, then per target in
## fleet-index order either the §4.5 adjacent-action ram (`can_ram`) or the
## first legal velocity whose §4.3a sweep enters the target — authored as a
## `move`, because the sweep itself resolves the ram and a follow-up `ram`
## action would strike a survivor twice. `{}` when nothing rams.
static func _ram_decision(sim: BattleSimLib, unit: Dictionary, legal: Array,
		player_ships: Array) -> Dictionary:
	var capable := false
	for vel in legal:
		if int(floor(BattleSimLib.vel_length(vel))) >= RAM_SPEED_MIN:
			capable = true
			break
	if not capable:
		return {}
	var own_ship: Dictionary = unit.get("ship", {})
	var own_rating := int(own_ship.get("cannons", 0)) + int(unit.get("captain_rating", 0))
	var origin := sim.unit_cell(unit)
	for target in player_ships:
		var ship: Dictionary = target.get("ship", {})
		var theirs := int(ship.get("cannons", 0)) + int(target.get("captain_rating", 0))
		if own_rating <= theirs:
			continue
		if sim.can_ram(unit, target):
			# Master W3-gate ruling (ledger): the adjacent-action ram OMITS
			# `vel` — no movement phase, the retained closing velocity prices
			# the §4.5 impact (a `vel: ZERO` authoring brakes first and
			# reads the ×0.75 standstill multiplier).
			return {"action": "ram", "target": target}
		var target_cell: Vector2i = sim.unit_cell(target)
		for vel in legal:
			if _sweep_enters(sim, unit, origin, vel, target_cell):
				return {"action": "move", "target": {}, "vel": vel}
	return {}


## §4.9a close step: the first legal velocity minimizing the resulting
## Chebyshev distance (pos + vel) to the nearest player ship (§4.11.8 pin 1 —
## enumeration order is the tie-break). At Chebyshev ≤ 2 the §4.9a
## deceleration takes precedence: the first `‖vel‖ ≤ 1` pick that does not
## increase the distance, so the §4.6a hook window opens. `NO_CELL` when no
## velocity exists at all.
static func _close_step(sim: BattleSimLib, unit: Dictionary, legal: Array,
		nearest: Dictionary) -> Vector2i:
	if legal.is_empty():
		return BattleSimLib.NO_CELL
	var origin := sim.unit_cell(unit)
	var target_cell: Vector2i = sim.unit_cell(nearest["unit"])
	var distance := int(nearest["distance"])
	if distance <= CLOSE_DECELERATION_RANGE:
		for vel in legal:
			if BattleSimLib.vel_length(vel) <= float(HOOK_SPEED_MAX) \
					and _chebyshev(origin + vel, target_cell) <= distance:
				return vel
	var best := BattleSimLib.NO_CELL
	var best_distance := 0
	for vel in legal:
		var current := _chebyshev(origin + vel, target_cell)
		if best == BattleSimLib.NO_CELL or current < best_distance:
			best = vel
			best_distance = current
	return best


## §4.11.8 rule 2's weakest fallback: lowest current durability, ties to the
## lower fleet index (candidates arrive in fleet-index order). An empty
## candidate list yields `{}`.
static func _lowest_durability(candidates: Array) -> Dictionary:
	var best := {}
	var best_durability := 0
	for candidate in candidates:
		var durability := int(candidate.get("ship", {}).get("durability", 0))
		if best.is_empty() or durability < best_durability:
			best = candidate
			best_durability = durability
	return best


## The nearest player ship by Chebyshev distance, ties to the lower fleet
## index, with the unit and distance attached.
static func _nearest(sim: BattleSimLib, player_ships: Array,
		from: Vector2i) -> Dictionary:
	var best := {}
	var best_distance := 0
	for ship in player_ships:
		var distance := _chebyshev(from, sim.unit_cell(ship))
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance
					and int(ship.index) < int(best["unit"].index)):
			best = {"unit": ship, "distance": distance}
			best_distance = distance
	return best


## §4.4 rake, recomputed with the sim's own statics because the engine's
## predicate is private: the bearing bucket from TARGET to ATTACKER relative
## to the TARGET's heading8 ∈ {0°, 180°} — the shot runs the target's deck
## line. Side-independent (it depends on the geometry, not the firing side).
static func _is_rake_on(target_cell: Vector2i, target_heading: int,
		attacker_cell: Vector2i) -> bool:
	var bearing := BattleSimLib.heading8_of(attacker_cell - target_cell)
	var steps := BattleSimLib.bucket_distance(bearing, target_heading)
	return steps == 0 or steps == 4


## Whether the §4.3a sweep of `vel` from `from` would enter `target_cell`:
## the walk (the sim's own Bresenham cell generator) stops at the first
## out-of-bounds or occupied cell, and the §4.5 sweep ram fires only when
## THAT first occupant is the target. A pure preview over public reads — the
## executor re-resolves the real sweep.
static func _sweep_enters(sim: BattleSimLib, unit: Dictionary, from: Vector2i,
		vel: Vector2i, target_cell: Vector2i) -> bool:
	for cell in BattleSimLib._bresenham_cells(from, from + vel):
		if not BattleSimLib.in_grid(cell):
			return false
		for other in sim.units():
			if is_same(other, unit) or not bool(other.get("alive", false)):
				continue
			if sim.unit_cell(other) == cell:
				return sim.unit_cell(other) == target_cell
	return false


static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
