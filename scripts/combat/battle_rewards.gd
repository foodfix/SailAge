class_name BattleRewards
extends RefCounted
## Battle-end economy effects (docs/60-COMBAT.md §4.11.10, §4.12.2, §4.12.3;
## owner: task G). Step **3** of the §4.12.4 battle-end sequence.
##
## What this module is: the one place that turns a finished battle's
## pre-computed outcome block into player state. `BattleSim` already did the
## bookkeeping and never touches `GameState` (§4.12.1); `BattleResult` (task C)
## already moved hulls in and out of the fleet; this module touches **only**
## `GameState.gold`, `player.xp` and `player.reputation` (§4.12.4).
##
## The three §4.11.10 numbers live here as the canonical formulas:
##
##   * **Salvage gold** — `Σ floor(ShipType.base_price × 0.05)` over the ships
##     the player *sank* ([method salvage_for]). Captured/surrendered hulls pay
##     nothing: their value is the hull and the hold, not salvage.
##   * **Battle XP** — `+10` per enemy ship neutralised + `+5` per round the
##     battle lasted ([method xp_for]). A retreat awards nothing at all (§4.10),
##     which the engine already expresses by pre-computing `xp = 0`.
##   * **Reputation** — pirates defeated (any outcome except retreat) credit
##     `+2` with each of the two nearest ports' nations
##     ([method nearest_nations], Chebyshev from the contact tile, ties by port
##     id, a nation credited once). The navy `−20` is **not** here and never
##     appears in `rep_deltas`: §4.11.10 charges it once at battle start
##     charged at battle start by the S3 funnel (`world_map.gd` `_open_encounter`;\n##     the retired Phase-2 `encounters.gd` funnel it replaces), not per ship and not at battle end.
##     [method apply] therefore has no negative consequence to charge, and
##     applying an outcome twice cannot repeat one.
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

const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

## §4.11.10 rewards pin, single source of truth: `battle_sim.gd` §4.11/§4.12.
const SALVAGE_FRACTION := BattleSimLib.SALVAGE_FRACTION
const XP_PER_ENEMY_NEUTRALIZED := BattleSimLib.XP_PER_ENEMY_NEUTRALIZED
const XP_PER_ROUND := BattleSimLib.XP_PER_ROUND
const PIRATE_REP_GAIN := BattleSimLib.PIRATE_REP_GAIN
const NEAREST_PORT_COUNT := BattleSimLib.NEAREST_PORT_COUNT
const RESULT_RETREAT := BattleSimLib.RESULT_RETREAT

## The two lists §4.12.2 uses for "neutralised" tallies: a captured hull and a
## hull whose captain surrendered both count, and `surrendered_enemy` is only a
## wording sub-tally (never add it, §4.12.2).
const SUNK_ENEMY_KEY := "sunk_enemy"
const CAPTURED_ENEMY_KEY := "captured_enemy"

## The §4.12.3 return shape's keys, in wireframe order.
const GOLD_KEY := "gold"
const XP_KEY := "xp"
const REP_DELTAS_KEY := "rep_deltas"


# --- Application seam (§4.12.3) --------------------------------------------

## Applies a finished battle's economy effects and returns what was applied.
##
## `outcome` is the §4.12.2 block (after `BattleResult.apply`, so fleet effects
## have already happened). Read for `salvage_gold`, `xp` and `rep_deltas` only;
## the only write is the idempotency marker `rewards_applied` (§4.12.3: "the
## screen may call it once, tests may call twice").
##
## Returns `{gold, xp, rep_deltas}` — **the state change actually applied**:
##
##   `gold`        the gold `GameState.add_gold()` added
##   `xp`          the XP `Character.award_xp()` awarded
##   `rep_deltas`  per nation, the reputation points the call moved (a +2 at
##                 99 reputation reports +1, because `Character.add_reputation`
##                 clamps to ±100 — §4.6). The *requested* deltas stay in
##                 `outcome.rep_deltas`, which is what the after-action dialog
##                 prints (§4.12.2).
##
## An already-applied block returns all-zeroes. Reputation is clamped to
## −100…+100 by `Character.add_reputation`; a navy `−20` is never present
## (§4.11.10).
static func apply(outcome: Dictionary) -> Dictionary:
	var applied := {GOLD_KEY: 0, XP_KEY: 0, REP_DELTAS_KEY: {}}
	if not (outcome is Dictionary) or outcome.is_empty():
		return applied
	# Defensive: the outcome block may arrive already settled (§4.12.3).
	if bool(outcome.get("rewards_applied", false)):
		return applied
	var gold := maxi(int(outcome.get("salvage_gold", 0)), 0)
	var xp := maxi(int(outcome.get("xp", 0)), 0)
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
	if xp > 0:
		CharacterLib.award_xp(xp)
	applied[XP_KEY] = xp
	applied[REP_DELTAS_KEY] = deltas
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
		width = 2160
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
