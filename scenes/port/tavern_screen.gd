extends Control
## Tavern (S7) — crew hire/fire + officer recruiting
## (docs/30-PORTS-AND-TRADE.md §4.5, §4.7; docs/50-* §4.4–§4.5;
## docs/40-SHIPS-AND-FLEET.md §4.4; docs/80-UI-UX.md §4.2–§4.3, §4.7–§4.8).
##
## Two tabs, exactly as the §4.7 wireframe:
##   * **Crew** — `n / crew_max`, morale tier, `Hire 1 / Hire 10 / Fill`,
##     `Fire 1 / Fire 10 / Down to min`, "20g per head" and the reason a
##     button is disabled (at cap / at floor / short of gold).
##   * **Officers** — the officers whose `recruit_ports` include this port and
##     who are not employed, each with name, role, stats, wage, bio and a
##     `Recruit` button showing the `wage × 10` signing fee; below, the
##     current roster with `Dismiss`.
##
## Every rule lives in `scripts/port/tavern_engine.gd` (crew maths/visibility)
## and `character.gd` (officers, OFFICER_MAX, role bonuses) — this screen only
## renders state and forwards clicks. That keeps the tavern data-driven and
## the same rules testable headless.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const TavernEngineLib := preload("res://scripts/port/tavern_engine.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"

## Tab ids (`select_tab` argument / [method active_tab] return).
const TAB_CREW := "crew"
const TAB_OFFICERS := "officers"
const TAB_RUMORS := "rumors"

## How long the transient action toast stays up (docs/80-* §4.7: 2.5s).
const TOAST_SECONDS := 2.5

## ui_strings keys this screen needs that the shared table does not carry yet
## (T4 owns `data/ui_strings.json`; T14 must not edit it). Same zh+en shape as
## the JSON so merging them later is a copy-paste, and the screen renders
## correctly in the meantime. Resolved by [method _t_key].
const FALLBACK_STRINGS := {
	"tavern.crew_full": {
		"zh": "船员已满({max} 人)。",
		"en": "Crew is at full strength ({max}).",
	},
}

## docs/50-* §4.5 role id → ui_strings key (same mapping the character panel
## uses; an unknown role falls back to `char.none`).
const ROLE_KEYS := {
	"navigator": "tavern.role.navigator",
	"boatswain": "tavern.role.boatswain",
	"gunner": "tavern.role.gunner",
}

## Routing switch for headless tests (the `GameState.new_game(..., route)`
## convention): with `false`, [method go_back] runs its state transition and
## emits [signal back_requested] without replacing the scene.
var route_to_port: bool = true

## Emitted when Back/Esc is taken, before any scene swap.
signal back_requested

@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _gold: Label = $Layout/VBox/Header/Gold
@onready var _back_button: Button = $Layout/VBox/Header/Back
@onready var _crew_tab: Button = $Layout/VBox/Tabs/CrewTab
@onready var _officers_tab: Button = $Layout/VBox/Tabs/OfficersTab
@onready var _rumors_tab: Button = $Layout/VBox/Tabs/RumorsTab
@onready var _crew_panel: VBoxContainer = $Layout/VBox/Body/CrewPanel
@onready var _officers_panel: VBoxContainer = $Layout/VBox/Body/OfficersPanel
@onready var _rumors_panel: VBoxContainer = $Layout/VBox/Body/RumorsPanel
@onready var _rumor_tournament: Label = \
	$Layout/VBox/Body/RumorsPanel/Tournament
