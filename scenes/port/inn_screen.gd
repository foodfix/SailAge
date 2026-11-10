extends Control
## Inn (S8) — rest + harbor relief (docs/30-PORTS-AND-TRADE.md §4.6, §4.7;
## docs/50-CHARACTER-AND-PROGRESSION.md §4.7, §6; docs/80-UI-UX.md §4.3–§4.8,
## §4.1 S8 / §4.2 "S4 ──facility──► S5/S6/S7/S8 ──Back/Esc──► S4").
##
## Screen contract:
##   * a status box with morale (+ tier label), gold and day;
##   * **Rest 3 days** — disabled with `inn.no_gold` while the purse is below
##     30g; one click charges the lodging and runs three port ledger days;
##   * **Work an odd job** — the harbor-relief fallback. Enabled **iff**
##     `InnEngine.odd_job_eligible()`; otherwise disabled with the generic
##     `inn.odd_job.ineligible` label plus the specific reason key. The state
##     machine is re-evaluated on screen open and after every click (§4.7
##     step 1 "whenever `inn_screen` opens and after each odd job");
##   * `Esc` / Back → the port hub (S4).
##
## All numbers and rules live in `scripts/port/inn_engine.gd`; this scene only
## renders and routes (docs/90-* §4 "scripts/ holds pure-logic classes").
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.
##
## **Absolute tile layout (Phase 12 W2-A, docs/80-* §4.8.9; 10-* §4.23).** The
## node tree IS the element tree: every group parent is a plain Control at its
## data rect and every leaf hangs directly off its registered parent — the
## flow containers (MarginContainer → VBox chains) are deleted. The build code
## authors the tile rects below (today's captured look, flattened to the
## 32-tile grid); `data/ui_layout.json` (assembled from this screen's capture
## fragment) is the whole truth once managed — the authored values are the
## same, so `apply_layout` is idempotent. The captains section is the screen's
## one dynamic list: rows register `{"list": "captains"}` and take
## [method LayoutRegistry.list_rect] positions (the same tiles as the
## authored fallback block), and a row's parts are absolutely-placed children
## of the row node.

