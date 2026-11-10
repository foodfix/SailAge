extends Node
## Phase-9 W2-C acceptance tests — the S21 naval-battle sandbox skeleton
## (docs/IMPLEMENT-Phase9.md decision 15 + W2-C slot; docs/60-COMBAT.md
## §4.12.1 `player_stats` seam, §4.11.1 seed, §4.12.4 sandbox zero-write
## branch; docs/80-UI-UX.md §4.7.16 export schema + clamps).
##
##   godot --headless res://tools/test_battle_sandbox.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1  S21 headless boot — editors build (16 hulls, 9 kinds, clamp bounds);
##   2  the §4.7.16 clamp table is immediate (hull-driven re-clamps, ship
##      count 1..5, day ≥ 1, attrs/morale 0..100, strength 0..3);
##   3  the §4.12.1 `player_stats` seam: override wins per key, GameState
##      fallback otherwise, and a sim WITHOUT the key is byte-identical;
##   4  export/import round-trip byte-identity (+ unknown keys ignored,
##      invalid payload refused);
##   5  S21 → S10 headless run on a fixed config + fixed seed — battle
##      completes, same-config-same-seed `log_lines()` byte-identity, and the
##      `seed_mode = auto` fixture omits `seed`;
##   6  ZERO-WRITE AUDIT — full GameState + NpcFleets snapshot deep-equality
##      around the sandbox battle, read-only after-action, return to S21;
##   7  normal-path guard — a NON-sandbox battle still routes through
##      BattleResult/BattleRewards (outcome carries applied `rewards`), while
##      the sandbox outcome never does;
##   8  the S1 海战 button and the S10 → S21 configuration restore;
##   9  随机全部 determinism/fuzz — seeded handler calls across varied
##      pre-states always leave 1..5 ships per side, every field inside its
##      clamp, the enemy panel rows present AND visible (the "enemy
##      sometimes empty" defect), and the export→import→export round trip
##      byte-identical;
##  10  layout regression — over the live control rects (both locales):
##      no label clipped, no control past its panel edge, one header per
##      panel, the compose checkbox beside its label, the fleet buttons
##      directly under the rows scroll.
##  11  W5-C the ai_level/archetype true-override emission (at-default keys
##      stay out of the fixture; off-row keys ride) + the S10 screen fold
##      into `_enemy_profile` + the same-ai_level replay determinism + the
##      level-sensitivity evidence (the row's ai_level flips the same-seed
##      battle);
##  12  W5-C the whole-field round-trip fuzz — export → import → re-export
##      byte-identical with EVERY §4.7.16 field group surviving (named
##      drifts), the three seed modes, and the export's positive field
##      coverage.
##  13  the 2026-11-09 re-layout pins — after every successful add the NEW
##      row is inside its rows scroll viewport (the "add ship shows
##      nothing" defect), the 5-ship fleet needs no rows scroll, the cap
##      refusal shows the `sandbox.ship.max` toast and disables the Add
##      button (Remove disables at the floor), the three regions sit at
##      their exact pinned 1920×1080 rects, and the rendered-text audit:
##      no Label/Button/OptionButton draws wider than its control in
##      either locale.

const SandboxLib := preload("res://scenes/combat/battle_sandbox.gd")
const SandboxScene := preload("res://scenes/combat/battle_sandbox.tscn")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const ScreenScene := preload("res://scenes/combat/battle_screen.tscn")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const TitleScene := preload("res://scenes/title/title_screen.tscn")

## The §4.7.16 canonical export fixture (the normative doc example, adapted
## to the locked hull data) — imported through the S21 editor before the
## battle runs, so the whole S21 → S10 path runs on editor-made state.
const FIXTURE_JSON := '{"version": 1, "kind": "sailage_sandbox", ' + \
	'"player": {"stats": {"constitution": 30, "intellect": 20, "charisma": 25, ' + \
	'"courage": 40, "luck": 33, "weapon": "eq_cutlass", "armor": ""}, "morale": 55, ' + \
	'"ships": [' + \
	'{"ship_type_id": "brigantine", "cannons": 10, "crew": 30, "durability": 100, ' + \
	'"equipment": {"figurehead": "", "sail": ""}, "captain_id": ""}, ' + \
	'{"ship_type_id": "sloop", "cannons": 4, "crew": 15, "durability": 50, ' + \
	'"equipment": {"figurehead": "", "sail": ""}, "captain_id": ""}]}, ' + \
	'"enemy": {"kind": "pirate", "ai_level": 1, "archetype": "aggressive", ' + \
	'"formation": "swarm", "morale": 60, "compose": false, "ships": [' + \
	'{"ship_type_id": "sloop", "cannons": 4, "crew": 12, "durability": 55, ' + \
	'"equipment": {"figurehead": "", "sail": ""}, "captain_id": ""}, ' + \
	'{"ship_type_id": "sloop", "cannons": 4, "crew": 12, "durability": 55, ' + \
	'"equipment": {"figurehead": "", "sail": ""}, "captain_id": ""}]}, ' + \
	'"conditions": {"day": 5, "seed_mode": "fixed", "seed": 4242, ' + \
	'"weather": "calm", "wind_dir": "E", "current": {"dir": "E", "strength": 0}, ' + \
	'"deployment": "standard"}}'

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	# SANDBOX_SHOT=1 (windowed run): layout-eyeball captures, then quit.
	if OS.get_environment("SANDBOX_SHOT") == "1":
		await _screenshot_smoke()
		return
	await _test_sandbox_boot()
	await _test_clamps()
	await _test_add_ship_visibility()
	await _test_player_stats_seam()
	await _test_export_import()
	await _test_sandbox_run_and_zero_write()
	await _test_normal_path_guard()
	await _test_title_and_restore()
	await _test_randomize_fuzz()
	await _test_layout_geometry()
	await _test_panel_interiors_managed()
	await _test_profile_overrides()
	await _test_full_field_roundtrip()
	_report()


# --- 1. S21 boot ------------------------------------------------------------

func _test_sandbox_boot() -> void:
	var sandbox = await _new_sandbox()
	_check(sandbox != null, "S21 instantiates from battle_sandbox.tscn")
	if sandbox == null:
		return
	_check(sandbox.zero_write_label() != null \
			and sandbox.zero_write_label().visible,
		"the zero-write notice is present and always visible (§4.7.16)")
	_check(sandbox.start_button() != null and sandbox.random_all_button() != null
			and sandbox.import_button() != null and sandbox.export_button() != null,
		"[开战][随机全部][导入][导出] all exist (§4.7.16)")
	# The §4.7.16 editor option sets.
	_check(sandbox.player_rows().size() == 1 and sandbox.enemy_rows().size() == 1,
		"the doc-example default is one player ship vs one enemy ship")
	var player_row: Dictionary = sandbox.player_rows()[0]
	var type_option: OptionButton = player_row["type"]
	_check(type_option.item_count == 16,
		"the ship-type editor offers the 16 locked hulls (%d)"
			% type_option.item_count)
	_check(sandbox.kind_option().item_count == 9,
		"the enemy-kind editor offers the 9 kinds (%d)"
			% sandbox.kind_option().item_count)
	_check(sandbox.weather_option().item_count == 4
			and sandbox.wind_option().item_count == 9
			and sandbox.current_dir_option().item_count == 8
			and sandbox.deployment_option().item_count == 2
			and sandbox.seed_mode_option().item_count == 3
			and sandbox.archetype_option().item_count == 3
			and sandbox.formation_option().item_count == 4
			and sandbox.ai_level_option().item_count == 2,
		"weather 4 / wind 9 (+VAR) / current 8 / deployment 2 / seed 3 / "
		+ "archetype 3 / formation 4 / ai_level 2 option sets build")
	# The fixture editor defaults derive from the hull rows (never invented).
	var brigantine: Dictionary = DataLoader.get_ship_type("brigantine")
	_check(int(player_row["cannons"].value) == int(brigantine["armament_slots"])
			and int(player_row["crew"].value) == int(brigantine["crew_min"])
			and int(player_row["durability"].value) == int(brigantine["durability"]),
		"the default flagship row is brigantine at full cannons / min crew / "
		+ "base durability")
	_check(int(player_row["cannons"].max_value) == int(brigantine["armament_slots"]),
		"the cannons editor clamps to armament_slots of the selected hull")
	_check(int(player_row["crew"].min_value) == int(brigantine["crew_min"])
			and int(player_row["crew"].max_value) == int(brigantine["crew_max"]),
		"the crew editor clamps to crew_min..crew_max of the selected hull")
	_check(int(player_row["durability"].min_value) == 1
			and int(player_row["durability"].max_value) == int(brigantine["durability"]),
		"the durability editor clamps to 1..base durability (W3 owns the "
		+ "figurehead delta)")
	_check(int(sandbox.day_spin().min_value) == 1,
		"day ≥ 1 (the clamp table)")
	_check(int(sandbox.current_strength_spin().min_value) == 0
			and int(sandbox.current_strength_spin().max_value) == 3,
		"current strength clamps to 0..3")
	_check(int(sandbox.attribute_spin("courage").min_value) == 0
			and int(sandbox.attribute_spin("courage").max_value) == 100
			and int(sandbox.player_morale_spin().min_value) == 0
			and int(sandbox.player_morale_spin().max_value) == 100
			and int(sandbox.enemy_morale_spin().min_value) == 0
			and int(sandbox.enemy_morale_spin().max_value) == 100,
		"attributes and both morale editors clamp to 0..100")
	sandbox.queue_free()
	await get_tree().process_frame


