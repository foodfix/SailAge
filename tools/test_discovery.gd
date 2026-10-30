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
## 5 minimap geometry/explored-only/nation dots, 6 desertion hook, 7 dialog
## order at entry.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const HUDScene := preload("res://scenes/ui_shared/hud.tscn")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")

const WORLD_SCENE := "res://scenes/world/world_map.tscn"
const PORT_SCENE := "res://scenes/port/port_screen.tscn"

## The six §4.11 new-game capitals.
const CAPITALS: Array[String] = [
	"amsterdam", "istanbul", "lisbon", "london", "seville", "venice",
]

## Open-water cell used for the minimap fixture (every neighbour is sea).
const OPEN_CELL := Vector2i(20, 20)
## Lisbon (7,57) and the sea tile beside it (8,57).
const LISBON := Vector2i(7, 57)
const SEA_BESIDE_LISBON := Vector2i(8, 57)

## Valencia (27,55) is not a capital, so it starts unknown. The cells below
## sit at exactly Chebyshev distance d from it along the NW diagonal; the pair
## (D23, D24) straddles the Phase-4 base radius 24 (`20-*` §4.11), and the
## four smaller ones remain the single-step fixtures below that.
const VALENCIA_D26 := Vector2i(1, 29)
const VALENCIA_D24 := Vector2i(3, 31)
const VALENCIA_D25 := Vector2i(2, 30)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/p1_mediterranean.txt", DataLoader.map_legend
	)
	_check(ok, "map loads for the discovery fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	if DataLoader.map != null:
		_check(DataLoader.map.port_cell("valencia") == Vector2i(27, 55),
			"valencia stands at its data position (got %s)"
			% str(DataLoader.map.port_cell("valencia")))
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
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": navigation, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": officers,
		"reputation": {"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
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
	# Phase-4 (`20-*` §4.11, `50-*` §4.2): radius = 24 + floor((navigation − 10)/10).
	_make_run(15)
	_check(CharacterLib.sighting_radius() == 24,
		"navigation 15 → sighting radius 24 (§4.2 formula; got %d)"
		% CharacterLib.sighting_radius())
	_make_run(10)
	_check(CharacterLib.sighting_radius() == 24,
		"navigation 10 → sighting radius 24 (got %d)" % CharacterLib.sighting_radius())
	_make_run(25)
	_check(CharacterLib.sighting_radius() == 25,
		"navigation 25 → sighting radius 25 (got %d)" % CharacterLib.sighting_radius())
	_make_run(30)
	_check(CharacterLib.sighting_radius() == 26,
		"navigation 30 → sighting radius 26 (got %d)" % CharacterLib.sighting_radius())
	# §5 worked example: Portugal (15) + navigator (+10) = 25 → 25.
	_make_run(15, OPEN_CELL, 70, ["off_mateus_alvares"])
	_check(CharacterLib.effective_stat("navigation") == 25,
		"navigator officer gives effective navigation 25 (got %d)"
		% CharacterLib.effective_stat("navigation"))
	_check(CharacterLib.sighting_radius() == 25,
		"Portugal + navigator → sighting radius 25 (§5 worked example, got %d)"
		% CharacterLib.sighting_radius())

	# Chebyshev boundary at the Phase-4 base: exactly `radius` reveals,
	# `radius + 1` does not.
	_check(_known_from(VALENCIA_D24, 10),
		"nav 10 (radius 24): a port at Chebyshev distance 24 is revealed")
	_check(not _known_from(VALENCIA_D25, 10),
		"nav 10 (radius 24): distance 25 is NOT revealed")
	# +1 navigation per 10 points shifts the boundary by one tile.
	_check(_known_from(VALENCIA_D25, 20),
		"nav 20 (radius 25): distance 25 is revealed")
	_check(not _known_from(VALENCIA_D26, 20),
		"nav 20 (radius 25): distance 26 is NOT revealed")
	# The officer path agrees with the raw stat at the same boundary: Portugal
	# (15) + navigator (+10) = 25 → radius 25, identical to a raw 25.
	_check(_known_from(VALENCIA_D25, 15, ["off_mateus_alvares"])
		and not _known_from(VALENCIA_D26, 15, ["off_mateus_alvares"]),
		"nav 15 + navigator (effective 25, radius 25): boundary at 25/26")


# --- 3. Discover-then-enter ----------------------------------------------

func _test_discover_then_enter() -> void:
	# Approach a NOT-yet-known harbor from beyond the sighting radius.
	_make_run(10, VALENCIA_D25)  # distance 25, radius 24
	var spawned: Array = _spawn_world()
	var world = spawned[1]
	_check(not GameState.known_ports.has("valencia"),
		"valencia is unknown from beyond the radius (distance 25, radius 24)")
	_check(not GameState.explored_tiles.has(Vector2i(27, 55)),
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
	spawned[0].queue_free()

	# Entering an *unknown* harbor tile discovers it and enters normally.
	_make_run(10, Vector2i(28, 54))  # directly NW of valencia's marker
	var spawned2: Array = _spawn_world()
	var world2 = spawned2[1]
	GameState.known_ports = []  # forget everything the ready reveal found
	var entered: Array = []
	var listener := func(port_id: String) -> void: entered.append(port_id)
	EventBus.port_entered.connect(listener)
	var clock_before := float(GameState.world["clock_fraction"])
	_check(not GameState.known_ports.has("valencia"),
		"valencia is unknown just before the entry step")
	var stepped: bool = world2.try_step(Vector2i(27, 55))
	EventBus.port_entered.disconnect(listener)
	_check(stepped, "stepping onto valencia's harbor tile succeeds (no error)")
	_check(entered == ["valencia"],
		"port_entered('valencia') fired exactly once (got %s)" % str(entered))
	_check(GameState.known_ports.has("valencia"),
		"entering an unknown port discovers it (§4.11)")
	_check(GameState.current_port == "valencia",
		"current_port is valencia after entry (got %s)" % str(GameState.current_port))
	# §4.2: the harbor tile's clock cost applied before docking.
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
		clock_before + SailingSimLib.move_cost()),
		"the harbor tile cost applies before docking (%.4f → %.4f)"
		% [clock_before, float(GameState.world["clock_fraction"])])
	_drain_dialogs(world2.get_node("HUDLayer/HUD"))
	spawned2[0].queue_free()

	# With routing enabled the entry targets S4; because this world instance is
	# a child (not the tree's current scene) the router must not swap the test's
	# root — docs/90-* §7 "no scene ever frees another".
	_make_run(10, Vector2i(28, 54))
	var spawned3: Array = _spawn_world(true)
	var world3 = spawned3[1]
	_check(world3.port_route_target() == "",
		"no route target before any entry")
	world3._enter_port("valencia")
	_check(world3.port_route_target() == PORT_SCENE,
		"with routing enabled the entry targets the port screen (got '%s')"
		% world3.port_route_target())
	_check(not world3.is_active_scene(),
		"a child-instanced world scene is not the active scene")
	_drain_dialogs(world3.get_node("HUDLayer/HUD"))
	_check(is_instance_valid(world3),
		"draining the queue does not swap the test's own scene root")
	spawned3[0].queue_free()


# --- 4. Set Sail round trip through the real scenes ----------------------

func _test_set_sail_round_trip() -> void:
	_make_run(10, SEA_BESIDE_LISBON)
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
	_check(world.fleet_cell() == SEA_BESIDE_LISBON,
		"world restores the fleet on the fixture tile (got %s)"
		% str(world.fleet_cell()))

	# Enter Lisbon through the real input path.
	var harbor := LISBON
	_check(world.try_step(harbor), "stepping onto Lisbon's harbor tile succeeds")
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
	_check((port.get_node("Layout/VBox/Header/TitleRow/PortName") as Label).text
		== I18n.t(lisbon["name"]),
		"port header shows the localized port name")
	_check((port.get_node("Layout/VBox/Header/TitleRow/NationName") as Label).text
		== I18n.t(nation["name"]),
		"port header shows the localized nation")
	_check((port.get_node("Layout/VBox/Header/Greeting") as Label).text
		== I18n.t(lisbon["flavor"]),
		"the greeting banner shows the port's flavor line")
	_check((port.get_node("Layout/VBox/Header/TitleRow/NationSwatch") as ColorRect).color
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
	var sail: Button = port.get_node("Layout/VBox/Footer/SetSail")
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
	_check(row.text == I18n.t_key("port.market"),
		"add_facility_row() binds port.market (%s)" % row.text)
	_check(row.custom_minimum_size == Vector2(240, PaletteLib.BUTTON_H),
		"facility rows use the 40px button height (§4.8)")
	_check(port.facility_container().get_child_count() == rows_before + 1,
		"the row lands in the facility container")
	row.pressed.emit()
	_check(requested.has("market"),
		"pressing the row reports the facility id (got %s)" % str(requested))
	_check(port.is_inside_tree() and tree.current_scene == port,
		"route_to_facility=false keeps the port screen in place")
	I18n.set_locale("zh")
	_check(row.text == I18n.t_key("port.market"),
		"facility rows rebind on locale_changed (%s)" % row.text)
	I18n.set_locale("en")
	row.queue_free()

	# Locale rebinding.
	I18n.set_locale("zh")
	_check((port.get_node("Layout/VBox/Header/Greeting") as Label).text
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

	# --- Esc = Set Sail (S4's back edge is S3, §4.3/§4.2) ------------------
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	port._unhandled_input(esc)
	await tree.process_frame
	await tree.process_frame

	var back = tree.current_scene
	_check(back != null and back.scene_file_path == WORLD_SCENE,
		"Esc (Set Sail) routes back to world_map.tscn (got %s)"
		% ("null" if back == null else back.scene_file_path))
	_check(GameState.world_tile() == harbor,
		"Set Sail leaves the fleet on the harbor tile (got %s)"
		% str(GameState.world_tile()))
	_check(float(GameState.world["clock_fraction"]) == 0.0,
		"Set Sail resets clock_fraction to exactly 0.0 (got %.10f)"
		% float(GameState.world["clock_fraction"]))
	_check(GameState.current_port == null,
		"Set Sail clears current_port (got %s)" % str(GameState.current_port))
	if back != null and back.scene_file_path == WORLD_SCENE:
		_check(back.fleet_cell() == harbor,
			"the returned world scene puts the marker on the harbor tile (got %s)"
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
	var name_label: Label = port.get_node("Layout/VBox/Header/TitleRow/PortName")
	_check(name_label.text == "-", "standalone: the port name is a placeholder (%s)"
		% name_label.text)
	var greeting: Label = port.get_node("Layout/VBox/Header/Greeting")
	_check(greeting.text == "", "standalone: the greeting banner is empty, not <key>")
	var day_greeting: Label = port.get_node("Layout/VBox/Header/DayGreeting")
	_check(not day_greeting.visible, "standalone: the day greeting row is hidden")
	var sail: Button = port.get_node("Layout/VBox/Footer/SetSail")
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


# --- 5. Minimap ----------------------------------------------------------
func _test_minimap() -> void:
	_make_run(10, OPEN_CELL)
	# The world scene owns exploration (§4.11/§4.12); spawn it first so the
	# explored set is populated exactly as it is at sea, then exercise the HUD
	# chart against that real set.
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

	# Geometry: 256×192 at 2 px/tile, `M` → 512×384 centered.
	_check(hud.minimap_rect().size == Vector2(256, 192),
		"minimap is 256×192 (got %s)" % str(hud.minimap_rect().size))
	_check(hud.minimap_px_per_tile() == 2,
		"minimap draws 2 px per tile (got %d)" % hud.minimap_px_per_tile())
	_check(hud.minimap_image_size() == Vector2i(256, 192),
		"the chart image is 128×96 tiles × 2 px (got %s)"
		% str(hud.minimap_image_size()))
	_check(hud.minimap_rect().position == Vector2(
		PaletteLib.MARGIN, PaletteLib.TOP_BAR_H + PaletteLib.MARGIN),
		"minimap sits under the top bar at the 16px margin (got %s)"
		% str(hud.minimap_rect().position))
	hud.toggle_minimap()
	_check(hud.minimap_rect().size == Vector2(512, 384),
		"`M` enlarges the chart to 512×384 (got %s)" % str(hud.minimap_rect().size))
	_check(hud.minimap_rect().position == Vector2(384, 168),
		"the enlarged chart is centered in 1280×720 (got %s)"
		% str(hud.minimap_rect().position))
	_check(hud.is_minimap_enlarged(), "is_minimap_enlarged() follows the toggle")

	# Enlarged mode is a modal overlay: movement must not step the fleet behind
	# it (docs/80-* §4.3, §6 "modals consume all input"). The world scene's own
	# HUD is the one movement consults.
	var world_hud = world.get_node("HUDLayer/HUD")
	world_hud.toggle_minimap()
	var cell_before: Vector2i = world.fleet_cell()
	var move := InputEventAction.new()
	move.action = "move_e"
	move.pressed = true
	world._unhandled_input(move)
	_check(world.fleet_cell() == cell_before,
		"movement is blocked while the enlarged chart is open (got %s)"
		% str(world.fleet_cell()))
	world_hud.toggle_minimap()
	_check(not world_hud.is_minimap_enlarged(), "the world's chart closes again")

	# `Esc` closes the enlarged chart (docs/80-* §4.3).
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	hud._unhandled_input(esc)
	_check(not hud.is_minimap_enlarged(),
		"Esc closes the enlarged chart (got enlarged=%s)"
		% str(hud.is_minimap_enlarged()))
	_check(hud.minimap_rect().size == Vector2(256, 192),
		"closing restores 256×192 (got %s)" % str(hud.minimap_rect().size))

	# `M` toggles it too, through the HUD's own input path.
	var m_key := InputEventAction.new()
	m_key.action = "toggle_minimap"
	m_key.pressed = true
	hud._unhandled_input(m_key)
	_check(hud.is_minimap_enlarged(), "`M` re-opens the enlarged chart")
	hud._unhandled_input(m_key)
	_check(not hud.is_minimap_enlarged(), "`M` closes it again")

	# Explored-only: the fleet tile is painted, a far tile stays fog.
	_check(hud.minimap_pixel_color(OPEN_CELL)
		== PaletteLib.SEA,
		"an explored sea tile is painted SEA (got %s)"
		% str(hud.minimap_pixel_color(OPEN_CELL)))
	var radius: int = CharacterLib.sighting_radius()
	_check(not GameState.explored_tiles.has(OPEN_CELL + Vector2i(radius + 1, 0)),
		"a tile beyond the sighting radius is not explored")
	_check(hud.minimap_pixel_color(OPEN_CELL + Vector2i(radius + 1, 0))
		== PaletteLib.PANEL_BG,
		"an unexplored tile stays panel background (got %s)"
		% str(hud.minimap_pixel_color(OPEN_CELL + Vector2i(radius + 1, 0))))
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

	# Growth on movement; far tiles stay unexplored.
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
		"the chart follows the fleet onto the new tile")

	# Known-port dots: nation colors, known ports only.
	GameState.known_ports = ["lisbon", "valencia"]
	var dots: Array = hud.minimap_known_ports()
	_check(dots.size() == 2,
		"the chart draws one dot per known port (got %d)" % dots.size())
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
		_check((by_id["lisbon"]["cell"] as Vector2i) == LISBON,
			"lisbon's dot sits on its harbor tile (got %s)"
			% str(by_id["lisbon"]["cell"]))
	if by_id.has("valencia"):
		var valencia: Dictionary = DataLoader.get_port("valencia")
		var nation2: Dictionary = DataLoader.get_nation(str(valencia["nation_id"]))
		_check(by_id["valencia"]["color"]
			== PaletteLib.nation_color(str(nation2["color"])),
			"valencia's dot uses Spain's nation color (got %s)"
			% str(by_id["valencia"]["color"]))
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

	spawned[0].queue_free()
	host.queue_free()


# --- 6. Desertion hook at port entry (§4.8.2) -----------------------------

func _test_desertion_hook() -> void:
	# morale < 40 → crew loss `max(1, floor(crew × 0.10 × multiplier))`.
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
	spawned[0].queue_free()

	# morale ≥ 40 → no desertion, greeting only. 40 is the exact boundary
	# (the doc's condition is `< 40`).
	for morale in [40, 70]:
		_make_run(10, SEA_BESIDE_LISBON, morale)
		var before_crew: int = FleetLib.total_crew()
		var spawned2: Array = _spawn_world()
		var world2 = spawned2[1]
		world2._enter_port("lisbon")
		var shown2: Array[String] = _drain_dialogs(world2.get_node("HUDLayer/HUD"))
		_check(FleetLib.total_crew() == before_crew,
			"morale %d: no desertion (crew %d → %d)"
			% [morale, before_crew, FleetLib.total_crew()])
		_check(shown2.size() == 1 and shown2[0].begins_with("Arrived"),
			"morale %d: only the greeting is shown (got %s)" % [morale, str(shown2)])
		spawned2[0].queue_free()


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
	_make_run(10, SEA_BESIDE_LISBON, 39)
	var spawned: Array = _spawn_world()
	var world = spawned[1]
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
	spawned[0].queue_free()


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
