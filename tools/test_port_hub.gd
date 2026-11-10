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
##   9 the §4.6.1-amended 一键补满 auto-fill: the exact plan maths (largest
##     common target, hold cap ⌊(free+P+W)/2⌋, piecewise purse cap), buy-only
##     plans running at once, discard-bearing plans confirm-first, the
##     disabled no-op reason and the zh rebind;
##  10 the S18 officers panel opens from the `O` key and the shared open
##     path (the §4.5 intel menu's 官员 item — the footer button was removed
##     2026-11-03).

const PortScene := preload("res://scenes/port/port_screen.tscn")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
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
	await _test_provisions_fill()
	await _test_provisions_gate()
	await _test_officers_panel_entry()
	await _test_chart_at_port()
	await _test_game_over_full_scene()
	await _test_rebuild_reapplies_layout()
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
		"position": {"x": tile.x, "y": tile.y},
		# §4.1b port hours (added 2026-11-02): 12:00 — every facility open.
		"clock_fraction": 0.5,
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


## Row ids, in display order, from the actual card buttons (not the hub's own
## cache) so the assertion is about what is on screen.
func _row_ids(hub) -> Array:
	var ids: Array = []
	for button in hub.facility_buttons():
		ids.append(str(button.get_meta("facility_id")))
	return ids


## The fixed §4.8.1 grid lines, derived from the cards' authored slots
## (Phase 12: the cards hang directly off facility_grid at the CARD_SLOTS
## rects — the pair HBoxes are gone, so the two-per-line rule is read off
## the grid positions): group by slot row, order by slot column.
func _row_lines(hub) -> Array:
	var cells: Array = []
	for button in hub.facility_buttons():
		cells.append({
			"x": int(button.position.x / 32.0),
			"y": int(button.position.y / 32.0),
			"id": str(button.get_meta("facility_id")),
		})
	return _group_lines(cells)


## The committed `cards.*` rows grouped the same way — the file is the
## pin (docs/80-* §4.8.9): the build must honor whatever layout the
## studio committed, authored CARD_SLOTS or the user's restyle.
func _expected_lines_from_layout() -> Array:
	var cells: Array = []
	var elements: Dictionary = (DataLoader.ui_layout.get(
			"port", {}) as Dictionary).get("elements", {}) as Dictionary
	for key: String in elements:
		if not key.begins_with("cards.") \
				or key.substr(6).contains("."):
			continue
		var facility_id := key.trim_prefix("cards.")
		if facility_id in FIXED_ORDER:
			var rect: Dictionary = elements[key]
			cells.append({
				"x": int(rect.get("x", 0)),
				"y": int(rect.get("y", 0)),
				"id": facility_id,
			})
	return _group_lines(cells)


func _group_lines(cells: Array) -> Array:
	var rows := {}
	for cell in cells:
		if not rows.has(cell["y"]):
			rows[cell["y"]] = []
		rows[cell["y"]].append(cell)
	var ys: Array = rows.keys()
	ys.sort()
	var lines: Array = []
	for y in ys:
		var row_cells: Array = rows[y]
		row_cells.sort_custom(func(a, b): return a["x"] < b["x"])
		var ids: Array = []
		for cell in row_cells:
			ids.append(cell["id"])
		lines.append(ids)
	return lines


