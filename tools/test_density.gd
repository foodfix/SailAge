extends Node
## Phase-5 task M acceptance tests: the density dial UI (S19 modal on S1 and
## S4; amended 2026-10-31 — S2 has no density row) and the measured scaling
## proof.
## (docs/80-UI-UX.md §4.6.3/§4.2/§4.3/§4.7/§4.7.9; docs/60-COMBAT.md §4.1.2,
## §4.11.11.5; docs/10-DATA-SCHEMA.md §4.10; docs/90-* §8.1 `npc_preset`.)
##
##   godot --headless res://tools/test_density.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 the S19 mounts (S1 pre-game applies before new_game; S4 mid-run) and
##     the absence of any S2 density row;
##   2 preset round-trip through the save payload (all five presets);
##   3 the initial fill ≈ half the core cap at normal (the seeded count);
##   4 mid-run semantics through S19 (raise refills via the trickle, lowering
##     never culls, deserted = zero spawns + zero contacts, deserted → extreme
##     repopulates over days);
##   5 the S19 modal over S4 (footer entry, modal rule, Esc, zh/en);
##   6 the perf gates (docs/60-* §4.11.11.5): day tick ≤ 50 ms @ normal cap
##     288, ≤ 150 ms @ extreme, linear marginal cost, save ≤ 2 MB @ extreme.
##
## Isolation: this suite never writes `user://` (the save round-trip and the
## payload-size gate serialize through `SaveSystem.snapshot()` to a string),
## so it is safe to run in parallel with the serial-save suites.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const NationalityScene := preload("res://scenes/title/nationality_select.tscn")
const TitleScene := preload("res://scenes/title/title_screen.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")
const SettingsScene := preload("res://scenes/ui_shared/settings_panel.tscn")

## The five locked presets (docs/10-* §4.10), in `npc_config.json` order.
const PRESETS: Array[String] = [
	"deserted", "low", "normal", "high", "extreme",
]

## Open water in the world map's variables band, far from every harbor.
const OPEN_CELL := Vector2i(700, 320)

## The perf gates (docs/60-* §4.11.11.5). ≥ 30 timed ticks each; kept modest
## so the whole suite stays well under a minute.
const PERF_TICKS := 35
const GATE_NORMAL_MS := 50.0
const GATE_EXTREME_MS := 150.0
## Marginal cost ≈ linear: extreme (×4 fleets) must stay under 8× the normal
## average (16× would be quadratic).
const LINEARITY_RATIO := 8.0
const GATE_SAVE_BYTES := 2 * 1024 * 1024

const WATCHDOG_SECONDS := 240.0

var _failures: Array[String] = []
var _checks := 0
var _watchdog: Timer = null
var _section := "<startup>"


func _ready() -> void:
	_arm_watchdog()
	_section = "map load"
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "map loads for the density fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	NpcFleetsLib.reset_caches()

	_section = "1 S2 density row"
	await _test_s2_row()
	_section = "2 preset save round-trip"
	_test_preset_round_trip()
	_section = "3 initial fill at normal"
	_test_initial_fill()
	_section = "4 mid-run semantics"
	_test_mid_run()
	_section = "5 S19 modal over S4"
	await _test_s19_modal()
	_section = "6 perf gates"
	_test_perf_gates()
	_section = "report"
	_report()


func _arm_watchdog() -> void:
	_watchdog = Timer.new()
	_watchdog.name = "Watchdog"
	_watchdog.one_shot = true
	_watchdog.wait_time = WATCHDOG_SECONDS
	_watchdog.timeout.connect(_on_watchdog)
	add_child(_watchdog)
	_watchdog.start()


func _on_watchdog() -> void:
	print("")
	print("WATCHDOG: no report after %.0f s — the suite stalled in section '%s'"
		% [WATCHDOG_SECONDS, _section])
	print("%d checks ran, %d failures so far:" % [_checks, _failures.size()])
	for failure in _failures:
		print("  - ", failure)
	_failures.append("WATCHDOG: stalled in section '%s'" % _section)
	get_tree().quit(1)


