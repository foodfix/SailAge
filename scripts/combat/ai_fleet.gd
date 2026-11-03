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
## enumeration IS the tie-break). Distance math is judged on the §4.3a
## sweep's LANDING cell (master W3-gate ruling — a pick the sweep stops does
## without a sweep preview: the §4.3a sweep can only shorten a move, never
## lengthen it.
##
## W4-B order consumption (§4.9b): [method decide] takes an optional `order`
## — the `FleetCommander` five-tuple (+ phase rider, see
## `fleet_commander.gd`) for this ship this round. Orders are FEED-FORWARD
## CONSTRAINTS inside the unchanged priority list, never a replacement for
## it: `discipline` hard-removes off-station velocity candidates before any
## objective ranking, form/close/engage/wear phases steer toward the order's
## `station` (engage/wear holding the `desired_heading8` bucket first),
## screen orders keep the §4.9b flagship-radius-3 screen, and an
## `assigned_target ≥ 0` restricts the §4.11.8 fire ranking to that player
## ship. The EMPTY order is the free T2, byte-for-byte.
##
## Every formula that already exists in `battle_sim.gd` is called, never
## copied: the AI asks the sim for velocity legality, per-side arc/range
## checks, the §4.4b shot rule and the §4.7 surrender roll. The sim is
## referenced through this preload (not the `BattleSim` global class name) so
## the file also parses from a fresh checkout with no
## `.godot/global_script_class_cache.cfg` yet.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
## The §4.9c T3 one-ply lookahead (W5-A) — the `ai_level = 1` dispatch target.
## ai_search.gd reaches THIS file's helpers through a lazy `load()` (its
## `_ai_fleet_lib()`), so the pair never closes a cyclic-preload loop at
## parse time: the const-preload arrow points one way only.
const AiSearchLib := preload("res://scripts/combat/ai_search.gd")

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

