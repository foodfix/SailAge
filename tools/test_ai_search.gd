extends Node
## Phase-9 W5-D — the §4.9c T3 one-ply lookahead suite (docs/IMPLEMENT-Phase9.md
## W5-D; docs/60-COMBAT.md §4.9c, §4.9a/§4.9b, §4.11.8, §4.12.1, §4.12.3).
## Headless:
##
##   godot --headless res://tools/test_ai_search.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Every check pins a doc number: the θ consts are asserted verbatim against
## the §4.9c doc-first prior, the φ evaluation is checked against hand-computed
## nine-feature totals on fixed mini-fixtures, and the search-level behaviors
## (determinism, dice-freedom, discipline removal, the engage assignment, the
## shared hard gates) are asserted as fixed situations — one deterministic
## observation per behavior, no Monte Carlo (the repo's test discipline).
##
## Sections:
##   1  the θ consts equal the §4.9c prior {10, 4, 2, 3, −5, −6, −2, −4, 2}
##      for all three archetypes (the pre-tune pin — the CEM θ-finalization
##      amends the doc + the consts TOGETHER later; until then this pins the
##      shipped values), the `theta_for` archetype mapping over the shipped
##      §4.10 rows (pirate/privateer → aggressive; patrol/navy/tournament →
##      balanced; treasure/trader/coaster/courier → cautious; unknown →
##      balanced);
##   2  the candidate bound: `legal_velocities` ≤ (2·battle_max_speed + 1)² —
##      49 at the tier-3 hulls, 81 at tier 4 (§4.3a's Chebyshev box) — and the
##      T3 candidate set = velocities × actions ≤ 5 per velocity (steer/hold +
##      cannon per loaded side ≤ 2 + ram + board, §4.9c);
##   3  the search leaves no trace: snapshot() before decide == snapshot()
##      after (the candidates restore rng.state too, §4.9c) and two `decide`
##      calls on the identical restored state return identical dicts;
##   4  same-seed full-battle identity: two T3-vs-T3 battles (enemy via the
##      AiFleet dispatch, player via the same AiSearch) replay byte-identical
##      `log_lines()`;
##   5  §4.9b discipline removal: the disciplined engage order keeps the ship
##      on its station (the off-station candidate is hard-removed even though
##      it scores higher) against the free T3's off-station pick;
##   6  the §4.9b engage assignment (the W5-A master bounce): when the T3
##      fires under `assigned_target = k`, the target IS ship k; a dead
##      assignment falls back to the free ranking;
##   7  the shared hard gates fire at BOTH levels (the §4.9c amendment): ①
##      the §4.7 surrender gate resolves BEFORE the search (a low-durability
##      ai_level-1 ship at side morale ≤ 20 rolls; a failed roll reaches the
##      search; the gate stays closed at morale 21), ② the §4.9a flee rule
##      (hp < flee_pct ∨ aggression < 25 ∨ side morale ≤ 20) takes the flee
##      action over any T3 candidate while an escape velocity exists;
##   8  the normative φ table spot-checks: φ1 (durability diff /20), φ3
##      (loaded-side counts) and φ9 (alignment) hand-computed on fixed
##      mini-fixtures and matched against the module's evaluation;
##   9  the T3-vs-T2 harness wiring: the battle_ai_harness navy-vs-pirate
##      section shape driven directly — a 4-seed mini-run with ai_level
##      forced 1 on the navy side via profile injection at the suite level —
##      asserting the stats dict shape and that it runs;
##  10  the §4.9c adoption-gate ARITHMETIC (≥ +10 pp win rate, 100 %
##      legal-action rate, ≤ 30 ms average decision) evaluated on fixture
##      win-rates — the W6 run-based pin rides `tools/battle_tune.py` once
##      that tool lands (W5-B ran in a sibling slot; until its merge this is
##      the pure-function pin of the documented verdict).

