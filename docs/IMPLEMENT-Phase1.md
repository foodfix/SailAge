# IMPLEMENT — Phase 1: Sail & Trade

Ordered, checkable task backlog. Execute as background-subagent waves per the
plan at the bottom (max 4 concurrent; top-to-bottom order is the dependency
order); each task lists the docs it draws from, the artifacts it creates, and
executable "done-when" criteria. Design questions raised by any task must be
answered in the owning system doc **before** the task proceeds (rule from
`00-OVERVIEW.md` §13).

Definition of done for the phase: **T19 (demo-loop acceptance) passes.**

---

## T1 — Godot project scaffold

- **Goal:** runnable empty Godot 4 project matching the architecture doc.
- **Docs:** `90-ARCHITECTURE.md` §4–6; `80-UI-UX.md` §4.8 (palette script).
- **Creates:** `project.godot` (settings per `90-*` §6), the full §4 directory
  tree, empty `autoload/*.gd` scripts registered in order, `scripts/palette.gd`
  with the §4.8 hex constants, and a minimal `title_screen.tscn` showing the
  game title (so the project runs).
- **Done-when:** project opens in Godot 4.x and runs to a title screen
  1280×720; autoload order in `project.godot` is exactly EventBus, DataLoader,
  I18n, GameState, SaveSystem; no other autoloads.

## T2 — Core data files + validator

- **Goal:** all Phase-1 data authored and machine-checked.
- **Docs:** `10-DATA-SCHEMA.md` (all of §§3–8).
- **Creates:** `data/nations.json` (6), `data/goods.json` (20),
  `data/ship_types.json` (8), `data/ports.json` (30, incl. flavor lines),
  `data/officers.json` (6), empty `data/discoveries.json`,
  `data/quests.json`, `data/equipment.json`, and `tools/validate_data.py`
  implementing check groups 1–5 (group 6 lands with T3).
- **Done-when:** `python3 tools/validate_data.py` exits 0; every id/count
  matches §7 tables exactly; deliberately breaking a reference (temp copy)
  produces the correct exit code.

## T3 — ASCII world map + legend

- **Goal:** the Phase-1 world authored as text and machine-verified.
- **Docs:** `10-*` §6, §7.1, §8 (group 6).
- **Creates:** `data/map_legend.json` (exactly the §4.9 content),
  `data/maps/p1_mediterranean.txt` (96×128, every §7.1 port marker at its exact
  `position`, coastlines plausible for the listed seas; Gibraltar and the
  English Channel open; no landlocked sea pockets containing a port).
- **Done-when:** validator group 6 passes, *specifically* the BFS check that
  all 30 markers are sea-reachable from Lisbon's tile (8-directional,
  passability per legend); each marker has an adjacent `#`.

## T4 — DataLoader, I18n, EventBus, ui_strings skeleton

- **Goal:** data is queryable at runtime; all UI text source exists.
- **Docs:** `90-*` §5.1–5.3; `80-*` §4.4.
- **Creates:** `autoload/data_loader.gd`, `autoload/i18n.gd`,
  `autoload/event_bus.gd` (signal set exactly per `90-*` §5.1),
  `data/ui_strings.json` covering every key cited in docs 20/30/40/50/80
  (build the list by grepping for keys).
- **Done-when:** startup loads all data into `DataLoader.ports` etc.;
  `I18n.t_key("market.buy")` returns both locales after toggling; validator
  exit-2 passes on `ui_strings.json` (placeholder sets match); a missing key
  renders `<key>` and logs.

## T5 — Map loader: ASCII → TileMap

- **Goal:** the world renders from data files.
- **Docs:** `90-*` §9; `10-*` §6; `80-*` §4.8 (palette).
- **Creates:** `scripts/world/map_loader.gd`, `scenes/world/world_map.tscn` with
  a TileMap (layers 0 terrain / 1 ports) and Camera2D (behavior `80-*` §4.5).
- **Done-when:** running the scene renders the 128×96 map with correct tile
  colors per legend and all 30 port markers (nation-colored square + name
  initial); `is_passable` answers correctly for all 4 tile kinds + markers;
  swapping in a test map file (valid per legend) requires zero code edits.

## T6 — World scene: movement, camera, HUD shell

- **Goal:** the fleet steps around the grid.
- **Docs:** `20-*` §4.1–4.2; `80-*` §4.3, §4.5; `90-*` §7.
- **Creates:** fleet marker on `world_map.tscn`, movement input handling
  (keys + click-to-step, no corner cutting), camera follow+clamp, `hud.tscn`
  with top/bottom bars bound to GameState/EventBus, `ui_shared/dialog_box.tscn`
  and `confirm_dialog.tscn`.
