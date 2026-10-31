extends Control
## Guild (S12) — quest offers and discovery reports
## (docs/70-* §4.2, §4.4, §4.9.3; docs/10-* §4.8; docs/30-* §4.1, §4.7;
## docs/80-* §4.1, §4.2, §4.7.3).
##
## Two stacked sections, exactly the §4.7 wireframe:
##   * **Offers** — one row per generated offer (0–3): type tag, composed
##     objective line, days remaining, gold reward, `Accept` / `Hint`.
##   * **Reports** — one row per found-but-unreported discovery with its
##     `report_reward_gold`/`fame` and a `Report` button.
##
## All rules live in `scripts/quests/quest_gen.gd` and
## `scripts/world/discovery.gd`; this screen only renders state and forwards
## clicks. Offers are **derived** from `(port, day // 7)`, so opening the guild
## twice on the same day shows the same list without any saved state.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## Type tag → `ui_strings` key (`80-*` §4.7.4).
const TYPE_KEYS := {
	"delivery": "quest.type.delivery",
	"bounty": "quest.type.bounty",
	"exploration": "quest.type.exploration",
	"royal": "quest.type.royal",
}

## Routing switch for headless tests (the `port_screen.route_to_world`
## convention): with `false` the screen states and emits without swapping.
var route_to_port: bool = true
## Emitted right before the S12 → S4 route.
signal back_requested
## Emitted after a successful accept / report / hint purchase.
signal quest_accepted(instance: Dictionary)
signal discovery_reported(block: Dictionary)

@onready var _background: ColorRect = $Background
@onready var _hud: Control = get_node_or_null("HUD")
@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _gold: Label = $Layout/VBox/Header/Gold
@onready var _fame: Label = $Layout/VBox/Header/Fame
@onready var _back_button: Button = $Layout/VBox/Header/Back
@onready var _offers_heading: Label = $Layout/VBox/Offers/Heading
@onready var _offers_hint: Label = $Layout/VBox/Offers/Refresh
@onready var _announce: Label = $Layout/VBox/Offers/Announce
@onready var _offers_rows: VBoxContainer = $Layout/VBox/Offers/Scroll/Rows
@onready var _offers_empty: Label = $Layout/VBox/Offers/Empty
@onready var _reports_heading: Label = $Layout/VBox/Reports/Heading
@onready var _reports_rows: VBoxContainer = $Layout/VBox/Reports/Scroll/Rows
@onready var _reports_empty: Label = $Layout/VBox/Reports/Empty
@onready var _esc_hint: Label = $Layout/VBox/Footer/EscHint
@onready var _toast: Label = $Layout/VBox/Toast
@onready var _toast_timer: Timer = $ToastTimer

## Port id read at open time ("" when launched standalone from the editor).
var _port_id: String = ""
## The offer rows currently rendered, in order (tests read them).
var _offers: Array = []
## The discovery ids currently listed for report.
var _reports: Array = []


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_title, _gold, _fame, _offers_heading, _offers_hint,
			_announce, _reports_heading, _esc_hint, _toast]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_fame.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_offers_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_announce.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_esc_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_title.add_theme_font_size_override("font_size", 32)
	_toast.visible = false
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(func() -> void: _toast.visible = false)
	# S12 keeps the §4.5 bars but not the sea viewport (docs/80-* §4.5: port
	# screens replace it with their menu). Without this the 256×192 chart and
	# its weather/title captions draw over the guild list.
	if _hud != null:
		_hud.set_minimap_visible(false)
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)

	_port_id = _read_current_port()
	refresh()
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.quests_changed.connect(refresh)
	EventBus.fame_changed.connect(_on_fame_changed)
	EventBus.discovery_reported.connect(_on_discovery_reported)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		go_back()
		return


# --- Public API (tests + hosts) ------------------------------------------

func port_id() -> String:
	return _port_id


## The `instance_id`s of the offers currently listed, in display order.
func offer_rows() -> Array:
	var out: Array = []
	for offer in _offers:
		out.append(str((offer as Dictionary).get("instance_id", "")))
	return out


## The discovery ids currently listed for report, in display order.
func report_rows() -> Array:
	return _reports.duplicate()


## Every player-facing line this screen currently shows (the "no raw `<key>`"
## check walks it).
func all_text() -> Array:
	var out: Array = [
		_title.text, _gold.text, _fame.text, _back_button.text,
		_offers_heading.text, _offers_hint.text, _announce.text,
		_reports_heading.text, _esc_hint.text,
	]
	for container in [_offers_rows, _reports_rows]:
		for child in _walk_labels(container):
			out.append((child as Label).text)
	return out


## Accepts the offer at `index` (§4.9.3). Returns the stored instance (`{}` on
## refusal). The refusal reason is toasted so the click is never silent.
func accept_offer(index: int) -> Dictionary:
	if index < 0 or index >= _offers.size():
		return {}
	var offer: Dictionary = _offers[index]
	var reason := QuestGenLib.accept_block_reason(offer)
	if not reason.is_empty():
		_show_toast(reason)
		return {}
	var instance: Dictionary = QuestGenLib.accept(offer, _port_id, GameState.day)
	if instance.is_empty():
		_show_toast("quest.no_hold")
		return {}
	_show_toast("quest.accepted")
	quest_accepted.emit(instance)
	refresh()
	return instance


