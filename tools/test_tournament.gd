extends Node
## Phase-3 task F acceptance tests: the monthly tournament (Phase-9 W3-D
## re-pin) (docs/IMPLEMENT-Phase3.md F; docs/70-* §4.6, §4.9.7; docs/60-*
## §4.11.7.1, §4.11.2 tournament variant, §4.12.1; docs/80-* §4.7.3).
##
##   godot --headless --path . tools/test_tournament.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## W3 seam note: the Phase-3 suite drove the bouts through
## `battle_screen.tscn`. The screen is slot C's in-flight rewrite (this
## branch still carries the retired MP API there and in `ai_fleet.gd`), so
## §10 now builds the bouts DIRECTLY on `BattleSim` with the §4.11.2
## tournament deployment (`deployment: "tournament"`, config key of §4.12.1)
## and drives BOTH sides with this suite's own inline policy callable — the
## harness pattern — never slot B's T2 AI. The bracket semantics (3 bouts,
## the hull ladder, durability carry-over, any non-victory = bracket loss,
## no reputation) are unchanged.

const TournamentLib := preload("res://scripts/quests/tournament.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const Phase3HooksLib := preload("res://scripts/quests/phase3_hooks.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const BattleScene := preload("res://scenes/combat/battle_screen.tscn")

## docs/70-* §4.9.7: the §7.4 capital rotation.
const CAPITALS: Array[String] = [
	"lisbon", "seville", "london", "amsterdam", "istanbul", "venice",
]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_rotation()
	_test_entry_window()
	_test_entry()
	_test_round_fleets()
	_test_winner_payout()
	_test_loser_payout()
	_test_repair_to_half()
	_test_bounty_block()
	await _test_phase3_hooks()
	await _test_bracket_battles()
	await _test_palace_flow()
	_report()


# --- Fixtures -------------------------------------------------------------

func _new_run(port_id: String = "lisbon", day: int = 1) -> void:
	GameState.new_game("portugal", false, "world")
	GameState.day = day
	GameState.gold = 50000
	GameState.current_port = port_id
	# §4.1b port hours: 12:00 — the palace is open for entries.
	GameState.world = {"clock_fraction": 0.5}
	GameState.fame = 0
	GameState.bounties = {}
	GameState.discovery_hints = {}
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.active_quests = []
	GameState.pending_tournament_round = 0
	GameState.last_tournament_outcome = {}
	GameState.titles = {}
	for nation in DataLoader.nations_list:
		GameState.titles[str(nation["id"])] = "none"
		GameState.completed_royal_missions[str(nation["id"])] = 0


# --- 1. Rotation and cycle maths -----------------------------------------

func _test_rotation() -> void:
	_check(TournamentLib.CYCLE_DAYS == 30, "a cycle is 30 days")
	_check(TournamentLib.capitals() == CAPITALS,
		"the capitals are the §7.4 order (%s)" % str(TournamentLib.capitals()))
	_check(TournamentLib.cycle_of(1) == 0, "day 1 starts cycle 0")
	_check(TournamentLib.cycle_of(30) == 0, "day 30 is still cycle 0")
	_check(TournamentLib.cycle_of(31) == 1, "day 31 starts cycle 1")
	_check(TournamentLib.day_of_cycle(1) == 1, "day 1 is cycle day 1")
	_check(TournamentLib.day_of_cycle(30) == 30, "day 30 is cycle day 30")
	_check(TournamentLib.day_of_cycle(31) == 1, "day 31 is cycle day 1 again")
	# The host rotates through all six capitals exactly once per six cycles.
	var hosts: Array = []
	for cycle in range(0, 6):
		hosts.append(TournamentLib.host(cycle * 30 + 1))
	_check(hosts == CAPITALS, "the first six cycles rotate the six capitals (%s)"
		% str(hosts))
	_check(TournamentLib.host(180 + 1) == CAPITALS[0],
		"the rotation repeats on cycle 6 (got %s)"
		% TournamentLib.host(181))
	_check(TournamentLib.host(61) == "london",
		"cycle 2 hosts London (got %s)" % TournamentLib.host(61))


# --- 2. Entry window (cycle days 1–5) ------------------------------------

func _test_entry_window() -> void:
	_new_run("lisbon", 1)
	var open_days: Array = []
	for day in range(1, 31):
		if TournamentLib.in_entry_window(day):
			open_days.append(day)
	_check(open_days == [1, 2, 3, 4, 5],
		"the window is exactly days 1–5 (%s)" % str(open_days))
	_check(TournamentLib.in_entry_window(31), "cycle 1 re-opens on day 31")
	_check(not TournamentLib.in_entry_window(36), "day 36 is out of window")

	var status := TournamentLib.status("lisbon", 3)
	_check(bool(status["open"]), "lisbon is open on cycle day 3")
	_check(str(status["host"]) == "lisbon", "the host is Lisbon")
	_check(int(status["window_first"]) == 1 and int(status["window_last"]) == 5,
		"the status reports window days 1–5")
	_check(int(status["fee"]) == 1000, "the fee is 1,000g")

	var late := TournamentLib.status("lisbon", 7)
	_check(not bool(late["open"]), "day 7 is closed")
	_check(str(late["blocked"]) == "tournament.closed",
		"the closed reason is tournament.closed (%s)" % str(late["blocked"]))

	var elsewhere := TournamentLib.status("seville", 3)
	_check(not bool(elsewhere["open"]), "Seville is not the host this cycle")
	_check(str(elsewhere["blocked"]) == "tournament.not_host",
		"the wrong-host reason is tournament.not_host (%s)"
		% str(elsewhere["blocked"]))
	_check(int(elsewhere["window_first"]) == 1,
		"a non-host still learns the window")


# --- 3. Entry: fee, one entry per cycle, gold gate -----------------------

func _test_entry() -> void:
	_new_run("lisbon", 2)
	GameState.gold = 5000
	_check(TournamentLib.enter("lisbon", 2), "the entry succeeds")
	_check(GameState.gold == 4000, "the fee is charged (5000 → %d)" % GameState.gold)
	_check(TournamentLib.already_entered(2), "the cycle is marked entered")
	var again := TournamentLib.status("lisbon", 2)
	_check(not bool(again["open"]), "a second entry is blocked")
	_check(str(again["blocked"]) == "tournament.entered",
		"the repeat reason is tournament.entered (%s)" % str(again["blocked"]))
	_check(not TournamentLib.enter("lisbon", 2), "and no second fee is charged")
	_check(GameState.gold == 4000, "the purse is unchanged by the refusal")
	# The next cycle is a fresh entry.
	_check(not TournamentLib.already_entered(31), "the next cycle starts unentered")
	# Short of gold.
	_new_run("lisbon", 2)
	GameState.gold = 999
	var poor := TournamentLib.status("lisbon", 2)
	_check(not bool(poor["open"]), "999g cannot enter")
	_check(str(poor["blocked"]) == "market.no_gold",
		"the poor reason is market.no_gold (%s)" % str(poor["blocked"]))
	_check(not TournamentLib.enter("lisbon", 2), "the poor entry is refused")


# --- 4. Per-round fleets (brigantine → carrack → galleon) ---------------

func _test_round_fleets() -> void:
	_new_run()
	_check(TournamentLib.ROUND_HULLS == ["brigantine", "carrack", "galleon"],
		"the hull ladder is brigantine → carrack → galleon")
	_check(TournamentLib.ROUNDS == 3, "the bracket has three bouts")
	for row in [[1, "brigantine"], [2, "carrack"], [3, "galleon"]]:
		var ships := TournamentLib.round_fleet(int(row[0]))
		_check(ships.size() == 1, "bout %d fields one hull" % int(row[0]))
		var ship: Dictionary = ships[0]
		var ship_type: Dictionary = DataLoader.get_ship_type(str(row[1]))
		_check(str(ship["ship_type_id"]) == str(row[1]),
			"bout %d is a %s" % [int(row[0]), str(row[1])])
		_check(int(ship["durability"]) == int(ship_type["durability"]),
			"bout %d starts at full durability" % int(row[0]))
		_check(int(ship["crew"]) == int(ship_type["crew_min"]),
			"bout %d has crew_min crew" % int(row[0]))
		_check(int(ship["cannons"]) == int(ship_type["armament_slots"]),
			"bout %d carries armament_slots cannons" % int(row[0]))
	var encounter := TournamentLib.encounter(2, 40)
	_check(str(encounter["kind"]) == "tournament",
		"the bout's enemy_kind is tournament (no reputation deltas)")
	_check(str(encounter["id"]).begins_with("tournament_"),
		"the encounter id is tagged tournament_ (%s)" % str(encounter["id"]))
	_check(Phase3HooksLib.is_tournament(str(encounter["id"])),
		"Phase3Hooks recognises the bout")
	_check(not Phase3HooksLib.is_tournament("hf_1_2_pirate"),
		"an ordinary marker is not a bout")
	# `60-*` §4.11.7.1: the only combat-code change the seam needs is the tier.
	_check(int(BattleSimLib.FLEET_TIER.get("tournament", -1)) == 2,
		"the tournament tier is 2, like a navy (got %s)"
		% str(BattleSimLib.FLEET_TIER.get("tournament")))
	_check(BattleSimLib.FLEET_TIER.get("pirate") == 1,
		"adding the tier did not disturb the pirate tier")


# --- 5. Winner payout (10,000g + 100 fame) ------------------------------

func _test_winner_payout() -> void:
	_new_run()
	var emitted: Array = []
	var handler := func(outcome: Dictionary) -> void: emitted.append(outcome)
	EventBus.tournament_finished.connect(handler)
	GameState.gold = 1000
	GameState.fame = 50
	var outcome := TournamentLib.settle(true, 0)
	EventBus.tournament_finished.disconnect(handler)
	_check(bool(outcome["won"]), "the win outcome is marked won")
	_check(int(outcome["gold"]) == 10000, "the prize is 10,000g")
	_check(int(outcome["fame"]) == 100, "the prize is +100 fame")
	_check(GameState.gold == 11000, "the purse gains 10,000g (got %d)"
		% GameState.gold)
	_check(GameState.fame == 150, "fame gains 100 (got %d)" % GameState.fame)
	_check(int(outcome["repaired"]) == 0, "a win repairs nothing")
	_check(emitted.size() == 1, "tournament_finished fires once")
	if emitted.size() == 1:
		_check(int((emitted[0] as Dictionary)["gold"]) == 10000,
			"the signal carries the prize block")


# --- 6. Loser payout (500g + free repair to half) ----------------------

func _test_loser_payout() -> void:
	for round_number in [1, 2, 3]:
		_new_run()
		GameState.gold = 1000
		GameState.fame = 50
		var ship: Dictionary = GameState.fleet[0]
		var max_durability := int(ship["durability"])
		ship["durability"] = 1
		var outcome := TournamentLib.settle(false, round_number)
		_check(not bool(outcome["won"]), "round %d loss is marked lost"
			% round_number)
		_check(int(outcome["gold"]) == 500, "the consolation is 500g (round %d)"
			% round_number)
		_check(int(outcome["fame"]) == 0, "a loss grants no fame (round %d)"
			% round_number)
		_check(GameState.gold == 1500, "the purse gains 500g (round %d, got %d)"
			% [round_number, GameState.gold])
		_check(GameState.fame == 50, "fame is untouched by a loss")
		_check(int(outcome["round_reached"]) == round_number,
			"the outcome names the lost bout (%d)" % round_number)
		_check(int(ship["durability"]) == int(ceil(float(max_durability) * 0.5)),
			"the hull is repaired to half (round %d: %d/%d)"
			% [round_number, int(ship["durability"]), max_durability])
		_check(int(outcome["repaired"]) > 0,
			"the outcome reports the points restored (round %d)" % round_number)


# --- 7. repair_to_half only ever raises durability ----------------------

func _test_repair_to_half() -> void:
	_new_run()
	var ship: Dictionary = GameState.fleet[0]
	var max_durability := int(ship["durability"])
	# Already above half: untouched.
	ship["durability"] = max_durability
	_check(TournamentLib.repair_to_half() == 0,
		"a full hull is not touched by the consolation repair")
	_check(int(ship["durability"]) == max_durability, "it stays at max")
	# Exactly half: untouched (the rule is `max(current, ceil(max/2))`).
	var half := int(ceil(float(max_durability) * 0.5))
	ship["durability"] = half
	_check(TournamentLib.repair_to_half() == 0,
		"a hull already at half is not repaired")
	# Below half: raised to half, no further.
	ship["durability"] = 1
	var restored := TournamentLib.repair_to_half()
	_check(restored == half - 1, "the repair restores exactly up to half (%d)"
		% restored)
	_check(int(ship["durability"]) == half, "the hull sits at half durability")
	# The repair is free.
	GameState.gold = 777
	ship["durability"] = 1
	TournamentLib.repair_to_half()
	_check(GameState.gold == 777, "the consolation repair costs nothing (%d)"
		% GameState.gold)


# --- 8. A bountied host blocks entry -----------------------------------

func _test_bounty_block() -> void:
	_new_run("lisbon", 2)
	GameState.player["reputation"]["portugal"] = -60
	BountyLib.evaluate_all()
	_check(BountyLib.has_bounty("portugal"), "portugal issued a bounty")
	_check(BountyLib.is_port_closed("lisbon"), "lisbon is closed by the bounty")
	var status := TournamentLib.status("lisbon", 2)
	_check(not bool(status["open"]), "a bountied host refuses entry")
	_check(str(status["blocked"]) == "tournament.blocked_bounty",
		"the reason is tournament.blocked_bounty (%s)" % str(status["blocked"]))
	_check(not TournamentLib.enter("lisbon", 2), "no entry is recorded")
	_check(GameState.gold == 50000, "and no fee is charged (%d)" % GameState.gold)
	_check(not TournamentLib.already_entered(2), "the cycle stays unentered")


# --- 9. Phase3Hooks bracket stepping ----------------------------------

func _test_phase3_hooks() -> void:
	_new_run("lisbon", 2)
	GameState.gold = 1000
	GameState.fame = 0
	# Bout 1 won → advance to bout 2, no payout yet.
	var advance := Phase3HooksLib.on_tournament_bout({
		"encounter_id": "tournament_0_1", "result": "victory", "kind": "tournament",
	})
	_check(bool(advance.get("won", false)), "bout 1 is a win")
	_check(int(advance.get("next_round", 0)) == 2, "the bracket advances to bout 2")
	_check(Phase3HooksLib.take_pending_bout() == 2,
		"the pending bout is 2 (one-shot)")
	_check(Phase3HooksLib.take_pending_bout() == 0, "the pending bout is consumed")
	_check(GameState.gold == 1000, "no payout after two of three bouts")
	_check(GameState.last_tournament_outcome.is_empty(),
		"no settlement is recorded mid-bracket")

	# Bout 2 won → advance to bout 3.
	Phase3HooksLib.on_tournament_bout({
		"encounter_id": "tournament_0_2", "result": "victory", "kind": "tournament",
	})
	_check(Phase3HooksLib.take_pending_bout() == 3, "the bracket advances to bout 3")

	# Bout 3 won → settle the prize.
	var settled := Phase3HooksLib.on_tournament_bout({
		"encounter_id": "tournament_0_3", "result": "victory", "kind": "tournament",
	})
	_check(bool(settled.get("won", false)), "winning bout 3 wins the tournament")
	_check(int(settled.get("gold", 0)) == 10000, "the prize is 10,000g")
	_check(GameState.gold == 11000, "the prize is paid (got %d)" % GameState.gold)
	_check(Phase3HooksLib.take_pending_bout() == 0,
		"a settled bracket has no pending bout")
	var reported := Phase3HooksLib.take_tournament_outcome()
	_check(not reported.is_empty(), "the settlement is available once")
	_check(Phase3HooksLib.take_tournament_outcome().is_empty(),
		"and only once")

	# A loss in bout 2 settles immediately with the consolation.
	_new_run("lisbon", 2)
	GameState.gold = 1000
	var hurt: Dictionary = GameState.fleet[0]
	hurt["durability"] = 1
	var lost := Phase3HooksLib.on_tournament_bout({
		"encounter_id": "tournament_0_2", "result": "defeat_sunk",
		"kind": "tournament",
	})
	_check(not bool(lost.get("won", false)), "a defeat ends the bracket")
	_check(int(lost.get("gold", 0)) == 500, "the consolation is 500g")
	_check(GameState.gold == 1500, "the consolation is paid")
	_check(Phase3HooksLib.take_pending_bout() == 0, "no next bout after a loss")

	# A non-tournament outcome is ignored.
	_check(Phase3HooksLib.on_tournament_bout({
		"encounter_id": "hf_1_2_pirate", "result": "victory",
	}).is_empty(), "an ordinary battle settles no bracket")


# --- 10. Three real bouts on the velocity engine (§4.11.2 variant) ------

func _test_bracket_battles() -> void:
	_new_run("lisbon", 2)
	# A tournament-strength player fleet so the bracket is winnable and the
	# fights stay deterministic (the fight itself is §4.11's engine, driven
	# by this suite's inline policy on BOTH sides — no slot-B AI seam).
	# Two bouts exercise the velocity-engine seam; bout 3's settlement block
	# is pinned through the hooks in §9, so the sim stops at the re-open.
	var won: Dictionary = _run_bracket({"crew": 120, "cannons": 24}, 2)
	_check(not won.is_empty(), "a bracket runs to a settlement")
	_check(bool(won.get("won", false)),
		"a 120-crew 24-cannon galleon wins the first two bouts (%s)"
			% str(won.get("won")))
	_check((won.get("results", []) as Array) == ["victory", "victory"],
		"two bouts were fought on the velocity engine (%s)"
			% str(won.get("results", [])))
	_check(int(won.get("next_round", 0)) == 3,
		"the second win queues bout 3 (next_round %d)"
		% int(won.get("next_round", 0)))
	_check(Phase3HooksLib.take_pending_bout() == 3,
		"the bracket re-opens mid-way on the pending bout")

	# Durability carries: the fleet ends the bracket damaged, not reset.
	var carried := 0
	for ship in GameState.fleet:
		if int((ship as Dictionary).get("durability", 0)) \
				< int(DataLoader.get_ship_type("galleon")["durability"]):
			carried += 1
	_check(carried > 0 or GameState.fleet.is_empty(),
		"durability carries between bouts (the fleet is not reset)")

	# A hopeless fleet loses bout 1 and takes the consolation.
	_new_run("lisbon", 2)
	GameState.gold = 1000
	var lost: Dictionary = _run_bracket({"crew": 15, "cannons": 0})
	_check(not bool(lost.get("won", false)), "a cannon-less sloop fleet loses the bracket")
	_check(int(lost.get("gold", 0)) == 500, "the loser takes 500g")
	_check(GameState.gold == 1500, "the consolation is paid (got %d)"
		% GameState.gold)

	# §4.11.10: any non-victory is a bracket loss — a `stall` included.
	_new_run("lisbon", 2)
	GameState.gold = 1000
	var stalled: Dictionary = Phase3HooksLib.on_tournament_bout({
		"encounter_id": "tournament_0_1", "result": "stall", "kind": "tournament",
	})
	_check(not bool(stalled.get("won", false)),
		"a stalled bout is a bracket loss like any non-victory (§4.11.10)")
	_check(int(stalled.get("gold", 0)) == 500,
		"the stalled bracket still takes the consolation (%d)"
			% int(stalled.get("gold", 0)))
	_check(Phase3HooksLib.take_pending_bout() == 0,
		"no next bout after a stall")


## Runs the bouts DIRECTLY on BattleSim with the §4.11.2 tournament
## deployment (`deployment: "tournament"` — the §4.12.1 config key), both
## sides driven by this suite's inline fire/close policy. `stop_after` caps
## the bracket (the §10 win bracket stops after bout 2; bout 3's settlement
## is §9's pure-hook pin). The §4.12.4 durability write-back the screen owns
## in production (W3-C seam) is applied inline here, so the carry-over pin
## stays testable on the sim alone.
func _run_bracket(loadout: Dictionary, stop_after: int = TournamentLib.ROUNDS) -> Dictionary:
	GameState.fleet = [FleetLib.new_ship("galleon", int(loadout["crew"]))]
	var ship: Dictionary = GameState.fleet[0]
	ship["cannons"] = int(loadout["cannons"])
	ship["provisions"] = 60
	ship["water"] = 60
	# Phase 8 capture gate (`60-*` §4.11.7): a captured bracket prize joins
	# only with an idle officer to seat — the fixture keeps the base
	# "captured hulls join damaged" semantics by parking one.
	GameState.player["officers"] = ["fx_tour_idle"]
	var settled: Dictionary = {}
	var results: Array = []
	for round_number in range(1, TournamentLib.ROUNDS + 1):
		var sim := BattleSimLib.new({
			"player_ships": GameState.fleet,
			"enemy_ships": TournamentLib.round_fleet(round_number),
			"enemy_kind": "tournament", "enemy_nation": "",
			"day": GameState.day, "gold": GameState.gold,
			"contact": Vector2i(10, 15), "weather": "fair", "wind_dir": "E",
			"current": {"dir": "", "strength": 0},
			"deployment": BattleSimLib.TOURNAMENT_DEPLOYMENT,
			"seed": BattleSimLib.battle_seed_formula(
				GameState.day + round_number, Vector2i(37, 15), GameState.gold, 1),
		})
		sim.start()
		if round_number == 1:
			# §4.11.2 tournament variant, read off the velocity API.
			var p: Dictionary = sim.units()[0]
			var e: Dictionary = sim.units()[1]
			_check(sim.unit_cell(p) == BattleSimLib.TOURNAMENT_PLAYER_CELL
					and sim.unit_cell(e) == BattleSimLib.TOURNAMENT_ENEMY_CELL,
				"§4.11.2: bout 1 deploys at (10,15)/(37,15) (%s/%s)"
					% [str(sim.unit_cell(p)), str(sim.unit_cell(e))])
			_check((p["vel"] as Vector2i) == BattleSimLib.TOURNAMENT_PLAYER_VEL
					and (e["vel"] as Vector2i) == BattleSimLib.TOURNAMENT_ENEMY_VEL,
				"§4.11.2: the bout opens under way — vel (1,0)/(−1,0) (%s/%s)"
					% [str(p["vel"]), str(e["vel"])])
			_check(int(p["heading8"]) == BattleSimLib.heading8_of(Vector2i(1, 0))
					and int(e["heading8"]) == BattleSimLib.heading8_of(Vector2i(-1, 0)),
				"§4.11.2: the pinned velocities set the bout headings")
		var policy := func(active_sim, unit) -> Dictionary:
			return _bout_policy(active_sim, unit)
		var outcome: Dictionary = sim.run_to_completion(policy, BattleSimLib.MAX_ROUNDS)
		var result := str(outcome.get("result", ""))
		results.append(result)
		# §4.11.7.1: a tournament battle contributes no reputation of any kind.
		_check((outcome.get("rep_deltas", {}) as Dictionary).is_empty(),
			"§4.11.7.1: bout %d carries no rep_deltas (%s)"
				% [round_number, str(outcome.get("rep_deltas", {}))])
		# §4.12.4 durability write-back (the screen's production job — W3-C
		# seam): the surviving player hulls carry their battle durability.
		for unit in sim.living_units("player"):
			var fleet_ship: Dictionary = GameState.fleet[int(unit["index"])] \
				if int(unit["index"]) < GameState.fleet.size() else {}
			if not fleet_ship.is_empty():
				fleet_ship["durability"] = int(unit["ship"]["durability"])
		if result != "victory" or round_number == stop_after:
			settled = Phase3HooksLib.on_tournament_bout({
				"encounter_id": "tournament_0_%d" % round_number,
				"result": result, "kind": "tournament",
			})
			settled["results"] = results
			return settled
		# Carry the fleet into the next bout (no repair, no resupply).
	return settled


## The inline bout policy (BOTH sides): fire a loaded side in range+arc
## (round shot); inside cannon range steer the after-move broadside orbit;
## outside it close on the §4.3a sweep landing. Zero dice, no AI module.
func _bout_policy(sim, unit: Dictionary) -> Dictionary:
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
	var best := _chebyshev(from, sim.unit_cell(enemies[0]))
	for enemy in enemies:
		var distance := _chebyshev(from, sim.unit_cell(enemy))
		if distance < best:
			best = distance
			nearest = enemy
	var target_cell: Vector2i = sim.unit_cell(nearest)
	if best <= BattleSimLib.CANNON_RANGE_MAX:
		for vel in sim.legal_velocities(unit):
			var step: Vector2i = vel
			if step == Vector2i.ZERO:
				continue
			var landing := _landing(sim, unit, step)
			if landing == from:
				continue
			if _chebyshev(landing, target_cell) > BattleSimLib.CANNON_RANGE_MAX:
				continue
			var new_bearing := int(BattleSimLib.heading8_of(target_cell - landing))
			var new_heading := int(BattleSimLib.heading8_of(step))
			var steps := int(BattleSimLib.bucket_distance(new_bearing, new_heading))
			if steps in BattleSimLib.ARC_PORT_STEPS \
					or steps in BattleSimLib.ARC_STARBOARD_STEPS:
				return {"action": "move", "vel": step}
		return {"action": "hold"}
	var close_pick := Vector2i.ZERO
	var close_found := false
	var close_best := best
	for vel in sim.legal_velocities(unit):
		var landing := _landing(sim, unit, vel)
		var distance := _chebyshev(landing, target_cell)
		if landing != from and distance < close_best:
			close_best = distance
			close_pick = vel
			close_found = true
	if close_found:
		return {"action": "move", "vel": close_pick}
	return {"action": "hold"}


## The cell the §4.3a Bresenham sweep actually reaches for `step` (the walk
## stops at the first out-of-bounds or occupied cell; the mover stays at the
## PRIOR cell) — the same preview the harness uses.
func _landing(sim, unit: Dictionary, step: Vector2i) -> Vector2i:
	var from: Vector2i = sim.unit_cell(unit)
	var prior := from
	for cell in BattleSimLib._bresenham_cells(from, from + step):
		if not BattleSimLib.in_grid(cell):
			return prior
		for other in sim.units():
			if other == unit or not bool(other.get("alive", false)):
				continue
			if sim.unit_cell(other) == cell:
				return prior
		prior = cell
	return prior


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


# --- 11. The palace screen's tournament row and flow -------------------

func _test_palace_flow() -> void:
	_new_run("lisbon", 2)
	GameState.gold = 5000
	var screen: Control = PalaceScene.instantiate()
	screen.route_to_port = false
	add_child(screen)
	await get_tree().process_frame
	var label: Label = screen.get_node("Rows/TournamentRow/Label")
	var button: Button = screen.get_node("Rows/TournamentRow/Action")
	_check(label.text == I18n.fmt("tournament.status", {
		"port": I18n.t(DataLoader.get_port("lisbon")["name"]),
		"first": 1, "last": 5,
	}), "the tournament row names the host and window (%s)" % label.text)
	_check(button.text == I18n.fmt("tournament.enter", {"fee": "1,000"}),
		"the enter button shows the 1,000g fee (%s)" % button.text)
	_check(not button.disabled, "the entry is open on cycle day 2")
	_check(screen.enter_tournament(), "the palace enters the tournament")
	_check(GameState.gold == 4000, "the fee is paid through the screen")
	var pending = GameState.pending_encounter
	_check((pending is Dictionary and not (pending as Dictionary).is_empty())
		or screen.bout_pending,
		"the screen queues the first bout")
	_check(TournamentLib.already_entered(2), "the cycle is marked entered")

	# Out of window → the row disables with tournament.closed.
	GameState.day = 9
	screen.refresh()
	_check(button.disabled, "the enter button disables out of window")
	_check(button.tooltip_text == I18n.t_key("tournament.closed"),
		"the closed tooltip is tournament.closed (%s)" % button.tooltip_text)

	# Wrong host → tournament.not_host.
	GameState.current_port = "seville"
	GameState.day = 2
	screen.refresh()
	_check(button.disabled, "a non-host palace cannot enter")
	_check(button.tooltip_text == I18n.t_key("tournament.not_host"),
		"the wrong-host tooltip is tournament.not_host (%s)" % button.tooltip_text)

	# A settled bracket is reported on the next open — driven through the
	# screen's own report path on this open screen (§4.9.7's one-shot read
	# is `take_tournament_outcome`, pinned right below).
	_new_run("lisbon", 2)
	GameState.pending_tournament_round = 0
	GameState.last_tournament_outcome = {
		"won": true, "round_reached": 0, "gold": 10000, "fame": 100,
		"repaired": 0,
	}
	var reported: Dictionary = Phase3HooksLib.take_tournament_outcome()
	_check(GameState.last_tournament_outcome.is_empty(),
		"the settlement is consumed by the one-shot read")
	screen._report_tournament(reported)
	label = screen.get_node("Rows/TournamentRow/Label")
	_check(label.text == I18n.fmt("tournament.prize",
		{"gold": "10,000", "fame": 100}),
		"a won bracket reports tournament.prize (%s)" % label.text)

	# A lost bracket reports the consolation (the same open screen re-renders).
	GameState.last_tournament_outcome = {
		"won": false, "round_reached": 2, "gold": 500, "fame": 0,
		"repaired": 12,
	}
	screen._report_tournament(GameState.last_tournament_outcome)
	label = screen.get_node("Rows/TournamentRow/Label")
	_check(label.text == I18n.fmt("tournament.consolation", {"gold": "500"}),
		"a lost bracket reports tournament.consolation (%s)" % label.text)

	screen.queue_free()
	await get_tree().process_frame

	# Both locales, no raw keys.
	_new_run("lisbon", 2)
	screen = PalaceScene.instantiate()
	screen.route_to_port = false
	add_child(screen)
	await get_tree().process_frame
	var leaked: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		for line in screen.all_text():
			if str(line).contains("<") and str(line).contains(">"):
				leaked.append("%s: %s" % [locale, str(line)])
	_check(leaked.is_empty(), "the tournament row prints no raw <key> (%s)"
		% str(leaked.slice(0, 3)))
	I18n.set_locale("zh")
	label = screen.get_node("Rows/TournamentRow/Label")
	_check(label.text.contains(_ui_zh("tournament.status").split("{")[0]),
		"the zh row uses the zh frame (%s)" % label.text)
	I18n.set_locale("en")
	screen.queue_free()
	await get_tree().process_frame


# --- Helpers -------------------------------------------------------------

func _ui_zh(key: String) -> String:
	return str((DataLoader.ui_strings.get(key, {}) as Dictionary).get("zh", ""))


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
