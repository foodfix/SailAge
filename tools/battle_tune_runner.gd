extends Node
## W5-B — headless battle job runner for the offline θ CEM
## (IMPLEMENT-Phase9.md decision 16; docs/60-COMBAT.md §4.9c). NOT part of the
## `tools/test_*.tscn` gate family (`run_tests.py` globs `test_*.tscn` only):
##
##   TUNE_JOB=<job.json> TUNE_OUT=<out.json> \
##     godot --headless res://tools/battle_tune_runner.tscn
##
## The job JSON (written by `tools/battle_tune.py`): `{battles: [...],
## out_path}` where each battle is `{seed, enemy_kind, day, fleet_spec,
## contact, weather, wind_dir, current, theta_side, theta, archetype,
## baseline_side_profile, enemy_band}`. The runner composes BOTH fleets
## deterministically from the seed — `AiFleet.compose_enemy` for the enemy
## side (the §4.11.3 rng order), the player side from `fleet_spec` (hull
## counts → full `armament_slots` cannons, `crew_min` crew, max durability,
## no RNG) — and replays every battle to the §4.11.9 cap through
## `run_to_completion` with ONE policy callable driving both sides (the
## harness driver convention). Results (one record per battle + job checks)
## are written ONCE to `TUNE_OUT` at the end.
##
## The θ-side policy is the runner-side test seam the slot list mandates
## (the `BattleSim._captains_test_doubles` pattern: NOTHING is added to game
## code). The runner builds the profile dict itself — the enemy_kind row
## with `archetype` → the battle's archetype and `ai_level` → 1 — and drives
## θ-side units through the shared §4.9a hard gates ① surrender / ② flee and
## then `AiSearch.decide(sim, unit, theta)` DIRECTLY (the free T3 — no
## §4.9b orders). Every rule helper (landing preview, nearest pick, fire
## ranking, kite, board gate, ram decision, close step) is REUSED from
## `ai_fleet.gd` through the preload — nothing is copied.
##
## Two pinned readings, both recorded here because the runner is their only
## implementation:
##  - Gate ① fires for ENEMY-side units only. §4.8a correction 5 is engine
##    law: player ships never auto-strike, and `_apply_decision` routes a
##    player-side "surrender" to the §4.11.7 menu action (battle-ending) —
##    a policy must never emit it for the player seat.
##  - Gate ② for the θ seat uses the clauses that are LIVE for shipped
##    `ai_level = 1` archetypes — `flee_below_hp_pct` and side morale ≤ 20
##    (every ai_level-1 row carries aggression ≥ 60, so the `aggression < 25`
##    clause is already inert for T3 in the game). The BASELINE T2 seat keeps
##    the full §4.9a rule INCLUDING `aggression < 25` — that seat is the T2
##    exactly as shipped (cautious rows flee-always). Without this split the
##    stage-2 cautious fine-tune would pre-empt the search on every turn and
##    θ_cautious would be unobservable (fitness flat regardless of θ).
##
## The baseline side runs the FREE T2 assembled from `AiFleet.decide`'s own
## static helpers (gates + fire → kite → board ≥ ram → close → hold, no
## orders) with the profile from `baseline_side_profile` (a job override) or
## `AiFleet.profile_for(sim.enemy_kind)` — the engine default. It is
## assembled rather than called for two reasons: the plain `AiFleet.decide`
## dispatches into T3 for every `ai_level = 1` kind (the tune baseline must
## stay T2 — §4.9c adoption-gate reference), and `AiFleet.decide` is
## enemy-brained (it reads `living_units(SIDE_PLAYER)` as its targets), so
## driving the player seat with it would self-target.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const AiSearchLib := preload("res://scripts/combat/ai_search.gd")

var _checks := 0
var _failures: Array[String] = []

# --- Per-battle driver state (battles run sequentially inside _ready) -------

var _theta_side := "enemy"
var _theta: Array[int] = []
var _profile_theta := {}
var _profile_baseline := {}
var _fled := false              # the θ side ever took a ② flee action
var _theta_surrenders := 0      # resolved §4.7 surrenders ON the θ side
var _boardings := 0             # resolved §4.6 boardings (both sides)
var _grape_shots := 0           # resolved grape volleys (both sides)
var _cannon_volleys := 0        # resolved cannon volleys (both sides)
var _decisions := 0
var _illegal := 0
var _usec_total := 0
var _usec_max := 0
var _theta_decisions := 0
var _theta_usec_total := 0
var _theta_usec_max := 0
var _dist_sum := 0.0
var _dist_samples := 0
var _last_round := -1