@onready var _rumor_price: Label = $Layout/VBox/Body/RumorsPanel/Price
@onready var _rumor_rows: VBoxContainer = $Layout/VBox/Body/RumorsPanel/Scroll/Rows
@onready var _rumor_empty: Label = $Layout/VBox/Body/RumorsPanel/Empty
@onready var _crew_count: Label = $Layout/VBox/Body/CrewPanel/CrewCount
@onready var _morale: Label = $Layout/VBox/Body/CrewPanel/Morale
@onready var _per_head: Label = $Layout/VBox/Body/CrewPanel/PerHead
@onready var _hire_1: Button = $Layout/VBox/Body/CrewPanel/HireRow/Hire1
@onready var _hire_10: Button = $Layout/VBox/Body/CrewPanel/HireRow/Hire10
@onready var _fill: Button = $Layout/VBox/Body/CrewPanel/HireRow/Fill
@onready var _fire_1: Button = $Layout/VBox/Body/CrewPanel/FireRow/Fire1
@onready var _fire_10: Button = $Layout/VBox/Body/CrewPanel/FireRow/Fire10
@onready var _down_to_min: Button = $Layout/VBox/Body/CrewPanel/FireRow/DownToMin
@onready var _reason: Label = $Layout/VBox/Body/CrewPanel/Reason
@onready var _min_note: Label = $Layout/VBox/Body/CrewPanel/MinNote
@onready var _recruitable: VBoxContainer = \
	$Layout/VBox/Body/OfficersPanel/RecruitableScroll/Recruitable
@onready var _roster_header: Label = $Layout/VBox/Body/OfficersPanel/RosterHeader
@onready var _roster: VBoxContainer = \
	$Layout/VBox/Body/OfficersPanel/RosterScroll/Roster
@onready var _officer_reason: Label = $Layout/VBox/Body/OfficersPanel/Reason
@onready var _toast: Label = $Layout/VBox/Toast
@onready var _toast_timer: Timer = $ToastTimer
@onready var _esc_hint: Label = $Layout/VBox/Footer/EscHint

## Currently shown tab ([constant TAB_CREW] / [constant TAB_OFFICERS]).
var _tab: String = TAB_CREW

## Port id read at open time ("" when launched standalone from the editor).
var _port_id: String = ""

## The rumour hint rows currently rendered (discovery id + fame), in order.
var _rumors: Array = []

## True while a TavernEngine/Character transaction is running; the EventBus
## refresh handlers do nothing then (see [method hire_heads]).
var _busy: bool = false


func _ready() -> void:
	$Background.color = PaletteLib.PANEL_BG
	for label in [
		_title, _gold, _crew_count, _morale, _per_head, _reason, _min_note,
		_roster_header, _officer_reason, _esc_hint, _toast, _rumor_price,
		_rumor_empty, _rumor_tournament,
	]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_per_head.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_rumor_price.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_min_note.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_esc_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_rumor_empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_title.add_theme_font_size_override("font_size", 32)
	_toast.visible = false
	_toast_timer.timeout.connect(_on_toast_timeout)
	_toast_timer.one_shot = true

	for button in [
		_back_button, _crew_tab, _officers_tab, _rumors_tab, _hire_1, _hire_10,
		_fill, _fire_1, _fire_10, _down_to_min,
	]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H
		_style_button(button)

	_back_button.pressed.connect(go_back)
	_crew_tab.pressed.connect(select_tab.bind(TAB_CREW))
	_officers_tab.pressed.connect(select_tab.bind(TAB_OFFICERS))
	_rumors_tab.pressed.connect(select_tab.bind(TAB_RUMORS))
	_hire_1.pressed.connect(_on_hire_pressed.bind(1))
	_hire_10.pressed.connect(_on_hire_pressed.bind(10))
	_fill.pressed.connect(_on_fill_pressed)
	_fire_1.pressed.connect(_on_fire_pressed.bind(1))
	_fire_10.pressed.connect(_on_fire_pressed.bind(10))
	_down_to_min.pressed.connect(_on_down_to_min_pressed)

	_port_id = _read_current_port()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	refresh()


func _unhandled_input(event: InputEvent) -> void:
	# §4.3 "Esc = back / close modal": this screen is one edge from S4, so Esc
	# is the same back edge as the Back button (docs/80-* §4.2).
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		go_back()
		return
	if event.is_action_pressed("toggle_locale"):
		get_viewport().set_input_as_handled()
		I18n.toggle_locale()


