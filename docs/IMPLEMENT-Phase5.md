# IMPLEMENT — Phase 5: Living Economy & National NPC Fleets

**STATUS: ✅ COMPLETE (2026-10-31).** All seven waves merged on `main`;
the completion record and final gate are at the bottom, and the dated
acceptance record is `tools/demo_check_phase5.md`. Rewritten from
`.kilo/plans/1793352418172-npc-fleets-economy-plan.md` after a full repo
review; the [review corrections](#review-corrections-applied-to-the-source-plan)
below are already folded in, so this document is the only source of truth.

Ordered, checkable task backlog (letters, coarse by design; **task-owned**
details are decided inside the task per the cited docs). Execute as
background-subagent waves per the plan at the bottom — **max 4 concurrent,
one git worktree per subagent, master merges and gates between waves**.
Prerequisite: Phase 4 complete (it is: 2026-10-31, plus follow-ups P1
berth/shore harbor pairs and P2 provisioning/S18 officers).

The design decisions below are normative; every number lives in the
[locked-constants tables](#locked-constants) and must be copied into the
owning system doc by the W1 doc tasks **before** any code task starts
(`00-OVERVIEW.md` §13 rule). Where this doc and an older doc disagree, this
doc wins until the owning doc is amended, after which the owning doc wins.

---

## Goal

Replace the static price factors and the 3-marker hostile-fleet system with:

1. A **stock-based supply/demand economy** — every port-good has a stock
   level; prices are a function of stock; player and NPC trades move stock;
   daily drift heals toward resting stock at tier-dependent rates.
2. **Demand events** (`data/market_events.json`) — cycled, budgeted,
   tavern-telegraphed rest-overrides that create tradeable surges.
3. **Purposeful, nation-owned NPC fleets** — ~272 persistent fleets across
   8 roles (traders, coasters, patrols, couriers, privateers, pirates,
   bounty hunters, transient wrecks) sailing a **hand-authored historical
   trade-lane network** (12 major lanes + tool-generated minor spokes), with
   runtime pathfinding reduced to pursuit-only A*.
4. **A living sea** — convoys, 4 named pirates, seasonal treasure fleets,
   abstract NPC-vs-NPC auto-resolve with lootable wreckage, tavern rumors
   from live fleet state, visible wakes, and **a named captain on every
   fleet** sightable in port facilities via seeded, visit-stable rolls.
5. **A configurable density dial** — `data/npc_config.json` budgets ×
   player-facing presets (`deserted`/`low`/`normal`/`high`/`extreme`),
   chosen on S2 and changeable mid-run in the new S19 settings modal.

Resolved with the product owner (carried from the source plan): full scope,
wave-gated and each wave mergeable; NPC-vs-NPC battles are **abstract
auto-resolve + visible wreckage** (no battle screen); trading directly with
NPC ships at sea is **out of scope**; captain sightings are **read-only
intel cards + one paid action** (tavern "buy a round" 20g → a posted
captain's exact position as rumor text); NPC fleets sail **fixed historical
routes** (minor spoke → major trunk → minor spoke), authored as historical
facts, with hunters staying lane-locked too — they navigate the junction
graph to their intel target (`60-*` §4.11.11.1).

---

## Review corrections applied to the source plan

Every correction below was verified against the repo on 2026-10-31. The
plan text already reflects the corrected values; this table is the record.

| # | Source-plan claim | Verified fact | Fix applied |
|---|---|---|---|
| 1 | "30 suites exist" | **31 suites, 5 351 checks** (post-Phase-4 follow-ups) | counts and gates updated |
| 2 | "`hostile_fleets` readers outside `encounters.gd`: `phase3_hooks.gd:197`, `quest_gen.gd:666`" | Readers are `autoload/save_system.gd` (key list, `OPTIONAL_DEFAULTS`, payload, validation, restore — 7 sites), `phase3_hooks._marker`, `quest_gen._find_marker`, `world_map.gd` via `Encounters`, **plus 10 suites** (`test_encounters`, `test_phase2_acceptance`, `test_movement`, `test_palace`, `test_quests`, `test_bounty`, `test_battle_economy`, `test_tournament`, `test_world_e2e`, `test_save`) | task J owns the whole rename with an explicit file/suite checklist; symbols are referenced by name, not line number |
| 3 | Fleet budgets "(~125 traders, ~72 coasters, ~18 patrols)", "global cap 256" | Recomputed from `ports.json`: spain 20, holland 20, portugal 18, ottoman 18, england 14, italy 10 → traders **127**, coasters **77**, patrols **19**, couriers 12, privateers 12 (6 undirected rivalry pairs × 2), pirates 8 + unpatrolled_zones (≈ 25) ⇒ core ≈ **272 > 256** — the proposed cap contradicted its own budgets | global cap pinned at **288** (272 core + 6 treasure fleets + ≤ 6 hunters + slack); extreme ≈ 1 088 core, under `absolute_cap 2048` |
| 4 | Save v5 with `MIGRATIONS[4]`; "the v4→v5 migration spawns half the cap"; "pirates keep `nation_id: ""` (save-shaped like today's markers + `role`)" | Phase 4 removed the migration chain: `save_system.gd` SAVE_VERSION 4 with "no migration chain"; `90-*` §8.2 pins dev-stage scope (only the current version must load) | **No migration.** `SAVE_VERSION = 5`, `PHASE = 5`; v4 payloads are refused like any older version. Initial fill happens at `new_game` only (decision 5) |
| 5 | "row on New Game confirm (S2) + in-game options (where the language toggle lives)" | **No options screen exists.** The locale toggle is `L` on S1/S2 plus a top-bar button; S1 hosts Load, S4 hosts Save; S18 is the highest S-number | density preset row on S2 + new **S19 settings modal** (opened from the S4 hub), both pinned in `80-*` by task C |
| 6 | Captain pools "per nation" | Pirates are nationless (`nation_id: ""`); a per-nation-only pool leaves them unnamed | `data/npc_captains.json` gets pools for the 6 nations **plus a `""` nationless pool**, ≥ 8 zh/en names each; validator enforces |
| 7 | Price factor `clamp(1.5 − 0.5 × stock/100, 0.5, 2.0)` (float) | `trade_engine.gd` is **exact per-thousand fixed point** — float factors would break its exact-arithmetic contract | factor pinned in per-thousand units: `factor_units = clamp(1500 − 5 × stock, 500, 2000)` — integer-linear, reproduces 700 / 1300 / 1000 at rest exactly |
| 8 | Consumption tiers "by `base_price` quartiles" | 20 goods ⇒ an exact split exists but boundary assignment was unspecified | rank rule pinned: sort by (`base_price` asc, `id` asc); indices 0–4 staples (±3/day), 5–14 middle (±2/day), 15–19 luxuries (±1/day); derived at load from `goods.json`, validator-asserted |
| 9 | (unaddressed) | XP profit basis is `max(0, sell − floor(base × 0.7))` (`50-*` §4.3); with dynamic buy prices the 0.7 basis is no longer the real acquisition cost | pinned **unchanged** as a metagame approximation, with an explicit clarifying sentence in `50-*` (task B) — cheapest consistent resolution, no cost-basis tracking in cargo |
| 10 | "warship wreck = `Σ floor(base_price × 0.05)` salvage gold" | `battle_rewards.gd` already owns `salvage_for(sunk_ship_type_ids)` for sunk-hull salvage | wreck salvage **reuses `BattleRewards.salvage_for`** (single implementation) instead of a parallel formula |
| 11 | Route sources: possibly vendor the flotas shapefile "if metadata confirms CC-BY" | any vendored dataset is a licensing/maintenance liability for what is needed (a dozen polylines) and subagents may have no network | **nothing is vendored**: waypoints are hand-authored as historical facts (facts are uncopyrightable), per-lane source list recorded in `LICENSE-NOTES.md`; CC-BY-ND reference-only sources stay reference-only (decision 7) |
| 12 | Monolithic W1 (6 docs + 5 data files + 12 lanes + builder + validator + loader in one task) | one task cannot parallelize; lane authoring alone is a research task | split into doc tasks A/B/C, data tasks D/E, builder task F; 12 tasks across 7 waves, peak 3 concurrent (≤ 4 cap) — see the wave table |
| 13 | (unaddressed) | `quest_gen` courier hooks "(mission flavor, 5D hooks)" had no pinned mechanics | courier quest hooks moved to **out of scope** (Phase 6); couriers this phase are behavior + sightings + rumors only |

---

## Decision record

1. **Stock-based pricing that reproduces today exactly at rest.** Each
   port-good holds stock `0 … 200`; the price factor is an integer-linear
   function of stock pinned to equal the retired static factors at resting
   stock (700/1300/1000 per thousand). All other price plumbing (0.8 sell
   margin, investment discount, title bonus, `[0.5, 2.0]` band,
   provisions/water exemption) is untouched.
2. **NPC traders are boundedly rational by pin.** They decide (good,
   destination) jointly by a profit-per-day score over **own-nation** ports
   within Chebyshev 60, using live stock prices only — no forecasting, no
   cross-nation reach, no global coordination. Cross-nation arbitrage is
   the player's protected profit space by construction.
3. **Fleets sail fixed historical lanes.** Routing is Dijkstra over the
   tool-built junction graph + walking a pre-rasterized tile path;
   per-leg runtime A* is retired. The time-budgeted A* (≤ 250 ms/day)
   survives only for hunter/pursuit chases.
4. **NPC-vs-NPC combat is abstract.** Auto-resolve + lootable wreckage at
   the site; no battle screen. Salvage reuses the existing
   `BattleRewards.salvage_for` implementation.
5. **No save migration.** Per `90-*` §8.2 dev-stage scope, Phase 5 ships
   `SAVE_VERSION = 5` and refuses v4 payloads (deviation from the source
   plan, which assumed `MIGRATIONS[4]`; the migration chain was removed in
   Phase 4 and is not reintroduced). All new state is initialized by
   `new_game`; the seeded **initial fill to half the fleet cap** happens
   there and only there.
6. **Settings get a screen.** There is no options screen today; Phase 5
   adds the density row to S2 (new game) and a new **S19 settings modal**
   over S4 housing the mid-run density control (locale stays where it is).
7. **Waypoints are facts; nothing is vendored.** The 12 major lanes are
   hand-authored `[lat, lon]` polylines recording historical routes as
   facts, with per-lane source citations in `LICENSE-NOTES.md`. No
   shapefiles, no CC-BY/CC-BY-ND dependencies, offline-friendly.
8. **Cap 288 is an ecology choice, not a performance one.** The
   architecture (cell-bucket index, zero-pathfinding lane stepping,
   viewport-culled rendering) is linear in fleet count; `absolute_cap 2048`
   and the `extreme` preset exist so "more alive" is a data edit.
9. **Sightings are stable within a visit.** Facility and presence rolls
   are seeded from `(fleet_id, port_id, arrival_day)` — no flicker on
   re-open, re-rolled next visit. Hunters appear only at the palace bounty
   board.
10. **Docs first, one wave, blocking.** Tasks A/B/C ratify every locked
    constant into the owning docs before any data/tool/code task starts.

---

## Pre-state (verified 2026-10-31)

- Autoloads: `autoload/{game_state,event_bus,data_loader,i18n,save_system}.gd`.
- `GameState.hostile_fleets` (`game_state.gd`) is the 3-marker block owned
  by `scripts/world/encounters.gd` (815 lines, `MAX_MARKERS = 3`, kinds
  `pirate`/`navy`, spawn 1%/2% per day, zone radius 15, contact Chebyshev
  1, spawn immunity 3 days, pursuit cooldown 1 day, seeded formula family
  `day × 1000003 + x × 7919 + y × 104729`). Readers/writers: `save_system.gd`
  (7 sites), `phase3_hooks._marker`, `quest_gen._find_marker`,
  `world_map.gd` (marker nodes, contact → `_open_encounter`, right-click
  attack, single piracy funnel), and the 10 suites listed in correction 2.
- Prices: `trade_engine.gd` constants `PRODUCES_FACTOR 0.7` /
  `DEMANDS_FACTOR 1.3` / `NEUTRAL_FACTOR 1.0`, exact per-thousand fixed
  point, unlimited quantity, no stock. Stale line to delete:
  `docs/30-PORTS-AND-TRADE.md` §4.4 "…(dynamic pricing OUT OF SCOPE
  (phase 3))".
- Nations (`data/nations.json`): six — `portugal`(lisbon, #1a8c4e),
  `spain`(seville, #b3191f), `england`(london, #274b8f),
  `holland`(amsterdam, #d97b1e), `ottoman`(istanbul, #6a3d9a),
  `italy`(venice, #c9a227); each exactly 2 rivals, symmetric
  (6 undirected pairs: portugal–spain, portugal–england, spain–italy,
  england–holland, holland–portugal, ottoman–italy). `ports.json`: 100
  ports with `lat/lon` — spain 20, holland 20, portugal 18, ottoman 18,
  england 14, italy 10.
- Goods (`data/goods.json`): 20, fields `id/name/unit_size/base_price`/
  `category`; sorted `base_price`:
  `[8,10,12,15,16,18,22,25,28,30,35,40,45,50,60,80,90,110,120,150]`.
- Save: `SAVE_VERSION 4`, `PHASE 4`, **no migration chain**; older payloads
  refused (`90-*` §8.2 dev-stage scope). Suites: `test_save`, `test_save_v4`.
- Combat/composition: `ai_fleet.compose_enemy` is the single composition
  implementation; `battle_rewards.salvage_for(sunk_ship_type_ids)` is the
  single salvage implementation; `bounty.apply_piracy(nation_id)` is the
  single piracy funnel (−20 owner / +2 its rivals); navy hostility at rep
  ≤ −50 (`70-*` §4.5 bounty tiers).
- World: 2160 × 1080 wrap-aware grid; click-to-sail `AStarGrid2D` within
  a 1 s budget (`20-*` §4.2); harbor berth/shore pairs in
  `world_report.json` re-derived at runtime from `ports.json` lat/lon.
- UI: S1–S18 exist (S18 = officers, added post-Phase-4). **No
  options/settings screen** — locale via `L` on S1/S2 + top-bar button; S1
  hosts Load, S4 hosts Save; the provisioning prompt is a modal over S4.
- Tests: **31 suites / 5 351 checks**, gate
  `godot --headless res://tools/test_<name>.tscn`, exit 0 = pass;
  validator `python3 tools/validate_data.py` groups 1–6 exit 0;
  `tools/build_world.py` owns the PNG raster + a small decoder
  `build_routes.py` may share.
- `day_advanced` order (`20-*` §4.3): ledger runs, then
  `EventBus.day_advanced.emit(day)`; port day-advances run the same ledger.
  The world scene ticks `Encounters` once per day (`last_tick_day` dedupe).

---

## Locked constants

The interface pin for every wave. Tasks A/B/C copy these into the owning
docs verbatim; later tasks implement to this table. Two tasks must never
derive one of these differently.

### Economy (`30-*` §4.2/§4.4 + new §4.5 demand events — task B)

| Constant | Value | Owning doc |
|---|---|---|
| Stock range | `0 … 200`, hard clamp per port-good | `30-*` §4.2 |
| Resting stock | produced 160, demanded 40, neutral 100 (derived from `ports.json` — zero new content data) | `30-*` §4.2 |
| Price factor (exact) | `factor_units = clamp(1500 − 5 × stock, 500, 2000)` per thousand; equals 700/1300/1000 at rest; price still floored once on the full product | `30-*` §4.2 |
| Consumption tiers | rank goods by (`base_price` asc, `id` asc): idx 0–4 **staples** drift ±3/day, 5–14 **middle** ±2/day, 15–19 **luxuries** ±1/day; derived at load from `goods.json` (zero new data), validator-asserted 5/10/5 | `30-*` §4.2 |
| Daily drift | toward resting stock by the tier rate, once per day tick, **after the ledger, before `day_advanced`**; runs on port day-advances too | `30-*` §4.2, `20-*` §4.3 |
| Tranche repricing | volume reprices per **10-unit tranche** (buy and sell); the market shows the **marginal (next-tranche) price**; the ledger sums tranches; NPC calls ≤ 30 units = 1–3 tranches | `30-*` §4.4 |
| NPC port-call cap | ≤ 30 units of one good per call (coasters ≤ 5, hold ≤ 10) | `30-*` §4.4 |
| Unchanged plumbing | 0.8 sell margin, investment discount, title bonus, band `[0.5, 2.0]`, provisions/water exemption, XP profit basis `floor(base × 0.7)` (metagame approximation, clarified in `50-*` §4.3) | `30-*` §4.2–4.4, `50-*` §4.3 |

### Demand events (`30-*` new §4.5 + `10-*` schema — tasks A/B)

- `data/market_events.json` (~8 templates, zh/en names):
  `{"id", "scope": "port", "cadence_days", "duration_days", "shifts":
  {"good_id": ±n}, "name": {zh, en}}`.
- Effect: `rest += shift` per good, result clamped `[10, 190]`, for
  `duration_days`; drift rates and the price formula untouched — an event
  is a temporary rest-override table inside `economy.gd` (pure).
- Templates: seasonal cycles (winter wool/furs, summer wine), one-off
  surges (harvest festival; war provisioning at a capital −30
  timber/cannons 60 days; plague = halved demand). Authored in task D.
- Budget: **≤ 1 active event per nation, ≤ 4 world-wide**; seeded schedule
  (per template × cadence window, formula family); active instances saved
  in `GameState.market_events` for exact replays.
- Telegraph: on start, a tavern rumor in the affected region's ports
  (ui_strings zh/en) — information is profit.
- Self-limiting: traders' `factor > 1.0` sell rule swarms the inflated
  port and partially refills the shortage by emergence, no clamp-pinning.

### Trader market rules (`30-*` §4.4 / `60-*` — tasks B/C)

```
score(good, P) = (est_sell_price(P, good) − buy_price) × qty × spec_mult × noise × risk
                 ───────────────────────────────────────────────────────────────────────
                                  lane_days(A → P) + 2 dwell days
```

- Joint (good, destination) argmax over own-nation produced goods ×
  candidate destinations (own-nation ports, Chebyshev ≤ 60, wrap-aware).
- `est_sell_price` = the **live** stock-based price at P (no forecasting).
- **Specialty:** `specialty: good_id` drawn at spawn from the nation's
  produced goods (fleet seed), persisted; `spec_mult = 1.5` for it; fleets
  lacking the field draw lazily from their own seed (no data migration).
- **Noise:** seeded ×`0.8 … 1.25` per decision.
- **Risk discount:** sample the candidate lane path; any hostile fleet
  within Chebyshev 5 of a sample point ⇒ `risk = 0.5` else 1.0 (one
  bucket-index query per sample, deterministic).
- **Sell rule:** sell cargo only where `factor > 1.0`; else pick the next
  candidate — never sell into a saturated market.
- **Purchase volume:** ≤ the 30-unit cap, also bounded by free hold and by
  not self-saturating the destination below `factor 1.0` within tranches.
- Not implemented (doc-only lever): the sub-linear volume knob
  `round(30/√preset)` — noted in `30-*` as a Phase-6 balance candidate.

### NPC fleet roles (`60-*` §4.1/§4.11.11 rewrite — task C)

All fleets save-shaped as `{id, role, nation_id, cell(vec2), route, cargo,
captain, specialty?, cooldown_until_day, …}`; pirates keep `nation_id: ""`.
Budgets multiply by the preset (`ceil` per role), from `npc_config.json`:

| Role | Budget (normal) | Computed @ 6 nations / 100 ports | Behavior (pin) |
|---|---|---|---|
| `trader` | `ceil(own_ports × 1.25)`/nation | 25+25+23+23+18+13 = **127** | own-nation routes via lane graph; 2-day dwell; joint profit-per-day decision; sells only where `factor > 1.0` |
| `coaster` | `ceil(own_ports × 0.75)`/nation | 15+15+14+14+11+8 = **77** | visual-life small craft; adjacent-port spokes; hold ≤ 10, trades ≤ 5/call; **never triggers contact**, raiders ignore; attacking one is ordinary piracy; loot `25 + floor(day/10)`g |
| `patrol` | `ceil(own_ports / 6)`, min 1 | **19** | cycles its nation's lanes, docking en route; same-nation traders within Chebyshev 10 count escorted; halves pirate/privateer spawn rolls in its 15-tile zone |
| `courier` | 2/nation | **12** | capital ↔ own-ports dispatch runs (sightings/rumors only — no quest mechanics this phase) |
| `privateer` | 2/undirected rivalry pair | **12** | stations on its sponsor's rivals' major lanes (chokepoint-biased); hunts only those rivals' fleets; defeating one: +2 rep with **each** of the two sponsor rivals |
| `pirate` | `8 + unpatrolled_zones` (computed daily: navy 15-tile zones lacking a patrol) | ≈ **25** | camps tagged chokepoints; prefers nearest trader/patrol within Chebyshev 10 |
| `hunter` | bounty-only, ≤ 1 per bountied nation | transient ≤ 6 | rep ≤ −50 navy hunter; stays lane-locked, navigating the junction graph to its intel target (`60-*` §4.11.11.1; the one runtime A* user) |
| `treasure` | 1/nation per season | transient ≤ 6 | see Aliveness table |
| Core cap | sum of the above at normal | **272** | + 6 treasure + ≤ 6 hunters = 284, rounded up with slack ⇒ **global cap 288** (wrecks are stored in `GameState.wrecks`, never counted) |

Flow (`npc_config.json` `flow` block): `spawns_per_day_base 4` → trickle
`max(4, ceil(cap / 50))` fleets/day; **initial fill**: `new_game` spawns
half the cap immediately (seeded, distributed on lanes near ports);
`path_budget_ms_per_day 250` for pursuit A* (overflow = lose the chase that
day); `trade_units_per_port_call 30`; `coaster_trade_units 5`;
`absolute_cap 2048`.

Spatial index: one wrap-aware **cell-bucket hash** (cell → fleet) serving
occupancy, contact, and neighborhood queries (prey-10, escort-10, patrol
zones) — every per-day check linear in fleet count. **Every "within N
tiles" check goes through the bucket index** (review gate, tasks J/K).

### Trade lanes (`10-*` schema + `20-*`/`60-*` behavior — tasks A/C/E/F)

- **Hand-authored majors** — `data/trade_routes.json`:
  `{version, lanes: [{id, class: "major", nations: [ids], waypoints:
  [[lat, lon], …], goods: [ids], chokepoints: [tags]}]}`; waypoints in
  `ports.json` lat/lon space, wrap-aware across the dateline (the Manila
  lane). Locked id set (12): `carreira_da_india`, `west_indies_flota`,
  `manila_galleon`, `venice_alexandria`, `venice_flanders`, `genoa_grain`,
  `hanseatic_north`, `aden_gujarat_malacca`, `red_sea_india`,
  `basra_muscat_india`, `iceland_cod`, `grand_banks_cod`. No Cape Horn
  (post-1616 anachronism) — Magellan Strait instead.
- **Generated feeders + tile paths** — `tools/build_routes.py` (mirrors
  `build_world.py` governance): snaps each waypoint to water (≤ 2 tiles,
  same rule as ports), walks every segment for passability, rasterizes
  every lane into a tile path, generates one **minor spoke** per port to
  the nearest lane waypoint within Chebyshev 20 (wrap-aware; fallback
  direct generated spoke to the national capital; a port with neither is a
  hard build error), and writes the tool-owned
  `data/trade_routes_built.json` (tile paths + junction graph, **never
  hand-edited**). Deterministic: rebuild byte-identical, asserted by
  validator group 8. Hand fixes via `tools/route_overrides.json` only.
- Runtime: Dijkstra over the junction graph (edge weight = tile length,
  tie-break lane id then (y, x)); fleet persists
  `route: {lanes: [ids], leg, tile_index}` — smaller than a tile path.
  Lane-locked: `trader`, `coaster`, `courier`, `treasure`. `patrol` cycles
  its nation's lanes. `pirate`/`privateer` anchor within Chebyshev 3 of
  chokepoint tiles and leave only for prey within Chebyshev 5, returning
  when prey is beyond 8 or lost (5/8 hysteresis). `hunter` stays
  lane-locked too — it sails the junction graph to its intel target
  (`60-*` §4.11.11.1). Fallback on an impossible route (validator
  makes this unreachable): one direct A* leg + logged warning.

### Auto-resolve, wreckage & player combat (`60-*` — task C)

| Rule | Pin |
|---|---|
| Raider vs unescorted trader | raider wins 60% (seeded) |
| Raider vs patrol / escorted trader / convoy | raider loses |
| Loser | despawns, leaves a `wreck` at the site; despawn after **5 days** |
| Trader wreck | its actual cargo (collect up to free capacity) |
| Warship wreck | `BattleRewards.salvage_for(hull ids)` gold (single implementation) |
| Player collect | entering the wreck tile collects (no battle) |
| Player contact (Chebyshev 1, wrap-aware) | opens battle only for `pirate` / `privateer` / `hunter`-with-bounty — exactly as today |
| Player attacks any fleet (right-click) | non-pirate owner pays `Bounty.apply_piracy` (−20 owner, +2 its rivals) **once per battle at start** (existing single funnel); loot = actual cargo + `min(1000, 100 + 10 × day)`g |
| Composition | `AiFleet.compose_enemy` unchanged; per-fleet seeded stream; kind→budget map `{"trader": 6, "coaster": 2, "courier": 0, "patrol": 30, "privateer": 20, "pirate": 20}` + `floor(day/30)` |
| Chained battles | existing §4.11.11.3 pattern preserved for hostile contacts; S10 descriptor shape unchanged |

### Aliveness & captains (`60-*`/`70-*`/`80-*` — task C)

| Feature | Pin |
|---|---|
| Convoys | same-lane traders within Chebyshev 3 render as one group with a shared escort square; auto-resolve treats a convoy as escorted |
| Named pirates | `data/named_pirates.json`: 4 captains, zh/en, tiers 1–3 (`70-*` §4.5); defeated → respawn as a new name **+30 days**; `quest_gen` bounty targets prefer named captains |
| Treasure fleets | 1/nation/season on day `45 + 15 × nation_index` (mod 90), `nation_index` = `nations.json` file order (portugal 0 … italy 5) ⇒ days 45/60/75/90/105/120; 3–5 ships + patrol escort on the nation's historical lane; loot = cargo (×3 normal volume) + `min(3000, 500 + 25 × day)`g |
| Tavern rumors | a rumor row source = live fleets within Chebyshev 40 ("an ottoman convoy left Istanbul for Alexandria") + departures/arrivals at this port within 3 days + demand-event telegraphs (all ui_strings zh/en) |
| Wakes | 5-tile dashed trail (1 px palette lines) behind moving markers |
| Captain identity | every fleet draws `captain: {"pool_id", "name_index"}` at spawn from `data/npc_captains.json` (6 nation pools + `""` nationless pool, ≥ 8 zh/en names each) via its seeded stream; names never flicker on reload; famous pirates override; a captain dies with its fleet |
| Primary facility | trader→market, coaster/patrol/courier/privateer→tavern, hunter→palace bounty board, any docked fleet→inn eligible |
| Facility roll (seeded `(fleet_id, port_id, arrival_day)`) | 60% primary, 40% uniform alternate from {market, tavern, inn} plausible sets; hunter = palace only |
| Presence roll (same seed family) | 75% sightable that day, else "gone ashore" from every facility that day |
| Wanted posters | `pirate`/`privateer` captain within Chebyshev 40 of the visited port → tavern poster row (name, tier, last-known position, reward hint) |
| Paid reveal | one tavern action per poster: "buy a round — 20g" → rumor text with the **exact live position** (tile + nearest port); text only, at-sea posters only |
| All sighting strings | `ui_strings.json` keys `captain.*`, zh/en |

### Density dial & save (`10-*`/`80-*`/`90-*` — tasks A/B/C)

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

- `GameState.npc_preset` (string, default `"normal"`): chosen on S2,
  changeable mid-run in **S19**; raising refills via trickle, lowering
  **never culls** living fleets; `deserted` = zero NPC spawns/contacts.
- Save **v5**, `PHASE 5`; new `GameState` blocks: `market_stocks
  {port_id: {good_id: int}}` (default derived 160/40/100 — no RNG),
  `npc_fleets []` (renames `hostile_fleets`), `wrecks []`,
  `npc_preset "normal"`, `market_events []`; v4 payloads refused
  (decision 5).
- New EventBus signal: `market_changed(port_id)`; battle flow reuses
  `battle_started`/`battle_finished` unchanged.
- Cap-sizing note (copy into `90-*`): normal ≈ 288 is ecology/balance, not
  performance; coasters absorb the visual traffic (≤ 5-unit trades) so
  effective long-haul trading stays ~127 fleets; far-field LOD is the
  Phase-6 lever beyond `absolute_cap`.

### Performance gates (measured in tools suites — tasks J/M)

| Gate | Pin |
|---|---|
| Day tick @ normal (cap 288) | ≤ 50 ms headless, zero runtime pathfinding for lane traffic |
| Day tick @ extreme (≈ 1 100 fleets) | ≤ 150 ms headless |
| Marginal cost | demonstrably linear (extreme ≈ 4× normal, not 16×) |
| Pursuit A* | ≤ 250 ms/day budget, overflow loses the chase |
| Save payload @ extreme | ≤ 2 MB |

---

## Tasks

### A — Amend `10-DATA-SCHEMA.md`, `90-ARCHITECTURE.md`, `00-OVERVIEW.md`, AGENTS.md (doc-first)

- **Goal:** the data contract and architecture pins for the living
  economy, on paper.
- **Docs:** this doc's locked constants; current `10-*`, `90-*`, `00-*`.
- **Changes:** `10-*` — new schemas: `npc_config.json` (presets/budgets/
  flow/absolute_cap, validator rules), `npc_captains.json` (7 pools incl.
  `""`, ≥ 8 zh/en names), `named_pirates.json` (4, tiers 1–3, i18n),
  `market_events.json` (scope/cadence/duration/shifts/i18n),
  `trade_routes.json` (locked 12-lane id set, waypoint space, chokepoint
  tags) + tool-owned `trade_routes_built.json` (never hand-edited,
  determinism rule); `market_stocks`/`npc_fleets`/`wrecks`/`npc_preset`/
  `market_events` save-block shapes; validator **group 7** (npc/economy
  data: presets ≥ 0 with a 1.0 default, `default_preset ∈ presets`,
  budgets > 0, `absolute_cap ≤ 2048`, captain pools complete i18n,
  named-pirate tiers/i18n, event scopes valid + cadence > 0 + shifts
  bounded so rest lands in `[10, 190]`) and **group 8** (trade routes:
  locked id set, waypoint snap ≤ 2 water, segment passability,
  wrap-aware continuity, per-port spoke ≤ 20 or capital fallback, junction
  connectivity, built file byte-identical). `90-*` — GameState field list
  + `EventBus.market_changed`, save v5 key list + "no migration; v4
  refused" line, §5.4 module pin `encounters.gd` → `npc_fleets.gd`,
  day-tick listener order (economy drift before `day_advanced`),
  cap-sizing note. `00-*` — §5 phase table Phase-5 row; §12 glossary: 商队/
  trade convoy, 护航舰队/escort patrol, 私掠船/privateer, 沿岸货船/coaster,
  沉船残骸/wreck, 航海密度/sea traffic, 船长/captain, 通缉令/wanted poster,
  航线/trade lane, 咽喉要道/chokepoint, 需求事件/demand event, 消费档位/
  consumption tier. **AGENTS.md** — task-backlog pointer to Phase 5;
  one line adding `trade_routes_built.json` to the tool-owned-artifact
  family ("never hand-edit", like `world.png`).
- **Done-when:** every locked constant with owning doc `10-*`/`90-*`/
  `00-*` appears there exactly once; grep finds no promise of ASCII-only
  or migration-chain requirements contradicting decision 5; no file
  outside `docs/` and `AGENTS.md` touched.

### B — Amend `30-PORTS-AND-TRADE.md`, `50-CHARACTER-AND-PROGRESSION.md` (doc-first)

- **Goal:** the economy spec, on paper.
- **Docs:** locked constants (economy, demand events, trader market
  rules); current §§4.2–4.4, §5, §7.
- **Changes:** §4.2 rewrite — stock range/resting stock/exact factor
  formula/consumption tiers/drift order/price-band interaction (the factor
  lives inside the existing `[0.5, 2.0]` band, investment/title discounts
  unchanged); §4.4 rewrite — tranche repricing algorithm with a worked
  300-unit example, marginal-price display rule, NPC caps + purchase-volume
  bounds, the joint profit-per-day trader decision formula with specialty/
  noise/risk pins; **new §4.5 demand events** (schema pointer, budget,
  telegraph, self-limiting note); §5 worked examples re-derived at rest
  (must still produce today's numbers) + one displaced-stock example;
  delete the stale "dynamic pricing OUT OF SCOPE (phase 3)" line (keep
  §4.3's wider-investment-effects deferral — that's Phase 6);
  `50-*` §4.3 — one clarifying sentence: the `floor(base × 0.7)` profit
  basis is a locked metagame approximation, not the dynamic acquisition
  cost.
- **Done-when:** resting examples reproduce 0.7/1.3/1.0 numerically in the
  doc; the 300-unit tranche example walks ≥ 5 tranche prices without a
  clamp jump; every economy locked constant appears exactly once; grep
  finds no remaining "OUT OF SCOPE (phase 3)" dynamic-pricing line.

### C — Amend `20-WORLD-AND-SAILING.md`, `60-COMBAT.md`, `70-*.md`, `80-UI-UX.md` (doc-first)

- **Goal:** the fleet/ecology/UI spec, on paper.
- **Docs:** locked constants (roles, lanes, auto-resolve, aliveness,
  captains, density, perf); current §§.
- **Changes:** `20-*` §4.3 day-tick order (ledger → economy drift/events →
  `day_advanced` → npc tick), §4.11 sighting of NPC fleets unchanged at
  port radius rules, lane-behavior summary pointer; `60-*` §4.1 + §4.11.11
  full rewrite (roles/budgets/lane routing/auto-resolve/wreckage/loot/
  piracy funnel/chokepoint hysteresis/convoys/treasure fleets/named
  pirates/captain seeds/perf gates), §4.12.3 API table rewritten for
  `npc_fleets.gd` (spawn, tick, markers, contacts, collect, reset_rng …)
  with the guard-call convention; `70-*` §4.5 bounty tiers cited for
  named pirates + privateer rep effects; `80-*` — S2 density row,
  **new S19 settings modal** (over S4; density control + locale pointer),
  market screen stock + trend + marginal-price column wireframe, world-map
  role markers (nation-colored squares, wreck icon, wakes), chart lane
  heat dots (optional flag), captain sighting surfaces (market rows,
  tavern captains + wanted posters + 20g reveal, inn list, palace board)
  with seeded-roll semantics, `captain.*` + `settings.*` + `market.stock.*`
  ui_strings key families (zh/en).
- **Done-when:** cross-doc consistency greps clean (role names, budget
  formulas, S19 nav graph entry, hysteresis 5/8, treasure schedule); the
  §4.12.3 table names exactly the symbols task J implements; no
  `Encounters` API row survives outside the historical record.

### D — Npc/economy data files + validator group 7 + loader

- **Goal:** content data for fleets, captains, pirates, events — green.
- **Docs:** `10-*` schemas as amended (A); locked constants.
- **Creates:** `data/npc_config.json` (locked block above),
  `data/npc_captains.json` (7 pools × ≥ 8 zh/en names; era-plausible per
  nation), `data/named_pirates.json` (4, tiers 1–3, zh/en),
  `data/market_events.json` (~8 templates per the locked families, zh/en);
  validator group 7 in `tools/validate_data.py`; `data_loader.gd`
  registrations.
- **Done-when:** validator exit 0 with group 7 active; every zh/en name
  complete; each event template's worst-case rest shift lands in
  `[10, 190]` (asserted); all 31 existing suites still green (data-only
  change + loader registrations).

### E — Author the 12 historical lanes + source notes

- **Goal:** `data/trade_routes.json` as historical facts, fully cited.
- **Docs:** `10-*` schema (A); locked lane id set.
- **Creates:** `data/trade_routes.json` — the 12 lanes, each with
  nations/goods/chokepoints and a `[lat, lon]` waypoint polyline real
  ships could follow at 10 nm resolution (dateline-crossing segments for
  `manila_galleon` keep monotonic x under wrap); `tools/route_overrides.json`
  skeleton (`{"overrides": []}`); per-lane source records appended to
  `LICENSE-NOTES.md` (waypoints authored as historical facts; reference
  list per lane — global sea-route geodatabases, historical atlases,
  OWTRAD-style sources; **nothing vendored**, no CC-BY-ND).
  Waypoint coordinates are **task-owned data** (like the Phase-4 §7.1
  transcription); historical grounding is the review criterion, not a
  checksum.
- **Done-when:** all 12 locked ids present with plausible paths (each
  lane's endpoints connect the ports its `nations`/`goods` imply; spot
  facts: Carreira rounds the Cape of Good Hope; the flota links
  Seville/Havana/Veracruz; Manila links Manila–Acapulco across the
  dateline; Hanseatic links Bergen–London–Bruges–Baltic); every lane has
  ≥ 1 chokepoint tag; JSON parses under the A schema (self-check script or
  D's group-7-style dry run); no file outside the three created touched.

### F — `tools/build_routes.py` + built artifact + validator group 8

- **Goal:** deterministic rasterized lanes + junction graph + spokes.
- **Docs:** `10-*` schema (A); locked constants (snap/spoke/determinism).
- **Creates:** `tools/build_routes.py` (water-snapping ≤ 2 with the locked
  smallest-(y, x) tie-break, per-segment passability walk, tile-path
  rasterization, one minor spoke per port within Chebyshev 20 wrap-aware
  else capital fallback, junction-graph extraction, `--ascii` debug export,
  `--report` JSON; may share `build_world.py`'s PNG decoder);
  `data/trade_routes_built.json` (tool-owned); validator group 8 —
  determinism re-check (rebuild byte-identical), connectivity (every port
  reaches every lane it needs via the junction graph), wrap-aware segment
  continuity. `data_loader.gd` registration for the built artifact.
  **Lane fixes belong here** (via `route_overrides.json`; minimal
  waypoint edits to E's file allowed and must be reported per lane).
- **Done-when:** two rebuilds byte-identical; validator exit 0 with group
  8; every port has a spoke; named probes pass (acapulco/manila link under
  wrap, hanseatic reaches danzig, carreira reaches goa); failures
  (landlocked waypoint, broken segment) exit non-zero naming the lane;
  all 31 suites still green.

### G — Economy core + save v5 (keeps `hostile_fleets` untouched)

- **Goal:** stock pricing live in the market; state shape ready for J.
- **Docs:** `30-*` §4.2/§4.4 as amended (B); `90-*` save pins (A).
- **Changes:** new `scripts/port/economy.gd` (pure: stock init 160/40/100,
  tier table derived from `goods.json`, per-tier drift, apply-trade with
  10-unit tranche repricing, `factor_units(port_id, good_id)`,
  rest-override table + expiry — the hook events plug into, rotation
  itself lands in L); `trade_engine.gd` — static factors replaced by
  `Economy.factor_units` (margin/discount/title/band plumbing and exact
  fixed-point contract untouched), quantity limits unchanged
  (buy/sell now walk tranches; per-tranche prices summed exactly);
  market screen — stock + trend column + marginal-price display (ui_strings
  keys listed for the master); `GameState` — new blocks `market_stocks`,
  `wrecks`, `npc_preset`, `market_events` (init at `new_game`; stocks
  derived, no RNG);
  `save_system.gd` — `SAVE_VERSION := 5`, `PHASE := 5`, new keys in the
  payload/defaults/validation, **`hostile_fleets` key kept as-is** (J owns
  its rename); `event_bus.gd` — `market_changed(port_id)`; day-tick
  wiring per `20-*` §4.3 (drift after the ledger, before `day_advanced`,
  on port day-advances too).
- **Tests:** new `tools/test_economy.tscn`; rework `test_trade`
  (rest-price reproduction, tranche walks, drift tiers, band/cap edge
  cases), `test_save` key updates, rename `test_save_v4` → `test_save_v5`
  with v4-refused expectations updated (v4 refused, like v3 today).
- **Done-when:** resting prices reproduce 0.7/1.3/1.0 **exactly**;
  scripted: buying 100 wine moves the port's price; a staple heals a
  30-unit nudge in 10 days and a luxury in 30 (tiers demonstrably
  differ); a 300-unit sale walks the price down per tranche without
  jumping to the clamp; a v4 save is refused with the standard message;
  `market_changed` fires on trades; validator + all suites green.

### H — (absorbed)

> Task letter held: the standalone "save/migration" task from the source
> plan is absorbed into G (fields/keys) and J (the `hostile_fleets` →
> `npc_fleets` rename), per decisions 3–5. No H task exists.

### I — (absorbed)

> Task letter held: the source plan's monolithic W1 validator/loader work
> is split across D (group 7 + registrations) and F (group 8 + built-file
> registration). No I task exists.

### J — NPC fleet core: `npc_fleets.gd` + the great rename

- **Goal:** the living-sea simulation replaces the 3-marker system.
- **Docs:** `60-*` §4.1/§4.11.11/§4.12.3 as amended (C); locked constants;
  `30-*` trader rules (B).
- **Creates:** `scripts/world/npc_fleets.gd` (pure RefCounted, the §4.12.3
  API table exactly): role model, budget computation from `npc_config` ×
  live `npc_preset` (ceil per role), seeded **initial fill to half cap** at
  `new_game` + daily trickle, wrap-aware **cell-bucket spatial index**
  (all "within N tiles" queries route through it), **lane routing**
  (Dijkstra over the built junction graph + polyline tile-walk stepping;
  pursuit A* only, ≤ 250 ms/day budget), port dwell (2 days) + the pinned
  trader market rules against `economy.gd` (specialty ×1.5 persisted,
  seeded noise ×0.8–1.25, risk ×0.5 via bucket query, `factor > 1.0` sell
  walk-away, ≤ 30-unit cap), captain + specialty seeded draws persisted in
  the fleet dict, contact API, pursuit cooldown semantics carried over,
  `reset_rng` test seam.
- **Rename sweep (the whole point of one wave):** `hostile_fleets` →
  `npc_fleets` with `kind` → `role` mapping (`pirate`→`pirate`,
  `navy`→`hunter`) in: `game_state.gd`, `save_system.gd` (key + defaults +
  validation + payload + restore), `phase3_hooks.gd`, `quest_gen.gd`,
  `world_map.gd` (marker adoption/sync, contact → `_open_encounter`,
  right-click attack — minimal wiring to keep today's battle behavior),
  and the 10 suites (correction 2); delete `scripts/world/encounters.gd`;
  rework `test_encounters` → `tools/test_npc_fleets.tscn` (spawn budgets
  per role, lane-route determinism: same seed ⇒ same lanes + positions,
  bucket-index occupancy, trader decision cases, captain persistence).
- **Done-when:** day tick ≤ 50 ms headless @ cap 288 with **zero** runtime
  pathfinding for lane traffic; given a near+thin and a far+fat demanding
  port the trader picks the higher per-day score; two same-nation traders
  with different specialties buy different goods in identical markets; a
  scripted sequential 5-trader herd on one good reroutes #4 and the
  port-good stays within ±30 of rest after drift; a trader avoids a
  pirated lane when an equal alternative exists; no trader ever sells into
  a `factor ≤ 1.0` market; coasters trade ≤ 5 units, never open contact,
  and are ignored by raiders; markers never step onto land/occupied tiles;
  every nation's marker color reachable on its own lanes; save/load
  reproduces fleet positions, route legs, specialties, captain names
  exactly; grep for `hostile_fleets`/`encounters.gd` in `scripts/` +
  `autoload/` + `tools/` returns only historical doc/prose mentions;
  validator + all suites green.

### K — Ecology & combat integration

- **Goal:** NPC-vs-NPC resolution, wreckage, escorts, chokepoints, and the
  player's combat surface over the new fleets.
- **Docs:** `60-*` auto-resolve/loot/chokepoint tables (C).
- **Changes:** `npc_fleets.gd` — seeded auto-resolve (60% rule), wreck
  lifecycle (spawn on loss, 5-day despawn, contents per the locked table),
  patrol escort effects (escorted-within-10 via bucket index), privateer
  rival-only targeting, pirate/privateer chokepoint camping with 5/8
  hysteresis, wreck clustering emerging on lanes; `world_map.gd` —
  wreck markers + collect-on-entry (cargo up to free capacity, salvage via
  `BattleRewards.salvage_for`), right-click attack on **any** fleet through
  the single piracy funnel (charge once at battle start; privateer-sponsor
  nation penalties chained correctly), chained battles preserved; suites —
  fixture updates where marker shapes changed (`test_bounty`,
  `test_battle_economy` must stay green with **only** fixture updates; S10
  descriptor shape unchanged) + new `tools/test_ecology.tscn`.
- **Done-when:** raiders measurably deplete unescorted traders over seeded
  runs while escorted lanes stay traffic-healthy; sitting near a tagged
  chokepoint yields regular sightings and open sea stays quiet; killing a
  trader triggers −20/+2 rep + the bounty path (`test_bounty` green);
  wreckage salvage works and expires at 5 days; privateer defeat pays +2
  with both sponsor rivals; validator + all suites green.

### L — Aliveness, market events & captain sightings

- **Goal:** the visible/auditable life layer — convoys, named pirates,
  treasure fleets, rumors, demand events in rotation, sightings.
- **Docs:** locked aliveness/captains tables; `80-*` surfaces (C).
- **Changes:** `npc_fleets.gd` (this wave's owner) — treasure-fleet
  seasonal scheduler + named-pirate respawn (+30 days, new name);
  convoy grouping rule (auto-resolve already escorted — done in K; this is
  render + query); new pure query module `scripts/world/npc_intel.gd`
  (sightings by port/facility with the seeded 60/40 + 75% rolls, wanted
  posters within 40, exact-position lookup for the paid reveal, rumor row
  sources); `economy.gd` extension — event rotation (seeded schedule,
  ≤ 1/nation ≤ 4 world, rest-overrides + expiry, telegraph hook) with
  `GameState.market_events` persistence; screens — market "merchant
  captains in port" rows, tavern captains section + wanted posters + 20g
  reveal + live-fleet/departure/event rumor rows, inn "captains resting",
  palace bounty-board hunter captains; `world_map.gd` — wakes, wreck icon
  cosmetics, convoy group render; chart lane heat dots (the optional
  `80-*` flag — implement if the wave has slack, else flag stays off);
  `quest_gen.gd` bounty targets prefer named captains; new suite
  `tools/test_aliveness.tscn`; ui_strings keys listed for the master.
- **Done-when:** a treasure fleet sails its historical lane on schedule
  and is interceptable; a bounty quest can target a named captain; rumor
  text reflects real fleet/event state (zh/en); a demand event runs
  end-to-end (rumor telegraph → prices surge → arriving traders soften
  the shift → rest restores after expiry); a docked trader's captain
  appears at that port's plausible facilities; a pirate within 40 tiles
  has a poster and paying 20g returns its exact live position (verified
  against `npc_fleets`); captain names survive save/load; sighting rolls
  are stable within a visit-day, vary across visits/days, and a hunter
  never appears outside the palace board; validator + all suites green.

### M — Density dial UI + perf proof

- **Goal:** the player-facing dial and the measured scaling claim.
- **Docs:** `80-*` S2 row + S19 (C); locked density/perf tables.
- **Changes:** `nationality_select` (S2) density row feeding
  `GameState.npc_preset` before `new_game`; new
  `scenes/ui_shared/settings_panel.tscn` (**S19**, modal over S4, opened
  from the S4 hub): preset selector applying mid-run (raise → trickle
  refills; lower → no culling; `deserted` → spawns stop); ui_strings
  `settings.*` keys listed for the master; new `tools/test_density.tscn` —
  preset round-trip through save/load, initial-fill count ≈ half cap @
  normal, mid-run raise/lower semantics, perf runs at normal cap 288
  (≤ 50 ms/tick) and extreme (≈ 4× budgets; ≤ 150 ms/tick) with the full
  ecology running, per-fleet marginal cost ≈ linear (extreme ≈ 4× normal),
  save payload ≤ 2 MB @ extreme.
- **Done-when:** switching `deserted` → `extreme` mid-run visibly
  repopulates over days; `deserted` yields zero NPC contacts; all strings
  zh/en; the three perf gates pass and their numbers are recorded in the
  task report; validator + all suites green.

### N — Phase-5 acceptance (orchestrator-led)

- **Goal:** the phase definition of done + completion record.
- **Docs:** everything above; `00-*` §7 demo loop.
- **Creates:** `tools/demo_check_phase5.md` — dated manual run, zh and en,
  of the demo loop plus the Phase-5 checks: anchor at Lisbon 10 days →
  ≥ 5 fleet sightings (mixed flags + coasters); loiter at a tagged
  chokepoint → repeated sighting/ambush chances; top-demand good's price
  moves within a season; sink a trader → patrol reroute/privateer pressure
  visible; ride one demand event end-to-end (read rumor → buy cheap nearby
  → sell into the surge → profit); 30 days of pirating @ `extreme` doesn't
  run away the gold curve; sight a captain in port, pay 20g, verify the
  position against the map; S2 → S19 round-trip of the density dial.
- **Done-when:** `python3 tools/validate_data.py` exit 0 incl. group 8
  determinism; all suites (existing reworked + `test_economy`,
  `test_npc_fleets`, `test_ecology`, `test_aliveness`, `test_density`)
  green with suite/check counts recorded; `godot --headless --quit-after 3`
  clean; zero `<key>` fallbacks zh/en; world.png unchanged; this file's
  completion record filled in.

---

## Task dependency note

A/B/C unblock everything (pure docs; nothing launches before W1 merges).
D and E need A (schemas). F needs E (lanes) + A; G needs A + B. J needs
F (built artifact) + G (economy API) + C; J is the critical path and the
only merge that may turn suites red inside its worktree — it merges green.
K and M need J (M's perf gates are meaningless without the full ecology,
so M follows K — see waves). L needs J + K (escort rule, wreck lifecycle)
+ G. N needs all.

The critical path is A/B/C → D/E → F/G → J → K → L → N: **seven waves**.
Parallelism peaks at 3 concurrent subagents (W1); the fourth worktree slot
stays free for master-side merge verification or an ad-hoc fix.

## Shared-file pins (hard rule: one writer per file per wave)

- **W1:** A owns `docs/10-*`, `docs/90-*`, `docs/00-*`, `AGENTS.md`;
  B owns `docs/30-*`, `docs/50-*`; C owns `docs/20-*`, `docs/60-*`,
  `docs/70-*`, `docs/80-*`. Disjoint.
- **W2:** D owns `data/npc_config.json`, `data/npc_captains.json`,
  `data/named_pirates.json`, `data/market_events.json`,
  `tools/validate_data.py` (group 7), `autoload/data_loader.gd`;
  E owns `data/trade_routes.json`, `tools/route_overrides.json`,
  `LICENSE-NOTES.md`. Disjoint.
- **W3:** F owns `tools/build_routes.py`, `data/trade_routes_built.json`,
  `tools/validate_data.py` (group 8 — sequential to D's W2), one
  `data_loader.gd` registration, and any lane fixes (`route_overrides.json`,
  minimal reported `trade_routes.json` edits); G owns `scripts/port/**`,
  `autoload/{game_state,save_system,event_bus}.gd`,
  `scenes/port/market_screen.*`, `tools/test_economy.*`, `tools/test_trade.*`,
  `tools/test_save*.gd/.tscn`. Disjoint; the only shared directory is
  `tools/` with disjoint files.
- **W4:** J owns `scripts/world/npc_fleets.gd` (new),
  `scripts/world/encounters.gd` (delete), `scenes/world/world_map.gd`,
  `autoload/game_state.gd`, `autoload/save_system.gd`,
  `scripts/quests/{phase3_hooks,quest_gen}.gd`, `tools/test_npc_fleets.*`
  and every suite in correction 2. Single-task wave — no conflicts.
- **W5:** K owns `scripts/world/npc_fleets.gd`, `scenes/world/world_map.gd`,
  `tools/test_ecology.*`, `tools/test_bounty.*`, `tools/test_battle_economy.*`.
  Single-task wave.
- **W6:** L owns `scripts/world/npc_fleets.gd` (scheduler sections),
  `scripts/world/npc_intel.gd` (new), `scripts/port/economy.gd` (rotation
  section), `scenes/port/{market,tavern,inn,palace}_screen.gd`,
  `scenes/world/{world_map,chart_screen}.gd`, `scripts/quests/quest_gen.gd`,
  `tools/test_aliveness.*`; M owns `scenes/title/*`,
  `scenes/ui_shared/settings_panel.*` (new), `scenes/port/port_screen.gd`
  (S19 entry point only), `tools/test_density.*`. One file is adjacent —
  `port_screen.gd` (M) vs `tavern_screen.gd` etc. (L) — disjoint.
- **`data/ui_strings.json` is orchestrator-owned** (Phase-4 protocol):
  every task lists its zh/en keys in its report; the master merges after
  each wave. No subagent edits it directly.

## Subagent execution plan (max 4 background subagents, one worktree each)

Same protocol as Phases 3–4: the master owns the base branch, creates and
removes one named worktree per subagent (`tools.opencode.worktree_create`),
launches tasks as background subagents with full context prompts, merges
every branch itself, runs the validator + full suite between waves, and
pins **task-owned** numbers in the owning doc before launch (the
Phase-2/3 lesson).

| Wave | Tasks (parallel) | Gate to advance (after merge) |
|---|---|---|
| W1 | A, B, C | docs greps per each task's done-when; tree otherwise untouched |
| W2 | D, E | validator exit 0 (groups 1–7); all 31 suites green |
| W3 | F, G | validator exit 0 (groups 1–8, incl. determinism); all suites green (`test_save_v5`) |
| W4 | J | validator exit 0; all suites green (rename sweep complete); tick ≤ 50 ms @ 288 |
| W5 | K | validator exit 0; all suites green (`test_bounty`, `test_battle_economy` fixture-only changes) |
| W6 | L, M | validator exit 0; all suites green; perf gates recorded; zh/en key parity |
| W7 | N | acceptance record + completion record in this file |

- **No sanctioned red window.** Unlike Phase 4, no wave may merge with any
  red check: D/E ship data+validator together, F ships the built artifact
  with its group, G keeps `hostile_fleets` untouched, and the rename blast
  radius (J) is contained in one worktree until green. This is deliberately
  stricter than Phase 4's W3 window.
- W4 and W5 are single-task waves by dependency: J is on every later path
  and K alone owns the combat surface; W2/W3/W6 pair up disjoint owners.
- The fourth worktree slot is reserved for master-side merge verification
  or an ad-hoc repair task — never for a fifth content task mid-wave.
- Subagent prompts must carry: this file's path, the task letter, its docs,
  the locked-constants pointer, the done-when list, the shared-file
  ownership list, and the wave gate. Numbers not in the locked tables are
  invented by no one (the §13 rule applies to subagents first).
- N is orchestrator-led (dated manual run), as in every phase.

## Risks & pinned mitigations

| Risk | Mitigation (pinned here, verified in done-when) |
|---|---|
| Pursuit A* cost at scale | only hunters/pursuers pathfind; 250 ms/day budget, overflow loses the chase (J) |
| Day-tick cost in GDScript | cell-bucket index keeps every query linear; measured 50/150 ms gates + linear-cost proof (J, M) |
| Naive O(N²) neighbor scans sneak in | every "within N tiles" check through the bucket index — code-review gate (J, K) |
| Lane crosses land at 10 nm resolution | build-time waypoint snapping ≤ 2 + per-segment passability walk + `route_overrides.json`; validator fails loudly (E, F) |
| Port unreachable from the lane network | spoke ≤ 20 or capital fallback is a hard build/validator error, never a runtime stall (F) |
| Route source licensing | waypoints authored as historical facts, sources cited, **nothing vendored**; CC-BY-ND sources reference-only (E) — licensing risk eliminated, not managed |
| Lane authoring needs the open internet | authoring-from-facts is offline-friendly; sources are citations, not downloads (E) |
| Save size at high caps | wrecks outside the fleet cap; composed data via seeds (captain = `{pool_id, name_index}`); ≤ 2 MB @ extreme gate (M) |
| NPC arbitrage kills player margins | boundedly rational by pin (own-nation ≤ 60, live-stock pricing, no forecasting); 30-unit cap; raiders reopen spreads; sub-linear knob documented as Phase-6 lever only (B, J) |
| Trader herding pins a port-good | five layers: per-nation candidates → persisted specialty ×1.5 → seeded noise ×0.8–1.25 → tranche self-correction + `factor > 1.0` walk-away → spawn/dwell desync; rest clamps `[10, 190]`; scripted herding done-when (J) |
| Event spam / overlap | ≤ 1 per nation, ≤ 4 world-wide; shifts bounded; active list saved for deterministic replays (L) |
| Static-factor suites break on the economy swap | G reworks `test_trade` in its own wave; rest-price reproduction is the done-when anchor (G) |
| The rename blast radius (12+ files, 10 suites) exceeds one task | correction 2's explicit checklist is J's contract; single-task wave; merges only when green (J) |
| Dynamic prices break XP/rep maths that assume 0.7/1.3 | XP basis pinned unchanged as a metagame approximation (`50-*` sentence); title/discount plumbing untouched (B, G) |
| Settings screen scope creep | S19 hosts exactly the density control + a locale pointer this phase (C, M) |
| Treasure-fleet/piracy gold runaway | loot pins are capped (`min(1000, …)` / `min(3000, …)`); N manually runs the 30-day piracy curve @ extreme |
| Save determinism under seeded systems | all streams seeded (formula family); compositions reproducible; preset saved; W4/W6 save-load done-whens verify byte-level reproduction (J, L) |

## Out of scope (Phase-6 candidates)

Watchable AI-vs-AI battle screens; trading with NPC ships at sea (owner
decision); full captain interactions (bribes, escort deals, recruiting);
chart ping/marker for the paid reveal (text only); courier quest hooks (L
ships behavior + sightings + rumors only); dynamic diplomacy/war-peace
(static `rivals` is a locked simplification); far-field LOD beyond
`absolute_cap`; NPC provisions/weather consumption; seasonal/monsoon lane
variants (pairs with the Phase-5-candidate monsoon layer once scheduled —
same month-indexed mechanism); investment → demand growth (Tier 3; `30-*`
§4.3's deferral stands); the sub-linear `round(30/√preset)` volume knob
(documented lever, not implemented); hand-editing
`trade_routes_built.json` or generated spokes (source JSON + overrides
only, mirroring the `world.png` rule).

---

## Completion record

*(Filled in by task N. Run 2026-10-31, `main` at `2c0d31f`+; see
`tools/demo_check_phase5.md` for the full acceptance record.)*

| Wave | Tasks | Result |
|---|---|---|
| W1 | A, B, C | ✅ docs ratified: 5 new data schemas + save v5 pins (`10-*`/`90-*`/`00-*`/AGENTS.md); stock economy + tranche + demand-event spec (`30-*`/`50-*`); fleet/ecology/UI spec incl. S19 + `npc_fleets.gd` API (`20-*`/`60-*`/`70-*`/`80-*`). Gate: cross-doc greps clean, tree untouched outside docs. |
| W2 | D, E | ✅ 4 npc/economy data files + validator group 7 (12 negative tests) + loader; 12 historical lanes (415 waypoints, raster-verified) + `LICENSE-NOTES.md` + empty overrides. Gate: validator groups 1–7, 31 suites green. |
| W3 | F, G | ✅ `build_routes.py` + 767 KB built artifact (769 nodes/805 edges, 47 documented spokes + 1 capital fallback, 100/100 ports) + validator group 8 with rebuild byte-equality; pure `economy.gd` + tranche-walking trade engine + save v5 + `market_changed` + market columns; new `test_economy`, reworked `test_trade`, `test_save_v5`. Gate: groups 1–8, all suites green. |
| W4 | J | ✅ `npc_fleets.gd` (8 roles, budgets × preset, half-cap initial fill, cell-bucket index, Dijkstra lane stepping, seeded trader rules, captains) + `fleet_path.gd`; full `hostile_fleets`→`npc_fleets` rename sweep (16 files, 10 suites, `encounters.gd` deleted); hunter-intel amendment (lane-bound hunters, 15/20 hysteresis, persisted intel keys); 290-check suite. Gate: 32/32 green, tick 9–16 ms @ 272. |
| W5 | K | ✅ seeded 60% auto-resolve, wreck lifecycle (5-day, `salvage_for` reuse), escort/convoy/patrol protection, privateer rival-only targeting, chokepoint 5/8 hysteresis, collect-on-entry, any-fleet piracy funnel + sponsor-rival rep chain; fixed a latent head-on stepping deadlock; coaster loot pin reconciled. Gate: 33/33 green. |
| W6 | L, M | ✅ L: treasure scheduler (45/60/75/90/105/120), named pirates + persisted +30-day respawns, `npc_intel.gd` sightings/posters/20g reveal/rumors, demand-event rotation + telegraphs, wakes, convoys, port-log; L follow-up reconciled from stray main-tree edits (save key `named_pirate_respawns`, transient wake/log state, load-time override re-apply). M: S2 density row, S19 settings modal, `new_game` preserves the S2 preset, `test_density` perf proof (17/69 ms, 0.95 MB). Gate: 35/35 green. |
| W7 | N | ✅ acceptance record `tools/demo_check_phase5.md`; final gates below. |

### Final gate

| Check | Result |
|---|---|
| `python3 tools/validate_data.py` | **exit 0** — groups 1–8 PASS |
| `python3 tools/build_routes.py` (rebuild) | **exit 0** — rebuild byte-identical (`--check`) |
| suites | **35 suites / 6 008 checks, 0 failures, 0 zombie/hang** (`tools/run_tests.py`, 160 s) |
| `godot --headless --quit-after 3` | exit 0, zero `SCRIPT ERROR` |
| day tick @ normal 288 / @ extreme | **15.9 ms avg / 26.9 ms worst** (≤ 50) / **69 ms** @ ≈990 fleets (≤ 150); near-linear |
| locale (zh/en) | **448 ui_strings keys, 0 bad** (validator-enforced placeholder parity) |
| `data/maps/world.png` | **unchanged** (0 diff since the plan commit) |
| save payload @ extreme | **953 401 B / 0.91 MB** (≤ 2 MB) |
