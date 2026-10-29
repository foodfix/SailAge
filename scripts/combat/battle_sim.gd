class_name BattleSim
extends RefCounted
## Turn engine for grid sea battles (docs/60-COMBAT.md §4.2–§4.7, §4.11.4–§4.11.9).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4). The engine
## **never mutates `GameState`**: it deep-copies the ship instances handed to
## [method _init] and owns every battle-local field itself (units, RNG, log,
## outcome tallies). Reading the player's effective combat stat / worn
## equipment (§4.11.5, §4.11.6) is the only GameState access.
##
## Interface: every method/signature pinned in docs/60-* §4.12.1, plus the
## seams a caller needs that the pin leaves implicit:
##   * [method units] / [method living_units] — the AI (§4.12.1.1) and S10
##     must enumerate tokens;
##   * [method combat_rating] / [method effective_speed] /
##     [method effective_max_durability] — the §4.11.5/§4.11.12 numbers;
##   * [method seed_value] — the §4.11.1 seed actually used (tests/audit);
##   * [method retreat] / [method offer_surrender] — the two menu-only
##     outcomes of §4.11.9/§4.11.7 (they are not per-unit actions);
##   * [method log_lines] — the structured log of §4.11.4 "damage order".
##
## One implementation of every formula lives here; `ai_fleet.gd`, the S10
## screen and the S11 modal all call into this file instead of copying numbers.

const CharacterLib := preload("res://scripts/player/character.gd")

# --- Grid & deployment (docs/60-* §4.2, §4.11.2) ---------------------------

const GRID_WIDTH := 16
const GRID_HEIGHT := 10
## §4.2 bands: player ships start at x ≤ 2, enemy ships at x ≥ 13.
const PLAYER_BAND_MAX_X := 2
const ENEMY_BAND_MIN_X := 13
## §4.11.2 concrete tiles, indexed by fleet index (0 = flagship).
const PLAYER_DEPLOYMENT: Array = [
	Vector2i(1, 4), Vector2i(1, 5), Vector2i(1, 3), Vector2i(1, 6), Vector2i(1, 2),
]
const ENEMY_DEPLOYMENT: Array = [
	Vector2i(14, 4), Vector2i(14, 5), Vector2i(14, 3), Vector2i(14, 6), Vector2i(14, 2),
]
## "No destination cell" marker for non-move decisions / queries.
const NO_CELL := Vector2i(-1, -1)

# --- Sides -----------------------------------------------------------------

const SIDE_PLAYER := "player"
const SIDE_ENEMY := "enemy"

# --- Movement (docs/60-* §4.3, §4.11.4) ------------------------------------

const MP_ORTHOGONAL := 1
const MP_DIAGONAL := 2
## The eight neighbour offsets; diagonals cost [constant MP_DIAGONAL].
const DIRECTIONS: Array = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]

# --- Cannon (docs/60-* §4.4, §4.11.5) --------------------------------------

const CANNON_RANGE_MIN := 1
const CANNON_RANGE_MAX := 3
## range_factor at range 1 / 2 / 3 (§4.4).
const CANNON_RANGE_FACTOR := {1: 1.0, 2: 0.75, 3: 0.5}
const CANNON_BASE_MULTIPLIER := 2
## §4.2 / §4.11.5: storm weather scales cannon damage.
const STORM_CANNON_MULTIPLIER := 0.75
const STORM_WEATHER := "storm"
## §4.11.4: firing in round N blocks round N+1 (sets `round + 2`).
const RELOAD_ROUNDS := 2
## §4.4: `+ floor(effective combat / 10)` damage.
const COMBAT_BONUS_DIVISOR := 10

# --- Ram (docs/60-* §4.5, §4.11.5) ----------------------------------------

const RAM_TARGET_FRACTION := 0.25
const RAM_ATTACKER_FRACTION := 0.10
## §4.5 galley identity rule (oar/hybrid attackers).
const OAR_RAM_MULTIPLIER := 1.25
const OAR_SHIP_CLASSES: Array[String] = ["oar", "hybrid"]

# --- Duel (docs/60-* §4.6, §4.11.6) ---------------------------------------

const DUEL_WINS_NEEDED := 3
const DUEL_MAX_ROUNDS := 5
const DUEL_ROUND_MAX_ROLL := 20
const DUEL_CREW_DIVISOR := 5
const DUEL_CREW_CAP := 20
const CAPTAIN_RATING_BASE := 5
## §4.6 "fleet tier": pirate tier 1, navy tier 2.
const FLEET_TIER := {"pirate": 1, "navy": 2}

# --- Outcome (docs/60-* §4.11.9, §4.11.10) --------------------------------

const RESULT_VICTORY := "victory"
const RESULT_DEFEAT_SUNK := "defeat_sunk"
const RESULT_DEFEAT_CAPTURED := "defeat_captured"
const RESULT_RETREAT := "retreat"
const RESULT_SURRENDER := "surrender"
const RESULT_UNFINISHED := ""
const RESULT_VALUES: Array[String] = [
	RESULT_VICTORY, RESULT_DEFEAT_SUNK, RESULT_DEFEAT_CAPTURED,
	RESULT_RETREAT, RESULT_SURRENDER,
]
const XP_PER_ENEMY_NEUTRALIZED := 10
const XP_PER_ROUND := 5
const PIRATE_REP_GAIN := 2
const NAVY_REP_PENALTY := -20
const SALVAGE_FRACTION := 0.05
const NEAREST_PORT_COUNT := 2

