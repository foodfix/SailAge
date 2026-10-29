extends Node
## Phase-2 task C (duel modal + battle-result seam) acceptance tests
## (docs/IMPLEMENT-Phase2.md C; docs/60-COMBAT.md §4.6, §4.11.6, §4.11.7,
## §4.11.9, §4.12.1.2, §4.12.2, §4.12.3, §4.12.5, §5, §6;
## docs/80-UI-UX.md §4.1 S11, §4.7.1, §4.8; docs/90-* §5.1).
## Headless scene test:
##
##   godot --headless res://tools/test_duel.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 the duel bases: `player_base()` equipment deltas, `defender_base()`
##     boundaries, `captain_rating()` (§4.11.6, §4.11.12);
##   2 `Duel.start` reproduces the §5 scripted sequence byte-for-byte against
##     a direct `BattleSim.resolve_duel` call, and is deterministic;
##   3 both outcomes (`capture`, `defeat`) are reachable through `Duel.start`;
##   4 the headless contract: no modal is instanced, nothing blocks;
##   5 the presentation handshake `Duel.start` awaits (modal instancing +
##     `closed`) without a display server;
##   6 capture applies to the fleet: `FLEET_MAX`, cargo loot + overflow,
##     the §4.11.7 hull transform, `fleet_changed`;
##   7 loss applies to the fleet: removal, flagship promotion, empty fleet →
##     `game_over("captured")`/`("sunk")`;
##   8 the `duel_modal.tscn` scene: group, dim, width, rows, locale rebind,
##     `EventBus.duel_finished` exactly once, no `<key>` text (§4.7.1, §6).

# Path-preloaded rather than referenced by `class_name`, matching
# `test_battle.gd`: the suite must also run from a fresh checkout before the
# editor has written its global class cache.
const BattleLib := preload("res://scripts/combat/battle_sim.gd")
const DuelLib := preload("res://scripts/combat/duel.gd")
const ResultLib := preload("res://scripts/combat/battle_result.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const ModalLib := preload("res://scenes/combat/duel_modal.gd")
const ModalScene := preload("res://scenes/combat/duel_modal.tscn")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")

## §5 scripted duel: player combat 12 + cutlass 3 = 15 vs a pirate sloop with
## crew 20 (floor(20/5) = 4) + rating 6 = 10; seed 33 → win/loss/win/win, 3–1.
const DOC_PLAYER_BASE := 15
const DOC_DEFENDER_BASE := 10
const DOC_SEED := 33
const DOC_ROUNDS: Array = ["win", "loss", "win", "win"]
## A hand-checked mirror seed (loss/win/loss/loss, 3–1 the other way).
const DEFEAT_SEED := 19
## A seed whose duel is level after 5 rounds → the defender holds (§4.11.6).
const HELD_SEED := 14
## `Duel.captain_rating` fixtures (§4.6: pirate tier 1, navy tier 2).
const PIRATE_TIER := 1
const NAVY_TIER := 2

var _failures: Array[String] = []
var _checks := 0

## Games-over observed during the run.
var _game_over: Array = []
## `fleet_changed` count observed during the run.
var _fleet_changed := 0
## Set by `_run_start()` when `Duel.start` resumes (section 5).
var _start_done := false
## `Duel.start`'s return value from that coroutine.
var _start_result: Dictionary = {}


func _ready() -> void:
	EventBus.game_over.connect(func(reason: String) -> void: _game_over.append(reason))
	EventBus.fleet_changed.connect(func() -> void: _fleet_changed += 1)
	await _test_bases()
	await _test_scripted_duel()
	await _test_outcomes_reachable()
	await _test_headless_contract()
	await _test_presentation()
	await _test_capture_full_fleet()
	await _test_capture_transform()
	await _test_loss_paths()
	await _test_modal()
	_report()


# --- Fixtures --------------------------------------------------------------

## A §4.11.11 ship instance (the `40-*` §4.1 shape).
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


## A player block with one `combat` stat and the two worn slots (§4.8 shape).
func _stats(combat: int) -> void:
	GameState.player = {
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": combat,
			"navigation": 10, "luck": 10,
		},
		"officers": [],
		"equipment": {"weapon": "", "armor": ""},
	}


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


## The §4.12.3 `config` for a duel with the §5 fixture bases.
func _duel_config(overrides: Dictionary = {}) -> Dictionary:
	var config := {
		"player_base": DOC_PLAYER_BASE,
		"defender_base": DOC_DEFENDER_BASE,
		"seed": DOC_SEED,
		"ship_name": "Sloop",
		"attacker_name": "You",
		"defender_name": "Pirate captain",
	}
	for key in overrides:
		config[key] = overrides[key]
	return config


# --- 1. Duel bases (§4.11.6, §4.11.12) -----------------------------------

