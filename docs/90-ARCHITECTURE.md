# 90 — Architecture (Godot Project)

## 1. Purpose & Phase

Defines the Godot 4 project structure every implementation task builds into:
directory tree, scene patterns, autoload singletons, the scene-vs-data split,
save-file format and versioning, and how the world PNG becomes chunked runtime
TileMaps. Gates all phases; Phase-1 tasks must not introduce structures that
contradict this doc.

## 2. Artifacts

| Path | Contents |
|---|---|
| `project.godot` | Godot 4.x project file; window 1280×720 (see §6) |
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
│   └── event_bus.gd       # EventBus singleton
├── scenes/
│   ├── title/
│   │   ├── title_screen.tscn
│   │   └── nationality_select.tscn
│   ├── world/
│   │   ├── world_map.tscn       # chunked-TileMap ocean sailing scene
│   │   └── chart_screen.tscn    # S17 whole-world Chart (Phase 4)
│   ├── port/
│   │   ├── port_screen.tscn     # port hub (facility menu)
│   │   ├── provisions_dialog.tscn  # Set-Sail provisioning prompt (§4.6.1)
│   │   ├── officers_panel.tscn     # officer roster + details, S18 (§4.6.2)
│   │   ├── market_screen.tscn
│   │   ├── shipyard_screen.tscn
│   │   ├── tavern_screen.tscn
│   │   ├── inn_screen.tscn
│   │   ├── guild_screen.tscn    # Phase 3 (S12)
│   │   └── palace_screen.tscn   # Phase 3 (S13)
│   ├── combat/                 # Phase 2
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
│   ├── world/sail_path.gd      # click-to-sail A* pathing (20-* §4.2, Phase 4)
│   ├── world/discovery.gd      # Phase 3: explore/report/hints (70-* §4.4)
│   ├── world/npc_fleets.gd     # Phase 5: the living-sea fleet sim (60-* §4.1)
│   ├── world/npc_intel.gd      # Phase 5: sightings/posters/rumors queries (60-* §4.1)
│   ├── port/trade_engine.gd    # price formulas from 30-PORTS-AND-TRADE.md
│   ├── port/economy.gd         # Phase 5: stock/drift/events, pure (30-* §4.2/§4.5)
│   ├── port/shipyard_engine.gd
│   ├── port/palace_engine.gd   # Phase 3: royal missions, titles (70-* §4.3)
│   ├── quests/quest_gen.gd     # Phase 3: offers + tracking (70-* §4.9.3)
│   ├── quests/bounty.gd        # Phase 3: piracy/bounty (70-* §4.9.5)
│   ├── quests/tournament.gd    # Phase 3: bracket + prizes (70-* §4.9.7)
│   ├── player/character.gd     # stats, XP, officers
│   ├── player/fame.gd          # Phase 3: fame + title ladder (70-* §4.9.2)
│   └── fleet/fleet.gd          # fleet composition, cargo maths
├── data/                        # contract owner: 10-DATA-SCHEMA.md
│   ├── maps/world.png           # generated, tool-owned (§9)
│   └── trade_routes_built.json  # generated, tool-owned (Phase 5; 10-* §4.14)
└── tools/
    ├── validate_data.py
    ├── build_world.py           # Natural Earth → data/maps/world.png (Phase 4)
    ├── map_overrides.json       # carved-strait list (Phase 4)
    ├── build_routes.py          # trade lanes → trade_routes_built.json (Phase 5)
    └── route_overrides.json     # lane hand-fixes (Phase 5)
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
| `locale_changed(locale: String)` | `"zh"`/`"en"` | language toggle |
| `gold_changed(new_gold: int)` | | any gold delta |
| `fleet_changed()` | | ship bought/sold/sunk/repaired/cargo moved |
| `market_changed(port_id: String)` | | a trade moved a port-good's stock at that port (economy stock change; market UI refreshes) |
| `port_entered(port_id: String)` | | a port's shore tile entered (docking, `20-*` §4.11.1) |
| `game_over(reason: String)` | `"starvation"`/`"scurvy"`/`"sunk"`/`"captured"` | sea-death |
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

### 5.2 DataLoader (`autoload/data_loader.gd`)

- Loads every `data/*.json` at startup into typed dictionaries keyed by id:
  `DataLoader.ports`, `.goods`, `.ship_types`, `.nations`, `.officers`,
  `.equipment`, `.discoveries`, `.quests`, `.ui_strings`, `.map_legend`,
  plus the Phase-5 files `.npc_config`, `.npc_captains`, `.named_pirates`,
  `.market_events`, `.trade_routes`, and the tool-built
  `.trade_routes_built` (read-only, `10-*` §4.14).
  There is exactly one port file (`data/ports.json`, 100 ports) — **no
  merge step**.
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
- `player: Dictionary` • — nationality, stats, XP/level, officers, reputation
  map (shape in `50-CHARACTER-AND-PROGRESSION.md` §save-block)
