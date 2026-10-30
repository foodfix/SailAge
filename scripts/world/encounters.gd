class_name Encounters
extends RefCounted
## World-map hostile fleets: pirate spawns, navy hunters, marker movement and
## contact detection (docs/60-COMBAT.md §4.1, §4.8, §4.11.11.1–§4.11.11.3;
## API pinned by §4.12.3; docs/20-WORLD-AND-SAILING.md §4.7, §4.11;
## docs/90-ARCHITECTURE.md §5.4, §8.1).
##
## Pure logic, no node references and no scene access (docs/90-* §4): the whole
## module works on two pieces of `GameState` and nothing else —
##
##   * `GameState.hostile_fleets` — the §4.11.11 save block, the **only** place
##     markers live (this module mutates that array, never a copy);
##   * `GameState.proximity_cooldowns` — the §4.8 spawn immunity `{kind: day}`.
##
## Everything else it reads (`GameState.day`, `world_tile()`, `known_ports`,
## `current_port`, `player.reputation`) is read-only. Composition is **not**
## re-implemented here: every marker's `ships` comes from
## [method AiFleet.compose_enemy] (§4.11.3, the single implementation).
##
## RNG discipline (§4.11.11.2): one dedicated world stream. It is seeded from
## the §4.11.1 formula family (`day × 1000003 + x × 7919 + y × 104729`) the
## first time a roll needs it, so a run is reproducible from the state it
## started in; [method reset_rng] replaces that seed (the pinned test seam).
## Marker composition uses its **own** stream seeded from the marker's own
## identity ([method composition_seed]), so a marker's fleet can be reproduced
## from its saved fields alone — no replay of the spawn stream required.

const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")

# --- Locked numbers (docs/60-* §4.1, §4.8, §4.11.10, §4.11.11.1–.2) -------

## §4.11.11 `kind` values.
const PIRATE := "pirate"
const NAVY := "navy"
const KINDS: Array[String] = [PIRATE, NAVY]

## §4.11.11.2 step 4: "Markers never exceed 3 at once".
const MAX_MARKERS := 3
## §4.11.11.2 steps 2–3: the per-day spawn chances.
const PIRATE_SPAWN_CHANCE := 0.01
const NAVY_SPAWN_CHANCE := 0.02
## A hard ceiling on the candidate enumeration: `known_ports × 961` for pirates,
## `nation_ports × 961` for navies. The shipped worst case is 96 100 cells (all
## 100 ports known), so 10× headroom still turns any future bug (an unbounded
## loop, a runaway port list) into a logged error instead of a CI hang.
const CANDIDATE_SCAN_LIMIT := 1000000
## §4.11.11.1: a pirate spawn is within Chebyshev 15 of its anchor port,
## measured **wrap-aware on x** over the 2160-wide world grid. The Phase-2
## Atlantic strip `x ≥ 7` exclusion is retired with the strip itself
## (`60-*` §4.1: latitude weather bands replace it, no tile exclusion remains).
const ZONE_RADIUS := 15
## §4.11.11.1 / `70-*` §4.5: a navy is hostile only at or below this
## reputation (`≤ −50` holds a bounty).
const NAVY_HOSTILE_REPUTATION := -50
## §4.11.11.1: contact is measured at Chebyshev distance 1.
const CONTACT_DISTANCE := 1
## §4.8 / §4.11.10: after a battle the kind's next legal spawn day is
## `day + 3` (stored in `GameState.proximity_cooldowns`).
const SPAWN_IMMUNITY_DAYS := 3
## §4.10 / §4.11.11.1: a marker that lost a battle does not move for 1 day.
##
## Unlike `GameState.proximity_cooldowns` (a *first legal day*), a marker's
## `cooldown_until_day` is the **last day the marker may not move** (inclusive):
## a battle on day D stores `D + 1`, so the marker holds through day D+1 and
## moves again on day D+2 — exactly "does not move for 1 day". §4.11.11 does not
## pin the inclusivity, and this reading is the only one that yields an idle
## day from a `+1` offset (see the task F report).
const PURSUIT_COOLDOWN_DAYS := 1## §4.11.10 / `70-*` §4.5: attacking a navy fleet is piracy (−20 reputation).
## Charged exactly **once per navy battle, at battle start** by `world_map.gd`
## (§4.11.10 pin) — never per ship and never again at battle end, so this
## module only owns the constant.
const PIRACY_REPUTATION := -20

