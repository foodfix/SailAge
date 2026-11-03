class_name AiSearch
extends RefCounted
## The §4.9c T3 one-ply lookahead (Phase 9 W5-A): `ai_level = 1` ships decide
## by enumerating every legal velocity (`BattleSim.legal_velocities`, the
## §4.3a (y, x) lexicographic order) × the candidate action set {steer/hold,
## cannon per loaded side, ram, board} on the live sim behind
## `snapshot()/restore()`, scoring each applied candidate with
## `score = θ·φ` over NINE integer features, and returning the FIRST maximum
## (the enumeration order IS the tie-break — §4.11.8 pin 1).
##
## ZERO DICE by construction: a candidate's application (velocity + cannon/
## ram/board) draws from the §4.11.1 stream exactly as a real turn would —
## but every candidate starts from `restore(snapshot)` and `restore()` puts
## `rng.state` back (§4.12.1), so the search leaves the sim byte-identical
## to its pre-search state. The search never rolls, never logs, never
## persists: the executor replays the winning decision through the ordinary
## §4.3 turn seam and the dice (if any) fall there.
##
## The hard-rule layer STAYS OUTSIDE this file (§4.9c amendment): the §4.9a
## ① surrender roll and ② flee rule fire before the dispatch for BOTH AI
## levels; this module ranks the remaining candidates ③+ (fire / board ≥
## ram / steering). The shot type is NEVER an enumerated dimension (§4.4b,
## decision 4): a cannon candidate derives it from
## `BattleSim.ai_shot_type` at application time, exactly as the executor
## will.
##
## Reuse rule (never a second copy): the §4.9a profile row, the §4.11.8
## focus ordering, the board gate, the rake predicate, the nearest-enemy
## pick and the Chebyshev helper all come from `ai_fleet.gd`, referenced
## through the lazy `load()` below — a const preload here would close a
## cyclic-preload loop with the dispatch-side
## `const AiSearchLib := preload(...)` in `ai_fleet.gd`; at call time the
## resource cache already holds the loaded script (this file is only ever
## reached through it), so the load is a cache hit.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

const AIFLEET_PATH := "res://scripts/combat/ai_fleet.gd"

static var _ai_fleet_cache = null


## The `ai_fleet.gd` script resource (lazy — see the module doc).
static func _ai_fleet_lib():
	if _ai_fleet_cache == null:
		_ai_fleet_cache = load(AIFLEET_PATH)
	return _ai_fleet_cache


# --- θ (docs/60-* §4.9c; correction 11) --------------------------------------

## The §4.9c doc-first prior `{10, 4, 2, 3, −5, −6, −2, −4, 2}` — ALL THREE
## arrays are seeded with it. The offline CEM run (`tools/battle_tune.py`,
## W5-B) finalizes the integers through the named master θ-finalization task
## (correction 11: the doc is amended first, then these consts sync) — these
## consts are the runtime's ONLY θ source. Position i weights feature φ(i+1).
const THETA_AGGRESSIVE: Array[int] = [10, 4, 2, 3, -5, -6, -2, -4, 2]
const THETA_BALANCED: Array[int] = [10, 4, 2, 3, -5, -6, -2, -4, 2]
const THETA_CAUTIOUS: Array[int] = [10, 4, 2, 3, -5, -6, -2, -4, 2]

## §4.9c archetype → θ mapping: pirate/privateer rows carry `aggressive`,
## patrol/navy/tournament `balanced`, treasure/trader/coaster/courier
## `cautious`; an unknown archetype reads balanced (the middle row).
const ARCHETYPE_AGGRESSIVE := "aggressive"
const ARCHETYPE_BALANCED := "balanced"
const ARCHETYPE_CAUTIOUS := "cautious"

