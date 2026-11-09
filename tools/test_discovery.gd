extends Node
## T10 acceptance tests (docs/IMPLEMENT-Phase1.md T10; docs/20-* §4.2,
## §4.8.2, §4.11–§4.12; docs/50-* §4.2, §5; docs/80-* §4.3, §4.5–§4.7).
## Headless scene test:
##
##   godot --headless res://tools/test_discovery.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: 1 new-game capitals, 2 sighting radius + Chebyshev boundary,
## 3 discover-then-enter, 4 Set Sail round trip through the real scenes,
## 5 minimap crop (geometry/explored-only/nation dots), 5b the dateline crop,
## 5c the Chart screen S17 (the reveal→dot wiring + the §4.3 modal round trip;
## the chart-local basics live in test_chart), 5d minimap/chart identity + the
## discovery reveal at 18, 6 desertion hook, 7 dialog order at entry.
## (Gate-audit trim 2026-11-02: shared world boots across adjacent sections.)

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")

const WORLD_SCENE := "res://scenes/world/world_map.tscn"
const PORT_SCENE := "res://scenes/port/port_screen.tscn"

## The six §4.11 new-game capitals.
const CAPITALS: Array[String] = [
	"amsterdam", "istanbul", "lisbon", "london", "seville", "venice",
]

## Open-water cell for the minimap fixture (every neighbour is sea), in the
## world map's variables band far from every harbor. Phase 4: re-anchored from
## the retired P1 grid (20,20) by task G.
const OPEN_CELL := Vector2i(1800, 660)
## Lisbon's derived harbor **berth** (`10-*` §6.1), its **shore** tile (`20-*`
## §4.11.1) and the sea tile beside it: (2049,615) is carved coastal sea.
const LISBON := Vector2i(2050, 615)
const LISBON_SHORE := Vector2i(2051, 615)
const SEA_BESIDE_LISBON := Vector2i(2049, 615)
## Valencia's harbor tile on the world map (derived, not stored). It is not a
## capital, so it starts unknown. The three cells below sit at Chebyshev 48 /
## 49 / 52 from the shore tile and each is a legal step from the next; the
## (D48, D49) pair straddles the base radius 48 (`20-*` §4.11).
const VALENCIA_HARBOR := Vector2i(2156, 606)
## Valencia's shore tile: the `#` tile orthogonally adjacent to its berth that
## the port is drawn on and docked into (`20-*` §4.11.1).
const VALENCIA_SHORE := Vector2i(2155, 606)
const VALENCIA_D26 := Vector2i(2104, 554)
const VALENCIA_D25 := Vector2i(2107, 557)
const VALENCIA_D24 := Vector2i(2108, 558)

var _failures: Array[String] = []
var _checks := 0

## The §5a boot is queue_freed when its section ends; later §5 sections
## re-spawn the shared world when that free has landed (a freed instance
## reads as null/invalid here and the old direct use raised a SCRIPT ERROR).
func _ensure_shared_world() -> Node:
	if _shared_world != null and is_instance_valid(_shared_world) \
			and is_instance_valid(_shared_host):
		return _shared_world
	if _shared_host != null and is_instance_valid(_shared_host):
		_shared_host.queue_free()
	var spawned: Array = _spawn_world()
	_shared_host = spawned[0]
	_shared_world = spawned[1]
	return _shared_world

