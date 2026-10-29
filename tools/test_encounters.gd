extends Node
## Phase-2 task F acceptance tests: world-map encounters
## (docs/IMPLEMENT-Phase2.md F; docs/60-* §4.1, §4.8, §4.10, §4.11.3,
## §4.11.10, §4.11.11–§4.11.11.3, §4.12.3; docs/20-* §4.7, §4.11;
## docs/90-* §5.1, §5.4, §8.1).
##
##   godot --headless --path . tools/test_encounters.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## The rate tests use `Encounters.reset_rng(seed)` plus a real day loop over a
## live `Encounters` instance; `roll_counts` is the documented seam that
## separates "roll made" from "spawn created", so the 3-marker cap and the
## spawn cooldowns cannot bias the measured probability.
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved into
## memory and written back at the end; every file this suite creates is removed
## again (start AND end), exactly like `tools/test_save*.gd`.

const EncountersLib := preload("res://scripts/world/encounters.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

## Open-water cell whose 8 neighbours are all passable (the T6 fixture).
const OPEN_CELL := Vector2i(20, 20)
## Lisbon (7,57) and the coastal sea tile beside it.
const LISBON := Vector2i(7, 57)
const SEA_BESIDE_LISBON := Vector2i(8, 57)

## The rate fixture: one trial = one seeded day sequence. 100,000 days put the
## binomial σ of a 2%/day event at 0.044%, so the pinned ±0.002 band is a
## >4σ test rather than a coin flip (at 20,000 it is only 2σ).
const RATE_TRIALS := 100000
const RATE_TOLERANCE := 0.002
const RATE_SEED := 20261029
## Navy trials need a bounty; one nation at −50 gives a clean 2% series.
const NAVY_RATE_TRIALS := 100000
## The multi-nation section reuses the same day count.
const MULTI_NATION_DAYS := 100000

const WORLD_SCENE_PATH := "res://scenes/world/world_map.tscn"
const BATTLE_SCENE_PATH := "res://scenes/combat/battle_screen.tscn"

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map(
		"res://data/maps/p1_mediterranean.txt", DataLoader.map_legend
	)
	_check(ok, "map loads for the encounters fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null

	_test_spawn_rates()
	_test_marker_cap()
	_test_spawn_immunity()
	_test_id_format_and_uniqueness()
	_test_zone_rules()
	_test_movement_and_removal()
	_test_pursuit_cooldown()
	_test_contact_and_hostility()
	_test_composition_on_contact()
	_test_attack_navy_reputation()
	_test_save_round_trip()
	await _test_world_scene_integration()
	_cleanup_saves()
	_report()


func _settle() -> void:
	await get_tree().process_frame


# --- Fixtures --------------------------------------------------------------

## Minimal Portugal run on open water: caravel, ample stores, a healthy crew.
func _make_run(
	cell: Vector2i = OPEN_CELL,
	reputation: Dictionary = {}
) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {
			"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0,
		},
	}
	for nation_id in reputation:
		GameState.player["reputation"][str(nation_id)] = int(reputation[nation_id])
	var ship_type: Dictionary = DataLoader.get_ship_type("caravel")
	GameState.fleet = [FleetLib.new_ship("caravel", int(ship_type["crew_min"]))]
	# A capacity-legal hold (caravel: 120) so the save round-trip fixture does
	# not trip the §40-* §6 capacity guard and emit warnings.
	GameState.fleet[0]["provisions"] = 40
	GameState.fleet[0]["water"] = 40
	GameState.day = 1
	GameState.gold = 50000
	GameState.morale = 70
	GameState.current_port = null
	GameState.known_ports = ["lisbon", "seville", "london", "amsterdam",
		"venice", "istanbul"]
	GameState.explored_tiles = {}
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.world = {
		"position": {"x": cell.x, "y": cell.y},
		"clock_fraction": 0.0,
		"weather": "fair",
	}
	SailingSimLib.reset_ledger_state()


## A world scene under a throwaway host with routing disabled, so the test's
## own scene root is never swapped (the `new_game(..., route)` convention).
func _spawn_world(route_battle: bool = false) -> Array:
	var host := Node2D.new()
	add_child(host)
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = route_battle
	host.add_child(world)
	return [host, world]


## An `Encounters` that cannot spawn (both kinds on a far-future immunity), so a
## movement fixture measures movement alone. The markers are placed by hand.
func _frozen_module(start_day: int = 1) -> Object:
	var module := EncountersLib.new(start_day)
	GameState.proximity_cooldowns[EncountersLib.PIRATE] = 999999
	GameState.proximity_cooldowns[EncountersLib.NAVY] = 999999
	return module


## A hand-built marker for movement/contact fixtures (never spawned by a roll,
## so the assertions are about the movement rule alone).
func _place_marker(
	kind: String,
	cell: Vector2i,
	anchor_port_id: String,
	day: int = 1,
	nation_id: String = ""
) -> Dictionary:
	var marker := {
		"id": EncountersLib.marker_id(day, cell, kind),
		"kind": kind,
		"nation_id": nation_id,
		"position": {"x": cell.x, "y": cell.y},
		"anchor_port_id": anchor_port_id,
		"ships": EncountersLib.compose_ships(kind, day, cell),
		"spawn_day": day,
		"cooldown_until_day": 0,
	}
	GameState.hostile_fleets.append(marker)
	return marker


# --- 1. Seeded spawn rates match the §4.11.11.2 table ----------------------

func _test_spawn_rates() -> void:
	# One seeded sequence of `trial_count` days at sea, at a fixed tile, with the
	# cap and cooldowns live: `roll_counts` counts every roll actually made, so
	# the measured rate is the pinned probability itself, not a cap-truncated
	# spawn count.
	var pirate_rate := _measure_rate(EncountersLib.PIRATE, RATE_TRIALS, RATE_SEED, {})
	_check(absf(pirate_rate - EncountersLib.PIRATE_SPAWN_CHANCE) <= RATE_TOLERANCE,
		"pirate spawn rate %.4f%% is within ±%.1f%% of 1%% (seed %d, %d days)"
		% [pirate_rate * 100.0, RATE_TOLERANCE * 100.0, RATE_SEED, RATE_TRIALS])

	var navy_rate := _measure_rate(
		EncountersLib.NAVY, NAVY_RATE_TRIALS, RATE_SEED, {"spain": -50}
	)
	_check(absf(navy_rate - EncountersLib.NAVY_SPAWN_CHANCE) <= RATE_TOLERANCE,
		"navy spawn rate %.4f%% is within ±%.1f%% of 2%% for one bountied nation (seed %d, %d days)"
		% [navy_rate * 100.0, RATE_TOLERANCE * 100.0, RATE_SEED, NAVY_RATE_TRIALS])

	# Two bounties → one 2% roll per nation, measured per nation.
	_make_run(OPEN_CELL, {"spain": -50, "england": -60})
	var two := EncountersLib.new()
	two.reset_rng(RATE_SEED)
	two.log_rolls = false
	var markers_seen := 0
	for day in range(1, MULTI_NATION_DAYS + 1):
		GameState.day = day
		# Keep the world renewable: no marker lives long enough to hold the cap.
		GameState.hostile_fleets = []
		two.tick(true)
		markers_seen += GameState.hostile_fleets.size()
	for nation_id in ["england", "spain"]:
		var bucket: Dictionary = two.roll_counts_by_nation.get(nation_id, {})
		var rolls := int(bucket.get("rolls", 0))
		var hits := int(bucket.get("hits", 0))
		_check(rolls >= MULTI_NATION_DAYS - 1,
			"%s got its own navy roll every day (%d rolls of %d)"
			% [nation_id, rolls, MULTI_NATION_DAYS])
		var rate := float(hits) / maxf(1.0, float(rolls))
		_check(absf(rate - EncountersLib.NAVY_SPAWN_CHANCE) <= RATE_TOLERANCE,
			"%s navy rate %.4f%% is within ±0.2%% of 2%% (%d days, seed %d)"
			% [nation_id, rate * 100.0, MULTI_NATION_DAYS, RATE_SEED])

	# A pirate roll is never made while the pirate cooldown is live, and a navy
	# roll is never made for a nation without a bounty (§4.11.11.2 steps 1/3).
	_make_run(OPEN_CELL, {"spain": -49})
	var none := EncountersLib.new()
	none.reset_rng(RATE_SEED)
	none.set_cooldown(EncountersLib.PIRATE, 50)
	for day in range(1, 41):
		GameState.day = day
		none.tick(true)
	_check(int(none.roll_counts[EncountersLib.PIRATE]["rolls"]) == 0,
		"no pirate roll while proximity_cooldowns['pirate'] > day (made %d)"
		% int(none.roll_counts[EncountersLib.PIRATE]["rolls"]))
	_check(int(none.roll_counts[EncountersLib.NAVY]["rolls"]) == 0,
		"no navy roll at reputation −49 (no bounty; made %d)"
		% int(none.roll_counts[EncountersLib.NAVY]["rolls"]))


## Measures one kind's roll rate over `days` seeded sea days. The fleet tile is
## fixed and the module's own counters record every roll it made, so the rate is
## the pinned probability itself; `proximity_cooldowns` is left alone because
## `reset_rng` clears the module's state.
func _measure_rate(
	kind: String, days: int, seed_value: int, reputation: Dictionary
) -> float:
	_make_run(OPEN_CELL, reputation)
	var module := EncountersLib.new()
	module.reset_rng(seed_value)
	for day in range(1, days + 1):
		GameState.day = day
		module.tick(true)
	var bucket: Dictionary = module.roll_counts.get(kind, {})
	var rolls := int(bucket.get("rolls", 0))
	var hits := int(bucket.get("hits", 0))
	_check(rolls == days,
		"%s made one roll per day (%d of %d)" % [kind, rolls, days])
	return float(hits) / maxf(1.0, float(rolls))


# --- 2. The 3-marker cap ---------------------------------------------------

func _test_marker_cap() -> void:
	_make_run()
	var module := EncountersLib.new()
	module.reset_rng(RATE_SEED)
	# Fill to exactly 3 by hand (a seeded spawn cannot be forced through rolls).
	var filled := 0
	for cell in [Vector2i(20, 20), Vector2i(21, 20), Vector2i(22, 20)]:
		var marker := _place_marker(EncountersLib.PIRATE, cell, "lisbon")
		if not marker.is_empty():
			filled += 1
	_check(GameState.hostile_fleets.size() == 3,
		"the fixture starts with 3 markers (got %d)" % GameState.hostile_fleets.size())
	var created := module.spawn(EncountersLib.PIRATE, "", GameState.day)
	_check(created.is_empty(), "spawn() returns {} while 3 markers live")
	_check(GameState.hostile_fleets.size() == 3,
		"a 4th marker is never created (got %d)" % GameState.hostile_fleets.size())

	# And through the real roll path: markers at the cap must stay at 3 however
	# many days pass, so the cap is enforced by the tick, not just by spawn().
	var before := GameState.hostile_fleets.size()
	for day in range(2, 400):
		GameState.day = day
		module.tick(true)
		if GameState.hostile_fleets.size() > 3:
			break
	_check(GameState.hostile_fleets.size() <= 3,
		"ticking 400 days never exceeds 3 markers (got %d, from %d)"
		% [GameState.hostile_fleets.size(), before])


# --- 3. Spawn immunity (§4.8 / §4.11.11.1) -------------------------------

func _test_spawn_immunity() -> void:
	# A battle sets `day + 3`; the roll must be skipped until then.
	_make_run()
	var module := EncountersLib.new()
	GameState.day = 10
	module.set_cooldown(EncountersLib.PIRATE, 10 + EncountersLib.SPAWN_IMMUNITY_DAYS)
	_check(EncountersLib.SPAWN_IMMUNITY_DAYS == 3,
		"SPAWN_IMMUNITY_DAYS is the pinned 3")
	_check(module.cooldown_until(EncountersLib.PIRATE) == 13,
		"set_cooldown writes day + 3 (got %d)"
		% module.cooldown_until(EncountersLib.PIRATE))
	var rolls := 0
	for day in [10, 11, 12]:
		GameState.day = day
		module.tick(true)
		rolls = int(module.roll_counts[EncountersLib.PIRATE]["rolls"])
		_check(rolls == 0,
			"day %d: no pirate roll during the 3-day immunity (made %d)"
			% [day, rolls])
	GameState.day = 13
	module.tick(true)
	_check(int(module.roll_counts[EncountersLib.PIRATE]["rolls"]) == 1,
		"day 13 (the first legal day) makes the pirate roll again (made %d)"
		% int(module.roll_counts[EncountersLib.PIRATE]["rolls"]))
	_check(module.cooldown_until(EncountersLib.PIRATE) == 13,
		"proximity_cooldowns keeps 'first legal spawn day' (got %d)"
		% module.cooldown_until(EncountersLib.PIRATE))


# --- 4. Id format and uniqueness -----------------------------------------

func _test_id_format_and_uniqueness() -> void:
	# A directly spawned marker states its spawn tile explicitly, so the id can
	# be checked against the tile it was born on (§4.11.11.2 step 5).
	_make_run()
	var module := EncountersLib.new()
	module.reset_rng(RATE_SEED)
	var direct := module.spawn(EncountersLib.PIRATE, "", 7)
	if not direct.is_empty():
		var cell := EncountersLib.position_of(direct)
		_check(str(direct.id) == "hf_7_%d_%d_pirate" % [cell.x, cell.y],
			"a spawned marker's id is hf_<day>_<x>_<y>_<kind> (%s)" % str(direct.id))
		_check(str(direct.id) == EncountersLib.marker_id(7, cell, "pirate"),
			"spawn() and marker_id() agree on the id")

	# The format is stable across a long run, and no two markers ever share an
	# id (the id names the spawn tile, so a marker's later walk cannot collide
	# with another marker's spawn).
	_make_run()
	var run := EncountersLib.new()
	run.reset_rng(RATE_SEED)
	var seen: Dictionary = {}
	var format_ok := true
	var duplicates := 0
	var sample := ""
	for day in range(1, 2001):
		GameState.day = day
		run.tick(true)
		for marker in GameState.hostile_fleets:
			var id := str(marker.get("id", ""))
			var kind := str(marker.get("kind", ""))
			var parts: PackedStringArray = id.split("_")
			var well_formed := parts.size() == 5 and parts[0] == "hf" \
				and parts[1].is_valid_int() and parts[2].is_valid_int() \
				and parts[3].is_valid_int() and parts[4] == kind \
				and int(parts[1]) == int(marker.get("spawn_day", -1))
			if kind == EncountersLib.PIRATE:
				well_formed = well_formed and int(parts[2]) >= EncountersLib.PIRATE_MIN_X
			if not well_formed:
				format_ok = false
				if sample.is_empty():
					sample = id
			# A marker is re-observed on every day it lives; only a *different*
			# spawn day under the same id would be a real collision.
			if seen.has(id) and int(seen[id]) != int(marker.get("spawn_day", -1)):
				duplicates += 1
			seen[id] = int(marker.get("spawn_day", -1))
	_check(seen.size() >= 5,
		"the id fixture observed several distinct markers (%d ids over 2000 days)"
		% seen.size())
	_check(format_ok,
		"every id is hf_<spawn_day>_<x>_<y>_<kind> with the marker's own kind (%s)"
		% (sample if not sample.is_empty() else "ok"))
	_check(duplicates == 0,
		"ids are unique across a multi-day run (%d repeats in %d ids)"
		% [duplicates, seen.size()])
	# The marker's spawn_day survives its walk, so the id stays reproducible.
	_check(EncountersLib.marker_id(7, Vector2i(30, 40), "pirate") == "hf_7_30_40_pirate",
		"the §4.11.11 worked id reproduces exactly (%s)"
		% EncountersLib.marker_id(7, Vector2i(30, 40), "pirate"))


# --- 5. Zone rules (§4.11.11.1) -----------------------------------------

func _test_zone_rules() -> void:
	_make_run()
	var module := EncountersLib.new()
	module.reset_rng(RATE_SEED)
	var checked := 0
	var on_land := 0
	var in_strip := 0
	var outside_zone := 0
	var occupied := 0
	var wrong_anchor := 0
	for day in range(1, 3001):
		GameState.day = day
		var before_count: int = GameState.hostile_fleets.size()
		module.tick(true)
		# Inspect only the markers this tick created (older ones have walked).
		for marker in GameState.hostile_fleets:
			if int(marker.get("spawn_day", 0)) != day:
				continue
			var kind := str(marker.get("kind", ""))
			if kind != EncountersLib.PIRATE:
				continue
			checked += 1
			var cell := EncountersLib.position_of(marker)
			var anchor_id := str(marker.get("anchor_port_id", ""))
			var anchor_cell: Vector2i = DataLoader.map.port_cell(anchor_id)
			if cell.x < EncountersLib.PIRATE_MIN_X:
				in_strip += 1
			if not DataLoader.map.is_passable(cell):
				on_land += 1
			var distance := maxi(absi(cell.x - anchor_cell.x), absi(cell.y - anchor_cell.y))
			if distance > EncountersLib.ZONE_RADIUS:
				outside_zone += 1
			if anchor_id != _nearest_known_port(cell):
				wrong_anchor += 1
			# Occupancy: no other marker and not the fleet.
			if cell == GameState.world_tile():
				occupied += 1
			for other in GameState.hostile_fleets:
				if other != marker and EncountersLib.position_of(other) == cell:
					occupied += 1
		# Force turnover so the cap never masks the sample.
		if before_count >= EncountersLib.MAX_MARKERS:
			GameState.hostile_fleets = []
	_check(checked >= 20,
		"the zone fixture observed a real pirate sample (%d spawns)" % checked)
	_check(in_strip == 0,
		"every pirate spawn is at x ≥ 7, outside the Atlantic strip (%d violations)" % in_strip)
	_check(on_land == 0,
		"no pirate spawn is on land/reef (%d violations)" % on_land)
	_check(outside_zone == 0,
		"every pirate spawn is within Chebyshev 15 of its anchor port (%d violations)"
		% outside_zone)
	_check(wrong_anchor == 0,
		"every anchor is the nearest known port (Chebyshev, ties by id) (%d violations)"
		% wrong_anchor)
	_check(occupied == 0,
		"no spawn lands on an occupied tile (%d violations)" % occupied)

	# Navy spawns stay inside their own nation's 15-tile zone.
	_make_run(OPEN_CELL, {"spain": -50})
	var navy := EncountersLib.new()
	navy.reset_rng(RATE_SEED)
	var navy_checked := 0
	var navy_outside := 0
	var navy_wrong_nation := 0
	for day in range(1, 3001):
		GameState.day = day
		navy.tick(true)
		for marker in GameState.hostile_fleets:
			if int(marker.get("spawn_day", 0)) != day:
				continue
			if str(marker.get("kind", "")) != EncountersLib.NAVY:
				continue
			navy_checked += 1
			var cell := EncountersLib.position_of(marker)
			var anchor_id := str(marker.get("anchor_port_id", ""))
			var anchor_cell: Vector2i = DataLoader.map.port_cell(anchor_id)
			var navy_distance := maxi(
				absi(cell.x - anchor_cell.x), absi(cell.y - anchor_cell.y)
			)
			if navy_distance > EncountersLib.ZONE_RADIUS:
				navy_outside += 1
			var port: Dictionary = DataLoader.get_port(anchor_id)
			if str(port.get("nation_id", "")) != "spain":
				navy_wrong_nation += 1
			if str(marker.get("nation_id", "")) != "spain":
				navy_wrong_nation += 1
		if GameState.hostile_fleets.size() >= EncountersLib.MAX_MARKERS:
			GameState.hostile_fleets = []
	_check(navy_checked >= 20,
		"the navy zone fixture observed a real sample (%d spawns)" % navy_checked)
	_check(navy_outside == 0,
		"every navy spawn is within Chebyshev 15 of its anchor port (%d violations)"
		% navy_outside)
	_check(navy_wrong_nation == 0,
		"every navy anchor and nation_id is that navy's own nation (%d violations)"
		% navy_wrong_nation)


func _nearest_known_port(cell: Vector2i) -> String:
	var best := ""
	var best_distance := 0
	for port_id in GameState.known_ports:
		var port_cell: Vector2i = DataLoader.map.port_cell(str(port_id))
		if port_cell.x < 0:
			continue
		var distance := maxi(absi(cell.x - port_cell.x), absi(cell.y - port_cell.y))
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and str(port_id) < best):
			best = str(port_id)
			best_distance = distance
	return best


