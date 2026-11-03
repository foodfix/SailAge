extends Node
## Phase-9 W3-D — the Phase-2 acceptance walk, re-pinned onto the velocity
## engine (docs/IMPLEMENT-Phase2.md H; docs/60-COMBAT.md §4.2, §4.3a, §4.4,
## §4.4a, §4.5, §4.6a, §4.8, §4.10, §4.11.2, §4.11.7, §4.11.9, §4.11.10,
## §4.12.2, §4.12.3; docs/90-ARCHITECTURE.md §8.1, §8.2).
##
##   godot --headless --path . tools/test_phase2_acceptance.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What makes this an acceptance test rather than another unit suite.** Every
## scenario starts from a real **save file on disk** (the current
## `save_version`, written by a plain JSON dump exactly as `SaveSystem.save()`
## would), loads it through `SaveSystem.load()`, then drives the *shipped*
## battle path: the §4.11.1-seeded `BattleSim` over the loaded fleet, the
## three-phase §4.3/§4.3a turns (pick a legal velocity → the Bresenham sweep →
## at most one action) through this suite's own policy callables, and the
## §4.12.2 → §4.12.3 aftermath through the guarded `BattleRewards` /
## `BattleResult` seams.
##
## W3 seam note: the Phase-2 suite drove `world_map.gd` + `battle_screen.tscn`
## for the contact walk and the fight. Those screens are W3-B/C's in-flight
## rewrites (`scripts/combat/ai_fleet.gd` and `scenes/combat/battle_screen.gd`
## still reference the retired MP API on this branch), so the movement /
## interaction steps are re-expressed here directly on the velocity API —
## deployment (§4.11.2), cannon via arcs + per-side reload, the sweep ram,
## the §4.6a hook + board, retreat and surrender — while every economy /
## outcome pin is preserved. The world-ecology pins (marker removal, the
## pursuit cooldown, the contact walk) stay with the ecology suite; the S10
## render flow is re-covered by slot C's `tools/test_battle_screen.gd`.
##
## Scenarios:
##   S1  win by cannons          → victory, salvage, XP, pirate rep, contact
##                                 block; the player never boards or rams
##   S1b  a sweep-ram kill       → the §4.5 ram resolves through the sweep
##   S2  win by boarding+capture → the §4.6a hook zeroes both velocities; the
##                                 captured hull joins at 25% durability with
##                                 crew 0 and cargo intact; morale_delta +10 (§4.8a)
##   S2b a second capture on a full fleet → looted + scuttled, overflow named
##   S3  retreat                 → result `retreat`, no XP/gold/rep, fleet kept
##   S3b player surrender        → §4.11.7: the pirates take the hold only
##   S4  lose a duel as the last ship → defeat_captured; S9 renders
##                                 `gameover.captured` in both locales
##
## Every scenario also asserts the save → load → battle → save round trip
## (`save_version == SaveSystem.SAVE_VERSION` on disk, reload succeeds).

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const BattleRewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const BattleResultLib := preload("res://scripts/combat/battle_result.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")

## Open-water fixture tile, 8 tiles from Lisbon (open water on the Phase-6
## grid). The battle's §4.11.1 contact and the §4.11.10 rep anchor.
const CONTACT := Vector2i(2042, 615)

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	await _scenario_cannon_victory()
	await _scenario_sweep_ram()
	await _scenario_boarding_capture()
	await _scenario_full_fleet_capture()
	await _scenario_retreat()
	await _scenario_surrender()
	await _scenario_last_ship_captured()
	_cleanup_saves()
	_report()


# ===========================================================================
# S1 — start from a save, meet a pirate, win by cannons
# ===========================================================================

