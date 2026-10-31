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

const PaletteLib := preload("res://scripts/palette.gd")
const InnEngineLib := preload("res://scripts/port/inn_engine.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
## Task L (docs/80-* §4.7.8): the "captains resting" rows.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"

## Emitted when the odd-job button's state machine re-evaluates (`eligible` is
## the new value). Tests observe it instead of reaching into the widgets.
signal odd_job_state_changed(eligible: bool)
## Emitted after a successful rest / odd job with the ui key of its message.
signal message_shown(key: String)
## Emitted right before the S8 → S4 route.
signal left_inn

@onready var _background: ColorRect = $Background
@onready var _hud: Control = $HUD
@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _status_panel: PanelContainer = $Layout/VBox/Status
@onready var _morale_label: Label = $Layout/VBox/Status/Margin/StatusVBox/Morale
@onready var _gold_label: Label = $Layout/VBox/Status/Margin/StatusVBox/Gold
@onready var _day_label: Label = $Layout/VBox/Status/Margin/StatusVBox/Day
@onready var _rest_button: Button = $Layout/VBox/Actions/RestButton
@onready var _rest_hint: Label = $Layout/VBox/Actions/RestHint
@onready var _odd_job_button: Button = $Layout/VBox/Actions/OddJobButton
@onready var _odd_job_hint: Label = $Layout/VBox/Actions/OddJobHint
@onready var _back_button: Button = $Layout/VBox/Footer/Back

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

## Task L (§4.7.8): the "captains resting" list (code-built under the odd-job
## rows) — header + row labels and the `{id, name, role}` seam rows.
var _captains_header: Label = null
var _captains_box: VBoxContainer = null
var _captain_rows: Array = []


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_title, _morale_label, _gold_label, _day_label]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_rest_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_odd_job_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_status_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_font_size_override("font_size", 32)
	for button in [_rest_button, _odd_job_button, _back_button]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_rest_button.pressed.connect(_on_rest_pressed)
	_odd_job_button.pressed.connect(_on_odd_job_pressed)
	_back_button.pressed.connect(leave)

	# S8 keeps the S4 bars (docs/80-* §4.5: the port screens share the HUD);
	# the sea viewport (minimap + weather glyph) stays hidden as on S4.
	_hud.set_minimap_visible(false)

	_build_captains_section()

	_bind()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.fleet_changed.connect(_on_fleet_changed)


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
	_morale_label.add_theme_color_override(
		"font_color", HudLib.morale_color(GameState.morale)
	)
	_gold_label.text = I18n.fmt(
		"ui.gold_amount", {"gold": HudLib.format_thousands(GameState.gold)}
	)
	_day_label.text = I18n.fmt("world.day", {"day": GameState.day})

	_bind_rest()
	_bind_odd_job()
	_bind_captains()

	_back_button.text = I18n.t_key("ui.back")


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


## Builds the section shell once (header + rows box) under the odd-job rows.
func _build_captains_section() -> void:
	var actions: Control = $Layout/VBox/Actions
	var footer: Control = $Layout/VBox/Footer
	var layout: Node = actions.get_parent()
	var footer_index := footer.get_index()
	_captains_header = Label.new()
	_captains_header.name = "CaptainsHeader"
	_captains_header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	layout.add_child(_captains_header)
	_captains_box = VBoxContainer.new()
	_captains_box.name = "CaptainsRows"
	_captains_box.add_theme_constant_override("separation", 2)
	layout.add_child(_captains_box)
	layout.move_child(_captains_header, footer_index)
	layout.move_child(_captains_box, footer_index + 1)


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
			"name": str(entry.get("name", "")),
			"role": str(entry.get("role", "")),
			"nation_id": str(entry.get("nation_id", "")),
		})
	if _captain_rows.is_empty():
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = "-"
		empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		_captains_box.add_child(empty)
		return
	for entry in _captain_rows:
		var row := Label.new()
		row.name = "Captain_%s" % str(entry["id"])
		row.text = "%s · %s" % [str(entry["name"]),
			I18n.t_key("captain.role.%s" % str(entry["role"]))]
		row.add_theme_color_override("font_color", PaletteLib.TEXT)
		_captains_box.add_child(row)


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


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


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


func _on_fleet_changed() -> void:
	_bind()


func _exit_tree() -> void:
	# EventBus autoloads outlive every screen; drop the connections so a freed
	# inn screen never re-binds onto a dead node on a later signal.
	for pair in [
		[EventBus.locale_changed, _on_locale_changed],
		[EventBus.gold_changed, _on_gold_changed],
		[EventBus.day_advanced, _on_day_advanced],
		[EventBus.fleet_changed, _on_fleet_changed],
	]:
		var sig: Signal = pair[0]
		var callable: Callable = pair[1]
		if sig.is_connected(callable):
			sig.disconnect(callable)
