extends Node
## TEMPORARY production probe (master, uncommitted): boots the REAL world
## scene on the DISPLAY renderer and dumps water-layer ground truth.

const WorldScene := preload("res://scenes/world/world_map.tscn")
const WaterLayerLib := preload("res://scripts/world/water_layer.gd")

func _ready() -> void:
	var mat: ShaderMaterial = WaterLayerLib.build_material()
	print("PROBE build_material -> %s" % ("null" if mat == null else "OK"))
	if mat != null:
		print("PROBE shader=%s mask=%s motion=%s period=%s darken=%s" % [
			mat.shader != null, mat.get_shader_parameter("u_mask") != null,
			mat.get_shader_parameter("u_motion"),
			mat.get_shader_parameter("u_period"), mat.get_shader_parameter("u_darken")])
	GameState.new_game("spain", false)
	var world: Node = WorldScene.instantiate()
	await get_tree().process_frame
	get_tree().root.add_child(world)
	for i in 8:
		await get_tree().process_frame
	var loader = DataLoader.map
	var chunks: Dictionary = loader._chunks
	print("PROBE live chunks=%d" % chunks.size())
	var water_nodes := 0
	var attached := 0
	for key in chunks:
		var chunk: Node = chunks[key]
		var water: TileMapLayer = chunk.get_node_or_null("Water")
		if water == null:
			continue
		water_nodes += 1
		if water.material != null:
			attached += 1
			if water_nodes == 1:
				var m: ShaderMaterial = water.material
				print("PROBE water[0].material shader=%s mask=%s motion=%s" % [
					m.shader != null, m.get_shader_parameter("u_mask") != null,
					m.get_shader_parameter("u_motion")])
	print("PROBE water children=%d material-attached=%d" % [water_nodes, attached])
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("/tmp/opencode/sea_probe_a.png")
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var img2 := get_viewport().get_texture().get_image()
	img2.save_png("/tmp/opencode/sea_probe_b.png")
	var a := get_viewport().get_texture().get_image()
	var diff := 0
	var total := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var c1 := a.get_pixel(x, y)
			var c2 := img2.get_pixel(x, y)
			if c1.b > 0.25 and c1.r < 0.35 and c1.g < c1.b:
				total += 1
				if c1 != c2:
					diff += 1
	print("PROBE sea-pixel diff between frames: %d/%d" % [diff, total])
	print("PROBE DONE")
	get_tree().quit()
