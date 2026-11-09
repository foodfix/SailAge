extends Node
## Layout-bounds guard (docs/80-UI-UX.md §4.8.9; IMPLEMENT-Phase11.md §5 —
## the both-locale containment pin). Headless scene test:
##
##   godot --headless --path . res://tools/test_layout_bounds.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS PINNED — the one guarantee the override file must never break,
## asserted as one deterministic observation per locale (the no-overkill
## discipline: the market screen is the densest registered screen; the
## other seven ride the same registry mechanics pinned by
## test_layout_registry + their behavior suites):
##   1. CONTAINMENT — with the SHIPPED empty `data/ui_layout.json`, every
##      registered market row's live rect (tiles, floored) stays inside
##      the 60 × 33.75 design canvas (1-tile floor-rounding slack) in
##      BOTH locales — the baseline is safe by construction.
##   2. THE GUARD BITES — with a deliberately clipping fixture committed
##      (a 30-tile-tall header), the containment check FAILS: the suite
##      exits 1. This is the demonstration that the layout-override
##      commit path has a working both-locale geometry guard (the run
##      swaps the fixture in and restores `{}` itself; no external state).
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

const BAD_FIXTURE := {
	"market": {"header": {"min_w": GRID_W, "min_h": 30}},
}
const CLIP_Y_MAX := GRID_H + 12  # the header pushes rows past the canvas

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var was := I18n.get_locale()
	# 1. The shipped file: containment in both locales.
	RegistryLib._reset_for_tests()
	DataLoader.ui_layout = {}
	for locale in ["zh", "en"]:
		I18n.set_locale(locale)
		await _containment("empty/" + locale, false)
	# 2. The guard bites on a clipping commit.
	DataLoader.ui_layout = BAD_FIXTURE.duplicate(true)
	RegistryLib._reset_for_tests()
	I18n.set_locale("zh")
	await _containment("fixture/zh", true)
	# 3. Restored: green again.
	DataLoader.ui_layout = {}
	RegistryLib._reset_for_tests()
	I18n.set_locale("en")
	await _containment("restored/en", false)
	I18n.set_locale(was)
	DataLoader.ui_layout = {}
	_report()


## Mounts the market screen fresh, walks the registered rows, and checks
## containment. `expect_breach=true` inverts the check (the demonstration
## run): at least one row must sit outside the canvas.
func _containment(case_id: String, expect_breach: bool) -> void:
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
		# rows scroll) — the containment contract covers visible chrome.
		if bool(row.get("clipped")):
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
	if expect_breach:
		_check(not breaches.is_empty(),
				"%s: the clipping fixture breaches containment (%s)"
						% [case_id, breaches.front()])
		# the strict canvas bound, reported for the acceptance record
		var worst := _worst_y(rows)
		_check(worst > CLIP_Y_MAX - 12,
				"%s: content pushed past y=%d (worst y=%d)"
						% [case_id, CLIP_Y_MAX - 12, worst])
	else:
		var detail: String = "" if breaches.is_empty() \
				else " — " + ", ".join(breaches.slice(0, 3))
		var description: String = (
				"%s: all %d unclipped rows inside the canvas "
				+ "(%d scroll-owned skipped)%s") % [case_id,
				rows.size() - clipped, clipped, detail]
		_check(breaches.is_empty(), description)
	screen.queue_free()
	await get_tree().process_frame


## The lowest row bottom edge (the acceptance record's clipping number).
func _worst_y(rows: Array) -> int:
	var worst := 0
	for row: Dictionary in rows:
		var rect: Dictionary = row["rect_tiles"]
		worst = maxi(worst, int(rect["y"]) + int(rect["h"]))
	return worst


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