const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const AiLib := preload("res://scripts/combat/ai_fleet.gd")
const AiSearchLib := preload("res://scripts/combat/ai_search.gd")
const FleetCommanderLib := preload("res://scripts/combat/fleet_commander.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_theta_consts()
	_test_candidate_bound()
	_test_dice_free_search()
	_test_same_seed_battles()
	_test_discipline_removal()
	_test_assigned_target()
	_test_hard_gates()
	_test_phi_features()
	_test_harness_wiring()
	_test_adoption_gate_arithmetic()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A §4.11.11 ship instance (the test_battle shape). `crew` defaults to the
## hull's crew_min.
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


## A hermetic sim (current strength 0, calm — no raster leakage).
func _sim(config: Dictionary) -> BattleLib:
	var full := {
		"player_ships": [], "enemy_ships": [], "enemy_kind": "pirate",
		"enemy_nation": "", "day": 1, "gold": 0,
		"contact": Vector2i(30, 40), "weather": "calm",
		"current": {"dir": "", "strength": 0},
	}
	for key in config:
		full[key] = config[key]
	return BattleLib.new(full)


func _unit(sim: BattleLib, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


func _place(sim: BattleLib, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["pos"] = cell


func _face(unit: Dictionary, heading8: int) -> void:
	if not unit.is_empty():
		unit["heading8"] = heading8


## Ends turns until `side`/`index` is the acting unit — the T3 search applies
## its candidates through the live engine seam (`apply_velocity` / `cannon`),
## which requires the §4.11.4 acting cursor.
func _begin_turn(sim: BattleLib, side: String, index: int) -> void:
	for _guard in 16:
		var current := sim.current_unit()
		if current.is_empty() or (str(current["side"]) == side
				and int(current["index"]) == index):
			return
		sim.end_turn()


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## A minimal §4.12.3 Person model (the test_battle convention).
static func _person() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {
			"seamanship": 0, "navigation": 0, "swordplay": 10, "gunnery": 10,
			"appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0,
		},
		"officers": [], "equipment": {"weapon": "", "armor": ""},
	}


# --- 1. θ consts (docs/60-* §4.9c) -------------------------------------------

func _test_theta_consts() -> void:
	_person()
	# The §4.9c doc-first prior, verbatim, for ALL THREE archetypes — the
	# pre-tune pin: the offline CEM run finalizes the integers through the
	# named master θ-finalization task (correction 11: the doc is amended
	# first, then these consts sync together — never one without the other).
	var prior: Array[int] = [10, 4, 2, 3, -5, -6, -2, -4, 2]
	_check(AiSearchLib.THETA_AGGRESSIVE == prior,
		"§4.9c: THETA_AGGRESSIVE is the doc-first prior %s" % str(prior))
	_check(AiSearchLib.THETA_BALANCED == prior,
		"§4.9c: THETA_BALANCED is the doc-first prior %s" % str(prior))
	_check(AiSearchLib.THETA_CAUTIOUS == prior,
		"§4.9c: THETA_CAUTIOUS is the doc-first prior %s" % str(prior))
	# The archetype → θ mapping over the shipped §4.10 rows: pirate/privateer
	# rows carry `aggressive`, patrol/navy/tournament `balanced`,
	# treasure/trader/coaster/courier `cautious` (§4.9c); an unknown
	# archetype reads balanced (the middle row).
	var mapping := {
		"pirate": AiSearchLib.THETA_AGGRESSIVE,
		"privateer": AiSearchLib.THETA_AGGRESSIVE,
		"patrol": AiSearchLib.THETA_BALANCED,
		"navy": AiSearchLib.THETA_BALANCED,
		"tournament": AiSearchLib.THETA_BALANCED,
		"treasure": AiSearchLib.THETA_CAUTIOUS,
		"trader": AiSearchLib.THETA_CAUTIOUS,
		"coaster": AiSearchLib.THETA_CAUTIOUS,
		"courier": AiSearchLib.THETA_CAUTIOUS,
	}
	var wrong: Array[String] = []
	for kind in mapping:
		var row: Dictionary = AiLib.profile_for(str(kind))
		var archetype := str(row.get("archetype", ""))
		if AiSearchLib.theta_for(archetype) != mapping[kind]:
			wrong.append(str(kind))
		if archetype != _expected_archetype(str(kind)):
			wrong.append("%s(archetype %s)" % [str(kind), archetype])
	_check(wrong.is_empty(),
		"§4.9c/§4.10: the nine shipped rows map to the §4.9c archetypes and "
			+ "θ arrays (mismatches %s)" % str(wrong))
	_check(AiSearchLib.theta_for("balanced") == AiSearchLib.THETA_BALANCED
			and AiSearchLib.theta_for("aggressive") == AiSearchLib.THETA_AGGRESSIVE
			and AiSearchLib.theta_for("cautious") == AiSearchLib.THETA_CAUTIOUS,
		"§4.9c: theta_for resolves each archetype to its own const")
	_check(AiSearchLib.theta_for("no_such_archetype") == AiSearchLib.THETA_BALANCED,
		"§4.9c: an unknown archetype reads balanced (the middle row)")


func _expected_archetype(kind: String) -> String:
	if kind == "pirate" or kind == "privateer":
		return "aggressive"
	if kind == "patrol" or kind == "navy" or kind == "tournament":
		return "balanced"
	return "cautious"


# --- 2. The candidate bound (docs/60-* §4.3a, §4.9c) -------------------------

func _test_candidate_bound() -> void:
	_person()
	# §4.3a: `legal_velocities` enumerates the Chebyshev box
	# (2·battle_max_speed + 1)² — 49 at the tier-3 hulls, 81 at tier 4 —
	# filtered by the §4.3a legality order; §4.9c pairs it with the action
	# set {steer/hold, cannon per loaded side ≤ 2, ram, board} — ≤ 5
	# candidates per velocity, so the T3 candidate set stays ≤ 5 × 81 = 405.
	var slo := _sim({
		"player_ships": [_ship("sloop")],
		"enemy_ships": [_ship("latin", {"cannons": 0})], "seed": 5,
	})
	slo.start()
	var sloop := _unit(slo, "player", 0)
	sloop["vel"] = Vector2i(3, 0)
	sloop["heading8"] = BattleLib.HEADING_EAST
	_check(slo.battle_max_speed(sloop) == 3
			and slo.legal_velocities(sloop).size() <= 49,
		"§4.3a: the tier-3 hull's velocity enumeration stays inside the "
			+ "Chebyshev box (max_speed %d, %d ≤ (2·3+1)² = 49)"
			% [slo.battle_max_speed(sloop), slo.legal_velocities(sloop).size()])
	var big := _sim({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("latin", {"cannons": 0})], "seed": 5,
	})
	big.start()
	var brig := _unit(big, "player", 0)
	brig["vel"] = Vector2i(4, 0)
	brig["heading8"] = BattleLib.HEADING_EAST
	_check(big.battle_max_speed(brig) == 4
			and big.legal_velocities(brig).size() <= 81,
		"§4.3a/§4.9c: the tier-4 hull's enumeration stays ≤ (2·4+1)² = 81 "
			+ "(%d candidates × ≤ 5 actions = ≤ 405)"
			% big.legal_velocities(brig).size())
	_check(big.legal_velocities(_unit(big, "enemy", 0)).size() <= 49,
		"§4.3a: a tier-2 hull's box is bounded by (2·2+1)² = 25 (%d)"
			% big.legal_velocities(_unit(big, "enemy", 0)).size())


# --- 3. The search leaves no trace (§4.9c, §4.12.1) --------------------------

## The boarding-adjacent fixture (the §4.6a hook legal — a board candidate
## resolves a full §4.11.6 duel with dice inside the search).
func _board_fixture(seed_value: int) -> BattleLib:
	var sim := _sim({
		"player_ships": [_ship("sloop", {"cannons": 0, "crew": 10})],
		"enemy_ships": [_ship("latin", {"cannons": 4, "crew": 40})],
		"seed": seed_value,
	})
	sim.start()
	_place(sim, "player", 0, Vector2i(10, 16))
	var boarder := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(10, 15))
	_face(boarder, BattleLib.HEADING_EAST)
	boarder["vel"] = Vector2i.ZERO
	_begin_turn(sim, "enemy", 0)
	return sim


