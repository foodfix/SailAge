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
##   4b haul valuation (Phase 8, W4-C): every haul gold credited
##     ×`clamp(1 + (appraisal + negotiation)/400, 1.0, 1.5)` (§4.8/§4.11.10);
##   4c battle XP multiplier (Phase 8): credited ×(1 + level/20), floored
##     once, at levels 1/10/20 (§4.8, `50-*` §4.4);
##   4d boarding morale (Phase 8): the outcome's `morale_bonus` moves
##     `GameState.morale` once, clamped (§4.8);
##   4e the capture officer gate (Phase 8): ≥ 1 idle officer joins the prize,
##     otherwise loot-convert + scuttle with the failed gate named
##     (§4.11.7/§4.11.15);
##   4f the captain lifecycle hooks (Phase 8): defeat (return day +60,
##     crushed on a wiped fleet), the nemesis stance −2 extra, the win on a
##     lost flagship duel (§4.11.15);
##   4g the piracy-fame extension hook (Phase 8): rep −20/+2 rivals unchanged,
##     plus −20 fame and the victim stance −1 (§4.11.10/§4.11.15);
##   4h the 4 named-pirate `drop`s still grant through the captain-id keying
##     on the v2 `named_pirates.json` (§4.11.13, Phase 8 correction 7);
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
const ResultLib := preload("res://scripts/combat/battle_result.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
## W4-C: the lifecycle hooks call slot A's contract through the guarded load;
## the stub this worktree carries implements the same names (the master keeps
## slot A's normative `captains.gd` at the merge).
const CaptainsLib := preload("res://scripts/world/captains.gd")
## Phase-5 task J: the S3-leg fixtures build §4.15 fleet dicts over the
## `NpcFleets` ecology (docs/60-* §4.11.11, §4.12.3).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
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
const LISBON_CONTACT := Vector2i(2054, 620)
## A contact tile whose two nearest ports are both Portuguese (Lisbon d=5 and
## Oporto d=34) — the "nation credited once" case. Re-anchored to the Phase-6
## grid (the finer raster moved Oporto's berth north of Lisbon's latitude).
const SAME_NATION_CONTACT := Vector2i(2047, 620)
## A contact tile where the two nearest ports tie on distance (Amsterdam 24 /
## London 24), so the port-id tie-break decides: amsterdam < london → Holland
## before England. Re-anchored to the Phase-6 grid (`20-*` §4.11.1).
const TIE_CONTACT := Vector2i(2190, 438)

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
	_test_haul_valuation()
	_test_battle_xp_multiplier()
	_test_boarding_morale()
	_test_capture_gate()
	_test_captain_lifecycle()
	_test_piracy_attack()
	_test_named_drops_canon()
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
	# Sanity: the list never repeats a nation and never carries "" — sampled
	# 10×10 over the map (the full sweep ran in Phase 4; this pins the
	# invariants cheaply).
	var repeated: Array[String] = []
	var blanks: Array[String] = []
	for x in range(0, 2160, 216):
		for y in range(0, 1080, 108):
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
	# Phase 8: the credited XP is the outcome total ×(1 + level/20) — at the
	# fixture's level 1 that is floor(65 × 1.05) = 68 (§4.11.10, 4c below).
	var expected_xp := RewardsLib.battle_xp_for(65)
	_check(expected_xp == 68,
		"the level multiplier is exact at level 1: floor(65 × 1.05) = 68 (%d)"
		% expected_xp)
	var applied := RewardsLib.apply(_outcome({
		"salvage_gold": 900, "xp": 65,
		"rep_deltas": {"portugal": 2, "spain": 2},
	}))
	_check(int(applied["gold"]) == 900,
		"apply() reports the salvage gold it added (%d)" % int(applied["gold"]))
	_check(GameState.gold == gold_before + 900,
		"apply() adds the salvage gold exactly (%d → %d)"
		% [gold_before, GameState.gold])
	_check(CharacterLib.current_xp() == xp_before + expected_xp,
		"apply() awards the battle XP exactly, ×(1 + level/20) (%d → %d)"
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
	_check(NpcFleetsLib.PIRACY_REPUTATION == BattleLib.NAVY_REP_PENALTY,
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


# --- 4b. Haul valuation (Phase 8: §4.8/§4.11.10) --------------------------

func _test_haul_valuation() -> void:
	_check(RewardsLib.HAUL_SKILL_DIVISOR == 400.0,
		"the haul divisor is the pinned 400 (§4.11.10)")
	_check(RewardsLib.HAUL_MULT_MIN == 1.0 and RewardsLib.HAUL_MULT_MAX == 1.5,
		"the haul multiplier clamps to [1.0, 1.5] (§4.11.10)")
	# The three pinned points: the two skills at 0 / 50 / 100 each —
	# sums 0 / 100 / 200 over the divisor → ×1.00 / ×1.25 / ×1.50 (the last
	# exactly at the clamp).
	var cases := [[0, 1.0], [50, 1.25], [100, 1.5]]
	for case in cases:
		_make_run()
		_set_haul_skills(int(case[0]), int(case[0]))
		var mult := RewardsLib.haul_multiplier()
		_check(absf(mult - float(case[1])) < 0.0001,
			"appraisal %d + negotiation %d → ×%.2f (got %.4f)"
			% [int(case[0]), int(case[0]), float(case[1]), mult])
	# The credited form floors once: 900 raw → 900 / 1125 / 1350.
	_make_run()
	_set_haul_skills(0, 0)
	_check(RewardsLib.haul_gold(900) == 900,
		"a ×1.00 haul credits the raw gold (900 → %d)" % RewardsLib.haul_gold(900))
	_set_haul_skills(50, 50)
	_check(RewardsLib.haul_gold(900) == 1125,
		"a ×1.25 haul floors once (900 → %d)" % RewardsLib.haul_gold(900))
	_set_haul_skills(100, 100)
	_check(RewardsLib.haul_gold(900) == 1350,
		"a ×1.50 haul floors once (900 → %d)" % RewardsLib.haul_gold(900))
	# apply() credits the salvage through the same multiplier (skills 50/50):
	_make_run()
	_set_haul_skills(50, 50)
	var gold_before := GameState.gold
	var applied := RewardsLib.apply(_outcome({"salvage_gold": 900}))
	_check(GameState.gold == gold_before + 1125 and int(applied["gold"]) == 1125,
		"apply() credits salvage_gold × haul_multiplier (%d → %d)"
		% [gold_before, GameState.gold])
	# It prices gold, never goods: a negative raw line stays at 0.
	_check(RewardsLib.haul_gold(-5) == 0, "a nonsensical raw haul credits 0")


# --- 4c. Battle XP multiplier (Phase 8: §4.8, 50-* §4.4) -------------------

func _test_battle_xp_multiplier() -> void:
	_check(RewardsLib.XP_LEVEL_DIVISOR == 20.0,
		"the XP level divisor is the pinned 20 (§4.11.10)")
	# The raw bases are unchanged (§4.11.10 kept: +10/neutralised, +5/round);
	# xp_for stays the raw engine-mirror formula.
	_check(RewardsLib.xp_for(1, 1) == 15, "the raw bases are unchanged (1,1 → 15)")
	# ×(1 + level/20) at the three pinned levels, floored once, on the level
	# held BEFORE the award (raw 65 → 68 / 97 / 130).
	var cases := [[1, 68], [10, 97], [20, 130]]
	for case in cases:
		_make_run()
		var level := int(case[0])
		CharacterLib.award_xp(0)  # no-op guard: the fixture starts at 0 XP
		var p: Dictionary = GameState.player
		p["xp"] = CharacterLib.xp_for_level(level)
		p["level"] = level
		GameState.player = p
		_check(CharacterLib.current_level() == level,
			"the fixture holds level %d (got %d)"
			% [level, CharacterLib.current_level()])
		_check(RewardsLib.battle_xp_for(65) == int(case[1]),
			"level %d credits floor(65 × (1 + %d/20)) = %d (got %d)"
			% [level, level, int(case[1]), RewardsLib.battle_xp_for(65)])
	# The multiplier belongs to battle rewards only (50-* §4.4): the sea-day
	# and profit paths call award_xp directly and are untouched.
	_make_run()
	CharacterLib.add_profit_xp(1000, 700, 10)
	_check(CharacterLib.current_xp() == 51,
		"the profit-XP path stays unscaled (10 × (1000 − 490) → floor(5100/100)"
		+ " = %d XP)" % CharacterLib.current_xp())


# --- 4d. Boarding morale (Phase 8: §4.8) -----------------------------------

func _test_boarding_morale() -> void:
	_make_run()
	GameState.morale = 70
	# The W3-C engine field exists; without a won boarding it is 0 and morale
	# never moves.
	var outcome := _outcome({"xp": 0, "morale_bonus": 5})
	var applied := RewardsLib.apply(outcome)
	_check(GameState.morale == 75,
		"a won boarding's morale_bonus +5 moves fleet morale (70 → %d)"
		% GameState.morale)
	_check(int(applied["morale"]) == 5,
		"apply() reports the morale it applied (%d)" % int(applied["morale"]))
	# Idempotent: the replay is a no-op under the same rewards_applied marker.
	var replay := RewardsLib.apply(outcome)
	_check(GameState.morale == 75 and int(replay["morale"]) == 0,
		"a replayed block cannot double the morale (70+5 stays %d)"
		% GameState.morale)
	_make_run()
	GameState.morale = 98
	var clamped := RewardsLib.apply(_outcome({"morale_bonus": 5}))
	_check(GameState.morale == 100,
		"the morale gain clamps at 100 (98 → %d)" % GameState.morale)
	_check(int(clamped["morale"]) == 2,
		"the clamped step is reported as applied (+2, not +5) (%d)"
		% int(clamped["morale"]))
	# No boarding, no bonus: morale_bonus 0 leaves morale untouched.
	_make_run()
	GameState.morale = 70
	RewardsLib.apply(_outcome({"morale_bonus": 0}))
	_check(GameState.morale == 70, "morale_bonus 0 leaves morale untouched")


# --- 4e. The capture officer gate (Phase 8: §4.11.7/§4.11.15) --------------

func _test_capture_gate() -> void:
	var prize := _ship("sloop", {"cargo": {"wine": 4}})

	# With an idle officer the prize joins (it needs a captain).
	_make_run()
	_make_officer("fx_cap_a", "")
	var joined := ResultLib.apply(_outcome({"captured_enemy": [prize]}),
		[], GameState.fleet)
	_check((joined["captured_ships"] as Array) == ["sloop"],
		"with an idle officer the captured hull joins the fleet (%s)"
		% str(joined["captured_ships"]))
	_check(GameState.fleet.size() == 2,
		"the prize is the fleet's second hull (%d)" % GameState.fleet.size())
	_check(str(joined["capture_gate_failed"]) == "",
		"a joined capture reports no failed gate (%s)"
		% str(joined["capture_gate_failed"]))

	# Employed but none idle (both in posts) → the loot-convert fallback.
	_make_run()
	_make_officer("fx_cap_b", "pilot")
	_make_officer("fx_cap_c", "gunner")
	GameState.fleet = [_ship("caravel", {"cannons": 4, "crew": 15})]
	var converted := ResultLib.apply(_outcome({"captured_enemy": [prize]}),
		[], GameState.fleet)
	_check((converted["scuttled_ships"] as Array) == ["sloop"],
		"with no idle officer the prize is loot-converted and scuttled (%s)"
		% str(converted["scuttled_ships"]))
	_check((converted["captured_ships"] as Array).is_empty(),
		"the fallback prize never joins (%s)" % str(converted["captured_ships"]))
	_check(str(converted["capture_gate_failed"]) == "no_idle_officer",
		"the report names the no-idle-officer gate (%s)"
		% str(converted["capture_gate_failed"]))
	_check(FleetLib.held("wine") == 4,
		"the fallback still moves the prize cargo to the hold (%d wine)"
		% FleetLib.held("wine"))

	# A full fleet names the fleet-full gate (the §4.11.7 first clause).
	_make_run()
	var full_fleet: Array = []
	for index in FleetLib.FLEET_MAX:
		full_fleet.append(_ship("sloop"))
	GameState.fleet = full_fleet
	var full := ResultLib.apply(_outcome({"captured_enemy": [prize]}),
		[], GameState.fleet)
	_check(str(full["capture_gate_failed"]) == "fleet_full",
		"with a full fleet the report names the fleet-full gate (%s)"
		% str(full["capture_gate_failed"]))
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"the full fleet stays at FLEET_MAX (%d)" % GameState.fleet.size())

	# The flagship-duel-lost marker (the captain `win` hook's input).
	_make_run()
	var flagship := _ship("caravel", {"cannons": 4, "crew": 15})
	GameState.fleet = [flagship, _ship("sloop")]
	var lost_flagship := ResultLib.apply(
		_outcome({"lost_player": [flagship]}), [], GameState.fleet)
	_check(bool(lost_flagship["flagship_duel_lost"]),
		"a lost flagship hull is reported to the captain `win` hook")
	_check(GameState.fleet.size() == 1
			and str(GameState.fleet[0]["ship_type_id"]) == "sloop",
		"the next ship becomes flagship (fleet[0], order preserved)")
	_make_run()
	GameState.fleet = [flagship, _ship("brigantine")]
	var lost_escort := ResultLib.apply(
		_outcome({"lost_player": [_ship("sloop", {"durability": 3})]}),
		[], GameState.fleet)
	_check(not bool(lost_escort["flagship_duel_lost"]),
		"an escort loss does not mark the flagship lost")


# --- 4f. The captain lifecycle hooks (Phase 8: §4.11.15) -------------------

func _test_captain_lifecycle() -> void:
	_make_run()
	GameState.day = 12
	GameState.captain_states = {}

	# Defeat: a victory outcome with a captain_id → the return queue at
	# day + 60, defeats + 1. The fleet was wiped (no hull joined, none
	# surrendered) → crushed → the tier drifts −1 (from the seeded 2).
	GameState.captain_states["cap_wiped"] = {
		"status": CaptainsLib.STATUS_ACTIVE, "return_day": 0, "tier_now": 2,
		"stance": 0, "familiarity": 0, "dossier_seen": false,
		"defeats": 0, "wins": 0,
	}
	# apply()'s return carries the lifecycle report under `captain_lifecycle`
	# (the §4.12.3 return shape) — every read below goes through it.
	var report: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": "cap_wiped", "result": "victory",
		"captured_ships": [], "surrendered_enemy": 0,
		"sunk_enemy": ["sloop", "sloop"],
	}))["captain_lifecycle"]
	var wiped_state := CaptainsLib.state("cap_wiped")
	_check(bool(report["defeat"]) and bool(report["crushed"]),
		"a wiped fleet's defeat reports crushed (%s)" % str(report))
	_check(int(wiped_state["return_day"]) == 72,
		"the defeat queues the captain's return at day + 60 (12 + 60 = %d)"
		% int(wiped_state["return_day"]))
	_check(int(wiped_state["defeats"]) == 1,
		"the defeat is booked on the captain's record (%d)"
		% int(wiped_state["defeats"]))
	_check(int(wiped_state["tier_now"]) == 1,
		"a crushed defeat drifts the tier −1 (2 → %d)" % int(wiped_state["tier_now"]))

	# Not crushed: a hull was captured into the fleet → no tier drift.
	GameState.captain_states["cap_spared"] = {
		"status": CaptainsLib.STATUS_ACTIVE, "return_day": 0, "tier_now": 2,
		"stance": 0, "familiarity": 0, "dossier_seen": false,
		"defeats": 0, "wins": 0,
	}
	var spared: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": "cap_spared", "result": "victory",
		"captured_ships": ["sloop"], "surrendered_enemy": 0,
	}))["captain_lifecycle"]
	_check(bool(spared["defeat"]) and not bool(spared["crushed"]),
		"a victory with a joined hull is not crushed (%s)" % str(spared))
	_check(int(CaptainsLib.state("cap_spared")["tier_now"]) == 2,
		"a non-crushed defeat leaves the tier (2 → %d)"
		% int(CaptainsLib.state("cap_spared")["tier_now"]))

	# Not crushed either: a surrendered hull (the §4.12.2 sub-tally).
	var surrendered: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": "cap_spared", "result": "victory",
		"captured_ships": [], "surrendered_enemy": 1,
	}))["captain_lifecycle"]
	_check(not bool(surrendered["crushed"]),
		"a surrendered hull keeps the defeat from being crushed")

	# Nemesis extra: stance ≤ −3 → the defeat also moves stance −2.
	var nemesis := "cap_grudge"
	CaptainsLib.adjust_stance(nemesis, -3)
	var grudge: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": nemesis, "result": "victory",
	}))["captain_lifecycle"]
	_check(bool(grudge["defeat"]) and int(grudge["nemesis_stance"]) == -5,
		"a nemesis defeat adds the pinned stance −2 (−3 → %d)"
		% int(grudge["nemesis_stance"]))
	_check(int(CaptainsLib.state(nemesis)["stance"]) == -5,
		"the stance state carries the nemesis extra (%d)"
		% int(CaptainsLib.state(nemesis)["stance"]))
	_check(CaptainsLib.is_nemesis(nemesis), "stance −5 reads as a nemesis")
	# The clamp: a nemesis already at the floor stays there.
	CaptainsLib.adjust_stance(nemesis, CaptainsLib.STANCE_NEMESIS_DEFEAT * 4)
	_check(int(CaptainsLib.state(nemesis)["stance"]) == -10,
		"the stance clamps at −10 (%d)" % int(CaptainsLib.state(nemesis)["stance"]))

	# Win: the flagship fell to the captain (BattleResult's report field) —
	# the captain beat the player's duel even though his fleet lost.
	var duelist := "cap_duelist"
	var win_report: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": duelist, "result": "victory",
		"flagship_duel_lost": true,
	}))["captain_lifecycle"]
	_check(bool(win_report["win"]) and bool(win_report["defeat"]),
		"a won battle with a lost flagship fires defeat AND win (%s)"
		% str(win_report))
	_check(int(CaptainsLib.state(duelist)["wins"]) == 1,
		"the captain's win is booked (%d)" % int(CaptainsLib.state(duelist)["wins"]))
	_check(int(CaptainsLib.state(duelist)["tier_now"]) == 2,
		"a win drifts the tier +1 (1 → %d)"
		% int(CaptainsLib.state(duelist)["tier_now"]))

	# No defeat on a retreat (the fleet stays, §4.10) and none on a player
	# defeat; the nemesis extra never fires without the defeat either.
	GameState.captain_states = {}
	var retreat: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": "cap_untouched", "result": "retreat",
		"flagship_duel_lost": true,
	}))["captain_lifecycle"]
	_check(not bool(retreat["defeat"]) and bool(retreat["win"]),
		"a retreat is not a defeat but a lost flagship is still a win (%s)"
		% str(retreat))
	_check(int(CaptainsLib.state("cap_untouched")["defeats"]) == 0,
		"no defeat is booked on a retreat")
	var player_lost: Dictionary = RewardsLib.apply(_outcome({
		"captain_id": "cap_untouched", "result": "defeat_captured",
	}))["captain_lifecycle"]
	_check(not bool(player_lost["defeat"]),
		"a player defeat does not defeat the enemy captain")

	# No captain id → the hooks no-op (legacy/successor fleets).
	var anonymous: Dictionary = RewardsLib.apply(
		_outcome({"result": "victory"}))["captain_lifecycle"]
	_check(str(anonymous["captain_id"]) == "" and not bool(anonymous["defeat"]),
		"an outcome without a captain_id fires nothing (%s)" % str(anonymous))

	# The hull-instance fallback: a W4-B ship instance carries captain_id
	# through the deep-copied captured_enemy list.
	var hull_captain := "cap_on_hull"
	var with_hull := _outcome({
		"result": "victory",
		"captured_enemy": [_ship("sloop", {"captain_id": hull_captain})],
	})
	var hull_report: Dictionary = RewardsLib.apply(with_hull)["captain_lifecycle"]
	_check(str(hull_report["captain_id"]) == hull_captain
			and bool(hull_report["defeat"]),
		"the captured hull's own captain_id drives the defeat hook (%s)"
		% str(hull_report))


