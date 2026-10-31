extends Node
func _ready() -> void:
	DataLoader.ensure_map()
	var sim = load("res://scripts/world/npc_fleets.gd").new({})
	sim._refresh_net()
	var cu: int = sim._node_index.get(sim._cell_key(Vector2i(1021, 312)), -1)
	var cv: int = sim._node_index.get(sim._cell_key(Vector2i(1022, 322)), -1)
	print("node u=", cu, " v=", cv)
	for edge in sim._adjacency.get(cu, []):
		if int(edge[0]) == cv:
			print("u->v edge: ", edge)
	for edge in sim._adjacency.get(cv, []):
		if int(edge[0]) == cu:
			print("v->u edge: ", edge)
	get_tree().quit(0)