## W4-B pins. The §4.9a pre-fleet-layer morale flee threshold ("side morale
## ≤ 20"), read through the defensive W4-A seam (`_side_morale` — no
## reading before that merge ⇒ the gate keeps its W3 shape); the §4.9b
## flagship screen radius; the engage focus-fire aggression; and the
## §4.9b phase vocabulary the order rider carries (steering-mode dispatch).
const SIDE_MORALE_FLEE := 20
const SCREEN_RADIUS := 3
const FOCUS_FIRE_AGGRESSION := 80
const HEADING_HOLD_BUCKETS := 1        # "holds the desired_heading8 bucket (±1)"
const ORDER_PHASE_FORM := "form"
const ORDER_PHASE_CLOSE := "close"
const ORDER_PHASE_ENGAGE := "engage"
const ORDER_PHASE_WEAR := "wear"
const ORDER_PHASE_SCREEN := "screen"

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
##
## W4-B: `order` (optional, default empty) is the §4.9b five-tuple + phase
## rider from `FleetCommander.generate_orders` for this ship this round. It
## constrains candidate sets and targets INSIDE the unchanged list — the
## empty order reproduces the free T2 exactly.
static func decide(sim: BattleSimLib, unit: Dictionary,
		order: Dictionary = {}) -> Dictionary:
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

	# W4-B order decode. The empty order leaves every constraint inert:
	# phase "", station NO_CELL, assigned −1, discipline false — the free T2.
	var has_order := not order.is_empty()
	var phase := str(order.get("phase", ""))
	var station := BattleSimLib.to_cell(order.get("station", BattleSimLib.NO_CELL))
	var assigned := int(order.get("assigned_target", -1)) if has_order else -1
	var discipline := has_order and bool(order.get("discipline", false))
	var band_lo := 0
	var band_hi := 0
	var band_ok := false
	var band = order.get("desired_speed_band", null)
	if has_order and band is Array and (band as Array).size() >= 2:
		band_lo = int(band[0])
		band_hi = int(band[1])
		band_ok = true
	# §4.9b hard constraint: `discipline` removes off-station candidates —
	# picks whose §4.3a landing WORSENS the Chebyshev deviation to the
	# station — from the consideration set before every objective ranking
	# (hold-in-place landings survive; the ship never willingly drifts).
	var considered: Array = legal
	if discipline and station != BattleSimLib.NO_CELL:
		considered = legal.filter(func(vel): return _keeps_station(sim, unit, origin, vel, station))

	# ① §4.7/§4.8a surrender roll: SIDE morale ≤ 20 (the W4-A seam, the
	#    proximity clause retired by decision 9/§4.7's W1 pin) AND the ship
	#    at ≤ 25 % max durability. The chance is the sim's §4.7
	#    `surrender_chance(unit, courage_mod, morale)` — the profile
	#    `courage_mod` folded into the effective courage (§4.9a) plus the
	#    `+ floor((20 − morale) / 2)` pp morale modifier — and the roll is
	#    drawn from the battle's §4.11.1 stream; a failed roll re-rolls next
	#    turn. The defensive seam (no `side_morale` ⇒ −1) keeps the
	#    merge-order fallback exactly the durability half of the gate.
	#    Orders never touch this priority (the §4.9b layer constrains
	#    maneuvers and targets, not the §4.7 gate).
	var side_morale := -1
	if sim.has_method("side_morale"):
		side_morale = int(sim.side_morale(BattleSimLib.SIDE_ENEMY))
	if max_durability > 0 \
			and int(own_ship.get("durability", 0)) * 100 \
				<= SURRENDER_DURABILITY_PERCENT * max_durability \
			and (side_morale < 0 or side_morale <= BattleSimLib.MORALE_SURRENDER_GATE):
		if sim.roll_surrender(unit, courage_mod, side_morale):
			return {"action": "surrender", "target": {}, "vel": Vector2i.ZERO}

	# ② §4.9a flee: hp% below the profile gate, or aggression < 25, or —
	#    the §4.9a pre-fleet-layer widening — side morale ≤ 20 through the
	#    defensive W4-A seam: before the sim exposes `side_morale` there is
	#    no reading (-1) and the gate is exactly the W3 pair above
	#    (merge-order guard; the threshold pins at 20 either way). The first
	#    legal velocity strictly increasing the Chebyshev distance to the
	#    nearest player ship, judged on the sweep's landing cell (§4.11.8
	#    pin 5 + the landing ruling); hold when none — a cornered fleer does
	#    not fall through to the guns. Discipline-filtered candidates apply
	#    (the order constrains the consideration set).
	var flee_hp := int(profile.get("flee_below_hp_pct", 0))
	var wants_flee := max_durability > 0 \
		and int(own_ship.get("durability", 0)) * 100 < flee_hp * max_durability
	if int(profile.get("aggression", 0)) < FLEE_AGGRESSION_MAX:
		wants_flee = true
	if not wants_flee:
		var morale := _side_morale(sim)
		if morale >= 0 and morale <= SIDE_MORALE_FLEE:
			wants_flee = true
	if wants_flee:
		for vel in considered:
			if _chebyshev(_landing(sim, unit, origin, vel), nearest_cell) > distance:
				return {"action": "move", "target": {}, "vel": vel}
		return hold

	# ②→T3 §4.9c dispatch: `ai_level = 1` ranks the remaining candidates ③+
	# with the one-ply search — θ from the profile `archetype` (§4.9c
	# mapping), the §4.9b order consumed inside the search (discipline
	# removal + the φ7 station term; the empty order is the free T3). The
	# hard-rule layer above (① surrender roll, ② flee) is level-agnostic:
	# it fired BEFORE this dispatch for both levels (the §4.9c amendment).
	if int(profile.get("ai_level", 0)) == 1:
		return AiSearchLib.decide(sim, unit,
			AiSearchLib.theta_for(str(profile.get("archetype", "balanced"))),
			order)

	# ③ §4.11.8 pin 2 fire: rake preference → profile focus → loaded side
	#    with more cannons (tie → port); the shot type is the §4.4b rule's.
	#    W4-B: `assigned_target ≥ 0` restricts the ranking to that player
	#    ship (free ranking only when the assignment is dead/absent).
	var fire := _fire_decision(sim, unit, profile, player_ships, assigned)
	if not fire.is_empty():
		return fire

	# ③½ §4.9b engage/wear steering: develop the broadside bucket. While
	#    the ship is outside the desired_heading8 ±1 window the maneuver
	#    outranks the remaining priorities (objective: minimal heading gap,
	#    then keep the enemy in a fireable arc, then station deviation —
	#    first-best by enumeration, landing-cell judged); once inside the
	#    window the list resumes below.
	if has_order and (phase == ORDER_PHASE_ENGAGE or phase == ORDER_PHASE_WEAR):
		var desired := posmod(int(order.get("desired_heading8", 0)),
			BattleSimLib.HEADING_RAYS.size())
		if BattleSimLib.bucket_distance(
				posmod(int(unit.get("heading8", 0)),
					BattleSimLib.HEADING_RAYS.size()), desired) \
				> HEADING_HOLD_BUCKETS:
			var turn := _heading_hold_step(sim, unit, considered, station,
				desired, nearest_cell)
			if turn != BattleSimLib.NO_CELL:
				return {"action": "move", "target": {}, "vel": turn}

	# ④ §4.9a kite: both broadside reload windows active → steer so the
	#    resulting Chebyshev distance (pos + vel) meets the profile
	#    `preferred_range` (§4.11.8 pin 3). Ordered engage/wear ships yield
	#    this step to ③½ (the queue holds its heading, it does not kite).
	var round_no := sim.round_number()
	if round_no < int(unit.get("reload_port", 1)) \
			and round_no < int(unit.get("reload_starboard", 1)) \
			and not (has_order and (phase == ORDER_PHASE_ENGAGE
				or phase == ORDER_PHASE_WEAR)):
		var kite := _kite_step(sim, unit, considered, nearest,
			int(profile.get("preferred_range", 0)))
		if kite != BattleSimLib.NO_CELL:
			return {"action": "move", "target": {}, "vel": kite}

	# ⑤ Board ranks above ram (decision 13). Board: the §4.6a hook legal AND
	#    (own crew + duel rating > the target's OR target hp% ≤ 25).
	#    Ram: floor(‖vel‖) ≥ 2 possible AND own cannons + duel rating > the
	#    target's — delivered either as the adjacent-action ram or as the
	#    first legal velocity whose §4.3a sweep enters the target (the sweep
	#    IS the §4.5 ram; authoring it as a move keeps the executor from
	#    re-striking a ram survivor). Discipline-filtered candidates apply
	#    to the sweep leg; fire assignments do not restrict these targets
	#    (the §4.9b pin constrains the guns, not the grappling parties).
	var boarding := _boarding_target(sim, unit, player_ships)
	if not boarding.is_empty():
		return {"action": "board", "target": boarding, "vel": Vector2i.ZERO}
	var ram_move := _ram_decision(sim, unit, considered, player_ships)
	if not ram_move.is_empty():
		return ram_move

	# ⑥ §4.9b-ordered steering: form/close/engage/wear close onto the
	#    order's `station` (speed band as a first-stage preference);
	#    screen orders close on the nearest enemy while preferring
	#    landings inside the flagship's Chebyshev SCREEN_RADIUS. An ordered
	#    ship with no surviving candidate holds — it never falls back to
	#    the free close (that would breach the constraint). Swarm/break
	#    orders carry the assignment only: free steering continues below.
	var phase_is_ordered := has_order and station != BattleSimLib.NO_CELL \
		and (phase == ORDER_PHASE_FORM or phase == ORDER_PHASE_CLOSE
			or phase == ORDER_PHASE_ENGAGE or phase == ORDER_PHASE_WEAR
			or phase == ORDER_PHASE_SCREEN)
	if phase_is_ordered:
		var ordered := BattleSimLib.NO_CELL
		if phase == ORDER_PHASE_SCREEN:
			ordered = _screen_close_step(sim, unit, considered, station, nearest)
		else:
			ordered = _station_step(sim, unit, considered, station,
				band_lo, band_hi, band_ok)
		if ordered != BattleSimLib.NO_CELL:
			return {"action": "move", "target": {}, "vel": ordered}
		return hold

	# ⑥ §4.9a close: the first legal velocity minimizing the resulting
	#    Chebyshev distance to the nearest player ship (enumeration order is
	#    the tie-break), decelerating to ‖vel‖ ≤ 1 at Chebyshev ≤ 2 so the
	#    §4.6a hook window opens. Also the swarm/break-order steering leg.
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
##
## W4-B: `assigned ≥ 0` restricts the candidate pool to that player fleet
## index (§4.9b engage assignment — a loaded side without a fireable angle
## onto the assigned ship holds fire). An assignment that is dead/absent
## from `player_ships` falls back to the free ranking.
static func _fire_decision(sim: BattleSimLib, unit: Dictionary,
		profile: Dictionary, player_ships: Array, assigned: int = -1) -> Dictionary:
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
	if assigned >= 0:
		var restricted := pairs.filter(func(pair: Dictionary) -> bool:
			return int(pair["target"].index) == assigned)
		if not restricted.is_empty():
			pairs = restricted
		elif _has_fleet_index(player_ships, assigned):
			return {}  # assigned and alive, but no fireable geometry: hold fire
		# dead/absent assignment → free ranking (the §4.9b fallback)
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


