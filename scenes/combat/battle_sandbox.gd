extends Control
## S21 naval-battle sandbox (Phase 9, decision 15; docs/80-UI-UX.md §4.7.16,
## docs/60-COMBAT.md §4.12.1 `player_stats`, §4.12.4 zero-write branch,
## docs/10-DATA-SCHEMA.md §7.12 `sandbox.*` inventory).
##
## A full naval-battle editor opened from S1 (the 海战 button) and a
## **zero-write** surface: nothing here ever writes the save, `GameState`,
## `NpcFleets`, the phase-3 hooks or world routing. 开战 assembles a fixture
## encounter (`{sandbox: true, player_ships, enemy_ships, day, gold, seed,
## weather, player_stats}`) on `GameState.pending_encounter` — the SAME seam
## `world_map.gd` uses — and routes to S10; the battle's read-only after-action
## dialog returns here with the configuration kept in
## [member last_config] (a runtime-only static, never saved — that is what
## "configuration kept on return" means without touching `GameState`).
##
## **Forward-compat contract** (`80-*` §4.7.16): the export schema declares
## ALL planned fields from day one — `weather / wind_dir / current /
## deployment / morale / ai_level / archetype / formation`. W4 landed the
## morale keys (`player_morale` / `enemy_morale` ride the fixture as §4.12.1
## config keys); W4 + W5-C landed the enemy profile overrides — `formation`,
## `ai_level` and `archetype` ride the fixture ONLY when the editor leaves
## the `ai_profiles` row's own value (the true-override emission in
## [method build_encounter]; the screen folds them into the battle's profile
## row). Still dormant: wind_dir / current / deployment stay editor + export
## values (the §4.12.1 wind/current keys and the sim `deployment` variant
## are engine-side; the S21 conditions row keeps them forward-compat).
##
## **Strings** (`10-*` §7.12): every label comes from the `sandbox.*` /
## `battle.*` / `char.attr.*` / `world.weather.*` / `shipyard.slot.*`
## families through [method _t]. W2-B authors the `sandbox.*` values; until
## that merge each read falls back to the raw key or the raw value id (the
## `battle_screen._reason_text` convention) — no player-facing string is
## invented here.
##
## The whole editor is built in `_ready`; the `.tscn` carries the root node
## only. Phase-10 W5-B sweep (80-* §4.9): the side panels are the kit `frame`
## atom, the fleet/action buttons the kit `button` atom, panel chrome and
## semantic text colors ride the shared theme (Label variations
## `Accent`/`Warn`/`Dim`) — this file carries NO per-screen styling (the
## sweep-guard audit `tools/test_ui_styling_audit.gd` pins that). The three
## §4.7.16 regions (player panel / enemy panel / conditions strip) sit at
## the pinned 1920×1080 full-surface geometry (2026-11-09 horizontal-bands
## re-layout — the same-day fleet/editor split was WITHDRAWN: the §4.8.8
## tile grid floors every sheeted control at 2×2 tiles, so a SpinBox
## measures ~96px wide and no side column can hold a ship line):
## the player panel (16, 72) 1888×416 — row 1 = the captain stats (five
## attributes, weapon/armor, the short-label morale) then FIVE ONE-LINE
## ship rows, every field on one 64px line; the enemy panel (16, 496)
## 1888×416 — row 1 = the enemy profile (kind, compose, flagship captain,
## ai_level, archetype, formation, morale) then its five one-line ship
## rows; the conditions strip (16, 912) 1888×168 — the encounter
## conditions row + the four action buttons right-aligned. All five ships
## per side are visible with NO scrolling. Field labels are never
## `clip_text`ed: each column floor (the `LABEL_W*` constants) fits the
## longest localized string, and the layout regression test pins the live
## control rects for both locales.

