extends Node
## One-shot probe: mount the market, dump the goods_scroll tree row +
## its content node's minimums — what the studio's drag floors see.

const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const MarketScene := preload("res://scenes/port/market_screen.tscn")


func _ready() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [], "reputation": {},
	}
	for nation in ["portugal", "spain", "england", "holland", "ottoman",
			"italy"]:
		GameState.player["reputation"][nation] = 0
	GameState.fleet = [FleetLib.new_ship("caravel", 0)]
	GameState.day = 1
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = "lisbon"
	GameState.port_investments = {}
	GameState.known_ports = ["lisbon"]
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list)
	GameState.market_events = []
	GameState.npc_fleets = []
	GameState.npc_port_log = []
	EconomyLib.reset_overrides()
	var port: Dictionary = DataLoader.get_port("lisbon")
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		"clock_fraction": 0.5, "weather": "fair",
	}
	var screen: Control = MarketScene.instantiate()
	add_child(screen)
	for i in range(6):
		await get_tree().process_frame
	for row: Dictionary in RegistryLib.tree("market"):
		if row["id"] in ["goods_scroll", "table", "table_frame"]:
			print("ROW ", JSON.stringify(row))
	var scroll: Control = screen.get_node("TableFrame/Table/GoodsScroll")
	var rows: Control = screen.get_node("TableFrame/Table/GoodsScroll/GoodsRows")
	print("SCROLL min=", scroll.get_minimum_size(),
			" custom_min=", scroll.custom_minimum_size,
			" vmode=", scroll.vertical_scroll_mode,
			" hmode=", scroll.horizontal_scroll_mode,
			" size=", scroll.size, " pos=", scroll.position)
	print("ROWS  min=", rows.get_minimum_size(),
			" custom_min=", rows.custom_minimum_size,
			" size=", rows.size,
			" hflags=", rows.size_flags_horizontal,
			" vflags=", rows.size_flags_vertical)
	var frame: Control = screen.get_node("TableFrame")
	print("FRAME size=", frame.size, " pos=", frame.position)
	# THE STUDIO EDIT: shrink + move goods_scroll (the user report —
	# pre-fix this snapped back to the content width floor).
	RegistryLib.apply_overrides("market", "goods_scroll",
			{"x": 2, "y": 5, "w": 30, "h": 12})
	await get_tree().process_frame
	await get_tree().process_frame
	print("SCROLL after edit size=", scroll.size, " pos=", scroll.position,
			" (want pos=(64,160) size=(960,384) — the edit sticks)")
	get_tree().quit(0)
