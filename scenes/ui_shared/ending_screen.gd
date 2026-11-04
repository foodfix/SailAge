extends Control
## Ending screen (S16) — retirement summary
## (docs/70-* §4.7; docs/80-* §4.1, §4.2, §4.7.3, §4.7.4, §4.14).
##
## Two modes, one scene:
##   * **Just retired** — opened by S13's Retire row, it summarises the live
##     `GameState` and its Continue button returns to S1.
##   * **Retired save** — `SaveSystem` routes here on a load of a `retired`
##     payload; the summary comes from `last_retired_summary` and no route back
##     into play exists (`ending.retired_title`).
##
## Phase 8 appends the read-only RPG segment (`80-*` §4.14) below the six
## summary lines, in its own `RpgRows` container — the six summary rows'
## container, names and order are untouched. Selection rules in `_bind_rpg`.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

const TITLE_SCENE := "res://scenes/title/title_screen.tscn"

## Phase-8 RPG segment (docs/70-* §4.7, docs/80-* §4.14): the read-only rows
## below the six summary lines.
const RPG_NEMESIS_SLOTS := 3
## A veteran needs ≥ 90 sea-days served (docs/70-* §4.7).
const RPG_VETERAN_SEA_DAYS := 90

@onready var _background: ColorRect = $Background
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _subtitle: Label = $Center/Panel/Margin/Body/Subtitle
@onready var _rows: VBoxContainer = $Center/Panel/Margin/Body/Rows
@onready var _rpg_rows: VBoxContainer = $Center/Panel/Margin/Body/RpgRows
@onready var _continue: Button = $Center/Panel/Margin/Body/Footer/Continue

## `true` when showing a retired save rather than a fresh retirement.
var summary_mode: bool = false
## The summary block being shown (tests read it).
var summary: Dictionary = {}


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	# §4.9 sweep (W4-B): the panel chrome is the theme's PanelContainer
	# stylebox (the scene's local stylebox resource is gone); the subtitle is
	# secondary text → the `Dim` variation. The title's 32px is the
	# scene's own pin (`ending_screen.tscn`).
	_subtitle.theme_type_variation = "Dim"
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
	for child in _rpg_rows.get_children():
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
	_bind_rpg()


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
	# Ink is the theme's TEXT (§4.9 sweep).
	_rows.add_child(label)


# --- Phase-8 RPG segment (docs/70-* §4.7; docs/80-* §4.14) -------------------
#
# Four read-only rows below the six summary lines, drawn entirely from
# existing run state — no new simulation, no new counters. Selection rules
# as implemented (doc-literal):
#   * **Nemesis list** — met captains (a `captain_states` entry exists)
#     whose win count is positive, the top 3 by wins with the captain id as
#     the deterministic tie-break; each row names the captain with its
#     drifted tier and stance (`ending.rpg.nemesis_row`);
#   * **Deepest grudge** — the met captain with the lowest **negative**
#     stance, ties by id (a merely-met captain at stance 0 holds no
#     grudge — the row's eligibility condition);
#   * **Most loyal veteran** — the employed officer with `sea_days ≥ 90`
#     and the highest loyalty (ties by id), shown with the days served;
#   * **Background recall** — the player background's bio line from
#     `data/backgrounds.json`.
# A row with no eligible entry renders the `ui.empty` convention
# (docs/80-* §4.14) — e.g. the whole block on a retired-save load, whose
# load restores no run state (docs/70-* §4.7).

