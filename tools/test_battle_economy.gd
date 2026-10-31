extends Node
## Phase-2 task G (economy & strings integration) acceptance tests
## (docs/IMPLEMENT-Phase2.md G; docs/60-COMBAT.md §4.8, §4.11.10, §4.12.2,
## §4.12.3, §4.12.4, §4.12.5; docs/80-UI-UX.md §4.4, §4.7.1, §4.7.2;
## docs/00-OVERVIEW.md §9, §12).
##
##   godot --headless --path . tools/test_battle_economy.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 salvage gold: `Σ floor(base_price × 0.05)` over sunk hulls (§4.11.10);
##   2 battle XP: `+10`/neutralised + `+5`/round, 0 on retreat (§4.10);
##   3 the two nearest ports' nations (Chebyshev, ties by id, nation once);
##   4 `BattleRewards.apply()`: gold/XP/reputation exactly, ±100 clamp,
##     idempotent, and never a navy `−20` (§4.11.10, §4.12.3);
##   5 engine agreement: `BattleSim.outcome()`'s `salvage_gold`/`xp` are the
##     `BattleRewards` formulas over a seeded sweep of pirate and navy battles;
##   6 the whole reward pipeline through `battle_screen.gd`: one battle via
##     `open_battle` + `run_to_completion` applies the outcome exactly once;
##   7 locale completeness (the done-when gate): every `battle.*`/`duel.*`/
##     `encounter.*`/`gameover.captured` key resolves in BOTH locales, and no
##     rendered label of S10's after-action dialog, S11's duel modal, S3's
##     encounter confirm or S9's captured screen contains a `<key>` in either
##     locale.

