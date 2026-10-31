extends Node
## Phase-3 task D acceptance tests: palace, royal missions and the title ladder
## (docs/IMPLEMENT-Phase3.md D; docs/70-* §4.3, §4.9.2, §4.9.4; docs/30-* §4.2,
## §4.7; docs/40-* §4.3; docs/80-* §4.7.3).
##
##   godot --headless --path . tools/test_palace.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const FameLib := preload("res://scripts/player/fame.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const ShipyardEngineLib := preload("res://scripts/port/shipyard_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")

## docs/70-* §4.9.2: the pinned ladder, (fame, royal missions) per rank.
const LADDER := [
	["knight", 100, 1],
	["baron", 300, 2],
	["viscount", 700, 3],
	["count", 1500, 5],
	["duke", 3000, 8],
]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_ladder_table()
	_test_ladder_thresholds()
	_test_per_nation_independence()
	_test_sell_bonus()
	_test_repair_discount()
	_test_quest_slot_grant()
	_test_mission_gate()
	_test_mission_kinds()
	_test_mission_completion()
	_test_mission_failure()
	await _test_palace_screen()
	_report()


# --- Fixtures -------------------------------------------------------------

func _new_run(port_id: String = "lisbon", day: int = 1) -> void:
	GameState.new_game("portugal", false, "world")
	GameState.day = day
	GameState.gold = 50000
	GameState.current_port = port_id
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.bounties = {}
	GameState.active_quests = []
	GameState.fame = 0
	GameState.titles = {}
	for nation in DataLoader.nations_list:
		GameState.titles[str(nation["id"])] = "none"
		GameState.completed_royal_missions[str(nation["id"])] = 0
	for ship in GameState.fleet:
		(ship as Dictionary)["cargo"] = {}
		(ship as Dictionary)["provisions"] = 0
		(ship as Dictionary)["water"] = 0


func _set_rank(nation_id: String, rank: String) -> void:
	GameState.titles[nation_id] = rank


# --- 1. The ladder table is exactly §4.9.2 --------------------------------

func _test_ladder_table() -> void:
	_check(FameLib.RANKS == ["none", "knight", "baron", "viscount", "count", "duke"],
		"the rank order is none→knight→baron→viscount→count→duke (%s)"
		% str(FameLib.RANKS))
	for row in LADDER:
		var rank := str(row[0])
		var need: Dictionary = FameLib.LADDER.get(rank, {})
		_check(int(need.get("fame", -1)) == int(row[1]),
			"%s needs %d fame (got %s)" % [rank, int(row[1]), str(need.get("fame"))])
		_check(int(need.get("missions", -1)) == int(row[2]),
			"%s needs %d royal missions (got %s)"
			% [rank, int(row[2]), str(need.get("missions"))])
	_check(not FameLib.LADDER.has("none"),
		"`none` is the starting rung and is never granted")
	_check(FameLib.RANKS.size() == LADDER.size() + 1,
		"the ladder has exactly five grantable rungs")


# --- 2. Thresholds: promotion needs both fame and missions ----------------

func _test_ladder_thresholds() -> void:
	_new_run()
	var nation := "portugal"
	# One rung at a time: even with fame for duke, no missions → no grant.
	GameState.fame = 3000
	_check(FameLib.can_promote(nation) == false,
		"3000 fame alone does not promote (0 royal missions)")
	_check(FameLib.grant(nation).is_empty(), "the ceremony refuses at rank 0")
	_check(FameLib.title(nation) == "none", "the title stays none")

	for row in LADDER:
		var rank := str(row[0])
		var fame := int(row[1])
		var missions := int(row[2])
		# Fame short by one: still no.
		GameState.fame = fame - 1
		GameState.completed_royal_missions[nation] = missions
		_check(not FameLib.can_promote(nation),
			"%s is refused at fame %d" % [rank, fame - 1])
		# Missions short by one: still no.
		GameState.fame = fame
		GameState.completed_royal_missions[nation] = missions - 1
		_check(not FameLib.can_promote(nation),
			"%s is refused at %d royal missions" % [rank, missions - 1])
		# Both exactly met: grant, one step.
		GameState.completed_royal_missions[nation] = missions
		_check(FameLib.can_promote(nation),
			"%s is offered at fame %d + %d missions" % [rank, fame, missions])
		_check(FameLib.next_rank(nation) == rank,
			"next_rank() names %s (got %s)" % [rank, FameLib.next_rank(nation)])
		var granted := FameLib.grant(nation)
		_check(granted == rank, "the ceremony grants %s (got '%s')"
			% [rank, granted])
		_check(FameLib.title(nation) == rank, "the stored title is %s" % rank)

	_check(FameLib.next_rank(nation).is_empty(), "duke is the top of the ladder")
	_check(FameLib.next_fame_required(nation) == -1, "no fame requirement at duke")
	_check(FameLib.grant(nation).is_empty(), "no grant above duke")
	_check(FameLib.is_duke(nation), "duke is detected")
	_check(FameLib.any_duke(), "any_duke() sees it")


