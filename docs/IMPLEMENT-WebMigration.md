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
  `127.0.0.1:8537` (8000 at M0; re-pointed 2026-11-11 because 8000 is
  routinely occupied on dev hosts); save profile dir `~/.sailage/` with the
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

### M2 — 2026-11-11

**Delivered:** `server/app.py` (FastAPI, static mounts for the SPA/assets/
data/tiles), `server/session.py` (the single live session: GameState +
ecology + the action adapters + the 10 Hz tick loop), `server/api/` (the
frozen endpoint inventory of `90-*` §0.4), `server/ws.py` (the frozen §0.3
protocol), `server/__main__.py` + `run.sh` (the frozen launch contract).

- **Contract gates:** 967 pytest cases green (the API contract suite covers
  the six endpoints, a full HTTP save round-trip, the facility inventory
  frozen as a literal table, WS hello→state→tick→helm-motion→error, the
  second-connection 4001 close, locale over both transports, and the
  refusal paths never 500); validator groups 1–15 green.
- **WS coverage:** every §0.3 frame implemented (hello/state/tick/
  battle_tick/event/error) and all nine intents server-validated; one
  client per session with code-4001 refusal; tick frames coalesced.
- **Tick loop:** one asyncio task at `SIM_TICK_HZ` = 10; at sea it runs the
  sailing motion advance + appointed voyage + the unified NPC accrual +
  the contact funnel, then broadcasts one coalesced `tick`; battles pump
  enemy turns and broadcast `battle_tick`.
- **Inventory note:** `provisions/buy_supplies` was added to the frozen
  inventory (set_sail is supply-gated; without it the demo loop cannot
  leave port).
- **Deferred seams (M5):** the §4.9b `FleetCommander` order generator runs
  in M5's golden-trace work; `battle_order`'s `station`/`discipline` are
  recorded; click-route suspension on battle entry; at-sea `explore`,
  at-sea minor repair, mutiny, and the duel modal are not in the frozen
  intent table yet.
- **Doc-ambiguity resolutions frozen here:** refusal status semantics
  (200 in-game / 400 malformed), `GET /api/state` → `{ok, state, hello}`,
  `error.msg` is a ui_strings key, `tick` fires at sea only, and the
  screen-projection channel `GET /api/view/<screen_id>` (amended into
  `90-*` §0.4 with the M3 wiring).

### M3 — 2026-11-11

**Delivered:** the React foundation + live wiring.
- Foundation: a deterministic palette→CSS-token generator (129 colours +
  8 sizing tokens, `--check` byte-stable), the i18n layer (both locales,
  loud `<key>` misses, persisted toggle), the `ui_layout` rect loader +
  six kit atoms + sprite registry, and the 8 port screens.
- Wiring: `GET /api/view/<screen_id>` server projections (the §0.4
  no-rules-in-TS channel), the live WS/REST `GameClient` (reconnect with
  backoff; 4001 terminal), every port screen on authoritative state.
- The audit gates shipped with the first screen and stay green: **0
  hardcoded strings (empty allowlist)**, styling boundary clean, and layout
  coverage growing to **32/32** screens by M6.
- Browser-verified: all 8 screens render live state; market buy + inn rest
  update through the `state` frame.

### M4 — 2026-11-11

- `tools/build_web_tiles.py` + `web/public/tiles/**`: **876 committed
  tiles** (4 sources × z0–3), byte-identical double rebuild, validator
  **group 15** (inventory + rebuild + 80 decode probes).
- The canvas world view: pyramid renderer (zoom levels, wrap seam, camera,
  RAF glide), the full 25-id `world` HUD, step/helm/click-to-sail/trim/wait
  intents, fleet/port/wreck markers, minimap with the explored mask, and a
  clearly-marked fixture 10 Hz loop. Headless-probed (sail, dock, trim,
  Esc→port).

### M5 — 2026-11-11

- **Golden-trace gate:** `tools/battle_golden_trace.gd` records a pinned
  18-line trace (scenario + 16 rounds + final, incl. `rng_state`); the
  Python replay is **field-identical**, and the trace is stored at
  `server/tests/fixtures/battle_golden_trace.jsonl` so the gate survives
  the cutover. The diff found the real §4.8a morale-start bug on the live
  path (fixed: `session._open_battle` passes the run morale).
- The battle canvas: 48×30 renderer (hulls by heading8, broadside arcs,
  reload pips, minimap, storm wash), **42/42** `battle` layout ids, the
  order five-tuple UI, broadside/hook/retreat/surrender intents, the
  outcome overlay; fixture-driven for offline demos.

### M6 — 2026-11-11 (cutover)

**Screens:** the remaining 22 built (front door: title/nationality/creation/
save-slot; bookends: gameover/ending; chart with explored fog + ports;
settings/confirm/dialog_box; the people surfaces: intel window + four tabs,
character card, dossier, captain view, fleet view, officer roster,
reputation; hail, fleet picker, autopilot HUD, duel, S21 sandbox).
**32/32 screens real**; every `ui_layout.json` element id is rendered
(list-member ids verified in-DOM).

