class_name CharacterCard
extends PanelContainer
## The unified character card (docs/80-UI-UX.md §4.12.1, locked layout) — ONE
## scene renders any Person: player / officer / NPC captain, with an identical
## structure from every entry (the §4.12 acceptance pin).
##
## Entries call [method setup_person] with a kind and a data dictionary built
## by [method card_data] — the pure builder every entry shares, so the same
## captain renders byte-identical data from the picker inspect, the tavern
## recruit dialog and the dossier (each exposes its card's
## [method rendered_data] for the acceptance pin).
##
## IDENTIFY = FULL REVEAL (locked): every card number renders ungated; only
## the dossier's career log is familiarity-gated (§4.11.3). The player card
## adds the effective-values split and — when `data.alloc` is set — the §4.12.2
## allocation steppers (enabled iff `Character.alloc_pending() > 0`, local
## draft, confirm commits through `Character.allocate`, cancel rolls back, a
## single attribute clamps at 100, no second confirm, skills never allocate).
##
## Placeholder art only (§4.8): the portrait is a palette color block derived
## from the appearance tags (deterministic hash → palette constant) + the
## name's initial; every bar is a palette-styled ProgressBar.
##
## `FALLBACK_STRINGS` is the W5-C pattern: keys the card needs that the shared
## `data/ui_strings.json` does not carry yet (W6-D owns the residual merge —
## reported). Resolved by [method _t]: canonical key first, fallback second.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")

const SCENE_PATH := "res://scenes/ui/character_card.tscn"

## Person kinds (the [method setup_person] contract).
const KIND_PLAYER := "player"
const KIND_OFFICER := "officer"
const KIND_NPC := "npc"

## The §4.15 attribute-name family has no `ui_strings` keys yet (the Phase-1
## panel only named the four legacy stats). W6-D merges `char.attr.*`;
## zh names are the `50-*` §4.2 table, verbatim.
const FALLBACK_STRINGS := {
	"char.attr.constitution": {"zh": "体魄", "en": "Constitution"},
	"char.attr.intellect": {"zh": "悟性", "en": "Intellect"},
	"char.attr.charisma": {"zh": "魅力", "en": "Charisma"},
	"char.attr.courage": {"zh": "胆识", "en": "Courage"},
	"char.attr.luck": {"zh": "运气", "en": "Luck"},
	"char.card.loyalty": {"zh": "忠诚 {amount}", "en": "Loyalty {amount}"},
	"char.card.wins": {"zh": "胜 {amount}", "en": "Wins {amount}"},
	"char.card.defeats": {"zh": "负 {amount}", "en": "Defeats {amount}"},
	"char.card.return_day": {"zh": "归队日:第 {day} 天", "en": "Returns on day {day}"},
}

## Attribute / skill bar geometry (the §4.8 8px grid).
const BAR_W := 160.0
const BAR_COMPACT_W := 96.0
const BAR_H := 12.0
## Portrait block (§4.8: placeholder color block + default font).
const PORTRAIT_SIZE := 64.0
## The deterministic portrait palette (§4.8 constants only — no new colors).
const PORTRAIT_COLORS: Array[Color] = [
	PaletteLib.SEA, PaletteLib.COAST_SEA, PaletteLib.LAND, PaletteLib.ACCENT,
	PaletteLib.GOOD, PaletteLib.WARN, PaletteLib.BAD, PaletteLib.PORT_NEUTRAL,
]
## familiarity tier (0–3) → the `dossier.tier.*` name key's number.
const TIER_NAME_NUMBERS: Array[int] = [3, 6, 10]

## The last data dictionary this card rendered ([method card_data] shape —
## the acceptance pin reads this from every entry).
var _data: Dictionary = {}
## The §4.12.2 allocation draft (`{attribute_key: +n}`), local to the card.
var _draft: Dictionary = {}

@onready var _body: VBoxContainer = $Margin/Scroll/Body


# --- The data contract (pure builder every entry shares) --------------------

