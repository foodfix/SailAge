class_name FleetCommander
extends RefCounted
## The §4.9b fleet-command layer (Phase 9 W4-B): per-round **order
## five-tuples** for a multi-ship AI fleet, consumed by [method
## AiFleet.decide]'s order parameter (docs/60-COMBAT.md §4.9b, §4.12.3).
##
## PURE and ZERO-RNG: the same `(view, profile, state)` triple always yields
## the same orders array — assert-friendly by construction (no `randi`, no
## `Time`, no autoload writes; the only globals read are read-only data).
##
## INTERFACE (§4.12.3 pin — names + purity; the dict shapes below are the
## W4-B refinement the wave owns):
##
##   generate_orders(view: Dictionary, profile: Dictionary,
##       state: Dictionary) -> Array
##
##   view    — the read-only battle view the CALLER assembles from the sim:
##             `{units: Array, round: int, enemy_kind: String}` where each
##             unit dict is the sim's unit shape (side / index / pos / vel /
##             heading8 / ship / alive — `BattleSim.units()` entries verbatim,
##             both sides). Optional key `side_morale` (int 0..100): the
##             caller threads `sim.side_morale("enemy")` through it WHEN the
##             W4-A seam exists (merge-order guard — absent/null ⇒ the
##             §4.9b pre-fleet-layer fallback: no morale break). The view is
##             never mutated.
##   profile — the §4.10 row via `AiFleet.profile_for(kind)` (six live T2
##             keys + `formation`). Never mutated.
##   state   — the commander's persistent per-battle state the CALLER owns
##             and passes back each round, seeded once by [method
##             initial_state]:
##                 {
##                   formation: String,      # line_ahead|column|screen|swarm
##                   phase: String,          # form|close|engage|wear|break|screen|swarm
##                   phase_rounds: int,      # completed rounds in `phase`
##                   anchor_pos: Vector2i,   # the formation reference cell
##                   anchor_heading: int,    # the queue heading bucket 0..7
##                   assignments: {},        # ai fleet index -> player fleet index
##                   flagship_down: bool,    # succession has happened
##                 }
##             **Updated IN PLACE**: [method generate_orders] writes the
##             post-round phase / phase_rounds / anchor / assignments back
##             into the same dict, so the caller's only duty is to keep
##             passing the same dictionary once per round. Determinism holds:
##             same view + same incoming state ⇒ same orders AND same
##             outgoing state.
##
##   returns — one entry per LIVING AI ship, fleet-index order:
##             `{index: int, order: Dictionary}` with the §4.9b five-tuple
##             `{station: Vector2i, desired_heading8: int,
##               desired_speed_band: [lo, hi], assigned_target: int,
##               discipline: bool}` (`assigned_target` = player fleet index,
##             −1 = none) plus the consumption rider `phase: String` — the
##             state-machine phase the order was emitted under; [method
##             AiFleet.decide] keys its steering modes on it. The five-tuple
##             keys are the §4.9b contract; the rider is W4-B plumbing.
##
## STATE MACHINE `form → close → engage → wear → break` (§4.9b table),
## per formation: `line_ahead` runs all five; `column` = form/close/engage
## (+ wear/break as forced states); `screen` = flagship-radius-3 screen +
## free fire (no line states); `swarm` = target assignment only. Round
## accounting: `phase_rounds` counts COMPLETED rounds in the phase; the
## exit test runs before the round's orders are emitted, and a transition
## needs `held ≥ 2` (hysteresis) unless forced. Forced transitions: the
## `form` 3-round bail-out, the §4.9b morale break (side morale ≤ 20 —
## terminal, from any line state), `column`'s engage→wear (hysteresis-exempt
## per "+wear/break as forced states"), and `wear`'s own lock exit (the lock
## IS the wear gate — §4.9b table row; it cannot be interrupted by anything
## else). Geometry: all §4.9b judgments are on CURRENT (already-landed)
## positions; the landing-cell discipline of §4.11.8 pin 1 applies where
## velocities exist — inside [method AiFleet.decide], which reuses
## `AiFleet._landing` (never a second sweep preview here).

const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

# --- Pinned numbers (docs/60-COMBAT.md §4.9b — nothing invented) -------------