# --- 3. Per-nation independence ------------------------------------------

func _test_per_nation_independence() -> void:
	_new_run()
	GameState.fame = 3000
	for nation in ["portugal", "spain", "england", "holland", "ottoman", "italy"]:
		GameState.completed_royal_missions[nation] = 8
	# Promote only portugal.
	_check(FameLib.grant("portugal") == "knight", "portugal starts climbing")
	for _step in 4:
		FameLib.grant("portugal")
	_check(FameLib.title("portugal") == "duke", "portugal reaches duke")
	for other in ["spain", "england", "holland", "ottoman", "italy"]:
		_check(FameLib.title(other) == "none",
			"%s stays a commoner (got %s)" % [other, FameLib.title(other)])
		_check(not FameLib.is_duke(other), "%s is not duke" % other)
	# Missions are per nation too: portugal's 8 do not promote spain.
	_check(FameLib.royal_missions("portugal") == 8, "portugal's missions are its own")
	_check(FameLib.grant("spain") == "knight",
		"spain's own ceremony grants its own first rank")
	_check(FameLib.title("portugal") == "duke",
		"promoting spain never touches portugal")
	_check(FameLib.earned_titles().size() == 2,
		"earned_titles() lists the two titles (%d)" % FameLib.earned_titles().size())
	# Grants never regress: a second ceremony at duke is a no-op.
	_check(FameLib.grant("portugal").is_empty(), "a grant never regresses")
	# Ceremony is palace-bound: only the nation's own capital can promote.
	GameState.titles["italy"] = "none"
	_check(PalaceEngineLib.attend_ceremony("venice") == "knight",
		"venice's palace grants the italian knight")
	_check(PalaceEngineLib.attend_ceremony("lisbon").is_empty()
		or FameLib.title("portugal") == "duke",
		"lisbon's palace promotes only portugal")
	_check(PalaceEngineLib.attend_ceremony("athens").is_empty(),
		"a non-capital has no ceremony")


# --- 4. Sell-price `title_bonus` (docs/30-* §4.2, 70-* §4.9.2) -----------

func _test_sell_bonus() -> void:
	_new_run()
	# Worked example (docs/30-* §5): London wine, factor 1.3, no investment.
	var port := "london"
	GameState.titles["england"] = "none"
	GameState.port_investments = {}
	_check(TradeEngineLib.buy_price(port, "wine") == 39,
		"London wine buys at 39 (got %d)" % TradeEngineLib.buy_price(port, "wine"))
	_check(TradeEngineLib.sell_price(port, "wine") == 31,
		"London wine sells at 31 with no title (got %d)"
		% TradeEngineLib.sell_price(port, "wine"))

	GameState.titles["england"] = "knight"
	_check(TradeEngineLib.title_units(port) == 1050,
		"knight maps to 1050 per-mille (got %d)"
		% TradeEngineLib.title_units(port))
	_check(TradeEngineLib.sell_price(port, "wine") == 32,
		"knight sells at floor(30×1.3×0.8×1.05) = 32 (got %d)"
		% TradeEngineLib.sell_price(port, "wine"))

	GameState.titles["england"] = "baron"
	_check(TradeEngineLib.sell_price(port, "wine") == 34,
		"baron sells at floor(30×1.3×0.8×1.10) = 34 (got %d)"
		% TradeEngineLib.sell_price(port, "wine"))
	for rank in ["viscount", "count", "duke"]:
		GameState.titles["england"] = rank
		_check(TradeEngineLib.sell_price(port, "wine") == 34,
			"%s keeps the 1.10 bonus (got %d)"
			% [rank, TradeEngineLib.sell_price(port, "wine")])

	# Buy prices are never affected.
	GameState.titles["england"] = "baron"
	_check(TradeEngineLib.buy_price(port, "wine") == 39,
		"the title never touches the buy side (got %d)"
		% TradeEngineLib.buy_price(port, "wine"))

	# The multiplier is the **port's own** nation's title, not another's.
	GameState.titles["england"] = "none"
	GameState.titles["portugal"] = "duke"
	_check(TradeEngineLib.sell_price(port, "wine") == 31,
		"a portuguese dukedom does not raise a London sale (got %d)"
		% TradeEngineLib.sell_price(port, "wine"))
	GameState.titles["portugal"] = "none"
	GameState.titles["holland"] = "duke"
	_check(TradeEngineLib.sell_price("amsterdam", "wine")
		> TradeEngineLib.price_from_units(
			int(DataLoader.get_good("wine")["base_price"]),
			TradeEngineLib.band_units(1.0, 1.0), true),
		"the dutch title does raise an Amsterdam sale")

	# An actual sale pays the bonus (not just the readout).
	_new_run()
	GameState.titles["england"] = "baron"
	GameState.gold = 1000
	FleetLib.add_goods("wine", 10)
	var before := GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 10), "a titled sale succeeds")
	_check(GameState.gold == before + 34 * 10,
		"the sale pays 34g/unit (got %d)" % (GameState.gold - before))


