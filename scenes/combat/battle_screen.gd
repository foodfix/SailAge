extends Control
## Battle screen (S10) — docs/60-COMBAT.md §4.2–§4.10, §4.11.2, §4.11.4,
## §4.11.9, §4.11.10, §4.12.1–§4.12.5; docs/80-UI-UX.md §4.1–§4.3, §4.7.1,
## §4.8; docs/90-ARCHITECTURE.md §5.1, §7.
##
## What this scene *is*: a thin input + render shell around [BattleSim]. Every
## rule (deployment, MP, damage, reload, the duel formula, the outcome block and
## every reward number) lives in the engine; this file only
##   * draws the §4.7.1 wireframe (16×10 tiles at 48px, 24×24 lettered tokens,
##     the bottom stat/action panel, the 3-line log, the after-action dialog);
##   * turns mouse clicks / `Tab` / arrows / `Enter` / `Esc` into engine calls;
##   * runs the §4.12.4 five-step battle-end sequence through the §4.12.3
##     guarded loaders, so no sibling task can block this one.
##
## **Two drivers, one engine.** The player acts through the buttons, clicks and
## keys; the AI acts through [AiFleet.decide] applied by [method run_ai_turn].
## Both mutate the same [BattleSim] *and* use the engine's own decision applier,
## so a battle played by hand and one driven by [method run_to_completion] obey
## exactly the same rules — which is what makes the headless suite meaningful
## proof for the interactive screen.
##
## **Turn flow (§4.3).** Moving does not end a turn; the one action per turn
## does. Once an action is spent (or the player holds), this screen advances the
## engine and plays every intervening AI turn, so the player always comes back
## to a ship they can command. Clicking a highlighted tile moves, clicking an
## enemy token in range is the default action, `Hold` passes.
##
## **Presentation is task-owned** (§4.7.1): every action appends one localised
## log line, no animation exists, and an engine log kind outside the §4.12.5
## inventory is simply not rendered rather than inventing `ui_strings` keys.
##
## **Test / headless contract.** [method open_battle] sets up and does *not*
## run; [method run_to_completion] drives the whole battle and returns
## [member last_outcome]. `route_to_world` is the `port_screen.route_to_world`
## convention: a suite instancing this scene as a child turns routing off and
## still gets the complete end-of-battle sequence, dialog included.
##
## Palette/engine scripts are preloaded rather than referenced through their
## global class names so the scene parses from a fresh checkout.

const PaletteLib := preload("res://scripts/palette.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")

const WORLD_SCENE := "res://scenes/world/world_map.tscn"
## Phase 3: a tournament bout returns to the host palace instead of S3, because
## the bracket continues there (`70-*` §4.9.7).
const PALACE_SCENE := "res://scenes/port/palace_screen.tscn"
## The application seams this task calls but must not own (§4.12.3).
const BATTLE_RESULT_PATH := "res://scripts/combat/battle_result.gd"
const BATTLE_REWARDS_PATH := "res://scripts/combat/battle_rewards.gd"
const DUEL_PATH := "res://scripts/combat/duel.gd"
## Phase-5 rename: the fleet-ecology module behind §4.12.4 step 4
## (`NpcFleets.remove` / `set_pursuit_cooldown`; docs/60-* §4.12.3).
const NPC_FLEETS_PATH := "res://scripts/world/npc_fleets.gd"
## Phase 3: quest/bounty/tournament aftermath (`70-*` §4.5, §4.9.7).
const PHASE3_HOOKS_PATH := "res://scripts/quests/phase3_hooks.gd"
## S9 (a shared Phase-1 scene) is instanced over S10 when a `gameover.*` fires.
const GAMEOVER_SCENE := "res://scenes/ui_shared/gameover_screen.tscn"

## §4.2 / §4.7.1 geometry: 48px tiles; 16×10 = 768×480, centred at (256, 56)
## between the 40px top bar and the bottom panel.
const TILE_PX := 48
const GRID_W := BattleSimLib.GRID_WIDTH
const GRID_H := BattleSimLib.GRID_HEIGHT
const GRID_PX := Vector2(GRID_W * TILE_PX, GRID_H * TILE_PX)
const GRID_ORIGIN := Vector2(256, 56)
## §4.8: ship tokens are 24×24 squares with a letter.
const TOKEN_PX := 24
## §4.7.1: the log panel shows the last 3 lines.
const LOG_LINES := 3
## Default round cap of [method run_to_completion] (§4.11.11.3).
const DEFAULT_MAX_ROUNDS := 30
## Token letters (§4.8 "colored 24×24 squares with a letter"): the player's
## flagship, other player hulls, and every enemy hull.
const TOKEN_FLAGSHIP := "F"
const TOKEN_PLAYER := "P"
const TOKEN_ENEMY := "E"
## Bar colour thresholds, the §4.8 GOOD/WARN/BAD placeholders (same as S6).
const BAR_GOOD_ABOVE := 0.6
const BAR_WARN_ABOVE := 0.25
## Safety net for the "play the AI until a player ship acts" loop.
const MAX_CHAINED_TURNS := 200

## Action ids in the §4.7.1 wireframe order; `battle.action.<id>` labels them.
const ACTION_IDS: Array[String] = [
	"cannon", "ram", "board", "hold", "retreat", "surrender",
]

## Emitted when a battle sets up (tests observe the engine without a swap).
signal battle_opened(encounter: Dictionary)
## Emitted once at the end, inside the §4.12.4 sequence, just before the
## after-action dialog. Tests observe this instead of a scene swap.
signal battle_closed(outcome: Dictionary)

## The engine driving this screen (null before [method open_battle]).
var sim = null
## §4.12.2 outcome block, filled at battle end (`{}` while the battle runs).
var last_outcome: Dictionary = {}
## Encounter descriptor this battle was opened from (§4.11.11 shape).
var encounter: Dictionary = {}

## Routing seam, the `port_screen.route_to_world` convention: a headless suite
## sets this false so the end-of-battle sequence (dialog included) runs without
## replacing the test's own scene root.
var route_to_world: bool = true
## Set when a `gameover.*` fired: S9 owns the screen then, so no S3 route
## underneath it (§4.12.4 step 5).
var game_over_raised: bool = false

## Guards a second [method finish] for the same battle.
var _finished := false
## Warning tag → how many times it was issued (§4.12.3 guard transparency:
## "exactly one warning per absent module").
var _warning_counts: Dictionary = {}
## Actions disabled this repaint: id → `ui_strings` reason key.
var _disabled_reasons: Dictionary = {}
## Cell the keyboard cursor sits on (`Enter` confirms it).
var _cursor := BattleSimLib.NO_CELL
var _cursor_visible := false
## Unit the player picked as the action target ({} = auto).
var _target: Dictionary = {}
## Unit the player explicitly selected; only ever an *acting* player ship.
var _selection: Dictionary = {}
## Presentation log records `{key, values}` — rendered fresh on every repaint so
## a locale toggle re-translates the same three lines (§6).
var _log_entries: Array = []
## How many engine log entries have already been presented.
var _presented := 0
## Actor key of the last `battle.log.turn` line, so it appears once per turn.
var _last_actor := ""
## The `gameover.*` reason that fired, "" while the run is alive.
var _gameover_reason := ""
## The S9 overlay instance (null until one fires).
var _gameover: Control = null

@onready var _background: ColorRect = $Background
@onready var _top_bar: ColorRect = $TopBar
@onready var _bottom_panel: ColorRect = $BottomPanel
@onready var _title: Label = $TopRow/Title
@onready var _day: Label = $TopRow/Day
@onready var _round: Label = $TopRow/Round
@onready var _weather: Label = $TopRow/Weather
@onready var _esc_hint: Label = $TopRow/EscHint
@onready var _grid_area: Control = $GridArea
@onready var _sea: ColorRect = $GridArea/Sea
@onready var _cells: Control = $GridArea/Cells
@onready var _tokens: Control = $GridArea/Tokens
@onready var _overlay: Control = $GridArea/Overlay
@onready var _flagship_label: Label = $BottomPanel/Margin/VBox/StatsRow/Flagship
@onready var _durability_bar: Control = $BottomPanel/Margin/VBox/StatsRow/DurabilityBar
@onready var _durability_fill: ColorRect = \
	$BottomPanel/Margin/VBox/StatsRow/DurabilityBar/Fill
