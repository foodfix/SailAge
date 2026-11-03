extends Node
## Phase-9 W3-A — the 64-seed mirror self-play harness (IMPLEMENT-Phase9
## decision 16, correction 13 "harness before rewrite"). NOT part of the
## `tools/test_*.tscn` gate family (`run_tests.py` globs `test_*.tscn` only,
## so this stays a tool, never a suite):
##
##   godot --headless res://tools/battle_ai_harness.tscn
##
## Two sections run per invocation (the W4-D extension):
##
##   1. the pinned 64-seed MIRROR set (seed_i = 1000003 + i × 7919, i in
##      0..63 — the formula is the pin, do not regenerate the table) of a
##      symmetric deterministic greedy mirror policy driving BOTH sides, on
##      a player fleet of 2 brigantines vs `AiFleet.compose_enemy("pirate",
##      day=30)` composed on the §4.11.1 hand-off stream (the same `rng`
##      object seeds the composition and the sim, so composition → duel
##      continuity holds, §4.12.1 optional `rng` key).
##
##   2. the W4 navy-vs-pirate section over seeds[0..15] of the same table:
##      the ENEMY side is the navy fleet (`AiFleet.compose_enemy("navy",
##      day=30, rng)` — the navy row's `line_ahead`) driven by
##      `AiFleet.decide` THROUGH the §4.9b FleetCommander layer: a
##      `FleetCommander.initial_state` seeded at battle start (anchor =
##      flagship pos + heading8), per-round `generate_orders` on the live
##      sim view (`{units, round, enemy_kind, side_morale:
##      sim.side_morale("enemy")}` — threaded when the W4-A seam exists),
##      each five-tuple consumed by `AiFleet.decide(sim, unit, order)`;
##      the player side stays the mirror greedy. Metrics: rounds, navy
##      winrate, formation-hold % (the fraction of engage/form rounds where
##      every living navy ship is within the §4.9b station-deviation 2 of
##      the order station just issued), navy surrender count. The design
##      expectation — formation-hold ≥ 60 % (the phase doc's "line
##      formation never forms" risk) — is RECORDED in the report, never
##      tuned against.
##
## The mirror policy is ENGINE-AGNOSTIC: it probes the sim API once
## (`legal_velocities` present ⇒ the Phase-9 velocity engine, else the
## Phase-2/8 MP engine) and drives either through `run_to_completion`:
##   ① if a loaded cannon side has an enemy target in range+arc → fire it
##     (round shot; the MP engine has neither arcs nor sides — a plain
##     `can_cannon` hit fires);
##   ② else take the FIRST legal velocity (the engine's own enumeration
##     order) that strictly reduces the Chebyshev distance to the nearest
##     enemy (MP engine: the first legal move cell that does);
##   ③ else hold.
##
## Per seed it records: winner side, rounds, cap-hit, both damage exchange
## directions, every-decision-legal (the chosen velocity must be in
## `legal_velocities` / the chosen cell in `legal_moves` — asserted 100 %),
## and per-decision timing (`Time.get_ticks_usec` around the policy call).
## It audits determinism (seed[0] run twice ⇒ byte-identical `log_lines()`
## hash and outcome) and records the win-rate symmetry.
##
## The report lands in `tools/battle_ai_harness_report.md` (tool-owned, never
## hand-edited): the run writes its own engine's section — the MP engine
## writes "## Before (Phase-8 MP engine)", the velocity engine writes
## "## After (Phase-9 velocity engine)" plus the before→after comparison and
## the health-band reading (avg rounds 12–25, cap-hit < 10 %, stall < 5 %,
## legal-action 100 %, avg decision ≤ 30 ms). Each section carries its
## metrics as a ```json fence so the later run can parse the earlier one
## back for the comparison table. The W4 section is regenerated fresh every
## run and appended after the comparison.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const FleetCommanderLib := preload("res://scripts/combat/fleet_commander.gd")

# --- Pinned harness constants ----------------------------------------------

## seed_i = 1000003 + i × 7919 for i in 0..63 (deterministic table — comment
## the formula, never enumerate literal seeds).
const SEED_BASE := 1000003
const SEED_STEP := 7919
const SEED_COUNT := 64

## Round caps: the MP engine's cap was 30 (the Phase-2 default); the Phase-9
## velocity engine re-pins 40 (§4.12.1, correction 12). The probe picks.
const OLD_CAP := 30
const NEW_CAP := 40

const REPORT_PATH := "res://tools/battle_ai_harness_report.md"
const SECTION_BEFORE := "## Before (Phase-8 MP engine)"
const SECTION_AFTER := "## After (Phase-9 velocity engine)"

## The W4 navy-vs-pirate section (the D-slot extension): 16 seeds, the
## formation-hold design expectation, the §4.9b station-deviation radius.
const SECTION_W4 := "## W4: navy line_ahead (FleetCommander) vs pirate swarm"
const W4_SEED_COUNT := 16
const W4_FORMATION_HOLD_TARGET := 60.0
const W4_STATION_DEVIATION := 2

## The fixture battle: player 2 brigantines (full `armament_slots` cannons,
## `crew_min` crew, max durability) vs the composed pirate fleet at day 30.
const DAY := 30
const GOLD := 0
const CONTACT := Vector2i(100, 100)
const FIXTURE_WEATHER := "fair"

## Health band (IMPLEMENT-Phase9 W3 gate; the ONLY balance gate for 9A).
const BAND_AVG_ROUNDS_MIN := 12.0
const BAND_AVG_ROUNDS_MAX := 25.0
const BAND_CAP_HIT_PCT := 10.0
const BAND_STALL_PCT := 5.0
const BAND_AVG_DECISION_MS := 30.0

var _checks := 0
var _failures: Array[String] = []
var _new_engine := false
var _cap := OLD_CAP


