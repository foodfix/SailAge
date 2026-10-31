extends Node
## Phase-2 task H — Phase-2 acceptance, scripted end to end
## (docs/IMPLEMENT-Phase2.md H; docs/60-COMBAT.md §4.6, §4.8, §4.10, §4.11.9,
## §4.11.10, §4.11.11.3, §4.12.4, §6; docs/90-ARCHITECTURE.md §8.1, §8.2).
##
##   godot --headless --path . tools/test_phase2_acceptance.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What makes this an acceptance test rather than another unit suite.** Every
## scenario starts from a real **save file on disk** (the current
## `save_version`, written by a plain JSON dump exactly as `SaveSystem.save()`
## would), loads it through `SaveSystem.load()`, then drives the *shipped* path:
## `Encounters` + `world_map.gd` for the contact, `battle_screen.tscn` for the
## fight (its buttons for the player, `AiFleet` for the enemy), and the §4.12.4
## battle-end sequence for the aftermath. Nothing here calls `BattleResult` /
## `BattleRewards` directly: those are reached through the screen's guarded
## seams, exactly as in production.
##
## Scenarios (docs/IMPLEMENT-Phase2.md H):
##   S1  win by cannons          → victory, salvage, XP, rep, marker removal,
##                                 spawn immunity, contact-tile return
##   S2  win by boarding+capture → captured hull joins at 25% durability with
##                                 crew 0 and cargo intact; a second capture on
##                                 a full 5-ship fleet is looted + scuttled
##   S3  retreat                 → result `retreat`, no XP/gold, marker keeps
##                                 its +1 day pursuit cooldown and survives
##   S4  lose a duel as the last ship → `EventBus.game_over("captured")`, S9
##                                 renders `gameover.captured` in both locales,
##                                 empty fleet
##
## Every scenario also asserts the save → load → battle → save round trip
## (`save_version == SaveSystem.SAVE_VERSION` on disk, reload succeeds).
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved into
## memory and written back at the end; every file this suite creates is removed
## again (start AND end), exactly like `tools/test_save*.gd`.

## Phase-5 task J: the 3-marker system is retired; the scenarios run against
## the `NpcFleets` ecology (`60-*` §4.11.11, §4.12.3) — `hostile_fleets`
## became `npc_fleets`, `kind` became `role`, and the per-kind spawn
## immunity is retired (the trickle refills the ecology).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const BattleRewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const BattleScene := preload("res://scenes/combat/battle_screen.tscn")

## Open-water fixture tile (all 8 neighbours passable) 8 tiles from Lisbon in
## the world map's variables band (lat 40°N). Phase 4 (task G): re-anchored from
## the retired P1 grid's (20,20) — that tile is polar ice on the world grid. The
## pirate is placed on the neighbour to its east, so a real day tick walks it
## into contact.
## (1023,300) is open water 8 tiles from Lisbon; the marker one tile east of it
## steps south-west and lands at Chebyshev 1 on the very next day tick (verified
## by replaying the exact §4.11.8 rule-5 tie-breaks over the shipped artifact).
const CONTACT := Vector2i(1023, 300)
const MARKER_CELL := CONTACT + Vector2i(1, 0)
const MAP_PATH := "res://data/maps/world.png"

## Pre-battle day of every fixture: the day tick that brings the pirate into
## contact advances it to [constant BATTLE_DAY], so both numbers are explicit.
## The pre-battle day. Phase 4 (task G): the battle seed includes the contact
## tile (`60-*` §4.11.1), which moved from P1's (20,20) to the world's
## (1023,300), so the day was re-searched: run day 3 → battle day 4 is the
## cannon-victory stream for this fixture (2 enemy hulls sunk, 0 captured).
const RUN_DAY := 3
const BATTLE_DAY := RUN_DAY + 1

## A weather seed that rolls `fair` on the fixture tile, so the §4.11.5 cannon
## numbers are the un-stormed ones (a storm would halve them, §4.2).
const WEATHER_SEED := 7

## §4.11.2 / §4.11.9 constants asserted below.
const SPAWN_IMMUNITY_DAYS := 3
const PURSUIT_COOLDOWN_DAYS := 1

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}
## Every `EventBus.game_over` reason seen by the current scenario.
var _game_over_reasons: Array = []


func _ready() -> void:
	_backup_saves()
	_ensure_map()
	_connect_game_over()
	await _scenario_cannon_victory()
	await _scenario_boarding_capture()
	await _scenario_retreat()
	await _scenario_last_ship_captured()
	_cleanup_saves()
	_report()


func _connect_game_over() -> void:
	EventBus.game_over.connect(func(reason: String) -> void:
		_game_over_reasons.append(reason))


# ===========================================================================
# S1 — start from a save, meet a pirate, win by cannons
# ===========================================================================

