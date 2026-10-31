# IMPLEMENT — Phase 6: Sea Navigation Depth

**Status (2026-10-31):** backlog ratified; W1 (docs) launches first.
**Prerequisite (verified 2026-10-31):** Phase 5 is **fully complete** —
final gate green on `main` at `8d3913f` (`tools/demo_check_phase5.md`:
validator groups 1–8 exit 0, `trade_routes_built.json` rebuild
byte-identical, **35 suites / 6 008 checks**, `godot --headless
--quit-after 3` clean, day tick 15.9 ms avg @ 288 fleets, zh/en 448 keys
0 bad, save 0.91 MB @ extreme). Everything this phase builds on —
`npc_fleets.gd` (8 roles, lane stepping, hunter intel `60-*` §4.11.11.1),
S19 settings modal (`80-*` §4.6.3, amended 2026-10-31), save v5, and
`build_routes.py` — has landed.
**Source plan:** `.kilo/plans/1793422682981-phase6-navigation-depth-plan.md`
(product-owner decisions 1–14 carried below; the "Review corrections"
table records every divergence from that plan, verified against the repo).

---

## Goal

Make route planning seasonal and heading-aware — pillar 1 ("the sea has a
cost; route planning is the core skill") gets its depth:

1. **A 2× grid rescale** (task R): 2160×1080 → **4320×2160**, 6 → 12
   tiles/degree, 1 tile = 5 nm, voyage durations in days unchanged
   (tiles/day doubles). Tool-owned artifacts are regenerated, never
   hand-edited.
2. **A month/season calendar** (30-day months, 360-day year) that every
   seasonal layer indexes on.
3. **Prevailing winds + monsoons**: a hand-authored region × month table
   (~15–25 ocean regions), baked to `data/maps/wind_regions.png`; daily
   direction roll on the existing seeded weather stream; heading-relative
   `direction_factor` in the §4.4 speed pipeline.
4. **Ocean currents**: ~20 hand-authored systems baked to
   `data/maps/currents.png`; speed modifier always, optional per-day
   drift push; seasonal reversal (Somali) applied at lookup time.
5. **Sail trim + wait-at-sea**: `furled/reefed/normal/full` states and a
   Space-bar wait that makes "ride out the storm" a tactic.
6. **Two input modes** (Step default vs UW2-style Helm auto-sail) and
   **interpolated ship rendering** — rules stay strictly tile-domain.
7. **Seasonal sea ice**: month-windowed impassability (Baltic, Hudson
   Bay, White Sea) that NPC lanes respect via seasonal variants.
8. **NPC parity**: NPC fleets pay the same wind/current factors, hunters
   included; seasonal lane variants; hunter radii join the rescale
   (15/20 → 30/40).
9. **Neutral ports** (+40–60, `nation_id: ""`) across the monsoon world
   and **5 new regional lanes** (locked id set 12 → 17) so the phase's
   flagship loop — ride the summer monsoon to a China-coast port and
   sell into its market — has destinations.
10. **An omniscient debug chart mode** (S19-gated, session-only) as the
    phase's sanity window for every layer above.

Settings surface: two persisted toggles (`input_mode: step|helm`,
`current_mode: modifier|drift`) in **S19 only** (reachable pre-game via
S1, in-run via S4 — the S2 density row no longer exists), defaulting
Step + Modifier, persisted per save like `npc_preset`.

---

## Review corrections applied to the source plan

Every correction below was verified against the repo on 2026-10-31. The
plan text below (locked constants, tasks, waves) already reflects the
corrected values; this table is the record.

| # | Source-plan claim | Verified fact | Fix applied |
|---|---|---|---|
| 1 | "Phase 5 fully complete (as of planning, W3 merged; J/K/L/M/N still open)" | Phase 5 **is** fully complete: W1–W7 all merged, task N acceptance recorded 2026-10-31, final gate green (35 suites / 6 008 checks) | pre-state rewritten; hunter-intel inheritance is now a landed fact, not a forecast |
| 2 | Control toggles "settable on S2 (next to the density row) and in S19" | The S2 density row was **removed** the same day (80-* §4.6.3 amended 2026-10-31: density lives in S19 only, reached from S1 pre-game or S4 in-run; commits `f572c78`, `149fa6f`) | toggles pinned **S19-only** (task A/C/V); no S2 change this phase |
| 3 | A* fix = "window-local query region (±64 tiles, seam-shifted)" replacing a full-map `AStarGrid2D` | `sail_path.gd` **already ships** a two-stage design: near region (Chebyshev ≤ `NEAR_REGION_TILES` 256, `REGION_MARGIN` 24, seam-shifted local frame) + full-region stage with jumping off; measured worst route 0.37 s at 2160² (budget 1 s). Click destinations are screen-local by §4.2 pin, and the viewport shows the *same tile count* at any scale (32 px tiles) — so legal clicks are **always** near-stage at 4320² too | R keeps the shipped architecture: re-baseline benchmarks, re-measure the (unreachable-by-clicks) full stage at 9.33 M cells, keep the 1 s budget + pinned escape hatch; the heavier rework is implemented **only if measurement fails** |
| 4 | Rescale constants listed speeds `{8,10,12} → {16,20,24}` without an owner doc/file | Ship speeds live in **data**: `data/ship_types.json` and `validate_data.py`'s `LOCKED_SHIP_TYPES` tuples (latin 8 … galleon 10), locked by `10-*` §7.3 and asserted by validator group 3/5 | task A re-pins §7.3 speed values; task C amends `40-*`; task R owns the data + validator constant edits in its sweep |
| 5 | Combat tie: "divide by 2 at the seam or re-pin the mp table — doc decision, one place" | `60-*` §4.2 pins `battle_mp(speed) = speed / 2` ("required because ShipType.speed doubled", a Phase-4 pin that preserved pacing exactly once before) | **decision taken:** `battle_mp(speed) = speed / 4` — battle pacing preserved exactly a second time; C writes it, R implements it, no open decision remains |
| 6 | A\* world width handled generically | Hardcoded grid sizes beyond the builders: `validate_data.py` `MAP_WIDTH/MAP_HEIGHT` 2160×1080; `npc_fleets.gd` `_width/_height` defaults **and cell-key packing `int(cell.y) * 4096 + posmod(cell.x, 4096)` (breaks outright at x > 4095)** + `_bucket_index` stride 4096 + `buckets_x := 2160 / BUCKET_SIZE`; `sail_path.gd` `short_dx` default `width = 2160`; `map_loader.gd` seam double-draw at `x = 2160` | R's grep checklist names these symbols explicitly; cell-key packing must become width-derived |
| 7 | "`map_overrides.json` tile-unit review — halve or re-derive" | Direction is wrong: 6 → 12 tiles/degree means the same geographic feature is **2× tiles**, not ½ | corrected: tile-unit override entries **double** (or are re-derived geographically); single writer = R |
| 8 | "Space/Esc stops" the helm; "`Space` waits at sea in both modes" | Unpinned conflict: today `Esc` opens the S4 hub from the world map (`80-*` §4.6.3), and Space is unbound at sea | resolved: **Space** in Helm mode stops the fleet (press again while stopped = wait one day); in Step mode Space = wait one day; **Esc keeps its global S4 meaning everywhere** — helm cancels on click-to-sail, battle, docking only; heading persists (§2.6) |
| 9 | Currents schema `{version, systems: [...]}`, wind/ice `{version, regions: [...]}` | Validator group 1 **globs all `data/*.json`** and requires unknown files to use an envelope plural key == filename (`plural = name[:-5]`); files not in `ENTITY_FILES` are inert in groups 3–5 | envelope keys renamed to **`wind_regions` / `ocean_currents` / `ice_regions`** (plural == basename) so D merges green in W2 with **zero** validator edits; groups 9–10 (E) read the files directly |
| 10 | Wave sketch merges P (ports+lanes) at W2 end with validator "id-set amendment in task E" (W3) | `LOCKED_PORTS` exact-set check (group 5 `_locked_id_sets`) fails the moment a 101st port lands; group 8 fails the moment a 13th lane lands or source/built mismatch appears — P **cannot gate green** before E's amendments | **held-branch protocol:** P runs in W2 (authoring parallelism) and its worktree/branch is held unmerged through the W2 gate; at the W3 gate the master merges **P first, then E** (E's validator amendments + rebuilt artifact turn the wave green). No wave gates red — the gate runs once, at wave end, after both merges |
| 11 | Neutral ports slot into §7.1 with no validator interaction beyond groups 6/8 | Group 5 locks are exact-set; the neutral tier needs an explicit lock-model amendment: sovereign-100 exact + neutral tier (structure, i18n, goods refs, count 40–60) | E owns the group-5 amendment in W3 (one writer per file per wave: R has `validate_data.py` in W2 for grid/speed locks) |
| 12 | New world keys (`sail_trim`, `heading`, `wind_dir`) ownership unstated; W5 subagents would need them at launch | Runtime writers only assign into `GameState.world` dict keys; defaults live in `game_state.gd`'s world block | F (W4) owns the world-block defaults; V (W5) owns `control_prefs` + save v6 keys; G/H/I read via the **guard-call convention** (`.get` with the documented default) so W5 worktrees are independent until merge (Phase-5 J precedent) |
| 13 | Hunter chase A* ≤ 250 ms/day assumed to carry over | Chase radii ×2 (15/20 → 30/40) **quadruples** the search area | H re-measures against the 250 ms/day budget; windowed `AStarGrid2D` region (the `sail_path` near-stage pattern) if it fails — measurement gates the rework, not speculation |
| 14 | Save v6 bump placement unstated | Between R's coordinate rebase and V's v6 bump, a stale v5 payload would *load* into the rescaled world at half-scale coordinates (dev-stage only; suites round-trip and stay green) | **all of save v6 lands in V (W5)**: `SAVE_VERSION = 6`, `PHASE = 6`, v5 refused, new keys, `test_save_v5` → `test_save_v6` rename/rework. Mid-phase state is documented as "never load a previous-phase save"; the phase ships with v6 refusing v5 |
| 15 | Ocean rasters decoded somewhere | `map_loader.gd` owns only `world.png`; no current/wind decoder exists | new **`scripts/world/ocean_layers.gd`** (F) decodes both rasters + ice polygons and owns all lookups (reversal flip, month-keyed ice cache); `map_loader.gd` untouched |