@onready var _durability: Label = $BottomPanel/Margin/VBox/StatsRow/Durability
@onready var _crew: Label = $BottomPanel/Margin/VBox/StatsRow/Crew
@onready var _cannons: Label = $BottomPanel/Margin/VBox/StatsRow/Cannons
@onready var _reload: Label = $BottomPanel/Margin/VBox/StatsRow/Reload
@onready var _target_label: Label = $BottomPanel/Margin/VBox/StatsRow/Target
@onready var _actions: HBoxContainer = $BottomPanel/Margin/VBox/Actions
@onready var _log_labels: Array = [
	$BottomPanel/Margin/VBox/Log/Line0,
	$BottomPanel/Margin/VBox/Log/Line1,
	$BottomPanel/Margin/VBox/Log/Line2,
]
@onready var _after_action: Control = $AfterAction
@onready var _after_title: Label = $AfterAction/Center/Panel/Margin/Body/Title
@onready var _after_lines: VBoxContainer = $AfterAction/Center/Panel/Margin/Body/Lines
@onready var _after_continue: Button = \
	$AfterAction/Center/Panel/Margin/Body/Footer/Continue
@onready var _menu: Control = $BattleMenu
@onready var _menu_title: Label = $BattleMenu/Center/Panel/Margin/Body/Title
@onready var _menu_retreat: Button = $BattleMenu/Center/Panel/Margin/Body/Retreat
@onready var _menu_surrender: Button = $BattleMenu/Center/Panel/Margin/Body/Surrender
@onready var _menu_back: Button = $BattleMenu/Center/Panel/Margin/Body/Back
@onready var _confirm: Control = $ConfirmDialog

## `action_id` → Button, filled in `_ready`.
var _action_buttons: Dictionary = {}
## The 160 cell tiles, row-major.
var _tiles: Array = []
## Unit key (`side:index`) → token widgets `{root, square, label, frame}`.
var _token_widgets: Dictionary = {}


func _ready() -> void:
	_style()
	_build_grid()
	_build_action_buttons()
	_after_action.visible = false
	_menu.visible = false
	_after_continue.pressed.connect(_continue_after_battle)
	_menu_retreat.pressed.connect(func() -> void: _request_end("retreat"))
	_menu_surrender.pressed.connect(func() -> void: _request_end("surrender"))
	_menu_back.pressed.connect(close_menu)
	if _confirm.has_signal("confirmed"):
		_confirm.confirmed.connect(_on_end_confirmed)
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.game_over.connect(_on_game_over)
	# Production queues the encounter on `GameState` and then routes here
	# (§4.11.11.3); a test calls [method open_battle] directly instead.
	var pending = GameState.get("pending_encounter")
	if pending is Dictionary and not (pending as Dictionary).is_empty():
		open_battle(pending)
		begin()
	else:
		_bind()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.game_over.is_connected(_on_game_over):
		EventBus.game_over.disconnect(_on_game_over)


# --- Public API (docs/60-* §4.11.11.3, §4.12.4; task D tests) --------------

## Sets the battle up from `encounter` (§4.11.11 shape) and **does not run**
## anything: deployment, round 1 and the AI's first turn are all still ahead,
## which is what makes "set up" assertable (§4.11.2).
##
## `encounter` = `{id, kind, nation_id, position{x,y}|contact{x,y}, ships[]}`;
## `day` is optional (defaults to `GameState.day`). Passing `{}` consumes
## `GameState.pending_encounter` instead. The pending descriptor is cleared here
## exactly once, so a re-entrant contact cannot open two battles (§4.11.11.3).
func open_battle(in_encounter: Dictionary = {}) -> void:
	var source: Dictionary = in_encounter
	if source.is_empty():
		var pending = GameState.get("pending_encounter")
		if pending is Dictionary:
			source = pending
	_clear_pending_encounter()
	if source.is_empty():
		push_warning("BattleScreen.open_battle: no encounter; nothing to set up")
		return

	encounter = source.duplicate(true)
	last_outcome = {}
	_finished = false
	game_over_raised = false
	_target = {}
	_selection = {}
	_log_entries = []
	_presented = 0
	_last_actor = ""
	_gameover_reason = ""
	_warning_counts = {}

	# §4.11.2: deployment is the engine's, from the player's live fleet and the
	# encounter's seeded enemy composition.
	#
	# §4.11.1 pins `contact` as **the player's world tile at contact**, so the
	# descriptor's `contact` (written by S3, `world_map._encounter_for`) wins over
	# the marker's own `position`: the §4.11.1 seed and the §4.11.10 "fleet is
	# placed on the contact tile" return both use it, and using the marker tile
	# would reproduce neither. `position` stays the fallback for a hand-built
	# encounter that carries only the marker shape.
	var contact := BattleSimLib.to_cell(encounter.get("contact",
		encounter.get("position", Vector2i.ZERO)))
	var kind := str(encounter.get("kind", "pirate"))
	var day := int(encounter.get("day", GameState.day))
	var enemy_ships = encounter.get("ships", [])
	enemy_ships = (enemy_ships as Array).duplicate(true) \
		if enemy_ships is Array else []
	# §4.11.1: one stream per battle — composition first, then the sim, so a
	# duel continues the same sequence.
	var rng := RandomNumberGenerator.new()
	rng.seed = BattleSimLib.battle_seed_formula(
		day, contact, int(GameState.gold), _player_fleet().size())
	if (enemy_ships as Array).is_empty():
		enemy_ships = AiFleetLib.compose_enemy(kind, day, rng)

	sim = BattleSimLib.new({
		"player_ships": _player_fleet(),
		"enemy_ships": enemy_ships,
		"enemy_kind": kind,
		"enemy_nation": str(encounter.get("nation_id", "")),
		"day": day,
		"gold": int(GameState.gold),
		"contact": contact,
		"weather": _weather_name(),
		"encounter_id": str(encounter.get("id", "")),
		"rng": rng,
	})
	sim.start()
	_seed_cursor()
	_bind()
	battle_opened.emit(encounter)


## Production entry point: with the battle set up, play any AI turn that comes
## before the player's first ship in the initiative order (§4.11.4 — a faster
## enemy can legitimately act first). [method open_battle] deliberately leaves
## this to the caller so a test can inspect the §4.11.2 deployment untouched.
func begin() -> void:
	_pump_enemy_turns()
	_bind()


## Drives the battle to the end with no human input: the player side uses
## [method _player_auto_action] (the same actions the buttons offer, same
## legality order) and the enemy side uses [AiFleet.decide] (§4.9 verbatim)
## through [method run_ai_turn]. Returns [member last_outcome] (`{}` if the
## round cap was hit first).
##
## This is the headless driver of §4.11.11.3 and the "full battle through the UI
## API" path of the acceptance suite: it calls the handlers the buttons, clicks
## and keys call, never the engine directly.
func run_to_completion(max_rounds: int = DEFAULT_MAX_ROUNDS) -> Dictionary:
	if sim == null:
		open_battle()
	if sim == null:
		return {}
	if not sim.is_over():
		sim.start()
	var guard := 0
	var limit := maxi(max_rounds, 1) * maxi(sim.units().size(), 1) * 4 + 10
	while not sim.is_over() and sim.round_number() <= max_rounds:
		guard += 1
		if guard > limit:
			push_warning("BattleScreen.run_to_completion: step guard tripped")
			break
		var unit: Dictionary = sim.current_unit()
		if unit.is_empty():
			sim.end_turn()
			continue
		var before := _turn_marker()
		if str(unit.get("side", "")) == BattleSimLib.SIDE_ENEMY:
			run_ai_turn()
		else:
			_player_auto_action(unit)
		if not sim.is_over() and _turn_marker() == before:
			# Nothing advanced the cursor (cannot happen for a legal turn, but a
			# stuck loop would hang a suite): force the turn over.
			sim.end_turn()
		_bind()
	if sim.is_over():
		_finish_battle()
	return last_outcome


## The player ship that may act right now ({} while the AI acts or after the
## battle). Only the acting ship is selectable: the engine owns the turn order
## (§4.3, §4.12.1 `is_acting`).
func selected_unit() -> Dictionary:
	if sim == null or sim.is_over():
		return {}
	var acting: Dictionary = sim.current_unit()
	if acting.is_empty() or str(acting.get("side", "")) != BattleSimLib.SIDE_PLAYER:
		return {}
	return acting


## Selects `unit` as the ship the UI acts for. Succeeds only for the acting
## player ship (a living, player-side, currently-acting unit); anything else is
## ignored with `false`.
func select_unit(unit: Dictionary) -> bool:
	if not (unit is Dictionary) or unit.is_empty() or sim == null:
		return false
	if str(unit.get("side", "")) != BattleSimLib.SIDE_PLAYER:
		return false
	if not bool(unit.get("alive", false)) or not sim.is_acting(unit):
		return false
	_selection = unit
	_cursor = sim.unit_cell(unit)
	_cursor_visible = true
	_target = {}
	_bind()
	return true