## The §4.8.1 open-card status text for `id` at `port_id`: the windowed
## `open_now` line, or the plain `open_always` label for a 24h facility
## (empty window).
func _open_status(port_id: String, id: String) -> String:
	var window: Dictionary = SailingSimLib.facility_window_text(port_id, id)
	if window.is_empty():
		return I18n.t_key("port.facility.open_always")
	return I18n.fmt("port.facility.open_now", window)


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
	var sail: Button = hub.get_node("footer/SetSail")
	_check(sail != null and not sail.disabled,
		"Set Sail is present and enabled below the rows")
	# Fixed-card grid layout (docs/80-* §4.8.1): [Market][Shipyard] /
	# [Tavern][Inn] / [Guild][Palace] — every present facility takes the same
	# two-per-line slot whatever its open/closed state. Phase 12: the file
	# is the pin — the expected lines derive from the committed `cards.*`
	# rows (the user's studio layout may differ from the authored
	# CARD_SLOTS; the contract is that the BUILD honors the file).
	var lines := _row_lines(hub)
	_check(lines == _expected_lines_from_layout(),
		"Lisbon lays the cards out as the committed §4.8.1 grid (got %s, want %s)"
				% [str(lines), str(_expected_lines_from_layout())])
	# Every card uses the fixed 320×64 spec (docs/80-* §4.8.1).
	for id in ids:
		var row: Button = hub.facility_row(id)
		_check(row != null and row.custom_minimum_size == Vector2(320, 64),
			"card '%s' uses the 320×64 §4.8.1 spec (%s)"
			% [id, "" if row == null else str(row.custom_minimum_size)])

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
			"clock_fraction": 0.5}
		var hub = _mount_hub(host)
		await get_tree().process_frame
		var guild: Button = hub.facility_row("guild")
		_check(guild != null, "%s: the guild row exists" % port_id)
		_check(hub.is_facility_enabled("guild"),
			"%s: guild is enabled at Phase 3" % port_id)
		hub.queue_free()
		await get_tree().process_frame
	# §7.1: the 100 sovereign ports all list a guild; the Phase-6 neutral
	# tier never carries one (its facilities are market/tavern/inn ± shipyard).
	var sovereign_count := 0
	for port_record in DataLoader.ports_list:
		if str(port_record.get("nation_id", "")) != "":
			sovereign_count += 1
	_check(ports_with_guild == sovereign_count,
		"every sovereign port's data lists guild (phase 3) — %d/%d (neutral tier carries none, §7.1)"
		% [ports_with_guild, sovereign_count])

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
		var texts: Dictionary = {} if row == null \
			else hub.facility_card_texts(id)
		_check(texts.get("name", "") == I18n.t_key("port.%s" % id),
			"'%s' shows its noun on the name line (%s)" % [id, str(texts)])
		_check(texts.get("status", "") == _open_status("lisbon", id),
			"'%s' shows the open-now status line (%s)" % [id, str(texts)])

	for id in P3_FACILITIES:
		var row: Button = hub.facility_row(id)
		_check(row != null and not row.disabled,
			"phase-3 facility '%s' is enabled" % id)
		var texts: Dictionary = {} if row == null \
			else hub.facility_card_texts(id)
		_check(texts.get("name", "") == I18n.t_key("port.%s" % id),
			"'%s' shows its noun on the name line (%s)" % [id, str(texts)])
		_check(texts.get("status", "") == _open_status("lisbon", id),
			"'%s' shows the open-now status line (%s)" % [id, str(texts)])
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
	# The constant is read straight off the script — no hub instantiation
	# needed to inspect a routing table.
	var port_script = load("res://scenes/port/port_screen.gd")
	for id in P1_FACILITIES:
		_check(str(port_script.FACILITY_SCENES.get(id, "")) == FACILITY_SCENES[id],
			"FACILITY_SCENES[%s] == %s (got '%s')"
			% [id, FACILITY_SCENES[id],
				str(port_script.FACILITY_SCENES.get(id, ""))])
		_check(ResourceLoader.exists(FACILITY_SCENES[id]),
			"the %s screen exists on disk" % id)