---

## Decision record

Carried from the source plan (product-owner decisions 1–14) with the
corrections above folded in:

1. **Full scope, one phase.** All five navigation features + calendar +
   grid rescale + neutral ports/lanes + debug chart land together; quest
   hooks stay out.
2. **Anisotropic speed is the world, not an option.** Player control
   depth = exactly two persisted toggles in S19 (`input_mode`,
   `current_mode`), defaults Step + Modifier, plumbing mirrored on
   `npc_preset` (S19 settable pre-game via S1, carried by `new_game`,
   persisted per save).
3. **Hand-authored, cited, nothing vendored.** Wind regions, currents,
   ice, ports, lanes are authored facts with per-section sources in
   `LICENSE-NOTES.md` (Phase-5 decision 7 precedent).
4. **Click-to-sail stays wind-blind.** Distance-optimal A* unchanged;
   wind/currents act on elapsed time only. A hand-tacked route beats the
   autopilot upwind — that skill gap is the point.
5. **NPC physics parity.** NPC tile budgets multiply by the same
   direction/current factors (pure functions of day+position,
   deterministic); seasonal lane variants by month; hunters included.
6. **Grid rescale by regeneration.** `tools/build_world.py` and
   `tools/build_routes.py` re-run at 12 tiles/degree; artifacts stay
   tool-owned and byte-identical across rebuilds; `map_overrides.json`
   tile-unit entries double (correction 7).
7. **A\* architecture unchanged.** The shipped two-stage `sail_path.gd`
   covers all legal clicks at any scale via its near stage; R measures,
   it does not redesign (correction 3).
8. **Interpolated rendering, tile-domain rules.** The ship marker
   animates between tile positions over each step interval in both input
   modes; no sub-tile value exists in any rule or save.
9. **Motion/wait keys resolved** (correction 8): Space = wait (Step) /
   stop-then-wait (Helm); Esc = S4 everywhere; helm cancels on
   click-to-sail/battle/docking.
10. **Neutral ports are frontier markets.** Minimal now-semantics
    (§2.11): markets work, no NPC fleet serves them this phase, they can
    never close; no new goods; existing 100 ports frozen.
11. **Lanes authored now** — 5 regional lanes + `hanseatic_north` winter
    variant, one content writer (P); they carry patrols/treasure/pirates
    visibly but zero trader traffic yet (own-nation docking pin).
12. **No save migration.** `SAVE_VERSION = 6`, `PHASE = 6`, v5 refused
    (`90-*` §8.2 dev-stage rule).
13. **Docs first, one wave, blocking** — A/B/C ratify every number below
    into the owning docs before any data/tool/code task starts
    (`00-*` §13).
14. **Envelope plural == basename** for the three new data files
    (correction 9), so content merges stay green ahead of tooling.
15. **Debug chart is read-only and session-only** — a documented cheat
    that is session-only and never persisted (S19-gated, default off),
    never mutates
    `GameState`, never gates gameplay.

---

## Pre-state (verified 2026-10-31)

- Autoloads: `autoload/{game_state,event_bus,data_loader,i18n,save_system}.gd`;
  `SAVE_VERSION = 5` (`save_system.gd:60`), hunter keys
  `world.last_departed_port` / `world.hunter_intel_cell` persisted
  (v5 world block).
- Grid: `sailing_sim.gd:51` `TILES_PER_DEGREE := 6`; `build_world.py`
  `LOCKED_GRID_W/H = 2160/1080`; `validate_data.py` `MAP_WIDTH/HEIGHT =
  2160/1080`; hardcoded 2160/1080/4096 sites per correction 6.
- Sailing: `sailing_sim.gd` (1067 lines) — `wind_factor(weather, class)`
  static, `effective_speed()` heading-blind, `move_cost()` parameterless;
  base speeds `{8,10,12}` tiles/day on 10 nm tiles (`20-*` §4.4);
  ship speeds duplicated in `data/ship_types.json` + validator
  `LOCKED_SHIP_TYPES` (correction 4).
- Pathfinding: `sail_path.gd` (337 lines) two-stage A* —
  `NEAR_REGION_TILES = 256`, `REGION_MARGIN = 24`, `BUDGET_MS = 1000`,
  seam-shifted local frame, full stage with jumping off (correction 3).
- Input: `world_map.gd` (2018 lines) — hold-to-repeat 0.25 s delay then
  ~8 tiles/s; click-to-sail advances on the same cadence; Space unbound
  at sea; Esc → S4 hub (`80-*` §4.6.3).
- World map agents: `npc_fleets.gd` (3316 lines) — 8 roles, cell-bucket
  index (`BUCKET_SIZE 16`, key packing/bucket strides per correction 6),
  lane stepping 1 tile/day base, hunter 15/20 hysteresis
  (`60-*` §4.11.11.1); `fleet_path.gd` pursuit A* (250 ms/day budget).
- Data: 100 ports (spain 20, holland 20, portugal 18, ottoman 18,
  england 14, italy 10 — zero `nation_id: ""` ports; east of 90°E all 16
  ports are European factories); 12 locked lanes; 20 locked goods
  (consumption tier split 5/10/5 validator-asserted);
  `trade_routes_built.json` (769 nodes/805 edges) byte-identical rebuilds.
- Settings: S19 modal `scenes/ui_shared/settings_panel.{tscn,gd}`,
  reached from S1 and S4; owns density dial + locale + return-to-menu +
  Save; `settings.*` ui_strings family (448 total keys, 0 bad).
- Placeholder: `20-*` §4.13 "Seasonal wind & ocean currents (Phase-5
  placeholder)" awaits replacement by the real §§4.14–4.18.
- Suites: 35 / 6 008 checks (`tools/run_tests.py`); `test_save_v5` is the
  current save suite.
- Stale-doc cleanup owed: `IMPLEMENT-Phase5.md`'s role table says hunters
  "leave lanes entirely" — superseded by `60-*` §4.11.11.1 (task C
  sweep).

---

## Locked constants

All numbers here get ratified into the owning docs by the Phase-6 doc
tasks before any data/code starts (00-* §13). All tile-domain numbers
are stated **at the new 5 nm grid** (§2.0). Task-owned values are
marked; everything else is final-for-now per `00-*` §11.

### 2.0 Grid rescale — 4320×2160, 12 tiles/degree (task R)

- `TILES_PER_DEGREE` 6 → 12; grid 2160×1080 → **4320×2160**; 1 tile =
  10 nm → **5 nm**; `TILE_SIZE_PX` stays 32 (viewport shows half the
  geographic span — the free "ocean feels bigger" lever). Longitude
  wraps mod 4320; latitude/`I` band rules unchanged (they are degrees).