func _scenario_cannon_victory() -> void:
	print("\n=== S1: win by cannons (save → §4.11.2 deployment → victory) ===")
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30,
		"provisions": 40, "water": 40}),
		_ship("brigantine", {"cannons": 10, "crew": 30})]
	var save_gold := 5000
	var save_day := 3
	_check(_start_from_save("S1", fleet, save_day, save_gold, 12),
		"S1: the save loads")

	# The enemy holds at rest — a static §4.11.3-style target pair.
	var enemy_ships: Array = [
		_ship("sloop", {"cannons": 4}), _ship("sloop", {"cannons": 4}),
	]
	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": enemy_ships,
		"enemy_kind": "pirate", "enemy_nation": "",
		"day": GameState.day, "gold": GameState.gold,
		"contact": CONTACT, "weather": "fair", "wind_dir": "E",
		"current": {"dir": "", "strength": 0},
	})
	sim.start()
	var p0 := _unit(sim, "player", 0)
	var p1 := _unit(sim, "player", 1)
	var e0 := _unit(sim, "enemy", 0)
	_check(sim.unit_cell(p0) == Vector2i(10, 15) and sim.unit_cell(p1) == Vector2i(10, 14),
		"S1: §4.11.2 deployment — the player column sits on (10,15)/(10,14) (%s/%s)"
			% [str(sim.unit_cell(p0)), str(sim.unit_cell(p1))])
	_check(sim.unit_cell(e0) == Vector2i(37, 15),
		"S1: §4.11.2 deployment — the enemy flagship sits on (37,15) (%s)"
			% str(sim.unit_cell(e0)))
	_check((p0["vel"] as Vector2i) == Vector2i(1, 0)
			and int(p0["heading8"]) == BattleSimLib.HEADING_EAST
			and int(e0["heading8"]) == BattleSimLib.HEADING_WEST,
		"S1: §4.11.2 correction 15 — the closing start (1,0) with headings east/west at the start")
	# §4.11.1 over the engine's own pre-battle values.
	_check(sim.seed_value() == BattleSimLib.battle_seed_formula(
			int(sim.day), sim.contact, int(sim.gold),
			sim.living_units(BattleSimLib.SIDE_PLAYER).size()),
		"S1: the seed is the §4.11.1 formula over day/contact/gold/fleet (%d)"
			% sim.seed_value())
	# Fixture arrangement: the §4.11.2 correction-15 bands open 27 cells
	# apart; the target pair is moved to mid-board so the scenario stays
	# deterministic and inside the 40-round cap (the same explicit-
	# arrangement rule as the other suites; the closing start only shortens
	# the approach).
	_place(sim, "enemy", 0, Vector2i(25, 15))
	_place(sim, "enemy", 1, Vector2i(25, 14))

	var baseline := _reputation_snapshot()
	var gold_before := GameState.gold
	var xp_before := CharacterLib.current_xp()
	var guard := _drive(sim, "cannon_only")
	var outcome: Dictionary = sim.outcome()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S1: the cannon-only fight ends in `victory` (%s, %d driver steps)"
		% [str(outcome.get("result")), guard])
	_check(_engine_actions_of(sim, ["board", "ram"], "player") == 0,
		"S1: the player never boarded or rammed — cannons only")
	var sunk := _as_array(outcome.get("sunk_enemy", []))
	var captured := _as_array(outcome.get("captured_enemy", []))
	_check(sunk.size() == 2 and captured.is_empty(),
		"S1: both enemy hulls were sunk by cannon fire (%s)" % str(sunk))
	_check(_engine_actions_of(sim, ["cannon"], "player") >= 2,
		"S1: the engine log carries the player's cannon volleys")

	# §4.11.10: salvage = Σ floor(base_price × 0.05) over the SUNK hulls.
	var expected_salvage: int = BattleRewardsLib.salvage_for(sunk)
	var expected_neutralised: int = sunk.size() + captured.size()
	var expected_xp: int = BattleRewardsLib.xp_for(expected_neutralised,
		int(outcome.get("rounds", 0)))
	_check(int(outcome.get("salvage_gold", -1)) == expected_salvage,
		"S1: salvage gold = Σ floor(base_price × 0.05) of the sunk hulls (%d, expected %d)"
		% [int(outcome.get("salvage_gold", -1)), expected_salvage])
	_check(int(outcome.get("xp", -1)) == expected_xp,
		"S1: XP = 10 × %d neutralised + 5 × %d rounds = %d (got %d)"
		% [expected_neutralised, int(outcome.get("rounds", 0)), expected_xp,
			int(outcome.get("xp", -1))])
	# §4.11.10 rep: +2 with each of the two nearest ports' nations.
	var expected_nations: Array = BattleRewardsLib.nearest_nations(CONTACT)
	_check(not expected_nations.is_empty(),
		"S1: the contact tile has two nearest ports (%s)" % str(expected_nations))
	_check(_as_dict(outcome.get("rep_deltas", {})) == _expected_rep_block(expected_nations),
		"S1: the outcome's rep_deltas is exactly %s (%s)"
		% [str(_expected_rep_block(expected_nations)),
			str(outcome.get("rep_deltas", {}))])
	_check(_as_dict(outcome.get("contact", {})) == {"x": CONTACT.x, "y": CONTACT.y},
		"S1: the outcome block reports the contact tile (%s)"
		% str(outcome.get("contact", {})))

	# The §4.12.3 aftermath, applied once. The level multiplier reads the
	# level held BEFORE the award (§4.11.10), so the expectation is computed
	# before apply() can level the player up.
	var credited_xp := BattleRewardsLib.battle_xp_for(expected_xp)
	var applied := BattleRewardsLib.apply(outcome)
	_check(GameState.gold == gold_before + expected_salvage,
		"S1: the salvage landed in the purse exactly once (%d → %d)"
		% [gold_before, GameState.gold])
	_check(CharacterLib.current_xp() == xp_before + credited_xp,
		"S1: the XP reached player.xp through the level multiplier "
			+ "(%d → %d, credited %d)" % [xp_before, CharacterLib.current_xp(),
			credited_xp])
	var rep_ok := true
	for nation_id in expected_nations:
		if CharacterLib.reputation(str(nation_id)) \
				!= int(baseline.get(nation_id, 0)) + BattleRewardsLib.PIRATE_REP_GAIN:
			rep_ok = false
	_check(rep_ok, "S1: pirate rep is +2 with %s" % str(expected_nations))
	var untouched := true
	for nation_id in baseline:
		if str(nation_id) in expected_nations:
			continue
		if CharacterLib.reputation(str(nation_id)) != int(baseline[nation_id]):
			untouched = false
	_check(untouched, "S1: no other nation's reputation moved")
	var replay := BattleRewardsLib.apply(outcome)
	_check(int(replay["gold"]) == 0 and int(replay["xp"]) == 0,
		"S1: the applied block cannot double-apply (%s)" % str(replay))
	await _assert_round_trip("S1")


# ===========================================================================
# S1b — the §4.5 sweep ram as the killing blow
# ===========================================================================

func _scenario_sweep_ram() -> void:
	print("\n=== S1b: a sweep-ram kill (§4.3a sweep → §4.5 ram) ===")
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30})]
	_check(_start_from_save("S1b", fleet, 3, 5000, 12), "S1b: the save loads")
	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": [_ship("sloop", {"cannons": 0, "durability": 25})],
		"enemy_kind": "pirate", "day": GameState.day, "gold": GameState.gold,
		"contact": CONTACT, "weather": "calm",
		"current": {"dir": "", "strength": 0},
	})
	sim.start()
	_place(sim, "player", 0, Vector2i(20, 15))
	_place(sim, "enemy", 0, Vector2i(23, 15))
	_face(sim, "player", 0, BattleSimLib.HEADING_EAST)
	var guard := _drive(sim, "ram")
	var outcome: Dictionary = sim.outcome()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S1b: the ram fight ends in `victory` (%s, %d steps)"
		% [str(outcome.get("result")), guard])
	_check(_engine_actions_of(sim, ["ram"], "player") >= 1,
		"S1b: the sweep resolved a player-side §4.5 ram")
	_check(_as_array(outcome.get("sunk_enemy", [])) == ["sloop"],
		"S1b: the ram sank the enemy hull (%s)" % str(outcome.get("sunk_enemy")))
	await _assert_round_trip("S1b")


