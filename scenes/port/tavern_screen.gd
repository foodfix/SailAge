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
## Phase-8 W5-C (docs/80-* §4.11, in-port verb matrices), all on the rumours
## tab beside the §4.7.8 sighting surfaces:
##   * sighting rows gain the 交好 befriend verb (+1 stance, once per captain
##     per port-visit day — the engine-side session guard);
##   * the **captains' table** (§4.11.2) indexes this port's sightings with
##     role/tier/last-seen/facility pointers and an inspect action (+1
##     familiarity per view; the unified card is W6-A's, so the placeholder
##     renders a summary line);
##   * the **sparring bet** row — stake 100–1,000g in 100g steps via the
##     −/+ steppers, the locked `p` against the 40-swordplay tavern champion,
##     a win paying pot × 2, every bout counting 3 swordplay usages; the roll
##     comes from the seeded per-(port, visit-day) stream.
##
## Every rule lives in `scripts/port/tavern_engine.gd` (crew maths/visibility,
## befriend guard, sparring) and `character.gd` (officers, OFFICER_MAX, role
## bonuses) — this screen only renders state and forwards clicks. That keeps
## the tavern data-driven and the same rules testable headless.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-10 sweep (§4.9): sighting/poster/rumor rows carry the §4.8
## `role_{role}` / `scroll` icons through the kit registry (an absent id
## renders nothing — the flat fallback; the registry fills at W4-D), morale
## renders through the kit value_bar atom (§4.8 thresholds), the private
## toast adopts the kit toast atom, and the hand-built button chrome and
## per-screen colors retire to the shared theme.
const UiKitLib := preload("res://scripts/ui_kit.gd")
const TavernEngineLib := preload("res://scripts/port/tavern_engine.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
## Task L (docs/80-* §4.7.8): captains, wanted posters, the 20g reveal and
## the live-fleet/departure/event rumor rows.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
## Phase-8 W5-C: the captains' table and the inspect action read the canon
## cards and run state through the W4-A module (read-only for this screen).
const CaptainsLib := preload("res://scripts/world/captains.gd")
## §4.11.1: the sparring terms line renders the effective swordplay win
## chance (the growth engine owns the value).
const SkillsLib := preload("res://scripts/player/skills.gd")
## §4.1b port hours: the officers tab's window guard + hour charge (added
## 2026-11-02) — the tavern is the facility, this screen hosts the action.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const GameOverHostLib := preload("res://scenes/ui_shared/game_over_host.gd")
## §4.12.1 (W6-A): the recruit dialog renders the §4.12 officer card (the
## officer entry).
const CardLib := preload("res://scenes/ui/character_card.gd")
## The Phase-12 absolute-tile layout registry (docs/80-* §4.8.9): the data
## file is the layout; the registration below feeds the capture fragment.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## This screen's id in the registry (LayoutRegistry.SCREENS).
const LAYOUT_SCREEN := "tavern"

## --- The authored tile table (parent-relative 32-px tiles; Phase 12) ---------
## One tile = `Palette.CHROME_TILE`. The screen root is the canvas; the
## tab panels all sit on the body rect (tab-switched visibility) and their
## children address the panel's space.
const TILE := PaletteLib.CHROME_TILE
## The three tab panels' list blocks (content-node tiles): row *i* at
## `(base + (0, i·row_h))`.
const RECRUITABLE_LIST := "recruitable"
const RECRUITABLE_W := 58
const RECRUITABLE_ROW_H := 4
const ROSTER_LIST := "roster"
const ROSTER_W := 58
const ROSTER_ROW_H := 2
## The rumors scroll mixes row shapes (hint rows, sighting lines, wanted
## posters) at one pitch — a 2-tile row (the 64-px verbs set it).
const RUMORS_LIST := "rumors"
const RUMORS_W := 58
const RUMORS_ROW_H := 2
## The captains' table (§4.11.2): a non-scrolling list under its header
## (base y = 1 leaves the header its own tile).
const TABLE_LIST := "table"
const TABLE_W := 58
const TABLE_ROW_H := 2
const TABLE_BASE_Y := 1
## Recruitable-row internals (row-local tiles): the identity block, the bio
## line, and the action column (cost over Recruit over the card verb).
const OFFICER_NAME_RECT := Rect2i(0, 0, 30, 1)
const OFFICER_ROLE_RECT := Rect2i(0, 1, 30, 1)
const OFFICER_STATS_RECT := Rect2i(0, 2, 30, 1)
const OFFICER_BIO_RECT := Rect2i(0, 3, 44, 1)
const OFFICER_COST_RECT := Rect2i(46, 0, 6, 1)
const OFFICER_RECRUIT_RECT := Rect2i(46, 1, 6, 2)
const OFFICER_CARD_RECT := Rect2i(53, 1, 5, 2)
## Roster-row internals: name · role · wage · Dismiss.
const ROSTER_NAME_RECT := Rect2i(0, 0, 22, 2)
const ROSTER_ROLE_RECT := Rect2i(22, 0, 10, 2)
const ROSTER_WAGE_RECT := Rect2i(32, 0, 18, 2)
const ROSTER_DISMISS_RECT := Rect2i(52, 0, 6, 2)
## Sighting/poster/table-row internals: the §4.8 badge slot (1 tile, only
## when the art id answers), the line, and the row's verb at the right edge.
const ROW_BADGE_RECT := Rect2i(0, 0, 1, 2)
const ROW_TEXT_W := 49
const ROW_VERB_RECT := Rect2i(51, 0, 7, 2)
## Spar-section internals (spar-local tiles): the result line rides right of
## the terms line.
const SPAR_RESULT_RECT := Rect2i(29, 1, 29, 1)

## Tab ids (`select_tab` argument / [method active_tab] return).
const TAB_CREW := "crew"
const TAB_OFFICERS := "officers"
const TAB_RUMORS := "rumors"

## §4.8 morale tiers for the kit value_bar (docs/80-* §4.8: yellow < 40,
## red < 20 — the same thresholds `UiKit.auto_tier` takes).
const MORALE_GOOD_MIN := 40
const MORALE_WARN_MIN := 20

## ui_strings keys this screen needs that the shared table does not carry yet
## (T4 owns `data/ui_strings.json`; T14 must not edit it). Same zh+en shape as
## the JSON so merging them later is a copy-paste, and the screen renders
## correctly in the meantime. Resolved by [method _t_key].
## (Task L's `captain.rumor.*` / `captain.poster.reward` fallbacks were
## merged into the shared table at the W6 gate and are gone from here — the
## screen now reads the canonical keys directly.)
## Phase-8 W5-C adds the §4.11.1 sparring family (`tavern.spar.*`) — reported
## for the W6-D residual merge; until then the row renders from here.
const FALLBACK_STRINGS := {
	"tavern.crew_full": {
		"zh": "船员已满({max} 人)。",
		"en": "Crew is at full strength ({max}).",
	},
	"tavern.spar.title": {
		"zh": "切磋赌酒",
		"en": "Sparring bet",
	},
	"tavern.spar.stake": {
		"zh": "赌注:{gold} 金 · 胜率 {pct}%",
		"en": "Stake: {gold}g · win chance {pct}%",
	},
	"tavern.spar.go": {
		"zh": "押注切磋",
		"en": "Place the bet",
	},
	"tavern.spar.win": {
		"zh": "你赢了,赢得 {gold} 金!",
		"en": "You win — {gold}g paid out!",
	},
	"tavern.spar.lose": {
		"zh": "你输了,{gold} 金赌注归了馆主。",
		"en": "You lose — the {gold}g stake stays with the house.",
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

@onready var _header: Control = $header
@onready var _title: Label = $header/Title
@onready var _gold: Label = $header/Gold
@onready var _back_button: Button = $header/Back
@onready var _tabs: Control = $tabs
@onready var _crew_tab: Button = $tabs/CrewTab
@onready var _officers_tab: Button = $tabs/OfficersTab
@onready var _rumors_tab: Button = $tabs/RumorsTab
@onready var _body: Control = $body
@onready var _crew_panel: Control = $body/CrewPanel
@onready var _officers_panel: Control = $body/OfficersPanel
@onready var _rumors_panel: Control = $body/RumorsPanel
@onready var _rumor_tournament: Label = $body/RumorsPanel/Tournament
@onready var _rumor_price: Label = $body/RumorsPanel/Price
@onready var _rumor_scroll: ScrollContainer = $body/RumorsPanel/Scroll
@onready var _rumor_rows: Control = $body/RumorsPanel/Scroll/Rows
@onready var _rumor_empty: Label = $body/RumorsPanel/Empty
@onready var _crew_count: Label = $body/CrewPanel/CrewCount
@onready var _morale: Label = $body/CrewPanel/Morale
@onready var _per_head: Label = $body/CrewPanel/PerHead
@onready var _hire_row: Control = $body/CrewPanel/HireRow
@onready var _hire_1: Button = $body/CrewPanel/HireRow/Hire1
@onready var _hire_10: Button = $body/CrewPanel/HireRow/Hire10
@onready var _fill: Button = $body/CrewPanel/HireRow/Fill
@onready var _fire_row: Control = $body/CrewPanel/FireRow
@onready var _fire_1: Button = $body/CrewPanel/FireRow/Fire1
@onready var _fire_10: Button = $body/CrewPanel/FireRow/Fire10
@onready var _down_to_min: Button = $body/CrewPanel/FireRow/DownToMin
@onready var _reason: Label = $body/CrewPanel/Reason
@onready var _min_note: Label = $body/CrewPanel/MinNote
@onready var _recruitable_scroll: ScrollContainer = \
	$body/OfficersPanel/RecruitableScroll
@onready var _recruitable: Control = \
	$body/OfficersPanel/RecruitableScroll/Recruitable
@onready var _roster_header: Label = $body/OfficersPanel/RosterHeader
@onready var _roster_scroll: ScrollContainer = \
	$body/OfficersPanel/RosterScroll
@onready var _roster: Control = $body/OfficersPanel/RosterScroll/Roster
@onready var _officer_reason: Label = $body/OfficersPanel/Reason
## The morale value_bar next to the crew count (built in `_bind`, the same
## discipline as the inn's).
var _morale_bar: ProgressBar = null

## Currently shown tab ([constant TAB_CREW] / [constant TAB_OFFICERS]).
var _tab: String = TAB_CREW

## Port id read at open time ("" when launched standalone from the editor).
var _port_id: String = ""

## The rumour hint rows currently rendered (discovery id + fame), in order.
var _rumors: Array = []

## Task L (§4.7.8): the aliveness rows currently rendered — captain rows,
## poster rows and rumor texts (the seams a headless test reads).
var _captain_rows: Array = []
var _poster_rows: Array = []
var _rumor_texts: Array = []
## Phase 7 (§4.7.14): the investment-telegraph rows currently rendered.
var _invest_rows: Array = []
## Fleet ids whose exact position was already bought this visit (§4.7.8: one
## action per poster).
var _revealed: Dictionary = {}
## The reveal text of the most recent "buy a round" ("" before the first).
var last_reveal_text: String = ""
## The rumors list's next free slot after the last build (the paid reveal
## line appends there; the same-frame `gold_changed` refresh clears it, so
## it never survives a frame).
var _rumor_row_count: int = 0

## Phase-8 W5-C (§4.11.2): the captains' table — code-built under the rumor
## scroll (the RumorsPanel children the §4.7.8 test pins stay untouched).
var _table_box: Control = null
## The table rows currently rendered (`{captain_id, fleet_id, name, role,
## tier, nation_id, facility, last_seen_day}` — the headless seam).
var _table_rows: Array = []
## The summary line of the most recent inspect ("" before the first). The
## unified §4.12 card is W6-A's; this is the placeholder summary.
var last_inspect_text: String = ""

## Phase-8 W5-C (§4.11.1): the sparring row — code-built beside the table.
var _spar_box: Control = null

## §4.12.1 (W6-A): the recruit dialog — the §4.12 officer card over the
## recruitable list (`null` while closed; the card-identity pin reads its
## card through [method recruit_dialog]).
var _recruit_dialog: Control = null
## The stake the steppers currently offer (always on a 100g step).
var _spar_stake: int = TavernEngineLib.SPAR_STAKE_MIN
## The seeded bout stream: re-seeded per (port, visit-day) so a bout sequence
## replays deterministically (the §4.7.8 roll discipline, applied to bets).
var _spar_seed_key: String = ""
var _spar_rng := RandomNumberGenerator.new()
## The most recent bout's result (`{}` before the first) — `{won, stake,
## chance, uses, roll}`; the row re-renders its result line from it.
var last_spar: Dictionary = {}

## Phase-11 (§4.8.9): per dynamic section, true once its first build has
## registered (see [_register_dynamic] for the first-build/rebuild split).
var _layout_built: Dictionary = {}

## True while a TavernEngine/Character transaction is running; the EventBus
## refresh handlers do nothing then (see [method hire_heads]).
var _busy: bool = false


func _ready() -> void:
	# §4.8 Skin coverage (amended 2026-11-05): the background is a
	# theme-styled Panel — the nine-patch walnut frame in texture mode, the
	# pinned navy flat panel in the reduced-graphics fallback. No paint call.
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): a run can die on any
	# ledger tick ashore — the game-over screen must rise over the tavern too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the shared theme (TEXT is the
	# theme's Label default; secondary notes carry the `Dim` variation and
	# the doc-pinned ACCENT tints the master-added `Accent` variation), the
	# tab buttons and row buttons render the themed states (the hand-built
	# chrome is gone), and the scene file keeps the 32px title / headings.
	_min_note.theme_type_variation = "Dim"
	_rumor_empty.theme_type_variation = "Dim"
	_per_head.theme_type_variation = "Accent"
	_rumor_price.theme_type_variation = "Accent"

	for button in [
		_back_button, _crew_tab, _officers_tab, _rumors_tab, _hire_1, _hire_10,
		_fill, _fire_1, _fire_10, _down_to_min,
	]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H

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

	# Phase 12 (§4.8.9): the authored tile rects — every static at its data
	# rect, the groups as plain Controls, before anything registers.
	_place_statics()
	_build_table_and_spar_sections()
	_register_layout()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	refresh()

	# Phase-11 (§4.8.9): the build is registered — activate the screen (pins
	# the root, captures baselines, applies the committed table; ships {}).
	RegistryLib.screen_active(LAYOUT_SCREEN, self)


## Phase 12 (§4.8.9): one authored rect = one `position`/`size` write, in
## the DIRECT parent's tile space (point anchors everywhere; nothing is
## stretched).
func _place(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(TILE)
	control.size = Vector2(rect.size) * float(TILE)


## The authored tile table — today's captured look, flattened to the grid
## (`data/ui_layout.json
## `).
func _place_statics() -> void:
	_place(_header, Rect2i(1, 1, 58, 2))
	_place(_title, Rect2i(0, 0, 51, 1))
	_place(_gold, Rect2i(52, 1, 2, 1))
	_place(_back_button, Rect2i(54, 0, 4, 2))
	_place(_tabs, Rect2i(1, 3, 58, 2))
	_place(_crew_tab, Rect2i(0, 0, 5, 2))
	_place(_officers_tab, Rect2i(5, 0, 5, 2))
	_place(_rumors_tab, Rect2i(11, 0, 5, 2))
	_place(_body, Rect2i(1, 6, 58, 24))
	_place(_crew_panel, Rect2i(0, 0, 58, 24))
	_place(_crew_count, Rect2i(0, 0, 58, 1))
	_place(_morale, Rect2i(0, 1, 58, 1))
	_place(_per_head, Rect2i(0, 3, 58, 1))
	_place(_hire_row, Rect2i(0, 4, 58, 2))
	_place(_hire_1, Rect2i(0, 0, 5, 2))
	_place(_hire_10, Rect2i(5, 0, 5, 2))
	_place(_fill, Rect2i(11, 0, 5, 2))
	_place(_fire_row, Rect2i(0, 6, 58, 2))
	_place(_fire_1, Rect2i(0, 0, 5, 2))
	_place(_fire_10, Rect2i(5, 0, 5, 2))
	_place(_down_to_min, Rect2i(11, 0, 5, 2))
	_place(_reason, Rect2i(0, 8, 58, 1))
	_place(_min_note, Rect2i(0, 9, 58, 1))
	_place(_officers_panel, Rect2i(0, 0, 58, 24))
	_place(_recruitable_scroll, Rect2i(0, 0, 58, 16))
	_place(_roster_header, Rect2i(0, 17, 58, 1))
	_place(_roster_scroll, Rect2i(0, 18, 58, 5))
	_place(_officer_reason, Rect2i(0, 23, 58, 1))
	_place(_rumors_panel, Rect2i(0, 0, 58, 24))
	_place(_rumor_tournament, Rect2i(0, 0, 58, 1))
	_place(_rumor_price, Rect2i(0, 1, 58, 1))
	_place(_rumor_scroll, Rect2i(0, 2, 58, 15))
	_place(_rumor_empty, Rect2i(0, 2, 58, 1))


## Row *i*'s rect for a list block — px in the section's content-node space:
## the data block when managed, the same tiles authored otherwise. The
## captains' table's base sits one tile down (its header's own tile).
func _list_row_rect(list_id: String, index: int, w: int, row_h: int) -> Rect2:
	var rect := RegistryLib.list_rect(LAYOUT_SCREEN, list_id, index)
	if rect != Rect2():
		return rect
	var base_y := TABLE_BASE_Y if list_id == TABLE_LIST else 0
	return Rect2(
		Vector2(0, base_y + index * row_h) * float(TILE),
		Vector2(w, row_h) * float(TILE))


func _unhandled_input(event: InputEvent) -> void:
	# §4.12.1 (W6-A): the recruit dialog owns the input while it is up (§6) —
	# its own `_unhandled_input` handles Esc first (reverse tree order); this
	# guard keeps the Back edge from firing behind it.
	if _recruit_dialog != null and _recruit_dialog.is_open():
		return
	# §4.3 "Esc = back / close modal": this screen is one edge from S4, so Esc
	# is the same back edge as the Back button (docs/80-* §4.2).
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		go_back()
		return


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


## Officers-tab actions. Rules live in Character (docs/50-* §4.4); the §4.1b
## window guard and one-hour cost live here — the tavern is the facility, the
## roster bookkeeping is Character's. All-or-nothing: a closed-door request is
## refused before Character is called.
func recruit_officer(officer_id: String) -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if not SailingSimLib.facility_open(port_id(), "tavern"):
		return false
	_busy = true
	var ok: bool = CharacterLib.recruit(officer_id)
	_busy = false
	if ok:
		_show_toast("tavern.recruited", {"name": I18n.t(officer.get("name", {}))})
		SailingSimLib.advance_port_hours(1)
	_after_recruit(ok)
	return ok


func dismiss_officer(officer_id: String) -> bool:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	if not SailingSimLib.facility_open(port_id(), "tavern"):
		return false
	_busy = true
	var ok: bool = CharacterLib.dismiss(officer_id)
	_busy = false
	if ok:
		_show_toast("tavern.dismissed", {"name": I18n.t(officer.get("name", {}))})
		SailingSimLib.advance_port_hours(1)
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
	# Active tab: the toggle's pressed state (the theme's unified pressed
	# stylebox) marks the current tab — the former per-screen ACCENT tint
	# retires with the sweep.
	for pair in [[TAB_CREW, _crew_tab], [TAB_OFFICERS, _officers_tab],
			[TAB_RUMORS, _rumors_tab]]:
		(pair[1] as Button).button_pressed = _tab == str(pair[0])


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
	# The tier color rides the kit value_bar (§4.8 morale thresholds); the
	# label itself stays on the theme's TEXT.
	_refresh_morale_bar()
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
	var recruit_entries: Array = []
	var recruit_index := 0
	if available.is_empty():
		var empty := _make_label(
			I18n.t_key("tavern.no_officers"), "Empty"
		)
		_recruitable.add_child(empty)
		# The empty marker is a `recruitable` LIST MEMBER placed at the
		# block's row 0 (the coverage check exempts list members — the
		# seeded capture never sees the empty state; docs/80-* §4.8.9).
		var rect := RegistryLib.list_rect(LAYOUT_SCREEN, RECRUITABLE_LIST,
				0)
		if rect == Rect2():
			rect = Rect2(Vector2.ZERO,
					Vector2(RECRUITABLE_W, RECRUITABLE_ROW_H) * float(TILE))
		empty.set_anchors_preset(Control.PRESET_TOP_LEFT)
		empty.position = rect.position
		empty.size = rect.size
		recruit_entries.append({
			"control": empty, "id": "officers.recruitable.empty",
			"opts": {"role": RegistryLib.ROLE_PLAIN,
				"list": RECRUITABLE_LIST},
		})
	for officer_id in available:
		_build_recruitable_row(str(officer_id), recruit_index,
			recruit_entries)
		recruit_index += 1
	# The scroll's stacked extent: the plain content Control sized to the
	# rows' total pitch (viewport math, not flow).
	_recruitable.custom_minimum_size = Vector2(
		RECRUITABLE_W * float(TILE),
		recruit_index * RECRUITABLE_ROW_H * float(TILE))
	_register_dynamic("recruitable", recruit_entries)

	_roster_header.text = I18n.t_key("char.officers")
	var employed: Array = CharacterLib.employed_officers()
	var roster_entries: Array = []
	var roster_index := 0
	if employed.is_empty():
		var empty := _make_label(I18n.t_key("char.no_officers"), "Empty")
		_roster.add_child(empty)
		_place(empty, Rect2i(0, 0, ROSTER_W, 1))
		roster_entries.append({
			"control": empty, "id": "officers.roster.empty",
			"opts": {"role": RegistryLib.ROLE_PLAIN},
		})
	for officer_id in employed:
		_build_roster_row(str(officer_id), roster_index, roster_entries)
		roster_index += 1
	_roster.custom_minimum_size = Vector2(
		ROSTER_W * float(TILE),
		roster_index * ROSTER_ROW_H * float(TILE))
	_register_dynamic("roster", roster_entries)

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


## One recruitable row: a plain Control at the block's row rect; the
## identity block, bio and action column are absolutely-placed children of
## the row (no per-row flow containers, §4.8.9). The row is a `recruitable`
## list member; its parts are unregistered (locked viewport blocks).
func _build_recruitable_row(officer_id: String, index: int,
		entries: Array) -> void:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var row := Control.new()
	row.name = "Officer_%s" % officer_id
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recruitable.add_child(row)
	var rect := _list_row_rect(RECRUITABLE_LIST, index, RECRUITABLE_W,
		RECRUITABLE_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var row_id := "officers.recruitable.%s" % officer_id
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": RECRUITABLE_LIST},
	})

	var name_label := _make_label(I18n.t(officer.get("name", {})), "Name")
	row.add_child(name_label)
	_place(name_label, OFFICER_NAME_RECT)
	var role_key := str(ROLE_KEYS.get(str(officer.get("role", "")), "char.none"))
	var subtitle := _make_label("%s · %s" % [
		I18n.t_key(role_key),
		I18n.fmt("tavern.wage", {"price": int(officer.get("wage_daily", 0))}),
	], "Role")
	subtitle.theme_type_variation = "Dim"
	row.add_child(subtitle)
	_place(subtitle, OFFICER_ROLE_RECT)
	var stats: Dictionary = officer.get("stats", {})
	var stats_label := _make_label(I18n.fmt("tavern.stats", {
		"leadership": int(stats.get("leadership", 0)),
		"seamanship": int(stats.get("seamanship", 0)),
		"combat": int(stats.get("combat", 0)),
		"navigation": int(stats.get("navigation", 0)),
	}), "Stats")
	row.add_child(stats_label)
	_place(stats_label, OFFICER_STATS_RECT)
	var bio := _make_label(I18n.t(officer.get("bio", {})), "Bio")
	bio.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bio.theme_type_variation = "Dim"
	row.add_child(bio)
	_place(bio, OFFICER_BIO_RECT)

	var cost := _make_label(I18n.fmt(
		"tavern.signing_cost",
		{"amount": CharacterLib.recruit_cost(officer_id)},
	), "Cost")
	row.add_child(cost)
	_place(cost, OFFICER_COST_RECT)
	var button := UiKitLib.button("tavern.recruit")
	button.name = "Recruit"
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
	row.add_child(button)
	_place(button, OFFICER_RECRUIT_RECT)
	# §4.12.1 (W6-A): the recruit dialog — the §4.12 officer card view (the
	# officer entry); the signing itself stays on the row's Recruit button,
	# the dialog re-offers the same shared recruit path.
	var card_button := UiKitLib.button("interact.verb.inspect")
	card_button.name = "Card"
	card_button.pressed.connect(open_recruit_dialog.bind(officer_id))
	row.add_child(card_button)
	_place(card_button, OFFICER_CARD_RECT)


# --- §4.12.1 (W6-A): the recruit dialog -------------------------------------

## Opens the recruit dialog for `officer_id`: the §4.12 officer card (the
## officer entry) with the shared recruit path and the close edge. Returns
## the dialog (the test seam).
func open_recruit_dialog(officer_id: String) -> Control:
	close_recruit_dialog()
	_recruit_dialog = RecruitDialog.new()
	_recruit_dialog.name = "RecruitDialog"
	_recruit_dialog.tavern = self
	add_child(_recruit_dialog)
	_recruit_dialog.open(officer_id)
	return _recruit_dialog


## The open recruit dialog, or `null` when closed.
func recruit_dialog() -> Control:
	return _recruit_dialog


func close_recruit_dialog() -> void:
	if _recruit_dialog != null:
		_recruit_dialog.queue_free()
	_recruit_dialog = null


## The §4.12 officer card of the open recruit dialog (`{}` when closed) — the
## card-identity pin's tavern-side read.
func recruit_card_data() -> Dictionary:
	if _recruit_dialog == null or not _recruit_dialog.is_open():
		return {}
	return _recruit_dialog.card_data()


## The post-recruit refresh closes the dialog (the officer is aboard — the
## row is gone from the recruitable list).
func _after_recruit(ok: bool) -> void:
	if ok:
		close_recruit_dialog()
	refresh()


## One roster row: a plain Control at the block's row rect; name · role ·
## wage · Dismiss as absolutely-placed children (a `roster` list member;
## parts unregistered).
func _build_roster_row(officer_id: String, index: int,
		entries: Array) -> void:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	var row := Control.new()
	row.name = "Employed_%s" % officer_id
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster.add_child(row)
	var rect := _list_row_rect(ROSTER_LIST, index, ROSTER_W, ROSTER_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var row_id := "officers.roster.%s" % officer_id
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": ROSTER_LIST},
	})

	var name_label := _make_label(I18n.t(officer.get("name", {})), "Name")
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)
	_place(name_label, ROSTER_NAME_RECT)
	var role_key := str(ROLE_KEYS.get(str(officer.get("role", "")), "char.none"))
	var role_label := _make_label(I18n.t_key(role_key), "Role")
	role_label.theme_type_variation = "Dim"
	role_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(role_label)
	_place(role_label, ROSTER_ROLE_RECT)
	var wage := _make_label(I18n.fmt(
		"tavern.wage", {"price": int(officer.get("wage_daily", 0))}
	), "Wage")
	wage.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(wage)
	_place(wage, ROSTER_WAGE_RECT)

	var button := UiKitLib.button("tavern.dismiss", "danger")
	button.name = "Dismiss"
	button.pressed.connect(dismiss_officer.bind(officer_id))
	row.add_child(button)
	_place(button, ROSTER_DISMISS_RECT)


