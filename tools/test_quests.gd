extends Node
## Phase-3 task B acceptance tests: guild activation + quest system
## (docs/IMPLEMENT-Phase3.md B; docs/70-* §4.2, §4.3, §4.9.3; docs/10-* §4.8;
## docs/30-* §4.1; docs/80-* §4.1, §4.2).
##
##   godot --headless --path . tools/test_quests.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const GuildScene := preload("res://scenes/port/guild_screen.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")
const WorldScene := preload("res://scenes/world/world_map.tscn")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_deterministic_offers()
	_test_offer_shapes()
	_test_offer_lifecycle()
	_test_accept()
	_test_slots()
	_test_delivery_completion()
	_test_delivery_failure()
	_test_expiry()
	_test_exploration_completion()
	_test_bounty_completion()
	await _test_guild_screen()
	await _test_port_hub_activation()
	await _test_world_hooks()
	_report()


# --- Fixtures -------------------------------------------------------------

func _new_run(port_id: String = "lisbon", day: int = 12) -> void:
	GameState.new_game("portugal", false, "p3")
	GameState.day = day
	GameState.gold = 5000
	GameState.current_port = port_id
	# Keep the hold clear so delivery acceptance can always take the goods.
	for ship in GameState.fleet:
		(ship as Dictionary)["cargo"] = {}
		(ship as Dictionary)["provisions"] = 0
		(ship as Dictionary)["water"] = 0


func _clear_quests() -> void:
	GameState.active_quests = []


# --- 1. Seeded offers are deterministic per (port, week) -----------------

func _test_deterministic_offers() -> void:
	_new_run("lisbon", 12)
	var a: Array = QuestGenLib.offers("lisbon", 12)
	var b: Array = QuestGenLib.offers("lisbon", 12)
	_check(str(a) == str(b), "the same (port, day) yields the same offers")
	_check(a.size() == 3, "a guild lists 3 offers (got %d)" % a.size())
	# Within one week the list is stable …
	var same_week: Array = QuestGenLib.offers("lisbon", 13)
	_check(_ids(a) == _ids(same_week),
		"the offer list is stable across a week (day 12 vs 13)")
	# … and the next week differs.
	var next_week: Array = QuestGenLib.offers("lisbon", 19)
	_check(_ids(a) != _ids(next_week),
		"the offer list changes next week (day 12 vs 19)")
	_check(int(a[0].get("instance_id", "").split("_")[-1]) == 0,
		"slot 0 is the first delivery (got %s)" % str(a[0].get("instance_id")))
	_check(str(a[0].get("type", "")) == "delivery",
		"slot 0 is always a delivery (got %s)" % str(a[0].get("type")))
	# The seed is the documented formula.
	var port_ordinal := QuestGenLib.port_ordinal("lisbon")
	_check(QuestGenLib.offer_seed("lisbon", 12)
		== (12 / 7) * QuestGenLib.SEED_WEEK_MULT \
			+ port_ordinal * QuestGenLib.SEED_PORT_MULT,
		"offer_seed() is (day//7)*1000003 + port_ordinal*7919")
	_check(QuestGenLib.offer_seed("lisbon", 12) != QuestGenLib.offer_seed("tunis", 12),
		"different ports seed different lists")
	_check(QuestGenLib.next_refresh_day(12) == 14,
		"the next refresh after day 12 is day 14 (got %d)"
		% QuestGenLib.next_refresh_day(12))


# --- 2. Offer shape and reward bands -------------------------------------