# --- Battle state (§4.11.1 seed, §4.11.11 instance shape) ------------------

var enemy_kind := "pirate"
var enemy_nation := ""
var day := 0
var gold := 0
var contact := Vector2i.ZERO
var weather := "calm"
## Optional caller-supplied id (§4.12.2 `encounter_id`), "" when not given.
var encounter_id := ""
## One stream per battle (§4.11.1); duels draw from it (§4.11.6).
var rng := RandomNumberGenerator.new()

var _seed := 0
var _player_ships: Array = []
var _enemy_ships: Array = []
var _units: Array = []
var _order: Array = []
var _round := 1
var _current := -1
var _action_taken := false
var _started := false
var _over := false
var _result := RESULT_UNFINISHED
var _flagship_index := 0

# Outcome tallies (§4.12.2).
var _sunk_enemy: Array = []
var _sunk_enemy_by_player: Array = []
var _captured_enemy: Array = []
var _surrendered_enemy := 0
var _sunk_player: Array = []
var _lost_player: Array = []
var _player_last_cause := ""
var _log: Array = []


## §4.12.1 config keys: `player_ships`, `enemy_ships`, `enemy_kind`,
## `enemy_nation`, `day`, `gold`, `contact`, `weather`, optional `seed` and
## optional `encounter_id`. Ship instances are deep-copied so the caller's
## `GameState.fleet` can never be touched by a battle.
##
## Optional `rng`: a `RandomNumberGenerator` the caller has **already used** to
## compose the enemy fleet (the §4.11.1 "duel rolls draw from the same stream,
## after deployment and enemy composition" rule). When absent the sim seeds a
## fresh stream from `seed` (or the §4.11.1 formula). The §4.12.1 config table
## lists no key for that hand-off, so it is added here as an optional extra —
## `seed` alone stays sufficient for every test that does not audit the
## composition/duel continuity.
func _init(config: Dictionary) -> void:
	_player_ships = _copy_ships(config.get("player_ships", []))
	_enemy_ships = _copy_ships(config.get("enemy_ships", []))
	enemy_kind = str(config.get("enemy_kind", "pirate"))
	enemy_nation = str(config.get("enemy_nation", ""))
	day = int(config.get("day", 0))
	gold = int(config.get("gold", 0))
	contact = to_cell(config.get("contact", Vector2i.ZERO))
	weather = str(config.get("weather", "calm"))
	encounter_id = str(config.get("encounter_id", ""))
	var shared = config.get("rng", null)
	if shared is RandomNumberGenerator:
		rng = shared
		_seed = int(shared.seed)
	else:
		_seed = int(config.get("seed", battle_seed_formula(day, contact, gold, _player_ships.size())))
		rng.seed = _seed


# --- §4.11.1 seed ----------------------------------------------------------

## `day × 1000003 + contact.x × 7919 + contact.y × 104729 + gold × 31 +
## fleet.size() × 17`, plain integer arithmetic (no `hash()`), so the value is
## identical on every platform and every caller can audit a battle.
static func battle_seed_formula(p_day: int, p_contact: Vector2i, p_gold: int, p_fleet_size: int) -> int:
	return p_day * 1000003 + p_contact.x * 7919 + p_contact.y * 104729 \
		+ p_gold * 31 + p_fleet_size * 17


## The seed actually in use (config `seed` override wins).
func seed_value() -> int:
	return _seed


# --- Lifecycle (§4.12.1) ---------------------------------------------------

func start() -> void:
	if _started:
		return
	_started = true
	_units.clear()
	for index in _player_ships.size():
		_units.append(_make_unit(SIDE_PLAYER, index, _player_ships[index],
			_deploy_cell(SIDE_PLAYER, index)))
	for index in _enemy_ships.size():
		_units.append(_make_unit(SIDE_ENEMY, index, _enemy_ships[index],
			_deploy_cell(SIDE_ENEMY, index)))
	_roll_captain_ratings()
	_round = 1
	_current = -1
	_action_taken = false
	_flagship_index = _lowest_living_index(SIDE_PLAYER)
	_check_over()
	if _over:
		return
	_build_order()
	_advance()


func round_number() -> int:
	return _round


func is_over() -> bool:
	return _over


func current_unit() -> Dictionary:
	if _over or _current < 0 or _current >= _order.size():
		return {}
	var unit = _order[_current]
	if not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return {}
	return unit


## True when `unit` is the ship whose turn it is (§4.3 "each round, every
## living ship acts once"). A not-yet-started battle has no cursor, so
## configuration-time calls are allowed and only the action budget is enforced.
func is_acting(unit: Dictionary) -> bool:
	if not _started:
		return true
	var current := current_unit()
	return not current.is_empty() and is_same(current, unit)