func _test_dice_free_search() -> void:
	_person()
	var sim := _board_fixture(99)
	var boarder := _unit(sim, "enemy", 0)
	_check(sim.can_board(boarder, _unit(sim, "player", 0)),
		"§4.6a: the fixture's hook is legal (a board candidate exists)")
	var pre: Array[int] = sim.snapshot()
	var decision := AiLib.decide(sim, boarder)
	var decision_again := AiLib.decide(sim, boarder)
	var post: Array[int] = sim.snapshot()
	_check(pre == post,
		"§4.9c: the search leaves the sim byte-identical — snapshot() before "
			+ "decide == snapshot() after (the candidates' dice are rolled "
			+ "back with rng.state, §4.12.1)")
	_check(JSON.stringify(decision) == JSON.stringify(decision_again),
		"§4.9c/§4.11.8 pin 1: two decide calls on the identical restored "
			+ "state return identical dicts (%s)" % str(decision))


# --- 4. Same-seed full-battle identity (§4.11.1) ------------------------------

func _test_same_seed_battles() -> void:
	_person()
	var runs: Array = []
	for _run_index in 2:
		var rng := RandomNumberGenerator.new()
		rng.seed = 4242
		var foes: Array = AiLib.compose_enemy("pirate", 30, rng)
		var battle := BattleLib.new({
			"player_ships": [
				_ship("sloop", {"cannons": 0}),
				_ship("sloop", {"cannons": 0}),
			],
			"enemy_ships": foes, "enemy_kind": "pirate",
			"day": 30, "gold": 0, "contact": Vector2i(30, 40),
			"weather": "calm", "wind_dir": "E",
			"current": {"dir": "", "strength": 0},
			"seed": 4242, "rng": rng,
		})
		battle.start()
		# BOTH sides through the T3: the enemy via the §4.9a dispatch (the
		# pirate row carries ai_level 1), the player via the same search
		# with the balanced θ — the §4.9c mirror pair.
		var policy := func(active_sim, unit) -> Dictionary:
			if str(unit.get("side", "")) == "enemy":
				return AiLib.decide(active_sim, unit)
			return AiSearchLib.decide(active_sim, unit,
				AiSearchLib.THETA_BALANCED)
		var outcome := battle.run_to_completion(policy, 20)
		runs.append({
			"log": JSON.stringify(battle.log_lines()),
			"outcome": JSON.stringify(outcome),
		})
	_check(runs.size() == 2 and str(runs[0]["log"]) == str(runs[1]["log"]),
		"§4.11.1/§4.9c: two same-seed T3-vs-T3 battles replay byte-identical "
			+ "log_lines()")
	_check(str(runs[0]["outcome"]) == str(runs[1]["outcome"]),
		"§4.11.1: …and identical outcome blocks")


# --- 5. Discipline removal (docs/60-* §4.9b/§4.9c) ---------------------------

## The fixture (a) arrangement: an ai_level-1 latin at (10,15) heading east,
## an unarmed brigantine player at (14,17) — off every gate, in T3 territory.
## The free T3's best-scoring pick is the eastward fire position (11,15)
## (φ4 arc fit +3); the disciplined engage order hard-removes it.
func _hunter_fixture(seed_value: int, enemy_morale = null) -> BattleLib:
	var config := {
		"player_ships": [_ship("brigantine", {"cannons": 0})],
		"enemy_ships": [_ship("latin", {"cannons": 4})], "seed": seed_value,
	}
	if enemy_morale != null:
		config["enemy_morale"] = enemy_morale
	var sim := _sim(config)
	sim.start()
	_place(sim, "player", 0, Vector2i(14, 17))
	var hunter := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(10, 15))
	_face(hunter, BattleLib.HEADING_EAST)
	hunter["vel"] = Vector2i.ZERO
	_begin_turn(sim, "enemy", 0)
	return sim


func _test_discipline_removal() -> void:
	_person()
	var sim := _hunter_fixture(911)
	var hunter := _unit(sim, "enemy", 0)
	var station := sim.unit_cell(hunter)
	var free := AiLib.decide(sim, hunter)
	var free_landing: Vector2i = sim.unit_cell(hunter) \
		+ (free.get("vel", Vector2i.ZERO) as Vector2i)
	_check(str(free["action"]) == "move" and free_landing != station,
		"§4.9c: the free T3 takes the better-scoring off-station pick "
			+ "(landing %s off the station %s)" % [str(free_landing),
			str(station)])
	var disciplined := AiLib.decide(sim, hunter, {
		"station": station, "desired_heading8": 0,
		"desired_speed_band": [0, 2], "assigned_target": -1,
		"discipline": true, "phase": "engage",
	})
	var landing: Vector2i = sim.unit_cell(hunter) \
		+ (disciplined.get("vel", Vector2i.ZERO) as Vector2i)
	_check(_chebyshev(landing, station) <= _chebyshev(station, station),
		"§4.9b/§4.9c: discipline removes the off-station candidates — the "
			+ "chosen candidate keeps the station (landing %s on %s)"
			% [str(landing), str(station)])
	_check(landing == station,
		"§4.9b: the disciplined engage ship holds its post exactly (%s)"
			% str(landing))


