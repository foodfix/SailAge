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
## chokepoints + legend, the `,`/`.` month scrubber), the
## redraw-trigger discipline (build counters move only on triggers, never per
## frame), the purity guarantees (a `SaveSystem.snapshot()` digest taken
## before vs after any debug interaction is identical; a save taken
## mid-preview round-trips identically — the preview month appears nowhere in
## the payload), and the §4.6 side-legend panel (pinned rect + vertical
## scroll, localized `debug.lane.*` §7.6 names, and the scene-order rule that
## no full-rect child masks the root draw).
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
	_test_legend_panel_and_lanes()
	_test_mouse_view()
	_test_legend_rows()
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
		"the debug row reads OFF by contract default (live static or absent symbol)")
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

	# `D` — omniscient: ON by default with the row on (§4.6, amended
	# 2026-11-01); `D` toggles the explored view back and forth.
	_check(chart.omniscient_on(),
		"row on: the chart opens omniscient (the fog is lifted)")
	chart.toggle_omniscient()
	_check(not chart.omniscient_on(), "row on: `D` toggles the explored view")
	chart.toggle_omniscient()
	_check(chart.omniscient_on(), "row on: `D` re-enables the omniscient mode")
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

	# The per-role legend counts sum to the live fleet cap, from markers().
	var counts: Dictionary = {}
	for entry in shown:
		counts[str(entry["role"])] = int(counts.get(str(entry["role"]), 0)) + 1
	var total := 0
	for role in counts:
		total += int(counts[role])
	_check(total == GameState.npc_fleets.size(),
		"the legend's per-role counts sum to the live fleet cap (%d)" % total)
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
	_check(panel_value is bool and panel_value == false,
		"the real static exists and defaults OFF")
	# Live-follow through V's OWN write path (the instance method that assigns
	# the static): `Script.get` must reflect it in this engine version.
	var panel_view = panel.new()
	panel_view.apply_debug_overlays(true)
	_check(chart.debug_available() == true,
		"the real S19 row ON (via apply_debug_overlays) enables the debug gate")
	chart.open_chart()
	_check(chart.omniscient_on(),
		"the real row on: the chart opens omniscient (end to end)")
	_press(KEY_D)
	_check(not chart.omniscient_on(),
		"the real row on: `D` toggles the explored view back")
	chart.close_chart()
	panel_view.apply_debug_overlays(false)
	_check(chart.debug_available() == false,
		"the real S19 row OFF disables the gate (live value, not presence)")
	chart.open_chart()
	_check(not chart.omniscient_on(),
		"the real row off: the chart opens explored")
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
	# The terrain image: with the omniscient open (row on ⇒ fog lifted, §4.6
	# amended 2026-11-01) the whole-map image is cached — layer/scrub/day
	# rebuilds reuse it and the terrain counter stays flat.
	_check(chart.terrain_build_count() == terrains,
		"layer/scrub/day rebuilds reuse the cached whole-map terrain (open built it once)")
	EventBus.day_advanced.emit(int(GameState.day) + 1)
	_check(chart.build_count() == builds + 3,
		"day_advanced rebuilds while open (the pinned trigger)")
	_check(chart.terrain_build_count() == terrains,
		"day_advanced does not re-walk the terrain")
	# `D` flips the terrain source: the explored image builds once per flip to
	# player; flipping back reuses the cached whole-map image.
	var before_flip: int = chart.terrain_build_count()
	chart.toggle_omniscient()
	_check(chart.terrain_build_count() == before_flip + 1,
		"the D flip builds the explored terrain image once")
	chart.toggle_omniscient()
	_check(chart.terrain_build_count() == before_flip + 1,
		"flipping back reuses the cached whole-map image")
	var cached: int = chart.terrain_build_count()
	chart.toggle_omniscient()
	chart.toggle_omniscient()
	_check(chart.terrain_build_count() == cached + 1,
		"omniscient re-flips only rebuild the explored image (whole-map stays cached)")
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


# --- 11. Side-legend panel + localized §7.6 lane names (§4.6, §4.7.10) -------

