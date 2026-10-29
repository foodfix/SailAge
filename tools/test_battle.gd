extends Node
## Phase-2 task B (combat engine core) acceptance tests
## (docs/IMPLEMENT-Phase2.md B; docs/60-COMBAT.md §4.2–§4.7, §4.9, §4.11.2–
## §4.11.9, §4.12.1, §5). Headless scene test:
##
##   godot --headless res://tools/test_battle.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 grid + §4.11.2 deployment tiles for 1..5 ships per side;
##   2 initiative order (§4.11.4) incl. a unit killed before its slot;
##   3 MP rules: orthogonal 1 / diagonal 2, refresh, occupancy (§4.3);
##   4 reload: fire r1 → blocked r2 → fires r3 (§4.11.4);
##   5 the §5 worked cannon example + range/storm factors (§4.11.5);
##   6 ram numbers, oar ×1.25, the galley designer check (§4.5, §4.11.5);
##   7 the duel: §5 scripted sequence, ties, 5-round pin (§4.6, §4.11.6);
##   8 boarding through resolve_duel: capture + loss paths (§4.11.7);
##   9 compose_enemy determinism + all §4.11.3 bounds;
##  10 AI §4.9 rules 1–6 with one seeded fixture each;
##  11 a full headless battle via run_to_completion;
##  12 one-action-per-turn, occupancy walls, salvage/XP pins, §4.11.12 gear;
##  13 the §4.11.1 stream continuity (composition → duel), a fully scripted
##     battle replayed from a fixed seed, and a 60-battle robustness sweep.

const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const AiLib := preload("res://scripts/combat/ai_fleet.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

## FLEET_MAX (docs/40-* §4.4) — the deployment table has 5 rows per side.
const TABLE_ROWS := 5
## Damage constants asserted below (§5 + §4.11.5).
const DOC_CANNON_DAMAGE := 16
const DOC_COMBAT_RATING := 14

var _failures: Array[String] = []
var _checks := 0

## Observation state for the run_to_completion policy (see [method
## _test_full_battle] — a lambda cannot write a local back to its caller).
var _sizes_ok := true
var _previous_sizes: Dictionary = {}


func _ready() -> void:
	_test_grid_and_deployment()
	_test_initiative_order()
	_test_mp_rules()
	_test_reload()
	_test_cannon_damage()
	_test_ram()
	_test_duel()
	_test_board_paths()
	_test_compose_enemy()
	_test_ai_rules()
	_test_full_battle()
	_test_turn_and_equipment_pins()
	_test_seed_audit()
	_report()


# --- Fixtures --------------------------------------------------------------

func _stats(combat: int = 10) -> void:
	GameState.player = {
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": combat,
			"navigation": 10, "luck": 10,
		},
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
	var full := {
		"player_ships": [], "enemy_ships": [], "enemy_kind": "pirate",
		"enemy_nation": "", "day": 1, "gold": 0,
		"contact": Vector2i(30, 40), "weather": "calm",
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


## Repositions a unit. Fixtures need close-quarters setups: §4.2 deployment
## deliberately opens every battle 13 tiles apart ("every battle opens with a
## movement phase"), so the tests that exercise a single turn build the
## arrangement explicitly instead of sailing for six rounds first.
func _place(sim: BattleLib, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["cell"] = cell


## Ends turns until `side`/`index` is the acting unit (refreshing its MP the
## way a real turn does), so AI fixtures are evaluated exactly as in a battle.
func _begin_turn(sim: BattleLib, side: String, index: int) -> Dictionary:
	for _guard in 12:
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


# --- 1. Grid + deployment (§4.2, §4.11.2) ---------------------------------

func _test_grid_and_deployment() -> void:
	_stats()
	_check(BattleLib.GRID_WIDTH == 16 and BattleLib.GRID_HEIGHT == 10,
		"the grid is 16×10 (§4.2): %d×%d" % [BattleLib.GRID_WIDTH, BattleLib.GRID_HEIGHT])
	_check(BattleLib.PLAYER_DEPLOYMENT.size() == TABLE_ROWS
			and BattleLib.ENEMY_DEPLOYMENT.size() == TABLE_ROWS,
		"the §4.11.2 table has one row per fleet slot (%d)" % FleetLib.FLEET_MAX)

	# The pinned table, verbatim.
	var player_table := [
		Vector2i(1, 4), Vector2i(1, 5), Vector2i(1, 3), Vector2i(1, 6), Vector2i(1, 2),
	]
	var enemy_table := [
		Vector2i(14, 4), Vector2i(14, 5), Vector2i(14, 3), Vector2i(14, 6), Vector2i(14, 2),
	]
	var player_cells: Array = []
	for cell in BattleLib.PLAYER_DEPLOYMENT:
		player_cells.append(cell)
	_check(player_cells == player_table,
		"player deployment matches §4.11.2 exactly (%s)" % str(player_cells))
	var enemy_cells: Array = []
	for cell in BattleLib.ENEMY_DEPLOYMENT:
		enemy_cells.append(cell)
	_check(enemy_cells == enemy_table,
		"enemy deployment matches §4.11.2 exactly (%s)" % str(enemy_cells))

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
		_check(band_ok, "%d ships/side: player band x≤2, enemy band x≥13 (§4.2)" % count)
		_check(distinct.size() == placed.size(),
			"%d ships/side: no two units share a cell (%d distinct of %d)"
			% [count, distinct.size(), placed.size()])
		_check(sim.units().size() == count * 2,
			"%d ships/side: the engine holds %d units" % [count, count * 2])

	# The two bands start 13 tiles apart (§4.11.2).
	_check(BattleLib.ENEMY_DEPLOYMENT[0].x - BattleLib.PLAYER_DEPLOYMENT[0].x == 13,
		"the flagship bands open 13 tiles apart")


# --- 2. Initiative order (§4.11.4) ---------------------------------------

func _test_initiative_order() -> void:
	_stats()
	# Speeds: brigantine 6, galley 6, sloop 5, caravel 5, latin 4.
	var sim := _sim({
		"player_ships": [
			_ship("sloop"), _ship("brigantine"), _ship("latin"),
		],
		"enemy_ships": [_ship("caravel"), _ship("galley")],
	})
	sim.start()
	var order := _order_of(sim, 5)
	_check(order == ["player:1", "enemy:1", "player:0", "enemy:0", "player:2"],
		"descending speed, player-before-enemy on ties, then fleet index: %s" % str(order))

	# A unit killed before its slot never acts. Order round 1 is
	# player:0 (brigantine 6) → enemy:0 (galley 6) → player:1 (latin 4); the
	# galley sinks the latin at slot 2, so slot 3 must be skipped.
	var kill_sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("latin", {"durability": 1})],
		"enemy_ships": [_ship("galley", {"cannons": 4})],
	})
	kill_sim.start()
	_place(kill_sim, "enemy", 0, Vector2i(7, 4))
	_place(kill_sim, "player", 1, Vector2i(5, 5))
	var latin := _unit(kill_sim, "player", 1)
	_check(kill_sim.unit_cell(latin) == Vector2i(5, 5)
			and kill_sim.unit_cell(_unit(kill_sim, "enemy", 0)) == Vector2i(7, 4),
		"the skip fixture places the galley 2 tiles from the 1-durability latin")
	_check(str(kill_sim.current_unit()["side"]) == "player"
			and int(kill_sim.current_unit()["index"]) == 0,
		"round 1 opens with the player brigantine (speed 6, player tie-break)")
	kill_sim.hold(kill_sim.current_unit())
	kill_sim.end_turn()
	var galley := kill_sim.current_unit()
	_check(str(galley["side"]) == "enemy" and int(galley["index"]) == 0,
		"slot 2 is the enemy galley (speed 6 tie, enemy after player)")
	var volley := kill_sim.cannon(galley, latin)
	_check(bool(volley["ok"]) and bool(volley["sunk"]),
		"the galley sinks the latin before its slot (damage %d)" % int(volley["damage"]))
	kill_sim.end_turn()
	_check(kill_sim.round_number() == 2,
		"the dead latin's slot is skipped and the round rolls over (round %d)"
		% kill_sim.round_number())
	_check(str(kill_sim.current_unit()["side"]) == "player"
			and int(kill_sim.current_unit()["index"]) == 0,
		"round 2 opens with the surviving brigantine")
	var skipped := true
	for unit in kill_sim.units():
		if unit == latin and bool(unit.get("alive", true)):
			skipped = false
	_check(skipped, "the sunk unit is marked dead and never acts again")


