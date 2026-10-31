# 20 — World & Sailing

## 1. Purpose & Phase

Specifies the tile-grid world model, movement, the game clock and daily
ledger, consumption (provisions/water/wages), morale with mutiny/desertion,
weather and storms, sea-death fail states, port discovery and entry/exit,
minimap and Chart behavior. Gates Phase 1 and Phase 4 (the real-Earth grid,
latitude weather bands, click-to-sail); Phase 2 combat reuses the map and
movement constants unchanged. Phase 5 amends §4.3 (day-tick order: the
economy step and the NPC fleet tick) and §4.11 (NPC fleet markers). Phase 6
amends §4.1 (grid rescale), §4.2 (input modes + interpolated rendering), §4.4
(the direction-aware speed pipeline) and §4.7 (the wind-direction roll),
re-pins the sighting/discovery radii at the 5 nm grid (48/36), and replaces
§4.13 with the real §§4.14–4.18 (prevailing winds, calendar, ocean currents,
sail trim & wait, seasonal sea ice).

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/world/world_map.tscn` | sailing scene: chunked TileMaps + fleet marker + HUD |
| `scenes/world/chart_screen.tscn` | full-screen whole-world Chart (S17, `80-*` §4.6) |
| `scripts/world/sailing_sim.gd` | movement, clock, daily ledger, weather, morale |
| `scripts/world/sail_path.gd` | click-to-sail `AStarGrid2D` pathing (§4.2, task H) |
| `scripts/world/map_loader.gd` | PNG world → chunked TileMaps (spec in `90-ARCHITECTURE.md` §9) |
| `scripts/world/ocean_layers.gd` | Phase-6 ocean-layer lookups: wind-region id, current vector (with reversal flip), month-keyed ice cache (schemas `10-*` §6.5) |
| `data/maps/world.png` | the single Terra Vera world map (artefact spec `10-*` §6.3, built by `tools/build_world.py`) |
| `data/wind_regions.json` | region × month prevailing-wind table (hand-authored, cited; envelope schema `10-*`) |
| `data/ocean_currents.json` | ~20 hand-authored current systems (strength 1–3, lat/lon paths, Somali reversal) |
| `data/ice_regions.json` | seasonal sea-ice polygons (Baltic, Hudson Bay, White Sea) |
| `data/maps/wind_regions.png` | baked wind-region raster (tool-owned, `tools/build_ocean.py`, never hand-edited) |
| `data/maps/currents.png` | baked current raster (tool-owned; annual-mean vectors, reversal applied at lookup) |
| GameState keys | `day`, `world.position`, `world.map_id` (always `"world"`), `world.weather`, `world.sail_trim`, `world.heading`, `world.wind_dir`, `known_ports`, `control_prefs`, morale/crew state inside `fleet` (schema in `40-*`) |

## 3. Dependencies

`00-OVERVIEW.md`, `10-DATA-SCHEMA.md` (esp. §6 map constants and §6.5 ocean
layers), `90-*` (scene
pattern, §9 loader), `40-*` (fleet/cargo schema), `50-*` (stat effects on
speed), `80-*` §4.5/§4.6 (HUD crop and Chart), `30-*` §4.2/§4.5 (the economy
drift/events the day tick orders), `60-*` §4.11.11 (the NPC fleet tick and
its Phase-6 parity factors).

## 4. Systems / Mechanics

### 4.1 Grid & coordinates

- World grid: `map_legend.json#grid` = **4320 × 2160** tiles — the whole globe
  at 12 tiles per degree (`10-*` §6.1); `TILE_SIZE_PX` = 32 (unchanged); one
  tile = **5 nm**. Addressing: `lon = x/12 − 180`, `lat = 90 − y/12`; origin
  top-left, `x` east, `y` south.
- **Longitude wraps.** `x` is taken mod 4320 everywhere (movement, BFS,
  camera, click); a fleet at `x = 4319` stepping east lands on `x = 0`. This is
  a single map: `GameState.world["map_id"]` exists and is always `"world"`
  (`90-*` §5.4), and no sailing code branches on it.
- **Latitude edges are impassable:** a tile is `I` (polar ice) iff
  `lat ≥ 70°N` or `lat ≤ 60°S`, so the fleet can never leave the grid
  north/south.
- The fleet occupies exactly one tile (`GameState.world.position`).
- Tile kinds `~ . # ^ I` (`10-*` §6.2): `sea ~` and `coastal_sea .` passable;
  `land #`, `reef ^` and `polar ice I` block. Passability comes from the
  decoded PNG's palette index (index 0–4 → `~ . # ^ I`).
- Ports are an **overlay**, not map characters: their berth tiles are water
  and passable, their shore tiles are the land tile the port is drawn on and
  docked into (§4.11.1).

### 4.2 Movement

Player movement has two input modes, chosen by the persisted setting
`control_prefs.input_mode` — `step` (default) or `helm` (`control_prefs` is
S19-only, `80-*` §4.6.3; persisted per save like `npc_preset`, save v6). The
rules are identical in both modes — a step is a step wherever it comes from;
the modes differ only in what produces the steps.

- **Step mode (default) — today's behavior verbatim:** 8-directional, one tile
  per input (arrow keys / numpad). **Hold-to-repeat:** a held direction key
  steps at ~8 tiles/s after a 0.25 s delay. Each held step is one normal move,
  so N held-steps = N moves and N clock costs (§4.3) — no batching, no free
  steps.
