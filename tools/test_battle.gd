extends Node
## Phase-9 W3-D — the fixed-situation battle suite, re-pinned onto the
## velocity-physics engine (docs/IMPLEMENT-Phase9.md W3-D; docs/60-COMBAT.md
## §4.2, §4.3, §4.3a, §4.4, §4.3a/§4.4a/§4.4b/§4.6a, §4.11.2, §4.11.4,
## §4.11.5, §4.11.8, §4.11.9, §4.11.10, §4.11.12, §4.12.1). Headless:
##
##   godot --headless res://tools/test_battle.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## The suite drives `scripts/combat/battle_sim.gd` DIRECTLY (the merged W3-A
## engine) with its own inline policy callables — it never calls
## `AiFleet.decide` (W3-B seam: B's T2 rewrite is in flight on another
## branch; everything AI-shaped here is expressed as a local policy stub).
## Every check pins a doc number: the constant or closed form is asserted,
## never re-derived.
##
## Sections (the W3-D slot list):
##   1  grid + §4.11.2 deployment: 48×30, the six pinned cells per side,
##      band overflow scan, the tournament variant cells/velocities;
##   2  §4.3a velocity legality: angle / magnitude-delta / cap order,
##      standstill any-direction, (0,0) always legal, (y,x) enumeration
##      order + Chebyshev box bound, overshoot clamp along the direction;
##   3  §4.3a cap_eff tiers: the wind_factor table × direction_factor
##      columns (calm identity), the current ±1 pin, the chain debuff −1
##      with floor 1, the sail delta applied after the clamp;
##   4  §4.3a heading8: integer dot/cross bucketing at the 22.5°
##      boundaries, (0,0) keeps the last heading;
##   5  §4.4 broadside arcs {45,90,135}/{225,270,315} + the floor(n/2)
##      split with the retained total;
##   6  §4.4a reload: gunnery 0/50/100 → 3/2/1, the legacy 10+10×tier
##      fallback, low-crew +1, per-side independence
##      (`reload_side = round + reload_turns`);
##   7  §4.11.5 crew casualties: /20 standard, /10 rake, boarding winner
##      floor(crew × 0.2), clamp at 0 (a 0-crew ship still sails);
##   8  §4.4b grape: range 1 only, hull = floor(same-range round × 0.5),
##      crew kill = same, no gate;
##   9  §4.4b the four shot-rule situations (chain / grape / armor-
##      piercing / round fall-through) + the chain-over-grape priority;
##  10  §4.4/§4.11.5 the damage stack: one floor after the weather term,
##      storm ×0.75 / strong ×0.9 / rake ×1.25, shot multipliers;
##  11  §4.5/§4.3a the sweep: enemy-entry ram, friendly stop at the prior
##      cell (zero damage), out-of-bounds stop, the ram multipliers
##      (speed, bow/stern ×1.15, oar ×1.25), attacker resolves last;
##  12  §4.6a the hook: orthogonal + both ⌊vel⌋ ≤ 1 + weather ≠ storm,
##      both velocities zeroed, storm refuses;
##  13  §4.11.9 stall: 8 quiet rounds within a ±2 net distance window,
##      the drift window breach, any damage resets the counter, a
##      decisive battle never stalls;
##  14  §4.11.4 initiative: built ONCE (speed + sail delta desc, player
##      first, fleet index), a destroyed unit skips its slot, the order
##      never re-sorts;
##  15  §4.11.1 determinism: same seed ⇒ identical log_lines() + outcome
##      over two full run_to_completion runs;
##  16  §4.11.6 duel bases carried over from Phase 8;
##  17  §4.11.10 economy pins carried over (salvage, XP, rep, the 40-round
##      cap, the menu outcomes);
##  18  §4.11.3 compose_enemy (slim — W3-B will derive the broadside split;
##      these composition pins hold under both).

const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const AiLib := preload("res://scripts/combat/ai_fleet.gd")
const RewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

## FLEET_MAX (docs/40-* §4.4) — the deployment table has 5 rows per side.
const TABLE_ROWS := 5

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_grid_and_deployment()
	_test_velocity_legality()
	_test_cap_eff()
	_test_heading8()
	_test_arcs()
	_test_reload()
	_test_casualties()
	_test_grape()
	_test_ai_shot_rule()
	_test_damage_stack()
	_test_sweep_ram()
	_test_hook()
	_test_stall()
	_test_initiative()
	_test_determinism()
	_test_duel_bases()
	_test_economy_pins()
	_test_compose_enemy()
	_report()


# --- Fixtures --------------------------------------------------------------

## A Phase-8 Person-model player block (the `50-*` §4.8 shape). Courage and
## charisma default to 10 so `floor(x / 20)` terms stay 0 unless raised.
func _person(swordplay: int = 10, gunnery: int = 0, overrides: Dictionary = {}) -> void:
	var attributes := {
		"constitution": 10, "intellect": 10, "charisma": 10,
		"courage": 10, "luck": 10,
	}
	var skills := {
		"seamanship": 0, "navigation": 0, "swordplay": swordplay, "gunnery": gunnery,
		"appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0,
	}
	var attribute_overrides: Dictionary = overrides.get("attributes", {}) \
		if overrides.get("attributes", {}) is Dictionary else {}
	var skill_overrides: Dictionary = overrides.get("skills", {}) \
		if overrides.get("skills", {}) is Dictionary else {}
	for key in attribute_overrides:
		attributes[key] = attribute_overrides[key]
	for key in skill_overrides:
		skills[key] = skill_overrides[key]
	GameState.player = {
		"nation_id": "portugal",
		"attributes": attributes,
		"skills": skills,
		"officers": [],
		"equipment": {"weapon": "", "armor": ""},
	}


## A §4.11.11 ship instance (the `40-*` §4.1 shape + the §4.11.12 equipment
## object). `crew` defaults to the hull's crew_min.
func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


func _sim(config: Dictionary) -> BattleLib:
	# `current` defaults to strength 0 so the fixtures are hermetic — the
	# §4.12.1 default (the decoded contact-tile current) would leak a ±1
	# cap mod from the real raster; the cap tests pass their own current.
	var full := {
		"player_ships": [], "enemy_ships": [], "enemy_kind": "pirate",
		"enemy_nation": "", "day": 1, "gold": 0,
		"contact": Vector2i(30, 40), "weather": "calm",
		"current": {"dir": "", "strength": 0},
	}
	for key in config:
		full[key] = config[key]
	return BattleLib.new(full)


## The live unit dict of `side`/`index` (unit dicts are the engine's handles).
func _unit(sim: BattleLib, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


## Repositions / re-states a unit. Fixtures need close-quarters setups:
## §4.11.2 deployment deliberately opens every battle 43 tiles apart ("every
## battle opens with an approach phase"), so the fixed situations build the
## arrangement explicitly instead of sailing for twenty rounds first.
func _place(sim: BattleLib, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["pos"] = cell


func _face(unit: Dictionary, heading8: int) -> void:
	if not unit.is_empty():
		unit["heading8"] = heading8


## Ends turns until `side`/`index` is the acting unit, so direct
## cannon/ram/board fixtures resolve exactly as in a battle (§4.11.4
## is_acting + one-action-per-turn).
func _begin_turn(sim: BattleLib, side: String, index: int) -> Dictionary:
	for _guard in 16:
		var current := sim.current_unit()
		if current.is_empty():
			return {}
		if str(current["side"]) == side and int(current["index"]) == index:
			return current
		sim.end_turn()
	return {}


func _order_of(sim: BattleLib, count: int) -> Array:
	var out: Array = []
	for _index in count:
		var unit := sim.current_unit()
		if unit.is_empty():
			break
		out.append("%s:%d" % [str(unit["side"]), int(unit["index"])])
		sim.end_turn()
	return out


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## The cell the §4.3a Bresenham sweep actually reaches for `step` from the
## unit's cell (the walk stops at the first out-of-bounds or occupied cell;
## the mover stays at the PRIOR cell) — the same preview the harness uses.
func _landing(sim: BattleLib, unit: Dictionary, step: Vector2i) -> Vector2i:
	var from: Vector2i = sim.unit_cell(unit)
	var prior := from
	for cell in BattleLib._bresenham_cells(from, from + step):
		if not BattleLib.in_grid(cell):
			return prior
		for other in sim.units():
			if other == unit or not bool(other.get("alive", false)):
				continue
			if sim.unit_cell(other) == cell:
				return prior
		prior = cell
	return prior


## The inline deterministic battle policy both determinism runs (and the
## economy suite) drive: ① fire a loaded side with an enemy in range+arc
## (round shot) ② else the first legal velocity whose sweep landing puts
## the nearest enemy's bearing into a broadside arc ③ else the first legal
## velocity whose landing strictly reduces Chebyshev without entering an
## occupied cell ④ hold. Pure function of the sim state — zero dice.
func _fire_and_close_policy(sim, unit: Dictionary) -> Dictionary:
	var own_side := str(unit.get("side", "player"))
	var other := "enemy" if own_side == "player" else "player"
	var enemies: Array = sim.living_units(other)
	if enemies.is_empty():
		return {"action": "hold"}
	for side in ["port", "starboard"]:
		for target in enemies:
			if sim.can_cannon(unit, target, str(side)):
				return {"action": "cannon", "target": target,
					"side": str(side), "shot": "round"}
	var from: Vector2i = sim.unit_cell(unit)
	var nearest: Dictionary = enemies[0]
	for enemy in enemies:
		if _chebyshev(from, sim.unit_cell(enemy)) \
				< _chebyshev(from, sim.unit_cell(nearest)):
			nearest = enemy
	var bearing := int(BattleLib.heading8_of(sim.unit_cell(nearest) - from))
	var legal: Array = sim.legal_velocities(unit)
	for vel in legal:
		var step: Vector2i = vel
		if step == Vector2i.ZERO:
			continue
		var steps := int(BattleLib.bucket_distance(bearing,
			int(BattleLib.heading8_of(step))))
		if steps in BattleLib.ARC_PORT_STEPS or steps in BattleLib.ARC_STARBOARD_STEPS:
			return {"action": "move", "vel": step}
	var distance := _chebyshev(from, sim.unit_cell(nearest))
	for vel in legal:
		var step: Vector2i = vel
		if step == Vector2i.ZERO:
			continue
		var landing := _landing(sim, unit, step)
		if landing != from and _chebyshev(landing, sim.unit_cell(nearest)) < distance:
			return {"action": "move", "vel": step}
	return {"action": "hold"}


# --- 1. Grid + deployment (§4.2, §4.11.2) ----------------------------------

func _test_grid_and_deployment() -> void:
	_person()
	_check(BattleLib.GRID_WIDTH == 48 and BattleLib.GRID_HEIGHT == 30,
		"§4.2: the grid is 48×30 (%d×%d)"
			% [BattleLib.GRID_WIDTH, BattleLib.GRID_HEIGHT])
	_check(BattleLib.PLAYER_BAND_MAX_X == 5 and BattleLib.ENEMY_BAND_MIN_X == 42,
		"§4.2: player band x ≤ 5, enemy band x ≥ 42 (%d/%d)"
			% [BattleLib.PLAYER_BAND_MAX_X, BattleLib.ENEMY_BAND_MIN_X])
	_check(BattleLib.PLAYER_DEPLOYMENT.size() == TABLE_ROWS
			and BattleLib.ENEMY_DEPLOYMENT.size() == TABLE_ROWS,
		"§4.11.2: the table has one row per fleet slot (%d)" % TABLE_ROWS)

	# The pinned table, verbatim (§4.11.2 — flagship centred, extras
	# alternate below/above).
	var player_table := [
		Vector2i(2, 15), Vector2i(2, 14), Vector2i(2, 16), Vector2i(2, 13), Vector2i(2, 17),
	]
	var enemy_table := [
		Vector2i(45, 15), Vector2i(45, 14), Vector2i(45, 16), Vector2i(45, 13), Vector2i(45, 17),
	]
	var player_cells: Array = []
	for cell in BattleLib.PLAYER_DEPLOYMENT:
		player_cells.append(cell)
	_check(player_cells == player_table,
		"§4.11.2: player deployment matches the pinned cells exactly (%s)" % str(player_cells))
	var enemy_cells: Array = []
	for cell in BattleLib.ENEMY_DEPLOYMENT:
		enemy_cells.append(cell)
	_check(enemy_cells == enemy_table,
		"§4.11.2: enemy deployment matches the pinned cells exactly (%s)" % str(enemy_cells))

	for count in range(1, TABLE_ROWS + 1):
		var player_ships: Array = []
		var enemy_ships: Array = []
		for _index in count:
			player_ships.append(_ship("sloop"))
			enemy_ships.append(_ship("latin"))
		var sim := _sim({"player_ships": player_ships, "enemy_ships": enemy_ships})
		sim.start()
		var placed: Array = []
		var table_ok := true
		var band_ok := true
		for index in count:
			var pc := sim.unit_cell(_unit(sim, "player", index))
			var ec := sim.unit_cell(_unit(sim, "enemy", index))
			if pc != player_table[index] or ec != enemy_table[index]:
				table_ok = false
			if pc.x > BattleLib.PLAYER_BAND_MAX_X or ec.x < BattleLib.ENEMY_BAND_MIN_X:
				band_ok = false
			placed.append(pc)
			placed.append(ec)
		var distinct := {}
		for cell in placed:
			distinct[cell] = true
		_check(table_ok, "%d ships/side: every unit sits on its §4.11.2 tile" % count)
		_check(band_ok, "%d ships/side: player band x ≤ 5, enemy band x ≥ 42 (§4.2)" % count)
		_check(distinct.size() == placed.size(),
			"%d ships/side: no two units share a cell (%d distinct of %d)"
				% [count, distinct.size(), placed.size()])
		_check(sim.units().size() == count * 2,
			"%d ships/side: the engine holds %d units" % [count, count * 2])

	# The bands open 43 cells apart (§4.11.2 "open 43 cells apart").
	_check(BattleLib.ENEMY_DEPLOYMENT[0].x - BattleLib.PLAYER_DEPLOYMENT[0].x == 43,
		"§4.11.2: the flagship bands open 43 cells apart")

	# Normal start: vel (0,0) with heading8 east / west (§4.11.2).
	var rest := _sim({"player_ships": [_ship("sloop")], "enemy_ships": [_ship("latin")]})
	rest.start()
	var rest_p := _unit(rest, "player", 0)
	var rest_e := _unit(rest, "enemy", 0)
	_check((rest_p["vel"] as Vector2i) == Vector2i.ZERO
			and (rest_e["vel"] as Vector2i) == Vector2i.ZERO,
		"§4.11.2: deployment starts every ship at vel (0,0)")
	_check(int(rest_p["heading8"]) == BattleLib.HEADING_EAST
			and int(rest_e["heading8"]) == BattleLib.HEADING_WEST,
		"§4.11.2: player faces east (%d), enemy west (%d)"
			% [int(rest_p["heading8"]), int(rest_e["heading8"])])
	_check(rest_p["vel"] == Vector2i.ZERO and rest_e["vel"] == Vector2i.ZERO,
		"§4.11.2: the standstill rule governs the first velocity pick")

	# Band overflow (more than 5 ships): the 6th continues the in-band scan.
	var overflow := _sim({
		"player_ships": [
			_ship("sloop"), _ship("sloop"), _ship("sloop"), _ship("sloop"),
			_ship("sloop"), _ship("sloop"),
		],
		"enemy_ships": [_ship("latin")],
	})
	overflow.start()
	var sixth := _unit(overflow, "player", 5)
	var sixth_cell := overflow.unit_cell(sixth)
	_check(sixth_cell == Vector2i(0, 0),
		"§4.2: a band overflow continues the in-band scan — ship 6 lands on the "
			+ "first free band cell (0,0), got %s" % str(sixth_cell))
	_check(sixth_cell.x <= BattleLib.PLAYER_BAND_MAX_X,
		"§4.2: the overflow ship stays inside the player band (x = %d)" % sixth_cell.x)
	var all_cells: Array = []
	for unit in overflow.units():
		all_cells.append(overflow.unit_cell(unit))
	var distinct_all := {}
	for cell in all_cells:
		distinct_all[cell] = true
	_check(distinct_all.size() == all_cells.size(),
		"§4.2: the overflow scan never double-books a cell (%d units)"
			% all_cells.size())

	# Tournament variant (§4.11.2): pinned cells + pinned initial velocities,
	# selected by the §4.12.1 config key `deployment: "tournament"`.
	var tour := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("brigantine")],
		"deployment": "tournament",
	})
	_check(tour.deployment == BattleLib.TOURNAMENT_DEPLOYMENT,
		"§4.12.1: the config key `deployment` carries \"tournament\" (%s)"
			% str(tour.deployment))
	tour.start()
	var tour_p := _unit(tour, "player", 0)
	var tour_e := _unit(tour, "enemy", 0)
	_check(tour.unit_cell(tour_p) == BattleLib.TOURNAMENT_PLAYER_CELL
			and tour.unit_cell(tour_e) == BattleLib.TOURNAMENT_ENEMY_CELL,
		"§4.11.2: the bout deploys at (10,15)/(37,15) (%s/%s)"
			% [str(tour.unit_cell(tour_p)), str(tour.unit_cell(tour_e))])
	_check((tour_p["vel"] as Vector2i) == BattleLib.TOURNAMENT_PLAYER_VEL
			and (tour_e["vel"] as Vector2i) == BattleLib.TOURNAMENT_ENEMY_VEL,
		"§4.11.2: pinned initial velocities (1,0)/(−1,0) (%s/%s)"
			% [str(tour_p["vel"]), str(tour_e["vel"])])
	_check(int(tour_p["heading8"]) == BattleLib.heading8_of(Vector2i(1, 0))
			and int(tour_e["heading8"]) == BattleLib.heading8_of(Vector2i(-1, 0)),
		"§4.11.2: the pinned velocities set the bout headings (%d/%d)"
			% [int(tour_p["heading8"]), int(tour_e["heading8"])])
	_check(BattleLib.TOURNAMENT_ENEMY_CELL.x - BattleLib.TOURNAMENT_PLAYER_CELL.x == 27,
		"§4.11.2: the tournament cells sit 27 apart")
	# Extras (should a fixture carry them) deploy through the band scan at rest.
	var tour_full := _sim({
		"player_ships": [_ship("brigantine"), _ship("sloop")],
		"enemy_ships": [_ship("brigantine")],
		"deployment": "tournament",
	})
	tour_full.start()
	var tour_extra := _unit(tour_full, "player", 1)
	_check((tour_extra["vel"] as Vector2i) == Vector2i.ZERO,
		"§4.11.2: a bout extra deploys at rest through the band scan")