## The action button for `name` (`cannon|ram|board|hold|retreat|surrender`),
## null for an unknown id.
func action_button(name: String) -> Button:
	var button = _action_buttons.get(name, null)
	return button as Button


## The battle-menu button for `name` (`retreat|surrender|back`).
func menu_button(name: String) -> Button:
	match name:
		"retreat":
			return _menu_retreat
		"surrender":
			return _menu_surrender
		"back":
			return _menu_back
	return null


## The shared confirm dialog (`battle.retreat.confirm` / `.surrender.confirm`).
func confirm_dialog() -> Control:
	return _confirm


## The cells currently outlined as reachable for the selected ship —
## `BattleSim.legal_moves()` verbatim (§4.3, §4.11.4).
func highlighted_cells() -> Array:
	if _overlay == null:
		return []
	return _overlay.call("reachable_cells")


## The enemy cells highlighted as targets (cannon/board/ram range).
func target_cells() -> Array:
	if _overlay == null:
		return []
	return _overlay.call("target_cells")


## The last 3 rendered log lines, oldest first (localised).
func log_lines() -> Array[String]:
	var out: Array[String] = []
	for label in _log_labels:
		out.append((label as Label).text)
	return out


## The whole structured engine log so far (`{kind, key, values}`, §4.11.4) —
## the acceptance suite asserts the §4.9 rules on it.
func engine_log() -> Array:
	return [] if sim == null else sim.log_lines()


## The presentation records behind [method log_lines] (tests/localisation).
func log_entries() -> Array:
	return _log_entries.duplicate(true)


func is_over() -> bool:
	return sim == null or sim.is_over()


## True while a modal this screen owns is up (after-action, battle menu or the
## confirm dialog): input is ignored then (§6 "modals consume all input").
func has_modal() -> bool:
	return _after_action.visible or _menu.visible \
		or (_confirm != null and _confirm.visible)


## Opens the `Esc` battle menu (Retreat / Surrender / back, §4.3).
func open_menu() -> void:
	if _finished or (sim != null and sim.is_over()):
		return
	_menu.visible = true
	if not _menu.is_in_group("modal_overlay"):
		_menu.add_to_group("modal_overlay")
	_bind_menu()
	_menu_back.grab_focus()


func close_menu() -> void:
	_menu.visible = false
	_menu.remove_from_group("modal_overlay")


func menu_open() -> bool:
	return _menu.visible


## The after-action dialog root (tests read its lines).
func after_action_dialog() -> Control:
	return _after_action


## Every player-facing line the after-action dialog currently shows, title and
## button included — the "no raw `<key>` in either locale" check walks this.
func after_action_lines() -> Array[String]:
	var out: Array[String] = []
	out.append(_after_title.text)
	for child in _after_lines.get_children():
		if child is Label:
			out.append((child as Label).text)
	out.append(_after_continue.text)
	return out


## True once [member last_outcome] holds a finished §4.11.9 block.
func battle_finished() -> bool:
	return not last_outcome.is_empty()


## How many times the §4.12.3 guard warned about `tag` (a module path). Tests
## assert "exactly one warning per absent module" through this.
func warning_count(tag: String) -> int:
	return int(_warning_counts.get(tag, 0))


## Every guard warning tag issued since [method open_battle], with its count.
func warnings() -> Dictionary:
	return _warning_counts.duplicate()


# --- Engine actions (what the buttons, clicks and keys call) ---------------

## Runs one §4.9 AI turn for the acting enemy unit, then advances the engine.
## Returns the decision that was applied (`{action, target, cell}`) so tests can
## assert which §4.9 priority rule fired.
func run_ai_turn() -> Dictionary:
	var unit: Dictionary = sim.current_unit() if sim != null else {}
	if unit.is_empty() or str(unit.get("side", "")) != BattleSimLib.SIDE_ENEMY:
		return {}
	var decision: Dictionary = AiFleetLib.decide(sim, unit)
	_apply_engine_decision(unit, decision)
	if sim.is_over():
		_finish_battle()
	else:
		sim.end_turn()
	_bind()
	return decision


## Moves the selected ship to `cell` — the click-to-move path (§4.3). Illegal,
## occupied or over-budget cells change nothing and return false. A move never
## ends the turn (§4.3 "up to MOVE followed by at most 1 action").
func move_selected(cell: Vector2i) -> bool:
	var unit := selected_unit()
	if unit.is_empty() or not sim.is_acting(unit):
		return false
	if not sim.move_to(unit, cell):
		return false
	_cursor = cell
	_cursor_visible = true
	_bind()
	return true


## Performs `action` against `target` (default: the resolved target) and
## settles the turn. Returns the engine result (`{ok: false}` when illegal).
func perform_action(action: String, target: Dictionary = {}) -> Dictionary:
	var unit := selected_unit()
	if unit.is_empty() or not sim.is_acting(unit):
		return {"ok": false}
	if action == "hold":
		var held: Dictionary = sim.hold(unit)
		_settle_turn(bool(held.get("ok", false)))
		return held
	if target.is_empty():
		target = _resolve_target(unit, action)
	if target.is_empty():
		return {"ok": false}
	var result: Dictionary = {}
	match action:
		"cannon":
			result = sim.cannon(unit, target)
		"ram":
			result = sim.ram(unit, target)
		"board":
			result = _board(unit, target)
		_:
			return {"ok": false}
	_settle_turn(bool(result.get("ok", false)))
	return result


## §4.10 `battle.retreat`: ends the battle through the engine, then runs the
## §4.12.4 sequence.
func retreat_battle() -> void:
	if sim == null or sim.is_over():
		return
	sim.retreat()
	_finish_battle()


## §4.11.7 player-offered surrender: same shape as [method retreat_battle].
func surrender_battle() -> void:
	if sim == null or sim.is_over():
		return
	sim.offer_surrender()
	_finish_battle()


## Simulates a left click on `cell` (the acceptance suite and the mouse handler
## share this one path, so "click a legal cell" and "click an enemy" exercise
## the real handlers, not test-only shortcuts).
func click_cell(cell: Vector2i) -> void:
	if not BattleSimLib.in_grid(cell):
		return
	_on_grid_cell(cell)


## After an action: end the battle, else advance the turn and let the AI play
## every intervening turn (§4.3). `spent` is the engine's "the action happened".
func _settle_turn(spent: bool) -> void:
	if sim.is_over():
		_finish_battle()
		return
	if spent:
		sim.end_turn()
	_pump_enemy_turns()
	_bind()


## Plays AI turns until a player ship may act or the battle ends (§4.3 turn
## order — a faster enemy legitimately acts before the player's ships).
func _pump_enemy_turns() -> void:
	if sim == null:
		return
	var guard := 0
	while not sim.is_over():
		guard += 1
		if guard > MAX_CHAINED_TURNS:
			push_warning("BattleScreen: AI turn chain guard tripped")
			return
		var unit: Dictionary = sim.current_unit()
		if unit.is_empty() or str(unit.get("side", "")) != BattleSimLib.SIDE_ENEMY:
			return
		run_ai_turn()


# --- Boarding through the guarded `Duel` seam (§4.12.3) --------------------

## §4.6 boarding: `Duel.start(...)` when task C's module exists, else the
## engine's own `BattleSim.resolve_duel` path — logged once, and **never** a
## second copy of the duel formula (§4.12.1.2).
##
## `BattleSim.board()` stays the data path in both cases: it is the single
## implementation of §4.11.7's capture/loss consequences and it draws the rounds
## from the battle's one §4.11.1 stream. The rounds S11 presents are replayed
## from a **clone** of that stream, so the modal shows exactly the rolls the
## engine applied without consuming the battle RNG twice.
func _board(unit: Dictionary, target: Dictionary) -> Dictionary:
	var defender: Dictionary = target \
		if str(target.get("side", "")) == BattleSimLib.SIDE_ENEMY else unit
	var player_base := BattleSimLib.player_duel_base()
	var defender_base := BattleSimLib.defender_duel_base(
		int(defender.get("ship", {}).get("crew", 0)),
		int(defender.get("captain_rating", 0)))
	var state_before := int(sim.rng.state)
	var result: Dictionary = sim.board(unit, target)
	var duel_module = ResourceLoader.load(DUEL_PATH) \
		if ResourceLoader.exists(DUEL_PATH) else null
	if duel_module == null or not duel_module.has_method("start"):
		_warn_once("duel", "BattleScreen: %s missing (task C); boarding resolves "
			% DUEL_PATH + "through BattleSim.resolve_duel")
		return result
	# Presentation only: replay the applied rolls from the pre-board snapshot.
	var clone := RandomNumberGenerator.new()
	clone.state = state_before
	duel_module.call("start", {
		"player_base": player_base,
		"defender_base": defender_base,
		"seed": int(sim.seed_value()),
		"rng": clone,
		"ship_name": _ship_name(unit.get("ship", {})),
		"attacker_name": _ship_name(unit.get("ship", {})),
		"defender_name": _ship_name(defender.get("ship", {})),
	})
	return result


