# 10 — Data Schema

## 1. Purpose & Phase

This document is the contract every other doc and every implementation task
depends on. It defines:

- The exact JSON file layout under `data/` and the schema of every entity type.
- The i18n rule for all display strings.
- The spec for `tools/validate_data.py`, the validator all data must pass.
- The locked content lists: 105 sovereign ports (the 100 plus the five of
  the 2026-11-02 route-network amendment) plus the Phase-6 neutral
  tier (§7.1), 40 goods (§7.2), 16 ship types (§7.3), 6 nations, the
  96-officer roster retaining the 6 Phase-1 starter ids (§7.5), plus the
  Phase-5/6/7 lists — 21 trade lanes (§7.6), the named-captain canon rule
  (§7.7), 4 named pirates as v2 full cards (§7.8), 24 equipment items
  (§7.9), and the Phase-8 6-background set (§7.10) — exhaustive, with no
  open slots.
- The Phase-5 npc/economy schemas (`npc_config`, `named_pirates`,
  `market_events` — §4.10, §4.12–4.13), the trade-route pair
  (`trade_routes.json` hand-authored, `trade_routes_built.json` tool-owned —
  §4.14), and the living-economy save-block shapes (§4.15).
- The Phase-6 additions: the three ocean seasonal datasets —
  `wind_regions.json` (§4.16), `ocean_currents.json` (§4.17),
  `ice_regions.json` (§4.18) — the lane `variants` schema (§4.14), the
  neutral-port tier (§7.1), the 21-lane set (§7.6; the 17 plus the four of
  the 2026-11-02 route-network amendment), and the two tool-owned
  ocean rasters (§6.5).
- The Phase-7 additions (trade empires): goods flags
  `staple`/`specialty`/`exclusive`/`flow` and the 40-good list (§4.2, §7.2),
  ship `role`/`tier` and the 16-hull list (§4.3, §7.3), equipment
  `tier`/`rare` and the 24-item list (§4.6, §7.9), the named-pirate `drop`
  refs (§4.12), the port fields `band`/`protected`/`dev`/`sphere` plus the
  per-port `shipyard`/`equipment_stock` stock lists and the port region
  bands (§4.4, §7.1), and the group-3/4/5/7 validator amendments (§8).
- The grid constants, tile legend, and the generated raster world artifact
  (`data/maps/world.png`) with its harbor-snap rule — ports are `lat`/`lon`
  data in `data/ports.json`, never hand-placed cells.
- The harbor-relief (anti-softlock) fallback spec.
- The Phase-8 additions (characters/careers/encounters): the
  named-captain canon `data/captains.json` (built; §4.11) replacing the
  retired `npc_captains.json` name pools, `officers.json` v2 — 96 entries,
  built by the same tool (§4.5) — the person-schema files `skill_gates.json`
  (§4.20), `officer_posts.json` (§4.21), `backgrounds.json` (§4.22),
  `named_pirates.json` v2 full cards (§4.12), the save-block additions
  `officer_states`/`captain_states` and the fleet's `captain_id` (§4.15),
  and the group-11/12 validator specs (§8.6–8.7).

Gates all phases. Later-phase entity schemas (`Equipment`, `Discovery`, `Quest`)
are fully specified here; each data file ships when its owning phase lands.

## 2. Artifacts

| Path | Contents | Owner doc |
|---|---|---|
| `data/nations.json` | Nation list (incl. `rivals`) | this doc |
| `data/goods.json` | Good list — 40 entries with `staple`/`specialty`/`exclusive`/`flow` since Phase 7 (§4.2, §7.2) | this doc |
| `data/ship_types.json` | ShipType list — 16 entries with `role`/`tier` since Phase 7; Phase 9 adds the three battle fields `battle_max_speed`/`battle_accel`/`battle_turn_rate` (§4.3, §7.3) | this doc |
| `data/ports.json` | Port list — the 100 locked sovereign ports plus the Phase-6 neutral tier (§7.1) in one envelope; `lat`/`lon` are the geographic truth; Phase 7 adds `band`/`protected`/`dev`/`sphere` and the per-port `shipyard`/`equipment_stock` stock lists (§4.4) | this doc |
| `data/officers.json` | Officer roster — **v2**: 96 entries (24 legend + 72 regular) in the person-card shape (§4.5); built artifact of `tools/build_captains.py`, never hand-edited | this doc |
| `data/discoveries.json` | Discovery list; `lat`/`lon` are the geographic truth | this doc / `70-*` |
| `data/quests.json` | Quest templates | this doc / `70-*` |
| `data/equipment.json` | Equipment list — 24 entries with `tier`/`rare` since Phase 7 (§4.6, §7.9) | this doc / `60-*` |
| `data/npc_config.json` | Density-dial config: presets, budgets, flow, `absolute_cap`, plus the Phase-9 `ai_profiles` nine-key block (§4.10) | this doc / `80-*` |
| `data/captains.json` | Named-captain canon — the closed roster covering the extreme density preset (§4.11); tool-built, never hand-edited | this doc / `60-*` |
| `data/captain_name_parts.json` | The canon builder's authored source: per-nation name parts + personality pools + appearance vocabulary (§4.11.1) | this doc |
| `data/named_pirates.json` | The 4 named pirates as **v2 full captain cards**, each with its rare-equipment `drop` (§4.12, §7.8) | this doc / `60-*` / `70-*` |
| `data/skill_gates.json` | Data-driven skill/stat gates — one row per locked gate (§4.20) | this doc / `50-*` |
| `data/officer_posts.json` | Officer posts: prereqs, descriptions, advice triggers (§4.21) | this doc / `50-*` |
| `data/backgrounds.json` | New-game backgrounds — exactly 6 (§4.22, §7.10) | this doc / `50-*` |
| `data/market_events.json` | Demand-event templates (§4.13) | this doc / `30-*` |
| `data/trade_routes.json` | Hand-authored major trade lanes — exactly the 21 locked ids of §7.6 (§4.14) | this doc / `20-*` / `60-*` |
| `data/wind_regions.json` | Prevailing-wind regions: month-keyed wind-from directions per ocean region (§4.16) — hand-authored | this doc / `20-*` |
| `data/ocean_currents.json` | Ocean-current systems: strength, path, width, optional reversal (§4.17) — hand-authored | this doc / `20-*` |
| `data/ice_regions.json` | Seasonal sea-ice polygons with month windows (§4.18) — hand-authored | this doc / `20-*` |
| `data/map_legend.json` | MapLegend (tiles + grid constants) | this doc |
| `data/maps/maps.json` | Map index (exactly one entry, `id: "world"`) | `90-*` §9.1 |
| `data/maps/world.png` | Generated world map artifact — indexed PNG, 4320×2160, 1 px = 1 tile (§6.3) | this doc |
| `data/maps/wind_regions.png` | Baked prevailing-wind lookup — indexed PNG, 4320×2160, 1 px = 1 tile, palette index = region id (§6.5); tool-owned, never hand-edited | this doc |
| `data/maps/currents.png` | Baked current lookup — indexed PNG, 4320×2160, 1 px = 1 tile, index = `dir_index × 3 + strength` (§6.5); tool-owned, never hand-edited | this doc |
| `data/maps/world_report.json` | Builder report: build params, sea fraction, ice extent, component sizes > 2000 tiles, per-port `harbor_tile` (berth) and `shore_tile` (§6.3, §8.1) | this doc |
| `data/maps/harbors.json` | Persisted per-port berth + shore tiles (the §6.3/§8.1 snap output, unified-movement amendment): `{"version": 1, "harbors": [{"id", "berth": [x, y], "shore": [x, y]}, …]}` — the runtime READS this table (`map_loader.harbor_tiles`) instead of re-snapping lat/lon per session; tool-owned, never hand-edited; the validator proves it matches the §6.1 recomputation for every port (§8.1 group 6) | this doc |
| `data/trade_routes_built.json` | Lane-builder artifact: tile paths + junction graph + per-port spokes (§4.14) — tool-owned, never hand-edited | this doc |
| `tools/build_world.py` | World generator: shorelines → tiles → `world.png` + `world_report.json` (§6.3); `--ascii` debug export only | this doc / `IMPLEMENT-Phase4.md` task C |
| `tools/map_overrides.json` | Waterway carves (Gibraltar, Bosphorus, …) and tidal-river carves (§6.1, `IMPLEMENT-Phase4.md` task D) | this doc |
| `tools/build_routes.py` | Lane builder: `trade_routes.json` → snapped/rasterized lanes (incl. per-variant month-window passability, §4.14), junction graph, spokes → `trade_routes_built.json` (§4.14); `--ascii` debug export only | this doc / `IMPLEMENT-Phase5.md` task F |
| `tools/route_overrides.json` | Hand fixes consumed by the lane builder (§4.14) | this doc |
| `tools/build_ocean.py` | Ocean-layer rasterizer: `wind_regions.json` + `ocean_currents.json` → `data/maps/wind_regions.png` + `data/maps/currents.png` (§6.5); `--ascii`/`--report` debug exports only | this doc / `IMPLEMENT-Phase6.md` task E |
| `tools/build_captains.py` | Canon builder: `data/captain_name_parts.json` + the quota derivation (§4.10 budgets × the `60-*` §4.1.1 formulas) + the override layers → `data/captains.json` **and** `data/officers.json` v2 (§4.11, §4.5); `--check` verifies byte-identical rebuilds | this doc / `IMPLEMENT-Phase8.md` W2-A |
| `tools/captain_overrides.json` | Legend layer consumed by the canon builder: the 4 named pirates (with their `drop`s) + 20 legend captains (§4.11, §7.7) | this doc |
| `tools/officer_overrides.json` | The 24 hand-authored legend officers consumed by the canon builder (§4.5, §7.5) | this doc |
| `tools/assets/` | Vendored public-domain shapefiles (Natural Earth 10 m land + minor islands + lakes) and `LICENSE-NOTES.md` with per-file SHA-256 | this doc |
| `data/ui_strings.json` | UI-frame L10n strings | `80-UI-UX.md` |
| `tools/validate_data.py` | Schema/i18n/integrity/map/npc-economy/trade-route/captain-canon/RPG-data validator (groups 1–12, §8) | this doc |

## 3. Shared Conventions

### 3.1 Primitive types

| Name | Definition |
|---|---|
| `id` | String matching `^[a-z][a-z0-9_]*$`, unique within its entity file |
| `L10nString` | Object with **exactly** two keys: `{"zh": <non-empty string>, "en": <non-empty string>}` |
| `money` | Integer ≥ 0, unit: gold pieces (g) |
| `day` | Integer ≥ 0, the game-clock tick unit (1 day per tick) |
| `tile` | Unit of distance/size on the world grid |
| `cargo unit` | Abstract hold space; 1 unit of any good, provision, or water = 1 cargo unit. **Display convention (amended 2026-11-02):** 1 cargo unit renders as **1 ton (t)** in every player-facing label (HUD, panels, dialogs) — display-only; storage, prices and consumption keep counting abstract units |
| `tilePos` | `{"x": int, "y": int}` with `0 ≤ x < 4320`, `0 ≤ y < 2160` (see §6). `x` wraps: every consumer (movement, BFS, camera, click) takes `x mod 4320`; `y` is bounded and never wraps. |
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
| `bonus_attribute` | id | **Phase 8**: exactly one of the 5 attribute ids (`constitution`/`intellect`/`charisma`/`courage`/`luck`) — the nation's +5 attribute at new game (`50-*` §4.2) |
| `bonus_skill` | id | **Phase 8**: exactly one of the 8 player skill ids (`seamanship`…`rumour`) — the nation's +5 signature skill at new game (`50-*` §4.2); the pair per nation is the locked decision-2 mapping |
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
      "bonus_attribute": "intellect",
      "bonus_skill": "navigation",
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
| `id` | id | one of the 40 locked ids (§7.2) |
| `name` | L10nString | |
| `category` | enum | `food` \| `textile` \| `luxury` \| `material` — descriptive only; it does **not** drive the economy (the tier flags below do) |
| `base_price` | money | global baseline price per cargo unit, before port modifiers (formula in `30-PORTS-AND-TRADE.md`) |
| `unit_size` | int | cargo units per unit of good; locked at `1` for all goods |
| `staple` | bool | optional; `true` marks a staple — the cheap basics (exactly **12** of the 40, §7.2). Authoring rule (validator-asserted, `IMPLEMENT-Phase7.md` correction 3): for every port, `demands ⊇ (staples ∖ port.produces)`; every port lists every staple it does not produce |
| `specialty` | bool | optional; `true` marks a specialty — produced at **≤ 6 ports worldwide** (validator-asserted); exactly **12** goods. A specialty good is the good's luxury consumption tier (below); a subset of specialties carries `exclusive` |
| `exclusive` | bool | optional; `true` marks 专营货 — the alignment-gated subset of specialties (**≥ 1 produced per neutral region band**, machine-checked via the port `band` field, §4.4/§7.1). Buy/sell gating is `30-*` §4.9/§4.10 behavior, not schema |
| `flow` | object | optional; `{prod: int, cons: int, capacity: int}` — per-good overrides of the tier defaults (rates/capacities in `30-*` §4.2). All three keys together or none; values > 0; `capacity ≤ 200` |

**Consumption tier (flag-driven; Phase 7).** A good's tier is read from its
flags, never derived from base-price order (the Phase-5 derived 5/10/5 split
is retired): `staple: true` → **staple** tier; `specialty: true` → **luxury**
tier; neither flag → **middle** tier. The split is exactly **12 staples /
16 middle / 12 luxuries** (validator group 7, §8.2); tier flow rates and
capacities are pinned in `30-*` §4.2. The economy tier is the only tier
notion on goods — `tier` as a purchasable-hardware gate exists on ship types
and equipment only (§4.3, §4.6).

**Listing (data-side).** A port's market rows draw exactly from
`produces ∪ demands` (staples ubiquitously by the `staple` authoring rule
above) — the former optional `market_goods` key is **retired in Phase 7** and
must not appear in any port row (§4.4). Engine/screen semantics: `30-*`
§4.4/§4.8.

```json
{
  "version": 1,
  "goods": [
    {
      "id": "wine",
      "name": {"zh": "葡萄酒", "en": "Wine"},
      "category": "food",
      "base_price": 30,
      "unit_size": 1,
      "staple": true
    },
    {
      "id": "spices",
      "name": {"zh": "香料", "en": "Spices"},
      "category": "luxury",
      "base_price": 150,
      "unit_size": 1,
      "specialty": true,
      "exclusive": true
    }
  ]
}
```

### 4.3 ShipType — `data/ship_types.json`

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 16 locked ids (§7.3) |
| `name` | L10nString | |
| `class` | enum | `sail` \| `oar` \| `hybrid` (oar/hybrid ignore wind modifiers, defined in `20-WORLD-AND-SAILING.md`) |
| `role` | enum | `war` \| `trade` \| `coastal` *(Phase 7)* — hull vocation shown on every shipyard row (wording `40-*`/`80-*`); first-pass assignments in §7.3, finalized by task S |
| `tier` | int | `1 \| 2 \| 3` *(Phase 7)* — development-gated availability: `purchasable = in_stock ∧ tier ≤ effective_dev(port)` at both port kinds (`30-*` §4.9; rows above dev grayed 需发展度). ≥ 2 hulls per tier (validator §8.2); first-pass assignment §7.3, finalized by S |
| `base_price` | money | purchase price of a new hull at 100% durability |
| `durability` | int > 0 | max hull HP; 0 at sea = sinking |
| `capacity` | int > 0 | max cargo units (goods + provisions + water combined; armament shares capacity per `40-SHIPS-AND-FLEET.md`) |
| `speed` | int > 0 | tiles per day before modifiers; every hull's final value lies in the §6.1 locked set `{16, 20, 24}` |
| `crew_min` | int > 0 | below this, speed penalty applies (formula in `20-*`) |
| `crew_max` | int ≥ crew_min | hard crew cap |
| `armament_slots` | int ≥ 0 | max cannon count (Phase 2) |
| `battle_max_speed` | int 3–5 | *(Phase 9; correction 15)* battle velocity-cap tier derived from `speed`: `16→3`, `20→4`, `24→5` — the validator enforces the exact per-speed mapping (§8, group 3); consumed by the battle `cap_eff` clamp (`60-*` §4.3a). *(Correction 15, user-locked 2026-11-04: the tiers rise one step — the 2–4 pin left battles approach-bound; the mapping's tier structure is unchanged)* |
| `battle_accel` | int | *(Phase 9)* `1 \| 2` — velocity-magnitude change allowed per turn: oar-class hulls `2` (galley, galiot, galleass), every `sail`/`hybrid` hull `1` (`60-*` §4.3a) |
| `battle_turn_rate` | int | *(Phase 9)* `45 \| 90` — degrees the heading may change per turn: 90 = latin, sloop, galiot, pinnace, dhow, xebec, galley; 45 = the other nine (caravel, brigantine, nao, carrack, galleon, galleass, fluyt, junk, caravela_redonda) — the 16 locked hulls partition exactly once (validator §8, group 3) |

Per-port availability: `facilities.shipyard` holds the hull **id list** this
port stocks (§4.4); a hull is offered iff it is on that list and passes the
`tier` gate. Save ships store `ship_type_id` as before — no save impact.

```json
{
  "version": 1,
  "ship_types": [
    {
      "id": "caravel",
      "name": {"zh": "卡拉维尔帆船", "en": "Caravel"},
      "class": "sail",
      "role": "trade",
      "tier": 2,
      "base_price": 8000,
      "durability": 90,
      "capacity": 120,
      "speed": 20,
      "crew_min": 15,
      "crew_max": 45,
      "armament_slots": 6,
      "battle_max_speed": 4,
      "battle_accel": 1,
      "battle_turn_rate": 45
    }
  ]
}
```

### 4.4 Port — `data/ports.json`

`data/ports.json` holds **all ports** in one envelope (§7.1) — the 100
locked sovereign ports plus the Phase-6 neutral tier (`nation_id: ""`); there
is no second port file and no per-map port variant.

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 100 locked sovereign ids in §7.1, or a Phase-6 neutral-tier id appended there |
| `name` | L10nString | |
| `nation_id` | id \| `""` | references Nation; `""` marks a Phase-6 neutral-tier port (§7.1) |
| `lat` | number | WGS84 latitude in degrees, `-90 ≤ lat ≤ 90`; the port's real-world position and the **geographic truth** |
| `lon` | number | WGS84 longitude in degrees, `-180 ≤ lon ≤ 180`; geographic truth |
| `band` | id | *(Phase 7)* the port's region band — one of the §7.1 band id set; required on **all 150 ports**. Consumers: the staple-coverage and exclusive-coverage checks (§8.2) and tavern telegraph scoping (`30-*` §4.9) |
| `produces` | []id | ⊆ Good ids; port sells these cheaper (supply factor in `30-*`); `produces ∩ demands = ∅` (hard rule, Phase 7 — validator §8.2) |
| `demands` | []id | ⊆ Good ids; port buys these dearer; must include every staple the port does not produce — `demands ⊇ (staples ∖ produces)` (`IMPLEMENT-Phase7.md` correction 3, validator §8.2) |
| `protected` | bool | *(Phase 7)* optional; `true` marks a **protected port**: permanent alignment to its owner, never a ledger, discount-only investment, `dev` floor never grows. ≤ 4 per nation, and the set must include every nation capital (§7.1 lists the locked set). Sovereign ports only — never on a `nation_id: ""` row |
| `dev` | int | *(Phase 7)* authored development **floor** `0…3`: capitals and `protected` ports `3`, sovereign contestable majors `2`, remaining sovereign contestable `1`, neutral tier `0` (majors chosen with historical rationale by task P). Runtime dev = `max(floor, ledger thresholds)` and is **never saved** (`90-*` §8.1); thresholds and effects in `30-*` §4.9 |
| `sphere` | []id | *(Phase 7)* nation ids — the AI claimants that may counter-invest here; **required on every contestable port** (sovereign non-core and neutral alike — foreign contestable sovereigns may appear in rival spheres); protected ports carry none; ids ⊆ Nations |
| `facilities` | object | keys with activation phase: `market:1, tavern:1, inn:1, guild:3, palace:3`; `shipyard` *(Phase 7 shape)*: an array `[]id` of **2–8** ShipType ids this port stocks (was the int `1`; the int form is retired) — present on exactly the 104 shipyard ports; `equipment_stock`: array `[]id` of equipment ids stocked (≥ **2**, required at every shipyard port); rare (`rare: true`) items never appear in any list. `palace` is **omitted** unless this port is a nation's `capital_port_id` |
| `flavor` | L10nString | 1 sentence shown in the port-entry greeting |

**Allegiance classes (Phase 7, `30-*` §4.9).** `protected: true` marks the
protected class (the decision-25 core set in §7.1); every other port —
sovereign non-core and all 45 neutrals — is **contestable**: its allegiance
is resolved at runtime from per-nation investment ledgers (save key
`port_allegiance`, `90-*` §8.1) and its development from the `dev` floor vs
the ledger thresholds. The data files carry only the fields above; ledger
arithmetic, monthly AI, and tariffs are `30-*` §4.9/§4.10 and `90-*` §8.1
material.

The harbor **pair** — the berth tile the fleet stands on and the shore tile it
docks into (`20-*` §4.11.1) — is **never stored**. Both are derived at
load/build time from `lat`/`lon` by §6.1's projection plus the locked
harbor-snap rule in §6.1, by both `tools/build_world.py` and the GDScript
runtime (identical rule, agreement tested by validator group 6, §8).
Ports render as an overlay from JSON; no port character appears in the terrain
(§6.2). The retired per-map keys (`marker`, `position`, the former world-map
marker block, and `phase`) — plus, since Phase 7, `market_goods` (listing is
derived from `produces ∪ demands`, §4.2) and the int form of
`facilities.shipyard` — no longer exist anywhere in a port row.

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
      "band": "europe_atlantic",
      "protected": true,
      "dev": 3,
      "produces": ["wine", "salt"],
      "demands": ["spices", "silk", "timber"],
      "sphere": [],
      "facilities": {"market": 1, "shipyard": ["caravel", "nao"], "equipment_stock": ["eq_cutlass", "eq_cotton_sails"], "tavern": 1, "inn": 1, "guild": 3, "palace": 3},
      "flavor": {"zh": "大航海时代的起点,特茹河口帆影如林。", "en": "Cradle of the Age of Discovery, its Tagus anchorage thick with sails."}
    },
    {
      "id": "venice",
      "name": {"zh": "威尼斯", "en": "Venice"},
      "nation_id": "italy",
      "lat": 45.44,
      "lon": 12.33,
      "band": "europe_med",
      "protected": true,
      "dev": 3,
      "produces": ["glassware", "perfume"],
      "demands": ["spices", "silk", "cotton_cloth"],
      "sphere": [],
      "facilities": {"market": 1, "shipyard": ["galley", "galleass"], "equipment_stock": ["eq_rapier", "eq_storm_sails"], "tavern": 1, "inn": 1, "guild": 3, "palace": 3},
      "flavor": {"zh": "亚得里亚海的女王,商栈与运河之城。", "en": "Queen of the Adriatic, city of canals and counting-houses."}
    }
  ]
}
```

(`band` ids above are illustrative — the locked band id set is authored by
task P and recorded in §7.1; `protected` rows carry an empty `sphere`, and a
contestable row would list its claimant nations. The `produces`/`demands`
values predate the Phase-7 40-good rewrite and are illustrative only — they
do not yet satisfy the §8.2 staple-ubiquity rule, which task P's rewrite
enforces on every port.)

### 4.5 Officer — `data/officers.json` *(Phase 8 v2; built)*

`data/officers.json` holds exactly **96 officers — 24 legends + 72 regulars**
(locked split, §7.5). Since Phase 8 it is a **built artifact** of
`tools/build_captains.py` — the same builder, name-parts, seed and override
family that produces the captain canon (§4.11; `tools/officer_overrides.json`
authors the 24 legends): never hand-edited, two consecutive builds
byte-identical (§8.6). The card is the shared person-card shape (the same
attribute/skill space as the player and NPC captains, `50-*` §2.1–2.2) plus
the three officer-only skills.

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique; the 6 Phase-1 starter ids (§7.5) are retained |
| `name` | L10nString | unique across every person in `captains.json` ∪ `officers.json` (§8.6) |
| `nation_id` | id | references Nation |
| `legend` | bool | `true` on exactly the 24 hand-authored legends |
| `main_skill` | id | the native role's **signature skill** — the strict maximum of `skills` (validator-asserted) |
| `attributes` | object | the 5 attribute keys of §4.11 (`constitution`…`luck`); ints 1–100 |
| `skills` | object | all **11** skill keys — the 8 player skills plus `medicine`/`carpentry`/`cooking`; ints 0–100 |
| `personality` | []id | 1–2 tags from the native role's personality pool (§4.11.1) |
| `appearance` | object | the 4 appearance axes, one value each (§4.11.1) |
| `wage_daily` | money | gold per day while employed; legends 40–60, regulars 20–35 (§8.7) |
| `recruit_ports` | []id | ≥ 1 port id; legends hand-authored; regulars ⊆ the officer's own nation's ports (the per-nation home-port band, `IMPLEMENT-Phase8.md` correction 9) |
| `bio` | L10nString | 1 sentence shown in the recruit dialog |

Bands (validator group 12, §8.7): main-skill legends **45–60** / regulars
**25–45**. The **native role** is the person's fixed vocation: it pins
`main_skill`, the personality pool, the recruit text and the initial skill
distribution — it never restricts appointment. A **post** (§4.21) is
appointable: any officer meeting a post's prereq may take it; in-post
contribution, loyalty and the `+1`/90-sea-days growth are `50-*` behavior.
**Quotas (§8.7):** specialty coverage — each of the 11 skills is carried at
≥ 20 (the post-prereq band) by ≥ 10 officers; captain-qualified —
`skills.seamanship ≥ 25 ∧ attributes.courage ≥ 30` on ≥ 12 officers.

```json
{
  "version": 2,
  "officers": [
    {
      "id": "off_mateus_alvares",
      "name": {"zh": "马特乌斯·阿尔瓦雷斯", "en": "Mateus Álvares"},
      "nation_id": "portugal",
      "legend": false,
      "main_skill": "navigation",
      "attributes": {"constitution": 11, "intellect": 14, "charisma": 12, "courage": 13, "luck": 10},
      "skills": {"seamanship": 18, "navigation": 30, "swordplay": 8, "gunnery": 6,
                  "appraisal": 10, "negotiation": 12, "cartography": 16, "rumour": 10,
                  "medicine": 0, "carpentry": 0, "cooking": 8},
      "personality": ["bookish", "patient"],
      "appearance": {"face": "lean", "beard": "clean", "eyes": "hazel", "hair": "brown"},
      "wage_daily": 30,
      "recruit_ports": ["lisbon", "madeira"],
      "bio": {"zh": "一位在老领航员手下学艺的青年,星象与海图无一不精。", "en": "A young pilot schooled by old navigators; at home with stars and charts alike."}
    }
  ]
}
```

(The personality/appearance values above are illustrative — the locked
vocabularies are authored with the name parts, §4.11.1.)

### 4.6 Equipment — `data/equipment.json` *(Phase 2; Phase 7 extension)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | |
| `name` | L10nString | |
| `slot` | enum | `weapon` \| `armor` \| `figurehead` \| `sail` |
| `modifiers` | object | stat-name → int delta; stat names from `50-*` (player) or `40-*` (ship); Phase 7 adds the sideways keys `storm_damage_pct` (−%, multiplies `storm_damage_for`) and `scurvy_delay_days` (semantics `60-*` §4.11.12) |
| `price` | money | 300–6,000 g band (§7.9 guideline: tier 1 ≤ 1,500, tier 2 ≤ 3,500, tier 3 above) |
| `tier` | int | `1 \| 2 \| 3` *(Phase 7)* — **2 tier-1 + 2 tier-2 + 2 tier-3 items per slot** (§7.9); same `tier ≤ effective_dev(port)` gate as ships (§4.3) |
| `rare` | bool | *(Phase 7)* optional; `true` on exactly **4** items — one per slot, obtainable **only** as a named-pirate `drop` (§4.12); never in any `facilities.equipment_stock` list, never tier-gated (never purchasable at all) — validator-asserted (§8.2 for the stock rule; the `drop` pairing check rides in group 7 since Phase 8, cross-referenced by group 11 §8.6) |
| `phase` | int | locked at `2` for all equipment |

Locked content set (24 items, Phase 7): §7.9. Modifier semantics
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
      "tier": 1,
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
| `grid` | object | `{"width": 4320, "height": 2160}` — locked (§6.1) |
| `tiles` | object | char → `{"kind": string, "passable": bool}`; locked keys `~ . # ^ I` (§6.2) |

