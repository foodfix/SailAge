extends Node
## T11 acceptance tests (docs/IMPLEMENT-Phase1.md T11; docs/30-* §4.1, §4.7;
## docs/80-* §4.2, §4.3, §4.5, §4.8; docs/10-* §4.4).
## Headless scene test:
##
##   godot --headless res://tools/test_port_hub.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections
##   1 row order + content per port class: Lisbon (capital, palace) → 6 rows,
##     Ceuta (non-capital) → 5 rows, guild always a disabled stub;
##   2 data-driven proof: removing "inn" from a copy of the port's facilities
##     drops the row, adding "palace" to a non-capital adds it — no code edit;
##   3 enable/disable: market/shipyard/tavern/inn enabled, guild/palace
##     disabled with the `port.stub.phase3` label;
##   4 routing: all four Phase-1 facilities route to their scene, Esc from each
##     returns to port_screen.tscn;
##   5 stub rows do not route (clicking guild/palace changes nothing);
##   6 locale rebind: every row label switches zh↔en with no `<key>` anywhere;
##   7 the T10 shell survives: greeting banner, Set Sail, standalone load.

const PortScene := preload("res://scenes/port/port_screen.tscn")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
const WORLD_SCENE := "res://scenes/world/world_map.tscn"

## The §4.1 fixed order (the six facility ids, wireframe order).
const FIXED_ORDER: Array[String] = [
	"market", "shipyard", "tavern", "inn", "guild", "palace",
]
## The four Phase-1 facilities whose rows must be clickable.
const P1_FACILITIES: Array[String] = ["market", "shipyard", "tavern", "inn"]
## Phase-3 facilities: always disabled stubs when present.
const P3_FACILITIES: Array[String] = ["guild", "palace"]
## Facility id → expected screen (docs/30-* §4.7, docs/80-* §4.1).
const FACILITY_SCENES := {
	"market": "res://scenes/port/market_screen.tscn",
	"shipyard": "res://scenes/port/shipyard_screen.tscn",
	"tavern": "res://scenes/port/tavern_screen.tscn",
	"inn": "res://scenes/port/inn_screen.tscn",
}
## Lisbon's harbor tile (docs/10-* §7.1).
const LISBON_TILE := Vector2i(7, 57)
## Ceuta's harbor tile (docs/10-* §7.1), a non-capital port.
const CEUTA_TILE := Vector2i(2, 63)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	await _test_row_order_lisbon()
	await _test_row_order_ceuta()
	await _test_guild_always_present()
	await _test_data_driven()
	await _test_enable_disable()
	await _test_locale_rebind()
	_test_facility_scene_table()
	await _test_routing_all_four()
	await _test_stub_rows_do_not_route()
	await _test_shell_intact()
	await _test_standalone()
	_report()


# --- Fixtures --------------------------------------------------------------

## A docked run at `port_id` on that port's harbor tile, with a purse big
## enough that no facility row can be disabled for want of gold.
func _make_run(port_id: String = "lisbon", tile: Vector2i = LISBON_TILE) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.gold = 7830
	GameState.day = 12
	GameState.morale = 70
	GameState.fleet = [FleetLib.new_ship("caravel", 15)]
	var flagship: Dictionary = GameState.fleet[0]
	flagship["provisions"] = 200
	flagship["water"] = 200
	GameState.current_port = port_id
	GameState.world = {
		"position": {"x": tile.x, "y": tile.y}, "clock_fraction": 0.0,
	}
	GameState.known_ports = [port_id]
	GameState.locale = "en"


## Mounts the hub under a Control host with routing off (repo gotcha 6). The
## returned hub is the real scene, ready and bound.
func _mount_hub(host: Control):
	var hub = PortScene.instantiate()
	hub.route_to_facility = false
	hub.route_to_world = false
	host.add_child(hub)
	return hub


## Row ids, in display order, from the actual row buttons (not the hub's own
## cache) so the assertion is about what is on screen. The wireframe pairs the
## open facilities inside HBoxContainers, so the walk is recursive.
func _row_ids(hub) -> Array:
	var ids: Array = []
	for button in hub.facility_buttons():
		ids.append(str(button.get_meta("facility_id")))
	return ids