func _test_offer_shapes() -> void:
	_new_run("lisbon", 12)
	# Scan many weeks so every type shows up.
	var types := {}
	var bad_delivery: Array = []
	var bad_band: Array = []
	for week in range(0, 60):
		var day := week * 7 + 1
		for offer in QuestGenLib.offers("lisbon", day):
			var o: Dictionary = offer
			types[str(o.get("type", ""))] = true
			if str(o["type"]) == "delivery":
				var req: Dictionary = o["requirements"]
				var quantity := int(req.get("quantity", 0))
				var good_id := str(req.get("good_id", ""))
				var base := int(DataLoader.get_good(good_id).get("base_price", 0))
				if not (quantity in [20, 30, 40, 50]):
					bad_delivery.append("qty %d" % quantity)
				if int(req.get("dest_port_id", "").length()) == 0:
					bad_delivery.append("no dest")
				if str(req.get("dest_port_id", "")) == "lisbon":
					bad_delivery.append("dest == origin")
				if int(((o["rewards"] as Dictionary)).get("gold", 0)) \
						!= 2 * base * quantity:
					bad_band.append("gold %s vs %d"
						% [str((o["rewards"] as Dictionary).get("gold")),
							2 * base * quantity])
				if int(((o["rewards"] as Dictionary)).get("fame", 0)) != 10:
					bad_band.append("delivery fame")
			elif str(o["type"]) == "bounty":
				var tier := int((o["requirements"] as Dictionary).get("tier", 0))
				if not (tier in [1, 2, 3]):
					bad_band.append("bounty tier %d" % tier)
				if int(((o["rewards"] as Dictionary)).get("gold", 0)) \
						!= {1: 5000, 2: 10000, 3: 20000}.get(tier, -1):
					bad_band.append("bounty gold")
				if int(((o["rewards"] as Dictionary)).get("fame", 0)) != 15:
					bad_band.append("bounty fame")
				if int(o.get("expiry_days", 0)) != 30:
					bad_band.append("bounty expiry")
			elif str(o["type"]) == "exploration":
				if str((o["requirements"] as Dictionary).get("discovery_id", "")).is_empty():
					bad_band.append("exploration id")
				if int(((o["rewards"] as Dictionary)).get("fame", 0)) != 10:
					bad_band.append("exploration fame")
	_check(types.has("delivery") and types.has("bounty") and types.has("exploration"),
		"all three guild types appear over 60 weeks (got %s)" % str(types.keys()))
	_check(bad_delivery.is_empty(),
		"every delivery draw is in the pinned bands (%s)" % str(bad_delivery.slice(0, 4)))
	_check(bad_band.is_empty(),
		"every reward band matches §4.9.3 to the gold (%s)" % str(bad_band.slice(0, 4)))
	# A delivery destination is on the map and in the pinned distance band.
	var offer: Dictionary = QuestGenLib.offers("lisbon", 1)[0]
	var origin: Dictionary = DataLoader.get_port("lisbon")
	var dest: Dictionary = DataLoader.get_port(
		str((offer["requirements"] as Dictionary)["dest_port_id"]))
	var from := Vector2i(int((origin["position"] as Dictionary)["x"]),
		int((origin["position"] as Dictionary)["y"]))
	var to := Vector2i(int((dest["position"] as Dictionary)["x"]),
		int((dest["position"] as Dictionary)["y"]))
	var distance := maxi(absi(from.x - to.x), absi(from.y - to.y))
	_check(distance >= 3 and distance <= 60,
		"the delivery distance is inside [3, 60] (got %d)" % distance)
	_check(int(offer.get("expiry_days", 0)) >= 7 and int(offer.get("expiry_days", 0)) <= 30,
		"the delivery expiry is inside [7, 30] (got %d)" % int(offer.get("expiry_days", 0)))


# --- 3. Offers are derived; accepting removes them -----------------------

func _test_offer_lifecycle() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	var before: Array = QuestGenLib.available_offers("lisbon", 12)
	_check(before.size() == 3, "3 offers are available before accepting")
	var accepted: Dictionary = QuestGenLib.accept(before[0], "lisbon", 12)
	_check(not accepted.is_empty(), "the first offer is accepted")
	_check(GameState.active_quests.size() == 1,
		"the accepted quest is stored in active_quests")
	var after: Array = QuestGenLib.available_offers("lisbon", 12)
	_check(_ids(after).size() == 2, "the accepted offer leaves the list (got %d)"
		% _ids(after).size())
	_check(not _ids(after).has(str(accepted.get("instance_id", ""))),
		"the accepted instance id is no longer offered")
	_check(int(accepted.get("accepted_day", 0)) == 12,
		"the instance records its accepted day")
	_check(int(accepted.get("deadline_day", 0))
		== 12 + int(accepted.get("expiry_days", 0)),
		"the deadline is accepted_day + expiry_days")