# --- 2. Clamps --------------------------------------------------------------

func _test_clamps() -> void:
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	# Ship-count clamps: 1..5 per side (§4.7.16).
	for _index in 7:
		sandbox.add_ship_row("player")
	_check(sandbox.player_rows().size() == 5,
		"adding beyond 5 player ships is refused (%d rows)"
			% sandbox.player_rows().size())
	for _index in 7:
		sandbox.remove_ship_row("player")
	_check(sandbox.player_rows().size() == 1,
		"removing at 1 player ship is refused (%d rows)"
			% sandbox.player_rows().size())
	for _index in 3:
		sandbox.add_ship_row("enemy")
	_check(sandbox.enemy_rows().size() == 4,
		"the enemy side grows to 4 rows (%d)" % sandbox.enemy_rows().size())

	# Value clamps: out-of-range writes clamp immediately.
	var row: Dictionary = sandbox.player_rows()[0]
	row["cannons"].value = 99.0
	_check(int(row["cannons"].value) == int(row["cannons"].max_value),
		"cannons above armament_slots clamp to armament_slots (%d ≤ %d)"
			% [int(row["cannons"].value), int(row["cannons"].max_value)])
	row["crew"].value = 10000.0
	_check(int(row["crew"].value) == int(row["crew"].max_value),
		"crew above crew_max clamps to crew_max")
	row["crew"].value = -5.0
	_check(int(row["crew"].value) == int(row["crew"].min_value),
		"crew below crew_min clamps to crew_min")
	row["durability"].value = 100000.0
	_check(int(row["durability"].value) == int(row["durability"].max_value),
		"durability above the hull base clamps to the base")
	row["durability"].value = -1.0
	_check(int(row["durability"].value) == 1,
		"durability below 1 clamps to 1")
	sandbox.attribute_spin("courage").value = 250.0
	_check(int(sandbox.attribute_spin("courage").value) == 100,
		"an attribute above 100 clamps to 100")
	sandbox.attribute_spin("courage").value = -3.0
	_check(int(sandbox.attribute_spin("courage").value) == 0,
		"an attribute below 0 clamps to 0")
	sandbox.player_morale_spin().value = 101.0
	sandbox.enemy_morale_spin().value = -1.0
	_check(int(sandbox.player_morale_spin().value) == 100
			and int(sandbox.enemy_morale_spin().value) == 0,
		"both morale editors clamp into 0..100")
	sandbox.day_spin().value = 0.0
	_check(int(sandbox.day_spin().value) == 1,
		"day below 1 clamps to 1")
	sandbox.current_strength_spin().value = 4.0
	_check(int(sandbox.current_strength_spin().value) == 3,
		"current strength above 3 clamps to 3")

	# Hull-switch re-clamps: latin (arm 2, crew 8..20, dur 40).
	row["type"].select(0)
	sandbox.apply_clamps()
	var latin: Dictionary = DataLoader.get_ship_type("latin")
	var value: Dictionary = sandbox._read_row(row)
	_check(value["ship_type_id"] == "latin"
			and value["cannons"] == int(latin["armament_slots"])
			and value["crew"] >= int(latin["crew_min"])
			and value["crew"] <= int(latin["crew_max"])
			and value["durability"] >= 1
			and value["durability"] <= int(latin["durability"]),
		"a hull switch re-clamps the row into the new hull's ranges (%s)"
			% str(value))

	# 随机全部 never produces an out-of-range state (§4.7.16).
	sandbox.randomize_all()
	sandbox.apply_clamps()
	var ok := true
	for side in ["player", "enemy"]:
		for ship_row in sandbox.ship_rows(side):
			var state: Dictionary = sandbox._read_row(ship_row)
			var hull: Dictionary = DataLoader.get_ship_type(state["ship_type_id"])
			if state["cannons"] < 0 or state["cannons"] > int(hull["armament_slots"]) \
					or state["crew"] < int(hull["crew_min"]) \
					or state["crew"] > int(hull["crew_max"]) \
					or state["durability"] < 1 \
					or state["durability"] > int(hull["durability"]):
				ok = false
	_check(ok, "随机全部 leaves every row inside its hull's clamp table")
	_check(sandbox.player_rows().size() >= 1 and sandbox.player_rows().size() <= 5
			and sandbox.enemy_rows().size() >= 1 and sandbox.enemy_rows().size() <= 5,
		"随机全部 keeps 1..5 ships per side")
	sandbox.queue_free()
	await get_tree().process_frame


# --- 3. The §4.12.1 player_stats seam ---------------------------------------

# --- 2b. Add-ship visibility + cap feedback (the 2026-11-09 re-layout) ------

func _test_add_ship_visibility() -> void:
	SandboxLib.last_config = {}
	_fixture_run_state()
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	# After EVERY successful add the NEW row must sit inside its side's
	# panel — the rows region has no scroll (the 2026-11-09 horizontal-
	# bands re-layout: five one-line rows fit the pinned panel), so
	# "visible" means geometrically inside the panel's rect.
	for side in ["player", "enemy"]:
		for step in 4:
			_check(sandbox.add_ship_row(side),
				"%s ship %d added" % [side, step + 2])
			await get_tree().process_frame
			await get_tree().process_frame
			var panel: Control = sandbox.player_panel() if side == "player" \
				else sandbox.enemy_panel()
			var rows: Array = sandbox.ship_rows(side)
			var last: Control = rows[rows.size() - 1]["root"]
			var panel_rect := Rect2(panel.global_position, panel.size)
			var row_rect := Rect2(last.global_position, last.size)
			var inside := panel_rect.encloses(row_rect)
			var note: String = "" if inside else " (row %s vs panel %s)" \
				% [row_rect, panel_rect]
			var message: String = ("after the %s add, the new ship row is "
				+ "inside the panel rect (all rows visible, no scroll)%s") \
				% [side, note]
			_check(inside, message)

	# The 5-ship fleet fits its panel with NO scrolling: the rows content
	# stays inside the pinned panel height.
	for side in ["player", "enemy"]:
		var content: float = (sandbox.rows_box(side) as Control).size.y
		var panel: Control = sandbox.player_panel() if side == "player" \
			else sandbox.enemy_panel()
		_check(content <= panel.size.y + 1.0,
			("%s: 5-ship rows content (%.0f px) fits the panel height "
			+ "(%.0f px) — no scrolling needed") % [side, content,
			panel.size.y])

	# Cap: the 6th add refuses, shows the sandbox.ship.max toast, and the
	# Add button disables. Floor: Remove disables at 1, re-enables above.
	_check(not sandbox.add_ship_row("player"),
		"the 6th player add is refused at the §4.7.16 cap")
	_check(sandbox.toast_label().visible,
		"the refused add shows the sandbox.ship.max toast")
	_check(sandbox.player_add_button().disabled,
		"the player Add button disables at the 5-ship cap")
	_check(not sandbox.player_remove_button().disabled,
		"the player Remove button is enabled at 5 ships")
	while sandbox.player_rows().size() > 1:
		sandbox.remove_ship_row("player")
	_check(sandbox.player_remove_button().disabled,
		"the player Remove button disables at the 1-ship floor")
	_check(not sandbox.player_add_button().disabled,
		"the player Add button re-enables below the cap")
	_check(sandbox.enemy_add_button().disabled
			and sandbox.enemy_remove_button().disabled == false,
		"the enemy side's buttons track their own counts")
	sandbox.queue_free()
	await get_tree().process_frame


# --- 3. The §4.12.1 player_stats seam ---------------------------------------

func _fixture_run_state() -> void:
	GameState.locale = "en"
	GameState.day = 5
	GameState.gold = 1234
	GameState.morale = 70
	GameState.world = {"position": {"x": 30, "y": 40}, "clock_fraction": 0.0,
		"weather": "fair"}
	# The §50 Person shape: the "without override" reads below assert against
	# THESE values (the existing suites' fixture convention).
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 21},
		"skills": {"swordplay": 8, "seamanship": 9, "gunnery": 2},
		"xp": 0, "level": 1, "officers": [],
		"equipment": {"weapon": "eq_rapier", "armor": ""},
		"reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0,
			"ottoman": 0, "italy": 0},
	}
	GameState.fleet = [_ship("caravel", {"cannons": 6, "crew": 20})]
	GameState.npc_fleets = [_fleet("nf_audit_1"), _fleet("nf_audit_2")]
	GameState.wrecks = []
	if "pending_encounter" in GameState:
		GameState.set("pending_encounter", null)


