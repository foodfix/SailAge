# 20 — World & Sailing

## 1. Purpose & Phase

Specifies the tile-grid world model, movement, the game clock and daily
ledger, consumption (provisions/water/wages), morale with mutiny/desertion,
weather and storms, sea-death fail states, port discovery and entry/exit, and
minimap behavior. Gates Phase 1; Phase 2 combat reuses the map and movement
constants unchanged.

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/world/world_map.tscn` | sailing scene: TileMap + fleet marker + HUD |
| `scripts/world/sailing_sim.gd` | movement, clock, daily ledger, weather, morale |
| `scripts/world/map_loader.gd` | ASCII map → TileMap (spec in `90-ARCHITECTURE.md` §9) |
| `data/maps/p1_mediterranean.txt` | Phase-1 world (constants in `10-DATA-SCHEMA.md` §6) |
| GameState keys | `day`, `world.position`, `world.weather`, `known_ports`, morale/crew state inside `fleet` (schema in `40-*`) |

## 3. Dependencies

`00-OVERVIEW.md`, `10-DATA-SCHEMA.md` (esp. §6 map constants), `90-*` (scene
pattern), `40-*` (fleet/cargo schema), `50-*` (stat effects on speed).

## 4. Systems / Mechanics

### 4.1 Grid & coordinates

- World grid: 128×96 tiles, origin top-left, `x` east, `y` south
  (`10-*` §6.1). Tile rendering size 32×32 px.
- The fleet occupies exactly one tile (`GameState.world.position`).
- Passability: `sea ~` and `coastal_sea .` passable; `land #` and `reef ^`
  block; port marker tiles passable (they are sea tiles carrying a marker).

### 4.2 Movement

- 8-directional, one tile per input (arrow keys / numpad; also click-to-step
  on an adjacent tile, see `80-*`).
- **No corner cutting:** a diagonal move is blocked if either orthogonal
  neighbor of the target corner is impassable.
- Each successful tile move advances the fractional clock by
  `1 / effective_speed` days (§4.4). Blocked moves cost nothing.
- Moving onto a port marker tile triggers port entry (§4.11) instead of
  consuming further movement input; before docking, the fractional clock cost
  of that tile applies normally.

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

Rolled once per day tick, zone-dependent:

| Zone | Definition | calm | fair | strong | storm |
|---|---|---|---|---|---|
| Atlantic strip | tiles with `x ≤ 6` | 0.05 | 0.30 | 0.15 | 0.50 |
| Rest of map | all other tiles | 0.20 | 0.55 | 0.15 | 0.10 |

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
- The Atlantic strip exists to guarantee demo-loop step 5 (storm reachable
  within 1 day sailing west of Lisbon at `x = 7`).

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
- Purchased only at port markets: `provisions` 2g/unit, `water` 1g/unit
  (locked prices; not affected by supply/demand — they are supplies, not
  trade goods, and never appear in `goods.json`).
- Surplus can be jettisoned from the fleet panel; not sellable.

### 4.11 Port discovery & entry/exit

- **Known ports:** `GameState.known_ports`. At new game: all 6 capital/start
  ports are known (`lisbon, seville, london, amsterdam, istanbul, venice`).
- **Sighting:** when the fleet is within the sighting radius (base 8,
  modified by navigation per `50-*` §4.2; Chebyshev distance) of a port's
  harbor tile, that port is added to `known_ports` permanently (marker
  appears on map + minimap). Map exploration (§4.12) uses the same radius.
- **Entry:** moving onto a known port's harbor tile → port-entry sequence
  (greeting banner with `Port.flavor`, day count, desertion check §4.8.2)
  → route to `port_screen.tscn`. Moving onto an *unknown* port's harbor tile
  discovers it (adds to `known_ports`) and enters normally.
- **Exit:** "Set sail" from the port screen returns to `world_map.tscn` with
  the fleet on the harbor tile and `clock_fraction` reset to 0.

### 4.12 Minimap

- HUD element, 256×192 px (2 px per tile), per `80-*` §HUD.
- Renders explored tiles only: a tile is explored after being within the
  sighting radius (§4.11) of the fleet. Explored set is not saved in Phase 1
  (re-explored on load; known limitation, fixed with Phase-3 map work).
- Known port markers drawn as 2×2 px dots in the port's nation color; fleet
  as a 2×2 px white dot.

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
    "sighting_radius": 8,
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
- **Entering map edge:** tiles outside 0..127 / 0..95 are impassable.

## 7. Acceptance Criteria

- [ ] From Lisbon, sailing west reaches a 50%-storm zone within one day
      (demo-loop step 5 reachable).
- [ ] Provisions 2g / water 1g / wage 2g are the only consumption prices and
      match `30-*` market UI and `10-*` harbor-relief math.
- [ ] Ledger step order (§4.5) is implemented verbatim and unit-testable in
      `sailing_sim.gd` without a running scene.
- [ ] Morale tiers use exactly the §4.8 thresholds; mutiny/desertion trigger
      only via the specified checks.
- [ ] Game over fires only from `"starvation"`, `"scurvy"`, `"sunk"`.
- [ ] Port entry/exit round-trips position and resets `clock_fraction`.
- [ ] Minimap dimensions and sighting radius (8) match `80-*` HUD spec.