const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const AiLib := preload("res://scripts/combat/ai_fleet.gd")
const RewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const EncountersLib := preload("res://scripts/world/encounters.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const ScreenScene := preload("res://scenes/combat/battle_screen.tscn")
const DuelScene := preload("res://scenes/combat/duel_modal.tscn")
const DuelLib := preload("res://scripts/combat/duel.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")

## §4.11.10 worked numbers: sloop 3000 → 150, brigantine 15000 → 750.
const SALVAGE_SLOOP := 150
const SALVAGE_BRIGANTINE := 750
## An open-water cell whose 8 neighbours are all passable. Phase 4 (task G):
## re-anchored from the retired P1 grid's (20,20) — that tile is polar ice on
## the 2160×1080 world.
const OPEN_CELL := Vector2i(700, 320)
## A contact tile whose two nearest ports are Lisbon (Portugal, d=6) and Seville
## (Spain, d=10) — two distinct nations, no tie. Re-anchored from P1's (7,57)
## to the world's Lisbon harbor.
const LISBON_CONTACT := Vector2i(1030, 310)
## A contact tile whose two nearest ports are both Portuguese (Lisbon d=15 and
## Oporto d=15) — the "nation credited once" case. Re-anchored from P1's
## (30,40) (which no longer sits between two same-nation ports).
const SAME_NATION_CONTACT := Vector2i(1025, 308)
## A contact tile where the two nearest ports tie on distance (Amsterdam 11 /
## London 11), so the port-id tie-break decides: amsterdam < london → Holland
## before England. Re-anchored from (1080,204) after the harbor-pair snap moved
## Amsterdam's berth one tile east (`20-*` §4.11.1).
const TIE_CONTACT := Vector2i(1096, 219)

## The 47-key §4.12.5 inventory, transcribed from the doc table (the contract:
## D/C/F "must not invent others"). Task G verified the *texts* against the
## table as well; the suite pins the key set so a merge cannot drop one.
const DOC_KEYS_47: Array[String] = [
	"battle.title", "battle.round",
	"battle.action.cannon", "battle.action.ram", "battle.action.board",
	"battle.action.hold", "battle.action.retreat", "battle.action.surrender",
	"battle.reload", "battle.target.none",
	"battle.log.cannon", "battle.log.ram", "battle.log.sunk", "battle.log.turn",
	"battle.duel.start", "battle.duel.round",
	"battle.result.victory", "battle.result.defeat", "battle.result.retreat",
	"battle.result.surrender",
	"battle.after.title", "battle.after.loot", "battle.after.xp",
	"battle.after.captured", "battle.after.scuttled", "battle.after.overflow",
	"battle.after.lost", "battle.after.rep",
	"battle.log.hold", "battle.log.board", "battle.log.surrender_enemy",
	"battle.reason.no_cannons", "battle.reason.out_of_range",
	"battle.surrender.confirm", "battle.retreat.confirm",
	"duel.title", "duel.round.win", "duel.round.loss", "duel.round.tie",
	"duel.result.capture", "duel.result.defeat", "duel.committed",
	"encounter.pirate", "encounter.navy", "encounter.contact",
	"encounter.attack_confirm",
	"gameover.captured",
]
const REQUIRED_EXTRA: Array[String] = ["gameover.captured"]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_salvage_formula()
	_test_xp_formula()
	_test_nearest_nations()
	_test_apply()
	_test_engine_agreement()
	await _test_scene_pipeline()
	await _test_locale_completeness()
	_report()


# --- 1. Salvage (§4.11.10) ------------------------------------------------

func _test_salvage_formula() -> void:
	_check(RewardsLib.SALVAGE_FRACTION == 0.05,
		"the salvage fraction is the pinned 0.05 (%s)" % str(RewardsLib.SALVAGE_FRACTION))
	_check(RewardsLib.salvage_for([]) == 0, "no sunk hull → no salvage gold")
	_check(RewardsLib.salvage_for(["sloop"]) == SALVAGE_SLOOP,
		"a sunk sloop pays floor(3000 × 0.05) = %d (%d)"
		% [SALVAGE_SLOOP, RewardsLib.salvage_for(["sloop"])])
	_check(RewardsLib.salvage_for(["brigantine"]) == SALVAGE_BRIGANTINE,
		"a sunk brigantine pays floor(15000 × 0.05) = %d (%d)"
		% [SALVAGE_BRIGANTINE, RewardsLib.salvage_for(["brigantine"])])
	# Per-hull flooring, not one floor over the sum: latin 1200 → 60,
	# galley 10000 → 500, galleon 60000 → 3000.
	_check(RewardsLib.salvage_for(["latin", "galley", "galleon"]) == 60 + 500 + 3000,
		"a mixed hull set sums the per-hull floors (%d)"
		% RewardsLib.salvage_for(["latin", "galley", "galleon"]))
	_check(RewardsLib.salvage_for(["sloop", "sloop"]) == 2 * SALVAGE_SLOOP,
		"two sunk sloops pay twice (%d)" % RewardsLib.salvage_for(["sloop", "sloop"]))
	# Every locked hull type yields a positive, floor-correct number.
	var mismatches: Array[String] = []
	for ship_type in DataLoader.ship_types_list:
		var ship_type_id := str(ship_type.get("id", ""))
		var expected := int(floor(float(ship_type.get("base_price", 0)) * 0.05))
		if RewardsLib.salvage_for([ship_type_id]) != expected:
			mismatches.append("%s: %d != %d" % [ship_type_id,
				RewardsLib.salvage_for([ship_type_id]), expected])
	_check(mismatches.is_empty(),
		"every locked ShipType salvages floor(base_price × 0.05) (%s)"
		% str(mismatches))
	# A corrupted id contributes 0 instead of crashing a battle end.
	_check(RewardsLib.salvage_for(["no_such_hull"]) == 0,
		"an unknown hull id contributes no salvage")


# --- 2. XP (§4.11.10, §4.10) ----------------------------------------------

func _test_xp_formula() -> void:
	_check(RewardsLib.XP_PER_ENEMY_NEUTRALIZED == 10,
		"XP per neutralised hull is the pinned 10")
	_check(RewardsLib.XP_PER_ROUND == 5, "XP per round is the pinned 5")
	_check(RewardsLib.xp_for(0, 0) == 0, "nothing neutralised, no rounds → 0 XP")
	_check(RewardsLib.xp_for(1, 1) == 15,
		"one hull in one round → 10 + 5 = 15 (%d)" % RewardsLib.xp_for(1, 1))
	_check(RewardsLib.xp_for(3, 6) == 60,
		"three hulls over six rounds → 30 + 30 = 60 (%d)"
		% RewardsLib.xp_for(3, 6))
	# A retreat forfeits the round XP as well as the kill XP (§4.10 "costs no XP").
	var retreat := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop")],
	}).retreat()
	_check(str(retreat.get("result", "")) == "retreat",
		"the retreat fixture ends in `retreat` (%s)" % str(retreat.get("result")))
	_check(int(retreat.get("xp", -1)) == 0,
		"a retreat awards 0 XP even though a round was played (%d)"
		% int(retreat.get("xp", -1)))
	_check(int(retreat.get("salvage_gold", -1)) == 0,
		"a retreat salvages nothing (nothing was sunk) (%d)"
		% int(retreat.get("salvage_gold", -1)))
	_check((retreat.get("rep_deltas", {}) as Dictionary).is_empty(),
		"a retreat from pirates credits no nation (§4.11.10 'except retreat') (%s)"
		% str(retreat.get("rep_deltas")))


# --- 3. Nearest ports (§4.11.10) ------------------------------------------

