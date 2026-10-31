# 80 — UI / UX

## 1. Purpose & Phase

Specifies the screen inventory and navigation graph, input scheme,
dialog/text conventions, the sailing HUD layout, the Chart screen (S17),
save/load UX, the `ui_strings.json` key inventory, and the placeholder-art
palette + sizing grid. Gates Phase 1 for the listed screens; Phase-2/3 screens
are named and marked; Phase 4 adds S17 (Chart).

## 2. Artifacts

| Path | Contents |
|---|---|
| `data/ui_strings.json` | every UI-frame L10nString, keyed (§4.4) |
| `scenes/ui_shared/dialog_box.tscn` | modal message dialog |
| `scenes/ui_shared/confirm_dialog.tscn` | modal yes/no dialog |
| `scenes/ui_shared/hud.tscn` | shared HUD (world + port) |
| `scenes/world/chart_screen.tscn` | full-screen Chart (S17, §4.6) |
| all `scenes/**` screens | per `90-*` §4 tree, content per docs 30/50 |
| Save UX | title-screen Load / port-side Save (§4.7) |

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
| S9 | Game over | `ui_shared/gameover_screen.tscn` (modal over S3) | 1 |
| S10 | Battle | `scenes/combat/battle_screen.tscn` | 2 |
| S11 | Duel | `scenes/combat/duel_modal.tscn` (modal over S10) | 2 |
| S12 | Guild | `guild_screen.tscn` | 3 |
| S13 | Palace | `palace_screen.tscn` | 3 |
| S14 | Character/status panel | `ui_shared/character_panel.tscn` (modal over S3/S4) | 1 |
| S15 | Fleet/cargo panel | `ui_shared/fleet_panel.tscn` (modal over S3/S4) | 1 |
| S16 | Ending / retirement | `ui_shared/ending_screen.tscn` (root scene, from S13) | 3 |
| S17 | Chart | `scenes/world/chart_screen.tscn` (full-screen whole-world chart, §4.6) | 4 |
| S18 | Officers | `scenes/port/officers_panel.tscn` (officer roster + details, §4.6.2) | 5 |

Save/load has no dedicated scene: S1 hosts Load; S4 hosts Save (§4.7).
The provisioning prompt (§4.6.1) is a **modal over S4**, not a screen of its
own, so it takes no S-number.

### 4.2 Navigation graph

