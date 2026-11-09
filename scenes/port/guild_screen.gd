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
##
## **Absolute tile layout (Phase 12 W2-A, docs/80-* §4.8.9; 10-* §4.23).** The
## node tree IS the element tree: header/offers/reports are plain Controls at
## their authored tile rects and every leaf hangs directly off its registered
## parent — the flow containers are deleted (the empty HBox footer and the
## unused toast label/timer with them). The two dynamic sections are list
## blocks: rows register `{"list": ...}` and take
## [method LayoutRegistry.list_rect] positions inside the section's scroll
## viewport (the ONLY surviving containers); a row's parts are
## absolutely-placed children of the row node.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-10 sweep (§4.9): styling retires to the shared theme/kit — buttons
## come from the kit atom, secondary text from the theme's `Dim` variation,
## and the private toast from the kit toast atom (§4.7.17 fades).
const UiKitLib := preload("res://scripts/ui_kit.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
## §4.1b port hours (added 2026-11-02): the guild counter's window guard and
## hour charges go through the one clock seam.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const GameOverHostLib := preload("res://scenes/ui_shared/game_over_host.gd")
## The Phase-12 absolute-tile layout registry (docs/80-* §4.8.9): the data
## file is the layout; the registration below feeds the capture fragment.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## This screen's id in the registry (LayoutRegistry.SCREENS).
const LAYOUT_SCREEN := "guild"
## Type tag → `ui_strings` key (`80-*` §4.7.4).
const TYPE_KEYS := {
	"delivery": "quest.type.delivery",
	"bounty": "quest.type.bounty",
	"exploration": "quest.type.exploration",
	"royal": "quest.type.royal",
}

## --- The authored tile table (parent-relative 32-px tiles; Phase 12) ---------
## One tile = `Palette.CHROME_TILE`. The screen root is the canvas; group
## parents carry their own rects and their children address the group's space.
const TILE := PaletteLib.CHROME_TILE
## The offers list block (content-node tiles): row *i* at `(0, i·row_h)` —
## a 3-tile row (the identity line over the reward/action line). The
## viewport is the scroll's rect in the offers group's space; the authored
## fallback block carries the same tiles, so the interim apply is idempotent.
const OFFERS_LIST := "offers"
const OFFERS_W := 58
const OFFERS_ROW_H := 3
## The reports list block: a 2-tile row (the 64-px Report button sets the
## pitch).
const REPORTS_LIST := "reports"
const REPORTS_W := 58
const REPORTS_ROW_H := 2
## Offer-row internals (row-local tiles): the identity line (tag · objective
## · days) over the action line (reward · Accept · Hint).
const OFFER_TAG_RECT := Rect2i(0, 0, 3, 1)
const OFFER_OBJECTIVE_RECT := Rect2i(3, 0, 51, 1)
const OFFER_DAYS_RECT := Rect2i(54, 0, 4, 1)
const OFFER_REWARD_RECT := Rect2i(0, 1, 49, 1)
const OFFER_ACCEPT_RECT := Rect2i(49, 1, 5, 2)
const OFFER_ACCEPT_NO_HINT_RECT := Rect2i(53, 1, 5, 2)
const OFFER_REWARD_NO_HINT_RECT := Rect2i(0, 1, 53, 1)
const OFFER_HINT_RECT := Rect2i(54, 1, 4, 2)
## Report-row internals (row-local tiles): name · reward · the Report verb.
const REPORT_NAME_RECT := Rect2i(0, 0, 45, 2)
const REPORT_REWARD_RECT := Rect2i(45, 0, 8, 2)
const REPORT_BUTTON_RECT := Rect2i(53, 0, 5, 2)

## Routing switch for headless tests (the `port_screen.route_to_world`
## convention): with `false` the screen states and emits without swapping.
var route_to_port: bool = true
## Emitted right before the S12 → S4 route.
signal back_requested
## Emitted after a successful accept / report / hint purchase.
signal quest_accepted(instance: Dictionary)
signal discovery_reported(block: Dictionary)

@onready var _background: Panel = $Background
@onready var _hud: Control = get_node_or_null("HUD")
@onready var _header: Control = $header
@onready var _title: Label = $header/Title
@onready var _gold: Label = $header/Gold
@onready var _fame: Label = $header/Fame
@onready var _back_button: Button = $header/Back
@onready var _offers: Control = $offers
@onready var _offers_heading: Label = $offers/Heading
@onready var _offers_hint: Label = $offers/Refresh
@onready var _announce: Label = $offers/Announce
@onready var _offers_scroll: ScrollContainer = $offers/Scroll
@onready var _offers_rows: Control = $offers/Scroll/Rows
@onready var _offers_empty: Label = $offers/Empty
@onready var _reports: Control = $reports
@onready var _reports_heading: Label = $reports/Heading
@onready var _reports_scroll: ScrollContainer = $reports/Scroll
@onready var _reports_rows: Control = $reports/Scroll/Rows
@onready var _reports_empty: Label = $reports/Empty

## Port id read at open time ("" when launched standalone from the editor).
var _port_id: String = ""
## The offer rows currently rendered, in order (tests read them).
var _offers_data: Array = []
## The discovery ids currently listed for report.
var _reports_data: Array = []
## Phase-11 (§4.8.9): per dynamic section, true once its first build has
## registered (see [_register_dynamic] for the first-build/rebuild split).
var _layout_built: Dictionary = {}


func _ready() -> void:
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): a run can die on any
	# ledger tick ashore — the game-over screen must rise over the guild too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the theme — TEXT is the theme's
	# Label default, secondary lines carry the `Dim` variation.
	_offers_hint.theme_type_variation = "Dim"
	# S12 keeps the §4.5 bars but not the sea viewport (docs/80-* §4.5: port
	# screens replace it with their menu). Without this the 256×192 chart and
	# its weather/title captions draw over the guild list.
	if _hud != null:
		_hud.set_minimap_visible(false)
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)

	# Phase 12 (§4.8.9): the authored tile rects — every static at its data
	# rect, the groups as plain Controls, before anything registers.
	_place_statics()

	_port_id = _read_current_port()
	_register_layout()
	refresh()
	# Phase-11 (§4.8.9): the build is registered — activate the screen (pins
	# the root, captures baselines, applies the committed table; the interim
	# `{}` file leaves the authored rects standing).
	RegistryLib.screen_active(LAYOUT_SCREEN, self)
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.quests_changed.connect(refresh)
	EventBus.fame_changed.connect(_on_fame_changed)
	EventBus.discovery_reported.connect(_on_discovery_reported)


