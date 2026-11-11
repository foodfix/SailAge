extends SceneTree
## M5 golden-trace oracle — docs/IMPLEMENT-WebMigration.md §3 M5 ("golden
## traces recorded from the GDScript harness act as oracle").
##
## Headless (no scene file; the autoloads already exist under /root, their
## `_ready` has not run yet, so DataLoader is loaded explicitly):
##
##   godot --headless --path . --script res://tools/battle_golden_trace.gd
##
## Builds ONE pinned battle — fixed seed + fixed composition + ai_level 1
## + a fixed player fleet-order sequence — and drives it to completion with
## the frozen oracle modules (`battle_sim.gd` + `ai_fleet.gd` +
## `fleet_commander.gd` + `ai_search.gd` through the ai_level dispatch),
## exactly the way `scenes/combat/battle_screen.gd` drives it (the §4.9b
## FleetCommander order layer, the engine's own `_apply_decision` seam).
##
## Output: deterministic compact JSON lines (stdout), sorted keys:
##
##   {"type":"scenario", …}   the pinned constants + resolved profile + θ
##   {"type":"round", …}      one per round: orders, per-unit state, the
##                            round's structured §4.11.4 log entries
##   {"type":"final", …}      the §4.12.2 outcome subset + final rng.state
##
## The contract is consumed line-for-line by `server/tests/test_golden_traces.py`,
## which replays the same scenario through the Python port and diffs. Every
## number here is either a doc pin (§4.11.1 seed formulas, §4.12.1 cap 40),
## a fixture constant, or data (`data/ship_types.json`); no value is invented.
##
## Determinism audit: run twice, diff stdout — the harness itself writes
## nothing else (no timestamps, no elapsed time, no hash-order iteration).

## The pinned scenario (frozen contract). `test_golden_traces.py` re-pins
## every value below and refuses a silent harness edit.
const SEED := 7000001
const DAY := 30
const GOLD := 0
const CONTACT := Vector2i(100, 100)
const WEATHER := "fair"
const WIND_DIR := "W"
## Contact-tile current pinned explicitly: strength 0 (no current) keeps the
## trace independent of the currents raster while exercising the §4.3a
## `current_mod` seam. The reversal is a lookup-time rule (§6.5), not here.
const CURRENT := {"dir": "", "strength": 0}
const ENEMY_KIND := "navy"
const ENEMY_NATION := "spain"
## §4.8a side-morale starts, pinned through the §4.12.1 optional keys (the
## S21 seam) so the trace never depends on a live `GameState.morale` read.
## The player start is a pinned 60 (the oracle's own default would read
## `GameState.morale`, 70 at new game; the Python port's no-autoload default
## is 0 — the divergence is reported, and pinning both sides here is what
## keeps this trace a pure engine diff). The AI start is the §4.8a default for
## a legacy navy flagship without a captain card — clamp(40 + (10 + 10×2),
## 20, 90) = 70.
const PLAYER_MORALE := 60
const ENEMY_MORALE := 70
## §4.12.1: `run_to_completion`'s round cap is 40 (correction 12).
const MAX_ROUNDS := 40

const HULL_ID := "brigantine"
const PLAYER_SHIP_COUNT := 2
const ENEMY_SHIP_COUNT := 3

## The S21 `player_stats` seam (§4.12.1) — pinned so no GameState read is
## part of the trace. gunnery 60 ⇒ the §4.4a one-turn reload (50+ gate) and
## the +2 §4.4 gunnery bonus; swordplay 40 ⇒ the §4.11.6 duel base.
const PLAYER_STATS := {
	"attributes": {
		"constitution": 10, "intellect": 10, "charisma": 10,
		"courage": 10, "luck": 10,
	},
	"skills": {
		"seamanship": 0, "navigation": 0, "swordplay": 40,
		"gunnery": 60, "appraisal": 0, "negotiation": 0,
		"cartography": 0, "rumour": 0,
	},
	"equipment": {"weapon": "", "armor": ""},
}