# ===========================================================================
# S2 — win by boarding + capture, then the full-fleet loot & scuttle
# ===========================================================================

func _scenario_boarding_capture() -> void:
	print("\n=== S2: win by boarding + capture (the §4.6a hook) ===")
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30,
		"provisions": 40, "water": 40})]
	# A single pirate sloop: crew 10 → defender base min(floor(10/5),20) + 6
	# = 8 (§4.11.6). The fixture gold/day is whichever makes this fixture's
	# §4.11.1 duel stream a player win (base 12 vs 8).
	var enemy := _ship("sloop", {"crew": 10, "cannons": 0, "cargo": {"wine": 6}})
	var save_gold := 5000
	var save_day: int = _duel_day("capture", save_gold, 1, 12,
		BattleSimLib.defender_duel_base(10, BattleSimLib.CAPTAIN_RATING_BASE + 1))
	_check(save_day > 0,
		"S2: a fixture day whose §4.11.1 duel stream is a player win exists (%d)"
			% save_day)
	_check(_start_from_save("S2", fleet, save_day, save_gold, 12),
		"S2: the save loads")
	# Phase 8 capture gate (`60-*` §4.11.7): the captured hull needs ≥ 1 idle
	# officer — seat one (no state entry reads as idle, `post_id ""` default).
	GameState.player["officers"] = ["fx_p2_idle"]
	var battle_seed: int = BattleSimLib.battle_seed_formula(save_day, CONTACT,
		save_gold, 1)
	var predicted := _predicted_duel(battle_seed, 12,
		BattleSimLib.defender_duel_base(10, BattleSimLib.CAPTAIN_RATING_BASE + 1))
	_check(str(predicted.get("result", "")) == "capture",
		"S2: the seeded duel for this fixture is a player win (%s, %s)"
		% [str(predicted.get("result")), str(predicted.get("rounds"))])

	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": [enemy],
		"enemy_kind": "pirate", "day": save_day, "gold": save_gold,
		"contact": CONTACT, "weather": "calm",
		"current": {"dir": "", "strength": 0}, "seed": battle_seed,
	})
	sim.start()
	# Fixture arrangement: the correction-15 closing start accelerates the
	# boarding approach past the old 27-cell cruise — at full speed the
	# brake-pick's (y,x)-first scan grabs a diagonal fling past a far target
	# and deadlocks the 45°-turn ship. The single sloop is placed at
	# (13,15) so the soft-close search lands manhattan 1 at mag 2 on round 1
	# and the brake ladder resolves straight down (2 → 0 → board at round 3,
	# no sweep-ram, no overshoot) — deterministic and well inside the cap.
	_place(sim, "enemy", 0, Vector2i(13, 15))
	var fleet_before: int = GameState.fleet.size()
	var guard := _drive(sim, "board")
	var outcome: Dictionary = sim.outcome()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S2: the boarding fight ends in `victory` (%s, %d steps)"
		% [str(outcome.get("result")), guard])
	_check(_engine_actions_of(sim, ["board"], "player") == 1,
		"S2: the §4.6a hook + boarding duel really resolved (§4.6)")
	var captured := _as_array(outcome.get("captured_enemy", []))
	_check(captured.size() == 1,
		"S2: the boarded hull is captured (%d captured)" % captured.size())
	_check(_as_array(outcome.get("sunk_enemy", [])).is_empty(),
		"S2: nothing was sunk — the win came from the duel, not gunfire")
	# §4.8a (W4 re-pin): the boarding +5 flat is retired — a won boarding
	# books the BOARDING WIN +10 event, so a bare boarding win (nothing else
	# happening to the player side) yields `morale_delta == +10`; the
	# `morale_bonus` outcome key is gone.
	_check(int(outcome.get("morale_bonus", -1)) == -1
			and int(outcome.get("morale_delta", -1)) == 10,
		"S2: §4.8a — the won boarding books morale_delta +10 (the §4.8 flat "
			+ "+5 is retired) (delta %d)" % int(outcome.get("morale_delta", -1)))
	_check(int(outcome.get("xp", -1)) == BattleRewardsLib.xp_for(
			captured.size(), int(outcome.get("rounds", 0))),
		"S2: XP = 10 × %d captured + 5 × %d rounds = %d (got %d)"
		% [captured.size(), int(outcome.get("rounds", 0)),
			BattleRewardsLib.xp_for(captured.size(), int(outcome.get("rounds", 0))),
			int(outcome.get("xp", -1))])

	# The §4.11.7 application: the prize joins at 25% durability, crew 0,
	# cargo intact — through the guarded BattleResult seam.
	var applied := BattleResultLib.apply(outcome, [], GameState.fleet)
	_check(GameState.fleet.size() == fleet_before + 1,
		"S2: the captured hull joined the fleet (%d → %d)"
		% [fleet_before, GameState.fleet.size()])
	_check(GameState.fleet.size() <= FleetLib.FLEET_MAX,
		"S2: the fleet respects FLEET_MAX = %d (%d)"
		% [FleetLib.FLEET_MAX, GameState.fleet.size()])
	if captured.size() == 1:
		var hull: Dictionary = captured[0]
		var expected_durability := maxi(1, int(floor(
			float(hull.get("durability", 0)) * 0.25)))
		var joined: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
		_check(str(joined.get("ship_type_id", "")) == str(hull.get("ship_type_id", "")),
			"S2: the appended hull is the captured %s (%s)"
			% [str(hull.get("ship_type_id", "")), str(joined.get("ship_type_id", ""))])
		_check(int(joined.get("durability", -1)) == expected_durability,
			"S2: it joins at max(1, floor(current × 0.25)) = %d (got %d)"
			% [expected_durability, int(joined.get("durability", -1))])
		_check(int(joined.get("crew", -1)) == 0,
			"S2: …with crew 0 (got %d)" % int(joined.get("crew", -1)))
		_check(int(joined.get("cannons", -1)) == int(hull.get("cannons", -2))
				and _as_dict(joined.get("equipment", {})) == _as_dict(hull.get("equipment", {})),
			"S2: …cannons and equipment intact")
	_check(FleetLib.held("wine") == 6,
		"S2: the captured cargo is intact in the pooled hold (%d wine)"
		% FleetLib.held("wine"))
	await _assert_round_trip("S2")