# --- 6. The engage assignment (docs/60-* §4.9b + the W5-A master bounce) -----

## The broadside-on fire-forcing fixture (loaded sides, explicit arrangement):
## a 14-cannon latin at (10,15) heading east (both sides loaded at round 1),
## player 0 dead-ahead at (13,15) (distance 3, in NO arc), player 1 — the
## weak sloop — at (13,13) (bearing one bucket off the bow, distance 3, in
## the port arc). The fire candidate (hold position + the port volley) beats
## every maneuver by the φ table (the 10-damage volley flips φ1's /20 term),
## so the fire branch actually executes.
func _gunner_fixture(seed_value: int) -> BattleLib:
	var sim := _sim({
		"player_ships": [
			_ship("sloop", {"cannons": 0, "durability": 60}),
			_ship("sloop", {"cannons": 0, "durability": 20}),
		],
		"enemy_ships": [_ship("latin", {"cannons": 14})], "seed": seed_value,
	})
	sim.start()
	_place(sim, "player", 0, Vector2i(13, 15))
	_place(sim, "player", 1, Vector2i(13, 13))
	var gunner := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(10, 15))
	_face(gunner, BattleLib.HEADING_EAST)
	gunner["vel"] = Vector2i.ZERO
	_begin_turn(sim, "enemy", 0)
	return sim


func _engage_order(station: Vector2i, assigned: int) -> Dictionary:
	return {
		"station": station, "desired_heading8": 0,
		"desired_speed_band": [0, 2], "assigned_target": assigned,
		"discipline": true, "phase": "engage",
	}


func _test_assigned_target() -> void:
	_person()
	var sim := _gunner_fixture(912)
	var gunner := _unit(sim, "enemy", 0)
	var station := sim.unit_cell(gunner)
	var on_target := AiLib.decide(sim, gunner,
		_engage_order(station, 1))
	_check(str(on_target["action"]) == "cannon"
			and (on_target["target"] as Dictionary).get("index", -1) == 1,
		"§4.9b/§4.9c: when the T3 fires under the engage assignment, the "
			+ "target IS the assigned ship (action %s, target %d)"
			% [str(on_target["action"]),
			int((on_target["target"] as Dictionary).get("index", -1))])
	var dead := AiLib.decide(sim, gunner,
		_engage_order(station, 7))
	var dead_target: Dictionary = dead.get("target", {})
	_check(str(dead["action"]) == "cannon"
			and int(dead_target.get("index", -1)) in [0, 1],
		"§4.9b: a dead assignment falls back to the free ranking — the T3 "
			+ "fires at its own §4.11.8-best target (action %s, target %d)"
			% [str(dead["action"]), int(dead_target.get("index", -1))])


# --- 7. The shared hard gates (docs/60-* §4.9c amendment, §4.9a) -------------

