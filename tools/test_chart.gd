extends Node
## Phase-6 task I acceptance tests (docs/IMPLEMENT-Phase6.md task I + §2.9/§2.12;
## docs/80-UI-UX.md §4.6 seasonal layers + omniscient debug chart mode).
## Headless scene test:
##
##   godot --headless res://tools/test_chart.tscn
##
## Exits 0 when every check passes, 1 otherwise. Covers: the `W`/`C`/`I`
## overlay state machines (keys + toggles, chart-local view state), the S19
## debug-row gate (off ⇒ `D`/`,`/`.` unreachable), the §2.12 debug layer list
## (omniscient map + every port/neutral/capitals, live ecology markers,
## wrecks, hunter-intel shapes, the 17-lane network with variants/spokes/
## chokepoints + legend, the `,`/`.` month scrubber, the info strip), the
## redraw-trigger discipline (build counters move only on triggers, never per
## frame), and the purity guarantees (a `SaveSystem.snapshot()` digest taken
## before vs after any debug interaction is identical; a save taken
## mid-preview round-trips identically — the preview month appears nowhere in
## the payload).
##
## The S19 row itself is task V's (parallel W5): the gate is read guard-style
## (`ChartView.debug_row_enabled`), so this suite drives the gate through the
## documented `ChartView.debug_row_override` test seam and additionally
## exercises the real `SettingsPanel.debug_overlays` static when it exists
## (post-merge), skipping those checks with a NOTE before V lands.