## Shared spawned world (gate-audit trim 2026-11-02, ≤ 10 boots): adjacent
## sections that only need a `_make_run` + `sync_from_state()` re-fixture
## reuse one boot (`sync_from_state` re-runs the same `_reveal()` the boot
## path runs — `world_map.gd` `_ready` vs `sync_from_state`).
var _shared_host: Node = null
var _shared_world: Node = null


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/world.png", DataLoader.map_legend
	)
	_check(ok, "map loads for the discovery fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	if DataLoader.map != null:
		_check(DataLoader.map.port_cell("valencia") == VALENCIA_HARBOR,
			"valencia stands at its derived harbor tile %s (got %s)"
			% [str(VALENCIA_HARBOR), str(DataLoader.map.port_cell("valencia"))])
		_check(DataLoader.map.is_passable(OPEN_CELL)
			and DataLoader.map.is_passable(VALENCIA_D24)
			and DataLoader.map.is_passable(VALENCIA_D25)
			and DataLoader.map.is_passable(VALENCIA_D26),
			"fixture cells are passable sea")

	_test_new_game_capitals()
	await _settle()
	_test_sighting_radius()
	await _settle()
	_test_discover_then_enter()
	await _settle()
	await _test_set_sail_round_trip()
	await _settle()
	_test_port_screen_standalone()
	await _settle()
	_test_minimap()
	await _settle()
	_test_dateline_crop()
	await _settle()
	await _test_chart_screen()
	await _settle()
	await _test_minimap_chart_identity()
	await _settle()
	_test_desertion_hook()
	await _settle()
	_test_dialog_order()
	await _settle()
	_report()


## Lets `queue_free()`d host scenes actually leave the tree (their EventBus
## connections would otherwise survive into the next section).
func _settle() -> void:
	await get_tree().process_frame


# --- Fixtures --------------------------------------------------------------

## Minimal Portugal run on open water: caravel, full crew, ample stores.
## `navigation` is the raw stat (officers are added separately).
func _make_run(
	navigation: int = 10,
	cell: Vector2i = OPEN_CELL,
	morale: int = 70,
	officers: Array = []
) -> void:
	# Phase-8 v9 player block (`50-*` §4.8): `navigation` is the navigation
	# SKILL (the old four-stat block is retired).
	var skills := {}
	for key in SkillsLib.KEYS:
		skills[key] = 0
	skills["navigation"] = navigation
	var counters := {}
	for key in SkillsLib.KEYS:
		counters[key] = 0
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": skills,
		"skill_counters": counters,
		"alloc_pending": 0,
		"xp": 0,
		"level": 1,
		"officers": officers,
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	# Seeded officer states so `Skills.appoint`/contributions see the roster.
	var states := {}
	for officer_id in officers:
		states[str(officer_id)] = {"loyalty": 50, "sea_days": 0,
			"post_id": "", "ship_id": "", "talk_cd_day": 0,
			"gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0}
	GameState.officer_states = states
	var ship_type: Dictionary = DataLoader.get_ship_type("caravel")
	GameState.fleet = [FleetLib.new_ship("caravel", int(ship_type["crew_min"]))]
	GameState.fleet[0]["provisions"] = 100
	GameState.fleet[0]["water"] = 100
	GameState.day = 1
	GameState.gold = 100000
	GameState.morale = morale
	GameState.current_port = null
	GameState.known_ports = []
	GameState.explored_tiles = {}
	GameState.world = {
		"position": {"x": cell.x, "y": cell.y},
		"clock_fraction": 0.0,
		"weather": "fair",
	}
	SailingSimLib.reset_ledger_state()


## A world scene added under a throwaway host (routing disabled, so the test's
## own scene root is never swapped — the `new_game(..., route)` convention).
## Returns `[host, world]`.
func _spawn_world(route: bool = false) -> Array:
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = route
	host.add_child(world)
	return [host, world]


## Closes every modal the HUD still shows or queues, collecting the texts in
## the order they were displayed. Returns the texts.
func _drain_dialogs(hud) -> Array[String]:
	var shown: Array[String] = []
	var guard := 0
	while hud != null and hud.has_modal() and guard < 64:
		guard += 1
		var dialog = hud.current_dialog()
		if dialog == null:
			break
		shown.append(dialog.message_text())
		dialog.close()
	return shown


# --- 1. New game knows exactly the six capitals ---------------------------

func _test_new_game_capitals() -> void:
	GameState.new_game("portugal", false)
	var known: Array = GameState.known_ports.duplicate()
	known.sort()
	var expected: Array = CAPITALS.duplicate()
	expected.sort()
	_check(known == expected,
		"new game knows exactly the 6 capitals (got %s)" % str(known))
	_check(known.size() == 6,
		"new game knows 6 ports, nothing else (got %d)" % known.size())
	for port_id in CAPITALS:
		_check(GameState.known_ports.has(port_id),
			"%s is known at new game" % port_id)
	for port_id in GameState.known_ports:
		_check(DataLoader.map.port_cell(str(port_id)) != Vector2i(-1, -1),
			"%s has a harbor tile on the map" % port_id)
	_check(not GameState.known_ports.has("valencia"),
		"valencia (not a capital) is unknown at new game")


# --- 2. Sighting radius & Chebyshev boundary ------------------------------

## Reveals from `cell` with the world scene's ready path and reports whether
## `port_id` became known.
func _known_from(cell: Vector2i, navigation: int, officers: Array = []) -> bool:
	_make_run(navigation, cell, 70, officers)
	var spawned: Array = _spawn_world()
	var world = spawned[1]
	var known: bool = GameState.known_ports.has("valencia")
	spawned[0].queue_free()
	return known


func _test_sighting_radius() -> void:
	# Phase 8 (`20-*` §4.11, `50-*` §4.3): radius = 48 + floor(navigation / 12)
	# with navigation the EFFECTIVE skill (player + in-post pilot contribution).
	_make_run(0)
	_check(CharacterLib.sighting_radius() == 48,
		"navigation 0 → sighting radius 48 (§4.11 formula; got %d)"
		% CharacterLib.sighting_radius())
	_make_run(12)
	_check(CharacterLib.sighting_radius() == 49,
		"navigation 12 → sighting radius 49 (got %d)" % CharacterLib.sighting_radius())
	_make_run(24)
	_check(CharacterLib.sighting_radius() == 50,
		"navigation 24 → sighting radius 50 (got %d)" % CharacterLib.sighting_radius())
	_make_run(48)
	_check(CharacterLib.sighting_radius() == 52,
		"navigation 48 → sighting radius 52 (got %d)" % CharacterLib.sighting_radius())
	# §4.3 worked example (Phase 8): Mateus (pilot, main navigation 30) in post
	# over a skill-0 player → effective 30 → radius 50.
	_make_run(0, OPEN_CELL, 70, ["off_mateus_alvares"])
	_check(SkillsLib.appoint("off_mateus_alvares", "pilot"),
		"pilot appointment accepted (navigation 30 ≥ prereq 20)")
	_check(SkillsLib.effective_skill("navigation") == 30,
		"pilot in post gives effective navigation 30 (got %d)"
		% SkillsLib.effective_skill("navigation"))
	_check(CharacterLib.sighting_radius() == 50,
		"skill 0 + pilot (30) → sighting radius 50 (§4.3 worked example, got %d)"
		% CharacterLib.sighting_radius())

	# Chebyshev boundary at the Phase-6 base: exactly `radius` reveals,
	# `radius + 1` does not (two real scene boots for the straddling pair).
	_check(_known_from(VALENCIA_D24, 10),
		"nav 10 (radius 48): distance 48 is revealed")
	_check(not _known_from(VALENCIA_D25, 10),
		"nav 10 (radius 48): distance 49 is NOT revealed")
	# The radius-49 pair (nav 20) on one live scene via the re-fixture seam
	# (gate-audit trim 2026-11-02: the boundary geometry is already proven by
	# the straddling pair above and the direct formula checks at the top).
	_make_run(20, VALENCIA_D25)
	var spawned: Array = _spawn_world()
	var world = spawned[1]
	_check(GameState.known_ports.has("valencia"),
		"nav 20 (radius 49): distance 49 is revealed")
	_make_run(20, VALENCIA_D26)
	world.sync_from_state()
	_check(not GameState.known_ports.has("valencia"),
		"nav 20 (radius 49): distance 52 is NOT revealed")
	# The officer path agrees at its own boundary (radius 50 = Mateus over a
	# skill-0 player): distance 49 revealed, distance 52 not.
	_make_run(0, VALENCIA_D25, 70, ["off_mateus_alvares"])
	SkillsLib.appoint("off_mateus_alvares", "pilot")
	world.sync_from_state()
	var officer_at_49: bool = GameState.known_ports.has("valencia")
	_make_run(0, VALENCIA_D26, 70, ["off_mateus_alvares"])
	SkillsLib.appoint("off_mateus_alvares", "pilot")
	world.sync_from_state()
	_check(officer_at_49 and not GameState.known_ports.has("valencia"),
		"pilot in post (effective 30, radius 50): boundary at 49 revealed / 52 not")
	spawned[0].queue_free()


# --- 3. Discover-then-enter ----------------------------------------------

func _test_discover_then_enter() -> void:
	# Gate-audit trim 2026-11-02: one spawned world carries all three clauses —
	# each re-fixtured through `_make_run` + `sync_from_state()` (the same
	# reveal the fresh boot runs).
	# Approach a NOT-yet-known harbor from beyond the sighting radius.
	_make_run(10, VALENCIA_D25)  # distance 49, radius 48
	var spawned: Array = _spawn_world()
	var world = spawned[1]
	_check(not GameState.known_ports.has("valencia"),
		"valencia is unknown from beyond the radius (distance 49, radius 48)")
	_check(not GameState.explored_tiles.has(VALENCIA_HARBOR),
		"the harbor tile is unexplored from beyond the radius")

	# One step inward: the sighting reveal discovers it without docking (§4.11).
	_check(world.try_step(VALENCIA_D24), "stepping inward toward valencia succeeds")
	_check(GameState.known_ports.has("valencia"),
		"approaching within the radius discovers valencia (§4.11)")
	_check(GameState.current_port == null,
		"discovery alone does not dock (current_port %s)"
		% str(GameState.current_port))
	# Permanent: moving away again keeps it.
	_check(world.try_step(VALENCIA_D25), "stepping back out succeeds")
	_check(GameState.known_ports.has("valencia"),
		"a discovered port stays known after moving away")

	# Entering an *unknown* harbor docks by heading into its **shore** tile from
	# the berth (20-* §4.11.1) — one legal gesture from valencia's berth, which
	# the re-fixture's sighting knows (the fixture forgets it again below to
	# exercise the entry branch).
	_make_run(10, VALENCIA_HARBOR)
	world.sync_from_state()
	GameState.known_ports = []  # forget everything the reveal found
	var entered: Array = []
	var listener := func(port_id: String) -> void: entered.append(port_id)
	EventBus.port_entered.connect(listener)
	var clock_before := float(GameState.world["clock_fraction"])
	_check(not GameState.known_ports.has("valencia"),
		"valencia is unknown just before the entry step")
	_check(DataLoader.map.port_cell("valencia") == VALENCIA_HARBOR,
		"the fleet stands on valencia's berth %s" % str(VALENCIA_HARBOR))
	_check(DataLoader.map.shore_cell("valencia") == VALENCIA_SHORE,
		"valencia's shore tile is %s" % str(VALENCIA_SHORE))
	var stepped: bool = world.try_step(VALENCIA_SHORE)
	EventBus.port_entered.disconnect(listener)
	_check(stepped, "heading into valencia's shore tile docks (no error)")
	_check(entered == ["valencia"],
		"port_entered('valencia') fired exactly once (got %s)" % str(entered))
	_check(GameState.known_ports.has("valencia"),
		"entering an unknown port discovers it (§4.11)")
	_check(GameState.current_port == "valencia",
		"current_port is valencia after entry (got %s)" % str(GameState.current_port))
	# §4.11.1: exactly one move's worth of days **plus the §4.1b docking hour**
	# before the screen, and the fleet stays on the berth (docking never steps
	# onto the land tile). Phase-6 master ruling: the docking charge carries
	# the docking move's own heading — here W (shore west of berth), running
	# against the guard-default easterly wind (`world.wind_dir` default "E")
	# = 1/26, then +1h (added 2026-11-02).
	var docked_cost := SailingSimLib.move_cost(SailingSimLib.heading_of_delta(
		VALENCIA_SHORE - VALENCIA_HARBOR)) + 1.0 / 24.0
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
		clock_before + docked_cost),
		"the docking cost is one move_cost(heading) + 1h (%.4f → %.4f)"
		% [clock_before, float(GameState.world["clock_fraction"])])
	_check(GameState.world_tile() == VALENCIA_HARBOR,
		"the fleet stays on the berth after docking (got %s)"
		% str(GameState.world_tile()))
	_drain_dialogs(world.get_node("HUDLayer/HUD"))

	# With routing enabled the entry targets S4; because this world instance is
	# a child (not the tree's current scene) the router must not swap the test's
	# root — docs/90-* §7 "no scene ever frees another". (Same world, flag
	# flipped: the router reads `route_to_port` at entry time.)
	_make_run(10, VALENCIA_HARBOR)
	world.route_to_port = true
	world.sync_from_state()
	_check(world.port_route_target() == "",
		"no route target before any entry")
	world._enter_port("valencia")
	_check(world.port_route_target() == PORT_SCENE,
		"with routing enabled the entry targets the port screen (got '%s')"
		% world.port_route_target())
	_check(not world.is_active_scene(),
		"a child-instanced world scene is not the active scene")
	_drain_dialogs(world.get_node("HUDLayer/HUD"))
	_check(is_instance_valid(world),
		"draining the queue does not swap the test's own scene root")
	spawned[0].queue_free()