## Reports a discovery (§4.4), completing any exploration/royal quest that
## names it. Returns the report block (`{}` on refusal).
func report_discovery(discovery_id: String) -> Dictionary:
	var block: Dictionary = DiscoveryLib.report(discovery_id)
	if block.is_empty():
		return {}
	# Exploration quests complete *in addition to* the report reward (§4.4).
	QuestGenLib.complete_exploration_quests(discovery_id)
	for quest in QuestGenLib.active_quests():
		if str(quest.get("giver", "")) != "palace":
			continue
		if str((quest.get("requirements", {}) as Dictionary).get("kind", "")) \
				!= PalaceEngineLib.KIND_CHART:
			continue
		PalaceEngineLib.on_discovery_reported(quest)
	_show_toast("guild.report.action")
	discovery_reported.emit(block)
	refresh()
	return block


## Buys the hint of the exploration offer at `index` (free: exploration offers
## already carry the hint, §4.4), or of `discovery_id` at the Rumor price.
func buy_hint(discovery_id: String) -> Dictionary:
	var entry := DiscoveryLib.buy_hint(discovery_id)
	if entry.is_empty():
		_show_toast("tavern.rumor.no_gold" if not DiscoveryLib.is_hinted(discovery_id)
			else "tavern.rumor.bought")
		return {}
	_show_toast("tavern.rumor.buy")
	refresh()
	return entry


## Back edge S12 → S4 (docs/80-* §4.2). Leaves game state untouched.
func go_back() -> bool:
	back_requested.emit()
	if route_to_port:
		GameState.change_scene(PORT_SCENE)
	return true


# --- Rendering ------------------------------------------------------------

func refresh() -> void:
	_port_id = _read_current_port()
	var port: Dictionary = DataLoader.get_port(_port_id) if not _port_id.is_empty() else {}
	_title.text = I18n.fmt("guild.title", {
		"port": I18n.t(port.get("name", {})) if not port.is_empty() else "-",
	})
	_gold.text = I18n.fmt("ui.gold_amount", {
		"gold": HudLib.format_thousands(GameState.gold),
	})
	_fame.text = I18n.fmt("ending.fame", {"fame": GameState.fame})
	_back_button.text = I18n.t_key("ui.back")
	_offers_heading.text = I18n.t_key("guild.offers")
	_announce.text = _tournament_announcement()
	_offers_hint.text = I18n.fmt("guild.offers_refresh", {
		"day": QuestGenLib.next_refresh_day(GameState.day),
	})
	_reports_heading.text = I18n.t_key("guild.report.section")
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	_bind_offers()
	_bind_reports()


## The monthly tournament announcement (§4.6: "announced via tavern rumor and
## the guild"), so the guild is a second place to learn where the next bracket
## is. Empty when there is no run to read a day from.
func _tournament_announcement() -> String:
	if _port_id.is_empty():
		return ""
	var status := TournamentLib.status(_port_id, GameState.day)
	var text := I18n.fmt("tournament.status", {
		"port": I18n.t(DataLoader.get_port(str(status.get("host", "")))
			.get("name", {})),
		"first": int(status.get("window_first", 1)),
		"last": int(status.get("window_last", 5)),
	})
	var blocked := str(status.get("blocked", ""))
	if blocked in ["tournament.not_host", "tournament.closed"]:
		text += " — %s" % I18n.t_key(blocked)
	return text


func _bind_offers() -> void:
	_clear(_offers_rows)
	_offers = []
	if _port_id.is_empty():
		_offers_empty.visible = true
		_offers_empty.text = I18n.t_key("ui.not_available")
		return
	_offers = QuestGenLib.available_offers(_port_id, GameState.day)
	_offers_empty.visible = _offers.is_empty()
	# The empty line states the real reason: no free slot, else "all taken".
	_offers_empty.text = I18n.t_key(
		"quest.slots_full"
		if QuestGenLib.active_count() >= QuestGenLib.max_active_quests()
		else "ui.empty")
	if _offers.is_empty():
		return
	for index in _offers.size():
		_offers_rows.add_child(_build_offer_row(_offers[index], index))


