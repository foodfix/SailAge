# 10 — Data Schema

## 1. Purpose & Phase

This document is the contract every other doc and every implementation task
depends on. It defines:

- The exact JSON file layout under `data/` and the schema of every entity type.
- The i18n rule for all display strings.
- The spec for `tools/validate_data.py`, the validator all data must pass.
- The locked content lists: 100 ports, 20 goods, 8 ship types,
  6 nations, 6 starter officers (§7.1–7.5), plus the Phase-5 lists —
  12 trade lanes (§7.6), 7 captain name pools (§7.7), 4 named pirates
  (§7.8) — exhaustive, with no open slots.
- The Phase-5 npc/economy schemas (`npc_config`, `npc_captains`,
  `named_pirates`, `market_events` — §4.10–4.13), the trade-route pair
  (`trade_routes.json` hand-authored, `trade_routes_built.json` tool-owned —
  §4.14), and the living-economy save-block shapes (§4.15).
- The grid constants, tile legend, and the generated raster world artifact
  (`data/maps/world.png`) with its harbor-snap rule — ports are `lat`/`lon`
  data in `data/ports.json`, never hand-placed cells.
- The harbor-relief (anti-softlock) fallback spec.

Gates all phases. Later-phase entity schemas (`Equipment`, `Discovery`, `Quest`)
are fully specified here; each data file ships when its owning phase lands.

## 2. Artifacts

| Path | Contents | Owner doc |
|---|---|---|
| `data/nations.json` | Nation list (incl. `rivals`) | this doc |
| `data/goods.json` | Good list | this doc |
| `data/ship_types.json` | ShipType list | this doc |
| `data/ports.json` | Port list — all 100 locked ports in one envelope; `lat`/`lon` are the geographic truth | this doc |
| `data/officers.json` | Officer roster | this doc |
| `data/discoveries.json` | Discovery list; `lat`/`lon` are the geographic truth | this doc / `70-*` |
| `data/quests.json` | Quest templates | this doc / `70-*` |
| `data/equipment.json` | `[]` until Phase 2 | this doc / `60-*` |
| `data/npc_config.json` | Density-dial config: presets, budgets, flow, `absolute_cap` (§4.10) | this doc / `80-*` |
| `data/npc_captains.json` | Captain name pools — 7 incl. the nationless `""` pool (§4.11, §7.7) | this doc / `60-*` |
| `data/named_pirates.json` | The 4 named pirates, tiers 1–3 (§4.12, §7.8) | this doc / `60-*` / `70-*` |
| `data/market_events.json` | Demand-event templates (§4.13) | this doc / `30-*` |
| `data/trade_routes.json` | Hand-authored major trade lanes — exactly the 12 locked ids of §7.6 (§4.14) | this doc / `20-*` / `60-*` |
| `data/map_legend.json` | MapLegend (tiles + grid constants) | this doc |
| `data/maps/maps.json` | Map index (exactly one entry, `id: "world"`) | `90-*` §9.1 |
| `data/maps/world.png` | Generated world map artifact — indexed PNG, 2160×1080, 1 px = 1 tile (§6.3) | this doc |
| `data/maps/world_report.json` | Builder report: build params, sea fraction, ice extent, component sizes > 2000 tiles, per-port `harbor_tile` (berth) and `shore_tile` (§6.3, §8.1) | this doc |
| `data/trade_routes_built.json` | Lane-builder artifact: tile paths + junction graph + per-port spokes (§4.14) — tool-owned, never hand-edited | this doc |
| `tools/build_world.py` | World generator: shorelines → tiles → `world.png` + `world_report.json` (§6.3); `--ascii` debug export only | this doc / `IMPLEMENT-Phase4.md` task C |
| `tools/map_overrides.json` | Waterway carves (Gibraltar, Bosphorus, …) and tidal-river carves (§6.1, `IMPLEMENT-Phase4.md` task D) | this doc |
| `tools/build_routes.py` | Lane builder: `trade_routes.json` → snapped/rasterized lanes, junction graph, spokes → `trade_routes_built.json` (§4.14); `--ascii` debug export only | this doc / `IMPLEMENT-Phase5.md` task F |
| `tools/route_overrides.json` | Hand fixes consumed by the lane builder (§4.14) | this doc |
| `tools/assets/` | Vendored public-domain shapefiles (Natural Earth 10 m land + minor islands + lakes) and `LICENSE-NOTES.md` with per-file SHA-256 | this doc |
| `data/ui_strings.json` | UI-frame L10n strings | `80-UI-UX.md` |
| `tools/validate_data.py` | Schema/i18n/integrity/map/npc-economy/trade-route validator (groups 1–8, §8) | this doc |

## 3. Shared Conventions

### 3.1 Primitive types

| Name | Definition |
|---|---|
| `id` | String matching `^[a-z][a-z0-9_]*$`, unique within its entity file |
| `L10nString` | Object with **exactly** two keys: `{"zh": <non-empty string>, "en": <non-empty string>}` |
| `money` | Integer ≥ 0, unit: gold pieces (g) |
| `day` | Integer ≥ 0, the game-clock tick unit (1 day per tick) |
| `tile` | Unit of distance/size on the world grid |
| `cargo unit` | Abstract hold space; 1 unit of any good, provision, or water = 1 cargo unit |
| `tilePos` | `{"x": int, "y": int}` with `0 ≤ x < 2160`, `0 ≤ y < 1080` (see §6). `x` wraps: every consumer (movement, BFS, camera, click) takes `x mod 2160`; `y` is bounded and never wraps. |
| `lat` / `lon` | WGS84 decimal degrees: `lat ∈ [-90, 90]`, `lon ∈ [-180, 180]`. The geographic truth for ports and discoveries; the grid cell is derived by §6.1's projection + harbor-snap rule. |

### 3.2 File envelope

Every entity file under `data/` is a JSON object:

```json
{
  "version": 1,
  "ports": [ ]
}
```

- `version` (int, required): schema version of the file; starts at 1; bump when
  the file's schema changes. There is no data/save migration chain
  (`90-*` §8.2) — a version bump is a breaking change the whole tree takes
  at once.
- The second key is the plural entity name from §2 and contains the array.
- UTF-8, 2-space indent, trailing newline. No comments (JSON).

### 3.3 i18n rule (normative)

1. Every display string anywhere in `data/` is an `L10nString`.
2. Both locales must be present and non-empty; a missing or empty locale is a
   validation error (validator exit 2), never a runtime fallback.
3. Non-display strings (`id`, `color`, keys) are plain strings.
4. Unicode: `zh` values use Simplified Chinese; `en` values use sentence case.
5. Numbers/units are localizable only via full-sentence strings; keep numbers
   out of L10nString values (UI composes them) except in flavor text.

## 4. Entity Schemas

Each subsection gives a field table followed by complete, valid examples.
Types use §3.1 names plus JSON primitives. `[]T` = array of T.

### 4.1 Nation — `data/nations.json`

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 6 locked ids (§7.4) |
| `name` | L10nString | |
| `color` | string | hex `#rrggbb`, primary faction color for UI |
| `capital_port_id` | id | references Port; the nation's palace city (Phase 3) |
| `start_port_id` | id | references Port; new-game spawn port |
| `start_ship_type_id` | id | references ShipType; starter ship at new game |
| `start_gold` | money | gold at new game |
| `start_reputation` | int −100…100 | initial reputation with own nation; other nations start at 0 |
| `rivals` | []id | **Phase 3**: exactly 2 other nation ids that gain `+2` reputation when the player commits piracy against this nation (`70-*` §4.9.5). Symmetry is not required. |
| `description` | L10nString | 1–2 sentences shown on the nationality-select screen |

```json
{
  "version": 1,
  "nations": [
    {
      "id": "portugal",
      "name": {"zh": "葡萄牙", "en": "Portugal"},
      "color": "#1a8c4e",
      "capital_port_id": "lisbon",
      "start_port_id": "lisbon",
      "start_ship_type_id": "caravel",
      "start_gold": 5000,
      "start_reputation": 20,
      "description": {
        "zh": "先驱航海之国。从里斯本出发,以卡拉维尔帆船开拓贸易航线。",
        "en": "The pioneering seafaring nation. Sail from Lisbon in a caravel and blaze new trade routes."
      }
    }
  ]
}
```

### 4.2 Good — `data/goods.json`

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 20 locked ids (§7.2) |
| `name` | L10nString | |
| `category` | enum | `food` \| `textile` \| `luxury` \| `material` |
| `base_price` | money | global baseline price per cargo unit, before port modifiers (formula in `30-PORTS-AND-TRADE.md`) |
| `unit_size` | int | cargo units per unit of good; locked at `1` for all Phase-1 goods |

```json
{
  "version": 1,
  "goods": [
    {
      "id": "wine",
      "name": {"zh": "葡萄酒", "en": "Wine"},
      "category": "food",
      "base_price": 30,
      "unit_size": 1
    },
    {
      "id": "spices",
      "name": {"zh": "香料", "en": "Spices"},
      "category": "luxury",
      "base_price": 150,
      "unit_size": 1
    }
  ]
}
```

### 4.3 ShipType — `data/ship_types.json`

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 8 locked ids (§7.3) |
| `name` | L10nString | |
| `class` | enum | `sail` \| `oar` \| `hybrid` (oar/hybrid ignore wind modifiers, defined in `20-WORLD-AND-SAILING.md`) |
| `base_price` | money | purchase price of a new hull at 100% durability |
| `durability` | int > 0 | max hull HP; 0 at sea = sinking |
| `capacity` | int > 0 | max cargo units (goods + provisions + water combined; armament shares capacity per `40-SHIPS-AND-FLEET.md`) |
| `speed` | int > 0 | tiles per day before modifiers |
| `crew_min` | int > 0 | below this, speed penalty applies (formula in `20-*`) |
| `crew_max` | int ≥ crew_min | hard crew cap |
| `armament_slots` | int ≥ 0 | max cannon count (Phase 2) |