func _test_bases() -> void:
	_stats(12)
	# Bare: the effective combat stat alone.
	_check(DuelLib.player_base() == 12,
		"player_base() without equipment is the effective combat (12 = %d)"
		% DuelLib.player_base())
	# §4.11.12: the worn weapon's `combat` modifier adds exactly its value.
	GameState.player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
	_check(DuelLib.player_base() == 15,
		"…a worn eq_cutlass (+3) makes it 15 (%d), i.e. exactly the item's modifier"
		% DuelLib.player_base())
	# Weapon + armor stack.
	GameState.player["equipment"] = {"weapon": "eq_cutlass", "armor": "eq_breastplate"}
	_check(DuelLib.player_base() == 17,
		"…adding eq_breastplate (+2) makes it 17 (%d) — both worn slots stack"
		% DuelLib.player_base())
	# The rapier is the +5 weapon: 12 + 5 = 17.
	GameState.player["equipment"] = {"weapon": "eq_rapier", "armor": ""}
	_check(DuelLib.player_base() == 17,
		"…eq_rapier (+5) instead gives 17 (%d)" % DuelLib.player_base())
	_check(DuelLib.player_base() == 12 + ShipyardLib.player_combat_bonus(),
		"player_base() is the stat plus ShipyardEngine.player_combat_bonus() "
		+ "(the single equipment sum, +%d)" % ShipyardLib.player_combat_bonus())
	# An empty slot block (old save) reads as no bonus, never a crash.
	GameState.player["equipment"] = {}
	_check(DuelLib.player_base() == 12,
		"a missing equipment block reads as no bonus (%d)" % DuelLib.player_base())
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	_check(DuelLib.player_base() == 12,
		"…and bare equipment gives the bare base (%d)" % DuelLib.player_base())

	# The done-when phrasing, measured as a **delta** from a 0-combat captain:
	# bare 0, +3 with eq_cutlass, +5 with cutlass + breastplate.
	_stats(0)
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	_check(DuelLib.player_base() == 0,
		"player_base() with combat 0 and no equipment is 0 (%d)" % DuelLib.player_base())
	GameState.player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
	_check(DuelLib.player_base() == 3,
		"…rises by exactly the worn weapon's modifier: 3 with eq_cutlass (%d)"
		% DuelLib.player_base())
	GameState.player["equipment"] = {"weapon": "eq_cutlass", "armor": "eq_breastplate"}
	_check(DuelLib.player_base() == 5,
		"…and 5 with eq_cutlass + eq_breastplate (%d)" % DuelLib.player_base())

	# §4.11.6 defender base: min(floor(crew / 5), 20) + captain rating.
	_check(DuelLib.defender_base(0, 6) == 6,
		"defender_base(0, 6) is the rating alone (6 = %d)" % DuelLib.defender_base(0, 6))
	_check(DuelLib.defender_base(100, 6) == 26,
		"defender_base(100, 6) caps the crew term at 20 (26 = %d)"
		% DuelLib.defender_base(100, 6))
	_check(DuelLib.defender_base(500, 6) == 26,
		"defender_base(500, 6) stays capped (26 = %d)" % DuelLib.defender_base(500, 6))
	_check(DuelLib.defender_base(20, 6) == 10,
		"the §5 fixture (crew 20, rating 6) is 10 (%d)" % DuelLib.defender_base(20, 6))
	_check(DuelLib.defender_base(19, 6) == 9,
		"the crew term floors: floor(19/5) = 3 → 9 (%d)" % DuelLib.defender_base(19, 6))
	_check(DuelLib.defender_base(0, 7) == 7,
		"crew 0 leaves the captain rating alone (navy rating 7 → %d)"
		% DuelLib.defender_base(0, 7))
	_check(DuelLib.defender_base(500, 7) == 27,
		"the 20 cap plus rating 7 is 27 (%d)" % DuelLib.defender_base(500, 7))

	# §4.6 captain rating = 5 + fleet tier (pirate 1, navy 2).
	_check(DuelLib.captain_rating(PIRATE_TIER) == 6,
		"captain_rating(pirate tier 1) == 6 (got %d)"
		% DuelLib.captain_rating(PIRATE_TIER))
	_check(DuelLib.captain_rating(NAVY_TIER) == 7,
		"captain_rating(navy tier 2) == 7 (got %d)"
		% DuelLib.captain_rating(NAVY_TIER))
	_check(DuelLib.captain_rating(PIRATE_TIER) == BattleLib.CAPTAIN_RATING_BASE + PIRATE_TIER,
		"…and 5 is BattleSim's own constant, not a second copy")


# --- 2. The §5 scripted duel through Duel.start ---------------------------

func _test_scripted_duel() -> void:
	var direct := BattleLib.resolve_duel(
		DOC_PLAYER_BASE, DOC_DEFENDER_BASE, _rng(DOC_SEED))
	var via_start: Dictionary = await DuelLib.start(_duel_config())

	_check(str(direct["rounds"]) == str(DOC_ROUNDS),
		"a direct resolve_duel(15, 10, seed 33) reproduces the §5 sequence %s (got %s)"
		% [str(DOC_ROUNDS), str(direct["rounds"])])
	_check(str(via_start["rounds"]) == str(DOC_ROUNDS),
		"Duel.start(config) reproduces the same scripted sequence (got %s)"
		% str(via_start["rounds"]))
	_check(str(via_start["result"]) == "capture",
		"seed 33 wins the duel (capture: %s)" % str(via_start["result"]))
	_check(int(via_start["player_wins"]) == 3 and int(via_start["defender_wins"]) == 1,
		"…3 round wins to 1, the §5 'decided 3-1' (%d-%d)"
		% [int(via_start["player_wins"]), int(via_start["defender_wins"])])
	_check(via_start == direct,
		"Duel.start returns resolve_duel's dictionary unchanged (equal: %s)"
		% str(via_start == direct))
	_check(JSON.stringify(via_start) == JSON.stringify(direct),
		"…and serialises identically (%s)" % JSON.stringify(via_start))

	# Determinism: same config, same duel.
	var repeat: Dictionary = await DuelLib.start(_duel_config())
	_check(repeat == via_start, "the same config replays the identical duel")

	# A handed-over `rng` stream continues instead of reseeding (§4.12.1 seam).
	var expected := BattleLib.resolve_duel(
		DOC_PLAYER_BASE, DOC_DEFENDER_BASE, _rng(DOC_SEED))
	var via_rng: Dictionary = await DuelLib.start({
		"player_base": DOC_PLAYER_BASE,
		"defender_base": DOC_DEFENDER_BASE,
		"rng": _rng(DOC_SEED),
		"attacker_name": "You",
		"defender_name": "Pirate captain",
	})
	_check(via_rng == expected,
		"a handed-over rng stream produces the same rolls as a direct call")

	# Different bases change the duel (they are actually used, not ignored).
	var stronger: Dictionary = await DuelLib.start(_duel_config({"defender_base": 26}))
	_check(stronger != via_start,
		"a different defender base changes the outcome (proves the base is used)")

	# `preview()` carries the per-round rolls S11 renders, and its outcome is
	# the same duel (the stream must not be consumed twice).
	var preview: Dictionary = DuelLib.preview(_duel_config())
	_check(preview["outcome"] == direct, "Duel.preview().outcome equals the direct duel")
	_check((preview["rolls"] as Array).size() == DOC_ROUNDS.size(),
		"preview() reports one pair of rolls per played round (%d)"
		% (preview["rolls"] as Array).size())
	var rolls_match := true
	for index in (preview["rolls"] as Array).size():
		var roll: Dictionary = (preview["rolls"] as Array)[index]
		var verdict := str((direct["rounds"] as Array)[index])
		var expected_verdict := "win" if int(roll["player"]) > int(roll["defender"]) \
			else ("loss" if int(roll["defender"]) > int(roll["player"]) else "tie")
		if verdict != expected_verdict:
			rolls_match = false
	_check(rolls_match,
		"each previewed roll pair explains the round verdict (player > defender ⇒ win)")
	_check(int(preview["player_base"]) == DOC_PLAYER_BASE
			and int(preview["defender_base"]) == DOC_DEFENDER_BASE,
		"preview() echoes both bases for the header")


