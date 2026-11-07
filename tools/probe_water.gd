extends Node2D
## Diagnostic probe for the §4.8 deep-sea darkening (2026-11-07 patch
## amendment). Boots the live world scene, aims the camera at the Atlantic
## west of Portugal, then dumps:
##   1. chunk/water-layer inventory — water layers carry NO material (the
##      animated-sea retirement) and ONE DepthPatch child (128×128 gray,
##      multiply material)
##   2. the water atlas columns 0 and 1 byte-comparison (both kinds stamp
##      the same painted wang tile)
##   3. captures: deep view (patch on), deep view (patches hidden —
##      baseline), coast-spanning view (the ramp)
## Read-only wrt game data; output is stdout + the capture PNGs.

func _ready() -> void:
	# The production boot registers textures in title_screen._ready(); a direct
	# scene boot skips it, so replicate it here or every wang id misses and the
	# water falls back to the retired two-tone fills (a probe-only artifact).
	TextureRegistry.ensure_registered()
	var wm: Node2D = load("res://scenes/world/world_map.tscn").instantiate()
	add_child(wm)
	_run(wm)

func _run(wm: Node2D) -> void:
	for i in 8:
		await get_tree().process_frame
	var chunks: Node2D = wm._chunks_root
	# A: open Atlantic west of Portugal (all-deep view).
	wm._fleet_cell = Vector2i(2040, 600)
	wm._update_camera()
	for i in 30:
		await get_tree().process_frame

	print("PROBE chunks spawned: ", chunks.get_child_count())
	var water: TileMapLayer = null
	var patches := 0
	var mat_ok := true
	for c in chunks.get_children():
		for ch in c.get_children():
			if ch is TileMapLayer and ch.name == "Water":
				if water == null:
					water = ch
				if ch.material != null:
					mat_ok = false
				for p in ch.get_children():
					if p is Sprite2D and p.name == "DepthPatch":
						patches += 1
	if water == null:
		print("PROBE FAIL: no water layer found")
		get_tree().quit(1)
		return
	print("PROBE water material: ", water.material,
		" (expected null — retirement)")
	print("PROBE water layers with material: ", not mat_ok,
		" (expected false)")
	print("PROBE DepthPatch count: ", patches)
	var first_patch := _first_patch(chunks)
	if first_patch != null:
		print("PROBE patch texture: ", first_patch.texture.get_size(),
			" blend ", (first_patch.material as CanvasItemMaterial).blend_mode,
			" (expected 128x128, 4=MUL)")

	# --- the water atlas: are the two kind columns identical? ---
	var ts: TileSet = water.tile_set
	var src_id := ts.get_next_source_id() - 1
	var src := ts.get_source(src_id) as TileSetAtlasSource
	var atlas := src.texture.get_image()
	var px := ts.tile_size.x
	var col0 := atlas.get_region(Rect2i(0, 0, px, px))
	var col1 := atlas.get_region(Rect2i(px, 0, px, px))
	print("PROBE column0==column1: ", col0.get_data() == col1.get_data())

	await _capture("/tmp/opencode/probe_capture_deep.png")
	# baseline: hide every patch — pure painted water.
	_set_patches_visible(chunks, false)
	await _capture("/tmp/opencode/probe_capture_deep_nodist.png")
	_set_patches_visible(chunks, true)
	# C: coast-spanning view — ocean west, Iberian coast at the right edge.
	wm._fleet_cell = Vector2i(2065, 634)
	wm._update_camera()
	for i in 30:
		await get_tree().process_frame
	await _capture("/tmp/opencode/probe_capture_coast.png")
	get_tree().quit()

func _first_patch(chunks: Node2D) -> Sprite2D:
	for c in chunks.get_children():
		for ch in c.get_children():
			if ch is TileMapLayer and ch.name == "Water":
				for p in ch.get_children():
					if p is Sprite2D and p.name == "DepthPatch":
						return p
	return null

func _set_patches_visible(chunks: Node2D, shown: bool) -> void:
	for c in chunks.get_children():
		for ch in c.get_children():
			if ch is TileMapLayer and ch.name == "Water":
				for p in ch.get_children():
					if p is Sprite2D and p.name == "DepthPatch":
						p.visible = shown

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("PROBE CAPTURE saved ", path, " ", img.get_size())