## Phase 12 (§4.8.9): one authored rect = one `position`/`size` write, in
## the DIRECT parent's tile space (point anchors everywhere; nothing is
## stretched).
func _place(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(TILE)
	control.size = Vector2(rect.size) * float(TILE)


## The authored tile table — today's captured look, flattened to the grid
## (see the fragment this screen's capture emits: `data/layout_fragments/
## guild.json`).
func _place_statics() -> void:
	_place(_header, Rect2i(1, 1, 58, 2))
	_place(_title, Rect2i(0, 0, 48, 1))
	_place(_gold, Rect2i(49, 1, 2, 1))
	_place(_fame, Rect2i(52, 1, 2, 1))
	_place(_back_button, Rect2i(54, 0, 4, 2))
	_place(_offers, Rect2i(1, 3, 58, 21))
	_place(_offers_heading, Rect2i(0, 0, 58, 1))
	_place(_offers_hint, Rect2i(0, 1, 58, 1))
	_place(_announce, Rect2i(0, 2, 58, 1))
	_place(_offers_scroll, Rect2i(0, 3, 58, 18))
	_place(_offers_empty, Rect2i(0, 3, 58, 2))
	_place(_reports, Rect2i(1, 25, 58, 6))
	_place(_reports_heading, Rect2i(0, 0, 58, 1))
	_place(_reports_scroll, Rect2i(0, 1, 58, 4))
	_place(_reports_empty, Rect2i(0, 1, 58, 2))


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
	for offer in _offers_data:
		out.append(str((offer as Dictionary).get("instance_id", "")))
	return out


## The discovery ids currently listed for report, in display order.
func report_rows() -> Array:
	return _reports_data.duplicate()


## Every player-facing line this screen currently shows (the "no raw `<key>`"
## check walks it).
func all_text() -> Array:
	var out: Array = [
		_title.text, _gold.text, _fame.text, _back_button.text,
		_offers_heading.text, _offers_hint.text, _announce.text,
		_reports_heading.text,
	]
	for container in [_offers_rows, _reports_rows]:
		for child in _walk_labels(container):
			out.append((child as Label).text)
	return out


## Accepts the offer at `index` (§4.9.3). Returns the stored instance (`{}` on
## refusal). The refusal reason is toasted so the click is never silent.
## §4.1b (added 2026-11-02): the counter must be open and the signing takes
## one hour.
func accept_offer(index: int) -> Dictionary:
	if index < 0 or index >= _offers_data.size():
		return {}
	var offer: Dictionary = _offers_data[index]
	var reason := QuestGenLib.accept_block_reason(offer)
	if not reason.is_empty():
		_show_toast(reason)
		return {}
	if not SailingSimLib.facility_open(_port_id, "guild"):
		return {}
	var instance: Dictionary = QuestGenLib.accept(offer, _port_id, GameState.day)
	if instance.is_empty():
		_show_toast("quest.no_hold")
		return {}
	_show_toast("quest.accepted")
	SailingSimLib.advance_port_hours(1)
	quest_accepted.emit(instance)
	refresh()
	return instance


## Reports a discovery (§4.4), completing any exploration/royal quest that
## names it. Returns the report block (`{}` on refusal). §4.1b (added
## 2026-11-02): the counter must be open and the report takes one hour.
func report_discovery(discovery_id: String) -> Dictionary:
	if not SailingSimLib.facility_open(_port_id, "guild"):
		return {}
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
	SailingSimLib.advance_port_hours(1)
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


## Row *i*'s rect for a list block — px in the section's content-node space:
## the data block when managed, the same tiles authored otherwise.
func _list_row_rect(list_id: String, index: int, w: int, row_h: int) -> Rect2:
	var rect := RegistryLib.list_rect(LAYOUT_SCREEN, list_id, index)
	if rect != Rect2():
		return rect
	return Rect2(
		Vector2(0, index * row_h) * float(TILE),
		Vector2(w, row_h) * float(TILE))


func _bind_offers() -> void:
	_clear(_offers_rows)
	_offers_data = []
	if _port_id.is_empty():
		_offers_empty.visible = true
		_offers_empty.text = I18n.t_key("ui.not_available")
		_offers_rows.custom_minimum_size = Vector2(
			OFFERS_W * float(TILE), 0)
		return
	_offers_data = QuestGenLib.available_offers(_port_id, GameState.day)
	_offers_empty.visible = _offers_data.is_empty()
	# The empty line states the real reason: no free slot, else "all taken".
	_offers_empty.text = I18n.t_key(
		"quest.slots_full"
		if QuestGenLib.active_count() >= QuestGenLib.max_active_quests()
		else "ui.empty")
	var entries: Array = []
	for index in _offers_data.size():
		_build_offer_row(_offers_data[index], index, entries)	# The scroll's stacked extent: the plain content Control sized to the
	# rows' total pitch (viewport math, not flow).
	_offers_rows.custom_minimum_size = Vector2(
		OFFERS_W * float(TILE),
		_offers_data.size() * OFFERS_ROW_H * float(TILE))
	_register_dynamic("offers", entries)


func _build_offer_row(offer: Dictionary, index: int, entries: Array) -> void:
	var row_id := str(offer.get("instance_id", ""))
	if row_id.is_empty():
		row_id = "%d" % index
	var row := Control.new()
	row.name = "Offer_%d" % index
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offers_rows.add_child(row)
	var rect := _list_row_rect(OFFERS_LIST, index, OFFERS_W, OFFERS_ROW_H)
	row.position = rect.position
	row.size = rect.size
	entries.append({
		"control": row, "id": "offers.rows.%s" % row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": OFFERS_LIST},
	})

	# The identity line: type tag · objective · days — absolutely-placed
	# children of the row (no per-row flow containers, §4.8.9).
	var tag := _make_label(I18n.t_key(str(TYPE_KEYS.get(
		str(offer.get("type", "")), "ui.not_available"))), "Tag")
	# The §4.8 ACCENT tag tint rides the theme's `Accent` variation.
	tag.theme_type_variation = "Accent"
	row.add_child(tag)
	_place(tag, OFFER_TAG_RECT)
	var line := _make_label(_objective_text(offer), "Objective")
	row.add_child(line)
	_place(line, OFFER_OBJECTIVE_RECT)
	var days := _make_label(I18n.fmt("quest.days_left", {
		"days": int(offer.get("expiry_days", 0)),
	}), "Days")
	days.theme_type_variation = "Dim"
	row.add_child(days)
	_place(days, OFFER_DAYS_RECT)

	# The action line: reward · Accept, plus the Hint verb for exploration
	# offers — the accept/hint pair shifts left when the hint is present.
	var has_hint := str(offer.get("type", "")) == "exploration"
	var reward := _make_label(_reward_text(offer), "Reward")
	# The §4.8 GOOD reward tint rides the theme's `Good` variation.
	reward.theme_type_variation = "Good"
	row.add_child(reward)
	_place(reward, OFFER_REWARD_RECT if has_hint \
		else OFFER_REWARD_NO_HINT_RECT)
	var reason := QuestGenLib.accept_block_reason(offer)
	var accept := UiKitLib.button("quest.accept", "primary")
	accept.name = "Accept"
	accept.disabled = not reason.is_empty()
	if not reason.is_empty():
		accept.tooltip_text = I18n.t_key(reason)
	accept.pressed.connect(func() -> void: accept_offer(index))
	row.add_child(accept)
	_place(accept, OFFER_ACCEPT_RECT if has_hint \
		else OFFER_ACCEPT_NO_HINT_RECT)
	if has_hint:
		var hint := UiKitLib.button("quest.hint")
		hint.name = "Hint"
		hint.disabled = true
		hint.tooltip_text = I18n.t(_hint_text(offer))
		row.add_child(hint)
		_place(hint, OFFER_HINT_RECT)


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
	_reports_data = DiscoveryLib.unreported()
	_reports_empty.visible = _reports_data.is_empty()
	_reports_empty.text = I18n.t_key("guild.report.none")
	var entries: Array = []
	var index := 0
	for discovery_id in _reports_data:
		_build_report_row(str(discovery_id), index, entries)
		index += 1
	_reports_rows.custom_minimum_size = Vector2(
		REPORTS_W * float(TILE),
		_reports_data.size() * REPORTS_ROW_H * float(TILE))
	_register_dynamic("reports", entries)


func _build_report_row(discovery_id: String, index: int,
		entries: Array) -> void:
	var discovery: Dictionary = DataLoader.get_discovery(discovery_id)
	var row := Control.new()
	row.name = "Report_%s" % discovery_id
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reports_rows.add_child(row)
	var rect := _list_row_rect(REPORTS_LIST, index, REPORTS_W, REPORTS_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var row_id := "reports.rows.%s" % discovery_id
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": REPORTS_LIST},
	})
	var name_label := _make_label(I18n.t(discovery.get("name", {})), "Name")
	row.add_child(name_label)
	_place(name_label, REPORT_NAME_RECT)
	var reward := _make_label(I18n.fmt("guild.report_reward", {
		"gold": HudLib.format_thousands(int(discovery.get("report_reward_gold", 0))),
		"fame": int(discovery.get("fame", 0)),
	}), "Reward")
	# The §4.8 GOOD reward tint rides the theme's `Good` variation.
	reward.theme_type_variation = "Good"
	row.add_child(reward)
	_place(reward, REPORT_REWARD_RECT)
	var button := UiKitLib.button("guild.report.action", "primary")
	button.name = "Report"
	button.pressed.connect(func() -> void: report_discovery(discovery_id))
	row.add_child(button)
	_place(button, REPORT_BUTTON_RECT)