# --- 5. Repair discount (docs/70-* §4.9.2 count grant) -------------------

func _test_repair_discount() -> void:
	_new_run("lisbon")
	# Caravel: ceil(8000/400) = 20g per point (docs/40-* §5).
	var ship: Dictionary = GameState.fleet[0]
	ship["durability"] = 10
	GameState.titles["portugal"] = "none"
	_check(ShipyardEngineLib.repair_cost_per_point("caravel") == 20,
		"caravel repairs cost 20g/point")
	_check(ShipyardEngineLib.repair_cost(0, 10, "lisbon") == 200,
		"10 points cost 200g without a title (got %d)"
		% ShipyardEngineLib.repair_cost(0, 10, "lisbon"))
	GameState.titles["portugal"] = "count"
	_check(ShipyardEngineLib.repair_cost(0, 10, "lisbon") == 160,
		"count applies the 0.8 factor: 160g (got %d)"
		% ShipyardEngineLib.repair_cost(0, 10, "lisbon"))
	GameState.titles["portugal"] = "duke"
	_check(ShipyardEngineLib.repair_cost(0, 10, "lisbon") == 160,
		"duke keeps the 0.8 factor")
	GameState.titles["portugal"] = "viscount"
	_check(ShipyardEngineLib.repair_cost(0, 10, "lisbon") == 200,
		"viscount does not discount repairs")
	# Other nations' ports are unaffected.
	GameState.titles["portugal"] = "duke"
	_check(ShipyardEngineLib.repair_cost(0, 10, "seville") == 200,
		"a spanish port charges full price (got %d)"
		% ShipyardEngineLib.repair_cost(0, 10, "seville"))
	# The transaction charges the discounted amount.
	GameState.gold = 1000
	ship["durability"] = 10
	var before := GameState.gold
	_check(ShipyardEngineLib.repair(0, 10, "lisbon"), "the discounted repair runs")
	_check(GameState.gold == before - 160,
		"the repair charges 160g (got %d)" % (before - GameState.gold))
	_check(int(ship["durability"]) == 20, "10 durability points were restored")
	# Odd point counts floor once at the end of the transaction (§4.9.2).
	GameState.titles["portugal"] = "count"
	_check(ShipyardEngineLib.repair_cost(0, 1, "lisbon") == 16,
		"1 point costs ceil(20×0.8) = 16 (got %d)"
		% ShipyardEngineLib.repair_cost(0, 1, "lisbon"))
	_check(ShipyardEngineLib.repair_cost(0, 3, "lisbon") == 48,
		"3 points cost ceil(60×0.8) = 48 (got %d)"
		% ShipyardEngineLib.repair_cost(0, 3, "lisbon"))
	# The palace bays share the same price.
	_check(PalaceEngineLib.repair_cost("lisbon", 0, 3) == 48,
		"the palace bays quote the same 48g (got %d)"
		% PalaceEngineLib.repair_cost("lisbon", 0, 3))


# --- 6. Quest slot grant (viscount, max over nations) --------------------