## Builds the card's data dictionary for `kind` from live state:
##   * `player` — `person_id` is ignored; the GameState.player block feeds it
##     (name = the `char.title` line, level/XP derived, the effective split
##     computed per §4.5.3, `alloc_pending` from the block);
##   * `officer` — the `data/officers.json` v2 record (11 skills, personality,
##     appearance, `main_skill` = the native role) plus the §4.8
##     `officer_states` relations (loyalty, post);
##   * `npc` — the `data/captains.json` canon card (8 skills, role, tier,
##     level) plus the §4.15 `captain_states` run state (stance, familiarity,
##     wins/defeats, status, return day, drifted tier).
##
## Pure read: no state is mutated, nothing is created (an unmet NPC reads the
## defaults, the `Captains.state` convention). `options` carries the render
## flags (`compact` — the S18 row shape; `alloc` — the player card's
## allocation steppers, set by the S14 attributes tab).
static func card_data(kind: String, person_id: String,
		options: Dictionary = {}) -> Dictionary:
	var data: Dictionary = {
		"kind": kind,
		"person_id": person_id,
		"compact": bool(options.get("compact", false)),
		"alloc": bool(options.get("alloc", false)),
		"name": "",
		"nation_id": "",
		"role_id": "",
		"role_key": "char.none",
		"tier": 0,
		"level": 0,
		"main_skill": "",
		"loyalty": -1,
		"post_id": "",
		"stance": 0,
		"familiarity": 0,
		"wins": 0,
		"defeats": 0,
		"status": "",
		"return_day": 0,
		"xp": -1,
		"next_xp": -1,
		"alloc_pending": 0,
		"attributes": {},
		"skills": {},
		"skill_keys": [] as Array[String],
		"grayed_skill_keys": [] as Array[String],
		"personality": [],
		"appearance": {},
		"effective": [] as Array,
	}
	match kind:
		KIND_PLAYER:
			_fill_player(data)
		KIND_OFFICER:
			_fill_officer(data, person_id)
		KIND_NPC:
			_fill_npc(data, person_id)
		_:
			push_error("CharacterCard.card_data: unknown kind '%s'" % kind)
			return {}
	data["portrait_color"] = portrait_color(data)
	return data


## The player view (the §4.8 block through the Character/Skills read seams —
## never a second copy of a formula).
static func _fill_player(data: Dictionary) -> void:
	data["name"] = I18n.t_key("char.title")
	data["nation_id"] = str(GameState.player.get("nation_id", ""))
	data["role_key"] = "char.title"
	data["level"] = CharacterLib.current_level()
	data["attributes"] = CharacterLib.attributes()
	data["skill_keys"] = CharacterLib.SKILL_KEYS
	# §4.3: the three officer-only skills render grayed-labelled on the player.
	var skills: Dictionary = {}
	var keys: Array[String] = []
	keys.assign(CharacterLib.SKILL_KEYS)
	for key in CharacterLib.SKILL_KEYS:
		skills[key] = SkillsLib.skill(key)
	for key in SkillsLib.OFFICER_KEYS:
		skills[key] = 0
		(data["grayed_skill_keys"] as Array).append(key)
		# The officer-only skills render as grayed-labelled rows (§4.12.1).
		keys.append(key)
	data["skill_keys"] = keys
	data["skills"] = skills
	data["xp"] = CharacterLib.current_xp()
	data["next_xp"] = CharacterLib.xp_to_next_level()
	data["alloc_pending"] = CharacterLib.alloc_pending()
	data["effective"] = effective_split()


## §4.5.3 the effective-values split, per player skill: base + the one
## in-post officer's contribution (+ the native-signature tag) = effective,
## with the "without this officer" value the rows difference on display.
static func effective_split() -> Array:
	var nation: Dictionary = DataLoader.get_nation(
		str(GameState.player.get("nation_id", "")))
	var native_skill := str(nation.get("bonus_skill", ""))
	var rows: Array = []
	for key in CharacterLib.SKILL_KEYS:
		var base := SkillsLib.skill(key)
		var add := SkillsLib.officer_contribution(key)
		var holder_id := ""
		for post_id in SkillsLib.POST_SKILL:
			if str(SkillsLib.POST_SKILL[post_id]) == key:
				holder_id = SkillsLib.post_holder(str(post_id))
				break
		var holder_name := ""
		if not holder_id.is_empty():
			holder_name = I18n.t(DataLoader.get_officer(holder_id)
				.get("name", {}))
		rows.append({
			"key": key,
			"base": base,
			"officer_add": add,
			"native": key == native_skill,
			"holder": holder_name,
			"total": base + add,
			"without": base,
		})
	return rows