## The §4.9c feature-table integers (the φ formulas' own numbers):
## φ1 divides the durability difference by 20, φ2 the cannon difference by 4,
## φ6's flagship term reads ≤ 25 % of the effective max durability
## (the §4.11.8 percentage family), φ8 counts blockers within Chebyshev 3
## (the cannon range family) at 1..3 cells along the heading-ray, and φ9
## saturates the alignment at 4 buckets (the `bucket_distance` maximum).
const DURABILITY_DIFF_DIVISOR := 20
const CANNON_DIFF_DIVISOR := 4
const FLAGSHIP_LOW_DURABILITY_PERCENT := 25
const BLOCKED_LANE_CHEBYSHEV := 3
const BLOCKED_LANE_MIN_CELLS := 1
const BLOCKED_LANE_MAX_CELLS := 3
const ALIGNMENT_MAX := 4


static func theta_for(archetype: String) -> Array[int]:
	match archetype:
		ARCHETYPE_AGGRESSIVE:
			return THETA_AGGRESSIVE
		ARCHETYPE_CAUTIOUS:
			return THETA_CAUTIOUS
		_:
			return THETA_BALANCED


# --- The search (docs/60-* §4.9c) ---------------------------------------------

## The T3 one-ply search for `unit`'s turn. `theta` is the §4.9c integer
## 9-array for the ship's archetype; `order` is the §4.9b five-tuple + phase
## rider (`{}` = the free T3 — no discipline, no station term). Returns the
## §4.12.1.1 decision dict (`cell` is derived by the executor, never
## authored; `side` / `shot` ride the cannon winner explicitly). An empty
## candidate set ⇒ hold.
##
## Candidate enumeration: velocities in `legal_velocities` order; within a
## velocity the actions rank steer/hold → cannon-port → cannon-starboard →
## ram → board. The FIRST strictly-greater score wins; ties keep the earlier
## candidate. `discipline = true` (with a station) removes off-station
## velocity candidates OUTRIGHT before the action pairing (§4.9b's
## keeps-station test, judged on the §4.3a sweep's real landing — the
## candidate IS applied on the sim, so the landing is the engine's own).
static func decide(sim, unit: Dictionary, theta: Array[int],
		order: Dictionary = {}) -> Dictionary:
	var hold := {"action": "hold", "target": {}, "vel": Vector2i.ZERO}
	if sim == null or theta.is_empty() or not (unit is Dictionary) \
			or not bool(unit.get("alive", false)):
		return hold
	var fleet = _ai_fleet_lib()
	if fleet == null:
		return hold
	var my_side := str(unit.get("side", ""))
	var their_side := BattleSimLib.SIDE_PLAYER \
		if my_side == BattleSimLib.SIDE_ENEMY else BattleSimLib.SIDE_ENEMY
	var foes: Array = sim.living_units(their_side)
	if foes.is_empty():
		return hold
	var profile: Dictionary = fleet.profile_for(str(sim.enemy_kind))
	var origin: Vector2i = sim.unit_cell(unit)
	var legal: Array = sim.legal_velocities(unit)
	if legal.is_empty():
		return hold

	# W4-B order decode (the empty order = the free T3).
	var has_order := not order.is_empty()
	var phase := str(order.get("phase", ""))
	var station := BattleSimLib.to_cell(order.get("station", BattleSimLib.NO_CELL))
	var discipline := has_order and bool(order.get("discipline", false)) \
		and station != BattleSimLib.NO_CELL
	# §4.9b engage assignment: `-1`/absent = free ranking (the T2 consumer's
	# exact fallback semantics).
	var assigned_target := int(order.get("assigned_target", -1)) if has_order else -1
	# φ7's station exists for the §4.9b line phases only (form/close/engage/
	# wear — screen/swarm/break carry no station term).
	var station_valid := has_order and station != BattleSimLib.NO_CELL \
		and phase in [fleet.ORDER_PHASE_FORM, fleet.ORDER_PHASE_CLOSE,
			fleet.ORDER_PHASE_ENGAGE, fleet.ORDER_PHASE_WEAR]

	# Move-invariant gates, priced once (§4.11.8 pin 4's ram capability:
	# floor(‖vel‖) ≥ 2 must be reachable at all) and the move-invariant half
	# of the cannon candidates (a side loaded at the turn's start — reload
	# does not move).
	var ram_capable := false
	for vel in legal:
		if int(floor(BattleSimLib.vel_length(vel))) >= fleet.RAM_SPEED_MIN:
			ram_capable = true
			break
	var round_no: int = sim.round_number()
	var fire_sides: Array = []
	for side in [BattleSimLib.BROADSIDE_PORT, BattleSimLib.BROADSIDE_STARBOARD]:
		if _side_loaded(sim, unit, side, round_no):
			fire_sides.append(side)

	var pre: Array[int] = sim.snapshot()
	var best_score := 0
	var best: Dictionary = {}
	var first := true
	var score := 0

	for vel in legal:
		# --- steer/hold: the velocity with no action. -----------------------
		sim.restore(pre)
		sim.apply_velocity(unit, vel)
		var landing: Vector2i = sim.unit_cell(unit)
		# §4.9c discipline removal — off-station velocities leave the
		# enumeration outright (before the action pairing).
		if discipline and _cheb(landing, station) > _cheb(origin, station):
			continue
		score = _evaluate(sim, unit, theta, my_side, their_side,
			station_valid, station)
		if first or score > best_score:
			first = false
			best_score = score
			best = _steer_decision(vel)

		# --- cannon per loaded side, §4.11.8-best target for the side. -----
		for side in fire_sides:
			sim.restore(pre)
			sim.apply_velocity(unit, vel)
			var target := _fire_target_for_side(sim, unit, side, foes, profile,
				fleet, assigned_target)
			if target.is_empty():
				continue
			# §4.4b: the shot type is rule-derived OUTSIDE the enumeration.
			var shot := str(sim.ai_shot_type(unit, target))
			sim.cannon(unit, target, side, shot)
			score = _evaluate(sim, unit, theta, my_side, their_side,
				station_valid, station)
			if score > best_score:
				best_score = score
				best = {"action": "cannon", "target": target,
					"side": side, "shot": shot, "vel": vel}

		# --- ram: the first legal target (§4.11.8 pin 4's rating gate). ----
		if ram_capable:
			sim.restore(pre)
			sim.apply_velocity(unit, vel)
			var ram_target := _ram_target(sim, unit, foes, fleet)
			if not ram_target.is_empty():
				sim.ram(unit, ram_target)
				score = _evaluate(sim, unit, theta, my_side, their_side,
					station_valid, station)
				if score > best_score:
					best_score = score
					best = {"action": "ram", "target": ram_target, "vel": vel}

		# --- board: the §4.6a hook + the §4.11.8 pin 4 board gate. ---------
		sim.restore(pre)
		sim.apply_velocity(unit, vel)
		var board_target: Dictionary = fleet._boarding_target(sim, unit, foes)
		if not board_target.is_empty():
			sim.board(unit, board_target)
			score = _evaluate(sim, unit, theta, my_side, their_side,
				station_valid, station)
			if score > best_score:
				best_score = score
				best = {"action": "board", "target": board_target, "vel": vel}

	sim.restore(pre)
	if best.is_empty():
		return hold
	return best