# --- 2. Velocity legality (§4.3a, §4.11.4) ---------------------------------

func _test_velocity_legality() -> void:
	_person()
	# Brigantine: bms 4, accel 1, turn_rate 45 (data/ship_types.json, §4.3a
	# class constants). Calm wind E, heading east → cap floor(4 × 0.8) = 3.
	var sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("latin")],
		"weather": "calm", "wind_dir": "E", "current": {"dir": "", "strength": 0},
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	_check(sim.battle_max_speed(brig) == 4 and sim.battle_accel(brig) == 1
			and sim.battle_turn_rate(brig) == 45,
		"§4.3a: brigantine bms 4 / accel 1 / turn 45 (%d/%d/%d)"
			% [sim.battle_max_speed(brig), sim.battle_accel(brig),
			sim.battle_turn_rate(brig)])
	brig["vel"] = Vector2i(1, 0)
	_face(brig, BattleLib.HEADING_EAST)
	var legal: Array = sim.legal_velocities(brig)
	_check(_as_vec2i_array(legal).has(Vector2i(2, 0)),
		"§4.3a: (2,0) legal — bucket 0 ≤ 45, |Δmag| 1 ≤ accel 1, mag 2 ≤ cap 3")
	_check(_as_vec2i_array(legal).has(Vector2i(1, -1)),
		"§4.3a: (1,−1) legal — bucket NE = 45° exactly at the turn rate")
	_check(not _as_vec2i_array(legal).has(Vector2i(0, -1)),
		"§4.3a: (0,−1) illegal — bucket N = 90° > turn_rate 45 (angle leg)")
	_check(not _as_vec2i_array(legal).has(Vector2i(-1, 0)),
		"§4.3a: (−1,0) illegal — bucket W = 180° > turn_rate 45")
	_check(not _as_vec2i_array(legal).has(Vector2i(2, 1)),
		"§4.3a: (2,1) illegal — |Δmag| √5−1 > accel 1 (magnitude-delta leg)")
	_check(not _as_vec2i_array(legal).has(Vector2i(3, 0)),
		"§4.3a: (3,0) illegal — |Δmag| 2 > accel 1")
	_check(not _as_vec2i_array(legal).has(Vector2i(4, 0)),
		"§4.3a: (4,0) illegal — mag 4 > cap_eff 3 (cap leg; calm sail ×0.8)")
	_check(_as_vec2i_array(legal).has(Vector2i.ZERO),
		"§4.3a: vel (0,0) is legal whenever the magnitude delta holds")

	# The turn-rate tiers: a galley turns 90° per round (§4.3a class table).
	var oar_sim := _sim({
		"player_ships": [_ship("galley")],
		"enemy_ships": [_ship("latin")],
		"weather": "storm", "wind_dir": "E",
	})
	oar_sim.start()
	var galley := _unit(oar_sim, "player", 0)
	_check(sim.battle_turn_rate(galley) == 90 and oar_sim.battle_turn_rate(galley) == 90,
		"§4.3a: the galley's turn rate is the 90° tier (%d)"
			% oar_sim.battle_turn_rate(galley))
	galley["vel"] = Vector2i(1, 0)
	_face(galley, BattleLib.HEADING_EAST)
	var oar_legal: Array = oar_sim.legal_velocities(galley)
	_check(_as_vec2i_array(oar_legal).has(Vector2i(0, -1)),
		"§4.3a: the 90° tier turns two buckets (galley (1,0) → (0,−1))")
	_check(not _as_vec2i_array(oar_legal).has(Vector2i(-1, -1)),
		"§4.3a: the 90° tier cannot turn three buckets ((−1,−1) = 135°)")

	# Standstill: any direction legal at magnitude ≤ accel; the cap leg still
	# applies (a becalmed ship cannot start moving, §4.3a).
	brig["vel"] = Vector2i.ZERO
	_face(brig, BattleLib.HEADING_WEST)
	var still: Array = sim.legal_velocities(brig)
	for direction in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if not _as_vec2i_array(still).has(direction):
			_check(false, "§4.3a: standstill any-direction — %s missing" % str(direction))
	_check(_as_vec2i_array(still).has(Vector2i(1, 0))
			and _as_vec2i_array(still).has(Vector2i(-1, 0))
			and _as_vec2i_array(still).has(Vector2i(0, 1))
			and _as_vec2i_array(still).has(Vector2i(0, -1)),
		"§4.3a: from standstill ANY direction is legal (angle relaxed)")
	_check(not _as_vec2i_array(still).has(Vector2i(2, 0)),
		"§4.3a: standstill magnitude ≤ accel ((2,0) needs Δmag 2 > 1)")
	# The calm cap identity keeps its wind_factor penalty with no direction
	# effect: a bms-2 sail hull reads floor(2 × 0.8 × 1.0) = 1 whatever its
	# heading (the normative §4.3a sentence; see the deviation note above).
	var becalmed := _sim({
		"player_ships": [_ship("latin")],
		"enemy_ships": [_ship("sloop")],
		"weather": "calm", "wind_dir": "E",
	})
	becalmed.start()
	var latin := _unit(becalmed, "player", 0)
	_check(becalmed.cap_eff(latin) == 1,
		"§4.3a: calm identity — the latin's cap is floor(2 × 0.8) = 1 facing "
			+ "east AND west (%d)" % becalmed.cap_eff(latin))
	_face(latin, BattleLib.HEADING_WEST)
	_check(becalmed.cap_eff(latin) == 1,
		"§4.3a: …and %d facing west (no direction effect in calm)"
			% becalmed.cap_eff(latin))

	# Enumeration: (y, x) lexicographic, inside the Chebyshev box (§4.3a).
	# Galley, storm (oar ×1.0 everywhere → cap 4), standstill, accel 2:
	# exactly the mag ≤ 2 box vectors, in (y, x) order.
	var full: Array = oar_sim.legal_velocities(galley)
	galley["vel"] = Vector2i.ZERO
	full = oar_sim.legal_velocities(galley)
	var expected := [
		Vector2i(0, -2),
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
		Vector2i(0, 2),
	]
	_check(_as_vec2i_array(full) == expected,
		"§4.3a: enumeration is (y,x) lexicographic — galley standstill mag ≤ 2: %s"
			% str(full))
	var sloop_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("latin")],
		"weather": "storm", "wind_dir": "E",
	})
	sloop_sim.start()
	var sloop := _unit(sloop_sim, "player", 0)
	var sloop_legal: Array = sloop_sim.legal_velocities(sloop)
	var in_box := true
	for vel in sloop_legal:
		if absi((vel as Vector2i).x) > 3 or absi((vel as Vector2i).y) > 3:
			in_box = false
	_check(in_box and sloop_legal.size() <= 49,
		"§4.3a: bms 3 → every candidate in the 7×7 box, ≤ 49 candidates (%d)"
			% sloop_legal.size())
	_check(oar_sim.legal_velocities(galley).size() <= 81,
		"§4.3a: bms 4 → ≤ 81 candidates (correction 3's 9×9 box)")

	# Overshoot clamp: a cap overshoot clamps ALONG ITS OWN DIRECTION
	# (component floor), then sweeps (§4.3a).
	sim = _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("latin")],
		"weather": "calm", "wind_dir": "E",
	})
	sim.start()
	brig = _unit(sim, "player", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	brig["vel"] = Vector2i(3, 0)
	_face(brig, BattleLib.HEADING_EAST)
	_begin_turn(sim, "player", 0)
	_check(sim.apply_velocity(brig, Vector2i(4, 0)),
		"§4.3a: an overshooting pick is clamped, not rejected")
	_check((brig["vel"] as Vector2i) == Vector2i(3, 0),
		"§4.3a: the overshoot clamps along its own direction to cap 3 (%s)"
			% str(brig["vel"]))
	_check(sim.unit_cell(brig) == Vector2i(13, 15),
		"§4.3a: the clamped velocity sweeps 3 cells (%s)" % str(sim.unit_cell(brig)))
	_check(not sim.apply_velocity(brig, Vector2i(1, 0)),
		"§4.3a: movement happens exactly once per turn")

	# (0,0) pick keeps the last heading and holds position (§4.3a).
	oar_sim = _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("latin")],
	})
	oar_sim.start()
	var holder := _unit(oar_sim, "player", 0)
	holder["vel"] = Vector2i(0, -1)
	_face(holder, 2)   # heading north (bucket 2)
	_begin_turn(oar_sim, "player", 0)
	var before := oar_sim.unit_cell(holder)
	_check(oar_sim.apply_velocity(holder, Vector2i.ZERO),
		"§4.3a: a (0,0) pick is legal (the angle leg reads only a non-zero old vel)")
	_check(int(holder["heading8"]) == 2 and oar_sim.unit_cell(holder) == before,
		"§4.3a: vel (0,0) keeps the last heading and holds position (heading %d)"
			% int(holder["heading8"]))


