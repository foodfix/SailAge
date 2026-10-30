class_name QuestGen
extends RefCounted
## Guild quest offers, acceptance, tracking, and completion/failure
## (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.2, §4.9.3; schema in `10-*` §4.8;
## UI in `30-*` §4.7 and `80-*` §4.7.3).
##
## Pure static logic (`RefCounted`, no node references, docs/90-* §4) so the
## whole offer/track/complete cycle is unit-testable headless. It reads and
## mutates only these `GameState` fields: `day`, `gold`, `active_quests`,
## `fame`, `player.reputation` (through `Character`), and the fleet hold
## (through `Fleet`) for delivery pickup.
##
## **Offers are derived, never saved** (§4.9.3): the 3 offers of a guild are a
## pure function of `(port id, day // 7)`, so save/load cannot desynchronise
## them and a reload offers exactly what the player saw.
##
## **One seed, one draw order** (§4.9.3) — every draw below consumes the stream
## in the documented order, so a test can reproduce any offer list exactly.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FameLib := preload("res://scripts/player/fame.gd")

# --- §4.9.3 pinned numbers ------------------------------------------------

## Offers per guild (§4.2 "lists 3 quests").
const OFFERS_PER_GUILD := 3
## Refresh cadence: `day // OFFER_WEEK`.
const OFFER_WEEK := 7
## Seed formula, the same family as `60-*` §4.11.1 (`day` term + ordinal).
const SEED_WEEK_MULT := 1000003
const SEED_PORT_MULT := 7919
## Base active-quest slots (§4.2 "max 3"), +1 at viscount (§4.9.2).
const MAX_ACTIVE_QUESTS := 3
const VISCOUNT_EXTRA_SLOT := 1
## Delivery draw bands (§4.9.3).
const DELIVERY_QTY_BASE := 20
const DELIVERY_QTY_STEP := 10
const DELIVERY_QTY_TIERS := 4          # 20 / 30 / 40 / 50
const DELIVERY_DIST_MIN := 6
const DELIVERY_DIST_MAX := 30
const DELIVERY_DIST_MIN_WIDE := 3
const DELIVERY_DIST_MAX_WIDE := 60
const DELIVERY_EXPIRY_DIVISOR := 4
const DELIVERY_EXPIRY_PAD := 5
const DELIVERY_EXPIRY_MIN := 7
const DELIVERY_EXPIRY_MAX := 30
## Reward bands (§4.2/§4.9.3).
const DELIVERY_GOLD_FACTOR := 2
const DELIVERY_REP := 5
const DELIVERY_FAME := 10
const BOUNTY_FAME := 15
const EXPLORATION_REP := 5
const EXPLORATION_FAME := 10
const BOUNTY_EXPIRY_DAYS := 30
const BOUNTY_GOLD_BY_TIER := {1: 5000, 2: 10000, 3: 20000}
const BOUNTY_TIER_MIN := 1
const BOUNTY_TIER_MAX := 3
const BOUNTY_ZONE_RADIUS := 10
## Offer-type roll bands for slots 1 and 2 (§4.9.3 step 2).
const TYPE_DELIVERY_UNTIL := 0.5
const TYPE_BOUNTY_UNTIL := 0.8
## Failure delta (§4.2 "Fail … −5 rep").
const FAIL_REPUTATION := -5

## Offer/quest type ids (`10-*` §4.8).
const TYPE_DELIVERY := "delivery"
const TYPE_BOUNTY := "bounty"
const TYPE_EXPLORATION := "exploration"
const TYPE_ROYAL := "royal"
## Lifecycle statuses on a stored instance.
const STATUS_ACTIVE := "active"
const STATUS_COMPLETED := "completed"
const STATUS_FAILED := "failed"

## Quest instance id prefix: `q_<origin port>_<week>_<slot>`.
const INSTANCE_PREFIX := "q_"


# --- Offers (docs/70-* §4.9.3) -------------------------------------------