- **Helm mode (UW2-style auto-sail):** a direction key **sets the heading**;
  the fleet then auto-steps that heading every
  `interval_s = clamp(1.0 / effective_speed(heading), 0.12, 2.0)` seconds (the
  clamp lands a speed-16 hull at 0.12 s ≈ today's hold rate). A new direction
  key changes the heading without stopping. **`Space` stops the helm**;
  pressing `Space` again while stopped waits one day (below). Helm **cancels**
  on click-to-sail, on a battle handoff and on docking; **`Esc` keeps its
  global S4 meaning everywhere** (`80-*` §4.6.3 — the Phase-6 motion-key
  decision, `IMPLEMENT-Phase6.md` decision 9). Trim keys work while under
  helm; port entry is unchanged — steering into a shore tile docks (§4.11.1)
  and cancels the helm. The heading persists as `world.heading`
  (default `"E"`).
- **Wait at sea (both modes, any trim):** `Space` holds position and advances
  exactly 1 day via `advance_clock(1.0)` — the full ledger runs (provisions,
  wages, weather re-roll, morale; §4.5). In Step mode `Space` is the wait key;
  in Helm mode the first press stops, the second waits (§4.17).
- **Sail-trim keys (both modes):** `[` / `]` cycle the trim state (§4.17).
- **Interpolated rendering (both modes):** the ship marker animates between
  tile positions over each step interval — a **render-only offset**. Logic,
  rules and saves stay strictly tile-domain: no rule reads the interpolation
  offset, no sub-tile coordinate exists in any rule, and nothing sub-tile is
  ever saved.
- **Click-to-sail (both modes):** clicking any visible water tile computes an
  `AStarGrid2D` path over the region 4320×2160 with
  `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` (no corner cutting) and jumping on; the
  fleet then walks it step-by-step through the normal per-step rules (clock,
  consumption, port entry, encounters). A click on land, permanent ice or a
  seasonally frozen tile (§4.18) is rejected with no clock cost. The path
  cancels on manual input and recomputes after a battle interrupts it.
  - **Seam-crossing path queries** are made in a local frame: shift the fleet
    and target `x` together by `−fleet.x mod 4320` into `[0, 4320)` before the
    query (`AStarGrid2D` rejects out-of-region points), then offset the
    returned path back. `|Δx| > 2160` selects the short way around the seam.
  - **Wind-blind A\* (locked decision 4).** The path is distance-optimal and
    knows nothing about wind or currents; wind/currents act on elapsed time
    only (§4.4, §4.16). A hand-tacked route therefore beats the autopilot
    upwind — that skill gap is the point, not a defect.
  - **Architecture (locked decision 7).** The shipped two-stage `sail_path.gd`
    design is kept: near region Chebyshev ≤ `NEAR_REGION_TILES` 256 with
    `REGION_MARGIN` 24 (seam-shifted local frame) covers every legal click at
    any scale, plus the full-region stage with jumping off, under the 1 s
    budget; the pinned escape hatch stands (below).
  - **Pre-named fallback (pinned, task H):** if the 1 s path budget fails,
    route over a coarse precomputed passable-waypoint graph, then refine per
    chunk with the same A* — no redesign.
- **No corner cutting:** a diagonal move is blocked if either orthogonal
  neighbor of the target corner is impassable.
- **Seasonal ice refuses entry (both modes, §4.18):** an in-month
  `ice_regions.json` polygon tile is impassable to *entering* — a direction
  key, a helm step and an A* path may not move the fleet onto it (a blocked
  move: no clock cost, `world.ice_blocked` toast). A tile that freezes **under**
  a standing fleet never traps it: the fleet may still move out.
- Each successful tile move advances the fractional clock by
  `move_cost(heading)` = `1 / effective_speed(heading)` days (§4.4). Blocked
  moves cost nothing.
- Heading into a port's **shore** tile from an orthogonally adjacent tile
  triggers port entry (§4.11.1) instead of moving the fleet; the docking
  charges one `move_cost(heading)` before the port screen opens. Sailing
  across a port's berth tile is ordinary movement and docks nothing.

### 4.3 Game clock & day tick

- `GameState.day` is an integer; a fractional accumulator
  `world.clock_fraction ∈ [0,1)` holds sub-day progress (not saved — saving
  happens only in port, where the fraction is always reset to 0).
- **Day-tick order (locked, Phase 5).** When `clock_fraction ≥ 1.0`:
  subtract 1.0, `day += 1`, then run strictly in order:
  1. the **daily ledger** (§4.5) — whose step 3 is now a **two-part weather
     roll**: the strength roll, then the wind-direction roll, one seeded
     stream, pinned order strength → direction (§4.5, §4.7);
  2. the **economy step**: stock drift toward resting stock by consumption
     tier + demand-event start/expiry (`30-*` §4.2/§4.5 — the drift rates
     and event rules live there, not here); this step also runs on **port
     day-advances** (`30-*` §4.2);
  3. emit `EventBus.day_advanced`;
  4. the **NPC fleet tick** (`60-*` §4.11.11): lane stepping, dwell,
     auto-resolve and the daily trickle — the world scene ticks it once per
     day on `day_advanced` (the Phase-4 `last_tick_day` dedupe is kept).
- **Wait is a day-advance source (Phase 6).** The wait action (`Space` at sea,
  §4.2/§4.17) holds position, calls `advance_clock(1.0)` and runs this same
  day-tick sequence — the full ledger and the steps below it, exactly like any
  other day.
- **Drift push (Phase 6).** In `current_mode: drift`, the daily current push
  (§4.16) runs once per day tick **at sea, after the ledger** — a positional
  push along the current vector by the §4.16 rates (wrap-aware; stops before
  impassable tiles), not a clocked move.
- In port, the clock does not advance except by explicit actions that cost a
  day (odd jobs, rest). Port actions advancing the day run the same ledger
  and the same economy step (order step 2 above).

### 4.4 Speed formula

```
effective_speed(heading) = floor(
    base_speed                          # fleet speed = slowest ShipType.speed (below, unchanged)
  × wind_factor(weather, class)         # §4.7
  × direction_factor(heading, wind_dir) # table below; identity 1.0 when weather = calm
  × current_factor(heading, position)   # §4.16; identity 1.0 in drift mode
  × crew_factor(crew, crew_min)         # §4.6
  × (1 + seamanship_bonus)              # 50-* §stat effects
  × trim_factor(sail_trim)              # §4.17
)
minimum 1 tile/day
```

`floor` applies after all multipliers. `seamanship_bonus =
(seamanship − 10) / 100`, clamped to `[-0.1, +0.2]` (per `50-*`).

`heading` is one of the 8 compass directions; `wind_dir` is the day's
wind-FROM direction (`world.wind_dir`, §4.7). The angle between the move
heading and the wind-from direction is bucketed to the 8-compass grid:

| bucket (angle to wind-from) | sail | hybrid | oar |
|---|---|---|---|
| 0° (into wind) | 0.50 | 0.85 | 1.00 |
| 45° (close-hauled) | 0.70 | 0.95 | 1.00 |
| 90° (beam) | 1.00 | 1.00 | 1.00 |
| 135° (broad reach) | 1.15 | 1.05 | 1.00 |
| 180° (running) | 1.30 | 1.10 | 1.00 |

`direction_factor` is applied **only when weather ≠ `calm`** — a calm keeps
the flat sail penalty of the `wind_factor` table (sail 0.8) and no direction
effect (identity 1.0 for every class). `move_cost()` becomes
`move_cost(heading)`: each successful tile move advances the clock by
`1 / effective_speed(heading)` days; blocked moves still cost nothing. The
heading-less `effective_speed()` (the HUD average, no steering context) uses
the **beam** bucket, 1.0, as its `direction_factor`.

**Ocean-current factor (§4.16; `current_mode: modifier`).** Alignment between
the move heading and the current's flow direction: within 67.5° →
`1 + 0.08 × strength`; 67.5–112.5° → `1.0`; ≥ 112.5° → `1 − 0.08 × strength`
(strength 1–3). In `current_mode: drift` the factor is identity 1.0 and the
current acts as a daily push instead (§4.16).

**Sail-trim factor (§4.17, normative there).** furled 0 (cannot move), reefed
0.75, normal 1.0, full 1.15. Trim also multiplies storm damage: furled ×0.5,
reefed ×0.75, normal ×1.0, full ×1.5 (§4.17 table).

**Units (Phase 6 re-pin).** A tile is 5 nm (§4.1), so `ShipType.speed` is
**tiles/day on 5 nm tiles**: the base speeds are `{16, 20, 24}` tiles/day =
80–120 nm/day — the same 80–120 nm/day as Phase 4, now at 12 tiles per
degree. The floor of 1 tile/day is unchanged.

**Fleet-speed composition (normative, resolves `40-*` §4.4).** `base_speed` is
the **slowest `ShipType.speed` among all ships in the fleet**, not the
flagship's own value; every other factor (`crew`, `crew_min`, `class` for
`wind_factor`, `seamanship_bonus`) comes from the **flagship**. A one-ship fleet
therefore reduces to the flagship's own speed.