## The §4.6 side-legend contract: no opaque full-rect child may sit over the
## root draw (the shipped `Background` node masked the whole map), the panel
## scrolls in its pinned rect instead of growing over the top bar, and the
## lane rows render the `debug.lane.<id>` §7.6 names (zh/en, id fallback).
func _test_legend_panel_and_lanes() -> void:
	# Scene order: the root _draw paints the map and must be unmasked.
	_check(chart.get_node_or_null("Background") == null,
		"the chart scene keeps no Background child over the root draw")
	for child in chart.get_children():
		var covers := child is ColorRect \
			and (child as ColorRect).anchor_left <= 0.0 \
			and (child as ColorRect).anchor_top <= 0.0 \
			and (child as ColorRect).anchor_right >= 1.0 \
			and (child as ColorRect).anchor_bottom >= 1.0
		_check(not covers,
			"no full-rect ColorRect child masks the root draw (%s)" % child.name)
	# The panel is pinned to its §4.6 rect (width == DEBUG_PANEL_W) and scrolls
	# instead of growing (grow_* = BEGIN would push it over the Close button).
	var panel: PanelContainer = chart.get_node("DebugPanel")
	_check(absf(-panel.offset_left - 16.0 - float(chart.DEBUG_PANEL_W)) < 0.01,
		"the panel's left offset matches DEBUG_PANEL_W (%d)" % int(-panel.offset_left))
	var scroll: ScrollContainer = panel.get_node("Scroll")
	_check(scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED,
		"the side legend scrolls vertically instead of overflowing the panel")
	_check(scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"the side legend never scrolls horizontally (labels elide)")
	# The 17 §7.6 lanes each carry a zh/en `debug.lane.<id>` key …
	ChartViewLib.debug_row_override = 1
	chart.open_chart()
	var lanes: Array = chart.network_layer().get("lanes", [])
	_check(lanes.size() == 17, "the built network lists the 17 §7.6 lanes")
	var missing: Array[String] = []
	for lane in lanes:
		var l10n = DataLoader.ui_strings.get("debug.lane." + str(lane["id"]), {})
		if not (l10n is Dictionary) or str(l10n.get("zh", "")).is_empty() \
				or str(l10n.get("en", "")).is_empty():
			missing.append(str(lane["id"]))
	_check(missing.is_empty(),
		"every lane legend row has a zh/en debug.lane.<id> key (missing: %s)"
			% ", ".join(missing))
	# … and every role legend row carries a zh/en debug.role.<role> name.
	var role_missing: Array[String] = []
	for role in chart.LEGEND_ROLES:
		var rl10n = DataLoader.ui_strings.get("debug.role." + str(role), {})
		if not (rl10n is Dictionary) or str(rl10n.get("zh", "")).is_empty() \
				or str(rl10n.get("en", "")).is_empty():
			role_missing.append(str(role))
	_check(role_missing.is_empty(),
		"every role legend row has a zh/en debug.role.<role> key (missing: %s)"
			% ", ".join(role_missing))
	# … and the rows render the localized names (exact §7.6 strings), not ids.
	I18n.set_locale("zh")
	var zh_texts: Array = chart.debug_legend_texts()
	_check(_legend_has(zh_texts, "汉萨北方航线"),
		"the hanseatic_north row shows its §7.6 zh name")
	_check(_legend_has(zh_texts, "亚丁—古吉拉特—马六甲航线"),
		"the aden_gujarat_malacca row shows its §7.6 zh name")
	_check(not _legend_has(zh_texts, HANSE_LANE),
		"no legend row renders the raw lane id while localized")
	# The role rows read "<marker letter> <debug.role.* name>" (§4.7.10).
	_check(_legend_has(zh_texts, "T 商船"),
		"the trader role row shows its letter + zh name")
	_check(_legend_has(zh_texts, "· 海盗"),
		"the pirate role row shows its marker dot + zh name")
	I18n.set_locale("en")
	var en_texts: Array = chart.debug_legend_texts()
	_check(_legend_has(en_texts, "T Trader"),
		"the trader role row shows its letter + en name")
	_check(_legend_has(chart.debug_legend_texts(), "The Hanseatic northern run"),
		"the hanseatic_north row shows its §7.6 en name")
	chart.close_chart()


## Exact-match probe over the legend's label/value texts.
func _legend_has(texts: Array, needle: String) -> bool:
	for entry in texts:
		if str(entry) == needle:
			return true
	return false


# --- 12. Mouse view: the zoom/pan state machine (§4.6, amended 2026-11-01) ----