# --- Grid rendering (docs/80-* §4.7.1, §4.8) -------------------------------

func _style() -> void:
	_background.color = PaletteLib.PANEL_BG
	_top_bar.color = PaletteLib.PANEL_BG
	_bottom_panel.color = PaletteLib.PANEL_BG
	_sea.color = PaletteLib.SEA
	for label in [_title, _day, _round, _flagship_label, _durability, _crew,
			_cannons, _target_label]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_esc_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_weather.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_reload.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_title.add_theme_font_size_override("font_size", 20)
	_after_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_after_title.add_theme_font_size_override("font_size", 24)
	_menu_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_menu_title.add_theme_font_size_override("font_size", 24)
	for label in _log_labels:
		(label as Label).add_theme_color_override("font_color", PaletteLib.TEXT)
	_after_continue.custom_minimum_size.y = float(PaletteLib.BUTTON_H)
	($AfterAction/Center/Panel as PanelContainer).add_theme_stylebox_override(
		"panel", _panel_style())
	($BattleMenu/Center/Panel as PanelContainer).add_theme_stylebox_override(
		"panel", _panel_style())
	# §4.2/§4.7.1: the grid is 768×480, centred between the bars.
	_grid_area.position = GRID_ORIGIN
	_grid_area.size = GRID_PX


## Builds the 160 palette tiles once (§4.7.1 "grid rendering, palette
## placeholders"; §4.8 "no textures").
func _build_grid() -> void:
	_tiles.clear()
	for y in GRID_H:
		for x in GRID_W:
			var tile := ColorRect.new()
			tile.name = "Cell_%d_%d" % [x, y]
			tile.color = PaletteLib.SEA
			tile.position = Vector2(x * TILE_PX, y * TILE_PX)
			tile.size = Vector2(TILE_PX, TILE_PX)
			tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_cells.add_child(tile)
			_tiles.append(tile)


func _build_action_buttons() -> void:
	for action_id in ACTION_IDS:
		var button := Button.new()
		button.name = "Action_%s" % action_id
		button.custom_minimum_size = Vector2(120, float(PaletteLib.BUTTON_H))
		button.focus_mode = Control.FOCUS_ALL
		button.set_meta("action_id", action_id)
		# A lambda cannot capture a loop variable by reference, so the id comes
		# from the button's own metadata.
		button.pressed.connect(func() -> void:
			_on_action_pressed(str(button.get_meta("action_id"))))
		_actions.add_child(button)
		_action_buttons[action_id] = button


## One 24×24 lettered token per ship (§4.8). Widgets are created once per unit
## key and repositioned on every repaint; a dead hull's token is hidden rather
## than deleted, so a token keeps its identity across a sinking.
func _sync_tokens() -> void:
	if sim == null:
		return
	var seen: Dictionary = {}
	for unit in sim.units():
		var key := _unit_key(unit)
		seen[key] = true
		if not _token_widgets.has(key):
			_token_widgets[key] = _make_token(key)
		_place_token(_token_widgets[key], unit)
	for key in _token_widgets.keys():
		if not seen.has(key):
			(_token_widgets[key]["root"] as Control).queue_free()
			_token_widgets.erase(key)


func _make_token(key: String) -> Dictionary:
	var root := Control.new()
	root.name = "Token_%s" % key.replace(":", "_")
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.size = Vector2(TOKEN_PX, TOKEN_PX)
	var square := ColorRect.new()
	square.name = "Square"
	square.color = PaletteLib.TEXT
	square.size = Vector2(TOKEN_PX, TOKEN_PX)
	square.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(square)
	var frame := Panel.new()
	frame.name = "Frame"
	frame.size = Vector2(TOKEN_PX, TOKEN_PX)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", _frame_style(Color.BLACK))
	root.add_child(frame)
	var label := Label.new()
	label.name = "Letter"
	label.text = TOKEN_PLAYER
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(TOKEN_PX, TOKEN_PX)
	label.add_theme_font_size_override("font_size", 12)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label)
	_tokens.add_child(root)
	return {"root": root, "square": square, "label": label, "frame": frame}


## §4.8 token colours: player `TEXT` with a black outline, pirate `BAD`, navy
## the owning nation's `Nation.color`.
func _place_token(widgets: Dictionary, unit: Dictionary) -> void:
	var root: Control = widgets["root"]
	if not bool(unit.get("alive", false)):
		root.visible = false
		return
	root.visible = true
	var cell: Vector2i = sim.unit_cell(unit)
	root.position = Vector2(cell * TILE_PX) + Vector2(
		(TILE_PX - TOKEN_PX) * 0.5, (TILE_PX - TOKEN_PX) * 0.5)
	var square: ColorRect = widgets["square"]
	var label: Label = widgets["label"]
	var frame: Panel = widgets["frame"]
	if str(unit.get("side", "")) == BattleSimLib.SIDE_PLAYER:
		square.color = PaletteLib.TEXT
		# The black outline is the §4.8 player marker; the flagship's is ACCENT
		# so the ship the bottom panel describes is identifiable on the grid.
		var flagship_unit: Dictionary = sim.flagship_unit()
		var flagship: bool = not flagship_unit.is_empty() \
			and _unit_key(flagship_unit) == _unit_key(unit)
		frame.add_theme_stylebox_override("panel",
			_frame_style(PaletteLib.ACCENT if flagship else Color.BLACK))
		label.add_theme_color_override("font_color", Color.BLACK)
		label.text = TOKEN_FLAGSHIP if flagship else TOKEN_PLAYER
	else:
		square.color = PaletteLib.BAD if _enemy_is_pirate() else _enemy_nation_color()
		frame.add_theme_stylebox_override("panel", _frame_style(PaletteLib.TEXT))
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
		label.text = TOKEN_ENEMY


# --- Repaint ---------------------------------------------------------------

## Re-reads the engine and repaints every derived widget. Never mutates state.
func _bind() -> void:
	if sim == null:
		return
	_title.text = _t("battle.title")
	_day.text = I18n.fmt("world.day", {"day": int(sim.day)})
	_round.text = _t("battle.round", {"round": int(sim.round_number())})
	_weather.text = I18n.t_key("world.weather.%s" % _weather_name())
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	_sync_tokens()
	_bind_stats()
	_bind_log_records()
	_bind_actions()
	_bind_log()
	_bind_highlights()


func _bind_stats() -> void:
	var unit := selected_unit()
	if unit.is_empty() and not sim.is_over():
		unit = sim.flagship_unit()
	if unit.is_empty():
		_flagship_label.text = "-"
		_durability.text = ""
		_crew.text = ""
		_cannons.text = ""
		_reload.text = ""
		_durability_fill.size = Vector2.ZERO
		_target_label.text = _t("battle.target.none")
		return
	var ship: Dictionary = unit.get("ship", {})
	_flagship_label.text = "%s · %s" % [
		I18n.t_key("fleet.flagship"), _ship_name(ship),
	]
	var max_durability := int(sim.effective_max_durability(ship))
	var durability := int(ship.get("durability", 0))
	_durability.text = I18n.fmt("shipyard.durability", {"durability": durability})
	_crew.text = I18n.fmt("world.crew", {
		"crew": int(ship.get("crew", 0)),
		"max": _ship_crew_max(ship),
	})
	_cannons.text = "%s %d" % [I18n.t_key("shipyard.cannons"),
		int(ship.get("cannons", 0))]
	var ratio := 0.0 if max_durability <= 0 \
		else clampf(float(durability) / float(max_durability), 0.0, 1.0)
	var bar_width := _durability_bar.custom_minimum_size.x
	_durability_fill.size = Vector2(bar_width * ratio,
		_durability_bar.custom_minimum_size.y)
	_durability_fill.color = _bar_color(ratio)
	# §4.4 reload: loaded iff `round >= reload_until_round` (§4.11.4).
	var loaded := int(sim.round_number()) >= int(unit.get("reload_until_round", 1))
	_reload.text = "" if loaded else _t("battle.reload")
	_target_label.text = _target_text(unit)


func _bind_actions() -> void:
	_disabled_reasons.clear()
	var unit := selected_unit()
	var target: Dictionary = _resolve_target(unit, "") if not unit.is_empty() else {}
	for action_id in ACTION_IDS:
		var button: Button = _action_buttons[action_id]
		button.text = _t("battle.action.%s" % action_id)
		var reason := _block_reason(action_id, unit, target)
		button.disabled = not reason.is_empty()
		button.tooltip_text = "" if reason.is_empty() else _reason_text(reason)
		if not reason.is_empty():
			_disabled_reasons[action_id] = reason
	_bind_menu()


