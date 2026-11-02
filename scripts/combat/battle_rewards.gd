class_name BattleRewards
extends RefCounted
## Battle-end economy effects (docs/60-COMBAT.md §4.11.10, §4.12.2, §4.12.3;
## owner: task G). Step **3** of the §4.12.4 battle-end sequence.
##
## What this module is: the one place that turns a finished battle's
## pre-computed outcome block into player state. `BattleSim` already did the
## bookkeeping and never touches `GameState` (§4.12.1); `BattleResult` (task C)
## already moved hulls in and out of the fleet; this module touches **only**
## `GameState.gold`, `player.xp`, `player.reputation`, `GameState.morale` and
## the captain lifecycle via `scripts/world/captains.gd` (§4.12.4).
##
## The §4.11.10 numbers live here as the canonical formulas:
##
##   * **Salvage gold** — `Σ floor(ShipType.base_price × 0.05)` over the ships
##     the player *sank* ([method salvage_for]). Captured/surrendered hulls pay
##     nothing: their value is the hull and the hold, not salvage. **Phase 8:**
##     the credited gold gains the haul-valuation multiplier (below).
##   * **Battle XP** — `+10` per enemy ship neutralised + `+5` per round the
##     battle lasted ([method xp_for]). A retreat awards nothing at all (§4.10),
##     which the engine already expresses by pre-computing `xp = 0`.
##     **Phase 8:** the credited total is ×(1 + level/20), floored once.
##   * **Reputation** — pirates defeated (any outcome except retreat) credit
##     `+2` with each of the two nearest ports' nations
##     ([method nearest_nations], Chebyshev from the contact tile, ties by port
##     id, a nation credited once). The navy `−20` is **not** here and never
##     appears in `rep_deltas`: §4.11.10 charges it once at battle start by the
##     S3 funnel (`world_map.gd` `_open_encounter`; the retired Phase-2
##     `encounters.gd` funnel it replaces), not per ship and not at battle end.
##     [method apply] therefore has no negative consequence to charge, and
##     applying an outcome twice cannot repeat one.
##   * **Boarding morale** — the §4.8 `morale_bonus` the engine reports in the
##     outcome (+5 after a won boarding duel); the aftermath application below
##     is its one consumer (§4.12.4 keeps the engine `GameState`-free).
##
## **Idempotency.** [method apply] marks the outcome dictionary it was handed
## with `rewards_applied: true` and returns early on every later call for the
## same block. The screen calls it exactly once (§4.12.4), but a test (or a
## retried end-of-battle sequence) may call it twice and must not double-pay.
##
## Constants are read from [BattleSim] rather than re-typed, so the engine's
## outcome block and this module can never drift apart on a number; the
## engine's own private helpers compute the same formulas, and
## `tools/test_battle_economy.gd` asserts outcome == formula for several hull
## sets and round counts.
##
## Layering (docs/90-ARCHITECTURE.md §4): pure static logic, no node
## references, no signals. `EventBus.gold_changed` is emitted by
## `GameState.add_gold()` and nothing else is broadcast here.
##
## Phase 8 (2026-11-02, W4-C) adds four seams, all on the Person model:
##
##   * **Haul valuation** (§4.8/§4.11.10): every haul gold this module credits
##     is ×[method haul_multiplier] — `1 + (appraisal + negotiation) / 400`,
##     clamped [×1.0, ×1.5] on the two `Skills.effective_skill` values. The
##     same helper prices the §4.11.11.2 loot-gold lines and the treasure-fleet
##     loot gold (their credit points call [method haul_gold] so the one
##     formula cannot drift).
##   * **Battle XP ×(1 + level/20)** (§4.8/§4.11.10): [method apply] scales the
##     outcome's pre-computed XP once, floored, on the player's level
##     (`Character.current_level()`), on top of the unchanged per-kill/round
##     bases ([method xp_for] stays the raw engine formula).
##   * **Boarding morale** (§4.8): the outcome's `morale_bonus` (the W3-C
##     engine field, +5 after a won boarding duel) moves `GameState.morale`,
##     clamped 0–100, exactly once — under the same `rewards_applied`
##     idempotency marker as gold/XP/rep.
##   * **Captain lifecycle hooks** (§4.11.15, `scripts/world/captains.gd`):
##     [method apply_captain_lifecycle] turns an outcome that carries a
##     `captain_id` into `Captains.defeat` (victory; `crushed` = the fleet was
##     wiped), the nemesis stance −2 extra, and `Captains.win` (the flagship
##     fell to that captain). [method apply_piracy_attack] is the §4.11.10
##     piracy-fame extension for the single battle-start funnel.

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const FameLib := preload("res://scripts/player/fame.gd")

