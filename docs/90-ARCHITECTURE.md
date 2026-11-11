# 90 — Architecture

## 0. Stack transition — the web-stack era (2026-11-11, user-locked; FROZEN in M0)

**This section is the normative architecture from M0 onward.** The delivery
target moved from the Godot runtime to a Python/FastAPI server sim plus a
React/TypeScript SPA (the full program and its acceptance records live in
`docs/IMPLEMENT-WebMigration.md`). It does **not** change any game-design
content: world, sailing, economy, combat and quest rules stay exactly as
their owning system docs specify — the rewrite is a translation exercise
with the Godot tree as oracle, not a re-design.

### 0.1 Locked direction (user, 2026-11-11)

1. **Full rewrite, not strangler.** One clean cut; the Godot tree is frozen
   read-only as the parity oracle until the M6 cutover, then deleted
   (scenes/ scripts/ autoload/ *.tscn *.import project.godot, plus the
   GDScript test harnesses). No incremental dual-stack shipping.
2. **Frontend = SPA.** React + TypeScript (React over Vue: sample density is
   the entire motivation for the migration). canvas 2D first; pixi.js/WebGL
   is deferred to the parking-lot waterline-VFX phase.
3. **Keep the Phase-10 UI PNGs** (317 files, `tools/build_ui_art.py` output)
   as plain static assets. What is discarded is the Godot *wrapper*
   (theme/tres, `palette.gd`/`ui_kit.gd` runtime), not the bitmaps.
4. **Deployment = local uvicorn + browser.** Server binds `127.0.0.1`,
   single command (`python -m server`, or `run.sh`) opens the game.
   Multiplayer remains out of scope (`00-*` §5 stands).
5. **Server-authoritative.** ALL game rules live in Python under pytest.
   The TS client is a pure renderer + intent sender: no movement rules, no
   economy math, no AI in TS. State streams over one WebSocket; menu/port
   interactions use plain HTTP actions. (Precedent: the §5.7 layout-bridge
   protocol was frozen before either end was written — same discipline.)

### 0.2 Target project layout

```
server/                     Python package (FastAPI) — THE sim
  app.py                    127.0.0.1 bind, static mount for web/ build + assets/
  sim/                      world, sailing, trade, character, combat, quests
  api/                      REST actions (menus, port screens)
  ws.py                     one-client WebSocket: state stream + intents
  save.py                   save v1 (§0.5; no migration chain)
  tests/                    pytest parity suites (M1 output)
web/                        React + TypeScript + Vite SPA — pure presentation
  src/screens/              port, market, inn, guild, provisions, palace,
                            tavern, shipyard, title, creation, …
  src/canvas/world/         sailing view (tile consumer + RAF renderer)
  src/canvas/battle/        combat view
  src/i18n/                 loads data/ui_strings.json + content JSON dicts
data/  tools/  assets/  docs/   unchanged owners
```

- **State & tick.** Single-player, single session: game state lives in the
  server process. A fixed-rate sim tick advances sailing/battle frames;
  state frames broadcast over WS (rates frozen in §0.5). Day cadence and
  every rule constant stay owned by `20-*`/`40-*`/`30-*`/`50-*`/`60-*` —
  no invented numbers.
- **Intent vs action.** Real-time intents (helm, sail setting, battle
  orders) go over WS (§0.3); discrete actions (buy, sell, talk, board,
  save) are HTTP POSTs (§0.4) returning the new authoritative state.
- **i18n.** Unchanged rule, wider reach: every player-facing string stays a
  `{"zh","en"}` JSON entry (`10-*` §3.3). The server serves them; TSX
  renders them. The M3 lint gate keeps TSX free of hardcoded strings,
  allowlist empty — the `test_ui_styling_audit` culture transplanted.
- **Tiles.** `tools/build_web_tiles.py` slices the four world rasters
  (`world.png` + `wind_regions.png` + `currents.png` + `dist_land.png`) into
  web-servable tile pyramids — spec `10-*` §6.8; two builds byte-identical
  (validator group 15). The runtime never hand-edits rasters — unchanged.
- **The model studio stays separate** (`tools/model_studio/`): its own
  process, never merged into the game server (explicit non-blocker).

### 0.3 The one-client WebSocket protocol (FROZEN verbatim — amend this table, never the code first)

**Transport (frozen):**

- URL `ws://127.0.0.1:{port}/ws` — same port as the HTTP server (§0.5).
  One WebSocket per session.
- Frames are JSON text, one object per frame: `{"type": "<name>", …}` —
  payload keys inlined at the top level (the §5.7 LayoutBridge convention).
- **One client:** a second concurrent WebSocket connection is refused —
  the server closes it with close code `4001`. The first connection is
  authoritative; a reconnect re-handshakes (`hello` is re-sent).
- **Backpressure:** at most one `tick`/`battle_tick` frame per sim tick;
  if a client falls behind, queued tick frames are coalesced (the newest
  wins) — `state`/`event` frames are never dropped.

**Server → client (frozen):**

| type | Payload (frozen keys) | When |
|---|---|---|
| `hello` | `{save_version, tick_hz, broadcast_hz, locale, has_run, current_screen, saves:[{slot, day, nation_id, port_id, gold, saved_at}]}` | first frame on connect |
| `state` | the full authoritative snapshot — the §8.1-shaped save payload plus the transient keys (`pending_encounter`, `npc_port_log`, levelup toast state); replaces client state wholesale | on connect, after every HTTP action, after new_game/load/locale change |
| `tick` | `{day, clock_min, position:{x,y}, heading, sail_trim, wind_dir, weather, speed, gold, morale, autopilot, contact_hint}` — the sailing slice | every sim tick while a run is live at sea (10 Hz) |
| `battle_tick` | `{round, phase, ships:[{id, side, kind, position, velocity, heading8, hull, crew, morale, reload:{port, starboard}}], wind, weather, orders_due}` — the battle slice | every sim tick during a battle (10 Hz) |
| `event` | `{name, args}` — `name` mirrors the §5.1 EventBus table verbatim (`day_advanced`, `gold_changed`, `port_entered`, `game_over`, `battle_started`, `battle_finished`, `quests_changed`, …) | on the corresponding server-side transition |
| `error` | `{code, msg}` | refused/unknown/malformed intent — never a crash; the run continues |

**Client → server intents (frozen; every one is server-validated):**

| type | Payload (frozen keys) | Gate |
|---|---|---|
| `helm` | `{dir: "N"\|"NE"\|"E"\|"SE"\|"S"\|"SW"\|"W"\|"NW"\|"stop"}` | at sea; `input_mode` per `control_prefs` |
| `sail_trim` | `{trim: "furled"\|"reefed"\|"normal"\|"full"}` | at sea |
| `sail_to` | `{x, y}` — target tile | at sea; the server computes the path and walks it (click-to-sail, `20-*` §4.2) |
| `wait` | `{}` | at sea (wait-at-sea, `20-*` §4.17) |
| `intercept` | `{fleet_id}` or `{cancel: true}` | at sea; target inside sighting radius |
| `autopilot` | `{dest_port_id}` or `{cancel: true}` | at sea; known port + in-post pilot (`20-*`) |
| `battle_order` | `{station, desired_heading8, desired_speed_band, assigned_target, discipline}` — the per-round order five-tuple (`60-*` §4.9b) | in battle, inside the orders window |
| `battle_action` | `{verb: "broadside"\|"hook"\|"retreat"\|"surrender", side: "port"\|"starboard", shot: "round"\|"chain"\|"armor_piercing"\|"grape"}` — `side`/`shot` only on `broadside` | in battle |
| `locale` | `{locale: "zh"\|"en"}` | anytime |

### 0.4 HTTP action shape (frozen; the endpoint inventory freezes at M2)

- Discrete actions are `POST /api/<facility>/<action>` with a JSON body in
  and JSON out: success `{"ok": true, …}` (the fresh authoritative snapshot
  rides the next `state` frame); refusal `{"ok": false, "error":
  {"code", "msg"}}`. Reads are `GET`.
- Fixed endpoints, frozen now: `POST /api/new_game {nation_id,
  background_id, attr_alloc, skill_alloc}` · `POST /api/load {slot}` ·
  `POST /api/save {slot}` · `GET /api/saves` · `GET /api/state` ·
  `POST /api/locale {locale}`. The facility inventory (market, shipyard,
  tavern, inn, guild, palace, provisions, people verbs) is enumerated and
  frozen in the M2 acceptance record before the first screen consumes it.

### 0.5 Frozen numbers

| Number | Value | Notes |
|---|---|---|
| `SIM_TICK_HZ` | **10** | server advances sim time at 10 Hz; the day cadence and every rule constant are unchanged (`20-*`). Confirmed against sailing feel in M4, then frozen verbatim here |
| `WS_BROADCAST_HZ` | **10** | one `tick`/`battle_tick` per sim tick (§0.3 backpressure coalesces) |
| Server bind / port | `127.0.0.1` : **8000** | default port 8000, `--port` override; `python -m server` (or `run.sh`) starts uvicorn and opens the browser |
| Save profile dir | **`~/.sailage/`** | XDG-style profile root; the `SAILAGE_HOME` env var overrides it (test seam). Saves at `~/.sailage/saves/save_{1..3}.json` — 3 slots, the Godot UX count |
| `SAVE_VERSION` | **1** | the web era restarts the counter; **no migration chain** — a payload whose `save_version ≠ 1` is refused (the §8.2 discipline carries over verbatim; Godot-era v1–v9 payloads are all "pre-release saves") |
| Day-tick budget | ≤ **75 ms** | **Measured (M1, 2026-11-11): mean 45.7 ms · median 44.8 · p95 60.8 · max 84.7 ms** (single spawn-day spike) at **334 fleets** — above the Phase-8 318-fleet count — via `python -m server.perf_day_tick` (deterministic seeds, full §5.4 chain: ledger → economy → month → day_advanced → ecology → quests → captains). numpy **not** needed; the Godot-era record (72 ms @ 318) is history |
| Python dependency pinning | exact `==` pins | `server/requirements.txt` is the FastAPI domain (fastapi, uvicorn, pytest, httpx; numpy joins only if the M1 perf spike demands it — pre-approved, §0.1) — a **separate dependency domain** from the stdlib-purist `tools/`, which stays stdlib-only |
| Web dependency pinning | exact semver pins | `web/package.json` (React 18 + TypeScript + Vite); the lockfile is committed |