## §4.10 / `60-*` §4.11.9: the battle outcome that leaves the enemy in place.
const RETREAT := "retreat"

## §4.11.1 seed formula constants, reused by §4.11.11.2 ("the same formula
## family") and by [method composition_seed].
const SEED_DAY_MULT := 1000003
const SEED_X_MULT := 7919
const SEED_Y_MULT := 104729

## "No cell" sentinel for [method choose_step] / positions off the map.
const NO_CELL := Vector2i(-1, -1)

## `roll_log` keeps only the most recent entries; the aggregate [member
## roll_counts] is exact for the whole run.
const ROLL_LOG_LIMIT := 256

# --- Instance state -------------------------------------------------------

## Day of the last tick that actually ran the day's work (§4.11.11.1: one
## spawn-roll + movement pass **per day tick**, however often the scene calls
## [method tick] within that day). `-1` means "no day has ticked yet"; the
## world scene passes `GameState.day` so a scene opened mid-day does not replay
## that day (see [method _init]).
var last_tick_day: int = -1

## Seeded spawn-rate counters (the §4.11.11.2 table seam): `kind → {rolls, hits}`.
## `rolls` counts only rolls that were actually made — a day skipped by the
## spawn immunity is not a roll — and `hits` counts `rng.randf() < chance`.
var roll_counts: Dictionary = {}
## Per-nation navy counters, `nation_id → {rolls, hits}`, so the "2% per
## bountied nation" pin can be measured nation by nation.
var roll_counts_by_nation: Dictionary = {}
## Recent rolls for debugging, newest last (capped at [constant ROLL_LOG_LIMIT]).
var roll_log: Array = []
## Set true to keep a log entry for every roll (default off: 20k-day rate runs
## would otherwise pay for 40k dictionaries they never read).
var log_rolls: bool = false

var _rng := RandomNumberGenerator.new()
var _rng_seeded: bool = false
## `cache_key → [[Vector2i cell, String anchor_port_id], …]` (§4.11.11.1 zone).
var _candidates_cache: Dictionary = {}
var _cache_map_id: int = 0


## `start_day` is the day that has already had its tick (the world scene passes
## `GameState.day` at `_ready`); `-1` (the default, used by tests) makes the
## first [method tick] run a full day.
func _init(start_day: int = -1) -> void:
	last_tick_day = start_day
	_reset_counters()


# --- Public API (docs/60-* §4.12.3) ---------------------------------------

## One day tick for the world map, in the §4.11.11.2 / §4.11.11.1 order:
## spawn rolls (at sea only) → every marker steps 1 tile toward its anchor →
## markers that reached their port are removed → `cooldown_until_day` is
## applied/cleared. Returns the hostile markers now in contact with the fleet
## (Chebyshev 1, player tile from `GameState.world_tile()`), nearest first.
##
## The day's work runs **once per `GameState.day`**: a second call in the same
## day only re-checks contact (§4.11.11.1 "measured after both the player move
## and the marker step"). Not at sea, the day is still consumed — a harbour day
## never herds markers (they only move "each day tick **at sea**").
func tick(is_at_sea: bool) -> Array:
	_ensure_rng()
	var day := GameState.day
	if day != last_tick_day:
		last_tick_day = day
		if is_at_sea:
			_roll_spawns(day)
			_move_markers(day)
			_remove_arrived()
	_clear_expired_cooldowns(day)
	if not is_at_sea:
		return []
	return contacts(GameState.world_tile())


## Live marker list (the §4.11.11 save block itself, shallow-copied: the dicts
## are the stored ones, so a fixture may adjust a marker in place).
func markers() -> Array:
	return GameState.hostile_fleets.duplicate()


## Every hostile marker within Chebyshev 1 of `cell`, nearest first (ties by id
## ascending). `{}` when none — the §4.11.11.1 contact rule.
func nearest_contact(cell: Vector2i) -> Dictionary:
	var found: Array = contacts(cell)
	return found[0] if not found.is_empty() else {}