```json
{
  "version": 1,
  "ship_types": [
    {
      "id": "caravel",
      "name": {"zh": "卡拉维尔帆船", "en": "Caravel"},
      "class": "sail",
      "base_price": 8000,
      "durability": 90,
      "capacity": 120,
      "speed": 10,
      "crew_min": 15,
      "crew_max": 45,
      "armament_slots": 6
    }
  ]
}
```

### 4.4 Port — `data/ports.json`

`data/ports.json` holds **all 100 ports** in one envelope (§7.1); there is no
second port file and no per-map port variant.

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 100 locked ids in §7.1 |
| `name` | L10nString | |
| `nation_id` | id | references Nation |
| `lat` | number | WGS84 latitude in degrees, `-90 ≤ lat ≤ 90`; the port's real-world position and the **geographic truth** |
| `lon` | number | WGS84 longitude in degrees, `-180 ≤ lon ≤ 180`; geographic truth |
| `produces` | []id | ⊆ Good ids; port sells these cheaper (supply factor in `30-*`) |
| `demands` | []id | ⊆ Good ids; port buys these dearer |
| `market_goods` | []id | optional; ⊆ Good ids; when absent, **all 20 goods trade here** |
| `facilities` | object | keys with activation phase: `market:1, shipyard:1, tavern:1, inn:1, guild:3, palace:3`. `palace` is **omitted** unless this port is a nation's `capital_port_id` |
| `flavor` | L10nString | 1 sentence shown in the port-entry greeting |

The harbor **pair** — the berth tile the fleet stands on and the shore tile it
docks into (`20-*` §4.11.1) — is **never stored**. Both are derived at
load/build time from `lat`/`lon` by §6.1's projection plus the locked
harbor-snap rule in §6.1, by both `tools/build_world.py` and the GDScript
runtime (identical rule, agreement tested by validator group 6, §8).
Ports render as an overlay from JSON; no port character appears in the terrain
(§6.2). The retired per-map keys (`marker`, `position`, the former world-map
marker block, and `phase`) no longer exist anywhere in a port row.

```json
{
  "version": 1,
  "ports": [
    {
      "id": "lisbon",
      "name": {"zh": "里斯本", "en": "Lisbon"},
      "nation_id": "portugal",
      "lat": 38.72,
      "lon": -9.14,
      "produces": ["wine", "salt"],
      "demands": ["spices", "silk", "timber"],
      "facilities": {"market": 1, "shipyard": 1, "tavern": 1, "inn": 1, "guild": 3, "palace": 3},
      "flavor": {"zh": "大航海时代的起点,特茹河口帆影如林。", "en": "Cradle of the Age of Discovery, its Tagus anchorage thick with sails."}
    },
    {
      "id": "venice",
      "name": {"zh": "威尼斯", "en": "Venice"},
      "nation_id": "italy",
      "lat": 45.44,
      "lon": 12.33,
      "produces": ["glassware", "perfume"],
      "demands": ["spices", "silk", "cotton_cloth"],
      "facilities": {"market": 1, "shipyard": 1, "tavern": 1, "inn": 1, "guild": 3, "palace": 3},
      "flavor": {"zh": "亚得里亚海的女王,商栈与运河之城。", "en": "Queen of the Adriatic, city of canals and counting-houses."}
    }
  ]
}
```

### 4.5 Officer — `data/officers.json`

| Field | Type | Rule |
|---|---|---|
| `id` | id | |
| `name` | L10nString | character name |
| `nation_id` | id | references Nation |
| `role` | enum | `navigator` \| `boatswain` \| `gunner` (effects in `50-CHARACTER-AND-PROGRESSION.md`) |
| `stats` | object | keys `leadership`, `seamanship`, `combat`, `navigation`: ints 1–20 |
| `wage_daily` | money | gold per day while employed |
| `recruit_ports` | []id | ⊆ Port ids; taverns where this officer can be hired |
| `bio` | L10nString | 1 sentence shown in the recruit dialog |

```json
{
  "version": 1,
  "officers": [
    {
      "id": "off_mateus_alvares",
      "name": {"zh": "马特乌斯·阿尔瓦雷斯", "en": "Mateus Álvares"},
      "nation_id": "portugal",
      "role": "navigator",
      "stats": {"leadership": 10, "seamanship": 14, "combat": 6, "navigation": 16},
      "wage_daily": 30,
      "recruit_ports": ["lisbon", "madeira"],
      "bio": {"zh": "一位在老领航员手下学艺的青年,星象与海图无一不精。", "en": "A young pilot schooled by old navigators; at home with stars and charts alike."}
    }
  ]
}
```

### 4.6 Equipment — `data/equipment.json` *(Phase 2)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | |
| `name` | L10nString | |
| `slot` | enum | `weapon` \| `armor` \| `figurehead` \| `sail` |
| `modifiers` | object | stat-name → int delta; stat names from `50-*` (player) or `40-*` (ship) |
| `price` | money | |
| `phase` | int | locked at `2` for all Phase-2 equipment |

Locked Phase-2 content set (8 items): `60-*` §4.11.13. Modifier semantics
(which slot is player-worn, which ship-bound, and what each stat does in a
battle or a duel) are pinned in `60-*` §4.11.12.

```json
{
  "version": 1,
  "equipment": [
    {
      "id": "eq_cutlass",
      "name": {"zh": "水手弯刀", "en": "Sailor's Cutlass"},
      "slot": "weapon",
      "modifiers": {"combat": 3},
      "price": 400,
      "phase": 2
    }
  ]
}
```

### 4.7 Discovery — `data/discoveries.json` *(Phase 3)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | |
| `name` | L10nString | |
| `category` | enum | `natural` \| `ruins` \| `relic` \| `creature` |
| `lat` | number | WGS84 latitude in degrees, `-90 ≤ lat ≤ 90`; where it is found |
| `lon` | number | WGS84 longitude in degrees, `-180 ≤ lon ≤ 180` |
| `fame` | int > 0 | fame granted on first report |
| `report_reward_gold` | money | gold paid by the guild on report |
| `region_hint` | L10nString | 1-sentence rumor text sold at taverns |

The `phase` key is dead and must not appear. Discovery tiles are derived from
`lat`/`lon` the same way a port's berth tile is (§6.1); the validator requires
the placed tile to be passable or orthogonally adjacent to a passable tile
(§8, group 6).

```json
{
  "version": 1,
  "discoveries": [
    {
      "id": "disc_atlas_cedars",
      "name": {"zh": "阿特拉斯雪松林", "en": "Cedars of the Atlas"},
      "category": "natural",
      "lat": 32.08,
      "lon": -9.42,
      "fame": 150,
      "report_reward_gold": 2000,
      "region_hint": {"zh": "据说在南方的深山里,有参天的古老雪松。", "en": "Deep in the southern mountains, ancient cedars are said to touch the sky."}
    }
  ]
}
```

A discovery's `lat`/`lon` follows the **same water rule as a port harbor**
(§6.1): the tile it maps to is passable water or orthogonally adjacent to it,
so the Explore action can reach it (`70-*` §4.4). The illustrative coordinate
above sits in coastal water off Safi with the High Atlas inland — a hint may
name an inland feature, but its coordinate is always the sea approach.

### 4.8 Quest — `data/quests.json` *(Phase 3)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | |
| `type` | enum | `delivery` \| `bounty` \| `exploration` \| `royal` |
| `giver` | enum | `guild` \| `palace` |
| `name` | L10nString | |
| `description` | L10nString | |
| `requirements` | object | type-specific keys; `delivery`: `good_id` (id), `quantity` (int), `dest_port_id` (id); `bounty`: `target_fleet_id` (id); `exploration`: `discovery_id` (id); `royal`: `objective` (L10nString) + `dest_port_id` (id) |
| `rewards` | object | keys: `gold` (money), `reputation` (object nation_id → int delta), `fame` (int) |
| `expiry_days` | int > 0 | days after acceptance the quest fails |
| `phase` | int | locked at `3` |

This file holds **templates** (§`70-*` §4.9.3 pins the 9 rows); the same
`requirements`/`rewards` keys carry the *draw rules* a template's generator
fills (`quantity`/`dest_port_id`/`target_fleet_id`/`discovery_id` are chosen
at offer time). A template row's `requirements` therefore states the fields
its type will fill, with the placeholder values the §4.9.3 draw rules
replace, and `rewards` states the band. Royal templates also carry
`requirements.kind` ∈ `royal_delivery|royal_patrol|royal_chart`.

```json
{
  "version": 1,
  "quests": [
    {
      "id": "qt_delivery_wine",
      "type": "delivery",
      "giver": "guild",
      "name": {"zh": "葡萄酒的托付", "en": "A Commission of Wine"},
      "description": {"zh": "公会需要一批葡萄酒送往他乡。", "en": "The guild needs a shipment of wine carried to another shore."},
      "requirements": {"good_id": "wine", "quantity": 20, "dest_port_id": "london"},
      "rewards": {"gold": 1200, "reputation": {"england": 5}, "fame": 10},
      "expiry_days": 30,
      "phase": 3
    }
  ]
}
```

### 4.9 MapLegend — `data/map_legend.json`

| Field | Type | Rule |
|---|---|---|
| `tile_size_px` | int | locked `32` |
| `grid` | object | `{"width": 2160, "height": 1080}` — locked (§6.1) |
| `tiles` | object | char → `{"kind": string, "passable": bool}`; locked keys `~ . # ^ I` (§6.2) |

