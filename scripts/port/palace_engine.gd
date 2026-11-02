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
## §4.1b port hours (added 2026-11-02): the palace audiences' window guard and
## hour charges go through the one clock seam.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
## Port allegiance, tariffs and permits (Phase 7, task L) — the permit state,
## void rules and treasury credit live there; the sale flow lives here.
const AllegianceLib := preload("res://scripts/port/allegiance.gd")

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
			return _delivery_offer(instance_id, port_id, nation_id, day)


## The royal delivery is a guild delivery with the §4.9.4 multipliers, drawn
## from the same deterministic per-(port, day//7) stream.
static func _delivery_offer(instance_id: String, port_id: String,
		nation_id: String, day: int) -> Dictionary:
	var deliveries := QuestGenLib.offers(port_id, day)
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
	return accept_offer(port_id, day, offer(port_id, day))


## [method accept] for an already-built `candidate` (the same offer the screen
## displayed, so a screen click and a test accept the identical instance).
## §4.1b (added 2026-11-02): the audience must start inside the palace's
## window and charges one hour on success (all-or-nothing: a closed-door call
## returns `{}` untouched).
static func accept_offer(port_id: String, day: int, candidate: Dictionary) -> Dictionary:
	if candidate.is_empty():
		return {}
	if not SailingSimLib.facility_open(port_id, "palace"):
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
	# §4.1b action cost: one hour for the mission audience.
	SailingSimLib.advance_port_hours(1)
	return instance


## Spawns the patrol's target fleets through the Phase-5 fleet seam
## (`60-*` §4.12.3 quest seam), each tagged with the mission id. The
## `privateer` role is the always-contact-hostile warship role
## (`60-*` §4.11.11.2), so the mission plays exactly like the retired
## Phase-2 navy markers: contact opens the battle, the piracy funnel
## charges once at battle start, and the §4.12.4 aftermath credits the
## kill through the quest id.
static func _spawn_patrol(instance: Dictionary, day: int) -> void:
	var fleets_path := "res://scripts/world/npc_fleets.gd"
	if not ResourceLoader.exists(fleets_path):
		return
	DataLoader.ensure_map()
	var module = ResourceLoader.load(fleets_path)
	if module == null or not module.can_instantiate():
		return
	var fleets = module.new({
		"npc_config": DataLoader.npc_config,
		"preset": GameState.npc_preset,
	})
	var nation_id := str((instance["requirements"] as Dictionary)
		.get("nation_id", ""))
	for _index in PATROL_COUNT:
		var marker: Dictionary = fleets.call("spawn", "privateer", nation_id, day)
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
## §4.1b (added 2026-11-02): the audience must start inside the palace window
## and charges one hour.
static func attend_ceremony(port_id: String) -> String:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return ""
	if not SailingSimLib.facility_open(port_id, "palace"):
		return ""
	var rank := FameLib.grant(nation_id)
	if not rank.is_empty():
		SailingSimLib.advance_port_hours(1)
	return rank


# --- Repair bays (docs/70-* §4.9.2 count grant) --------------------------

## The per-point repair cost at `port_id`'s palace bays, after the count-grant
## discount: `ceil(points × ceil(base_price/400) × 0.8)` floored once at the
## end of the whole transaction (`40-*` §4.3 price, then `70-*` §4.9.2).
static func repair_cost(port_id: String, ship_index: int, points: int) -> int:
	var shipyard = _shipyard()
	if shipyard == null:
		return 0
	return int(shipyard.call("repair_cost", ship_index, points, port_id))


## Repairs one hull at the bays, charging [method repair_cost]. Returns the
## points repaired (0 when refused: no damage, no gold, or not a capital).
## The bays walk the shipyard engine's **un-timed** primitive
## (`repair_apply`): the §4.1b bay cost is charged once per fill action by
## the screen, never per hull here.
static func repair(port_id: String, ship_index: int, points: int) -> int:
	if nation_of(port_id).is_empty() or points <= 0:
		return 0
	var shipyard = _shipyard()
	if shipyard == null:
		return 0
	var max_points := int(shipyard.call("max_repair_points", ship_index))
	var actual := mini(points, max_points)
	if actual <= 0:
		return 0
	if not bool(shipyard.call("repair_apply", ship_index, actual, port_id)):
		return 0
	return actual


## The shipyard engine module (rules shared, not re-implemented).
static func _shipyard():
	var path := "res://scripts/port/shipyard_engine.gd"
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path)


# --- Bounty / tournament / retirement edges ------------------------------

## Palace bounty row: pays the nation's bounty (docs/70-* §4.9.5).
## §4.1b (added 2026-11-02): the pay-off is an audience — it must start inside
## the palace window and charges one hour.
static func pay_bounty(port_id: String) -> bool:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return false
	if not SailingSimLib.facility_open(port_id, "palace"):
		return false
	if not BountyLib.pay_off(nation_id):
		return false
	SailingSimLib.advance_port_hours(1)
	return true


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


