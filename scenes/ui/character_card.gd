class_name CharacterCard
extends Panel
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
## Portraits (Phase-10 decision 10, W4-D): the Identity slot renders the
## procedural 72×96 bust from `PortraitComposer` (override file wins,
## appearance-tag composition otherwise; the player card passes role
## "player"). The §4.8 placeholder color block + name initial stays as the
## fallback when even `pp_base` is missing. Bars are the §4.9 kit atom
## (`UiKit.value_bar`); labels are theme TEXT / the `Dim` variation — the
## card styles nothing itself (§4.9 no-per-screen-styling rule).
##
## `FALLBACK_STRINGS` is the W5-C pattern: keys the card needs that the shared
## `data/ui_strings.json` does not carry yet (W6-D owns the residual merge —
## reported). Resolved by [method _t]: canonical key first, fallback second.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's class cache.
##
## Phase 12 (docs/80-* §4.8.9, the absolute-tile layout): the flow tree is
## DELETED — the card is a plain `Panel` whose only container is the internal
## `ScrollContainer` (the clipped viewport of the §4.12.1 scrolling card);
## its content node is a plain `Control` sized to the stacked extent, and
## every section/row hangs off it at an authored tile rect. The card is its
## own layout screen (`character_card`, docs/10-* §4.23): the persistent
## controls register stable dotted ids (shared across the player/officer/NPC
## variants — a variant simply leaves a variant-only id unregistered), the
## attribute/skill rows are `attributes`/`skills` LIST members
## (`RegistryLib.list_rect`), and the build path activates the screen
## (`RegistryLib.screen_active`) so the data table governs wherever the card
## is embedded — the parent-bounds clamp adapts the viewport to each host
## (the dossier's 420 px card window, the roster's full-height page, the
## picker's grown panel) without per-host code.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
## Phase-10 kit atoms (§4.9) — the value_bar adoption (W4-D sweep).
const UiKitLib := preload("res://scripts/ui_kit.gd")
## Phase-10 W4-D portrait ladder (decision 10): override file wins, else the
## procedural 72×96 bust composed from the appearance axes.
const PortraitComposerLib := preload("res://scripts/ui/portrait_composer.gd")
## Phase 12 (docs/80-* §4.8.9): the card registers under its layout id.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

const SCENE_PATH := "res://scenes/ui/character_card.tscn"

## This card's layout screen id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "character_card"

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

## Attribute / skill bar geometry (the §4.8 8px grid). Bar height is the
## §4.9 kit atom's own (UiKit.BAR_H) since the W4-D sweep.
const BAR_W := 160.0
const BAR_COMPACT_W := 96.0
## Portrait slot (§4.8/decision 10): the composer bust is 72×96 (3:4 bust);
## the placeholder color block + initial stays as the null-size fallback.
const PORTRAIT_SIZE := Vector2(72, 96)
const PORTRAIT_FALLBACK := 64.0
## The deterministic portrait palette (§4.8 constants only — no new colors).
const PORTRAIT_COLORS: Array[Color] = [
	PaletteLib.SEA, PaletteLib.COAST_SEA, PaletteLib.LAND, PaletteLib.ACCENT,
	PaletteLib.GOOD, PaletteLib.WARN, PaletteLib.BAD, PaletteLib.PORT_NEUTRAL,
]
## familiarity tier (0–3) → the `dossier.tier.*` name key's number.
const TIER_NAME_NUMBERS: Array[int] = [3, 6, 10]

