# 10 — Data Schema

## 1. Purpose & Phase

This document is the contract every other doc and every implementation task
depends on. It defines:

- The exact JSON file layout under `data/` and the schema of every entity type.
- The i18n rule for all display strings.
- The spec for `tools/validate_data.py`, the validator all data must pass.
- The locked Phase-1 content lists: 30 ports, 20 goods, 8 ship types,
  6 nations, 6 starter officers — exhaustive, with no open slots.
- The ASCII-art map legend, grid constants, and port-marker conventions.
- The harbor-relief (anti-softlock) fallback spec.

Gates all phases. Phase-2/3 entity schemas (`Equipment`, `Discovery`, `Quest`)
are fully specified here now; their data files ship as empty arrays until the
owning phase.

## 2. Artifacts

| Path | Contents | Owner doc |
|---|---|---|
| `data/nations.json` | Nation list | this doc |
| `data/goods.json` | Good list | this doc |
| `data/ship_types.json` | ShipType list | this doc |
| `data/ports.json` | Port list | this doc |
| `data/officers.json` | Officer roster | this doc |
| `data/discoveries.json` | `[]` until Phase 3 | this doc / `70-*` |
| `data/quests.json` | `[]` until Phase 3 | this doc / `70-*` |
| `data/equipment.json` | `[]` until Phase 2 | this doc / `60-*` |
| `data/map_legend.json` | MapLegend (tiles, markers, constants) | this doc |
| `data/maps/p1_mediterranean.txt` | ASCII world map, Phase 1 | this doc / `20-*` |
| `data/ui_strings.json` | UI-frame L10n strings | `80-UI-UX.md` |
| `tools/validate_data.py` | Schema/i18n/integrity/map validator | this doc |

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
| `tilePos` | `{"x": int, "y": int}` with `0 ≤ x < 128`, `0 ≤ y < 96` (see §6) |

### 3.2 File envelope

Every entity file under `data/` is a JSON object:

```json
{
  "version": 1,
  "ports": [ ]
}
```

- `version` (int, required): schema version of the file; starts at 1; bump when
  the file's schema changes (migration notes in `docs/90-ARCHITECTURE.md`).
- The second key is the plural entity name from §2 and contains the array.
- UTF-8, 2-space indent, trailing newline. No comments (JSON).

### 3.3 i18n rule (normative)

1. Every display string anywhere in `data/` is an `L10nString`.
2. Both locales must be present and non-empty; a missing or empty locale is a
   validation error (validator exit 2), never a runtime fallback.
3. Non-display strings (`id`, `marker`, `color`, keys) are plain strings.
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
      "speed": 5,
      "crew_min": 15,
      "crew_max": 45,
      "armament_slots": 6
    }
  ]
}
```

### 4.4 Port — `data/ports.json`

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 30 locked ids (§7.1) |
| `name` | L10nString | |
| `nation_id` | id | references Nation |
| `marker` | string | exactly 1 char from `0-9` or `a-t`; unique; must appear at `position` in the map file and in `map_legend.json#port_markers` |
| `position` | tilePos | the port's harbor tile; locked values in §7.1; the map-authoring task must place this port's marker at exactly this coordinate |
| `produces` | []id | ⊆ Good ids; port sells these cheaper (supply factor in `30-*`) |
| `demands` | []id | ⊆ Good ids; port buys these dearer |
| `market_goods` | []id | optional; ⊆ Good ids; when absent, **all 20 goods trade here** (locked for Phase 1) |
| `facilities` | object | keys with activation phase: `market:1, shipyard:1, tavern:1, inn:1, guild:3, palace:3`. `palace` is **omitted** unless this port is a nation's `capital_port_id` |
| `flavor` | L10nString | 1 sentence shown in the port-entry greeting |

