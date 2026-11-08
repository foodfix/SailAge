# 80 — UI / UX

## 1. Purpose & Phase

Specifies the screen inventory and navigation graph, input scheme,
dialog/text conventions, the sailing HUD layout, the Chart screen (S17),
save/load UX, the `ui_strings.json` key inventory, and the placeholder-art
palette + sizing grid. Gates Phase 1 for the listed screens; Phase-2/3 screens
are named and marked; Phase 4 adds S17 (Chart). Phase 5 adds **S19
(settings modal)** — which owns the sea-traffic density dial (the S2
density row was removed 2026-10-31, §4.6.3) — the market
stock/trend/marginal-price columns,
world-map fleet markers with wakes and the wreck icon, and the captain
sighting surfaces (§4.5.2, §4.6.3, §4.7.7–§4.7.9). Phase 6 adds the two
input modes (Step/Helm), the sail-trim and wait-at-sea keys, the seasonal
HUD indicators, the chart wind/current/ice layers, the S19 input/current/
debug rows and the omniscient debug chart (§4.3, §4.5, §4.6, §4.6.3,
§4.7.10). Phase 7 adds the trade-empire surfaces — market listing/特产/
tariff/invest-gate rows, shipyard role labels + three row states, palace
permit row + commendation dialog, tavern investment telegraphs
(§4.7.11–§4.7.15) — and pins the W3/W4 symbol contracts (§4.16). Phase 8
(the RPG overhaul) adds the right-click interaction layer — the fleet
picker, the hail modal and the port context menu (§4.10) — the in-port
verb matrices, the captain's table and the dossier panel (§4.11), the
unified character card + allocation UX + the character-panel rework
(§4.12), the two-step creation screen S20 (§4.13), the retirement-screen
RPG segment (§4.14), and the Phase-8 `ui_strings` family inventory
(§4.15).

## 2. Artifacts

| Path | Contents |
|---|---|
| `data/ui_strings.json` | every UI-frame L10nString, keyed (§4.4) |
| `scenes/ui_shared/dialog_box.tscn` | modal message dialog |
| `scenes/ui_shared/confirm_dialog.tscn` | modal yes/no dialog |
| `scenes/ui_shared/hud.tscn` | shared HUD (world + port) |
| `scenes/ui_shared/intel_window.tscn` | the 情报 window (§4.5) hosting `captain_view` / `officer_roster_view` / `fleet_view` + the 委托 list + the S17 launcher |
| `scenes/world/chart_screen.tscn` | full-screen Chart (S17, §4.6) |
| `scenes/ui/character_card.tscn` | unified character card — renders any Person (player / officer / NPC captain; §4.12) |
| `scenes/world/fleet_picker.tscn` | right-click fleet verb picker (§4.10.1) |
| `scenes/world/hail_modal.tscn` | at-sea hail modal (§4.10.2) |
| `scenes/world/autopilot_hud.tscn` | appointed-voyage HUD bar, instanced into the world HUD (§4.10.4) |
| `scenes/title/creation_screen.tscn` | S20 creation — background + free points (§4.13) |
| dossier panel | card-external info layer: full card + career log (§4.11.3) |
| all `scenes/**` screens | per `90-*` §4 tree, content per docs 30/50 |
| Save UX | title-screen Load / S19 Save (§4.6.3, §4.7) |

## 3. Dependencies

`00-*` (demo loop, i18n rule), `90-*` (scene flow, window settings),
`20/30/40/50` for the data each screen shows.

## 4. Systems / Mechanics

### 4.1 Screen inventory

| # | Screen | Scene | Phase |
|---|---|---|---|
| S1 | Title | `title_screen.tscn` | 1 |
| S2 | Nationality select | `nationality_select.tscn` | 1 |
| S3 | World map (sailing) | `world_map.tscn` | 1 |
| S4 | Port hub | `port_screen.tscn` | 1 |
| S5 | Market | `market_screen.tscn` | 1 |
| S6 | Shipyard | `shipyard_screen.tscn` | 1 |
| S7 | Tavern | `tavern_screen.tscn` | 1 |
| S8 | Inn | `inn_screen.tscn` | 1 |
| S9 | Game over | `ui_shared/gameover_screen.tscn` (modal over any run-hosting scene — world, port hub, every facility screen; full-scene amendment 2026-11-02) | 1 |
| S10 | Battle | `scenes/combat/battle_screen.tscn` | 2 |
| S11 | Duel | `scenes/combat/duel_modal.tscn` (modal over S10) | 2 |
| S12 | Guild | `guild_screen.tscn` | 3 |
| S13 | Palace | `palace_screen.tscn` | 3 |
| S14 | ~~Character/status panel~~ **retired 2026-11-03** — the 船长 page lives on as the intel window's 船长 tab (`captain_view`, §4.12) | — | 1→ |
| S15 | ~~Fleet/cargo panel~~ **retired 2026-11-03** — the fleet body lives on as the intel window's 船队 tab (`fleet_view`, §4.5.1) | — | 1→ |
| S16 | Ending / retirement | `ui_shared/ending_screen.tscn` (root scene, from S13) | 3 |
| S17 | Chart | `scenes/world/chart_screen.tscn` (full-screen whole-world chart, §4.6) | 4 |
| S18 | ~~Officers panel~~ **retired 2026-11-03** — redesigned into the intel window's 官员 tab (table + detail, §4.6.2) | — | 5→ |
| S19 | Settings | `scenes/ui_shared/settings_panel.tscn` (modal over **S1 and S4**: the sea-traffic density dial + return-to-menu action, §4.6.3) | 5 |
| S20 | Creation (出身 + 自由点数) | `scenes/title/creation_screen.tscn` (two-step flow, §4.13) | 8 |
| S21 | Naval-battle sandbox | `scenes/combat/battle_sandbox.tscn` (zero-write editor, §4.7.16) | 9 |
| — | **Intel window** | `scenes/ui_shared/intel_window.tscn` (modal over **S3/S4**; hosts the 船长/官员/船队/海图/委托 tabs — the §4.5 dropdown became a full window, 2026-11-03) | — |

Phase 8 adds no further S-numbers: `fleet_picker`, `hail_modal`,
`character_card`, the dossier panel and `autopilot_hud` are
modals/instanced panels over their hosts (the provisioning-prompt
convention below).

Save/load has no dedicated scene: S1 hosts Load; S4 hosts Save (§4.7).
The provisioning prompt (§4.6.1) is a **modal over S4**, not a screen of its
own, so it takes no S-number.

### 4.2 Navigation graph

```
S1 ──New Game──► S2 ──confirm──► S20 ──confirm──► S4
    (S20 = creation, background → free points; Phase 8, §4.13)
S1 ──Load──────► (slot dialog) ─► S3 or S4 (state-dependent)
S1 ──Load retired slot──► S16 (summary only)
S3 ──dock: head into shore tile──► S4
S4 ──Set Sail──► S3
S3 ──Tab──► S17 ──Esc/Tab──► back (S3)
S4 ──Tab──► S17 ──Esc/Tab──► back (S4)   (amended 2026-11-01)
S4 ──facility──► S5/S6/S7/S8/S12/S13 ──Back/Esc──► S4
S4 ──Save──► (slot dialog)
S3/S4 ──C / 情报 button / F / O──► the intel window (modal, §4.5) on the
        船长 / 官员 / 船队 tab (amended 2026-11-03 — the S14/S15/S18 modals
        retired into it; the remembered tab is the mouse path's landing tab)
S3/S4 ──intel window 海图 tab──► S17 (launcher closes the window first;
        Tab still opens S17 directly)
S1 ──Settings──► S19 (modal; pre-game density dial, §4.6.3) ──Esc/Close──► S1
S4 ──Settings──► S19 (modal; density dial + return-to-menu, §4.6.3) ──Esc──► S4
S3 ──hostile contact / attack──► S10 ──board──► S11 (modal) ──► S10
S10 ──battle ends──► S3 (after-action dialog first)
S13 ──Retire (Duke)──► S16 ──any key──► S1
S13 ──tournament entry──► S10 (3 bouts) ──won bout──► S13 ──last bout──► S13
S1 ──海战──► S21 ──开战──► S10 (fixture encounter, zero-write)
S10 ──battle ends──► S21 (read-only after-action dialog first, configuration kept)
S21 ──Esc──► S1
S3 ──sea death / capture──► S9 ──any key──► S1
S4–S13 ──run death while ashore (a ledger tick on any port scene, e.g. a
        durability-0 flagship rolling a docked day)──► S9 ──any key──► S1
        (full-scene amendment 2026-11-02: every port-side scene attaches
        the shared `ui_shared/game_over_host.gd`; the world scene keeps its
        own handler with the debug-chart layer placement)
S1 ──Quit──► exit
```

No cross-links beyond these; Esc = step back one edge where applicable.
The tournament edge is a detail of the S13 row: a bout's after-action
`Continue` returns to the host palace (not S3), because the bracket continues
there and the palace starts the next bout (`70-*` §4.9.7). The
`S10 ──battle ends──► S21` edge is likewise a detail of the S21 row: a
**sandbox** battle never returns to S3 — its ending is the read-only
after-action dialog and the editor reopens with the configuration kept
(§4.7.16); a normal battle still ends at S3.

### 4.3 Input scheme (keyboard + mouse)

| Context | Keys | Action |
|---|---|---|
| Any | `Esc` | back / close modal; on S1: no-op |
| Any | `F5` | quick-save (allowed only in port; elsewhere shows toast `ui.cant_save_here`) |
| Any | `F9` | quick-load to slot 1 (confirm dialog) |
| S3 | `F10` | **session capture** (amended 2026-11-05, Phase-10 acceptance round): save the live viewport to `user://screenshots/world_<ticks>.png` and print the absolute path. Deliberately NOT gated on modals — evidence must work with any UI on screen; needs a loaded run, echo ignored. S10 pairs it with `battle_<ticks>.png` |
| S3 | arrows / numpad 1–9 | **Step mode:** step one tile (8-directional per `20-*` §4.2); **hold to repeat** at ~8 tiles/s after a 0.25 s delay, each held step a normal move. **Helm mode:** set the helm heading (persisted `world.heading`); the fleet then auto-sails that heading per `20-*` §4.2 — a new direction key re-steers |
| S3 | `Space` | **Step mode:** wait one day at sea — the full daily ledger (`advance_clock(1.0)`: provisions, wages, weather reroll, morale; `20-*` §4.17). **Helm mode:** stop the fleet; pressed again while stopped, wait one day |
| S3 | `[` / `]` | cycle sail trim `furled → reefed → normal → full` (persisted `world.sail_trim`; speed/storm-damage effects per `20-*` §4.17) |
| S3 | `Z` | toggle the world camera zoom — exactly two levels, 1.0 near (64 px tiles) ⇄ 0.5 wide (32 px effective); session-local, persisted nowhere (the §4.8 world zoom-out amendment, key pinned per the 613ddbf round) |
| S3 | left-click any visible water tile | **click-to-sail**: path there (A*, `20-*` §4.2) and walk it; a click on land/ice is rejected (`world.move_blocked`); cancels Helm mode |
| S3/S4 | `C` | open/close the intel window on the 船长 tab (§4.5; pressed again on the active tab it closes, another key switches — amended 2026-11-03) |
| S3/S4 | `F` | open/close the intel window on the 船队 tab (§4.5) |
| S3/S4 | `Tab` | open the Chart (S17, §4.6) — from the port hub too (amended 2026-11-01) |
| S3/S4 | click 情报 (top bar, right) | open the **intel window** (§4.5, amended 2026-11-03 — the dropdown became a full window): 船长 Captain (`char.title`) · 官员 Officers (`officers.title`) · 船队 Fleet (`fleet.title`) · 海图 Chart (`chart.title`) · 委托 Commissions (`char.quests`) tabs; the window remembers its last tab |
| S3 | `Esc` | close the Chart when it is open (otherwise no-op on S3) |
| dialogs | `Enter`/`Y` confirm, `N`/`Esc` cancel | confirm dialogs |
| lists | mouse wheel / ↑↓ + Enter | scroll & activate focused row |
| S10 | left-click tile / enemy token | move / default action |
| S10 | `Tab` | cycle own ships; arrows move the targeting cursor |
| S10 | `Enter` | confirm the highlighted move/action |
| S10 | `Esc` | battle menu (Retreat / Surrender / AI-turn speed switch / back) |
| S10 | `F10` | **session capture** (capture amendment 2026-11-05): save the live battle viewport to `user://screenshots/battle_<ticks>.png` and print the absolute path — `_input`-stage, so it fires even under the after-action dialog / menu / confirm modals |
| S10 | RMB / MMB drag | camera pan; a manual pan pauses the auto-center follow until the acting unit's next turn (§4.7.1) |
| S10 | mouse wheel | camera zoom 0.6×–1.5×, anchored at the cursor |
| S10 | viewport edge band | edge scroll — the cursor within 16 px of the screen edge pans the camera at 600 px/s |
| S10 | `Home` or [fit] | fit the whole 1536×960 battle world in the viewport |
| S10 | minimap click | jump the camera there (the minimap owns input before the world view) |
| S10 | press-move ≤ 4 px | a press that moves ≤ 4 px is a click (select/act), more is a drag (pan) |
| S10 | `1`–`4` | shot-selector buttons 1–4 pick the shot type — round / chain / armor-piercing / grape (gate-locked states disabled, §4.7.1) |
| S21 | `Esc` | back to S1; panels, buttons and clamps per §4.7.16 |
| S3 | right-click a fleet inside sighting radius | opens **fleet_picker** (§4.10.1): inspect / talk / attack. Left-click sail-to is unchanged; `attack` keeps the existing funnel (a non-pirate owner = piracy + −20 fame, `70-*` §4.5 + `60-*` §4.11.10; contact rules `60-*` §4.11.11.2); a **coaster** offers no attack verb (intimidate-only, `60-*` §4.1.1); right-click on empty water or land is a no-op |
| S3 | talk verb at Chebyshev ≤ 2 | opens the **hail modal** (§4.10.2) |
| S3 | right-click a port harbor tile | the **port context menu** (§4.10.3): dock / 委任航行 appoint voyage |
| S3 | `E` | Explore: find every discovery within Chebyshev 36, wrap-aware (`70-*` §4.4; Phase-6 sweep of the 18-tile radius); no-op with a toast `world.explore.none` when nothing is in range |
| S17 (Chart owns input while open) | `W` | toggle the current-month wind-arrow layer per region (§4.6) |
| S17 | `C` | toggle the current-arrow layer (§4.6) — chart-local; shadows the character-panel `C` only while S17 is open |
| S17 | `I` | toggle the ice tint on explored tiles (§4.6) |
| S17 | `D` | debug omniscient mode — reachable only while the S19 调试图层 row is on (§4.6 debug mode); **on by default while the row is on** (amended 2026-11-01) |
| S17 | `,` / `.` | month scrubber (debug mode only): preview any month's winds/ice/active lane variants — pure view state |
| S17 | mouse wheel | zoom 1.0×–8.0×, ×1.25 per notch, anchored at the cursor (amended 2026-11-01, §4.6) |
| S17 | left/right-button drag | pan 1:1, clamped to the map; opening restores the fit view (amended 2026-11-01, §4.6) |
| S17 | click a debug side-legend row | show/hide what that row depicts (lanes, spokes, chokepoints, roles, wrecks, intel, neutral; §4.6) |
| S17 | click a port dot (debug row on) | toggle the port debug panel (full report, §4.6) — a press that lands on a port is a click, never a pan; clicking elsewhere closes the panel and pans; `Esc` closes the panel first, then the chart |
| S17 | `Tab` / `Esc` | toggle back to the screen it was opened over (S3/S4; the Chart never mutates state) |
| S12/S13 | `Esc` | back to S4 (same edge as Back) |
| S4 | `ESC` | opens the provisioning prompt (§4.6.1) — the same edge as Set Sail |
| S4 | `O` | open/close the intel window on the 官员 tab (§4.6.2, amended 2026-11-03) |
| S4 | `Space` | wait one hour (`advance_port_hours(1)`, `20-*` §4.3; amended 2026-11-02) — hub only, never behind a modal |
| S19 | `Esc` | close settings, back to its host (S1 or S4; same edge as Close) |
| provisioning | `Enter` | sail (disabled with a stated reason when gated, `20-*` §4.11.2) |
| provisioning | `Esc` | back to S4 without sailing |

Focus outline (2px accent border) always visible on keyboard-focused control.

**Phase-6 key notes (correction 8).** **`Esc` keeps its global meaning
everywhere** — back / close modal, exactly as the `Any` row pins it; the
Chart (S17 owns all input while it is open, so its `C` shadows the
character-panel `C` only while S17 is up) is no exception. Helm mode adds
**no** `Esc` behavior: the helm is cancelled by **click-to-sail, battle
and docking** — never by `Esc`. `Space`, `[` and `]` work in both input
modes regardless of trim (`20-*` §4.17).

### 4.4 `ui_strings.json` conventions

- Flat key → L10nString: `"market.buy": {"zh": "购买", "en": "Buy"}`.
- Key namespaces by screen: `title.*`, `nation.*`, `world.*`, `port.*`,
  `market.*`, `shipyard.*`, `tavern.*`, `inn.*`, `char.*`, `ui.*` (shared:
  `ui.back`, `ui.confirm`, `ui.cancel`, `ui.gold_abbr`…), `gameover.*`,
  `battle.*` (S10), `duel.*` (S11), `encounter.*` (fleet contacts),
  `guild.*` (S12), `palace.*` (S13), `quest.*`, `rank.*` (nobility names),
  `bounty.*`, `tournament.*`, `discovery.*`, `ending.*` (S16),
  `chart.*` (S17), the Phase-4 `world.*` sailing keys below, the
  Phase-5 families `settings.*` (S19), `market.stock.*` (market columns)
  and `captain.*` (fleet captain sightings — §4.7.9), and the Phase-6
  families `world.wind.*`, `world.current.*`, `world.trim.*`,
  `world.ice.*`, `world.wait.*`, `world.calendar.*` (HUD/sailing),
  `settings.input.*`, `settings.current.*`, `settings.debug.*` (S19),
  `chart.wind.*`, `chart.current.*`, `chart.ice.*` (chart layers) and
  `debug.*` (debug chart — §4.7.10), and the Phase-7 families
  `market.specialty.*`, `market.tax.*`, `market.exclusive.*`,
  `market.invest_gate.*`, `shipyard.role.*`, `shipyard.tier.*`,
  `palace.permit.*`, `palace.commend.*`, `tavern.invest.*`
  (§4.7.15), and the Phase-8 families `char.*` / `skill.*` / `gate.*` /
  `hail.*` / `interact.*` / `dossier.*` / `captain.table.*` /
  `officer.post.*` / `advice.*` / `creation.*` / `sail.autopilot.*`
  plus the personality/appearance part keys, and the 2026-11-03 intel
  window keys `intel.*` (`intel.hint`, `intel.chart.note`,
  `intel.open_chart`, `intel.officers.name`, `intel.officers.wage`;
  the tab labels reuse the existing `char.title` / `officers.title` /
  `fleet.title` / `chart.title` / `char.quests` keys) (§4.15).
- Event/system strings also live here (`world.mutiny.title`,
  `world.desertion`, `inn.odd_job.offer`, `world.ship_lost`…).
- **Port-hours keys (amended 2026-11-02, `30-*` §4.1b):** `port.facility.closed`
  = `营业时间 {open}–{close}` / `Closed · Opens {open}–{close}` (the disabled
  facility card's status line, §4.8.1), `port.facility.open_now` =
  `营业中 · {open}–{close}` / `Open · {open}–{close}` (an open card's status
  line; a 24h facility has no window to quote and shows
  `port.facility.open_always` = `全天营业` / `Open around the clock`
  instead) and `port.wait.hour` = `等待 1 小时 (空格)` /
  `Wait 1 hour (Space)` (the hub's wait affordance label).
- Placeholders use `{name}` syntax, substituted by code:
  `"world.arrive": {"zh": "抵达 {port}。第 {day} 天。", "en": "Arrived at {port}. Day {day}."}`.
- The validator checks both locales non-empty and that zh/en placeholder sets
  match per key.
- Minimum Phase-1 inventory: every label in the wireframes of `30-*` §4.8,
  every event string referenced in `20/30/40/50`, plus this §'s shared keys.
  Exact list is assembled by the IMPLEMENT-Phase1 task that creates
  `ui_strings.json`; it must cover ≥ the keys cited across docs.

### 4.5 Sailing HUD (S3)

Layout (1920×1080; tile viewport is the space below the top bar):

```
+------------------------------------------------------------------+
| Day 12 08:30 · Year 1 · Month 1   7,830g   Morale 72 (Good)   [里斯本 · Lisbon area]   [情报 Intel]   top bar 40px
+------------------------------------------------------------------+
| [minimap 256×192]                                   (viewport)   |
|  explored tiles only                                             |
|                                                                  |
|                               [fleet ship sprite placeholder]    |
+------------------------------------------------------------------+
| Provisions 45 (15d) · Water 45 (15d) · Crew 15/45 · Cargo 120/120 t · Speed 4.2 kn | bottom bar 32px
+------------------------------------------------------------------+
```

- Top bar: day **with time-of-day** `第 {day} 天 {time}` / `Day {day} {time}`
  (`world.day_time`; `{time}` = `HH:MM` per `20-*` §4.3, amended 2026-11-02 —
  day-only surfaces keep `world.day`), **`Year {y} · Month {m}` (zh
  `{y}年{m}月`; Phase 6, calendar per `20-*` §4.15, key
  `world.calendar.year_month`)**, gold, morale (value +
  tier label, tier-colored per `20-*`
  §4.8 — yellow < 40, red < 20), current area label (nearest known port
  within 16 tiles, else `world.open_sea`). **No language control** (amended
  2026-10-31: the locale lives only in S19, §4.6.3).
- **Intel window (amended 2026-11-03, §4.2):** a plain `Button` at the top
  bar's **right end**, labelled `ui.intel` (情报 / Intel), present on **S3
  and S4** (one shared `hud.tscn` serves both, so the button exists in port
  and at sea alike). The press opens the **one dedicated 情报 modal** — the
  morning's dropdown became a full window (the §4.1 inventory row) — whose
  six tabs host the information surfaces, in this order:
  船长 (`char.title`) → the captain view (the retired S14 single page, §4.12);
  声望 (`char.reputation`) → the six-nation reputation table (split out of
  the 船长 page, 2026-11-03); 官员 (`officers.title`) → the officers roster
  table + detail (the retired S18, §4.6.2; the sea rules apply —
  talk/gift/train usable anywhere, appoint/Dismiss port-only); 船队
  (`fleet.title`) → the fleet view (the retired S15 body, §4.5.1); 海图
  (`chart.title`) → **enters the fullscreen S17 immediately** (amended
  2026-11-03: the tab is not a page with a launcher button but a direct
  entry — pressing it closes this window and opens the chart); 委托
  (`char.quests`) → the active-quest list (§4.7.3, migrated from the
  retired S14 tab).
  Tab labels rebind on `locale_changed` (§4.4); the window remembers its last
  tab for the button's next open (session-only; the 海图 entry is never
  remembered — it is an action, not a page). Keys (§4.3): `C`/`O`/`F`
  open the window on their tab — pressed again on the active tab the window
  closes, a different key switches tabs in place; `Esc` closes; opening on a
  key is ignored while another modal is on screen (§6). The HUD button only
  *opens* the shared window instance the hosts attached — it never mutates
  state (docs/90-* §7 "HUD only reads").
  **Supersedes the surface duplicates (amended 2026-11-03):** the top-bar
  船长 character button is removed — its §4.12.2 alloc badge rides the intel
  button — and S4's footer `Fleet · Officers` buttons are removed (§4.6.2).
- Bottom bar (formats amended 2026-11-02; conventions per `10-*` §3.1,
  `20-*` §4.3, `40-*` §4.4 speed units):
  - **`补给 {amount}（{days}天）` / `Provisions {amount} ({days} days)`** and
    the matching water line — the §4.5.1 `fleet.stat.supply` line, `days`
    being **each kind's own** days-of-supply from the locked `20-*` §4.10
    formula on the pooled stack. The label is tier-coloured by `days` with
    the **same §4.6.1 thresholds** as the provisioning prompt: GOOD ≥ 10
    (green), WARN 3–9 (yellow), BAD ≤ 2 (red).
  - **`货舱 {amount}/{capacity} 吨`** — 1 cargo unit renders as 1 t
    (`10-*` §3.1 display convention; abstract units underneath).
  - **`航速 {speed} 节`** — knots per `40-*` (`× 5 nm ÷ 24 h`, one decimal),
    never tiles/day.
  All live-updating via `EventBus` signals; a movement step also refreshes
  the day/time label (a sub-day tick has no EventBus signal — the host calls
  `set_fleet_cell`, which owns position-derived refreshes).
- Weather icon (placeholder glyph: sun/wind/storm text label) sits under the
  minimap; in storm it flashes (0.5s cycle).
- **Wind indicator (Phase 6):** beside the weather glyph, an **arrow that
  rotates to the day's `world.wind_dir`** (8-dir; guard-read with default
  `"E"`) plus a **strength label** (calm/fair/strong/storm, `20-*` §4.7).
- **Current indicator (Phase 6):** a **current arrow shown only while the
  fleet stands on a current tile** — direction = the decoded current vector
  after the seasonal reversal flip (`20-*` §4.16).
- **Trim chip (Phase 6):** a 帆位/sail-trim chip (`furled`/`reefed`/
  `normal`/`full`, `world.sail_trim`, guard-read default `normal`) near the
  speed readout, **highlighted while the trim ≠ `normal`**.
- **Appointed-voyage bar (Phase 8):** while an appointed voyage runs,
  `scenes/world/autopilot_hud.tscn` is instanced into the world HUD below
  the top bar — destination / ETA / cancel (§4.10.4).
- Camera: a `Camera2D` centers on the fleet marker every frame. **`x` wraps**
  (no clamp at the dateline; the seam shows no void) and `y` is clamped to the
  2160-tile height (Phase-6 grid; minimap box/crop numbers unchanged per
  `IMPLEMENT-Phase6.md` §2.0); zoom locked at 1.0. Only live chunks are drawn
  (`90-*` §9).
- Minimap: the 256×192 px box shows a **wrap-aware 128×96-tile crop** around
  the fleet at 2 px/tile, drawn from the explored bitset (`20-*` §4.12).
- The full world is the separate **Chart screen (S17, §4.6)**, opened with
  `Tab`.
- NPC fleet markers, wake trails and the wreck icon render per §4.5.2
  (Phase 5); they are data from `NpcFleets.markers()`, never a second
  simulation.
- S4 (port) HUD: same top/bottom bars, viewport replaced by the port menu;
  the bar contents are identical so stats are always visible.

### 4.5.1 The fleet view (the intel window's 船队 tab; the S15 body)

Embedded in the intel window's 船队 tab (`ui_shared/fleet_view.gd`, the
retired S15 body — `F` opens the window there; amended 2026-11-03). It is the fleet-management surface the fleet panel of `40-*` §4.4 and
the supplies jettison of `20-*` §4.10 refer to.

```
+----------------------------------------------------------------------+
| 舰队 / Fleet                    Day 12 08:30 · 7,830g · Morale 72 (Good)   | header
| 2/5 ships · Free 100 · Fleet is full (5 ships)                        |
| <at-sea banner, hidden in port>                                       |
+----------------------------------------------------------------------+
| Ship 1 · Caravel [Flagship]                                           |
| 耐久 Durability  [====------] 45/90     载重 Cargo 0/120 t free       |
| 船员 Crew        15/45        火炮 Guns   6/6                         |
| 航速 Speed       4.2/5.0 kn (wind: fair ×1.0)                         |
| 补给 Provisions  45 (15 days)  淡水 Water 45 (15 days)                |
| 货物 Wine × 30 [Jettison]                                             |
| Ship 2 · Nao                              [Make flagship]             |
| ...                                                                   |
+----------------------------------------------------------------------+
| Esc to go back                                              [Close]   |
+----------------------------------------------------------------------+
```

- **Header:** fleet count `n/5`, pooled `fleet_free`, `fleet.full` at the cap,
  plus the same day / gold / morale line the HUD shows so the panel is
  self-contained.
- **Per ship, three stat lines** (all values from `data/ship_types.json` +
  the ship instance, never hardcoded):
  1. durability bar (tier-coloured, same thresholds as S6) `durability /
     effective_max`, and cargo `used/capacity` with `free` beside it;
  2. crew `crew/crew_max` and guns `cannons/armament_slots`;
  3. speed `effective/base` in **knots** (`40-*` §4.4 speed units, amended
     2026-11-02: tiles/day × 5 nm ÷ 24 h, one decimal) with the wind factor
     that produced it (§4.4), so a becalmed or storm-lashed fleet explains
     itself;
  4. supplies: `provisions` and `water` **each with their days-of-supply**
     derived by `20-*` §4.10's formula, so the panel answers "can I leave?"
     without opening the provisioning prompt.
- Then one line per stack — provisions, water, and each trade good — with its
  own `Jettison` button.
- **Fleet totals row** at the bottom of the list: pooled provisions, water and
  their combined days (the lesser of the two), plus the fleet's effective
  speed (slowest hull, `20-*` §4.4).
- Promote sits on non-flagship rows only (§4.4: free, port-only,
  order-preserving). Jettison drops the **whole** stack after a `ui.confirm`
  dialog (destructive action, §4.7) and frees capacity immediately.
- At sea the panel is **read-only**: every action is disabled and states its
  reason, because promotion and jettison are port actions.
- Rows are 32px table rows (§4.8); no textures.

#### 4.5.2 World-map fleet markers, wakes & wrecks (Phase 5)

NPC fleets render on S3 as placeholder shapes only (§4.8 palette, no
textures). All data comes from `NpcFleets.markers()` (`60-*` §4.12.3);
rendering is viewport-culled and never re-simulates.

- **Role markers (locked set):** every national fleet (`trader`, `coaster`,
  `courier`, `patrol`, `privateer`, `treasure`) draws as a
  **nation-coloured square** (`Nation.color`, `10-*` §7.4) with a letter
  for the role; `pirate` is a `BAD` red square (as today); a `hunter` uses
  its nation's colour with the navy letter.