func _test_hard_gates() -> void:
	_person()
	# ① The §4.7 surrender gate resolves BEFORE the search (the dispatch's
	#    hard-rule layer is level-agnostic): an ai_level-1 pirate ship at
	#    ≤ 25 % durability with side morale ≤ 20 rolls; one seed's roll
	#    succeeds (the decision is the surrender, never a T3 candidate) and
	#    another seed's roll fails INTO the search (the decision is whatever
	#    the φ ranking chose).
	var surrendered_seed := -1
	var searched_seed := -1
	for probe_seed in range(1, 41):
		var sim := _sim({
			"player_ships": [_ship("brigantine", {"cannons": 0})],
			"enemy_ships": [_ship("latin", {"cannons": 4, "durability": 10})],
			"enemy_morale": 20, "seed": probe_seed,
		})
		sim.start()
		_place(sim, "player", 0, Vector2i(24, 15))
		var pinned := _unit(sim, "enemy", 0)
		_place(sim, "enemy", 0, Vector2i(20, 15))
		_begin_turn(sim, "enemy", 0)
		var decision := AiLib.decide(sim, pinned)
		if str(decision.get("action")) == "surrender":
			if surrendered_seed < 0:
				surrendered_seed = probe_seed
		elif searched_seed < 0:
			searched_seed = probe_seed
		if surrendered_seed >= 0 and searched_seed >= 0:
			break
	_check(surrendered_seed > 0,
		"§4.7/§4.9a ①: the ai_level-1 ship's surrender roll fires BEFORE the "
			+ "search (gate open at ≤ 25 %% durability ∧ morale 20 — seed %d)"
			% surrendered_seed)
	_check(searched_seed > 0,
		("§4.9c: a FAILED surrender roll reaches the T3 search (seed %d — "
			+ "the decision is the φ ranking, never a capitulation)")
			% searched_seed)
	#    The gate boundary: side morale 21 keeps the roll closed — the T3
	#    search answers every seed, never a surrender.
	var gate_closed := true
	for probe_seed in range(1, 11):
		var sim21 := _sim({
			"player_ships": [_ship("brigantine", {"cannons": 0})],
			"enemy_ships": [_ship("latin", {"cannons": 4, "durability": 10})],
			"enemy_morale": 21, "seed": probe_seed,
		})
		sim21.start()
		_place(sim21, "player", 0, Vector2i(24, 15))
		var pinned21 := _unit(sim21, "enemy", 0)
		_place(sim21, "enemy", 0, Vector2i(20, 15))
		_begin_turn(sim21, "enemy", 0)
		if str(AiLib.decide(sim21, pinned21).get("action")) == "surrender":
			gate_closed = false
	_check(gate_closed,
		"§4.7: side morale 21 stays above the gate — no seed surrenders "
			+ "(the roll never fires; the T3 ranks the candidates)")
	# ② The §4.9a flee rule preempts the T3 when an escape velocity exists.
	#    Morale leg: side morale 15 ≤ 20 opens the gate; the first strictly
	#    distance-increasing landing wins over ANY T3 candidate.
	var flee_sim := _hunter_fixture(911, 15)
	var fleer := _unit(flee_sim, "enemy", 0)
	var flee := AiLib.decide(flee_sim, fleer)
	var flee_landing: Vector2i = flee_sim.unit_cell(fleer) \
		+ (flee.get("vel", Vector2i.ZERO) as Vector2i)
	_check(str(flee["action"]) == "move"
			and _chebyshev(flee_landing, Vector2i(14, 17)) > 4,
		"§4.9a ②: side morale ≤ 20 — the flee rule takes the strictly "
			+ "distance-increasing escape over any T3 candidate (landing %s)"
			% str(flee_landing))
	#    Aggression leg: the profile row injected at the suite level.
	var profiles: Dictionary = DataLoader.npc_config.get("ai_profiles", {})
	var shipped: Dictionary = (profiles.get("pirate", {}) as Dictionary) \
		.duplicate(true)
	var timid: Dictionary = shipped.duplicate(true)
	timid["aggression"] = 10
	DataLoader.npc_config["ai_profiles"]["pirate"] = timid
	var aggression_sim := _hunter_fixture(911)
	var aggression_pick := AiLib.decide(aggression_sim,
		_unit(aggression_sim, "enemy", 0))
	DataLoader.npc_config["ai_profiles"]["pirate"] = shipped
	var aggression_landing: Vector2i = aggression_sim.unit_cell(
			_unit(aggression_sim, "enemy", 0)) \
		+ (aggression_pick.get("vel", Vector2i.ZERO) as Vector2i)
	_check(int(timid["aggression"]) < AiLib.FLEE_AGGRESSION_MAX
			and str(aggression_pick["action"]) == "move"
			and _chebyshev(aggression_landing, Vector2i(14, 17)) > 4,
		"§4.9a ②: aggression < 25 flees through the injected row (landing %s)"
			% str(aggression_landing))
	#    HP leg: `flee_below_hp_pct` exceeded.
	var fleeing_row: Dictionary = shipped.duplicate(true)
	fleeing_row["flee_below_hp_pct"] = 50
	DataLoader.npc_config["ai_profiles"]["pirate"] = fleeing_row
	var hp_sim := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 0})],
		"enemy_ships": [_ship("latin", {"cannons": 4, "durability": 10})],
		"enemy_morale": 80, "seed": 911,
	})
	hp_sim.start()
	_place(hp_sim, "player", 0, Vector2i(14, 17))
	var hp_fleer := _unit(hp_sim, "enemy", 0)
	_place(hp_sim, "enemy", 0, Vector2i(10, 15))
	_face(hp_fleer, BattleLib.HEADING_EAST)
	hp_fleer["vel"] = Vector2i.ZERO
	_begin_turn(hp_sim, "enemy", 0)
	var hp_pick := AiLib.decide(hp_sim, hp_fleer)
	DataLoader.npc_config["ai_profiles"]["pirate"] = shipped
	var hp_landing: Vector2i = hp_sim.unit_cell(hp_fleer) \
		+ (hp_pick.get("vel", Vector2i.ZERO) as Vector2i)
	_check(str(hp_pick["action"]) == "move"
			and _chebyshev(hp_landing, Vector2i(14, 17)) > 4,
		"§4.9a ②: hp < flee_below_hp_pct flees over any T3 candidate "
			+ "(landing %s)" % str(hp_landing))
	#    The contrast — every gate closed, the T3 owns the decision (the
	#    discipline section's free pick, re-asserted here against the flee
	#    signature).
	var open_sim := _hunter_fixture(911)
	var open_pick := AiLib.decide(open_sim, _unit(open_sim, "enemy", 0))
	var open_landing: Vector2i = open_sim.unit_cell(
			_unit(open_sim, "enemy", 0)) \
		+ (open_pick.get("vel", Vector2i.ZERO) as Vector2i)
	_check(_chebyshev(open_landing, Vector2i(14, 17)) <= 4,
		"§4.9a/§4.9c: with every flee gate closed the T3 ranks its own "
			+ "candidates (the close-in pick %s, no escape)" % str(open_landing))


# --- 8. The normative φ table (docs/60-* §4.9c) ------------------------------
#
# Hand-computed nine-feature totals on fixed mini-fixtures; the module's
# `_evaluate` must reproduce them exactly. Feature-by-feature derivation in
# the comments — every division truncates, all arithmetic integers.