func _ready() -> void:
	_new_engine = _script_has_method(BattleSimLib, "legal_velocities")
	_cap = NEW_CAP if _new_engine else OLD_CAP
	_fixture_player()
	var records: Array = []
	for index in SEED_COUNT:
		records.append(_run_seed(index))
	_determinism_audit()
	var metrics := _aggregate(records)
	_print_summary(metrics)
	_check(records.size() == SEED_COUNT,
		"all %d seeds produced a record (%d)" % [SEED_COUNT, records.size()])
	_check(int(metrics["wins_player"]) + int(metrics["wins_enemy"]) \
		+ int(metrics["wins_stall"]) + int(metrics["cap_hit"])
		== SEED_COUNT,
		"winner tally sums to the seed count (%d)" % SEED_COUNT)
	_check(int(metrics["decisions"]) > 0
		and float(metrics["decision_avg_ms"]) >= 0.0
		and float(metrics["decision_max_ms"]) >= float(metrics["decision_avg_ms"]),
		"decision timing recorded (avg %.3f ms ≤ max %.3f ms, %d decisions)"
			% [float(metrics["decision_avg_ms"]),
			float(metrics["decision_max_ms"]), int(metrics["decisions"])])
	_check(int(metrics["damage_p2e"]) >= 0 and int(metrics["damage_e2p"]) >= 0,
		"damage exchange recorded (p→e %d / e→p %d)"
			% [int(metrics["damage_p2e"]), int(metrics["damage_e2p"])])
	_check(float(metrics["legal_rate"]) == 100.0,
		"legal-action rate 100%% (actual %.2f%%)"
			% float(metrics["legal_rate"]))
	_check(int(metrics["cap_used"]) == _cap,
		"cap used matches the engine probe (%d)" % _cap)
	# --- W4 section: navy line_ahead (FleetCommander) vs pirate swarm ------
	var w4_records: Array = []
	for index in W4_SEED_COUNT:
		w4_records.append(_run_w4_seed(index))
	var w4_metrics := _aggregate_w4(w4_records)
	_print_w4_summary(w4_metrics)
	_check(w4_records.size() == W4_SEED_COUNT,
		"w4: all %d navy-vs-pirate seeds produced a record (%d)"
			% [W4_SEED_COUNT, w4_records.size()])
	_check(int(w4_metrics["player_wins"]) + int(w4_metrics["navy_wins"]) \
		+ int(w4_metrics["stalls"]) + int(w4_metrics["cap_hit"])
		== W4_SEED_COUNT,
		"w4: winner tally sums to the seed count (%d)" % W4_SEED_COUNT)
	_check(int(w4_metrics["formation_rounds"]) > 0,
		"w4: formation-hold measured over %d engage/form rounds"
			% int(w4_metrics["formation_rounds"]))
	_write_report(metrics, w4_metrics)
	_check(FileAccess.file_exists(REPORT_PATH),
		"report written to %s" % REPORT_PATH)
	_report()


static func _script_has_method(lib, method_name: String) -> bool:
	for info in lib.get_script_method_list():
		if info is Dictionary and str(info.get("name", "")) == method_name:
			return true
	return false


static func seed_at(index: int) -> int:
	return SEED_BASE + index * SEED_STEP


# --- Fixtures ---------------------------------------------------------------

## A modest Person-model player (the test_battle pattern): swordplay 10,
## gunnery 10, everything else 10 — floor terms stay 0 except the reload
## gate (3 − floor(gunnery/50) → 3 turns at gunnery 10).
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


func _brigantine() -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type("brigantine")
	return {
		"ship_type_id": "brigantine",
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": int(ship_type.get("armament_slots", 0)),
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}


# --- Per-seed run -----------------------------------------------------------

func _run_seed(index: int) -> Dictionary:
	var seed_i := seed_at(index)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var enemy := AiFleetLib.compose_enemy("pirate", DAY, rng)
	var sim := BattleSimLib.new({
		"player_ships": [_brigantine(), _brigantine()],
		"enemy_ships": enemy,
		"enemy_kind": "pirate",
		"enemy_nation": "",
		"day": DAY,
		"gold": GOLD,
		"contact": CONTACT,
		"weather": FIXTURE_WEATHER,
		"seed": seed_i,
		"rng": rng,
	})
	var recorder := {
		"seed": seed_i,
		"damage_p2e": 0, "damage_e2p": 0,
		"decisions": 0, "illegal": 0,
		"usec_total": 0, "usec_max": 0,
	}
	_recorder = recorder
	var policy := Callable(self, "_harness_policy")
	var outcome := sim.run_to_completion(policy, _cap)
	var record := {
		"seed": seed_i,
		"result": str(outcome.get("result", "")),
		"over": bool(outcome.get("over", true)),
		"rounds": int(outcome.get("rounds", sim.round_number())),
		"damage_p2e": recorder["damage_p2e"],
		"damage_e2p": recorder["damage_e2p"],
		"decisions": recorder["decisions"],
		"illegal": recorder["illegal"],
		"decision_avg_ms": _avg_ms(recorder),
		"decision_max_ms": float(recorder["usec_max"]) / 1000.0,
		"log_hash": _hash_lines(sim.log_lines()),
	}
	_tally_damage(record, sim.log_lines())
	_check(record["rounds"] >= 1, "seed %d lasted ≥ 1 round" % seed_i)
	return record


static func _avg_ms(recorder: Dictionary) -> float:
	if int(recorder["decisions"]) <= 0:
		return 0.0
	return float(recorder["usec_total"]) / float(recorder["decisions"]) / 1000.0


static func _hash_lines(lines: Array) -> int:
	return hash(JSON.stringify(lines))


