extends Node
## Phase-10 W4-D acceptance tests: the portrait composer
## (`scripts/ui/portrait_composer.gd`, IMPLEMENT-Phase10.md decision 10 +
## the W3-D contract in `tools/ui_art/portraits/README.md`/`anchors.json`,
## docs/80-UI-UX.md §4.8 portrait block) and the texture-registry bootstrap
## (`scripts/ui/texture_registry.gd`, W4-D deliverable 1, §4.9 icon params).
##
##   godot --headless res://tools/test_portrait_composer.tscn
##
## **Override-fixture seam (documented per the W4-D prompt):** the ladder's
## override rung reads through `PortraitComposer._override_path(id)`, whose
## directory half is the static `PortraitComposer._override_dir`. This suite
## re-points that static at a temp `user://` dir, writes a tiny 72×96 PNG
## there with `Image.save_png`, and proves the override file wins over the
## composition — without touching the read-only `assets/` tree. `user://`
## PNGs have no import sidecar, so the composer reads them through
## `Image.load_from_file` (the same seam the future `user://portraits/`
## generation cache rides). Everything else asserts pure `compose_image`
## pixel facts, so no RenderingServer round-trip is needed headless.
##
## Exits 0 when every check passes, 1 otherwise.

const PortraitComposerLib := preload("res://scripts/ui/portrait_composer.gd")
const TextureRegistryLib := preload("res://scripts/ui/texture_registry.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const PaletteLib := preload("res://scripts/palette.gd")

## A pinned beard pixel: the anchors put the `full` beard band / mustache at
## (36, 41) — verified `#6b4a2a` on `pp_beard_full.png` (the swap source).
const BEARD_PIXEL := Vector2i(36, 41)
## A pinned sash pixel: the sash diagonal starts at origin (24, 70)
## (anchors.json `sash`), verified `#d9a441` on `pp_cloth_patrol.png` and on
## the trader body sheet.
const SASH_PIXEL := Vector2i(24, 70)

## The id the override fixture impersonates (a canon legend captain).
const OVERRIDE_ID := "cap_leg_trader_05"
const OVERRIDE_DIR := "user://w4d_test_overrides"

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_part_list_contract()
	_test_compose_basics_and_determinism()
	_test_beard_swap_pinned_pixel()
	_test_sash_swap_pinned_pixel()
	_test_full_appearance_domain_resolves()
	await _test_override_wins_ladder()
	_test_portrait_texture_cache()
	_test_texture_registry()
	_report()


# --- Harness ----------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)


func _appearance(face: String, beard: String, hair: String,
		eyes: String) -> Dictionary:
	return {"face": face, "beard": beard, "hair": hair, "eyes": eyes}


func _hex(image: Image, pixel: Vector2i) -> String:
	return image.get_pixel(pixel.x, pixel.y).to_html(false)


func _count_hex(image: Image, hex: String) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.0 \
					and image.get_pixel(x, y).to_html(false) == hex:
				count += 1
	return count


# --- The fixed part list (fixed appearance dict → fixed part list) ----------

func _test_part_list_contract() -> void:
	# The exact layer file sequence in stack order base→face→eyes→beard→hair→
	# cloth (the W3-D composer contract).
	var parts := PortraitComposerLib.part_files(
		_appearance("round", "forked", "grey_streaked", "hazel"), "patrol")
	_check(parts == [
		"pp_base.png",
		"pp_face_round.png",
		"pp_eyes_hazel.png",
		"pp_beard_forked.png",
		"pp_hair_grey_streaked.png",
		"pp_cloth_patrol.png",
	], "the part list is the fixed base→face→eyes→beard→hair→cloth sequence")
	# Guard-read defaults: empty appearance → lean/clean/black/dark; empty
	# role → the trader cloth rung.
	var defaults := PortraitComposerLib.part_files({}, "")
	_check(defaults == [
		"pp_base.png",
		"pp_face_lean.png",
		"pp_eyes_dark.png",
		"pp_beard_clean.png",
		"pp_hair_black.png",
		"pp_cloth_trader.png",
	], "the empty appearance/role guard-reads to lean/clean/black/dark + trader")
	# The player card passes role "player" — the eighth cloth rung.
	var player := PortraitComposerLib.part_files(
		_appearance("lean", "clean", "black", "dark"), "player")
	_check(str(player[player.size() - 1]) == "pp_cloth_player.png",
		"role \"player\" resolves the §4.8 player cloth rung")


# --- Compose basics + determinism --------------------------------------------

func _test_compose_basics_and_determinism() -> void:
	var appearance := _appearance("lean", "full", "brown", "dark")
	var image := PortraitComposerLib.compose_image(appearance, "trader")
	_check(image.get_width() == 72 and image.get_height() == 96,
		"the composed bust is the 72×96 canvas")
	_check(image.get_format() == Image.FORMAT_RGBA8,
		"the composed bust is RGBA8")
	var opaque := 0
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.0:
				opaque += 1
	_check(opaque > 0, "the composed bust is not empty (%d opaque pixels)"
		% opaque)
	# Same input → byte-equal Image data twice (deterministic, instant).
	var again := PortraitComposerLib.compose_image(appearance, "trader")
	_check(again.get_data() == image.get_data(),
		"compose_image is byte-deterministic (same input → equal data)")
	# The clean-beard rung composes too (the sheet ships fully transparent,
	# W3-D adjudication 3 — the layer skip path).
	var clean := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "hunter")
	_check(clean.get_width() == 72, "the clean-beard compose succeeds too")


