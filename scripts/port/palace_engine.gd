class_name PalaceEngine
extends RefCounted
## Palace offers: royal missions, the title ceremony, repair bays, bounty
## pay-off, tournament entry and retirement
## (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.3, §4.7, §4.9.2, §4.9.4, §4.9.5,
## §4.9.7; `30-*` §4.2; `40-*` §4.3; `80-*` §4.7.3).
##
## Pure static logic (`RefCounted`, no node refs, docs/90-* §4). The screen
## (`palace_screen.gd`) only renders these answers and forwards clicks.
##
## One rule per §4.9.4 lives here and nowhere else: which nations can offer a
## mission, the three mission kinds, the one-per-nation limit, and the
## completion deltas. The title ladder itself is `Fame`.

const CharacterLib := preload("res://scripts/player/character.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")

## §4.3: a nation offers royal missions only at or above this reputation.
const MISSION_REPUTATION := 30
## §4.9.4: the three royal mission kinds.
const KIND_DELIVERY := "royal_delivery"
const KIND_PATROL := "royal_patrol"
const KIND_CHART := "royal_chart"
const KINDS: Array[String] = [KIND_DELIVERY, KIND_PATROL, KIND_CHART]
## §4.9.4 pinned rewards.
const ROYAL_DELIVERY_GOLD_FACTOR := 3
const ROYAL_DELIVERY_REP := 10
const ROYAL_FAME := 25
const PATROL_COUNT := 2
const PATROL_GOLD := 8000
const CHART_COUNT := 2
const CHART_GOLD := 6000
const ROYAL_REP := 10
const ROYAL_EXPIRY_DAYS := 60
## §4.9.4 failure delta.
const FAIL_REPUTATION := -10


# --- Access ---------------------------------------------------------------

## The nation whose palace this is (`""` when `port_id` is not a capital).
static func nation_of(port_id: String) -> String:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return ""
	var nation_id := str(port.get("nation_id", ""))
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	if str(nation.get("capital_port_id", "")) == port_id:
		return nation_id
	return ""


## `true` when the palace at `port_id` offers royal missions: it is a capital,
## the player's reputation with that nation is ≥ 30, and no bounty shuts it.
static func offers_missions(port_id: String) -> bool:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return false
	if BountyLib.is_port_closed(port_id) and not BountyLib.can_pay_here(port_id):
		return false
	return CharacterLib.reputation(nation_id) >= MISSION_REPUTATION


## "" when `port_id`'s palace may open at all, else the reason key.
static func open_block_reason(port_id: String) -> String:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return "palace.not_capital"
	if BountyLib.is_port_closed(port_id) and not BountyLib.can_pay_here(port_id):
		return "port.closed_bounty"
	return ""


# --- Royal missions (docs/70-* §4.9.4) -----------------------------------

## The active royal mission of `nation_id` (`{}` when none) — §4.3 "one at a
## time per nation".
static func active_mission(nation_id: String) -> Dictionary:
	for quest in GameState.active_quests:
		if not (quest is Dictionary):
			continue
		var q: Dictionary = quest
		if str(q.get("giver", "")) != "palace":
			continue
		if str(q.get("status", "")) != QuestGenLib.STATUS_ACTIVE:
			continue
		var origin: Dictionary = DataLoader.get_port(str(q.get("origin_port_id", "")))
		if str(origin.get("nation_id", "")) == nation_id:
			return q
	return {}


## The mission kind `port_id`'s palace offers this week: `cycle(kind count)`
## rotated by `day // 30`, so all three kinds appear in a long run, and the
## offer is deterministic per (nation, month) like the guild's.
static func offered_kind(port_id: String, day: int) -> String:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return ""
	var ids: Array = DataLoader.nations.keys()
	ids.sort()
	var ordinal := maxi(0, ids.find(nation_id))
	var month := int(day / 30)
	return KINDS[posmod(month + ordinal, KINDS.size())]