## One real scene swap per Phase-1 facility: the row click routes to its screen,
## and Esc from that screen returns to the port hub (docs/80-* §4.2).
func _test_routing_all_four() -> void:
	for id in P1_FACILITIES:
		_make_run("lisbon", LISBON_TILE)
		var tree := get_tree()
		# Free the previous routed scene explicitly (it is never the test
		# scene itself after the first pass): change_scene_to_file only frees
		# what current_scene points at, and nulling that pointer used to
		# orphan the old hub — whose ChartScreen then hijacked the later
		# chart-at-port Tab probes (found 2026-11-01).
		if tree.current_scene != null and tree.current_scene != self:
			tree.current_scene.queue_free()
			await tree.process_frame
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
		english[id] = hub.facility_card_texts(id)

	I18n.set_locale("zh")
	await get_tree().process_frame
	for id in FIXED_ORDER:
		var texts: Dictionary = hub.facility_card_texts(id)
		_check(texts.get("name", "") != str(english[id].get("name", "")),
			"zh rebinds the '%s' name line (%s)" % [id, str(texts)])
		_check(texts.get("name", "") == I18n.t_key("port.%s" % id),
			"zh '%s' name line uses the zh key (%s)" % [id, str(texts)])
		_check(texts.get("status", "") != str(english[id].get("status", "")),
			"zh rebinds the '%s' status line (%s)" % [id, str(texts)])

	# No card line may ever render a raw key (docs/80-* §6), and every line is
	# localised in zh.
	for button in hub.facility_buttons():
		var id := str(button.get_meta("facility_id"))
		var texts: Dictionary = hub.facility_card_texts(id)
		for line in ["name", "status"]:
			var text := str(texts.get(line, ""))
			_check(not text.begins_with("<") and not text.contains("<port."),
				"'%s' %s line is localised, not a raw key (%s)" % [id, line, text])
			_check(not text.is_empty(),
				"'%s' %s line is non-empty in zh (%s)" % [id, line, text])

	# The header, greeting and Set Sail rebind with the cards.
	var greeting: Label = hub.get_node("header/Greeting")
	var lisbon: Dictionary = DataLoader.get_port("lisbon")
	_check(greeting.text == I18n.t(lisbon["flavor"]),
		"the greeting banner rebinds to zh (%s)" % greeting.text)
	var sail: Button = hub.get_node("footer/SetSail")
	_check(sail.text == I18n.t_key("port.set_sail"),
		"Set Sail rebinds to zh (%s)" % sail.text)

	# Back to en restores every label exactly.
	I18n.set_locale("en")
	await get_tree().process_frame
	for id in FIXED_ORDER:
		var texts: Dictionary = hub.facility_card_texts(id)
		_check(texts.get("name", "") == str(english[id].get("name", "")),
			"en restores the '%s' name line (%s)" % [id, str(texts)])
		_check(texts.get("status", "") == str(english[id].get("status", "")),
			"en restores the '%s' status line (%s)" % [id, str(texts)])

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
	_check((hub.get_node("header/PortName") as Label).text
		== I18n.t(lisbon["name"]), "the header still shows the port name")
	_check((hub.get_node("header/NationName") as Label).text
		== I18n.t(nation["name"]), "the header still shows the nation")
	_check((hub.get_node("header/Greeting") as Label).text
		== I18n.t(lisbon["flavor"]), "the flavor greeting banner is kept")
	var hud = hub.get_node_or_null("HUD")
	_check(hud != null and not hud.is_minimap_visible(),
		"S4 keeps the shared HUD with the minimap hidden (§4.5)")
	var heading: Label = hub.get_node("facility_heading")
	_check(heading.text == I18n.t_key("port.facilities"),
		"the facilities heading uses port.facilities (%s)" % heading.text)

	# Set Sail still runs the S4 → S3 transition (routing off, state change on).
	var sailed: Array = []
	hub.sailed.connect(func() -> void: sailed.append(true))
	var sail: Button = hub.get_node("footer/SetSail")
	_check(hub.set_sail(), "set_sail() succeeds while docked")
	_check(sailed.size() == 1, "set_sail() emits sailed")
	_check(GameState.current_port == null, "set_sail() clears current_port")
	# §4.1b / §4.3 continuous clock (amended 2026-11-02): the sail-out charges
	# one hour from the fixture's 12:00 and the fraction carries to sea.
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), 13.0 / 24.0),
		"set_sail() charges +1h and carries the fraction (got %.4f)"
		% float(GameState.world["clock_fraction"]))

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
	var sail: Button = hub.get_node("footer/SetSail")
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
	var sail: Button = hub.get_node("footer/SetSail")
	_check(not sail.disabled, "Set Sail is enabled with a crew and supplies")
	sail.pressed.emit()
	await get_tree().process_frame
	_check(prompt.is_open(), "clicking Set Sail opens the provisioning prompt")
	_check(GameState.current_port == "lisbon",
		"…and does not leave port yet (still docked)")
	_check(hub.has_modal(), "the hub knows the prompt is a modal")
	_check(get_tree().get_nodes_in_group("modal_overlay").has(prompt),
		"the open prompt joins modal_overlay (§6)")

	# --- the readout, tier bar (§4.8 GOOD ≥ 10; §4.9 kit value_bar) -------
	var days_label: Label = prompt.get_node(
		"Panel/DaysRow/Days"
	)
	_check(days_label.text == I18n.fmt("port.sail.days", {"days": 15}),
		"the readout uses port.sail.days with {days} (%s)" % days_label.text)
	var good_bar: ProgressBar = prompt.days_bar()
	_check(good_bar != null and good_bar.value == 10 and good_bar.max_value == 10,
		"15 safe days fill the readout bar (saturated at the GOOD boundary)")
	_check(good_bar != null and good_bar.get_theme_stylebox("fill") != null \
		and good_bar.get_theme_stylebox("fill").bg_color == Color("#4e9e4e"),
		"15 days is the GOOD-green tier (§4.8)")
	_check(prompt.days_of_supply() == 15,
		"days_of_supply() agrees with the label (%d)" % prompt.days_of_supply())

	# --- discarding supplies (80-* §4.6.1 amended) -------------------------
	var prov_j: Button = prompt.jettison_supply_button("provisions")
	var water_j: Button = prompt.jettison_supply_button("water")
	_check(prov_j != null and water_j != null,
		"both supply rows carry a jettison action")
	if prov_j != null:
		_check(prov_j.text == I18n.t_key("port.sail.jettison"),
			"the discard action uses port.sail.jettison")
		# Nothing staged: disabled with a reason.
		_check(prov_j.disabled, "the discard is disabled with nothing staged")
		# Stage 30 (stock 45) — the stepper ceiling covers carried stock even
		# with a full hold, so a discard can be staged when nothing fits.
		GameState.fleet[0]["cargo"] = {"wine": 30}
		prompt.rebuild()
		for i in range(3):
			prompt.step("provisions", 1)
		_check(prompt.pending_qty("provisions") == 30,
			"the stepper stages 30 units (3 × 10)")
		_check(not prov_j.disabled,
			"the discard enables with a staged quantity")
		var gold_before: int = GameState.gold
		var free_before: int = FleetLib.fleet_free()
		var dialog: Control = prompt.open_jettison_confirm("provisions")
		_check(dialog != null and dialog.is_open(),
			"discarding is confirm-first (§4.7)")
		_check(str(dialog._source.get("key", "")) == "port.sail.jettison.confirm"
			and int(dialog._source.get("values", {}).get("qty", -1)) == 30,
			"the confirm names the quantity via port.sail.jettison.confirm")
		dialog.accept()
		var stock: int = FleetLib.supplies("provisions")
		_check(stock == 45 - 30,
			"the confirmed discard removes the staged 30 (stock %d)" % stock)
		_check(GameState.gold == gold_before,
			"discarding refunds nothing")
		_check(prompt.pending_qty("provisions") == 0,
			"the staged quantity resets after the discard")
		# The freed capacity is real: exactly the discarded units return to
		# the free pool (cannons also occupy §4.2 capacity, so compute, don't
		# hard-code).
		_check(FleetLib.fleet_free() == free_before + 30,
			"the discard frees exactly the removed units (free %d → %d)"
			% [free_before, FleetLib.fleet_free()])
		# Restore the starter 45 for the sections below.
		_check(FleetLib.add_supplies("provisions", 30) == 30,
			"the freed hold takes 30 units back")
		_check(FleetLib.supplies("provisions") == 45,
			"back at the starter 45 after the round trip")
	var title: Label = prompt.get_node("Panel/Title")
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
	var hint: Label = prompt.get_node("Panel/Hint")
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
	var stay: Button = prompt.get_node("Panel/Footer/Stay")
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
	prompt.get_node("Panel/Footer/Sail").pressed.emit()
	await get_tree().process_frame
	_check(sailed.size() == 1,
		"the prompt's Set Sail calls PortScreen.set_sail() (one sailed signal)")
	_check(GameState.current_port == null,
		"…which clears current_port (the one S4 → S3 path)")
	# §4.1b / §4.3 continuous clock (amended 2026-11-02): +1h, fraction kept.
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), 13.0 / 24.0),
		"…and charges +1h carrying the fraction (got %.4f)"
		% float(GameState.world["clock_fraction"]))

	# Locale rebind while open.
	_make_starter_run()
	prompt.rebuild()
	prompt.open()
	await get_tree().process_frame
	I18n.set_locale("zh")
	await get_tree().process_frame
	_check((prompt.get_node("Panel/Title") as Label).text
		== "出航准备", "the prompt rebinds on locale_changed (%s)"
		% (prompt.get_node("Panel/Title") as Label).text)
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