## The officer view: the v2 record plus the live relations.
static func _fill_officer(data: Dictionary, officer_id: String) -> void:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if officer.is_empty():
		push_error("CharacterCard.card_data: unknown officer '%s'" % officer_id)
		return
	data["name"] = I18n.t(officer.get("name", {}))
	data["nation_id"] = str(officer.get("nation_id", ""))
	# The native role is the §4.5.2 signature: the card names the main skill.
	var main := str(officer.get("main_skill", ""))
	data["main_skill"] = main
	data["role_id"] = main
	data["role_key"] = "skill.%s" % main
	data["attributes"] = _int_dict(officer.get("attributes", {}))
	data["skill_keys"] = CharacterLib.SKILL_KEYS + SkillsLib.OFFICER_KEYS
	data["skills"] = _int_dict(officer.get("skills", {}))
	data["personality"] = (officer.get("personality", []) as Array).duplicate()
	data["appearance"] = (officer.get("appearance", {}) as Dictionary).duplicate()
	var state: Dictionary = GameState.officer_states.get(officer_id, {})
	data["loyalty"] = int(state.get("loyalty", SkillsLib.LOYALTY_START))
	data["post_id"] = str(state.get("post_id", ""))


## The NPC captain view: the canon card plus the run state.
static func _fill_npc(data: Dictionary, captain_id: String) -> void:
	var canon: Dictionary = DataLoader.get_captain(captain_id)
	if canon.is_empty():
		push_error("CharacterCard.card_data: unknown captain '%s'" % captain_id)
		return
	data["name"] = I18n.t(canon.get("name", {}))
	data["nation_id"] = str(canon.get("nation_id", ""))
	var role := str(canon.get("role", ""))
	data["role_id"] = role
	data["role_key"] = "captain.role.%s" % role if not role.is_empty() \
		else "char.none"
	data["level"] = int(canon.get("level", 1))
	data["attributes"] = _int_dict(canon.get("attributes", {}))
	data["skill_keys"] = CharacterLib.SKILL_KEYS
	data["skills"] = _int_dict(canon.get("skills", {}))
	data["personality"] = (canon.get("personality", []) as Array).duplicate()
	data["appearance"] = (canon.get("appearance", {}) as Dictionary).duplicate()
	var state: Dictionary = CaptainsLib.state(captain_id)
	data["stance"] = int(state.get("stance", 0))
	data["familiarity"] = int(state.get("familiarity", 0))
	data["tier"] = int(state.get("tier_now", int(canon.get("tier", 1))))
	data["wins"] = int(state.get("wins", 0))
	data["defeats"] = int(state.get("defeats", 0))
	data["status"] = str(state.get("status", CaptainsLib.STATUS_ACTIVE))
	data["return_day"] = int(state.get("return_day", 0))


static func _int_dict(source: Variant) -> Dictionary:
	var out: Dictionary = {}
	if source is Dictionary:
		for key in source:
			out[str(key)] = int(source[key])
	return out


## The deterministic portrait color: a pure hash of the appearance tags into
## the §4.8 palette (the same tags always paint the same block).
static func portrait_color(data: Dictionary) -> Color:
	var tags: Array[String] = []
	var appearance: Dictionary = data.get("appearance", {})
	for axis in ["face", "beard", "eyes", "hair"]:
		tags.append("%s=%s" % [axis, str(appearance.get(axis, ""))])
	var index := absi(hash(" | ".join(tags))) % PORTRAIT_COLORS.size()
	return PORTRAIT_COLORS[index]


# --- Widget API -------------------------------------------------------------

## Renders `data` (a [method card_data] dictionary).
func setup_person(kind: String, data: Dictionary) -> void:
	if str(data.get("kind", kind)) != kind:
		push_error("CharacterCard.setup_person: data kind '%s' != '%s'"
			% [str(data.get("kind", "")), kind])
		return
	_data = data.duplicate(true)
	_draft = {}
	if _body == null:
		# Not yet in the tree (a card configured straight after instantiate):
		# `_rebuild` runs from `_ready`.
		return
	_rebuild()


## The last rendered data dictionary (the card-identity acceptance pin).
func rendered_data() -> Dictionary:
	return _data.duplicate(true)


## A section node by its Body-relative path ("Identity/Name",
## "Attributes/Attr_luck/Plus", …) — the test/inspection seam. Null when the
## card has not rendered yet or the section does not exist.
func section(path: String) -> Node:
	if _body == null:
		return null
	return _body.get_node_or_null(path)


## The allocation draft currently staged (the §4.12.2 test seam).
func alloc_draft() -> Dictionary:
	return _draft.duplicate()


## Re-stages an allocation draft after a rebuild (the S14 refresh keeps the
## player's in-progress allocation alive across a mid-edit data change).
func restage_draft(draft: Dictionary) -> void:
	_draft = draft.duplicate()
	_refresh_allocation()