# --- 4. Acceptance moves the delivery goods -----------------------------

func _test_accept() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	GameState.gold = 1000
	var offer: Dictionary = QuestGenLib.offers("lisbon", 12)[0]
	var req: Dictionary = offer["requirements"]
	var good_id := str(req["good_id"])
	var quantity := int(req["quantity"])
	_check(FleetLib.held(good_id) == 0, "the hold starts empty of %s" % good_id)
	var accepted: Dictionary = QuestGenLib.accept(offer, "lisbon", 12)
	_check(not accepted.is_empty(), "the delivery offer is accepted")
	_check(FleetLib.held(good_id) == quantity,
		"accepting puts %d %s in the hold (got %d)"
		% [quantity, good_id, FleetLib.held(good_id)])
	_check(GameState.gold == 1000,
		"the delivery goods are granted free (gold unchanged)")
	var reward := int((accepted["rewards"] as Dictionary)["gold"])
	_check(reward == 2 * int(DataLoader.get_good(good_id)["base_price"]) * quantity,
		"the reward is 2 × base_price × quantity (got %d)" % reward)

	# A full hold refuses the offer without changing anything.
	_new_run("lisbon", 12)
	_clear_quests()
	var container: Dictionary = GameState.fleet[0]
	container["cargo"] = {}
	container["provisions"] = 0
	container["water"] = 0
	# Fill the hold with a good the offer does not use.
	var fill_id := "amber"
	var free := FleetLib.fleet_free()
	FleetLib.add_goods(fill_id, free)
	_check(FleetLib.fleet_free() == 0, "the hold is full for the refusal check")
	var blocked: Dictionary = QuestGenLib.offers("lisbon", 12)[0]
	_check(QuestGenLib.accept_block_reason(blocked) == "quest.no_hold",
		"a full hold reports quest.no_hold")
	_check(QuestGenLib.accept(blocked, "lisbon", 12).is_empty(),
		"a full hold refuses the delivery")
	_check(GameState.active_quests.is_empty(), "a refused offer stores nothing")


# --- 5. The slot cap and the viscount grant -----------------------------

func _test_slots() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	_check(QuestGenLib.max_active_quests() == 3,
		"the base slot cap is 3 (got %d)" % QuestGenLib.max_active_quests())
	# Fill the three slots (with exploration offers that take no cargo).
	var filled := 0
	for week in range(0, 20):
		var day := week * 7 + 1
		for offer in QuestGenLib.offers("lisbon", day):
			if filled >= 3:
				break
			if str((offer as Dictionary)["type"]) == "bounty":
				continue
			if QuestGenLib.accept(offer, "lisbon", day).is_empty():
				# A delivery may need hold space; skip and try the next.
				continue
			filled += 1
	_check(QuestGenLib.active_count() == 3,
		"three quests can be active (got %d)" % QuestGenLib.active_count())
	var fourth: Dictionary = {}
	for week in range(0, 20):
		for offer in QuestGenLib.offers("lisbon", week * 7 + 1):
			if QuestGenLib.accept_block_reason(offer) == "quest.slots_full":
				fourth = offer
				break
		if not fourth.is_empty():
			break
	_check(QuestGenLib.accept_block_reason(fourth) == "quest.slots_full",
		"a fourth quest reports quest.slots_full")
	_check(QuestGenLib.accept(fourth, "lisbon", 12).is_empty(),
		"a fourth quest is refused")
	# Viscount (any nation) grants the extra slot.
	GameState.titles["spain"] = "viscount"
	_check(QuestGenLib.max_active_quests() == 4,
		"a viscount title raises the cap to 4 (got %d)"
		% QuestGenLib.max_active_quests())
	GameState.titles["spain"] = "count"
	_check(QuestGenLib.max_active_quests() == 4, "count keeps the extra slot")
	GameState.titles["spain"] = "none"
	_check(QuestGenLib.max_active_quests() == 3, "dropping the title restores 3")


# --- 6. Delivery completion ---------------------------------------------

