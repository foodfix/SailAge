# 90 — Architecture (Godot Project)

## 1. Purpose & Phase

Defines the Godot 4 project structure every implementation task builds into:
directory tree, scene patterns, autoload singletons, the scene-vs-data split,
save-file format and versioning, and how the ASCII map files become a runtime
TileMap. Gates all phases; Phase-1 tasks must not introduce structures that
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
│   │   └── world_map.tscn       # TileMap ocean sailing scene
│   ├── port/
│   │   ├── port_screen.tscn     # port hub (facility menu)
│   │   ├── market_screen.tscn
│   │   ├── shipyard_screen.tscn
│   │   ├── tavern_screen.tscn
│   │   └── inn_screen.tscn
│   ├── combat/                 # Phase 2
│   └── ui_shared/
│       ├── dialog_box.tscn
│       ├── confirm_dialog.tscn
│       ├── gameover_screen.tscn
│       └── hud.tscn
├── scripts/
│   ├── world/sailing_sim.gd    # day tick, consumption, weather, morale
│   ├── world/map_loader.gd     # ASCII map → TileMap (§9)
│   ├── port/trade_engine.gd    # price formulas from 30-PORTS-AND-TRADE.md
│   ├── port/shipyard_engine.gd
│   ├── player/character.gd     # stats, XP, officers
│   └── fleet/fleet.gd          # fleet composition, cargo maths
├── data/                        # contract owner: 10-DATA-SCHEMA.md
│   └── maps/p1_mediterranean.txt
└── tools/validate_data.py
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
| `port_entered(port_id: String)` | | harbor tile reached |
| `game_over(reason: String)` | `"starvation"`/`"scurvy"`/`"sunk"`/`"captured"` | sea-death |
| `save_completed(slot: int)` | | SaveSystem finished a write |
| `battle_started(encounter: Dictionary)` | encounter descriptor (`60-*` §4.11.11) | S10 opens a battle |
| `battle_finished(outcome: Dictionary)` | outcome block (`60-*` §4.11.9/§4.11.10) | a battle ends, any outcome |
| `duel_finished(outcome: Dictionary)` | `{result, rounds, attacker, defender}` | the S11 modal closes |

Any module may `emit`; only view/UI code and `GameState` may `connect`.
Cross-screen communication never uses direct node references.

### 5.2 DataLoader (`autoload/data_loader.gd`)

- Loads every `data/*.json` at startup into typed dictionaries keyed by id:
  `DataLoader.ports`, `.goods`, `.ship_types`, `.nations`, `.officers`,
  `.equipment`, `.discoveries`, `.quests`, `.ui_strings`, `.map_legend`.
- Entry points: `get_port(id) -> Dictionary`, `get_good(id)`, …
  plus `map_loader` handoff (§9).
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
- `world: Dictionary` • — fleet tile position, movement state, weather state
- `morale: int` • — fleet morale 0–100 (`20-*` §4.8)
- `current_port: String?` • — port id while docked; `null` at sea (save/load
  routing, `80-*` §4.6)
- `port_investments: Dictionary` • — `{port_id: gold_total}` (`30-*` §4.3)
- `known_ports: Array[String]` • — discovered ports (§20 port discovery)
- `hostile_fleets: Array` • — world-map hostile markers (`60-*` §4.11.11);
  present-but-empty before Phase 2
- `proximity_cooldowns: Dictionary` • — `{kind: day}` spawn immunity
  (`60-*` §4.8); present-but-empty before Phase 2
- `pending_encounter` — **transient, never saved**: the encounter S3 hands to
  S10 (`60-*` §4.11.11.3); S10 clears it on open
- `quests`, `discoveries_found`: Phase-2/3 fields, present-but-empty in P1
- API: `new_game(nation_id)`, `add_gold(delta)`, `advance_day()`, and thin
  helpers; heavy rules live in `scripts/` engines which mutate GameState.
- On `day_advanced`: runs the daily ledger delegation order fixed in
  `20-WORLD-AND-SAILING.md` §5 (consumption before wages before morale).

### 5.5 SaveSystem (`autoload/save_system.gd`)

- 3 slots: `user://saves/save_1.json` … `save_3.json`.
- `save(slot)`, `load(slot) -> bool`, `list_saves() -> Array[Dictionary]`
  (slot, day, nation, port, gold, timestamp for the slot UI).
- Serializes exactly the •-marked GameState fields plus
  `{"save_version": 1, "saved_at": <unix>, "phase": 1}`.
- `load` validates `save_version` and runs migrations (§8.2); on unrecoverable
  version mismatch returns `false` and leaves state untouched.

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
- **World ↔ Port:** reaching a harbor tile emits `port_entered`; the world
  scene reacts by routing to `port_screen.tscn` with `GameState.current_port`
  set. Leaving port returns to `world_map.tscn` at the harbor tile.