## §4.11.7 "With a full fleet the ship is looted … and scuttled" plus §6
## "capture with full fleet and full cargo — loot-to-capacity then scuttle;
## overflow cargo reported lost".
func _scenario_full_fleet_capture() -> void:
	print("\n=== S2b: a second capture with a full fleet → loot + scuttle ===")
	var fleet: Array = []
	for _index in FleetLib.FLEET_MAX:
		# Capacity 120, hold exactly full → nothing can be looted.
		fleet.append(_ship("caravel", {"cannons": 0, "crew": 15,
			"cargo": {"wine": 120}}))
	var defender_base: int = BattleSimLib.defender_duel_base(
		10, BattleSimLib.CAPTAIN_RATING_BASE + 1)
	var save_gold := 5000
	var save_day: int = _duel_day("capture", save_gold, FleetLib.FLEET_MAX, 12,
		defender_base)
	_check(save_day > 0,
		"S2b: a full-fleet day whose §4.11.1 duel stream is a player win exists (%d)"
			% save_day)
	_check(_start_from_save("S2b", fleet, save_day, save_gold, 12),
		"S2b: a 5-ship save loads")
	# Seat an idle officer so the gate that fires here is `fleet_full` (the
	# scenario's subject), not `no_idle_officer`.
	GameState.player["officers"] = ["fx_p2_idle"]
	var battle_seed: int = BattleSimLib.battle_seed_formula(save_day, CONTACT,
		save_gold, FleetLib.FLEET_MAX)
	_check(str(_predicted_duel(battle_seed, 12, defender_base).get("result", ""))
			== "capture",
		"S2b: the seeded duel is a player win with a full fleet too")
	var gold_before := GameState.gold
	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": [_ship("sloop", {"crew": 10, "cannons": 0, "cargo": {"wine": 6}})],
		"enemy_kind": "pirate", "day": save_day, "gold": save_gold,
		"contact": CONTACT, "weather": "calm",
		"current": {"dir": "", "strength": 0}, "seed": battle_seed,
	})
	sim.start()
	var guard := _drive(sim, "board")
	var outcome: Dictionary = sim.outcome()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S2b: the fight is a victory (%s, %d steps)" % [str(outcome.get("result")), guard])
	BattleResultLib.apply(outcome, [], GameState.fleet)
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"S2b: the fleet stays at FLEET_MAX — nothing joined (%d)"
		% GameState.fleet.size())
	_check(_as_array(outcome.get("captured_enemy", [])).size() == 1,
		"S2b: the sloop was captured by the duel")
	_check((applied_report(outcome) as Array) == ["sloop"],
		"S2b: the captured sloop was looted and scuttled (%s)"
		% str(applied_report(outcome)))
	_check(int(outcome.get("salvage_gold", -1)) == 0
			and GameState.gold == gold_before,
		"S2b: a captured (not sunk) hull pays no salvage (%d → %d)"
		% [gold_before, GameState.gold])
	_check(FleetLib.held("wine") == 120 * FleetLib.FLEET_MAX,
		"S2b: the full holds gained nothing (%d wine; §4.11.7 loot-to-capacity)"
		% FleetLib.held("wine"))
	await _assert_round_trip("S2b")


## BattleResult's scuttle report for this outcome (the §4.11.7 loot-convert
## fallback list), read off a throwaway application.
func applied_report(outcome: Dictionary) -> Array:
	return _as_array(BattleResultLib.apply(outcome, [], GameState.fleet.duplicate(true))
		.get("scuttled_ships", []))


# ===========================================================================
# S3 — retreat, S3b — player surrender
# ===========================================================================

func _scenario_retreat() -> void:
	print("\n=== S3: retreat (§4.10) ===")
	var fleet: Array = [_ship("caravel", {"cannons": 4, "crew": 15,
		"provisions": 20, "water": 20})]
	_check(_start_from_save("S3", fleet, 3, 5000, 10), "S3: the save loads")
	var gold_before := GameState.gold
	var xp_before := CharacterLib.current_xp()
	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": [_ship("sloop", {"cannons": 4})],
		"enemy_kind": "pirate", "day": GameState.day, "gold": GameState.gold,
		"contact": CONTACT, "weather": "calm",
		"current": {"dir": "", "strength": 0},
	})
	sim.start()
	var outcome := sim.retreat()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_RETREAT,
		"S3: the retreat ends the battle with `retreat` (%s)"
		% str(outcome.get("result")))
	_check(int(outcome.get("xp", -1)) == 0
			and CharacterLib.current_xp() == xp_before,
		"S3: a retreat awards no XP (§4.10): outcome %d, player %d"
		% [int(outcome.get("xp", -1)), CharacterLib.current_xp()])
	_check(int(outcome.get("salvage_gold", -1)) == 0
			and GameState.gold == gold_before,
		"S3: a retreat pays no salvage gold (%d, purse %d)"
		% [int(outcome.get("salvage_gold", -1)), GameState.gold])
	_check(_as_dict(outcome.get("rep_deltas", {})).is_empty(),
		"S3: a retreat books no pirate reputation (§4.11.10 'except retreat')")
	_check(_as_array(outcome.get("lost_player", [])).is_empty(),
		"S3: the fleet is retained (nothing lost to a retreat)")
	_check(not BattleRewardsLib.apply(outcome).is_empty(),
		"S3: the §4.12.3 seam still accepts the retreat block")
	await _assert_round_trip("S3")