## The presentation log: one record per engine entry this screen knows how to
## render, plus one `battle.log.turn` line per turn. Kinds outside the §4.12.5
## inventory are skipped rather than inventing keys.
func _bind_log_records() -> void:
	var entries: Array = sim.log_lines()
	while _presented < entries.size():
		_present(_log_entries, entries[_presented])
		_presented += 1
	var actor: Dictionary = sim.current_unit()
	if actor.is_empty() or sim.is_over():
		return
	var actor_key := _unit_key(actor)
	if actor_key == _last_actor:
		return
	_last_actor = actor_key
	_log_entries.append({
		"key": "battle.log.turn",
		"values": {"ship": _ship_name(actor.get("ship", {}))},
	})


## Translates one engine entry into zero or more presentation records
## (`{key, values}`) using only §4.12.5 keys.
func _present(out: Array, entry) -> void:
	if not (entry is Dictionary):
		return
	var values = (entry as Dictionary).get("values", {})
	if not (values is Dictionary):
		values = {}
	var payload: Dictionary = values
	var attacker := _log_unit_name(payload, "unit")
	var target := _log_unit_name(payload, "target")
	match str((entry as Dictionary).get("kind", "")):
		"cannon":
			out.append({"key": "battle.log.cannon", "values": {
				"attacker": attacker, "target": target,
				"damage": int(payload.get("damage", 0)),
			}})
		"ram":
			out.append({"key": "battle.log.ram", "values": {
				"attacker": attacker, "target": target,
				"self_damage": int(payload.get("attacker_damage",
					payload.get("self_damage", 0))),
			}})
		"board":
			# §4.12.5 has one boarding line (`battle.duel.start`); the per-round
			# detail belongs to the S11 modal (task C).
			out.append({"key": "battle.duel.start", "values": {}})
		"retreat":
			out.append({"key": "battle.result.retreat", "values": {}})
		"surrender":
			out.append({"key": "battle.result.surrender", "values": {}})
		_:
			# `hold` and `surrender_enemy` have no §4.12.5 line; the after-action
			# dialog reports captures/surrenders. Nothing is invented here.
			pass
	# A sunk hull gets its own documented line after the damaging one (§4.7).
	if bool(payload.get("sunk", false)) and not target.is_empty():
		out.append({"key": "battle.log.sunk", "values": {"ship": target}})


func _bind_log() -> void:
	var tail: Array = _log_entries.slice(
		maxi(_log_entries.size() - LOG_LINES, 0))
	for index in _log_labels.size():
		var label: Label = _log_labels[index]
		if index >= tail.size():
			label.text = ""
			continue
		var record: Dictionary = tail[index]
		label.text = _t(str(record.get("key", "")), record.get("values", {}))


func _bind_highlights() -> void:
	var reachable: Array = []
	var targets: Array = []
	var unit := selected_unit()
	if not unit.is_empty():
		reachable = sim.legal_moves(unit)
		for enemy in sim.living_units(BattleSimLib.SIDE_ENEMY):
			if sim.can_cannon(unit, enemy) or sim.can_board(unit, enemy) \
					or sim.can_ram(unit, enemy):
				targets.append(sim.unit_cell(enemy))
	_overlay.call("set_state", reachable, targets, _cursor, _cursor_visible)


func _bind_menu() -> void:
	if _menu_title == null:
		return
	_menu_title.text = _t("battle.title")
	_menu_retreat.text = _t("battle.action.retreat")
	_menu_surrender.text = _t("battle.action.surrender")
	_menu_back.text = I18n.t_key("ui.back")


## Applies one `AiFleet.decide()` dict through the engine's own decision seam
## when it exists (exact parity with `BattleSim.run_to_completion`, including
## §4.9 rule 1's AI surrender), else through the same mapping spelled out here.
func _apply_engine_decision(unit: Dictionary, decision: Dictionary) -> void:
	var action := str(decision.get("action", "hold"))
	var target = decision.get("target", {})
	if not (target is Dictionary):
		target = {}
	if sim.has_method("_apply_decision"):
		if action == "board" and not (target as Dictionary).is_empty():
			# Route the AI's boarding through the same guarded Duel seam.
			_board(unit, target)
			return
		sim.call("_apply_decision", unit, decision)
		return
	match action:
		"cannon":
			sim.cannon(unit, target)
		"ram":
			sim.ram(unit, target)
		"board":
			_board(unit, target)
		"move":
			sim.move_to(unit,
				BattleSimLib.to_cell(decision.get("cell", BattleSimLib.NO_CELL)))
		_:
			sim.hold(unit)


# --- Input (docs/80-* §4.3 S10 rows) --------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if sim == null:
		return
	# Modals consume everything first (§6).
	if _after_action.visible:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("back"):
			get_viewport().set_input_as_handled()
			_continue_after_battle()
		return
	if _confirm != null and _confirm.visible:
		return
	if _menu.visible:
		if event.is_action_pressed("back"):
			get_viewport().set_input_as_handled()
			close_menu()
		return
	if sim.is_over():
		return
	# Any input while the AI is acting pumps its turns, so play never stalls on
	# an enemy that opened the round (§4.3).
	_pump_enemy_turns()
	if sim.is_over():
		return

	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			var local := mouse.position - _grid_area.global_position
			_on_grid_cell(Vector2i(
				int(floor(local.x / float(TILE_PX))),
				int(floor(local.y / float(TILE_PX)))))
		return

	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		open_menu()
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		var key := event as InputEventKey
		match key.physical_keycode:
			KEY_TAB:
				get_viewport().set_input_as_handled()
				_cycle_own_ships(-1 if key.shift_pressed else 1)
			KEY_ENTER, KEY_KP_ENTER:
				get_viewport().set_input_as_handled()
				_confirm_cursor()
			KEY_UP:
				get_viewport().set_input_as_handled()
				_move_cursor(Vector2i(0, -1))
			KEY_DOWN:
				get_viewport().set_input_as_handled()
				_move_cursor(Vector2i(0, 1))
			KEY_LEFT:
				get_viewport().set_input_as_handled()
				_move_cursor(Vector2i(-1, 0))
			KEY_RIGHT:
				get_viewport().set_input_as_handled()
				_move_cursor(Vector2i(1, 0))


## One click (or `Enter`) on `cell`: a highlighted tile moves; an enemy token in
## range is the default action (§4.3, §4.7.1); anything else parks the cursor.
func _on_grid_cell(cell: Vector2i) -> void:
	if not BattleSimLib.in_grid(cell):
		return
	_cursor = cell
	_cursor_visible = true
	var unit := selected_unit()
	if unit.is_empty():
		_bind()
		return
	for enemy in sim.living_units(BattleSimLib.SIDE_ENEMY):
		if sim.unit_cell(enemy) == cell:
			_target = enemy
			_default_action(unit, enemy)
			return
	if sim.legal_moves(unit).has(cell):
		move_selected(cell)
		return
	_bind()


## §4.7.1 "default action against it (cannon if loaded, else ram/board)".
func _default_action(unit: Dictionary, enemy: Dictionary) -> void:
	if sim.can_cannon(unit, enemy):
		perform_action("cannon", enemy)
	elif sim.can_ram(unit, enemy):
		perform_action("ram", enemy)
	elif sim.can_board(unit, enemy):
		perform_action("board", enemy)
	else:
		_bind()


## `Tab`: cycles the player's ships (§4.3). The cursor jumps to the next living
## own hull, which is also how the player inspects a ship that is not acting.
func _cycle_own_ships(direction: int) -> void:
	var own: Array = sim.living_units(BattleSimLib.SIDE_PLAYER)
	if own.is_empty():
		return
	var index := 0
	var current := selected_unit()
	if not current.is_empty():
		for i in own.size():
			if int((own[i] as Dictionary).get("index", -1)) \
					== int(current.get("index", -2)):
				index = i
	index = posmod(index + direction, own.size())
	var next: Dictionary = own[index]
	_cursor = sim.unit_cell(next)
	_cursor_visible = true
	if sim.is_acting(next):
		_selection = next
	_target = {}
	_bind()


## Arrows move the targeting cursor (§4.3); `Enter` confirms it.
func _move_cursor(delta: Vector2i) -> void:
	if _cursor == BattleSimLib.NO_CELL:
		var unit := selected_unit()
		_cursor = sim.unit_cell(unit) if not unit.is_empty() else Vector2i.ZERO
		_cursor_visible = true
		_bind()
		return
	var next := _cursor + delta
	if not BattleSimLib.in_grid(next):
		return
	_cursor = next
	_cursor_visible = true
	_bind()


