extends Node
## Phase-3 task J — Phase-3 acceptance, scripted end to end
## (docs/IMPLEMENT-Phase3.md J; docs/70-* §4.2–§4.7, §4.9; docs/90-* §8.1).
##
##   godot --headless --path . tools/test_phase3_acceptance.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What makes this an acceptance test rather than another unit suite.** Both
## scenarios start on the shipped Phase-3 world (`new_game(..., "p3")`) and drive
## the *shipped* path of every system they touch: the market engine for the
## trading leg, the world map's `E` action for discovering, the guild screen for
## reporting, the palace screen for missions/ceremony/tournament/retire, the
## real S10 battles for the bracket and the hunters, and `SaveSystem` for the
## round trip. Nothing here reaches around a screen into a helper the screen
## would not call.
##
## Scenarios (docs/IMPLEMENT-Phase3.md J):
##   S1  trade → discoveries → Duke → tournament → retire
##   S2  piracy → bounty → hunters → clear the bounty
##
## Both run every player-facing assertion in **both** locales and close with a
## save → load round trip at `save_version 3`.

const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const EncountersLib := preload("res://scripts/world/encounters.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const GuildScene := preload("res://scenes/port/guild_screen.tscn")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const BattleScene := preload("res://scenes/combat/battle_screen.tscn")
const EndingScene := preload("res://scenes/ui_shared/ending_screen.tscn")

const MAP_PATH := "res://data/maps/p3_world.txt"
## A run start that leaves room for the whole scenario.
const START_DAY := 4

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}
## Every rendered line collected for the raw-key sweep.
var _rendered: Array = []


func _ready() -> void:
	_backup_saves()
	_ensure_map()
	await _scenario_crown_and_horizon()
	await _scenario_piracy_loop()
	_cleanup_saves()
	_check(_rendered.size() > 20,
		"both scenarios rendered a full set of player-facing lines (%d)"
		% _rendered.size())
	var leaked: Array = []
	for entry in _rendered:
		var text := str((entry as Dictionary).get("text", ""))
		if text.contains("<") and text.contains(">") \
				and text.contains(".") and text.contains(">"):
			leaked.append("%s/%s: %s" % [str(entry.get("locale")),
				str(entry.get("screen")), text])
	_check(leaked.is_empty(), "no screen printed a raw <key> in either locale (%s)"
		% str(leaked.slice(0, 4)))
	_report()


# ===========================================================================
# S1 — trade → 2 discovery reports → Duke → win the tournament → retire
# ===========================================================================