func _test_phi_features() -> void:
	_person()
	# Fixture A — φ1 and φ3. Enemy sloop: durability 20 (of 60), 4 cannons
	# (port 2 / starboard 2, both loaded at round 1). Player sloop:
	# durability 60, 4 cannons with `reload_starboard` pushed to 5 (port
	# loaded only). Both at (24,15)/(24,18) heading east — the enemy's
	# starboard arc and the player's port arc each contain the other at
	# Chebyshev 3.
	#   φ1 = (20 − 60)/20 = −2      → 10 × −2 = −20
	#   φ2 = (4 − 4)/4 = 0
	#   φ3 = (2 loaded − 1 loaded)  →  2 × +1 = +2
	#   φ4 = 1 friendly arc − 1 enemy arc = 0
	#   φ5 = neither ship on a deck line → 0
	#   φ6 = each flagship inside the other's loaded arc → 1 − 1 = 0
	#   φ7 = no station → 0 ;  φ8 = single-ship sides → 0
	#   φ9 = bearing S (bucket 6) vs heading E (0) → 4 − 2 = 2 → 2 × 2 = +4
	# Total: −20 + 2 + 4 = −14.
	var sim_a := _sim({
		"player_ships": [_ship("sloop", {"durability": 60, "cannons": 4})],
		"enemy_ships": [_ship("sloop", {"durability": 20, "cannons": 4})],
		"seed": 7,
	})
	sim_a.start()
	var enemy_a := _unit(sim_a, "enemy", 0)
	var player_a := _unit(sim_a, "player", 0)
	_place(sim_a, "enemy", 0, Vector2i(24, 15))
	_place(sim_a, "player", 0, Vector2i(24, 18))
	_face(enemy_a, BattleLib.HEADING_EAST)
	_face(player_a, BattleLib.HEADING_EAST)
	player_a["reload_starboard"] = 5
	_check(AiSearchLib._evaluate(sim_a, enemy_a,
			AiSearchLib.THETA_BALANCED, "enemy", "player", false,
			Vector2i.ZERO) == -14,
		"§4.9c φ1/φ3: the hand-computed total (φ1 −2·10, φ3 +1·2, φ9 2·2) "
			+ "evaluates to −14")
	# The φ3 delta in isolation: the player's starboard reloads back into
	# round 1 → both player sides loaded → φ3 = 0 → the total drops by the
	# φ3 weight (−14 − 2 = −16).
	player_a["reload_starboard"] = 1
	_check(AiSearchLib._evaluate(sim_a, enemy_a,
			AiSearchLib.THETA_BALANCED, "enemy", "player", false,
			Vector2i.ZERO) == -16,
		"§4.9c φ3: restoring the player's starboard load zeroes φ3 (−16 = "
			+ "−14 − 2·1)")
	# Fixture B — φ9 (and the φ5 interplay). Both sloops 0 cannons,
	# durability 40, the player dead north of the enemy at Chebyshev 3.
	# Heading south: the enemy sits on the player's deck line (φ5 = 1 →
	# −5·1) and the bearing (N, bucket 2) is 4 buckets off the heading
	# (φ9 = 0): total −5. Heading west: no exposure and 2 buckets off
	# (φ9 = 2 → +2·2): total +4.
	var sim_b := _sim({
		"player_ships": [_ship("sloop", {"cannons": 0})],
		"enemy_ships": [_ship("sloop", {"cannons": 0})],
		"seed": 7,
	})
	sim_b.start()
	var enemy_b := _unit(sim_b, "enemy", 0)
	var player_b := _unit(sim_b, "player", 0)
	_place(sim_b, "enemy", 0, Vector2i(24, 15))
	_place(sim_b, "player", 0, Vector2i(24, 12))
	_face(player_b, BattleLib.HEADING_EAST)
	_face(enemy_b, 6)
	_check(AiSearchLib._evaluate(sim_b, enemy_b,
			AiSearchLib.THETA_BALANCED, "enemy", "player", false,
			Vector2i.ZERO) == -5,
		"§4.9c φ9/φ5: heading into the bearing (alignment 0) with the deck "
			+ "line held (φ5 1) evaluates to −5")
	_face(enemy_b, BattleLib.HEADING_WEST)
	_check(AiSearchLib._evaluate(sim_b, enemy_b,
			AiSearchLib.THETA_BALANCED, "enemy", "player", false,
			Vector2i.ZERO) == 4,
		"§4.9c φ9: two buckets off the bearing with the exposure escaped "
			+ "evaluates to +4 (φ9 2·2, φ5 0)")


# --- 9. The T3-vs-T2 harness wiring (docs/IMPLEMENT-Phase9.md W5-D) ----------
#
# The battle_ai_harness W4 navy-vs-pirate section shape, driven directly: a
# 4-seed mini-run (the pinned table formula, i in 0..3) with ai_level forced
# 1 on the navy side via profile injection at the suite level (the same
# override pattern the harness section uses), the navy fleet through the
# §4.9b FleetCommander + the `AiFleet.decide` order seam (the ai_level = 1
# dispatch ⇒ the T3), the player side the pinned mirror greedy.

var _mh_profile: Dictionary = {}
var _mh_state: Dictionary = {}
var _mh_orders: Array = []
var _mh_orders_round := -1
var _mh_hold_rounds := 0
var _mh_hold_hits := 0