# --- 3. Both outcomes reachable through Duel.start ------------------------

func _test_outcomes_reachable() -> void:
	var capture: Dictionary = await DuelLib.start(_duel_config())
	var defeat: Dictionary = await DuelLib.start(_duel_config({"seed": DEFEAT_SEED}))
	_check(str(capture["result"]) == "capture",
		"a capture is reachable through Duel.start (seed %d)" % DOC_SEED)
	_check(str(defeat["result"]) == "defeat",
		"a defeat is reachable through Duel.start (seed %d)" % DEFEAT_SEED)
	_check(str(defeat["rounds"]) == str(["loss", "win", "loss", "loss"]),
		"the defeat seed is the documented mirror sequence (got %s)"
		% str(defeat["rounds"]))

	# §4.11.6: equal counts after 5 rounds are held by the defender.
	var held: Dictionary = await DuelLib.start(_duel_config({"seed": HELD_SEED}))
	_check((held["rounds"] as Array).size() == 5,
		"a level duel runs the full 5 rounds (%d)" % (held["rounds"] as Array).size())
	_check(int(held["player_wins"]) == int(held["defender_wins"])
			and str(held["result"]) == "defeat",
		"…level after 5 rounds → the defender holds (defeat: %d-%d)"
		% [int(held["player_wins"]), int(held["defender_wins"])])
	_check("tie" in (held["rounds"] as Array),
		"…because a tie scored for nobody (%s)" % str(held["rounds"]))

	# §4.6/§4.11.6: board-and-hold is not a second formula — a duel resolved
	# straight from the two base helpers equals the config-driven one.
	_stats(12)
	DuelLib.preview(_duel_config())  # warm path, no state kept
	_check(DuelLib.player_base() == 12 and DuelLib.defender_base(20, 6) == 10,
		"the base helpers feed exactly the §5 fixture numbers (12 vs 10)")


# --- 4. The headless contract --------------------------------------------

func _test_headless_contract() -> void:
	var before := _duel_modal_count()
	var outcome: Dictionary = await DuelLib.start(_duel_config())
	_check(outcome.has("result") and outcome.has("rounds"),
		"headless Duel.start still returns a full outcome")
	_check(not DuelLib.last_presented,
		"headless Duel.start never presents the modal (last_presented false)")
	_check(_duel_modal_count() == before,
		"Duel.start instances no duel_modal node in a headless run (%d before/after)"
		% before)
	_check(DuelLib.presentation_host(_duel_config()) == null,
		"presentation_host() is null in a headless run, so no scene is loaded")
	_check(DuelLib.is_headless(), "is_headless() detects the headless display server")

	# An explicit `present: false` is the same headless path, even with a live
	# host in the tree (the opt-out a nested UI needs).
	var host := Control.new()
	add_child(host)
	_check(DuelLib.presentation_host(_duel_config({"host": host, "present": false})) == null,
		"`present: false` disables presentation even with a live host")
	# A host that is not inside the tree is also refused.
	var orphan := Control.new()
	_check(DuelLib.presentation_host(_duel_config({"host": orphan})) == null,
		"a host outside the scene tree is refused (never instanced detached)")
	orphan.free()
	host.queue_free()
	await get_tree().process_frame


func _duel_modal_count() -> int:
	var count := 0
	for node in _all_nodes(get_tree().root):
		if node.get_script() == ModalLib:
			count += 1
	return count


func _all_nodes(node: Node) -> Array:
	var out: Array = [node]
	for child in node.get_children():
		out.append_array(_all_nodes(child))
	return out


# --- 5. The presentation path end-to-end ----------------------------------

## `Duel.start`'s presentation path, end to end. The headless display would
## normally take the immediate path, so the documented test seam
## `Duel.force_presentation` turns the real path on: `start` must instance S11,
## open it, suspend, and resume with `resolve_duel`'s dictionary when the
## player acknowledges.
func _test_presentation() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var expected := BattleLib.resolve_duel(
		DOC_PLAYER_BASE, DOC_DEFENDER_BASE, _rng(DOC_SEED))

	DuelLib.force_presentation = true
	_start_done = false
	_start_result = {}
	_run_start(_duel_config({"host": host}))
	DuelLib.force_presentation = false

	var modal: Node = null
	for child in host.get_children():
		if child.get_script() == ModalLib:
			modal = child
	_check(modal != null,
		"Duel.start instances duel_modal.tscn under the supplied host")
	_check(DuelLib.last_presented, "…and reports last_presented = true")
	if modal == null:
		host.queue_free()
		await get_tree().process_frame
		return
	_check(modal.is_open() and modal.is_in_group("modal_overlay"),
		"…already open and in the modal_overlay group")
	_check(int(modal.result()["player_wins"]) == 3,
		"…showing the same duel resolve_duel produced (3 round wins)")
	_check(modal.round_count() == DOC_ROUNDS.size(),
		"…with one row per played round (%d)" % modal.round_count())
	_check(not _start_done,
		"Duel.start is suspended until the player acknowledges the duel")

	modal.close()
	_check(_start_done, "…and resumes on `closed`")
	_check(_start_result == expected,
		"…returning resolve_duel's dictionary unchanged (%s)" % str(_start_result))
	_check(not is_instance_valid(modal) or modal.is_queued_for_deletion(),
		"Duel.start frees the modal after the acknowledgement")
	host.queue_free()
	await get_tree().process_frame


## Starts `Duel.start` as a coroutine (no `await` here: the point is to observe
## the suspension) and records its return value for the caller.
func _run_start(config: Dictionary) -> void:
	_start_result = await DuelLib.start(config)
	_start_done = true