## The deterministic seed of a guild's offer list: `(day // 7) × 1000003 +
## port_ordinal × 7919`, `port_ordinal` being the 0-based index of the port id
## in the **ascending id order** (map-independent, so the same port always
## seeds the same list).
static func offer_seed(port_id: String, day: int) -> int:
	return (day / OFFER_WEEK) * SEED_WEEK_MULT + port_ordinal(port_id) * SEED_PORT_MULT


## The 0-based position of `port_id` among all sorted port ids (0 when the port
## is unknown, so a bad id never crashes the generator).
static func port_ordinal(port_id: String) -> int:
	var ids: Array = DataLoader.ports.keys()
	ids.sort()
	return ids.find(port_id)


## The week number a day falls in (`day // 7`).
static func week_of(day: int) -> int:
	return int(day / OFFER_WEEK)


## The first day of the **next** offer refresh after `day` (§4.2 "refreshes
## every 7 in-game days"), for the guild header line.
static func next_refresh_day(day: int) -> int:
	return (week_of(day) + 1) * OFFER_WEEK


## The 3 offers at `port_id` on `day`, as quest **instances** (not yet
## accepted): `{instance_id, template_id, type, giver, origin_port_id,
## requirements, rewards, expiry_days, status}`. Deterministic per
## `(port, day // 7)` — see [method offer_seed].
static func offers(port_id: String, day: int) -> Array:
	var out: Array = []
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = offer_seed(port_id, day)
	var week := week_of(day)
	for slot in OFFERS_PER_GUILD:
		var type := TYPE_DELIVERY
		if slot > 0:
			var roll := rng.randf()
			if roll < TYPE_DELIVERY_UNTIL:
				type = TYPE_DELIVERY
			elif roll < TYPE_BOUNTY_UNTIL:
				type = TYPE_BOUNTY
			else:
				type = TYPE_EXPLORATION
		var offer: Dictionary = _make_offer(port_id, type, slot, week, day, rng)
		if not offer.is_empty():
			out.append(offer)
	return out


## The offers that are neither accepted nor currently unaffordable-for-hold:
## the guild screen's list, with accepted instances filtered out so an offer
## cannot be taken twice (the instance id is derived, not random).
static func available_offers(port_id: String, day: int) -> Array:
	var taken := {}
	for quest in GameState.active_quests:
		if quest is Dictionary:
			taken[str((quest as Dictionary).get("instance_id", ""))] = true
	var out: Array = []
	for offer in offers(port_id, day):
		if taken.has(str(offer.get("instance_id", ""))):
			continue
		out.append(offer)
	return out


## One offer, by type. Draws the type's own numbers from `rng` in the §4.9.3
## order; `{}` only when the type cannot be offered at all (an exploration with
## no unfound discovery in range degenerates to a delivery, never to {}).
static func _make_offer(port_id: String, type: String, slot: int, week: int,
		day: int, rng: RandomNumberGenerator) -> Dictionary:
	var instance_id := "%s%s_%d_%d" % [INSTANCE_PREFIX, port_id, week, slot]
	match type:
		TYPE_BOUNTY:
			return _bounty_offer(instance_id, port_id, day, rng)
		TYPE_EXPLORATION:
			var exploration := _exploration_offer(instance_id, port_id, day, rng)
			if not exploration.is_empty():
				return exploration
			# §4.9.3: an impossible exploration degenerates to a delivery.
			return _delivery_offer(instance_id, port_id, day, rng)
		_:
			return _delivery_offer(instance_id, port_id, day, rng)