const PaletteLib := preload("res://scripts/palette.gd")
const InnEngineLib := preload("res://scripts/port/inn_engine.gd")
## Phase-10 sweep (§4.9): the status box renders morale through the kit's
## value_bar atom (tier via the doc-pinned §4.8 morale thresholds), and the
## scene chrome retires to the shared theme.
const UiKitLib := preload("res://scripts/ui_kit.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
## The clock text in the day label (`20-*` §4.3 amended).
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## Task L (docs/80-* §4.7.8): the "captains resting" rows.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
const GameOverHostLib := preload("res://scenes/ui_shared/game_over_host.gd")
## The Phase-12 absolute-tile layout registry (docs/80-* §4.8.9): the data
## file is the layout; the registration below feeds the capture fragment.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## This screen's id in the registry (LayoutRegistry.SCREENS).
const LAYOUT_SCREEN := "inn"

## --- The authored tile table (parent-relative 32-px tiles) -------------------
## One tile = `Palette.CHROME_TILE`. The screen root is the canvas; group
## parents carry their own rects and their children address the group's space.

const TILE := PaletteLib.CHROME_TILE
## The captains list block (content-node tiles): row *i* at
## `(0, i·row_h)`, size `(w, row_h)` — non-scrolling, so the block's viewport
## is the base itself (the capture emits the same values).
const CAPTAINS_LIST := "captains"
const CAPTAINS_BASE_W := 58
const CAPTAINS_ROW_H := 2
## Captain-row internals (row-local tiles): the §4.8 role badge slot, the
## sighting line, and the limited-talk verb at the right edge.
const CAPTAIN_BADGE_RECT := Rect2i(0, 0, 1, 2)
const CAPTAIN_TEXT_W := 44
const CAPTAIN_TALK_RECT := Rect2i(52, 0, 6, 2)

## Phase-8 W5-C (docs/80-* §4.11.1): the limited-talk `ui_strings` keys —
## reported for the W6-D residual merge; until then the rows render from this
## local table (the tavern-screen FALLBACK_STRINGS pattern).
const TALK_FALLBACK_STRINGS := {
	"inn.talk.result": {
		"zh": "与{name}闲谈,熟悉度 +1。",
		"en": "You chatted with {name}; familiarity +1.",
	},
	"inn.talk.done": {
		"zh": "本次进港已谈过话。",
		"en": "You already talked this visit.",
	},
}

## §4.8 morale tiers for the kit value_bar (docs/80-* §4.8: yellow < 40,
## red < 20 — the same thresholds `UiKit.auto_tier` takes).
const MORALE_GOOD_MIN := 40
const MORALE_WARN_MIN := 20

## The morale value_bar under the status line (built once in `_ready`,
## re-tiered in `_bind`). Null-safe until it is built.
var _morale_bar: ProgressBar = null

## Emitted when the odd-job button's state machine re-evaluates (`eligible` is
## the new value). Tests observe it instead of reaching into the widgets.
signal odd_job_state_changed(eligible: bool)
## Emitted after a successful rest / odd job with the ui key of its message.
signal message_shown(key: String)
## Emitted right before the S8 → S4 route.
signal left_inn

@onready var _background: Panel = $Background
@onready var _hud: Control = $HUD
@onready var _header: Control = $header
@onready var _title: Label = $header/Title
@onready var _status: Panel = $status
@onready var _morale_label: Label = $status/Morale
@onready var _gold_label: Label = $status/Gold
@onready var _day_label: Label = $status/Day
@onready var _actions: Control = $actions
@onready var _rest_button: Button = $actions/RestButton
@onready var _rest_hint: Label = $actions/RestHint
@onready var _odd_job_button: Button = $actions/OddJobButton
@onready var _odd_job_hint: Label = $actions/OddJobHint
@onready var _footer: Control = $footer
@onready var _back_button: Button = $footer/Back

## Routing switch for headless tests (the `port_screen.route_to_world`
## convention): with `false`, [method leave] runs the state transition and
## emits [signal left_inn] without replacing the scene.
var route_to_port: bool = true

## ui key of the most recent action's message (`""` before the first action).
## The HUD toast shows the same text; tests read this instead of racing the
## 2.5s toast timer (docs/80-* §4.7).
var last_message_key: String = ""

## Current disabled-reason key for the odd-job button (`""` when enabled).
var _odd_job_reason: String = ""

## Task L (§4.7.8): the "captains resting" list (code-built under the actions
## group) — header + rows group and the `{id, name, role}` seam rows.
var _captains_header: Label = null
var _captains_box: Control = null
var _captain_rows: Array = []
## Phase-11 (§4.8.9): per dynamic section, true once its first build has
## registered (see [_register_dynamic] for the first-build/rebuild split).
var _layout_built: Dictionary = {}


func _ready() -> void:
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): rest rolls ledger days
	# while this screen is up — the game-over screen must rise over the inn too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the theme (TEXT is the theme
	# default; secondary hints carry the `Dim` variation) and the status box
	# renders the themed Panel chrome — the hand-built box is gone.
	_rest_hint.theme_type_variation = "Dim"
	_odd_job_hint.theme_type_variation = "Dim"
	for button in [_rest_button, _odd_job_button, _back_button]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_rest_button.pressed.connect(_on_rest_pressed)
	_odd_job_button.pressed.connect(_on_odd_job_pressed)
	_back_button.pressed.connect(leave)

	# S8 keeps the S4 bars (docs/80-* §4.5: the port screens share the HUD);
	# the sea viewport (minimap + weather glyph) stays hidden as on S4.
	_hud.set_minimap_visible(false)

	# Phase 12 (§4.8.9): the authored tile rects — every static at its data
	# rect, the groups as plain Controls, before anything registers.
	_place_statics()
	_build_captains_section()
	_register_layout()

	_bind()

	# Phase-11 (§4.8.9): the build is registered — activate the screen (pins
	# the root, captures baselines, applies the committed table; the interim
	# `{}` file leaves the authored rects standing).
	RegistryLib.screen_active(LAYOUT_SCREEN, self)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.clock_changed.connect(_on_clock_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)


