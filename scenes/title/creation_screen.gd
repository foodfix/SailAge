extends Control
## Creation screen (S20) — the Phase-8 two-step new-game flow
## (docs/80-UI-UX.md §4.13; docs/50-* §4.1; docs/IMPLEMENT-Phase8.md §2.8).
##
## The S2 nationality confirm stores the nation in [member pending_nation_id]
## and routes here (docs/80-* §4.2: S1 → S2 → S20 → S4). One scene, two steps:
##
##   1. **出身 background** — the six `data/backgrounds.json` cards (name /
##      bio / the composed bonus line), selectable exactly like the S2 grid.
##   2. **自由点数 free points** — attribute steppers (+5 total) and skill
##      steppers (+3 total), a per-item cap of +3, the 均匀分配 spread-evenly
##      shortcut (attributes +1 each; the first three skills +1 each), the
##      must-spend-all gate (confirm disabled while points remain) and the
##      live derived preview (sighting / fleet speed / duel value).
##
## **Phase-12 W2-B absolute layout** (docs/80-UI-UX.md §4.8.9): the node tree
## IS the element tree — the `Layout`/`Header`/`Footer` flow containers, the
## per-card `Content` boxes and the step-② `Columns`/`SpreadRow`/`Preview`
## boxes are deleted. The two step groups (`StepBackground` / `StepPoints`)
## are plain Controls at their data rects; cards and stepper rows are
## absolute elements placed inside them from the data order on the 32×32
## chrome-tile grid. The step visibility swap and the toggle-pressed card
## semantics (the `Toggle` theme variation) are untouched — only the layout
## changed. (The 2026-11-04 `SPEND_HINT_MIN_W` stepper-pixel pin was a flow
## workaround — the re-centering it guarded is deleted with the flow.)
##
## The preview never re-derives a formula: sighting and speed come from the
## `Character` pure statics (`sighting_radius_for`, `speed_bonus_for`) and the
## duel value is `BattleSimLib.player_duel_base()` — §4.11.6's single duel
## implementation — evaluated on the draft Person that
## `Character.starting_person` builds (exactly the block `new_game` will
## store). The same-source call reads `GameState.player`, so the draft is
## bracketed in for that one call and restored immediately; nothing leaks.
##
## Confirm runs `GameState.new_game(nation_id, true, background_id,
## attr_alloc, skill_alloc)`; its internal §4.1 routing opens the start-port
## screen — the code path S2 used before the two-step flow existed. The S19
## pre-game choices (`npc_preset`, `control_prefs`) are GameState run input
## that `new_game` reads BEFORE its reset (docs/80-* §4.6.3); this screen
## never touches them, so the handoff preserves them by construction.
##
## The creation screen never references Palette constants directly: its
## rects are whole chrome tiles (docs/80-* §4.8.9), and the theme variation
## carries the colors.

## Phase-12 W2-B (docs/80-UI-UX.md §4.8.9): the absolute-tile layout registry —
## every persistent control registers under a stable hierarchical id and the
## step builds re-apply the committed table after re-registering.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

const NATIONALITY_SCENE := "res://scenes/title/nationality_select.tscn"
const BACKGROUNDS_PER_ROW := 3
## One card: 11×8 chrome tiles, on a 12×8-tile pitch inside the `cards`
## block (docs/80-* §4.8.9 — 1 tile = Palette.CHROME_TILE = 32 px).
const CARD_SIZE := Vector2(352, 256)
const CARD_PITCH := Vector2(384, 256)
## The step-② tile geometry (points-relative): the attribute column at tile
## x=0, the skill column at tile x=10, stepper rows stacked from tile y=1
## under their headers; the spread shortcut + hint cell and the preview
## lines sit below the columns (docs/80-* §4.8.9).
const STEPPER_COL_W := 10
## The spread shortcut's rect and the must-spend hint's fixed cell
## (points-relative px — tiles (7,10,11,1) for the hint).
const SPREAD_POS := Vector2(0, 320)
const SPREAD_SIZE := Vector2(192, 64)
const SPEND_HINT_POS := Vector2(224, 320)
const SPEND_HINT_SIZE := Vector2(352, 32)
## The creation extremes are the closed §4.1 step-4 forms; the constants live
## on the model (`50-*`), and this UI only clamps the steppers against them.