### 0.6 Status of the Godot-era sections (§1–§13)

Sections §1–§13 below describe the **Godot runtime**; they keep their
numbers because every system doc cites them (`90-*` §5.1 signals, §8 save
format, §9 map loader …). Their status from M0:

- **Frozen read-only** as the parity oracle until the M6 cutover — the
  runtime stays runnable for oracle diffs (the §8.1 v9 payload, the
  §5.1 signal names and the §9 loader semantics are what M1–M5 port).
- **Retired at M6** together with the tree they describe, by the explicit
  enumerated list in the M6 acceptance record (`IMPLEMENT-WebMigration.md`);
  semantic doc pins are re-homed to §0 + the system docs first, per the
  check-count-drift agreement.
- Godot file paths in the system docs (`scripts/…`, `autoload/…`, `*.tscn`)
  stay the oracle pointers until M6; the Python/TS realizations cite
  `90-*` §0 plus their owning system doc. `95-DEBUG-HOVER.md` is
  Godot-only and retires at M6 with them.

## 1. Purpose & Phase

Defines the Godot 4 project structure every implementation task builds into:
directory tree, scene patterns, autoload singletons, the scene-vs-data split,
save-file format and versioning, and how the world PNG becomes chunked runtime
TileMaps. Gates all phases; Phase-1 tasks must not introduce structures that
contradict this doc. Phase 7 (trade empires) adds the `allegiance.gd` engine
module, five allegiance/permit/treasury GameState fields, the month-tick
ordering pin (§5.4), and save v7 (§8). Phase 8 (characters/careers/encounters)
adds the person-model scripts (`player/skills.gd`, `world/captains.gd`,
`world/interactions.gd`, `world/hail_options.gd`, `world/autopilot.gd`), the
officer/captain state blocks on GameState (§5.4), and save v9 (§8). Phase 10
(UI element kit & generated pixel art) adds the `class_name` statics
`ui_theme.gd`/`ui_kit.gd`/`ui_motion.gd`, `ui/portrait_composer.gd`,
`world/arrow_field.gd`, the generated-art artifacts under `assets/ui/`
(`80-*` §4.8/§4.9) and the terrain-art/overlay rendering of §9.2 — no
autoload, no new signal, no save-format change.

## 2. Artifacts

| Path | Contents |
|---|---|
| `project.godot` | Godot 4.x project file; window 1920×1080 (see §6) |
| `autoload/*.gd` | Singleton scripts (§5) |
| `scenes/*/*.tscn` | All scenes (§4) |
| `scripts/*.gd` | Non-autoload logic (§4) |
| `data/*` | All game content, per `docs/10-DATA-SCHEMA.md` |
| `tools/validate_data.py` | Data validator (spec in `10-DATA-SCHEMA.md` §8) |
| `user://saves/save_%d.json` | Save files (§8) |

## 3. Dependencies

Read `docs/00-OVERVIEW.md` (conventions) and `docs/10-DATA-SCHEMA.md`
(data contract) first. System docs (`20–50`) cite this doc for where their
scenes/scripts live.

## 4. Project Layout

```
SailAge/
├── project.godot
├── autoload/
│   ├── game_state.gd      # GameState singleton
│   ├── data_loader.gd     # DataLoader singleton
│   ├── i18n.gd            # I18n singleton
│   ├── save_system.gd     # SaveSystem singleton
│   ├── event_bus.gd       # EventBus singleton
│   └── layout_bridge.gd   # Phase 11: debug-gated WS layout bridge (§5.7) — a disabled no-op without `--layout-bridge`
├── scenes/
│   ├── title/
│   │   ├── title_screen.tscn
│   │   ├── nationality_select.tscn
│   │   └── creation_screen.tscn  # Phase 8: background + free points, step ②③ (80-*)
│   ├── world/
│   │   ├── world_map.tscn       # chunked-TileMap ocean sailing scene
│   │   ├── chart_screen.tscn    # S17 whole-world Chart (Phase 4)
│   │   ├── fleet_picker.tscn    # Phase 8: right-click multi-fleet picker (60-*/80-*)
│   │   ├── hail_modal.tscn      # Phase 8: at-sea hail verbs (80-*)
│   │   └── autopilot_hud.tscn   # Phase 8: appointed-voyage HUD bar (80-*)
│   ├── port/
│   │   ├── port_screen.tscn     # port hub (facility menu)
│   │   ├── provisions_dialog.tscn  # Set-Sail provisioning prompt (§4.6.1)
│   │   ├── market_screen.tscn
│   │   ├── shipyard_screen.tscn
│   │   ├── tavern_screen.tscn
│   │   ├── inn_screen.tscn
│   │   ├── guild_screen.tscn    # Phase 3 (S12)
│   │   └── palace_screen.tscn   # Phase 3 (S13)
│   ├── combat/                 # Phase 2; Phase 9 adds the S21 sandbox
│   │   ├── battle_screen.tscn    # S10 battle screen (80-* §4.7.1)
│   │   └── battle_sandbox.tscn   # Phase 9 W2: S21 naval-battle sandbox, zero-write (80-* §4.7.16)
│   ├── ui/                     # Phase 8: shared person UI
│   │   ├── character_card.tscn    # unified person renderer — player/officer/NPC captain (80-*)
│   │   └── dossier_panel.tscn     # captain dossier: card + familiarity-gated career log (80-*)
│   └── ui_shared/
│       ├── dialog_box.tscn
│       ├── confirm_dialog.tscn
│       ├── gameover_screen.tscn
│       ├── ending_screen.tscn   # Phase 3 (S16, retirement summary)
│       ├── settings_panel.tscn  # Phase 5 (S19 settings modal, over S4)
│       └── hud.tscn
├── scripts/
│   ├── world/sailing_sim.gd    # day tick, consumption, weather, morale
│   ├── world/map_loader.gd     # PNG world → chunked TileMaps (§9)
│   ├── world/ocean_layers.gd   # Phase 6: decodes wind_regions.png/currents.png + ice polygon cache; owns all ocean-layer lookups (10-* §6.5)
│   ├── world/sail_path.gd      # click-to-sail A* pathing (20-* §4.2, Phase 4)
│   ├── world/discovery.gd      # Phase 3: explore/report/hints (70-* §4.4)
│   ├── world/npc_fleets.gd     # Phase 5: the living-sea fleet sim (60-* §4.1)
│   ├── world/npc_intel.gd      # Phase 5: sightings/posters/rumors queries (60-* §4.1)
│   ├── world/captains.gd       # Phase 8: canon read + captain state machine (10-* §4.11, 60-*)
│   ├── world/interactions.gd   # Phase 8: targeting/fleet attribution/verb dispatch (60-*)
│   ├── world/hail_options.gd   # Phase 8: role × stance × skill hail-option builder (80-*)
│   ├── world/autopilot.gd      # Phase 8: appointed voyage — route + interrupts (20-*)
│   ├── world/arrow_field.gd    # Phase 10: S3 wind/current arrow-field sampler, pure (80-* §4.8 arrow-field spec)
│   ├── combat/battle_sim.gd      # Phase 2: battle turn engine, pure (60-* §4.12.1)
│   ├── combat/ai_fleet.gd        # Phase 2: enemy composition + AI decisions (60-* §4.12.1.1)
│   ├── combat/fleet_commander.gd # Phase 9 W4: per-round fleet order five-tuples, pure (60-* §4.9b)
│   ├── combat/ai_search.gd       # Phase 9 W5: T3 one-ply lookahead + shared evaluation + θ const tables (60-* §4.9c)
│   ├── port/trade_engine.gd    # price formulas from 30-PORTS-AND-TRADE.md
│   ├── port/economy.gd         # Phase 5/7: flow-economy stock tick + events, pure (30-* §4.2/§4.5)
│   ├── port/allegiance.gd      # Phase 7: port classes, ledgers, dev, treasuries, tariffs/permits inputs (30-* §4.9/§4.10)
│   ├── port/shipyard_engine.gd
│   ├── port/palace_engine.gd   # Phase 3: royal missions, titles (70-* §4.3)
│   ├── quests/quest_gen.gd     # Phase 3: offers + tracking (70-* §4.9.3)
│   ├── quests/bounty.gd        # Phase 3: piracy/bounty (70-* §4.9.5)
│   ├── quests/tournament.gd    # Phase 3: bracket + prizes (70-* §4.9.7)
│   ├── player/character.gd     # stats, XP, officers
│   ├── player/skills.gd        # Phase 8: skill values, usage counters, gates, training (50-*)
│   ├── player/fame.gd          # Phase 3: fame + title ladder (70-* §4.9.2)
│   ├── fleet/fleet.gd          # fleet composition, cargo maths
│   ├── ui_theme.gd             # Phase 10: build_theme() — one code-built Theme from palette constants (80-* §4.9); applied at startup, no .tres, no autoload
│   ├── ui_kit.gd               # Phase 10: the six widget atoms, static factory (80-* §4.9); + the tile grid pass (2026-11-09): install_tile_grid() once at the S1 theme point snaps every sheeted control's min size to whole chrome tiles (§4.8 sizing grid)
│   ├── ui_motion.gd            # Phase 10: the UiMotion motion-gate static (80-* §4.7.17 timings)
│   ├── ui/layout_registry.gd   # Phase 12: the absolute-tile layout registry (80-* §4.8.9); applies data/ui_layout.json v2 rects after build, dumps the bridge tree
│   └── ui/portrait_composer.gd # Phase 10: 72×96 procedural busts from a captain's `appearance` + role cloth; override file wins (80-* §4.8)
├── data/                        # contract owner: 10-DATA-SCHEMA.md
│   ├── wind_regions.json        # Phase 6: prevailing-wind regions (10-* §4.16)
│   ├── ocean_currents.json      # Phase 6: ocean-current systems (10-* §4.17)
│   ├── ice_regions.json         # Phase 6: seasonal sea ice (10-* §4.18)
│   ├── captains.json            # Phase 8: named-captain canon — built, tool-owned (10-* §4.11)
│   ├── captain_name_parts.json  # Phase 8: builder's authored source — names/personality/appearance (10-* §4.11.1)
│   ├── officers.json            # Phase 8 v2: 96-officer roster — built, tool-owned (10-* §4.5)
│   ├── skill_gates.json         # Phase 8: data-driven skill/stat gates (10-* §4.20)
│   ├── officer_posts.json       # Phase 8: officer posts — prereqs + advice triggers (10-* §4.21)
│   ├── backgrounds.json         # Phase 8: 6 new-game backgrounds (10-* §4.22)
│   ├── ui_layout.json           # Phase 12: THE absolute layout file, v2 (10-* §4.23) — every static element's rect + list blocks; the ONLY layout artifact (the fragment/assembler pipeline is retired, 2026-11-11), single writer = the studio
│   ├── maps/world.png           # generated, tool-owned (§9)
│   ├── maps/wind_regions.png    # Phase 6: baked wind lookup, tool-owned (10-* §6.5)
│   ├── maps/currents.png        # Phase 6: baked current lookup, tool-owned (10-* §6.5)
│   ├── maps/world_shore.png     # Phase 10: shore-edge lookup raster, tool-owned (10-* §6.6)
│   └── trade_routes_built.json  # generated, tool-owned (Phase 5; 10-* §4.14)
├── assets/ui/                   # Phase 10: generated UI art PNGs — indexed, nearest-neighbor import, tool-owned, never hand-edited (80-* §4.8)
└── tools/
    ├── validate_data.py
    ├── build_world.py           # Natural Earth → data/maps/world.png (Phase 4)
    ├── map_overrides.json       # carved-strait list (Phase 4)
    ├── build_ocean.py           # ocean rasters: wind_regions.png + currents.png (Phase 6)
    ├── build_routes.py          # trade lanes → trade_routes_built.json (Phase 5)
    ├── route_overrides.json     # lane hand-fixes (Phase 5)
    ├── build_captains.py        # Phase 8: parts + quotas + overrides → captains.json + officers.json v2 (--check = byte-identical rebuilds; 10-* §4.11)
    ├── captain_overrides.json   # Phase 8: legend layer — 4 named pirates (with drops) + 20 legend captains
    ├── officer_overrides.json   # Phase 8: the 24 hand-authored legend officers
    ├── battle_ai_harness.gd     # Phase 9 W3: 64-seed mirror self-play harness (+ .tscn)
    ├── battle_ai_harness_report.md  # generated, tool-owned — never hand-edited
    ├── battle_tune.py           # Phase 9 W5: offline CEM θ learning, stdlib-only
    ├── battle_tune_report.md    # generated, tool-owned — never hand-edited
    ├── build_ui_art.py          # Phase 10: the art governor — manifests → engine renders → transforms/remaps/seams/nine-patch/atlases/contact sheet; --check byte-compare
    ├── build_shore.py           # Phase 10: world.png → data/maps/world_shore.png (10-* §6.6); --check byte-compare
    ├── art_prompts.json         # Phase 10: model-pass prompt manifest (24 legend + 4 named pirates + 30 discoveries)
    ├── ui_art/<class>/          # Phase 10: declarative sprite manifests (chrome/icons/hulls/terrain/fx/portraits)
    └── yoyopixel/               # Phase 10: vendored YoYoPixel skill + LICENSE + extracted engine core + node render.js (MIT, © 2026 SbName; node pinned v24.16.0; zero npm deps)
```