func _test_nearest_nations() -> void:
	_check(RewardsLib.NEAREST_PORT_COUNT == 2, "the pin credits two ports")
	# Lisbon (Portugal, d=6) and Seville (Spain, d=10) are the two nearest.
	var near_lisbon := RewardsLib.nearest_nations(LISBON_CONTACT)
	_check(near_lisbon == ["portugal", "spain"],
		"near Lisbon the two nearest nations are Portugal then Spain (%s)"
		% str(near_lisbon))
	# At (1025,308) the two nearest ports are Lisbon and Oporto (both d=15),
	# both Portuguese → the nation is credited once, so the list holds one entry.
	var same_nation := RewardsLib.nearest_nations(SAME_NATION_CONTACT)
	_check(same_nation == ["portugal"],
		"a same-nation port pair is credited once (%s)" % str(same_nation))
	# Ties break on port id ascending: amsterdam (26) before london (26).
	var tie := RewardsLib.nearest_nations(TIE_CONTACT)
	_check(tie == ["holland", "england"],
		"a distance tie breaks by port id ascending → amsterdam before london (%s)"
		% str(tie))
	# Sanity: the list never repeats a nation and never carries "".
	var repeated: Array[String] = []
	var blanks: Array[String] = []
	for x in range(0, 2160, 61):
		for y in range(0, 1080, 37):
			var nations := RewardsLib.nearest_nations(Vector2i(x, y))
			var seen: Array[String] = []
			for nation_id in nations:
				if nation_id.is_empty():
					blanks.append(str(Vector2i(x, y)))
				if nation_id in seen:
					repeated.append("%s@%s" % [nation_id, str(Vector2i(x, y))])
				seen.append(nation_id)
			if nations.size() > RewardsLib.NEAREST_PORT_COUNT:
				repeated.append("too many@%s" % str(Vector2i(x, y)))
	_check(repeated.is_empty(),
		"no nation is ever credited twice over the whole map (%d violations)"
		% repeated.size())
	_check(blanks.is_empty(),
		"no empty nation id is ever credited (%d violations)" % blanks.size())

	# The engine's own rep deltas must be this exact list at +2 each (§4.11.10).
	var pirate := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10})],
		"enemy_ships": [_ship("sloop", {"durability": 1})],
		"contact": LISBON_CONTACT,
	})
	pirate.start()
	var gunner := _unit(pirate, "player", 0)
	var wreck := _unit(pirate, "enemy", 0)
	_place(pirate, "enemy", 0, Vector2i(3, 4))
	_check(bool(pirate.cannon(gunner, wreck)["sunk"]), "the sloop sinks to one volley")
	var outcome := pirate.outcome()
	var expected := {}
	for nation_id in near_lisbon:
		expected[nation_id] = RewardsLib.PIRATE_REP_GAIN
	_check(outcome["rep_deltas"] == expected,
		"outcome.rep_deltas is the nearest-nations list at +2 (%s vs %s)"
		% [str(outcome["rep_deltas"]), str(expected)])
	_check(RewardsLib.PIRATE_REP_GAIN == 2, "the pirate reputation gain is the pinned +2")


# --- 4. BattleRewards.apply() (§4.12.3) -----------------------------------

