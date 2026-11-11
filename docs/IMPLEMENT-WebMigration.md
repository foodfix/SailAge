# IMPLEMENT — Web-Stack Migration (Godot → Python/FastAPI + React)

Provenance: user-locked plan of 2026-11-11 (`~/.opencode/plan/web-stack-migration.md`),
copied into the repo as the delivery ledger per `00-OVERVIEW.md` §5's phase-ledger
note. Status: design settled (direction + 4 shape decisions user-locked
2026-11-11). This program supersedes the Godot runtime as the delivery target;
it does NOT touch the design docs' game-design content (world, economy,
combat rules stay as specified). Normative architecture: `90-ARCHITECTURE.md` §0.

## 1. Locked decisions (user, 2026-11-11)

1. **Full rewrite, not strangler.** One clean cut to the new stack; the
   Godot tree is frozen read-only as oracle until the M6 cutover, then
   deleted. No incremental dual-stack shipping.
2. **Frontend = SPA**, not server-rendered pages. React + TypeScript,
   locked as the default with rationale (sample density).
3. **Keep the Phase-10 UI PNGs** (317 files, `tools/build_ui_art.py`
   output) as plain static assets. What is discarded is the Godot
   *wrapper* (theme/tres, `palette.gd`/`ui_kit.gd` runtime), not the
   bitmaps.
4. **Deployment = local uvicorn + browser.** Server binds 127.0.0.1,
   single command (`python -m server` or `run.sh`) opens the game.
   Multiplayer remains out of scope (`00-OVERVIEW.md` line 58 stands).
5. **Derived defaults, locked 2026-11-11:**
   - React over Vue — sample density is the entire motivation for this
     migration; pick the densest corpus.
   - Server-authoritative tick. ALL game rules live in Python under
     pytest. The TS client is a pure renderer + intent sender (no
     movement rules, no economy math, no AI in TS). State streams over
     one WebSocket; menu/port interactions may use plain HTTP actions.
     Precedent: the `90-*` §5.7 layout-bridge protocol was frozen before
     either end was written — same discipline here.
   - canvas 2D first; pixi.js/WebGL is deferred until the waterline VFX
     phase (parking lot) demands it.

## 2. Current-state facts (verified 2026-11-11)

| Asset | Size | Disposition |
|---|---|---|
| Runtime GDScript (`autoload/` 3,976 + `scripts/` 31,429 + `scenes/` 33,848) | 89 files, ~69.3k lines | translate → Python (`server/`), delete at M6 |
| Test/harness GDScript (`tools/*.gd`) | 79 files, 67.7k lines | spec for pytest port; delete at M6 |
| Python tools (`tools/*.py`, stdlib-only) | 18 files, 28.9k lines | keep unchanged |
| Content + rasters (`data/**`) | all JSON + generated PNG/JSON | keep 100% |
| UI art PNGs (`assets/ui/**`) | 317 PNGs | keep, served statically |
| Scenes (`*.tscn`) + `.import` | 112 tscn | delete at M6 |
| Model studio (`tools/model_studio/`) | server.py 2,030 (stdlib http.server) + studio.js 1,396 | keep; proves the local-server workflow |
| `data/ui_layout.json` (v2, Phase 12) | 8 port screens, every static rect | port spec for M3, then retired (`10-*` §4.23 disposition) |
| Perf record | day tick 72 ms ≤ 75 @ measured fleet count (318 fleets, Phase 8: 68 ms) | re-measured in M1 for Python |
| Combat AI | T3 @ `ai_level=1`, CEM-finalized θ (Phase 9) | θ ports verbatim; golden-trace gate in M5 |

## 3. Milestones