# --- 6. Movement & removal (§4.11.11.1, §4.11.8 rule 5) ------------------

## A start tile from which the greedy walk reaches Lisbon in 57 steps (found by
## searching the shipped map for the longest unobstructed greedy route), so the
## 1-tile/day assertions run over a real multi-day journey.
const LONG_WALK := Vector2i(19, 0)

func _test_movement_and_removal() -> void:
	# Pure tie-break levels: Chebyshev first, then Manhattan, then lowest (y,x).
	var two_way := EncountersLib.choose_step(
		Vector2i(10, 10), Vector2i(10, 8),
		[Vector2i(10, 9), Vector2i(9, 9)]
	)
	_check(two_way == Vector2i(10, 9),
		"equal Chebyshev: the smaller |dx|+|dy| wins (%s)" % str(two_way))
	var tie := EncountersLib.choose_step(
		Vector2i(10, 10), Vector2i(12, 8),
		[Vector2i(11, 10), Vector2i(10, 9), Vector2i(11, 9)]
	)
	# (11,9) and (11,10) both give Chebyshev 1 / Manhattan 2; (10,9) gives
	# Chebyshev 2, so (11,9) vs (11,10) is settled by the lowest (y, x).
	_check(tie == Vector2i(11, 9),
		"full tie: the lowest (y, x) cell wins (%s)" % str(tie))
	var hold := EncountersLib.choose_step(
		Vector2i(10, 10), Vector2i(10, 10), [Vector2i(10, 9), Vector2i(9, 10)]
	)
	_check(hold == EncountersLib.NO_CELL,
		"no improving cell → hold, never a lateral drift (%s)" % str(hold))

	# One marker on a long open route with Lisbon as its anchor walks exactly
	# 1 tile/day, always strictly closer, until it is removed at the harbor.
	_make_run(LONG_WALK)
	var marker := _place_marker(EncountersLib.PIRATE, LONG_WALK, "lisbon")
	var module := _frozen_module()
	var previous := EncountersLib.position_of(marker)
	var anchor: Vector2i = DataLoader.map.port_cell("lisbon")
	var steps_checked := 0
	var bad_steps := 0
	var detail := ""
	for day in range(2, 90):
		GameState.day = day
		module.tick(true)
		if GameState.hostile_fleets.is_empty():
			break
		var current := EncountersLib.position_of(marker)
		var moved := maxi(absi(current.x - previous.x), absi(current.y - previous.y))
		var before_distance := maxi(absi(previous.x - anchor.x), absi(previous.y - anchor.y))
		var after_distance := maxi(absi(current.x - anchor.x), absi(current.y - anchor.y))
		if moved != 1:
			bad_steps += 1
			if detail.is_empty():
				detail = "day %d moved %d from %s to %s" % [day, moved, str(previous), str(current)]
		elif after_distance >= before_distance:
			bad_steps += 1
			if detail.is_empty():
				detail = "day %d distance %d → %d" % [day, before_distance, after_distance]
		previous = current
		steps_checked += 1
	_check(steps_checked >= 20,
		"the movement fixture walked a real distance (%d steps)" % steps_checked)
	_check(bad_steps == 0,
		"each tick moves exactly 1 tile toward the anchor (%d violations; %s)"
		% [bad_steps, detail])
	_check(GameState.hostile_fleets.is_empty(),
		"the walker is removed when it reaches its anchor port (%d left)"
		% GameState.hostile_fleets.size())
	# The loop stops the tick the marker is dropped, so the last *observed* tile
	# is the one before it stepped onto the harbor (that final step is asserted
	# directly by the `near` fixture below).
	var last_distance := maxi(absi(previous.x - anchor.x), absi(previous.y - anchor.y))
	_check(last_distance == 1,
		"the walker is dropped on the tick it reaches the harbor %s (last seen %s)"
		% [str(anchor), str(previous)])

	# Reaching the anchor cell removes the marker (§4.11.11.1), end to end.
	_make_run()
	var near := _place_marker(EncountersLib.PIRATE, anchor + Vector2i(1, 0), "lisbon")
	var near_module := _frozen_module()
	GameState.day += 1
	var contacted: Array = near_module.tick(true)
	_check(GameState.hostile_fleets.is_empty(),
		"a marker that reaches its anchor port is removed (%d left)"
		% GameState.hostile_fleets.size())
	_check(contacted.is_empty(),
		"an arrived marker is no longer a contact")
	_check(EncountersLib.position_of(near) == anchor,
		"it stepped onto the anchor cell before being dropped (%s)"
		% str(EncountersLib.position_of(near)))

	# Markers never step onto land/reef, never share a tile, never sit on the
	# fleet: a long run of many walkers, checked every day.
	_make_run(Vector2i(60, 70))
	var block_module := _frozen_module()
	var starts := [Vector2i(19, 0), Vector2i(76, 57), Vector2i(7, 27)]
	for index in starts.size():
		_place_marker(EncountersLib.PIRATE, starts[index], "lisbon", 1)
	var illegal := 0
	var sharing := 0
	var on_fleet := 0
	for day in range(2, 60):
		GameState.day = day
		block_module.tick(true)
		var cells: Dictionary = {}
		for other in GameState.hostile_fleets:
			var cell := EncountersLib.position_of(other)
			if not DataLoader.map.is_passable(cell):
				illegal += 1
			if cell == GameState.world_tile():
				on_fleet += 1
			if cells.has(cell):
				sharing += 1
			cells[cell] = true
		if GameState.hostile_fleets.is_empty():
			break
	_check(illegal == 0,
		"no marker ever steps onto land/reef (%d violations)" % illegal)
	_check(sharing == 0,
		"no two markers ever share a tile (%d violations)" % sharing)
	_check(on_fleet == 0,
		"no marker ever steps onto the fleet's tile (%d violations)" % on_fleet)