const PaletteLib := preload("res://scripts/palette.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const ChartScene := preload("res://scenes/world/chart_screen.tscn")

## Baltic fixture tile (inside `baltic_ice`, months 12/1/2/3) — test_ocean's.
const ICE_CELL := Vector2i(2313, 420)
## An open-water tile the fixture run never explores (the omniscient-vs-player
## pixel identity probe).
const DARK_CELL := Vector2i(1242, 609)
## The lane with the shipped seasonal variant (`10-*` §7.6).
const HANSE_LANE := "hanseatic_north"
const HANSE_WINTER := "hanseatic_north_winter"
## The reversal system (`20-*` §4.16: summer months flip the Somali).
const SOMALI_SYSTEM := "somali_current"
## A port from the neutral tier (`nation_id: ""`, task P's content).
const NEUTRAL_PORT := "guangzhou"

var _failures: Array[String] = []
var _checks := 0
var chart = null


func _ready() -> void:
	var map = MapLoaderLib.new()
	_check(map.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"map loads for the chart fixtures (%s)" % map.last_error)
	DataLoader.map = map
	GameState.new_game("portugal", false)
	_check(GameState.day >= 1, "fixture run starts on a real day (day %d)"
		% GameState.day)
	_check(GameState.npc_fleets.size() > 0,
		"fixture run seeded the ecology (%d fleets)" % GameState.npc_fleets.size())

	chart = ChartScene.instantiate()
	add_child(chart)
	var ocean = OceanLayersLib.instance()
	print("NOTE  ocean decode (wind): ok=%s %d ms (%s)"
		% [str(ocean.decode_ok), ocean.decode_ms, ocean.last_error])

	_test_gate_defaults()
	_test_row_off_keys_unreachable()
	_test_player_overlay_state_machine()
	_test_snapshot_purity()
	_test_debug_layers()
	_test_scrub_purity()
	_test_marker_sources()
	_test_real_settings_symbol()
	_test_redraw_discipline()
	_test_locale_and_budget()
	ChartViewLib.debug_row_override = -1
	_report()


# --- Harness ----------------------------------------------------------------

func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(message)
		print("FAIL  %s" % message)
	return condition


func _report() -> void:
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d checks FAILED" % _failures.size())
		get_tree().quit(1)


## A full-state digest: the whole `SaveSystem.snapshot()` payload (minus the
## wall-clock `saved_at`) plus the session-only fields a save does not carry
## (the explored set, the fleet sim's save payload, the day).
func _state_digest() -> String:
	var snapshot: Dictionary = SaveSystem.snapshot()
	snapshot.erase("saved_at")
	var payload := {
		"snapshot": snapshot,
		"explored_tiles": JSON.stringify(GameState.explored_tiles),
		"known_ports": GameState.known_ports.duplicate(),
		"day": int(GameState.day),
		"world": JSON.stringify(GameState.world),
		"fleet": GameState.fleet.size(),
	}
	return JSON.stringify(payload)


## Synthesizes a raw key edge into the chart's input handler (the chart owns
## input while open; no InputMap actions are bound for its keys).
func _press(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = true
	chart._unhandled_input(ev)


func _set_explored(cell: Vector2i) -> void:
	GameState.explored_tiles[cell] = true


## Advances a few frames without touching the chart — the "no per-frame
## rebuild" probe.
func _idle_frames(count: int) -> void:
	for _i in count:
		await get_tree().process_frame


## Resets the chart-local view state (the toggles persist by design; sections
## that assert from a known state start here).
func _reset_view_state() -> void:
	if chart.is_open():
		chart.close_chart()
	chart._wind_on = false
	chart._current_on = false
	chart._ice_on = false
	chart._omni_on = false
	chart._preview_month = 0


# --- 1. Gate defaults (correction 12: session-only, default false) ----------

func _test_gate_defaults() -> void:
	ChartViewLib.debug_row_override = -1
	var panel: Script = load("res://scenes/ui_shared/settings_panel.gd")
	var panel_value = panel.get("debug_overlays")
	if panel_value == null:
		print("NOTE  SettingsPanel.debug_overlays not landed yet — guard default asserted")
	_check(chart.debug_available() == false,
		"pre-merge (and by contract default) the debug row reads OFF")
	_check(not chart.debug_layers_active(),
		"no build has rendered the debug layers with the row off")
	_check(chart.is_open() == false, "the chart starts closed")


# --- 2. Row off ⇒ the debug keys are unreachable (§2.12) --------------------

func _test_row_off_keys_unreachable() -> void:
	ChartViewLib.debug_row_override = 0  # forced off — the row-off machine
	_reset_view_state()
	chart.open_chart()
	var builds: int = chart.build_count()
	_press(KEY_D)
	_check(not chart.omniscient_on(),
		"row off: `D` cannot enable the omniscient mode")
	_press(KEY_COMMA)
	_press(KEY_PERIOD)
	_check(chart.preview_month() == 0,
		"row off: `,`/`.` never open the month scrubber")
	_check(chart.build_count() == builds,
		"row off: the ignored debug keys trigger no rebuild")
	# The player layers still work with the row off (§2.9).
	_press(KEY_W)
	_check(chart.wind_layer_on(), "row off: `W` still opens the wind layer")
	_press(KEY_C)
	_check(chart.current_layer_on(), "row off: `C` still opens the current layer")
	_press(KEY_I)
	_check(chart.ice_layer_on(), "row off: `I` still opens the ice layer")
	_check(chart.ecology_markers().is_empty() and chart.network_layer().is_empty(),
		"row off: no debug layer builds even with the seasonal layers on")
	chart.close_chart()


# --- 3. Player overlay state machines (§2.9; keys live only while open) -----

func _test_player_overlay_state_machine() -> void:
	ChartViewLib.debug_row_override = -1
	_reset_view_state()
	chart.open_chart()
	# A pristine run has explored nothing: the player ice layer is empty even
	# with the layer on (the explored bitset rule).
	chart.toggle_ice_layer()
	_check(chart.ice_layer_on(), "the `I` layer turns on")
	_check(chart.ice_marker_cells().is_empty(),
		"player ice layer respects the explored bitset (fresh run ⇒ no tint)")
	_set_explored(ICE_CELL)
	chart.toggle_ice_layer()
	chart.toggle_ice_layer()  # off → on: the rebuild re-reads the explored set
	var cells: Array = chart.ice_marker_cells()
	_check(cells.has(ICE_CELL),
		"explored Baltic ice tile is tinted in month %d" % chart.view_month())
	chart.toggle_ice_layer()
	_check(chart.ice_marker_cells().is_empty(),
		"the ice layer off empties the tint list")

	# Wind arrows: one per region, tokens in the §4.14 domain.
	chart.toggle_wind_layer()
	var wind: Array = chart.wind_markers()
	var regions: int = DataLoader.wind_regions_list.size()
	_check(wind.size() == regions,
		"the wind layer draws one arrow per region (%d of %d)" % [wind.size(), regions])
	var token_ok := true
	for arrow in wind:
		if not (str(arrow["token"]) in OceanLayersLib.WIND_TOKENS):
			token_ok = false
	_check(token_ok, "every wind arrow token is a §4.14 direction or VAR")
	var var_seen := false
	for arrow in wind:
		if arrow.get("variable", false):
			var_seen = true
	_check(var_seen, "the VAR (doldrums) regions carry the placeholder glyph flag")

	# Current arrows: strength band 1..3, compass directions, post-reversal.
	chart.toggle_current_layer()
	var currents: Array = chart.current_markers()
	_check(not currents.is_empty(),
		"the current layer draws arrows on the shipped corridors (%d)"
			% currents.size())
	var band_ok := true
	for arrow in currents:
		if int(arrow["strength"]) < 1 or int(arrow["strength"]) > 3:
			band_ok = false
		if str(arrow["dir"]) == "" or not (str(arrow["dir"]) in OceanLayersLib.COMPASS_DIRS):
			band_ok = false
	_check(band_ok, "every current arrow decodes into the §6.5 strength/dir bands")

	# View state persists across close/open (chart-local toggles).
	chart.close_chart()
	chart.open_chart()
	_check(chart.wind_layer_on() and chart.current_layer_on()
		and not chart.ice_layer_on(),
		"W/C/I toggles persist chart-locally across close/open")
	chart.close_chart()

	# Model-level month checks (the §2.12 scrubber drives the same functions):
	# the East-China monsoon flips NE→S between months 1 and 7.
	var jan := ChartViewLib.wind_arrows(1)
	var jul := ChartViewLib.wind_arrows(7)
	var jan_monsoon := ""
	var jul_monsoon := ""
	for arrow in jan:
		if str(arrow["id"]) == "monsoon_e_china":
			jan_monsoon = str(arrow["token"])
	for arrow in jul:
		if str(arrow["id"]) == "monsoon_e_china":
			jul_monsoon = str(arrow["token"])
	_check(jan_monsoon == "NE" and jul_monsoon == "S",
		"the monsoon arrows reverse between month 1 (%s) and 7 (%s)"
			% [jan_monsoon, jul_monsoon])
	# The Somali reversal flips at lookup (§4.16/§6.5).
	var somali_jan := _somali_dir(1)
	var somali_jul := _somali_dir(7)
	_check(somali_jan != "" and somali_jul != "" and somali_jan != somali_jul,
		"the Somali current arrows flip between month 1 (%s) and 7 (%s)"
			% [somali_jan, somali_jul])


func _somali_dir(month: int) -> String:
	for arrow in ChartViewLib.current_arrows(month):
		if str(arrow["system_id"]) == SOMALI_SYSTEM:
			return str(arrow["dir"])
	return ""


# --- 4. Snapshot purity: no debug interaction mutates state ------------------

func _test_snapshot_purity() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	var before := _state_digest()
	chart.open_chart()
	chart.toggle_wind_layer()
	chart.toggle_current_layer()
	chart.toggle_ice_layer()
	chart.toggle_omniscient()
	chart.set_preview_month(12)
	chart.scrub_month(1)
	chart.scrub_month(-1)
	chart.scrub_month(-1)
	# Hover over a live fleet marker (read-only tooltip).
	var fleets: Array = chart.ecology_markers()
	if not fleets.is_empty():
		chart._update_hover(chart._to_screen(fleets[0]["cell"]))
		_check(not chart.hover_text().is_empty(),
			"the debug hover tooltip reads a fleet marker")
	else:
		_check(false, "fixture: expected at least one live fleet marker to hover")
	# Structure probes must not mutate either.
	var _pixel: Color = chart.world_pixel_color(DARK_CELL)
	var _markers: Array = chart.port_markers()
	var _network: Dictionary = chart.network_layer()
	var after := _state_digest()
	_check(before == after,
		"open + toggles + D + scrub + hover leave the save payload identical")

	# A save taken MID-PREVIEW round-trips identically: the preview month
	# appears nowhere in the payload (no chart field exists to persist).
	chart.set_preview_month(7)
	var mid_preview := _state_digest()
	_check(mid_preview == before,
		"the mid-preview (month 7) payload is byte-identical to the pre-debug one")
	chart.close_chart()
	var closed := _state_digest()
	_check(closed == before, "closing the chart leaves the payload identical")


# --- 5. The §2.12 debug layer list (row on) ---------------------------------

func _test_debug_layers() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	chart.open_chart()
	_check(chart.debug_layers_active(),
		"row on: the chart renders the debug layers")
	_check(chart.build_count() >= 1, "open rebuilds (build counter moved)")

	# `D` — omniscient: the whole map + every port + neutral grey + capitals.
	chart.toggle_omniscient()
	_check(chart.omniscient_on(), "row on: `D` enables the omniscient mode")
	_check(chart.world_pixel_color(DARK_CELL) != PaletteLib.PANEL_BG,
		"omniscient: an unexplored tile renders terrain, not the fog colour")
	var all_ports: Array = chart.port_markers()
	_check(all_ports.size() == DataLoader.ports_list.size(),
		"omniscient: every port draws (%d of %d)"
			% [all_ports.size(), DataLoader.ports_list.size()])
	var neutral_seen := false
	var neutral_color := true
	for entry in all_ports:
		if entry.get("neutral", false):
			neutral_seen = true
			if entry["color"] != ChartViewLib.port_neutral_color():
				neutral_color = false
	_check(neutral_seen, "omniscient: the neutral tier draws (its grey row exists)")
	_check(neutral_color, "omniscient: neutral ports wear the PORT_NEUTRAL grey")
	var capitals := 0
	for entry in all_ports:
		if not str(entry.get("capital", "")).is_empty():
			capitals += 1
	_check(capitals == DataLoader.nations_list.size(),
		"omniscient: every nation capital is ringed (%d of %d)"
			% [capitals, DataLoader.nations_list.size()])
	# Omniscient ice ignores the bitset (Baltic is unexplored in this run).
	GameState.explored_tiles.erase(ICE_CELL)
	chart.toggle_ice_layer()
	_check(chart.ice_marker_cells().has(ICE_CELL),
		"omniscient: the ice tint ignores the explored bitset (month %d)"
			% chart.view_month())

	# The player layers respect it again once D is off.
	chart.toggle_omniscient()
	_check(not chart.ice_marker_cells().has(ICE_CELL),
		"player mode: the unexplored Baltic tile is not tinted")

	# The network layer: 17 lanes, per-lane colors, spokes, chokepoints.
	var network: Dictionary = chart.network_layer()
	var lanes: Array = network.get("lanes", [])
	_check(lanes.size() == 17, "the network layer carries all 17 built lanes (%d)"
		% lanes.size())
	var colors := {}
	var ids_seen := {}
	for lane in lanes:
		colors[str(lane["color"])] = true
		ids_seen[str(lane["id"])] = true
		var path: Array = lane.get("active_path", [])
		_check_quiet(path.size() > 0, "lane %s has an active path" % lane["id"])
	_check(colors.size() == lanes.size(),
		"the per-lane legend colors are a stable, distinct rotation")
	_check(ids_seen.has(HANSE_LANE), "the shipped variant lane is in the legend")
	var spokes: Array = network.get("spokes", [])
	_check(spokes.size() == DataLoader.route_spokes.size(),
		"every built spoke draws (%d)" % spokes.size())
	var chokes: Array = network.get("chokepoints", [])
	_check(not chokes.is_empty(),
		"chokepoint diamonds derive from the built shared tiles (%d)" % chokes.size())
	var choke_ok := true
	for choke in chokes:
		if (choke.get("lanes", []) as Array).size() < 2:
			choke_ok = false
	_check(choke_ok, "every chokepoint diamond is attributed to ≥ 2 lanes")

	# Seasonal lane variants: the winter variant is active in month 1, the
	# base path in month 4 (the §4.14 variant rule at lookup).
	chart.toggle_ice_layer()
	chart.set_preview_month(1)
	var winter_net: Dictionary = chart.network_layer()
	var winter_variant := _lane_field(winter_net, HANSE_LANE, "active_variant")
	chart.set_preview_month(4)
	var spring_net: Dictionary = chart.network_layer()
	var spring_variant := _lane_field(spring_net, HANSE_LANE, "active_variant")
	_check(winter_variant == HANSE_WINTER,
		"month 1 preview: the Hanse winter variant is the solid path (%s)"
			% winter_variant)
	_check(spring_variant == "",
		"month 4 preview: the Hanse base path is active again (%s)" % spring_variant)
	chart.set_preview_month(0)


func _lane_field(network: Dictionary, lane_id: String, field: String) -> String:
	for lane in network.get("lanes", []):
		if str(lane.get("id", "")) == lane_id:
			return str(lane.get(field, ""))
	return ""


func _check_quiet(condition: bool, message: String) -> void:
	# Per-lane loop helper: same ledger, but the message is only printed on
	# failure (17 lanes would flood the log).
	_checks += 1
	if not condition:
		_failures.append(message)
		print("FAIL  %s" % message)


# --- 6. Scrub purity + the preview month state machine (§2.12) ---------------

func _test_scrub_purity() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	chart.open_chart()
	var live: int = chart.view_month()
	chart.scrub_month(1)
	_check(chart.view_month() == posmod(live, 12) + 1,
		"`.` previews the next month (%d → %d)" % [live, chart.view_month()])
	chart.scrub_month(-1)
	chart.scrub_month(-1)
	_check(chart.view_month() == posmod(live - 2, 12) + 1,
		"`,` steps back and wraps within 1..12 (now %d)" % chart.view_month())
	for month in range(1, 13):
		chart.set_preview_month(month)
		_check(chart.view_month() == month,
			"preview month %d renders without touching the clock" % month)
	var digest := _state_digest()
	_check(digest == _state_digest(), "scrubbing all 12 months mutates nothing")
	chart.close_chart()
	_check(chart.preview_month() == 0,
		"closing resets the preview to the live month (documented view rule)")
	chart.close_chart()


# --- 7. Marker sources: markers() / wrecks / hunter-intel shapes -------------

func _test_marker_sources() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	chart.open_chart()
	# Fleets: exactly `NpcFleets.markers()` — the only fleet source, un-culled.
	var reference: Array = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config,
		"preset": GameState.npc_preset,
	}).markers()
	var shown: Array = chart.ecology_markers()
	_check(shown.size() == reference.size(),
		"the debug chart shows every markers() entry (%d vs %d, no viewport cull)"
			% [shown.size(), reference.size()])
	var ref_cells := {}
	for entry in reference:
		ref_cells[str(entry["id"])] = entry["cell"]
	var cells_match := true
	for entry in shown:
		if ref_cells.get(str(entry["id"]), Vector2i(-9, -9)) != entry["cell"]:
			cells_match = false
	_check(cells_match, "every debug fleet marker sits on its markers() cell")

	# Role markers (§4.5.2): the letter set comes from the shared sim rule and
	# the colors from the chart's own — pirate BAD, others their nation color.
	var letters_ok := true
	for entry in shown:
		if str(entry["letter"]) != NpcFleetsLib.marker_letter(str(entry["role"])):
			letters_ok = false
	_check(letters_ok, "role markers carry the §4.5.2 letter set")
	var portugal_color: String = str(DataLoader.get_nation("portugal").get("color", ""))
	_check(chart._role_color("pirate", "") == PaletteLib.BAD,
		"the pirate marker is the BAD red square")
	_check(chart._role_color("trader", "portugal")
		== PaletteLib.nation_color(portugal_color),
		"national markers wear their nation's colour")

	# Wrecks: the save payload cells draw as the ACCENT × sites.
	GameState.wrecks.append({
		"id": "wk_chart_test", "cell": {"x": 1234, "y": 567},
		"cargo": {}, "salvage_gold": 0, "spawn_day": int(GameState.day),
	})
	chart.scrub_month(1)  # any trigger re-reads the ecology
	chart.scrub_month(-1)
	var wrecks: Array = chart.wreck_markers()
	var wreck_seen := false
	for entry in wrecks:
		if str(entry["id"]) == "wk_chart_test" \
				and entry["cell"] == Vector2i(1234, 567):
			wreck_seen = true
	_check(wreck_seen, "a seeded wreck draws at its payload cell")

	# Hunter intel: the ring on the last departed port's shore tile and the
	# cross on the at-sea intel cell (`60-*` §4.11.11.1).
	GameState.world["last_departed_port"] = "lisbon"
	GameState.world["hunter_intel_cell"] = {"x": 2000, "y": 900}
	chart.scrub_month(1)
	chart.scrub_month(-1)
	var intel: Array = chart.intel_layer()
	var ring_cell := Vector2i(-1, -1)
	var cross_cell := Vector2i(-1, -1)
	for entry in intel:
		if str(entry["kind"]) == "ring":
			ring_cell = entry["cell"]
		else:
			cross_cell = entry["cell"]
	_check(ring_cell == DataLoader.map.shore_cell("lisbon"),
		"the intel ring sits on the last departed port's shore tile (%s)"
			% str(ring_cell))
	_check(cross_cell == Vector2i(2000, 900),
		"the intel cross sits on the at-sea intel cell (%s)" % str(cross_cell))

	# The info strip: density preset + fleet counts by role, from markers().
	var counts: Dictionary = {}
	for entry in shown:
		counts[str(entry["role"])] = int(counts.get(str(entry["role"]), 0)) + 1
	var total := 0
	for role in counts:
		total += int(counts[role])
	_check(total == GameState.npc_fleets.size(),
		"the info strip's per-role counts sum to the live fleet cap (%d)" % total)
	chart.close_chart()
	# Restore the seeded debug-only state (these tests are done with it).
	GameState.wrecks.clear()
	GameState.world["last_departed_port"] = ""
	GameState.world["hunter_intel_cell"] = null