## Slot A's captain module, loaded through the §4.12.3 guarded convention (the
## W4 merge order puts this file in worktrees where `captains.gd` does not
## exist yet; a missing module disables the lifecycle hooks, never the battle).
const CAPTAINS_LIB_PATH := "res://scripts/world/captains.gd"

## §4.11.10 rewards pin, single source of truth: `battle_sim.gd` §4.11/§4.12.
const SALVAGE_FRACTION := BattleSimLib.SALVAGE_FRACTION
const XP_PER_ENEMY_NEUTRALIZED := BattleSimLib.XP_PER_ENEMY_NEUTRALIZED
const XP_PER_ROUND := BattleSimLib.XP_PER_ROUND
const PIRATE_REP_GAIN := BattleSimLib.PIRATE_REP_GAIN
const NEAREST_PORT_COUNT := BattleSimLib.NEAREST_PORT_COUNT
const RESULT_RETREAT := BattleSimLib.RESULT_RETREAT

## --- Phase 8 numbers (each doc-pinned, §4.8/§4.11.10/§4.11.15) -------------

## Haul valuation: `1 + (appraisal + negotiation) / 400`, clamped [1.0, 1.5]
## on the player's two `Skills.effective_skill` values (§4.11.10).
const HAUL_SKILL_DIVISOR := 400.0
const HAUL_MULT_MIN := 1.0
const HAUL_MULT_MAX := 1.5
## Battle XP ×(1 + level / 20), floored once (§4.11.10); `50-*` §4.4 pins the
## multiplier's ownership to battle rewards (never the trade/sea-day paths).
const XP_LEVEL_DIVISOR := 20.0
## §4.11.10 piracy fame extension: −20 fame, once, at battle start, by the
## same single funnel as the rep −20 (never at battle end, never per ship).
const PIRACY_FAME_PENALTY := -20

## The outcome keys the lifecycle hooks consume. `captain_id` is threaded by
## the caller from the W4-B battle config (the sim's raw block does not carry
## it — §4.12.2 lists no such field); `flagship_duel_lost` is BattleResult's
## report field (the §4.11.7 player-loses branch against fleet[0]). A
## captured enemy hull that itself carries `captain_id` (a W4-B ship instance)
## is the fallback when the outcome key is absent.
const CAPTAIN_ID_KEY := "captain_id"
const FLAGSHIP_DUEL_LOST_KEY := "flagship_duel_lost"

## The two lists §4.12.2 uses for "neutralised" tallies: a captured hull and a
## hull whose captain surrendered both count, and `surrendered_enemy` is only a
## wording sub-tally (never add it, §4.12.2).
const SUNK_ENEMY_KEY := "sunk_enemy"
const CAPTURED_ENEMY_KEY := "captured_enemy"

## The §4.12.3 return shape's keys, in wireframe order.
const GOLD_KEY := "gold"
const XP_KEY := "xp"
const REP_DELTAS_KEY := "rep_deltas"
const MORALE_KEY := "morale"
const CAPTAIN_LIFECYCLE_KEY := "captain_lifecycle"
const DROP_ITEM_KEY := "drop_item"
const DROP_SOLD_BACK_KEY := "drop_sold_back"


# --- Application seam (§4.12.3) --------------------------------------------