- **Done-when:** manual + scripted moves: 8-dir stepping works; land/reef
  block; diagonal corner-cut attempts are rejected at zero clock cost; camera
  never shows out-of-bounds void; HUD bars update from signal emissions only.

## T7 — Sailing sim: clock, ledger core, speed

- **Goal:** time passes; ships eat; crews are paid.
- **Docs:** `20-*` §4.3–4.6, §4.10, §5; `40-*` §4.2; `50-*` §4.5 (officer
  wages).
- **Creates:** `scripts/world/sailing_sim.gd` (constants §5 at top),
  fractional clock on `GameState.world`, ledger steps 1–2, effective-speed
  pipeline incl. crew factor and seamanship bonus, market-side supply
  carry-over is out of scope here (see T12).
- **Done-when:** unit checks from docs: 15-crew caravel burns exactly 3+3
  units/day; wages = crew×2 + Σ officer wages; the `20-*` §4.4 formula passes
  tabled cases (storm-wind sail 1.5×; skeleton crew factor 0.25 floor; speed
  floor 1); `day_advanced` fires once per integer boundary.

## T8 — Weather & storms

- **Goal:** weather exists, storms hurt, Atlantic strip is dangerous.
- **Docs:** `20-*` §4.7; `50-*` §4.2 (luck); `80-*` §4.5 (icon).
- **Creates:** weather roll at ledger step 3, zone table, wind factors by
  class, storm damage + luck mitigation, HUD weather display.
- **Done-when:** seeded-random test: 10,000 rolls at x≤6 produce storm
  frequency 0.5±0.02; storm day applies `ceil(0.05×max)×(0.75 if luck≥50)`
  damage; west of Lisbon (x≤6) a storm occurs within 6 in-game days with
  probability ≥ 0.98 (equivalently ≥ 0.96 within 5 days) — the original
  "≥ 0.97 in 5 days" figure is arithmetically unreachable and is superseded
  by `20-*` §4.7 "Reachability acceptance" (scripted check).

## T9 — Morale, desertion, mutiny, fail states, game over

- **Goal:** the sea can kill the player through crew systems.
- **Docs:** `20-*` §4.8–4.9; `80-*` §4.7 (dialog queue) — creates
  `ui_shared/gameover_screen.tscn`; strings in `ui_strings.json`.
- **Creates:** ledger steps 4–6, morale tiers + HUD colors, desertion on port
  entry, mutiny modal (pay/suppress), starvation/scurvy/sinking paths to
  `EventBus.game_over(reason)`.
- **Done-when:** scripted scenarios: provisions 0 → 7th day game over
  `starvation` (and mirror for water → `scurvy`); morale forced to 10 →
  mutiny within 5 days at ≥ 76% probability (1 − 0.75⁵ ≈ 0.763
  compounding check);
  desertion at morale 39 removes `max(1, 10%)` crew; dialogs appear in the
  §4.7 queue order.

## T10 — Port discovery, entry/exit, minimap

- **Goal:** ports are found, entered, and left.
- **Docs:** `20-*` §4.11–4.12; `50-*` §4.2 (navigation bonus);
  `80-*` §4.5–4.6 (routing).
- **Creates:** sighting + known_ports bookkeeping, port-entry sequence
  (greeting banner, desertion hook, dialog queue), `port_screen.tscn` shell +
  Set Sail, minimap widget (explored tiles, known ports, fleet dot; `M`
  enlarged mode).
- **Done-when:** new game knows exactly the 6 capitals; approaching an
  unknown harbor tile from beyond radius reveals then enters it; Set Sail
  restores position on the harbor tile with `clock_fraction = 0`; minimap
  shows explored-only tiles and nation-colored port dots at 2px/tile.

## T11 — Port hub + facility stubs

- **Goal:** the port menu and Phase-3 stubs exist.
- **Docs:** `30-*` §4.1, §4.7; `80-*` §4.2.
- **Creates:** port hub per wireframe: 6 facility rows + Set Sail; guild
  always stub-disabled; palace stub only where `facilities` includes it.
- **Done-when:** rows render from the port's `facilities` data (edit a port
  JSON → hub changes with no code edit); all four P1 facilities route to their
  screens and Esc returns; stubs show key `port.stub.phase3`.

## T12 — Trade engine + market screen

- **Goal:** the demo-loop economy works.
- **Docs:** `30-*` §4.2–4.5, §4.7, §5; `40-*` §4.2 (capacity); `50-*` §4.3
  (profit XP), §4.6 (reputation); `20-*` §4.10 (supplies rows).