## `Enter`: one move onto the highlighted tile, else the enemy under the
## cursor's default action, else hold (so `Enter` always does something).
func _confirm_cursor() -> void:
	var unit := selected_unit()
	if unit.is_empty():
		return
	if sim.legal_moves(unit).has(_cursor):
		move_selected(_cursor)
		return
	for enemy in sim.living_units(BattleSimLib.SIDE_ENEMY):
		if sim.unit_cell(enemy) == _cursor:
			_target = enemy
			_default_action(unit, enemy)
			return
	perform_action("hold")


# --- Buttons ---------------------------------------------------------------

func _on_action_pressed(action_id: String) -> void:
	if has_modal() or sim == null or sim.is_over():
		return
	# A synthetic `pressed.emit()` must not act on a disabled button either.
	if _disabled_reasons.has(action_id):
		return
	match action_id:
		"hold":
			perform_action("hold")
		"retreat":
			_request_end("retreat")
		"surrender":
			_request_end("surrender")
		_:
			var unit := selected_unit()
			if unit.is_empty():
				return
			perform_action(action_id, _resolve_target(unit, action_id))


## The two battle-ending actions confirm first (`battle.retreat.confirm` /
## `battle.surrender.confirm`, §4.12.5, §4.7).
func _request_end(what: String) -> void:
	if sim == null or sim.is_over() or _finished:
		return
	close_menu()
	if _confirm == null:
		_apply_end(what)
		return
	_confirm.set_meta("end_action", what)
	_confirm.open_text(_t("battle.%s.confirm" % what))


func _on_end_confirmed() -> void:
	_apply_end(str(_confirm.get_meta("end_action", "")))


func _apply_end(what: String) -> void:
	_target = {}
	if what == "retreat":
		retreat_battle()
	elif what == "surrender":
		surrender_battle()


# --- Target resolution & legality reasons ---------------------------------

## The enemy the next action applies to: the explicit selection while it is
## still legal, else the best in-range target, else `{}` (§4.7.1 "the action
## buttons act on the selected target").
func _resolve_target(unit: Dictionary, action: String) -> Dictionary:
	if unit.is_empty() or sim == null:
		return {}
	if not _target.is_empty() and bool(_target.get("alive", false)) \
			and (action.is_empty() or _is_legal(action, unit, _target)):
		return _target
	var enemies: Array = sim.living_units(BattleSimLib.SIDE_ENEMY)
	if action.is_empty():
		for enemy in enemies:
			if sim.can_cannon(unit, enemy):
				return enemy
		for enemy in enemies:
			if sim.can_board(unit, enemy):
				return enemy
		return {}
	for enemy in enemies:
		if _is_legal(action, unit, enemy):
			return enemy
	return {}


func _is_legal(action: String, unit: Dictionary, target: Dictionary) -> bool:
	match action:
		"cannon":
			return sim.can_cannon(unit, target)
		"ram":
			return sim.can_ram(unit, target)
		"board":
			return sim.can_board(unit, target)
	return false


## "" when `action_id` is legal, else the `ui_strings` key of the tooltip that
## explains the refusal (§4.7.1 "disabled with a tooltip reason"). Only keys
## from the §4.12.5 inventory and the shared `ui.*` set are used: Phase 2 pins no
## "no cannons" reason key, so a gunless hull explains with `ui.not_available`
## rather than an invented string.
func _block_reason(action_id: String, unit: Dictionary, target: Dictionary) -> String:
	if sim == null or sim.is_over() or _finished:
		return "battle.target.none"
	if action_id == "retreat" or action_id == "surrender":
		return ""
	if unit.is_empty():
		return "battle.target.none"
	match action_id:
		"hold":
			return ""
		"cannon":
			if int(unit.get("ship", {}).get("cannons", 0)) < 1:
				return "battle.reason.no_cannons"
			if int(sim.round_number()) < int(unit.get("reload_until_round", 1)):
				return "battle.reload"
			if target.is_empty():
				return "battle.target.none"
			if not sim.can_cannon(unit, target):
				return "battle.reason.out_of_range"
			return ""
		"ram":
			if target.is_empty() or not sim.can_ram(unit, target):
				return "battle.target.none"
			return ""
		"board":
			if target.is_empty() or not sim.can_board(unit, target):
				return "battle.target.none"
			return ""
	return "battle.target.none"


## The target row: `battle.target.none`, or the enemy's hull name + range.
func _target_text(unit: Dictionary) -> String:
	var target := _resolve_target(unit, "")
	if target.is_empty():
		return _t("battle.target.none")
	var distance := _distance(sim.unit_cell(unit), sim.unit_cell(target))
	return "%s · %d" % [_ship_name(target.get("ship", {})), distance]


# --- Battle end (docs/60-* §4.12.4, five steps in order) -------------------

## Runs §4.12.4 exactly once per battle:
##   1. `BattleSim.outcome()` is the raw block;
##   2. `BattleResult.apply(raw, enemy_units, GameState.fleet)`;
##   3. `BattleRewards.apply(outcome)`;
##   4. `NpcFleets.remove(id)` — or, on a retreat,
##      `NpcFleets.set_pursuit_cooldown(id, day + 1)` (§4.12.4 step 4;
##      the Phase-2 spawn immunity is retired, docs/60-* §4.11.11.1);
##   5. `GameState.set_world_tile(contact)`; `EventBus.battle_finished`;
##      after-action dialog; route to S3 unless a `gameover.*` fired.
func _finish_battle() -> void:
	if _finished or sim == null or not sim.is_over():
		return
	_finished = true
	_bind_log_records()
	_bind()
	# 1. Raw §4.12.2 block.
	last_outcome = (sim.outcome() as Dictionary).duplicate(true)

	# 2. Fleet effects (task C) — guarded.
	# §4.12.3 pins the second argument as `BattleSim.units()` (the engine's unit
	# dicts, used to tag each capture with the enemy fleet index it came from);
	# handing it bare ship instances made `captured_units[].index` always −1.
	var result_module = _guarded_apply(BATTLE_RESULT_PATH)
	if result_module != null:
		var applied = result_module.call("apply", last_outcome,
			sim.units(), GameState.fleet)
		if applied is Dictionary:
			last_outcome = (applied as Dictionary).duplicate(true)

	# 3. Gold / XP / reputation (task G) — guarded.
	var rewards_module = _guarded_apply(BATTLE_REWARDS_PATH)
	if rewards_module != null:
		var applied = rewards_module.call("apply", last_outcome)
		if applied is Dictionary and not (applied as Dictionary).is_empty():
			last_outcome["rewards"] = (applied as Dictionary).duplicate(true)

	# 4. Fleet-ecology bookkeeping (task J) — guarded.
	var fleets_module = _guarded_module(NPC_FLEETS_PATH)
	if fleets_module != null:
		_cleanup_encounter(fleets_module)

	# 4b. Phase 3: win counter, bounty-target quests, patrol kills, the
	# hunter-surrendered bounty, and a tournament bout's bracket step.
	var phase3_module = ResourceLoader.load(PHASE3_HOOKS_PATH) \
		if ResourceLoader.exists(PHASE3_HOOKS_PATH) else null
	if phase3_module != null:
		var before_result := str(last_outcome.get("result", ""))
		var marker_snapshot := last_outcome.duplicate(true)
		if phase3_module.has_method("on_battle_finished"):
			last_outcome["phase3"] = phase3_module.call(
				"on_battle_finished", marker_snapshot)
		if str(marker_snapshot.get("encounter_id", "")).begins_with("tournament_"):
			if phase3_module.has_method("on_tournament_bout"):
				last_outcome["tournament"] = phase3_module.call(
					"on_tournament_bout", marker_snapshot)
		# `before_result` is read only to keep the snapshot's result explicit.
		if before_result != str(marker_snapshot.get("result", "")):
			push_error("BattleScreen: the Phase-3 hooks mutated the outcome result")

	# 5. Position, signal, dialog, route.
	GameState.set_world_tile(
		BattleSimLib.to_cell(last_outcome.get("contact", sim.contact)))
	_emit_finished()
	battle_closed.emit(last_outcome)
	# The dialog is modal, so the S3 route is its `Continue` edge (§4.7.1
	# "a dialog_box-style modal … then returns to S3"). Routing here would
	# destroy this scene one frame after the dialog appeared.
	_show_after_action()


## The §4.12.3 guarded loader for an `apply()` module (tasks C/G): the script
## when it exists **and** has `apply`, else null with exactly one warning (the
## `SaveSystem.apply_fleet_guard` convention).
func _guarded_apply(path: String) -> Variant:
	var module = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if module == null or not module.has_method("apply"):
		_warn_once(path, "BattleScreen: %s is missing; that battle-end step is "
			% path + "skipped (docs/60-* §4.12.4)")
		return null
	return module