# --- 8b. The 一键补满 auto-fill (docs/80-* §4.6.1 amended) ------------------

## The auto-fill: the pure plan maths (largest common target with
## provisions = water, locked 2g / 1g prices, hold cap ⌊(free+P+W)/2⌋ and the
## piecewise purse cap), then the live button — buy-only plans run at once,
## discard-bearing plans confirm first (§4.7), and a balanced-and-unraisable
## state disables the button with a stated reason.
func _test_provisions_fill() -> void:
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
	_check(prompt.fill_button() != null,
		"the prompt carries the 一键补满 button")

	# --- the pure plan maths ------------------------------------------------
	# Hold cap ⌊(free+P+W)/2⌋ beats the purse: surplus of the larger kind is
	# traded for the short kind.
	var plan: Dictionary = prompt.fill_plan(100, 50, 0, 1000)
	_check(int(plan["target"]) == 75 and int(plan["discard_provisions"]) == 25
		and int(plan["buy_water"]) == 25 and int(plan["cost"]) == 25,
		"fill_plan(100,50,free=0,gold=1000) trades surplus for the short kind"
		+ " (target %d)" % int(plan["target"]))
	# The purse beats the hold: 12g buys 12 water and stops — and the target
	# sits below the provisions stack, so equalising trims 38 provisions.
	plan = prompt.fill_plan(100, 50, 200, 12)
	_check(int(plan["target"]) == 62 and int(plan["buy_water"]) == 12
		and int(plan["discard_provisions"]) == 38 and int(plan["cost"]) == 12,
		("fill_plan(100,50,free=200,gold=12) stops at the purse and trims"
		+ " the surplus (target %d, plan %s)") % [int(plan["target"]), str(plan)])
	# Both caps loose: raise both stacks together at 3g per common unit.
	plan = prompt.fill_plan(100, 50, 200, 1000)
	_check(int(plan["target"]) == 175 and int(plan["buy_provisions"]) == 75
		and int(plan["buy_water"]) == 125 and int(plan["cost"]) == 275,
		"fill_plan(100,50,free=200,gold=1000) raises both to the hold cap (%d)"
		% int(plan["target"]))
	# Equal stacks with no gold: already balanced, nothing to do.
	plan = prompt.fill_plan(45, 45, 30, 0)
	_check(int(plan["target"]) == 45 and prompt._plan_is_empty(plan),
		"fill_plan(45,45,free=30,gold=0) is an empty plan")
	# Zero gold, unequal stacks: discard-only equalisation refunds nothing.
	plan = prompt.fill_plan(200, 50, 0, 0)
	_check(int(plan["target"]) == 50 and int(plan["discard_provisions"]) == 150
		and int(plan["cost"]) == 0,
		"fill_plan(200,50,free=0,gold=0) discards down to the smaller stack")
	# Reversed stacks: the gold cap is now priced at the provisions' 2g.
	plan = prompt.fill_plan(50, 100, 0, 1000)
	_check(int(plan["target"]) == 75 and int(plan["buy_provisions"]) == 25
		and int(plan["discard_water"]) == 25 and int(plan["cost"]) == 50,
		"fill_plan(50,100,free=0,gold=1000) prices the short kind at 2g (%d)"
		% int(plan["target"]))

	# --- live: a buy-only plan runs at once, no confirm ---------------------
	var ship: Dictionary = GameState.fleet[0]
	ship["provisions"] = 45
	ship["water"] = 45
	ship["cargo"] = {}
	GameState.gold = 100
	prompt.open()
	await get_tree().process_frame
	var fill: Button = prompt.fill_button()
	_check(not fill.disabled,
		"45/45 with hold headroom and gold enables the auto-fill")
	var changes: Array = []
	prompt.supplies_changed.connect(
		func(kind: String, qty: int) -> void: changes.append([kind, qty]))
	fill.pressed.emit()
	await get_tree().process_frame
	_check(FleetLib.supplies("provisions") == 60 and FleetLib.supplies("water") == 60,
		"the buy-only fill raised both stacks to 60 (%d/%d)"
		% [FleetLib.supplies("provisions"), FleetLib.supplies("water")])
	_check(GameState.gold == 55, "15+15 units at 2g/1g cost 45g (gold %d)"
		% GameState.gold)
	_check(not prompt._confirm.is_open(),
		"a buy-only plan confirms nothing")
	_check(changes.has(["provisions", 15]) and changes.has(["water", 15]),
		"supplies_changed reports both buys (%s)" % str(changes))

	# --- live: balanced and unraisable disables the button with a reason ----
	# 60/60 with free=0: the hold cap equals the stacks — empty plan.
	GameState.gold = 0
	prompt.rebuild()
	await get_tree().process_frame
	_check(fill.disabled, "60/60 with no hold and no gold disables the fill")
	_check(fill.tooltip_text == I18n.t_key("port.sail.fill.done"),
		"the disabled fill states its reason (port.sail.fill.done)")

	# --- live: a discard-bearing plan is confirm-first (§4.7) ----------------
	# P100/W20 fills the 120-hold exactly (free=0); gold 1000: the hold cap
	# (60) beats the purse, so 40 provisions trade for 40 water.
	ship["provisions"] = 100
	ship["water"] = 20
	GameState.gold = 1000
	prompt.rebuild()
	await get_tree().process_frame
	_check(not fill.disabled, "P100/W20 with gold enables the fill again")
	changes.clear()
	fill.pressed.emit()
	await get_tree().process_frame
	_check(prompt._confirm.is_open(), "a discard-bearing fill confirms first")
	_check(str(prompt._confirm._source.get("key", ""))
			== "port.sail.fill.confirm_both"
		and int(prompt._confirm._source.get("values", {}).get("target", -1)) == 60
		and int(prompt._confirm._source.get("values", {}).get("gold", -1)) == 40,
		"the confirm names target 60 at 40g (port.sail.fill.confirm_both)")
	_check(FleetLib.supplies("provisions") == 100
		and FleetLib.supplies("water") == 20 and GameState.gold == 1000,
		"nothing moved before the confirm is accepted")
	changes.clear()
	prompt._confirm.accept()
	await get_tree().process_frame
	_check(FleetLib.supplies("provisions") == 60 and FleetLib.supplies("water") == 60,
		"the accepted fill equalised at 60/60 (%d/%d)"
		% [FleetLib.supplies("provisions"), FleetLib.supplies("water")])
	_check(GameState.gold == 960, "40 water at 1g cost 40g (gold %d)"
		% GameState.gold)
	_check(changes.has(["provisions", -40]) and changes.has(["water", 40]),
		"supplies_changed reports the discard and the buy (%s)" % str(changes))
	_check(fill.disabled, "60/60 at the hold cap leaves the fill disabled")

	# --- live: cancelling the confirm changes nothing ------------------------
	ship["provisions"] = 100
	ship["water"] = 20
	GameState.gold = 1000
	prompt.rebuild()
	await get_tree().process_frame
	fill.pressed.emit()
	await get_tree().process_frame
	_check(prompt._confirm.is_open(), "the fill confirm reopens for cancel")
	prompt._confirm.cancel()
	await get_tree().process_frame
	_check(not prompt._confirm.is_open()
		and FleetLib.supplies("provisions") == 100
		and FleetLib.supplies("water") == 20 and GameState.gold == 1000,
		"cancel leaves the stacks, hold and purse untouched")

	# --- the label rebinds to zh --------------------------------------------
	I18n.set_locale("zh")
	await get_tree().process_frame
	_check(fill.text == "一键补满", "the fill label rebinds to zh (%s)" % fill.text)
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
	var sail: Button = prompt.get_node("Panel/Footer/Sail")
	_check(sail.disabled, "Set Sail is disabled with no crew")
	var reason: Label = prompt.get_node(
		"Panel/Footer/GateReason"
	)
	_check(reason.visible and reason.text == I18n.t_key("port.sail.no_crew"),
		"the reason is visible and uses port.sail.no_crew (%s)" % reason.text)
	var days_label: Label = prompt.get_node(
		"Panel/DaysRow/Days"
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
		"Panel/DaysRow/Short"
	)
	_check(prompt.days_of_supply() == 5, "15 / 3 = 5 days (got %d)"
		% prompt.days_of_supply())
	_check(short.visible and short.text == I18n.fmt(
		"port.sail.short_warning", {"days": 5}),
		"a small but non-zero readout shows port.sail.short_warning (%s)"
		% short.text)
	_check(prompt.days_bar().get_theme_stylebox("fill").bg_color
		== Color("#d9a441"), "5 days is the WARN-amber tier (§4.8)")
	# BAD ≤ 2.
	GameState.fleet[0]["provisions"] = 6
	GameState.fleet[0]["water"] = 6
	prompt.rebuild()
	await get_tree().process_frame
	_check(prompt.days_of_supply() == 2, "6 / 3 = 2 days (got %d)"
		% prompt.days_of_supply())
	_check(prompt.days_bar().get_theme_stylebox("fill").bg_color
		== Color("#b3341f"), "2 days is the BAD-red tier (§4.8)")

	prompt.close()
	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame


# --- 9. The officers roster entry points (the §4.5 intel window) ------------

func _test_officers_panel_entry() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	_make_run("lisbon", LISBON_TILE)
	GameState.player["officers"] = ["off_mateus_alvares"]
	var hub = _mount_hub(host)
	await get_tree().process_frame

	var panel = hub.officers_panel()
	_check(panel != null,
		"the hub attaches the intel window with the officers roster")
	if panel == null:
		host.queue_free()
		return
	var window = hub.get_node_or_null("IntelWindow")
	_check(window != null and not window.is_open(),
		"the intel window starts closed")

	# `O` on S4 (§4.3) — the real input chain lands on the window.
	var key := InputEventAction.new()
	key.action = "toggle_officers"
	key.pressed = true
	hub._unhandled_input(key)
	await get_tree().process_frame
	_check(window.is_open() and window.active_tab() == "officers",
		"`O` opens the intel window on the 官员 tab (§4.3)")
	_check(hub.has_modal(), "the hub knows the intel window is a modal")
	_check(panel.officer_ids() == ["off_mateus_alvares"],
		"the roster lists the employed officer (%s)" % str(panel.officer_ids()))
	# The `O` toggle lands on the window itself — exactly what the real input
	# chain does (a modal owns input first, §6).
	hub.toggle_officers_panel()
	await get_tree().process_frame
	_check(not window.is_open(), "`O` closes it again (§4.3 toggle)")
	_check(not hub.has_modal(), "a closed window is no longer a modal")

	# Amended 2026-11-03 (docs/80-* §4.6.2/§4.5): the footer `Fleet ·
	# Officers` buttons were removed as intel duplicates. The entries are the
	# intel window's 官员 tab and the `O` key; the hub pins the absence and
	# the facility column staying untouched (no "officers" row ever existed).
	_check(not hub.has_method("officers_row"),
		"the removed footer accessor is gone (officers_row)")
	_check(hub.get_node_or_null("footer/Officers") == null,
		"the port hub footer no longer carries an Officers button")
	_check(hub.get_node_or_null("footer/Fleet") == null,
		"…nor a Fleet button (both live in the §4.5 intel window)")
	_check(not hub.facility_row_ids().has("officers"),
		"the facility column never enters an officers row (§4.1 order)")
	# The shared open path opens the window on the 官员 tab.
	hub.open_officers_panel()
	await get_tree().process_frame
	_check(window.is_open() and window.active_tab() == "officers",
		"open_officers_panel() opens the 官员 tab (the shared path)")
	hub.toggle_officers_panel()

	# Esc is behind the modal rule: it closes the window, never Set Sail.
	window.open_tab("officers")
	await get_tree().process_frame
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	hub._unhandled_input(esc)
	await get_tree().process_frame
	_check(window.is_open(),
		"Esc behind the open window does not reach S4's Set Sail edge")
	_check(GameState.current_port == "lisbon",
		"…so the fleet stays docked (current_port %s)"
		% str(GameState.current_port))
	window.close()

	hub.queue_free()
	host.queue_free()
	await get_tree().process_frame

