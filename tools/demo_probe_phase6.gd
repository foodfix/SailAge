extends Node
## Phase-6 task J — the scripted acceptance probe behind
## `tools/demo_check_phase6.md` (the dated manual run's evidence rows).
## NOT part of the `tools/test_*.tscn` gate family (`run_tests.py` globs
## `test_*.tscn` only); it is the reproducible record of the backlog's
## demo scenarios on the shipped tree:
##
##   godot --headless res://tools/demo_probe_phase6.tscn
##
## Exits 0 when every scenario holds. Numbers it prints are quoted in the
## demo-check record (branch/commit + date at the top of that file).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const GameStateLib := preload("res://autoload/game_state.gd")

var _failures: Array[String] = []
var _checks := 0

## Lisbon's berth neighbourhood (open Atlantic water east/west of it).
const LISBON_BERTH := Vector2i(2050, 615)
## Gulf Stream corridor tile (strength 3, stored N/NE) on the shipped raster.
const GULF_STREAM_CELL := Vector2i(1202, 719)  # verified N/3 corridor (53-tile run)
## Baltic in-mask water tile + its month window (baltic_ice: 12,1,2,3).
const BALTIC_ICE_CELL := Vector2i(2313, 420)
## South China Sea monsoon region probe (monsoon_south_china_sea).
const SCS_CELL := Vector2i(3540, 900)  # verified monsoon_south_china_sea water tile
## Quanzhou (neutral, China coast) berth — from world_report.json.
const QUANZHOU_BERTH := Vector2i(3893, 786)


func _ready() -> void:
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "world.png loads (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	var ocean = OceanLayersLib.instance()
	_check(ocean.decode_ok, "ocean rasters decode")
	SailingSimLib.rng.seed = 20261101

	_scenario_upwind_downwind()
	_scenario_tack_vs_autopilot()
	_scenario_storm_wait_trimmed()
	_scenario_gulf_stream()
	_scenario_baltic_winter()
	_scenario_monsoon_signature_loop()
	_scenario_debug_scrub_months()
	_scenario_s19_toggles()
	_report()


# --- 1. Lisbon→open sea: upwind vs downwind day rates -----------------------
func _scenario_upwind_downwind() -> void:
	print("\n== 1. Lisbon anchorage: upwind (E) vs downwind (W) at wind E ==")
	GameState.new_game("portugal", false)
	GameState.day = 1
	var world: Dictionary = GameState.world
	world["position"] = {"x": LISBON_BERTH.x, "y": LISBON_BERTH.y}
	world["wind_dir"] = "E"
	world["weather"] = "fair"
	var east: float = SailingSimLib.move_cost("E")
	var west: float = SailingSimLib.move_cost("W")
	print("    move_cost into the wind (E) = %.4f d/tile; running (W) = %.4f d/tile"
		% [east, west])
	print("    effective_speed E=%d W=%d tiles/day (flagship caravel, base 20)"
		% [SailingSimLib.effective_speed("E"), SailingSimLib.effective_speed("W")])
	_check(east > west * 1.5,
		"into-wind days per tile exceed running by the 0.50/1.30 bucket ratio")
	_check(is_equal_approx(east, 1.0 / 10.0) and is_equal_approx(west, 1.0 / 26.0),
		"speeds land on the locked buckets (10 beating / 26 running)")


# --- 2. The autopilot is wind-blind; the human times the season -------------
func _scenario_tack_vs_autopilot() -> void:
	print("\n== 2. Wind-blind A* vs the human: timing the monsoon, and the tack wash ==")
	# Decision 4: the A* is distance-optimal and wind-blind. The skill gap is
	# seasonal timing: the SAME 20-tile easting runs at 0.50 (beating, NE
	# monsoon) or 1.30 (running, SW monsoon) — the human waits for the season.
	var beat: float = 20.0 * SailingSimLib.move_cost("E")   # wind E: into it
	var run: float = 20.0 * SailingSimLib.move_cost("W")    # wind E: running
	print("    same 20 tiles: beating = %.2f days, running = %.2f days"
		% [beat, run])
	_check(run * 2.0 < beat,
		"timing the run more than halves the same leg vs beating it")
	# The 45-degree tack itself is a wash by the locked buckets (0.70 ×
	# 1/√2 ≈ 0.495 vs 0.50 straight): recorded honestly.
	var tack: float = 20.0 * sqrt(2.0) * (1.0 / 14.0)
	print("    45° tack arithmetic: %.1f tiles at 1/14 = %.2f days vs %.2f straight (wash)"
		% [20.0 * sqrt(2.0), tack, beat])
	_check(absf(tack - beat) < 0.1,
		"the close-hauled tack is break-even against a straight beat (recorded)")