# --- Fixtures ---------------------------------------------------------------

## A fresh run at `preset`, docked nowhere, day 1 — the `GameState.new_game`
## path (so the initial fill respects the preset), with routing off.
func _make_run(preset: String = "normal") -> NpcFleetsLib:
	GameState.npc_preset = preset
	GameState.new_game("portugal", false)
	return _sim_for_preset(preset)


## The sim the way the world scene builds it (one per scene entry, reading
## `GameState.npc_preset` at construction — `world_map._init_fleets`).
func _sim_for_preset(preset: String) -> NpcFleetsLib:
	return NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": preset,
	})


## Ticks `days` days through one sim, mirroring the world scene's
## one-tick-per-day call. Returns the ids spawned across the window.
func _tick_days(sim: NpcFleetsLib, from_day: int, days: int) -> Array:
	var spawned: Array = []
	for offset in days:
		var day := from_day + offset
		GameState.day = day
		spawned.append_array(sim.tick(day))
	return spawned


func _fleet_ids() -> Array:
	var ids: Array = []
	for fleet in GameState.npc_fleets:
		ids.append(str(fleet.get("id", "")))
	return ids


func _count_role(role: String) -> int:
	var count := 0
	for fleet in GameState.npc_fleets:
		if str(fleet.get("role", "")) == role:
			count += 1
	return count


# --- 1. Settings mounts: S1 pre-game + S4 mid-run (80-* §4.6.3 amended) ------

func _test_s2_row() -> void:
	# Amended 2026-10-31: S2 is the nationality grid only; the sea-traffic
	# dial lives in S19, mounted on S1 (pre-game) and S4 (mid-run).
	var s2 = NationalityScene.instantiate()
	add_child(s2)
	await get_tree().process_frame
	_check(s2.get_node_or_null("Layout/DensityRow") == null,
		"S2 no longer carries a density row (80-* §4.6.3 amended)")
	_check(s2.get_node_or_null("Layout/Cards") != null,
		"S2 still renders the nationality cards")
	s2.queue_free()
	await get_tree().process_frame

	# S1 mount: the Settings button opens the panel; no return action there.
	var title = TitleScene.instantiate()
	title.route_to_nationality = false
	add_child(title)
	await get_tree().process_frame
	var panel = title.open_settings_panel()
	_check(panel != null, "the S1 Settings button opens the S19 panel")
	if panel != null:
		_check((panel as Control).visible, "the S1-hosted panel opens visible")
		_check(not panel.call("host_is_port"),
			"the S1 mount is not a port host")
		_check(not (panel.call("return_button") as Control).is_visible_in_tree(),
			"the S1 mount hides 'Return to main menu' (no run to leave)")
		_check(panel.call("locale_button") != null,
			"the S1 mount carries the language toggle")
		_check(title.get_node_or_null("Center/Stack/Buttons/Language") == null,
			"S1 no longer has its own language button")
		_check(s2.get_node_or_null("Layout/Footer/Lang") == null,
			"S2 no longer has its own language button")
		# A pre-game choice writes the run input before new_game.
		_check(panel.call("apply_preset", "extreme"),
			"the S1 panel applies a preset")
		_check(GameState.npc_preset == "extreme",
			"the S1 choice writes GameState.npc_preset before a new game")
		s2 = NationalityScene.instantiate()
		s2.route_after_confirm = false
		add_child(s2)
		await get_tree().process_frame
		var extreme_sim := _sim_for_preset("extreme")
		var normal_fill := _sim_for_preset("normal").fleets().size()
		s2.confirm_selection()
		var extreme_fill: int = GameState.npc_fleets.size()
		var extreme_half: int = extreme_sim.core_cap() / 2
		_check(extreme_fill <= extreme_half and extreme_fill >= extreme_half - 8,
			"the pre-game extreme choice survives new_game's fill (target %d, seeded exact %d)"
			% [extreme_half, extreme_fill])
		_check(extreme_fill > 2 * normal_fill,
			"the extreme fill is visibly multiplied (%d vs %d at normal)"
			% [extreme_fill, normal_fill])
		panel.call("apply_preset", "deserted")
		s2.confirm_selection()
		_check(GameState.npc_fleets.is_empty(),
			"a deserted pre-game choice starts with zero fleets")
		s2.queue_free()
		await get_tree().process_frame
	title.queue_free()
	await get_tree().process_frame