## Tournament entry at this palace (`70-*` §4.9.7). §4.1b (added 2026-11-02):
## the entry is an audience — palace window guard, one hour on success.
static func tournament_status(port_id: String, day: int) -> Dictionary:
	return TournamentLib.status(port_id, day)


static func enter_tournament(port_id: String, day: int) -> bool:
	if not SailingSimLib.facility_open(port_id, "palace"):
		return false
	if not TournamentLib.enter(port_id, day):
		return false
	SailingSimLib.advance_port_hours(1)
	return true


# --- Tax permits (docs/30-* §4.10, Phase 7; UI contract 80-* §4.7.13) ------
#
# The state (flags, coverage, void rules) is `allegiance.gd`; this section is
# the sale flow: which kind the palace sells, the price/title/rep gates, the
# gold charge and the treasury credit. The screen (task F) renders the offer.

## The permit row at `port_id`'s palace (`{}` when the port has no palace).
## Shape: `{kind, nation_id, price, owned, void_key, title_locked, rep_locked,
## coverage_key}` — all screen-side strings are ui_strings keys from the
## `palace.permit.*` family (the orchestrator-merged inventory).
static func permit_offer(port_id: String) -> Dictionary:
	var nation_id := nation_of(port_id)
	if nation_id.is_empty():
		return {}
	var player := _player_nation()
	var kind := "home" if nation_id == player else "foreign"
	var price := AllegianceLib.PERMIT_HOME_PRICE if kind == "home" \
		else AllegianceLib.PERMIT_FOREIGN_PRICE
	var owned := _permit_owned(kind, nation_id)
	return {
		"kind": kind,
		"nation_id": nation_id,
		"price": price,
		"owned": owned,
		"void_key": AllegianceLib.permit_void_reason(nation_id),
		"title_locked": kind == "foreign"
			and FameLib.rank_index(FameLib.title(nation_id))
				< FameLib.rank_index(FameLib.RANK_KNIGHT),
		"rep_locked": kind == "foreign"
			and CharacterLib.reputation(nation_id)
				< AllegianceLib.PERMIT_FOREIGN_MIN_REP,
		"coverage_key": "palace.permit.home.coverage" if kind == "home"
			else "palace.permit.foreign.coverage",
	}


## True when the player already holds the permit (`palace.permit.*.owned`).
static func _permit_owned(kind: String, nation_id: String) -> bool:
	if kind == "home":
		return AllegianceLib.has_permit_home()
	return AllegianceLib.has_permit_foreign(nation_id)


## Buys the permit this palace sells (home charter at the player's own nation's
## palaces, foreign permit for that nation elsewhere). Refused when there is
## no palace, the permit is already held (non-void), a §4.10 gate locks it, or
## the purse cannot pay. While **void** a re-buy costs the full price. On
## success the price flows to the selling nation's treasury (decision 19).
static func buy_permit(port_id: String) -> bool:
	var offer := permit_offer(port_id)
	if offer.is_empty():
		return false
	if not SailingSimLib.facility_open(port_id, "palace"):
		return false
	if bool(offer["owned"]) and str(offer["void_key"]).is_empty():
		return false
	if bool(offer["title_locked"]) or bool(offer["rep_locked"]):
		return false
	var price := int(offer["price"])
	if GameState.gold < price:
		return false
	GameState.add_gold(-price)
	AllegianceLib.set_permit(str(offer["kind"]), str(offer["nation_id"]))
	AllegianceLib.credit_permit_sale(str(offer["nation_id"]), price)
	# §4.1b action cost: one hour for the permit audience.
	SailingSimLib.advance_port_hours(1)
	return true


# --- Commendation hook (docs/70-* §4.1; UI contract 80-* §4.7.13) -----------
#
# The first time a contestable port flips to the player's nation, the
# allegiance engine queues a one-time commendation (`fame_commended`); the
# palace surface (task F) plays the `palace.commend.*` dialog at the player's
# nation's palaces and dismisses it here. Pull model — no EventBus surface.

## The unshown commendation this palace should play (`{}`, or
## `{port_id, nation_id}` — both i18n names are the screen's to resolve).
static func pending_commendation(port_id: String) -> Dictionary:
	if nation_of(port_id) != _player_nation() or _player_nation().is_empty():
		return {}
	return AllegianceLib.pending_commendation()


## Dismisses the pending commendation after the dialog played.
static func dismiss_commendation() -> void:
	AllegianceLib.mark_commendation_shown()


## The player's nation id (`""` before a run exists).
static func _player_nation() -> String:
	return str(GameState.player.get("nation_id", ""))