## Every hostile marker within Chebyshev 1 of `cell`, nearest first.
##
## A marker on its §4.10 pursuit cooldown is **disengaged**: contact is not
## raised until the cooldown day has passed. That is the only reading under
## which "the enemy marker gets +1 day pursuit cooldown" does anything — the
## fleet is left standing on the contact tile (§4.11.10) right next to the
## marker, so without this a retreat would re-open the same battle on the next
## tick (and forever, since S10 returns to a freshly opened S3).
func contacts(cell: Vector2i) -> Array:
	var day := GameState.day
	var out: Array = []
	for marker in GameState.hostile_fleets:
		if not (marker is Dictionary) or not is_hostile(marker):
			continue
		if int(marker.get("cooldown_until_day", 0)) >= day:
			continue
		var distance := _chebyshev(cell, position_of(marker))
		if distance > CONTACT_DISTANCE:
			continue
		out.append(marker)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := _chebyshev(cell, position_of(a))
		var db := _chebyshev(cell, position_of(b))
		if da != db:
			return da < db
		return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## Removes marker `id` from `GameState.hostile_fleets`. True when one was there.
func remove(id: String) -> bool:
	for index in range(GameState.hostile_fleets.size() - 1, -1, -1):
		var marker = GameState.hostile_fleets[index]
		if marker is Dictionary and str(marker.get("id", "")) == id:
			GameState.hostile_fleets.remove_at(index)
			return true
	return false


## §4.8 / §4.11.11.1 spawn immunity: `proximity_cooldowns[kind] = until_day`.
func set_cooldown(kind: String, until_day: int) -> void:
	if kind.is_empty():
		return
	GameState.proximity_cooldowns[kind] = int(until_day)


## §4.10 pursuit cooldown on a **stored** marker (`cooldown_until_day`, the last
## day it may not move). Returns false when no marker has that id.
##
## This exists because the encounter descriptor handed to S10 is a *copy* of the
## marker (the save block must not be mutated by whoever reads the encounter):
## writing a cooldown on the copy would silently do nothing, so the update goes
## through the stored dict found by id.
func set_pursuit_cooldown(id: String, until_day: int) -> bool:
	var index := _find(id)
	if index < 0:
		return false
	(GameState.hostile_fleets[index] as Dictionary)["cooldown_until_day"] = int(until_day)
	return true


## The kind's first legal spawn day (`0` when it never fought).
func cooldown_until(kind: String) -> int:
	return int(GameState.proximity_cooldowns.get(kind, 0))


## Spawns one marker of `kind` (docs/60-* §4.11.11.2) and returns it, or `{}`
## when the §4.11.11.1 zone has no candidate, the drawn tile is occupied, the
## 3-marker cap is reached, or the spawn would duplicate an id.
##
## The tile is drawn uniformly from the kind's candidate list and then
## **rejected if occupied** (§4.11.11.2 step 2 "uniform over candidates,
## rejected if occupied"), so a full sea spends the roll instead of stacking
## markers. `nation_id` is required for navies and ignored for pirates.
func spawn(kind: String, nation_id: String, day: int) -> Dictionary:
	if not (kind in KINDS):
		return {}
	if GameState.hostile_fleets.size() >= MAX_MARKERS:
		return {}
	if kind == NAVY and nation_id.is_empty():
		return {}
	_ensure_rng()
	var candidates := _candidates(kind, nation_id)
	if candidates.is_empty():
		return {}
	# "Uniform over candidates, rejected if occupied": one draw per call, so a
	# crowded sea spends the roll instead of stacking markers on one tile.
	var pick: Array = candidates[_rng.randi_range(0, candidates.size() - 1)]
	var cell: Vector2i = pick[0]
	var anchor_id := str(pick[1])
	if _is_occupied(cell):
		return {}
	var id := marker_id(day, cell, kind)
	if _find(id) != -1:
		return {}
	var marker := {
		"id": id,
		"kind": kind,
		"nation_id": nation_id if kind == NAVY else "",
		"position": {"x": cell.x, "y": cell.y},
		"anchor_port_id": anchor_id,
		"ships": compose_ships(kind, day, cell),
		"spawn_day": int(day),
		"cooldown_until_day": 0,
	}
	GameState.hostile_fleets.append(marker)
	return marker