# --- The beard palette swap (W3-D pin: HAIR_BROWN → the captain's hair hex) --

func _test_beard_swap_pinned_pixel() -> void:
	# Sanity on the source sheet itself: (36, 41) is HAIR_BROWN on
	# pp_beard_full.png — the pin the swap assertions hang on. The PNG
	# source is committed, so a direct file read works without the import
	# pipeline.
	var sheet := Image.load_from_file(
		"res://assets/ui/portraits/pp_beard_full.png")
	_check(sheet != null and sheet.get_pixel(BEARD_PIXEL.x, BEARD_PIXEL.y)
		.to_html(false) == "6b4a2a",
		"pp_beard_full renders the #6b4a2a swap source at (36, 41)")
	# black hair → the beard pixels re-map to HAIR_BLACK.
	var black := PortraitComposerLib.compose_image(
		_appearance("lean", "full", "black", "dark"), "trader")
	_check(_hex(black, BEARD_PIXEL) == "1a1a1e",
		"hair black: the pinned beard pixel reads the HAIR_BLACK hex")
	_check(_count_hex(black, "6b4a2a") == 0,
		"hair black: no swap-source pixels remain (the beard fully re-maps)")
	# brown hair → the beard stays the neutral default (source == target).
	var brown := PortraitComposerLib.compose_image(
		_appearance("lean", "full", "brown", "dark"), "trader")
	_check(_hex(brown, BEARD_PIXEL) == "6b4a2a",
		"hair brown: the pinned beard pixel stays HAIR_BROWN")
	# grey_streaked / sun_bleached hit their own block hexes.
	var grey := PortraitComposerLib.compose_image(
		_appearance("lean", "full", "grey_streaked", "grey"), "coaster")
	_check(_hex(grey, BEARD_PIXEL) == "b9bcc0",
		"hair grey_streaked: the beard reads HAIR_GREY")
	var bleached := PortraitComposerLib.compose_image(
		_appearance("lean", "full", "sun_bleached", "pale_blue"), "courier")
	_check(_hex(bleached, BEARD_PIXEL) == "d9b98a",
		"hair sun_bleached: the beard reads HAIR_BLEACHED")


# --- The sash re-tint (W3-D pin: CLOTH_ACCENT cells → the owner's cloth) -----

func _test_sash_swap_pinned_pixel() -> void:
	# Empty owner (the default) keeps the ACCENT sash.
	var neutral := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "patrol")
	_check(_hex(neutral, SASH_PIXEL) == "d9a441",
		"patrol without an owner keeps the #d9a441 ACCENT sash")
	# Known owners re-tint to their §4.8 CLOTH_{nation} hex.
	var spain := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "patrol", "spain")
	_check(_hex(spain, SASH_PIXEL) == PaletteLib.CLOTH_SPAIN.to_html(false),
		"patrol owned by spain re-tints the sash to CLOTH_SPAIN")
	var ottoman := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "privateer", "ottoman")
	_check(_hex(ottoman, SASH_PIXEL) == PaletteLib.CLOTH_OTTOMAN.to_html(false),
		"privateer owned by ottoman re-tints the sash to CLOTH_OTTOMAN")
	var england := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "privateer", "england")
	_check(_hex(england, SASH_PIXEL) == PaletteLib.CLOTH_ENGLAND.to_html(false),
		"privateer owned by england re-tints the sash to CLOTH_ENGLAND")
	# An unknown owner (player/neutral/anything) keeps the ACCENT sash.
	var unknown := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "patrol", "player")
	_check(_hex(unknown, SASH_PIXEL) == "d9a441",
		"an unknown owner keeps the ACCENT sash (no invented hex)")
	# The swap is sash-only: the trader BODY is accent and never re-tints,
	# and the player cloth rung is untouched.
	var trader := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "trader", "spain")
	_check(_hex(trader, SASH_PIXEL) == "d9a441",
		"the trader accent body is not a sash — no re-tint with an owner")
	var player := PortraitComposerLib.compose_image(
		_appearance("lean", "clean", "black", "dark"), "player", "spain")
	_check(_hex(player, SASH_PIXEL) == "e8e6df",
		"the player cloth rung reads CLOTH_PLAYER at the pinned pixel")