static func _delivery_offer(instance_id: String, port_id: String, day: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var templates: Array = _templates_of_type(TYPE_DELIVERY)
	if templates.is_empty():
		return {}
	var template: Dictionary = templates[rng.randi_range(0, templates.size() - 1)]
	var good_id := str((template.get("requirements", {}) as Dictionary)
		.get("good_id", ""))
	var quantity := DELIVERY_QTY_BASE \
		+ DELIVERY_QTY_STEP * rng.randi_range(0, DELIVERY_QTY_TIERS - 1)
	var dest := _pick_destination(port_id, rng)
	if dest.is_empty():
		return {}
	var dest_port: Dictionary = DataLoader.get_port(str(dest["id"]))
	var nation_id := str(dest_port.get("nation_id", ""))
	var base_price := int(DataLoader.get_good(good_id).get("base_price", 0))
	return {
		"instance_id": instance_id,
		"template_id": str(template.get("id", "")),
		"type": TYPE_DELIVERY,
		"giver": "guild",
		"origin_port_id": port_id,
		"requirements": {
			"good_id": good_id,
			"quantity": quantity,
			"dest_port_id": str(dest["id"]),
		},
		"rewards": {
			"gold": DELIVERY_GOLD_FACTOR * base_price * quantity,
			"reputation": {nation_id: DELIVERY_REP},
			"fame": DELIVERY_FAME,
		},
		"expiry_days": int(dest["expiry"]),
		"status": STATUS_ACTIVE,
	}


static func _bounty_offer(instance_id: String, port_id: String, day: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var template: Dictionary = _first_template(TYPE_BOUNTY)
	if template.is_empty():
		return {}
	var tier := rng.randi_range(BOUNTY_TIER_MIN, BOUNTY_TIER_MAX)
	return {
		"instance_id": instance_id,
		"template_id": str(template.get("id", "")),
		"type": TYPE_BOUNTY,
		"giver": "guild",
		"origin_port_id": port_id,
		"requirements": {
			# The fleet is spawned on acceptance, so the id is only known then;
			# the offer carries the tier it will be built from.
			"tier": tier,
			"target_fleet_id": "",
		},
		"rewards": {
			"gold": int(BOUNTY_GOLD_BY_TIER.get(tier, 5000)),
			"reputation": {},
			"fame": BOUNTY_FAME,
		},
		"expiry_days": BOUNTY_EXPIRY_DAYS,
		"status": STATUS_ACTIVE,
	}


static func _exploration_offer(instance_id: String, port_id: String, day: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var template: Dictionary = _first_template(TYPE_EXPLORATION)
	if template.is_empty():
		return {}
	var candidates := _hint_candidates(port_id, 40)
	if candidates.is_empty():
		return {}
	var discovery_id := str(candidates[rng.randi_range(0, candidates.size() - 1)])
	var port: Dictionary = DataLoader.get_port(port_id)
	var nation_id := str(port.get("nation_id", ""))
	return {
		"instance_id": instance_id,
		"template_id": str(template.get("id", "")),
		"type": TYPE_EXPLORATION,
		"giver": "guild",
		"origin_port_id": port_id,
		"requirements": {"discovery_id": discovery_id},
		"rewards": {
			"gold": 0,
			"reputation": {nation_id: EXPLORATION_REP},
			"fame": EXPLORATION_FAME,
		},
		"expiry_days": 30,
		"status": STATUS_ACTIVE,
	}


## A destination draw (§4.9.3): a port on the active map with a different
## nation and a Chebyshev distance in `[6, 30]`, sorted by id; if that set is
## empty the nation filter is dropped, then the band widens to `[3, 60]`.
static func _pick_destination(port_id: String, rng: RandomNumberGenerator) -> Dictionary:
	var origin: Dictionary = DataLoader.get_port(port_id)
	var from := Vector2i(int((origin.get("position", {}) as Dictionary).get("x", 0)),
		int((origin.get("position", {}) as Dictionary).get("y", 0)))
	var origin_nation := str(origin.get("nation_id", ""))
	for band in [[DELIVERY_DIST_MIN, DELIVERY_DIST_MAX, true],
			[DELIVERY_DIST_MIN, DELIVERY_DIST_MAX, false],
			[DELIVERY_DIST_MIN_WIDE, DELIVERY_DIST_MAX_WIDE, false]]:
		var candidates := _destination_candidates(port_id, from, origin_nation,
			int(band[0]), int(band[1]), bool(band[2]))
		if candidates.is_empty():
			continue
		return candidates[rng.randi_range(0, candidates.size() - 1)]
	return {}


static func _destination_candidates(port_id: String, from: Vector2i,
		origin_nation: String, distance_min: int, distance_max: int,
		distinct_nation: bool) -> Array:
	var out: Array = []
	for entry in DataLoader.ports_list:
		var other_id := str((entry as Dictionary).get("id", ""))
		if other_id == port_id:
			continue
		if distinct_nation \
				and str((entry as Dictionary).get("nation_id", "")) == origin_nation:
			continue
		var position: Dictionary = (entry as Dictionary).get("position", {})
		var cell := Vector2i(int(position.get("x", 0)), int(position.get("y", 0)))
		var distance := maxi(absi(cell.x - from.x), absi(cell.y - from.y))
		if distance < distance_min or distance > distance_max:
			continue
		out.append({
			"id": other_id,
			"distance": distance,
			"expiry": clampi(int(ceil(float(distance) / DELIVERY_EXPIRY_DIVISOR))
				+ DELIVERY_EXPIRY_PAD, DELIVERY_EXPIRY_MIN, DELIVERY_EXPIRY_MAX),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["id"]) < str(b["id"]))
	return out


## Discovery ids that are unfound and within Chebyshev `radius` of `port_id`'s
## harbour, sorted ascending (§4.9.3 exploration draw).
static func _hint_candidates(port_id: String, radius: int) -> Array:
	var port: Dictionary = DataLoader.get_port(port_id)
	var position: Dictionary = port.get("position", {})
	var from := Vector2i(int(position.get("x", 0)), int(position.get("y", 0)))
	var out: Array = []
	for entry in DataLoader.discoveries_list:
		var discovery_id := str((entry as Dictionary).get("id", ""))
		if GameState.discoveries_found.has(discovery_id):
			continue
		var pos: Dictionary = (entry as Dictionary).get("position", {})
		var cell := Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0)))
		if maxi(absi(cell.x - from.x), absi(cell.y - from.y)) > radius:
			continue
		out.append(discovery_id)
	out.sort()
	return out