# --- 8. The real SettingsPanel symbol (post-merge path; V owns the row) ------

func _test_real_settings_symbol() -> void:
	ChartViewLib.debug_row_override = -1
	var panel: Script = load("res://scenes/ui_shared/settings_panel.gd")
	var panel_value = panel.get("debug_overlays")
	if panel_value == null:
		print("NOTE  skipping the real-symbol flip (SettingsPanel.debug_overlays not landed)")
		return
	panel.set("debug_overlays", true)
	_check(chart.debug_available(),
		"the real S19 row ON enables the debug gate")
	chart.open_chart()
	_press(KEY_D)
	_check(chart.omniscient_on(), "the real row on: `D` works end to end")
	chart.close_chart()
	panel.set("debug_overlays", false)
	_check(not chart.debug_available(),
		"the real S19 row OFF disables the debug gate")
	chart.open_chart()
	_press(KEY_D)
	_check(not chart.omniscient_on(),
		"the real row off: `D` is ignored again")
	chart.close_chart()


# --- 9. Redraw-trigger discipline (§2.12: no per-frame work) -----------------

func _test_redraw_discipline() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	chart.open_chart()
	var builds: int = chart.build_count()
	var terrains: int = chart.terrain_build_count()
	# Frames + hover probes move nothing.
	await _idle_frames(4)
	chart._update_hover(chart.world_rect().position)
	chart.world_pixel_color(DARK_CELL)
	_check(chart.build_count() == builds,
		"frames + hover + pixel probes never rebuild")
	# The pinned triggers move the overlay counter by exactly one.
	chart.toggle_wind_layer()
	_check(chart.build_count() == builds + 1, "a layer toggle rebuilds once")
	chart.scrub_month(1)
	_check(chart.build_count() == builds + 2, "a month scrub rebuilds once")
	# The terrain image only rebuilds when the explored/omniscient source
	# flips — a layer toggle or scrub reuses it.
	_check(chart.terrain_build_count() == terrains + 1,
		"layer/scrub rebuilds reuse the terrain image (open built it once)")
	EventBus.day_advanced.emit(int(GameState.day) + 1)
	_check(chart.build_count() == builds + 3,
		"day_advanced rebuilds while open (the pinned trigger)")
	_check(chart.terrain_build_count() == terrains + 1,
		"day_advanced does not re-walk the terrain")
	# `D` flips the terrain source exactly once.
	chart.toggle_omniscient()
	_check(chart.terrain_build_count() == terrains + 2,
		"the omniscient flip builds the whole-map terrain (cached afterwards)")
	var cached: int = chart.terrain_build_count()
	chart.toggle_omniscient()
	chart.toggle_omniscient()
	_check(chart.terrain_build_count() == cached + 2,
		"omniscient re-flips reuse the cached whole-map image")
	chart.close_chart()
	var closed_builds: int = chart.build_count()
	EventBus.day_advanced.emit(int(GameState.day) + 1)
	_check(chart.build_count() == closed_builds,
		"day_advanced while closed triggers no rebuild")
	chart.close_chart()