const HYSTERESIS_ROUNDS := 2       # "every state holds ≥ 2 rounds"
const FORM_BAIL_ROUNDS := 3        # form bail-out "after 3 rounds"
const STATION_DEVIATION_MAX := 2   # form exit: station deviation ≤ 2
const CLOSE_ENGAGE_RANGE := 5      # close exit: nearest enemy Chebyshev ≤ 5
const WEAR_TOLERANCE_BUCKETS := 1  # wear lock: within ±1 bucket
const MORALE_BREAK := 20           # side morale ≤ 20 ⇒ break (AiFleetLib pin)

# --- Phase / formation vocabulary (the state-dict's string values) -----------

const PHASE_FORM := "form"
const PHASE_CLOSE := "close"
const PHASE_ENGAGE := "engage"
const PHASE_WEAR := "wear"
const PHASE_BREAK := "break"
const PHASE_SCREEN := "screen"
const PHASE_SWARM := "swarm"

const FORMATION_LINE_AHEAD := "line_ahead"
const FORMATION_COLUMN := "column"
const FORMATION_SCREEN := "screen"
const FORMATION_SWARM := "swarm"

const PERPENDICULAR_BUCKETS := 2   # ±90° in the 8-bucket compass


# --- Construction (docs/60-* §4.9b, §4.12.3) ---------------------------------

## The battle-start state the caller seeds and keeps passing back: the
## formation from the profile row, the anchor = flagship pos + heading8
## (§4.9b "anchor = flagship pos + heading8 at battle start"). The phase
## opens at `form` for the line formations, at the formation's own
## non-walked phase for screen/swarm. Pure.
static func initial_state(formation: String, anchor_pos: Vector2i,
		anchor_heading: int) -> Dictionary:
	var resolved := formation
	if resolved != FORMATION_LINE_AHEAD and resolved != FORMATION_COLUMN \
			and resolved != FORMATION_SCREEN:
		resolved = FORMATION_SWARM  # unknown rows degrade to swarm semantics
	return {
		"formation": resolved,
		"phase": _opening_phase(resolved),
		"phase_rounds": 0,
		"anchor_pos": _wrap_in_grid(anchor_pos),
		"anchor_heading": posmod(anchor_heading, BattleSimLib.HEADING_RAYS.size()),
		"assignments": {},
		"flagship_down": false,
	}


static func _opening_phase(formation: String) -> String:
	if formation == FORMATION_LINE_AHEAD or formation == FORMATION_COLUMN:
		return PHASE_FORM
	if formation == FORMATION_SCREEN:
		return PHASE_SCREEN
	return PHASE_SWARM


# --- The per-round entry point (§4.12.3 pin signature) -----------------------

## Emits one five-tuple per living AI ship and advances `state` in place
## (see the module doc). Pure, deterministic, zero RNG.
static func generate_orders(view: Dictionary, profile: Dictionary,
		state: Dictionary) -> Array:
	var own: Array = _living_fleet(view)
	if own.is_empty():
		return []
	var enemies: Array = _living_enemies(view)
	if enemies.is_empty():
		return []
	var morale := _view_morale(view)

	_update_anchor(state, own)
	_advance_state_machine(state, own, enemies, morale)

	var phase := str(state.get("phase", PHASE_SWARM))
	var assignments: Dictionary = state.get("assignments", {})
	# §4.9b target assignment: recomputed live in engage (and in the swarm
	# formation, whose only business IS the assignment); wear keeps the last
	# engage distribution (the maneuver holds the line it engaged with) and
	# break keeps it too ("dissolve to swarm — assignments kept").
	if phase == PHASE_ENGAGE or phase == PHASE_SWARM:
		assignments = _assign_targets(profile, state, own, enemies)
		state["assignments"] = assignments

	var stations := _stations(state, own)
	var orders: Array = []
	for unit in own:
		orders.append({
			"index": int(unit.get("index", -1)),
			"order": _order_for(unit, state, phase, stations, assignments),
		})
	return orders


# --- State machine (docs/60-* §4.9b table) -----------------------------------