func _scenario_surrender() -> void:
	print("\n=== S3b: player surrender to pirates (§4.11.7) ===")
	var fleet: Array = [_ship("caravel", {"cannons": 4, "crew": 15})]
	_check(_start_from_save("S3b", fleet, 3, 5000, 10), "S3b: the save loads")
	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": [_ship("sloop", {"cannons": 4})],
		"enemy_kind": "pirate", "day": GameState.day, "gold": GameState.gold,
		"contact": CONTACT, "weather": "calm",
		"current": {"dir": "", "strength": 0},
	})
	sim.start()
	var outcome := sim.offer_surrender()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_SURRENDER,
		"S3b: the player surrender ends the battle with `surrender` (%s)"
		% str(outcome.get("result")))
	_check(_as_array(outcome.get("lost_player", [])).is_empty(),
		"S3b: the pirates take the hold, not the hulls (§4.11.7) (%s)"
			% str(outcome.get("lost_player")))
	_check(GameState.fleet.size() == 1,
		"S3b: every ship is retained (%d)" % GameState.fleet.size())
	await _assert_round_trip("S3b")


# ===========================================================================
# S4 — lose a duel as the last ship → defeat_captured + gameover.captured
# ===========================================================================

func _scenario_last_ship_captured() -> void:
	print("\n=== S4: lose a duel as the last ship → gameover.captured ===")
	# One weak ship (swordplay 1) against a galleon crew 120 → defender base
	# min(floor(120/5), 20) + 6 = 26, so the §4.11.6 duel cannot be won and
	# the hull is the whole fleet. The day is whichever makes the loss certain.
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30,
		"provisions": 20, "water": 20})]
	var enemy := _ship("galleon", {"crew": 120, "cannons": 0, "cargo": {}})
	var defender_base: int = BattleSimLib.defender_duel_base(
		120, BattleSimLib.CAPTAIN_RATING_BASE + 1)
	var save_gold := 5000
	var save_day: int = _duel_day("defeat", save_gold, 1, 1, defender_base)
	_check(save_day > 0,
		"S4: a fixture day whose §4.11.1 duel stream is a player loss exists (%d)"
			% save_day)
	_check(_start_from_save("S4", fleet, save_day, save_gold, 1),
		"S4: the save loads")
	var battle_seed: int = BattleSimLib.battle_seed_formula(save_day, CONTACT,
		save_gold, 1)
	_check(str(_predicted_duel(battle_seed, 1, defender_base).get("result", ""))
			== "defeat",
		"S4: the seeded duel for this fixture is a player loss (%s, %s)"
		% [str(_predicted_duel(battle_seed, 1, defender_base).get("result", "")),
		str(_predicted_duel(battle_seed, 1, defender_base).get("rounds"))])
	var sim := BattleSimLib.new({
		"player_ships": GameState.fleet,
		"enemy_ships": [enemy],
		"enemy_kind": "pirate", "day": save_day, "gold": save_gold,
		"contact": CONTACT, "weather": "calm",
		"current": {"dir": "", "strength": 0}, "seed": battle_seed,
	})
	sim.start()
	# The same S2 arrangement repair: the galleon at (13,15) keeps the
	# boarding approach inside the soft-close window (manhattan 1 at mag 2,
	# brake straight to 0, no sweep-ram) so the seeded loss duel resolves.
	_place(sim, "enemy", 0, Vector2i(13, 15))
	var guard := _drive(sim, "board")
	var outcome: Dictionary = sim.outcome()
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_DEFEAT_CAPTURED,
		"S4: losing the last ship's duel yields `defeat_captured` (%s, %d steps)"
		% [str(outcome.get("result")), guard])
	_check(_engine_actions_of(sim, ["board"], "player") == 1,
		"S4: the loss came from a boarding duel (§4.6)")
	_check(_as_array(outcome.get("lost_player", [])).size() == 1,
		"S4: the boarded flagship is the one that was taken (%d)"
		% _as_array(outcome.get("lost_player", [])).size())
	# The §4.12.3 application empties the fleet.
	BattleResultLib.apply(outcome, [], GameState.fleet)
	_check(GameState.fleet.is_empty(),
		"S4: the fleet ends empty (%d ships)" % GameState.fleet.size())

	# §4.12.4 step 5: S9 owns the captured screen and names the reason in
	# both locales (the screen is ui_shared — no W3 seam).
	var scene = GameOverScene.instantiate()
	scene.route_to_title = false
	add_child(scene)
	await get_tree().process_frame
	scene.open_reason("captured")
	await get_tree().process_frame
	var rendered := {}
	var locale_before: String = GameState.locale
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		rendered[locale] = scene.reason_text()
	I18n.set_locale(locale_before)
	await get_tree().process_frame
	_check(str(rendered.get("en", "")).contains(_ui("gameover.captured", "en"))
			and not _has_raw_key([rendered.get("en", "")]),
		"S4: en renders gameover.captured (%s)" % str(rendered.get("en", "")))
	_check(str(rendered.get("zh", "")).contains(_ui("gameover.captured", "zh"))
			and not _has_raw_key([rendered.get("zh", "")]),
		"S4: zh renders gameover.captured (%s)" % str(rendered.get("zh", "")))
	_check(str(rendered.get("en", "")) != str(rendered.get("zh", "")),
		"S4: the game-over text really switches language")
	scene.queue_free()
	await get_tree().process_frame
	await _assert_round_trip("S4")


# ===========================================================================
# Driving the velocity API
# ===========================================================================

## Drives the battle through the three-phase §4.3 turn with the named
## player policy; the enemy side always holds. Returns the step guard.
func _drive(sim, mode: String) -> int:
	var guard := 0
	while not sim.is_over() and guard < 600:
		guard += 1
		var unit: Dictionary = sim.current_unit()
		if unit.is_empty():
			sim.end_turn()
			continue
		var decision: Dictionary
		if str(unit["side"]) == "enemy":
			decision = {"action": "hold"}
		else:
			decision = _player_decision(sim, unit, mode)
		sim._apply_decision(unit, decision)
		if not sim.is_over():
			sim.end_turn()
	return guard