func _test_delivery_completion() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	var offer: Dictionary = QuestGenLib.offers("lisbon", 12)[0]
	var req: Dictionary = offer["requirements"]
	var dest := str(req["dest_port_id"])
	var nation := str(DataLoader.get_port(dest)["nation_id"])
	var accepted: Dictionary = QuestGenLib.accept(offer, "lisbon", 12)
	var gold_before := GameState.gold
	var fame_before := GameState.fame
	var rep_before := CharacterLib.reputation(nation)
	var reward := int((accepted["rewards"] as Dictionary)["gold"])

	# Nothing completes at the wrong port.
	_check(QuestGenLib.complete_delivery_quests("madeira").is_empty(),
		"a delivery does not complete at the wrong port")
	_check(GameState.gold == gold_before, "no reward is paid early")

	var done: Array = QuestGenLib.complete_delivery_quests(dest)
	_check(done.size() == 1, "the delivery completes at its destination (got %d)"
		% done.size())
	_check(GameState.gold == gold_before + reward,
		"the delivery pays exactly its reward (%d → %d, expected +%d)"
		% [gold_before, GameState.gold, reward])
	_check(FleetLib.held(str(req["good_id"])) == 0,
		"the delivered goods leave the hold")
	_check(GameState.fame == fame_before + 10,
		"the delivery grants +10 fame (got +%d)" % (GameState.fame - fame_before))
	_check(CharacterLib.reputation(nation) == rep_before + 5,
		"the delivery grants +5 rep with the destination nation")
	_check(str((done[0] as Dictionary).get("status", "")) == "completed",
		"the instance is marked completed")
	_check(QuestGenLib.active_count() == 0, "a completed quest frees its slot")


# --- 7. Delivery failure (cargo sold / jettisoned) ----------------------

func _test_delivery_failure() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	var offer: Dictionary = QuestGenLib.offers("lisbon", 12)[0]
	var req: Dictionary = offer["requirements"]
	var accepted: Dictionary = QuestGenLib.accept(offer, "lisbon", 12)
	var origin_nation := str(DataLoader.get_port("lisbon")["nation_id"])
	var rep_before := CharacterLib.reputation(origin_nation)
	var fame_before := GameState.fame
	var gold_before := GameState.gold

	# Sell the cargo out from under the quest.
	FleetLib.remove_goods(str(req["good_id"]), int(req["quantity"]))
	_check(QuestGenLib.delivery_cargo_lost(accepted),
		"a delivery whose cargo is gone reports cargo_lost")
	var failed: Array = QuestGenLib.tick(12)
	_check(failed.size() == 1, "the day tick fails the cargo-less delivery")
	_check(CharacterLib.reputation(origin_nation) == rep_before - 5,
		"the failure costs −5 rep with the origin nation (got %d)"
		% CharacterLib.reputation(origin_nation))
	_check(GameState.fame == fame_before, "the failure grants no fame")
	_check(GameState.gold == gold_before, "the failure grants no gold")
	_check(str((failed[0] as Dictionary).get("status", "")) == "failed",
		"the instance is marked failed")
	# A failed quest is never failed twice.
	_check(QuestGenLib.tick(12).is_empty(), "a failed quest is not failed again")

	# Abandoning uses the same path.
	_new_run("lisbon", 12)
	_clear_quests()
	var second: Dictionary = QuestGenLib.accept(
		QuestGenLib.offers("lisbon", 12)[2], "lisbon", 12)
	_check(not second.is_empty(), "a second offer is accepted for the abandon test")
	_check(QuestGenLib.abandon(second), "abandon() fails the quest")
	_check(str(second.get("status", "")) == "failed", "the abandoned quest is failed")


# --- 8. Expiry -----------------------------------------------------------