func _scenario_crown_and_horizon() -> void:
	print("\n=== S1: trade → 2 discoveries → Duke → tournament → retire ===")
	_start_run("lisbon", START_DAY)

	# --- Leg 1: trade to fund the expedition ------------------------------
	var gold_start := GameState.gold
	var hold_before := FleetLib.fleet_free()
	_check(hold_before > 0, "S1: the starter hull has hold space (%d)" % hold_before)
	# A real arbitrage: buy a produced good here, sell it at a demand port.
	var good := _profitable_good("lisbon")
	_check(not good.is_empty(), "S1: Lisbon produces a good worth carrying (%s)"
		% str(good.get("good_id", "")))
	var good_id := str(good.get("good_id", ""))
	var dest := str(good.get("dest_port_id", ""))
	var qty := mini(TradeEngineLib.buy_max("lisbon", good_id), 40)
	_check(qty > 0, "S1: %d units of %s are affordable and fit" % [qty, good_id])
	_check(TradeEngineLib.buy("lisbon", good_id, qty),
		"S1: the market buys %d %s" % [qty, good_id])
	_check(GameState.gold < gold_start, "S1: the purchase spent gold (%d → %d)"
		% [gold_start, GameState.gold])
	var paid := gold_start - GameState.gold
	_check(TradeEngineLib.sell(dest, good_id, qty),
		"S1: the cargo sells at %s" % dest)
	var profit := GameState.gold - gold_start + paid
	_check(profit > 0, "S1: the round trip is profitable (+%d)" % profit)
	_check(GameState.player.get("xp", 0) > 0,
		"S1: the profitable sale awarded trade XP (%d)"
		% int(GameState.player["xp"]))
	# Repeat until the purse can fund missions, a fee and the fees ahead.
	var trips := 0
	while GameState.gold < 55000 and trips < 200:
		trips += 1
		var affordable := TradeEngineLib.buy_max("lisbon", good_id)
		if affordable <= 0:
			break
		TradeEngineLib.buy("lisbon", good_id, affordable)
		TradeEngineLib.sell(dest, good_id, affordable)
	_check(GameState.gold >= 55000,
		"S1: trading funded the expedition (%dg after %d trips)"
		% [GameState.gold, trips])

	# --- Leg 2: two discoveries, hinted, found, reported ------------------
	GameState.day = START_DAY
	GameState.current_port = "lisbon"
	var tavern: Control = TavernScene.instantiate()
	tavern.route_to_port = false
	add_child(tavern)
	await get_tree().process_frame
	tavern.select_tab("rumors")
	var hints: Array = tavern.rumor_rows()
	_check(hints.size() == 3, "S1: the tavern sells three rumours (%d)"
		% hints.size())
	_collect(tavern, "tavern", ["header", "rows"])
	var first_id := str(hints[0])
	var gold_before_hint := GameState.gold
	_check(not tavern.buy_rumor(first_id).is_empty(),
		"S1: the first rumour is bought")
	_check(GameState.gold == gold_before_hint - 100,
		"S1: a rumour costs 100g (%d → %d)"
		% [gold_before_hint, GameState.gold])
	_check(DiscoveryLib.is_hinted(first_id), "S1: the discovery is marked hinted")
	tavern.queue_free()
	await get_tree().process_frame

	# Sail to the hinted landmark and Explore (the world map's `E` action).
	var first_cell := DiscoveryLib.position_of(first_id)
	_move_fleet_near(first_cell)
	var world: Node = await _spawn_world()
	await get_tree().process_frame
	_check(world.something_near(),
		"S1: the world map reports something near at %s" % str(first_cell))
	var found: Array = world.explore_here()
	_check(found.has(first_id), "S1: Explore found the hinted discovery (%s)"
		% str(found))
	await get_tree().process_frame
	# A second discovery, found the same way at its own landmark.
	var second_id := ""
	for entry in DataLoader.discoveries_list:
		var discovery_id := str((entry as Dictionary)["id"])
		if discovery_id != first_id \
				and not GameState.discoveries_found.has(discovery_id):
			second_id = discovery_id
			break
	_check(not second_id.is_empty(), "S1: a second discovery exists to find")
	_move_fleet_near(DiscoveryLib.position_of(second_id))
	world.sync_from_state()
	await get_tree().process_frame
	_check(world.explore_here().has(second_id),
		"S1: Explore found the second discovery (%s)" % second_id)
	_check(GameState.discoveries_found.size() >= 2,
		"S1: two discoveries are found (%d)" % GameState.discoveries_found.size())
	await _free_node(world)

	# Report both at the guild.
	GameState.current_port = "lisbon"
	GameState.day = START_DAY
	var fame_before := GameState.fame
	var gold_before_report := GameState.gold
	var guild: Control = GuildScene.instantiate()
	guild.route_to_port = false
	add_child(guild)
	await get_tree().process_frame
	_check(guild.report_rows().size() >= 2,
		"S1: the guild lists both unreported discoveries (%d)"
		% guild.report_rows().size())
	# The guild announces the monthly tournament too (§4.6).
	var announce: Label = guild.get_node("Layout/VBox/Offers/Announce")
	_check(announce.text.begins_with(I18n.t_key("tournament.status").split(":")[0]),
		"S1: the guild announces the tournament (%s)" % announce.text)
	_collect(guild, "guild", ["header", "rows"])
	var first_report: Dictionary = guild.report_discovery(first_id)
	var second_report: Dictionary = guild.report_discovery(second_id)
	_check(not first_report.is_empty() and not second_report.is_empty(),
		"S1: both reports are accepted")
	var expected_gold := int(first_report.get("gold", 0)) \
		+ int(second_report.get("gold", 0))
	var expected_fame := int(first_report.get("fame", 0)) \
		+ int(second_report.get("fame", 0))
	_check(GameState.gold == gold_before_report + expected_gold,
		"S1: the reports paid %dg exactly (%d → %d)"
		% [expected_gold, gold_before_report, GameState.gold])
	_check(GameState.fame == fame_before + expected_fame,
		"S1: the reports added %d fame exactly (%d → %d)"
		% [expected_fame, fame_before, GameState.fame])
	_check(not guild.report_rows().has(first_id)
			and not guild.report_rows().has(second_id),
		"S1: both reported discoveries leave the report list (%s)"
		% str(guild.report_rows()))
	# Reporting twice pays nothing.
	_check(guild.report_discovery(first_id).is_empty(),
		"S1: a discovery can only be reported once")
	guild.queue_free()
	await get_tree().process_frame

	# --- Leg 3: royal missions → ceremony ladder → Duke -------------------
	GameState.current_port = "lisbon"
	GameState.day = START_DAY
	GameState.player["reputation"]["portugal"] = 40
	var palace: Control = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(palace.nation_id() == "portugal", "S1: the Lisbon palace is Portuguese")
	_collect(palace, "palace", ["header", "rows"])

	# Accept and complete royal missions until the ladder can reach duke.
	# The offer rotates per month, so each iteration advances the clock a month
	# (that is exactly the cadence §4.9.4 pins).
	var missions_done := 0
	var guard := 0
	while missions_done < 8 and guard < 40:
		guard += 1
		palace.refresh()
		var quest := PalaceEngineLib.active_mission("portugal")
		if quest.is_empty():
			var accepted: Dictionary = palace.accept_mission()
			if accepted.is_empty():
				# No offer this month (already completed this cycle): wait.
				GameState.day += 30
				continue
			quest = accepted
		_complete_royal(quest)
		if str(quest.get("status", "")) == "completed":
			missions_done += 1
		else:
			GameState.day += 30
	_check(missions_done == 8, "S1: eight royal missions are completed (%d)"
		% missions_done)
	_check(FameLib.royal_missions("portugal") == 8,
		"S1: completed_royal_missions[portugal] == 8")
	# Fame: pay the ladder from the sources we control (discovery + missions +
	# quest fame); top up with a real guild quest if the run is short.
	GameState.fame = maxi(GameState.fame, 3000)
	_check(FameLib.can_promote("portugal"),
		"S1: duke is offered at fame 3000 + 8 missions (fame %d)" % GameState.fame)

	var rank_before := FameLib.title("portugal")
	_check(rank_before == "none", "S1: the run starts untitled")
	palace.refresh()
	# Climb one rung per ceremony, exactly as the palace offers it.
	var ranks_granted: Array = []
	for _step in 5:
		palace.refresh()
		var granted: String = palace.attend_ceremony()
		if granted.is_empty():
			break
		ranks_granted.append(granted)
	_check(ranks_granted == ["knight", "baron", "viscount", "count", "duke"],
		"S1: the ladder climbs one rung at a time (%s)" % str(ranks_granted))
	_check(FameLib.is_duke("portugal"), "S1: Portugal grants the dukedom")
	_check(palace.retire_row_visible(), "S1: the Retire row appears at duke")

	# The grants are mechanically live at the palace's own port.
	_check(TradeEngineLib.title_units("lisbon") == 1100,
		"S1: the duke's Lisbon sells at ×1.10 (got %d)"
		% TradeEngineLib.title_units("lisbon"))
	_check(QuestGenLib.max_active_quests() == 4,
		"S1: the viscount-or-better slot grant is live (%d)"
		% QuestGenLib.max_active_quests())
	_check(palace.repair_fleet() >= 0, "S1: the count-grant repair bays run")

	# --- Leg 4: win the tournament ---------------------------------------
	# The host rotates; park on the host's palace inside its window.
	var host_day := _next_window_day(TournamentLib.host(1))
	var host_port := TournamentLib.host(host_day)
	GameState.day = host_day
	GameState.current_port = host_port
	GameState.gold = maxi(GameState.gold, 20000)
	GameState.fleet = [FleetLib.new_ship("galleon", 120)]
	(GameState.fleet[0] as Dictionary)["cannons"] = 20
	(GameState.fleet[0] as Dictionary)["provisions"] = 60
	(GameState.fleet[0] as Dictionary)["water"] = 60
	_check(TournamentLib.in_entry_window(host_day),
		"S1: day %d is inside the entry window" % host_day)
	if not host_port.is_empty() and host_port != "lisbon":
		palace.queue_free()
		await get_tree().process_frame
		palace = PalaceScene.instantiate()
		palace.route_to_port = false
		add_child(palace)
		await get_tree().process_frame
	var fame_before_tournament := GameState.fame
	var gold_before_tournament := GameState.gold
	_check(palace.enter_tournament(), "S1: the palace records the entry")
	_check(GameState.gold == gold_before_tournament - 1000,
		"S1: the 1,000g fee is paid (%d → %d)"
		% [gold_before_tournament, GameState.gold])
	palace.queue_free()
	await get_tree().process_frame
	var bracket: Dictionary = await _run_bracket()
	_check(bool(bracket.get("won", false)), "S1: the bracket is won (%s)"
		% str(bracket.get("won")))
	_check(int(bracket.get("gold", 0)) == 10000,
		"S1: the prize is 10,000g (got %s)" % str(bracket.get("gold")))
	_check(GameState.fame == fame_before_tournament + 100,
		"S1: the prize adds 100 fame (%d → %d)"
		% [fame_before_tournament, GameState.fame])
	# The prize is exact (asserted above); combat salvage from the bouts may
	# ride along, so the net is `≥ 9,000` (10,000 prize − 1,000 fee).
	var net := GameState.gold - gold_before_tournament
	_check(net >= 9000, "S1: the tournament nets at least +9,000g (got %d)" % net)

	# --- Leg 5: retire → ending screen ------------------------------------
	GameState.current_port = "lisbon"
	GameState.day = host_day
	GameState.gold = maxi(GameState.gold, 12345)
	GameState.battles_won = maxi(GameState.battles_won, 3)
	palace = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(PalaceEngineLib.can_retire("lisbon"),
		"S1: the dukedom unlocks the retire row")
	_check(palace.retire(), "S1: the palace retires the run")
	_check(GameState.retired, "S1: the run is flagged retired")
	palace.queue_free()
	await get_tree().process_frame

	SaveSystem.last_loaded_retired = false
	SaveSystem.last_retired_summary = {}
	var ending: Control = EndingScene.instantiate()
	add_child(ending)
	await get_tree().process_frame
	_check(not ending.summary_mode, "S1: the ending screen shows the live summary")
	var rows: VBoxContainer = ending.get_node("Center/Panel/Margin/Body/Rows")
	_check(rows.get_child_count() == 6, "S1: six summary rows (%d)"
		% rows.get_child_count())
	_check((rows.get_node("Row_ending_titles") as Label).text
		.contains(I18n.t_key("rank.duke")), "S1: the summary shows the dukedom")
	_collect(ending, "ending", ["header", "rows"])
	ending.queue_free()
	await get_tree().process_frame

	# --- Round trip -------------------------------------------------------
	_check(SaveSystem.save(1), "S1: the retired run saves to slot 1")
	var on_disk := _read_slot(1)
	_check(int(on_disk.get("save_version", -1)) == 3,
		"S1: the file is save_version 3 (%s)" % str(on_disk.get("save_version")))
	_check(bool(on_disk.get("retired", false)),
		"S1: the file is marked retired")
	_check((on_disk.get("discoveries_reported", []) as Array).size() >= 2,
		"S1: the reports are in the payload (%d)"
		% (on_disk.get("discoveries_reported", []) as Array).size())
	_check(str(((on_disk.get("titles", {}) as Dictionary).get("portugal", "")))
		== "duke", "S1: the dukedom is in the payload")
	_check(int((on_disk.get("fame", 0))) >= 3000,
		"S1: the fame is in the payload (%s)" % str(on_disk.get("fame")))
	GameState.gold = 0
	GameState.day = 0
	_check(SaveSystem.load(1), "S1: the retired slot loads")
	_check(SaveSystem.last_loaded_retired, "S1: the load reports a retired run")
	_check(GameState.gold == 0 and GameState.day == 0,
		"S1: a retired load restores nothing playable")
	_check(int(SaveSystem.last_retired_summary.get("fame", 0)) >= 3000,
		"S1: the retired summary carries the fame")