# --- 4g. The piracy-fame extension hook (Phase 8: §4.11.10/§4.11.15) -------

func _test_piracy_attack() -> void:
	_make_run()
	GameState.fame = 40
	GameState.captain_states = {}
	var applied := RewardsLib.apply_piracy_attack("spain", "cap_victim")
	# 1. The unchanged rep funnel: −20 owner, +2 its two rivals.
	_check(int(applied["rep_deltas"]["spain"]) == -20,
		"the piracy hook keeps the −20 owner rep (%s)"
		% str(applied["rep_deltas"]))
	_check(int(CharacterLib.reputation("spain")) == -20,
		"spain's reputation moved −20 (%d)" % CharacterLib.reputation("spain"))
	_check(int(CharacterLib.reputation("portugal")) == 22
			and int(CharacterLib.reputation("italy")) == 2,
		"spain's two rivals gained +2 each (portugal %d, italy %d)"
		% [CharacterLib.reputation("portugal"), CharacterLib.reputation("italy")])
	# 2. The fame extension: −20 once.
	_check(GameState.fame == 20 and int(applied["fame"]) == -20,
		"the attack costs −20 fame (40 → %d, reported %d)"
		% [GameState.fame, int(applied["fame"])])
	# 3. The victim captain's grudge: STANCE_ATTACK_NONHOSTILE = −1.
	_check(int(CaptainsLib.STANCE_ATTACK_NONHOSTILE) == -1,
		"the pinned non-hostile attack stance is −1")
	_check(int(applied["stance"]) == -1
			and int(CaptainsLib.state("cap_victim")["stance"]) == -1,
		"the victim captain's stance drops −1 (%s)"
		% str(CaptainsLib.state("cap_victim")))
	# The fame floor: −20 at fame 5 clamps to 0 and reports the real step.
	GameState.fame = 5
	var floored := RewardsLib.apply_piracy_attack("portugal", "")
	_check(GameState.fame == 0 and int(floored["fame"]) == -5,
		"the fame penalty floors at 0 (5 → %d, reported %d)"
		% [GameState.fame, int(floored["fame"])])
	# Pirates have no nation: an empty nation id applies nothing.
	var pirate_case := RewardsLib.apply_piracy_attack("", "cap_victim")
	_check(int(pirate_case["fame"]) == 0
			and (pirate_case["rep_deltas"] as Dictionary).is_empty(),
		"an empty victim nation (a pirate) applies nothing (%s)"
		% str(pirate_case))