## The cell the §4.3a sweep actually reaches for `vel` from `origin`: the
## Bresenham walk (the engine's own `_bresenham_cells`, so the preview is
## exact) stops at the first out-of-grid or occupied cell and the ship stays
## at the PRIOR cell in both cases. Every §4.9a velocity pick is judged on
## this landing cell (master W3-gate ruling, ledgered into §4.11.8): a pick
## the sweep stops does not close, flee, kite, or open distance — without
## this a cornered ship "sails" through the map edge every round (pos + vel
## reads a landing the sweep eats) and freezes the battle into a stall.
static func _landing(sim: BattleSimLib, unit: Dictionary, origin: Vector2i,
		vel: Vector2i) -> Vector2i:
	var target := origin + vel
	if target == origin:
		return origin
	var occupied := {}
	for other in sim.units():
		if other == unit or not bool(other.get("alive", false)):
			continue
		occupied[sim.unit_cell(other)] = true
	var prior := origin
	for cell in BattleSimLib._bresenham_cells(origin, target):
		if not BattleSimLib.in_grid(cell) or occupied.has(cell):
			return prior
		prior = cell
	return prior


## §4.11.8 pin 3 kite step: the FIRST legal velocity whose resulting Chebyshev
## distance (the §4.3a sweep's landing cell) to the nearest player ship equals
## `preferred_range`; if none achieves it exactly, the first minimizing
## `|distance − preferred_range|`. `NO_CELL` when no velocity exists at all.
static func _kite_step(sim: BattleSimLib, unit: Dictionary, legal: Array,
		nearest: Dictionary, preferred_range: int) -> Vector2i:
	if legal.is_empty():
		return BattleSimLib.NO_CELL
	var origin := sim.unit_cell(unit)
	var target_cell: Vector2i = sim.unit_cell(nearest["unit"])
	var best := BattleSimLib.NO_CELL
	var best_gap := 0
	for vel in legal:
		var gap := absi(_chebyshev(_landing(sim, unit, origin, vel), target_cell)
			- preferred_range)
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
## Chebyshev distance (the sweep's landing cell) to the nearest player ship
## (§4.11.8 pin 1 — enumeration order is the tie-break). At Chebyshev ≤ 2 the
## §4.9a deceleration takes precedence: the first `‖vel‖ ≤ 1` pick that does not
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
					and _chebyshev(_landing(sim, unit, origin, vel), target_cell) <= distance:
				return vel
	var best := BattleSimLib.NO_CELL
	var best_distance := 0
	for vel in legal:
		var current := _chebyshev(_landing(sim, unit, origin, vel), target_cell)
		if best == BattleSimLib.NO_CELL or current < best_distance:
			best = vel
			best_distance = current
	return best


