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
(§4.7.11–§4.7.15) — and pins the W3/W4 symbol contracts (§4.9). Phase 8
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
| S14 | Character/status panel | `ui_shared/character_panel.tscn` (modal over S3/S4) | 1 |
| S15 | Fleet/cargo panel | `ui_shared/fleet_panel.tscn` (modal over S3/S4) | 1 |
| S16 | Ending / retirement | `ui_shared/ending_screen.tscn` (root scene, from S13) | 3 |
| S17 | Chart | `scenes/world/chart_screen.tscn` (full-screen whole-world chart, §4.6) | 4 |
| S18 | Officers | `scenes/port/officers_panel.tscn` (officer roster + details, §4.6.2) | 5 |
| S19 | Settings | `scenes/ui_shared/settings_panel.tscn` (modal over **S1 and S4**: the sea-traffic density dial + return-to-menu action, §4.6.3) | 5 |
| S20 | Creation (出身 + 自由点数) | `scenes/title/creation_screen.tscn` (two-step flow, §4.13) | 8 |

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
S3/S4 ──Status──► S14 (modal)
S3/S4 ──Fleet──► S15 (modal; read-only at sea)
S4 ──Officers──► S18 (modal; read-only at sea)
S1 ──Settings──► S19 (modal; pre-game density dial, §4.6.3) ──Esc/Close──► S1
S4 ──Settings──► S19 (modal; density dial + return-to-menu, §4.6.3) ──Esc──► S4
S3 ──hostile contact / attack──► S10 ──board──► S11 (modal) ──► S10
S10 ──battle ends──► S3 (after-action dialog first)
S13 ──Retire (Duke)──► S16 ──any key──► S1
S13 ──tournament entry──► S10 (3 bouts) ──won bout──► S13 ──last bout──► S13
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
there and the palace starts the next bout (`70-*` §4.9.7).

### 4.3 Input scheme (keyboard + mouse)

| Context | Keys | Action |
|---|---|---|
| Any | `Esc` | back / close modal; on S1: no-op |
| Any | `F5` | quick-save (allowed only in port; elsewhere shows toast `ui.cant_save_here`) |
| Any | `F9` | quick-load to slot 1 (confirm dialog) |
| S3 | arrows / numpad 1–9 | **Step mode:** step one tile (8-directional per `20-*` §4.2); **hold to repeat** at ~8 tiles/s after a 0.25 s delay, each held step a normal move. **Helm mode:** set the helm heading (persisted `world.heading`); the fleet then auto-sails that heading per `20-*` §4.2 — a new direction key re-steers |
| S3 | `Space` | **Step mode:** wait one day at sea — the full daily ledger (`advance_clock(1.0)`: provisions, wages, weather reroll, morale; `20-*` §4.17). **Helm mode:** stop the fleet; pressed again while stopped, wait one day |
| S3 | `[` / `]` | cycle sail trim `furled → reefed → normal → full` (persisted `world.sail_trim`; speed/storm-damage effects per `20-*` §4.17) |
| S3 | left-click any visible water tile | **click-to-sail**: path there (A*, `20-*` §4.2) and walk it; a click on land/ice is rejected (`world.move_blocked`); cancels Helm mode |
| S3/S4 | `C` | open/close character panel (S14) |
| S3/S4 | `F` | open/close fleet/cargo panel (S15) |
| S3/S4 | `Tab` | open the Chart (S17, §4.6) — from the port hub too (amended 2026-11-01) |
| S3 | `Esc` | close the Chart when it is open (otherwise no-op on S3) |
| dialogs | `Enter`/`Y` confirm, `N`/`Esc` cancel | confirm dialogs |
| lists | mouse wheel / ↑↓ + Enter | scroll & activate focused row |
| S10 | left-click tile / enemy token | move / default action |
| S10 | `Tab` | cycle own ships; arrows move the targeting cursor |
| S10 | `Enter` | confirm the highlighted move/action |
| S10 | `Esc` | battle menu (Retreat / Surrender / back) |
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
| S4 | `O` | open/close the officers panel (S18, §4.6.2) |
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
  plus the personality/appearance part keys (§4.15).
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

Layout (1280×720; tile viewport is the space below the top bar):