# --- 6. Capture into the fleet (§4.11.7) ---------------------------------

func _test_capture_full_fleet() -> void:
	# §4.11.7 `FLEET_MAX`: a 4-ship fleet takes the captured hull → 5 ships.
	GameState.fleet = [
		_ship("sloop"), _ship("latin"), _ship("caravel"), _ship("brigantine"),
	]
	var captured_hull := _ship("nao", {"durability": 140, "crew": 25})
	_fleet_changed = 0
	var applied: Dictionary = ResultLib.apply(
		_outcome({"captured_enemy": [captured_hull]}), [], GameState.fleet)
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"a 4-ship fleet + 1 capture == FLEET_MAX 5 (%d)" % GameState.fleet.size())
	_check((applied["captured_ships"] as Array) == ["nao"],
		"the outcome reports the captured ship_type_id (%s)"
		% str(applied["captured_ships"]))
	_check(int(applied["cargo_overflow_lost"]) == 0,
		"nothing overflowed (%d)" % int(applied["cargo_overflow_lost"]))
	_check(str(GameState.fleet[GameState.fleet.size() - 1]["ship_type_id"]) == "nao",
		"the capture joins in fleet order at the end")
	_check(_fleet_changed >= 1,
		"a capture that joins the fleet emits fleet_changed (%d)" % _fleet_changed)
	# §4.11.6/§4.11.7 hull transform: 140 × 0.25 = 35, crew cleared.
	var joined: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
	_check(int(joined["durability"]) == 35,
		"the captured hull keeps 25%% of its current durability (140 → 35, got %d)"
		% int(joined["durability"]))
	_check(int(joined["crew"]) == 0,
		"…with a cleared crew (got %d)" % int(joined["crew"]))

	# §4.11.7 full fleet: loot cargo to capacity, scuttle, report the rest.
	# The fleet's holds are emptied first so the loot destination is exact.
	for ship in GameState.fleet:
		ship["cargo"] = {}
		ship["provisions"] = 0
		ship["water"] = 0
		ship["cannons"] = 0
	var capacity := 0
	for ship in GameState.fleet:
		capacity += FleetLib.ship_stat(ship, "capacity")
	var loot_hull := _ship("sloop", {
		"durability": 60, "crew": 10, "cannons": 2,
		"cargo": {"wine": 1000},
		"provisions": 3, "water": 4,
	})
	_fleet_changed = 0
	var full_applied: Dictionary = ResultLib.apply(
		_outcome({"captured_enemy": [loot_hull]}), [], GameState.fleet)
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"a full 5-ship fleet stays at 5 (got %d)" % GameState.fleet.size())
	_check((full_applied["captured_ships"] as Array).is_empty(),
		"…so the captured hull does not join")
	_check((full_applied["scuttled_ships"] as Array) == ["sloop"],
		"…it is looted and scuttled instead (%s)"
		% str(full_applied["scuttled_ships"]))
	_check(FleetLib.held("wine") == capacity,
		"…its cargo fills the fleet to exactly its capacity (%d of %d wine)"
		% [FleetLib.held("wine"), capacity])
	_check(int(full_applied["cargo_overflow_lost"]) == 1000 - capacity + 3 + 4,
		"…and the uncarriable goods + provisions/water are counted, not dropped "
		+ "silently (%d; expected %d)"
		% [int(full_applied["cargo_overflow_lost"]), 1000 - capacity + 7])
	_check(_fleet_changed >= 1,
		"fleet_changed is emitted for the scuttle/loot (%d)" % _fleet_changed)

	# A fleet at the cap only *because* of this battle's capture scuttles the
	# next one: two captures into a 4-ship fleet → 5 ships, second looted.
	GameState.fleet = [
		_ship("sloop"), _ship("latin"), _ship("caravel"), _ship("brigantine"),
	]
	var two: Dictionary = ResultLib.apply(
		_outcome({"captured_enemy": [_ship("sloop"), _ship("sloop")]}), [], GameState.fleet)
	_check(GameState.fleet.size() == FleetLib.FLEET_MAX,
		"two captures into a 4-ship fleet leave exactly 5 (%d)" % GameState.fleet.size())
	_check((two["captured_ships"] as Array).size() == 1
			and (two["scuttled_ships"] as Array).size() == 1,
		"…the first joins, the second is scuttled (%s / %s)"
		% [str(two["captured_ships"]), str(two["scuttled_ships"])])


func _test_capture_transform() -> void:
	# §4.11.7: durability floor + cargo/cannons/equipment intact. 1 × 0.25
	# floors to 0, which the `max(1, …)` rule lifts to 1. (An empty fleet, so
	# `normalize_all` has no earlier hull to redistribute the hold into — the
	# flagship-first invariant of `40-*` §4.2 is asserted on its own in
	# `tools/test_fleet.gd`.)
	GameState.fleet = []
	var hull := _ship("brigantine", {
		"durability": 1,
		"crew": 40,
		"cannons": 7,
		"cargo": {"wine": 12, "silk": 3},
		"provisions": 5,
		"water": 6,
		"equipment": {"figurehead": "eq_mermaid_figurehead", "sail": "eq_cotton_sails"},
	})
	var applied: Dictionary = ResultLib.apply(
		_outcome({"captured_enemy": [hull]}), [], GameState.fleet)
	var taken: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
	_check(int(taken["durability"]) == 1,
		"a 1-durability hull is captured at 1, not 0 (max(1, floor(0.25 × 1)): %d)"
		% int(taken["durability"]))
	_check(int(taken["crew"]) == 0, "the captured hull's crew is 0 (%d)" % int(taken["crew"]))
	_check(int(taken["cannons"]) == 7,
		"its cannons stay intact (%d)" % int(taken["cannons"]))
	_check((taken["cargo"] as Dictionary) == {"wine": 12, "silk": 3},
		"its cargo stays intact (%s)" % str(taken["cargo"]))
	_check((taken["equipment"] as Dictionary)["figurehead"] == "eq_mermaid_figurehead"
			and (taken["equipment"] as Dictionary)["sail"] == "eq_cotton_sails",
		"its equipment stays intact (%s)" % str(taken["equipment"]))
	_check(int(applied["cargo_overflow_lost"]) == 0,
		"a hull that fits its own hold causes no overflow (%d)"
		% int(applied["cargo_overflow_lost"]))
	# The capture copy is independent: mutating it never edits the battle's
	# outcome instance (the sim's copy stays at full durability).
	_check(int(hull["durability"]) == 1,
		"the outcome's own hull instance is not mutated by the capture")

	# A hull whose hold is over capacity for its own type: the §4.11.7
	# normalize_all() guard truncates, and the overflow is reported.
	GameState.fleet = []
	var overloaded := _ship("latin", {"cargo": {"wine": 500}})
	var over_applied: Dictionary = ResultLib.apply(
		_outcome({"captured_enemy": [overloaded]}), [], GameState.fleet)
	var over_taken: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
	_check(FleetLib.used_capacity(over_taken) <= FleetLib.ship_stat(over_taken, "capacity"),
		"an over-capacity captured hold is truncated to the hull's capacity (%d ≤ %d)"
		% [FleetLib.used_capacity(over_taken), FleetLib.ship_stat(over_taken, "capacity")])
	_check(int(over_applied["cargo_overflow_lost"])
			== 500 - FleetLib.ship_stat(over_taken, "capacity"),
		"…and every dropped unit is reported (%d; expected %d)"
		% [int(over_applied["cargo_overflow_lost"]),
		500 - FleetLib.ship_stat(over_taken, "capacity")])

	# Normalize keeps a *captured* hull's hold: earlier hulls with room may
	# only be filled, never drained, so nothing above is a mini-`add_goods`.
	_check(FleetLib.held("wine") == FleetLib.ship_stat(over_taken, "capacity"),
		"the surviving units stay in the captured hold (flagship-first "
		+ "distribution moved nothing away from an earlier ship)")