static func _templates_of_type(type: String) -> Array:
	var out: Array = []
	for entry in DataLoader.quests_list:
		if (entry as Dictionary).get("type") == type:
			out.append(entry)
	return out


static func _first_template(type: String) -> Dictionary:
	var templates := _templates_of_type(type)
	return templates[0] if not templates.is_empty() else {}


# --- Acceptance (docs/70-* §4.9.3) ---------------------------------------

## Max active quests: 3, or 4 while **any** nation's title is viscount or
## higher (`70-*` §4.9.2 — max over nations, not a sum).
static func max_active_quests() -> int:
	var best := 0
	for nation_id in GameState.titles:
		var rank := str(GameState.titles[nation_id])
		if rank in ["viscount", "count", "duke"]:
			return MAX_ACTIVE_QUESTS + VISCOUNT_EXTRA_SLOT
	return MAX_ACTIVE_QUESTS


## Number of quests currently active.
static func active_count() -> int:
	var count := 0
	for quest in GameState.active_quests:
		if quest is Dictionary \
				and str((quest as Dictionary).get("status", STATUS_ACTIVE)) == STATUS_ACTIVE:
			count += 1
	return count


## "" when `offer` may be accepted, else the `ui_strings` reason key
## (`quest.slots_full`, `quest.no_hold`).
static func accept_block_reason(offer: Dictionary) -> String:
	if active_count() >= max_active_quests():
		return "quest.slots_full"
	if str(offer.get("type", "")) == TYPE_DELIVERY:
		var requirements: Dictionary = offer.get("requirements", {})
		if FleetLib.fleet_free() < int(requirements.get("quantity", 0)):
			return "quest.no_hold"
	return ""


