extends Node
## Layout capture (docs/IMPLEMENT-Phase12.md W1; docs/80-* §4.8.9; the
## generalized `nest_audit`): boots one screen with its suite rig, waits
## out the layout, and emits the screen's v2 layout fragment — every
## registered element's settled rect in PARENT-RELATIVE tiles plus the
## list blocks (base/row_h derived from consecutive row origins,
## viewport from the nearest ScrollContainer ancestor).
##
##   godot --headless --path . res://tools/layout_capture.tscn -- --screen=market
##   godot --headless --path . res://tools/layout_capture.tscn -- --all
##
## Output: `data/layout_fragments/<screen>.json` —
## `{"elements": {id: {x, y, w, h}}, "lists": {id: {base, row_h,
## viewport}}}` — canonical bytes (sorted keys, 2-space indent,
## trailing newline). The master assembles fragments into the single
## `data/ui_layout.json` at each merge gate (docs/IMPLEMENT-Phase12.md
## §4). Determinism (W4.7): fixed rigs, settled-frame waits, sorted
## output — a double capture must be byte-identical.
##
## The registered-ancestor capture rule makes parent-relative rects
## robust to the W2 container deletion: a rect relative to its
## REGISTERED parent survives the parent's flow plumbing being removed,
## as long as the registered parent's own rect is unchanged.

const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

const TILE := PaletteLib.CHROME_TILE
## Settled-frame wait (nest_audit's proven 6).
const SETTLE_FRAMES := 6

## The W1 rig set: the 8 port screens (the other screens' minimal rigs
## land with their W2 waves; a missing rig is a visible error, never a
## silent skip).
const PORT_SCENES := {
	"port": "res://scenes/port/port_screen.tscn",
	"market": "res://scenes/port/market_screen.tscn",
	"provisions": "res://scenes/port/provisions_dialog.tscn",
	"shipyard": "res://scenes/port/shipyard_screen.tscn",
	"inn": "res://scenes/port/inn_screen.tscn",
	"guild": "res://scenes/port/guild_screen.tscn",
	"palace": "res://scenes/port/palace_screen.tscn",
	"tavern": "res://scenes/port/tavern_screen.tscn",
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var screen := ""
	var all := false
	for arg in args:
		if arg.begins_with("--screen="):
			screen = arg.get_slice("=", 1)
		elif arg == "--all":
			all = true
	if all:
		var ok := true
		for rig_screen in PORT_SCENES:
			if not await _capture_screen(rig_screen):
				ok = false
		# --- rig: title (W2-B) ---
		for rig_screen in W2B_SCENES:
			if not await _capture_screen(rig_screen):
				ok = false
		# --- end rig: title (W2-B) ---
		get_tree().quit(0 if ok else 1)
	elif screen != "":
		var ok := await _capture_screen(screen)
		get_tree().quit(0 if ok else 1)
	else:
		push_error("layout_capture: pass --screen=<id> or --all")
		get_tree().quit(1)


## Boots one screen, waits out the layout, writes its fragment.
func _capture_screen(screen_id: String) -> bool:
	if not (screen_id in RegistryLib.SCREENS):
		push_error("layout_capture: unknown screen '%s'" % screen_id)
		return false
	# --- rig: nationality_select (W2-B) ---
	if not PORT_SCENES.has(screen_id) and not W2B_SCENES.has(screen_id):
	# --- end rig: nationality_select (W2-B) ---
		push_error("layout_capture: no rig for '%s' yet (its W2 wave "
				+ "adds one)" % screen_id)
		return false
	# --- rig: creation (W2-B) ---
	var scene_path: String = PORT_SCENES.get(screen_id, "")
	if W2B_SCENES.has(screen_id):
		scene_path = W2B_SCENES[screen_id]
		_rig_w2b(screen_id)
	else:
		_rig_port()
	var scene: PackedScene = load(scene_path)
	# --- end rig: creation (W2-B) ---
	var screen_root: Control = scene.instantiate()
	add_child(screen_root)
	for i in range(SETTLE_FRAMES):
		await get_tree().process_frame
	# --- rig: creation (W2-B) ---
	await _post_mount_w2b(screen_id, screen_root)
	# --- end rig: creation (W2-B) ---
	var fragment := _dump_fragment(screen_id)
	screen_root.queue_free()
	RegistryLib._reset_for_tests()
	if fragment.is_empty():
		return false
	var dir := "res://data/layout_fragments"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s.json" % [dir, screen_id]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("layout_capture: cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(fragment, "  ", true) + "\n")
	f.close()
	var elements: Dictionary = fragment.get("elements", {})
	var lists: Dictionary = fragment.get("lists", {})
	print("CAPTURED %s — %d elements, %d lists -> %s"
			% [screen_id, elements.size(), lists.size(), path])
	return true