## Ends the acting unit's turn; advances to the next living unit in initiative
## order, rolling into the next round (§4.11.4). Dead units are skipped.
func end_turn() -> void:
	if _over:
		return
	_action_taken = false
	_check_over()
	if _over:
		return
	_advance()


## §4.12.2 outcome block; `{}` until [method is_over] (§4.12.1 pin).
##
## `captured_enemy` is the list the application seam (§4.12.3, task C) takes
## into the fleet. §4.11.7 resolves an AI surrender "exactly as a duel win
## (capture/loot)", so a surrendered hull appears **both** in that list and in
## the `surrendered_enemy` counter — the counter is a sub-tally for the
## after-action dialog's wording, never an addition to the list.
func outcome() -> Dictionary:
	if not _over:
		return {}
	var neutralized := _sunk_enemy.size() + _captured_enemy.size()
	var rounds_lasted := maxi(_round, 1)
	# §4.10 "Retreating forfeits nothing but costs no XP": a retreat awards
	# nothing, while everything already earned (salvage, navy rep) stands.
	var xp := 0 if _result == RESULT_RETREAT \
		else neutralized * XP_PER_ENEMY_NEUTRALIZED + rounds_lasted * XP_PER_ROUND
	return {
		"result": _result,
		"rounds": rounds_lasted,
		"kind": enemy_kind,
		"nation_id": enemy_nation,
		"encounter_id": encounter_id,
		"contact": {"x": contact.x, "y": contact.y},
		"sunk_enemy": _sunk_enemy.duplicate(),
		"captured_enemy": _captured_enemy.duplicate(true),
		"surrendered_enemy": _surrendered_enemy,
		"sunk_player": _sunk_player.duplicate(),
		"lost_player": _lost_player.duplicate(true),
		"salvage_gold": _salvage_gold(),
		"xp": xp,
		"rep_deltas": _rep_deltas(),
		"cargo_overflow_lost": 0,
	}


# --- Unit enumeration (S10 / AiFleet seam) --------------------------------

## Every unit dict, living or not (killed units keep their last state so the
## screen can animate a sinking token). Never `null` entries.
func units() -> Array:
	return _units.duplicate()


## Living units of `side`, in fleet-index order.
func living_units(side: String) -> Array:
	var out: Array = []
	for unit in _units:
		if unit.side == side and bool(unit.get("alive", false)):
			out.append(unit)
	out.sort_custom(func(a, b) -> bool: return int(a.index) < int(b.index))
	return out


# --- Grid / movement (docs/60-* §4.2, §4.11.4) ----------------------------

func unit_cell(unit: Dictionary) -> Vector2i:
	return to_cell(unit.get("cell", NO_CELL))