## Accepts `offer` at `port_id` on `day`: stores the instance in
## `active_quests`, moves the delivery goods into the hold free, and spawns a
## bounty target through the Phase-2 encounter API. Returns the stored instance
## (`{}` on any refusal, state untouched).
static func accept(offer: Dictionary, port_id: String, day: int) -> Dictionary:
	if offer.is_empty() or not accept_block_reason(offer).is_empty():
		return {}
	var instance: Dictionary = offer.duplicate(true)
	instance["origin_port_id"] = port_id
	instance["accepted_day"] = day
	instance["deadline_day"] = day + int(instance.get("expiry_days", 30))
	instance["status"] = STATUS_ACTIVE
	if str(instance.get("type", "")) == TYPE_DELIVERY:
		var requirements: Dictionary = instance["requirements"]
		var quantity := int(requirements.get("quantity", 0))
		var stored := FleetLib.add_goods(str(requirements.get("good_id", "")), quantity)
		if stored != quantity:
			if stored > 0:
				FleetLib.remove_goods(str(requirements.get("good_id", "")), stored)
			return {}
		FleetLib.notify_changed()
	elif str(instance.get("type", "")) == TYPE_BOUNTY:
		var target_id := _spawn_bounty_target(instance, day)
		if not target_id.is_empty():
			(instance["requirements"] as Dictionary)["target_fleet_id"] = target_id
	GameState.active_quests.append(instance)
	EventBus.quests_changed.emit()
	return instance


# --- Completion & failure (docs/70-* §4.9.3) -----------------------------

## The quests a delivery at `dest_port_id` would complete right now (called on
## port entry). Pure read: [method complete_delivery_quests] applies them.
static func completable_deliveries(dest_port_id: String) -> Array:
	var out: Array = []
	for quest in GameState.active_quests:
		if not (quest is Dictionary):
			continue
		var q: Dictionary = quest
		if str(q.get("status", "")) != STATUS_ACTIVE:
			continue
		if str(q.get("type", "")) != TYPE_DELIVERY:
			continue
		var requirements: Dictionary = q.get("requirements", {})
		if str(requirements.get("dest_port_id", "")) != dest_port_id:
			continue
		var good_id := str(requirements.get("good_id", ""))
		if FleetLib.held(good_id) < int(requirements.get("quantity", 0)):
			continue
		out.append(q)
	return out


## Completes every delivery quest due at `dest_port_id`; returns the list of
## completed instances. The goods are removed, then the reward is paid.
static func complete_delivery_quests(dest_port_id: String) -> Array:
	var done: Array = []
	for quest in completable_deliveries(dest_port_id):
		var requirements: Dictionary = quest["requirements"]
		var removed := FleetLib.remove_goods(str(requirements.get("good_id", "")),
			int(requirements.get("quantity", 0)))
		if removed != int(requirements.get("quantity", 0)):
			continue
		_complete(quest)
		done.append(quest)
	if not done.is_empty():
		FleetLib.notify_changed()
	return done


## Completes the exploration quest for `discovery_id` (called by the guild
## report), on top of the report's own reward (§4.4).
static func complete_exploration_quests(discovery_id: String) -> Array:
	var done: Array = []
	for quest in GameState.active_quests:
		if not (quest is Dictionary) or str(quest.get("type", "")) != TYPE_EXPLORATION:
			continue
		if str(quest.get("status", "")) != STATUS_ACTIVE:
			continue
		if str((quest.get("requirements", {}) as Dictionary).get("discovery_id", "")) \
				!= discovery_id:
			continue
		_complete(quest)
		done.append(quest)
	return done


## Completes the bounty quest whose `target_fleet_id` just lost a battle
## (`70-*` §4.9.3: a `victory` against the target fleet).
static func complete_bounty_quests(target_fleet_id: String) -> Array:
	var done: Array = []
	if target_fleet_id.is_empty():
		return done
	for quest in GameState.active_quests:
		if not (quest is Dictionary) or str(quest.get("type", "")) != TYPE_BOUNTY:
			continue
		if str(quest.get("status", "")) != STATUS_ACTIVE:
			continue
		if str((quest.get("requirements", {}) as Dictionary)
				.get("target_fleet_id", "")) != target_fleet_id:
			continue
		_complete(quest)
		done.append(quest)
	return done