# --- 4h. The named-pirate drops on the v2 cards (Phase 7 flow, §4.11.13) ---

func _test_named_drops_canon() -> void:
	# The v2 named_pirates.json still keys the drop by captain id, and the
	# canon cards carry the same drop (Phase 8 correction 7).
	_check(DataLoader.named_pirates_list.size() == 4,
		"the v2 file carries the 4 named pirates (%d)"
		% DataLoader.named_pirates_list.size())
	for pirate in DataLoader.named_pirates_list:
		var pirate_id := str(pirate.get("id", ""))
		var drop_id := str(pirate.get("drop", ""))
		var card: Dictionary = DataLoader.captains.get(pirate_id, {}) \
			if DataLoader.captains is Dictionary else {}
		_check(not drop_id.is_empty(),
			"%s carries a drop on the v2 file" % pirate_id)
		_check(str(card.get("drop", "")) == drop_id,
			"%s's canon card carries the same drop (%s)"
			% [pirate_id, str(card.get("drop", ""))])
		# The grant fires through the captain-id keying into an empty slot.
		_make_run([_ship("caravel", {"cannons": 4, "crew": 15})])
		var outcome := _outcome({})
		var granted := RewardsLib.apply_named_drop(outcome, pirate_id)
		_check(granted == drop_id and str(outcome["drop_item"]) == drop_id,
			"%s's drop grants through the captain-id keying (%s)"
			% [pirate_id, granted])
		var item: Dictionary = DataLoader.equipment.get(drop_id, {}) \
			if DataLoader.equipment is Dictionary else {}
		var slot := str(item.get("slot", ""))
		var carried := ""
		if slot == "weapon" or slot == "armor":
			carried = str((GameState.player.get("equipment", {}) as Dictionary)
				.get(slot, ""))
		else:
			carried = str((GameState.fleet[0].get("equipment", {}) as Dictionary)
				.get(slot, ""))
		_check(carried == drop_id,
			"%s is equipped into its %s slot (%s)" % [drop_id, slot, carried])