- `fleet: Array` • — ship instances (shape in `40-SHIPS-AND-FLEET.md` §ship
  instance schema)
- `world: Dictionary` • — fleet tile position, `map_id` (always `"world"`,
  `DEFAULT_MAP_ID`), movement state, weather state. The explored bitset is a
  `PackedByteArray` of 291,600 bytes owned by the world scene/HUD, **not**
  saved and not part of `world`.
- `morale: int` • — fleet morale 0–100 (`20-*` §4.8)
- `current_port: String?` • — port id while docked; `null` at sea (save/load
  routing, `80-*` §4.7)
- `port_investments: Dictionary` • — `{port_id: gold_total}` (`30-*` §4.3)
- `known_ports: Array[String]` • — discovered ports (§20 port discovery)
- `npc_fleets: Array` • — every living NPC fleet, 8 roles (`60-*` §4.1);
  save shape in `10-*` §4.15. Owned by `scripts/world/npc_fleets.gd` — the
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
- `market_events: Array` • — active demand-event instances (shape in
  `10-*` §4.15); rotation in `30-*` §4.5
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
- API: `new_game(nation_id, route)`, `add_gold(delta)`,
  `advance_day()`, and thin helpers; heavy rules live in `scripts/` engines
  which mutate GameState. `world.map_id` is set to `DEFAULT_MAP_ID = "world"`
  at new game — there is no map choice.
- Day-tick listener order (`20-*` §4.3): the daily ledger runs first
  (`20-*` §5: consumption before wages before morale), then **economy
  drift + demand-event expiry** (pure `scripts/port/economy.gd`,
  `30-*` §4.2/§4.5), then `EventBus.day_advanced` fires, and the
  world-scene listeners (the NPC fleet tick) run on it — economy drift is
  always before `day_advanced`, on sea days and port day-advances alike.
- **Cap sizing (Phase 5):** normal ≈ 288 is ecology/balance, not
  performance; coasters absorb the visual traffic (≤ 5-unit trades) so
  effective long-haul trading stays ~127 fleets; far-field LOD is the
  Phase-6 lever beyond `absolute_cap`.

### 5.5 SaveSystem (`autoload/save_system.gd`)

- 3 slots: `user://saves/save_1.json` … `save_3.json`.
- `save(slot)`, `load(slot) -> bool`, `list_saves() -> Array[Dictionary]`
  (slot, day, nation, port, gold, timestamp for the slot UI).
- Serializes exactly the •-marked GameState fields plus
  `{"save_version": 5, "saved_at": <unix>, "phase": 5}`.
- `load` validates `save_version` — it must equal `SAVE_VERSION = 5`;
  **no migration chain** (§8.2): a v4 or older payload is refused
  ("pre-release save"), `load()` returns `false`, and state is untouched.

## 6. `project.godot` Requirements (locked values)

| Setting | Value |
|---|---|
| `display/window/size/viewport_width` | 1280 |
| `display/window/size/viewport_height` | 720 |
| `display/window/stretch/mode` | `canvas_items` |
| `display/window/stretch/aspect` | `keep` |
| Main scene | `scenes/title/title_screen.tscn` |
| Autoloads | EventBus, DataLoader, I18n, GameState, SaveSystem (in that order) |
| Input | keyboard+mouse only; no joypad actions in Phase 1 |

UI scales up from 1280×720 via stretch; no per-screen responsive logic.

## 7. Scene Flow Patterns

- **Screen switching:** a tiny `SceneRouter` (function on GameState,
  `change_scene(path)`) swaps the root scene via
  `get_tree().change_scene_to_file`. No scene ever frees another.
- **World ↔ Port:** docking (heading into a port's shore tile from an
  orthogonally adjacent tile, `20-*` §4.11.1) emits `port_entered`; the world
  scene reacts by routing to `port_screen.tscn` with `GameState.current_port`
  set. Leaving port returns to `world_map.tscn` on the port's **berth** tile.
- **World ⇄ Chart:** `S3 ⇄ S17` via `Tab` (open) and `Esc`/`Tab` (close); the
  Chart is an overlay view of the current session and returns to S3 with state
  untouched. `world.map_id` is a single value (`"world"`), so **no
  map-switch routing exists** anywhere in the flow.
- **Dialogs:** `dialog_box.tscn` / `confirm_dialog.tscn` are instanced as
  modal children of the current screen; results delivered via signals, not
  callbacks into other scenes.
- **HUD:** `hud.tscn` is a child of `world_map.tscn` and `port_screen.tscn`;
  it only reads GameState + EventBus signals, never mutates.

## 8. Save Format & Versioning

### 8.1 Shape

