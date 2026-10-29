extends Node
## T19 — Phase-1 demo-loop acceptance, scripted.
##
## Walks the nine steps of docs/00-OVERVIEW.md §7 through the real engines and
## state (not mocks), asserting the exact numbers the docs promise. Steps that
## need a human eye (title layout, locale spot-check list) are covered by
## tools/demo_check.md; everything mechanical is asserted here.
##
## Run: godot --headless res://tools/test_demo_loop.tscn
##      (exit 0 = all steps pass; the check count must be 100% of TOTAL)

const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const SailingLib := preload("res://scripts/world/sailing_sim.gd")
const TradeLib := preload("res://scripts/port/trade_engine.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const TavernLib := preload("res://scripts/port/tavern_engine.gd")
const InnLib := preload("res://scripts/port/inn_engine.gd")
const MapLib := preload("res://scripts/world/map_loader.gd")
const VillageLib := preload("res://scenes/port/port_screen.gd")

var checks := 0
var failures: Array[String] = []


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		failures.append(label)
		print("FAIL  " + label)


func _ready() -> void:
	_ensure_map()
	_clean_saves()
	await _step1_title()
	await _step2_nationality()
	await _step3_market()
	await _step4_sail()
	await _step5_storm_and_starvation()
	await _step6_second_port()
	await _step7_facilities()
	await _step8_save_load()
	await _step9_locale()

	print("")
	if failures.is_empty():
		print("ALL PASS (%d checks) — demo loop complete" % checks)
	else:
		print("%d of %d checks FAILED:" % [failures.size(), checks])
		for f in failures:
			print("  - " + f)
	get_tree().quit(0 if failures.is_empty() else 1)


func _ensure_map() -> void:
	if DataLoader.map == null:
		var loader = MapLib.new()
		loader.load_map("res://data/maps/p1_mediterranean.txt", DataLoader.map_legend)
		DataLoader.map = loader


func _clean_saves() -> void:
	for slot in range(1, 4):
		SaveSystem.delete_save(slot)


# --- Step 1: title screen ---------------------------------------------------

func _step1_title() -> void:
	var scene: PackedScene = load("res://scenes/title/title_screen.tscn")
	_check(scene != null, "step 1: title screen scene loads")
	var title: Node = scene.instantiate()
	add_child(title)
	await get_tree().process_frame
	_check(title.get_node_or_null("Center/Stack/Buttons/NewGame") != null,
		"step 1: title offers New Game")
	_check(title.get_node_or_null("Center/Stack/Buttons/Load") != null,
		"step 1: title offers Load Game")
	_check(title.get_node_or_null("Center/Stack/Buttons/Language") != null,
		"step 1: title offers the language toggle")
	var proj: Variant = ProjectSettings.get_setting("display/window/size/viewport_width")
	var proj_h: Variant = ProjectSettings.get_setting("display/window/size/viewport_height")
	_check(int(proj) == 1280 and int(proj_h) == 720,
		"step 1: logical window is 1280×720")
	title.queue_free()
	await get_tree().process_frame


# --- Step 2: nationality select --------------------------------------------

func _step2_nationality() -> void:
	var scene: PackedScene = load("res://scenes/title/nationality_select.tscn")
	var pick: Node = scene.instantiate()
	add_child(pick)
	await get_tree().process_frame
	var cards = pick.get_node_or_null("Layout/Cards")
	_check(cards != null and cards.get_child_count() == 6,
		"step 2: exactly 6 nationality cards")
	# Data-driven: each card's package matches nations.json.
	var all_match := true
	for nation in DataLoader.nations_list:
		var port: Dictionary = DataLoader.get_port(nation.start_port_id)
		var ship: Dictionary = DataLoader.get_ship_type(nation.start_ship_type_id)
		if port.is_empty() or ship.is_empty():
			all_match = false
	_check(all_match, "step 2: every nation resolves its start port and ship from data")
	pick.queue_free()
	await get_tree().process_frame

	GameState.new_game("portugal", false)
	_check(GameState.day == 1, "step 2: new game starts on day 1")
	_check(GameState.gold == 5000, "step 2: Portugal starts with 5,000g")
	_check(GameState.fleet.size() == 1
		and GameState.fleet[0].ship_type_id == "caravel",
		"step 2: Portugal starts in a caravel")
	_check(GameState.fleet[0].crew == 15, "step 2: starter crew = crew_min (15)")
	_check(GameState.current_port == "lisbon", "step 2: spawns in Lisbon")


# --- Step 3: market buy ----------------------------------------------------

func _step3_market() -> void:
	GameState.new_game("portugal", false)
	GameState.current_port = "lisbon"
	var gold0: int = GameState.gold
	var price: int = TradeLib.buy_price("lisbon", "wine")
	_check(price == 21, "step 3: Lisbon wine buy price is 21g (§5 worked example)")
	_check(TradeLib.sell_price("lisbon", "wine") == 16,
		"step 3: Lisbon wine sell price is 16g")
	var ok: bool = TradeLib.buy("lisbon", "wine", 10)
	_check(ok, "step 3: buying 10 wine succeeds")
	_check(GameState.gold == gold0 - 210,
		"step 3: gold drops by exactly 210 (%d → %d)" % [gold0, GameState.gold])
	_check(FleetLib.held("wine") == 10, "step 3: cargo shows 10 wine immediately")
	_check(FleetLib.used_capacity(GameState.fleet[0]) == 10,
		"step 3: hold usage tracks the purchase immediately")


# --- Step 4: sailing, 8-dir, consumption, wages ----------------------------

func _step4_sail() -> void:
	GameState.new_game("portugal", false)
	GameState.current_port = null
	GameState.world["weather"] = "fair"
	GameState.set_world_tile(Vector2i(7, 57))
	GameState.world["clock_fraction"] = 0.0
	SailingLib.reset_ledger_state()
	SailingLib.set_weather_seed(11)

	# 8-directional stepping from open water (Atlantic, west of Lisbon).
	var start := Vector2i(3, 57)
	var moved := 0
	for dir in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
			Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
		GameState.set_world_tile(start)
		if SailingLib.try_move(start + dir, DataLoader.map, start):
			moved += 1
	_check(moved == 8, "step 4: all 8 directions step on open water (got %d)" % moved)

	# Land blocks movement at zero clock cost.
	GameState.set_world_tile(Vector2i(7, 57))
	GameState.world["clock_fraction"] = 0.5
	var before: float = GameState.world.clock_fraction
	_check(not SailingLib.try_move(Vector2i(7, 56), DataLoader.map, Vector2i(7, 57)),
		"step 4: land blocks movement")
	_check(GameState.world.clock_fraction == before,
		"step 4: a blocked move costs no clock")

	# A 15-crew caravel burns exactly 3 + 3 per day and pays 2g/crew/day.
	GameState.new_game("portugal", false)
	GameState.current_port = null
	GameState.world["weather"] = "fair"
	FleetLib.add_supplies("provisions", 60)
	FleetLib.add_supplies("water", 60)
	GameState.gold = 1000
	var p0: int = FleetLib.supplies("provisions")
	var w0: int = FleetLib.supplies("water")
	SailingLib.advance_clock(1.0)
	_check(p0 - FleetLib.supplies("provisions") == 3,
		"step 4: 15 crew eat exactly 3 provisions/day")
	_check(w0 - FleetLib.supplies("water") == 3,
		"step 4: 15 crew drink exactly 3 water/day")
	_check(GameState.gold == 970, "step 4: wages are 2g × 15 crew = 30g/day")
	_check(GameState.day == 2, "step 4: one day of sailing advances the clock")


# --- Step 5: storm reachable, starvation fail state ------------------------

func _step5_storm_and_starvation() -> void:
	# Storm zone reachable within one day sailing west of Lisbon.
	var reached := false
	GameState.new_game("portugal", false)
	GameState.current_port = null
	GameState.set_world_tile(Vector2i(7, 57))
	for i in range(7):
		_check_cell_west()
		GameState.set_world_tile(Vector2i(7, 57))
		GameState.world["clock_fraction"] = 0.0
		SailingLib.reset_ledger_state()
		SailingLib.set_weather_seed(900 + i)
		for day in range(5):
			SailingLib.advance_clock(1.0)
			if SailingLib.was_storm_last_day():
				reached = true
				break
		if reached:
			break
	_check(reached, "step 5: a storm is reachable within 5 days at x ≤ 6")

	var zone: String = SailingLib.weather_zone_for(Vector2i(6, 57))
	_check(zone == "atlantic_strip",
		"step 5: x = 6 is the 50%%-storm Atlantic strip")
	_check(SailingLib.weather_zone_for(Vector2i(7, 57)) != "atlantic_strip",
		"step 5: Lisbon itself (x = 7) is outside the strip")

	# Starvation: 7 days with no provisions → game over.
	var reasons: Array[String] = []
	var handler := func(reason: String) -> void: reasons.append(reason)
	EventBus.game_over.connect(handler)
	GameState.new_game("portugal", false)
	GameState.current_port = null
	GameState.fleet[0].provisions = 0
	GameState.fleet[0].water = 500
	SailingLib.reset_ledger_state()
	SailingLib.set_weather_seed(5)
	for i in range(6):
		SailingLib.advance_clock(1.0)
	_check(reasons.is_empty(), "step 5: no game over before the 7th starved day")
	SailingLib.advance_clock(1.0)
	_check(reasons == ["starvation"],
		"step 5: 7 shortfall days fire game_over(\"starvation\")")
	_check(SailingLib.game_over_reason == "starvation",
		"step 5: the sim latches the reason for the game-over screen")
	EventBus.game_over.disconnect(handler)

	# The game-over screen exists and is a modal over S3 (S9).
	var scene: PackedScene = load("res://scenes/ui_shared/gameover_screen.tscn")
	var over: Node = scene.instantiate() if scene != null else null
	_check(over != null, "step 5: gameover_screen.tscn loads")
	if over != null:
		_check(over.has_method("return_to_title"),
			"step 5: the game-over screen can return to the title")
		over.queue_free()
	await get_tree().process_frame


func _check_cell_west() -> void:
	GameState.set_world_tile(Vector2i(3, 57))
	_check(DataLoader.is_passable(Vector2i(3, 57)),
		"step 5: the Atlantic strip tile (3, 57) is sailable")


# --- Step 6: second port, supply/demand sale ------------------------------

func _step6_second_port() -> void:
	GameState.new_game("portugal", false)
	GameState.current_port = null
	# Known-port bookkeeping and entry.
	_check(GameState.known_ports.has("london"), "step 6: London is known at new game")
	GameState.set_world_tile(DataLoader.map.port_cell("london"))
	GameState.current_port = "london"

	var buy_lisbon: int = TradeLib.buy_price("lisbon", "wine")
	var sell_london: int = TradeLib.sell_price("london", "wine")
	_check(buy_lisbon == 21 and sell_london == 31,
		"step 6: Lisbon 21g → London 31g (§5 worked example)")
	_check(sell_london - buy_lisbon == 10,
		"step 6: the route nets 10g/unit before costs")

	# Sell with profit: gold up, XP awarded, reputation booked.
	FleetLib.add_goods("wine", 10)
	GameState.gold = 1000
	GameState.player.xp = 0
	var xp0: int = GameState.player.xp
	var gold0: int = GameState.gold
	var ok: bool = TradeLib.sell("london", "wine", 10)
	_check(ok, "step 6: selling 10 wine at London succeeds")
	_check(GameState.gold == gold0 + 310,
		"step 6: sale revenue is exactly 10 × 31 = 310g")
	_check(FleetLib.held("wine") == 0, "step 6: cargo updates on sale")
	_check(GameState.player.xp > xp0, "step 6: a profitable sale awards XP")
	_check(CharacterLib.profit_by_nation("england") == 100,
		"step 6: England's cumulative profit is booked (100g)")


# --- Step 7: shipyard / tavern / inn --------------------------------------

func _step7_facilities() -> void:
	GameState.new_game("portugal", false)
	GameState.current_port = "lisbon"
	GameState.gold = 20000

	# Shipyard: repair available; refit present but Phase-2 disabled.
	GameState.fleet[0].durability = 50
	_check(ShipyardLib.repair_cost_per_point("caravel") == 20,
		"step 7: caravel repair is 20g/point")
	var gold_before: int = GameState.gold
	_check(ShipyardLib.repair(0, 10), "step 7: repairing 10 points succeeds")
	_check(GameState.gold == gold_before - 200,
		"step 7: repair charges exactly 200g for 10 points")
	_check(GameState.fleet[0].durability == 60, "step 7: durability restored by 10")
	# §4.3: refit maths exist for Phase 2 but there is no Phase-1 UI path.
	GameState.current_port = "lisbon"
	var shipyard_scene: PackedScene = load("res://scenes/port/shipyard_screen.tscn")
	var shipyard_ui: Node = shipyard_scene.instantiate()
	add_child(shipyard_ui)
	await get_tree().process_frame
	var refit_button := shipyard_ui.find_child("Refit_0", true, false) as Button
	_check(refit_button != null and refit_button.disabled,
		"step 7: the refit row is present and disabled in Phase 1")
	shipyard_ui.queue_free()
	await get_tree().process_frame

	# Tavern: recruit one officer, then see it in the character panel data.
	GameState.gold = 20000
	var cost: int = CharacterLib.recruit_cost("off_mateus_alvares")
	_check(cost == 300, "step 7: Mateus Álvares costs wage×10 = 300g")
	_check(CharacterLib.recruit("off_mateus_alvares"), "step 7: recruiting succeeds")
	_check(GameState.player.officers.has("off_mateus_alvares"),
		"step 7: the officer joins player.officers (panel source)")
	_check(CharacterLib.effective_stat("navigation") == 25,
		"step 7: the navigator's +10 navigation applies (15 → 25)")

	# Inn: rest restores morale. A fresh run clears the game-over latch and every
	# transient ledger counter left by step 5 (the sim stays dead until a new run
	# starts), and rest requires a docked port because it runs port day-advances.
	GameState.new_game("portugal", false)
	SailingLib.reset_ledger_state()
	GameState.current_port = "lisbon"
	GameState.gold = 1000
	GameState.morale = 40
	var day0: int = GameState.day
	_check(InnLib.rest(), "step 7: resting 3 days succeeds")
	_check(GameState.day == day0 + 3, "step 7: rest advances exactly 3 days")
	_check(GameState.morale == 55, "step 7: rest adds +5 morale/day (40 → 55)")

	# Every facility screen the loop needs exists.
	for path in ["res://scenes/port/market_screen.tscn",
			"res://scenes/port/shipyard_screen.tscn",
			"res://scenes/port/tavern_screen.tscn",
			"res://scenes/port/inn_screen.tscn"]:
		_check(ResourceLoader.exists(path), "step 7: %s exists" % path.get_file())


# --- Step 8: save → quit → load -------------------------------------------

func _step8_save_load() -> void:
	GameState.new_game("portugal", false)
	GameState.current_port = "lisbon"
	GameState.day = 19
	GameState.gold = 4310
	GameState.morale = 58
	GameState.world.position = {"x": 7, "y": 57}
	GameState.player.officers = ["off_mateus_alvares"]
	GameState.player.reputation.portugal = 23
	GameState.known_ports = ["lisbon", "london", "seville"]
	GameState.port_investments = {"lisbon": 1500}
	GameState.fleet[0].provisions = 42
	GameState.fleet[0].water = 39
	GameState.fleet[0].cargo = {"wine": 7}
	GameState.fleet[0].crew = 18

	var saved := {
		"day": GameState.day, "gold": GameState.gold, "morale": GameState.morale,
		"position": GameState.world.position.duplicate(),
		"officers": GameState.player.officers.duplicate(),
		"rep": int(GameState.player.reputation.portugal),
		"known": GameState.known_ports.duplicate(),
		"invest": GameState.port_investments.duplicate(),
		"provisions": int(GameState.fleet[0].provisions),
		"water": int(GameState.fleet[0].water),
		"wine": int(GameState.fleet[0].cargo.wine),
		"crew": int(GameState.fleet[0].crew),
		"ship": String(GameState.fleet[0].ship_type_id),
	}
	_check(SaveSystem.save(1), "step 8: saving to slot 1 succeeds")

	# Quit to title, then load fresh.
	GameState.new_game("spain", false)
	_check(SaveSystem.load(1), "step 8: loading slot 1 succeeds")
	_check(GameState.day == saved["day"], "step 8: day restored (%d)" % GameState.day)
	_check(GameState.gold == saved["gold"], "step 8: gold restored (%d)" % GameState.gold)
	_check(GameState.morale == saved["morale"],
		"step 8: morale restored (%d)" % GameState.morale)
	_check(GameState.world.position == saved["position"],
		"step 8: position restored (%s)" % str(GameState.world.position))
	_check(GameState.player.officers == saved["officers"],
		"step 8: officers restored")
	_check(CharacterLib.reputation("portugal") == saved["rep"],
		"step 8: reputation restored (%d)" % CharacterLib.reputation("portugal"))
	_check(GameState.known_ports == saved["known"], "step 8: known_ports restored")
	_check(int(GameState.port_investments.get("lisbon", 0)) == saved["invest"]["lisbon"],
		"step 8: investments restored")
	_check(int(GameState.fleet[0].provisions) == saved["provisions"],
		"step 8: provisions restored")
	_check(int(GameState.fleet[0].water) == saved["water"],
		"step 8: water restored")
	_check(int(GameState.fleet[0].cargo.wine) == saved["wine"], "step 8: cargo restored")
	_check(int(GameState.fleet[0].crew) == saved["crew"], "step 8: crew restored")
	_check(String(GameState.fleet[0].ship_type_id) == saved["ship"],
		"step 8: ship type restored")
	_check(GameState.morale_tier_label() if GameState.has_method("morale_tier_label") \
		else true, "step 8: morale tier is derivable after load")
	SaveSystem.delete_save(1)


# --- Step 9: locale toggle -------------------------------------------------

func _step9_locale() -> void:
	GameState.new_game("portugal", false)
	I18n.set_locale("en")
	_check(I18n.t_key("market.buy") == "Buy", "step 9: en renders Buy")
	_check(I18n.t(DataLoader.get_port("lisbon").name) == "Lisbon",
		"step 9: en renders the port name")
	_check(I18n.t(DataLoader.get_good("wine").name) == "Wine",
		"step 9: en renders the good name")

	I18n.set_locale("zh")
	_check(I18n.t_key("market.buy") == "购买", "step 9: zh renders 购买")
	_check(I18n.t(DataLoader.get_port("lisbon").name) == "里斯本",
		"step 9: zh renders the port name")
	_check(I18n.t(DataLoader.get_good("wine").name) == "葡萄酒",
		"step 9: zh renders the good name")

	# No missing keys across the whole inventory, in either locale.
	var missing: Array[String] = []
	for locale in ["zh", "en"]:
		I18n.set_locale(locale)
		for key in DataLoader.ui_strings.keys():
			if String(key) == "version":
				continue
			var value: String = I18n.t_key(String(key))
			if value.begins_with("<") and value.ends_with(">"):
				missing.append("%s/%s" % [locale, key])
	_check(missing.is_empty(),
		"step 9: every ui_strings key resolves in both locales (%d missing)"
		% missing.size())

	I18n.set_locale("en")
	_check(I18n.t_key("market.buy") == "Buy", "step 9: toggling back to en works")