# --- 4. Set Sail round trip through the real scenes ----------------------

func _test_set_sail_round_trip() -> void:
	# The fleet starts on Lisbon's **berth** and docks by heading into the shore
	# tile (20-* §4.11.1).
	_make_run(10, LISBON)
	GameState.known_ports = ["lisbon"]
	GameState.world["clock_fraction"] = 0.4

	# Keep this test node alive under the root while the router swaps scenes
	# (`current_scene` is what `change_scene_to_file` replaces/frees).
	var tree := get_tree()
	tree.current_scene = null
	tree.change_scene_to_file(WORLD_SCENE)
	await tree.process_frame
	await tree.process_frame

	var world = tree.current_scene
	_check(world != null and world.scene_file_path == WORLD_SCENE,
		"world_map.tscn is the active scene (got %s)"
		% ("null" if world == null else world.scene_file_path))
	if world == null or world.scene_file_path != WORLD_SCENE:
		return
	_check(world.is_active_scene(), "the world scene sees itself as the active scene")
	_check(world.fleet_cell() == LISBON,
		"world restores the fleet on the berth tile (got %s)"
		% str(world.fleet_cell()))

	# Enter Lisbon through the real input path: dock by heading into its **shore**
	# tile from the berth (20-* §4.11.1). Set Sail must return the fleet to the
	# berth, which is where `world.position` already is.
	var harbor := LISBON
	_check(DataLoader.map.port_cell("lisbon") == harbor,
		"Lisbon's berth is %s" % str(harbor))
	_check(DataLoader.map.shore_cell("lisbon") == LISBON_SHORE,
		"Lisbon's shore tile is %s" % str(LISBON_SHORE))
	_check(world.try_step(LISBON_SHORE), "heading into Lisbon's shore tile docks")
	_drain_dialogs(world.get_node("HUDLayer/HUD"))
	await tree.process_frame
	await tree.process_frame

	var port = tree.current_scene
	_check(port != null and port.scene_file_path == PORT_SCENE,
		"port entry routes to port_screen.tscn after the dialog chain (got %s)"
		% ("null" if port == null else port.scene_file_path))
	if port == null or port.scene_file_path != PORT_SCENE:
		return
	_check(port.port_id() == "lisbon",
		"port screen knows it is Lisbon (got '%s')" % port.port_id())

	# --- The T10 shell -----------------------------------------------------
	var lisbon: Dictionary = DataLoader.get_port("lisbon")
	var nation: Dictionary = DataLoader.get_nation("portugal")
	_check((port.get_node("header/PortName") as Label).text
		== I18n.t(lisbon["name"]),
		"port header shows the localized port name")
	_check((port.get_node("header/NationName") as Label).text
		== I18n.t(nation["name"]),
		"port header shows the localized nation")
	_check((port.get_node("header/Greeting") as Label).text
		== I18n.t(lisbon["flavor"]),
		"the greeting banner shows the port's flavor line")
	_check((port.get_node("header/NationSwatch") as ColorRect).color
		== PaletteLib.nation_color(str(nation["color"])),
		"the nation swatch uses the nation color")
	var hud = port.get_node_or_null("HUD")
	_check(hud != null, "the port screen instances the shared HUD (§4.5)")
	if hud != null:
		_check(not hud.is_minimap_visible(),
			"S4 replaces the sea viewport: minimap hidden (§4.5)")
		_check((hud.get_node("TopRow/Gold") as Label).text
			== I18n.fmt("ui.gold_amount", {"gold": hud.format_thousands(GameState.gold)}),
			"the S4 HUD still renders the live gold bar")
	var sail: Button = port.get_node("footer/SetSail")
	_check(sail.text == I18n.t_key("port.set_sail"),
		"the Set Sail button uses port.set_sail (%s)" % sail.text)
	_check(not sail.disabled, "Set Sail is enabled while docked")
	# T11 made the hub render rows from the port data. Lisbon is a capital, so
	# its `facilities` object lists all six ids → six rows, in the §4.1 order.
	_check(port.facility_row_ids() == ["market", "shipyard", "tavern", "inn",
			"guild", "palace"],
		"T11 renders the six Lisbon rows from the port data (got %s)"
		% str(port.facility_row_ids()))
	_check(port.facility_row_count() == 6,
		"facility_row_count() reports the six rows (got %d)"
		% port.facility_row_count())
	_check(port.facility_container().get_child_count() > 0,
		"the rows land in the facility container")
	_check(port.has_method("add_facility_row"),
		"the T11 extension point add_facility_row() exists")
	# The extension point itself: a row binds its label through ui_strings,
	# takes the locked button height, and reports the facility id on press.
	# `route_to_facility = false` keeps the test on S4: the assertion is about
	# the wiring (intent + target), not about swapping the scene root (T12–T15
	# own their screens' own routing tests).
	port.route_to_facility = false
	var requested: Array = []
	port.facility_requested.connect(func(fid: String) -> void: requested.append(fid))
	var rows_before: int = port.facility_container().get_child_count()
	var row: Button = port.add_facility_row("market", "port.market")
	_check(port.facility_card_texts("market")["name"] == I18n.t_key("port.market"),
		"add_facility_row() binds port.market (%s)"
		% str(port.facility_card_texts("market")))
	_check(row.custom_minimum_size == Vector2(320, 64),
		"facility cards use the fixed 320×64 §4.8.1 spec")
	_check(port.facility_container().get_child_count() == rows_before + 1,
		"the row lands in the facility container")
	row.pressed.emit()
	_check(requested.has("market"),
		"pressing the row reports the facility id (got %s)" % str(requested))
	_check(port.is_inside_tree() and tree.current_scene == port,
		"route_to_facility=false keeps the port screen in place")
	I18n.set_locale("zh")
	_check((row.get_meta("name_label") as Label).text == I18n.t_key("port.market"),
		"facility cards rebind on locale_changed (%s)"
		% str((row.get_meta("name_label") as Label).text))
	I18n.set_locale("en")
	row.queue_free()

	# Locale rebinding.
	I18n.set_locale("zh")
	_check((port.get_node("header/Greeting") as Label).text
		== I18n.t(lisbon["flavor"]),
		"the port screen rebinds on locale_changed")
	_check(sail.text == I18n.t_key("port.set_sail"),
		"the Set Sail label rebinds on locale_changed")
	I18n.set_locale("en")

	# A modal blocks the Esc → Set Sail edge (docs/80-* §6).
	if hud != null:
		hud.show_dialog("ui.saved")
		_check(port.has_modal(), "has_modal() sees the HUD dialog")
		var blocked_esc := InputEventAction.new()
		blocked_esc.action = "back"
		blocked_esc.pressed = true
		port._unhandled_input(blocked_esc)
		_check(port.is_inside_tree() and GameState.current_port == "lisbon",
			"Esc behind a modal does not leave harbour (current_port %s)"
			% str(GameState.current_port))
		_drain_dialogs(hud)
		_check(not port.has_modal(), "the dialog queue drains")

	# --- Esc on S4 = the Set Sail edge, which since Phase 5 opens the
	# provisioning prompt first (docs/80-* §4.3, §4.6.1; docs/20-* §4.11.2) ---
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	port._unhandled_input(esc)
	await tree.process_frame
	await tree.process_frame

	_check(tree.current_scene == port,
		"Esc on S4 opens the provisioning prompt instead of routing directly")
	var prompt = port.provisions_dialog()
	_check(prompt != null and prompt.is_open(),
		"Esc on S4 opens the Set-Sail provisioning prompt (§4.6.1)")
	_check(GameState.current_port == "lisbon",
		"the prompt keeps the fleet in port until Set Sail is confirmed")
	# `Esc` inside the prompt is *back to S4*, not sail.
	var prompt_esc := InputEventAction.new()
	prompt_esc.action = "back"
	prompt_esc.pressed = true
	prompt._unhandled_input(prompt_esc)
	await tree.process_frame
	_check(not prompt.is_open(), "Esc inside the prompt closes it back to S4")
	_check(GameState.current_port == "lisbon",
		"Esc inside the prompt does not sail (still docked)")
	# Re-open and sail through the prompt's own Set Sail — the existing path.
	port._unhandled_input(esc)
	await tree.process_frame
	_check(prompt.is_open(), "Esc re-opens the prompt")
	_check(prompt.get_node("Panel/Footer/Sail").disabled == false,
		"Set Sail is enabled with a crew and a day of supplies")
	# §4.1b: capture the docked clock just before the sail for the +1h assert.
	var fraction_before_sail := float(GameState.world["clock_fraction"])
	prompt.get_node("Panel/Footer/Sail").pressed.emit()
	await tree.process_frame
	await tree.process_frame

	var back = tree.current_scene
	_check(back != null and back.scene_file_path == WORLD_SCENE,
		"Esc (Set Sail) routes back to world_map.tscn (got %s)"
		% ("null" if back == null else back.scene_file_path))
	_check(GameState.world_tile() == harbor,
		"Set Sail leaves the fleet on the berth tile (got %s)"
		% str(GameState.world_tile()))
	_check(DataLoader.map.is_passable(GameState.world_tile()),
		"the exit tile is water, never a land tile")
	# §4.1b continuous clock (amended 2026-11-02): the sail-out charges +1h
	# and the fraction carries — no reset.
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
			fraction_before_sail + 1.0 / 24.0),
		"Set Sail charges +1h and carries the fraction (%.10f → %.10f)"
		% [fraction_before_sail, float(GameState.world["clock_fraction"])])
	_check(GameState.current_port == null,
		"Set Sail clears current_port (got %s)" % str(GameState.current_port))
	if back != null and back.scene_file_path == WORLD_SCENE:
		_check(back.fleet_cell() == harbor,
			"the returned world scene puts the marker on the berth tile (got %s)"
			% str(back.fleet_cell()))
	# Leave the tree in a clean state for the remaining (non-routing) tests.
	if tree.current_scene != null:
		tree.current_scene.queue_free()
		tree.current_scene = null
	await tree.process_frame