func _ready() -> void:
	_fixture_player()
	var job_path := OS.get_environment("TUNE_JOB")
	var out_path := OS.get_environment("TUNE_OUT")
	if job_path.is_empty() or out_path.is_empty():
		push_error("battle_tune_runner: TUNE_JOB/TUNE_OUT not set")
		get_tree().quit(2)
		return
	var parsed = JSON.parse_string(_read_file(job_path))
	if not (parsed is Dictionary):
		push_error("battle_tune_runner: job JSON unparsable")
		get_tree().quit(2)
		return
	var job: Dictionary = parsed
	var battles: Array = job.get("battles", [])
	var results: Array = []
	for index in battles.size():
		var battle: Dictionary = battles[index]
		if battle is Dictionary:
			var t0 := Time.get_ticks_usec()
			results.append(_run_battle(battle))
			print("battle %d/%d seed %d %.1fs" % [index + 1, battles.size(),
				int(battle.get("seed", 0)),
				float(Time.get_ticks_usec() - t0) / 1000000.0])
	_check(results.size() == battles.size(),
		"every battle produced a record (%d/%d)" % [results.size(), battles.size()])
	var repro := _probe_reproducible(battles)
	var band_ok := true
	var illegal := 0
	var decisions := 0
	for record in results:
		band_ok = band_ok and bool(record["enemy_band_ok"])
		illegal += int(record["illegal"])
		decisions += int(record["decisions"])
	_check(band_ok, "enemy compositions inside the kind bands")
	_check(repro, "reproducibility probe: battle[0] log hash identical twice")
	var payload := {
		"results": results,
		"expected": battles.size(),
		"ran": results.size(),
		"reproducible": repro,
		"illegal": illegal,
		"decisions": decisions,
		"band_ok": band_ok,
	}
	var target := str(out_path)
	if str(job.get("out_path", "")) != "":
		target = str(job["out_path"])
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		push_error("battle_tune_runner: cannot write %s" % target)
		get_tree().quit(2)
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	print("battle_tune_runner: %d battles -> %s (%d checks, %d failures)"
		% [results.size(), target, _checks, _failures.size()])
	if _failures.is_empty():
		get_tree().quit(0)
		return
	for failure in _failures:
		print("  FAIL %s" % failure)
	get_tree().quit(1)


static func _read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


# --- Battle execution --------------------------------------------------------