## Reseeds the world spawn stream (the pinned test seam, §4.12.3). Also clears
## the counters, the roll log and the "this day already ticked" mark, so a
## suite can replay the exact same sequence from scratch.
func reset_rng(seed_value: int) -> void:
	_rng.seed = seed_value
	_rng_seeded = true
	last_tick_day = -1
	_reset_counters()


## §4.11.11 `hf_<day>_<x>_<y>_<kind>` — deterministic and unique per spawn day.
static func marker_id(day: int, cell: Vector2i, kind: String) -> String:
	return "hf_%d_%d_%d_%s" % [int(day), cell.x, cell.y, kind]


## §4.11.1/§4.11.11.2 seed formula, used unchanged for a marker's own
## composition stream so `AiFleet.compose_enemy(kind, spawn_day, rng)` with
## `rng.seed = composition_seed(...)` reproduces the saved ships exactly.
static func composition_seed(day: int, cell: Vector2i) -> int:
	return int(day) * SEED_DAY_MULT + cell.x * SEED_X_MULT + cell.y * SEED_Y_MULT


## §4.11.3 composition for a marker spawned on `day` at `cell` — a thin call
## into the single implementation, never a copy.
static func compose_ships(kind: String, day: int, cell: Vector2i) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = composition_seed(day, cell)
	return AiFleetLib.compose_enemy(kind, day, rng)


## §4.11.11.1 hostility: pirates always, navies only while the player's
## reputation with that nation is ≤ −50 (`70-*` §4.5).
static func is_hostile(marker: Dictionary) -> bool:
	var kind := str(marker.get("kind", ""))
	if kind == PIRATE:
		return true
	if kind != NAVY:
		return false
	return CharacterLib.reputation(str(marker.get("nation_id", ""))) \
		<= NAVY_HOSTILE_REPUTATION


## Marker cell from the `{"x","y"}` save shape (tolerates a Vector2i/Vector2).
static func position_of(marker: Dictionary) -> Vector2i:
	var pos = marker.get("position", null)
	if pos is Vector2i:
		return pos
	if pos is Vector2:
		return Vector2i(pos)
	if pos is Dictionary:
		return Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0)))
	return NO_CELL


## Writes the marker cell back in the §4.11.11 `{"x","y"}` save shape.
static func set_position(marker: Dictionary, cell: Vector2i) -> void:
	marker["position"] = {"x": cell.x, "y": cell.y}


## §4.11.8 rule 5 tie-breaks over an already-legal candidate list: keep only
## cells that strictly reduce the Chebyshev distance to `anchor`, prefer the
## smallest `max(|dx|,|dy|)`, then the smallest `|dx|+|dy|`, then the lowest
## `(y, x)` cell. Returns [constant NO_CELL] when no candidate improves (the
## caller then holds, exactly like the AI pin).
##
## Pure so the three tie-break levels are unit-testable without a map; the
## world path ([method _best_step]) only supplies the passability filter.
static func choose_step(from: Vector2i, anchor: Vector2i, candidates: Array) -> Vector2i:
	var current := _step_distance(from, anchor)
	var best := NO_CELL
	var best_distance := current
	var best_manhattan := 0
	for cell_value in candidates:
		var cell: Vector2i = cell_value
		var distance := _step_distance(cell, anchor)
		if distance >= current:
			continue
		var manhattan := _step_manhattan(cell, anchor)
		if best == NO_CELL or distance < best_distance \
				or (distance == best_distance and manhattan < best_manhattan) \
				or (distance == best_distance and manhattan == best_manhattan
					and _cell_before(cell, best)):
			best = cell
			best_distance = distance
			best_manhattan = manhattan
	return best


## Marker colour (docs/60-* §4.1): a red square for pirates, the nation colour
## for navies (placeholder art only, `80-*` §4.8).
static func marker_color(kind: String, nation_id: String) -> Color:
	if kind != NAVY:
		return PaletteLib.BAD
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	var hex := str(nation.get("color", ""))
	if not Color.html_is_valid(hex):
		return PaletteLib.PANEL_LINE
	return PaletteLib.nation_color(hex)


# --- Spawn rolls (docs/60-* §4.11.11.2) ------------------------------------