```
S1 ──New Game──► S2 ──confirm──► S4
S1 ──Load──────► (slot dialog) ─► S3 or S4 (state-dependent)
S1 ──Load retired slot──► S16 (summary only)
S3 ──dock: head into shore tile──► S4
S4 ──Set Sail──► S3
S3 ──Tab──► S17 ──Esc/Tab──► S3
S4 ──facility──► S5/S6/S7/S8/S12/S13 ──Back/Esc──► S4
S4 ──Save──► (slot dialog)
S3/S4 ──Status──► S14 (modal)
S3/S4 ──Fleet──► S15 (modal; read-only at sea)
S3 ──hostile contact / attack──► S10 ──board──► S11 (modal) ──► S10
S10 ──battle ends──► S3 (after-action dialog first)
S13 ──Retire (Duke)──► S16 ──any key──► S1
S13 ──tournament entry──► S10 (3 bouts) ──won bout──► S13 ──last bout──► S13
S3 ──sea death / capture──► S9 ──any key──► S1
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
| S1/S2 | `L` | toggle locale zh/en; also an on-screen button `[ 中文 / EN ]` on every screen's top bar |
| S3 | arrows / numpad 1–9 | step one tile (8-directional per `20-*` §4.2); **hold to repeat** at ~8 tiles/s after a 0.25 s delay, each held step a normal move |
| S3 | left-click any visible water tile | **click-to-sail**: path there (A*, `20-*` §4.2) and walk it; a click on land/ice is rejected (`world.move_blocked`) |
| S3/S4 | `C` | open/close character panel (S14) |
| S3/S4 | `F` | open/close fleet/cargo panel (S15) |
| S3 | `Tab` | open the Chart (S17, §4.6) |
| S3 | `Esc` | close the Chart when it is open (otherwise no-op on S3) |
| dialogs | `Enter`/`Y` confirm, `N`/`Esc` cancel | confirm dialogs |
| lists | mouse wheel / ↑↓ + Enter | scroll & activate focused row |
| S10 | left-click tile / enemy token | move / default action |
| S10 | `Tab` | cycle own ships; arrows move the targeting cursor |
| S10 | `Enter` | confirm the highlighted move/action |
| S10 | `Esc` | battle menu (Retreat / Surrender / back) |
| S3 | right-click a hostile marker | attack it (navy = piracy, `70-*` §4.5) |
| S3 | `E` | Explore: find every discovery within Chebyshev 18, wrap-aware (`70-*` §4.4); no-op with a toast `world.explore.none` when nothing is in range |
| S17 | `Tab` / `Esc` | toggle back to S3 (the Chart never mutates state) |
| S12/S13 | `Esc` | back to S4 (same edge as Back) |
| S4 | `ESC` | opens the provisioning prompt (§4.6.1) — the same edge as Set Sail |
| S4 | `O` | open/close the officers panel (S18, §4.6.2) |
| provisioning | `Enter` | sail (disabled with a stated reason when gated, `20-*` §4.11.2) |
| provisioning | `Esc` | back to S4 without sailing |

Focus outline (2px accent border) always visible on keyboard-focused control.

### 4.4 `ui_strings.json` conventions

- Flat key → L10nString: `"market.buy": {"zh": "购买", "en": "Buy"}`.
- Key namespaces by screen: `title.*`, `nation.*`, `world.*`, `port.*`,
  `market.*`, `shipyard.*`, `tavern.*`, `inn.*`, `char.*`, `ui.*` (shared:
  `ui.back`, `ui.confirm`, `ui.cancel`, `ui.gold_abbr`…), `gameover.*`,
  `battle.*` (S10), `duel.*` (S11), `encounter.*` (hostile-fleet markers),
  `guild.*` (S12), `palace.*` (S13), `quest.*`, `rank.*` (nobility names),
  `bounty.*`, `tournament.*`, `discovery.*`, `ending.*` (S16),
  `chart.*` (S17), and the Phase-4 `world.*` sailing keys below.
- Event/system strings also live here (`world.mutiny.title`,
  `world.desertion`, `inn.odd_job.offer`, `world.ship_lost`…).
- Placeholders use `{name}` syntax, substituted by code:
  `"world.arrive": {"zh": "抵达 {port}。第 {day} 天。", "en": "Arrived at {port}. Day {day}."}`.
- The validator checks both locales non-empty and that zh/en placeholder sets
  match per key.
- Minimum Phase-1 inventory: every label in the wireframes of `30-*` §4.7,
  every event string referenced in `20/30/40/50`, plus this §'s shared keys.
  Exact list is assembled by the IMPLEMENT-Phase1 task that creates
  `ui_strings.json`; it must cover ≥ the keys cited across docs.

### 4.5 Sailing HUD (S3)

Layout (1280×720; tile viewport is the space below the top bar):

```
+------------------------------------------------------------------+
| Day 12   7,830g   Morale 72 (Good)   [里斯本 · Lisbon area] [中文/EN]  top bar 40px
+------------------------------------------------------------------+
| [minimap 256×192]                                   (viewport)   |
|  explored tiles only                                             |
|                                                                  |
|                               [fleet ship sprite placeholder]    |
+------------------------------------------------------------------+
| Provisions 45 · Water 45 · Crew 15/45 · Cargo 120/120 · Speed 8  | bottom bar 32px
+------------------------------------------------------------------+
```

- Top bar: day, gold, morale (value + tier label, tier-colored per `20-*`
  §4.8 — yellow < 40, red < 20), current area label (nearest known port
  within 16 tiles, else `world.open_sea`), language toggle.
- Bottom bar: provisions / water / crew / cargo / current effective speed —
  all live-updating via `EventBus` signals.
- Weather icon (placeholder glyph: sun/wind/storm text label) sits under the
  minimap; in storm it flashes (0.5s cycle).
- Camera: a `Camera2D` centers on the fleet marker every frame. **`x` wraps**
  (no clamp at the dateline; the seam shows no void) and `y` is clamped to the
  1080-tile height; zoom locked at 1.0. Only live chunks are drawn
  (`90-*` §9).
- Minimap: the 256×192 px box shows a **wrap-aware 128×96-tile crop** around
  the fleet at 2 px/tile, drawn from the explored bitset (`20-*` §4.12).
- The full world is the separate **Chart screen (S17, §4.6)**, opened with
  `Tab`.
- S4 (port) HUD: same top/bottom bars, viewport replaced by the port menu;
  the bar contents are identical so stats are always visible.

### 4.5.1 Fleet/cargo panel (S15)

Modal over S3/S4 (`ui_shared/fleet_panel.tscn`, 880px wide, 40% dim, `F` to
toggle). It is the fleet-management surface the fleet panel of `40-*` §4.4 and
the supplies jettison of `20-*` §4.10 refer to.

```
+----------------------------------------------------------------------+
| 舰队 / Fleet                    Day 12 · 7,830g · Morale 72 (Good)   | header
| 2/5 ships · Free 100 · Fleet is full (5 ships)                        |
| <at-sea banner, hidden in port>                                       |
+----------------------------------------------------------------------+
| Ship 1 · Caravel [Flagship]                                           |
| 耐久 Durability  [====------] 45/90     载重 Cargo 0/120 free         |
| 船员 Crew        15/45        火炮 Guns   6/6                         |
| 航速 Speed       10/12 tiles/day (wind: fair ×1.0)                    |
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
  3. speed `effective/base` in tiles/day with the wind factor that produced
     it (§4.4), so a becalmed or storm-lashed fleet explains itself;
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

