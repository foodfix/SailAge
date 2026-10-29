# 80 — UI / UX

## 1. Purpose & Phase

Specifies the screen inventory and navigation graph, input scheme,
dialog/text conventions, the sailing HUD layout, save/load UX, the
`ui_strings.json` key inventory, and the placeholder-art palette + sizing
grid. Gates Phase 1 for the listed screens; Phase-2/3 screens are named and
marked.

## 2. Artifacts

| Path | Contents |
|---|---|
| `data/ui_strings.json` | every UI-frame L10nString, keyed (§4.4) |
| `scenes/ui_shared/dialog_box.tscn` | modal message dialog |
| `scenes/ui_shared/confirm_dialog.tscn` | modal yes/no dialog |
| `scenes/ui_shared/hud.tscn` | shared HUD (world + port) |
| all `scenes/**` screens | per `90-*` §4 tree, content per docs 30/50 |
| Save UX | title-screen Load / port-side Save (§4.6) |

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
| S11 | Duel | (modal over S10) | 2 |
| S12 | Guild | `guild_screen.tscn` | 3 |
| S13 | Palace | `palace_screen.tscn` | 3 |
| S14 | Character/status panel | `ui_shared/character_panel.tscn` (modal over S3/S4) | 1 |
| S15 | Fleet/cargo panel | `ui_shared/fleet_panel.tscn` (modal over S3/S4) | 1 |

Save/load has no dedicated scene: S1 hosts Load; S4 hosts Save (§4.6).

### 4.2 Navigation graph

```
S1 ──New Game──► S2 ──confirm──► S4
S1 ──Load──────► (slot dialog) ─► S3 or S4 (state-dependent)
S3 ──enter harbor tile──► S4
S4 ──Set Sail──► S3
S4 ──facility──► S5/S6/S7/S8 ──Back/Esc──► S4
S4 ──Save──► (slot dialog)
S3/S4 ──Status──► S14 (modal)
S3/S4 ──Fleet──► S15 (modal; read-only at sea)
S3 ──sea death──► S9 ──any key──► S1
S1 ──Quit──► exit
```

No cross-links beyond these; Esc = step back one edge where applicable.

### 4.3 Input scheme (keyboard + mouse)

| Context | Keys | Action |
|---|---|---|
| Any | `Esc` | back / close modal; on S1: no-op |
| Any | `F5` | quick-save (allowed only in port; elsewhere shows toast `ui.cant_save_here`) |
| Any | `F9` | quick-load to slot 1 (confirm dialog) |
| S1/S2 | `L` | toggle locale zh/en; also an on-screen button `[ 中文 / EN ]` on every screen's top bar |
| S3 | arrows / numpad 1–9 | step one tile (8-directional per `20-*` §4.2) |
| S3 | left-click adjacent tile | step there if legal |
| S3/S4 | `C` | open/close character panel (S14) |
| S3/S4 | `F` | open/close fleet/cargo panel (S15) |
| S3 | `M` | toggle minimap enlarged mode (512×384, centered) |
| dialogs | `Enter`/`Y` confirm, `N`/`Esc` cancel | confirm dialogs |
| lists | mouse wheel / ↑↓ + Enter | scroll & activate focused row |

Focus outline (2px accent border) always visible on keyboard-focused control.

### 4.4 `ui_strings.json` conventions

- Flat key → L10nString: `"market.buy": {"zh": "购买", "en": "Buy"}`.
- Key namespaces by screen: `title.*`, `nation.*`, `world.*`, `port.*`,
  `market.*`, `shipyard.*`, `tavern.*`, `inn.*`, `char.*`, `ui.*` (shared:
  `ui.back`, `ui.confirm`, `ui.cancel`, `ui.gold_abbr`…), `gameover.*`.
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
| Provisions 45 · Water 45 · Crew 15/45 · Cargo 120/120 · Speed 5  | bottom bar 32px
+------------------------------------------------------------------+
```

- Top bar: day, gold, morale (value + tier label, tier-colored per `20-*`
  §4.8 — yellow < 40, red < 20), current area label (nearest known port
  within 16 tiles, else `world.open_sea`), language toggle.
- Bottom bar: provisions / water / crew / cargo / current effective speed —
  all live-updating via `EventBus` signals.
- Weather icon (placeholder glyph: sun/wind/storm text label) sits under the
  minimap; in storm it flashes (0.5s cycle).
- Camera: a `Camera2D` centers on the fleet marker every frame and is clamped
  to the map bounds (no void shown past the 128×96 grid); zoom locked at 1.0
  in Phase 1.
- S4 (port) HUD: same top/bottom bars, viewport replaced by the port menu;
  the bar contents are identical so stats are always visible.

### 4.5.1 Fleet/cargo panel (S15)

Modal over S3/S4 (`ui_shared/fleet_panel.tscn`, 880px wide, 40% dim, `F` to
toggle). It is the fleet-management surface the fleet panel of `40-*` §4.4 and
the supplies jettison of `20-*` §4.10 refer to.

```
+--------------------------------------------------------------+
| Fleet                                                        |
| 2/5 · Free 100 · Fleet is full (5 ships)                     | header
| <at-sea banner, hidden in port>                              |
+--------------------------------------------------------------+
| Ship 1 · Caravel [Flagship]                                  |
| [====------] Durability 45/90   Crew 15/45        Free 0     |
| Provisions 45 [Jettison]   Water 45 [Jettison]               |
| Wine × 30 [Jettison]                                         |
| Ship 2 · Nao                       [Make flagship]           |
| ...                                                          |
+--------------------------------------------------------------+
| Esc to go back                                     [Close]  |
+--------------------------------------------------------------+
```

- Header: fleet count `n/5`, pooled `fleet_free`, `fleet.full` at the cap.
- Per ship row: data-driven ship-type name, flagship tag on row 1, durability
  bar (tier-coloured, same thresholds as S6), crew `crew/crew_max`, per-ship
  free capacity, then one line per stack — provisions, water, and each trade
  good — with its own `Jettison` button.
- Promote sits on non-flagship rows only (§4.4: free, port-only,
  order-preserving). Jettison drops the **whole** stack after a `ui.confirm`
  dialog (destructive action, §4.7) and frees capacity immediately.
- At sea the panel is **read-only**: every action is disabled and states its
  reason, because promotion and jettison are port actions.
- Rows are 32px table rows (§4.8); no textures.

### 4.6 Save / load UX

- **Save:** available only at port (S4 menu row + F5). Slot dialog lists 3
  slots with summary line (`Day · Nation · gold · timestamp`) or `Empty`.
  Choosing a non-empty slot asks to confirm overwrite. After write: toast
  `ui.saved` + `EventBus.save_completed`.
- **Load:** title-screen Load (always) + F9 quick-load slot 1 (with confirm).
  Loading routes to S4 if `current_port` set, else S3.
- No autosave in Phase 1.
- Version-mismatch or corrupt file → slot line shows `ui.save.invalid` and is
  not selectable (`90-*` §8.2).

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

## 7. Acceptance Criteria

- [ ] Every Phase-1 screen (S1–S9, S14) exists and navigates only along §4.2.
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