# --- Public API (tests + hosts) --------------------------------------------

func port_id() -> String:
	return _port_id


## Switches the visible panel. Unknown ids are ignored.
func select_tab(tab: String) -> void:
	if tab != TAB_CREW and tab != TAB_OFFICERS and tab != TAB_RUMORS:
		return
	_tab = tab
	refresh()


func active_tab() -> String:
	return _tab


## Back edge S7 → S4 (docs/80-* §4.2). Leaves game state untouched: a facility
## visit never clears `current_port` (that is Set Sail, docs/20-* §4.11).
func go_back() -> bool:
	back_requested.emit()
	if route_to_port:
		GameState.change_scene(PORT_SCENE)
	return true


## Crew-tab actions. Thin delegates: the rules live in TavernEngine.
##
## [_busy] suppresses the `gold_changed` / `fleet_changed` refresh during the
## transaction: a hire/recruit emits those signals *while* the engine is still
## half-way through, and rebuilding the officer rows then would free the very
## button whose `pressed` signal we are inside. One refresh after the
## transaction shows the finished state.
func hire_heads(heads: int) -> bool:
	_busy = true
	var ok: bool = TavernEngineLib.hire(heads)
	_busy = false
	refresh()
	return ok


## Fires at most `heads`, clamped to the crew_min floor (§6 "−1/−10 clamp
## likewise"); returns the number actually let go.
func fire_heads(heads: int) -> int:
	_busy = true
	var fired: int = TavernEngineLib.fire_clamped(heads)
	_busy = false
	refresh()
	return fired


## Officers-tab actions. Rules live in Character (docs/50-* §4.4).
func recruit_officer(officer_id: String) -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	_busy = true
	var ok: bool = CharacterLib.recruit(officer_id)
	_busy = false
	if ok:
		_show_toast("tavern.recruited", {"name": I18n.t(officer.get("name", {}))})
	refresh()
	return ok


func dismiss_officer(officer_id: String) -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	_busy = true
	var ok: bool = CharacterLib.dismiss(officer_id)
	_busy = false
	if ok:
		_show_toast("tavern.dismissed", {"name": I18n.t(officer.get("name", {}))})
	refresh()
	return ok


## Rumors-tab action (docs/70-* §4.4): buys `discovery_id`'s hint for 100g.
## Returns the discovery entry (`{}` on refusal — already hinted or short of
## gold, in which case a reason is toasted).
func buy_rumor(discovery_id: String) -> Dictionary:
	var hinted := DiscoveryLib.is_hinted(discovery_id)
	var entry := DiscoveryLib.buy_hint(discovery_id)
	if entry.is_empty():
		_show_toast("tavern.rumor.bought" if hinted else "tavern.rumor.no_gold")
		refresh()
		return {}
	_show_toast("tavern.rumor.buy")
	refresh()
	return entry


## The discovery ids the Rumors tab currently lists, in display order.
func rumor_rows() -> Array:
	var out: Array = []
	for entry in _rumors:
		out.append(str((entry as Dictionary).get("id", "")))
	return out


## Rebuilds every label/row from GameState. Called on open, on locale change
## and on `gold_changed` / `fleet_changed` (never polled from `_process`).
func refresh() -> void:
	_port_id = _read_current_port()
	_bind_header()
	_bind_crew()
	_bind_officers()
	_bind_rumors()
	_crew_panel.visible = _tab == TAB_CREW
	_officers_panel.visible = _tab == TAB_OFFICERS
	_rumors_panel.visible = _tab == TAB_RUMORS


# --- Header / tabs ---------------------------------------------------------