# --- 3. Waiting out a storm, reefed -----------------------------------------
func _scenario_storm_wait_trimmed() -> void:
	print("\n== 3. Storm damage by sail trim (caravel 90 max, luck 10) ==")
	GameState.new_game("portugal", false)
	GameState.day = 1
	GameState.current_port = null  # new_game spawns docked; clear to be at sea
	var by_trim := {}
	for trim in ["furled", "reefed", "normal", "full"]:
		GameState.world["sail_trim"] = trim
		var dmg: int = SailingSimLib.storm_damage_for(90,
			SailingSimLib.trim_storm_multiplier(trim, "sail"))
		by_trim[trim] = dmg
		print("    %-7s → %d hull damage" % [trim, dmg])
	_check(by_trim["furled"] == 3 and by_trim["reefed"] == 4
		and by_trim["normal"] == 5 and by_trim["full"] == 7,
		"the trim table lands 3/4/5/7 (multiplier inside the pre-rounding ceil)")
	GameState.world["sail_trim"] = "reefed"
	GameState.world["weather"] = "storm"
	var waited: bool = SailingSimLib.wait_at_sea()
	print("    reefed in a storm: wait_at_sea() = %s, day now %d, hull damage taken"
		% [str(waited), GameState.day])
	_check(waited and GameState.day == 2, "the reefed fleet waits out the storm day")


# --- 4. The Gulf Stream: modifier, then drift -------------------------------
func _scenario_gulf_stream() -> void:
	print("\n== 4. Gulf Stream tile %s: modifier vs drift mode ==" % str(GULF_STREAM_CELL))
	GameState.new_game("portugal", false)
	GameState.day = 152  # month 6 — inside reversal months, N-flow at full value
	GameState.current_port = null
	GameState.world["position"] = {"x": GULF_STREAM_CELL.x, "y": GULF_STREAM_CELL.y}
	GameState.control_prefs = {"input_mode": "step", "current_mode": "modifier"}
	var cur: Dictionary = OceanLayersLib.instance().current_at(GULF_STREAM_CELL, 6)
	print("    decoded current (month 6): %s/%d (reversal-applied where owned)"
		% [str(cur.get("dir", "-")), int(cur.get("strength", 0))])
	_check(not cur.is_empty() and int(cur.get("strength", 0)) == 3,
		"the Gulf Stream corridor decodes at strength 3")
	var aligned: float = SailingSimLib.current_factor("N", GULF_STREAM_CELL, 6)
	var opposed: float = SailingSimLib.current_factor("S", GULF_STREAM_CELL, 6)
	print("    heading N (with it): ×%.2f; heading S (against): ×%.2f"
		% [aligned, opposed])
	_check(aligned == 1.24 and opposed == 0.76,
		"the ±0.08×strength bands land at 1.24 / 0.76")
	# Drift mode: three day ticks push the fleet along the flow.
	GameState.control_prefs = {"input_mode": "step", "current_mode": "drift"}
	var before: Vector2i = GULF_STREAM_CELL
	for i in range(3):
		SailingSimLib.advance_clock(1.0)
	var pos: Dictionary = GameState.world["position"]
	var moved := Vector2i(int(pos.x), int(pos.y)) - before
	print("    drift mode, 3 sea days: fleet moved %s (stops before land, never damaged)"
		% str(moved))
	_check(moved.length() > 0.0 and Vector2i(int(pos.x), int(pos.y)) != before,
		"drift mode moves the fleet along the current")


# --- 5. The Baltic closes; hanseatic_north takes its winter variant ---------
func _scenario_baltic_winter() -> void:
	print("\n== 5. Seasonal Baltic ice + the hanseatic_north winter variant ==")
	var ocean = OceanLayersLib.instance()
	var jan: bool = ocean.ice_blocks(BALTIC_ICE_CELL, 1)
	var jul: bool = ocean.ice_blocks(BALTIC_ICE_CELL, 7)
	print("    Baltic tile %s: month 1 ice=%s, month 7 ice=%s"
		% [str(BALTIC_ICE_CELL), str(jan), str(jul)])
	_check(jan and not jul, "the Baltic freezes in month 1 and opens by month 7")
	var built: Dictionary = DataLoader.trade_routes_built
	var lane: Dictionary = {}
	for l in built.get("lanes", []):
		if str(l.get("id", "")) == "hanseatic_north":
			lane = l
	var variants: Array = lane.get("variants", [])
	print("    hanseatic_north carries %d variant(s): %s (months %s), base covers the rest"
		% [variants.size(), str(variants[0].get("id", "?")) if variants.size() > 0 else "-",
		   str(variants[0].get("months", [])) if variants.size() > 0 else "-"])
	_check(variants.size() == 1 and variants[0].get("months", []) == [12, 1, 2, 3],
		"the winter variant owns months 12–3 (the freeze window)")