# --- 2. Preset round-trip through the save payload (docs/90-* §8.1) ----------

func _test_preset_round_trip() -> void:
	_make_run("normal")
	for preset in PRESETS:
		GameState.npc_preset = preset
		# The same path a slot write/read takes: snapshot → JSON text →
		# parse → normalize_numbers (Godot's JSON yields floats for every
		# number — `_parse_slot` runs the same coercion) → validate → apply.
		# No file I/O, so parallel suites that do write slots are never
		# contended with.
		var text := JSON.stringify(SaveSystem.snapshot(), "\t")
		var parsed = JSON.parse_string(text)
		_check(parsed is Dictionary, "the %s payload parses" % preset)
		if not parsed is Dictionary:
			continue
		var data: Dictionary = SaveSystem.normalize_numbers(parsed)
		var reason := SaveSystem.validate_payload(data)
		_check(reason.is_empty(),
			"the %s payload validates (%s)" % [preset, reason])
		if reason.is_empty():
			SaveSystem._apply(data)
			_check(GameState.npc_preset == preset,
				"'%s' survives the save/load round-trip (got '%s')"
				% [preset, GameState.npc_preset])
	# An unknown preset never enters the payload through the panel's apply
	# (S19 refuses it), and a hand-edited save is refused by validation.
	var panel := SettingsScene.instantiate()
	add_child(panel)
	_check(not panel.apply_preset("ludicrous"),
		"S19 refuses an unknown preset id")
	panel.queue_free()


# --- 3. The initial fill at normal (docs/60-* §4.1.2) ------------------------

func _test_initial_fill() -> void:
	var sim := _make_run("normal")
	_check(sim.core_cap() == 272,
		"the normal core cap is 272 (got %d)" % sim.core_cap())
	var half: int = sim.core_cap() / 2
	var filled: int = GameState.npc_fleets.size()
	# The fill targets exactly half the cap; a failed spawn draw (no legal
	# tile that day) can leave a handful short — the replay below pins the
	# seeded exact count as deterministic.
	_check(filled <= half and filled >= half - 8,
		"new_game seeds ≈ half the core cap (target %d, seeded exact %d)"
		% [half, filled])
	# Determinism of the seeded count: an independent replay refills identically
	# (the same day/world seed family — the test_npc_fleets §2 pattern).
	var first: Array = GameState.npc_fleets.duplicate(true)
	GameState.npc_fleets = []
	_sim_for_preset("normal").initial_fill(1)
	_check(GameState.npc_fleets.size() == filled,
		"the seeded fill count is deterministic (%d vs %d)"
		% [GameState.npc_fleets.size(), filled])
	var same := true
	for index in mini(first.size(), GameState.npc_fleets.size()):
		if str((first[index] as Dictionary).get("id", "")) \
				!= str((GameState.npc_fleets[index] as Dictionary).get("id", "")):
			same = false
			break
	_check(same, "the seeded fill replays the same fleet ids")


# --- 4. Mid-run semantics through S19 (docs/80-* §4.6.3, docs/60-* §4.1.2) ---