## Runs the §4.9b exit tests for the current phase against the CURRENT view,
## applies hysteresis / forced-transition rules, and writes the resulting
## phase (with the entry hooks' anchor bookkeeping) into `state`.
static func _advance_state_machine(state: Dictionary, own: Array,
		enemies: Array, morale: int) -> void:
	var formation := str(state.get("formation", FORMATION_SWARM))
	# screen/swarm rows have no line states — their phase is their formation.
	if formation == FORMATION_SCREEN or formation == FORMATION_SWARM:
		return
	var phase := str(state.get("phase", PHASE_FORM))
	var held := maxi(int(state.get("phase_rounds", 0)), 0)
	var anchor: Vector2i = state.get("anchor_pos", Vector2i.ZERO)

	# §4.9b bullet: side morale ≤ 20 ⇒ break — forced, terminal, from any
	# line state (the seam is threaded through the view; absent ⇒ the
	# pre-fleet-layer fallback: no morale break).
	if morale >= 0 and morale <= MORALE_BREAK and phase != PHASE_BREAK:
		_enter(state, PHASE_BREAK)
		return
	if phase == PHASE_BREAK:
		return  # terminal for the battle

	var nearest: Dictionary = _nearest_enemy_cell(anchor, enemies)
	var bearing := _bearing_to(anchor, nearest)
	match phase:
		PHASE_FORM:
			var settled := _formation_settled(state, own)
			# Forced bail-out: "after 3 rounds" → close. Otherwise the
			# completion exit needs the hysteresis hold as well.
			if held >= FORM_BAIL_ROUNDS \
					or (settled and held >= HYSTERESIS_ROUNDS):
				_enter_close(state, bearing)
			else:
				state["phase_rounds"] = held + 1
		PHASE_CLOSE:
			# Column cruise: aim the queue at the enemy and step the anchor
			# one cell (clamped in-grid — the cruise never wraps; only the
			# trailing stations do). The step commits first; the exit test
			# reads the committed cell.
			var moved := _clamp_in_grid(
				anchor + BattleSimLib.HEADING_RAYS[posmod(bearing, 8)])
			state["anchor_pos"] = moved
			state["anchor_heading"] = posmod(bearing,
				BattleSimLib.HEADING_RAYS.size())
			if _chebyshev(moved, nearest["cell"]) <= CLOSE_ENGAGE_RANGE \
					and held >= HYSTERESIS_ROUNDS:
				_enter_engage(state, bearing)
			else:
				state["phase_rounds"] = held + 1
		PHASE_ENGAGE:
			var parallel := _is_parallel(bearing,
				int(state.get("anchor_heading", 0)))
			# line_ahead: the bearing-parallel exit is a non-forced
			# transition (hysteresis). column: "+wear as a forced state" —
			# hysteresis-exempt.
			var may_wear := held >= HYSTERESIS_ROUNDS \
				or formation == FORMATION_COLUMN
			if parallel and may_wear:
				_enter_wear(state, bearing)
			else:
				state["phase_rounds"] = held + 1
		PHASE_WEAR:
			# Locked until every living ship is within ±1 bucket (the §4.9b
			# wear row IS the gate — no extra hysteresis on top; nothing
			# else may interrupt the maneuver).
			if _wear_complete(state, own):
				_enter_engage(state, bearing)
			else:
				state["phase_rounds"] = held + 1


static func _enter(state: Dictionary, phase: String) -> void:
	state["phase"] = phase
	state["phase_rounds"] = 0


static func _enter_close(state: Dictionary, bearing: int) -> void:
	_enter(state, PHASE_CLOSE)
	if bearing >= 0:
		state["anchor_heading"] = posmod(bearing, BattleSimLib.HEADING_RAYS.size())


## Engage entry: the queue heading sticks at a perpendicular (±90° bucket)
## of the enemy bearing — the one requiring the smaller turn from the old
## queue heading, ties to +90° (§4.9b "perpendicular to the enemy bearing").
static func _enter_engage(state: Dictionary, bearing: int) -> void:
	_enter(state, PHASE_ENGAGE)
	if bearing >= 0:
		var old := int(state.get("anchor_heading", 0))
		state["anchor_heading"] = _perpendicular_toward(bearing, old)


## Wear entry: the wear heading = the old engage heading ± 90° toward the
## new enemy bearing (both candidates are ⊥ the bearing because wear fires
## only when the bearing is parallel to the old queue); the smaller step
## toward the bearing wins, ties to +90°.
static func _enter_wear(state: Dictionary, bearing: int) -> void:
	_enter(state, PHASE_WEAR)
	if bearing >= 0:
		var old := int(state.get("anchor_heading", 0))
		state["anchor_heading"] = _wear_heading(old, bearing)


