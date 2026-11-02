extends Node
## FleetSim — owns the live NPC ecology sim instance
## (docs/90-ARCHITECTURE.md §5.6, added 2026-11-02).
##
## The world scene used to own the `NpcFleets` instance, so the ecology froze
## whenever that scene was gone — every port day (rest, odd jobs) skipped the
## tick entirely. This autoload moves the **lifecycle** up: the daily tick
## runs here as the post-`day_advanced` listener in every scene, port
## included (`20-*` §4.3 step 5), so the sea keeps moving while the player is
## ashore.
##
## Ownership boundaries (unchanged semantics):
##   * the fleet store is still `GameState.npc_fleets` — the §8.1 save block,
##     mutated in place by the sim. This node holds only the runtime instance
##     (accrual marks, RNG, caches), which is **never saved**.
##   * `ensure()` lazily builds the sim over the current store with
##     `last_tick_day = GameState.day` ("this day already ticked") and the
##     accrual clock synced to the load instant — no catch-up, no re-tick
##     (`60-*` §4.11.11.1). The instance re-adopts automatically whenever the
##     store object is swapped (a new game, a save load, a test fixture).
##   * **Never opens battles**: contact checks and `pending_encounter` stay
##     with the world scene; a hostile fleet drifting onto a docked player's
##     tile just holds there.
##
## Guards mirror the world scene's old ones: without a run
## (`GameState.player` empty) or under a game-over the listener is a no-op.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

## The live sim (`null` until the first `ensure()` with a run).
var _sim = null
## The `GameState.npc_fleets` array object the sim was built over — a new
## array under the same field (new game / load / fixture swap) means re-adopt.
var _store_ref = null


func _ready() -> void:
	# The tick is the §4.3 step-5 listener. Autoloads connect before any
	# scene, so this handler always runs *before* a scene's own
	# `day_advanced` presentation pass (EventBus fires in connection order).
	EventBus.day_advanced.connect(_on_day_advanced)


## The live sim, created on demand (null while there is no run).
func sim():
	return ensure()


## Creates the sim over the current fleet store when absent or stale. A fresh
## sim starts "this day already ticked" and with its accrual mark at the
## current clock — opening the map, loading a save or resting through days
## can never re-tick or back-date a fleet (§4.11.11.1).
func ensure():
	if _sim != null and is_same(_store_ref, GameState.npc_fleets):
		return _sim
	if GameState.player.is_empty():
		return null
	_sim = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config,
		"preset": GameState.npc_preset,
	})
	_sim.last_tick_day = int(GameState.day)
	_store_ref = GameState.npc_fleets
	return _sim


## Drops the runtime instance (tests, future load seams). The next `ensure()`
## re-adopts the store without catch-up.
func reset_sim() -> void:
	_sim = null
	_store_ref = null


## Test seam: inject a fixture sim (the `world_map.fleet_sim()` contract
## delegates here). Takes ownership exactly like `ensure()` would.
func replace_sim(sim_instance) -> void:
	_sim = sim_instance
	_store_ref = GameState.npc_fleets


## The world scene's per-move accrual: one call per helm move, idempotent with
## the day tick's catch-up (`60-*` §4.11.11). No-op without a live sim.
func accrue() -> void:
	if _sim == null:
		return
	_sim.advance_clock()


## Mid-run preset application (the S19 dial): forwards to the live sim; a
## later `ensure()` reads `GameState.npc_preset` anyway.
func apply_preset(preset: String) -> void:
	if _sim != null and _sim.has_method("set_preset"):
		_sim.set_preset(preset)


## The §4.3 step-5 daily tick — in every scene, port included. Runs the
## ecology's day work, then fans the NPC-trade `market_changed` events (the
## pure module never emits; the old world-scene listener owned that fan-out).
func _on_day_advanced(_new_day: int) -> void:
	if not _has_game() or SailingSimLib.is_game_over():
		return
	# The daily tick runs in every scene, port included: ensure the sim
	# HERE (not only on the world scene's per-move seam) so a session that
	# never opened the map — a fresh run or a load landing in a port —
	# still ticks the ecology at each midnight. `ensure()` starts a fresh
	# sim "this day already ticked" (§4.11.11.1), so adoption itself never
	# back-ticks or catch-up-accrues.
	var sim = ensure()
	if sim == null:
		return
	var moved: Array = sim.moved_ports
	sim.tick(int(GameState.day))
	for port_id in (sim.moved_ports as Array):
		if not (moved as Array).has(port_id):
			EventBus.market_changed.emit(str(port_id))


func _has_game() -> bool:
	return not GameState.player.is_empty()