Rules:

- One scene per screen; a screen scene never embeds another screen's logic.
- `scripts/` holds pure-logic classes (`extends RefCounted`) with no node
  references, so they are unit-testable from the editor's headless mode.
- All placeholder visuals (colored `ColorRect`, `Polygon2D`, default-font
  `Label`) live inside the screen scenes; no shared art directory in Phase 1.

## 5. Autoload Singletons

Registered in `project.godot` in this order (dependencies flow downward):

### 5.1 EventBus (`autoload/event_bus.gd`)

Application-wide signals; no state. Canonical signals:

| Signal | Args | Emitted when |
|---|---|---|
| `day_advanced(new_day: int)` | day number | clock ticks (at sea and in port) |
| `clock_changed()` | | any `advance_clock` that consumed time, sub-day included — `HH:MM` labels re-render (added 2026-11-02) |
| `locale_changed(locale: String)` | `"zh"`/`"en"` | language toggle |
| `gold_changed(new_gold: int)` | | any gold delta |
| `fleet_changed()` | | ship bought/sold/sunk/repaired/cargo moved |
| `market_changed(port_id: String)` | | a trade moved a port-good's stock at that port (economy stock change; market UI refreshes) |
| `port_entered(port_id: String)` | | a port's shore tile entered (docking, `20-*` §4.11.1) |
| `game_over(reason: String)` | `"starvation"`/`"scurvy"`/`"sunk"`/`"captured"` | run death — a ledger tick ended the run (port day-rolls included, `20-*` §4.9); S9 rises over every run-hosting scene (`80-*` §4.2 full-scene amendment 2026-11-02) |
| `save_completed(slot: int)` | | SaveSystem finished a write |
| `battle_started(encounter: Dictionary)` | encounter descriptor (`60-*` §4.11.11) | S10 opens a battle |
| `battle_finished(outcome: Dictionary)` | outcome block (`60-*` §4.11.9/§4.11.10) | a battle ends, any outcome |
| `duel_finished(outcome: Dictionary)` | `{result, rounds, attacker, defender}` | the S11 modal closes |
| `fame_changed(new_fame: int)` | | any fame delta |
| `quests_changed()` | | a quest accepted / completed / failed |
| `title_granted(nation_id: String, rank: String)` | `70-*` §4.9.2 rank id | a palace ceremony grants a title |
| `discovery_found(discovery_id: String)` | | an Explore action found a discovery |
| `discovery_reported(discovery_id: String)` | | a guild report paid out |
| `bounty_issued(nation_id: String)` | | rep hit ≤ −50 and a bounty was created |
| `bounty_cleared(nation_id: String)` | | either clearing path reset rep to −10 |
| `tournament_finished(outcome: Dictionary)` | `{won, round_reached, gold, fame}` | a tournament bracket ended |
| `retired()` | | the ending screen opened |

Any module may `emit`; only view/UI code and `GameState` may `connect`.
Cross-screen communication never uses direct node references.
**Phase-8 note (2026-11-02):** the table is unchanged — Phase 8 adds **no new
signal**. The new UI (level-up toast + allocation badge, advice banners,
`fleet_picker`/`hail_modal` results, dossier panels) reads GameState and the
`Character`/`Skills` statics directly and rides the existing signals
(`day_advanced`, `gold_changed`, dialogs-as-modal-children), consistent with
the HUD pattern of §7.

### 5.2 DataLoader (`autoload/data_loader.gd`)

- Loads every `data/*.json` at startup into typed dictionaries keyed by id:
  `DataLoader.ports`, `.goods`, `.ship_types`, `.nations`, `.officers`,
  `.equipment`, `.discoveries`, `.quests`, `.ui_strings`, `.map_legend`,
  plus the Phase-5 files `.npc_config`, `.named_pirates`,
  `.market_events`, `.trade_routes`, the tool-built
  `.trade_routes_built` (read-only, `10-*` §4.14), the Phase-6 ocean
  files `.wind_regions`, `.ocean_currents`, `.ice_regions` (`10-*` §4.16–4.18),
  `.facility_hours` (`10-*` §4.19, added 2026-11-02), and the Phase-8
  canon/data files — the tool-built `.captains` and `.officers` v2 (one
  builder, byte-identical rebuilds, read-only; `10-*` §4.11/§4.5) plus the
  authored `.captain_name_parts`, `.skill_gates`, `.officer_posts`,
  `.backgrounds` (`10-*` §4.11.1, §4.20–4.22). The Phase-5 `.npc_captains`
  loader key is **removed** (the file is deleted — the named-captain canon
  replaces the name pools).
  There is exactly one port file (`data/ports.json`, the 100 sovereign ports
  plus the Phase-6 neutral tier, `10-*` §7.1) — **no merge step**.
- Entry points: `get_port(id) -> Dictionary`, `get_good(id)`, …
  plus the world-map handoff **`DataLoader.map`**: a `MapLoader` instance
  built over `data/maps/world.png` (§9).
