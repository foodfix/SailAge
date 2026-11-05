class_name TextureRegistry
extends RefCounted
## The Phase-10 texture registry bootstrap (IMPLEMENT-Phase10.md W4-D,
## deliverable 1; docs/80-UI-UX.md §4.9 "Icon params").
##
## ONE static pass at startup — called from `title_screen._ready()` right
## after the theme application point (§4.9; S1 is the locked main scene) —
## scans the fixed `assets/ui/` class dirs in a deterministic order and
## registers every found PNG under its file-stem id into the `UiKit`
## registry (`UiKit.register_textures`, one call). Consumers keep resolving
## ids through `UiKit.icon_texture(id)`; an absent id ⇒ null (the flat
## fallback, §4.9).
##
## Headless-safe by contract: a missing dir (e.g. `assets/ui/markers/` and
## `assets/ui/overrides/` do not exist until their class lands) is skipped
## silently, and a `load()` that returns null is skipped silently — the
## registry simply carries fewer ids. The `.import` sidecars are committed
## (the W3 master `--import` pass), so the textures import as
## CompressedTexture2D everywhere the repo is checked out — EXCEPT the
## token family: `assets/ui/tokens/` joined the raw-bytes data-artifact
## family (2026-11-05, 90-* §9.2 amendment 10acf123 — the `world.png`
## pattern): the eager pass skips it, and token ids resolve LAZILY through
## `_load_token_texture` — raw `FileAccess` bytes + `Image.load_png_from_buffer`
## + `ImageTexture.create_from_image`, no `.import` sidecar needed, so a
## studio-accepted token reaches the game by file replace + restart (no
## import refresh). Lazy loads join the ONE id cache (`UiKit._textures`)
## with the same fallback chain: a missing id resolves null exactly as
## before (the white-square/flat fallback is the consumers' unchanged rule).
##
## Idempotent: the static guard makes the second call a no-op. Deterministic:
## the dir list is a fixed table, and each dir walk is sorted, so the map is
## byte-stable across runs (late ids never overwrite earlier ones — every id
## is unique per class by construction).

const UiKitLib := preload("res://scripts/ui_kit.gd")

## The fixed scan table (dir → comment); stem ids everywhere. `markers/` and
## `shore/` are in the contract but may not exist in a given tree — the walk
## skips absent dirs silently (W4-C consumes the marker ids once they land;
## the shore strips currently build into `terrain/`, whose stem ids cover
## `shore_{dir}` already).
const SCAN_DIRS: Array[String] = [
	"res://assets/ui/icons",
	"res://assets/ui/tokens",
	"res://assets/ui/markers",
	"res://assets/ui/terrain",
	"res://assets/ui/shore",
	"res://assets/ui/fx",
	"res://assets/ui/portraits",
	"res://assets/ui/overrides",
]

## The raw-bytes family's one dir (90-* §9.2): scanned LAZILY, never through
## the import pipeline. Production points at the committed asset dir; the
## suite re-points it at a `user://` fixture dir to prove the raw-byte load
## (and the file-replace→new-art swap) without touching `assets/` — the
## same seam shape as `PortraitComposer._override_dir`.
const TOKENS_DIR := "res://assets/ui/tokens"
static var _token_dir := TOKENS_DIR

static var _registered := false
## Ids registered by the last successful pass (the suite/report read seam).
## Tokens are not in this count — they resolve lazily on first render.
static var registered_count := 0


## The one-time bootstrap. Safe to call repeatedly and from anywhere
## (the second call is a no-op).
static func ensure_registered() -> void:
	if _registered:
		return
	_registered = true
	UiKitLib.register_token_loader(_load_token_texture)
	var map: Dictionary = {}
	for dir_path in SCAN_DIRS:
		if dir_path == TOKENS_DIR:
			continue  # the raw-bytes family — lazy loads only (§9.2)
		map.merge(_scan_dir(dir_path), true)
	UiKitLib.register_textures(map)
	registered_count = map.size()


## One lazy token load (the `UiKit` miss resolver, installed once by
## [method ensure_registered]): `icon_texture("hull_<ship>_<owner>_<dir>")`
## lands here when the id misses the map — read `res://assets/ui/tokens/<id>.png`
## RAW bytes, decode with `Image.load_png_from_buffer`, wrap in an
## `ImageTexture`. Never `load()`: no `.import` sidecar is consulted or
## needed, so the decoded pixels are always the file's current bytes (the
## stale `.godot/imported` cache cannot leak in). Missing or undecodable
## id ⇒ null — the consumer's fallback chain is unchanged.
static func _load_token_texture(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var path := "%s/%s.png" % [_token_dir, id]
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	return ImageTexture.create_from_image(image)


## One sorted dir walk → `{stem: Texture2D}`. Missing dir or a null
## `load()` ⇒ the id stays out of the map (silent, headless-safe).
static func _scan_dir(dir_path: String) -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out  # absent dir — silent skip
	var names: Array[String] = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		# PNGs only; the `.import` sidecars and any dot-files are not ids.
		if not dir.current_is_dir() and name.ends_with(".png") \
				and not name.begins_with("."):
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for file_name in names:
		var tex := load("%s/%s" % [dir_path, file_name]) as Texture2D
		if tex == null:
			continue  # a texture that fails to load — silent skip
		out[file_name.get_basename()] = tex
	return out


## Test seam: forget the one-time guard and (optionally) the UiKit map is
## left to the caller (`UiKit.clear_textures`). Suites use this to prove
## idempotence and re-seed behavior; production never calls it.
static func _reset_for_tests() -> void:
	_registered = false
	registered_count = 0