func _run_battle(battle: Dictionary) -> Dictionary:
	var seed_i := int(battle.get("seed", 0))
	var kind := str(battle.get("enemy_kind", "pirate"))
	var day := int(battle.get("day", 1))
	var theta_side := str(battle.get("theta_side", "enemy"))
	var contact: Vector2i = BattleSimLib.to_cell(battle.get("contact", Vector2i.ZERO))
	# §4.11.1 hand-off stream: composition consumes it first, the battle
	# continues on the same stream (the harness's exact pattern — same seed
	# ⇒ identical fleets AND identical dice stream at battle start).
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var enemy: Array = AiFleetLib.compose_enemy(kind, day, rng)
	var band: Array = battle.get("enemy_band", [0, 99])
	var band_ok := enemy.size() >= int(band[0]) \
		and enemy.size() <= int(band[1])
	# The θ side's profile: the kind row with the battle's archetype + T3.
	var profile_theta: Dictionary = AiFleetLib.profile_for(kind)
	profile_theta["archetype"] = str(battle.get("archetype", "balanced"))
	profile_theta["ai_level"] = 1
	# The baseline side's profile: the job override or the engine default.
	var baseline_profile = battle.get("baseline_side_profile", null)
	var profile_baseline: Dictionary = AiFleetLib.profile_for(kind) \
		if not (baseline_profile is Dictionary) or (baseline_profile as Dictionary).is_empty() \
		else (baseline_profile as Dictionary).duplicate()
	var theta: Array[int] = []
	for value in battle.get("theta", [10, 4, 2, 3, -5, -6, -2, -4, 2]):
		theta.append(int(value))
	_theta_side = theta_side
	_theta = theta
	_profile_theta = profile_theta
	_profile_baseline = profile_baseline
	_fled = false
	_theta_surrenders = 0
	_boardings = 0
	_grape_shots = 0
	_cannon_volleys = 0
	_decisions = 0
	_illegal = 0
	_usec_total = 0
	_usec_max = 0
	_theta_decisions = 0
	_theta_usec_total = 0
	_theta_usec_max = 0
	_dist_sum = 0.0
	_dist_samples = 0
	_last_round = -1
	var sim := BattleSimLib.new({
		"player_ships": _player_fleet(battle.get("fleet_spec", {}), seed_i),
		"enemy_ships": enemy,
		"enemy_kind": kind,
		"enemy_nation": "",
		"day": day,
		"gold": 0,
		"contact": contact,
		"weather": str(battle.get("weather", "calm")),
		"wind_dir": str(battle.get("wind_dir", "E")),
		"current": battle.get("current", {"dir": "", "strength": 0}),
		"seed": seed_i,
		"rng": rng,
	})
	var outcome: Dictionary = sim.run_to_completion(Callable(self, "_policy"),
		BattleSimLib.MAX_ROUNDS)
	_tally_log(sim)
	var result := str(outcome.get("result", ""))
	var winner := "none"
	if result == "victory":
		winner = "player"
	elif result in ["defeat_sunk", "defeat_captured", "surrender"]:
		winner = "enemy"
	var other := "player" if theta_side == "enemy" else "enemy"
	var winner_side := "none"
	if winner == theta_side:
		winner_side = "theta"
	elif winner == other:
		winner_side = "baseline"
	return {
		"seed": seed_i,
		"enemy_kind": kind,
		"theta_side": theta_side,
		"archetype": str(battle.get("archetype", "balanced")),
		"winner_side": winner_side,
		"result": result,
		"rounds": int(outcome.get("rounds", sim.round_number())),
		"over": bool(outcome.get("over", true)),
		"stall": result == "stall",
		"damage_theta": _damage.get(theta_side, 0),
		"damage_baseline": _damage.get(other, 0),
		"engagement_distance_mean": _dist_sum / float(_dist_samples) \
			if _dist_samples > 0 else 0.0,
		"engagement_samples": _dist_samples,
		"fled": _fled,
		"boardings": _boardings,
		"grape_shots": _grape_shots,
		"cannon_volleys": _cannon_volleys,
		"theta_surrenders": _theta_surrenders,
		"enemy_ship_count": enemy.size(),
		"enemy_band_ok": band_ok,
		"decisions": _decisions,
		"illegal": _illegal,
		"theta_decisions": _theta_decisions,
		"theta_avg_ms": _theta_usec_total / float(maxi(_theta_decisions, 1)) / 1000.0,
		"theta_max_ms": float(_theta_usec_max) / 1000.0,
		"log_hash": _hash_lines(sim.log_lines()),
	}


## Damage attribution from the structured log (cannon: the volley's damage
## credited to the firing side; ram: `damage` to the rammer,
## `attacker_damage` to the rammed side; boarding logs a `board` entry).
var _damage := {}


func _tally_log(sim) -> void:
	_damage = {"player": 0, "enemy": 0}
	for entry in sim.log_lines():
		if not (entry is Dictionary):
			continue
		var kind := str(entry.get("kind", ""))
		var values: Dictionary = entry.get("values", {})
		var attacker := str(values.get("side", ""))
		var target_side := str(values.get("target_side", ""))
		if kind == "cannon":
			_cannon_volleys += 1
			if str(values.get("shot", "")) == "grape":
				_grape_shots += 1
			_damage[attacker] = int(_damage.get(attacker, 0)) \
				+ maxi(int(values.get("damage", 0)), 0)
		elif kind == "ram":
			_damage[attacker] = int(_damage.get(attacker, 0)) \
				+ maxi(int(values.get("damage", 0)), 0)
			_damage[target_side] = int(_damage.get(target_side, 0)) \
				+ maxi(int(values.get("attacker_damage", 0)), 0)
		elif kind == "board":
			_boardings += 1
		elif kind == "surrender_enemy":
			if attacker == _theta_side:
				_theta_surrenders += 1