## The no-action candidate's decision: a (0,0) pick is the §4.9a hold, any
## other velocity is a `move` (the T2 steering dict shape).
static func _steer_decision(vel: Vector2i) -> Dictionary:
	if vel == Vector2i.ZERO:
		return {"action": "hold", "target": {}, "vel": Vector2i.ZERO}
	return {"action": "move", "target": {}, "vel": vel}


## The §4.11.8-best fire target for the NAMED side from the current state:
## among the side's fireable foes (arc + Chebyshev 1..3, §4.4) a rake-position
## pool wins when any exists, then the profile `focus` picks (AiFleet's
## `_focus_target` — the single focus implementation). `{}` when the side has
## no fireable target.
static func _fire_target_for_side(sim, unit: Dictionary, side: String,
		foes: Array, profile: Dictionary, fleet, fleet_order_target: int = -1) -> Dictionary:
	var fireable: Array = []
	var raked: Array = []
	for foe in foes:
		if not sim.can_cannon(unit, foe, side):
			continue
		fireable.append(foe)
		if fleet._is_rake_on(sim.unit_cell(foe),
				int(foe.get("heading8", BattleSimLib.HEADING_EAST)),
				sim.unit_cell(unit)):
			raked.append(foe)
	if fireable.is_empty():
		return {}
	var pool: Array = raked if not raked.is_empty() else fireable
	# §4.9b engage assignment (W5 master bounce): an `assigned_target ≥ 0`
	# restricts the fire pool to that ship. DEAD/absent ⇒ the free-ranking
	# fallback (the T2 consumer's exact rule); ALIVE but not fireable on
	# this side ⇒ the pool is EMPTY ⇒ hold fire — the same semantics on
	# both levels (unified W5-D gate; the old fall-through to the pool's
	# best target contradicted the pin).
	var assigned := int(fleet_order_target)
	if assigned >= 0:
		var assigned_foe: Dictionary = {}
		for foe in foes:
			if int(foe.get("index", -1)) == assigned and bool(foe.get("alive", false)):
				assigned_foe = foe
				break
		if assigned_foe.is_empty():
			return fleet._focus_target(profile, unit, pool, sim)
		var pinned: Array = pool.filter(func(foe) -> bool:
			return int(foe.get("index", -1)) == assigned)
		if pinned.is_empty():
			return {}
		pool = pinned
	return fleet._focus_target(profile, unit, pool, sim)