## ui_strings keys this screen needs that the shared table does not carry yet
## (W6-D owns `data/ui_strings.json`; this screen must not edit it). Same
## zh+en shape as the JSON so the residual merge is a copy-paste; resolved by
## [method _t_key]. Reported to the W6 orchestrator ledger.
const FALLBACK_STRINGS := {
	"creation.next": {
		"zh": "下一步",
		"en": "Next",
	},
	"creation.bonus_line": {
		"zh": "{attr}+{attr_n}/{skill}+{skill_n}",
		"en": "{attr}+{attr_n}/{skill}+{skill_n}",
	},
}

## The nation S2 handed over (docs/80-* §4.13). Class static — the scene is
## swapped between the write (S2 confirm) and the read (this screen's
## `_ready`), the same transient-carry pattern as `Character.pending_levelup`.
## Consumed exactly once: `_ready` reads and clears it.
static var pending_nation_id: String = ""

## Headless-test seams (the S2 `route_after_confirm` convention): when
## `route_sink` is valid it receives every would-be `change_scene` path, so a
## suite observes the routing without swapping its own scene out.
## `route_after_confirm` keeps governing `new_game`'s internal port routing.
var route_after_confirm: bool = true
var route_sink: Callable = Callable()

## 1 = background cards, 2 = free points.
var _step: int = 1
var _nation_id: String = ""
var _background_id: String = ""
## The step-② drafts: `{attribute_key: points}` / `{skill_key: points}`.
var _attr_alloc: Dictionary = {}
var _skill_alloc: Dictionary = {}
## Card buttons in `backgrounds.json` order (selection styling).
var _cards: Array[Button] = []
## Per-item stepper controls, `{key: {name, value, add, sub}}`.
var _attr_steppers: Dictionary = {}
var _skill_steppers: Dictionary = {}
## The step-② counter headers and preview labels.
var _attr_header: Label = null
var _skill_header: Label = null
var _spend_hint: Label = null
var _preview_labels: Dictionary = {}

@onready var _background: Panel = $Background
@onready var _title: Label = $Title
@onready var _prompt: Label = $Prompt
@onready var _step_background: Control = $StepBackground
@onready var _step_points: Control = $StepPoints
@onready var _back_button: Button = $Back
@onready var _confirm_button: Button = $Confirm


func _ready() -> void:
	# §4.9: the prompt line reads through the theme's `Dim` variation; the
	# title renders the theme's default Label (TEXT). No per-screen overrides.
	_prompt.theme_type_variation = "Dim"
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_back_button.pressed.connect(_go_back)
	_confirm_button.pressed.connect(confirm_selection)
	EventBus.locale_changed.connect(_on_locale_changed)

	# Consume the S2 handoff exactly once; a direct open (a test or a deep
	# route) falls back to the first nation like S2 does, so the screen is
	# never nation-less.
	_nation_id = pending_nation_id
	pending_nation_id = ""
	if _nation_id.is_empty() and not DataLoader.nations_list.is_empty():
		_nation_id = str(DataLoader.nations_list[0].get("id", ""))
	_step = 1
	_build_background_step()
	_show_step()
	# Phase-12 W2-B: one activation after the full build — pins the root,
	# captures the baselines and applies the committed v2 table (a no-op
	# walk until master assembles the fragments at the merge gate).
	_register_static_ids()
	RegistryLib.screen_active("creation", self)


## The static chrome's element ids (docs/80-* §4.8.9). The step-① cards and
## step-② point elements register where they build.
func _register_static_ids() -> void:
	RegistryLib.register("creation", _background, "background",
		{"role": RegistryLib.ROLE_PANEL})
	RegistryLib.register("creation", _title, "title")
	RegistryLib.register("creation", _prompt, "prompt")
	RegistryLib.register("creation", _step_background, "cards")
	RegistryLib.register("creation", _step_points, "points")
	RegistryLib.register("creation", _back_button, "back",
		{"role": RegistryLib.ROLE_BUTTON})
	RegistryLib.register("creation", _confirm_button, "confirm",
		{"role": RegistryLib.ROLE_BUTTON})


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		_go_back()


