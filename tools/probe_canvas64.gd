extends Node
## TEMPORARY acceptance probe (uncommitted) — canvas-64 + sea_fix_r4 round.
## Boots the REAL world scene on the DISPLAY renderer, drives the acceptance
## protocol: bay-mouth foam (3 land sides, open waterway clean), the
## two-level sea shimmer (perceptibility + a long-session lifecycle check),
## and the canvas-64 near/wide captures.

const WorldScene := preload("res://scenes/world/world_map.tscn")
const TextureRegistryLib := preload("res://scripts/ui/texture_registry.gd")
const UiKit := preload("res://scripts/ui_kit.gd")

const OUT := "/home/weidong/repo/SailAge/art_review"
const BAY_CELL := Vector2i(2054, 598)  # land N/E/S, open W, NW+SW land
const OPEN_SEA := Vector2i(2010, 650)  # open Atlantic water

var _world: Node = null

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	# The real game bootstraps the texture registry on the title screen;
	# this probe never passes it, so register here (same one-time pass).
	TextureRegistryLib.ensure_registered()
	print("PROBE registry ids=%d foam strips resolve=%s" % [
		TextureRegistryLib.registered_count,
		UiKit.icon_texture("shore_n") != null])
	GameState.new_game("portugal", false)
	_world = WorldScene.instantiate()
	add_child(_world)
	for i in 10:
		await get_tree().process_frame
	print("PROBE world children=%d loaded=%s err='%s' cam=%s" % [
		_world.get_child_count(), _world._is_loaded(),
		_world._loader.last_error if _world._loader != null else "?",
		_world.get_node_or_null("Camera2D")])
	await _teleport(OPEN_SEA)
	await _settle(6)

	# --- 1. the two-level shimmer, perceptibility (two frames 0.4 s apart)
	var a := await _grab()
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var b := get_viewport().get_texture().get_image()
	var rep := _anim_delta(a, b)
	print("PROBE anim t0: %s" % rep)
	_save_side_by_side(a, b, "%s/sea_fix_r4_anim.png" % OUT)

	# --- 2. the long-session lifecycle: ~2 min of camera moves across chunk
	# borders (chunk free/rebuild cycles), then re-measure.
	var moves := [
		Vector2i(1600, 400), Vector2i(2159, 615), Vector2i(0, 615),
		Vector2i(4320, 615), Vector2i(3000, 900), Vector2i(1200, 1500),
		Vector2i(600, 300), Vector2i(2500, 700), Vector2i(1800, 1100),
		Vector2i(2054, 598),
	]
	var started := Time.get_ticks_msec()
	for round in 2:
		for cell in moves:
			await _teleport(cell)
			await _settle(2)
		# settle back on open sea for the re-measure
		await _teleport(OPEN_SEA)
		await _settle(6)
	var elapsed := Time.get_ticks_msec() - started
	var c := await _grab()
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var d := get_viewport().get_texture().get_image()
	var rep2 := _anim_delta(c, d)
	print("PROBE anim after %d ms of chunk churn: %s" % [elapsed, rep2])
	_save_side_by_side(c, d, "%s/sea_fix_r4_anim_late.png" % OUT)

	# --- 3. the bay: 3 land sides foam, the open waterway edge clean
	await _teleport(BAY_CELL)
	await _settle(8)
	var bay := await _grab()
	bay.save_png("%s/sea_fix_r4_bay.png" % OUT)
	bay.save_png("%s/14_canvas64_probe.png" % OUT)
	_bay_edges(bay)
	# ×4 nearest crop of the bay mouth around the screen centre
	_save_crop_zoom(bay, Rect2i(576, 296, 128, 128), 4,
		"%s/sea_fix_r4_bay_zoom.png" % OUT)
	# a marker-hidden frame for the unpolluted per-edge measurement (the
	# 64px token sprite shares the cell with its edge bands)
	_world.get_node("FleetMarker").visible = false
	await _settle(3)
	var clean := await _grab()
	clean.save_png("%s/sea_fix_r4_bay_clean.png" % OUT)
	_bay_edges(clean)
	_world.get_node("FleetMarker").visible = true

	# --- 4. the canvas-64 wide capture (zoom 0.5), then back to near
	_world.toggle_world_zoom()
	await _settle(6)
	var wide := await _grab()
	wide.save_png("%s/14b_canvas64_wide.png" % OUT)
	print("PROBE zoom now %.2f wide=%s" % [_world.world_zoom(),
		_world.world_zoom_wide()])
	_world.toggle_world_zoom()
	await _settle(4)
	print("PROBE zoom back %.2f" % _world.world_zoom())
	print("PROBE DONE")
	get_tree().quit(0)