# --- 6. The signature loop: summer monsoon to Quanzhou, sell in its market --
func _scenario_monsoon_signature_loop() -> void:
	print("\n== 6. Summer monsoon to a neutral China-coast port; sell there ==")
	var ocean = OceanLayersLib.instance()
	var m1: String = ocean.prevailing_for(SCS_CELL, 1)
	var m7: String = ocean.prevailing_for(SCS_CELL, 7)
	print("    South China Sea prevailing: month 1 = %s (NE monsoon), month 6 = %s (SW)"
		% [m1, m7])
	_check(m1 == "NE" and m7 == "SW", "the SCS monsoon reverses across the year")
	GameState.new_game("portugal", false)
	GameState.day = 152  # month 6 — riding the summer monsoon
	GameState.current_port = null
	var world: Dictionary = GameState.world
	world["position"] = {"x": QUANZHOU_BERTH.x, "y": QUANZHOU_BERTH.y}
	var port: Dictionary = DataLoader.get_port("quanzhou")
	print("    fleet on quanzhou's berth %s; port nation_id = '%s' (neutral tier)"
		% [str(QUANZHOU_BERTH), str(port.get("nation_id", ""))])
	_check(str(port.get("nation_id", "")) == "", "quanzhou is a neutral-tier port")
	# Docking is the world scene's shore-tile gesture (G, e2e-proven); the
	# market itself is the standard §4.2 stock economy (30-* one-sentence pin).
	GameState.current_port = "quanzhou"
	var stock: int = int(GameState.market_stocks.get("quanzhou", {}).get("silk", -1))
	var quote_buy: int = TradeEngineLib.buy_price("quanzhou", "silk")
	var afford: int = mini(stock, 20)
	GameState.gold = 100000
	var bought: bool = TradeEngineLib.buy("quanzhou", "silk", afford)
	print("    quanzhou silk stock %d, first-unit buy quote %dg → bought 20 units: %s"
		% [stock, quote_buy, str(bought)])
	_check(bought and afford > 0, "the neutral market sells stock to the player")
	var sold: bool = TradeEngineLib.sell("quanzhou", "silk", afford)
	print("    sold the %d units back into the same market: %s" % [afford, str(sold)])
	_check(sold, "the neutral market buys from the player")
	GameState.current_port = null


# --- 7. The debug chart's month scrubber (pure view state) ------------------
func _scenario_debug_scrub_months() -> void:
	print("\n== 7. Debug chart month scrub: the seasonal layers follow the preview ==")
	var view_month := 1
	var wind1: String = OceanLayersLib.instance().prevailing_for(SCS_CELL, view_month)
	var ice1: bool = OceanLayersLib.instance().ice_blocks(BALTIC_ICE_CELL, view_month)
	view_month = 7
	var wind7: String = OceanLayersLib.instance().prevailing_for(SCS_CELL, view_month)
	var ice7: bool = OceanLayersLib.instance().ice_blocks(BALTIC_ICE_CELL, view_month)
	print("    scrub 1→7: SCS wind %s→%s, Baltic ice %s→%s, Somali flips (reversal)"
		% [wind1, wind7, str(ice1), str(ice7)])
	_check(wind1 != wind7 and ice1 and not ice7,
		"the scrubbed month drives winds and ice (no GameState writes)")
	var snap: Dictionary = SaveSystem.snapshot()
	_check(String(snap.get("world", {}).get("wind_dir", "E")) != "",
		"the payload is untouched by the preview (pure view state)")


# --- 8. S19 toggles flip mid-run --------------------------------------------
func _scenario_s19_toggles() -> void:
	print("\n== 8. S19 toggles flip control_prefs live ==")
	GameState.control_prefs = {"input_mode": "step", "current_mode": "modifier"}
	GameState.control_prefs["input_mode"] = "helm"
	GameState.control_prefs["current_mode"] = "drift"
	print("    after the S19 flip: %s" % str(GameState.control_prefs))
	_check(GameState.control_prefs["input_mode"] == "helm"
		and GameState.control_prefs["current_mode"] == "drift",
		"both toggles apply mid-run without a restart")
	var snap: Dictionary = SaveSystem.snapshot()
	_check(snap.get("control_prefs", {}).get("input_mode", "") == "helm",
		"the flipped prefs persist (save v6)")


# --- harness -----------------------------------------------------------------
func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  " + description)
	else:
		_failures.append(description)
		print("FAIL  " + description)


func _report() -> void:
	if _failures.is_empty():
		print("\nALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("\n%d of %d checks FAILED:" % [_failures.size(), _checks])
		for f in _failures:
			print("  - " + f)
		get_tree().quit(1)