## Every player-facing line (the no-raw-key check walks it).
func lines() -> Array:
	var out: Array = [_title.text, _prompt.text,
		_back_button.text, _confirm_button.text]
	for container in [_step_background, _step_points]:
		for child in (container as Node).get_children():
			_collect_lines(child, out)
	return out


func _collect_lines(node: Node, out: Array) -> void:
	if node is Label or node is Button:
		out.append((node as Control).text)
	for child in node.get_children():
		_collect_lines(child, out)


# --- Step ① background cards (docs/50-* §4.1 step 1) -------------------------

func _build_background_step() -> void:
	for child in _step_background.get_children():
		_step_background.remove_child(child)
		child.queue_free()
	_cards.clear()
	# The first card is selected until the player picks one (the S2 rule).
	_background_id = ""
	var index := 0
	for background in DataLoader.backgrounds_list:
		var background_id := str(background.get("id", ""))
		if _background_id.is_empty():
			_background_id = background_id
		var card := _build_card(background, index)
		_step_background.add_child(card)
		_cards.append(card)
		index += 1
	_refresh_selection()
	# The rebuilt cards re-registered where they built — re-apply the
	# committed table (a no-op on the interim `{}`).
	RegistryLib.apply_layout("creation")


## One background card: name, bio and the composed bonus line — all read from
## the Background record; nothing about a background is hardcoded here. The
## parts are absolutely placed inside the card rect; the column/row come
## from the data order via [param index].
func _build_card(background: Dictionary, index: int) -> Button:
	var background_id := str(background.get("id", ""))
	var card := Button.new()
	card.name = "Card_%s" % background_id
	card.toggle_mode = true
	# §4.9 texture-mode mapping: a toggle card's selected state rides the
	# `Toggle` variation's pressed cell (the focus sheet ×TOGGLE_MODULATE —
	# the persistent ACCENT ring), not the momentary press dimming.
	card.theme_type_variation = "Toggle"
	card.position = Vector2(
		(index % BACKGROUNDS_PER_ROW) * CARD_PITCH.x,
		floori(index / float(BACKGROUNDS_PER_ROW)) * CARD_PITCH.y)
	card.size = CARD_SIZE
	card.pressed.connect(_on_card_pressed.bind(background_id))

	var name_label := Label.new()
	name_label.name = "BackgroundName"
	name_label.text = I18n.t(background.get("name", {}))
	name_label.position = Vector2(32, 32)
	name_label.size = Vector2(288, 32)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(name_label)

	var bio := Label.new()
	bio.name = "Bio"
	bio.text = I18n.t(background.get("bio", {}))
	bio.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bio.position = Vector2(32, 64)
	bio.size = Vector2(288, 96)
	bio.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(bio)

	var bonus := Label.new()
	bonus.name = "Bonus"
	bonus.text = _bonus_line(background)
	bonus.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bonus.position = Vector2(32, 160)
	bonus.size = Vector2(288, 32)
	bonus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(bonus)

	# Phase-12 W2-B: one data-derived id per card (the backgrounds.json order
	# is the locked data contract) + its persistent parts.
	RegistryLib.register("creation", card, "cards.%s" % background_id,
		{"role": RegistryLib.ROLE_BUTTON, "data_ordered": true})
	RegistryLib.register("creation", name_label, "cards.%s.name" % background_id)
	RegistryLib.register("creation", bio, "cards.%s.bio" % background_id)
	RegistryLib.register("creation", bonus, "cards.%s.bonus" % background_id)

	return card


## "体+3/操船+5" — composed from the record's two bonus tables; the L10nString
## only provides the frame (docs/10-* §3.3 rule 5).
func _bonus_line(background: Dictionary) -> String:
	var attr_bonus: Dictionary = background.get("attribute_bonus", {})
	var skill_bonus: Dictionary = background.get("skill_bonus", {})
	var attr_key := str(attr_bonus.keys()[0]) if not attr_bonus.is_empty() else ""
	var skill_key := str(skill_bonus.keys()[0]) if not skill_bonus.is_empty() else ""
	return _fmt("creation.bonus_line", {
		"attr": _stat_name(attr_key),
		"attr_n": int(attr_bonus.get(attr_key, 0)),
		"skill": _stat_name(skill_key),
		"skill_n": int(skill_bonus.get(skill_key, 0)),
	})