func _test_apply() -> void:
	_make_run()
	var gold_before := GameState.gold
	var xp_before := CharacterLib.current_xp()
	var rep_before := CharacterLib.reputation("portugal")
	var applied := RewardsLib.apply(_outcome({
		"salvage_gold": 900, "xp": 65,
		"rep_deltas": {"portugal": 2, "spain": 2},
	}))
	_check(int(applied["gold"]) == 900,
		"apply() reports the salvage gold it added (%d)" % int(applied["gold"]))
	_check(GameState.gold == gold_before + 900,
		"apply() adds the salvage gold exactly (%d → %d)"
		% [gold_before, GameState.gold])
	_check(CharacterLib.current_xp() == xp_before + 65,
		"apply() awards the battle XP exactly (%d → %d)"
		% [xp_before, CharacterLib.current_xp()])
	_check(CharacterLib.reputation("portugal") == rep_before + 2
			and CharacterLib.reputation("spain") == 2,
		"apply() credits every rep_deltas nation (portugal %d, spain %d)"
		% [CharacterLib.reputation("portugal"), CharacterLib.reputation("spain")])
	_check(applied["rep_deltas"] == {"portugal": 2, "spain": 2},
		"apply() returns the deltas it applied (%s)" % str(applied["rep_deltas"]))

	# Idempotent: a second call on the same block is a no-op (§4.12.3).
	var settled := _outcome({"salvage_gold": 900, "xp": 65,
		"rep_deltas": {"portugal": 2}})
	RewardsLib.apply(settled)
	_check(bool(settled.get("rewards_applied", false)),
		"apply() marks the block `rewards_applied`")
	var gold_mid := GameState.gold
	var xp_mid := CharacterLib.current_xp()
	var rep_mid := CharacterLib.reputation("portugal")
	var again := RewardsLib.apply(settled)
	_check(int(again["gold"]) == 0 and int(again["xp"]) == 0
			and (again["rep_deltas"] as Dictionary).is_empty(),
		"a second apply() on the same block applies nothing (%s)" % str(again))
	_check(GameState.gold == gold_mid and CharacterLib.current_xp() == xp_mid
			and CharacterLib.reputation("portugal") == rep_mid,
		"…and leaves gold/XP/reputation untouched (%d/%d/%d)"
		% [GameState.gold, CharacterLib.current_xp(), CharacterLib.reputation("portugal")])

	# Reputation clamps at the §4.6 ±100 bounds through Character.add_reputation.
	_make_run()
	CharacterLib.add_reputation("portugal", 79)
	_check(CharacterLib.reputation("portugal") == 99,
		"the fixture starts at 99 reputation (got %d)"
		% CharacterLib.reputation("portugal"))
	var clamped := RewardsLib.apply(_outcome({
		"salvage_gold": 0, "xp": 0, "rep_deltas": {"portugal": 2, "spain": -500},
	}))
	_check(CharacterLib.reputation("portugal") == 100,
		"a +2 at 99 clamps to +100 (got %d)" % CharacterLib.reputation("portugal"))
	_check(CharacterLib.reputation("spain") == -100,
		"a large negative delta clamps at −100 (got %d)"
		% CharacterLib.reputation("spain"))
	_check(clamped["rep_deltas"] == {"portugal": 1, "spain": -100},
		"apply() reports the clamped step it really moved (portugal +1, spain "
		+ "−100): %s" % str(clamped["rep_deltas"]))

	# A zero/absent reward block applies nothing and never goes negative.
	_make_run()
	var zero_gold := GameState.gold
	var zero := RewardsLib.apply(_outcome({
		"salvage_gold": 0, "xp": 0, "rep_deltas": {},
	}))
	_check(int(zero["gold"]) == 0 and int(zero["xp"]) == 0
			and (zero["rep_deltas"] as Dictionary).is_empty()
			and GameState.gold == zero_gold,
		"a zero-reward outcome changes nothing")
	_check(RewardsLib.apply({}).is_empty() == false
			and int(RewardsLib.apply({})["gold"]) == 0,
		"an empty dictionary is a safe no-op")

	# §4.11.10 navy pin: the −20 is charged once at battle start, so a navy
	# outcome carries no negative entry and apply() never charges one.
	var navy := _sim({
		"player_ships": [_ship("brigantine", {"cannons": 10, "crew": 40})],
		"enemy_ships": [_ship("sloop", {"durability": 1})],
		"enemy_kind": "navy",
		"enemy_nation": "spain",
		"contact": LISBON_CONTACT,
	})
	navy.start()
	var navy_gunner := _unit(navy, "player", 0)
	_place(navy, "enemy", 0, Vector2i(3, 4))
	_check(bool(navy.cannon(navy_gunner, _unit(navy, "enemy", 0))["sunk"]),
		"the navy sloop sinks to one volley")
	var navy_outcome := navy.outcome()
	_check(str(navy_outcome["result"]) == "victory",
		"the navy fixture is a victory (%s)" % str(navy_outcome["result"]))
	var negatives: Array[String] = []
	for nation_id in (navy_outcome["rep_deltas"] as Dictionary):
		if int((navy_outcome["rep_deltas"] as Dictionary)[nation_id]) < 0:
			negatives.append("%s:%d" % [nation_id,
				int((navy_outcome["rep_deltas"] as Dictionary)[nation_id])])
	_check((navy_outcome["rep_deltas"] as Dictionary).is_empty(),
		"a navy outcome carries no rep_deltas at all (the −20 is charged at "
		+ "battle start): %s" % str(navy_outcome["rep_deltas"]))
	_check(negatives.is_empty(),
		"no rep_deltas entry is ever negative (%s)" % str(negatives))
	_check(BattleLib.NAVY_REP_PENALTY == -20,
		"the pinned navy penalty is still −20 (applied elsewhere)")
	_check(EncountersLib.PIRACY_REPUTATION == BattleLib.NAVY_REP_PENALTY,
		"the battle-start piracy charge and the engine constant are the same −20")
	_make_run()
	var spain_before := CharacterLib.reputation("spain")
	var navy_applied := RewardsLib.apply(navy_outcome)
	_check(CharacterLib.reputation("spain") == spain_before
			and (navy_applied["rep_deltas"] as Dictionary).is_empty(),
		"applying a navy outcome charges no reputation (spain %d)"
		% CharacterLib.reputation("spain"))
	_check(int(navy_applied["gold"]) == int(navy_outcome["salvage_gold"]),
		"…but it still pays the salvage (%d)" % int(navy_applied["gold"]))


# --- 5. Engine agreement (§4.12.2 vs the formulas) ------------------------