func _bind_header() -> void:
	var port: Dictionary = DataLoader.get_port(_port_id) if not _port_id.is_empty() else {}
	_title.text = I18n.fmt("tavern.title", {
		"port": I18n.t(port.get("name", {})) if not port.is_empty() else "-",
	})
	_gold.text = I18n.fmt("ui.gold_amount", {
		"gold": HudLib.format_thousands(GameState.gold),
	})
	_back_button.text = I18n.t_key("ui.back")
	_crew_tab.text = I18n.t_key("tavern.crew_tab")
	_officers_tab.text = I18n.t_key("tavern.officers_tab")
	_rumors_tab.text = I18n.t_key("tavern.rumor_tab")
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	# Active tab is accent-colored and held down; the inactive one stays
	# neutral (toggle buttons, so only one reads as "current").
	for pair in [[TAB_CREW, _crew_tab], [TAB_OFFICERS, _officers_tab],
			[TAB_RUMORS, _rumors_tab]]:
		var active: bool = _tab == str(pair[0])
		var button: Button = pair[1]
		button.button_pressed = active
		button.add_theme_color_override(
			"font_color", PaletteLib.ACCENT if active else PaletteLib.TEXT
		)


# --- Crew tab (docs/30-* §4.5) --------------------------------------------

func _bind_crew() -> void:
	var max_crew := TavernEngineLib.crew_max()
	var crew := TavernEngineLib.crew()
	var min_crew := TavernEngineLib.crew_min()
	_crew_count.text = I18n.fmt(
		"tavern.crew_count", {"crew": crew, "max": max_crew}
	)
	_morale.text = "%s (%s)" % [
		I18n.fmt("world.morale", {"amount": GameState.morale}),
		I18n.t_key("world.morale.%s" % HudLib.morale_tier(GameState.morale)),
	]
	_morale.add_theme_color_override(
		"font_color", HudLib.morale_color(GameState.morale)
	)
	_per_head.text = I18n.fmt(
		"tavern.per_head", {"price": TavernEngineLib.per_head()}
	)
	_min_note.text = I18n.fmt("tavern.crew_min_note", {"crew": min_crew})

	_hire_1.text = I18n.fmt("tavern.hire", {"qty": 1})
	_hire_10.text = I18n.fmt("tavern.hire", {"qty": 10})
	_fill.text = I18n.t_key("tavern.fill")
	_fire_1.text = I18n.fmt("tavern.fire", {"qty": 1})
	_fire_10.text = I18n.fmt("tavern.fire", {"qty": 10})
	_down_to_min.text = I18n.t_key("tavern.down_to_min")

	# Hire: never past crew_max, never without gold (§4.5 + §6).
	_set_enabled(_hire_1, TavernEngineLib.can_hire(1))
	_set_enabled(_hire_10, TavernEngineLib.can_hire(10))
	var fill_heads := TavernEngineLib.fill_heads()
	_set_enabled(_fill, fill_heads > 0)

	# Fire: cannot go below crew_min. §6 "−1/−10 clamp likewise" — the button
	# fires as many as the floor allows, so −10 with 3 head above the floor
	# stops exactly on crew_min instead of refusing (see fire_clamped).
	var floor_note := I18n.fmt("tavern.crew_min_note", {"crew": min_crew})
	var can_fire_any := TavernEngineLib.min_fire() > 0
	_set_enabled(_fire_1, can_fire_any)
	_set_enabled(_fire_10, can_fire_any)
	_set_enabled(_down_to_min, can_fire_any)
	if not can_fire_any:
		_fire_1.tooltip_text = floor_note
		_fire_10.tooltip_text = floor_note
		_down_to_min.tooltip_text = floor_note

	# Disabled reason for the hire side: at cap, then short of gold. With no
	# flagship (editor standalone) every crew action is inert and no "reason"
	# is claimed — there is no ship to crew.
	var reason := ""
	var tooltip := ""
	if max_crew <= 0:
		pass
	elif TavernEngineLib.max_hire() <= 0:
		reason = _crew_full_text(max_crew)
		tooltip = reason
	elif GameState.gold < TavernEngineLib.per_head():
		reason = I18n.t_key("market.no_gold")
		tooltip = I18n.fmt("market.not_enough_gold", {
			"gold": TavernEngineLib.hire_cost(1),
		})
	_reason.text = reason
	_reason.visible = not reason.is_empty()
	if not tooltip.is_empty():
		_hire_1.tooltip_text = tooltip
		_hire_10.tooltip_text = tooltip
		_fill.tooltip_text = tooltip
	else:
		_hire_1.tooltip_text = ""
		_hire_10.tooltip_text = ""
		_fill.tooltip_text = ""