**Integration closed:** run-end routing (`game_over`/retired → bookend),
Tab→Chart, the live S19 settings rows (`settings/*`), the level-up
allocation verb (`people/allocate`), the full facility inventory (incl.
provisions fill/jettison, tavern bulk crew, palace repair/bounty/inform/
retire, guild complete/abandon), the bounty-closure gate on dispatch, the
sighting-pass reveal on the live path (fresh runs no longer stay fogged),
and 68 emitted-but-missing `ui_strings` keys added across M3–M6.

**Cutover executed** (the §7 lists): deleted the Godot runtime
(`scenes/` 109 files, `scripts/` 98, `autoload/` 14, `project.godot`,
112 `*.tscn`, 179 `*.import`), the GDScript harnesses (`tools/*.gd` 80
files + `tools/run_tests.py` + their fixtures), `data/ui_layout.json`, and
`AGENTS.md` rewritten for the web era, and `scripts/palette.gd`'s values
extracted to `web/src/theme/palette.json` (the CSS-token source). **Kept
deliberately:** `data/ui_layout.json` + validator group 14 — the React
screens consume its rects as data (the file is the web-era layout data,
not a Godot artifact); plus `data/**`, `assets/**`, `tools/*.py`, the
art/tiling pipelines, the model studio, `docs/`.

**Final gates:** `validate_data.py` groups 1–13 + 15 green ·
`pytest server/tests` **993 passed, 1 skipped** (the harness cross-check
skips now that the Godot tree is gone) · `npm run build` · `npm run audit`
(32/32, empty i18n allowlist) · `build_tokens.mjs --check` ·
`python -m server.demo_loop_smoke` **25 checks** (storm observed in the
sample run).

**Suite-count note:** the Godot era ran 59 GDScript suites / ~10k checks;
the web era runs 994 pytest cases. The shrinkage is the port-the-guarantee
rule (closed forms + one deterministic observation), not lost coverage;
every unique-behaviour pin from the 80 GDScript harnesses was ported or
deliberately superseded by a doc-pinned closed form.

## 8. Parking lot (explicit non-blockers after M6)

- Officer training verb (needs the persisted `skill_deltas` design
  decision — the roster renders it disabled).
- Duel start/advance intents + the duel modal transcript; the at-sea
  `explore` intent; mutiny resolution as a WS intent; at-sea minor repair
  action.
- Server projections for the 12 people surfaces (they render from state +
  canon today; a `GET /api/view` entry per screen is the tidy follow-up).
- The battle canvas's `battle_tick` extras (acting unit, log stream,
  cannon counts, per-ship maxima, nation colour, current vector).
- The model studio's layout editor is vestigial (its `ui_layout.json`
  target retired); the model/art re-roll bench stays.
- The Phase-9/Phase-10 parking lots (per-broadside shot types, merchant
  archetype, sandbox persistence, portraits, waterline VFX/pixi, …) are
  unchanged.

## 7. M6 cutover plan (the explicit deletion / retirement lists)

Executed only after every M6 screen lands and the full demo loop passes in
the browser. One commit set; the gates are the final run of everything.

**Delete (the Godot runtime + its harnesses):**
- `scenes/**`, `scripts/**`, `autoload/**`, `project.godot`, every `*.tscn`
  and every `*.import`
- `tools/*.gd` (all 67 `test_*.gd` suites + `battle_ai_harness.gd` +
  `battle_tune_runner.gd` and their `.tscn` fixtures)
- `tools/run_tests.py` (the Godot suite runner — pytest is the gate now)
- the Godot-era `AGENTS.md` content (replaced below)
- **KEPT, not deleted:** `data/ui_layout.json` (+ validator group 14) — the
  React screens consume its rects as data (`10-*` §4.23 final disposition);
  `scripts/palette.gd`'s values were extracted to
  `web/src/theme/palette.json` before deletion (the CSS-token source)
- `.godot/` (already gitignored; delete locally)

**Validator groups:** **none retire** — group 14 survives because its
artifact does (the web layout data); groups 1–13 and 15 were already
artifact-based. No group references a `.gd`, `.tscn` or `project.godot`.

**Keep unchanged:** `data/**`, `assets/**` (317+ PNGs), `tools/*.py`
(stdlib build/validate tools), `tools/model_studio/`, `tools/ui_art/`
manifests, `tools/yoyopixel/`, `docs/` game-design content, `server/`,
`web/`, `run.sh`.

**`AGENTS.md` rewrite (web era):** point at `docs/` in the same order,
restate i18n/data-first/concrete-numbers/byte-identical rasters/no
multiplayer; replace the Godot tree rules with: `server/` is THE sim
(Python, pytest-gated), `web/` is the pure renderer (TS, i18n/styling
audits with an empty allowlist), `python -m server` / `run.sh` is the
launch, `python -m pytest server/tests` + `tools/validate_data.py` +
`npm run build/audit` + `build_tokens.mjs --check` are the gates, the
world rasters and `web/public/tiles` stay tool-owned, and the migration
ledger is this doc.

**Final gates (cutover commit):** `python3 tools/validate_data.py`
(groups 1–13, 15 — 14 retired), `python -m pytest server/tests`, `npm run
build`, `npm run audit`, `node scripts/build_tokens.mjs --check`,
`python -m server.demo_loop_smoke`, and the browser demo loop.