## Steps 1–4 of §4.11.11.2 in the pinned order.
func _roll_spawns(day: int) -> void:
	# 1. Spawn immunity skips the roll entirely (not a "spent" roll).
	if day >= cooldown_until(PIRATE):
		var roll := _rng.randf()
		var hit := roll < PIRATE_SPAWN_CHANCE
		var spawned := false
		if hit:
			# 4. The cap is applied inside spawn(); the roll is spent either way.
			spawned = not spawn(PIRATE, "", day).is_empty()
		_count(PIRATE, "", hit, roll, PIRATE_SPAWN_CHANCE, spawned, day)
	# 3. One 2% roll per nation holding a bounty, in nation-id order so the
	#    stream is stable regardless of dictionary order.
	if day >= cooldown_until(NAVY):
		for nation_id in bountied_nations():
			var navy_roll := _rng.randf()
			var navy_hit := navy_roll < NAVY_SPAWN_CHANCE
			var navy_spawned := false
			if navy_hit:
				navy_spawned = not spawn(NAVY, nation_id, day).is_empty()
			_count(NAVY, nation_id, navy_hit, navy_roll, NAVY_SPAWN_CHANCE,
				navy_spawned, day)


## Nations the player holds a bounty against, `70-*` §4.5: `reputation ≤ −50`.
## Sorted by id for a stable RNG stream.
func bountied_nations() -> Array[String]:
	var out: Array[String] = []
	var reputation: Dictionary = GameState.player.get("reputation", {})
	for nation_id in reputation:
		if int(reputation[nation_id]) <= NAVY_HOSTILE_REPUTATION:
			out.append(str(nation_id))
	out.sort()
	return out


func _count(kind: String, nation_id: String, hit: bool, roll: float,
		chance: float, spawned: bool, day: int) -> void:
	var bucket: Dictionary = roll_counts.get(kind, {"rolls": 0, "hits": 0})
	bucket["rolls"] = int(bucket.get("rolls", 0)) + 1
	if hit:
		bucket["hits"] = int(bucket.get("hits", 0)) + 1
	roll_counts[kind] = bucket
	if kind == NAVY and not nation_id.is_empty():
		var nation_bucket: Dictionary = roll_counts_by_nation.get(
			nation_id, {"rolls": 0, "hits": 0}
		)
		nation_bucket["rolls"] = int(nation_bucket.get("rolls", 0)) + 1
		if hit:
			nation_bucket["hits"] = int(nation_bucket.get("hits", 0)) + 1
		roll_counts_by_nation[nation_id] = nation_bucket
	if log_rolls:
		roll_log.append({
			"day": day, "kind": kind, "nation_id": nation_id,
			"roll": roll, "chance": chance, "hit": hit, "spawned": spawned,
		})
		if roll_log.size() > ROLL_LOG_LIMIT:
			roll_log.pop_front()


func _reset_counters() -> void:
	roll_counts = {PIRATE: {"rolls": 0, "hits": 0}, NAVY: {"rolls": 0, "hits": 0}}
	roll_counts_by_nation = {}
	roll_log = []


## Lazily seeds the world stream from the §4.11.11.2 formula family so a run is
## reproducible from the state it started in.
func _ensure_rng() -> void:
	if _rng_seeded:
		return
	var tile := GameState.world_tile()
	_rng.seed = GameState.day * SEED_DAY_MULT + tile.x * SEED_X_MULT \
		+ tile.y * SEED_Y_MULT
	_rng_seeded = true


# --- Candidate zones (docs/60-* §4.11.11.1) --------------------------------