| M | Deliverable | Done-when |
|---|---|---|
| **M0** | Doc amendments FIRST (the §5 list); repo scaffold `server/` + `web/` (empty shells, pinned `server/requirements.txt` — FastAPI domain, separate from the stdlib-purist `tools/`); freeze WS protocol table + new numbers (`90-*` §0) | every cross-citation resolves; protocol table frozen verbatim in `90-*` |
| **M1** | Sim core port: all systems (world, sailing, trade/economy, character/officers, combat rules, quests) → `server/sim/` + pytest suites porting every pinned contract from the 79 GDScript test files. **Week-1 spike:** day tick at the 318-fleet scenario; numpy allowed for the runtime server if the budget needs it | parity assertions green; Python day-tick budget measured + the number amended into `90-*` §0.5 |
| **M2** | FastAPI shell: state store, action endpoints, WS stream, save v1 round-trip, headless API smoke of the demo loop | contract tests green; save round-trip test green |
| **M3** | React shell + the 8 port screens (spec = `ui_layout.json` rects + `ui_strings.json`); 317 PNGs wired as static sprite assets; palette constants from `80-*` §4.8 become CSS tokens | i18n lint green with empty allowlist; each screen functionally replaces its Godot counterpart |
| **M4** | `tools/build_web_tiles.py` + canvas world map + sailing loop + HUD; demo-probe sailing scenario playable end-to-end | rebuild byte-identical ×2; probe scenario ALL PASS via browser |
| **M5** | Combat canvas + AI port; θ verbatim; golden traces recorded from the GDScript harness act as oracle | golden-trace diff clean; battle acceptance suite green |
| **M6** | Remaining screens (title, creation, discovery log, quest UI, endgame), full demo loop, **cutover**: delete Godot runtime (`scenes/ scripts/ autoload/ *.tscn *.import project.godot`), retire `.gd`-referencing validator groups by explicit list, update `AGENTS.md` | full demo loop in browser; suite count recorded; deletion list executed |

Execution protocol per `AGENTS.md` where parallelizable: ≤ 4 background
sub-agents per wave, one worktree + branch each, master merges with the
validator + suite gates after each merge. M1–M3 slots are largely
file-disjoint after M0.

## 4. Asset disposition summary

- **Keep as-is:** `data/**`, `tools/*.py`, `assets/**` (317 PNGs),
  `docs/` game-design content, `tools/model_studio/`.
- **Translate (old = spec, retired at M6):** runtime GDScript →
  `server/sim/`; GDScript tests → pytest (expect major shrinkage — port
  the guarantee, not the method); `ui_layout.json` → component structure;
  `palette.gd` constants → CSS tokens.
- **Delete at M6:** Godot runtime tree, `.tscn`, `.import`, GDScript test
  harnesses, Godot-era save format.

## 5. M0 doc amendment inventory (landed 2026-11-11)

- `90-ARCHITECTURE.md` §0 — the normative web-era architecture: the
  FROZEN WS protocol table (§0.3), the HTTP action shape (§0.4), the
  frozen numbers (§0.5: `SIM_TICK_HZ` = 10, `WS_BROADCAST_HZ` = 10 —
  confirmed against sailing feel in M4 then frozen verbatim; server bind
  `127.0.0.1:8000`; save profile dir `~/.sailage/` with the
  `SAILAGE_HOME` test override; `SAVE_VERSION` = 1, no migration chain;
  day-tick budget ≤ 75 ms placeholder until the M1 measurement amends it;
  the `server/requirements.txt` == -pin policy), and §0.6 — the
  Godot-era sections' frozen-oracle-until-M6 status.
- `00-OVERVIEW.md` — vision stack note, phase-ledger note, Engine
  locked-decision row, §11 language conventions (Python/TS), doc-map row.
- `10-DATA-SCHEMA.md` — §4.23 web-era disposition (port spec at M3,
  retired at M6), §6.8 web tile pyramids (frozen spec: 256 px tiles,
  z 0–3, nearest-neighbour downsample, stdlib PNG writer, committed,
  byte-identical ×2), §8 group-15 row + §8.10 normative spec (activates
  in M4 with the tool), §2 artifact rows.
- `80-UI-UX.md` — "React realization" notes on §4.8.9 (absolute tile
  placement → CSS, lists → clipped viewports, no-flow rule carries over)
  and §4.9 (palette hexes → CSS tokens, nine-patch sheets → border-image,
  atoms → TSX components, styling-audit equivalent with empty allowlist).