func _test_mid_run() -> void:
	# Raise: normal → high. The trickle refills toward the NEW budgets over
	# days (max(4, ceil(cap/50)) per day), on the world-scene seam path
	# (S19 writes GameState; the next sim is constructed with the new preset).
	var sim := _make_run("normal")
	var high_cap := _sim_for_preset("high").global_cap()
	var settled := _drive_to_cap(sim, 2, 200, sim.core_cap())
	var at_normal: int = GameState.npc_fleets.size()
	_apply_preset_via_s19("high")
	# The live sim re-budgets through the set_preset seam (a host that keeps
	# its sim across the change); the world scene rebuild path is exercised
	# by discarding and re-creating below.
	sim.set_preset("high")
	_check(sim.trickle_per_day() >= 4,
		"the high trickle stays ≥ 4/day (got %d)" % sim.trickle_per_day())
	var growth := _tick_days(sim, settled + 1, 20)
	var raised: int = GameState.npc_fleets.size()
	_check(raised > at_normal and not growth.is_empty(),
		"normal → high repopulates over days via the trickle (%d → %d, %d spawns)"
		% [at_normal, raised, growth.size()])
	_check(raised >= at_normal + sim.trickle_per_day() * 8,
		"the raise grows visibly toward the new budget (%d → %d, cap %d)"
		% [at_normal, raised, high_cap])

	# Lower: high → low. Living fleets are NEVER culled — named fleets the
	# ecology's own combat can never remove (coasters are ignored by raiders,
	# couriers are not prey, docs/60-* §4.1.1) must all survive the window.
	var named := _seed_named_fleets(sim, ["cst_keep_1", "cst_keep_2",
		"crs_keep_1"])
	var before_lower: Array = _fleet_ids()
	var low_cap := _sim_for_preset("low").global_cap()
	_apply_preset_via_s19("low")
	sim.set_preset("low")
	var lower_day := GameState.day + 1
	_tick_days(sim, lower_day, 15)
	for id in named:
		var alive: bool = id in _fleet_ids()
		_check(alive, "lowering high → low never culls '%s'" % id)
	var after_lower: int = GameState.npc_fleets.size()
	_check(after_lower <= before_lower.size() + 5,
		"the lower preset spawns almost nothing (%d → %d, low cap %d)"
		% [before_lower.size(), after_lower, low_cap])

	# Deserted: zero spawns, zero contacts — while every living fleet stays
	# (the deserted tick returns before any stepping, so the id set freezes).
	var player_cell := OPEN_CELL
	GameState.set_world_tile(player_cell)
	var pirate := _seed_pirate_beside(sim, player_cell)
	var pre_deserted_ids: Array = _fleet_ids()
	_check(not sim.contacts(player_cell).is_empty(),
		"the seeded pirate is a live contact before the dial drops (control)")
	_apply_preset_via_s19("deserted")
	sim.set_preset("deserted")
	var deserted_day := GameState.day + 1
	var spawned := _tick_days(sim, deserted_day, 6)
	_check(spawned.is_empty(), "deserted spawns nothing over 6 days")
	_check(_fleet_ids() == pre_deserted_ids,
		"deserted freezes the ecology — no fleet is removed or added")
	_check(sim.contacts(player_cell).is_empty()
		and sim.nearest_contact(player_cell).is_empty(),
		"deserted yields zero NPC contacts beside a hostile fleet")
	_check(str(pirate.get("id", "")) in _fleet_ids(),
		"the deserted dial never removes the living pirate")

	# Deserted → extreme: visibly repopulates over days.
	_apply_preset_via_s19("extreme")
	var extreme_sim := _sim_for_preset("extreme")
	var from_frozen: int = GameState.npc_fleets.size()
	var window := 30
	var counts := [from_frozen]
	for offset in window:
		GameState.day = GameState.day + 1
		extreme_sim.tick(GameState.day)
		counts.append(GameState.npc_fleets.size())
	var grew: bool = counts[0] < counts[5] and counts[5] < counts[window]
	_check(grew,
		"deserted → extreme repopulates over days (%d → %d → %d)"
		% [counts[0], counts[5], counts[window]])
	_check(counts[window] >= int(0.85 * float(extreme_sim.core_cap())),
		"the extreme refill reaches ≈ the extreme budget (%d → %d, core cap %d)"
		% [from_frozen, counts[window], extreme_sim.core_cap()])