## All legal spawn tiles for `kind` as `[[cell, anchor_port_id], …]`, in map
## order so a seeded draw is stable.
##
## * Pirate: passable, in bounds, and the **nearest known port** is within
##   Chebyshev 15 (wrap-aware on x) — that port becomes the anchor
##   (§4.11.11.1). No `x ≥ 7` strip rule exists any more (`60-*` §4.1).
## * Navy: within Chebyshev 15 of one of that **nation's own** ports
##   (§4.11.11.2 step 3 "inside its own ports' 15-tile zone"); the anchor is the
##   nearest own-nation port (ties by port id), because a patrol belongs to its
##   own navy — §4.11.11.1's "nearest known port" wording is written for
##   pirates. No `x ≥ 7` strip rule is applied (the strip is retired).
func _candidates(kind: String, nation_id: String) -> Array:
	var map = _map()
	if map == null:
		return []
	var key := _cache_key(kind, nation_id)
	var cached = _candidates_cache.get(key, null)
	if cached is Array:
		return cached
	var scanned := 0
	var out: Array = []
	if kind == PIRATE:
		out = _pirate_candidates(map)
	else:
		for port_id in _nation_ports(nation_id):
			var anchor_cell: Vector2i = map.port_cell(port_id)
			if anchor_cell.x < 0:
				continue
			for dy in range(-ZONE_RADIUS, ZONE_RADIUS + 1):
				for dx in range(-ZONE_RADIUS, ZONE_RADIUS + 1):
					scanned += 1
					if scanned > CANDIDATE_SCAN_LIMIT:
						push_error(
							"Encounters: navy candidate scan exceeded %d cells"
							% CANDIDATE_SCAN_LIMIT
						)
						return out
					# x wraps (§4.1): a zone at the seam continues on the far side.
					var cell := Vector2i(
						posmod(anchor_cell.x + dx, map.width), anchor_cell.y + dy
					)
					if cell.y < 0 or cell.y >= map.height:
						continue
					if not map.is_passable(cell):
						continue
					# Nearest own-nation port wins; ties by port id ascending.
					var best := _nearest_own_port(cell, nation_id)
					if best != port_id:
						continue
					var entry := [cell, port_id]
					if not out.has(entry):
						out.append(entry)
		out.sort_custom(func(a: Array, b: Array) -> bool:
			var ca: Vector2i = a[0]
			var cb: Vector2i = b[0]
			if ca.y != cb.y:
				return ca.y < cb.y
			return ca.x < cb.x)
	_candidates_cache[key] = out
	return out


## Every legal pirate spawn tile, enumerated **around the known ports** instead
## of scanning the 2.33 M-tile world (docs/60-* §4.11.11.1).
##
## A candidate must be within Chebyshev `ZONE_RADIUS` of its anchor port, so the
## search space is `known_ports × (2·15+1)²` (~961 cells per port) rather than
## the whole grid: < 100 k passability lookups even with every port known.
## Semantics are unchanged — passable, on the grid, within 15 (wrap-aware on x)
## of the **nearest** known port (ties by port id ascending) — and the result is
## sorted into map order `(y, x)`, so a seeded draw picks exactly the tile it
## picked before. `x` wraps (§4.1); there is no Atlantic-strip exclusion any
## more (`60-*` §4.1: the strip is retired with the weather strip).
func _pirate_candidates(map) -> Array:
	var known: Array = []
	for raw_id in GameState.known_ports:
		var port_id := str(raw_id)
		var anchor_cell: Vector2i = map.port_cell(port_id)
		if anchor_cell.x >= 0:
			known.append([port_id, anchor_cell])
	if known.is_empty():
		return []
	known.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]) < str(b[0]))
	var width: int = int(map.width)
	var height: int = int(map.height)
	# One pass over `known_ports × 961` cells: remember the **best** anchor per
	# tile (`(distance, port_id)` ascending — the §4.11.11.1 "nearest, ties by
	# id" rule) instead of re-scanning the port list per candidate. The union of
	# the zones is exactly the candidate set, because a tile whose nearest port
	# is `P` always lies inside `P`'s ±15 zone.
	var best: Dictionary = {}
	var scanned := 0
	for entry in known:
		var anchor_id := str(entry[0])
		var anchor_cell: Vector2i = entry[1]
		for dy in range(-ZONE_RADIUS, ZONE_RADIUS + 1):
			var y: int = anchor_cell.y + dy
			if y < 0 or y >= height:
				continue
			for dx in range(-ZONE_RADIUS, ZONE_RADIUS + 1):
				scanned += 1
				if scanned > CANDIDATE_SCAN_LIMIT:
					# Defensive: a guard, never a code path. Log and stop rather
					# than spin — a test or CI must never hang on a map bug.
					push_error(
						"Encounters: pirate candidate scan exceeded %d cells"
						% CANDIDATE_SCAN_LIMIT
					)
					return []
				# x wraps (§4.1): a zone at the seam continues on the far side.
				var x: int = posmod(anchor_cell.x + dx, width)
				var key: int = y * width + x
				var wrapped_dx: int = absi(dx) % width
				var distance: int = maxi(
					mini(wrapped_dx, width - wrapped_dx), absi(dy)
				)
				var previous = best.get(key, null)
				if previous is Array:
					var previous_distance: int = previous[0]
					var previous_id: String = previous[1]
					if distance > previous_distance:
						continue
					if distance == previous_distance and anchor_id > previous_id:
						continue
				best[key] = [distance, anchor_id]
	var out: Array = []
	for key in best:
		var y: int = int(key) / width
		var x: int = int(key) % width
		if not map.is_passable_xy(x, y):
			continue
		out.append([Vector2i(x, y), str((best[key] as Array)[1])])
	out.sort_custom(func(a: Array, b: Array) -> bool:
		var ca: Vector2i = a[0]
		var cb: Vector2i = b[0]
		if ca.y != cb.y:
			return ca.y < cb.y
		return ca.x < cb.x)
	return out