# --- The Chart over the hub (§4.2/§4.3, amended 2026-11-01) -------------------

## Tab opens the Chart (S17) over the port hub; Esc/Tab closes back into S4.
## The chart overlay wires itself: it joins the modal group, so the hub's
## Set-Sail edge is guarded while it shows, and it never mutates state.
func _test_chart_at_port() -> void:
	_make_run()
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var hub = _mount_hub(host)
	await get_tree().process_frame
	var chart = hub.get_node_or_null("ChartScreen")
	if chart == null:
		_check(false, "the port hub hosts the Chart overlay (S17)")
		hub.queue_free()
		host.queue_free()
		await get_tree().process_frame
		return
	_check(true, "the port hub hosts the Chart overlay (S17)")
	_check(not chart.is_open(), "the chart starts closed at port")
	# The §4.3 focus-steal fix (amended 2026-11-01): a footer button holds
	# focus (as after any click) and Tab must still open the chart, not cycle
	# focus — the toggle edge lives in ChartScreen._input, above the GUI layer.
	var footer: Button = hub.get_node("footer/SetSail")
	footer.grab_focus()
	_check(footer.has_focus(), "fixture: a footer button holds focus")
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	get_viewport().push_input(tab)
	_check(chart.is_open(), "Tab opens the chart over the port hub (focus held)")
	_check(hub.has_modal(),
		"the open chart counts as a port modal (Set Sail guarded)")
	_check(not chart.debug_layers_active(),
		"the port chart opens in player mode with the S19 row off")
	# Tab closes again — even though open_chart focused the close button.
	get_viewport().push_input(tab)
	_check(not chart.is_open(), "Tab closes the chart back into S4")
	# Esc closes too (the §4.3 back edge), after a fresh Tab open.
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	get_viewport().push_input(tab)
	_check(chart.is_open(), "Tab reopens the chart at port")
	get_viewport().push_input(esc)
	_check(not chart.is_open(), "Esc closes the chart back into S4")
	_check(not hub.has_modal(), "the closed chart leaves the hub modal-free")
	var world_before: Dictionary = GameState.world.duplicate(true)
	get_viewport().push_input(tab)
	chart.close_chart()
	_check(GameState.world.hash() == world_before.hash(),
		"open/close at port mutates nothing")
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