# --- 4b. Port screen opened standalone (§ "Load standalone → exit 0") ----

func _test_port_screen_standalone() -> void:
	# No run in progress, no `current_port`: the scene must still build, show
	# neutral placeholders and refuse to sail (no bogus route, no I18n error).
	GameState.player = {}
	GameState.fleet = []
	GameState.current_port = null
	GameState.world = {}

	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var port = PortScene.instantiate()
	host.add_child(port)

	_check(port.port_id() == "", "standalone: port_id() is empty")
	_check(port.port_data().is_empty(), "standalone: port_data() is empty")
	var name_label: Label = port.get_node("header/PortName")
	_check(name_label.text == "-", "standalone: the port name is a placeholder (%s)"
		% name_label.text)
	var greeting: Label = port.get_node("header/Greeting")
	_check(greeting.text == "", "standalone: the greeting banner is empty, not <key>")
	var day_greeting: Label = port.get_node("header/DayGreeting")
	_check(not day_greeting.visible, "standalone: the day greeting row is hidden")
	var sail: Button = port.get_node("footer/SetSail")
	_check(sail.disabled, "standalone: Set Sail is disabled with nowhere to sail from")
	_check(sail.text == I18n.t_key("port.set_sail"),
		"standalone: the button label still binds (%s)" % sail.text)
	# Esc must not route anywhere either.
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	port._unhandled_input(esc)
	_check(port.is_inside_tree(), "standalone: Esc leaves the scene in place")
	host.queue_free()


# --- 5. Minimap crop (docs/20-* §4.12, docs/80-* §4.5 as amended) --------