## The royal offer at `port_id` on `day` (`{}` when missions are unavailable or
## one is already running). The instance is the same shape as a guild quest,
## with `giver: "palace"` and `requirements.kind`.
static func offer(port_id: String, day: int) -> Dictionary:
	if not offers_missions(port_id) or not active_mission(nation_of(port_id)).is_empty():
		return {}
	var nation_id := nation_of(port_id)
	var kind := offered_kind(port_id, day)
	var instance_id := "q_royal_%s_%d" % [nation_id, int(day / 30)]
	match kind:
		KIND_PATROL:
			return {
				"instance_id": instance_id,
				"template_id": "qt_royal_patrol",
				"type": "royal",
				"giver": "palace",
				"origin_port_id": port_id,
				"requirements": {"kind": KIND_PATROL,
					"nation_id": _rival_of(nation_id),
					"count": PATROL_COUNT},
				"rewards": {"gold": PATROL_GOLD,
					"reputation": {nation_id: ROYAL_REP}, "fame": ROYAL_FAME},
				"expiry_days": ROYAL_EXPIRY_DAYS,
				"status": QuestGenLib.STATUS_ACTIVE,
			}
		KIND_CHART:
			return {
				"instance_id": instance_id,
				"template_id": "qt_royal_chart",
				"type": "royal",
				"giver": "palace",
				"origin_port_id": port_id,
				"requirements": {"kind": KIND_CHART, "count": CHART_COUNT},
				"rewards": {"gold": CHART_GOLD,
					"reputation": {nation_id: ROYAL_REP}, "fame": ROYAL_FAME},
				"expiry_days": ROYAL_EXPIRY_DAYS,
				"status": QuestGenLib.STATUS_ACTIVE,
			}
		_:
			return _delivery_offer(instance_id, port_id, nation_id)


## The royal delivery is a guild delivery with the §4.9.4 multipliers, drawn
## from the same deterministic per-(port, day//7) stream.
static func _delivery_offer(instance_id: String, port_id: String,
		nation_id: String) -> Dictionary:
	var deliveries := QuestGenLib.offers(port_id, GameState.day)
	var template: Dictionary = {}
	for offer in deliveries:
		if str((offer as Dictionary).get("type", "")) == QuestGenLib.TYPE_DELIVERY:
			template = offer
			break
	if template.is_empty():
		return {}
	var requirements: Dictionary = (template["requirements"] as Dictionary).duplicate(true)
	var rewards: Dictionary = {
		"gold": int(((template["rewards"] as Dictionary).get("gold", 0)))
			* ROYAL_DELIVERY_GOLD_FACTOR,
		"reputation": {nation_id: ROYAL_DELIVERY_REP},
		"fame": ROYAL_FAME,
	}
	return {
		"instance_id": instance_id,
		"template_id": str(template.get("template_id", "")),
		"type": "royal",
		"giver": "palace",
		"origin_port_id": port_id,
		"requirements": {
			"kind": KIND_DELIVERY,
			"good_id": str(requirements.get("good_id", "")),
			"quantity": int(requirements.get("quantity", 0)),
			"dest_port_id": str(requirements.get("dest_port_id", "")),
		},
		"rewards": rewards,
		"expiry_days": QuestGenLib.DELIVERY_EXPIRY_MAX,
		"status": QuestGenLib.STATUS_ACTIVE,
	}


## The rival nation a patrol targets: the giver's first `rivals` entry
## (`70-*` §4.9.5 data table), falling back to any other nation.
static func _rival_of(nation_id: String) -> String:
	var rivals := BountyLib.rivals(nation_id)
	if not rivals.is_empty():
		return str(rivals[0])
	for nation in DataLoader.nations_list:
		var other := str((nation as Dictionary).get("id", ""))
		if other != nation_id:
			return other
	return ""


## Accepts the palace's offer, spawning what its kind needs (a patrol's navy
## markers, a royal delivery's cargo). Returns the stored instance or `{}`.
static func accept(port_id: String, day: int) -> Dictionary:
	var candidate := offer(port_id, day)
	if candidate.is_empty():
		return {}
	var instance: Dictionary = candidate.duplicate(true)
	instance["accepted_day"] = day
	instance["deadline_day"] = day + int(instance.get("expiry_days",
		ROYAL_EXPIRY_DAYS))
	var kind := str((instance["requirements"] as Dictionary).get("kind", ""))
	if kind == KIND_DELIVERY:
		var requirements: Dictionary = instance["requirements"]
		var quantity := int(requirements.get("quantity", 0))
		if FleetLib.fleet_free() < quantity:
			return {}
		var stored := FleetLib.add_goods(str(requirements.get("good_id", "")), quantity)
		if stored != quantity:
			if stored > 0:
				FleetLib.remove_goods(str(requirements.get("good_id", "")), stored)
			return {}
		FleetLib.notify_changed()
	elif kind == KIND_PATROL:
		_spawn_patrol(instance, day)
	GameState.active_quests.append(instance)
	EventBus.quests_changed.emit()
	return instance