There is no `port_markers` table: port markers left the map (decision 7 in
`IMPLEMENT-Phase4.md`). Ports are an overlay layer drawn from
`data/ports.json#ports[].lat/lon` via the harbor-snap rule (§6.1), so the
legend carries only `version`, `tile_size_px`, `grid`, and `tiles`.

```json
{
  "version": 1,
  "tile_size_px": 32,
  "grid": {"width": 2160, "height": 1080},
  "tiles": {
    "~": {"kind": "sea", "passable": true},
    ".": {"kind": "coastal_sea", "passable": true},
    "#": {"kind": "land", "passable": false},
    "^": {"kind": "reef", "passable": false},
    "I": {"kind": "polar_ice", "passable": false}
  }
}
```

### 4.10 NpcConfig — `data/npc_config.json` *(Phase 5)*

The density-dial config. Not an entity file: one config block, no display
strings (validator group 1 exempts it from the plural-key rule, exactly like
`map_legend.json`).

| Field | Type | Rule |
|---|---|---|
| `version` | int | `1` |
| `presets` | object | exactly the 5 locked preset ids → multiplier; every multiplier ≥ 0; exactly one multiplier is `1.0` and `default_preset` names it (group 7) |
| `default_preset` | id | ∈ `presets`; the value `GameState.npc_preset` starts at |
| `budgets` | object | per-role budget constants, every value > 0 (group 7); the per-role budget formulas that consume them are pinned in `60-*` §4.1 |
| `flow` | object | spawn-flow constants, every value > 0 (group 7) |
| `absolute_cap` | int | hard upper bound on live NPC fleets (wrecks are saved in `GameState.wrecks` and never counted); group 7 enforces the locked cap |

The file content is **locked verbatim** — task D copies this block; the
`presets`/`budgets`/`flow` key sets are exactly these:

```json
{
  "version": 1,
  "presets": {"deserted": 0.0, "low": 0.5, "normal": 1.0, "high": 2.0,
               "extreme": 4.0},
  "default_preset": "normal",
  "budgets": {"traders_mult_per_port": 1.25, "coasters_mult_per_port": 0.75,
               "patrols_div_ports": 6, "patrols_min": 1,
               "couriers_per_nation": 2, "privateers_per_rivalry": 2,
               "pirate_base": 8, "pirates_per_unpatrolled_zone": 1},
  "flow": {"spawns_per_day_base": 4, "path_budget_ms_per_day": 250,
            "trade_units_per_port_call": 30, "coaster_trade_units": 5},
  "absolute_cap": 2048
}
```

Preset semantics (`80-*`: the S2 row and the S19 settings modal): the
multiplier scales every role budget (`ceil` per role); `deserted` means zero
NPC spawns and contacts; raising the preset refills via the daily trickle,
lowering **never culls** living fleets.

### 4.11 NpcCaptainPools — `data/npc_captains.json` *(Phase 5)*

Envelope `{"version": 1, "pools": [...]}` — the plural key is `pools`
(named in the group-1 exception, §8).

| Field | Type | Rule |
|---|---|---|
| `nation_id` | id \| `""` | one of the 6 locked nation ids (§7.4) **or** the empty string — the nationless pool |
| `names` | []L10nString | ≥ 8 entries (§7.7); every entry has non-empty zh and en |

Locked pool set: exactly 7 (§7.7). Every fleet draws
`captain: {"pool_id": id, "name_index": int}` at spawn from its nation's
pool — pirates draw from `""` — via its seeded stream (`60-*` §4.1); the
drawn name is stable for the fleet's life and survives save/load.

```json
{
  "version": 1,
  "pools": [
    {
      "nation_id": "portugal",
      "names": [
        {"zh": "若昂·阿尔梅达", "en": "João Almeida"},
        {"zh": "佩德罗·努诺", "en": "Pedro Nuno"},
        {"zh": "迪奥戈·苏亚雷斯", "en": "Diogo Soares"},
        {"zh": "费尔南·科埃略", "en": "Fernão Coelho"},
        {"zh": "阿方索·皮雷斯", "en": "Afonso Pires"},
        {"zh": "瓦斯科·马丁斯", "en": "Vasco Martins"},
        {"zh": "努诺·阿尔瓦雷斯", "en": "Nuno Álvares"},
        {"zh": "吉尔·埃阿尼斯", "en": "Gil Eanes"}
      ]
    }
  ]
}
```

### 4.12 NamedPirate — `data/named_pirates.json` *(Phase 5)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique |
| `name` | L10nString | the captain's name |
| `tier` | int | `1 … 3` (§7.8; bounty-tier semantics in `70-*` §4.5) |

Exactly 4 entries (§7.8); names are era-plausible authored content (task D).
A defeated named pirate respawns under a new name on the `60-*` §4.1
schedule; `quest_gen` bounty targets prefer named captains (`70-*` §4.9.5).

```json
{
  "version": 1,
  "named_pirates": [
    {
      "id": "pirate_murad_red_sail",
      "name": {"zh": "「红帆」穆拉德", "en": "Murad the Red Sail"},
      "tier": 2
    }
  ]
}
```

### 4.13 MarketEvent — `data/market_events.json` *(Phase 5)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique |
| `scope` | enum | `"port"` — the only valid value this phase (group 7); rotation binds each instance to a concrete port (`30-*` §4.5) |
| `cadence_days` | int > 0 | width of the template's seeded scheduling window (`30-*` §4.5) |
| `duration_days` | int > 0 | how long the rest-override stays active |
| `shifts` | object | good id → int delta; keys ⊆ goods; each shift bounded by the group-7 rest-band check (§8.2) |
| `name` | L10nString | tavern-telegraph and rumor display name |

≈ 8 templates are authored from the locked families of `30-*` §4.5
(seasonal cycles, one-off surges). Effect, budget (≤ 1 active event per
nation, ≤ 4 world-wide), tavern telegraph, and the self-limiting trader
response are pinned in `30-*` §4.5; active instances persist in
`GameState.market_events` (§4.15).

```json
{
  "version": 1,
  "market_events": [
    {
      "id": "evt_harvest_festival",
      "scope": "port",
      "cadence_days": 120,
      "duration_days": 14,
      "shifts": {"wheat": -25, "wine": -20},
      "name": {"zh": "丰收节宴饮", "en": "Harvest Festival Feasting"}
    }
  ]
}
```

### 4.14 TradeRoute — `data/trade_routes.json` + `data/trade_routes_built.json` *(Phase 5)*

`data/trade_routes.json` holds **only the major lanes** — exactly the 12
locked ids of §7.6, hand-authored as historical facts. Envelope
`{"version": 1, "lanes": [...]}` (group-1 exception: key `lanes`).

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 12 locked lane ids (§7.6) |
| `class` | enum | `"major"`; minor spokes are builder-generated and never stored in this file |
| `nations` | []id | ⊆ Nation ids; the fleets that work the lane |
| `waypoints` | [][lat, lon] | ≥ 2 pairs in the `ports.json` coordinate space (§3.1); wrap-aware across the dateline — a crossing segment keeps `x` monotonic under wrap (the Manila lane) |
| `goods` | []id | ⊆ Good ids; the lane's historical trade goods |
| `chokepoints` | []string | ≥ 1 snake_case tag per lane naming the historical choke points the lane passes |

```json
{
  "version": 1,
  "lanes": [
    {
      "id": "carreira_da_india",
      "class": "major",
      "nations": ["portugal"],
      "waypoints": [[38.72, -9.14], [36.5, -8.5], [16.0, -24.0], [-34.8, 18.4], [-20.0, 60.0], [15.50, 73.83]],
      "goods": ["spices", "cotton_cloth"],
      "chokepoints": ["strait_of_gibraltar", "cape_of_good_hope"]
    }
  ]
}
```

Builder rules (locked; `tools/build_routes.py`, mirroring `build_world.py`
governance):

- **Waypoint snap:** every waypoint snaps to a water tile by the §6.1
  harbor-snap rule (≤ 2 tiles Chebyshev, wrap-aware, tie-break smallest
  `(y, x)`); the builder may share `build_world.py`'s PNG decoder.
- **Segment passability:** every consecutive waypoint pair is walked on the
  raster; a segment that steps on an impassable tile is a hard build error
  naming the lane (group 8).
- **Rasterization + junction graph:** every lane becomes a tile path and the
  builder extracts the junction graph the runtime routes over (`60-*` §4.1).
- **Minor spokes:** exactly one generated spoke per port — to the nearest
  lane waypoint within Chebyshev 20 (wrap-aware), else a direct generated
  spoke to the port's national capital. A port with neither is a hard
  build/validator error naming the port, never a runtime stall.
- **Determinism:** two consecutive builds produce a **byte-identical**
  `data/trade_routes_built.json` (group 8 re-asserts it). Hand fixes go in
  `tools/route_overrides.json` — plus minimal, per-lane-reported waypoint
  edits to this file — never by touching the built file.

`data/trade_routes_built.json` is a **tool-owned artifact** with the same
standing as `data/maps/world.png`: written only by `tools/build_routes.py`,
**never hand-edited**. It records the per-lane tile paths, the junction
graph, the per-port spokes, and build params. Its envelope is
`{"version", "generated_by", "artifact", …}` — a tool output, not an entity
file (group 1 exempts it exactly like `maps/world_report.json`). Runtime
routing over the graph is `20-*`/`60-*` material.

### 4.15 Save-block shapes (Phase 5)

The five living-economy save blocks — keys of the v5 payload (`90-*` §8.1).
Not data files: runtime state whose shapes this doc pins. Shapes only;
behavior lives in `30-*`/`60-*`:

