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
	if not PORT_SCENES.has(screen_id) and not W2D_SCENES.has(screen_id):
		push_error("layout_capture: no rig for '%s' yet (its W2 wave "
				+ "adds one)" % screen_id)
		return false
	if PORT_SCENES.has(screen_id):
		_rig_port()
	else:
		call("_rig_%s" % screen_id)  # the per-screen W2 rig
	var scene: PackedScene = load(
			PORT_SCENES.get(screen_id, W2D_SCENES.get(screen_id, "")))
	var screen_root: Control = scene.instantiate()
	add_child(screen_root)
	# A modal screen opens (and registers) through its open call, not its
	# _ready — the per-screen `_open_<id>` hook runs it before the settle.
	if has_method("_open_%s" % screen_id):
		call("_open_%s" % screen_id, screen_root)
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