# --- 3. MP rules (§4.3, §4.11.4) ------------------------------------------

func _test_mp_rules() -> void:
	_stats()
	var sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("sloop")],
		"enemy_ships": [_ship("latin")],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	_check(sim.current_unit() == brig, "the 6-MP brigantine acts first")
	_check(int(brig["mp"]) == 6, "MP is refreshed to ShipType.speed at turn start (%d)"
		% int(brig["mp"]))
	_check(sim.effective_speed(brig) == 6, "brigantine effective speed is 6")

	var moves := sim.legal_moves(brig)
	_check(moves.has(Vector2i(7, 4)),
		"6 orthogonal steps are reachable: (1,4) → (7,4)")
	_check(not moves.has(Vector2i(8, 4)),
		"a 7th orthogonal step is out of MP: (8,4) unreachable")
	_check(moves.has(Vector2i(4, 7)),
		"3 diagonal steps cost 6 MP and are reachable: (1,4) → (4,7)")
	_check(not moves.has(Vector2i(5, 8)),
		"4 diagonal steps would cost 8 MP: (5,8) unreachable")
	# (1,3) is a legal diagonal step inside the grid (cost 2).
	_check(moves.has(Vector2i(1, 3)), "an in-grid diagonal step costs 2 MP: (1,3) reachable")
	_check(moves.has(Vector2i(0, 3)),
		"a diagonal toward the west edge (0,3) is reachable: both corner tiles "
			+ "(0,4)/(1,3) are inside the grid (§4.11.4)")
	_check(moves.has(Vector2i(2, 3)),
		"a diagonal inside the grid (2,3) is reachable at cost 2")
	# With open sea (§4.2) the corner rule is structural: a destination inside
	# the grid always has both orthogonal corners inside it too, so no legal
	# diagonal is ever blocked in Phase 2 (reef/coast terrain is Phase 3).
	var corners_ok := true
	for cell in moves:
		if cell.x == 1 and cell.y == 4:
			corners_ok = false
	_check(corners_ok, "legal_moves never returns the origin tile itself")
	var sloop_cell := sim.unit_cell(_unit(sim, "player", 1))
	_check(sloop_cell == Vector2i(1, 5), "the escort deploys at (1,5)")
	_check(not moves.has(sloop_cell), "an occupied tile is never a legal move")
	_check(not sim.move_to(brig, sloop_cell), "moving onto an occupied tile is refused")
	_check(sim.unit_cell(brig) == Vector2i(1, 4), "the refused move changes nothing")
	_check(not sim.move_to(brig, Vector2i(9, 4)), "an out-of-MP move is refused")

	_check(sim.move_to(brig, Vector2i(7, 4)),
		"move_to spends 6 MP for 6 orthogonal steps")
	_check(sim.unit_cell(brig) == Vector2i(7, 4), "the ship is on (7,4)")
	_check(int(brig["mp"]) == 0, "MP is 0 after the full move (%d)" % int(brig["mp"]))
	_check(sim.legal_moves(brig).is_empty(), "no MP → no legal moves left this turn")

	# MP never carries over: partial move, then the next turn is full again.
	sim.end_turn()  # escort's turn
	sim.end_turn()  # latin's turn
	sim.end_turn()  # → round 2, brigantine again
	_check(sim.current_unit() == brig and sim.round_number() == 2,
		"round 2 reaches the brigantine again")
	_check(int(brig["mp"]) == 6, "MP refreshes to full in round 2 (%d)" % int(brig["mp"]))
	_check(sim.move_to(brig, Vector2i(6, 3)), "a diagonal step is legal (cost 2)")
	_check(int(brig["mp"]) == 4, "the diagonal move cost 2 MP (%d left)" % int(brig["mp"]))
	sim.end_turn()
	sim.end_turn()
	sim.end_turn()
	_check(sim.round_number() == 3 and int(brig["mp"]) == 6,
		"the 4 unspent MP do not carry over: round 3 starts at 6 (got %d)"
		% int(brig["mp"]))


# --- 4. Reload (§4.4, §4.11.4) -------------------------------------------

func _test_reload() -> void:
	_stats(10)
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"cannons": 0})],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var enemy := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(3, 4))  # Chebyshev 2 → in range
	_check(sim.round_number() == 1, "reload fixture starts in round 1")
	_check(sim.can_cannon(brig, enemy), "round 1: cannons ≥ 1, loaded, in range")
	var shot := sim.cannon(brig, enemy)
	_check(bool(shot["ok"]) and int(shot["damage"]) > 0,
		"round 1 volley lands (%d damage)" % int(shot["damage"]))
	_check(int(brig["reload_until_round"]) == 3,
		"firing sets reload_until_round = round + 2 (%d)"
		% int(brig["reload_until_round"]))
	sim.end_turn()  # enemy turn
	sim.hold(sim.current_unit())
	sim.end_turn()  # → round 2
	_check(sim.round_number() == 2 and sim.current_unit() == brig,
		"round 2 reaches the brigantine")
	_check(not sim.can_cannon(brig, enemy),
		"round 2: reloading, the same volley is illegal (§4.4 'cannot fire next turn')")
	var blocked := sim.cannon(brig, enemy)
	_check(not bool(blocked["ok"]) and int(blocked["damage"]) == 0,
		"a blocked volley deals no damage")
	sim.end_turn()
	sim.hold(sim.current_unit())
	sim.end_turn()  # → round 3
	_check(sim.round_number() == 3, "round 3 begins")
	_check(sim.can_cannon(brig, enemy), "round 3: loaded again, the volley is legal")


# --- 5. Cannon damage (§5, §4.11.5) --------------------------------------