func _ready() -> void:
	add_theme_stylebox_override("panel", _panel_style())
	if not _data.is_empty():
		_rebuild()


# --- Rendering --------------------------------------------------------------

func _rebuild() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	var compact := bool(_data.get("compact", false))

	_body.add_child(_build_identity(compact))
	_body.add_child(_section_header(_t("char.card.attributes"),
		"AttributesHeader"))
	_body.add_child(_build_attributes(compact))
	_body.add_child(_section_header(_t("char.card.skills"), "SkillsHeader"))
	_body.add_child(_build_skills(compact))
	if not compact:
		var tags := _build_tags()
		if tags != null and tags.get_child_count() > 0:
			_body.add_child(tags)
	_body.add_child(_section_header(_t("char.card.relations"),
		"RelationsHeader"))
	_body.add_child(_build_relations())
	_body.add_child(_section_header(_t("char.card.career"), "CareerHeader"))
	_body.add_child(_build_career())
	if str(_data.get("kind", "")) == KIND_PLAYER:
		_body.add_child(_section_header(_t("char.card.effective"),
			"EffectiveHeader"))
		_body.add_child(_build_effective())
		if bool(_data.get("alloc", false)):
			_body.add_child(_build_allocation())
			# The stepper states recompute against the live pending counter
			# and the 100 clamp once the box is in the tree.
			_refresh_allocation()
	_publish_content_height()


## Publishes the rendered content height as the scroll's minimum (docs/80-*
## §4.12.1 "Sizing", 2026-11-03 amendment). The scroll's vertical axis is
## scrollable, so without this the card's minimum height is just the
## MarginContainer's margins and the card collapses to an empty bordered
## strip in every host that does not hand it an explicit height (S18 rows,
## the tavern recruit dialog, the S14 hosts — the collapsed-strip bug the
## Phase-8 play report hit). Width needs no help: the scroll's horizontal
## mode is disabled, so the content's minimum width already propagates.
func _publish_content_height() -> void:
	var scroll := _body.get_parent() as ScrollContainer
	if scroll == null:
		return
	scroll.custom_minimum_size.y = _body.get_combined_minimum_size().y


func _build_identity(compact: bool) -> Control:
	var row := HBoxContainer.new()
	row.name = "Identity"
	row.add_theme_constant_override("separation", PaletteLib.MARGIN)
	if not compact:
		# Portrait: palette block from the appearance tags + the name initial.
		var portrait := PanelContainer.new()
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(PORTRAIT_SIZE, PORTRAIT_SIZE)
		var style := StyleBoxFlat.new()
		style.bg_color = _data.get("portrait_color", PaletteLib.PANEL_LINE)
		portrait.add_theme_stylebox_override("panel", style)
		var initial := Label.new()
		initial.name = "Initial"
		initial.text = str(_data.get("name", " ")).substr(0, 1)
		initial.add_theme_font_size_override("font_size", 28)
		initial.add_theme_color_override("font_color", PaletteLib.TEXT)
		initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		portrait.add_child(initial)
		row.add_child(portrait)
	# Flag block: the nation's color (the §4.10.1 flag rule, placeholder block).
	var flag := ColorRect.new()
	flag.name = "Flag"
	flag.custom_minimum_size = Vector2(PaletteLib.ROW_H, PaletteLib.ROW_H)
	flag.color = _nation_color()
	flag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(flag)

	var names := VBoxContainer.new()
	names.name = "Names"
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := _label(str(_data.get("name", "")), PaletteLib.TEXT)
	name_label.name = "Name"
	name_label.add_theme_font_size_override("font_size", 20)
	names.add_child(name_label)
	var detail: Array[String] = []
	var role := _t(str(_data.get("role_key", "char.none")))
	if not role.begins_with("<"):
		detail.append(role)
	var detail_label := _label(" · ".join(detail), PaletteLib.PANEL_LINE)
	detail_label.name = "Role"
	names.add_child(detail_label)
	row.add_child(names)

	# Tier badge (NPC) / level (player + NPC), right-aligned.
	var kind := str(_data.get("kind", ""))
	if kind == KIND_NPC:
		row.add_child(_tier_badge(int(_data.get("tier", 1))))
	if kind == KIND_PLAYER or kind == KIND_NPC:
		var level := _label(I18n.fmt("char.level",
			{"level": int(_data.get("level", 1))}), PaletteLib.ACCENT)
		level.name = "Level"
		level.custom_minimum_size.x = 96.0
		level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(level)
	return row


