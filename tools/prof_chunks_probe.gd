extends Node
func _ready() -> void:
	TextureRegistry.ensure_registered()
	var MapLoaderLib := load("res://scripts/world/map_loader.gd")
	var loader = MapLoaderLib.new()
	loader.load_map("res://data/maps/world.png", DataLoader.map_legend)
	loader.tile_size_px = 64
	var t1 := Time.get_ticks_usec()
	loader._ensure_tile_set()
	print("PROF ensure_tile_set ms: ", (Time.get_ticks_usec() - t1) / 1000)
	var t1b := Time.get_ticks_usec()
	var wl := load("res://scripts/world/water_layer.gd")
	var layer = wl.build_layer(64, ["n", "ne", "e", "se", "s", "sw", "w", "nw"])
	print("PROF first water layer ms: ", (Time.get_ticks_usec() - t1b) / 1000,
		" foam=", wl.foam_ready, " wang=", wl.wang_ready_for_px(64))
	layer.free()
	var parent := Node2D.new()
	add_child(parent)
	loader.build_tilemap(parent)
	var t3 := Time.get_ticks_usec()
	for n in 6:
		loader.update_chunks(Vector2i(2200 + n * 40, 460), Vector2i(20, 12))
		var now := Time.get_ticks_usec()
		print("PROF update_chunks[%d] ms: %d live=%d" % [n, (now - t3) / 1000, loader.live_chunk_count()])
		t3 = now
	print("PROF done")
	get_tree().quit(0)