# --- Rumors tab (docs/70-* §4.4) ------------------------------------------

## Up to three unfound discoveries for this tavern visit, each showing its
## `region_hint` and a `Buy — 100g` button. Buying marks it hinted (the name
## is then revealed) and the row turns into `tavern.rumor.bought`.
## Task L (docs/80-* §4.7.8): below the discovery rows the rumors tab also
## carries the aliveness rows — demand-event telegraphs, live-fleet and
## departure/arrival rumors, the captains section, and the wanted posters
## with the 20g exact-position reveal.
func _bind_rumors() -> void:
	_clear(_rumor_rows)
	_rumors = []
	_captain_rows = []
	_poster_rows = []
	_rumor_texts = []
	_invest_rows = []
	# Task L: the active demand events' rest-overrides + telegraph rows are
	# derived from the saved instance list on every rebuild.
	var tournament_status: Dictionary = TournamentLib.status(_port_id, GameState.day)
	_rumor_tournament.text = I18n.fmt("tournament.status", {
		"port": I18n.t(DataLoader.get_port(str(tournament_status.get("host", "")))
			.get("name", {})),
		"first": int(tournament_status.get("window_first", 1)),
		"last": int(tournament_status.get("window_last", 5)),
	})
	var blocked := str(tournament_status.get("blocked", ""))
	if blocked == "tournament.not_host" or blocked == "tournament.closed":
		_rumor_tournament.text += " — %s" % I18n.t_key(blocked)
	_rumor_price.text = I18n.fmt(
		"tavern.rumor.price", {"gold": DiscoveryLib.HINT_PRICE}
	)
	_rumor_empty.text = I18n.t_key("tavern.rumor.none")
	if _port_id.is_empty():
		_rumors = []
	else:
		for discovery_id in DiscoveryLib.hints(_port_id, GameState.day):
			_rumors.append({"id": str(discovery_id)})
	var entries: Array = []
	var index := 0
	for entry in _rumors:
		_build_rumor_row(str(entry["id"]), index, entries)
		index += 1
	index = _bind_aliveness_rows(entries, index)
	_bind_table()
	_bind_spar()
	# The scroll's stacked extent: the plain content Control sized to the
	# rows' total pitch (viewport math, not flow). `_rumor_row_count` is the
	# next free slot (the paid reveal line appends there).
	_rumor_row_count = index
	_rumor_rows.custom_minimum_size = Vector2(
		RUMORS_W * float(TILE),
		maxi(index, 1) * RUMORS_ROW_H * float(TILE))
	_register_dynamic("rumors", entries)
	_rumor_empty.visible = _rumors.is_empty() and _rumor_texts.is_empty()