**NPC parity (cross-reference, Phase 6).** NPC fleet daily tile budgets
multiply by the same `direction_factor`/`current_factor` for the current leg
heading, lane stepping runs at base **2 tiles/day** before factors, and lanes
carry seasonal variants — normative in `60-*` §4.11.11 (Phase-6 amendment),
not here.

### 4.5 Daily ledger (strict order, runs once per day tick at sea and on
port day-advances)

1. **Consumption:** daily need is `need = ceil(total_crew / RATION_SIZE)`
   units of provisions **and** the same in water, with `RATION_SIZE = 5`
   (1 unit feeds/waters 5 crew for 1 day; pooled across all ships,
   `40-*` §pooling). If stock < need, the stock is consumed to 0 and the
   shortfall triggers fail-state counters (§4.9).
2. **Wages:** `gold -= total_crew × CREW_WAGE_DAILY + Σ officer.wage_daily`.
   `CREW_WAGE_DAILY = 2` (locked). Gold may go negative ≤ 0 → clamp to 0 and
   apply morale −5 once that day (unpaid crew).
3. **Weather rolls (§4.7): the strength roll, then the wind-direction roll**
   for the coming day — one seeded stream, pinned order strength → direction;
   the direction persists as `GameState.world["wind_dir"]`.
4. **Morale update** (§4.8).
5. **Fail-state checks** (§4.9) in order: sinking, starvation, scurvy.
6. **Mutiny check** (§4.8.3).

### 4.6 Crew factor

```
crew_factor = crew < crew_min ? crew / crew_min (min 0.25) : 1.0
```

Uses the flagship's `crew_min` (fleet rule: each ship needs its own minimum;
the sim reduces flagship speed only, fleet ships are assumed crewed from the
pool — full multi-ship crewing model is OUT OF SCOPE (phase 2)).

### 4.7 Weather

Rolled once per day tick, **latitude-band** dependent. Band = `|lat|`
(symmetric N/S, so the same band applies in both hemispheres); the fleet's
latitude comes from `lat = 90 − y/12` (§4.1). The 60–70°N band is north-only
because south of 60°S is ice (the `I` band, §4.1).

| Band | clear | overcast | windy | storm |
|---|---|---|---|---|
| Doldrums: \|lat\| < 8° | 0.30 | 0.45 | 0.15 | 0.10 |
| Trade winds: 8–30° | 0.15 | 0.30 | 0.20 | 0.35 |
| Variables: 30–40° | 0.30 | 0.40 | 0.20 | 0.10 |
| Westerlies: 40–60° | 0.10 | 0.30 | 0.35 | 0.25 |
| Boreal: 60–70°N | 0.15 | 0.35 | 0.30 | 0.20 |

The four weather states are the ones the `wind_factor` table below names
`calm` / `fair` / `strong` / `storm`: **clear = calm**, **overcast = fair**,
**windy = strong**, **storm = storm** (one state, two labels — the band table
keeps the Phase-4 column names). Each band row sums to 1.00.

**The mapping is normative (locked):** `GameState.world["weather"]` and every
`wind_factor` key are the engine ids `calm|fair|strong|storm`; the band table's
`clear|overcast|windy|storm` are display column names only and never appear in
code or data. `SailingSim.weather_zone_for()` returns a **band id**
(`doldrums`, `trade_winds`, `variables`, `westerlies`, `boreal`), and
`SailingSim.zone_probabilities()` returns the four engine ids, so the roll can
only ever produce a value the `wind_factor` table understands.

`wind_factor` by propulsion class (`ShipType.class`):

| weather | sail | oar | hybrid |
|---|---|---|---|
| calm | 0.8 | 1.0 | 1.0 |
| fair | 1.0 | 1.0 | 1.0 |
| strong | 1.25 | 1.0 | 1.1 |
| storm | 1.5 | 1.0 | 1.2 |

#### 4.7.1 Wind direction (Phase 6)

