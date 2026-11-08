extends Control
## Battle screen (S10) — the Phase-9 §4.7.1 rewrite
## (docs/80-UI-UX.md §4.3, §4.7.1, §4.8; docs/60-COMBAT.md §4.2–§4.7, §4.3a,
## §4.4a/§4.4b, §4.6a, §4.11.2, §4.11.4, §4.11.9, §4.11.10, §4.12.1–§4.12.5;
## docs/90-ARCHITECTURE.md §5.1, §7).
##
## What this scene *is*: a thin input + render shell around [BattleSim]. Every
## rule (deployment, the velocity model, damage, per-side reload, the duel
## formula, the outcome block and every reward number) lives in the engine;
## this file only
##   * draws the §4.7.1 wireframe — a 48×30 tile world at 32 px (1536×960)
##     under a free camera in a 1280×584 viewport, a 192×120 minimap
##     top-right, and the 96 px bottom bar (`‖vel‖` · heading8 · per-side
##     reload pips · wind · weather · the four-shot selector · `[fit]`);
##   * owns ALL camera math as pure static functions (§4.7.1): world↔screen,
##     clamp, cursor-anchored zoom, minimap mapping, edge scroll and the
##     4 px click/drag threshold;
##   * turns clicks / `Tab` / arrows / `Enter` / `1`–`4` / `Home` / `Esc`
##     into engine calls (§4.3 S10 rows): a click on a legal velocity vector
##     moves, a click on an enemy token is the default action, arrows cycle
##     the `legal_velocities` enumeration and `Enter` confirms;
##   * runs the §4.12.4 five-step battle-end sequence through the §4.12.3
##     guarded loaders, so no sibling task can block this one.
##
## **W4 (Phase 9).** Two §4.7.1 additions live here: the two side-morale bars
## in the top area (§4.8a values, `sim.side_morale` guarded — the pre-A seam
## renders 100/100) and the formation display (the minimap anchor line for a
## line formation + the `battle.formation.*` label), plus the §4.9b fleet
## dispatch — one `fleet_commander.gd` instance per battle, its orders
## re-emitted at each round start and fed to `AiFleet.decide(sim, unit,
## order)` as the third argument. Every sibling seam is guarded
## (`has_method` / `ResourceLoader.exists`, the §4.12.3 convention), so the
## pre-A / pre-B merge order leaves this screen running exactly as before.
##
## **Two drivers, one engine.** The player acts through the velocity picks,
## buttons and keys; the AI acts through [AiFleet.decide] applied by the
## engine's own decision seam. Both mutate the same [BattleSim], so a battle
## played by hand and one driven by [method run_to_completion] obey exactly
## the same rules — which is what makes the headless suite meaningful proof
## for the interactive screen.
##
## **Turn flow (§4.3, three phases).** Picking a velocity integrates it as a
## Bresenham sweep; movement happens exactly once per turn. The one action
## (cannon naming the side / ram / board / hold) ends the turn; this screen
## then advances the engine and plays every intervening AI turn, so the player
## always comes back to a ship they can command.
##
## **AI-turn speed switch (§4.7.1).** The `Esc` menu carries
## `battle.ai_speed.animate` / `battle.ai_speed.instant`: animate plays one
## stepped AI turn per frame, instant resolves the whole AI stretch in one
## call. The choice lives in scene state only — never a settings write.
##
## **Presentation is task-owned** (§4.7.1): every action appends one localised
## log line (last 3 visible), tokens stay placeholder shapes (§4.8), and an
## engine log kind outside the `battle.*` inventory is simply not rendered
## rather than inventing `ui_strings` keys.
##
## **Phase-10 W5-A.** The §4.7.17 presentation layer lives here and in
## `battle_fx_layer.gd` (the sequencer node): the battle sea is the shared
## animated-water builder (`WaterLayer`, §4.7.17 — one material with S3, the
## gate is `UiMotion.enabled` ONLY, never the battle animate switch), tokens
## render `hull_{type}_{owner}_{dir}` sprites from `heading8` (§4.8.6) with
## the letter badges kept as runtime overlays (§4.8.5) and the placeholder
## squares as the registry-miss fallback, the formation label gains the
## `formation_*` icon beside it, the after-action dialog carries the
## opposing flagship captain's bust, and the FX sequencer plays the pinned
## move → volley → flight → impact chain gated by the battle animate/instant
## switch (instant ⇒ every duration 0, no timers — the logs stay
## byte-identical; presentation only).
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
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## §4.7.1 (W6-A): the battle-intro captain preview reads the §4.12 card data
## (the NPC entry) for the one-line preview panel before round 1.
const CardLib := preload("res://scenes/ui/character_card.gd")
## The preview reads the canon captain card through the W4-A module.
const CaptainsLib := preload("res://scripts/world/captains.gd")
## Phase-10 W5-A: the §4.7.17 battle water rides the shared animated-sea
## builder (the ONE material S3 and S10 share); hull tokens resolve through
## the §4.9 icon registry; the after-action portrait runs on the W4-D
## composer (on main — direct use, the hail-modal contract).
const WaterLayerLib := preload("res://scripts/world/water_layer.gd")
const ArrowFieldLib := preload("res://scripts/world/arrow_field.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const UiMotionLib := preload("res://scripts/ui_motion.gd")
const PortraitComposerLib := preload("res://scripts/ui/portrait_composer.gd")

## ui_strings keys the preview needs that the shared table does not carry yet
## (the W5-C `FALLBACK_STRINGS` pattern — W6-D owns the residual merge).
const FALLBACK_STRINGS := {
	"battle.preview.duel": {"zh": "接舷 {amount}", "en": "Duel {amount}"},
	"battle.preview.cannon": {"zh": "炮击 {amount}", "en": "Cannon {amount}"},
}

const WORLD_SCENE := "res://scenes/world/world_map.tscn"
## Phase-9 S21 (§4.12.4 sandbox zero-write branch): a sandbox battle's
## after-action `Continue` returns to the S21 editor instead of S3.
const SANDBOX_SCENE := "res://scenes/combat/battle_sandbox.tscn"
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
## Phase-9 W4 (§4.9b/§4.12.3): the fleet-command module — lazily loaded and
## guarded exactly like `battle_result.gd`, so the pre-B merge order cannot
## block this screen (the AI then runs as before).
const FLEET_COMMANDER_PATH := "res://scripts/combat/fleet_commander.gd"
## S9 (a shared Phase-1 scene) is instanced over S10 when a `gameover.*` fires.
const GAMEOVER_SCENE := "res://scenes/ui_shared/gameover_screen.tscn"

# --- §4.7.1 world & camera geometry (all numbers pinned there) --------------

## The battle world: 48×30 tiles at 64 px (§4.2, the 2026-11-08
## battle-64 amendment — tokens render 1:1 64 on 64px tiles).
const TILE_PX := 64.0
const GRID_W := BattleSimLib.GRID_WIDTH
const GRID_H := BattleSimLib.GRID_HEIGHT
const WORLD_PX := Vector2(GRID_W * TILE_PX, GRID_H * TILE_PX)  # 3072×1920
## The camera viewport (the bottom bar takes the rest of 1920×1080, §4.7.1
## as amended by the 2026-11-08 resolution bump).
const VIEW_SIZE := Vector2(1920, 944)
const TOP_BAR_H := 40.0
const BOTTOM_BAR_H := 96.0
## The minimap: 192×120 at 4 px/cell, top-right (§4.7.1).
const MINIMAP_SIZE := Vector2(192, 120)
const MINIMAP_MARGIN := 8.0
const MINIMAP_SCALE := 0.0625  # 4 px/cell ÷ 64 px/cell
## Camera zoom bounds and the per-notch wheel step (§4.3/§4.7.1: 0.6×–1.5×,
## anchored at the cursor; the step follows the S17 chart's ×1.25 precedent).
const ZOOM_MIN := 0.45  # the [fit] view is height-bound 944/1920 = 0.4917
const ZOOM_MAX := 1.5
const ZOOM_STEP := 1.25
## Edge scroll: a 16 px screen band pans at 600 px/s (§4.3).
const EDGE_BAND_PX := 16.0
const EDGE_SPEED := 600.0
## "press-move ≤ 4 px is a click, more is a drag" (§4.3).
const CLICK_THRESHOLD_PX := 4.0

## §4.8: ship tokens are 24×24 squares with a letter.
const TOKEN_PX := 64
## W4 (§4.8a): the §4.7 gate value — a side at or below it fills the morale
## bar in the WARN tier. On the player side this is display ONLY ("low player
## morale is a HUD warning only", §4.8a — player ships never auto-strike);
## on the enemy side the same threshold merely telegraphs the §4.7/§4.8a
## strike gates. No behavior rides the color.
const MORALE_WARN_AT := 20
## W4 (§4.7.1): the formation anchor ray on the minimap, in cells (§4.9b's
## formation-slot scale; 6 cells = 24 px at the 4 px/cell minimap scale).
const FORMATION_ANCHOR_CELLS := 6
## The §4.8 line formations the anchor lines are pinned to (`line_ahead` /
## `column`); `screen`/`swarm` draw nothing and label nothing (W4 gate).
const LINE_FORMATIONS: Array[String] = ["line_ahead", "column"]
## §4.7.1: the log panel shows the last 3 lines.
const LOG_LINES := 3
## Default round cap of [method run_to_completion]. §4.11.11.3 quotes 30
## (Phase 2); DEVIATION (W3-C, 2026-11-03): re-pinned to 60 because the
## merged velocity model makes cap_eff 1 for a ship sailing into the wind
## (§4.3a) — a 43-tile into-the-wind crossing takes 42 rounds, which the
## Phase-2 bound cut off before contact (the pre-Phase-9 MP model closed the
## same distance in a handful of MP moves). This is a headless-driver hang
## guard, not a game rule: rounds/XP still come from the engine, and the
## engine's own §4.11.9 stall still ends dead battles at round ~9.
const DEFAULT_MAX_ROUNDS := 60
## Token letters (§4.8 "colored 24×24 squares with a letter"): the player's
## flagship, other player hulls, and every enemy hull.
const TOKEN_FLAGSHIP := "F"
const TOKEN_PLAYER := "P"
const TOKEN_ENEMY := "E"
## Safety net for the "play the AI until a player ship acts" loop.
const MAX_CHAINED_TURNS := 200

## Action ids in the bottom bar (`battle.action.<id>` labels them); retreat /
## surrender live in the `Esc` menu (§4.3, §4.7.1).
const ACTION_IDS: Array[String] = ["cannon", "ram", "board", "hold"]
## The §4.7.1 shot selector: the four §4.4b shot types in `1`–`4` order.
const SHOT_IDS: Array[String] = [
	BattleSimLib.ROUND_SHOT, BattleSimLib.CHAIN_SHOT,
	BattleSimLib.ARMOR_PIERCING_SHOT, BattleSimLib.GRAPE_SHOT,
]


# --- §4.8.6 hull-token mapping (Phase-10 W5-A; pure statics) ------------------

## The §4.8.6 dir id of a `heading8` bucket — the ArrowField table (bucket 0
## = east, increasing counterclockwise; screen y-down) pinned as the ONE
## source for every `hull_{type}_{owner}_{dir}` sprite id. "" out of range.
static func heading_dir_id(heading8: int) -> String:
	return ArrowFieldLib.dir_id_of_bucket(heading8)


## The sprite owner id of a battle side (the W5-A pin): the player fleet
## renders `player` (the white livery, matching W4-C's S3 pin); an enemy
## renders its fleet owner — the nation id when the encounter carries one
## (navy and the nation-roled fleets), `pirate` for the pirate kind,
## `neutral` otherwise. vel = 0 keeps the last heading per `60-*` §4.3a, so
## the dir always reads the unit's stored `heading8`.
static func owner_id_for_side(side: String, kind: String,
		nation_id: String) -> String:
	if side == BattleSimLib.SIDE_PLAYER:
		return "player"
	if not nation_id.is_empty():
		return nation_id
	if kind == "pirate":
		return "pirate"
	return "neutral"


## The §4.8 token sprite id — the north token scheme (80-* §4.8 2026-11-07):
## `hull_{ship_type_id}_{owner}` (the owner id resolves onto the shared
## `hull_{ship_type_id}` through the registry); facing is a runtime
## rotation (`heading_rotation_degrees`), not part of the id. "" when the
## hull has no type (the placeholder-square fallback then renders).
static func hull_sprite_id(ship_type_id: String, owner: String) -> String:
	if ship_type_id.is_empty() or owner.is_empty():
		return ""
	return "hull_%s_%s" % [ship_type_id, owner]


## The token rotation for a `heading8` bucket: the pinned top-down map
## (`ArrowField.rotation_degrees_of_dir`, clockwise degrees, screen
## y-down) on the §4.8.6 dir id (vel = 0 keeps the last heading per
## `60-*` §4.3a, so the facing always reads the unit's stored `heading8`).
static func heading_rotation_degrees(heading8: int) -> float:
	return ArrowFieldLib.rotation_degrees_of_dir(heading_dir_id(heading8))


## This battle's enemy owner id (the encounter's kind/nation are fixed at
## open time, so the value is constant for the whole battle).
func _enemy_owner_id() -> String:
	return owner_id_for_side(BattleSimLib.SIDE_ENEMY,
		str(encounter.get("kind", "pirate")),
		str(encounter.get("nation_id", "")))


## The §4.8.6 sprite id of a battle unit (the fx layer's snapshot mapper).
func _unit_sprite_id(unit: Dictionary) -> String:
	var ship: Dictionary = unit.get("ship", {}) \
		if unit.get("ship", {}) is Dictionary else {}
	var side := str(unit.get("side", ""))
	var owner := "player" if side == BattleSimLib.SIDE_PLAYER \
		else _enemy_owner_id()
	return hull_sprite_id(str(ship.get("ship_type_id", "")), owner)

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
## Cell the keyboard cursor sits on (`Enter` confirms a velocity pick).
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

# --- Camera & turn-presentation state (§4.7.1) ------------------------------

## The camera's world-pixel position and zoom (always clamped by
## [method clamp_cam] / the ZOOM bounds).
var _cam_pos := Vector2.ZERO
var _cam_zoom := 1.0
## Auto-center on the acting unit until the first manual pan; a manual pan
## pauses follow until the acting unit's NEXT turn (§4.7.1).
var _follow := true
## The acting unit key the camera/turn presentation last saw.
var _actor_key := ""
## True once this unit's one §4.3 movement is spent (presentation gate for
## the velocity vectors).
var _movement_spent := false
## The `legal_velocities()` enumeration for the acting unit and the keyboard
## index into it (arrows cycle, `Enter` confirms — §4.3).
var _legal_velocities: Array[Vector2i] = []
var _velocity_index := -1
## The §4.7.1 shot selector's picked shot; rides the cannon decision
## (`shot` key, §4.12.1.1).
var _selected_shot := BattleSimLib.ROUND_SHOT
## §4.7.1 AI-turn speed switch: false = 跟随动画 animate (one stepped AI turn
## per frame), true = 即时结算 instant (the whole AI stretch in one call).
## Scene state only — never persisted.
var _ai_instant := false
## Mouse press/drag bookkeeping (the §4.3 4 px click/drag threshold).
var _press_active := false
var _press_pos := Vector2.ZERO
var _press_button := MOUSE_BUTTON_LEFT
var _panning := false
## Overlay presentation caches (tests read them through highlighted_cells() /
## target_cells()).
var _endpoint_cells: Array = []
var _target_cells_cache: Array = []

# --- W4 (§4.7.1 additions / §4.9b dispatch) state ---------------------------

## The §4.9a profile row of this battle's enemy kind (`AiFleet.profile_for`,
## guarded), with the S21 `formation` override folded in when the fixture
## carries one. Built at open time; drives the §4.9b dispatch and the
## formation display.
var _enemy_profile: Dictionary = {}
## The lazily loaded `fleet_commander.gd` INSTANCE for this battle (the enemy
## side is one fleet). Null whenever the module is absent or malformed —
## pre-B the whole layer stays dormant and the AI runs exactly as today.
var _fleet_commander = null
## The commander's persistent state dict — passed by reference every round so
## B's hysteresis / anchor-succession memory lives across rounds (§4.9b).
var _fc_state: Dictionary = {}
## The round the current `_fc_orders` were issued for (the round-change
## detector; −1 = none issued yet).
var _fc_round := -1
## The current round's per-ship order five-tuples (§4.9b).
var _fc_orders: Array = []
## Cached probe of the loaded ai_fleet's decide arity (−1 unknown, 0 = the
## 2-arg form, 1 = the §4.12.1.1 W4-B `decide(sim, unit, order := {})`).
var _ai_fleet_order_args := -1
## The ai_fleet script as a DYNAMICALLY dispatched handle. The W4-B decide
## gains a third `order` parameter, which the analyzer refuses against the
## pre-B script at compile time — the sibling-module guard must probe the
## call shape at runtime, so every guarded ai_fleet interaction (decide
## arity, `profile_for`) goes through this Variant, not the typed preload.
var _ai_fleet_script: Variant = load("res://scripts/combat/ai_fleet.gd")

## W4 HUD handles (built in `_ready`): the §4.7.1 top-area morale bars and
## the formation label under the minimap.
var _morale_player_label: Label = null
var _morale_enemy_label: Label = null
var _morale_player_track: ColorRect = null
var _morale_enemy_track: ColorRect = null
var _morale_player_fill: ColorRect = null
var _morale_enemy_fill: ColorRect = null
var _formation_label: Label = null
## Phase-10 W5-A: the §4.8 formation icon beside the label (registry-miss ⇒
## hidden — the text-only label is the fallback rendering).
var _formation_icon: TextureRect = null
## Phase-10 W5-A: the §4.7.17 animated battle water (the shared
## `WaterLayer` builder; flat sea tiles under the S3-shared shader material).
var _water_layer: TileMapLayer = null

@onready var _background: Panel = $Background
@onready var _top_bar: ColorRect = $TopBar
@onready var _bottom_panel: ColorRect = $BottomPanel
@onready var _title: Label = $TopRow/Title
@onready var _day: Label = $TopRow/Day
@onready var _round: Label = $TopRow/Round
@onready var _weather: Label = $TopRow/Weather
@onready var _grid_view: Control = $GridView
@onready var _overlay: Control = $Overlay
## Phase-10 W5-A: the §4.7.17 FX sequencer node (scenes/combat/battle_fx_layer.gd;
## wired by the scene, like the grid overlay — no script preload cycle).
@onready var _fx: Control = $FxLayer
@onready var _minimap: Control = $Minimap
@onready var _speed: Label = \
	$BottomPanel/Margin/Columns/LeftCol/StatsRow/Speed
@onready var _heading: Label = \
	$BottomPanel/Margin/Columns/LeftCol/StatsRow/Heading
@onready var _reload_port: Label = \
	$BottomPanel/Margin/Columns/LeftCol/StatsRow/ReloadPort
@onready var _reload_starboard: Label = \
	$BottomPanel/Margin/Columns/LeftCol/StatsRow/ReloadStarboard
@onready var _wind: Label = $BottomPanel/Margin/Columns/LeftCol/StatsRow/Wind
@onready var _weather_label: Label = \
	$BottomPanel/Margin/Columns/LeftCol/StatsRow/WeatherLabel
@onready var _fit_button: Button = \
	$BottomPanel/Margin/Columns/LeftCol/StatsRow/Fit
@onready var _log_labels: Array = [
	$BottomPanel/Margin/Columns/LeftCol/Log/Line0,
	$BottomPanel/Margin/Columns/LeftCol/Log/Line1,
	$BottomPanel/Margin/Columns/LeftCol/Log/Line2,
]
@onready var _actions: HBoxContainer = \
	$BottomPanel/Margin/Columns/RightCol/ActionRow
@onready var _target_label: Label = $BottomPanel/Margin/Columns/RightCol/ActionRow/Target
@onready var _shot_row: HBoxContainer = \
	$BottomPanel/Margin/Columns/RightCol/ShotRow
@onready var _after_action: Control = $AfterAction
@onready var _after_title: Label = $AfterAction/Center/Panel/Margin/Body/Title
@onready var _after_lines: VBoxContainer = $AfterAction/Center/Panel/Margin/Body/Lines
@onready var _after_continue: Button = \
	$AfterAction/Center/Panel/Margin/Body/Footer/Continue
@onready var _menu: Control = $BattleMenu
@onready var _menu_title: Label = $BattleMenu/Center/Panel/Margin/Body/Title
@onready var _menu_retreat: Button = $BattleMenu/Center/Panel/Margin/Body/Retreat
@onready var _menu_surrender: Button = $BattleMenu/Center/Panel/Margin/Body/Surrender
@onready var _menu_ai_animate: Button = $BattleMenu/Center/Panel/Margin/Body/AiAnimate
@onready var _menu_ai_instant: Button = $BattleMenu/Center/Panel/Margin/Body/AiInstant
@onready var _menu_back: Button = $BattleMenu/Center/Panel/Margin/Body/Back
@onready var _confirm: Control = $ConfirmDialog

## `action_id` → Button, filled in `_ready`.
var _action_buttons: Dictionary = {}
## `shot_id` → Button.
var _shot_buttons: Dictionary = {}


## The §4.7.1 captain intro preview (Phase 8, W6-A): one line/panel with the
## opposing flagship captain's name / role / tier and the duel + cannon
## ratings (the §4.11.5 card formulas), rendered from the §4.12 card data —
## identified = full reveal, but the full card would block the battle, so the
## intro stays a preview panel dismissed with any input before round 1.
func _show_captain_preview(captain_id: String) -> void:
	_dismiss_captain_preview()
	var canon := CaptainsLib.captain(captain_id)
	if canon.is_empty():
		return
	var data := CardLib.card_data(CardLib.KIND_NPC, captain_id)
	# §4.9 sweep (W5-A): the preview rides the kit frame atom (theme panel
	# chrome + the 16px margin); the atom's header label is child 0 of the
	# frame's VBox (the W2-C pinned layout), re-titled here because the text
	# carries `{name}` values the atom's key-only resolver cannot format.
	var preview := UiKitLib.frame("battle.title")
	preview.name = "CaptainPreview"
	var header := ((preview.get_child(0) as VBoxContainer)
		.get_child(0) as Label)
	var box: VBoxContainer = preview.get_meta(UiKitLib.META_BODY)
	header.name = "Title"
	header.text = I18n.fmt("dossier.title", {"name": str(data.get("name", ""))})
	header.theme_type_variation = "Accent"
	var detail := Label.new()
	detail.name = "Detail"
	var role := str(data.get("role_key", "char.none"))
	var parts: Array[String] = [I18n.t_key(role)]
	parts.append("%s %d" % [I18n.t_key("captain.table.tier"),
		int(data.get("tier", 1))])
	parts.append(I18n.fmt("char.level", {"level": int(data.get("level", 1))}))
	detail.text = " · ".join(parts)
	box.add_child(detail)
	var ratings := Label.new()
	ratings.name = "Ratings"
	ratings.text = "%s · %s" % [
		_t("battle.preview.duel", {
			"amount": BattleSimLib.card_duel_rating(canon)}),
		_t("battle.preview.cannon", {
			"amount": BattleSimLib.card_cannon_rating(canon)}),
	]
	ratings.theme_type_variation = "Warn"
	box.add_child(ratings)
	preview.set_anchors_preset(Control.PRESET_CENTER_TOP)
	preview.position = Vector2((VIEW_SIZE.x - 320.0) * 0.5, TOP_BAR_H + 8.0)
	add_child(preview)
	_preview = preview


## Dismisses the preview (any input before the first round, §4.7.1).
var _preview: Control = null


func _dismiss_captain_preview() -> void:
	if _preview != null:
		_preview.queue_free()
		_preview = null


func _ready() -> void:
	_style()
	_build_morale_hud()
	_build_battle_water()
	# Phase-10 W5-A: the fx layer's snapshot mapper is this screen's §4.8.6
	# hull-sprite id builder (the sink ghost needs the sunk hull's sprite).
	if _fx != null and _fx.has_method("set_mapper"):
		_fx.set_mapper(_unit_sprite_id)
	# §4.7.1: the battle opens fitted to the whole 1536×960 world.
	_cam_zoom = fit_zoom()
	_cam_pos = clamp_cam(WORLD_PX * 0.5, _cam_zoom)
	_sync_world_node(_water_layer)
	_sync_world_node(_fx)
	_grid_view.draw.connect(_on_world_draw)
	# §4.8 64-canvas amendment: the hull tokens are 64×64 canvases drawn at
	# 0.5 scale (32 px on the 32 px battle tile) — nearest filtering keeps
	# the ÷2 downsample pixel-exact (each 2×2 texel block maps to one px).
	_grid_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_minimap.draw.connect(_on_minimap_draw)
	_minimap.gui_input.connect(_on_minimap_gui_input)
	_wire_action_buttons()
	_fit_button.pressed.connect(fit_view)
	for shot_id in SHOT_IDS:
		var button: Button = _shot_buttons.get(shot_id, null)
		if button == null:
			continue
		button.pressed.connect(func() -> void:
			select_shot(str(button.get_meta("shot_id"))))
	_after_action.visible = false
	_menu.visible = false
	_bind_menu()
	_after_continue.pressed.connect(_continue_after_battle)
	_menu_retreat.pressed.connect(func() -> void: _request_end("retreat"))
	_menu_surrender.pressed.connect(func() -> void: _request_end("surrender"))
	_menu_ai_animate.pressed.connect(func() -> void: set_ai_speed(false))
	_menu_ai_instant.pressed.connect(func() -> void: set_ai_speed(true))
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
		_queue_redraw()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.game_over.is_connected(_on_game_over):
		EventBus.game_over.disconnect(_on_game_over)


# --- Camera math (docs/80-* §4.7.1: "all camera math lives as pure
# --- functions in battle_screen.gd ... with fixed-value assertions"). -------

## World px → viewport px: the camera-centred projection. `zoom` 1.0 puts
## `cam_pos` at the viewport centre.
static func world_to_screen(world_pos: Vector2, cam_pos: Vector2,
		zoom: float) -> Vector2:
	return (world_pos - cam_pos) * zoom + VIEW_SIZE * 0.5


## The exact inverse of [method world_to_screen].
static func screen_to_world(screen_pos: Vector2, cam_pos: Vector2,
		zoom: float) -> Vector2:
	return (screen_pos - VIEW_SIZE * 0.5) / zoom + cam_pos


## Clamps the camera so the viewport-sized window stays inside the
## 1536×960 world; an axis whose whole world fits at `zoom` centres.
static func clamp_cam(cam_pos: Vector2, zoom: float) -> Vector2:
	var zoomed := maxf(zoom, 0.001)
	var half := VIEW_SIZE * 0.5 / zoomed
	var out := cam_pos
	if VIEW_SIZE.x / zoomed >= WORLD_PX.x:
		out.x = WORLD_PX.x * 0.5
	else:
		out.x = clampf(out.x, half.x, WORLD_PX.x - half.x)
	if VIEW_SIZE.y / zoomed >= WORLD_PX.y:
		out.y = WORLD_PX.y * 0.5
	else:
		out.y = clampf(out.y, half.y, WORLD_PX.y - half.y)
	return out


## Cursor-anchored wheel zoom (§4.3: 0.6×–1.5×, the world point under the
## cursor stays put). `wheel_delta` > 0 zooms in, < 0 out, ×[constant ZOOM_STEP]
## per notch. Returns `{zoom, cam}` with `cam` already clamped.
static func zoom_at(old_zoom: float, wheel_delta: float, anchor_screen: Vector2,
		cam_pos: Vector2) -> Dictionary:
	var new_zoom := old_zoom
	if wheel_delta > 0.0:
		new_zoom = old_zoom * ZOOM_STEP
	elif wheel_delta < 0.0:
		new_zoom = old_zoom / ZOOM_STEP
	new_zoom = clampf(new_zoom, ZOOM_MIN, ZOOM_MAX)
	var anchor_world := screen_to_world(anchor_screen, cam_pos, old_zoom)
	var new_cam := anchor_world - (anchor_screen - VIEW_SIZE * 0.5) / new_zoom
	return {"zoom": new_zoom, "cam": clamp_cam(new_cam, new_zoom)}


## The zoom that fits the whole 1536×960 world into the 1280×584 viewport
## (`Home` / `[fit]`, §4.3), clamped into the 0.6×–1.5× window.
static func fit_zoom() -> float:
	return clampf(
		minf(VIEW_SIZE.x / WORLD_PX.x, VIEW_SIZE.y / WORLD_PX.y),
		ZOOM_MIN, ZOOM_MAX)


## World px → minimap px (§4.7.1: the 192×120 minimap at 4 px/cell).
static func minimap_map(world_pos: Vector2) -> Vector2:
	return world_pos * MINIMAP_SCALE


## Edge scroll delta (§4.3: the cursor within 16 px of a screen edge pans at
## 600 px/s). Returns the UNCLAMPED camera delta for `delta_time` seconds —
## the caller clamps through [method clamp_cam].
static func edge_scroll(_cam_pos: Vector2, mouse_pos: Vector2,
		delta_time: float) -> Vector2:
	var out := Vector2.ZERO
	if mouse_pos.x < EDGE_BAND_PX:
		out.x = -EDGE_SPEED * delta_time
	elif mouse_pos.x > VIEW_SIZE.x - EDGE_BAND_PX:
		out.x = EDGE_SPEED * delta_time
	if mouse_pos.y < EDGE_BAND_PX:
		out.y = -EDGE_SPEED * delta_time
	elif mouse_pos.y > VIEW_SIZE.y - EDGE_BAND_PX:
		out.y = EDGE_SPEED * delta_time
	return out


## The §4.3 threshold: a press that moves ≤ 4 px is a click (select/act),
## more is a drag (pan).
static func is_click(from: Vector2, to: Vector2) -> bool:
	return (to - from).length() <= CLICK_THRESHOLD_PX


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
	# §4.7.1 presentation reset: fitted camera, follow on, no stale velocity
	# pick, round shot selected.
	_cam_zoom = fit_zoom()
	_cam_pos = clamp_cam(WORLD_PX * 0.5, _cam_zoom)
	_follow = true
	_actor_key = ""
	_movement_spent = false
	_velocity_index = -1
	_legal_velocities = []
	_selected_shot = BattleSimLib.ROUND_SHOT
	_cursor = BattleSimLib.NO_CELL
	_cursor_visible = false
	# Phase-10 W5-A: the §4.7.17 sequencer forgets the previous battle.
	if _fx != null and _fx.has_method("reset"):
		_fx.reset()

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
	# Phase-9 S21 (§4.12.4): the sandbox fixture carries BOTH fleets as
	# §4.11.11 instances (`player_ships` / `enemy_ships`) plus its own
	# `gold` / `weather`, so the live run is never read for them. A normal
	# battle keeps the exact Phase-2/5 sources (GameState.fleet + the seeded
	# `AiFleet.compose_enemy`).
	var sandbox := is_sandbox_battle()
	var player_ships := _player_fleet()
	var gold := int(GameState.gold)
	var weather := _weather_name()
	if sandbox:
		var fixture_player = encounter.get("player_ships", [])
		player_ships = (fixture_player as Array).duplicate(true) \
			if fixture_player is Array else []
		gold = int(encounter.get("gold", 0))
		var fixture_weather := str(encounter.get("weather", ""))
		weather = fixture_weather if not fixture_weather.is_empty() \
			else weather
	var enemy_ships = encounter.get("enemy_ships", encounter.get("ships", [])) \
		if sandbox else encounter.get("ships", [])
	enemy_ships = (enemy_ships as Array).duplicate(true) \
		if enemy_ships is Array else []
	# §4.11.1: one stream per battle — composition first, then the sim, so a
	# duel continues the same sequence. Sandbox: the fixture's optional `seed`
	# (§4.7.16 `seed_mode`) drives the stream — `fixed`/`random` carry a number
	# in the encounter, `auto` omits it and the §4.11.1 formula applies (gold
	# 0, no contact tile ⇒ the origin; the S21 fixture pins that contract).
	var rng := RandomNumberGenerator.new()
	if sandbox:
		if encounter.has("seed"):
			rng.seed = int(encounter["seed"])
		else:
			rng.seed = BattleSimLib.battle_seed_formula(
				day, contact, gold, player_ships.size())
	else:
		rng.seed = BattleSimLib.battle_seed_formula(
			day, contact, int(GameState.gold), _player_fleet().size())
	if (enemy_ships as Array).is_empty():
		enemy_ships = AiFleetLib.compose_enemy(kind, day, rng)

	var sim_config := {
		"player_ships": player_ships,
		"enemy_ships": enemy_ships,
		"enemy_kind": kind,
		"enemy_nation": str(encounter.get("nation_id", "")),
		"day": day,
		"gold": gold,
		"contact": contact,
		"weather": weather,
		"encounter_id": str(encounter.get("id", "")),
		"rng": rng,
	}
	# §4.2/§4.12.1 battle-condition pass-through: when the encounter carries
	# the locked `wind_dir` / `current` (written by the interactions funnel),
	# they ride the config verbatim; when absent the engine defaults them
	# (the world's locked wind / the decoded contact-tile current) — the
	# sandbox fixture deliberately omits both (the §4.7.16 forward-compat keys).
	if encounter.has("wind_dir"):
		sim_config["wind_dir"] = str(encounter["wind_dir"])
	var encounter_current = encounter.get("current", null)
	if encounter_current is Dictionary:
		sim_config["current"] = (encounter_current as Dictionary).duplicate(true)
	if sandbox:
		# §4.12.1 `player_stats` (Phase 9): the S21 editor's attribute /
		# equipment override rides the fixture encounter; absent → the sim
		# stays byte-identical to the normal path.
		var stats_override = encounter.get("player_stats", null)
		if stats_override is Dictionary \
				and not (stats_override as Dictionary).is_empty():
			sim_config["player_stats"] = stats_override
	# W4 (§4.8a/§4.12.1): the S21 fixture's initial side-morale keys ride the
	# config when present (the same pass-through shape as `wind_dir`). A sim
	# without the keys (pre-A) ignores unknown config, so this is harmless
	# both ways and never changes an outcome byte before A lands.
	for morale_key in ["player_morale", "enemy_morale"]:
		if encounter.has(morale_key):
			sim_config[morale_key] = int(encounter[morale_key])
	sim = BattleSimLib.new(sim_config)
	sim.start()
	_seed_cursor()
	# W4 (§4.9b): the battle's §4.9a profile row + the guarded one-per-battle
	# fleet commander (null pre-B — the layer stays dormant).
	_setup_fleet_commander()
	# §4.7.1 (W6-A): the captain intro preview — before the first round, when
	# the encounter names a canon captain (every Phase-8 fleet carries one).
	var captain_id := str(encounter.get("captain_id", ""))
	if not captain_id.is_empty():
		_show_captain_preview(captain_id)
	_bind()
	_queue_redraw()
	battle_opened.emit(encounter)


## Production entry point: with the battle set up, play any AI turn that comes
## before the player's first ship in the initiative order (§4.11.4 — a faster
## enemy can legitimately act first). [method open_battle] deliberately leaves
## this to the caller so a test can inspect the §4.11.2 deployment untouched.
func begin() -> void:
	_pump_enemy_turns()
	_bind()
	_queue_redraw()


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
			_end_turn_checked()
		_bind()
		if sim.is_over() and last_outcome.is_empty():
			_finish_battle()
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


## The action button for `name` (`cannon|ram|board|hold`), null otherwise.
func action_button(name: String) -> Button:
	var button = _action_buttons.get(name, null)
	return button as Button


## The battle-menu button for `name`
## (`retreat|surrender|ai_animate|ai_instant|back`).
func menu_button(name: String) -> Button:
	match name:
		"retreat":
			return _menu_retreat
		"surrender":
			return _menu_surrender
		"ai_animate":
			return _menu_ai_animate
		"ai_instant":
			return _menu_ai_instant
		"back":
			return _menu_back
	return null


## The shared confirm dialog (`battle.retreat.confirm` / `.surrender.confirm`).
func confirm_dialog() -> Control:
	return _confirm


## The cells the acting unit's velocity vectors land on (`pos + vel` for every
## `legal_velocities()` entry) — the §4.3 "click a legal vector" target set,
## empty once the turn's movement is spent.
func highlighted_cells() -> Array:
	return (_endpoint_cells as Array).duplicate()


## The enemy cells highlighted as targets (cannon/board/ram range).
func target_cells() -> Array:
	return (_target_cells_cache as Array).duplicate()


## The velocity the arrow keys currently point at (NO_CELL = none), from the
## `legal_velocities()` enumeration (§4.3 "arrows cycle the enumeration").
func cycled_velocity() -> Vector2i:
	if _velocity_index < 0 or _velocity_index >= _legal_velocities.size():
		return BattleSimLib.NO_CELL
	return _legal_velocities[_velocity_index]


## Applies `vel` to the acting player ship through the engine's
## `apply_velocity` (§4.12.1). False (state untouched) when illegal or the
## turn's movement is already spent.
func apply_selected_velocity(vel: Vector2i) -> bool:
	var unit := selected_unit()
	if unit.is_empty():
		return false
	return _apply_unit_velocity(unit, vel)


## Picks the §4.4b shot type the next cannon volley fires (`1`–`4` keys and
## the selector buttons, §4.7.1). Unknown ids are refused.
func select_shot(shot: String) -> bool:
	if not (shot in SHOT_IDS):
		return false
	_selected_shot = shot
	_bind_actions()
	return true


## The shot type the selector currently rides on the cannon decision.
func selected_shot() -> String:
	return _selected_shot


## §4.7.1 AI-turn speed switch: true = 即时结算 instant, false = 跟随动画
## animate. Scene state only — nothing is persisted.
func set_ai_speed(instant: bool) -> void:
	_ai_instant = instant
	_bind_menu()


func ai_instant_mode() -> bool:
	return _ai_instant


## The §4.7.17 effective instant gate for the FX sequencer: the battle's
## animate/instant switch **or** the global `UiMotion` gate (motion off ⇒
## every duration 0). The sea animation does NOT follow this — the water
## layer's gate is `UiMotion.enabled` alone (the W5-A ledger note).
func _fx_instant() -> bool:
	return _ai_instant or not UiMotionLib.enabled


# --- W4 accessors (tests / hosts) -------------------------------------------

## The §4.7.1 W4 morale label of `side` (`player`/`enemy`), null before
## `_ready` built the HUD.
func morale_label(side: String) -> Label:
	return _morale_player_label if side == BattleSimLib.SIDE_PLAYER \
		else _morale_enemy_label


## The §4.7.1 W4 morale bar fill of `side` (its width is value/100 of the
## track; the color is the §4.8 tier).
func morale_fill(side: String) -> ColorRect:
	return _morale_player_fill if side == BattleSimLib.SIDE_PLAYER \
		else _morale_enemy_fill


## The §4.7.1 W4 morale bar track of `side` (the full-width backdrop).
func morale_track(side: String) -> ColorRect:
	return _morale_player_track if side == BattleSimLib.SIDE_PLAYER \
		else _morale_enemy_track


## The morale value the bars currently show (the guarded §4.12.1 seam read).
func side_morale_shown(side: String) -> int:
	return _side_morale(side)


## The §4.7.1 W4 formation label (hidden unless the §4.9b layer is active on
## a line formation).
func formation_label() -> Label:
	return _formation_label


## The Phase-10 W5-A formation icon beside the label (`formation_*` via the
## §4.9 registry; hidden on a registry miss — the label-only fallback).
func formation_icon() -> TextureRect:
	return _formation_icon


## The §4.7.17 animated battle water layer (the shared `WaterLayer` build).
func water_layer() -> TileMapLayer:
	return _water_layer


## The §4.7.17 FX sequencer node (`battle_fx_layer.gd`).
func fx_layer() -> Control:
	return _fx


## True while this battle's §4.9b fleet layer is live (a loaded
## `fleet_commander.gd` instance exists).
func fleet_commander_active() -> bool:
	return _fleet_commander != null


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


## Opens the `Esc` battle menu (Retreat / Surrender / the AI-turn speed
## switch / back, §4.3).
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
## The walk is depth-first over `_after_lines` so the §4.9 portrait row's
## nested result line (W5-A) is collected in visual order like the rest.
func after_action_lines() -> Array[String]:
	var out: Array[String] = []
	out.append(_after_title.text)
	_collect_labels(_after_lines, out)
	out.append(_after_continue.text)
	return out


func _collect_labels(root: Node, out: Array[String]) -> void:
	for child in root.get_children():
		if child is Label:
			out.append((child as Label).text)
		_collect_labels(child, out)


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


## Fits the whole world into the viewport (`Home` / the `[fit]` button,
## §4.3): fit zoom, world centred. A manual camera command, so follow pauses
## until the acting unit's next turn.
func fit_view() -> void:
	_cam_zoom = fit_zoom()
	_cam_pos = clamp_cam(WORLD_PX * 0.5, _cam_zoom)
	_follow = false
	_queue_redraw()


## The camera state (tests / minimap frame math).
func camera_state() -> Dictionary:
	return {"cam": _cam_pos, "zoom": _cam_zoom, "follow": _follow}


# --- Engine actions (what the buttons, clicks and keys call) ---------------

## Runs one §4.9 AI turn for the acting enemy unit, then advances the engine.
## Returns the decision that was applied so tests can assert which priority
## rule fired. A decision outside the §4.12.1.1 dict shape (a sibling task's
## in-flight module) degrades to a hold through the engine's own decision
## seam — never a second copy of the turn rules.
##
## This is ALSO the §4.9b dispatch point: both AI paths (the animate/instant
## pumps of `_pump_enemy_turns` / `_process`, and `run_to_completion`'s AI
## branch) funnel through this method, so the round-start fleet dispatch of
## [method _ensure_fleet_orders] fires exactly once per round, at the first
## AI turn of that round.
func run_ai_turn() -> Dictionary:
	var unit: Dictionary = sim.current_unit() if sim != null else {}
	if unit.is_empty() or str(unit.get("side", "")) != BattleSimLib.SIDE_ENEMY:
		return {}
	_ensure_fleet_orders()
	var decision = _ai_decide(unit)
	if not (decision is Dictionary):
		decision = {}
	_apply_engine_decision(unit, decision)
	if sim.is_over():
		_finish_battle()
	else:
		_end_turn_checked()
	_bind()
	# The W4 minimap anchor line + formation label track the fleet layer, so
	# the AI stretch repaints too (queue_redraw coalesces within a frame).
	_queue_redraw()
	return decision


# --- §4.9b fleet dispatch (W4; the guarded FleetCommander caller) -----------

## One-time setup at [method open_battle]: builds the battle's §4.9a profile
## row (with the S21 `formation` / `ai_level` / `archetype` overrides folded
## in) and lazily loads `fleet_commander.gd` — the `battle_result.gd` guard
## pattern (§4.12.3), so a pre-B tree simply leaves [_member _fleet_commander]
## null and the AI runs exactly as before (one warning per battle, the guard
## convention).
func _setup_fleet_commander() -> void:
	_fc_state = {}
	_fc_round = -1
	_fc_orders = []
	_fleet_commander = null
	_enemy_profile = {}
	if _ai_fleet_script != null and _ai_fleet_script.has_method("profile_for"):
		var profile = _ai_fleet_script.profile_for(
			str(encounter.get("kind", "pirate")))
		if profile is Dictionary:
			_enemy_profile = (profile as Dictionary).duplicate()
	# §4.7.16: the sandbox fixture's enemy formation override replaces the
	# profile row's formation for this battle (the fixture carries the key
	# only when the editor left its default).
	var formation_override = encounter.get("formation", null)
	if formation_override is String \
			and not (formation_override as String).is_empty():
		_enemy_profile["formation"] = formation_override
	# §4.7.16/§4.9c (W5-C): the ai_level/archetype overrides fold the same
	# guarded way (the fixture carries the keys only off the row defaults).
	var ai_level_override = encounter.get("ai_level", null)
	if ai_level_override != null:
		_enemy_profile["ai_level"] = int(ai_level_override)
	var archetype_override = encounter.get("archetype", null)
	if archetype_override is String \
			and not (archetype_override as String).is_empty():
		_enemy_profile["archetype"] = archetype_override
	var module = ResourceLoader.load(FLEET_COMMANDER_PATH) \
		if ResourceLoader.exists(FLEET_COMMANDER_PATH) else null
	if module == null or not module.has_method("generate_orders") \
			or not module.can_instantiate():
		_warn_once(FLEET_COMMANDER_PATH, "BattleScreen: %s missing; the §4.9b "
			% FLEET_COMMANDER_PATH + "fleet layer stays dormant (W4-B)")
		return
	_fleet_commander = module.new()


## The §4.9b round-start dispatch, called at the top of [method run_ai_turn]:
## on a round change, re-emits the fleet's per-ship orders. The state dict is
## passed BY REFERENCE and kept across rounds (`_fc_state` is the same object
## B mutates — the hysteresis/succession memory, §4.9b); the returned array is
## this round's per-ship orders, stored for [_method _fleet_order_for].
## Guarded end to end: no commander (pre-B), no living enemy, or a malformed
## return all leave the AI on the plain §4.9a path.
func _ensure_fleet_orders() -> void:
	if _fleet_commander == null or sim == null or sim.is_over():
		return
	var round_no := int(sim.round_number())
	if round_no == _fc_round:
		return
	var anchor: Dictionary = _enemy_anchor_unit()
	if anchor.is_empty():
		return
	_fc_round = round_no
	# Anchor seeding (§4.9b): the enemy flagship's first-round pos + heading8;
	# the formation comes from the profile row. A refined B module without
	# `initial_state` still works from an empty state (guard convention).
	if _fc_state.is_empty():
		if _fleet_commander.has_method("initial_state"):
			var seeded = _fleet_commander.call("initial_state",
				str(_enemy_profile.get("formation", "swarm")),
				sim.unit_cell(anchor),
				int(anchor.get("heading8", BattleSimLib.HEADING_WEST)))
			_fc_state = seeded if seeded is Dictionary else {}
		else:
			_fc_state = {}
	# The §4.9b view: the engine's units, the round, the battle kind, and the
	# enemy side morale (W4 master integration — B's commander reads
	# `view["side_morale"]` for the ≤ 20 break rule; guarded for pre-A sims).
	var view := {
		"units": sim.units(),
		"round": round_no,
		"enemy_kind": str(encounter.get("kind", "pirate")),
	}
	if sim.has_method("side_morale"):
		view["side_morale"] = int(sim.side_morale("enemy"))
	var orders = _fleet_commander.call("generate_orders",
		view, _enemy_profile, _fc_state)
	_fc_orders = orders if orders is Array else []


## The enemy fleet's anchor unit: the flagship while it lives (fleet index 0),
## else the lowest living fleet index (§4.9b succession) — `living_units`
## returns fleet-index order, so that is the first survivor.
func _enemy_anchor_unit() -> Dictionary:
	for unit in sim.living_units(BattleSimLib.SIDE_ENEMY):
		return unit
	return {}


## The order B emitted for `unit` this round. §4.12.3 fixes the return as an
## Array of per-ship five-tuples; the identity key inside an order is B's
## refinement, so the lookup is defensive: an explicit index key first
## (`index` / `unit_index` / `fleet_index`), then the positional reading
## (fleet-index order) for an order dict that carries no identity key at
## all. `{}` when nothing matches (the ship then decides §4.9a-plain).
func _fleet_order_for(unit: Dictionary) -> Dictionary:
	if _fc_orders.is_empty():
		return {}
	var unit_index := int(unit.get("index", -1))
	for order in _fc_orders:
		if not (order is Dictionary):
			continue
		for key in ["index", "unit_index", "fleet_index"]:
			var value = (order as Dictionary).get(key, null)
			if value != null and int(value) == unit_index:
				return order
	if unit_index >= 0 and unit_index < _fc_orders.size():
		var positional = _fc_orders[unit_index]
		if positional is Dictionary \
				and not (positional as Dictionary).has("index") \
				and not (positional as Dictionary).has("unit_index") \
				and not (positional as Dictionary).has("fleet_index"):
			return positional
	return {}


## Whether the loaded `ai_fleet.gd` carries the §4.12.1.1 W4-B decide shape
## `decide(sim, unit, order := {})` — probed once against the script's method
## list (the sibling-module guard convention). Pre-B the 2-arg decide is
## called; post-B the ship's order rides as the third argument.
func _ai_fleet_takes_order() -> bool:
	if _ai_fleet_script == null or not _ai_fleet_script.has_method("decide"):
		return false
	if _ai_fleet_order_args < 0:
		_ai_fleet_order_args = 0
		for method in _ai_fleet_script.get_script_method_list():
			if str(method.get("name", "")) == "decide":
				if (method.get("args", []) as Array).size() >= 3:
					_ai_fleet_order_args = 1
				break
	return _ai_fleet_order_args == 1


## One §4.9 decision for `unit`: with the ship's §4.9b order as the THIRD
## argument when both layers are landed, else the plain §4.9a decision (the
## pre-B behavior, byte-identical to today). The call goes through the
## dynamically dispatched script handle — the analyzer must not reject the
## post-B arity against the pre-B script.
func _ai_decide(unit: Dictionary) -> Dictionary:
	var order := _fleet_order_for(unit)
	# §4.9c (W5-C bounce): the folded battle profile rides the call so the
	# fixture's ai_level/archetype overrides reach the dispatch — the plain
	# `decide` re-derives the row from `enemy_kind` and would ignore them.
	if not order.is_empty() and _ai_fleet_takes_order():
		return _ai_fleet_script.decide(sim, unit, order, _enemy_profile)
	return AiFleetLib.decide(sim, unit, {}, _enemy_profile)


## The §4.7.1/§4.9b anchor-line datum for the minimap and the formation
## label: the anchor cell + heading8 of the enemy fleet's flagship (the
## §4.9b anchor = flagship pos + heading8; the lowest living fleet index
## after succession — the first survivor in fleet-index order). Empty unless
## the fleet layer is ACTIVE (a commander loaded AND this round's orders
## issued) AND the profile's formation is one of §4.8's line formations
## (`line_ahead`/`column`); `screen`/`swarm` draw nothing.
func formation_anchor_line() -> Dictionary:
	if _fleet_commander == null or _fc_orders.is_empty() \
			or sim == null or sim.is_over():
		return {}
	var formation := str(_enemy_profile.get("formation", ""))
	if not (formation in LINE_FORMATIONS):
		return {}
	for unit in sim.living_units(BattleSimLib.SIDE_ENEMY):
		return {
			"formation": formation,
			"cell": sim.unit_cell(unit),
			"heading8": int(unit.get("heading8", BattleSimLib.HEADING_EAST)),
		}
	return {}


## Advances the engine's cursor and finishes the battle when the advance
## itself ends it (the §4.11.9 stall fires inside `end_turn`'s round wrap —
## the outcome must still run the §4.12.4 sequence).
func _end_turn_checked() -> void:
	sim.end_turn()
	if sim.is_over():
		_finish_battle()


## Applies `vel` to the acting ship through the engine's `apply_velocity`
## (§4.12.1): validate → clamp → Bresenham sweep. Movement happens exactly
## once per turn (§4.3) — the presentation gate rides the engine's answer.
func _apply_unit_velocity(unit: Dictionary, vel: Vector2i) -> bool:
	if not sim.apply_velocity(unit, vel):
		return false
	_movement_spent = true
	_velocity_index = -1
	_cursor = sim.unit_cell(unit)
	_cursor_visible = true
	_bind()
	_queue_redraw()
	return true


## Performs `action` against `target` (default: the resolved target) and
## settles the turn. Returns the engine result (`{ok: false}` when illegal).
## The cannon carries the §4.11.8 side auto-pick (`side == ""`) and the shot
## selector's picked type (§4.7.1); ram / board / hold map 1:1 onto the
## engine's §4.5/§4.6/§4.3 actions.
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
			result = sim.cannon(unit, target, "", _selected_shot)
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


## Simulates a left click on `cell` (the acceptance suite and the mouse
## handler share this one path — the click is routed through the camera
## functions, so "click a legal vector" exercises the real handlers, not
## test-only shortcuts).
func click_cell(cell: Vector2i) -> void:
	if not BattleSimLib.in_grid(cell):
		return
	var world := Vector2(cell) * TILE_PX + Vector2(TILE_PX, TILE_PX) * 0.5
	_handle_click_at(world_to_screen(world, _cam_pos, _cam_zoom))


## After an action: end the battle, else advance the turn and let the AI play
## every intervening turn (§4.3). `spent` is the engine's "the action happened".
func _settle_turn(spent: bool) -> void:
	if sim.is_over():
		_finish_battle()
		return
	if spent:
		_end_turn_checked()
		if sim.is_over():
			return
	_pump_enemy_turns()
	_bind()
	_queue_redraw()


## Plays AI turns until a player ship may act or the battle ends (§4.3 turn
## order — a faster enemy legitimately acts before the player's ships).
## Animate mode (§4.7.1) applies ONE stepped AI turn per call — the `_process`
## loop keeps the presentation moving; instant mode resolves the whole stretch.
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
		if unit.is_empty():
			# The empty-cursor transient (pacing-repins bounce): the last-slot
			# ship can die mid-round, leaving the cursor empty with the battle
			# still open — the documented `BattleSim.run_to_completion` path
			# covers this via its `end_turn()` re-check; the pump must too,
			# or an animate-mode battle stalls with nobody to act.
			if not sim.is_over():
				_end_turn_checked()
				continue
			return
		if str(unit.get("side", "")) != BattleSimLib.SIDE_ENEMY:
			return
		run_ai_turn()
		if not _ai_instant:
			return


## §4.7.1 animate mode: one stepped AI turn per frame (the instant switch
## short-circuits this loop entirely). The §4.7.17 sequencer paces the step:
## while its presentation of the previous turn is still running, the next AI
## turn waits — the sim's call sequence is unchanged (one `run_ai_turn()` at
## a time), only the wall-clock spacing follows the FX. Instant mode never
## waits (the sequencer is idle by construction there).
func _process(delta: float) -> void:
	if sim == null or sim.is_over() or has_modal():
		return
	if not _ai_instant:
		var unit: Dictionary = sim.current_unit()
		if not unit.is_empty() and str(unit.get("side", "")) == BattleSimLib.SIDE_ENEMY:
			var sequencer_busy: bool = _fx != null \
				and _fx.has_method("busy") and bool(_fx.busy())
			if not sequencer_busy:
				run_ai_turn()
				if sim.is_over():
					return
	# The §4.7.17 token slide: while a move event animates, the world tokens
	# re-draw each frame to carry the interpolation offset.
	if _fx != null and _fx.has_method("needs_world_redraw") \
			and bool(_fx.needs_world_redraw()):
		_grid_view.queue_redraw()
	# Edge scroll (§4.3) runs only for the production scene, so a headless
	# suite's mouse at (0,0) never drifts the camera mid-assertion.
	if is_active_scene():
		var mouse := get_viewport().get_mouse_position() - _grid_view.global_position
		if Rect2(Vector2.ZERO, VIEW_SIZE).has_point(mouse):
			var scroll := edge_scroll(_cam_pos, mouse, delta)
			if scroll != Vector2.ZERO:
				_cam_pos = clamp_cam(_cam_pos + scroll, _cam_zoom)
				_queue_redraw()


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
		int(defender.get("crew", 0)),
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


# --- World rendering (docs/80-* §4.7.1, §4.8) -------------------------------

func _style() -> void:
	# §4.9 sweep (W5-A): the bars/panels/labels ride the theme (Label TEXT,
	# PanelContainer chrome); the two semantic inks are the ledgered theme
	# variations — Dim (= PANEL_LINE) for the top-bar weather readout,
	# Accent for the ‖vel‖ readout. Per-screen font sizes retired.
	# §4.8 Skin coverage (amended 2026-11-05): the top bar and the 96px
	# bottom panel render the walnut band vocabulary at bar scale
	# (`UiKit.route_band`); the full-screen Background is a theme-styled
	# Panel (nine-patch walnut, navy flat fallback). The pinned navy fills
	# remain the reduced-graphics fallback.
	UiKitLib.route_band(_top_bar, UiKitLib.BAND_EDGE_BOTTOM)
	UiKitLib.route_band(_bottom_panel, UiKitLib.BAND_EDGE_TOP)
	_weather.theme_type_variation = "Dim"
	_speed.theme_type_variation = "Accent"
	# The log lines' 11px ink is load-bearing for the §4.7.1 96px bottom bar
	# (three lines + the stats row must fit); it lives on the labels in
	# battle_screen.tscn (`theme_override_font_sizes` — the scene-file
	# channel, the same one that carries the container margins there).
	# W5-A follow-up (bar budget): the bar's minimum is consumed exactly by
	# the shot selector's two 40px rows (40 + 8 + 40 + the Margin's 2+2
	# verticals = 92 ≤ 96, with the LeftCol's stats row + 3 log lines at
	# 2 + 31 + 2 + 50 + 2 = 87), so even the §4.9 40px button floor on the
	# [fit] button keeps the bar at 96 (2 + 40 + 2 + 50 + 2 = 96).
	_after_continue.custom_minimum_size.y = float(PaletteLib.BUTTON_H)


func _wire_action_buttons() -> void:
	_action_buttons.clear()
	for node in _actions.get_children():
		if node is Button and node.has_meta("action_id"):
			var button := node as Button
			var action_id := str(button.get_meta("action_id"))
			button.pressed.connect(func() -> void:
				_on_action_pressed(str(button.get_meta("action_id"))))
			_action_buttons[action_id] = button
	_shot_buttons.clear()
	for node in _shot_row.get_children():
		if node is Button and node.has_meta("shot_id"):
			var button := node as Button
			_shot_buttons[str(button.get_meta("shot_id"))] = button


# --- §4.7.17 battle water (Phase-10 W5-A; retired material, 2026-11-07) ------

## The 48×30 battle sea on the SHARED water builder (`WaterLayer.build_layer`
## stamps the two flat painted fills). The animated-sea ShaderMaterial is
## RETIRED (2026-11-07, user direction "remove everything", 80-* §4.7.17):
## the layer carries no material — plain painted water. A missing registry id
## renders the locked palette fill exactly as the pre-Phase-10 sea did.
func _build_battle_water() -> void:
	_water_layer = WaterLayerLib.build_layer(int(TILE_PX))
	_water_layer.name = "BattleWater"
	# The battle world is open water: every cell stamps the flat sea fill.
	if _water_layer.tile_set != null:
		var source := _water_layer.tile_set.get_next_source_id() - 1
		var column := int(WaterLayerLib.KIND_COLUMNS["sea"])
		for y in GRID_H:
			for x in GRID_W:
				_water_layer.set_cell(Vector2i(x, y), source,
					Vector2i(column, 0))
	add_child(_water_layer)
	# Above the background, under every HUD/token canvas item.
	move_child(_water_layer, 1)


## Keeps a world-space canvas item (the water layer, the fx layer) in the
## camera's screen transform: the world's top-left at the projected origin,
## scaled by the zoom — the same mapping the world draw applies by hand.
func _sync_world_node(node: CanvasItem) -> void:
	if node == null:
		return
	node.position = world_to_screen(Vector2.ZERO, _cam_pos, _cam_zoom)
	node.scale = Vector2.ONE * _cam_zoom


# --- W4 HUD (docs/80-* §4.7.1 top-area morale bars + formation label) -------

## Builds the §4.7.1 W4 additions in code (palette shapes only, §4.8): the
## two labeled side-morale bars appended to the top row (player left of the
## pair, enemy right) and the formation label under the minimap. The label
## text is set by [method _bind_morale] / [method _bind_formation]; every
## control ignores the mouse so the top bar and the world view keep input.
func _build_morale_hud() -> void:
	var box := HBoxContainer.new()
	box.name = "MoraleBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side_def in [
		{
			"side": BattleSimLib.SIDE_PLAYER,
			"column": "MoralePlayer", "label": "MoralePlayerLabel",
			"track": "MoralePlayerTrack", "fill": "MoralePlayerFill",
		},
		{
			"side": BattleSimLib.SIDE_ENEMY,
			"column": "MoraleEnemy", "label": "MoraleEnemyLabel",
			"track": "MoraleEnemyTrack", "fill": "MoraleEnemyFill",
		},
	]:
		var column := VBoxContainer.new()
		column.name = str(side_def["column"])
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The §4.8.1-pinned 12px status-line variation (theme-owned size +
		# TEXT ink — the per-screen override channel is retired).
		var label := Label.new()
		label.name = str(side_def["label"])
		label.text = _t("battle.morale")
		label.theme_type_variation = "CardStatus"
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(label)
		var track := ColorRect.new()
		track.name = str(side_def["track"])
		track.custom_minimum_size = Vector2(96, 8)
		track.color = PaletteLib.PANEL_LINE
		track.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill := ColorRect.new()
		fill.name = str(side_def["fill"])
		fill.color = PaletteLib.GOOD
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		track.add_child(fill)
		column.add_child(track)
		box.add_child(column)
		if side_def["side"] == BattleSimLib.SIDE_PLAYER:
			_morale_player_label = label
			_morale_player_track = track
			_morale_player_fill = fill
		else:
			_morale_enemy_label = label
			_morale_enemy_track = track
			_morale_enemy_fill = fill
	_top_bar.add_child(box)
	box.position = Vector2(VIEW_SIZE.x - 224.0, 4.0)

	# The formation display sits directly under the 192×120 minimap
	# (§4.7.1 "near the minimap"): the §4.8 `formation_*` icon beside the
	# label, hidden until a line formation's fleet layer is active (§4.8
	# pins the anchor lines to line_ahead/column). A registry miss hides the
	# icon — the label-only rendering is the fallback.
	var formation_box := HBoxContainer.new()
	formation_box.name = "FormationBox"
	formation_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	formation_box.position = Vector2(1080, 170)
	formation_box.size = Vector2(192, 36)
	_formation_icon = TextureRect.new()
	_formation_icon.name = "FormationIcon"
	_formation_icon.custom_minimum_size = Vector2(32, 32)
	_formation_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_formation_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_formation_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_formation_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_formation_icon.visible = false
	formation_box.add_child(_formation_icon)
	_formation_label = Label.new()
	_formation_label.name = "FormationLabel"
	_formation_label.theme_type_variation = "CardStatus"
	_formation_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_formation_label.size_flags_vertical = Control.SIZE_FILL
	_formation_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_formation_label.visible = false
	formation_box.add_child(_formation_label)
	add_child(formation_box)


## One side's §4.8a morale. GUARDED SEAM (W4-A): when the engine lacks
## `side_morale` (the pre-A merge), the bars render 100/100 — a full bar is
## the missing-seam reading, never a guessed value; the call shape is the
## `60-*` §4.12.1 pin (`sim.side_morale("player"/"enemy")`).
func _side_morale(side: String) -> int:
	if sim != null and sim.has_method("side_morale"):
		var value = sim.call("side_morale", side)
		if value is int or value is float:
			return clampi(int(value), 0, 100)
	return 100


## Sets one bar's fill: `value/100` of the track width, GOOD tier above the
## §4.8a gate and WARN at or below it (see MORALE_WARN_AT — display only).
func _set_morale_fill(fill: ColorRect, track: ColorRect, value: int) -> void:
	if fill == null or track == null:
		return
	var width := track.size.x
	if width <= 0.0:
		width = track.custom_minimum_size.x
	var height := track.size.y
	if height <= 0.0:
		height = track.custom_minimum_size.y
	fill.position = Vector2.ZERO
	fill.size = Vector2(width * float(clampi(value, 0, 100)) / 100.0, height)
	fill.color = PaletteLib.WARN if value <= MORALE_WARN_AT else PaletteLib.GOOD


## §4.7.1 W4: the morale bars refresh on the existing `_bind` cadence — the
## labels read `battle.morale` + the value, the fills value/100.
func _bind_morale() -> void:
	if _morale_player_label == null or _morale_enemy_label == null:
		return
	var player_value := _side_morale(BattleSimLib.SIDE_PLAYER)
	var enemy_value := _side_morale(BattleSimLib.SIDE_ENEMY)
	_morale_player_label.text = "%s %d" % [_t("battle.morale"), player_value]
	_morale_enemy_label.text = "%s %d" % [_t("battle.morale"), enemy_value]
	_set_morale_fill(_morale_player_fill, _morale_player_track, player_value)
	_set_morale_fill(_morale_enemy_fill, _morale_enemy_track, enemy_value)


## §4.7.1 W4: the formation label + §4.8 formation icon — `battle.formation`
## + the `battle.formation.<value>` label with the §4.8 `formation_*` icon
## beside it, shown only while the §4.9b fleet layer is active on a line
## formation (§4.8's `line_ahead`/`column` pin); hidden otherwise (no
## display, no key invented, for `screen`/`swarm`). A registry miss keeps
## the label-only rendering (the §4.9 fallback).
func _bind_formation() -> void:
	if _formation_label == null:
		return
	var anchor := formation_anchor_line()
	if anchor.is_empty():
		_formation_label.visible = false
		if _formation_icon != null:
			_formation_icon.visible = false
		return
	var formation := str(anchor.get("formation", ""))
	_formation_label.visible = true
	_formation_label.text = "%s %s" % [
		_t("battle.formation"),
		I18n.t_key("battle.formation.%s" % formation),
	]
	if _formation_icon != null:
		var texture := UiKitLib.icon_texture("formation_%s" % formation)
		_formation_icon.texture = texture
		_formation_icon.visible = texture != null


## One custom-draw pass for the whole world view (§4.7.1, §4.8): the grid
## lines and the unit tokens, all through the camera functions. The sea
## itself is the §4.7.17 water TileMapLayer (the shared builder — see
## [_method _build_battle_water]); drawing the tokens/lines (not child
## Controls) keeps the free camera cheap.
func _on_world_draw() -> void:
	# Every call draws on `_grid_view`, the item whose `draw` signal fired —
	# an unqualified `draw_*` binds to `self` (this root Control), which is
	# not inside its own draw window, so the engine rejects it with
	# "Drawing is only allowed …" per call (and nothing renders).
	# The camera transform of the two world-space layers is refreshed here
	# so a draw triggered by any path still renders the current camera.
	_sync_world_node(_water_layer)
	_sync_world_node(_fx)
	var line := PaletteLib.PANEL_LINE
	for x in range(1, GRID_W):
		var px := world_to_screen(Vector2(x * TILE_PX, 0), _cam_pos, _cam_zoom)
		_grid_view.draw_rect(Rect2(px, Vector2(1.0, WORLD_PX.y * _cam_zoom)), line, true)
	for y in range(1, GRID_H):
		var px := world_to_screen(Vector2(0, y * TILE_PX), _cam_pos, _cam_zoom)
		_grid_view.draw_rect(Rect2(px, Vector2(WORLD_PX.x * _cam_zoom, 1.0)), line, true)
	if sim == null:
		return
	var font := ThemeDB.fallback_font
	var acting: Dictionary = sim.current_unit()
	var owner := _enemy_owner_id()
	for unit in sim.units():
		if not bool(unit.get("alive", false)):
			continue
		var cell: Vector2i = sim.unit_cell(unit)
		# The §4.7.17 sequencer's token slide (ZERO when idle/instant).
		var slide := Vector2.ZERO
		if _fx != null and _fx.has_method("move_offset_for"):
			slide = _fx.move_offset_for(_unit_key(unit))
		var center := world_to_screen(
			Vector2(cell) * TILE_PX + Vector2(TILE_PX, TILE_PX) * 0.5,
			_cam_pos, _cam_zoom) + slide
		var letter := TOKEN_PLAYER
		var flagship_unit: Dictionary = sim.flagship_unit()
		var flagship: bool = not flagship_unit.is_empty() \
			and _unit_key(flagship_unit) == _unit_key(unit)
		if str(unit.get("side", "")) == BattleSimLib.SIDE_PLAYER:
			letter = TOKEN_FLAGSHIP if flagship else TOKEN_PLAYER
		else:
			letter = TOKEN_ENEMY
		# §4.8 hull token (top-down amendment, 2026-11-07): the tier-sized
		# north token `hull_{type}_{owner}` (owner fallback → the shared
		# `hull_{type}`), resolved through the §4.9 registry and rotated to
		# the unit's `heading8` (vel = 0 keeps the last heading, `60-*`
		# §4.3a). A registry miss keeps the Phase-1 placeholder square (the
		# fallback path never goes away).
		var heading8 := int(unit.get("heading8", 0))
		var sprite_id := hull_sprite_id(
			str((unit.get("ship", {}) as Dictionary).get("ship_type_id", "")),
			owner if str(unit.get("side", "")) != BattleSimLib.SIDE_PLAYER
			else "player")
		var texture := UiKitLib.icon_texture(sprite_id) \
			if not sprite_id.is_empty() else null
		if texture != null:
			# The tier-sized token canvas draws at 0.5 × native — t3 64→32 px
			# on the 32 px battle tile (unchanged), t2 48→24, t1 32→16. The
			# rotation pivots on the drawn-rect center (draw_set_transform);
			# nearest filtering is pinned on the grid view (see `_ready`).
			var blit_px := texture.get_size() * 0.5 * _cam_zoom
			var rot := deg_to_rad(heading_rotation_degrees(heading8))
			_grid_view.draw_set_transform(center, rot, Vector2.ONE)
			_grid_view.draw_texture_rect(texture,
				Rect2(-blit_px * 0.5, blit_px), false)
			_grid_view.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			var half := TOKEN_PX * _cam_zoom * 0.5
			var rect := Rect2(center - Vector2(half, half),
				Vector2(half, half) * 2.0)
			var outline := Color.BLACK
			if str(unit.get("side", "")) == BattleSimLib.SIDE_PLAYER:
				outline = PaletteLib.ACCENT if flagship else Color.BLACK
				_grid_view.draw_rect(rect, PaletteLib.TEXT)
			else:
				outline = PaletteLib.TEXT
				_grid_view.draw_rect(rect, _enemy_dot_color())
			_grid_view.draw_rect(rect, outline, false, 1.0)
		# §4.8.5: the identification letter stays a runtime OVERLAY badge on
		# top of the token sprite — never baked into the PNG.
		if font != null:
			var font_size := maxi(8, int(round(12.0 * _cam_zoom)))
			var text_size := font.get_string_size(letter,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			_grid_view.draw_string(font, center
				+ Vector2(-text_size.x * 0.5, text_size.y * 0.25),
				letter, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.BLACK)
	# The acting unit wears a 2px accent frame (§4.8 focus outline).
	if not acting.is_empty() and bool(acting.get("alive", false)):
		var cell: Vector2i = sim.unit_cell(acting)
		var slide := Vector2.ZERO
		if _fx != null and _fx.has_method("move_offset_for"):
			slide = _fx.move_offset_for(_unit_key(acting))
		var center := world_to_screen(
			Vector2(cell) * TILE_PX + Vector2(TILE_PX, TILE_PX) * 0.5,
			_cam_pos, _cam_zoom) + slide
		var half := TOKEN_PX * _cam_zoom * 0.5 + 2.0
		_grid_view.draw_rect(
			Rect2(center - Vector2(half, half), Vector2(half, half) * 2.0),
			PaletteLib.ACCENT, false, 2.0)


## §4.8 token colours: player `TEXT` with a black outline, pirate `BAD`, navy
## the owning nation's `Nation.color` (the same pin the minimap dots use).
func _enemy_dot_color() -> Color:
	if _enemy_is_pirate():
		return PaletteLib.BAD
	return _enemy_nation_color()


## The 192×120 minimap (§4.7.1, §4.8 pins): ship dots, the viewport frame,
## the wind arrow (ACCENT, the battle's locked `wind_dir`), the current arrow
## (COAST_SEA, only while the locked current has strength), and — W4 — the
## formation anchor lines stub. Every call draws on `_minimap`, the item
## whose `draw` signal fired (an unqualified `draw_*` binds to `self`, which
## is not inside its own draw window — see `_on_world_draw`).
func _on_minimap_draw() -> void:
	_minimap.draw_rect(Rect2(Vector2.ZERO, MINIMAP_SIZE), PaletteLib.PANEL_BG)
	if sim == null:
		return
	# Ship dots: player = TEXT, enemy = BAD / the navy owner's Nation.color.
	for unit in sim.units():
		if not bool(unit.get("alive", false)):
			continue
		var cell: Vector2i = sim.unit_cell(unit)
		var center := minimap_map(
			Vector2(cell) * TILE_PX + Vector2(TILE_PX, TILE_PX) * 0.5)
		var color := PaletteLib.TEXT \
			if str(unit.get("side", "")) == BattleSimLib.SIDE_PLAYER \
			else _enemy_dot_color()
		_minimap.draw_rect(Rect2(center - Vector2(2, 2), Vector2(4, 4)),
			color, true)
	# The viewport frame (§4.8 pin: ACCENT).
	var world_rect := Rect2(
		_cam_pos - VIEW_SIZE * 0.5 / _cam_zoom, VIEW_SIZE / _cam_zoom)
	var frame_pos := minimap_map(world_rect.position)
	var frame_end := minimap_map(world_rect.end)
	_minimap.draw_rect(Rect2(frame_pos, frame_end - frame_pos),
		PaletteLib.ACCENT, false, 1.0)
	# The wind arrow (§4.8 pin: ACCENT) — rotated per the wind-FROM token.
	# The arrow's segments are computed as pure data and drawn here, in the
	# one handler (never on another item, never outside the draw window).
	var center := MINIMAP_SIZE * 0.5
	var wind_index := SailingSimLib.heading_index(str(sim.wind_dir))
	if wind_index >= 0:
		for segment in _minimap_arrow_segments(center,
				Vector2(BattleSimLib.HEADING_RAYS[wind_index]), 22.0):
			_minimap.draw_line(segment[0], segment[1], PaletteLib.ACCENT, 2.0)
	# The current arrow (§4.8 pin: COAST_SEA) — only while strength > 0; it
	# points along the flow-TO token.
	var current: Dictionary = sim.current
	var strength := int(current.get("strength", 0)) if current is Dictionary else 0
	var current_index := SailingSimLib.heading_index(
		str(current.get("dir", ""))) if current is Dictionary else -1
	if strength > 0 and current_index >= 0:
		for segment in _minimap_arrow_segments(center,
				Vector2(BattleSimLib.HEADING_RAYS[current_index]), 14.0):
			_minimap.draw_line(segment[0], segment[1],
				PaletteLib.COAST_SEA, 1.5)
	# W4 (§4.7.1/§4.8): the formation anchor line — the anchor cell centre
	# plus a 6-cell heading ray, PANEL_LINE per the §4.8 pin, drawn only
	# while the §4.9b fleet layer is active on a line formation.
	var anchor := formation_anchor_line()
	if not anchor.is_empty():
		var anchor_cell: Vector2i = anchor.get("cell", Vector2i.ZERO)
		var anchor_center := minimap_map(
			Vector2(anchor_cell) * TILE_PX + Vector2(TILE_PX, TILE_PX) * 0.5)
		var heading: int = int(anchor.get("heading8", BattleSimLib.HEADING_EAST))
		if heading >= 0 and heading < BattleSimLib.HEADING_RAYS.size():
			var ray := Vector2(BattleSimLib.HEADING_RAYS[heading]).normalized()
			_minimap.draw_line(anchor_center,
				anchor_center + ray
					* (float(FORMATION_ANCHOR_CELLS) * TILE_PX * MINIMAP_SCALE),
				PaletteLib.PANEL_LINE, 1.5)


## Pure arrow geometry (no drawing): the three segments of a minimap arrow —
## shaft `from → tip`, then the two head strokes at ±150° off the direction.
func _minimap_arrow_segments(from: Vector2, direction: Vector2,
		length: float) -> Array:
	var dir := direction.normalized()
	var tip := from + dir * length
	var segments: Array = [[from, tip]]
	for side in [-1.0, 1.0]:
		var head := dir.rotated(side * PI * 0.8333) * mini(length * 0.3, 6.0)
		segments.append([tip, tip + head])
	return segments


func _on_minimap_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	# §4.3: "the minimap owns input before the world view" — a click jumps the
	# camera. A manual camera command, so follow pauses until the next turn.
	var world := (mouse.position / MINIMAP_SCALE).clamp(Vector2.ZERO, WORLD_PX)
	_cam_pos = clamp_cam(world, _cam_zoom)
	_follow = false
	get_viewport().set_input_as_handled()
	_queue_redraw()


func _queue_redraw() -> void:
	_grid_view.queue_redraw()
	_minimap.queue_redraw()


# --- Repaint ---------------------------------------------------------------

## Re-reads the engine and repaints every derived widget. Never mutates state.
func _bind() -> void:
	if sim == null:
		return
	# Phase-10 W5-A: the fx sequencer observes the engine's event stream
	# (log entries + position diffs — read-only) before anything repaints.
	if _fx != null and _fx.has_method("observe"):
		_fx.observe(sim, _fx_instant())
	_title.text = _t("battle.title")
	_day.text = I18n.fmt("world.day", {"day": int(sim.day)})
	_round.text = _t("battle.round", {"round": int(sim.round_number())})
	# §4.12.1: the battle's weather is locked at open time. A sandbox battle
	# locks it on the fixture (there is no world state to read), so the label
	# reads the engine's copy there; the normal path keeps the world lookup.
	var weather_name := str(sim.weather) if is_sandbox_battle() else _weather_name()
	_weather.text = I18n.t_key("world.weather.%s" % weather_name)
	_sync_camera()
	_bind_stats()
	_bind_actions()
	_bind_shots()
	_bind_log_records()
	_bind_log()
	_bind_highlights()
	_bind_morale()
	_bind_formation()
	_bind_menu()


## §4.7.1 camera follow: auto-center on the acting unit until the first manual
## pan; a manual pan pauses follow until the acting unit's NEXT turn.
func _sync_camera() -> void:
	var actor: Dictionary = sim.current_unit()
	var actor_key := "" if actor.is_empty() else _unit_key(actor)
	if actor_key != _actor_key:
		_actor_key = actor_key
		_movement_spent = false
		_velocity_index = -1
		_follow = true
	if _follow and not actor.is_empty():
		var center := Vector2(sim.unit_cell(actor)) * TILE_PX \
			+ Vector2(TILE_PX, TILE_PX) * 0.5
		_cam_pos = clamp_cam(center, _cam_zoom)
	_overlay.set_camera(_cam_pos, _cam_zoom)
	# The two world-space layers ride the same camera transform.
	_sync_world_node(_water_layer)
	_sync_world_node(_fx)


func _bind_stats() -> void:
	var unit := selected_unit()
	if unit.is_empty() and not sim.is_over():
		unit = sim.flagship_unit()
	if unit.is_empty():
		for label in [_speed, _heading, _reload_port, _reload_starboard,
				_wind, _weather_label]:
			label.text = "-"
		_target_label.text = _t("battle.target.none")
		return
	var vel: Vector2i = unit.get("vel", Vector2i.ZERO)
	# §4.7.1 bottom bar: ‖vel‖ (1 decimal) and the heading8 compass token.
	_speed.text = "%s %.1f" % [_t("battle.speed"),
		BattleSimLib.vel_length(vel)]
	_heading.text = "%s %s" % [_t("battle.heading"),
		BattleSimLib.HEADING_TOKENS[posmod(int(unit.get("heading8", 0)),
			BattleSimLib.HEADING_TOKENS.size())]]
	_reload_port.text = "%s %s" % [_t("battle.reload.port"),
		_reload_pips(unit, BattleSimLib.BROADSIDE_PORT)]
	_reload_starboard.text = "%s %s" % [_t("battle.reload.starboard"),
		_reload_pips(unit, BattleSimLib.BROADSIDE_STARBOARD)]
	_wind.text = "%s %s" % [_t("battle.wind"), str(sim.wind_dir)]
	var weather_name := str(sim.weather) if is_sandbox_battle() else _weather_name()
	_weather_label.text = "%s %s" % [_t("battle.weather"),
		I18n.t_key("world.weather.%s" % weather_name)]
	_target_label.text = _target_text(unit)


## §4.7.1 per-side reload pips: a loaded side shows one filled pip (`●`) per
## cannon; a reloading side shows hollow pips (`○`) plus the rounds still to
## wait in `(N)` form (§4.4a — "that side may fire again only when
## `round ≥ reload_side`"). Example: `Port ●●` loaded, `Starboard ○○ (2)`
## reloading.
func _reload_pips(unit: Dictionary, side: String) -> String:
	var key := "reload_port" if side == BattleSimLib.BROADSIDE_PORT \
		else "reload_starboard"
	var total: int = sim.side_cannons(unit, side)
	var ready_at := int(unit.get(key, 1))
	var round_no := int(sim.round_number())
	if round_no >= ready_at:
		return "●".repeat(total)
	return "%s (%d)" % ["○".repeat(total), ready_at - round_no]


func _bind_actions() -> void:
	_disabled_reasons.clear()
	var unit := selected_unit()
	var target: Dictionary = _resolve_target(unit, "") if not unit.is_empty() else {}
	for action_id in ACTION_IDS:
		var button: Button = _action_buttons.get(action_id, null)
		if button == null:
			continue
		button.text = _t("battle.action.%s" % action_id)
		var reason := _block_reason(action_id, unit, target)
		button.disabled = not reason.is_empty()
		button.tooltip_text = "" if reason.is_empty() else _reason_text(reason)
		if not reason.is_empty():
			_disabled_reasons[action_id] = reason
	_bind_menu()


## §4.7.1 shot selector: the four §4.4b shot types; gate-locked states grayed
## with `battle.shot.locked` {value} (chain 25 / armor-piercing 50, the
## `skill_gates` data via the engine's gate accessors); grape disabled unless
## the intended target is at Chebyshev range 1. The selection rides the
## cannon decision (no text marker — buttons `1`–`4` re-pick, §4.3).
func _bind_shots() -> void:
	var unit := selected_unit()
	var target: Dictionary = _resolve_target(unit, "cannon") \
		if not unit.is_empty() else {}
	var distance := -1
	if not unit.is_empty() and not target.is_empty():
		distance = _distance(sim.unit_cell(unit), sim.unit_cell(target))
	for index in SHOT_IDS.size():
		var shot: String = SHOT_IDS[index]
		var button: Button = _shot_buttons.get(shot, null)
		if button == null:
			continue
		var label := "%d %s" % [index + 1, _t("battle.shot.%s" % shot)]
		button.text = label
		button.set_meta("index", index)
		var tooltip := ""
		if shot == BattleSimLib.CHAIN_SHOT \
				and not BattleSimLib.shot_unlocked(shot):
			tooltip = _t("battle.shot.locked",
				{"value": BattleSimLib.chain_shot_gate()})
		elif shot == BattleSimLib.ARMOR_PIERCING_SHOT \
				and not BattleSimLib.shot_unlocked(shot):
			tooltip = _t("battle.shot.locked",
				{"value": BattleSimLib.armor_piercing_gate()})
		elif shot == BattleSimLib.GRAPE_SHOT and distance != BattleSimLib.CANNON_RANGE_MIN:
			tooltip = _reason_text("battle.reason.out_of_range")
		button.disabled = not tooltip.is_empty()
		button.tooltip_text = tooltip


## The presentation log: one record per engine entry this screen knows how to
## render, plus one `battle.log.turn` line per turn. Kinds outside the
## `battle.*` inventory are skipped rather than inventing keys.
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
## (`{key, values}`) using only landed `battle.*` keys.
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
			# The per-round detail belongs to the S11 modal; the log keeps
			# the one boarding line.
			out.append({"key": "battle.duel.start", "values": {}})
		"hold":
			out.append({"key": "battle.log.hold", "values": {"ship": attacker}})
		"retreat":
			out.append({"key": "battle.result.retreat", "values": {}})
		"surrender":
			out.append({"key": "battle.result.surrender", "values": {}})
		"surrender_enemy":
			out.append({"key": "battle.log.surrender_enemy",
				"values": {"ship": attacker}})
		"strike":
			out.append({"key": "battle.log.strike", "values": {"ship": attacker}})
		_:
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


## Pushes the §4.7.1 overlay state for the acting player unit: the reachable
## velocity vectors, the broadside arc fans, the target side indicators and
## the hook-highlight rings.
func _bind_highlights() -> void:
	var unit := selected_unit()
	var targets: Array = []
	var side_marks: Array = []
	var hook_cells: Array = []
	var endpoints: Array = []
	var vectors: Array = []
	var origin := Vector2.ZERO
	var heading := 0
	var selected := BattleSimLib.NO_CELL
	if not unit.is_empty():
		var unit_cell: Vector2i = sim.unit_cell(unit)
		origin = Vector2(unit_cell) * TILE_PX
		heading = int(unit.get("heading8", 0))
		for enemy in sim.living_units(BattleSimLib.SIDE_ENEMY):
			var enemy_cell: Vector2i = sim.unit_cell(enemy)
			if sim.can_cannon(unit, enemy) or sim.can_ram(unit, enemy) \
					or sim.can_board(unit, enemy):
				targets.append(enemy_cell)
			# §4.7.1 target side indicators: a marker on the arc side that
			# can fire at this enemy (§4.4 named-side arcs).
			var side := ""
			if sim.can_cannon(unit, enemy, BattleSimLib.BROADSIDE_PORT):
				side = BattleSimLib.BROADSIDE_PORT
			elif sim.can_cannon(unit, enemy, BattleSimLib.BROADSIDE_STARBOARD):
				side = BattleSimLib.BROADSIDE_STARBOARD
			if not side.is_empty():
				side_marks.append({"cell": enemy_cell, "side": side})
			# §4.6a hook condition → the GOOD ring (`battle.ring.hook`).
			if sim.can_board(unit, enemy):
				hook_cells.append(enemy_cell)
		if not _movement_spent:
			_legal_velocities = sim.legal_velocities(unit)
			for vel in _legal_velocities:
				vectors.append(vel)
				endpoints.append(unit_cell + vel)
			if _velocity_index >= 0 and _velocity_index < _legal_velocities.size():
				selected = _legal_velocities[_velocity_index]
	else:
		_legal_velocities = []
	_velocity_index = mini(_velocity_index, _legal_velocities.size() - 1)
	_endpoint_cells = endpoints
	_target_cells_cache = targets
	_overlay.set_state(origin, heading, vectors, selected, side_marks,
		hook_cells, _cursor, _cursor_visible)


func _bind_menu() -> void:
	if _menu_title == null:
		return
	_menu_title.text = _t("battle.title")
	_menu_retreat.text = _t("battle.action.retreat")
	_menu_surrender.text = _t("battle.action.surrender")
	_menu_ai_animate.text = _t("battle.ai_speed.animate")
	_menu_ai_instant.text = _t("battle.ai_speed.instant")
	# The ACTIVE mode's button is disabled — the other one switches (§4.7.1
	# "跟随动画 animate / 即时结算 instant").
	_menu_ai_animate.disabled = not _ai_instant
	_menu_ai_instant.disabled = _ai_instant
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
			# The decision's `vel` WAS the move (the engine's seam applies it);
			# a cell-authored legacy decision degenerates to a hold.
			var vel = decision.get("vel", null)
			if vel is Vector2i:
				sim.apply_velocity(unit, vel)
			else:
				sim.hold(unit)
		_:
			sim.hold(unit)


# --- Input (docs/80-* §4.3 S10 rows, §4.7.1) --------------------------------

## The `F10` session capture rides the `_input` stage (docs/80-* §4.3 keybind
## row, capture amendment 2026-11-05) so it fires even while the after-action
## dialog, confirm or menu owns input — the capture is acceptance evidence
## and must work with any UI on screen. Echo events ignored.
func _input(event: InputEvent) -> void:
	if sim == null:
		return
	if not (event is InputEventKey) or not (event as InputEventKey).pressed \
			or (event as InputEventKey).echo:
		return
	var key := event as InputEventKey
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE \
		else key.keycode
	if code == KEY_F10:
		_capture_session_screenshot()


## Waits for the current frame to finish drawing, then dumps the battle
## viewport to `user://screenshots/battle_<ticks>.png`; prints the absolute
## path (the acceptance-report seam).
func _capture_session_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var dir := OS.get_user_data_dir() + "/screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/battle_%d.png" % [dir, Time.get_ticks_msec()]
	get_viewport().get_texture().get_image().save_png(path)
	print("CAPTURE saved: ", path)


func _unhandled_input(event: InputEvent) -> void:
	if sim == null:
		return
	# §4.7.1 (W6-A): the captain intro preview is dismissed with any input
	# before the first round (the input is otherwise swallowed).
	if _preview != null and _preview.visible:
		get_viewport().set_input_as_handled()
		_dismiss_captain_preview()
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
		_on_mouse_button(event as InputEventMouseButton)
		return
	if event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
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
				_confirm_velocity()
			KEY_UP, KEY_LEFT:
				get_viewport().set_input_as_handled()
				_cycle_velocity(-1)
			KEY_DOWN, KEY_RIGHT:
				get_viewport().set_input_as_handled()
				_cycle_velocity(1)
			KEY_HOME:
				get_viewport().set_input_as_handled()
				fit_view()
			KEY_1:
				get_viewport().set_input_as_handled()
				select_shot(BattleSimLib.ROUND_SHOT)
			KEY_2:
				get_viewport().set_input_as_handled()
				select_shot(BattleSimLib.CHAIN_SHOT)
			KEY_3:
				get_viewport().set_input_as_handled()
				select_shot(BattleSimLib.ARMOR_PIERCING_SHOT)
			KEY_4:
				get_viewport().set_input_as_handled()
				select_shot(BattleSimLib.GRAPE_SHOT)


func _on_mouse_button(mouse: InputEventMouseButton) -> void:
	var view_pos := mouse.position - _grid_view.global_position
	match mouse.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if mouse.pressed:
				get_viewport().set_input_as_handled()
				_apply_wheel(
					1.0 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0,
					view_pos)
			return
		_:
			pass
	if mouse.pressed:
		_press_active = true
		_press_pos = view_pos
		_press_button = mouse.button_index
		_panning = false
		return
	# Release: a LEFT press that moved ≤ 4 px is a click (§4.3); any press
	# that moved more was a drag (already panned).
	if _press_active and _press_button == mouse.button_index:
		if mouse.button_index == MOUSE_BUTTON_LEFT \
				and not _panning and is_click(_press_pos, view_pos):
			get_viewport().set_input_as_handled()
			_handle_click_at(view_pos)
		_press_active = false
		_panning = false


## Wheel zoom (§4.3): 0.6×–1.5×, anchored at the cursor. A manual camera
## command — follow pauses until the acting unit's next turn.
func _apply_wheel(wheel_delta: float, anchor_view: Vector2) -> void:
	var result := zoom_at(_cam_zoom, wheel_delta, anchor_view, _cam_pos)
	_cam_zoom = float(result["zoom"])
	_cam_pos = result["cam"]
	_follow = false
	_queue_redraw()


func _on_mouse_motion(motion: InputEventMouseMotion) -> void:
	if not _press_active:
		return
	var view_pos := motion.position - _grid_view.global_position
	if not _panning and not is_click(_press_pos, view_pos):
		_panning = true
		_follow = false
	if _panning:
		get_viewport().set_input_as_handled()
		_cam_pos = clamp_cam(
			_cam_pos - motion.relative / _cam_zoom, _cam_zoom)
		_queue_redraw()


## One click in view coordinates (§4.3, §4.7.1): a legal velocity vector moves
## (movement unspent), an enemy token takes the default action, anything else
## parks the cursor.
func _handle_click_at(view_pos: Vector2) -> void:
	var world := screen_to_world(view_pos, _cam_pos, _cam_zoom)
	var cell := Vector2i(int(floor(world.x / TILE_PX)),
		int(floor(world.y / TILE_PX)))
	if not BattleSimLib.in_grid(cell):
		return
	_cursor = cell
	_cursor_visible = true
	var unit := selected_unit()
	if unit.is_empty():
		_bind()
		_queue_redraw()
		return
	# 1. A pick on a reachable velocity vector moves (§4.3 "click a legal
	#    vector"); apply_velocity refuses once the turn's movement is spent,
	#    so the pick falls through to the enemy-token path then.
	var vel: Vector2i = _overlay.pick_velocity(world)
	if vel != BattleSimLib.NO_CELL:
		if _apply_unit_velocity(unit, vel):
			return
	# 2. An enemy token: the default action (§4.7.1).
	for enemy in sim.living_units(BattleSimLib.SIDE_ENEMY):
		if sim.unit_cell(enemy) == cell:
			_target = enemy
			_default_action(unit, enemy)
			return
	_bind()
	_queue_redraw()


## Arrows cycle the `legal_velocities()` enumeration (§4.3); the highlighted
## entry thickens on the overlay and `Enter` applies it.
func _cycle_velocity(direction: int) -> void:
	if _movement_spent or _legal_velocities.is_empty():
		return
	_velocity_index = posmod(
		_velocity_index + direction, _legal_velocities.size())
	_bind_highlights()
	_queue_redraw()


## `Enter` confirms the cycled velocity (§4.3). Without a cycled entry (or
## with the movement spent) it does nothing — the action phase has its own
## buttons and enemy-token clicks.
func _confirm_velocity() -> void:
	var unit := selected_unit()
	if unit.is_empty() or _movement_spent:
		return
	var vel := cycled_velocity()
	if vel == BattleSimLib.NO_CELL:
		return
	_apply_unit_velocity(unit, vel)


## §4.7.1 "default action against it (cannon with the §4.11.8 side pick, else
## ram, else board)".
func _default_action(unit: Dictionary, enemy: Dictionary) -> void:
	if sim.can_cannon(unit, enemy):
		perform_action("cannon", enemy)
	elif sim.can_ram(unit, enemy):
		perform_action("ram", enemy)
	elif sim.can_board(unit, enemy):
		perform_action("board", enemy)
	else:
		_bind()
		_queue_redraw()


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
	_queue_redraw()


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
## from the landed `battle.*` inventory are used.
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
			if sim.side_cannons(unit, BattleSimLib.BROADSIDE_PORT) < 1 \
					and sim.side_cannons(unit, BattleSimLib.BROADSIDE_STARBOARD) < 1:
				return "battle.reason.no_cannons"
			var resolved := target
			if resolved.is_empty():
				resolved = _resolve_target(unit, "cannon")
			if resolved.is_empty():
				return "battle.target.none"
			var reloaded := int(sim.round_number()) \
					>= int(unit.get("reload_port", 1)) \
				or int(sim.round_number()) \
					>= int(unit.get("reload_starboard", 1))
			if not reloaded:
				return "battle.reload"
			if not sim.can_cannon(unit, resolved):
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
	# Phase 8 (W4 master micro-integration): the enemy fleet's canon captain
	# rides the outcome so `BattleRewards.apply`'s lifecycle hooks fire —
	# the encounter descriptor's `captain_id` (written by the world-side
	# encounter builder over the fleet dict) is the source of truth.
	last_outcome["captain_id"] = str(encounter.get("captain_id", ""))

	# **Sandbox zero-write branch (Phase 9, docs/60-* §4.12.4, decision 15).**
	# Steps 2/3/4 and step 5's world writes are skipped ENTIRELY: no
	# `BattleResult.apply`, no `BattleRewards.apply`, no `NpcFleets` mutation,
	# no phase-3 hooks, no `GameState.set_world_tile`, and no
	# `battle_finished` broadcast (the S3 world scene consumes that signal to
	# remove fleets and resume routing — emitting it would violate the
	# zero-write contract whenever S3 happens to be listening). The dialog is
	# READ-ONLY (it renders only the outcome block's own numbers), and the
	# `Continue` edge routes back to S21 (`return_scene`). A sandbox battle is
	# observed through `battle_closed` / [member last_outcome].
	if is_sandbox_battle():
		battle_closed.emit(last_outcome)
		_show_after_action()
		return

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

	# 3b. Phase 7 rare drop (60-* §4.11.13): a named pirate's captain sunk or
	# captured (any fleet-removed outcome — victory/surrender; a retreat keeps
	# the fleet) credits that captain's `named_pirates.json` `drop` item
	# through the standing replace rule. Guarded, like every aftermath hook.
	var end_result := str(last_outcome.get("result", ""))
	if end_result == BattleSimLib.RESULT_VICTORY \
			or end_result == BattleSimLib.RESULT_SURRENDER:
		var captain: Dictionary = (encounter.get("captain", {}) as Dictionary) \
			if (encounter.get("captain", {}) is Dictionary) else {}
		if rewards_module != null \
				and rewards_module.has_method("apply_named_drop") \
				and not str(captain.get("named_id", "")).is_empty():
			rewards_module.call("apply_named_drop",
				last_outcome, str(captain.get("named_id", "")))

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
## pre-computed by the engine / tasks C and G). Phase-10 W5-A: the opposing
## flagship captain's bust rides beside the result line (the §4.9 portrait
## slot; null ⇒ exactly the text-only dialog).
func _show_after_action() -> void:
	_after_title.text = _t("battle.after.title")
	for child in _after_lines.get_children():
		_after_lines.remove_child(child)
		child.queue_free()
	var bust := _after_action_portrait()
	var texts := _after_action_texts()
	for index in texts.size():
		var label := Label.new()
		label.text = texts[index] as String
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = 600
		if index == 0 and bust != null:
			# The §4.9 portrait slot: the 72×96 bust (§4.8.8, nearest) beside
			# the result line — the outcome text wraps into the row's rest.
			var row := HBoxContainer.new()
			row.name = "PortraitRow"
			var rect := TextureRect.new()
			rect.name = "Portrait"
			rect.texture = bust
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			rect.custom_minimum_size = Vector2(
				float(PortraitComposerLib.CANVAS_W),
				float(PortraitComposerLib.CANVAS_H))
			rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(rect)
			label.custom_minimum_size.x = 0
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.size_flags_vertical = Control.SIZE_FILL
			row.add_child(label)
			_after_lines.add_child(row)
			continue
		_after_lines.add_child(label)
	_after_continue.text = I18n.t_key("ui.ok")
	_after_action.visible = true
	if not _after_action.is_in_group("modal_overlay"):
		_after_action.add_to_group("modal_overlay")
	_after_continue.grab_focus()


## The after-action portrait slot (Phase-10 decision 10): the W4-D composer's
## bust of the opposing flagship captain (`encounter.captain_id` → the canon
## card; the override-wins ladder inside). EVERY miss — no id, unknown
## captain, missing part sheets — returns null and the dialog stays exactly
## text-only. Never crashes, never invents a placeholder of its own.
func _after_action_portrait() -> Texture2D:
	var captain_id := str(encounter.get("captain_id", ""))
	if captain_id.is_empty():
		return null
	var person: Dictionary = CaptainsLib.captain(captain_id)
	if person.is_empty():
		return null
	return PortraitComposerLib.portrait_texture(person)


## The `battle.after.*` lines in wireframe order: loot gold, XP, captures,
## scuttles, overflow, losses, preceded by the `battle.result.*` line
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
## §4.11.9 groups (`defeat_sunk` and `defeat_captured` share the one defeat key;
## a `stall` is its own `battle.result.stall` entry in the landed table).
func _result_text(result: String) -> String:
	match result:
		BattleSimLib.RESULT_VICTORY:
			return _t("battle.result.victory")
		BattleSimLib.RESULT_RETREAT:
			return _t("battle.result.retreat")
		BattleSimLib.RESULT_SURRENDER:
			return _t("battle.result.surrender")
		BattleSimLib.RESULT_STALL:
			return _t("battle.result.stall")
		_:
			return _t("battle.result.defeat")


## §4.7.1 "loot gold, captured ships, XP and reputation deltas", through the
## `battle.after.rep` key.
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
## `scuttled_ships` / `lost_ships`, hull ids) wins over the instance list
## when present, so a post-merge screen reports what the seams applied.
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
	if is_sandbox_battle():
		# §4.12.4 sandbox branch: `Continue` is the S10 → S21 edge (the
		# editor restores its configuration from
		# `battle_sandbox.gd.last_config`). The S9 game-over screen can never
		# be involved — step 2 (the `gameover.*` emitter) was skipped.
		_route_to_world()
		return
	if game_over_raised:
		# §4.12.4 step 5: *not* S3 — S9 is the terminal screen for this run.
		_show_game_over()
		return
	_route_to_world()


## True when this battle was opened from a S21 sandbox fixture
## (`encounter.sandbox == true`, docs/60-* §4.12.4). Guarding every skip on
## this flag keeps a normal battle's sequence byte-identical to Phase 8.
func is_sandbox_battle() -> bool:
	return bool(encounter.get("sandbox", false))


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


## The scene the after-action dialog's `Continue` opens. A sandbox battle
## returns to the S21 editor (§4.12.4 zero-write branch); a tournament bout
## goes back to the host palace, which starts the next bout (`70-*` §4.9.7:
## "3 successive battles", no repairs between rounds); every other battle
## returns to S3 (§4.12.4 step 5).
func return_scene() -> String:
	if is_sandbox_battle():
		return SANDBOX_SCENE
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
## `data/ui_strings.json` entry, resolved through the shared formatter (§4.4
## `{name}` placeholders). This screen never carries its own copy of a
## player-facing string (AGENTS.md i18n hard rule); a missing key is a data
## bug and renders `I18n.t_key()`'s `<key>` marker, which the data validator
## prevents in shipped data. The preview keys ride the screen's
## `FALLBACK_STRINGS` table (the W5-C pattern) until the residual merge.
func _t(key: String, values: Dictionary = {}) -> String:
	if not DataLoader.ui_strings.has(key) and FALLBACK_STRINGS.has(key):
		var text := I18n.t(FALLBACK_STRINGS.get(key, {}))
		for name in values:
			text = text.replace("{%s}" % name, str(values[name]))
		return text
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
	_queue_redraw()
	if _after_action.visible:
		_show_after_action()
	# §4.7.1 (W6-A): the intro preview re-renders in the new locale.
	if _preview != null and _preview.visible:
		var captain_id := str(encounter.get("captain_id", ""))
		if not captain_id.is_empty():
			_show_captain_preview(captain_id)


# --- Player auto policy (the headless driver of run_to_completion) ---------

## One player turn using the **same** legality order the buttons use: fire,
## else board, else ram, else close in with a legal velocity and act, else
## hold. Movement rides `apply_velocity` (§4.12.1); the approach velocity is
## the `legal_velocities()` endpoint minimising (Chebyshev, Manhattan) to the
## nearest enemy, ties broken by the §4.11.8 enumeration order — a converging
## close-in that never drifts past the target.
func _player_auto_action(unit: Dictionary) -> void:
	_target = {}
	if _act_best(unit):
		return
	var vel := _approach_velocity(unit)
	if vel == BattleSimLib.NO_CELL:
		# W3 bounce-back: under inertia an overshooting ship has no
		# Chebyshev/Manhattan-improving pick for several rounds — come about
		# instead (turn toward the nearest enemy) so a headless driver cannot
		# freeze a winnable battle into a §4.11.9 stall.
		vel = _come_about_velocity(unit)
	if vel != BattleSimLib.NO_CELL and sim.apply_velocity(unit, vel):
		unit = selected_unit()
		if unit.is_empty() or _act_best(unit):
			return
	# Nothing to shoot, nothing to board: pass the turn.
	perform_action("hold")


## The legal velocity whose resulting heading nearest aligns with the bearing
## to the nearest enemy (unsigned bucket steps, ties = the smaller landing
## Chebyshev, then enumeration order). Deliberately NO "must not lose
## ground" filter: a ship carrying velocity v turning 45° projects further
## from an abeam-behind target EVERY time — requiring a non-increase at
## high v freezes the ship pointing away forever (the bout-1 stall). A
## come-about accepts the temporary increase. NO_CELL when no velocity
## qualifies.
func _come_about_velocity(unit: Dictionary) -> Vector2i:
	var enemies: Array = sim.living_units(BattleSimLib.SIDE_ENEMY)
	if enemies.is_empty():
		return BattleSimLib.NO_CELL
	var nearest_cell: Vector2i = sim.unit_cell(enemies[0])
	var best_chebyshev := _distance(sim.unit_cell(unit), nearest_cell)
	for enemy in enemies:
		var distance := _distance(sim.unit_cell(unit), sim.unit_cell(enemy))
		if distance < best_chebyshev:
			best_chebyshev = distance
			nearest_cell = sim.unit_cell(enemy)
	var from: Vector2i = sim.unit_cell(unit)
	var bearing := int(BattleSimLib.heading8_of(nearest_cell - from))
	var best_vel := BattleSimLib.NO_CELL
	var best_steps := 9
	var best_landing := 1 << 30
	for vel in sim.legal_velocities(unit):
		var step: Vector2i = vel
		if step == Vector2i.ZERO:
			continue
		var endpoint: Vector2i = from + step
		if not BattleSimLib.in_grid(endpoint):
			continue
		var steps := mini(int(BattleSimLib.bucket_distance(
			int(BattleSimLib.heading8_of(step)), bearing)), 4)
		var landing := _distance(endpoint, nearest_cell)
		if steps < best_steps or (steps == best_steps
				and landing < best_landing):
			best_steps = steps
			best_landing = landing
			best_vel = step
	return best_vel


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


## The `legal_velocities()` endpoint minimising (Chebyshev, Manhattan) to the
## nearest enemy — the (Chebyshev, Manhattan) minimum, ties broken by the
## enumeration order (§4.11.8's tie-break). Chebyshev-only first-match would
## zigzag laterally (any diagonal that shaves the Chebyshev wins even while
## wasting Manhattan), which cannot close a 43-tile gulf inside the round cap;
## the Manhattan term keeps the close-in straight. NO_CELL when nothing
## improves (the ship holds instead).
func _approach_velocity(unit: Dictionary) -> Vector2i:
	var enemies: Array = sim.living_units(BattleSimLib.SIDE_ENEMY)
	if enemies.is_empty():
		return BattleSimLib.NO_CELL
	var nearest_cell: Vector2i = sim.unit_cell(enemies[0])
	var best_chebyshev := _distance(sim.unit_cell(unit), nearest_cell)
	for enemy in enemies:
		var distance := _distance(sim.unit_cell(unit), sim.unit_cell(enemy))
		if distance < best_chebyshev:
			best_chebyshev = distance
			nearest_cell = sim.unit_cell(enemy)
	var best_vel := BattleSimLib.NO_CELL
	var best_score := Vector2i(best_chebyshev, _manhattan(
		sim.unit_cell(unit), nearest_cell))
	for vel in sim.legal_velocities(unit):
		if vel == Vector2i.ZERO:
			continue
		var endpoint: Vector2i = sim.unit_cell(unit) + vel
		if not BattleSimLib.in_grid(endpoint):
			continue
		var score := Vector2i(_distance(endpoint, nearest_cell),
			_manhattan(endpoint, nearest_cell))
		if score.x < best_score.x or (score.x == best_score.x
				and score.y < best_score.y):
			best_score = score
			best_vel = vel
	return best_vel


func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


func _distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