## The §4.11.8 pin 4 ram target: the first foe (fleet-index order) that is
## orthogonally adjacent AND loses the cannon+duel-rating comparison
## (own cannons + duel rating > the target's). `{}` when none qualifies.
static func _ram_target(sim, unit: Dictionary, foes: Array, fleet) -> Dictionary:
	var own_rating := int(unit.get("ship", {}).get("cannons", 0)) \
		+ int(unit.get("captain_rating", 0))
	for foe in foes:
		if not sim.can_ram(unit, foe):
			continue
		var theirs := int(foe.get("ship", {}).get("cannons", 0)) \
			+ int(foe.get("captain_rating", 0))
		if own_rating > theirs:
			return foe
	return {}


## §4.4 side firing readiness (the "loaded" reading shared by φ3/φ4/φ6):
## `round ≥ reload_side` AND the side carries ≥ 1 cannon.
static func _side_loaded(sim, unit: Dictionary, side: String,
		round_no: int) -> bool:
	if sim.side_cannons(unit, side) < 1:
		return false
	var key := "reload_port" if side == BattleSimLib.BROADSIDE_PORT \
		else "reload_starboard"
	return round_no >= int(unit.get(key, 1))


# --- The nine features (docs/60-* §4.9c — the normative φ table) --------------
#
# φ1 durability diff  (friendly total durability − enemy total) / 20
# φ2 cannon diff      (friendly total cannons − enemy total) / 4
# φ3 reload diff      (friendly loaded side-count − enemy loaded side-count)
# φ4 arc fit          friendly loaded sides with a living enemy in arc+range
#                     minus the enemy's mirror
# φ5 rake exposure    friendly ships sitting in an enemy's rake position
#                     minus the enemy's mirror
# φ6 flagship danger  my flagship's two danger terms minus the enemy
#                     flagship's
# φ7 station deviation  Chebyshev(pos_after, order.station) — 0 without a
#                     station (the §4.9b line phases only)
# φ8 friendly-blocked line  friendly pairs (a, b) with b on a's heading-ray
#                     within Chebyshev 3
# φ9 heading alignment  4 − min(bucket_distance(heading_after, bearing to
#                     the nearest enemy), 4)
#
# "friendly" is the deciding ship's side, "enemy" the opposing side; totals
# run over LIVING ships; every feature is a small deterministic integer.