func _test_engine_agreement() -> void:
	var salvage_mismatches: Array[String] = []
	var xp_mismatches: Array[String] = []
	var search = [SAME_NATION_CONTACT, LISBON_CONTACT, TIE_CONTACT]
	for kind in ["pirate", "navy"]:
		for seed_offset in range(1, 13):
			var battle_seed := 700000 + seed_offset
			var rng := _rng(battle_seed)
			var foes := AiLib.compose_enemy(kind, 20, rng)
			var sim := BattleLib.new({
				"player_ships": [
					_ship("brigantine", {"cannons": 10, "crew": 40}),
					_ship("sloop", {"cannons": 3}),
				],
				"enemy_ships": foes,
				"enemy_kind": kind,
				"enemy_nation": "spain" if kind == "navy" else "",
				"day": 20, "gold": 500, "contact": search[seed_offset % 3],
				"weather": "calm", "rng": rng,
			})
			sim.start()
			var policy := func(active_sim) -> Dictionary:
				var current: Dictionary = active_sim.current_unit()
				if current.is_empty():
					return {"action": "hold", "target": {}, "cell": BattleLib.NO_CELL}
				if str(current["side"]) == "enemy":
					return AiLib.decide(active_sim, current)
				return _player_policy(active_sim, current)
			var outcome := sim.run_to_completion(policy, 30)
			if not sim.is_over():
				xp_mismatches.append("seed %d never finished" % battle_seed)
				continue
			var expected_salvage := RewardsLib.salvage_for(outcome["sunk_enemy"])
			if int(outcome["salvage_gold"]) != expected_salvage:
				salvage_mismatches.append("%s/%d: %d != %d (%s)" % [kind, battle_seed,
					int(outcome["salvage_gold"]), expected_salvage,
					str(outcome["sunk_enemy"])])
			var neutralised := RewardsLib.neutralised_for(outcome)
			var expected_xp := RewardsLib.xp_for(neutralised, int(outcome["rounds"]))
			if str(outcome["result"]) == BattleLib.RESULT_RETREAT:
				expected_xp = 0
			if int(outcome["xp"]) != expected_xp:
				xp_mismatches.append("%s/%d: %d != %d (%d neutralised, %d rounds)"
					% [kind, battle_seed, int(outcome["xp"]), expected_xp,
						neutralised, int(outcome["rounds"])])
			# A navy outcome must never carry the −20 (§4.11.10).
			if kind == "navy" and not (outcome["rep_deltas"] as Dictionary).is_empty():
				salvage_mismatches.append("%s/%d carries rep_deltas %s"
					% [kind, battle_seed, str(outcome["rep_deltas"])])
	_check(salvage_mismatches.is_empty(),
		"24 seeded battles: outcome.salvage_gold == BattleRewards.salvage_for("
		+ "sunk_enemy) (%d mismatches: %s)"
		% [salvage_mismatches.size(), str(salvage_mismatches.slice(0, 3))])
	_check(xp_mismatches.is_empty(),
		"24 seeded battles: outcome.xp == +10/neutralised + 5/round (%d mismatches: %s)"
		% [xp_mismatches.size(), str(xp_mismatches.slice(0, 3))])


# --- 6. Full pipeline through battle_screen.gd (§4.12.4) ------------------

func _test_scene_pipeline() -> void:
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
	var screen = ScreenScene.instantiate()
	screen.route_to_world = false
	add_child(screen)
	await get_tree().process_frame
	var encounter := _pirate_encounter(1, "latin")
	(encounter["ships"][0] as Dictionary)["durability"] = 5
	screen.open_battle(encounter)
	await get_tree().process_frame

	var gold_before := GameState.gold
	var xp_before := CharacterLib.current_xp()
	var rep_before := _reputation_snapshot()
	screen.run_to_completion(30)
	await get_tree().process_frame
	var outcome: Dictionary = screen.last_outcome
	_check(screen.battle_finished() and str(outcome.get("result", "")) == "victory",
		"the scene battle finished in a victory (%s)" % str(outcome.get("result", "")))
	_check(bool(outcome.get("rewards_applied", false)),
		"the scene applied the reward block (rewards_applied)")

	# Exactly the outcome block's numbers, once.
	_check(GameState.gold == gold_before + int(outcome.get("salvage_gold", 0)),
		"gold rose by exactly the outcome salvage (%d + %d = %d)"
		% [gold_before, int(outcome.get("salvage_gold", 0)), GameState.gold])
	_check(CharacterLib.current_xp() == xp_before + int(outcome.get("xp", 0)),
		"XP rose by exactly the outcome xp (%d + %d = %d)"
		% [xp_before, int(outcome.get("xp", 0)), CharacterLib.current_xp()])
	var rep_ok := true
	var rep_report: Array[String] = []
	for nation_id in (outcome.get("rep_deltas", {}) as Dictionary):
		var delta := int((outcome["rep_deltas"] as Dictionary)[nation_id])
		var expected := clampi(int(rep_before.get(nation_id, 0)) + delta, -100, 100)
		var actual := CharacterLib.reputation(str(nation_id))
		rep_report.append("%s %d→%d" % [str(nation_id), int(rep_before.get(nation_id, 0)),
			actual])
		if actual != expected:
			rep_ok = false
	_check(rep_ok, "reputation moved by exactly the outcome deltas (%s)"
		% str(rep_report))
	_check(not (outcome.get("rep_deltas", {}) as Dictionary).is_empty(),
		"the pirate victory credited the two nearest nations (%s)"
		% str(outcome.get("rep_deltas")))
	var rewards = outcome.get("rewards", {})
	_check(rewards is Dictionary and int((rewards as Dictionary).get("gold", -1))
			== int(outcome.get("salvage_gold", 0))
			and int((rewards as Dictionary).get("xp", -1)) == int(outcome.get("xp", 0)),
		"the screen records what BattleRewards applied (%s)" % str(rewards))

	# A second call on the same block (a retried sequence) pays nothing more.
	var gold_after := GameState.gold
	var xp_after := CharacterLib.current_xp()
	var rep_after := _reputation_snapshot()
	var replay := RewardsLib.apply(outcome)
	_check(int(replay["gold"]) == 0 and int(replay["xp"]) == 0,
		"replaying apply() on the applied block pays nothing (%s)" % str(replay))
	screen._finish_battle()
	await get_tree().process_frame
	_check(GameState.gold == gold_after and CharacterLib.current_xp() == xp_after
			and _reputation_snapshot() == rep_after,
		"the screen's own finish guard cannot double-apply either (%d/%d)"
		% [GameState.gold, CharacterLib.current_xp()])
	_check(screen.after_action_dialog().visible,
		"the after-action dialog is up after the battle")
	_check(not screen.game_over_open(), "a victory against pirates is no game over")
	screen.queue_free()
	await get_tree().process_frame