- **Creates:** `scripts/port/trade_engine.gd`, `market_screen.tscn` per
  wireframe (goods table, supplies rows, invest button, qty pickers).
- **Done-when:** `30-*` §5 worked examples reproduce exactly (21/16 Lisbon
  wine, 39/31 London) as unit tests; 10×500g investment caps at −10% and the
  11th click is impossible; adding a 21st good to `data/goods.json` adds a
  functional row with zero code edits; buy clamps to gold and `fleet_free`;
  supplies rows ignore all factors; sell with profit emits XP + reputation.

## T13 — Shipyard engine + screen

- **Goal:** buy/repair/sell ships; refit stub ready for Phase 2.
- **Docs:** `40-*` §4.3–4.4, §5; `80-*` §4.7.
- **Creates:** `scripts/port/shipyard_engine.gd`, `shipyard_screen.tscn`
  (catalog list with prices/stats; repair with points picker; sell with
  confirm; refit row disabled with `shipyard.cannons.phase2`).
- **Done-when:** all §4.3 formulas enforced (`40-*` §7 unit tests);
  `FLEET_MAX = 5` and no-sell-flagship / no-sell-last-ship rules hold; bought
  ships start at full durability, zero crew; repair partial-payment math
  matches `ceil(base/400)` pricing.

## T14 — Tavern: crew hire/fire + officers

- **Goal:** crewing and officer recruiting work.
- **Docs:** `30-*` §4.5, §4.7; `50-*` §4.4–4.5; `40-*` §4.4.
- **Creates:** `tavern_screen.tscn` with Crew/Officers tabs; roster storage in
  `player.officers`.
- **Done-when:** hire costs 20g/head up to flagship `crew_max`; fire clamps to
  `crew_min`; each of the 6 officers appears only at its `recruit_ports`,
  costs `wage×10` to sign, vanishes from all taverns while employed, returns
  on dismiss; `OFFICER_MAX = 3` enforced; role bonuses apply in
  `character.gd#effective_stat`.

## T15 — Inn: rest + harbor relief

- **Goal:** morale recovery and the anti-softlock fallback.
- **Docs:** `30-*` §4.6; `50-*` §4.7 (+ §6 edge rules); `20-*` §4.5.
- **Creates:** `inn_screen.tscn` with rest button and conditional odd-job
  button; `GameState.debug_strip_fleet()` debug hook (editor-only).
- **Done-when:** rest advances exactly 3 ledger days with +5 morale/day capped
  at 80 and wages paid; odd-job button state machine matches `50-*` §6
  (shipless+broke only, officers lockout); each click +100g and +1 day.

## T16 — Character: nationality select, stats, XP, panel

- **Goal:** new-game flow and progression display.
- **Docs:** `50-*` §4.1–4.6, §5; `80-*` S2/S14.
- **Creates:** `nationality_select.tscn` (6 data-driven cards),
  `scripts/player/character.gd` (effective_stat, XP, levels, reputation),
  character panel modal S14 (stats, level/XP, officers, reputation table).
- **Done-when:** each nation spawns per `50-*` §4.1 (gold/ship/crew-min/
  start tile/current_port); stat effects unit-tested at boundaries per
  `50-*` §7; level formula rows from `50-*` §5 verified; panel shows live
  data; `C` toggles it over S3 and S4.

## T17 — Save / load

- **Goal:** full state persistence with the 3-slot UX.
- **Docs:** `90-*` §8, §5.5; `80-*` §4.6.
- **Creates:** `autoload/save_system.gd`, slot dialog (title Load; port Save;
  F5/F9 wiring).
- **Done-when:** save→quit→load round-trip restores every `90-*` §8.1 field
  byte-equal (spot-check day/gold/position/fleet/officers/reputation/
  investments/morale/known_ports/locale); corrupt and version-mismatched
  files show `ui.save.invalid` and never crash; F5 at sea shows
  `ui.cant_save_here`.

## T18 — Fleet panel: promote, jettison, capacity guard

- **Goal:** fleet management UI and invariants.
- **Docs:** `40-*` §4.4, §6; `20-*` §4.10.
- **Creates:** fleet/cargo panel (ship rows: type, durability bar, crew,
  supplies, cargo list; Promote button; Jettison per stack); normalization
  invariants in `fleet.gd` incl. load-time truncation guard.
- **Done-when:** promote is free and port-only; jettison updates
  `fleet_free` immediately; a hand-corrupted over-capacity save loads with
  logged truncation; `40-*` §5 valid loadout passes, invalid ones are
  impossible to reach via UI.