## The task L rows of the rumors tab, in §4.7.8 order: telegraphs, live
## fleets and departures/arrivals, then the captains section and the posters.
## `index` carries the rumors list's next slot (the hint rows built first).
func _bind_aliveness_rows(entries: Array, index: int) -> int:
	if _port_id.is_empty() or GameState.player.is_empty():
		return index
	for row in NpcIntelLib.rumor_rows(_port_id):
		# Phase 7 (docs/80-* §4.7.14): allegiance investment telegraphs, under
		# their own section header, right after the demand-event rows.
		if str(row.get("kind", "")) == "investment":
			index = _bind_investment_row(row, entries, index)
			continue
		var text := _rumor_text(row)
		if text.is_empty():
			continue
		_rumor_texts.append(text)
		var label := _make_label(text, "RumorAliveness")
		_rumor_rows.add_child(label)
		var rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W,
			RUMORS_ROW_H)
		label.position = rect.position
		label.size = rect.size
		index += 1
		entries.append({
			"control": label,
			"id": "rumors.rows.rumor.%d" % _rumor_texts.size(), "opts": {
				"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
				"list": RUMORS_LIST},
		})
	# Captains sighted in the tavern (§4.7.8), then the gone-ashore notes.
	# Phase 8 (§4.11.1): each sighting row is interactive — the befriend verb
	# (+1 stance, once per captain per port-visit day).
	var captains: Array = NpcIntelLib.sightings(_port_id,
		NpcIntelLib.FACILITY_TAVERN)
	if not captains.is_empty() or not NpcIntelLib.gone_ashore(_port_id).is_empty():
		var header := _make_label(_t_key("captain.section.tavern"),
			"CaptainsHeader")
		_rumor_rows.add_child(header)
		var rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W,
			RUMORS_ROW_H)
		header.position = rect.position
		header.size = rect.size
		index += 1
		# The section header lives INSIDE the rumors list at its own slot —
		# a list member like the rows (its slot is data-derived).
		entries.append({
			"control": header, "id": "rumors.rows.captains_header",
			"opts": {"role": RegistryLib.ROLE_PLAIN, "list": RUMORS_LIST},
		})
		for entry in captains:
			var row_text := "%s · %s" % [str(entry.get("name", "")),
				I18n.t_key("captain.role.%s" % str(entry.get("role", "")))]
			var row := {
				"id": str(entry.get("id", "")),
				"captain_id": str(entry.get("captain_id", "")),
				"name": str(entry.get("name", "")),
				"role": str(entry.get("role", "")),
				"nation_id": str(entry.get("nation_id", "")),
			}
			_captain_rows.append(row)
			index = _build_captain_row(row, row_text, index, entries)
		var ashore_count := 0
		for entry in NpcIntelLib.gone_ashore(_port_id):
			ashore_count += 1
			var ashore := I18n.fmt("captain.gone_ashore",
				{"name": str(entry.get("name", ""))})
			_rumor_texts.append(ashore)
			var label := _make_label(ashore, "CaptainAshore")
			label.theme_type_variation = "Dim"
			_rumor_rows.add_child(label)
			var ashore_rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W,
				RUMORS_ROW_H)
			label.position = ashore_rect.position
			label.size = ashore_rect.size
			index += 1
			entries.append({
				"control": label,
				"id": "rumors.rows.ashore.%d" % ashore_count, "opts": {
					"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
					"list": RUMORS_LIST},
			})
	# Wanted posters within Chebyshev 40 (§4.7.8) — each row carries its own
	# `captain.poster.title` line, so no extra section header is invented.
	var posters: Array = NpcIntelLib.wanted_posters(_port_id)
	if not posters.is_empty():
		for poster in posters:
			_poster_rows.append(poster)
			index = _build_poster_row(poster, index, entries)
	return index