- `docs/IMPLEMENT-WebMigration.md` — this ledger.

## 6. Acceptance records

### M0 — 2026-11-11

- Doc amendments as inventoried in §5; `python3 tools/validate_data.py`
  exit 0 (data untouched); every new cross-citation (`90-*` §0.x,
  `10-*` §6.8, §8.10) resolves to a written section.
- Scaffold landed: `server/` package shell (app/ws/save/sim/api/tests
  docstrings pinning their milestone) + pinned `server/requirements.txt`
  (installed and import-verified on Python 3.14); `web/` Vite + React 18
  + TypeScript shell with pinned `package.json` + committed lockfile
  (`npm install` + `vite build` verified).
- WS protocol table frozen verbatim at `90-ARCHITECTURE.md` §0.3.

### M1 — 2026-11-11

**Delivered:** every Godot-era sim system ported to `server/sim/` with pytest
parity suites (port the guarantee, not the method), plus save v1 and the
frozen perf number:

| Area | Modules | Parity evidence |
|---|---|---|
| Foundation | `rng.py` (Godot PCG32, bit-exact) · `data.py` (DataLoader) · `world/raster.py` (world/ocean/ice/dist_land decode + harbors) | RNG truth tables captured from the live Godot 4.7 oracle; raster lookups pinned against builder reports |
| World | `sailing.py` (ledger/weather/morale/mutiny/movement/trim/currents/ice/docking/port hours) · `sail_path.py` (A*, dateline shift) · `npc_fleets.py` + `npc_intel.py` (8-role ecology, lanes, convoys, wrecks, hunters) · `captains.py` · `interactions.py` · `hail_options.py` · `autopilot.py` · `discovery.py` · `advice.py` · `arrow_field.py` · `fleet_path.py` | Seeded replays; weather strength→direction order pinned; 319-fleet tick measured |
| Port/economy | `trade.py` · `economy.py` · `allegiance.py` · `shipyard.py` · `tavern.py` · `inn.py` · `palace.py` | Doc-table prices (300-unit London sale 5,170g); golden 360-day event replay + month-31/61 counter-investment replayed from the oracle |
| Person/fleet | `player/character.py` · `skills.py` · `fame.py` · `fleet/fleet.py` | Closed-form XP/loyalty/title boundaries; hold maths |
| Quests | `quest_gen.py` · `bounty.py` · `phase3_hooks.py` | Offer lists cross-checked row-for-row against the live oracle |
| Combat | `battle_sim.py` · `battle_result.py` · `battle_rewards.py` · `ai_fleet.py` · `ai_search.py` (θ verbatim) · `fleet_commander.py` · `duel.py` | Decompose/duel/log/surrender traces byte-identical to the oracle incl. final `rng.state` |
| Integration | `state.py` (the §5.4 GameState + new_game + pinned tick chain) · `save.py` (v1, profile dir, explored-RLE) | Round-trip green; refusal matrix (no migration chain) |

**Perf (week-1 spike, amended into `90-ARCHITECTURE.md` §0.5):** the full
day tick at **334 fleets** (above the Phase-8 318 count) — **mean 45.7 ms ·
median 44.8 · p95 60.8 · max 84.7** (a spawn-day spike), deterministic
seeds, `python -m server.perf_day_tick`. Inside the frozen ≤ 75 ms budget;
numpy was not needed.

**Gates:** `server/tests` 957 passed · `tools/validate_data.py` groups 1–15
green, including group 15 (web tile pyramids, pulled forward from M4:
876 committed tiles, byte-identical double rebuild).

**Reported doc ambiguities (resolved in code per the oracle; no doc edits
needed yet):** the §5 worked cannon example predates the broadside split;
`30-*` §4.7's `< 100` relief row is stale vs the amended `10-*` §5
(`< 1200`); `60-*` §4.9b prose says `assigned_target` is a unit while the
oracle/consumer carry the fleet index; the `phase` payload stamp is `"web"`
for the web era (state.py keeps the Godot `PHASE = 9` constant unused by
`save.py`).