func _on_card_pressed(background_id: String) -> void:
	_background_id = background_id
	_refresh_selection()


func _refresh_selection() -> void:
	# The §4.9 sweep: selection reads through the unified pressed state
	# (the theme styles toggle buttons' pressed bg) — no font-color overrides.
	for card in _cards:
		card.button_pressed = card.name == "Card_%s" % _background_id


# --- Step ② free points (docs/50-* §4.1 step 2, docs/80-* §4.13) -------------

func _build_points_step() -> void:
	for child in _step_points.get_children():
		_step_points.remove_child(child)
		child.queue_free()
	_attr_steppers = {}
	_skill_steppers = {}
	_preview_labels = {}

	# Phase-12 W2-B: the two stepper columns are absolute element blocks —
	# the attribute column at tile x=0, the skill column at tile x=10,
	# stepper rows stacked from tile y=1 under their headers (docs/80-*
	# §4.8.9); the rows are plain Controls, their parts absolutely placed.
	_attr_header = Label.new()
	_attr_header.name = "AttrHeader"
	_attr_header.position = Vector2(0, 0)
	_attr_header.size = Vector2(STEPPER_COL_W * 32, 32)
	_step_points.add_child(_attr_header)
	var attr_index := 0
	for key in CharacterLib.ATTRIBUTES:
		_build_stepper_row(0, attr_index, key, true)
		attr_index += 1

	_skill_header = Label.new()
	_skill_header.name = "SkillHeader"
	_skill_header.position = Vector2(STEPPER_COL_W * 32, 0)
	_skill_header.size = Vector2(STEPPER_COL_W * 32, 32)
	_step_points.add_child(_skill_header)
	var skill_index := 0
	for key in SkillsLib.KEYS:
		_build_stepper_row(STEPPER_COL_W, skill_index, key, false)
		skill_index += 1

	var spread := Button.new()
	spread.name = "Spread"
	spread.text = I18n.t_key("creation.spread")
	spread.position = SPREAD_POS
	spread.size = SPREAD_SIZE
	spread.pressed.connect(_on_spread)
	_step_points.add_child(spread)
	_spend_hint = Label.new()
	_spend_hint.name = "SpendHint"
	_spend_hint.theme_type_variation = "Dim"
	_spend_hint.position = SPEND_HINT_POS
	_spend_hint.size = SPEND_HINT_SIZE
	_step_points.add_child(_spend_hint)

	for preview_index in range(3):
		var line_key: String = ["sighting", "speed", "duel"][preview_index]
		var label := Label.new()
		label.name = "Preview_%s" % line_key
		label.theme_type_variation = "Dim"
		label.position = Vector2(0, (12 + preview_index) * 32)
		label.size = Vector2(608, 32)
		_step_points.add_child(label)
		_preview_labels[line_key] = label

	# Phase-12 W2-B: the rebuilt points elements re-registered where they
	# built — re-apply the committed table (a no-op on the interim `{}`).
	RegistryLib.register("creation", spread, "points.spread",
		{"role": RegistryLib.ROLE_BUTTON})
	RegistryLib.register("creation", _spend_hint, "points.spend_hint")
	RegistryLib.register("creation", _attr_header, "points.attr_header")
	RegistryLib.register("creation", _skill_header, "points.skill_header")
	for line_key in ["sighting", "speed", "duel"]:
		RegistryLib.register("creation", _preview_labels[line_key],
			"points.preview.%s" % line_key)
	RegistryLib.apply_layout("creation")


