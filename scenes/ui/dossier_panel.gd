extends Control
## The dossier panel (docs/80-UI-UX.md §4.11.3) — the card-external
## information layer, opened from any captain entry: the full §4.12 card
## **plus the career log**. Read-only.
##
## Familiarity gates ONLY the career log (locked): tier 3 = the last-seen
## fleet composition, tier 6 = home port + sighting history, tier 10 = the
## full lane picture incl. month variants (`Captains.FAMILIARITY_TIERS`,
## `80-*` §4.11.3). Below a tier its section renders locked with
## `dossier.locked.tier`. Card numbers are never gated (identify = full
## reveal, §4.12.1). Stance ≥ +2 adds the captain's current tier + status
## (在航 / 归队中) to the header.
##
## Entry: [method open_for] — the static seam any captain surface can call
## (the W5-C palace bounty seam still renders its toast placeholder; W7 /
## master may re-wire it here — noted in the W6-A report). Opening marks the
## captain's `dossier_seen` flag through `Captains.mark_dossier_seen`.
##
## The career log reads the same live state the rest of the UI reads: the
## captain's fleet from `GameState.npc_fleets` (composition, arrival day,
## lane ids), the canon card's `home_port`, and the built route artifact's
## month variants via `DataLoader.get_route_lane`. A captain with no live
## fleet (gone ashore / returning) renders "-" for the fleet-sourced rows.
##
## Owns all input while open (§6); Esc closes; joins the `modal_overlay`
## group (docs/90-* §11).
##
## Portrait slot (Phase-10 decision 10, W4-D): the dossier's portrait is the
## embedded §4.12 card's Identity slot — the composer bust (override file
## wins) rendered by `character_card.gd` above the career log. This panel
## styles nothing itself (§4.9 no-per-screen-styling rule; labels are theme
## TEXT / the `Dim` variation).