func _nation_color() -> Color:
	var nation: Dictionary = DataLoader.get_nation(str(_data.get("nation_id", "")))
	var hex := str(nation.get("color", ""))
	return PaletteLib.nation_color(hex) if not hex.is_empty() \
		else PaletteLib.PORT_NEUTRAL


## The five attribute bars (1–100), each row `Attr_<key>` with
## Name / Bar / Value (+ the §4.12.2 `Plus` stepper on the player card).
func _build_attributes(compact: bool) -> Control:
	var box := VBoxContainer.new()
	box.name = "Attributes"
	box.add_theme_constant_override("separation", 4)
	var kind := str(_data.get("kind", ""))
	var with_alloc: bool = kind == KIND_PLAYER and bool(_data.get("alloc", false))
	var attributes: Dictionary = _data.get("attributes", {})
	var bar_w := BAR_COMPACT_W if compact else BAR_W
	for key in CharacterLib.ATTRIBUTES:
		var value := int(attributes.get(key, CharacterLib.BASE_ATTRIBUTE))
		var row := HBoxContainer.new()
		row.name = "Attr_%s" % key
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var name_label := _label(_t("char.attr.%s" % key), PaletteLib.TEXT)
		name_label.name = "Name"
		name_label.custom_minimum_size.x = 96.0
		row.add_child(name_label)
		row.add_child(_bar(value, CharacterLib.ATTR_MAX, PaletteLib.SEA,
			"Bar", bar_w))
		var value_label := _label(str(value), PaletteLib.TEXT)
		value_label.name = "Value"
		value_label.custom_minimum_size.x = 40.0
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)
		if with_alloc:
			var plus := Button.new()
			plus.name = "Plus"
			plus.text = I18n.t_key("creation.stepper.add")
			plus.custom_minimum_size = Vector2(56.0, PaletteLib.BUTTON_H - 8)
			plus.pressed.connect(_on_alloc_plus.bind(key))
			row.add_child(plus)
		box.add_child(row)
	return box


## The skill bars (0–100): the signature/main skill highlighted, a 0 skill
## grayed as unlearned; the player's three officer-only skills render
## grayed-labelled. Each row is `Skill_<key>` with Name / Bar / Value.
func _build_skills(compact: bool) -> Control:
	var box := VBoxContainer.new()
	box.name = "Skills"
	box.add_theme_constant_override("separation", 4)
	var kind := str(_data.get("kind", ""))
	var signature := str(_data.get("main_skill", ""))
	var skills: Dictionary = _data.get("skills", {})
	var bar_w := BAR_COMPACT_W if compact else BAR_W
	for key in _data.get("skill_keys", []):
		var key_name := str(key)
		var value := int(skills.get(key_name, 0))
		var unlearned := value <= 0
		var grayed: bool = key_name in (_data.get("grayed_skill_keys", [])
			as Array)
		var row := HBoxContainer.new()
		row.name = "Skill_%s" % key_name
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var name_label := _label(_t("skill.%s" % key_name),
			PaletteLib.PANEL_LINE if (unlearned or grayed) else PaletteLib.TEXT)
		name_label.name = "Name"
		name_label.custom_minimum_size.x = 96.0
		row.add_child(name_label)
		var color := PaletteLib.PANEL_LINE
		if not unlearned:
			color = PaletteLib.ACCENT if key_name == signature else PaletteLib.SEA
		row.add_child(_bar(value, SkillsLib.SKILL_MAX, color, "Bar", bar_w))
		var value_label := _label(str(value),
			PaletteLib.PANEL_LINE if unlearned else PaletteLib.TEXT)
		value_label.name = "Value"
		value_label.custom_minimum_size.x = 40.0
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)
		if kind == KIND_PLAYER and not grayed:
			# §4.3.3 the usage counter beside the growth bar (the §4.12.3
			# skills tab reuses the card's rows).
			var uses := _label(I18n.fmt("skill.uses", {
				"count": int(SkillsLib.counters().get(key_name, 0)),
				"need": SkillsLib.growth_threshold(key_name),
			}), PaletteLib.PANEL_LINE)
			uses.name = "Uses"
			uses.custom_minimum_size.x = 96.0
			row.add_child(uses)
		box.add_child(row)
	return box