```
+------------------------------------------------------------------+
| Day 12 08:30 · Year 1 · Month 1   7,830g   Morale 72 (Good)   [里斯本 · Lisbon area]  top bar 40px
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

### 4.5.1 Fleet/cargo panel (S15)

Modal over S3/S4 (`ui_shared/fleet_panel.tscn`, 880px wide, 40% dim, `F` to
toggle). It is the fleet-management surface the fleet panel of `40-*` §4.4 and
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

### 4.6.2 Officers panel (S18, Phase 5 polish)

A dedicated roster screen, opened from **S4's footer, beside the Fleet button**
(and from the character panel, `C`) — the Phase-5 officer **summary** in S14's
right column is, since Phase 8 (2026-11-02), the 官员与岗位 tab (§4.12.3);
this panel is the detail view.

**Entry point (locked):** S18 is a **modal over S4**, like S15, so it belongs
with the footer modal buttons (`Save · Set Sail · Fleet · Officers`), **not** in
the facility list. The facility column is reserved for rows that leave S4 for
another screen (`§4.2`); a full-width roster row dangling under 公会/王宫 read
as a seventh facility and was removed.

```
+--------------------------------------------------------------+
| 官员 / Officers           3 / 3 · wages 88g/day   [Close]     |
+--------------------------------------------------------------+
| 马特乌斯·阿尔瓦雷斯  Mateus Álvares        [领航员 Navigator]  |
|   统率 10  航海术 14  战斗 6  导航 16      日薪 30g            |
|   效果: 侦察半径 +0 · 航行加成 +0%                             |
|   雇佣于: 里斯本         [解雇 Dismiss]                       |
+--------------------------------------------------------------+
| 迭戈·费尔南德斯  Diego Fernández         [水手长 Boatswain]   |
| ...                                                          |
+--------------------------------------------------------------+
| 空位 3/3 · 在酒馆招募新官员                                    |
+--------------------------------------------------------------+
```

(Phase-5 wireframe kept for layout reference — Phase 8 replaces the
per-officer stat line with the §4.12 card bars and adds the post column
and the four action buttons.)

- **Rows (Phase 8, amended 2026-11-02):** one per employed officer
  (`player.officers` → the officer roster, `50-*`), rendered with the
  §4.12 character-card component — the Person model's attribute/skill
  bars, the **native role** tag, the **post column** (current post, or
  idle; a prereq-failing post renders prereq-gray + its `gate.*` reason),
  loyalty, `wage_daily`, the recruit port — plus the **four actions**
  talk / gift / train / appoint (`50-*` formulas; §4.12.3) and
  `Dismiss` (confirm dialog; frees the slot and stops the wage from the
  next day tick). The Phase-5 four-stat line (统率/航海术/战斗/导航) and
  its derived-effect text are retired with the old model.
- **Header:** `n / OFFICER_MAX` (**12** since Phase 8, `50-*`; the
  Phase-5 cap was 3) and the total daily wage bill — the number
  that shows up in `20-*` §4.5 ledger step 2.
- **Port/sea availability (Phase 8):** `appoint` and `Dismiss` are port
  actions (fleet composition changes dock-side, the §4.5.1 promotion
  rule); `talk` / `gift` / `train` work anywhere, each with its own
  cooldown shown on the row.
- **Empty state:** `char.no_officers` plus the tavern hint (`§4.4` is where
  they are hired).
- **At sea (Phase 8):** `appoint` / `Dismiss` are disabled at sea with
  their reason (port actions, the §4.5.1 promotion rule); the
  talk / gift / train rows stay usable.
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
(mid-run, beside `Save · Set Sail · Fleet · Officers`, §4.6.2's entry-point
rule). One panel, two mounts.

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
  footer keeps `Set Sail · Fleet · Officers · Settings`; the per-screen
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
|  whole world 4320×2160 downscaled to fit (≈0.30× at 1280×720)     |
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
  ≈ 0.30× at 1280×720); no scrolling, no per-region tabs. Dateline handling is
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

#### 4.7.1 S10 battle screen (Phase 2)

Layout, 1280×720, placeholder shapes only (§4.8 palette):

```
+------------------------------------------------------------------+
| Battle · Day 12 · Round 3        [weather]      [Esc: menu]       | top 40px
+------------------------------------------------------------------+
| battle grid 16×10 tiles at 48px = 768×480, centered               |
|  ship tokens: 24×24 squares with a letter (§4.8)                  |
|  highlight: reachable tiles (ACCENT outline), target tiles (BAD)  |
+------------------------------------------------------------------+
| flagship: durability bar · crew · cannons · reload state           | bottom 96px
| [Cannon] [Ram] [Board] [Hold] [Retreat] [Surrender]   action menu  |
+------------------------------------------------------------------+
```

- **Input:** mouse click a highlighted tile = move; click an enemy token in
  range = the default action against it (cannon if loaded, else ram/board);
  the action buttons act on the selected target. Keyboard: `Tab` cycles own
  ships, arrows move the cursor, `Enter` confirms, `Esc` opens the battle menu
  (Retreat / Surrender / back). All buttons carry `battle.*` keys.
- **Presentation:** every action appends one log line (bottom panel, last 3
  lines visible); no animation is required in Phase 2. Tokens are
  `ColorRect`s; player ships `TEXT` white, pirate `BAD` red, navy the owning
  nation's `Nation.color` (§4.8).
- **Duel modal (S11):** `duel_modal.tscn` is instanced over S10 by the
  boarding action; it shows both sides' rolls per round (three rows max) and
  closes with `duel.*` result text. It owns all input while open.
- **Captain intro preview (Phase 8):** the battle opens with a one-card
  preview of the opposing flagship captain's §4.12 character card
  (identified = full reveal), dismissed with any input before the first
  round.
- **After-action:** a `dialog_box`-style modal lists loot gold, captured
  ships, XP and reputation deltas, then returns to S3 (`60-*` §4.11.10).

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

**Character panel `Quests` tab (S14, Phase 3).** A third tab after the stats
column shows `char.quests`: one row per active quest with type tag, objective,
destination (`quest.dest`, always naming the port even if unknown), days left
(`quest.days_left`), and a `quest.abandon` button that fails it (same −5 rep
path). Above the rows: `quest.slots` = `n / max` (max 3, or 4 at viscount,
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
| 葡萄酒    | 87         | ▲ 回升     | 1,020‰ → 96g    | 30   | [买] [卖] |
+------------------------------------------------------------------------+
```