## Pays one quest's rewards and marks it completed. The single place a quest
## awards gold/reputation/fame, so every completion path is identical.
static func _complete(quest: Dictionary) -> void:
	var rewards: Dictionary = quest.get("rewards", {})
	var gold := int(rewards.get("gold", 0))
	if gold > 0:
		GameState.add_gold(gold)
	var reputation: Dictionary = rewards.get("reputation", {})
	for nation_id in reputation:
		CharacterLib.add_reputation(str(nation_id), int(reputation[nation_id]))
	var fame := int(rewards.get("fame", 0))
	if fame > 0:
		FameLib.add(fame)
	quest["status"] = STATUS_COMPLETED
	quest["completed_day"] = int(GameState.day)
	EventBus.quests_changed.emit()


## Fails `quest` with the §4.2 delta (−5 rep with the origin port's nation, no
## fame, no gold; delivery goods are *not* reclaimed).
static func fail(quest: Dictionary) -> bool:
	if str(quest.get("status", "")) != STATUS_ACTIVE:
		return false
	var origin: Dictionary = DataLoader.get_port(str(quest.get("origin_port_id", "")))
	CharacterLib.add_reputation(str(origin.get("nation_id", "")), FAIL_REPUTATION)
	quest["status"] = STATUS_FAILED
	quest["failed_day"] = int(GameState.day)
	EventBus.quests_changed.emit()
	return true


## `true` when `quest` has expired on `day` (§4.9.3 `day > deadline_day`).
static func is_expired(quest: Dictionary, day: int) -> bool:
	if int(quest.get("deadline_day", 0)) <= 0:
		return false
	return day > int(quest.get("deadline_day", 0))


## `true` when a delivery's goods are no longer held in the pooled hold — the
## "cargo sold/jettisoned" failure path (§4.2, §6).
static func delivery_cargo_lost(quest: Dictionary) -> bool:
	if str(quest.get("type", "")) != TYPE_DELIVERY:
		return false
	var requirements: Dictionary = quest.get("requirements", {})
	return FleetLib.held(str(requirements.get("good_id", ""))) \
		< int(requirements.get("quantity", 0))


## The day-tick pass: expires every overdue quest and fails every delivery
## whose cargo is gone. Returns the list of failed instances (for the report).
## Bounty quests are **not** failed here while their battle is running: the
## caller invokes this at the day tick, and a battle in progress blocks the
## tick, so the §6 "expired bounty while in battle" rule is satisfied by the
## ordering (`complete_bounty_quests` runs at battle end, before the next tick).
static func tick(day: int) -> Array:
	var failed: Array = []
	for quest in GameState.active_quests:
		if not (quest is Dictionary) or str(quest.get("status", "")) != STATUS_ACTIVE:
			continue
		if is_expired(quest, day) or delivery_cargo_lost(quest):
			if fail(quest):
				failed.append(quest)
	return failed


## Drops completed/failed instances from `active_quests` (the panel and the
## slot count only ever see live quests). Returns how many were dropped.
static func prune() -> int:
	var kept: Array = []
	var dropped := 0
	for quest in GameState.active_quests:
		if quest is Dictionary \
				and str((quest as Dictionary).get("status", STATUS_ACTIVE)) == STATUS_ACTIVE:
			kept.append(quest)
		else:
			dropped += 1
	GameState.active_quests = kept
	return dropped


## The active quests for the character panel, in accepted order.
static func active_quests() -> Array:
	var out: Array = []
	for quest in GameState.active_quests:
		if quest is Dictionary \
				and str((quest as Dictionary).get("status", STATUS_ACTIVE)) == STATUS_ACTIVE:
			out.append(quest)
	return out


## Abandons `quest` (the panel's `quest.abandon`): the same failure path.
static func abandon(quest: Dictionary) -> bool:
	return fail(quest)


# --- Presentation (docs/80-* §4.7.3, §4.7.4) -----------------------------