## The direct children of the row container: Buttons (stubs, one per line) and
## HBoxContainers (wireframe pairs of open facilities).
func _row_lines(hub) -> Array:
	var lines: Array = []
	for child in hub.facility_container().get_children():
		if child is Button and child.has_meta("facility_id"):
			lines.append([str(child.get_meta("facility_id"))])
		elif child is HBoxContainer:
			var ids: Array = []
			for grandchild in child.get_children():
				if grandchild is Button and grandchild.has_meta("facility_id"):
					ids.append(str(grandchild.get_meta("facility_id")))
			lines.append(ids)
	return lines


# --- 1. Row order and content per port class -------------------------------

func _test_row_order_lisbon() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	var hub = _mount_hub(host)
	await get_tree().process_frame

	# Lisbon is Portugal's capital → palace is in its data.
	var lisbon: Dictionary = DataLoader.get_port("lisbon")
	_check((lisbon.get("facilities", {}) as Dictionary).has("palace"),
		"fixture: Lisbon's facilities include palace (capital)")
	_check((lisbon.get("facilities", {}) as Dictionary).has("guild"),
		"fixture: Lisbon's facilities include guild")

	var ids := _row_ids(hub)
	_check(ids == FIXED_ORDER,
		"Lisbon renders 6 rows in the §4.1 order (got %s)" % str(ids))
	_check(ids.size() == 6, "Lisbon has exactly 6 facility rows (got %d)"
		% ids.size())
	_check(hub.facility_row_ids() == FIXED_ORDER,
		"facility_row_ids() reports the same order (%s)"
		% str(hub.facility_row_ids()))
	# Set Sail follows the rows (the wireframe's last row).
	var sail: Button = hub.get_node("Layout/VBox/Footer/SetSail")
	_check(sail != null and not sail.disabled,
		"Set Sail is present and enabled below the rows")
	# Wireframe layout: [Market][Shipyard] / [Tavern][Inn], then one line per
	# stub (docs/30-* §4.7).
	var lines := _row_lines(hub)
	_check(lines == [["market", "shipyard"], ["tavern", "inn"],
			["guild"], ["palace"]],
		"Lisbon lays the rows out as the §4.7 wireframe (got %s)" % str(lines))
	# Every row is a 40px button (docs/80-* §4.8).
	for id in ids:
		var row: Button = hub.facility_row(id)
		_check(row != null and row.custom_minimum_size.y == 40.0,
			"row '%s' uses the 40px button height (§4.8)" % id)

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


func _test_row_order_ceuta() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("ceuta", CEUTA_TILE)
	var hub = _mount_hub(host)
	await get_tree().process_frame

	# Ceuta is not a capital → its data omits palace entirely.
	var ceuta: Dictionary = DataLoader.get_port("ceuta")
	_check(not (ceuta.get("facilities", {}) as Dictionary).has("palace"),
		"fixture: Ceuta's facilities omit palace (non-capital)")

	var ids := _row_ids(hub)
	_check(ids == ["market", "shipyard", "tavern", "inn", "guild"],
		"Ceuta renders 5 rows, no palace, same order (got %s)" % str(ids))
	_check(not ids.has("palace"), "Ceuta has no palace row")
	_check(hub.facility_row("palace") == null,
		"facility_row('palace') is null where the port omits it")
	_check(hub.facility_row("guild") != null,
		"Ceuta still shows the guild row (phase 3 stub)")

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


## Guild is phase 3 in every port's data (docs/10-* §4.4), so its disabled stub
## row must appear everywhere — the row is never absent and never enabled.
func _test_guild_always_present() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var ports_with_guild := 0
	var checked := 0
	for port_record in DataLoader.ports_list:
		var port_id := str(port_record.get("id", ""))
		var facilities = port_record.get("facilities", {})
		if not facilities is Dictionary or not (facilities as Dictionary).has("guild"):
			continue
		ports_with_guild += 1
		# Spot-check a representative few in the scene (instantiating 30 hubs
		# is slow); the data-driven assertion below covers the rest.
		if checked >= 3:
			continue
		checked += 1
		GameState.current_port = port_id
		GameState.world = {"position": {"x": LISBON_TILE.x, "y": LISBON_TILE.y},
			"clock_fraction": 0.0}
		var hub = _mount_hub(host)
		await get_tree().process_frame
		var guild: Button = hub.facility_row("guild")
		_check(guild != null, "%s: the guild row exists" % port_id)
		_check(not hub.is_facility_enabled("guild"),
			"%s: guild is a disabled stub (phase 3)" % port_id)
		hub.queue_free()
		await get_tree().process_frame
	_check(ports_with_guild == DataLoader.ports_list.size(),
		"every port's data lists guild (phase 3) — %d/%d"
		% [ports_with_guild, DataLoader.ports_list.size()])

	host.queue_free()
	await get_tree().process_frame


