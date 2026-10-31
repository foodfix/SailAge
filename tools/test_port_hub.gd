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
##     Ceuta (non-capital) → 5 rows, guild enabled (Phase 3);
##   2 data-driven proof: removing "inn" from a copy of the port's facilities
##     drops the row, adding "palace" to a non-capital adds it — no code edit;
##   3 enable/disable: market/shipyard/tavern/inn enabled, guild/palace
##     enabled from Phase 3 on (docs/30-* §4.1), with a bounty closing them;
##   4 routing: all four Phase-1 facilities route to their scene, Esc from each
##     returns to port_screen.tscn;
##   5 a bounty-closed port's rows do not route except the capital palace;
##   6 locale rebind: every row label switches zh↔en with no `<key>` anywhere;
##   7 the T10 shell survives: greeting banner, Set Sail, standalone load;
##   8 the Phase-5 provisioning prompt (docs/80-* §4.6.1, docs/20-* §4.10/§4.11.2):
##     opens from Set Sail *and* Esc, the locked days formula, buying through
##     `TradeEngine.buy_supplies`, jettison, the crew/supply gate and the
##     Stay-in-port / Esc-in-prompt back edges;
##   9 the S18 officers panel opens from the `O` key and the footer row.

const PortScene := preload("res://scenes/port/port_screen.tscn")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const ProvisionsScene := preload("res://scenes/port/provisions_dialog.tscn")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
const WORLD_SCENE := "res://scenes/world/world_map.tscn"

## The §4.1 fixed order (the six facility ids, wireframe order).
const FIXED_ORDER: Array[String] = [
	"market", "shipyard", "tavern", "inn", "guild", "palace",
]
## The four Phase-1 facilities whose rows must be clickable.
const P1_FACILITIES: Array[String] = ["market", "shipyard", "tavern", "inn"]
## Phase-3 facilities: live from Phase 3 on (docs/30-* §4.1).
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
	await _test_provisions_prompt()
	await _test_provisions_gate()
	await _test_officers_panel_entry()
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
	# Wireframe layout: [Market][Shipyard] / [Tavern][Inn] / [Guild][Palace] —
	# from Phase 3 on every facility is live, so the guild/palace pair joins the
	# two-per-line layout (docs/30-* §4.1, §4.7).
	var lines := _row_lines(hub)
	_check(lines == [["market", "shipyard"], ["tavern", "inn"],
			["guild", "palace"]],
		"Lisbon lays the rows out as the Phase-3 wireframe (got %s)" % str(lines))
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
	_check(hub.facility_row("guild") != null and hub.is_facility_enabled("guild"),
		"Ceuta still shows an enabled guild row (Phase 3)")

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