static func _is_parallel(bearing: int, queue: int) -> bool:
	var steps := BattleSimLib.bucket_distance(bearing, queue)
	return steps == 0 or steps == 4


## Every LIVING ship within station deviation ≤ 2 (Chebyshev, §4.9b form row).
static func _formation_settled(state: Dictionary, own: Array) -> bool:
	var stations := _stations(state, own)
	for unit in own:
		var station: Vector2i = stations.get(int(unit.get("index", -1)),
			_cell_of(unit))
		if _chebyshev(_cell_of(unit), station) > STATION_DEVIATION_MAX:
			return false
	return true


## The wear lock: every LIVING ship's heading within ±1 bucket of the wear
## heading (the queue heading this phase installed).
static func _wear_complete(state: Dictionary, own: Array) -> bool:
	var target := posmod(int(state.get("anchor_heading", 0)),
		BattleSimLib.HEADING_RAYS.size())
	for unit in own:
		if BattleSimLib.bucket_distance(
				posmod(int(unit.get("heading8", 0)),
					BattleSimLib.HEADING_RAYS.size()), target) \
				> WEAR_TOLERANCE_BUCKETS:
			return false
	return true


# --- Anchor & succession (docs/60-* §4.9b) -----------------------------------

## While the flagship lives the anchor is commander-driven (form/close/
## engage/wear bookkeeping below). §4.9b succession: when the flagship has
## sunk, the LOWEST living fleet index takes the anchor — its pos + heading8,
## re-read every round so a further loss hands the anchor on — and the state
## machine inherits unchanged (phase/phase_rounds/assignments untouched).
static func _update_anchor(state: Dictionary, own: Array) -> void:
	var flagship_alive := false
	for unit in own:
		if int(unit.get("index", -1)) == 0:
			flagship_alive = true
			break
	if flagship_alive and not bool(state.get("flagship_down", false)):
		return
	# `own` is fleet-index sorted, so [0] IS the lowest living index.
	var holder: Dictionary = own[0]
	var heading := posmod(int(holder.get("heading8", 0)),
		BattleSimLib.HEADING_RAYS.size())
	state["flagship_down"] = true
	state["anchor_pos"] = _wrap_in_grid(_cell_of(holder)
		+ BattleSimLib.HEADING_RAYS[heading])
	state["anchor_heading"] = heading


# --- Formation geometry (docs/60-* §4.9b form row) ---------------------------

## Stations: ship i at `anchor − i × ray`, wrapped in-grid. line_ahead rays
## run along the RECIPROCAL of the queue heading (the line trails behind the
## anchor); column rays run along the perpendicular (lateral spacing).
static func _stations(state: Dictionary, own: Array) -> Dictionary:
	var formation := str(state.get("formation", FORMATION_SWARM))
	var anchor: Vector2i = state.get("anchor_pos", Vector2i.ZERO)
	var heading := posmod(int(state.get("anchor_heading", 0)),
		BattleSimLib.HEADING_RAYS.size())
	var ray: Vector2i = BattleSimLib.HEADING_RAYS[heading]
	if formation == FORMATION_COLUMN:
		ray = BattleSimLib.HEADING_RAYS[
			posmod(heading + PERPENDICULAR_BUCKETS,
				BattleSimLib.HEADING_RAYS.size())]
	var out := {}
	for unit in own:
		var index := int(unit.get("index", -1))
		out[index] = _wrap_in_grid(anchor - ray * index)
	return out


## Longitude/latitude wrap into the battle grid (§4.9b "wrapped in-grid").
static func _wrap_in_grid(cell: Vector2i) -> Vector2i:
	var x := posmod(cell.x, BattleSimLib.GRID_WIDTH)
	var y := posmod(cell.y, BattleSimLib.GRID_HEIGHT)
	return Vector2i(x, y)


## In-grid clamp (the close cruise stops at the map edge instead of wrapping).
static func _clamp_in_grid(cell: Vector2i) -> Vector2i:
	return Vector2i(
		clampi(cell.x, 0, BattleSimLib.GRID_WIDTH - 1),
		clampi(cell.y, 0, BattleSimLib.GRID_HEIGHT - 1))


# --- Target assignment (docs/60-* §4.9b) -------------------------------------