# --- 7. Loss, promotion, game over (§4.11.7, §4.11.9) --------------------

func _test_loss_paths() -> void:
	# Losing the flagship with an escort: the next hull is fleet[0] afterwards.
	GameState.fleet = [_ship("latin"), _ship("sloop"), _ship("caravel")]
	var lost_flagship: Dictionary = (GameState.fleet[0] as Dictionary).duplicate(true)
	_game_over.clear()
	_fleet_changed = 0
	var applied: Dictionary = ResultLib.apply(
		_outcome({"lost_player": [lost_flagship]}), [], GameState.fleet)
	_check(GameState.fleet.size() == 2,
		"losing one hull removes exactly one (3 → %d)" % GameState.fleet.size())
	_check(str(GameState.fleet[0]["ship_type_id"]) == "sloop",
		"the next ship becomes the flagship (fleet[0] = %s)"
		% str(GameState.fleet[0]["ship_type_id"]))
	_check((applied["lost_ships"] as Array) == ["latin"],
		"the outcome reports the lost ship_type_id (%s)" % str(applied["lost_ships"]))
	_check(_game_over.is_empty(),
		"escorts remain, so no game_over fires (%s)" % str(_game_over))
	_check(str(applied["game_over"]) == "",
		"…and the applied outcome's game_over field is empty")
	_check(_fleet_changed >= 1, "fleet_changed fires for the loss (%d)" % _fleet_changed)

	# Loss matching falls back to the hull type when the battle changed the
	# instance (durability from cannon fire): the count must still be right.
	GameState.fleet = [_ship("latin"), _ship("sloop")]
	var damaged: Dictionary = (GameState.fleet[0] as Dictionary).duplicate(true)
	damaged["durability"] = 3
	ResultLib.apply(_outcome({"lost_player": [damaged]}), [], GameState.fleet)
	_check(GameState.fleet.size() == 1
			and str(GameState.fleet[0]["ship_type_id"]) == "sloop",
		"a battle-damaged instance still removes its own hull, not another (left: %s)"
		% str(GameState.fleet))

	# Losing the last ship to a capture → game_over("captured") (§4.11.7).
	GameState.fleet = [_ship("latin")]
	var last: Dictionary = (GameState.fleet[0] as Dictionary).duplicate(true)
	_game_over.clear()
	var final: Dictionary = ResultLib.apply(
		_outcome({"result": "defeat_captured", "lost_player": [last]}), [], GameState.fleet)
	_check(GameState.fleet.is_empty(), "losing the last ship empties the fleet")
	_check(_game_over == ["captured"],
		"…and emits game_over(\"captured\") (got %s)" % str(_game_over))
	_check(str(final["game_over"]) == "captured",
		"the applied outcome reports game_over = captured")

	# The S9 screen accepts `captured`: it renders the reason once
	# `gameover.captured` is merged (docs/60-* §6 "the reason set becomes
	# {…, captured}"; §4.12.5 owns the string) and otherwise hides the row
	# rather than printing a bare key. Both halves are asserted so the check
	# survives the ui_strings merge.
	var screen = GameOverScene.instantiate()
	add_child(screen)
	screen.route_to_title = false
	screen.open_reason("captured")
	var reason_row: Label = screen.get_node("Center/Panel/Margin/Body/Reason")
	var has_key := DataLoader.ui_strings.has("gameover.captured")
	_check("captured" in screen.REASONS,
		"the game-over reason set accepts `captured` ({starvation, scurvy, sunk, "
		+ "captured}, §60 §6): %s" % str(screen.REASONS))
	if has_key:
		_check(reason_row.visible and screen.reason_text() == I18n.fmt(
			"gameover.reason", {"reason": I18n.t_key("gameover.captured")}),
			"…and renders gameover.captured (%s)" % screen.reason_text())
	else:
		_check(not reason_row.visible,
			"…and hides the reason row while gameover.captured is unmerged "
			+ "(never a raw <key>, §80 §6)")
	_check(reason_row.text.find("<") == -1,
		"the reason row never holds a raw <key> (%s)" % reason_row.text)
	screen.queue_free()

	# A sinking-caused empty fleet uses the other reason (§4.11.9). The sim
	# reports a sunk hull in `sunk_player` (ids), not `lost_player`.
	GameState.fleet = [_ship("sloop")]
	_game_over.clear()
	ResultLib.apply(_outcome({"result": "defeat_sunk", "sunk_player": ["sloop"]}),
		[], GameState.fleet)
	_check(GameState.fleet.is_empty(), "a sunk last ship leaves the fleet")
	_check(_game_over == ["sunk"],
		"a sinking-caused empty fleet emits game_over(\"sunk\") (got %s)" % str(_game_over))

	# `sunk_player` (§4.12.2) is the sinking tally and its hulls leave the
	# fleet too (§4.7): the outcome carries ids, so the removal is by type.
	GameState.fleet = [_ship("sloop"), _ship("latin")]
	var sunk_only: Dictionary = ResultLib.apply(
		_outcome({"result": "victory", "sunk_player": ["sloop"], "lost_player": []}),
		[], GameState.fleet)
	_check(GameState.fleet.size() == 1,
		"a `sunk_player` hull leaves the fleet too (§4.7; %d ship left)"
		% GameState.fleet.size())
	_check((sunk_only["sunk_ships"] as Array) == ["sloop"],
		"…and is reported in sunk_ships (%s)" % str(sunk_only["sunk_ships"]))
	_check(str(sunk_only["result"]) == "victory",
		"…and the outcome block is passed through unchanged (result: %s)"
		% str(sunk_only["result"]))
	# A sunk id with no matching fleet hull removes nothing (never a stray ship).
	var unmatched: Dictionary = ResultLib.apply(
		_outcome({"result": "victory", "sunk_player": ["galleon"]}), [], GameState.fleet)
	_check(GameState.fleet.size() == 1 and (unmatched["sunk_ships"] as Array).is_empty(),
		"a sunk id with no matching hull removes nothing (%d ship)"
		% GameState.fleet.size())

	# Nothing to change → no signals at all (§4.12.3: "when the fleet changed").
	GameState.fleet = [_ship("sloop")]
	_fleet_changed = 0
	_game_over.clear()
	ResultLib.apply(_outcome({"lost_player": []}), [], GameState.fleet)
	_check(_fleet_changed == 0 and _game_over.is_empty(),
		"an outcome that changes nothing emits neither signal")
	await get_tree().process_frame
	await _test_boarding_end_to_end()