- On parse/validation failure: push full error to console and show
  `data_error_screen` text on the title screen; the game must not start with
  invalid data in development builds (release builds may proceed with
  whatever parsed).
- Depends on nothing; loads before GameState init finishes.

### 5.3 I18n (`autoload/i18n.gd`)

- `t(l10n: Dictionary) -> String` — returns `l10n[GameState.locale]`.
- `t_key(key: String) -> String` — looks up `DataLoader.ui_strings[key]`.
- `set_locale(locale: String)` — writes `GameState.locale`, emits
  `EventBus.locale_changed`.
- No fallback chain: validator guarantees both locales; a missing key returns
  the literal `"<key>"` and logs an error (bug, not data path).

### 5.4 GameState (`autoload/game_state.gd`)

Single source of truth for all mutable game state. Fields (save-relevant ones
marked •):

- `locale: String` • (`"zh"` default `"en"`? locked: `"en"` — user toggles)
- `day: int` •, `gold: int` •
- `player: Dictionary` • — nationality, background, the five attributes +
  eight skills (with `skill_counters` and the persisted `alloc_pending`
  counter), XP/level, the `autopilot` appointment (`{dest_port_id}`, absent
  when none), officers, reputation map (the v9 Person shape in
  `50-CHARACTER-AND-PROGRESSION.md` §4.8). `Character.pending_levelup` (the
  class static in `scripts/player/character.gd`) stays **session-transient**
  (the level-up toast + badge); `player.alloc_pending` is the persisted
  counter — no levelup key exists in any save
- `fleet: Array` • — ship instances (shape in `40-SHIPS-AND-FLEET.md` §ship
  instance schema)
- `world: Dictionary` • — fleet tile position, `map_id` (always `"world"`,
  `DEFAULT_MAP_ID`), movement state, weather state, and the Phase-5 hunter
  intel keys: `last_departed_port` (port id string, set at every Set Sail)
  and `hunter_intel_cell` (tile position, set on contact with a hostile
  nation's fleet — behavior in `60-*` §4.11.11.1). Phase 6 adds three
  keys with pinned defaults: `sail_trim` (default `"normal"`,
  `20-*` §4.17), `heading` (default `"E"`; an 8-dir id, `20-*` §4.2), and
  `wind_dir` (default `"E"`; an 8-dir id — overwritten by every ledger
  weather roll before any movement consumes it, and persisted for the
  current day, `20-*` §4.7). The explored set's container is a
  `PackedByteArray` of **9,331,200** bytes (~9.3 MB at the 4320×2160 grid;
  the runtime keeps the Phase-1 Dictionary behind `ChartView.is_explored`)
  owned by the world scene/HUD. It **is** saved since the explored-state
  amendment (2026-11-02) — as the top-level §8.1 key `explored_tiles`,
  never inside `world`.
- `morale: int` • — fleet morale 0–100 (`20-*` §4.8)
- `current_port: String?` • — port id while docked; `null` at sea (save/load
  routing, `80-*` §4.7)
- `port_investments: Dictionary` • — `{port_id: gold_total}` (`30-*` §4.3)
- `known_ports: Array[String]` • — discovered ports (§20 port discovery)
- `npc_fleets: Array` • — every living NPC fleet, 8 roles (`60-*` §4.1);
  save shape in `10-*` §4.15. Since Phase 8 each fleet carries `captain_id`
  — a key into `data/captains.json` canon plus the fleet's
  `captain_states` entry (`10-*` §4.11/§4.15). Owned by
  `scripts/world/npc_fleets.gd` — the
  Phase-5 module that replaces the retired Phase-2
  `scripts/world/encounters.gd` 3-marker system (the rename
  `hostile_fleets` → `npc_fleets` with `kind` → `role` mapping,
  `pirate`→`pirate` / `navy`→`hunter`, is task J's sweep; this doc pins the
  post-rename state)
- `market_stocks: Dictionary` • — `{port_id: {good_id: stock}}` (shape in
  `10-*` §4.15); initialized at `new_game` from the derived resting stock
  (`30-*` §4.2) — no RNG
- `wrecks: Array` • — lootable wreck sites (shape in `10-*` §4.15); never
  counted against the fleet cap
- `npc_preset: String` • — density preset id (`10-*` §4.10), default
  `"normal"`; chosen on S2, changeable mid-run in the S19 settings modal;
  raising refills via the trickle, lowering never culls living fleets
- `control_prefs: Dictionary` • — Phase-6 control preferences
  `{input_mode: "step"|"helm", current_mode: "modifier"|"drift"}`; defaults
  `{input_mode: "step", current_mode: "modifier"}` (**pinned**); **S19-only**
  rows (`80-*` §4.6.3), settable pre-game via S1 and in-run via S4; carried
  by `new_game` like `npc_preset`; persisted per save (`90-*` §8.1).
  Input-mode and current-mode semantics: `20-*` §4.2/§4.16
- `market_events: Array` • — active demand-event instances (shape in
  `10-*` §4.15); rotation in `30-*` §4.5
- `permits: Dictionary` • — Phase 7: `{home: bool, foreign: {nation_id: bool}}`
  (`30-*` §4.10); defaults `{home: false, foreign: {}}`; void/re-buy rules in
  `30-*` §4.10
- `port_allegiance: Dictionary` • — Phase 7: `{port_id: {ledger: {nation_id:
  gold}, allegiance: nation_id \| ""}}` for **all contestable ports** (`30-*`
  §4.9; save shape `90-*` §8.1). `allegiance` is persisted because the tie
  rule keeps the incumbent; **development is derived on load and on every
  ledger change — never saved**. Seeded by `Allegiance.seed_new_game()`
  (contestable sovereigns `{owner: 6,000}`, neutrals empty)
- `month_invested: Dictionary` • — Phase 7: `{port_id: gold}` — the
  ≤ 2,000g/port/month player-investment counter (decision 26); reset at the
  month tick
- `nation_treasuries: Dictionary` • — Phase 7: `{nation_id: gold}` — start
  5,000g each; funded by tax + permit sales, spent on monthly NPC
  counter-investment only (`30-*` §4.9/§4.10)
- `fame_commended: Dictionary` • — Phase 7: `{port_id: true}` — one palace
  commendation per port converted to the player's nation (`70-*` §4.1
  extension)
- `officer_states: Dictionary` • — Phase 8: `{officer_id: {loyalty, sea_days,
  post_id, ship_id, talk_cd_day, gift_cd_day, defeats}}` per employed officer
  (`10-*` §4.15; behavior `50-*`). `post_id = ""` = idle; `ship_id` is
  non-empty only on a captain post. Owned by `scripts/player/character.gd` +
  `scripts/world/interactions.gd` (the officer 4 actions)
- `captain_states: Dictionary` • — Phase 8: `{captain_id: {status, return_day,
  tier_now, stance, familiarity, dossier_seen, defeats, wins}}`; **full
  entries exist only for met captains** — the canon cards themselves
  (`data/captains.json`) are save-independent (`10-*` §4.11/§4.15; the
  `active → defeated → returning(day+60) → active` state machine lives in
  `scripts/world/captains.gd`, behavior `60-*`)
- `npc_port_log` — **transient, never saved**: the last ≤ 128
  arrival/departure records the ecology appends for tavern rumor rows
  (`60-*` §4.11.11.4 task L pin); a fresh run and every load start with an
  empty log. **Unchanged by Phase 8**
- `proximity_cooldowns: Dictionary` • — `{kind: day}` spawn immunity
  (`60-*` §4.8); present-but-empty before Phase 2
- `pending_encounter` — **transient, never saved**: the encounter S3 hands to
  S10 (`60-*` §4.11.11.3); S10 clears it on open
- `pending_tournament_round` / `last_tournament_outcome` — **transient, never
  saved**: S10 hands a won bout's next round back to S13, and a settled bracket
  its outcome block, so the palace screen can resume/announce the bracket
  (`70-*` §4.9.7)
- `quests` — Phase-1 placeholder, permanently empty from Phase 3 (§8.1)
- `discoveries_found` • (`[]id`) — discovery ids found by Explore (`70-*`
  §4.4); found ≠ reported
- Phase-3 fields (§8.1): `fame` • (int), `titles` •, `bounties` •,
  `active_quests` •, `completed_royal_missions` •, `discoveries_reported` •,
  `discovery_hints` •, `battles_won` •, `retired` •, `retired_at` •
- API: `new_game(nation_id, background_id, attr_alloc, skill_alloc)` (the
  Phase-8 two-step creation signature, `50-*` §4.1), `add_gold(delta)`,
  `advance_day()`, and thin helpers; heavy rules live in `scripts/` engines
  which mutate GameState. `world.map_id` is set to `DEFAULT_MAP_ID = "world"`
  at new game — there is no map choice.
- Day-tick listener order (`20-*` §4.3): the daily ledger runs first
  (`20-*` §5: consumption before wages before morale), then **economy
  drift + demand-event expiry** (pure `scripts/port/economy.gd`,
  `30-*` §4.2/§4.5), then `EventBus.day_advanced` fires, and the
  world-scene listeners (the NPC fleet tick) run on it — economy drift is
  always before `day_advanced`, on sea days and port day-advances alike.
  The Phase-6 wind-direction roll joins the ledger's weather step (step 3)
  on the same seeded stream, pinned order **strength → direction**
  (`20-*` §4.5/§4.7).