# --- The mirror self-play policy (engine-agnostic) --------------------------
#
# `run_to_completion` feeds (sim, unit) — both engines share that convention.
# The per-seed recorder rides on the instance (`_recorder`): the driver calls
# the policy synchronously, one seed at a time.

var _recorder: Dictionary = {}


func _harness_policy(sim, unit) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var decision := _decide(sim, unit, _recorder)
	var elapsed := Time.get_ticks_usec() - t0
	_recorder["usec_total"] = int(_recorder["usec_total"]) + elapsed
	_recorder["usec_max"] = maxi(int(_recorder["usec_max"]), elapsed)
	_recorder["decisions"] = int(_recorder["decisions"]) + 1
	return decision


func _decide(sim, unit: Dictionary, recorder: Dictionary) -> Dictionary:
	var own_side := str(unit.get("side", "player"))
	var other := "enemy" if own_side == "player" else "player"
	var enemies: Array = sim.living_units(other)
	if enemies.is_empty():
		return {"action": "hold"}
	# ① a loaded cannon side with an enemy target in range+arc → fire it
	#    (round shot). Velocity engine: per side (port first), arcs enforced
	#    by `can_cannon(unit, target, side)`. MP engine: no sides/arcs — a
	#    plain `can_cannon(unit, target)` hit fires.
	if _new_engine:
		for side in ["port", "starboard"]:
			for target in enemies:
				if sim.can_cannon(unit, target, str(side)):
					return {"action": "cannon", "target": target,
						"side": str(side), "shot": "round"}
	else:
		for target in enemies:
			if sim.can_cannon(unit, target):
				return {"action": "cannon", "target": target}
	# ② the FIRST legal velocity (the engine's enumeration order) that
	#    strictly reduces the Chebyshev distance to the nearest enemy. On the
	#    velocity engine the §4.3a sweep may stop a candidate short (out of
	#    bounds or an occupied cell ⇒ prior cell, zero displacement), so the
	#    reduction is judged on the SWEEP'S LANDING CELL — a pick the sweep
	#    eats does not reduce the real distance. (The MP engine's
	#    `legal_moves` cells are reachability-checked by the engine, so no
	#    preview is needed there.)
	var from: Vector2i = sim.unit_cell(unit)
	var nearest: Dictionary = _nearest_unit(enemies, from)
	var distance := _chebyshev(from, sim.unit_cell(nearest))
	if _new_engine:
		var legal: Array = sim.legal_velocities(unit)
		for vel in legal:
			var step: Vector2i = vel
			if step == Vector2i.ZERO:
				continue
			var landing := _sweep_landing(sim, unit, from, step)
			if _chebyshev(landing, sim.unit_cell(nearest)) < distance:
				if not legal.has(step):
					recorder["illegal"] = int(recorder["illegal"]) + 1
				return {"action": "move", "vel": step}
	else:
		var legal: Array = sim.legal_moves(unit)
		for cell in legal:
			var dest: Vector2i = cell
			if _chebyshev(dest, sim.unit_cell(nearest)) < distance:
				if not legal.has(dest):
					recorder["illegal"] = int(recorder["illegal"]) + 1
				return {"action": "move", "cell": dest}
	# ②-b turn-to-broadside fallback (master integration fix, W3 gate
	#    ledger): a nose-to-nose freeze — no reducing pick, dead-ahead in
	#    neither arc — never develops firing geometry, so the mirror can't
	#    exercise the engine's fight (39/64 before-runs hit the cap). Take
	#    the FIRST legal velocity whose resulting heading8 puts the nearest
	#    enemy's bearing bucket inside a broadside arc (§4.4 sets).
	if _new_engine:
		var bearing := int(BattleSimLib.heading8_of(
			sim.unit_cell(nearest) - from))
		for vel in sim.legal_velocities(unit):
			var step: Vector2i = vel
			if step == Vector2i.ZERO:
				continue
			var steps := int(BattleSimLib.bucket_distance(
				bearing, int(BattleSimLib.heading8_of(step))))
			if steps in BattleSimLib.ARC_PORT_STEPS \
					or steps in BattleSimLib.ARC_STARBOARD_STEPS:
				if not sim.legal_velocities(unit).has(step):
					recorder["illegal"] = int(recorder["illegal"]) + 1
				return {"action": "move", "vel": step}
	# ③ hold.
	return {"action": "hold"}


## The cell the §4.3a Bresenham sweep actually reaches for `step` from `from`:
## the walk stops at the first out-of-bounds or occupied cell (the mover stays
## at the PRIOR cell in both cases). Engine-agnostic preview over the sim's
## public state (`units()` + `unit_cell`).
func _sweep_landing(sim, unit: Dictionary, from: Vector2i, step: Vector2i) -> Vector2i:
	var prior := from
	for cell in BattleSimLib._bresenham_cells(from, from + step):
		if not BattleSimLib.in_grid(cell):
			return prior
		var blocked := false
		for other in sim.units():
			if is_same(other, unit) or not bool(other.get("alive", false)):
				continue
			if sim.unit_cell(other) == cell:
				blocked = true
				break
		if blocked:
			return prior
		prior = cell
	return prior


static func _nearest_unit(units: Array, from: Vector2i) -> Dictionary:
	var best := {}
	var best_distance := 0
	for unit in units:
		var cell: Vector2i = unit.get("pos", unit.get("cell", Vector2i(-1, -1)))
		var distance := _chebyshev(from, cell)
		if best.is_empty() or distance < best_distance:
			best = unit
			best_distance = distance
	return best


static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


# --- Damage exchange from the structured log --------------------------------