func _teleport(cell: Vector2i) -> void:
	GameState.set_world_tile(cell)
	_world.sync_from_state()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Perceptibility of the two-level dither: blue-channel deltas on water
## pixels between two frames 0.4 s apart (the scroll shifts 64 px per 0.4 s
## — half the mask period — so dithered cells flip their level).
func _anim_delta(a: Image, b: Image) -> String:
	var moved := 0
	var big := 0
	var max_delta := 0
	var sum := 0
	for y in range(48, 680, 2):
		for x in range(8, 1000, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			# water-ish on both frames: blue-dominant, not foam-white, not UI
			if ca.b < 0.3 or ca.r > 0.35 or cb.b < 0.3 or cb.r > 0.35:
				continue
			var da := int(absf(roundf(ca.b * 255.0 - cb.b * 255.0)))
			moved += 1
			sum += da
			if da > max_delta:
				max_delta = da
			if da >= 15:
				big += 1
	return ("%d water samples, mean dB %.1f, max dB %d, %d samples ≥ 15 (%.1f%%)"
		% [moved, float(sum) / maxf(moved, 1), max_delta, big,
		100.0 * big / maxf(moved, 1)])


func _save_side_by_side(a_img: Image, b_img: Image, path: String) -> void:
	var a := a_img.duplicate() as Image
	var b := b_img.duplicate() as Image
	if a.get_format() != Image.FORMAT_RGBA8:
		a.convert(Image.FORMAT_RGBA8)
	if b.get_format() != Image.FORMAT_RGBA8:
		b.convert(Image.FORMAT_RGBA8)
	var out := Image.create_empty(a.get_width() * 2 + 4, a.get_height(),
		false, Image.FORMAT_RGBA8)
	out.blit_rect(a, Rect2i(0, 0, a.get_width(), a.get_height()), Vector2i.ZERO)
	out.blit_rect(b, Rect2i(0, 0, b.get_width(), b.get_height()),
		Vector2i(a.get_width() + 4, 0))
	out.save_png(path)


func _save_crop_zoom(img: Image, rect: Rect2i, factor: int, path: String) -> void:
	var out := Image.create_empty(rect.size.x * factor, rect.size.y * factor,
		false, img.get_format())
	for y in rect.size.y:
		for x in rect.size.x:
			var p := img.get_pixel(rect.position.x + x, rect.position.y + y)
			for fy in factor:
				for fx in factor:
					out.set_pixel(x * factor + fx, y * factor + fy, p)
	out.save_png(path)


## The bay screen sample: the cell sits centred (640, 360) at zoom 1.0,
## 64 px cells. Land edges N/E/S must carry foam in their edge bands; the
## open W edge core must be foam-free (corner stubs of the masked N/S
## strips legitimately wrap 4px into the W band ends — excluded here).
func _bay_edges(img: Image) -> void:
	var foam := Color8(223, 240, 244)  # the §4.8 foam hex #dff0f4
	var results := ""
	for edge in [["N", Rect2i(614, 328, 52, 11)],
			["E", Rect2i(661, 334, 11, 52)],
			["S", Rect2i(614, 381, 52, 11)],
			["W", Rect2i(608, 334, 11, 52)]]:
		var label: String = edge[0]
		var rect: Rect2i = edge[1]
		var count := 0
		var min_dist := 999
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var p := img.get_pixel(x, y)
				var dist := absf(p.r - foam.r) + absf(p.g - foam.g) \
					+ absf(p.b - foam.b)
				min_dist = mini(min_dist, int(dist * 255.0))
				if dist < 0.12:
					count += 1
		results += "%s:%d foam px (min d %d)  " % [label, count, min_dist]
	print("PROBE bay edges: %s" % results)