## One rumor row's localized text (the seeded rows come from `npc_intel`).
func _rumor_text(row: Dictionary) -> String:
	var nation_id := str(row.get("nation_id", ""))
	var nation := I18n.t(DataLoader.get_nation(nation_id).get("name", {})) \
		if not nation_id.is_empty() else "-"
	# NOTE: no `captain.role.*` lookup here — the event telegraph rows carry
	# no role and none of the four rumor texts uses one, so a blind lookup
	# would log `unknown ui_strings key 'captain.role.'` per event row.
	match str(row.get("kind", "")):
		"event":
			return I18n.fmt("captain.rumor.event", {
				"port": str(row.get("port_name", "")),
				"event": str(row.get("event_name", "")),
			})
		"fleet":
			return I18n.fmt("captain.rumor.fleet", {
				"nation": nation, "port": str(row.get("nearest_port_name", "")),
			})
		"departed":
			return I18n.fmt("captain.rumor.departed", {
				"nation": nation, "port": str(row.get("dest_port_name", "")),
			})
		"arrived":
			return I18n.fmt("captain.rumor.arrived", {"nation": nation})
	return ""


## One wanted poster (§4.7.8): title (name + tier) with the captain's §4.8
## role badge, last-known position hint, reward hint, and the one
## "buy a round — 20g" reveal action — absolutely-placed children of a plain
## Control at the block's row rect. Returns the next rumors slot.
func _build_poster_row(poster: Dictionary, index: int,
		entries: Array) -> int:
	var id := str(poster.get("id", ""))
	var row := Control.new()
	row.name = "Poster_%s" % id
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rumor_rows.add_child(row)
	var rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W, RUMORS_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var row_id := "rumors.rows.poster.%s" % id
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": RUMORS_LIST},
	})

	# §4.8 role badge (the poster payload carries no role — resolve it from
	# the canon card; an unknown captain renders the flat fallback: no icon).
	var canon: Dictionary = CaptainsLib.captain(str(poster.get("captain_id", "")))
	var badge_icon := _attach_role_badge(row, str(canon.get("role", "")))
	var text_x := 0
	if badge_icon != null:
		_place(badge_icon, ROW_BADGE_RECT)
		text_x = 1
	var title := _make_label(I18n.fmt("captain.poster.title", {
		"name": str(poster.get("name", "")),
		"tier": int(poster.get("tier", 1)),
	}), "Title")
	# The §4.8 danger tint marks a wanted poster (the theme's `Bad`
	# variation).
	title.theme_type_variation = "Bad"
	row.add_child(title)
	_place(title, Rect2i(text_x, 0, ROW_TEXT_W + 1 - text_x, 1))

	var hint := _make_label("%s · %s" % [
		I18n.fmt("captain.poster.hint", {
			"port": str(poster.get("nearest_port_name", ""))}),
		I18n.fmt("captain.poster.reward", {
			"gold": int(poster.get("reward_gold", 0))}),
	], "Hint")
	hint.theme_type_variation = "Dim"
	row.add_child(hint)
	_place(hint, Rect2i(text_x, 1, ROW_TEXT_W + 1 - text_x, 1))

	var button := UiKitLib.button("captain.reveal.buy")
	button.name = "Reveal"
	if _revealed.has(id):
		# §4.7.8: one action per poster — the position is already known.
		button.disabled = true
	else:
		button.pressed.connect(func() -> void: buy_reveal(id))
	row.add_child(button)
	_place(button, ROW_VERB_RECT)
	return index + 1