const PaletteLib := preload("res://scripts/palette.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
## Phase 12 (docs/80-* §4.8.9): the chrome registers under the sandbox's
## layout id.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## This screen's layout id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "sandbox"
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

const TITLE_SCENE := "res://scenes/title/title_screen.tscn"
const BATTLE_SCENE := "res://scenes/combat/battle_screen.tscn"

## Editor limits (docs/80-* §4.7.16 clamp rules).
const MAX_SHIPS := 5
const MIN_SHIPS := 1
const ATTR_MIN := 0
const ATTR_MAX := 100
const MORALE_MIN := 0
const MORALE_MAX := 100
const CURRENT_STRENGTH_MAX := 3
const DAY_MIN := 1
const SEED_MAX := 999999999
## Toast seconds (80-* §4.7: toasts are transient, 2.5 s).
const TOAST_SECONDS := 2.5

## Field-label column floors (px, the 2026-11-09 horizontal-bands
## re-layout — 80-* §4.8 grid). Labels are unclipped, so the floor is a
## column width, not a truncation: each constant fits the LONGEST
## localized string of its column (the EN forms — "Wind direction",
## "Deployment", "Constitution" — are the longest; zh is always shorter).
const LABEL_W_LONG := 128
const LABEL_W_MID := 100
const LABEL_W_ATTR := 104
const LABEL_W_STD := 72
const LABEL_W_SHORT := 56
const LABEL_W_DURABILITY := 88
const LABEL_W_MORALE := 60
const LABEL_W_STRENGTH := 88
const ROW_HEADER_W := 64

## The pinned §4.7.16 region rects (1920×1080 horizontal-bands re-layout,
## 2026-11-09): player panel, enemy panel, conditions strip.
const PLAYER_PANEL_RECT := Rect2(16, 72, 1888, 416)
const ENEMY_PANEL_RECT := Rect2(16, 496, 1888, 416)
const CONDITIONS_RECT := Rect2(16, 912, 1888, 168)

## Phase 12 (docs/80-* §4.8.9): the flat interior slots — the panel inset,
## the 64px row pitch (one editors row + five one-line ship rows per
## panel), the rows region's height, and the cell gap (the deleted
## HBoxes' separation).
const PANEL_PAD := 16.0
const ROW_PITCH := 64.0
const ROWS_REGION_H := 5.0 * ROW_PITCH
const CELL_GAP := 8.0

## The nine battle kinds (`10-*` §4.10 `ai_profiles` key set / `60-*` §4.9a):
## the 7 pass-through kinds + `navy` (hunter battles) + `tournament`.
const KINDS: Array[String] = [
	"trader", "coaster", "courier", "patrol", "privateer", "pirate",
	"treasure", "navy", "tournament",
]
const ARCHETYPES: Array[String] = ["aggressive", "balanced", "cautious"]
const FORMATIONS: Array[String] = ["line_ahead", "column", "screen", "swarm"]
## `60-*` §4.9c: 0 = T2 deterministic greedy, 1 = T3 one-ply lookahead.
const AI_LEVELS: Array = [0, 1]
const WEATHERS: Array[String] = ["calm", "fair", "strong", "storm"]
## `20-*` §4.7.1 wind-FROM tokens + the variable reading (`VAR` is an editor
## choice the engine's 9A consumer may resolve; the exported id stays a token
## of this set).
const WIND_DIRS: Array[String] = [
	"N", "NE", "E", "SE", "S", "SW", "W", "NW", "VAR",
]
const CURRENT_DIRS: Array[String] = [
	"N", "NE", "E", "SE", "S", "SW", "W", "NW",
]
const SEED_MODES: Array[String] = ["fixed", "random", "auto"]
const DEPLOYMENTS: Array[String] = ["standard", "tournament"]
## `50-*` §2.1 attribute keys (the labels reuse `char.attr.*`).
const ATTRIBUTES: Array[String] = [
	"constitution", "intellect", "charisma", "courage", "luck",
]
## The equipment slot the stats editor exposes (`10-*` §7.9 / `60-*` §4.11.12);
## the per-ship slots (figurehead / sail) are fixed in `_make_ship_row`.
const STATS_EQUIPMENT_SLOTS: Array = ["weapon", "armor"]
## The fixture carries no contact tile, so the §4.11.1 auto-seed formula
## evaluates at the origin — a deterministic, documented contract for
## `seed_mode = auto` (day + 0 + 0 + 0 + fleet.size() × 17).
const FIXTURE_CONTACT := Vector2i.ZERO

## **Doc-pinned profile fallback** (`10-*` §4.10 normative value table — the
## three editor-facing keys only). Used only while
## `DataLoader.npc_config.ai_profiles` is absent (the W2-A data merge); at
## runtime the data wins. `hunter` → the `navy` row (correction 8).
const DOC_PROFILE_FALLBACK: Dictionary = {
	"pirate": {"archetype": "aggressive", "formation": "swarm", "ai_level": 1},
	"privateer": {"archetype": "aggressive", "formation": "swarm", "ai_level": 1},
	"patrol": {"archetype": "balanced", "formation": "line_ahead", "ai_level": 1},
	"navy": {"archetype": "balanced", "formation": "line_ahead", "ai_level": 1},
	"tournament": {"archetype": "balanced", "formation": "line_ahead", "ai_level": 1},
	"treasure": {"archetype": "cautious", "formation": "screen", "ai_level": 0},
	"trader": {"archetype": "cautious", "formation": "column", "ai_level": 0},
	"coaster": {"archetype": "cautious", "formation": "column", "ai_level": 0},
	"courier": {"archetype": "cautious", "formation": "column", "ai_level": 0},
}

## The configuration carried across the S10 round-trip: written by
## [method start_battle] (开战), read in `_ready` to restore the editors.
## Runtime-only — never saved (`80-*` §4.7.16 "configuration kept on return"
## without a `GameState` write; preset persistence is out of scope, S4).
static var last_config: Dictionary = {}

## Routing seam (the `title_screen.route_to_nationality` convention): a test
## sets this false so the Esc edge records only the intent.
var route_to_title: bool = true

## The toast generation in flight, so a replaced toast does not hide its
## successor (the `market_screen` convention).
var _toast_generation := 0
## True while code is programming widgets (guards the re-entrant
## `text_changed` / `item_selected` handlers, the `shipyard_screen` pattern).
var _programming := false

# --- Widget handles (filled in `_ready`; tests read them) -------------------

var _background: Panel
var _title: Label
var _zero_write: Label
var _back_hint: Label
var _toast: Label
var _player_panel: Control
var _enemy_panel: Control
var _player_header: Label
var _enemy_header: Label
## Phase 12 (docs/80-* §4.8.9): the deleted flow containers are plain
## Controls — the editors rows, the ship-rows regions and the conditions
## grid/actions are absolutely-placed plain Controls at their data rects
## (the 16px-inset content columns are deleted too — 2026-11-10: the
## interiors parent straight to their panels so the registered parent IS
## the Godot parent).
var _conditions_panel: Panel
var _player_rows_box: Control
var _enemy_rows_box: Control
var _player_stats_row_h: Control
var _enemy_profile_row_h: Control
var _player_add: Button
var _player_remove: Button
var _enemy_add: Button
var _enemy_remove: Button
var _attribute_spins: Dictionary = {}
var _weapon_option: OptionButton
var _armor_option: OptionButton
var _player_morale_spin: SpinBox
var _kind_option: OptionButton
var _compose_check: CheckBox
var _enemy_captain_edit: LineEdit
var _ai_level_option: OptionButton
var _archetype_option: OptionButton
var _formation_option: OptionButton
var _enemy_morale_spin: SpinBox
var _day_spin: SpinBox
var _seed_mode_option: OptionButton
var _seed_spin: SpinBox
var _weather_option: OptionButton
var _wind_option: OptionButton
var _current_dir_option: OptionButton
var _current_strength_spin: SpinBox
var _deployment_option: OptionButton
var _start_button: Button
var _random_all_button: Button
var _import_button: Button
var _export_button: Button
var _conditions_grid: Control
var _conditions_actions: Control

## Per-ship widget rows: `{root, type, cannons, crew, durability, figurehead,
## sail, captain}` — fleet-index order.
var _player_rows: Array = []
var _enemy_rows: Array = []


func _ready() -> void:
	_build_static_widgets()
	_build_panels()
	_build_conditions_row()
	# Phase 12 (docs/80-* §4.8.9): the S21 chrome's persistent controls
	# register their stable ids and activate at build. The flow containers
	# are DELETED — the region panels are plain Panels, every editors row /
	# ship line / conditions cell an absolutely-placed plain child at its
	# authored tile rect. The panels' INTERIORS register too (the
	# 2026-11-10 user report: the studios' ids stopped at the plates, so
	# the rows/buttons inside were unmodifiable): the editors rows, the
	# +/− pair, the ship-rows regions and the conditions grid/actions —
	# the Box/Headers stay unregistered (inert 16px pads: the interiors'
	# parent space), and the per-ship lines register as list members of
	# the `player_rows`/`enemy_rows` blocks.
	_register_chrome_ids()
	RegistryLib.screen_active(SCREEN_ID, self)
	# The S10 round-trip restore (§4.7.16 "configuration kept on return");
	# otherwise the doc-example defaults seeded from the live run's reads.
	var restored: Dictionary = last_config if last_config is Dictionary else {}
	if restored.is_empty():
		restored = _default_config()
	_load_config(restored)


## The id pass — the fixed static widgets + the three region panels + the
## strip's action buttons (the deep editor fields stay unregistered for
## now — see the _ready note).
func _register_chrome_ids() -> void:
	RegistryLib.register(SCREEN_ID, _background, "background",
		{"role": "panel"})
	RegistryLib.register(SCREEN_ID, _title, "title")
	RegistryLib.register(SCREEN_ID, _zero_write, "zero_write")
	RegistryLib.register(SCREEN_ID, _back_hint, "back_hint")
	RegistryLib.register(SCREEN_ID, _toast, "toast")
	RegistryLib.register(SCREEN_ID, _player_panel, "player_panel",
		{"role": "panel"})
	RegistryLib.register(SCREEN_ID, _enemy_panel, "enemy_panel",
		{"role": "panel"})
	RegistryLib.register(SCREEN_ID, _conditions_panel, "conditions_panel",
		{"role": "panel"})
	if _start_button != null:
		RegistryLib.register(SCREEN_ID, _start_button, "actions.start",
			{"role": "button"})
	if _random_all_button != null:
		RegistryLib.register(SCREEN_ID, _random_all_button, "actions.random",
			{"role": "button"})
	if _import_button != null:
		RegistryLib.register(SCREEN_ID, _import_button, "actions.import",
			{"role": "button"})
	if _export_button != null:
		RegistryLib.register(SCREEN_ID, _export_button, "actions.export",
			{"role": "button"})
	# The panel interiors — each at its parent-local rect (the unregistered
	# Box/Headers are the interiors' parent space; the rows' data is
	# parent-relative by the capture rule).
	if _player_stats_row_h != null:
		RegistryLib.register(SCREEN_ID, _player_stats_row_h,
			"player_panel.stats_row", {"role": "panel"})
	if _enemy_profile_row_h != null:
		RegistryLib.register(SCREEN_ID, _enemy_profile_row_h,
			"enemy_panel.profile_row", {"role": "panel"})
	if _player_rows_box != null:
		RegistryLib.register(SCREEN_ID, _player_rows_box,
			"player_panel.rows", {"role": "panel"})
	if _enemy_rows_box != null:
		RegistryLib.register(SCREEN_ID, _enemy_rows_box,
			"enemy_panel.rows", {"role": "panel"})
	if _player_add != null:
		RegistryLib.register(SCREEN_ID, _player_add,
			"player_panel.stats_row.add", {"role": "button"})
	if _player_remove != null:
		RegistryLib.register(SCREEN_ID, _player_remove,
			"player_panel.stats_row.remove", {"role": "button"})
	if _enemy_add != null:
		RegistryLib.register(SCREEN_ID, _enemy_add,
			"enemy_panel.profile_row.add", {"role": "button"})
	if _enemy_remove != null:
		RegistryLib.register(SCREEN_ID, _enemy_remove,
			"enemy_panel.profile_row.remove", {"role": "button"})
	if _conditions_grid != null:
		RegistryLib.register(SCREEN_ID, _conditions_grid,
			"conditions_panel.grid", {"role": "panel"})
	if _conditions_actions != null:
		RegistryLib.register(SCREEN_ID, _conditions_actions,
			"conditions_panel.actions", {"role": "panel"})


# --- Build ------------------------------------------------------------------

func _build_static_widgets() -> void:
	# §4.8 Skin coverage (amended 2026-11-05 + the 2026-11-09
	# third-tileset amendment): the fullscreen surface rides the
	# `Backdrop` panel variation — the `frame` tileset's ocean-chart
	# water, the pinned navy flat fill in the reduced-graphics fallback.
	_background = Panel.new()
	_background.name = "Background"
	_background.theme_type_variation = "Backdrop"
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)

	# §4.9 Label row: TEXT is the theme default — the title needs no styling.
	_title = Label.new()
	_title.name = "Title"
	_title.text = _t("sandbox.title")
	_title.position = Vector2(16, 8)
	_title.size = Vector2(640, 32)
	add_child(_title)

	# The persistent zero-write notice (§4.7.16) — always visible; the WARN
	# tint rides the theme's `Warn` Label variation (§4.9 sweep).
	_zero_write = Label.new()
	_zero_write.name = "ZeroWrite"
	_zero_write.text = _t("sandbox.zero_write")
	_zero_write.theme_type_variation = "Warn"
	_zero_write.position = Vector2(16, 42)
	_zero_write.size = Vector2(900, 20)
	add_child(_zero_write)

	# `Esc` → S1 (§4.2); the corner hint names the edge, right-aligned to the
	# full 1920 surface. Secondary text rides the theme's `Dim` variation;
	# the box is sized for the default font (the per-screen font-size
	# overrides retired with the §4.9 sweep).
	_back_hint = Label.new()
	_back_hint.name = "BackHint"
	_back_hint.text = "Esc · %s" % _t("sandbox.back")
	_back_hint.theme_type_variation = "Dim"
	_back_hint.position = Vector2(1540, 12)
	_back_hint.size = Vector2(364, 20)
	_back_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_back_hint)

	_toast = Label.new()
	_toast.name = "Toast"
	_toast.visible = false
	# Bottom-center toast slot, riding the enemy panel's bottom edge just
	# above the conditions strip (y = 912; the horizontal-bands rects).
	_toast.position = Vector2(660, 890)
	_toast.size = Vector2(600, 22)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_toast)


func _build_panels() -> void:
	# The §4.7.16 regions: top = the player panel, middle = the enemy
	# panel — plain Panels at the pinned geometry (§4.9 sweep; the kit
	# frame's PanelContainer chrome retired with the flow tree), each
	# carrying a hidden header Label (the band rows carry no title line,
	# the title rides the panel tooltip) and a plain-Control content column
	# at the panel's 16px inset.
	var player := _panel_column("PlayerPanel", "sandbox.player",
		PLAYER_PANEL_RECT.position, PLAYER_PANEL_RECT.size)
	_player_panel = player["panel"]
	_player_header = player["header"]
	var enemy := _panel_column("EnemyPanel", "sandbox.enemy",
		ENEMY_PANEL_RECT.position, ENEMY_PANEL_RECT.size)
	_enemy_panel = enemy["panel"]
	_enemy_header = enemy["header"]

	# Row 1 = the shared editors row (built FIRST so the ship rows
	# follow it); its right end carries the compact +/− fleet buttons.
	_build_player_stats_row()
	_build_enemy_profile_row()

	# The one-line ship rows follow the editors row directly (no scroll:
	# five rows fit the pinned 416px panel by construction — the
	# horizontal-bands re-layout's whole point).
	_player_rows_box = _rows_box()
	_player_panel.add_child(_player_rows_box)
	_enemy_rows_box = _rows_box()
	_enemy_panel.add_child(_enemy_rows_box)
	_player_add = _fleet_button("sandbox.ship.add")
	_player_remove = _fleet_button("sandbox.ship.remove")
	_player_add.pressed.connect(func() -> void: add_ship_row("player"))
	_player_remove.pressed.connect(func() -> void: remove_ship_row("player"))
	_editor_row_cell(_player_stats_row_h, _player_add, 0)
	_editor_row_cell(_player_stats_row_h, _player_remove, 1)
	_enemy_add = _fleet_button("sandbox.ship.add")
	_enemy_remove = _fleet_button("sandbox.ship.remove")
	_enemy_add.pressed.connect(func() -> void: add_ship_row("enemy"))
	_enemy_remove.pressed.connect(func() -> void: remove_ship_row("enemy"))
	_editor_row_cell(_enemy_profile_row_h, _enemy_add, 0)
	_editor_row_cell(_enemy_profile_row_h, _enemy_remove, 1)
	_refresh_fleet_buttons()