# --- The policy (one callable drives both sides, harness convention) --------

func _policy(sim, unit: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var round_no: int = sim.round_number()
	if round_no != _last_round:
		_last_round = round_no
		_sample_round_distance(sim)
	var theta_seat := str(unit.get("side", "")) == _theta_side
	var decision := _theta_decision(sim, unit) if theta_seat \
		else _baseline_decision(sim, unit)
	var elapsed := Time.get_ticks_usec() - t0
	_decisions += 1
	_usec_total += elapsed
	_usec_max = maxi(_usec_max, elapsed)
	if theta_seat:
		_theta_decisions += 1
		_theta_usec_total += elapsed
		_theta_usec_max = maxi(_theta_usec_max, elapsed)
	# Legal-action audit: a carried non-zero velocity must be in the engine's
	# own enumeration (holds with vel (0,0) are the engine's safe degenerate).
	var vel = decision.get("vel", null)
	if vel is Vector2i and vel != Vector2i.ZERO \
			and not sim.legal_velocities(unit).has(vel):
		_illegal += 1
	return decision


## Engagement distance: once per round, while both sides are alive, the min
## Chebyshev across the two sides' living ships (the fleet engagement gap the
## behavior-distinctness gate reads).
func _sample_round_distance(sim) -> void:
	var player: Array = sim.living_units(BattleSimLib.SIDE_PLAYER)
	var enemy: Array = sim.living_units(BattleSimLib.SIDE_ENEMY)
	if player.is_empty() or enemy.is_empty():
		return
	var best := 999999
	for a in player:
		var ca: Vector2i = sim.unit_cell(a)
		for b in enemy:
			var d: int = BattleSimLib._chebyshev(ca, sim.unit_cell(b))
			if d < best:
				best = d
	if best < 999999:
		_dist_sum += float(best)
		_dist_samples += 1


# --- The θ seat: shared hard gates ① ② then the free T3 ---------------------

func _theta_decision(sim, unit: Dictionary) -> Dictionary:
	var hold := {"action": "hold", "target": {}, "vel": Vector2i.ZERO}
	var foes: Array = sim.living_units(_other_side(str(unit.get("side", ""))))
	if foes.is_empty():
		return hold
	var profile: Dictionary = _profile_theta
	var own_ship: Dictionary = unit.get("ship", {})
	var max_durability: int = sim.effective_max_durability(own_ship)
	# ① §4.7/§4.8a surrender — ENEMY-side units only (engine law: player
	#    ships never auto-strike, and a player-side surrender action is the
	#    §4.11.7 menu capitulation). Same gate shape as AiFleet.decide:
	#    side morale ≤ 20 ∧ ship ≤ 25 % max durability → the §4.7 roll with
	#    the profile courage_mod; drawn from the battle stream.
	if str(unit.get("side", "")) == BattleSimLib.SIDE_ENEMY:
		var morale := -1
		if sim.has_method("side_morale"):
			morale = int(sim.side_morale(BattleSimLib.SIDE_ENEMY))
		if max_durability > 0 \
				and int(own_ship.get("durability", 0)) * 100 \
					<= AiFleetLib.SURRENDER_DURABILITY_PERCENT * max_durability \
				and (morale < 0 or morale <= BattleSimLib.MORALE_SURRENDER_GATE):
			if sim.roll_surrender(unit, int(profile.get("courage_mod", 0)), morale):
				return {"action": "surrender", "target": {}, "vel": Vector2i.ZERO}
	# ② §4.9a flee for the T3 seat — the clauses LIVE for shipped ai_level-1
	#    archetypes: hp% below the profile gate, or side morale ≤ 20 (own
	#    side). The `aggression < 25` clause stays on the T2 seat only (see
	#    the module doc). First legal velocity strictly increasing the
	#    Chebyshev distance to the nearest foe, judged on the §4.3a landing
	#    cell; hold when none (a cornered fleer does not fall through).
	var wants_flee := false
	var flee_hp := int(profile.get("flee_below_hp_pct", 0))
	if max_durability > 0 \
			and int(own_ship.get("durability", 0)) * 100 < flee_hp * max_durability:
		wants_flee = true
	if not wants_flee:
		var morale := _own_side_morale(sim, str(unit.get("side", "")))
		if morale >= 0 and morale <= AiFleetLib.SIDE_MORALE_FLEE:
			wants_flee = true
	if wants_flee:
		var origin: Vector2i = sim.unit_cell(unit)
		var nearest: Dictionary = AiFleetLib._nearest(sim, foes, origin)
		var nearest_cell: Vector2i = sim.unit_cell(nearest["unit"])
		var distance := int(nearest["distance"])
		for vel in sim.legal_velocities(unit):
			if AiFleetLib._chebyshev(
					AiFleetLib._landing(sim, unit, origin, vel), nearest_cell) > distance:
				_fled = true
				return {"action": "move", "target": {}, "vel": vel}
		return hold
	# The free T3 (no orders — no discipline, no station term).
	return AiSearchLib.decide(sim, unit, _theta)


# --- The baseline seat: the free T2 (gates + priority list, no dispatch) ----
#
# Assembled from AiFleet.decide's own static helpers so the empty-order free
# path is reproduced, the T3 dispatch is suppressed (the tune baseline stays
# T2 for every ai_level), and the player seat mirrors the targets (the
# engine's AiFleet.decide hardcodes living_units(SIDE_PLAYER) as targets).
# The §4.9a rule keeps ALL THREE flee clauses here (the T2 as shipped).

func _baseline_decision(sim, unit: Dictionary) -> Dictionary:
	var hold := {"action": "hold", "target": {}, "vel": Vector2i.ZERO}
	var own_side := str(unit.get("side", ""))
	var foes: Array = sim.living_units(_other_side(own_side))
	if foes.is_empty():
		return hold
	var profile: Dictionary = _profile_baseline
	var own_ship: Dictionary = unit.get("ship", {})
	var max_durability: int = sim.effective_max_durability(own_ship)
	var origin: Vector2i = sim.unit_cell(unit)
	var nearest: Dictionary = AiFleetLib._nearest(sim, foes, origin)
	var nearest_cell: Vector2i = sim.unit_cell(nearest["unit"])
	var distance := int(nearest["distance"])
	var legal: Array = sim.legal_velocities(unit)
	# ① surrender — enemy-side units only (see the θ seat note).
	if own_side == BattleSimLib.SIDE_ENEMY:
		var morale := -1
		if sim.has_method("side_morale"):
			morale = int(sim.side_morale(BattleSimLib.SIDE_ENEMY))
		if max_durability > 0 \
				and int(own_ship.get("durability", 0)) * 100 \
					<= AiFleetLib.SURRENDER_DURABILITY_PERCENT * max_durability \
				and (morale < 0 or morale <= BattleSimLib.MORALE_SURRENDER_GATE):
			if sim.roll_surrender(unit, int(profile.get("courage_mod", 0)), morale):
				return {"action": "surrender", "target": {}, "vel": Vector2i.ZERO}
	# ② flee — the full §4.9a rule (hp% OR aggression < 25 OR morale ≤ 20).
	var wants_flee := max_durability > 0 \
		and int(own_ship.get("durability", 0)) * 100 \
			< int(profile.get("flee_below_hp_pct", 0)) * max_durability
	if int(profile.get("aggression", 0)) < AiFleetLib.FLEE_AGGRESSION_MAX:
		wants_flee = true
	if not wants_flee:
		var morale := _own_side_morale(sim, own_side)
		if morale >= 0 and morale <= AiFleetLib.SIDE_MORALE_FLEE:
			wants_flee = true
	if wants_flee:
		for vel in legal:
			if AiFleetLib._chebyshev(
					AiFleetLib._landing(sim, unit, origin, vel), nearest_cell) > distance:
				return {"action": "move", "target": {}, "vel": vel}
		return hold
	# ③ fire (the §4.11.8 pin-2 ranking; no assignment — the free T2).
	var fire := AiFleetLib._fire_decision(sim, unit, profile, foes)
	if not fire.is_empty():
		return fire
	# ④ kite while both sides reload (no engage/wear orders — the free T2
	#    never enters the ③½ heading-hold step).
	var round_no: int = sim.round_number()
	if round_no < int(unit.get("reload_port", 1)) \
			and round_no < int(unit.get("reload_starboard", 1)):
		var kite := AiFleetLib._kite_step(sim, unit, legal, nearest,
			int(profile.get("preferred_range", 0)))
		if kite != BattleSimLib.NO_CELL:
			return {"action": "move", "target": {}, "vel": kite}
	# ⑤ board ≥ ram (decision 13).
	var boarding := AiFleetLib._boarding_target(sim, unit, foes)
	if not boarding.is_empty():
		return {"action": "board", "target": boarding, "vel": Vector2i.ZERO}
	var ram_move := AiFleetLib._ram_decision(sim, unit, legal, foes)
	if not ram_move.is_empty():
		return ram_move
	# ⑥ close (the §4.9a decelerating close — also the swarm steering leg).
	var step := AiFleetLib._close_step(sim, unit, legal, nearest)
	if step != BattleSimLib.NO_CELL:
		return {"action": "move", "target": {}, "vel": step}
	# ⑦ hold.
	return hold


# --- Fleet composition --------------------------------------------------------

## The player side from the job's fleet_spec — NO RNG: hull counts map to
## full-`armament_slots` cannons, `crew_min` crew, max durability (the
## harness's `_brigantine` generalized). `{"compose": kind}` composes the
## player side via `compose_enemy` on a SEPARATE deterministic stream
## (seed ⊕ the tag below) so the §4.11.1 battle stream stays untouched.
func _player_fleet(spec: Dictionary, seed_i: int) -> Array:
	if spec.has("compose"):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_i + 7919
		return AiFleetLib.compose_enemy(str(spec["compose"]),
			int(spec.get("day", 30)), rng)
	var ships: Array = []
	var hulls: Dictionary = spec.get("hulls", {"brigantine": 2})
	for hull_id in hulls.keys():
		var ship_type: Dictionary = DataLoader.get_ship_type(str(hull_id))
		for _i in int(hulls[hull_id]):
			ships.append({
				"ship_type_id": str(hull_id),
				"durability": int(ship_type.get("durability", 0)),
				"crew": int(ship_type.get("crew_min", 0)),
				"provisions": 0,
				"water": 0,
				"cannons": int(ship_type.get("armament_slots", 0)),
				"equipment": {"figurehead": "", "sail": ""},
				"cargo": {},
			})
	return ships


## The harness's fixture player (Person model): the floor terms stay 0
## except the reload gate (gunnery 10 → 3 turns).
func _fixture_player() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {
			"seamanship": 0, "navigation": 0, "swordplay": 10,
			"gunnery": 10, "appraisal": 0, "negotiation": 0,
			"cartography": 0, "rumour": 0,
		},
		"officers": [],
		"equipment": {"weapon": "", "armor": ""},
	}