func _test_cannon_damage() -> void:
	_stats(DOC_COMBAT_RATING)
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"durability": 60})],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var enemy := _unit(sim, "enemy", 0)
	_check(sim.combat_rating(brig) == DOC_COMBAT_RATING,
		"the player flagship's combat rating is the effective combat stat (%d)"
		% sim.combat_rating(brig))
	_check(sim.combat_rating(enemy) == 6,
		"a pirate ship's combat rating is 5 + tier 1 = 6 (%d)" % sim.combat_rating(enemy))

	_place(sim, "enemy", 0, Vector2i(3, 4))
	_check(sim.cannon_damage(brig, enemy) == DOC_CANNON_DAMAGE,
		"§5 worked example: 10 cannons, range 2, combat 14 → 16 (got %d)"
		% sim.cannon_damage(brig, enemy))
	var landing := sim.cannon(brig, enemy)
	_check(int(landing["damage"]) == DOC_CANNON_DAMAGE,
		"the cannon action applies exactly 16 damage (%d)" % int(landing["damage"]))
	_check(int(enemy["ship"]["durability"]) == 60 - DOC_CANNON_DAMAGE,
		"the target's durability drops 60 → 44 (%d)"
		% int(enemy["ship"]["durability"]))

	# Range factors: 1.0 / 0.75 / 0.5 with the +1 combat bonus.
	_place(sim, "enemy", 0, Vector2i(2, 4))
	_check(sim.cannon_damage(brig, enemy) == 21,
		"range 1 factor 1.0: floor(10×2×1.0) + 1 = 21 (got %d)"
		% sim.cannon_damage(brig, enemy))
	_place(sim, "enemy", 0, Vector2i(4, 4))
	_check(sim.cannon_damage(brig, enemy) == 11,
		"range 3 factor 0.5: floor(10×2×0.5) + 1 = 11 (got %d)"
		% sim.cannon_damage(brig, enemy))

	# Without the gunner bonus the raw factors are 20 and 10 (§5).
	_stats(0)
	_check(sim.combat_rating(brig) == 0, "combat 0 → rating 0")
	_place(sim, "enemy", 0, Vector2i(2, 4))
	_check(sim.cannon_damage(brig, enemy) == 20,
		"range 1 without bonus: floor(10×2×1.0) = 20 (got %d)"
		% sim.cannon_damage(brig, enemy))
	_place(sim, "enemy", 0, Vector2i(4, 4))
	_check(sim.cannon_damage(brig, enemy) == 10,
		"range 3 without bonus: floor(10×2×0.5) = 10 (got %d)"
		% sim.cannon_damage(brig, enemy))

	# Storm: all cannon damage ×0.75, floored after the bonus (§4.2/§4.11.5).
	_stats(DOC_COMBAT_RATING)
	var storm := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop")],
		"weather": "storm",
	})
	storm.start()
	var storm_brig := _unit(storm, "player", 0)
	var storm_enemy := _unit(storm, "enemy", 0)
	_place(storm, "enemy", 0, Vector2i(3, 4))
	_check(storm.cannon_damage(storm_brig, storm_enemy) == 12,
		"storm: floor(16 × 0.75) = 12 (got %d)"
		% storm.cannon_damage(storm_brig, storm_enemy))

	# Range 4 is out of range, out of arc terms inclusive (§4.4 1..3).
	_place(storm, "enemy", 0, Vector2i(5, 4))
	_check(not storm.can_cannon(storm_brig, storm_enemy),
		"range 4 is out of range (Chebyshev 1..3 only)")

	# Escorts get no combat bonus (§4.11.5).
	var two := _sim({
		"player_ships": [_ship("brigantine"), _ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop")],
	})
	two.start()
	var escort := _unit(two, "player", 1)
	_check(two.combat_rating(escort) == 0,
		"player escorts have combat rating 0 (%d)" % two.combat_rating(escort))
	_place(two, "enemy", 0, Vector2i(3, 4))
	_check(two.cannon_damage(escort, _unit(two, "enemy", 0)) == 15,
		"escort range-2 volley: floor(10×2×0.75) + 0 = 15 (got %d)"
		% two.cannon_damage(escort, _unit(two, "enemy", 0)))


# --- 6. Ram (§4.5, §4.11.5) ----------------------------------------------

func _test_ram() -> void:
	_stats()
	var sim := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var enemy := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(2, 4))
	_check(sim.can_ram(brig, enemy), "a ram needs an orthogonally adjacent target")
	var hit := sim.ram(brig, enemy)
	_check(int(hit["damage"]) == 27,
		"brigantine ram target damage: floor(0.25 × 110) = 27 (got %d)"
		% int(hit["damage"]))
	_check(int(hit["attacker_damage"]) == 11,
		"brigantine ram self damage: floor(0.10 × 110) = 11 (got %d)"
		% int(hit["attacker_damage"]))
	_check(int(enemy["ship"]["durability"]) == 60 - 27,
		"the sloop loses 27 durability (60 → 33: %d)"
		% int(enemy["ship"]["durability"]))
	_check(int(brig["ship"]["durability"]) == 110 - 11,
		"the brigantine loses 11 durability (110 → 99: %d)"
		% int(brig["ship"]["durability"]))

	# Diagonal neighbours cannot be rammed (orthogonal only).
	var diagonal := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
	})
	diagonal.start()
	_place(diagonal, "enemy", 0, Vector2i(2, 5))
	_check(not diagonal.can_ram(_unit(diagonal, "player", 0), _unit(diagonal, "enemy", 0)),
		"a diagonal neighbour is not rammable (§4.5 orthogonal)")

	# Designer check: the galley (class oar) multiplies target damage ×1.25.
	var galley_sim := _sim({
		"player_ships": [_ship("galley")],
		"enemy_ships": [_ship("sloop")],
	})
	galley_sim.start()
	var galley := _unit(galley_sim, "player", 0)
	var victim := _unit(galley_sim, "enemy", 0)
	_place(galley_sim, "enemy", 0, Vector2i(2, 4))
	var galley_hit := galley_sim.ram(galley, victim)
	_check(int(galley_hit["damage"]) == 21,
		"galley ram (oar ×1.25): floor(floor(0.25 × 70) × 1.25) = 21 (got %d)"
		% int(galley_hit["damage"]))
	_check(int(galley_hit["attacker_damage"]) == 7,
		"galley ram self damage: floor(0.10 × 70) = 7 (got %d)"
		% int(galley_hit["attacker_damage"]))

	# Hybrid hulls count as oar too (§4.11.5 "oar or hybrid").
	var galleon := _ship("galleon")
	_check(BattleLib.equipment_item_modifier("", "durability") == 0,
		"an empty equipment slot contributes no durability (§4.11.12)")
	_check(_effective_max_durability(galleon) == 240,
		"a galleon's effective max durability is its base 240 (%d)"
		% _effective_max_durability(galleon))
	_check("hybrid" in BattleLib.OAR_SHIP_CLASSES,
		"hybrid hulls share the oar ram multiplier (§4.11.5)")

	# A ram that sinks both ships resolves the attacker last (§6).
	var last_sim := _sim({
		"player_ships": [_ship("brigantine", {"durability": 5})],
		"enemy_ships": [_ship("sloop", {"durability": 5})],
	})
	last_sim.start()
	var doomed := _unit(last_sim, "player", 0)
	var other := _unit(last_sim, "enemy", 0)
	_place(last_sim, "enemy", 0, Vector2i(2, 4))
	var both := last_sim.ram(doomed, other)
	_check(bool(both["sunk"]) and bool(both["attacker_sunk"]),
		"a ram can sink both ships")
	_check(last_sim.is_over() and str(last_sim.outcome()["result"]) == "defeat_sunk",
		"both sunk with the player flagship → defeat_sunk (§6, §4.11.9)")
	_check(str(last_sim.outcome()["sunk_enemy"]) == str(["sloop"]),
		"the enemy hull is reported sunk (%s)" % str(last_sim.outcome()["sunk_enemy"]))


## Effective max durability (§4.11.12) via a throwaway sim.
func _effective_max_durability(ship: Dictionary) -> int:
	return BattleLib.new({"player_ships": [], "enemy_ships": []}).effective_max_durability(ship)


# --- 7. Duel (§4.6, §4.11.6, §5) -----------------------------------------

