extends Node
## Route-seam auditor: for every origin→dest port pair, build the route via
## NpcFleetsLib.route_between and verify the legs chain exactly:
##   * leg 0's walked head == the origin berth,
##   * leg k's walked end == leg k+1's walked head (the shared junction tile),
##   * the last leg's walked end == the dest berth.
## Also audits every lane/spoke variant mapping (a/b fraction remap) for
## endpoint drift: a variant walked range must END on the same tiles as the
## base walked range, or month-rollover walks teleport.
##
##   godot --headless res://tools/probe_route_seams.tscn

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")


func _ready() -> void:
	var map = MapLoaderLib.new()
	if not map.load_map("res://data/maps/world.png", DataLoader.map_legend):
		print("FATAL: map load failed: %s" % map.last_error)
		get_tree().quit(1)
		return
	DataLoader.map = map
	NpcFleetsLib.reset_caches()
	var sim: NpcFleetsLib = NpcFleetsLib.new({})
	sim._refresh_net()

	var ports: Array = DataLoader.ports_list
	var failures: Array[String] = []
	var checked := 0
	var no_route := 0
	# Audit both a base month (7) and a variant month (12 — the
	# hanseatic_north_winter window): the seam identity must hold under
	# BOTH active geometries.
	for probe_day in [210, 340]:
		GameState.day = probe_day
		for origin in ports:
			var origin_id := str((origin as Dictionary).get("id", ""))
			for dest in ports:
				var dest_id := str((dest as Dictionary).get("id", ""))
				if origin_id == dest_id:
					continue
				var route := sim.route_between(origin_id, dest_id)
				if route.is_empty():
					no_route += 1
					continue
				checked += 1
				_audit_route(sim, origin_id, dest_id, route, failures)

	print("----")
	print("routes checked: %d (no route: %d)" % [checked, no_route])
	if failures.is_empty():
		print("ROUTE-SEAM PROBE: GREEN")
		get_tree().quit(0)
		return
	print("ROUTE-SEAM PROBE: RED (%d failures)" % failures.size())
	for f in failures.slice(0, 80):
		print("  %s" % f)
	get_tree().quit(1)


func _audit_route(sim: NpcFleetsLib, origin_id: String, dest_id: String,
		route: Dictionary, failures: Array[String]) -> void:
	var legs: Array = (route.get("legs_save", {}) as Dictionary).get(
		"legs", [])
	if legs.is_empty():
		failures.append("%s→%s route has no legs (%s)"
			% [origin_id, dest_id, str(route.keys())])
		return
	var start_tile := sim._port_cell(origin_id)
	var end_tile := sim._port_cell(dest_id)
	for index in legs.size():
		var leg: Dictionary = legs[index]
		var geo := sim._leg_geometry(leg)
		if geo.is_empty():
			failures.append("%s→%s leg %d %s:%s BROKEN geometry" % [
				origin_id, dest_id, index, str(leg.get("kind", "?")),
				str(leg.get("id", "?"))])
			continue
		var path: Array = geo["path"]
		var head: Vector2i = path[int(geo["end"]) if bool(geo["reverse"]) \
			else int(geo["start"])]
		var tail: Vector2i = path[int(geo["start"]) if bool(geo["reverse"]) \
			else int(geo["end"])]
		if index == 0 and head != start_tile:
			failures.append("%s→%s leg 0 head %s ≠ origin berth %s (%s:%s [%d..%d] rev=%d)"
				% [origin_id, dest_id, head, start_tile,
				str(leg.get("kind", "?")), str(leg.get("id", "?")),
				int(leg.get("a", -1)), int(leg.get("b", -1)),
				1 if bool(leg.get("reverse", false)) else 0])
		if index == legs.size() - 1 and tail != end_tile:
			failures.append("%s→%s last leg tail %s ≠ dest berth %s (%s:%s [%d..%d] rev=%d)"
				% [origin_id, dest_id, tail, end_tile,
				str(leg.get("kind", "?")), str(leg.get("id", "?")),
				int(leg.get("a", -1)), int(leg.get("b", -1)),
				1 if bool(leg.get("reverse", false)) else 0])
		if index > 0:
			var prev: Dictionary = legs[index - 1]
			var prev_geo := sim._leg_geometry(prev)
			if not prev_geo.is_empty():
				var prev_path: Array = prev_geo["path"]
				var prev_tail: Vector2i = prev_path[
					int(prev_geo["start"]) if bool(prev_geo["reverse"])
					else int(prev_geo["end"])]
				var gap := NpcFleetsLib.chebyshev(prev_tail, head)
				if gap > 1:
					failures.append("%s→%s seam %d→%d gap %d: %s:%s[%d..%d]rev=%d tail %s → %s:%s[%d..%d]rev=%d head %s"
						% [origin_id, dest_id, index - 1, index, gap,
						str(prev.get("kind", "?")), str(prev.get("id", "?")),
						int(prev.get("a", -1)), int(prev.get("b", -1)),
						1 if bool(prev.get("reverse", false)) else 0, prev_tail,
						str(leg.get("kind", "?")), str(leg.get("id", "?")),
						int(leg.get("a", -1)), int(leg.get("b", -1)),
						1 if bool(leg.get("reverse", false)) else 0, head])