A second, directional roll joins the daily weather step (ledger step 3, §4.5):
**the strength roll happens first, then the wind-direction roll**, both drawn
from the same seeded stream in that pinned order (deterministic per seed — the
same seed replays the same direction sequence).

- **Prevailing direction:** the fleet's region's table entry for the current
  month (§4.14; `data/wind_regions.json`, region × month). Tokens are the 8
  compass directions **plus `VAR`**; every token is a **wind-FROM** direction.
  Uncovered water (no authored region) falls back to `VAR` + variable
  behavior.
- **`VAR`** draws uniformly over the 8 compass directions.
- **Jitter by weather** (the day's just-rolled strength state):

  | weather | prevailing kept | otherwise |
  |---|---|---|
  | calm | 60% | uniform draw of ±45° or ±90° |
  | fair | 70% | uniform draw of ±45° |
  | strong | 60% | uniform draw of ±45° or ±90° |
  | storm | 0% | uniform over all 8 compass directions |

  Storm never keeps the prevailing direction — it is always a uniform draw.

- **Persistence:** the result is stored per day in
  `GameState.world["wind_dir"]` (an 8-direction id; default `"E"`, overwritten
  by every ledger roll before any movement can consume it). The HUD wind
  arrow + strength label sit by the weather glyph and read this key
  (visuals in `80-*` §4.5).
- **Effect:** `direction_factor(heading, wind_dir)` enters the §4.4 pipeline
  **only when weather ≠ `calm`** — a calm keeps the flat 0.8 sail penalty and
  no direction effect.

**Storm effects** (checked at the day tick that rolled storm, before movement):

- Each ship takes `ceil(durability_max × 0.05)` damage, reduced by luck
  mitigation (`50-*`: luck ≥ 50 → damage × 0.75, applied before rounding).
- Morale −5 (stacks with §4.8 daily delta).

**Demo-loop re-anchor (replaces the old Atlantic strip).** The old low-x
Atlantic-strip thresholds are deleted; storms are now a property of the latitude
bands. Demo-loop step 5 is satisfied by **Lisbon (38.7°N) → the open water off
Santa Cruz de Tenerife (≈28.3°N 16.5°W)** — a **coordinate destination**, not a
port (the 100-port list has no Canaries port and none is added). Arrival means
crossing the 30°N band edge into the trade-wind belt and sampling weather
there; `madeira` (32.7°N) sits in the variables band and cannot substitute.

**Reachability acceptance (exact arithmetic).** The effective per-day storm
probability in the trade-wind belt is `0.35 × (1 − luck/400)` (`50-*` §4.2),
i.e. `p = 0.34125` at the default `luck = 10`. The per-day **no-storm** factor
before the luck term is `1 − 0.35 = 0.65`. Compounded over `n` in-band day
ticks, the chance of at least one storm is `1 − (1 − p)^n`; the scripted gate
is computed with the luck-modified `p` in the seeded check:

- **"storm within 6 day ticks in-band ≥ 0.90"** — `1 − 0.65⁶ = 0.9246`
  (no-luck term) and `1 − (1 − 0.34125)⁶ = 0.9183` at luck 10; both clear the
  gate.
- A "≥ 0.98 within 12 days" claim is **not** made and must not be asserted.

Band probability acceptance uses **10,000 seeded rolls per band** and must
match every category within **±0.02**. Every band is validated this way,
including the north-only boreal row.

### 4.8 Morale

Fleet morale is a single value 0–100 (per-ship morale OUT OF SCOPE
(phase 2)). New game: 70.

#### 4.8.1 Daily delta (step 4 of ledger)

| Condition | Delta |
|---|---|
| At sea, fully supplied | −1 |
| At sea, provisions short | −5 additional |
| At sea, water short | −5 additional |
| At sea, storm day | −5 additional |
| In port (any cause of day advance) | +5, up to the port cap 80 |
| Wages unpaid (gold clamped) | −5 additional |

Clamp result to [0, 100]. Morale tiers (HUD colors in `80-*`):

| Tier | Range |
|---|---|
| Excellent | 80–100 |
| Good | 60–79 |
| Strained | 40–59 |
| Dangerous | 20–39 (HUD yellow warning) |
| Mutinous | 0–19 (HUD red warning) |

**Normative clarifications (resolved while implementing).**

1. **Port cap scope.** The in-port `+5` is raised only up to the cap:
   `morale = min(morale + 5, max(morale, 80))`. A fleet already above 80 keeps
   its value (no forced decay to 80), and the cap never suppresses at-sea
   losses; the outer `[0, 100]` clamp still applies.
2. **"Wages unpaid" is not at-sea-only.** The −5 row applies on any day the
   gold clamp fired, in port included (so an unpaid port day nets `+5 −5 = 0`).
3. **Acceptance sampling.** The mutiny rate is `0.25 × (1 − (leadership−10)/200)`
   per at-sea day, so the 5-day compounded probability is `1 − 0.75⁵ = 0.7627`
   at leadership 10. Verify against that value within **±0.02** using ≥ 4000
   seeded trials; an exact `≥ 0.76` threshold has a 0.0067 standard error at
   n = 4000 and is flaky.

#### 4.8.2 Desertion

On every port entry, if morale < 40: `crew -= max(1, floor(crew × 0.10))`
from the flagship pool; a dialog reports the loss (`ui_strings`
`world.desertion`). Desertion cannot reduce crew below 1.

#### 4.8.3 Mutiny

At ledger step 6, if at sea and morale < 20: 25% chance per day of the
mutiny event modal (`ui_strings world.mutiny.*`):

- **Pay off** (disabled unless `gold ≥ crew × 20`): `gold -= crew × 20`,
  morale = 50.
- **Suppress:** `crew -= max(1, floor(crew × 0.30))`, morale = 40.

If neither is possible (e.g., crew already 1), mutiny fizzles with morale +5.

### 4.9 Fail states (sea-death; only game-over source in Phase 1)

| Counter | Trigger at ledger step 1/5 | Daily effect while active | Game over when |
|---|---|---|---|
| Starvation | provisions < need (provisions clamp to 0) | counter+1; `crew -= max(1, floor(crew × 0.05))`; morale −5 (in 4.8.1 table) | counter ≥ 7 → `EventBus.game_over("starvation")` |
| Scurvy | water < need (water clamp to 0) | counter+1; `crew -= max(1, floor(crew × 0.05))`; morale −5 | counter ≥ 7 → `game_over("scurvy")` |
| Sinking | any ship durability ≤ 0 | — | flagship only ship → `game_over("sunk")`; else crew/cargo relocate per `40-*` §sinking |

Starvation/scurvy counters reset to 0 on the first fully-supplied day. Crew
loss from either cannot reduce crew below 1 (game over fires at 7 days
regardless). On game over: show `gameover_screen` with the reason string,
then return to title; no save is written or deleted.

### 4.10 Provisions & water as cargo

- Both occupy capacity at 1 cargo unit per unit (`10-*` §3.1) and are
  consumed at `ceil(crew / 5)` units each per day (§4.5) — e.g., a 15-crew
  caravel burns 3 + 3 units/day, so 60 + 60 units of cargo = 20 days at sea.
- **Purchased at the Set-Sail provisioning dialog, not the market**
  (`80-*` §4.6.1): `provisions` 2g/unit, `water` 1g/unit (locked prices; not
  affected by supply/demand — they are supplies, not trade goods, and never
  appear in `goods.json`). The market no longer sells them; the provisioning
  prompt is the single supply purchase point, and it also jettisons surplus.
  Reasons: (1) supplies are survival, not commerce, so they must not compete
  with trade rows; (2) leaving port is the moment the player knows where they
  are going, so it is the moment the number matters.
- **Days-of-supply readout (locked).** The prompt shows
  `days = min(floor(provisions / need), floor(water / need))` with
  `need = ceil(total_crew / RATION_SIZE)` (§4.5) — the number of full days the
  fleet can stay at sea on the lesser of the two. Zero crew is handled by
  §4.11.2's sailing gate, not by this formula.
- Surplus can be jettisoned from the fleet panel (S15, `80-*` §4.5.1); not
  sellable. Jettison is per **stack**: it drops every unit of one trade good,
  or the whole provisions or water stack, from one ship, after a confirm
  dialog, and frees capacity immediately (`Fleet.jettison_good` /
  `Fleet.jettison_supplies`). It is a port action, like flagship promotion —
  the panel is read-only at sea.

### 4.11 Port discovery & entry/exit

- **Known ports:** `GameState.known_ports`. At new game: all 6 capital/start
  ports are known (`lisbon, seville, london, amsterdam, istanbul, venice`).
- **Sighting:** when the fleet is within the sighting radius (**48** tiles,
  ≈4° ≈ 240 nm; modified by navigation per `50-*` §4.2; Chebyshev distance,
  **wrap-aware on x**) of a port's harbor pair (measured to its berth tile),
  that port is added to `known_ports` permanently (marker appears on map +
  minimap). Map exploration (§4.12) uses the same radius.
- **Discovery sighting (Phase 3, world map):** a separate, shorter radius —
  **36** tiles (Chebyshev, wrap-aware) — is when the `E` Explore action can
  find a `Discovery` (`70-*` §4.4). Ports and discoveries never share a radius
  constant (`sighting_radius` 48 vs `discovery_radius` 36, §5).
- **NPC fleet sighting (Phase 5):** national NPC fleets are world-map
  overlays rendered like ports (`60-*` §4.11.11) — nation-coloured squares,
  the wreck icon and wake trails (`80-*` §4.5.2). The two radii above are
  **unchanged by the fleet layer at their Phase-6 values**: port sighting
  stays **48**, discovery stays **36**, and fleets need no sighting roll of
  their own (they are simply rendered when on screen). Lane behavior — which
  routes each role sails, chokepoint camping with the 5/8 hysteresis, and the
  pursuit exception — is specified in `60-*` §4.11.11, not here.

#### 4.11.1 Harbor pair: shore (land) tile + berth (sea) tile (locked)

Every port owns a **pair** of orthogonally adjacent tiles, both derived from
its `lat`/`lon` (`10-*` §6.1) — neither is stored in data:

| Tile | Derivation | Passable | Role |
|---|---|---|---|
| **berth tile** (sea) | §6.1 snap: nearest water within 2 tiles, Chebyshev, tie-break smallest `(y, x)`, **skipping candidates with no orthogonally adjacent `#`** (the pair constraint below) | **yes** (`~`/`.`) | the fleet's berth; where the fleet stands after leaving port |
| **shore tile** (land) | nearest `#` tile **orthogonally adjacent** to the berth tile, tie-break smallest `(y, x)` | **never** (it is `#`) | **the port's map location** — this is what the player sees marked |

The pair is mandatory: every port must have a shore tile orthogonally
adjacent to its berth tile (validator group 6). The berth snap therefore
carries the pair as a **candidate constraint**: a water candidate with no
orthogonally adjacent `#` is skipped, and the berth is the nearest candidate
that satisfies both rules (`10-*` §6.1). A port whose plain §6.1 berth already
has a shore tile does not move; on the shipped map exactly 14 do, by one tile.
The berth is ordinary water — **standing on it does not open the port screen**.

- **Presentation (locked):** the port overlay (nation-coloured square + label)
  is drawn on the **shore tile**, not the berth. What the player sees as "the
  port" is the land tile; the berth next to it is where the ship sits.
- **Entry (docking):** the fleet docks by **heading into the shore tile**.
  A direction key or click whose target is a port's shore tile opens the
  port-entry sequence (greeting banner `Port.flavor`, day count, desertion
  check §4.8.2) → route to `port_screen.tscn`. The fleet does **not** move
  onto the land tile: docking is an interaction, not a step.
  - **Orthogonality (locked):** docking requires the fleet to be
    **orthogonally adjacent** to the shore tile; a diagonal into it is illegal
    exactly as any diagonal into land is (§4.2, no corner cutting). Since the
    berth is orthogonally adjacent to the shore, standing on or beside the
    berth is the docking position.
  - **Clock cost (locked):** docking charges one `move_cost(heading)`
    (`1 / effective_speed(heading)` days, §4.4) before the port screen opens,
    so the
    "distance is the core resource" pillar is not leaked. `clock_fraction`
    still resets to 0 at port entry.
  - Docking an **unknown** port discovers it (`known_ports`) and enters
    normally.
  - A land tile that is not a port's shore tile is an ordinary blocked move
    (§6: silent, no clock cost, `world.move_blocked` toast).
- **Exit:** "Set sail" returns to `world_map.tscn` with the fleet on the
  **berth tile** (sea) and `clock_fraction` reset to 0. The fleet never
  occupies a land tile.
- **Click-to-sail:** a shore tile is a valid route *destination* — clicking it
  routes to the adjacent berth and then docks. It is never a routing waypoint;
  `AStarGrid2D` still treats it as solid.
- **No accidental docking:** sailing across a berth is ordinary movement. This
  deliberately removes the old behaviour where stepping onto the berth opened
  the port.

#### 4.11.2 Sailing gate: crew + supplies (locked)

Leaving port is refused — the Set Sail button is **disabled with a stated
reason**, and `set_sail()` returns false with state untouched — unless **both**
hold:

| Condition | Threshold | Key when it fails |
|---|---|---|
| Crew aboard | `total_crew ≥ 1` (the fleet is not shipless/crewless) | `port.sail.no_crew` |
| Days of supply | `days ≥ 1` (§4.10 formula) | `port.sail.no_supply` |

This is a **hard gate**, not a warning: a fleet that cannot survive one day
must not reach open water, because §4.9's starvation/scurvy counters would
otherwise start on day 1 with no decision left to the player. The turn-away is
recoverable by construction — supplies are buyable in the prompt itself and
the inn's odd-job fallback (`10-*` §5) still pays, so no softlock is created.

`ESC` on S4 is the same edge as Set Sail (`80-*` §4.3): it opens the
provisioning prompt rather than leaving directly.

### 4.12 Minimap

- HUD element: a **256×192 px** box showing a **wrap-aware 128×96-tile crop**
  around the fleet at 2 px/tile.
- Renders explored tiles only, from the session explored bitset (a
  `PackedByteArray` of **9,331,200** bytes — 4320 × 2160, one per world tile,
  ~9.3 MB; not saved):
  a tile is explored after being within the sighting radius (§4.11) of the
  fleet. Re-explored on load — known limitation, unchanged.
- The crop is **centred on the fleet** (column 64 of the 128, row 48 of 96),
  so a fleet at `x = 4319` shows tiles `x ∈ [4255..4319]` then `x ∈ [0..62]`
  — 128 contiguous columns, with no void at the seam. `x = 4254` and
  `x = 63` are outside the window.
- Known port markers drawn as 2×2 px dots in the port's nation color, on the
  port's **shore** tile (the pair's visible location, §4.11.1); fleet
  as a 2×2 px white dot. Found discoveries are drawn as 2×2 px `ACCENT` dots
  once explored.
