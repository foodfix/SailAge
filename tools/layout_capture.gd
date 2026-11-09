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
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const CaptainsLib2 := preload("res://scripts/world/captains.gd")

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

# --- W2 rigs (each slot appends between its own markers) ----------------------

# --- rig: confirm (W2-D) ---
const CONFIRM_SCENE := "res://scenes/ui_shared/confirm_dialog.tscn"
# --- rig: dialog_box (W2-D) ---
const DIALOG_BOX_SCENE := "res://scenes/ui_shared/dialog_box.tscn"
# --- rig: save_slot (W2-D) ---
const SAVE_SLOT_SCENE := "res://scenes/ui_shared/save_slot_dialog.tscn"
# --- rig: settings (W2-D) ---
const SETTINGS_SCENE := "res://scenes/ui_shared/settings_panel.tscn"
# --- rig: gameover (W2-D) ---
const GAMEOVER_SCENE := "res://scenes/ui_shared/gameover_screen.tscn"
# --- rig: ending (W2-D) ---
const ENDING_SCENE := "res://scenes/ui_shared/ending_screen.tscn"
# --- rig: duel (W2-D) ---
const DUEL_SCENE := "res://scenes/combat/duel_modal.tscn"
# --- rig: intel_window (W2-D) ---
const INTEL_WINDOW_SCENE := "res://scenes/ui_shared/intel_window.tscn"

## The W2-D shared/combat screens captured so far (extended per commit).
## The lookup falls back here after PORT_SCENES.
const W2D_SCENES := {
	"confirm": CONFIRM_SCENE,
	"dialog_box": DIALOG_BOX_SCENE,
	"save_slot": SAVE_SLOT_SCENE,
	"settings": SETTINGS_SCENE,
	"gameover": GAMEOVER_SCENE,
	"ending": ENDING_SCENE,
	"duel": DUEL_SCENE,
	"intel_window": INTEL_WINDOW_SCENE,
	"reputation_view": "res://scenes/ui_shared/reputation_view.tscn",
	"captain_view": "res://scenes/ui_shared/captain_view.tscn",
	"battle": "res://scenes/combat/battle_screen.tscn",
	"sandbox": "res://scenes/combat/battle_sandbox.tscn",
	"dossier": "res://scenes/ui/dossier_panel.tscn",
	"fleet_view": "res://scenes/ui_shared/fleet_view.tscn",
	"officer_roster": "res://scenes/ui_shared/officer_roster_view.tscn",
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
	if _rig_scene_path(screen_id).is_empty():
		push_error("layout_capture: no rig for '%s' yet (its W2 wave "
				+ "adds one)" % screen_id)
		return false
	_rig_boot(screen_id)
	var scene: PackedScene = load(_rig_scene_path(screen_id))
	var screen_root: Control = scene.instantiate()
	add_child(screen_root)
	# The open path: the W2-C screens open in `_rig_post`; the W2-D
	# modals open (and REGISTER) through their awaited `_open_<id>` hook
	# (the battle rig plays the battle out to its after-action); the W2-A
	# provisions prompt is a hidden modal — its lists and its real look
	# exist only open, so the rig opens it (a no-op for every other
	# screen: the guard is has_method-based).
	await _rig_post(screen_id, screen_root)
	if has_method("_open_%s" % screen_id):
		await call("_open_%s" % screen_id, screen_root)
	if screen_root.has_method("open_on"):
		screen_root.open_on(null)
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
	# Phase 12 W2-A (the list blocks must derive): the caravel carries a
	# trade-good stack so the provisions dialog's cargo jettison list has a
	# member (fleet order, then sorted good ids — the locked order).
	GameState.fleet[0]["cargo"] = {"wine": 20}
	GameState.day = 1
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = "lisbon"
	GameState.port_investments = {}
	GameState.known_ports = ["lisbon"]
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list)
	GameState.market_events = []
	# Phase 12 W2-A (the list blocks must derive): the harbor table loads
	# (`ensure_map`) so the docked-fleet queries resolve Lisbon's berth, then
	# three docked fleets — two traders (market/inn rolls) and one coaster
	# (tavern roll) — plus a hunter at the pier (palace bounty board) and one
	# pirate at sea within the §4.7.8 poster radius (palace inform). Canon
	# captain ids only (`data/captains.json`); the seeded facility/presence
	# rolls are stable for these fixed ids, port and day. One
	# found-but-unreported discovery feeds the guild's report list.
	DataLoader.ensure_map()
	GameState.npc_fleets = [
		_rig_fleet("cap_w2a_trader_2", "cap_trader_0002", "trader",
			"holland", true),
		_rig_fleet("cap_w2a_trader_4", "cap_trader_0003", "trader",
			"england", true),
		_rig_fleet("cap_w2a_coaster_1", "cap_coaster_0001", "coaster",
			"spain", true),
		_rig_fleet("cap_w2a_hunter_1", "cap_hunter_0001", "hunter",
			"portugal", true),
		_rig_fleet("cap_w2a_pirate_1", "pirate_edward_bloodhand", "pirate",
			"", false),
	]
	GameState.npc_port_log = []
	var found := str(DataLoader.discoveries_list[0].get("id", ""))
	GameState.discoveries_found = [found] if not found.is_empty() else []
	GameState.discoveries_reported = []
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