func _scenario_cannon_victory() -> void:
	print("\n=== S1: win by cannons (save → pirate contact → victory) ===")
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30,
		"provisions": 40, "water": 40}),
		_ship("brigantine", {"cannons": 10, "crew": 30})]
	_check(_start_from_save("S1", fleet, RUN_DAY, 5000, 12),
		"S1: the save loads")
	_set_explored_world()
	_ensure_map()
	SailingSimLib.reset_ledger_state()
	SailingSimLib.set_weather_seed(WEATHER_SEED)

	# The pirate lives in the §4.11.11 save block, composed by the §4.11.3
	# implementation, two tiles east of the fleet.
	var marker := _place_marker("pirate", MARKER_CELL, RUN_DAY)
	_check(not marker.is_empty(), "S1: a pirate fleet is in the npc_fleets block")
	var pair: Array = await _spawn_world()
	var world = pair[1]
	_check(world.fleet_marker_cells().size() == 1,
		"S1: the world map adopts exactly one fleet")

	# One real sea day: the marker steps 1 tile toward its anchor and contacts.
	SailingSimLib.advance_clock(1.0)
	await get_tree().process_frame
	_check(GameState.day == BATTLE_DAY,
		"S1: one day of sailing advances the clock to day %d (%d)"
		% [BATTLE_DAY, GameState.day])
	_check(str(GameState.world.get("weather", "")) != "storm",
		"S1: the fixture day is not a storm, so §4.11.5 numbers are un-halved (%s)"
		% str(GameState.world.get("weather", "")))
	_check(world.pending_encounter_id() == str(marker.get("id", "")),
		"S1: the pirate walked into contact and queued its encounter (%s)"
		% world.pending_encounter_id())

	# S10 picks the queued encounter up in `_ready` — the production handoff.
	var screen = await _open_battle_screen()
	_check(screen != null and not screen.encounter.is_empty(),
		"S1: battle_screen opens the queued encounter")
	if screen == null or screen.encounter.is_empty():
		await _free_node(pair[0])
		await _assert_round_trip("S1")
		return
	_check(int(screen.sim.day) == BATTLE_DAY,
		"S1: the engine gets the contact day (%d)" % int(screen.sim.day))
	_check(screen.sim.contact == CONTACT,
		"S1: §4.11.1 contact is the player's tile %s (%s)"
		% [str(CONTACT), str(screen.sim.contact)])
	# §4.11.1 over the engine's own pre-battle values (the daily ledger has
	# already taken that day's wages, so `gold` is the live figure, not the
	# save's).
	_check(screen.sim.seed_value() == BattleSimLib.battle_seed_formula(
			int(screen.sim.day), screen.sim.contact, int(screen.sim.gold),
			screen.sim.living_units(BattleSimLib.SIDE_PLAYER).size()),
		"S1: the seed is the §4.11.1 formula over day/contact/gold/fleet (%d)"
		% screen.sim.seed_value())

	var baseline := _reputation_snapshot()
	var gold_before := GameState.gold
	var xp_before := int(GameState.player.get("xp", 0))
	var guard: int = await _drive(screen, "cannon")
	var board_or_ram: int = _player_chain_actions(screen)
	await get_tree().process_frame

	var outcome: Dictionary = screen.last_outcome
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S1: the cannon-only fight ends in `victory` (%s, %d driver steps)"
		% [str(outcome.get("result")), guard])
	_check(board_or_ram == 0,
		"S1: the player never boarded or rammed — cannons only (%d such actions)"
		% board_or_ram)
	var sunk: Array = _as_array(outcome.get("sunk_enemy", []))
	var captured: Array = _as_array(outcome.get("captured_enemy", []))
	_check(not sunk.is_empty(),
		"S1: at least one enemy hull was sunk by cannon fire (%s)" % str(sunk))
	_check(_has_engine_kind(screen, "cannon"),
		"S1: the engine log carries cannon volleys")

	# §4.11.10: salvage = Σ floor(base_price × 0.05) over the SUNK hulls.
	var expected_salvage: int = BattleRewardsLib.salvage_for(sunk)
	var expected_neutralised: int = sunk.size() + captured.size()
	var expected_xp: int = BattleRewardsLib.xp_for(expected_neutralised,
		int(outcome.get("rounds", 0)))
	_check(int(outcome.get("salvage_gold", -1)) == expected_salvage,
		"S1: salvage gold = Σ floor(base_price × 0.05) of the sunk hulls (%d, expected %d)"
		% [int(outcome.get("salvage_gold", -1)), expected_salvage])
	_check(GameState.gold == gold_before + expected_salvage,
		"S1: the payout landed in the purse (%d → %d, +%d)"
		% [gold_before, GameState.gold, expected_salvage])
	_check(int(outcome.get("xp", -1)) == expected_xp,
		"S1: XP = 10 × %d neutralised + 5 × %d rounds = %d (got %d)"
		% [expected_neutralised, int(outcome.get("rounds", 0)), expected_xp,
			int(outcome.get("xp", -1))])
	_check(int(GameState.player.get("xp", 0)) - xp_before >= expected_xp,
		"S1: the XP reached player.xp (%d → %d)"
		% [xp_before, int(GameState.player.get("xp", 0))])

	# §4.11.10 rep: +2 with each of the two nearest ports' nations (two ports
	# selected first, their nations deduplicated).
	var expected_nations: Array = BattleRewardsLib.nearest_nations(CONTACT)
	_check(not expected_nations.is_empty(),
		"S1: the contact tile has two nearest ports (%s)" % str(expected_nations))
	var rep_ok := true
	for nation_id in expected_nations:
		if CharacterLib.reputation(str(nation_id)) \
				!= int(baseline.get(nation_id, 0)) + BattleRewardsLib.PIRATE_REP_GAIN:
			rep_ok = false
	_check(rep_ok,
		"S1: pirate rep is +2 with %s (%s)" % [str(expected_nations),
			str(_reputation_delta(baseline))])
	var untouched := true
	for nation_id in baseline:
		if str(nation_id) in expected_nations:
			continue
		if CharacterLib.reputation(str(nation_id)) != int(baseline[nation_id]):
			untouched = false
	_check(untouched, "S1: no other nation's reputation moved")
	_check(_as_dict(outcome.get("rep_deltas", {})) == _expected_rep_block(expected_nations),
		"S1: the outcome's rep_deltas is exactly %s (%s)"
		% [str(_expected_rep_block(expected_nations)),
			str(outcome.get("rep_deltas", {}))])

	# §4.11.11.2 return: the defeated fleet is removed; the per-kind spawn
	# immunity is retired with the marker system (§4.11.11.1).
	var marker_gone := true
	for left in GameState.npc_fleets:
		if str(left.get("id", "")) == str(marker.get("id", "")):
			marker_gone = false
	_check(marker_gone,
		"S1: the defeated fleet is removed from the map")
	_check(GameState.world_tile() == CONTACT,
		"S1: the fleet is back on the contact tile %s (%s)"
		% [str(CONTACT), str(GameState.world_tile())])
	_check(_as_dict(outcome.get("contact", {})) == {"x": CONTACT.x, "y": CONTACT.y},
		"S1: the outcome block reports the contact tile (%s)"
		% str(outcome.get("contact", {})))
	_check(screen.after_action_dialog().visible,
		"S1: the after-action dialog reports the battle (§4.12.4 step 5)")

	# Both locales, no raw `<key>` anywhere the screen renders.
	_check(await _locales_clean(screen, "S1"), "S1: the after-action text is localised")
	await _free_node(screen)
	await _free_node(pair[0])
	await _assert_round_trip("S1")