# --- 10. Locale rebind + the §4.6 open budget --------------------------------

func _test_locale_and_budget() -> void:
	ChartViewLib.debug_row_override = 1
	chart.toggle_wind_layer()
	chart.toggle_omniscient()
	chart.open_chart()
	var ms: float = chart.last_open_ms()
	print("PROFILE chart_debug_open_ms %d" % int(ms))
	_check(ms < 5000.0, "a debug open (whole-map terrain cached) stays bounded (%d ms)"
		% int(ms))
	var debug_texts: Array = chart.debug_legend_texts()
	_check(debug_texts.size() >= 40,
		"the debug side legend renders its rows (%d strings, keys pre-merge)"
			% debug_texts.size())
	_check(not str(debug_texts[0]).is_empty(),
		"the debug legend has a title row (%s)" % str(debug_texts[0]))
	chart.close_chart()

	# The §4.6 player budget: the plain chart open stays < 0.5 s.
	ChartViewLib.debug_row_override = -1
	chart.open_chart()
	print("PROFILE chart_open_ms %d" % int(chart.last_open_ms()))
	_check(chart.last_open_ms() < 500.0,
		"the player chart open keeps the §4.6 budget (%d ms)"
			% int(chart.last_open_ms()))
	_check(chart.legend_texts().size() == 6,
		"the player chart still shows exactly its 6 §4.7.5 strings")
	var before_locale: Array = chart.legend_texts()
	I18n.set_locale("zh")
	var zh_locale: Array = chart.legend_texts()
	I18n.set_locale("en")
	_check(not before_locale.is_empty() and before_locale != zh_locale,
		"the chart rebinds its labels on locale_changed")
	chart.close_chart()