## Port ids of `nation_id` that actually have a harbour tile on this map.
func _nation_ports(nation_id: String) -> Array[String]:
	var out: Array[String] = []
	var map = _map()
	if map == null:
		return out
	var ids: Array = DataLoader.ports.keys()
	ids.sort()
	for port_id in ids:
		var port: Dictionary = DataLoader.get_port(str(port_id))
		if str(port.get("nation_id", "")) != nation_id:
			continue
		var cell: Vector2i = map.port_cell(str(port_id))
		if cell.x < 0:
			continue
		out.append(str(port_id))
	return out


## Nearest **known** port to `cell` (Chebyshev, ties by port id), "" when the
## player knows no port on this map (§4.11.11.1).
##
## `map.port_cell()` is O(1) (the loader memoises the §6.1 harbor snap), so this
## is a handful of dictionary lookups per call, not a scan — which is what keeps
## the port-centric candidate enumeration above cheap.
func _nearest_known_port(cell: Vector2i) -> String:
	var map = _map()
	if map == null:
		return ""
	var best := ""
	var best_distance := 0
	for raw_id in GameState.known_ports:
		var port_id := str(raw_id)
		var port_cell: Vector2i = map.port_cell(port_id)
		if port_cell.x < 0:
			continue
		var distance := _chebyshev(cell, port_cell)
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and port_id < best):
			best = port_id
			best_distance = distance
	return best


## Nearest port of `nation_id` to `cell` (Chebyshev, ties by port id).
func _nearest_own_port(cell: Vector2i, nation_id: String) -> String:
	var map = _map()
	if map == null:
		return ""
	var best := ""
	var best_distance := 0
	for port_id in _nation_ports(nation_id):
		var port_cell: Vector2i = map.port_cell(port_id)
		var distance := _chebyshev(cell, port_cell)
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and port_id < best):
			best = port_id
			best_distance = distance
	return best


## The candidate cache survives for as long as the map instance and the
## player's known-port set do (both are read on every rebuild).
func _cache_key(kind: String, nation_id: String) -> String:
	var map = _map()
	var map_id: int = map.get_instance_id() if map != null else 0
	if map_id != _cache_map_id:
		_candidates_cache.clear()
		_cache_map_id = map_id
	var suffix := ""
	if kind == PIRATE:
		var known: Array = GameState.known_ports.duplicate()
		known.sort()
		suffix = "|".join(known)
	return "%s|%s|%s" % [kind, nation_id, suffix]


# --- Movement & removal (docs/60-* §4.11.11.1) -----------------------------

## Every marker steps 1 tile toward its anchor port, skipping land/reef and
## occupied tiles, holding when no step improves the distance (§4.11.8 rule 5).
## A marker still on its §4.10 pursuit cooldown does not move.
func _move_markers(day: int) -> void:
	for marker in GameState.hostile_fleets:
		if not (marker is Dictionary):
			continue
		# Inclusive: a battle on day D stores D+1, so D+1 is still idle.
		if int(marker.get("cooldown_until_day", 0)) >= day:
			continue
		var origin := position_of(marker)
		var anchor_id := str(marker.get("anchor_port_id", ""))
		var anchor_cell: Vector2i = _port_cell(anchor_id)
		if anchor_cell.x < 0 or origin == NO_CELL:
			continue
		var step := _best_step(origin, anchor_cell, marker)
		if step != NO_CELL and step != origin:
			set_position(marker, step)