| GameState field | Type | Shape |
|---|---|---|
| `market_stocks` | object | `{port_id: {good_id: stock int}}` — every port × every good that trades there; initialized at `new_game` from the derived resting stock (`30-*` §4.2), no RNG; stock range per `30-*` §4.2 |
| `npc_fleets` | []object | fleet dicts (table below); renames the retired `hostile_fleets` |
| `wrecks` | []object | `{"cell": tilePos, "cargo": {good_id: units}, "salvage_gold": money, "spawn_day": day}` — contents per the `60-*` auto-resolve table (cargo or salvage gold); expiry on the `60-*` schedule |
| `npc_preset` | id | one of the §4.10 preset keys; default `"normal"` |
| `market_events` | []object | active instances: `{"template_id": id, "port_id": id, "start_day": day}`; expiry derives from the template's `duration_days` (`30-*` §4.5) |

Fleet dict — the locked save shape (`60-*` §4.1):

| Field | Type | Rule |
|---|---|---|
| `id` | string | stable fleet id; the seeded streams (captain, specialty, decisions) key off it |
| `role` | id | one of the 8 fleet roles (`60-*` §4.1) |
| `nation_id` | id \| `""` | owner nation; pirates keep `""` |
| `cell` | tilePos | current grid position (§3.1; `x` wraps) |
| `route` | object | `{"lanes": []id, "leg": int, "tile_index": int}` — position on the built lane network (§4.14) |
| `cargo` | object | `{good_id: units}` — the actual hold contents |
| `captain` | object | `{"pool_id": id \| "", "name_index": int}` into `npc_captains.json` (§4.11) |
| `specialty` | id | optional; the good id drawn at spawn (traders) |
| `cooldown_until_day` | day | pursuit/spawn cooldown |

```json
{
  "id": "fleet_spain_trader_017",
  "role": "trader",
  "nation_id": "spain",
  "cell": {"x": 1025, "y": 307},
  "route": {"lanes": ["west_indies_flota"], "leg": 1, "tile_index": 42},
  "cargo": {"wine": 28},
  "captain": {"pool_id": "spain", "name_index": 3},
  "specialty": "wine",
  "cooldown_until_day": 0
}
```

## 5. Harbor-Relief Fallback (anti-softlock)

Locked rule, implemented at the inn (facility `inn`), behavior detailed in
`50-CHARACTER-AND-PROGRESSION.md`:

- **Availability:** every port inn, from Phase 1.
- **Condition:** the player's fleet contains 0 ships AND no officers are
  employed AND `player_gold < 1200` (the cheapest hull, `latin`, §7.3).
- **Action:** "Work an odd job" — effect: `gold += 100`, `day += 1`. Repeatable
  while the condition holds (no cooldown beyond the 1-day advance).
- **Strings:** the offer and result messages are L10nStrings in
  `data/ui_strings.json` (keys `inn.odd_job.offer`, `inn.odd_job.result`).
- **Rationale:** from 0 gold, 12 odd jobs reach exactly the 1,200g `latin`,
  so a shipless player always has a finite path back to sailing and a softlock
  is unreachable — consistent with the sea-death-only game-over rule.
- **Why the threshold is 1,200, not 100 (amended).** The earlier wording gated
  on `gold < 100` while paying `+100`, which is self-defeating: one payout
  leaves exactly 100g, the gate closes, and the purse can never exceed 100g —
  the 1,200g hull in the rationale was arithmetically unreachable, i.e. the
  fallback caused the softlock it exists to prevent. Gating on the cheapest
  hull price is the same intent, stateless, and makes "at most 12 odd jobs"
  exactly true. The condition is re-evaluated on the inn screen open and after
  every job, so it self-clears the moment a ship is bought.

## 6. Map Constants & Legend

### 6.1 Locked constants

The single source of truth for the grid. Values are copied verbatim from the
Locked constants table in `IMPLEMENT-Phase4.md`; no consumer may derive one
differently.

| Constant | Value | Used by |
|---|---|---|
| Grid | `2160 × 1080` tiles | the single world; `20-*`, `60-*`, `80-*`, `90-*` |
| Tiles per degree | `6`; 1 tile = 10′ lat = 10 nm | all distance/speed math |
| Addressing | `lon = x/6 − 180`, `lat = 90 − y/6`; origin top-left, x east, y south | `20-*` §4.1, `90-*` §9 |
| Longitude wrap | on; `x` taken mod 2160 everywhere (movement, BFS, camera, click) | `20-*` §4.1, `80-*` §4.5, validator group 6 |
| Latitude edges | impassable (ice band, below) | `20-*` §4.1 |
| `TILE_SIZE_PX` | `32` (unchanged) | TileMap config, `80-*` §4.5 |
| Coastal band | `.` iff within 3 tiles (Chebyshev, wrap-aware) of a passable-adjacent land/ice tile, else `~`; `.` is cosmetic only (same passability/speed as `~`) | `tools/build_world.py`, renderer |
| Harbor snap | berth tile within 2 tiles (Chebyshev) of `Port.lat/lon`, on water, with ≥ 1 orthogonally adjacent water tile; equidistant candidates tie-break to the smallest `(y, x)` — the Python builder and the GDScript runtime implement this rule exactly and the validator tests they agree | `10-*` §7.1, `tools/build_world.py`, `90-*` §9 |
| Harbor pair | every port has a **shore tile**: the nearest `#` tile orthogonally adjacent to its berth, tie-break smallest `(y, x)`. The shore tile is the port's visible location and the docking target; the berth is where the fleet stands (`20-*` §4.11.1). Both are derived, never stored. The pair constraint is part of the berth snap: a water candidate with no orthogonally adjacent `#` is skipped, so the berth is the nearest candidate satisfying **both** rules | `20-*` §4.11.1, `90-*` §9, validator group 6 |
| Port sighting | `24 tiles` (≈ 4° ≈ 240 nm) | `20-*` §4.11 |
| Discovery sighting | `18 tiles` (≈ 3°) | `70-*` §4.4 |
| Ship speeds | ×2: base speeds become `{8, 10, 12}` tiles/day = 80–120 nm/day; floor 1 tile/day unchanged; fleet = slowest hull, unchanged | `40-*` §4.2, `data/ship_types.json` |
| Weather zones | 5 latitude bands (§6.4) | `20-*` §4.7 |
| Map artifact | `data/maps/world.png` — indexed-color PNG, 2160×1080, 1 px = 1 tile, palette index 0–4 = `~ . # ^ I` | §6.3, `tools/build_world.py` |
| Palette policy | append-only: indices 0–4 = `~ . # ^ I` are locked; indices ≥ 5 are reserved for future cosmetic/seasonal layers and never carry simulation semantics | §6.3 |
| Lakes | `ne_10m_lakes` polygons rasterized as `#` (land for all purposes; the Caspian is land) | `tools/build_world.py` |
| Map index | `data/maps/maps.json` exactly one entry, `id: "world"` | `90-*` §9.1 |
| Save | version 5; no migration chain — v4 and older payloads refused | `90-*` §8.1–8.2 |
| Port schema | `lat`, `lon` (WGS84 degrees, truth); the `marker`, `position`, and `phase` keys and the retired world-map marker block are removed; `ports.json` holds all 100 ports | §4.4, §7.1 |

**Projection.** The grid is the whole globe at 6 tiles/degree: it spans
180°W–180°E and 90°N–90°S, and circumnavigation is a first-class feature
(`x = 0` and `x = 2159` are neighbours). No Mercator: a uniform grid is
load-bearing for the engine; display projection is a render concern only.

### 6.2 Tile legend (locked)

| Char | Kind | Passable | Notes |
|---|---|---|---|
| `~` | `sea` | yes | open water |
| `.` | `coastal_sea` | yes | shallow water; cosmetic only — same passability and speed as `~` |
| `#` | `land` | no | blocks movement; includes rasterized lakes (the Caspian is land) |
| `^` | `reef` | no | hazard; blocks movement, reserved for Phase-2 damage rules |
| `I` | `polar_ice` | no | polar ice edge; impassable, **not** reef, not land for adjacency purposes except edge-blocking |

**Ice rule (locked):** a tile is `I` iff `lat ≥ 70°N or lat ≤ 60°S`. This
keeps Cape Horn (55.98°S) sailable while North Cape (71.2°N) is iced: there is
no northeast or northwest passage. Tiles outside the ice band follow the
coastal-band/land rules.

**Ports are not terrain.** No port character exists in the tile charset. Ports
render as an overlay layer drawn from `data/ports.json#ports[].lat/lon` snapped
by §6.1's harbor rule (decision 7 in `IMPLEMENT-Phase4.md`); docking happens
when the fleet heads into the port's derived **shore tile** from an
orthogonally adjacent tile, which triggers the port-entry flow
(`20-WORLD-AND-SAILING.md` §4.11.1).

### 6.3 Map artifact format — `data/maps/world.png`

- **Format:** indexed-color (palette) PNG, exactly 2160 × 1080 pixels,
  1 px = 1 tile. Palette indices 0–4 correspond to `~ . # ^ I` in that order.
- **Append-only palette policy:** indices 0–4 are locked and their meanings may
  never change. Indices ≥ 5 are reserved for future cosmetic/seasonal layers
  (relief, biomes, seasonal ice) and never carry simulation semantics; adding
  one is a render-only change.
- **Loader contract:** read with `FileAccess` +
  `Image.load_png_from_buffer`. The PNG is **data**, not an imported texture —
  no Godot import pipeline, and the placeholder-art rule
  (`docs/80-UI-UX.md` §4.8) is unaffected.
- **Provenance:** generated by `tools/build_world.py` from public-domain
  shorelines (`tools/assets/`) plus `tools/map_overrides.json`; never
  hand-edited. ASCII is a debug export only (`build_world.py --ascii`):
  never shipped, never hand-edited, not a data source.