- **Dialogs:** `dialog_box.tscn` / `confirm_dialog.tscn` are instanced as
  modal children of the current screen; results delivered via signals, not
  callbacks into other scenes.
- **HUD:** `hud.tscn` is a child of `world_map.tscn` and `port_screen.tscn`;
  it only reads GameState + EventBus signals, never mutates.

## 8. Save Format & Versioning

### 8.1 Shape

```json
{
  "save_version": 2,
  "saved_at": 1793119712,
  "phase": 2,
  "locale": "en",
  "day": 12,
  "gold": 7830,
  "player": {},
  "fleet": [],
  "morale": 70,
  "world": {"position": {"x": 7, "y": 57}, "weather": "calm"},
  "current_port": "lisbon",
  "known_ports": ["lisbon"],
  "port_investments": {"lisbon": 500},
  "quests": [],
  "discoveries_found": [],
  "hostile_fleets": [],
  "proximity_cooldowns": {}
}
```

(`player`/`fleet` interior shapes are owned by docs 50/40; SaveSystem treats
them opaquely.)

Phase-2 additions (version 2):

| Key | Type | Default when absent | Owner |
|---|---|---|---|
| `hostile_fleets` | `[]object` | `[]` | `60-*` §4.11.11 |
| `proximity_cooldowns` | `object` `kind → day` | `{}` | `60-*` §4.8 spawn immunity |

`proximity_cooldowns` records, per hostile `kind`, the first day on which a new
spawn of that kind is allowed again after a battle (`spawn_immunity_days = 3`,
`60-*` §4.8).

### 8.2 Migration rule

- `save_version` increments on any breaking shape change.
- `SaveSystem.MIGRATIONS` is an ordered map `1: Callable`, `2: Callable`, …
  where `MIGRATIONS[n]` upgrades a version-n dict to n+1.
- Loading applies migrations from the file's version up to the current one;
  missing migration step = load failure (returns false, logs).
- Phase-2 code ships `save_version = 2` with exactly one migration:

  `MIGRATIONS[1]` — upgrades a Phase-1 payload by adding
  `"hostile_fleets": []` and `"proximity_cooldowns": {}`, adding the
  `player.equipment` block of `60-*` §4.11.12
  (`{"weapon": "", "armor": ""}`) when `player` is a non-empty object, adding
  the `fleet[i].equipment` block (`{"figurehead": "", "sail": ""}`) to every
  ship instance, and setting `phase = 2`. It never touches any other key, so a
  Phase-1 save re-saves byte-equal apart from the added keys and the version.
- Migration functions are pure: they receive a dict and return a new dict; the
  loaded file is never mutated in place.

## 9. ASCII Map → TileMap (loading pipeline)

Implemented by `scripts/world/map_loader.gd` (RefCounted, called by
DataLoader):

1. Read `data/maps/p1_mediterranean.txt` → array of 96 strings × 128 chars.
2. Read `data/map_legend.json` → char semantics + constants (fail if the file
   dimensions disagree with `grid.width/height`).
3. Build a `TileMap` with **layer 0 = terrain**: a programmatically generated
   `TileSet` whose tiles are 32×32 colored squares (placeholder palette from
   `80-UI-UX.md` §palette: sea, coastal, land, reef). One cell per file char.
4. Build **layer 1 = ports**: for each of the 30 markers, record
   `marker_cell → port_id`; place a port placeholder marker (32×32 square in
   the port's nation color + first letter of its English name as a Label).
5. Passability lookup (`is_passable(Vector2i)`) consults layer 0 kinds; port
   marker cells are always passable (they sit on sea per `10-*` §6.2).
6. The world scene queries only `map_loader`'s output; it never re-parses the
   text file.

The same pipeline serves Phase 3's full-world map by file-name swap only —
adding a map is a data-only change plus one legend entry set.

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
- **Map file shorter than 96 lines / wrong width** → DataLoader startup error;
  same path as invalid data.
- **Port entered while a dialog is open** → dialogs are modal; movement input
  is disabled while any modal exists, so this cannot occur.
- **Two scenes connected to the same EventBus signal after scene switch** →
  scenes connect in `_ready` and Godot frees connections with the node; HUD
  re-connects on each entry. Double-connection is prevented by connecting in
  `_ready` only.

## 12. Acceptance Criteria

- [ ] Directory tree (§4) is the one created by the Phase-1 setup task; any
      deviation requires amending this doc.
- [ ] Autoload list, order, and signal names (§5.1) are used verbatim in code
      and cited by name (no ad-hoc signals for the listed events).
- [ ] `project.godot` matches §6 exactly.
- [ ] Save file contains at least the §8.1 keys with `save_version` present;
      load tolerates missing optional keys only where a default is documented.
- [ ] Swapping `data/maps/p1_mediterranean.txt` for a different
      legend-conformant map file requires zero code edits (verified at the
      Phase-3 world-map task).
- [ ] Adding one new good to `data/goods.json` requires zero code edits
      (verified in the Phase-1 market task acceptance).