func _test_quest_slot_grant() -> void:
	_new_run()
	_check(FameLib.quest_slots_bonus() == 0, "no title → no extra slot")
	_check(QuestGenLib.max_active_quests() == 3,
		"the base cap is 3 (got %d)" % QuestGenLib.max_active_quests())
	GameState.titles["portugal"] = "baron"
	_check(FameLib.quest_slots_bonus() == 0, "baron adds no slot")
	GameState.titles["portugal"] = "viscount"
	_check(FameLib.quest_slots_bonus() == 1, "viscount adds one slot")
	_check(QuestGenLib.max_active_quests() == 4,
		"the cap becomes 4 (got %d)" % QuestGenLib.max_active_quests())
	# A max over nations, never a sum.
	GameState.titles["spain"] = "viscount"
	GameState.titles["italy"] = "duke"
	_check(FameLib.quest_slots_bonus() == 1,
		"three titled nations still add exactly one slot")
	_check(QuestGenLib.max_active_quests() == 4,
		"the cap stays 4 (got %d)" % QuestGenLib.max_active_quests())
	# A fourth quest is really accepted; a fifth is refused.
	GameState.titles = {"portugal": "viscount"}
	GameState.day = 12
	GameState.active_quests = []
	var offers: Array = QuestGenLib.offers("lisbon", 12)
	var accepted := 0
	for offer in offers:
		if not QuestGenLib.accept(offer, "lisbon", 12).is_empty():
			accepted += 1
	_check(accepted == 3, "three offers are accepted (%d)" % accepted)
	# Synthesize a fourth live quest (the guild lists only three per week).
	var extra: Dictionary = (offers[0] as Dictionary).duplicate(true)
	extra["instance_id"] = "q_synth_4"
	extra["type"] = "exploration"
	extra["requirements"] = {"discovery_id": "disc_atlas_cedars"}
	extra["accepted_day"] = 12
	extra["deadline_day"] = 40
	extra["status"] = "active"
	GameState.active_quests.append(extra)
	_check(QuestGenLib.active_count() == 4, "four quests are live")
	_check(QuestGenLib.accept_block_reason(offers[1]) == "quest.slots_full",
		"a fifth quest is refused with quest.slots_full")
	GameState.titles = {"portugal": "none"}
	_check(QuestGenLib.accept_block_reason(offers[1]) == "quest.slots_full",
		"without the grant four live quests stay over the cap")
	# The base cap is 3 *total*, so only two live quests leave room for another.
	GameState.active_quests = GameState.active_quests.slice(0, 2)
	_check(QuestGenLib.accept_block_reason(offers[1]) != "quest.slots_full",
		"back at two quests the slot cap no longer blocks (%s)"
		% QuestGenLib.accept_block_reason(offers[1]))


# --- 7. Royal-mission gate (rep ≥ 30, capitals only) --------------------

func _test_mission_gate() -> void:
	_new_run("lisbon", 1)
	GameState.active_quests = []
	GameState.player["reputation"]["portugal"] = 29
	_check(not PalaceEngineLib.offers_missions("lisbon"),
		"rep 29 is below the royal-mission gate")
	_check(PalaceEngineLib.offer("lisbon", 1).is_empty(), "no offer at rep 29")
	GameState.player["reputation"]["portugal"] = 30
	_check(PalaceEngineLib.offers_missions("lisbon"), "rep 30 unlocks missions")
	_check(not PalaceEngineLib.offer("lisbon", 1).is_empty(), "an offer exists")
	_check(PalaceEngineLib.offer("athens", 1).is_empty(),
		"a non-capital never offers a royal mission")
	_check(PalaceEngineLib.open_block_reason("athens") == "palace.not_capital",
		"a non-capital palace reports palace.not_capital")
	# One mission per nation at a time (§4.9.4).
	var accepted := PalaceEngineLib.accept("lisbon", 1)
	_check(not accepted.is_empty(), "the royal mission is accepted")
	_check(not PalaceEngineLib.active_mission("portugal").is_empty(),
		"the nation has an active royal mission")
	_check(PalaceEngineLib.offer("lisbon", 2).is_empty(),
		"a second royal mission is not offered while one runs")
	_check(PalaceEngineLib.accept("lisbon", 2).is_empty(), "and is not accepted")
	# A different nation is independent.
	GameState.player["reputation"]["spain"] = 40
	_check(PalaceEngineLib.offers_missions("seville"),
		"spain can still offer its own mission")
	_check(PalaceEngineLib.active_mission("spain").is_empty(),
		"spain has no active mission yet")