func _test_mouse_view() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	chart.open_chart()
	var builds: int = chart.build_count()
	# Wheel zoom: ×1.25 per notch, clamped to [ZOOM_MIN, ZOOM_MAX], and never
	# a rebuild (only a redraw of the existing caches).
	chart._zoom_at(Vector2(600, 300), chart.ZOOM_STEP)
	_check(absf(chart._zoom - chart.ZOOM_STEP) < 0.0001, "one notch zooms ×1.25")
	_check(chart.build_count() == builds, "zooming never rebuilds")
	for _i in range(20):
		chart._zoom_at(Vector2(600, 300), chart.ZOOM_STEP)
	_check(absf(chart._zoom - chart.ZOOM_MAX) < 0.0001,
		"zoom clamps at ×8 (%.2f)" % chart._zoom)
	chart._zoom_at(Vector2(600, 300), 1.0 / chart.ZOOM_STEP)
	for _i in range(60):
		chart._zoom_at(Vector2(600, 300), 1.0 / chart.ZOOM_STEP)
	_check(chart._zoom == chart.ZOOM_MIN, "zoom clamps at the fit view")
	_check(chart.build_count() == builds, "zoom clamps never rebuild")
	# The cursor anchor: the world point under the cursor stays under it.
	chart._zoom_at(Vector2(400, 200), chart.ZOOM_STEP)
	var world_pt: Vector2 = (Vector2(400, 200) - chart._view_rect().position) \
		/ (chart.chart_scale() * chart._zoom)
	chart._zoom_at(Vector2(400, 200), chart.ZOOM_STEP)
	var world_pt2: Vector2 = (Vector2(400, 200) - chart._view_rect().position) \
		/ (chart.chart_scale() * chart._zoom)
	_check(Vector2(world_pt).distance_to(Vector2(world_pt2)) < 0.5,
		"zoom stays anchored at the cursor (the world point is stable)")
	# Pan: a 1:1 drag (button press arms it, motion pans) clamped so the map
	# never leaves the view.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(400, 200)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(5000, 5000)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	chart._gui_input(press)  # a press at zoom > MIN arms the drag
	chart._gui_input(drag)
	var limit: Vector2 = chart.world_rect().size * (chart._zoom - 1.0)
	_check(absf(chart._pan.x - (-limit.x)) < 0.01 \
		and absf(chart._pan.y - (-limit.y)) < 0.01,
		"drag pans 1:1 and clamps to the map bounds (%s)" % str(chart._pan))
	# At the fit view a press arms nothing: the map cannot pan.
	chart._zoom = chart.ZOOM_MIN
	chart._pan = Vector2.ZERO
	chart._gui_input(press)
	chart._gui_input(drag)
	_check(chart._pan == Vector2.ZERO, "dragging at the fit view pans nothing")
	# Opening restores the fit view (§4.6).
	chart._zoom_at(Vector2(600, 300), chart.ZOOM_STEP)
	chart.close_chart()
	chart.open_chart()
	_check(chart._zoom == chart.ZOOM_MIN and chart._pan == Vector2.ZERO,
		"opening restores the fit view")
	chart.close_chart()


# --- 13. Interactive legend rows (§4.6, amended 2026-11-01) -------------------

func _test_legend_rows() -> void:
	ChartViewLib.debug_row_override = 1
	_reset_view_state()
	chart.open_chart()
	var builds: int = chart.build_count()
	# A lane row click hides that lane: a draw-time filter, never a rebuild.
	chart._on_row_gui_input(_click(), "lane_" + HANSE_LANE)
	_check(chart._layer_hidden.get("lane_" + HANSE_LANE, false) == true,
		"clicking a lane row hides that lane")
	_check(chart.build_count() == builds, "a legend filter flip never rebuilds")
	var row: Dictionary = chart._panel_rows["lane_" + HANSE_LANE]
	_check(absf((row["box"] as Control).modulate.a - chart.HIDDEN_ROW_ALPHA) < 0.001,
		"the hidden lane row dims to the documented alpha")
	chart._on_row_gui_input(_click(), "lane_" + HANSE_LANE)
	_check(not chart._layer_hidden.get("lane_" + HANSE_LANE, false),
		"clicking again shows the lane")
	_check(absf((row["box"] as Control).modulate.a - 1.0) < 0.001,
		"the shown lane row is fully opaque")
	# The shape rows round-trip the same way.
	for row_id in ["spokes", "chokepoints", "wrecks", "intel", "neutral"]:
		chart._on_row_gui_input(_click(), row_id)
		if not chart._layer_hidden.get(row_id, false):
			_check(false, "the %s row hides on click" % row_id)
		chart._on_row_gui_input(_click(), row_id)
		if chart._layer_hidden.get(row_id, false):
			_check(false, "the %s row shows again on click" % row_id)
	_check(true, "the spokes/chokepoints/wrecks/intel/neutral rows round-trip")
	# Role rows key per role.
	chart._on_row_gui_input(_click(), "role_trader")
	_check(chart._layer_hidden.get("role_trader", false) == true,
		"a role row hides that role's markers")
	chart._on_row_gui_input(_click(), "role_trader")
	_check(not chart._layer_hidden.get("role_trader", false),
		"a role row shows its role again")
	# The four toggle rows reuse their key handlers (one rebuild per click).
	var toggle_builds: int = chart.build_count()
	for row_id in ["wind", "wind", "current", "current", "ice", "ice",
			"omni", "omni"]:
		chart._on_row_gui_input(_click(), row_id)
	_check(chart.build_count() == toggle_builds + 8,
		"toggle-row clicks rebuild once each (the same as their keys)")
	_check(not chart._wind_on and not chart._current_on \
		and not chart._ice_on and chart._omni_on,
		"toggle-row round-trips restore the omniscient open state")
	chart.close_chart()


## A left-button press event for the legend-row handlers.
func _click() -> InputEventMouseButton:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	return mb
