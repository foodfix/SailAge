extends Node
## One-shot nesting audit: boots the REAL port screen, dumps the layout
## tree, and checks every child rect against its registered parent row's
## rect (the user report: cards.market shows outside facility_grid.pair.0).

const PortScene := preload("res://scenes/port/port_screen.tscn")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")


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
	var screen: Control = PortScene.instantiate()
	add_child(screen)
	for i in range(6):
		await get_tree().process_frame
	var rows: Array = RegistryLib.tree("port")
	var by_id := {}
	for row: Dictionary in rows:
		by_id[row["id"]] = row
	var violations: Array[String] = []
	for row: Dictionary in rows:
		var pid: String = row.get("parent", "")
		if pid.is_empty() or not by_id.has(pid):
			continue
		var c: Dictionary = row["rect_tiles"]
		var p: Dictionary = by_id[pid]["rect_tiles"]
		var inside: bool = c.x >= p.x - 1 and c.y >= p.y - 1 \
			and c.x + c.w <= p.x + p.w + 1 \
			and c.y + c.h <= p.y + p.h + 1
		if not inside:
			violations.append("%s (x%d y%d w%d h%d) outside %s "
				+ "(x%d y%d w%d h%d)" % [row["id"], c.x, c.y, c.w, c.h,
				pid, p.x, p.y, p.w, p.h])
	if violations.is_empty():
		print("NEST OK — all %d rows nest inside their registered parents"
				% rows.size())
	else:
		print("NEST VIOLATIONS (%d of %d rows):" % [violations.size(),
				rows.size()])
		for v in violations:
			print("  ", v)
	print("--- sample: pair.0 / cards.market ---")
	for row: Dictionary in rows:
		if row["id"] in ["facility_grid.pair.0", "cards.market",
				"facility_grid", "toolbar"]:
			print(JSON.stringify(row))
	get_tree().quit(0)