# --- 7. Locale completeness (the done-when gate) --------------------------

func _test_locale_completeness() -> void:
	# 7a. Every `battle.*` / `duel.*` / `encounter.*` / `gameover.captured` key
	# resolves in both locales, with a real value rather than a marker.
	var locale_before: String = GameState.locale
	var broken: Array[String] = []
	var missing: Array[String] = []
	for locale in ["zh", "en"]:
		I18n.set_locale(locale)
		for key in _required_keys():
			if not DataLoader.ui_strings.has(key):
				missing.append("%s/%s" % [locale, key])
				continue
			var text := I18n.t_key(key)
			if text.strip_edges().is_empty() or _has_raw_key([text]):
				broken.append("%s/%s='%s'" % [locale, key, text])
	_check(missing.is_empty(),
		"every §4.12.5 key exists in ui_strings.json (%d missing: %s)"
		% [missing.size(), str(missing.slice(0, 5))])
	_check(broken.is_empty(),
		"every §4.12.5 key resolves in both locales (%d broken: %s)"
		% [broken.size(), str(broken.slice(0, 5))])
	# The §4.12.5 inventory is a contract: exactly the 47 doc rows, no more.
	_check(_required_keys().size() == 47,
		"the §4.12.5 inventory is the 47 doc rows (%d)" % _required_keys().size())
	var extra: Array[String] = []
	for key in DOC_KEYS_47:
		if not DataLoader.ui_strings.has(key):
			extra.append(key)
	_check(extra.is_empty(),
		"every one of the 47 documented keys is in ui_strings.json (missing: %s)"
		% str(extra))

	# 7b. No rendered label of S10's after-action dialog, S11's modal or S3's
	# encounter confirm contains a `<key>` in either locale.
	var leaks: Array[String] = []
	for locale in ["zh", "en"]:
		I18n.set_locale(locale)
		await get_tree().process_frame

		# S10 after-action dialog, from a real battle.
		_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
		var screen = ScreenScene.instantiate()
		screen.route_to_world = false
		add_child(screen)
		await get_tree().process_frame
		var encounter := _pirate_encounter(1, "latin")
		(encounter["ships"][0] as Dictionary)["durability"] = 5
		screen.open_battle(encounter)
		await get_tree().process_frame
		screen.run_to_completion(30)
		await get_tree().process_frame
		var dialog_lines: Array = screen.after_action_lines()
		leaks.append_array(_labelled_leaks(dialog_lines, "S10/%s" % locale))
		if _joined(dialog_lines).strip_edges().is_empty():
			leaks.append("S10/%s rendered nothing" % locale)
		# The mid-dialog locale toggle must re-translate, not reload.
		leaks.append_array(_labelled_leaks(screen.log_lines(), "S10log/%s" % locale))
		screen.queue_free()
		await get_tree().process_frame

		# S11 duel modal (full-rect anchored, so its size comes from the scene).
		var modal = DuelScene.instantiate()
		add_child(modal)
		await get_tree().process_frame
		modal.open_duel(DuelLib.preview({
			"player_base": 15, "defender_base": 10, "seed": 33,
			"attacker_name": "You", "defender_name": "Pirate captain",
			"ship_name": "Brigantine",
		}))
		await get_tree().process_frame
		leaks.append_array(_widget_leaks(modal, "S11/%s" % locale))
		modal.close()
		modal.queue_free()
		await get_tree().process_frame

		# S3 encounter confirm (the navy attack warning).
		leaks.append_array(await _encounter_confirm_leaks(locale))

		# S9 `gameover.captured` (the Phase-2 reason, §4.12.5) is the terminal
		# screen of a lost last ship — it must name the reason, not a `<key>`.
		leaks.append_array(await _gameover_leaks(locale))

	I18n.set_locale(locale_before)
	await get_tree().process_frame
	_check(leaks.is_empty(),
		"no <key> in S10's dialog, S11's modal, S3's encounter confirm or S9's "
		+ "captured screen in either locale (%d leaks: %s)"
		% [leaks.size(), str(leaks.slice(0, 5))])

	# The same battle text really differs between locales (a copy, not a
	# fallback), and its placeholder survives in both (the §4.4 contract).
	var english := _text_in_locale("battle.after.loot", "en")
	var chinese := _text_in_locale("battle.after.loot", "zh")
	_check(english != chinese and english.contains("{gold}")
			and chinese.contains("{gold}"),
		"battle.after.loot is translated in both locales with the same "
		+ "placeholder (%s / %s)" % [english, chinese])
	_check(I18n.fmt("battle.after.loot", {"gold": 150}).contains("150"),
		"the {gold} placeholder substitutes at render time (%s)"
		% I18n.fmt("battle.after.loot", {"gold": 150}))


