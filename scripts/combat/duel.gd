class_name Duel
extends RefCounted
## Captain duel entry point (docs/60-COMBAT.md §4.6, §4.11.6, §4.12.1.2,
## §4.12.3, §5; docs/80-UI-UX.md §4.7.1).
##
## **One formula, one owner:** every roll is produced by
## [method BattleSim.resolve_duel]. This file only prepares the two bases
## (§4.11.6) and, when a scene tree is available, presents S11 and waits for
## the player's acknowledgement. It never re-implements the win rule, the
## round cap or the `capture`/`defeat` decision.
##
## Headless safety: [method start] presents **only** when it is running with a
## real display inside a scene tree (or when `config.host` is a node in a tree
## and `config.present` is true) and the build is not headless. In headless
## runs — every test in `tools/` — it returns immediately without instancing
## `duel_modal.tscn`, so no suite can ever block on a click.
##
## Return contract (§4.12.3): `start()` returns the **exact** dictionary
## [method BattleSim.resolve_duel] produced (`result`, `rounds`,
## `player_wins`, `defender_wins`), so a caller can compare it byte-for-byte
## against a direct call. The extra presentation data (per-round rolls, the two
## bases, the captain names) lives in [method preview], which the modal also
## accepts, so the *outcome* payload stays clean.

# Preloaded by path rather than through the global class names, so the file
# parses from a fresh checkout before the editor has written its class cache
# (the `ai_fleet.gd`/`fleet.gd` convention).
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")

## The S11 scene (docs/60-* §2). Loaded lazily by [method open_modal] and
## never preloaded: the modal preloads this file for its own `preview()`
## fallback, and a static preload in both directions would make GDScript fail
## to resolve either.
const SCENE_PATH := "res://scenes/combat/duel_modal.tscn"

## §4.11.6: `5 + fleet tier`; the tier table itself lives in `battle_sim.gd`
## (`FLEET_TIER`: pirate 1, navy 2) and is not copied here.
const CAPTAIN_RATING_BASE := BattleSimLib.CAPTAIN_RATING_BASE

## True after the last [method start] call actually presented the modal.
## Tests assert the headless contract with it (no click is ever needed).
static var last_presented: bool = false

## Test seam, the same convention as `gameover_screen.route_to_title` and
## `GameState.new_game(..., route)`: with `true`, [method start] presents even
## under `--headless`, so a suite can drive the real
## "instance → await → resume on acknowledgement" path instead of only its two
## halves. A shipped build never sets it.
static var force_presentation: bool = false


# --- Bases (docs/60-* §4.11.6) --------------------------------------------

## The player's duel base: effective `combat` (§4.11.5: base stat + assigned
## officer roles) plus the `combat` modifiers of both worn player items
## (§4.11.12), delegated to [method ShipyardEngine.player_combat_bonus] so the
## equipment sum exists once.
static func player_base() -> int:
	return CharacterLib.effective_stat("combat") + ShipyardLib.player_combat_bonus()


## The AI captain's base: `min(floor(crew / 5), 20) + captain_rating`
## (§4.11.6). Delegated to `BattleSim.defender_duel_base` — the same formula
## the battle's boarding action uses.
static func defender_base(crew: int, captain_rating: int) -> int:
	return BattleSimLib.defender_duel_base(crew, captain_rating)


## §4.6/§4.11.6: `5 + fleet tier` (pirate 1, navy 2). The rating is a fixed
## formula, not a roll, and is stored on the unit at battle start.
static func captain_rating(fleet_tier: int) -> int:
	return CAPTAIN_RATING_BASE + fleet_tier


# --- Presentation payloads -------------------------------------------------

## Resolves one duel and returns everything S11 renders, **without** touching
## the scene tree:
##
##   `{outcome, rolls, player_base, defender_base, attacker_name,
##     defender_name, ship_name}`
##
## `outcome` is [method BattleSim.resolve_duel]'s return value untouched;
## `rolls[i]` is `{player, defender}` — the two individual rolls of round `i`,
## recovered by replaying the **same** RNG stream from the snapshot taken just
## before `resolve_duel` consumed it (the function draws player-then-defender,
## §4.11.6). Replaying roll values is presentation only: the round labels and
## the result still come from `resolve_duel`.
static func preview(config: Dictionary) -> Dictionary:
	var player_rating := int(config.get("player_base", player_base()))
	var defender_rating := int(config.get("defender_base", 0))
	var rng := _rng_for(config)
	var state_before := rng.state
	var outcome: Dictionary = BattleSimLib.resolve_duel(player_rating, defender_rating, rng)
	return {
		"outcome": outcome,
		"rolls": _replay_rolls(
			state_before, player_rating, defender_rating,
			(outcome.get("rounds", []) as Array).size()
		),
		"player_base": player_rating,
		"defender_base": defender_rating,
		"attacker_name": str(config.get("attacker_name", "")),
		"defender_name": str(config.get("defender_name", "")),
		"ship_name": str(config.get("ship_name", "")),
	}