func _as_vec2i_array(legal: Array) -> Array:
	var out: Array = []
	for vel in legal:
		out.append(vel)
	return out


# --- 3. cap_eff tiers (§4.3a, decision 2, corrections 1–3) ------------------

func _test_cap_eff() -> void:
	_person()
	# The wind_factor table per weather × class (20-* §4.7; oar 1.0 always).
	var wind_table := SailingSimLib.WIND_FACTORS
	_check(float(wind_table["calm"]["sail"]) == 0.8
			and float(wind_table["calm"]["oar"]) == 1.0
			and float(wind_table["calm"]["hybrid"]) == 1.0,
		"§4.3a: calm wind factors sail .8 / oar 1 / hybrid 1")
	_check(float(wind_table["fair"]["sail"]) == 1.0
			and float(wind_table["strong"]["sail"]) == 1.25
			and float(wind_table["storm"]["sail"]) == 1.5,
		"§4.3a: sail column fair 1 / strong 1.25 / storm 1.5")
	_check(float(wind_table["strong"]["hybrid"]) == 1.1
			and float(wind_table["storm"]["hybrid"]) == 1.2
			and float(wind_table["storm"]["oar"]) == 1.0,
		"§4.3a: hybrid strong 1.1 / storm 1.2; oar 1.0 in every weather")

	# Per weather × class over the direction identity (heading W = running:
	# sail 1.30, hybrid 1.10, oar 1.00 — the 20-* §4.4 180° row).
	var cases := [
		# [weather, ship, heading bucket, expected cap]
		["calm", "sloop", BattleLib.HEADING_EAST, 2],    # floor(3 × .8 × 1)
		["fair", "sloop", BattleLib.HEADING_EAST, 1],    # floor(3 × 1 × .5)
		["strong", "sloop", BattleLib.HEADING_EAST, 1],  # floor(3 × 1.25 × .5)
		["storm", "sloop", BattleLib.HEADING_EAST, 2],   # floor(3 × 1.5 × .5)
		["calm", "sloop", BattleLib.HEADING_WEST, 2],    # calm identity ×1.0
		["fair", "sloop", BattleLib.HEADING_WEST, 3],    # floor(3 × 1 × 1.3) = 3
		["strong", "sloop", BattleLib.HEADING_WEST, 3],  # floor(4.875) = 4 → clamp 3
		["storm", "sloop", BattleLib.HEADING_WEST, 3],   # floor(5.85)=5 → clamp 3
		["calm", "galley", BattleLib.HEADING_EAST, 4],   # oar 1.0 everywhere
		["storm", "galley", BattleLib.HEADING_EAST, 4],
		["calm", "galleon", BattleLib.HEADING_EAST, 3],  # calm identity: floor(3 × 1 × 1.0)
		["fair", "galleon", BattleLib.HEADING_EAST, 2],  # floor(3 × .85)
		["storm", "galleon", BattleLib.HEADING_EAST, 3], # floor(3 × 1.2 × .85)
		["storm", "galleon", BattleLib.HEADING_WEST, 3], # floor(3 × 1.2 × 1.1) → clamp 3
	]
	for case in cases:
		var sim := _sim({
			"player_ships": [_ship(str(case[1]))],
			"enemy_ships": [_ship("latin")],
			"weather": str(case[0]), "wind_dir": "E",
		})
		sim.start()
		var unit := _unit(sim, "player", 0)
		_face(unit, int(case[2]))
		_check(sim.cap_eff(unit) == int(case[3]),
			"§4.3a cap_eff: %s %s heading %d → %d (got %d)"
				% [str(case[0]), str(case[1]), int(case[2]), int(case[3]),
				sim.cap_eff(unit)])

	# The current ±1 pin (correction 1): bucket {0°,45°} ∧ strength ≥ 2 → +1;
	# bucket {135°,180°} ∧ strength 3 → −1; strength 0 never modifies.
	var current_cases := [
		# [current dir, strength, heading bucket, expected mod-bearing cap]
		["E", 2, BattleLib.HEADING_EAST, 3],    # bucket 0, +1 → clamp(2+1,0,3)
		["E", 3, BattleLib.HEADING_EAST, 3],    # bucket 0, +1 (clamp at bms)
		["E", 1, BattleLib.HEADING_EAST, 2],    # strength < 2 → no mod
		["E", 2, 1, 3],                          # bucket 45 (NE vs E), +1
		["E", 3, BattleLib.HEADING_WEST, 1],    # bucket 180, strength 3 → −1
		["E", 2, BattleLib.HEADING_WEST, 2],    # bucket 180, strength 2 → no mod
		["E", 3, 2, 2],                          # bucket 90 (N vs E) → no mod
		["E", 3, 3, 1],                          # bucket 135 (NW vs E), −1
		["E", 0, BattleLib.HEADING_EAST, 2],    # strength 0 never modifies
	]
	for case in current_cases:
		var sim := _sim({
			"player_ships": [_ship("sloop")],
			"enemy_ships": [_ship("latin")],
			"weather": "calm", "wind_dir": "E",
			"current": {"dir": str(case[0]), "strength": int(case[1])},
		})
		sim.start()
		var unit := _unit(sim, "player", 0)
		_face(unit, int(case[2]))
		_check(sim.cap_eff(unit) == int(case[3]),
			"§4.3a current: flow %s strength %d, heading bucket %d → cap %d (got %d)"
				% [str(case[0]), int(case[1]), int(case[2]), int(case[3]),
				sim.cap_eff(unit)])

	# Chain debuff −1 with floor 1 (§4.3a). (The doc's "cap of 0 without the
	# debuff" parenthetical — floor(2 × 0.8 × 0.5) — predates the normative
	# calm-identity sentence: with direction 1.0 in calm the shipped hull
	# table floors every non-debuff cap at 1, so no 0-cap fixture exists
	# without the debuff; recorded as a deviation in the W3-D report.)
	var floor_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("latin")],
		"weather": "fair", "wind_dir": "E",
	})
	floor_sim.start()
	var floored := _unit(floor_sim, "player", 0)
	_face(floored, BattleLib.HEADING_WEST)
	_check(floor_sim.cap_eff(floored) == 3, "§4.3a: the pre-debuff cap is 3")
	floored["speed_debuff_turns"] = 2
	_check(floor_sim.cap_eff(floored) == 2,
		"§4.3a: the chain debuff subtracts 1 (3 → %d)" % floor_sim.cap_eff(floored))
	var zero_sim := _sim({
		"player_ships": [_ship("latin")],
		"enemy_ships": [_ship("sloop")],
		"weather": "calm", "wind_dir": "E",
	})
	zero_sim.start()
	var zeroed := _unit(zero_sim, "player", 0)
	_face(zeroed, BattleLib.HEADING_EAST)
	zeroed["speed_debuff_turns"] = 2
	_check(zero_sim.cap_eff(zeroed) == 1,
		"§4.3a: the debuff floors at 1 — max(1, 0 − 1) = 1 (%d)"
			% zero_sim.cap_eff(zeroed))
	zeroed["speed_debuff_turns"] = 0
	_check(zero_sim.cap_eff(zeroed) == 1,
		"§4.3a: without the debuff the cap returns to the calm-identity floor "
			+ "floor(2 × 0.8) = 1 (%d)" % zero_sim.cap_eff(zeroed))

	# The sail delta applies AFTER the clamp and is not clamped back
	# (§4.3a correction 2 / §4.11.12).
	var sail_id := "eq_test_cap_sails"
	var existed := DataLoader.equipment.has(sail_id)
	var previous = DataLoader.equipment.get(sail_id, null)
	DataLoader.equipment[sail_id] = {
		"id": sail_id, "name": {"zh": "试作帆", "en": "Test Sails"},
		"slot": "sail", "modifiers": {"speed": 2}, "price": 1, "phase": 2,
	}
	var sail_sim := _sim({
		"player_ships": [_ship("latin", {"equipment": {"figurehead": "", "sail": sail_id}})],
		"enemy_ships": [_ship("sloop")],
		"weather": "calm", "wind_dir": "E",
	})
	sail_sim.start()
	var sailor := _unit(sail_sim, "player", 0)
	_face(sailor, BattleLib.HEADING_EAST)
	_check(sail_sim.cap_eff(sailor) == 3,
		"§4.3a/§4.11.12: the sail delta rides AFTER the clamp, unclamped back "
			+ "— 1 + 2 = 3 > battle_max_speed 2 (%d)" % sail_sim.cap_eff(sailor))
	if existed:
		DataLoader.equipment[sail_id] = previous
	else:
		DataLoader.equipment.erase(sail_id)
	_check(DataLoader.get_equipment(sail_id).is_empty(),
		"the injected sail double is removed again")


# --- 4. heading8 bucketing (§4.3a, decision 1) ------------------------------

func _test_heading8() -> void:
	# The eight compass rays at integer dot/cross — never atan2 (decision 1).
	var compass := [
		[Vector2i(1, 0), 0], [Vector2i(1, -1), 1], [Vector2i(0, -1), 2],
		[Vector2i(-1, -1), 3], [Vector2i(-1, 0), 4], [Vector2i(-1, 1), 5],
		[Vector2i(0, 1), 6], [Vector2i(1, 1), 7],
	]
	var all_rays := true
	for entry in compass:
		if BattleLib.heading8_of(entry[0]) != int(entry[1]):
			all_rays = false
	_check(all_rays,
		"§4.3a: heading8 buckets the 8 compass rays exactly (E,NE,N,NW,W,SW,S,SE)")
	_check(BattleLib.heading8_of(Vector2i(29, -12)) == 0,
		"§4.3a: the 22.5° boundary — (29,−12) slope .4138 < tan 22.5° stays E")
	_check(BattleLib.heading8_of(Vector2i(12, -5)) == 1,
		"§4.3a: (12,−5) slope .4167 > tan 22.5° tips into NE (no integer tie)")
	_check(BattleLib.heading8_of(Vector2i(-29, 12)) == 4,
		"§4.3a: the boundary is symmetric ((−29,12) buckets W)")
	_check(BattleLib.bucket_distance(0, 1) == 1 and BattleLib.bucket_distance(0, 4) == 4
			and BattleLib.bucket_distance(1, 7) == 2 and BattleLib.bucket_distance(3, 7) == 4,
		"§4.3a: bucket_distance is the 45°-step shortest arc (0..4)")
	_check(BattleLib.HEADING_TOKENS[BattleLib.heading8_of(Vector2i(1, 0))] == "E",
		"§4.3a: the HEADING_TOKENS bridge reads the 20-* §4.4 id set")
	_check(BattleLib.heading8_of(Vector2i.ZERO) == BattleLib.HEADING_EAST,
		"§4.3a: the static (0,0) default is east; the CALLER keeps the last heading")