There is no `port_markers` table: port markers left the map (decision 7 in
`IMPLEMENT-Phase4.md`). Ports are an overlay layer drawn from
`data/ports.json#ports[].lat/lon` via the harbor-snap rule (§6.1), so the
legend carries only `version`, `tile_size_px`, `grid`, and `tiles`.

```json
{
  "version": 1,
  "tile_size_px": 32,
  "grid": {"width": 4320, "height": 2160},
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
| `ai_profiles` | object | *(Phase 9)* per-kind enemy battle behavior — keyed by battle kind, **exactly 9 rows**, each row carrying **exactly 9 keys** (value table below; validator §8.2 item 14) |

The Phase-5 block is **locked verbatim** — task D copies it verbatim; the
`presets`/`budgets`/`flow` key sets are exactly these (the Phase-9
`ai_profiles` key below joins the same envelope):

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

**Phase-9 `ai_profiles` block *(Phase 9)*.** The envelope grows one more
top-level key, `ai_profiles` — an object keyed by battle kind with **exactly
9 rows**: `pirate`, `privateer`, `patrol`, `navy`, `tournament`, `treasure`,
`trader`, `coaster`, `courier`. Each row carries **exactly 9 keys**:

| Key | Type | Rule |
|---|---|---|
| `kind` | string | mirrors the row's map key — the validator checks `kind` == key (§8.2 item 14) |
| `archetype` | enum | `aggressive` \| `balanced` \| `cautious` — the T3 θ group selector (`60-*` §4.9c) |
| `aggression` | int | 0–100 |
| `preferred_range` | int | 1–3 |
| `flee_below_hp_pct` | int | 0–100 |
| `focus` | enum | `weakest` \| `nearest` \| `flagship` |
| `courage_mod` | int | −10…10 |
| `formation` | enum | `line_ahead` \| `column` \| `screen` \| `swarm` (runtime consumer: the fleet layer, `60-*` §4.9b) |
| `ai_level` | int | `0` \| `1` — T2 deterministic greedy vs T3 one-ply lookahead (`60-*` §4.9c) |

Normative value table (all 9 rows, locked):

| kind | archetype | aggression | preferred_range | flee_below_hp_pct | focus | courage_mod | formation | ai_level |
|---|---|---|---|---|---|---|---|---|
| pirate | aggressive | 90 | 2 | 0 | weakest | +5 | swarm | 1 |
| privateer | aggressive | 80 | 2 | 10 | weakest | +5 | swarm | 1 |
| patrol | balanced | 70 | 3 | 15 | nearest | 0 | line_ahead | 1 |
| navy | balanced | 60 | 3 | 15 | flagship | 0 | line_ahead | 1 |
| tournament | balanced | 60 | 3 | 0 | weakest | 0 | line_ahead | 1 |
| treasure | cautious | 10 | 3 | 40 | nearest | −5 | screen | 0 |
| trader | cautious | 5 | 3 | 50 | nearest | −5 | column | 0 |
| coaster | cautious | 5 | 3 | 50 | nearest | −5 | column | 0 |
| courier | cautious | 5 | 3 | 60 | nearest | −5 | column | 0 |

**Lookup rule (correction 8):** a battle kind missing from the table falls
back — `hunter` → the `navy` row (mirroring `NpcFleets.composition_kind`);
**no `hunter` row may exist**. The `coaster` row is forward-compat +
sandbox-only (coasters are intimidate-only, never battle, `60-*` §4.1.1) —
the validator still checks its shape (§8.2 item 14). **All nine keys land
with the Phase-9 W2 data wave** (correction 11) even though the runtime
consumers arrive per stage (`formation` → the fleet layer, `ai_level` → T3);
the validator checks the shape from day one. Behavior consumption is
`60-*` §4.9a.

```json
{
  "version": 1,
  "ai_profiles": {
    "pirate": {
      "kind": "pirate",
      "archetype": "aggressive",
      "aggression": 90,
      "preferred_range": 2,
      "flee_below_hp_pct": 0,
      "focus": "weakest",
      "courage_mod": 5,
      "formation": "swarm",
      "ai_level": 1
    }
  }
}
```

(Excerpt — the shipped `data/npc_config.json` carries all nine kind rows
beside the locked `presets`/`budgets`/`flow` block above.)

### 4.11 Captain — `data/captains.json` *(Phase 8; built)*

The **closed named-captain canon**. It replaces the retired Phase-5 name
pools (`data/npc_captains.json` — the file is deleted, and validator group 11
asserts its absence, §8.6): every NPC fleet's captain is a named card from
this roster, and a captain never dies — defeat moves it onto the return
queue (`captain_states`, §4.15; the state machine and lifecycle behavior are
`60-*` material, read by `scripts/world/captains.gd`).

**Built artifact** of `tools/build_captains.py` — the same standing as
`trade_routes_built.json` (§4.14): written only by the builder, never
hand-edited, two consecutive builds byte-identical (§8.6). One tool, one
parts/seed/override family produces **both** `captains.json` and
`officers.json` v2 (§4.5).

**Envelope** (a tool output, validator group-1 exception — key `captains`,
§8): `{"version": 1, "generated_by": "tools/build_captains.py",
"artifact": "data/captains.json", "build": {…}, "quota_table": {…},
"captains": […]}` — `build` records the seed and source paths, `quota_table`
the derived role × tier × nation coverage table (item below).

Card fields:

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique within the canon |
| `name` | L10nString | unique across every person — canon ∪ officers (§8.6); names are never reused |
| `nation_id` | id \| `""` | owner nation; pirates keep `""` |
| `role` | enum | `trader` \| `coaster` \| `patrol` \| `courier` \| `privateer` \| `pirate` \| `hunter` — the 7 locked roles. The §4.1.1 `treasure` rows commission **`trader`-role cards of the fleet's nation at tier 2** (a treasure fleet is a national convoy; no 8th role exists — W1 pin 2026-11-02) |
| `tier` | int | `1 … 3`, within the role's range (table below) |
| `level` | int | `1 + tier×4`, `+2` for pirate/hunter (tier 1 → 5; tier 2 → 9, 11 pirate/hunter; tier 3 → 13, 15 pirate/hunter) |
| `attributes` | object | the 5 keys `constitution`/`intellect`/`charisma`/`courage`/`luck` (`50-*` §2.1); ints 1–100 |
| `skills` | object | the 8 player skill keys (`50-*` §2.2); ints 0–100 |
| `personality` | []id | 1–2 tags from the role's personality pool (§4.11.1) |
| `appearance` | object | exactly the 4 axes `face`/`beard`/`eyes`/`hair`, one value each (§4.11.1); string-part assembly renders the card's appearance sentence (`80-*`) |
| `drop` | id | **the 4 named pirates only**; references a `rare: true` equipment item of §7.9 (§8.6 — the relocated group-7 pin) |
| `legend` | bool | `true` on exactly the 24 hand-authored cards (§7.7: the 4 named pirates + 20 legend captains, authored in `tools/captain_overrides.json`) |
| `home_port` | id | optional; ∈ ports (the dossier's familiarity-6 row reveals it; a card without one has no home-port row) |

**Generation rules (generated — non-legend — cards; §8.6 re-asserts them
term-by-term):**

- **Level:** `1 + tier×4` (`+2` pirate/hunter).
- **Attributes:** base 10; the template's main attribute `+3×tier`, its
  secondary `+2×tier`, the other three `+1×tier`; every final value jitters
  by a seeded `±3`.
- **Skills:** the template's signature skill `8×tier + seeded(0…6)`; its
  secondary skill `4×tier`; every other skill `0`.
- **Personality:** 1–2 tags drawn from the role pool. **Appearance:** one
  value per axis.

**Role templates** (main/secondary attribute — signature/secondary skill):

| Role | Attributes | Skills | Tier range |
|---|---|---|---|
| `trader` | 魅 charisma / 运 luck | 交涉 negotiation · 鉴定 appraisal | 1–2 |
| `coaster` | 体 constitution / 运 luck **low** | none — every skill `0` | 1 only |
| `patrol` | 胆 courage / 魅 charisma | 炮术 gunnery · 操船 seamanship | 2 only |
| `courier` | 体 constitution / 悟 intellect | 航海 navigation · 操船 seamanship | 1–2 |
| `privateer` | 胆 courage / 运 luck | 剑术 swordplay · 炮术 gunnery | 2–3 |
| `pirate` | 胆 courage / 魅 charisma | 剑术 swordplay · 炮术 gunnery | 1–3 |
| `hunter` | 胆 courage / 悟 intellect | 剑术 swordplay · 航海 navigation | 2–3 |

(The coaster's `-low` tag is the W1 concretization of the backlog template
line: the coaster's **luck sits at the others step (`+1×tier`), never the
secondary step**, and the coaster names **no skills** — all `0`. Coasters
never trigger contact and are not attackable; their hulls set their speed.)

**Quota rule (locked in §7.7, machine-checked by §8.6 items 3–4):** the canon
covers the **extreme density preset** — the card count is computed from
`data/npc_config.json` (§4.10) budgets × preset multipliers under the role
budget formulas of `60-*` §4.1.1 (as amended by `60-*` §4.11.14 for
nationless coasters), including the transient hunter/treasure rows; the
builder emits the derived `quota_table` and fills every cell.

**Sources:** `data/captain_name_parts.json` (§4.11.1) + the quota derivation
+ `tools/captain_overrides.json` (the legend layer wins over generation for
its ids; the 4 pirates carry their Phase-7 `drop` fields verbatim —
correction 7).

```json
{
  "version": 1,
  "generated_by": "tools/build_captains.py",
  "artifact": "data/captains.json",
  "build": {"seed": "sailage-canon-v1", "parts": "data/captain_name_parts.json",
            "overrides": ["tools/captain_overrides.json", "tools/officer_overrides.json"],
            "coverage_preset": "extreme"},
  "quota_table": {
    "pirate": {"1": {"": 32}, "2": {"": 20}, "3": {"": 16}},
    "hunter": {"2": {"england": 2, "spain": 2}, "3": {"england": 2, "spain": 2}}
  },
  "captains": [
    {
      "id": "cap_pirate_0042",
      "name": {"zh": "雅各布·埃雷拉", "en": "Jacobo Herrera"},
      "nation_id": "",
      "role": "pirate",
      "tier": 2,
      "level": 11,
      "attributes": {"constitution": 13, "intellect": 10, "charisma": 15, "courage": 16, "luck": 12},
      "skills": {"seamanship": 0, "navigation": 0, "swordplay": 18, "gunnery": 8,
                  "appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0},
      "personality": ["ferocious", "vain"],
      "appearance": {"face": "scarred", "beard": "forked", "eyes": "dark", "hair": "black"},
      "legend": false
    }
  ]
}
```

(The `quota_table` and card values above are illustrative — the table is
builder-computed from §4.10 × the §4.1.1 formulas at the extreme preset;
`nation_id: ""` cells are the nationless pirate/coaster rows.)

#### 4.11.1 `data/captain_name_parts.json` — the builder's authored source *(Phase 8)*

Plain object file (validator group-1 exception, like `npc_config.json`).
It carries every authored string-part family the builder draws from — names,
personality pools and the appearance vocabulary:

| Block | Shape | Rule |
|---|---|---|
| `surnames` | object `nation_id → []L10nString` | the 6 nation keys **plus** `""` (the nationless set pirates draw from); ≈ 30 parts per set, era-plausible per nation, zh and en |
| `given_names` | object `nation_id → []L10nString` | same key set; ≈ 30 parts per set |
| `personalities` | object `{all: []id, roles: {role: []id}}` | one shared tag vocabulary (`all`; snake_case ids; ≥ 8 tags) and per-role pools (`roles.<pool_id>` ⊆ `all`, 2–5 tags each) — one pool per §4.11 captain role, plus one per officer native role (pool id = the native-role id; the native-role list is `50-*` §4.5's pin); every tag has a `char.personality.<tag>` `ui_strings.json` row |
| `appearance` | object of exactly 4 axes | `face`, `beard`, `eyes`, `hair`; ≥ 4 values per axis; every value has a `char.appearance.<axis>.<value>` `ui_strings.json` row |
| `officer_bios` | object `role → []L10nString-template` | per-officer-native-role zh/en bio templates for the generated officer regulars; `{n}` substitutes the nation display name (from `data/nations.json`); the 6 starter bios and the 24 legend bios stay hand-authored in `tools/officer_overrides.json` and are never templated |

Assembly: a generated person's display name is drawn without replacement
from its nation's `given_names` × `surnames` (assembled in the locale's
order — zh 若昂·阿尔梅达, en João Almeida), so **no two people ever share a
name** — the builder refuses a colliding draw and the validator re-asserts
uniqueness across the canon and the officer roster (§8.6). Cards draw
`personality` (1–2 tags, their own role's pool) and one value per appearance
axis. The exact part lists and vocabularies are authored by the W2 roster
task and recorded in this subsection after authoring.

```json
{
  "version": 1,
  "surnames": {"portugal": [{"zh": "阿尔梅达", "en": "Almeida"}, {"zh": "苏亚雷斯", "en": "Soares"}], "": [{"zh": "埃雷拉", "en": "Herrera"}]},
  "given_names": {"portugal": [{"zh": "若昂", "en": "João"}, {"zh": "迪奥戈", "en": "Diogo"}], "": [{"zh": "雅各布", "en": "Jacobo"}]},
  "personalities": {
    "all": ["ferocious", "greedy", "vain", "stoic", "bookish", "patient", "boastful", "sullen"],
    "roles": {"trader": ["greedy", "patient", "boastful"], "pirate": ["ferocious", "vain", "sullen"]}
  },
  "appearance": {
    "face": ["lean", "round", "scarred", "weathered"],
    "beard": ["clean", "stubble", "full", "forked"],
    "eyes": ["dark", "grey", "hazel", "pale blue"],
    "hair": ["black", "brown", "sun-bleached", "grey-streaked"]
  }
}
```

(The example above is an illustrative excerpt — real part sets hold ≈ 30
entries per nation set and the full role pool map.)

### 4.12 NamedPirate — `data/named_pirates.json` *(Phase 5; v2 full cards, Phase 8)*

Exactly 4 entries (§7.8) — since Phase 8 each is a **full captain card**:
every §4.11 field plus `drop`. The four cards are authored once, in the
legend layer `tools/captain_overrides.json`, and therefore also exist inside
the `data/captains.json` canon; the `named_pirates.json` rows are the
bounty-facing copies (tier semantics `70-*` §4.5). Group 11 asserts the two
copies agree field-for-field (§8.6) — `version` bumps to `2`.

| Field | Type | Rule |
|---|---|---|
| *(all §4.11 card fields)* | | `id`, `name` (unique canon-wide), `nation_id` — all four keep `""` — , `role: "pirate"`, `tier` 1–3, `level` (`+2` pirate), `attributes`, `skills`, `personality`, `appearance`, `legend: true` |
| `drop` | id | the equipment id this captain's sunk/captured hull yields (`60-*` §4.11 loot flow keys off the captain id); must reference a `rare: true` equipment item of §7.9. The Phase-7 pin is **re-checked in group 7** against the v2 full cards, cross-referenced by group 11 (§8.6), unchanged in semantics (`IMPLEMENT-Phase8.md` correction 7) |

Behavior change (Phase 8): a defeated named pirate no longer respawns under
a new name — it enters the §4.11 return queue
(`defeated → returning(day+60) → active`); the Phase-5 successor machinery
(`named_pirate_respawns`, alias slots) is retired. `quest_gen` bounty
targets still prefer named captains (`70-*` §4.9.5).

```json
{
  "version": 2,
  "named_pirates": [
    {
      "id": "pirate_murad_red_sail",
      "name": {"zh": "「红帆」穆拉德", "en": "Murad the Red Sail"},
      "nation_id": "",
      "role": "pirate",
      "tier": 2,
      "level": 11,
      "attributes": {"constitution": 14, "intellect": 12, "charisma": 15, "courage": 17, "luck": 11},
      "skills": {"seamanship": 0, "navigation": 0, "swordplay": 19, "gunnery": 8,
                  "appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0},
      "personality": ["ferocious", "vain"],
      "appearance": {"face": "scarred", "beard": "forked", "eyes": "dark", "hair": "black"},
      "legend": true,
      "drop": "eq_red_sail"
    }
  ]
}
```

(The attribute/skill values above are illustrative legend-layer content;
the `drop` ids are the shipped Phase-7 pairings. Hand-authored legend names
use the 「alias」 style and never collide with part-assembled names — §8.6
asserts the whole space.)

### 4.13 MarketEvent — `data/market_events.json` *(Phase 5)*

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique |
| `scope` | enum | `"port"` — the only valid value this phase (group 7); rotation binds each instance to a concrete port (`30-*` §4.5) |
| `cadence_days` | int > 0 | width of the template's seeded scheduling window (`30-*` §4.5) |
| `duration_days` | int > 0 | how long the rate-surge stays active (Phase 7: consumption ×3, `30-*` §4.5) |
| `rate_override` | array | the template's goods as a non-empty id list, each ∈ goods, no duplicates — consumption of every listed good is ×3 for the duration (Phase 7 replaced the `shifts` rest-override; §8.2 item 4) |
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
      "rate_override": ["wheat", "wine"],
      "name": {"zh": "丰收节宴饮", "en": "Harvest Festival Feasting"}
    }
  ]
}
```

### 4.14 TradeRoute — `data/trade_routes.json` + `data/trade_routes_built.json` *(Phase 5)*

`data/trade_routes.json` holds **only the major lanes** — exactly the 21
locked ids of §7.6, hand-authored as historical facts. Envelope
`{"version": 1, "lanes": [...]}` (group-1 exception: key `lanes`).

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 21 locked lane ids (§7.6) |
| `class` | enum | `"major"`; minor spokes are builder-generated and never stored in this file |
| `nations` | []id | ⊆ Nation ids; the fleets that work the lane |
| `waypoints` | [][lat, lon] | ≥ 2 pairs in the `ports.json` coordinate space (§3.1); wrap-aware across the dateline — a crossing segment keeps `x` monotonic under wrap (the Manila lane) |
| `goods` | []id | ⊆ Good ids; the lane's historical trade goods |
| `chokepoints` | []string | ≥ 1 snake_case tag per lane naming the historical choke points the lane passes |
| `variants` | []object | optional (Phase 6): seasonal waypoint overrides — each `{"id": id, "months": []int, "waypoints": [][lat, lon]}`; rules below (validator group 10, §8.5) |

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

Lane **`variants`** (Phase 6, seasonal waypoint overrides):

- each variant: `id` unique within its lane; `months` a non-empty list of
  ints 1–12; `waypoints` ≥ 2 pairs like the base field;
- `months` sets are pairwise **disjoint** across a lane's variants; months no
  variant covers use the **base** `waypoints` — so base + variants always
  cover all 12 months;
- each variant's waypoint walk must be passable **within its own month
  window** — the walk is checked with the in-month seasonal-ice mask
  (§4.18); a violation is a hard build error naming the lane
  (`tools/build_routes.py`), re-asserted by validator group 10 (§8.5);
- a lane crossing a seasonal-ice polygon must either carry a covering
  variant set or avoid ice year-round (§8.5);
- first customer: `hanseatic_north` carries a winter variant outside the
  Baltic freeze (§7.6).

Example (variant shape; authored waypoint/chokepoint values are task-owned —
Phase-6 task P):

```json
{
  "version": 1,
  "lanes": [
    {
      "id": "hanseatic_north",
      "class": "major",
      "nations": ["holland"],
      "waypoints": [[60.39, 5.32], [54.40, 18.68], [53.87, 8.70]],
      "goods": ["dried_fish", "timber"],
      "chokepoints": ["skagerrak"],
      "variants": [
        {
          "id": "winter_off_baltic",
          "months": [12, 1, 2, 3],
          "waypoints": [[60.39, 5.32], [57.70, 10.70], [53.87, 8.70]]
        }
      ]
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
  lane waypoint within Chebyshev 40 (wrap-aware; the Phase-6 rescale of the
  former 20, §6.1 enumeration), else a direct generated spoke to the port's
  national capital. A neutral port (`nation_id: ""`, §7.1) has no capital:
  its fallback is the **nearest lane waypoint, unbounded**. A port with
  neither is a hard build/validator error naming the port, never a runtime
  stall.
  **Rule-1 selection is walk-aware (pinned at the W2 gate):** among the
  in-radius lane waypoints in Chebyshev order, the builder picks the first
  whose spoke walk succeeds (the builder's own budgeted A*); a candidate
  whose walk fails is skipped, and only when no in-radius candidate has a
  walk does the rule fall through to the capital/override fallbacks. An
  override row is **superseded** (a build error naming the port) exactly
  when rule 1 succeeds for that port; an override whose rule-1 walk fails
  stays legal.
  **Rule 5 — connectivity completion (2026-11-06 amendment).** After
  rules 1–4 resolve every spoke, the builder builds the junction graph;
  if it has more than one component (§8.3 item 7 requires exactly one),
  the detached component is re-attached: the spoke whose port harbor is
  closest (wrapped Chebyshev) to any waypoint tile of a lane anchored in
  the main (largest) component is **re-pathfound there with A\*** and
  rewritten as resolution kind `"completion"` — its endpoint is the named
  lane waypoint, its `tile_path` is the A\* water path, and it must be
  **load-bearing** (without it the graph stays disconnected — the
  validator rebuilds the graph without the spoke and asserts the split).
  Spoke attachments pinned by the §8.3 item 7 probes (`lima`,
  `valparaiso`, `guayaquil`, `panama` → `pacific_america`; `safi`,
  `elmina`, `luanda` → `west_africa`) are never rewritten. Candidate
  order is deterministic `(chebyshev, y, x, lane rank, waypoint index,
  port id)`; a failed walk tries the next candidate; passes repeat to
  fixpoint (non-convergence is a build error). Motivation: the §6.2 coast
  cleanup re-opens walks, which legitimately supersedes override spokes —
  but Canton's override spoke was the one bridge the Pacific cluster
  (`manila_galleon` / `pacific_america`) had into the world network, and
  rule 1's local resolution cannot see network-level connectivity.
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

### 4.15 Save-block shapes (Phase 5; Phase-8 additions)

The living-economy save blocks — keys of the save payload since v5, carried
into v6 unchanged (`90-*` §8.1; the Phase-6 keys `control_prefs`,
`world.sail_trim`, `world.heading`, `world.wind_dir` are pinned in
`90-*` §8.1 only). Not data files: runtime state whose shapes this doc pins.
Shapes only; behavior lives in `30-*`/`60-*`. The former sixth Phase-5 key
`named_pirate_respawns` is **retired at save v9** with the successor
machinery — the `captain_states` return queue replaces it (row below). Phase
8 adds `officer_states`/`captain_states` and reshapes the fleet's captain
field.

| GameState field | Type | Shape |
|---|---|---|
| `market_stocks` | object | `{port_id: {good_id: stock int}}` — every port × every good that trades there; initialized at `new_game` from the derived resting stock (`30-*` §4.2), no RNG; stock range per `30-*` §4.2 |
| `npc_fleets` | []object | fleet dicts (table below); renames the retired `hostile_fleets` |
| `wrecks` | []object | `{"cell": tilePos, "cargo": {good_id: units}, "salvage_gold": money, "spawn_day": day}` — contents per the `60-*` auto-resolve table (cargo or salvage gold); expiry on the `60-*` schedule |
| `npc_preset` | id | one of the §4.10 preset keys; default `"normal"` |
| `market_events` | []object | active instances: `{"template_id": id, "port_id": id, "start_day": day}`; expiry derives from the template's `duration_days` (`30-*` §4.5) |
| `officer_states` *(Phase 8)* | object | `{officer_id: {loyalty: int 0–100, sea_days: int ≥ 0, post_id: id \| "", ship_id: id \| "", talk_cd_day: day, gift_cd_day: day, defeats: int ≥ 0}}` — one entry per employed officer; `post_id = ""` = idle; `ship_id` non-empty only on a captain post (`50-*`) |
| `captain_states` *(Phase 8)* | object | `{captain_id: {status: "active" \| "defeated" \| "returning", return_day: day, tier_now: int 1–3, stance: int (the ± scale, `60-*`), familiarity: int, dossier_seen: bool, defeats: int ≥ 0, wins: int ≥ 0}}` — full entries **only for met captains**; the canon card (§4.11) is save-independent (`60-*`) |

Fleet dict — the locked save shape (`60-*` §4.1):

| Field | Type | Rule |
|---|---|---|
| `id` | string | stable fleet id; the seeded streams (captain draw, specialty, decisions) key off it |
| `role` | id | one of the 8 fleet roles (`60-*` §4.1) |
| `nation_id` | id \| `""` | owner nation; pirates keep `""` |
| `cell` | tilePos | current grid position (§3.1; `x` wraps) |
| `route` | object | `{"lanes": []id, "leg": int, "tile_index": int}` — position on the built lane network (§4.14) |
| `cargo` | object | `{good_id: units}` — the actual hold contents |
| `captain_id` | string | *(Phase 8)* the captain's `data/captains.json` id (§4.11); stance/familiarity/return state lives in `captain_states` (row above). The retired Phase-5 shape `captain: {"pool_id", "name_index"}` (the `npc_captains.json` name pools) must not appear |
| `specialty` | id | optional; the good id drawn at spawn (traders) |
| `cooldown_until_day` | day | pursuit/spawn cooldown |
| `ships` | []object | the §4.11.3 composed ship list, stored at spawn (unified-movement amendment, `60-*` §4.11.11): each entry `{"ship_type_id": id, "durability": int, "crew": int, "provisions": int, "water": int, "cannons": int, "equipment": {"figurehead": id \| "", "sail": id \| ""}, "cargo": {good_id: units}}`; hull draws key off `seed` only (never the day), so a fleet missing the field (older save) backfills it lazily, bit-identical to the spawn draw; drives the fleet's §4.4 base speed (slowest hull), cached in the derived `speed` (number — float since the Phase-8 ±10% captain jitter, W4-B) + `speed_class` (id) pair written beside the list at spawn and backfilled under the same lazy rule — **spawn-time caching keeps read-only passes (markers, diagnostics) mutation-free** (the `80-*` §4.6 snapshot-purity probe) |

```json
{
  "id": "fleet_spain_trader_017",
  "role": "trader",
  "nation_id": "spain",
  "cell": {"x": 1025, "y": 307},
  "route": {"lanes": ["west_indies_flota"], "leg": 1, "tile_index": 42},
  "cargo": {"wine": 28},
  "captain_id": "cap_trader_0207",
  "specialty": "wine",
  "cooldown_until_day": 0,
  "ships": [
    {"ship_type_id": "caravel", "durability": 90, "crew": 15,
      "provisions": 0, "water": 0, "cannons": 2,
      "equipment": {"figurehead": "", "sail": ""}, "cargo": {"wine": 3}},
    {"ship_type_id": "latin", "durability": 40, "crew": 8,
      "provisions": 0, "water": 0, "cannons": 0,
      "equipment": {"figurehead": "", "sail": ""}, "cargo": {"wine": 3}}
  ]
}
```

### 4.16 WindRegion — `data/wind_regions.json` *(Phase 6)*

Envelope `{"version": 1, "wind_regions": [...]}` — the plural key **equals
the file basename**, so validator group 1 needs no exception (§3.2).

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique |
| `name` | L10nString | |
| `polygon` | [][lat, lon] | closed ring — the first pair is repeated as the last pair; vertices in the `ports.json` coordinate space (§3.1) |
| `months` | object | exactly 12 keys `"1"` … `"12"`; each value a direction token naming the **wind-from** direction prevailing that month |
| `variability` | enum | `steady` \| `variable` |

- **`variability` is authored metadata only in Phase 6** — no runtime rule
  consumes it this phase: the daily jitter table keys off the day's weather
  exclusively (`20-*` §4.7.1); the debug chart's info strip may display it.
  Values remain the locked enum `steady` \| `variable`.
- **Direction tokens:** the 8 compass directions `N NE E SE S SW W NW`
  (wind-FROM) plus `VAR` — a month with no prevailing direction draws
  uniformly.
- **Coverage:** 15–25 regions tile **all ocean between 70°N–60°S**; water no
  polygon covers falls back to `VAR` + `variable`.
- **Daily roll:** the ledger's weather step (step 3), after the
  weather-strength roll, on the same seeded stream — pinned order
  **strength → direction**; jitter by weather is pinned in `20-*` §4.7. The
  result persists per day as `GameState.world.wind_dir` (an 8-dir id;
  `90-*` §5.4).
- **Baked lookup:** `data/maps/wind_regions.png` (§6.5) — palette index =
  region id; tool-owned.

```json
{
  "version": 1,
  "wind_regions": [
    {
      "id": "trade_winds_n_atlantic",
      "name": {"zh": "北大西洋信风带", "en": "North Atlantic trade-wind belt"},
      "polygon": [[8.0, -70.0], [30.0, -70.0], [30.0, -20.0], [20.0, -20.0], [8.0, -30.0], [8.0, -70.0]],
      "months": {"1": "NE", "2": "NE", "3": "NE", "4": "NE", "5": "NE", "6": "NE",
                  "7": "NE", "8": "NE", "9": "NE", "10": "NE", "11": "NE", "12": "NE"},
      "variability": "steady"
    }
  ]
}
```

### 4.17 OceanCurrent — `data/ocean_currents.json` *(Phase 6)*

Envelope `{"version": 1, "ocean_currents": [...]}` — the plural key **equals
the file basename**, so validator group 1 needs no exception (§3.2).
≈ 20 hand-authored systems (exact list task-owned by Phase-6 task D; sources
cited per system in `LICENSE-NOTES.md`).

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique |
| `name` | L10nString | |
| `strength` | int | `1` \| `2` \| `3` |
| `path` | [][lat, lon] | ≥ 2 pairs (§3.1) — the system's flow axis, downstream order |
| `width_tiles` | int > 0 | the system's corridor width in tiles, at the §6.1 5 nm grid. **Corridor expansion (pinned):** the baked corridor is the path tiles dilated by Chebyshev radius `floor((width_tiles − 1) / 2)` per side (wrap-aware on x); authored widths are odd numbers (1/3/5 tiles at 5 nm), so the painted width is exactly `width_tiles`. Overlaps resolve strongest-then-id-order as pinned in §6.5. This is the convention `tools/build_ocean.py` implements and validator group 9's determinism check exercises |
| `reversal` | object? | optional; exactly `{"summer_months": []int, "direction": "reverse"}` — `summer_months` non-empty month ints; the decoded current vector **flips during these months at lookup time** (§6.5). Initial user: the Somali current |

- **Baked lookup:** `data/maps/currents.png` (§6.5) — index 0 = none,
  indices 1–24 = 8 directions × 3 strengths; overlaps resolved
  strongest-then-id-order; the raster stores each system's **authored
  (stored, non-flipped) vector** — for a reversal system, the non-summer
  regime — and `reversal` is applied at lookup time (runtime and debug
  renderer alike).
- **Consumption:** the speed-modifier and drift formulas, and the
  `control_prefs.current_mode` selection between them, are pinned in
  `20-*` §4.16; the persisted mode lives in `GameState.control_prefs`
  (`90-*` §5.4).

```json
{
  "version": 1,
  "ocean_currents": [
    {
      "id": "somali_current",
      "name": {"zh": "索马里洋流", "en": "Somali Current"},
      "strength": 2,
      "path": [[2.0, 51.0], [8.0, 53.0], [12.0, 55.0]],
      "width_tiles": 5,
      "reversal": {"summer_months": [6, 7, 8, 9], "direction": "reverse"}
    }
  ]
}
```

### 4.18 IceRegion — `data/ice_regions.json` *(Phase 6)*

Envelope `{"version": 1, "ice_regions": [...]}` — the plural key **equals
the file basename**, so validator group 1 needs no exception (§3.2).
Initial locked set: Baltic (months 12–3), Hudson Bay (11–4), White Sea
(11–4); the polygon shapes are authored by Phase-6 task D.

| Field | Type | Rule |
|---|---|---|
| `id` | id | unique |
| `name` | L10nString | |
| `polygon` | [][lat, lon] | closed ring — the first pair is repeated as the last pair (§3.1) |
| `months` | []int | non-empty; each an int 1–12 — the months the polygon's water is frozen |

- **Rule:** in-month, water tiles inside a polygon are impassable to
  **entering** fleets — player, NPC (incl. A\* and lane stepping) alike. A
  tile freezing under a standing fleet does **not** trap it: it may still
  move out. A refused move raises the `world.ice_blocked` toast.
- **Runtime:** a polygon check with a month-keyed tile cache in
  `scripts/world/ocean_layers.gd` (`90-*` §4) — small data, **no raster**.
- **Interaction with lanes:** a lane crossing a seasonal-ice polygon must
  carry a covering `variants` set or avoid ice year-round (§4.14; validator
  group 10, §8.5).
- The permanent `I` band rule (§6.2) is unchanged — seasonal ice only adds
  temporary impassability equatorward of it.

```json
{
  "version": 1,
  "ice_regions": [
    {
      "id": "baltic_ice",
      "name": {"zh": "波罗的海季节海冰", "en": "Baltic seasonal sea ice"},
      "polygon": [[54.0, 10.5], [54.0, 21.0], [60.0, 27.0], [65.5, 24.0], [65.5, 17.0], [60.0, 17.5], [54.0, 10.5]],
      "months": [12, 1, 2, 3]
    }
  ]
}
```

### 4.19 FacilityHours — `data/facility_hours.json` *(added 2026-11-02)*

Port-facility opening hours (`30-*` §4.1b): one **default** window per
facility id plus optional **per-port overrides** — a port without an override
sails on the defaults. Envelope `{"version": 1, "default": {...},
"overrides": {...}}` (a plain object file, like §4.10 `npc_config` — not an
entity list, so validator group 1 does not apply; its check rides in group 7 (check-id `hours`, folded there at the Phase-8 validator implementation — §8 has no dedicated exit row for it).

- A window is `"HH:MM"`–`"HH:MM"` as the two-element array `[open, close]`;
  minutes are `HH×60+MM`, `close` may be `"24:00"` (= minute 1440). The
  special value `"24h"` marks an always-open facility.
- Keys of `default` and of every override are facility ids (`30-*` §4.1:
  market, shipyard, tavern, inn, guild, palace); override keys are port ids
  that must exist in `ports.json`. Every facility id in `30-*` §4.1 must have
  a default window; `inn` ships as `"24h"`.
- **Runtime:** `DataLoader.facility_hours` (loaded at startup, `90-*` §5.2);
  `SailingSim.facility_open(port_id, facility_id)` answers the closed rule
  against `time_of_day_minutes()`.

```json
{
  "version": 1,
  "default": {
    "market": ["08:00", "18:00"],
    "shipyard": ["08:00", "18:00"],
    "tavern": ["10:00", "24:00"],
    "inn": "24h",
    "guild": ["08:00", "18:00"],
    "palace": ["09:00", "17:00"]
  },
  "overrides": {}
}
```

### 4.20 SkillGate — `data/skill_gates.json` *(Phase 8)*

Envelope `{"version": 1, "skill_gates": [...]}` — plural == basename, so
validator group 1 needs no exception. One row per **locked skill/stat gate**
— the Gates column of the `50-*` §2.2 skills table plus every other
gate-pinned feature — so the UI renders each locked feature's reason from
data with one renderer (`80-*`):

| Field | Type | Rule |
|---|---|---|
| `feature_id` | id | unique; names the gated feature as `<system>.<feature>` (e.g. `sail.autopilot`) |
| `name` | L10nString | the gate's display name in the skills view (amended 2026-11-03 — the raw `feature_id` never reaches a label) |
| `stat_or_skill` | id | one of the 5 attributes or the 11 skills (§4.5) |
| `threshold` | int | 1–99; the feature unlocks at `stat ≥ threshold` |
| `reason` | L10nString | the locked, player-visible "why locked" line |

Compound numeric gates (e.g. the two duel-ladder ranks, the two shot types)
are two rows with distinct `feature_id`s. Non-stat halves of a gate (an
officer in post, a facility) are post/facility state, not stats — the
`reason` names them; the behavior lives in the owning system doc.

The **appointed-voyage gate** ships as:

```json
{
  "version": 1,
  "skill_gates": [
    {
      "feature_id": "sail.autopilot",
      "name": {"zh": "委任航行", "en": "Appointed voyage"},
      "stat_or_skill": "navigation",
      "threshold": 40,
      "reason": {"zh": "委任航行需要舵手在位,且航海 ≥ 40。", "en": "An appointed voyage needs a pilot in post with navigation ≥ 40."}
    }
  ]
}
```

(behavior `20-*`; the entry points and HUD `80-*`.)

### 4.21 OfficerPost — `data/officer_posts.json` *(Phase 8)*

Envelope `{"version": 1, "officer_posts": [...]}`. Exactly **7** rows — the
6 flagship functional posts + the per-escort captain seat (`50-*` §4.5;
the post → pipeline table `IMPLEMENT-Phase8.md` §2.7):

| Field | Type | Rule |
|---|---|---|
| `post_id` | id | `pilot` \| `boatswain` \| `gunner` \| `surgeon` \| `carpenter` \| `cook` \| `captain` |
| `slot_type` | enum | `flagship` — one holder on the flagship; `captain` — one per escort ship (the holder's `ship_id` names the ship) |
| `prereq` | object | stat/skill id → minimum value. **Flagship:** the matching skill ≥ 20 — pilot `navigation`, boatswain `seamanship`, gunner `gunnery`, surgeon `medicine`, carpenter `carpentry`, cook `cooking`. **Captain:** `seamanship ≥ 25` ∧ `courage ≥ 30` |
| `desc` | L10nString | the appointment-UI description; the derived-effects line is generated from the same table (`50-*`) |
| `advice` | object | optional; situation id → trigger params — the in-post **advice-event** trigger table (`50-*`: each sea-day tick, 3% per in-post officer, seeded, when the post's threshold is met). The text is pure `ui_strings.json` — `advice.<post_id>.<situation_id>`; the numeric trigger params (5 days, 50%, 40) sit in this table, never in code |

```json
{
  "version": 1,
  "officer_posts": [
    {
      "post_id": "surgeon",
      "slot_type": "flagship",
      "prereq": {"medicine": 20},
      "desc": {"zh": "船医随船,坏血病更晚到来。", "en": "A surgeon aboard delays the scurvy."},
      "advice": {"water_low": {"days": 5}}
    },
    {
      "post_id": "captain",
      "slot_type": "captain",
      "prereq": {"seamanship": 25, "courage": 30},
      "desc": {"zh": "一艘分舰船的船长席位。", "en": "The captain's seat of one escort ship."}
    }
  ]
}
```

The six locked situations — pilot = tomorrow's wind band; surgeon = water
≤ 5 days; boatswain = wrong sail plan in a storm; gunner = first contact
round; carpenter = fleet durability < 50%; cook = morale < 40 — are the
`advice` keys' content.

### 4.22 Background — `data/backgrounds.json` *(Phase 8)*

Envelope `{"version": 1, "backgrounds": [...]}`. Exactly **6** rows — the
locked set of §7.10:

| Field | Type | Rule |
|---|---|---|
| `id` | id | one of the 6 locked ids (§7.10) |
| `name` | L10nString | |
| `attribute_bonus` | object | **exactly one** attribute key → `3` |
| `skill_bonus` | object | **exactly one** skill key → `5` |
| `bio` | L10nString | 1–2 sentences on the creation card |

(The creation flow — background card, then the free-point pool: attributes
+5 and skills +3 in total, per-item cap +3, all points spent — is
`50-*` §4.1; the derived extremes attribute ≤ 21 / skill ≤ 13 fall out of
that section's numbers, not this file's.)

```json
{
  "version": 1,
  "backgrounds": [
    {
      "id": "background_deckhand",
      "name": {"zh": "甲板水手", "en": "Deckhand"},
      "attribute_bonus": {"constitution": 3},
      "skill_bonus": {"seamanship": 5},
      "bio": {"zh": "你在帆缆之间长大,双手比言语更可靠。", "en": "You grew up between mast and deck; your hands speak louder than words."}
    }
  ]
}
```

### 4.23 UILayout — `data/ui_layout.json` *(Phase 12 — rewrites the Phase-11 override table)*

**The data file IS the layout** (`80-*` §4.8.9): every static element's
absolute rect in **tile units** (1 tile = `Palette.CHROME_TILE` = 32 px),
parent-relative — a child's tiles address space is its parent's rect;
top-level elements are screen tiles on the 60 × 33.75 canvas. There are
NO code defaults underneath: a screen's table is the whole truth for its
static elements. **Not an envelope file** — the top level is
`{version, screens}` (`ui_strings.json` pattern with a version key;
group-1 exception). Ships POPULATED (the Phase-12 capture of each
screen's settled look).

- **Top level:** `{"version": 2, "screens": {…}}`. A v1-shaped file
  (top level = the screen map, no `version`) FAILS group 14 — v1
  shipped `{}`, no migration; the file is regenerated by the capture.
- **Screen set (32, locked):** the Phase-11 pilot eight `port`,
  `market`, `provisions`, `shipyard`, `inn`, `guild`, `palace`,
  `tavern`; the title trio `title`, `nationality_select`, `creation`;
  the world family `world` (the sailing HUD), `chart`, `hail`,
  `fleet_picker`, `autopilot_hud`; the combat trio `battle`, `sandbox`,
  `duel`; and the shared/modals `confirm`, `save_slot`, `settings`,
  `intel_window`, `dialog_box`, `dossier`, `character_card`,
  `captain_view`, `fleet_view`, `officer_roster`, `reputation_view`,
  `gameover`, `ending`.
- **`elements`:** element id → rect object. Element ids are
  hierarchical dotted strings `^[a-z0-9_]+(\.[a-z0-9_]+)*$` — static
  segments authored in code, dynamic segments data-derived. **`parent`
  is NOT in the data** — the node tree (authored by the screens' build
  code + `.tscn`) defines nesting; the registry reads it. Dynamic list
  rows (`rows.<good_id>` …) are NOT in `elements` — they belong to the
  screen's list blocks below.

| Key | Type | Meaning |
|---|---|---|
| `x`, `y` | int ≥ 0, tiles | absolute position, parent-relative (px = tiles × 32; point anchors everywhere — nothing is ever stretched) |
| `w`, `h` | int ≥ 0, tiles | size; the runtime applies `max((w,h)·32, content-min quantized up, registered-children extent)` and clamps inside the parent's rect (`80-*` §4.8.9) |
| `sheet` | enum | one of the **7** assignable nine-patch sheets: `panel`, `button`, `button_hover`, `button_pressed`, `button_focus`, `field`, `backdrop` — per-element nine-patch assignment, unchanged from Phase 11 |

- **`lists`:** computed-stacking blocks for the dynamic sections
  (market goods rows, officer rosters, rumor lists …) — list id →
  `{"base": {x,y,w,h}, "row_h": int ≥ 1, "viewport": {x,y,w,h}}`, all
  tiles. Row *i* sits at `(base.x, base.y + i·row_h)` with the row's
  size `(base.w, base.h)`; the viewport is the ScrollContainer's clip
  rect (the ONLY surviving container per screen list — its content node
  is a plain Control sized to the stacked extent; nothing inside it is
  flow-laid).
- **Bounds:** every element rect and list block satisfies
  `x + w ≤ 60` and `y + h ≤ 34` (the 1920×1080 canvas = 60 × 33.75
  tiles; a full-height element's 1080 px measures `roundi` = 34 tiles —
  the 34th row's bottom 8 px are the canvas sliver, clipped, and the
  horizontal 60 is exact). Parent-relative bounds beyond the flat check
  are enforced at runtime (the registry clamps every applied rect
  inside the parent), not statically.
- **The only layout rules** (kept from Phase 11): a child cannot leave
  its parent's rect (clamp on move/resize); a parent cannot shrink
  below its registered children's extent (children-extent floor).
  Everything else is a rect — no flow, no stretch, no separation math.
- **No strings at all** — no i18n rule applies (group 2 skips it).
- **Serialization byte rule:** sorted keys, 2-space indent, trailing
  newline — byte-stable commits (group 14 checks the bytes).
- **Single writer:** the studio writes this file (after an in-process
  validator pass) and the capture tool regenerates it; the game and
  bridge never write it.

```json
{
  "version": 2,
  "screens": {
    "market": {
      "elements": {
        "background":  {"x": 0, "y": 0, "w": 60, "h": 34},
        "header":      {"x": 1, "y": 1, "w": 58, "h": 4},
        "header.back": {"x": 50, "y": 1, "w": 8, "h": 2}
      },
      "lists": {
        "rows": {"base": {"x": 1, "y": 6, "w": 58, "h": 2}, "row_h": 2,
                 "viewport": {"x": 1, "y": 6, "w": 58, "h": 24}}
      }
    }
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

The single source of truth for the grid. Values are the Phase-6 locked
constants — the 4320×2160 rescale of `IMPLEMENT-Phase6.md` §2.0 (the
Phase-4-era values they superseded are that backlog's historical record); no
consumer may derive one differently.

| Constant | Value | Used by |
|---|---|---|
| Grid | `4320 × 2160` tiles | the single world; `20-*`, `60-*`, `80-*`, `90-*` |
| Tiles per degree | `12`; 1 tile = 5′ lat = 5 nm | all distance/speed math |
| Addressing | `lon = x/12 − 180`, `lat = 90 − y/12`; origin top-left, x east, y south | `20-*` §4.1, `90-*` §9 |
| Longitude wrap | on; `x` taken mod 4320 everywhere (movement, BFS, camera, click) | `20-*` §4.1, `80-*` §4.5, validator group 6 |
| Latitude edges | impassable (ice band, below) | `20-*` §4.1 |
| `TILE_SIZE_PX` | `32` (unchanged) | TileMap config, `80-*` §4.5 |
| Coastal band | `.` iff within 6 tiles (Chebyshev, wrap-aware) of a passable-adjacent land/ice tile, else `~`; `.` is cosmetic only (same passability/speed as `~`) — the 6-tile band keeps the shallow-water band at 30 nm | `tools/build_world.py`, renderer |
| Harbor snap | berth tile within 2 tiles (Chebyshev) of `Port.lat/lon`, on water, with ≥ 1 orthogonally adjacent water tile; equidistant candidates tie-break to the smallest `(y, x)` — the Python builder and the GDScript runtime implement this rule exactly and the validator tests they agree. **Unchanged at 2 tiles** (derivation-accuracy class: the tile count is kept and its nm accuracy improves at 5 nm — see the enumeration below) | `10-*` §7.1, `tools/build_world.py`, `90-*` §9 |
| Harbor pair | every port has a **shore tile**: the nearest `#` tile orthogonally adjacent to its berth, tie-break smallest `(y, x)`. The shore tile is the port's visible location and the docking target; the berth is where the fleet stands (`20-*` §4.11.1). Both are derived, never stored. The pair constraint is part of the berth snap: a water candidate with no orthogonally adjacent `#` is skipped, so the berth is the nearest candidate satisfying **both** rules | `20-*` §4.11.1, `90-*` §9, validator group 6 |
| Port sighting | `48 tiles` (≈ 4° ≈ 240 nm) | `20-*` §4.11 |
| Discovery sighting | `36 tiles` (≈ 3°) | `70-*` §4.4 |
| Ship speeds | base speeds `{16, 20, 24}` tiles/day on 5 nm tiles = 80–120 nm/day (unchanged); floor 1 tile/day unchanged; fleet = slowest hull, unchanged | `40-*` §4.2, `data/ship_types.json` |
| Weather zones | 5 latitude bands (§6.4) | `20-*` §4.7 |
| Map artifact | `data/maps/world.png` — indexed-color PNG, 4320×2160, 1 px = 1 tile, palette index 0–4 = `~ . # ^ I` | §6.3, `tools/build_world.py` |
| Ocean rasters | `data/maps/wind_regions.png` + `data/maps/currents.png` — indexed-color PNGs, 4320×2160, 1 px = 1 tile, own palette encodings | §6.5, `tools/build_ocean.py` |
| Distance raster | `data/maps/dist_land.png` — RGB8 PNG, 4320×2160, 1 texel = 1 tile; per-tile Euclidean distance to land encoded `round(min(d,16)/16*65535)` across R/G — the water shader's pixel-depth factor source | §6.7, `tools/build_distance_field.py` |
| Palette policy | append-only: indices 0–4 = `~ . # ^ I` are locked; indices ≥ 5 are reserved for future cosmetic/seasonal layers and never carry simulation semantics. The §6.5 ocean rasters are **separate files with their own palettes** — they do not use or extend this one | §6.3, §6.5 |
| Lakes | `ne_10m_lakes` polygons rasterized as `#` (land for all purposes; the Caspian is land) | `tools/build_world.py` |
| Map index | `data/maps/maps.json` exactly one entry, `id: "world"` | `90-*` §9.1 |
| Save | version 9; no migration chain — v8 and older payloads refused | `90-*` §8.1–8.2 |
| Port schema | `lat`, `lon` (WGS84 degrees, truth); the `marker`, `position`, and `phase` keys and the retired world-map marker block are removed; `ports.json` holds the 105 sovereign ports plus the Phase-6 neutral tier; Phase 7 adds `band`/`protected`/`dev`/`sphere` and the list-form `shipyard`/`equipment_stock` (§4.4) | §4.4, §7.1 |

**Projection.** The grid is the whole globe at 12 tiles/degree: it spans
180°W–180°E and 90°N–90°S, and circumnavigation is a first-class feature
(`x = 0` and `x = 4319` are neighbours). No Mercator: a uniform grid is
load-bearing for the engine; display projection is a render concern only.

**Phase-6 rescale enumeration (ratified from `IMPLEMENT-Phase6.md` §2.0).**
Every tile-domain pin is classified into one of three sweep classes; the
gameplay semantics live in their owning system docs (`20-*`, `40-*`,
`60-*`, `80-*`), which re-pin these same values:

- **Physical (nm semantics preserved; tiles ×2):** `ShipType.speed`
  `{16, 20, 24}` tiles/day (80–120 nm/day unchanged); port sighting
  24 → **48** tiles (≈ 240 nm); discovery sighting 18 → **36**; trader
  decision range 60 → **120**; escort radius 10 → **20**; coastal band
  3 → **6** tiles (cosmetic 30 nm shallow-water band, nm preserved).
- **Derivation accuracy (tile count kept — nm accuracy improves):**
  harbor snap ≤ **2** (unchanged); lane waypoint snap ≤ **2** (unchanged);
  `world_report.json` component-list threshold **2000** tiles
  (informational diagnostic, unchanged).
- **Gameplay (default ×2; re-tunable only per `00-*` §11):** patrol zone
  15 → **30**; chokepoint anchor 3 → **6**; pirate hysteresis 5/8 →
  **10/16**; hunter hysteresis 15/20 → **30/40** (`60-*` §4.11.11.1);
  lane spoke 20 → **40**; lane stepping base 1 → **2** tiles/day; current
  drift rates **0.5 / 2 / 4** tiles/day at 5 nm (currents strengths 1/2/3;
  `20-*` §4.16).

Seam and code pins of the same sweep:

- **Combat seam:** `battle_mp(speed) = speed / 4` — battle pacing preserved
  exactly a second time (the Phase-4 pin pattern repeated; `60-*` §4.2).
- **A\*:** the shipped two-stage `sail_path.gd` is kept — near stage
  `NEAR_REGION_TILES` 256 / `REGION_MARGIN` 24, `BUDGET_MS` 1000 — and
  re-benchmarked at 4320²; the 1 s budget and the pinned escape hatch stand.
- **Minimap/chart:** the 256×192 px box and the 128×96-tile crop at 2 px/tile
  are unchanged; the chart downscales as today; the explored bitset grows to
  **9,331,200 bytes (~9.3 MB)** — session-only, not saved.
- **Width-derived code sites:** `npc_fleets.gd`'s hardcoded `_width`/
  `_height`, the cell-key packing `cell.y * 4096 + posmod(cell.x, 4096)`,
  the `_bucket_index` stride, and `buckets_x` all become **width-derived**
  (they break outright at `x > 4095` on the old packing); `world_map.gd`'s
  seam double-draw moves to `x = 4320`; `sail_path.gd`'s `short_dx` default
  width becomes **4320**.

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

- **Format:** indexed-color (palette) PNG, exactly 4320 × 2160 pixels,
  1 px = 1 tile. Palette indices 0–4 correspond to `~ . # ^ I` in that order.
- **Append-only palette policy:** indices 0–4 are locked and their meanings may
  never change. Indices ≥ 5 are reserved for future cosmetic/seasonal layers
  (relief, biomes, seasonal ice) and never carry simulation semantics; adding
  one is a render-only change. The Phase-6 ocean rasters
  (`data/maps/wind_regions.png` / `data/maps/currents.png`, §6.5) are
  **separate files with their own palettes** — they do not use or extend this
  palette.
- **Loader contract:** read with `FileAccess` +
  `Image.load_png_from_buffer`. The PNG is **data**, not an imported texture —
  no Godot import pipeline, and the placeholder-art rule
  (`docs/80-UI-UX.md` §4.8) is unaffected.
- **Provenance:** generated by `tools/build_world.py` from public-domain
  shorelines (`tools/assets/`) plus `tools/map_overrides.json`; never
  hand-edited. ASCII is a debug export only (`build_world.py --ascii`):
  never shipped, never hand-edited, not a data source.
- **2026-11-06 amendment — the §6.2 coast-cleanup pass (canonical).** After
  the override carves and before harbor snapping, `build_world.py` runs
  `pass_coast_cleanup`: every land cell with water on **3 or 4 orthogonal
  sides**, or on an **opposite pair** (N+S / E+W), is deleted to open sea —
  iterated to fixpoint (a deletion can expose a new violation next door;
  the loop runs until a full scan deletes nothing, verified by a strict
  rescan recorded in `world_report.json#build.coast_cleanup
  .strict_violations_remaining`, which must be 0 or the build fails).
  "Water" here is **every non-land palette** (`~ . ^ I`) plus off-grid
  rows — reef and polar ice render as water, so they count. The shape
  family this removes (one-cell tips, single-pixel islands, one-cell
  strips with two opposite beaches, ice-ringed shards) is exactly what no
  corner-Wang tile can paint (§4.8 in `80-UI-UX.md`). Ports the cleanup
  strands get a violation-free 2×2 land block **restored at the port's
  pre-cleanup shore location** (`port_block_widening` in the report) —
  never at the bare port tile, which once stamped land onto the
  `basra_muscat_india` lane. Derived artifacts are regenerated in the
  same change: `dist_land.png` (§6.7), `wind_regions.png` /
  `currents.png` (§6.5), `world_shore.png` (§6.6), and
  `trade_routes_built.json` (§4.14 — the cleanup re-opens spoke walks, so
  superseded §4.14 overrides are removed from `tools/route_overrides.json`
  by the builder's own invariant).
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

**Phase-10 amendment — the tool-owned generated-artifact family.** Two new
outputs join this file and the §6.5 rasters in the never-hand-edit family:
`assets/ui/` (every generated UI-art PNG, written only by
`tools/build_ui_art.py` from the `tools/ui_art/<class>/` manifests) and
`data/maps/world_shore.png` (§6.6, written only by `tools/build_shore.py`
from `world.png`). Same rules as above: **never hand-edited**; two
consecutive builds **byte-identical** (validator group 13, §8.8 — the
double-run is also the hand-edit detector); a style fix edits the owning
tool's sources/manifests and rebuilds, never a single PNG. The
`assets/ui/*.import` files are committed once by the master
`godot --headless --import` pass (nearest-neighbour import,
`IMPLEMENT-Phase10.md` decision 5); the map rasters themselves stay data
artifacts with no Godot import pipeline (the loader contract above).

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
(`1 − 0.65⁶ = 0.9246`). Tenerife is a **coordinate destination** — the
sovereign 100-port list has no Canaries port and none is added; arrival means
crossing the 30°N band edge and sampling weather there, not docking.

### 6.5 Ocean rasters — `data/maps/wind_regions.png` + `data/maps/currents.png` *(Phase 6)*

Two tool-owned lookup rasters bake the §4.16 wind regions and the §4.17
currents to O(1) runtime reads (`scripts/world/ocean_layers.gd`, `90-*` §4):

- **Format (both files):** indexed-color (palette) PNG, color type 3, exactly
  4320 × 2160 pixels — 1 px = 1 tile at the §6.1 grid.
- **`wind_regions.png` — palette index = region id.** Index 0 = unassigned
  water → the `VAR` + `variable` fallback (`20-*` §4.14); indices `1..N` are
  the regions of `data/wind_regions.json` in file order. The palette holds
  ≤ 1 + 25 entries (§4.16's 15–25 regions).
- **`currents.png` — index 0 = no current; indices 1–24 = 8 directions × 3
  strengths,** encoded as `index = dir_index × 3 + strength` with `dir_index`
  0–7 over the compass order `N NE E SE S SW W NW` and `strength` 1–3
  (so `N`/1 = 1 … `NW`/3 = 24). A tile's index decodes to a unit direction +
  strength; the `20-*` §4.16 modifier/drift formulas consume the decoded
  vector. **Per-tile direction (pinned at the W3 gate):** a corridor tile
  takes its **segment's dominant compass direction** — a bending system
  paints per-segment bearings, not one system-wide bearing.
- **Overlap rules:** currents — a tile covered by several systems takes the
  **strongest** system's vector; strength ties go to the system earliest in
  `data/ocean_currents.json` file (id) order — "strongest-then-id-order",
  deterministic. Wind regions — authored regions are **disjoint**; should any
  overlap, the region **earliest in file order wins** (the builder paints in
  file order and reports the overlap count; the shipped sources overlap on
  exactly 0 tiles).
- **VAR fallback is an expected state (W3 pin):** stray water tiles outside
  every wind polygon (shipped: 614 tiles, 0.013% — e.g. the Gulf of Alaska
  margin) decode to index 0 → `VAR` + `variable`; the §4.16 "tile all ocean"
  wording is the authoring target, not a validator gate (group 9 checks
  palette bounds, not totality).
- **JSON structure ownership (W3 pin):** group 9 owns the two ocean JSON
  files' structural basics — unique ids matching the regex and complete
  L10nString names; the month tables (`"1"…"12"` → compass token) and
  `reversal` shape are authored data self-checked at authoring time (task D)
  and exercised at runtime by task F's determinism tests.
- **Variants and the junction graph (W3 pin):** lane `variants` are **not**
  junction-graph members — the graph stays month-blind (base lanes + spokes);
  each variant's tile path is carried on its lane in the built artifact and
  the runtime selects the in-month path for stepping (`60-*` §4.11.11
  amendment).
- **`months` arrays (W3 pin):** an ice region's or variant's `months` array
  has **no ordering requirement** — duplicate-free ints 1–12 (the shipped
  Baltic entry is cyclic: `[12, 1, 2, 3]`).
- **Reversal at lookup (pinned):** the raster stores the system's
  **stored (non-flipped)** vector — for a reversal system the **non-summer
  regime**, so the flip yields the real summer jet; a system's
  `reversal.summer_months` flips the decoded vector **at
  lookup time** — runtime and debug renderer apply the same one-line flip
  (§4.17). One static PNG, seasonal Somali.
- **Governance — same standing as `world.png` (§6.3):** written only by
  `tools/build_ocean.py`, **never hand-edited**; two consecutive builds are
  **byte-identical** (validator group 9, §8.4 re-asserts it); `--ascii` and
  `--report` are debug exports only — never shipped, never hand-edited, not
  data sources. The rasters do **not** use `world.png`'s 5-colour palette:
  their palettes encode ids/vectors per the rules above.
- **Session-only:** decoded once at load; never saved (§6.5 state is data,
  not save state). Ice regions are **not** rasterized — §4.18 stays a runtime
  polygon check with a month-keyed tile cache.

### 6.6 Shore-edge raster — `data/maps/world_shore.png` *(Phase 10)*

One tool-owned lookup raster bakes the water→land boundary into per-tile
edge codes, so the shore overlay is a pure decode at load (`90-*` §4;
consumed by `scripts/world/map_loader.gd`'s overlay TileMap layer):

- **Format:** indexed-color (palette) PNG, color type 3, exactly
  4320 × 2160 pixels — 1 px = 1 tile at the §6.1 grid. Generated by
  `tools/build_shore.py` from `data/maps/world.png` alone.
- **Palette encoding (pinned):** index 0 = no edge; indices 1–8 are the
  edge codes `n, ne, e, se, s, sw, w, nw` — the §6.5 currents compass
  order, and also the **priority order** (`n > ne > e > se > s > sw > w >
  nw`). A water tile (`~` or `.`) whose neighbour in direction *d*
  (8-neighborhood, `x` wrap-aware per §6.1) is land (`#`), reef (`^`) or
  ice (`I`) carries that direction's code; a tile qualifying for several
  directions takes the **highest-priority** one. A neighbour with `y` out
  of range counts as **non-land** — it yields no code (in practice
  unreachable: the `y` edges are the locked §6.2 ice band, so no water
  tile sits there). Land, reef and ice tiles are **always 0** — the
  raster codes water only.
- **Cosmetic only:** the overlay changes rendering, never semantics —
  passability, speed and the `sea` vs `coastal_sea` distinction keep
  following the `world.png` indices (§6.2/§6.3), exactly like the §6.1
  coastal band.
- **Consumers:** `map_loader.gd`'s overlay TileMap layer maps each code
  to its `shore_{dir}.png` strip (`IMPLEMENT-Phase10.md` A.6); decoded
  once at load, never saved — session-only state, like the §6.5 rasters.
- **Governance — the §6.3 amendment family:** written only by
  `tools/build_shore.py`, **never hand-edited**; two consecutive builds
  are **byte-identical** (validator group 13 item 9, §8.8); an ASCII
  export is a debug output only — never shipped, never hand-edited, not
  a data source.

### 6.7 Land-distance raster — `data/maps/dist_land.png` *(2026-11-06)*

One tool-owned raster carries the per-tile Euclidean distance to land —
the factor source of the water shader's pixel-depth darkening (`80-*`
§4.8 2026-11-06: every pure-water pixel darkens continuously with its own
distance; the user direction "pixel level of darker, not tile level"):

- **Format:** RGB8 (colour type 2) PNG, exactly 4320 × 2160 pixels — one
  texel per tile of the §6.1 grid. Generated by
  `tools/build_distance_field.py` from `data/maps/world.png` alone (the
  §6.3 land index 2), with an exact Felzenszwalb–Huttenlocher EDT computed
  on a 3× horizontally tiled mask so distances across the dateline are
  exact (the world is a cylinder; `x` wraps, `y` does not — off-map `y`
  reads open water).
- **Encoding (pinned):** `enc = round(min(d, 16) / 16 * 65535)`, then
  `R = enc >> 8`, `G = enc & 255`, `B = 0`; decode
  `d = (R * 256 + G) / 4096` tiles — 1/4096-tile precision, saturated at
  16 (the factor curve's deep end is 10, so saturation never touches the
  ramp). The shader decodes with linear filtering, which makes the field
  continuous at world scale.
- **Render-only:** like the §6.5 rasters, this file changes rendering
  never semantics — passability, speed and the `sea`/`coastal_sea`
  distinction keep following the `world.png` indices.
- **Consumers:** the water shader via `water_layer.gd`
  (`u_dist_tex`; world chunks only — the S10 battle grid disables the
  amendment). Decoded once per process through the raw-bytes
  DATA-ARTIFACT pattern; session-only, never saved.
- **Governance — the §6.3 amendment family:** written only by
  `tools/build_distance_field.py`, **never hand-edited**. Determinism is
  two-gated: every validation pass runs the **sampled-probe audit**
  (validator group 9: decode, encode bounds, land pixels exactly 0, and a
  fixed-stride probe sample vs the true Euclidean distance — the
  expensive-re-derivation rule forbids re-running the whole EDT per
  pass), and the **full byte-identical double-run** is
  `tools/build_distance_field.py --check` (an acceptance-time gate; the
  2026-11-06 acceptance run reported `--check OK: rebuild
  byte-identical`).

## 7. Locked Content Lists

Exhaustive — no additions or removals without amending this doc.

### 7.1 Ports (105 sovereign + Phase-6 neutral tier)

The **sovereign set** — exactly the 100 ids below — lives in the single
`data/ports.json` envelope and is **locked and untouched** (exact-set, validator
group 5). `lat`/`lon` are WGS84 degrees (the geographic truth); the harbor pair
is derived by §6.1's projection + harbor-snap rule, never hand-placed. Nations
from §7.4. Ordering is the file order: the original 30 Mediterranean/Atlantic
ports first, then the 70 world-expansion ports.

**Neutral tier (Phase 6, `IMPLEMENT-Phase6.md` §2.11).** `data/ports.json` may
additionally hold **40–60 neutral ports** with `nation_id: ""`, appended after
the sovereign block:

- era-appropriate, cited historical names, zh and en both required;
- `produces`/`demands` over the **existing 20 goods** — no new goods (the
  5/10/5 consumption-tier split stays validator-asserted, §8.2)
  **(superseded Phase 7)**: task P rewrites every port's
  `produces`/`demands` over the 40 goods of §7.2 under the §8.2 rules —
  this line's 20-good scope is the Phase-6 history only;
- facilities are data-driven per port; default `market + inn + tavern`,
  `shipyard` only where authored;
- minimal now-semantics: the market works as-is off the port's
  produces/demands; **no NPC fleet serves a neutral port this phase**
  (player-only frontier markets; amended Phase 7 — nationless coasters serve
  every neutral port and lane traders dock at ports aligned to their nation,
  `IMPLEMENT-Phase7.md` §2.7 and `30-*` §4.9); zero budget churn; **a neutral
  port can
  never close**; lane spoke to the nearest lane waypoint within **40** tiles,
  nationless fallback = nearest lane waypoint unbounded (§4.14);
- ids are appended by Phase-6 task P and recorded in this § after authoring.

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
| botany_bay | 鲨鱼湾 | Shark Bay | holland | -25.50 | 113.50 | salt, dried_fish | timber, iron |
| siam | 暹罗 | Siam | portugal | 13.50 | 100.58 | timber, ceramics | glassware, wool |
| cadiz | 加的斯 | Cadiz | spain | 36.53 | -6.29 | salt, wine | spices, timber |
| oporto | 波尔图 | Oporto | portugal | 41.14 | -8.68 | wine, leather | spices, glassware |
| plymouth | 普利茅斯 | Plymouth | england | 50.37 | -4.14 | dried_fish, wool | wine, spices |
| bergen | 卑尔根 | Bergen | holland | 60.39 | 5.32 | dried_fish, timber | wine, salt |
| danzig | 但泽 | Danzig | holland | 54.40 | 18.68 | timber, amber | wine, salt |
| stockholm | 斯德哥尔摩 | Stockholm | holland | 59.32 | 18.10 | copper, iron | wine, salt |
| trieste | 的里雅斯特 | Trieste | italy | 45.65 | 13.77 | glassware, timber | spices, sugar |
| corfu | 科孚 | Corfu | italy | 39.62 | 19.92 | olive_oil, salt | wine, timber |
| santa_cruz | 圣克鲁斯 | Santa Cruz de Tenerife | spain | 28.47 | -16.25 | wine, sugar | wheat, olive_oil, wool, salt, dried_fish, timber, iron, cheese, rice, pitch, glassware, linen |
| reykjavik | 雷克雅未克 | Reykjavik | holland | 64.15 | -21.94 | dried_fish, wool | wheat, olive_oil, wine, sugar, salt, timber, iron, cheese, rice, pitch, glassware, linen |
| praia | 普拉亚 | Praia | portugal | 14.92 | -23.51 | salt, cotton_cloth | wheat, olive_oil, wine, wool, sugar, dried_fish, timber, iron, cheese, rice, pitch, glassware, linen |
| benguela | 本格拉 | Benguela | portugal | -12.58 | 13.41 | amber, leather, salt | wheat, olive_oil, wine, wool, sugar, dried_fish, timber, iron, cheese, rice, pitch, cotton_cloth, glassware |
| caffa | 卡法 | Caffa | italy | 45.03 | 35.38 | wheat, salt, leather | olive_oil, wine, wool, sugar, dried_fish, timber, iron, cheese, rice, pitch, glassware, linen, silk |

Historical fidelity is deliberately loose (e.g., French-coast ports assigned
to Spain, Mediterranean islands split between Italy and the Ottomans, and the
world-expansion ports' nation assignments) to keep the 6-nation model closed;
do not "fix" assignments without amending this doc.

**`botany_bay` amendment (Phase 6 task P, master-pinned; 2026-10-31).** The id
is locked, but the 1770 Cook naming breaks the phase's ~1550–1620s anchor:
the row above is re-placed to Shark Bay, Western Australia (−25.50, 113.50),
display name 鲨鱼湾 / Shark Bay, `nation_id` england → **holland** (Dirck
Hartog's 1616 Dutch landfall — the id/display mismatch is covered by the
deliberate-fidelity note above), produces salt + dried_fish, demands timber +
iron. Nothing else about the sovereign 100 changes.

#### Phase-6 neutral tier (task P, 2026-10-31)

Exactly the 45 neutral ports below, appended after the sovereign block in
`data/ports.json` (count within the 40–60 lock; exact-set enforced by
validator group 5 after task E's amendment). All rows carry `nation_id: ""`,
zh/en names, flavor, and the default facilities `market + tavern + inn`
(`guild`/`palace` omitted — Phase-3 facilities); `shipyard` is authored on
exactly four rows (quanzhou, hirado, sakai, gresik) — the `funai` row
carries no shipyard (data is ground truth; the former "five rows incl.
funai" wording was stale). Ordering is the
file order.

| id | zh | en | Nation | lat | lon | produces | demands |
|---|---|---|---|---|---|---|---|
| quanzhou | 泉州 | Quanzhou (Zayton) | — | 24.85 | 118.72 | silk, ceramics | spices, timber |
| ningbo | 宁波 | Ningbo | — | 29.95 | 121.70 | ceramics, silk | spices, timber |
| yuegang | 月港 | Yuegang (Zhangzhou) | — | 24.42 | 117.98 | silk, sugar | spices, timber |
| shuangyu | 双屿 | Shuangyu | — | 29.74 | 122.22 | dried_fish, salt | silk, spices |
| nanao | 南澳 | Nan'ao | — | 23.40 | 117.20 | salt, dried_fish | silk, timber |
| xiamen | 厦门 | Xiamen (Amoy) | — | 24.44 | 118.13 | silk, sugar | spices, timber |
| fuzhou | 福州 | Fuzhou | — | 26.02 | 119.65 | timber, silk | spices, salt |
| wenzhou | 温州 | Wenzhou | — | 27.97 | 120.68 | ceramics, dried_fish | silk, timber |
| zhelin | 柘林 | Zhelin (Chaozhou) | — | 23.62 | 117.13 | sugar, timber | silk, spices |
| qiongzhou | 琼州 | Qiongzhou (Hainan) | — | 20.03 | 110.33 | timber, leather | salt, silk |
| beihai | 北海 | Beihai (Hepu) | — | 21.48 | 109.12 | salt, timber | silk, cotton_cloth |
| dinghai | 定海 | Dinghai (Zhoushan) | — | 30.01 | 122.11 | dried_fish, salt | silk, spices |
| liujiagang | 刘家港 | Liujiagang (Taicang) | — | 31.50 | 121.55 | cotton_cloth, dried_fish | silk, timber |
| hirado | 平户 | Hirado | — | 33.25 | 129.56 | copper, ceramics | silk, spices |
| sakai | 堺 | Sakai | — | 34.50 | 135.42 | cotton_cloth, leather | silk, spices |
| yamagawa | 山川 | Yamagawa (Satsuma) | — | 31.10 | 130.58 | timber, dried_fish | silk, cotton_cloth |
| hakata | 博多 | Hakata | — | 33.59 | 130.39 | dried_fish, timber | silk, ceramics |
| funai | 丰后府内 | Bungo-Funai (Ōita) | — | 33.24 | 131.61 | dried_fish, timber | silk, glassware |
| urado | 浦户 | Urado (Tosa) | — | 33.50 | 133.55 | timber, dried_fish | silk, salt |
| anotsu | 安浓津 | Anotsu (Ise) | — | 34.60 | 136.70 | dried_fish, timber | silk, ceramics |
| busan | 釜山 | Busan (Pusan) | — | 35.10 | 129.04 | dried_fish, salt | silk, ceramics |
| yeompo | 盐浦 | Yeompo | — | 35.50 | 129.43 | salt, dried_fish | cotton_cloth, silk |
| hoi_an | 会安 | Hoi An (Faifo) | — | 15.90 | 108.34 | silk, ceramics | spices, cotton_cloth |
| banten | 万丹 | Banten | — | -5.85 | 105.95 | spices, salt | cotton_cloth, ceramics |
| jambi | 占碑 | Jambi | — | -1.12 | 103.80 | spices, timber | cotton_cloth, salt |
| palembang | 巨港 | Palembang | — | -2.25 | 104.85 | spices, timber | cotton_cloth, salt |
| gresik | 革儿昔 | Gresik (Surabaya) | — | -7.05 | 113.35 | salt, timber | spices, silk |
| sulu | 苏禄 | Sulu (Jolo) | — | 5.98 | 120.98 | timber, dried_fish | ceramics, cotton_cloth |
| kedah | 吉打 | Kedah | — | 6.10 | 100.32 | salt, timber | cotton_cloth, spices |
| nagapattinam | 内加帕塔姆 | Nagapattinam | — | 10.76 | 79.85 | cotton_cloth, salt | spices, ceramics |
| masulipatnam | 马苏利帕特南 | Masulipatnam | — | 16.10 | 81.12 | cotton_cloth, leather | spices, copper |
| hughli | 胡格利 | Hughli (Bengal) | — | 21.65 | 88.05 | silk, sugar | spices, timber |
| syriam | 沙廉 | Syriam (Pegu) | — | 16.60 | 96.28 | timber, salt | copper, cotton_cloth |
| dianga | 迪昂 | Dianga (Arakan) | — | 18.40 | 94.30 | dried_fish, timber | cotton_cloth, spices |
| khambhat | 坎贝 | Cambay (Khambhat) | — | 21.70 | 72.55 | cotton_cloth, leather | spices, copper |
| diu | 第乌 | Diu | — | 20.69 | 70.97 | salt, cotton_cloth | timber, wine |
| mocha | 摩卡 | Mocha | — | 13.30 | 43.22 | leather, salt | cotton_cloth, spices |
| qalhat | 哈尔哈特 | Qalhat | — | 22.68 | 59.80 | dried_fish, leather | cotton_cloth, spices |
| hormuz | 霍尔木兹 | Hormuz | — | 26.62 | 56.43 | carpet, salt | cotton_cloth, spices |
| zanzibar | 桑给巴尔 | Zanzibar | — | -6.05 | 38.92 | timber, dried_fish | cotton_cloth, glassware |
| kilwa | 基尔瓦 | Kilwa | — | -8.96 | 39.50 | salt, timber | cotton_cloth, glassware |
| sofala | 索法拉 | Sofala | — | -19.60 | 35.25 | amber, salt | cotton_cloth, ceramics |
| lamu | 拉穆 | Lamu | — | -2.30 | 40.60 | timber, dried_fish | cotton_cloth, spices |
| massawa | 马萨瓦 | Massawa | — | 15.60 | 39.45 | salt, leather | cotton_cloth, iron |
| zeila | 泽拉 | Zeila | — | 11.35 | 43.47 | salt, dried_fish | cotton_cloth, wool |

Band allocation: China coast 13 (quanzhou … liujiagang), Japan 7 (hirado …
anotsu), Korea 2 (busan, yeompo), sovereign SE Asia 7 (hoi_an … kedah),
Mughal India/Persia/Arabia 10 (nagapattinam … hormuz), Swahili/Red Sea 6
(zanzibar … zeila).

#### Port region bands (Phase 7)

The **band id set** is a locked container defined here; task P authors its
members (the §4.4 `band` field references it). Rules:

- Ids follow the §3.1 `id` regex (snake_case); every band id is unique.
- The set **partitions all 150 ports**: every port's `band` ∈ the set, and
  the validator asserts membership (§8.2) plus that no band id goes unused.
- The set is a **superset of the six Phase-6 neutral-region bands** above —
  skeleton ids `china_coast`, `japan`, `korea`, `southeast_asia`,
  `india_persia_arabia`, `swahili_red_sea` (P may finalize exact id wording;
  the six regions themselves are locked by the allocation paragraph above) —
  plus bands covering the remaining sovereign ports (Europe, Africa's
  Atlantic coast, the New World).
- A band containing at least one `nation_id: ""` port is a **neutral
  band**; the §8.2 checks keyed on bands (≥ 2 staple producers per band,
  ≥ 1 exclusive good produced per neutral band, tavern telegraph scoping)
  use this field.
- The final member list is recorded in this subsection after task P
  authors it (same protocol as the §7.1 neutral-tier table).

**Band members (final, task P, 2026-11-02).** Exactly the 15 band ids
below partition all 150 ports (member ids in file order); the first six
are the locked Phase-6 neutral-region regions. No further band id may be
added without amending this table.

| band id | ports | members |
|---|---|---|
| europe_atlantic | 14 | lisbon oporto seville cadiz bordeaux london plymouth amsterdam antwerp hamburg bergen danzig stockholm reykjavik |
| europe_med | 18 | marseille valencia barcelona genoa naples palermo syracuse cagliari valetta venice trieste ragusa corfu athens istanbul smyrna candia caffa |
| africa_levant | 8 | ceuta safi algiers tunis tripoli alexandria beirut cyprus |
| africa_atlantic | 8 | saint_louis elmina accra luanda madeira santa_cruz praia benguela |
| swahili_red_sea | 10 | mozambique mombasa suakin mogadishu zanzibar kilwa sofala lamu massawa zeila |
| india_persia_arabia | 22 | aden jiddah muscat basra bandar_abbas goa calicut cochin bombay surat colombo pondicherry nagapattinam masulipatnam hughli syriam dianga khambhat diu mocha qalhat hormuz |
| southeast_asia | 17 | malacca batavia macassar amboina manila patani brunei ternate timor siam hoi_an banten jambi palembang gresik sulu kedah |
| china_coast | 16 | macau canton zeelandia quanzhou ningbo yuegang shuangyu nanao xiamen fuzhou wenzhou zhelin qiongzhou beihai dinghai liujiagang |
| japan | 9 | nagasaki osaka hirado sakai yamagawa hakata funai urado anotsu |
| korea | 2 | busan yeompo |
| americas_north | 6 | boston new_york jamestown charleston new_foundland quebec |
| americas_caribbean | 8 | havana san_juan santo_domingo curacao suriname cartagena portobelo vera_cruz |
| americas_pacific | 5 | acapulco panama guayaquil lima valparaiso |
| americas_brazil | 5 | bahia rio_de_janeiro recife belem buenos_aires |
| indian_ocean_south | 2 | cape_town botany_bay |

Neutral bands (contain `nation_id: ""` ports): swahili_red_sea,
india_persia_arabia, southeast_asia, china_coast, japan, korea — the six
Phase-6 regions, unchanged. Banding rationale (Atlantic/Baltic split, the
Brouwer-route `indian_ocean_south` pair, `africa_levant` naming, and
`botany_bay`'s placement) is in `LICENSE-NOTES.md` ("Phase 7 region
bands").

**Port classes & dev floors (final, task P, 2026-11-02).** `protected:
true` on exactly the decision-25 core set — portugal {lisbon, oporto},
spain {seville, cadiz, valencia, barcelona}, england {london, plymouth},
holland {amsterdam, antwerp}, ottoman {istanbul, athens, smyrna}, italy
{venice, genoa, naples, palermo} — 17 ports, ⊇ the 6 capitals, ≤ 4 per
nation. Authored `dev` floors: protected `3`; the 29 sovereign
contestable majors `2` — aden alexandria bahia basra batavia calicut
canton cartagena colombo danzig goa hamburg havana jiddah luanda macau
malacca manila marseille mombasa mozambique nagasaki osaka panama recife
stockholm surat vera_cruz zeelandia (historical rationale per port in
`LICENSE-NOTES.md`); all other sovereign contestable ports `1`; all 45
neutral ports `0`.

### 7.2 Goods (40, Phase 7)

The schema (the `staple`/`specialty`/`exclusive`/`flow` fields and the
flag-driven tier rule) is §4.2; this section locks the **40-id list**. The
original 20 keep their zh/en names and `base_price` (prices locked; the
Phase-7 task adds tier flags — no other value changes). The 20 new ids
complete the list; their zh/en display names and `base_price` values are
**task-owned by G** — the zh/en below are skeleton suggestions. Tier
columns are the A-pinned skeleton: G finalizes members within the locked
12/16/12 split (validator §8.2).

**Existing 20 — tier skeleton (assigned):**

| id | zh | en | category | base_price | tier |
|---|---|---|---|---|---|
| wheat | 小麦 | Wheat | food | 8 | staple |
| salt | 盐 | Salt | food | 12 | staple |
| dried_fish | 鱼干 | Dried Fish | food | 10 | staple |
| timber | 木材 | Timber | material | 15 | staple |
| cheese | 奶酪 | Cheese | food | 16 | staple |
| wool | 羊毛 | Wool | textile | 18 | staple |
| olive_oil | 橄榄油 | Olive Oil | food | 22 | staple |
| wine | 葡萄酒 | Wine | food | 30 | staple |
| sugar | 糖 | Sugar | food | 40 | staple |
| iron | 铁 | Iron | material | 35 | staple |
| cotton_cloth | 棉布 | Cotton Cloth | textile | 45 | middle |
| ceramics | 陶瓷 | Ceramics | material | 25 | middle |
| leather | 皮革 | Leather | material | 28 | middle |
| copper | 铜 | Copper | material | 50 | middle |
| glassware | 玻璃器皿 | Glassware | luxury | 60 | middle |
| silk | 丝绸 | Silk | textile | 120 | luxury |
| spices | 香料 | Spices | luxury | 150 | luxury |
| carpet | 地毯 | Carpet | textile | 80 | luxury |
| perfume | 香水 | Perfume | luxury | 90 | luxury |
| amber | 琥珀 | Amber | luxury | 110 | luxury |

**Phase-7 skeleton — the 20 new ids** (the 15 backlog-named ids are the
fixed core; the 5 era fillers `rice`/`pitch`/`linen`/`furs`/`ivory` G may
substitute era-appropriately, keeping the 40 total — era anchor
~1550–1620; ids snake_case):

| id | zh (skeleton) | en (skeleton) | tier | era note |
|---|---|---|---|---|
| rice | 稻米 | Rice | staple | the Asian staple grain |
| pitch | 沥青 | Pitch | staple | naval stores (tar/pitch) |
| linen | 亚麻布 | Linen | middle | North-European cloth |
| furs | 毛皮 | Furs | middle | Baltic/Russian pelts |
| dye_wood | 苏木 | Sappanwood | middle | SE-Asia dyewood, the Japan-trade staple |
| indigo | 靛蓝 | Indigo | middle | Indian dyestuff |
| ivory | 象牙 | Ivory | middle | East-African/Indian trade |
| sandalwood | 檀香 | Sandalwood | middle | Timor/Indies aromatic wood |
| coffee | 咖啡 | Coffee | middle | Yemen/Mocha trade |
| tobacco | 烟草 | Tobacco | middle | New-World colonies |
| tea | 茶 | Tea | middle | China export novelty |
| rhubarb | 大黄 | Rhubarb | middle | Chinese medicinal root |
| raw_silk | 生丝 | Raw Silk | middle | Ming mass-export silk |
| porcelain | 瓷器 | Porcelain | luxury | China export ware |
| pearls | 珍珠 | Pearls | luxury | Gulf pearl fisheries |
| gems | 宝石 | Gems | luxury | India/Ceylon stones |
| musk | 麝香 | Musk | luxury | Tibet/Yunnan aromatics |
| lacquerware | 漆器 | Lacquerware | luxury | East-Asian craft ware |
| silver | 白银 | Silver | luxury | bullion flowing to China |
| gold | 黄金 | Gold | luxury | West-African/Andean bullion |

Split check (validator §8.2): 12 staples / 16 middle / 12 luxuries — the
skeleton above lands exactly on it. Every `specialty` (= luxury tier, §4.2)
is authored at ≤ 6 producers, and ≥ 1 exclusive good is produced per
neutral band (P's graph).

**Producer sets as authored by task P's port graph (2026-11-02).** Luxury
producer counts: silk 4 (canton venice smyrna bandar_abbas), spices 6
(malacca ternate amboina banten jambi calicut), carpet 5, perfume 4, amber
4 (hamburg danzig stockholm sofala), porcelain 5 (canton macau ningbo
quanzhou busan), pearls 5 (hormuz basra sulu cartagena beihai), gems 3,
musk 2, lacquerware 2, silver 5, gold 6. Band-exclusive coverage of the
six neutral bands is **final**: G's
`exclusive: true` set is {spices, carpet, porcelain, pearls, gems, musk,
lacquerware, gold} (master-ruled 2026-11-02), and P's graph satisfies
every band under it — china_coast → **musk** (band-only) / porcelain;
japan → **lacquerware** (band-only); korea → **porcelain**; southeast_asia
→ **spices** / **pearls**; india_persia_arabia → **gems** (band-only) /
pearls; swahili_red_sea → **gold**. (amber, silver, silk, perfume are not
flagged exclusive; no band relies on them.)

### 7.3 ShipTypes (16, Phase 7)

The 16-hull roster. The original 8 keep every locked stat; the 8 Phase-7
hulls enter with the `IMPLEMENT-Phase7.md` §2.2 first-pass stats below —
task S may tune within ±20% at authoring, then the values are locked
(exact-set validator tuples, §8 group 5).

| id | zh | en | class | role | tier | price | durability | capacity | speed | crew min/max | cannons |
|---|---|---|---|---|---|---|---|---|---|---|---|
| latin | 拉丁帆船 | Latin | sail | — (S) | 1 | 1200 | 40 | 30 | 16 | 8/20 | 2 |
| sloop | 单桅纵帆船 | Sloop | sail | — (S) | 1 | 3000 | 60 | 60 | 20 | 10/30 | 4 |
| caravel | 卡拉维尔帆船 | Caravel | sail | — (S) | 2 | 8000 | 90 | 120 | 20 | 15/45 | 6 |
| galley | 桨帆船 | Galley | oar | war | 2 | 10000 | 70 | 50 | 24 | 40/120 | 4 |
| brigantine | 双桅帆船 | Brigantine | sail | — (S) | 2 | 15000 | 110 | 150 | 24 | 20/60 | 10 |
| nao | 瑙船 | Nao | sail | — (S) | 3 | 22000 | 140 | 300 | 16 | 25/80 | 10 |
| carrack | 卡拉克帆船 | Carrack | sail | — (S) | 3 | 40000 | 180 | 450 | 16 | 30/100 | 16 |
| galleon | 盖伦帆船 | Galleon | hybrid | — (S) | 3 | 60000 | 240 | 400 | 20 | 40/150 | 24 |
| galiot | 小型桨帆船 | Galiot | oar | war | 1 | 2400 | 35 | 25 | 16 | 15/40 | 2 |
| galleass | 加莱赛战船 | Galleass | oar | war | 3 | 22000 | 110 | 70 | 16 | 60/160 | 6 |
| fluyt | 弗鲁特商船 | Fluyt | sail | trade | 2 | 14000 | 70 | 180 | 16 | 12/30 | 2 |
| junk | 福船 | Junk | sail | trade | 2 | 16000 | 90 | 140 | 18 | 20/60 | 3 |
| dhow | 单桅三角帆船 | Dhow | sail | trade | 2 | 9000 | 60 | 90 | 18 | 10/30 | 2 |
| pinnace | 平底船 | Pinnace | sail | coastal | 1 | 2200 | 40 | 45 | 16 | 8/20 | 2 |
| caravela_redonda | 卡拉维拉方形帆船 | Caravela Redonda | sail | trade | 2 | 11000 | 70 | 100 | 20 | 15/40 | 3 |
| xebec | 小型三桅船 | Xebec | hybrid | war | 2 | 15000 | 60 | 60 | 24 | 25/80 | 4 |

- **`role` enum (locked): `war | trade | coastal`** (§4.3; row wording
  `40-*`/`80-*`). First-pass values above are §2.2's: the galley re-roles to
  `war` (price unchanged), the new hulls as shown; the 7 unassigned
  originals are **task-owned by S** (coordinated with C's `40-*` wording).
  The galley's stock list is restricted to Mediterranean/North-African
  ports (P).
- **`tier` first-pass (§2.2; S finalizes, then locked):** tier 1 = {latin,
  sloop, pinnace, galiot}; tier 2 = {caravel, brigantine, galley, dhow,
  caravela_redonda, fluyt, junk, xebec}; tier 3 = {nao, carrack, galleon,
  galleass} — ≥ 2 hulls per tier (validator §8.2).
- **Speeds:** first-pass values above; every hull's **final** `speed` must
  lie in the §6.1 locked set `{16, 20, 24}` — the two 18s (junk, dhow) snap
  within S's ±20% budget (S finalizes; validator exact-set re-pins them).
  The xebec is the dated ~1690s exception, recorded as a one-line note in
  `LICENSE-NOTES.md`. The 1 tile/day floor and "fleet = slowest hull" are
  unchanged.
- **Per-port stock:** `facilities.shipyard` lists 2–8 hull ids per shipyard
  port (§4.4); regional flavor (Mediterranean → galley/galiot/galleass/
  xebec; China coast → junk; Arabia/India → dhow; Holland → fluyt; capitals
  the widest set) and ≥ 4 dev-3 sovereign ports stocking tier-3 hulls are
  P's authoring under the §8.2 checks. At start only the 6 dev-3 capitals
  sell tier-3 hulls.

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

### 7.5 Officer roster (96, Phase 8; the 6 Phase-1 starters retained)

`data/officers.json` v2 (§4.5, built) holds exactly **96 officers — 24
legends + 72 regulars**; the legends are hand-authored in
`tools/officer_overrides.json`. The Phase-1 starters below keep their ids,
names, nations and recruit ports as **locked identity**; their v1
`role`/`stats` columns are retired (the v2 person-card conversion of these
six rows is W2 roster-task work — their v1 wages 28–32 g sit inside the
regular 20–35 g band, §4.5):

| id | zh | en | nation | recruit ports |
|---|---|---|---|---|
| off_mateus_alvares | 马特乌斯·阿尔瓦雷斯 | Mateus Álvares | portugal | lisbon, madeira |
| off_diego_fernandez | 迭戈·费尔南德斯 | Diego Fernández | spain | seville, ceuta |
| off_thomas_reed | 托马斯·里德 | Thomas Reed | england | london |
| off_jan_de_vries | 扬·德弗里斯 | Jan de Vries | holland | amsterdam, antwerp |
| off_kemal_agha | 凯末尔阿迦 | Kemal Agha | ottoman | istanbul, smyrna |
| off_marco_bellini | 马尔科·贝里尼 | Marco Bellini | italy | venice, genoa |

The other 90 roster members, the legend layer, and the quota bands
(specialty coverage / captain-qualified / wages) are §4.5 + §8.7 material —
the exact per-skill membership is authored data, recorded nowhere here.

### 7.6 Trade lanes (21, Phase 5 + Phase 6 + the 2026-11-02 amendment)

The locked `data/trade_routes.json` lane id set (§4.14) — exhaustive. The 12
Phase-5 lanes' `nations`/`goods`/`waypoints`/`chokepoints` values are authored
data (`IMPLEMENT-Phase5.md` task E); the 5 Phase-6 lanes' ids, waypoints and
chokepoints are locked by Phase-6 task P (`IMPLEMENT-Phase6.md` §2.11.1):

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
| canton_country_trade | 广州—中国沿海贸易航线 | The Canton country trade run |
| coromandel_bengal | 科罗曼德尔—孟加拉航线 | The Coromandel–Bengal run |
| swahili_coast | 斯瓦希里海岸航线 | The Swahili coast run |
| pacific_america | 太平洋美洲航线 | The Pacific America run |
| west_africa | 西非航线 | The West Africa run |

The set is closed: **no Cape Horn lane** (rounding the Horn is a post-1616
anachronism; the Magellan Strait is the historical south-sea passage where
one is relevant). The `hanseatic_north` lane carries a winter `variants`
entry (§4.14) — the first variant customer, avoiding the Baltic freeze
(§4.18). The Phase-6 lanes carry patrols/treasure fleets/chokepoint pirates
visibly but no trader traffic docks at a neutral port this phase.

**Phase-6 lane authoring (task P, 2026-10-31).** The 5 new lanes' ids,
waypoints, nations, goods and chokepoints below are locked **as authored**
(with the pinned port-touch waypoints at the exact `ports.json` coordinates
of Malacca/Hoi An/Macau/Quanzhou/Ningbo/Hirado, Goa/Colombo,
Nagapattinam/Masulipatnam/Hughli, Mozambique/Mombasa/Mogadishu,
Acapulco/Panama/Guayaquil/Callao-Lima/Valparaíso,
Madeira/Safi/Saint-Louis/Elmina/Accra/Luanda; intermediate offshore steering
points authored on the world raster — walkable ≤ 2-tile snap per §4.14):

| id | waypoints (summary) | nations | goods | chokepoints |
|---|---|---|---|---|
| canton_country_trade | Malacca → Singapore strait → offshore Vietnam → Hoi An → Gulf of Tonkin → Macau → Guangdong/Fujian coast → Quanzhou → Zhejiang coast → Ningbo → East China Sea → Hirado (53 waypoints) | portugal, holland, spain | silk, ceramics, spices, cotton_cloth | taiwan_strait |
| coromandel_bengal | Goa → Malabar coast → Gulf of Mannar (south of Sri Lanka) → Colombo → east of Ceylon → Nagapattinam → Coromandel coast → Masulipatnam → Bay of Bengal → Hughli (37 waypoints) | portugal, holland | cotton_cloth, silk, sugar, spices | ceylon_south |
| swahili_coast | Mozambique Island → Mozambique channel coast → Mombasa → Somali coast → Mogadishu (19 waypoints) | portugal | dried_fish, salt, cotton_cloth | cape_guardafui |
| pacific_america | Acapulco → offshore Central America → Gulf of Panama → Panama → Ecuador coast → Guayaquil → offshore Peru → Callao/Lima → offshore Chile → Valparaíso (38 waypoints) | spain | sugar, dried_fish, wool, salt | gulf_of_panama |
| west_africa | Madeira → Moroccan coast → Safi → Saharan coast → Saint-Louis → Guinea coast → Elmina → Accra → Gulf of Guinea → Angola coast → Luanda (41 waypoints) | portugal | dried_fish, salt, cotton_cloth, amber | gulf_of_guinea |
| atlantic_north | The Dover strait → Plymouth → the 44–48°N westerlies → Newfoundland → Gulf of St. Lawrence (Gaspé roads) → back out → Boston → New York → Charleston (53 waypoints) | england, holland | dried_fish, timber, furs, wool, salt, tobacco | dover_strait, gulf_of_st_lawrence |
| brasil_run | Lisbon → Madeira → Praia → Belém → Recife → Bahia → Rio de Janeiro → Buenos Aires (44 waypoints) | portugal, spain | sugar, timber, salt, wine | volta_do_mar, rio_de_la_plata |
| brouwer_route | Table Bay → the Roaring Forties (−38/−42°) → Cape Leeuwin → Shark Bay → the Western-Australian coast north → Sunda strait → Batavia (46 waypoints) | holland | spices, silk, cotton_cloth, sugar | cape_of_good_hope, sunda_strait |
| molucca_run | Batavia → east along the Java sea → Gresik → Makassar → Timor → Ambon → Ternate (36 waypoints) | holland, portugal | spices, cotton_cloth, silk, sugar | makassar_strait |

**`hanseatic_north` winter variant (task P, 2026-10-31).** The lane's base
waypoints enter the Baltic through the Danish straits (Bergen → Dover →
London/Flanders → sounds → Danzig), which sits inside the §4.18 Baltic freeze
in months 12–3. The lane therefore carries the variant
`hanseatic_north_winter` (`months: [12, 1, 2, 3]`): the Hamburg–Bergen North
Sea run of the Hamburg *Bergenfahrer* (Bergen → North Sea → German bight →
Hamburg), staying clear of the Baltic freeze polygon entirely. Month
coverage: base `waypoints` serve months 4–11 (ice-free by §4.18's own
months), the variant serves 12–3 — base + variants cover all 12 months, no
overlap.

**Route-network amendment (2026-11-02).** The locked lane set grows 17 → 21
with the four regional runs above, five ports join §7.1, and the following
existing-lane waypoints are amended (all port-touch waypoints pin the exact
`ports.json` coordinates; every segment and month window verified by
`tools/build_routes.py`; the amendment closes the audited coastal gaps —
eastern North America, eastern South America, southern Africa, the Gulf of
Thailand, the Burmese coast, the Japanese south coast, the Moluccas and
Western Australia — and re-joins the network into one junction component):

- `grand_banks_cod` — start pinned to London (the Thames-estuary
  out-and-back waypoints removed), end pinned to Newfoundland.
- `iceland_cod` — start moved to London (sharing the Dover–Celtic-sea
  corridor with `grand_banks_cod`), Plymouth kept as a victualling touch,
  end pinned to Reykjavik (no more open-water terminus).
- `west_indies_flota` — the Canary spike replaced by a Santa Cruz touch;
  the Antilles arc replaced by the historical southern galeones silver loop
  Trinidad → Curaçao → Cartagena → Portobelo → western Caribbean (a Puerto
  Rico north-coast touch remains for San Juan).
- `genoa_grain` — an Istanbul touch on the Bosporus and the terminus moved
  from the open Black-sea shelf to Caffa.
- `west_africa` — extended Luanda → Benguela → the Namibian coast →
  Cape Town (joining the west-African and cape networks).
- `swahili_coast` — southern terminus Sofala prepended before Mozambique.
- `carreira_da_india` — the cape passage now calls at Table Bay (Cape Town).
- `aden_gujarat_malacca` — extended Malacca → the Singapore strait → the
  Gulf of Thailand → Siam (serving Patani en route).
- `coromandel_bengal` — extended Hughli → the delta offshore → Dianga →
  Syriam.
- `canton_country_trade` — the Macau weave simplified, and the lane extended
  Hirado → around Kyushu's south → Urado → Anotsu (the Japan south coast).
- `venice_alexandria` — unchanged (the Beirut junction station stays).

### 7.7 Named-captain canon (closed roster, Phase 8)

`data/npc_captains.json` — the Phase-5 §7.7 of 7 captain name pools — is
**deleted**; every fleet captain is now a named card of the closed canon
`data/captains.json` (§4.11). The locked rule:

- **Coverage is computed, never magic-numbered.** The canon card count is
  ≥ the **extreme-preset** fleet total derived from `data/npc_config.json`
  (§4.10) budgets × preset multipliers under the role budget formulas of
  `60-*` §4.1.1 (as amended by `60-*` §4.11.14 for nationless coasters),
  **including the transient rows**: hunters ≤ 1 × bountied nation (worst
  case all 6) and treasure 1 × nation per season (worst case 6), each ×4 at
  the extreme preset. At the current content the normal-preset total is
  **323** fleets (core 307 + 16 slack, `tools/demo_check_phase7.md`); the
  extreme canon lands ≈ **1,300** cards — the validator computes the exact
  number at validation time (§8.6 items 3–4) and the acceptance record pins
  the measured canon count.
- **24 legend cards** are hand-authored (`tools/captain_overrides.json`):
  the 4 named pirates of §7.8 (with their `drop` fields) + 20 legend
  captains. Every other card is generated from
  `data/captain_name_parts.json` (§4.11.1).
- **Names are never reused** — one name per person across the canon, the
  officer roster (§7.5) and the part-assembled name space; builder-refused
  and validator-asserted (§8.6).

### 7.8 Named pirates (4, Phase 5; v2 full cards, Phase 8)

`data/named_pirates.json` (§4.12) holds exactly 4 named pirates; every
`tier` ∈ `1 … 3` (`70-*` §4.5 bounty tiers). Since Phase 8 each row is a
**full captain card** (§4.12) authored in `tools/captain_overrides.json`
with its `drop` preserved; the Phase-5 respawn-under-a-new-name rule is
retired (the §4.11 return queue replaces it). The locked part: the count
(4), the tier band, and the `drop` → `rare: true` pairing 1:1 with the four
captains (validator §8.6).

### 7.9 Equipment (24, Phase 7)

`data/equipment.json` (§4.6) holds exactly **24 items — 6 per slot**
(weapon/armor player-worn; figurehead/sail ship-bound; semantics
`60-*` §4.11.12). Locked structure:

- **Tier split per slot: 2 tier-1 / 2 tier-2 / 2 tier-3** (§4.6 `tier`;
  price guideline: tier 1 ≤ 1,500 g, tier 2 ≤ 3,500 g, tier 3 above; whole
  set inside the 300–6,000 g band). S finalizes prices/tiers.
- **Rare drops:** exactly **4** items carry `rare: true` — one per slot;
  never in any `facilities.equipment_stock` list, never tier-gated
  (never purchasable at all); each is some named pirate's `drop` (§4.12,
  §7.8). Validator-asserted: the stock rule in §8.2, the `drop` pairing in
  group 11 (§8.6, relocated Phase 8).
- **Modifier keys:** the existing `combat`/`luck`/`durability`/`speed` plus
  the Phase-7 sideways keys `storm_damage_pct` and `scurvy_delay_days`
  (§4.6; semantics `60-*` §4.11.12).
- **Existing 8 ids stay** (exact-set lock moves to the 24-id set, §8
  group 5): `eq_cutlass`, `eq_rapier`, `eq_breastplate`, `eq_lucky_charm`,
  `eq_mermaid_figurehead`, `eq_dragon_figurehead`, `eq_cotton_sails`,
  `eq_storm_sails`. The 16 new ids, zh/en names, prices, tiers, and the
  rare pairing are **task-owned by S** and recorded here after authoring.
- **Per-port stock:** `facilities.equipment_stock` lists ≥ 2 ids at every
  shipyard port (§4.4); regional flavor as ships; same tier filter and the
  neutral allegiance gate (`30-*` §4.9).

### 7.10 Backgrounds (6, Phase 8)

`data/backgrounds.json` (§4.22) holds exactly **6** new-game backgrounds —
the locked set (attribute +3 / skill +5 each; bio zh/en per §4.22; the
creation flow and free-point pool `50-*` §4.1):

| id | zh | en | attribute | skill |
|---|---|---|---|---|
| background_deckhand | 甲板水手 | Deckhand | 体魄 constitution +3 | 操船 seamanship +5 |
| background_navy_cadet | 海军见习生 | Naval Cadet | 胆识 courage +3 | 航海 navigation +5 |
| background_merchant_apprentice | 商行学徒 | Merchant Apprentice | 魅力 charisma +3 | 交涉 negotiation +5 |
| background_cartographer_apprentice | 制图学徒 | Cartographer's Apprentice | 悟性 intellect +3 | 制图 cartography +5 |
| background_tavern_errand | 酒馆跑腿 | Tavern Runner | 运气 luck +3 | 打探 rumour +5 |
| background_fencing_student | 剑馆弟子 | Fencing Student | 胆识 courage +3 | 剑术 swordplay +5 |

### 7.11 ui_strings Phase-8 families (inventory, Phase 8)

`data/ui_strings.json` grows these families (both locales; group 12 asserts
presence, §8.7): `char.*` (character panel/card), `skill.*` (skill names and
growth copy), `gate.*` (locked-gate frames pairing the §4.20 rows),
`hail.*` (hail modal verbs/intel), `interact.*` (fleet picker / verb
matrices), `dossier.*` (career-log layers), `captain.table.*` (the tavern
index), `officer.post.*` (appointment UI), `creation.*` (the two-step
new-game screens), `sail.autopilot.*` (appointed-voyage HUD/entry), and
`advice.*` (the §4.21 per-post situation lines) — plus the
personality/appearance part keys `personality.<tag>` and
`appearance.<axis>.<value>` of §4.11.1. The Phase-7 baseline is ≈ **680**
keys (`IMPLEMENT-Phase8.md` correction 5; the exact count is recorded at
validation time in the acceptance record — never a pinned constant).

### 7.12 ui_strings Phase-9 families (inventory, Phase 9)

`data/ui_strings.json` grows these two families in the Phase-9 W2 strings
wave (both locales; the zh/en values themselves are authored there — this
inventory is the normative key set for the wave, and **no other Phase-9 key
may be invented by later waves without amending this inventory first**).
Locale parity and the per-key `{placeholder}`-token-set identity remain
group 2's standing recursion; no new validator group is introduced (the
Phase-9 validator amendments are group 3's §4.3 ship_types fields and
group 7's `ai_profiles` — §8, §8.2 item 14).

- **`battle.*` (21 keys):** `battle.fit`, `battle.speed`, `battle.heading`,
  `battle.wind`, `battle.current`, `battle.weather`, `battle.reload.port`,
  `battle.reload.starboard`, `battle.morale`, `battle.formation`,
  `battle.shot.round`, `battle.shot.chain`, `battle.shot.armor_piercing`,
  `battle.shot.grape`, `battle.shot.locked` (`{value}`), `battle.ring.hook`,
  `battle.ai_speed.animate`, `battle.ai_speed.instant`,
  `battle.result.stall`, `battle.log.rake` (`{attacker}`, `{target}`,
  `{damage}`), `battle.log.strike` (`{ship}`).
- **`sandbox.*` (44 keys):** `sandbox.title`, `sandbox.start`,
  `sandbox.random_all`, `sandbox.import`, `sandbox.export`,
  `sandbox.back`, `sandbox.player`, `sandbox.enemy`,
  `sandbox.ship` (`{index}`), `sandbox.ship.add`, `sandbox.ship.remove`,
  `sandbox.ship.max`,
  `sandbox.ship.type`, `sandbox.ship.cannons`, `sandbox.ship.crew`,
  `sandbox.ship.durability`, `sandbox.ship.figurehead`, `sandbox.ship.sail`,
  `sandbox.ship.captain`, `sandbox.enemy.kind`, `sandbox.enemy.compose`,
  `sandbox.enemy.flagship`, `sandbox.morale.short`,
  `sandbox.current.strength`,
  `sandbox.day`, `sandbox.seed`, `sandbox.seed.fixed`,
  `sandbox.seed.random`, `sandbox.seed.auto`, `sandbox.weather`,
  `sandbox.wind_dir`, `sandbox.current`, `sandbox.deployment`,
  `sandbox.deployment.standard`, `sandbox.deployment.tournament`,
  `sandbox.morale.player`, `sandbox.morale.enemy`, `sandbox.formation`,
  `sandbox.ai_level`, `sandbox.archetype`, `sandbox.import.invalid`,
  `sandbox.import.ok`, `sandbox.export.ok`, `sandbox.zero_write`.

Every key not annotated above is a plain label (no placeholder). Notes:

- **Value-label sub-keys (W2 gate amendment, master-authorized):** the
  S21 selectors must never render raw ids, so the wave also ships the
  `{family}.{value}` labels — `battle.formation.{line_ahead, column,
  screen, swarm}` (4), `sandbox.kind.{pirate, navy, patrol, privateer,
  treasure, trader, coaster, courier, tournament}` (9),
  `sandbox.archetype.{aggressive, balanced, cautious}` (3),
  `sandbox.ai_level.{t2, t3}` (2), `sandbox.dir.{N, NE, E, SE, S, SW, W,
  NW, VAR}` (9; shared by the wind-direction and current-direction
  selectors). Weather labels reuse the existing `world.weather.*` keys.
  With these, the families total 88 new keys (899 → 987).
- attribute labels reuse the existing `char.attr.*` keys — no new attribute
  strings;
- equipment item names come from `data/equipment.json` — never duplicated
  into `ui_strings.json`;
- the sandbox after-action dialog reuses the existing `battle.after.*` keys;
- grape volleys log hull damage through the existing `battle.log.cannon`.

## 8. `tools/validate_data.py` Spec

Python ≥ 3.10, stdlib only (`json`, `re`, `sys`, `pathlib`, `zlib` for the PNG
reader). Run:
`python3 tools/validate_data.py` from the repo root. Exit code 0 = all checks
pass; first failure prints `FAIL <check-id> <file> <details>` and exits with
the code below. All checks run in order.

| Exit | Check group | Checks |
|---|---|---|
| 1 | Parse & envelope | every `data/*.json` parses; envelope has int `version` and exactly one plural entity key matching the filename (except `map_legend.json`, `maps/maps.json`, `maps/world_report.json`, `facility_hours.json`, `ui_strings.json`, and the envelope exceptions — `npc_config.json` (config block), `trade_routes.json` (key `lanes`), `trade_routes_built.json` (tool output), `captains.json` (tool output, key `captains`), `captain_name_parts.json` (authored multi-block source)). The Phase-6 ocean files (`wind_regions.json`, `ocean_currents.json`, `ice_regions.json`) use plural == basename and need **no** exception — as do the Phase-8 `skill_gates.json` / `officer_posts.json` / `backgrounds.json`. A present `data/npc_captains.json` (retired) fails group 11 (§8.6) |
| 2 | i18n | every L10nString has exactly keys `zh`,`en`, both non-empty strings; applies recursively to all entity files. `ui_strings.json`: every top-level key except `version` maps to an L10nString, and per key the `{placeholder}` token sets in `zh` and `en` must be identical. The Phase-8 string families (§7.11) must each carry ≥ 1 key in both locales (group 12 owns the per-family check); the total key count is recorded at validation time, never pinned as a constant |
| 3 | Schema | every entity has its §4 required fields with correct types and enum/range constraints (incl. `id` regex, `tilePos` bounds `4320 × 2160`, `lat ∈ [-90, 90]`, `lon ∈ [-180, 180]`, and rejection of the retired port keys). **Phase 7:** goods `staple`/`specialty`/`exclusive` bools + `flow {prod, cons, capacity}` (all-three-or-none, values > 0, `capacity ≤ 200`); ship `role ∈ {war, trade, coastal}` and `tier ∈ {1, 2, 3}`; equipment `tier ∈ {1, 2, 3}` and `rare` bool; named-pirate `drop` id type; port `band` id type, `protected` bool, `dev ∈ 0…3`, `sphere []id`, `facilities.shipyard` a 2–8-element id array (the retired int form rejected), `facilities.equipment_stock` ≥ 2 ids; rejection of the retired `market_goods` key. **Phase 8:** captain-card and officer-card field shapes (§4.11, §4.5 — role enum, tier/level/attribute/skill ranges, personality/appearance vocabulary refs); `skill_gates`/`officer_posts`/`backgrounds` field shapes (§4.20–4.22) — the normative field-level specs are groups 11–12 (§8.6–8.7). **Phase 9:** ship_types `battle_max_speed`/`battle_accel`/`battle_turn_rate` (§4.3) — type/range checks (`battle_max_speed` 3–5 per correction 15, `battle_accel ∈ {1, 2}`, `battle_turn_rate ∈ {45, 90}`), the exact per-speed mapping `16→3 / 20→4 / 24→5` (correction 15), the `battle_accel` oar rule (oar hulls 2, sail/hybrid 1), and the `battle_turn_rate` two-tier hull partition (90 = latin sloop galiot pinnace dhow xebec galley; 45 = the other nine — the 16 locked hulls partition exactly once) |
| 4 | Referential integrity | `port.nation_id ∈ nations` (or `""` — the Phase-6 neutral tier, §7.1); `port.produces ∪ port.demands ⊆ goods`; `port.band ∈ the §7.1 band id set`; `facilities.shipyard[] ⊆ ship_types`; `facilities.equipment_stock[] ⊆ equipment` and never contains a `rare: true` item; `port.sphere ⊆ nations`; `nation.start_port_id ∈ ports`; `nation.capital_port_id ∈ ports`; `nation.start_ship_type_id ∈ ship_types`; `nation.rivals ⊆ nations` (exactly 2, never itself); `officer.nation_id ∈ nations`; `officer.recruit_ports ⊆ ports`; captain/officer `home_port` (when present) `∈ ports`; `quest.requirements.good_id ∈ goods`, `dest_port_id ∈ ports`, `exploration.discovery_id ∈ discoveries`, `rewards.reputation` keys ∈ nations; equipment `modifiers` keys are known stat names (incl. the Phase-7 `storm_damage_pct`/`scurvy_delay_days`); gate `stat_or_skill` ∈ the 5 attributes + 11 skills; background bonus keys ∈ attributes/skills. (The named-pirate `drop` → rare-equipment pin is re-checked in group 7 since Phase 8 — §8.6 cross-reference, relocated) |
| 5 | Locked lists | the §7.1 **lock model** — *Phase-7 amendment:* for ports, **identity locks only** (id/zh/en/nation/lat/lon exact vs the §7.1 tables; the port id set is exactly the 105 sovereign (the 100 plus the five of the
2026-11-02 route-network amendment) **plus the 45 recorded Phase-6 neutrals**; produces/demands are demoted to the structural §8.2 checks so the economy graph can be authored); §7.2 **40 goods**, §7.3 **16 ship types**, §7.4 6 nations, §7.5 **96 officers** (24 legend + 72 regular; the 6 Phase-1 starter ids locked), §7.9 **24 equipment**, §7.10 **6 backgrounds** — id sets must match exactly (ships/equipment/goods are authored-to-final, no sim loop; the 90 non-starter officers and the canon are builder-generated and checked by groups 11–12 instead); the §7.1 band id set matches the P-recorded list |
| 6 | World map | The generated-artifact integrity group below (artifact, harbor-tile agreement, reachability, probes, component listing) plus the seeded negative tests |
| 7 | NPC & economy data | `npc_config.json` bounds (presets ≥ 0, `default_preset` ∈ `presets` at the neutral multiplier, budgets/flow > 0, `absolute_cap` ≤ the §4.10 cap, plus the Phase-7 `neutral_coasters_mult` > 0 line); `named_pirates.json` (exactly 4, tiers 1–3, i18n — since Phase 8 they are v2 full captain cards and the field-level checks incl. the `drop` pin live in group 11, §8.6); `market_events.json` (`scope` valid, cadence/duration > 0, shifts keep rest inside the band — **this event block is untouched by Phase 7's W2 wave**; the rate-surge transition is task K's in W3, `IMPLEMENT-Phase7.md` correction 9); the Phase-7 economy-data checks — normative spec §8.2. (The Phase-5 `npc_captains.json` checks are removed — the file is retired, its absence asserted by group 11, §8.6.) **Phase 9:** `npc_config.json` `ai_profiles` — the 9-kind exact set, the 9-key row shape, enum membership, integer ranges, `kind` == map key, hunter-fallback (no `hunter` row may exist) — normative spec §8.2 item 14 |
| 8 | Trade routes | `trade_routes.json` id set is exactly §7.6's **21**; waypoints satisfy the §6.1 snap rule; every segment passable and wrap-continuous; every port satisfies the §4.14 spoke rule; junction-graph connectivity probes; `trade_routes_built.json` rebuild equality — normative spec §8.3 |
| 9 | Ocean rasters | `data/maps/wind_regions.png` + `data/maps/currents.png` decode as 4320×2160 indexed PNGs; palette bounds per the §6.5 encodings; water-coverage vs `world.png`; `tools/build_ocean.py` rebuild determinism — normative spec §8.4; + the §6.7 distance raster audit (decode/bounds/land-zero/1020 sampled probes; the full rebuild is `tools/build_distance_field.py --check`) |
| 10 | Ice & lane variants | `ice_regions.json` structure; lane `variants` month coverage + per-variant month-window passability under the ice mask; ice-crossing lanes carry covering variants — normative spec §8.5 |
| 11 | Captain canon | `npc_captains.json` **absent**; `captains.json` + `officers.json` rebuild determinism (`tools/build_captains.py --check`); canon coverage ≥ the computed extreme-preset total; the artifact `quota_table` matches the roster; name uniqueness across all captains + officers; `named_pirates.json` v2 ≡ its canon copies with the `drop` → rare pin; generated-card formula conformance — normative spec §8.6 |
| 12 | RPG data | officers v2 shape (96 = 24 + 72, 11 skill keys, wage & main-skill bands, specialty coverage ≥ 10 per skill at ≥ 20, captain-qualified ≥ 12, recruit-port rules); `skill_gates.json` rows incl. `sail.autopilot`; `officer_posts.json` exactly 7 with the locked prereqs; `backgrounds.json` exactly 6 with the key/range rules; ui_strings Phase-8 family presence — normative spec §8.7 |
| 13 | Generated UI art & shore raster | `assets/ui/` inventory == manifest ids for every contract class (`IMPLEMENT-Phase10.md` A.1–A.7); per-sprite palette-block membership + color budgets; 8-direction transform relations; hull ingest audit (raw dedupe: 16 × 8 shared grid + provenance ledger, owner ids resolved by the runtime fallback — classic: 16 × 9 × 8 remap coverage); tier footprint bands (waived for the raw family); seam checks; `world_shore.png` integrity (§6.6); `art_prompts.json` coverage; byte-identical `build_ui_art.py` / `build_shore.py` rebuilds — normative spec §8.8; PixelLab coast family: `assets/ui/terrain/terrain_coast_wang_*.png` inventory via the §4.8 2026-11-06 ledger (`tools/assets/pixellab_raw/pixellab_coast_ledger.json`), palette/budget/ring waived (raw-pixellab ruling), `build_ui_art --check` copies the committed tiles); PixelLab waterline VFX family (2026-11-07): `assets/ui/fx/fx_waterline_{back,front}_{dir}.png` (8 dirs × 2) + `fx_waterline.json` inventory via the `tools/assets/pixellab_raw/pixellab_vfx_ledger.json` (raw-pixellab ruling — palette/budget waived; canvas fit + anchor bounds + sheet sha256 match enforced), `build_ui_art --check` copies the committed family |
| 14 | Layout file | `data/ui_layout.json` v2 shape (version + screens), the 32-screen set, element/list rect shapes, canvas bounds, serialization bytes — normative spec §8.9 (Phase 12) |

### 8.1 Group 6 — world map, normative spec

Group 6 has no ASCII input and no markers. Exit 6. It checks:

1. **Artifact.** `data/maps/world.png` exists, decodes as an **indexed-color**
   PNG (color type 3), is exactly `4320 × 2160` pixels, and every palette
   index used is in the locked set `0–4` (`~ . # ^ I` in that order). Decode
   with `zlib` and the tool's own PNG reader — stdlib only, no PIL.
2. **Harbor tiles agree.** For each port of §7.1 (sovereign + neutral), recompute the harbor
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
   (`x mod 4320`; `x = 0` and `x = 4319` are neighbours). The BFS must reach
   every port's berth tile (§7.1: sovereign + neutral) and all discovery
   tiles (a discovery's derived tile is passable or orthogonally adjacent to
   a passable tile — `70-*` §4.4).
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

Group 7 exits 7. It checks the Phase-5 data files still in force —
`npc_config`, `named_pirates`, `market_events` (L10nString completeness
inside them is group 2's recursion; group 7 owns structure, counts, and
bounds):

1. **`npc_config.json`** (§4.10): every `presets` multiplier ≥ 0;
   `default_preset` ∈ `presets`, and it must be the neutral preset of
   §4.10; every `budgets` and `flow` value > 0;
   `absolute_cap` ≤ the §4.10 locked cap; the `presets`/`budgets`/`flow`
   key sets are exactly the §4.10 keys.
2. **`npc_captains.json` — removed (Phase 8).** The Phase-5 name-pool file is
   deleted; group 7 no longer reads it, and its absence is asserted by
   group 11 (§8.6 item 1).
3. **`named_pirates.json`** (§4.12, §7.8): exactly 4 entries; every `tier`
    an int in the locked band 1–3; ids unique; names complete i18n. Since
    Phase 8 the four rows are v2 full captain cards — the field-level checks
    and the `drop` → `rare: true` pin live in group 11 (§8.6 item 6),
    relocated herefrom unchanged in semantics (correction 7).
4. **`market_events.json`** (§4.13): every `scope == "port"` (the only
   valid value this phase); every `cadence_days` > 0 and `duration_days` >
   0; `rate_override` a non-empty good-id list, no duplicates, every id ∈
   goods (Phase 7 rate-surge shape — the W2-era note about `shifts` and the
   rest-band bound is retired with the K transition, `IMPLEMENT-Phase7.md`
   correction 9).
5. **Consumption-tier assertion (Phase-7 form):** the tier split is
   **flag-driven** per §4.2 — exactly **12** goods with `staple: true`
   (staple tier), exactly **12** with `specialty: true` (luxury tier), the
   remaining **16** unflagged (middle tier); the derived
   `base_price`-rank split of Phase 5 is retired. Every
   `specialty`/`exclusive` carrier must also satisfy `exclusive ⇒ specialty`.
6. **Port economy graph (correction 3):** for every port,
   `produces ∩ demands = ∅` (hard fail, was a warning) and
   `demands ⊇ (staples ∖ produces)` — i.e. every staple not produced here
   is demanded here, so `staples ⊆ produces ∪ demands` everywhere; every
   referenced good ∈ the §7.2 40.
7. **Graph shape:** every good has **≥ 2 producers** and **≥ 4 consumers**
   worldwide; every `specialty: true` good has **≤ 6 producers** (§4.2).
8. **Staple coverage (decision 21):** computing on the §6.1 grid at 12
   tiles/degree — from every port there is a staple producer within **120**
   tiles (Chebyshev) and ≥ **2** within **240**; every band of §7.1 has
   **≥ 2 staple producers**.
9. **Exclusive coverage:** every **neutral band** (§7.1 definition — any
   band containing a `nation_id: ""` port) has **≥ 1 exclusive good
   produced within it**.
10. **Port class rules (§7.1, decision 25):** `protected: true` only on
    sovereign rows; protected ⊇ the 6 capitals (lisbon, seville, london,
    amsterdam, istanbul, venice); **≤ 4 protected per nation** — the locked
    core set is portugal {lisbon, oporto}; spain {seville, cadiz, valencia,
    barcelona}; england {london, plymouth}; holland {amsterdam, antwerp};
    ottoman {istanbul, athens, smyrna}; italy {venice, genoa, naples,
    palermo}; protected rows carry no `sphere` entries; `dev` floors: 3 on
    capitals/protected, 2 on authored sovereign majors, 1 on remaining
    sovereign contestable, 0 on every neutral.
11. **Hardware tiers:** ship types ≥ **2 per tier**; equipment **2/2/2 per
    slot** (§7.9); **≥ 4 dev-3 sovereign ports** whose
    `facilities.shipyard` includes a tier-3 hull; every shipyard port's
    `equipment_stock` ≥ 2 ids; no `rare: true` item in any
    `equipment_stock` list.
12. **Named-pirate drops** — **relocated to group 11** (§8.6 item 6; the
    Phase-8 correction-7 move): every `drop` ∈ equipment with `rare: true`
    (§4.12), the 4 drops distinct and pairing 1:1 with the 4 captains,
    checked there against the canon copies.
13. **Band id set:** every port `band` ∈ the §7.1 recorded set; the set
    contains the six neutral-region bands (§7.1 skeleton ids) and covers
    all 150 ports with no unused id.
14. **`ai_profiles` (Phase 9, §4.10):** the `npc_config.json` map holds
    exactly the 9 kind rows — `pirate`, `privateer`, `patrol`, `navy`,
    `tournament`, `treasure`, `trader`, `coaster`, `courier` (exact set;
    **no `hunter` row may exist** — a battle kind missing from the table
    falls back to the `navy` row, hunter battles entering as
    `kind = "navy"`, correction 8); every row carries exactly the 9 keys
    `kind`/`archetype`/`aggression`/`preferred_range`/`flee_below_hp_pct`/
    `focus`/`courage_mod`/`formation`/`ai_level`; enum membership —
    `archetype ∈ {aggressive, balanced, cautious}`, `focus ∈ {weakest,
    nearest, flagship}`, `formation ∈ {line_ahead, column, screen, swarm}`,
    `ai_level ∈ {0, 1}`; integer ranges — `aggression` 0–100,
    `preferred_range` 1–3, `flee_below_hp_pct` 0–100, `courage_mod` −10…10;
    and each row's `kind` value equals its map key. The `coaster` row is
    forward-compat + sandbox-only (coasters are intimidate-only, never
    battle, `60-*` §4.1.1) but is shape-checked like every other row. All
    nine keys land with the W2 data wave (correction 11) — no per-stage key
    growth; the values are the §4.10 table verbatim.

**Negative tests (must provably fail, exit 7, named message):** a negative
preset; a default whose multiplier is not 1.0; a budget ≤ 0; an
`absolute_cap` above the cap; a 5th named pirate; a tier-4 pirate; a shift
that pushes any applicable rest outside the band. Phase-7 additions:
a 13th good flagged `staple`; a specialty with 7 producers; a good with 1
producer or 3 consumers; a port demanding only half of its non-produced
staples; `produces ∩ demands ≠ ∅`; a port > 120 tiles from any staple
producer; a neutral band with no exclusive producer; a 5th protected port of
one nation; a capital missing from `protected`; a neutral-tier port row with
authored `dev > 0`; a tier with 1 ship; a rare item inside an
`equipment_stock` list; a port `band` outside the recorded set. Phase-9
additions: a 10th `ai_profiles` kind (a `hunter` row included); a profile
row with a missing key or a 10th key; an `archetype`/`focus`/`formation`
value outside its enum; an `aggression` of 101 or a `courage_mod` of 11; a
row whose `kind` disagrees with its map key. (The
captain-pool and `drop`-reference negatives moved to group 11 with their
checks — §8.6.)

### 8.3 Group 8 — trade routes, normative spec

Group 8 exits 8. It runs after group 6 (same PNG decoder; sharing
`build_world.py`'s reader is allowed). It checks:

1. **Lane id set.** `data/trade_routes.json` contains exactly the §7.6
   **17** locked ids — none missing, none extra.
2. **Lane schema.** Every lane: `class == "major"`; `nations` ⊆ nations;
   `goods` ⊆ goods; ≥ 1 chokepoint tag; ≥ 2 waypoints with in-range
   lat/lon (§3.1). Optional `variants` structures are checked by group 10
   (§8.5).
3. **Waypoint snap.** Every waypoint satisfies the §6.1 snap rule as the
   builder applies it (the §4.14 rule: same radius, wrap-aware,
   smallest-`(y, x)` tie-break). Failure names the lane and waypoint.
4. **Segment passability.** The tile walk of every consecutive waypoint
   pair steps only on passable tiles, corner-cutting forbidden, wrap-aware
   (the group 6 item 3 movement rules).
5. **Wrap-aware continuity.** Dateline-crossing segments stay continuous
   under `x mod 4320` — no segment jumps the seam (`manila_galleon`
   waypoints keep per-segment `x` monotonic under wrap).
6. **Port spokes.** Every port of §7.1 (sovereign + neutral) satisfies the
   §4.14 spoke rule (a lane waypoint within the spoke radius, else the
   capital fallback; a neutral port uses the nationless nearest-waypoint
   fallback; §4.14 rule 5 may rewrite one spoke per detached component as
   a `"completion"` spoke — load-bearing, A\*-pathfound, endpoint on the
   named lane waypoint). A port with neither is a hard failure naming the
   port.
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

### 8.4 Group 9 — ocean rasters, normative spec

Group 9 exits 9. It runs after group 6 (same stdlib `zlib` PNG decoder; no
PIL). It checks both Phase-6 rasters of §6.5:

1. **Artifact decode.** Both `data/maps/wind_regions.png` and
   `data/maps/currents.png` exist, decode as **indexed-color** PNGs
   (color type 3), and are exactly **4320 × 2160** pixels.
2. **Palette bounds — wind.** Every palette index used in
   `wind_regions.png` is in `0 … region_count`, where `region_count =
   len(data/wind_regions.json#wind_regions)`; index 0 is the unassigned
   `VAR`-fallback water (§6.5); no index above the region count ever appears.
3. **Palette bounds — currents.** Every palette index used in
   `currents.png` is in `0 … 24` (the §6.5 encoding `index = dir_index × 3 +
   strength`; index 0 = no current).
4. **Water coverage vs `world.png`.** A non-zero wind-region index or a
   non-zero current index on a tile that is land (`#`), reef (`^`) or
   permanent ice (`I`) in `data/maps/world.png` is a failure naming the tile
   and the region/system.
5. **Determinism.** Re-run `tools/build_ocean.py` and compare both artifacts
   **byte-exactly** against the committed files; any drift fails naming the
   differing file. The fix lives in the JSON sources or the builder — never
   the PNGs.

**Negative tests (must provably fail, exit 9, named message):** a raster of
the wrong size or a non-indexed PNG; a wind index above the region count; a
current index above 24; a wind/current index on a land tile; a rebuilt raster
that differs by one byte.

### 8.5 Group 10 — ice & lane variants, normative spec

Group 10 exits 10. It checks the §4.18 ice regions and the §4.14 lane
`variants`:

1. **`ice_regions.json` structure.** Every polygon is a closed ring (first
   pair repeated last) whose vertices are in-range lat/lon (§3.1); `months`
   is a non-empty list of ints within 1–12; ids unique; names complete
   i18n (group 2's recursion).
2. **Lane variant structure (§4.14).** Every lane's `variants` entries: `id`
   unique within the lane; `months` a non-empty list of ints 1–12;
   `months` sets pairwise **disjoint** across the lane's variants;
   `waypoints` ≥ 2 pairs — so the lane's month coverage is total across
   base + variants (base covers the months no variant names).
3. **Variant passability within month windows.** Each variant's waypoint
   walk is checked once per month in its own window, with the group-6
   item-3 movement rules **plus the in-month ice mask** (a water tile inside
   an `ice_regions.json` polygon whose `months` include the walked month is
   impassable). A variant walk that hits in-month ice is a hard failure
   naming the lane and the variant.
4. **Ice-crossing lanes carry coverage.** Per lane and per month, the walk
   active in that month (variant if one covers it, else base) must be
   passable under that month's ice mask. A lane whose base walk crosses a
   seasonal-ice polygon without a covering variant set is a failure naming
   the lane.

**Negative tests (must provably fail, exit 10, named message):** an ice
polygon not closed or with out-of-range vertices; an ice region with an
empty or out-of-range `months`; two variants of one lane with overlapping
months; a variant walk stepping onto in-month ice; an ice-crossing lane with
no variants.

### 8.6 Group 11 — captain canon, normative spec *(Phase 8)*

Group 11 exits 11. It checks the built canon, the officer roster it shares a
builder with, and the retired name pools:

1. **`npc_captains.json` absent.** The Phase-5 name-pool file must not exist
   — its presence is the failure (the successor machinery is retired,
   `60-*`; the canon + `captain_states` replace it).
2. **Rebuild determinism.** Re-run `tools/build_captains.py` and compare
   both products **byte-exactly** against the committed `data/captains.json`
   **and** `data/officers.json`; any drift fails naming the differing part.
   The fix lives in `data/captain_name_parts.json`,
   `tools/captain_overrides.json` or `tools/officer_overrides.json` — never
   a built file. (`build_captains.py --check` is the builder's own
   byte-compare mode.)
3. **Canon coverage (computed, no magic constant).** From
   `data/npc_config.json` (§4.10) and the `60-*` §4.1.1 role budget formulas
   (as amended by `60-*` §4.11.14 for nationless coasters), compute the
   **extreme-preset** per-role fleet totals (`ceil` per role at multiplier
   4.0) plus the worst-case transient rows — hunters `1 × 6` bountied
   nations and treasure `1 × 6` nations, each ×4. Assert per role:
   `captains.json` cards of that role ≥ the role's extreme total; and the
   grand total ≥ the extreme fleet-cap total. (At the current content the
   normal total is 323 fleets and extreme ≈ 1,300 cards — the validator
   computes both numbers; the acceptance record pins the measured canon
   count.)
4. **Quota-table match.** The artifact's `quota_table` (role → tier →
   nation → count, §4.11) equals the roster's actual per-cell card counts,
   and its per-role sums satisfy item 3. Every `tier` value in the table
   and roster stays inside its role's §4.11 tier range; `nation_id: ""`
   cells carry the nationless roles (pirate, and the coasters).
5. **Name uniqueness.** Assembled `name.zh` and `name.en` are unique across
   **all** people: `captains.json` ∪ `officers.json` (which includes the
   4 named pirates — their `named_pirates.json` copies carry the same
   names). No part-assembled name may collide with a hand-authored legend
   name; the builder refuses the draw, this group re-asserts.
6. **Named-pirate consistency (the relocated drop pin).**
   `named_pirates.json` (§4.12) holds exactly 4 rows; each is
   field-for-field identical to its canon copy in `captains.json`; every
   `drop` ∈ equipment with `rare: true` (§7.9), the 4 drops distinct and
   pairing 1:1 — the Phase-7 group-7 pin, relocated unchanged
   (correction 7).
7. **Card conformance.** Every legend card satisfies the §4.11 field
   types/ranges/vocabularies (role enum, tier range, attributes 1–100,
   skills 0–100, personality ⊆ its role pool, the 4 appearance axes,
   `legend: true`). Every **generated** (non-legend) card additionally
   satisfies the §4.11 formulas term-by-term: `level = 1 + tier×4`
   (`+2` pirate/hunter); main attribute ∈ `[10+3t−3, 10+3t+3]`, secondary
   ∈ `[10+2t−3, 10+2t+3]`, others ∈ `[10+t−3, 10+t+3]`; signature skill
   ∈ `[8t, 8t+6]`, secondary skill `= 4t`, all other skills `0` (coaster:
   every skill `0`). `drop` appears on the 4 pirates only; `legend: true`
   on exactly the 24 hand-authored cards.

**Negative tests (must provably fail, exit 11, named message):** a present
`data/npc_captains.json`; a rebuilt `captains.json` (or `officers.json`)
differing by one byte; a canon short by one card in any role at the extreme
total; a `quota_table` cell disagreeing with the roster; a duplicated name
(zh or en) between any captain and officer; a pirate `drop` referencing a
non-rare or unknown equipment id; a tier-4 pirate; a generated pirate whose
signature skill is outside `[8t, 8t+6]`; a coaster card with a nonzero
skill.

### 8.7 Group 12 — RPG data (officers v2, gates, posts, backgrounds, strings), normative spec *(Phase 8)*

Group 12 exits 12. It checks:

1. **Officers v2 shape (§4.5, §7.5).** Exactly 96 entries — 24 with
   `legend: true` + 72 regulars; every card carries all 5 attribute keys
   (ints 1–100) and all 11 skill keys (ints 0–100); `main_skill` is the
   strict maximum of `skills`; `personality` ⊆ the officer's native-role
   pool (§4.11.1); `appearance` carries exactly the 4 axes.
2. **Bands.** `main_skill` value: legends 45–60, regulars 25–45;
   `wage_daily`: legends 40–60 g, regulars 20–35 g.
3. **Specialty coverage.** For each of the 11 skills (the 8 player skills +
   `medicine`/`carpentry`/`cooking`), ≥ **10** officers carry it at ≥ **20**
   (the post-prereq band, §4.21).
4. **Captain-qualified.** ≥ **12** officers with `skills.seamanship ≥ 25 ∧
   attributes.courage ≥ 30`.
5. **Recruit ports.** `recruit_ports` ≥ 1 id ∈ ports; legends hand-authored
   (no placement rule); every regular's ports ⊆ its own nation's ports
   (correction 9's home-port band).
6. **`skill_gates.json` (§4.20).** One row per locked gate in the `50-*`
   §2.2 Gates column plus `sail.autopilot`; `feature_id`s unique;
   `stat_or_skill` ∈ the 5 attributes + 11 skills; `threshold` int 1–99;
   `reason` complete i18n. The `sail.autopilot` row pins
   `stat_or_skill: "navigation"`, `threshold: 40`.
7. **`officer_posts.json` (§4.21).** Exactly the 7 posts: 6 `flagship`
   (pilot `navigation ≥ 20`, boatswain `seamanship ≥ 20`, gunner
   `gunnery ≥ 20`, surgeon `medicine ≥ 20`, carpenter `carpentry ≥ 20`,
   cook `cooking ≥ 20`) + 1 `captain` (`seamanship ≥ 25 ∧ courage ≥ 30`);
   `desc` complete i18n; every `advice` situation id has a
   `advice.<post_id>.<situation_id>` `ui_strings.json` row in both locales.
8. **`backgrounds.json` (§4.22, §7.10).** Exactly 6, the §7.10 id set;
   `attribute_bonus` exactly one attribute key `= 3`; `skill_bonus` exactly
   one skill key `= 5`; `bio` complete i18n.
9. **ui_strings Phase-8 families (§7.11).** Each family — `char.`,
   `skill.`, `gate.`, `hail.`, `interact.`, `dossier.`, `captain.table.`,
   `officer.post.`, `creation.`, `sail.autopilot.`, `advice.` — plus
   `personality.<tag>` / `appearance.<axis>.<value>` carries ≥ 1 key in
   both locales; every personality tag and appearance value referenced by
   any canon/officer card has its string. Parity and placeholder-token
   checks remain group 2's; the total key count is recorded at validation
   time (baseline ≈ 680 after Phase 7, correction 5), never pinned as a
   constant.

**Negative tests (must provably fail, exit 12, named message):** a 97th
officer or a 25th legend; a legend main skill 61; a regular main skill 46;
a legend wage 61 g or a regular wage 36 g; a skill carried at ≥ 20 by only
9 officers; a captain-qualified count of 11; a background with two
attribute keys, a `+4` skill bonus, or a 7th background; a gate row whose
`stat_or_skill` is unknown or whose `threshold` is 0; a flagship post whose
prereq is below 20; an advice situation with no ui_strings entry.

### 8.8 Group 13 — generated UI art & shore raster, normative spec *(Phase 10)*

Group 13 exits 13. It runs after groups 1–12 in the single
`validate_data.py` pass and requires **node ≥ v24.16.0** on PATH — the
vendored `tools/yoyopixel/render.js` engine's pinned runtime
(`IMPLEMENT-Phase10.md` decision 5). Sprite ids are the contract pinned in
`80-*` §4.8/§4.9 at W1 — kit/scenes reference ids, the tool owns pixels;
the class inventory below is `IMPLEMENT-Phase10.md`'s Appendix (A.1–A.7),
reconciled at machine scope, its approximate total informational only. It
checks:

1. **Manifest/artifact inventory equality.** For every contract class —
   chrome (15 tiles + the 5 assembled nine-patch sheets, A.1); icons 129
   (HUD resources 5; nav/weather 5 + wind/current arrows 16; battle 8;
   economy/port 4; meta/status 5; nation flags 7 (the 6 nations +
   neutral); goods `good_{id}` × 40 from `data/goods.json`; equipment
   `eq_{id}` × 24 from `data/equipment.json`; role badges 7
   `role_{trader|coaster|courier|patrol|privateer|pirate|hunter}`;
   formations 4; `trophy`; market trend/event 3, A.2); tokens (hulls
   — raw-dedupe amendment 2026-11-06: ONE owner-less file per ship × dir
   `hull_{ship_type_id}_{dir}` (16 × 8 = 128) + 6 facility tokens; the
   runtime resolves `hull_{ship_type_id}_{owner}_{dir}` ids onto the
   shared file (owner fallback, texture_registry), so the classic
   16 × 9 × 8 = 1 152 owner grid exists only while the ledger is
   classic, A.3); world markers 6 (A.4); terrain
   13 + `sea_pattern.png` (A.5); shore strips 8 (A.6); FX 11 + portrait
   part sheets 25 (A.7) — the set of files emitted under `assets/ui/`
   equals exactly the manifests' declared ids: none missing, none extra.
   Counts are reconciled from the `tools/ui_art/<class>/` manifests plus
   the data files (`goods.json`, `equipment.json`, `nations.json`,
   `ship_types.json`) at machine scope — never hard-pinned totals, so
   content growth cannot silently pass or fail.
2. **Byte-identical rebuild (double-run).** Re-run
   `tools/build_ui_art.py` (engine renders via the vendored
   `tools/yoyopixel/render.js`, node pinned v24.16.0) and
   `tools/build_shore.py`; every output file must be byte-identical to
   the committed tree — any diff fails naming the file. The same check
   is the hand-edited-PNG detector: no hand-authored PNG may exist under
   `assets/ui/` or at `data/maps/world_shore.png`.
3. **Palette-block membership.** Decode every indexed PNG under
   `assets/ui/`; every palette hex must belong to exactly one `80-*` §4.8
   palette block (terrain / icon / hull / fx / portrait) or be one of the
   chrome hexes already in §4.8's locked table; an off-block hex fails
   naming the sprite and the hex. The validator carries the pinned hex
   sets transcribed from §4.8's tables.
4. **Color budgets.** Per sprite, the distinct color count is ≤ its
   size-tier cap — 16×16 → 12; 32×32 → 20; 48px+ → 25 (the skill's
   tiers, `80-*` §4.8). Caps, not quotas — under is fine; exceeding
   fails naming the sprite and both counts.
 5. **8-direction transform relations.** For the **derivation families** —
    arrows (authored bases `n`, `ne`) and shore strips (authored `n` + one
    corner) — each derived direction must be the pixel-exact lossless
    transform (90° rotations / mirrors) of its authored base map under the
    pinned heading8→dir-id table (`80-*` §4.8). A mismatched derived sprite
    fails naming it. **Hulls are exempt (amended 2026-11-04, user
    direction): hull tokens are UW2-style side/3-quarter sailing views
    (`80-*` §4.8.6 amendment) — a side-view ship does not rotate
    losslessly, so all eight hull directions are authored maps and no
    derive entries exist for hulls; this check does not apply to them.**
 6. **Hull coverage.** The 9 owner **pennant remaps** — the 6 nations of
    `data/nations.json` + player + neutral + pirate — each map the
    authored pennant source hex onto its `PENNANT_*` hex on every one of
    the hull's authored maps (wood/sail/ink are owner-invariant; `80-*`
    §4.8 hull block, the shared-hull pennant scheme); the authored source
    hex never survives a remap; `hull_{ship_type_id}_{owner}_{dir}.png`
    exists for the full 16 × 9 × 8 = 1 152 grid, and the owner set equals
    `nations ∪ {player, neutral, pirate}` exactly. Hull docs declare
    **eight authored maps** (one per direction; no derive table).
    **Raw-dedupe amendment (2026-11-06):** while the ingest ledger is the
    pixellab raw family, the shipped grid is the owner-less
    16 × 8 = 128 (`hull_{ship_type_id}_{dir}.png`; the registry's
    `path_template` pins it) and the runtime falls owner ids onto the
    shared file — the ×9 remap grid, and this item's per-owner coverage,
    apply only when a future amendment reinstates owner pennants.
 7. **Footprint bands.** Per hull, the long-axis extent in px **on the
    side view (`e`/`w` — the profile shows the ship's length)** lies in
    its tier band — tier 1: 28–36, tier 2: 40–52, tier 3: 52–60
    (the §4.8 64-canvas model-pass upgrade, amendment 1664ba9: the bands
    are measured on the 64×64 token canvas, ×2 of the retired 32-canvas
    values 14–18/20–26/26–30; `ship_types.tier` partitions the 16 hulls
    4 / 8 / 4); the stern/bow views (`n`/`s`) show the beam and are
    canvas-fit only. A hull outside its band fails naming it and the
    measured extent.

**64-canvas artifacts (amendment 1664ba9).** Hull tokens and the terrain
class (terrain tiles, shore strips, port markers) ship as 64×64 canvases —
the exact ×2 nearest upscale of the authored 32-grid renders (the authored
manifests REMAIN the 32-grid source of truth; nothing is hand-drawn at 64);
`sea_pattern.png` is authored at 64 and ships 1:1. The validator decodes the
shipped canvas: terrain-class artifacts must be the declared grid ×2, hull
tokens declare the 64 canvas directly; ids and filenames are unchanged.
Inline icons keep the native 32 px art (`80-*` §4.8.8).
8. **Seam checks.** All variants of one terrain kind share a
   byte-identical, wrap-continuous outer 1px ring (interiors vary
   freely); `sea_pattern.png` and the nine-patch edge tiles are
   torus-safe along their repeating axes; shore-strip foam thickness
   matches the corner tiles' band; shore strips are transparent outside
   their land-facing band (the `80-*` §4.8 seam rules, machine-checked
   here).
9. **`world_shore.png` integrity (§6.6).** Byte-identity (item 2);
   palette indices ⊆ 0–8; every coded cell is water (`~`/`.`) in
   `world.png` and carries a land/reef/ice neighbour in exactly the
   coded direction (wrap-aware `x`, the §6.6 encoding); completeness —
   an uncoded water cell adjacent to land/reef/ice must carry a code;
   land/reef/ice cells are always 0.
10. **`art_prompts.json` coverage.** `tools/art_prompts.json` carries
    prompt entries for exactly the 24 `legend: true` captains + the 4
    named pirates + the 30 discoveries — none missing, none extra — with
    one shared `style_preamble` and per-class canvas dimensions
    (portraits 72×96, discoveries 64×64).

**Negative probes (must provably fail, exit 13, named message):** an
off-palette pixel; a hand-edited PNG (a rebuild diff); a broken transform
relation; an out-of-band hull footprint; an invalid shore code (a coded
non-water cell / an unknown palette index); a seam-rule violation (a ring
mismatch / a non-torus edge tile).

**Fixture command shape.** As in §8.4 (rebuild equality) and §8.6
(`build_captains.py --check`), the byte-compare lives in the builders'
own `--check` modes: `python3 tools/build_ui_art.py --check` and
`python3 tools/build_shore.py --check`.

### 8.9 Group 14 — the absolute layout file, normative spec *(Phase 12 — rewrites the Phase-11 override rules)*

Group 14 exits 14. It runs after groups 1–13 in the single
`validate_data.py` pass and reads only `data/ui_layout.json` (§4.23).
The file must exist and MUST be v2-shaped (`{"version": 2, "screens": …}`
— a v1-shaped file, top level = the screen map, fails item 0; there is
no migration, the capture regenerates the file). It checks:

0. **Version + top-level shape.** Exactly two keys: `version` (int
   `== 2`) and `screens` (an object; may be `{}` only for the port-pilot
   interim state — the shipped file is populated).
1. **Screen ids.** Every `screens` key is one of the **32** locked
   screen ids (§4.23); every screen value is an object whose keys are
   exactly `elements` and/or `lists` (both optional per screen, each an
   object when present).
2. **Element id format.** Every `elements` key matches
   `^[a-z0-9_]+(\.[a-z0-9_]+)*$` (dotted hierarchical ids; no leading /
   trailing / doubled dots). The runtime element set is open — the
   validator checks format only. List rows (`rows.*` …) never appear in
   `elements`.
3. **Rect shape + types.** Every element object's keys ⊆
   `{x, y, w, h, sheet}`; `x`, `y`, `w`, `h` are required ints
   (non-negative, no floats, no strings, no bools); `sheet`, when
   present, ∈ the 7 assignable ids (`panel`, `button`, `button_hover`,
   `button_pressed`, `button_focus`, `field`, `backdrop`).
4. **Canvas bounds.** Every element rect: `x + w ≤ 60`, `y + h ≤ 34`
   (the 1920×1080 canvas = 60 × 33.75 tiles; 34 = the rounded canvas
   height, §4.23 bounds). Parent-relative containment is runtime
   (registry clamp), not static.
5. **List blocks.** Every `lists` value is an object
   `{"base": {x,y,w,h}, "row_h": int ≥ 1, "viewport": {x,y,w,h}}`;
   `base`/`viewport` carry the same required non-negative int keys; both
   satisfy the item-4 canvas bounds; a list id matches the dotted-id
   regex of item 2; `base.w` == the row width the screen's builders
   place (format-level check only — the registry clamps at runtime).
6. **Serialization bytes.** The file's raw text equals
   `json.dumps(parsed, sort_keys=True, indent=2) + "\n"` — sorted keys,
   2-space indent, exactly one trailing newline (byte-stable commits;
   the studio and the capture tool both serialize this way).

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
  4320 × 2160 fails. Regenerate; never patch pixels.
- **A lane variant walk hitting in-month ice (§8.5 item 3)** → validator
  exit 10 naming the lane and the variant. The fix is a rerouted variant or
  a covering variant set in `data/trade_routes.json` — never a hand-edit of
  the built file.
- **A wind-region or current pixel on land/reef/permanent ice (§8.4
  item 4)** → validator exit 9 naming the tile and the region/system. The
  fix is the JSON sources and a `tools/build_ocean.py` regeneration.
- **A neutral port failing tier structure — a count ≠ 45 (the §8 group 5
  exact 150-set), an id colliding with a sovereign id, a missing locale,
  a good outside the §7.2 40, or a non-empty `nation_id` (§7.1, §8
  group 5)** → validator exit 5.
- **`market_goods` present** → validator exit 3: the key is retired
  (Phase 7); a port's market rows are derived from `produces ∪ demands`
  (§4.2).
- **`produces` ∩ `demands` ≠ ∅ for a port** → validator exit 7 (§8.2 item
  6): the listing rule makes the overlap a data bug, not a curiosity.
- **A port's `demands` missing a non-produced staple** → validator exit 7
  (§8.2 item 6, correction 3): staple access is the data rule, never a
  code special case.
- **A `band` id outside the §7.1 recorded set** → validator exit 7 (§8.2
  item 13); bands are authored by task P and recorded in §7.1, never
  invented per port.
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
- **A captain pool missing, extra, or under 8 names** → retired rule: the
  name pools no longer exist. A present `data/npc_captains.json` fails
  validator **exit 11** (§8.6 item 1) — every captain is canon (§4.11).
- **Two people share a name** (a part-assembled draw colliding with any
  captain/officer name, zh or en) → builder refuses the draw; if a built
  file drifts into a collision, validator exit 11 (§8.6 item 5) — names
  are never reused.

## 10. Acceptance Criteria

- [ ] All artifact paths from §2 exist in the doc set's file inventory and
      match these names exactly.
- [ ] Every JSON example in this doc parses (spot-checked with a parser).
- [ ] §7 tables contain exactly 105 sovereign + 45 neutral ports / 40 goods
      / 16 ship types / 6 nations / a 96-officer roster (24 + 72, the 6
      Phase-1 starter ids locked) / 6 backgrounds / 24 equipment rows and
      only ids using the §3.1 `id` regex; every §7.1 `lat`/`lon` is a
      plausible real-world position (Lisbon ≈ 38.7°N 9.1°W, Nagasaki ≈
      32.7°N 129.9°E) and no port sits in the polar ice band (`|lat| ≥ 70`
      north, `≤ −60` south).
- [ ] Every non-ASCII display string in tables carries both zh and en.
- [ ] Every locked constant of the Phase-6 rescale (`IMPLEMENT-Phase6.md`
      §2.0–§2.4, §2.10–§2.11) with owning doc `10-*` appears exactly once in
      §6.1/§4.14–4.18 with the same value (grid, tiles per degree, sighting
      radii, ship-speed set, artifact paths, drift rates); the §6.1 save
      row pins the current version (9, no migration chain — `90-*` §8.2).
- [ ] Every locked constant with owning doc `10-*` from
      `IMPLEMENT-Phase8.md` §2.1–§2.9 appears in this doc exactly once: the
      captain card fields, generation formulas, role templates and tier
      ranges (§4.11), the name-parts source family (§4.11.1), the officers
      v2 shape with the 96 = 24 + 72 split and quota bands (§4.5, §7.5),
      the v2 named-pirate cards with `drop` preserved (§4.12, §7.8), the
      canon coverage rule (§7.7), the gate/post/background shapes with the
      locked `sail.autopilot`, post prereqs and the 6-background set
      (§4.20–4.22, §7.10), the `officer_states`/`captain_states` shapes and
      the fleet `captain_id` (§4.15), and the group-11/12 validator specs
      (§8.6–8.7).
- [ ] Every locked constant of `IMPLEMENT-Phase7.md` §2.1–§2.9 with owning
      doc `10-*` appears in this doc exactly once: the goods fields and
      40-id skeleton with the flag-driven 12/16/12 split (§4.2, §7.2), the
      16-hull list with `role`/`tier` (§4.3, §7.3), the 24-item equipment
      structure with `rare` (§4.6, §7.9), the named-pirate `drop` (§4.12),
      the port fields `band`/`protected`/`dev`/`sphere` and the
      shipyard/equipment stock lists plus the band container (§4.4, §7.1),
      and the group-3/4/5/7 validator amendments (§8, §8.2).
- [ ] Every locked constant with owning doc `10-*` from
      `IMPLEMENT-Phase5.md` (the §4.10/§4.12–4.15 schemas, the §7.6–7.8
      lists, the §8.2/§8.3 validator specs) appears in this doc exactly
      once — with the Phase-8 amendments applied (the name pools retired,
      the drop pin relocated to §8.6).
- [ ] `validate_data.py` check groups (exit 1–12) are implementable from
      §8 alone, without further design questions — including the §8.1
      group 6 world-map spec, §8.2 group 7, §8.3 group 8, §8.4 group 9,
      §8.5 group 10, §8.6 group 11, and §8.7 group 12.
- [ ] §4.16–4.18 (WindRegion/OceanCurrent/IceRegion) and §6.5 (ocean
      rasters) are implementable from this doc alone — envelope plural ==
      basename, field tables, index encodings, overlap and reversal rules —
      with no open design questions.
- [ ] §7.6 lists exactly the **21** locked lane ids (12 Phase-5 + the 5
      named Phase-6 ids + the 4 of the 2026-11-02 amendment); §7.7 pins the
      closed-canon rule (count computed at validation, §8.6); §7.8 exactly
      4 named pirates as v2 cards; §7.10 exactly 6 backgrounds; §7.9
      exactly 24 equipment items in the 2/2/2-per-slot tier structure.
- [ ] §7.3's **final** speed values use exactly the locked set
      `{16, 20, 24}` (tiles/day at 5 nm; §6.1) — the table's two 18s are
      first-pass values that task S snaps into the set within its ±20%
      budget before the exact-set lock.
- [ ] The save-block shapes of §4.15 match the `90-*` §8.1 key list
      field-for-field (carried into v9; `officer_states`/`captain_states`
      added and `named_pirate_respawns` removed at v9, `90-*` §8.1).
- [ ] The validator summary reports a port count of **105 sovereign +
      45 neutral** (the group-5 exact 150-set).
- [ ] Harbor-relief numbers (threshold 1,200, payout 100, cheapest hull 1,200)
      are consistent with §7.3 and `50-*`.