## One side panel: a plain Panel at `at` × `panel_size` (the deleted kit
## frame's chrome is the theme's Panel stylebox, §4.9) carrying the hidden
## header Label. Returns `{panel, header}`. The former content-column
## Control (the 16px-inset Box) is DELETED (2026-11-10): the interiors
## parent straight to the panel so each element's registered parent IS
## its Godot parent — the capture/apply coordinate spaces agree (the
## unregistered Box's 16px offset made the tile rows ratchet +16px per
## capture round).
func _panel_column(panel_name: String, title_key: String, at: Vector2,
		panel_size: Vector2) -> Dictionary:
	var panel := Panel.new()
	panel.name = panel_name
	panel.position = at
	panel.size = panel_size
	panel.tooltip_text = _t(title_key)
	add_child(panel)
	var header := Label.new()
	header.name = "Header"
	header.text = _t(title_key)
	header.theme_type_variation = "Accent"
	header.visible = false
	# Anchors, not a fixed rect: the header tracks the panel's COMMITTED
	# width (the user's arrangement narrowed the panel — a build-px size
	# would overflow it after apply; this inert label is unregistered
	# chrome, so anchors keep it inside at any committed width).
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_left = PANEL_PAD
	header.offset_right = -PANEL_PAD
	header.offset_top = PANEL_PAD
	header.offset_bottom = PANEL_PAD + float(PaletteLib.ROW_H)
	panel.add_child(header)
	return {"panel": panel, "header": header}


## The ship-rows column of a side panel: a plain Control under the editors
## row (five 64px lines fit the pinned panel — the horizontal-bands layout
## needs no scroll). The rows stack at the fixed 64px pitch.
func _rows_box() -> Control:
	# A ScrollContainer viewport (the 2026-11-11 user request): the five
	# ship lines scroll when the region is resized below the stack —
	# the same clipped-viewport pattern as the market's goods_scroll.
	# The CONTENT node is a plain Control sized to the stacked extent;
	# the members are scroll-owned (never floored, never clamped,
	# `clipped` in the tree payload).
	var scroll := ScrollContainer.new()
	scroll.name = "Rows"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Panel-local 16px pad + one editors row down, pre-apply (the data
	# row snaps this to its committed tile at activation).
	scroll.position = Vector2(PANEL_PAD, PANEL_PAD + ROW_PITCH)
	scroll.size = Vector2(_panel_box_w(), ROWS_REGION_H)
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = Vector2(_panel_box_w(), ROWS_REGION_H)
	scroll.add_child(content)
	return scroll


## Sizes a rows scroll's content node to the stacked extent — the scroll
## range follows the fleet count (the block width drives the row width).
func _sync_rows_content(side: String) -> void:
	var box := _player_rows_box if side == "player" else _enemy_rows_box
	var content: Control = box.get_child(0)
	var rect := RegistryLib.list_rect(SCREEN_ID,
			"player_rows" if side == "player" else "enemy_rows", 0)
	var w: float = rect.size.x if rect != Rect2() else _panel_box_w()
	# The scroll's stacked extent rides custom_minimum_size (the market's
	# goods_rows pattern): a ScrollContainer computes its scroll range
	# from the child's MINIMUM size — a plain size never engages it.
	content.custom_minimum_size = Vector2(w,
			maxf(1.0, float(ship_rows(side).size())) * ROW_PITCH)
	content.size = content.custom_minimum_size


## The content column's width (the panel's pinned rect minus the 16px
## insets) — the row cells' layout width.
func _panel_box_w() -> float:
	return PLAYER_PANEL_RECT.size.x - 2.0 * PANEL_PAD


## The compact per-side fleet button: a 2-tile-wide `+`/`-` glyph button
## (theme-styled, no per-screen styling; the localized label rides
## `tooltip_text` — the `sandbox.ship.add`/`sandbox.ship.remove` keys
## stay referenced).
func _fleet_button(key: String) -> Button:
	var button := Button.new()
	button.text = "+" if key == "sandbox.ship.add" else "-"
	button.tooltip_text = _t(key)
	button.custom_minimum_size = Vector2(64, float(PaletteLib.BUTTON_H))
	return button


## A field label on the band rows (TEXT is the theme's Label default,
## §4.9). Labels are NEVER clipped (`clip_text` stays off — the text grows
## the label), so `width` is a column floor that lines the field column
## up; pick it ≥ the longest localized string (the `LABEL_W*` constants).
## Phase 12: the label takes its absolute cell rect in the row (1 tile
## tall, vertically centered against the 2-tile sheeted controls on the
## line — the compose-beside contract).
func _field_label(text: String, width := 0) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, float(PaletteLib.ROW_H))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _spin(minimum: int, maximum: int, value: int, width := 100) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1
	spin.value = clampi(value, minimum, maximum)
	spin.custom_minimum_size = Vector2(width, float(PaletteLib.ROW_H))
	return spin


func _option(width := 150) -> OptionButton:
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(width, float(PaletteLib.ROW_H))
	return option


## Phase 12 — one absolutely-placed cell: adds `control` to `row` at the
## running cursor `x`, vertically centered in the 64px band, and returns
## the next cursor (`x + width + CELL_GAP`). The cell's rect is the whole
## contract: nothing is stretched, nothing re-flows.
func _row_cell(row: Control, control: Control, x: float, width: float,
		cell_h: float) -> float:
	row.add_child(control)
	control.position = Vector2(x, (ROW_PITCH - cell_h) / 2.0)
	control.size = Vector2(width, cell_h)
	return x + width + CELL_GAP


## Phase 12 — a label+control pair at the cursor: the label at its column
## floor width, the control beside it (the deleted HBox's compose-beside
## contract, cursor-computed). Returns the next cursor.
func _row_pair(row: Control, label: Label, control: Control, x: float,
		label_w: float, control_w: float) -> float:
	x = _row_cell(row, label, x, label_w, float(PaletteLib.ROW_H))
	return _row_cell(row, control, x, control_w, ROW_PITCH)


## Phase 12 (the 2026-11-10 user reports — down to "the children of
## stats_row.charisma"): one registered CELL per label+field pair, and
## the pair's TWO HALVES register inside it (`<cell id>.label` role
## plain, `<cell id>.field` role field). The whole row composes in
## TILES — the label takes its column-floor tile width at full cell
## height (the text vertically centers — the §4.8 look), the field takes
## its floor width beside it — so the build, the committed rows and the
## capture agree exactly. `cx` is the TILE cursor; returns the next one.
func _row_field(row: Control, id: String, label: Label, field: Control,
		cx: int, label_tw: int, field_tw: int) -> int:
	var tile := float(PaletteLib.CHROME_TILE)
	var cell := Control.new()
	cell.name = id.get_slice(".", id.get_slice_count(".") - 1)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.position = Vector2(cx * tile, 0)
	cell.size = Vector2((label_tw + field_tw) * tile, ROW_PITCH)
	label.position = Vector2.ZERO
	label.size = Vector2(label_tw * tile, ROW_PITCH)
	cell.add_child(label)
	field.position = Vector2(label_tw * tile, 0)
	field.size = Vector2(field_tw * tile, ROW_PITCH)
	cell.add_child(field)
	row.add_child(cell)
	RegistryLib.register(SCREEN_ID, cell, id, {"role": "field"})
	RegistryLib.register(SCREEN_ID, label, "%s.label" % id,
			{"role": "plain"})
	RegistryLib.register(SCREEN_ID, field, "%s.field" % id,
			{"role": "field"})
	return cx + label_tw + field_tw


## The bare variant — one self-labelled control (the compose checkbox)
## or a lone field (the fixed-seed spin) as one registered cell with its
## `.field` half.
func _row_field_bare(row: Control, id: String, field: Control, cx: int,
		field_tw: int) -> int:
	var tile := float(PaletteLib.CHROME_TILE)
	var cell := Control.new()
	cell.name = id.get_slice(".", id.get_slice_count(".") - 1)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.position = Vector2(cx * tile, 0)
	cell.size = Vector2(field_tw * tile, ROW_PITCH)
	field.position = Vector2.ZERO
	field.size = Vector2(field_tw * tile, ROW_PITCH)
	cell.add_child(field)
	row.add_child(cell)
	RegistryLib.register(SCREEN_ID, cell, id, {"role": "field"})
	RegistryLib.register(SCREEN_ID, field, "%s.field" % id,
			{"role": "field"})
	return cx + field_tw


## Phase 12 — the +/− fleet buttons ride the editors row's right end (the
## 2026-11-09 horizontal-bands contract): `slot` 0 is the left button of
## the pair, slot 1 the right one (64px buttons, one gap apart).
func _editor_row_cell(row: Control, button: Button, slot: int) -> void:
	var row_w: float = (row.size.x if row.size.x > 0.0 else _panel_box_w())
	var x := row_w - 2.0 * (64.0 + CELL_GAP) + float(slot) * (64.0 + CELL_GAP)
	row.add_child(button)
	button.position = Vector2(x, (ROW_PITCH - float(PaletteLib.BUTTON_H)) / 2.0)
	button.size = Vector2(64.0, float(PaletteLib.BUTTON_H))


## Fills `option` with `ids`, one item per id, labelled `key_prefix.<id>`
## (the raw id shows until W2-B authors the family). Selects the first.
func _fill_option(option: OptionButton, ids: Array, key_prefix: String) -> void:
	option.clear()
	for id in ids:
		option.add_item(_t_id(key_prefix, str(id)))
		option.set_item_metadata(option.item_count - 1, id)
	if not ids.is_empty():
		_select_option(option, ids[0])


func _select_option(option: OptionButton, id) -> void:
	for index in option.item_count:
		if str(option.get_item_metadata(index)) == str(id):
			option.select(index)
			return


func _option_value(option: OptionButton):
	if option.selected < 0 or option.selected >= option.item_count:
		return ""
	return option.get_item_metadata(option.selected)


## The editor's equipment options for `slot`: the empty slot first (the "—"
## marker), then the `data/equipment.json` items of that slot in file order.
## Items show their authored localized `name` (the `shipyard_screen` read
## convention — `10-*` i18n rule): raw machine ids would blow the dropdown's
## minimum width past the panel edge (the layout audit measured the longest
## figurehead id at 264 px; the longest localized name fits the 130 px slot).
func _fill_equipment_option(option: OptionButton, slot: String) -> void:
	option.clear()
	option.add_item("—")
	option.set_item_metadata(0, "")
	for id in _equipment_ids(slot):
		option.add_item(_equipment_label(id))
		option.set_item_metadata(option.item_count - 1, id)
	_select_option(option, "")


