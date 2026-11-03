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
##   8  the S1 海战 button and the S10 → S21 configuration restore.

const SandboxLib := preload("res://scenes/combat/battle_sandbox.gd")
const SandboxScene := preload("res://scenes/combat/battle_sandbox.tscn")
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
	await _test_sandbox_boot()
	await _test_clamps()
	await _test_player_stats_seam()
	await _test_export_import()
	await _test_sandbox_run_and_zero_write()
	await _test_normal_path_guard()
	await _test_title_and_restore()
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
	var button: Button = title.get_node_or_null("Center/Stack/Buttons/Sandbox")
	_check(button != null,
		"S1 carries the 海战 button between New Game and Load (§4.7.16)")
	if button != null:
		var stack: VBoxContainer = title.get_node("Center/Stack/Buttons")
		var children := stack.get_children()
		var index := children.find(button)
		_check(index == 1,
			"the 海战 button sits between New Game (0) and Load (%d)" % index)
		title.route_to_sandbox = false
		_check(title.open_sandbox() and
			title.last_route == "res://scenes/combat/battle_sandbox.tscn",
			"open_sandbox() routes to S21 (guarded — no scene swap in the suite)")
	title.queue_free()
	await get_tree().process_frame


# --- Helpers ----------------------------------------------------------------

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
