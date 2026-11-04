class_name PortraitComposer
extends RefCounted
## The Phase-10 procedural portrait composer (IMPLEMENT-Phase10.md decision 10,
## docs/80-UI-UX.md §4.8 portrait block + the W3-D composer contract in
## `tools/ui_art/portraits/README.md` + `anchors.json`).
##
## Portrait ladder (override wins): `assets/ui/overrides/portrait_{id}.png`
## (only the 24 legend captains + 4 named pirates ever get one) beats the
## procedural composition. The procedural side stacks the 72×96 RGBA part
## sheets in the fixed order **base → face → eyes → beard → hair → cloth**
## (later layers win; the only designed overlaps are hair-over-face,
## beard-over-face, cloth-over-base), driven by the captain's `appearance`
## dict (`data/captains.json`: face ∈ lean|round|scarred|weathered, beard ∈
## clean|forked|full|stubble, hair ∈ black|brown|grey_streaked|sun_bleached,
## eyes ∈ dark|grey|hazel|pale_blue) and the role cloth (7 roles + "player",
## per the §4.8 cloth rule). Missing layer file ⇒ the layer is skipped (base
## alone still composes); the results are cached by
## (appearance, role, owner) so 1 275 captains cost at most 256 + cloth
## compositions. Deterministic, instant, fully offline — no hash, no RNG.
##
## Palette swaps (the W3-D pins):
## - every beard sheet renders in HAIR_BROWN `#6b4a2a` as the swap SOURCE;
##   the composer re-maps those pixels to the captain's hair hex (black
##   `#1a1a1e`, brown `#6b4a2a`, grey_streaked `#b9bcc0` — its `#e8e6df`
##   streak strands stay, sun_bleached `#d9b98a`), so a black-haired captain
##   gets a black beard;
## - the patrol/privateer sheets carry the neutral `CLOTH_LINE` body plus a
##   diagonal `CLOTH_ACCENT` `#d9a441` sash; the composer re-tints exactly
##   those sash pixels to the owner nation's `CLOTH_{nation}` hex (roles read
##   national — distinguished by the role badge, §4.8). An empty/unknown
##   owner keeps the ACCENT sash.
##
## Every composed hex belongs to the §4.8 `portrait` block; no new colors.
## Preload-friendly static (the repo convention: consumers preload the
## script; the `class_name` stays for the W4+ contract).

## Part-sheet dir (the W3-D output; ids `pp_*`, 72×96 RGBA).
const PART_DIR := "res://assets/ui/portraits"
## Canvas (decision 6: portraits 72×96, 3:4 vertical bust).
const CANVAS_W := 72
const CANVAS_H := 96

## The documented guard-read defaults (a person without an `appearance`
## dict — the player block — composes as lean/clean/black/dark).
const DEFAULT_APPEARANCE := {
	"face": "lean", "beard": "clean", "hair": "black", "eyes": "dark",
}
## Role default (the cloth id guard; the player card passes "player").
const DEFAULT_ROLE := "trader"
## The patrol/privateer roles whose sash cells re-tint to the owner nation.
const SASH_ROLES: Array[String] = ["patrol", "privateer"]

## hair id → hex (the §4.8 portrait block; the beard-swap TARGET table).
const HAIR_HEX := {
	"black": "1a1a1e",        # HAIR_BLACK
	"brown": "6b4a2a",        # HAIR_BROWN (== the beard swap source)
	"grey_streaked": "b9bcc0",  # HAIR_GREY (the #e8e6df strands stay)
	"sun_bleached": "d9b98a",   # HAIR_BLEACHED
}
## The beard swap SOURCE: every beard sheet renders HAIR_BROWN (W3-D pin 2).
const BEARD_SOURCE_HEX := "6b4a2a"
## The sash swap SOURCE: CLOTH_ACCENT cells on patrol/privateer (W3-D pin 1).
const SASH_SOURCE_HEX := "d9a441"
## owner nation → CLOTH_{nation} hex (the §4.8 portrait block table).
const NATION_CLOTH_HEX := {
	"portugal": "1a8c4e", "spain": "b3191f", "england": "274b8f",
	"holland": "d97b1e", "ottoman": "6a3d9a", "italy": "c9a227",
}

## (appearance|role|owner) → ImageTexture.portrait_texture cache (static:
## the composer is pure, so one entry serves every consumer this session).
static var _cache: Dictionary = {}
## id → override Texture2D (the ladder's first rung is cached by id so
## repeat calls return the same texture instance).
static var _override_cache: Dictionary = {}
## The override dir (the ladder's first rung). Production points at the
## committed asset dir; the suite re-points it at a temp dir to prove the
## override-wins rule without touching `assets/` (see
## `tools/test_portrait_composer.gd`).
static var _override_dir := "res://assets/ui/overrides"


## The override file path for a person id (the test seam: `_override_dir`
## above is the redirectable half).
static func _override_path(id: String) -> String:
	return "%s/portrait_%s.png" % [_override_dir, id]


