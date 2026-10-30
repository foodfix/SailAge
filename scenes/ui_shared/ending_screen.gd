extends Control
## Ending screen (S16) — retirement summary
## (docs/70-* §4.7; docs/80-* §4.1, §4.2, §4.7.3, §4.7.4).
##
## Two modes, one scene:
##   * **Just retired** — opened by S13's Retire row, it summarises the live
##     `GameState` and its Continue button returns to S1.
##   * **Retired save** — `SaveSystem` routes here on a load of a `retired`
##     payload; the summary comes from `last_retired_summary` and no route back
##     into play exists (`ending.retired_title`).
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

const TITLE_SCENE := "res://scenes/title/title_screen.tscn"

@onready var _background: ColorRect = $Background
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _subtitle: Label = $Center/Panel/Margin/Body/Subtitle
@onready var _rows: VBoxContainer = $Center/Panel/Margin/Body/Rows
@onready var _continue: Button = $Center/Panel/Margin/Body/Footer/Continue

## `true` when showing a retired save rather than a fresh retirement.
var summary_mode: bool = false
## The summary block being shown (tests read it).
var summary: Dictionary = {}


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	_panel.add_theme_stylebox_override("panel", _panel_style())
	for label in [_title, _subtitle]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 32)
	_subtitle.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_continue.custom_minimum_size.y = PaletteLib.BUTTON_H
	_continue.pressed.connect(continue_to_title)
	EventBus.locale_changed.connect(_on_locale_changed)

	# A load of a retired slot routes here with the summary already extracted
	# (`SaveSystem.last_retired_summary`); a fresh retirement uses live state.
	if SaveSystem.last_loaded_retired and not SaveSystem.last_retired_summary.is_empty():
		open_summary(SaveSystem.last_retired_summary)
	else:
		open_live()


## Fresh retirement: reads the live run.
func open_live() -> void:
	summary_mode = false
	summary = {
		"day": int(GameState.day),
		"gold": int(GameState.gold),
		"fame": int(GameState.fame),
		"titles": FameLib.earned_titles(),
		"discoveries": GameState.discoveries_reported.size(),
		"battles": int(GameState.battles_won),
	}
	_bind()


## Retired-save mode: the payload's summary, never live state.
func open_summary(block: Dictionary) -> void:
	summary_mode = true
	summary = block.duplicate(true)
	_bind()


## Every player-facing line (the no-raw-key check walks it).
func lines() -> Array:
	var out: Array = [_title.text, _subtitle.text, _continue.text]
	for child in _rows.get_children():
		if child is Label:
			out.append((child as Label).text)
	return out


func continue_to_title() -> bool:
	if not is_inside_tree():
		return false
	GameState.change_scene(TITLE_SCENE)
	return true


# --- Rendering ------------------------------------------------------------

func _bind() -> void:
	_title.text = I18n.t_key("ending.retired_title" if summary_mode
		else "ending.title")
	_subtitle.text = I18n.t_key("ending.retired_title" if summary_mode
		else "title.subtitle")
	_continue.text = I18n.t_key("ending.continue")
	_clear()
	_add_row("ending.days", {"days": int(summary.get("day", 0))})
	_add_row("ending.gold", {
		"gold": HudLib.format_thousands(int(summary.get("gold", 0))),
	})
	_add_row("ending.fame", {"fame": int(summary.get("fame", 0))})
	_add_row("ending.titles", {"titles": _titles_text(summary.get("titles", []))})
	_add_row("ending.discoveries", {
		"count": int(summary.get("discoveries", 0)),
	})
	_add_row("ending.battles", {"count": int(summary.get("battles", 0))})


## `Portuguese Baron · English Knight`, or `—` for a run with no title.
func _titles_text(entries) -> String:
	if not (entries is Array) or (entries as Array).is_empty():
		return I18n.t_key("char.none")
	var parts: Array = []
	for entry in entries:
		if not (entry is Array) or (entry as Array).size() != 2:
			continue
		var nation_id := str((entry as Array)[0])
		var rank := str((entry as Array)[1])
		parts.append("%s %s" % [
			I18n.t(DataLoader.get_nation(nation_id).get("name", {})),
			I18n.t_key("rank.%s" % rank),
		])
	return " · ".join(parts)


func _add_row(key: String, values: Dictionary) -> void:
	var label := Label.new()
	label.name = "Row_%s" % key.replace(".", "_")
	label.text = I18n.fmt(key, values)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_rows.add_child(label)


func _clear() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


func _on_locale_changed(_locale: String) -> void:
	_bind()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