## W4-B — the defensive §4.8a side-morale seam (§4.9a pre-fleet-layer pin):
## the reading exists only once the sim exposes `side_morale`; before that
## merge-order point this yields −1 ("no reading") and every morale gate
## keeps its W3 shape. Numeric-only acceptance — a malformed reading is no
## reading.
static func _side_morale(sim: BattleSimLib) -> int:
	if sim == null or not sim.has_method("side_morale"):
		return -1
	var reading = sim.side_morale(BattleSimLib.SIDE_ENEMY)
	if reading is int or reading is float:
		return int(reading)
	return -1


## W4-B §4.9b discipline test for one candidate: its §4.3a landing cell must
## not WORSEN the Chebyshev deviation to the station (landing-cell judged —
## the §4.11.8 pin 1 discipline).
static func _keeps_station(sim: BattleSimLib, unit: Dictionary,
		origin: Vector2i, vel: Vector2i, station: Vector2i) -> bool:
	return _chebyshev(_landing(sim, unit, origin, vel), station) \
		<= _chebyshev(origin, station)


## W4-B §4.9b engage/wear steering step: the first candidate achieving the
## best lexicographic objective (§4.11.8 pin 1 — enumeration is the
## tie-break): ① heading-bucket gap to `desired` (a (0,0) pick keeps the
## current heading), ② arc penalty — 0 when the landing cell + landing
## heading keep the nearest enemy in a fireable broadside arc, ③ station
## deviation (skipped without a station). All landings judged through
## `_landing` — the §4.11.8 landing discipline.
static func _heading_hold_step(sim: BattleSimLib, unit: Dictionary,
		candidates: Array, station: Vector2i, desired: int,
		enemy_cell: Vector2i) -> Vector2i:
	if candidates.is_empty():
		return BattleSimLib.NO_CELL
	var origin := sim.unit_cell(unit)
	var current := posmod(int(unit.get("heading8", 0)),
		BattleSimLib.HEADING_RAYS.size())
	var best := BattleSimLib.NO_CELL
	var best_gap := 0
	var best_arc := 0
	var best_dev := 0
	for vel in candidates:
		var landing := _landing(sim, unit, origin, vel)
		var heading := current if vel == Vector2i.ZERO \
			else posmod(BattleSimLib.heading8_of(vel),
				BattleSimLib.HEADING_RAYS.size())
		var gap := BattleSimLib.bucket_distance(heading, desired)
		var arc := 0 if _bearing_in_arc(landing, heading, enemy_cell) else 1
		var dev := 0
		if station != BattleSimLib.NO_CELL:
			dev = _chebyshev(landing, station)
		if best == BattleSimLib.NO_CELL or gap < best_gap \
				or (gap == best_gap and arc < best_arc) \
				or (gap == best_gap and arc == best_arc and dev < best_dev):
			best = vel
			best_gap = gap
			best_arc = arc
			best_dev = dev
	return best