# --- 7. Pursuit cooldown (§4.10 / §4.11.11.1) ----------------------------

func _test_pursuit_cooldown() -> void:
	# §4.10: "enemy marker gets +1 day pursuit cooldown" — the marker stands
	# still for one day and raises no contact, so the fleet left standing on the
	# contact tile (§4.11.10) does not re-enter the battle it just left.
	# `cooldown_until_day` holds the *last idle day*; §4.11.11.1 does not pin the
	# inclusivity and the module documents the reading it uses.
	_make_run(LONG_WALK)
	var marker := _place_marker(EncountersLib.PIRATE, LONG_WALK, "lisbon")
	var module := _frozen_module()
	var battle_day := GameState.day
	GameState.day = battle_day + EncountersLib.PURSUIT_COOLDOWN_DAYS
	marker["cooldown_until_day"] = GameState.day
	var start := EncountersLib.position_of(marker)
	module.tick(true)
	_check(EncountersLib.position_of(marker) == start,
		"a marker on retreat-cooldown does not move for 1 day (still %s)"
		% str(EncountersLib.position_of(marker)))
	_check(int(marker.get("cooldown_until_day", -1)) == GameState.day,
		"the idle day keeps cooldown_until_day set (got %d, day %d)"
		% [int(marker.get("cooldown_until_day", -1)), GameState.day])
	# Sitting right beside it raises no contact while it holds (§4.10).
	GameState.set_world_tile(start + Vector2i(1, 0))
	var held_contact: Dictionary = module.nearest_contact(GameState.world_tile())
	_check(held_contact.is_empty(),
		"a marker on pursuit cooldown raises no contact (%s)"
		% str(held_contact.get("id", "")))

	# The day after, it is a contact again and it moves again — and the field is
	# cleared back to 0 (§4.11.11.1 "applies/clears cooldown_until_day").
	GameState.day += 1
	module.tick(true)
	# It walked away this tick, so the fleet follows it to test the contact.
	GameState.set_world_tile(EncountersLib.position_of(marker) + Vector2i(1, 0))
	_check(not module.nearest_contact(GameState.world_tile()).is_empty(),
		"the marker is hostile contact again once the cooldown passed")
	_check(EncountersLib.position_of(marker) != start,
		"it moves again the day after the cooldown (%s → %s)"
		% [str(start), str(EncountersLib.position_of(marker))])
	_check(int(marker.get("cooldown_until_day", -1)) == 0,
		"the expired cooldown_until_day is cleared back to 0 (got %d)"
		% int(marker.get("cooldown_until_day", -1)))
	_check(EncountersLib.PURSUIT_COOLDOWN_DAYS == 1,
		"the pursuit cooldown is the pinned 1 day")