- **Stock** — the port-good's current stock, `0 … 200`, hard-clamped
  (`30-*` §4.2).
- **Trend** — a one-glyph drift arrow (▲ refilling in `GOOD`, ▼ draining in
  `BAD`) derived from recent stock deltas; no forecast is shown.
- **Marginal price** — the **marginal (next-tranche) price** (`30-*` §4.4):
  buying and selling reprice per 10-unit tranche, and the column always
  shows the price the *next* tranche would trade at, never the average; the
  ledger sums tranches exactly.
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
  ★ badge (`market.specialty.badge`); a header line above the table names
  **up to 3** of them (`market.specialty.header`, `特产:{names}`).
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

### 4.7 Dialog & text conventions

- All dialogs are modal instances of `dialog_box.tscn` (message + OK) or
  `confirm_dialog.tscn` (message + confirm/cancel), centered, dimming the
  background by 40% black.
- One action per dialog; chained events queue (storm damage → desertion →
  greeting shows 3 dialogs in fixed order, never simultaneously).
- Numeric entry fields: digits only, live-clamped to the valid range, empty =
  invalid (dependent buttons disabled).
- Toasts: transient (2.5s), bottom-center, max 1 visible (new replaces old).
- Text speed: instant (no typewriter effect in Phase 1).

### 4.8 Placeholder art & palette

- Everything is `ColorRect`/`Polygon2D`/`Label` with default Godot font; the
  **only** textures allowed in Phase 1 are none (no imports).
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

- Sizing grid: 8px base unit; margins 16px; button height 40px; bar heights
  40/32px (§4.5); table row height 32px; dialog width 480px.
- Ship/tokens: colored 24×24 squares with a letter; player fleet white square
  with black outline.
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

### 4.9 W3/W4 symbol contracts (Phase 7 — the launch condition)

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
- **Stance ≥ +2** adds the captain's current tier + status (在航 at sea /
  归队中 returning) to the panel header.