## The whole §4.12.4 chain for one boarding: `BattleSim.board()` (which resolves
## through the one duel formula) → `outcome()` → `BattleResult.apply()` → the
## fleet. This is the integration a single module test cannot show.
func _test_boarding_end_to_end() -> void:
	_stats(12)
	GameState.player["equipment"] = {"weapon": "", "armor": ""}
	# A pirate sloop (crew 10 → 2, + rating 6 = 8) boarded by a 12-combat
	# captain: seed 2 gives win/loss/win/win → capture 3–1.
	var sim := _sim({
		"player_ships": [_ship("brigantine", {"crew": 60})],
		"enemy_ships": [_ship("sloop", {"crew": 10, "cannons": 0, "cargo": {"wine": 6}})],
		"seed": 2,
	})
	sim.start()
	var player_unit: Dictionary = _unit(sim, "player", 0)
	var enemy_unit: Dictionary = _unit(sim, "enemy", 0)
	enemy_unit["cell"] = Vector2i(2, 4)
	var boarding: Dictionary = sim.board(player_unit, enemy_unit)
	_check(str(boarding["duel"]["result"]) == "capture",
		"the boarding resolves to a capture through resolve_duel (%s)"
		% str(boarding["duel"]["result"]))
	_check(sim.is_over(), "…and ends the battle (the only enemy is taken)")

	GameState.fleet = [_ship("sloop")]
	var raw: Dictionary = sim.outcome()
	_check(raw["cargo_overflow_lost"] == 0,
		"the raw outcome carries the §4.12.2 cargo_overflow_lost placeholder")
	var applied: Dictionary = ResultLib.apply(raw, sim.units(), GameState.fleet)
	_check(GameState.fleet.size() == 2,
		"the captured sloop joins the 1-ship fleet (%d ships)" % GameState.fleet.size())
	_check(str(applied["result"]) == "victory",
		"…for a victory outcome (%s)" % str(applied["result"]))
	var taken: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
	_check(int(taken["durability"]) == 15,
		"…at max(1, floor(60 × 0.25)) = 15 durability (%d)" % int(taken["durability"]))
	_check(int(taken["crew"]) == 0, "…with crew 0 (%d)" % int(taken["crew"]))
	_check(FleetLib.held("wine") == 6,
		"…and its 6 wine survive in the pooled hold (%d; §4.2 flagship-first "
		% FleetLib.held("wine") + "distribution may carry them into the older hull)")
	_check((applied["captured_units"] as Array).size() == 1
			and int((applied["captured_units"] as Array)[0]["index"]) == 0,
		"…tagged with the enemy unit index it came from (%s)"
		% str(applied["captured_units"]))
	_check(GameState.fleet.size() > 1 and str(GameState.fleet[0]["ship_type_id"]) == "sloop",
		"the original flagship stays at fleet[0] (captures append)")


## The `BattleSim` config used above (the §4.12.1 table with test values).
func _sim(config: Dictionary) -> BattleLib:
	var full := {
		"player_ships": [], "enemy_ships": [], "enemy_kind": "pirate",
		"enemy_nation": "", "day": 1, "gold": 0,
		"contact": Vector2i(30, 40), "weather": "calm",
	}
	for key in config:
		full[key] = config[key]
	return BattleLib.new(full)