- The **full world is the separate Chart screen** (S17, `80-*` §4.6): the
  whole 4320×2160 grid downscaled to fit, explored overlay + known ports +
  fleet marker. The HUD minimap never scales with a map size (there is one
  map). Phase-6 chart overlays (wind/current arrows, ice tint) are `80-*`'s
  spec (task C); their sailing-side semantics are pinned here (§4.14/§4.16/
  §4.18): wind arrows show each region's current-month prevailing direction,
  current arrows show the decoded (reversal-applied) flow, and the ice tint
  marks in-month seasonal ice on explored tiles.

### 4.14 Prevailing winds & monsoons (Phase 6)

- **Data:** `data/wind_regions.json`, envelope `{version, wind_regions: [...]}`
  (plural == basename, `10-*` §3.2); each region is
  `{id, name: {zh, en}, polygon: [[lat, lon], …], months: {"1": "NE", …
  "12": "SW"}, variability: "steady" | "variable"}`. The schema is `10-*`'s;
  the sailing semantics (the daily roll) are §4.7.1's. Hand-authored, cited
  facts — per-region sources recorded in `LICENSE-NOTES.md` (Phase-6 decision
  3); nothing vendored.
- **Tokens:** the 8 compass directions `N NE E SE S SW W NW` plus `VAR`;
  every token is a **wind-FROM** direction. Regions tile all ocean between
  70°N–60°S; **uncovered water falls back to `VAR` + variable**.