- **Companion report:** `data/maps/world_report.json` records build params,
  sea fraction, ice extent, component sizes > 2000 tiles, and the derived
  `harbor_tile {x, y}` (berth) plus `shore_tile {x, y}` per port (validator
  group 6 reads both). It is a **tool
  output, not an entity file**: its envelope is `{"version", "generated_by",
  "artifact", …}` with no plural entity array, so validator group 1 exempts it
  exactly like `map_legend.json` (its keys are `version`, `generated_by`,
  `artifact`, `build`, `tile_counts`, `tiles_total`, `sea_fraction`,
  `land_fraction`, `ice_fraction`, `reef_fraction`, `fractions`, `land_mask`,
  `components`, `overrides`, `override_details`, `ports`, `port_count`).

### 6.4 Weather bands

Five latitude bands replace the old "Atlantic strip" rule. Band = `|lat|`,
symmetric N/S; the last boreal band is north-only because south of 60°S is
ice. Column order is the existing `20-*` §4.7 schema order:
clear / overcast / windy / storm.

| Band | clear | overcast | windy | storm |
|---|---|---|---|---|
| Doldrums: \|lat\| < 8° | 0.30 | 0.45 | 0.15 | 0.10 |
| Trade winds: 8–30° | 0.15 | 0.30 | 0.20 | 0.35 |
| Variables: 30–40° | 0.30 | 0.40 | 0.20 | 0.10 |
| Westerlies: 40–60° | 0.10 | 0.30 | 0.35 | 0.25 |
| Boreal: 60–70°N | 0.15 | 0.35 | 0.30 | 0.20 |

**Storm-reachability acceptance:** per band, 10,000 seeded rolls must match
every category within ±0.02 (the T8 methodology). The demo gate is re-anchored:
**Lisbon → the water off Santa Cruz de Tenerife** (≈ 28.3°N 16.5°W) crosses into
the trade-wind belt; the scripted gate is "storm within 6 days in-band ≥ 0.90"
(`1 − 0.65⁶ = 0.9246`). Tenerife is a **coordinate destination** — the 100-port
list has no Canaries port and none is added; arrival means crossing the 30°N
band edge and sampling weather there, not docking.

## 7. Locked Content Lists

Exhaustive — no additions or removals without amending this doc.

### 7.1 Ports (100)

All 100 ports live in the single `data/ports.json` envelope. `lat`/`lon` are
WGS84 degrees (the geographic truth); the harbor pair is derived by §6.1's
projection + harbor-snap rule, never hand-placed. Nations from §7.4. Ordering
is the file order: the original 30 Mediterranean/Atlantic ports first, then the
70 world-expansion ports.

| id | zh | en | Nation | lat | lon | produces | demands |
|---|---|---|---|---|---|---|---|
| lisbon | 里斯本 | Lisbon | portugal | 38.72 | -9.14 | wine, salt | spices, silk, timber |
| seville | 塞维利亚 | Seville | spain | 37.00 | -6.35 | olive_oil, wine, wool | sugar, spices |
| valencia | 瓦伦西亚 | Valencia | spain | 39.45 | -0.33 | silk, ceramics | wheat, timber |
| barcelona | 巴塞罗那 | Barcelona | spain | 41.35 | 2.17 | wool, cotton_cloth | iron, spices |
| marseille | 马赛 | Marseille | spain | 43.30 | 5.37 | wine, salt, perfume | wool, silk |
| bordeaux | 波尔多 | Bordeaux | spain | 45.55 | -1.15 | wine, salt | timber, wool |
| london | 伦敦 | London | england | 51.47 | 0.75 | wool, cotton_cloth | wine, spices, timber |
| amsterdam | 阿姆斯特丹 | Amsterdam | holland | 52.46 | 4.60 | cheese, glassware | spices, silk, wheat |
| antwerp | 安特卫普 | Antwerp | holland | 51.44 | 3.60 | glassware, wool | spices, wine |
| hamburg | 汉堡 | Hamburg | holland | 53.87 | 8.70 | dried_fish, timber, amber | wine, salt |
| genoa | 热那亚 | Genoa | italy | 44.41 | 8.93 | olive_oil, cotton_cloth | spices, copper |
| naples | 那不勒斯 | Naples | italy | 40.84 | 14.25 | olive_oil, wine | wheat, timber |
| palermo | 巴勒莫 | Palermo | italy | 38.12 | 13.36 | wheat, olive_oil | timber, iron |
| syracuse | 锡拉库萨 | Syracuse | italy | 37.07 | 15.29 | salt, wheat | timber, leather |
| cagliari | 卡利亚里 | Cagliari | italy | 39.22 | 9.11 | salt, leather | wheat, glassware |
| valetta | 瓦莱塔 | Valetta | italy | 35.90 | 14.51 | cotton_cloth | wheat, timber, iron |
| venice | 威尼斯 | Venice | italy | 45.44 | 12.33 | glassware, perfume | spices, silk, cotton_cloth |
| ragusa | 拉古萨 | Ragusa | italy | 42.65 | 18.09 | timber, leather, wool | wheat |
| athens | 雅典 | Athens | ottoman | 37.94 | 23.64 | olive_oil, wine, ceramics | timber, iron |
| candia | 干地亚 | Candia | ottoman | 35.34 | 25.13 | wine, olive_oil | wheat, salt |
| cyprus | 塞浦路斯 | Cyprus | ottoman | 34.67 | 33.04 | copper, sugar | wheat, timber |
| smyrna | 士麦那 | Smyrna | ottoman | 38.42 | 27.14 | carpet | wheat, glassware, iron |
| istanbul | 伊斯坦布尔 | Istanbul | ottoman | 41.01 | 28.97 | carpet, perfume | wheat, iron, timber |
| beirut | 贝鲁特 | Beirut | ottoman | 33.90 | 35.50 | silk, timber | wheat, salt |
| alexandria | 亚历山大 | Alexandria | ottoman | 31.20 | 29.92 | cotton_cloth, sugar, wheat | timber, iron, wine |
| tripoli | 的黎波里 | Tripoli | ottoman | 32.90 | 13.18 | leather, salt | wheat, timber |
| tunis | 突尼斯 | Tunis | ottoman | 36.82 | 10.30 | olive_oil, leather | wheat, iron |
| algiers | 阿尔及尔 | Algiers | ottoman | 36.77 | 3.06 | leather, wool | wheat, timber, wine |
| ceuta | 休达 | Ceuta | portugal | 35.89 | -5.32 | wheat, leather | wine, cotton_cloth |
| madeira | 马德拉 | Madeira | portugal | 32.65 | -16.91 | sugar, wine | wheat, iron |
| havana | 哈瓦那 | Havana | spain | 23.13 | -82.38 | sugar, amber | wine, cotton_cloth |
| vera_cruz | 韦拉克鲁斯 | Veracruz | spain | 19.20 | -96.13 | copper, sugar | iron, glassware |
| cartagena | 卡塔赫纳 | Cartagena | spain | 10.39 | -75.53 | amber, sugar | wine, wool |
| portobelo | 波托贝洛 | Portobelo | spain | 9.55 | -79.65 | sugar | silk, spices |
| lima | 利马 | Lima | spain | -12.06 | -77.15 | copper, sugar | glassware, wine |
| buenos_aires | 布宜诺斯艾利斯 | Buenos Aires | spain | -34.60 | -58.37 | leather, wheat | iron, glassware |
| san_juan | 圣胡安 | San Juan | spain | 18.47 | -66.11 | sugar, salt | cotton_cloth, wine |
| santo_domingo | 圣多明各 | Santo Domingo | spain | 18.47 | -69.88 | sugar, leather | silk, glassware |
| acapulco | 阿卡普尔科 | Acapulco | spain | 16.85 | -99.90 | silk, copper | wheat, glassware |
| panama | 巴拿马 | Panama | spain | 8.98 | -79.52 | amber, copper | wine, iron |
| valparaiso | 瓦尔帕莱索 | Valparaiso | spain | -33.03 | -71.63 | copper, wine | glassware, wool |
| guayaquil | 瓜亚基尔 | Guayaquil | spain | -2.60 | -80.30 | sugar, timber | iron, glassware |
| bahia | 巴伊亚 | Bahia | portugal | -12.97 | -38.50 | sugar, timber | glassware, iron |
| rio_de_janeiro | 里约热内卢 | Rio de Janeiro | portugal | -22.90 | -43.18 | sugar, timber, amber | iron, wool |
| recife | 累西腓 | Recife | portugal | -8.06 | -34.87 | sugar, cotton_cloth | wine, iron |
| belem | 贝伦 | Belem | portugal | -1.35 | -48.48 | timber, spices | salt, glassware |
| boston | 波士顿 | Boston | england | 42.36 | -71.05 | dried_fish, timber | wine, salt |
| new_york | 纽约 | New York | england | 40.70 | -74.02 | timber, dried_fish | wine, spices |
| jamestown | 詹姆斯敦 | Jamestown | england | 37.00 | -76.30 | timber, wheat | wine, iron |
| charleston | 查尔斯顿 | Charleston | england | 32.78 | -79.93 | sugar, timber | wine, salt |
| new_foundland | 纽芬兰 | Newfoundland | england | 47.56 | -52.71 | dried_fish, timber | wine, salt |
| quebec | 魁北克 | Quebec | england | 47.00 | -70.50 | timber, dried_fish | wine, salt |
| curacao | 库拉索 | Curacao | holland | 12.11 | -68.93 | salt, sugar | timber, wine |
| suriname | 苏里南 | Suriname | holland | 5.90 | -55.15 | sugar, timber | iron, wine |
| elmina | 埃尔米纳 | Elmina | portugal | 5.08 | -1.35 | amber, salt | cotton_cloth, iron |
| luanda | 罗安达 | Luanda | portugal | -8.78 | 13.23 | amber, leather | glassware, wool |
| mozambique | 莫桑比克 | Mozambique | portugal | -15.03 | 40.73 | amber, spices | cotton_cloth, iron |
| mombasa | 蒙巴萨 | Mombasa | ottoman | -4.06 | 39.68 | spices, amber | glassware, wine |
| cape_town | 开普敦 | Cape Town | holland | -33.92 | 18.42 | wine, wheat | timber, iron |
| safi | 萨菲 | Safi | portugal | 32.30 | -9.24 | salt, leather | silk, spices |
| saint_louis | 圣路易 | Saint-Louis | holland | 16.00 | -16.51 | leather, salt | glassware, wool |
| accra | 阿克拉 | Accra | england | 5.53 | -0.20 | amber, salt | cotton_cloth, wine |
| goa | 果阿 | Goa | portugal | 15.50 | 73.83 | spices, cotton_cloth | wine, glassware |
| calicut | 卡利卡特 | Calicut | portugal | 11.25 | 75.77 | spices, carpet | glassware, copper |
| cochin | 科钦 | Cochin | holland | 9.97 | 76.27 | spices, timber | iron, wine |
| bombay | 孟买 | Bombay | england | 18.92 | 72.83 | cotton_cloth, spices | iron, wine |
| surat | 苏拉特 | Surat | england | 21.10 | 72.70 | cotton_cloth, carpet | glassware, amber |
| colombo | 科伦坡 | Colombo | holland | 6.93 | 79.85 | spices, ceramics | wine, iron |
| pondicherry | 本地治里 | Pondicherry | england | 11.93 | 79.83 | cotton_cloth, spices | glassware, amber |
| muscat | 马斯喀特 | Muscat | ottoman | 23.62 | 58.59 | amber, carpet | wine, timber |
| basra | 巴士拉 | Basra | ottoman | 30.00 | 48.50 | carpet, dried_fish | iron, timber |
| bandar_abbas | 阿巴斯港 | Bandar Abbas | ottoman | 27.18 | 56.28 | carpet, amber | glassware, sugar |
| aden | 亚丁 | Aden | ottoman | 12.79 | 45.03 | amber, salt | wheat, iron |
| jiddah | 吉达 | Jiddah | ottoman | 21.48 | 39.18 | carpet, amber | wheat, timber |
| suakin | 苏阿金 | Suakin | ottoman | 19.10 | 37.33 | salt, leather | glassware, wine |
| mogadishu | 摩加迪沙 | Mogadishu | ottoman | 2.03 | 45.34 | spices, leather | iron, wine |
| malacca | 马六甲 | Malacca | portugal | 2.19 | 102.25 | spices, amber | iron, wool |
| batavia | 巴达维亚 | Batavia | holland | -6.13 | 106.81 | spices, sugar | wine, iron |
| macassar | 望加锡 | Macassar | holland | -5.13 | 119.41 | spices, timber | glassware, wool |
| amboina | 安汶 | Amboina | holland | -3.69 | 128.18 | spices, salt | iron, wine |
| manila | 马尼拉 | Manila | spain | 14.58 | 120.97 | silk, spices | wheat, iron |
| macau | 澳门 | Macao | portugal | 22.19 | 113.54 | silk, ceramics | sugar, glassware |
| canton | 广州 | Canton | england | 22.75 | 113.65 | silk, ceramics, timber | copper, salt |
| nagasaki | 长崎 | Nagasaki | holland | 32.75 | 129.88 | copper, silk | sugar, wine |
| osaka | 大阪 | Osaka | holland | 34.65 | 135.43 | copper, ceramics | silk, glassware |
| zeelandia | 热兰遮 | Zeelandia | holland | 22.99 | 120.16 | sugar, timber | silk, iron |
| patani | 北大年 | Patani | holland | 6.87 | 101.25 | spices, timber | cotton_cloth, iron |
| brunei | 文莱 | Brunei | spain | 5.00 | 115.05 | timber, spices | glassware, wool |
| ternate | 特尔纳特 | Ternate | holland | 0.79 | 127.38 | spices, salt | wine, iron |
| timor | 帝汶 | Timor | portugal | -10.17 | 123.60 | spices, timber | glassware, iron |
| botany_bay | 植物学湾 | Botany Bay | england | -33.98 | 151.18 | timber, dried_fish | wine, iron |
| siam | 暹罗 | Siam | portugal | 13.50 | 100.58 | timber, ceramics | glassware, wool |
| cadiz | 加的斯 | Cadiz | spain | 36.53 | -6.29 | salt, wine | spices, timber |
| oporto | 波尔图 | Oporto | portugal | 41.14 | -8.68 | wine, leather | spices, glassware |
| plymouth | 普利茅斯 | Plymouth | england | 50.37 | -4.14 | dried_fish, wool | wine, spices |
| bergen | 卑尔根 | Bergen | holland | 60.39 | 5.32 | dried_fish, timber | wine, salt |
| danzig | 但泽 | Danzig | holland | 54.40 | 18.68 | timber, amber | wine, salt |
| stockholm | 斯德哥尔摩 | Stockholm | holland | 59.32 | 18.10 | copper, iron | wine, salt |
| trieste | 的里雅斯特 | Trieste | italy | 45.65 | 13.77 | glassware, timber | spices, sugar |
| corfu | 科孚 | Corfu | italy | 39.62 | 19.92 | olive_oil, salt | wine, timber |