## Round-robin over the enemy by the profile `focus` ordering, ships in
## fleet-index order; at `aggression ≥ 80` every ship gets the focus-top
## target (§4.9b focus fire). Returns `{ai index: player index}`.
static func _assign_targets(profile: Dictionary, state: Dictionary,
		own: Array, enemies: Array) -> Dictionary:
	var anchor: Vector2i = state.get("anchor_pos", Vector2i.ZERO)
	var ordered := _focus_ordered(profile, enemies, anchor)
	if ordered.is_empty():
		return {}
	var focus_fire := int(profile.get("aggression", 0)) \
		>= AiFleetLib.FOCUS_FIRE_AGGRESSION
	var out := {}
	var slot := 0
	for unit in own:
		var pick: Dictionary = ordered[0] if focus_fire \
			else ordered[slot % ordered.size()]
		out[int(unit.get("index", -1))] = int(pick.get("index", -1))
		slot += 1
	return out


## The §4.11.8 pin 2 focus ordering as a TOTAL order (Godot's sort is not
## stable, so every comparator carries the fleet-index tiebreak):
## `weakest` = lowest current durability; `nearest` = minimum Chebyshev from
## the anchor; `flagship` = player index 0 first with the weakest fallback.
static func _focus_ordered(profile: Dictionary, enemies: Array,
		from: Vector2i) -> Array:
	var arr := enemies.duplicate()
	var focus := str(profile.get("focus", "weakest"))
	if focus == "flagship":
		arr.sort_custom(_flagship_less)
	elif focus == "nearest":
		arr.sort_custom(func(a, b) -> bool: return _nearest_less(from, a, b))
	else:
		arr.sort_custom(_weakest_less)
	return arr


## `flagship` focus: player index 0 first, the weakest ordering behind it.
static func _flagship_less(a, b) -> bool:
	var ra := 0 if int(a.get("index", -1)) == 0 else 1
	var rb := 0 if int(b.get("index", -1)) == 0 else 1
	if ra != rb:
		return ra < rb
	return _weakest_less(a, b)


static func _weakest_less(a, b) -> bool:
	var da := int(a.get("ship", {}).get("durability", 0))
	var db := int(b.get("ship", {}).get("durability", 0))
	if da != db:
		return da < db
	return int(a.get("index", -1)) < int(b.get("index", -1))


static func _nearest_less(from: Vector2i, a, b) -> bool:
	var da := _chebyshev(from, _cell_of(a))
	var db := _chebyshev(from, _cell_of(b))
	if da != db:
		return da < db
	return int(a.get("index", -1)) < int(b.get("index", -1))


# --- Order emission (the §4.9b five-tuple + the phase rider) -----------------

static func _order_for(unit: Dictionary, state: Dictionary, phase: String,
		stations: Dictionary, assignments: Dictionary) -> Dictionary:
	var index := int(unit.get("index", -1))
	var own_cell := _cell_of(unit)
	var own_heading := posmod(int(unit.get("heading8", 0)),
		BattleSimLib.HEADING_RAYS.size())
	var order := {
		"station": own_cell,
		"desired_heading8": own_heading,
		"desired_speed_band": [0, _hull_max_speed(unit)],
		"assigned_target": -1,
		"discipline": false,
		"phase": phase,
	}
	match phase:
		PHASE_FORM, PHASE_CLOSE:
			# Sail to the formation slot; the queue heading rides along
			# (the consumer holds headings only in engage/wear).
			order["station"] = stations.get(index, own_cell)
			order["desired_heading8"] = posmod(
				int(state.get("anchor_heading", 0)),
				BattleSimLib.HEADING_RAYS.size())
		PHASE_ENGAGE, PHASE_WEAR:
			# Broadside-on: hold the queue heading, keep the line
			# (discipline = true — the §4.9b hard constraint), fire at the
			# assigned target.
			order["station"] = stations.get(index, own_cell)
			order["desired_heading8"] = posmod(
				int(state.get("anchor_heading", 0)),
				BattleSimLib.HEADING_RAYS.size())
			order["discipline"] = true
			order["assigned_target"] = int(assignments.get(index, -1))
		PHASE_SCREEN:
			# Flagship-radius-3 screen: the station is the screen CENTER
			# (the anchor) — the consumer ranks candidates by the radius,
			# never piling onto the cell. Free fire, no discipline.
			order["station"] = _wrap_in_grid(state.get("anchor_pos",
				Vector2i.ZERO))
		PHASE_SWARM, PHASE_BREAK:
			# Target assignment only — steering and heading free
			# (break keeps the last engage distribution).
			order["assigned_target"] = int(assignments.get(index, -1))
	return order