## Applies a preset exactly the way S19 does (the real panel's apply path),
## on a standalone panel instance.
func _apply_preset_via_s19(preset: String) -> void:
	var panel := SettingsScene.instantiate()
	add_child(panel)
	panel.apply_preset(preset)
	panel.queue_free()


## Ticks until the ecology reaches `target` fleets (or `max_days`), then
## returns the last day used — the §14 test_npc_fleets settle loop.
func _drive_to_cap(sim: NpcFleetsLib, from_day: int, max_days: int,
		target: int) -> int:
	var day := from_day
	for offset in max_days:
		day = from_day + offset
		GameState.day = day
		sim.tick(day)
		if GameState.npc_fleets.size() >= target:
			return day
	return day


## Seeds fleets with fixed ids in roles the ecology's own auto-resolve can
## never remove (coaster: raiders ignore; courier: not prey — docs/60-*
## §4.1.1), so a missing id can only mean the dial culled it.
func _seed_named_fleets(sim: NpcFleetsLib, ids: Array) -> Array:
	var seeded: Array = []
	for id in ids:
		var role := "coaster" if str(id).begins_with("cst_") else "courier"
		var fleet := {
			"id": str(id), "role": role, "nation_id": "portugal",
			"cell": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
			"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
			"cargo": {}, "captain": {"pool_id": "portugal", "name_index": 0},
			"cooldown_until_day": 0, "seed": 777, "dest_port_id": "",
			"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
			"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
		}
		GameState.npc_fleets.append(fleet)
		seeded.append(str(id))
	sim.reset_index()
	return seeded