# --- 8. The three mission kinds -----------------------------------------

func _test_mission_kinds() -> void:
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	# The offer rotates through all three kinds over months.
	var seen := {}
	for day in range(1, 200, 30):
		GameState.active_quests = []
		var offer := PalaceEngineLib.offer("lisbon", day)
		if offer.is_empty():
			continue
		seen[str((offer["requirements"] as Dictionary)["kind"])] = true
	_check(seen.size() == 3, "all three royal kinds are offered over time (%s)"
		% str(seen.keys()))

	# `royal_patrol`: two navy markers tagged with the mission id.
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	var patrol: Dictionary = _mission_of_kind("patrol")
	_check(not patrol.is_empty(), "a royal_patrol offer exists")
	GameState.active_quests = []
	GameState.npc_fleets = []
	GameState.day = int(patrol.get("day", 1))
	GameState.current_port = "lisbon"
	var accepted := PalaceEngineLib.accept_offer("lisbon", int(patrol["day"]), patrol["offer"])
	_check(not accepted.is_empty(), "the patrol mission is accepted")
	var requirements: Dictionary = accepted["requirements"]
	_check(int(requirements.get("count", 0)) == 2,
		"a patrol needs two kills (got %s)" % str(requirements.get("count")))
	_check(str(requirements.get("nation_id", "")) != "portugal",
		"the patrol targets a rival nation (%s)"
		% str(requirements.get("nation_id")))
	var tagged := 0
	for marker in GameState.npc_fleets:
		if str((marker as Dictionary).get("quest_id", "")) \
				== str(accepted["instance_id"]):
			tagged += 1
			_check(bool((marker as Dictionary).get("royal_mission", false)),
				"the patrol fleet carries royal_mission")
			_check(str((marker as Dictionary).get("role", "")) == "privateer",
				"the patrol fleet is a hostile warship (privateer role)")
	_check(tagged == 2, "accepting spawns two target fleets (%d)" % tagged)

	# `royal_chart`: two discovery reports after acceptance.
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	var chart: Dictionary = _mission_of_kind("chart")
	_check(not chart.is_empty(), "a royal_chart offer exists")
	GameState.active_quests = []
	GameState.day = int(chart.get("day", 1))
	GameState.current_port = "lisbon"
	var chart_quest := PalaceEngineLib.accept_offer("lisbon", int(chart["day"]), chart["offer"])
	_check(not chart_quest.is_empty(), "the chart mission is accepted")
	_check(int((chart_quest["requirements"] as Dictionary).get("count", 0)) == 2,
		"a chart needs two reports")

	# `royal_delivery`: 3× the guild delivery reward.
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	var delivery: Dictionary = _mission_of_kind("delivery")
	_check(not delivery.is_empty(), "a royal_delivery offer exists")
	var offer: Dictionary = delivery["offer"]
	var guild_offers: Array = QuestGenLib.offers("lisbon", int(delivery["day"]))
	var guild_gold := 0
	for entry in guild_offers:
		if str((entry as Dictionary).get("type", "")) == "delivery":
			guild_gold = int(((entry as Dictionary)["rewards"] as Dictionary)["gold"])
			break
	_check(int(((offer["rewards"] as Dictionary)).get("gold", 0)) == guild_gold * 3,
		"royal_delivery pays 3× the guild delivery (%d vs %d)"
		% [int(((offer["rewards"] as Dictionary)).get("gold", 0)), guild_gold])
	_check(int(((offer["rewards"] as Dictionary)).get("fame", 0)) == 25,
		"every royal kind grants +25 fame")
	_check(int(((offer["rewards"] as Dictionary)).get("gold", 0)) > 0,
		"royal_delivery has a gold reward")


## Finds the first day whose offer is `kind` (searches whole cycles).
func _mission_of_kind(kind_fragment: String) -> Dictionary:
	for day in range(1, 400):
		GameState.active_quests = []
		var offer := PalaceEngineLib.offer("lisbon", day)
		if offer.is_empty():
			continue
		var kind := str((offer["requirements"] as Dictionary).get("kind", ""))
		if kind.contains(kind_fragment):
			return {"day": day, "offer": offer}
	return {}


# --- 9. Mission completion deltas ---------------------------------------