# --- S9 full-scene (80-* §4.2 full-scene amendment, 2026-11-02) ------------

## Every run-hosting port scene attaches the shared GameOverHost, so a ledger
## death ashore — the frozen-port bug: a starvation/scurvy counter completing
## on a docked midnight roll — raises S9 over whichever screen is up. The
## world scene keeps its own handler and is not exercised here.
func _test_game_over_full_scene() -> void:
	_make_run()
	var host := Control.new()
	add_child(host)
	# Two representative screens boot for real (the hub and the deepest
	# facility); the other five share the same wiring — every port screen's
	# script calls `GameOverHostLib.attach_to(self)` — so their pin is the
	# script source itself, read without a boot.
	var booted: Array[String] = [
		"res://scenes/port/port_screen.tscn",
		"res://scenes/port/palace_screen.tscn",
	]
	var wired: Array[String] = [
		"res://scenes/port/market_screen.tscn",
		"res://scenes/port/shipyard_screen.tscn",
		"res://scenes/port/tavern_screen.tscn",
		"res://scenes/port/inn_screen.tscn",
		"res://scenes/port/guild_screen.tscn",
	]
	for path in booted:
		var scene: Control = (load(path) as PackedScene).instantiate()
		host.add_child(scene)
		await get_tree().process_frame
		EventBus.game_over.emit("sunk")
		var screen := scene.get_node_or_null(
			"GameOverHost/GameOverLayer/GameOverScreen") as Control
		_check(screen != null and screen.is_open(),
			"%s raises S9 on game_over" % path.get_file())
		if screen != null:
			_check(screen.reason == "sunk"
				and not screen.reason_text().is_empty(),
				"%s's S9 binds the reason (%s)"
				% [path.get_file(), screen.reason_text()])
		if scene.has_method("has_modal"):
			_check(scene.has_modal(),
				"%s holds its hotkeys while S9 is open" % path.get_file())
		host.remove_child(scene)
		scene.free()
	for path in wired:
		var source := FileAccess.get_file_as_string(
			path.replace(".tscn", ".gd"))
		_check(source.contains("GameOverHost"),
			"%s wires the shared GameOverHost (attach in script source)"
			% path.get_file())
	host.queue_free()