- **Regeneration, not editing:** re-run `tools/build_world.py` → new
  `data/maps/world.png` + `world_report.json`; re-run
  `tools/build_routes.py` → new `trade_routes_built.json` (waypoints are
  lat/lon, re-rasterized). Two rebuilds byte-identical; validator groups
  1–8 re-run at the new size. `tools/map_overrides.json` tile-unit
  entries **double** or are re-derived (correction 7).
- **Constants sweep** — classify every tile-unit pin, then rescale; the
  full enumeration table is written into the owning docs by A/B/C first,
  and R implements it with a grep checklist as its done-when:
  | Class | Rule | Examples |
  |---|---|---|
  | Physical (nm semantics preserved) | ×2 tiles | `ShipType.speed` {8,10,12} → {16,20,24} in `data/ship_types.json` + `LOCKED_SHIP_TYPES` (80–120 nm/day unchanged); sighting 24 → 48 (≈240 nm); discovery 18 → 36; trader decision range 60 → 120; escort 10 → 20 |
  | Derivation accuracy (tile count kept — nm accuracy *improves*) | unchanged | harbor snap ≤ 2 (now 10 nm); lane waypoint snap ≤ 2 |
  | Gameplay (default ×2, re-tunable only per `00-*` §11) | ×2 tiles | patrol zone 15 → 30; chokepoint anchor 3 → 6; pirate hysteresis 5/8 → 10/16; hunter hysteresis 15/20 → **30/40** (`60-*` §4.11.11.1); lane spoke 20 → 40; lane stepping base 1 → 2 tiles/day; drift tile rates (§2.4) |
- **Symbol-named grep checklist (R's done-when):** `TILES_PER_DEGREE`
  (`sailing_sim.gd`); `LOCKED_GRID_W/H` (`build_world.py`);
  `MAP_WIDTH/MAP_HEIGHT` (`validate_data.py`); `_width/_height`,
  `_bucket_index`, `buckets_x`, key packing `cell.y * 4096 +
  posmod(cell.x, 4096)` (`npc_fleets.gd` — must become width-derived);
  `short_dx(..., width = 2160)` (`sail_path.gd`); seam double-draw
  `x = 2160` (`map_loader.gd`); `LOCKED_SHIP_TYPES` speeds
  (`validate_data.py`); every literal 2160/1080 found by grep.
- **A\* (decision 7 / correction 3):** shipped two-stage design kept;
  near-stage constants (256/24) cover every legal click at any scale
  (viewport tile count is scale-invariant). R re-runs the module's
  benchmark set at 4320², records numbers in the module docstring, and
  measures the full-stage region cost (9.33 M cells) — the 1 s budget +
  pinned escape hatch stand; heavier rework only if measurement fails.
- **Combat seam (decision 5):** `battle_mp(speed) = speed / 4` —
  Phase-4's pacing-pin pattern repeated (`60-*` §4.2); battle pacing
  unchanged.
- **Minimap/chart:** 256×192 px box and 128×96-tile crop at 2 px/tile
  unchanged (window span halves geographically, consistent with the
  denser world); chart downscales as today. Explored bitset grows to
  ~9.3 MB session-only (not saved) — acceptable.
- **Save:** `world.position` re-bases to 4320×2160 — absorbed by the
  save v6 bump (§2.10, task V); dev-stage "never load a previous-phase
  save" holds mid-phase (correction 14).

### 2.1 Calendar (`20-*` new §4.15)

- `MONTH_DAYS = 30`, `YEAR_MONTHS = 12` → 360-day year; day 1 = Month 1.
  `year(day) = floor((day − 1) / 360) + 1`;
  `month(day) = floor(((day − 1) mod 360) / 30) + 1`.
- Treasure-fleet "seasons" (Phase 5, mod 90) reconcile as 90-day
  quarters anchored at Month 1 — behavior unchanged, doc note only.
- HUD top bar gains `Year {y} · Month {m}` (zh `{y}年{m}月`); month
  display forms 一月…十二月 / Month 1–12 in `ui_strings.json`.

### 2.2 Prevailing wind (`20-*` §4.7 extension + new §4.14)

- `data/wind_regions.json`: `{version, wind_regions: [{id, name:{zh,en},
  polygon: [[lat,lon],…], months: {"1":"NE", … "12":"SW"},
  variability: "steady"|"variable"}]}` (correction 9 envelope). Direction
  tokens: the 8 compass dirs `N NE E SE S SW W NW` + `VAR`. Regions tile
  all ocean between 70°N–60°S; uncovered water falls back to `VAR` +
  `variable`.
- Daily roll (ledger step 3, after weather strength, same seeded stream,
  pinned order strength→direction): prevailing = region table for the
  current month; `VAR` draws uniformly. Jitter by weather:
  | weather | prevailing | deviation |
  |---|---|---|
  | calm | 60% | else uniform ±45°/±90° |
  | fair | 70% | else ±45° |
  | strong | 60% | else ±45° or ±90° |
  | storm | 0% | uniform over all 8 |
  Result persisted per day in `GameState.world.wind_dir` (8-dir id).
- Baked lookup: `data/maps/wind_regions.png` (1 px = 1 tile at 5 nm,
  palette index = region id), tool-owned (`build_ocean.py`), runtime
  O(1) via `ocean_layers.gd`.

### 2.3 Heading-relative speed (`20-*` §4.4 pipeline addition)

```
effective_speed(heading) = floor(base × wind_factor × direction_factor
                                 × current_factor × crew_factor
                                 × (1 + seamanship_bonus) × trim_factor)
minimum 1 tile/day
```

- `direction_factor` — angle between move heading and wind-from
  direction, bucketed to the 8 compass grid; applied only when weather
  ≠ `calm` (calm keeps the flat 0.8 sail penalty):
  | bucket | sail | hybrid | oar |
  |---|---|---|---|
  | 0° (into wind) | 0.50 | 0.85 | 1.00 |
  | 45° (close-hauled) | 0.70 | 0.95 | 1.00 |
  | 90° (beam) | 1.00 | 1.00 | 1.00 |
  | 135° (broad reach) | 1.15 | 1.05 | 1.00 |
  | 180° (running) | 1.30 | 1.10 | 1.00 |
- `move_cost()` becomes `move_cost(heading)`; blocked moves still cost
  nothing; heading-less `effective_speed()` (HUD average) uses beam 1.0.

### 2.4 Ocean currents (`20-*` new §4.16)

- `data/ocean_currents.json`: `{version, ocean_currents: [{id,
  name:{zh,en}, strength: 1|2|3, path: [[lat,lon],…],
  width_tiles: int (at 5 nm),
  reversal: {"summer_months": [6,7,8,9], "direction": "reverse"}?}]}`
  (~20 systems: Gulf Stream, Kuroshio, N/S Equatorial, Canaries,
  Benguela, Agulhas, Somali (reversal), Brazil, N/S Pacific, Antarctic
  Circumpolar, North Atlantic Drift, Labrador, Humboldt, E/N Australian,
  Monsoon drift…; exact list task-owned). Sources cited per system in
  `LICENSE-NOTES.md` (facts, nothing vendored).
- Baked: `data/maps/currents.png` (1 px = 1 tile; index 0 = none;
  indices 1–24 = 8 dirs × 3 strengths; overlaps resolved by
  strongest-then-id-order). Tool-owned, byte-identical rebuild
  (validator group 9). **Reversal rule (pinned):** the raster stores the
  annual-mean vector; `reversal.summer_months` flips the decoded vector
  **at lookup time** (runtime + debug renderer apply the same one-line
  flip) — one static PNG, seasonal Somali.
- **Modifier (both input modes):** heading/current alignment within
  67.5° → `1 + 0.08 × strength`; 67.5–112.5° → 1.0; ≥ 112.5° →
  `1 − 0.08 × strength`.
- **Drift (Drift mode only):** at each day tick at sea, the fleet is
  pushed along the current vector by strength: 2.5 / 10 / 20 nm/day =
  **0.5 / 2 / 4 tiles/day at 5 nm** (fractional accumulator for the 0.5
  case). Wrap-aware; stops before impassable tiles (never lands the
  fleet, no damage); suppressed while docked. Accumulator not persisted
  (saves are port-only; it resets).

### 2.5 Sail trim (`20-*` new §4.17)

- States `furled | reefed | normal | full` (default `normal`), keys
  `[`/`]` cycle, persisted (`world.sail_trim`).
- Speed: furled 0 (cannot move), reefed 0.75, normal 1.0, full 1.15.
- Storm damage: furled ×0.5, reefed ×0.75, normal ×1.0, full ×1.5
  (multiplies `storm_damage_for`); oar class ignores trim; hybrid uses
  the sail table.
- **Wait at sea:** `Space` holds position and advances exactly 1 day
  (`advance_clock(1.0)` — full ledger: provisions, wages, weather
  reroll, morale). Both input modes regardless of trim (correction 8) —
  the "wait out the storm / wait for wind shift" tactic.

### 2.6 Input modes & interpolated rendering (`20-*` §4.2 extension, `80-*` §4.3)

- **Step (default):** today's behavior (key-per-tile, hold-to-repeat
  0.25 s delay then ~8 tiles/s).