## The player decision by scenario mode, over the §4.12.1.1 dict shape.
## All closing geometry runs on MANHATTAN distance — the §4.6a hook and the
## §4.5 ram need orthogonal adjacency, which a Chebyshev-close can wedge
## into a permanent diagonal.
func _player_decision(sim, unit: Dictionary, mode: String) -> Dictionary:
	var enemies: Array = sim.living_units("enemy")
	if enemies.is_empty():
		return {"action": "hold"}
	var from: Vector2i = sim.unit_cell(unit)
	var nearest: Dictionary = enemies[0]
	var best := _manhattan(from, sim.unit_cell(enemies[0]))
	for enemy in enemies:
		var distance := _manhattan(from, sim.unit_cell(enemy))
		if distance < best:
			best = distance
			nearest = enemy
	var target_cell: Vector2i = sim.unit_cell(nearest)
	var cheb := _chebyshev(from, target_cell)

	if mode == "board":
		# The §4.6a hook needs orthogonal adjacency with BOTH ships at
		# ⌊vel⌋ ≤ 1 — the FLOOR, so a (1,1) approach (mag √2) is already in
		# the window. The decision's vel (0,0) may be refused by the accel
		# budget; the hook itself then zeroes both velocities (§4.6a).
		var mag := BattleSimLib.vel_length(unit["vel"])
		var manhattan := _manhattan(from, target_cell)
		if manhattan == 1 and int(floor(mag)) <= 1:
			return {"action": "board", "target": nearest, "vel": Vector2i.ZERO}
		if manhattan <= int(floor(mag)) + 1 and mag > 1.0:
			# The current speed would sweep past (or into) the target this
			# turn — brake now, one accel-step per turn (§4.3a), never
			# through the target's cell (that would be a §4.5 ram).
			return {"action": "move", "vel": _decelerate_pick(sim, unit, target_cell)}
		# Otherwise steer toward an orthogonal landing (a manhattan-1 landing
		# at ⌊vel⌊ ≤ 1 preferred, so the next turn can board).
		var soft := Vector2i.ZERO
		var soft_found := false
		var rough := Vector2i.ZERO
		var rough_found := false
		var rough_best := best
		for candidate in sim.legal_velocities(unit):
			var step: Vector2i = candidate
			if _walk_hits(sim, unit, step, target_cell):
				continue
			var landing := _landing(sim, unit, step)
			var landing_manhattan := _manhattan(landing, target_cell)
			if landing_manhattan == 1 and BattleSimLib.vel_length(step) <= 2.0:
				return {"action": "move", "vel": step}
			if landing_manhattan == 1 and not rough_found:
				rough = step
				rough_found = true
			if landing != from and landing_manhattan < rough_best:
				rough_best = landing_manhattan
				soft = step
				soft_found = true
		if rough_found:
			return {"action": "move", "vel": rough}
		if soft_found:
			return {"action": "move", "vel": soft}
		return {"action": "hold"}

	if mode == "ram":
		# Adjacent → drive the sweep INTO the enemy cell (the §4.5 sweep ram;
		# the impact speed is the applied velocity, so any speed helps).
		if _manhattan(from, target_cell) == 1:
			var delta: Vector2i = target_cell - from
			if sim.legal_velocities(unit).has(delta):
				return {"action": "move", "vel": delta}
			return {"action": "move", "vel": _decelerate_pick(sim, unit, Vector2i(-9, -9))}
		var ram_pick := Vector2i.ZERO
		var ram_found := false
		var ram_best := best
		for vel in sim.legal_velocities(unit):
			var landing := _landing(sim, unit, vel)
			var distance := _manhattan(landing, target_cell)
			if landing != from and distance < ram_best:
				ram_best = distance
				ram_pick = vel
				ram_found = true
		if ram_found:
			return {"action": "move", "vel": ram_pick}
		return {"action": "hold"}

	# cannon_only: fire a loaded side in range+arc; inside cannon range turn
	# to broadside when no arc bears; outside it close on the sweep landing
	# (manhattan geometry), never entering an occupied cell (no ram, §4.5).
	for side in ["port", "starboard"]:
		for target in enemies:
			if sim.can_cannon(unit, target, str(side)):
				return {"action": "cannon", "target": target,
					"side": str(side), "shot": "round"}
	if cheb <= BattleSimLib.CANNON_RANGE_MAX:
		# Broadside-on orbit: a velocity pick both MOVES the ship and turns
		# it (the heading is the committed velocity's, §4.3a), so the arc
		# check must read the AFTER-move geometry — landing cell and new
		# heading together — and stay inside cannon range while orbiting.
		var drift := Vector2i.ZERO
		var drift_found := false
		var drift_mag := 1e9
		for vel in sim.legal_velocities(unit):
			var step: Vector2i = vel
			if step == Vector2i.ZERO:
				continue
			var landing := _landing(sim, unit, step)
			if landing == from:
				continue
			var landing_cheb := _chebyshev(landing, target_cell)
			if landing_cheb > BattleSimLib.CANNON_RANGE_MAX:
				continue
			var new_bearing := int(BattleSimLib.heading8_of(target_cell - landing))
			var new_heading := int(BattleSimLib.heading8_of(step))
			# §4.4 arcs are SIGNED counterclockwise steps (the engine's
			# W3 bounce-back resolution) — the unsigned bucket_distance can
			# never reach the starboard set and mislabels port bearings.
			var steps := (new_bearing - new_heading + 8) % 8
			if steps in BattleSimLib.ARC_PORT_STEPS \
					or steps in BattleSimLib.ARC_STARBOARD_STEPS:
				return {"action": "move", "vel": step}
			var mag := BattleSimLib.vel_length(step)
			if mag < drift_mag:
				drift_mag = mag
				drift = step
				drift_found = true
		if drift_found:
			# No arc this turn: bleed speed (a slower velocity turns wider
			# next round) while staying in range.
			return {"action": "move", "vel": drift}
		return {"action": "hold"}
	var close_pick := Vector2i.ZERO
	var close_found := false
	var close_best := best
	for vel in sim.legal_velocities(unit):
		var landing := _landing(sim, unit, vel)
		var distance := _manhattan(landing, target_cell)
		if landing != from and distance < close_best:
			close_best = distance
			close_pick = vel
			close_found = true
	if close_found:
		return {"action": "move", "vel": close_pick}
	# Come-about (W3 bounce-back): under inertia a ship that overshot the
	# target has NO Manhattan-improving pick for several rounds (the MP
	# engine's cell reachability never had this hole) — turn toward the
	# target instead: the first legal velocity whose resulting heading is
	# nearest the target bearing (unsigned bucket steps, ties = enumeration
	# order), never increasing the Manhattan distance.
	var bearing := int(BattleSimLib.heading8_of(target_cell - from))
	var turn_pick := Vector2i.ZERO
	var turn_best := 9
	for vel in sim.legal_velocities(unit):
		var step: Vector2i = vel
		if step == Vector2i.ZERO:
			continue
		var landing := _landing(sim, unit, step)
		if landing == from or _manhattan(landing, target_cell) > best:
			continue
		var new_heading := int(BattleSimLib.heading8_of(step))
		var steps := mini(int(BattleSimLib.bucket_distance(new_heading, bearing)), 4)
		if steps < turn_best:
			turn_best = steps
			turn_pick = step
	if turn_pick != Vector2i.ZERO:
		return {"action": "move", "vel": turn_pick}
	return {"action": "hold"}


