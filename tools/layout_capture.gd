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
	if _rig_scene_path(screen_id).is_empty():
		push_error("layout_capture: no rig for '%s' yet (its W2 wave "
				+ "adds one)" % screen_id)
		return false
	_rig_boot(screen_id)
	var scene: PackedScene = load(_rig_scene_path(screen_id))
	var screen_root: Control = scene.instantiate()
	add_child(screen_root)
	_rig_post(screen_id, screen_root)
	for i in range(SETTLE_FRAMES):
		await get_tree().process_frame
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


# --- rig: world family (W2-C) -------------------------------------------------
#
# The W2-C rigs (docs/IMPLEMENT-Phase12.md §4): the sailing HUD (`world`),
# the chart, the hail modal, the fleet picker and the autopilot HUD bar.
# Each boots the same game-state fixture its matching suite uses
# (test_sailing / test_chart / test_hail / test_ui_window_sizes /
# test_autopilot), so the captured rects are the screens' real settled look.

## The W2-C rig scenes (the port eight stay in `PORT_SCENES`).
const WORLD_RIG_SCENES := {
	"world": "res://scenes/ui_shared/hud.tscn",
	"chart": "res://scenes/world/chart_screen.tscn",
	"hail": "res://scenes/world/hail_modal.tscn",
	"fleet_picker": "res://scenes/world/fleet_picker.tscn",
	"autopilot_hud": "res://scenes/world/autopilot_hud.tscn",
}

const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const HailOptionsLib := preload("res://scripts/world/hail_options.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const AutopilotLib := preload("res://scripts/world/autopilot.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

## The HUD rig's open-sea tile (test_sailing's `OPEN_CELL`).
const RIG_OPEN_CELL := Vector2i(1400, 640)


## The rig lookup: a W2-C screen, else the port eight, else "" (no rig).
func _rig_scene_path(screen_id: String) -> String:
	if WORLD_RIG_SCENES.has(screen_id):
		return String(WORLD_RIG_SCENES[screen_id])
	if PORT_SCENES.has(screen_id):
		return String(PORT_SCENES[screen_id])
	return ""


## Pre-instantiate fixture boot, dispatched per screen (the port eight
## share `_rig_port`).
func _rig_boot(screen_id: String) -> void:
	match screen_id:
		"world":
			_rig_world_hud()
		"chart":
			_rig_chart()
		"hail":
			_rig_hail()
		"fleet_picker":
			_rig_fleet_picker()
		"autopilot_hud":
			_rig_autopilot()
		_:
			_rig_port()


## Post-instantiate open path (a chart opens itself, the modals open on
## their fixture payload; the port screens need nothing).
func _rig_post(screen_id: String, screen_root: Control) -> void:
	match screen_id:
		"chart":
			screen_root.call("open_chart")
		"hail":
			screen_root.call("setup", _rig_hail_fleet())
		"fleet_picker":
			screen_root.call("open_fleets", _rig_picker_fleets())
		"autopilot_hud":
			screen_root.call("setup")
		_:
			pass


## The HUD rig (test_sailing's `_make_run`): the v9 player block, a full
## caravel with supplies, open-sea position, fair weather, a southerly wind.
func _rig_world_hud() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {
			"seamanship": 10, "navigation": 60, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0,
			"cartography": 0, "rumour": 0,
		},
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 60, "luck": 10},
		"xp": 0, "level": 1, "officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	var ship: Dictionary = FleetLib.new_ship("caravel", 15)
	ship["provisions"] = 100
	ship["water"] = 100
	GameState.fleet = [ship]
	GameState.day = 12
	GameState.gold = 12345
	GameState.morale = 75
	GameState.current_port = null
	GameState.known_ports = ["lisbon"]
	SailingSimLib.last_day_shortfalls = {"provisions": false, "water": false}
	SailingSimLib.last_day_unpaid_wages = false
	SailingSimLib.last_day_wages = 0
	SailingSimLib.last_day_storm = false
	GameState.world = {
		"position": {"x": RIG_OPEN_CELL.x, "y": RIG_OPEN_CELL.y},
		"clock_fraction": 0.0,
		"weather": "fair",
		"wind_dir": "S",
	}


## The chart rig (test_chart's fixture): the real world map, a fresh
## portugal run, the S19 debug row ON (the seam `debug_row_override`) so
## the side-legend rows are built and captured with the screen.
func _rig_chart() -> void:
	var map = MapLoaderLib.new()
	if not map.load_map("res://data/maps/world.png", DataLoader.map_legend):
		push_error("layout_capture: the chart rig's map failed to load (%s)"
				% map.last_error)
	DataLoader.map = map
	GameState.new_game("portugal", false)
	ChartViewLib.debug_row_override = 1