func _test_player_stats_seam() -> void:
	_fixture_run_state()
	# With the override: every carried key returns the override (§4.12.1).
	var with_override = BattleLib.new({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
		"enemy_kind": "pirate", "day": 5, "gold": 0,
		"contact": Vector2i.ZERO, "weather": "calm",
		"player_stats": {
			"attributes": {"courage": 77, "charisma": 66},
			"skills": {"swordplay": 55, "gunnery": 30},
			"equipment": {"weapon": "eq_cutlass", "armor": ""},
		},
	})
	_check(BattleLib.player_attribute("courage") == 77,
		"player_attribute('courage') returns the override (77)")
	_check(BattleLib.player_attribute("charisma") == 66,
		"player_attribute('charisma') returns the override (66)")
	_check(BattleLib.player_attribute("luck") == 21,
		"a key the override does not carry falls back to GameState (luck 21)")
	_check(BattleLib.player_effective_skill("swordplay") == 55,
		"player_effective_skill('swordplay') returns the override (55)")
	_check(BattleLib.player_effective_skill("gunnery") == 30,
		"player_effective_skill('gunnery') returns the override (30)")
	_check(BattleLib.player_effective_skill("seamanship") == 9,
		"a skill the override does not carry falls back to GameState (9)")
	# Duel base: 55 (swordplay) + floor(77/20)=3 + eq_cutlass combat 3 = 61 —
	# the equipment term reads the OVERRIDE's weapon, not the worn rapier.
	_check(BattleLib.player_duel_base() == 61,
		"player_duel_base() prices the override's attributes + weapon (61, "
		+ "not the worn rapier's 15)")
	# The flagship gunnery damage term goes through the same seam (§4.4).
	_check(BattleLib.cannon_bonus_flagship() == 1,
		"cannon_bonus_flagship() = floor(30/25) through the override")
	# A sim WITHOUT the key clears the holder — byte-identical fallback.
	var without_override = BattleLib.new({
		"player_ships": [_ship("brigantine")],
		"enemy_ships": [_ship("sloop")],
		"enemy_kind": "pirate", "day": 5, "gold": 0,
		"contact": Vector2i.ZERO, "weather": "calm",
	})
	_check(BattleLib.player_attribute("courage") == 40,
		"without player_stats, player_attribute reads GameState (courage 40)")
	_check(BattleLib.player_effective_skill("swordplay") == 8,
		"without player_stats, effective_skill reads GameState (8)")
	_check(BattleLib.player_duel_base() == 15,
		"without player_stats, player_duel_base prices the worn equipment "
		+ "(8 + 2 + 5 = 15, byte-identical to the pre-seam path)")
	_check(BattleLib.cannon_bonus_flagship() == 0,
		"without player_stats, the gunnery term reads GameState (0)")


# --- 4. Export / import round trip -----------------------------------------

func _test_export_import() -> void:
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	_check(sandbox.import_json(FIXTURE_JSON),
		"the §4.7.16 fixture JSON imports into the editors")
	var first: String = sandbox.export_json()
	_check(sandbox.import_json(first), "a re-import of the export succeeds")
	var second: String = sandbox.export_json()
	_check(first == second,
		"export → import → re-export is byte-identical (§4.7.16)")
	# Unknown keys are ignored; missing keys fall back to the editor values.
	var parsed = JSON.parse_string(first)
	parsed["unknown_future"] = {"whatever": [1, 2, 3]}
	(parsed["player"] as Dictionary)["future_block"] = {"x": 1}
	_check(sandbox.import_json(JSON.stringify(parsed)),
		"unknown keys at both levels are ignored on import")
	_check(sandbox.export_json() == first,
		"the re-export after an unknown-key import is unchanged")
	var no_ships: Dictionary = (JSON.parse_string(first) as Dictionary).duplicate(true)
	(no_ships["player"] as Dictionary).erase("ships")
	_check(sandbox.import_json(JSON.stringify(no_ships)),
		"an import without player.ships succeeds")
	_check(sandbox.export_json() == first,
		"a missing key falls back to the current editor values (ships kept)")
	_check(not sandbox.import_json("this is not json"),
		"invalid JSON refuses with false (the sandbox.import.invalid toast path)")
	_check(not sandbox.import_json("{\"version\": 2, \"kind\": \"sailage_sandbox\"}"),
		"a wrong-envelope version refuses")
	_check(not sandbox.import_json("{\"version\": 1, \"kind\": \"other\"}"),
		"a wrong-envelope kind refuses")
	# The enemies' compose toggle rides the schema.
	var composed: Dictionary = JSON.parse_string(first)
	(composed["enemy"] as Dictionary)["compose"] = true
	_check(sandbox.import_json(JSON.stringify(composed))
			and sandbox.compose_check().button_pressed,
		"compose: true restores the one-click compose toggle")
	_check(sandbox.export_json() != first,
		"compose: true changes the export (the field is schema-carried)")
	sandbox.queue_free()
	await get_tree().process_frame


# --- 5 + 6. The S21 → S10 run, determinism, and the zero-write audit -------

func _test_sandbox_run_and_zero_write() -> void:
	_fixture_run_state()
	var before := _snapshot()
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	_check(sandbox.import_json(FIXTURE_JSON), "the battle fixture imports")
	# The fixture encounter: shape + determinism (§4.7.16 开战 contract).
	var encounter: Dictionary = sandbox.build_encounter()
	_check(bool(encounter.get("sandbox", false)) and str(encounter.get("id")) == "sandbox",
		"the fixture encounter carries sandbox:true / id:sandbox")
	_check(str(encounter.get("kind")) == "pirate" and int(encounter.get("day")) == 5
			and int(encounter.get("gold")) == 0
			and str(encounter.get("weather")) == "calm"
			and int(encounter.get("seed")) == 4242,
		"kind/day/gold/weather/seed ride the fixture (gold 0, fixed seed)")
	_check(encounter.get("player_ships") is Array
			and (encounter["player_ships"] as Array).size() == 2
			and encounter.get("enemy_ships") is Array
			and (encounter["enemy_ships"] as Array).size() == 2,
		"the fixture carries both fleets as §4.11.11 instances")
	var flagship: Dictionary = encounter["player_ships"][0]
	_check(str(flagship.get("ship_type_id")) == "brigantine"
			and int(flagship.get("cannons")) == 10
			and int(flagship.get("crew")) == 30
			and int(flagship.get("durability")) == 100
			and flagship.get("equipment") is Dictionary
			and flagship.get("cargo") is Dictionary
			and (flagship["cargo"] as Dictionary).is_empty(),
		"a ship instance is the §4.11.11 shape (type/durability/crew/cannons/"
		+ "equipment/cargo {})")
	var stats = encounter.get("player_stats", {})
	_check(stats is Dictionary
			and int((stats["attributes"] as Dictionary).get("courage", 0)) == 40
			and str((stats["equipment"] as Dictionary).get("weapon")) == "eq_cutlass",
		"the editor's stats ride player_stats (the §4.12.1 seam payload)")
	# Forward-compat: the dormant keys stay OUT of the fixture encounter.
	for dormant in ["wind_dir", "current", "morale", "ai_level", "archetype",
			"formation", "deployment"]:
		if encounter.has(dormant):
			_check(false, "the fixture leaks the dormant key '%s'" % dormant)
	_check(true,
		"wind/current/morale/ai_level/archetype/formation/deployment stay "
		+ "editor + export-only (forward-compat)")
	var encounter_again: Dictionary = sandbox.build_encounter()
	_check(JSON.stringify(encounter) == JSON.stringify(encounter_again),
		"the same fixed config builds the same encounter twice")

	# seed_mode = auto: the key is OMITTED, the §4.11.1 formula applies.
	var auto_json = JSON.parse_string(FIXTURE_JSON)
	(auto_json["conditions"] as Dictionary)["seed_mode"] = "auto"
	_check(sandbox.import_json(JSON.stringify(auto_json)), "auto seed imports")
	var auto_encounter: Dictionary = sandbox.build_encounter()
	_check(not auto_encounter.has("seed"),
		"seed_mode auto omits the seed key (the §4.11.1 formula applies)")
	var expected_seed := BattleLib.battle_seed_formula(5, Vector2i.ZERO, 0, 2)
	_check(expected_seed == BattleLib.battle_seed_formula(5, Vector2i.ZERO, 0, 2),
		"the auto seed resolves through the §4.11.1 closed form (day 5, "
		+ "origin contact, gold 0, fleet 2 → %d)" % expected_seed)
	_check(JSON.stringify(auto_encounter) == JSON.stringify(sandbox.build_encounter()),
		"the auto-seed encounter is deterministic too")

	# The S10 run — the production path: pending_encounter, then S10's _ready.
	SandboxLib.last_config = sandbox.export_config()
	GameState.pending_encounter = encounter
	var screen = await _new_screen()
	_check(screen != null and screen.sim != null,
		"S10 opens the sandbox fixture from GameState.pending_encounter")
	_check(screen.is_sandbox_battle(),
		"the opened battle reports is_sandbox_battle() (the §4.12.4 guard flag)")
	var pending_after = GameState.get("pending_encounter")
	_check(pending_after == null or (pending_after is Dictionary
			and (pending_after as Dictionary).is_empty()),
		"the pending descriptor was consumed exactly once (§4.11.11.3)")
	var first_log: String = JSON.stringify(screen.sim.log_lines())
	var outcome: Dictionary = screen.run_to_completion()
	_check(not outcome.is_empty() and str(outcome.get("result", "")) != "",
		"the sandbox battle completes (result '%s' in %d rounds)"
			% [str(outcome.get("result", "")), int(outcome.get("rounds", 0))])
	_check(str(outcome.get("encounter_id", "")) == "sandbox",
		"the outcome block carries encounter_id 'sandbox'")
	_check(not outcome.has("rewards"),
		"no BattleRewards payload rides the sandbox outcome (steps 2/3 skipped)")
	_check(screen.after_action_dialog() != null
			and screen.after_action_dialog().visible,
		"the read-only after-action dialog is up after the battle")
	_check(screen.return_scene() == "res://scenes/combat/battle_sandbox.tscn",
		"Continue returns to S21 (§4.12.4 sandbox branch)")
	_check(not screen.game_over_raised,
		"no gameover.* fired for the sandbox battle (BattleResult.apply skipped)")
	# The zero-write audit: the LIVE GameState fields + the ecology.
	var after_continue_ok := true
	screen.route_to_world = false
	screen._continue_after_battle()
	_check(not screen.after_action_dialog().visible,
		"the dialog confirm closes the after-action dialog")
	_check(screen.return_scene() == "res://scenes/combat/battle_sandbox.tscn",
		"after the confirm the route target is still S21 (no world routing)")
	var after := _snapshot()
	after_continue_ok = _deep_eq(before, after)
	_check(after_continue_ok,
		"ZERO-WRITE AUDIT: day/gold/morale/player/fleet/world/wrecks are "
		+ "deep-equal around the sandbox battle")
	_check(_deep_eq(before["npc_fleets"], after["npc_fleets"]),
		"ZERO-WRITE AUDIT: NpcFleets.fleets() is deep-equal (no remove / "
		+ "no set_pursuit_cooldown)")
	_check((after["npc_fleets"] as Array).size() == 2,
		"ZERO-WRITE AUDIT: the fleet count is unchanged (2 fixture fleets)")

	# Determinism: the same config + fixed seed rebuilds a byte-identical log.
	var screen_b = await _new_screen_with_encounter(encounter)
	var second_log: String = JSON.stringify(screen_b.sim.log_lines())
	_check(first_log == second_log,
		"same config + same seed → byte-identical sim.log_lines() across runs")
	var outcome_b: Dictionary = screen_b.run_to_completion()
	_check(JSON.stringify(outcome_b) == JSON.stringify(outcome),
		"the outcome blocks are byte-identical across the two runs")
	_check(SandboxLib.last_config.has("player")
			and str((SandboxLib.last_config["enemy"] as Dictionary).get("kind")) == "pirate",
		"last_config keeps the configuration across the S10 round-trip")

	# The S21 restore: a fresh S21 boots its editors from last_config.
	var restored = SandboxScene.instantiate()
	add_child(restored)
	await get_tree().process_frame
	var stats_restored: Dictionary = restored.export_config()["player"]["stats"]
	_check(int(stats_restored["courage"]) == 40
			and str(stats_restored["weapon"]) == "eq_cutlass",
		"the fresh S21 restores the kept configuration (stats + weapon)")
	_check((restored.export_config()["player"]["ships"] as Array).size() == 2,
		"the kept fleet shape restores (2 player ships)")
	screen.queue_free()
	screen_b.queue_free()
	restored.queue_free()
	sandbox.queue_free()
	await get_tree().process_frame