### 4.6.1 Provisioning dialog (S4 → S3, Phase 5 polish)

Clicking **Set Sail** (`出航`) — or pressing `ESC` on S4, which is the same
edge (`§4.2`) — opens a provisioning prompt **before** the world map. This is
the only place supplies are bought; the market sells trade goods only
(`20-*` §4.10).

```
+--------------------------------------------------------------+
| 出航准备 / Prepare to Sail                                    |
| 里斯本 Lisbon · Day 12 · 7,830g                               |
+--------------------------------------------------------------+
| 船员 Crew        15 / 45                                      |
| 补给 Provisions  45  (15 days)   [- 10 +]  [Buy 10 — 20g]      |
| 淡水 Water       45  (15 days)   [- 10 +]  [Buy 10 — 10g]      |
| 货舱 Free        0 / 120                                      |
+--------------------------------------------------------------+
| 可航行天数 Days at sea: 15                                    |
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
- **Gate (locked, `20-*` §4.11.2):** `Set Sail` is disabled when there are no
  crew (`port.sail.no_crew`) or fewer than one day of supply
  (`port.sail.no_supply`), each stating its reason. `Stay in port` always
  works.
- `ESC` closes the prompt back to S4 (it does **not** sail) — the standard
  "Esc steps back one edge" rule (`§4.2`).

### 4.6.2 Officers panel (S18, Phase 5 polish)

A dedicated roster screen, opened from S4's facility list and from the
character panel (`C`) — the existing officer **summary** in S14's right column
stays as-is; this panel is the detail view.

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

- **Rows:** one per employed officer (`player.officers` → `data/officers.json`),
  sorted by `id`; name (L10n), `role` tag, the four stats, `wage_daily`, the
  **derived effect** each contributes (navigation → sighting radius,
  seamanship → speed bonus, leadership → mutiny/desertion, combat → battle /
  duel), the recruit port, and `Dismiss` (confirm dialog; frees the slot and
  stops the wage from the next day tick).
- **Header:** `n / 3` (`OFFICER_MAX`) and the total daily wage bill — the number
  that shows up in `20-*` §4.5 ledger step 2.
- **Empty state:** `char.no_officers` plus the tavern hint (`§4.4` is where
  they are hired).
- Read-only at sea (dismissal is a port action), same rule as S15.
- No textures; 32px rows (§4.8).

### 4.6 Chart screen (S17, Phase 4)

Full-screen panel over S3 (`scenes/world/chart_screen.tscn`); it **never
mutates state** — a pure view of the session.

```
+------------------------------------------------------------------+
| 海图 / Chart                                        [关闭海图]     | top 40px
+------------------------------------------------------------------+
|  whole world 2160×1080 downscaled to fit (≈0.55× at 1280×720)     |
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
  the session explored bitset (`PackedByteArray`, `20-*` §4.12), known ports
  as nation-coloured dots with names shown at zoom, discovery hint icons, the
  fleet marker.