## The hail rig (test_hail's `_reset_world` + a warm stance-2 trader): a
## sloop fleet at the NPC's tile, day 100, the canon tier-1 trader captain.
func _rig_hail() -> void:
	var captain := _rig_first_captain("trader", 1)
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {},
		"alloc_pending": 0,
		"xp": 0, "level": 1, "officers": [],
		"reputation": {},
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	var st: Dictionary = DataLoader.get_ship_type("sloop")
	GameState.fleet = [{
		"ship_type_id": "sloop",
		"durability": int(st.get("durability", 0)),
		"crew": 20, "provisions": 50, "water": 50, "cargo": {},
	}]
	GameState.gold = 10000
	GameState.day = 100
	GameState.world = {"position": {"x": 100, "y": 100}}
	GameState.known_ports = ["lisbon", "seville"]
	GameState.captain_states = {}
	GameState.officer_states = {}
	GameState.fame = 0
	HailOptionsLib.reset_session()
	CaptainsLib.ensure(captain)["stance"] = 2


## The hail rig's hailed fleet (a warm tier-1 trader, test_hail's shape).
func _rig_hail_fleet() -> Dictionary:
	var captain := _rig_first_captain("trader", 1)
	return {
		"id": "nf_cap_a",
		"role": "trader",
		"nation_id": "portugal",
		"cell": {"x": 100, "y": 100},
		"route": {"lanes": ["lane_a"], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {"wine": 30},
		"captain_id": captain,
		"dest_port_id": "seville",
		"cooldown_until_day": 0,
		"seed": 0,
		"dwell_until_day": 0,
		"anchor_cell": null,
	}


## The fleet-picker rig (test_ui_window_sizes' fixture): two identified
## fleets on the tile (a trader + a pirate — the multi-row pick list).
func _rig_fleet_picker() -> void:
	var captain := _rig_first_captain("trader", 1)
	GameState.new_game("portugal", false)
	GameState.current_port = "lisbon"
	GameState.gold = 20000
	var pirate := _rig_first_captain("pirate", 1)
	_rig_picker_payload = [
		_rig_pick_fleet("nf_cap_a", "trader", captain),
		_rig_pick_fleet("nf_cap_b", "pirate", pirate),
	]


## One picker payload fleet (test_ui_window_sizes' `_npc_fleet` shape).
func _rig_pick_fleet(id: String, role: String, captain: String) -> Dictionary:
	return {
		"id": id,
		"role": role,
		"nation_id": "",
		"cell": {"x": 100, "y": 100},
		"route": {"lanes": ["lane_a"], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {"wine": 30},
		"captain_id": captain,
		"dest_port_id": "seville",
		"cooldown_until_day": 0,
		"seed": 0,
		"dwell_until_day": 0,
		"anchor_cell": null,
		"convoy_count": 1,
		"on_berth": false,
	}


## The payload carrier between `_rig_fleet_picker` and `_rig_post` (the
## picker's `open_fleets` runs after instantiation).
var _rig_picker_payload: Array = []


func _rig_picker_fleets() -> Array:
	return _rig_picker_payload


## The autopilot-HUD rig (test_autopilot's fixture): the map + ocean
## decode, a fresh run, a hired navigation-40 pilot at sea, then the
## appointed voyage lisbon→seville so the bar renders its destination line.
func _rig_autopilot() -> void:
	var map = MapLoaderLib.new()
	if not map.load_map("res://data/maps/world.png", DataLoader.map_legend):
		push_error("layout_capture: the autopilot rig's map failed (%s)"
				% map.last_error)
	DataLoader.map = map
	var ocean = OceanLayersLib.instance()
	if not ocean.decode_ok:
		push_error("layout_capture: the autopilot rig's ocean decode failed")
	GameState.new_game("portugal", false)
	var pilot := "off_ap_capture_pilot"
	var card := {
		"id": pilot, "role": "", "main_skill": "navigation",
		"wage_daily": 20, "recruit_ports": ["lisbon"],
		"personality": ["honest"],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 10},
		"skills": {"seamanship": 12, "navigation": 40, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·领航员", "en": "Capture Pilot"},
		"bio": {"zh": "测试", "en": "Fixture"},
	}
	DataLoader.officers[pilot] = card
	DataLoader.officers_list.append(card)
	GameState.player["officers"] = [pilot]
	GameState.officer_states[pilot] = {"loyalty": 50, "sea_days": 0,
		"post_id": "pilot", "ship_id": "", "talk_cd_day": 0,
		"gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0}
	GameState.current_port = null
	var berth: Vector2i = DataLoader.map.port_cell("lisbon")
	if berth.x >= 0:
		GameState.set_world_tile(berth)
	AutopilotLib.appoint("seville")


## The first canon captain id of `role`/`tier` (the suites' lookup).
func _rig_first_captain(role: String, tier: int) -> String:
	for card in CaptainsLib.canon_list():
		if str((card as Dictionary).get("role", "")) == role \
				and int((card as Dictionary).get("tier", 0)) == tier:
			return str((card as Dictionary).get("id", ""))
	return ""
# --- end rig: world family (W2-C) ---------------------------------------------


## The v2 fragment for one captured screen: parent-relative element
## rects + list blocks derived from the list-member registrations.
func _dump_fragment(screen_id: String) -> Dictionary:
	var rows: Array = RegistryLib.capture_rows(screen_id)
	if rows.is_empty():
		push_error("layout_capture: %s has no registered rows — run it "
				+ "after the id pass" % screen_id)
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