# --- Officers tab (docs/50-* §4.4) ---------------------------------------

func _bind_officers() -> void:
	_clear(_recruitable)
	_clear(_roster)

	var available: Array = TavernEngineLib.officers_at_port(_port_id)
	if available.is_empty():
		_recruitable.add_child(_make_label(
			I18n.t_key("tavern.no_officers"), "Empty"
		))
	for officer_id in available:
		_recruitable.add_child(_build_recruitable_row(str(officer_id)))

	_roster_header.text = I18n.t_key("char.officers")
	var employed: Array = CharacterLib.employed_officers()
	if employed.is_empty():
		_roster.add_child(_make_label(I18n.t_key("char.no_officers"), "Empty"))
	for officer_id in employed:
		_roster.add_child(_build_roster_row(str(officer_id)))

	# One shared reason for the whole recruitable list: roster full first
	# (docs/50-* §6), then short of gold (§6 "button disabled with price shown").
	var reason := ""
	if CharacterLib.officer_count() >= CharacterLib.OFFICER_MAX:
		reason = I18n.fmt("char.officers_full", {"max": CharacterLib.OFFICER_MAX})
	else:
		for officer_id in available:
			if GameState.gold < CharacterLib.recruit_cost(str(officer_id)):
				reason = I18n.t_key("market.no_gold")
				break
	_officer_reason.text = reason
	_officer_reason.visible = not reason.is_empty()


func _build_recruitable_row(officer_id: String) -> Control:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var row := HBoxContainer.new()
	row.name = "Officer_%s" % officer_id
	row.add_theme_constant_override("separation", PaletteLib.MARGIN)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(_make_label(I18n.t(officer.get("name", {})), "Name"))
	var role_key := str(ROLE_KEYS.get(str(officer.get("role", "")), "char.none"))
	var subtitle := _make_label("%s · %s" % [
		I18n.t_key(role_key),
		I18n.fmt("tavern.wage", {"price": int(officer.get("wage_daily", 0))}),
	], "Role")
	subtitle.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	info.add_child(subtitle)
	var stats: Dictionary = officer.get("stats", {})
	info.add_child(_make_label(I18n.fmt("tavern.stats", {
		"leadership": int(stats.get("leadership", 0)),
		"seamanship": int(stats.get("seamanship", 0)),
		"combat": int(stats.get("combat", 0)),
		"navigation": int(stats.get("navigation", 0)),
	}), "Stats"))
	var bio := _make_label(I18n.t(officer.get("bio", {})), "Bio")
	bio.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bio.custom_minimum_size.x = 560
	bio.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	info.add_child(bio)
	row.add_child(info)

	var action := VBoxContainer.new()
	action.custom_minimum_size.x = 200
	var cost := _make_label(I18n.fmt(
		"tavern.signing_cost",
		{"amount": CharacterLib.recruit_cost(officer_id)},
	), "Cost")
	cost.add_theme_color_override("font_color", PaletteLib.ACCENT)
	action.add_child(cost)
	var button := Button.new()
	button.name = "Recruit"
	button.text = I18n.t_key("tavern.recruit")
	button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_style_button(button)
	button.disabled = not CharacterLib.can_recruit(officer_id)
	if button.disabled:
		if CharacterLib.officer_count() >= CharacterLib.OFFICER_MAX:
			button.tooltip_text = I18n.fmt(
				"char.officers_full", {"max": CharacterLib.OFFICER_MAX}
			)
		else:
			button.tooltip_text = I18n.fmt("market.not_enough_gold", {
				"gold": CharacterLib.recruit_cost(officer_id),
			})
	button.pressed.connect(recruit_officer.bind(officer_id))
	action.add_child(button)
	row.add_child(action)
	return row