- **Helm:** a direction key sets the heading; the fleet auto-steps that
  heading every `interval_s = clamp(1.0 / effective_speed(heading),
  0.12, 2.0)` s (the clamp lands a speed-16 ship at ≈ today's hold
  rate). New direction key changes heading; `Space` stops (press again
  stopped = wait); click-to-sail, battle and docking cancel helm
  (**Esc stays the S4 hub everywhere** — correction 8); trim keys work;
  port entry unchanged. Heading persisted (`world.heading`).
- **Interpolated rendering (both modes):** the ship marker animates
  between tile positions over the step interval; logic, rules and saves
  stay strictly tile-domain. No sub-tile coordinates exist in any rule.
- Settings: `control_prefs: {input_mode: "step"|"helm",
  current_mode: "modifier"|"drift"}` in GameState, **S19-only** rows
  (correction 2), persisted in save v6 like `npc_preset`.

### 2.7 Seasonal sea ice (`20-*` new §4.18)

- `data/ice_regions.json`: `{version, ice_regions: [{id, name:{zh,en},
  polygon: …, months: […]}]}` — initial set: Baltic (12–3), Hudson Bay
  (11–4), White Sea (11–4).
- Rule: in-month, water tiles inside a polygon are impassable to
  *entering* fleets (player, NPC, A*, lane stepping) — a tile freezing
  under a standing fleet does not trap it (it may still move out). Toast
  `world.ice_blocked` on a refused move. Runtime polygon check with a
  month-keyed tile cache (small data, no raster) in `ocean_layers.gd`.
- The permanent `I` band rule (§4.1) is unchanged — seasonal ice only
  adds temporary impassability equatorward of it.

### 2.8 NPC parity & seasonal lane variants (`60-*` §4.11.11 amendment)

- NPC fleet daily tile budget multiplies by the same
  `direction_factor`/`current_factor` for the current leg heading (pure
  functions of day+position — no RNG, replays exact). Hunters pay it per
  pursuit step too.
- Lane stepping base 1 → 2 tiles/day (§2.0 sweep) before factors.
- `trade_routes.json` lanes gain optional
  `variants: [{id, months: […], waypoints: […]}]`. Runtime picks the
  in-month variant; the builder validates each variant's passability
  within its own month window (hard build error; validator group 10
  checks coverage). A lane crossing an ice polygon must either carry a
  covering variant set or avoid ice year-round (first customer:
  `hanseatic_north` winter variant outside the Baltic freeze).

#### 2.8.1 Hunter intel (Phase-5 lock — inherited, not rebuilt)

Phase-5 landed (`60-*` §4.11.11.1): hunters navigate the lane network
to `world.last_departed_port`, loiter 10 days, chase only within
Chebyshev 15 (short-range A* ≤ 250 ms/day), give up beyond Chebyshev 20;
at-sea contact updates `world.hunter_intel_cell`. Both keys persist in
the v5 world block. Phase 6's only touchpoints:

- radii join the §2.0 sweep: **15/20 → 30/40** (R implements, C
  re-pins);
- `hunter_intel_cell` re-bases to 4320×2160 with save v6 (breaking
  change absorbed by the version bump);
- §2.8 parity factors multiply hunter lane travel and pursuit steps
  (base lane stepping 1 → 2);
- H re-measures the pursuit A* budget at the quadrupled search area
  (correction 13).

### 2.9 Chart / HUD surfaces (`80-*`)

- HUD: wind arrow + strength label by the weather glyph; current arrow
  on a current tile; trim chip; `Year {y} · Month {m}` in the top bar.
- Chart (S17): current-month wind arrows per region (toggle `W`),
  current arrows (`C`), ice tint on explored tiles (`I`) — plus the
  §2.12 debug mode layers. Placeholder shapes only.
- New ui_strings families: `world.wind.*`, `world.current.*`,
  `world.trim.*`, `world.ice.*`, `world.wait.*`, `settings.input.*`,
  `settings.current.*`, `chart.wind.*`, `chart.current.*`, `debug.*`
  (zh/en complete; orchestrator-merged per the standing protocol).

### 2.10 Save v6 (`90-*` §8.2)

`SAVE_VERSION = 6`, `PHASE = 6`, **no migration, v5 refused**. New
persisted keys: `control_prefs`, `world.sail_trim`, `world.heading`,
`world.wind_dir`. Phase-5 hunter keys carry over unchanged in shape
(cell re-based, §2.8.1). Nothing else is new: drift accumulator resets;
wind direction is re-rolled daily on the seeded stream but persisted for
the current day.

### 2.11 Neutral ports — the monsoon world gets destinations (`10-*` §7.1 amendment, task P)

Diagnosis (verified 2026-10-31): 100 ports, all owned by the 6 nations;
the monsoon's home region has zero sovereign destinations.

- **Tier:** new ports carry `nation_id: ""` (pirate-fleet precedent).
  Target **+40–60**, band per region: China coast 12–15, Japan 6–8,
  Korea 1–2, sovereign SE Asia 6–8, Mughal India/Persia/Arabia 10,
  Swahili/Red Sea 4–6. Era-appropriate, cited historical facts; exact
  list task-owned.
- **Minimal now-semantics (pinned):**
  | System | Rule |
  |---|---|
  | Market/economy | works as-is — resting stock from each port's produces/demands fields |
  | NPC fleets | **none serve them this phase** → documented player-only frontier markets; local traffic = later phase |
  | Budgets/cap | zero churn — Phase-5 arithmetic untouched |
  | Rep/bounty/closed ports | a neutral port can never close → emergent safe haven; documented known effect |
  | Lane spokes | spoke to nearest lane waypoint within **40** tiles; nationless fallback = **nearest lane waypoint** unbounded |
  | Facilities | data-driven per port; default market + inn + tavern, shipyard only where authored |
  | Marker/label | one neutral color constant + 中立港/Neutral port ui_strings |
  | i18n | zh/en names required (广州, 长崎, 苏拉特…) |
- **Hard constraints:** no new goods (the 5/10/5 split is
  validator-asserted); existing 100 ports untouched; A unlocks §7.1's
  count wording before P authors.
- **Rescale interaction:** `ports.json` is lat/lon — resolution
  independent; harbor-pair derivation and group 6 re-run in R/E gates.

#### 2.11.1 Regional lanes (locked id set 12 → 17, task P authors / E builds)

| Lane | Waypoints (approx, task-owned) | `nations` | `goods` (existing 20 only) | `chokepoints` |
|---|---|---|---|---|
| `canton_country_trade` | Malacca → Hoi An → Macau → Quanzhou → Ningbo → Hirado | portugal, holland, spain | silk, ceramics, spices, cotton_cloth | `taiwan_strait` |
| `coromandel_bengal` | Goa → Colombo → Nagapattinam → Masulipatnam → Hughli | portugal, holland | cotton_cloth, silk, sugar, spices | `ceylon_south` |
| `swahili_coast` | Mozambique Is. → Mombasa → Mogadishu | portugal | dried_fish, salt, cotton_cloth | `cape_guardafui` |
| `pacific_america` | Acapulco → offshore Central America → Gulf of Panama → Guayaquil → Callao → Valparaíso | spain | sugar, dried_fish, wool, salt | `gulf_of_panama` |
| `west_africa` | Madeira → Safi → Saint-Louis → Elmina → Accra → Luanda | portugal | dried_fish, salt, cotton_cloth, amber | `gulf_of_guinea` |

- **Fringe policy (pinned):** Oceania, spice fringe, N.-America east
  coast and `portobelo`'s portage stay on long spokes **on purpose**;
  the `--report` spoke-length distribution (E) is the data input for any
  future lane decision. Task P also resolves the `botany_bay` (1770)
  anachronism against the ~1550–1620s anchor as a one-line data decision
  (re-place or re-role).