## One stepper row: an absolute element of the `points` block — the column's
## tile x ([param col_tile_x]) and the stack index place it; the name, the
## live value and the ± buttons are absolutely placed inside the row rect.
func _build_stepper_row(col_tile_x: int, index: int, key: String,
		is_attr: bool) -> void:
	var row := Control.new()
	row.name = "Row_%s" % key
	row.position = Vector2(col_tile_x * 32, (1 + index) * 32)
	row.size = Vector2(STEPPER_COL_W * 32, 32)
	_step_points.add_child(row)

	var name_label := Label.new()
	name_label.name = "StatName"
	name_label.text = _stat_name(key)
	name_label.position = Vector2(0, 0)
	name_label.size = Vector2(128, 32)
	row.add_child(name_label)

	var value_label := Label.new()
	value_label.name = "StatValue"
	value_label.position = Vector2(128, 0)
	value_label.size = Vector2(32, 32)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	var sub := Button.new()
	sub.name = "Sub"
	sub.text = I18n.t_key("creation.stepper.sub")
	sub.position = Vector2(192, 0)
	sub.size = Vector2(64, 32)
	sub.pressed.connect(_on_step.bind(key, is_attr, -1))
	row.add_child(sub)

	var add := Button.new()
	add.name = "Add"
	add.text = I18n.t_key("creation.stepper.add")
	add.position = Vector2(256, 0)
	add.size = Vector2(64, 32)
	add.pressed.connect(_on_step.bind(key, is_attr, 1))
	row.add_child(add)

	(_attr_steppers if is_attr else _skill_steppers)[key] = {
		"value": value_label, "add": add, "sub": sub,
	}
	# Phase-12 W2-B: one data-derived id per stepper row (the §4.1 attribute
	# / skill orders are the locked data contracts) + its persistent parts.
	var group := "attrs" if is_attr else "skills"
	RegistryLib.register("creation", row, "points.%s.%s" % [group, key],
		{"data_ordered": true})
	RegistryLib.register("creation", name_label,
		"points.%s.%s.name" % [group, key])
	RegistryLib.register("creation", value_label,
		"points.%s.%s.value" % [group, key])
	RegistryLib.register("creation", sub, "points.%s.%s.sub" % [group, key],
		{"role": RegistryLib.ROLE_BUTTON})
	RegistryLib.register("creation", add, "points.%s.%s.add" % [group, key],
		{"role": RegistryLib.ROLE_BUTTON})


## One stepper click. The + arm refuses beyond the §4.1 per-item cap +3 or
## when no budget remains; the − arm refuses below zero. The draft can
## therefore never break the creation extremes (attribute ≤ 21, skill ≤ 13).
func _on_step(key: String, is_attr: bool, delta: int) -> void:
	var alloc := _attr_alloc if is_attr else _skill_alloc
	var current := maxi(0, int(alloc.get(key, 0)))
	if delta > 0:
		var remaining: int = _remaining_attr() if is_attr else _remaining_skill()
		if current >= CharacterLib.ALLOC_ITEM_CAP or remaining <= 0:
			return
		alloc[key] = current + 1
	else:
		if current <= 0:
			return
		if current == 1:
			alloc.erase(key)
		else:
			alloc[key] = current - 1
	_refresh_points()


## 均匀分配 (docs/50-* §4.1 step ②): attributes +1 each and the first three
## skills +1 each — exactly the full +5/+3 budget, inside every per-item cap.
func _on_spread() -> void:
	_attr_alloc = {}
	for key in CharacterLib.ATTRIBUTES:
		_attr_alloc[key] = 1
	_skill_alloc = {}
	for key in SkillsLib.KEYS.slice(0, 3):
		_skill_alloc[key] = 1
	_refresh_points()


func _remaining_attr() -> int:
	return CharacterLib.ATTR_ALLOC_TOTAL \
		- CharacterLib.attr_alloc_total(_attr_alloc)


func _remaining_skill() -> int:
	return CharacterLib.SKILL_ALLOC_TOTAL \
		- CharacterLib.skill_alloc_total(_skill_alloc)