## The paid reveal (§4.7.8): one action per poster — "buy a round — 20g" →
## the captain's EXACT live position (tile + nearest port) as rumor text.
## Text only; no chart ping (Phase-6 candidate). Returns the text ("" on
## refusal — short of gold — which also toasts `captain.reveal.no_gold`).
func buy_reveal(fleet_id: String) -> String:
	var position: Dictionary = NpcIntelLib.reveal_position(fleet_id)
	if position.is_empty():
		return ""
	if _revealed.has(fleet_id):
		return ""  # one action per poster (§4.7.8)
	if GameState.gold < NpcIntelLib.REVEAL_COST:
		_show_toast("captain.reveal.no_gold")
		return ""
	# Set before the charge: add_gold fires gold_changed, which rebuilds the
	# tab synchronously — the fresh row must already show the button spent.
	_revealed[fleet_id] = true
	GameState.add_gold(-NpcIntelLib.REVEAL_COST)
	var cell: Vector2i = position.get("cell", Vector2i.ZERO)
	last_reveal_text = I18n.fmt("captain.reveal.text", {
		"name": str(position.get("name", "")),
		"x": cell.x, "y": cell.y,
		"port": str(position.get("nearest_port_name", "")),
	})
	_rumor_texts.append(last_reveal_text)
	var label := _make_label(last_reveal_text, "RevealText")
	_rumor_rows.add_child(label)
	var rect := _list_row_rect(RUMORS_LIST, _rumor_row_count, RUMORS_W,
		RUMORS_ROW_H)
	label.position = rect.position
	label.size = rect.size
	return last_reveal_text


## One investment telegraph (Phase 7, docs/80-* §4.7.14): the first row lays
## down the `tavern.invest.header` section header, then the row itself as
## `tavern.invest.row` — `{nation} 在 {port} 投资 {amount} 金` (the names and
## amount are supplied by the `npc_intel.gd` guard read). Returns the next
## rumors slot.
func _bind_investment_row(row: Dictionary, entries: Array,
		index: int) -> int:
	if _invest_rows.is_empty():
		var header := _make_label(I18n.t_key("tavern.invest.header"),
			"InvestHeader")
		_rumor_rows.add_child(header)
		var rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W, RUMORS_ROW_H)
		header.position = rect.position
		header.size = rect.size
		index += 1
		entries.append({
			"control": header, "id": "rumors.rows.invest_header",
			"opts": {"role": RegistryLib.ROLE_PLAIN,
				"list": RUMORS_LIST},
		})
	var text := I18n.fmt("tavern.invest.row", {
		"nation": str(row.get("nation_name", "-")),
		"port": str(row.get("port_name", "-")),
		"amount": int(row.get("amount", 0)),
	})
	_invest_rows.append({
		"port_id": str(row.get("port_id", "")),
		"nation_id": str(row.get("nation_id", "")),
		"amount": int(row.get("amount", 0)),
		"days_left": int(row.get("days_left", -1)),
		"text": text,
	})
	_rumor_texts.append(text)
	var label := _make_label(text, "InvestRow")
	_rumor_rows.add_child(label)
	var row_rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W, RUMORS_ROW_H)
	label.position = row_rect.position
	label.size = row_rect.size
	index += 1
	entries.append({
		"control": label, "id": "rumors.rows.invest.%d" % _invest_rows.size(),
		"opts": {"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": RUMORS_LIST},
	})
	return index


## The investment telegraph rows currently rendered (the seams a headless
## test reads — the captains-pattern).
func invest_rows() -> Array:
	return _invest_rows.duplicate()


## The aliveness seams (§4.7.8) — rows a headless test reads without widget
## reach-in.
func captain_rows() -> Array:
	return _captain_rows.duplicate()


func poster_rows() -> Array:
	return _poster_rows.duplicate()


func rumor_texts() -> Array:
	return _rumor_texts.duplicate()


# --- Phase-8 W5-C: row verbs, the captains' table, sparring (§4.11) ---------

## One tavern sighting row: a plain Control at the block's row rect — the
## §4.7.8 text with the captain's §4.8 role badge plus the 交好 befriend verb
## (+1 stance, once per captain per port-visit day — the hail rule) as
## absolutely-placed children. Disabled rows gray-render with their
## `hail.befriend.used` term. Returns the next rumors slot.
func _build_captain_row(row_data: Dictionary, row_text: String,
		index: int, entries: Array) -> int:
	var row := Control.new()
	row.name = "Captain_%s" % str(row_data["id"])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rumor_rows.add_child(row)
	var rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W, RUMORS_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var badge_icon := _attach_role_badge(row, str(row_data.get("role", "")))
	var text_x := 0
	if badge_icon != null:
		_place(badge_icon, ROW_BADGE_RECT)
		text_x = 1

	var text := _make_label(row_text, "Text")
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text)
	_place(text, Rect2i(text_x, 0, ROW_TEXT_W + 1 - text_x, 2))

	var button := UiKitLib.button("hail.option.befriend")
	button.name = "Befriend"
	button.tooltip_text = I18n.t_key("hail.befriend.terms")
	var captain_id := str(row_data.get("captain_id", ""))
	if not TavernEngineLib.can_befriend(captain_id, _port_id):
		button.disabled = true
		button.tooltip_text = I18n.t_key("hail.befriend.used")
	else:
		button.pressed.connect(func() -> void: befriend_captain(captain_id,
			str(row_data.get("name", ""))))
	row.add_child(button)
	_place(button, ROW_VERB_RECT)
	var row_id := "rumors.rows.captain.%s" % str(row_data["id"])
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": RUMORS_LIST},
	})
	return index + 1


## The befriend verb (§4.11.1): stance +1 through the engine's visit guard,
## then the `hail.befriend.result` toast. Returns the new stance.
func befriend_captain(captain_id: String, captain_name: String) -> int:
	var stance := TavernEngineLib.befriend(captain_id, _port_id)
	_show_toast("hail.befriend.result", {"name": captain_name})
	refresh()
	return stance


## Builds the captains'-table and sparring section shells once, under the
## rumors panel at their authored rects (plain Controls — nothing inside
## them is flow-laid; the §4.7.8-pinned `Scroll/Rows` children stay
## untouched).
func _build_table_and_spar_sections() -> void:
	_table_box = Control.new()
	_table_box.name = "CaptainsTable"
	_table_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rumors_panel.add_child(_table_box)
	_place(_table_box, Rect2i(0, 17, 58, 3))
	_spar_box = Control.new()
	_spar_box.name = "SparRow"
	_spar_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rumors_panel.add_child(_spar_box)
	_place(_spar_box, Rect2i(0, 20, 58, 4))