## The §4.12.5 inventory key set, plus the `gameover.captured` reason it names.
func _required_keys() -> Array[String]:
	var keys: Array[String] = []
	for key in DOC_KEYS_47:
		if not keys.has(key):
			keys.append(key)
	for key in REQUIRED_EXTRA:
		if not keys.has(key):
			keys.append(key)
	keys.sort()
	return keys


func _text_in_locale(key: String, locale: String) -> String:
	var before: String = GameState.locale
	I18n.set_locale(locale)
	var text := I18n.t_key(key)
	I18n.set_locale(before)
	return text


## Rendered-text leaks for S3's `encounter.attack_confirm` modal, built through
## the real world scene (the map fixture lives in `test_encounters.gd`).
func _encounter_confirm_leaks(locale: String) -> Array[String]:
	var leaks: Array[String] = []
	var map = MapLoaderLib.new()
	var loaded: bool = map.load_map("res://data/maps/world.png",
		DataLoader.map_legend)
	if not loaded:
		leaks.append("S3/%s map failed to load (%s)" % [locale, map.last_error])
		return leaks
	DataLoader.map = map
	_make_run()
	GameState.set_world_tile(OPEN_CELL)
	GameState.hostile_fleets = [{
		"id": EncountersLib.marker_id(1, OPEN_CELL + Vector2i(1, 0),
			EncountersLib.NAVY),
		"kind": EncountersLib.NAVY,
		"nation_id": "spain",
		"position": {"x": OPEN_CELL.x + 1, "y": OPEN_CELL.y},
		"anchor_port_id": "seville",
		"ships": EncountersLib.compose_ships(EncountersLib.NAVY, 1,
			OPEN_CELL + Vector2i(1, 0)),
		"spawn_day": 1,
		"cooldown_until_day": 0,
	}]
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	await get_tree().process_frame
	world.sync_from_state()
	if not world._try_attack(OPEN_CELL + Vector2i(1, 0)):
		leaks.append("S3/%s the navy attack did not open" % locale)
		host.queue_free()
		return leaks
	var dialog = world._attack_confirm
	if dialog == null:
		leaks.append("S3/%s the encounter confirm did not open" % locale)
		host.queue_free()
		return leaks
	var nation := I18n.t(DataLoader.get_nation("spain").get("name", {}))
	var message: String = dialog.message_text()
	if message.strip_edges().is_empty() or _has_raw_key([message]):
		leaks.append("S3/%s message='%s'" % [locale, message])
	if not message.contains(nation):
		leaks.append("S3/%s message omits the nation name (%s)"
			% [locale, message])
	leaks.append_array(_widget_leaks(dialog, "S3/%s" % locale))
	world._close_attack_confirm()
	await get_tree().process_frame
	host.queue_free()
	GameState.hostile_fleets = []
	await get_tree().process_frame
	return leaks


# --- Fixtures -------------------------------------------------------------

## S9 rendering of the Phase-2 `gameover.captured` reason (docs/60-* §4.12.5).
func _gameover_leaks(locale: String) -> Array[String]:
	var leaks: Array[String] = []
	var scene = GameOverScene.instantiate()
	scene.route_to_title = false
	add_child(scene)
	await get_tree().process_frame
	scene.open_reason("captured")
	await get_tree().process_frame
	var reason_text: String = scene.reason_text()
	if reason_text.strip_edges().is_empty() or _contains_key_marker(reason_text):
		leaks.append("S9/%s reason='%s'" % [locale, reason_text])
	if not reason_text.contains(I18n.t_key("gameover.captured")):
		leaks.append("S9/%s reason omits gameover.captured (%s)"
			% [locale, reason_text])
	leaks.append_array(_widget_leaks(scene, "S9/%s" % locale))
	scene.queue_free()
	await get_tree().process_frame
	return leaks


func _make_run(fleet: Array = []) -> void:
	GameState.locale = "en"
	GameState.day = 12
	GameState.gold = 3000
	GameState.current_port = null
	GameState.world = {"position": {"x": 30, "y": 40}, "clock_fraction": 0.0,
		"weather": "calm"}
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 12,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [],
		"equipment": {"weapon": "", "armor": ""},
		"reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0,
			"ottoman": 0, "italy": 0},
	}
	GameState.fleet = fleet.duplicate(true) if not fleet.is_empty() \
		else [_ship("caravel", {"cannons": 4, "crew": 15})]
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	if "pending_encounter" in GameState:
		GameState.set("pending_encounter", null)