## Applies a finished battle's economy effects and returns what was applied.
##
## `outcome` is the §4.12.2 block (after `BattleResult.apply`, so fleet effects
## have already happened — the lifecycle hooks below read BattleResult's report
## fields). Read for `salvage_gold`, `xp`, `rep_deltas`, `morale_bonus`,
## `captain_id` and `flagship_duel_lost`; the only write is the idempotency
## marker `rewards_applied` (§4.12.3: "the screen may call it once, tests may
## call twice").
##
## Returns `{gold, xp, rep_deltas, morale, captain_lifecycle}` — **the state
## change actually applied**:
##
##   `gold`        the gold `GameState.add_gold()` added — the §4.11.10 haul
##                 valuation `floor(salvage_gold × haul_multiplier())` (Phase 8)
##   `xp`          the XP `Character.award_xp()` awarded — the §4.11.10 total
##                 `floor(outcome.xp × (1 + level/20))` (Phase 8; the outcome's
##                 `xp` field stays the raw engine number)
##   `rep_deltas`  per nation, the reputation points the call moved (a +2 at
##                 99 reputation reports +1, because `Character.add_reputation`
##                 clamps to ±100 — §4.6). The *requested* deltas stay in
##                 `outcome.rep_deltas`, which is what the after-action dialog
##                 prints (§4.12.2).
##   `morale`      the morale points `GameState.morale` moved for the outcome's
##                 `morale_bonus` (§4.8 boarding-victory +5; clamped 0–100, so
##                 a gain at 98 reports +2)
##   `captain_lifecycle`  [method apply_captain_lifecycle]'s report (the
##                 §4.11.15 hooks; all-false/zero without a `captain_id`)
##
## An already-applied block returns all-zeroes. Reputation is clamped to
## −100…+100 by `Character.add_reputation`; a navy `−20` is never present
## (§4.11.10).
static func apply(outcome: Dictionary) -> Dictionary:
	var applied := {
		GOLD_KEY: 0, XP_KEY: 0, REP_DELTAS_KEY: {},
		MORALE_KEY: 0, CAPTAIN_LIFECYCLE_KEY: {},
	}
	if not (outcome is Dictionary) or outcome.is_empty():
		return applied
	# Defensive: the outcome block may arrive already settled (§4.12.3).
	if bool(outcome.get("rewards_applied", false)):
		return applied
	var gold := haul_gold(maxi(int(outcome.get("salvage_gold", 0)), 0))
	# Mark first: an empty run still pays the gold, and a retried call must not
	# pay it twice even though the XP could not be booked yet.
	outcome["rewards_applied"] = true
	if gold > 0:
		GameState.add_gold(gold)
	applied[GOLD_KEY] = gold
	var player: Dictionary = GameState.player
	if not (player is Dictionary) or player.is_empty():
		# Awarding XP/reputation would log an error inside `Character` and lose
		# the value; gold is run-independent state, so only it is applied.
		push_warning("BattleRewards.apply: GameState.player is empty; XP and "
			+ "reputation were not applied")
		return applied
	var deltas := _apply_reputation(outcome.get("rep_deltas", {}))
	# §4.8 boarding-victory morale: the engine reported `morale_bonus` (+5
	# after a won boarding duel) and never touches `GameState` (§4.12.1) — this
	# aftermath application is its one consumer.
	var morale_bonus := maxi(int(outcome.get("morale_bonus", 0)), 0)
	var morale_before := int(GameState.morale)
	if morale_bonus > 0:
		GameState.morale = clampi(morale_before + morale_bonus, 0, 100)
	applied[MORALE_KEY] = int(GameState.morale) - morale_before
	# §4.11.10 Phase 8: the battle XP total ×(1 + level/20), floored once, on
	# the level held *before* the award.
	var xp := battle_xp_for(maxi(int(outcome.get("xp", 0)), 0))
	if xp > 0:
		CharacterLib.award_xp(xp)
	applied[XP_KEY] = xp
	applied[REP_DELTAS_KEY] = deltas
	applied[CAPTAIN_LIFECYCLE_KEY] = apply_captain_lifecycle(outcome)
	return applied