## Phase 12 (§4.8.9): one authored rect = one `position`/`size` write, in
## the DIRECT parent's tile space (point anchors everywhere; nothing is
## stretched).
func _place(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(TILE)
	control.size = Vector2(rect.size) * float(TILE)


## The authored tile table — today's captured look, flattened to the grid
## (the committed rows live in `data/ui_layout.json
## `).
func _place_statics() -> void:
	_place(_header, Rect2i(1, 1, 58, 1))
	_place(_title, Rect2i(0, 0, 58, 1))
	_place(_status, Rect2i(1, 2, 58, 6))
	_place(_morale_label, Rect2i(1, 1, 57, 1))
	_place(_gold_label, Rect2i(1, 3, 57, 1))
	_place(_day_label, Rect2i(1, 4, 57, 1))
	_place(_actions, Rect2i(1, 9, 58, 10))
	_place(_rest_button, Rect2i(0, 0, 10, 2))
	_place(_rest_hint, Rect2i(0, 2, 58, 1))
	_place(_odd_job_button, Rect2i(0, 4, 13, 2))
	_place(_odd_job_hint, Rect2i(0, 6, 58, 2))
	_place(_footer, Rect2i(1, 30, 58, 2))
	_place(_back_button, Rect2i(54, 0, 4, 2))


func _unhandled_input(event: InputEvent) -> void:
	# §4.3 "Esc = back / close modal"; S8's only back edge is the port hub.
	# A modal owns input first (§6 "modals consume all input").
	if event.is_action_pressed("back"):
		if has_modal():
			return
		get_viewport().set_input_as_handled()
		leave()
		return


## True while a modal is up on this screen (the HUD's queued dialogs or any
## dialog in the `modal_overlay` group); Esc then closes that instead.
func has_modal() -> bool:
	if _hud != null and _hud.has_method("has_modal") and _hud.has_modal():
		return true
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	return false


# --- Public API (tests / T11) ----------------------------------------------

## Re-evaluates both buttons from the live state. `_bind()` is the single
## implementation; this alias exists so a host/test can say *why* it refreshes.
func refresh() -> void:
	_bind()


## True while the odd-job button is clickable (mirrors the engine predicate).
func odd_job_enabled() -> bool:
	return not _odd_job_button.disabled


## Specific disabled-reason key of the odd-job button (`""` when enabled).
func odd_job_reason() -> String:
	return _odd_job_reason


## True when an inn action is possible at all: the scene may be opened
## standalone from the editor, where there is no run to spend days in.
func has_run() -> bool:
	return not GameState.player.is_empty()


## Back to the port hub. Returns false (no route) when the scene was opened
## without a docked port — that only happens standalone from the editor.
func leave() -> bool:
	left_inn.emit()
	if not route_to_port:
		return true
	if not has_run() or GameState.current_port == null:
		push_warning("InnScreen: leave() with no docked port; nothing to return to")
		return false
	GameState.change_scene(PORT_SCENE)
	return true


# --- Binding ---------------------------------------------------------------

## Rebuilds every label and **re-runs the odd-job state machine** (docs/50-*
## §4.7 step 1). Called on ready, on locale change, on ledger state changes and
## explicitly after each action.
func _bind() -> void:
	var port := _port_name()
	_title.text = I18n.fmt("inn.title", {"port": port})
	_morale_label.text = "%s (%s)" % [
		I18n.fmt("inn.morale", {"amount": GameState.morale}),
		I18n.t_key("world.morale.%s" % HudLib.morale_tier(GameState.morale)),
	]
	# The tier color rides the kit value_bar (§4.8 morale thresholds); the
	# label itself stays on the theme's TEXT.
	_refresh_morale_bar()
	_gold_label.text = I18n.fmt(
		"ui.gold_amount", {"gold": HudLib.format_thousands(GameState.gold)}
	)
	_day_label.text = I18n.fmt("world.day_time", {
		"day": GameState.day, "time": SailingSimLib.clock_text(),
	})

	_bind_rest()
	_bind_odd_job()
	_bind_captains()

	_back_button.text = I18n.t_key("ui.back")


## Re-tiered kit value_bar under the morale line (§4.9: the atom bakes the
## tier into its fill at build time, so a changed morale rebuilds it). The
## bar is a registered static (`status.morale_bar`) at its authored slot —
## the rebuild re-places it there.
func _refresh_morale_bar() -> void:
	if _morale_bar != null and is_instance_valid(_morale_bar):
		_status.remove_child(_morale_bar)
		_morale_bar.queue_free()
	var tier := UiKitLib.auto_tier(GameState.morale, MORALE_GOOD_MIN,
		MORALE_WARN_MIN)
	_morale_bar = UiKitLib.value_bar(GameState.morale, 100, tier)
	_status.add_child(_morale_bar)
	_place(_morale_bar, Rect2i(1, 2, 57, 1))
	_register_dynamic("morale_bar", [{
		"control": _morale_bar, "id": "status.morale_bar",
		"opts": {"role": RegistryLib.ROLE_PLAIN},
	}])


func _bind_rest() -> void:
	_rest_button.text = I18n.fmt("inn.rest_cost", {
		"day": InnEngineLib.REST_DAYS,
		"price": InnEngineLib.REST_COST,
	})
	# `inn.rest` is the short action label ("Rest 3 days"); the button carries
	# the priced variant (§4.7 wireframe) and the short form rides along as the
	# tooltip, so both documented keys are live and localized.
	_rest_button.tooltip_text = I18n.fmt("inn.rest", {"day": InnEngineLib.REST_DAYS})
	var affordable := can_rest_now()
	_rest_button.disabled = not affordable
	# Disabled reason (§4.6 + docs/80-* §4.7 "disabled with reason"): the only
	# way rest is refused at the engine level is an unaffordable purse.
	_rest_hint.visible = not affordable
	_rest_hint.text = "" if affordable else I18n.t_key("inn.no_gold")


func _bind_odd_job() -> void:
	var eligible := has_run() and InnEngineLib.odd_job_eligible()
	_odd_job_reason = "" if eligible else _reason_for_ui()
	_odd_job_button.disabled = not eligible
	# Eligible: the offer label. Disabled: the generic "relief is only for the
	# penniless without a ship" label plus the specific reason underneath
	# (docs/30-* §4.7, docs/50-* §4.7 step 3).
	_odd_job_button.text = I18n.t_key(
		"inn.odd_job.offer" if eligible else "inn.odd_job.ineligible"
	)
	_odd_job_hint.visible = not eligible
	_odd_job_hint.text = "" if eligible else _reason_text()
	odd_job_state_changed.emit(eligible)


## Localised specific reason, or "" while the key is still awaiting the
## orchestrator's `ui_strings.json` merge (`ui_strings.json` is
## orchestrator-owned during parallel waves; a missing key must not spam
## `I18n` errors — the same guard `hud.toast_key` uses). The key itself is
## always available through [method odd_job_reason], so the disabled state is
## testable before the merge.
func _reason_text() -> String:
	if not DataLoader.ui_strings.has(_odd_job_reason):
		return ""
	return I18n.t_key(_odd_job_reason)


# --- Captains resting (docs/80-* §4.7.8, task L) -----------------------------

## The captain rows currently rendered (`{id, name, role, nation_id}`) — the
## headless seam.
func captain_rows() -> Array:
	return _captain_rows.duplicate()


## Builds the section shell once (header + rows group) under the actions
## group, at its authored rects. The rows group is the captains list block's
## content node (a plain Control — nothing inside it is flow-laid).
func _build_captains_section() -> void:
	_captains_header = Label.new()
	_captains_header.name = "CaptainsHeader"
	add_child(_captains_header)
	_place(_captains_header, Rect2i(1, 20, 58, 1))
	_captains_box = Control.new()
	_captains_box.name = "CaptainsRows"
	_captains_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_captains_box)
	_place(_captains_box, Rect2i(1, 21, 58, 4))