func _build_offer_row(offer: Dictionary, index: int) -> Control:
	var row := VBoxContainer.new()
	row.name = "Offer_%d" % index
	row.add_theme_constant_override("separation", 4)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", PaletteLib.MARGIN)
	var tag := _make_label(I18n.t_key(str(TYPE_KEYS.get(
		str(offer.get("type", "")), "ui.not_available"))), "Tag")
	tag.custom_minimum_size.x = 96
	tag.add_theme_color_override("font_color", PaletteLib.ACCENT)
	top.add_child(tag)
	var line := _make_label(_objective_text(offer), "Objective")
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(line)
	var days := _make_label(I18n.fmt("quest.days_left", {
		"days": int(offer.get("expiry_days", 0)),
	}), "Days")
	days.custom_minimum_size.x = 120
	days.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	top.add_child(days)
	row.add_child(top)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", PaletteLib.MARGIN)
	var reward := _make_label(_reward_text(offer), "Reward")
	reward.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reward.add_theme_color_override("font_color", PaletteLib.GOOD)
	bottom.add_child(reward)
	var reason := QuestGenLib.accept_block_reason(offer)
	var accept := Button.new()
	accept.name = "Accept"
	accept.text = I18n.t_key("quest.accept")
	accept.custom_minimum_size = Vector2(140, PaletteLib.BUTTON_H)
	accept.disabled = not reason.is_empty()
	if not reason.is_empty():
		accept.tooltip_text = I18n.t_key(reason)
	accept.pressed.connect(func() -> void: accept_offer(index))
	bottom.add_child(accept)
	if str(offer.get("type", "")) == "exploration":
		var hint := Button.new()
		hint.name = "Hint"
		hint.text = I18n.t_key("quest.hint")
		hint.custom_minimum_size = Vector2(140, PaletteLib.BUTTON_H)
		hint.disabled = true
		hint.tooltip_text = I18n.t(_hint_text(offer))
		bottom.add_child(hint)
	row.add_child(bottom)
	return row


## The composed objective line (§4.9.3 names; numbers by the UI, `10-*` §3.3).
func _objective_text(offer: Dictionary) -> String:
	if str(offer.get("type", "")) == "exploration":
		return "%s — %s" % [
			QuestGenLib.objective_text(offer),
			I18n.t(_hint_text(offer)),
		]
	return QuestGenLib.objective_text(offer)


func _reward_text(offer: Dictionary) -> String:
	var rewards: Dictionary = offer.get("rewards", {})
	var gold := int(rewards.get("gold", 0))
	var fame := int(rewards.get("fame", 0))
	return "%s · %s" % [
		I18n.fmt("ui.gold_amount", {"gold": HudLib.format_thousands(gold)}),
		I18n.fmt("ending.fame", {"fame": fame}),
	]


func _hint_text(offer: Dictionary) -> Dictionary:
	var discovery_id := str((offer.get("requirements", {}) as Dictionary)
		.get("discovery_id", ""))
	if discovery_id.is_empty():
		return {}
	return DiscoveryLib.hint_text(discovery_id)


func _bind_reports() -> void:
	_clear(_reports_rows)
	_reports = DiscoveryLib.unreported()
	_reports_empty.visible = _reports.is_empty()
	_reports_empty.text = I18n.t_key("guild.report.none")
	for discovery_id in _reports:
		_reports_rows.add_child(_build_report_row(str(discovery_id)))


func _build_report_row(discovery_id: String) -> Control:
	var discovery: Dictionary = DataLoader.get_discovery(discovery_id)
	var row := HBoxContainer.new()
	row.name = "Report_%s" % discovery_id
	row.add_theme_constant_override("separation", PaletteLib.MARGIN)
	var name_label := _make_label(I18n.t(discovery.get("name", {})), "Name")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var reward := _make_label(I18n.fmt("guild.report_reward", {
		"gold": HudLib.format_thousands(int(discovery.get("report_reward_gold", 0))),
		"fame": int(discovery.get("fame", 0)),
	}), "Reward")
	reward.custom_minimum_size.x = 240
	reward.add_theme_color_override("font_color", PaletteLib.GOOD)
	row.add_child(reward)
	var button := Button.new()
	button.name = "Report"
	button.text = I18n.t_key("guild.report.action")
	button.custom_minimum_size = Vector2(140, PaletteLib.BUTTON_H)
	button.pressed.connect(func() -> void: report_discovery(discovery_id))
	row.add_child(button)
	return row


# --- Helpers --------------------------------------------------------------

func _read_current_port() -> String:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return value
	return ""


func _make_label(text: String, node_name: String = "") -> Label:
	var label := Label.new()
	label.text = text
	if not node_name.is_empty():
		label.name = node_name
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	return label


func _walk_labels(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Label:
			out.append(child)
		elif child is Node:
			out.append_array(_walk_labels(child))
	return out


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _show_toast(key: String, values: Dictionary = {}) -> void:
	if not DataLoader.ui_strings.has(key):
		return
	_toast.text = I18n.fmt(key, values)
	_toast.add_theme_color_override("font_color", PaletteLib.GOOD)
	_toast.visible = true
	_toast_timer.start(2.5)


func _on_locale_changed(_locale: String) -> void:
	refresh()


func _on_gold_changed(_new_gold: int) -> void:
	refresh()


func _on_fame_changed(_new_fame: int) -> void:
	refresh()


func _on_discovery_reported(_discovery_id: String) -> void:
	refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.quests_changed.is_connected(refresh):
		EventBus.quests_changed.disconnect(refresh)
	if EventBus.fame_changed.is_connected(_on_fame_changed):
		EventBus.fame_changed.disconnect(_on_fame_changed)
	if EventBus.discovery_reported.is_connected(_on_discovery_reported):
		EventBus.discovery_reported.disconnect(_on_discovery_reported)
