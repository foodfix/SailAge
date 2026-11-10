extends Node
## The empty-state layout guard (IMPLEMENT-Phase12.md — the user-reported
## coverage errors: `inn captains.rows.empty` / `market captains.empty`
## — the conditionally-built empty markers had no rect rows because the
## seeded capture rigs never saw the empty state). Headless scene test:
##
##   godot --headless --path . res://tools/test_layout_empty_states.tscn
##
## Exits 0 when every check passes, 1 otherwise.
## Boots the four facility screens that build empty markers on EMPTY
## dynamic data (zero NPC fleets ⇒ zero sightings), then asserts each
## marker registered as its list's member at the block's row 0.

const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

const SCENES := {
	"market": "res://scenes/port/market_screen.tscn",
	"inn": "res://scenes/port/inn_screen.tscn",
	"palace": "res://scenes/port/palace_screen.tscn",
	"tavern": "res://scenes/port/tavern_screen.tscn",
}
## screen id → the empty marker's id + its owning list.
const MARKERS := {
	"market": {"id": "captains.empty", "list": "captains"},
	"inn": {"id": "captains.rows.empty", "list": "captains"},
	"palace": {"id": "board.rows.empty", "list": "board"},
	"tavern": {"id": "captains_table.empty", "list": "table"},
}

var _failures := 0
var _checks := 0


func _ready() -> void:
	for screen_id: String in SCENES:
		await _probe(screen_id)
	if _failures == 0:
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d of %d checks FAILED" % [_failures, _checks])
		get_tree().quit(1)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures += 1
		print("FAIL  ", description)


func _rig_empty_port() -> void:
	# The user's scenario: a real boot at a port with NO captain
	# sightings — every dynamic section builds its empty marker.
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
	GameState.current_port = "lisbon"
	GameState.port_investments = {}
	GameState.known_ports = ["lisbon"]
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list)
	GameState.market_events = []
	GameState.npc_fleets = []      # EMPTY — no sightings anywhere
	GameState.npc_port_log = []
	GameState.discoveries_found = []
	GameState.discoveries_reported = []
	EconomyLib.reset_overrides()
	var port: Dictionary = DataLoader.get_port("lisbon")
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		"clock_fraction": 0.5, "weather": "fair",
	}


func _probe(screen_id: String) -> void:
	RegistryLib._reset_for_tests()
	_rig_empty_port()
	var scene: PackedScene = load(SCENES[screen_id])
	var screen_root: Control = scene.instantiate()
	add_child(screen_root)
	for i in range(6):
		await get_tree().process_frame
	var marker: Dictionary = MARKERS[screen_id]
	# The registry record: the marker must carry its list membership
	# (the coverage exemption) and sit at the block's row 0.
	var rec: Dictionary = RegistryLib._screens.get(screen_id, {}) \
			.get(marker["id"], {})
	var control = rec.get("control", {}).get_ref() \
			if rec.has("control") else null
	_check(not rec.is_empty() and control != null,
			"%s: the empty marker '%s' is registered live"
					% [screen_id, marker["id"]])
	if control != null:
		_check(String(rec.get("list", "")) == marker["list"],
				"%s: the marker is a '%s' list member (coverage-exempt)"
						% [screen_id, marker["list"]])
		var expected: Rect2 = RegistryLib.list_rect(screen_id,
				marker["list"], 0)
		_check(control.position == expected.position,
				"%s: the marker sits at the block's row 0 (got %s, want %s)"
						% [screen_id, str(control.position),
						str(expected.position)])
	if screen_id == "market":
		# The user-reported goods_scroll pin (2026-11-10): the scroll's
		# disabled horizontal axis floored its minimum at the rows'
		# content width — the studio could not shrink or move it. The
		# viewport is scroll-managed: an edit must STICK.
		var scroll: Control = screen_root.get_node_or_null(
				"TableFrame/Table/GoodsScroll")
		if scroll != null:
			RegistryLib.apply_overrides("market", "goods_scroll",
					{"x": 2, "y": 5, "w": 30, "h": 12})
			await get_tree().process_frame
			await get_tree().process_frame
			var tile := float(RegistryLib.TILE)
			_check(scroll.position == Vector2(2, 5) * tile
					and scroll.size == Vector2(30, 12) * tile,
					"market: a goods_scroll rect edit STICKS (got %s / %s)"
							% [str(scroll.position), str(scroll.size)])
	screen_root.queue_free()
	await get_tree().process_frame