## Phase 12 — the authored tile table (docs/80-* §4.8.9: today's captured
## look, flattened to the 32×32 grid; the capture
## `data/layout_fragments/character_card.json` pins the same numbers).
## Parent-relative tiles: children of a group address the group's rect; the
## rows live in their list blocks (below). 1 tile = Palette.CHROME_TILE.
const CARD_TILES := 15  # the content column's width in tiles
const CARD_TILES_TABLE := {
	"card": Rect2i(0, 0, 32, 34),
	"scroll": Rect2i(0, 0, 32, 34),
	"body": Rect2i(0, 0, 15, 34),
	"identity": Rect2i(0, 0, 15, 3),
	"identity.portrait": Rect2i(0, 0, 3, 3),
	"identity.flag": Rect2i(3, 0, 1, 1),
	"identity.names": Rect2i(4, 0, 8, 2),
	"identity.names.name": Rect2i(0, 0, 8, 1),
	"identity.names.role": Rect2i(0, 1, 8, 1),
	"identity.tier_badge": Rect2i(12, 0, 1, 1),
	"identity.level": Rect2i(13, 0, 2, 1),
	"stat_columns": Rect2i(0, 3, 15, 18),
	"stat_columns.attribute_column": Rect2i(0, 0, 15, 6),
	"stat_columns.attribute_column.header": Rect2i(0, 0, 8, 1),
	"stat_columns.attribute_column.attributes": Rect2i(0, 1, 15, 5),
	"stat_columns.skill_column": Rect2i(0, 6, 15, 12),
	"stat_columns.skill_column.header": Rect2i(0, 6, 8, 1),
	"stat_columns.skill_column.skills": Rect2i(0, 7, 15, 11),
	"tags": Rect2i(0, 21, 15, 2),
	"tags.personality": Rect2i(0, 0, 15, 1),
	"tags.appearance": Rect2i(0, 1, 15, 1),
	"relations.header": Rect2i(0, 23, 15, 1),
	"relations": Rect2i(0, 24, 15, 2),
	"relations.loyalty": Rect2i(0, 0, 15, 1),
	"relations.post": Rect2i(0, 1, 15, 1),
	"relations.stance": Rect2i(0, 0, 15, 1),
	"relations.tier": Rect2i(0, 1, 15, 1),
	"relations.empty": Rect2i(0, 0, 15, 1),
	"career.header": Rect2i(0, 26, 15, 1),
	"career": Rect2i(0, 27, 15, 2),
	"career.xp": Rect2i(0, 0, 15, 1),
	"career.next": Rect2i(0, 1, 15, 1),
	"career.record": Rect2i(0, 0, 15, 1),
	"career.returning": Rect2i(0, 1, 15, 1),
	"career.empty": Rect2i(0, 0, 15, 1),
	"allocation": Rect2i(0, 29, 15, 5),
	"allocation.pending": Rect2i(0, 0, 15, 1),
	"allocation.left": Rect2i(0, 1, 15, 1),
	"allocation.clamp_note": Rect2i(0, 2, 15, 1),
	"allocation.buttons": Rect2i(0, 3, 15, 2),
	"allocation.confirm": Rect2i(0, 0, 4, 2),
	"allocation.cancel": Rect2i(4, 0, 4, 2),
}

## Phase 12 — the dynamic list blocks (the attribute/skill rows): rows take
## `RegistryLib.list_rect(SCREEN_ID, list, index)` in their stack group's
## space (`base` is group-relative, the §4.23 block shape).
const LIST_ATTRIBUTES := "attributes"
const LIST_SKILLS := "skills"
const CARD_LISTS := {
	LIST_ATTRIBUTES: {"base": {"x": 0, "y": 0, "w": 15, "h": 1}, "row_h": 1},
	LIST_SKILLS: {"base": {"x": 0, "y": 0, "w": 15, "h": 1}, "row_h": 1},
}

## The row-cell rects in row-local px (the rows are 1 tile tall; cells are
## absolutely-placed unregistered children — the §4.8.9 row-internals rule).
const CELL_NAME := Rect2(0, 0, 96, 32)
const CELL_BAR := Rect2(96, 8, 160, 16)
const CELL_VALUE := Rect2(256, 0, 64, 32)
const CELL_PLUS := Rect2(320, 0, 64, 56)
const CELL_USES := Rect2(320, 0, 96, 32)
## The Plus stepper is a 2-tile button standing in the row's empty right
## lane (attribute rows carry no Uses cell there), so every row keeps the
## 1-tile pitch and one rect set serves all three variants.

## The last data dictionary this card rendered ([method card_data] shape —
## the acceptance pin reads this from every entry).
var _data: Dictionary = {}
## The §4.12.2 allocation draft (`{attribute_key: +n}`), local to the card.
var _draft: Dictionary = {}

## The card's own viewport (the ONLY container left — the §4.12.1 scrolling
## card) and its plain-Control content node.
@onready var _scroll: ScrollContainer = $Scroll
@onready var _body: Control = $Scroll/Body


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
		"stat_blocks": bool(options.get("stat_blocks", true)),
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
	# §4.9 (W4-D sweep): the Panel chrome is the theme's — the per-card
	# stylebox retired with the rest of the per-screen styling.
	if not _data.is_empty():
		_rebuild()


# --- Rendering (Phase 12: the absolute-tile card) ---------------------------