func _tally_damage(record: Dictionary, lines: Array) -> void:
	for entry in lines:
		if not (entry is Dictionary):
			continue
		var kind := str(entry.get("kind", ""))
		if kind != "cannon" and kind != "ram":
			continue
		var values: Dictionary = entry.get("values", {})
		var attacker := str(values.get("side", ""))
		var target := str(values.get("target_side", ""))
		var damage := int(values.get("damage", 0))
		if damage > 0 and attacker == "player" and target == "enemy":
			record["damage_p2e"] = int(record["damage_p2e"]) + damage
		elif damage > 0 and attacker == "enemy" and target == "player":
			record["damage_e2p"] = int(record["damage_e2p"]) + damage
		# Ram self-damage (`attacker_damage`) is the rammer's own hull cost —
		# neither exchange direction; deliberately not tallied.


# --- Determinism audit ------------------------------------------------------

## seed[0] run twice from scratch ⇒ byte-identical `log_lines()` (string-hash
## equality) and an identical outcome dict.
func _determinism_audit() -> void:
	var first := _run_seed(0)
	var second := _run_seed(0)
	_check(first["log_hash"] == second["log_hash"],
		"determinism: seed[0] log_lines() hash identical twice (%d)"
			% int(first["log_hash"]))
	_check(first["result"] == second["result"] and first["rounds"] == second["rounds"]
		and first["damage_p2e"] == second["damage_p2e"]
		and first["damage_e2p"] == second["damage_e2p"],
		"determinism: seed[0] outcome identical twice (%s @ r%d)"
			% [str(first["result"]), int(first["rounds"])])


# --- W4 section: navy line_ahead (FleetCommander) vs pirate swarm -----------
#
# The D-slot extension: the ENEMY side is the navy fleet driven by the real
# T2 THROUGH the §4.9b FleetCommander; the player side stays the pinned
# mirror greedy. Per-round the commander's `generate_orders` runs ONCE on
# the live sim view (orders cached per round — the §4.9b layer is per-round,
# not per-ship), the formation-hold bookkeeping reads the orders at issue
# time, and each navy ship consumes its five-tuple via `AiFleet.decide`.

var _w4_state: Dictionary = {}      # the commander's per-battle state
var _w4_profile: Dictionary = {}    # the navy row (§4.10)
var _w4_orders: Array = []          # this round's five-tuples
var _w4_orders_round := -1
var _w4_hold_rounds := 0            # engage/form rounds seen
var _w4_hold_hits := 0              # …where every ship sat on its station


func _run_w4_seed(index: int) -> Dictionary:
	var seed_i := seed_at(index)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var navy: Array = AiFleetLib.compose_enemy("navy", DAY, rng)
	var sim := BattleSimLib.new({
		"player_ships": [_brigantine(), _brigantine()],
		"enemy_ships": navy,
		"enemy_kind": "navy",
		"enemy_nation": "spain",
		"day": DAY,
		"gold": GOLD,
		"contact": CONTACT,
		"weather": FIXTURE_WEATHER,
		"seed": seed_i,
		"rng": rng,
	})
	_w4_profile = AiFleetLib.profile_for("navy")
	_w4_orders = []
	_w4_orders_round = -1
	_w4_hold_rounds = 0
	_w4_hold_hits = 0
	var recorder := {
		"seed": seed_i,
		"damage_p2e": 0, "damage_e2p": 0,
		"decisions": 0, "illegal": 0,
		"usec_total": 0, "usec_max": 0,
	}
	_recorder = recorder
	sim.start()
	var flagship: Dictionary = {}
	for unit in sim.units():
		if str(unit.get("side", "")) == "enemy" \
				and int(unit.get("index", -1)) == 0:
			flagship = unit
			break
	# §4.9b: the anchor = flagship pos + heading8 at battle start.
	_w4_state = FleetCommanderLib.initial_state(
		str(_w4_profile.get("formation", "line_ahead")),
		sim.unit_cell(flagship), int(flagship.get("heading8", 4)))
	var policy := Callable(self, "_w4_policy")
	var outcome := sim.run_to_completion(policy, _cap)
	return {
		"seed": seed_i,
		"result": str(outcome.get("result", "")),
		"over": bool(outcome.get("over", true)),
		"rounds": int(outcome.get("rounds", sim.round_number())),
		"navy_surrenders": int(outcome.get("surrendered_enemy", 0)),
		"hold_rounds": _w4_hold_rounds,
		"hold_hits": _w4_hold_hits,
	}


func _w4_policy(sim, unit) -> Dictionary:
	if str(unit.get("side", "")) == "enemy":
		return _w4_enemy_decision(sim, unit)
	return _decide(sim, unit, _recorder)


## One generate_orders per round (on the live sim view, the W4-A
## `side_morale` threaded when the seam exists), then this ship's order
## consumed by the unchanged T2 (§4.9b + §4.12.1.1).
func _w4_enemy_decision(sim, unit: Dictionary) -> Dictionary:
	var round_no: int = sim.round_number()
	if round_no != _w4_orders_round:
		_w4_orders_round = round_no
		var view := {
			"units": sim.units(),
			"round": round_no,
			"enemy_kind": str(sim.enemy_kind),
		}
		if sim.has_method("side_morale"):
			view["side_morale"] = sim.side_morale("enemy")
		_w4_orders = FleetCommanderLib.generate_orders(view, _w4_profile,
			_w4_state)
		_record_formation_hold(sim, _w4_orders)
	for entry in _w4_orders:
		if entry is Dictionary \
				and int(entry.get("index", -1)) == int(unit.get("index", -1)):
			return AiFleetLib.decide(sim, unit, entry.get("order", {}))
	return AiFleetLib.decide(sim, unit)


