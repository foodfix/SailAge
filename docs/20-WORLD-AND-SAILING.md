# 20 — World & Sailing

## 1. Purpose & Phase

Specifies the tile-grid world model, movement, the game clock and daily
ledger, consumption (provisions/water/wages), morale with mutiny/desertion,
weather and storms, sea-death fail states, port discovery and entry/exit,
minimap and Chart behavior. Gates Phase 1 and Phase 4 (the real-Earth grid,
latitude weather bands, click-to-sail); Phase 2 combat reuses the map and
movement constants unchanged.

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/world/world_map.tscn` | sailing scene: chunked TileMaps + fleet marker + HUD |
| `scenes/world/chart_screen.tscn` | full-screen whole-world Chart (S17, `80-*` §4.6) |
| `scripts/world/sailing_sim.gd` | movement, clock, daily ledger, weather, morale |
| `scripts/world/sail_path.gd` | click-to-sail `AStarGrid2D` pathing (§4.2, task H) |
| `scripts/world/map_loader.gd` | PNG world → chunked TileMaps (spec in `90-ARCHITECTURE.md` §9) |
| `data/maps/world.png` | the single Terra Vera world map (artefact spec `10-*` §6.3, built by `tools/build_world.py`) |
| GameState keys | `day`, `world.position`, `world.map_id` (always `"world"`), `world.weather`, `known_ports`, morale/crew state inside `fleet` (schema in `40-*`) |

## 3. Dependencies

`00-OVERVIEW.md`, `10-DATA-SCHEMA.md` (esp. §6 map constants), `90-*` (scene
pattern, §9 loader), `40-*` (fleet/cargo schema), `50-*` (stat effects on
speed), `80-*` §4.5/§4.6 (HUD crop and Chart).

## 4. Systems / Mechanics

### 4.1 Grid & coordinates

- World grid: `map_legend.json#grid` = **2160 × 1080** tiles — the whole globe
  at 6 tiles per degree (`10-*` §6.1); `TILE_SIZE_PX` = 32. Addressing:
  `lon = x/6 − 180`, `lat = 90 − y/6`; origin top-left, `x` east, `y` south.
- **Longitude wraps.** `x` is taken mod 2160 everywhere (movement, BFS,
  camera, click); a fleet at `x = 2159` stepping east lands on `x = 0`. This is
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

- 8-directional, one tile per input (arrow keys / numpad).
- **Hold-to-repeat:** a held direction key steps at ~8 tiles/s after a 0.25 s
  delay. Each held step is one normal move, so N held-steps = N moves and N
  clock costs (§4.3) — no batching, no free steps.
- **Click-to-sail:** clicking any visible water tile computes an `AStarGrid2D`
  path over the region 2160×1080 with
  `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` (no corner cutting) and jumping on; the
  fleet then walks it step-by-step through the normal per-step rules (clock,
  consumption, port entry, encounters). A click on land or ice is rejected
  with no clock cost. The path cancels on manual input and recomputes after a
  battle interrupts it.
- **Seam-crossing path queries** are made in a local frame: shift the fleet
  and target `x` together by `−fleet.x mod 2160` into `[0, 2160)` before the
  query (`AStarGrid2D` rejects out-of-region points), then offset the returned
  path back. `|Δx| > 1080` selects the short way around the seam.
- **Pre-named fallback (pinned, task H):** if the 1 s path budget fails, route
  over a coarse precomputed passable-waypoint graph, then refine per chunk with
  the same A* — no redesign.
- **No corner cutting:** a diagonal move is blocked if either orthogonal
  neighbor of the target corner is impassable.
- Each successful tile move advances the fractional clock by
  `1 / effective_speed` days (§4.4). Blocked moves cost nothing.
- Heading into a port's **shore** tile from an orthogonally adjacent tile
  triggers port entry (§4.11.1) instead of moving the fleet; the docking
  charges one `move_cost()` before the port screen opens. Sailing across a
  port's berth tile is ordinary movement and docks nothing.

### 4.3 Game clock & day tick

- `GameState.day` is an integer; a fractional accumulator
  `world.clock_fraction ∈ [0,1)` holds sub-day progress (not saved — saving
  happens only in port, where the fraction is always reset to 0).
- When `clock_fraction ≥ 1.0`: subtract 1.0, `day += 1`, run the **daily
  ledger** (§4.5), emit `EventBus.day_advanced`.
- In port, the clock does not advance except by explicit actions that cost a
  day (odd jobs, rest). Port actions advancing the day run the same ledger.

### 4.4 Speed formula

```
effective_speed = floor(
    base_speed                      # flagship's ShipType.speed (40-* §fleet rule: fleet speed = slowest ship)
  × wind_factor(weather, class)     # §4.7
  × crew_factor(crew, crew_min)     # §4.6
  × (1 + seamanship_bonus)          # 50-* §stat effects
)
minimum 1 tile/day
```

`floor` applies after all multipliers. `seamanship_bonus =
(seamanship − 10) / 100`, clamped to `[-0.1, +0.2]` (per `50-*`).

**Units (Phase 4).** A tile is 10 nm (§4.1), so `ShipType.speed` is
**tiles/day on 10 nm tiles**: the Phase-4 base speeds are `{8, 10, 12}`
tiles/day = 80–120 nm/day, which matches historical daily runs. The formula
above is unchanged.