## The port-suite rig (the nest_audit fixture — the shared port
## context: a Lisbon stop, a caravel, seeded stocks, zero NPC fleets).
func _rig_port() -> void:
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
	GameState.npc_fleets = []
	GameState.npc_port_log = []
	EconomyLib.reset_overrides()
	var port: Dictionary = DataLoader.get_port("lisbon")
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		"clock_fraction": 0.5, "weather": "fair",
	}


# --- rig: title (W2-B) ---------------------------------------------------------
# --- rig: nationality_select (W2-B) --------------------------------------------
# --- rig: creation (W2-B) ------------------------------------------------------
## The W2-B rigs: the title trio (docs/IMPLEMENT-Phase12.md §3 W2-B).
## `title` needs no game state (the S1 screen reads only ui_strings + the
## load/save dirs); `nationality_select` / `creation` mount the minimal
## `GameState.player` skeleton the suites use (the test_creation fixture
## shape — the creation preview's duel read brackets its own draft in and
## out, so the skeleton only has to be a Dictionary).
const CreationCaptureLib := preload("res://scenes/title/creation_screen.gd")

const W2B_SCENES := {
	"title": "res://scenes/title/title_screen.tscn",
	"nationality_select": "res://scenes/title/nationality_select.tscn",
	"creation": "res://scenes/title/creation_screen.tscn",
}


## The W2-B fixture dispatch (no-op for `title`).
func _rig_w2b(screen_id: String) -> void:
	match screen_id:
		"nationality_select":
			_rig_w2b_player()
		"creation":
			_rig_w2b_player()
			CreationCaptureLib.pending_nation_id = "portugal"
		_:
			pass  # title — no game state


## The minimal `GameState.player` skeleton (the suites' fixture shape).
func _rig_w2b_player() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [], "reputation": {},
	}
	for nation in ["portugal", "spain", "england", "holland", "ottoman",
			"italy"]:
		GameState.player["reputation"][nation] = 0


## The post-mount drive. The creation rig walks the fresh screen into step
## ② (the free points) so the fragment carries BOTH steps' elements: the
## step-① cards stay registered (hidden) with their rects, the step-② point
## elements build and register on entry.
func _post_mount_w2b(screen_id: String, screen_root: Control) -> void:
	if screen_id != "creation":
		return
	(screen_root as Node).call("confirm_selection")  # step ① → ②
	for i in range(SETTLE_FRAMES):
		await get_tree().process_frame


# --- end rig: W2-B -------------------------------------------------------------


## The v2 fragment for one captured screen: parent-relative element
## rects + list blocks derived from the list-member registrations.
func _dump_fragment(screen_id: String) -> Dictionary:
	var rows: Array = RegistryLib.capture_rows(screen_id)
	if rows.is_empty():
		push_error(("layout_capture: %s has no registered rows — run it "
				+ "after the id pass") % screen_id)
		return {}
	var elements := {}
	var list_members := {}
	for row: Dictionary in rows:
		var list_id := String(row.get("list", ""))
		var pos: Vector2 = row["global_pos"] - row["parent_global"]
		var size: Vector2 = row["size"]
		if list_id.is_empty():
			elements[String(row["id"])] = _tiles(pos, size)
		else:
			if not list_members.has(list_id):
				list_members[list_id] = []
			list_members[list_id].append(row)
	var lists := {}
	for list_id in list_members:
		var members: Array = list_members[list_id]
		members.sort_custom(func(a, b):
			return (a["global_pos"] - a["content_parent_global"]).y \
					< (b["global_pos"] - b["content_parent_global"]).y)
		# base = row 0's rect in the CONTENT-node space; row_h from the
		# second row's origin when present, else the row's own height.
		var first: Dictionary = members[0]
		var first_pos: Vector2 = first["global_pos"] \
				- first["content_parent_global"]
		var base := _tiles(first_pos, first["size"])
		var row_h: int = base["h"]
		if members.size() > 1:
			var second: Dictionary = members[1]
			var second_pos: Vector2 = second["global_pos"] \
					- second["content_parent_global"]
			row_h = maxi(1, roundi((second_pos.y - first_pos.y)
					/ float(TILE)))
		var viewport := {}
		var scroll_size: Vector2 = first.get("scroll_size", Vector2.ZERO)
		if scroll_size > Vector2.ZERO:
			viewport = _tiles(
				first["scroll_global"] - first["scroll_parent_global"],
				scroll_size)
		else:
			viewport = base.duplicate()
		lists[String(list_id)] = {
			"base": base, "row_h": row_h, "viewport": viewport,
		}
	return {"elements": elements, "lists": lists}


## One px rect → one tile rect (nearest tile — the capture of today's
## look; chrome rects are tile-aligned or within half a tile).
func _tiles(pos: Vector2, size: Vector2) -> Dictionary:
	return {
		"x": roundi(pos.x / float(TILE)),
		"y": roundi(pos.y / float(TILE)),
		"w": maxi(1, roundi(size.x / float(TILE))),
		"h": maxi(1, roundi(size.y / float(TILE))),
	}