## The legal velocity with the smallest magnitude (the deceleration pick —
## the §4.3a accel budget allows one magnitude-step per turn, so a fast
## arrival brakes over several turns before the hook reads ⌊vel⌋ ≤ 1).
func _decelerate_pick(sim, unit: Dictionary, avoid_cell: Vector2i) -> Vector2i:
	var current: Vector2i = unit["vel"]
	var best_pick := Vector2i.ZERO
	var best_mag := BattleSimLib.vel_length(current)
	for candidate in sim.legal_velocities(unit):
		var step: Vector2i = candidate
		var mag := BattleSimLib.vel_length(step)
		if mag >= best_mag:
			continue
		if _walk_hits(sim, unit, step, avoid_cell):
			continue
		best_mag = mag
		best_pick = step
	return best_pick


## True when the §4.3a sweep walk for `step` touches `cell` (e.g. the target
## of a boarding approach — entering it would ram instead of hook).
func _walk_hits(sim, unit: Dictionary, step: Vector2i, cell: Vector2i) -> bool:
	if cell.x < 0:
		return false
	var from: Vector2i = sim.unit_cell(unit)
	for walked in BattleSimLib._bresenham_cells(from, from + step):
		if walked == cell:
			return true
	return false


## Player-side engine-log actions of the given kinds (§4.11.4 entries carry
## `values.side`).
func _engine_actions_of(sim, kinds: Array, side: String) -> int:
	var count := 0
	for entry in sim.log_lines():
		if not (entry is Dictionary):
			continue
		if not (str(entry.get("kind", "")) in kinds):
			continue
		var values = entry.get("values", {})
		if values is Dictionary and str(values.get("side", "")) == side:
			count += 1
	return count


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


# ===========================================================================
# The §4.11.1 fixture-day search (doc-derived fixture selection)
# ===========================================================================

## The pre-battle day whose §4.11.1 duel stream resolves the way `wanted`
## asks (`"capture"` for the boarding wins, `"defeat"` for the last-ship
## loss) — the same documented, deterministic search the Phase-2 suite used.
## It changes no pinned number and makes each duel scenario a guaranteed
## branch instead of a lucky one (§6 "duel RNG audit").
func _duel_day(wanted: String, gold: int, fleet_size: int,
		player_base: int, defender_base: int) -> int:
	for day in range(1, 200):
		var seed_value := BattleSimLib.battle_seed_formula(day, CONTACT, gold,
			fleet_size)
		if str(_predicted_duel(seed_value, player_base, defender_base)
				.get("result", "")) == wanted:
			return day
	return -1