- **Month-tick ordering (Phase 7, pinned — one seam, one owner: task L):**
  the day ledger calls `Economy.day_tick` first (flow-economy stock
  movement + event bookkeeping — the existing position above, unchanged),
  then, when the day crosses a month boundary (30-day months), it calls
  `allegiance.month_tick()` — which resets `month_invested`, credits each
  nation's baseline treasury income, resolves the seeded NPC
  counter-investment, and refreshes the tavern telegraph windows
  (`30-*` §4.9). No other module performs month-boundary allegiance work;
  there is no second month tick anywhere in the frame.
- **Cap sizing (Phase 5; raised Phase 7):** normal ≈ **323** (core 307 + 16
  slack, `tools/demo_check_phase7.md`) is ecology/balance, not performance;
  coasters absorb the visual traffic (≤ 5-unit trades) so effective
  long-haul trading stays ~127 fleets; far-field LOD is the Phase-6 lever
  beyond `absolute_cap`.

### 5.5 SaveSystem (`autoload/save_system.gd`)

- 3 slots: `user://saves/save_1.json` … `save_3.json`.
- `save(slot)`, `load(slot) -> bool`, `list_saves() -> Array[Dictionary]`
  (slot, day, nation, port, gold, timestamp for the slot UI).
- Serializes exactly the •-marked GameState fields plus
  `{"save_version": 9, "saved_at": <unix>, "phase": 9}`.
- `load` validates `save_version` — it must equal `SAVE_VERSION = 9`;
  **no migration chain** (§8.2): a v8 or older payload is refused
  ("pre-release save"), `load()` returns `false`, and state is untouched.

### 5.6 FleetSim (`autoload/fleet_sim.gd`) *(added 2026-11-02)*

- Owns the live `NpcFleets` ecology sim instance. The fleet store itself
  stays `GameState.npc_fleets` (the §8.1 save block) — the instance is
  runtime-only and lazily re-created (`ensure()`), after a load or a new run,
  with `last_tick_day = GameState.day` and the accrual clock mark synced to
  the load instant (no catch-up, `60-*` §4.11.11).
- The `day_advanced` listener runs the **full daily ecology tick** here — in
  every scene, port included (`20-*` §4.3 step 5) — and emits
  `market_changed` for the ports the NPC trades moved (the pure module never
  emits). Per-move accrual is exposed as `accrue()` for the world scene's
  helm callers.
- **Never opens battles**: contact checks and `pending_encounter` stay with
  the world scene (`60-*` §4.11.11.2); a hostile fleet drifting onto a docked
  player's tile just waits there.
- Guards: without a run (`GameState.player` empty) or under a game-over the
  listener is a no-op — the same conditions the world scene checked.
- `replace_sim()` is the test seam (the `world_map.fleet_sim()` contract
  delegates here). Registered **last**, after SaveSystem.

### 5.7 LayoutBridge (`autoload/layout_bridge.gd`) *(added 2026-11-09, Phase 11; protocol amended Phase 12 — debug-gated)*

The studio layout editor's game-side endpoint (`80-*` §4.8.9). Registered
**last, after FleetSim**; it touches only UI trees and the network.

- **Gating:** disabled unless the game is launched with
  `-- --layout-bridge` (read from `OS.get_cmdline_user_args()`). Disabled
  = `_ready` returns immediately: no listener, no polling, no cost.
  Saves, the save format and the EventBus contract are untouched.
- **Enabled:** a one-client `WebSocketPeer` server bound to
  `127.0.0.1:8765` (port is a file constant), `_process` pumps the peer.
  Protocol (JSON text frames):
  | Direction | Message | Payload |
  |---|---|---|
  | game→studio | `hello` | `{screens, grid:{w:60,h:34}, tile:32}` |
  | game→studio | `screen_changed` | `{screen}` |
  | game→studio | `tree` | `{screen, elements:[{id, kind, role, rect_tiles, sheet, locked, parent, clipped, min_tiles, kids_tiles?}…]}` |
  | game→studio | `frame` | `{png_b64}` (viewport capture — on connect, `screen_changed`, after edits, on `get_frame`) |
  | game→studio | `error` | `{code, msg}` |
  | studio→game | `get_tree` / `get_frame` | `{}` |
  | studio→game | `move` / `resize` | `{screen, id, x?, y?, w?, h?}` — tiles; an element edits its rect, every element alike (the Phase-12 kind split is retired) |
  | studio→game | `assign_sheet` / `revert` | `{screen, id, sheet?}` |
  | studio→game | `reset_screen` | `{screen}` |
  | studio→game | `commit` | `{}` — replies `ok`; the game NEVER writes files |
- **Retired fields (Phase 12):** `min_w`/`min_h`, `order`, `anchor`
  leave the protocol — there is no stretch, no sibling re-flow and no
  edge dock to override. Until the studio's W3 lands, v1 messages are
  TOLERATED for one campaign: a `reorder`, or `resize` carrying only
  `min_w`/`min_h`, is answered `error` (`retired_field`) without
  touching the tree — never a crash (unknown keys ignored).
- Every edit is applied to the running tree immediately through
  `LayoutRegistry` (the user watches the real screen move); the reply
  is DEFERRED ONE FRAME (no container cascades remain — the single
  deferred frame is a safety margin, replacing the Phase-11 4-frame
  settle wait) and carries the fresh `tree` + a `frame`. The Phase-11
  resize-repro debug trail (`[LayoutBridge]` stdout/`user://
  layout_debug.log` lines) was REMOVED 2026-11-10 (user direction —
  per-element spam on every screen change); the reply mechanism and
  the single-writer rule are unchanged.
- **Single-writer rule:** the studio serializes its session, runs
  `tools/validate_data.py` in-process and writes `data/ui_layout.json`
  on validator pass. The bridge never touches the filesystem.

## 6. `project.godot` Requirements (locked values)

| Setting | Value |
|---|---|
| `display/window/size/viewport_width` | 1280 |
| `display/window/size/viewport_height` | 720 |
| `display/window/stretch/mode` | `canvas_items` |
| `display/window/stretch/aspect` | `keep` |
| Main scene | `scenes/title/title_screen.tscn` |
| Autoloads | EventBus, DataLoader, I18n, GameState, SaveSystem, FleetSim, LayoutBridge (in that order; FleetSim added 2026-11-02, LayoutBridge added 2026-11-09 — §5.7, a disabled no-op without `--layout-bridge`) |
| Input | keyboard+mouse only; no joypad actions in Phase 1 |

UI is authored at the 1920×1080 design canvas (`canvas_items` stretch, keep aspect); no per-screen responsive logic.

## 7. Scene Flow Patterns

- **Screen switching:** a tiny `SceneRouter` (function on GameState,
  `change_scene(path)`) swaps the root scene via
  `get_tree().change_scene_to_file`. No scene ever frees another.
- **World ↔ Port:** docking (heading into a port's shore tile from an
  orthogonally adjacent tile, `20-*` §4.11.1) emits `port_entered`; the world
  scene reacts by routing to `port_screen.tscn` with `GameState.current_port`
  set. Leaving port returns to `world_map.tscn` on the port's **berth** tile.
- **World ⇄ Chart:** `S3/S4 ⇄ S17` via `Tab` (open) and `Esc`/`Tab`
  (close; amended 2026-11-01 — the Chart is also openable from the port
  hub); the Chart is an overlay view of the current session and closes
  over whichever screen opened it, with state untouched. `world.map_id`
  is a single value (`"world"`), so **no map-switch routing exists**
  anywhere in the flow.
- **Title ⇄ Sandbox ⇄ Battle (Phase 9):** `S1 ──海战──► S21 ──开战──►
  S10 ──battle ends──► S21` — the naval-battle sandbox
  (`scenes/combat/battle_sandbox.tscn`, `80-*` §4.7.16) opens S10 through
  a **zero-write** fixture encounter (`60-*` §4.12.4); the ending shows a
  read-only after-action dialog and returns to S21 with the configuration
  kept (a normal battle still ends at S3); `Esc` returns S21 → S1.
- **Dialogs:** `dialog_box.tscn` / `confirm_dialog.tscn` are instanced as
  modal children of the current screen; results delivered via signals, not
  callbacks into other scenes.
- **HUD:** `hud.tscn` is a child of `world_map.tscn` and `port_screen.tscn`;
  it only reads GameState + EventBus signals, never mutates.

## 8. Save Format & Versioning

### 8.1 Shape

```json
{
  "save_version": 9,
  "saved_at": 1793119712,
  "phase": 9,
  "locale": "en",
  "day": 12,
  "gold": 7830,
  "player": {},
  "fleet": [],
  "morale": 70,
  "world": {"position": {"x": 2050, "y": 615}, "map_id": "world", "weather": "calm", "sail_trim": "normal", "heading": "E", "wind_dir": "E"},
  "current_port": "lisbon",
  "known_ports": ["lisbon"],
  "explored_tiles": "",
  "port_investments": {"lisbon": 500},
  "quests": [],
  "discoveries_found": [],
  "npc_fleets": [],
  "officer_states": {},
  "captain_states": {},
  "proximity_cooldowns": {},
  "market_stocks": {},
  "wrecks": [],
  "npc_preset": "normal",
  "market_events": [],
  "control_prefs": {"input_mode": "step", "current_mode": "modifier"},
  "permits": {"home": false, "foreign": {}},
  "port_allegiance": {},
  "month_invested": {},
  "nation_treasuries": {},
  "fame_commended": {}
}
```