# --- Every distinct appearance value in captains.json resolves (4×4×4×4) ----

func _test_full_appearance_domain_resolves() -> void:
	var faces := {}
	var beards := {}
	var hairs := {}
	var eyes := {}
	for captain in DataLoader.captains_list:
		var appearance: Dictionary = captain.get("appearance", {})
		faces[str(appearance.get("face", ""))] = true
		beards[str(appearance.get("beard", ""))] = true
		hairs[str(appearance.get("hair", ""))] = true
		eyes[str(appearance.get("eyes", ""))] = true
	_check(faces.size() == 4 and beards.size() == 4 and hairs.size() == 4
		and eyes.size() == 4,
		"captains.json carries exactly 4 distinct values per appearance axis "
		+ "(got %d/%d/%d/%d)" % [faces.size(), beards.size(), hairs.size(),
		eyes.size()])
	var resolved := true
	for face in faces:
		for beard in beards:
			for hair in hairs:
				for eye in eyes:
					var image := PortraitComposerLib.compose_image(
						_appearance(face, beard, hair, eye), "trader")
					if image.get_width() != 72 or image.get_height() != 96:
						resolved = false
	_check(resolved, "every 4×4×4×4 appearance combination composes 72×96")
	# And one canon captain end-to-end through the ladder.
	var canon: Dictionary = DataLoader.captains_list[0]
	var texture := PortraitComposerLib.portrait_texture({
		"id": str(canon.get("id", "")),
		"appearance": canon.get("appearance", {}),
		"role": str(canon.get("role", "")),
		"nation_id": str(canon.get("nation_id", "")),
	})
	_check(texture != null and texture.get_width() == 72
		and texture.get_height() == 96,
		"the ladder composes a canon captain to a 72×96 texture")


# --- The override-wins rung (fixture via the _override_dir seam) --------------

func _test_override_wins_ladder() -> void:
	# Build a tiny override PNG (one flat color, alpha on) in a temp user://
	# dir — the documented seam keeps assets/ read-only.
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("w4d_test_overrides"):
		dir.make_dir("w4d_test_overrides")
	var image := Image.create(72, 96, false, Image.FORMAT_RGBA8)
	image.fill(Color("1a2b3c"))
	var fixture_path := "%s/portrait_%s.png" % [OVERRIDE_DIR, OVERRIDE_ID]
	var saved := image.save_png(fixture_path)
	_check(saved == OK, "the override fixture PNG writes to user://")
	# Point the ladder's first rung at the fixture dir.
	var production_dir: String = PortraitComposerLib._override_dir
	PortraitComposerLib._override_dir = OVERRIDE_DIR
	var person := {
		"id": OVERRIDE_ID,
		"appearance": _appearance("lean", "full", "black", "dark"),
		"role": "trader",
		"nation_id": "england",
	}
	var override := PortraitComposerLib.portrait_texture(person)
	_check(override != null, "the override file loads as a texture")
	_check(override != null and override.get_width() == 72
		and override.get_height() == 96,
		"the override texture carries the fixture's canvas")
	# The override rung is cached by id: the repeat call returns the SAME
	# texture instance (no second load).
	var cached_override := PortraitComposerLib.portrait_texture(person)
	_check(cached_override == override,
		"the override result is cached by id (same instance on repeat)")
	# A person WITHOUT an override file falls through to the composition.
	PortraitComposerLib._clear_cache_for_tests()
	var composed := PortraitComposerLib.portrait_texture({
		"id": "cap_trader_0001",
		"appearance": _appearance("lean", "full", "black", "dark"),
		"role": "trader",
		"nation_id": "england",
	})
	_check(composed != null and composed != override,
		"a person without an override composes procedurally instead")
	# Restore the production rung and the cache.
	PortraitComposerLib._override_dir = production_dir
	PortraitComposerLib._clear_cache_for_tests()
	_check(PortraitComposerLib._override_path(OVERRIDE_ID)
		== "res://assets/ui/overrides/portrait_%s.png" % OVERRIDE_ID,
		"the production override rung points back at assets/ui/overrides")
	# An override dir with no file for the id never blocks the ladder
	# (the rung is skipped silently — headless-safe contract).
	_check(FileAccess.file_exists(PortraitComposerLib._override_path(
		OVERRIDE_ID)) == false,
		"the production tree ships no override file (compose path rules)")