- **Monsoons** are this same region × month table where it flips seasonally
  (the Indian-Ocean NE/SW reversal is the canonical case) — there is no
  second mechanism.
- **The monthly roll** — prevailing for the current month → per-weather
  jitter → `world.wind_dir` persistence, on the seeded stream after the
  strength roll — is normative in §4.7.1 and not restated here.
- **Baked lookup:** `data/maps/wind_regions.png` — 1 px = 1 tile at the 5 nm
  grid, palette index = region id; tool-owned by `tools/build_ocean.py`
  (byte-identical rebuilds, never hand-edited). Runtime lookup is O(1) via
  `scripts/world/ocean_layers.gd`.
- **Cosmetic layer (still future scope):** a second indexed PNG (biomes/
  relief; rivers via `ne_10m_rivers_lake_centerlines`) consumed only by the
  renderer, never by simulation; palette indices ≥ 5 per the append-only
  policy (`10-*` §6.3).

### 4.15 Calendar (Phase 6)

- `MONTH_DAYS = 30`, `YEAR_MONTHS = 12` — a **360-day year**; day 1 is
  Month 1.
- `year(day) = floor((day − 1) / 360) + 1`;
  `month(day) = floor(((day − 1) mod 360) / 30) + 1`.
- **Treasure-fleet reconciliation (doc note only).** The Phase-5 treasure-fleet
  season cycle (mod 90, `60-*` §4.11.11.4) reads as **90-day quarters
  anchored at Month 1**: `(day − 1) mod 90` puts days 1–90 in Months 1–3,
  91–180 in Months 4–6, 181–270 in Months 7–9, 271–360 in Months 10–12.
  Behavior is unchanged — the month calendar and the season cycle are the
  same lattice.
- **HUD:** the top bar gains `Year {y} · Month {m}` (zh `{y}年{m}月`); months
  display as 一月…十二月 / Month 1–12 from `ui_strings.json` — the HUD spec
  is `80-*`'s (task C).