## Row *i*'s rect for the captains list block — px in the rows group's space:
## the data block when managed, the same tiles authored otherwise.
func _captain_row_rect(index: int) -> Rect2:
	var rect := RegistryLib.list_rect(LAYOUT_SCREEN, CAPTAINS_LIST, index)
	if rect != Rect2():
		return rect
	return Rect2(
		Vector2(0, index * CAPTAINS_ROW_H) * float(TILE),
		Vector2(CAPTAINS_BASE_W, CAPTAINS_ROW_H) * float(TILE))


## The docked captains whose seeded facility roll landed on the inn (any
## docked fleet is inn-eligible, §4.7.8), present today.
func _bind_captains() -> void:
	if _captains_box == null:
		return
	for child in _captains_box.get_children():
		_captains_box.remove_child(child)
		child.queue_free()
	_captain_rows = []
	if not has_run() or GameState.current_port == null:
		_captains_header.visible = false
		return
	_captains_header.visible = true
	_captains_header.text = I18n.t_key("captain.section.inn")
	var port_id := str(GameState.current_port)
	for entry in NpcIntelLib.sightings(port_id, NpcIntelLib.FACILITY_INN):
		_captain_rows.append({
			"id": str(entry.get("id", "")),
			"captain_id": str(entry.get("captain_id", "")),
			"name": str(entry.get("name", "")),
			"role": str(entry.get("role", "")),
			"nation_id": str(entry.get("nation_id", "")),
		})
	if _captain_rows.is_empty():
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = "-"
		empty.theme_type_variation = "Dim"
		_captains_box.add_child(empty)
		# The empty marker is a `captains` LIST MEMBER placed at the
		# block's row 0 (builder-owned placement — the coverage check
		# exempts list members; docs/80-* §4.8.9).
		var rect := RegistryLib.list_rect(LAYOUT_SCREEN, CAPTAINS_LIST, 0)
		if rect == Rect2():
			rect = Rect2(Vector2.ZERO,
					Vector2(CAPTAINS_BASE_W, CAPTAINS_ROW_H) * float(TILE))
		empty.set_anchors_preset(Control.PRESET_TOP_LEFT)
		empty.position = rect.position
		empty.size = rect.size
		_register_dynamic("captains", [{
			"control": empty, "id": "captains.rows.empty",
			"opts": {"role": RegistryLib.ROLE_PLAIN,
				"list": CAPTAINS_LIST},
		}])
		return
	var entries: Array = []
	var index := 0
	for entry in _captain_rows:
		_build_captain_row(entry, index, entries)
		index += 1
	_register_dynamic("captains", entries)