- **Honest scope:** the new lanes carry `nations`-tagged patrols,
  treasure fleets and chokepoint pirates (`taiwan_strait`,
  `ceylon_south`) — real visible gameplay; **no trader docks at a
  neutral port yet**. Fleet budgets, cap 288, rivalry math untouched.
- **File ownership:** P owns **every** `trade_routes.json` content
  addition (5 lanes + `hanseatic_north` winter variant); E stays
  tools-only.

### 2.12 Debug chart mode (`80-*` §4.6 extension, task I)

The existing Chart (S17) gains an omniscient debug mode behind a
调试图层/Debug overlays row in **S19** — **session-only, default off,
never persisted**. With the row on, opening the Chart adds:

- **`D` — omniscient mode:** ignores explored bitset + `known_ports`
  (whole map + every port: nation colors, neutral grey, capitals
  ringed).
- **Live ecology:** every fleet from `NpcFleets.markers()` (role colors
  per `80-*` §4.5.2, not viewport-culled), wrecks, hunter-intel markers
  (`last_departed_port` ring + `hunter_intel_cell` cross). Tooltips
  read-only.
- **Network:** all 17 lanes from built tile paths (per-lane colors,
  active variant solid), spokes (thin grey), chokepoint diamonds, lane
  ids in a side legend.
- **`W`/`C`/`I` toggles + `,`/`.` month scrubber:** previews any month's
  prevailing wind arrows, seasonal ice, active lane variants, reversed
  Somali — pure view state, `GameState` untouched.
- **Info strip:** day → Year/Month, density preset, fleet count by role.
- **Redraw triggers:** open, layer/month toggle, `day_advanced` — no
  per-frame work.
- **Governance:** documented cheat; read-only; gates nothing.
- Symbol contract (pinned by C in `80-*`, used cross-worktree in W5):
  `SettingsPanel.debug_overlays: bool` (static, session-only, default
  false).

---

## New artifacts