## An equipment item's player-facing label: the authored `name` (both
## locales) when it carries the active locale, else the raw id (the
## degrade-to-fallback convention).
func _equipment_label(id: String) -> String:
	for item in DataLoader.equipment_list:
		if item is Dictionary and str(item.get("id", "")) == id:
			var name = item.get("name", {})
			if name is Dictionary \
					and (name as Dictionary).has(I18n.get_locale()):
				return I18n.t(name)
			return id
	return id


func _equipment_ids(slot: String) -> Array:
	var out: Array = []
	var items = DataLoader.equipment_list
	if not (items is Array):
		return out
	for item in items:
		if item is Dictionary and str(item.get("slot", "")) == slot:
			out.append(str(item.get("id", "")))
	return out


func _hull_row(hull_id: String) -> Dictionary:
	for row in DataLoader.ship_types_list:
		if row is Dictionary and str(row.get("id", "")) == hull_id:
			return row
	return {}


## One editable ship row (§4.7.16, the 2026-11-09 horizontal-bands
## ONE-LINE re-layout): `Ship {index}` header + hull + cannons / crew /
## durability + escort captain (expanding) + the figurehead + sail slots —
## all seven fields on ONE 64px line, so the 5-ship fleet is fully visible
## with no scrolling. Every field is one unclipped label + one control.
## Phase 12: the line HBox is deleted — the row is a plain Control at its
## 64px slot; the cells take cursor-computed absolute slots, the four
## expanding cells (hull, captain, figurehead, sail) splitting the
## leftover width evenly (an authored computation, not a stretch flag).
func _make_ship_row(side: String) -> Dictionary:
	# The ship line composes its cells to the COMMITTED block width (the
	# data is the truth — the authored `_panel_box_w` fallback applies
	# only when the block is absent, e.g. a suite table without lists).
	var list_id := "player_rows" if side == "player" else "enemy_rows"
	var row_w := _panel_box_w()
	var block_rect := RegistryLib.list_rect(SCREEN_ID, list_id, 0)
	if block_rect != Rect2():
		row_w = block_rect.size.x
	var line := Control.new()
	line.name = "%sShip%d" % [side.capitalize(), ship_rows(side).size()]
	line.mouse_filter = Control.MOUSE_FILTER_PASS

	var x := 0.0
	var header := _field_label("", ROW_HEADER_W)
	x = _row_cell(line, header, x, ROW_HEADER_W, float(PaletteLib.ROW_H))
	var type := _option(160)
	for hull in DataLoader.ship_types_list:
		if not (hull is Dictionary) or str(hull.get("id", "")).is_empty():
			continue
		type.add_item(str(hull["id"]))
		type.set_item_metadata(type.item_count - 1, str(hull["id"]))
	var cannons_label := _field_label(_t("sandbox.ship.cannons"), LABEL_W_STD)
	var cannons := _spin(0, 0, 0, 96)
	var crew_label := _field_label(_t("sandbox.ship.crew"), LABEL_W_SHORT)
	var crew := _spin(0, 0, 0, 96)
	var durability_label := _field_label(_t("sandbox.ship.durability"),
		LABEL_W_DURABILITY)
	var durability := _spin(1, 1, 1, 96)
	var captain_label := _field_label(_t("sandbox.ship.captain"), LABEL_W_STD)
	var captain := LineEdit.new()
	captain.placeholder_text = ""
	var figurehead_label := _field_label(_t("shipyard.slot.figurehead"),
		LABEL_W_MID)
	var figurehead := _option(160)
	_fill_equipment_option(figurehead, "figurehead")
	var sail_label := _field_label(_t("shipyard.slot.sail"), LABEL_W_SHORT)
	var sail := _option(160)
	_fill_equipment_option(sail, "sail")

	# The fixed cells' total cursor width (x already carries the header +
	# its gap), then the four expanding cells split exactly what remains
	# (the deleted EXPAND_FILL distribution, authored).
	var fixed := x + (LABEL_W_STD + CELL_GAP + 96.0 + CELL_GAP) \
		+ (LABEL_W_SHORT + CELL_GAP + 96.0 + CELL_GAP) \
		+ (LABEL_W_DURABILITY + CELL_GAP + 96.0 + CELL_GAP) \
		+ (LABEL_W_STD + CELL_GAP) + (LABEL_W_MID + CELL_GAP) \
		+ (LABEL_W_SHORT + CELL_GAP)
	# The three gaps BETWEEN the four expanding cells come off the leftover
	# too (the last cell ends flush with the row's right edge).
	var expand_w: float = maxf(120.0,
		(row_w - fixed - 3.0 * CELL_GAP) / 4.0)
	x = _row_cell(line, type, x, expand_w, ROW_PITCH)
	x = _row_pair(line, cannons_label, cannons, x, LABEL_W_STD, 96)
	x = _row_pair(line, crew_label, crew, x, LABEL_W_SHORT, 96)
	x = _row_pair(line, durability_label, durability, x,
		LABEL_W_DURABILITY, 96)
	x = _row_cell(line, captain_label, x, LABEL_W_STD,
		float(PaletteLib.ROW_H))
	x = _row_cell(line, captain, x, expand_w, ROW_PITCH)
	x = _row_cell(line, figurehead_label, x, LABEL_W_MID,
		float(PaletteLib.ROW_H))
	x = _row_cell(line, figurehead, x, expand_w, ROW_PITCH)
	x = _row_cell(line, sail_label, x, LABEL_W_SHORT, float(PaletteLib.ROW_H))
	x = _row_cell(line, sail, x, expand_w, ROW_PITCH)

	var row := {
		"root": line, "header": header, "type": type, "cannons": cannons,
		"crew": crew, "durability": durability, "figurehead": figurehead,
		"sail": sail, "captain": captain,
	}
	type.item_selected.connect(func(_index: int) -> void:
		_clamp_row(row))
	captain.text_changed.connect(func(_text: String) -> void:
		if side == "enemy":
			_sync_enemy_captain(true))
	var box := _player_rows_box if side == "player" else _enemy_rows_box
	var index := ship_rows(side).size()
	# The v2 list block drives the row rect (docs/80-* §4.8.9 — the same
	# pattern as the market's goods rows); the authored pitch is the
	# fallback when the block is absent (a suite table without lists).
	var rect := RegistryLib.list_rect(SCREEN_ID, list_id, index)
	if rect != Rect2():
		line.position = rect.position
		line.size = rect.size
	else:
		line.position = Vector2(0, float(index * int(ROW_PITCH)))
		line.size = Vector2(row_w, ROW_PITCH)
	var content: Control = box.get_child(0)
	content.add_child(line)
	RegistryLib.register(SCREEN_ID, line, "%s.%d" % [list_id, index],
		{"list": list_id})
	if side == "player":
		_player_rows.append(row)
	else:
		_enemy_rows.append(row)
	_sync_rows_content(side)
	_clamp_row(row)
	return row


## Re-clamps one row's hull-dependent ranges (§4.7.16 clamp table): cannons
## 0..armament_slots, crew crew_min..crew_max, durability 1..base durability
## (figurehead durability deltas are W3 territory — the editor clamps to the
## hull row's own value).
func _clamp_row(row: Dictionary) -> void:
	if _programming:
		return
	_programming = true
	var hull := _hull_row(str(_option_value(row["type"])))
	var armament := int(hull.get("armament_slots", 0))
	var crew_min := int(hull.get("crew_min", 0))
	var crew_max := maxi(int(hull.get("crew_max", crew_min)), crew_min)
	var max_durability := maxi(int(hull.get("durability", 1)), 1)
	var cannons: SpinBox = row["cannons"]
	var crew: SpinBox = row["crew"]
	var durability: SpinBox = row["durability"]
	cannons.max_value = armament
	cannons.value = clampi(int(cannons.value), 0, armament)
	crew.min_value = crew_min
	crew.max_value = crew_max
	crew.value = clampi(int(crew.value), crew_min, crew_max)
	durability.min_value = 1
	durability.max_value = max_durability
	durability.value = clampi(int(durability.value), 1, max_durability)
	_programming = false