# --- 5. Broadside arcs (§4.4) ----------------------------------------------

func _test_arcs() -> void:
	_person()
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop")],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var enemy := _unit(sim, "enemy", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	_face(brig, BattleLib.HEADING_EAST)
	_check(BattleLib.ARC_PORT_STEPS == [1, 2, 3]
			and BattleLib.ARC_STARBOARD_STEPS == [5, 6, 7],
		"§4.4: the arcs are buckets {45°,90°,135°} port / {225°,270°,315°} starboard")

	# port = floor(n/2), starboard the rest; the ship's TOTAL is retained
	# for the outcome blocks (decision 3 / decision 14).
	_check(sim.side_cannons(brig, "port") == 5
			and sim.side_cannons(brig, "starboard") == 5,
		"§4.4: 10 cannons split 5/5 (port = floor(n/2))")
	_check(int(brig["ship"]["cannons"]) == 10,
		"§4.4 decision 14: the ship's total cannon count is retained (%d)"
			% int(brig["ship"]["cannons"]))
	var odd_sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 7})],
		"enemy_ships": [_ship("sloop")],
	})
	odd_sim.start()
	var odd := _unit(odd_sim, "player", 0)
	_check(odd_sim.side_cannons(odd, "port") == 3
			and odd_sim.side_cannons(odd, "starboard") == 4,
		"§4.4: 7 cannons split 3/4 — floor(7/2) port, the rest starboard")

	# The arc membership, relative to the ATTACKER's heading8 (east).
	_place(sim, "enemy", 0, Vector2i(11, 14))   # bearing NE → bucket 45°
	_check(sim.can_cannon(brig, enemy, "port")
			and not sim.can_cannon(brig, enemy, "starboard"),
		"§4.4: a NE bearing is in the PORT arc only")
	_place(sim, "enemy", 0, Vector2i(11, 16))   # bearing SE → bucket 315°
	_check(sim.can_cannon(brig, enemy, "starboard")
			and not sim.can_cannon(brig, enemy, "port"),
		"§4.4: a SE bearing is in the STARBOARD arc only")
	_place(sim, "enemy", 0, Vector2i(12, 13))   # bearing NNE → bucket 45°, range 2
	_check(sim.can_cannon(brig, enemy, "port"),
		"§4.4: the 45° arc reaches across Chebyshev range 2")
	_place(sim, "enemy", 0, Vector2i(13, 17))   # bucket 315°, range 3
	_check(sim.can_cannon(brig, enemy, "starboard"),
		"§4.4: the 315° arc reaches across Chebyshev range 3")
	_place(sim, "enemy", 0, Vector2i(13, 15))   # dead ahead → bucket 0°
	_check(not sim.can_cannon(brig, enemy, "port")
			and not sim.can_cannon(brig, enemy, "starboard"),
		"§4.4: a dead-ahead target sits in NEITHER arc")
	_place(sim, "enemy", 0, Vector2i(8, 15))    # dead astern → bucket 180°
	_check(not sim.can_cannon(brig, enemy, "port")
			and not sim.can_cannon(brig, enemy, "starboard"),
		"§4.4: a dead-astern target sits in NEITHER arc")
	_place(sim, "enemy", 0, Vector2i(14, 18))   # range 4
	_check(not sim.can_cannon(brig, enemy, "starboard"),
		"§4.4: Chebyshev range 4 is out of range (1..3 only)")
	# side "" (the compat read) asks whether EITHER side can.
	_place(sim, "enemy", 0, Vector2i(11, 16))
	_check(sim.can_cannon(brig, enemy),
		"§4.4: an unnamed side asks whether either broadside bears")


# --- 6. Reload (§4.4a, decision 5; §4.11.4 per-side pin) --------------------

func _test_reload() -> void:
	# Gunnery 0 / 50 / 100 → reload 3 / 2 / 1 (clamp(3 − floor(g/50), 1, 3)).
	for gunnery in [[0, 3], [50, 2], [100, 1], [49, 3]]:
		_person(0, int(gunnery[0]))
		var sim := _sim({
			"player_ships": [_ship("brigantine", {"cannons": 10})],
			"enemy_ships": [_ship("sloop")],
		})
		sim.start()
		var brig := _unit(sim, "player", 0)
		_check(sim.reload_turns_of(brig) == int(gunnery[1]),
			"§4.4a: gunnery %d → reload %d turns (got %d)"
				% [int(gunnery[0]), int(gunnery[1]), sim.reload_turns_of(brig)])

	# Low crew +1: crew_ratio = crew / crew_min < 0.5.
	_person(0, 0)
	var low_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 4, "cannons": 4})],
		"enemy_ships": [_ship("latin")],
	})
	low_sim.start()
	var short := _unit(low_sim, "player", 0)
	_check(low_sim.reload_turns_of(short) == 4,
		"§4.4a: crew 4/10 (ratio 0.4 < 0.5) adds +1 → 4 turns (%d)"
			% low_sim.reload_turns_of(short))
	var half_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 5, "cannons": 4})],
		"enemy_ships": [_ship("latin")],
	})
	half_sim.start()
	_check(half_sim.reload_turns_of(_unit(half_sim, "player", 0)) == 3,
		"§4.4a: ratio exactly 0.5 is not low crew → 3 turns (%d)"
			% half_sim.reload_turns_of(_unit(half_sim, "player", 0)))

	# The legacy fallback family prices the gunnery source: 10 + 10 × tier
	# (§4.4a gunnery source; correction 6's fallback family).
	var legacy_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("sloop")],
	})
	legacy_sim.start()
	_check(int(_unit(legacy_sim, "enemy", 0)["gunnery"]) == 20,
		"§4.4a: a card-less pirate fleet's gunnery source is 10 + 10 × tier 1 = 20 (%d)"
			% int(_unit(legacy_sim, "enemy", 0)["gunnery"]))
	var navy_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("sloop")],
		"enemy_kind": "navy", "enemy_nation": "spain",
	})
	navy_sim.start()
	_check(int(_unit(navy_sim, "enemy", 0)["gunnery"]) == 30,
		"§4.4a: a navy fleet's legacy gunnery source is 10 + 10 × tier 2 = 30 (%d)"
			% int(_unit(navy_sim, "enemy", 0)["gunnery"]))
	var tour_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("brigantine")],
		"enemy_kind": "tournament",
	})
	tour_sim.start()
	_check(int(_unit(tour_sim, "enemy", 0)["gunnery"]) == 30,
		"§4.11.7.1: the tournament tier 2 prices the same 30 gunnery source (%d)"
			% int(_unit(tour_sim, "enemy", 0)["gunnery"]))
	var escort_sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("sloop")],
		"enemy_ships": [_ship("latin")],
	})
	escort_sim.start()
	_check(int(_unit(escort_sim, "player", 1)["gunnery"]) == 0,
		"§4.4a: a captain-less player escort's gunnery source is 0")

	# Per-side independence: firing port does not touch starboard, and
	# `reload_side = round + reload_turns` exactly (§4.4a / §4.11.4).
	_person(0, 0)
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"durability": 200}), _ship("sloop", {"durability": 200})],
	})
	sim.start()
	var gunner := _unit(sim, "player", 0)
	var port_target := _unit(sim, "enemy", 0)
	var star_target := _unit(sim, "enemy", 1)
	_place(sim, "player", 0, Vector2i(10, 15))
	_place(sim, "enemy", 0, Vector2i(11, 14))   # NE → port arc
	_place(sim, "enemy", 1, Vector2i(11, 16))   # SE → starboard arc
	_begin_turn(sim, "player", 0)
	var volley := sim.cannon(gunner, port_target, "port")
	_check(bool(volley["ok"]) and str(volley["side"]) == "port",
		"§4.4a: the named-side volley resolves")
	_check(int(gunner["reload_port"]) == 4 and int(gunner["reload_starboard"]) == 1,
		"§4.4a: reload_port = round 1 + 3 turns = 4; starboard untouched (%d/%d)"
			% [int(gunner["reload_port"]), int(gunner["reload_starboard"])])
	sim.end_turn()   # spend the brig's fired turn
	_begin_turn(sim, "player", 0)   # walk the two enemy slots into round 2
	_check(sim.round_number() == 2, "§4.4a: the fixture reaches round 2")
	_check(not sim.can_cannon(gunner, port_target, "port"),
		"§4.4a: round 2 < reload_port 4 — the port side cannot fire")
	_check(sim.can_cannon(gunner, star_target, "starboard"),
		"§4.4a: the starboard side reloaded independently (round 2 ≥ 1)")
	var star_volley := sim.cannon(gunner, star_target, "starboard")
	_check(bool(star_volley["ok"]),
		"§4.4a: the independent starboard volley fires")
	_check(int(gunner["reload_port"]) == 4 and int(gunner["reload_starboard"]) == 5,
		"§4.4a: reload_starboard = round 2 + 3 = 5 while port stays 4 (%d/%d)"
			% [int(gunner["reload_port"]), int(gunner["reload_starboard"])])


# --- 7. Crew casualties (§4.11.5, correction 7) -----------------------------

