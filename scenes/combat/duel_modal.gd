class_name DuelModal
extends Control
## S11 captain-duel modal (docs/80-UI-UX.md §4.1 S11, §4.7.1 "Duel modal",
## §4.8 palette/sizing; docs/60-COMBAT.md §4.6, §4.11.6, §4.12.1.2,
## §4.12.5; docs/90-ARCHITECTURE.md §5.1).
##
## A modal over S10: 40% black dim, a 480px panel in palette colours, and
## `ColorRect`/`Label`/`Button` only (no textures, no animation — §4.7.1
## "all input while open", test-friendly without waiting on a tween).
##
## Contents:
##   * both captains (name + duel base) in the header;
##   * one row per round already played: the round number, the player's roll,
##     the defender's roll and the localised verdict (`duel.round.*`);
##   * the closing `duel.result.capture|defeat` line;
##   * `duel.committed` (boarding cannot be retreated from, §4.6);
##   * one acknowledgement button — the duel has no cancel (§4.6).
##
## **The outcome is never computed here.** [method open_duel] accepts the
## payload [method Duel.preview] already produced (`outcome`, `rolls`, the two
## bases, the names); a bare config is forwarded to `Duel.preview` so the
## editor/standalone path resolves through the same single formula
## (`BattleSim.resolve_duel`, §4.12.1.2).
##
## Signals: emits `EventBus.duel_finished(outcome)` **exactly once per duel**,
## when the modal closes (§5.1 "the S11 modal closes"). There is deliberately
## no local `duel_finished` signal — one place, one emission. The local
## [signal closed] is the presentation handshake `Duel.start` awaits.
##
## Text is re-bound on `EventBus.locale_changed` (§6 "toggle locale
## mid-dialog"). Every `duel.*` key comes from §4.12.5; where a key is not in
## `ui_strings.json` yet the row degrades to numbers/names (never a raw
## `<key>`, §6) and the optional `duel.committed` line simply hides.

const PaletteLib := preload("res://scripts/palette.gd")
const DuelLib := preload("res://scripts/combat/duel.gd")

## §4.7: modals dim the background by 40% black.
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## The only keys this scene renders (§4.12.5 inventory).
const TITLE_KEY := "duel.title"
const RESULT_KEYS := {"capture": "duel.result.capture", "defeat": "duel.result.defeat"}
const ROUND_KEYS := {"win": "duel.round.win", "loss": "duel.round.loss", "tie": "duel.round.tie"}
const COMMITTED_KEY := "duel.committed"

## Round-table column widths (px, §4.8 8px base unit).
const COL_ROUND_W := 64.0
const COL_ROLL_W := 96.0
const COL_VERDICT_W := 120.0

## Emitted when the player acknowledges the duel (any key / the button).
## `Duel.start` awaits it; `EventBus.duel_finished` is emitted in the same
## close, so consumers listen there, not here.
signal closed

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _header: Label = $Center/Panel/Margin/Body/Header
@onready var _rounds: VBoxContainer = $Center/Panel/Margin/Body/Rounds
@onready var _result: Label = $Center/Panel/Margin/Body/Result
@onready var _committed: Label = $Center/Panel/Margin/Body/Committed
@onready var _acknowledge: Button = $Center/Panel/Margin/Body/Footer/Acknowledge

## The payload last opened (`Duel.preview` shape), `{}` before [method
## open_duel]. Re-bound on a locale change, so it is kept.
var _config: Dictionary = {}
## `resolve_duel`'s dictionary — what [method result] returns.
var _outcome: Dictionary = {}
## True between [method open_duel] and [method close]; guards the
## exactly-once `duel_finished` emission.
var _open := false
## Round widgets: one `{round, player, defender, verdict, row}` per played
## round, in play order (tests read this).
var _rows: Array = []


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 32)
	_header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_committed.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_acknowledge.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_acknowledge.pressed.connect(close)
	EventBus.locale_changed.connect(_on_locale_changed)