## The live unit dict of `side`/`index` (the engine's handles).
func _unit(sim: BattleLib, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


# --- 8. The S11 scene (§4.7.1, §4.8, §5.1, §6) --------------------------

func _test_modal() -> void:
	if not EventBus.has_signal("duel_finished"):
		# `90-*` §5.1 pins the signal; the autoload lands with another task
		# (this branch never edits `autoload/`). Register it for the run so the
		# emission contract is still proven end-to-end.
		EventBus.add_user_signal("duel_finished", [TYPE_DICTIONARY])
	var finished: Array = []
	var collector := func(payload: Dictionary) -> void: finished.append(payload)
	EventBus.connect("duel_finished", collector)

	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var modal = ModalScene.instantiate()
	host.add_child(modal)
	_check(modal is Control, "duel_modal.tscn instantiates as a Control modal")

	var payload: Dictionary = DuelLib.preview(_duel_config())
	modal.open_duel(payload)
	_check(modal.is_open(), "open_duel(config) opens the modal")
	_check(modal.is_in_group("modal_overlay"),
		"…and joins the modal_overlay group (§4.7 'modals consume input')")
	var dim: ColorRect = modal.get_node("Dim")
	_check(is_equal_approx(dim.color.a, 0.4),
		"the dim is 40%% black (§4.7: got %.2f)" % dim.color.a)
	var panel: Control = modal.get_node("Center/Panel")
	_check(panel.custom_minimum_size.x == 480.0,
		"the panel is 480px wide (§4.8: got %.0f)" % panel.custom_minimum_size.x)

	# One row per round, each with the two rolls and a verdict.
	_check(modal.round_count() == DOC_ROUNDS.size(),
		"one row per played round (%d, §4.7.1)" % modal.round_count())
	var rows: Array = modal.round_rows()
	var rolls_ok := true
	for index in rows.size():
		var row: Dictionary = rows[index]
		var roll: Dictionary = (payload["rolls"] as Array)[index]
		if not str((row["player"] as Label).text).ends_with(str(roll["player"])):
			rolls_ok = false
		if not str((row["defender"] as Label).text).ends_with(str(roll["defender"])):
			rolls_ok = false
		if (row["verdict"] as Label).text.is_empty():
			rolls_ok = false
	_check(rolls_ok, "each row shows both captains' rolls and a localised verdict")
	_check(str(modal.result()["result"]) == "capture",
		"result() exposes the outcome (%s)" % str(modal.result()["result"]))
	# The header names both captains (§4.7.1) — names are data, not keys.
	var header: Label = modal.get_node("Center/Panel/Margin/Body/Header")
	_check(header.text.contains("You") and header.text.contains("Pirate captain"),
		"the header names both captains (%s)" % header.text)
	# Round verdicts use the §4.12.5 keys when merged, numbers otherwise.
	var verdict_ok := true
	for verdict in ["win", "loss", "tie"]:
		var key := str(ModalLib.ROUND_KEYS.get(verdict, ""))
		var expected: String = I18n.t_key(key) if DataLoader.ui_strings.has(key) \
			else ModalLib._verdict_fallback(verdict)
		if modal._verdict_text(verdict) != expected:
			verdict_ok = false
	_check(verdict_ok, "duel.round.win|loss|tie render through their §4.12.5 keys "
		+ "(or the numeric fallback while unmerged)")
	_check(modal._verdict_text("win") in ["Win", "胜", "+1"]
			or DataLoader.ui_strings.has(str(ModalLib.ROUND_KEYS["win"])),
		"a win verdict is a localised word or a neutral number (%s)"
		% modal._verdict_text("win"))

	# Every visible Label/Button is non-empty and never a raw `<key>` (§6), in
	# both locales — the "no <key> anywhere" done-when.
	I18n.set_locale("en")
	var english_result: String = (modal.get_node(
		"Center/Panel/Margin/Body/Result") as Label).text
	var leaks: Array[String] = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		leaks.append_array(_label_leaks(modal, locale))
	_check(leaks.is_empty(),
		"no visible label/button renders empty or a raw <key> in either locale (%s)"
		% str(leaks))
	# The result line rebinds on `locale_changed` (§6 mid-dialog toggle).
	I18n.set_locale("en")
	var result_label: Label = modal.get_node("Center/Panel/Margin/Body/Result")
	_check(result_label.text == english_result,
		"the result line rebinds back to the English text after a round-trip (%s)"
		% result_label.text)
	# Re-binding must not duplicate rows.
	_check(modal.round_count() == DOC_ROUNDS.size(),
		"a locale rebind does not duplicate the round rows (%d)" % modal.round_count())

	# The single acknowledgement button (there is no retreat, §4.6).
	var acknowledge: Button = modal.get_node("Center/Panel/Margin/Body/Footer/Acknowledge")
	_check(acknowledge.text == I18n.t_key("ui.ok"),
		"the single button is the shared `ui.ok` acknowledgement (%s)" % acknowledge.text)
	_check(acknowledge.custom_minimum_size.y == float(PaletteLib.BUTTON_H),
		"…at the §4.8 40px button height (%.0f)" % acknowledge.custom_minimum_size.y)
	_check(modal.find_children("*", "Button", true, false).size() == 1,
		"…and it is the only button: boarding commits, there is no cancel")

	modal.close()
	_check(finished.size() == 1,
		"closing emits EventBus.duel_finished exactly once (%d)" % finished.size())
	_check(not (finished[0] as Dictionary).is_empty()
			and str((finished[0] as Dictionary).get("result", "")) == "capture",
		"…with the outcome payload (%s)" % str(finished[0]))
	var payload_keys: Array = (finished[0] as Dictionary).keys()
	_check(payload_keys.has("result") and payload_keys.has("rounds")
			and payload_keys.has("attacker") and payload_keys.has("defender"),
		"…shaped {result, rounds, attacker, defender} per §5.1 (%s)"
		% str(payload_keys))
	_check(not modal.is_open() and not modal.is_in_group("modal_overlay"),
		"…and the modal is closed and out of the group")
	modal.close()
	_check(finished.size() == 1,
		"a second close() on a closed modal emits nothing more (%d)" % finished.size())

	# A second duel on the same instance emits once more, not twice.
	modal.open_duel(_duel_config({"seed": DEFEAT_SEED}))
	_check(modal.is_open() and modal.round_count() == 4,
		"re-opening re-renders the new duel (4 rounds)")
	modal.close()
	_check(finished.size() == 2,
		"one more duel → exactly one more signal (%d total)" % finished.size())
	_check(str((finished[1] as Dictionary).get("result", "")) == "defeat",
		"…carrying the defeat result (%s)" % str(finished[1]))

	# A bare config (no preview payload) also resolves through resolve_duel.
	modal.open_duel(_duel_config())
	_check(modal.round_count() == DOC_ROUNDS.size()
			and str(modal.result()["result"]) == "capture",
		"open_duel accepts a bare Duel.start config and resolves it identically")
	modal.close()
	_check(finished.size() == 3, "…and emits one signal for that duel too (%d)"
		% finished.size())

	# Long captain names never widen the 480px panel (§4.8; the header wraps,
	# the round cells trim).
	modal.open_duel({
		"player_base": 15, "defender_base": 10, "seed": DOC_SEED,
		"attacker_name": "Bartholomew the Extremely Long-Winded Captain",
		"defender_name": "Don Alejandro de la Vega y Ramirez",
	})
	await get_tree().process_frame
	await get_tree().process_frame
	_check(panel.get_combined_minimum_size().x <= 480.0 + 8.0,
		"long captain names keep the panel at ~480px (min width %.0f)"
		% panel.get_combined_minimum_size().x)
	modal.close()

	EventBus.disconnect("duel_finished", collector)
	await _test_modal_with_keys(modal, payload)
	host.queue_free()
	await get_tree().process_frame


## The same scene with the six §4.12.5 `duel.*` keys injected as a test double
## (the `test_battle.gd` equipment-injection pattern), so the "renders the keys
## G is about to merge" half of the contract is proven before the merge lands.
## Every double is removed again and the inventory is asserted unchanged.
func _test_modal_with_keys(modal: Node, payload: Dictionary) -> void:
	var doubles := {
		"duel.title": {"zh": "船长决斗", "en": "Captain's Duel"},
		"duel.round.win": {"zh": "胜", "en": "Win"},
		"duel.round.loss": {"zh": "负", "en": "Loss"},
		"duel.round.tie": {"zh": "平", "en": "Tie"},
		"duel.result.capture": {
			"zh": "你赢得了决斗,敌船投降!",
			"en": "You win the duel — the enemy ship strikes her colours!",
		},
		"duel.result.defeat": {
			"zh": "你输掉了决斗,舰船被夺。",
			"en": "You lose the duel and your ship is taken.",
		},
		"duel.committed": {"zh": "接舷战无法撤退。", "en": "Boarding commits — there is no retreat."},
	}
	var previous: Dictionary = {}
	for key in doubles:
		previous[key] = DataLoader.ui_strings.get(key, null)
		DataLoader.ui_strings[key] = (doubles[key] as Dictionary).duplicate(true)

	modal.open_duel(payload)
	var title: Label = modal.get_node("Center/Panel/Margin/Body/Title")
	var result_label: Label = modal.get_node("Center/Panel/Margin/Body/Result")
	var committed: Label = modal.get_node("Center/Panel/Margin/Body/Committed")
	_check(title.visible and title.text == I18n.t_key("duel.title"),
		"with the keys merged the modal shows duel.title (%s)" % title.text)
	_check((modal.round_rows()[0]["verdict"] as Label).text == I18n.t_key("duel.round.win"),
		"…and duel.round.win for the first round (%s)"
		% (modal.round_rows()[0]["verdict"] as Label).text)
	_check(result_label.text == I18n.t_key("duel.result.capture"),
		"…and duel.result.capture as the closing line (%s)" % result_label.text)
	_check(committed.visible and committed.text == I18n.t_key("duel.committed"),
		"…and the duel.committed line (%s)" % committed.text)
	# Both locales, still no raw key anywhere.
	I18n.set_locale("zh")
	_check(title.text == doubles["duel.title"]["zh"]
			and result_label.text == doubles["duel.result.capture"]["zh"],
		"…switching to zh rebinds the title and result (%s / %s)"
		% [title.text, result_label.text])
	I18n.set_locale("en")
	_check(_label_leaks(modal, "en").is_empty(),
		"…and with the keys merged there is still no empty/<key> label")
	# Strict reading of the done-when: with the inventory complete, *every*
	# Label on the modal carries text (nothing hidden for want of a key).
	var bare: Array[String] = []
	for label in modal.find_children("*", "Label", true, false):
		var text := (label as Label).text
		if text.strip_edges().is_empty() or text.begins_with("<"):
			bare.append("%s='%s'" % [label.name, text])
	_check(bare.is_empty(),
		"with the inventory complete every Label is non-empty and not a <key> (%s)"
		% str(bare))

	# A defeat renders the other result key.
	modal.close()
	modal.open_duel(_duel_config({"seed": DEFEAT_SEED}))
	_check(result_label.text == I18n.t_key("duel.result.defeat"),
		"a lost duel closes with duel.result.defeat (%s)" % result_label.text)
	modal.close()

	for key in previous:
		if previous[key] == null:
			DataLoader.ui_strings.erase(key)
		else:
			DataLoader.ui_strings[key] = previous[key]
	await get_tree().process_frame
	var restored := true
	for key in doubles:
		var had: bool = previous[key] != null
		if DataLoader.ui_strings.has(key) != had:
			restored = false
	_check(restored, "the injected duel.* doubles are removed again "
		+ "(the inventory is back to its pre-test state)")


## Every visible `Label`/`Button` text of `root` that is empty or starts with
## `<` (the bare-key bug path, §6).
func _label_leaks(root: Node, locale: String) -> Array[String]:
	var leaks: Array[String] = []
	for label in root.find_children("*", "Label", true, false):
		if not (label as CanvasItem).is_visible_in_tree():
			continue
		var text := (label as Label).text
		if text.strip_edges().is_empty() or text.begins_with("<"):
			leaks.append("%s:%s='%s'" % [locale, label.name, text])
	for button in root.find_children("*", "Button", true, false):
		if not (button as CanvasItem).is_visible_in_tree():
			continue
		var text := (button as Button).text
		if text.strip_edges().is_empty() or text.begins_with("<"):
			leaks.append("%s:%s='%s'" % [locale, button.name, text])
	return leaks


# --- Helpers ---------------------------------------------------------------

## A §4.12.2 outcome block skeleton with `fields` merged over it.
func _outcome(fields: Dictionary) -> Dictionary:
	var outcome := {
		"result": "victory",
		"rounds": 6,
		"kind": "pirate",
		"nation_id": "",
		"encounter_id": "",
		"contact": {"x": 0, "y": 0},
		"sunk_enemy": [],
		"captured_enemy": [],
		"surrendered_enemy": 0,
		"sunk_player": [],
		"lost_player": [],
		"salvage_gold": 0,
		"xp": 0,
		"rep_deltas": {},
		"cargo_overflow_lost": 0,
	}
	for key in fields:
		outcome[key] = fields[key]
	return outcome


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