- **Scale:** whole 2160×1080 grid downscaled to fit the viewport (scale
  ≈ 0.55× at 1280×720); no scrolling, no per-region tabs. Dateline handling is
  implicit in a full-world image (no seam crop).
- **Input:** `Tab` toggles, `Esc` closes (`§4.3`); the panel owns all input
  while open. Closing returns to S3 with the fleet unmoved and the clock
  untouched.
- **Budget:** open (build + first frame) **< 0.5 s**.
- **Strings:** every label from `chart.*` (§4.7.5).
- **Not saved:** explored state and the chart itself are session-only (Phase-1
  known limitation, unchanged).

### 4.7 Save / load UX

- **Save:** available only at port (S4 menu row + F5). Slot dialog lists 3
  slots with summary line (`Day · Nation · gold · timestamp`) or `Empty`.
  Choosing a non-empty slot asks to confirm overwrite. After write: toast
  `ui.saved` + `EventBus.save_completed`.
- **Load:** title-screen Load (always) + F9 quick-load slot 1 (with confirm).
  Loading routes to S4 if `current_port` set, else S3.
- No autosave.
- **Save version:** current format is **version 4** (`90-*` §8.2); loading a v1,
  v2 or v3 save migrates it forward (`MIGRATIONS[1..3]`).
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

**S12 `guild_screen.tscn`** (wireframe: `30-*` §4.7 "Guild"). Two stacked
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

**S13 `palace_screen.tscn`** (wireframe: `30-*` §4.7 "Palace"). Rows, top to
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

**S16 `ending_screen.tscn`** (root scene, not a modal): dimmed background, a
centered panel with `ending.title`, the six summary rows of `70-*` §4.7, and
one button `ending.continue` → S1. In `retired` load mode the panel title is
`ending.retired_title` and no Continue route back into play exists.

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
| `fleet.ship_header` | 舰队 | Fleet |
| `fleet.stat.durability` | 耐久 {current}/{max} | Durability {current}/{max} |
| `fleet.stat.cargo` | 载重 {used}/{capacity}(剩余 {free}) | Cargo {used}/{capacity} ({free} free) |
| `fleet.stat.crew` | 船员 {crew}/{max} | Crew {crew}/{max} |
| `fleet.stat.guns` | 火炮 {cannons}/{slots} | Guns {cannons}/{slots} |
| `fleet.stat.speed` | 航速 {speed}/{max} 格/日(风:{wind}) | Speed {speed}/{max} tiles/day (wind: {wind}) |
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
- **Minimap with zero explored tiles after load** → expected (Phase-1 known
  limitation, `20-*` §4.12), not a bug.
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

## 7. Acceptance Criteria

- [ ] Every Phase-1 screen (S1–S9, S14) exists and navigates only along §4.2.
- [ ] Every Phase-3 screen (S12, S13, S16) exists and navigates only along
      §4.2; the guild/palace hubs open from S4's facility rows and Esc returns.
- [ ] S17 (Chart) opens with `Tab` from S3, closes with `Esc`/`Tab`, renders
      the whole 2160×1080 world downscaled in under 0.5 s, shows the explored
      overlay + known ports + fleet marker, and mutates no state.
- [ ] Input table §4.3 fully implemented; Esc always steps back.
- [ ] HUD bars (§4.5) show live values driven by `EventBus`, not polling the
      scene tree.
- [ ] Locale toggle switches 100% of visible text on the current screen
      without a scene reload glitch (manual spot-check list in
      IMPLEMENT-Phase1).
- [ ] `ui_strings.json` passes the placeholder-match check (§4.4).
- [ ] Palette values used are exactly §4.8 constants (scene files reference
      a shared `palette.gd` constants script).
- [ ] Save slot dialog shows corrupted saves as invalid, never crashes.