Historical fidelity is deliberately loose (e.g., French-coast ports assigned
to Spain, Mediterranean islands split between Italy and the Ottomans, and the
world-expansion ports' nation assignments) to keep the 6-nation model closed;
do not "fix" assignments without amending this doc.

### 7.2 Goods (20)

| id | zh | en | category | base_price |
|---|---|---|---|---|
| wheat | 小麦 | Wheat | food | 8 |
| olive_oil | 橄榄油 | Olive Oil | food | 22 |
| wine | 葡萄酒 | Wine | food | 30 |
| wool | 羊毛 | Wool | textile | 18 |
| cotton_cloth | 棉布 | Cotton Cloth | textile | 45 |
| silk | 丝绸 | Silk | textile | 120 |
| spices | 香料 | Spices | luxury | 150 |
| sugar | 糖 | Sugar | food | 40 |
| salt | 盐 | Salt | food | 12 |
| dried_fish | 鱼干 | Dried Fish | food | 10 |
| timber | 木材 | Timber | material | 15 |
| iron | 铁 | Iron | material | 35 |
| copper | 铜 | Copper | material | 50 |
| glassware | 玻璃器皿 | Glassware | luxury | 60 |
| leather | 皮革 | Leather | material | 28 |
| ceramics | 陶瓷 | Ceramics | material | 25 |
| perfume | 香水 | Perfume | luxury | 90 |
| carpet | 地毯 | Carpet | textile | 80 |
| amber | 琥珀 | Amber | luxury | 110 |
| cheese | 奶酪 | Cheese | food | 16 |

### 7.3 ShipTypes (8)

| id | zh | en | class | price | durability | capacity | speed | crew min/max | cannons |
|---|---|---|---|---|---|---|---|---|---|
| latin | 拉丁帆船 | Latin | sail | 1200 | 40 | 30 | 8 | 8/20 | 2 |
| sloop | 单桅纵帆船 | Sloop | sail | 3000 | 60 | 60 | 10 | 10/30 | 4 |
| caravel | 卡拉维尔帆船 | Caravel | sail | 8000 | 90 | 120 | 10 | 15/45 | 6 |
| galley | 桨帆船 | Galley | oar | 10000 | 70 | 50 | 12 | 40/120 | 4 |
| brigantine | 双桅帆船 | Brigantine | sail | 15000 | 110 | 150 | 12 | 20/60 | 10 |
| nao | 瑙船 | Nao | sail | 22000 | 140 | 300 | 8 | 25/80 | 10 |
| carrack | 卡拉克帆船 | Carrack | sail | 40000 | 180 | 450 | 8 | 30/100 | 16 |
| galleon | 盖伦帆船 | Galleon | hybrid | 60000 | 240 | 400 | 10 | 40/150 | 24 |

Speeds are the Phase-4 rescaled values (`×2` on the Phase-1 tiles/day, §6.1
"Ship speeds"): on 10 nm tiles this yields the historical 80–120 nm/day. The
1 tile/day floor and "fleet = slowest hull" are unchanged.

### 7.4 Nations (6)

| id | zh | en | color | start port | start ship | start gold | start rep |
|---|---|---|---|---|---|---|---|
| portugal | 葡萄牙 | Portugal | `#1a8c4e` | lisbon | caravel | 5000 | 20 |
| spain | 西班牙 | Spain | `#b3191f` | seville | nao | 6000 | 15 |
| england | 英格兰 | England | `#274b8f` | london | sloop | 4500 | 10 |
| holland | 荷兰 | Holland | `#d97b1e` | amsterdam | nao | 7000 | 10 |
| ottoman | 奥斯曼 | Ottoman | `#6a3d9a` | istanbul | galley | 6000 | 12 |
| italy | 意大利 | Italy | `#c9a227` | venice | brigantine | 5500 | 10 |

Capital ports (palace locations, Phase 3): lisbon, seville, london, amsterdam,
istanbul, venice.

### 7.5 Starter Officer Roster (6, Phase 1)

One recruit per nation, available at the listed taverns from game start:

| id | zh | en | nation | role | recruit ports | wage |
|---|---|---|---|---|---|---|
| off_mateus_alvares | 马特乌斯·阿尔瓦雷斯 | Mateus Álvares | portugal | navigator | lisbon, madeira | 30 |
| off_diego_fernandez | 迭戈·费尔南德斯 | Diego Fernández | spain | boatswain | seville, ceuta | 28 |
| off_thomas_reed | 托马斯·里德 | Thomas Reed | england | gunner | london | 32 |
| off_jan_de_vries | 扬·德弗里斯 | Jan de Vries | holland | boatswain | amsterdam, antwerp | 28 |
| off_kemal_agha | 凯末尔阿迦 | Kemal Agha | ottoman | gunner | istanbul, smyrna | 30 |
| off_marco_bellini | 马尔科·贝里尼 | Marco Bellini | italy | navigator | venice, genoa | 30 |

### 7.6 Trade lanes (12, Phase 5)

The locked `data/trade_routes.json` lane id set (§4.14) — exhaustive; the
`nations`/`goods`/`waypoints`/`chokepoints` values are task-owned authored
data (`IMPLEMENT-Phase5.md` task E):

| id | zh | en |
|---|---|---|
| carreira_da_india | 印度航线（好望角） | The Carreira da Índia (Cape of Good Hope run) |
| west_indies_flota | 西印度大舰队航线 | The West Indies flota circuit |
| manila_galleon | 马尼拉大帆船航线 | The Manila galleon run (dateline-crossing) |
| venice_alexandria | 威尼斯—亚历山大航线 | The Venice–Alexandria run |
| venice_flanders | 威尼斯—佛兰德斯航线 | The Venice–Flanders run |
| genoa_grain | 热那亚粮食航线 | The Genoa grain run |
| hanseatic_north | 汉萨北方航线 | The Hanseatic northern run |
| aden_gujarat_malacca | 亚丁—古吉拉特—马六甲航线 | The Aden–Gujarat–Malacca run |
| red_sea_india | 红海—印度航线 | The Red Sea–India run |
| basra_muscat_india | 巴士拉—马斯喀特—印度航线 | The Basra–Muscat–India run |
| iceland_cod | 冰岛鳕鱼航线 | The Iceland cod run |
| grand_banks_cod | 纽芬兰大浅滩鳕鱼航线 | The Grand Banks cod run |

The set is closed: **no Cape Horn lane** (rounding the Horn is a post-1616
anachronism; the Magellan Strait is the historical south-sea passage where
one is relevant).

### 7.7 Captain name pools (7, Phase 5)

`data/npc_captains.json` (§4.11) holds exactly 7 pools — one per nation plus
the nationless `""` pool. Every pool carries **≥ 8 zh/en names**, authored
era-plausible per nation (task-owned content, task D):

| pool (`nation_id`) | roster |
|---|---|
| `portugal` | Portuguese captains |
| `spain` | Spanish captains |
| `england` | English captains |
| `holland` | Dutch captains |
| `ottoman` | Ottoman captains |
| `italy` | Italian captains |
| `""` | Nationless captains — the pool pirates draw from |

### 7.8 Named pirates (4, Phase 5)

`data/named_pirates.json` (§4.12) holds exactly 4 named pirates; every
`tier` ∈ `1 … 3` (`70-*` §4.5 bounty tiers). Names and tiers are task-owned
authored content (task D); the count and the tier band are the locked part.

## 8. `tools/validate_data.py` Spec

Python ≥ 3.10, stdlib only (`json`, `re`, `sys`, `pathlib`, `zlib` for the PNG
reader). Run:
`python3 tools/validate_data.py` from the repo root. Exit code 0 = all checks
pass; first failure prints `FAIL <check-id> <file> <details>` and exits with
the code below. All checks run in order.

| Exit | Check group | Checks |
|---|---|---|
| 1 | Parse & envelope | every `data/*.json` parses; envelope has int `version` and exactly one plural entity key matching the filename (except `map_legend.json`, `maps/maps.json`, `maps/world_report.json`, `ui_strings.json`, and the Phase-5 envelopes — `npc_config.json` (config block), `npc_captains.json` (key `pools`), `trade_routes.json` (key `lanes`), `trade_routes_built.json` (tool output)) |
| 2 | i18n | every L10nString has exactly keys `zh`,`en`, both non-empty strings; applies recursively to all entity files. `ui_strings.json`: every top-level key except `version` maps to an L10nString, and per key the `{placeholder}` token sets in `zh` and `en` must be identical |
| 3 | Schema | every entity has its §4 required fields with correct types and enum/range constraints (incl. `id` regex, `tilePos` bounds `2160 × 1080`, `lat ∈ [-90, 90]`, `lon ∈ [-180, 180]`, and rejection of the retired port keys) |
| 4 | Referential integrity | `port.nation_id ∈ nations`; `port.produces ∪ port.demands ∪ port.market_goods ⊆ goods`; `nation.start_port_id ∈ ports`; `nation.capital_port_id ∈ ports`; `nation.start_ship_type_id ∈ ship_types`; `nation.rivals ⊆ nations` (exactly 2, never itself); `officer.nation_id ∈ nations`; `officer.recruit_ports ⊆ ports`; `quest.requirements.good_id ∈ goods`, `dest_port_id ∈ ports`, `exploration.discovery_id ∈ discoveries`, `rewards.reputation` keys ∈ nations; equipment `modifiers` keys are known stat names |
| 5 | Locked lists | exactly the §7.1 100 ports (the single `data/ports.json` file), §7.2 20 goods, §7.3 8 ship types, §7.4 6 nations, §7.5 6 officers — id sets must match exactly |
| 6 | World map | The generated-artifact integrity group below (artifact, harbor-tile agreement, reachability, probes, component listing) plus the seeded negative tests |
| 7 | NPC & economy data | `npc_config.json` bounds (presets ≥ 0, `default_preset` ∈ `presets` at the neutral multiplier, budgets/flow > 0, `absolute_cap` ≤ the §4.10 cap); `npc_captains.json` (exactly §7.7's 7 pools, ≥ 8 names each, complete i18n); `named_pirates.json` (exactly 4, tiers 1–3, i18n); `market_events.json` (`scope` valid, cadence/duration > 0, shifts keep rest inside the band); the `30-*` §4.2 consumption-tier split assertion — normative spec §8.2 |
| 8 | Trade routes | `trade_routes.json` id set is exactly §7.6's 12; waypoints satisfy the §6.1 snap rule; every segment passable and wrap-continuous; every port satisfies the §4.14 spoke rule; junction-graph connectivity probes; `trade_routes_built.json` rebuild equality — normative spec §8.3 |

### 8.1 Group 6 — world map, normative spec

Group 6 has no ASCII input and no markers. Exit 6. It checks:

1. **Artifact.** `data/maps/world.png` exists, decodes as an **indexed-color**
   PNG (color type 3), is exactly `2160 × 1080` pixels, and every palette
   index used is in the locked set `0–4` (`~ . # ^ I` in that order). Decode
   with `zlib` and the tool's own PNG reader — stdlib only, no PIL.
2. **Harbor tiles agree.** For each of the 100 ports, recompute the harbor
   (berth) tile **independently from `Port.lat`/`Port.lon`** with the §6.1 snap
   rule (within 2 tiles Chebyshev, on water, ≥ 1 orthogonally adjacent water
   tile, tie-break to smallest `(y, x)`) **plus the item 2b pair constraint**
   (a candidate water tile with no orthogonally adjacent `#` is skipped — see
   the §6.1 "Harbor pair" row) and compare it with the builder's
   `data/maps/world_report.json#ports[].harbor_tile`. They must be identical.
   Failures name the port and both tiles.
2b. **Harbor pair.** Every port must have a **shore tile**: a `#` tile
   orthogonally adjacent to its berth tile (`20-*` §4.11.1). A port with no
   such neighbour fails group 6 naming the port — the docking gesture and the
   overlay both depend on it. The shore tile itself is recomputed the same way
   (nearest to `lat`/`lon`, tie-break `(y, x)`) and must agree with the
   builder's `world_report.json#ports[].shore_tile`.
3. **Reachability.** BFS from Lisbon's berth tile over **all** passable tiles
   (`~`, `.` — `#`, `^`, `I` are impassable), 8-directional with
   **corner-cutting forbidden** (a diagonal step is legal only when both
   orthogonal neighbours of the corner are passable) and **wrap-aware**
   (`x mod 2160`; `x = 0` and `x = 2159` are neighbours). The BFS must reach
   all 100 berth tiles and all discovery tiles (a discovery's derived tile is
   passable or orthogonally adjacent to a passable tile — `70-*` §4.4).
   Plain 8-directional BFS is a validator bug: it reports reachability through
   gaps no fleet can traverse.
4. **Probe ports** asserted reachable in the same BFS: `istanbul`
   (Bosphorus), `danzig` and `stockholm` (Øresund/Great Belt), `aden`
   (Bab-el-Mandeb), `nagasaki` (Malacca/Sunda), `venice`, `london`, `hamburg`
   (Elbe). Each is named in its failure message with the strait it proves.
5. **Component listing (informational).** Any disconnected passable component
   larger than 2000 tiles is listed by size and an example tile. No
   disconnected sea is expected because lakes rasterize as land; the listing
   stays as a diagnostic, never a failure.

**Negative tests (must provably fail).** The validator ships a mutation
harness; each seeded mutation makes group 6 exit 6 with a named message:

- Gibraltar override removed from `tools/map_overrides.json` →
  unreachable named port (`ceuta`, or the Gibraltar-flank port that loses its
  water path);
- one port moved 3 tiles inland → snap failure naming that port;
- one berth stripped of its orthogonally adjacent `#` → harbor-pair failure
  naming that port (item 2b);
- a report `shore_tile` made stale → harbor-pair mismatch naming the port and
  both tiles;
- two ports sharing a shore tile → shore-collision failure;
- `world.png` corrupted to a wrong size → artifact failure;
- `world.png` re-palettized with an index ≥ 5 → artifact failure.

**Runtime bound:** < 30 s wall clock, stdlib only.

`--verbose` prints a per-check pass summary.

### 8.2 Group 7 — npc & economy data, normative spec

Group 7 exits 7. It checks the four Phase-5 data files (L10nString
completeness inside them is group 2's recursion; group 7 owns structure,
counts, and bounds):

1. **`npc_config.json`** (§4.10): every `presets` multiplier ≥ 0;
   `default_preset` ∈ `presets`, and it must be the neutral preset of
   §4.10; every `budgets` and `flow` value > 0;
   `absolute_cap` ≤ the §4.10 locked cap; the `presets`/`budgets`/`flow`
   key sets are exactly the §4.10 keys.
2. **`npc_captains.json`** (§4.11, §7.7): exactly 7 pools — the 6 locked
   nation ids plus `""`, no duplicates, no extras; every pool ≥ 8 names;
   every name a complete L10nString.
3. **`named_pirates.json`** (§4.12, §7.8): exactly 4 entries; every `tier`
   an int in the locked band 1–3; ids unique; names complete i18n.
4. **`market_events.json`** (§4.13): every `scope == "port"` (the only
   valid value this phase); every `cadence_days` > 0 and `duration_days` >
   0; every `shifts` key ∈ goods; **rest-band bound:** for every shifted
   good, `10 ≤ rest + shift ≤ 190` for every resting value that good takes
   across the 100 ports (produced/demanded/neutral per `30-*` §4.2) — a
   violation names the template and the good.
5. **Consumption-tier assertion:** ranking `goods.json` per `30-*` §4.2
   (`base_price` asc, `id` asc tie-break) yields exactly 5 staples /
   10 middle / 5 luxuries.

**Negative tests (must provably fail, exit 7, named message):** a negative
preset; a default whose multiplier is not 1.0; a budget ≤ 0; an
`absolute_cap` above the cap; a missing or extra captain pool; a pool with
7 names; a tier-4 pirate; a shift that pushes any applicable rest outside
the band.

### 8.3 Group 8 — trade routes, normative spec

Group 8 exits 8. It runs after group 6 (same PNG decoder; sharing
`build_world.py`'s reader is allowed). It checks:

1. **Lane id set.** `data/trade_routes.json` contains exactly the §7.6
   12 locked ids — none missing, none extra.
2. **Lane schema.** Every lane: `class == "major"`; `nations` ⊆ nations;
   `goods` ⊆ goods; ≥ 1 chokepoint tag; ≥ 2 waypoints with in-range
   lat/lon (§3.1).
3. **Waypoint snap.** Every waypoint satisfies the §6.1 snap rule as the
   builder applies it (the §4.14 rule: same radius, wrap-aware,
   smallest-`(y, x)` tie-break). Failure names the lane and waypoint.
4. **Segment passability.** The tile walk of every consecutive waypoint
   pair steps only on passable tiles, corner-cutting forbidden, wrap-aware
   (the group 6 item 3 movement rules).
5. **Wrap-aware continuity.** Dateline-crossing segments stay continuous
   under `x mod 2160` — no segment jumps the seam (`manila_galleon`
   waypoints keep per-segment `x` monotonic under wrap).
6. **Port spokes.** Every one of the 100 ports satisfies the §4.14 spoke
   rule (a lane waypoint within the spoke radius, else the capital
   fallback). A port with neither is a hard failure naming the port.
7. **Junction connectivity.** Over the built junction graph every port
   reaches every lane its nation/goods data implies; the named probes are
   asserted: `acapulco` ↔ `manila` across the wrap, `hanseatic_north`
   reaches `danzig`, `carreira_da_india` reaches `goa`.
8. **Determinism.** Rebuild the artifact with `tools/build_routes.py` and
   compare against the committed `data/trade_routes_built.json`: equality
   is byte-exact. Any drift — a hand-edit included — fails naming the
   differing part; the fix is `data/trade_routes.json` /
   `tools/route_overrides.json`, never the built file.

**Negative tests (must provably fail, exit 8, named message):** a waypoint
with no water within the snap radius (landlocked); a segment walked onto an
impassable tile; a port with no spoke and no capital fallback; a rebuilt
artifact that differs by one byte.

`--verbose` prints a per-check pass summary for groups 7–8 as for group 6.

## 9. Edge Cases & Fail States

- **Locale string empty or whitespace-only** → validator exit 2.
- **Two ports share a harbor tile** → validator exit 6. The snap rule's
  smallest-`(y, x)` tie-break resolves equidistant *candidates* within one
  port; it never permits two ports to occupy the same harbor cell — the
  second one fails with a named collision error.
- **Two ports share a shore tile** → validator exit 6 (same rule, applied to
  the harbor pair's land half: only one port could be docked into it).
- **A berth has no orthogonally adjacent `#`** → validator exit 6 naming the
  port (`20-*` §4.11.1, group 6 item 2b): the docking gesture and the overlay
  both depend on the shore tile. On the shipped map 14 ports moved one tile
  to satisfy this; a future port needs a coordinate or carve amendment.
- **A port snaps further than 2 tiles from its `lat`/`lon`** → validator
  exit 6 (snap rule unsatisfiable: no water within the 2-tile Chebyshev
  radius, or no orthogonally adjacent water). The fix is a coordinate
  amendment in `docs/10-DATA-SCHEMA.md` §7.1 and `data/ports.json`, or a
  tidal-river carve entry in `tools/map_overrides.json` — never a hand-edit
  of the PNG.
- **A discovery on land with no adjacent passable water** → validator exit 6
  (`70-*` §4.4 placement rule).
- **`data/maps/world.png` missing, wrong size, or not an indexed PNG** →
  validator exit 6 (artifact check).
- **`data/maps/world.png` hand-edited (palette or geometry drift)** →
  validator exit 6: the artifact must be reproducible by
  `tools/build_world.py`, and any index outside `0–4` or size other than
  2160 × 1080 fails. Regenerate; never patch pixels.
- **`market_goods` absent** → all 20 goods trade; adding the key later with a
  subset is a valid data-only change.
- **`produces` ∩ `demands` ≠ ∅ for a port** → allowed but pointless; validator
  `--verbose` prints a warning, not a failure.
- **Phase-2 files (`equipment`) may be `[]`** — valid; schema checks skip
  empty arrays, envelope/version still required.
- **Officer hired twice / dead officers** — runtime concern, owned by
  `50-CHARACTER-AND-PROGRESSION.md`; data layer only guarantees id uniqueness.
- **`rivals` missing on a nation** → validator exit 3 (the key is required);
  the loader cannot invent it, so the data file is amended, not the save.
- **A lane waypoint has no water within the snap radius** → validator
  exit 8 naming the lane and waypoint. The fix is
  `tools/route_overrides.json` or a reported waypoint amendment in
  `data/trade_routes.json` — never a hand-edit of
  `data/trade_routes_built.json`.
- **A port has no lane waypoint within the spoke radius and no capital
  fallback** → hard build/validator error (exit 8) naming the port — the
  network, not the runtime, is broken.
- **`data/trade_routes_built.json` hand-edited or rebuild-drifted** →
  validator exit 8 (§8.3 determinism); regenerate with
  `tools/build_routes.py`.
- **A demand-event shift pushes any applicable rest outside the band
  (§8.2 item 4)** → validator exit 7 naming the template and good.
- **`npc_config.json` out of bounds** (negative preset, default not the
  neutral preset, a budget ≤ 0, `absolute_cap` above the §4.10 cap) →
  validator exit 7.
- **A captain pool missing, extra, or under 8 names** → validator exit 7;
  the §7.7 pool set is closed.

## 10. Acceptance Criteria

- [ ] All artifact paths from §2 exist in the doc set's file inventory and
      match these names exactly.
- [ ] Every JSON example in this doc parses (spot-checked with a parser).
- [ ] §7 tables contain exactly 100/20/8/6/6 rows and only ids using the §3.1
      `id` regex; every §7.1 `lat`/`lon` is a plausible real-world position
      (Lisbon ≈ 38.7°N 9.1°W, Nagasaki ≈ 32.7°N 129.9°E) and no port sits in
      the polar ice band (`|lat| ≥ 70` north, `≤ −60` south).
- [ ] Every non-ASCII display string in tables carries both zh and en.
- [ ] Every locked constant from `IMPLEMENT-Phase4.md`'s Locked constants
      table appears exactly once in §6.1 with the same value (grid, tiles per
      degree, sighting radii, ship-speed set, artifact path); the §6.1 save
      row pins the current version (5, no migration chain — `90-*` §8.2).
- [ ] Every locked constant with owning doc `10-*` from
      `IMPLEMENT-Phase5.md` (the §4.10–4.15 schemas, the §7.6–7.8 lists,
      the §8.2/§8.3 validator specs) appears in this doc exactly once.
- [ ] `validate_data.py` check groups (exit 1–8) are implementable from §8
      alone, without further design questions — including the §8.1 group 6
      world-map spec, §8.2 group 7, and §8.3 group 8.
- [ ] §7.6 lists exactly the 12 locked lane ids; §7.7 exactly 7 pools;
      §7.8 exactly 4 named pirates.
- [ ] The v5 save-block shapes of §4.15 match the `90-*` §8.1 key list
      field-for-field.
- [ ] The validator summary reports a port count of **100**.
- [ ] Harbor-relief numbers (threshold 1,200, payout 100, cheapest hull 1,200)
      are consistent with §7.3 and `50-*`.