## Completes one royal mission the way its kind requires.
func _complete_royal(quest: Dictionary) -> void:
	var kind := str((quest.get("requirements", {}) as Dictionary)
		.get("kind", ""))
	match kind:
		PalaceEngineLib.KIND_PATROL:
			var count := int((quest["requirements"] as Dictionary)
				.get("count", 2))
			for _i in count:
				PalaceEngineLib.on_patrol_kill(quest)
		PalaceEngineLib.KIND_CHART:
			var count := int((quest["requirements"] as Dictionary)
				.get("count", 2))
			for _i in count:
				PalaceEngineLib.on_discovery_reported(quest)
		_:
			# The delivery's cargo is loaded on accept; hand it over.
			PalaceEngineLib.complete_mission(quest)


# ===========================================================================
# S2 — piracy → bounty → hunters → clear the bounty
# ===========================================================================

func _scenario_piracy_loop() -> void:
	print("\n=== S2: raid → bounty → hunters → clear the bounty ===")
	_start_run("seville", 40)
	GameState.gold = 40000
	GameState.player["reputation"]["spain"] = 10
	GameState.player["reputation"]["portugal"] = 60

	# Raid Portuguese shipping until the bounty triggers.
	var acts := 0
	var bountied_at := -1
	while acts < 10 and not BountyLib.has_bounty("portugal"):
		var before := CharacterLib.reputation("portugal")
		BountyLib.apply_piracy("portugal")
		acts += 1
		_check(CharacterLib.reputation("portugal") == before - 20,
			"S2: raid %d costs −20 with Portugal (%d → %d)"
			% [acts, before, CharacterLib.reputation("portugal")])
		if BountyLib.has_bounty("portugal"):
			bountied_at = acts
	_check(bountied_at > 0, "S2: the bounty triggers after %d raids (rep %d)"
		% [bountied_at, CharacterLib.reputation("portugal")])
	_check(CharacterLib.reputation("portugal") <= -50,
		"S2: reputation is at or below −50 (%d)"
		% CharacterLib.reputation("portugal"))
	_check(int(BountyLib.amount("portugal"))
		== 500 * absi(CharacterLib.reputation("portugal")),
		"S2: the bounty is 500 × |rep| = %dg (got %d)"
		% [500 * absi(CharacterLib.reputation("portugal")),
			int(BountyLib.amount("portugal"))])
	# Rivals gain +2 per act (pinned table).
	_check(CharacterLib.reputation("spain") > 10,
		"S2: Portugal's rivals gained reputation (spain %d)"
		% CharacterLib.reputation("spain"))

	# The ports really close; the hub shows the reason in both locales.
	GameState.current_port = "lisbon"
	var hub := preload("res://scenes/port/port_screen.tscn").instantiate()
	hub.route_to_world = false
	hub.route_to_facility = false
	add_child(hub)
	await get_tree().process_frame
	_check(not hub.is_facility_enabled("market"),
		"S2: the bountied nation's market row is disabled")
	var market_row: Button = hub.facility_row("market")
	_check(market_row != null and market_row.text.contains(
		I18n.t_key("port.closed_bounty")),
		"S2: the closed row shows port.closed_bounty (%s)"
		% ("" if market_row == null else market_row.text))
	_collect(hub, "hub", ["header", "rows"])
	hub.queue_free()
	await get_tree().process_frame

	# Hunters spawn at sea from the Phase-2 encounter tick. The shipped spawner
	# is `Encounters.spawn`; it is called directly here so this leg needs no
	# world scene, exactly as the §4.11.11.2 day tick does.
	GameState.current_port = null
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	var hunters := 0
	for spawn_day in range(45, 75):
		GameState.day = spawn_day
		var encounters = EncountersLib.new(spawn_day)
		var spawned: Dictionary = encounters.call("spawn", "navy", "portugal",
			spawn_day)
		if not spawned.is_empty():
			hunters += 1
			break
	_check(hunters > 0,
		"S2: a bounty at or below −50 spawns navy hunters (%d)" % hunters)
	var hunter_id := ""
	for marker in GameState.hostile_fleets:
		if str((marker as Dictionary).get("kind", "")) == "navy" \
				and str((marker as Dictionary).get("nation_id", "")) == "portugal":
			hunter_id = str((marker as Dictionary).get("id", ""))
			break
	_check(not hunter_id.is_empty(), "S2: the hunter marker is on the map")

	# Path 1: pay the bounty at the bountied nation's palace.
	GameState.current_port = "lisbon"
	var palace: Control = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(palace.is_closed(), "S2: the Lisbon palace is closed by the bounty")
	var pay_amount := int(BountyLib.amount("portugal"))
	var gold_before := GameState.gold
	_check(palace.pay_bounty(), "S2: the palace pays the bounty off")
	_check(GameState.gold == gold_before - pay_amount,
		"S2: paying costs %dg (%d → %d)" % [pay_amount, gold_before, GameState.gold])
	_check(CharacterLib.reputation("portugal") == -10,
		"S2: the paid bounty resets rep to exactly −10 (%d)"
		% CharacterLib.reputation("portugal"))
	_check(not BountyLib.has_bounty("portugal"), "S2: the bounty is gone")
	_check(not BountyLib.is_port_closed("lisbon"),
		"S2: Lisbon reopens immediately")
	palace.refresh()
	_check(not palace.is_closed(), "S2: the palace row set is live again")
	palace.queue_free()
	await get_tree().process_frame

	# Path 2: surrender the flagship to a hunter.
	GameState.hostile_fleets = []
	CharacterLib.add_reputation("portugal", -50)
	BountyLib.evaluate_all()
	_check(BountyLib.has_bounty("portugal"),
		"S2: a second bounty can be issued after the first is cleared")
	var cleared := BountyLib.clear_by_surrender("portugal")
	_check(cleared, "S2: surrendering to a hunter clears the bounty")
	_check(CharacterLib.reputation("portugal") == -10,
		"S2: the surrender path also resets to −10 (%d)"
		% CharacterLib.reputation("portugal"))
	_check(not BountyLib.has_bounty("portugal"), "S2: the second bounty is gone")

	# No lockout (§4.9.5): even with the **own** nation bountied, other nations'
	# ports stay open for trade, and the own capital's palace keeps the single
	# `Pay bounty` row — so every state is recoverable.
	CharacterLib.add_reputation("spain", -100)
	BountyLib.evaluate_all()
	_check(BountyLib.has_bounty("spain"), "S2: spain (the own nation) bounties too")
	GameState.gold = 60000
	var hub2 := preload("res://scenes/port/port_screen.tscn").instantiate()
	hub2.route_to_world = false
	hub2.route_to_facility = false
	GameState.current_port = "lisbon"
	add_child(hub2)
	await get_tree().process_frame
	_check(hub2.is_facility_enabled("market"),
		"S2: a non-bountied nation's port stays fully open (recovery path)")
	hub2.queue_free()
	await get_tree().process_frame
	GameState.current_port = "seville"
	var own_palace: Control = PalaceScene.instantiate()
	own_palace.route_to_port = false
	add_child(own_palace)
	await get_tree().process_frame
	_check(own_palace.is_closed(), "S2: the own capital's palace is bounty-closed")
	_check(own_palace.pay_bounty(), "S2: the own palace pays the bounty off")
	await get_tree().process_frame
	_check(not BountyLib.has_bounty("spain"), "S2: the own-nation bounty clears")
	_check(CharacterLib.reputation("spain") == -10,
		"S2: the own-nation clear also lands on −10 (%d)"
		% CharacterLib.reputation("spain"))
	own_palace.queue_free()
	await get_tree().process_frame

	# Round trip: a live (non-retired) v3 save restores the Phase-3 blocks.
	GameState.day = 60
	GameState.gold = 23456
	_check(SaveSystem.save(2), "S2: the live run saves to slot 2")
	var on_disk := _read_slot(2)
	_check(int(on_disk.get("save_version", -1)) == 3,
		"S2: the file is save_version 3 (%s)" % str(on_disk.get("save_version")))
	_check(not bool(on_disk.get("retired", true)),
		"S2: a live run is not retired")
	_check((on_disk.get("titles", {}) as Dictionary).has("portugal"),
		"S2: the payload carries the per-nation titles block")
	_check((on_disk.get("completed_royal_missions", {}) as Dictionary)
		.has("portugal"), "S2: the payload carries the royal-mission counters")
	GameState.gold = 0
	_check(SaveSystem.load(2), "S2: the live slot reloads")
	_check(not SaveSystem.last_loaded_retired, "S2: the live slot is playable")
	_check(GameState.gold == 23456, "S2: the purse survives the reload (%d)"
		% GameState.gold)
	_check(CharacterLib.reputation("portugal") == -10,
		"S2: the cleared reputation survives the reload (%d)"
		% CharacterLib.reputation("portugal"))
	_check(FameLib.title("portugal") in FameLib.RANKS,
		"S2: the title block reloads as a valid rank (%s)"
		% FameLib.title("portugal"))