- **Convoys:** same-lane traders within Chebyshev 3 render as **one group
  with a shared escort square** (`60-*` §4.11.11.4) — the group shares one
  marker; the member count is a small numeral beside it.
- **Wreck icon:** a `wreck` draws as an `ACCENT` × glyph (2×2 tiles) at its
  site; entering the tile collects it (cargo up to free capacity or salvage
  gold, `60-*` §4.11.11.2). No battle opens on a wreck tile.
- **Wakes (locked):** each moving marker drags a **5-tile dashed trail** of
  1 px `PANEL_LINE` lines behind it that fades tile-by-tile; wrecks and
  docked markers draw none.
- **Marker path playback (stepwise-glide amendment, 2026-11-02):** NPC
  markers replay an accrual **tile by tile along the walked path** — the
  logic already commits tile-by-tile (`60-*` §4.11.11) and now reports every
  walked cell, so the marker walks the fleet's real route instead of
  sweeping a straight from→to line (which read as a jump, and could cross
  land). All fleets in one accrual batch start their playback on the same
  frame and march in **lockstep** — one shared per-tile duration, the
  player's own step cadence (`_step_render_seconds`) when unbacklogged.
  **Viewport-gated:** a batch animates only fleets whose from/path cells
  touch the camera's visible rect expanded by
  `NPC_GLIDE_MARGIN_TILES = 2` tiles (wrap-aware); a path that never enters
  the frame snaps. **Backlog:** a fleet already playing chains new tiles
  onto its polyline; once a fleet's pending tiles exceed
  `NPC_GLIDE_BACKLOG_TILES = 8`, the whole batch speeds up so its largest
  pending queue still drains within `NPC_GLIDE_MAX_LAG_SECONDS = 1.5` s, and
  a fleet pending more than `NPC_GLIDE_SNAP_TILES = 24` tiles skips
  animation and snaps. Waypoint pixels unwrap the dateline (each step takes
  the camera-nearest x representation) — a seam crossing walks one tile,
  never sweeps the map. Render-only: logic, contact and saves keep reading
  tile positions, and the seam honours the same glide-disabled test switch
  (which also drops any playing playback). This supersedes the
  unified-movement amendment's from→to glide (2026-11-01), which itself
  replaced a snap that read as teleporting. Docked fleets render at their
  simulated cell — the port's **sea berth tile**, the only legal docking
  tile (established pin; ships never dock on the shore tile).
- **Debug chart (Phase 6):** the omniscient debug chart mode (§4.6) renders
  the **same** `NpcFleets.markers()` data un-culled — every fleet on the
  whole map, same role colors.

### 4.6.1 Provisioning dialog (S4 → S3, Phase 5 polish)

Clicking **Set Sail** (`出航`) — or pressing `ESC` on S4, which is the same
edge (`§4.2`) — opens a provisioning prompt **before** the world map. This is
the only place supplies are bought; the market sells trade goods only
(`20-*` §4.10). The prompt buys at **any hour** — supplies are a 24h
exception to the §4.1b windows (2026-11-02 amendment, `30-*` §4.1b); each
completed purchase still charges its §4.1b hour.

```
+--------------------------------------------------------------+
| 出航准备 / Prepare to Sail                                    |
| 里斯本 Lisbon · Day 12 · 7,830g                               |
+--------------------------------------------------------------+
| 船员 Crew        15 / 45                                      |
| 补给 Provisions  45  (15 days)   [- 10 +]  [Buy 10 — 20g] [抛弃] |
| 淡水 Water       45  (15 days)   [- 10 +]  [Buy 10 — 10g] [抛弃] |
| 货舱 Free        0 / 120                                      |
+--------------------------------------------------------------+
| 可航行天数 Days at sea: 15                    [一键补满 Auto-fill] |
| 离港后第 7 天起可能断粮。                                      |
+--------------------------------------------------------------+
| [出航 Set Sail]   [留在港口 Stay in port]                     |
+--------------------------------------------------------------+
```

- **Readout (locked):** `days = min(floor(provisions / need),
  floor(water / need))`, `need = ceil(total_crew / 5)` (`20-*` §4.10). Shown
  large and colour-coded: `GOOD` ≥ 10 days, `WARN` 3–9, `BAD` ≤ 2.