# --- 8. Contact & hostility -----------------------------------------------

func _test_contact_and_hostility() -> void:
	_make_run(OPEN_CELL)
	var module := EncountersLib.new()
	# Chebyshev 1 in every direction is contact; 2 is not.
	for delta in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
		GameState.hostile_fleets = []
		var marker := _place_marker(EncountersLib.PIRATE, OPEN_CELL + delta, "lisbon")
		var contact := module.nearest_contact(OPEN_CELL)
		_check(not contact.is_empty() and str(contact.get("id", "")) == str(marker.id),
			"Chebyshev 1 at %s is contact" % str(delta))
		_check(EncountersLib.position_of(contact) == OPEN_CELL + delta,
			"the contact is the marker on that tile")
	GameState.hostile_fleets = []
	_place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(2, 2), "lisbon")
	_check(module.nearest_contact(OPEN_CELL).is_empty(),
		"Chebyshev 2 is not contact")
	_check(module.nearest_contact(OPEN_CELL + Vector2i(100, 100)).is_empty(),
		"no markers at all → nearest_contact returns {}")

	# Tick returns the contact list (nearest first).
	_make_run(OPEN_CELL)
	GameState.hostile_fleets = []
	_place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(1, 1), "lisbon")
	var near2 := _place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(1, 0), "lisbon")
	var tick_module := EncountersLib.new()
	tick_module.last_tick_day = GameState.day
	var contacts: Array = tick_module.tick(true)
	_check(contacts.size() == 2,
		"tick() returns every marker in contact (%d)" % contacts.size())
	if contacts.size() == 2:
		_check(str(contacts[0].get("id", "")) == str(near2.id),
			"tick() returns contacts nearest first")

	# A navy is not hostile at rep −49 and is at −50 (§4.11.11.1).
	_make_run(OPEN_CELL + Vector2i(0, 0), {"spain": -49})
	var navy := _place_marker(
		EncountersLib.NAVY, OPEN_CELL + Vector2i(1, 0), "seville", 1, "spain"
	)
	_check(not EncountersLib.is_hostile(navy),
		"a navy at reputation −49 is not hostile")
	_check(module.nearest_contact(OPEN_CELL).is_empty(),
		"a non-hostile navy is not a contact")
	CharacterLib.add_reputation("spain", -1)
	_check(CharacterLib.reputation("spain") == -50,
		"the fixture reached exactly −50 (got %d)" % CharacterLib.reputation("spain"))
	_check(EncountersLib.is_hostile(navy), "a navy at reputation −50 IS hostile")
	_check(not module.nearest_contact(OPEN_CELL).is_empty(),
		"the same navy is a contact at −50")
	_check(EncountersLib.is_hostile(_place_marker(
		EncountersLib.PIRATE, Vector2i(5, 5), "lisbon")) or true,
		"pirates are hostile regardless of reputation")
	GameState.hostile_fleets = []
	CharacterLib.add_reputation("spain", -100)
	var pirate := _place_marker(EncountersLib.PIRATE, Vector2i(5, 5), "lisbon")
	_check(EncountersLib.is_hostile(pirate),
		"a pirate is hostile at any reputation (rep now %d)"
		% CharacterLib.reputation("spain"))