```json
{
  "version": 1,
  "ports": [
    {
      "id": "lisbon",
      "name": {"zh": "里斯本", "en": "Lisbon"},
      "nation_id": "portugal",
      "marker": "f",
      "position": {"x": 7, "y": 57},
      "produces": ["wine", "salt"],
      "demands": ["spices", "silk", "timber"],
      "facilities": {"market": 1, "shipyard": 1, "tavern": 1, "inn": 1, "guild": 3, "palace": 3},
      "flavor": {"zh": "大航海时代的起点,特茹河口帆影如林。", "en": "Cradle of the Age of Discovery, its Tagus anchorage thick with sails."}
    },
    {
      "id": "venice",
      "name": {"zh": "威尼斯", "en": "Venice"},
      "nation_id": "italy",
      "marker": "t",
      "position": {"x": 57, "y": 34},
      "produces": ["glassware", "perfume"],
      "demands": ["spices", "silk", "cotton_cloth"],
      "facilities": {"market": 1, "shipyard": 1, "tavern": 1, "inn": 1, "guild": 3, "palace": 3},
      "flavor": {"zh": "亚得里亚海的女王,商栈与运河之城。", "en": "Queen of the Adriatic, city of canals and counting-houses."}
    },
    {
      "id": "ceuta",
      "name": {"zh": "休达", "en": "Ceuta"},
      "nation_id": "portugal",
      "marker": "a",
      "position": {"x": 16, "y": 67},
      "produces": ["wheat", "leather"],
      "demands": ["wine", "cotton_cloth"],
      "facilities": {"market": 1, "shipyard": 1, "tavern": 1, "inn": 1, "guild": 3},
      "flavor": {"zh": "直布罗陀门户上的葡属要塞。", "en": "A Portuguese stronghold guarding the gates of Gibraltar."}
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
| `position` | tilePos | where it is found on the world grid |
| `fame` | int > 0 | fame granted on first report |
| `report_reward_gold` | money | gold paid by the guild on report |
| `region_hint` | L10nString | 1-sentence rumor text sold at taverns |
| `phase` | int | locked at `3` |

```json
{
  "version": 1,
  "discoveries": [
    {
      "id": "disc_atlas_cedars",
      "name": {"zh": "阿特拉斯雪松林", "en": "Cedars of the Atlas"},
      "category": "natural",
      "position": {"x": 24, "y": 80},
      "fame": 150,
      "report_reward_gold": 2000,
      "region_hint": {"zh": "据说在南方的深山里,有参天的古老雪松。", "en": "Deep in the southern mountains, ancient cedars are said to touch the sky."},
      "phase": 3
    }
  ]
}
```

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

```json
{
  "version": 1,
  "quests": [
    {
      "id": "quest_wine_to_london",
      "type": "delivery",
      "giver": "guild",
      "name": {"zh": "送往伦敦的葡萄酒", "en": "Wine for London"},
      "description": {"zh": "公会需要20单位葡萄酒在期限内送抵伦敦。", "en": "The guild needs 20 units of wine delivered to London before the deadline."},
      "requirements": {"good_id": "wine", "quantity": 20, "dest_port_id": "london"},
      "rewards": {"gold": 3000, "reputation": {"portugal": 5}, "fame": 10},
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
| `grid` | object | `{"width": 128, "height": 96}` — locked for the Phase-1 map |
| `tiles` | object | char → `{"kind": string, "passable": bool}`; locked keys `~ . # ^` (§6.2) |
| `port_markers` | object | marker char → Port id; must cover exactly the 30 ports, and each `Port.marker`/`Port.position` must agree with it and with the map file |

```json
{
  "version": 1,
  "tile_size_px": 32,
  "grid": {"width": 128, "height": 96},
  "tiles": {
    "~": {"kind": "sea", "passable": true},
    ".": {"kind": "coastal_sea", "passable": true},
    "#": {"kind": "land", "passable": false},
    "^": {"kind": "reef", "passable": false}
  },
  "port_markers": {
    "0": "algiers", "1": "alexandria", "2": "amsterdam", "3": "antwerp",
    "4": "athens", "5": "barcelona", "6": "beirut", "7": "bordeaux",
    "8": "cagliari", "9": "candia", "a": "ceuta", "b": "cyprus",
    "c": "genoa", "d": "hamburg", "e": "istanbul", "f": "lisbon",
    "g": "london", "h": "madeira", "i": "marseille", "j": "naples",
    "k": "palermo", "l": "ragusa", "m": "seville", "n": "smyrna",
    "o": "syracuse", "p": "tripoli", "q": "tunis", "r": "valencia",
    "s": "valetta", "t": "venice"
  }
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

| Constant | Value | Used by |
|---|---|---|
| `MAP_WIDTH` | 128 tiles | map file, `20-*`, `60-*` scale reference |
| `MAP_HEIGHT` | 96 tiles | map file |
| `TILE_SIZE_PX` | 32 px | TileMap config, `80-*` |
| Map file | `data/maps/p1_mediterranean.txt` | Phase 1 world |
| Nominal scale | 1 tile ≈ 0.42° lon ≈ 0.28° lat; 1 tile ≈ 35 km | flavor/speed sanity only |

Grid origin `(0,0)` is the **top-left** tile; `x` increases east, `y`
increases south. The grid spans roughly 18°W–42°E, 28°N–55°N (Madeira sits on
the western map edge at column 0).

### 6.2 Tile legend (locked)

| Char | Kind | Passable | Notes |
|---|---|---|---|
| `~` | `sea` | yes | open water |
| `.` | `coastal_sea` | yes | shallow water; visually distinct only in Phase 1 |
| `#` | `land` | no | blocks movement |
| `^` | `reef` | no | hazard; blocks movement, reserved for Phase-2 damage rules |

Port markers (`0-9`, `a-t`) occupy a **sea tile** that is passable and
represents the port's harbor; moving onto it triggers the port-entry flow
(`20-WORLD-AND-SAILING.md`). Every port marker must have at least one
orthogonally adjacent land (`#`) tile (harbor-on-a-coast rule, checked by the
validator).

### 6.3 Map file format

- Exactly `MAP_HEIGHT` lines; each line exactly `MAP_WIDTH` chars.
- Allowed chars: the 4 tile kinds + the 30 port markers. No other bytes except
  the trailing newline per line. No BOM.
- The map-authoring task in `IMPLEMENT-Phase1.md` must place each port's
  marker at exactly the `position` given in §7.1.

## 7. Locked Phase-1 Content Lists

Exhaustive — no additions or removals in Phase 1 without amending this doc.

### 7.1 Ports (30)

`x`,`y` per §6.1's projection; `M` = map marker. Nations from §7.4.

| id | zh | en | Nation | M | x | y | produces | demands |
|---|---|---|---|---|---|---|---|---|
| lisbon | 里斯本 | Lisbon | portugal | f | 7 | 57 | wine, salt | spices, silk, timber |
| seville | 塞维利亚 | Seville | spain | m | 13 | 65 | olive_oil, wine, wool | sugar, spices |
| valencia | 瓦伦西亚 | Valencia | spain | r | 27 | 55 | silk, ceramics | wheat, timber |
| barcelona | 巴塞罗那 | Barcelona | spain | 5 | 33 | 48 | wool, cotton_cloth | iron, spices |
| marseille | 马赛 | Marseille | spain | i | 41 | 41 | wine, salt, perfume | wool, silk |
| bordeaux | 波尔多 | Bordeaux | spain | 7 | 26 | 33 | wine, salt | timber, wool |
| london | 伦敦 | London | england | g | 30 | 13 | wool, cotton_cloth | wine, spices, timber |
| amsterdam | 阿姆斯特丹 | Amsterdam | holland | 2 | 40 | 9 | cheese, glassware | spices, silk, wheat |
| antwerp | 安特卫普 | Antwerp | holland | 3 | 39 | 13 | glassware, wool | spices, wine |
| hamburg | 汉堡 | Hamburg | holland | d | 51 | 6 | dried_fish, timber, amber | wine, salt |
| genoa | 热那亚 | Genoa | italy | c | 49 | 37 | olive_oil, cotton_cloth | spices, copper |
| naples | 那不勒斯 | Naples | italy | j | 62 | 50 | olive_oil, wine | wheat, timber |
| palermo | 巴勒莫 | Palermo | italy | k | 60 | 59 | wheat, olive_oil | timber, iron |
| syracuse | 锡拉库萨 | Syracuse | italy | o | 64 | 63 | salt, wheat | timber, leather |
| cagliari | 卡利亚里 | Cagliari | italy | 8 | 50 | 56 | salt, leather | wheat, glassware |
| valetta | 瓦莱塔 | Valetta | italy | s | 62 | 67 | cotton_cloth | wheat, timber, iron |
| venice | 威尼斯 | Venice | italy | t | 57 | 34 | glassware, perfume | spices, silk, cotton_cloth |
| ragusa | 拉古萨 | Ragusa | italy | l | 71 | 44 | timber, leather, wool | wheat |
| athens | 雅典 | Athens | ottoman | 4 | 84 | 60 | olive_oil, wine, ceramics | timber, iron |
| candia | 干地亚 | Candia | ottoman | 9 | 87 | 69 | wine, olive_oil | wheat, salt |
| cyprus | 塞浦路斯 | Cyprus | ottoman | b | 107 | 70 | copper, sugar | wheat, timber |
| smyrna | 士麦那 | Smyrna | ottoman | n | 92 | 58 | carpet | wheat, glassware, iron |
| istanbul | 伊斯坦布尔 | Istanbul | ottoman | e | 96 | 49 | carpet, perfume | wheat, iron, timber |
| beirut | 贝鲁特 | Beirut | ottoman | 6 | 112 | 74 | silk, timber | wheat, salt |
| alexandria | 亚历山大 | Alexandria | ottoman | 1 | 99 | 84 | cotton_cloth, sugar, wheat | timber, iron, wine |
| tripoli | 的黎波里 | Tripoli | ottoman | p | 59 | 78 | leather, salt | wheat, timber |
| tunis | 突尼斯 | Tunis | ottoman | q | 52 | 64 | olive_oil, leather | wheat, iron |
| algiers | 阿尔及尔 | Algiers | ottoman | 0 | 36 | 64 | leather, wool | wheat, timber, wine |
| ceuta | 休达 | Ceuta | portugal | a | 16 | 67 | wheat, leather | wine, cotton_cloth |
| madeira | 马德拉 | Madeira | portugal | h | 0 | 78 | sugar, wine | wheat, iron |

Historical fidelity is deliberately loose (e.g., French-coast ports assigned
to Spain, Mediterranean islands split between Italy and the Ottomans) to keep
the 6-nation model closed; do not "fix" assignments without amending this doc.

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
| latin | 拉丁帆船 | Latin | sail | 1200 | 40 | 30 | 4 | 8/20 | 2 |
| sloop | 单桅纵帆船 | Sloop | sail | 3000 | 60 | 60 | 5 | 10/30 | 4 |
| caravel | 卡拉维尔帆船 | Caravel | sail | 8000 | 90 | 120 | 5 | 15/45 | 6 |
| galley | 桨帆船 | Galley | oar | 10000 | 70 | 50 | 6 | 40/120 | 4 |
| brigantine | 双桅帆船 | Brigantine | sail | 15000 | 110 | 150 | 6 | 20/60 | 10 |
| nao | 瑙船 | Nao | sail | 22000 | 140 | 300 | 4 | 25/80 | 10 |
| carrack | 卡拉克帆船 | Carrack | sail | 40000 | 180 | 450 | 4 | 30/100 | 16 |
| galleon | 盖伦帆船 | Galleon | hybrid | 60000 | 240 | 400 | 5 | 40/150 | 24 |

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

## 8. `tools/validate_data.py` Spec

Python ≥ 3.10, stdlib only (`json`, `re`, `sys`, `pathlib`). Run:
`python3 tools/validate_data.py` from the repo root. Exit code 0 = all checks
pass; first failure prints `FAIL <check-id> <file> <details>` and exits with
the code below. All checks run in order.

| Exit | Check group | Checks |
|---|---|---|
| 1 | Parse & envelope | every `data/*.json` parses; envelope has int `version` and exactly one plural entity key matching the filename (except `map_legend.json`, `ui_strings.json`) |
| 2 | i18n | every L10nString has exactly keys `zh`,`en`, both non-empty strings; applies recursively to all entity files. `ui_strings.json`: every top-level key except `version` maps to an L10nString, and per key the `{placeholder}` token sets in `zh` and `en` must be identical |
| 3 | Schema | every entity has its §4 required fields with correct types and enum/range constraints (incl. `id` regex, tilePos bounds, marker charset/length) |
| 4 | Referential integrity | `port.nation_id ∈ nations`; `port.produces ∪ port.demands ∪ port.market_goods ⊆ goods`; `nation.start_port_id ∈ ports`; `nation.capital_port_id ∈ ports`; `nation.start_ship_type_id ∈ ship_types`; `officer.nation_id ∈ nations`; `officer.recruit_ports ⊆ ports`; `quest.requirements.good_id ∈ goods`, `dest_port_id ∈ ports`, `exploration.discovery_id ∈ discoveries`, `rewards.reputation` keys ∈ nations; equipment `modifiers` keys are known stat names |
| 5 | Locked lists | exactly the §7.1 30 ports, §7.2 20 goods, §7.3 8 ship types, §7.4 6 nations, §7.5 6 officers — id sets must match exactly |
| 6 | Map | `data/maps/p1_mediterranean.txt` exists; 96 lines × 128 chars; all chars ∈ legend; each port marker appears exactly once and at its §7.1 `position` (agreement with `map_legend.port_markers` and `Port.marker`); each marker tile has ≥1 orthogonally adjacent `#` AND ≥1 orthogonally adjacent **passable** tile (a harbour must be sailable in and out without a diagonal step); BFS from `lisbon`'s tile over passable tiles reaches all 30 markers. **The BFS must use the movement rule players actually have (`20-*` §4.2): 8-directional but with corner-cutting forbidden** — a diagonal step is legal only when both orthogonal neighbours of the corner are passable. Using plain 8-directional BFS is a validator bug: it reports reachability through gaps no fleet can traverse. |

Additionally group 6 asserts **one single sea component** under the strict movement rule:
every passable non-marker tile must be reachable from Lisbon's tile (this is what
prevents sealed basins such as a landlocked Black Sea or an enclosed Adriatic).
Failures name the offending marker ids or the size of each stray component.

`--verbose` prints a per-check pass summary.

## 9. Edge Cases & Fail States

- **Locale string empty or whitespace-only** → validator exit 2.
- **Two ports share a marker char or position** → validator exit 3/6 (schema +
  map checks catch both encodings).
- **Map edited but `ports.json` not (or vice versa)** → validator exit 6
  (position/marker agreement). The §7.1 table is the single source of truth;
  the map-authoring task conforms the map file to it.
- **`market_goods` absent** → all 20 goods trade; adding the key later with a
  subset is a valid data-only change (Phase 3 world-map expansion).
- **`produces` ∩ `demands` ≠ ∅ for a port** → allowed but pointless; validator
  `--verbose` prints a warning, not a failure.
- **Phase-2/3 files (`equipment`, `discoveries`, `quests`) are `[]` in
  Phase 1** — valid; schema checks skip empty arrays, envelope/version still
  required.
- **Officer hired twice / dead officers** — runtime concern, owned by
  `50-CHARACTER-AND-PROGRESSION.md`; data layer only guarantees id uniqueness.

## 10. Acceptance Criteria

- [ ] All 12 artifact paths from §2 exist in the doc set's file inventory and
      match these names exactly.
- [ ] Every JSON example in this doc parses (spot-checked with a parser).
- [ ] §7 tables contain exactly 30/20/8/6/6 rows and only ids using the §3.1
      `id` regex.
- [ ] Every non-ASCII display string in tables carries both zh and en.
- [ ] §6 constants (`128 × 96`, `32px`, file name) are the only grid constants
      referenced by `20-*`, `60-*`, and `80-*`.
- [ ] `validate_data.py` check groups (exit 1–6) are implementable from §8
      alone, without further design questions.
- [ ] Harbor-relief numbers (threshold 100, payout 100, cheapest hull 1,200)
      are consistent with §7.3 and `50-*`.