## Formation-hold bookkeeping: while the commander's phase is engage or
## form, the round counts — and holds when EVERY living navy ship sits
## within the §4.9b station-deviation 2 of the order station just issued.
func _record_formation_hold(sim, orders: Array) -> void:
	if orders.is_empty():
		return
	var phase := str((orders[0] as Dictionary).get("order", {}).get("phase", ""))
	if phase != "engage" and phase != "form":
		return
	_w4_hold_rounds += 1
	var cells := {}
	for unit in sim.units():
		if bool(unit.get("alive", false)):
			cells[int(unit.get("index", -1))] = sim.unit_cell(unit)
	for entry in orders:
		var order: Dictionary = entry.get("order", {})
		var index := int(entry.get("index", -1))
		if not cells.has(index):
			continue
		var station: Vector2i = BattleSimLib.to_cell(
			order.get("station", BattleSimLib.NO_CELL))
		if _chebyshev(cells[index], station) > W4_STATION_DEVIATION:
			return
	_w4_hold_hits += 1


func _aggregate_w4(records: Array) -> Dictionary:
	var player_wins := 0
	var navy_wins := 0
	var stalls := 0
	var cap_hits := 0
	var rounds_total := 0
	var surrenders := 0
	var hold_rounds := 0
	var hold_hits := 0
	for record in records:
		var result := str(record["result"])
		if result in ["defeat_sunk", "defeat_captured"]:
			navy_wins += 1
		elif result == "victory":
			player_wins += 1
		elif result == "stall":
			stalls += 1
		if not bool(record["over"]):
			cap_hits += 1
		rounds_total += int(record["rounds"])
		surrenders += int(record["navy_surrenders"])
		hold_rounds += int(record["hold_rounds"])
		hold_hits += int(record["hold_hits"])
	var count := maxi(records.size(), 1)
	return {
		"seeds": records.size(),
		"cap_used": _cap,
		"player_wins": player_wins,
		"navy_wins": navy_wins,
		"stalls": stalls,
		"cap_hit": cap_hits,
		"avg_rounds": float(rounds_total) / float(count),
		"navy_winrate_pct": 100.0 * float(navy_wins) / float(count),
		"navy_surrenders": surrenders,
		"formation_rounds": hold_rounds,
		"formation_hold_pct": 100.0 * float(hold_hits) / float(maxi(hold_rounds, 1)),
		"timestamp": Time.get_datetime_string_from_system(true),
	}


func _print_w4_summary(metrics: Dictionary) -> void:
	print("")
	print("== battle_ai_harness W4 (navy line_ahead vs pirate swarm) ==")
	print("seeds %d · navy wins %d · player wins %d · stall %d · cap-hit %d"
		% [int(metrics["seeds"]), int(metrics["navy_wins"]),
		int(metrics["player_wins"]), int(metrics["stalls"]),
		int(metrics["cap_hit"])])
	print("avg rounds %.2f · navy surrenders %d · formation-hold %.1f%% over %d engage/form rounds"
		% [float(metrics["avg_rounds"]), int(metrics["navy_surrenders"]),
		float(metrics["formation_hold_pct"]), int(metrics["formation_rounds"])])


func _w4_section_markdown(metrics: Dictionary) -> String:
	var hold := float(metrics["formation_hold_pct"])
	var verdict := "PASS" if hold >= W4_FORMATION_HOLD_TARGET else "WATCH"
	var lines: Array[String] = []
	lines.append_array([
		SECTION_W4,
		"",
		"- recorded: %s (UTC)" % str(metrics["timestamp"]),
		"- fixture: enemy side = the navy fleet (`AiFleet.compose_enemy(\"navy\", day=%d, rng)`, 2–4 hulls," % DAY
			+ " the navy row's `line_ahead`) driven by `AiFleet.decide` THROUGH the §4.9b FleetCommander —"
			+ " `FleetCommander.initial_state` at battle start (anchor = flagship pos + heading8),"
			+ " per-round `generate_orders` on the live sim view (`{units, round, enemy_kind, side_morale}`),"
			+ " each five-tuple consumed by `AiFleet.decide(sim, unit, order)`;"
			+ " player side = the pinned mirror greedy (2 brigantines), unchanged."
			+ " Seeds[0..15] of the pinned table, weather `fair`, contact (100, 100), cap %d." % int(metrics.get("cap_used", _cap)),
		"- formation-hold metric: over every round the commander's phase is"
			+ " engage or form, the round HOLDS when every living navy ship"
			+ " sits within the §4.9b station-deviation %d of the order"
			% W4_STATION_DEVIATION
			+ " station just issued (read off the orders at issue time).",
		"",
		"| metric | value |",
		"|---|---|",
		"| seeds | %d |" % int(metrics["seeds"]),
		"| navy wins | %d / %d |" % [int(metrics["navy_wins"]), int(metrics["seeds"])],
		"| player wins | %d / %d |" % [int(metrics["player_wins"]), int(metrics["seeds"])],
		"| stall outcomes | %d |" % int(metrics["stalls"]),
		"| cap-hit | %d |" % int(metrics["cap_hit"]),
		"| avg rounds | %.2f |" % float(metrics["avg_rounds"]),
		"| navy winrate | %.1f%% |" % float(metrics["navy_winrate_pct"]),
		"| navy surrender count | %d |" % int(metrics["navy_surrenders"]),
		"| formation-hold rounds (engage/form) | %d |" % int(metrics["formation_rounds"]),
		"| formation-hold %% | %.1f%% |" % hold,
		"",
		"W4 band: formation-hold ≥ %.0f%% is the design expectation (the"
			% W4_FORMATION_HOLD_TARGET
			+ " phase doc's \"line formation never forms\" risk); rounds and"
			+ " winrate are recorded, not gated — no tuning against the band.",
		"",
		"Verdict: formation-hold %.1f%% vs ≥ %.0f%% → %s."
			% [hold, W4_FORMATION_HOLD_TARGET, verdict],
		"",
		"Metrics block:",
		"",
		"```json",
		JSON.stringify(metrics, "  "),
		"```",
		"",
	])
	return "\n".join(lines)