# --- 5. Engine agreement (§4.12.2 vs the formulas) ------------------------

func _test_engine_agreement() -> void:
	var salvage_mismatches: Array[String] = []
	var xp_mismatches: Array[String] = []
	var search = [SAME_NATION_CONTACT, LISBON_CONTACT, TIE_CONTACT]
	for kind in ["pirate", "navy"]:
		for seed_offset in range(1, 4):
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
		"6 seeded battles: outcome.salvage_gold == BattleRewards.salvage_for("
		+ "sunk_enemy) (%d mismatches: %s)"
		% [salvage_mismatches.size(), str(salvage_mismatches.slice(0, 3))])
	_check(xp_mismatches.is_empty(),
		"6 seeded battles: outcome.xp == +10/neutralised + 5/round (%d mismatches: %s)"
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

	# Exactly the outcome block's numbers, once — the XP through the Phase-8
	# level multiplier (the fixture holds level 1 → ×1.05).
	var expected_xp := RewardsLib.battle_xp_for(int(outcome.get("xp", 0)))
	_check(GameState.gold == gold_before + int(outcome.get("salvage_gold", 0)),
		"gold rose by exactly the outcome salvage (%d + %d = %d)"
		% [gold_before, int(outcome.get("salvage_gold", 0)), GameState.gold])
	_check(CharacterLib.current_xp() == xp_before + expected_xp,
		"XP rose by exactly the outcome xp ×(1 + level/20) (%d + %d = %d)"
		% [xp_before, expected_xp, CharacterLib.current_xp()])
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
			and int((rewards as Dictionary).get("xp", -1)) == expected_xp,
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

	# One DataLoader-level map load serves the whole sweep: the S3 confirm
	# boots a world per locale and both boots read the same raster (the
	# decode itself is owned by §3, not a per-locale contract).
	var map = MapLoaderLib.new()
	if not map.load_map("res://data/maps/world.png", DataLoader.map_legend):
		leaks.append("S3 map failed to load (%s)" % map.last_error)
	DataLoader.map = map

	# S10 after-action dialog, from a real battle — fought once in `en`,
	# then the locale toggles on the open dialog (§6: re-translate, not
	# reload).
	_make_run([_ship("brigantine", {"cannons": 10, "crew": 20})])
	I18n.set_locale("en")
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
	for locale in ["en", "zh"]:
		var dialog_lines: Array = screen.after_action_lines()
		leaks.append_array(_labelled_leaks(dialog_lines, "S10/%s" % locale))
		if _joined(dialog_lines).strip_edges().is_empty():
			leaks.append("S10/%s rendered nothing" % locale)
		# The mid-dialog locale toggle must re-translate, not reload.
		leaks.append_array(_labelled_leaks(screen.log_lines(), "S10log/%s" % locale))
		if locale == "en":
			I18n.set_locale("zh")
			await get_tree().process_frame
	_check(screen.after_action_dialog().visible,
		"the after-action dialog survives the mid-dialog locale toggle")
	screen.queue_free()
	await get_tree().process_frame

	# S11 duel modal (full-rect anchored, so its size comes from the scene):
	# one instance serves both locales through the §6 re-bind.
	I18n.set_locale("en")
	var modal = DuelScene.instantiate()
	add_child(modal)
	await get_tree().process_frame
	modal.open_duel(DuelLib.preview({
		"player_base": 15, "defender_base": 10, "seed": 33,
		"attacker_name": "You", "defender_name": "Pirate captain",
		"ship_name": "Brigantine",
	}))
	await get_tree().process_frame
	for locale in ["en", "zh"]:
		leaks.append_array(_widget_leaks(modal, "S11/%s" % locale))
		if locale == "en":
			I18n.set_locale("zh")
			await get_tree().process_frame
	modal.close()
	modal.queue_free()
	await get_tree().process_frame

	# S3 encounter confirm (the navy attack warning) boots a world per locale.
	for locale in ["zh", "en"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		leaks.append_array(await _encounter_confirm_leaks(locale))

	# S9 `gameover.captured` (the Phase-2 reason, §4.12.5) is the terminal
	# screen of a lost last ship — it must name the reason, not a `<key>`.
	# One instance re-binds on the toggle (§6).
	I18n.set_locale("en")
	var scene = GameOverScene.instantiate()
	scene.route_to_title = false
	add_child(scene)
	await get_tree().process_frame
	scene.open_reason("captured")
	await get_tree().process_frame
	for locale in ["en", "zh"]:
		var reason_text: String = scene.reason_text()
		if reason_text.strip_edges().is_empty() or _contains_key_marker(reason_text):
			leaks.append("S9/%s reason='%s'" % [locale, reason_text])
		if not reason_text.contains(I18n.t_key("gameover.captured")):
			leaks.append("S9/%s reason omits gameover.captured (%s)"
				% [locale, reason_text])
		leaks.append_array(_widget_leaks(scene, "S9/%s" % locale))
		if locale == "en":
			I18n.set_locale("zh")
			await get_tree().process_frame
	scene.queue_free()
	await get_tree().process_frame

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
## the real world scene (the map fixture lives in `test_npc_fleets.gd`).
## `DataLoader.map` is loaded once by `_test_locale_completeness`.
func _encounter_confirm_leaks(locale: String) -> Array[String]:
	var leaks: Array[String] = []
	_make_run()
	GameState.set_world_tile(OPEN_CELL)
	# A §4.15 hunter fixture (the retired navy marker's successor): its
	# battle keeps kind = "navy" (docs/60-* §4.11.11.3) and the seeded
	# composition comes from the fleet's own stream at contact time.
	GameState.npc_fleets = [{
		"id": "fx_hunter_spain",
		"role": "hunter",
		"nation_id": "spain",
		"cell": {"x": OPEN_CELL.x + 1, "y": OPEN_CELL.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": "spain", "name_index": 0},
		"cooldown_until_day": 0,
		"seed": 1 * 1000003 + (OPEN_CELL.x + 1) * 7919 + OPEN_CELL.y * 104729,
		"dest_port_id": "",
		"dwell_until_day": 0,
		"anchor_cell": null,
		"target_fleet_id": "",
		"hunter_state": "",
		"loiter_until_day": 0,
		"home_port_id": "",
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
	GameState.npc_fleets = []
	await get_tree().process_frame
	return leaks


# --- Fixtures -------------------------------------------------------------


func _make_run(fleet: Array = []) -> void:
	GameState.locale = "en"
	GameState.day = 12
	GameState.gold = 3000
	GameState.morale = 70
	GameState.fame = 0
	GameState.current_port = null
	GameState.world = {"position": {"x": 30, "y": 40}, "clock_fraction": 0.0,
		"weather": "calm"}
	# The v9 Person block (docs/50-* §4.8): the two haul skills read 0, so the
	# Phase-7-era gold pins stay ×1.00 and the XP pins carry only the level
	# term (level 1 → ×1.05).
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {},
		"alloc_pending": 0,
		"xp": 0, "level": 1, "officers": [],
		"equipment": {"weapon": "", "armor": ""},
		"reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0,
			"ottoman": 0, "italy": 0},
	}
	GameState.officer_states = {}
	GameState.captain_states = {}
	GameState.fleet = fleet.duplicate(true) if not fleet.is_empty() \
		else [_ship("caravel", {"cannons": 4, "crew": 15})]
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	if "pending_encounter" in GameState:
		GameState.set("pending_encounter", null)


## An employed officer fixture: the roster row plus the §4.8 officer_states
## entry at `post_id` ("" = the idle bench the capture gate queries).
func _make_officer(officer_id: String, post_id: String) -> void:
	var officers: Array = GameState.player.get("officers", [])
	officers.append(officer_id)
	GameState.player["officers"] = officers
	GameState.officer_states[officer_id] = {
		"loyalty": 50, "sea_days": 0, "post_id": post_id, "ship_id": "",
		"talk_cd_day": 0, "gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0,
	}


## Sets the player's own appraisal/negotiation (the haul-valuation inputs;
## no officer post maps to either skill, §4.5.3).
func _set_haul_skills(appraisal: int, negotiation: int) -> void:
	var skills: Dictionary = GameState.player.get("skills", {})
	skills["appraisal"] = appraisal
	skills["negotiation"] = negotiation
	GameState.player["skills"] = skills


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


## A §4.12.2 outcome block skeleton with `fields` merged over it (the W3-C
## `morale_bonus` field included — the engine reports it on every block).
func _outcome(fields: Dictionary) -> Dictionary:
	var outcome := {
		"result": "victory", "rounds": 6, "kind": "pirate", "nation_id": "",
		"encounter_id": "", "contact": {"x": 30, "y": 40},
		"sunk_enemy": [], "captured_enemy": [], "surrendered_enemy": 0,
		"sunk_player": [], "lost_player": [],
		"salvage_gold": 0, "xp": 0, "rep_deltas": {},
		"morale_bonus": 0,
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