# --- 7. Normal-path guard ---------------------------------------------------

func _test_normal_path_guard() -> void:
	_fixture_run_state()
	var gold_before := int(GameState.gold)
	var screen = await _new_screen_with_encounter({
		"id": "hf_9_30_40_pirate", "kind": "pirate", "nation_id": "",
		"position": {"x": 30, "y": 40}, "day": 9,
		"ships": [_ship("sloop", {"cannons": 4, "crew": 20})],
	})
	if screen == null:
		return
	_check(not screen.is_sandbox_battle(),
		"a plain encounter is NOT a sandbox battle (the guard flag)")
	var outcome: Dictionary = screen.run_to_completion()
	_check(not outcome.is_empty(), "the normal battle completes")
	_check(outcome.has("rewards"),
		"GUARD: a NON-sandbox battle still routes through BattleRewards "
		+ "(the applied rewards payload rides the outcome)")
	_check(int(GameState.gold) == gold_before + int(outcome.get("salvage_gold", 0)),
		"GUARD: BattleRewards applied the salvage to GameState.gold (%+d)"
			% (int(GameState.gold) - gold_before))
	_check(screen.return_scene() == "res://scenes/world/world_map.tscn",
		"GUARD: a normal battle still routes back to S3")
	screen.queue_free()
	await get_tree().process_frame


# --- 8. Title button + restore ----------------------------------------------

func _test_title_and_restore() -> void:
	var title = TitleScene.instantiate()
	add_child(title)
	await get_tree().process_frame
	var button: Button = title.get_node_or_null("Sandbox")
	_check(button != null,
		"S1 carries the 海战 button between New Game and Load (§4.7.16)")
	if button != null:
		# W2-B: the node tree IS the element tree — the flat root children
		# keep the §4.7.16 order (NewGame → Sandbox → Load).
		var new_game: Control = title.get_node("NewGame")
		var load_button: Control = title.get_node("Load")
		_check(button.get_index() == new_game.get_index() + 1
			and load_button.get_index() == button.get_index() + 1,
			"the 海战 button sits between New Game (%d) and Load (%d)"
			% [new_game.get_index(), load_button.get_index()])
		title.route_to_sandbox = false
		_check(title.open_sandbox() and
			title.last_route == "res://scenes/combat/battle_sandbox.tscn",
			"open_sandbox() routes to S21 (guarded — no scene swap in the suite)")
	title.queue_free()
	await get_tree().process_frame


# --- 9. 随机全部 determinism / the empty-enemy regression -------------------

func _test_randomize_fuzz() -> void:
	# Boot from the doc-example defaults (test 5 left a kept configuration in
	# the static), en locale (the longest labels), a live fixture GameState.
	SandboxLib.last_config = {}
	_fixture_run_state()
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	# 24 scripted rolls — the handler is called DIRECTLY (no UI simulation)
	# with a pinned seed per roll, across varied pre-states: fleet sizes
	# 1..5 on both sides, compose ON every third state (the reported defect's
	# setup). After every roll: 1..5 ships per side, every field inside its
	# clamp, both sides' ship rows present AND visible in the tree, and the
	# export → import → export round trip byte-identical.
	var details: Array[String] = []
	var rolls := 24
	for attempt in rolls:
		var player_count := 1 + (attempt * 7) % 5
		var enemy_count := 1 + (attempt * 11 + 3) % 5
		var compose := attempt % 3 == 1
		if not _apply_prestate(sandbox, player_count, enemy_count, compose):
			details.append("roll %d: prestate %d/%d compose %s refused"
				% [attempt, player_count, enemy_count, compose])
			continue
		sandbox.randomize_all(913000 + attempt * 7919)
		var problems := _randomize_invariant_problems(sandbox)
		var first: String = sandbox.export_json()
		if not sandbox.import_json(first):
			problems.append("the roll's export refuses to re-import")
		elif sandbox.export_json() != first:
			problems.append("export → import → export drifted")
		if not problems.is_empty():
			details.append("roll %d (pre %d/%d compose %s): %s" % [
				attempt, player_count, enemy_count, compose,
				"; ".join(problems)])
	_check(details.is_empty(),
		"24 seeded 随机全部 rolls across varied pre-states: both sides 1..5 "
		+ "ships, every field inside its clamp, ship rows present + visible, "
		+ "round trip byte-identical"
		+ ("" if details.is_empty() else " — " + "; ".join(details)))

	# The reported defect, pinned explicitly: compose ON hides the enemy rows
	# scroll (the defect setup), and the roll must restore the panel.
	if not _apply_prestate(sandbox, 1, 3, true):
		_check(false, "the compose-ON prestate imports")
	else:
		_check(sandbox.compose_check().button_pressed
				and not sandbox.rows_box("enemy").visible,
			"prestate: compose ON hides the enemy ship rows box (the "
			+ "defect's setup)")
		sandbox.randomize_all(4242)
		var rows: int = sandbox.enemy_rows().size()
		var pinned_text: String = ("随机全部 after a compose-ON state: compose "
			+ "OFF and the enemy panel's ship rows visible again (%d rows) "
			+ "— the 'enemy sometimes empty' defect is pinned") % rows
		_check(not sandbox.compose_check().button_pressed
				and sandbox.rows_box("enemy").visible
				and rows >= 1 and rows <= 5
				and sandbox.rows_content("enemy").get_child_count() == rows
				and (sandbox.rows_content("enemy").get_child(0) as Control)
					.is_visible_in_tree(),
			pinned_text)

	# The randomized export must re-import byte-identical into a FRESH editor
	# (the nested `equipment` slots of the normative schema are restored).
	sandbox.randomize_all(90210)
	var exported: String = sandbox.export_json()
	var fresh = await _new_sandbox()
	_check(fresh.import_json(exported) and fresh.export_json() == exported,
		"a randomized export re-imports byte-identical into a FRESH editor "
		+ "(nested equipment slots restored)")
	fresh.queue_free()
	sandbox.queue_free()
	await get_tree().process_frame