func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func _test_duel() -> void:
	# §5: player combat 12 + cutlass 3 = base 15. `data/equipment.json` is
	# empty in this wave (task E owns it), so the +3 item is injected as a
	# test double and removed again — the wiring under test is the lookup.
	_stats(12)
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	_check(BattleLib.player_duel_base() == 12,
		"without worn equipment the player duel base is the effective combat (12 = %d)"
		% BattleLib.player_duel_base())

	var injected := {
		"id": "eq_test_cutlass",
		"name": {"zh": "试作弯刀", "en": "Test Cutlass"},
		"slot": "weapon",
		"modifiers": {"combat": 3},
		"price": 400,
		"phase": 2,
	}
	var existed := DataLoader.equipment.has("eq_test_cutlass")
	var previous = DataLoader.equipment.get("eq_test_cutlass", null)
	DataLoader.equipment["eq_test_cutlass"] = injected
	GameState.player["equipment"] = {"weapon": "eq_test_cutlass", "armor": ""}
	_check(BattleLib.player_duel_base() == 15,
		"§5 player base: combat 12 + cutlass combat 3 = 15 (got %d)"
		% BattleLib.player_duel_base())
	GameState.player["equipment"] = {"weapon": "eq_test_cutlass", "armor": "eq_test_cutlass"}
	_check(BattleLib.player_duel_base() == 18,
		"both worn slots stack their combat modifiers (18 = %d)"
		% BattleLib.player_duel_base())
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	if existed:
		DataLoader.equipment["eq_test_cutlass"] = previous
	else:
		DataLoader.equipment.erase("eq_test_cutlass")
	_check(DataLoader.get_equipment("eq_test_cutlass").is_empty(),
		"the injected equipment double is removed again")

	# Defender base = min(floor(crew/5), 20) + captain rating (§4.11.6).
	_check(BattleLib.defender_duel_base(50, 6) == 16,
		"defender base: floor(50/5) + (5 + pirate tier 1) = 16 (got %d)"
		% BattleLib.defender_duel_base(50, 6))
	_check(BattleLib.defender_duel_base(20, 6) == 10,
		"defender base for the §5 fixture (crew 20, pirate rating 6) is 10 (got %d)"
		% BattleLib.defender_duel_base(20, 6))
	_check(BattleLib.defender_duel_base(500, 6) == 26,
		"the crew term caps at 20: 20 + 6 = 26 (got %d)"
		% BattleLib.defender_duel_base(500, 6))
	_check(BattleLib.defender_duel_base(0, 7) == 7,
		"crew 0 leaves the captain rating alone (navy: 5 + tier 2 = 7)")

	# §5 scripted sequence: player base 15 (combat 12 + cutlass 3) vs a sloop
	# defender base 10 (crew 20 → 4, + pirate rating 6); seed 33 reproduces
	# win/loss/win/win, capture 3–1 ("best-of-5 decided 3-1").
	var capture := BattleLib.resolve_duel(15, 10, _rng(33))
	_check(str(capture["rounds"]) == str(["win", "loss", "win", "win"]),
		"seed 33 reproduces the §5 round sequence %s (got %s)"
		% [str(["win", "loss", "win", "win"]), str(capture["rounds"])])
	_check(str(capture["result"]) == "capture",
		"seed 33 takes the duel: capture (got %s)" % str(capture["result"]))
	_check(int(capture["player_wins"]) == 3 and int(capture["defender_wins"]) == 1,
		"the §5 duel ends 3–1 (%d–%d)"
		% [int(capture["player_wins"]), int(capture["defender_wins"])])
	_check(capture["rounds"].size() == 4,
		"a decided duel stops at the third win (4 rounds: %d)"
		% capture["rounds"].size())

	# Same seed, same sequence (determinism).
	var repeat := BattleLib.resolve_duel(15, 10, _rng(33))
	_check(repeat == capture, "the same seed replays the identical duel")

	# Both outcomes are reachable across seeds.
	var defeat := BattleLib.resolve_duel(15, 10, _rng(19))
	_check(str(defeat["result"]) == "defeat"
			and str(defeat["rounds"]) == str(["loss", "win", "loss", "loss"]),
		"seed 19 is the mirror image: loss/win/loss/loss, defeat (%s, %s)"
		% [str(defeat["rounds"]), str(defeat["result"])])
	var capture_also := BattleLib.resolve_duel(15, 10, _rng(2))
	_check(str(capture_also["result"]) == "capture",
		"a third seed also reaches capture (seed 2: %s)" % str(capture_also["result"]))
	_check("capture" in [_result_of(33), _result_of(19)],
		"both capture and defeat are reachable across seeds")

	# A tie round scores for neither side (§4.11.6).
	var with_tie := BattleLib.resolve_duel(15, 10, _rng(2))
	_check("tie" in with_tie["rounds"],
		"seed 2 produces a tie round (%s)" % str(with_tie["rounds"]))
	_check(int(with_tie["player_wins"]) == 3 and int(with_tie["defender_wins"]) == 0,
		"the tie round scored for neither side (3–0 with one tie: %d–%d)"
		% [int(with_tie["player_wins"]), int(with_tie["defender_wins"])])
	_check(with_tie["rounds"].count("win") == int(with_tie["player_wins"]),
		"round labels match the win counter (3 wins)")

	# Undecided after 5 rounds (only ties can cause it): equal counts → the
	# defender holds, so the boarding attempt fails (§4.11.6).
	var stuck := BattleLib.resolve_duel(15, 10, _rng(14))
	_check(stuck["rounds"].size() == 5,
		"an undecided duel runs the full 5 rounds (%d)" % stuck["rounds"].size())
	_check(int(stuck["player_wins"]) == int(stuck["defender_wins"]),
		"seed 14 ends level (%d–%d)"
		% [int(stuck["player_wins"]), int(stuck["defender_wins"])])
	_check(str(stuck["result"]) == "defeat",
		"level after 5 rounds → the defender holds (defeat: %s)" % str(stuck["result"]))


func _result_of(seed_value: int) -> String:
	return str(BattleLib.resolve_duel(15, 10, _rng(seed_value))["result"])


# --- 8. Boarding paths (§4.11.6, §4.11.7) --------------------------------

func _test_board_paths() -> void:
	_stats(12)
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	# Player base 12 vs a pirate sloop (crew 10 → floor(10/5)=2, +6 → 8).
	# Seed 2 gives win/loss/win/win → capture 3–1.
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"crew": 60})],
		"enemy_ships": [_ship("sloop", {"crew": 10, "cannons": 0})],
		"seed": 2,
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var enemy := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(2, 4))
	_check(sim.can_board(brig, enemy), "board targets an orthogonally adjacent ship")
	_check((sim.units()[0] as Dictionary).has("captain_rating"),
		"the AI captain rating is stored on the unit at battle start (§4.11.6)")
	_check(int(enemy["captain_rating"]) == 6,
		"pirate captain rating 5 + tier 1 = 6 (%d)" % int(enemy["captain_rating"]))
	_check(sim.defender_duel_base(10, 6) == 8,
		"the sloop's defender base is 2 + 6 = 8 (%d)"
		% sim.defender_duel_base(10, 6))
	var boarding := sim.board(brig, enemy)
	var duel: Dictionary = boarding["duel"]
	var expected := BattleLib.resolve_duel(12, 8, _rng(2))
	_check(duel == expected,
		"board() resolves through BattleSim.resolve_duel — same rolls as a direct call "
		+ "(%s vs %s)" % [str(duel), str(expected)])
	_check(str(duel["result"]) == "capture",
		"a won boarding captures the enemy ship (got %s)" % str(duel["result"]))
	_check(not bool(enemy["alive"]),
		"the captured enemy ship leaves the battle")
	_check(sim.is_over() and str(sim.outcome()["result"]) == "victory",
		"the last enemy captured → victory (%s)" % str(sim.outcome()["result"]))
	var captured: Array = sim.outcome()["captured_enemy"]
	_check(captured.size() == 1 and str(captured[0]["ship_type_id"]) == "sloop",
		"captured_enemy reports the intact ship instance (%s)" % str(captured))
	_check(int(captured[0]["durability"]) == 60,
		"the outcome ships the hull at its current durability (60); the §4.11.7 "
			+ "25%% transform belongs to the application seam (%d)"
			% int(captured[0]["durability"]))
	_check(sim.outcome()["cargo_overflow_lost"] == 0
			and int(sim.outcome()["xp"]) > 0,
		"the outcome block carries the §4.12.2 payload fields")

	# The mirror path: a weak player captain loses the boarding and the ship.
	_stats(0)
	var loss_sim := _sim({
		"player_ships": [_ship("latin", {"crew": 8}), _ship("sloop")],
		"enemy_ships": [_ship("galleon", {"crew": 150})],
		"seed": 19,
	})
	loss_sim.start()
	var victim := _unit(loss_sim, "player", 0)
	var strong := _unit(loss_sim, "enemy", 0)
	_place(loss_sim, "enemy", 0, Vector2i(2, 4))
	_begin_turn(loss_sim, "player", 0)
	var lost := loss_sim.board(victim, strong)
	_check(str(lost["duel"]["result"]) == "defeat",
		"a lost boarding is a `defeat` (%s)" % str(lost["duel"]["result"]))
	_check(int(lost["duel"]["defender_wins"]) == 3,
		"the strong defender reached 3 round wins (%d)"
		% int(lost["duel"]["defender_wins"]))
	_check(not bool(victim["alive"]), "the boarded-from player ship is taken")
	_check(loss_sim.is_over() == false,
		"the escort is still alive, so the battle continues")
	_check(loss_sim.flagship_index() == 1,
		"the next ship becomes the flagship (fleet[0] promotion, §4.6): index %d"
		% loss_sim.flagship_index())
	_check(loss_sim.flagship_unit() == _unit(loss_sim, "player", 1),
		"flagship_unit() now points at the surviving escort")

	# Losing the last ship to a boarding → defeat_captured (§4.11.9).
	var solo_sim := _sim({
		"player_ships": [_ship("latin", {"crew": 8})],
		"enemy_ships": [_ship("carrack", {"crew": 100})],
		"seed": 19,
	})
	solo_sim.start()
	var solo := _unit(solo_sim, "player", 0)
	var monster := _unit(solo_sim, "enemy", 0)
	_place(solo_sim, "enemy", 0, Vector2i(2, 4))
	_begin_turn(solo_sim, "player", 0)
	var final := solo_sim.board(solo, monster)
	_check(str(final["duel"]["result"]) == "defeat" and solo_sim.is_over(),
		"the last ship lost to boarding ends the battle")
	_check(str(solo_sim.outcome()["result"]) == "defeat_captured",
		"last ship captured → defeat_captured (%s)" % str(solo_sim.outcome()["result"]))
	_check(solo_sim.outcome()["lost_player"].size() == 1,
		"lost_player reports the taken ship instance")


# --- 9. Enemy composition (§4.11.3) --------------------------------------