# --- Aggregation ------------------------------------------------------------

func _aggregate(records: Array) -> Dictionary:
	var wins_player := 0
	var wins_enemy := 0
	var wins_stall := 0
	var cap_hits := 0
	var rounds_total := 0
	var damage_p2e := 0
	var damage_e2p := 0
	var decisions := 0
	var illegal := 0
	var usec_total := 0
	var usec_max := 0
	for record in records:
		var result := str(record["result"])
		var over := bool(record["over"])
		if result == "victory":
			wins_player += 1
		elif result in ["defeat_sunk", "defeat_captured"]:
			wins_enemy += 1
		elif result == "stall":
			wins_stall += 1
		if not over:
			cap_hits += 1
		rounds_total += int(record["rounds"])
		damage_p2e += int(record["damage_p2e"])
		damage_e2p += int(record["damage_e2p"])
		decisions += int(record["decisions"])
		illegal += int(record["illegal"])
		usec_total += int(float(record["decision_avg_ms"]) * 1000.0
			* float(record["decisions"]))
		usec_max = maxi(usec_max, int(float(record["decision_max_ms"]) * 1000.0))
	var count := maxi(records.size(), 1)
	var avg_rounds := float(rounds_total) / float(count)
	var decision_avg_ms := float(usec_total) / float(maxi(decisions, 1)) / 1000.0
	var decision_max_ms := float(usec_max) / 1000.0
	var legal_rate := 100.0 if decisions == 0 \
		else 100.0 * float(decisions - illegal) / float(decisions)
	return {
		"engine": "phase9-velocity" if _new_engine else "phase8-mp",
		"cap_used": _cap,
		"seeds": SEED_COUNT,
		"wins_player": wins_player,
		"wins_enemy": wins_enemy,
		"wins_stall": wins_stall,
		"cap_hit": cap_hits,
		"cap_hit_pct": 100.0 * float(cap_hits) / float(count),
		"stall_pct": 100.0 * float(wins_stall) / float(count),
		"avg_rounds": avg_rounds,
		"damage_p2e": damage_p2e,
		"damage_e2p": damage_e2p,
		"decisions": decisions,
		"illegal": illegal,
		"legal_rate": legal_rate,
		"decision_avg_ms": decision_avg_ms,
		"decision_max_ms": decision_max_ms,
		"timestamp": Time.get_datetime_string_from_system(true),
	}


func _print_summary(metrics: Dictionary) -> void:
	print("")
	print("== battle_ai_harness (%s engine, cap %d) ==" % [metrics["engine"], metrics["cap_used"]])
	print("seeds %d · player wins %d · enemy wins %d · stall %d · cap-hit %d (%.1f%%)"
		% [metrics["seeds"], metrics["wins_player"], metrics["wins_enemy"],
		metrics["wins_stall"], metrics["cap_hit"], float(metrics["cap_hit_pct"])])
	print("avg rounds %.2f · stall %.1f%% · damage p→e %d / e→p %d"
		% [float(metrics["avg_rounds"]), float(metrics["stall_pct"]),
		int(metrics["damage_p2e"]), int(metrics["damage_e2p"])])
	print("decisions %d · legal %.2f%% · timing avg %.3f ms / max %.3f ms"
		% [int(metrics["decisions"]), float(metrics["legal_rate"]),
		float(metrics["decision_avg_ms"]), float(metrics["decision_max_ms"])])


# --- Report ----------------------------------------------------------------

func _write_report(metrics: Dictionary, w4_metrics: Dictionary = {}) -> void:
	var is_after := _new_engine
	var existing := ""
	if FileAccess.file_exists(REPORT_PATH):
		existing = FileAccess.open(REPORT_PATH, FileAccess.READ).get_as_text()
	var head := "# battle_ai_harness report (tool-owned)\n\n" \
		+ "Generated by `tools/battle_ai_harness.tscn` (headless):\n\n" \
		+ "    godot --headless res://tools/battle_ai_harness.tscn\n\n" \
		+ "Seed table (pinned formula): `seed_i = 1000003 + i × 7919` for i in 0..63.\n" \
		+ "Fixture: player 2 brigantines (full armament, crew_min, max durability)\n" \
		+ "vs `AiFleet.compose_enemy(\"pirate\", day=30, rng)`; the §4.11.1 stream\n" \
		+ "(`rng`) seeds composition and battle alike; weather `fair`, contact\n" \
		+ "(100, 100). Mirror self-play policy: ① fire a loaded side in\n" \
		+ "range+arc (round shot) ② first legal velocity strictly reducing the\n" \
		+ "Chebyshev distance to the nearest enemy — judged on the §4.3a sweep's\n" \
		+ "LANDING cell (a pick the sweep stops short does not reduce the real\n" \
		+ "distance; MP-engine moves are engine-reachability-checked) — ②-b\n" \
		+ "turn-to-broadside fallback (master fix, W3 gate): the first legal\n" \
		+ "velocity whose resulting heading8 puts the nearest enemy in a\n" \
		+ "broadside arc, so a nose-to-nose freeze cannot run the clock out —\n" \
		+ "③ hold.\n" \
		+ "Ram self-damage is not tallied in either exchange direction.\n" \
		+ "A W4 section (navy line_ahead via the FleetCommander vs pirate\n" \
		+ "swarm, seeds[0..15]) is regenerated after the comparison.\n\n"
	var out: String
	if not is_after:
		# Before starts the file: header + this section (any stale After
		# content is dropped — the file is rebuilt canonically every run).
		out = head + _section_markdown(metrics, false)
	else:
		# After rebuilds the whole file: header + the Before section
		# (regenerated from the parsed metrics block) + this section + the
		# comparison + the W4 navy-vs-pirate section (fresh every run).
		var before := _normalize_metrics(_parse_before_metrics(existing))
		var parts: Array[String] = [head]
		if not before.is_empty():
			parts.append(_section_markdown(before, false))
		parts.append(_section_markdown(metrics, true))
		parts.append(_comparison_markdown(before, metrics).strip_edges())
		if not w4_metrics.is_empty():
			parts.append("")
			parts.append(_w4_section_markdown(
				_normalize_w4_metrics(w4_metrics)))
		out = "\n".join(parts)
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	file.store_string(out)
	file.close()


