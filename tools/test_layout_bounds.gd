extends Node
## Layout-bounds guard (docs/80-UI-UX.md §4.8.9; IMPLEMENT-Phase12.md §5 —
## the both-locale containment pin). Headless scene test:
##
##   godot --headless --path . res://tools/test_layout_bounds.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS PINNED — the one guarantee the layout file must never break,
## asserted as one deterministic observation per locale (the no-overkill
## discipline: the market screen is the densest registered screen; the
## other screens ride the same registry mechanics pinned by
## test_layout_registry + their behavior suites):
##   1. CONTAINMENT — with the SHIPPED `data/ui_layout.json`, every
##      registered market row's live rect (tiles, floored) stays inside
##      the 60 × 33.75 design canvas (1-tile floor-rounding slack) in
##      BOTH locales. Green both in the interim ({}, the flow-authored
##      path) and once W2 lands the market's v2 table (the file is the
##      pin).
##   2. THE GUARD IS STRUCTURAL — with a deliberately out-of-canvas v2
##      row committed (a background at y=40), the applied rect is
##      CLAMPED back inside the canvas (the parent-bounds rule): a bad
##      commit can no longer breach containment at runtime, so the
##      containment check STAYS GREEN — the clamp itself is asserted.
##   3. THE LOOP CLOSES — with `{}` restored, containment is green again
##      in both locales.

const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const MarketScene := preload("res://scenes/port/market_screen.tscn")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## The 1920×1080 design canvas in chrome tiles (80-* §4.8.9 grid caps).
const GRID_W := 60
const GRID_H := 33
## The floor-rounding slack (rect_tiles floors live px).
const SLACK := 1

## The escape fixture (v2 shape): a background row that tries to sit
## 40 tiles down — outside the canvas. Rule 1 clamps it back.
const ESCAPE_FIXTURE := {
	"market": {"elements": {"background":
			{"x": 0, "y": 40, "w": 60, "h": 34}}},
}

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var was := I18n.get_locale()
	# 1. The shipped file: containment in both locales (the file is the
	# pin — this leg stays green through the W2 merges).
	RegistryLib._reset_for_tests()
	DataLoader.ui_layout = _shipped_table()
	for locale in ["zh", "en"]:
		I18n.set_locale(locale)
		await _containment("shipped/" + locale, false)
	# 2. The guard is structural: an out-of-canvas row clamps back.
	# (A rig-level demonstration — injecting a partial table into the
	# real market would make it a MISmanaged screen mid-conversion; the
	# real-table version of this leg lands with W2-A's converted
	# market.)
	RegistryLib._reset_for_tests()
	DataLoader.ui_layout = ESCAPE_FIXTURE.duplicate(true)
	await _clamp_observation()
	# 3. Restored: green again.
	DataLoader.ui_layout = {}
	RegistryLib._reset_for_tests()
	I18n.set_locale("en")
	await _containment("restored/en", false)
	I18n.set_locale(was)
	DataLoader.ui_layout = {}
	_report()


## The shipped file's per-screen table (the suite reads the real file —
## the same bytes the game loads; `{}` interim).
func _shipped_table() -> Dictionary:
	var f := FileAccess.open("res://data/ui_layout.json", FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and parsed.get("screens", null) is Dictionary:
		return parsed["screens"]
	return {}


## Rule 1's canvas-level demonstration: a background element whose data
## row tries to sit 40 tiles down lands clamped to the canvas — an
## out-of-canvas applied rect is structurally impossible.
func _clamp_observation() -> void:
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	add_child(root)
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("market", panel, "background", {"role": "panel"})
	RegistryLib.screen_active("market", root)
	var rect: Dictionary = {}
	for r: Dictionary in RegistryLib.tree("market"):
		if r["id"] == "background":
			rect = r["rect_tiles"]
	_check(rect.get("y", 99) <= GRID_H + 1 and rect.get("h", 0) <= GRID_H + 1,
			"escape: the out-of-canvas row lands clamped inside the "
			+ "canvas (got %s)" % JSON.stringify(rect))
	_check(rect.get("x", -1) == 0 and rect.get("y", -1) == 0
			and rect.get("w", 0) == GRID_W and rect.get("h", 0) == GRID_H + 1,
			"escape: the clamped rect is exactly the canvas "
			+ "(0,0,60,34 — 1088 px fills the 1080 px sliver)")
	root.queue_free()
	await get_tree().process_frame


## Mounts the market screen fresh, walks the registered rows, and checks
## containment. (The Phase-11 `expect_breach` demonstration is retired:
## rule 1 makes an out-of-canvas applied rect structurally impossible —
## leg 2 pins the clamp instead.)
func _containment(case_id: String, _expect_breach: bool) -> void:
	_make_run("lisbon")
	var screen: Control = MarketScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	var rows: Array = RegistryLib.tree("market")
	var breaches: Array[String] = []
	var clipped := 0
	for row: Dictionary in rows:
		# Scroll-owned rows may legitimately exceed the canvas (the market
		# rows scroll) — and list members are data-driven content placed
		# by their list block (the captains strip's rows sit right of the
		# strip's origin by design). The containment contract covers the
		# visible chrome: skip both.
		if bool(row.get("clipped")) or not String(row.get("list", "")).is_empty():
			clipped += 1
			continue
		var rect: Dictionary = row["rect_tiles"]
		var x: int = rect["x"]
		var y: int = rect["y"]
		var w: int = rect["w"]
		var h: int = rect["h"]
		if x < -SLACK or y < -SLACK or x + w > GRID_W + SLACK \
				or y + h > GRID_H + 1 + SLACK:
			breaches.append("%s @(x%d y%d w%d h%d)" % [row["id"], x, y, w, h])
	var detail: String = "" if breaches.is_empty() \
			else " — " + ", ".join(breaches.slice(0, 3))
	var description: String = (
			"%s: all %d unclipped rows inside the canvas "
			+ "(%d scroll-owned skipped)%s") % [case_id,
			rows.size() - clipped, clipped, detail]
	_check(breaches.is_empty(), description)
	screen.queue_free()
	await get_tree().process_frame


func _make_run(port_id: String) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [], "reputation": {},
	}
	for nation in ["portugal", "spain", "england", "holland", "ottoman",
			"italy"]:
		GameState.player["reputation"][nation] = 0
	GameState.fleet = [FleetLib.new_ship("caravel", 0)]
	GameState.day = 1
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = port_id
	GameState.port_investments = {}
	GameState.known_ports = [port_id]
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list)
	GameState.market_events = []
	GameState.npc_fleets = []
	GameState.npc_port_log = []
	EconomyLib.reset_overrides()
	var port: Dictionary = DataLoader.get_port(port_id)
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		"clock_fraction": 0.5,
		"weather": "fair",
	}


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
	else:
		for failure in _failures:
			print("FAILED: ", failure)
		print("%d of %d checks FAILED" % [_failures.size(), _checks])
		get_tree().quit(1)