func _test_expiry() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	var offer: Dictionary = QuestGenLib.offers("lisbon", 12)[0]
	var accepted: Dictionary = QuestGenLib.accept(offer, "lisbon", 12)
	var deadline := int(accepted["deadline_day"])
	# Give the cargo back so only the clock can fail it.
	_check(not QuestGenLib.is_expired(accepted, deadline),
		"a quest is alive on its deadline day (§4.9.3 uses day > deadline)")
	_check(QuestGenLib.is_expired(accepted, deadline + 1),
		"a quest expires the day after its deadline")
	var origin_nation := str(DataLoader.get_port("lisbon")["nation_id"])
	var rep_before := CharacterLib.reputation(origin_nation)
	var failed: Array = QuestGenLib.tick(deadline + 1)
	_check(failed.size() == 1, "the tick fails the expired quest")
	_check(CharacterLib.reputation(origin_nation) == rep_before - 5,
		"an expired delivery still costs −5 rep")
	_check(FleetLib.held(str((offer["requirements"] as Dictionary)["good_id"])) > 0,
		"expiry does not reclaim the goods (§4.9.3)")


# --- 9. Exploration completion ------------------------------------------

func _test_exploration_completion() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	# Find an exploration offer in any week at a port that has discoveries near.
	var chosen: Dictionary = {}
	for week in range(0, 200):
		for offer in QuestGenLib.offers("lisbon", week * 7 + 1):
			if str((offer as Dictionary)["type"]) == "exploration":
				chosen = offer
				break
		if not chosen.is_empty():
			break
	_check(not chosen.is_empty(), "an exploration offer is found in 200 weeks")
	var discovery_id := str((chosen["requirements"] as Dictionary)["discovery_id"])
	var accepted: Dictionary = QuestGenLib.accept(chosen, "lisbon", 12)
	_check(not accepted.is_empty(), "the exploration offer is accepted")
	# The quest reveals the hint free.
	_check(not (DataLoader.get_discovery(discovery_id).get("region_hint", {}) as Dictionary).is_empty(),
		"the exploration quest carries a real hint")
	var fame_before := GameState.fame
	var done: Array = QuestGenLib.complete_exploration_quests(discovery_id)
	_check(done.size() == 1, "reporting the discovery completes the quest")
	_check(GameState.fame == fame_before + 10,
		"the exploration quest grants +10 fame on top of the report")
	_check(str((done[0] as Dictionary).get("status", "")) == "completed", "marked completed")


# --- 10. Bounty completion ----------------------------------------------

func _test_bounty_completion() -> void:
	_new_run("lisbon", 1)
	_clear_quests()
	GameState.hostile_fleets = []
	# Find a bounty offer.
	var chosen: Dictionary = {}
	for week in range(0, 60):
		for offer in QuestGenLib.offers("lisbon", week * 7 + 1):
			if str((offer as Dictionary)["type"]) == "bounty":
				chosen = offer
				break
		if not chosen.is_empty():
			break
	_check(not chosen.is_empty(), "a bounty offer is found in 60 weeks")
	GameState.day = 1
	var accepted: Dictionary = QuestGenLib.accept(chosen, "lisbon", 1)
	_check(not accepted.is_empty(), "the bounty offer is accepted")
	var target_id := str((accepted["requirements"] as Dictionary)
		.get("target_fleet_id", ""))
	_check(target_id is String and not target_id.is_empty(),
		"accepting spawns a target fleet (got '%s')" % str(target_id))
	var spawned := false
	for marker in GameState.hostile_fleets:
		if str((marker as Dictionary).get("id", "")) == target_id:
			spawned = true
			_check(str((marker as Dictionary).get("quest_id", ""))
				== str(accepted["instance_id"]),
				"the marker is tagged with its quest id")
			break
	_check(spawned, "the target fleet is a normal hostile marker")
	var gold_before := GameState.gold
	var fame_before := GameState.fame
	var reward := int((accepted["rewards"] as Dictionary)["gold"])
	var done: Array = QuestGenLib.complete_bounty_quests(target_id)
	_check(done.size() == 1, "a victory against the target completes the bounty")
	_check(GameState.gold == gold_before + reward,
		"the bounty pays its tier reward (%d)" % reward)
	_check(GameState.fame == fame_before + 15, "the bounty grants +15 fame")
	# A different fleet id does nothing.
	_new_run("lisbon", 1)
	_clear_quests()
	var again: Dictionary = QuestGenLib.accept(chosen, "lisbon", 1)
	_check(QuestGenLib.complete_bounty_quests("hf_999_1_1_pirate").is_empty(),
		"an unrelated fleet id does not complete the bounty")