## The captains'-table rows currently rendered (the headless seam).
func table_rows() -> Array:
	return _table_rows.duplicate()


## THIS port's captain sightings across every facility (the §4.11.2 index):
## docked, present, captain-bearing; one row per sighting with the facility
## pointer naming where that captain can be found right now. Composed from
## npc_intel's seeded rolls without the `sightings()` familiarity side
## effect — the table must not double-charge what the facility rows charge.
func _port_sighting_rows() -> Array:
	var out: Array = []
	if _port_id.is_empty() or GameState.player.is_empty():
		return out
	for fleet in NpcIntelLib.docked_fleets(_port_id):
		if not NpcIntelLib.is_present(fleet, _port_id):
			continue
		var captain_id := str(fleet.get("captain_id", ""))
		if captain_id.is_empty():
			continue
		var canon := CaptainsLib.captain(captain_id)
		out.append({
			"captain_id": captain_id,
			"fleet_id": str(fleet.get("id", "")),
			"name": I18n.t(canon.get("name", {})),
			"role": str(fleet.get("role", "")),
			"tier": int(canon.get("tier", 1)),
			"nation_id": str(fleet.get("nation_id", "")),
			"facility": NpcIntelLib.facility_of(fleet, _port_id),
			"last_seen_day": NpcIntelLib.arrival_day_of(fleet),
		})
	out.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("fleet_id", "")) \
			< str((b as Dictionary).get("fleet_id", "")))
	return out


## Binds the captains' table (§4.11.2): one row per sighted captain — name
## (canon), role/tier, last-seen day and the "now at: {facility}" pointer —
## each with an inspect action (+1 familiarity per view; the unified card is
## W6-A's, so the placeholder renders a summary line).
func _bind_table() -> void:
	if _table_box == null:
		return
	_clear(_table_box)
	_table_rows = []
	last_inspect_text = ""
	var header := _make_label(I18n.t_key("captain.table.title"), "TableHeader")
	_table_box.add_child(header)
	_place(header, Rect2i(0, 0, TABLE_W, 1))
	_table_rows = _port_sighting_rows()
	var entries: Array = [{
		"control": header, "id": "captains_table.header",
		"opts": {"role": RegistryLib.ROLE_PLAIN},
	}]
	if _table_rows.is_empty():
		var empty := _make_label(I18n.t_key("captain.table.empty"), "Empty")
		empty.theme_type_variation = "Dim"
		_table_box.add_child(empty)
		# The empty marker is a `table` LIST MEMBER placed at the
		# block's row 0 (builder-owned placement — the coverage check
		# exempts list members; docs/80-* §4.8.9).
		var rect := _list_row_rect(TABLE_LIST, 0, TABLE_W, TABLE_ROW_H)
		empty.set_anchors_preset(Control.PRESET_TOP_LEFT)
		empty.position = rect.position
		empty.size = rect.size
		entries.append({
			"control": empty, "id": "captains_table.empty",
			"opts": {"role": RegistryLib.ROLE_PLAIN,
				"list": TABLE_LIST},
		})
		_register_dynamic("table", entries)
		return
	var index := 0
	for row in _table_rows:
		_build_table_row(row, index, entries)
		index += 1
	_register_dynamic("table", entries)


## One captains'-table row: a plain Control at the block's row rect — the
## §4.8 role badge, the index text and the inspect verb as absolutely-placed
## children (a `table` list member; parts unregistered).
func _build_table_row(row_data: Dictionary, index: int,
		entries: Array) -> void:
	var row := Control.new()
	row.name = "TableRow_%s" % str(row_data["captain_id"])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_table_box.add_child(row)
	var rect := _list_row_rect(TABLE_LIST, index, TABLE_W, TABLE_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var badge_icon := _attach_role_badge(row, str(row_data.get("role", "")))
	var text_x := 0
	if badge_icon != null:
		_place(badge_icon, ROW_BADGE_RECT)
		text_x = 1

	var facility_key := "port.%s" % str(row_data.get("facility", ""))
	var facility_name := I18n.t_key(facility_key)
	var text := "%s · %s · %s %d · %s · %s" % [
		str(row_data.get("name", "")),
		I18n.t_key("captain.role.%s" % str(row_data.get("role", ""))),
		I18n.t_key("captain.table.tier"), int(row_data.get("tier", 1)),
		I18n.fmt("captain.table.last_seen",
			{"day": int(row_data.get("last_seen_day", 0))}),
		I18n.fmt("captain.table.at", {"facility": facility_name}),
	]
	var label := _make_label(text, "Text")
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	_place(label, Rect2i(text_x, 0, ROW_TEXT_W + 1 - text_x, 2))

	var button := UiKitLib.button("interact.verb.inspect")
	button.name = "Inspect"
	button.pressed.connect(func() -> void: inspect_captain(
		str(row_data.get("captain_id", ""))))
	row.add_child(button)
	_place(button, ROW_VERB_RECT)
	var row_id := "captains_table.rows.%s" % str(row_data["captain_id"])
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": TABLE_LIST},
	})


## The inspect action (§4.11.2): +1 familiarity per view, then the placeholder
## summary line (name · role · tier · familiarity — the §4.12 unified card is
## W6-A's). Returns the composed summary.
func inspect_captain(captain_id: String) -> String:
	CaptainsLib.add_familiarity(captain_id, 1)
	var canon := CaptainsLib.captain(captain_id)
	var role := str(canon.get("role", ""))
	var summary := "%s · %s · %s %d · %s %d" % [
		I18n.t(canon.get("name", {})),
		I18n.t_key("captain.role.%s" % role) if not role.is_empty() else "-",
		I18n.t_key("captain.table.tier"), int(canon.get("tier", 1)),
		I18n.t_key("dossier.familiarity"), CaptainsLib.familiarity(captain_id),
	]
	last_inspect_text = summary
	# The summary rides under the rows as the placeholder detail line (the
	# next free table slot).
	if _table_box != null:
		var detail := _make_label(summary, "InspectSummary")
		_table_box.add_child(detail)
		var rect := _list_row_rect(TABLE_LIST, _table_rows.size(), TABLE_W,
			TABLE_ROW_H)
		detail.position = rect.position
		detail.size = rect.size
	return summary


## The stake the steppers currently offer.
func spar_stake_value() -> int:
	return _spar_stake


## Steppers: ±100g inside the locked 100–1,000 band (§4.11.1).
func spar_stake_step(direction: int) -> int:
	_spar_stake = TavernEngineLib.spar_step(_spar_stake, direction)
	_bind_spar()
	return _spar_stake


## The bout roll: one draw from the seeded per-(port, visit-day) stream.
func _spar_roll() -> float:
	var key := "%s|%d" % [_port_id, int(GameState.day)]
	if key != _spar_seed_key:
		_spar_seed_key = key
		_spar_rng.seed = hash("spar|%s" % key)
	return _spar_rng.randf()


## The sparring bet (§4.11.1): the row's current stake, one seeded roll.
## Returns the bout result (`{}` when the engine refused — invalid band or
## short purse, which also toasts the reuseable `captain.reveal.no_gold`).
func place_spar_bet() -> Dictionary:
	var roll := _spar_roll()
	_busy = true
	var result: Dictionary = TavernEngineLib.spar(_spar_stake, roll)
	_busy = false
	if result.is_empty():
		_show_toast("captain.reveal.no_gold")
		refresh()
		return {}
	last_spar = result.duplicate()
	last_spar["roll"] = roll
	refresh()
	return last_spar


## Appends the bout's result line (the win/lose `tavern.spar.*` texts with
## the gold amount composed in) into the persistent `spar.result` slot —
## right of the terms line. `_bind_spar` re-fills it after every rebuild,
## so the line survives the `gold_changed` refresh. Returns the line (the
## spar registration's read).
func _append_spar_result(result: Dictionary) -> Control:
	if _spar_box == null:
		return null
	var key := "tavern.spar.win" if bool(result.get("won", false)) \
		else "tavern.spar.lose"
	var gold := TavernEngineLib.spar_pot(int(result.get("stake", 0))) \
		if bool(result.get("won", false)) else int(result.get("stake", 0))
	var line := _spar_box.get_node_or_null("SparResult")
	if line == null:
		# No bind yet (the bout precedes the first bind): build the
		# persistent slot now; the next rebuild re-uses it.
		line = _make_label("", "SparResult")
		_spar_box.add_child(line)
		_place(line, SPAR_RESULT_RECT)
		RegistryLib.register(LAYOUT_SCREEN, line, "spar.result",
			{"role": RegistryLib.ROLE_PLAIN})
	_fill_spar_result(line, result)
	line.visible = true
	return line