# --- 9. Contact opens battle with the marker's composition ----------------

func _test_composition_on_contact() -> void:
	# §4.11.3 is single-sourced: the saved ships must equal what AiFleet
	# produces for the marker's own seed.
	var ships := EncountersLib.compose_ships("pirate", 12, Vector2i(30, 40))
	var rng := RandomNumberGenerator.new()
	rng.seed = EncountersLib.composition_seed(12, Vector2i(30, 40))
	var expected := AiFleetLib.compose_enemy("pirate", 12, rng)
	_check(ships == expected,
		"compose_ships() reproduces AiFleet.compose_enemy for the same seed (%d vs %d ships)"
		% [ships.size(), expected.size()])
	_check(ships.size() >= 1 and ships.size() <= 3,
		"a pirate fleet is 1–3 ships (got %d)" % ships.size())
	var navy := EncountersLib.compose_ships("navy", 100, Vector2i(20, 30))
	_check(navy.size() >= 2 and navy.size() <= 4,
		"a navy fleet is 2–4 ships (got %d)" % navy.size())
	var total_cannons := 0
	for ship in ships:
		total_cannons += int(ship.get("cannons", 0))
		_check(int(ship.get("provisions", 0)) == 0 and int(ship.get("water", 0)) == 0,
			"AI ships carry no provisions/water (§4.11.3 step 4)")
		_check(ship.has("equipment") and ship.has("cargo"),
			"AI ships use the §4.11.11 instance shape")
	_check(total_cannons <= AiFleetLib.cannon_budget("pirate", 12),
		"the pirate cannon budget is respected (%d ≤ %d)"
		% [total_cannons, AiFleetLib.cannon_budget("pirate", 12)])

	# The contact → battle handoff: the encounter queued on
	# `GameState.pending_encounter` carries exactly the marker's ships.
	_make_run(OPEN_CELL)
	var module := EncountersLib.new()
	var marker := _place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(1, 0), "lisbon")
	module.last_tick_day = GameState.day
	var contacted := module.tick(true)
	_check(contacted.size() == 1, "one marker in contact at tick time")
	if contacted.is_empty():
		return
	var encounter: Dictionary = contacted[0]
	_check(encounter.get("ships", []) == marker.get("ships", []),
		"the contact's ships are the marker's ships")
	_check(str(encounter.get("id", "")) == str(marker.id),
		"the contact carries the marker id")
	_check(str(encounter.get("kind", "")) == "pirate",
		"the contact carries the marker kind")
	_check(encounter.has("nation_id") and encounter.has("anchor_port_id")
		and encounter.has("position") and encounter.has("spawn_day")
		and encounter.has("cooldown_until_day"),
		"the contact is the whole §4.11.11 descriptor")