## The §4.11.6 duel a battle with this §4.11.1 seed resolves (§4.11.1: "duel
## rolls draw from the same stream" — deployment and composition consume
## nothing before the first boarding).
func _predicted_duel(seed_value: int, player_base: int,
		defender_base: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return BattleSimLib.resolve_duel(player_base, defender_base, rng)


# ===========================================================================
# Save fixture (docs/90-* §8.1) + load path (docs/90-* §8.2)
# ===========================================================================

## A complete current-version payload (every §8.1 key) at sea. Written to
## `user://saves/save_1.json` and loaded through `SaveSystem.load(1)` — the
## shipped path, with no migration involved (docs/90-* §8.2).
func _current_payload(fleet: Array, day: int, gold: int, swordplay: int) -> Dictionary:
	return {
		"save_version": SaveSystem.SAVE_VERSION,
		"saved_at": 1793119712,
		"phase": SaveSystem.PHASE,
		"locale": "en",
		"day": day,
		"gold": gold,
		"player": {
			"nation_id": "portugal",
			"background_id": "",
			"attributes": {"constitution": 10, "intellect": 10,
				"charisma": 10, "courage": 10, "luck": 10},
			"skills": {"seamanship": 0, "navigation": 0, "swordplay": swordplay,
				"gunnery": 0, "appraisal": 0, "negotiation": 0,
				"cartography": 0, "rumour": 0},
			"skill_counters": {"seamanship": 0, "navigation": 0,
				"swordplay": 0, "gunnery": 0, "appraisal": 0,
				"negotiation": 0, "cartography": 0, "rumour": 0},
			"alloc_pending": 0,
			"xp": 0,
			"level": 1,
			"officers": [],
			"reputation": {
				"portugal": 10, "spain": 10, "england": 10,
				"holland": 10, "ottoman": 10, "italy": 10,
			},
		},
		"fleet": fleet.duplicate(true),
		"morale": 70,
		"world": {
			"position": {"x": CONTACT.x, "y": CONTACT.y},
			"weather": "fair",
			"map_id": SaveSystem.DEFAULT_MAP_ID,
		},
		"current_port": null,
		"known_ports": ["lisbon", "london", "seville", "amsterdam"],
		"port_investments": {},
		"discoveries_found": [],
		"npc_fleets": [],
		"proximity_cooldowns": {},
		"fame": 0,
		"titles": _nation_map("none"),
		"bounties": {},
		"active_quests": [],
		"completed_royal_missions": _nation_map(0),
		"discoveries_reported": [],
		"discovery_hints": {},
		"battles_won": 0,
		"retired": false,
		"retired_at": 0,
	}


## `{nation_id: value}` over `data/nations.json` (the §8.1 map-shaped keys).
func _nation_map(value) -> Dictionary:
	var out := {}
	for entry in DataLoader.nations_list:
		out[str(entry.get("id", ""))] = value
	return out


func _start_from_save(label: String, fleet: Array, day: int, gold: int,
		swordplay: int) -> bool:
	_ensure_slot_dir()
	var payload := _current_payload(fleet, day, gold, swordplay)
	var file := FileAccess.open(SaveSystem.slot_path(1), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	# Quit-and-restart: wipe the live state so a silent no-op load is visible.
	_clobber_state()
	var loaded: bool = SaveSystem.load(1)
	_check(loaded and SaveSystem.last_read_error.is_empty(),
		"%s: SaveSystem.load(1) restored the save file (%s)"
		% [label, SaveSystem.last_read_error])
	_check(GameState.day == day and GameState.gold == gold,
		"%s: the save's day/gold restore exactly (%d/%d)" % [label, day, gold])
	_check(GameState.fleet.size() == fleet.size()
			and (GameState.fleet[0] as Dictionary).has("equipment"),
		"%s: the fleet and its equipment blocks restore" % label)
	return loaded


# ===========================================================================
# Save round trip (save → load → save) per scenario
# ===========================================================================

func _assert_round_trip(label: String) -> void:
	_ensure_slot_dir()
	_check(SaveSystem.save(1), "%s: the post-battle state saves" % label)
	var on_disk := _read_slot(1)
	_check(int(on_disk.get("save_version", -1)) == SaveSystem.SAVE_VERSION,
		"%s: the re-saved file is save_version %d (%s)"
		% [label, SaveSystem.SAVE_VERSION, str(on_disk.get("save_version"))])
	_check(on_disk.has("npc_fleets") and on_disk.has("proximity_cooldowns"),
		"%s: the file carries the state blocks" % label)
	var fleet_before: Array = GameState.fleet.duplicate(true)
	var reloaded: bool = SaveSystem.load(1)
	_check(reloaded and SaveSystem.last_read_error.is_empty(),
		"%s: the file reloads cleanly (%s)" % [label, SaveSystem.last_read_error])
	_check(GameState.fleet == fleet_before,
		"%s: the fleet survives the reload (%d ships)" % [label, GameState.fleet.size()])


# ===========================================================================
# Fixtures & helpers
# ===========================================================================

func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"cargo": {},
		# The §4.11.12 equipment block every current-version ship carries.
		"equipment": {"figurehead": "", "sail": ""},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


## Wipes every GameState field so a load that silently did nothing is visible.
func _clobber_state() -> void:
	GameState.locale = "zh"
	GameState.day = 1
	GameState.gold = 1
	GameState.morale = 99
	GameState.current_port = null
	GameState.player = {}
	GameState.fleet = []
	GameState.world = {"position": {"x": 0, "y": 0}, "clock_fraction": 0.0}
	GameState.known_ports = []
	GameState.port_investments = {}
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.pending_encounter = null
	GameState.officer_states = {}
	GameState.captain_states = {}


func _unit(sim, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


func _place(sim, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["pos"] = cell


func _face(sim, side: String, index: int, heading8: int) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["heading8"] = heading8


func _reputation_snapshot() -> Dictionary:
	var out := {}
	for nation_id in GameState.player.get("reputation", {}):
		out[str(nation_id)] = int((GameState.player["reputation"] as Dictionary)[nation_id])
	return out


func _expected_rep_block(nations: Array) -> Dictionary:
	var out := {}
	for nation_id in nations:
		out[str(nation_id)] = BattleRewardsLib.PIRATE_REP_GAIN
	return out


func _ui(key: String, locale: String) -> String:
	var value = DataLoader.ui_strings.get(key, {})
	return str((value as Dictionary).get(locale, "")) if value is Dictionary else ""


func _as_array(value) -> Array:
	return (value as Array) if value is Array else []


func _as_dict(value) -> Dictionary:
	return (value as Dictionary) if value is Dictionary else {}


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## Every string shaped like `I18n.t_key`'s `<key>` missing-entry marker.
func _has_raw_key(values: Array) -> bool:
	for value in values:
		var text := str(value)
		if text.begins_with("<") and text.ends_with(">") and text.length() > 2 \
				and not text.contains(" "):
			return true
	return false


func _free_node(node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	await get_tree().process_frame


# ===========================================================================
# Save-file isolation (same contract as tools/test_save.gd)
# ===========================================================================

func _read_slot(slot: int) -> Dictionary:
	var text := FileAccess.get_file_as_string(SaveSystem.slot_path(slot))
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return SaveSystem.normalize_numbers(parsed) if parsed is Dictionary else {}


func _ensure_slot_dir() -> void:
	if not DirAccess.dir_exists_absolute(SaveSystem.SLOT_DIR):
		DirAccess.make_dir_recursive_absolute(SaveSystem.SLOT_DIR)


func _delete_all_slots() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")


func _backup_saves() -> void:
	_backup.clear()
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_bytes(path)
	_delete_all_slots()


func _cleanup_saves() -> void:
	_delete_all_slots()
	if _backup.is_empty():
		return
	_ensure_slot_dir()
	for slot in _backup:
		var file := FileAccess.open(SaveSystem.slot_path(int(slot)), FileAccess.WRITE)
		if file != null:
			file.store_buffer(_backup[slot])
			file.close()
	_backup.clear()


# ===========================================================================
# Harness
# ===========================================================================

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