func _build_roster_row(officer_id: String) -> Control:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var row := HBoxContainer.new()
	row.name = "Employed_%s" % officer_id
	row.add_theme_constant_override("separation", PaletteLib.MARGIN)

	var name_label := _make_label(I18n.t(officer.get("name", {})), "Name")
	name_label.custom_minimum_size.x = 260
	row.add_child(name_label)
	var role_key := str(ROLE_KEYS.get(str(officer.get("role", "")), "char.none"))
	var role_label := _make_label(I18n.t_key(role_key), "Role")
	role_label.custom_minimum_size.x = 120
	role_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	row.add_child(role_label)
	var wage := _make_label(I18n.fmt(
		"tavern.wage", {"price": int(officer.get("wage_daily", 0))}
	), "Wage")
	wage.custom_minimum_size.x = 160
	row.add_child(wage)

	var button := Button.new()
	button.name = "Dismiss"
	button.text = I18n.t_key("tavern.dismiss")
	button.custom_minimum_size = Vector2(160, PaletteLib.BUTTON_H)
	_style_button(button)
	button.pressed.connect(dismiss_officer.bind(officer_id))
	row.add_child(button)
	return row


# --- Rumors tab (docs/70-* §4.4) ------------------------------------------

## Up to three unfound discoveries for this tavern visit, each showing its
## `region_hint` and a `Buy — 100g` button. Buying marks it hinted (the name
## is then revealed) and the row turns into `tavern.rumor.bought`.
func _bind_rumors() -> void:
	_clear(_rumor_rows)
	_rumors = []
	# The monthly tournament is announced here (§4.6: "announced via tavern
	# rumor and the guild"), so a player who never opens a palace can find it.
	var status := TournamentLib.status(_port_id, GameState.day)
	_rumor_tournament.text = I18n.fmt("tournament.status", {
		"port": I18n.t(DataLoader.get_port(str(status.get("host", "")))
			.get("name", {})),
		"first": int(status.get("window_first", 1)),
		"last": int(status.get("window_last", 5)),
	})
	var blocked := str(status.get("blocked", ""))
	if blocked == "tournament.not_host" or blocked == "tournament.closed":
		_rumor_tournament.text += " — %s" % I18n.t_key(blocked)
	_rumor_tournament.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_rumor_price.text = I18n.fmt(
		"tavern.rumor.price", {"gold": DiscoveryLib.HINT_PRICE}
	)
	_rumor_empty.text = I18n.t_key("tavern.rumor.none")
	if _port_id.is_empty():
		_rumors = []
	else:
		for discovery_id in DiscoveryLib.hints(_port_id, GameState.day):
			_rumors.append({"id": str(discovery_id)})
	_rumor_empty.visible = _rumors.is_empty()
	if _rumors.is_empty():
		return
	for entry in _rumors:
		_rumor_rows.add_child(_build_rumor_row(str(entry["id"])))