# ===========================================================================
# S2 — win by boarding + capture, then the full-fleet loot & scuttle
# ===========================================================================

func _scenario_boarding_capture() -> void:
	print("\n=== S2: win by boarding + capture ===")
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30,
		"provisions": 40, "water": 40})]
	# A single pirate sloop: crew 10 → defender base min(floor(10/5),20) + 6 = 8
	# (§4.11.6). The fixture day is whichever makes this fixture's §4.11.1 duel
	# stream a player win.
	var enemy := _ship("sloop", {"crew": 10, "cannons": 0, "cargo": {"wine": 6}})
	var defender_base: int = BattleSimLib.defender_duel_base(
		10, BattleSimLib.CAPTAIN_RATING_BASE + 1)
	var save_gold := 5000
	var flagship_crew := 30
	var run_day: int = _duel_day("capture", save_gold, flagship_crew, 1, 12,
		defender_base)
	_check(run_day > 0,
		"S2: a fixture day whose §4.11.1 duel stream is a player win exists (%d)"
		% run_day)
	_check(_start_from_save("S2", fleet, run_day, save_gold, 12),
		"S2: the save loads")
	_set_explored_world()
	_ensure_map()
	SailingSimLib.reset_ledger_state()
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var battle_day: int = run_day + 1
	var battle_gold := save_gold - 2 * flagship_crew
	var predicted: Dictionary = _predicted_duel(battle_day, battle_gold, 1, 12,
		defender_base)
	_check(str(predicted.get("result", "")) == "capture",
		"S2: the seeded duel for this fixture is a player win (%s, %s)"
		% [str(predicted.get("result")), str(predicted.get("rounds"))])

	var marker := _place_marker("pirate", MARKER_CELL, run_day, "pirate", [enemy])
	_check(not marker.is_empty(), "S2: a pirate marker with one sloop is placed")
	var pair: Array = await _spawn_world()
	var world = pair[1]
	SailingSimLib.advance_clock(1.0)
	await get_tree().process_frame
	_check(GameState.day == battle_day, "S2: the day tick reached day %d (%d)"
		% [battle_day, GameState.day])
	_check(world.pending_encounter_id() == str(marker.get("id", "")),
		"S2: the contact queued the encounter (%s)" % world.pending_encounter_id())

	var screen = await _open_battle_screen()
	_check(screen != null and not screen.encounter.is_empty(),
		"S2: battle_screen opens the queued encounter")
	if screen == null or screen.encounter.is_empty():
		await _free_node(pair[0])
		await _assert_round_trip("S2")
		return
	var fleet_before: int = GameState.fleet.size()
	var guard: int = await _drive(screen, "board")
	await get_tree().process_frame
	var outcome: Dictionary = screen.last_outcome
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S2: the boarding fight ends in `victory` (%s, %d steps)"
		% [str(outcome.get("result")), guard])
	_check(_has_engine_kind(screen, "board"),
		"S2: the boarding action really resolved a duel (§4.6)")
	var captured: Array = _as_array(outcome.get("captured_enemy", []))
	_check(captured.size() == 1,
		"S2: the boarded hull is captured (%d captured)" % captured.size())
	_check(_as_array(outcome.get("sunk_enemy", [])).is_empty(),
		"S2: nothing was sunk — the win came from the duel, not gunfire")
	_check(GameState.fleet.size() == fleet_before + 1,
		"S2: the captured hull joined the fleet (%d → %d)"
		% [fleet_before, GameState.fleet.size()])
	_check(GameState.fleet.size() <= FleetLib.FLEET_MAX,
		"S2: the fleet respects FLEET_MAX = %d (%d)"
		% [FleetLib.FLEET_MAX, GameState.fleet.size()])
	if captured.size() == 1:
		var hull: Dictionary = captured[0]
		var expected_durability := maxi(1, int(floor(
			float(hull.get("durability", 0)) * 0.25)))
		var joined: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
		_check(str(joined.get("ship_type_id", "")) == str(hull.get("ship_type_id", "")),
			"S2: the appended hull is the captured %s (%s)"
			% [str(hull.get("ship_type_id", "")), str(joined.get("ship_type_id", ""))])
		_check(int(joined.get("durability", -1)) == expected_durability,
			"S2: it joins at max(1, floor(current × 0.25)) = %d (got %d)"
			% [expected_durability, int(joined.get("durability", -1))])
		_check(int(joined.get("crew", -1)) == 0,
			"S2: …with crew 0 (got %d)" % int(joined.get("crew", -1)))
		_check(int(joined.get("cannons", -1)) == int(hull.get("cannons", -2))
				and _as_dict(joined.get("equipment", {})) == _as_dict(hull.get("equipment", {})),
			"S2: …cannons and equipment intact")
	_check(FleetLib.held("wine") == 6,
		"S2: the captured cargo is intact in the pooled hold (%d wine; §4.2 "
		% FleetLib.held("wine") + "distribution may carry it to the older hull)")
	_check(int(outcome.get("xp", -1)) == BattleRewardsLib.xp_for(
			captured.size(), int(outcome.get("rounds", 0))),
		"S2: XP = 10 × %d captured + 5 × %d rounds = %d (got %d)"
		% [captured.size(), int(outcome.get("rounds", 0)),
			BattleRewardsLib.xp_for(captured.size(), int(outcome.get("rounds", 0))),
			int(outcome.get("xp", -1))])
	_check(await _locales_clean(screen, "S2"), "S2: the capture dialog is localised")
	await _free_node(screen)
	await _free_node(pair[0])

	# --- S2b: a second capture with a full 5-ship fleet → loot + scuttle -----
	await _scenario_full_fleet_capture()
	await _assert_round_trip("S2")