## The §4.9b close-row speed band "full (0..battle_max_speed)" — per hull,
## mirroring `BattleSimLib.battle_max_speed`'s defaults from the W2 data.
static func _hull_max_speed(unit: Dictionary) -> int:
	var ship: Dictionary = unit.get("ship", {})
	var ship_type: Dictionary = DataLoader.get_ship_type(
		str(ship.get("ship_type_id", "")))
	return maxi(1, int(ship_type.get("battle_max_speed", 2)))


# --- View / geometry helpers -------------------------------------------------

## Living AI-side units, fleet-index order (fresh arrays — the view is never
## mutated, never sorted in place).
static func _living_fleet(view: Dictionary) -> Array:
	return _living_side(view, BattleSimLib.SIDE_ENEMY)


static func _living_enemies(view: Dictionary) -> Array:
	return _living_side(view, BattleSimLib.SIDE_PLAYER)


static func _living_side(view: Dictionary, side: String) -> Array:
	var out: Array = []
	for unit in view.get("units", []):
		if unit is Dictionary and str(unit.get("side", "")) == side \
				and bool(unit.get("alive", false)):
			out.append(unit)
	out.sort_custom(func(a, b) -> bool:
		return int(a.get("index", -1)) < int(b.get("index", -1)))
	return out


## The defensive W4-A morale thread: the CALLER copies `sim.side_morale`
## into the view when the seam exists (§4.9b bullet); absent or non-numeric
## ⇒ −1 = "no reading" ⇒ the pre-fleet-layer fallback (no morale break).
static func _view_morale(view: Dictionary) -> int:
	var reading = view.get("side_morale", null)
	if reading is int or reading is float:
		return int(reading)
	return -1


## Nearest living enemy cell from `from`: minimum Chebyshev, ties to the
## lower fleet index (`enemies` arrives index-sorted and only a strict win
## replaces the holder).
static func _nearest_enemy_cell(from: Vector2i, enemies: Array) -> Dictionary:
	var best := {}
	for unit in enemies:
		var cell := _cell_of(unit)
		var distance := _chebyshev(from, cell)
		if best.is_empty() or distance < int(best["distance"]):
			best = {"cell": cell, "distance": distance}
	return best


## The bearing bucket from `from` toward the nearest enemy cell (−1 when
## there is none — callers guard). Degenerate same-cell reads resolve east
## via `heading8_of`, deterministically.
static func _bearing_to(from: Vector2i, nearest: Dictionary) -> int:
	if nearest.is_empty():
		return -1
	return BattleSimLib.heading8_of(
		Vector2i(nearest["cell"]) - from)


static func _perpendicular_toward(bearing: int, from_heading: int) -> int:
	var clockwise := posmod(bearing + PERPENDICULAR_BUCKETS,
		BattleSimLib.HEADING_RAYS.size())
	var counter := posmod(bearing - PERPENDICULAR_BUCKETS,
		BattleSimLib.HEADING_RAYS.size())
	if BattleSimLib.bucket_distance(from_heading, counter) \
			< BattleSimLib.bucket_distance(from_heading, clockwise):
		return counter
	return clockwise


static func _wear_heading(old: int, bearing: int) -> int:
	var clockwise := posmod(old + PERPENDICULAR_BUCKETS,
		BattleSimLib.HEADING_RAYS.size())
	var counter := posmod(old - PERPENDICULAR_BUCKETS,
		BattleSimLib.HEADING_RAYS.size())
	if BattleSimLib.bucket_distance(counter, bearing) \
			< BattleSimLib.bucket_distance(clockwise, bearing):
		return counter
	return clockwise


## Delegated to the T2 module — one Chebyshev implementation in the combat
## AI (the preload-reuse rule; never a second copy).
static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return AiFleetLib._chebyshev(a, b)


static func _cell_of(unit: Dictionary) -> Vector2i:
	return BattleSimLib.to_cell(unit.get("pos",
		unit.get("cell", BattleSimLib.NO_CELL)))