(`player`'s interior shape is the v9 Person block, owned by `50-*` §4.8;
`fleet` interior shapes are owned by doc 40; SaveSystem treats both
opaquely. `world.position` is the Lisbon berth on the 4320×2160 grid —
lon −9.14 → `(−9.14 + 180) × 12 ≈ 2050`, lat 38.72 → `(90 − 38.72) × 12 ≈ 615`.)

Phase-2 additions (version 2):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `hostile_fleets` | `[]object` | `[]` | `60-*` §4.11.11 — **renamed `npc_fleets` at v5** |
| `proximity_cooldowns` | `object` `kind → day` | `{}` | `60-*` §4.8 spawn immunity |

`proximity_cooldowns` records, per hostile `kind`, the first day on which a new
spawn of that kind is allowed again after a battle (`spawn_immunity_days = 3`,
`60-*` §4.8).

Phase-3 additions (version 3):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `fame` | `int ≥ 0` | `0` | `70-*` §4.1, §4.9.1 |
| `titles` | `object nation_id → rank` | all six nations `"none"` | `70-*` §4.3, §4.9.2 |
| `bounties` | `object nation_id → {amount, day}` | `{}` | `70-*` §4.5, §4.9.5 |
| `active_quests` | `[]object` | `[]` | `70-*` §4.9.3 |
| `completed_royal_missions` | `object nation_id → int` | all six nations `0` | `70-*` §4.3 |
| `discoveries_reported` | `[]id` | `[]` | `70-*` §4.4 |
| `discovery_hints` | `object id → true` | `{}` | `70-*` §4.4 |
| `battles_won` | `int ≥ 0` | `0` | `70-*` §4.7 |
| `world.map_id` | `"world"` | `"world"` | `90-*` §9.1; value fixed in Phase 4 |
| `retired` | `bool` | `false` | `70-*` §4.7 |
| `retired_at` | `int` unix | `0` | `70-*` §4.7 |

`quests` (the Phase-1 placeholder) stays **present but permanently empty**:
it is superseded by `active_quests`, and nothing in Phase-3 code reads or
writes it. A v3+ save has no `quests` key (the retired `2 → 3` migration
dropped it; that chain no longer exists, §8.2); a load with the key absent
restores `GameState.quests = []`.
`world.map_id` is written by `SaveSystem.snapshot()` from `GameState.world`
(it already serialises `world`'s `position`/`weather`; `map_id` joins them).
Its value in a v3 payload was the map id current at that time; Phase 4 fixes
the value to `"world"` (§8.1 Phase-4 row).

Phase-4 change (version 4):

| Key | Value at v4 | How it is set |
|---|---|---|
| `world.map_id` | `"world"` | `DEFAULT_MAP_ID` (§9.1) |
| `world.position` | `tilePos` on the 2160×1080 grid | the save's `current_port` **berth** tile (`10-*` §6.1 snap rule, `20-*` §4.11.1) |

**No payload keys are added or removed** by version 4 — only values change:
`world.map_id` becomes `"world"`, `world.position` becomes the **berth** tile
(`10-*` §6.1 snap rule) of the save's `current_port` (saves are port-only by
design, `20-*` §4.3), `clock_fraction` becomes `0` (it is a runtime
accumulator, absent from a normal save — the retired migration normalized it
if a hand-edited payload carried one), `known_ports` is kept untouched (port ids
survived intact, `10-*` §7.1), and `phase` becomes `4`.

Phase-5 additions (version 5):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `npc_fleets` | `[]object` | `[]` | `60-*` §4.1; renames v2's `hostile_fleets`; shape in `10-*` §4.15; each fleet carries its `ships` composition (unified-movement amendment, `60-*` §4.11.11) — absent on an older payload ⇒ lazily recomposed from the fleet's `seed`, bit-identical, no version bump |
| `market_stocks` | `object port_id → {good_id → stock}` | derived resting stock (`30-*` §4.2), no RNG | `30-*` §4.2; shape in `10-*` §4.15 |
| `wrecks` | `[]object` | `[]` | `60-*` auto-resolve; shape in `10-*` §4.15 |
| `npc_preset` | string preset id | `"normal"` | `10-*` §4.10 |
| `market_events` | `[]object` | `[]` | `30-*` §4.5; shape in `10-*` §4.15 |
| `named_pirate_respawns` | `object named_id → day` | `{}` | `60-*` §4.11.11.4 (task L pin): a defeated famous pirate's respawn-availability day (`day + 30`; a defeated successor books the `successor_<tier>` alias slot); a live famous pirate is derived from the fleets themselves — **removed at v9** (Phase 8 retires the successor machinery; see the Version 9 block below) |

**No migration; v4 refused (Phase-5 decision 5).** `SAVE_VERSION = 5`,
`PHASE = 5`; version 5 adds **no `MIGRATIONS` entry and performs no payload
transformation**. All new state is initialized by `new_game`; a v4 payload
is refused like any older version (`load()` false, "pre-release save"
logged); see §8.2 for the normative rule.

Phase-6 additions (version 6):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `control_prefs` | object | `{"input_mode": "step", "current_mode": "modifier"}` | Phase-6 input/current modes (`20-*` §4.2/§4.16; S19-only rows, `80-*` §4.6.3) |
| `world.sail_trim` | string | `"normal"` | `20-*` §4.17 (sail trim) |
| `world.heading` | string 8-dir id | `"E"` | `20-*` §4.2 (last movement heading — every successful step updates it) |
| `world.wind_dir` | string 8-dir id | `"E"` | `20-*` §4.7 (the daily wind-direction roll, persisted for the current day) |