# --- 11. The guild screen renders the system ----------------------------

func _test_guild_screen() -> void:
	_new_run("lisbon", 12)
	_clear_quests()
	GameState.discoveries_found = ["disc_atlas_cedars"]
	GameState.discoveries_reported = []
	var screen: Control = GuildScene.instantiate()
	screen.route_to_port = false
	add_child(screen)
	await get_tree().process_frame
	_check(screen.port_id() == "lisbon", "the guild screen binds the docked port")
	_check(screen.offer_rows().size() == 3,
		"the guild screen lists 3 offers (got %d)" % screen.offer_rows().size())
	_check(screen.report_rows().size() == 1,
		"the guild screen lists 1 unreported discovery (got %d)"
		% screen.report_rows().size())
	# Accepting through the screen stores the quest.
	var before := GameState.active_quests.size()
	var acc = screen.accept_offer(0)
	_check(not acc.is_empty(), "the screen accepts offer 0")
	_check(GameState.active_quests.size() == before + 1,
		"the screen's accept stores the quest")
	_check(screen.offer_rows().size() == 2,
		"the accepted offer leaves the screen's list")
	# An empty list states the real reason (docs/80-* §4.7.3).
	var empty_label: Label = screen.get_node("Layout/VBox/Offers/Empty")
	_check(not empty_label.visible, "the empty line stays hidden while offers exist")
	# Fill every slot: the list empties and the line names the slot cap.
	screen.refresh()
	while screen.offer_rows().size() > 0:
		if screen.accept_offer(0).is_empty():
			break
	GameState.day = 12
	var third: Dictionary = {"instance_id": "q_synth_slot", "type": "exploration",
		"giver": "guild", "origin_port_id": "lisbon",
		"requirements": {"discovery_id": "disc_atlas_cedars"},
		"rewards": {}, "expiry_days": 30, "accepted_day": 12,
		"deadline_day": 42, "status": "active"}
	while QuestGenLib.active_count() < QuestGenLib.max_active_quests():
		GameState.active_quests.append(third.duplicate(true))
	screen.refresh()
	_check(screen.offer_rows().is_empty(), "a full slot bar empties the offers list")
	_check(empty_label.visible and empty_label.text
		== I18n.t_key("quest.slots_full"),
		"the empty line names the slot cap (%s)" % empty_label.text)
	GameState.active_quests = []
	# Reporting through the screen pays out.
	var gold_before := GameState.gold
	var report_block = screen.report_discovery("disc_atlas_cedars")
	_check(report_block is Dictionary and not (report_block as Dictionary).is_empty(),
		"the screen reports the discovery (got %s)" % str(report_block))
	_check(GameState.gold == gold_before + 2000,
		"the report pays the discovery's gold (got +%d)" % (GameState.gold - gold_before))
	_check(screen.report_rows().is_empty(),
		"the reported discovery leaves the report list")
	# No raw key leaks in either locale.
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		var leaked: Array = []
		for line in screen.all_text():
			if str(line).contains("<") and str(line).contains(">"):
				leaked.append(str(line))
		_check(leaked.is_empty(), "no raw <key> on the guild screen (%s): %s"
			% [locale, str(leaked.slice(0, 3))])
	I18n.set_locale("en")
	screen.queue_free()
	await get_tree().process_frame


# --- 12. The port hub activates guild and palace ------------------------

func _test_port_hub_activation() -> void:
	_new_run("lisbon", 12)
	var hub: Control = PortScene.instantiate()
	hub.route_to_world = false
	hub.route_to_facility = false
	add_child(hub)
	await get_tree().process_frame
	_check(hub.is_facility_enabled("guild"),
		"the guild row is enabled at Phase 3 (docs/30-* §4.1)")
	_check(hub.is_facility_enabled("palace"),
		"the palace row is enabled at a capital")
	_check(hub.open_facility("guild"), "the hub opens the guild")
	_check(not hub.is_facility_enabled("nope"), "an unknown facility has no row")
	hub.queue_free()
	await get_tree().process_frame
	# A non-capital port has no palace row at all.
	_new_run("madeira", 12)
	var hub2: Control = PortScene.instantiate()
	hub2.route_to_world = false
	hub2.route_to_facility = false
	add_child(hub2)
	await get_tree().process_frame
	_check(not hub2.facility_row_ids().has("palace"),
		"a non-capital port has no palace row")
	_check(hub2.is_facility_enabled("guild"), "a non-capital port still has a guild")
	hub2.queue_free()
	await get_tree().process_frame