## A §4.11.11 ship instance (the `40-*` §4.1 shape + §4.11.12 equipment).
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
		"enemy_nation": "", "day": 12, "gold": 3000,
		"contact": Vector2i(30, 40), "weather": "calm",
	}
	for key in config:
		full[key] = config[key]
	var sim := BattleLib.new(full)
	sim.start()
	return sim


func _unit(sim, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


func _place(sim, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["cell"] = cell


## A §4.11.11 encounter descriptor for the scene fixture.
func _pirate_encounter(enemy_count: int, hull_id: String) -> Dictionary:
	var ships: Array = []
	for _index in enemy_count:
		ships.append(_ship(hull_id))
	return {
		"id": "hf_econ_9_30_40_pirate",
		"kind": "pirate",
		"nation_id": "",
		"position": {"x": 30, "y": 40},
		"day": 9,
		"ships": ships,
	}


## A §4.12.2 outcome block skeleton with `fields` merged over it.
func _outcome(fields: Dictionary) -> Dictionary:
	var outcome := {
		"result": "victory", "rounds": 6, "kind": "pirate", "nation_id": "",
		"encounter_id": "", "contact": {"x": 30, "y": 40},
		"sunk_enemy": [], "captured_enemy": [], "surrendered_enemy": 0,
		"sunk_player": [], "lost_player": [],
		"salvage_gold": 0, "xp": 0, "rep_deltas": {},
		"cargo_overflow_lost": 0,
	}
	outcome.merge(fields, true)
	return outcome


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


## A simple player policy: fire when possible, else board, else close in.
func _player_policy(sim, unit: Dictionary) -> Dictionary:
	var enemies: Array = sim.living_units("enemy")
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
	var origin: Vector2i = sim.unit_cell(unit)
	var nearest: Dictionary = enemies[0]
	var best := maxi(absi(origin.x - sim.unit_cell(nearest).x),
		absi(origin.y - sim.unit_cell(nearest).y))
	for enemy in enemies:
		var cell: Vector2i = sim.unit_cell(enemy)
		var distance := maxi(absi(origin.x - cell.x), absi(origin.y - cell.y))
		if distance < best:
			best = distance
			nearest = enemy
	var target_cell: Vector2i = sim.unit_cell(nearest)
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


# --- Helpers --------------------------------------------------------------

func _reputation_snapshot() -> Dictionary:
	var out := {}
	for nation in DataLoader.nations_list:
		var nation_id := str(nation.get("id", ""))
		out[nation_id] = CharacterLib.reputation(nation_id)
	return out


## Every string shaped like `I18n.t_key`'s `<key>` missing-entry marker (§6).
func _has_raw_key(values: Array) -> bool:
	for value in values:
		var text := str(value)
		if text.begins_with("<") and text.ends_with(">") and text.length() > 2 \
				and not text.contains(" "):
			return true
		if _contains_key_marker(text):
			return true
	return false


## True when any `battle.`/`duel.`/`encounter.`/`gameover.` key is printed
## verbatim inside `text` (the `<battle.x>` marker anywhere in a longer line).
func _contains_key_marker(text: String) -> bool:
	var start := text.find("<")
	while start >= 0:
		var end := text.find(">", start)
		if end > start:
			var inner := text.substr(start + 1, end - start - 1)
			for prefix in ["battle.", "duel.", "encounter.", "gameover."]:
				if inner.begins_with(prefix):
					return true
		start = text.find("<", start + 1)
	return false


func _labelled_leaks(values: Array, tag: String) -> Array[String]:
	var out: Array[String] = []
	for value in values:
		var text := str(value)
		if text.strip_edges().is_empty() or _contains_key_marker(text):
			out.append("%s:'%s'" % [tag, text])
	return out


## Every visible Label/Button under `root` — never empty, never a `<key>`.
func _widget_leaks(root: Node, tag: String) -> Array[String]:
	var out: Array[String] = []
	for label in root.find_children("*", "Label", true, false):
		if not (label as CanvasItem).is_visible_in_tree():
			continue
		var text := (label as Label).text
		if text.strip_edges().is_empty() or _contains_key_marker(text):
			out.append("%s:%s='%s'" % [tag, label.name, text])
	for button in root.find_children("*", "Button", true, false):
		if not (button as CanvasItem).is_visible_in_tree():
			continue
		var text := (button as Button).text
		if text.strip_edges().is_empty() or _contains_key_marker(text):
			out.append("%s:%s='%s'" % [tag, button.name, text])
	return out


func _joined(values: Array) -> String:
	var parts: Array[String] = []
	for value in values:
		parts.append(str(value))
	return " | ".join(parts)


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
		print("  - " + failure)
	get_tree().quit(1)