func _test_minimap() -> void:
	_make_run(10, OPEN_CELL)
	# The world scene owns exploration (§4.11/§4.12); spawn it first so the
	# explored set is populated exactly as it is at sea, then exercise the HUD
	# minimap crop against that real set.
	var spawned: Array = _spawn_world()
	var world = spawned[1]
	_check(GameState.explored_tiles.has(OPEN_CELL),
		"scene ready marks the fixture tile explored")

	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)
	hud.set_fleet_cell(OPEN_CELL)

	# Geometry: a fixed 256×192 box at 2 px/tile = a 128×96-tile **crop**
	# (docs/80-* §4.5, docs/20-* §4.12). Phase 4 deleted the `M` enlarged mode,
	# so the cached image is the crop box, never a whole-world image.
	_check(hud.minimap_rect().size == Vector2(256, 192),
		"minimap is 256×192 (got %s)" % str(hud.minimap_rect().size))
	_check(hud.minimap_px_per_tile() == 2,
		"minimap draws 2 px per tile (got %d)" % hud.minimap_px_per_tile())
	_check(hud.minimap_crop_tiles() == Vector2i(128, 96),
		"the crop is 128×96 tiles (got %s)" % str(hud.minimap_crop_tiles()))
	_check(hud.minimap_image_size() == Vector2i(256, 192),
		"the cached image is the 256×192 crop, not the whole world (got %s)"
		% str(hud.minimap_image_size()))
	# Phase 12 (docs/80-UI-UX.md §4.8.9): the minimap block is an authored
	# tile cluster — the box sits at tile (1,2), directly under the 2-tile
	# top bar (the 16px-margin pin quantizes onto the chrome grid).
	_check(hud.minimap_rect().position == Vector2(
		PaletteLib.CHROME_TILE, PaletteLib.TOP_BAR_H),
		"minimap sits at its authored tile (1,2) under the top bar (got %s)"
		% str(hud.minimap_rect().position))
	# The crop is centred on the fleet: 128 wide → origin = fleet.x − 64.
	_check(hud.minimap_crop_origin() == OPEN_CELL - Vector2i(64, 48),
		"the crop is centred on the fleet (origin %s)"
		% str(hud.minimap_crop_origin()))

	# `M` is gone (`80-*` §4.3): its toggle is a no-op and the seam that
	# `world_map.gd::_modal_open()` still probes reports false, so the minimap
	# never blocks movement the way the old enlarged overlay did.
	hud.toggle_minimap()
	_check(hud.minimap_rect().size == Vector2(256, 192),
		"the retired `M` toggle leaves the box at 256×192 (got %s)"
		% str(hud.minimap_rect().size))
	_check(not hud.is_minimap_enlarged(),
		"is_minimap_enlarged() is the always-false Phase-4 shim")
	var world_hud = world.get_node("HUDLayer/HUD")
	_check(not world_hud.is_minimap_enlarged(),
		"the world scene's HUD reports no enlarged mode either")
	_check(not world._modal_open(),
		"the minimap is no longer a modal overlay (movement is not blocked)")

	# Explored-only: the fleet tile is painted, an explored-square hole stays fog.
	_check(hud.minimap_pixel_color(OPEN_CELL) == PaletteLib.SEA,
		"an explored sea tile is painted SEA (got %s)"
		% str(hud.minimap_pixel_color(OPEN_CELL)))
	var radius: int = CharacterLib.sighting_radius()
	var beyond := OPEN_CELL + Vector2i(radius + 1, 0)
	_check(not GameState.explored_tiles.has(beyond),
		"a tile beyond the sighting radius is not explored")
	_check(hud.minimap_contains(beyond),
		"that tile is still inside the 128×96 crop (so the check is sharp)")
	_check(hud.minimap_pixel_color(beyond) == PaletteLib.PANEL_BG,
		"an unexplored tile inside the crop stays panel background (got %s)"
		% str(hud.minimap_pixel_color(beyond)))
	# A land tile inside the square is painted LAND, not SEA.
	var land_cell := Vector2i(-1, -1)
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var cell := OPEN_CELL + Vector2i(dx, dy)
			if DataLoader.map.terrain_kind(cell) == "land":
				land_cell = cell
				break
		if land_cell.x >= 0:
			break
	_check(land_cell.x >= 0, "an explored land tile exists near the fixture")
	if land_cell.x >= 0:
		_check(hud.minimap_pixel_color(land_cell) == PaletteLib.LAND,
			"explored land is painted LAND (got %s)"
			% str(hud.minimap_pixel_color(land_cell)))

	# Growth on movement; far tiles stay unexplored and outside the crop.
	var before: int = GameState.explored_tiles.size()
	var next_cell := OPEN_CELL + Vector2i(1, 0)
	_check(world.try_step(next_cell), "the fixture step succeeds")
	_check(GameState.explored_tiles.size() > before,
		"moving grows the explored set (%d → %d)" % [before, GameState.explored_tiles.size()])
	_check(GameState.explored_tiles.has(next_cell), "the new fleet tile is explored")
	_check(not GameState.explored_tiles.has(next_cell + Vector2i(radius + 1, 0)),
		"a tile outside the radius of every visited tile stays unexplored")
	hud.set_fleet_cell(next_cell)
	_check(hud.minimap_pixel_color(next_cell) == PaletteLib.SEA,
		"the crop follows the fleet onto the new tile")

	# Known-port dots: nation colors, known ports only.
	GameState.known_ports = ["lisbon", "valencia"]
	var dots: Array = hud.minimap_known_ports()
	_check(dots.size() == 2,
		"the minimap draws one dot per known port (got %d)" % dots.size())
	var by_id: Dictionary = {}
	for entry in dots:
		by_id[str(entry["port_id"])] = entry
	_check(by_id.has("lisbon") and by_id.has("valencia"),
		"the dots are lisbon and valencia (got %s)" % str(by_id.keys()))
	if by_id.has("lisbon"):
		var lisbon: Dictionary = DataLoader.get_port("lisbon")
		var nation: Dictionary = DataLoader.get_nation(str(lisbon["nation_id"]))
		_check(by_id["lisbon"]["color"] == PaletteLib.nation_color(str(nation["color"])),
			"lisbon's dot uses Portugal's nation color (got %s)"
			% str(by_id["lisbon"]["color"]))
		_check((by_id["lisbon"]["cell"] as Vector2i) == LISBON_SHORE,
			"lisbon's dot sits on its shore tile (got %s)"
			% str(by_id["lisbon"]["cell"]))
		_check((by_id["lisbon"]["berth_cell"] as Vector2i) == LISBON,
			"lisbon's dot carries its berth tile too (got %s)"
			% str(by_id["lisbon"]["berth_cell"]))
	if by_id.has("valencia"):
		var valencia: Dictionary = DataLoader.get_port("valencia")
		var nation2: Dictionary = DataLoader.get_nation(str(valencia["nation_id"]))
		_check(by_id["valencia"]["color"]
			== PaletteLib.nation_color(str(nation2["color"])),
			"valencia's dot uses Spain's nation color (got %s)"
			% str(by_id["valencia"]["color"]))
	# A port outside the crop is still listed (the layer is world-wide) but its
	# dot is not drawn — `minimap_contains()` is the single placement rule, and
	# the known set itself is untouched.
	_check(not hud.minimap_contains(LISBON),
		"lisbon is outside this crop, so its dot is not drawn (layer stays whole)")
	GameState.known_ports = ["lisbon"]
	_check(hud.minimap_known_ports().size() == 1,
		"an unknown port gets no dot (only known ports are drawn)")
	GameState.known_ports = []
	_check(hud.minimap_known_ports().is_empty(),
		"no known ports → no dots")

	# A fresh explored dict (new game / save load) clears the painted cache.
	GameState.explored_tiles = {}
	GameState.world["position"] = {"x": LISBON.x, "y": LISBON.y}
	world.sync_from_state()
	hud.set_fleet_cell(LISBON)
	_check(hud.minimap_pixel_color(OPEN_CELL) == PaletteLib.PANEL_BG,
		"a new explored set clears the previously painted tiles")
	_check(hud.minimap_pixel_color(LISBON) != PaletteLib.PANEL_BG,
		"the new fleet tile is painted again (markers sit on sea)")

	# Gate-audit trim 2026-11-02: this boot stays alive — §5c and §5d only
	# need a `_make_run` + `sync_from_state()` re-fixture on the same scene.
	_shared_host = spawned[0]
	_shared_world = world
	host.queue_free()