# --- 2. Data-driven proof --------------------------------------------------

## Mutates a COPY of the port record in DataLoader's table (never data/ on
## disk): the hub must follow the data with no code change. Restored at the end.
func _test_data_driven() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("ceuta", CEUTA_TILE)

	var original: Dictionary = DataLoader.ports["ceuta"].duplicate(true)
	var hub = _mount_hub(host)
	await get_tree().process_frame
	_check(_row_ids(hub) == ["market", "shipyard", "tavern", "inn", "guild"],
		"before the edit: Ceuta renders 5 rows (got %s)" % str(_row_ids(hub)))

	# (a) Remove "inn" from the copy's facilities → its row disappears.
	var facilities: Dictionary = DataLoader.ports["ceuta"]["facilities"]
	facilities.erase("inn")
	hub._bind()
	await get_tree().process_frame
	_check(not _row_ids(hub).has("inn"),
		"removing 'inn' from the port data drops the row (got %s)"
		% str(_row_ids(hub)))
	_check(_row_ids(hub) == ["market", "shipyard", "tavern", "guild"],
		"the remaining rows keep the fixed order (got %s)" % str(_row_ids(hub)))

	# (b) Add "palace" to a non-capital → its row appears.
	facilities["palace"] = 3
	hub._bind()
	await get_tree().process_frame
	_check(_row_ids(hub).has("palace"),
		"adding 'palace' to a non-capital adds the row (got %s)"
		% str(_row_ids(hub)))
	_check(_row_ids(hub) == ["market", "shipyard", "tavern", "guild", "palace"],
		"the added row lands in the fixed order (got %s)" % str(_row_ids(hub)))
	_check(not hub.is_facility_enabled("palace"),
		"the added palace row is a disabled stub (phase 3)")

	# (c) Promote an existing facility to phase 1 → it becomes clickable.
	facilities["guild"] = 1
	hub._bind()
	await get_tree().process_frame
	_check(hub.is_facility_enabled("guild"),
		"a phase-1 guild in the data makes the row clickable")

	# (d) An unknown facility key never invents a row (fixed order only).
	facilities["casino"] = 1
	hub._bind()
	await get_tree().process_frame
	_check(not _row_ids(hub).has("casino"),
		"an unknown facility key adds no row (got %s)" % str(_row_ids(hub)))

	# Restore the data and prove the hub follows back.
	DataLoader.ports["ceuta"] = original
	hub._bind()
	await get_tree().process_frame
	_check(_row_ids(hub) == ["market", "shipyard", "tavern", "inn", "guild"],
		"restoring the data restores the original rows (got %s)"
		% str(_row_ids(hub)))

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 3. Enable / disable ---------------------------------------------------

func _test_enable_disable() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	var hub = _mount_hub(host)
	await get_tree().process_frame

	for id in P1_FACILITIES:
		var row: Button = hub.facility_row(id)
		_check(row != null and not row.disabled,
			"P1 facility '%s' is enabled" % id)
		_check(row != null and row.text == I18n.t_key("port.%s" % id),
			"'%s' shows its noun, no stub note (%s)"
			% [id, "" if row == null else row.text])

	for id in P3_FACILITIES:
		var row: Button = hub.facility_row(id)
		_check(row != null and row.disabled,
			"phase-3 facility '%s' is a disabled stub" % id)
		var expected := "%s — %s" % [
			I18n.t_key("port.%s" % id), I18n.t_key("port.stub.phase3"),
		]
		_check(row != null and row.text == expected,
			"'%s' carries the port.stub.phase3 label (%s)"
			% [id, "" if row == null else row.text])
		_check(row != null and row.text.contains(I18n.t_key("port.stub.phase3")),
			"'%s' text contains the stub key's translation" % id)
		_check(row != null and row.tooltip_text == I18n.t_key("port.stub.phase3"),
			"'%s' tooltip repeats the stub reason" % id)

	_check(hub.is_facility_enabled("market"), "is_facility_enabled(market)")
	_check(not hub.is_facility_enabled("palace"),
		"is_facility_enabled(palace) is false")

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 4. Routing ------------------------------------------------------------

func _test_facility_scene_table() -> void:
	var hub = PortScene.instantiate()
	for id in P1_FACILITIES:
		_check(str(hub.FACILITY_SCENES.get(id, "")) == FACILITY_SCENES[id],
			"FACILITY_SCENES[%s] == %s (got '%s')"
			% [id, FACILITY_SCENES[id], str(hub.FACILITY_SCENES.get(id, ""))])
		_check(ResourceLoader.exists(FACILITY_SCENES[id]),
			"the %s screen exists on disk" % id)
	hub.free()