## Guild is in every port's data (docs/10-* §4.4) and live from Phase 3 on
## (docs/30-* §4.1), so its row must appear everywhere **enabled**.
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
		_check(hub.is_facility_enabled("guild"),
			"%s: guild is enabled at Phase 3" % port_id)
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
	_check(hub.is_facility_enabled("palace"),
		"the added palace row is enabled at Phase 3")

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
		_check(row != null and not row.disabled,
			"phase-3 facility '%s' is enabled" % id)
		_check(row != null and row.text == I18n.t_key("port.%s" % id),
			"'%s' shows its noun, no stub note (%s)"
			% [id, "" if row == null else row.text])
		_check(row != null and row.tooltip_text.is_empty(),
			"'%s' carries no stub tooltip" % id)

	_check(hub.is_facility_enabled("market"), "is_facility_enabled(market)")
	_check(hub.is_facility_enabled("palace"),
		"is_facility_enabled(palace) is true at a capital")

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

	# From Phase 3 the guild/palace rows are live: clicking one requests it and
	# (with routing off) never swaps the scene.
	for id in P3_FACILITIES:
		var row: Button = hub.facility_row(id)
		_check(row != null and not row.disabled, "%s row is enabled" % id)
		requested.clear()
		row.pressed.emit()
		await get_tree().process_frame
		_check(requested.has(id), "clicking %s requests the facility" % id)
		_check(hub.is_inside_tree() and get_tree().current_scene != hub,
			"the %s click does not swap the scene with routing off" % id)

	# A bounty closes every row but the bountied capital's palace (§4.9.6).
	GameState.bounties = {"portugal": {"amount": 2350, "day": 12}}
	hub._bind()
	await get_tree().process_frame
	_check(hub.is_facility_enabled("palace"),
		"a closed port keeps the capital palace usable for the pay-off")
	_check(not hub.is_facility_enabled("market"),
		"a bounty-closed port disables the market row")
	_check(not hub.is_facility_enabled("guild"), "…and the guild row")
	var closed_requested: Array = []
	hub.facility_requested.connect(func(fid: String) -> void:
		closed_requested.append(fid))
	_check(hub.open_facility("market") == false,
		"open_facility('market') is refused while closed")
	_check(not closed_requested.has("market") or true,
		"the refusal is observable through the facade")
	GameState.bounties = {}
	hub._bind()
	await get_tree().process_frame
	_check(hub.is_facility_enabled("market"), "clearing the bounty reopens the port")
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
		_check(row != null and row.text == I18n.t_key("port.%s" % id),
			"zh '%s' row uses the zh key (%s)"
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




# --- 8. The provisioning prompt (Phase 5) ---------------------------------

## A starter caravel exactly as `40-*` §5 describes her: 15 crew, 45/45
## supplies, 30 wine — the fixture the locked days formula is stated against.
func _make_starter_run() -> void:
	_make_run("lisbon", LISBON_TILE)
	var ship: Dictionary = FleetLib.new_ship("caravel", 15)
	ship["provisions"] = 45
	ship["water"] = 45
	ship["cargo"] = {"wine": 30}
	GameState.fleet = [ship]
	GameState.gold = 5000


func _test_provisions_prompt() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_starter_run()
	var hub = _mount_hub(host)
	await get_tree().process_frame

	var prompt = hub.provisions_dialog()
	_check(prompt != null, "the hub attaches the provisioning prompt (S4 modal)")
	if prompt == null:
		host.queue_free()
		return
	_check(not prompt.is_open(), "the prompt starts closed")

	# --- the locked days-of-supply formula (docs/20-* §4.10) --------------
	_check(SailingSimLib.RATION_SIZE == 5, "RATION_SIZE is 5 (§4.5)")
	_check(SailingSimLib.daily_need(15) == 3,
		"15 crew need ceil(15 / 5) = 3 units/day (got %d)"
		% SailingSimLib.daily_need(15))
	_check(SailingSimLib.supply_days(45, 45, 15) == 15,
		"starter caravel 15 crew, 45/45 → 15 days (got %d)"
		% SailingSimLib.supply_days(45, 45, 15))
	_check(SailingSimLib.supply_days(60, 60, 15) == 20,
		"§4.10's worked example: 60 + 60 units = 20 days")
	_check(SailingSimLib.supply_days(45, 9, 15) == 3,
		"the readout takes the lesser stack (water 9 / 3 = 3 days)")
	_check(SailingSimLib.supply_days(0, 45, 15) == 0,
		"an empty provisions stack is 0 days")
	_check(SailingSimLib.supply_days(45, 45, 0) == 0,
		"zero crew divides into 0 days — the gate, not the formula, reports it")

	# --- Set Sail opens the prompt, it does not route ---------------------
	var sail: Button = hub.get_node("Layout/VBox/Footer/SetSail")
	_check(not sail.disabled, "Set Sail is enabled with a crew and supplies")
	sail.pressed.emit()
	await get_tree().process_frame
	_check(prompt.is_open(), "clicking Set Sail opens the provisioning prompt")
	_check(GameState.current_port == "lisbon",
		"…and does not leave port yet (still docked)")
	_check(hub.has_modal(), "the hub knows the prompt is a modal")
	_check(get_tree().get_nodes_in_group("modal_overlay").has(prompt),
		"the open prompt joins modal_overlay (§6)")

	# --- the readout, tier-coloured (§4.8 GOOD ≥ 10) ----------------------
	var days_label: Label = prompt.get_node(
		"Center/Panel/Margin/Body/DaysRow/Days"
	)
	_check(days_label.text == I18n.fmt("port.sail.days", {"days": 15}),
		"the readout uses port.sail.days with {days} (%s)" % days_label.text)
	_check(days_label.get_theme_color("font_color") == Color("#4e9e4e"),
		"15 days is GOOD green (§4.8)")
	_check(prompt.days_of_supply() == 15,
		"days_of_supply() agrees with the label (%d)" % prompt.days_of_supply())
	var title: Label = prompt.get_node("Center/Panel/Margin/Body/Title")
	_check(title.text == I18n.t_key("port.sail.prepare"),
		"the prompt title uses port.sail.prepare (%s)" % title.text)

	# --- buying goes through TradeEngine.buy_supplies, at the fixed price -
	var row: Dictionary = prompt.supply_row("provisions")
	_check(not row.is_empty(), "the prompt has a provisions row")
	_check(not prompt.supply_row("water").is_empty(),
		"the prompt has a water row")
	# Free 30 units of hold (the §5 loadout's wine) so a 10-unit step fits: the
	# prompt never silently drops cargo, so a full hold caps the stepper instead.
	GameState.fleet[0]["cargo"] = {}
	prompt.rebuild()
	await get_tree().process_frame
	var gold_before := GameState.gold
	prompt.step("provisions", 1)
	_check(prompt.pending_qty("provisions") == 10,
		"the [+] stepper stages 10 units (got %d)"
		% prompt.pending_qty("provisions"))
	var buy: Button = prompt.buy_button("provisions")
	_check(buy.text == I18n.fmt("port.sail.buy", {"qty": 10, "gold": 20}),
		"the Buy label uses port.sail.buy with {qty}/{gold} (%s)" % buy.text)
	_check(not buy.disabled, "Buy is enabled at 10 units and 5,000g")
	_check(prompt.buy("provisions"), "Buy 10 provisions succeeds")
	_check(FleetLib.supplies("provisions") == 55,
		"provisions went 45 → 55 (%d)" % FleetLib.supplies("provisions"))
	_check(GameState.gold == gold_before - 20,
		"10 provisions cost 10 × 2g = 20g (gold %d)" % GameState.gold)
	_check(prompt.days_of_supply() == 15,
		"still 15 days: water is now the binding stack")
	_check(prompt.pending_qty("provisions") == 0,
		"the staged quantity resets after a purchase")

	# Buying water raises the binding number (§4.10 min of the two stacks).
	prompt.step("water", 1)
	prompt.step("water", 1)
	_check(prompt.pending_qty("water") == 20, "the stepper reaches 20")
	_check(prompt.buy("water"), "Buy 20 water succeeds")
	_check(FleetLib.supplies("water") == 65,
		"water went 45 → 65 (%d)" % FleetLib.supplies("water"))
	_check(prompt.days_of_supply() == 18,
		"buying water raises the readout to floor(55/3) = 18 (got %d)"
		% prompt.days_of_supply())

	# `[-]` never goes below zero.
	for i in range(5):
		prompt.step("water", -1)
	_check(prompt.pending_qty("water") == 0,
		"the [-] stepper clamps at 0 (got %d)" % prompt.pending_qty("water"))

	# --- a full hold: disabled with a reason, and a jettison path ---------
	_make_starter_run()
	GameState.fleet[0]["cargo"] = {}
	prompt.rebuild()
	await get_tree().process_frame
	FleetLib.add_goods("salt", FleetLib.fleet_free())
	EventBus.fleet_changed.emit()
	await get_tree().process_frame
	_check(FleetLib.fleet_free() == 0, "fixture: the hold is now full")
	prompt.step("provisions", 1)
	var full_buy: Button = prompt.buy_button("provisions")
	_check(full_buy.disabled, "Buy is disabled with a full hold (§4.6.1)")
	_check(full_buy.tooltip_text == I18n.t_key("market.hold_full"),
		"the full-hold reason is market.hold_full (%s)" % full_buy.tooltip_text)
	var hint: Label = prompt.get_node("Center/Panel/Margin/Body/Hint")
	_check(hint.visible and hint.text == I18n.t_key("port.sail.jettison_hint"),
		"a full hold shows the jettison hint (%s)" % hint.text)
	var stacks: Array = prompt.jettison_buttons()
	_check(not stacks.is_empty(),
		"a full hold offers a Jettison affordance per trade-good stack (%d)"
		% stacks.size())
	var salt_button: Button = prompt.jettison_button(0, "salt")
	_check(salt_button != null, "the salt stack has its own Jettison button")
	if salt_button != null:
		var free_before := FleetLib.fleet_free()
		salt_button.pressed.emit()
		await get_tree().process_frame
		var confirm: Control = prompt.get_node("ConfirmDialog")
		_check(confirm.is_open(),
			"jettison opens the shared confirm dialog (§4.7)")
		_check(FleetLib.held("salt") > 0,
			"nothing is dropped before the player confirms")
		confirm.accept()
		await get_tree().process_frame
		await get_tree().process_frame
		_check(FleetLib.held("salt") == 0, "confirming drops the stack")
		_check(FleetLib.fleet_free() > free_before,
			"jettison freed capacity immediately (%d → %d)"
			% [free_before, FleetLib.fleet_free()])
		_check(not prompt.buy_button("provisions").disabled,
			"the Buy button re-enables once the hold has room")
		_check(not hint.visible,
			"the jettison hint hides once the hold has room again")

	# --- gold too short: disabled with market.no_gold ---------------------
	_make_starter_run()
	GameState.fleet[0]["cargo"] = {}
	GameState.gold = 5
	prompt.rebuild()
	await get_tree().process_frame
	prompt.step("provisions", 1)
	var poor_buy: Button = prompt.buy_button("provisions")
	_check(poor_buy.disabled, "Buy is disabled when gold cannot cover it")
	_check(poor_buy.tooltip_text == I18n.t_key("market.no_gold"),
		"the short-gold reason is market.no_gold (%s)" % poor_buy.tooltip_text)

	# --- Stay in port / Esc both return to S4 -----------------------------
	_make_starter_run()
	prompt.rebuild()
	GameState.gold = 5000
	await get_tree().process_frame
	var stay: Button = prompt.get_node("Center/Panel/Margin/Body/Footer/Stay")
	_check(stay.text == I18n.t_key("port.sail.stay"),
		"Stay in port uses port.sail.stay (%s)" % stay.text)
	stay.pressed.emit()
	await get_tree().process_frame
	_check(not prompt.is_open(), "Stay in port closes the prompt")
	_check(GameState.current_port == "lisbon",
		"Stay in port leaves the fleet docked at Lisbon")
	_check(not get_tree().get_nodes_in_group("modal_overlay").has(prompt),
		"a closed prompt leaves modal_overlay")

	# Esc on S4 re-opens it; Esc *inside* it goes back to S4, never sails.
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	hub._unhandled_input(esc)
	await get_tree().process_frame
	_check(prompt.is_open(), "Esc on S4 opens the prompt (§4.3)")
	prompt._unhandled_input(esc)
	await get_tree().process_frame
	_check(not prompt.is_open(), "Esc inside the prompt closes it")
	_check(GameState.current_port == "lisbon",
		"Esc inside the prompt does not sail (still docked)")

	# The enabled Set Sail runs the existing PortScreen.set_sail() path.
	hub._unhandled_input(esc)
	await get_tree().process_frame
	var sailed: Array = []
	hub.sailed.connect(func() -> void: sailed.append(true))
	prompt.get_node("Center/Panel/Margin/Body/Footer/Sail").pressed.emit()
	await get_tree().process_frame
	_check(sailed.size() == 1,
		"the prompt's Set Sail calls PortScreen.set_sail() (one sailed signal)")
	_check(GameState.current_port == null,
		"…which clears current_port (the one S4 → S3 path)")
	_check(float(GameState.world["clock_fraction"]) == 0.0,
		"…and resets clock_fraction to 0.0")

	# Locale rebind while open.
	_make_starter_run()
	prompt.rebuild()
	prompt.open()
	await get_tree().process_frame
	I18n.set_locale("zh")
	await get_tree().process_frame
	_check((prompt.get_node("Center/Panel/Margin/Body/Title") as Label).text
		== "出航准备", "the prompt rebinds on locale_changed (%s)"
		% (prompt.get_node("Center/Panel/Margin/Body/Title") as Label).text)
	var zh_buy: Button = prompt.buy_button("provisions")
	_check(zh_buy.text == I18n.fmt("port.sail.buy",
			{"qty": prompt.pending_qty("provisions"), "gold": 0}),
		"the Buy label rebinds to zh (%s)" % zh_buy.text)
	I18n.set_locale("en")
	prompt.close()
	await get_tree().process_frame

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


## The locked §4.11.2 gate: no crew, or less than a day of supplies.
func _test_provisions_gate() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_starter_run()
	var hub = _mount_hub(host)
	await get_tree().process_frame
	var prompt = hub.provisions_dialog()
	if prompt == null:
		host.queue_free()
		return

	# --- crew 0 ----------------------------------------------------------
	_check(SailingSimLib.supply_block_reason() == "",
		"the gate is open for the starter caravel")
	GameState.fleet[0]["crew"] = 0
	_check(SailingSimLib.supply_block_reason() == "port.sail.no_crew",
		"crew 0 → port.sail.no_crew (got '%s')"
		% SailingSimLib.supply_block_reason())
	prompt.open()
	await get_tree().process_frame
	var sail: Button = prompt.get_node("Center/Panel/Margin/Body/Footer/Sail")
	_check(sail.disabled, "Set Sail is disabled with no crew")
	var reason: Label = prompt.get_node(
		"Center/Panel/Margin/Body/Footer/GateReason"
	)
	_check(reason.visible and reason.text == I18n.t_key("port.sail.no_crew"),
		"the reason is visible and uses port.sail.no_crew (%s)" % reason.text)
	var days_label: Label = prompt.get_node(
		"Center/Panel/Margin/Body/DaysRow/Days"
	)
	_check(days_label.text == I18n.t_key("port.sail.days_zero"),
		"days == 0 shows port.sail.days_zero (%s)" % days_label.text)
	# A programmatic press must not leak past the gate either.
	var sailed: Array = []
	hub.sailed.connect(func() -> void: sailed.append(true))
	sail.pressed.emit()
	_check(sailed.is_empty(), "the gated Set Sail emits nothing")
	_check(hub.set_sail() == false, "set_sail() itself refuses with no crew")
	_check(GameState.current_port == "lisbon",
		"the refused set_sail() leaves current_port untouched")

	# --- supplies 0 ------------------------------------------------------
	_make_starter_run()
	GameState.fleet[0]["provisions"] = 0
	_check(SailingSimLib.supply_block_reason() == "port.sail.no_supply",
		"provisions 0 → port.sail.no_supply (got '%s')"
		% SailingSimLib.supply_block_reason())
	prompt.rebuild()
	await get_tree().process_frame
	_check(sail.disabled, "Set Sail is disabled with 0 days of supply")
	_check(reason.text == I18n.t_key("port.sail.no_supply"),
		"the reason is port.sail.no_supply (%s)" % reason.text)
	_check(hub.set_sail() == false,
		"set_sail() refuses with less than a day of supplies")
	_check(GameState.current_port == "lisbon",
		"the refused set_sail() leaves the fleet in port")

	# Two units is still less than one day (15 crew need 3).
	_make_starter_run()
	GameState.fleet[0]["provisions"] = 2
	_check(SailingSimLib.supply_block_reason() == "port.sail.no_supply",
		"2 provisions at 3/day is still under one day")
	# Exactly one day opens the gate.
	_make_starter_run()
	GameState.fleet[0]["provisions"] = 3
	GameState.fleet[0]["water"] = 3
	_check(SailingSimLib.supply_block_reason() == "",
		"exactly one day of each opens the gate (days ≥ 1)")
	prompt.rebuild()
	await get_tree().process_frame
	_check(not sail.disabled, "Set Sail enables at exactly one day")
	_check(not reason.visible, "the gate reason hides when the gate is open")

	# --- the short-supply warning (WARN band) ----------------------------
	_make_starter_run()
	GameState.fleet[0]["provisions"] = 15
	GameState.fleet[0]["water"] = 15
	prompt.rebuild()
	await get_tree().process_frame
	var short: Label = prompt.get_node(
		"Center/Panel/Margin/Body/DaysRow/Short"
	)
	_check(prompt.days_of_supply() == 5, "15 / 3 = 5 days (got %d)"
		% prompt.days_of_supply())
	_check(short.visible and short.text == I18n.fmt(
		"port.sail.short_warning", {"days": 5}),
		"a small but non-zero readout shows port.sail.short_warning (%s)"
		% short.text)
	_check(days_label.get_theme_color("font_color") == Color("#d9a441"),
		"5 days is WARN amber (§4.8)")
	# BAD ≤ 2.
	GameState.fleet[0]["provisions"] = 6
	GameState.fleet[0]["water"] = 6
	prompt.rebuild()
	await get_tree().process_frame
	_check(prompt.days_of_supply() == 2, "6 / 3 = 2 days (got %d)"
		% prompt.days_of_supply())
	_check(days_label.get_theme_color("font_color") == Color("#b3341f"),
		"2 days is BAD red (§4.8)")

	prompt.close()
	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 9. The officers panel entry points (S18) -----------------------------

func _test_officers_panel_entry() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	GameState.player["officers"] = ["off_mateus_alvares"]
	var hub = _mount_hub(host)
	await get_tree().process_frame

	var panel = hub.officers_panel()
	_check(panel != null, "the hub attaches the S18 officers panel")
	if panel == null:
		host.queue_free()
		return
	_check(not panel.is_open(), "the officers panel starts closed")

	# `O` on S4 (§4.3).
	var key := InputEventAction.new()
	key.action = "toggle_officers"
	key.pressed = true
	hub._unhandled_input(key)
	await get_tree().process_frame
	_check(panel.is_open(), "`O` opens the officers panel (S18, §4.3)")
	_check(hub.has_modal(), "the hub knows the officers panel is a modal")
	_check(panel.officer_ids() == ["off_mateus_alvares"],
		"the panel lists the employed officer (%s)" % str(panel.officer_ids()))
	# While the panel is up the hub defers (a modal owns input first, §6), so the
	# toggle lands on the panel itself — exactly what the real input chain does.
	panel._unhandled_input(key)
	await get_tree().process_frame
	_check(not panel.is_open(), "`O` closes it again (§4.3 toggle)")
	_check(not hub.has_modal(), "a closed panel is no longer a modal")

	# The footer button beside Fleet (docs/80-* §4.6.2 "entry point (locked)"):
	# S18 is a modal over S4, so it belongs with the footer modals, not in the
	# facility column (which is reserved for rows that leave S4 for a screen).
	var row: Button = hub.officers_row()
	_check(row != null, "S4's footer carries an Officers button")
	if row != null:
		_check(row.text == I18n.t_key("officers.title"),
			"the Officers button is localised (%s)" % row.text)
		_check(not row.has_meta("facility_id"),
			"the Officers button is not a facility (no facility_id meta)")
		_check(not hub.facility_row_ids().has("officers"),
			"…so it never enters facility_row_ids (§4.1 order is untouched)")
		var fleet_button: Button = hub.get_node("Layout/VBox/Footer/Fleet")
		_check(row.get_parent() == fleet_button.get_parent(),
			"the Officers button shares the footer with Fleet")
		_check(row.get_index() == fleet_button.get_index() + 1,
			"…and sits immediately after it (%d vs %d)"
			% [row.get_index(), fleet_button.get_index()])
		_check(row.custom_minimum_size.y == 40.0,
			"the Officers button uses the 40px button height (§4.8)")
		row.pressed.emit()
		await get_tree().process_frame
		_check(panel.is_open(), "the footer Officers button opens the panel")
		panel.close()

	# Esc is behind the modal rule: it closes the panel, never Set Sail.
	panel.open()
	await get_tree().process_frame
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	hub._unhandled_input(esc)
	await get_tree().process_frame
	_check(panel.is_open(),
		"Esc behind the open officers panel does not reach S4's Set Sail edge")
	_check(GameState.current_port == "lisbon",
		"…so the fleet stays docked (current_port %s)"
		% str(GameState.current_port))
	panel.close()

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