## One refresh pass over the counters, every stepper, the gate and the
## preview — run after any draft change and on locale change.
func _refresh_points() -> void:
	for key in CharacterLib.ATTRIBUTES:
		_refresh_row(_attr_steppers[key], key, true)
	for key in SkillsLib.KEYS:
		_refresh_row(_skill_steppers[key], key, false)
	_attr_header.text = I18n.fmt("creation.points.attributes",
		{"count": _remaining_attr()})
	_skill_header.text = I18n.fmt("creation.points.skills",
		{"count": _remaining_skill()})
	var left := _remaining_attr() + _remaining_skill()
	_prompt.text = I18n.fmt("creation.points.left", {"count": left})
	var must_spend := left > 0
	_confirm_button.disabled = must_spend
	_confirm_button.tooltip_text = \
		I18n.t_key("creation.points.must_spend") if must_spend else ""
	_spend_hint.text = I18n.t_key("creation.points.must_spend") \
		if must_spend else ""
	_refresh_preview()


func _refresh_row(controls: Dictionary, key: String, is_attr: bool) -> void:
	var alloc: Dictionary = _attr_alloc if is_attr else _skill_alloc
	var spent := maxi(0, int(alloc.get(key, 0)))
	var base: int = _attr_base(key) if is_attr else _skill_base(key)
	(controls["value"] as Label).text = str(base + spent)
	var at_cap := spent >= CharacterLib.ALLOC_ITEM_CAP
	var add := controls["add"] as Button
	add.disabled = at_cap or (_remaining_attr() if is_attr
		else _remaining_skill()) <= 0
	add.tooltip_text = _t_key("creation.cap_reached") if at_cap else ""
	(controls["sub"] as Button).disabled = spent <= 0


# --- Live derived preview (docs/80-* §4.13: same-source formulas) ------------

## The draft Person for an alloc pair — the same builder `new_game` stores,
## so the preview can never drift from the real block.
func _draft_person(attr_alloc: Dictionary,
		skill_alloc: Dictionary) -> Dictionary:
	return CharacterLib.starting_person(
		_nation_id, _background_id, attr_alloc, skill_alloc)


## §4.11.6's single duel formula on a draft. `player_duel_base()` reads the
## live player block, so the draft is bracketed in for the one call —
## no formula is copied here.
func _duel_value_for(draft: Dictionary) -> int:
	var saved: Dictionary = GameState.player
	GameState.player = draft
	var value: int = BattleSimLib.player_duel_base()
	GameState.player = saved
	return value


## The six preview numbers for the current draft and the zero-alloc base
## (each line shows `base → value`, docs/80-* §4.13). The suite pins these
## against the §4.2/§4.3 closed forms.
func preview_values() -> Dictionary:
	var base := _draft_person({}, {})
	var draft := _draft_person(_attr_alloc, _skill_alloc)
	return {
		"sighting_base": CharacterLib.sighting_radius_for(
			int(base["skills"]["navigation"])),
		"sighting_value": CharacterLib.sighting_radius_for(
			int(draft["skills"]["navigation"])),
		"speed_base": CharacterLib.speed_bonus_for(
			int(base["skills"]["seamanship"])),
		"speed_value": CharacterLib.speed_bonus_for(
			int(draft["skills"]["seamanship"])),
		"duel_base": _duel_value_for(base),
		"duel_value": _duel_value_for(draft),
	}


func _refresh_preview() -> void:
	var values := preview_values()
	_set_preview_line("sighting", "creation.preview.sighting",
		str(int(values["sighting_base"])), str(int(values["sighting_value"])))
	_set_preview_line("speed", "creation.preview.speed",
		_pct(values["speed_base"]), _pct(values["speed_value"]))
	_set_preview_line("duel", "creation.preview.duel",
		str(int(values["duel_base"])), str(int(values["duel_value"])))


func _set_preview_line(line_key: String, name_key: String, base: String,
		value: String) -> void:
	(_preview_labels[line_key] as Label).text = "%s %s" % [
		I18n.t_key(name_key),
		_fmt("creation.preview.base_value", {"base": base, "value": value}),
	]


## The speed bonus as a percent with one decimal (`skill/300` clamps at +30%,
## so one decimal resolves every creation-time value).
func _pct(value: float) -> String:
	return "%.1f%%" % [value * 100.0]


# --- Flow --------------------------------------------------------------------