## One real scene swap per Phase-1 facility: the row click routes to its screen,
## and Esc from that screen returns to the port hub (docs/80-* §4.2).
func _test_routing_all_four() -> void:
	for id in P1_FACILITIES:
		_make_run("lisbon", LISBON_TILE)
		var tree := get_tree()
		tree.current_scene = null
		tree.change_scene_to_file(PORT_SCENE)
		await tree.process_frame
		await tree.process_frame
		var hub = tree.current_scene
		_check(hub != null and hub.scene_file_path == PORT_SCENE,
			"%s: the port hub is the active scene (got %s)"
			% [id, "null" if hub == null else hub.scene_file_path])
		if hub == null or hub.scene_file_path != PORT_SCENE:
			continue

		var requested: Array = []
		hub.facility_requested.connect(func(fid: String) -> void:
			requested.append(fid))
		var row: Button = hub.facility_row(id)
		_check(row != null, "%s: the enabled row exists to click" % id)
		if row == null:
			continue
		row.pressed.emit()
		await tree.process_frame
		await tree.process_frame
		var screen = tree.current_scene
		_check(screen != null and screen.scene_file_path == FACILITY_SCENES[id],
			"clicking '%s' routes to %s (got %s)"
			% [id, FACILITY_SCENES[id],
				"null" if screen == null else screen.scene_file_path])
		_check(requested == [id],
			"'%s' emits facility_requested(%s) once (got %s)"
			% [id, id, str(requested)])
		if screen == null or screen.scene_file_path != FACILITY_SCENES[id]:
			continue

		# Esc from the facility screen = one edge back to S4.
		var esc := InputEventAction.new()
		esc.action = "back"
		esc.pressed = true
		screen._unhandled_input(esc)
		await tree.process_frame
		await tree.process_frame
		var back = tree.current_scene
		_check(back != null and back.scene_file_path == PORT_SCENE,
			"Esc from %s returns to port_screen.tscn (got %s)"
			% [id, "null" if back == null else back.scene_file_path])
		if back != null and back.scene_file_path == PORT_SCENE:
			_check(back.port_id() == "lisbon" and
				back.facility_row("market") != null,
				"the returned hub re-binds Lisbon and its rows")

	# Leave the tree clean for the remaining (non-routing) sections.
	var tree := get_tree()
	if tree.current_scene != null:
		tree.current_scene.queue_free()
		tree.current_scene = null
	await tree.process_frame


# --- 5. Stub rows do not route --------------------------------------------

func _test_stub_rows_do_not_route() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	var hub = _mount_hub(host)
	await get_tree().process_frame

	var requested: Array = []
	hub.facility_requested.connect(func(fid: String) -> void:
		requested.append(fid))

	for id in P3_FACILITIES:
		var row: Button = hub.facility_row(id)
		_check(row != null and row.disabled, "%s stub row is disabled" % id)
		# A disabled Button does not emit `pressed` even if the signal is
		# emitted directly; emitting it anyway proves nothing routes.
		row.pressed.emit()
		await get_tree().process_frame
		_check(requested.is_empty() or not requested.has(id),
			"clicking the %s stub requests nothing (got %s)"
			% [id, str(requested)])
		_check(hub.is_inside_tree() and get_tree().current_scene != hub,
			"the %s stub click does not swap the scene" % id)

	# The direct API is the second guard: open_facility() refuses phase 3 and
	# does not report success, even with routing off.
	_check(hub.open_facility("guild") == false,
		"open_facility('guild') returns false (phase 3)")
	_check(hub.open_facility("palace") == false,
		"open_facility('palace') returns false (phase 3)")
	# And a facility this port does not offer.
	_make_run("ceuta", CEUTA_TILE)
	hub._bind()
	_check(hub.open_facility("palace") == false,
		"open_facility('palace') is false where the data omits palace")

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 6. Locale rebind ------------------------------------------------------

