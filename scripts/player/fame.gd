class_name Fame
extends RefCounted
## Fame and the per-nation nobility-title ladder
## (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.1, §4.3, §4.9.1, §4.9.2).
##
## Pure static logic (`RefCounted`, no node references, docs/90-* §4). It owns
## three `GameState` fields — `fame`, `titles`, `completed_royal_missions` —
## and exposes the ladder arithmetic every other module reads:
##
##   * `title_bonus(nation_id)` — the sell-price multiplier `30-*` §4.2 applies;
##   * `repair_discount(nation_id)` — the count-grant 0.8 factor;
##   * `quest_slots_bonus()` — the viscount-grant extra quest slot;
##   * `next_rank(nation_id)` / `can_promote(nation_id)` / `grant(nation_id)`;
##   * `is_duke(nation_id)` — the retirement gate (§4.7).
##
## The ladder itself is data (`RANKS`, below), so a seventh rank is one edit —
## but the *grants* are code, exactly as `10-*` §4.9 says enums are.

## Rank ids, lowest first (docs/70-* §4.9.2). Index = ladder position.
const RANKS: Array[String] = [
	"none", "knight", "baron", "viscount", "count", "duke",
]
## The four grants the §4.3 table names. Only `none`/`knight`/`baron` differ on
## sell price; viscount adds a quest slot; count adds the repair discount; duke
## unlocks retirement.
const RANK_NONE := "none"
const RANK_KNIGHT := "knight"
const RANK_BARON := "baron"
const RANK_VISCOUNT := "viscount"
const RANK_COUNT := "count"
const RANK_DUKE := "duke"

## §4.9.2: sell-price multiplier by rank — `1.05` at knight, `1.10` at baron
## and above, `1.00` otherwise (applied to the port's **own** nation title).
const SELL_BONUS_KNIGHT := 1.05
const SELL_BONUS_BARON := 1.10
## §4.9.2: count-and-above repair cost factor at that nation's ports.
const REPAIR_DISCOUNT_COUNT := 0.8
## §4.9.2: the viscount grant is `+1` slot; `QuestGen` owns the `3` base.
const QUEST_SLOT_BONUS := 1

## The ladder: rank id → (fame required, royal missions required). `none` is
## the starting rung and is never "granted".
const LADDER := {
	"knight": {"fame": 100, "missions": 1},
	"baron": {"fame": 300, "missions": 2},
	"viscount": {"fame": 700, "missions": 3},
	"count": {"fame": 1500, "missions": 5},
	"duke": {"fame": 3000, "missions": 8},
}


# --- Fame (docs/70-* §4.1, §4.9.1) ---------------------------------------

## Current fame (never negative).
static func value() -> int:
	return maxi(0, int(GameState.fame))


## Adds fame and announces it (§4.9.1: fame never decreases; a non-positive
## amount is a no-op, so a caller cannot spend fame by accident).
static func add(amount: int) -> int:
	if amount <= 0:
		return value()
	GameState.fame = value() + amount
	EventBus.fame_changed.emit(GameState.fame)
	return GameState.fame


# --- Titles (docs/70-* §4.9.2) -------------------------------------------

## The rank id of `nation_id`: its stored rank, or `none` when absent/unknown
## (a hand-edited save must not wedge the ladder).
static func title(nation_id: String) -> String:
	var raw := str(GameState.titles.get(nation_id, RANK_NONE))
	return raw if raw in RANKS else RANK_NONE


## The ladder position of a rank id (0 for `none`, 5 for `duke`).
static func rank_index(rank: String) -> int:
	var index := RANKS.find(rank)
	return index if index >= 0 else 0


## The rank after `nation_id`'s current one (`""` at duke).
static func next_rank(nation_id: String) -> String:
	var index := rank_index(title(nation_id))
	if index + 1 >= RANKS.size():
		return ""
	return RANKS[index + 1]