# --- The world-map hooks (docs/70-* §4.9.3) -----------------------------

## Both documented scene hooks are wired: a delivery completes on **port entry**
## (through `world_map._enter_port`) and a delivery whose cargo disappears fails
## immediately on the **cargo mutation** (through the `fleet_changed` funnel),
## not only at the next day tick.
func _test_world_hooks() -> void:
	# 1. Port entry completes the delivery and queues the report dialog.
	_new_run("lisbon", 12)
	_clear_quests()
	var offer: Dictionary = QuestGenLib.offers("lisbon", 12)[0]
	var req: Dictionary = offer["requirements"]
	var dest := str(req["dest_port_id"])
	var accepted: Dictionary = QuestGenLib.accept(offer, "lisbon", 12)
	_check(not accepted.is_empty(), "a delivery is accepted for the world hook")
	GameState.current_port = null
	GameState.day = 12
	# Stand on the destination harbor tile and let the map's own `_enter_port`
	# sequence run (routing disabled: no scene swap).
	var dest_port: Dictionary = DataLoader.get_port(dest)
	var cell := Vector2i(int((dest_port["position"] as Dictionary)["x"]),
		int((dest_port["position"] as Dictionary)["y"]))
	GameState.set_world_tile(cell)
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	var gold_before := GameState.gold
	world._enter_port(dest)
	await get_tree().process_frame
	_check(str(accepted.get("status", "")) == "completed",
		"entering the destination completes the delivery (%s)"
		% str(accepted.get("status")))
	_check(GameState.gold > gold_before,
		"the delivery reward was paid on port entry (+%d)"
		% (GameState.gold - gold_before))
	_check(GameState.current_port == dest, "the map docked at the destination")
	world.queue_free()
	await get_tree().process_frame

	# 2. Selling the cargo mid-route fails the quest immediately.
	_new_run("lisbon", 12)
	_clear_quests()
	offer = QuestGenLib.offers("lisbon", 12)[0]
	req = offer["requirements"]
	var origin_nation := str(DataLoader.get_port("lisbon")["nation_id"])
	accepted = QuestGenLib.accept(offer, "lisbon", 12)
	var rep_before := CharacterLib.reputation(origin_nation)
	world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	# The screen-free path a sale takes (`Fleet.remove_goods` + notify).
	FleetLib.remove_goods(str(req["good_id"]), int(req["quantity"]))
	FleetLib.notify_changed()
	await get_tree().process_frame
	_check(str(accepted.get("status", "")) == "failed",
		"losing the cargo fails the delivery at once (%s)"
		% str(accepted.get("status")))
	_check(CharacterLib.reputation(origin_nation) == rep_before - 5,
		"the immediate failure costs −5 rep (%d → %d)"
		% [rep_before, CharacterLib.reputation(origin_nation)])
	var dialog_text := ""
	if world.hud() != null and world.hud().current_dialog() != null:
		dialog_text = world.hud().current_dialog().message_text()
	# `quest.failed` is "Commission failed: {name}"; the prefix alone proves the
	# right key was used without pinning the composed objective text.
	var failed_prefix := I18n.fmt("quest.failed", {"name": ""}).strip_edges()
	_check(dialog_text.contains(failed_prefix.rstrip(" :：")) ,
		"the failure is reported in a dialog (%s)" % dialog_text)
	world.queue_free()
	await get_tree().process_frame
	GameState.active_quests = []


# --- Helpers --------------------------------------------------------------

func _ids(offers: Array) -> Array:
	var out: Array = []
	for offer in offers:
		out.append(str((offer as Dictionary).get("instance_id", "")))
	return out


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