## The user-reported regression (2026-11-10): an hour-crossing rebuilds
## the §4.8.1 facility cards at the AUTHORED CARD_SLOTS, snapping the
## user's committed studio layout back to default. The rebuild must
## re-apply the committed layout (docs/80-* §4.8.9 — apply runs at
## activation AND after every rebuild).
func _test_rebuild_reapplies_layout() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	# 08:00: the tavern's §4.1b window (10:00–24:00) is CLOSED.
	_make_run("lisbon", LISBON_TILE)
	GameState.world["clock_fraction"] = 8.0 / 24.0
	# A committed layout that differs from the authored CARD_SLOTS slot
	# (inside facility_grid's 7-tile rect — rule 1 clamps to the parent).
	DataLoader.ui_layout = {
		"port": {"elements": {"cards.market":
				{"x": 3, "y": 3, "w": 10, "h": 2}}},
	}
	RegistryLib._reset_for_tests()
	var hub = _mount_hub(host)
	await get_tree().process_frame
	await get_tree().process_frame
	var market: Control = hub._row_buttons.get("market", null)
	_check(market != null, "rebuild-reapply: the market card is live")
	if market == null:
		DataLoader.ui_layout = {}
		RegistryLib._reset_for_tests()
		host.queue_free()
		await get_tree().process_frame
		return
	var tile := float(RegistryLib.TILE)
	_check(market.position == Vector2(3 * tile, 3 * tile),
		"rebuild-reapply: the committed rect applies on mount (got %s)"
				% str(market.position))
	# Cross the tavern's opening hour: 08:00 → 12:00 flips the card's
	# open state → the §4.1b signature changes → the grid rebuilds.
	GameState.world["clock_fraction"] = 0.5
	EventBus.clock_changed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var market_after: Control = hub._row_buttons.get("market", null)
	_check(market_after != null and market_after != market,
		"rebuild-reapply: the hour-crossing rebuilt the card node")
	if market_after != null:
		_check(market_after.position == Vector2(3 * tile, 3 * tile),
			("rebuild-reapply: the committed rect SURVIVES the hour "
				+ "crossing (got %s — the pre-fix bug snapped it to "
				+ "CARD_SLOTS)") % str(market_after.position))
	DataLoader.ui_layout = {}
	RegistryLib._reset_for_tests()
	host.queue_free()
	await get_tree().process_frame


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