| Artifact | Owner | Notes |
|---|---|---|
| `data/wind_regions.json` | D | hand-authored, cited; plural key `wind_regions` (correction 9) |
| `data/ocean_currents.json` | D | hand-authored, cited; plural key `ocean_currents` |
| `data/ice_regions.json` | D | hand-authored; plural key `ice_regions` |
| `data/maps/wind_regions.png` | E (`build_ocean.py`) | tool-owned, never hand-edited, byte-identical rebuild |
| `data/maps/currents.png` | E (`build_ocean.py`) | tool-owned (annual-mean; reversal at lookup) |
| `tools/build_ocean.py` | E | rasterize regions + currents, `--ascii`/`--report`, determinism |
| validator groups 9 (ocean rasters: coverage, determinism, palette bounds) and 10 (ice/lane variants: month-window passability, variant coverage) | E | plus group 5 neutral-tier + group 8 12→17 id-set amendments |
| lane `variants` + 5 regional lanes | P (data/trade_routes.json, single writer) | E owns builder support |
| `data/ports.json` (+40–60 neutral) | P | + `LICENSE-NOTES.md` port-region sources |
| `scripts/world/ocean_layers.gd` | F | raster decode + polygon cache + all lookups (correction 15) |
| `data/maps/world.png`, `world_report.json`, `trade_routes_built.json` | R (regenerate at 12 t/°), E (final routes rebuild over P's sources) | existing tool-owned artifacts, not new |

---

## Tasks

### A — Amend `10-DATA-SCHEMA.md`, `90-ARCHITECTURE.md`, `00-OVERVIEW.md`, AGENTS.md (doc-first)

- **Goal:** the data contract + architecture pins for navigation depth.
- **Docs:** this file's locked constants; current `10-*`, `90-*`, `00-*`.
- **Changes:** `10-*` — new schemas (`wind_regions.json`,
  `ocean_currents.json`, `ice_regions.json` with **plural ==
  basename** envelopes), tool-owned raster rules for
  `wind_regions.png`/`currents.png` (like `world.png`), lane
  `variants` schema, validator **group 9** + **group 10** specs, the
  §2.0 grid constants (4320×2160, 12 t/°) wherever the schema states
  grid size (§6.3, harbor snap rules stay ≤ 2), **§7.1 unlock**
  ("100 locked sovereign ports, untouched" + neutral tier: `nation_id:
  ""`, count 40–60, structural rules; ids appended by task P), **§7.6
  lane id-set unlock 12 → 17** (5 new ids named; ids/waypoints locked by
  task P), **§7.3 ShipType speed re-pin {16,20,24}** (correction 4).
  `90-*` — GameState `control_prefs` + world key additions, save v6 key
  list + "**no migration; v5 refused**", autoload/module row for
  `ocean_layers.gd`, day-tick order note (wind-direction roll joins the
  seeded stream strength→direction). `00-*` — §5 phase table Phase-6
  row; §12 glossary: 洋流 ocean current, 季风 monsoon, 盛行风 prevailing
  wind, 帆位 sail trim, 季节海冰 seasonal ice, 掌舵 helm mode, 漂移
  drift, 中立港 neutral port. `AGENTS.md` — task-backlog pointer to
  Phase 6; add `wind_regions.png`/`currents.png` to the tool-owned
  family line; builder list gains `build_ocean.py`.
- **Done-when:** every §2.0–§2.4, §2.10–§2.11 locked constant with
  owning doc `10-*`/`90-*`/`00-*` appears there exactly once; the §7.x
  unlock wordings match this file; no file outside `docs/` and
  `AGENTS.md` touched.

### B — Amend `20-WORLD-AND-SAILING.md` (+ one line in `30-*`) (doc-first)

- **Goal:** the sailing/world spec, on paper.
- **Changes:** §4.1 grid constants at 12 t/°; §4.2 input modes +
  interpolated rendering + corrected key semantics (Space/Esc per
  correction 8); §4.4 pipeline + factor tables + speeds {16,20,24} on
  5 nm tiles; §4.7 wind-direction roll (stream order pinned);
  **replace the §4.13 placeholder** with the real §4.14 (wind
  regions), §4.15 (calendar), §4.16 (currents), §4.17 (trim + wait),
  §4.18 (ice); minimap/chart pins (§2.0); **`30-*`**: one sentence —
  neutral ports run the standard market off their produces/demands
  (frontier markets, player-only this phase).
- **Done-when:** cross greps vs `10-*`/`60-*` clean (grid size, factor
  tables, calendar, wait/space semantics); no §4.13 placeholder prose
  survives.

### C — Amend `60-COMBAT.md`, `40-SHIPS-AND-FLEET.md`, `70-QUESTS-*.md`, `80-UI-UX.md` (doc-first)

- **Goal:** the fleet/ecology/UI/combat-seam spec, on paper.
- **Changes:** `40-*` — ShipType.speed values re-pinned {16,20,24} on
  5 nm tiles (fleet-speed composition note carries over). `60-*` — §4.2
  **`battle_mp(speed) = speed / 4`** (decision 5, one sentence of
  rationale mirroring the Phase-4 pin); §4.11.11 amendment (parity
  factors, variant selection, lane stepping base 2, ice-aware stepping);
  §4.11.11.1 radii 15/20 → **30/40** in the sweep; pursuit A* budget
  unchanged (H re-measures). `70-*` — none beyond greps (quest hooks
  out of scope, note stays). `80-*` — HUD indicators (§2.9), chart
  toggles `W`/`C`/`I`, **the §2.12 debug chart mode** incl. the
  `SettingsPanel.debug_overlays` symbol contract, S19 rows
  (`settings.input.*`, `settings.current.*`, debug-overlays row —
  **S19-only**, correction 2), wait/helm key table rows (Space per
  correction 8), the full ui_strings family inventory (§2.9) + `debug.*`
  + neutral-port label/marker constant. **Stale-line sweep:** fix
  `IMPLEMENT-Phase5.md`'s hunter "leave lanes entirely" role-table line
  to cite `60-*` §4.11.11.1.
- **Done-when:** cross-doc greps clean (mp formula, 30/40 radii, factor
  application points, S19 nav rows, the debug symbol); C names exactly
  the symbols G/H/I ship against; no file outside `docs/` touched.

### R — Grid rescale at 12 tiles/degree (builders + code constants + suite re-baseline)

- **Goal:** the world at 4320×2160 with every tile-domain constant
  swept, suites green.
- **Docs:** §2.0 + the enumeration tables A/B/C ratified.
- **Creates/changes:** parametrize `tools/build_world.py`
  (`LOCKED_GRID_W/H` → 4320/2160 via the shared grid helper); audit +
  double tile-unit entries in `tools/map_overrides.json`; re-run → new
  `data/maps/world.png` + `world_report.json` (two rebuilds
  byte-identical); re-run `tools/build_routes.py` (12-lane file
  unchanged by R) → new `trade_routes_built.json`; `validate_data.py` —
  `MAP_WIDTH/HEIGHT`, `LOCKED_SHIP_TYPES` speeds, every tpd-derived
  constant audited (harbor snap stays ≤ 2); `data/ship_types.json`
  speeds {16,20,24}; **code sweep** per the §2.0 grep checklist
  (`sailing_sim.gd` `TILES_PER_DEGREE`, `npc_fleets.gd` width/height +
  **cell-key packing made width-derived** (correction 6), `sail_path.gd`
  `short_dx` default + benchmark re-run at 4320² with numbers recorded
  in the module docstring, `map_loader.gd` seam, `world_map.gd` wrap,
  `battle_mp` → /4 wherever implemented); full-suite re-baseline
  (movement coordinates, sighting/discovery radii, lane timing, ecology,
  e2e — every check that embeds a tile-domain number).
- **Done-when:** `python3 tools/validate_data.py` exit 0 (groups 1–8 at
  the new size; world.png's builder report agrees with derived harbor
  tiles); both rebuilds byte-identical; all suites green at the new
  scale with re-baselined numbers recorded in the task report; the §2.0
  grep checklist shows zero unreviewed hits; full-stage A* cost at
  9.33 M cells measured and recorded (budget verdict: ship/as-is vs
  pinned fallback); `godot --headless --quit-after 3` clean.

### D — Ocean data: wind regions, currents, ice (content, cited)

- **Goal:** the three seasonal datasets, green-inert (correction 9).
- **Docs:** `10-*` schemas (A); §2.2/§2.4/§2.7.
- **Creates:** `data/wind_regions.json` (15–25 regions × 12 months,
  tiling all ocean 70°N–60°S, compass tokens, `VAR` usage justified per
  region); `data/ocean_currents.json` (~20 systems, strengths 1–3,
  lat/lon paths, width at 5 nm, Somali `reversal`); `data/ice_regions.json`
  (Baltic 12–3, Hudson Bay 11–4, White Sea 11–4); `LICENSE-NOTES.md`
  new ocean sections (per-source citations; facts, nothing vendored).
- **Done-when:** schemas exactly as A ratified (envelope plural ==
  basename → group 1 passes with zero validator edits); every region
  polygon closed + within bounds + sanity-checked against `world.png`
  water (self-check script or manual spot list in the report); sources
  recorded; `python3 tools/validate_data.py` exit 0 **as-is**.

### P — Neutral ports + regional lanes (`10-*` §7.1/§7.6 content; one writer)

- **Goal:** the monsoon world's destinations + topology, authored.
- **Docs:** §2.11/§2.11.1; `10-*` as unlocked (A).
- **Creates/changes:** `data/ports.json` +40–60 `nation_id: ""` ports
  (bands per §2.11; era-appropriate; zh/en names; produces/demands over
  the existing 20 goods; facilities per the pinned default; existing 100
  untouched); the `botany_bay` anachronism decision (re-place or
  re-role, one line of rationale in the report); `data/trade_routes.json`
  +5 lanes (§2.11.1, waypoint snap ≤ 2 discipline, chokepoint tags) +
  `hanseatic_north` winter variant avoiding the Baltic freeze; minimal
  `tools/route_overrides.json` additions only where a segment cannot be
  fixed in the source waypoints; `docs/10-*` §7.1/§7.6 list extensions
  (the new ids, after authoring); `LICENSE-NOTES.md` new port-region +
  lane sections.
- **Done-when (worktree-local):** content complete + self-checked
  (per-port lat/lon lands on water per the **new** world.png; per-lane
  segments walkable — use a local throwaway walk script, do not ship
  fixtures); **held unmerged until the W3 gate** (correction 10: the
  port/lane locks make a standalone merge red; the master merges P
  immediately before E at the W3 gate).

### E — Ocean builder + route-builder variants + validator groups 9–10 + lock amendments (tools only)

- **Goal:** rasters, variants, spokes, validation — the W3 green-maker.
- **Docs:** `10-*` schemas/groups (A); §2.2/§2.4/§2.8/§2.11.
- **Creates/changes:** `tools/build_ocean.py` (rasterize wind regions +
  currents at 4320×2160; overlap rule strongest-then-id-order;
  `--ascii`/`--report`; deterministic) → `data/maps/wind_regions.png` +
  `data/maps/currents.png` (two rebuilds byte-identical);
  `tools/build_routes.py` — lane `variants` (per-variant month-window
  passability as a hard build error naming the lane), nationless spoke
  fallback (nearest waypoint unbounded), `--report` **spoke-length
  distribution** (longest spokes + port/lane names); final rebuild of
  `trade_routes_built.json` over the merged P sources;
  `tools/validate_data.py` — **group 9** (rasters: palette bounds,
  water-coverage vs world.png, determinism) + **group 10** (ice/lane
  variants: month-window coverage, ice-crossing lanes carry variants) +
  group 8 id-set 12 → 17 + group 5 port lock amendment (sovereign-100
  exact + neutral tier rules, count 40–60); `autoload/data_loader.gd`
  registrations for the three new json files.
- **Done-when (at the W3 gate, after the master merges P):** validator
  exit 0 groups 1–10 incl. determinism; two `build_ocean.py` rebuilds
  byte-identical; junction-graph connectivity probes pass (Macau ↔
  Hirado, Busan → Hirado end, Mombasa spoke ≤ 40, `lima`/`valparaiso`/
  `guayaquil`/`panama` spokes shorten onto `pacific_america`,
  `safi`/`elmina`/`luanda` onto `west_africa`); the longest remaining
  spokes are the pinned intentional fringes; in-worktree self-test of
  builder/validator changes runs against throwaway fixtures in /tmp
  (none shipped); all suites green.

### F — `sailing_sim.gd` core + `ocean_layers.gd` (calendar, wind, factors, trim, wait)

- **Goal:** direction-aware sailing rules, pure + tested.
- **Docs:** `20-*` as amended (B); §2.1–§2.7.
- **Creates/changes:** `scripts/world/ocean_layers.gd` (new — decodes
  `wind_regions.png`/`currents.png` at load; ice polygon cache,
  month-keyed; lookups: region id, wind prevailing, current vector with
  reversal flip, ice-membership); `sailing_sim.gd` — calendar helpers
  (`year/month`), seeded wind-direction roll (stream order
  strength→direction), `direction_factor`/`current_factor` tables,
  `trim_factor` + storm-damage multiplier, `move_cost(heading)`,
  heading-less HUD speed at beam, wait action (`advance_clock(1.0)`),
  drift push (Drift mode, accumulator, impassable-stop, docked
  suppression), ice entry refusal + `world.ice_blocked` signal path;
  `game_state.gd` world-block defaults `sail_trim`/`heading`/`wind_dir`
  (correction 12); rework `tools/test_sailing.*`, `test_weather.*`,
  `test_movement.*`; new `tools/test_ocean.*` (wind roll determinism,
  factor tables, drift push, ice by month, trim effects).
- **Done-when:** all suites green incl. `test_ocean`; determinism proof
  (same seed → same direction sequence); no heading value ever leaves
  the 8-dir domain; `game_state.gd` writes only the three pinned keys.

### V — Save v6 + control prefs plumbing (one owner for the breaking bump)

- **Goal:** the phase's single breaking save moment, shipped whole.
- **Docs:** `90-*` §8.2 (A); §2.10; `80-*` rows (C).
- **Creates/changes:** `autoload/save_system.gd` — `SAVE_VERSION = 6`,
  `PHASE = 6`, v5 refused, key list + validation for `control_prefs`,
  `world.sail_trim`, `world.heading`, `world.wind_dir`;
  `autoload/game_state.gd` — `control_prefs` block (defaults
  Step+Modifier, `new_game` carry mirroring `npc_preset`);
  `scenes/ui_shared/settings_panel.{tscn,gd}` — two settings rows +
  **debug-overlays row** (`SettingsPanel.debug_overlays`, session-only
  static, correction 12/C contract); `tools/test_save_v5.*` → renamed
  `tools/test_save_v6.*`, reworked (round-trip incl. new keys; hunter
  keys carried, cell re-based; v5 refusal test).
- **Done-when:** save v6 round-trips every new key; a v5 payload is
  refused with the standard pre-release message; S19 rows flip
  `GameState.control_prefs` live; `debug_overlays` never enters a save
  payload (asserted); all suites green.

### G — `world_map.gd` UI: helm mode, trim/wait keys, interpolation, HUD (one owner for the world scene)

- **Goal:** the player-facing sailing surface.
- **Docs:** `20-*` §4.2/§4.4 ×; `80-*` (C); §2.5/§2.6/§2.9.
- **Creates/changes:** `scenes/world/world_map.gd` — helm mode
  (heading set/auto-step interval per §2.6, cancel seams on
  click-to-sail/battle/docking), trim `[`/`]` keys, Space semantics per
  correction 8 (wait / stop-then-wait), interpolated ship rendering in
  both modes (render-only offset; every rule reads tile positions);
  `scenes/ui_shared/hud.{tscn,gd}` — wind arrow + strength, current
  arrow, trim chip, Year·Month top bar; reads of new keys via the
  guard-call convention (`.get` with documented defaults) so the
  worktree is independent of V/F inits; helm/wait/trim cases added to
  `tools/test_world_map.*` / `test_movement.*` (owned jointly with F —
  see pins).
- **Done-when:** both input modes play end-to-end; interpolation never
  changes logic outcomes (suite: marker offset does not affect ledger,
  encounters, docking); HUD shows all §2.9 indicators; zero `<key>`
  fallbacks zh/en (strings via the orchestrator list); all suites green.

### H — `npc_fleets.gd` parity + seasonal variants + ice-aware stepping (one owner for the ecology)

- **Goal:** NPC fleets pay the same sea.
- **Docs:** `60-*` §4.11.11/§4.11.11.1 as amended (C); §2.8/§2.8.1.
- **Creates/changes:** `scripts/world/npc_fleets.gd` (+ `fleet_path.gd`
  if the pursuit window changes) — daily tile budgets ×
  `direction_factor`/`current_factor` per leg heading (pure
  day+position, no RNG), in-month variant selection (built paths),
  ice-aware lane stepping + pursuit (refused-entry rule), radii sweep
  verified at 30/40 (R set the constants; H verifies semantics),
  pursuit A* budget re-measured at the quadrupled area with windowing if
  failed (correction 13); probe suite: **no trader ever docks at a
  neutral port**; patrol/treasure/pirate presence on the 5 new lanes;
  rework Phase-5 lane-timing suites (`test_npc_fleets`,
  `test_ecology`, `test_aliveness`, `test_density`, `test_bounty`).
- **Done-when:** parity factor application proven per role (hunter
  regression: routes to last departed port, camps, chases only inside
  30, gives up at 40); variant flip observable across a month boundary
  (deterministic); day tick ≤ 50 ms @ 288 re-proven and recorded;
  pursuit budget verdict recorded; all suites green.

### I — Chart overlays + omniscient debug chart mode (one owner for the chart)

- **Goal:** the seasonal layers made visible, and the phase's sanity
  window.
- **Docs:** `80-*` (C); §2.9/§2.12.
- **Creates/changes:** `scenes/world/chart_screen.{tscn,gd}` +
  `scripts/world/chart_view.gd` — player toggles `W`/`C`/`I`
  (current-month wind arrows per region, current arrows, ice tint on
  explored tiles); S19-gated debug mode per §2.12 (`D` omniscient, live
  fleets/wrecks/hunter-intel, 17 lanes + spokes + chokepoints + legend,
  `,`/`.` month scrubber, info strip, `day_advanced` redraw trigger);
  gates on `SettingsPanel.debug_overlays` (C's contract — V owns the
  row; guard-read); new suite `tools/test_chart.*` (overlay state
  machines, debug read-only proof, scrub purity).
- **Done-when:** with the row off none of the debug layers are
  reachable; with it on the full §2.12 layer list renders; the month
  scrubber touches no `GameState` field (a save taken mid-preview
  round-trips identically — suite-asserted); no debug interaction
  mutates state; `debug.*` strings complete zh/en (orchestrator list);
  all suites green.

### J — Acceptance (master-led, dated manual run)

- **Goal:** `tools/demo_check_phase6.md` + this file's completion record.
- **Scenario (all recorded):** sail Lisbon→Canaries upwind vs downwind
  (different tile/day rates observed); tack by hand and beat the
  autopilot's straight line; wait out a storm reefed; ride the Gulf
  Stream north (modifier) and watch drift move the fleet (Drift mode);
  winter-close the Baltic and see `hanseatic_north` take its winter
  variant; **ride the summer monsoon to a neutral China-coast port and
  sell into its market** (signature loop); sight a patrol/treasure fleet
  on `canton_country_trade` and pirates camping `taiwan_strait`; draw a
  hunter to the last port, slip away, watch it camp the wrong harbor
  (rescaled radii); flip both toggles in S19 mid-run; zh/en parity.
- **Debug-chart sanity eyeball:** scrub month 1 vs 7 — monsoon wind
  arrows reverse, Baltic ice appears/disappears, `hanseatic_north` swaps
  variant, Somali flips; no lane crosses land; no port dot sits in open
  sea or permanent ice; neutral China-coast cluster visible; currents
  form coherent gyres; `taiwan_strait` diamonds; fleets dwell/dock on
  their lanes day over day.
- **Done-when:** every scenario recorded with version + results; the
  final-gate table below re-run and pasted; this file's completion
  record filled in.

---

## Task dependency note

A/B/C unblock everything (pure docs; nothing launches before W1 merges).
R and D need A only (schemas + enumeration tables). P needs A (§7.1/§7.6
unlocks) — and benefits from R's new world.png for self-checking
lat/lon→water, so P launches with W2 and is **held unmerged** until the
W3 gate (correction 10). E needs A (group specs) and to *integrate* D
(W2-merged) and P (merged at the W3 gate immediately before E); in its
worktree E self-tests with /tmp fixtures. F needs E (raster artifacts +
loader registrations) + R (constants) + B. V, G, H, I need F (factor
APIs) and E+P (built lanes/rasters for H, rasters for I); C's symbol
contracts make V/G/H/I mutually independent in parallel (guard-reads).
J needs all.

The critical path is A/B/C → R → E(integrating D, P) → F → {V,G,H,I} →
J: **six waves**.

## Shared-file pins (hard rule: one writer per file per wave)

- **W1:** A owns `docs/10-*`, `docs/90-*`, `docs/00-*`, `AGENTS.md`;
  B owns `docs/20-*`, `docs/30-*`; C owns `docs/40-*`, `docs/60-*`,
  `docs/70-*`, `docs/80-*` (+ the `IMPLEMENT-Phase5.md` stale-line
  sweep). Disjoint.
- **W2:** R owns `tools/build_world.py`, `tools/build_routes.py`,
  `tools/validate_data.py`, `tools/map_overrides.json`,
  `data/maps/world.png`, `data/maps/world_report.json`,
  `data/trade_routes_built.json`, `data/ship_types.json`,
  `scripts/world/{sailing_sim,sail_path,map_loader,npc_fleets}.gd`
  (constants only), `scripts/battle/**` (mp seam only),
  `scenes/world/world_map.gd` (wrap constants only) + every suite
  needing re-baseline. D owns `data/wind_regions.json`,
  `data/ocean_currents.json`, `data/ice_regions.json`,
  `LICENSE-NOTES.md` (new ocean sections). P owns `data/ports.json`,
  `data/trade_routes.json`, `tools/route_overrides.json`, `docs/10-*`
  (§7.1/§7.6 list extensions, appended after authoring),
  `LICENSE-NOTES.md` (new port/lane sections). Disjoint **except**
  `LICENSE-NOTES.md`: D and P append to *different new sections only*
  (line-additive; Phase-5 W2 D/E precedent), and `world_map.gd`/
  `npc_fleets.gd` are R-only within W2.
- **W3:** E owns `tools/build_ocean.py`, `tools/build_routes.py`,
  `tools/validate_data.py`, `data/maps/{wind_regions,currents}.png`,
  `data/trade_routes_built.json`, `autoload/data_loader.gd`. P's branch
  is merged by the master immediately before E — P writes nothing
  further unless the gate bounces a fix back into its (still-open)
  worktree.
- **W4:** F owns `scripts/world/ocean_layers.gd` (new),
  `scripts/world/sailing_sim.gd`, `autoload/game_state.gd` (world-block
  defaults only), `tools/test_{sailing,weather,movement,ocean}.*`.
  Single-task wave.
- **W5:** V owns `autoload/{save_system,game_state}.gd` (`control_prefs`
  + v6 keys), `scenes/ui_shared/settings_panel.*`,
  `tools/test_save_v6.*` (renamed from v5). G owns
  `scenes/world/world_map.{tscn,gd}`, `scenes/ui_shared/hud.*`,
  `tools/test_world_map.*` (its new cases). H owns
  `scripts/world/npc_fleets.gd`, `scripts/world/fleet_path.gd`,
  `tools/test_{npc_fleets,ecology,aliveness,density,bounty}.*`. I owns
  `scenes/world/chart_screen.*`, `scripts/world/chart_view.gd`,
  `tools/test_chart.*` (new). Disjoint; cross-worktree reads use C's
  symbol contracts + the guard-call convention (correction 12).
  W4/W5 note: `test_movement.*` is F-written (W4); G's helm cadence
  cases go in `test_world_map.*` — no shared suite files in W5.
- **`data/ui_strings.json` is orchestrator-owned** (Phase-4/5 protocol):
  every task lists its zh/en keys in its report; the master merges after
  each wave. No subagent edits it directly.

## Subagent execution plan (max 4 background subagents, one worktree each)

Same protocol as Phases 3–5: the master owns the base branch, creates
and removes one named worktree per subagent
(`tools.opencode.worktree_create`), launches tasks as background
subagents with full-context prompts, merges every branch itself, and
runs the validator + full suite at each wave gate. Numbers not in the
locked tables are invented by no one (`00-*` §13 applies to subagents
first); the master pins task-owned numbers in the owning doc before
launch where a task depends on another's symbol (C's contracts).