## The composed objective line of an offer or stored instance (`quest.line.*`
## frames from `80-*` §4.7.4; numbers composed by the UI, `10-*` §3.3).
## Shared by the guild screen and the character panel so a quest reads the same
## wherever it is listed.
static func objective_text(quest: Dictionary) -> String:
	var requirements: Dictionary = quest.get("requirements", {})
	var type := str(quest.get("type", ""))
	if type == TYPE_ROYAL:
		# Royal missions name their objective in the template (`data/quests.json`
		# `requirements.objective`, `70-*` §4.9.4) and wrap it in the §4.7.4
		# `quest.line.royal` frame.
		var template: Dictionary = DataLoader.get_quest(
			str(quest.get("template_id", "")))
		var objective: Dictionary = (template.get("requirements", {}) as Dictionary) \
			.get("objective", {})
		if not objective.is_empty():
			return I18n.fmt("quest.line.royal", {"objective": I18n.t(objective)})
		return I18n.t_key("quest.type.royal")
	match type:
		TYPE_DELIVERY:
			return _delivery_line(requirements)
		TYPE_BOUNTY:
			return I18n.fmt("quest.line.bounty", {
				"target": I18n.t_key("encounter.pirate"),
				"tier": int(requirements.get("tier", 1)),
			})
		TYPE_EXPLORATION:
			return I18n.t_key("quest.line.exploration")
	return I18n.t_key("ui.not_available")


static func _delivery_line(requirements: Dictionary) -> String:
	return I18n.fmt("quest.line.delivery", {
		"quantity": int(requirements.get("quantity", 0)),
		"good": I18n.t(DataLoader.get_good(str(requirements.get("good_id", "")))
			.get("name", {})),
		"port": _port_name(str(requirements.get("dest_port_id", ""))),
	})


static func _port_name(port_id: String) -> String:
	if port_id.is_empty():
		return "-"
	return I18n.t(DataLoader.get_port(port_id).get("name", {}))


## The type tag key of a quest (`quest.type.*`, `80-*` §4.7.4).
static func type_key(quest: Dictionary) -> String:
	return "quest.type.%s" % str(quest.get("type", ""))


# --- Bounty spawn (docs/70-* §4.9.3) ------------------------------------

## Spawns the pirate fleet a bounty offer names, through the Phase-2
## `Encounters.spawn` API **unmodified** (`IMPLEMENT-Phase3.md` "B4"): the
## marker is then a normal hostile marker whose battle outcome the completion
## hook can match by id. Returns the marker id ("" when no spawn happened).
static func _spawn_bounty_target(quest: Dictionary, day: int) -> String:
	var encounters_path := "res://scripts/world/encounters.gd"
	if not ResourceLoader.exists(encounters_path):
		return ""
	# Spawning walks the map (`60-*` §4.11.11.1 zone), and a save loaded
	# straight into port never opened S3 — build the loader here if needed.
	DataLoader.ensure_map()
	var module = ResourceLoader.load(encounters_path)
	if module == null or not module.can_instantiate():
		return ""
	var encounters = module.new(day)
	var marker: Dictionary = encounters.call("spawn", "pirate", "", day)
	if marker.is_empty():
		return ""
	var id := str(marker.get("id", ""))
	# Tag the marker with its quest so the battle-end hook can match it, and
	# set the tier the reward was priced from.
	var lookup := _find_marker(id)
	if not lookup.is_empty():
		lookup["quest_id"] = str(quest.get("instance_id", ""))
		lookup["tier"] = int((quest.get("requirements", {}) as Dictionary)
			.get("tier", 1))
	return id


static func _find_marker(id: String) -> Dictionary:
	for marker in GameState.hostile_fleets:
		if marker is Dictionary and str((marker as Dictionary).get("id", "")) == id:
			return marker
	return {}


## The instance with `instance_id`, or `{}`.
static func find(instance_id: String) -> Dictionary:
	for quest in GameState.active_quests:
		if quest is Dictionary and str((quest as Dictionary).get("instance_id", "")) == instance_id:
			return quest
	return {}