## Personality tags + the appearance sentence (skipped in compact mode and on
## a card without tags — the player carries neither yet). The box is built
## lazily so a tagless Person leaks nothing: the pre-fix code allocated the
## "Tags" VBox unconditionally and dropped it when empty (the orphaned-VBox
## leak in the Phase-8 exit log — one per tagless full-card render).
func _build_tags() -> Control:
	var box: VBoxContainer = null
	var personality: Array = _data.get("personality", [])
	if not personality.is_empty():
		var tags: Array[String] = []
		for tag in personality:
			tags.append(_t("char.personality.%s" % str(tag)))
		box = _tags_box(box)
		var line := _label(I18n.fmt("char.personality_line",
			{"tags": " · ".join(tags)}), PaletteLib.TEXT)
		line.name = "Personality"
		box.add_child(line)
	var appearance: Dictionary = _data.get("appearance", {})
	if not appearance.is_empty():
		var parts: Array[String] = []
		for axis in ["face", "beard", "eyes", "hair"]:
			var value := str(appearance.get(axis, ""))
			if value.is_empty():
				continue
			parts.append(_t("char.appearance.%s.%s" % [axis, value]))
		if not parts.is_empty():
			box = _tags_box(box)
			var line := _label(I18n.fmt("char.appearance.sentence",
				{"parts": " · ".join(parts)}), PaletteLib.PANEL_LINE)
			line.name = "Appearance"
			box.add_child(line)
	return box


## The lazily-created "Tags" box (null stays null until a line needs it).
func _tags_box(existing: VBoxContainer) -> VBoxContainer:
	if existing != null:
		return existing
	var box := VBoxContainer.new()
	box.name = "Tags"
	return box


## Relation block: officer → loyalty + native role + current post (or idle);
## NPC captain → stance + familiarity (+ the familiarity tier name).
func _build_relations() -> Control:
	var box := VBoxContainer.new()
	box.name = "Relations"
	var kind := str(_data.get("kind", ""))
	if kind == KIND_OFFICER:
		var loyalty := _label(_fmt("char.card.loyalty",
			{"amount": int(_data.get("loyalty", 0))}), PaletteLib.TEXT)
		loyalty.name = "Loyalty"
		box.add_child(loyalty)
		var post_id := str(_data.get("post_id", ""))
		var post_line := _label("%s · %s" % [
			_t(str(_data.get("role_key", "char.none"))),
			I18n.t_key("officer.post.%s" % post_id)
			if not post_id.is_empty() else I18n.t_key("officer.post.idle"),
		], PaletteLib.TEXT)
		post_line.name = "Post"
		box.add_child(post_line)
	elif kind == KIND_NPC:
		var relations := _label("%s: %+d · %s: %d" % [
			_t("char.card.relations"),
			int(_data.get("stance", 0)),
			I18n.t_key("dossier.familiarity"),
			int(_data.get("familiarity", 0)),
		], PaletteLib.TEXT)
		relations.name = "Stance"
		box.add_child(relations)
		var tier := CaptainsLib.familiarity_tier(str(_data.get("person_id", "")))
		if tier > 0:
			var tier_label := _label(I18n.t_key(
				"dossier.tier.%d" % TIER_NAME_NUMBERS[tier - 1]),
				PaletteLib.PANEL_LINE)
			tier_label.name = "FamiliarityTier"
			box.add_child(tier_label)
	else:
		box.add_child(_label("-", PaletteLib.PANEL_LINE))
	return box


## Career block: player → XP / level / next-level XP; NPC → wins / defeats /
## return day (a returning captain shows the `dossier.status.returning` state).
func _build_career() -> Control:
	var box := VBoxContainer.new()
	box.name = "Career"
	var kind := str(_data.get("kind", ""))
	if kind == KIND_PLAYER:
		var xp := _label(I18n.fmt("char.xp", {"xp": int(_data.get("xp", 0))}),
			PaletteLib.TEXT)
		xp.name = "Xp"
		box.add_child(xp)
		var next_xp := int(_data.get("next_xp", -1))
		if next_xp >= 0:
			var next_label := _label(I18n.fmt("char.next_level", {"xp": next_xp}),
				PaletteLib.PANEL_LINE)
			next_label.name = "Next"
			box.add_child(next_label)
	elif kind == KIND_NPC:
		var record := _label("%s · %s" % [
			_fmt("char.card.wins", {"amount": int(_data.get("wins", 0))}),
			_fmt("char.card.defeats", {"amount": int(_data.get("defeats", 0))}),
		], PaletteLib.TEXT)
		record.name = "Record"
		box.add_child(record)
		if str(_data.get("status", "")) == CaptainsLib.STATUS_RETURNING:
			var returning := _label("%s · %s" % [
				I18n.t_key("dossier.status.returning"),
				_fmt("char.card.return_day",
					{"day": int(_data.get("return_day", 0))}),
			], PaletteLib.WARN)
			returning.name = "Returning"
			box.add_child(returning)
	else:
		box.add_child(_label("-", PaletteLib.PANEL_LINE))
	return box


