class_name DiscoverySight
extends RefCounted
## Discovery sighting, reporting and tavern hints
## (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.4; schema `10-*` §4.7; UI `80-*`
## §4.3/§4.7.3).
##
## Pure static logic (`RefCounted`, no node refs, docs/90-* §4). It owns
## three `GameState` fields — `discoveries_found` (found), `discoveries_reported`
## (paid out) and `discovery_hints` (bought at a tavern) — and nothing else.
##
## **Found ≠ reported.** Finding is local (move within `RADIUS` and Explore);
## reporting is a guild action that pays once, ever. Both sets are saved
## (`90-*` §8.1), so a reload cannot re-pay or lose progress.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const FameLib := preload("res://scripts/player/fame.gd")

## §4.4 pin: this is **not** the port sighting radius (8, `20-*` §4.11).
const RADIUS := 3
## §4.4: a tavern hint costs this much.
const HINT_PRICE := 100
## §4.4: up to three hints per tavern visit.
const HINTS_PER_VISIT := 3
## Same seed family as the guild offers (§4.9.3), so both are reproducible.
const SEED_DAY_MULT := 1000003
const SEED_PORT_MULT := 7919


# --- Explore (docs/70-* §4.4) --------------------------------------------

## Every discovery within Chebyshev `RADIUS` of `cell` that has not been found
## yet, sorted by id (stable dialog order).
static func in_range(cell: Vector2i) -> Array:
	var out: Array = []
	for entry in DataLoader.discoveries_list:
		var discovery_id := str((entry as Dictionary).get("id", ""))
		if GameState.discoveries_found.has(discovery_id):
			continue
		if _distance(entry, cell) <= RADIUS:
			out.append(discovery_id)
	out.sort()
	return out


## `true` while a discovery sits in range — what the HUD's
## `world.something_near` hint and the `E` action availability read.
static func something_near(cell: Vector2i) -> bool:
	return not in_range(cell).is_empty()


## The Explore action: marks every in-range discovery found and announces each.
## Returns the ids found (empty when nothing was in range — the caller shows
## `world.explore.none`). No day cost, no cooldown (§4.4).
static func explore(cell: Vector2i) -> Array:
	var found := in_range(cell)
	for discovery_id in found:
		GameState.discoveries_found.append(discovery_id)
		EventBus.discovery_found.emit(str(discovery_id))
	return found


# --- Report (docs/70-* §4.4) ---------------------------------------------

## The found-but-unreported ids, sorted (the guild's report list).
static func unreported() -> Array:
	var out: Array = []
	for entry in DataLoader.discoveries_list:
		var discovery_id := str((entry as Dictionary).get("id", ""))
		if GameState.discoveries_found.has(discovery_id) \
				and not GameState.discoveries_reported.has(discovery_id):
			out.append(discovery_id)
	out.sort()
	return out


## Reports `discovery_id` at a guild: pays `report_reward_gold` and adds `fame`
## **once**; returns the report block (`{}` when not reportable). Completed
## exploration/royal missions are handled by the caller (`QuestGen`,
## `PalaceEngine`) so this module stays pure report bookkeeping.
static func report(discovery_id: String) -> Dictionary:
	if not GameState.discoveries_found.has(discovery_id):
		return {}
	if GameState.discoveries_reported.has(discovery_id):
		return {}
	var entry: Dictionary = DataLoader.get_discovery(discovery_id)
	if entry.is_empty():
		return {}
	var gold := int(entry.get("report_reward_gold", 0))
	var fame := int(entry.get("fame", 0))
	if gold > 0:
		GameState.add_gold(gold)
	FameLib.add(fame)
	GameState.discoveries_reported.append(discovery_id)
	EventBus.discovery_reported.emit(discovery_id)
	return {"id": discovery_id, "gold": gold, "fame": fame}


# --- Hints (docs/70-* §4.4) ----------------------------------------------

## The up-to-three hints a tavern at `port_id` offers on `day`, as discovery
## ids: unfound discoveries drawn from
## `seed = day × 1000003 + port_ordinal × 7919`, uniformly without replacement,
## `fame`-ascending as the stable tie-break (cheapest first). A hinted
## discovery stays listed (so its text can be re-read) but cannot be bought
## again; `hinted` marks it.
static func hints(port_id: String, day: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = day * SEED_DAY_MULT + _port_ordinal(port_id) * SEED_PORT_MULT
	var pool: Array = []
	for entry in DataLoader.discoveries_list:
		var discovery_id := str((entry as Dictionary).get("id", ""))
		if GameState.discoveries_found.has(discovery_id):
			continue
		pool.append({
			"id": discovery_id,
			"fame": int((entry as Dictionary).get("fame", 0)),
		})
	# Deterministic base order: fame ascending, then id — so the draw below is
	# reproducible regardless of the data file's order.
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["fame"]) == int(b["fame"]):
			return str(a["id"]) < str(b["id"])
		return int(a["fame"]) < int(b["fame"]))
	var out: Array = []
	while out.size() < HINTS_PER_VISIT and not pool.is_empty():
		var index := rng.randi_range(0, pool.size() - 1)
		out.append(str((pool[index] as Dictionary)["id"]))
		pool.remove_at(index)
	return out


## `true` when `discovery_id`'s hint was already bought.
static func is_hinted(discovery_id: String) -> bool:
	return GameState.discovery_hints.has(discovery_id)


## Buys `discovery_id`'s hint for 100g. Returns the `region_hint` L10nString
## (so the screen shows the text) or `{}` when refused (unknown, already
## hinted, no gold).
static func buy_hint(discovery_id: String) -> Dictionary:
	if is_hinted(discovery_id) or GameState.gold < HINT_PRICE:
		return {}
	var entry: Dictionary = DataLoader.get_discovery(discovery_id)
	if entry.is_empty():
		return {}
	GameState.add_gold(-HINT_PRICE)
	GameState.discovery_hints[discovery_id] = true
	return entry


## The L10nString to show for a hint row: the real text when bought, else the
## same text (Phase 3 shows the rumour and sells the *location*, `80-*` §4.7.3).
static func hint_text(discovery_id: String) -> Dictionary:
	return DataLoader.get_discovery(discovery_id).get("region_hint", {})


# --- Helpers --------------------------------------------------------------

static func _distance(entry: Dictionary, cell: Vector2i) -> int:
	var pos: Dictionary = (entry as Dictionary).get("position", {})
	var other := Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0)))
	return maxi(absi(other.x - cell.x), absi(other.y - cell.y))


static func _port_ordinal(port_id: String) -> int:
	var ids: Array = DataLoader.ports.keys()
	ids.sort()
	return ids.find(port_id)


## The discovery's map cell (`Vector2i.ZERO` for an unknown id).
static func position_of(discovery_id: String) -> Vector2i:
	var pos: Dictionary = DataLoader.get_discovery(discovery_id).get("position", {})
	return Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0)))