## Builds a fuzz pre-state: `player_count` / `enemy_count` ship rows and the
## compose toggle, applied through the import seam (the production state
## path). Returns false if the crafted payload refuses.
func _apply_prestate(sandbox, player_count: int, enemy_count: int,
		compose: bool) -> bool:
	var config = JSON.parse_string(sandbox.export_json())
	if not (config is Dictionary):
		return false
	for side_def in [["player", player_count], ["enemy", enemy_count]]:
		var block: Dictionary = config[side_def[0]]
		var ships: Array = block["ships"]
		while ships.size() > side_def[1]:
			ships.pop_back()
		while ships.size() < side_def[1]:
			ships.append((ships[0] as Dictionary).duplicate(true))
		block["ships"] = ships
	(config["enemy"] as Dictionary)["compose"] = compose
	return sandbox.import_json(JSON.stringify(config))


## The post-roll invariant set (§4.7.16): 1..5 ships per side, every field
## inside its clamp, compose OFF, and both sides' ship rows present AND
## visible in the node tree. Returns human-readable problems (empty = clean).
func _randomize_invariant_problems(sandbox) -> Array[String]:
	var problems: Array[String] = []
	for side in ["player", "enemy"]:
		var rows: Array = sandbox.ship_rows(side)
		if rows.size() < 1 or rows.size() > 5:
			problems.append("%s side has %d ships (clamp 1..5)"
				% [side, rows.size()])
		var box: Control = sandbox.rows_content(side)
		if box.get_child_count() != rows.size():
			problems.append("%s rows_box holds %d of %d rows"
				% [side, box.get_child_count(), rows.size()])
		if not sandbox.rows_box(side).visible:
			problems.append("%s rows box hidden" % side)
		for index in rows.size():
			var row: Dictionary = rows[index]
			if not (row["root"] as Control).is_visible_in_tree():
				problems.append("%s ship %d row node not visible"
					% [side, index])
			var state: Dictionary = sandbox._read_row(row)
			var hull: Dictionary = DataLoader.get_ship_type(
				state["ship_type_id"])
			if hull.is_empty():
				problems.append("%s ship %d: unknown hull '%s'"
					% [side, index, state["ship_type_id"]])
				continue
			if int(state["cannons"]) < 0 \
					or int(state["cannons"]) > int(hull["armament_slots"]):
				problems.append("%s ship %d: cannons %d outside 0..%d"
					% [side, index, int(state["cannons"]),
					int(hull["armament_slots"])])
			if int(state["crew"]) < int(hull["crew_min"]) \
					or int(state["crew"]) > int(hull["crew_max"]):
				problems.append("%s ship %d: crew %d outside %d..%d"
					% [side, index, int(state["crew"]),
					int(hull["crew_min"]), int(hull["crew_max"])])
			if int(state["durability"]) < 1 \
					or int(state["durability"]) > int(hull["durability"]):
				problems.append("%s ship %d: durability %d outside 1..%d"
					% [side, index, int(state["durability"]),
					int(hull["durability"])])
	if sandbox.compose_check().button_pressed:
		problems.append("compose rolled ON (the mode is not a die roll)")
	if int(sandbox.day_spin().value) < 1:
		problems.append("day %d below 1" % int(sandbox.day_spin().value))
	var strength: int = int(sandbox.current_strength_spin().value)
	if strength < 0 or strength > 3:
		problems.append("current strength %d outside 0..3" % strength)
	for key in ["constitution", "intellect", "charisma", "courage", "luck"]:
		var spin: SpinBox = sandbox.attribute_spin(key)
		if int(spin.value) < 0 or int(spin.value) > 100:
			problems.append("attribute %s %d outside 0..100"
				% [key, int(spin.value)])
	for spin in [sandbox.player_morale_spin(), sandbox.enemy_morale_spin()]:
		if int(spin.value) < 0 or int(spin.value) > 100:
			problems.append("morale %d outside 0..100" % int(spin.value))
	var seed_value: int = int(sandbox.seed_spin().value)
	if seed_value < 0 or seed_value > 999999999:
		problems.append("seed %d outside 0..999999999" % seed_value)
	return problems


# --- 10. Layout regression — nothing clips, nothing overflows ---------------

func _test_layout_geometry() -> void:
	# The label strings are locale-dependent (EN is the longest form), so the
	# audit runs for BOTH locales with the fleet at its worst case (5v5).
	for locale in ["en", "zh"]:
		GameState.locale = locale
		SandboxLib.last_config = {}
		var sandbox = await _new_sandbox()
		if sandbox == null:
			return
		while sandbox.player_rows().size() < 5:
			sandbox.add_ship_row("player")
		while sandbox.enemy_rows().size() < 5:
			sandbox.add_ship_row("enemy")
		await get_tree().process_frame
		await get_tree().process_frame

		var problems := _layout_problems(sandbox)
		var layout_note: String = "" if problems.is_empty() \
			else " — " + "; ".join(problems)
		var layout_text: String = "[%s] layout rects: no label clipped, no " \
			+ "control past its panel edge, every rendered text fits its " \
			+ "control, ship rows fit their scroll's width"
		_check(problems.is_empty(), (layout_text % locale) + layout_note)

		# One header per panel — the panel content builds no second title row.
		for side_def in [["player", sandbox.player_header(),
				sandbox.player_panel()], ["enemy", sandbox.enemy_header(),
				sandbox.enemy_panel()]]:
			var header: Label = side_def[1]
			var count := 0
			for control in _panel_controls(side_def[2]):
				if control is Label and control.text == header.text:
					count += 1
			_check(count == 1,
				"[%s] the %s panel shows exactly ONE '%s' header (found %d)"
					% [locale, side_def[0], header.text, count])

		# The compose toggle carries its OWN localized text (the whole
		# checkbox is clickable — the 2026-11-09 re-layout).
		var compose_text: String = I18n.t_key("sandbox.enemy.compose")
		var check: Control = sandbox.compose_check()
		_check(check is CheckBox and (check as CheckBox).text == compose_text,
			"[%s] the compose toggle carries its own localized label" % locale)

		# The fleet +/− buttons sit on the panel's FIRST row (the shared
		# editors row) at its right end, inside the panel (the 2026-11-09
		# horizontal-bands re-layout).
		for side in ["player", "enemy"]:
			var panel: Control = sandbox.player_panel() if side == "player" \
				else sandbox.enemy_panel()
			var add: Button = sandbox.player_add_button() \
				if side == "player" else sandbox.enemy_add_button()
			var row_ok := add.global_position.y \
				< panel.global_position.y + 72.0 \
				and add.global_position.x + add.size.x \
					<= panel.global_position.x + panel.size.x + 1.0
			_check(row_ok,
				("[%s] the %s fleet +/− buttons sit on the editors row's "
				+ "right end inside the panel") % [locale, side])

		# The three §4.7.16 regions sit at their EXACT managed rects (the
		# Phase-12 v2 tile grid: the fragment `sandbox.json` is the pin —
		# 1,2,59,13 / 1,16,59,13 / 1,29,59,5 in tiles × 32px).
		var rects := [
			["player panel", sandbox.player_panel(),
				Vector2(32, 64), Vector2(1888, 416)],
			["enemy panel", sandbox.enemy_panel(),
				Vector2(32, 512), Vector2(1888, 416)],
			["conditions", sandbox.conditions_panel(),
				Vector2(32, 928), Vector2(1888, 160)],
		]
		var rects_ok := true
		var rects_note := ""
		for entry in rects:
			var control: Control = entry[1]
			if control.position != (entry[2] as Vector2) \
					or control.size != (entry[3] as Vector2):
				rects_ok = false
				rects_note += " %s at %s×%s" % [entry[0], control.position,
					control.size]
		_check(rects_ok,
			("[%s] the three §4.7.16 regions sit at the managed tile rects "
			+ "(player 32,64 1888×416 / enemy 32,512 1888×416 / conditions "
			+ "32,928 1888×160 — the v2 grid's quantized form of the pinned "
			+ "bands)") % locale + rects_note)

		sandbox.queue_free()
		await get_tree().process_frame
	GameState.locale = "en"


## Every descendant Control of `root` (excluding `root` itself), pre-order.
func _panel_controls(root: Control) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child is Control:
			out.append(child)
			out.append_array(_panel_controls(child))
	return out