## Whether a ship at `from` facing `heading` has `to` in a fireable
## broadside arc: the §4.4 arcs are the sim's SIGNED counterclockwise steps
## off the heading — port {1,2,3} ∪ starboard {5,6,7} — i.e. neither
## dead-ahead (0) nor dead-astern (4).
static func _bearing_in_arc(from: Vector2i, heading: int, to: Vector2i) -> bool:
	if from == to:
		return false
	var bearing := posmod(BattleSimLib.heading8_of(to - from), 8)
	var steps := posmod(bearing - posmod(heading, 8), 8)
	return steps != 0 and steps != 4


## W4-B §4.9b ordered ⑥: the first candidate minimizing the landing-cell
## Chebyshev distance to the order's `station`, preferring in-band
## magnitudes (`desired_speed_band`) as a first-stage pool — a preference,
## never a filter (an empty in-band pool falls back to all candidates, so
## the band can only steer, never strand). No §4.9a hook deceleration —
## stations are not hook windows.
static func _station_step(sim: BattleSimLib, unit: Dictionary,
		candidates: Array, station: Vector2i, band_lo: int, band_hi: int,
		band_ok: bool) -> Vector2i:
	if candidates.is_empty():
		return BattleSimLib.NO_CELL
	var pool := candidates
	if band_ok:
		var in_band := candidates.filter(func(vel: Vector2i) -> bool:
			var magnitude := BattleSimLib.vel_length(vel)
			return magnitude >= float(band_lo) and magnitude <= float(band_hi))
		if not in_band.is_empty():
			pool = in_band
	var origin := sim.unit_cell(unit)
	var best := BattleSimLib.NO_CELL
	var best_distance := 0
	for vel in pool:
		var distance := _chebyshev(_landing(sim, unit, origin, vel), station)
		if best == BattleSimLib.NO_CELL or distance < best_distance:
			best = vel
			best_distance = distance
	return best


## W4-B §4.9b screen ⑥: close on the nearest enemy while preferring
## landings within the §4.9b flagship screen radius (Chebyshev
## [constant SCREEN_RADIUS] of `station` — the anchor the order carries).
## Objective: (outside-radius penalty, resulting distance to the enemy),
## first-best by enumeration. `NO_CELL` only when no candidate exists.
static func _screen_close_step(sim: BattleSimLib, unit: Dictionary,
		candidates: Array, station: Vector2i, nearest: Dictionary) -> Vector2i:
	if candidates.is_empty():
		return BattleSimLib.NO_CELL
	var origin := sim.unit_cell(unit)
	var target_cell: Vector2i = sim.unit_cell(nearest["unit"])
	var best := BattleSimLib.NO_CELL
	var best_outside := 0
	var best_distance := 0
	for vel in candidates:
		var landing := _landing(sim, unit, origin, vel)
		var outside := 0 if _chebyshev(landing, station) <= SCREEN_RADIUS else 1
		var distance := _chebyshev(landing, target_cell)
		if best == BattleSimLib.NO_CELL or outside < best_outside \
				or (outside == best_outside and distance < best_distance):
			best = vel
			best_outside = outside
			best_distance = distance
	return best


## Whether `player_ships` (living, fleet-index order) carries `index`.
static func _has_fleet_index(player_ships: Array, index: int) -> bool:
	for ship in player_ships:
		if int(ship.get("index", -1)) == index:
			return true
	return false


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