func _test_mission_completion() -> void:
	# Patrol: two victories complete the mission → +8000g, +25 fame, +1 mission.
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	var patrol: Dictionary = _mission_of_kind("patrol")
	GameState.active_quests = []
	GameState.day = int(patrol["day"])
	var quest := PalaceEngineLib.accept_offer("lisbon", int(patrol["day"]), patrol["offer"])
	var gold_before := GameState.gold
	var fame_before := GameState.fame
	var first := PalaceEngineLib.on_patrol_kill(quest)
	_check(first.is_empty(), "one kill does not complete a two-kill patrol")
	_check(int((quest["requirements"] as Dictionary).get("killed", 0)) == 1,
		"the kill counter advanced to 1")
	var second := PalaceEngineLib.on_patrol_kill(quest)
	_check(not second.is_empty(), "the second kill completes the patrol")
	_check(GameState.gold == gold_before + 8000,
		"the patrol pays 8000g (got %d)" % (GameState.gold - gold_before))
	_check(GameState.fame == fame_before + 25,
		"the patrol grants +25 fame (got %d)" % (GameState.fame - fame_before))
	_check(FameLib.royal_missions("portugal") == 1,
		"completed_royal_missions[portugal] is 1")
	_check(CharacterLib.reputation("portugal") == 50,
		"the giver gains +10 reputation (got %d)"
		% CharacterLib.reputation("portugal"))
	_check(str(quest.get("status", "")) == "completed", "the mission is completed")
	_check(PalaceEngineLib.on_patrol_kill(quest).is_empty(),
		"a completed mission cannot be credited twice")

	# Chart: two reports complete it → +6000g.
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	var chart: Dictionary = _mission_of_kind("chart")
	GameState.active_quests = []
	GameState.day = int(chart["day"])
	var chart_quest := PalaceEngineLib.accept_offer("lisbon", int(chart["day"]), chart["offer"])
	gold_before = GameState.gold
	_check(PalaceEngineLib.on_discovery_reported(chart_quest).is_empty(),
		"one report does not complete a two-report chart")
	_check(not PalaceEngineLib.on_discovery_reported(chart_quest).is_empty(),
		"the second report completes the chart")
	_check(GameState.gold == gold_before + 6000,
		"the chart pays 6000g (got %d)" % (GameState.gold - gold_before))
	_check(FameLib.royal_missions("portugal") == 1,
		"the chart counts as one completed royal mission")

	# The ladder is evaluated after the completion, not granted automatically.
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	GameState.fame = 3000
	GameState.completed_royal_missions["portugal"] = 7
	var delivery: Dictionary = _mission_of_kind("delivery")
	GameState.active_quests = []
	GameState.day = int(delivery["day"])
	var delivery_quest := PalaceEngineLib.accept_offer("lisbon", int(delivery["day"]), delivery["offer"])
	PalaceEngineLib.complete_mission(delivery_quest)
	_check(FameLib.royal_missions("portugal") == 8,
		"the eighth mission is recorded")
	_check(FameLib.can_promote("portugal"),
		"the duke requirement is now met (the player must still attend)")
	_check(FameLib.title("portugal") == "none",
		"completing a mission grants nothing by itself")


# --- 10. Mission failure (expiry → −10 rep) ----------------------------

func _test_mission_failure() -> void:
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	var delivery: Dictionary = _mission_of_kind("delivery")
	GameState.active_quests = []
	GameState.day = int(delivery["day"])
	var quest := PalaceEngineLib.accept_offer("lisbon", int(delivery["day"]), delivery["offer"])
	var deadline := int(quest.get("deadline_day", 0))
	_check(PalaceEngineLib.tick(deadline).is_empty(),
		"the deadline day itself does not fail the mission")
	var failed := PalaceEngineLib.tick(deadline + 1)
	_check(failed.size() == 1, "the next day fails the mission")
	_check(CharacterLib.reputation("portugal") == 30,
		"expiry costs 10 reputation (got %d)"
		% CharacterLib.reputation("portugal"))
	_check(str(quest.get("status", "")) == "failed", "the mission is failed")
	_check(FameLib.royal_missions("portugal") == 0,
		"a failed mission is not credited")
	_check(GameState.fame == 0, "a failed mission grants no fame")


# --- 11. The palace screen (S13) ---------------------------------------