# --- 5b. The dateline crop (docs/20-* §4.12) ------------------------------

## Fleet at the eastern edge: the crop must wrap to `x = 0` with no void and no
## duplicated column. The grid is 4320 wide and the crop 128, so the window is
## `[4255..4319] ∪ [0..62]` (fleet on column 64) — the doc's "`[4256..4319]`
## then `[0..k]`" union shape, with the fleet centred rather than at the right
## edge (`20-*` §4.5/§4.12: "a … crop **around** the fleet").
func _test_dateline_crop() -> void:
	_make_run(10, Vector2i(4319, 172))
	GameState.explored_tiles = {}
	for cell in [Vector2i(4319, 172), Vector2i(0, 172), Vector2i(1, 172),
			Vector2i(5, 172), Vector2i(62, 172)]:
		GameState.explored_tiles[cell] = true

	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)
	hud.set_fleet_cell(Vector2i(4319, 172))

	_check(hud.minimap_crop_origin().x == 4255,
		"fleet x=4319: the crop starts at x=4255 (4319 − 64; got %d)"
		% hud.minimap_crop_origin().x)
	var columns: Array = hud.minimap_crop_columns()
	_check(columns.size() == 128,
		"the crop has 128 columns (got %d)" % columns.size())
	if columns.size() == 128:
		_check(columns[64] == 4319,
			"column 64 (the fleet's) is x=4319 (got %s)" % str(columns[64]))
		_check(columns[65] == 0,
			"column 65 wraps to x=0 (got %s)" % str(columns[65]))
		_check(columns[0] == 4255,
			"the crop's first column is x=4255 (got %s)" % str(columns[0]))
		_check(columns[127] == 62,
			"the crop's last column is x=62, so k = 62 (got %s)" % str(columns[127]))
		var unique: Dictionary = {}
		var contiguous := true
		for index in columns.size():
			unique[int(columns[index])] = true
			if index > 0:
				var expected := posmod(int(columns[index - 1]) + 1, 4320)
				if int(columns[index]) != expected:
					contiguous = false
		_check(unique.size() == 128,
			"the 128 crop columns are all distinct, no duplicate at the seam (got %d)"
			% unique.size())
		_check(contiguous,
			"the crop columns are contiguous across the seam (no void, no gap)")
		# The union the doc names: everything east of the fleet, then x=0..k.
		var east := columns.slice(0, 65)
		var west := columns.slice(65)
		_check(east[0] == 4255 and east[east.size() - 1] == 4319,
			"the eastern half is x∈[4255..4319] (got [%s..%s])"
			% [str(east[0]), str(east[east.size() - 1])])
		_check(west[0] == 0 and west[west.size() - 1] == 62,
			"the western half is x∈[0..62] (got [%s..%s])"
			% [str(west[0]), str(west[west.size() - 1])])

	# Pixel-level: tiles on both sides of the seam really are painted, and a
	# crop column just past k is not in the crop at all.
	for cell in [Vector2i(4319, 172), Vector2i(0, 172), Vector2i(1, 172),
			Vector2i(5, 172), Vector2i(62, 172)]:
		_check(hud.minimap_contains(cell),
			"%s is inside the dateline crop" % str(cell))
		_check(hud.minimap_pixel_color(cell) != PaletteLib.PANEL_BG,
			"%s is painted on the minimap (got %s)"
			% [str(cell), str(hud.minimap_pixel_color(cell))])
	_check(not hud.minimap_contains(Vector2i(63, 172)),
		"x=63 is outside the crop (k = 62)")
	_check(not hud.minimap_contains(Vector2i(4254, 172)),
		"x=4254 is outside the crop (it starts at 4255)")

	host.queue_free()



# --- 5c. Chart screen S17 (docs/80-* §4.6, §4.3) --------------------------

## The §4.11 → S17 wiring: a port revealed at the sighting boundary becomes a
## nation dot on the chart, and the open chart is a real modal over S3 —
## movement blocked, fleet and clock untouched by the round trip.
## (Gate-audit trim 2026-11-02: the chart-local S17 basics — the Tab/Esc
## machine, the open budget, the fit/aspect geometry, the legend locale
## contract — live in tools/test_chart.gd now; this section keeps the
## world-scene integration those cannot prove, on the shared §5 boot.)
func _test_chart_screen() -> void:
	# --- The reveal at 48 tiles shows up as a known-port dot on the chart ---
	# Valencia at Chebyshev 48 from the fleet is exactly the sighting boundary
	# (`20-*` §4.11, radius 48): the reveal knows it, so the chart must
	# draw its nation dot.
	_make_run(10, VALENCIA_D24)
	_check(not GameState.known_ports.has("valencia"),
		"fixture: valencia starts unknown")
	var world: Node = _ensure_shared_world()
	world.sync_from_state()
	_check(GameState.known_ports.has("valencia"),
		"the reveal at Chebyshev 48 discovers valencia (§4.11)")
	var chart = world.get_node_or_null("HUDLayer/ChartScreen")
	_check(chart != null, "world_map.tscn instances the Chart (S17) over S3")
	if chart == null:
		_shared_host.queue_free()
		_shared_host = null
		_shared_world = null
		return
	_check(not chart.is_open(), "the chart starts closed on S3")
	chart.open_chart()
	_check(chart.is_open(), "open_chart() shows the chart")
	var markers: Array = chart.port_markers()
	var marker_ids: Array = []
	for entry in markers:
		marker_ids.append(str(entry["port_id"]))
	_check(marker_ids.has("valencia"),
		"the port revealed at 24 tiles is a dot on the chart (got %s)"
		% str(marker_ids))
	_check(markers.size() == GameState.known_ports.size(),
		"the chart's known-port set is exactly the session's (chart %d, session %d)"
		% [markers.size(), GameState.known_ports.size()])
	# Nation colour, from the same shared layer the minimap uses.
	var valencia_dot: Dictionary = {}
	for entry in markers:
		if str(entry["port_id"]) == "valencia":
			valencia_dot = entry
	var valencia: Dictionary = DataLoader.get_port("valencia")
	var spain: Dictionary = DataLoader.get_nation(str(valencia["nation_id"]))
	_check(not valencia_dot.is_empty()
		and valencia_dot["color"] == PaletteLib.nation_color(str(spain["color"])),
		"valencia's chart dot uses Spain's nation color")
	_check((valencia_dot.get("cell", Vector2i(-1, -1)) as Vector2i) == VALENCIA_SHORE,
		"valencia's chart dot sits on its shore tile")
	_check((valencia_dot.get("berth_cell", Vector2i(-1, -1)) as Vector2i)
		== VALENCIA_HARBOR,
		"valencia's chart dot carries its berth tile")

	# --- One §4.3 round trip: the open chart is a modal over S3 ------------
	# (The chart-local Tab/Esc machine itself lives in test_chart now; this
	# keeps the world-scene consequences — the modal block, and a fleet/clock
	# the round trip never touches.)
	chart.close_chart()
	var cell_before: Vector2i = world.fleet_cell()
	var clock_before := float(GameState.world["clock_fraction"])
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	# The Tab toggle lives in ChartScreen._input since the focus-steal fix
	# (§4.3, amended 2026-11-01) — Tab above the GUI layer.
	chart._input(tab)
	_check(chart.is_open(), "`Tab` opens the chart from S3 (§4.3)")
	_check(world._modal_open(),
		"the open chart is a modal: the world scene's _modal_open() is true")
	var move := InputEventAction.new()
	move.action = "move_e"
	move.pressed = true
	world._unhandled_input(move)
	_check(world.fleet_cell() == cell_before,
		"movement is blocked while the chart is open (fleet %s)"
		% str(world.fleet_cell()))
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	chart._unhandled_input(esc)
	_check(not chart.is_open(), "`Esc` closes the chart (§4.3)")
	_check(not world._modal_open(), "closing the chart releases the modal block")
	_check(world.fleet_cell() == cell_before,
		"the fleet is unmoved by the chart round trip (%s)" % str(world.fleet_cell()))
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), clock_before),
		"the clock is untouched by the chart round trip (%.4f → %.4f)"
		% [clock_before, float(GameState.world["clock_fraction"])])