## The fixed player fleet-order sequence (§4.9b five-tuple, the
## `battle_order` wire shape §0.3). Each entry applies from its
## `until_round` upward; the last entry is terminal. The bands make the
## standstill escorts accelerate (`[1,1]`), the line close (`[2,5]`), then
## press (`[1,3]`, the assigned target flips to fleet index 1).
const PLAYER_ORDERS := [
	{
		"until_round": 2,
		"order": {
			"station": [10, 15], "desired_heading8": 0,
			"desired_speed_band": [1, 1], "assigned_target": 0,
			"discipline": false,
		},
	},
	{
		"until_round": 5,
		"order": {
			"station": [10, 15], "desired_heading8": 0,
			"desired_speed_band": [2, 5], "assigned_target": 0,
			"discipline": false,
		},
	},
	{
		"until_round": 999,
		"order": {
			"station": [10, 15], "desired_heading8": 0,
			"desired_speed_band": [1, 3], "assigned_target": 1,
			"discipline": false,
		},
	},
]

const SIDE_PLAYER := "player"
const SIDE_ENEMY := "enemy"

var _sim
var _sim_lib
var _ai_lib
var _fc_lib
var _loader
var _profile: Dictionary = {}
var _fc_state: Dictionary = {}
var _fc_round := -1
var _orders: Array = []
var _log_seen := 0
var _round_record: Dictionary = {}


func _initialize() -> void:
	var loader = get_root().get_node_or_null("DataLoader")
	_loader = loader
	if loader == null:
		push_error("battle_golden_trace: DataLoader autoload missing")
		quit(1)
		return
	if not bool(loader.get("load_ok")):
		loader.load_all()
	if not bool(loader.get("load_ok")):
		push_error("battle_golden_trace: data load failed: %s" % [loader.get("load_errors")])
		quit(1)
		return
	_sim_lib = load("res://scripts/combat/battle_sim.gd")
	_ai_lib = load("res://scripts/combat/ai_fleet.gd")
	_fc_lib = load("res://scripts/combat/fleet_commander.gd")

	var player_ships: Array = []
	for index in PLAYER_SHIP_COUNT:
		player_ships.append(_fixture_ship())
	var enemy_ships: Array = []
	for index in ENEMY_SHIP_COUNT:
		enemy_ships.append(_fixture_ship())

	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	_sim = _sim_lib.new({
		"player_ships": player_ships,
		"enemy_ships": enemy_ships,
		"enemy_kind": ENEMY_KIND,
		"enemy_nation": ENEMY_NATION,
		"day": DAY,
		"gold": GOLD,
		"contact": CONTACT,
		"weather": WEATHER,
		"seed": SEED,
		"rng": rng,
		"wind_dir": WIND_DIR,
		"current": CURRENT.duplicate(true),
		"player_stats": PLAYER_STATS.duplicate(true),
		"player_morale": PLAYER_MORALE,
		"enemy_morale": ENEMY_MORALE,
	})
	_profile = _ai_lib.profile_for(ENEMY_KIND)

	_emit({
		"type": "scenario",
		"seed": SEED,
		"day": DAY,
		"gold": GOLD,
		"contact": {"x": CONTACT.x, "y": CONTACT.y},
		"weather": WEATHER,
		"wind_dir": WIND_DIR,
		"current": CURRENT.duplicate(true),
		"enemy_kind": ENEMY_KIND,
		"enemy_nation": ENEMY_NATION,
		"player_morale": PLAYER_MORALE,
		"enemy_morale": ENEMY_MORALE,
		"max_rounds": MAX_ROUNDS,
		"hull_id": HULL_ID,
		"player_ships": player_ships,
		"enemy_ships": enemy_ships,
		"player_stats": PLAYER_STATS.duplicate(true),
		"profile": _profile,
		"theta": _ai_lib_theta(),
		"orders": PLAYER_ORDERS.duplicate(true),
	})

	_sim.start()
	var anchor: Dictionary = _sim.living_units(SIDE_ENEMY)[0]
	_fc_state = _fc_lib.initial_state(
		str(_profile.get("formation", "swarm")),
		_sim.unit_cell(anchor),
		int(anchor.get("heading8", _sim_lib.HEADING_WEST)))

	var guard := 0
	while not _sim.is_over() and _sim.round_number() <= MAX_ROUNDS:
		guard += 1
		if guard > MAX_ROUNDS * _sim.units().size() * 2 + 10:
			break
		var round_no: int = _sim.round_number()
		if round_no != _fc_round:
			_begin_round(round_no)
		var unit: Dictionary = _sim.current_unit()
		if unit.is_empty():
			_sim.end_turn()
			continue
		if str(unit.get("side", "")) == SIDE_ENEMY:
			_sim._apply_decision(unit, _ai_lib.decide(_sim, unit, _order_for(unit), {}))
		else:
			_player_turn(unit, _player_order(round_no))
		if not _sim.is_over():
			_sim.end_turn()
	_finish_round()

	_emit_final()
	quit(0)