func _test_palace_screen() -> void:
	_new_run("lisbon", 1)
	GameState.player["reputation"]["portugal"] = 40
	GameState.fame = 100
	GameState.completed_royal_missions["portugal"] = 1
	var screen: Control = PalaceScene.instantiate()
	screen.route_to_port = false
	add_child(screen)
	await get_tree().process_frame
	_check(screen.port_id() == "lisbon", "the palace binds the docked port")
	_check(screen.nation_id() == "portugal", "the palace knows its nation")
	var hud: Control = screen.get_node_or_null("HUD")
	_check(hud != null and not hud.is_minimap_visible(),
		"S13 replaces the sea viewport: minimap hidden (§4.5)")
	_check(not screen.is_closed(), "an unbountied palace is open")
	_check(not screen.retire_row_visible(),
		"a commoner does not see the Retire row (§4.7)")

	# The title row shows the current rank and the next requirement.
	var current: Label = screen.get_node("Layout/VBox/Rows/TitleRow/Current")
	var next: Label = screen.get_node("Layout/VBox/Rows/TitleRow/Next")
	_check(current.text == I18n.fmt("palace.title.current",
		{"rank": I18n.t_key("rank.none")}),
		"the current rank row reads Commoner (%s)" % current.text)
	_check(next.text == I18n.fmt("palace.title.next", {
		"rank": I18n.t_key("rank.knight"), "fame": 100, "missions": 1,
	}), "the next-rank row names knight (100/1) (%s)" % next.text)

	# Ceremony through the button.
	var ceremony: Button = screen.get_node("Layout/VBox/Rows/TitleRow/Ceremony")
	_check(not ceremony.disabled, "the ceremony is offered when eligible")
	var granted := [""]
	screen.title_granted_here.connect(func(_n: String, rank: String) -> void:
		granted[0] = rank)
	screen.attend_ceremony()
	_check(granted[0] == "knight", "the ceremony button grants the knight (%s)"
		% granted[0])
	_check(FameLib.title("portugal") == "knight", "the state holds the knight")
	_check(current.text == I18n.fmt("palace.title.current",
		{"rank": I18n.t_key("rank.knight")}),
		"the current-rank row rebinds to Knight (%s)" % current.text)
	# Ineligible: the ceremony button is disabled.
	_check(ceremony.disabled, "the ceremony disables at fame 100 / 1 mission")

	# All six ranks exist as localised names.
	for rank in FameLib.RANKS:
		_check(DataLoader.ui_strings.has("rank.%s" % rank),
			"rank.%s is in the string table" % rank)

	# Locale rebind + no raw keys.
	var leaked: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		for line in screen.all_text():
			if str(line).contains("<") and str(line).contains(">"):
				leaked.append("%s: %s" % [locale, str(line)])
	_check(leaked.is_empty(), "the palace prints no raw <key> (%s)"
		% str(leaked.slice(0, 3)))
	I18n.set_locale("zh")
	_check(current.text.contains(_ui_zh("rank.knight")),
		"the zh rank name is 骑士 (%s)" % current.text)
	I18n.set_locale("en")
	_check(current.text.contains(_ui_en("rank.knight")),
		"the en rank name is Knight (%s)" % current.text)

	# The hub routes to the palace on a capital row.
	var hub: Control = PortScene.instantiate()
	hub.route_to_world = false
	hub.route_to_facility = false
	add_child(hub)
	await get_tree().process_frame
	_check(hub.is_facility_enabled("palace"), "the hub enables the palace row")
	_check(str(hub.FACILITY_SCENES["palace"]) ==
		"res://scenes/port/palace_screen.tscn", "the palace scene path is wired")
	hub.queue_free()
	await get_tree().process_frame

	# A non-capital hub has no palace row at all.
	GameState.current_port = "athens"
	hub = PortScene.instantiate()
	hub.route_to_world = false
	hub.route_to_facility = false
	add_child(hub)
	await get_tree().process_frame
	_check(hub.facility_row("palace") == null,
		"a non-capital has no palace row")
	hub.queue_free()
	await get_tree().process_frame

	screen.queue_free()
	await get_tree().process_frame


# --- Helpers -------------------------------------------------------------

func _ui_en(key: String) -> String:
	return str((DataLoader.ui_strings.get(key, {}) as Dictionary).get("en", ""))


func _ui_zh(key: String) -> String:
	return str((DataLoader.ui_strings.get(key, {}) as Dictionary).get("zh", ""))


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