func _show_step() -> void:
	_back_button.text = I18n.t_key("ui.back")
	_step_background.visible = _step == 1
	_step_points.visible = _step == 2
	if _step == 1:
		_title.text = I18n.t_key("creation.step.background")
		var background: Dictionary = DataLoader.get_background(_background_id)
		_prompt.text = I18n.t(background.get("bio", {})) \
			if not background.is_empty() else ""
		_confirm_button.text = _t_key("creation.next")
		_confirm_button.disabled = _background_id.is_empty()
		_confirm_button.tooltip_text = ""
	else:
		# Rebuilt on every entry and every locale change so the counters,
		# steppers and preview re-translate (the build clears first).
		_build_points_step()
		_title.text = I18n.t_key("creation.step.points")
		_confirm_button.text = I18n.t_key("creation.confirm")
		_refresh_points()


## Step ① confirm advances to the free points; step ② confirm (only with
## every point spent) starts the run per docs/50-* §4.1 step 5 — the model
## owns the block, `new_game` owns the routing.
func confirm_selection() -> void:
	if _step == 1:
		if _background_id.is_empty():
			return
		_step = 2
		_show_step()
		return
	if _remaining_attr() > 0 or _remaining_skill() > 0:
		return
	GameState.new_game(_nation_id, route_after_confirm, _background_id,
		_attr_alloc, _skill_alloc)


## Back navigation (docs/80-* §4.2: S20's back edge is S2).
func _go_back() -> void:
	_route(NATIONALITY_SCENE)


## The scene router with the headless-test seam (see [member route_sink]).
func _route(path: String) -> void:
	if route_sink.is_valid():
		route_sink.call(path)
		return
	GameState.change_scene(path)


# --- Helpers -----------------------------------------------------------------

## The attribute/skill display name: the five attribute names live in the
## unified `char.attr.*` family (the W7 unify — the duplicate `attr.*` keys
## D authored stay as inert duplicates), the eight skills in `skill.*`.
func _stat_name(key: String) -> String:
	if key.is_empty():
		return ""
	if key in CharacterLib.ATTRIBUTES:
		return _t_key("char.attr.%s" % key)
	return I18n.t_key("skill.%s" % key)


## The creation-time base value of one attribute: base 10 + the nation's +5
## on its bonus attribute + the background's +3 (before any free points).
func _attr_base(key: String) -> int:
	var nation: Dictionary = DataLoader.get_nation(_nation_id)
	var background: Dictionary = DataLoader.get_background(_background_id)
	var value := CharacterLib.BASE_ATTRIBUTE
	if str(nation.get("bonus_attribute", "")) == key:
		value += CharacterLib.NATION_BONUS_AMOUNT
	var attr_bonus: Dictionary = background.get("attribute_bonus", {})
	if attr_bonus.has(key):
		value += int(attr_bonus[key])
	return value


## The creation-time base value of one skill: 0 + the nation's signature +5
## + the background's +5 (before any free points).
func _skill_base(key: String) -> int:
	var nation: Dictionary = DataLoader.get_nation(_nation_id)
	var background: Dictionary = DataLoader.get_background(_background_id)
	var value := 0
	if str(nation.get("bonus_skill", "")) == key:
		value += CharacterLib.NATION_BONUS_AMOUNT
	var skill_bonus: Dictionary = background.get("skill_bonus", {})
	if skill_bonus.has(key):
		value += int(skill_bonus[key])
	return value


## `I18n.t_key` for a key this screen also carries in [constant
## FALLBACK_STRINGS] until W6-D merges it (the tavern-screen pattern).
func _t_key(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	var l10n: Dictionary = FALLBACK_STRINGS.get(key, {})
	if l10n.is_empty():
		return I18n.t_key(key)
	return I18n.t(l10n)


## [method _t_key] plus `{name}` substitution (docs/80-* §4.4).
func _fmt(key: String, values: Dictionary = {}) -> String:
	var text := _t_key(key)
	for name in values:
		text = text.replace("{%s}" % name, str(values[name]))
	return text


func _on_locale_changed(_locale: String) -> void:
	_build_background_step()
	_show_step()