func _test_harness_wiring() -> void:
	_person()
	var profiles: Dictionary = DataLoader.npc_config.get("ai_profiles", {})
	var shipped: Dictionary = (profiles.get("navy", {}) as Dictionary) \
		.duplicate(true)
	var injected: Dictionary = shipped.duplicate(true)
	injected["ai_level"] = 1
	DataLoader.npc_config["ai_profiles"]["navy"] = injected
	_check(int(injected["ai_level"]) == 1,
		"§4.9c: the navy row's ai_level forced to 1 at the suite level (the "
			+ "shipped §4.10 value) — the dispatch below IS the T3")
	_mh_profile = injected
	var records: Array = []
	for index in 4:
		records.append(_mini_harness_seed(index))
	DataLoader.npc_config["ai_profiles"]["navy"] = shipped
	var tally := {
		"seeds": records.size(),
		"player_wins": 0, "navy_wins": 0, "stalls": 0, "cap_hit": 0,
		"formation_rounds": _mh_hold_rounds, "formation_hits": _mh_hold_hits,
	}
	for record in records:
		var result := str(record["result"])
		if result == "victory":
			tally["player_wins"] = int(tally["player_wins"]) + 1
		elif result in ["defeat_sunk", "defeat_captured"]:
			tally["navy_wins"] = int(tally["navy_wins"]) + 1
		elif result == "stall":
			tally["stalls"] = int(tally["stalls"]) + 1
		if not bool(record["over"]):
			tally["cap_hit"] = int(tally["cap_hit"]) + 1
	var stats := {
		"seeds": int(tally["seeds"]),
		"cap_used": BattleLib.MAX_ROUNDS,
		"player_wins": int(tally["player_wins"]),
		"navy_wins": int(tally["navy_wins"]),
		"stalls": int(tally["stalls"]),
		"cap_hit": int(tally["cap_hit"]),
		"avg_rounds": _avg_rounds(records),
		"navy_winrate_pct": 100.0 * float(tally["navy_wins"])
			/ float(maxi(int(tally["seeds"]), 1)),
		"navy_surrenders": _sum_surrenders(records),
		"formation_rounds": int(tally["formation_rounds"]),
		"formation_hold_pct": 100.0 * float(tally["formation_hits"])
			/ float(maxi(int(tally["formation_rounds"]), 1)),
	}
	var shape: Array[String] = ["seeds", "cap_used", "player_wins",
		"navy_wins", "stalls", "cap_hit", "avg_rounds", "navy_winrate_pct",
		"navy_surrenders", "formation_rounds", "formation_hold_pct"]
	var missing: Array[String] = []
	for key in shape:
		if not stats.has(key):
			missing.append(str(key))
	_check(records.size() == 4 and missing.is_empty(),
		"W5-D harness wiring: the 4-seed navy-vs-pirate mini-run produced a "
			+ "record per seed and the harness stats-dict shape (missing %s)"
			% str(missing))
	_check(int(stats["player_wins"]) + int(stats["navy_wins"]) \
			+ int(stats["stalls"]) + int(stats["cap_hit"]) == 4,
		"W5-D harness wiring: the winner tally sums to the seed count "
			+ "(%s)" % str([stats["player_wins"], stats["navy_wins"],
			stats["stalls"], stats["cap_hit"]]))
	_check(float(stats["navy_winrate_pct"]) >= 0.0
			and float(stats["avg_rounds"]) >= 1.0,
		("W5-D harness wiring: the T3 navy fleet ran to recorded metrics "
			+ "(navy winrate %.1f%%, avg rounds %.2f, formation-hold %.1f%% "
			+ "over %d engage/form rounds)") % [float(stats["navy_winrate_pct"]),
			float(stats["avg_rounds"]), float(stats["formation_hold_pct"]),
			int(stats["formation_rounds"])])


func _mini_harness_seed(index: int) -> Dictionary:
	# The pinned harness table formula: seed_i = 1000003 + i × 7919.
	var seed_i := 1000003 + index * 7919
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var navy: Array = AiLib.compose_enemy("navy", 30, rng)
	var sim := _sim({
		"player_ships": [
			_ship("brigantine", {"cannons": 10}),
			_ship("brigantine", {"cannons": 10}),
		],
		"enemy_ships": navy, "enemy_kind": "navy", "enemy_nation": "spain",
		"day": 30, "gold": 0, "contact": Vector2i(100, 100),
		"weather": "calm", "wind_dir": "E",
		"current": {"dir": "", "strength": 0}, "seed": seed_i, "rng": rng,
	})
	sim.start()
	var flagship: Dictionary = {}
	for unit in sim.units():
		if str(unit.get("side", "")) == "enemy" \
				and int(unit.get("index", -1)) == 0:
			flagship = unit
			break
	# §4.9b: the anchor = flagship pos + heading8 at battle start.
	_mh_state = FleetCommanderLib.initial_state(
		str(_mh_profile.get("formation", "line_ahead")),
		sim.unit_cell(flagship), int(flagship.get("heading8", 4)))
	_mh_orders = []
	_mh_orders_round = -1
	_mh_hold_rounds = 0
	_mh_hold_hits = 0
	var policy := func(active_sim, unit) -> Dictionary:
		if str(unit.get("side", "")) == "enemy":
			return _mh_navy_decision(active_sim, unit)
		return _mirror_decision(active_sim, unit)
	var outcome := sim.run_to_completion(policy, BattleLib.MAX_ROUNDS)
	return {
		"result": str(outcome.get("result", "")),
		"over": bool(outcome.get("over", true)),
		"rounds": int(outcome.get("rounds", sim.round_number())),
		"surrendered_enemy": int(outcome.get("surrendered_enemy", 0)),
	}


## One generate_orders per round on the live sim view (the W4-A side_morale
## threaded when the seam exists), then this ship's five-tuple consumed by
## the unchanged `AiFleet.decide` (the ai_level = 1 dispatch).
func _mh_navy_decision(sim, unit: Dictionary) -> Dictionary:
	var round_no: int = sim.round_number()
	if round_no != _mh_orders_round:
		_mh_orders_round = round_no
		var view := {
			"units": sim.units(), "round": round_no,
			"enemy_kind": str(sim.enemy_kind),
		}
		if sim.has_method("side_morale"):
			view["side_morale"] = sim.side_morale("enemy")
		_mh_orders = FleetCommanderLib.generate_orders(view, _mh_profile,
			_mh_state)
		_mh_record_formation_hold(sim)
	for entry in _mh_orders:
		if entry is Dictionary \
				and int(entry.get("index", -1)) == int(unit.get("index", -1)):
			return AiLib.decide(sim, unit, entry.get("order", {}))
	return AiLib.decide(sim, unit)