## §4.11.7 "With a full fleet the ship is looted … and scuttled" plus §6
## "capture with full fleet and full cargo — loot-to-capacity then scuttle;
## overflow cargo reported lost".
func _scenario_full_fleet_capture() -> void:
	var fleet: Array = []
	for _index in FleetLib.FLEET_MAX:
		# Capacity 120, hold exactly full → nothing can be looted.
		fleet.append(_ship("caravel", {"cannons": 0, "crew": 15,
			"cargo": {"wine": 120}}))
	var defender_base: int = BattleSimLib.defender_duel_base(
		10, BattleSimLib.CAPTAIN_RATING_BASE + 1)
	var save_gold := 5000
	var run_day: int = _duel_day("capture", save_gold, 15, FleetLib.FLEET_MAX,
		12, defender_base)
	_check(run_day > 0,
		"S2b: a full-fleet day whose §4.11.1 duel stream is a player win exists (%d)"
		% run_day)
	_check(_start_from_save("S2b", fleet, run_day, save_gold, 12),
		"S2b: a 5-ship save loads")
	_set_explored_world()
	_ensure_map()
	SailingSimLib.reset_ledger_state()
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"S2b: the fleet is full (%d ships)" % GameState.fleet.size())

	var battle_day: int = run_day + 1
	var predicted: Dictionary = _predicted_duel(battle_day, save_gold - 2 * 15,
		FleetLib.FLEET_MAX, 12, defender_base)
	_check(str(predicted.get("result", "")) == "capture",
		"S2b: the seeded duel is a player win with a full fleet too (%s)"
		% str(predicted.get("result")))

	var enemy := _ship("sloop", {"crew": 10, "cannons": 0, "cargo": {"wine": 6}})
	_place_marker("pirate", MARKER_CELL, run_day, "pirate", [enemy])
	var pair: Array = await _spawn_world()
	var world = pair[1]
	SailingSimLib.advance_clock(1.0)
	await get_tree().process_frame
	_check(GameState.day == battle_day, "S2b: the day tick reached day %d (%d)"
		% [battle_day, GameState.day])
	_check(world.pending_encounter_id() != "", "S2b: the contact queued the encounter")
	var screen = await _open_battle_screen()
	if screen == null:
		await _free_node(pair[0])
		return
	var gold_before := GameState.gold
	await _drive(screen, "board")
	await get_tree().process_frame
	var outcome: Dictionary = screen.last_outcome
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_VICTORY,
		"S2b: the fight is a victory (%s)" % str(outcome.get("result")))
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"S2b: the fleet stays at FLEET_MAX — nothing joined (%d)"
		% GameState.fleet.size())
	_check(_as_array(outcome.get("captured_ships", [])).is_empty(),
		"S2b: no hull joined the fleet (%s)" % str(outcome.get("captured_ships")))
	_check(_as_array(outcome.get("scuttled_ships", [])) == ["sloop"],
		"S2b: the captured sloop was looted and scuttled (%s)"
		% str(outcome.get("scuttled_ships")))
	_check(int(outcome.get("cargo_overflow_lost", -1)) == 6,
		"S2b: the 6 units that could not be carried are reported lost (%d)"
		% int(outcome.get("cargo_overflow_lost", -1)))
	_check(FleetLib.held("wine") == 120 * FleetLib.FLEET_MAX,
		"S2b: the full holds gained nothing (%d wine; §4.11.7 loot-to-capacity)"
		% FleetLib.held("wine"))
	_check(GameState.gold == gold_before,
		"S2b: a captured (not sunk) hull pays no salvage (%d → %d)"
		% [gold_before, GameState.gold])
	var dialog := _joined_text(screen.after_action_lines())
	_check(dialog.contains(I18n.fmt("battle.after.scuttled", {
			"ship": I18n.t(DataLoader.get_ship_type("sloop").get("name", {}))}))
		and dialog.contains(I18n.fmt("battle.after.overflow", {"count": 6})),
		"S2b: the dialog reports the scuttle and the overflow")
	await _free_node(screen)
	await _free_node(pair[0])


# ===========================================================================
# S3 — retreat
# ===========================================================================