## The same guard for a module with its own instance API (task J's
## `NpcFleets`, whose `remove`/`set_pursuit_cooldown` mutate `GameState` and
## are not static). Returns an instance, or null with one warning.
func _guarded_module(path: String) -> Variant:
	var module = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	if module == null or not module.can_instantiate():
		_warn_once(path, "BattleScreen: %s is missing; fleet cleanup "
			% path + "skipped (docs/60-* §4.12.4)")
		return null
	var instance = module.new()
	if instance == null:
		_warn_once(path, "BattleScreen: %s cannot be instantiated; "
			% path + "fleet cleanup skipped")
		return null
	return instance


## §4.12.4 step 4: drop the fleet, or cool it down after a retreat.
##
## §4.10/§4.11.11.1 exception: a `retreat` does **not** resolve the battle, so
## the fleet stays and takes the +1 day pursuit cooldown instead of being
## despawned (the inclusive reading, docs/60-* §4.11.11.1). The Phase-2
## per-kind spawn immunity is retired with the marker system — the trickle
## refills the ecology (docs/60-* §4.11.11.1). Both writes are idempotent
## (they mutate `GameState.npc_fleets` by id), so S3 applying the same
## cooldown again is harmless.
func _cleanup_encounter(fleets_module) -> void:
	var encounter_id := str(last_outcome.get("encounter_id", ""))
	var retreated := str(last_outcome.get("result", "")) == BattleSimLib.RESULT_RETREAT
	if not encounter_id.is_empty() and fleets_module.has_method("remove"):
		if retreated and fleets_module.has_method("set_pursuit_cooldown"):
			# The +1 day is the module's own pin (`PURSUIT_COOLDOWN_DAYS`,
			# §4.10/§4.11.11.1); read it instead of restating the number.
			var cooldown_days: int = int(fleets_module.get("PURSUIT_COOLDOWN_DAYS"))
			fleets_module.call("set_pursuit_cooldown", encounter_id,
				int(GameState.day) + cooldown_days)
		else:
			fleets_module.call("remove", encounter_id)


## `EventBus.battle_finished(outcome)` — exactly once per battle (docs/90-* §5.1,
## docs/60-* §4.12.4 step 5). Guarded because the signal is declared by the
## Phase-2 autoload change this branch may be cut before (the same
## `has_method`/`has_signal` convention as the §4.12.3 module guards).
func _emit_finished() -> void:
	if not EventBus.has_signal("battle_finished"):
		_warn_once("battle_finished", "BattleScreen: EventBus.battle_finished is "
			+ "missing (Phase-2 autoload change); outcome not broadcast")
		return
	EventBus.battle_finished.emit(last_outcome)


## §4.12.4 step 5: the `battle.after.*` dialog, rebuilt **only** from the
## outcome block — no number is computed here (§4.11.10 values arrive
## pre-computed by the engine / tasks C and G).
func _show_after_action() -> void:
	_after_title.text = _t("battle.after.title")
	for child in _after_lines.get_children():
		_after_lines.remove_child(child)
		child.queue_free()
	for text in _after_action_texts():
		var label := Label.new()
		label.text = text
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = 600
		_after_lines.add_child(label)
	_after_continue.text = I18n.t_key("ui.ok")
	_after_action.visible = true
	if not _after_action.is_in_group("modal_overlay"):
		_after_action.add_to_group("modal_overlay")
	_after_continue.grab_focus()


## The §4.12.5 `battle.after.*` lines in wireframe order: loot gold, XP,
## captures, scuttles, overflow, losses, preceded by the `battle.result.*` line
## and followed by the reputation deltas §4.7.1 asks for.
func _after_action_texts() -> Array[String]:
	var out: Array[String] = []
	out.append(_result_text(str(last_outcome.get("result", ""))))
	out.append(_t("battle.after.loot", {
		"gold": int(last_outcome.get("salvage_gold", 0)),
	}))
	out.append(_t("battle.after.xp", {
		"xp": int(last_outcome.get("xp", 0)),
	}))
	for name in _outcome_ship_names("captured_ships", "captured_enemy"):
		out.append(_t("battle.after.captured", {"ship": name}))
	for name in _outcome_ship_names("scuttled_ships", "scuttled_enemy"):
		out.append(_t("battle.after.scuttled", {"ship": name}))
	var overflow := int(last_outcome.get("cargo_overflow_lost", 0))
	if overflow > 0:
		out.append(_t("battle.after.overflow", {"count": overflow}))
	for name in _outcome_ship_names("lost_ships", "lost_player"):
		out.append(_t("battle.after.lost", {"ship": name}))
	out.append_array(_reputation_texts())
	return out


## `battle.result.victory` / `.defeat` / `.retreat` / `.surrender` for the four
## §4.11.9 groups (`defeat_sunk` and `defeat_captured` share the one defeat key
## of the §4.12.5 inventory).
func _result_text(result: String) -> String:
	match result:
		BattleSimLib.RESULT_VICTORY:
			return _t("battle.result.victory")
		BattleSimLib.RESULT_RETREAT:
			return _t("battle.result.retreat")
		BattleSimLib.RESULT_SURRENDER:
			return _t("battle.result.surrender")
		_:
			return _t("battle.result.defeat")


## §4.7.1 "loot gold, captured ships, XP and reputation deltas", through the
## `battle.after.rep` key of the §4.12.5 inventory.
func _reputation_texts() -> Array[String]:
	var out: Array[String] = []
	var deltas = last_outcome.get("rep_deltas", {})
	if not (deltas is Dictionary):
		return out
	var nation_ids: Array = (deltas as Dictionary).keys()
	nation_ids.sort_custom(func(a, b) -> bool: return str(a) < str(b))
	for nation_id in nation_ids:
		var delta := int((deltas as Dictionary).get(nation_id, 0))
		if delta == 0:
			continue
		var nation: Dictionary = DataLoader.get_nation(str(nation_id))
		var nation_name := I18n.t(nation.get("name", {})) \
			if not nation.is_empty() else str(nation_id)
		out.append(_t("battle.after.rep", {
			"nation": nation_name, "delta": "%+d" % delta,
		}))
	return out


## Ship names from an outcome list. `ids_key` (task C's `captured_ships` /
## `scuttled_ships` / `lost_ships`, hull ids) wins over the §4.12.2 instance
## list when present, so a post-merge screen reports what the seams applied.
func _outcome_ship_names(ids_key: String, instances_key: String) -> Array[String]:
	var out: Array[String] = []
	var ids = last_outcome.get(ids_key, [])
	if ids is Array and not (ids as Array).is_empty():
		for ship_type_id in ids:
			out.append(_ship_type_name(str(ship_type_id)))
		return out
	for ship in _outcome_ships(instances_key):
		out.append(_ship_name(ship))
	return out


func _outcome_ships(key: String) -> Array:
	var value = last_outcome.get(key, [])
	if not (value is Array):
		return []
	var out: Array = []
	for ship in value:
		if ship is Dictionary:
			out.append(ship)
	return out


func _continue_after_battle() -> void:
	if not _after_action.visible:
		return
	_after_action.visible = false
	_after_action.remove_from_group("modal_overlay")
	if game_over_raised:
		# §4.12.4 step 5: *not* S3 — S9 is the terminal screen for this run.
		_show_game_over()
		return
	_route_to_world()


func _route_to_world() -> void:
	if not route_to_world:
		return
	var target := return_scene()
	if not ResourceLoader.exists(target):
		push_warning("BattleScreen: %s missing; staying on S10" % target)
		return
	if not is_active_scene():
		return
	GameState.change_scene(target)


## The scene the after-action dialog's `Continue` opens. A tournament bout goes
## back to the host palace, which starts the next bout (`70-*` §4.9.7: "3
## successive battles", no repairs between rounds); every other battle returns
## to S3 (§4.12.4 step 5).
func return_scene() -> String:
	if is_tournament_battle():
		return PALACE_SCENE
	return WORLD_SCENE


## `true` for a tournament bout: `Phase3Hooks` tagged the encounter id.
func is_tournament_battle() -> bool:
	var id := str(last_outcome.get("encounter_id", ""))
	if id.is_empty() and not encounter.is_empty():
		id = str(encounter.get("id", ""))
	return id.begins_with("tournament_")