func _test_casualties() -> void:
	_person(0, 0)
	# Standard volley: crew −= floor(damage / 20). Galleon port 12 cannons,
	# range 1 → damage 24 → kill 1.
	var sim := _sim({
		"player_ships": [_ship("galleon", {"cannons": 24})],
		"enemy_ships": [_ship("sloop", {"crew": 45})],
	})
	sim.start()
	var gunner := _unit(sim, "player", 0)
	var victim := _unit(sim, "enemy", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	_place(sim, "enemy", 0, Vector2i(11, 14))
	_begin_turn(sim, "player", 0)
	var volley := sim.cannon(gunner, victim, "port")
	_check(int(volley["damage"]) == 24 and int(volley["crew_kill"]) == 1,
		"§4.11.5: standard volley 24 damage → floor(24/20) = 1 crew (%d)"
			% int(volley["crew_kill"]))
	_check(int(victim["crew"]) == 44, "§4.11.5: the crew drops 45 → %d"
		% int(victim["crew"]))

	# Rake volley: crew −= floor(damage / 10). The target heads NE so the
	# bearing target→attacker runs its deck line (§4.4 rake).
	var rake_sim := _sim({
		"player_ships": [_ship("galleon", {"cannons": 24})],
		"enemy_ships": [_ship("sloop", {"crew": 45})],
	})
	rake_sim.start()
	var rake_gunner := _unit(rake_sim, "player", 0)
	var raked := _unit(rake_sim, "enemy", 0)
	_place(rake_sim, "player", 0, Vector2i(10, 15))
	_place(rake_sim, "enemy", 0, Vector2i(11, 14))
	_face(raked, 1)   # heading NE: the attacker bears SW = 180° off the bow
	_begin_turn(rake_sim, "player", 0)
	var rake_volley := rake_sim.cannon(rake_gunner, raked, "port")
	_check(bool(rake_volley["rake"]),
		"§4.4: the bearing-vs-target-heading bucket 180° is a rake volley")
	_check(int(rake_volley["damage"]) == 30,
		"§4.11.5: the raked volley floors once — floor(24 × 1.25) = 30 (%d)"
			% int(rake_volley["damage"]))
	_check(int(rake_volley["crew_kill"]) == 3,
		"§4.11.5: a rake volley's crew term is floor(damage / 10) = 3 (%d)"
			% int(rake_volley["crew_kill"]))

	# Clamp at 0: crew can reach 0 and stays there — a 0-crew ship still
	# sails (correction 7).
	var clamp_sim := _sim({
		"player_ships": [_ship("galleon", {"cannons": 24})],
		"enemy_ships": [_ship("sloop", {"crew": 1})],
	})
	clamp_sim.start()
	var clamped := _unit(clamp_sim, "enemy", 0)
	_place(clamp_sim, "player", 0, Vector2i(10, 15))
	_place(clamp_sim, "enemy", 0, Vector2i(11, 14))
	_begin_turn(clamp_sim, "player", 0)
	var wipe := clamp_sim.cannon(_unit(clamp_sim, "player", 0), clamped, "port")
	_check(int(clamped["crew"]) == 0,
		"§4.6a correction 7: crew clamps at 0 (%d)" % int(clamped["crew"]))
	_check(bool(clamped["alive"]),
		"§4.6a: a 0-crew ship still sails (not sunk, not removed)")
	_begin_turn(clamp_sim, "enemy", 0)
	_check(bool(clamp_sim.hold(clamped)["ok"]),
		"§4.6a: the 0-crew ship still takes its turn (its penalties are only "
			+ "the reload +1 and the weakened duel term)")


# --- 8. Grape (§4.4b) -------------------------------------------------------

func _test_grape() -> void:
	_person(0, 0)   # gunnery 0 — grape has NO gate
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"crew": 10})],
	})
	sim.start()
	var gunner := _unit(sim, "player", 0)
	var target := _unit(sim, "enemy", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	_place(sim, "enemy", 0, Vector2i(11, 14))   # port arc, range 1
	_begin_turn(sim, "player", 0)
	var grape := sim.cannon(gunner, target, "port", BattleLib.GRAPE_SHOT)
	_check(bool(grape["ok"]) and str(grape["shot"]) == BattleLib.GRAPE_SHOT,
		"§4.4b: grape fires at gunnery 0 — no gate")
	_check(int(grape["damage"]) == 5,
		"§4.4b: grape hull = floor(same-range round 10 × 0.5) = 5 (%d)"
			% int(grape["damage"]))
	_check(int(grape["crew_kill"]) == 5,
		"§4.4b: the grape crew kill equals the hull halving (%d)"
			% int(grape["crew_kill"]))
	_check(int(target["ship"]["durability"]) == 55 and int(target["crew"]) == 5,
		"§4.4b: the volley applies hull 5 and crew 5 (%d dur / %d crew)"
			% [int(target["ship"]["durability"]), int(target["crew"])])
	_check(int(gunner["reload_port"]) == 4,
		"§4.4a: the grape volley reloads its side like any other (%d)"
			% int(gunner["reload_port"]))

	# Rake grape: the halving reads the same-range ROUND damage including
	# rake (galleon port 12 raked → round 30 → 15/15).
	var rake_sim := _sim({
		"player_ships": [_ship("galleon", {"cannons": 24})],
		"enemy_ships": [_ship("sloop", {"crew": 45})],
	})
	rake_sim.start()
	var rake_gunner := _unit(rake_sim, "player", 0)
	var raked := _unit(rake_sim, "enemy", 0)
	_place(rake_sim, "player", 0, Vector2i(10, 15))
	_place(rake_sim, "enemy", 0, Vector2i(11, 14))
	_face(raked, 1)
	_begin_turn(rake_sim, "player", 0)
	var rake_grape := rake_sim.cannon(rake_gunner, raked, "port", BattleLib.GRAPE_SHOT)
	_check(int(rake_grape["damage"]) == 15 and int(rake_grape["crew_kill"]) == 15,
		"§4.4b: a raked grape halves the raked round — 30 → 15 hull / 15 crew (%d/%d)"
			% [int(rake_grape["damage"]), int(rake_grape["crew_kill"])])

	# Range 1 ONLY: beyond it the volley is refused, spends no turn, sets no
	# reload — the round volley still fires in the same turn.
	var far_sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"durability": 60})],
	})
	far_sim.start()
	var far_gunner := _unit(far_sim, "player", 0)
	var far_target := _unit(far_sim, "enemy", 0)
	_place(far_sim, "player", 0, Vector2i(10, 15))
	_place(far_sim, "enemy", 0, Vector2i(12, 13))   # port arc, Chebyshev 2
	_begin_turn(far_sim, "player", 0)
	var refused: Dictionary = far_sim.cannon(far_gunner, far_target, "port",
		BattleLib.GRAPE_SHOT)
	_check(not bool(refused["ok"]) and int(refused.get("range", -1)) == 2,
		"§4.4b: grape beyond range 1 is refused with the range reason (%s)"
			% str(refused))
	_check(int(far_target["ship"]["durability"]) == 60
			and int(far_gunner["reload_port"]) == 1,
		"§4.4b: the refused grape deals no damage and sets no reload")
	var round_after := far_sim.cannon(far_gunner, far_target, "port")
	_check(bool(round_after["ok"]),
		"§4.4b: the refused grape spent no turn — the round volley fires (§4.4b "
			+ "'not a lock, a range gate')")


# --- 9. The §4.4b shot rule situations --------------------------------------

func _test_ai_shot_rule() -> void:
	_person()
	# ① chain: target ⌊vel⌋ ≥ 2 pulling away, attacker gunnery ≥ 25.
	var chain_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20})],
		"enemy_ships": [_ship("sloop", {"gunnery": 25, "cannons": 4})],
	})
	chain_sim.start()
	var chain_gunner := _unit(chain_sim, "enemy", 0)
	var fleeing := _unit(chain_sim, "player", 0)
	_place(chain_sim, "enemy", 0, Vector2i(10, 15))
	_place(chain_sim, "player", 0, Vector2i(13, 15))
	fleeing["vel"] = Vector2i(2, 0)
	_check(chain_sim.ai_shot_type(chain_gunner, fleeing) == BattleLib.CHAIN_SHOT,
		"§4.4b rule 1: a ⌊vel⌋ ≥ 2 target pulling away draws chain shot (%s)"
			% chain_sim.ai_shot_type(chain_gunner, fleeing))
	# Below the gate the same situation falls through to round.
	var low_gunner_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20})],
		"enemy_ships": [_ship("sloop", {"gunnery": 24, "cannons": 4})],
	})
	low_gunner_sim.start()
	var low_gunner := _unit(low_gunner_sim, "enemy", 0)
	var still_fleeing := _unit(low_gunner_sim, "player", 0)
	_place(low_gunner_sim, "enemy", 0, Vector2i(10, 15))
	_place(low_gunner_sim, "player", 0, Vector2i(13, 15))
	still_fleeing["vel"] = Vector2i(2, 0)
	_check(low_gunner_sim.ai_shot_type(low_gunner, still_fleeing) == BattleLib.ROUND_SHOT,
		"§4.4b: gunnery 24 < the 25 gate falls through to round (%s)"
			% low_gunner_sim.ai_shot_type(low_gunner, still_fleeing))

	# ② grape: hook window (Chebyshev ≤ 2) + the crew-strength edge.
	var grape_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20})],
		"enemy_ships": [_ship("sloop", {"crew": 40, "cannons": 4})],
	})
	grape_sim.start()
	var grape_gunner := _unit(grape_sim, "enemy", 0)
	var weak := _unit(grape_sim, "player", 0)
	_place(grape_sim, "enemy", 0, Vector2i(10, 15))
	_place(grape_sim, "player", 0, Vector2i(11, 14))
	_check(grape_sim.ai_shot_type(grape_gunner, weak) == BattleLib.GRAPE_SHOT,
		"§4.4b rule 2: crew 40 + 6 > 20 + 0 at range 1 → grape (%s)"
			% grape_sim.ai_shot_type(grape_gunner, weak))

	# ③ armor-piercing: a player-side target with a non-empty armor slot.
	var ap_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20,
			"equipment": {"figurehead": "", "sail": ""}})],
		"enemy_ships": [_ship("sloop", {"gunnery": 50, "cannons": 4, "crew": 10})],
	})
	ap_sim.start()
	var ap_gunner := _unit(ap_sim, "enemy", 0)
	var plated := _unit(ap_sim, "player", 0)
	(aplated_equipment(plated))["armor"] = "eq_test_plate"
	_place(ap_sim, "enemy", 0, Vector2i(10, 15))
	_place(ap_sim, "player", 0, Vector2i(12, 14))   # Chebyshev 2, outside grape
	_check(ap_sim.ai_shot_type(ap_gunner, plated) == BattleLib.ARMOR_PIERCING_SHOT,
		"§4.4b rule 3: a plated player target at gunnery ≥ 50 draws armor-piercing (%s)"
			% ap_sim.ai_shot_type(ap_gunner, plated))
	# The AP gate: gunnery 49 falls to round.
	var ap_low_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20,
			"equipment": {"figurehead": "", "sail": ""}})],
		"enemy_ships": [_ship("sloop", {"gunnery": 49, "cannons": 4, "crew": 10})],
	})
	ap_low_sim.start()
	var ap_low_gunner := _unit(ap_low_sim, "enemy", 0)
	var plated_low := _unit(ap_low_sim, "player", 0)
	(aplated_equipment(plated_low))["armor"] = "eq_test_plate"
	_place(ap_low_sim, "enemy", 0, Vector2i(10, 15))
	_place(ap_low_sim, "player", 0, Vector2i(12, 14))
	_check(ap_low_sim.ai_shot_type(ap_low_gunner, plated_low) == BattleLib.ROUND_SHOT,
		"§4.4b: gunnery 49 < the 50 gate falls to round (%s)"
			% ap_low_sim.ai_shot_type(ap_low_gunner, plated_low))

	# ④ round: the default fall-through.
	var round_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20})],
		"enemy_ships": [_ship("sloop", {"crew": 10, "cannons": 4})],
	})
	round_sim.start()
	var round_gunner := _unit(round_sim, "enemy", 0)
	var calm_target := _unit(round_sim, "player", 0)
	_place(round_sim, "enemy", 0, Vector2i(10, 15))
	_place(round_sim, "player", 0, Vector2i(14, 15))
	calm_target["vel"] = Vector2i(1, 0)
	_check(round_sim.ai_shot_type(round_gunner, calm_target) == BattleLib.ROUND_SHOT,
		"§4.4b rule 4: no chain, no grape window, no plate → round (%s)"
			% round_sim.ai_shot_type(round_gunner, calm_target))

	# The rule evaluates IN ORDER: chain beats grape in the window.
	var both_sim := _sim({
		"player_ships": [_ship("sloop", {"crew": 20})],
		"enemy_ships": [_ship("sloop", {"gunnery": 25, "crew": 40, "cannons": 4})],
	})
	both_sim.start()
	var both_gunner := _unit(both_sim, "enemy", 0)
	var fleeing_close := _unit(both_sim, "player", 0)
	_place(both_sim, "enemy", 0, Vector2i(10, 15))
	_place(both_sim, "player", 0, Vector2i(11, 14))
	fleeing_close["vel"] = Vector2i(2, 0)
	_check(both_sim.ai_shot_type(both_gunner, fleeing_close) == BattleLib.CHAIN_SHOT,
		"§4.4b: the rule is evaluated in order — chain beats the grape window (%s)"
			% both_sim.ai_shot_type(both_gunner, fleeing_close))


## The equipment dict of a unit's ship (the §4.4b rule-3 read).
func aplated_equipment(unit: Dictionary) -> Dictionary:
	return unit["ship"]["equipment"]


# --- 10. The damage stack (§4.4, §4.11.5) -----------------------------------