# --- Scenario fixtures ------------------------------------------------------


## The §4.11.11 ship-instance shape at the hull's data defaults (durability,
## crew_min, armament_slots) — the same fixture `battle_ai_harness.gd` uses.
func _fixture_ship() -> Dictionary:
	var ship_type: Dictionary = _loader.call("get_ship_type", HULL_ID)
	return {
		"ship_type_id": HULL_ID,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": int(ship_type.get("armament_slots", 0)),
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}


func _ai_lib_theta() -> Array:
	var ai_search = load("res://scripts/combat/ai_search.gd")
	var archetype := str(_profile.get("archetype", "balanced"))
	if archetype == "aggressive":
		return Array(ai_search.THETA_AGGRESSIVE)
	if archetype == "cautious":
		return Array(ai_search.THETA_CAUTIOUS)
	return Array(ai_search.THETA_BALANCED)


func _player_order(round_no: int) -> Dictionary:
	for entry in PLAYER_ORDERS:
		if round_no <= int(entry["until_round"]):
			return entry["order"]
	return PLAYER_ORDERS[-1]["order"]


# --- The §4.9b fleet-commander layer (battle_screen.gd's guarded caller) ----


func _begin_round(round_no: int) -> void:
	_finish_round()
	_fc_round = round_no
	var anchor: Dictionary = {}
	var living: Array = _sim.living_units(SIDE_ENEMY)
	if not living.is_empty():
		anchor = living[0]
	var view := {
		"units": _sim.units(),
		"round": round_no,
		"enemy_kind": ENEMY_KIND,
		"side_morale": int(_sim.side_morale(SIDE_ENEMY)),
	}
	_orders = _fc_lib.generate_orders(view, _profile, _fc_state)
	_round_record = {
		"type": "round",
		"round": round_no,
		"phase": str(_fc_state.get("phase", "")),
		"orders": {
			"player": _player_order(round_no).duplicate(true),
			"enemy": _encoded_orders(_orders),
		},
		"ships": _ships_state(),
	}


func _order_for(unit: Dictionary) -> Dictionary:
	var unit_index := int(unit.get("index", -1))
	for entry in _orders:
		if int(entry.get("index", -1)) == unit_index:
			return entry.get("order", {})
	return {}


func _encoded_orders(orders: Array) -> Array:
	var out: Array = []
	for entry in orders:
		var order: Dictionary = entry.get("order", {})
		var station = order.get("station", Vector2i.ZERO)
		out.append({
			"index": int(entry.get("index", -1)),
			"order": {
				"station": [station.x, station.y],
				"desired_heading8": int(order.get("desired_heading8", 0)),
				"desired_speed_band": [
					int((order.get("desired_speed_band", [0, 0]) as Array)[0]),
					int((order.get("desired_speed_band", [0, 0]) as Array)[1]),
				],
				"assigned_target": int(order.get("assigned_target", -1)),
				"discipline": bool(order.get("discipline", false)),
				"phase": str(order.get("phase", "")),
			},
		})
	return out


# --- The player turn (session.py's `battle_action` seam, same semantics) ----


## `server/session.py::_intent_battle_action` for the player: pick the first
## legal velocity (the engine's own enumeration) matching the order's
## `desired_heading8` + `desired_speed_band`, then fire at the assigned
## target with the first loaded side (`port`, then `starboard`, §4.11.8
## rule 2's side pick), else hold. The shot type is round for a player actor
## (§4.12.1.1).
func _player_turn(unit: Dictionary, order: Dictionary) -> void:
	var heading := int(order.get("desired_heading8", -1))
	var band: Array = order.get("desired_speed_band", [])
	if heading >= 0 and band.size() >= 2:
		for vel in _sim.legal_velocities(unit):
			var magnitude := int(floor(sqrt(float(vel.x * vel.x + vel.y * vel.y))))
			if _sim_lib.heading8_of(vel) == heading \
					and magnitude >= int(band[0]) and magnitude <= int(band[1]):
				_sim.apply_velocity(unit, vel)
				break
	var target := _target_for(unit, int(order.get("assigned_target", -1)))
	if target.is_empty():
		_sim.hold(unit)
		return
	if _sim.can_cannon(unit, target, _sim_lib.BROADSIDE_PORT):
		_sim.cannon(unit, target, _sim_lib.BROADSIDE_PORT, _sim_lib.ROUND_SHOT)
	elif _sim.can_cannon(unit, target, _sim_lib.BROADSIDE_STARBOARD):
		_sim.cannon(unit, target, _sim_lib.BROADSIDE_STARBOARD, _sim_lib.ROUND_SHOT)
	else:
		_sim.hold(unit)