func _rebuild() -> void:
	_clear(_body)

	# The card's own chrome: viewport + content node. The viewport rides
	# FULL-RECT anchors (it always fills whatever rect the host gave the
	# card — the §4.12.1 per-host sizing); the managed apply re-derives the
	# same fill from the data rect (the parent-bounds clamp), the authored
	# tiles stay the unmanaged fallback. The content node is a plain Control
	# sized to the stacked extent (the §4.8.9 viewport rule) — left
	# UNREGISTERED, exactly like the market's `GoodsRows`.
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_body.position = Vector2.ZERO
	_body.size = Vector2(CARD_TILES, CARD_TILES_TABLE["body"].size.y) \
		* float(PaletteLib.CHROME_TILE)
	_body.custom_minimum_size = _body.size
	# The §4.12.1 "Sizing" contract (the collapsed-strip fix): the card's
	# minimum is its full content extent, so a host that does not hand the
	# card an explicit height (the tavern dialog's scroll, the picker's
	# `reset_size`) still shows the whole card and scrolls it in its own
	# viewport; hosts that do hand one (the dossier's 420 px card window)
	# clamp it right back via the managed apply or their explicit size.
	custom_minimum_size = _body.size

	var compact := bool(_data.get("compact", false))
	_build_identity(compact)
	if not bool(_data.get("stat_blocks", true)):
		# The officers detail page (amended 2026-11-03): the table already
		# shows every attribute and skill, so the detail card omits the blocks
		# entirely rather than rendering them empty.
		pass
	else:
		# Attributes on the left, skills on the right (amended 2026-11-03):
		# one two-column block halves the card height. The absolute card
		# keeps the single-column stack (the flat §4.12.1 form); the
		# StatColumns/AttributeColumn/SkillColumn groups stay as plain
		# Controls at their data rects so the §4.12 section seam is stable.
		_build_stat_columns()
	if not compact:
		_build_tags()
	_build_relations()
	_build_career()
	if str(_data.get("kind", "")) == KIND_PLAYER \
			and bool(_data.get("alloc", false)):
		# The standalone 生效值 block is retired (amended 2026-11-03): the
		# skill rows now show the effective value and their tooltips carry the
		# base / officer / total split plus each gate (§4.12.1/§4.12.3).
		_build_allocation()
		# The stepper states recompute against the live pending counter
		# and the 100 clamp once the box is in the tree.
		_refresh_allocation()
	# Phase 12 (docs/80-* §4.8.9): the build path activates the card's own
	# layout screen — the persistent controls' data rects apply (a managed
	# table clamps the viewport into the host's rect; an unmanaged one
	# leaves the authored tiles), and the bridge learns the screen.
	RegistryLib.screen_active(SCREEN_ID, self)


## Phase 12: one authored rect = one `position`/`size` write, in the DIRECT
## parent's tile space (point anchors everywhere; nothing is stretched) —
## and one registration under the matching stable dotted id (the §4.8.9 id
## registry; re-registration replaces the record across rebuilds).
func _place(control: Control, id: String) -> void:
	var rect: Rect2i = CARD_TILES_TABLE.get(id, Rect2i(0, 0, 2, 2))
	_place_rect(control, rect)
	RegistryLib.register(SCREEN_ID, control, id)