## The rig lookup: a W2-C screen, else a W2-D screen, else a W2-B screen,
## else the port eight, else "" (no rig).
func _rig_scene_path(screen_id: String) -> String:
	if WORLD_RIG_SCENES.has(screen_id):
		return String(WORLD_RIG_SCENES[screen_id])
	if W2D_SCENES.has(screen_id):
		return String(W2D_SCENES[screen_id])
	if W2B_SCENES.has(screen_id):
		return String(W2B_SCENES[screen_id])
	if PORT_SCENES.has(screen_id):
		return String(PORT_SCENES[screen_id])
	return ""


## Pre-instantiate fixture boot, dispatched per screen (the port eight
## share `_rig_port`; the W2-B trio shares `_rig_w2b`; the W2-D rigs
## ride their `_rig_<id>` names).
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
		"title", "nationality_select", "creation":
			_rig_w2b(screen_id)
		_:
			if has_method("_rig_%s" % screen_id):
				call("_rig_%s" % screen_id)
			else:
				_rig_port()


## Post-instantiate open path (a chart opens itself, the W2-C modals
## open on their fixture payload; the port screens need nothing — the
## W2-D modals open through the awaited `_open_<id>` hooks instead).
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



## One minimal NPC fleet for the rig: docked at Lisbon on its berth when
## `docked` (dwell active), at sea three tiles southeast otherwise (the
## wanted-poster family). The shape is the `npc_fleets.gd` fleet dict's
## live-read subset (`position_of`, `docked_fleets`, the seeded rolls).
func _rig_fleet(id: String, captain_id: String, role: String,
		nation_id: String, docked: bool) -> Dictionary:
	var cell := DataLoader.port_cell("lisbon")
	if not docked:
		cell += Vector2i(3, 3)
	return {
		"id": id,
		"role": role,
		"nation_id": nation_id,
		"cell": {"x": cell.x, "y": cell.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain_id": captain_id,
		"cooldown_until_day": 0,
		"seed": 0,
		"dest_port_id": "lisbon" if docked else "",
		"dwell_until_day": GameState.day + 3 if docked else 0,
		"anchor_cell": null,
		"target_fleet_id": "",
		"hunter_state": "",
		"loiter_until_day": 0,
		"home_port_id": "",
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


# --- W2-D rigs (scenes/combat + ui_shared) ------------------------------------

## The modal rigs' shared minimal run (the suites' `new_game`-free shape:
## direct GameState fields, a caravel, no NPCs — enough for any modal that
## reads state, harmless for those that don't).
func _rig_modal_run() -> void:
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
	GameState.current_port = ""
	GameState.npc_fleets = []


# --- rig: confirm (W2-D) -------------------------------------------------------

func _rig_confirm() -> void:
	_rig_modal_run()


## The fixture message (the window-sizes suite's jettison confirm — a
## two-line wrapped body, deterministic via `ui_strings.json`).
func _open_confirm(dialog: Control) -> void:
	dialog.call("open_key", "fleet.jettison.confirm",
		{"ship": "Ship 1", "good": "Wine", "qty": 30})


# --- rig: dialog_box (W2-D) ----------------------------------------------------

func _rig_dialog_box() -> void:
	_rig_modal_run()


## The fixture message (the suite's short line — text-only dialog).
func _open_dialog_box(dialog: Control) -> void:
	dialog.call("open_text", "A short line.")


# --- rig: save_slot (W2-D) -----------------------------------------------------

func _rig_save_slot() -> void:
	_rig_modal_run()
	GameState.day = 12
	GameState.gold = 7830
	# One filled slot + one empty + one corrupt (the §4.6 row states) — the
	# summary rows need entries; the slots list block derives from the live
	# rows.
	DirAccess.make_dir_recursive_absolute(SaveSystem.SLOT_DIR)
	# The v9 Person block carries no `stats` key (docs/50-* §4.8) — the rig
	# player's stat block is stripped so slot 1 reads VALID.
	var player: Dictionary = GameState.player.duplicate(true)
	player.erase("stats")
	var save := {
		"save_version": 9, "saved_at": 1793119712, "phase": 9,
		"locale": "en", "day": 12, "gold": 7830,
		"player": player, "fleet": GameState.fleet,
		"morale": 70,
		"world": {"position": {"x": 0, "y": 0}, "map_id": "world",
			"weather": "calm", "sail_trim": "normal", "heading": "E",
			"wind_dir": "E"},
		"current_port": "lisbon", "known_ports": ["lisbon"],
		"explored_tiles": "", "port_investments": {}, "quests": [],
		"discoveries_found": [], "npc_fleets": [], "officer_states": {},
		"captain_states": {}, "proximity_cooldowns": {},
		"market_stocks": {}, "wrecks": [], "npc_preset": "normal",
		"market_events": [],
		"control_prefs": {"input_mode": "step", "current_mode": "modifier"},
		"permits": {"home": false, "foreign": {}},
		"port_allegiance": {}, "month_invested": {},
		"nation_treasuries": {}, "fame_commended": {},
	}
	var f := FileAccess.open(SaveSystem.slot_path(1), FileAccess.WRITE)
	f.store_string(JSON.stringify(save))
	f.close()
	f = FileAccess.open(SaveSystem.slot_path(2), FileAccess.WRITE)
	f.store_string("{\"save_version\": 4}")
	f.close()


## The fixture dialog: SAVE mode (all three §4.6 row states on screen).
func _open_save_slot(dialog: Control) -> void:
	dialog.call("open", 0)


# --- rig: settings (W2-D) ------------------------------------------------------

func _rig_settings() -> void:
	_rig_modal_run()
	GameState.current_port = "lisbon"  # the S4 mount: Save/Return rows show


func _open_settings(panel_screen: Control) -> void:
	panel_screen.call("open")


# --- rig: gameover (W2-D) ------------------------------------------------------

func _rig_gameover() -> void:
	_rig_modal_run()


## The fixture death (a §4.9 reason, so the reason line shows). The screen
## is live from _ready — no open call needed.
func _open_gameover(screen: Control) -> void:
	screen.call("open_reason", "sunk")


# --- rig: ending (W2-D) --------------------------------------------------------

func _rig_ending() -> void:
	_rig_modal_run()
	# A served run: fame, reported discoveries, battle count, titles, one
	# met captain with wins + a negative stance (the nemesis/grudge rows).
	GameState.day = 210
	GameState.gold = 48250
	GameState.fame = 88
	GameState.battles_won = 14
	GameState.discoveries_reported = ["d_amazon"]
	GameState.titles["portugal"] = "baron"
	GameState.captain_states = {
		"cp_redbeard": {"wins": 3, "stance": -4, "tier_now": 2, "met": 30},
	}


## The fixture retirement (open_live — the fresh-retirement mode). The
## screen builds at _ready; the open call re-reads live state.
func _open_ending(screen: Control) -> void:
	screen.call("open_live")


# --- rig: duel (W2-D) ----------------------------------------------------------

func _rig_duel() -> void:
	_rig_modal_run()


## The fixture duel: the full best-of-5 preview against a pirate captain
## (the round rows' longest state — the `rounds` list block derives from
## them). The config goes through `Duel.preview` like the suites'.
func _open_duel(modal: Control) -> void:
	modal.call("open_duel", {
		"player_base": 15,
		"defender_base": 10,
		"seed": 33,
		"ship_name": "Sloop",
		"attacker_name": "You",
		"defender_name": "Pirate captain",
	})


# --- rig: battle (W2-D) --------------------------------------------------------

## A started battle (the window-sizes suite's pirate-encounter fixture) —
## the chrome (top bar, bottom bar, command buttons) renders over it.
func _rig_battle() -> void:
	_rig_modal_run()
	GameState.day = 9


func _battle_encounter() -> Dictionary:
	var ships: Array = []
	for _index in 2:
		ships.append({
			"ship_type_id": "sloop",
			"durability": 40, "crew": 12, "provisions": 0, "water": 0,
			"cannons": 4, "equipment": {"figurehead": "", "sail": ""},
			"cargo": {},
		})
	return {
		"id": "hf_9_30_40_pirate", "kind": "pirate", "nation_id": "",
		"position": {"x": 30, "y": 40}, "day": 9, "ships": ships,
	}


## A started battle, run to its after-action report — the chrome AND the
## `after_lines` list block capture (the §4.9 bust needs a captain; the
## composer override is not installed here, so row 0 is text-only).
func _open_battle(screen: Control) -> void:
	screen.set("route_to_world", false)
	screen.call("open_battle", _battle_encounter())
	await get_tree().process_frame
	screen.call("run_to_completion", 30)


# --- rig: sandbox (W2-D) -------------------------------------------------------

func _rig_sandbox() -> void:
	_rig_modal_run()


# --- rig: dossier (W2-D) -------------------------------------------------------

func _rig_dossier() -> void:
	_rig_modal_run()
	CaptainsLib2.ensure(CaptainsLib2.canon_list()[0].get("id", ""))


## The fixture dossier: the captain card + career log (setup IS the open).
func _open_dossier(panel: Control) -> void:
	panel.call("setup", str(CaptainsLib2.canon_list()[0].get("id", "")))


# --- rig: fleet_view (W2-D) ----------------------------------------------------

func _rig_fleet_view() -> void:
	_rig_modal_run()
	GameState.current_port = "lisbon"
	GameState.fleet = [FleetLib.new_ship("caravel", 0),
		FleetLib.new_ship("sloop", 1)]


## The fixture view: a two-ship fleet at port (rebuild IS the open).
func _open_fleet_view(view: Control) -> void:
	view.call("rebuild")


# --- rig: officer_roster (W2-D) -------------------------------------------------

func _rig_officer_roster() -> void:
	_rig_modal_run()
	preload("res://scripts/player/character.gd").recruit("off_mateus_alvares")


## The fixture view: one employed officer (rebuild IS the open).
func _open_officer_roster(view: Control) -> void:
	view.call("rebuild")


# --- rig: intel_window (W2-D) --------------------------------------------------

func _rig_intel_window() -> void:
	_rig_modal_run()
	GameState.current_port = "lisbon"  # the fleet tab's port actions live


## The fixture window: opens on the 委托 tab so the `quests` list block
## captures (one commission accepted at the docked port first).
func _open_intel_window(window: Control) -> void:
	var offers: Array = QuestGenLib.available_offers("lisbon", GameState.day)
	if not offers.is_empty():
		QuestGenLib.accept(offers[0], "lisbon", GameState.day)
	window.call("open_tab", "quests")


# --- rig: reputation_view (W2-D) -----------------------------------------------

func _rig_reputation_view() -> void:
	_rig_modal_run()
	GameState.player["reputation"]["spain"] = 12
	GameState.player["reputation"]["ottoman"] = -8


## The fixture view: a fresh build renders the six-nation table (the view
## is live from _ready; refresh fills the cells).
func _open_reputation_view(view: Control) -> void:
	view.call("refresh")


# --- rig: captain_view (W2-D) ---------------------------------------------------

func _rig_captain_view() -> void:
	_rig_modal_run()
	GameState.day = 41


## The fixture view: refresh renders the nation/day line + the player card.
func _open_captain_view(view: Control) -> void:
	view.call("refresh")