## The player card's effective-values split (§4.12.1): one row per skill —
## base, the in-post officer's contribution (with their name), the native
## signature tag, the effective total and the "without this officer" value
## (the rows ARE the diff, §4.12.1 "on demand").
func _build_effective() -> Control:
	var box := VBoxContainer.new()
	box.name = "Effective"
	box.add_theme_constant_override("separation", 4)
	for row_data in _data.get("effective", []):
		var entry: Dictionary = row_data
		var key := str(entry.get("key", ""))
		var row := HBoxContainer.new()
		row.name = "Eff_%s" % key
		row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
		var name_label := _label(_t("skill.%s" % key), PaletteLib.TEXT)
		name_label.name = "Name"
		name_label.custom_minimum_size.x = 96.0
		row.add_child(name_label)
		var parts: Array[String] = []
		var add := int(entry.get("officer_add", 0))
		if add > 0:
			var part := I18n.fmt("char.card.officer_part", {"amount": add})
			if not str(entry.get("holder", "")).is_empty():
				part += " (%s)" % str(entry.get("holder", ""))
			parts.append(part)
		if bool(entry.get("native", false)):
			parts.append(_t("char.card.native_part"))
		var detail := _label(" · ".join(parts) if not parts.is_empty() else "-",
			PaletteLib.PANEL_LINE)
		detail.name = "Parts"
		detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(detail)
		var total := _label(str(int(entry.get("total", 0))), PaletteLib.ACCENT)
		total.name = "Total"
		total.custom_minimum_size.x = 40.0
		total.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(total)
		var without := _label(I18n.fmt("char.card.without_officer",
			{"amount": int(entry.get("without", 0))}), PaletteLib.PANEL_LINE)
		without.name = "Without"
		without.custom_minimum_size.x = 160.0
		without.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(without)
		box.add_child(row)
	return box


## The §4.12.2 allocation footer: the pending-points line, the remaining
## count and the confirm/cancel pair. The per-attribute `Plus` steppers sit
## on the attribute rows; the draft is local to the card and commits through
## `Character.allocate` (no second confirm).
func _build_allocation() -> Control:
	var box := VBoxContainer.new()
	box.name = "Allocation"
	box.add_theme_constant_override("separation", 4)
	var pending := _label("%s: %d" % [I18n.t_key("char.points_pending"),
		CharacterLib.alloc_pending()], PaletteLib.ACCENT)
	pending.name = "Pending"
	box.add_child(pending)
	var left := _label(I18n.fmt("creation.points.left", {"count": _left()}),
		PaletteLib.TEXT)
	left.name = "Left"
	box.add_child(left)
	var clamp_note := _label("", PaletteLib.WARN)
	clamp_note.name = "ClampNote"
	clamp_note.visible = false
	box.add_child(clamp_note)
	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.add_theme_constant_override("separation", PaletteLib.MARGIN)
	var confirm := Button.new()
	confirm.name = "Confirm"
	confirm.text = I18n.t_key("ui.confirm")
	confirm.custom_minimum_size = Vector2(120.0, PaletteLib.BUTTON_H)
	confirm.pressed.connect(_on_alloc_confirm)
	buttons.add_child(confirm)
	var cancel := Button.new()
	cancel.name = "Cancel"
	cancel.text = I18n.t_key("ui.cancel")
	cancel.custom_minimum_size = Vector2(120.0, PaletteLib.BUTTON_H)
	cancel.pressed.connect(_on_alloc_cancel)
	buttons.add_child(cancel)
	box.add_child(buttons)
	return box


# --- Allocation flow (§4.12.2, locked) --------------------------------------

## Points left in the draft (`alloc_pending` − spent).
func _left() -> int:
	var spent := 0
	for key in _draft:
		spent += maxi(0, int(_draft[key]))
	return maxi(0, CharacterLib.alloc_pending() - spent)


## One `+` press: the draft gains a point when points remain and the
## attribute sits below the 100 clamp (§4.4).
func _on_alloc_plus(key: String) -> void:
	if _left() <= 0:
		return
	var attributes: Dictionary = _data.get("attributes", {})
	var value := int(attributes.get(key, CharacterLib.BASE_ATTRIBUTE)) \
		+ int(_draft.get(key, 0))
	if value + 1 > CharacterLib.ATTR_MAX:
		_show_clamp_note()
		return
	_draft[key] = int(_draft.get(key, 0)) + 1
	_refresh_allocation()