static func _evaluate(sim, unit: Dictionary, theta: Array[int],
		my_side: String, their_side: String, station_valid: bool,
		station: Vector2i) -> int:
	var fleet = _ai_fleet_lib()
	var round_no: int = sim.round_number()
	var mine: Array = sim.living_units(my_side)
	var theirs: Array = sim.living_units(their_side)

	var durability := 0
	var durability_theirs := 0
	var cannons := 0
	var cannons_theirs := 0
	var loaded := 0
	var loaded_theirs := 0
	var arc_fit := 0
	var rake_exposure := 0
	var blocked := 0
	for u in mine:
		durability += int(u.get("ship", {}).get("durability", 0))
		cannons += sim.side_cannons(u, BattleSimLib.BROADSIDE_PORT) \
			+ sim.side_cannons(u, BattleSimLib.BROADSIDE_STARBOARD)
		loaded += _loaded_side_count(sim, u, round_no)
		arc_fit += _loaded_arcs_with_target(sim, u, theirs, round_no)
		if _is_exposed(sim, u, theirs, fleet):
			rake_exposure += 1
		blocked += _blocked_count(mine, u)
	for u in theirs:
		durability_theirs += int(u.get("ship", {}).get("durability", 0))
		cannons_theirs += sim.side_cannons(u, BattleSimLib.BROADSIDE_PORT) \
			+ sim.side_cannons(u, BattleSimLib.BROADSIDE_STARBOARD)
		loaded_theirs += _loaded_side_count(sim, u, round_no)
		arc_fit -= _loaded_arcs_with_target(sim, u, mine, round_no)
		if _is_exposed(sim, u, mine, fleet):
			rake_exposure -= 1
	var flagship_danger := _flagship_danger(sim, my_side, mine, theirs,
		round_no) \
		- _flagship_danger(sim, their_side, theirs, mine, round_no)
	var station_deviation := _cheb(sim.unit_cell(unit), station) \
		if station_valid else 0
	var nearest: Dictionary = fleet._nearest(sim, theirs, sim.unit_cell(unit))
	var bearing := BattleSimLib.heading8_of(
		(sim.unit_cell(nearest["unit"]) - sim.unit_cell(unit)) \
			if not nearest.is_empty() else Vector2i.ZERO)
	var alignment := ALIGNMENT_MAX - mini(BattleSimLib.bucket_distance(
		posmod(int(unit.get("heading8", 0)), 8), bearing), ALIGNMENT_MAX)

	var features := [
		(durability - durability_theirs) / DURABILITY_DIFF_DIVISOR,
		(cannons - cannons_theirs) / CANNON_DIFF_DIVISOR,
		loaded - loaded_theirs,
		arc_fit,
		rake_exposure,
		flagship_danger,
		station_deviation,
		blocked,
		alignment,
	]
	var score := 0
	for index in features.size():
		if index >= theta.size():
			break
		score += theta[index] * int(features[index])
	return score


## φ3's per-ship half: how many of the ship's sides are loaded (0..2).
static func _loaded_side_count(sim, unit: Dictionary, round_no: int) -> int:
	var count := 0
	for side in [BattleSimLib.BROADSIDE_PORT, BattleSimLib.BROADSIDE_STARBOARD]:
		if _side_loaded(sim, unit, side, round_no):
			count += 1
	return count


## True when `ship` has a LOADED side whose §4.4 arc contains `target`
## within cannon range (Chebyshev 1..3), judged on the current state. The
## φ6 "inside some enemy loaded arc within range" term and the φ4 per-side
## scan both read through here.
static func _in_loaded_arc(sim, ship: Dictionary, target: Dictionary,
		round_no: int) -> bool:
	var origin: Vector2i = sim.unit_cell(ship)
	var target_cell: Vector2i = sim.unit_cell(target)
	var distance := _cheb(origin, target_cell)
	if distance < BattleSimLib.CANNON_RANGE_MIN \
			or distance > BattleSimLib.CANNON_RANGE_MAX:
		return false
	var steps := posmod(BattleSimLib.heading8_of(target_cell - origin)
		- int(ship.get("heading8", BattleSimLib.HEADING_EAST)), 8)
	for side in [BattleSimLib.BROADSIDE_PORT, BattleSimLib.BROADSIDE_STARBOARD]:
		if not _side_loaded(sim, ship, side, round_no):
			continue
		var arc: Array = BattleSimLib.ARC_PORT_STEPS \
			if side == BattleSimLib.BROADSIDE_PORT \
			else BattleSimLib.ARC_STARBOARD_STEPS
		if steps in arc:
			return true
	return false