## The scene this battle would route to now: S3 (or S13 for a tournament bout),
## or "" when routing is off, the after-action dialog is still up (its
## `Continue` is the edge) or a `gameover.*` fired (S9 owns the screen). The
## `world_route_target()` seam — tests read this instead of letting the router
## swap their scene root.
func world_route_target() -> String:
	if game_over_raised or _after_action.visible:
		return ""
	var target := return_scene()
	if not route_to_world or not ResourceLoader.exists(target):
		return ""
	return target


## True when this node is the tree's current scene (production S10) rather than
## a child instanced by a test — the `world_map.is_active_scene` convention.
func is_active_scene() -> bool:
	var tree := get_tree()
	return tree != null and tree.current_scene == self


## `BattleResult` (task C) emits `gameover.*` (sunk / captured) during §4.12.4
## step 2; S9 then owns the screen, so this scene must not route to S3 underneath
## it (§4.12.4 step 5).
func _on_game_over(reason: String) -> void:
	if str(reason).is_empty():
		return
	game_over_raised = true
	_gameover_reason = str(reason)


## Instances S9 over S10 (the `world_map._on_game_over` pattern: the shared
## `gameover_screen.tscn` in a top layer, no state of its own). S9 routes to the
## title on any key.
func _show_game_over() -> void:
	if _gameover != null:
		return
	if not ResourceLoader.exists(GAMEOVER_SCENE):
		push_warning("BattleScreen: %s missing; staying on S10" % GAMEOVER_SCENE)
		return
	var layer := get_node_or_null("GameOverLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "GameOverLayer"
		# Above this screen's own canvas so S9 dims everything (§4.8, §6).
		layer.layer = 3
		add_child(layer)
	_gameover = (ResourceLoader.load(GAMEOVER_SCENE) as PackedScene).instantiate()
	_gameover.name = "GameOverScreen"
	layer.add_child(_gameover)
	_gameover.open_reason(_gameover_reason)


## True once S9 is on screen (tests observe the terminal state).
func game_over_open() -> bool:
	return _gameover != null and _gameover.has_method("is_open") \
		and _gameover.is_open()


# --- Localisation helpers --------------------------------------------------

## `battle.*`/`encounter.*` text. Every one of these keys is a
## `data/ui_strings.json` entry (`docs/60-COMBAT.md` §4.12.5), resolved through
## the shared formatter (§4.4 `{name}` placeholders). This screen never carries
## its own copy of a player-facing string (AGENTS.md i18n hard rule); a missing
## key is a data bug and renders `I18n.t_key()`'s `<key>` marker, which the data
## validator prevents in shipped data.
func _t(key: String, values: Dictionary = {}) -> String:
	return I18n.fmt(key, values)


## `ui.reason` prefix + a localised reason word (§4.7 "disabled with a tooltip
## reason"). A key absent from `ui_strings` degrades to `ui.not_available`
## rather than printing `<key>`.
func _reason_text(key: String) -> String:
	var reason_key := key if DataLoader.ui_strings.has(key) else "ui.not_available"
	return I18n.fmt("ui.reason", {"reason": I18n.t_key(reason_key)})


# --- Small helpers ---------------------------------------------------------

## The display name behind a log entry's `unit`/`target` index (§4.11.4 values
## carry indices; the line needs a hull name).
func _log_unit_name(values: Dictionary, name: String) -> String:
	var side_key := "side" if name == "unit" else "target_side"
	if not values.has(side_key) or sim == null:
		return "-"
	var side := str(values[side_key])
	var index := int(values.get(name, -1))
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -2)) == index:
			return _ship_name(unit.get("ship", {}))
	return "-"


func _ship_name(ship: Dictionary) -> String:
	if not (ship is Dictionary):
		return "-"
	return _ship_type_name(str(ship.get("ship_type_id", "")))


func _ship_type_name(ship_type_id: String) -> String:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	if ship_type.is_empty():
		return ship_type_id if not ship_type_id.is_empty() else "-"
	return I18n.t(ship_type.get("name", {}))


func _ship_crew_max(ship: Dictionary) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(
		str(ship.get("ship_type_id", "")))
	return int(ship_type.get("crew_max", 0))


func _bar_color(ratio: float) -> Color:
	if ratio > BAR_GOOD_ABOVE:
		return PaletteLib.GOOD
	if ratio > BAR_WARN_ABOVE:
		return PaletteLib.WARN
	return PaletteLib.BAD


func _frame_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.draw_center = false
	style.border_color = color
	style.set_border_width_all(2)
	return style


func _unit_key(unit: Dictionary) -> String:
	return "%s:%d" % [str(unit.get("side", "")), int(unit.get("index", -1))]


## Identifies the current turn slot (`round:unit`) so the driver can tell
## whether a call advanced the engine.
func _turn_marker() -> String:
	if sim == null:
		return ""
	var unit: Dictionary = sim.current_unit()
	return "%d:%s" % [int(sim.round_number()), _unit_key(unit)]


func _player_fleet() -> Array:
	return GameState.fleet if GameState.fleet is Array else []


## §4.12.1 config `weather` (docs/20-* §4.7 value); "calm" with no world state.
func _weather_name() -> String:
	var weather = GameState.world.get("weather", "calm")
	if weather is String and not (weather as String).is_empty():
		return weather
	return "calm"


## Encounter kind: stable for the whole battle (the engine copies it into the
## outcome block and never changes it).
func _enemy_is_pirate() -> bool:
	return str(encounter.get("kind", "pirate")) != "navy"


func _enemy_nation_color() -> Color:
	var nation: Dictionary = DataLoader.get_nation(
		str(encounter.get("nation_id", "")))
	if nation.is_empty():
		return PaletteLib.BAD
	return PaletteLib.nation_color(str(nation.get("color", "#b3341f")))


func _seed_cursor() -> void:
	var unit := selected_unit()
	if unit.is_empty() and sim != null:
		var own: Array = sim.living_units(BattleSimLib.SIDE_PLAYER)
		unit = own[0] if not own.is_empty() else {}
	_cursor = sim.unit_cell(unit) if sim != null and not unit.is_empty() \
		else BattleSimLib.NO_CELL
	_cursor_visible = not unit.is_empty()


## §4.11.11.3: cleared on battle start so a re-entrant contact cannot open two
## battles. `pending_encounter` is declared by the Phase-2 GameState change this
## branch may be cut before, so the write is guarded (docs/60-* §4.11.11.3).
func _clear_pending_encounter() -> void:
	if "pending_encounter" in GameState:
		GameState.set("pending_encounter", null)


func _warn_once(tag: String, message: String) -> void:
	_warning_counts[tag] = warning_count(tag) + 1
	if warning_count(tag) > 1:
		return
	push_warning(message)


func _on_locale_changed(_locale: String) -> void:
	_bind()
	if _after_action.visible:
		_show_after_action()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


# --- Player auto policy (the headless driver of run_to_completion) ---------

## One player turn using the **same** legality order the buttons use: fire,
## else board, else ram, else close in and act, else hold.
func _player_auto_action(unit: Dictionary) -> void:
	_target = {}
	if _act_best(unit):
		return
	var cell := _approach_cell(unit)
	if cell != BattleSimLib.NO_CELL and move_selected(cell):
		unit = selected_unit()
		if unit.is_empty() or _act_best(unit):
			return
	# Nothing to shoot, nothing to board: pass the turn.
	perform_action("hold")


## Performs the first legal action for `unit` (cannon → board → ram). Returns
## true when an action was taken (which settles the turn).
func _act_best(unit: Dictionary) -> bool:
	if unit.is_empty():
		return false
	var target := _resolve_target(unit, "")
	if target.is_empty():
		return false
	if sim.can_cannon(unit, target):
		return bool(perform_action("cannon", target).get("ok", false))
	if sim.can_board(unit, target):
		return bool(perform_action("board", target).get("ok", false))
	if sim.can_ram(unit, target):
		return bool(perform_action("ram", target).get("ok", false))
	return false


## The reachable tile that closes the Chebyshev distance to the nearest enemy
## (the same greedy rule the AI's rule 5 uses, §4.11.8).
func _approach_cell(unit: Dictionary) -> Vector2i:
	var enemies: Array = sim.living_units(BattleSimLib.SIDE_ENEMY)
	if enemies.is_empty():
		return BattleSimLib.NO_CELL
	var nearest: Dictionary = enemies[0]
	var best := _distance(sim.unit_cell(unit), sim.unit_cell(nearest))
	for enemy in enemies:
		var distance := _distance(sim.unit_cell(unit), sim.unit_cell(enemy))
		if distance < best:
			best = distance
			nearest = enemy
	var best_cell := BattleSimLib.NO_CELL
	var best_distance := best
	for cell in sim.legal_moves(unit):
		var distance := _distance(cell, sim.unit_cell(nearest))
		if distance < best_distance:
			best_distance = distance
			best_cell = cell
	return best_cell


func _distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