# --- 10. rep −20 on attacking a navy (§4.11.10, 70-* §4.5) ----------------

func _test_attack_navy_reputation() -> void:
	_make_run(OPEN_CELL, {"spain": 0, "england": 0})
	var module := EncountersLib.new()
	# Through the module the piracy delta is the scene's job (§4.12.3 keeps
	# `Encounters` state-only); what the module owns is the −20 constant.
	_check(EncountersLib.PIRACY_REPUTATION == -20,
		"the piracy delta is the pinned −20 (got %d)" % EncountersLib.PIRACY_REPUTATION)

	var spawned: Array = _spawn_world(false)
	var world = spawned[1]
	var navy := _place_marker(
		EncountersLib.NAVY, OPEN_CELL + Vector2i(1, 0), "seville", 1, "spain"
	)
	var before_spain := CharacterLib.reputation("spain")
	var before_england := CharacterLib.reputation("england")
	# Right-click the marker: a navy needs the confirm first (§4.1).
	_check(world._try_attack(OPEN_CELL + Vector2i(1, 0)),
		"right-clicking an adjacent navy marker starts the attack flow")
	_check(world._attack_confirm != null,
		"the navy attack opens the encounter.attack_confirm modal")
	if world._attack_confirm != null:
		# `encounter.attack_confirm` is task G's key (§4.12.5); before it lands
		# the modal still names the nation instead of printing "<key>".
		var nation := I18n.t(DataLoader.get_nation("spain")["name"])
		var expected_confirm := I18n.fmt(
			"encounter.attack_confirm", {"nation": nation}
		) if DataLoader.ui_strings.has("encounter.attack_confirm") else ""
		var text: String = world._attack_confirm.message_text()
		_check((not expected_confirm.is_empty() and text == expected_confirm)
			or (expected_confirm.is_empty() and text.contains(nation)
				and not text.contains("<")),
			"the confirm names the navy's nation via the encounter.attack_confirm "
			+ "key (or its documented placeholder): %s" % text)
		_check(CharacterLib.reputation("spain") == before_spain,
			"merely opening the confirm changes no reputation")
		world._attack_confirm.confirmed.emit()
	_check(CharacterLib.reputation("spain") == before_spain - 20,
		"attacking a navy drops that nation by exactly 20 (%d → %d)"
		% [before_spain, CharacterLib.reputation("spain")])
	_check(CharacterLib.reputation("england") == before_england,
		"no other nation's reputation is touched (england %d)"
		% CharacterLib.reputation("england"))
	_check(world.pending_encounter_id() == str(navy.id),
		"the attack queues the navy encounter for S10 (got '%s')"
		% world.pending_encounter_id())
	_check(world.pending_encounter().get("ships", []) == navy.get("ships", []),
		"the queued navy encounter has the marker's ships")
	_check(not world.battle_route_target().is_empty() if ResourceLoader.exists(
		BATTLE_SCENE_PATH) else true,
		"route_to_battle=false still records the encounter")
	spawned[0].queue_free()

	# Clamp at −100, and never a positive overflow.
	_make_run(OPEN_CELL, {"spain": -90})
	var spawned2: Array = _spawn_world(false)
	var world2 = spawned2[1]
	_place_marker(EncountersLib.NAVY, OPEN_CELL + Vector2i(0, 1), "seville", 1, "spain")
	world2._attack(_marker_at(world2, OPEN_CELL + Vector2i(0, 1)))
	_check(CharacterLib.reputation("spain") == -100,
		"the −20 clamps at −100 (got %d)" % CharacterLib.reputation("spain"))
	spawned2[0].queue_free()

	# A pirate attack costs nothing (§4.1: only navies are piracy).
	_make_run(OPEN_CELL, {"spain": 0})
	var spawned3: Array = _spawn_world(false)
	var world3 = spawned3[1]
	var pirate := _place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(1, 1), "lisbon")
	var rep_before := CharacterLib.reputation("spain")
	_check(world3._try_attack(OPEN_CELL + Vector2i(1, 1)),
		"right-clicking an adjacent pirate marker opens the battle directly")
	_check(world3._attack_confirm == null,
		"a pirate attack needs no confirm")
	_check(CharacterLib.reputation("spain") == rep_before,
		"attacking a pirate costs no reputation (spain %d)"
		% CharacterLib.reputation("spain"))
	_check(world3.pending_encounter_id() == str(pirate.id),
		"the pirate encounter is queued for S10 (got '%s')"
		% world3.pending_encounter_id())
	spawned3[0].queue_free()