## The §4.11.10 haul-valuation multiplier (Phase 8):
## `clamp(1 + (appraisal + negotiation) / 400, 1.0, 1.5)` on the player's two
## skills, each read as `Skills.effective_skill` (the player value plus the one
## in-post officer's contribution, §4.5.3 — no post maps to either haul skill,
## so in practice the player value alone decides). Every battle-haul gold
## valuation is credited through this: the salvage gold, the §4.11.11.2
## loot-gold lines and the treasure-fleet loot gold. It prices **gold** — it
## never re-weights goods (captured cargo still moves into the hold, §4.11.7).
static func haul_multiplier() -> float:
	var appraisal := SkillsLib.effective_skill("appraisal")
	var negotiation := SkillsLib.effective_skill("negotiation")
	return clampf(1.0 + (appraisal + negotiation) / HAUL_SKILL_DIVISOR,
		HAUL_MULT_MIN, HAUL_MULT_MAX)


## `floor(raw_gold × [method haul_multiplier])` — the credited form of a haul
## gold line. The credit points for the §4.11.11.2 loot-gold lines and the
## treasure-fleet loot gold call this (single implementation, §4.11.11.2).
static func haul_gold(raw_gold: int) -> int:
	return int(floor(float(maxi(int(raw_gold), 0)) * haul_multiplier()))


## The §4.11.10 battle-XP credit (Phase 8): `floor(raw_xp × (1 + level / 20))`
## on `Character.current_level()` (the level held before the award). The raw
## bases — +10 per neutralised hull, +5 per round, 0 on retreat — stay in the
## engine's outcome block and in [method xp_for]; this is the one scaling.
static func battle_xp_for(raw_xp: int) -> int:
	var level := float(CharacterLib.current_level())
	return int(floor(float(maxi(int(raw_xp), 0)) * (1.0 + level / XP_LEVEL_DIVISOR)))


## The §4.11.15 captain lifecycle hooks (Phase 8, W4-C). Fired from
## [method apply] — the §4.12.4 step-3 seam, after `BattleResult.apply` has
## reported which hulls joined and whether the flagship fell. A no-op without
## a `captain_id` (legacy/successor fleets) or when slot A's module is absent
## (the guarded-load convention above); the world-side call sites are W5/W6's.
##
##   * **Defeat** — `result == "victory"` (§4.11.9: the whole enemy fleet is
##     sunk/captured/surrendered; a `retreat` keeps the fleet, §4.10, so it is
##     not a defeat) → `Captains.defeat(captain_id, GameState.day, crushed)`.
##     **`crushed` pin: the fleet was wiped** — no enemy hull joined the player
##     fleet (`captured_ships` empty, so every hull was sunk by cannon/ram or
##     scuttled by the §4.11.7 loot-convert fallback) and none surrendered
##     (`surrendered_enemy == 0`).
##   * **Nemesis extra** — when `Captains.is_nemesis(captain_id)`, also
##     `adjust_stance(captain_id, STANCE_NEMESIS_DEFEAT)` (−2; §4.11.15).
##   * **Win** — the outcome reports `flagship_duel_lost` (BattleResult's
##     §4.11.7 player-loses marker: the boarded-from hull was `fleet[0]`) →
##     `Captains.win(captain_id, GameState.day)`: the captain beat the player's
##     own duel even if his fleet still lost the battle.
##
## Returns the report `{captain_id, defeat, crushed, win, nemesis_stance}`
## (`nemesis_stance` = the stance value the nemesis extra moved to, 0 when it
## did not fire).
static func apply_captain_lifecycle(outcome: Dictionary) -> Dictionary:
	var report := {
		"captain_id": "", "defeat": false, "crushed": false,
		"win": false, "nemesis_stance": 0,
	}
	if not (outcome is Dictionary) or outcome.is_empty():
		return report
	var lib: Variant = _captains_lib()
	if lib == null:
		return report
	var captain_id := outcome_captain_id(outcome)
	if captain_id.is_empty():
		return report
	report["captain_id"] = captain_id
	if str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY:
		var crushed := crushed_victory(outcome)
		lib.call("defeat", captain_id, int(GameState.day), crushed)
		report["defeat"] = true
		report["crushed"] = crushed
		if bool(lib.call("is_nemesis", captain_id)):
			var stance := int(lib.call("adjust_stance", captain_id,
				int(lib.get("STANCE_NEMESIS_DEFEAT"))))
			report["nemesis_stance"] = stance
	if bool(outcome.get(FLAGSHIP_DUEL_LOST_KEY, false)):
		lib.call("win", captain_id, int(GameState.day))
		report["win"] = true
	return report