## Spawns the patrol's navy markers through the Phase-2 encounter API
## (bypassing the bounty gate, each tagged with the mission id).
static func _spawn_patrol(instance: Dictionary, day: int) -> void:
	var encounters_path := "res://scripts/world/encounters.gd"
	if not ResourceLoader.exists(encounters_path):
		return
	DataLoader.ensure_map()
	var module = ResourceLoader.load(encounters_path)
	if module == null or not module.can_instantiate():
		return
	var encounters = module.new(day)
	var nation_id := str((instance["requirements"] as Dictionary)
		.get("nation_id", ""))
	for _index in PATROL_COUNT:
		var marker: Dictionary = encounters.call("spawn", "navy", nation_id, day)
		if marker.is_empty():
			continue
		marker["quest_id"] = str(instance.get("instance_id", ""))
		marker["royal_mission"] = true
		(instance["requirements"] as Dictionary)["killed"] = \
			int((instance["requirements"] as Dictionary).get("killed", 0))


## Called at battle end for a `victory`: credits a patrol kill / a charting
## report and completes the mission when its count is reached. Returns the
## completed instance (`{}` otherwise).
static func on_patrol_kill(quest: Dictionary) -> Dictionary:
	var requirements: Dictionary = quest.get("requirements", {})
	requirements["killed"] = int(requirements.get("killed", 0)) + 1
	if int(requirements["killed"]) < int(requirements.get("count", PATROL_COUNT)):
		EventBus.quests_changed.emit()
		return {}
	return complete_mission(quest)


## Called when a discovery is reported: credits `royal_chart` progress.
static func on_discovery_reported(quest: Dictionary) -> Dictionary:
	var requirements: Dictionary = quest.get("requirements", {})
	requirements["reported"] = int(requirements.get("reported", 0)) + 1
	if int(requirements["reported"]) < int(requirements.get("count", CHART_COUNT)):
		EventBus.quests_changed.emit()
		return {}
	return complete_mission(quest)


## Pays a royal mission: gold/reputation/fame, one more completed mission for
## the giver nation, then the §4.9.2 ladder is re-evaluated (the *player*
## still has to attend the ceremony, so nothing is granted here).
static func complete_mission(quest: Dictionary) -> Dictionary:
	if str(quest.get("status", "")) != QuestGenLib.STATUS_ACTIVE:
		return {}
	var rewards: Dictionary = quest.get("rewards", {})
	var gold := int(rewards.get("gold", 0))
	if gold > 0:
		GameState.add_gold(gold)
	var reputation: Dictionary = rewards.get("reputation", {})
	for nation_id in reputation:
		CharacterLib.add_reputation(str(nation_id), int(reputation[nation_id]))
	FameLib.add(int(rewards.get("fame", 0)))
	quest["status"] = QuestGenLib.STATUS_COMPLETED
	quest["completed_day"] = int(GameState.day)
	var nation_id := nation_of(str(quest.get("origin_port_id", "")))
	if nation_id.is_empty():
		var origin: Dictionary = DataLoader.get_port(
			str(quest.get("origin_port_id", "")))
		nation_id = str(origin.get("nation_id", ""))
	FameLib.add_royal_mission(nation_id)
	EventBus.quests_changed.emit()
	return quest