- **Bounty board links to dossiers:** every palace bounty row gains an
  open-dossier action.
- Strings: `dossier.*` (§4.15).

### 4.12 The unified character card, allocation & the S14 rework

#### 4.12.1 `scenes/ui/character_card.tscn` (locked layout)

One scene renders **any** Person — player, officer, NPC captain — with an
identical structure from every entry:

- **Portrait:** a color block composed from the appearance tags
  (`{face, beard, eyes, …}` — §4.8 palette, placeholder-first).
- **Identity row:** name / flag color block / role / tier badge / level.
- **Five attribute bars** (体魄 / 悟性 / 魅力 / 胆识 / 运气, 1–100) and
  **skill bars** for the Person's skills — the signature skill
  highlighted, a 0-value skill grayed as unlearned.
- **Personality tags** and the **appearance sentence** assembled from the
  part keys (`char.personality.*`, `char.appearance.*`, §4.15).
- **Relation block:** officer = loyalty + native role / current post;
  NPC captain = stance + familiarity.
- **Career block:** player = XP / level; NPC captain = wins / defeats /
  return day.
- **Player-card extra — the effective-values split:** base value +
  officer contribution + the native +5, with the "without this officer"
  diff (`50-*`; the successor of S18's pre-Phase-8 derived-effect line).

**IDENTIFY = FULL REVEAL (locked):** an identified NPC captain's card
shows every number; familiarity gates only the dossier career log
(§4.11.3). **The same captain's card is identical from every entry**
(picker inspect, captain's-table row, bounty row, hail modal, battle
intro preview) — acceptance-pinned.

**Entries (locked set):** panel header (player); officer row / tavern
recruit dialog (officers); picker inspect / captain's-table row / bounty
row / hail modal / battle intro preview (NPC — §4.7.1).

#### 4.12.2 Allocation UX (level-up points, locked flow)

`award_xp` detects the level-up → toast `char.level_up` +
`alloc_pending += 2` (**persisted**, save v9) → a badge on the character
button (`char.points_pending`). The player allocates on **their own
card's attribute tab** at leisure:

- per-attribute `+` stepper (enabled iff `alloc_pending > 0`) → the rows
  enter the **draft** → `确认` commits / `取消` rolls the draft back;
- a single attribute clamps at 1–100; **no second confirm dialog**;
- **skills never allocate** (usage growth + paid training only, `50-*`);
- points are **deferrable forever** — the badge persists until spent.

#### 4.12.3 Character panel (S14) three tabs + the appointment flow

The person side of S14 reorganizes into **three tabs** (Phase 8):

| Tab | Shows |
|---|---|
| **属性 Attributes** | the five attribute bars, level / XP, the §4.12.2 allocation steppers, and the player's **effective-values split** |
| **技能 Skills + gates** | the eight skill bars with their usage counters, and every locked feature rendered from `data/skill_gates.json` — the one `gate.*` reason renderer (grayed row + threshold + reason) shared by the whole UI |
| **官员与岗位 Officers & posts** | the officer roster (the §4.6.2 rows with their four actions) and the post table |

The Phase-3 委托 Quests tab is unchanged and keeps its place beside the
three person tabs.

**Officer actions (S18 rows; formulas `50-*`):** `talk` (loyalty +1,
10-day cooldown), `gift` (200g → loyalty +5; +8 贪婪 / +3 忠厚, 10-day
cooldown), `train` (the paid-training formula), `appoint` (the post
table). The **post column** renders prereq-gray + reason through the
same data-driven gates renderer (`officer_posts.json` prereqs ship their
`gate.*` reasons in the `skill_gates.json` shape). `appoint` / `Dismiss`
are port actions; `talk` / `gift` / `train` work anywhere (§4.6.2).

**Fleet-panel captain rows (S15):** every non-flagship ship row gains a
**"captain: ___"** line naming its appointed captain (or the
`officer.post.no_captain` state — the captain-less penalties of `40-*` /
`50-*` apply), with the appoint shortcut into the S18 post table.

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

- [ ] Every Phase-1 screen (S1–S9, S14) exists and navigates only along §4.2.
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