## The `captain_id` an outcome carries: the caller-threaded W4-B battle-config
## id, else the first captured enemy hull's own `captain_id` (a W4-B ship
## instance rides the deep-copied `captured_enemy` list). "" when neither is
## present — the legacy/successor fleets the hooks must skip.
static func outcome_captain_id(outcome: Dictionary) -> String:
	var threaded := str(outcome.get(CAPTAIN_ID_KEY, ""))
	if not threaded.is_empty():
		return threaded
	var captured: Array = outcome.get("captured_enemy", []) \
		if outcome.get("captured_enemy", []) is Array else []
	for hull in captured:
		if hull is Dictionary and not str((hull as Dictionary).get(CAPTAIN_ID_KEY, "")).is_empty():
			return str((hull as Dictionary).get(CAPTAIN_ID_KEY, ""))
	return ""


## The `crushed` pin for a victory outcome: the fleet was wiped — every hull
## sunk by the player or scuttled by the loot-convert fallback, none captured
## into the fleet (`captured_ships`, BattleResult's report) and none
## surrendered (`surrendered_enemy`, the §4.12.2 sub-tally).
static func crushed_victory(outcome: Dictionary) -> bool:
	var joined: Array = outcome.get("captured_ships", []) \
		if outcome.get("captured_ships", []) is Array else []
	return joined.is_empty() and int(outcome.get("surrendered_enemy", 0)) == 0


## `scripts/world/captains.gd` through the §4.12.3 guarded convention: the
## script when it exists **and** exposes the contract, else null (the hooks
## no-op; no warning spam — the module's absence is a merge-order state, and
## the Phase-1 `apply_fleet_guard` convention is warning-once per caller path).
static func _captains_lib() -> Variant:
	if not ResourceLoader.exists(CAPTAINS_LIB_PATH):
		return null
	var lib = load(CAPTAINS_LIB_PATH)
	if lib == null or not lib.has_method("defeat") \
			or not lib.has_method("adjust_stance") \
			or not lib.has_method("is_nemesis"):
		return null
	return lib


## The §4.11.10 piracy-fame extension, exposed for the **single battle-start
## funnel** (world_map's `_charge_piracy` successor — the W5/W6 call site; this
## module never fires it at battle end and never per ship). The caller owns the
## §4.11.15 preconditions: the fleet was non-hostile, its role is not `pirate`
## (pirates have no nation and gain no rivals), and coasters are unreachable
## (no attack verb).
##
## Applies, in one call:
##   1. the existing `Bounty.apply_piracy` charge — rep −20 with the owner,
##      +2 with each of its two `data/nations.json#rivals`, then the bounty
##      threshold re-evaluation (unchanged, `70-*` §4.5/§4.9.5);
##   2. the fame −20 extension — `GameState.fame` floored at 0 (the ladder
##      never reads a negative), `fame_changed` announced;
##   3. the victim captain's grudge — `Captains.adjust_stance(
##      victim_captain_id, STANCE_ATTACK_NONHOSTILE)` (−1, clamped ±10).
##
## Returns `{rep_deltas, fame, stance}` — the deltas actually applied (`fame`
## is the real step, so a clamp at 0 reports −5 from a fame of 5; `stance` is
## the value the victim's stance moved to, 0 when no captain id was given).
static func apply_piracy_attack(victim_nation_id: String,
		victim_captain_id: String = "") -> Dictionary:
	var applied := {"rep_deltas": {}, "fame": 0, "stance": 0}
	if victim_nation_id.is_empty():
		return applied
	# 1. The unchanged rep funnel (the −20 owner, +2 rivals, bounty re-check).
	applied["rep_deltas"] = BountyLib.apply_piracy(victim_nation_id)
	# 2. The Phase-8 fame extension: −20 once, floored at 0.
	var before := FameLib.value()
	GameState.fame = maxi(0, before + PIRACY_FAME_PENALTY)
	applied["fame"] = int(GameState.fame) - before
	if applied["fame"] != 0 and EventBus.has_signal("fame_changed"):
		EventBus.fame_changed.emit(int(GameState.fame))
	# 3. The victim captain remembers (§4.11.15). Skipped without a captain id
	# (legacy/successor fleets) or when slot A's module has not merged.
	if not victim_captain_id.is_empty():
		var lib: Variant = _captains_lib()
		if lib != null:
			applied["stance"] = int(lib.call("adjust_stance", victim_captain_id,
				int(lib.get("STANCE_ATTACK_NONHOSTILE"))))
	return applied