```json
{
  "save_version": 5,
  "saved_at": 1793119712,
  "phase": 5,
  "locale": "en",
  "day": 12,
  "gold": 7830,
  "player": {},
  "fleet": [],
  "morale": 70,
  "world": {"position": {"x": 1025, "y": 307}, "map_id": "world", "weather": "calm"},
  "current_port": "lisbon",
  "known_ports": ["lisbon"],
  "port_investments": {"lisbon": 500},
  "quests": [],
  "discoveries_found": [],
  "npc_fleets": [],
  "proximity_cooldowns": {},
  "market_stocks": {},
  "wrecks": [],
  "npc_preset": "normal",
  "market_events": []
}
```

(`player`/`fleet` interior shapes are owned by docs 50/40; SaveSystem treats
them opaquely.)

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
| `npc_fleets` | `[]object` | `[]` | `60-*` §4.1; renames v2's `hostile_fleets`; shape in `10-*` §4.15 |
| `market_stocks` | `object port_id → {good_id → stock}` | derived resting stock (`30-*` §4.2), no RNG | `30-*` §4.2; shape in `10-*` §4.15 |
| `wrecks` | `[]object` | `[]` | `60-*` auto-resolve; shape in `10-*` §4.15 |
| `npc_preset` | string preset id | `"normal"` | `10-*` §4.10 |
| `market_events` | `[]object` | `[]` | `30-*` §4.5; shape in `10-*` §4.15 |

**No migration; v4 refused (Phase-5 decision 5).** `SAVE_VERSION = 5`,
`PHASE = 5`; version 5 adds **no `MIGRATIONS` entry and performs no payload
transformation**. All new state is initialized by `new_game`; a v4 payload
is refused like any older version (`load()` false, "pre-release save"
logged); see §8.2 for the normative rule.

### 8.2 Versioning rule (no migration chain)

**Development-stage scope (normative; amended 2026-10-31, Phase 5).**
SailAge has not shipped; there are no player saves in the wild. Backward
compatibility across phases is therefore **explicitly out of scope until
the first release**, and no task may spend effort on it. Concretely:

- `save_version` increments on any breaking shape change. The current
  values are `SAVE_VERSION = 5`, `PHASE = 5`.
- **No migration chain.** `SaveSystem.MIGRATIONS` is empty. The whole load
  contract is the identity: a payload whose `save_version` equals
  `SAVE_VERSION` loads (round-trip); **any older payload — v4 included —
  is refused** (`load()` returns false, logs "pre-release save"). There is
  no v4 → v5 step, and none may be reintroduced: Phase 4 removed the chain
  (`IMPLEMENT-Phase5.md` correction 4) and Phase 5 keeps it removed
  (decision 5).
- All Phase-5 state is initialized by `new_game` (stocks derived; fleets
  seeded to half the cap there and only there); nothing is back-filled at
  load.
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
2. Verify size **2160 × 1080** and an indexed palette whose indices are
   ⊆ `0–4`; anything else is a DataLoader startup error (§11).
3. Passability = byte lookup on the decoded `Image`'s palette index
   (0–4 → `~ . # ^ I`, `10-*` §6.2). `is_passable(x, y)` is **wrap-aware on
   x** (`x` taken mod 2160) and false for `y` out of range and for
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
   so a port at `x = 0` also shows at `x = 2160`. The loader exposes
   `port_cell(id)` (berth) and `shore_cell(id)`; both are memoised.
6. The camera centers on the fleet and `x` wraps (§7); `y` clamps to the
   1080-tile height.
7. The world scene queries only the loader; it **never re-reads the PNG**.

The loader's passability API does not change movement rules (`20-*` §4.2):

- **No corner cutting:** a diagonal move is blocked if either orthogonal
  neighbor of the target corner is impassable.
- **Longitude wraps.** `x` is taken mod 2160 everywhere (movement, BFS,
  camera, click); a fleet at `x = 2159` stepping east lands on `x = 0`.
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
  (`20-*` §4.2): fleet and target `x` are shifted together into `[0, 2160)`
  before the `AStarGrid2D` query and the path is offset back, so a fleet at
  `x = 2100` clicking `x = 50` gets the short westward route.

## 12. Acceptance Criteria

- [ ] Directory tree (§4) is the one created by the Phase-1 setup task; any
      deviation requires amending this doc.
- [ ] Autoload list, order, and signal names (§5.1) are used verbatim in code
      and cited by name (no ad-hoc signals for the listed events).
- [ ] `project.godot` matches §6 exactly.
- [ ] Save file contains at least the §8.1 keys with `save_version` present;
      load tolerates missing optional keys only where a default is documented.
- [ ] A v5 payload round-trips exactly (fleet positions, route legs,
      captains, stocks); a v4 payload is refused with the standard message
      (`load()` false, "pre-release save" logged — §8.2).
- [ ] Swapping `data/maps/world.png` for another palette-conformant
      2160×1080 indexed PNG requires zero code edits.
- [ ] Adding one new good to `data/goods.json` requires zero code edits
      (verified in the Phase-1 market task acceptance).