# --- The composition cache ----------------------------------------------------

func _test_portrait_texture_cache() -> void:
	PortraitComposerLib._clear_cache_for_tests()
	var person := {
		"id": "",
		"appearance": _appearance("round", "stubble", "brown", "hazel"),
		"role": "hunter",
		"nation_id": "",
	}
	var first := PortraitComposerLib.portrait_texture(person)
	var second := PortraitComposerLib.portrait_texture(person)
	_check(first != null and first == second,
		"the same (appearance, role, owner) key returns the cached texture")
	# The player card passes role "player" — a distinct cache entry that
	# resolves too (the §4.8 player cloth rung).
	var player := PortraitComposerLib.portrait_texture({
		"id": "", "appearance": {}, "role": "player", "nation_id": "",
	})
	_check(player != null,
		"the default player person (no appearance) composes the player bust")
	PortraitComposerLib._clear_cache_for_tests()


# --- The texture registry bootstrap (W4-D deliverable 1) ----------------------

func _test_texture_registry() -> void:
	UiKitLib.clear_textures()
	TextureRegistryLib._reset_for_tests()
	TextureRegistryLib.ensure_registered()
	var count := TextureRegistryLib.registered_count
	# 10acf123 (2026-11-05): hull tokens joined the raw-bytes lazy family —
	# they resolve on first render, NOT through the eager registration, so
	# the eager count is icons+markers+terrain+fx+portraits (~200), not the
	# 1152-token grid. Token coverage is proven by the lazy probes below.
	_check(count > 150,
		"the registry registers the eager generated families (%d ids; " +
		"tokens lazy since 10acf123)" % count)
	# One id per family resolves through the kit.
	var probes := {
		"coin": "icons (stem id)",
		"hull_caravel_player": "tokens (north hull grid)",
		"facility_market": "tokens (facility)",
		"sea_pattern": "terrain (water pattern)",
		"terrain_land_0": "terrain (kind tile)",
		"shore_n": "terrain (shore strip stem id)",
		"fx_splash_0": "fx",
		"pp_base": "portraits (the composer's base rung)",
		"pp_cloth_patrol": "portraits (cloth rung)",
	}
	for id in probes:
		_check(UiKitLib.icon_texture(id) != null,
			"registry resolves %s — %s" % [id, probes[id]])
	# The override family registers when its dir exists; it does not in this
	# tree, and the missing dir is skipped silently (headless-safe contract).
	# markers/ landed with the W3 follow-up (master commit 72d4ffe) — the
	# registry now carries them (master fix, ledgered; the W5-A escalation).
	_check(UiKitLib.icon_texture("marker_wreck") != null,
		"markers/ registered since the W3 follow-up — marker ids resolve")
	_check(UiKitLib.icon_texture("registry_absent_probe") == null,
		"an unregistered id still resolves to null (the flat fallback)")
	# Idempotent: the second call is a no-op; the deterministic sorted walks
	# keep the map byte-stable.
	TextureRegistryLib.ensure_registered()
	_check(TextureRegistryLib.registered_count == count,
		"ensure_registered is idempotent (the guard makes call 2 a no-op)")
	var walk_a: Dictionary = TextureRegistryLib._scan_dir(
		"res://assets/ui/portraits")
	var walk_b: Dictionary = TextureRegistryLib._scan_dir(
		"res://assets/ui/portraits")
	var keys_a := walk_a.keys()
	var keys_b := walk_b.keys()
	_check(keys_a == keys_b and keys_a.size() == 25,
		"the dir walk is sorted + deterministic (25 portrait stems, stable)")
	_check(TextureRegistryLib._scan_dir("res://assets/ui/absent_dir") == {},
		"a missing dir scans to an empty map (no crash)")
	UiKitLib.clear_textures()
	TextureRegistryLib._reset_for_tests()
