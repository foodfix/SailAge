extends Node
## One-shot visual smoke for the waterline VFX (80-* §4.8 2026-11-07):
## boots the world on a sailing east-bound caravel fixture, steps the fx
## clock a few frames, and captures the viewport around the fleet token.
## Capture lands in user://screenshots/ (the F10 convention).
const WorldScene := preload("res://scenes/world/world_map.tscn")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

func _ready() -> void:
	GameState.player = {"nation_id": "portugal",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 10, "navigation": 60, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 60, "luck": 10},
		"xp": 0, "level": 1, "officers": [],
		"reputation": {}}
	GameState.fleet = [{
		"ship_type_id": "caravel", "durability": 100, "crew": 30,
		"cannons": 0, "id": "flagship", "name": "Flagship",
	}]
	# Open sea east of the Atlantic primer: a cell the map reports as water.
	GameState.world = {"position": {"x": 2160, "y": 1080}, "heading": "e",
		"day": 1, "clock_fraction": 0.5, "weather": "fair",
		"sail_trim": "full", "wind_dir": "e", "map_id": "world"}
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	# a sailing NPC fleet nearby so the sandwich shows on a marker too
	GameState.npc_fleets = [{
		"id": "npc_probe", "role": "trade", "nation_id": "spain",
		"cell": {"x": 2162, "y": 1080},
		"ship_type": "galleon", "heading": "e", "sailing": true,
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {}, "captain": {"pool_id": "", "name_index": 0},
		"cooldown_until_day": 0, "seed": 1, "dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
		"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
		"convoy_leader": "", "convoy_count": 0, "wake": [], "stall": "",
		"on_berth": false, "letter": "S",
	}]
	# let the world load + the marker pass run, then drive the fx clock
	for i in 12:
		await get_tree().process_frame
	world._tick_waterline_fx(0.05)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := OS.get_user_data_dir() + "/screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/waterline_probe_%d.png" % [dir,
		Time.get_ticks_msec()]
	img.save_png(path)
	print("PROBE SAVED: ", path)
	# a zoomed crop around the fleet token for the review
	var fleet_px: Vector2 = world.get_node("FleetMarker").position
	var crop := 160
	var origin := (fleet_px - Vector2(crop, crop) * 0.5).clamp(
		Vector2.ZERO, Vector2(img.get_width(), img.get_height())
		- Vector2(crop * 2, crop * 2))
	var region := img.get_region(Rect2(origin, Vector2(crop * 2, crop * 2)))
	var crop_path := "%s/waterline_probe_crop_%d.png" % [dir,
		Time.get_ticks_msec()]
	region.save_png(crop_path)
	print("PROBE CROP: ", crop_path)
	get_tree().quit(0)