func _test_compose_enemy() -> void:
	var budget_ok := true
	var slots_ok := true
	var hulls_ok := true
	var cargo_ok := true
	var count_ok := true
	var never_empty := true
	var goods_ids: Array = []
	for entry in DataLoader.goods_list:
		goods_ids.append(str(entry.get("id", "")))
	for seed_value in range(1, 61):
		for kind in ["pirate", "navy"]:
			var rng_a := _rng(seed_value)
			var rng_b := _rng(seed_value)
			var fleet_a := AiLib.compose_enemy(kind, 45, rng_a)
			var fleet_b := AiLib.compose_enemy(kind, 45, rng_b)
			if JSON.stringify(fleet_a) != JSON.stringify(fleet_b):
				never_empty = false
			if fleet_a.is_empty():
				never_empty = false
			var expected_budget := (20 if kind == "pirate" else 30) + int(floor(45.0 / 30.0))
			var total_cannons := 0
			for ship in fleet_a:
				if not (str(ship.get("ship_type_id", "")) in AiLib.HULL_IDS):
					hulls_ok = false
				var slots := int(DataLoader.get_ship_type(str(ship["ship_type_id"]))["armament_slots"])
				if int(ship["cannons"]) > slots:
					slots_ok = false
				total_cannons += int(ship["cannons"])
				var capacity := int(DataLoader.get_ship_type(str(ship["ship_type_id"]))["capacity"])
				var expected_qty := maxi(1, int(floor(float(capacity) / 10.0)))
				var cargo: Dictionary = ship["cargo"]
				if cargo.size() != 1:
					cargo_ok = false
				else:
					var good_id: String = str(cargo.keys()[0])
					if not (good_id in goods_ids) or int(cargo[good_id]) != expected_qty:
						cargo_ok = false
				if int(ship["crew"]) != int(DataLoader.get_ship_type(
						str(ship["ship_type_id"]))["crew_min"]):
					count_ok = false
				if int(ship["durability"]) != int(DataLoader.get_ship_type(
						str(ship["ship_type_id"]))["durability"]):
					count_ok = false
				if ship["equipment"] != {"figurehead": "", "sail": ""}:
					count_ok = false
			if total_cannons > expected_budget:
				budget_ok = false
			var size := fleet_a.size()
			if kind == "pirate" and (size < 1 or size > 3):
				count_ok = false
			if kind == "navy" and (size < 2 or size > 4):
				count_ok = false
	_check(never_empty, "compose_enemy is deterministic for the same seed (60 seeds × 2 kinds)")
	_check(hulls_ok, "every hull id comes from the locked 4-hull order (§4.11.3)")
	_check(slots_ok, "no ship exceeds its armament_slots (§4.11.3)")
	_check(budget_ok, "total cannons stay within 20/30 + floor(day/30) (§4.11.3)")
	_check(cargo_ok, "each ship carries max(1, floor(capacity/10)) of one locked good")
	_check(count_ok, "crews = crew_min, durability = max, equipment empty; counts 1–3/2–4")

	# One concrete fleet, pinned so a regression names a number.
	var sample := AiLib.compose_enemy("pirate", 45, _rng(7))
	var summary: Array = []
	for ship in sample:
		summary.append("%s/%d" % [str(ship["ship_type_id"]), int(ship["cannons"])])
	_check(sample.size() >= 1 and sample.size() <= 3,
		"seed 7 pirate fleet has 1–3 hulls: %s" % str(summary))
	var dealt := 0
	var slot_capacity := 0
	for ship in sample:
		dealt += int(ship["cannons"])
		slot_capacity += int(DataLoader.get_ship_type(
			str(ship["ship_type_id"]))["armament_slots"])
	_check(dealt == mini(AiLib.cannon_budget("pirate", 45), slot_capacity),
		"seed 7 deals min(budget, total armament_slots) = min(21, %d) cannons (%s)"
		% [slot_capacity, str(summary)])

	# Budget grows with the day (§4.11.3): `+ floor(day / 30)`.
	_check(AiLib.cannon_budget("pirate", 0) == 20 and AiLib.cannon_budget("pirate", 59) == 21,
		"pirate budget 20 + floor(day/30): 20 at day 0, 21 at day 59")
	_check(AiLib.cannon_budget("navy", 0) == 30 and AiLib.cannon_budget("navy", 90) == 33,
		"navy budget 30 + floor(day/30): 30 at day 0, 33 at day 90")
	var early := AiLib.compose_enemy("navy", 90, _rng(7))
	var early_total := 0
	var early_slots := 0
	for ship in early:
		early_total += int(ship["cannons"])
		early_slots += int(DataLoader.get_ship_type(
			str(ship["ship_type_id"]))["armament_slots"])
	_check(early_total <= 33 and early_total == mini(33, early_slots),
		"a day-90 navy fleet never exceeds the 33-cannon budget (%d of %d slots)"
		% [early_total, early_slots])


# --- 10. AI rules (§4.9, §4.11.8) ---------------------------------------