func _bind_rpg() -> void:
	_clear_rpg()
	# 宿敌榜 nemesis list: the section header is constant, then the ranked
	# rows (or the ui.empty convention).
	_add_rpg_row("Row_rpg_nemesis_title", I18n.t_key("ending.rpg.nemesis_title"))
	var nemeses := _nemesis_ids()
	if nemeses.is_empty():
		_add_rpg_row("Row_rpg_nemesis_empty", I18n.t_key("ui.empty"), true)
	else:
		for index in nemeses.size():
			var captain_id := str(nemeses[index])
			var state: Dictionary = GameState.captain_states.get(captain_id, {})
			var card: Dictionary = DataLoader.get_captain(captain_id)
			_add_rpg_row("Row_rpg_nemesis_%d" % index, I18n.fmt(
				"ending.rpg.nemesis_row", {
					"name": I18n.t(card.get("name", {})),
					"tier": int(state.get("tier_now", card.get("tier", 1))),
					"stance": int(state.get("stance", 0)),
				}))
	# 最深恩仇 deepest grudge.
	var grudge := _grudge_id()
	if grudge.is_empty():
		_add_rpg_row("Row_rpg_grudge", I18n.t_key("ui.empty"), true)
	else:
		_add_rpg_row("Row_rpg_grudge", I18n.fmt("ending.rpg.grudge",
			{"name": _captain_name(grudge)}))
	# 最忠诚老部下 most loyal veteran.
	var veteran := _veteran_id()
	if veteran.is_empty():
		_add_rpg_row("Row_rpg_veteran", I18n.t_key("ui.empty"), true)
	else:
		var state: Dictionary = GameState.officer_states.get(veteran, {})
		_add_rpg_row("Row_rpg_veteran", I18n.fmt("ending.rpg.veteran", {
			"name": I18n.t(DataLoader.get_officer(veteran).get("name", {})),
			"days": int(state.get("sea_days", 0)),
		}))
	# 出身回望 background bio.
	var bio := _background_bio()
	if bio.is_empty():
		_add_rpg_row("Row_rpg_bio", I18n.t_key("ui.empty"), true)
	else:
		_add_rpg_row("Row_rpg_bio",
			"%s\n%s" % [I18n.t_key("ending.rpg.bio"), bio])


## The nemesis ranking: met captains with `wins > 0`, wins descending and
## the captain id ascending as the tie-break, capped at the top 3.
func _nemesis_ids() -> Array:
	var ranked: Array = []
	for id in GameState.captain_states:
		var entry: Variant = GameState.captain_states[id]
		if not (entry is Dictionary):
			continue
		var wins := int((entry as Dictionary).get("wins", 0))
		if wins <= 0:
			continue
		ranked.append({"id": str(id), "wins": wins})
	ranked.sort_custom(func(a, b) -> bool:
		if int(a["wins"]) != int(b["wins"]):
			return int(a["wins"]) > int(b["wins"])
		return str(a["id"]) < str(b["id"]))
	var out: Array = []
	for entry in ranked.slice(0, RPG_NEMESIS_SLOTS):
		out.append(str(entry["id"]))
	return out


## The deepest grudge: the met captain with a **negative** stance, the
## lowest first (ties by captain id); "" when nobody holds a grudge. The
## negativity gate is the row's eligibility condition (docs/80-* §4.14's
## "empty states" convention — a merely-met captain at stance 0 is no
## grudge, and every spawned fleet's captain gets a met entry).
func _grudge_id() -> String:
	var best := ""
	var best_stance := 0
	for id in GameState.captain_states:
		var entry: Variant = GameState.captain_states[id]
		if not (entry is Dictionary):
			continue
		var stance := int((entry as Dictionary).get("stance", 0))
		if stance >= 0:
			continue
		if best.is_empty() or stance < best_stance \
				or (stance == best_stance and str(id) < best):
			best = str(id)
			best_stance = stance
	return best


## The employed officer with `sea_days ≥ 90` and the highest loyalty (ties
## by officer id); "" when nobody qualifies yet.
func _veteran_id() -> String:
	var best := ""
	var best_loyalty := -1
	for officer_id in GameState.player.get("officers", []):
		var id := str(officer_id)
		var state: Dictionary = GameState.officer_states.get(id, {})
		if int(state.get("sea_days", 0)) < RPG_VETERAN_SEA_DAYS:
			continue
		var loyalty := int(state.get("loyalty", 0))
		if loyalty > best_loyalty or (loyalty == best_loyalty
				and not best.is_empty() and id < best):
			best = id
			best_loyalty = loyalty
	return best


## The player background's bio line ("" for an unknown/absent background_id).
func _background_bio() -> String:
	var background: Dictionary = DataLoader.get_background(
		str(GameState.player.get("background_id", "")))
	if background.is_empty():
		return ""
	return I18n.t(background.get("bio", {}))


func _captain_name(id: String) -> String:
	if id.is_empty():
		return ""
	return I18n.t(DataLoader.get_captain(id).get("name", {}))


func _add_rpg_row(row_name: String, text: String, dim := false) -> void:
	var label := Label.new()
	label.name = row_name
	label.text = text
	# §4.9 sweep: dim rows are the theme's `Dim` variation; otherwise the
	# theme's TEXT ink.
	if dim:
		label.theme_type_variation = "Dim"
	_rpg_rows.add_child(label)


func _clear_rpg() -> void:
	for child in _rpg_rows.get_children():
		_rpg_rows.remove_child(child)
		child.queue_free()


func _clear() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()




func _on_locale_changed(_locale: String) -> void:
	_bind()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