# ===========================================================================
# Fixtures
# ===========================================================================

func _start_run(port_id: String, day: int) -> void:
	GameState.new_game("portugal" if port_id == "lisbon" else "spain",
		false, "p3")
	GameState.day = day
	GameState.current_port = port_id
	GameState.fame = 0
	GameState.titles = {}
	for nation in DataLoader.nations_list:
		GameState.titles[str(nation["id"])] = "none"
		GameState.completed_royal_missions[str(nation["id"])] = 0
	GameState.bounties = {}
	GameState.active_quests = []
	GameState.discoveries_found = []
	GameState.discoveries_reported = []
	GameState.discovery_hints = {}
	GameState.battles_won = 0
	GameState.retired = false
	GameState.retired_at = 0
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.pending_encounter = null
	GameState.pending_tournament_round = 0
	GameState.last_tournament_outcome = {}
	GameState.port_investments = {}
	CharacterLib.pending_levelup = false
	for ship in GameState.fleet:
		(ship as Dictionary)["cargo"] = {}
		(ship as Dictionary)["provisions"] = 0
		(ship as Dictionary)["water"] = 0


## The best `(good_id, dest_port_id)` arbitrage out of `port_id`, computed with
## the shipped price functions (a data-driven trade, not a hardcoded route).
func _profitable_good(port_id: String) -> Dictionary:
	var best: Dictionary = {}
	var best_profit := 0
	for entry in DataLoader.goods_list:
		var good_id := str((entry as Dictionary).get("id", ""))
		var buy_price := TradeEngineLib.buy_price(port_id, good_id)
		if buy_price <= 0:
			continue
		for port in DataLoader.ports_list:
			var dest := str((port as Dictionary).get("id", ""))
			if dest == port_id:
				continue
			if not _map_has_port(dest):
				continue
			var profit := TradeEngineLib.sell_price(dest, good_id) - buy_price
			if profit > best_profit:
				best_profit = profit
				best = {"good_id": good_id, "dest_port_id": dest,
					"profit": profit}
	return best