## The geometric layout audit over the live control rects: every non-scroll
## descendant must stay inside its panel's right/bottom edge, no label may
## set clip_text, each side's rows column must fit its scroll's width
## (horizontal scrolling is disabled, so a too-wide row would clip), and —
## the 2026-11-09 addition — every Label/Button/OptionButton's RENDERED
## text must fit its control (the rect audit alone never sees an
## OptionButton's selected item drawing past its box; Button pads ≈8px per
## side, OptionButton pads + arrow ≈34px).
func _layout_problems(sandbox) -> Array[String]:
	var problems: Array[String] = []
	# Phase 12 (W2-D): the regions are the managed data rects now (the
	# 32-tile grid; `data/layout_fragments/sandbox.json` is the pin) — the
	# screen bottom carries the §4.23 sliver row (the canvas is 60×33.75
	# tiles: a full-height 34-tile element's bottom 8px are IN bounds).
	var regions: Array = [
		{"name": "player panel", "panel": sandbox.player_panel(),
			"right": 1920.0, "bottom": 1080.0},
		{"name": "enemy panel", "panel": sandbox.enemy_panel(),
			"right": 1920.0, "bottom": 1080.0},
		{"name": "conditions", "panel": sandbox.conditions_panel(),
			"right": 1920.0, "bottom": 1080.0},
		{"name": "screen", "panel": sandbox, "right": 1920.0, "bottom": 1088.0},
	]
	for region in regions:
		var panel: Control = region["panel"]
		var limit_right: float = region["right"] if panel == sandbox \
			else panel.global_position.x + panel.size.x
		var limit_bottom: float = region["bottom"] if panel == sandbox \
			else panel.global_position.y + panel.size.y
		for control in _panel_controls(panel):
			if control == panel:
				continue
			var right: float = control.global_position.x + control.size.x
			var bottom: float = control.global_position.y + control.size.y
			if right > limit_right + 1.0:
				problems.append("%s: %s overflows the right edge by %.0fpx"
					% [region["name"], _ctrl_path(control, panel),
					right - limit_right])
			if bottom > limit_bottom + 1.0:
				problems.append("%s: %s overflows the bottom edge by %.0fpx"
					% [region["name"], _ctrl_path(control, panel),
					bottom - limit_bottom])
			if control is Label and (control as Label).clip_text:
				problems.append("%s: %s sets clip_text (labels never clip)"
					% [region["name"], _ctrl_path(control, panel)])
			var text_problem := _text_overflow(control)
			if not text_problem.is_empty():
				problems.append("%s: %s %s"
					% [region["name"], _ctrl_path(control, panel),
					text_problem])
	for side in ["player", "enemy"]:
		var panel: Control = sandbox.player_panel() if side == "player" \
			else sandbox.enemy_panel()
		var box: Control = sandbox.rows_box(side)
		if box.size.x > panel.size.x + 1.0:
			problems.append("%s ship rows are wider (%.0f) than their panel "
				+ ("(%.0f) — horizontal clip"
				% [side, box.size.x, panel.size.x]))
	return problems


## The rendered-text fit audit for one control: "" = fits. Measures the
## visible text (a Label's text, a Button's text, an OptionButton's
## selected item) against the control's live width, minus the chrome the
## theme actually reserves: the "normal" stylebox's own margins, and for
## an OptionButton additionally its "arrow" icon (the pads are MEASURED,
## not guessed — the flat guesses false-failed by 2px on 'Lookahead (T3)').
## Empty texts skip.
func _text_overflow(control: Control) -> String:
	var text := ""
	var reserve := 0.0
	var font: Font = null
	var font_size := 0
	if control is Label:
		text = (control as Label).text
		font = (control as Label).get_theme_font("font")
		font_size = (control as Label).get_theme_font_size("font_size")
	elif control is OptionButton:
		var option := control as OptionButton
		if option.selected < 0 or option.selected >= option.item_count:
			return ""
		text = option.get_item_text(option.selected)
		font = option.get_theme_font("font")
		font_size = option.get_theme_font_size("font_size")
		reserve += _stylebox_margins(option)
		var arrow := option.get_theme_icon("arrow") as Texture2D
		if arrow != null:
			reserve += arrow.get_width()
	elif control is Button:
		text = (control as Button).text
		font = (control as Button).get_theme_font("font")
		font_size = (control as Button).get_theme_font_size("font_size")
		reserve += _stylebox_margins(control)
	if text.is_empty() or font == null:
		return ""
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, font_size).x
	if width + reserve > control.size.x + 1.0:
		return "text '%s' is %.0fpx (+%.0f chrome) but the box is %.0fpx" \
			% [text, width, reserve, control.size.x]
	return ""


## The "normal" stylebox's left+right margins of a button-like control
## (the space its theme chrome reserves beside the text).
func _stylebox_margins(control: Control) -> float:
	var box := control.get_theme_stylebox("normal") as StyleBox
	if box == null:
		return 0.0
	return box.get_margin(SIDE_LEFT) + box.get_margin(SIDE_RIGHT)


## A short readable name for a control relative to its panel.
func _ctrl_path(control: Control, root: Control) -> String:
	var name: String = control.name
	var parent = control.get_parent()
	while parent is Control and parent != root:
		name = "%s/%s" % [parent.name, name]
		parent = parent.get_parent()
	return name


# --- 11. W5-C: the ai_level/archetype overrides become effective ------------

## The panel interiors are managed (the 2026-11-10 user report: the
## studios' ids stopped at the plates — the editors rows, the +/− pair,
## the ship-rows regions and the conditions grid/actions were
## unmodifiable). The pins derive expectations from the COMMITTED
## `data/ui_layout.json` (the file is the pin): every interior id has a
## live record, the rects apply from the file, the ship rows ride their
## list block and follow their host, and a studio edit STICKS.
func _test_panel_interiors_managed() -> void:
	GameState.locale = "en"
	SandboxLib.last_config = {}
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	var tile := float(PaletteLib.CHROME_TILE)
	var f := FileAccess.open("res://data/ui_layout.json", FileAccess.READ)
	var doc: Dictionary = JSON.parse_string(f.get_as_text()) if f != null \
			else {}
	f.close()
	var rows: Dictionary = doc.get("screens", {}).get("sandbox", {}) \
			.get("elements", {})
	var lists: Dictionary = doc.get("screens", {}).get("sandbox", {}) \
			.get("lists", {})
	_check(not rows.is_empty() and not lists.is_empty(),
			"interiors: the committed file carries sandbox rows + lists")

	var live := func(id: String) -> Control:
		var rec: Dictionary = RegistryLib._screens.get("sandbox", {}) \
				.get(id, {})
		var ref: WeakRef = rec.get("control", null) if rec.has("control") \
				else null
		return ref.get_ref() if ref != null else null
	var at := func(id: String) -> Vector2:
		var r: Dictionary = rows.get(id, {})
		return Vector2(float(int(r.get("x", -9))), float(int(r.get("y", -9)))) \
				* tile

	# Every interior id is live and at its committed rect (panel-local).
	for id in ["player_panel.stats_row", "player_panel.rows",
			"enemy_panel.profile_row", "enemy_panel.rows",
			"conditions_panel.grid", "conditions_panel.actions",
			"player_panel.stats_row.add", "player_panel.stats_row.remove",
			"enemy_panel.profile_row.add", "enemy_panel.profile_row.remove"]:
		var ctl: Control = live.call(id)
		_check(ctl != null and ctl.position == at.call(id),
				"interiors: %s is live at its committed rect (got %s)"
						% [id, str(ctl.position if ctl != null else "absent")])

	# The ship rows are list members riding the block (builder-placed via
	# list_rect — the committed base/row_h).
	var row0: Control = live.call("player_rows.0")
	var row_h := float(int(lists.get("player_rows", {}).get("row_h", -9)))
	_check(row0 != null and row_h == 2.0 and row0.position.y == 0.0,
			"interiors: ship row 0 rides the player_rows block (row_h %s)"
					% str(row_h))
	sandbox.add_ship_row("player")
	await get_tree().process_frame
	var row1: Control = live.call("player_rows.1")
	_check(row1 != null and row1.position.y == row_h * tile,
			"interiors: an added ship row lands at the block's next row "
			+ "(y=%s)" % str(row1.position.y if row1 != null else -1.0))

	# The cells (the follow-up report — "edit constitution, intellect,
	# armor, weapon…"): every committed cell row under the three editors
	# rows is live at its rect, and one cell edit STICKS. The ids derive
	# from the committed file (the file is the pin). Runs BEFORE the row
	# shrink below — a shrunken row clamps its cells into it (the amended
	# rule 2), which is pinned separately.
	var cell_ids: Array[String] = []
	for id in rows.keys():
		var s := str(id)
		if s.begins_with("player_panel.stats_row.") \
				or s.begins_with("enemy_panel.profile_row.") \
				or s.begins_with("conditions_panel.grid."):
			cell_ids.append(s)
	_check(cell_ids.size() >= 20,
			"cells: %d committed cell rows (want ≥ 20)" % cell_ids.size())
	var cells_ok := true
	for id in cell_ids:
		var ctl: Control = live.call(id)
		if ctl == null or ctl.position != at.call(id):
			cells_ok = false
			print("  cell off: %s got %s want %s" % [id,
					str(ctl.position if ctl != null else "absent"),
					str(at.call(id))])
	_check(cells_ok,
			"cells: every committed cell is live at its rect (%d)"
					% cell_ids.size())
	RegistryLib.apply_overrides("sandbox",
			"player_panel.stats_row.constitution", {"x": 2, "y": 0})
	await get_tree().process_frame
	await get_tree().process_frame
	var constitution: Control = live.call(
			"player_panel.stats_row.constitution")
	_check(constitution != null and constitution.position == Vector2(2, 0)
			* tile, "cells: a constitution cell edit STICKS (got %s)"
					% str(constitution.position if constitution != null
					else "absent"))

	# A studio edit on the stats row STICKS, and the cells clamp INTO the
	# shrunken row (the amended rule 2 — the shrink succeeds).
	var stats: Control = live.call("player_panel.stats_row")
	RegistryLib.apply_overrides("sandbox", "player_panel.stats_row",
			{"x": 2, "y": 2, "w": 40, "h": 2})
	await get_tree().process_frame
	await get_tree().process_frame
	_check(stats.position == Vector2(2, 2) * tile
			and stats.size == Vector2(40, 2) * tile,
			"interiors: a stats_row studio edit STICKS (got %s / %s)"
					% [str(stats.position), str(stats.size)])
	var morale: Control = live.call("player_panel.stats_row.morale")
	var morale_w := float(int(rows.get("player_panel.stats_row.morale",
			{}).get("w", -1)))
	_check(morale != null and morale_w > 0 and morale.position.x
			== (40 - morale_w) * tile,
			"cells: the morale cell clamped into the shrunken row "
			+ "(got %s)" % str(morale.position if morale != null
					else "absent"))
	RegistryLib.apply_overrides("sandbox", "player_panel.stats_row",
			{"x": 1, "y": 1, "w": 58, "h": 2})
	var region: Control = live.call("player_panel.rows")
	# The region is a scroll viewport (the 2026-11-11 user request): the
	# ship lines live in a content node sized to the stacked extent, so
	# resizing the region below the stack scrolls instead of clipping.
	_check(region is ScrollContainer,
			"interiors: the rows region is a ScrollContainer")
	var content: Control = region.get_child(0)
	_check(content != null and content.size.y == float(
					content.get_child_count()) * 2.0 * tile,
			"interiors: the scroll content is sized to the stacked "
			+ "extent (got %s)" % str(content.size if content != null
					else "absent"))
	var region_before: float = row1.global_position.y
	RegistryLib.apply_overrides("sandbox", "player_panel.rows",
			{"x": 1, "y": 2})
	await get_tree().process_frame
	_check(region_before - row1.global_position.y == tile,
			"interiors: the ship rows follow their host region")
	RegistryLib.apply_overrides("sandbox", "player_panel.rows",
			{"x": 1, "y": 3})
	sandbox.queue_free()
	await get_tree().process_frame


