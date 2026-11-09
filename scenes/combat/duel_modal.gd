class_name DuelModal
extends Control
## S11 captain-duel modal (docs/80-UI-UX.md §4.1 S11, §4.7.1 "Duel modal",
## §4.9 theme & kit; docs/60-COMBAT.md §4.6, §4.11.6, §4.12.1.2,
## §4.12.5; docs/90-ARCHITECTURE.md §5.1).
##
## A modal over S10: 40% black dim, a 480px panel on the shared theme's
## panel chrome (§4.9 — the per-screen stylebox retired with the W5-B
## sweep), and `ColorRect`/`Label`/`Button` only (no textures, no
## animation — §4.7.1 "all input while open", test-friendly without waiting
## on a tween). Semantic text colors ride the theme's Label variations
## (`Accent`/`Dim`/`Good`/`Bad`/`Warn`) — no per-screen styling here.
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
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## This modal's layout screen id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "duel"

## §4.7: modals dim the background by 40% black.
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## The only keys this scene renders (§4.12.5 inventory).
const TITLE_KEY := "duel.title"
const RESULT_KEYS := {"capture": "duel.result.capture", "defeat": "duel.result.defeat"}
const ROUND_KEYS := {"win": "duel.round.win", "loss": "duel.round.loss", "tie": "duel.round.tie"}
const COMMITTED_KEY := "duel.committed"

## Round-table cell rects (px, inside the 13-tile round row — the row's
## internals flatten: 2+3+3+4 tiles = 12 of the 13-tile row width).
const CELL_NUMBER_RECT := Rect2(0, 0, 64, 32)
const CELL_PLAYER_RECT := Rect2(64, 0, 96, 32)
const CELL_DEFENDER_RECT := Rect2(160, 0, 96, 32)
const CELL_VERDICT_RECT := Rect2(256, 0, 128, 32)

## The round rows' list block (docs/10-* §4.23 — tiles, content-node space);
## the shipped data row mirrors these constants exactly.
const LIST_ROUNDS := "rounds"
const ROUNDS_BASE_TILES := Rect2i(0, 0, 13, 1)
const ROUNDS_ROW_H_TILES := 1

## Emitted when the player acknowledges the duel (any key / the button).
## `Duel.start` awaits it; `EventBus.duel_finished` is emitted in the same
## close, so consumers listen there, not here.
signal closed

@onready var _dim: ColorRect = $Dim
@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _header: Label = $Panel/Header
@onready var _rounds_viewport: ScrollContainer = $Panel/RoundsViewport
@onready var _rounds: Control = $Panel/RoundsViewport/Rounds
@onready var _result: Label = $Panel/Result
@onready var _committed: Label = $Panel/Committed
@onready var _acknowledge: Button = $Panel/Acknowledge

## The payload last opened (`Duel.preview` shape), `{}` before [method
## open_duel]. Re-bound on a locale change, so it is kept.
var _config: Dictionary = {}
## `resolve_duel`'s dictionary — what [method result] returns.
var _outcome: Dictionary = {}
## True between [method open_duel] and [method close]; guards the
## exactly-once `duel_finished` emission.
var _open := false
## The id pass runs once per instance (records persist across closes).
var _ids_registered := false
## Round widgets: one `{round, player, defender, verdict, row}` per played
## round, in play order (tests read this).
var _rows: Array = []


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 sweep (W5-B): the panel chrome is the theme's panel row;
	# the semantic text colors ride theme Label variations — the title and
	# the roll cells read the default TEXT.
	_header.theme_type_variation = "Accent"
	_committed.theme_type_variation = "Dim"
	_acknowledge.pressed.connect(close)
	EventBus.locale_changed.connect(_on_locale_changed)