func _scenario_retreat() -> void:
	print("\n=== S3: retreat ===")
	var fleet: Array = [_ship("caravel", {"cannons": 4, "crew": 15,
		"provisions": 20, "water": 20})]
	_check(_start_from_save("S3", fleet, RUN_DAY, 5000, 10),
		"S3: the save loads")
	_set_explored_world()
	_ensure_map()
	SailingSimLib.reset_ledger_state()
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_game_over_reasons.clear()

	var marker := _place_marker("pirate", MARKER_CELL, RUN_DAY)
	var pair: Array = await _spawn_world()
	var world = pair[1]
	SailingSimLib.advance_clock(1.0)
	await get_tree().process_frame
	_check(world.pending_encounter_id() == str(marker.get("id", "")),
		"S3: the contact queued the encounter")
	# The marker walked one tile toward its anchor on the tick that raised the
	# contact (§4.11.11.1), so this is its *contact-time* cell; retreat must not
	# move it again.
	var marker_cell_at_contact := NpcFleetsLib.position_of(marker)
	_check(maxi(absi(marker_cell_at_contact.x - CONTACT.x),
			absi(marker_cell_at_contact.y - CONTACT.y)) == 1,
		"S3: the marker is at Chebyshev 1 of the fleet when contact opens (%s)"
		% str(marker_cell_at_contact))
	var screen = await _open_battle_screen()
	if screen == null:
		await _free_node(pair[0])
		await _assert_round_trip("S3")
		return
	var gold_before := GameState.gold
	var xp_before := int(GameState.player.get("xp", 0))

	# The `Esc` battle menu → Retreat → confirm (§4.10, §4.12.5).
	screen.begin()
	screen.open_menu()
	_check(screen.menu_open(), "S3: `Esc` opens the battle menu")
	screen.menu_button("retreat").pressed.emit()
	_check(screen.confirm_dialog() != null and screen.confirm_dialog().visible,
		"S3: retreat asks for confirmation (battle.retreat.confirm)")
	screen.confirm_dialog().accept()
	await get_tree().process_frame

	var outcome: Dictionary = screen.last_outcome
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_RETREAT,
		"S3: the confirmed retreat ends the battle with `retreat` (%s)"
		% str(outcome.get("result")))
	_check(int(outcome.get("xp", -1)) == 0 and int(GameState.player.get("xp", 0)) == xp_before,
		"S3: a retreat awards no XP (§4.10): outcome %d, player %d → %d"
		% [int(outcome.get("xp", -1)), xp_before,
			int(GameState.player.get("xp", 0))])
	_check(int(outcome.get("salvage_gold", -1)) == 0 and GameState.gold == gold_before,
		"S3: a retreat pays no salvage gold (%d, purse %d → %d)"
		% [int(outcome.get("salvage_gold", -1)), gold_before, GameState.gold])
	_check(_as_dict(outcome.get("rep_deltas", {})).is_empty(),
		"S3: a retreat books no pirate reputation (%s)" % str(outcome.get("rep_deltas", {})))
	_check(GameState.world_tile() == CONTACT,
		"S3: the fleet is on the contact tile %s (%s)"
		% [str(CONTACT), str(GameState.world_tile())])
	_check(DataLoader.is_passable(GameState.world_tile()),
		"S3: …which is passable (the §4.10 fallback is not needed here)")

	# §4.10: the enemy survives and takes the +1 day pursuit cooldown.
	var survivor: Dictionary = _marker_by_id(str(marker.get("id", "")))
	_check(not survivor.is_empty(),
		"S3: the retreated fleet still exists (%d fleets)"
		% GameState.npc_fleets.size())
	if not survivor.is_empty():
		_check(int(survivor.get("cooldown_until_day", 0))
				== GameState.day + PURSUIT_COOLDOWN_DAYS,
			"S3: §4.10 gives it a +1 day pursuit cooldown = %d (%d)"
			% [GameState.day + PURSUIT_COOLDOWN_DAYS,
				int(survivor.get("cooldown_until_day", 0))])
		_check(NpcFleetsLib.position_of(survivor) == marker_cell_at_contact,
			"S3: the fleet keeps the tile it held at contact %s (%s)"
			% [str(marker_cell_at_contact), str(NpcFleetsLib.position_of(survivor))])
		_check(NpcFleetsLib.new().contacts(GameState.world_tile()).is_empty(),
			"S3: the cooldown stops it re-opening the same battle right away")
	_check(_game_over_reasons.is_empty(),
		"S3: a retreat raises no game over (%s)" % str(_game_over_reasons))
	_check(screen.after_action_dialog().visible,
		"S3: the after-action dialog reports the retreat")
	_check(await _locales_clean(screen, "S3"), "S3: the retreat dialog is localised")
	await _free_node(screen)
	await _free_node(pair[0])
	await _assert_round_trip("S3")


# ===========================================================================
# S4 — lose a duel as the last ship → gameover.captured
# ===========================================================================

func _scenario_last_ship_captured() -> void:
	print("\n=== S4: lose a duel as the last ship → gameover.captured ===")
	# One weak ship (combat 1) against a galleon crew 120 → defender base
	# min(floor(120/5),20) + 6 = 26, so the §4.11.6 duel cannot be won and the
	# hull is the whole fleet. The day is whichever makes the loss certain.
	var fleet: Array = [_ship("brigantine", {"cannons": 10, "crew": 30,
		"provisions": 20, "water": 20})]
	var enemy := _ship("galleon", {"crew": 120, "cannons": 0, "cargo": {}})
	var defender_base: int = BattleSimLib.defender_duel_base(
		120, BattleSimLib.CAPTAIN_RATING_BASE + 1)
	var save_gold := 5000
	var run_day: int = _duel_day("defeat", save_gold, 30, 1, 1, defender_base)
	_check(run_day > 0,
		"S4: a fixture day whose §4.11.1 duel stream is a player loss exists (%d)"
		% run_day)
	_check(_start_from_save("S4", fleet, run_day, save_gold, 1),
		"S4: the save loads")
	_set_explored_world()
	_ensure_map()
	SailingSimLib.reset_ledger_state()
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	_game_over_reasons.clear()

	var battle_day: int = run_day + 1
	var predicted: Dictionary = _predicted_duel(battle_day, save_gold - 2 * 30, 1,
		1, defender_base)
	_check(str(predicted.get("result", "")) == "defeat",
		"S4: the seeded duel for this fixture is a player loss (%s, %s)"
		% [str(predicted.get("result")), str(predicted.get("rounds"))])

	_place_marker("pirate", MARKER_CELL, run_day, "pirate", [enemy])
	var pair: Array = await _spawn_world()
	var world = pair[1]
	SailingSimLib.advance_clock(1.0)
	await get_tree().process_frame
	_check(GameState.day == battle_day, "S4: the day tick reached day %d (%d)"
		% [battle_day, GameState.day])
	_check(world.pending_encounter_id() != "", "S4: the contact queued the encounter")
	var screen = await _open_battle_screen()
	if screen == null:
		await _free_node(pair[0])
		await _assert_round_trip("S4")
		return
	await _drive(screen, "board")
	await get_tree().process_frame
	var outcome: Dictionary = screen.last_outcome
	_check(str(outcome.get("result", "")) == BattleSimLib.RESULT_DEFEAT_CAPTURED,
		"S4: losing the last ship's duel yields `defeat_captured` (%s)"
		% str(outcome.get("result")))
	_check(_has_engine_kind(screen, "board"),
		"S4: the loss came from a boarding duel (§4.6)")
	_check(_as_array(outcome.get("lost_player", [])).size() == 1,
		"S4: the boarded flagship is the one that was taken (%d)"
		% _as_array(outcome.get("lost_player", [])).size())
	_check(GameState.fleet.is_empty(),
		"S4: the fleet ends empty (%d ships)" % GameState.fleet.size())
	_check(_game_over_reasons == ["captured"],
		"S4: EventBus.game_over fires exactly once with `captured` (%s)"
		% str(_game_over_reasons))

	# §4.12.4 step 5: S9 owns the screen; Continue opens it, not S3.
	screen._continue_after_battle()
	await get_tree().process_frame
	_check(screen.game_over_open(), "S4: the S9 game-over screen opens over S10")
	_check(screen.world_route_target() == "",
		"S4: no S3 route exists once a gameover fired")
	var s9 = screen.get_node_or_null("GameOverLayer/GameOverScreen")
	_check(s9 != null, "S4: the S9 overlay is instanced")
	if s9 != null:
		_check(str(s9.reason) == "captured",
			"S4: S9 accepts the `captured` reason (%s)" % str(s9.reason))
		var rendered := {}
		var expected := {}
		var locale_before: String = GameState.locale
		for locale in ["en", "zh"]:
			I18n.set_locale(locale)
			await get_tree().process_frame
			rendered[locale] = s9.reason_text()
			# Rendered through the live locale, exactly as the screen does.
			expected[locale] = I18n.fmt("gameover.reason",
				{"reason": I18n.t_key("gameover.captured")})
		I18n.set_locale(locale_before)
		await get_tree().process_frame
		_check(rendered["en"] == expected["en"]
				and rendered["en"].contains(_ui_en("gameover.captured")),
			"S4: en renders gameover.captured (%s)" % str(rendered.get("en", "")))
		_check(rendered["zh"] == expected["zh"]
				and rendered["zh"].contains(_ui_zh("gameover.captured")),
			"S4: zh renders gameover.captured (%s)" % str(rendered.get("zh", "")))
		_check(not _has_raw_key([rendered["en"], rendered["zh"]]),
			"S4: neither locale prints a raw <key> (%s / %s)"
			% [str(rendered.get("en", "")), str(rendered.get("zh", ""))])
		_check(str(rendered["en"]) != str(rendered["zh"]),
			"S4: the game-over text really switches language")
	await _free_node(screen)
	await _free_node(pair[0])
	await _assert_round_trip("S4")