| Wave | Launch (parallel) | Merge & gate |
|---|---|---|
| W1 | A, B, C | master merges all three; gate: docs greps per done-when; tree untouched outside docs/`AGENTS.md` |
| W2 | R, D, P | master merges **R and D**; gate: validator exit 0 (groups 1–8 @ 4320², rebuilds byte-identical), all suites green. **P's branch is held unmerged** (kept in its worktree; correction 10) |
| W3 | E | master merges **P, then E**; gate (once, after both): validator exit 0 groups 1–10, `build_ocean.py` + `build_routes.py` rebuilds byte-identical, connectivity probes + spoke report per E's done-when, all suites green. Fix bounces return to the still-open P/E worktrees |
| W4 | F | gate: all suites green incl. `test_ocean`; determinism proof recorded |
| W5 | V, G, H, I | master merges all four; gate: all suites green (37+ suites incl. `test_save_v6`, `test_chart`); perf: day tick ≤ 50 ms @ 288 recorded; zh/en key parity (orchestrator merge) |
| W6 | J (master-led) | acceptance record + completion record in this file; final gates re-run |

- **Peak concurrency: 4 subagents (W5)**; W1/W2 run 3, W3/W4 run 1
  critical-path task. Worktrees open at once never exceed 4: W3 has P
  (held) + E (live) + master verification slot.