### 4.16 Ocean currents (Phase 6)

- **Data:** `data/ocean_currents.json`, envelope
  `{version, ocean_currents: [...]}`; each system is `{id, name: {zh, en},
  strength: 1|2|3, path: [[lat, lon], …], width_tiles: int (at 5 nm),
  reversal: {"summer_months": [6, 7, 8, 9], "direction": "reverse"}?}` (the
  `reversal` key is optional). ~20 hand-authored systems — Gulf Stream,
  Kuroshio, N/S Equatorial, Canaries, Benguela, Agulhas, Somali (the
  reversal), Brazil, N/S Pacific, Antarctic Circumpolar, North Atlantic
  Drift, Labrador, Humboldt, E/N Australian, Monsoon drift, … (the exact
  list is task-owned, task D). Per-system sources are cited in
  `LICENSE-NOTES.md` (facts, nothing vendored).
- **Baked raster:** `data/maps/currents.png` — 1 px = 1 tile; palette index
  0 = no current, indices 1–24 = 8 directions × 3 strengths; overlaps resolve
  strongest-then-id-order. Tool-owned, byte-identical rebuild (validator
  group 9). **The raster stores the annual-mean vector;** a system's
  `reversal.summer_months` flips the decoded vector **at lookup time** —
  runtime and debug renderer apply the same one-line flip. One static PNG,
  seasonal Somali.
- **Modifier mode** (`current_mode: "modifier"`, the default; applies in
  **both input modes**): alignment between the move heading and the current's
  flow
  direction — within 67.5° → `1 + 0.08 × strength`; 67.5–112.5° → `1.0`;
  ≥ 112.5° → `1 − 0.08 × strength`. This is the §4.4 `current_factor`; it is
  identity 1.0 in drift mode. The HUD current arrow on a current tile shows
  the decoded, reversal-applied flow (visuals in `80-*` §4.5).
- **Drift mode** (`current_mode: "drift"`): at each day tick at sea the fleet
  is pushed along the current vector by strength — **0.5 / 2 / 4 tiles/day**
  for strength 1/2/3 (= 2.5/10/20 nm/day at 5 nm). A fractional accumulator
  carries the sub-tile remainder (strength 1's 0.5 is the case that needs
  it); each whole tile of accumulated drift steps the fleet one tile along
  the current, wrap-aware. The push **stops before impassable tiles** (land,
  reef, permanent `I`, in-month seasonal ice §4.18): it never lands the
  fleet on one and deals no damage. It is **suppressed while docked**. The
  accumulator is **not persisted** (saves are port-only) — it resets on load.

### 4.17 Sail trim & wait (Phase 6)

- **States:** `furled | reefed | normal | full` (default `normal`); the keys
  `[` / `]` cycle them (§4.2); the state persists as `world.sail_trim`.