func _test_profile_overrides() -> void:
	_fixture_run_state()
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return

	# The at-default fixture stays byte-harmless (the true-override
	# emission): the §4.7.16 fixture is pirate AT the §4.10 row's own values
	# (ai_level 1 / aggressive / swarm), so NONE of the three profile keys
	# rides the encounter — the W2-C dormant-key audit keeps its meaning.
	_check(sandbox.import_json(FIXTURE_JSON),
		"the §4.7.16 fixture imports (the W5-C emission pins)")
	var plain_encounter: Dictionary = sandbox.build_encounter()
	var leaked: Array[String] = []
	for key in ["ai_level", "archetype", "formation"]:
		if plain_encounter.has(key):
			leaked.append(key)
	_check(leaked.is_empty(),
		"at the §4.10 row defaults none of ai_level/archetype/formation "
		+ "rides the fixture (the byte-harmless audit stays meaningful)"
		+ ("" if leaked.is_empty() else " — leaked: " + ", ".join(leaked)))

	# Off the row defaults each key rides — and only that key.
	sandbox._select_option(sandbox.ai_level_option(), 0)
	sandbox._select_option(sandbox.archetype_option(), "cautious")
	var override_encounter: Dictionary = sandbox.build_encounter()
	_check(int(override_encounter.get("ai_level", -1)) == 0,
		"ai_level 0 ≠ the pirate row's 1 rides the fixture (the W5-C "
		+ "true-override emission)")
	_check(str(override_encounter.get("archetype", "")) == "cautious",
		"archetype cautious ≠ the pirate row's aggressive rides the fixture")
	_check(not override_encounter.has("formation"),
		"the formation key stays out while the editor holds the row's swarm "
		+ "(per-key override granularity)")
	_check(JSON.stringify(override_encounter) == JSON.stringify(
			sandbox.build_encounter()),
		"the override fixture builds byte-identically twice (determinism)")

	# The kind switch re-syncs the selectors to the row: a trader at its row
	# defaults (0/cautious/column) emits nothing again — the sync RESTORES
	# the at-default editor state.
	sandbox._select_option(sandbox.kind_option(), "trader")
	sandbox._apply_kind_profile("trader")
	var trader_encounter: Dictionary = sandbox.build_encounter()
	_check(not trader_encounter.has("ai_level")
			and not trader_encounter.has("archetype")
			and not trader_encounter.has("formation"),
		"the trader kind re-sync (row 0/cautious/column) drops every profile "
		+ "key out of the fixture")
	sandbox._select_option(sandbox.ai_level_option(), 1)
	var trader_t3: Dictionary = sandbox.build_encounter()
	_check(int(trader_t3.get("ai_level", -1)) == 1
			and not trader_t3.has("archetype"),
		"a trader fixture with ai_level 1 rides the override (the row says 0)")

	# The S10 screen fold (§4.7.16/§4.9c — the W4 formation-fold pattern):
	# the fixture keys land in the battle's §4.9a profile row.
	var keyed_screen = await _new_screen_with_encounter(override_encounter)
	_check(keyed_screen != null and keyed_screen.sim != null,
		"the override fixture opens in S10")
	_check(int(keyed_screen._enemy_profile.get("ai_level", -1)) == 0
			and str(keyed_screen._enemy_profile.get("archetype", ""))
				== "cautious",
		"the fixture ai_level/archetype fold into the battle's profile row "
		+ "(the W4 formation-fold pattern)")
	var plain_screen = await _new_screen_with_encounter(plain_encounter)
	_check(int(plain_screen._enemy_profile.get("ai_level", -1)) == 1
			and str(plain_screen._enemy_profile.get("archetype", ""))
				== "aggressive",
		"without the fixture keys the battle profile keeps the §4.10 row "
		+ "(pirate: 1/aggressive)")

	# The same-ai_level determinism contract under the new keys: a fixture
	# CARRYING ai_level/archetype replays byte-identically.
	var keyed_outcome: Dictionary = keyed_screen.run_to_completion()
	var keyed_log: String = JSON.stringify(keyed_screen.sim.log_lines())
	_check(not keyed_outcome.is_empty()
			and str(keyed_outcome.get("result", "")) != "",
		"the override fixture battle completes (%s in %d rounds)" % [
			str(keyed_outcome.get("result", "")),
			int(keyed_outcome.get("rounds", 0))])
	var replay_screen = await _new_screen_with_encounter(override_encounter)
	var replay_outcome: Dictionary = replay_screen.run_to_completion()
	_check(JSON.stringify(replay_screen.sim.log_lines()) == keyed_log,
		"the override fixture replays byte-identical log_lines (the "
		+ "same-ai_level determinism contract under the W5-C keys)")
	_check(JSON.stringify(replay_outcome) == JSON.stringify(keyed_outcome),
		"the override fixture replays a byte-identical outcome block")

	# The dispatch is LEVEL-SENSITIVE — the evidence the fixture seam feeds.
	# With the fixture carrying NO ai_level key, flipping the pirate ROW's
	# ai_level for one run (the save/mutate/restore pattern of
	# test_world_e2e; suites are separate Godot processes) flips the same
	# seed: profile 1 = the T3 one-ply search, 0 = the T2 greedy. The
	# diverging pair at seed 4242 is deterministic.
	var plain_outcome: Dictionary = plain_screen.run_to_completion()
	var t3_log: String = JSON.stringify(plain_screen.sim.log_lines())
	var profiles: Dictionary = DataLoader.npc_config["ai_profiles"]
	var row_ai_level: int = int((profiles["pirate"] as Dictionary)["ai_level"])
	(profiles["pirate"] as Dictionary)["ai_level"] = 0
	var t2_screen = await _new_screen_with_encounter(plain_encounter)
	var t2_outcome: Dictionary = t2_screen.run_to_completion()
	var t2_log: String = JSON.stringify(t2_screen.sim.log_lines())
	(profiles["pirate"] as Dictionary)["ai_level"] = row_ai_level
	_check(int((profiles["pirate"] as Dictionary)["ai_level"]) == row_ai_level,
		"the §4.10 data row was restored after the level-sensitivity probe")
	_check(t2_log != t3_log,
		("the ai_level dispatch flips the engine: the same seed at profile "
		+ "ai_level 1 (T3, %d rounds) vs 0 (T2, %d rounds) diverges — the "
		+ "fixture override steers this seam once a decide-side consumer "
		+ "lands (W5-A dispatch reads profile_for(enemy_kind), not the "
		+ "folded profile; reported to the master)") % [
			int(plain_outcome.get("rounds", 0)),
			int(t2_outcome.get("rounds", 0))])

	keyed_screen.queue_free()
	replay_screen.queue_free()
	plain_screen.queue_free()
	t2_screen.queue_free()
	sandbox.queue_free()
	await get_tree().process_frame


# --- 12. W5-C: the whole-field round-trip fuzz -------------------------------