## The §4.7.16 player stats — ONE row of the player panel (the
## horizontal-bands re-layout): the five attributes (each 0–100, labels
## `char.attr.*`) + the weapon/armor slots — injected into the battle
## through the `60-*` §4.12.1 `player_stats` seam — + the initial morale
## (short label `sandbox.morale.short`). The per-side +/− fleet buttons
## join this row's right end (appended by `_build_panels`). Defaults read
## the live run's values — reads are zero-write. Phase 12: the row is a
## plain Control; the cells take cursor-computed absolute slots (the
## deleted HBox's compose-beside order, no flow).
func _build_player_stats_row() -> void:
	var row := Control.new()
	row.name = "PlayerStats"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Panel-local 16px pad pre-apply (the deleted Box's inset); the data
	# row snaps this to its committed tile at activation.
	row.position = Vector2(PANEL_PAD, PANEL_PAD)
	row.size = Vector2(_panel_box_w(), ROW_PITCH)
	_player_stats_row_h = row

	var cx := 0
	var row_id := "player_panel.stats_row"
	for key in ATTRIBUTES:
		var spin := _spin(ATTR_MIN, ATTR_MAX, _default_attribute(key), 96)
		cx = _row_field(row, "%s.%s" % [row_id, key],
				_field_label(_t("char.attr.%s" % key), LABEL_W_ATTR),
				spin, cx, 4, 3)
		_attribute_spins[key] = spin

	_weapon_option = _option(160)
	_armor_option = _option(160)
	_fill_equipment_option(_weapon_option, "weapon")
	_fill_equipment_option(_armor_option, "armor")
	cx = _row_field(row, "%s.weapon" % row_id,
			_field_label(_t("shipyard.slot.weapon"), LABEL_W_SHORT),
			_weapon_option, cx, 2, 5)
	cx = _row_field(row, "%s.armor" % row_id,
			_field_label(_t("shipyard.slot.armor"), LABEL_W_SHORT),
			_armor_option, cx, 2, 5)
	var morale_spin := _spin(MORALE_MIN, MORALE_MAX, 50, 96)
	cx = _row_field(row, "%s.morale" % row_id,
			_field_label(_t("sandbox.morale.short"), LABEL_W_MORALE),
			morale_spin, cx, 2, 3)
	_player_morale_spin = morale_spin
	_player_panel.add_child(row)


## The private row holders (the +/− buttons append to these in
## `_build_panels`).
func _player_stats_row() -> Control:
	return _player_stats_row_h


func _enemy_profile_row() -> Control:
	return _enemy_profile_row_h


## The enemy panel's profile — ONE row of the enemy panel (the
## horizontal-bands re-layout): the kind (9 kinds), the compose toggle
## (the checkbox carries its own localized text, so the whole toggle is
## clickable), the FLAGSHIP captain id (synced with enemy row 0 — the
## export schema has no enemy-level key, the value rides per-ship
## `captain_id`), `ai_level` ∈ {0,1}, `archetype`, `formation` and the
## initial morale. `formation` + morale took effect at W4 (§4.9b /
## §4.12.1); `ai_level` / `archetype` at W5-C (the true-override emission
## into the fixture, folded into the battle's profile row by the screen).
## The per-side +/− fleet buttons join the row's right end (appended by
## `_build_panels`). Phase 12: a plain Control row; the flagship edit
## takes the leftover width between the fixed cells and the +/− pair.
func _build_enemy_profile_row() -> void:
	var row := Control.new()
	row.name = "EnemyProfile"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Panel-local 16px pad pre-apply (the deleted Box's inset); the data
	# row snaps this to its committed tile at activation.
	row.position = Vector2(PANEL_PAD, PANEL_PAD)
	row.size = Vector2(_panel_box_w(), ROW_PITCH)
	_enemy_profile_row_h = row

	var cx := 0
	var row_id := "enemy_panel.profile_row"
	_kind_option = _option(160)
	_fill_option(_kind_option, KINDS, "sandbox.kind")
	_kind_option.item_selected.connect(func(_index: int) -> void:
		_apply_kind_profile(str(_option_value(_kind_option))))
	cx = _row_field(row, "%s.kind" % row_id,
			_field_label(_t("sandbox.enemy.kind"), LABEL_W_MID),
			_kind_option, cx, 4, 5)
	_compose_check = CheckBox.new()
	_compose_check.text = _t("sandbox.enemy.compose")
	_compose_check.toggled.connect(_on_compose_toggled)
	cx = _row_field_bare(row, "%s.compose" % row_id, _compose_check, cx,
			5)

	var flagship_label := _field_label(_t("sandbox.enemy.flagship"),
		LABEL_W_STD)
	_enemy_captain_edit = LineEdit.new()
	_enemy_captain_edit.placeholder_text = ""
	_enemy_captain_edit.text_changed.connect(func(_text: String) -> void:
		_sync_enemy_captain(false))
	# The flagship edit takes its column-floor width (3 tiles) + a 4-tile
	# edit — the tile-packed row leaves the leftover to the right.
	cx = _row_field(row, "%s.flagship" % row_id, flagship_label,
			_enemy_captain_edit, cx, 3, 4)

	_ai_level_option = _option(164)
	_ai_level_option.add_item(_t_id("sandbox.ai_level", "t2"))
	_ai_level_option.set_item_metadata(0, 0)
	_ai_level_option.add_item(_t_id("sandbox.ai_level", "t3"))
	_ai_level_option.set_item_metadata(1, 1)
	_ai_level_option.select(0)
	cx = _row_field(row, "%s.ai_level" % row_id,
			_field_label(_t("sandbox.ai_level"), LABEL_W_STD),
			_ai_level_option, cx, 3, 6)
	_archetype_option = _option(136)
	_fill_option(_archetype_option, ARCHETYPES, "sandbox.archetype")
	cx = _row_field(row, "%s.archetype" % row_id,
			_field_label(_t("sandbox.archetype"), LABEL_W_MID),
			_archetype_option, cx, 4, 5)

	_formation_option = _option(140)
	_fill_option(_formation_option, FORMATIONS, "battle.formation")
	cx = _row_field(row, "%s.formation" % row_id,
			_field_label(_t("sandbox.formation"), LABEL_W_MID),
			_formation_option, cx, 4, 5)
	var morale_spin := _spin(MORALE_MIN, MORALE_MAX, 50, 96)
	cx = _row_field(row, "%s.morale" % row_id,
			_field_label(_t("sandbox.morale.short"), LABEL_W_MORALE),
			morale_spin, cx, 2, 3)
	_enemy_morale_spin = morale_spin
	_enemy_panel.add_child(row)


## One-click `compose_enemy` generation toggle (§4.7.16): ON hides ONLY the
## per-ship rows and the fleet add/remove buttons — the enemy profile row
## above stays visible (composing replaces the rows, not the panel).
func _on_compose_toggled(pressed: bool) -> void:
	_enemy_rows_box.visible = not pressed
	_enemy_add.visible = not pressed
	_enemy_remove.visible = not pressed


## The enemy panel's captain field IS enemy flagship row 0's captain id (the
## export schema has no enemy-level key — the value rides per-ship
## `captain_id`, the normative shape). Syncs the two editors either way;
## `from_row` is true when row 0's own LineEdit changed.
func _sync_enemy_captain(from_row: bool) -> void:
	if _programming or _enemy_rows.is_empty():
		return
	_programming = true
	if from_row:
		_enemy_captain_edit.text = \
			str((_enemy_rows[0] as Dictionary)["captain"].text)
	else:
		(_enemy_rows[0] as Dictionary)["captain"].text = _enemy_captain_edit.text
	_programming = false


## On a kind change the three profile selectors follow the kind's
## `ai_profiles` row (`10-*` §4.10; the doc-pinned fallback while the data
## wave is unmerged). The sync also RESTORES the at-default editor state:
## a selector back on the row's own value stops riding the fixture (the
## true-override emission reads this exact row).
func _apply_kind_profile(kind: String) -> void:
	var profile := _profile_default(kind)
	_select_option(_archetype_option, str(profile.get("archetype", "balanced")))
	_select_option(_formation_option, str(profile.get("formation", "column")))
	_ai_level_option.select(1 if int(profile.get("ai_level", 0)) == 1 else 0)


func _profile_default(kind: String) -> Dictionary:
	var kind_id := kind
	if kind_id == "hunter":
		# Correction-8 lookup rule: a hunter battle reads the navy row.
		kind_id = "navy"
	var profiles = DataLoader.npc_config.get("ai_profiles", {}) \
		if DataLoader.npc_config is Dictionary else {}
	if profiles is Dictionary and (profiles as Dictionary).has(kind_id):
		var row = (profiles as Dictionary)[kind_id]
		if row is Dictionary:
			return row
	return DOC_PROFILE_FALLBACK.get(kind_id, {
		"archetype": "balanced", "formation": "column", "ai_level": 0,
	})


## The bottom strip (§4.7.16, the 2026-11-09 horizontal-bands pinned
## rect): row 1 = the encounter conditions — day; the seed pair (the mode
## option + the value spin that shows only for `seed_mode = fixed`);
## weather; `wind_dir`; the current pair (direction + the LABELED strength
## `sandbox.current.strength`); deployment — row 2 = the four action
## buttons right-aligned (`sandbox.start` 开战 / `sandbox.random_all` /
## `sandbox.import` / `sandbox.export`). Phase 12: the strip's
## PanelContainer/VBox/HBox chain is deleted — a plain Panel at the pinned
## rect whose two rows are plain Controls with cursor-computed cell slots.
## The seed spin keeps its slot when hidden (a blank slot, no re-flow).
func _build_conditions_row() -> void:
	var panel := Panel.new()
	panel.name = "ConditionsPanel"
	panel.position = CONDITIONS_RECT.position
	panel.size = CONDITIONS_RECT.size
	_conditions_panel = panel
	add_child(panel)
	var strip_w: float = CONDITIONS_RECT.size.x - 2.0 * PANEL_PAD

	# Row 1: the encounter conditions on one 64px line.
	var grid := Control.new()
	grid.name = "Conditions"
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.position = Vector2(PANEL_PAD, PANEL_PAD)
	grid.size = Vector2(strip_w, ROW_PITCH)
	panel.add_child(grid)
	_conditions_grid = grid

	var cx := 0
	var row_id := "conditions_panel.grid"
	_day_spin = _spin(DAY_MIN, 9999, 1, 96)
	cx = _row_field(grid, "%s.day" % row_id,
			_field_label(_t("sandbox.day"), LABEL_W_SHORT),
			_day_spin, cx, 2, 3)
	# The seed pair: the value spin rides beside its mode option (it shows
	# only for `seed_mode = fixed` — the §4.7.16 resolution rules).
	_seed_mode_option = _option(190)
	_fill_option(_seed_mode_option, SEED_MODES, "sandbox.seed")
	_seed_spin = _spin(0, SEED_MAX, 1, 128)
	_seed_mode_option.item_selected.connect(func(_index: int) -> void:
		_seed_spin.visible = str(_option_value(_seed_mode_option)) == "fixed")
	cx = _row_field(grid, "%s.seed_mode" % row_id,
			_field_label(_t("sandbox.seed"), LABEL_W_SHORT),
			_seed_mode_option, cx, 2, 6)
	cx = _row_field_bare(grid, "%s.seed_value" % row_id, _seed_spin, cx,
			4)
	_weather_option = _option(112)
	_fill_option(_weather_option, WEATHERS, "world.weather")
	cx = _row_field(grid, "%s.weather" % row_id,
			_field_label(_t("sandbox.weather"), LABEL_W_STD),
			_weather_option, cx, 3, 4)

	_wind_option = _option(88)
	_fill_option(_wind_option, WIND_DIRS, "sandbox.dir")
	cx = _row_field(grid, "%s.wind_dir" % row_id,
			_field_label(_t("sandbox.wind_dir"), LABEL_W_LONG),
			_wind_option, cx, 4, 3)
	# The current pair: the direction option + the LABELED 0..3 strength
	# spin (the strength was an unlabeled mystery box before 2026-11-09).
	_current_dir_option = _option(84)
	_fill_option(_current_dir_option, CURRENT_DIRS, "sandbox.dir")
	_current_strength_spin = _spin(0, CURRENT_STRENGTH_MAX, 0, 96)
	cx = _row_field(grid, "%s.current" % row_id,
			_field_label(_t("sandbox.current"), LABEL_W_STD),
			_current_dir_option, cx, 3, 3)
	cx = _row_field(grid, "%s.current_strength" % row_id,
			_field_label(_t("sandbox.current.strength"), LABEL_W_STRENGTH),
			_current_strength_spin, cx, 3, 3)
	_deployment_option = _option(150)
	_fill_option(_deployment_option, DEPLOYMENTS, "sandbox.deployment")
	cx = _row_field(grid, "%s.deployment" % row_id,
			_field_label(_t("sandbox.deployment"), LABEL_W_LONG),
			_deployment_option, cx, 4, 5)

	# Row 2: the four actions, right-aligned (a single 4-across row fits
	# the 1888px strip now that the conditions carry their own row).
	var actions := Control.new()
	actions.name = "Actions"
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	actions.position = Vector2(PANEL_PAD, PANEL_PAD + ROW_PITCH)
	actions.size = Vector2(strip_w, ROW_PITCH)
	panel.add_child(actions)
	_conditions_actions = actions
	_start_button = UiKitLib.button("sandbox.start")
	_random_all_button = UiKitLib.button("sandbox.random_all")
	_import_button = UiKitLib.button("sandbox.import")
	_export_button = UiKitLib.button("sandbox.export")
	var action_w := 160.0
	var actions_x: float = strip_w - 4.0 * (action_w + CELL_GAP)
	var slot := 0
	for button in [_start_button, _random_all_button, _import_button,
			_export_button]:
		actions.add_child(button)
		button.position = Vector2(actions_x + float(slot * int(action_w
			+ CELL_GAP)), (ROW_PITCH - float(PaletteLib.BUTTON_H)) / 2.0)
		button.size = Vector2(action_w, float(PaletteLib.BUTTON_H))
		slot += 1
	_start_button.pressed.connect(start_battle)
	_random_all_button.pressed.connect(randomize_all)
	_import_button.pressed.connect(_on_import_pressed)
	_export_button.pressed.connect(_on_export_pressed)


# --- Editors & clamps (§4.7.16: the clamp table is IMMEDIATE) ---------------

func ship_rows(side: String) -> Array:
	return _player_rows if side == "player" else _enemy_rows


## Copies of the per-ship widget rows (tests/hosts).
func player_rows() -> Array:
	return _player_rows.duplicate()


func enemy_rows() -> Array:
	return _enemy_rows.duplicate()


## Adds one ship row (a fresh default of the side's flagship hull). Refused
## beyond [constant MAX_SHIPS] (§4.7.16: 1–5 ships per side) with the
## `sandbox.ship.max` toast; on success the row lands in the side's rows
## column — all five rows stay visible (the horizontal-bands layout has no
## rows scroll).
func add_ship_row(side: String) -> bool:
	if ship_rows(side).size() >= MAX_SHIPS:
		_show_toast(_t("sandbox.ship.max"))
		return false
	var hull := "sloop"
	if not ship_rows(side).is_empty():
		hull = str(_option_value((ship_rows(side)[0] as Dictionary)["type"]))
	_make_ship_row(side)
	_write_row(ship_rows(side)[ship_rows(side).size() - 1],
		_default_ship_state(hull))
	_refresh_row_headers(side)
	_refresh_fleet_buttons()
	return true


## Removes the last ship row. Refused at [constant MIN_SHIPS].
func remove_ship_row(side: String) -> bool:
	var rows := ship_rows(side)
	if rows.size() <= MIN_SHIPS:
		return false
	var row: Dictionary = rows[rows.size() - 1]
	var root: Control = row["root"]
	root.get_parent().remove_child(root)
	root.queue_free()
	if side == "player":
		_player_rows.remove_at(_player_rows.size() - 1)
	else:
		_enemy_rows.remove_at(_enemy_rows.size() - 1)
	_sync_rows_content(side)
	_refresh_row_headers(side)
	_refresh_fleet_buttons()
	if side == "enemy" and not _enemy_rows.is_empty():
		_sync_enemy_captain(true)
	return true


## Presentation-only enable state (2026-11-09): Add disables at the 5-ship
## cap, Remove at the 1-ship floor (the compose toggle hides the enemy
## buttons entirely, which supersedes this). The direct add/remove method
## contracts are untouched.
func _refresh_fleet_buttons() -> void:
	if _player_add == null or _enemy_add == null:
		return
	_player_add.disabled = ship_rows("player").size() >= MAX_SHIPS
	_player_remove.disabled = ship_rows("player").size() <= MIN_SHIPS
	_enemy_add.disabled = ship_rows("enemy").size() >= MAX_SHIPS
	_enemy_remove.disabled = ship_rows("enemy").size() <= MIN_SHIPS


func _refresh_row_headers(side: String) -> void:
	for index in ship_rows(side).size():
		var row: Dictionary = ship_rows(side)[index]
		var label: Label = row["header"]
		label.text = _tfmt("sandbox.ship", {"index": index + 1},
			"ship {index}")


## Immediate UI-layer clamps (§4.7.16): hull-driven ranges re-apply to every
## row; the SpinBox min/max bounds clamp attrs/morale/day/strength on change.
## An invalid combination never reaches 开战 — [method build_encounter] and
## [method export_config] call this first.
func apply_clamps() -> void:
	for side in ["player", "enemy"]:
		for row in ship_rows(side):
			_clamp_row(row)
	_day_spin.value = float(maxi(int(_day_spin.value), DAY_MIN))
	_current_strength_spin.value = float(clampi(
		int(_current_strength_spin.value), 0, CURRENT_STRENGTH_MAX))
	for key in ATTRIBUTES:
		var spin: SpinBox = _attribute_spins.get(key)
		if spin != null:
			spin.value = float(clampi(int(spin.value), ATTR_MIN, ATTR_MAX))
	_player_morale_spin.value = float(clampi(int(_player_morale_spin.value),
		MORALE_MIN, MORALE_MAX))
	_enemy_morale_spin.value = float(clampi(int(_enemy_morale_spin.value),
		MORALE_MIN, MORALE_MAX))


# --- State <-> editors ------------------------------------------------------

## A default §4.7.16 ship state for `hull_id` (full cannon load, min crew,
## base durability — derived from the hull row, never invented).
func _default_ship_state(hull_id: String) -> Dictionary:
	var hull := _hull_row(hull_id)
	if hull.is_empty() and not (DataLoader.ship_types_list as Array).is_empty():
		var first = DataLoader.ship_types_list[0]
		hull = first if first is Dictionary else {}
		hull_id = str(hull.get("id", hull_id))
	return {
		"ship_type_id": hull_id,
		"cannons": int(hull.get("armament_slots", 0)),
		"crew": int(hull.get("crew_min", 0)),
		"durability": int(hull.get("durability", 1)),
		"figurehead": "",
		"sail": "",
		"captain_id": "",
	}


## The live attribute read (headless/empty player → the `50-*` base 10).
func _default_attribute(key: String) -> int:
	var char_lib: Variant = CharacterLib
	if char_lib != null and char_lib.has_method("attribute"):
		return clampi(int(char_lib.attribute(key)), ATTR_MIN, ATTR_MAX)
	return 10


## The doc-example defaults (`80-*` §4.7.16) with the player block seeded
## from the live run's reads (attributes/equipment — reads are zero-write).
func _default_config() -> Dictionary:
	var attributes: Dictionary = {}
	for key in ATTRIBUTES:
		attributes[key] = _default_attribute(key)
	var equipment = GameState.player.get("equipment", {}) \
		if GameState.player is Dictionary else {}
	var stats_gear := {"weapon": "", "armor": ""}
	if equipment is Dictionary:
		for slot in STATS_EQUIPMENT_SLOTS:
			stats_gear[slot] = str(equipment.get(slot, ""))
	var pirate := _profile_default("pirate")
	var attributes_gear: Dictionary = attributes.duplicate(true)
	for slot in STATS_EQUIPMENT_SLOTS:
		attributes_gear[slot] = stats_gear[slot]
	return {
		"version": 1,
		"kind": "sailage_sandbox",
		"player": {
			"stats": attributes_gear,
			"morale": 50,
			"ships": [_default_ship_state("brigantine")],
		},
		"enemy": {
			"kind": "pirate",
			"ai_level": int(pirate.get("ai_level", 1)),
			"archetype": str(pirate.get("archetype", "aggressive")),
			"formation": str(pirate.get("formation", "swarm")),
			"morale": 50,
			"compose": false,
			"ships": [_default_ship_state("sloop")],
		},
		"conditions": {
			"day": 1,
			"seed_mode": "fixed",
			"seed": 1,
			"weather": "fair",
			"wind_dir": "E",
			"current": {"dir": "E", "strength": 0},
			"deployment": "standard",
		},
	}


## Reads one row's editors into a ship-state dict (values already clamped by
## the widgets).
func _read_row(row: Dictionary) -> Dictionary:
	return {
		"ship_type_id": str(_option_value(row["type"])),
		"cannons": int((row["cannons"] as SpinBox).value),
		"crew": int((row["crew"] as SpinBox).value),
		"durability": int((row["durability"] as SpinBox).value),
		"figurehead": str(_option_value(row["figurehead"])),
		"sail": str(_option_value(row["sail"])),
		"captain_id": str((row["captain"] as LineEdit).text).strip_edges(),
	}


## Programs one row's editors from a ship-state dict (values clamped). The
## hull-driven ranges are WIDENED for the new hull before the values are
## written — otherwise a brigantine write into a latin-bounded row would
## clamp to the old maximum.
func _write_row(row: Dictionary, state: Dictionary) -> void:
	_programming = true
	_select_option(row["type"], str(state.get("ship_type_id", "")))
	_programming = false
	_clamp_row(row)
	_programming = true
	(row["cannons"] as SpinBox).value = float(int(state.get("cannons", 0)))
	(row["crew"] as SpinBox).value = float(int(state.get("crew", 0)))
	(row["durability"] as SpinBox).value = float(int(state.get("durability", 1)))
	_select_option(row["figurehead"], str(state.get("figurehead", "")))
	_select_option(row["sail"], str(state.get("sail", "")))
	(row["captain"] as LineEdit).text = str(state.get("captain_id", ""))
	_programming = false
	_clamp_row(row)


## Rebuilds a side's rows to `states.size()` entries (the round-trip
## contract: the same list reproduces the same rows), merging per field so a
## partial row dict falls back to the row's current editor values.
func _write_rows(side: String, states: Array) -> void:
	var rows := ship_rows(side)
	while rows.size() > maxi(states.size(), MIN_SHIPS):
		remove_ship_row(side)
	while rows.size() < states.size() and rows.size() < MAX_SHIPS:
		add_ship_row(side)
	for index in ship_rows(side).size():
		var current := _read_row(ship_rows(side)[index])
		var state: Dictionary = states[index] if index < states.size() \
			and states[index] is Dictionary else {}
		var merged := current.duplicate(true)
		for key in ["ship_type_id", "cannons", "crew", "durability",
				"figurehead", "sail", "captain_id"]:
			if state.has(key):
				merged[key] = state[key]
		# The normative export nests the equipment slots under `equipment`
		# (`80-*` §4.7.16 schema); an imported row restores both slots from
		# the nested object when the flat keys are absent (editor-internal
		# callers pass flat dicts, which keep priority).
		if state.has("equipment") and (state["equipment"] is Dictionary):
			var equipment: Dictionary = state["equipment"]
			if not state.has("figurehead") and equipment.has("figurehead"):
				merged["figurehead"] = str(equipment["figurehead"])
			if not state.has("sail") and equipment.has("sail"):
				merged["sail"] = str(equipment["sail"])
		_write_row(ship_rows(side)[index], merged)
	_refresh_row_headers(side)


## Loads a full §4.7.16 config: unknown keys ignored, missing keys fall back
## to the current editor values.
func _load_config(data: Dictionary) -> void:
	_programming = true
	var player: Dictionary = data.get("player", {}) \
		if data.get("player", {}) is Dictionary else {}
	var enemy: Dictionary = data.get("enemy", {}) \
		if data.get("enemy", {}) is Dictionary else {}
	var conditions: Dictionary = data.get("conditions", {}) \
		if data.get("conditions", {}) is Dictionary else {}

	var stats: Dictionary = player.get("stats", {}) \
		if player.get("stats", {}) is Dictionary else {}
	for key in ATTRIBUTES:
		var spin: SpinBox = _attribute_spins.get(key)
		if spin != null and stats.has(key):
			spin.value = float(clampi(int(stats[key]), ATTR_MIN, ATTR_MAX))
	_select_option(_weapon_option,
		str(stats.get("weapon", _option_value(_weapon_option))))
	_select_option(_armor_option,
		str(stats.get("armor", _option_value(_armor_option))))
	_player_morale_spin.value = float(clampi(
		int(player.get("morale", int(_player_morale_spin.value))),
		MORALE_MIN, MORALE_MAX))

	_select_option(_kind_option,
		str(enemy.get("kind", _option_value(_kind_option))))
	_ai_level_option.select(1 if int(enemy.get("ai_level",
		int(_option_value(_ai_level_option)))) == 1 else 0)
	_select_option(_archetype_option,
		str(enemy.get("archetype", _option_value(_archetype_option))))
	_select_option(_formation_option,
		str(enemy.get("formation", _option_value(_formation_option))))
	_enemy_morale_spin.value = float(clampi(
		int(enemy.get("morale", int(_enemy_morale_spin.value))),
		MORALE_MIN, MORALE_MAX))
	_compose_check.button_pressed = bool(enemy.get("compose",
		_compose_check.button_pressed))
	_programming = false
	if enemy.has("ships") and enemy["ships"] is Array:
		_write_rows("enemy", enemy["ships"])
	if player.has("ships") and player["ships"] is Array:
		_write_rows("player", player["ships"])
	_sync_enemy_captain(true)

	_day_spin.value = float(maxi(
		int(conditions.get("day", int(_day_spin.value))), DAY_MIN))
	_select_option(_seed_mode_option,
		str(conditions.get("seed_mode", _option_value(_seed_mode_option))))
	_seed_spin.value = float(clampi(
		int(conditions.get("seed", int(_seed_spin.value))), 0, SEED_MAX))
	_seed_spin.visible = str(_option_value(_seed_mode_option)) == "fixed"
	_select_option(_weather_option,
		str(conditions.get("weather", _option_value(_weather_option))))
	_select_option(_wind_option,
		str(conditions.get("wind_dir", _option_value(_wind_option))))
	var current: Dictionary = conditions.get("current", {}) \
		if conditions.get("current", {}) is Dictionary else {}
	_select_option(_current_dir_option,
		str(current.get("dir", _option_value(_current_dir_option))))
	_current_strength_spin.value = float(clampi(
		int(current.get("strength", int(_current_strength_spin.value))),
		0, CURRENT_STRENGTH_MAX))
	_select_option(_deployment_option,
		str(conditions.get("deployment", _option_value(_deployment_option))))
	apply_clamps()
	_on_compose_toggled(_compose_check.button_pressed)
	_refresh_fleet_buttons()


# --- Export / import (forward-compatible §4.7.16 schema) --------------------

## The normative export dict — fixed key order, all planned fields (values
## already clamped). `JSON.stringify` of this is byte-stable, so the
## export → import → re-export round trip is byte-identical.
func export_config() -> Dictionary:
	apply_clamps()
	var stats: Dictionary = {}
	for key in ATTRIBUTES:
		stats[key] = int((_attribute_spins[key] as SpinBox).value)
	stats["weapon"] = str(_option_value(_weapon_option))
	stats["armor"] = str(_option_value(_armor_option))
	return {
		"version": 1,
		"kind": "sailage_sandbox",
		"player": {
			"stats": stats,
			"morale": int(_player_morale_spin.value),
			"ships": _export_ships("player"),
		},
		"enemy": {
			"kind": str(_option_value(_kind_option)),
			"ai_level": int(_option_value(_ai_level_option)),
			"archetype": str(_option_value(_archetype_option)),
			"formation": str(_option_value(_formation_option)),
			"morale": int(_enemy_morale_spin.value),
			"compose": bool(_compose_check.button_pressed),
			"ships": _export_ships("enemy"),
		},
		"conditions": {
			"day": int(_day_spin.value),
			"seed_mode": str(_option_value(_seed_mode_option)),
			"seed": int(_seed_spin.value),
			"weather": str(_option_value(_weather_option)),
			"wind_dir": str(_option_value(_wind_option)),
			"current": {
				"dir": str(_option_value(_current_dir_option)),
				"strength": int(_current_strength_spin.value),
			},
			"deployment": str(_option_value(_deployment_option)),
		},
	}


func _export_ships(side: String) -> Array:
	var out: Array = []
	for row in ship_rows(side):
		var state := _read_row(row)
		out.append({
			"ship_type_id": state["ship_type_id"],
			"cannons": state["cannons"],
			"crew": state["crew"],
			"durability": state["durability"],
			"equipment": {
				"figurehead": state["figurehead"],
				"sail": state["sail"],
			},
			"captain_id": state["captain_id"],
		})
	return out


## The export JSON (compact, deterministic key order).
func export_json() -> String:
	return JSON.stringify(export_config())


## Parses and applies a clipboard payload. Unknown keys are ignored; missing
## keys fall back to the current editor values; non-JSON / wrong-envelope
## payloads return false (the `sandbox.import.invalid` toast).
func import_json(text: String) -> bool:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var data: Dictionary = parsed
	if str(data.get("kind", "")) != "sailage_sandbox" \
			or int(data.get("version", 0)) != 1:
		return false
	_load_config(data)
	return true


func _on_export_pressed() -> void:
	DisplayServer.clipboard_set(export_json())
	_show_toast(_t("sandbox.export.ok"))


func _on_import_pressed() -> void:
	if import_json(DisplayServer.clipboard_get()):
		_show_toast(_t("sandbox.import.ok"))
	else:
		_show_toast(_t("sandbox.import.invalid"))


## Transient bottom-center toast (`80-*` §4.7: 2.5 s, max one visible).
func _show_toast(text: String) -> void:
	_toast_generation += 1
	var generation := _toast_generation
	_toast.text = text
	_toast.visible = true
	await get_tree().create_timer(TOAST_SECONDS).timeout
	if not is_instance_valid(_toast) or not is_inside_tree():
		return
	if generation == _toast_generation:
		_toast.visible = false


# --- 随机全部 -----------------------------------------------------------------

## Randomizes every editor into its clamped range (the editors clamp on
## write, so an invalid combination can never reach 开战). Its own RNG — an
## editor convenience, never the battle stream. `seed_value ≥ 0` pins the
## RNG (deterministic acceptance tests); −1 rolls fresh entropy.
##
## The generation MODE is not a die roll: the compose toggle always returns
## to OFF so both sides' per-ship rows are present AND visible after every
## 随机全部. The old build diced the toggle (50% ON) and the toggled-ON hide
## blanked the whole enemy panel — the "enemy sometimes empty" defect; the
## row data was intact but invisible, and composing stays an explicit user
## choice anyway (§4.7.16: compose OR per-ship rows).
func randomize_all(seed_value := -1) -> void:
	var rng := RandomNumberGenerator.new()
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	for side in ["player", "enemy"]:
		var count := rng.randi_range(MIN_SHIPS, MAX_SHIPS)
		while ship_rows(side).size() < count:
			add_ship_row(side)
		while ship_rows(side).size() > count:
			remove_ship_row(side)
		for row in ship_rows(side):
			_write_row(row, {
				"ship_type_id": _random_hull(rng),
				"cannons": rng.randi_range(0, 64),
				"crew": rng.randi_range(1, 200),
				"durability": rng.randi_range(1, 500),
				"figurehead": _random_equipment(rng, "figurehead"),
				"sail": _random_equipment(rng, "sail"),
				"captain_id": "",
			})
	_sync_enemy_captain(true)
	for key in ATTRIBUTES:
		var spin: SpinBox = _attribute_spins.get(key)
		if spin != null:
			spin.value = float(rng.randi_range(ATTR_MIN, ATTR_MAX))
	_select_option(_weapon_option, _random_equipment(rng, "weapon"))
	_select_option(_armor_option, _random_equipment(rng, "armor"))
	_player_morale_spin.value = float(rng.randi_range(MORALE_MIN, MORALE_MAX))
	var kind: String = KINDS[rng.randi_range(0, KINDS.size() - 1)]
	_select_option(_kind_option, kind)
	_apply_kind_profile(kind)
	_ai_level_option.select(rng.randi_range(0, 1))
	_select_option(_archetype_option,
		ARCHETYPES[rng.randi_range(0, ARCHETYPES.size() - 1)])
	_select_option(_formation_option,
		FORMATIONS[rng.randi_range(0, FORMATIONS.size() - 1)])
	_enemy_morale_spin.value = float(rng.randi_range(MORALE_MIN, MORALE_MAX))
	# The mode toggle is never a die roll (see the docstring): OFF — the
	# per-ship rows stay visible on both sides.
	_compose_check.button_pressed = false
	_day_spin.value = float(rng.randi_range(DAY_MIN, 999))
	var seed_mode: String = SEED_MODES[rng.randi_range(0, SEED_MODES.size() - 1)]
	_select_option(_seed_mode_option, seed_mode)
	_seed_spin.value = float(rng.randi_range(0, SEED_MAX))
	_seed_spin.visible = seed_mode == "fixed"
	_select_option(_weather_option,
		WEATHERS[rng.randi_range(0, WEATHERS.size() - 1)])
	_select_option(_wind_option,
		WIND_DIRS[rng.randi_range(0, WIND_DIRS.size() - 1)])
	_select_option(_current_dir_option,
		CURRENT_DIRS[rng.randi_range(0, CURRENT_DIRS.size() - 1)])
	_current_strength_spin.value = float(
		rng.randi_range(0, CURRENT_STRENGTH_MAX))
	_select_option(_deployment_option,
		DEPLOYMENTS[rng.randi_range(0, DEPLOYMENTS.size() - 1)])
	apply_clamps()
	_on_compose_toggled(_compose_check.button_pressed)
	_refresh_fleet_buttons()


func _random_hull(rng: RandomNumberGenerator) -> String:
	var hulls: Array = DataLoader.ship_types_list
	if hulls.is_empty():
		return "sloop"
	var row = hulls[rng.randi_range(0, hulls.size() - 1)]
	return str(row.get("id", "sloop")) if row is Dictionary else "sloop"


func _random_equipment(rng: RandomNumberGenerator, slot: String) -> String:
	var items := _equipment_ids(slot)
	if items.is_empty() or rng.randf() < 0.5:
		return ""
	return str(items[rng.randi_range(0, items.size() - 1)])


# --- 开战 (the fixture encounter → S10) ---------------------------------------

## The §4.7.16 fixture encounter. Ship instances in the §4.11.11 shape;
## `gold` 0; the resolved seed — `fixed` → the editor number, `random` → a
## fresh `randi()`, `auto` → the key is OMITTED and the §4.11.1 formula
## applies (contact = the origin tile). W4: `player_morale` / `enemy_morale`
## ride as §4.12.1 config keys. W4 + W5-C: the enemy `formation` /
## `ai_level` / `archetype` ride only as TRUE overrides of the kind's
## `ai_profiles` row — at-default keys stay out of the fixture (the W2-C
## fixture-shape pin keeps the byte-harmless audit meaningful), and the
## screen's `_setup_fleet_commander` folds them into the battle's profile
## row. wind/current/deployment stay editor + export values (dormant).
func build_encounter() -> Dictionary:
	apply_clamps()
	var player_ships: Array = []
	for row in _player_rows:
		player_ships.append(_ship_instance(_read_row(row)))
	var kind := str(_option_value(_kind_option))
	var day := int(_day_spin.value)
	var enemy_ships: Array = []
	if not _compose_check.button_pressed:
		for row in _enemy_rows:
			enemy_ships.append(_ship_instance(_read_row(row)))
	# §4.7.16 seed resolution. With `compose` ON the composition consumes a
	# stream seeded from the same resolved seed (or, for `auto`, the §4.11.1
	# formula — the value the sim itself will re-derive), so a given
	# (config, seed) pair always composes the same fleet: the byte-identity
	# audit pair stays exact.
	var seed_mode := str(_option_value(_seed_mode_option))
	var resolved_seed := -1
	match seed_mode:
		"fixed":
			resolved_seed = int(_seed_spin.value)
		"random":
			resolved_seed = randi()
	if _compose_check.button_pressed:
		var rng := RandomNumberGenerator.new()
		rng.seed = resolved_seed if resolved_seed >= 0 \
			else BattleSimLib.battle_seed_formula(
				day, FIXTURE_CONTACT, 0, player_ships.size())
		enemy_ships = AiFleetLib.compose_enemy(kind, day, rng)
	var encounter := {
		"sandbox": true,
		"id": "sandbox",
		"kind": kind,
		"player_ships": player_ships,
		"enemy_ships": enemy_ships,
		"day": day,
		"gold": 0,
		"weather": str(_option_value(_weather_option)),
	}
	if resolved_seed >= 0:
		encounter["seed"] = resolved_seed
	encounter["player_stats"] = {
		"attributes": _player_attributes(),
		"equipment": {
			"weapon": str(_option_value(_weapon_option)),
			"armor": str(_option_value(_armor_option)),
		},
	}
	# W4 (§4.12.1 / §4.8a): the initial-morale fields are live — both sides'
	# editors ride the fixture as the §4.12.1 config keys. A sim without the
	# keys (pre-A) ignores unknown config, so this is harmless until A lands.
	encounter["player_morale"] = int(_player_morale_spin.value)
	encounter["enemy_morale"] = int(_enemy_morale_spin.value)
	# The enemy profile overrides (§4.7.16 / §4.9b / §4.9c): the editor's
	# formation / ai_level / archetype ride ONLY as true overrides of the
	# kind's `ai_profiles` row. At the editor's default — which IS the
	# profile row's own value (the kind switch syncs from it) — the key
	# stays out of the fixture and the row's default applies downstream
	# (the W2-C fixture-shape pin keeps the byte-harmless audit's keys out
	# of the at-default encounter).
	var profile_row := _profile_default(kind)
	var formation := str(_option_value(_formation_option))
	if formation != str(profile_row.get("formation", "")):
		encounter["formation"] = formation
	var ai_level := int(_option_value(_ai_level_option))
	if ai_level != int(profile_row.get("ai_level", 0)):
		encounter["ai_level"] = ai_level
	var archetype := str(_option_value(_archetype_option))
	if archetype != str(profile_row.get("archetype", "")):
		encounter["archetype"] = archetype
	return encounter


func _player_attributes() -> Dictionary:
	var out: Dictionary = {}
	for key in ATTRIBUTES:
		out[key] = int((_attribute_spins[key] as SpinBox).value)
	return out


## The §4.11.11 instance shape 开战 passes (per-ship captain ids stay editor
## + export values until W4 consumes escort captains).
func _ship_instance(state: Dictionary) -> Dictionary:
	return {
		"ship_type_id": str(state.get("ship_type_id", "")),
		"durability": int(state.get("durability", 1)),
		"crew": int(state.get("crew", 0)),
		"cannons": int(state.get("cannons", 0)),
		"equipment": {
			"figurehead": str(state.get("figurehead", "")),
			"sail": str(state.get("sail", "")),
		},
		"cargo": {},
	}


## 开战: clamp → keep the configuration → queue the fixture on the SAME seam
## `world_map.gd` uses (`GameState.pending_encounter`, the existing routing
## contract) → S10. The zero-write audit defines what may not CHANGE; the
## transient pending descriptor is consumed (cleared) by S10's open_battle.
func start_battle() -> void:
	apply_clamps()
	last_config = export_config()
	GameState.pending_encounter = build_encounter()
	GameState.change_scene(BATTLE_SCENE)


# --- Input ------------------------------------------------------------------

## `Esc` → S1 (§4.2). The configuration stays in [member last_config], so a
## later 海战 re-entry restores it.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		if route_to_title and ResourceLoader.exists(TITLE_SCENE):
			GameState.change_scene(TITLE_SCENE)


# --- Accessors (tests / hosts) ----------------------------------------------

func player_panel() -> Control:
	return _player_panel


func enemy_panel() -> Control:
	return _enemy_panel


func conditions_panel() -> Panel:
	return _conditions_panel


func player_header() -> Label:
	return _player_header


func enemy_header() -> Label:
	return _enemy_header


## The rows column of `side` (the one-line ship-row region; the enemy
## column is what the compose toggle hides).
func rows_box(side: String) -> Control:
	return _player_rows_box if side == "player" else _enemy_rows_box


## The rows scroll's content node (the stacked ship lines — the scroll
## viewport's child; the members' parent).
func rows_content(side: String) -> Control:
	return rows_box(side).get_child(0) as Control


func player_add_button() -> Button:
	return _player_add


func player_remove_button() -> Button:
	return _player_remove


func enemy_add_button() -> Button:
	return _enemy_add


func enemy_remove_button() -> Button:
	return _enemy_remove


func kind_option() -> OptionButton:
	return _kind_option


func compose_check() -> CheckBox:
	return _compose_check


func ai_level_option() -> OptionButton:
	return _ai_level_option


func archetype_option() -> OptionButton:
	return _archetype_option


func formation_option() -> OptionButton:
	return _formation_option


func enemy_morale_spin() -> SpinBox:
	return _enemy_morale_spin


func player_morale_spin() -> SpinBox:
	return _player_morale_spin


func attribute_spin(key: String) -> SpinBox:
	return _attribute_spins.get(key)


func weapon_option() -> OptionButton:
	return _weapon_option


func armor_option() -> OptionButton:
	return _armor_option


func day_spin() -> SpinBox:
	return _day_spin


func seed_mode_option() -> OptionButton:
	return _seed_mode_option


func seed_spin() -> SpinBox:
	return _seed_spin


func weather_option() -> OptionButton:
	return _weather_option


func wind_option() -> OptionButton:
	return _wind_option


func current_dir_option() -> OptionButton:
	return _current_dir_option


func current_strength_spin() -> SpinBox:
	return _current_strength_spin


func deployment_option() -> OptionButton:
	return _deployment_option


func start_button() -> Button:
	return _start_button


func random_all_button() -> Button:
	return _random_all_button


func import_button() -> Button:
	return _import_button


func export_button() -> Button:
	return _export_button


func zero_write_label() -> Label:
	return _zero_write


func toast_label() -> Label:
	return _toast


# --- Localisation helpers ---------------------------------------------------

## Every label is a `ui_strings.json` key (`10-*` §7.12). W2-B authors the
## `sandbox.*` values; until that merge the read degrades to the raw key
## (the `battle_screen._reason_text` convention) instead of spamming the
## missing-key error or inventing a player-facing string.
func _t(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return key


## A per-value label (`sandbox.kind.pirate`, `battle.formation.line_ahead`,
## `sandbox.dir.N`, …): the authored key wins, else the raw value id shows.
func _t_id(key_prefix: String, id: String) -> String:
	var key := key_prefix if id.is_empty() else "%s.%s" % [key_prefix, id]
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return id


## `I18n.fmt` with the same degrade-to-fallback for a `{placeholder}` key not
## yet authored.
func _tfmt(key: String, values: Dictionary, fallback: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.fmt(key, values)
	var out := fallback
	for name in values:
		out = out.replace("{%s}" % name, str(values[name]))
	return out