## A hostile fleet on the tile beside the player (contact range is
## Chebyshev 1, docs/60-* §4.11.11.2).
func _seed_pirate_beside(sim: NpcFleetsLib, player_cell: Vector2i) -> Dictionary:
	var pirate := {
		"id": "pir_beside_1", "role": "pirate", "nation_id": "",
		"cell": {"x": player_cell.x + 1, "y": player_cell.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {}, "captain": {"pool_id": "", "name_index": 0},
		"cooldown_until_day": 0, "seed": 999, "dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
		"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
	}
	GameState.npc_fleets.append(pirate)
	sim.reset_index()
	return pirate


# --- 5. The S19 modal over S4 (docs/80-* §4.6.3) -----------------------------

func _test_s19_modal() -> void:
	_make_run("normal")
	var port = PortScene.instantiate()
	add_child(port)
	await get_tree().process_frame
	# §4.6.3: a Settings button in the footer beside Officers, opening S19.
	var row: Button = port.settings_row()
	_check(row != null, "the S4 hub renders the Settings footer row")
	if row == null:
		port.queue_free()
		return
	_check(not row.disabled, "the Settings row is enabled with a run docked")
	_check(row.text == I18n.t_key("settings.title"),
		"the Settings row uses settings.title")
	var panel: Control = port.open_settings_panel()
	_check(panel != null and panel.is_open(),
		"the footer row opens the S19 modal")
	_check(port.has_modal(), "S4 reports the modal while S19 is open")
	_check(panel.preset_ids() == PRESETS,
		"S19 lists the five locked presets in order (%s)"
		% ", ".join(panel.preset_ids()))
	# The current line formats with the localised preset name.
	var current_label: Label = panel.get_node(
		"Center/Panel/Margin/Body/Density/Current")
	var current_expected := I18n.fmt("settings.density.current",
		{"preset": I18n.t_key("settings.density.normal")})
	_check(current_label.text == current_expected,
		"the current-preset line formats settings.density.current ('%s' vs '%s')"
		% [current_label.text, current_expected])
	# Applying mid-run goes through GameState.npc_preset (the field sims read
	# at construction and the save persists).
	panel.apply_preset("high")
	_check(GameState.npc_preset == "high",
		"S19 applies the preset mid-run into GameState.npc_preset")
	# Amended 2026-10-31: S19 owns the ONLY language toggle — the old `L`
	# hotkeys and the top-bar/S1/S2/market buttons are gone.
	_check(panel.locale_button() != null,
		"S19 carries the language toggle")
	_check(port.get_node_or_null("Layout/VBox/Header/Lang") == null,
		"the market header no longer carries a language button")
	var hud = port.get_node_or_null("HUD")
	if hud != null:
		_check(hud.get_node_or_null("TopRow/LangButton") == null,
			"the HUD top bar no longer carries a language button")
	var locale_before: String = I18n.get_locale()
	panel.locale_button().pressed.emit()
	_check(I18n.get_locale() != locale_before,
		"the S19 toggle flips the locale (%s -> %s)"
		% [locale_before, I18n.get_locale()])
	panel.locale_button().pressed.emit()
	# zh/en: every label rebinds on locale_changed with no <key> fallbacks.
	var title: Label = panel.get_node("Center/Panel/Margin/Body/Title")
	var before_toggle: String = title.text
	I18n.toggle_locale()
	var other_title: String = title.text
	var other_expected: String = I18n.t_key("settings.title")
	I18n.toggle_locale()
	_check(other_title == other_expected and not "<" in other_title
		and title.text == before_toggle,
		"the S19 title rebinds on locale change without fallbacks ('%s' ↔ '%s')"
		% [before_toggle, other_title])
	# §4.3: Esc closes back to S4 (same edge as Close).
	var back := InputEventAction.new()
	back.action = "back"
	back.pressed = true
	panel._unhandled_input(back)
	_check(not panel.is_open() and not port.has_modal(),
		"Esc closes S19 back to S4")
	panel.open()
	panel.close()
	_check(not port.has_modal(), "Close leaves S4 without a modal")
	# S4 mount: the return-to-menu action is visible, confirm-first, and its
	# confirmation names the unsaved-progress risk (amended §4.6.3).
	panel.route_to_menu = false
	panel.open()
	var ret: Button = panel.return_button()
	_check(ret != null and ret.is_visible_in_tree(),
		"the S4 mount shows 'Return to main menu'")
	if ret != null:
		_check(ret.text == I18n.t_key("settings.return_menu"),
			"the return action uses settings.return_menu")
		var dlg: Control = panel.open_return_confirm()
		_check(dlg != null and dlg.is_visible_in_tree(),
			"the return action opens a confirm dialog first")
		var warned := I18n.t_key("settings.return_menu.confirm")
		_check(warned.contains("Unsaved") or warned.contains("未保存"),
			"the confirm text names the lost-unsaved-progress risk")
		# Cancel leaves the run alone; confirm emits the signal and closes.
		dlg.call("cancel")
		_check(not dlg.is_visible_in_tree() and panel.is_open(),
			"cancelling the return confirm leaves S19 open")
		var returned: Array = []
		var on_return := func() -> void: returned.append(true)
		panel.return_to_menu.connect(on_return)
		dlg = panel.open_return_confirm()  # cancel closed it; reopen
		dlg.call("accept")
		panel.return_to_menu.disconnect(on_return)
		_check(returned.size() == 1 and not panel.is_open(),
			"confirming routes out of the panel and emits return_to_menu")
	_check(panel.host_is_port(), "the S4 mount reports a port host")
	# The standalone footer row greys out (no run docked).
	GameState.current_port = null
	EventBus.day_advanced.emit(GameState.day)
	await get_tree().process_frame
	_check(port.settings_row().disabled,
		"the Settings row greys out with no run docked")
	port.queue_free()
	await get_tree().process_frame


# --- 6. The perf gates (docs/60-* §4.11.11.5) --------------------------------

func _test_perf_gates() -> void:
	# Normal: settled at cap 288, ≥ 30 timed ticks.
	var sim := _make_run("normal")
	var settled_day := _drive_to_cap(sim, 2, 220, sim.core_cap())
	var n_normal: int = GameState.npc_fleets.size()
	var normal_avg := _timed_ticks(sim, settled_day + 1, PERF_TICKS)
	print("  normal probe: %d fleets, avg %.1f ms/tick"
		% [n_normal, normal_avg])
	print("PROFILE density_normal_avg_ms %d" % int(round(normal_avg)))
	_check(n_normal >= 250,
		"the normal probe runs at the filled cap (%d fleets)" % n_normal)
	_check(normal_avg <= GATE_NORMAL_MS,
		"the day tick averages ≤ %.0f ms at cap 288 (%.1f ms over %d ticks)"
		% [GATE_NORMAL_MS, normal_avg, PERF_TICKS])

	# Extreme: ×4 budgets (~4× fleets), ≤ 150 ms, linear marginal cost.
	_apply_preset_via_s19("extreme")
	sim.set_preset("extreme")
	var extreme_target := _sim_for_preset("extreme").core_cap()
	var extreme_day := _drive_to_cap(sim, settled_day + PERF_TICKS + 1, 120,
		extreme_target)
	var n_extreme: int = GameState.npc_fleets.size()
	var extreme_avg := _timed_ticks(sim, extreme_day + 1, PERF_TICKS)
	print("  extreme probe: %d fleets, avg %.1f ms/tick"
		% [n_extreme, extreme_avg])
	print("PROFILE density_extreme_avg_ms %d" % int(round(extreme_avg)))
	_check(n_extreme >= 3 * n_normal,
		"the extreme probe runs at ≈ 4× the normal fleets (%d vs %d)"
		% [n_extreme, n_normal])
	_check(extreme_avg <= GATE_EXTREME_MS,
		"the day tick averages ≤ %.0f ms at extreme (%.1f ms over %d ticks)"
		% [GATE_EXTREME_MS, extreme_avg, PERF_TICKS])
	_check(extreme_avg < LINEARITY_RATIO * maxf(normal_avg, 0.001),
		"marginal cost is linear: extreme %.1f ms < %.0f× normal %.1f ms"
		% [extreme_avg, LINEARITY_RATIO, normal_avg])

	# Save payload @ extreme ≤ 2 MB, measured on the exact slot-write bytes.
	var payload_bytes: int = JSON.stringify(
		SaveSystem.snapshot(), "\t").to_utf8_buffer().size()
	print("  extreme save payload: %d bytes (%.2f MB)"
		% [payload_bytes, payload_bytes / 1048576.0])
	print("PROFILE density_extreme_save_bytes %d" % payload_bytes)
	_check(payload_bytes <= GATE_SAVE_BYTES,
		"the save payload at extreme stays ≤ 2 MB (%d bytes)" % payload_bytes)


## Times `ticks` day ticks, returns the average ms (each tick exactly the
## `sim.tick(day)` call — the world scene's per-day work).
func _timed_ticks(sim: NpcFleetsLib, from_day: int, ticks: int) -> float:
	var total_ms := 0.0
	for offset in ticks:
		var day := from_day + offset
		GameState.day = day
		var started := Time.get_ticks_usec()
		sim.tick(day)
		total_ms += float(Time.get_ticks_usec() - started) / 1000.0
	return total_ms / float(ticks)


# --- Report ------------------------------------------------------------------

func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  ok  %s" % label)
	else:
		_failures.append(label)
		print("  FAIL %s" % label)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d of %d checks FAILED:" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - ", failure)
		get_tree().quit(1)