## One captain row: a plain Control at the block's row rect; the sighting
## text, the §4.8 role badge (an absent id adds nothing — the flat fallback)
## and the 受限谈话 limited-talk verb are absolutely-placed children of the
## row (no per-row flow containers, §4.8.9).
func _build_captain_row(entry: Dictionary, index: int,
		entries: Array) -> void:
	var row := Control.new()
	row.name = "Captain_%s" % str(entry["id"])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_captains_box.add_child(row)
	row.position = _captain_row_rect(index).position
	row.size = _captain_row_rect(index).size
	var row_id := "captains.rows.%s" % str(entry["id"])
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": CAPTAINS_LIST},
	})
	# The §4.8 role badge (§4.9 icon params): an absent id renders nothing
	# (the flat fallback — the registry fills at W4-D).
	var badge := UiKitLib.hero_texture("role_%s" % str(entry["role"]))
	var text_x := 0
	if badge != null:
		var icon := TextureRect.new()
		icon.name = "RoleBadge"
		icon.texture = badge
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		row.add_child(icon)
		_place(icon, CAPTAIN_BADGE_RECT)
		text_x = 1
	var text := Label.new()
	text.name = "Text"
	text.text = "%s · %s" % [str(entry["name"]),
		I18n.t_key("captain.role.%s" % str(entry["role"]))]
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text)
	_place(text, Rect2i(text_x, 0, CAPTAIN_TEXT_W - text_x, 2))
	# Phase-8 W5-C (docs/80-* §4.11.1): the 受限谈话 limited-talk verb —
	# +1 extra familiarity for one sighted captain, once per port visit.
	var talk := UiKitLib.button("interact.verb.talk")
	talk.name = "Talk"
	var captain_id := str(entry.get("captain_id", ""))
	if not InnEngineLib.can_talk(_port_id()):
		talk.disabled = true
		talk.tooltip_text = _talk_text("inn.talk.done")
	elif captain_id.is_empty():
		talk.disabled = true
	else:
		talk.pressed.connect(_on_talk_pressed.bind(captain_id,
			str(entry["name"])))
	row.add_child(talk)
	_place(talk, CAPTAIN_TALK_RECT)


