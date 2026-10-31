extends Node
func _ready() -> void:
	DataLoader.ensure_map()
	var sim = load("res://scripts/world/npc_fleets.gd").new({})
	print("seville cell: ", sim._port_cell("seville"), " barcelona: ", sim._port_cell("barcelona"))
	var r := sim.route_between("seville", "barcelona")
	print("route seville>barcelona: ", "len=" , r.get("length", -1), " legs=", (r.get("legs_save", {}) as Dictionary).get("legs", []).size())
	var r2 := sim.route_between("lisbon", "porto")
	print("route lisbon>porto: ", r2.get("length", -1))
	# check node presence
	sim._refresh_net()
	var k1 := sim._node_index.get(sim._cell_key(sim._port_cell("seville")), "MISSING")
	var k2 := sim._node_index.get(sim._cell_key(sim._port_cell("cadiz")), "MISSING")
	print("seville node: ", k1, " cadiz node: ", k2)
	var r3 := sim.route_between("seville", "cadiz")
	print("route seville>cadiz: ", r3.get("length", -1), " legs: ", (r3.get("legs_save", {}) as Dictionary).get("legs", []))
	# count how many port pairs route successfully
	var ports := sim.nation_ports("spain")
	var ok := 0
	var bad := []
	for a in ports:
		for b in ports:
			if a == b: continue
			if not sim.route_between(a, b).is_empty(): ok += 1
			else: bad.append(a + ">" + b)
	print("spain pairs ok: ", ok, " bad: ", bad.size(), bad.slice(0, 6))
	get_tree().quit(0)