## Applies every non-zero `rep_deltas` entry through
## `Character.add_reputation` and returns the deltas **as applied** (before →
## after, so a clamp at ±100 shows its real step). An empty nation id is
## skipped (a pirate outcome carries `""`; §4.11.10 credits ports' nations).
static func _apply_reputation(value) -> Dictionary:
	var applied := {}
	if not (value is Dictionary):
		return applied
	for nation_key in (value as Dictionary):
		var nation_id := str(nation_key)
		var delta := int((value as Dictionary).get(nation_key, 0))
		if nation_id.is_empty() or delta == 0:
			continue
		var before := CharacterLib.reputation(nation_id)
		var after := CharacterLib.add_reputation(nation_id, delta)
		if after != before:
			applied[nation_id] = after - before
	return applied


# --- The §4.11.10 formulas -------------------------------------------------

## The Phase-7 rare-drop flow (§4.11.13, keyed by the sunk/captured captain
## id): match `captain_named_id` against `data/named_pirates.json`, credit the
## match's `drop` item, and equip it through the standing replace rule
## (§4.11.12) — `weapon`/`armor` fit `GameState.player.equipment`,
## `figurehead`/`sail` fit the flagship (fleet index 0); an occupied slot
## sells the displaced item back at `floor(price × 0.5)` in the same grant.
## Writes `drop_item` (+ `drop_sold_back` when a displaced item sold) into
## `outcome` and returns the granted item id ("" when nothing matched or the
## run/flagship cannot carry it — an unnamed or successor captain drops
## nothing). Rare items are never tier-gated (never purchasable at all).
static func apply_named_drop(outcome: Dictionary, captain_named_id: String) -> String:
	if not (outcome is Dictionary) or outcome.is_empty():
		return ""
	var named_id := str(captain_named_id)
	if named_id.is_empty():
		return ""
	var pirate: Dictionary = DataLoader.named_pirates.get(named_id, {}) \
		if DataLoader.named_pirates is Dictionary else {}
	var item_id := str((pirate as Dictionary).get("drop", ""))
	if item_id.is_empty():
		return ""
	var item: Dictionary = DataLoader.equipment.get(item_id, {}) \
		if DataLoader.equipment is Dictionary else {}
	if item.is_empty():
		push_warning("BattleRewards.apply_named_drop: unknown drop item %s" % item_id)
		return ""
	var slot := str((item as Dictionary).get("slot", ""))
	var price := int((item as Dictionary).get("price", 0))
	var occupied := ""
	if slot == "weapon" or slot == "armor":
		var player: Dictionary = GameState.player
		if player.is_empty():
			return ""
		var equipment: Dictionary = player.get("equipment", {})
		if not (equipment is Dictionary):
			equipment = {}
		occupied = str(equipment.get(slot, ""))
		equipment[slot] = item_id
		player["equipment"] = equipment  # assign back: .get() orphans a fresh {}
	else:
		# `figurehead`/`sail` fit the flagship (fleet index 0, §4.11.2).
		var fleet: Array = GameState.fleet
		if fleet.is_empty() or not (fleet[0] is Dictionary):
			return ""
		var flagship: Dictionary = fleet[0]
		var ship_equipment: Dictionary = flagship.get("equipment", {})
		if not (ship_equipment is Dictionary):
			ship_equipment = {}
		occupied = str(ship_equipment.get(slot, ""))
		ship_equipment[slot] = item_id
		flagship["equipment"] = ship_equipment
	var sold_back := ""
	if not occupied.is_empty() and occupied != item_id:
		var displaced: Dictionary = DataLoader.equipment.get(occupied, {}) \
			if DataLoader.equipment is Dictionary else {}
		if not displaced.is_empty():
			sold_back = occupied
			GameState.add_gold(int(floor(float(int(displaced.get("price", 0))) * 0.5)))
	outcome[DROP_ITEM_KEY] = item_id
	outcome[DROP_SOLD_BACK_KEY] = sold_back
	return item_id


