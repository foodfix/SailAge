extends Node
## Sweep-guard audit (docs/80-UI-UX.md §4.9 "No-per-screen-styling rule +
## allowlist"; docs/IMPLEMENT-Phase10.md §5 "Sweep guard" and the W6 grep
## bounds). Headless scene test:
##
##   godot --headless --path . res://tools/test_ui_styling_audit.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS GATED — exactly the §5 spec's THREE tokens, scanned TEXTUALLY
## (grep parity with the §5 line and the W6 acceptance grep; a token inside
## a comment is still a hit, so scanned files must not even mention them):
##   * `*.gd` under `scenes/`, `scripts/`, `autoload/` (recursive):
##       `add_theme_stylebox_override`, `StyleBoxFlat`, `StyleBoxTexture`
##   * `*.tscn` under the same dirs (the scene-file channels for the same
##     rule): `StyleBox*` sub_resource declarations and
##     `theme_override_styles/*` stylebox properties.
##
## NOT gate tokens (note): `add_theme_color_override`,
## `add_theme_font_size_override` and `add_theme_constant_override` retire
## via the W4/W5 sweeps too — the §4.9 rule bans every `add_theme_*` call
## outside the allowed set — but this audit pins exactly the §5 spec's
## three; the other channels ride the sweep discipline, not a gate.
##
## ALLOWED SET: `scripts/ui_theme.gd` + `scripts/ui_kit.gd` (the theme/kit
## pair §4.9 names) ∪ the §4.9 allowlist table — which starts EMPTY and
## gains entries ONLY by master-ledger adjudication. The (empty) allowlist
## lives right next to ALLOWED_FILES below, commented out with its citation;
## an entry lands together with its §4.9 table row (file, reason, expiry)
## and exempts exactly that file here.
##
## STAGED EXPECTATION (W5 runs two slots in parallel): mid-wave runs may
## show the OTHER slot's not-yet-swept files as offenders (W5-A owns
## `battle_screen.gd` / `battle_grid_overlay.gd`). This suite is the guard,
## not the wave gate — at the wave gate the master enforces FULL GREEN
## (zero hits anywhere) after both slots merge.

## Directories walked recursively (§5: scenes/ + scripts/ + autoload/).
const SCAN_DIRS: Array[String] = [
	"res://scenes",
	"res://scripts",
	"res://autoload",
]

## The §4.9 theme/kit pair — styling LIVES here by design (§4.9 rule).
const ALLOWED_FILES: Array[String] = [
	"res://scripts/ui_theme.gd",
	"res://scripts/ui_kit.gd",
]

## The §4.9 allowlist table (docs/80-UI-UX.md §4.9) — starts EMPTY; entries
## are added only by master-ledger adjudication, together with the matching
## row in the doc's table. Uncomment and extend exactly then:
##
##   const ALLOWLIST: Array[String] = [
##       # "res://scenes/<file>.gd",  # <reason>, expires <date>
##   ]

## The three §5 gate tokens for `*.gd` sources.
const GD_TOKENS: Array[String] = [
	"add_theme_stylebox_override",
	"StyleBoxFlat",
	"StyleBoxTexture",
]

## The scene-file shapes of the same rule for `*.tscn` sources: any
## StyleBox* sub_resource declaration, any stylebox theme_override property.
const TSCN_TOKENS: Array[String] = [
	"[sub_resource type=\"StyleBox",
	"theme_override_styles/",
]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var result := _scan()
	_test_walk_integrity(result)
	_test_no_offenders(result)
	_report()


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


# --- The scan -----------------------------------------------------------------

## `{files: Array[String], hits: Array[Dictionary]}` — every scanned file
## path plus one `{path, line, text}` entry per token hit (file:line, the
## §5 report shape).
func _scan() -> Dictionary:
	var files: Array[String] = []
	var hits: Array = []
	for dir_path in SCAN_DIRS:
		_scan_dir(dir_path, files, hits)
	return {"files": files, "hits": hits}


func _scan_dir(dir_path: String, files: Array[String], hits: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var child := dir_path.path_join(entry)
			if dir.current_is_dir():
				_scan_dir(child, files, hits)
			elif entry.ends_with(".gd") or entry.ends_with(".tscn"):
				files.append(child)
				_scan_file(child, hits)
		entry = dir.get_next()
	dir.list_dir_end()


func _scan_file(path: String, hits: Array) -> void:
	var tokens: Array[String] = GD_TOKENS if path.ends_with(".gd") \
		else TSCN_TOKENS
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var line_no := 0
	while not file.eof_reached():
		line_no += 1
		var line := file.get_line()
		for token in tokens:
			if line.contains(token):
				hits.append({
					"path": path,
					"line": line_no,
					"text": line.strip_edges(),
				})


# --- Checks -------------------------------------------------------------------

## Walk integrity: the scan actually reached every root dir and the allowed
## pair (so an empty offenders list can never be a vacuous pass).
func _test_walk_integrity(result: Dictionary) -> void:
	var files: Array[String] = result["files"]
	_check(not files.is_empty(),
		"the scan walked sources under scenes/scripts/autoload (%d files)"
			% files.size())
	for dir_path in SCAN_DIRS:
		var reached := false
		for path in files:
			if path.begins_with(dir_path):
				reached = true
				break
		_check(reached, "the scan reached %s" % dir_path)
	for allowed in ALLOWED_FILES:
		_check(files.has(allowed), "the scan reached the allowed %s"
			% allowed.replace("res://", ""))


## Every hit outside the allowed set is a RED, reported with file:line (§5).
func _test_no_offenders(result: Dictionary) -> void:
	var offenders: Array = []
	for hit in result["hits"]:
		if not ALLOWED_FILES.has(str(hit["path"])):
			offenders.append(hit)
	# (§4.9: an adjudicated ALLOWLIST entry would exempt its file here.)
	for hit in offenders:
		_check(false, "%s:%d carries a gated styling token: %s"
			% [str(hit["path"]), int(hit["line"]), str(hit["text"])])
	_check(offenders.is_empty(),
		"no gated styling token outside {ui_theme.gd, ui_kit.gd} ∪ the "
		+ "§4.9 allowlist (%d hits scanned)" % (result["hits"] as Array).size())