## The fame the next rank needs, or −1 at the top (`palace.title.next`).
static func next_fame_required(nation_id: String) -> int:
	var rank := next_rank(nation_id)
	if rank.is_empty():
		return -1
	return int((LADDER[rank] as Dictionary)["fame"])


## The royal missions the next rank needs, or −1 at the top.
static func next_missions_required(nation_id: String) -> int:
	var rank := next_rank(nation_id)
	if rank.is_empty():
		return -1
	return int((LADDER[rank] as Dictionary)["missions"])


## Royal missions completed for `nation_id`.
static func royal_missions(nation_id: String) -> int:
	return maxi(0, int(GameState.completed_royal_missions.get(nation_id, 0)))


## `true` when **both** §4.9.2 requirements for the next rank are met.
static func can_promote(nation_id: String) -> bool:
	var rank := next_rank(nation_id)
	if rank.is_empty():
		return false
	var need: Dictionary = LADDER[rank]
	return value() >= int(need["fame"]) \
		and royal_missions(nation_id) >= int(need["missions"])


## Grants the next rank at a palace ceremony and announces it
## (`title_granted`). Returns the new rank id, `""` when not eligible.
static func grant(nation_id: String) -> String:
	if not can_promote(nation_id):
		return ""
	var rank := next_rank(nation_id)
	GameState.titles[nation_id] = rank
	EventBus.title_granted.emit(nation_id, rank)
	return rank


## Adds one completed royal mission and announces nothing (the caller owns the
## ceremony/quest report), returning the new count.
static func add_royal_mission(nation_id: String) -> int:
	var total := royal_missions(nation_id)
	GameState.completed_royal_missions[nation_id] = total + 1
	return total + 1


## `true` when `nation_id`'s title is duke (§4.7 retirement gate).
static func is_duke(nation_id: String) -> bool:
	return title(nation_id) == RANK_DUKE


## `true` when **any** nation's title is duke (§4.7 "Duke with any nation").
static func any_duke() -> bool:
	for nation_id in GameState.titles:
		if title(str(nation_id)) == RANK_DUKE:
			return true
	return false


## The non-`none` titles as `[[nation_id, rank], …]` in nation-id order — the
## S16 summary rows and the character panel's title block.
static func earned_titles() -> Array:
	var out: Array = []
	for nation_id in GameState.titles:
		var rank := title(str(nation_id))
		if rank != RANK_NONE:
			out.append([str(nation_id), rank])
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return out


# --- Grants (docs/70-* §4.9.2) -------------------------------------------

## The sell-price multiplier at a port of `nation_id` (§4.9.2): `1.05` at
## knight, `1.10` at baron and above, `1.00` otherwise. `TradeEngine` applies
## it to the **sell** side only, after the band clamp.
static func title_bonus(nation_id: String) -> float:
	var index := rank_index(title(nation_id))
	if index >= rank_index(RANK_BARON):
		return SELL_BONUS_BARON
	if index >= rank_index(RANK_KNIGHT):
		return SELL_BONUS_KNIGHT
	return 1.0


## The repair-cost factor at a port of `nation_id` (§4.9.2): `0.8` at count or
## duke, `1.0` otherwise. `ShipyardEngine` floors the discounted total once.
static func repair_discount(nation_id: String) -> float:
	return REPAIR_DISCOUNT_COUNT if rank_index(title(nation_id)) \
		>= rank_index(RANK_COUNT) else 1.0


## The extra active-quest slots from titles (§4.9.2): `1` when any nation's
## title is viscount or higher, else `0` — a `max`, never a sum.
static func quest_slots_bonus() -> int:
	for nation_id in GameState.titles:
		if rank_index(title(str(nation_id))) >= rank_index(RANK_VISCOUNT):
			return QUEST_SLOT_BONUS
	return 0


## `{fame, missions}` the next rank needs, for the palace header (`-1`s at the
## top of the ladder).
static func next_requirements(nation_id: String) -> Dictionary:
	return {
		"rank": next_rank(nation_id),
		"fame": next_fame_required(nation_id),
		"missions": next_missions_required(nation_id),
	}