## φ4's per-ship half: how many of the ship's loaded sides (0..2) have a
## living opponent in arc + range.
static func _loaded_arcs_with_target(sim, ship: Dictionary, foes: Array,
		round_no: int) -> int:
	var count := 0
	for side in [BattleSimLib.BROADSIDE_PORT, BattleSimLib.BROADSIDE_STARBOARD]:
		if not _side_loaded(sim, ship, side, round_no):
			continue
		var origin: Vector2i = sim.unit_cell(ship)
		var heading := int(ship.get("heading8", BattleSimLib.HEADING_EAST))
		var arc: Array = BattleSimLib.ARC_PORT_STEPS \
			if side == BattleSimLib.BROADSIDE_PORT \
			else BattleSimLib.ARC_STARBOARD_STEPS
		for foe in foes:
			var foe_cell: Vector2i = sim.unit_cell(foe)
			var distance := _cheb(origin, foe_cell)
			if distance < BattleSimLib.CANNON_RANGE_MIN \
					or distance > BattleSimLib.CANNON_RANGE_MAX:
				continue
			var steps := posmod(BattleSimLib.heading8_of(foe_cell - origin)
				- heading, 8)
			if steps in arc:
				count += 1
				break
	return count


## φ5's predicate: `ship` sits in a rake position of some living opponent —
## the bearing bucket between them ∈ {0°, 180°} relative to SHIP's heading8
## (AiFleet's rake predicate — the shot would run the ship's deck line).
static func _is_exposed(sim, ship: Dictionary, foes: Array, fleet) -> bool:
	var cell: Vector2i = sim.unit_cell(ship)
	var heading := int(ship.get("heading8", BattleSimLib.HEADING_EAST))
	for foe in foes:
		if fleet._is_rake_on(cell, heading, sim.unit_cell(foe)):
			return true
	return false


## φ6 for one side: the side flagship's two danger terms (≤ 25% durability;
## inside some opponent loaded arc within range), 0 when the flagship is
## sunk. The flagship is the engine's: fleet index 0 for the AI side, the
## §4.6 succession index (`flagship_index`) for the player side.
static func _flagship_danger(sim, side: String, units: Array, foes: Array,
		round_no: int) -> int:
	var want := 0
	if side == BattleSimLib.SIDE_PLAYER and sim.has_method("flagship_index"):
		want = int(sim.flagship_index())
	var flagship: Dictionary = {}
	for u in units:
		if int(u.get("index", -1)) == want:
			flagship = u
			break
	if flagship.is_empty():
		return 0
	var danger := 0
	var ship: Dictionary = flagship.get("ship", {})
	var max_durability: int = sim.effective_max_durability(ship)
	if max_durability > 0 and int(ship.get("durability", 0)) * 100 \
			<= FLAGSHIP_LOW_DURABILITY_PERCENT * max_durability:
		danger += 1
	for foe in foes:
		if _in_loaded_arc(sim, foe, flagship, round_no):
			danger += 1
			break
	return danger


## φ8: the friendly ships sitting on `ship`'s own heading-ray within
## Chebyshev 3 — the broadside lane blocked ahead (1..3 cells along
## `heading8`).
static func _blocked_count(units: Array, ship: Dictionary) -> int:
	var origin: Vector2i = _cell_of(ship)
	var ray: Vector2i = BattleSimLib.HEADING_RAYS[
		posmod(int(ship.get("heading8", 0)), 8)]
	var count := 0
	for other in units:
		if is_same(other, ship):
			continue
		var delta: Vector2i = _cell_of(other) - origin
		for k in range(BLOCKED_LANE_MIN_CELLS, BLOCKED_LANE_MAX_CELLS + 1):
			if delta == ray * k:
				count += 1
				break
	return count


static func _cell_of(unit: Dictionary) -> Vector2i:
	return BattleSimLib.to_cell(unit.get("pos", unit.get("cell",
		BattleSimLib.NO_CELL)))


static func _cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