## Confirm: the draft commits through [method Character.allocate] — points
## leave `alloc_pending`, the card re-renders from live state. A refused
## draft (any attribute would pass 100) shows the clamp note and rolls
## nothing (points are never partially spent, §4.4/§6).
func _on_alloc_confirm() -> void:
	if _draft.is_empty():
		return
	if not CharacterLib.allocate(_draft):
		_show_clamp_note()
		return
	_draft = {}
	var kind := str(_data.get("kind", ""))
	setup_person(kind, card_data(kind, str(_data.get("person_id", "")),
		{"alloc": bool(_data.get("alloc", false)),
			"compact": bool(_data.get("compact", false))}))


## Cancel: the draft rolls back (nothing was written — the draft is local).
func _on_alloc_cancel() -> void:
	_draft = {}
	_refresh_allocation()


func _show_clamp_note() -> void:
	var note := _body.get_node_or_null("Allocation/ClampNote") as Label
	if note == null:
		return
	note.text = I18n.t_key("creation.cap_reached")
	note.visible = true


## Re-renders the attribute values (+draft), the remaining-points line and
## every stepper's enable state (`alloc_pending > 0` and below the clamp) —
## covering the whole attribute table, not just drafted rows, so a re-render
## lands on a correct board too.
func _refresh_allocation() -> void:
	var allocation := _body.get_node_or_null("Allocation")
	if allocation == null:
		return
	var attributes: Dictionary = _data.get("attributes", {})
	var spent := 0
	for key in _draft:
		spent += maxi(0, int(_draft[key]))
	for key in CharacterLib.ATTRIBUTES:
		var row := _body.get_node_or_null("Attributes/Attr_%s" % key)
		if row == null:
			continue
		var key_name := str(key)
		var base := int(attributes.get(key_name, CharacterLib.BASE_ATTRIBUTE))
		var delta := int(_draft.get(key_name, 0))
		var value_label := row.get_node("Value") as Label
		value_label.text = str(base + delta) if delta == 0 \
			else "%d %+d" % [base + delta, delta]
		value_label.add_theme_color_override("font_color",
			PaletteLib.ACCENT if delta > 0 else PaletteLib.TEXT)
		var plus := row.get_node_or_null("Plus") as Button
		if plus == null:
			continue
		var value := base + delta
		plus.disabled = CharacterLib.alloc_pending() - spent <= 0 \
			or value >= CharacterLib.ATTR_MAX
		plus.tooltip_text = I18n.t_key("creation.cap_reached") \
			if value >= CharacterLib.ATTR_MAX else ""
	var left := allocation.get_node("Left") as Label
	left.text = I18n.fmt("creation.points.left", {"count": _left()})
	var note := allocation.get_node("ClampNote") as Label
	note.visible = false


# --- Widget helpers ---------------------------------------------------------

## `ui_strings` key first, the card's fallback table second (the W5-C
## `_inform_text` pattern — the residual merge is W6-D's).
static func _t(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return I18n.t(FALLBACK_STRINGS.get(key, {}))


## `_t` plus `{name}` substitution for a fallback key (the I18n.fmt shape).
static func _fmt(key: String, values: Dictionary = {}) -> String:
	var text := _t(key)
	for name in values:
		text = text.replace("{%s}" % name, str(values[name]))
	return text


func _tier_badge(tier: int) -> Control:
	# The fleet picker's badge palette (1 grey / 2 amber / 3 red — §4.8).
	var badge := PanelContainer.new()
	badge.name = "TierBadge"
	badge.custom_minimum_size = Vector2(PaletteLib.ROW_H, PaletteLib.ROW_H)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_LINE if tier <= 1 \
		else (PaletteLib.WARN if tier == 2 else PaletteLib.BAD)
	badge.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = str(tier)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(label)
	return badge


func _bar(value: int, max_value: int, color: Color, bar_name: String,
		width: float) -> Control:
	var bar := ProgressBar.new()
	bar.name = bar_name
	bar.min_value = 0
	bar.max_value = max_value
	bar.value = clampi(value, 0, max_value)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(width, BAR_H)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var background := StyleBoxFlat.new()
	background.bg_color = PaletteLib.PANEL_LINE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("background", background)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


func _section_header(text: String, header_name: String) -> Label:
	var header := _label(text, PaletteLib.ACCENT)
	header.name = header_name
	header.add_theme_font_size_override("font_size", 16)
	return header


func _label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	return label


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