func _port_id() -> String:
	var value = GameState.current_port
	if not (value is String) or (value as String).is_empty():
		return ""
	return value


## The limited-talk click (§4.11.1): one +1 familiarity per port visit, the
## `inn.talk.result` message records the captain.
func _on_talk_pressed(captain_id: String, captain_name: String) -> void:
	var port_id := str(GameState.current_port)
	if InnEngineLib.talk(captain_id, port_id):
		last_message_key = "inn.talk.result"
		message_shown.emit("inn.talk.result")
		if _hud != null and _hud.has_method("toast_text"):
			_hud.toast_text(_talk_fmt("inn.talk.result", {"name": captain_name}))
	_bind()


## `I18n` text for a talk key this screen also carries in
## [constant TALK_FALLBACK_STRINGS] until W6-D merges it.
func _talk_text(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return I18n.t(TALK_FALLBACK_STRINGS.get(key, {}))


## [method _talk_text] plus `{name}` substitution (docs/80-* §4.4).
func _talk_fmt(key: String, values: Dictionary) -> String:
	var text := _talk_text(key)
	for name in values:
		text = text.replace("{%s}" % name, str(values[name]))
	return text


## The engine's reason, or `inn.odd_job.ineligible` itself when the only
## blocker is "no run in progress" (standalone editor load).
func _reason_for_ui() -> String:
	var reason := InnEngineLib.ineligible_reason()
	return reason if not reason.is_empty() else "inn.odd_job.ineligible"


## `can_rest()` plus the "a run exists" guard (standalone editor load).
func can_rest_now() -> bool:
	return has_run() and InnEngineLib.can_rest()


func _port_name() -> String:
	var value = GameState.current_port
	if not (value is String) or (value as String).is_empty():
		return "-"
	var port := DataLoader.get_port(value)
	return I18n.t(port.get("name", {})) if not port.is_empty() else "-"


# --- Layout id registry (docs/80-UI-UX.md §4.8.9, Phase 12 W2-A) -------------

## Registers every persistent control with its stable hierarchical id. The
## statics carry the authored rects above (the capture emits them as the
## screen's fragment); the captain rows are list members — their ids carry
## the `list` flag and take `list_rect` positions.

func _register_layout() -> void:
	_reg(_background, "background", RegistryLib.ROLE_PANEL)
	_reg(_header, "header", RegistryLib.ROLE_PLAIN)
	_reg(_title, "header.title", RegistryLib.ROLE_PLAIN)
	_reg(_status, "status", RegistryLib.ROLE_PANEL)
	_reg(_morale_label, "status.morale", RegistryLib.ROLE_PLAIN)
	_reg(_gold_label, "status.gold", RegistryLib.ROLE_PLAIN)
	_reg(_day_label, "status.day", RegistryLib.ROLE_PLAIN)
	_reg(_actions, "actions", RegistryLib.ROLE_PLAIN)
	_reg(_rest_button, "actions.rest", RegistryLib.ROLE_BUTTON)
	_reg(_rest_hint, "actions.rest_hint", RegistryLib.ROLE_PLAIN)
	_reg(_odd_job_button, "actions.work_odd_job", RegistryLib.ROLE_BUTTON)
	_reg(_odd_job_hint, "actions.odd_job_hint", RegistryLib.ROLE_PLAIN)
	_reg(_footer, "footer", RegistryLib.ROLE_PLAIN)
	_reg(_back_button, "footer.back", RegistryLib.ROLE_BUTTON)
	_reg(_captains_header, "captains.header", RegistryLib.ROLE_PLAIN)
	_reg(_captains_box, "captains.rows", RegistryLib.ROLE_PLAIN)


## One static registration — kind omitted (auto-derives from the parent).
func _reg(control: Control, id: String, role: String) -> void:
	RegistryLib.register(LAYOUT_SCREEN, control, id, {"role": role})


## Registers one rebuilt dynamic row set (the captain rows, the morale bar).
## `entries` = [{control, id, opts}]. A section's FIRST build registers
## synchronously — inside `_ready`, ahead of `screen_active`, so the
## activation walk captures the rows' baselines. A REbuild defers one frame:
## the cleared rows are queue_freed but still live within this frame, and a
## same-frame re-register would read as a duplicate id — after the frame's
## delete flush the same-id replacement is silent. A pass whose screen died
## meanwhile has only dead nodes to visit: the instance-bound one-shot dies
## with it (nothing left to register).
func _register_dynamic(section: String, entries: Array) -> void:
	if not _layout_built.has(section):
		_layout_built[section] = true
		for entry in entries:
			RegistryLib.register(LAYOUT_SCREEN, entry["control"],
				entry["id"], entry["opts"])
		return
	var apply := func() -> void:
		for entry in entries:
			var candidate: Variant = entry["control"]
			# The Variant guard comes first: a freed node fails
			# `is_instance_valid` safely, while a typed assignment of it
			# would be a runtime error.
			if not is_instance_valid(candidate) or not (candidate is Control):
				continue
			RegistryLib.register(LAYOUT_SCREEN, candidate, entry["id"],
				entry["opts"])
		RegistryLib.apply_layout(LAYOUT_SCREEN)
	get_tree().process_frame.connect(apply, CONNECT_ONE_SHOT)


# --- Actions ---------------------------------------------------------------

func _on_rest_pressed() -> void:
	if InnEngineLib.rest():
		_show_message("inn.rest_done", {"day": InnEngineLib.REST_DAYS})
	_bind()


func _on_odd_job_pressed() -> void:
	if InnEngineLib.work_odd_job():
		# §4.7: the condition is re-evaluated after each job, so one click can
		# be the last one (gold reaching 100) — `_bind()` below flips the
		# button to its disabled state in the same frame.
		_show_message("inn.odd_job.result", {})
	_bind()


## Shows a message in the shared HUD toast (docs/80-* §4.7: transient, max 1)
## and records its key so a headless test never races the 2.5s timer.
func _show_message(key: String, values: Dictionary) -> void:
	last_message_key = key
	message_shown.emit(key)
	if _hud != null and _hud.has_method("toast_key"):
		_hud.toast_key(key, values)


# --- Signals ---------------------------------------------------------------

func _on_locale_changed(_locale: String) -> void:
	_bind()


## Gold changes while this screen is up come from the ledger (wages, odd-job
## payout) and from rest's up-front charge: the status box and both buttons
## must follow immediately.
func _on_gold_changed(_new_gold: int) -> void:
	_bind()


func _on_day_advanced(_new_day: int) -> void:
	_bind()


## §4.1b (added 2026-11-02): actions elsewhere in port move the `HH:MM`
## label; the inn banner follows without a day tick.
func _on_clock_changed() -> void:
	_bind()


func _on_fleet_changed() -> void:
	_bind()


func _exit_tree() -> void:
	# EventBus autoloads outlive every screen; drop the connections so a freed
	# inn screen never re-binds onto a dead node on a later signal.
	for pair in [
		[EventBus.locale_changed, _on_locale_changed],
		[EventBus.gold_changed, _on_gold_changed],
		[EventBus.day_advanced, _on_day_advanced],
		[EventBus.clock_changed, _on_clock_changed],
		[EventBus.fleet_changed, _on_fleet_changed],
	]:
		var sig: Signal = pair[0]
		var callable: Callable = pair[1]
		if sig.is_connected(callable):
			sig.disconnect(callable)