# --- Small helpers ------------------------------------------------------------

func _other_side(side: String) -> String:
	return BattleSimLib.SIDE_ENEMY if side == BattleSimLib.SIDE_PLAYER \
		else BattleSimLib.SIDE_PLAYER


## The defensive §4.8a side-morale read for the ACTING unit's own side
## (AiFleet's seam is hardcoded to SIDE_ENEMY — the engine's AI is
## enemy-brained; the runner drives both seats).
func _own_side_morale(sim, side: String) -> int:
	if sim == null or not sim.has_method("side_morale"):
		return -1
	var reading = sim.side_morale(side)
	if reading is int or reading is float:
		return int(reading)
	return -1


static func _hash_lines(lines: Array) -> int:
	return hash(JSON.stringify(lines))


## Reproducibility probe: battle[0] replayed twice from scratch must produce
## byte-identical structured logs (and outcomes).
func _probe_reproducible(battles: Array) -> bool:
	if battles.is_empty():
		return true
	var first := _run_battle(battles[0])
	var second := _run_battle(battles[0])
	return first["log_hash"] == second["log_hash"] \
		and first["winner_side"] == second["winner_side"] \
		and first["rounds"] == second["rounds"] \
		and first["damage_theta"] == second["damage_theta"] \
		and first["damage_baseline"] == second["damage_baseline"]


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures.append(label)