## Runs a duel and, when possible, presents S11 until the player acknowledges
## it (§4.6 "boarding commits — there is no retreat": the modal has a single
## confirmation, no cancel).
##
## `config`: `{player_base, defender_base, seed, ship_name, attacker_name,
## defender_name}` (§4.12.3) plus the optional extras `rng` (continue an
## existing stream, `battle_sim.gd`'s additive seam), `host` (Node the modal is
## attached to) and `present` (false forces the headless path).
##
## Returns `resolve_duel`'s dictionary unchanged. This is a coroutine because
## the presentation path waits for the player; in headless runs it returns on
## the same frame with `last_presented == false`.
static func start(config: Dictionary) -> Dictionary:
	var payload := preview(config)
	last_presented = false
	var host := presentation_host(config)
	if host == null:
		return payload["outcome"]
	var modal := open_modal(host, config, payload)
	if modal == null:
		return payload["outcome"]
	last_presented = true
	# `Signal(...)` rather than `modal.closed`: `modal` is an untyped Node here
	# (the scene's script is loaded at runtime), so the property does not exist
	# at parse time.
	await Signal(modal, "closed")
	modal.queue_free()
	return payload["outcome"]


# --- Presentation (S11) ----------------------------------------------------

## The node the modal should be attached to, or `null` for the headless path.
## A caller-provided `host` must be inside the tree; otherwise the current
## scene (or the tree root) is used when a display is available.
static func presentation_host(config: Dictionary) -> Node:
	if not bool(config.get("present", true)):
		return null
	if is_headless() and not force_presentation:
		return null
	var requested = config.get("host", null)
	var host: Node = requested if requested is Node else _current_scene()
	if host == null or not host.is_inside_tree():
		return null
	return host


## True in every `--headless` run. `OS.has_feature("headless")` is false in
## this Godot 4.7 build even under `--headless`, so the display server name is
## the reliable probe (both are checked; either one is enough).
static func is_headless() -> bool:
	if OS.has_feature("headless") or OS.has_feature("server"):
		return true
	return DisplayServer.get_name() == "headless"


static func _current_scene() -> Node:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var tree := loop as SceneTree
	return tree.current_scene if tree.current_scene != null else tree.root


## Instances `duel_modal.tscn` under `host`, following the modal convention of
## `scenes/ui_shared/fleet_panel.gd`: a `Control` host gets the modal as a
## child; any other host (the S10 screen's `Node2D` world, a `CanvasLayer`
## consumer) gets it inside a dedicated `CanvasLayer` so it neither inherits a
## camera transform nor collapses to a zero-size rect.
##
## Public (not `_`-prefixed) so the headless suite can prove the instancing
## half of the presentation path without a display server; S10 calls
## [method start], never this.
static func open_modal(host: Node, config: Dictionary, payload: Dictionary) -> Node:
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("Duel: missing %s" % SCENE_PATH)
		return null
	var modal: Node = scene.instantiate()
	modal.name = "DuelModal"
	var parent: Node = host
	if not (host is Control):
		var layer := host.get_node_or_null("DuelModalLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "DuelModalLayer"
			# Above the host screen's own canvas so the modal dims everything.
			layer.layer = 100
			host.add_child(layer)
		parent = layer
	parent.add_child(modal)
	var open_config := config.duplicate(true)
	# The resolved payload is authoritative: `resolve_duel` has already
	# consumed the RNG stream and must not be run twice.
	for key in payload:
		open_config[key] = payload[key]
	modal.open_duel(open_config)
	return modal


# --- Helpers ---------------------------------------------------------------

## The RNG for one duel: an explicitly handed stream wins (`battle_sim.gd`
## additive seam, so a caller can continue the battle's single §4.11.1
## stream), else a fresh generator seeded from `seed`, else seed 0.
static func _rng_for(config: Dictionary) -> RandomNumberGenerator:
	var shared = config.get("rng", null)
	if shared is RandomNumberGenerator:
		return shared
	var rng := RandomNumberGenerator.new()
	if config.has("seed"):
		rng.seed = int(config.get("seed", 0))
	else:
		push_warning("Duel: no `seed`/`rng` in config; using seed 0")
		rng.seed = 0
	return rng


## Replays `count` rounds of `resolve_duel`'s RNG consumption from a saved
## state to recover the individual rolls. The draw order (player, then
## defender; `0..20` each) and the `+base` are `battle_sim.gd`'s, reused from
## its constants — this function decides nothing about the outcome.
static func _replay_rolls(state_before: int, player_rating: int,
		defender_rating: int, count: int) -> Array:
	var probe := RandomNumberGenerator.new()
	probe.state = state_before
	var rolls: Array = []
	for _index in maxi(count, 0):
		var player_roll := player_rating \
			+ probe.randi_range(0, BattleSimLib.DUEL_ROUND_MAX_ROLL)
		var defender_roll := defender_rating \
			+ probe.randi_range(0, BattleSimLib.DUEL_ROUND_MAX_ROLL)
		rolls.append({"player": player_roll, "defender": defender_roll})
	return rolls