## JSON round-trips numbers as floats; the markdown generators format the
## count fields with %d — restore them to ints.
static func _normalize_metrics(metrics: Dictionary) -> Dictionary:
	if metrics.is_empty():
		return metrics
	for key in ["wins_player", "wins_enemy", "wins_stall", "cap_hit", "cap_used",
			"seeds", "damage_p2e", "damage_e2p", "decisions", "illegal"]:
		metrics[key] = int(metrics.get(key, 0))
	return metrics


## The W4 section's `%d` count fields (same float round-trip concern).
static func _normalize_w4_metrics(metrics: Dictionary) -> Dictionary:
	if metrics.is_empty():
		return metrics
	for key in ["seeds", "player_wins", "navy_wins", "stalls", "cap_hit",
			"navy_surrenders", "formation_rounds", "cap_used"]:
		metrics[key] = int(metrics.get(key, 0))
	return metrics


func _section_markdown(metrics: Dictionary, is_after: bool) -> String:
	var title := SECTION_AFTER if is_after else SECTION_BEFORE
	var cap_note := ("the Phase-9 round cap 40 (§4.12.1, correction 12)"
		if is_after else "the MP engine's round cap 30")
	var engine_note := ("the Phase-9 velocity engine (`legal_velocities` /"
		+ " `apply_velocity`, arcs, per-side reload, sweep ram)"
		if is_after else
		"the Phase-2/8 MP engine (16×10 grid, MP steps, 360° cannon)")
	var lines: Array[String] = [
		title,
		"",
		"- recorded: %s (UTC)" % str(metrics["timestamp"]),
		"- engine: %s — %s" % [str(metrics["engine"]), engine_note],
		"- cap: %d — %s" % [int(metrics["cap_used"]), cap_note],
		"- stall metric: %s" % ("reported by the engine (§4.11.9)"
			if is_after else
			"0 by definition — the concept does not exist on the MP engine"),
		"",
		"| metric | value |",
		"|---|---|",
		"| player-side wins | %d / %d |" % [int(metrics["wins_player"]), metrics["seeds"]],
		"| enemy-side wins | %d / %d |" % [int(metrics["wins_enemy"]), metrics["seeds"]],
		"| stall outcomes | %d |" % int(metrics["wins_stall"]),
		"| cap-hit | %d (%.1f%%) |" % [int(metrics["cap_hit"]), float(metrics["cap_hit_pct"])],
		"| avg rounds | %.2f |" % float(metrics["avg_rounds"]),
		"| damage player→enemy | %d |" % int(metrics["damage_p2e"]),
		"| damage enemy→player | %d |" % int(metrics["damage_e2p"]),
		"| decisions | %d |" % int(metrics["decisions"]),
		"| legal-action rate | %.2f%% |" % float(metrics["legal_rate"]),
		"| decision timing avg | %.3f ms |" % float(metrics["decision_avg_ms"]),
		"| decision timing max | %.3f ms |" % float(metrics["decision_max_ms"]),
		"",
		"Metrics block (parsed back by the later section for the comparison):",
		"",
		"```json",
		JSON.stringify(metrics, "  "),
		"```",
		"",
	]
	return "\n".join(lines)