**No migration; v5 refused (Phase-6 decision 12).** `SAVE_VERSION = 6`,
`PHASE = 6`; version 6 adds **no `MIGRATIONS` entry and performs no payload
transformation**. The Phase-5 hunter keys carry over unchanged in shape —
`world.last_departed_port` / `world.hunter_intel_cell` persist as before,
with `hunter_intel_cell` **re-based to the 4320×2160 grid** (the breaking
change the version bump absorbs). The drift accumulator is runtime-only and
resets; wind direction is re-rolled daily on the seeded stream but persisted
for the current day. All Phase-6 state is initialized by `new_game`; a v5
payload is refused like any older version (`load()` false, "pre-release
save" logged); see §8.2 for the normative rule.

Phase-7 additions (version 7):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `permits` | object `{home: bool, foreign: {nation_id: bool}}` | `{home: false, foreign: {}}` | `30-*` §4.10 (two permit kinds, void rules) |
| `port_allegiance` | object `port_id → {ledger: {nation_id: gold}, allegiance: nation_id \| ""}` | `{}` — then `Allegiance.seed_new_game()` reseeds | `30-*` §4.9; the **correction-8 shape**: exactly `{ledger, allegiance}` per contestable port — **`development` is never saved** (derived on load / ledger change: `max(authored dev floor, ledger thresholds)`), while `allegiance` **is** persisted because the resolution tie rule keeps the incumbent |
| `month_invested` | object `port_id → gold` | `{}` | decision 26 monthly cap; reset at the month tick |
| `nation_treasuries` | object `nation_id → gold` | all six `5,000` | `30-*` §4.9 (tax + permit income; counter-investment spend) |
| `fame_commended` | object `port_id → true` | `{}` | `70-*` §4.1 extension (one commendation per converted port) |

`market_stocks` keeps its shape (the flow economy changes tick semantics, not
the format). Every contestable port appears in `port_allegiance` — the
sovereign non-core set (seeded `{owner: 6,000}`) and all 45 neutrals (empty
ledger); protected ports never appear (no ledger exists for them). All five
keys are written by `SaveSystem.snapshot()` from the GameState fields of
§5.4; new-game seeding runs through `Allegiance.seed_new_game()` so v7
payloads replay pure (a mid-month save/load replays the month's
counter-investment identically).

**No migration; v6 refused (Phase-7 decision 13).** `SAVE_VERSION = 7`,
`PHASE = 7`; version 7 adds **no `MIGRATIONS` entry and performs no payload
transformation**. All Phase-7 state is initialized by `new_game` through
`Allegiance.seed_new_game()`; a v6 payload is refused like any older version
(`load()` false, "pre-release save" logged); see §8.2 for the normative rule.
One owner task (V, `tools/test_save_v7.*` renamed from `test_save_v6`), the
Phase-5/6 single-breaking-bump pattern.

Version 8 — explored-state amendment (2026-11-02):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `explored_tiles` | `string` — base64 of the run-length encoding below | `""` → the empty set | `20-*` §4.12 (the reveal rules; the set itself lives in `GameState.explored_tiles`) |

The key persists the session explored set so a load restores the exact fog
boundary (the Phase-1 "explored on load again" limitation is removed; `80-*`
§4.6 amended the same day). **Encoding** (normative): the string is standard
base64 (with padding) of a little-endian byte stream of **6-byte runs**
`[u16 y][u16 x0][u16 len−1]` over the 4320×2160 grid; runs are sorted by
`(y, x0)` strictly increasingly, never overlap or touch within a row, and
satisfy `y < 2160`, `x0 ≥ 0`, `len ≥ 1`, `x0 + len ≤ 4320`. The empty set
encodes as `""`. `snapshot()` derives runs from `GameState.explored_tiles`
(keys are already wrap-normalised `Vector2i`s); `validate_payload()` refuses
a value that is not a string, not valid base64, not a multiple of 6 bytes,
or carries an out-of-domain / unsorted / overlapping run — same
refuse-loudly rule as every other wrong-typed block. The runtime container
stays the Phase-1 Dictionary (`90-*` §5.4); load assigns a **fresh**
dictionary so the HUD minimap's reference-identity reset check keeps firing.

**No migration; v7 refused (explored-state amendment).** `SAVE_VERSION = 8`,
`PHASE = 8`; version 8 adds **no `MIGRATIONS` entry and performs no payload
transformation**. A v7 payload is refused like any older version (`load()`
false, "pre-release save" logged); see §8.2 for the normative rule. Owner:
the out-of-band explored-state amendment (no `IMPLEMENT-Phase8.md` exists);
`tools/test_save_v8.*` follows the `test_save_v7` single-breaking-bump
pattern.

Version 9 — Phase 8 (characters/careers/encounters):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `player` (reshape) | object | — | the v9 Person block: `{nation_id, background_id, attributes{5}, skills{8}, skill_counters{8}, alloc_pending, xp, level, autopilot, officers[], reputation{}, profit_by_nation{}, profit_rep_awarded{}, equipment{}}` (`50-*` §4.8). `autopilot: {dest_port_id}` is **absent** when no voyage is appointed (`20-*`); `level` stays the cached derivation of `xp`; the counters follow the usage-growth rule (reset on award, stop counting at 100) |
| `officer_states` | object `officer_id → state` | `{}` | `{loyalty, sea_days, post_id, ship_id, talk_cd_day, gift_cd_day, defeats}` per employed officer (`10-*` §4.15; behavior `50-*`); `post_id = ""` = idle, `ship_id` non-empty only on a captain post. Two optional keys (W3 gate, 2026-11-03): `wage_mult` (default `1.0`; the §4.5.4 raise-accept writes `1.25`) and `skill_deltas` (object `skill → +n`, default absent; the W6-C persistence of the in-post +1/90-sea-days officer growth — W3's runtime applies growth to the loaded record in memory, the deltas make it survive save/load) |
| `captain_states` | object `captain_id → state` | `{}` | `{status, return_day, tier_now, stance, familiarity, dossier_seen, defeats, wins}` — full entries **only for met captains**; the canon cards stay save-independent (`10-*` §4.11/§4.15, `60-*`) |

**Removed at v9 (no migration, old payloads refused wholesale):**
`player.stats` — the old leadership/seamanship/combat/navigation block — and
`named_pirate_respawns` (the Phase-5 successor machinery is retired; the
named-captain return queue of `captain_states` replaces it, so the Phase-5
table's `named_pirate_respawns` row above is historical). All other v8 keys
carry forward (incl. `explored_tiles`).

**No migration; v8 refused (Phase-8 decision 16).** `SAVE_VERSION = 9`,
`PHASE = 9`; version 9 adds **no `MIGRATIONS` entry and performs no payload
transformation**. All Phase-8 state is initialized by
`new_game(nation_id, background_id, attr_alloc, skill_alloc)` (`officer_states`
starts empty; `captain_states` starts as the initial fill's **deployed
captains** — W4 gate amendment, 2026-11-03: a fleet's captain is a "met"
captain from day 1, `10-*` §4.15 — and the reshaped player block at its
§4.8 defaults); a v8
payload is refused like any older version (`load()` false, "pre-release
save" logged); see §8.2 for the normative rule. One owner task (W6-C,
`tools/test_save_v9.*` renamed from `test_save_v8`), the single-breaking-bump
pattern.

### 8.2 Versioning rule (no migration chain)

**Development-stage scope (normative; amended 2026-10-31, Phases 5–6).**
SailAge has not shipped; there are no player saves in the wild. Backward
compatibility across phases is therefore **explicitly out of scope until
the first release**, and no task may spend effort on it. Concretely:

- `save_version` increments on any breaking shape change. The current
  values are `SAVE_VERSION = 9`, `PHASE = 9` (Phase 8,
  characters/careers/encounters). **Phase 9 keeps `SAVE_VERSION = 9`** —
  battle state stays transient (never saved; the §5.4
  `pending_encounter` handoff is unchanged) and the S21 naval-battle
  sandbox writes nothing (`80-*` §4.7.16).
- **No migration chain.** `SaveSystem.MIGRATIONS` is empty. The whole load
  contract is the identity: a payload whose `save_version` equals
  `SAVE_VERSION` loads (round-trip); **any older payload — v8 included —
  is refused** (`load()` returns false, logs "pre-release save"). There is
  no v8 → v9 step, and none may be reintroduced: Phase 4 removed the chain
  (`IMPLEMENT-Phase5.md` correction 4), Phase 5 kept it removed
  (decision 5), Phase 6 kept it removed (decision 12), Phase 7 kept
  it removed (decision 13), the explored-state amendment (2026-11-02)
  kept it removed, and Phase 8 keeps it removed (decision 16).
- All Phase-5/6/7/8 state is initialized by `new_game` (stocks derived;
  fleets seeded to half the cap there and only there; `control_prefs` and
  the three `world` ocean keys defaulted; the allegiance/permit/treasury
  blocks seeded through `Allegiance.seed_new_game()`; the Phase-8
  `officer_states` block and the reshaped player block start empty/defaulted;
  `captain_states` starts with the initial fill's deployed captains (W4 gate
  amendment, 2026-11-03)); nothing is back-filled at load.
- Anything that would only exist to serve an old save (position remapping,
  port-id remapping, `phase` rewrites, legacy-key repair) is dead weight: if it
  is cheaper to delete than to maintain, delete it.
- This section is amended to restore the full compatibility guarantee when a
  release is planned; until then, treat "old save loads" as **not a
  requirement** (`00-*` §11: no work without a spec).

**Historical record (not normative).** Phases 2–4 each shipped one migration
step — `MIGRATIONS[1]` (add the v2 keys and the equipment blocks),
`MIGRATIONS[2]` (add the v3 keys with their defaults, drop the superseded
`quests` key, add `world.map_id`), `MIGRATIONS[3]` (rewrite `world` to the
single-world payload: `map_id` → `"world"`, `position` → the current port's
berth tile, `clock_fraction` → `0`) — and were pure functions that never
mutated their input. That chain, including its end-to-end fixture test, was
removed in Phase 4's final state; Phase 5's `test_save_v5` (renamed from
`test_save_v4` by task G) tests the current-schema round-trip and the
v4-refused path. `titles`/`completed_royal_missions` cover all six nations
in every v3+ payload (the ladder and the quest-slot rule read them by key);
the six ids come from `data/nations.json`, never a list in code.

## 9. World PNG → chunked TileMap (loading pipeline)

Implemented by `scripts/world/map_loader.gd` (RefCounted, instantiated once by
DataLoader as `DataLoader.map`):

1. Read `data/maps/world.png` bytes with `FileAccess`, then decode with
   `Image.load_png_from_buffer`. It is **data, not an imported texture** — no
   import pipeline, and it works in exports (the placeholder-art rule is
   unaffected: this is the one shipped raster, `00-*` §6).
2. Verify size **4320 × 2160** and an indexed palette whose indices are
   ⊆ `0–4`; anything else is a DataLoader startup error (§11).
3. Passability = byte lookup on the decoded `Image`'s palette index
   (0–4 → `~ . # ^ I`, `10-*` §6.2). `is_passable(x, y)` is **wrap-aware on
   x** (`x` taken mod 4320) and false for `y` out of range and for
   `#`/`^`/`I`.
4. Rendering = **128×128-tile chunk TileMaps generated on demand around the
   camera**, at most **24 live chunks**, freed beyond a margin. The 5 palette
   colours come from `80-*` §4.8 through `scripts/palette.gd` (`SEA`,
   `COAST_SEA`, `LAND`, `REEF`, `ICE`).
5. Ports = an **overlay layer** from `data/ports.json`. Each port derives the
   **harbor pair** of `20-*` §4.11.1: a *berth* tile (sea, the `10-*` §6.1
   snap) and a *shore* tile (the nearest orthogonally adjacent `#` tile). The
   overlay draws the nation-coloured square + label on the **shore tile** —
   the port's visible map location — plus a small berth marker on the sea tile
   so the pairing reads at a glance. Both are **wrap-duplicated at the seam**
   so a port at `x = 0` also shows at `x = 4320`. The loader exposes
   `port_cell(id)` (berth) and `shore_cell(id)`; both are memoised.
6. The camera centers on the fleet and `x` wraps (§7); `y` clamps to the
   2160-tile height.
7. The world scene queries only the loader; it **never re-reads the PNG**.

The loader's passability API does not change movement rules (`20-*` §4.2):

- **No corner cutting:** a diagonal move is blocked if either orthogonal
  neighbor of the target corner is impassable.
- **Longitude wraps.** `x` is taken mod 4320 everywhere (movement, BFS,
  camera, click); a fleet at `x = 4319` stepping east lands on `x = 0`.
  Click-to-sail paths obey the same rules, including the local-frame shift for
  seam crossings.

#### 9.1 Single map index

`data/maps/maps.json` has **exactly one entry**; resolving it stays
data-driven:

```json
{
  "version": 1,
  "maps": [
    {"id": "world", "file": "data/maps/world.png",
     "legend": "data/map_legend.json",
     "name": {"zh": "世界地图", "en": "World map"}}
  ]
}
```

- `GameState.world["map_id"]` is always `"world"` (`DEFAULT_MAP_ID`,
  `90-*` §5.4). An unknown id is a logged data error; there is no fallback
  ladder and no map-switch routing.
- `DataLoader.get_map(id)` → `{file, legend_path, name}`; the legend is the
  single `data/map_legend.json` (`10-*` §6).
- Adding a second map is not a Phase-4 feature; the index shape exists so a
  future phase can re-introduce multi-map support as a data-only change.

**Harbor-pair equality contract (pinned).** The builder
(`tools/build_world.py --check-snaps`) and the GDScript runtime implement the
**same** rule — berth within 2 tiles (Chebyshev) of `Port.lat`/`lon`, on
water, with ≥ 1 orthogonally adjacent water tile, equidistant candidates
tie-breaking to the smallest `(y, x)`, skipping any candidate with no
orthogonally adjacent `#` shore tile (`20-*` §4.11.1) — and the validator
compares both halves of the pair against the builder's report; a disagreement
is a build failure, never a quiet divergence.

#### 9.2 Terrain art & overlay layers (Phase 10)

Normative notes for the Phase-10 generated-art pass (`80-*` §4.8/§4.9,
`10-*` §6.6); the loading pipeline above is otherwise unchanged:

- `map_loader.gd` gains terrain-art rendering: legend kinds render as
  generated terrain tiles with the variant picked by cell hash
  `(x·31+y·17)%n`, a shore overlay TileMap layer consumes
  `data/maps/world_shore.png` (`10-*` §6.6), and a dedicated water layer
  draws `sea`/`coastal_sea` flat tiles driven by the animated-sea shader
  (`80-*` §4.7.17) — the battle scene reuses the same water shader via a
  shared script. Port markers render as `terrain_port_{owner}` sprites
  from the same overlay family. Chart + minimap stay flat raster (pinned,
  `80-*` §4.8).
- **AI-ingestion path** (model pass — ACTIVE since the 2026-11-04
  64-canvas upgrade, 80-* §4.8; **hull tokens moved to the PixelLab
  backend 2026-11-06, 80-* §4.8** — raws under
  `tools/ui_art/model_raw/pixellab/` gitignored, API key in
  gitignored `tools/pixellab_config.json`, raw model output never
  committed): `build_ui_art.py --import <dir>`
  ingests TheNoise `/edit` outputs (draft-as-reference restyle):
  snap-downsample to the 64 logical grid, quantize to the family
  palette block, enforce pennant source + footprint bands, then emit
  tokens as tool-owned artifacts; raw model output stays uncommitted
  (cache under `tools/ui_art/model_raw/`, gitignored). **The Model
  Studio (`tools/model_studio/`) is the user-facing re-roll bench for
  this path**: ship cards drive `pixellab_pass.py` in-process (free-text
  description + seed, ship-as-drawn snap passthrough) and Accept runs
  `build_ui_art --import-ships-pixellab` over the whole fleet stage;
  icon/terrain cards keep the local chain. After any art
  rebuild run
  crops portraits to 3:4, palette-quantizes **before** nearest-downscale,
  applies the outline pass + alpha threshold, then writes — raw model
  output is never committed (`80-*` §4.8).
- **Portrait resolution ladder:** the override file (`portrait_{id}.png`)
  wins; otherwise the procedural composer
  (`scripts/ui/portrait_composer.gd`) composes the 72×96 bust from the
  captain's `appearance` + role cloth. The override-wins seam is the only
  hook a future runtime-generation client needs (deferred — Phase-10
  parking lot).
- **Regenerated-art refresh:** after any `assets/ui/` rebuild, run
  (data artifacts) — `assets/ui/tokens/` joined the raw-bytes family
  (2026-11-05): tokens load via `load_png_from_buffer` at runtime, so
  replacing token files needs **no import refresh** — restart the game
  and the new art renders (the model-studio accept→ingest flow relies
  on this). Every other regenerated texture still needs
  `godot --headless --import` once before launching the game — a plain
  game launch reuses the stale `.godot/imported` cache and renders the
  old textures (the 2026-11-04 "buttons still broken after the fix"
  report was exactly this).
- **Waterline VFX family (2026-11-07, 80-* §4.8):** `assets/ui/fx/`
  joins the raw-bytes lazy family — the registry miss resolver falls
  through the tokens dir onto the fx dir (`fx_waterline_{back,front}_
  {dir}.png` + `fx_waterline.json`), so a re-rolled VFX sheet reaches
  the game by the same file-replace + restart seam; no `.import`
  sidecars are consulted.
- **Why `project.godot` stays unchanged:** `ui_theme.gd`/`ui_kit.gd`/
  `ui_motion.gd` are `class_name` statics, not autoloads; the theme
  applies at `title_screen._ready()` (`get_window().theme`, `80-*` §4.9);
  no new EventBus signals (the §5.1 table is unchanged); the save format
  is untouched — `SAVE_VERSION` stays 9 (§8.2), Phase 10 adds no saved
  state.

## 10. "Add Content = Data-Only" Rule

- Adding a port, good, ship type, officer, quest, discovery, or equipment
  entry must require **edits only under `data/`** plus passing
  `tools/validate_data.py`. If a code change seems necessary, the design is
  wrong: generalize the code, don't special-case the content.
- Enums (`category`, `role`, `slot`, quest `type`…) are code-referenced; adding
  an enum value IS a code change and must be treated as such in the task list.

## 11. Edge Cases & Fail States

- **Invalid data at startup** → title screen shows the validator error text;
  no crash loop (§5.2).
- **Missing save slot file** → `list_saves()` reports the slot as empty;
  loading an empty slot returns false.
- **Save written mid-day-tick** → saves are only offered at port (Phase-1
  rule from `80-UI-UX.md`) and via title-screen autosave-on-load; GameState
  guarantees day tick is atomic before any save call.
- **`world.png` missing / wrong size / non-indexed / palette index > 4** →
  DataLoader startup error; same path as invalid data (§5.2).
- **Port entered while a dialog is open** → dialogs are modal; movement input
  is disabled while any modal exists, so this cannot occur.
- **Two scenes connected to the same EventBus signal after scene switch** →
  scenes connect in `_ready` and Godot frees connections with the node; HUD
  re-connects on each entry. Double-connection is prevented by connecting in
  `_ready` only.
- **Click-to-sail path across the dateline** → found via the local-frame shift
  (`20-*` §4.2): fleet and target `x` are shifted together into `[0, 4320)`
  before the `AStarGrid2D` query and the path is offset back, so a fleet at
  `x = 4200` clicking `x = 50` gets the short westward route.

## 12. Acceptance Criteria

- [ ] Directory tree (§4) is the one created by the Phase-1 setup task; any
      deviation requires amending this doc.
- [ ] Autoload list, order, and signal names (§5.1) are used verbatim in code
      and cited by name (no ad-hoc signals for the listed events).
- [ ] `project.godot` matches §6 exactly.
- [ ] Save file contains at least the §8.1 keys with `save_version` present;
      load tolerates missing optional keys only where a default is documented.
- [ ] A v9 payload round-trips exactly (fleet positions, route legs,
      captain states, officer states, stocks, control prefs, trim/heading/
      wind direction, permits, port allegiance ledgers, month investment
      counters, treasuries, commendation flags, explored tiles); a v8
      payload is refused with the standard message
      (`load()` false, "pre-release save" logged — §8.2).
- [ ] Swapping `data/maps/world.png` for another palette-conformant
      4320×2160 indexed PNG requires zero code edits.
- [ ] Swapping in rebuilt ocean rasters (`data/maps/wind_regions.png` /
      `data/maps/currents.png`, `10-*` §6.5) requires zero code edits beyond
      `ocean_layers.gd`'s decode contract.
- [ ] Adding one new good to `data/goods.json` requires zero code edits
      (verified in the Phase-1 market task acceptance).

## 13. Test Runner & Gates (Phase 5)

The per-suite contract is unchanged: every suite is
`tools/test_<name>.tscn`, runs headless (`godot --headless res://…`), exits 0
on pass, and prints a completion marker — `ALL PASS (N checks)` or
`X of Y checks FAILED`. `tools/run_tests.py` is the canonical gate runner
(stdlib-only) that wraps that contract with zombie/hang detection and
built-in profiling, so a wave gate needs exactly one run:

- **Scheduling.** Save-touching suites share `user://saves/` and run
  one-at-a-time (the serial-save set: `test_save`, `test_save_v9` (renamed
  from `test_save_v8` in Phase 8 W6; itself renamed from `test_save_v7` in
  Phase 7 W4 — the rename follows every breaking bump),
  `test_world_e2e`); every other suite runs in parallel workers
  (`-j`, default **8**).
- **Bounded time.** Per-suite wall cap **300 s** (kill the process group).
  Earlier detection for stuck suites: the runner samples each log every
  **2 s**; **6 s** with zero log growth AND < **0.05 s** child CPU advance
  AND no completion marker ⇒ stuck. A stuck suite with a script/scene load
  error in its log (`SCRIPT ERROR`, `Failed to load …`) is a **ZOMBIE**
  (it never started — e.g. a suite preloading a deleted file); without a
  load error it is a **HANG** (started, never finished — e.g. awaiting a
  signal that never fires). Busy suites (CPU advancing, e.g. the
  long-synchronous `test_world_e2e`) are never mistaken for stuck.
- **Classification.** GREEN (exit 0 + marker) · RED (marker with failures,
  or non-zero exit) · ZOMBIE · HANG. Report prints per-suite
  **wall ms + child-user CPU ms**, slowest first; suites over **30 s** wall
  are flagged `slow` (informational only — `test_world_e2e` is a known-slow
  legacy). Optional JSON via `--out`.
- **Exit codes.** `0` all green · `1` RED present · `2` ZOMBIE or HANG
  present (a wave may not merge on `2` even if every other suite is green).
- **Free profiling.** Suites MAY print `PROFILE <key> <int_ms>` lines around
  hot paths (e.g. day-tick probes); the runner collects them verbatim into
  the report so timings come with every gate run, never a second run.