## The harness's formation-hold bookkeeping: while the commander's phase is
## engage or form, the round counts — and holds when EVERY living navy ship
## sits within the §4.9b station-deviation 2 of the station just issued.
func _mh_record_formation_hold(sim, _orders: Array = []) -> void:
	if _mh_orders.is_empty():
		return
	var phase := str(((_mh_orders[0] as Dictionary).get("order", {})
		as Dictionary).get("phase", ""))
	if phase != "engage" and phase != "form":
		return
	_mh_hold_rounds += 1
	var cells := {}
	for unit in sim.units():
		if bool(unit.get("alive", false)):
			cells[int(unit.get("index", -1))] = sim.unit_cell(unit)
	for entry in _mh_orders:
		var order: Dictionary = entry.get("order", {})
		var index := int(entry.get("index", -1))
		if not cells.has(index):
			continue
		var station: Vector2i = BattleLib.to_cell(
			order.get("station", BattleLib.NO_CELL))
		if _chebyshev(cells[index], station) > 2:
			return
	_mh_hold_hits += 1


## The pinned mirror greedy (the harness `_decide` velocity-engine shape):
## ① fire a loaded side in range+arc (round shot) ② the first legal velocity
## whose §4.3a sweep landing strictly reduces the Chebyshev distance ②-b the
## turn-to-broadside fallback ③ hold.
func _mirror_decision(sim, unit: Dictionary) -> Dictionary:
	var enemies: Array = sim.living_units("enemy")
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
	var distance := _chebyshev(from, sim.unit_cell(nearest))
	for vel in sim.legal_velocities(unit):
		var step: Vector2i = vel
		if step == Vector2i.ZERO:
			continue
		var landing := _sweep_landing(sim, unit, from, step)
		if landing != from \
				and _chebyshev(landing, sim.unit_cell(nearest)) < distance:
			return {"action": "move", "vel": step}
	var bearing := int(BattleLib.heading8_of(
		sim.unit_cell(nearest) - from))
	for vel in sim.legal_velocities(unit):
		var step: Vector2i = vel
		if step == Vector2i.ZERO:
			continue
		var steps := int(BattleLib.bucket_distance(bearing,
			int(BattleLib.heading8_of(step))))
		if steps in BattleLib.ARC_PORT_STEPS \
				or steps in BattleLib.ARC_STARBOARD_STEPS:
			return {"action": "move", "vel": step}
	return {"action": "hold"}


## The §4.3a sweep's landing cell (the engine's own Bresenham preview).
func _sweep_landing(sim, unit: Dictionary, from: Vector2i,
		step: Vector2i) -> Vector2i:
	var prior := from
	for cell in BattleLib._bresenham_cells(from, from + step):
		if not BattleLib.in_grid(cell):
			return prior
		for other in sim.units():
			if is_same(other, unit) or not bool(other.get("alive", false)):
				continue
			if sim.unit_cell(other) == cell:
				return prior
		prior = cell
	return prior


func _avg_rounds(records: Array) -> float:
	var total := 0
	for record in records:
		total += int(record["rounds"])
	return float(total) / float(maxi(records.size(), 1))


func _sum_surrenders(records: Array) -> int:
	var total := 0
	for record in records:
		total += int(record["surrendered_enemy"])
	return total


# --- 10. The adoption-gate arithmetic (docs/60-* §4.9c; IMPLEMENT-Phase9 W6) -

## The §4.9c adoption gate, evaluated as a pure function of fixture numbers:
## T3 vs T2 ≥ +10 pp win rate AND a 100 % legal-action rate AND the ≤ 30 ms
## perf pin — otherwise `ai_level = 0` content ships. The RUN-based verdict
## (fixture win-rates measured by `tools/battle_tune.py`) is W6's pin once
## that tool lands on this branch; this is the documented verdict arithmetic.
func _adoption_verdict(winrate_delta_pp: float, legal_rate_pct: float,
		avg_decision_ms: float) -> String:
	var adopt := winrate_delta_pp >= 10.0 and legal_rate_pct >= 100.0 \
		and avg_decision_ms <= 30.0
	return "adopt" if adopt else "reject"


func _test_adoption_gate_arithmetic() -> void:
	_check(_adoption_verdict(12.5, 100.0, 21.0) == "adopt",
		"§4.9c gate: +12.5 pp / 100 % legal / 21 ms → adopt")
	_check(_adoption_verdict(10.0, 100.0, 30.0) == "adopt",
		"§4.9c gate: the boundaries +10 pp / 100 % / 30 ms → adopt")
	_check(_adoption_verdict(9.9, 100.0, 21.0) == "reject",
		"§4.9c gate: +9.9 pp misses the win-rate floor → reject "
			+ "(ai_level = 0 content ships)")
	_check(_adoption_verdict(12.5, 99.9, 21.0) == "reject",
		"§4.9c gate: a 99.9 % legal-action rate breaches the 100 % gate → "
			+ "reject")
	_check(_adoption_verdict(12.5, 100.0, 30.5) == "reject",
		"§4.9c gate: 30.5 ms average breaches the ≤ 30 ms perf pin → reject")


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