func _test_ai_rules() -> void:
	_stats(10)
	# Rule 1: below 25% max durability with a player ship within 3 → surrender.
	var r1 := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("sloop", {"durability": 14})],
	})
	r1.start()
	_place(r1, "enemy", 0, Vector2i(8, 4))
	_place(r1, "player", 0, Vector2i(5, 4))
	var decision := AiLib.decide(r1, _unit(r1, "enemy", 0))
	_check(str(decision["action"]) == "surrender",
		"AI rule 1: 14/60 durability with a player 3 tiles away surrenders (got %s)"
		% str(decision["action"]))
	# Just above the threshold the same ship does not surrender.
	var r1b := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("sloop", {"durability": 15})],
	})
	r1b.start()
	_place(r1b, "enemy", 0, Vector2i(8, 4))
	_place(r1b, "player", 0, Vector2i(5, 4))
	_check(str(AiLib.decide(r1b, _unit(r1b, "enemy", 0))["action"]) != "surrender",
		"AI rule 1 boundary: 15/60 = 25% is not below the threshold")

	# Rule 2: cannons loaded + in range → fire at the lowest durability.
	var r2 := _sim({
		"player_ships": [
			_ship("sloop", {"durability": 50}),
			_ship("latin", {"durability": 12}),
		],
		"enemy_ships": [_ship("caravel", {"cannons": 6})],
	})
	r2.start()
	_place(r2, "enemy", 0, Vector2i(8, 4))
	_place(r2, "player", 0, Vector2i(6, 4))
	_place(r2, "player", 1, Vector2i(7, 6))
	var fire := AiLib.decide(r2, _unit(r2, "enemy", 0))
	_check(str(fire["action"]) == "cannon",
		"AI rule 2: a loaded cannon with a target in range fires (got %s)"
		% str(fire["action"]))
	_check(not (fire["target"] as Dictionary).is_empty()
			and int(fire["target"]["index"]) == 1,
		"AI rule 2 targets the lowest-durability ship (index %d)"
		% int((fire["target"] as Dictionary).get("index", -1)))
	# Tie on durability → the lower fleet index (§4.11.8).
	var r2b := _sim({
		"player_ships": [_ship("sloop"), _ship("sloop")],
		"enemy_ships": [_ship("caravel", {"cannons": 6})],
	})
	r2b.start()
	_place(r2b, "enemy", 0, Vector2i(8, 4))
	_place(r2b, "player", 0, Vector2i(6, 4))
	_place(r2b, "player", 1, Vector2i(7, 6))
	var tie := AiLib.decide(r2b, _unit(r2b, "enemy", 0))
	_check(str(tie["action"]) == "cannon" and int(tie["target"]["index"]) == 0,
		"AI rule 2 tie-break: equal durability → lower fleet index (index %d)"
		% int(tie["target"]["index"]))

	# Rule 3: own cannons > total player cannons, adjacent to the flagship,
	# reloading (so rule 2 cannot fire first) → board.
	var r3 := _sim({
		"player_ships": [_ship("sloop", {"cannons": 1})],
		"enemy_ships": [_ship("brigantine", {"cannons": 6})],
	})
	r3.start()
	_place(r3, "enemy", 0, Vector2i(2, 4))
	var boarder := _unit(r3, "enemy", 0)
	boarder["reload_until_round"] = 99
	var boarding := AiLib.decide(r3, boarder)
	_check(str(boarding["action"]) == "board",
		"AI rule 3: 6 cannons > 1 player cannon, adjacent to the flagship → board (got %s)"
		% str(boarding["action"]))
	_check(int((boarding["target"] as Dictionary).get("index", -1)) == 0,
		"AI rule 3 boards the player flagship (index 0)")

	# Rule 4: adjacent with weaker guns → ram (reloading, so not rule 2).
	var r4 := _sim({
		"player_ships": [_ship("caravel", {"cannons": 6})],
		"enemy_ships": [_ship("sloop", {"cannons": 2})],
	})
	r4.start()
	_place(r4, "enemy", 0, Vector2i(2, 4))
	var rammer := _unit(r4, "enemy", 0)
	rammer["reload_until_round"] = 99
	var ramming := AiLib.decide(r4, rammer)
	_check(str(ramming["action"]) == "ram",
		"AI rule 4: weaker guns adjacent → ram (got %s)" % str(ramming["action"]))
	_check(int((ramming["target"] as Dictionary).get("index", -1)) == 0,
		"AI rule 4 rams the adjacent player ship")

	# Rule 5: move toward the nearest player ship, spending MP.
	var r5 := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("brigantine", {"cannons": 0})],
	})
	r5.start()
	var mover := _begin_turn(r5, "enemy", 0)
	var before := r5.unit_cell(mover)
	var advance := AiLib.decide(r5, mover)
	_check(str(advance["action"]) == "move",
		"AI rule 5: no shot, no adjacency → move (got %s)" % str(advance["action"]))
	var destination: Vector2i = advance["cell"]
	var target_cell := r5.unit_cell(_unit(r5, "player", 0))
	_check(maxi(absi(destination.x - target_cell.x), absi(destination.y - target_cell.y))
			< maxi(absi(before.x - target_cell.x), absi(before.y - target_cell.y)),
		"AI rule 5 closes the Chebyshev distance (%s → %s, target %s)"
		% [str(before), str(destination), str(target_cell)])
	_check(r5.legal_moves(mover).has(destination),
		"AI rule 5 only proposes a legal, reachable tile")
	_check(r5.move_to(mover, destination),
		"AI rule 5's move is accepted by the engine")
	_check(int(mover["mp"]) == 0,
		"AI rule 5 spends its MP (a 6-MP brigantine spends 6, %d left)"
		% int(mover["mp"]))

	# Rule 6: nothing improves → hold.
	var r6 := _sim({
		"player_ships": [_ship("sloop", {"cannons": 0})],
		"enemy_ships": [_ship("sloop", {"cannons": 0})],
	})
	r6.start()
	_place(r6, "enemy", 0, Vector2i(2, 4))
	_check(str(AiLib.decide(r6, _unit(r6, "enemy", 0))["action"]) == "hold",
		"AI rule 6: zero cannons, already adjacent, no improvement → hold")
	# …and a ship that cannot close (cornered by the grid edge is impossible on
	# open sea, so the hold case is exercised through an equal-cannon adjacency).
	var cornered := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 3})],
		"enemy_ships": [_ship("brigantine", {"cannons": 3})],
	})
	cornered.start()
	_place(cornered, "enemy", 0, Vector2i(15, 0))
	_place(cornered, "player", 0, Vector2i(9, 0))
	var close_in := AiLib.decide(cornered, _begin_turn(cornered, "enemy", 0))
	_check(str(close_in["action"]) == "move",
		"equal cannons and a valid approach still moves (rule 5)")

	# A surrendered AI ship resolves as a capture (§4.7).
	var surrender_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("latin", {"durability": 2})],
	})
	surrender_sim.start()
	_place(surrender_sim, "enemy", 0, Vector2i(4, 4))
	_place(surrender_sim, "player", 0, Vector2i(3, 4))
	_begin_turn(surrender_sim, "enemy", 0)
	var policy := func(sim) -> Dictionary:
		return AiLib.decide(sim, sim.current_unit())
	var result := surrender_sim.run_to_completion(policy, 5)
	_check(str(result["result"]) == "victory",
		"an AI surrender is a victory like a capture (got %s)" % str(result["result"]))
	_check(int(result["surrendered_enemy"]) == 1,
		"the surrender counter reports 1 (%d)" % int(result["surrendered_enemy"]))
	_check(result["captured_enemy"].size() == 1,
		"the surrendered hull is reported as captured")


# --- 11. Full headless battle --------------------------------------------

func _test_full_battle() -> void:
	_stats(14)
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 40})]
	var player_fleet := fleet.duplicate(true)
	var enemy: Array = AiLib.compose_enemy("pirate", 12, _rng(11))
	var original_enemy := enemy.duplicate(true)
	var sim := _sim({
		"player_ships": fleet,
		"enemy_ships": enemy,
		"day": 12,
		"gold": 3000,
		"contact": Vector2i(30, 40),
	})
	_check(sim.seed_value() == BattleLib.battle_seed_formula(12, Vector2i(30, 40), 3000, 1),
		"the §4.11.1 seed formula is used when no override is given (%d)"
		% sim.seed_value())
	sim.start()
	# Lambdas capture locals by value, so the observation state is a member
	# (a lambda assignment to a local would be silently discarded).
	_sizes_ok = true
	_previous_sizes = {
		"player": sim.living_units("player").size(),
		"enemy": sim.living_units("enemy").size(),
	}
	var policy := func(active_sim) -> Dictionary:
		var current: Dictionary = active_sim.current_unit()
		var player_living: int = active_sim.living_units("player").size()
		var enemy_living: int = active_sim.living_units("enemy").size()
		if player_living > int(_previous_sizes["player"]) \
				or enemy_living > int(_previous_sizes["enemy"]):
			_sizes_ok = false
		_previous_sizes["player"] = player_living
		_previous_sizes["enemy"] = enemy_living
		if str(current["side"]) == "enemy":
			return AiLib.decide(active_sim, current)
		return _player_policy(active_sim, current)
	var outcome := sim.run_to_completion(policy, 30)
	_check(sim.is_over(), "the headless battle reaches is_over() within 30 rounds")
	_check(str(outcome["result"]) in BattleLib.RESULT_VALUES,
		"outcome().result is one of the §4.11.9 values (%s)" % str(outcome["result"]))
	_check(int(outcome["rounds"]) >= 1 and int(outcome["rounds"]) <= 30,
		"the battle lasted %d rounds" % int(outcome["rounds"]))
	_check(_sizes_ok, "squad sizes never grow during the battle")
	_check(int(outcome["xp"]) >= BattleLib.XP_PER_ENEMY_NEUTRALIZED,
		"the outcome carries battle XP (%d)" % int(outcome["xp"]))
	_check(outcome.has("rep_deltas") and outcome.has("salvage_gold"),
		"the outcome block carries the §4.12.2 reward fields")

	# The engine never touched the caller's ships (§4.12.1 "never mutates").
	_check(JSON.stringify(fleet) == JSON.stringify(player_fleet),
		"the caller's player ships are untouched by the battle")
	_check(JSON.stringify(enemy) == JSON.stringify(original_enemy),
		"the caller's enemy ships are untouched by the battle")
	_check(sim.current_unit().is_empty(), "current_unit() is {} once the battle is over")

	# An explicit seed override is honoured (tests/audit, §4.12.1 config).
	var seeded := _sim({"player_ships": [_ship("sloop")], "enemy_ships": [_ship("sloop")], "seed": 4242})
	seeded.start()
	_check(seeded.seed_value() == 4242, "a config seed overrides the §4.11.1 formula")

	# Retreat and player surrender are the two menu-only outcomes.
	var retreat_sim := _sim({"player_ships": [_ship("sloop")], "enemy_ships": [_ship("sloop")]})
	retreat_sim.start()
	var retreat_outcome := retreat_sim.retreat()
	_check(str(retreat_outcome["result"]) == "retreat", "retreat() → result \"retreat\"")
	_check(int(retreat_outcome["xp"]) == 0,
		"a retreat costs no XP (§4.10): xp %d" % int(retreat_outcome["xp"]))
	var pirate_sim := _sim({"player_ships": [_ship("sloop")], "enemy_ships": [_ship("sloop")]})
	pirate_sim.start()
	var pirate_outcome := pirate_sim.offer_surrender()
	_check(str(pirate_outcome["result"]) == "surrender",
		"player surrender to pirates → result \"surrender\"")
	_check(pirate_outcome["lost_player"].is_empty(),
		"a pirate surrender takes the hold, not the hulls (§4.11.7)")
	var navy_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("sloop")],
		"enemy_kind": "navy",
		"enemy_nation": "spain",
	})
	navy_sim.start()
	var navy_outcome := navy_sim.offer_surrender()
	_check(str(navy_outcome["result"]) == "defeat_captured",
		"surrendering the last ship to a navy → defeat_captured (§4.11.7): %s"
		% str(navy_outcome["result"]))
	_check(navy_outcome["lost_player"].size() == 1,
		"the navy surrender takes the flagship hull")