## T19 — Demo-loop acceptance

- **Goal:** Phase 1 is playable end-to-end per `00-OVERVIEW.md` §7.
- **Docs:** `00-*` §7 (the 9 steps); everything above.
- **Creates:** `tools/demo_check.md` — filled-in checklist log of a recorded
  manual run (per-tester dated); optional scripted E2E for steps 4–6.
- **Done-when (all 9 steps, verifying exactly):**
  1. 1280×720 title with New/Load and instant zh↔en toggle.
  2. All 6 nationality cards correct per `nations.json`.
  3. Market buy updates gold and cargo immediately.
  4. At sea: 8-dir movement, land blocks, provisions/water auto-consume
     (3+3/day for a 15-crew caravel), wages −2g/crew/day.
  5. ≥50% storm zone reached sailing west from Lisbon; provisions run-out
     reaches the starvation game-over screen on a test path.
  6. Second port entered; sale price matches `30-*` §4.2 to the gold.
  7. Shipyard repair/refit visible (refit disabled P1); one officer
     recruited and visible in the character panel.
  8. Save → quit → Load restores **all** state (list per T17).
  9. Full run repeated in `zh` with zero `<key>` fallbacks visible.

---

## Task dependency note

T2 feeds T4/T5; T5→T6→T7→T8→T9 are the sailing spine; T10 unblocks
T12–T15; T11 follows T12–T15 (its routing done-when needs all four facility
screens); T16 is parallel after T4; T17∥T18 once GameState settles (pin P1);
T19 requires all. Deviations from this order are fine only if the substitute
order keeps every task's cited docs implemented elsewhere first — the wave
table below is the sanctioned deviation set.

---

## Subagent execution plan (max 4 background subagents)

Run this backlog with background subagents instead of one task at a time. The
orchestrating session manages waves and integration; subagents implement.

- **Launch:** each task is implemented by a `general` subagent started in
  background mode; launch all of a wave's subagents as parallel calls in one
  message. At most **4** run concurrently; further ready tasks queue FIFO.
- **Wave gate:** a wave is done when every subagent has reported and the
  orchestrator has verified each done-when criterion — only then may the
  next wave launch.
- **Subagent prompt:** the task block verbatim + the cited doc sections +
  the AGENTS.md hard rules + the wave's interface pins; the report must list
  every done-when criterion with its pass/fail result.
- **Shared files (hard rule):** two running subagents never write the same
  file. `data/ui_strings.json` is orchestrator-owned during parallel waves:
  subagents list their new keys (zh + en) in their report and never edit the
  file; the orchestrator merges after the wave. If two ready tasks cannot
  avoid a shared file, serialize them instead.
- **Interface pins:** when two tasks of one wave call each other, the
  orchestrator fixes the call signatures (P1 below) before launch; subagents
  implement to the pin.
- **Design gaps:** a blocked subagent stops and reports; the orchestrator
  amends the owning system doc first (rule in `00-OVERVIEW.md` §13) and
  relaunches the task.
- **Data waves:** after any wave that touched `data/`, the orchestrator runs
  `python3 tools/validate_data.py` (must exit 0) before the next wave.
- **Opportunistic fill:** while a wave runs, a later task may start early
  only if all its dependencies are done and it shares no file with any
  running subagent.

| Wave | Background subagents (parallel) | Gate (after) |
|---|---|---|
| W1 | T1, T2 | — |
| W2 | T3, T4 | W1 |
| W3 | T5, T16 | W2 |
| W4 | T6 | W3 |
| W5 | T7 | W4 |
| W6 | T8 | W5 |
| W7 | T9 | W6 |
| W8 | T10 | W7 |
| W9 | T12, T13, T14, T15 | W8 |
| W10 | T11, T17, T18 | W9 |
| W11 | T19 | W10 |

- W4–W8 are single-subagent by dependency, not by choice: the sailing spine
  (T6→T7→T8→T9→T10) is strictly sequential.
- W9 runs the four facility screens (market/shipyard/tavern/inn) — disjoint
  files, full 4-way parallelism.
- In W10, T11 routes the four screens from W9; T17∥T18 share a wave only
  under the pin below. T19 is orchestrator-led (records the dated manual
  run); a subagent may build the optional scripted E2E first.
- **P1 (T17∥T18):** T17 owns `autoload/save_system.gd` and calls
  `Fleet.normalize_all()` after deserialization; T18 owns `fleet.gd`
  (normalize/truncate logic + logging). Neither edits the other's file.