# --- 5d. Minimap/chart identity + discovery reveal at 18 ------------------

## The §J acceptance: explored tiles appear **identically** on the minimap and
## the chart, and a discovery revealed at Chebyshev 18 shows on the chart.
func _test_minimap_chart_identity() -> void:
	# disc_atlas_cedars sits at (2046,695); (2028,677) is exactly Chebyshev 18
	# away and is open water, so the Explore radius (§4.4) is exercised at its
	# boundary.
	var target: Vector2i = DiscoveryLib.position_of("disc_atlas_cedars")
	var at_18 := Vector2i(2028, 677)
	var at_19 := Vector2i(2009, 658)
	_check(target == Vector2i(2046, 695),
		"disc_atlas_cedars derives to (1023,347) (got %s)" % str(target))
	_check(maxi(absi(at_18.x - target.x), absi(at_18.y - target.y)) == 18,
		"the Explore fixture sits at exactly Chebyshev 18")
	_check(maxi(absi(at_19.x - target.x), absi(at_19.y - target.y)) == 37,
		"the control fixture sits at Chebyshev 37, outside the radius")
	_check(DataLoader.map.is_passable(at_18) and DataLoader.map.is_passable(at_19),
		"the discovery fixtures are open water")
	# Gate-audit trim 2026-11-02: all three phases ride the shared §5 world,
	# re-fixtured through `_make_run` + `sync_from_state()` (no fresh boots).
	_make_run(10, at_18)
	GameState.discoveries_found = []
	var world: Node = _ensure_shared_world()
	world.sync_from_state()
	_check(world.something_near(),
		"a discovery at exactly Chebyshev 18 is in Explore range (§4.4)")
	var found: Array = world.explore_here()
	_check(found.has("disc_atlas_cedars"),
		"Explore reveals the discovery at 18 tiles (got %s)" % str(found))
	_drain_dialogs(world.get_node("HUDLayer/HUD"))

	# Control: one tile further out (Chebyshev 19) nothing is in range.
	_make_run(10, at_19)
	GameState.discoveries_found = []
	world.sync_from_state()
	_check(not world.something_near(),
		"Chebyshev 37 is outside the 36-tile discovery radius")

	# Re-fixture at the boundary with the discovery found, for the chart checks.
	_make_run(10, at_18)
	GameState.discoveries_found = ["disc_atlas_cedars"]
	world.sync_from_state()

	var chart = world.get_node("HUDLayer/ChartScreen")
	chart.open_chart()
	var lead_ids: Array = []
	for entry in chart.lead_markers():
		lead_ids.append(str(entry["id"]))
	_check(lead_ids.has("disc_atlas_cedars"),
		"the discovery revealed at 18 tiles is a lead cross on the chart (got %s)"
		% str(lead_ids))
	var lead_cell := Vector2i(-1, -1)
	for entry in chart.lead_markers():
		if str(entry["id"]) == "disc_atlas_cedars":
			lead_cell = entry["cell"]
	_check(lead_cell == target,
		"the lead cross sits on the discovery's tile (%s)" % str(lead_cell))
	_check(chart.world_pixel_color(target) != PaletteLib.PANEL_BG,
		"the discovery's tile is explored, so the chart shows terrain there")

	# The chart's explored set == the session's, sampled across the map.
	var map = DataLoader.map
	var sampled := 0
	var mismatches: Array = []
	for raw_cell in GameState.explored_tiles:
		if not (raw_cell is Vector2i):
			continue
		var cell: Vector2i = raw_cell
		# The fate of every explored tile is a terrain colour on the chart.
		if chart.world_pixel_color(cell) == PaletteLib.PANEL_BG \
				and ChartViewLib.terrain_color(map.terrain_kind(cell)) != PaletteLib.PANEL_BG:
			mismatches.append(str(cell))
		sampled += 1
		if sampled >= 400:
			break
	_check(mismatches.is_empty(),
		"every sampled explored tile is painted on the chart (mismatches %s)"
		% str(mismatches.slice(0, 3)))
	# ... and an unexplored tile beyond the sighting square is fog on the chart.
	var unexplored := at_18 + Vector2i(CharacterLib.sighting_radius() + 2, 0)
	_check(not GameState.explored_tiles.has(unexplored),
		"the control tile is unexplored")
	_check(chart.world_pixel_color(unexplored) == PaletteLib.PANEL_BG,
		"an unexplored tile is PANEL_BG on the chart, never terrain")
	chart.close_chart()

	# --- Identity: the same explored tile has the same colour on both views --
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hud = HUDScene.instantiate()
	host.add_child(hud)
	hud.set_fleet_cell(at_18)
	# Gate-audit trim 2026-11-02: stride every 16th explored tile — the
	# identity contract is a sampled comparison over the crop, and every 16th
	# of the ~9.3k sighting square is ~580 two-pixel probes instead of one per
	# tile.
	var stride := 16
	var seen := 0
	var identical := 0
	var compared := 0
	var differences: Array = []
	for raw_cell in GameState.explored_tiles:
		if not (raw_cell is Vector2i):
			continue
		seen += 1
		if (seen - 1) % stride != 0:
			continue
		var cell: Vector2i = raw_cell
		if not hud.minimap_contains(cell):
			continue
		compared += 1
		var minimap_color: Color = hud.minimap_pixel_color(cell)
		var chart_color: Color = chart.world_pixel_color(cell)
		if minimap_color == chart_color:
			identical += 1
		elif differences.size() < 3:
			differences.append("%s: minimap %s vs chart %s"
				% [str(cell), str(minimap_color), str(chart_color)])
	_check(compared > 0,
		"the identity sample covers at least one explored tile in the crop (%d)"
		% compared)
	_check(identical == compared,
		"explored tiles are identical on minimap and chart (%d/%d; %s)"
		% [identical, compared, str(differences)])
	# Sanity: the shared colour source really is the palette, not a coincidence.
	_check(hud.minimap_pixel_color(at_18)
		== ChartViewLib.explored_color(ChartViewLib.palette_colors(DataLoader.map),
			DataLoader.map, at_18),
		"both views draw the shared ChartView explored colour for the fleet tile")
	# The minimap's known-port layer and the chart's are the same list.
	GameState.known_ports = ["lisbon", "valencia"]
	chart.open_chart()
	var minimap_ids: Array = []
	for entry in hud.minimap_known_ports():
		minimap_ids.append(str(entry["port_id"]))
	var chart_ids: Array = []
	for entry in chart.port_markers():
		chart_ids.append(str(entry["port_id"]))
	_check(minimap_ids == chart_ids,
		"minimap and chart draw the same known ports (%s vs %s)"
		% [str(minimap_ids), str(chart_ids)])
	chart.close_chart()
	host.queue_free()
	# The §5 shared world's last user was §5d: free it here.
	_shared_host.queue_free()
	_shared_host = null
	_shared_world = null