## One result line's text + §4.8 tier tint (the theme's `Good`/`Warn`
## variations).
func _fill_spar_result(line: Control, result: Dictionary) -> void:
	var key := "tavern.spar.win" if bool(result.get("won", false)) \
		else "tavern.spar.lose"
	var gold := TavernEngineLib.spar_pot(int(result.get("stake", 0))) \
		if bool(result.get("won", false)) else int(result.get("stake", 0))
	line.text = _fmt(key, {"gold": gold})
	# The bout outcome's §4.8 tier tint rides the theme's `Good` / `Warn`
	# variations.
	line.theme_type_variation = "Good" if bool(result.get("won", false)) \
		else "Warn"


## Rebinds the sparring row from state: the title, the stake + win-chance
## terms line (the §4.11.1 "carries its terms inline" rule), the steppers and
## the bet button (disabled with `captain.reveal.no_gold` when short) — all
## registered statics at their authored slots.
func _bind_spar() -> void:
	if _spar_box == null:
		return
	_clear(_spar_box)
	var entries: Array = []
	var header := _make_label(_t_key("tavern.spar.title"), "SparHeader")
	_spar_box.add_child(header)
	_place(header, Rect2i(0, 0, 58, 1))
	entries.append({
		"control": header, "id": "spar.header",
		"opts": {"role": RegistryLib.ROLE_PLAIN},
	})

	var chance := TavernEngineLib.spar_win_chance(
		SkillsLib.effective_skill("swordplay"))
	var terms := _make_label(_fmt("tavern.spar.stake", {
		"gold": _spar_stake,
		"pct": int(round(chance * 100.0)),
	}), "SparTerms")
	_spar_box.add_child(terms)
	_place(terms, Rect2i(0, 1, 29, 1))
	entries.append({
		"control": terms, "id": "spar.terms",
		"opts": {"role": RegistryLib.ROLE_PLAIN},
	})

	var down := Button.new()
	down.name = "StakeDown"
	down.text = "−"
	down.pressed.connect(spar_stake_step.bind(-1))
	_spar_box.add_child(down)
	_place(down, Rect2i(0, 2, 2, 2))
	var up := Button.new()
	up.name = "StakeUp"
	up.text = "+"
	up.pressed.connect(spar_stake_step.bind(1))
	_spar_box.add_child(up)
	_place(up, Rect2i(2, 2, 2, 2))
	var bet := Button.new()
	bet.name = "SparBet"
	bet.text = _t_key("tavern.spar.go")
	bet.tooltip_text = _fmt("tavern.spar.stake", {
		"gold": _spar_stake,
		"pct": int(round(chance * 100.0)),
	})
	if not TavernEngineLib.can_spar(_spar_stake):
		bet.disabled = true
		bet.tooltip_text = I18n.t_key("captain.reveal.no_gold")
	else:
		bet.pressed.connect(place_spar_bet)
	_spar_box.add_child(bet)
	_place(bet, Rect2i(5, 2, 7, 2))
	entries.append_array([
		{"control": down, "id": "spar.controls.stake_down",
			"opts": {"role": RegistryLib.ROLE_BUTTON}},
		{"control": up, "id": "spar.controls.stake_up",
			"opts": {"role": RegistryLib.ROLE_BUTTON}},
		{"control": bet, "id": "spar.controls.bet",
			"opts": {"role": RegistryLib.ROLE_BUTTON}},
	])

	# The result slot is a PERSISTENT registered static (the guild's
	# `offers.empty` pattern): the label exists every rebuild, hidden
	# until a bout has run — the seeded capture never sees a bout, so a
	# conditionally-registered id would carry no rect row and fire the
	# coverage fallback after every real bout (the empty-marker class).
	var result := _make_label("", "SparResult")
	result.theme_type_variation = "Good"
	result.visible = false
	_spar_box.add_child(result)
	_place(result, SPAR_RESULT_RECT)
	entries.append({
		"control": result, "id": "spar.result",
		"opts": {"role": RegistryLib.ROLE_PLAIN},
	})

	# The latest bout's result survives every rebuild (the reveal-text
	# discipline: the answer stays after the refresh).
	if not last_spar.is_empty():
		_fill_spar_result(result, last_spar)
		result.visible = true
	_register_dynamic("spar", entries)