## A simple player policy: fire when possible, else board/ram when adjacent,
## else close the distance; never grows a squad.
func _player_policy(sim: BattleLib, unit: Dictionary) -> Dictionary:
	var enemies := sim.living_units("enemy")
	if enemies.is_empty():
		return {"action": "hold", "target": {}, "cell": BattleLib.NO_CELL}
	var boardable := {}
	for enemy in enemies:
		if sim.can_cannon(unit, enemy):
			return {"action": "cannon", "target": enemy, "cell": BattleLib.NO_CELL}
		if sim.can_board(unit, enemy):
			boardable = enemy
	if not boardable.is_empty():
		return {"action": "board", "target": boardable, "cell": BattleLib.NO_CELL}
	var origin := sim.unit_cell(unit)
	var nearest: Dictionary = enemies[0]
	var best := maxi(absi(origin.x - sim.unit_cell(nearest).x),
		absi(origin.y - sim.unit_cell(nearest).y))
	for enemy in enemies:
		var cell := sim.unit_cell(enemy)
		var distance := maxi(absi(origin.x - cell.x), absi(origin.y - cell.y))
		if distance < best:
			best = distance
			nearest = enemy
	var target_cell := sim.unit_cell(nearest)
	var destination := BattleLib.NO_CELL
	var best_distance := best
	for cell in sim.legal_moves(unit):
		var distance := maxi(absi(cell.x - target_cell.x), absi(cell.y - target_cell.y))
		if distance < best_distance:
			best_distance = distance
			destination = cell
	if destination != BattleLib.NO_CELL:
		return {"action": "move", "target": {}, "cell": destination}
	return {"action": "hold", "target": {}, "cell": BattleLib.NO_CELL}


# --- 12. Turn pins, salvage, equipment (§4.11.4, §4.11.10, §4.11.12) ----

func _test_turn_and_equipment_pins() -> void:
	_stats(10)
	# One action per turn: after a volley neither a second volley nor a ram.
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("caravel"), _ship("sloop")],
	})
	sim.start()
	var brig := _unit(sim, "player", 0)
	var caravel := _unit(sim, "enemy", 0)
	var sloop := _unit(sim, "enemy", 1)
	_place(sim, "enemy", 0, Vector2i(3, 4))
	_place(sim, "enemy", 1, Vector2i(1, 3))
	_check(bool(sim.cannon(brig, caravel)["ok"]), "the volley is the turn's action")
	var second := sim.cannon(brig, caravel)
	_check(not bool(second["ok"]), "a second cannon in the same turn is refused")
	var bump := sim.ram(brig, sloop)
	_check(not bool(bump["ok"]), "a ram after a cannon is refused (one action per turn)")
	_check(not sim.move_to(brig, Vector2i(1, 5)),
		"movement after the action is refused (move then act, §4.3)")
	_check(not bool(sim.hold(brig)["ok"]), "hold is also refused after an action")

	# Hold spends the action; the next ship then acts.
	var hold_sim := _sim({
		"player_ships": [_ship("brigantine"), _ship("sloop")],
		"enemy_ships": [_ship("latin")],
	})
	hold_sim.start()
	_check(bool(hold_sim.hold(hold_sim.current_unit())["ok"]), "hold succeeds on a fresh turn")
	hold_sim.end_turn()
	_check(int(hold_sim.current_unit()["index"]) == 1 or str(hold_sim.current_unit()["side"]) == "enemy",
		"after hold + end_turn the next unit acts")

	# §4.11.4 occupancy: a wall of occupied tiles cannot be passed through.
	# Runner at (1,4); escorts at (2,3), (2,4), (2,5) wall off the east side.
	var walled := _sim({
		"player_ships": [
			_ship("brigantine"), _ship("sloop"), _ship("sloop"), _ship("sloop"),
		],
		"enemy_ships": [_ship("latin")],
	})
	walled.start()
	var pinned := _unit(walled, "player", 0)
	_place(walled, "player", 1, Vector2i(2, 4))
	_place(walled, "player", 2, Vector2i(2, 3))
	_place(walled, "player", 3, Vector2i(2, 5))
	var pinned_moves := walled.legal_moves(pinned)
	_check(not pinned_moves.has(Vector2i(2, 4)) and not pinned_moves.has(Vector2i(2, 3)),
		"occupied tiles are never reachable (escorts at (2,3)/(2,4)/(2,5))")
	_check(not walled.move_to(pinned, Vector2i(2, 4)),
		"moving into the wall is refused (occupied tile)")
	# (3,4) is normally a 2-MP straight line east; reaching it now costs 6 MP
	# via (1,3) → (2,2) → (3,3) → (3,4), which proves the wall is impenetrable
	# (a pass-through would have cost 2 and left 4 MP).
	_check(pinned_moves.has(Vector2i(3, 4)) and not pinned_moves.has(Vector2i(4, 4)),
		"the wall must be sailed around: (3,4) costs 6 MP, so (4,4) is out of reach")
	_check(not pinned_moves.has(Vector2i(4, 4)),
		"a ship can never pass through an occupied tile: (4,4) unreachable")
	_check(pinned_moves.has(Vector2i(1, 3)),
		"the free west/north tiles stay reachable around the wall")

	# §4.11.10 salvage: Σ floor(base_price × 0.05) over ships sunk by the player.
	var salvage_sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"durability": 4})],
	})
	salvage_sim.start()
	var gunner := _unit(salvage_sim, "player", 0)
	var wreck := _unit(salvage_sim, "enemy", 0)
	_place(salvage_sim, "enemy", 0, Vector2i(3, 4))
	_check(bool(salvage_sim.cannon(gunner, wreck)["sunk"]), "the sloop sinks to one volley")
	var sunk_outcome := salvage_sim.outcome()
	var sloop_price := int(DataLoader.get_ship_type("sloop")["base_price"])
	_check(int(sunk_outcome["salvage_gold"]) == int(floor(sloop_price * 0.05)),
		"salvage is floor(%d × 0.05) = %d (%d)"
		% [sloop_price, int(floor(sloop_price * 0.05)), int(sunk_outcome["salvage_gold"])])
	_check(int(sunk_outcome["xp"]) == _doc_xp(1, 1),
		"battle XP: 10 per neutralised ship + 5 per round = %d (%d)"
		% [_doc_xp(1, 1), int(sunk_outcome["xp"])])
	_check(not sunk_outcome["rep_deltas"].is_empty(),
		"defeating pirates credits the nearest ports' nations (%s)"
		% str(sunk_outcome["rep_deltas"]))

	# outcome() is {} before is_over() (§4.12.1).
	var pending := _sim({"player_ships": [_ship("sloop")], "enemy_ships": [_ship("sloop")]})
	pending.start()
	_check(pending.outcome().is_empty(), "outcome() is {} while the battle runs")

	# A capped run reports "unfinished" instead of a fake outcome.
	var long_sim := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("sloop")],
	})
	long_sim.start()
	var stalemate := func(active_sim) -> Dictionary:
		return {"action": "hold", "target": {}, "cell": BattleLib.NO_CELL}
	var capped := long_sim.run_to_completion(stalemate, 3)
	_check(not long_sim.is_over() and str(capped["result"]) == "",
		"a held battle under max_rounds=3 is reported unfinished (%s)" % str(capped))
	_check(int(capped["rounds"]) >= 3 and int(capped["rounds"]) <= 4,
		"the round cap is respected (stopped at round %d, max_rounds 3)"
		% int(capped["rounds"]))

	# §4.11.12 sail: +1 speed → +1 MP and earlier initiative.
	# §4.11.12 figurehead: +durability is the ram base.
	var sail_id := "eq_test_storm_sails"
	var figurehead_id := "eq_test_figurehead"
	var injected := [
		{"id": sail_id, "name": {"zh": "试作帆", "en": "Test Sails"}, "slot": "sail",
			"modifiers": {"speed": 1}, "price": 1, "phase": 2},
		{"id": figurehead_id, "name": {"zh": "试作船首像", "en": "Test Figurehead"},
			"slot": "figurehead", "modifiers": {"durability": 20}, "price": 1, "phase": 2},
	]
	var saved := {}
	for item in injected:
		saved[item["id"]] = DataLoader.equipment.get(item["id"], null)
		DataLoader.equipment[item["id"]] = item

	var gear := _sim({
		"player_ships": [_ship("latin", {"equipment": {"figurehead": "", "sail": sail_id}})],
		"enemy_ships": [_ship("latin")],
	})
	gear.start()
	var fast := _unit(gear, "player", 0)
	_check(gear.effective_speed(fast) == 5,
		"a sail's +1 speed raises the latin's 4 to 5 (%d)" % gear.effective_speed(fast))
	_check(int(fast["mp"]) == 5, "the sail bonus also raises MP (%d)" % int(fast["mp"]))
	_check(gear.current_unit() == fast,
		"the faster ship takes the initiative on a speed tie (sail 5 vs 4)")

	var heavy := _sim({
		"player_ships": [_ship("galley", {"equipment": {"figurehead": figurehead_id, "sail": ""}})],
		"enemy_ships": [_ship("sloop")],
	})
	heavy.start()
	var rammer := _unit(heavy, "player", 0)
	var victim := _unit(heavy, "enemy", 0)
	_check(heavy.effective_max_durability(rammer["ship"]) == 90,
		"the figurehead's +20 durability raises the galley's 70 to 90 (%d)"
		% heavy.effective_max_durability(rammer["ship"]))
	_place(heavy, "enemy", 0, Vector2i(2, 4))
	var heavy_hit := heavy.ram(rammer, victim)
	_check(int(heavy_hit["damage"]) == 27,
		"ram uses the effective max: floor(floor(0.25 × 90) × 1.25) = 27 (got %d)"
		% int(heavy_hit["damage"]))
	_check(int(heavy_hit["attacker_damage"]) == 9,
		"attacker self damage uses the effective max: floor(0.10 × 90) = 9 (got %d)"
		% int(heavy_hit["attacker_damage"]))

	for item in injected:
		if saved[item["id"]] == null:
			DataLoader.equipment.erase(item["id"])
		else:
			DataLoader.equipment[item["id"]] = saved[item["id"]]
	_check(DataLoader.get_equipment(sail_id).is_empty(),
		"the injected equipment doubles are removed again")