# --- 6. Desertion hook at port entry (§4.8.2) -----------------------------

func _test_desertion_hook() -> void:
	# morale < 40 → crew loss `max(1, floor(crew × 0.10 × multiplier))`.
	# (Gate-audit trim 2026-11-02: one boot carries §6 and §7 — each case
	# re-fixtures through `_make_run` + `sync_from_state()`.)
	_make_run(10, SEA_BESIDE_LISBON, 39)
	var crew_before: int = FleetLib.total_crew()
	var expected := maxi(1, int(floor(
		float(crew_before) * 0.10 * CharacterLib.desertion_multiplier()
	)))
	var spawned: Array = _spawn_world()
	var world = spawned[1]
	# §4.11 step 4: `port_entered` fires **after** the desertion is applied, so a
	# listener never sees the pre-desertion crew count.
	var seen_on_entered := [-1]
	var listener := func(_port_id: String) -> void:
		seen_on_entered[0] = FleetLib.total_crew()
	EventBus.port_entered.connect(listener)
	world._enter_port("lisbon")
	EventBus.port_entered.disconnect(listener)
	_check(seen_on_entered[0] == crew_before - expected,
		"port_entered fires after the desertion applied (crew seen %d, expected %d)"
		% [seen_on_entered[0], crew_before - expected])
	var hud = world.get_node("HUDLayer/HUD")
	var shown: Array[String] = _drain_dialogs(hud)
	_check(FleetLib.total_crew() == crew_before - expected,
		"morale 39: desertion costs %d crew (%d → %d)"
		% [expected, crew_before, FleetLib.total_crew()])
	_check(shown.size() == 2,
		"morale 39: desertion + greeting, two dialogs (got %d)" % shown.size())
	if shown.size() == 2:
		_check(shown[0] == I18n.fmt("world.desertion", {"count": expected}),
			"the desertion message reports the loss (%s)" % shown[0])
		_check(shown[1] == I18n.fmt("world.arrive", {
			"port": I18n.t(DataLoader.get_port("lisbon")["name"]),
			"day": GameState.day,
		}), "the arrival greeting reports port + day (%s)" % shown[1])

	# morale ≥ 40 → no desertion, greeting only. 40 is the exact boundary
	# (the doc's condition is `< 40`).
	for morale in [40, 70]:
		_make_run(10, SEA_BESIDE_LISBON, morale)
		world.sync_from_state()
		var before_crew: int = FleetLib.total_crew()
		world._enter_port("lisbon")
		var shown2: Array[String] = _drain_dialogs(world.get_node("HUDLayer/HUD"))
		_check(FleetLib.total_crew() == before_crew,
			"morale %d: no desertion (crew %d → %d)"
			% [morale, before_crew, FleetLib.total_crew()])
		_check(shown2.size() == 1 and shown2[0].begins_with("Arrived"),
			"morale %d: only the greeting is shown (got %s)" % [morale, str(shown2)])
	# The shared §6/§7 boot stays up for _test_dialog_order.


# --- 7. Dialog order at port entry (§4.7) --------------------------------

func _test_dialog_order() -> void:
	# §4.7 rank table: weather → sinking → mutiny → desertion → greeting.
	var entries: Array = [
		{"kind": "greeting", "key": "world.arrive", "values": {"port": "x", "day": 1}},
		{"kind": "desertion", "key": "world.desertion", "values": {"count": 1}},
		{"kind": "mutiny", "key": "world.mutiny.text", "values": {}},
		{"kind": "sinking", "key": "world.ship_lost", "values": {}},
		{"kind": "weather", "key": "world.storm_notice", "values": {"weather": "storm"}},
	]
	var ordered: Array = SailingSimLib.sort_dialogs(entries)
	var kinds: Array = []
	for entry in ordered:
		kinds.append(str(entry.get("kind", "")))
	_check(kinds == ["weather", "sinking", "mutiny", "desertion", "greeting"],
		"§4.7 dialog order is weather → sinking → mutiny → desertion → greeting (got %s)"
		% str(kinds))

	# The entry sequence, starting with a day-tick batch already queued: the
	# queued reports must be shown first, then desertion, then the greeting —
	# one modal at a time, never simultaneous.
	# (Gate-audit trim 2026-11-02: §6's live world, re-fixtured — no new boot.)
	_make_run(10, SEA_BESIDE_LISBON, 39)
	var world: Node = _ensure_shared_world()
	world.sync_from_state()
	var hud = world.get_node("HUDLayer/HUD")
	world._show_dialog_entries([
		{"kind": "weather", "key": "world.storm_notice",
			"values": {"weather": I18n.t_key("world.weather.storm")}},
		{"kind": "mutiny", "key": "world.mutiny.text", "values": {}},
	])
	world._enter_port("lisbon")

	var shown: Array[String] = []
	var visible_counts: Array[int] = []
	var guard := 0
	while hud.has_modal() and guard < 32:
		guard += 1
		var visible := 0
		for child in hud.get_node("ModalHost").get_children():
			if child.is_open():
				visible += 1
		visible_counts.append(visible)
		var dialog = hud.current_dialog()
		if dialog == null:
			break
		shown.append(dialog.message_text())
		dialog.close()
	_check(shown.size() == 4,
		"the entry chain shows 4 dialogs in sequence (got %d: %s)"
		% [shown.size(), str(shown)])
	if shown.size() == 4:
		_check(shown[0] == I18n.fmt("world.storm_notice",
			{"weather": I18n.t_key("world.weather.storm")}),
			"weather damage is first (%s)" % shown[0])
		_check(shown[1] == I18n.t_key("world.mutiny.text"),
			"mutiny follows the weather (§4.7) (%s)" % shown[1])
		_check(shown[2].begins_with("Low morale"),
			"desertion follows mutiny (%s)" % shown[2])
		_check(shown[3].begins_with("Arrived"),
			"the arrival greeting is last (%s)" % shown[3])
	var max_visible := 0
	for count in visible_counts:
		max_visible = maxi(max_visible, count)
	_check(max_visible == 1,
		"exactly one dialog is visible at a time, never simultaneous (max %d)"
		% max_visible)
	# The shared §6/§7 boot ends here.
	_shared_host.queue_free()
	_shared_host = null
	_shared_world = null


# --- Harness --------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	if description.is_empty():
		return
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