## The royal missions a day tick fails (expiry, §4.9.4: −10 rep, no fame).
static func tick(day: int) -> Array:
	var failed: Array = []
	for quest in GameState.active_quests:
		if not (quest is Dictionary) or str(quest.get("giver", "")) != "palace":
			continue
		if str(quest.get("status", "")) != QuestGenLib.STATUS_ACTIVE:
			continue
		if int(quest.get("deadline_day", 0)) > 0 and day > int(quest.get("deadline_day", 0)):
			var origin: Dictionary = DataLoader.get_port(
				str(quest.get("origin_port_id", "")))
			CharacterLib.add_reputation(str(origin.get("nation_id", "")),
				FAIL_REPUTATION)
			quest["status"] = QuestGenLib.STATUS_FAILED
			quest["failed_day"] = day
			EventBus.quests_changed.emit()
			failed.append(quest)
	return failed


# --- Titles (docs/70-* §4.9.2) -------------------------------------------

## Runs the ceremony: grants the next rank when both requirements are met.
static func attend_ceremony(port_id: String) -> String:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return ""
	return FameLib.grant(nation_id)


# --- Repair bays (docs/70-* §4.9.2 count grant) --------------------------

## The per-point repair cost at `port_id`'s palace bays, after the count-grant
## discount: `ceil(points × ceil(base_price/400) × 0.8)` floored once at the
## end of the whole transaction (`40-*` §4.3 price, then `70-*` §4.9.2).
static func repair_cost(port_id: String, ship_index: int, points: int) -> int:
	var shipyard_path := "res://scripts/port/shipyard_engine.gd"
	if not ResourceLoader.exists(shipyard_path):
		return 0
	var shipyard = ResourceLoader.load(shipyard_path)
	if shipyard == null or not shipyard.has_method("repair_cost_per_point"):
		return 0
	var ship: Dictionary = GameState.fleet[ship_index] if ship_index >= 0 \
		and ship_index < GameState.fleet.size() \
		and GameState.fleet[ship_index] is Dictionary else {}
	if ship.is_empty():
		return 0
	var nation_id := nation_of(port_id)
	var per_point := int(shipyard.call("repair_cost_per_point",
		str(ship.get("ship_type_id", ""))))
	var raw := int(ceil(float(per_point * maxi(points, 0)) \
		* FameLib.repair_discount(nation_id)))
	return maxi(raw, 0)


## Repairs one hull at the bays, charging [method repair_cost]. Returns the
## points repaired (0 when refused: no damage, no gold, or not a capital).
static func repair(port_id: String, ship_index: int, points: int) -> int:
	if nation_of(port_id).is_empty() or points <= 0:
		return 0
	var shipyard_path := "res://scripts/port/shipyard_engine.gd"
	if not ResourceLoader.exists(shipyard_path):
		return 0
	var shipyard = ResourceLoader.load(shipyard_path)
	if shipyard == null:
		return 0
	var max_points := int(shipyard.call("max_repair_points", ship_index))
	var actual := mini(points, max_points)
	if actual <= 0:
		return 0
	var cost := repair_cost(port_id, ship_index, actual)
	if GameState.gold < cost:
		return 0
	if not bool(shipyard.call("repair", ship_index, actual)):
		return 0
	# `repair()` charged the undiscounted price; refund the difference so the
	# count-grant discount is exact and there is one repair implementation.
	var full := int(shipyard.call("repair_cost", ship_index, actual))
	var refund := full - cost
	if refund > 0:
		GameState.add_gold(refund)
	return actual


# --- Bounty / tournament / retirement edges ------------------------------

## Palace bounty row: pays the nation's bounty (docs/70-* §4.9.5).
static func pay_bounty(port_id: String) -> bool:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return false
	return BountyLib.pay_off(nation_id)


## `true` when the retire row exists (§4.7: duke with this nation).
static func can_retire(port_id: String) -> bool:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return false
	return FameLib.is_duke(nation_id)


## Retires the run: marks the save state and announces it (§4.7). The caller
## routes to S16; `SaveSystem` writes the flag on the next save.
static func retire(port_id: String) -> bool:
	if not can_retire(port_id):
		return false
	GameState.retired = true
	GameState.retired_at = int(Time.get_unix_time_from_system())
	EventBus.retired.emit()
	return true


## Tournament entry at this palace (`70-*` §4.9.7).
static func tournament_status(port_id: String, day: int) -> Dictionary:
	return TournamentLib.status(port_id, day)


static func enter_tournament(port_id: String, day: int) -> bool:
	return TournamentLib.enter(port_id, day)