func _test_damage_stack() -> void:
	# Range factors 1.0 / 0.75 / 0.5 (§4.4) — brigantine port 5, bonus 0.
	_person(0, 0)
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop")],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var enemy := _unit(sim, "enemy", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	_place(sim, "enemy", 0, Vector2i(11, 14))
	_check(sim.cannon_damage(brig, enemy, "port") == 10,
		"§4.4: range 1 → floor(5 × 2 × 1.0) = 10 (%d)"
			% sim.cannon_damage(brig, enemy, "port"))
	_place(sim, "enemy", 0, Vector2i(12, 13))
	_check(sim.cannon_damage(brig, enemy, "port") == 7,
		"§4.4: range 2 → floor(5 × 2 × 0.75) = 7 (%d)"
			% sim.cannon_damage(brig, enemy, "port"))
	_place(sim, "enemy", 0, Vector2i(13, 12))
	_check(sim.cannon_damage(brig, enemy, "port") == 5,
		"§4.4: range 3 → floor(5 × 2 × 0.5) = 5 (%d)"
			% sim.cannon_damage(brig, enemy, "port"))

	# The gunnery bonus rides INSIDE the floored base (+1 at gunnery 30).
	_person(0, 30)
	var bonus_sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop")],
	})
	bonus_sim.start()
	var bonus_brig := _unit(bonus_sim, "player", 0)
	var bonus_target := _unit(bonus_sim, "enemy", 0)
	_place(bonus_sim, "player", 0, Vector2i(10, 15))
	_place(bonus_sim, "enemy", 0, Vector2i(11, 14))
	_check(bonus_sim.cannon_bonus(bonus_brig) == 1
			and bonus_sim.cannon_damage(bonus_brig, bonus_target, "port") == 11,
		"§4.4: +floor(effective gunnery 30 / 25) = +1 rides inside the base (11)")

	# Weather × rake × shot multiply with ONE floor after the weather term.
	var weather_cases := [
		# [weather, rake, shot, expected from base 10]
		["calm", false, BattleLib.ROUND_SHOT, 10],
		["storm", false, BattleLib.ROUND_SHOT, 7],    # floor(10 × 0.75)
		["strong", false, BattleLib.ROUND_SHOT, 9],   # floor(10 × 0.9)
		["calm", true, BattleLib.ROUND_SHOT, 12],     # floor(10 × 1.25)
		["storm", true, BattleLib.ROUND_SHOT, 9],     # floor(10 × .75 × 1.25) = 9
		["strong", true, BattleLib.ROUND_SHOT, 11],   # floor(10 × .9 × 1.25) = 11
		# gunnery 25 → bonus +1 rides INSIDE the base (11), then one floor:
		["calm", false, BattleLib.CHAIN_SHOT, 8],     # floor(11 × 0.75)
		# gunnery 50 → bonus +2 (base 12):
		["calm", false, BattleLib.ARMOR_PIERCING_SHOT, 15],  # floor(12 × 1.25)
	]
	for case in weather_cases:
		_person(0, 25 if str(case[2]) == BattleLib.CHAIN_SHOT
			else (50 if str(case[2]) == BattleLib.ARMOR_PIERCING_SHOT else 0))
		var w_sim := _sim({
			"player_ships": [_ship("brigantine", {"cannons": 10})],
			"enemy_ships": [_ship("sloop")],
			"weather": str(case[0]),
		})
		w_sim.start()
		var w_gunner := _unit(w_sim, "player", 0)
		var w_target := _unit(w_sim, "enemy", 0)
		_place(w_sim, "player", 0, Vector2i(10, 15))
		_place(w_sim, "enemy", 0, Vector2i(11, 14))
		if bool(case[1]):
			_face(w_target, 1)   # raked: the attacker bears 180° off the bow
		_begin_turn(w_sim, "player", 0)
		var w_volley: Dictionary = w_sim.cannon(w_gunner, w_target, "port", str(case[2]))
		_check(int(w_volley["damage"]) == int(case[3]),
			"§4.4/§4.11.5 one-floor stack: %s rake %s shot %s → %d (got %d)"
				% [str(case[0]), str(case[1]), str(case[2]), int(case[3]),
				int(w_volley["damage"])])
	_person(0, 0)


# --- 11. The sweep & ram (§4.3a, §4.5, §4.11.5) -----------------------------

func _test_sweep_ram() -> void:
	_person()
	# Sweep ram: entering an enemy-occupied cell with ⌊vel⌋ ≥ 1. Bow/stern
	# approach (the bearing runs the target's deck line) ×1.15.
	var sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	sim.start()
	var rammer := _unit(sim, "player", 0)
	var target := _unit(sim, "enemy", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	_place(sim, "enemy", 0, Vector2i(11, 15))
	_face(target, BattleLib.HEADING_EAST)   # approached along its deck line
	rammer["vel"] = Vector2i(1, 0)
	_begin_turn(sim, "player", 0)
	_check(sim.apply_velocity(rammer, Vector2i(1, 0)),
		"§4.3a: the sweep enters the enemy cell and rams")
	_check(sim.unit_cell(rammer) == Vector2i(10, 15),
		"§4.3a: the rammer stops at the PRIOR cell (no cell entry)")
	_check(int(target["ship"]["durability"]) == 60 - 31,
		"§4.5: bow/stern ×1.15 at speed 1 — floor(110 × 0.25 × 1.15) = 31 (%d)"
			% (60 - int(target["ship"]["durability"])))
	_check(int(rammer["ship"]["durability"]) == 110 - 12,
		"§4.5: the rammer pays floor(110 × 0.10 × 1.15) = 12 (%d)"
			% (110 - int(rammer["ship"]["durability"])))
	_check((rammer["vel"] as Vector2i) == Vector2i(1, 0),
		"§4.3a: the committed velocity is the unit's state even when blocked")

	# Beam approach (the bearing ⊥ the target's heading): no ×1.15.
	var beam_sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	beam_sim.start()
	var beam_attacker := _unit(beam_sim, "player", 0)
	var beam_target := _unit(beam_sim, "enemy", 0)
	_place(beam_sim, "player", 0, Vector2i(11, 14))
	_place(beam_sim, "enemy", 0, Vector2i(11, 15))
	_face(beam_target, BattleLib.HEADING_EAST)   # approached from the south
	beam_attacker["vel"] = Vector2i(0, 1)
	_face(beam_attacker, 6)   # heading S (y grows southward): the turn leg reads heading8
	_begin_turn(beam_sim, "player", 0)
	beam_sim.apply_velocity(beam_attacker, Vector2i(0, 1))
	_check(int(beam_target["ship"]["durability"]) == 60 - 27,
		"§4.5: a beam approach at speed 1 keeps mult 1 — floor(110 × 0.25) = 27 (%d)"
			% (60 - int(beam_target["ship"]["durability"])))
	_check(int(beam_attacker["ship"]["durability"]) == 110 - 11,
		"§4.5: the beam rammer pays floor(110 × 0.10) = 11 (%d)"
			% (110 - int(beam_attacker["ship"]["durability"])))

	# Speed builds impact: ×(1 + 0.25 × (⌊vel⌋ − 1)) with the bow/stern bonus.
	var fast_sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	fast_sim.start()
	var fast := _unit(fast_sim, "player", 0)
	var fast_target := _unit(fast_sim, "enemy", 0)
	_place(fast_sim, "player", 0, Vector2i(10, 15))
	_place(fast_sim, "enemy", 0, Vector2i(11, 15))
	_face(fast_target, BattleLib.HEADING_EAST)
	fast["vel"] = Vector2i(2, 0)
	_begin_turn(fast_sim, "player", 0)
	fast_sim.apply_velocity(fast, Vector2i(2, 0))
	_check(int(fast_target["ship"]["durability"]) == 60 - 39,
		"§4.5: speed 2 + bow/stern — floor(110 × 0.25 × 1.4375) = 39 (%d)"
			% (60 - int(fast_target["ship"]["durability"])))
	_check(int(fast["ship"]["durability"]) == 110 - 15,
		"§4.5: …and self damage floor(110 × 0.10 × 1.4375) = 15 (%d)"
			% (110 - int(fast["ship"]["durability"])))

	# The galley identity rule: an oar attacker multiplies ×1.25 (§4.5).
	var oar_sim := _sim({
		"player_ships": [_ship("galley")],
		"enemy_ships": [_ship("sloop")],
	})
	oar_sim.start()
	var oar := _unit(oar_sim, "player", 0)
	var oar_target := _unit(oar_sim, "enemy", 0)
	_place(oar_sim, "player", 0, Vector2i(11, 14))
	_place(oar_sim, "enemy", 0, Vector2i(11, 15))
	_face(oar_target, BattleLib.HEADING_EAST)
	oar["vel"] = Vector2i(0, 1)
	_face(oar, 6)   # heading S: the turn leg reads heading8
	_begin_turn(oar_sim, "player", 0)
	oar_sim.apply_velocity(oar, Vector2i(0, 1))
	_check(int(oar_target["ship"]["durability"]) == 60 - 21,
		"§4.5: the oar ×1.25 folds into the same floor — floor(70 × 0.25 × 1.25) = 21 (%d)"
			% (60 - int(oar_target["ship"]["durability"])))
	_check(int(oar["ship"]["durability"]) == 70 - 8,
		"§4.5: the oar rammer pays floor(70 × 0.10 × 1.25) = 8 (%d)"
			% (70 - int(oar["ship"]["durability"])))

	# Friendly-occupied stop: prior cell, ZERO damage, no ram log.
	var friendly_sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("sloop")],
		"enemy_ships": [_ship("latin")],
	})
	friendly_sim.start()
	var mover := _unit(friendly_sim, "player", 0)
	var friend := _unit(friendly_sim, "player", 1)
	_place(friendly_sim, "player", 0, Vector2i(10, 15))
	_place(friendly_sim, "player", 1, Vector2i(11, 15))
	var friend_durability := int(friend["ship"]["durability"])
	mover["vel"] = Vector2i(2, 0)
	_begin_turn(friendly_sim, "player", 0)
	friendly_sim.apply_velocity(mover, Vector2i(2, 0))
	_check(friendly_sim.unit_cell(mover) == Vector2i(10, 15),
		"§4.3a: a friend-occupied first cell stops the ship at the prior cell")
	_check(int(friend["ship"]["durability"]) == friend_durability,
		"§4.3a: a friendly stop deals zero damage")
	var ram_logs := 0
	for entry in friendly_sim.log_lines():
		if entry is Dictionary and str(entry.get("kind", "")) == "ram":
			ram_logs += 1
	_check(ram_logs == 0, "§4.3a: a friendly stop logs no ram")

	# Out-of-bounds stop: prior cell, no partial entry.
	var edge_sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("latin")],
	})
	edge_sim.start()
	var edge := _unit(edge_sim, "player", 0)
	_place(edge_sim, "player", 0, Vector2i(47, 15))
	edge["vel"] = Vector2i(2, 0)
	_begin_turn(edge_sim, "player", 0)
	edge_sim.apply_velocity(edge, Vector2i(2, 0))
	_check(edge_sim.unit_cell(edge) == Vector2i(47, 15),
		"§4.3a: an out-of-bounds first cell stops the ship at the prior cell "
			+ "(no partial entry past the 48-wide grid)")

	# Both-sink: the attacker resolves LAST (§4.11.5 / §6) — the enemy is
	# sunk first, so the same ram cannot report a player victory.
	var both_sim := _sim({
		"player_ships": [_ship("brigantine", {"durability": 5})],
		"enemy_ships": [_ship("sloop", {"durability": 5})],
	})
	both_sim.start()
	var doomed := _unit(both_sim, "player", 0)
	var other := _unit(both_sim, "enemy", 0)
	_place(both_sim, "player", 0, Vector2i(10, 15))
	_place(both_sim, "enemy", 0, Vector2i(11, 15))
	_face(other, BattleLib.HEADING_EAST)
	doomed["vel"] = Vector2i(1, 0)
	_begin_turn(both_sim, "player", 0)
	both_sim.apply_velocity(doomed, Vector2i(1, 0))
	_check(not bool(doomed["alive"]) and not bool(other["alive"]),
		"§4.5: a ram can sink both ships")
	both_sim.end_turn()   # §4.3: the over-check lands when the turn ends
	_check(both_sim.is_over()
			and str(both_sim.outcome()["result"]) == "defeat_sunk",
		"§4.11.5: the attacker resolves LAST — both sunk reads defeat_sunk, "
			+ "never victory (%s)" % str(both_sim.outcome()["result"]))


# --- 12. Hook & board (§4.6a, decision 8, correction 7) ---------------------

func _test_hook() -> void:
	_person(12)
	# Orthogonal + both ⌊vel⌋ ≤ 1 + weather ≠ storm → the hook zeroes BOTH
	# velocities, then the duel runs (§4.6a).
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"crew": 60})],
		"enemy_ships": [_ship("sloop", {"crew": 10, "cannons": 0})],
		"seed": 2,
	})
	sim.start()
	var boarder := _unit(sim, "player", 0)
	var target := _unit(sim, "enemy", 0)
	_place(sim, "player", 0, Vector2i(10, 15))
	_place(sim, "enemy", 0, Vector2i(11, 15))
	boarder["vel"] = Vector2i(1, 0)
	target["vel"] = Vector2i(0, -1)
	_check(sim.can_board(boarder, target),
		"§4.6a: orthogonal + both ⌊vel⌋ ≤ 1 + weather ≠ storm is hook-legal")
	_begin_turn(sim, "player", 0)
	var boarding := sim.board(boarder, target)
	_check(bool(boarding["ok"]),
		"§4.6a: the hook succeeds and the boarding duel resolves")
	_check((boarder["vel"] as Vector2i) == Vector2i.ZERO
			and (target["vel"] as Vector2i) == Vector2i.ZERO,
		"§4.6a correction 7: the hook sets BOTH ships' vel = (0,0)")
	_check(str(boarding["duel"]["result"]) == "capture",
		"§4.11.6: the seeded duel captures (seed 2, base 12 vs 8)")

	# Storm forbids hooking outright (§4.2 / §4.6a).
	var storm_sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
		"weather": "storm",
	})
	storm_sim.start()
	var storm_boarder := _unit(storm_sim, "player", 0)
	var storm_target := _unit(storm_sim, "enemy", 0)
	_place(storm_sim, "player", 0, Vector2i(10, 15))
	_place(storm_sim, "enemy", 0, Vector2i(11, 15))
	_check(not storm_sim.can_board(storm_boarder, storm_target),
		"§4.6a: storm forbids the hook outright")
	_begin_turn(storm_sim, "player", 0)
	_check(not bool(storm_sim.board(storm_boarder, storm_target)["ok"]),
		"§4.6a: a board action in a storm is refused")

	# ⌊vel⌋ ≥ 2 on either ship refuses the hook.
	var fast_sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	fast_sim.start()
	var fast_boarder := _unit(fast_sim, "player", 0)
	var fast_target := _unit(fast_sim, "enemy", 0)
	_place(fast_sim, "player", 0, Vector2i(10, 15))
	_place(fast_sim, "enemy", 0, Vector2i(11, 15))
	fast_boarder["vel"] = Vector2i(2, 0)
	_check(not fast_sim.can_board(fast_boarder, fast_target),
		"§4.6a: ⌊attacker vel⌋ = 2 refuses the hook")
	fast_boarder["vel"] = Vector2i.ZERO
	fast_target["vel"] = Vector2i(2, 0)
	_check(not fast_sim.can_board(fast_boarder, fast_target),
		"§4.6a: ⌊target vel⌋ = 2 refuses the hook")

	# Diagonal adjacency is not orthogonal (the §4.5 adjacency base).
	var diag_sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	diag_sim.start()
	var diag_boarder := _unit(diag_sim, "player", 0)
	var diag_target := _unit(diag_sim, "enemy", 0)
	_place(diag_sim, "player", 0, Vector2i(10, 15))
	_place(diag_sim, "enemy", 0, Vector2i(11, 16))
	_check(not diag_sim.can_board(diag_boarder, diag_target),
		"§4.6a: a diagonal neighbour is not hook-legal (orthogonal only)")