const PaletteLib := preload("res://scripts/palette.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const CardLib := preload("res://scenes/ui/character_card.gd")
## The career log's fleet-sourced reads (composition hulls, arrival day).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")

const SCENE_PATH := "res://scenes/ui/dossier_panel.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## The §4.11.3 stance threshold that adds the tier + status to the header.
const HEADER_STANCE_AT := 2

## The career log's three sections, in tier order: `{key, gate, threshold}` —
## `gate` is the familiarity tier (`Captains.familiarity_tier`) that unlocks
## the section, `threshold` the familiarity number the `dossier.locked.tier`
## reason names (the `Captains.FAMILIARITY_TIERS` values 3 / 6 / 10).
const LOG_SECTIONS: Array = [
	{"key": "dossier.log.composition", "gate": 1, "threshold": 3},
	{"key": "dossier.log.home_port", "gate": 2, "threshold": 6},
	{"key": "dossier.log.lanes", "gate": 3, "threshold": 10},
]

var _captain_id: String = ""
var _open := false

## The card rendered inside the panel (the card-identity pin reads its
## `rendered_data()` through [method card_widget]).
var _card: Control = null

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _header: Label = $Center/Panel/Margin/Body/Header
@onready var _content: VBoxContainer = $Center/Panel/Margin/Body/Scroll/Content
@onready var _close_button: Button = $Center/Panel/Margin/Body/Footer/Close


## Opens a dossier for `captain_id` under `host` (default: the current
## scene), marks it seen and returns the panel. An unknown id is refused.
static func open_for(captain_id: String, host: Node = null) -> Control:
	if captain_id.is_empty() or CaptainsLib.captain(captain_id).is_empty():
		return null
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("DossierPanel.open_for: missing %s" % SCENE_PATH)
		return null
	var panel: Control = scene.instantiate()
	var parent := host
	if parent == null:
		var tree := Engine.get_main_loop() as SceneTree
		parent = tree.current_scene if tree != null \
			and tree.current_scene != null else tree.root
	if parent is Control:
		parent.add_child(panel)
	else:
		var layer := parent.get_node_or_null("DossierLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "DossierLayer"
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(panel)
	panel.call("setup", captain_id)
	return panel


## Opens on `captain_id`: marks the §4.11.3 `dossier_seen` flag, renders the
## card + career log from live state.
func setup(captain_id: String) -> void:
	_captain_id = captain_id
	CaptainsLib.mark_dossier_seen(captain_id)
	_open = true
	visible = true
	add_to_group(MODAL_GROUP)
	_refresh()
	_close_button.grab_focus()


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	remove_from_group(MODAL_GROUP)


func is_open() -> bool:
	return _open


func captain_id() -> String:
	return _captain_id


## The embedded §4.12 card widget (the card-identity pin's read seam).
func card_widget() -> Control:
	return _card


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	get_viewport().set_input_as_handled()


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 (W4-D sweep): the PanelContainer chrome + Label colors are the
	# theme's; the header reads through the `Dim` variation. Nothing here
	# is styled per-screen any more.
	_header.theme_type_variation = "Dim"
	_close_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_close_button.pressed.connect(close)
	EventBus.locale_changed.connect(_on_locale_changed)


# --- Rendering --------------------------------------------------------------

func _refresh() -> void:
	var canon := CaptainsLib.captain(_captain_id)
	var name := I18n.t(canon.get("name", {}))
	_title.text = I18n.fmt("dossier.title", {"name": name})
	_header.text = " ".join(_header_parts(canon))
	_clear(_content)

	# The full §4.12 card (identify = full reveal — no gating here).
	var card_scene: PackedScene = load(CardLib.SCENE_PATH)
	_card = card_scene.instantiate()
	_card.name = "Card"
	_content.add_child(_card)
	_card.setup_person(CardLib.KIND_NPC, CardLib.card_data(
		CardLib.KIND_NPC, _captain_id))

	# The familiarity line (the gate's number, always visible).
	var familiarity := CaptainsLib.familiarity(_captain_id)
	var tier := CaptainsLib.familiarity_tier(_captain_id)
	var familiarity_line := _label("%s: %d" % [
		I18n.t_key("dossier.familiarity"), familiarity])
	familiarity_line.name = "Familiarity"
	_content.add_child(familiarity_line)
	if tier > 0:
		var tier_name := _dim_label(I18n.t_key("dossier.tier.%d"
			% CardLib.TIER_NAME_NUMBERS[tier - 1]))
		tier_name.name = "TierName"
		_content.add_child(tier_name)

	# The career log, gated section by section (§4.11.3, locked).
	for section in LOG_SECTIONS:
		_content.add_child(_log_section(section, tier))


## The header's second line: role · tier · level, and — stance ≥ +2 — the
## current tier + 在航/归队中 status (§4.11.3, locked).
func _header_parts(canon: Dictionary) -> Array[String]:
	var parts: Array[String] = []
	var role := str(canon.get("role", ""))
	if not role.is_empty():
		parts.append(I18n.t_key("captain.role.%s" % role))
	parts.append("%s %d" % [I18n.t_key("captain.table.tier"),
		int(CaptainsLib.state(_captain_id).get("tier_now",
			int(canon.get("tier", 1))))])
	parts.append(I18n.fmt("char.level",
		{"level": int(canon.get("level", 1))}))
	var stance := CaptainsLib.stance(_captain_id)
	if stance >= HEADER_STANCE_AT:
		parts.append(I18n.fmt("dossier.header.tier", {"tier": stance}))
		var status := str(CaptainsLib.state(_captain_id).get("status",
			CaptainsLib.STATUS_ACTIVE))
		parts.append(I18n.t_key("dossier.status.at_sea")
			if status == CaptainsLib.STATUS_ACTIVE
			else I18n.t_key("dossier.status.returning"))
	return parts


## One career-log row: unlocked → the section label + its data line;
## locked → the grayed label + the `dossier.locked.tier` reason.
func _log_section(section: Dictionary, tier: int) -> Control:
	var row := VBoxContainer.new()
	row.name = "Log_%d" % int(section["gate"])
	row.set("theme_override_constants/separation", 2)
	var unlocked: bool = tier >= int(section["gate"])
	var label := _label(I18n.t_key(str(section["key"]))) if unlocked \
		else _dim_label(I18n.t_key(str(section["key"])))
	label.name = "Label"
	row.add_child(label)
	if unlocked:
		var data_line := _label(_log_data(str(section["key"])))
		data_line.name = "Data"
		row.add_child(data_line)
	else:
		var locked := _dim_label(I18n.fmt("dossier.locked.tier",
			{"tier": int(section["threshold"])}))
		locked.name = "Locked"
		row.add_child(locked)
	return row


## The unlocked section's data line, composed from live state (never a new
## mechanic — every value is a read of an existing record).
func _log_data(section_key: String) -> String:
	match section_key:
		"dossier.log.composition":
			# Tier 3: the last-seen fleet composition — the live fleet's
			# seeded ships (count + hulls), or "-" when none is at sea.
			var fleet := _fleet_of_captain()
			if fleet.is_empty():
				return I18n.t_key("char.none")
			var ships: Array = fleet.get("ships", [])
			if (ships as Array).is_empty():
				ships = NpcFleetsLib.compose_fleet_ships(fleet,
					int(GameState.day))
			var hulls: Array[String] = []
			for ship in ships:
				hulls.append(str((ship as Dictionary).get("ship_type_id", "")))
			return "%s ×%d · %s" % [I18n.t_key("captain.role.%s"
				% str(fleet.get("role", ""))), (ships as Array).size(),
				", ".join(hulls)]
		"dossier.log.home_port":
			# Tier 6: the canon home port + the sighting history (the
			# familiarity count and the live fleet's arrival day).
			var canon := CaptainsLib.captain(_captain_id)
			var home := str(canon.get("home_port", ""))
			var home_name := I18n.t(DataLoader.get_port(home).get("name", {})) \
				if not home.is_empty() else I18n.t_key("char.none")
			var last_seen := "-"
			var fleet := _fleet_of_captain()
			if not fleet.is_empty():
				last_seen = str(NpcIntelLib.arrival_day_of(fleet))
			return "%s · %s %s" % [home_name,
				I18n.t_key("captain.table.last_seen"), last_seen]
		"dossier.log.lanes":
			# Tier 10: the full lane picture incl. month variants — the live
			# fleet's lane ids + the built artifact's `variants` months.
			var fleet := _fleet_of_captain()
			if fleet.is_empty():
				return I18n.t_key("char.none")
			var lanes: Array = (fleet.get("route", {}) as Dictionary) \
				.get("lanes", [])
			if (lanes as Array).is_empty():
				return I18n.t_key("char.none")
			var parts: Array[String] = []
			for lane_id in lanes:
				var lane := str(lane_id)
				var text := lane
				var variants: Array = DataLoader.get_route_lane(lane) \
					.get("variants", [])
				if not (variants as Array).is_empty():
					var names: Array[String] = []
					for variant in variants:
						names.append("%s(%s)" % [str(variant.get("id", "")),
							str(variant.get("months", []))])
					text += " · %s" % ", ".join(names)
				parts.append(text)
			return " · ".join(parts)
	return I18n.t_key("char.none")


## The live fleet the captain sails on ({} when gone ashore / returning).
func _fleet_of_captain() -> Dictionary:
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary and str(fleet.get("captain_id", "")) == _captain_id:
			return fleet
	return {}


## §4.9 Label row (W4-D sweep): the theme renders Labels in TEXT — the plain
## label sets nothing; secondary text reads through the `Dim` variation.
func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = float(PaletteLib.DIALOG_W
		- 2 * PaletteLib.MARGIN)
	return label


func _dim_label(text: String) -> Label:
	var label := _label(text)
	label.theme_type_variation = "Dim"
	return label


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


func _on_locale_changed(_locale: String) -> void:
	if _open:
		_refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