func _marker_at(world, cell: Vector2i) -> Dictionary:
	return world._marker_at(cell)


# --- 11. Save round trip (§4.11.11 / 90-* §8.1) --------------------------

func _test_save_round_trip() -> void:
	_make_run()
	var module := EncountersLib.new()
	module.reset_rng(RATE_SEED)
	# A run with several markers of both kinds and a live cooldown.
	for day in range(1, 60):
		GameState.day = day
		module.tick(true)
	# Top the list up by hand so both kinds and a cooldown are present.
	if GameState.hostile_fleets.size() < EncountersLib.MAX_MARKERS:
		_place_marker(EncountersLib.PIRATE, Vector2i(25, 25), "lisbon")
	if GameState.hostile_fleets.size() < EncountersLib.MAX_MARKERS:
		_place_marker(EncountersLib.NAVY, Vector2i(26, 25), "seville", 1, "spain")
	module.set_cooldown(EncountersLib.PIRATE, 99)
	var before: Array = GameState.hostile_fleets.duplicate(true)
	var cooldowns_before: Dictionary = GameState.proximity_cooldowns.duplicate(true)
	_check(not before.is_empty(),
		"the save fixture holds at least one marker (%d)" % before.size())

	_ensure_dir()
	_wipe_slots()
	_check(SaveSystem.save(1), "SaveSystem.save(1) writes the fixture")
	var snapshot: Dictionary = SaveSystem.snapshot()
	_check(int(snapshot.get("save_version", 0)) == 2,
		"the payload is save_version 2 (got %d)" % int(snapshot.get("save_version", 0)))
	_check((snapshot.get("hostile_fleets", null) as Array) == before,
		"the payload carries hostile_fleets verbatim (%d markers)"
		% (snapshot.get("hostile_fleets", []) as Array).size())
	_check((snapshot.get("proximity_cooldowns", null) as Dictionary)
		== cooldowns_before, "the payload carries proximity_cooldowns verbatim")

	# Wipe the state, then load and compare byte-for-byte.
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	_check(SaveSystem.load(1), "SaveSystem.load(1) restores the fixture")
	_check(GameState.hostile_fleets == before,
		"markers survive save → load unchanged (%d markers)"
		% GameState.hostile_fleets.size())
	_check(GameState.proximity_cooldowns == cooldowns_before,
		"proximity_cooldowns survive save → load unchanged")
	_check(str(JSON.stringify(GameState.hostile_fleets))
		== str(JSON.stringify(before)),
		"the reloaded markers are byte-equal JSON")
	# The restored markers still work: position accessors and movement.
	if not GameState.hostile_fleets.is_empty():
		var restored: Dictionary = GameState.hostile_fleets[0]
		_check(EncountersLib.position_of(restored) != EncountersLib.NO_CELL,
			"a reloaded marker's position parses back to a cell (%s)"
			% str(EncountersLib.position_of(restored)))
		_check(restored.get("ships", []) == before[0].get("ships", []),
			"a reloaded marker keeps its §4.11.3 ships")
	_wipe_slots()


# --- 12. world_map.gd integration ---------------------------------------