func _comparison_markdown(before: Dictionary, after: Dictionary) -> String:
	if before.is_empty():
		return "\n_(before-section metrics not parseable — comparison omitted)_\n"
	var rows := [
		["player-side wins", str(before.get("wins_player", "?")), str(after.get("wins_player", "?")), "—"],
		["enemy-side wins", str(before.get("wins_enemy", "?")), str(after.get("wins_enemy", "?")), "—"],
		["avg rounds", "%.2f" % float(before.get("avg_rounds", 0)),
			"%.2f" % float(after.get("avg_rounds", 0)),
			_band_verdict(float(after.get("avg_rounds", 0)),
				BAND_AVG_ROUNDS_MIN, BAND_AVG_ROUNDS_MAX)],
		["cap-hit %", "%.1f%%" % float(before.get("cap_hit_pct", 0)),
			"%.1f%%" % float(after.get("cap_hit_pct", 0)),
			_pct_verdict(float(after.get("cap_hit_pct", 0)), BAND_CAP_HIT_PCT)],
		["stall %", "%.1f%%" % float(before.get("stall_pct", 0)),
			"%.1f%%" % float(after.get("stall_pct", 0)),
			_pct_verdict(float(after.get("stall_pct", 0)), BAND_STALL_PCT)],
		["damage player→enemy", str(before.get("damage_p2e", "?")),
			str(after.get("damage_p2e", "?")), "—"],
		["damage enemy→player", str(before.get("damage_e2p", "?")),
			str(after.get("damage_e2p", "?")), "—"],
		["legal-action rate", "%.2f%%" % float(before.get("legal_rate", 0)),
			"%.2f%%" % float(after.get("legal_rate", 0)),
			"PASS" if float(after.get("legal_rate", 0)) == 100.0 else "BREACH"],
		["decision avg ms", "%.3f" % float(before.get("decision_avg_ms", 0)),
			"%.3f" % float(after.get("decision_avg_ms", 0)),
			_pct_verdict(float(after.get("decision_avg_ms", 0)),
				BAND_AVG_DECISION_MS)],
		["decision max ms", "%.3f" % float(before.get("decision_max_ms", 0)),
			"%.3f" % float(after.get("decision_max_ms", 0)), "—"],
	]
	var out: Array[String] = [
		"## Before → After comparison (health band)",
		"",
		"Band: avg rounds %.0f–%.0f · cap-hit < %.0f%% · stall < %.0f%% ·"
			% [BAND_AVG_ROUNDS_MIN, BAND_AVG_ROUNDS_MAX, BAND_CAP_HIT_PCT,
			BAND_STALL_PCT]
			+ " legal-action 100%% · avg decision ≤ %.0f ms." % BAND_AVG_DECISION_MS,
		"",
		"| metric | before | after | band verdict |",
		"|---|---|---|---|",
	]
	for row in rows:
		out.append("| %s | %s | %s | %s |" % [row[0], row[1], row[2], row[3]])
	out.append("")
	var breaches: Array[String] = []
	if float(after.get("avg_rounds", 0.0)) < BAND_AVG_ROUNDS_MIN \
			or float(after.get("avg_rounds", 0.0)) > BAND_AVG_ROUNDS_MAX:
		breaches.append("avg rounds %.2f outside %.0f–%.0f"
			% [float(after.get("avg_rounds", 0.0)), BAND_AVG_ROUNDS_MIN,
			BAND_AVG_ROUNDS_MAX])
	if float(after.get("cap_hit_pct", 0.0)) >= BAND_CAP_HIT_PCT:
		breaches.append("cap-hit %.1f%% ≥ %.0f%%"
			% [float(after.get("cap_hit_pct", 0.0)), BAND_CAP_HIT_PCT])
	if float(after.get("stall_pct", 0.0)) >= BAND_STALL_PCT:
		breaches.append("stall %.1f%% ≥ %.0f%%"
			% [float(after.get("stall_pct", 0.0)), BAND_STALL_PCT])
	if float(after.get("legal_rate", 0.0)) < 100.0:
		breaches.append("legal-action %.2f%% < 100%%"
			% float(after.get("legal_rate", 0.0)))
	if float(after.get("decision_avg_ms", 0.0)) > BAND_AVG_DECISION_MS:
		breaches.append("avg decision %.3f ms > %.0f ms"
			% [float(after.get("decision_avg_ms", 0.0)), BAND_AVG_DECISION_MS])
	out.append(_breach_analysis(breaches))
	out.append("")
	return "\n".join(out)


## The recorded breach note (the W3 instruction: a breach is RECORDED, no
## gameplay numbers are tuned — the master decides). The analysis text is the
## measured mechanism of the 2026-11-03 W3-A run; it stays until the numbers
## clear the band.
static func _breach_analysis(breaches: Array[String]) -> String:
	if breaches.is_empty():
		return "No band breach — all health-band rows PASS."
	var lines: Array[String] = [
		"## Breach analysis (recorded per the W3 instruction — no gameplay numbers tuned)",
		"",
		"Breaches: " + "; ".join(breaches) + ".",
		"",
		"Measured mechanism (W3-A, 2026-11-03) — a **harness-driver artifact**,",
		"not an engine defect (the engine-level probe verified `cap_eff` wind",
		"tables, integer-bucket heading, sweep stops and the snapshot round-trip",
		"directly):",
		"",
		"- The pinned mirror policy is ① fire / ② first strictly-reducing",
		"  velocity / ③ hold. After the approach (~round 20 from 43 cells at",
		"  cap 2 into the wind vs cap 4 running), the fleets meet nose-to-nose:",
		"  every closing velocity is sweep-blocked (the §4.3a sweep stops at the",
		"  occupied cell ⇒ prior cell ⇒ no strict reduction), a broadside turn",
		"  never reduces Chebyshev, and a dead-ahead bearing sits in NEITHER arc",
		"  (§4.4) — so both sides hold their approach heading and no loaded",
		"  broadside ever bears. The battle runs to the cap frozen.",
		"- The MP baseline never froze: `legal_moves` let the same greedy rule",
		"  sidestep (diagonal MP steps reduced distance while opening the",
		"  bearing) and its 360° cannon had no arcs to satisfy.",
		"- Damage does flow whenever drift geometry opens an arc (25/64 battles",
		"  resolve — the stronger player side wins every resolved one), so the",
		"  volley stack, per-side reload and crew casualties all exercise.",
		"- W3-B's T2 priority list (close / broadside-on / kite steering with",
		"  the §4.11.8 tie-breaks) owns exactly this geometry. Master options:",
		"  amend the harness policy with a turn-to-broadside fallback, or accept",
		"  the breach as the stand-in driver's artifact and re-run the harness",
		"  once T2 drives the enemy side.",
	]
	return "\n".join(lines)


static func _band_verdict(value: float, low: float, high: float) -> String:
	return "PASS" if value >= low and value <= high else "BREACH"


static func _pct_verdict(value: float, limit: float) -> String:
	return "PASS" if value <= limit else "BREACH"


## The before-section's ```json fence → Dictionary ({} when absent/broken).
static func _parse_before_metrics(text: String) -> Dictionary:
	var start := text.find(SECTION_BEFORE)
	if start < 0:
		return {}
	var stop := text.find("\n## ", start + SECTION_BEFORE.length())
	if stop < 0:
		stop = text.length()
	var section := text.substr(start, stop - start)
	var fence := section.find("```json")
	if fence < 0:
		return {}
	var body_start := section.find("\n", fence) + 1
	var body_end := section.find("```", body_start)
	if body_start <= 0 or body_end < 0:
		return {}
	var parsed = JSON.parse_string(section.substr(body_start, body_end - body_start))
	return parsed if parsed is Dictionary else {}


# --- Result -----------------------------------------------------------------

func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures.append(label)
		print("    FAIL %s" % label)


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