func _test_full_field_roundtrip() -> void:
	SandboxLib.last_config = {}
	_fixture_run_state()
	var sandbox = await _new_sandbox()
	if sandbox == null:
		return
	# 16 seeded 随机全部 rolls across compose on/off — after each roll:
	# export → import → re-export byte-identical AND every §4.7.16 field
	# group survives (the W4 pattern widened to NAME the drifted group:
	# player stats block, per-ship rows incl. equipment + captain, enemy
	# block incl. kind/ai_level/archetype/formation/morale, conditions incl.
	# seed modes/weather/wind/current/deployment).
	var details: Array[String] = []
	var rolls := 16
	for attempt in rolls:
		var player_count := 1 + (attempt * 3 + 1) % 5
		var enemy_count := 1 + (attempt * 9 + 2) % 5
		var compose := attempt % 2 == 1
		if not _apply_prestate(sandbox, player_count, enemy_count, compose):
			details.append("roll %d: prestate refused" % attempt)
			continue
		sandbox.randomize_all(601003 + attempt * 4001)
		var first: Dictionary = sandbox.export_config()
		var problems: Array[String] = []
		if not sandbox.import_json(JSON.stringify(first)):
			problems.append("the roll's export refuses to re-import")
		else:
			problems.append_array(_field_group_drift(
				first, sandbox.export_config(), ""))
		if problems.is_empty() \
				and sandbox.export_json() != JSON.stringify(first):
			problems.append("byte drift")
		if not problems.is_empty():
			details.append("roll %d (pre %d/%d compose %s): %s" % [
				attempt, player_count, enemy_count, compose,
				"; ".join(problems)])
	_check(details.is_empty(),
		"16 seeded rolls across compose on/off: export → import → re-export "
		+ "byte-identical with EVERY field group surviving (player stats / "
		+ "ship rows incl. equipment + captain / enemy block incl. "
		+ "kind+ai_level+archetype+formation+morale / conditions)"
		+ ("" if details.is_empty() else " — " + "; ".join(details)))

	# The three seed modes round-trip (the conditions group incl. seed
	# modes); the seed editor shows only for `fixed`.
	var mode_problems: Array[String] = []
	for mode in ["fixed", "random", "auto"]:
		sandbox.randomize_all(707017)
		sandbox._select_option(sandbox.seed_mode_option(), mode)
		var first: String = sandbox.export_json()
		if not sandbox.import_json(first) or sandbox.export_json() != first:
			mode_problems.append("%s: byte drift" % mode)
		if sandbox.seed_spin().visible != (mode == "fixed"):
			mode_problems.append("%s: seed spin visibility wrong" % mode)
	_check(mode_problems.is_empty(),
		"seed modes fixed/random/auto each round-trip byte-identically, the "
		+ "seed editor visible only for fixed"
		+ ("" if mode_problems.is_empty() else " — " + ", ".join(mode_problems)))

	# Positive coverage: the export DECLARES every §4.7.16 field (not just
	# "nothing drifted" — the leaf paths must exist).
	sandbox.randomize_all(808081)
	var config: Dictionary = sandbox.export_config()
	var paths: Array[String] = []
	_export_leaf_paths(config, "", paths)
	var missing: Array[String] = []
	for required in [
			"player.stats.constitution", "player.stats.intellect",
			"player.stats.charisma", "player.stats.courage",
			"player.stats.luck", "player.stats.weapon", "player.stats.armor",
			"player.morale",
			"player.ships[0].ship_type_id", "player.ships[0].cannons",
			"player.ships[0].crew", "player.ships[0].durability",
			"player.ships[0].equipment.figurehead",
			"player.ships[0].equipment.sail", "player.ships[0].captain_id",
			"enemy.kind", "enemy.ai_level", "enemy.archetype",
			"enemy.formation", "enemy.morale", "enemy.compose",
			"enemy.ships[0].ship_type_id", "enemy.ships[0].cannons",
			"enemy.ships[0].crew", "enemy.ships[0].durability",
			"enemy.ships[0].equipment.figurehead",
			"enemy.ships[0].equipment.sail", "enemy.ships[0].captain_id",
			"conditions.day", "conditions.seed_mode", "conditions.seed",
			"conditions.weather", "conditions.wind_dir",
			"conditions.current.dir", "conditions.current.strength",
			"conditions.deployment"]:
		if not paths.has(required):
			missing.append(required)
	_check(missing.is_empty(),
		"the export declares every §4.7.16 field (stats/morale/ship rows "
		+ "with equipment + captain/enemy kind+ai_level+archetype+formation"
		+ "+morale/conditions incl. seed+weather+wind+current+deployment)"
		+ ("" if missing.is_empty() else " — missing: " + ", ".join(missing)))
	sandbox.queue_free()
	await get_tree().process_frame


## Whole-field drift walk (the W5-C widening of the round-trip check):
## names every §4.7.16 field that changed between two export dicts
## ("enemy.ai_level 1 → 0"). Empty = identical.
func _field_group_drift(before, after, path: String) -> Array[String]:
	var problems: Array[String] = []
	if before is Dictionary and after is Dictionary:
		for key in before:
			var child := ("%s.%s" % [path, key]) if not path.is_empty() \
				else str(key)
			if not (after as Dictionary).has(key):
				problems.append("%s dropped" % child)
			else:
				problems.append_array(_field_group_drift(
					before[key], after[key], child))
		for key in after:
			if not (before as Dictionary).has(key):
				var child := ("%s.%s" % [path, key]) if not path.is_empty() \
					else str(key)
				problems.append("%s appeared" % child)
		return problems
	if before is Array and after is Array:
		if (before as Array).size() != (after as Array).size():
			problems.append("%s: %d rows → %d rows" % [path,
				(before as Array).size(), (after as Array).size()])
		else:
			for index in (before as Array).size():
				problems.append_array(_field_group_drift(
					before[index], after[index], "%s[%d]" % [path, index]))
		return problems
	if before != after:
		problems.append("%s: %s → %s" % [path, str(before), str(after)])
	return problems


## Every leaf path of a JSON-shaped config ("player.stats.courage",
## "player.ships[0].captain_id") — the positive-coverage walk.
func _export_leaf_paths(value, prefix: String, out: Array[String]) -> void:
	if value is Dictionary:
		for key in value:
			var child := ("%s.%s" % [prefix, key]) if not prefix.is_empty() \
				else str(key)
			_export_leaf_paths(value[key], child, out)
	elif value is Array:
		for index in (value as Array).size():
			_export_leaf_paths(value[index], "%s[%d]" % [prefix, index], out)
	else:
		out.append(prefix)


# --- Helpers ----------------------------------------------------------------

## SANDBOX_SHOT=1 (windowed, NOT headless): boots the sandbox, saves PNGs of
## both locales plus a compose-ON state to SHOT_DIR (default /tmp/opencode)
## for eyeballing the layout, then quits. Never runs in the suite.
func _screenshot_smoke() -> void:
	var dir := OS.get_environment("SHOT_DIR")
	if dir.is_empty():
		dir = "/tmp/opencode"
	SandboxLib.last_config = {}
	for locale in ["en", "zh"]:
		GameState.locale = locale
		var sandbox = await _new_sandbox()
		await get_tree().process_frame
		await get_tree().process_frame
		get_viewport().get_texture().get_image() \
			.save_png("%s/sandbox_%s.png" % [dir, locale])
		if locale == "en":
			var composed: Dictionary = JSON.parse_string(sandbox.export_json())
			(composed["enemy"] as Dictionary)["compose"] = true
			sandbox.import_json(JSON.stringify(composed))
			await get_tree().process_frame
			await get_tree().process_frame
			get_viewport().get_texture().get_image() \
				.save_png("%s/sandbox_compose.png" % dir)
		sandbox.queue_free()
		await get_tree().process_frame
	GameState.locale = "en"
	get_tree().quit(0)

func _new_sandbox():
	var sandbox = SandboxScene.instantiate()
	add_child(sandbox)
	await get_tree().process_frame
	return sandbox


func _new_screen():
	var screen = ScreenScene.instantiate()
	add_child(screen)
	screen.route_to_world = false
	await get_tree().process_frame
	return screen


## A battle screen opened directly on `encounter` (the open_battle seam).
func _new_screen_with_encounter(encounter: Dictionary):
	var screen = await _new_screen()
	screen.open_battle(encounter.duplicate(true))
	await get_tree().process_frame
	return screen


## A §4.11.11 ship instance (the suite fixture convention).
func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


## A minimal §4.11.11 fleet dict for the ecology audit (shape is irrelevant —
## the audit only ever compares snapshots).
func _fleet(id: String) -> Dictionary:
	return {
		"id": id, "role": "pirate", "nation_id": "",
		"cell": {"x": 30, "y": 40}, "ships": [_ship("sloop")],
		"seed": 1, "cargo": {}, "state": "sailing", "holds": 0, "stall": "",
	}


## The save-relevant GameState fields + the ecology, deep-copied. The
## transient `pending_encounter` routing seam is deliberately NOT audited
## (S10 consumes and clears it; decision 15 allows setting it).
func _snapshot() -> Dictionary:
	var fleets = NpcFleetsLib.new({}).fleets()
	return {
		"day": int(GameState.day),
		"gold": int(GameState.gold),
		"morale": int(GameState.morale),
		"player": (GameState.player as Dictionary).duplicate(true),
		"fleet": (GameState.fleet as Array).duplicate(true),
		"world": (GameState.world as Dictionary).duplicate(true),
		"wrecks": (GameState.wrecks as Array).duplicate(true),
		"npc_fleets": fleets.duplicate(true),
	}


## Order-independent deep equality for JSON-shaped state.
func _deep_eq(a, b) -> bool:
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for key in a:
			if not (b as Dictionary).has(key):
				return false
			if not _deep_eq(a[key], b[key]):
				return false
		return true
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for index in (a as Array).size():
			if not _deep_eq(a[index], b[index]):
				return false
		return true
	return a == b


func _check(condition: bool, description: String) -> void:
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
	else:
		print("%d of %d checks FAILED:" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - " + failure)
	get_tree().quit(0 if _failures.is_empty() else 1)