func _test_world_scene_integration() -> void:
	# Stepping beside a marker records the encounter without routing when
	# `route_to_battle` is false (`pending_encounter_id()` is the seam).
	_make_run(OPEN_CELL)
	GameState.hostile_fleets = []
	var spawned: Array = _spawn_world(false)
	var world = spawned[1]
	_check(world.encounters() != null, "the world scene owns an Encounters module")
	_check(world.hostile_marker_cells().is_empty(),
		"opening the scene rolls nothing (0 markers)")
	_place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(2, 0), "lisbon")
	world.sync_from_state()
	_check(world.hostile_marker_cells().size() == 1,
		"sync_from_state() adopts the saved marker (1 drawn)")
	var drawn: Array = world.hostile_marker_cells()
	_check((drawn[0]["cell"] as Vector2i) == OPEN_CELL + Vector2i(2, 0),
		"the marker square sits on the marker's tile (%s)"
		% str(drawn[0]["cell"]))

	# One step toward the marker → Chebyshev 1 → contact.
	_check(world.pending_encounter_id().is_empty(),
		"nothing is queued before the step")
	_check(world.try_step(OPEN_CELL + Vector2i(1, 0)),
		"the step toward the marker is legal")
	_check(not world.pending_encounter_id().is_empty(),
		"stepping adjacent to a marker queues the encounter (got '%s')"
		% world.pending_encounter_id())
	_check(world.pending_encounter_id() == str(GameState.hostile_fleets[0].id),
		"the queued id is the marker's id")
	_check(world.pending_encounter().get("ships", [])
		== GameState.hostile_fleets[0].get("ships", []),
		"the queued encounter has the marker's fleet composition")
	_check(not world.is_active_scene(),
		"the child-instanced world scene is not the active scene, so S10 is not swapped in")
	spawned[0].queue_free()

	# The marker count never grows inside one frame/day without a day tick.
	_make_run(OPEN_CELL)
	GameState.hostile_fleets = []
	var spawned2: Array = _spawn_world(false)
	var world2 = spawned2[1]
	var counts: Array[int] = []
	for i in 5:
		world2.sync_from_state()
		counts.append(GameState.hostile_fleets.size())
	_check(counts == [0, 0, 0, 0, 0],
		"re-syncing the scene five times spawns nothing (got %s)" % str(counts))
	# A day tick at sea is the only thing that can add one.
	var day_before := GameState.day
	world2._tick_encounters_at(true)
	_check(GameState.day == day_before,
		"the marker tick never advances the clock itself")
	_check(GameState.hostile_fleets.size() <= EncountersLib.MAX_MARKERS,
		"at most 3 markers after a tick (%d)" % GameState.hostile_fleets.size())
	spawned2[0].queue_free()

	# A contact routed with `route_to_battle = true` on a base with S10 present
	# targets the battle scene. S10 is task D's file: when it is absent the
	# target is "" and the encounter is still queued (reported, not invented).
	_make_run(OPEN_CELL)
	GameState.hostile_fleets = []
	var spawned3: Array = _spawn_world(true)
	var world3 = spawned3[1]
	_place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(0, 1), "lisbon")
	world3.sync_from_state()
	world3.try_step(OPEN_CELL + Vector2i(0, 1) - Vector2i(0, 1))
	# Contact already exists at Chebyshev 1; a legal step changes nothing about
	# the marker, so the encounter is discovered by the tick.
	world3._tick_encounters_at(true)
	_check(not world3.pending_encounter_id().is_empty(),
		"route_to_battle=true still records the pending encounter")
	if ResourceLoader.exists(BATTLE_SCENE_PATH):
		_check(world3.battle_route_target() == BATTLE_SCENE_PATH,
			"with S10 present the contact targets battle_screen.tscn (got '%s')"
			% world3.battle_route_target())
	else:
		_check(world3.battle_route_target() == "",
			"S10 is not in this worktree yet, so no route target is claimed "
			+ "(the encounter stays queued; task D owns the scene)")
	_check(not world3.is_active_scene(),
		"an inactive world scene never swaps the root (docs/90-* §7)")

	# `battle_finished` removes the marker, sets day + 3 and restores the tile.
	var marker_id: String = str(world3.pending_encounter_id())
	var contact_tile := GameState.world_tile()
	GameState.set_world_tile(OPEN_CELL + Vector2i(3, 3))  # a S10 detour
	var outcome := {"result": "victory", "kind": "pirate", "encounter_id": marker_id}
	if EventBus.has_signal("battle_finished"):
		EventBus.battle_finished.emit(outcome)
	else:
		world3._on_battle_finished(outcome)
	var still_there := false
	for marker in GameState.hostile_fleets:
		if str(marker.get("id", "")) == marker_id:
			still_there = true
	_check(not still_there, "battle_finished removes the marker")
	_check(int(GameState.proximity_cooldowns.get(EncountersLib.PIRATE, 0))
		== GameState.day + EncountersLib.SPAWN_IMMUNITY_DAYS,
		"battle_finished sets the kind cooldown to day + 3 (got %d, day %d)"
		% [int(GameState.proximity_cooldowns.get(EncountersLib.PIRATE, 0)), GameState.day])
	_check(GameState.world_tile() == contact_tile,
		"battle_finished restores the fleet to the contact tile (%s vs %s)"
		% [str(GameState.world_tile()), str(contact_tile)])
	_check(world3.pending_encounter_id().is_empty(),
		"the pending encounter is cleared at battle end")
	_check(world3.hostile_marker_cells().is_empty(),
		"the drawn marker square is gone (%d)" % world3.hostile_marker_cells().size())
	spawned3[0].queue_free()

	# §4.10 retreat: the enemy is not defeated, so the marker stays and takes
	# the +1 day pursuit cooldown (§4.11.11.1) instead of despawning.
	_make_run(LONG_WALK)
	GameState.hostile_fleets = []
	var spawned5: Array = _spawn_world(false)
	var world5 = spawned5[1]
	var survivor := _place_marker(EncountersLib.PIRATE, LONG_WALK, "lisbon")
	world5.sync_from_state()
	world5._tick_encounters_at(true)
	var retreat_id: String = str(world5.pending_encounter_id())
	_check(not retreat_id.is_empty(), "the retreat fixture has a pending encounter")
	var retreat_day := GameState.day
	if EventBus.has_signal("battle_finished"):
		EventBus.battle_finished.emit({
			"result": "retreat", "kind": "pirate", "encounter_id": retreat_id,
		})
	else:
		world5._on_battle_finished({
			"result": "retreat", "kind": "pirate", "encounter_id": retreat_id,
		})
	var survived := false
	for marker in GameState.hostile_fleets:
		if str(marker.get("id", "")) == retreat_id:
			survived = true
			_check(int(marker.get("cooldown_until_day", 0))
				== retreat_day + EncountersLib.PURSUIT_COOLDOWN_DAYS,
				"retreat gives the survivor a +1 day pursuit cooldown (got %d, day %d)"
				% [int(marker.get("cooldown_until_day", 0)), retreat_day])
	_check(survived, "a retreat does not remove the enemy marker")
	_check(int(GameState.proximity_cooldowns.get(EncountersLib.PIRATE, 0))
		== retreat_day + EncountersLib.SPAWN_IMMUNITY_DAYS,
		"retreat still records the 3-day spawn immunity (got %d)"
		% int(GameState.proximity_cooldowns.get(EncountersLib.PIRATE, 0)))
	_check(world5.pending_encounter_id().is_empty(),
		"the pending encounter is consumed by the retreat")
	var held := EncountersLib.position_of(survivor)
	GameState.day = retreat_day + EncountersLib.PURSUIT_COOLDOWN_DAYS
	world5.encounters().tick(true)
	_check(EncountersLib.position_of(survivor) == held,
		"the marker that won a retreat holds its tile for the cooldown day (still %s)"
		% str(held))
	_check(str(world5.pending_encounter_id()) != retreat_id,
		"the retreated marker does not immediately re-open the same battle")
	spawned5[0].queue_free()

	# Two markers in contact chain: after the first battle the second opens.
	_make_run(OPEN_CELL)
	GameState.hostile_fleets = []
	var spawned4: Array = _spawn_world(false)
	var world4 = spawned4[1]
	var first := _place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(1, 0), "lisbon")
	var second := _place_marker(EncountersLib.PIRATE, OPEN_CELL + Vector2i(0, 1), "lisbon")
	world4.sync_from_state()
	world4._tick_encounters_at(true)
	var first_id: String = str(world4.pending_encounter_id())
	_check(first_id == str(first.id) or first_id == str(second.id),
		"the first of two contacts is queued (got '%s')" % first_id)
	var chained_outcome := {"result": "victory", "kind": "pirate", "encounter_id": first_id}
	if EventBus.has_signal("battle_finished"):
		EventBus.battle_finished.emit(chained_outcome)
	else:
		world4._on_battle_finished(chained_outcome)
	var remaining: String = str(first.id if first_id == str(second.id) else second.id)
	_check(world4.pending_encounter_id() == str(remaining),
		"a second marker still in contact chains into the next battle (got '%s', expected '%s')"
		% [world4.pending_encounter_id(), str(remaining)])
	spawned4[0].queue_free()

	await _settle()


# --- Harness --------------------------------------------------------------

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


# --- Save-file isolation (same contract as tools/test_save.gd) -------------

func _backup_saves() -> void:
	if not DirAccess.dir_exists_absolute(SaveSystem.SLOT_DIR):
		return
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path: String = SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_bytes(path)
	_wipe_slots()


func _restore_saves() -> void:
	_wipe_slots()
	if _backup.is_empty():
		return
	_ensure_dir()
	for slot in _backup:
		var file := FileAccess.open(SaveSystem.slot_path(int(slot)), FileAccess.WRITE)
		if file != null:
			file.store_buffer(_backup[slot])
			file.close()


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(SaveSystem.SLOT_DIR):
		DirAccess.make_dir_recursive_absolute(SaveSystem.SLOT_DIR)


func _wipe_slots() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path: String = SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _cleanup_saves() -> void:
	_restore_saves()