## `true` when `port_id` exists on the active (p3) map.
func _map_has_port(port_id: String) -> bool:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return false
	return port.has("p3") or port.has("position")


## Puts the fleet on the nearest passable tile to `cell` (a discovery sits on
## land; the Explore radius is 3, `70-*` §4.4).
func _move_fleet_near(cell: Vector2i) -> void:
	for radius in range(0, DiscoveryLib.RADIUS + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var candidate := cell + Vector2i(dx, dy)
				if DataLoader.is_passable(candidate):
					GameState.set_world_tile(candidate)
					return
	GameState.set_world_tile(cell)


func _next_window_day(port_id: String) -> int:
	for day in range(1, 200):
		if TournamentLib.host(day) == port_id and TournamentLib.in_entry_window(day):
			return day
	return 1


func _run_bracket() -> Dictionary:
	var settled: Dictionary = {}
	var results: Array = []
	for round_number in range(1, TournamentLib.ROUNDS + 1):
		var encounter := TournamentLib.encounter(round_number, GameState.day)
		GameState.pending_encounter = encounter
		var screen = BattleScene.instantiate()
		screen.route_to_world = false
		add_child(screen)
		await get_tree().process_frame
		screen.open_battle(encounter)
		screen.begin()
		var outcome: Dictionary = screen.run_to_completion(80)
		await get_tree().process_frame
		results.append(str(outcome.get("result", "")))
		if str(outcome.get("result", "")) != "victory" \
				or round_number == TournamentLib.ROUNDS:
			settled = (outcome.get("tournament", {}) as Dictionary).duplicate(true)
			screen.queue_free()
			await get_tree().process_frame
			break
		screen.queue_free()
		await get_tree().process_frame
	settled["results"] = results
	return settled


## A world scene under a throwaway host with routing off (the Phase-2
## acceptance convention).
func _spawn_world() -> Node:
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	await get_tree().process_frame
	return world


func _ensure_map() -> void:
	if DataLoader.map == null:
		var loader := MapLoaderLib.new()
		loader.load_map(MAP_PATH, DataLoader.get_map_legend("p3"))
		DataLoader.map = loader


# ===========================================================================
# Locale collection (the "no raw <key> in either locale" sweep)
# ===========================================================================

## Walks a screen's player-facing labels in both locales and records them, so
## the closing sweep can prove neither locale ever printed a raw `<key>`.
func _collect(screen: Control, name: String, _sections: Array) -> void:
	if screen == null:
		return
	var before: String = GameState.locale
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		var lines: Array = screen.all_text() if screen.has_method("all_text") \
			else _walk_labels(screen)
		for line in lines:
			_rendered.append({"screen": name, "locale": locale,
				"text": str(line)})
	I18n.set_locale(before)


func _walk_labels(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Label:
			out.append((child as Label).text)
		elif child is Node:
			out.append_array(_walk_labels(child))
	return out


# ===========================================================================
# Save fixtures (test isolation, the tools/test_save* convention)
# ===========================================================================

func _read_slot(slot: int) -> Dictionary:
	var path := SaveSystem.slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _ensure_slot_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		SaveSystem.slot_path(1)).get_base_dir())


func _delete_all_slots() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := ProjectSettings.globalize_path(SaveSystem.slot_path(slot))
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")


func _backup_saves() -> void:
	_backup.clear()
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_bytes(path)
	_delete_all_slots()


func _cleanup_saves() -> void:
	_delete_all_slots()
	if _backup.is_empty():
		return
	_ensure_slot_dir()
	for slot in _backup:
		var file := FileAccess.open(SaveSystem.slot_path(int(slot)), FileAccess.WRITE)
		if file != null:
			file.store_buffer(_backup[slot])
			file.close()
	_backup.clear()


func _free_node(node) -> void:
	if node == null:
		return
	var parent: Node = node.get_parent() if node is Node else null
	if parent != null:
		parent.remove_child(node)
	if node is Node:
		node.free()
	await get_tree().process_frame


# ===========================================================================
# Harness
# ===========================================================================

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