## Modal behaviour (docs/80-* §6 "modals consume all input"): any key or a
## click acknowledges the duel — there is no retreat (§4.6). Enter/Space/Esc
## all take the only path out.
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	get_viewport().set_input_as_handled()
	var acknowledged := false
	if event is InputEventKey:
		acknowledged = (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo
	elif event is InputEventMouseButton:
		acknowledged = (event as InputEventMouseButton).pressed
	elif event is InputEventJoypadButton:
		acknowledged = (event as InputEventJoypadButton).pressed
	if acknowledged:
		close()


# --- Public API ------------------------------------------------------------

## Shows the duel. Accepts either a full [method Duel.preview] payload
## (`outcome` + `rolls` + bases + names, what `Duel.start` hands over) or the
## `Duel.start` config itself, which is resolved through `Duel.preview` here.
func open_duel(config: Dictionary) -> void:
	_config = config.duplicate(true) if config.has("outcome") \
		else DuelLib.preview(config)
	_outcome = _config.get("outcome", {})
	_open = true
	visible = true
	add_to_group(MODAL_GROUP)
	_bind()
	_acknowledge.grab_focus()


## Player acknowledgement (or the test's direct call). Idempotent, and the
## only place `EventBus.duel_finished` is emitted — once per opened duel.
func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit()
	_emit_finished()


func is_open() -> bool:
	return _open


## `resolve_duel`'s dictionary for the open/last duel (§4.12.3 return shape).
func result() -> Dictionary:
	return _outcome


## The per-round presentation widgets, in play order: `[{round, player,
## defender, verdict, row}]` where `player`/`defender`/`verdict` are the
## labels. Empty before [method open_duel].
func round_rows() -> Array:
	return _rows


## Number of rendered round rows (one per round actually played).
func round_count() -> int:
	return _rows.size()


# --- Binding ---------------------------------------------------------------

func _bind() -> void:
	# The title is the `duel.title` key (§4.12.5); the captain line below it is
	# proper nouns + numbers, so the header carries the screen even before the
	# key is merged and no raw `<key>` can ever be printed (§6).
	_title.visible = DataLoader.ui_strings.has(TITLE_KEY)
	_title.text = I18n.t_key(TITLE_KEY) if _title.visible else ""
	_header.text = _captains_heading()
	_acknowledge.text = I18n.t_key("ui.ok")
	_bind_rounds()
	_bind_result()
	# `duel.committed` is a flavour line ("boarding commits"); when the key is
	# not merged yet the row hides rather than printing a raw `<key>` (§6).
	_committed.visible = DataLoader.ui_strings.has(COMMITTED_KEY)
	_committed.text = I18n.t_key(COMMITTED_KEY) if _committed.visible else ""


## `<attacker> <base> – <defender> <base>`, falling back to the bare bases when
## a name is missing. Proper nouns and numbers only, so the heading is always
## non-empty and never needs a `ui_strings` key of its own.
func _captains_heading() -> String:
	var left := _captain(_config.get("attacker_name", ""), _config.get("player_base", 0))
	var right := _captain(_config.get("defender_name", ""), _config.get("defender_base", 0))
	return "%s – %s" % [left, right]


func _captain(name_value, base_value) -> String:
	var name := str(name_value).strip_edges()
	var base := int(base_value)
	if name.is_empty():
		return str(base)
	return "%s %d" % [name, base]


func _bind_rounds() -> void:
	for child in _rounds.get_children():
		_rounds.remove_child(child)
		child.queue_free()
	_rows.clear()

	var labels: Array = _outcome.get("rounds", [])
	var rolls: Array = _config.get("rolls", [])
	var attacker := str(_config.get("attacker_name", "")).strip_edges()
	var defender_name := str(_config.get("defender_name", "")).strip_edges()
	# One row per round actually played (best-of-5 stops at the third win).
	# Every cell carries text, so a row is readable on its own: the header
	# above names the two captains and each roll is prefixed with whose it is.
	for index in labels.size():
		var verdict := str(labels[index])
		var roll: Dictionary = rolls[index] if index < rolls.size() \
			and rolls[index] is Dictionary else {}
		var row := HBoxContainer.new()
		row.name = "Round_%d" % (index + 1)
		row.add_theme_constant_override("separation", 8)
		var number := _cell(str(index + 1), PaletteLib.PANEL_LINE, COL_ROUND_W)
		var player := _cell(
			_named_roll(attacker, roll.get("player", "-")), PaletteLib.TEXT, COL_ROLL_W)
		var defender := _cell(
			_named_roll(defender_name, roll.get("defender", "-")), PaletteLib.TEXT, COL_ROLL_W)
		var verdict_label := _cell(
			_verdict_text(verdict), _verdict_color(verdict), COL_VERDICT_W)
		for label in [number, player, defender, verdict_label]:
			row.add_child(label)
		_rounds.add_child(row)
		_rows.append({
			"round": number, "player": player, "defender": defender,
			"verdict": verdict_label, "row": row,
		})


## `"<name> <roll>"`, or the bare roll when no captain name was supplied.
static func _named_roll(name: String, roll) -> String:
	return str(roll) if name.is_empty() else "%s %s" % [name, str(roll)]


func _bind_result() -> void:
	var result := str(_outcome.get("result", ""))
	var key := str(RESULT_KEYS.get(result, ""))
	_result.add_theme_color_override(
		"font_color", PaletteLib.GOOD if result == "capture" else PaletteLib.BAD)
	# Fallback when `duel.result.*` is not merged yet: the scoreline ("3-1"),
	# a localised-neutral pair of numbers that still says who won.
	var score := "%d-%d" % [
		int(_outcome.get("player_wins", 0)), int(_outcome.get("defender_wins", 0)),
	]
	_result.text = _or(key, score)


## A round verdict, localised through `duel.round.win|loss|tie`; the numeric
## fallback (+1 / -1 / 0) keeps the row readable before the keys merge.
func _verdict_text(verdict: String) -> String:
	return _or(str(ROUND_KEYS.get(verdict, "")), _verdict_fallback(verdict))


static func _verdict_fallback(verdict: String) -> String:
	match verdict:
		"win":
			return "+1"
		"loss":
			return "-1"
		_:
			return "0"


func _verdict_color(verdict: String) -> Color:
	match verdict:
		"win":
			return PaletteLib.GOOD
		"loss":
			return PaletteLib.BAD
		_:
			return PaletteLib.WARN


# --- Emission --------------------------------------------------------------

## §5.1: one `EventBus.duel_finished(outcome)` per duel, on close, carrying the
## documented payload shape `{result, rounds, attacker, defender}`. The signal
## is pinned in `90-*` §5.1; the guard keeps this scene working on a tree
## where the autoload has not been extended yet (another task owns that file —
## C never edits `autoload/`). `emit_signal(name)` rather than
## `EventBus.duel_finished.emit(...)` so the call resolves at runtime: the
## signal does not exist on the autoload at parse time, and a property access
## would raise before the guard could help.
func _emit_finished() -> void:
	if not EventBus.has_signal("duel_finished"):
		return
	EventBus.emit_signal("duel_finished", {
		"result": str(_outcome.get("result", "")),
		"rounds": (_outcome.get("rounds", []) as Array).duplicate(),
		"attacker": str(_config.get("attacker_name", "")),
		"defender": str(_config.get("defender_name", "")),
	})


# --- Helpers ---------------------------------------------------------------

func _on_locale_changed(_locale: String) -> void:
	if _open:
		_bind()


## `key`'s localised text when `ui_strings.json` carries it, else `fallback`
## (names/numbers only, so no untranslated prose is ever invented) — the
## `fleet_panel._fmt_or` convention that keeps a pending key from printing a
## raw `<key>` (§6).
func _or(key: String, fallback: String) -> String:
	if key.is_empty() or not DataLoader.ui_strings.has(key):
		return fallback
	return I18n.t_key(key)


func _cell(text: String, color: Color, width: float) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.custom_minimum_size.x = width
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# A long captain name must never widen the 480px panel (§4.8): each cell
	# stays at its column width and trims instead of growing the modal.
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