**Fleet-speed composition (normative, resolves `40-*` §4.4).** `base_speed` is
the **slowest `ShipType.speed` among all ships in the fleet**, not the
flagship's own value; every other factor (`crew`, `crew_min`, `class` for
`wind_factor`, `seamanship_bonus`) comes from the **flagship**. A one-ship fleet
therefore reduces to the flagship's own speed.

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
3. **Weather roll** (§4.7) for the coming day.
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
latitude comes from `lat = 90 − y/6` (§4.1). The 60–70°N band is north-only
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
- **Sighting:** when the fleet is within the sighting radius (**24** tiles,
  ≈4° ≈ 240 nm; modified by navigation per `50-*` §4.2; Chebyshev distance,
  **wrap-aware on x**) of a port's harbor pair (measured to its berth tile),
  that port is added to `known_ports` permanently (marker appears on map +
  minimap). Map exploration (§4.12) uses the same radius.
- **Discovery sighting (Phase 3, world map):** a separate, shorter radius —
  **18** tiles (Chebyshev, wrap-aware) — is when the `E` Explore action can
  find a `Discovery` (`70-*` §4.4). Ports and discoveries never share a radius
  constant (`sighting_radius` 24 vs `discovery_radius` 18, §5).

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
  - **Clock cost (locked):** docking charges one `move_cost()`
    (`1 / effective_speed` days, §4.4) before the port screen opens, so the
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
  `PackedByteArray` of 291,600 bytes, one per world tile; not saved):
  a tile is explored after being within the sighting radius (§4.11) of the
  fleet. Re-explored on load — known limitation, unchanged.
- The crop is **centred on the fleet** (column 64 of the 128, row 48 of 96),
  so a fleet at `x = 2159` shows tiles `x ∈ [2095..2159]` then `x ∈ [0..62]`
  — 128 contiguous columns, with no void at the seam. `x = 2094` and
  `x = 63` are outside the window.
- Known port markers drawn as 2×2 px dots in the port's nation color, on the
  port's **shore** tile (the pair's visible location, §4.11.1); fleet
  as a 2×2 px white dot. Found discoveries are drawn as 2×2 px `ACCENT` dots
  once explored.
- The **full world is the separate Chart screen** (S17, `80-*` §4.6): the
  whole 2160×1080 grid downscaled to fit, explored overlay + known ports +
  fleet marker. The HUD minimap never scales with a map size (there is one
  map).

### 4.13 Seasonal wind & ocean currents (Phase-5 placeholder)

Recorded here so no Phase-4 task invents numbers for it: **monsoons, ocean
currents and seasonal sea ice are a Phase-5 month-indexed layer**
(`IMPLEMENT-Phase4.md` decision 11). Phase 4 pins **no numbers** for them
(`00-*` §11 rule).

- **Monsoons (seasonal wind):** a month-indexed prevailing wind direction per
  sea region feeding `wind_factor` (§4.4) as an additive season/direction
  input — additive to the pipeline, not a rewrite. Candidate data:
  hand-authored region × month table in `data/`, or NCEP/NCAR Reanalysis-2
  monthly mean 10 m winds (public domain) sampled by a builder pass.
- **Ocean currents:** a tile-domain drift layer, ideally a parallel indexed
  PNG `data/maps/currents.png` (1 px = 1 tile) built like `world.png` from the
  NOAA Global Drifter Program climatological monthly mean currents (1° grid,
  public domain); NOAA OSCAR is the heavier alternative. Effect (with/against
  speed modifier or daily drift) is Phase-5.
- **Seasonal sea ice:** a month-indexed passability overlay (Baltic, Hudson
  Bay) sharing the same month-indexed mechanism. The **Phase-4 `I` band stays
  the permanent polar edge** (`lat ≥ 70°N`, `lat ≤ 60°S`, §4.1) — seasonal ice
  only ever *adds* temporary ice inside it.
- **Cosmetic layer:** a second indexed PNG (biomes/relief; rivers via
  `ne_10m_rivers_lake_centerlines`) consumed only by the renderer, never by
  simulation; palette indices ≥ 5 per the append-only policy (`10-*` §6.3).

Every Phase-5 number is pinned in the Phase-5 backlog's owning doc first; this
section is a pointer, not a spec.

## 5. Data Examples

Storm-roll and morale tables are code constants; all tunables live at the top
of `sailing_sim.gd` and are listed here (single source of truth):

```json
{
  "sailing_constants": {
    "crew_wage_daily": 2,
    "ration_size": 5,
    "provisions_price": 2,
    "water_price": 1,
    "sighting_radius": 24,
    "discovery_radius": 18,
    "harbor_snap_radius": 2,
    "tiles_per_degree": 6,
    "map_width": 2160,
    "map_height": 1080,
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
    "storm_damage_fraction": 0.05
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
- **Map edge (latitude):** `y` out of range `0..1079` is impassable; the ice
  band `I` (`lat ≥ 70°N`, `lat ≤ 60°S`) is impassable, so the fleet cannot
  sail off the north/south edge.
- **Map edge (longitude):** `x` wraps mod 2160 — there is no eastern or
  western edge and no void; a step east from `x = 2159` lands on `x = 0`.
- **Click-to-sail across the dateline:** the path is computed in the local
  frame (§4.2), so a fleet at `x = 2100` clicking `x = 50` sails the short way
  west through the seam, not the long way around.
- **Click on land or ice:** rejected with no clock cost and no path; the fleet
  does not move.

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
      2 px/tile, and the sighting radius (24) matches `80-*` §4.5.
- [ ] The single world map plays with wrap-aware movement and the chunked
      loader (`90-*` §9): x wraps at the dateline, y is ice-bounded, and the
      loader renders only live chunks.