## The §4.11.10 XP formula: 10 per neutralised ship + 5 per round survived.
func _doc_xp(neutralized: int, rounds: int) -> int:
	return neutralized * BattleLib.XP_PER_ENEMY_NEUTRALIZED + rounds * BattleLib.XP_PER_ROUND


# --- 13. §4.11.1 seed audit ----------------------------------------------

func _test_seed_audit() -> void:
	_stats(14)
	# The whole battle must be reproducible from the §4.11.1 formula alone:
	# deployment → composition → duel rolls, all from one stream.
	var seed_value := BattleLib.battle_seed_formula(12, Vector2i(30, 40), 3000, 1)
	_check(seed_value == 12 * 1000003 + 30 * 7919 + 40 * 104729 + 3000 * 31 + 1 * 17,
		"§4.11.1 seed arithmetic: day×1000003 + x×7919 + y×104729 + gold×31 + n×17 = %d"
		% seed_value)

	var composition_rng := _rng(seed_value)
	var composed := AiLib.compose_enemy("pirate", 12, composition_rng)
	var composed_again := AiLib.compose_enemy("pirate", 12, _rng(seed_value))
	_check(JSON.stringify(composed) == JSON.stringify(composed_again),
		"the same §4.11.1 seed reproduces the enemy composition")

	# A sim handed the *same* rng object continues the stream where
	# composition stopped — that is what makes duel rolls reproducible after
	# deployment + composition (§4.11.1).
	var shared_rng := _rng(seed_value)
	var fleet := AiLib.compose_enemy("pirate", 12, shared_rng)
	# A second stream walked through the identical composition gives the
	# reference duel without touching `shared_rng`.
	var reference_rng := _rng(seed_value)
	AiLib.compose_enemy("pirate", 12, reference_rng)
	var expected_duel := BattleLib.resolve_duel(15, 10, reference_rng)

	var streamed := BattleLib.new({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": fleet,
		"enemy_kind": "pirate", "day": 12, "gold": 3000,
		"contact": Vector2i(30, 40), "weather": "calm", "rng": shared_rng,
	})
	streamed.start()
	var duel := BattleLib.resolve_duel(15, 10, streamed.rng)
	_check(duel == expected_duel,
		"the stream continues into the duel: identical round sequence %s"
		% str(duel["rounds"]))

	# A full scripted battle replayed twice from the seed gives the same log.
	var first := _scripted_battle(seed_value)
	var second := _scripted_battle(seed_value)
	_check(JSON.stringify(first) == JSON.stringify(second),
		"a whole scripted battle (AI both sides) replays identically from the seed")
	_check(not first.is_empty() and str(first["result"]) in BattleLib.RESULT_VALUES,
		"the replayed battle ends with a §4.11.9 result (%s)" % str(first["result"]))

	# Robustness sweep: 60 seeded battles (pirates + navies) must all terminate
	# with a legal result and never exceed the round cap.
	var legal := true
	var terminated := true
	var counts := {}
	for kind in ["pirate", "navy"]:
		for seed_offset in range(1, 31):
			var battle_seed := 900000 + seed_offset
			var swarm_rng := _rng(battle_seed)
			var foes := AiLib.compose_enemy(kind, 20, swarm_rng)
			var sweep := BattleLib.new({
				"player_ships": [
					_ship("brigantine", {"cannons": 8, "crew": 45}),
					_ship("sloop", {"cannons": 3}),
				],
				"enemy_ships": foes,
				"enemy_kind": kind,
				"enemy_nation": "spain" if kind == "navy" else "",
				"day": 20, "gold": 500, "contact": Vector2i(30, 40),
				"weather": "calm", "rng": swarm_rng,
			})
			sweep.start()
			var sweep_policy := func(active_sim) -> Dictionary:
				var current: Dictionary = active_sim.current_unit()
				if str(current["side"]) == "enemy":
					return AiLib.decide(active_sim, current)
				return _player_policy(active_sim, current)
			var sweep_outcome := sweep.run_to_completion(sweep_policy, 30)
			if not sweep.is_over() or int(sweep_outcome.get("rounds", 0)) > 30:
				terminated = false
			# The caller's arrays are re-read after every battle: a simulated
			# battle must never leak into the fleet the caller handed over.
			if JSON.stringify(foes) != JSON.stringify(
					AiLib.compose_enemy(kind, 20, _rng(battle_seed))):
				legal = false
			var sweep_result := str(sweep_outcome.get("result", ""))
			if not (sweep_result in BattleLib.RESULT_VALUES):
				legal = false
			counts[sweep_result] = int(counts.get(sweep_result, 0)) + 1
	_check(terminated, "60 seeded battles all finish inside the 30-round cap")
	_check(legal, "every sweep outcome is a §4.11.9 result value (%s)" % str(counts))
	_check(counts.size() >= 2,
		"the sweep exercises more than one outcome path (%s)" % str(counts))


## Runs a one-player-vs-AI battle with the shared player policy and returns
## the outcome. Used twice to prove §4.11.1 reproducibility end-to-end.
func _scripted_battle(seed_value: int) -> Dictionary:
	var sim := _sim({
		"player_ships": [
			_ship("brigantine", {"cannons": 10, "crew": 40}),
			_ship("sloop", {"cannons": 4}),
		],
		"enemy_ships": AiLib.compose_enemy("pirate", 12,
			_rng(seed_value)),
		"day": 12, "gold": 3000, "contact": Vector2i(30, 40),
		"seed": seed_value,
	})
	sim.start()
	var policy := func(active_sim) -> Dictionary:
		var current: Dictionary = active_sim.current_unit()
		if str(current["side"]) == "enemy":
			return AiLib.decide(active_sim, current)
		return _player_policy(active_sim, current)
	return sim.run_to_completion(policy, 30)


# --- Harness --------------------------------------------------------------

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