# --- Layout id registry (docs/80-UI-UX.md §4.8.9, Phase 12 W2-A) -------------

## Registers every persistent control with its stable hierarchical id. The
## statics carry the authored rects above (the capture emits them as the
## screen's fragment); the offer/report rows are list members — their ids
## carry the `list` flag and take `list_rect` positions.
func _register_layout() -> void:
	_reg(_background, "background", RegistryLib.ROLE_PANEL)
	_reg(_header, "header", RegistryLib.ROLE_PLAIN)
	_reg(_title, "header.title", RegistryLib.ROLE_PLAIN)
	_reg(_gold, "header.gold", RegistryLib.ROLE_PLAIN)
	_reg(_fame, "header.fame", RegistryLib.ROLE_PLAIN)
	_reg(_back_button, "header.back", RegistryLib.ROLE_BUTTON)
	_reg(_offers, "offers", RegistryLib.ROLE_PLAIN)
	_reg(_offers_heading, "offers.heading", RegistryLib.ROLE_PLAIN)
	_reg(_offers_hint, "offers.refresh_hint", RegistryLib.ROLE_PLAIN)
	_reg(_announce, "offers.announce", RegistryLib.ROLE_PLAIN)
	_reg(_offers_scroll, "offers.scroll", RegistryLib.ROLE_PLAIN)
	_reg(_offers_empty, "offers.empty", RegistryLib.ROLE_PLAIN)
	_reg(_reports, "reports", RegistryLib.ROLE_PLAIN)
	_reg(_reports_heading, "reports.heading", RegistryLib.ROLE_PLAIN)
	_reg(_reports_scroll, "reports.scroll", RegistryLib.ROLE_PLAIN)
	_reg(_reports_empty, "reports.empty", RegistryLib.ROLE_PLAIN)


## One static registration — kind omitted (auto-derives from the parent).
func _reg(control: Control, id: String, role: String) -> void:
	RegistryLib.register(LAYOUT_SCREEN, control, id, {"role": role})


## Registers one rebuilt dynamic row set (the offer/report rows). `entries`
## = [{control, id, opts}]. A section's FIRST build registers synchronously
## — inside `_ready`, ahead of `screen_active`, so the activation walk
## captures the rows' baselines. A REbuild defers one frame: the cleared
## rows are queue_freed but still live within this frame, and a same-frame
## re-register would read as a duplicate id — after the frame's delete
## flush the same-id replacement is silent. A pass whose screen died
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


## Transient feedback through the kit toast atom (§4.9/§4.7: bottom-center,
## max 1 visible, the §4.7.17 fades; the atom owns its own lifecycle, so the
## scene's retired toast label/timer are no longer touched). Missing keys
## show nothing so a not-yet-merged key never spams errors.
func _show_toast(key: String, values: Dictionary = {}) -> void:
	if not DataLoader.ui_strings.has(key):
		return
	UiKitLib.toast(self, I18n.fmt(key, values))


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