# ===========================================================================
# Save fixture (docs/90-* §8.1) + load path (docs/90-* §8.2)
# ===========================================================================

## A complete current-version payload (`save_version` 4, every §8.1 key) at sea.
## Written to `user://saves/save_1.json` and loaded through
## `SaveSystem.load(1)` — the shipped path, with no migration involved
## (docs/90-* §8.2 development-stage scope: there is no migration chain).
func _current_payload(fleet: Array, day: int, gold: int, combat: int) -> Dictionary:
	return {
		"save_version": SaveSystem.SAVE_VERSION,
		"saved_at": 1793119712,
		"phase": SaveSystem.PHASE,
		"locale": "en",
		"day": day,
		"gold": gold,
		"player": {
			"nation_id": "portugal",
			"stats": {
				"leadership": 10, "seamanship": 10, "combat": combat,
				"navigation": 10, "luck": 10,
			},
			"xp": 0,
			"level": 1,
			"officers": [],
			"reputation": {
				"portugal": 10, "spain": 10, "england": 10,
				"holland": 10, "ottoman": 10, "italy": 10,
			},
		},
		"fleet": fleet.duplicate(true),
		"morale": 70,
		"world": {
			"position": {"x": CONTACT.x, "y": CONTACT.y},
			"weather": "fair",
			"map_id": SaveSystem.DEFAULT_MAP_ID,
		},
		"current_port": null,
		"known_ports": ["lisbon", "london", "seville", "amsterdam"],
		"port_investments": {},
		"discoveries_found": [],
		# The Phase-2/3 state blocks every current-version save carries
		# (docs/90-* §8.1). A fresh fixture starts them at their defaults.
		"npc_fleets": [],
		"proximity_cooldowns": {},
		"fame": 0,
		"titles": _nation_map("none"),
		"bounties": {},
		"active_quests": [],
		"completed_royal_missions": _nation_map(0),
		"discoveries_reported": [],
		"discovery_hints": {},
		"battles_won": 0,
		"retired": false,
		"retired_at": 0,
	}


## `{nation_id: value}` over `data/nations.json` (the §8.1 map-shaped keys).
func _nation_map(value) -> Dictionary:
	var out: Dictionary = {}
	for entry in DataLoader.nations_list:
		out[str(entry.get("id", ""))] = value
	return out