# --- 13. Stall (§4.11.9, decision 12) ---------------------------------------

func _test_stall() -> void:
	_person()
	# Two fleets holding at rest: 8 quiet rounds within a ±2 net window →
	# outcome `stall` at exactly round 8.
	var sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("latin")],
	})
	var hold_policy := func(_active_sim, _unit) -> Dictionary:
		return {"action": "hold"}
	var outcome := sim.run_to_completion(hold_policy, 40)
	_check(str(outcome["result"]) == "stall",
		"§4.11.9: 8 quiet rounds at a constant distance end in `stall` (%s)"
			% str(outcome["result"]))
	_check(int(outcome["rounds"]) == BattleLib.STALL_ROUNDS,
		"§4.11.9: the stall fires at exactly round 8 (%d)"
			% int(outcome["rounds"]))
	_check(int(outcome["xp"]) == 8 * BattleLib.XP_PER_ROUND,
		"§4.11.10: a stall keeps the survived-round XP — 8 × 5 = 40 (%d)"
			% int(outcome["xp"]))

	# The distance conjunct: an enemy drifting +1/round breaches the ±2 net
	# window every 4th quiet-round (the anchor restarts each breach), so the
	# streak survives only after the LAST breach — round 25, anchored at
	# Chebyshev 43. The wall freezes the enemy at x = 47 from round 28 (the
	# window's net change stays +2 ≤ 2), and the 8th quiet round completes at
	# exactly round 32.
	var drift_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("latin")],
		"weather": "fair",   # calm + headwind would leave the drifter becalmed
	})
	drift_sim.start()
	_place(drift_sim, "player", 0, Vector2i(2, 15))
	_place(drift_sim, "enemy", 0, Vector2i(20, 15))
	_face(_unit(drift_sim, "enemy", 0), BattleLib.HEADING_EAST)
	var drift_policy := func(active_sim, unit) -> Dictionary:
		if str(unit["side"]) == "enemy":
			return {"action": "move", "vel": Vector2i(1, 0)}
		return {"action": "hold"}
	var drift_outcome := drift_sim.run_to_completion(drift_policy, 40)
	_check(str(drift_outcome["result"]) == "stall"
			and int(drift_outcome["rounds"]) == 32,
		"§4.11.9: the drift breaches the ±2 window (restarts every 4th quiet "
			+ "round) and only stalls once the wall freezes the distance — round 32 (%s @ r%d)"
				% [str(drift_outcome["result"]), int(drift_outcome["rounds"])])

	# Any damage resets the counter: a volley every 3rd round (reload 3)
	# keeps the battle alive past round 8, and the decisive battle ends in
	# victory — never a stall.
	var fight_sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"cannons": 0})],
	})
	fight_sim.start()
	_place(fight_sim, "player", 0, Vector2i(10, 15))
	_place(fight_sim, "enemy", 0, Vector2i(12, 13))   # port arc, Chebyshev 2
	var fire_policy := func(active_sim, unit) -> Dictionary:
		if str(unit["side"]) == "enemy":
			return {"action": "hold"}
		for side in ["port", "starboard"]:
			for target in active_sim.living_units("enemy"):
				if active_sim.can_cannon(unit, target, str(side)):
					return {"action": "cannon", "target": target,
						"side": str(side), "shot": "round"}
		return {"action": "hold"}
	var fight_outcome := fight_sim.run_to_completion(fire_policy, 40)
	_check(str(fight_outcome["result"]) == "victory"
			and int(fight_outcome["rounds"]) > BattleLib.STALL_ROUNDS,
		"§4.11.9: volley damage resets the counter — a decisive battle runs "
			+ "past round 8 and ends in victory (r%d, %s)"
				% [int(fight_outcome["rounds"]), str(fight_outcome["result"])])


# --- 14. Initiative (§4.3, §4.11.4) -----------------------------------------

func _test_initiative() -> void:
	_person()
	# Speeds: brigantine 24, galley 24, sloop 20, caravel 20,
	# latin 16 (+1 sail → 17), latin 16. Descending key, player before enemy
	# on ties, then ascending fleet index.
	var sail_id := "eq_test_init_sails"
	var existed := DataLoader.equipment.has(sail_id)
	var previous = DataLoader.equipment.get(sail_id, null)
	DataLoader.equipment[sail_id] = {
		"id": sail_id, "name": {"zh": "试作帆", "en": "Test Sails"},
		"slot": "sail", "modifiers": {"speed": 1}, "price": 1, "phase": 2,
	}
	var sim := _sim({
		"player_ships": [
			_ship("brigantine"),
			_ship("sloop"),
			_ship("latin", {"equipment": {"figurehead": "", "sail": sail_id}}),
		],
		"enemy_ships": [_ship("galley"), _ship("caravel"), _ship("latin")],
	})
	sim.start()
	var order := _order_of(sim, 6)
	_check(order == ["player:0", "enemy:0", "player:1", "enemy:1", "player:2", "enemy:2"],
		"§4.11.4: descending speed + sail delta, player first on ties, then "
			+ "fleet index: %s" % str(order))
	var latin_unit := _unit(sim, "player", 2)
	_check(sim.initiative_key(latin_unit) == 17,
		"§4.11.4 correction 2: the initiative key is speed + sail delta (16 + 1 = %d)"
			% sim.initiative_key(latin_unit))

	# A unit destroyed before its slot is skipped and never acts.
	var skip_sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("latin", {"durability": 1})],
		"enemy_ships": [_ship("galley", {"cannons": 4})],
	})
	skip_sim.start()
	_place(skip_sim, "enemy", 0, Vector2i(7, 15))
	_place(skip_sim, "player", 1, Vector2i(6, 14))
	var latin := _unit(skip_sim, "player", 1)
	_check(str(skip_sim.current_unit()["side"]) == "player"
			and int(skip_sim.current_unit()["index"]) == 0,
		"§4.11.4: round 1 opens with the 24-speed player brigantine (tie → player)")
	skip_sim.hold(skip_sim.current_unit())
	skip_sim.end_turn()
	var galley := skip_sim.current_unit()
	_check(str(galley["side"]) == "enemy" and int(galley["index"]) == 0,
		"§4.11.4: slot 2 is the enemy galley (24 tie, enemy after player)")
	var volley := skip_sim.cannon(galley, latin, "port")
	_check(bool(volley["ok"]) and bool(volley["sunk"]),
		"§4.11.4: the galley sinks the 1-durability latin before its slot")
	skip_sim.end_turn()
	_check(skip_sim.round_number() == 2,
		"§4.11.4: the dead latin's slot is skipped and the round rolls over (r%d)"
			% skip_sim.round_number())
	_check(str(skip_sim.current_unit()["side"]) == "player"
			and int(skip_sim.current_unit()["index"]) == 0,
		"§4.11.4: round 2 opens with the surviving brigantine")

	# The order is never re-sorted mid-battle: after the sloop dies, round 3
	# keeps the built-once order minus the dead slot (the 17-key latin does
	# NOT jump ahead of the 24-speed galley).
	var resort_sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("sloop", {"durability": 1})],
		"enemy_ships": [_ship("galley", {"cannons": 4}), _ship("caravel")],
	})
	resort_sim.start()
	_order_of(resort_sim, 4)   # round 1 plays out untouched
	_place(resort_sim, "enemy", 0, Vector2i(7, 15))
	_place(resort_sim, "player", 1, Vector2i(6, 14))
	var doomed_sloop := _unit(resort_sim, "player", 1)
	_begin_turn(resort_sim, "enemy", 0)
	resort_sim.cannon(_unit(resort_sim, "enemy", 0), doomed_sloop, "port")
	_check(not bool(doomed_sloop["alive"]), "§4.3: the sloop is sunk mid-battle")
	resort_sim.end_turn()
	resort_sim.end_turn()   # e1's slot, then the wrap into round 3
	_check(resort_sim.round_number() == 3, "§4.3: the fixture reaches round 3")
	var round3 := _order_of(resort_sim, 3)
	_check(round3 == ["player:0", "enemy:0", "enemy:1"],
		"§4.3: the once-built order never re-sorts — round 3 is %s (the dead "
			+ "slot skipped, no speed re-sort)" % str(round3))
	if round3 != ["player:0", "enemy:0", "enemy:1"]:
		print("      round 3 order: %s" % str(round3))
	if existed:
		DataLoader.equipment[sail_id] = previous
	else:
		DataLoader.equipment.erase(sail_id)


# --- 15. Determinism (§4.11.1) ----------------------------------------------

func _test_determinism() -> void:
	_person(14)
	var seed_value := 4242
	var runs: Array = []
	for _attempt in 2:
		var rng := _rng(seed_value)
		var enemy: Array = AiLib.compose_enemy("pirate", 12, rng)
		var sim := _sim({
			"player_ships": [_ship("brigantine", {"cannons": 10, "crew": 40})],
			"enemy_ships": enemy,
			"day": 12, "gold": 3000, "contact": Vector2i(30, 40),
			"seed": seed_value, "rng": rng,
		})
		sim.start()
		var policy := func(active_sim, unit) -> Dictionary:
			return _fire_and_close_policy(active_sim, unit)
		var outcome := sim.run_to_completion(policy, BattleLib.MAX_ROUNDS)
		runs.append({
			"log": JSON.stringify(sim.log_lines()),
			"outcome": JSON.stringify(outcome),
			"result": str(outcome.get("result", "")),
		})
	_check(runs.size() == 2 and str(runs[0]["result"]) in BattleLib.RESULT_VALUES,
		"§4.11.1: the scripted battle ends with a §4.11.9 result (%s)"
			% str(runs[0]["result"]))
	_check(not runs.is_empty() and str(runs[0]["log"]) == str(runs[1]["log"]),
		"§4.11.1: the same seed replays an IDENTICAL log_lines() across two "
			+ "full run_to_completion runs")
	_check(not runs.is_empty() and str(runs[0]["outcome"]) == str(runs[1]["outcome"]),
		"§4.11.1: the same seed replays an identical outcome block")

	# The §4.11.1 seed arithmetic (plain integers, no hash()) and the
	# config override (§4.12.1).
	var formula := BattleLib.battle_seed_formula(12, Vector2i(30, 40), 3000, 1)
	_check(formula == 12 * 1000003 + 30 * 7919 + 40 * 104729 + 3000 * 31 + 1 * 17,
		"§4.11.1: seed = day×1000003 + x×7919 + y×104729 + gold×31 + n×17 = %d"
			% formula)
	var overridden := _sim({"player_ships": [], "enemy_ships": [], "seed": 99})
	_check(overridden.seed_value() == 99, "§4.12.1: a config seed overrides the formula")


# --- 16. Duel bases (§4.11.6 — carried over from Phase 8) -------------------