- **Held-branch rule (new, correction 10):** a branch is held only when
  the lock model makes a standalone merge unverifiable — never as a
  convenience. Held branches are named in the wave table and merged at
  the next gate, before the gating task.
- **No sanctioned red window** (Phase-5 rule): every wave gate runs on a
  fully merged, fully green tree. Intra-gate merge order within W3 is
  pinned (P → E) precisely so the *gate* state is green.
- **Fourth worktree slot** outside W5 stays reserved for master-side
  merge verification or ad-hoc repair — never a fifth content task.
- Subagent prompts must carry: this file's path, the task letter, its
  docs, the locked-constants pointer, the done-when list, the
  shared-file ownership list, the ui_strings reporting duty, and the
  wave gate (incl. held-branch status for P).
- J is master-led (dated manual run), as in every phase.

## Risks & pinned mitigations

| Risk | Pinned mitigation |
|---|---|
| Missed constant in the rescale sweep | enumeration tables ratified by A/B/C first; R's done-when is a symbol-named grep checklist (§2.0) incl. the npc_fleets key-packing break (correction 6); full-suite re-baseline in R's own wave |
| A* full-stage cost at 9.33 M cells | shipped two-stage design covers all legal clicks (correction 3); R measures and records; 1 s budget + pinned escape hatch stand; rework only on measured failure |
| Hunter pursuit A* at 4× area blows 250 ms/day | H re-measures first; windowed region (sail_path near-stage pattern) only on measured failure (correction 13) |
| Combat mp silently doubles with world speed | `battle_mp = speed / 4` pinned by C (decision 5), implemented by R, one seam, suite-verified |
| P's content vs validator locks (red merge) | held-branch protocol + pinned W3 merge order P → E (correction 10); no wave gates red |
| New data files fail group 1 before E lands them | envelope plural == basename (correction 9) — D merges green standalone |
| Determinism under new daily rolls | wind direction joins the existing seeded weather stream (order strength→direction pinned); NPC factors are pure day+position functions |
| Ice freezing on top of the fleet | entering-vs-standing rule (§2.7); A*/lane stepping use in-month ice passability |
| Helm/Space/Esc key conflicts | resolved by correction 8 and pinned identically in B (20-*) and C (80-*) before any code |
| Interpolated rendering desyncs from logic | rendering-only offset; every rule reads tile positions; G's suite asserts the offset never changes outcomes; no sub-tile value is ever saved |
| W5 cross-worktree symbol drift | C pins exact symbols (`SettingsPanel.debug_overlays`, guard-call defaults) in W1; W5 prompts quote them |
| Regional lanes fail the passability walk at 5 nm | Phase-5 discipline: waypoint snap ≤ 2, per-segment walk, hand fixes via `route_overrides.json`; broken segment = hard build error naming the lane |
| New lanes leak trader traffic to neutral ports | `nations` tags + own-nation docking pin; H probe-tests; documented frontier state is intentional |
| Neutral ports break harbor/lane derivation | harbor pairs are derived, not stored; group 6 + spoke coverage re-run at R and E gates; no-spoke port = hard build error |
| Economy abuse at player-only frontier markets | tranche repricing + drift self-limit dumps (Phase-5 mechanics); local traffic is the designated later-phase fix, not this phase's bug |
| Perf (HUD/day-tick/decodes) | all lookups O(1) raster reads / small polygon caches; day tick ≤ 50 ms @ 288 re-proven in H; PNG decode cost measured in F |
| Debug chart drifts from game truth | pure read-only observer of live state + shipped data; recomputes nothing, mutates nothing; S19 gate session-only (correction 12) |
| Save breakage mid-phase | all of save v6 in one owner (V, correction 14); dev-stage "never load a previous-phase save" documented on this file |

## Out of scope (Phase-7 candidates)

Monsoon-timed trade voyages and courier quest hooks; wind-aware
autopilot; **chart-click long-distance autopilot** (needs the
hierarchical router this phase deliberately does not build); sail wear;
NPC provisions/weather consumption; storm drift for the player (glossary
line stays prose); **local nations for neutral ports** (own fleets,
budgets, diplomacy, markets beyond the player); **new trade goods**
(would re-cut the validator-asserted 5/10/5 tier split).

---

## Completion record

*(Filled in by task J.)*

| Wave | Tasks | Result |
|---|---|---|
| W1 | A, B, C | ☐ |
| W2 | R, D (merged), P (held) | ☐ |
| W3 | P → E | ☐ |
| W4 | F | ☐ |
| W5 | V, G, H, I | ☐ |
| W6 | J | ☐ |

### Final gate

| Check | Result |
|---|---|
| `python3 tools/validate_data.py` (groups 1–10) | ☐ |
| `python3 tools/build_world.py` / `build_routes.py` / `build_ocean.py` (rebuilds byte-identical) | ☐ |
| suites (`tools/run_tests.py`, counts recorded) | ☐ |
| `godot --headless --quit-after 3` clean | ☐ |
| day tick @ 288 ≤ 50 ms; pursuit budget verdict | ☐ |
| locale zh/en parity, zero `<key>` fallbacks | ☐ |
| save payload size ≤ 2 MB @ extreme | ☐ |
| demo loop (`00-*` §7) end-to-end at the new scale | ☐ |
| `tools/demo_check_phase6.md` scenario + debug-chart sanity record | ☐ |