func _test_locale_rebind() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	GameState.locale = "en"
	var hub = _mount_hub(host)
	await get_tree().process_frame

	var english: Dictionary = {}
	for id in FIXED_ORDER:
		var row: Button = hub.facility_row(id)
		english[id] = "" if row == null else row.text

	I18n.set_locale("zh")
	await get_tree().process_frame
	for id in FIXED_ORDER:
		var row: Button = hub.facility_row(id)
		_check(row != null and row.text != english[id],
			"zh rebinds the '%s' row (%s)" % [id, "" if row == null else row.text])
		_check(row != null and row.text == "%s%s" % [
			I18n.t_key("port.%s" % id),
			"" if id in P1_FACILITIES else " — " + I18n.t_key("port.stub.phase3"),
		], "zh '%s' row uses the zh keys (%s)"
			% [id, "" if row == null else row.text])

	# No row may ever render a raw key (docs/80-* §6), and every row is localised
	# in zh.
	for button in hub.facility_buttons():
		var text := (button as Button).text
		_check(not text.begins_with("<") and not text.contains("<port."),
			"row text is localised, not a raw key (%s)" % text)
		_check(not (button as Button).text.is_empty(),
			"row text is non-empty in zh (%s)" % text)

	# The header, greeting and Set Sail rebind with the rows.
	var greeting: Label = hub.get_node("Layout/VBox/Header/Greeting")
	var lisbon: Dictionary = DataLoader.get_port("lisbon")
	_check(greeting.text == I18n.t(lisbon["flavor"]),
		"the greeting banner rebinds to zh (%s)" % greeting.text)
	var sail: Button = hub.get_node("Layout/VBox/Footer/SetSail")
	_check(sail.text == I18n.t_key("port.set_sail"),
		"Set Sail rebinds to zh (%s)" % sail.text)

	# Back to en restores every label exactly.
	I18n.set_locale("en")
	await get_tree().process_frame
	for id in FIXED_ORDER:
		var row: Button = hub.facility_row(id)
		_check(row != null and row.text == english[id],
			"en restores the '%s' row (%s)" % [id, "" if row == null else row.text])

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 7. The shell ----------------------------------------------------------

func _test_shell_intact() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	var hub = _mount_hub(host)
	await get_tree().process_frame

	var lisbon: Dictionary = DataLoader.get_port("lisbon")
	var nation: Dictionary = DataLoader.get_nation("portugal")
	_check((hub.get_node("Layout/VBox/Header/TitleRow/PortName") as Label).text
		== I18n.t(lisbon["name"]), "the header still shows the port name")
	_check((hub.get_node("Layout/VBox/Header/TitleRow/NationName") as Label).text
		== I18n.t(nation["name"]), "the header still shows the nation")
	_check((hub.get_node("Layout/VBox/Header/Greeting") as Label).text
		== I18n.t(lisbon["flavor"]), "the flavor greeting banner is kept")
	var hud = hub.get_node_or_null("HUD")
	_check(hud != null and not hud.is_minimap_visible(),
		"S4 keeps the shared HUD with the minimap hidden (§4.5)")
	var heading: Label = hub.get_node("Layout/VBox/Facilities/Heading")
	_check(heading.text == I18n.t_key("port.facilities"),
		"the facilities heading uses port.facilities (%s)" % heading.text)

	# Set Sail still runs the S4 → S3 transition (routing off, state change on).
	var sailed: Array = []
	hub.sailed.connect(func() -> void: sailed.append(true))
	var sail: Button = hub.get_node("Layout/VBox/Footer/SetSail")
	_check(hub.set_sail(), "set_sail() succeeds while docked")
	_check(sailed.size() == 1, "set_sail() emits sailed")
	_check(GameState.current_port == null, "set_sail() clears current_port")
	_check(float(GameState.world["clock_fraction"]) == 0.0,
		"set_sail() resets clock_fraction to 0.0")

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


## Standalone (editor load, no run): no rows, no crash, Set Sail disabled.
func _test_standalone() -> void:
	GameState.player = {}
	GameState.fleet = []
	GameState.current_port = null
	GameState.world = {}
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hub = _mount_hub(host)
	await get_tree().process_frame

	_check(hub.port_id() == "", "standalone: port_id() is empty")
	_check(hub.facility_container().get_child_count() == 0,
		"standalone: no facility rows (nothing is docked)")
	_check(hub.facility_row_ids().is_empty(),
		"standalone: facility_row_ids() is empty")
	_check(hub.facility_row("market") == null,
		"standalone: facility_row('market') is null")
	_check(hub.open_facility("market") == false,
		"standalone: open_facility('market') is false")
	var sail: Button = hub.get_node("Layout/VBox/Footer/SetSail")
	_check(sail.disabled, "standalone: Set Sail is disabled")
	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- Harness ---------------------------------------------------------------

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