## Every tile the unit can reach with its remaining MP, in `(y, x)` order.
## Orthogonal steps cost 1, diagonal 2; a diagonal is legal only when both
## orthogonal corner tiles are inside the grid (§4.11.4); occupied tiles are
## never entered.
func legal_moves(unit: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return out
	var start := unit_cell(unit)
	var reach := _reachable(unit)
	var cells: Array = []
	for cell in reach:
		if cell == start:
			continue
		cells.append(cell)
	cells.sort_custom(func(a, b) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	for cell in cells:
		out.append(cell)
	return out


## Applies a legal move, spending the cheapest path cost (§4.11.4). Returns
## false (state untouched) for an illegal/occupied/out-of-grid destination or
## after the unit's one action has already been spent.
func move_to(unit: Dictionary, cell: Vector2i) -> bool:
	if _over or _action_taken or not is_acting(unit):
		return false
	if not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return false
	if cell.x < 0 or cell.y < 0 or cell.x >= GRID_WIDTH or cell.y >= GRID_HEIGHT:
		return false
	if cell == unit_cell(unit):
		return false
	var reach := _reachable(unit)
	if not reach.has(cell):
		return false
	unit["mp"] = int(unit.get("mp", 0)) - int(reach[cell])
	unit["cell"] = cell
	return true


## `MP = ShipType.speed + sail speed delta` (§4.11.4, §4.11.12).
func effective_speed(unit: Dictionary) -> int:
	var ship = unit.get("ship", {})
	if not (ship is Dictionary):
		return 0
	var ship_type: Dictionary = DataLoader.get_ship_type(str(ship.get("ship_type_id", "")))
	return int(ship_type.get("speed", 0)) + equipment_modifier(ship, "sail", "speed")


## §4.11.12: base durability + figurehead durability delta. Used for ram
## damage (§4.11.5) and as the current-durability cap.
func effective_max_durability(ship: Dictionary) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(str(ship.get("ship_type_id", "")))
	return int(ship_type.get("durability", 0)) + equipment_modifier(ship, "figurehead", "durability")


## §4.11.5 combat rating: the player's effective combat on the flagship, 0 on
## player escorts, `5 + fleet tier` on AI ships.
func combat_rating(unit: Dictionary) -> int:
	if not (unit is Dictionary):
		return 0
	if unit.side == SIDE_PLAYER:
		return player_effective_combat() if int(unit.index) == _flagship_index else 0
	return CAPTAIN_RATING_BASE + int(FLEET_TIER.get(enemy_kind, 1))


# --- Cannon (docs/60-* §4.4, §4.11.5) --------------------------------------

func can_cannon(unit, target) -> bool:
	if not (unit is Dictionary) or not (target is Dictionary):
		return false
	if not bool(unit.get("alive", false)) or not bool(target.get("alive", false)):
		return false
	if unit.side == target.side:
		return false
	var ship = unit.get("ship", {})
	if not (ship is Dictionary) or int(ship.get("cannons", 0)) < 1:
		return false
	if _round < int(unit.get("reload_until_round", 1)):
		return false
	var distance := _chebyshev(unit_cell(unit), unit_cell(target))
	return distance >= CANNON_RANGE_MIN and distance <= CANNON_RANGE_MAX


## `base = floor(cannons × 2 × range_factor) + floor(combat_rating / 10)`;
## storm weather applies `floor(base × 0.75)` (§4.11.5).
func cannon_damage(unit: Dictionary, target: Dictionary) -> int:
	var distance := _chebyshev(unit_cell(unit), unit_cell(target))
	var factor := float(CANNON_RANGE_FACTOR.get(distance, 0.0))
	var cannons := int(unit.get("ship", {}).get("cannons", 0))
	var base := int(floor(float(cannons) * CANNON_BASE_MULTIPLIER * factor))
	base += int(floor(float(combat_rating(unit)) / COMBAT_BONUS_DIVISOR))
	if weather == STORM_WEATHER:
		return int(floor(float(base) * STORM_CANNON_MULTIPLIER))
	return base


## Fires one volley. Returns `{ok, damage, sunk, log}` (§4.12.1). Sets
## `reload_until_round = round + 2` so the next turn cannot fire (§4.11.4).
func cannon(unit: Dictionary, target: Dictionary) -> Dictionary:
	var result := {"ok": false, "damage": 0, "sunk": false, "log": {}}
	if _over or _action_taken or not is_acting(unit) or not can_cannon(unit, target):
		return result
	_action_taken = true
	result["ok"] = true
	var damage := cannon_damage(unit, target)
	result["damage"] = damage
	unit["reload_until_round"] = _round + RELOAD_ROUNDS
	var ship: Dictionary = target["ship"]
	ship["durability"] = int(ship.get("durability", 0)) - damage
	var sunk := int(ship["durability"]) <= 0
	if sunk:
		_sink(target, str(unit.get("side", "")), "cannon")
	result["sunk"] = sunk
	result["log"] = _make_log("cannon", unit, target, {
		"damage": damage, "sunk": sunk, "range": _chebyshev(unit_cell(unit), unit_cell(target)),
	})
	_check_over()
	return result


# --- Ram (docs/60-* §4.5, §4.11.5) ----------------------------------------

## True when the ships are orthogonally adjacent (Manhattan distance 1).
func can_ram(unit, target) -> bool:
	if not (unit is Dictionary) or not (target is Dictionary):
		return false
	if not bool(unit.get("alive", false)) or not bool(target.get("alive", false)):
		return false
	if unit.side == target.side:
		return false
	return _manhattan(unit_cell(unit), unit_cell(target)) == 1


## Rams an orthogonally adjacent ship: both take damage; the attacker resolves
## last (§4.11.5, §6 "both ships sink" edge case).
func ram(unit: Dictionary, target: Dictionary) -> Dictionary:
	var result := {
		"ok": false, "damage": 0, "attacker_damage": 0,
		"sunk": false, "attacker_sunk": false, "log": {},
	}
	if _over or _action_taken or not is_acting(unit) or not can_ram(unit, target):
		return result
	_action_taken = true
	var attacker_max := effective_max_durability(unit["ship"])
	var target_damage := int(floor(float(attacker_max) * RAM_TARGET_FRACTION))
	var attacker_damage := int(floor(float(attacker_max) * RAM_ATTACKER_FRACTION))
	var ship_type: Dictionary = DataLoader.get_ship_type(str(unit["ship"].get("ship_type_id", "")))
	if str(ship_type.get("class", "")) in OAR_SHIP_CLASSES:
		target_damage = int(floor(float(target_damage) * OAR_RAM_MULTIPLIER))
	result["damage"] = target_damage
	result["attacker_damage"] = attacker_damage

	# Target first, then the attacker (§4.11.5 "attacker resolves last").
	var target_ship: Dictionary = target["ship"]
	target_ship["durability"] = int(target_ship.get("durability", 0)) - target_damage
	var target_sunk := int(target_ship["durability"]) <= 0
	if target_sunk:
		_sink(target, str(unit.get("side", "")), "ram")
	var attacker_ship: Dictionary = unit["ship"]
	attacker_ship["durability"] = int(attacker_ship.get("durability", 0)) - attacker_damage
	var attacker_sunk := int(attacker_ship["durability"]) <= 0
	if attacker_sunk:
		_sink(unit, str(target.get("side", "")), "ram")
	result["sunk"] = target_sunk
	result["attacker_sunk"] = attacker_sunk
	result["log"] = _make_log("ram", unit, target, {
		"damage": target_damage, "attacker_damage": attacker_damage,
		"sunk": target_sunk, "attacker_sunk": attacker_sunk,
	})
	_check_over()
	return result


# --- Boarding & duel (docs/60-* §4.6, §4.11.6) ----------------------------

## True for an orthogonally adjacent enemy ship (§4.6).
func can_board(unit, target) -> bool:
	return can_ram(unit, target)


## Resolves a boarding attempt through [method resolve_duel] — the single duel
## implementation (§4.12.1.2). The loser is captured: a player win removes the
## enemy ship (`captured_enemy`), a player loss removes the player's ship
## (`lost_player`, §4.11.7).
func board(unit: Dictionary, target: Dictionary) -> Dictionary:
	var result := {"ok": false, "duel": {}, "captured": {}, "lost": {}, "log": {}}
	if _over or _action_taken or not is_acting(unit) or not can_board(unit, target):
		return result
	_action_taken = true
	var enemy_unit: Dictionary = target if target.side == SIDE_ENEMY else unit
	var player_unit: Dictionary = target if target.side == SIDE_PLAYER else unit
	var defender_base := defender_duel_base(
		int(enemy_unit["ship"].get("crew", 0)),
		int(enemy_unit.get("captain_rating", CAPTAIN_RATING_BASE)))
	var duel := resolve_duel(player_duel_base(), defender_base, rng)
	result["duel"] = duel
	if str(duel.get("result", "")) == "capture":
		_capture(enemy_unit)
		result["captured"] = enemy_unit["ship"].duplicate(true)
	else:
		_capture(player_unit)
		result["lost"] = player_unit["ship"].duplicate(true)
	result["ok"] = true
	var won := str(duel.get("result", "")) == "capture"
	result["log"] = _make_log("board", unit, target, {
		"won": won, "player_wins": int(duel.get("player_wins", 0)),
		"defender_wins": int(duel.get("defender_wins", 0)),
	})
	_check_over()
	return result


## §4.12.1.2 / §4.11.6 — the **only** duel formula. `player_base` is the
## player captain's rating, `defender_base` the AI captain's. Both sides roll
## `base + rng.randi_range(0, 20)` per round (player roll first); the higher
## wins the round, equal rolls score for neither. First to 3 wins; after 5
## rounds the higher win count takes it, and equal counts are held by the
## defender (`result: "defeat"`).
static func resolve_duel(player_base: int, defender_base: int, rng: RandomNumberGenerator) -> Dictionary:
	var rounds: Array = []
	var player_wins := 0
	var defender_wins := 0
	for _index in range(DUEL_MAX_ROUNDS):
		if player_wins >= DUEL_WINS_NEEDED or defender_wins >= DUEL_WINS_NEEDED:
			break
		var player_roll := player_base + rng.randi_range(0, DUEL_ROUND_MAX_ROLL)
		var defender_roll := defender_base + rng.randi_range(0, DUEL_ROUND_MAX_ROLL)
		if player_roll > defender_roll:
			player_wins += 1
			rounds.append("win")
		elif defender_roll > player_roll:
			defender_wins += 1
			rounds.append("loss")
		else:
			rounds.append("tie")
	# §4.11.6: undecided after 5 rounds → more wins takes it; equal counts are
	# held by the defender, so the boarding attempt fails. Both cases are
	# expressed by the same comparison (a tie is a `defeat`).
	return {
		"result": "capture" if player_wins > defender_wins else "defeat",
		"rounds": rounds,
		"player_wins": player_wins,
		"defender_wins": defender_wins,
	}


## §4.11.6 defender base: `min(floor(crew / 5), 20) + captain rating`.
static func defender_duel_base(crew: int, captain_rating: int) -> int:
	return mini(int(floor(float(maxi(crew, 0)) / DUEL_CREW_DIVISOR)), DUEL_CREW_CAP) + captain_rating


## §4.11.6 player base: effective combat + worn weapon/armor `combat` deltas.
static func player_duel_base() -> int:
	var base := player_effective_combat()
	var player: Dictionary = GameState.player
	var equipment = player.get("equipment", {}) if player is Dictionary else {}
	if equipment is Dictionary:
		for slot in ["weapon", "armor"]:
			base += equipment_item_modifier(str(equipment.get(slot, "")), "combat")
	return base


## The player's effective `combat` stat (§4.11.5), 0 when no run is loaded.
static func player_effective_combat() -> int:
	var player: Dictionary = GameState.player
	if not (player is Dictionary) or player.is_empty():
		return 0
	return CharacterLib.effective_stat("combat")


# --- Hold / menu seams -----------------------------------------------------

## Spends the turn's action doing nothing (§4.9 rule 6, §4.4 "hold").
func hold(unit: Dictionary) -> Dictionary:
	var result := {"ok": false, "log": {}}
	if _over or _action_taken or not is_acting(unit):
		return result
	_action_taken = true
	result["ok"] = true
	result["log"] = _make_log("hold", unit, {}, {})
	return result


## §4.10 `battle.retreat`: ends the battle, result `retreat`.
func retreat() -> Dictionary:
	if _over:
		return outcome()
	_result = RESULT_RETREAT
	_over = true
	_log.append({"kind": "retreat", "key": "battle.log.retreat", "values": {}})
	return outcome()


## §4.11.7 player-offered surrender. Pirates take the flagship's hold (the
## fleet is retained — the application seam clears the hold); a navy with a
## bounty takes the flagship hull itself, and an empty fleet is
## `defeat_captured`. Returns the outcome block.
func offer_surrender() -> Dictionary:
	if _over:
		return outcome()
	_result = RESULT_SURRENDER
	var flagship := _flagship_unit()
	if enemy_kind == "navy" and not flagship.is_empty():
		_lost_player.append(flagship["ship"].duplicate(true))
		flagship["alive"] = false
		_player_last_cause = "captured"
		_promote_player_flagship()
		if living_units(SIDE_PLAYER).is_empty():
			_result = RESULT_DEFEAT_CAPTURED
	_over = true
	_log.append({"kind": "surrender", "key": "battle.log.surrender", "values": {}})
	return outcome()


## The structured log of every resolved action (§4.11.4 "damage order"). Each
## entry is `{kind, key, values}`: `key` is the `ui_strings.json` key the HUD
## renders (task G), `values` carries the numbers — never player-facing text.
func log_lines() -> Array:
	return _log.duplicate(true)


# --- Headless driver (§4.11.3 handoff / tests) ----------------------------

## Applies `policy(sim)` (or `policy(sim, unit)`) then [method end_turn] until
## [method is_over] or the round cap. Returns the outcome block when the battle
## finished, else `{result: "", rounds: <current>, "over": false}`.
func run_to_completion(policy: Callable, max_rounds: int = 30) -> Dictionary:
	if not _started:
		start()
	if not policy.is_valid():
		push_error("BattleSim.run_to_completion: invalid policy Callable")
		return {} if _over else {"result": RESULT_UNFINISHED, "rounds": _round, "over": false}
	var guard := 0
	var guard_limit := maxi(max_rounds, 1) * maxi(_units.size(), 1) * 2 + 10
	while not _over and _round <= max_rounds:
		guard += 1
		if guard > guard_limit:
			push_warning("BattleSim.run_to_completion: step guard tripped at round %d" % _round)
			break
		var unit := current_unit()
		if unit.is_empty():
			# No living unit at the cursor (the battle ended between calls):
			# end_turn() re-checks and advances.
			end_turn()
			continue
		_apply_decision(unit, _call_policy(policy, unit))
		if not _over:
			end_turn()
	if _over:
		return outcome()
	return {"result": RESULT_UNFINISHED, "rounds": _round, "over": false}


func _call_policy(policy: Callable, unit: Dictionary):
	var arguments := 0
	if policy.is_valid():
		arguments = policy.get_argument_count()
	if arguments <= 1:
		return policy.call(self)
	return policy.call(self, unit)


func _apply_decision(unit: Dictionary, decision) -> void:
	var action := "hold"
	var target = {}
	var cell := NO_CELL
	if decision is Dictionary:
		action = str(decision.get("action", "hold"))
		target = decision.get("target", {})
		cell = to_cell(decision.get("cell", NO_CELL))
	match action:
		"cannon":
			cannon(unit, target if target is Dictionary else {})
		"ram":
			ram(unit, target if target is Dictionary else {})
		"board":
			board(unit, target if target is Dictionary else {})
		"move":
			move_to(unit, cell)
		"surrender":
			# `surrender` is the AI's own §4.7 capitulation; a *player*-side
			# policy asking for it is the §4.11.7 menu action instead.
			if unit.side == SIDE_ENEMY:
				_ai_surrender(unit)
			else:
				offer_surrender()
		_:
			hold(unit)


## §4.7 AI surrender: resolved exactly as a duel win (capture), no duel.
func _ai_surrender(unit: Dictionary) -> void:
	if _over or _action_taken or unit.side != SIDE_ENEMY or not is_acting(unit):
		hold(unit)
		return
	_action_taken = true
	_surrendered_enemy += 1
	_captured_enemy.append(unit["ship"].duplicate(true))
	unit["alive"] = false
	_log.append(_make_log("surrender_enemy", unit, {}, {}))
	_check_over()


# --- Equipment helpers (docs/60-* §4.11.12) -------------------------------

## A `combat`/`speed`/`durability` modifier of the item worn in `slot`, 0 for
## an empty/unknown slot (§4.11.12 "missing keys read as empty slots").
static func equipment_modifier(ship: Dictionary, slot: String, stat: String) -> int:
	if not (ship is Dictionary):
		return 0
	var equipment = ship.get("equipment", {})
	if not (equipment is Dictionary):
		return 0
	return equipment_item_modifier(str(equipment.get(slot, "")), stat)


## Modifier of one equipment id, 0 when the id is empty/unknown.
static func equipment_item_modifier(equipment_id: String, stat: String) -> int:
	if equipment_id.is_empty():
		return 0
	var item: Dictionary = DataLoader.get_equipment(equipment_id)
	if item.is_empty():
		return 0
	var modifiers = item.get("modifiers", {})
	if not (modifiers is Dictionary):
		return 0
	return int(modifiers.get(stat, 0))


# --- Grid helpers ----------------------------------------------------------

static func in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < GRID_WIDTH and cell.y < GRID_HEIGHT


static func to_cell(value) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Dictionary:
		return Vector2i(int(value.get("x", -1)), int(value.get("y", -1)))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return NO_CELL


static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


# --- Turn / initiative internals (§4.11.4) --------------------------------

func _make_unit(side: String, index: int, ship: Dictionary, cell: Vector2i) -> Dictionary:
	return {
		"side": side,
		"index": index,
		"ship": ship,
		"cell": cell,
		"mp": 0,
		"reload_until_round": 1,
		"alive": true,
		"captain_rating": 0,
	}


func _deploy_cell(side: String, index: int) -> Vector2i:
	var table := PLAYER_DEPLOYMENT if side == SIDE_PLAYER else ENEMY_DEPLOYMENT
	if index < table.size():
		return table[index]
	# Beyond the pinned table (cannot happen with FLEET_MAX = 5 / navy max 4):
	# keep the "one ship per tile" invariant by scanning the band.
	var band: Array = []
	if side == SIDE_PLAYER:
		for x in PLAYER_BAND_MAX_X + 1:
			for y in GRID_HEIGHT:
				band.append(Vector2i(x, y))
	else:
		for x in range(ENEMY_BAND_MIN_X, GRID_WIDTH):
			for y in GRID_HEIGHT:
				band.append(Vector2i(x, y))
	for cell in band:
		var used := false
		for unit in _units:
			if unit_cell(unit) == cell:
				used = true
				break
		if not used:
			return cell
	return NO_CELL


## §4.6: the AI captain rating (`5 + fleet tier`) is a fixed formula, so it is
## computed once at battle start and stored on the unit (no RNG draw).
func _roll_captain_ratings() -> void:
	for unit in _units:
		if unit.side == SIDE_ENEMY:
			unit["captain_rating"] = CAPTAIN_RATING_BASE + int(FLEET_TIER.get(enemy_kind, 1))


func _build_order() -> void:
	_order = []
	for unit in _units:
		if bool(unit.get("alive", false)):
			_order.append(unit)
	_order.sort_custom(func(a, b) -> bool: return _initiative_before(a, b))


## §4.11.4: descending effective speed, player before enemy on a tie, then
## ascending fleet index.
func _initiative_before(a: Dictionary, b: Dictionary) -> bool:
	var speed_a := effective_speed(a)
	var speed_b := effective_speed(b)
	if speed_a != speed_b:
		return speed_a > speed_b
	if a.side != b.side:
		return a.side == SIDE_PLAYER
	return int(a.index) < int(b.index)


func _advance() -> void:
	var guard := 0
	while true:
		guard += 1
		if guard > GRID_WIDTH * GRID_HEIGHT * 4:
			return
		_current += 1
		if _current >= _order.size():
			_round += 1
			_build_order()
			_current = 0
			if _order.is_empty():
				_check_over()
				return
		var unit = _order[_current] if _current < _order.size() else null
		if unit is Dictionary and bool(unit.get("alive", false)):
			unit["mp"] = effective_speed(unit)
			_action_taken = false
			return


func _reachable(unit: Dictionary) -> Dictionary:
	var start := unit_cell(unit)
	var capacity := int(unit.get("mp", 0))
	var best := {start: 0}
	if capacity <= 0:
		return best
	var occupied := _occupied_cells(unit)
	var frontier: Array = [start]
	while not frontier.is_empty():
		var pick := 0
		for index in range(1, frontier.size()):
			if int(best[frontier[index]]) < int(best[frontier[pick]]):
				pick = index
		var cell: Vector2i = frontier[pick]
		frontier.remove_at(pick)
		var cost := int(best[cell])
		for direction in DIRECTIONS:
			var next: Vector2i = cell + (direction as Vector2i)
			if not in_grid(next):
				continue
			var diagonal: bool = direction.x != 0 and direction.y != 0
			if diagonal:
				# §4.11.4: both orthogonal corner tiles must be inside the grid.
				if not in_grid(cell + Vector2i(direction.x, 0)):
					continue
				if not in_grid(cell + Vector2i(0, direction.y)):
					continue
			if occupied.has(next):
				continue
			var step: int = MP_DIAGONAL if diagonal else MP_ORTHOGONAL
			var next_cost := cost + step
			if next_cost > capacity:
				continue
			if not best.has(next) or next_cost < int(best[next]):
				best[next] = next_cost
				frontier.append(next)
	return best


## Every tile occupied by a living ship other than `unit`'s own cell.
func _occupied_cells(unit: Dictionary) -> Dictionary:
	var cells := {}
	for other in _units:
		if other == unit or not bool(other.get("alive", false)):
			continue
		cells[unit_cell(other)] = true
	return cells


# --- Damage / removal internals (§4.11.5, §4.11.7) ------------------------

## Removes a sunk ship immediately; cargo is lost (§4.7).
func _sink(unit: Dictionary, by_side: String, _cause: String) -> void:
	if not bool(unit.get("alive", false)):
		return
	unit["alive"] = false
	unit["ship"]["durability"] = 0
	var ship_type_id := str(unit["ship"].get("ship_type_id", ""))
	if unit.side == SIDE_ENEMY:
		_sunk_enemy.append(ship_type_id)
		if by_side == SIDE_PLAYER:
			_sunk_enemy_by_player.append(ship_type_id)
	else:
		_sunk_player.append(ship_type_id)
		_player_last_cause = "sunk"
		_promote_player_flagship()


## Removes a captured ship (duel win/loss, AI surrender). The instance is
## reported intact; the §4.11.7 25%-durability/crew-0 transform is the
## application seam's (task C).
func _capture(unit: Dictionary) -> void:
	if not bool(unit.get("alive", false)):
		return
	unit["alive"] = false
	if unit.side == SIDE_ENEMY:
		_captured_enemy.append(unit["ship"].duplicate(true))
	else:
		_lost_player.append(unit["ship"].duplicate(true))
		_player_last_cause = "captured"
		_promote_player_flagship()


## The player flagship's fleet index (`fleet[0]`, §4.6/§4.11.7). Advanced to
## the next living ship when the flagship is captured or sunk.
func flagship_index() -> int:
	return _flagship_index


## The living player flagship unit, `{}` when the fleet is gone.
func flagship_unit() -> Dictionary:
	return _flagship_unit()


## §4.6: the next ship becomes the flagship, order preserved (`fleet[0]`).
func _promote_player_flagship() -> void:
	_flagship_index = _lowest_living_index(SIDE_PLAYER)


func _lowest_living_index(side: String) -> int:
	var best := -1
	for unit in _units:
		if unit.side != side or not bool(unit.get("alive", false)):
			continue
		if best < 0 or int(unit.index) < best:
			best = int(unit.index)
	return best


func _flagship_unit() -> Dictionary:
	for unit in _units:
		if unit.side == SIDE_PLAYER and bool(unit.get("alive", false)) \
				and int(unit.index) == _flagship_index:
			return unit
	return {}


func _check_over() -> void:
	if _over:
		return
	if living_units(SIDE_PLAYER).is_empty():
		_result = RESULT_DEFEAT_CAPTURED if _player_last_cause == "captured" else RESULT_DEFEAT_SUNK
		_over = true
		return
	if living_units(SIDE_ENEMY).is_empty():
		_result = RESULT_VICTORY
		_over = true


# --- Outcome internals (§4.11.10) -----------------------------------------

func _salvage_gold() -> int:
	var total := 0
	for ship_type_id in _sunk_enemy_by_player:
		var ship_type: Dictionary = DataLoader.get_ship_type(str(ship_type_id))
		total += int(floor(float(ship_type.get("base_price", 0)) * SALVAGE_FRACTION))
	return total


func _rep_deltas() -> Dictionary:
	var deltas := {}
	if enemy_kind == "pirate":
		# §4.11.10 "Pirates defeated (any outcome except retreat)".
		if _result != RESULT_RETREAT:
			for nation_id in _nearest_port_nations():
				deltas[nation_id] = int(deltas.get(nation_id, 0)) + PIRATE_REP_GAIN
	elif enemy_kind == "navy" and not enemy_nation.is_empty():
		# −20 per navy ship sunk or captured, regardless of who won.
		var acts := _sunk_enemy.size() + _captured_enemy.size()
		if acts > 0:
			deltas[enemy_nation] = acts * NAVY_REP_PENALTY
	return deltas


## Nations of the two nearest ports (Chebyshev from the contact tile; ties by
## port id ascending; a nation credited once).
func _nearest_port_nations() -> Array:
	var ports: Array = []
	for port in DataLoader.ports_list:
		if not (port is Dictionary):
			continue
		var position := to_cell(port.get("position", NO_CELL))
		ports.append({
			"id": str(port.get("id", "")),
			"nation_id": str(port.get("nation_id", "")),
			"distance": _chebyshev(contact, position),
		})
	ports.sort_custom(func(a, b) -> bool:
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return str(a["id"]) < str(b["id"]))
	var nations: Array = []
	for port in ports:
		if nations.size() >= NEAREST_PORT_COUNT:
			break
		var nation_id := str(port["nation_id"])
		if nation_id.is_empty() or nation_id in nations:
			continue
		nations.append(nation_id)
	return nations


func _make_log(kind: String, unit: Dictionary, target: Dictionary, values: Dictionary) -> Dictionary:
	var payload := values.duplicate(true)
	payload["side"] = str(unit.get("side", ""))
	payload["unit"] = int(unit.get("index", -1))
	if target is Dictionary and not target.is_empty():
		payload["target_side"] = str(target.get("side", ""))
		payload["target"] = int(target.get("index", -1))
	var entry := {"kind": kind, "key": "battle.log." + kind, "values": payload}
	_log.append(entry)
	return entry


static func _copy_ships(ships) -> Array:
	var out: Array = []
	if not (ships is Array):
		return out
	for ship in ships:
		if ship is Dictionary:
			out.append(ship.duplicate(true))
	return out