func _build_rumor_row(discovery_id: String) -> Control:
	var discovery: Dictionary = DataLoader.get_discovery(discovery_id)
	var hinted := DiscoveryLib.is_hinted(discovery_id)
	var row := VBoxContainer.new()
	row.name = "Rumor_%s" % discovery_id
	row.add_theme_constant_override("separation", 4)

	var hint := _make_label(I18n.t(DiscoveryLib.hint_text(discovery_id)), "Hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(hint)

	var bottom := HBoxContainer.new()
	bottom.name = "Bottom"
	bottom.add_theme_constant_override("separation", PaletteLib.MARGIN)
	# The 100g buys the *location*: the name appears only once hinted
	# (docs/80-* §4.7.3).
	var name_label := _make_label(
		I18n.t(discovery.get("name", {})) if hinted else "?", "Name"
	)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override(
		"font_color", PaletteLib.ACCENT if hinted else PaletteLib.PANEL_LINE
	)
	bottom.add_child(name_label)

	var button := Button.new()
	button.name = "Buy"
	button.custom_minimum_size = Vector2(200, PaletteLib.BUTTON_H)
	_style_button(button)
	button.tooltip_text = I18n.fmt(
		"tavern.rumor.price", {"gold": DiscoveryLib.HINT_PRICE}
	)
	if hinted:
		button.text = I18n.t_key("tavern.rumor.bought")
		button.disabled = true
	elif GameState.gold < DiscoveryLib.HINT_PRICE:
		button.text = I18n.t_key("tavern.rumor.buy")
		button.disabled = true
		button.tooltip_text = I18n.t_key("tavern.rumor.no_gold")
	else:
		button.text = I18n.t_key("tavern.rumor.buy")
		button.pressed.connect(func() -> void: buy_rumor(discovery_id))
	bottom.add_child(button)
	row.add_child(bottom)
	return row


# --- Button handlers -------------------------------------------------------

func _on_hire_pressed(heads: int) -> void:
	hire_heads(heads)


func _on_fill_pressed() -> void:
	hire_heads(TavernEngineLib.fill_heads())


func _on_fire_pressed(heads: int) -> void:
	fire_heads(heads)


func _on_down_to_min_pressed() -> void:
	fire_heads(TavernEngineLib.min_fire())


# --- Helpers ---------------------------------------------------------------

## The docked port id, else "" (standalone / no run).
func _read_current_port() -> String:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return value
	return ""


## `I18n.t_key` for a key this screen also carries in [constant
## FALLBACK_STRINGS] until T4 merges it into `data/ui_strings.json`.
func _t_key(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	var l10n: Dictionary = FALLBACK_STRINGS.get(key, {})
	if l10n.is_empty():
		return I18n.t_key(key)
	return I18n.t(l10n)


## [method _t_key] plus `{name}` substitution (docs/80-* §4.4).
func _fmt(key: String, values: Dictionary = {}) -> String:
	var text := _t_key(key)
	for name in values:
		text = text.replace("{%s}" % name, str(values[name]))
	return text


## "Crew is at full strength (N)" — from ui_strings when present, else the
## local fallback (see [constant FALLBACK_STRINGS]).
func _crew_full_text(max_crew: int) -> String:
	return _fmt("tavern.crew_full", {"max": max_crew})


func _set_enabled(button: Button, enabled: bool) -> void:
	button.disabled = not enabled
	if enabled:
		button.tooltip_text = ""


func _make_label(text: String, node_name: String = "") -> Label:
	var label := Label.new()
	label.text = text
	if not node_name.is_empty():
		label.name = node_name
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	return label


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _style_button(button: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = PaletteLib.PANEL_BG
	normal.border_color = PaletteLib.PANEL_LINE
	normal.set_border_width_all(2)
	normal.set_content_margin_all(PaletteLib.BASE_UNIT)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.border_color = PaletteLib.ACCENT
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = PaletteLib.ACCENT
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_stylebox_override("pressed", pressed)


## Transient action feedback (docs/80-* §4.7). Missing keys show nothing so a
## not-yet-merged key never spams errors. Uses a one-shot Timer child rather
## than a coroutine so a scene freed mid-toast cannot resume on a dead node.
func _show_toast(key: String, values: Dictionary = {}) -> void:
	if not DataLoader.ui_strings.has(key):
		return
	_toast.text = I18n.fmt(key, values)
	_toast.add_theme_color_override("font_color", PaletteLib.GOOD)
	_toast.visible = true
	_toast_timer.start(TOAST_SECONDS)


func _on_toast_timeout() -> void:
	_toast.visible = false


func _on_gold_changed(_new_gold: int) -> void:
	if _busy:
		return
	refresh()


func _on_fleet_changed() -> void:
	if _busy:
		return
	refresh()


func _on_locale_changed(_locale: String) -> void:
	refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.fleet_changed.is_connected(_on_fleet_changed):
		EventBus.fleet_changed.disconnect(_on_fleet_changed)