func _build_rumor_row(discovery_id: String, index: int,
		entries: Array) -> void:
	var discovery: Dictionary = DataLoader.get_discovery(discovery_id)
	var hinted := DiscoveryLib.is_hinted(discovery_id)
	var row := Control.new()
	row.name = "Rumor_%s" % discovery_id
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rumor_rows.add_child(row)
	var rect := _list_row_rect(RUMORS_LIST, index, RUMORS_W, RUMORS_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var row_id := "rumors.rows.%s" % discovery_id
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": RUMORS_LIST},
	})

	# The §4.8 `scroll` icon marks the purchasable rumor (a natural slot at
	# the row's head; an absent id renders nothing — the flat fallback).
	var scroll_icon := _attach_scroll_badge(row)
	var text_x := 0
	if scroll_icon != null:
		_place(scroll_icon, Rect2i(0, 0, 1, 2))
		text_x = 1
	var hint := _make_label(I18n.t(DiscoveryLib.hint_text(discovery_id)), "Hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(hint)
	_place(hint, Rect2i(text_x, 0, ROW_TEXT_W + 1 - text_x, 1))

	# The 100g buys the *location*: the name appears only once hinted
	# (docs/80-* §4.7.3).
	var name_label := _make_label(
		I18n.t(discovery.get("name", {})) if hinted else "?", "Name"
	)
	name_label.theme_type_variation = "" if hinted else "Dim"
	row.add_child(name_label)
	_place(name_label, Rect2i(text_x, 1, ROW_TEXT_W + 1 - text_x, 1))

	var button := UiKitLib.button("tavern.rumor.buy")
	button.name = "Buy"
	button.tooltip_text = I18n.fmt(
		"tavern.rumor.price", {"gold": DiscoveryLib.HINT_PRICE}
	)
	if hinted:
		button.text = I18n.t_key("tavern.rumor.bought")
		button.disabled = true
	elif GameState.gold < DiscoveryLib.HINT_PRICE:
		button.disabled = true
		button.tooltip_text = I18n.t_key("tavern.rumor.no_gold")
	else:
		button.pressed.connect(func() -> void: buy_rumor(discovery_id))
	row.add_child(button)
	_place(button, ROW_VERB_RECT)


## Prepends the §4.8 `scroll` hero to a rumor row head (the hero-64 rule:
## 1:1 64); an absent id adds nothing (the flat fallback). Returns the badge
## icon unplaced — the caller places it at the row's badge slot.
func _attach_scroll_badge(row: Control) -> Control:
	var texture := UiKitLib.hero_texture("scroll")
	if texture == null:
		return null
	var icon := TextureRect.new()
	icon.name = "ScrollBadge"
	icon.texture = texture
	icon.custom_minimum_size = Vector2(64, 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(icon)
	return icon


## Prepends the §4.8 `role_{role}` badge to a sighting/poster row; an absent
## id or an unknown role adds nothing (the flat fallback). Returns the badge
## icon unplaced — the caller places it at the row's badge slot.
func _attach_role_badge(row: Control, role: String) -> Control:
	if role.is_empty():
		return null
	var texture := UiKitLib.hero_texture("role_%s" % role)
	if texture == null:
		return null
	var icon := TextureRect.new()
	icon.name = "RoleBadge"
	icon.texture = texture
	icon.custom_minimum_size = Vector2(32, 32)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(icon)
	return icon


# --- Layout id registry (docs/80-UI-UX.md §4.8.9, Phase-11 W4-C) -------------

## Registers every persistent control with its stable hierarchical id. The
## statics carry the authored rects above (the capture emits them as the
## screen's fragment); the four dynamic lists' rows (recruitable, roster,
## rumors, table) are list members — their ids carry the `list` flag and
## take `list_rect` positions.
func _register_layout() -> void:
	_reg($Background, "background", RegistryLib.ROLE_PANEL)
	_reg(_header, "header", RegistryLib.ROLE_PLAIN)
	_reg(_title, "header.title", RegistryLib.ROLE_PLAIN)
	_reg(_gold, "header.gold", RegistryLib.ROLE_PLAIN)
	_reg(_back_button, "header.back", RegistryLib.ROLE_BUTTON)
	_reg(_tabs, "tabs", RegistryLib.ROLE_PLAIN)
	_reg(_crew_tab, "tabs.crew", RegistryLib.ROLE_BUTTON)
	_reg(_officers_tab, "tabs.officers", RegistryLib.ROLE_BUTTON)
	_reg(_rumors_tab, "tabs.rumors", RegistryLib.ROLE_BUTTON)
	_reg(_body, "body", RegistryLib.ROLE_PLAIN)
	_reg(_crew_panel, "crew", RegistryLib.ROLE_PLAIN)
	_reg(_crew_count, "crew.count", RegistryLib.ROLE_PLAIN)
	_reg(_morale, "crew.morale", RegistryLib.ROLE_PLAIN)
	_reg(_per_head, "crew.per_head", RegistryLib.ROLE_PLAIN)
	_reg(_hire_row, "crew.hire_row", RegistryLib.ROLE_PLAIN)
	_reg(_hire_1, "crew.hire_row.hire_1", RegistryLib.ROLE_BUTTON)
	_reg(_hire_10, "crew.hire_row.hire_10", RegistryLib.ROLE_BUTTON)
	_reg(_fill, "crew.hire_row.fill", RegistryLib.ROLE_BUTTON)
	_reg(_fire_row, "crew.fire_row", RegistryLib.ROLE_PLAIN)
	_reg(_fire_1, "crew.fire_row.fire_1", RegistryLib.ROLE_BUTTON)
	_reg(_fire_10, "crew.fire_row.fire_10", RegistryLib.ROLE_BUTTON)
	_reg(_down_to_min, "crew.fire_row.down_to_min", RegistryLib.ROLE_BUTTON)
	_reg(_reason, "crew.reason", RegistryLib.ROLE_PLAIN)
	_reg(_min_note, "crew.min_note", RegistryLib.ROLE_PLAIN)
	_reg(_officers_panel, "officers", RegistryLib.ROLE_PLAIN)
	_reg(_recruitable_scroll, "officers.recruitable_scroll",
		RegistryLib.ROLE_PLAIN)
	_reg(_roster_header, "officers.roster_header", RegistryLib.ROLE_PLAIN)
	_reg(_roster_scroll, "officers.roster_scroll", RegistryLib.ROLE_PLAIN)
	_reg(_officer_reason, "officers.reason", RegistryLib.ROLE_PLAIN)
	_reg(_rumors_panel, "rumors", RegistryLib.ROLE_PLAIN)
	_reg(_rumor_tournament, "rumors.tournament", RegistryLib.ROLE_PLAIN)
	_reg(_rumor_price, "rumors.price", RegistryLib.ROLE_PLAIN)
	_reg(_rumor_scroll, "rumors.scroll", RegistryLib.ROLE_PLAIN)
	_reg(_rumor_empty, "rumors.empty", RegistryLib.ROLE_PLAIN)
	_reg(_table_box, "captains_table", RegistryLib.ROLE_PLAIN)
	_reg(_spar_box, "spar", RegistryLib.ROLE_PLAIN)


## One static registration — kind omitted (auto-derives from the parent).
func _reg(control: Control, id: String, role: String) -> void:
	RegistryLib.register(LAYOUT_SCREEN, control, id, {"role": role})


## Registers one rebuilt dynamic row set (the rumor/aliveness/captain/poster
## rows, the officers lists, the captains' table, the sparring row, the
## morale bar). `entries` = [{control, id, opts}]. A section's FIRST build
## registers synchronously — inside `_ready`, ahead of `screen_active`, so
## the activation walk captures the rows' baselines. A REbuild defers one
## frame: the cleared rows are queue_freed but still live within this frame,
## and a same-frame re-register would read as a duplicate id — after the
## frame's delete flush the same-id replacement is silent. A pass whose
## screen died meanwhile has only dead nodes to visit: the instance-bound
## one-shot dies with it (nothing left to register). (The buy-reveal text
## line is not registered: `buy_reveal` appends it and the same-frame
## `gold_changed` refresh clears it again, so it never survives a frame.)
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
	return label


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


## Re-tiered kit value_bar beside the morale line (§4.9: the atom bakes the
## tier into its fill at build time, so a changed morale rebuilds it).
func _refresh_morale_bar() -> void:
	var parent := _morale.get_parent()
	if _morale_bar != null and is_instance_valid(_morale_bar):
		parent.remove_child(_morale_bar)
		_morale_bar.queue_free()
	var tier := UiKitLib.auto_tier(GameState.morale, MORALE_GOOD_MIN,
		MORALE_WARN_MIN)
	_morale_bar = UiKitLib.value_bar(GameState.morale, 100, tier)
	parent.add_child(_morale_bar)
	_place(_morale_bar, Rect2i(0, 2, 58, 1))
	_register_dynamic("morale_bar", [{
		"control": _morale_bar, "id": "crew.morale_bar",
		"opts": {"role": RegistryLib.ROLE_PLAIN},
	}])


## Transient action feedback (docs/80-* §4.7) through the kit toast atom
## (§4.9/§4.7.17: bottom-center, max 1 visible, the pinned fades; the atom
## owns its lifecycle). Missing keys show nothing so a not-yet-merged key
## never spams errors.
func _show_toast(key: String, values: Dictionary = {}) -> void:
	if not DataLoader.ui_strings.has(key):
		return
	UiKitLib.toast(self, I18n.fmt(key, values))


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


# --- §4.12.1 (W6-A): the recruit dialog (inner class) -----------------------

## The recruit dialog: dim + panel + the §4.12 officer card + the shared
## recruit path and the close edge. Code-built chrome (the §4.11 sections'
## pattern); owns all input while open (§6), Esc closes.
class RecruitDialog:
	extends Control

	const DIM_ALPHA := 0.4
	const MODAL_GROUP := "modal_overlay"
	# Inner classes see autoloads and global classes but NOT the outer
	# script's consts — the preloads are re-declared here (the cold class
	# cache stays harmless: the preloads win over `Palette`/`Character`).
	const PaletteLib := preload("res://scripts/palette.gd")
	const UiKitLib := preload("res://scripts/ui_kit.gd")
	const CharacterLib := preload("res://scripts/player/character.gd")
	const CardLib := preload("res://scenes/ui/character_card.gd")

	var tavern: Control = null
	var _officer_id: String = ""
	var _open := false
	var _card: Control = null
	var _dim: ColorRect
	var _title: Label
	var _recruit: Button
	var _close: Button

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_anchors_preset(Control.PRESET_FULL_RECT)
		_dim = ColorRect.new()
		_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		_dim.color = Color(0, 0, 0, DIM_ALPHA)
		add_child(_dim)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(center)
		# Phase-10 sweep: the dialog reuses the kit frame's chrome (titled
		# panel + margin body); the frame's header label doubles as the
		# officer-name title (its text is bound in [method open]).
		var panel := UiKitLib.frame("tavern.crew_tab")
		panel.custom_minimum_size = Vector2(520, 0)
		center.add_child(panel)
		var frame_box := panel.get_child(0) as VBoxContainer
		_title = frame_box.get_child(0) as Label
		_title.name = "Title"
		var body: VBoxContainer = panel.get_meta(UiKitLib.META_BODY)
		body.name = "Body"
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, 380)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		body.add_child(scroll)
		# The card drops in here at open (kind-specific build).
		_card = (load(CardLib.SCENE_PATH) as PackedScene).instantiate()
		_card.name = "Card"
		scroll.add_child(_card)
		_recruit = UiKitLib.button("tavern.recruit")
		_recruit.name = "Recruit"
		_recruit.custom_minimum_size = Vector2(160, PaletteLib.BUTTON_H)
		_recruit.pressed.connect(_on_recruit_pressed)
		_close = UiKitLib.button("ui.close", "quiet")
		_close.name = "Close"
		_close.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
		_close.pressed.connect(close)
		body.add_child(UiKitLib.footer([_recruit, _close]))

	## Opens on `officer_id`, rendering the §4.12 officer card.
	func open(officer_id: String) -> void:
		_officer_id = officer_id
		var officer: Dictionary = DataLoader.get_officer(officer_id)
		_title.text = I18n.t(officer.get("name", {}))
		_open = true
		visible = true
		add_to_group(MODAL_GROUP)
		_refresh()
		_recruit.disabled = not CharacterLib.can_recruit(officer_id)
		if _recruit.disabled:
			_recruit.tooltip_text = I18n.t_key("market.no_gold")
		_close.grab_focus()

	func close() -> void:
		if not _open:
			return
		_open = false
		visible = false
		remove_from_group(MODAL_GROUP)

	func is_open() -> bool:
		return _open

	## The rendered card's data dictionary (the card-identity pin's read).
	func card_data() -> Dictionary:
		return _card.rendered_data() if _card != null else {}

	func _unhandled_input(event: InputEvent) -> void:
		if not _open:
			return
		if event.is_action_pressed("back"):
			get_viewport().set_input_as_handled()
			close()
			return
		get_viewport().set_input_as_handled()

	## The shared recruit path — the same `TavernScreen.recruit_officer` the
	## row's button calls (one signing funnel; the toast/refresh behavior
	## cannot drift between the two surfaces). A successful signing closes
	## the dialog (`_after_recruit`).
	func _on_recruit_pressed() -> void:
		if tavern == null or not tavern.has_method("recruit_officer"):
			return
		var ok: bool = tavern.recruit_officer(_officer_id)
		if ok:
			close()

	func _refresh() -> void:
		if _card == null or _officer_id.is_empty():
			return
		_card.setup_person(CardLib.KIND_OFFICER, CardLib.card_data(
			CardLib.KIND_OFFICER, _officer_id))