func _place_rect(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(PaletteLib.CHROME_TILE)
	control.size = Vector2(rect.size) * float(PaletteLib.CHROME_TILE)


## Row *i*'s rect for a card list block — px in the stack group's space:
## the data block when managed, the same tiles authored otherwise.
func _list_row_rect(list_id: String, index: int) -> Rect2:
	var rect := RegistryLib.list_rect(SCREEN_ID, list_id, index)
	if rect != Rect2():
		return rect
	var block: Dictionary = CARD_LISTS.get(list_id, {})
	var base: Dictionary = block.get("base", {})
	var row_h: int = int(block.get("row_h", 1))
	return Rect2(
		Vector2(int(base.get("x", 0)), int(base.get("y", 0))
			+ index * row_h) * float(PaletteLib.CHROME_TILE),
		Vector2(int(base.get("w", 15)), row_h) * float(PaletteLib.CHROME_TILE))


func _build_identity(compact: bool) -> void:
	var identity := _group("Identity")
	_body.add_child(identity)
	_place(identity, "identity")

	# The portrait slot (Phase-10 decision 10, W4-D): the ladder's procedural
	# rung — `PortraitComposer.portrait_texture` (override file wins) — at
	# the bust size, nearest filtering per §4.8.8. When even `pp_base` is
	# missing the placeholder color block + name initial takes over (the
	# §4.8 placeholder rule, same node name either way — hosts and suites
	# read `Identity/Portrait`).
	var portrait := _build_portrait()
	identity.add_child(portrait)
	_place(portrait, "identity.portrait")

	# Flag block: the nation's color (the §4.10.1 flag rule, placeholder
	# block).
	var flag := ColorRect.new()
	flag.name = "Flag"
	flag.color = _nation_color()
	flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	identity.add_child(flag)
	_place(flag, "identity.flag")

	# Names block: the name line + the role line (a plain Control group —
	# the deleted VBox's two labels at their data rects).
	var names := _group("Names")
	identity.add_child(names)
	_place(names, "identity.names")
	var name_label := _label(str(_data.get("name", "")))
	name_label.name = "Name"
	names.add_child(name_label)
	_place(name_label, "identity.names.name")
	var detail: Array[String] = []
	var role := _t(str(_data.get("role_key", "char.none")))
	if not role.begins_with("<"):
		detail.append(role)
	var role_label := _dim_label(" · ".join(detail))
	role_label.name = "Role"
	names.add_child(role_label)
	_place(role_label, "identity.names.role")

	# Tier badge (NPC) / level (player + NPC), right-aligned.
	var kind := str(_data.get("kind", ""))
	if kind == KIND_NPC:
		var badge := _tier_badge(int(_data.get("tier", 1)))
		identity.add_child(badge)
		_place(badge, "identity.tier_badge")
	if kind == KIND_PLAYER or kind == KIND_NPC:
		var level := _label(I18n.fmt("char.level",
			{"level": int(_data.get("level", 1))}))
		level.name = "Level"
		level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		identity.add_child(level)
		_place(level, "identity.level")


## The portrait slot (Phase-10 decision 10, W4-D): the ladder's procedural
## rung — `PortraitComposer.portrait_texture` (override file wins) — at the
## bust size, nearest filtering per §4.8.8. When even `pp_base` is missing
## the placeholder color block + name initial takes over (the §4.8
## placeholder rule, same node name either way — hosts and suites read
## `Identity/Portrait`).
func _build_portrait() -> Control:
	var person := {
		"id": str(_data.get("person_id", "")),
		"appearance": _data.get("appearance", {}),
		# The player block carries no role/canon cloth — the card composes
		# the §4.8 "player" cloth rung; NPCs pass their canon role (an
		# officer's main_skill is not a cloth id — that layer just skips).
		"role": "player" if str(_data.get("kind", "")) == KIND_PLAYER \
			else str(_data.get("role_id", "")),
		"nation_id": str(_data.get("nation_id", "")),
	}
	var bust := PortraitComposerLib.portrait_texture(person)
	if bust != null:
		var rect := TextureRect.new()
		rect.name = "Portrait"
		rect.texture = bust
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return rect
	var block := ColorRect.new()
	block.name = "Portrait"
	block.color = _data.get("portrait_color", PaletteLib.PANEL_LINE)
	block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var initial := Label.new()
	initial.name = "Initial"
	initial.text = str(_data.get("name", " ")).substr(0, 1)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	initial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	block.add_child(initial)
	return block


func _nation_color() -> Color:
	var nation: Dictionary = DataLoader.get_nation(str(_data.get("nation_id", "")))
	var hex := str(nation.get("color", ""))
	return PaletteLib.nation_color(hex) if not hex.is_empty() \
		else PaletteLib.PORT_NEUTRAL


## The stat block: attributes then skills (the flat §4.12.1 form). The
## StatColumns / AttributeColumn / SkillColumn groups stay as plain Controls
## at their data rects so the §4.12 section seam (`StatColumns/
## AttributeColumn/Attributes/Attr_<key>`) is stable; the row cells are
## absolutely-placed unregistered children.
func _build_stat_columns() -> void:
	var columns := _group("StatColumns")
	_body.add_child(columns)
	_place(columns, "stat_columns")

	var left := _group("AttributeColumn")
	columns.add_child(left)
	_place(left, "stat_columns.attribute_column")
	var attributes_header := _section_header(_t("char.card.attributes"),
		"AttributesHeader")
	left.add_child(attributes_header)
	_place(attributes_header, "stat_columns.attribute_column.header")
	var attributes := _group("Attributes")
	left.add_child(attributes)
	_place(attributes, "stat_columns.attribute_column.attributes")
	_build_attributes(attributes)

	var right := _group("SkillColumn")
	columns.add_child(right)
	_place(right, "stat_columns.skill_column")
	var skills_header := _section_header(_t("char.card.skills"),
		"SkillsHeader")
	right.add_child(skills_header)
	_place(skills_header, "stat_columns.skill_column.header")
	var skills := _group("Skills")
	right.add_child(skills)
	_place(skills, "stat_columns.skill_column.skills")
	_build_skills(skills)


## The five attribute bars (1–100), each row `Attr_<key>` with
## Name / Bar / Value (+ the §4.12.2 `Plus` stepper on the player card).
## Every row explains what the attribute feeds on hover (amended 2026-11-03).
## Phase 12: rows are `attributes` list members at `list_rect` slots; the
## cells are absolutely-placed unregistered children.
func _build_attributes(attributes: Control) -> void:
	var kind := str(_data.get("kind", ""))
	var with_alloc: bool = kind == KIND_PLAYER and bool(_data.get("alloc", false))
	var values: Dictionary = _data.get("attributes", {})
	for index in CharacterLib.ATTRIBUTES.size():
		var key: String = CharacterLib.ATTRIBUTES[index]
		var value := int(values.get(key, CharacterLib.BASE_ATTRIBUTE))
		var row := _list_row("Attr_%s" % key, "attributes.%s" % key,
			LIST_ATTRIBUTES, index, attributes)
		# Hover explanation (`50-*` §4.2.1 verbatim, in ui_strings).
		var tooltip := wrap_tip(_desc("char.attr.%s.desc" % key))
		row.tooltip_text = tooltip
		var name_label := _label(_t("char.attr.%s" % key))
		name_label.name = "Name"
		name_label.tooltip_text = tooltip
		row.add_child(name_label)
		_cell(name_label, CELL_NAME)
		row.add_child(_bar(value, CharacterLib.ATTR_MAX, "good",
			"Bar", tooltip))
		var value_label := _label(str(value))
		value_label.name = "Value"
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.tooltip_text = tooltip
		row.add_child(value_label)
		_cell(value_label, CELL_VALUE)
		if with_alloc:
			var plus := Button.new()
			plus.name = "Plus"
			plus.text = I18n.t_key("creation.stepper.add")
			plus.pressed.connect(_on_alloc_plus.bind(key))
			row.add_child(plus)
			_cell(plus, CELL_PLUS)


## The skill bars (0–100): the signature/main skill highlighted, a 0 skill
## grayed as unlearned; the player's three officer-only skills render
## grayed-labelled. Each row is `Skill_<key>` with Name / Bar / Value
## (+ the §4.3.3 `Uses` counter on the player card).
##
## **The player row shows the effective value (amended 2026-11-03):**
## `effective = stored + the one in-post officer's contribution`
## (`50-*` §4.5.3) — the same read `SkillsLib.effective_skill` performs, so
## the number on the row is the number the pipelines consume. The split
## (base · officer · effective) and every gate keyed on the skill live in the
## row's tooltip instead of two extra page sections (§4.12.3).
func _build_skills(skills_box: Control) -> void:
	var kind := str(_data.get("kind", ""))
	var signature := str(_data.get("main_skill", ""))
	var values: Dictionary = _data.get("skills", {})
	var keys: Array = _data.get("skill_keys", [])
	for index in keys.size():
		var key_name := str(keys[index])
		var stored := int(values.get(key_name, 0))
		var row := _list_row("Skill_%s" % key_name, "skills.%s" % key_name,
			LIST_SKILLS, index, skills_box)

		# The value the row shows: the effective value on the player card
		# (stored + in-post officer), the plain stored value elsewhere.
		var value := stored
		var officer_add := 0
		var holder := ""
		if kind == KIND_PLAYER:
			officer_add = SkillsLib.officer_contribution(key_name)
			value = stored + officer_add
			holder = _post_holder_name(key_name)
		var unlearned := value <= 0
		var grayed: bool = key_name in (_data.get("grayed_skill_keys", [])
			as Array)

		# Hover explanation (`50-*` §4.3.1/§4.3.2 verbatim, in ui_strings),
		# plus the player's value split and this skill's gates (§4.12.3).
		var tooltip := _desc("skill.%s.desc" % key_name)
		if kind == KIND_PLAYER:
			var split := _value_split_tip(stored, officer_add, holder)
			var gates := _gates_tip(key_name, value)
			var extra: Array[String] = [split]
			if not gates.is_empty():
				extra.append(gates)
			tooltip = "\n".join(extra) if tooltip.is_empty() \
				else "%s\n%s" % [tooltip, "\n".join(extra)]
		tooltip = wrap_tip(tooltip)
		row.tooltip_text = tooltip
		var learned := not (unlearned or grayed)
		var name_label := _label(_t("skill.%s" % key_name)) if learned \
			else _dim_label(_t("skill.%s" % key_name))
		name_label.name = "Name"
		name_label.tooltip_text = tooltip
		row.add_child(name_label)
		_cell(name_label, CELL_NAME)
		# §4.9 atom tiers (W4-D sweep): the signature highlight keeps the
		# accent hex through "warn" (WARN == ACCENT), everything else reads
		# the kit's "good" fill (an unlearned 0-value row shows no fill).
		var tier := "warn" if (not unlearned and key_name == signature) \
			else "good"
		row.add_child(_bar(value, SkillsLib.SKILL_MAX, tier, "Bar", tooltip))
		var value_label := _label(str(value)) if not unlearned \
			else _dim_label(str(value))
		value_label.name = "Value"
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.tooltip_text = tooltip
		row.add_child(value_label)
		_cell(value_label, CELL_VALUE)
		if kind == KIND_PLAYER and not grayed:
			# §4.3.3 the usage counter beside the growth bar (the §4.12.3
			# skills tab reuses the card's rows).
			var uses := _dim_label(I18n.fmt("skill.uses", {
				"count": int(SkillsLib.counters().get(key_name, 0)),
				"need": SkillsLib.growth_threshold(key_name),
			}))
			uses.name = "Uses"
			uses.tooltip_text = tooltip
			row.add_child(uses)
			_cell(uses, CELL_USES)


## One list-row node at its `list_rect` slot (the §4.8.9 dynamic-row rule):
## a plain Control registered as the block's member; the cells hang
## unregistered.
func _list_row(node_name: String, id: String, list_id: String, index: int,
		parent: Control) -> Control:
	var row := Control.new()
	row.name = node_name
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(row)
	var rect := _list_row_rect(list_id, index)
	row.position = rect.position
	row.size = rect.size
	RegistryLib.register(SCREEN_ID, row, id,
		{"list": list_id, "data_ordered": true})
	return row


## One row cell: an absolutely-placed unregistered child at a row-local px
## rect (the §4.8.9 row-internals rule). The vertical center rides the
## control's own alignment; nothing is stretched.
func _cell(control: Control, rect: Rect2) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = rect.position
	control.size = rect.size
	if control is Label:
		(control as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER


## The first line of a player skill row's tooltip: the value split
## (`基础 5 · 官员贡献 +30 (马特乌斯) · 生效 35`, §4.12.1 amended). The officer
## part is omitted when no post contributes.
static func _value_split_tip(stored: int, officer_add: int,
		holder: String) -> String:
	var parts: Array[String] = [I18n.fmt("char.card.tip.base", {"base": stored})]
	if officer_add != 0:
		var part := I18n.fmt("char.card.tip.officer", {"amount": officer_add})
		if not holder.is_empty():
			part += " (%s)" % holder
		parts.append(part)
	parts.append(I18n.fmt("char.card.tip.effective",
		{"total": stored + officer_add}))
	return " · ".join(parts)


## This skill's gates, one line each (`<name> · 需 <skill> ≥ <n> ·
## 已解锁/未解锁 (<current>/<threshold>)`, §4.12.3 amended). Empty when the
## skill has none, so the tooltip never pads with an empty section.
static func _gates_tip(key_name: String, current: int) -> String:
	var lines: Array[String] = []
	for gate in DataLoader.skill_gates_list:
		if str(gate.get("stat_or_skill", "")) != key_name:
			continue
		var threshold := int(gate.get("threshold", 0))
		lines.append("%s · %s · %s (%d/%d)" % [
			I18n.t(gate.get("name", {})),
			I18n.fmt("gate.requires", {
				"stat": _t("skill.%s" % key_name), "n": threshold}),
			I18n.t_key("gate.unlocked" if current >= threshold
				else "gate.locked"),
			current, threshold,
		])
	return "\n".join(lines)


## The name of the officer holding the post that feeds `key_name` (`""` when
## the post is vacant or the skill has no post).
static func _post_holder_name(key_name: String) -> String:
	for post_id in SkillsLib.POST_SKILL:
		if str(SkillsLib.POST_SKILL[post_id]) != key_name:
			continue
		var holder := SkillsLib.post_holder(str(post_id))
		if holder.is_empty():
			return ""
		return I18n.t(DataLoader.get_officer(holder).get("name", {}))
	return ""


## Tooltip wrap width in display columns (a CJK glyph counts 2). The engine's
## own tooltip is a plain `Label` with autowrap OFF, so a long single line runs
## off the right edge of the screen — the UI wraps the text itself (§4.12.1
## amended 2026-11-03).
const TIP_COLUMNS := 56


## Wraps `text` to TIP_COLUMNS, honouring the caller's own line breaks (the
## value split / each gate keeps its own line).
static func wrap_tip(text: String) -> String:
	if text.is_empty():
		return ""
	var rows: Array[String] = []
	for line in text.split("\n"):
		rows.append_array(_wrap_line(line))
	return "\n".join(rows)


static func _wrap_line(line: String) -> Array[String]:
	var rows: Array[String] = []
	var current := ""
	var width := 0
	var last_space := -1
	for index in line.length():
		var ch := line[index]
		var w := 2 if ch.unicode_at(0) > 0x2E7F else 1
		if width + w > TIP_COLUMNS and not current.is_empty():
			if last_space > 0:
				rows.append(current.substr(0, last_space))
				current = current.substr(last_space + 1)
				last_space = -1
			else:
				rows.append(current)
				current = ""
			width = _tip_width(current)
		current += ch
		width += w
		if ch == " ":
			last_space = current.length() - 1
	if not current.is_empty():
		rows.append(current)
	return rows


static func _tip_width(text: String) -> int:
	var width := 0
	for index in text.length():
		width += 2 if text[index].unicode_at(0) > 0x2E7F else 1
	return width


## Personality tags + the appearance sentence (skipped in compact mode and on
## a card without tags — the player carries neither yet). The lines sit at
## their reserved data slots whether or not they render (the empty slots
## stay blank — no flow collapses), so one rect set serves every variant.
func _build_tags() -> void:
	var personality: Array = _data.get("personality", [])
	var appearance: Dictionary = _data.get("appearance", {})
	if personality.is_empty() and appearance.is_empty():
		return  # a tagless Person leaks nothing (the Phase-8 lazy-box rule)
	var tags := _group("Tags")
	_body.add_child(tags)
	_place(tags, "tags")
	if not personality.is_empty():
		var tags_text: Array[String] = []
		for tag in personality:
			tags_text.append(_t("char.personality.%s" % str(tag)))
		var line := _label(I18n.fmt("char.personality_line",
			{"tags": " · ".join(tags_text)}))
		line.name = "Personality"
		tags.add_child(line)
		_place(line, "tags.personality")
	if not appearance.is_empty():
		var parts: Array[String] = []
		for axis in ["face", "beard", "eyes", "hair"]:
			var value := str(appearance.get(axis, ""))
			if value.is_empty():
				continue
			parts.append(_t("char.appearance.%s.%s" % [axis, value]))
		if not parts.is_empty():
			var line := _dim_label(I18n.fmt("char.appearance.sentence",
				{"parts": " · ".join(parts)}))
			line.name = "Appearance"
			tags.add_child(line)
			_place(line, "tags.appearance")


## Relation block: officer → loyalty + native role + current post (or idle);
## NPC captain → stance + familiarity (+ the familiarity tier name); player
## → the dim "-" line. Each variant's lines sit at the same two slots.
func _build_relations() -> void:
	var header := _section_header(_t("char.card.relations"),
		"RelationsHeader")
	_body.add_child(header)
	_place(header, "relations.header")
	var box := _group("Relations")
	_body.add_child(box)
	_place(box, "relations")
	var kind := str(_data.get("kind", ""))
	if kind == KIND_OFFICER:
		var loyalty := _label(_fmt("char.card.loyalty",
			{"amount": int(_data.get("loyalty", 0))}))
		loyalty.name = "Loyalty"
		box.add_child(loyalty)
		_place(loyalty, "relations.loyalty")
		var post_id := str(_data.get("post_id", ""))
		var post_line := _label("%s · %s" % [
			_t(str(_data.get("role_key", "char.none"))),
			I18n.t_key("officer.post.%s" % post_id)
			if not post_id.is_empty() else I18n.t_key("officer.post.idle"),
		])
		post_line.name = "Post"
		box.add_child(post_line)
		_place(post_line, "relations.post")
	elif kind == KIND_NPC:
		var relations := _label("%s: %+d · %s: %d" % [
			_t("char.card.relations"),
			int(_data.get("stance", 0)),
			I18n.t_key("dossier.familiarity"),
			int(_data.get("familiarity", 0)),
		])
		relations.name = "Stance"
		box.add_child(relations)
		_place(relations, "relations.stance")
		var tier := CaptainsLib.familiarity_tier(str(_data.get("person_id", "")))
		if tier > 0:
			var tier_label := _dim_label(I18n.t_key(
				"dossier.tier.%d" % TIER_NAME_NUMBERS[tier - 1]))
			tier_label.name = "FamiliarityTier"
			box.add_child(tier_label)
			_place(tier_label, "relations.tier")
	else:
		var empty := _dim_label("-")
		empty.name = "-"
		box.add_child(empty)
		_place(empty, "relations.empty")


## Career block: player → XP / level / next-level XP; NPC → wins / defeats /
## return day (a returning captain shows the `dossier.status.returning`
## state); officer → the dim "-" line. Each variant's lines sit at the same
## two slots.
func _build_career() -> void:
	var header := _section_header(_t("char.card.career"),
		"CareerHeader")
	_body.add_child(header)
	_place(header, "career.header")
	var box := _group("Career")
	_body.add_child(box)
	_place(box, "career")
	var kind := str(_data.get("kind", ""))
	if kind == KIND_PLAYER:
		var xp := _label(I18n.fmt("char.xp", {"xp": int(_data.get("xp", 0))}))
		xp.name = "Xp"
		box.add_child(xp)
		_place(xp, "career.xp")
		var next_xp := int(_data.get("next_xp", -1))
		if next_xp >= 0:
			var next_label := _dim_label(I18n.fmt("char.next_level",
				{"xp": next_xp}))
			next_label.name = "Next"
			box.add_child(next_label)
			_place(next_label, "career.next")
	elif kind == KIND_NPC:
		var record := _label("%s · %s" % [
			_fmt("char.card.wins", {"amount": int(_data.get("wins", 0))}),
			_fmt("char.card.defeats", {"amount": int(_data.get("defeats", 0))}),
		])
		record.name = "Record"
		box.add_child(record)
		_place(record, "career.record")
		if str(_data.get("status", "")) == CaptainsLib.STATUS_RETURNING:
			var returning := _dim_label("%s · %s" % [
				I18n.t_key("dossier.status.returning"),
				_fmt("char.card.return_day",
					{"day": int(_data.get("return_day", 0))}),
			])
			returning.name = "Returning"
			box.add_child(returning)
			_place(returning, "career.returning")
	else:
		var empty := _dim_label("-")
		empty.name = "-"
		box.add_child(empty)
		_place(empty, "career.empty")


## The §4.12.2 allocation footer: the pending-points line, the remaining
## count and the confirm/cancel pair. The per-attribute `Plus` steppers sit
## on the attribute rows; the draft is local to the card and commits through
## `Character.allocate` (no second confirm).
func _build_allocation() -> void:
	var box := _group("Allocation")
	_body.add_child(box)
	_place(box, "allocation")
	var pending := _label("%s: %d" % [I18n.t_key("char.points_pending"),
		CharacterLib.alloc_pending()])
	pending.name = "Pending"
	box.add_child(pending)
	_place(pending, "allocation.pending")
	var left := _label(I18n.fmt("creation.points.left", {"count": _left()}))
	left.name = "Left"
	box.add_child(left)
	_place(left, "allocation.left")
	var clamp_note := _dim_label("")
	clamp_note.name = "ClampNote"
	clamp_note.visible = false
	box.add_child(clamp_note)
	_place(clamp_note, "allocation.clamp_note")
	var buttons := _group("Buttons")
	box.add_child(buttons)
	_place(buttons, "allocation.buttons")
	var confirm := Button.new()
	confirm.name = "Confirm"
	confirm.text = I18n.t_key("ui.confirm")
	confirm.pressed.connect(_on_alloc_confirm)
	buttons.add_child(confirm)
	_place(confirm, "allocation.confirm")
	var cancel := Button.new()
	cancel.name = "Cancel"
	cancel.text = I18n.t_key("ui.cancel")
	cancel.pressed.connect(_on_alloc_cancel)
	buttons.add_child(cancel)
	_place(cancel, "allocation.cancel")


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
		var row := _attribute_row(str(key))
		if row == null:
			continue
		var key_name := str(key)
		var base := int(attributes.get(key_name, CharacterLib.BASE_ATTRIBUTE))
		var delta := int(_draft.get(key_name, 0))
		var value_label := row.get_node("Value") as Label
		value_label.text = str(base + delta) if delta == 0 \
			else "%d %+d" % [base + delta, delta]
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

## One plain-Control group node (the deleted containers' replacement — the
## §4.8.9 group parents are plain Controls at their data rects).
func _group(node_name: String) -> Control:
	var group := Control.new()
	group.name = node_name
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return group


## The attribute row node, wherever the layout puts it (the flat card keeps
## the §4.12 section seam: `StatColumns/AttributeColumn/Attributes/Attr_<key>`).
## Null when the card has no attribute block (the officers detail page).
func _attribute_row(key: String) -> Node:
	for path in ["StatColumns/AttributeColumn/Attributes/Attr_%s" % key,
			"Attributes/Attr_%s" % key]:
		var row := _body.get_node_or_null(path)
		if row != null:
			return row
	return null

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


## The hover explanation for a stat id (`char.attr.<key>.desc` /
## `skill.<key>.desc`, amended 2026-11-03). Empty when the key is absent, so a
## missing string degrades to "no tooltip" rather than to a raw "<key>".
static func _desc(key: String) -> String:
	if not DataLoader.ui_strings.has(key):
		return ""
	return I18n.t_key(key)


func _tier_badge(tier: int) -> Control:
	# The fleet picker's badge palette (1 grey / 2 amber / 3 red — §4.8), as
	# a placeholder color block (W4-D sweep: no per-screen stylebox).
	var badge := ColorRect.new()
	badge.name = "TierBadge"
	badge.color = PaletteLib.PANEL_LINE if tier <= 1 \
		else (PaletteLib.WARN if tier == 2 else PaletteLib.BAD)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = str(tier)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.add_child(label)
	return badge


## One value bar: the §4.9 kit atom (W4-D sweep — the kit owns the trough,
## border and GOOD/WARN/BAD tier fill; `tier` ∈ good/warn/bad). `tip` is the
## owning row's tooltip: the bar is `MOUSE_FILTER_IGNORE` and carries the
## same text (a ProgressBar defaults to `MOUSE_FILTER_STOP` and swallowed
## the whole row's hover, so the row's tooltip only appeared over the one-
## word label).
func _bar(value: int, max_value: int, tier: String, bar_name: String,
		tip: String = "") -> Control:
	var bar := UiKitLib.value_bar(value, max_value, tier)
	bar.name = bar_name
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.tooltip_text = tip
	return bar


func _section_header(text: String, header_name: String) -> Label:
	var header := _label(text)
	header.name = header_name
	return header


## §4.9 Label row: the theme renders Labels in TEXT — the plain label sets
## nothing; secondary text reads through the `Dim` variation.
func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _dim_label(text: String) -> Label:
	var label := _label(text)
	label.theme_type_variation = "Dim"
	return label


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