func _start_from_save(label: String, fleet: Array, day: int, gold: int,
		combat: int) -> bool:
	_ensure_slot_dir()
	var payload := _current_payload(fleet, day, gold, combat)
	var file := FileAccess.open(SaveSystem.slot_path(1), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	# Quit-and-restart: wipe the live state so a silent no-op load is visible.
	_clobber_state()
	var loaded: bool = SaveSystem.load(1)
	_check(loaded and SaveSystem.last_read_error.is_empty(),
		"%s: SaveSystem.load(1) restored the save file (%s)"
		% [label, SaveSystem.last_read_error])
	_check(GameState.day == day and GameState.gold == gold,
		"%s: the save's day/gold restore exactly (%d/%d)" % [label, day, gold])
	_check(GameState.fleet.size() == fleet.size()
			and (GameState.fleet[0] as Dictionary).has("equipment"),
		"%s: the fleet and its equipment blocks restore" % label)
	return loaded


## A §4.15 fleet fixture; the `ships` override exists for the hand-picked
## duel fixtures (the encounter descriptor carries a fleet-provided `ships`
## verbatim, `60-*` §4.11.11.2's per-fleet stream with a fixture override).
func _place_marker(kind: String, cell: Vector2i, day: int,
		nation_id: String = "", ships: Array = []) -> Dictionary:
	var role := "pirate" if kind == "pirate" else "hunter"
	var marker := {
		"id": "fx_%s_%d_%d" % [kind, day, GameState.npc_fleets.size()],
		"role": role,
		"nation_id": nation_id,
		"cell": {"x": cell.x, "y": cell.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": nation_id, "name_index": 0},
		"cooldown_until_day": 0,
		"seed": int(day) * 1000003 + cell.x * 7919 + cell.y * 104729,
		"dest_port_id": "",
		"dwell_until_day": 0,
		"anchor_cell": null,
		"target_fleet_id": "",
		"hunter_state": "",
		"loiter_until_day": 0,
		"home_port_id": "",
	}
	if not ships.is_empty():
		marker["ships"] = ships.duplicate(true)
	GameState.npc_fleets.append(marker)
	return marker


## The pre-battle day whose next-day §4.11.1 duel stream resolves the way
## `wanted` asks (`"capture"` for the boarding wins, `"defeat"` for the
## last-ship loss).
##
## The seed is `day × 1000003 + contact.x × 7919 + contact.y × 104729 + gold × 31
## + fleet.size() × 17` (§4.11.1), and the daily ledger takes that day's wages
## (flagship crew × 2, `20-*` §4.9) before the contact, so the battle's `gold`
## is `save_gold − 2 × flagship crew`. Searching the day is fixture selection
## over a documented, deterministic rule: it changes no pinned number and makes
## each duel scenario a guaranteed branch instead of a lucky one (§6 "duel RNG
## audit" requires exactly this reproducibility).
func _duel_day(wanted: String, save_gold: int, flagship_crew: int,
		fleet_size: int, player_base: int, defender_base: int) -> int:
	var battle_gold := save_gold - 2 * flagship_crew
	for day in range(1, 200):
		var duel := _predicted_duel(day + 1, battle_gold, fleet_size,
			player_base, defender_base)
		if str(duel.get("result", "")) == wanted:
			return day
	return -1


## The §4.11.6 duel a battle on `day` with these values resolves, over the
## §4.11.1 stream (§4.11.1: "duel rolls draw from the same stream").
func _predicted_duel(day: int, gold: int, fleet_size: int,
		player_base: int, defender_base: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = BattleSimLib.battle_seed_formula(day, CONTACT, gold, fleet_size)
	return BattleSimLib.resolve_duel(player_base, defender_base, rng)


# ===========================================================================
# Driving the shipped scene
# ===========================================================================

## A world scene under a throwaway host with routing disabled: the contact path
## (tick → `_open_encounter` → `pending_encounter` → `battle_started`) runs for
## real, but neither S4 nor S10 can replace this test's scene root.
func _spawn_world() -> Array:
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	await get_tree().process_frame
	return [host, world]


## Instances S10 the way the router does: it picks the queued
## `GameState.pending_encounter` up in `_ready` (§4.11.11.3).
func _open_battle_screen():
	var screen = BattleScene.instantiate()
	screen.route_to_world = false
	add_child(screen)
	screen.route_to_world = false
	await get_tree().process_frame
	return screen


## Drives the battle through the screen's own player API: `cannon` fires only
## the Cannon button, `board` boards whenever the Board button is legal. Both
## fall back to a click-to-move toward the enemy, then to Hold.
func _drive(screen, mode: String) -> int:
	if not screen.is_over():
		screen.begin()
	var guard := 0
	while not screen.is_over() and guard < 800:
		guard += 1
		var unit: Dictionary = screen.selected_unit()
		if unit.is_empty():
			screen._pump_enemy_turns()
			await get_tree().process_frame
			continue
		screen.select_unit(unit)
		var button: Button = screen.action_button(mode)
		if button != null and not button.disabled:
			button.pressed.emit()
			await get_tree().process_frame
			continue
		var cell := _approach_cell(screen, unit, mode == "board")
		if cell != BattleSimLib.NO_CELL and screen.move_selected(cell):
			continue
		var hold: Button = screen.action_button("hold")
		if hold != null and not hold.disabled:
			hold.pressed.emit()
			await get_tree().process_frame
		else:
			screen.perform_action("hold")
	await get_tree().process_frame
	return guard


## The reachable tile closest (Manhattan) to the nearest enemy — orthogonally
## adjacent when `want_adjacent` and any such tile is legal (boarding needs
## adjacency, §4.6).
func _approach_cell(screen, unit: Dictionary, want_adjacent: bool) -> Vector2i:
	var enemies: Array = screen.sim.living_units(BattleSimLib.SIDE_ENEMY)
	if enemies.is_empty():
		return BattleSimLib.NO_CELL
	var target: Vector2i = screen.sim.unit_cell(enemies[0])
	var best := absi(screen.sim.unit_cell(unit).x - target.x) \
		+ absi(screen.sim.unit_cell(unit).y - target.y)
	var pick := BattleSimLib.NO_CELL
	for cell in screen.sim.legal_moves(unit):
		var distance := absi(cell.x - target.x) + absi(cell.y - target.y)
		if want_adjacent and distance == 1:
			return cell
		if distance < best:
			best = distance
			pick = cell
	return pick


## Counts the player-side boarding/ram actions in the engine log (§4.11.4
## entries carry `values.side`).
func _player_chain_actions(screen) -> int:
	var count := 0
	for entry in screen.engine_log():
		if not (entry is Dictionary):
			continue
		if not (str(entry.get("kind", "")) in ["board", "ram"]):
			continue
		var values = entry.get("values", {})
		if values is Dictionary and str(values.get("side", "")) == BattleSimLib.SIDE_PLAYER:
			count += 1
	return count


func _has_engine_kind(screen, kind: String) -> bool:
	for entry in screen.engine_log():
		if entry is Dictionary and str(entry.get("kind", "")) == kind:
			return true
	return false


## Renders the after-action dialog and the log in both locales and asserts no
## raw `<key>` marker leaks into either.
func _locales_clean(screen, label: String) -> bool:
	var locale_before: String = GameState.locale
	var clean := true
	var rendered_any := ""
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		var lines: Array = screen.after_action_lines()
		lines.append_array(screen.log_lines())
		if _has_raw_key(lines):
			clean = false
			print("      raw keys in %s/%s: %s" % [label, locale, str(_raw_keys(lines))])
		rendered_any += _joined_text(lines)
	I18n.set_locale(locale_before)
	await get_tree().process_frame
	return clean and not rendered_any.is_empty()


# ===========================================================================
# Save round trip (save → load → save) per scenario
# ===========================================================================

func _assert_round_trip(label: String) -> void:
	_ensure_slot_dir()
	_check(SaveSystem.save(1), "%s: the post-battle state saves" % label)
	var on_disk := _read_slot(1)
	_check(int(on_disk.get("save_version", -1)) == SaveSystem.SAVE_VERSION,
		"%s: the re-saved file is save_version %d (%s)"
		% [label, SaveSystem.SAVE_VERSION, str(on_disk.get("save_version"))])
	_check(on_disk.has("npc_fleets") and on_disk.has("proximity_cooldowns"),
		"%s: the file carries the Phase-2 state blocks" % label)
	var hostile_before := _as_array(GameState.npc_fleets).duplicate(true)
	var cooldowns_before := _as_dict(GameState.proximity_cooldowns).duplicate(true)
	var fleet_before: Array = GameState.fleet.duplicate(true)
	var reloaded: bool = SaveSystem.load(1)
	_check(reloaded and SaveSystem.last_read_error.is_empty(),
		"%s: the v2 file reloads cleanly (%s)" % [label, SaveSystem.last_read_error])
	_check(GameState.fleet == fleet_before,
		"%s: the fleet survives the reload (%d ships)" % [label, GameState.fleet.size()])
	_check(_as_array(GameState.npc_fleets) == hostile_before,
		"%s: npc_fleets survive the reload (%d fleets)"
		% [label, GameState.npc_fleets.size()])
	_check(_as_dict(GameState.proximity_cooldowns) == cooldowns_before,
		"%s: proximity_cooldowns survive the reload (%s)"
		% [label, str(GameState.proximity_cooldowns)])


# ===========================================================================
# Fixtures & helpers
# ===========================================================================

func _ensure_map() -> void:
	if DataLoader.map == null:
		var loader := MapLoaderLib.new()
		loader.load_map(MAP_PATH, DataLoader.map_legend)
		DataLoader.map = loader


## The world state the save fixture needs: at sea, calm clock, fair weather.
func _set_explored_world() -> void:
	GameState.current_port = null
	GameState.world["clock_fraction"] = 0.0
	GameState.world["weather"] = "fair"


func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"cargo": {},
		# The §4.11.12 equipment block every current-version ship carries.
		"equipment": {"figurehead": "", "sail": ""},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


## Wipes every GameState field so a load that silently did nothing is visible.
func _clobber_state() -> void:
	GameState.locale = "zh"
	GameState.day = 1
	GameState.gold = 1
	GameState.morale = 99
	GameState.current_port = null
	GameState.player = {}
	GameState.fleet = []
	GameState.world = {"position": {"x": 0, "y": 0}, "clock_fraction": 0.0}
	GameState.known_ports = []
	GameState.port_investments = {}
	GameState.quests = []
	GameState.discoveries_found = []
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.pending_encounter = null


func _marker_by_id(id: String) -> Dictionary:
	for marker in GameState.npc_fleets:
		if marker is Dictionary and str(marker.get("id", "")) == id:
			return marker
	return {}


func _reputation_snapshot() -> Dictionary:
	var out := {}
	for nation_id in GameState.player.get("reputation", {}):
		out[str(nation_id)] = int((GameState.player["reputation"] as Dictionary)[nation_id])
	return out


func _reputation_delta(baseline: Dictionary) -> Dictionary:
	var out := {}
	for nation_id in baseline:
		var now: int = CharacterLib.reputation(str(nation_id))
		if now != int(baseline[nation_id]):
			out[str(nation_id)] = now - int(baseline[nation_id])
	return out


func _expected_rep_block(nations: Array) -> Dictionary:
	var out := {}
	for nation_id in nations:
		out[str(nation_id)] = BattleRewardsLib.PIRATE_REP_GAIN
	return out


func _ui_en(key: String) -> String:
	var value = DataLoader.ui_strings.get(key, {})
	return str((value as Dictionary).get("en", "")) if value is Dictionary else ""


func _ui_zh(key: String) -> String:
	var value = DataLoader.ui_strings.get(key, {})
	return str((value as Dictionary).get("zh", "")) if value is Dictionary else ""


func _as_array(value) -> Array:
	return (value as Array) if value is Array else []


func _as_dict(value) -> Dictionary:
	return (value as Dictionary) if value is Dictionary else {}


func _joined_text(values: Array) -> String:
	var parts: Array[String] = []
	for value in values:
		parts.append(str(value))
	return " | ".join(parts)


## Every string shaped like `I18n.t_key`'s missing-entry marker.
func _raw_keys(values: Array) -> Array[String]:
	var out: Array[String] = []
	for value in values:
		var text := str(value)
		if text.begins_with("<") and text.ends_with(">") and text.length() > 2 \
				and not text.contains(" "):
			out.append(text)
	return out


func _has_raw_key(values: Array) -> bool:
	return not _raw_keys(values).is_empty()


func _free_node(node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	await get_tree().process_frame


# ===========================================================================
# Save-file isolation (same contract as tools/test_save.gd)
# ===========================================================================

func _read_slot(slot: int) -> Dictionary:
	var text := FileAccess.get_file_as_string(SaveSystem.slot_path(slot))
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return SaveSystem.normalize_numbers(parsed) if parsed is Dictionary else {}


func _ensure_slot_dir() -> void:
	if not DirAccess.dir_exists_absolute(SaveSystem.SLOT_DIR):
		DirAccess.make_dir_recursive_absolute(SaveSystem.SLOT_DIR)


func _delete_all_slots() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")


func _backup_saves() -> void:
	_backup.clear()
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_bytes(path)
	_delete_all_slots()


func _cleanup_saves() -> void:
	_delete_all_slots()
	if _backup.is_empty():
		return
	_ensure_slot_dir()
	for slot in _backup:
		var file := FileAccess.open(SaveSystem.slot_path(int(slot)), FileAccess.WRITE)
		if file != null:
			file.store_buffer(_backup[slot])
			file.close()
	_backup.clear()


# ===========================================================================
# Harness
# ===========================================================================

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
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