- **Speed factor** (the §4.4 pipeline's `trim_factor`):

  | trim | speed factor |
  |---|---|
  | furled | 0 (cannot move) |
  | reefed | 0.75 |
  | normal | 1.0 |
  | full | 1.15 |

- **Storm-damage multiplier** — multiplies `storm_damage_for` (§4.7 storm
  effects): furled ×0.5, reefed ×0.75, normal ×1.0, full ×1.5. **Oar class
  ignores trim; hybrid uses the sail table** (as does sail). A HUD trim chip
  shows the current state (visuals in `80-*` §4.5).
- **Wait at sea:** `Space` holds position and advances exactly 1 day —
  `advance_clock(1.0)`, the full ledger (provisions, wages, weather re-roll,
  morale; §4.5). It works in **both input modes regardless of trim** — the
  "wait out the storm / wait for the wind shift" tactic. In Helm mode the
  first `Space` stops the helm; the second waits (§4.2).

### 4.18 Seasonal sea ice (Phase 6)

- **Data:** `data/ice_regions.json`, envelope `{version, ice_regions: [...]}`;
  each region is `{id, name: {zh, en}, polygon: …, months: […]}` (a month
  window may wrap the year end). Initial set: **Baltic (months 12–3),
  Hudson Bay (11–4), White Sea (11–4)**.
- **Rule:** in-month, water tiles inside a polygon are impassable to
  **entering** fleets — player moves (both input modes), NPC lane stepping
  and A* (§4.2) all refuse entry. A tile freezing **under a standing fleet
  does not trap it**: the fleet may still move out. A refused move shows the
  `world.ice_blocked` toast and costs no clock.
- **Implementation:** a runtime polygon check with a month-keyed tile cache
  in `scripts/world/ocean_layers.gd` (small data, no raster).
- **The permanent `I` band rule (§4.1) is unchanged** — seasonal ice only
  adds temporary impassability equatorward of it.
- **NPC application (cross-reference):** ice-aware lane stepping and seasonal
  lane variants are normative in `60-*` §4.11.11 (Phase-6 amendment), not
  here.

## 5. Data Examples

Storm-roll and morale tables are code constants; all tunables live at the top
of `sailing_sim.gd` and are listed here (single source of truth). The Phase-6
pipeline tables (direction/current/trim factors, drift rates, helm clamp) are
code constants too:

```json
{
  "sailing_constants": {
    "crew_wage_daily": 2,
    "ration_size": 5,
    "provisions_price": 2,
    "water_price": 1,
    "sighting_radius": 48,
    "discovery_radius": 36,
    "harbor_snap_radius": 2,
    "tiles_per_degree": 12,
    "map_width": 4320,
    "map_height": 2160,
    "ice_north_lat": 70,
    "ice_south_lat": -60,
    "coastal_band_tiles": 3,
    "morale_start": 70,
    "morale_port_cap": 80,
    "starvation_limit_days": 7,
    "mutiny_threshold": 20,
    "mutiny_chance_per_day": 0.25,
    "desertion_threshold": 40,
    "desertion_fraction": 0.10,
    "storm_damage_fraction": 0.05,
    "month_days": 30,
    "year_months": 12,
    "direction_factor_buckets_deg": [0, 45, 90, 135, 180],
    "direction_factor_sail": [0.50, 0.70, 1.00, 1.15, 1.30],
    "direction_factor_hybrid": [0.85, 0.95, 1.00, 1.05, 1.10],
    "direction_factor_oar": [1.00, 1.00, 1.00, 1.00, 1.00],
    "current_factor_step_per_strength": 0.08,
    "current_alignment_bands_deg": [67.5, 112.5],
    "drift_tiles_per_day_by_strength": [0.5, 2, 4],
    "helm_interval_clamp_s": [0.12, 2.0],
    "trim_speed_factor": {"furled": 0, "reefed": 0.75, "normal": 1.0, "full": 1.15},
    "trim_storm_damage_multiplier": {"furled": 0.5, "reefed": 0.75, "normal": 1.0, "full": 1.5}
  }
}
```

(This JSON is illustrative for validators in docs; at runtime these constants
are GDScript constants, not a data file — game content stays in `data/`.)

## 6. Edge Cases & Fail States

- **effective_speed floors at 1** — a skeleton-crewed flagship in a calm can
  never be stranded at speed 0.
- **Jettison to survive:** dumping cargo to fit provisions is legal; capacity
  enforcement at purchase time only (`30-*`).
- **Blocked diagonal between two land tiles** — move rejected silently; no
  clock cost (§4.2).
- **Crew = 0 impossible:** all crew-loss rules floor at 1; the flagship always
  sails while the player lives.
- **Negative gold:** clamped at ledger step 2 with morale penalty; no other
  negatives allowed (purchases validate beforehand, `30-*`).
- **Storm on entry turn to a port tile:** port entry after the day tick means
  storm damage applies before docking; the greeting banner reports damage.
- **Map edge (latitude):** `y` out of range `0..2159` is impassable; the ice
  band `I` (`lat ≥ 70°N`, `lat ≤ 60°S`) is impassable, so the fleet cannot
  sail off the north/south edge.
- **Map edge (longitude):** `x` wraps mod 4320 — there is no eastern or
  western edge and no void; a step east from `x = 4319` lands on `x = 0`.
- **Click-to-sail across the dateline:** the path is computed in the local
  frame (§4.2), so a fleet at `x = 4200` clicking `x = 50` sails the short way
  west through the seam, not the long way around.
- **Click on land or ice:** rejected with no clock cost and no path; the fleet
  does not move.
- **Helm heading survives save/load:** `world.heading` is a v6 save key
  (default `"E"`); a fleet loaded in port keeps its last heading (saves are
  port-only, so a helm is never mid-run at load).
- **Drift push never strands or harms:** the drift-mode push (§4.16) stops
  before impassable tiles — it never lands the fleet on one and deals no
  damage; the fleet resumes steering normally.
- **Ice refuses entry, never traps:** in-month seasonal ice (§4.18) refuses
  *entering* moves (player, NPC, A*, lane stepping) with the
  `world.ice_blocked` toast, but a tile freezing under a standing fleet
  leaves it free to move out.
- **Furled = anchored:** trim `furled` sets the speed factor to 0 — the fleet
  cannot move and can only wait (`Space`), in either input mode (§4.17).
- **Wait advances exactly one day — even in a storm:** the wait's
  `advance_clock(1.0)` runs the full ledger once (§4.3/§4.17); storm damage
  and morale deltas apply for that single day, then the player re-decides.

## 7. Acceptance Criteria

- [ ] From Lisbon (38.7°N), sailing to the water off Santa Cruz de Tenerife
      (≈28.3°N 16.5°W — a coordinate destination, no port) crosses the 30°N
      band edge; the trade-wind band's storm gate is met: "storm within 6 day
      ticks in-band ≥ 0.90" (demo-loop step 5 reachable, `1 − 0.65⁶ = 0.9246`,
      §4.7).
- [ ] Provisions 2g / water 1g / wage 2g are the only consumption prices and
      match `30-*` market UI and `10-*` harbor-relief math.
- [ ] Ledger step order (§4.5) is implemented verbatim and unit-testable in
      `sailing_sim.gd` without a running scene.
- [ ] Morale tiers use exactly the §4.8 thresholds; mutiny/desertion trigger
      only via the specified checks.
- [ ] Game over fires only from `"starvation"`, `"scurvy"`, `"sunk"`.
- [ ] Port entry/exit round-trips position and resets `clock_fraction`.
- [ ] Minimap is a 256×192 px box showing a wrap-aware 128×96-tile crop at
      2 px/tile, and the sighting radius (48) matches `80-*` §4.5.
- [ ] The single world map plays with wrap-aware movement and the chunked
      loader (`90-*` §9): x wraps at the dateline, y is ice-bounded, and the
      loader renders only live chunks.
- [ ] Day-tick order (§4.3, Phase 5) holds and is unit-testable: ledger →
      economy step → `day_advanced` → NPC fleet tick, with the economy step
      also running on port day-advances.
- [ ] Both input modes play end-to-end (Phase 6): Step steps key-per-tile;
      Helm auto-steps at `clamp(1.0 / effective_speed(heading), 0.12, 2.0)` s,
      cancels on click-to-sail/battle/docking, and `Esc` keeps its global S4
      meaning (§4.2).
- [ ] Interpolated rendering never changes logic outcomes: no rule reads the
      marker offset; saves stay tile-domain (§4.2).
- [ ] The wind-direction roll is deterministic per seed — the same seed
      replays the same direction sequence, strength always before direction
      (§4.7.1).
- [ ] Cycling trim with `[`/`]` changes speed per the §4.17 table and storm
      damage per its multiplier table; oar ignores trim, hybrid uses the
      sail table.
- [ ] Drift mode pushes the fleet along the current (0.5/2/4 tiles/day by
      strength) and modifier mode does not; the push never lands the fleet on
      an impassable tile and never damages it (§4.16).
- [ ] Seasonal ice refuses entering fleets in-month (player, NPC, A*, lane
      stepping) with `world.ice_blocked`, and never traps a standing fleet
      (§4.18).
- [ ] Calendar formulas are unit-tested: `year(day)` / `month(day)` per §4.15
      (30-day months, 360-day year), and the wait action advances exactly one
      day via the full ledger (§4.17).