## The id pass — every persistent control under its stable hierarchical id.
## Modals register AT OPEN (see confirm_dialog.gd); the round rows register
## where they build (a `rounds` list block + its cell parts).
func _register_ids() -> void:
	RegistryLib.register(SCREEN_ID, _dim, "dim")
	RegistryLib.register(SCREEN_ID, _panel, "panel", {"role": "panel"})
	RegistryLib.register(SCREEN_ID, _title, "panel.title")
	RegistryLib.register(SCREEN_ID, _header, "panel.header")
	RegistryLib.register(SCREEN_ID, _rounds_viewport, "panel.rounds_viewport")
	RegistryLib.register(SCREEN_ID, _result, "panel.result")
	RegistryLib.register(SCREEN_ID, _committed, "panel.committed")
	RegistryLib.register(SCREEN_ID, _acknowledge, "panel.acknowledge",
		{"role": "button"})


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
	# Phase 12: register at the first OPEN, activate at every open, then
	# bind (the apply-then-bind order the locale path shares).
	if not _ids_registered:
		_register_ids()
		_ids_registered = true
	RegistryLib.screen_active(SCREEN_ID, self)
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
	# Phase 12 (docs/80-* §4.8.9): computed stacking — row *i* at
	# `base + i·row_h` inside the viewport's content node, its four cells
	# absolutely placed inside the row rect (the `rounds` list block).
	for index in labels.size():
		var verdict := str(labels[index])
		var roll: Dictionary = rolls[index] if index < rolls.size() \
			and rolls[index] is Dictionary else {}
		var row := Control.new()
		row.name = "Round_%d" % (index + 1)
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		var round_rect := _round_rect(index)
		row.position = round_rect.position
		row.size = round_rect.size
		var number := _cell(str(index + 1), "Dim", CELL_NUMBER_RECT)
		var player := _cell(
			_named_roll(attacker, roll.get("player", "-")), "",
			CELL_PLAYER_RECT)
		var defender := _cell(
			_named_roll(defender_name, roll.get("defender", "-")), "",
			CELL_DEFENDER_RECT)
		var verdict_label := _cell(
			_verdict_text(verdict), _verdict_variation(verdict),
			CELL_VERDICT_RECT)
		for cell in [number, player, defender, verdict_label]:
			row.add_child(cell)
		_rounds.add_child(row)
		RegistryLib.register(SCREEN_ID, row, "rounds.%d" % index,
			{"list": LIST_ROUNDS, "data_ordered": true})
		RegistryLib.register(SCREEN_ID, number, "rounds.%d.number" % index)
		RegistryLib.register(SCREEN_ID, player, "rounds.%d.player" % index)
		RegistryLib.register(SCREEN_ID, defender, "rounds.%d.defender" % index)
		RegistryLib.register(SCREEN_ID, verdict_label,
			"rounds.%d.verdict" % index)
		_rows.append({
			"round": number, "player": player, "defender": defender,
			"verdict": verdict_label, "row": row,
		})
	# The content node's stacked extent (the plain-Control scroll content).
	_rounds.custom_minimum_size = Vector2(
		_rounds_viewport.size.x,
		float(labels.size() * ROUNDS_ROW_H_TILES * PaletteLib.CHROME_TILE))


## `"<name> <roll>"`, or the bare roll when no captain name was supplied.
static func _named_roll(name: String, roll) -> String:
	return str(roll) if name.is_empty() else "%s %s" % [name, str(roll)]


func _bind_result() -> void:
	var result := str(_outcome.get("result", ""))
	var key := str(RESULT_KEYS.get(result, ""))
	# Semantic line color: the theme's `Good`/`Bad` Label variations (§4.9).
	_result.theme_type_variation = "Good" if result == "capture" else "Bad"
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


## The round verdict's theme Label variation (§4.9 sweep): win → `Good`,
## loss → `Bad`, everything else → `Warn` (the neutral tie reads ACCENT).
func _verdict_variation(verdict: String) -> String:
	match verdict:
		"win":
			return "Good"
		"loss":
			return "Bad"
		_:
			return "Warn"


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
		# The rebuild path: the round rows rebuild (re-register), then the
		# committed layout re-applies.
		_bind()
		RegistryLib.apply_layout(SCREEN_ID)


## `key`'s localised text when `ui_strings.json` carries it, else `fallback`
## (names/numbers only, so no untranslated prose is ever invented) — the
## `fleet_view._fmt_or` convention that keeps a pending key from printing a
## raw `<key>` (§6).
func _or(key: String, fallback: String) -> String:
	if key.is_empty() or not DataLoader.ui_strings.has(key):
		return fallback
	return I18n.t_key(key)


## One round row's rect: the list block's `list_rect` when the screen's v2
## table is live, else the same authored constants (the interim pre-merge
## state — the shipped data row mirrors them exactly).
func _round_rect(index: int) -> Rect2:
	var rect := RegistryLib.list_rect(SCREEN_ID, LIST_ROUNDS, index)
	if rect != Rect2():
		return rect
	var tile := float(PaletteLib.CHROME_TILE)
	return Rect2(
		float(ROUNDS_BASE_TILES.position.x) * tile,
		float(index * ROUNDS_ROW_H_TILES) * tile,
		float(ROUNDS_BASE_TILES.size.x) * tile,
		float(ROUNDS_BASE_TILES.size.y) * tile)


## One fixed-width round cell at its absolute slot inside the row rect
## (the row's internals flatten — no per-row flow box). `variation` is a
## theme Label variation name (§4.9 — "" = the default TEXT label). A long
## captain name must never widen the 480px plate (§4.8): each cell stays at
## its column width and trims instead of growing the modal.
func _cell(text: String, variation: String, cell_rect: Rect2) -> Label:
	var label := Label.new()
	label.text = text
	if not variation.is_empty():
		label.theme_type_variation = variation
	label.position = cell_rect.position
	label.size = cell_rect.size
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label