func _test_duel_bases() -> void:
	# The player base: swordplay + floor(courage / 20) + worn combat deltas.
	_person(12)
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	_check(BattleLib.player_duel_base() == 12,
		"§4.11.6: the bare base is swordplay 12 + floor(courage 10/20) = 12 (%d)"
			% BattleLib.player_duel_base())
	for boundary in [[0, 10, 0], [30, 50, 32], [60, 100, 65]]:
		_person(int(boundary[0]), 0, {"attributes": {"courage": int(boundary[1])}})
		_check(BattleLib.player_duel_base() == int(boundary[2]),
			"§4.11.6: swordplay %d + courage %d → base %d (got %d)"
				% [int(boundary[0]), int(boundary[1]), int(boundary[2]),
				BattleLib.player_duel_base()])
	var cutlass := "eq_test_duel_cutlass"
	var cutlass_existed := DataLoader.equipment.has(cutlass)
	var cutlass_previous = DataLoader.equipment.get(cutlass, null)
	DataLoader.equipment[cutlass] = {
		"id": cutlass, "name": {"zh": "试作弯刀", "en": "Test Cutlass"},
		"slot": "weapon", "modifiers": {"combat": 3}, "price": 400, "phase": 2,
	}
	_person(12)
	GameState.player["equipment"] = {"weapon": cutlass, "armor": cutlass}
	_check(BattleLib.player_duel_base() == 18,
		"§4.11.12: both worn slots stack their combat modifiers (12 + 6 = %d)"
			% BattleLib.player_duel_base())
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	if cutlass_existed:
		DataLoader.equipment[cutlass] = cutlass_previous
	else:
		DataLoader.equipment.erase(cutlass)

	# The defender base: min(floor(crew/5), 20) + the captain rating.
	_check(BattleLib.defender_duel_base(50, 6) == 16,
		"§4.11.6: floor(50/5) + 6 = 16 (%d)" % BattleLib.defender_duel_base(50, 6))
	_check(BattleLib.defender_duel_base(500, 6) == 26,
		"§4.11.6: the crew term caps at 20 (20 + 6 = %d)"
			% BattleLib.defender_duel_base(500, 6))
	_check(BattleLib.defender_duel_base(0, 7) == 7,
		"§4.11.6: crew 0 leaves the captain rating alone (%d)"
			% BattleLib.defender_duel_base(0, 7))
	_check(BattleLib.defender_charisma_bonus(10) == 0
			and BattleLib.defender_charisma_bonus(45) == 2
			and BattleLib.defender_charisma_bonus(85) == 4,
		"§4.11.6: the defender bonus is floor(charisma / 20): 10→0, 45→2, 85→4")

	# The §4.11.6 scripted sequences (resolve_duel is the only formula).
	var capture := BattleLib.resolve_duel(15, 10, _rng(33))
	_check(str(capture["rounds"]) == str(["win", "loss", "win", "win"])
			and str(capture["result"]) == "capture"
			and int(capture["player_wins"]) == 3,
		"§4.11.6: seed 33 decides 3–1 win/loss/win/win → capture (%s)"
			% str(capture["rounds"]))
	_check(BattleLib.resolve_duel(15, 10, _rng(33)) == capture,
		"§4.11.6: the same seed replays the identical duel")
	var defeat := BattleLib.resolve_duel(15, 10, _rng(19))
	_check(str(defeat["result"]) == "defeat"
			and str(defeat["rounds"]) == str(["loss", "win", "loss", "loss"]),
		"§4.11.6: seed 19 is the mirror defeat (%s)" % str(defeat["rounds"]))
	var tied := BattleLib.resolve_duel(15, 10, _rng(2))
	_check("tie" in (tied["rounds"] as Array) and int(tied["defender_wins"]) == 0,
		"§4.11.6: a tie round scores for neither side (seed 2: %s)"
			% str(tied["rounds"]))
	var stuck := BattleLib.resolve_duel(15, 10, _rng(14))
	_check((stuck["rounds"] as Array).size() == 5 and str(stuck["result"]) == "defeat",
		"§4.11.6: level after 5 rounds → the defender holds (defeat)")


# --- 17. Economy pins (§4.11.10 — carried over) -----------------------------

func _test_economy_pins() -> void:
	_person(10)
	# Salvage Σ floor(base_price × 0.05) over ships sunk BY THE PLAYER.
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"durability": 4})],
	})
	sim.start()
	var gunner := _unit(sim, "player", 0)
	var wreck := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(3, 14))
	_begin_turn(sim, "player", 0)
	_check(bool(sim.cannon(gunner, wreck, "port")["sunk"]),
		"§4.11.10: the fixture sinks the sloop with one volley")
	var outcome := sim.outcome()
	var sloop_price := int(DataLoader.get_ship_type("sloop")["base_price"])
	_check(int(outcome["salvage_gold"]) == int(floor(sloop_price * 0.05)),
		"§4.11.10: salvage = floor(%d × 0.05) = %d (%d)"
			% [sloop_price, int(floor(sloop_price * 0.05)),
			int(outcome["salvage_gold"])])
	_check(int(outcome["xp"]) == 1 * BattleLib.XP_PER_ENEMY_NEUTRALIZED
			+ 1 * BattleLib.XP_PER_ROUND,
		"§4.11.10: XP = 10 per neutralised + 5 per round = 15 (%d)"
			% int(outcome["xp"]))
	# Pirate rep: +2 with the two nearest ports' nations (deduplicated).
	var expected := {}
	for nation_id in RewardsLib.nearest_nations(Vector2i(30, 40)):
		expected[nation_id] = BattleLib.PIRATE_REP_GAIN
	_check((outcome["rep_deltas"] as Dictionary) == expected,
		"§4.11.10: rep_deltas is the nearest-nations list at +2 (%s vs %s)"
			% [str(outcome["rep_deltas"]), str(expected)])

	# The navy −20 is charged at battle START by the S3 funnel — the outcome
	# block never carries it (§4.11.10).
	var navy := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10, "crew": 40})],
		"enemy_ships": [_ship("sloop", {"durability": 1})],
		"enemy_kind": "navy", "enemy_nation": "spain",
	})
	navy.start()
	var navy_gunner := _unit(navy, "player", 0)
	_place(navy, "enemy", 0, Vector2i(3, 14))
	_begin_turn(navy, "player", 0)
	navy.cannon(navy_gunner, _unit(navy, "enemy", 0), "port")
	_check((navy.outcome()["rep_deltas"] as Dictionary).is_empty(),
		"§4.11.10: a navy outcome carries no rep_deltas at all (%s)"
			% str(navy.outcome()["rep_deltas"]))
	_check(BattleLib.NAVY_REP_PENALTY == -20,
		"§4.11.10: the pinned navy penalty stays −20 (applied elsewhere)")

	# The round cap re-pinned to 40 (correction 12) and the menu outcomes.
	_check(BattleLib.MAX_ROUNDS == 40,
		"§4.11.10 correction 12: the round cap is 40 (%d)" % BattleLib.MAX_ROUNDS)
	var retreat_sim := _sim({
		"player_ships": [_ship("sloop")], "enemy_ships": [_ship("latin")]})
	retreat_sim.start()
	var retreat := retreat_sim.retreat()
	_check(str(retreat["result"]) == "retreat" and int(retreat["xp"]) == 0
			and int(retreat["salvage_gold"]) == 0
			and (retreat["rep_deltas"] as Dictionary).is_empty(),
		"§4.10: a retreat forfeits nothing but costs no XP and books no rep")
	var pirate_sim := _sim({
		"player_ships": [_ship("sloop")], "enemy_ships": [_ship("latin")]})
	pirate_sim.start()
	var surrendered := pirate_sim.offer_surrender()
	_check(str(surrendered["result"]) == "surrender"
			and (surrendered["lost_player"] as Array).is_empty(),
		"§4.11.7: a player surrender to pirates keeps the fleet (the hold goes)")
	var navy_surrender_sim := _sim({
		"player_ships": [_ship("sloop")], "enemy_ships": [_ship("latin")],
		"enemy_kind": "navy", "enemy_nation": "spain",
	})
	navy_surrender_sim.start()
	var navy_surrender := navy_surrender_sim.offer_surrender()
	_check(str(navy_surrender["result"]) == "defeat_captured"
			and (navy_surrender["lost_player"] as Array).size() == 1,
		"§4.11.7: surrendering the last ship to a navy takes the flagship hull")

	# outcome() is {} until is_over(); a capped run reports unfinished.
	var pending := _sim({"player_ships": [_ship("sloop")], "enemy_ships": [_ship("latin")]})
	pending.start()
	_check(pending.outcome().is_empty(), "§4.12.1: outcome() is {} while the battle runs")
	var capped_sim := _sim({
		"player_ships": [_ship("sloop")], "enemy_ships": [_ship("latin")]})
	var capped_policy := func(_active_sim, _unit) -> Dictionary:
		return {"action": "hold"}
	var capped := capped_sim.run_to_completion(capped_policy, 3)
	_check(not capped_sim.is_over() and str(capped["result"]) == "",
		"§4.12.1: a battle held under max_rounds=3 reports unfinished (%s)"
			% str(capped))

	# The engine never mutates the caller's ships (§4.12.1).
	var caller_fleet: Array = [_ship("brigantine", {"cannons": 10})]
	var frozen: Array = caller_fleet.duplicate(true)
	var untouched_sim := _sim({
		"player_ships": caller_fleet,
		"enemy_ships": [_ship("latin")],
	})
	var untouched_policy := func(active_sim, unit) -> Dictionary:
		return _fire_and_close_policy(active_sim, unit)
	untouched_sim.run_to_completion(untouched_policy, BattleLib.MAX_ROUNDS)
	_check(JSON.stringify(caller_fleet) == JSON.stringify(frozen),
		"§4.12.1: the engine deep-copies — the caller's ships are untouched")


# --- 18. compose_enemy (§4.11.3 — slim; W3-B seam noted) ---------------------

func _test_compose_enemy() -> void:
	# W3-B seam: slot B's rewrite derives `cannons_port`/`cannons_starboard`
	# here (total retained). The §4.11.3 composition pins below hold under
	# both the current file and the rewrite.
	var never_empty := true
	var hulls_ok := true
	var counts_ok := true
	var cargo_ok := true
	var budget_ok := true
	var goods_ids: Array = []
	for entry in DataLoader.goods_list:
		goods_ids.append(str(entry.get("id", "")))
	for seed_value in range(1, 5):
		for kind in ["pirate", "navy"]:
			var fleet_a: Array = AiLib.compose_enemy(kind, 45, _rng(seed_value))
			var fleet_b: Array = AiLib.compose_enemy(kind, 45, _rng(seed_value))
			if fleet_a.is_empty() or JSON.stringify(fleet_a) != JSON.stringify(fleet_b):
				never_empty = false
			var expected_budget := (20 if kind == "pirate" else 30) \
				+ int(floor(45.0 / 30.0))
			var total_cannons := 0
			for ship in fleet_a:
				var ship_type: Dictionary = DataLoader.get_ship_type(
					str(ship["ship_type_id"]))
				if not (str(ship.get("ship_type_id", "")) in AiLib.HULL_IDS):
					hulls_ok = false
				if int(ship["cannons"]) > int(ship_type["armament_slots"]):
					counts_ok = false
				total_cannons += int(ship["cannons"])
				if int(ship["crew"]) != int(ship_type["crew_min"]) \
						or int(ship["durability"]) != int(ship_type["durability"]):
					counts_ok = false
				var cargo: Dictionary = ship["cargo"]
				var expected_qty := maxi(1, int(floor(float(ship_type["capacity"]) / 10.0)))
				if cargo.size() != 1 \
						or not (str(cargo.keys()[0]) in goods_ids) \
						or int(cargo[cargo.keys()[0]]) != expected_qty:
					cargo_ok = false
			if total_cannons > expected_budget:
				budget_ok = false
			var size := fleet_a.size()
			if kind == "pirate" and (size < 1 or size > 3):
				counts_ok = false
			if kind == "navy" and (size < 2 or size > 4):
				counts_ok = false
	_check(never_empty, "§4.11.3: compose_enemy is deterministic for the same seed")
	_check(hulls_ok, "§4.11.3: every hull id comes from the locked 4-hull order")
	_check(counts_ok, "§4.11.3: crew_min crew, full durability, counts 1–3 / 2–4")
	_check(cargo_ok, "§4.11.3: each ship carries max(1, floor(capacity/10)) of one good")
	_check(budget_ok, "§4.11.3: total cannons stay within the 20/30 + floor(day/30) budget")
	_check(AiLib.cannon_budget("pirate", 0) == 20 and AiLib.cannon_budget("pirate", 59) == 21,
		"§4.11.3: the pirate budget is 20 + floor(day/30)")
	_check(AiLib.cannon_budget("navy", 0) == 30 and AiLib.cannon_budget("navy", 90) == 33,
		"§4.11.3: the navy budget is 30 + floor(day/30)")


# --- Harness ----------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