## `Σ floor(base_price × 0.05)` over the `ship_type_id`s of ships the player
## sank this battle. Unknown ids contribute `floor(0 × 0.05) = 0` rather than
## crashing a battle end on a corrupted save.
static func salvage_for(sunk_ship_type_ids: Array) -> int:
	var total := 0
	if not (sunk_ship_type_ids is Array):
		return total
	for value in sunk_ship_type_ids:
		var ship_type: Dictionary = DataLoader.get_ship_type(str(value))
		total += int(floor(float(ship_type.get("base_price", 0)) * SALVAGE_FRACTION))
	return total


## `neutralised × 10 + rounds × 5` (§4.11.10). `rounds` is the §4.12.2
## `rounds` field; the engine floors it at 1 for a battle that lasted a single
## round. A retreat is worth 0 XP — the engine pre-computes `xp = 0` for
## `result == "retreat"` (§4.10), so callers must apply the block's `xp`, not
## this formula, when the outcome may be a retreat.
static func xp_for(neutralised: int, rounds: int) -> int:
	return maxi(neutralised, 0) * XP_PER_ENEMY_NEUTRALIZED \
		+ maxi(rounds, 0) * XP_PER_ROUND


## How many enemy ships the block counts as neutralised: sunk + captured
## (`surrendered_enemy` is a wording sub-tally of `captured_enemy`, never an
## addition — §4.12.2).
static func neutralised_for(outcome: Dictionary) -> int:
	if not (outcome is Dictionary):
		return 0
	return _list_size(outcome.get(SUNK_ENEMY_KEY, [])) \
		+ _list_size(outcome.get(CAPTURED_ENEMY_KEY, []))


static func _list_size(value) -> int:
	return (value as Array).size() if value is Array else 0


## Chebyshev distance with longitude wrap (`20-*` §4.1), mirroring
## `BattleSim._world_chebyshev` exactly — `tools/test_battle_economy.gd` asserts
## the two agree.
static func _world_chebyshev(a: Vector2i, b: Vector2i) -> int:
	var grid: Dictionary = DataLoader.map_legend.get("grid", {})
	var width := int(grid.get("width", 0))
	if width <= 0:
		width = 4320
	var dx := absi(a.x - b.x) % width
	return maxi(mini(dx, width - dx), absi(a.y - b.y))


# --- Nearest ports (§4.11.10) ----------------------------------------------

## Nations of the two nearest ports to `contact`, Chebyshev distance, ties by
## port id ascending, each nation credited once.
##
## **Two ports are selected first, then their nations are credited** — so a
## contact whose two nearest ports belong to the same nation credits that
## nation once and returns a single-entry list; it does not reach for a third
## port. That is the only reading under which §4.11.10's "A nation appearing
## twice is credited once" describes an observable case. This mirrors
## `BattleSim._nearest_port_nations()` exactly — the engine uses the list for
## `rep_deltas` and `tools/test_battle_economy.gd` asserts the two agree.
static func nearest_nations(contact: Vector2i) -> Array[String]:
	var ports: Array = []
	DataLoader.ensure_map()
	for port in DataLoader.ports_list:
		if not (port is Dictionary):
			continue
		# Ports carry lat/lon only; the berth tile is derived (§10-* §6.1).
		var position: Vector2i = DataLoader.port_cell(str(port.get("id", "")))
		if position.x < 0:
			continue
		ports.append({
			"id": str(port.get("id", "")),
			"nation_id": str(port.get("nation_id", "")),
			"distance": _world_chebyshev(contact, position),
		})
	ports.sort_custom(func(a, b) -> bool:
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return str(a["id"]) < str(b["id"]))
	var nations: Array[String] = []
	for index in mini(ports.size(), NEAREST_PORT_COUNT):
		var nation_id := str((ports[index] as Dictionary)["nation_id"])
		if nation_id.is_empty() or nation_id in nations:
			continue
		nations.append(nation_id)
	return nations