## Legal neighbours of `origin` → [method choose_step].
func _best_step(origin: Vector2i, anchor: Vector2i, marker: Dictionary) -> Vector2i:
	var map = _map()
	if map == null:
		return NO_CELL
	var candidates: Array = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			# x wraps (§4.1): a marker at x = 2159 may step east to x = 0.
			var cell := Vector2i(posmod(origin.x + dx, map.width), origin.y + dy)
			if not map.is_passable(cell):
				continue
			if _is_occupied(cell, marker):
				continue
			candidates.append(cell)
	return choose_step(origin, anchor, candidates)


## A marker that reaches its anchor port's cell is removed (§4.11.11.1).
func _remove_arrived() -> void:
	for index in range(GameState.hostile_fleets.size() - 1, -1, -1):
		var marker = GameState.hostile_fleets[index]
		if not (marker is Dictionary):
			continue
		var anchor_cell := _port_cell(str(marker.get("anchor_port_id", "")))
		if anchor_cell.x < 0:
			continue
		if position_of(marker) == anchor_cell:
			GameState.hostile_fleets.remove_at(index)


## §4.11.11.1 "applies/clears `cooldown_until_day`": once the idle day has
## passed (`cooldown_until_day < day`) the field is cleared so the stored block
## reads 0 again. On the idle day itself (`== day`) it is kept.
func _clear_expired_cooldowns(day: int) -> void:
	for marker in GameState.hostile_fleets:
		if not (marker is Dictionary):
			continue
		var until := int(marker.get("cooldown_until_day", 0))
		if until != 0 and until < day:
			marker["cooldown_until_day"] = 0


## True when `cell` holds another marker or the fleet (§4.11.11.1 "skipping
## occupied and occupied-by-fleet tiles"). `ignore` skips that marker's own
## current cell.
func _is_occupied(cell: Vector2i, ignore: Dictionary = {}) -> bool:
	if cell == GameState.world_tile():
		return true
	for marker in GameState.hostile_fleets:
		if not (marker is Dictionary):
			continue
		if not ignore.is_empty() and marker == ignore:
			continue
		if position_of(marker) == cell:
			return true
	return false


# --- Small helpers ---------------------------------------------------------

func _find(id: String) -> int:
	for index in GameState.hostile_fleets.size():
		var marker = GameState.hostile_fleets[index]
		if marker is Dictionary and str(marker.get("id", "")) == id:
			return index
	return -1


func _port_cell(port_id: String) -> Vector2i:
	var map = _map()
	if map == null or port_id.is_empty():
		return NO_CELL
	return map.port_cell(port_id)


func _map():
	# The world scene hands its MapLoader over (docs/90-* §9); a headless tool
	# may install a synthetic one. No map → no spawns and no movement.
	return DataLoader.map


## Chebyshev distance with longitude wrap (`20-*` §4.1): `min(|dx|, width −
## |dx|)`. The width comes from the loaded legend (2160), so zones, contact and
## anchor distances all agree with the validator.
static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	var grid: Dictionary = DataLoader.map_legend.get("grid", {})
	var width := int(grid.get("width", 0))
	if width <= 0:
		width = 2160
	var dx := absi(a.x - b.x) % width
	return maxi(mini(dx, width - dx), absi(a.y - b.y))


static func _cell_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


## Chebyshev distance used by [method choose_step]'s tie-breaks: the
## wrap-aware [method _chebyshev] so a step across the seam is chosen when it
## really is the short way round.
static func _step_distance(a: Vector2i, b: Vector2i) -> int:
	return _chebyshev(a, b)


## `|dx| + |dy|` with the same wrapped dx [method _step_distance] makes short.
static func _step_manhattan(a: Vector2i, b: Vector2i) -> int:
	var grid: Dictionary = DataLoader.map_legend.get("grid", {})
	var width := int(grid.get("width", 0))
	if width <= 0:
		width = 2160
	var dx := absi(a.x - b.x) % width
	return mini(dx, width - dx) + absi(a.y - b.y)