- **Buying:** fixed prices, provisions 2g / water 1g per unit, buying through
  `TradeEngine.buy_supplies` (never a second price path). `[- 10 +]` adjust the
  quantity in steps of 10; `Buy N` is disabled with a reason when the hold is
  full (`market.hold_full`) or gold is short (`market.no_gold`). Buying
  **jettison-free**: if the hold is full the player must jettison a cargo
  stack first (the fleet panel's button, `§4.5.1`) — the prompt says so rather
  than silently dropping cargo.
- **Jettison from the prompt:** a `Jettison` affordance per trade-good stack,
  same confirm as S15, so a full hold can be cleared without leaving the
  dialog.
- **Discarding supplies (amended 2026-10-31):** each supply row also carries
  a `抛弃` action: the row's staged quantity is removed from the pooled
  stock flagship-first (`Fleet.remove_supplies` — the single
  supplies-removal path), freeing hold capacity immediately and refunding
  nothing. The stepper's ceiling is therefore
  `max(free hold, current stock)`, so a discard can be staged even with a
  full hold. **Confirm-first** (§4.7, same `confirm_dialog` as the cargo
  jettison): `port.sail.jettison.confirm` names the kind and the quantity
  before anything is dropped.
- **一键补满 / Auto-fill (amended 2026-11-02):** a button on the days row.
  One press plans the largest common target `T` with
  `provisions = water = T`, then executes it: the shortfalls are **bought**
  at the fixed §4.10 prices (provisions 2g / water 1g, no tax) through
  `TradeEngine.buy_supplies`, and the surplus above `T` is **discarded**
  (the amended discard path above — `Fleet.remove_supplies`, no refund)
  only where the plan requires it. The plan is exact maths over the pooled
  state `P, W, free, gold`:
  - hold: `buy_p + buy_w ≤ free + discarded`, which collapses to the cap
    `T ≤ ⌊(free + P + W) / 2⌋` in every buy/discard mix;
  - purse: `2·buy_p + 1·buy_w ≤ gold` (cost is piecewise linear in `T`:
    0 up to `min(P, W)`, the smaller kind's price up to `max(P, W)`, then
    `3` per unit — so the gold cap is read off those breakpoints).
  `T = min(hold cap, gold cap)` is therefore the maximum; `T ≥ min(P, W)`
  always, so **at most one kind is ever discarded** — the larger one, and
  only when the hold (or purse) caps `T` below its stack. Discards run
  first (freeing hold), then the buys. **Confirm-first** (§4.7) whenever
  the plan discards anything (`port.sail.fill.confirm_both` /
  `port.sail.fill.confirm_discard` name the discard and buy parts); a
  buy-only plan executes immediately, like the row Buy buttons. With
  nothing to buy or discard the button is disabled with a stated reason
  (`port.sail.fill.done`). The button never stages a stepper quantity and
  never touches the cargo jettison list.
- **Gate (locked, `20-*` §4.11.2):** `Set Sail` is disabled when there are no
  crew (`port.sail.no_crew`) or fewer than one day of supply
  (`port.sail.no_supply`), each stating its reason. `Stay in port` always
  works.
- `ESC` closes the prompt back to S4 (it does **not** sail) — the standard
  "Esc steps back one edge" rule (`§4.2`).

### 4.6.2 Officers roster (the intel window's 官员 tab; amended 2026-11-03)

The officers roster lives as the **官员 tab of the §4.5 intel window** (the
retired S18 modal redesigned into it, 2026-11-03). Entries: the `O` key and
the 官员 tab itself (the intel menu's item and S14's Officers button retired
with their surfaces; the former footer row `Fleet · Officers` was removed as
an intel duplicate, so the S4 footer keeps only `Set Sail · Settings`).

**Table form:** one row per employed officer (`player.officers` → the
officer roster, `50-*`; sorted by id), with the fixed columns **姓名 name ·
岗位 post (current post, or idle) · 忠诚 loyalty (§4.5.4) · 日薪 wage** plus
a switchable stat block — the toggle buttons **属性 / 技能** flip the
columns between the five §4.12 attributes and the eight player skills +
the three officer-only skills (medicine/carpentry/cooking). The header row
names each column; an empty roster renders the `char.no_officers` empty
state with the tavern hint (§4.4).

**Detail page:** clicking a row opens it (a back button returns to the
table): the §4.12 officer card, the post · wage · recruit-port line, and the
actions — the **four actions** talk / gift / train / appoint
(`50-*` formulas) plus `Dismiss` (confirm dialog; frees the slot and stops
the wage from the next day tick).

**The detail card keeps the stat blocks (re-amended 2026-11-03):** the
earlier same-day amendment dropped them on the grounds that the table owns
the columns — but the table is **hidden** while the detail page is open, so
the numbers had nowhere to live and the card showed only identity,
personality, relations and career. The officer detail card therefore renders
the full §4.12 card again: **attributes and skills side by side**, exactly
like every other entry. The page's single scroll (§4.12.1 "Sizing") carries
the height, so nothing is pushed off screen. The Phase-5 four-stat line
(统率/航海术/战斗/导航) and its derived-effect text stay retired with the
old model.

**The detail page's layout (re-amended 2026-11-03):** the 属性/技能 toggle
belongs to the **table**, so it is hidden while the detail page is open. The
page keeps **no separate top bar**: `返回` is the **last entry of the action
row**, after `解雇`, so the card starts at the top of the page and the row
reads 交谈 · 赠礼 · 训练 · 任命 · 解雇 · 返回. The card sits directly in the
page column and publishes its content height (§4.12.1 "Sizing"); the card
column is the one scrolling region, while the action row stays fixed at the
bottom so the actions never scroll out of reach.

**The views do not clip a focus ring (amended 2026-11-03):** the embedded
views use `clip_contents` to stop an over-tall page painting over the tab
row (§4.5), but at `x = 0` the clip also shaved the 2px focus ring of the
leftmost control — the 返回 button's left border was visibly missing while
its right border was intact. The views therefore inset their body by one
`BASE_UNIT` (the same 8px the intel panel's own margin uses), so focus rings
have room on every side.

- **Header:** `n / OFFICER_MAX` (**12** since Phase 8, `50-*`; the
  Phase-5 cap was 3) and the total daily wage bill — the number
  that shows up in `20-*` §4.5 ledger step 2.
- **Port/sea availability (Phase 8):** `appoint` and `Dismiss` are port
  actions (fleet composition changes dock-side, the §4.5.1 promotion
  rule); `talk` / `gift` / `train` work anywhere, each with its own
  cooldown shown on the button.
- **Empty state:** `char.no_officers` plus the tavern hint (`§4.4` is where
  they are hired).
- **At sea (Phase 8):** `appoint` / `Dismiss` are disabled at sea with
  their reason (port actions, the §4.5.1 promotion rule); the
  talk / gift / train buttons stay usable.
- No textures; 32px rows (§4.8).

#### 4.6.3 Settings: S1 title entry + S19 settings modal (Phase 5, amended)

**S1 Settings entry (amended 2026-10-31).** The title screen gains a
`Settings` button in its button stack (between `Load game` and `Quit`),
opening the same **S19** modal over S1. **The sea-traffic (航海密度)
row is NOT on S2.** The new-game flow never asks for a density preset; the
run always starts at `npc_config.json`'s `default_preset` (`normal`) and the
dial is changed in S19 only (before a new game via S1, or mid-run via the S4
hub). This supersedes the earlier "S2 density row" pin: S2 is the
nationality card grid again.

**S19 `scenes/ui_shared/settings_panel.tscn`** — a **modal** opened from two
hosts: the **S1 title screen** (pre-game) and the **S4 port hub** footer
(mid-run, beside `Set Sail` — the §4.6.2 amendment removed the footer
`Fleet · Officers` duplicates in favour of the §4.5 intel menu). One panel,
two mounts.

```
+--------------------------------------------------------------+
| 设置 / Settings                                    [Close]    |
+--------------------------------------------------------------+
| 航海密度 Sea traffic                                           |
|   [荒芜 deserted] [稀少 low] [正常 normal]                     |
|   [繁忙 high] [极端 extreme]                                   |
|   当前 Current: normal                                        |
|   调高后船队将在数日内逐渐补充;调低不会移除现有船队。           |
+--------------------------------------------------------------+
| 输入模式 Input mode                                            |
|   [步进 Step] [掌舵 Helm]        当前 Current: 步进 step       |
| 洋流模式 Current mode                                          |
|   [修正 Modifier] [漂移 Drift]   当前 Current: 修正 modifier   |
| 调试图层 Debug overlays: [关 off]  (仅本次运行 · session-only)  |
+--------------------------------------------------------------+
| 语言 Language: [中文 / EN]                                    |
+--------------------------------------------------------------+
| 保存 Save (S4 mount only)                                     |
| 返回主菜单 Return to main menu (S4 mount only)                |
+--------------------------------------------------------------+
```

- **Density control applies mid-run (locked):** `GameState.npc_preset`
  (string, default `"normal"`) is set in S19; **raising** refills via
  trickle, **lowering never culls** living fleets; `deserted` = zero NPC
  spawns/contacts. A pre-game S1 open writes the same field before
  `new_game` (which preserves it as run input).
- **Input mode row (Phase 6):** `[步进 Step] [掌舵 Helm]` writes
  `GameState.control_prefs.input_mode` — persisted per save like
  `npc_preset`, default `"step"`; effects per §4.3 and `20-*` §4.2.
- **Current mode row (Phase 6):** `[修正 Modifier] [漂移 Drift]` writes
  `GameState.control_prefs.current_mode` — default `"modifier"`; effects
  per `20-*` §4.16. `control_prefs` defaults are exactly
  `{input_mode: "step", current_mode: "modifier"}`.
- **Debug overlays row (Phase 6, correction 12):** 调试图层 on/off flips
  the **static, session-only** `SettingsPanel.debug_overlays` flag (the
  §4.6 symbol contract; default off). It is **never persisted** — it must
  never enter a save payload — and only unlocks the chart's debug layers
  (§4.6) for this session.
- **All three rows live on BOTH mounts** (S1 pre-game + S4 in-run), like
  the density row; pre-game values are carried into the run by `new_game`
  (mirroring `npc_preset`).
- **S19-only (correction 2):** the input-mode, current-mode and
  debug-overlays rows exist nowhere else — **no S2 row** (S2 is the
  nationality card grid); the in-run mount is the S4 footer → Settings.
- **Locale lives only here (amended 2026-10-31):** S19 owns the language
  toggle (`[中文 / EN]`, both mounts). The old `L` hotkey, the S2 footer
  button, the top-bar button on every screen and the market header button are
  all **removed** — Settings is the single place to change the language. The
  `L` key remains bound in `project.godot` but is inert (reserved).
- **Save lives here too (amended 2026-10-31):** the S4 mount's `Save` action
  replaces the retired S4 footer row: it opens the same 3-slot dialog
  (§4.7), offered only while docked (`SaveSystem.can_save_here()`). The
  footer keeps `Set Sail · Settings` (amended 2026-11-03 — the
  `Fleet · Officers` duplicates moved into the §4.5 intel menu); the
  per-screen
  `Esc 返回` hint labels are removed (the Esc bindings themselves stay).
- **Return to main menu (amended 2026-10-31):** the **S4-hosted** panel shows
  a `Return to main menu` action below the locale row. It is **confirm-first**
  (`confirm_dialog`, destructive-action rule §4.7) and the confirmation says
  plainly that **unsaved progress is lost** — the game has manual saves only,
  so the player saves from the S4 row first if they want to keep the run.
  On confirm the app routes to **S1**; cancel returns to the panel. It is
  **not** shown on the S1-hosted panel (there is no run to leave). Keys:
  `settings.return_menu` / `settings.return_menu.confirm` (zh/en).
- Esc / `Close` returns to S4 (§4.2 edge); the panel consumes all input
  while open (modal rule, §4.7).
- Strings: `settings.*` plus the Phase-6 `settings.input.*` /
  `settings.current.*` / `settings.debug.*` keys (§4.7.10), zh/en. No
  textures; 32px rows.

### 4.6 Chart screen (S17, Phase 4)

Full-screen panel over S3 (`scenes/world/chart_screen.tscn`); it **never
mutates state** — a pure view of the session.

```
+------------------------------------------------------------------+
| 海图 / Chart                                        [关闭海图]     | top 40px
+------------------------------------------------------------------+
|  whole world 4320×2160 downscaled to fit (≈0.44× at 1920×1080)     |
|   explored tiles: SEA/COAST_SEA at low alpha                      |
|   unknown tiles: PANEL_BG                                         |
|   known ports: 3px nation-coloured dots (+ names at zoom)         |
|   discovery leads: ACCENT cross icons                             |
|   fleet: white 5px square with black outline                      |
+------------------------------------------------------------------+
| 已探索海域 · 已知港口 · 船队 · 发现物线索            (legend)      | bottom 32px
+------------------------------------------------------------------+
```

- **Layers, bottom to top:** canvas background, explored-tiles overlay from
  the session explored set (`20-*` §4.12 — persisted in the save since the
  explored-state amendment, 2026-11-02), known ports
  as nation-coloured dots with names shown at zoom, discovery hint icons, the
  fleet marker.
- **Scale:** whole 4320×2160 grid downscaled to fit the viewport (scale
  ≈ 0.44× at 1920×1080); no scrolling, no per-region tabs. Dateline handling is
  implicit in a full-world image (no seam crop).
- **Input:** `Tab` toggles, `Esc` closes (`§4.3`); the panel owns all input
  while open. Closing returns to S3 with the fleet unmoved and the clock
  untouched.
- **Budget:** open (build + first frame) **< 0.5 s**.
- **Strings:** every label from `chart.*` (§4.7.5).
- **Not saved:** the chart's local view state (`W`/`C`/`I`/`D`, the month
  preview, legend-visibility filters) is session-only. The explored set is
  **not** in that bucket: it persists as the §8.1 `explored_tiles` key
  (`90-*`, `20-*` §4.12) since the explored-state amendment (2026-11-02) —
  the Phase-1 "explored state is session-only" limitation is removed.
- **Phase-6 seasonal layers (player).** Three toggles while the chart is
  open — `W` draws the **current month's prevailing wind arrows per
  region** (from the baked `wind_regions` lookup, `20-*` §4.14), `C` draws
  **current arrows** (decoded annual-mean vectors with the seasonal
  reversal flip applied, `20-*` §4.16), `I` tints **ice** on explored
  tiles (the permanent `I` band plus in-month seasonal polygons,
  `20-*` §4.18). "Current month" = the calendar month of `GameState.day`
  (`20-*` §4.15). Placeholder shapes only per §4.8. Layers are view
  state; they mutate nothing.

**Omniscient debug chart mode (Phase 6, the `IMPLEMENT-Phase6.md` §2.12
spec).** Gated by the S19 调试图层 row — the symbol contract is exactly
**`SettingsPanel.debug_overlays: bool` (static, session-only, default
false)**; the chart reads it guard-style, task V owns the S19 row
(§4.6.3), and the flag is never persisted. With the row on, opening the
chart adds:

- **`D` — omniscient mode:** ignores the explored bitset **and**
  `known_ports` — the whole map renders plus **every** port:
  nation-colored dots, `PORT_NEUTRAL` grey for `nation_id: ""` ports
  (§4.8), capitals ringed. **On by default while the S19 row is on** —
  opening the chart lifts the fog (amended 2026-11-01); `D` toggles back
  to the explored view.
- **Live ecology:** every fleet from `NpcFleets.markers()` (role colors
  per §4.5.2, **not viewport-culled**), wrecks, and the hunter-intel
  markers with their exact shapes — `world.last_departed_port` drawn as a
  **ring** around its port, `world.hunter_intel_cell` drawn as a
  **cross**. Tooltips read-only.
- **Network layer:** all 21 lanes from the built tile paths
  (`trade_routes_built.json`), per-lane colors, the **active variant
  solid**, spokes thin grey, chokepoint diamonds, lane ids in a side
  legend. Legend rows show the lane's **localized name** — the
  `debug.lane.<id>` key (§4.7.10), whose zh/en strings are §7.6's name
  columns verbatim; a missing key falls back to the raw `id`.
- **`W`/`C`/`I` + `,`/`.` month scrubber (debug):** previews **any**
  month's prevailing winds, seasonal ice, active lane variants and the
  reversed Somali — pure view state, `GameState` untouched (a save taken
  mid-preview round-trips identically).
- **Stalled-fleets row + stall tooltips (unified-movement amendment):**
  every fleet entry carries `holds`/`stall` (`60-*` §4.12.3) — the side
  legend's 停滞舰队 (`debug.legend.stalls`) row shows the census
  (`blocked/camping/docked/cooldown` counts). Hovering the map opens a
  **floating window at the cursor** that lists **every fleet on the
  hovered tile**, each with its own debug block
  (`id · role · nation · stall×holds`, docked adds `@ port`) — stacked
  fleets all report; wrecks, ports and intel keep single-line entries.
  Each block ends in two developer-facing raw lines: **`[raw]`** — the
  live fleet state (`cell / dwell / day / legs / ti / holds / carry /
  mark`, `mark` at 10⁻³ clock precision, never rounded to the day) — and
  **`[raw2]`** (accrual telemetry, amended 2026-11-01): `now` (the
  absolute world clock `day + clock_fraction`), `pend` = `now − mark`
  (what the fleet's NEXT accrual would grant; **negative ⇒ frozen** —
  its mark is ahead of the clock), `lastd` (the Δ the last accrual
  granted), `moved` (that accrual changed the position), `skip`
  (`cooldown` / `stale_mark` / `docked` when a pass granted nothing),
  `committed` / `budget` / `pipe` (lane tiles actually walked / the day
  budget / the §4.4 rate at recording time), `cd` (cooldown_until_day)
  and `leg0` (the current leg `id[a..b]R<> ti/walked_len`). A fleet that
  only moves on day jumps shows `lastd≈1.0 moved=1` once per day with
  `pend` untouched between — a per-move accrual that never runs; a
  frozen fleet shows `pend<0`. A third **`[raw3]`** line (journey
  history, amended 2026-11-01) carries `dest` (the destination port id,
  shown even with no heading — the summary line hides it then), `mooring`
  (the port whose **berth tile the fleet actually stands on**, `-` in
  open water — never a destination fallback) and `ev` (the per-fleet
  journey event ring, oldest first, capped 8: `spawn`, `dep a→b` route
  armed, `depX a->b` no route found, `drop wedge|leg|seam:<id>` a
  mid-route drop with its cause, `arr <port>`). A fleet stuck in a
  drop/re-depart cycle shows a `dep→drop→dep→drop` chain here.
- **Annotated raw lines (amended 2026-11-02):** the three raw lines render
  **fully localized** — each line opens with its section title
  (`debug.raw.sec.state/accrual/journey`; the literal `[raw]`/`[raw2]`/
  `[raw3]` telemetry names live only in this section's prose and in the
  `markers()` wire format, never in the window) and every `key=value`
  token renders as `<gloss> <value>` (`debug.raw.f.<key>`, 22 keys, one
  per raw field; e.g. `目的港 塞维利亚` / `dest port Seville`). The raw
  `key=value` payload itself stays the `markers()` wire format (this
  section, the `test_npc_fleets.gd` assertions) but is **not echoed**
  into the window.
  Id values render as their localized names when they resolve, else the
  raw id (the legend's fallback rule): `dest` / `mooring` port ids,
  `leg0`'s id (a lane id on lane legs, a port id on spokes; its
  `[a..b]R<> ti/walked` tail keeps its numbers), and the `ev` event ids
  (`dep a->b` / `depX a->b` port ids, `arr <port>`, the
  `wedge|leg|seam:<id>` causes). `ev` renders fully localized
  (`debug.raw.ev.*`: 出生/起航/起航失败/丢弃/抵达 + wedge/leg/seam/leg-ti)
  with the `@<day>` stamps kept; `skip` values localize via
  `debug.raw.skip.*`. Value hints: `pend < 0` appends
  `debug.raw.hint.frozen` (mark ahead ⇒ frozen, the discriminator above)
  and `mark < 0` appends `debug.raw.hint.no_mark`. Non-key continuation
  tokens (`leg0`'s `ti/walked_len` tail) extend the preceding field.
  Fields join with ` · ` (the summary line's separator) and each section
  **pre-wraps at field boundaries** — a greedy fill to the fold cap
  `min(560, viewport width × 0.5)` px measured with the window's own
  font, so a wrap never cuts a gloss or a value in half. The window
  reads at a dedicated **13 px** font (smaller than the default 16 —
  stacked reports must stay compact); the label keeps autowrap off and
  the panel re-fits — and shrinks — on every show. Stacked fleet blocks
  separate with a blank line. Position clamping is unchanged.
- **Berth truth (`stranded`, amended 2026-11-01):** a legs-empty fleet
  holding its dwell is `docked` **only** when it stands on a port's berth
  tile; holding in open water is `stranded` — the summary line shows its
  cell instead of a port name it is nowhere near, the S3 badge wears `X`,
  and the day tick snaps it to the nearest resolvable berth (its
  destination's, else its own nation's nearest port) before any dwell
  expiry departs. `debug.stall.stranded` localises the state.
  The world-map S3 markers wear the same state letter as a `BAD` badge
  while the S19 row is on (§4.5.2) — `X` marks a docked fleet standing
  OFF its berth (an anomaly the day tick self-heals, `60-*` §4.11.11).
- **Port hover + click-to-inspect (Phase-8 amendment, 2026-11-02):** while
  the S19 row is on, hovering a port (within 8 px of its dot, or on its
  shore/berth tile — the same hit rule the bare-id fallback used) replaces
  that bare id with a **port summary block** in the same floating window,
  appended after any fleet blocks on the tile: name (L10n + raw id) ·
  nation/class (`debug.port.class.*`; 中立 neutral) · alignment + derived
  dev · market pulse (特产/需求/缺货 stock-0/满仓 at-capacity counts + the
  active demand event's name and days left) · fleet counts (停靠 docked /
  在途 inbound, read off the same `markers()` pass) · the player line
  (tariff badge reusing `market.tax.badge.*`, investment discount, month
  allowance at contestable ports, `debug.port.closed_for_player` while a
  bounty closes the port) · berth/shore tiles. The summary's second line
  appends the `debug.port.f.capital` tag at a nation's capital. **Clicking
  a port opens a
  pinned, scrollable full report panel at the port** (hit-tested on press:
  a press on a port is a click, never a pan; clicking elsewhere closes the
  panel and pans as before; `Esc` closes the panel first). The panel reads
  at the hover window's 13 px font, pre-wraps with the panel's own font to
  a fixed **440 px** width and caps at **62 % of the viewport height**
  (the no-autowrap discipline — Label wrap minimums never drive the
  geometry; the world stays visible behind it). The panel has
  eight sections (`debug.port.sec.*`): 概览 overview (the hover summary),
  市场 market (every listed port-good as one line — 产/需 side, stock /
  capacity, price factor, marginal buy/sell prices, `debug.port.no_buy`
  on produced rows, `debug.port.surge` while a demand event surges the
  good ×3; produces first, demands by factor descending), 账本 ledger
  (contestable only: per-nation raw → effective (owner ×1.25) values,
  the 5,000g alignment line state, the total; protected ports print
  `debug.port.ledger_none`), 设施 facilities (each row open/closed right
  now + its `{open}–{close}` hours, the shipyard's buildable ships,
  the equipment stock), 舰队 fleets (docked fleets one line each —
  id · role · nation · dwell deadline — and inbound ones likewise; the
  per-fleet raw blocks stay tile-hover-only), 几何 geometry (berth/shore
  tiles, lat/lon, band), 数据 data (raw produces/demands id lists,
  sphere, authored dev floor vs derived), 玩家 player (rep with the
  alignment nation, permit coverage, title sell bonus, closed state).
  Read-only throughout: neither the hover nor the panel ever mutates
  `GameState` (the §4.6 debug governance), and the panel is a one-shot
  build per open — no per-frame work.
- **Deep inspection zoom (unified-movement amendment):**
  `ZOOM_MAX` 8 → **64** (wheel ×1.25 per notch unchanged) and the terrain
  texture renders at the **map's native 4320×2160** — deep zoom stays
  crisp instead of magnifying a fit-view downscale; fleet squares scale
  to half a screen-tile. Pure view state. Per-fleet debug info shows in
  the hover window, never drawn on the map itself.
- **Info strip — removed (amended 2026-11-01):** the Year/Month, preview
  month, density and fleet-count rows went away as chart-local noise (the
  HUD already carries the calendar); the scrubbed month reads from the
  `W`/`C`/`I` layers themselves.
- **Side legend panel:** fixed width, anchored right **between** the bars —
  never over the top bar (`关闭海图` stays reachable). When its rows
  overflow the panel's height, the rows **scroll vertically** inside the
  panel instead of growing it; the whole world stays visible (§4.6
  "downscaled to fit").
- **Mouse view (amended 2026-11-01):** the wheel zooms **1.0×–8.0×**
  (×1.25 per notch, anchored at the cursor — the world point under the
  pointer stays put); dragging with the left/right button pans **1:1**,
  clamped so the map never leaves the view; opening the chart (or a window
  resize) restores the **fit view**. Zoom/pan are event-driven redraws of
  the existing caches — never a rebuild, never per-frame work; the base
  raster stretches nearest-neighbour, the vector layers (arrows, lanes,
  markers) re-project crisply.
- **Interactive legend rows (amended 2026-11-01):** clicking a side-legend
  row shows/hides what it depicts — the lane rows, 港口支线 (spokes),
  咽喉要地 (chokepoints), the role rows, 沉船 (wrecks), 猎捕情报 (hunter
  intel) and the 中立港 row are **draw-time visibility filters** over the
  existing caches (no rebuild); the 全知视图/风带/洋流/海冰 rows toggle the
  same state as their `D`/`W`/`C`/`I` keys. A hidden row dims to **0.35
  alpha**. Chart-local, session-only, never persisted.
- **Redraw triggers:** open, layer/month toggle, `day_advanced` — **no
  per-frame work**.
- **Governance:** a documented cheat — read-only, never mutates
  `GameState`, gates nothing gameplay-wise.
- **Lane heat dots (optional Phase-5 flag):** behind a `chart.lane_heat`
  flag (default **off**) the chart may draw small `ACCENT` dots along the
  `trade_routes_built.json` lanes, denser where fleet traffic is higher —
  purely cosmetic. Implemented only if the wave has slack (tasks L/M);
  otherwise the flag stays off and the chart ships without the layer.

### 4.7 Save / load UX

- **Save:** available only at port (S4 menu row + F5). Slot dialog lists 3
  slots with summary line (`Day · Nation · gold · timestamp`) or `Empty`.
  Choosing a non-empty slot asks to confirm overwrite. After write: toast
  `ui.saved` + `EventBus.save_completed`.
- **Load:** title-screen Load (always) + F9 quick-load slot 1 (with confirm).
  Loading routes to S4 if `current_port` set, else S3.
- No autosave.
- **Save version:** current format is **version 9** (`90-*` §8.2; Phase 8,
  2026-11-02 — v8 was the explored-state amendment, v9 is the RPG
  overhaul). There is **no migration chain** — a payload older than v9
  (v8 included) is refused like any corrupt or future-version file.
- Corrupt or future-version file → slot line shows `ui.save.invalid` and is
  not selectable (`90-*` §8.2).

#### 4.7.1 S10 battle screen (Phase 9 rewrite)

Phase 9 rebuilds the presentation: the Phase-2 16×10 MP grid becomes a
48×30 physics world with a free camera, a minimap and overlays. Layout,
1920×1080, placeholder shapes only (§4.8 palette):

```
+------------------------------------------------------------------+
| Battle · Day 12 · Round 3        [weather]      [Esc: menu]      | top 40px
+------------------------------------------------------------------+
| battle world 48×30 tiles @ 32px = 1536×960                       |
| camera viewport 1280×584 (the bottom bar takes the rest)         | 584px
|  ship tokens: 24×24 squares with a letter (§4.8)                 |
|  overlays: reachable vectors · arc fans · side marks · hook ring |
|                                [minimap 192×120, top-right]      |
+------------------------------------------------------------------+
| ‖vel‖ · heading8 · port/starboard reload pips · wind · weather   | bottom 96px
| [1 round] [2 chain] [3 armor-piercing] [4 grape]         [fit]   |
+------------------------------------------------------------------+
```

- **World & camera.** The battle world is 48×30 tiles at 32 px =
  1536×960; the camera viewport is 1920×944 (the bottom bar takes the
  rest of the 1920×1080 window). The camera auto-centers on the acting
  unit until the first manual pan — a manual pan pauses follow until the
  next unit's turn. Pan with RMB/MMB drag; zoom with the wheel at
  0.6×–1.5×, anchored at the cursor; edge scroll runs off a 16 px screen
  band at 600 px/s (§4.3); `Home` or the `[fit]` button fits the whole
  1536×960 world. All camera math lives as pure functions in
  `battle_screen.gd` (world↔screen mapping, clamp, zoom anchor, minimap
  mapping, the 4 px click/drag threshold) with fixed-value assertions in
  `tools/test_battle_screen.gd`.
- **Minimap.** 192×120 px (4 px/cell), top-right: the viewport frame,
  ship dots in the §4.8 pin colors (player/enemy; a navy fleet's dot
  takes its owner's `Nation.color`), the wind arrow, the current arrow
  and — Phase 9 W4 — the formation anchor lines
  (`line_ahead`/`column`). The minimap owns input before the world view;
  clicking it jumps the camera.
- **Bottom bar.** `‖vel‖` (1 decimal), the heading8 token, per-side
  reload pips (port / starboard), the wind direction + weather icon and
  the `[fit]` button — `battle.*` keys throughout.
- **Overlays.** the reachable-set velocity vectors for the acting ship
  (the `legal_velocities` endpoints, `60-*` §4.12.1), the two broadside
  arc fans (port {45°,90°,135°} / starboard {225°,270°,315°}), the
  target side indicators, and the hook-highlight ring on hookable
  targets (the `60-*` §4.6a condition).
- **Shot selector.** four buttons — round / chain / armor-piercing /
  grape (`battle.shot.*`) — showing the current side's availability.
  Gate-locked states render grayed with the required gunnery value
  (chain 25, armor-piercing 50); grape is disabled beyond range 1.
  Buttons 1–4 pick the shot type (§4.3).
- **AI-turn speed switch (battle menu).** 跟随动画 animate / 即时结算
  instant — whether the AI's turns play out as animation or resolve at
  once.
- **Input.** per §4.3: left-click a reachable endpoint / enemy token =
  move / the default action; `Tab` cycles own ships, arrows move the
  cursor, `Enter` confirms, `Esc` opens the battle menu (Retreat /
  Surrender / the AI-turn speed switch / back). Every action appends one
  log line (bottom panel, last 3 lines visible). All buttons carry
  `battle.*` keys.
- **Presentation.** tokens stay placeholder shapes per §4.8 (player
  ships `TEXT` white, pirate `BAD` red, navy the owning nation's
  `Nation.color`). The duel modal (S11) presentation is unchanged —
  `duel_modal.tscn` instanced over S10 shows both sides' rolls per round
  (three rows max) and closes with `duel.*` result text; it owns all
  input while open.
- **Captain intro preview (Phase 8, unchanged):** the battle opens with
  a one-card preview of the opposing flagship captain's §4.12 character
  card (identified = full reveal), dismissed with any input before the
  first round.
- **After-action:** a `dialog_box`-style modal lists loot gold, captured
  ships, XP and reputation deltas, then returns to S3 (`60-*` §4.11.10)
  — except a **sandbox** battle, whose ending is a read-only dialog and
  returns to S21 with the configuration kept (§4.7.16).

### 4.7.2 S6 shipyard refit + equipment rows (Phase 2)

Below the per-ship repair row, each hull gains:

- **Cannons** — numeric picker (0 … `max_refit`) priced at 100g/cannon, with
  the 50g sell-back shown for the current count, enabled in Phase 2
  (`ShipyardEngine.refit`).
- **Equipment** — four slot rows (`weapon`, `armor` on the player;
  `figurehead`, `sail` on the ship), each with the equipped item name or
  `ui.empty`, plus a buy list of every `data/equipment.json` item for that
  slot. Buying into an occupied slot sells the old item back at half price in
  the same action (`60-*` §4.11.12).

### 4.7.3 Phase-3 screens (S12, S13, S16) and their tabs

Same palette, 8px grid, 32px table rows and 40px buttons as every other
screen; no textures.

**S12 `guild_screen.tscn`** (wireframe: `30-*` §4.8 "Guild"). Two stacked
sections:

- *Offers* — one row per generated offer (0–3): a type tag
  (`quest.type.delivery|bounty|exploration`), the composed objective line
  (`quest.line.delivery` / `.bounty` / `.exploration`, numbers supplied by
  code per `10-*` §3.3 rule 5), days remaining, gold reward, and two buttons
  `Accept` (`quest.accept`) / `Hint` (`quest.hint`, exploration offers only —
  shows `region_hint` free). A disabled Accept carries its reason
  (`quest.slots_full`, `quest.no_hold`, `quest.accepted`); an empty list shows
  `quest.slots_full` when the slots are the cause, else `ui.empty`.
  The header line `guild.offers_refresh` says when the list changes, and a
  `tournament.status` line under it announces this month's bracket
  (`70-*` §4.9.7).
- *Reports* — one row per found-but-unreported discovery: name, the
  `guild.report_reward` line (gold · fame) and a `Report` button; empty
  state `guild.report.none`.

**S13 `palace_screen.tscn`** (wireframe: `30-*` §4.8 "Palace"). Rows, top to
bottom:

- Title row: current `rank.<id>` name plus the next rank + its two
  requirements (`palace.title.next`), and `Attend ceremony`
  (`palace.ceremony`) when both are met.
- Royal mission row: current mission objective + days left
  (`palace.mission.active`), else the offered kind's name and `Accept`.
  Disabled with `palace.rep_locked` under rep 30 and `palace.mission_active`
  while one is running.
- Bays row: `Repair fleet` (`palace.repair`, shows the 20% discount when the
  title is count+).
- Bounty row: `bounty.pay` with the amount, or `bounty.none`.
- Tournament row: host + window (`tournament.status`), `Enter` (1,000g) when
  the window is open, `tournament.blocked_bounty` / `tournament.closed` (out
  of window) / `tournament.entered` otherwise.
- `Retire` row (duke only) → `palace.retire.confirm`.
- Permit row + commendation dialog (Phase 7, §4.7.13).

**S16 `ending_screen.tscn`** (root scene, not a modal): dimmed background, a
centered panel with `ending.title`, the six summary rows of `70-*` §4.7, and
one button `ending.continue` → S1. In `retired` load mode the panel title is
`ending.retired_title` and no Continue route back into play exists.
Phase 8 adds the read-only RPG section above the summary rows (§4.14).

**Tavern `Rumors` tab (S7, Phase 3).** Third tab beside `Crew | Officers`.
Above the rows, the monthly tournament announcement (`tournament.status`, plus
`tournament.not_host`/`tournament.closed` when this port cannot host). Rows: up
to three unfound discoveries, each showing `region_hint` free (blurred
until bought is not required — Phase 3 shows the hint text, and the 100g buys
the **location**, i.e. it reveals the discovery name and marks it hinted for
the quest/UI) plus `Buy — 100g` (`tavern.rumor.buy`). Disabled reasons:
`tavern.rumor.bought`, `tavern.rumor.no_gold`; empty state
`tavern.rumor.none`.

**The intel window's 委托 tab (§4.5, migrated from the retired S14 tab,
2026-11-03).** The tab shows `char.quests`: one row per active quest with type
tag, objective, destination (`quest.dest`, always naming the port even if
unknown), days left (`quest.days_left`), and a `quest.abandon` button that
fails it (same −5 rep path). Above the rows: `quest.slots` = `n / max`
(max 3, or 4 at viscount,
`70-*` §4.9.2).

### 4.7.4 Phase-3 `ui_strings.json` inventory (S12/S13/S16)

Required keys — the master applies them in one commit per wave; subagents must
not invent any other key (report the need instead). Placeholders must match
between zh and en (the validator enforces it).

| Key | zh | en |
|---|---|---|
| `port.closed_bounty` | 该港因悬赏封闭 | Closed by bounty |
| `port.stub.phase3` | 第三阶段开放 | Opens in Phase 3 |
| `rank.none` | 平民 | Commoner |
| `rank.knight` | 骑士 | Knight |
| `rank.baron` | 男爵 | Baron |
| `rank.viscount` | 子爵 | Viscount |
| `rank.count` | 伯爵 | Count |
| `rank.duke` | 公爵 | Duke |
| `guild.title` | 公会 — {port} | Guild — {port} |
| `guild.offers` | 委托 | Commissions |
| `guild.offers_refresh` | 委托将在第 {day} 天更新 | New commissions on day {day} |
| `guild.report.section` | 发现报告 | Discovery reports |
| `guild.report.none` | 暂无待报告的发现物 | No unreported discoveries |
| `guild.report.action` | 报告 | Report |
| `guild.report_reward` | {gold} 金 · 声望 +{fame} | {gold} gold · +{fame} fame |
| `quest.type.delivery` | 运送 | Delivery |
| `quest.type.bounty` | 悬赏 | Bounty |
| `quest.type.exploration` | 探索 | Exploration |
| `quest.type.royal` | 王室委托 | Royal mission |
| `quest.line.delivery` | 将 {quantity} 单位{good}送抵{port} | Carry {quantity} {good} to {port} |
| `quest.line.bounty` | 讨伐{target}(等级 {tier}) | Hunt {target} (tier {tier}) |
| `quest.line.exploration` | 循着传闻寻找一处发现物 | Follow a rumour to a discovery |
| `quest.line.royal` | {objective} | {objective} |
| `quest.accept` | 接受 | Accept |
| `quest.accepted` | 已接受 | Accepted |
| `quest.hint` | 提示 | Hint |
| `quest.slots` | 委托 {used} / {max} | Quests {used} / {max} |
| `quest.slots_full` | 委托栏已满 | All quest slots are full |
| `quest.no_hold` | 货舱空间不足 | Not enough hold space |
| `quest.dest` | 目的地:{port} | Destination: {port} |
| `quest.days_left` | 剩余 {days} 天 | {days} days left |
| `quest.abandon` | 放弃委托 | Abandon quest |
| `quest.completed` | 委托完成:{name} | Commission complete: {name} |
| `quest.failed` | 委托失败:{name} | Commission failed: {name} |
| `quest.reward` | +{gold} 金,声望 {rep} | +{gold} gold, reputation {rep} |
| `char.quests` | 委托 | Quests |
| `palace.not_capital` | 只有首都才设有王宫 | Only a capital has a palace |
| `palace.title` | 王宫 — {port} · {nation} | Palace — {port} · {nation} |
| `palace.title.current` | 你的爵位:{rank} | Your title: {rank} |
| `palace.title.next` | 下一爵位:{rank}(声望 {fame} · 王室委托 {missions}) | Next rank: {rank} (fame {fame} · royal missions {missions}) |
| `palace.ceremony` | 参加授勋典礼 | Attend the ceremony |
| `palace.ceremony.done` | {nation}授予你{rank}爵位。 | {nation} grants you the title of {rank}. |
| `palace.title.max` | 已是最高的公爵爵位 | You already hold the highest title |
| `palace.mission.section` | 王室委托 | Royal mission |
| `palace.mission.accept` | 接受王室委托 | Accept the royal mission |
| `palace.mission.active` | {objective}(剩余 {days} 天) | {objective} ({days} days left) |
| `palace.mission_active` | 该国的王室委托仍在进行中 | That nation already has your mission |
| `palace.rep_locked` | 声望需达到 {rep} 才能接取王室委托 | Requires reputation {rep} for royal missions |
| `palace.mission.done` | 王室委托完成:{name} | Royal mission complete: {name} |
| `palace.repair` | 修缮船队 | Repair the fleet |
| `palace.repair.discount` | 修缮费用减免 {percent}% | Repairs cost {percent}% less |
| `palace.retire` | 退休 | Retire |
| `palace.retire.confirm` | 确定要退休,结束这段航程吗? | Retire and end this voyage? |
| `bounty.pay` | 缴纳悬赏金:{gold} 金 | Pay the bounty: {gold} gold |
| `bounty.none` | 本国没有针对你的悬赏 | No bounty stands against you |
| `bounty.issued` | {nation}对你发布了悬赏。 | {nation} has issued a bounty on you. |
| `bounty.cleared` | 你与{nation}的悬赏已解除。 | Your bounty with {nation} is settled. |
| `bounty.no_gold` | 金币不足以缴纳悬赏 | Not enough gold to pay the bounty |
| `tournament.not_host` | 本月比武大会在别处举行 | This month's tournament is held elsewhere |
| `tournament.status` | 比武大会:{port}(本月第 {first}–{last} 天) | Tournament: {port} (month days {first}–{last}) |
| `tournament.enter` | 报名参赛(1,000 金) | Enter the tournament (1,000 gold) |
| `tournament.entered` | 已报名,本次大会正在等待开赛 | Entry recorded — the tournament is waiting |
| `tournament.closed` | 本月大会的报名期已结束 | This month's entry window has closed |
| `tournament.blocked_bounty` | 悬赏在身,王宫拒绝你参赛 | The palace bars a wanted captain |
| `tournament.round` | 第 {round} 场 | Bout {round} |
| `tournament.won` | 你赢得了比武大会! | You win the tournament! |
| `tournament.lost` | 你在第 {round} 场落败。 | You were beaten in bout {round}. |
| `tournament.prize` | 奖金 {gold} 金,声望 +{fame} | Prize {gold} gold, +{fame} fame |
| `tournament.consolation` | 安慰奖 {gold} 金,船队免费修复至五成 | Consolation {gold} gold; your fleet is repaired to half |
| `discovery.explore` | 探索周边(E) | Explore the area (E) |
| `discovery.found` | 发现:{name}! | Discovery: {name}! |
| `discovery.found.hint` | 可到公会报告换取报酬 | Report it at any guild for a reward |
| `discovery.something_near` | 附近似乎有不寻常的事物(E) | Something unusual is nearby (E) |
| `world.explore.none` | 附近没有任何发现 | Nothing to discover here |
| `tavern.rumor_tab` | 传闻 | Rumours |
| `tavern.rumor.price` | 传闻售价 {gold} 金 | Rumours cost {gold} gold |
| `tavern.rumor.buy` | 购买传闻 | Buy the rumour |
| `tavern.rumor.bought` | 已购买 | Already known |
| `tavern.rumor.no_gold` | 金币不足 | Not enough gold |
| `tavern.rumor.none` | 酒馆里没有新的传闻 | No new rumours in this tavern |
| `ending.title` | 航程终章 | Voyage's End |
| `ending.retired_title` | 这位船长已经退休 | This captain has retired |
| `ending.days` | 航行天数:{days} | Days sailed: {days} |
| `ending.gold` | 结余:{gold} 金 | Gold: {gold} |
| `ending.fame` | 声望:{fame} | Fame: {fame} |
| `ending.titles` | 爵位:{titles} | Titles: {titles} |
| `ending.discoveries` | 发现物:{count} | Discoveries: {count} |
| `ending.battles` | 胜战:{count} | Battles won: {count} |
| `ending.continue` | 返回标题 | Return to the title |
| `nation.world` | 世界地图 | World map |

The Phase-3 `nation.world_p1` / `nation.world_p3` selector labels are retired
with the S2 map choice (there is exactly one map, `70-*` §4.9.8).

### 4.7.5 Phase-4 `ui_strings.json` inventory (S3 sailing + S17 Chart)

Required Phase-4 keys; placeholders must match between zh and en (the
validator enforces it). A task needing another key reports it instead of
inventing one.

| Key | zh | en |
|---|---|---|
| `chart.title` | 海图 | Chart |
| `chart.close` | 关闭海图 | Close the chart |
| `chart.hint` | 已探索海域 | Explored waters |
| `chart.legend.port` | 已知港口 | Known ports |
| `chart.legend.fleet` | 船队 | Fleet |
| `chart.legend.discovery` | 发现物线索 | Discovery leads |
| `world.move_blocked` | 此处无法通行 | Cannot sail there |
| `world.sail.no_path` | 无可行航线 | No route by sea |
| `world.sail.arrived` | 已抵达目的地 | Destination reached |

Display-format keys (amended 2026-11-02, `80-*` §4.5; `world.day` /
`world.provisions` / `world.water` remain as the day-only label and the
supply-kind nouns): `world.day_time` 第 {day} 天 {time} / Day {day} {time},
`world.speed` 航速 {speed} 节 / Speed {speed} kn, `ui.speed.noun` 航速 / Speed,
`world.cargo` 货舱 {amount}/{capacity} 吨 / Cargo {amount}/{capacity} t
(`char.day` carries {time} too, §4.7.3 inventory).

### 4.7.6 Phase-5 polish `ui_strings` inventory (S15/S18 + provisioning)

Required keys for the §4.5.1 stat block, §4.6.1 prompt and §4.6.2 panel.
Placeholders must match between zh and en.

| Key | zh | en |
|---|---|---|
| `port.sail.prepare` | 出航准备 | Prepare to Sail |
| `port.sail.days` | 可航行天数:{days} | Days at sea: {days} |
| `port.sail.days_zero` | 补给不足,无法出航 | Not enough supplies to sail |
| `port.sail.no_crew` | 没有船员,无法出航 | No crew aboard — cannot sail |
| `port.sail.no_supply` | 补给不足一天,无法出航 | Less than a day of supplies — cannot sail |
| `port.sail.short_warning` | 离港后第 {days} 天起可能断粮。 | Supplies may run short after {days} days. |
| `port.sail.stay` | 留在港口 | Stay in port |
| `port.sail.buy` | 购买 {qty}({gold}g) | Buy {qty} ({gold}g) |
| `port.sail.jettison_hint` | 货舱已满,请先抛弃部分货物。 | Hold is full — jettison some cargo first. |
| `port.sail.jettison` | 抛弃 | Jettison |
| `port.sail.jettison.confirm` | 抛弃{kind} × {qty}? | Jettison {kind} × {qty}? |
| `fleet.ship_header` | 舰队 | Fleet |
| `fleet.stat.durability` | 耐久 {current}/{max} | Durability {current}/{max} |
| `fleet.stat.cargo` | 载重 {used}/{capacity} 吨(剩余 {free} 吨) | Cargo {used}/{capacity} t ({free} t free) |
| `fleet.stat.crew` | 船员 {crew}/{max} | Crew {crew}/{max} |
| `fleet.stat.guns` | 火炮 {cannons}/{slots} | Guns {cannons}/{slots} |
| `fleet.stat.speed` | 航速 {speed}/{max} 节(风:{wind}) | Speed {speed}/{max} kn (wind: {wind}) |
| `fleet.stat.supply` | {kind} {amount}({days} 天) | {kind} {amount} ({days} days) |
| `fleet.totals` | 船队合计 | Fleet totals |
| `fleet.total_days` | 全队可航行 {days} 天 | Whole fleet: {days} days |
| `officers.title` | 官员 | Officers |
| `officers.slots` | {used} / {max} · 日薪 {wage}g | {used} / {max} · wages {wage}g/day |
| `officers.effect` | 效果:{effect} | Effect: {effect} |
| `officers.recruited_at` | 雇佣于:{port} | Hired at: {port} |
| `officers.dismiss` | 解雇 | Dismiss |
| `officers.dismiss.confirm` | 确定要解雇{name}吗? | Dismiss {name}? |
| `officers.empty_hint` | 在酒馆招募新官员 | Recruit officers at a tavern |
| `officers.readonly_sea` | 海上无法解雇官员 | Officers cannot be dismissed at sea |

#### 4.7.7 Market stock + trend + marginal price (S5, Phase 5)

The market table (wireframe `30-*` §4.8) gains three columns; rows stay
32px, palette-only, no textures:

```
+------------------------------------------------------------------------+
| 商品 Good | 存货 Stock | 走势 Trend | 边际价 Marginal | 持有 | 买/卖     |
|------------------------------------------------------------------------|
| 葡萄酒    | 87         | ▲ 回升     | 21金 / 16金      | 30   | [买] [卖] |
+------------------------------------------------------------------------+
```

- **Stock** — the port-good's current stock, `0 … 200`, hard-clamped
  (`30-*` §4.2).
- **Trend** — a one-glyph drift arrow (▲ refilling in `GOOD`, ▼ draining in
  `BAD`) derived from recent stock deltas; no forecast is shown.
- **Marginal price** — the **marginal (next-tranche) price** (`30-*` §4.4):
  buying and selling reprice per 10-unit tranche, and the column always
  shows the price the *next* tranche would trade at, never the average; the
  ledger sums tranches exactly. (Format amendment, 2026-11-03: the cell
  renders the next-tranche **buy / sell pair**, `买价金 / 卖价金` — the
  §4.8 wireframe's marginal column matches the implementation.)
- Strings: `market.stock.*` (§4.7.9).

#### 4.7.8 Captain sighting surfaces (Phase 5)

Every docked NPC fleet has a named captain (`60-*` §4.11.11.4) that may be
sighted in port facilities. The rolls are **seeded and visit-stable** — no
flicker on re-open, re-rolled on the next visit-day (`IMPLEMENT-Phase5.md`
decision 9).

- **Facility roll (locked):** seeded `(fleet_id, port_id, arrival_day)` —
  **60%** the primary facility (`trader`→market, `coaster`/`patrol`/
  `courier`/`privateer`→tavern, `hunter`→palace bounty board; any docked
  fleet is **inn-eligible**), else **40%** a uniform alternate from the
  `{market, tavern, inn}` plausible sets; a hunter is **palace-only**.
- **Presence roll (same seed family, locked):** **75%** sightable that day,
  else "gone ashore" — absent from every facility that day.
- **Surfaces:**
  - *Market (S5):* "merchant captains in port" rows under the trade table —
    captain name, nation, role (`captain.role.*`).
  - *Tavern (S7):* a captains section listing sighted captains, plus
    **wanted posters**: a `pirate`/`privateer` captain within Chebyshev 40
    of the visited port shows a poster row (name, tier, last-known
    position, reward hint). One action per poster — **"buy a round — 20g"**
    (`captain.reveal.buy`) → a rumor text line with the **exact live
    position** (tile + nearest port). Text only; **at-sea posters only**
    (a docked captain needs no reveal); no chart ping/marker (Phase-6
    candidate).
  - *Inn (S8):* "captains resting" list rows under the odd-job rows.
  - *Palace (S13):* the bounty board lists docked **hunter** captains.
- **Tavern rumor rows (locked):** a rumor row source = live fleets within
  Chebyshev 40 ("an ottoman convoy left Istanbul for Alexandria") +
  departures/arrivals at this port within 3 days + demand-event telegraphs
  (all ui_strings zh/en; event telegraphs per `30-*` §4.5). Phase 7 adds
  the investment-telegraph source, rumor row kind `"investment"`
  (§4.7.14).
- **All sighting strings** are `captain.*` keys (§4.7.9), zh/en.
- **Phase 8 (2026-11-02):** sighting rows become **interactive** — the
  §4.11.1 verb matrices (market quotes / supply pre-order, tavern
  befriend, inn limited talk, palace bounty business / inform), each row
  opening the captain's §4.12 card; the tavern gains the **captain's
  table** index (§4.11.2); palace bounty rows link to dossiers (§4.11.3).
  The seeded rolls and the 20g poster reveal above are unchanged.

#### 4.7.9 Phase-5 fleet `ui_strings.json` inventory (`captain.*` / `settings.*` / `market.stock.*`)

Required keys for §4.6.3, §4.7.7 and §4.7.8 — the master applies them in one
commit per wave; tasks report needs instead of inventing keys. Placeholders
must match between zh and en (the validator enforces it).

| Key | zh | en |
|---|---|---|
| `settings.title` | 设置 | Settings |
| `settings.close` | 关闭 | Close |
| `settings.density` | 航海密度 | Sea traffic |
| `settings.density.current` | 当前:{preset} | Current: {preset} |
| `settings.density.hint` | 调高后船队将在数日内逐渐补充;调低不会移除现有船队。 | Raising refills fleets over the next days; lowering never removes existing fleets. |
| `settings.density.deserted` | 荒芜 | Deserted |
| `settings.density.low` | 稀少 | Low |
| `settings.density.normal` | 正常 | Normal |
| `settings.density.high` | 繁忙 | High |
| `settings.density.extreme` | 极端 | Extreme |
| `settings.locale` | 语言 | Language |
| `settings.return_menu` | 返回主菜单 | Return to main menu |
| `settings.return_menu.confirm` | 返回主菜单?未保存的进度将丢失。 | Return to main menu? Unsaved progress will be lost. |
| `captain.section.market` | 港内商船船长 | Merchant captains in port |
| `captain.section.tavern` | 港内船长 | Captains in port |
| `captain.section.inn` | 歇脚的船长 | Captains resting |
| `captain.section.palace` | 悬赏猎人 | Bounty hunters |
| `captain.gone_ashore` | {name} 已上岸。 | {name} has gone ashore. |
| `captain.role.trader` | 商船队长 | Trading captain |
| `captain.role.coaster` | 沿岸货船船长 | Coaster captain |
| `captain.role.courier` | 信使船长 | Courier captain |
| `captain.role.patrol` | 护航舰队船长 | Escort patrol captain |
| `captain.role.privateer` | 私掠船长 | Privateer captain |
| `captain.role.pirate` | 海盗船长 | Pirate captain |
| `captain.role.hunter` | 追缉船长 | Bounty hunter |
| `captain.role.treasure` | 宝船船长 | Treasure fleet captain |
| `captain.poster.title` | 通缉令:{name}(等级 {tier}) | Wanted: {name} (tier {tier}) |
| `captain.poster.hint` | 最后出没于{port}附近海域 | Last seen near {port} |
| `captain.reveal.buy` | 请一圈酒 — 20 金 | Buy a round — 20g |
| `captain.reveal.text` | 据说{name}此刻就在({x}, {y})一带,靠近{port}。 | {name} is said to be at ({x}, {y}), near {port}, right now. |
| `captain.reveal.no_gold` | 金币不足 | Not enough gold |
| `market.stock.header` | 存货 | Stock |
| `market.stock.trend` | 走势 | Trend |
| `market.stock.marginal` | 边际价 | Marginal price |
| `market.stock.trend_up` | ▲ 回升 | ▲ refilling |
| `market.stock.trend_down` | ▼ 消耗 | ▼ draining |

#### 4.7.10 Phase-6 navigation `ui_strings.json` inventory (S3 HUD / S17 chart / S19 / neutral ports)

This section is the **orchestrator-merge contract** (§2.9 of
`IMPLEMENT-Phase6.md`): implementing tasks report their final zh/en
strings in their task reports; the **master** edits `data/ui_strings.json`
— no subagent edits the file. Placeholders must match between zh and en.
New families: `world.wind.*`, `world.current.*`, `world.trim.*`,
`world.ice.*`, `world.wait.*`, `world.calendar.*`, `settings.input.*`,
`settings.current.*`, `settings.debug.*`, `chart.wind.*`,
`chart.current.*`, `chart.ice.*`, `debug.*`, plus the neutral-port keys.
The keys each implementing task must define:

| Owner | Keys |
|---|---|
| V (S19 rows) | `settings.input.mode`, `settings.input.step`, `settings.input.helm`, `settings.current.mode`, `settings.current.modifier`, `settings.current.drift`, `settings.debug.overlays` |
| G (HUD / sailing toasts) | `world.wind.label`, `world.current.label`, `world.trim.chip`, `world.trim.furled`, `world.trim.reefed`, `world.trim.normal`, `world.trim.full`, `world.wait.done`, `world.ice.blocked`, `world.calendar.year_month` |
| I (chart layers / debug chart) | `chart.wind.title`, `chart.current.title`, `chart.ice.title`, `debug.title`, `debug.omniscient`, `debug.legend.*`, `debug.lane.*`, `debug.role.*`, `debug.legend.stalls` (unified-movement amendment), `debug.port.*` (the port hover/panel family, §4.6 Phase-8 amendment) |
| neutral ports (§4.8) | `port.neutral.label` (中立港 / Neutral port), `chart.debug.neutral` (the debug-chart legend row for the neutral grey) |

Notes pinning the set exactly:

- `world.calendar.year_month` is the top-bar frame
  `Year {y} · Month {m}` / `{y}年{m}月` (`20-*` §4.15).
- `world.trim.chip` is the chip label (帆位 / Trim); the four
  `world.trim.*` state names also compose the trim-cycle toast — no
  separate toast key.
- `world.ice.blocked` is the refused-entry toast (`20-*` §4.18);
  `world.wait.done` is the waited-one-day toast (`20-*` §4.17).
- `debug.legend.*` covers the network side legend (lane-name rows,
  role-color rows, spokes/chokepoints); the neutral row of the port
  legend uses `chart.debug.neutral`.
- `debug.port.*` (Phase-8 amendment, 2026-11-02): the port hover/panel
  family — 8 section titles (`debug.port.sec.overview/market/ledger/
  facilities/fleets/geometry/data/player`), the per-field glosses
  (`debug.port.f.*`), the class labels (`debug.port.class.protected/
  contestable`, `debug.port.neutral` for `nation_id: ""`), the market
  tokens (`debug.port.side.prod/demand`, `debug.port.factor/buy/sell/
  no_buy/surge`), the ledger state pair (`debug.port.f.aligned/
  unaligned`) and `debug.port.ledger_none` (protected), the open/closed
  facility pair, `debug.port.closed_for_player`, `debug.port.permit_home/
  foreign`, and `debug.port.f.remaining` (`{days}` — the demand event's
  days left). Facility names reuse the `port.<facility>` keys, the
  tariff badge reuses `market.tax.badge.*`; goods and nations read their
  own data L10n names. Ids stay raw (the §4.6 fallback rule).
- `debug.lane.<id>` is one key per locked §7.6 lane id (17, closed set);
  the zh/en strings are §7.6's name columns verbatim. The chart legend
  falls back to the raw `id` only when a key is missing.
- `debug.role.<role>` (8, the locked §4.5.2 role set) names the
  fleet-marker legend rows; the chart prefixes the role's marker letter
  (`T c k P p · N X`) itself. `debug.info.*` was **retired** with the
  info strip (amended 2026-11-01).
- `debug.raw.*` (localized hover raw lines, amended 2026-11-02): the 3
  section titles (`debug.raw.sec.state/accrual/journey`), 22 per-field
  glosses (`debug.raw.f.<key>`, one per raw key — `cell dwell day legs ti
  holds carry mark now pend last lastd moved skip committed budget pipe
  cd leg0 dest mooring ev`), 2 value hints (`debug.raw.hint.frozen` /
  `debug.raw.hint.no_mark`), the `debug.raw.ev.*` event vocabulary
  (9: `spawn/dep/depx/drop/arr/wedge/leg/seam/ti`) and the
  `debug.raw.skip.*` reasons (3: `cooldown/stale_mark/docked`). The
  window renders only the localized text — no raw keys, no `[raw*]` tags;
  the raw `key=value` payload stays the `markers()` wire format (§4.6).
- **Pre-declared per `20-*` §4.15:** `world.calendar.month.1` …
  `world.calendar.month.12` (一月…十二月 / Month 1–12). They are owed by
  whichever surface first renders a bare month name (the likely consumer
  is I's debug scrubber/info strip); the implementing task reports final
  zh/en at merge — the G list above needs none (the top bar composes
  `{y}年{m}月` numerically).

#### 4.7.11 Market rows (S5, Phase 7 — pairs with `30-*` §4.2/§4.4/§4.9/§4.10)

The trade table becomes listing-rule driven and gains the allegiance
surfaces. Rows stay 32px, palette-only (§4.8); every new string is
§4.7.15's.

- **Listing rule (`30-*` §4.2, behavior change):** a port lists a good
  iff it produces or demands it (staples ubiquitous by the data rule) —
  **unlisted goods never render**; the Phase-≤6 "20 rows everywhere"
  behavior is gone.
- **★ 特产 badge + header:** rows for `port.produces` members carry the
  ★ badge (`market.specialty.badge`) in a **fixed reserved slot** at the
  Good column's left — present on **every** row (blank on non-produce
  rows), so all good names align on one column (2026-11-03 amendment);
  a header line above the table names **up to 3** of them
  (`market.specialty.header`, `特产:{names}`) and appends
  `market.specialty.more` (`另有 {count} 种`) when there are more. The
  specialty group is separated from the remaining rows by a thin
  `PANEL_LINE` divider, and rows render **produces-first** (`30-*` §4.8).
- **Selected-row info strip (2026-11-03):** clicking anywhere on a row —
  or typing a quantity — selects it; the strip below the table shows the
  selected row's walked totals (`market.total.buy` / `market.total.sell`,
  the §4.4 `buy_cost` / `sell_gain` queries) with the tax lines
  (below) beneath. Inert rows (locked exclusives, empty quantity) keep
  the totals off.
- **不收购 rows (flow-economy market direction):** a producing port never
  buys its own produced goods — those rows' Sell button is disabled with
  the reason `market.not_bought` (`30-*` §4.2).
- **Exclusive (专营货) rows:** an exclusive good renders for everyone but
  buy/sell is alignment-gated — a non-entitled player sees the row grayed
  with the lock note `market.exclusive.locked` (the port aligned to the
  player's nation **and dev ≥ 2** activates it; `30-*` §4.9/§4.10).
- **Tax badge + lines (`30-*` §4.10):** the header badge has **4 states**
  — `market.tax.badge.in_sphere` (势力内 5%), `market.tax.badge.exempt`
  (免税), `market.tax.badge.foreign` (外国 20%),
  `market.tax.badge.unallied` (未同盟 20%) — and the trade dialog carries
  a tax line **each side** of the totals (`market.tax.buy_line` /
  `market.tax.sell_line`; the tariff applies after all price math,
  provisions/water exempt).
- **Three-state Invest button (decision 26):** the standing Invest 500g
  button renders (a) **available** (label `market.invest` unchanged);
  (b) **allowance-exhausted** — disabled with
  `market.invest_gate.exhausted` plus the hint
  `market.invest_gate.allowance` (≤ 2,000g per contestable port per
  month, reset at the month tick, `30-*` §4.9); (c)
  **diplomacy-blocked** — disabled with `market.invest_gate.blocked`
  (rep ≥ 0 and no bounty vs the port's current alignment nation). The
  state comes from the allegiance module's block-reason contract (§4.9).
- The invested-here discount line (`market.invested_here`) and the
  §4.7.7 stock/trend/marginal columns are unchanged.

#### 4.7.12 Shipyard row states (S6, Phase 7 — pairs with `40-*` §4.3.1)

Hull rows come from the port's stock list and render in exactly **three
states** (correction 11); every row also carries its role label
(`shipyard.role.*`: 战舰/商船/沿岸):

1. **Available** — `in_stock ∧ tier ≤ effective_dev(port)` (effective
   dev per `30-*` §4.9; guard default 0, §4.9): the normal buy row.
2. **Tier-gray 需发展度** — in stock but `tier > effective_dev`: grayed,
   Buy disabled, note `shipyard.tier.need_dev` (需发展度 {dev}).
3. **Allegiance-gray 同盟专营** — neutral-port rows: neutral shipyards
   stock their regional hulls **only under allegiance + dev ≥ 2**, so an
   **unallied neutral shows the full list allegiance-grayed** with the
   lock note `shipyard.tier.allegiance_locked` — never an empty or
   crashing state; the note explains the flip path (invest to align the
   port, grow dev to 2).

The refit tab (§4.7.2) and the equipment buy list are stock-aware too:
equipment rows follow the same three states under the port's
`equipment_stock` (`60-*` §4.11.13). **Rare items never render in any
stock UI** (`60-*` §4.11.13 — drop-only).

#### 4.7.13 Palace permit row + commendation dialog (S13, Phase 7 — pairs with `30-*` §4.10, `70-*` §4.1)

- **Permit row (`palace.permit.*`).** One row under the bays row:
  - at the player's **own nation's** palaces: 本国免税证 (home charter,
    **5,000g**, no title/rep gate) — covers every port whose effective
    alignment == the player's nation, tariff 5% → 0%
    (`palace.permit.home` + `palace.permit.home.coverage`);
  - at any **other nation's** palace: 涉外免税证 for **that nation**
    (**20,000g**, title ≥ Knight, rep ≥ +20) — covers that nation's
    protected + aligned contestable ports (`palace.permit.foreign` +
    `palace.permit.foreign.coverage`);
  - disabled gates: `palace.permit.title_locked` /
    `palace.permit.rep_locked`;
  - both kinds are **void** while that nation's bounty stands or rep <
    −20 — the row shows the void state (`palace.permit.void_bounty` /
    `palace.permit.void_rep`) and a re-buy costs full price;
  - held state `palace.permit.home.owned` / `palace.permit.foreign.owned`;
    purchase toast `palace.permit.bought`; section header
    `palace.permit.section`.
- **Commendation dialog (`palace.commend.*`).** The first time a
  contestable port flips to the player's nation, the palace plays a
  **one-time** commendation dialog (ceremony pattern reuse; tracked per
  port per save, `70-*` §4.1): `palace.commend.title` /
  `palace.commend.body` / `palace.commend.close`.

#### 4.7.14 Tavern investment-telegraph rows (S7, Phase 7 — pairs with `30-*` §4.9)

The Rumors tab gains a second row source, rumor row kind
**`"investment"`** (the kind string is part of the symbol contract,
§4.9): monthly NPC counter-investments render as rows
`{nation} 在 {port} 投资 {amount}g` (`tavern.invest.row`) under the
section header `tavern.invest.header`. Rows are visible for a **30-day
window**, scoped to the **invested port's band** — a tavern shows exactly
the rows whose invested port lies in the same band. Rows come from the
allegiance module's month-investment query (§4.9) through the
`npc_intel.gd` guard read (default: no rows); they expire with the
window like the demand-event telegraphs (§4.7.8).

#### 4.7.15 Phase-7 `ui_strings.json` inventory (orchestrator-merge contract)

This table is the **checklist the master merges into
`data/ui_strings.json`** after W1 (no subagent edits the file — the
Phase-6 §4.7.10 protocol). M (market/tavern) and F (shipyard/palace) use
exactly these keys and must not invent others; zh/en complete,
placeholders matched per key (validator-enforced).

| Key | zh | en |
|---|---|---|
| `market.specialty.badge` | 特产 | Specialty |
| `market.specialty.header` | 特产:{names} | Specialties: {names} |
| `market.specialty.more` | 另有 {count} 种 | +{count} more |
| `market.total.buy` | 买入 {qty} {name} 共 {gold} 金 | Buy {qty} {name}: {gold}g |
| `market.total.sell` | 卖出 {qty} {name} 得 {gold} 金 | Sell {qty} {name}: {gold}g |
| `market.not_bought` | 不收购 | Not bought here |
| `market.tax.badge.in_sphere` | 势力内 5% | In sphere 5% |
| `market.tax.badge.exempt` | 免税 | Tax-free |
| `market.tax.badge.foreign` | 外国 20% | Foreign 20% |
| `market.tax.badge.unallied` | 未同盟 20% | Unallied 20% |
| `market.tax.buy_line` | 买入关税({rate}%):−{gold} 金 | Buy tariff ({rate}%): −{gold} gold |
| `market.tax.sell_line` | 卖出关税({rate}%):−{gold} 金 | Sell tariff ({rate}%): −{gold} gold |
| `market.exclusive.locked` | 同盟专营:同盟且发展度 ≥ 2 后开放 | Allegiance-exclusive: opens when aligned at dev ≥ 2 |
| `market.invest_gate.allowance` | 本月已投 {invested} / {cap} 金 | Invested {invested} / {cap}g this month |
| `market.invest_gate.exhausted` | 本月投资上限已达 | Monthly investment allowance used up |
| `market.invest_gate.blocked` | 声望不足或与{nation}悬赏在身,无法投资 | Blocked: rep below 0 or a bounty with {nation} |
| `shipyard.role.war` | 战舰 | Warship |
| `shipyard.role.trade` | 商船 | Trade ship |
| `shipyard.role.coastal` | 沿岸 | Coastal |
| `shipyard.tier.need_dev` | 需发展度 {dev} | Requires development {dev} |
| `shipyard.tier.allegiance_locked` | 同盟专营:投资使其归属本国且发展度 ≥ 2 后开放 | Allegiance-exclusive: align it by investing; opens at dev ≥ 2 |
| `palace.permit.section` | 免税证 | Tax permits |
| `palace.permit.home` | 本国免税证 — 5,000 金 | Home charter — 5,000g |
| `palace.permit.home.coverage` | 覆盖本国及同盟港:关税 5% → 0% | Covers own + aligned ports: tariff 5% → 0% |
| `palace.permit.home.owned` | 本国免税证:已持有 | Home charter: held |
| `palace.permit.foreign` | 涉外免税证({nation})— 20,000 金 | Foreign permit ({nation}) — 20,000g |
| `palace.permit.foreign.coverage` | 覆盖该国的保护港与同盟港:关税 5% → 0% | Covers that nation's protected + aligned ports: tariff 5% → 0% |
| `palace.permit.foreign.owned` | 涉外免税证({nation}):已持有 | Foreign permit ({nation}): held |
| `palace.permit.title_locked` | 爵位需达到骑士 | Requires the title of Knight |
| `palace.permit.rep_locked` | 声望需达到 +20 | Requires reputation +20 |
| `palace.permit.void_bounty` | 悬赏在身,免税证失效;需全价重购 | Void while your bounty stands; rebuy at full price |
| `palace.permit.void_rep` | 声望低于 −20,免税证失效;需全价重购 | Void below −20 reputation; rebuy at full price |
| `palace.permit.bought` | 已购入免税证。 | Permit purchased. |
| `palace.commend.title` | 褒奖令 | Commendation |
| `palace.commend.body` | {nation}为{port}归入版图向你颁授褒奖令。 | {nation} commends you for bringing {port} into its fold. |
| `palace.commend.close` | 领受 | Accept with thanks |
| `tavern.invest.header` | 投资动向 | Investment news |
| `tavern.invest.row` | {nation} 在 {port} 投资 {amount} 金 | {nation} invested {amount}g in {port} |

Notes pinning the set exactly:

- `market.invest` / `market.invested_here` / `market.invest_cap` already
  exist (Phase 1); only the keys above are new.
- `market.not_bought` is the 不收购 sell-disabled reason — it lives in the
  plain `market.*` namespace beside its siblings, not in a new family.
- `tavern.invest.row` composes the telegraph text; the amounts and names
  are supplied by code (`30-*` §4.9 format `{nation} 在 {port} 投资
  {amount}g`).
- The role labels 战舰/商船/沿岸 are the §2.2-locked zh texts
  (`40-*` §4.3.1).

#### 4.7.16 S21 naval-battle sandbox (Phase 9)

`scenes/combat/battle_sandbox.tscn` — a full naval-battle editor reached
from S1 and a **zero-write** surface: nothing it does ever writes the
save, `GameState`, `NpcFleets`, the phase-3 hooks or world routing.

- **Entry.** S1 gains the 海战 button (`sandbox.title`) in its button
  stack, between New Game and Load. `Esc` returns to S1 (§4.2).
- **Layout (1920×1080).** left = the player panel, right = the enemy
  panel, bottom = the conditions row + `[开战] [随机全部] [导入] [导出]`.
  Every label comes from the `sandbox.*` family inventoried in `10-*`
  §7.12.
- **Player panel.** 1–5 ships, one editable row per ship: ship type (the
  16 hulls), cannons (0 … `armament_slots`), crew (`crew_min` …
  `crew_max`), durability (1 … max), the figurehead + sail equipment
  slots, and the escort captain's canon id (empty = legacy). Beside the
  ships: the five player attributes (each 0–100; labels reuse
  `char.attr.*`) and the weapon/armor equipment slots — injected into
  the battle through the `60-*` §4.12.1 `player_stats` seam — plus the
  initial morale (0–100).
- **Enemy panel.** the kind (9 kinds), a one-click `compose_enemy`
  generation toggle **or** per-ship rows in the same shape as the
  player's, the captain id (canon / legacy), `ai_level` ∈ {0,1},
  `archetype`, `formation` and the initial morale. The `ai_level` /
  `archetype` / `formation` overrides ride the forward-compatible schema
  below and take effect as their waves land (9C/9D).
- **Conditions row.** day; seed (`seed_mode` ∈ `fixed|random|auto` —
  `auto` = the `60-*` §4.11.1 formula); weather
  (`calm`/`fair`/`strong`/`storm`); `wind_dir` (8 tokens); the current
  `{dir, strength 0..3}`; the deployment variant (`standard` /
  `tournament`).
- **Clamp rules.** every field clamps immediately in the UI layer to the
  ranges above; an invalid combination never reaches 开战.
- **Editor presentation (W4 gate amendment, 2026-11-04, from the S21 UI-fix
  pass):** `随机全部` randomizes every editor field within its clamps and
  NEVER rolls the compose mode (composing stays an explicit user choice —
  the mode toggle only ever hides the per-ship rows + fleet buttons, never
  the enemy editors block); equipment dropdowns show the authored
  localized item `name`s (the `shipyard_screen` convention — metadata
  stays the id); each ship editor renders as a compact multi-line block
  (type/captain, cannons/crew/durability, then full-width figurehead and
  sail lines) so no label clips and every control stays inside its panel.
- **Import/export (forward-compatible schema).** `[导出]` copies the FULL
  configuration JSON to the clipboard; `[导入]` parses clipboard JSON and
  restores the editors. The schema declares ALL planned fields from day
  one — weather / wind / current / deployment / morale / `ai_level` /
  `archetype` / `formation` — so fields the current engine does not yet
  consume stay dormant in the payload until their wave lands; unknown
  keys on import are ignored. The canonical export shape (normative):

```json
{"version": 1, "kind": "sailage_sandbox",
 "player": {"stats": {"constitution": 10, "intellect": 10, "charisma": 10, "courage": 10, "luck": 10, "weapon": "", "armor": ""}, "morale": 50,
   "ships": [{"ship_type_id": "brigantine", "cannons": 12, "crew": 30, "durability": 90, "equipment": {"figurehead": "", "sail": ""}, "captain_id": ""}]},
 "enemy": {"kind": "pirate", "ai_level": 1, "archetype": "aggressive", "formation": "swarm", "morale": 50, "compose": false,
   "ships": [{"ship_type_id": "sloop", "cannons": 8, "crew": 20, "durability": 60, "equipment": {"figurehead": "", "sail": ""}, "captain_id": ""}]},
 "conditions": {"day": 1, "seed_mode": "fixed", "seed": 1, "weather": "fair", "wind_dir": "E", "current": {"dir": "E", "strength": 0}, "deployment": "standard"}}
```

  (`seed_mode` ∈ `fixed|random|auto`; `compose: true` ignores
  `enemy.ships` and one-click generates.)
- **Zero-write UX.** a persistent notice (`sandbox.zero_write`) states
  the sandbox never writes the save. 开战 runs the battle on a **fixture
  encounter** — `player_ships` / `day` / `gold` / `seed` plus the
  forward-compat condition keys (`60-*` §4.12.4) — so S10 opens exactly
  as in a real battle. The ending shows a **READ-ONLY** after-action
  dialog and returns to S21 with the configuration kept (change one
  field and re-run). Preset persistence (`user://sandbox/`) is **out of
  scope** in Phase 9 — clipboard import/export only.

#### 4.7.17 FX / UI-motion / animated-sea timing tables (Phase 10 — final values, W1 pins)

Every animation duration is pinned here and implemented as a named code
constant; the gate is the **`UiMotion` static** (`scripts/ui_motion.gd`,
W2-C): off ⇒ the duration is 0 (instant). Default on; headless suites run
with it off. Animation is presentation-only — it never touches sim, logs
or determinism; instant-mode battle logs stay byte-identical.

**Battle FX** — presentation-only FX layer in `battle_screen.gd`
(`60-*` §4.3a sim; screen §4.7.1); the event sequencer queues
move → volley → flight → impact:

| Effect | Duration |
|---|---|
| Cannonball parabolic flight tween | 300 ms |
| Splash frame set | 400 ms |
| Impact frame set | 300 ms |
| Smoke frame set | 500 ms |
| Sink fade | 600 ms |
| Per-event pause (sequencer) | 150 ms |
| Instant mode (`UiMotion` off) | every duration = 0 |

**UI transitions** (opacity/modulate only — no layout animation):

| Transition | Duration | Site |
|---|---|---|
| Toast fade-in | 100 ms | the HUD `toast_text` funnel + the kit toast atom (§4.9) adopted by private modal toasts |
| Toast fade-out | 150 ms | the same two sites |
| Button press flash | 100 ms | `ui_kit.button()` |
| Focus / hover / dialog open | instant (no duration) | theme states (§4.9) |

The two toast constants are pinned **once**, in this table — the HUD
funnel and the kit atom both read them; no site redefines its own.

**Animated sea** (S3 world water + S10 battle water; the Chart and the
minimap stay flat raster — pinned):

| Property | Value |
|---|---|
| Water kinds animated | `sea`, `coastal_sea` (flat tiles on a dedicated water TileMap layer) |
| Scroll driver | canvas-item shader scrolling `sea_pattern.png` (64×64 **torus-safe organic wave-crest mask** — amended 2026-11-05, r5: the r1–r4 diagonal-stripe mask is **self-similar under its own scroll direction**, so translation read as a static hatch and the animation stayed invisible no matter the contrast; the mask is now irregular crest clusters in the UW2 manner) |
| Scroll period | 800 ms |
| Tones | three-level (amended 2026-11-05, r5): base SEA · dark SEA×0.70 (mask field) · **crest accents** — sparse FOAM-tinted pixels riding the cluster edges (shader `mix` toward FOAM #dff0f4 on the crest level), which is what makes the drift human-visible |
| Darkening factor | ×0.70 (render math, not asset color — amended 2026-11-04, r4: the r2–r3 value ×0.82 was **imperceptible in real gameplay**, Δ 4–20 RGB units read as flat fills; ×0.70 gives a clearly visible two-level shimmer while staying shader-only) |
| `UiMotion` off | frozen at scroll offset 0 |
| Per-frame CPU | zero (shader-only; no cell swapping) |
| S10 battle water | reuses the same shader |

#### 4.7.18 Phase-10 `ui_strings.json` inventory (finalized 2026-11-04, W6)

The `ui.kit.*` namespace is the only Phase-10 key family, written once by
W2-C (the sole `ui_strings.json` writer for the phase); sweep slots
(W4/W5) reuse existing keys only — a genuinely missing key escalates to
the master ledger, which appends it on `main`. **Final inventory: exactly
the 11 W2-staged keys** `ui.kit.gallery.{title, theme_active,
theme_missing, buttons, rows, footer, value_bars, field_rows, toast,
fire_toast, toast_shown}` — the sweep needed no key beyond the staged set
(zero escalations were required), so the staged set IS the final set.

### 4.7 Dialog & text conventions

- All dialogs are modal instances of `dialog_box.tscn` (message + OK) or
  `confirm_dialog.tscn` (message + confirm/cancel), centered, dimming the
  background by 40% black.
- One action per dialog; chained events queue (storm damage → desertion →
  greeting shows 3 dialogs in fixed order, never simultaneously).
- Numeric entry fields: digits only, live-clamped to the valid range, empty =
  invalid (dependent buttons disabled).
- Toasts: transient (2.5s), bottom-center, max 1 visible (new replaces
  old). **Fade (Phase 10):** toasts fade in 100 ms and fade out 150 ms,
  gated by the `UiMotion` static (off ⇒ instant); applied at the HUD
  `toast_text` funnel and via the kit toast atom (§4.9) adopted by the
  private modal toasts. The constants are pinned once (§4.7.17).
- Text speed: instant (no typewriter effect in Phase 1).

### 4.8 Generated art & palette *(Phase 10 — rewrites the Phase-1 "Placeholder art & palette" section, 2026-11-04; the locked palette, sizing grid, S10 minimap pins and §4.8.1 below are unchanged)*

1. **Generated-art rule.** `tools/build_ui_art.py` is the only art
   source; everything under `assets/ui/` is tool-owned output (indexed
   PNGs, nearest-neighbor import, `.import` files committed), never
   hand-edited — the same family rule as `data/maps/world.png`. Authored
   inputs live as declarative manifests under `tools/ui_art/<class>/`;
   style fixes edit the manifests / rig fragments / this style guide and
   rebuild — never a single PNG. The engine core is vendored from YoYoPixel
   (MIT, © 2026 SbName) driven by node `render.js` (node pinned
   **v24.16.0**, zero npm deps); Python is the pipeline governor
   (8-direction transforms, owner remap tables, seam rings, nine-patch
   assembly, atlases, `contact_sheet.png`, validator glue). Rebuilds are
   byte-identical (double-run fixtures).
2. **Style guide.** uniform 1px outline on tokens (tool-applied; authored
   maps are outline-less); shading = highlight + base + shadow with ONE
   specular cluster per key material, textures hinted, dithering used
   sparingly and only at tone transitions — the aesthetic target is
   **UW2 (大航海时代2) refinement**: strong silhouette, ≤ 3 tones per
   material, crisp deliberate pixels, no noisy fills; light from NW;
   **hull tokens are side/3-quarter sailing views (non top-down — item 6
   amendment)**; icons are front-facing. One dither family for terrain. **Seam rules:** all variants
   of a terrain kind share a byte-identical, wrap-continuous outer 1px
   ring (it may carry dither); interiors vary freely; dither density
   ≤ 30%; `sea_pattern.png` and the nine-patch edge tiles are torus-safe
   along their repeating axis; shore strips carry foam only on the
   land-facing band (transparent elsewhere), the foam thickness shared
   with the corner tiles. Engine seamlessness comes from TileMap chunk
   batching + nearest filtering + integer placement — no runtime
   stitching.
3. **Color budgets = size tiers (caps, not quotas).** 16×16 → 8–12;
   32×32 → 12–20; 48px+ → 15–25.
4. **Palette blocks** (full hex tables — every sprite hex must belong to
   exactly one block: a sprite checks against its own class's block only,
   group 13 enforcing per-sprite hexes ⊆ class block; where several
   blocks pin the same value — e.g. `TEXT` in the icon/hull/portrait
   tables — each block owns its own entry, and no sprite draws across
   blocks). `scripts/palette.gd` mirrors the blocks as named constants
   (W2-A appends them, append-only — no renames of existing constants).
   Class → block mapping: chrome tiles and all A.2 semantic icons (A.2
   of `IMPLEMENT-Phase10.md`) → `icon`; terrain kinds, port markers and
   shore strips → `terrain`; hull tokens and facility tokens → `hull`;
   FX frames → `fx`; portrait part sheets → `portrait`.

   **`terrain` block** (water kinds are flat single-color fills — the
   animation is the shader's, §4.7.17):

   | Hex | Name | Use |
   |---|---|---|
   | `#16446e` | `SEA` | open-sea tile fill (existing locked) |
   | `#2f6f9e` | `COAST_SEA` | coastal-sea tile fill (existing locked) |
   | `#7a5c2e` | `LAND` | land tile base (existing locked) |
   | `#8f6d3a` | `LAND_HI` | land highlight / dither light step |
   | `#5e4720` | `LAND_LO` | land shadow / dither dark step |
   | `#3d3d3d` | `REEF` | reef tile base (existing locked) |
   | `#565656` | `REEF_HI` | reef highlight / dither step |
   | `#c9d6df` | `ICE` | polar-ice tile base (existing locked) |
   | `#e4eef4` | `ICE_HI` | ice highlight / dither light step |
   | `#9fb4c4` | `ICE_LO` | ice shadow / dither dark step |
   | `#dff0f4` | `FOAM` | shore-strip foam band (land-facing band only) |
   | `#101010` | `PORT_INK` | port-marker silhouette ink/outline |
   | `#1a8c4e` | `PORT_PORTUGAL` | port-marker fill, portugal (`10-*` §7.4) |
   | `#b3191f` | `PORT_SPAIN` | port-marker fill, spain |
   | `#274b8f` | `PORT_ENGLAND` | port-marker fill, england |
   | `#d97b1e` | `PORT_HOLLAND` | port-marker fill, holland |
   | `#6a3d9a` | `PORT_OTTOMAN` | port-marker fill, ottoman |
   | `#c9a227` | `PORT_ITALY` | port-marker fill, italy |
   | `#9a9a9a` | `PORT_NEUTRAL` | neutral-port marker fill (existing locked) |

   **`icon` block** (chrome tiles + every A.2 semantic icon; greys and
   accents aligned to the chrome hexes, plus the 32px shading ramp):

   | Hex | Name | Use |
   |---|---|---|
   | `#1c2230` | `PANEL_BG` | icon recess/background fill |
   | `#121724` | `ICON_BG_LO` | recess shadow step |
   | `#465468` | `PANEL_LINE` | icon outline / mid grey |
   | `#2e2014` | `PANEL_WOOD` | UW2 chrome skin: panel/button walnut fill |
   | `#6a4e28` | `PANEL_WOOD_HI` | UW2 chrome skin: bevel light (TL) / brass trim base |
   | `#14100a` | `PANEL_WOOD_LO` | UW2 chrome skin: bevel shadow (BR) / frame dark line |
   | `#5e7086` | `ICON_LINE_HI` | lit-outline step |
   | `#232c3e` | `ICON_MID` | metal/wood mid-tone base |
   | `#e8e6df` | `TEXT` | light ink / lit surface; **wind arrows** |
   | `#f7f5ee` | `ICON_HI` | specular highlight step |
   | `#d9a441` | `ACCENT` (= `WARN`) | gold accent; **`event_demand`**; coin metal |
   | `#f0c46a` | `ACCENT_HI` | gold highlight step |
   | `#a87a28` | `ACCENT_LO` | gold shadow step |
   | `#4e9e4e` | `GOOD` | **`trend_up`**; positive marks |
   | `#74c26e` | `GOOD_HI` | good highlight step |
   | `#b3341f` | `BAD` | **`trend_down`**; danger marks |
   | `#d4573c` | `BAD_HI` | bad highlight step |
   | `#2f6f9e` | `COAST_SEA` | **current arrows**; water/glass motif |
   | `#9a9a9a` | `ICON_NEUTRAL` | neutral-flag fill |
   | `#1a8c4e` | `FLAG_PORTUGAL` | flag fill |
   | `#b3191f` | `FLAG_SPAIN` | flag fill |
   | `#274b8f` | `FLAG_ENGLAND` | flag fill |
   | `#d97b1e` | `FLAG_HOLLAND` | flag fill |
   | `#6a3d9a` | `FLAG_OTTOMAN` | flag fill |
   | `#c9a227` | `FLAG_ITALY` | flag fill |

   Goods-category color mapping (A.2 motif families; no new hexes): food
   `GOOD`, material `ACCENT_LO`, textile `COAST_SEA`, luxury `ACCENT`.

   **`hull` block** (hull tokens + facility tokens; **amended 2026-11-04,
   user direction — the shared-hull pennant scheme**): every owner draws
   the SAME authored map in the shared wood/sail/ink palette below; the
   owner is encoded by the **masthead pennant** — the authored maps carry
   one authoring-only pennant source hex (`#b3191f`; an intermediate,
   never shipped — hull-doc manifests are exempt from membership checks),
   and the tool remaps it to the owner's pennant hex per owner. Wood,
   sail and ink are owner-invariant (no owner ramp). `HULL_GOLD` trims
   the tier-3 hulls (1px sheer/sterncastle line — gilded-warship look);
   it doubles as the player's pennant value.

   | Hex | Name | Use |
   |---|---|---|
   | `#101010` | `HULL_INK` | token outline + rigging/gunports (all owners, tool-applied 1px outline) |
   | `#8f6d3a` | `WOOD_HI` | shared wood highlight |
   | `#7a5c2e` | `WOOD` | shared wood base |
   | `#5e4720` | `WOOD_LO` | shared wood shadow / plank seams |
   | `#f7f5ee` | `SAIL_HI` | sail highlight + specular arcs |
   | `#e8e6df` | `SAIL` (= `TEXT`) | sail base |
   | `#c2beb2` | `SAIL_LO` | sail shadow / seams / leeches |
   | `#a8a496` | `SAIL_SH` | deep sail shade — the billow's dark flank (UW2 craft bar, 2026-11-04) |
   | `#9a6a3a` | `DECK` | warm deck-plank tone for the oblique deck planes |
   | `#d9a441` | `HULL_GOLD` | t3 trim line; player pennant value |
   | `#d9a441` | `PENNANT_PLAYER` | masthead pennant, player |
   | `#1a8c4e` | `PENNANT_PORTUGAL` | masthead pennant, portugal |
   | `#b3191f` | `PENNANT_SPAIN` | masthead pennant, spain |
   | `#274b8f` | `PENNANT_ENGLAND` | masthead pennant, england |
   | `#d97b1e` | `PENNANT_HOLLAND` | masthead pennant, holland |
   | `#6a3d9a` | `PENNANT_OTTOMAN` | masthead pennant, ottoman |
   | `#c9a227` | `PENNANT_ITALY` | masthead pennant, italy |
   | `#9a9a9a` | `PENNANT_NEUTRAL` | masthead pennant, neutral |
   | `#b3341f` | `PENNANT_PIRATE` | masthead pennant, pirate |

   Pennant hexes equal the nation `color` values (`10-*` §7.4) plus
   player gold, neutral grey, pirate red. (The retired owner triples —
   HI/BASE/LO ramps per owner — remain as pinned constants in
   `palette.gd` history; they are no longer used by the hull pipeline.)

   Owner base hexes are exactly `nations.json` `color` values (6 nations)
   plus player `TEXT` `#e8e6df`, neutral `#9a9a9a`, pirate `#b3341f`.

   **`fx` block** (≤ 12):

   | Hex | Name | Use |
   |---|---|---|
   | `#26262c` | `FX_BALL` | cannonball body |
   | `#8a929c` | `FX_SMOKE` | smoke base |
   | `#c6ccd4` | `FX_SMOKE_L` | smoke highlight frames |
   | `#555c66` | `FX_SMOKE_D` | smoke shadow frames |
   | `#dff0f4` | `FX_FOAM` | splash foam (same value as terrain `FOAM`) |
   | `#9fc4d4` | `FX_SPLASH_D` | splash water shadow |
   | `#7a2d16` | `FX_IMPACT_D` | impact scorch ink |
   | `#ff8c2a` | `FX_FIRE` | impact fire |
   | `#ffd23e` | `FX_SPARK` | fire spark highlight |

   **`portrait` block** (72×96 part sheets; 16–24 hexes — 24 pinned):

   | Hex | Name | Use |
   |---|---|---|
   | `#101010` | `INK` | portrait outline |
   | `#f0d0b0` | `SKIN_HI` | skin highlight |
   | `#d9a878` | `SKIN` | skin base |
   | `#a87a52` | `SKIN_LO` | skin shadow |
   | `#1a1a1e` | `HAIR_BLACK` | hair: black |
   | `#6b4a2a` | `HAIR_BROWN` | hair: brown |
   | `#b9bcc0` | `HAIR_GREY` | hair: grey_streaked base |
   | `#e8e6df` | `HAIR_STREAK` / `CLOTH_PLAYER` | grey_streaked strands; player cloth base |
   | `#d9b98a` | `HAIR_BLEACHED` | hair: sun_bleached |
   | `#2e2014` | `EYE_DARK` | eyes: dark |
   | `#8a929c` | `EYE_GREY` | eyes: grey |
   | `#a87a28` | `EYE_HAZEL` | eyes: hazel |
   | `#9cc4dc` | `EYE_PALE_BLUE` | eyes: pale_blue |
   | `#d9a441` | `CLOTH_ACCENT` | cloth: trader; player trim |
   | `#465468` | `CLOTH_LINE` | cloth: coaster |
   | `#2f6f9e` | `CLOTH_SEA` | cloth: courier |
   | `#4e9e4e` | `CLOTH_GOOD` | cloth: hunter |
   | `#b3341f` | `CLOTH_BAD` | cloth: pirate |
   | `#1a8c4e` | `CLOTH_PORTUGAL` | cloth: patrol/privateer, owner portugal |
   | `#b3191f` | `CLOTH_SPAIN` | cloth: patrol/privateer, owner spain |
   | `#274b8f` | `CLOTH_ENGLAND` | cloth: patrol/privateer, owner england |
   | `#d97b1e` | `CLOTH_HOLLAND` | cloth: patrol/privateer, owner holland |
   | `#6a3d9a` | `CLOTH_OTTOMAN` | cloth: patrol/privateer, owner ottoman |
   | `#c9a227` | `CLOTH_ITALY` | cloth: patrol/privateer, owner italy |

   Cloth per role (7 roles + player): trader `CLOTH_ACCENT`, coaster
   `CLOTH_LINE`, courier `CLOTH_SEA`, patrol + privateer the owner
   nation's `CLOTH_{nation}` (they read national — distinguished by the
   role badge, not the cloth), pirate `CLOTH_BAD`, hunter `CLOTH_GOOD`,
   player `CLOTH_PLAYER` (`#e8e6df`) with `CLOTH_ACCENT` trim.

   **UW2 chrome skin (amended 2026-11-04, user direction — full
   option B):** the five nine-patch sheets render the UW2 wood/brass
   menu look — dark-walnut fills (`PANEL_WOOD`) framed by beveled wood
   (light bevel top/left `PANEL_WOOD_HI`, shadow bottom/right
   `PANEL_WOOD_LO`), brass corner rosettes and a thin gold inner line
   (`ACCENT`/`ACCENT_HI`). The flat fallback keeps the navy constants —
   it is the reduced-graphics mode; font colors are unchanged (cream on
   walnut). The ninepatch sheets are the single switch: re-authoring
   them reskins every panel/button in the game.

   **NPC world-fleet tokens (amended 2026-11-05, user direction —
   UW2 ships-in-sight):** world-map NPC fleets render the same 8-dir
   hull tokens as the player (the flagship's ship type, the fleet's
   movement heading, the owner's `PENNANT_*` remap — pirate fleets
   carry the pirate pennant). The §4.5.2 letter-marker squares are
   demoted to a small role chip overlaid on the token corner (role
   letter + role color, ~6px) so trader/patrol/pirate stays readable
   at a glance; the bare square remains the fallback when no token
   resolves. Player-vs-NPC distinction: the player keeps the fleet
   marker/square; NPCs show ship + role chip only.
      **Skin coverage (amended 2026-11-05, user direction — UW2 style   **Skin coverage (amended 2026-11-05, user direction — UW2 style
   everywhere):** texture mode routes EVERY window/panel/HUD surface
   through the skin vocabulary — custom-drawn screens (HUD status
   bars, port screens, chart, fleet picker, hail modal, intel,
   creation, settings) use the nine-patch panel/button/field/bar
   components or the walnut/bevel/brass palette drawing; bare navy
   flat fills are the reduced-graphics fallback only. Layout pins
   (32px rows, timings, content) are unchanged — this is a surface
   treatment sweep, not a layout redesign.

   **The 64-canvas model-pass upgrade (amended 2026-11-04, user
   direction — hull tokens, icons and terrain tiles all move to
   64×64, with the model pass as the primary art pipeline and the
   string-map generators as the deterministic fallback):**
   - **Canvas.** hull tokens 64×64; semantic icons 64×64 (hero
     display); terrain tiles 64×64. The authored string-map manifests
     REMAIN the 32-grid source of truth; the build derives the
     fallback 64 art by exact ×2 nearest upscale (never hand-drawn at
     64).
   - **Render rules.** the world map renders terrain at
     `tile_size_px = 64` (view radius halves accordingly; the battle
     grid stays 48×30 @ 32 px); the world fleet token renders 1:1
     (64 px); battle-grid fleet tokens render at 0.5 scale (32 px on
     the 32 px battle tile); icons inline keep the 32 art, hero
     contexts show the 64 canvas.
   - **World zoom-out (amended 2026-11-04, user direction; view counts
     re-pinned by the 2026-11-08 resolution bump to 1920×1080).** the
     world camera has exactly two zoom levels: **1.0** (near — 64 px
     tiles, 30×17 view) and **0.5** (wide — 32 px effective, 60×33;
     exact integer halving keeps every pixel crisp, no fractional
     zoom). One key toggles (a free key per the §4.2 keybind table);
     chunk spawning follows the effective view radius so the wide
     view never shows void. Battle/ports/UI zoom unaffected.
   - **Ingestion contract (TheNoise, `POST /edit` on 127.0.0.1:8001,
     qwen_image21).** draft export (the 64 fallback upscaled to the
     API reference size) → `/edit` with the direction-specific
     restyle instruction → snap-downsample to the 64 logical grid
     (majority vote per logical pixel) → palette quantization to the
     family block → pennant-source presence + footprint-band checks →
     owner remap. Raw model output is **never committed**; the
     ingested tokens are tool-owned artifacts audited by group 13
     exactly like the generated ones. Regeneration is cheap
     (~40 s/asset): every family can be re-run through the model
     wholesale. **Five-direction generation, mirror-derived rest
     (amended 2026-11-05, user direction — consistency over
     shading):** the model pass generates only the **5 base
     directions n, s, w, sw, nw**; `e` is the exact horizontal
     mirror of `w`, `ne` of `nw`, `se` of `sw` (derived at
     ingestion, before the pennant remap; long axis and band
     membership are mirror-invariant). n/s stay separate bases
     (stern vs bow are genuinely different views). Mirrored pairs
     are drift-free by construction; the flipped light direction on
     mirrored pairs is an accepted trade (UW2 does the same). The
     deterministic fallback keeps its 8 authored maps unchanged.

     **Pixel-art read for the 64 grid (amended 2026-11-06, user
     direction — prompt + geometry, no re-rolls; SUPERSEDED for hull
     tokens same day by the PixelLab backend amendment below — the
     clause/block-pass mechanism below remains the pinned method for
     any local-TheNoise asset family):** fine-textured
     ~1024² model renders lose rigging, windows and gunports in the
     64-grid majority vote, so the model passes push pixel-art
     style explicitly, in two pinned parts. (a) **Side-view
     prompt clause** — the stage-1 TheNoise `/edit` prompt (the
     reconstructed canonical w-pose prompt) carries this appended
     clause, verbatim: `Crisp pixel art sprite: big chunky square
     pixels, flat color fills, strong dark outline around the
     sprite, limited palette, bold silhouette readable at 64×64
     size, no thin rigging lines, no fine surface texture, no
     anti-aliasing, no dithering.` The side view is the ComfyUI
     identity reference, so all five generated branches inherit
     the style through their existing "matching the input image's
     style" clause (the workflow JSON itself is unchanged). (b)
     **Pre-snap block pass** — in the snap chain, after key-green
     and BEFORE the resize/pan band normalization, the keyed RGBA
     render is nearest-downsampled to **256 px** native width
     (aspect kept) and nearest-upscaled back: a **4-native-px
     minimum feature size**, so features thinner than that cannot
     win their grid vote. One global value (like the band
     normalization factor, not per-ship); the 256 px pin is
     calibration-tunable by amendment. Both parts are geometric/
     prompt-side only — the seeds, the band gate and the
     normalization math are untouched.

     **PixelLab hull backend (amended 2026-11-06, user direction —
     hull tokens move to the PixelLab API; SUPERSEDES for hulls the
     local TheNoise+ComfyUI passes, the band/resize normalization,
     the tier footprint bands and the 5+mirror direction rule):**
     `tools/pixellab_pass.py` generates hull tokens via
     `POST /v2/create-object-pro-flash` (build-time SaaS; per-call
     ~$0.053 at the pinned size). **Envelope, pinned verbatim —
     exactly five fields, never a style_image (explicit user
     direction ×2):** `{"description", "image_size": {64, 64},
     "n_directions": 8, "view": "high top-down", "seed": 91000}`.
     The description = per-ship identity prefix + the pinned shared
     suffix. **Identity prefix:** `{Name-en} sailing ship, {rig}`
     with `{rig}` read from `tools/ui_art/hulls/rig.json` (e.g.
     brigantine = "Brigantine sailing ship, 2 masts, 2 square
     sails"); rowed ships carry their oar clause from the same rig
     string. **Shared style suffix, pinned verbatim (the 16-ship
     consistency anchor; includes the UW2 style reference — user
     picked wording):** `wooden sailing ship with dense multi-strake
     planking bands in several wood tones, dark gunwale, gold trim
     line along the sheer, gunport row with tiny dark ports, stern
     cabin with small lit windows, sails billowed with three folded
     shading bands and one bright highlight arc each, thin dark
     rigging ropes to bowsprit and hull, small red pennant at the
     mainmast top, deck planking and deck structures visible from
     above, retro 16-bit sailing ship sprite in the style of classic
     1990s naval adventure games like Uncharted Waters 2 / New
     Horizons, dark 1-pixel silhouette outline, transparent
     background.` (preceded by the identity prefix, comma-joined).
     **Ship-as-drawn rule:** tokens ship RAW 1:1 — no resize, no
     band normalization, no palette quantize; the model's native
     64×64 deliberate pixels are the shipped pixels. Consequences,
     all amended here: (a) **§4.8.7 tier footprint bands are
     retired for the model-token family** (they remain the
     deterministic fallback's authored standard; tier size identity
     becomes a review-sheet property, not a gate); (b) the
     validator's band + palette-block checks are retired for hull
     tokens — the audit becomes provenance ledger (object id +
     seed + description hash) + canvas fit + masthead pennant; (c)
     the "5 base + 3 mirrors" rule is retired for hulls — all 8
     rotations are native (pixellab names map 1:1 to the heading8
     dir ids: north→n, north-east→ne, …, west→w; verified on
     brigantine trial 5, art_review/63). **Pennant scheme: ship-as-
     drawn (final, user direction — supersedes the same-day option-B
     recolor experiment, which was REJECTED: flattening the flag's
     shading onto one hex looked terrible):** the model's own flag
     ships untouched and the SAME token bytes ship for every owner —
     the ×7 pennant remap is suspended for this family (owner color
     identity via pennant is retired until a future amendment
     reinstates it; owner id on the map falls to the fleet-letter
     badge + minimap pins). **File grid (raw dedupe, same amendment):**
     identical bytes × 9 owners was pure duplication — the family
     ships ONE owner-less file per ship × dir
     (`assets/ui/tokens/hull_{ship}_{dir}.png`, 16 × 8 = 128 files);
     the runtime resolves an owner id
     `hull_{ship}_{owner}_{dir}` whose per-owner file is absent onto
     the shared file through the registry
     (`scripts/ui/texture_registry.gd`), so all owner ids reference
     one ImageTexture (one VRAM copy per ship × dir). A per-owner
     file, when a future amendment returns owner pennants, simply
     shadows the shared one (direct path wins). Masthead/auto-paint
     logic does not run
     in this mode; gates = canvas fit. The option-B recolor (top-45%
     dominant red cluster → `PENNANT_SOURCE #b3191f`, Δ≤90) remains
     in git history as the reference implementation.
     Raw rotations live gitignored under
     `tools/ui_art/model_raw/pixellab/<label>/` with a manifest
     recording `object_id`/job id/seed/description (re-download
     without re-generation); **raw model output is never committed**
     (§9.2). API key: gitignored `tools/pixellab_config.json`,
     env `PIXELLAB_API_KEY` overrides. Fleet
     acceptance flow: per-
     ship user review of the snapped sheets → reject = one seed-
     bumped re-roll (user-capped) → ingest via
     `build_ui_art --import-ships-pixellab` (8 native dirs; mirror
     derivation skipped for pixellab tokens).
     **[2026-11-07 amendment note: the view, envelope, direction
     scheme and file grid of this block are SUPERSEDED by the
     top-down hull token amendment below; the pennant scheme, the
     ship-as-drawn raw rule, the raw-output/API-key handling and
     the owner-fallback mechanism carry over as re-pinned there.]**

     **Top-down hull tokens (amended 2026-11-07, user direction —
     the 45°-oblique "high top-down" hulls proved too hard for the
     model to hold consistent across 8 directions, so the family
     moves to ONE straight-overhead token per ship, rotated at
     runtime; SUPERSEDES for hulls the 2026-11-06 hull-backend
     amendment's view/envelope/direction/file-grid parts):**
     `tools/pixellab_pass.py --topdown` generates hull tokens via
     `POST /v2/generate-image-v2` (Pro; async background job,
     polled to completion; per-call ~$0.008 at the pinned sizes).
     **Envelope, pinned verbatim — exactly four fields, never a
     style_image or reference_images:** `{"description",
     "image_size": {S, S}, "no_background": true, "seed": 91000}`
     with S from the ship's tier (below). The endpoint has no
     view/direction parameters — camera and facing live in the
     prompt text. **Canvas = tier table (pinned):** tier 1 (latin,
     sloop, galiot, pinnace) → 32×32; tier 2 (caravel, galley,
     brigantine, fluyt, junk, dhow, caravela_redonda, xebec) →
     48×48; tier 3 (nao, carrack, galleon, galleass) → 64×64
     (4/8/4 ships; size derived from `tier` in
     `data/ship_types.json` — no new data field). **Identity
     prefix:** `{Name-en} sailing ship, {rig}` from
     `tools/ui_art/hulls/rig.json`, plus per-ship clause
     insertions and one full variant (the visibility rewrite
     below). **Shared style suffix, pinned verbatim (the 16-ship
     consistency anchor; the 2026-11-07 same-day visibility
     rewrite of the first overhead suffix, user direction — the
     first wording asked for side-view features a straight
     bird's-eye view cannot show, so the rewrite keeps only
     overhead-visible content: multi-strake side planking → deck
     planking, gunwale/sheer trim → hull rim, the gunport row and
     the lit cabin windows dropped, the sail billow shading bands
     + highlight arcs dropped in favor of the flat-panels-over-
     deck top-down game convention, gold trim dropped outright —
     it was t3-only in the authored maps yet the first suffix
     asked all 16 ships for it):**
     `wooden sailing ship seen from directly overhead, straight
     top-down bird's-eye view, hull axis vertical with the bow
     pointing to the top edge of the canvas, wooden deck planking
     bands in several warm brown tones between the masts, dark rim
     along the hull outline, sails drawn as flat pale panels laid
     over the deck following the rig — wide rectangles for square
     sails, triangles for lateen sails — the top-down game-sprite
     convention, masts as small round dots with thin yard lines,
     thin dark rigging ropes to the bowsprit and hull sides,
     raised stern cabin roof and deck hatches visible from above,
     small red pennant streaming from the mainmast top, retro
     16-bit sailing ship sprite in the style of classic 1990s
     naval adventure games like Uncharted Waters 2 / New
     Horizons, dark 1-pixel silhouette outline, transparent
     background.` (preceded by the identity prefix, comma-
     joined). **Per-ship clause insertions, pinned verbatim
     (placed between the rig string and the suffix):** galiot,
     galley and galleass append `, long oars fanned out along
     both hull sides` (oars are overhead-visible identity);
     junk appends `, each sail panel crossed by thin horizontal
     batten lines`. **Pinnace full variant, pinned verbatim (no
     mast and no sails — the suffix's sail/mast/rigging/pennant
     clauses are replaced wholesale; the token carries no
     pennant-source pixel — fine, the north ingest ships raw with
     the pennant gate retired):** `Pinnace ship, tiny open rowing
     craft, oars only, no mast, no sails, wooden boat seen from
     directly overhead, straight top-down bird's-eye view, hull
     axis vertical with the bow pointing to the top edge of the
     canvas, wooden hull interior with rowing benches in warm
     brown tones, dark rim along the hull outline, long oars
     fanned out along both hull sides, retro 16-bit game sprite
     in the style of classic 1990s naval adventure games like
     Uncharted Waters 2 / New Horizons, dark 1-pixel silhouette
     outline, transparent background.` **Ship-as-drawn rule:** tokens ship RAW 1:1 —
     no resize, no quantize; the model's native S×S deliberate
     pixels are the shipped pixels; gates = canvas fit (exact
     S×S) + provenance ledger (job id + seed + description hash);
     the hull may sit anywhere sensible on its canvas — exact
     hull-centering is a review-sheet property, NOT a validator
     gate (the runtime keys on canvas center, see below).
     **Pennant scheme:** unchanged from 2026-11-06 (ship-as-drawn;
     the same bytes ship for every owner; per-owner shadowing
     reserved for a future amendment). **File grid:** the family
     ships ONE owner-less north file per ship
     (`assets/ui/tokens/hull_{ship}.png`, 16 files; the six
     `facility_*` tokens are untouched). The runtime resolves an
     owner id `hull_{ship}_{owner}` whose per-owner file is absent
     onto the shared file through the registry — the dir segment
     disappears from every hull id. **Runtime rotation map
     (pinned, clockwise degrees in screen y-down):** n 0, ne 45,
     e 90, se 135, s 180, sw 225, w 270, nw 315 — the heading8
     dir id (§4.8.6, unchanged as the heading authority) selects
     the rotation; Godot rotates the token with the **NEAREST**
     filter (crisp pixels, no smoothing) — no baked direction
     variants. **World-map draw rule:** the token draws at its
     native canvas size, centered in the 64 px cell — offsets from
     the cell origin are 32→(16,16), 48→(8,8), 64→(0,0), all even,
     so the token center equals the cell center at every size and
     rotation never drifts off-center; tier size contrast is real
     on the map (t1 ships are genuinely half a t3's canvas).
     **Whole-sandwich rotation:** the FxBack → hull → FxFront
     waterline sandwich rotates as one unit around the token
     center; hull letters, fleet badges and NPC role chips are
     NOT rotated (they live in the unrotated marker/badge layer).
     **Battle screen:** token draws at 0.5 × native canvas (t3→32
     px on the 32 px tile — unchanged from today; t2→24, t1→16)
     with the same rotation map; roster keeps its 32 px
     keep-aspect box on the north token. Raw north tokens live
     gitignored under
     `tools/ui_art/model_raw/pixellab_topdown/<label>/`
     with a manifest recording job id/seed/description
     (re-download without re-generation); **raw model output is
     never committed** (§9.2); API key handling unchanged
     (gitignored `tools/pixellab_config.json`, env
     `PIXELLAB_API_KEY` overrides). Fleet acceptance flow:
     per-ship user review of the north token (+ a rotation
     preview) → reject = one seed-bumped re-roll (user-capped) →
     ingest via `build_ui_art --import-ships-pixellab`, which also
     removes any stale dir-suffixed files. **Retired by this
     amendment:** the `"high top-down"` Pro-Flash hull envelope
     and its `n_directions: 8` generation, the
     `hull_{ship}_{dir}` / `hull_{ship}_{owner}_{dir}` ids, the
     128-file 8-dir grid and the per-dir waterline sheets (see the
     same-day VFX revision below). The 2026-11-06 identity
     prefix, pennant scheme, raw rules and coast-tileset work are
     NOT retired. **Acceptance record (2026-11-07):** the 16 north
     tokens generated at the pinned seed 91000 (4×32², 8×48²,
     4×64² — every canvas exact); user review verdict "go straight
     to ingest" (all 16 accepted on the first roll; the pre-screen's
     two lean candidates latin/caravel shipped as drawn — hull-lean
     is a review-sheet property by the amendment, not a gate); the
     v4 wake families generated pro around
     hull_galleass/hull_caravel/hull_latin (quotes 10 generations
     each; effect ids d860e12e…/64882f43…/4e99cce9…; canvases
     54×92, 38×68, 64×72; anchors template-matched into the size
     boxes); ingest gates: `--check` byte-identical (270 files),
     validator groups 1–13 green, 61/61 suites green.
     **Acceptance record (2026-11-07, visibility rewrite):** the
     16 north tokens re-rolled against the rewritten suffix at the
     pinned seed 91000 (4×32², 8×48², 4×64² — every canvas
     exact); user review verdict "accept all" on the first roll —
     including the three flagged candidates kept as drawn (nao's
     model-added sail cross, galleass's full oar fan, carrack's
     teal midship panels — user direction); the pinnace variant
     token (rowing craft, no mast/sails/pennant) ingested raw
     under the retired pennant gate (0 auto-paints). The v5 wake
     families re-rolled pro around the NEW
     hull_latin/hull_caravel/hull_galleass (quotes 10 generations
     each; effect ids 396e7caa…/358943dd…/7279416f…; canvases
     96×88, 88×88, 128×144; anchors template-match 1.0).
     Ingest gates: `--check` byte-identical (257 files),
     validator groups 1–13 green, 61/61 suites green.

     **PixelLab semantic-icon pass (amended 2026-11-08, user direction —
     the 129 A.2 semantic icons move to the PixelLab backend,
     prompt-only, on the 64 canvas; the authored string-map manifests
     remain the committed fallback and the 32 inline source for any id
     that has not ingested yet):**
     `tools/pixellab_pass.py --icons` generates icons via
     `POST /v2/generate-image-v2` (Pro; async background job, polled to
     completion — the top-down hull envelope; per-call ~$0.008 at 64²).
     **Envelope, pinned verbatim — exactly four fields, never a
     style_image or reference_images:** `{"description",
     "image_size": {64, 64}, "no_background": true, "seed": 92000}` —
     every icon generates on the **64×64 canvas** regardless of its
     authored 32 grid (the 64 serves both the exact 2:1 halve to the
     inline 32 and the hero display). **Icon prompt rewrite (user
     direction — NO hull heritage):** the description = per-icon
     object descriptor + the pinned shared suffix, comma-joined;
     descriptors are REWRITTEN as object specs (material + color +
     pose), never adapted from the ship vocabulary. **Shared icon
     suffix, pinned verbatim (the 129-icon consistency anchor;
     strictly flat front-facing view for EVERY id — user direction;
     the UW2 style anchor kept — user direction):**
     `single centered game UI icon, flat front-facing view, the object
     fills about 70% of the canvas and stays fully inside the frame,
     bold readable silhouette, flat cel shading with two or three
     shading bands, dark 1-pixel silhouette outline on the outer edge
     only, no scenery, no background elements, no cropping, no text,
     no gradients, limited retro palette in warm midtones, retro
     16-bit pixel-art game icon in the style of classic 1990s naval
     adventure games like Uncharted Waters 2 / New Horizons,
     transparent background.` **Descriptor rules:** per-icon
     descriptors are pinned verbatim in `tools/pixellab_pass.py`
     `_ICON_DESCRIPTORS` (goods/equipment carry their en name from the
     data JSONs as the identity prefix; pure glyph ids carry a
     rewritten object spec; a full-variant dict replaces the whole
     description where the suffix would fight the object). **Arrow
     families keep the derivation-only policy:** only the `n`/`ne`
     bases generate (a bold top-pointing-arrow object spec); the six
     derived dirs per family are never sent to the API and the build
     re-derives them as today. **Raw files:** gitignored under
     `tools/ui_art/model_raw/pixellab_icons/<id>/icon.png` + a manifest
     (job id/seed/description/sha) — **raw model output is never
     committed** (§9.2); API key handling unchanged (gitignored
     `tools/pixellab_config.json`, env `PIXELLAB_API_KEY` overrides).
     **Snap:** raw passthrough into `<id>/snapped/icon.png` with a
     canvas-fit gate (exact 64×64) — the ship-as-drawn rule; the
     icon-block quantization, binary alpha and the 2:1 halve happen at
     INGEST (the §9b build contract), never in the pass. **Acceptance
     flow (pilot first — user direction):** a pilot batch — the 5 HUD
     resources (`coin`, `crew`, `provisions`, `morale`, `durability`)
     plus 4 goods, one per category motif family (`good_wheat` food,
     `good_iron` material, `good_cotton_cloth` textile, `good_spices`
     luxury) — is reviewed on a contact sheet (64 raw + the halved 32
     side by side); user approval freezes the suffix, then the
     remaining ~120 fire at the pinned seed. **Ingestion contract
     (extends §9b):** `build_ui_art --import-icons` accepts the
     `model_raw/pixellab_icons/<id>/snapped` cache alongside the
     studio caches (precedence rules unchanged); per ingested id it
     emits BOTH the halved 32 inline asset (existing contract:
     icon-block quantize, 20-color cap, binary alpha, exact 2:1
     origin-anchored halve) AND the hero 64 asset
     `assets/ui/icons64/<id>.png` (1:1, same quantize + alpha, no
     halve) — **the hero-64 deferral of the 64-canvas upgrade is
     retired** (user direction 2026-11-08). **Hero-64 display
     contract:** `assets/ui/icons64/` load lazily through the
     token-loader id `icon64_<id>` (raw file bytes, no `.import`
     sidecar — the token family rule; a miss stays the null fallback);
     the inline 32 assets and every 32px row/layout pin are untouched.
     **Hero hosts (pinned, the Phase-1 wiring — swap-only, no
     row/layout changes):** (a) S5 market — the selected-row info
     strip below the goods table gains a 64px hero slot for the
     selected `good_*` (the trend mark stays 32 inline); (b) S6
     shipyard — the refit picker's bottom detail area gains a 64px
     hero slot for the selected `eq_*`. Other surfaces keep the 32
     inline art until a future amendment pins more hosts. The
     arrow-family ingest policy and the `ICON_ARROW_*` guards are
     unchanged (§9b). **Acceptance record (2026-11-08):** the pilot 9
     (5 HUD + 4 goods, one per category motif family) generated first
     roll at the pinned seed and were accepted on the contact sheet —
     the suffix frozen as pinned; the fleet of 108 fired across 3
     parallel workers (disjoint slices, disjoint manifests) hit
     `HTTP 402` (account credits) at 109/117; after the top-up the run
     resumed (resumable loop, +8 incl. `wind_arrow_n`) → **117/117
     raws**. Verdicts: everything accepted as drawn except
     `wind_arrow_ne` — gold (seed 92000), tan (seed 92001), both
     REJECTED on review and preserved under
     `tools/ui_art/model_raw/pixellab_icons_rejects/` (outside the
     ingest scan); the descriptor hardened to "colored ONLY in pale
     grey and off-white like a paper ink mark — no gold, no brown, no
     tan, no warm tones" and the seed-92002 roll accepted
     (family-consistent with the n base).
     `marker_discovery_natural` is an icon-pass sibling note: its
     model-added small red X was user-accepted as drawn. Ingest: the
     union runs (`--import-icons` with BOTH caches — studio
     `model_raw/snapped` + `model_raw/pixellab_icons`, later dirs win
     per id) — final counts 117 accepted + 12 derivation-only skipped,
     `hero_64` 117. The **§8.8 item 5 refresh path was IMPLEMENTED this
     round** (the build re-derives each ingested arrow family's six
     siblings from the shipped ingested base — the validator caught its
     absence); the wind family closed: all four bases pass the pointing
     gates. Gates: `--check` 405 files byte-identical, validator groups
     1–13 PASS, 61/61 suites green (one interim fleet run tripped
     `test_captain_lifecycle`'s 80 ms day-tick gate at the filled cap —
     96.9 ms under parallel-suite contention on a warm box; green in
     isolation at 72 ms and on the clean full-fleet re-run; the tick
     code path was untouched by the pass).

     **PixelLab glyph pass — markers & facility tokens (amended
     2026-11-08, user direction — the marker and facility families join
     the PixelLab backend under the icon ruling):** the 6 marker
     (`marker_treasure`, `marker_wreck`,
     `marker_discovery_{creature,natural,relic,ruins}`) and 6 facility
     (`facility_{market,shipyard,palace,tavern,inn,guild}`) string-map
     glyphs generate via `tools/pixellab_pass.py --glyphs`, the same
     **prompt-only `POST /v2/generate-image-v2` envelope as the icons
     (exactly four fields, never a style_image or reference_images):**
     `{"description", "image_size": {64, 64}, "no_background": true,
     "seed": 92000}`. **Icon ruling, not the hull ruling:** generate at
     64, quantize to the owning class block, binary alpha, exact 2:1
     nearest halve → the 32 inline asset, 20-color cap at 32
     (§4.8.3); **hero variants: markers none** (no 64px display
     surface — pinned); **facility tokens YES** (user direction,
     same day): the ingest ALSO emits the hero 64 asset
     `assets/ui/tokens64/<id>.png` (the quantized 64 grid 1:1 —
     the icons64 pattern), and the port hub facility cards render
     it at 1:1 64 (the §4.8.1 card keeps its 320×64 envelope; the
     token becomes the card's full-height left emblem, name +
     status stacked beside it; a missing hero id falls back to the
     halved 32 token at 32). **Owning blocks (pinned):**
     `marker_*` → the terrain block (the §4.8 class mapping's "port
     markers" row — the marker glyphs are map-overlay art, not
     terrain tiles themselves; the block mapping is amended here to
     say so explicitly); `facility_*` → the hull block (the tokens
     family). The shipped 32 assets stay in place
     (`assets/ui/markers/<id>.png`, `assets/ui/tokens/<id>.png`);
     the generator string maps remain the per-file fallback.
     **Rewritten prompt families (user direction — NO icon heritage;
     each family gets its own pinned suffix):**
     **`MARKER_SUFFIX`, pinned verbatim (the map-overlay design
     problem is separation over live sea AND land tiles, not palette
     discipline):** `single centered world-map marker glyph, bold
     compact silhouette readable at tiny size, thick dark 1-pixel
     outline, flat cel shading with two or three shading bands,
     strong contrast against both blue sea and brown land, single
     object fully inside the frame, no scenery, no text, no
     gradients, retro 16-bit pixel-art game map marker in the style
     of classic 1990s naval adventure games like Uncharted Waters 2 /
     New Horizons, transparent background.` **`FACILITY_SUFFIX`,
     pinned verbatim (building fronts are a different object class
     from every prior family; signs stay UNLETTERED):** `small
     16th-century European port building front seen straight-on,
     flat frontal facade, centered doorway, one or two windows,
     thick dark 1-pixel outline, warm wood and stone midtones, bold
     readable silhouette, flat cel shading with two or three
     shading bands, the building fully inside the frame, no scenery
     around it, no text, no lettered signs, no gradients, retro
     16-bit pixel-art in the style of classic 1990s naval adventure
     games like Uncharted Waters 2 / New Horizons, transparent
     background.` **Per-id descriptors** are pinned verbatim in
     `tools/pixellab_pass.py` (`_GLYPH_DESCRIPTORS`); composition =
     `{identity}, {spec}{<family suffix>}`. **Cache & ledger:** raws
     gitignored under `tools/ui_art/model_raw/pixellab_glyphs/<id>/`
     (snap passthrough `<id>/snapped/icon.png`, canvas-fit gate
     exact 64×64, ship-as-generated at the 64 grid — quantize and
     halve happen at ingest); manifest + provenance identical to the
     icon pass; **ingestion** via the new
     `build_ui_art --import-glyphs`: per id, class resolved by
     prefix, re-quantize to the owning block, halve 64→32, cap
     gate, write the shipped 32; ledger sections `markers{}` /
     `facility{}` (job/seed/source/sha/accepted_at, mirroring
     `icons{}`); the override ladder + `--check` byte-identical
     contract extend to both families
     (`resolve_artifact_overrides` gains `markers`/`facility`).
     **Validator (group 13):** per family — presence, 32×32 canvas,
     owning-block membership, ≤ 20 colors, and the exactness assert
     (shipped 32 == the 2:1 halve of the re-quantized snapped
     source, re-derived where the local cache exists); ids outside
     the two pinned inventories rejected. **Acceptance flow:** ONE
     bundled resumption run with the 6 outstanding icons (`fair`,
     `flag_england`, `good_raw_silk`, `good_rhubarb`, `good_rice`,
     `wind_arrow_ne`; 18 jobs total, ~$0.14 at ~$0.008/job) once
     the PixelLab account is topped up → snap → review sheets
     (icons addendum 6, markers 6, facility 6) → user verdict →
     union ingest (`--import-icons` both caches +
     `--import-glyphs`) → gates (`--check` byte-identical,
     validator groups 1–13, suites). **Wind-family closure rides
     this run:** `wind_arrow_ne` landing and passing the
     NE-pointing gate admits both wind bases; the §8.8 item 5
     refresh path re-derives the six wind siblings from the
     ingested sources automatically. **Acceptance record
     (2026-11-08):** 12/12 first roll at the pinned seed, prompt-only,
     no reference images; the user verdict accepted all as drawn
     (`marker_discovery_natural` keeps the model's small red X).
     Ingest: markers 6 (terrain block), facility 6 (hull block) —
     every facility id also carries its hero 64 in
     `assets/ui/tokens64/` (the same-day user direction "facility
     icon should be 64x64 as well" retired this family's no-hero
     pin; markers stay hero-less). The port hub facility cards
     render the hero at 1:1 64 — the full-height left emblem with
     name + status stacked beside it, and a missing hero id falls
     back to the halved 32 token at 32
     (`facility64_<id>` through the kit registry's lazy raw-bytes
     branch). The pipeline was dry-run verified end-to-end with a
     synthetic snapped cache (12/12 ingested, 12/12 exactness
     chains green) BEFORE the real generation, then reverted to the
     staged state — the committed ledger carries only the real
     model provenance. Gates: `--check` 405 files byte-identical,
     validator groups 1–13 PASS (marker/facility sections +
     facility-hero exactness), 61/61 suites green. **Wind arrows move
     to runtime rotation (amended 2026-11-08, user direction — "take
     the north one, and create others by rotate it"):** the wind
     family ships ONE generated north texture (`wind_arrow_n`); the
     seven other dirs render by rotating it at draw time through the
     pinned heading8 map (`ArrowFieldLib.DIR_ROTATION_DEGREES`, the
     hull-token precedent — n 0, ne 45, … nw 315 clockwise in screen
     y-down, NEAREST filter, crisp pixels). A build-time rotation
     cannot serve the diagonals losslessly (45° pixel rotation
     aliases — the reason the family ever generated a diagonal base),
     so `wind_arrow_ne` and the six derive decls RETIRE from
     `arrows_wind.json` (their 32/64 files deleted; the ledger entry
     revoked; undeclared candidate ids skip with a ledger note — the
     manifests stay the id authority). The §8.8 item 5 transform pin
     retires for the wind rows (no sibling files exist to check);
     the current-arrow family keeps its two-base scheme unchanged.
     Consumers: the S3 arrow field (world map) rotates through
     `draw_set_transform`; the HUD wind sprite rotates the same map
     around its anchor. The windArrow_n pointing gate and the
     ingested provenance carry over unchanged.

     **Terrain blob program (amended 2026-11-05, user direction — the
     48-tile auto-tile standard):** terrain transitions adopt the
     Standard 48-Tile Auto-Tile Set per terrain PAIR (center 1,
     single edges 4, outer corners 4, inner corners 4, mixed
     edges/corners/strips/endpoints 37, base 1). Pairs over the five
     real kinds (`data/map_legend.json`: sea, coastal_sea, land,
     reef, polar_ice), in layering priority order (higher kind draws
     its transition tiles over the lower): polar_ice-over-land,
     polar_ice-over-coastal_sea, reef-over-sea, reef-over-coastal_sea,
     land-over-sea — land↔coastal_sea keeps the §6.6 shore foam
     system. (Correction 2026-11-05: the first draft of this
     amendment named hills/mountains — no such kinds exist in the
     legend; the generated hills/mountains art demonstrated the
     method and remains available if new kinds are ever added, which
     would require a map_legend + build_world + palette-policy
     amendment first.) Art: the context-sheet method at **3×3
     neighborhoods** (each patch shows the center tile with its
     exact 8-neighbour context; crop the centre 64px) — 25 patches
     per 1024 sheet, 2 sheets per pair, ~20 `/edit` calls total;
     crops write back into `tools/ui_art/terrain/` manifests as
     committed tool-owned artifacts; uniform fill/base tiles get a
     torus blend at the snap grid. Runtime: `map_loader` gains a
     256→48 blob-mask LUT (per cell, 8-neighbour same-kind bits,
     priority-ordered pairs) driving per-pair overlay atlases; the
     LUT is pinned in the terrain suite. The current 8-context
     probe sheets stand as method validation, superseded by this
     set. **Soft edges (amended 2026-11-05, user direction):** every
     transition tile's border band is a **2-stage checkerboard
     dither gradient** of the two terrains' palette colors (dense
     interleave at the boundary ~50%, thinning to ~10–15% at the
     band's far edge) — never a smooth gradient and never a hard
     1px line. The generation instruction carries it ("the boundary
     dissolves through a 2–4 px checkerboard dither of both terrain
     palettes, chunky pixels, NO smooth gradients"); snap+quantize
     converges residual blur into dither. Validator consequence:
     transition tiles' palette membership is the UNION of both
     terrains' blocks (dither interleave legal), anything outside
     still rejected — pinned with the LUT in the terrain suite.
     Geometry stays the blob set's job; softness lives only in the
     edge bands (same-kind interiors stay pure). Optional later
     extension: one extra wide-band tile per edge (2-tile gradient).

     **Coast foam language (amended 2026-11-05, r5 — the white
     outline line failed user acceptance three times):** shore foam
     is NO longer a uniform thin white line along the coast. The
     baked water variants carry, per land-facing edge: a **shore
     wash band** (6–10px of the water tone mixed toward
     COAST_SEA/FOAM, fading into open water — the UW2 light-shallow
     read) plus **irregular white foam speckle clusters** (2–5px
     dashes/speckles, scattered along the land edge with varying
     density, hugging the boundary on the water side). Same-kind
     interiors and open edges stay clean; the speckles follow the
     coastline path continuously (no gaps, no floating segments) —
     verified on synthetic staircase/channel/pocket fixtures and the
     real coast.
     **PixelLab coast program (amended 2026-11-06, user direction — the
     vendored wang tileset supersedes the land↔sea coast on the world
     map):** the sea/coastal_sea/land world-map rendering adopts the
     PixelLab-generated 16-tile Wang corner set (`terrain_coast_wang_0..15`,
     built by `tools/build_terrain_pixellab.py` from the vendored raw
     `tools/assets/pixellab_raw/tileset_coastline_*.json` — pro mode, 64px,
     seed 20261106, Uncharted Waters 2 style, NO palette quantization: the
     model's deliberate pixels ship as drawn, the 2026-11-06 raw hull
     ruling). Placement (replaces the land-over-sea blob pair + the §6.6
     foam variants for land↔sea edges): every cell reads its four corner
     VERTICES — vertex (vx, vy) is `upper` (land) iff the world tile at
     (vx, vy) is `#` (cells span pixels (x..x+1, y..y+1)); a cell with any
     land corner stamps the wang tile of its corner combo (combo bits
     NW/NE/SW/SE = 1/2/4/8, wang index = NW·8 + NE·4 + SW·2 + SE·1). Layer
     ownership follows the cell's OWN pixel (it is the cell's NW corner
     vertex): LAND cells own the coast placement, placed by the
     **water-flanking rule** (2026-11-06 evening revision — "N/W coasts
     have no beach"): a corner of the land cell is water-flanked when any
     of its three adjacent map neighbours is water (NW ← N/W/NW, NE ←
     N/E/NE, SW ← S/W/SW, SE ← S/E/SE), and the cell stamps the coast tile
     whose UPPER corners are the non-flanked ones — index = NW·8 + NE·4 +
     SW·2 + SE·1 (terrain atlas land row, columns 8..14). This makes the
     single-side coasts read their edge tiles (N → wang_3, S → wang_12,
     W → wang_5, E → wang_10 — the first revision left wang_3/wang_5 dead
     and stamped diagonal wedges on pure S/E edges), corners read their
     carats (NW wang_1, NE wang_2, SW wang_4, SE wang_8), lone diagonals
     read the concave wedges (wang_13 etc.). The atlas land row therefore
     bakes ALL fourteen coast indices wang_1..wang_14 at columns 8..21
     (the first bake carried only the vertex-sampler's {8..14} and left
     N/W coasts + carats falling back to plain variants — hard edges).
     The §6.2 coast cleanup
     guarantees no built cell carries water on opposite sides or 3+ sides,
     so index 0 (all corners flanked) never occurs in the built world;
     it falls back to the legacy variant path (synthetic-grid insurance).
     15 (no flanked corner) is the interior. WATER cells NEVER stamp
     corner tiles (2026-11-06 user direction, the "ship on land" report):
     a water pocket/strait cell always renders plain painted water, so
     narrow passages stay legible as water and the boundary art belongs
     strictly to the land side. Interior cells
     (combo 0 water / 15 land) keep their plain fills — water = wang_0 (the
     SAME painted tile for both water kinds: sea vs coastal_sea is no
     longer two fills but the depth factor below), land = wang_15 through
     its 8 dihedral transforms as the variant pool (the §9.2 cell hash
     picks among them). Two tiles adjacent across a coast share the same
     vertex row, so the beach is continuous by construction — the family's
     seam guarantee is this corner-vertex geometry, NOT the variant ring
     (the §8.8-8 ring rule is waived for the family via the ledger).
     Provenance + waiver: the family's ledger is
     `tools/assets/pixellab_raw/pixellab_coast_ledger.json` (group 13
     reads it: inventory expansion + palette/budget/ring waiver — the
     hulls-registry precedent); `build_ui_art --check` copies the
     committed tiles into the temp rebuild (never regenerates, never
     contacts the API). **Pixel depth (the user direction "pixel level of
     darker, not tile level"):** every pure-water pixel darkens by a
     factor that varies CONTINUOUSLY with its own Euclidean distance to
     land — factor 1.0 at ≤ **6 tiles** (the §6.2 coastal band), 0.6 at
     ≥ **10 tiles**, linear between; the factor source is the §6.7
     distance raster (`data/maps/dist_land.png`, one R8 texel per tile).
     **Amended 2026-11-07 (the fp16-varying report):** the darkening is a
     CPU-BAKED per-chunk multiply patch, not a shader sample — Godot
     4.7's canvas pipeline stores varyings at half precision (measured:
     fp16-ulp steps on world-scale UVs) and per-chunk origin offsets
     quantize/bias any shader-side sample past tile accuracy (uniform
     dark plateaus + light rectangles; probe: `tools/probe_water.gd`).
     At chunk spawn the loader bakes a 1-px-per-tile gray patch
     (factor-encoded, land tiles white, full 16-bit raster decode,
     x-wrap aware) and draws it over the water as a multiply-blended
     sprite — the GPU's linear filtering of that patch IS the sub-tile
     continuity (no blur pass, no tile-level steps, no shader coordinate
     math). **Animated sea retired (2026-11-07, user direction "remove
     everything"):** the §4.7.17 wave-dither scroll/mask/crest program no
     longer renders on any water layer — water is the painted wang fill
     plus the depth patch; `sea_water.gdshader`, `build_material` and the
     mask/scroll constants stay as dormant machinery (the foam-strip
     precedent) and `build_layer` attaches no material. Reef, polar ice,
     ports and the shore-strip
     system are UNCHANGED this round (their tiles carry the pre-painting
     sea background — regenerating them against the painted water is the
     ledgered follow-up); when the wang ids are absent (registry empty,
     suites) every path falls back to the legacy fills/foam unchanged
     (§4.9). **Coast foam retired (2026-11-06, user direction):** the r5
     coast-foam program (shore wash bands + speckle clusters, the §6.6
     variant columns) is retired from the WORLD path — the world water
     layer builds without shore dirs, the wang beach carries the baked
     shore art, and the r5 foam language read as noise over painted
     water. The machinery stays in `water_layer.gd` as the dormant
     fallback (build_tile_set with explicit dirs still composes it; the
     terrain suite pins verify it directly). The §4.7.17 crest FOAM
     accent is retired with it (`CREST_MIX` 0.70 → 0.0 — the shader
     block stays, the mix is the off switch).
     **Fleet waterline & wake VFX (amended 2026-11-07, user direction —
     the hull tokens stop floating on the water):** every world-map hull
     token — the player `FleetMarker` token and every NPC marker's
     `HullToken` alike — renders the full sandwich keyed on the fleet's
     dir id: the **BACK sheet** below the hull (stern wake fan + under-
     hull shading) → the hull token → the **FRONT sheet** above the hull
     (translucent sea water over the lower hull + waterline foam ON the
     planks = the "half the hull under water" read), both under the
     §4.8.5 letter/chip/count badges. (Scope history, user direction
     same day: NPCs were FRONT-only while the v1 family's ring art
     existed — the closed ripple rings read as noise across hundreds of
     fleets; when the v2 re-roll outlawed rings the scope returned to
     both layers for everyone. The §4.5.2 dashed trails are unchanged
     and stay a separate pinned feature.) Letter-square fallbacks and
     docked fleets wear neither sheet. Family: `fx_waterline_{back,front}_{dir}` (8 dirs),
     `assets/ui/fx/fx_waterline_{back,front}_{dir}.png` plus the
     committed frame table `assets/ui/fx/fx_waterline.json` (per dir:
     canvas w×h, frame count, fps, loop, the effect's `meta.anchor` —
     sheets draw the anchor on the hull cell center; canvases may
     exceed 64×64 for the wake). **Generation:**
     `tools/pixellab_vfx_pass.py` POSTs `/v2/vfx` — envelope pinned
     verbatim, exactly four fields (`description`, `sprite` = the
     shared `hull_galleass_<dir>.png` bytes — the largest silhouette at
     61×64, so the foam line hugs outside every other hull and the ≤5 px
     inner read on smaller ships is wake spread, `artist`, `game_pack:
     true`; the VFX schema has no seed and no style_image), `name:
     waterline-v3-<dir>-pro`. **v1 SUPERSEDED (2026-11-07 user
     sheet review — REJECTED):** the v1 wording produced closed
     elliptical ripple rings around the ship and a thin foam-only front
     layer (no submersion read); the v1 `e`/`ne` raws (and the
     never-downloaded `n` job) are retired for reference only. **v2
     SUPERSEDED (same day, kept as the accepted-look reference):** the
     v2 trial (lite vs pro on `e`) fixed the rings and the submersion
     read — lite quoted 2 (effect_id 6351949f…, 8 frames @10 fps), pro
     quoted 10 (effect_id 6190f842…, 8 frames @8 fps); pro won the A/B
     (user decision: richer water sheet, chunkier foam ridge, visible
     wake trail) — but v2's description never stated the ship's
     travelling direction (the artist inferred bow/stern from the
     sprite alone), so v2 is not the shipping family. **v3 description
     of record (2026-11-07, user direction — the prompt MUST state the
     motion):** the v2 text with an explicit motion sentence inserted
     after the opening clause and two trims to stay under the 1000-char
     quote tier (pro 1.25× ⇒ 10; max 963 chars). Template pinned
     verbatim (doc = source of truth; per-dir files gitignored at
     `tools/ui_art/model_raw/pixellab_vfx/v3/description_<dir>.txt`):
     `Waterline VFX around this high top-down (about 45 degrees from
     above) 16-bit pixel-art sailing ship sprite, 8-frame looping
     animation. The ship is sailing {MOTION}. In front of the sprite:
     translucent deep-blue sea water covers the lower half of the
     wooden hull — the ship visibly sits low in the sea — with a broken
     white foam ridge running along the ship's waterline ON the hull
     planks, plus white spray arcing forward from the bow. Behind the
     sprite: a foam wake fanning out behind the stern, tapering into
     dots, small foam scallops hugging both hull sides. STRICTLY
     FORBIDDEN: circular or elliptical ripple rings or any closed loops
     around the ship; water touches only the hull sides, bow and stern.
     Foam #dff0f4 over dark sea blues; never cover sails, deck, masts
     or the red pennant; transparent background. Style: crisp 16-bit
     pixel art, flat color, matching the ship sprite. Calm seas:
     gentle, slow, subtle.` with {MOTION} ∈ {n: `north (up on screen)`
     (950 chars), ne: `north-east (up-right on screen)` (961), e: `east
     (right on screen)` (952), se: `south-east (down-right on screen)`
     (963), s: `south (down on screen)` (952), sw: `south-west
     (down-left on screen)` (962), w: `west (left on screen)` (951),
     nw: `north-west (up-left on screen)` (960)}. **Trims vs v2
     (disclosed):** cut `strongest on the near side and both ends of
     the hull,` (foam-ridge emphasis — regression check on the sheets)
     and `faint dark shading under the hull,` (under-hull shadow). Raw
     output gitignored under
     `tools/ui_art/model_raw/pixellab_vfx/v3/<dir>_pro/` (sheets + game
     pack + `response.json` carrying
     `effect_id`/`conversation`/quote — retries are discounted
     change-calls; re-download without re-generation); **raw model
     output is never committed**.
     **Ingest:** `build_ui_art --import-fx-pixellab` copies the
     behind/front sheets + frame JSON verbatim into `assets/ui/fx/` and
     writes the provenance ledger `tools/assets/pixellab_raw/
     pixellab_vfx_ledger.json` (effect ids + sheet sha256s); `--check`
     copies the committed family into the temp rebuild (the coast-tiles
     precedent — never regenerates, never contacts the API). The family
     joins the **raw-bytes lazy registry family**: ids resolve through
     the registry miss resolver (file replace + restart, no `.import`
     refresh). **Runtime:** one shared clock in `world_map._process`
     steps every visible fleet's frame from the committed fps/durations
     with a per-fleet deterministic phase offset (marker-id hash — 300
     fleets never foam in lockstep); **sheets render only while the
     fleet is moving (2026-11-07 user direction, speed > 0):** player =
     `SailingSim.effective_speed() > 0` (the HUD knots source —
     becalmed, docked or waiting hides both sheets), NPC = the marker's
     `sailing` flag, the same predicate the §4.5.2 wake layer paints
     from — the hull token itself always shows. Letter-square fallbacks
     and docked fleets wear neither sheet; render-only, the day-tick
     budget is untouched. Battle-screen hulls (60-*) are out of scope.
     **Top-down VFX revision (amended 2026-11-07, same day, user
     direction — SUPERSEDES the per-dir family above; ships rotate at
     runtime, so the wake must rotate with them):** the family
     regenerates as ONE north family per size —
     `fx_waterline_{back,front}_{size}` (size ∈ {32,48,64}),
     `assets/ui/fx/fx_waterline_{back,front}_{size}.png` plus the
     committed frame table `assets/ui/fx/fx_waterline.json` keyed per
     size (canvas w×h, frame count, fps, loop, `meta.anchor`; sheets
     draw the anchor on the hull token center; canvases may exceed
     both the hull canvas and the 64 px cell and spill into
     neighbouring cells on the overlay layers — BACK z = −2 — as the
     per-dir sheets already did). **Generation:** 3 `/v2/vfx` calls
     total (one per size); envelope unchanged (four fields) with
     `sprite` = the representative north token per size — galleass
     64×64, caravel 48×48, latin 32×32
     (`assets/ui/tokens/hull_{galleass,caravel,latin}.png`) — and
     `name: waterline-v4-north-{size}-pro`. **v4 description of
     record:** the v3 template verbatim with two substitutions: the
     opening clause reads `Waterline VFX around this straight
     top-down (directly from above) 16-bit pixel-art sailing ship
     sprite` and {MOTION} is pinned to the single value `north (up
     on screen)` (the runtime rotation turns the whole sandwich, so
     only the north family ever exists). Everything else in the v3
     template (forbidden rings, foam hexes, calm-seas clause, the two
     disclosed trims) is unchanged and stays pinned. Raw output
     gitignored under `tools/ui_art/model_raw/pixellab_vfx/v4/<size>_pro/`
     (sheets + game pack + `response.json` carrying
     `effect_id`/`conversation`/quote — retries are discounted
     change-calls; re-download without re-generation); **raw model
     output is never committed**. **Ingest/runtime:**
     `build_ui_art --import-fx-pixellab` copies the sheets verbatim,
     template-matches each size's anchor and rewrites the frame
     table; the runtime lookup keys on (size, back/front) and the
     sheet rotates together with the hull sandwich around the token
     center (the light source follows the rotation — accepted user
     direction). The per-dir files
     `fx_waterline_{back,front}_{dir}.png` and their frame entries
     retire from `assets/ui/fx/`. Visible-while-moving, the shared
     clock with per-fleet phase offset, letter-square/docked
     exclusions and the §4.5.2 trail separation are all unchanged;
     battle-screen hulls remain out of scope.
     **Single-layer revision (amended 2026-11-07, same day, user
     direction — SUPERSEDES the two-layer sandwich above):** a
     straight top-down token needs ONE effect, not a sandwich — the
     whole wake renders UNDER the ship. The family becomes one sheet
     per size — `fx_waterline_{size}` (size ∈ {32,48,64}),
     `assets/ui/fx/fx_waterline_{size}.png` — and the frame table
     goes to **version 3** (per size: canvas, fps, frame_ms, frames,
     loop, `anchor_sprite`, one `sheet` record; no `layers`). The
     FRONT layer and its "foam ON the planks / half-submerged"
     content retire with the oblique view; z ladder: wake −2, hull
     −1, badges 0. **v5 description of record (pinned verbatim, the
     natural-language revision — the foam is described, not hexed):**
     `Waterline VFX for this straight top-down (directly from above)
     16-bit pixel-art sailing ship sprite, 8-frame looping
     animation. The ship is sailing north (up on screen). The effect
     is drawn ONLY of open sea, never over any part of the ship: a
     foam wake fanning out behind the stern and tapering into dots,
     small foam scallops hugging both hull sides, a thin foam line
     at the bow, and gentle ripples spreading around the hull. The
     effect layer renders under the sprite in the game — the hull
     silhouette area stays completely clean: no foam, water or
     spray touching the decks, sails, masts, rigging or the red
     pennant. STRICTLY FORBIDDEN: circular or elliptical ripple
     rings or any closed loops around the ship. Pale bluish-white
     foam over deep blue sea water. Transparent background
     everywhere the effect is not drawn. Style: crisp 16-bit pixel
     art, flat color, matching the ship sprite. Calm seas: gentle,
     slow, subtle. The 8 frames loop seamlessly.` (≈950 chars — the
     pro quote tier; envelope/inputs unchanged: the representative
     north tokens, `game_pack: true`, `name:
     waterline-v5-north-{size}-pro`, raw under
     `tools/ui_art/model_raw/pixellab_vfx/v5/<size>/`). The ingest
     copies ONE sheet per size, rewrites the table to v3 and prunes
     the retired two-layer files; `waterline_fx` drops the layer
     dimension; visible-while-moving, the shared clock with
     per-fleet phase offset, letter-square/docked exclusions and
     the §4.5.2 trail separation are all unchanged; battle-screen
     hulls remain out of scope. **Acceptance record (2026-11-07,
     single-layer):** the three v5 sheets generated pro (quotes 10
     each; effect ids 4e99cce9…/9ec1928c…/3e72491f…; sheets 45×63,
     43×73, 86×104; anchors template-matched into the size boxes);
     ingest gates: `--check` byte-identical (257 files), validator
     groups 1–13 green, 61/61 suites green.
     **Per-ship wake revision (amended 2026-11-08, user direction —
     SUPERSEDES the per-size family above; the wake is generated for
     EVERY ship type, not just the three size representatives):** the
     family regenerates as ONE north sheet per SHIP TYPE —
     `fx_waterline_{ship}` (ship ∈ the 16 `data/ship_types.json` ids),
     `assets/ui/fx/fx_waterline_{ship}.png` — and the frame table goes
     to **version 4** (per ship: canvas, fps, frame_ms, frames, loop,
     `anchor_sprite`, one `sheet` record, `sprite`; the per-size keys
     {32,48,64} and their sheets retire). The single-layer render
     rules are unchanged — everything UNDER the hull, z ladder wake
     −2 / hull −1 / badges 0. **Generation: exactly 16 `/v2/vfx`
     calls total (one per ship type);** the envelope is unchanged
     (four fields + `game_pack: true`) with `sprite` = that ship's
     OWN north token `assets/ui/tokens/hull_{ship}.png` (the wake
     hugs the hull silhouette it ships with — one representative per
     size read too wide or too narrow on the tier-mates) and
     `name: waterline-v6-north-{ship}-pro`; the description is the
     v5 template verbatim (unchanged, still pinned). Raw output
     gitignored under `tools/ui_art/model_raw/pixellab_vfx/v6/<ship>/`
     (sheets + game pack + `response.json` + the `pixellab_vfx.json`
     manifest keyed by ship id — retries are discounted change-calls;
     re-download without re-generation); **raw model output is never
     committed**. The anchor template-match resolves into the ship's
     OWN token box (the box = the token PNG's canvas — 4×32², 8×48²,
     4×64² across the 16 ships). **Ingest/runtime:**
     `build_ui_art --import-fx-pixellab` copies the 16 sheets
     verbatim, rewrites the table to v4 and prunes the retired
     per-size files `fx_waterline_{32,48,64}.png`; the runtime lookup
     keys on the fleet's ship type id — player = the flagship's
     `ship_type_id`, NPC = the marker's `ship_type` — with the sheet
     still rotating together with the hull sandwich around the token
     center. Visible-while-moving, the shared clock with per-fleet
     phase offset, letter-square/docked exclusions and the §4.5.2
     trail separation are all unchanged; battle-screen hulls remain
     out of scope. Group 13 cross-checks the table keys against
     `data/ship_types.json` (16 ships, no gaps, no extras).
     **Acceptance record (2026-11-08, per-ship):** the 16 v6 sheets
     generated pro at quotes 10 each (effect ids 7e41bb68…/dcae42ef…/
     52cd8127…/54a69cb4…/c086a692…/4befa306…/49f578c6…/81962706…/
     b63845ed…/a662fe8f…/44ccfa87…/e629e08d…/9764bbbf…/4a9a960c…/
     3bb2e05d…/02b225de… in SHIPS order; canvases 43×68 to 136×132; the
     nao pack shipped 6 fps ⇒ frame_ms 167, uniform-gated like the
     rest; anchors 16 × match_rate 1.0 into each ship's OWN token box —
     caravela_redonda's recomputed after the API hyphenated the
     underscore in its effect name, and the pass tool's pack lookup now
     globs `*-game.zip` for that reason). Ingest gates:
     `--check` byte-identical (270 files), validator groups 1–13 green,
     61/61 suites green; review contact sheet
     `tools/ui_art/model_raw/pixellab_vfx/v6/preview/wake_v6_review.png`
     (per-ship frame 0 under its own token, runtime placement).
     **Stretch-safety
   constraint (amended 2026-11-04, master adjudication after the sample
   review):** the runtime skin draws the sheets through
   `StyleBoxTexture` with default `axis_stretch_*` = STRETCH — the
   nine-patch center and every edge span are scaled, not tiled, so
   interior dither smears into large blocks at panel scale. Grain and
   dither therefore live ONLY in the corner tiles (they never stretch);
   fill tiles and edge-tile interiors are flat. Edge interiors must be
   flat in BOTH axes: the assembly's mirror-only `FRAME_OPS` derive the
   bottom/left/right sides from the one authored top edge tile, so any
   per-row-safe pattern there becomes per-column variance (vertical
   smears) on the derived sides.

5. **Hull-letter overlay rule.** identification letters stay as overlay
   badges drawn on top of the token sprite at runtime — never baked into
   the PNG (the authored maps are letter-less). The fleet letter badge
   renders in the world/HUD overlay layer above the `hull_*` sprite
   (replacing the §4.5.2 square's inline letter); S10 unit badges draw
   the same way over their tokens.
6. **heading8 → dir-id table.** `60-*` §4.3a buckets a velocity's
   heading at the 22.5° boundaries — bucket 0 = east (+x), increasing
   counterclockwise in the mathematical frame (screen y-down:
   `(1,−1)` = NE, `(0,−1)` = N …). The sprite dir ids follow that bucket
   order exactly:

   | heading8 bucket | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
   |---|---|---|---|---|---|---|---|---|
   | dir id | `e` | `ne` | `n` | `nw` | `w` | `sw` | `s` | `se` |

   Sprite ids: `hull_{ship_type_id}_{owner}_{dir}` and
   `wind_arrow_{dir}` / `current_arrow_{dir}`, with `{dir}` ∈ the eight
   ids above. **View convention (amended 2026-11-04, user direction —
   supersedes the W1 "top-down for tokens" rule): hull tokens are
   UW2-style side/3-quarter sailing views, NOT top-down deck views.**
   The `e`/`w` pair and `n`/`s` are **oblique elevated (~45°) sailing
   views, NOT flat side elevations** (amended 2026-11-04, second user
   direction): the hull shows a visible **waterline** — below it a
   submerged hull portion in darkened wood tones, above it the freeboard
   with the deck plane read from above; the waterline sits ~60 % down
   the hull and the view shows the deck at ~45° elevation
   (`n`/`s` previously shrank the whole ship): **mast and
   sail HEIGHT stay identical to the side view** — turning the ship
   never shrinks its masts — the hull reads at beam width (~40–60 % of
   the side view's length), and the sails from astern/bow read as
   full-height shapes at that width (a stern lateen is a tall triangle,
   a square rig a tall rectangle); the four diagonals are **3/4 views with the
   standard perspective cheat (amended 2026-11-04, user feedback on the
   first 8-dir strip: honest 45° projections collapse the ship into a
   sliver)**: a diagonal keeps a THICK hull band (≥ 4–6 px wide, deck +
   gunwale readable), sails at ~70–80 % of the side view's sail size,
   and overall canvas presence comparable to the side profile — the
   heading reads from the ~30° diagonal run of the hull and yards, never
   from foreshortening the ship away. Because a side-view ship does not
   rotate losslessly, **all eight hull directions are authored maps**
   (rig fragments composed per direction by the authoring tool) — the
   lossless-derivation scheme below remains for the arrow sets and the
   shore strips only. The owner encoding is the **pennant scheme**
   (§4.8.4 hull block, amended 2026-11-04): every owner draws the same
   shared map (wood/sail/ink owner-invariant) and the tool remaps the
   authoring-only pennant source hex to the owner's `PENNANT_*` hex.

   **UW2 silhouette richness (amended 2026-11-04, user direction with
   reference screenshots — applies to every hull, every direction):**
   1. **Sails dominate the sprite** — total sail canvas ≥ half the
      sprite's height; the masthead reaches near the canvas top edge and
      the hull sits near the bottom edge (fill the 64×64; the band still
      binds the side view's length).
   2. **Stack course + topsail per mast** — two vertically stacked
      sails per mast (course below, topsail above), so a 3-mast ship
      shows six sail masses before jibs/spankers.
   3. **Sail detailing** — 2–3 `SAIL_LO` fold/band lines per sail and
      one `SAIL_HI` specular arc; **national emblems/crosses are drawn
      in the pennant source hex** so the pennant remap colorizes them
      per owner (a Spain ship carries the red cross, England the blue —
      same authored map, owner-colored emblems).
   4. **Hull stripes** — decorative sheer/gunwale stripes may use the
      pass-through pennant values (non-source `PENNANT_*` values pass
      the remap untouched), giving UW2's striped gunwales; gunport rows
      stay dense (≈ 1 port per 4 px of hull length).
   5. `HULL_GOLD` runs the full sheer on tier 3 (not just the castle
      rails).
   6. **The UW2 craft bar (amended 2026-11-04, second user reference
      round — the billow test):** sails are **billowed**: sail edges
      bulge in arcs beyond the yard line (never straight), the interior
      carries curved shade bands that FOLLOW the bulge (`SAIL_LO` bands
      flanked by `SAIL_SH` on the dark flank, one `SAIL_HI` crest along
      the lit bulge), and a straight-edged sail fails review. Hulls are
      **dense** — no empty interior: multi-strake planking, castle/cabin
      faces with 1px lit-window dots, gunport frames, decorative wale
      bands (pass-through pennant values). The sprite fills its canvas
      (side views: hull to the bottom edge, masthead to the top edge).
      `SAIL_SH` and `DECK` join the hull block for this.
7. **Tier footprint bands (final values, 64 canvas — 2026-11-04
   upgrade, ×2 of the retired 32-canvas values).** long-axis px **on
   the side view (`e`/`w`)**: tier 1 (latin, sloop, galiot, pinnace)
   **28–36**; tier 2 (caravel, galley, brigantine, fluyt, junk, dhow,
   caravela_redonda, xebec) **40–52**; tier 3 (nao, carrack, galleon,
   galleass) **52–60** — on the 64×64 canvas; the validator checks the
   long axis there. **Big-lateen tolerance (ledgered 2026-11-05,
   extended same day):** tier-1 latin/galiot/sloop are checked
   against **37** (band hi +1) — the lateen rigs consistently draw
   1px over (latin/galiot on the white-bg round; sloop on the green
   re-roll); the waiver is hull-specific to the three t1 lateen
   hulls, not a band change. On green re-rolls latin (34) and
   galiot (31) landed in-band anyway — the waiver stays as guard. The stern/bow views (`n`/`s`) show the beam and are
   unbanded (canvas-fit only); the diagonals are the 3/4 views (with the
   §4.8.6 perspective cheat — full presence, not foreshortened slivers)
   and unbanded likewise.
8. **Icon sizes & display (amended 2026-11-04, 64-canvas upgrade).**
   semantic icons keep the native 32 px art inline — flush full-cell in
   32px rows, zero regression; the 64×64 canvas serves hero contexts
   (port/fleet/shipyard cards) at 1:1, nearest only; chrome tiles 16×16
   assembled into 48×48 nine-patch
   sheets (16px margins, edge tiles in tile-repeat mode — frames render
   at any size at runtime); FX cannonball/smoke 16×16, splash/impact
   32×32; portraits 72×96 (3:4 bust); discoveries 64×64;
   `sea_pattern.png` 64×64.
9. **LOD pins.** world-map NPC fleets stay colored squares (§4.5.2); S10
   minimap dots unchanged; chart + minimap stay flat raster; the S3
   player fleet token becomes the 8-dir directional sprite
   (`hull_{type}_{owner}_{dir}`; lists/rosters use static `n`). The
   Phase-1 "ship/token colored square" rule of this section is retired
   by this rewrite. **Heading alignment (amended 2026-11-06, user
   direction):** the player token's dir id is `world.heading`, and every
   successful step records its own delta there (`20-*` §4.2) — the token
   always faces the direction the fleet actually sails; the NPC hull
   tokens re-pick their `hull_{type}_{owner}_{dir}` sprite off the
   fleet's current lane heading at every marker sync (per player step and
   on the day tick), so a turning fleet never keeps a stale facing.
10. **S3 arrow-field spec.** pure sampler `scripts/world/arrow_field.gd`:
    stride 4×4 tiles over the visible window + apron, water cells only;
    wind arrow = the month's `prevailing_for(cell, month)` (the Phase-6
    wind-region raster, `10-*` §6.5); current arrow = the decoded,
    reversal-applied current vector (`20-*` §4.16) → 8-bucket per the
    table above; colors wind `TEXT` / current `COAST_SEA` (the sprite
    pins). Toggled by `W`/`C` keys on S3 (session-local, default off,
    mirroring the chart's toggles, §4.3) and re-sampled on month change.
    **Key semantics (amended 2026-11-04, W4-C adjudication — the original
    pin made the current field unreachable):** `W` always toggles the
    wind field; `C` toggles the current field **whenever either arrow
    field is on** (the intel `C` is shadowed while field mode is active);
    with both fields off, `C` is unchanged (the §4.5 intel window), and
    `O`/`F`/the intel button always open the window.
    The HUD's existing wind/current arrows (§4.5) swap to the same
    sprite ids.

- Locked palette (hex):

| Name | Color | Use |
|---|---|---|
| `SEA` | `#16446e` | open water tiles |
| `COAST_SEA` | `#2f6f9e` | coastal tiles |
| `LAND` | `#7a5c2e` | land tiles |
| `REEF` | `#3d3d3d` | reef tiles |
| `ICE` | `#c9d6df` | polar ice tiles (`I`, impassable; `20-*` §4.1) |
| `PORT` | nation colors (`10-*` §7.4) | port markers |
| `PORT_NEUTRAL` | `#9a9a9a` | neutral-port markers/labels (`nation_id: ""`, the `10-*` §7.1 neutral tier) and the debug chart's neutral grey (§4.6); constant `PORT_NEUTRAL` in `scripts/palette.gd` |
| `PANEL_BG` | `#1c2230` | panels/hud bars |
| `PANEL_LINE` | `#465468` | borders |
| `TEXT` | `#e8e6df` | primary text |
| `ACCENT` | `#d9a441` | focus outline, buttons hover |
| `GOOD`/`WARN`/`BAD` | `#4e9e4e` / `#d9a441` / `#b3341f` | morale tiers, toasts |

- **S10 minimap/overlay pins (Phase 9):** no new constants — the seven
  battle-view colors bind to the existing palette: player ship dot =
  `TEXT` `#e8e6df`; enemy ship dot = `BAD` `#b3341f` (a navy fleet's dot
  takes its owner's `Nation.color`); the minimap's viewport frame =
  `ACCENT` `#d9a441`; the wind arrow = `ACCENT` `#d9a441`; the current
  arrow = `COAST_SEA` `#2f6f9e`; the formation anchor lines
  (`line_ahead`/`column`, W4) = `PANEL_LINE` `#465468`; the
  hookable-target ring (`60-*` §4.6a) = `GOOD` `#4e9e4e`.

- Sizing grid: 8px base unit; margins 16px; button height 40px; bar heights
  40/32px (§4.5); table row height 32px; dialog width 480px.
- **Audio (placeholder note):** silence in Phase 1; hook method
  `EventBus.play_sfx(name)` exists as a no-op; free-asset replacement pass is
  a Phase-3 task.

#### 4.8.1 Port hub facility cards (S4, added 2026-11-02)

The S4 facility list is a **fixed card grid**: the open/closed state never
changes the layout. (The §4.1b first build laid open facilities two per line
and gave every closed/stub row a full-width line of its own, so the hub
visibly jumped at every opening/closing hour.)

- **Grid:** two columns, **left-aligned**, 8px separation, cells filled in
  the §4.1 fixed order (Market · Shipyard / Tavern · Inn / Guild · Palace).
  A port whose data omits a facility simply renders one card fewer; the
  cards never stretch with window width.
- **Card:** a **320×64 px** Button whose whole surface is clickable. Inside,
  a full-rect VBoxContainer (alignment center, `mouse_filter` ignore on the
  box and both labels) holds two centered labels: the facility name
  (default font size; `TEXT` when the card is enabled, `PANEL_LINE` when
  disabled) above a **12px** status line.
- **Status line (locked):**

| Card state | Status key | Color |
|---|---|---|
| open (windowed) | `port.facility.open_now` | `GOOD` |
| open 24h (no window) | `port.facility.open_always` | `GOOD` |
| hours-closed (`30-*` §4.1b) | `port.facility.closed` | `PANEL_LINE` |
| bounty-closed (`70-*` §4.9.6) | `port.closed_bounty` | `PANEL_LINE` |
| future-phase stub (`30-*` §4.1) | `port.stub.phase3` | `PANEL_LINE` |

  Precedence when several states collide: bounty > hours > phase stub.
- Clickability is unchanged: the card is disabled exactly when the §4.1b
  entry gate (`port_screen._facility_available`) refuses it; the Space wait
  (`30-*` §4.3) re-enables it on the next crossing hour. Routing, gating and
  the rebuild signature never move — only the rendering is fixed.

### 4.9 Shared theme & widget kit (Phase 10)

**Texture-mode state mapping (amended 2026-11-04, user feedback: the
first texture theme reused one sheet for normal/hover/pressed, leaving
hover and toggle-selection invisible).** When the nine-patch sheets are
active, states resolve per sheet with `StyleBoxTexture.modulate_color`:
**normal** = `ninepatch_button`; **hover** = `ninepatch_button_focus`
(the ACCENT ring); **pressed (momentary click)** = `ninepatch_button`
modulated ×0.82; **toggle-pressed (a held/selected card, e.g. the S2
nationality cards)** = `ninepatch_button_focus` modulated ×0.88
(distinct from plain hover); **disabled** = `ninepatch_button`
modulated ×0.45 (+ the `PANEL_LINE` disabled text). Keyboard focus =
`ninepatch_button_focus` (as hover — acceptable). Panel/LineEdit
variants have no states and keep their single sheet. All modulate
factors are named constants in `ui_theme.gd`.

**Application point.** `scripts/ui_theme.gd` `build_theme() -> Theme`
applies once at startup to the root window (`get_window().theme` in
`title_screen._ready()` — S1 is the locked main scene) and cascades to
every control. No `.tres`. Headless suites that boot scenes directly
apply `build_theme()` themselves (the direct-boot pattern is documented
in the test docstring). `project.godot` stays unchanged — no new
autoload: both `ui_theme.gd` and `ui_kit.gd` are `class_name` statics.
Motion gating is the `UiMotion` static (§4.7.17).

**Pinned numbers** (each row = a named constant in `ui_theme.gd`; all
hexes resolve to existing `palette.gd` constants):

| Control | Pins |
|---|---|
| Button | normal bg `PANEL_BG` + 2px border `PANEL_LINE`; hover border `ACCENT`; pressed bg `PANEL_LINE`; disabled text `PANEL_LINE`; keyboard focus = extra 2px `ACCENT` ring |
| V/HScrollBar | trough transparent; 8px grabber `PANEL_LINE`, hover/pressed `ACCENT`; min grabber 24px |
| Panel / PanelContainer | `PANEL_BG` + 2px `PANEL_LINE`, radius 4px (nine-patch sheets layered at W3; flat StyleBoxFlat remains the fallback when a texture id is absent) |
| LineEdit / TextEdit | bg `PANEL_BG`, border `PANEL_LINE`, focus border `ACCENT` |
| Slider (S19) | grabber `ACCENT`, groove `PANEL_LINE` |
| Tooltip | bg `PANEL_BG`, text `TEXT`, radius 4px, 8px padding |
| Label | `TEXT`; `Dim` variation `PANEL_LINE` for secondary row text |

**State matrix** ("—" = the control class has no such state; the theme
defines nothing for it):

| Control \ state | normal | hover | pressed | disabled | focused |
|---|---|---|---|---|---|
| Button | bg `PANEL_BG` / border `PANEL_LINE` | border `ACCENT` | bg `PANEL_LINE` | text `PANEL_LINE` | extra 2px `ACCENT` ring |
| Button · Primary | Button row, border/accent slots `ACCENT` | border `ACCENT` | bg `PANEL_LINE` | text `PANEL_LINE` | 2px `ACCENT` ring |
| Button · Danger | Button row, border/accent slots `BAD` | border `BAD` | bg `PANEL_LINE` | text `PANEL_LINE` | 2px `BAD` ring |
| Button · Quiet | transparent bg, no border | Button hover/pressed cells | bg `PANEL_LINE` | text `PANEL_LINE` | 2px `ACCENT` ring |
| ScrollBar (V/H) | trough transparent / grabber `PANEL_LINE` | grabber `ACCENT` | grabber `ACCENT` | grabber `PANEL_LINE` | grabber `ACCENT` |
| Panel / PanelContainer | `PANEL_BG` + 2px `PANEL_LINE`, radius 4px | — | — | — | — |
| LineEdit / TextEdit | bg `PANEL_BG` / border `PANEL_LINE` | border `PANEL_LINE` | — | text `PANEL_LINE` | border `ACCENT` |
| Slider | grabber `ACCENT` / groove `PANEL_LINE` | grabber `ACCENT` | grabber `ACCENT` | grabber `PANEL_LINE` | grabber `ACCENT` |
| Tooltip | bg `PANEL_BG` / text `TEXT`, radius 4px, 8px pad | — | — | — | — |
| Label | `TEXT` | — | — | `Dim` (`PANEL_LINE`) | — |

**Atom contracts** (`scripts/ui_kit.gd`, static factory — six atoms plus
the toast atom):

| Atom | Contract |
|---|---|
| `button(text_key, kind, icon_id = "")` | `kind` ∈ default/primary/danger; min height 40px; optional icon id; press flash per §4.7.17 |
| `frame(title_key)` | titled PanelContainer: header + 16px-margin VBox |
| `row(cols, height = 32)` | horizontal row of `cols` cells |
| `footer(buttons)` | right-aligned button row |
| `value_bar(value, max, tier)` | GOOD/WARN/BAD colors by tier |
| `field_row(label_key, control)` | label + control on one 32px row |
| `toast(...)` | kit toast atom for private modal toasts (fade per §4.7.17) |

Labels resolve through `I18n.t_key`; screens keep their
`locale_changed` re-render pattern.

**No-per-screen-styling rule + allowlist.** `add_theme_*`, local
`StyleBoxFlat` and `StyleBoxTexture` may appear only in
`{scripts/ui_theme.gd, scripts/ui_kit.gd}` ∪ the allowlist table below.
The sweep is mechanical across every screen (484 call sites / 26 files
at review — the count itself is never pinned, the rule is); no screen
redesign; visible diffs are limited to unified hover/pressed/focus
states, on-palette scrollbars and the generated art. The allowlist
starts EMPTY and gains entries only by master-ledger adjudication.

| File | Reason | Expiry |
|---|---|---|
| *(empty)* | entries added only by master-ledger adjudication | — |

**Icon params.** kit atoms and screens reference sprite ids —
`good_{id}`, `eq_{id}`, `role_{id}`, `facility_{id}`, and the `ui` icons
per the A.2 inventory of `IMPLEMENT-Phase10.md` — resolved through the
W3 texture registry; an absent id ⇒ flat fallback (no crash).

### 4.16 W3/W4 symbol contracts (Phase 7 — the launch condition; §4.9 before Phase 10)

These are the cross-worktree contracts for the Phase-7 W3/W4 code tasks
(K/L/M/F/N/V): **names exact**, quoted verbatim from the ratified backlog
(`IMPLEMENT-Phase7.md`, task C). This section is the **single statement**
of the list — implementing tasks, suites and wave prompts reference it by
section number and never restate it.

```
Allegiance.effective_alignment(port_id) -> String
Allegiance.dev(port_id) -> int
Allegiance.tariff_mille(port_id, nation_id) -> int        # 0/500/2000 after permits — called by trade_engine and the NPC crediting
Allegiance.invest_block_reason(port_id) -> String         # "" or a ui_strings key
Allegiance.last_month_investments() -> Array
Allegiance.credit_tax(port_id, payer_nation, gold) -> void
Allegiance.seed_new_game() -> void
Allegiance.month_tick() -> void

npc_config.json key: neutral_coasters_mult
rumor row kind: "investment"
```

- `Allegiance` is a **new autoload** (`scripts/port/allegiance.gd`, task L
  owns the implementation, `90-*` module row). L implements exactly these
  signatures; K/M/F/N/V call only these.
- **Guard-call convention (order-independent merges).** Every W3/W4
  module **guard-reads** `Allegiance` (autoload-present check, the
  Phase-6 guard pattern of `60-*` §4.12.3) and falls back to the safe
  defaults: **dev 0 / alignment = the port's data `nation_id` / tariff
  2000 / no telegraph rows** — so a module merges green before, with, or
  after the allegiance engine lands.
- Consumers of the block-reason contract resolve a non-empty return
  through `I18n.t` (it is a `ui_strings` key, §4.7.15's
  `market.invest_gate.*` states).

### 4.10 Phase-8 at-sea interaction layer (right-click, picker, hail, intercept)

Phase 8 keeps **left-click sail-to byte-for-byte unchanged** (§4.3) and
turns right-click into the interaction surface. Dispatch lives in
`scripts/world/interactions.gd`; hail option building lives in
`scripts/world/hail_options.gd`. The combat-side rules (piracy, contact,
coaster pins) are `60-*` §4.11.15; all strings are §4.15 families.

#### 4.10.1 Right-click & the fleet picker (`scenes/world/fleet_picker.tscn`)

- **Hit rules (locked):**
  - right-click **inside sighting radius** (`48 + floor(navigation / 12)`,
    `20-*`) on a tile holding one or more fleets → the picker;
  - right-click on a **port harbor tile** → the port context menu
    (§4.10.3);
  - right-click on empty water or land → **no-op** (no toast, no menu).
- **Picker:** one row per fleet on the tile — flag color (`Nation.color`),
  role icon (the §4.5.2 marker letter), the **identified name** (Phase 8:
  every captain carries a canon name — the row shows it) and the **tier
  badge**. A multi-fleet tile picks its target first (the rows are the
  pick list); a single-fleet tile may render the verbs directly beside
  its row.
- **Verbs:** `inspect` — opens the captain's §4.12 card (identify = full
  reveal); `talk` — the hail (§4.10.2), enabled within Chebyshev 2 and
  grayed with the distance reason beyond it; `attack` — the existing
  funnel (the intercept order below, then the `60-*` §4.11.11.2 contact
  battle). **A `coaster`-role fleet renders no attack verb**
  (intimidate-only, `60-*` §4.1.1/§4.11.15).
- Strings: `interact.verb.*`, `interact.pick.*` (§4.15).

#### 4.10.2 Hail modal (`scenes/world/hail_modal.tscn`)

The talk verb at **Chebyshev ≤ 2** opens the hail modal over S3. Options
are built from role × stance × skills and render as rows with their terms
inline; a gated option is grayed with its `gate.*` reason. The modal owns
all input while open (§4.7 modal rule).

**Modals are hosted on the interaction `CanvasLayer` (amended 2026-11-03):**
`world_map` is a `Node2D` whose map canvas sits at `z_index 10`, so a modal
added as its plain child rendered *behind* the water — `visible`, in the
tree, full-rect, and invisible on screen. Every at-sea interaction modal
(the hail, the message dialog, the fleet picker) is therefore added to the
one `InteractLayer` (`CanvasLayer`, layer 3) the world scene already owns.
The talk verb was dead in play for exactly this reason while
`test_interactions` stayed green: that suite called `_on_picker_verb`
directly and asserted the modal's `visible` flag, never that the modal was
on a canvas above the map.

- **问讯 ask rumours** — a rumour line; **stance ≥ +2** appends one free
  route/market intel (the same intel shape the captain's table points
  at).
- **买补给 buy supplies** — `trader`/`coaster` captains only: port price
  ×1.5, **×1.25 at stance ≥ +3**, minus `floor(negotiation / 10)`%;
  quantities via the §4.6.1 stepper convention, charged on confirm.
- **威吓 intimidate** — success chance per `60-*` §4.11.15
  (`clamp(strength share + 胆识/200 − stance penalty, 0.05, 0.95)`):
  success takes half the target's cargo (floor per good) + pirate fame
  +5; failure turns the target hostile and the battle opens.
- **交好 befriend** — stance +1, **once per captain per day** (a used
  befriend renders disabled with its reason).

#### 4.10.3 Port context menu (right-click on a harbor tile)

Rows: `靠港 dock` (the standard docking edge into S4) and `委任航行
appoint voyage` (§4.10.4; grayed with its `gate.*` reason when the
`sail.autopilot` gate fails — pilot not in post, navigation < 40, or the
port not in `known_ports`). Every other right-click target is the §4.10.1
no-op.

#### 4.10.4 Appointed voyage — entries, HUD bar, interrupts

- **Entries:** the Chart (S17) gains an **委任航行** action on a selected
  **known** port (`20-*`, the appointed-voyage input-mode section); the
  §4.10.3 port context menu is the at-sea shortcut. Gate = the
  `skill_gates` `sail.autopilot` row (pilot in post **and** navigation
  ≥ 40, `50-*`); grayed + reason otherwise; no fee.
- **HUD bar:** while appointed, `scenes/world/autopilot_hud.tscn` is
  instanced into the world HUD (§4.5) — `目的地 {port} · 预计 {days} 天 ·
  [取消]` (`sail.autopilot.hud.*`). Cancel returns control immediately;
  no clock cost beyond the sailing already done.
- **Interrupts:** hostile contact **auto-cancels with a notice toast**
  (`sail.autopilot.cancelled_contact`) before the `60-*` §4.11.11.2
  battle opens; **any manual input cancels**; **storms do not cancel**
  (auto-reef, `20-*`).

### 4.11 Phase-8 in-port people surfaces (verb matrices, captain's table, dossier)

The §4.7.8 sighting rolls are unchanged; what changes is that a sighting
row is now **interactive**. Every verb row carries its terms inline and
gray-renders with its `gate.*` reason when gated. A facility without a
sighted captain simply shows its rows without people verbs.

#### 4.11.1 Verb matrices per facility (locked)

| Facility | Sighting-row verbs (Phase 8) |
|---|---|
| Market (S5) | **行情 quotes** — the sighted trader captain's current-lane price intel (the ask-rumours intel shape); **补给预订 supply pre-order** — stage supplies for the next Set Sail: the row jumps into the §4.6.1 provisioning prompt with the quantity pre-staged (the prompt stays the only purchase seam) |
| Tavern (S7) | **交好 befriend** (stance +1, once per captain per day — the hail rule); **切磋 sparring bet** (below); the **captain's table** index (§4.11.2) |
| Inn (S8) | **受限谈话 limited talk** — +1 extra familiarity, **once per port visit** |
| Palace (S13) | **悬赏公务 bounty business** — the bounty-board rows link to dossiers (§4.11.3); **告发 inform on pirates** — 500g reveals a wanted captain's exact live position (the `captain.reveal.text` shape) |

- **Sparring bet (tavern, locked numbers):** the tavern champion's
  swordplay is **40**; the stake runs 100–1,000g in 100g steps and is the
  pot; win chance `p = clamp(0.5 + (player_swordplay − 40) / 200, 0.10,
  0.90)` (seeded; in-band values 0.30 / 0.50 / 0.80 at swordplay 0 / 40 /
  100 — the clamps engage only outside the 0–100 skill band); **a win pays
  `pot × 2`**; a loss forfeits the stake.
  **Each bout counts as 3 swordplay usages** (growth counter, `50-*`).
- Strings: `interact.market.*`, `tavern.spar.*`, `inn.talk.*`,
  `palace.inform.*` (§4.15).

#### 4.11.2 The captain's table (tavern index)

A tavern section listing **this port's sightings** (the §4.7.8 roll
output): one row per sighted captain — name, role, stance/familiarity
hint — each row opening the captain's §4.12 card and carrying a
**facility pointer** naming where that captain can be found right now
(the market / tavern / inn / palace row its sighting rolled). A sighted
captain's pointer names exactly one facility; "gone ashore" captains
render the `captain.gone_ashore` line without a pointer. Strings:
`captain.table.*` (§4.15).

#### 4.11.3 Dossier panel

A **card-external** information layer, opened from any captain entry
(picker inspect, captain's-table row, bounty row, hail modal): the full
§4.12 card **plus the career log**. The panel is read-only.

- **Familiarity gates only the career log (locked):** tier **3** = the
  captain's last-seen **fleet composition**; tier **6** = **home port +
  sighting history**; tier **10** = the **full lane picture including
  month variants** (`10-*` lane variants). Below a tier, its log section
  renders locked with the reason (`dossier.locked.*`).
- **Card numbers are never gated** — identify = full reveal (§4.12).
- **The picker's inspect view has no separate dossier button (amended
  2026-11-03):** the card rendered there **is** the dossier's card section,
  and the picker header already names the captain, so a `档案:<name>`
  button beneath it repeated the title and duplicated the card. The
  dossier's own entries (captain's table row, bounty row, hail) keep their
  links (§4.11.3 above).
- **Stance ≥ +2** adds the captain's current tier + status (在航 at sea /
  归队中 returning) to the panel header.
- **Bounty board links to dossiers:** every palace bounty row gains an
  open-dossier action.
- Strings: `dossier.*` (§4.15).

### 4.12 The unified character card, allocation & the captain view
      (the retired S14 rework, absorbed into the §4.5 intel window)

#### 4.12.1 `scenes/ui/character_card.tscn` (locked layout)

One scene renders **any** Person — player, officer, NPC captain — with an
identical structure from every entry:

- **Portrait:** a color block composed from the appearance tags
  (`{face, beard, eyes, …}` — §4.8 palette, placeholder-first).
- **Identity row:** name / flag color block / role / tier badge / level.
- **Attributes and skills side by side (amended 2026-11-03):** the five
  attribute bars (体魄 / 悟性 / 魅力 / 胆识 / 运气, 1–100) sit in the **left
  column** and the skill bars in the **right column** of one two-column
  block, so the card reads in half the height. The signature skill is
  highlighted; a 0-value skill is grayed as unlearned. Player cards still
  show the usage counter beside each skill; officer cards show nothing there
  (usage counters are player-only, `50-*` §4.3.3).
- **The skill row shows the EFFECTIVE value (amended 2026-11-03):** on the
  player card a skill row's number is `effective skill = player skill + the
  one in-post officer's true value` (`50-*` §4.5.3), and the bar fills to
  that same value — the card never asks the player to add two numbers in
  their head. The row keeps its existing width (name · bar · value · usage
  counter): the split lives in the tooltip, the row carries the answer.
  Officer and NPC cards have no contribution model, so their rows show the
  plain stored value. The three officer-only rows (medicine / carpentry /
  cooking) show the in-post contribution — 0 while the post is vacant —
  which is exactly the read `SailingSim.effective_carpentry` uses for the
  at-sea repair gate (`40-*` §4.5); their gray label still marks them as
  skills the player does not train.
- **Hover explanations (amended 2026-11-03):** every attribute row and every
  skill row carries a `tooltip_text` explaining what the stat feeds, read
  from `char.attr.<key>.desc` / `skill.<key>.desc` in `ui_strings.json`
  (`50-*` §4.2.1 and §4.3.1/§4.3.2 verbatim). The card never prints the
  explanation inline — the bar label stays one word. **A player skill row's
  tooltip also carries its numbers and its gates** (§4.12.3 amended): the
  base value, the in-post officer's contribution with their name, the
  effective total, then every `skill_gates.json` row whose `stat_or_skill`
  is that skill with its threshold and its 已解锁 / 未解锁 state. That is
  why the captain page needs no separate effective-values block and no
  separate locked-gate list — the row answers "what is it", "why is it that
  big" and "what does it unlock" in one place.
- **The stepper and the bar never eat the hover (amended 2026-11-03):** the
  bar is a `ProgressBar`, which defaults to `MOUSE_FILTER_STOP`; left alone
  it swallowed the whole row's hover and the row's tooltip only appeared
  over the one-word label. Every non-interactive child of a stat row is
  therefore `MOUSE_FILTER_IGNORE` and carries the row's tooltip, and the
  allocation `+` stepper keeps its own tooltip (the clamp note at the cap).
- **Personality tags** and the **appearance sentence** assembled from the
  part keys (`char.personality.*`, `char.appearance.*`, §4.15).
- **Relation block:** officer = loyalty + native role / current post;
  NPC captain = stance + familiarity.
- **Career block:** player = XP / level; NPC captain = wins / defeats /
  return day.
- **The effective-values block is retired (amended 2026-11-03):** the
  standalone 生效值 split that used to follow the skill list folded into the
  skill rows and their tooltips (above). The `card_data` `effective` array
  stays — it is the read seam the rows and the tests consume — but the card
  no longer renders a second copy of it.

**IDENTIFY = FULL REVEAL (locked):** an identified NPC captain's card
shows every number; familiarity gates only the dossier career log
(§4.11.3). **The same captain's card is identical from every entry**
(picker inspect, captain's-table row, bounty row, hail modal, battle
intro preview) — acceptance-pinned.

**The stat-block opt-out (amended 2026-11-03):** a host that already shows
the attributes and skills elsewhere passes `stat_blocks: false` to
`card_data`. The one such host is the officers detail page (§4.6.2), whose
table owns the attribute/skill columns. The opt-out is a **rendering**
option only — `card_data` still carries the numbers, and every other entry
keeps the identical full card (the identity pin above is scoped to the
entries that render the stat blocks).

**Entries (locked set):** panel header (player); officer row / tavern
recruit dialog (officers); picker inspect / captain's-table row / bounty
row / hail modal / battle intro preview (NPC — §4.7.1).

**Sizing (2026-11-03 amendment, the collapsed-strip fix):** the card's
inner scroll is a scrollable axis, which hides the content height from
parent containers — every host that did not hand the card an explicit
height got a ~32px empty bordered strip (S18 rows, the tavern recruit
dialog, the S14 person tabs). The card therefore **publishes the rendered
content height as its inner scroll's minimum size** after each rebuild;
hosts take the card at its content height and scroll it in their own
containers (S18 panel scroll, recruit dialog, dossier, picker). No host
wraps the card in a second scroll (amended 2026-11-03): the intel window's
views each own **one** page scroll, so a card inside them scrolls with the
whole page.

#### 4.12.2 Allocation UX (level-up points, locked flow)

`award_xp` detects the level-up → toast `char.level_up` +
`alloc_pending += 2` (**persisted**, save v9) → a badge on the **情报 intel
button** (`char.points_pending`; amended 2026-11-03 — the badge rode the
retired top-bar character button, and moves with the 船长 entry into the
§4.5 menu, whose button is the top bar's only remaining right-side
affordance). The player allocates on **their own
card's attribute tab** at leisure:

- per-attribute `+` stepper (enabled iff `alloc_pending > 0`) → the rows
  enter the **draft** → `确认` commits / `取消` rolls the draft back;
- a single attribute clamps at 1–100; **no second confirm dialog**;
- **skills never allocate** (usage growth + paid training only, `50-*`);
- points are **deferrable forever** — the badge persists until spent.

#### 4.12.3 The captain view (the intel window's 船长 tab) + the appointment flow

The retired S14 tabbed panel collapsed into this **single scrollable page**
(amended 2026-11-03; the person tabs showed the same card on both, and the
duplication is gone by merging them):

| Section | Shows |
|---|---|
| **§4.12 player card** | the five attribute bars, level / XP, the §4.12.2 allocation steppers, and the eight skill bars with their usage counters — ONE card instance, one render. The skill rows carry the **effective value** (base + in-post contribution) and their tooltips carry the base / contribution / total / gates split, so the page needs no separate 生效值 block (§4.12.1 amended) |

The 声望 reputation table moved to its own 声望 tab and the 官员 roster to
the 官员 tab (§4.6.2), the Phase-3 委托 list to the 委托 tab (§4.7.3) — the
2026-11-03 intel window amendment removed them from the captain page because
the window hosts them.

**The 未解锁 Locked list is retired (amended 2026-11-03):** the fourteen
gate rows used to sit in their own section under the card, duplicating what
the skill rows now answer on hover. Every gate still reaches the player —
each one is listed, with its threshold, the current value and its
已解锁 / 未解锁 state, in the tooltip of the skill row it belongs to
(`data/skill_gates.json` stays the single source; `50-*` §4.3.5). The gate
data is not filtered or thinned: a row lists all of its gates.

**Skill-row tooltip, exact shape (§4.12.3 amended 2026-11-03):**

```
操船
基础 5 · 官员贡献 +30 (马特乌斯) · 生效 35
恶劣天气修帆 · 需操船 ≥ 60 · 未解锁 (35/60)
海上小修 · 需修造 ≥ 60 · 未解锁 (35/60)
```

The first line is the value split (`char.card.tip.base` /
`char.card.tip.officer` / `char.card.tip.effective`); the contribution part
is omitted when no post contributes. Each following line is one gate whose
`stat_or_skill` is this skill: its localized `name` · `gate.requires` · the
`gate.unlocked` / `gate.locked` state · `current/threshold`. A skill with no
gates simply ends after the split — the tooltip never pads with an empty
section.

**Every gate has exactly one home (amended 2026-11-03):** a gate renders on
the tooltip of the card row that owns its `stat_or_skill`, and **all
fourteen** land on the player card's eleven skill rows — so retiring the
separate list hides none of them. Thirteen key on the eight player skills
(navigation ×2, gunnery ×2, swordplay ×2, appraisal ×2, negotiation ×2,
seamanship, cartography, rumour). The fourteenth, `repair.at_sea`
(修造 ≥ 60), keys on the **officer-only** carpentry skill: the player owns
no carpenter level, so that row's value is the in-post officer's
contribution (the same `effective skill` read `SailingSim.effective_carpentry`
uses, `40-*` §4.5) — 0 while the post is vacant, the carpenter's true value
while filled. The three officer-only rows (medicine / carpentry / cooking)
therefore show their effective value like every other skill row; the gray
label still marks them as skills the player does not train. `data/skill_gates.json`
stays the single source for all fourteen; nothing is filtered by hand.

**Officer actions (the 官员 tab's detail page; formulas `50-*`):** `talk` (loyalty +1,
10-day cooldown), `gift` (200g → loyalty +5; +8 贪婪 / +3 忠厚, 10-day
cooldown), `train` (the paid-training formula), `appoint` (the post
table). The **post column** renders prereq-gray + reason through the
same data-driven gates renderer (`officer_posts.json` prereqs ship their
`gate.*` reasons in the `skill_gates.json` shape). `appoint` / `Dismiss`
are port actions; `talk` / `gift` / `train` work anywhere (§4.6.2).

**Fleet-view captain rows (the 船队 tab):** every non-flagship ship row gains a
**"captain: ___"** line naming its appointed captain (or the
`officer.post.no_captain` state — the captain-less penalties of `40-*` /
`50-*` apply), with the appoint shortcut into the 官员 tab's post table
(§4.6.2).

### 4.13 Creation screen (S20, Phase 8)

`scenes/title/creation_screen.tscn` — the **two-step** flow between the
nationality card (S2, unchanged, hands off) and S4:

1. **出身 background** — a 6-choice card grid (`data/backgrounds.json`,
   zh/en name + bio + bonus line): 甲板水手 体+3/操船+5 · 海军见习生
   胆+3/航海+5 · 商行学徒 魅+3/交涉+5 · 制图学徒 悟+3/制图+5 · 酒馆跑腿
   运+3/打探+5 · 剑馆弟子 胆+3/剑术+5.
2. **自由点数 free points** — attributes +5 and skills +3 total,
   per-item cap +3, **must spend all** (confirm stays disabled with the
   remaining-points count otherwise); a **均匀分配 spread evenly**
   shortcut button (attributes +1 each; the first three skills +1 each);
   the §4.12.2 steppers, clamped 1–100 (attributes) / 0–100 (skills).

- **Live derived preview:** sighting / fleet speed / duel value move with
  the steppers — **the same source formulas** (`20-*` / `50-*` / `60-*`),
  never a re-derivation; each line shows `base → value` as points are
  spent.
- Creation extremes stay inside the balance band: attribute ≤ 21, skill
  ≤ 13 (`50-*`).
- `GameState.new_game(nation_id, background_id, attr_alloc, skill_alloc)`;
  `background_id` persists in save v9's player block.
- Strings: `creation.*` (§4.15). Reuses the nationality card component
  and the §4.12 card components.

### 4.14 Retirement screen RPG segment (S16, Phase 8)

The S16 summary gains a **read-only** RPG section above the six summary
rows — every line derives from existing state (`captain_states`,
`officer_states`, the player block), pure display:

- **宿敌榜 nemesis list** — the top **3** defeated captains ranked by
  their wins against the player (name + tier + stance);
- **最深恩仇 deepest grudge** — the captain with the lowest stance;
- **最忠诚老部下 most loyal veteran** — the highest-loyalty officer with
  **≥ 90 sea-days served**;
- **出身回望 background bio** — one line from the player's
  `backgrounds.json` bio.

Strings: `ending.rpg.*` (§4.15). Empty states (no defeats / no veteran
yet) render the `ui.empty` convention.

### 4.15 Phase-8 `ui_strings.json` families (orchestrator-merge contract)

Same protocol as §4.7.10/§4.7.15: W2-C authors the keys from this
inventory; zh/en complete and placeholders matched per key
(validator-enforced). The table pins each family's coverage with example
keys (zh/en shown for the examples); the full key lists are W2-C's task,
and a code review that misses a key reports it (the master micro-ledger
merges residuals).

| Family | Covers | Example keys (zh / en) |
|---|---|---|
| `char.*` | level-up toast, allocation badge, officer-action labels, card chrome | `char.level_up` 等级提升!可用 +2 点。/ Level up! +2 points to allocate. · `char.points_pending` 待分配点数 / Points to allocate · `char.action.gift` 赠礼 / Gift |
| `skill.*` | the 8 skill names + usage-counter labels | `skill.navigation` 航海 / Navigation · `skill.uses` 熟练 {count}/{need} / Uses {count}/{need} |
| `gate.*` | the one locked-reason renderer's rows (features + posts) | `gate.sail.autopilot` 需领航员在岗且航海 ≥ 40 / Needs a pilot in post with Navigation ≥ 40 |
| `hail.*` | hail modal options, terms, results | `hail.option.intimidate` 威吓 / Intimidate · `hail.intimidate.win` {name} 交出了半舱货物。/ {name} hands over half their cargo. |
| `interact.*` | picker verbs + intercept order | `interact.verb.inspect` 详查 / Inspect · `interact.verb.attack` 攻击 / Attack · `interact.intercept.set` 拦截:{name} / Intercept: {name} |
| `dossier.*` | dossier panel + career-log tiers | `dossier.title` 档案:{name} / Dossier: {name} · `dossier.locked.tier` 熟悉度不足(需 {tier}) / Not enough familiarity (needs {tier}) |
| `captain.table.*` | tavern captain's-table index | `captain.table.title` 船长桌 / The captains' table · `captain.table.at` 现在位于:{facility} / Now at: {facility} |
| `officer.post.*` | post names + the captain-less state | `officer.post.pilot` 领航员 / Pilot · `officer.post.captain` 舰长 / Ship captain · `officer.post.no_captain` 无舰长 / No captain |
| `advice.*` | the 6 in-post advice events, `advice.{post}.{situation}` | `advice.pilot.wind_band` 领航员:明日将进入风带。/ Pilot: we enter a wind band tomorrow. |
| `creation.*` | background cards, free points, spread evenly | `creation.points.left` 剩余 {count} 点未分配 / {count} points left to spend · `creation.spread` 均匀分配 / Spread evenly |
| `sail.autopilot.*` | appoint / cancel actions, HUD bar, notices | `sail.autopilot.appoint` 委任航行 / Appoint voyage · `sail.autopilot.cancelled_contact` 遭遇敌对船队,委任航行取消。/ Hostile fleet sighted — the appointed voyage is cancelled. |

Notes pinning the set exactly:

- `advice.{post}.{situation}` is a closed 6-entry table (the
  `officer_posts.json` `advice` field, `50-*`): `advice.pilot.wind_band`
  · `advice.surgeon.water_low` · `advice.boatswain.storm_sail` ·
  `advice.gunner.first_contact` · `advice.carpenter.durability_low` ·
  `advice.cook.morale_low`.
- Personality / appearance part keys join the inventory
  (`char.personality.*`, `char.appearance.face|beard|eyes|…`) — the card
  assembles the appearance sentence from the part keys.
- Post prereq reasons are `gate.*` keys (the renderer is shared, the
  `skill_gates.json` shape); `officer.post.*` owns only the post names
  and the `officer.post.no_captain` state line.
- The 6 backgrounds' name + bio live in `data/backgrounds.json`
  (L10nString per the `10-*` §4.22 schema — content stays data, `00-*` §9);
  `creation.*` owns only the flow chrome (step titles, point counters, the
  spread-evenly button, validation messages). The S16 bio line reads the
  same `bio` value from the data file.
- The retirement segment's strings **extend the existing `ending.*`
  family** (`ending.rpg.nemesis_title`, `ending.rpg.grudge`,
  `ending.rpg.veteran`, `ending.rpg.bio` + their row-composition keys) —
  no new family.

## 5. Data Examples

`ui_strings.json` excerpt (shape):

```json
{
  "version": 1,
  "ui.back": {"zh": "返回", "en": "Back"},
  "ui.confirm": {"zh": "确认", "en": "Confirm"},
  "ui.cancel": {"zh": "取消", "en": "Cancel"},
  "market.buy": {"zh": "购买", "en": "Buy"},
  "market.sell": {"zh": "出售", "en": "Sell"},
  "market.hold_full": {"zh": "货舱已满", "en": "Cargo hold is full"},
  "world.open_sea": {"zh": "外海", "en": "Open sea"},
  "world.arrive": {"zh": "抵达 {port}。第 {day} 天。", "en": "Arrived at {port}. Day {day}."},
  "world.desertion": {"zh": "士气低落,{count} 名船员在进港时离去。", "en": "Low morale: {count} crew deserted on arrival."},
  "inn.odd_job.offer": {"zh": "在码头打零工(+100 金,耗时 1 天)", "en": "Work an odd job at the docks (+100g, 1 day)"},
  "inn.odd_job.result": {"zh": "你帮工一天,挣得 100 金。", "en": "A day's labor on the docks earns you 100 gold."},
  "inn.odd_job.ineligible": {"zh": "赈济零工仅面向身无船只且穷困的旅人。", "en": "Relief work is only for the penniless without a ship."},
  "gameover.starvation": {"zh": "补给断绝,船队饿死在了海上。", "en": "Provisions gone — your fleet starved at sea."},
  "gameover.scurvy": {"zh": "淡水耗尽,坏血病夺走了整支船队。", "en": "The water ran out; scurvy took your fleet."},
  "gameover.sunk": {"zh": "旗舰沉没了,你也随之葬身大海。", "en": "Your flagship sank, and you went down with her."}
}
```

## 6. Edge Cases & Fail States

- **Missing `ui_strings` key at runtime** → renders the literal `<key>` and
  logs (bug path, `90-*` §5.3); validator prevents it in shipped data.
- **Toggle locale mid-dialog** → allowed; dialog rebinds text immediately via
  `locale_changed`.
- **Storm + mutiny + desertion same tick** → fixed dialog queue order
  (§4.7): weather damage, mutiny, desertion, arrival greeting.
- **Long strings overflow 480px dialog** → text wraps; dialog grows
  vertically to max 400px then scrolls.
- **Save during fractional day at sea** → impossible; save UI exists only in
  port (`20-*` §4.3).
- **Click-through dimmed background** → modals consume all input (Godot
  modal flag), no exceptions.
- **Minimap/chart with zero explored tiles after load** → only on a run that
  never sailed before saving; a save taken after sailing restores its
  explored set on load (explored-state amendment, 2026-11-02, `20-*`
  §4.12) — a fresh-run-shaped fog map after loading a sailed save is a bug.
- **A Phase-3 screen opened with no run** (editor) → renders `-` placeholders
  and every action is disabled, exactly as the Phase-1 facility screens do.
- **Palace ceremony while a locale toggle fires** → the ceremony dialog
  re-translates in place; the granted rank id is never localised at write
  time (it is stored as `rank.knight`-style id, resolved on display).
- **Ending screen reached from a retired load** → `ending.continue` returns
  to S1; it never restores the run.
- **Explore pressed at sea with nothing in range** → `world.explore.none`
  toast, no day cost.
- **Click-to-sail with no path** (target enclosed by land, or path budget
  exhausted) → `world.sail.no_path` toast; the fleet stays put, no clock cost.
- **Chart opened with zero explored tiles** (fresh run) → renders the port
  dots and fleet marker over the unexplored background, not a blank crash.
- **Chart open while a modal exists** → modals consume input; `Tab` does
  nothing while any modal is up.
- **Right-click on empty water or land** → a hard no-op: no picker, no
  menu, no toast (§4.10.1).
- **Picker on a multi-fleet tile** → the target is chosen first; `Esc`
  backs out of the picker with no order issued (§4.10.1).
- **Intimidate failure** → the hail modal closes, the target turns
  hostile and the `60-*` §4.11.11.2 battle opens through the normal
  funnel (§4.10.2).
- **`alloc_pending` across save/load** → the counter round-trips (save
  v9) and the badge persists; only a committed allocation spends it
  (§4.12.2) — a draft rolled back by `取消` restores the counter exactly.
- **Appointed voyage vs storm** → the voyage continues (auto-reef);
  only hostile contact or manual input cancels, each with its notice
  (§4.10.4).
- **Same captain, two entries** → the card renders identically from the
  picker and the dossier; any divergence is a bug (acceptance-pinned,
  §4.12.1).

## 7. Acceptance Criteria

- [ ] Every Phase-1 screen (S1–S9) exists and navigates only along §4.2; the
      S14/S15/S18 surfaces live on as the §4.5 intel window's tabs
      (amended 2026-11-03).
- [ ] Every Phase-3 screen (S12, S13, S16) exists and navigates only along
      §4.2; the guild/palace hubs open from S4's facility rows and Esc returns.
- [ ] S17 (Chart) opens with `Tab` from S3, closes with `Esc`/`Tab`, renders
      the whole 4320×2160 world downscaled in under 0.5 s, shows the explored
      overlay + known ports + fleet marker, and mutates no state.
- [ ] Input table §4.3 fully implemented; Esc always steps back.
- [ ] HUD bars (§4.5) show live values driven by `EventBus`, not polling the
      game state (the Phase-8 `alloc_pending` badge, §4.12.2, is the one
      sanctioned per-frame diff — a `process_frame` connection that touches
      the label only on change, no `_process` defined; amended 2026-11-03).
      scene tree.
- [ ] Locale toggle switches 100% of visible text on the current screen
      without a scene reload glitch (manual spot-check list in
      IMPLEMENT-Phase1).
- [ ] `ui_strings.json` passes the placeholder-match check (§4.4).
- [ ] Palette values used are exactly §4.8 constants (scene files reference
      a shared `palette.gd` constants script).
- [ ] Save slot dialog shows corrupted saves as invalid, never crashes.
- [ ] Phase 5 (amended 2026-10-31): S19 is reachable from **S1** (pre-game
      density; S2 has no density row) and **S4** (mid-run density + a
      confirm-first "return to main menu" that saves then routes to S1). S19
      writes `GameState.npc_preset`; applies the
      preset mid-run (raise refills via trickle, lower never culls,
      `deserted` = zero NPC spawns/contacts), and every string is zh/en.
- [ ] Phase 5: the market shows stock, trend and the marginal
      (next-tranche) price; world-map markers render nation-coloured
      squares, convoy groups, the wreck icon and 5-tile dashed wakes.
- [ ] Phase 5: captain sightings follow the seeded facility/presence rolls
      (stable within a visit-day, hunter palace-only), wanted posters
      appear within Chebyshev 40, and "buy a round — 20g" returns the
      exact live position as text.
- [ ] Phase 6: both input modes play end-to-end per §4.3 — Step
      (key-per-tile, `Space` = wait one day) and Helm (direction keys set
      the persisted heading, auto-sail, `Space` = stop-then-wait, `[`/`]`
      trim); the helm cancels on click-to-sail, battle and docking and
      **never** on `Esc`.
- [ ] Phase 6: the HUD shows every §4.5 Phase-6 indicator — wind arrow +
      strength label by the weather glyph, current arrow on a current
      tile, trim chip, and the `Year {y} · Month {m}` top-bar segment
      (zh `{y}年{m}月`).
- [ ] Phase 6: the chart layers `W`/`C`/`I` toggle, and the debug mode
      gates exactly on `SettingsPanel.debug_overlays` — row off ⇒ no
      debug layer reachable; row on ⇒ the full §4.6 debug list
      (omniscient, live ecology, network, scrubber, info strip) renders
      read-only and mutates nothing.
- [ ] Phase 6: zero `<key>` fallbacks zh/en for the §4.7.10 families
      (orchestrator merge complete).

**Phase-7 additions (trade empires).**

- [ ] Market rows follow the listing rule — unlisted goods never render;
      the ★ badge + 特产 header, 不收购 disabled sells, grayed exclusive
      rows with the lock note, the 4-state tax badge and both tax lines
      all render from §4.7.15's keys (zero `<key>` fallbacks zh/en).
- [ ] The Invest button renders its three states — available /
      allowance-exhausted with the hint / diplomacy-blocked — matching
      the §4.9 block-reason contract.
- [ ] Shipyard rows render the three §4.7.12 states: tier-gray 需发展度
      at an above-dev port, allegiance-gray 同盟专营 on every hull row at
      an unallied neutral (no empty state), role labels on every row;
      rare equipment never appears in any stock UI.
- [ ] The palace permit row plays purchase and void end-to-end for both
      kinds (5,000g home / 20,000g foreign, title/rep gates); the
      commendation dialog plays exactly once per converted port.
- [ ] Tavern telegraph rows of kind `"investment"` appear for the 30-day
      window, scoped to the invested port's band, and expire.
- [ ] Phase 7: zero `<key>` fallbacks zh/en for the §4.7.15 families
      (orchestrator merge complete).

**Phase-8 additions (the RPG overhaul, 2026-11-02).**

- [ ] Right-click: the picker renders exactly per §4.10.1 (coaster: no
      attack verb; empty water/land a no-op; multi-fleet pick first);
      left-click sail-to is unchanged; the hail modal opens only within
      Chebyshev 2 with role × stance × skills options.
- [ ] The port context menu docks or appoints; the appointed-voyage HUD
      bar shows destination / ETA / cancel, auto-cancels with a notice on
      hostile contact and never on storms.
- [ ] The same captain's card is identical from every entry (picker,
      captain's table, bounty row, hail modal, battle intro preview,
      dossier).
- [ ] Dossier familiarity gates only the career log at 3/6/10; card
      numbers never gated; stance ≥ +2 adds tier + status to the header.
- [ ] Allocation: level-up toast + persisted `alloc_pending` + badge;
      steppers → draft → confirm / cancel rollback; deferrable forever;
      skills never allocate.
- [ ] Officers panel: talk / gift / train / appoint with cooldowns and
      prereqs; the post column prereq-grays with its gate reason; S15
      shows the per-ship "captain: ___" rows.
- [ ] Creation S20: two steps, the live same-source derived preview,
      spread-evenly, must-spend-all; extremes attribute ≤ 21 / skill ≤ 13.
- [ ] Retirement RPG segment: nemesis top 3, deepest grudge, most loyal
      veteran (≥ 90 sea-days), background bio — all read-only.
- [ ] Phase 8: zero `<key>` fallbacks zh/en for the §4.15 families
      (orchestrator merge complete).