## The exact part-file list for an appearance + role, in stack order
## **base → face → eyes → beard → hair → cloth** (the W3-D composer
## contract). `appearance` is guard-read against DEFAULT_APPEARANCE; a
## role value without a cloth sheet still lists the file — the compose
## skips missing files, the list states the CONTRACT.
static func part_files(appearance: Dictionary, role: String) -> Array[String]:
	var face := str(appearance.get("face", DEFAULT_APPEARANCE["face"]))
	var eyes := str(appearance.get("eyes", DEFAULT_APPEARANCE["eyes"]))
	var beard := str(appearance.get("beard", DEFAULT_APPEARANCE["beard"]))
	var hair := str(appearance.get("hair", DEFAULT_APPEARANCE["hair"]))
	var cloth_role := role if not role.is_empty() else DEFAULT_ROLE
	return [
		"pp_base.png",
		"pp_face_%s.png" % face,
		"pp_eyes_%s.png" % eyes,
		"pp_beard_%s.png" % beard,
		"pp_hair_%s.png" % hair,
		"pp_cloth_%s.png" % cloth_role,
	]


## Composes the 72×96 RGBA bust for `appearance` + `role` (owner-nation
## re-tint per the sash rule). Pure: same input → byte-identical output.
## Missing layer files are skipped (base alone still composes); a missing
## base yields a fully transparent canvas (`portrait_texture` turns that
## case into null).
static func compose_image(appearance: Dictionary, role: String,
		owner_nation: String = "") -> Image:
	var canvas := Image.create(CANVAS_W, CANVAS_H, false, Image.FORMAT_RGBA8)
	var hair_hex := str(HAIR_HEX.get(
		str(appearance.get("hair", DEFAULT_APPEARANCE["hair"])), ""))
	var sash_hex := ""
	if str(role) in SASH_ROLES:
		sash_hex = str(NATION_CLOTH_HEX.get(str(owner_nation), ""))
	for file_name in part_files(appearance, role):
		var layer := _load_layer("%s/%s" % [PART_DIR, file_name])
		if layer == null:
			continue  # missing part — skip the layer, keep composing
		if file_name.begins_with("pp_beard_") and not hair_hex.is_empty():
			_swap_hex(layer, BEARD_SOURCE_HEX, hair_hex)
		if not sash_hex.is_empty() and file_name.begins_with("pp_cloth_"):
			_swap_hex(layer, SASH_SOURCE_HEX, sash_hex)
		canvas.blend_rect(layer, Rect2i(0, 0, CANVAS_W, CANVAS_H),
			Vector2i.ZERO)
	return canvas


## The portrait ladder: the override file always wins; otherwise the
## procedural composition (cached). Returns null only when even `pp_base`
## is missing. `person` carries `id` + `appearance` (+ `role`,
## `nation_id`); every field is guard-read.
static func portrait_texture(person: Dictionary) -> Texture2D:
	var id := str(person.get("id", ""))
	if not id.is_empty():
		if _override_cache.has(id):
			return _override_cache[id] as Texture2D
		var override_path := _override_path(id)
		if FileAccess.file_exists(override_path):
			var override := _load_override_texture(override_path)
			if override != null:
				_override_cache[id] = override
				return override
	if load("%s/pp_base.png" % PART_DIR) == null:
		return null  # no art at all — the flat/initial fallback takes over
	var appearance: Dictionary = person.get("appearance", {}) as Dictionary
	var role := str(person.get("role", ""))
	var owner_nation := str(person.get("nation_id", ""))
	var key := "%s|%s|%s|%s|%s|%s" % [
		str(appearance.get("face", DEFAULT_APPEARANCE["face"])),
		str(appearance.get("beard", DEFAULT_APPEARANCE["beard"])),
		str(appearance.get("hair", DEFAULT_APPEARANCE["hair"])),
		str(appearance.get("eyes", DEFAULT_APPEARANCE["eyes"])),
		role, owner_nation,
	]
	if _cache.has(key):
		return _cache[key] as Texture2D
	var image := compose_image(appearance, role, owner_nation)
	var texture := ImageTexture.create_from_image(image)
	_cache[key] = texture
	return texture


## Loads one part sheet as an RGBA8 Image (the imports are lossless
## CompressedTexture2D — decompress/convert defensively, never re-encode).
static func _load_layer(path: String) -> Image:
	var tex := load(path) as Texture2D
	if tex == null:
		return null  # absent file — silent skip (headless-safe contract)
	var image := tex.get_image()
	if image == null:
		return null
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


## The override rung's loader: `res://` overrides ride the import pipeline
## (CompressedTexture2D, `.import` sidecars committed); a runtime/test
## override under `user://` has no importer — the raw PNG is read directly
## (the same seam the future `user://portraits/` generation cache will ride,
## decision 10's deferred future work).
static func _load_override_texture(path: String) -> Texture2D:
	if path.begins_with("res://"):
		return load(path) as Texture2D
	var image := Image.load_from_file(path)
	if image == null:
		return null
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(image)


## Re-maps every pixel whose hex equals `source_hex` to `target_hex`
## (alpha preserved). Exact string compare on the 8-bit html form — no
## float drift, deterministic.
static func _swap_hex(image: Image, source_hex: String,
		target_hex: String) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.a == 0.0:
				continue
			if pixel.to_html(false) == source_hex:
				image.set_pixel(x, y, Color(target_hex, pixel.a))


## Test seam: empties the composition + override caches (the suite isolates
## the override fixture from cached results; production never calls it).
static func _clear_cache_for_tests() -> void:
	_cache.clear()
	_override_cache.clear()