func _target_for(unit: Dictionary, assigned_index: int) -> Dictionary:
	var living: Array = _sim.living_units(SIDE_ENEMY)
	if assigned_index >= 0:
		for enemy in living:
			if int(enemy.get("index", -1)) == assigned_index:
				return enemy
	if living.is_empty():
		return {}
	var origin: Vector2i = _sim.unit_cell(unit)
	living.sort_custom(func(a, b) -> bool:
		var da: int = maxi(absi(_sim.unit_cell(a).x - origin.x),
			absi(_sim.unit_cell(a).y - origin.y))
		var db: int = maxi(absi(_sim.unit_cell(b).x - origin.x),
			absi(_sim.unit_cell(b).y - origin.y))
		if da != db:
			return da < db
		return int(a.get("index", 0)) < int(b.get("index", 0)))
	return living[0]


# --- Trace emission ---------------------------------------------------------


func _finish_round() -> void:
	if _round_record.is_empty():
		return
	var lines: Array = _sim.log_lines()
	var new_lines: Array = []
	for index in range(_log_seen, lines.size()):
		new_lines.append(lines[index])
	_log_seen = lines.size()
	_round_record["log"] = new_lines
	_emit(_round_record)
	_round_record = {}


func _ships_state() -> Array:
	var out: Array = []
	for unit in _sim.units():
		var ship: Dictionary = unit.get("ship", {})
		var cell: Vector2i = _sim.unit_cell(unit)
		var vel: Vector2i = unit.get("vel", Vector2i.ZERO)
		out.append({
			"id": "%s_%d" % [str(unit.get("side", "")), int(unit.get("index", 0))],
			"side": str(unit.get("side", "")),
			"index": int(unit.get("index", 0)),
			"pos": {"x": cell.x, "y": cell.y},
			"vel": {"x": vel.x, "y": vel.y},
			"heading8": int(unit.get("heading8", 0)),
			"reload": {
				"port": int(unit.get("reload_port", 0)),
				"starboard": int(unit.get("reload_starboard", 0)),
			},
			"hull": int(ship.get("durability", 0)),
			"crew": int(unit.get("crew", 0)),
			"alive": bool(unit.get("alive", false)),
		})
	return out


func _emit_final() -> void:
	var outcome: Dictionary = _sim.outcome()
	var captured: Array = []
	for ship in outcome.get("captured_enemy", []):
		captured.append(str(ship.get("ship_type_id", "")))
	var lost: Array = []
	for ship in outcome.get("lost_player", []):
		lost.append(str(ship.get("ship_type_id", "")))
	_emit({
		"type": "final",
		"result": str(outcome.get("result", "")),
		"rounds": int(outcome.get("rounds", _sim.round_number())),
		"kind": str(outcome.get("kind", "")),
		"nation_id": str(outcome.get("nation_id", "")),
		"surrendered_enemy": int(outcome.get("surrendered_enemy", 0)),
		"sunk_enemy": outcome.get("sunk_enemy", []),
		"captured_enemy": captured,
		"sunk_player": outcome.get("sunk_player", []),
		"lost_player": lost,
		"salvage_gold": int(outcome.get("salvage_gold", 0)),
		"xp": int(outcome.get("xp", 0)),
		"morale_delta": int(outcome.get("morale_delta", 0)),
		"rep_deltas": outcome.get("rep_deltas", {}),
		"rng_state": int(_sim.rng.state),
		"log": _sim.log_lines(),
	})


func _emit(payload: Dictionary) -> void:
	print(JSON.stringify(payload, "", true))
