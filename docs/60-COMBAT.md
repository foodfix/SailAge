# 60 — Combat (Sea Battles & Duels)

## 1. Purpose & Phase

Specifies turn-based grid-lite sea combat: encounter generation, battle grid
setup, turn order, movement, cannon/ram/boarding, the captain duel, damage,
surrender, capture, loot, retreat, and enemy AI. Gates **Phase 2**. Uses the
Phase-1 ship/fleet/stat data unchanged.

**Phase 5 rewrite (§4.1 + §4.11.11).** The 3-marker hostile system
(`scripts/world/encounters.gd`, kinds `pirate`/`navy`) is replaced by the
national NPC fleet ecology of `scripts/world/npc_fleets.gd` — 8 roles,
historical trade lanes, NPC-vs-NPC auto-resolve with lootable wreckage,
named captains — with runtime pathfinding reduced to pursuit-only A*. The
battle grid, duel, damage and aftermath rules (§4.2–§4.11.10) are unchanged,
and the S10 descriptor shape is unchanged (§4.11.11.3).

**Phase 7 (§4.11.12–§4.11.14).** Equipment grows to the 24-item tiered
content set with two new modifier keys and rare named-pirate drops; the
ecology docks lane traders at alignment-open ports, serves every neutral
port with nationless coasters, and credits port-call tariff into host
treasuries. The battle rules (§4.2–§4.11.10) are unchanged.

**Phase 8 (the RPG overhaul, 2026-11-02).** Every battle-side stat moves
onto the Person model (`50-*`): the duel rolls swordplay + courage +
charisma instead of the retired `combat` stat (§4.6/§4.11.6), AI ships
rate their captains' canon cards instead of `5 + tier` (§4.11.5), gunnery
gains the flagship damage/hit term and the chain / armor-piercing shot
unlocks (§4.4), AI surrender becomes a courage-flavored roll (§4.7),
loot and XP gain the valuation and level multipliers plus the boarding
morale bonus (§4.8/§4.11.10), the right-click funnel widens into the
picker / hail / intercept interaction layer (§4.11.15; screens per
`80-*` §4.10), and the Phase-5 named-pirate respawn machinery is
retired for the captain return queue (§4.11.11.4 amended, §4.11.15).

**Phase 9 (naval-combat realism & AI, 2026-11-03).** Phase 9 replaces the
MP-grid battle with the velocity-physics layer (§4.2–§4.6a pins) and adds
side-level morale (§4.8a), the profile-driven enemy AI with the
fleet-command layer (§4.9a–§4.9c), the T3 lookahead ceiling (`ai_level`),
the S10 rebuild and the S21 zero-write sandbox (§4.12.4, `80-*` §4.7.16);
the aftermath/economy rules (§4.11.10) keep their shape.

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/combat/battle_screen.tscn` | grid battlefield scene (S10) |
| `scenes/combat/duel_modal.tscn` | captain duel modal (S11) |
| `scripts/combat/battle_sim.gd` | turn engine (RefCounted, deterministic-seedable) |
| `scripts/combat/ai_fleet.gd` | enemy decision rules (§4.9) |
| `scripts/world/npc_fleets.gd` | world-map NPC fleet ecology — 8 roles, lane routing, auto-resolve, wreckage (§4.1, §4.11.11) |
| `scripts/world/interactions.gd` `scripts/world/hail_options.gd` | Phase-8 interaction layer — verb dispatch + hail option builder (§4.11.15); scenes `fleet_picker.tscn` / `hail_modal.tscn` per `80-*` §4.10 |
| `data/npc_config.json` `captains.json` `named_pirates.json` `trade_routes_built.json` | fleet content (schemas `10-*`); Phase 7 added the `neutral_coasters_mult` line (§4.11.14) and `named_pirates.drop` (§4.11.13); Phase 8 retires `npc_captains.json` — the closed canon `captains.json` carries every captain card (§4.11.11.4) |
| `data/equipment.json` | Phase-2/7 equipment content set (§4.11.13 — 24 tiered items from Phase 7) |
| GameState additions | `npc_fleets` (fleet dicts, §4.11.11), `wrecks`, battle outcomes; Phase 5 saves as `SAVE_VERSION = 5` (no migration, v4 refused — `90-*` §8.2) |

## 3. Dependencies

`10-*` (ShipType/Equipment schemas; `npc_config.json`/`captains.json`/
`named_pirates.json`/`trade_routes_built.json` — the captain canon is the
Phase-8 closed roster that replaced `npc_captains.json`),
`20-*` (map constants, weather reuse, day-tick order §4.3), `30-*` §4.4
(the trader market rules NPC traders decide by), `40-*` (ship instances,
durability, cargo, FLEET_MAX), `50-*` (the Person model — attributes and
skills, equipment modifiers, reputation; the Phase-8 successor of the
retired four-stat character), `70-*` §4.5 (bounty tiers, piracy rep and
the Phase-8 fame extension), `80-*` (S10/S11 conventions, fleet markers,
the §4.10 interaction layer), `90-*` (save blocks, autoload order).

## 4. Systems / Mechanics

### 4.1 The NPC fleet ecology (world map) — Phase 5 rewrite

The Phase-2 3-marker hostile system is retired: `GameState.hostile_fleets`
becomes `GameState.npc_fleets` (key `kind` → `role`; `pirate`→`pirate`,
`navy`→`hunter`), `scripts/world/encounters.gd` is deleted, and the sea is
sailed by a persistent, nation-owned fleet ecology. The detailed pins live in
§4.11.11; the module API in §4.12.3. Everything else in this doc — battle
grid, duel, damage, aftermath (§4.2–§4.11.10) — is unchanged.

- **One world grid.** Fleets live on the single Terra Vera world grid
  (`20-*` §4.1): their `cell` values are tile coordinates on the
  **4320×2160** Phase-6 grid (`IMPLEMENT-Phase6.md` §2.0), and **all
  x-distance math is wrap-aware** — a fleet at `x = 4318` is 2 tiles from a
  fleet at `x = 0`, and no distance below ever exceeds `4320/2 = 2160`. A
  tile is 5 nm, so every tile distance below is 5 nm per tile (the Phase-5
  2160×1080 grid at 10 nm per tile was rescaled by the Phase-6 sweep).
- **Fleet shape (locked).** All fleets are save-shaped as
  `{id, role, nation_id, cell(vec2), route, cargo, captain, specialty?,
  cooldown_until_day, …}`; pirates keep `nation_id: ""`. Budgets multiply by
  the density preset (`ceil` per role), from `npc_config.json` (`10-*`).
- **Player surface.** Contact and the right-click attack funnel are pinned
  once, in the §4.11.11.2 table; the trader decision rule is `30-*` §4.4.
  (Phase 8, 2026-11-02: right-click opens the `fleet_picker` verb layer —
  inspect / talk / attack, §4.11.15 — whose attack verb ends in the same
  §4.11.11.2 funnel.)

#### 4.1.1 The 8 fleet roles & budgets (locked)

| Role | Budget (normal) | Computed @ 6 nations / 100 ports | Behavior (pin) |
|---|---|---|---|
| `trader` | `ceil(own_ports × 1.25)`/nation | 25+27+17+28+23+14 = **134** | own-nation routes via lane graph; 2-day dwell; joint profit-per-day decision; sells only where `factor > 1.0` |
| `coaster` | `ceil(own_ports × 0.75)`/nation | 15+15+14+14+11+8 = **77** | visual-life small craft; adjacent-port spokes; hold ≤ 10, trades ≤ 5/call; **never triggers contact**, raiders ignore; **not attackable — intimidate-only** (Phase 8, 2026-11-02: the picker exposes no attack verb for a coaster, retiring the old "attacking one is ordinary piracy; loot `25 + floor(day/10)`g" line — a successful intimidate takes half its cargo, floor per good, + pirate fame +5, §4.11.15) |
| `patrol` | `ceil(own_ports / 6)`, min 1 | **19** | cycles its nation's lanes, docking en route; same-nation traders within Chebyshev 20 count escorted; halves pirate/privateer spawn rolls in its 30-tile zone |
| `courier` | 2/nation | **12** | capital ↔ own-ports dispatch runs (sightings/rumors only — no quest mechanics this phase) |
| `privateer` | 2/undirected rivalry pair | **12** | stations on its sponsor's rivals' major lanes (chokepoint-biased); hunts only those rivals' fleets; defeating one: +2 rep with **each** of the two sponsor rivals |
| `pirate` | `8 + unpatrolled_zones` (computed daily: navy 30-tile zones lacking a patrol) | ≈ **25** | camps tagged chokepoints; prefers nearest trader/patrol within Chebyshev 10 |
| `hunter` | bounty-only, ≤ 1 per bountied nation | transient ≤ 6 | rep ≤ −50 navy hunter; sails the lane network to its intel target and pursues only at short range (§4.11.11.1 hunter intel) |
| `treasure` | 1/nation per season | transient ≤ 6 | see Aliveness table (§4.11.11.4) |
| Core cap | sum of the above at normal | **272** | + 6 treasure + ≤ 6 hunters = 284, rounded up with slack ⇒ **global cap 288** (wrecks are stored in `GameState.wrecks`, never counted) |

#### 4.1.2 Spawn flow (locked)

Flow (`npc_config.json` `flow` block): `spawns_per_day_base 4` → trickle
`max(4, ceil(cap / 50))` fleets/day; **initial fill**: `new_game` spawns
half the cap immediately (seeded, distributed on lanes near ports);
`path_budget_ms_per_day 250` for pursuit A* (overflow = lose the chase that
day); `trade_units_per_port_call 30`; `coaster_trade_units 5`;
`absolute_cap 2048`.

The trickle, the `new_game` initial fill and the §4.1.1 budgets are the only
spawn levers — the Phase-2 per-day spawn rolls and the per-kind spawn
immunity are retired with the marker system (§4.11.11.1).

### 4.2 Battle grid setup

- **Grid (Phase 9):** 48×30 cells (`x ∈ 0..47`, `y ∈ 0..29`), rendered at
  32 px — a 1536×960 world over the 1280×584 viewport (camera / minimap /
  bottom-bar presentation in `80-*` §4.7.1). Open sea, no obstacles — terrain
  (reef/coast tiles) stays OUT OF SCOPE (the Phase-2 lock, unchanged).
- **Deployment bands (W5 pacing correction 15 — the tournament-proven start
  is now THE start):** player ships in the west band `x ≤ 12`, enemy ships in
  the east band `x ≥ 35`, one ship per cell, flagship centred per side. The
  concrete deployment cells by fleet index 0–4 are pinned in §4.11.2 —
  player `(10,15) (10,14) (10,16) (10,13) (10,17)`, enemy
  `(37,15) (37,14) (37,16) (37,13) (37,17)` (27 cells apart), with pinned
  initial velocities `vel = (1,0)` (player) / `vel = (−1,0)` (enemy). A band
  overflow (more than 5 ships) continues the in-band scan. *(User-locked
  pacing amendment, 2026-11-04: the 43-cell gap cost 12–15 rounds of pure
  approach — the tournament variant had already proven the 27-cell +
  closing-velocity start resolves bouts in 10–13 rounds, so standard
  battles adopt it and the variant distinction retires; the sandbox
  `deployment` field stays for schema forward-compat and maps to the same
  start.)*
- **Ship unit** = its ship instance: durability, crew, cannons, cargo carried
  in (unchanged).
- **Battle-condition lock (Phase 9):** `wind_dir` (the 8-token **wind-FROM**
  id of `20-*` §4.7.1) and `weather` (engine ids `calm|fair|strong|storm`,
  `20-*` §4.7) lock at battle start and stay constant for the whole battle.
  The battle also reads the **decoded current vector at the contact tile**
  (`currents.png`, reversal applied — `20-*` §4.16) **regardless of the
  world's `current_mode`** (correction 1). All three are injected through the
  config keys pinned in §4.12.1.
- **Weather effects (battle):** storm ⇒ all cannon damage ×0.75 **and
  hooking forbidden** (§4.6a); strong ⇒ cannon damage ×0.9 (Phase-9 pin).
  Wind speed effects run through the per-class `wind_factor` /
  `direction_factor` tables consumed by `cap_eff` (§4.3a; `20-*` §4.7 /
  §4.4).

### 4.3 Turn structure

- **Rounds:** each round, every living ship acts once in **initiative order**
  generated **once at battle start**: descending
  `ShipType.speed + sail_speed_delta` (correction 2, §4.11.12), ties break
  player-before-enemy, then ascending fleet index. A unit destroyed before
  its slot is skipped and never acts; the order is never re-sorted
  mid-battle.
- **Per turn, three phases in order (mechanics pinned in §4.3a):**
  1. **Pick a new velocity** — a legal `vel` per the §4.3a constraints.
  2. **Integrate movement** — `pos += vel` resolved as the Bresenham sweep
     (§4.3a); an enemy-occupied first cell becomes a ram (§4.5).
  3. **At most one action:** cannon (naming the side) / ram / board / hold.
  Actions resolve immediately; non-blocking log lines suffice as the
  presentation (Phase-2 rule, unchanged).
- **Historical (Phases 2–8, retired):** movement was MP-based —
  `MP = battle_mp(ShipType.speed) = speed / 4` (integer division,
  `{16→4, 20→5, 24→6}`), orthogonal step = 1 MP, diagonal = 2 MP, a sail
  equipment's `speed` delta added after the division, refreshed to full at
  each of the ship's turns, unspent MP discarded. **Retired** by the Phase-9
  velocity model — this note is kept only as the historical record (§4.3a
  replaces it; `battle_mp` is gone).

### 4.3a Velocity, inertia & sweep (Phase 9)

- **Unit state (per ship):** `pos: Vector2i`, `vel: Vector2i`, `heading8`,
  `reload_port`, `reload_starboard`, `speed_debuff_turns`, `crew` — these
  replace the retired Phase-2 `cell` / `mp` / `mp_debuff` fields.
- **Velocity pick legality (enforced in this order, §4.11.4):** the bucket
  angle between the new velocity and the old velocity is ≤
  `battle_turn_rate` (heading-bucket sense, 22.5° boundaries); the magnitude
  delta `|‖new‖ − ‖old‖| ≤ battle_accel`; `‖new‖ ≤ cap_eff`. From `vel = 0`
  (standstill) **any direction** is legal with magnitude ≤ `battle_accel` —
  the angle constraint is relaxed, the cap constraint still applies (a
  becalmed ship cannot start moving). A pick of `vel = (0,0)` is legal
  whenever the magnitude-delta constraint holds (the angle constraint reads
  only a non-zero old velocity); `vel = 0` keeps the last heading.
- **Magnitude & heading:** `‖vel‖ = sqrt(vx² + vy²)` — floating point is
  used **only** for the magnitude (the existing `floor(float(...))` style).
  `heading8` derives from `vel` at the 22.5° boundaries via **integer
  dot/cross comparisons** against the 8 compass rays — never `atan2`,
  portable and deterministic across runtimes (decision 1).
- **Overshoot clamp:** a chosen velocity whose magnitude exceeds `cap_eff`
  clamps **along its own direction** (component floor) to `cap_eff`.
- **`cap_eff` (decision 2, corrections 1–3):**
  `cap_eff = clamp(floor(battle_max_speed × wind_factor(weather, class) ×
  direction_factor(heading8, wind_dir)) ± current_mod − debuff,
  0, battle_max_speed) + sail_speed_delta`, where `wind_factor` is the
  per-class weather table of `20-*` §4.7 (oar is 1.0 in every weather;
  hybrid per its column) and `direction_factor` is the `20-*` §4.4 table
  read at the **ship's own class column** (the `sail` column stays the
  fallback for an unknown class). Calm weather ⇒ `direction_factor`
  identity 1.0 for every class — the world rule of `20-*` §4.7.1. The
  `+ sail_speed_delta` (correction 2, §4.11.12) applies **after** the clamp
  and is **not** clamped back into `[0, battle_max_speed]`. `debuff` = 1
  while `speed_debuff_turns > 0` (chain shot, §4.4b), and the debuff term
  may never reduce `cap_eff` below 1 (the chain-shot cap floor — a cap of 0
  is unreachable in play: calm weather keeps `direction_factor` at the
  identity 1.0 (the normative calm rule above), so the worst natural case,
  a `battle_max_speed` 2 sail hull in calm against the wind, floors to
  `floor(2 × 0.8 × 1.0)` = 1). *(W3 gate amendment: the earlier parenthetical
  example — "into the wind, `floor(2 × 0.8 × 0.5)` = 0" — contradicted the
  calm identity and the shipped hull table; the identity reading wins,
  `test_battle` pins it.)*
- **Current modifier (new battle-domain pin, correction 1 — the `20-*` §4.16
  world rule is multiplicative and is deliberately NOT quoted here):** with
  `current_mod` keyed off the relative heading8 bucket between the ship's
  `heading8` and the locked contact-tile current's flow direction — bucket
  ∈ {0°, 45°} with current strength ≥ 2 → `current_mod = +1`; bucket
  ∈ {135°, 180°} with strength = 3 → `current_mod = −1`; strength 0 (no
  current) never modifies. All other bucket/strength combinations modify
  nothing.
- **Class constants:** `battle_accel` = 2 for `oar`, 1 for every other
  class. `battle_turn_rate` = 90° for `latin` / `sloop` / `galiot` /
  `pinnace` / `dhow` / `xebec` / `galley`; 45° for `caravel` / `brigantine` /
  `nao` / `carrack` / `galleon` / `galleass` / `fluyt` / `junk` /
  `caravela_redonda` — 7 + 9: the 16 hulls partition exactly once across the
  two tiers (schema in `10-*` §4.3; the data fields land in Phase 9 W2).
- **Sweep integration:** `pos += vel` resolves as a **Bresenham walk** cell
  by cell along the velocity; the **first occupied cell stops the ship** —
  enemy-occupied ⇒ ram (§4.5); friend-occupied or out-of-bounds ⇒ stop at
  the **prior cell** (zero damage, no partial entry).
- **`legal_velocities(unit)`:** every integer vector in the Chebyshev box
  `|vx|, |vy| ≤ battle_max_speed` satisfying the constraints above,
  enumerated in **(y, x) lexicographic order** — the enumeration order is
  the deterministic tie-break everywhere (§4.11.8, decision 13). The bound
  is ≤ 49 candidates at `battle_max_speed ≤ 3` (decision 13's pin);
  correction 3's speed-24 tier (`battle_max_speed = 4`) grows the box to
  9×9 = 81 candidates — the enumeration rule, not the 49 figure, is the
  normative part.

### 4.4 Cannon (Phase 9 broadsides)

- **Requirement:** the **named side** (port or starboard) has ≥ 1 loaded
  cannon (per-side reload, §4.4a) and the target within Chebyshev range
  `1..3` — `range_factor` 1.0 / 0.75 / 0.5 at range 1 / 2 / 3.
- **Broadside split (at battle start, decision 3):** `port = floor(n / 2)`,
  starboard takes the rest; the ship's **total** cannon count is retained for
  the outcome/rewards blocks (decision 14).
- **Arcs (relative to the ATTACKER's `heading8`, 8-bucket bearings):**
  port = {45°, 90°, 135°}, starboard = {225°, 270°, 315°}; the target's
  bearing bucket selects the side. A target in the 0° or 180° bucket
  (dead ahead / dead astern of the attacker) sits in **neither** arc and
  cannot be fired at from that position.
- **Damage stack (decision 3):**
  `damage = floor((side_cannons × 2 × range_factor + bonus) × weather ×
  shot × rake)` — the multipliers multiply and exactly **one** `floor`
  lands at the end, **after the weather term**: weather = storm ×0.75 /
  strong ×0.9 / otherwise ×1.0 (§4.2); shot = the §4.4b shot-type
  multiplier; rake = ×1.25 when the target's bearing bucket **relative to
  the TARGET's own `heading8`** ∈ {0°, 180°} (纵射 rake — the shot runs the
  target's deck line).
- **`bonus` (unchanged, §4.11.5):** the gunnery term —
  `floor(effective_gunnery / 25)` for the player flagship, the captain-card
  cannon-rating term for every captain-card ship.
- **Gunnery (player flagship; Phase 8, 2026-11-02 — replaces the Phase-2
  gunner-officer `effective_combat` bonus, retired with the four-stat
  model):** the flagship's cannon damage and its hit term gain
  `+ floor(effective_gunnery / 25)`, where `effective_gunnery` is the
  player's gunnery plus the in-post gunner officer's true value (`50-*`
  officer-contribution rule). The grid battle resolves a volley
  deterministically (in range = it connects; there is no hit roll), so
  the damage term is the only consumer of the "hit/damage
  `+floor(skill/25)`" magnitude today — the hit side rides the same
  locked value and is never a second formula.

### 4.4a Reload (Phase 9 — per side)

- **Formula (decision 5 as amended by the W5 pacing correction 14 — replaces
  `RELOAD_ROUNDS = 2`):**
  `reload_turns = clamp(2 − floor(gunnery / 50), 1, 2) +
  (crew_ratio < 0.5 ? 1 : 0)` with `crew_ratio = crew / crew_min` —
  **2 turns below 50 gunnery, 1 turn at 50+** (a hull at full gunnery fires
  every round), low crew adds a turn. *(User-locked pacing amendment,
  2026-11-04: the source-plan `3 − gunnery/50` clamp left a typical hull
  firing every 3–4 rounds — on the 43-tile deployment that made combat
  outlast the approach; the fun-first ruling halves the base cycle while
  keeping the gunnery perk.)*
- **Gunnery source (pinned):** the player flagship uses `effective_gunnery`
  (the §4.4 term); player escorts and AI captain-card ships use their captain
  card's `skills.gunnery`; a legacy fleet without cards falls back to
  `10 + 10 × tier` (the same fallback family as the courage roll, §4.7).
- **Per side:** the sides reload **independently** — after a side fires,
  `reload_side = round + reload_turns`; that side may fire again only when
  `round ≥ reload_side` (the turn-engine pin, §4.11.4).
- **Historical:** the Phase-2–8 single `RELOAD_ROUNDS = 2`
  (`reload_until_round` on the ship) is **retired**.

### 4.4b Shot types & the deterministic AI shot rule (Phase 9)

Four shot types; the §4.4 damage stack carries the shot multiplier, and the
gates read the §4.4a gunnery source:

| Shot | Gate | Effect |
|---|---|---|
| round | none (default) | the §4.4 stack as-is (multiplier ×1.0) |
| chain | gunnery ≥ 25 (`skill_gates`) | damage ×0.75 **and** target `speed_debuff_turns += 2` (the §4.3a cap debuff, chain floor-1 rule included) |
| armor-piercing | gunnery ≥ 50 (`skill_gates`) | damage ×1.25 and ignores the target's `armor` equipment modifiers (§4.11.12) |
| grape | **no gate, range 1 only** | hull `floor(same-range round × 0.5)` **plus** crew `floor(same-range round × 0.5)` |

"Same-range round" = the round-shot damage the §4.4 stack produces at that
range with the same side, bonus and multipliers. Grape's crew kill feeds the
duel crew term (`min(floor(crew / 5), 20)`, §4.11.6) through the §4.11.5
casualty rules — the kill **is** the grape volley's casualty term (§4.11.5),
not an addition to the standard `/20` divisor; grape's hull damage logs
through the existing `battle.log.cannon` line (no new string).

**Deterministic AI shot rule (T2/T3 shared; evaluated in order; always
OUTSIDE any T3 enumeration — decisions 4/13):**

1. Target `floor(‖vel‖) ≥ 2` **and** its current velocity strictly increases
   its Chebyshev distance to the attacker → **chain**.
2. (Target orthogonally adjacent **or** within Chebyshev ≤ 2) **and** own
   `crew + duel_rating > target crew + target duel_rating` (each side's own
   duel rating, §4.11.5) → **grape**.
3. The target is a player-side ship whose `equipment.armor` slot is
   non-empty → **armor-piercing** (master pin: AI ships carry no armor slot
   — ledger-recorded).
4. Otherwise → **round**.

### 4.5 Ram (Phase 9)

- **Sweep ram:** triggered when the §4.3a sweep enters an **enemy-occupied**
  cell with `floor(‖vel‖) ≥ 1`. The adjacent-action ram (the §4.3 action
  against an orthogonally adjacent enemy) is preserved as an action.
- **Multiplier (decision 7):**
  `mult = (1 + 0.25 × (floor(‖attacker vel‖) − 1)) ×
  (attacker approach bearing bucket ∈ {0°, 180°} vs the TARGET's heading8
  ? 1.15 : 1.0)` — speed builds impact; a bow/stern approach ×1.15.
- **Damage:** target `floor(att_max_dur × 0.25 × mult)`, self
  `floor(att_max_dur × 0.10 × mult)`; `att_max_dur` is the **effective** max
  durability (§4.11.12). An `oar`/`hybrid` attacker multiplies the target
  damage ×1.25 (the galley identity rule, preserved; folded into the same
  single floor, §4.11.5).
- If a ram sinks both ships the attacker resolves **LAST** (§6).

### 4.6 Boarding & captain duel

- Action against an enemy ship satisfying the **§4.6a hook condition**
  (orthogonal adjacency + both ships at `floor(‖vel‖) ≤ 1` + weather ≠
  storm) → hook (both ships' `vel = 0`) → duel modal (S11). The duel itself
  is §4.11.6, unchanged.
- **Duel (Phase 8 formula, 2026-11-02):** best-of-5 rounds. Each round both
  sides roll `base + rand(0, 20)`; higher wins the round; tie = no score.
  First to 3 round-wins takes the duel. The player's `base` =
  `swordplay + floor(courage / 20)` + equipment deltas (§4.11.12) — the
  Phase-2 `effective_combat` is retired. A captain-card ship rolls
  `min(floor(crew / 5), 20)` + its captain's **duel rating** =
  `captain swordplay + floor(captain courage / 20)` (computed once at
  fleet composition, §4.11.5 — this replaces the `5 + fleet tier`
  stand-in). **The defender adds `+ floor(charisma / 20)`** — the
  defending side's own charisma (the player's when the player defends,
  the captain card's otherwise). Full pin §4.11.6.
- **Player wins duel:** the ship is **captured**: if `fleet.size <
  FLEET_MAX` **and ≥ 1 idle officer** is available (the Phase-8 capture
  gate, §4.11.15), it joins at 25% current durability minimum 1, cleared
  crew, cargo intact; otherwise — full fleet **or no idle officer** — it
  is looted (cargo taken to capacity) and scuttled (the loot-convert
  fallback; the after-action dialog names the gate that failed).
- **Player loses duel:** the player's ship is captured — if it was the
  flagship: the next ship becomes flagship (rules of `40-*` §4.4); if no
  ships remain → game over `gameover.captured` (new reason added in Phase 2;
  extends `20-*` §4.9 list).
- Retreat from duel: none — boarding commits.

### 4.6a Hook & board (Phase 9)

- **Hook condition (decision 8):** orthogonal adjacency **+ both ships at
  `floor(‖vel‖) ≤ 1`** **+ weather ≠ storm** → the hook succeeds and **both
  ships' `vel = 0`** (correction 7). Storm forbids hooking outright (§4.2).
- **Duel:** §4.11.6, unchanged. Crew can reach **0 and clamps there**
  (correction 7) — a 0-crew ship still sails; its **only** penalties are the
  `crew_ratio < 0.5` reload +1 (§4.4a) and the weakened
  `min(floor(crew / 5), 20)` duel term (§4.11.6) — nothing more.
- **Strike semantics:** the boarding **loser strikes** — a **player** loss
  resolves as §4.11.7 `surrender` (fleet retained, the existing cargo
  rules), an **AI** loss resolves as **capture** (§4.11.7, the Phase-8
  idle-officer capture gate included).
- **Presentation:** S10 shows a highlight ring on hookable targets
  (`80-*` §4.7.1); AI ships decelerate into the hook window (§4.9a).

### 4.7 Damage, sinking, surrender

- Durability 0 at battle → ship sinks immediately; cargo lost (no salvage in
  battle, consistent with `40-*` §4.4).
- **AI surrender (Phase 8 roll, Phase 9 gate):** at its turn, an AI ship
  whose **side morale ≤ 20** (the §4.8a morale model) **and** whose
  durability ≤ 25% max rolls surrender — chance =
  `clamp(25 − floor(courage / 10), 10, 40)%` **plus
  `floor((20 − morale) / 2)` percentage points** (the base keeps its clamp;
  the morale modifier adds on top, so the effective ceiling is 50% at
  morale 0). **Effective courage** = the ship captain's card courage + the
  profile `courage_mod` (§4.9a); a legacy fleet without cards falls back to
  `10 + 10 × tier`. Drawn from the §4.11.1 battle stream; a failed roll
  re-rolls on the ship's next turn. A surrender resolves as a capture as if
  duel-won, no duel — the Phase-8 idle-officer capture gate included
  (§4.11.15). (The Phase-2 automatic surrender — the "fixed < 25%" reading —
  is retired, and so is the Phase-8 proximity clause "player ship within 3
  tiles": the Phase-9 gate is exactly morale ≤ 20 ∧ durability ≤ 25% max.)
- **Side collapse (Phase 9, AI-side only — correction 5):** at side morale
  ≤ 10 every living AI ship **strikes colors at its next turn with NO
  roll**, resolved as the §4.7 surrender above. Player ships **never**
  auto-surrender — low player morale is a HUD warning only; the player may
  offer surrender from the battle menu: battle ends, enemy takes flagship
  cargo only, ships retained (pirates), or flagship itself (navy with
  bounty — which clears the bounty, `70-*`).

### 4.8 Loot & aftermath

- Victory (all enemy ships sunk/captured/surrendered/retreated): loot = all
  cargo of captured ships (already handled) + gold =
  `Σ sunk_ship base_price × 0.05` (salvage sale abstraction). **Phase 8:**
  every haul gold valuation is credited ×(1 + (appraisal + negotiation) /
  400), clamped to [×1.0, ×1.5] (§4.11.10).
- Battle XP: +10 combat-relevant XP per sunk/captured ship to sailing XP pool
  (`50-*` §4.3 gains `+2 per battle round survived`? — locked: +10 XP per
  enemy ship neutralized, +5 per round survived). **Phase 8:** the total
  is ×(1 + level / 20), floored once (§4.11.10).
- **Boarding-victory morale (repinned Phase 9):** a boarding duel's morale
  effect is the §4.8a event table — boarding win **+10** / boarding loss
  **−10**. The Phase-8 flat +5 is absorbed into that table and retired.
- Reputation: defeating pirates +2 with the two nearest ports' nations;
  attacking/sinking navy ships applies `70-*` piracy deltas — **Phase 8
  adds −20 fame** when the attacked fleet was not hostile (§4.11.10).
- Return: world map at contact tile; the hostile marker despawns; spawn
  immunity 3 days (Phase-2 rule; retired in Phase 5, §4.11.11.1).

### 4.8a Side morale (Phase 9)

One morale value **per side** (not per ship), range 0–100:

- **Start.** Player side starts at `GameState.morale`. AI side starts at
  `clamp(40 + flagship-captain courage, 20, 90)` — `courage` read from the
  enemy flagship's captain card (`50-*` Person model); a legacy fleet
  without a card falls back to `10 + 10 × tier` (the same legacy fallback
  as gunnery — correction 6).
- **Events (both sides):**

  | Event | Delta |
  |---|---|
  | Friendly ship sunk | **−15** |
  | Ship captured | **−20** |
  | **Flagship sunk** | **−30 TOTAL** — replaces, never adds to, the friendly-sunk −15 on that event (correction 5) |
  | Side suffering a rake volley | **−5** |
  | Boarding win (§4.6) | **+10** |
  | Boarding loss (§4.6) | **−10** |

- **Gates.** Side morale ≤ 20 **and** ship durability ≤ 25% ⇒ the §4.7
  surrender roll, widened by `+ floor((20 − morale) / 2)` pp. Side
  morale ≤ 10 ⇒ **every living AI ship strikes colours at its next turn,
  no roll** — AI-side ONLY: player ships never auto-strike (§4.7), and low
  player morale is a HUD warning only (correction 5).
- **Writeback.** The outcome block carries `morale_delta` (§4.12.2); the
  caller applies `GameState.morale = clamp(start + delta, 0, 100)` through
  the §4.12.4 sequence — the old direct +5 write of §4.8 is retired.
  Tournament bouts participate normally.
- Both sides' morale values ride `snapshot()` / `restore()` (§4.12.1).

### 4.9 Enemy AI — the two-level ramp (Phase 9)

The enemy AI is a two-level ramp: **T2 deterministic greedy** (§4.9a) and
**T3 one-ply lookahead** (§4.9c), both consuming the per-kind profile
(§4.9a) and — for multi-ship AI fleets — the fleet-command orders (§4.9b);
`ai_level ∈ {0, 1}` selects per battle kind. The Phase-2 six-rule priority
list that stood here is **retired** — its semantics live on verbatim in
§4.9a's T2 priority list.

Seeded RNG (§4.11.1: one stream per battle, seeded from save state + contact
tile + day) makes AI and duel rolls reproducible for tests.

### 4.9a Profiles & the T2 priority list (Phase 9)

- **The profile block.** `data/npc_config.json` `ai_profiles` — nine kinds
  × nine keys (schema + value table pinned in `10-*` §4.10). The six live
  T2 keys are `archetype / aggression / preferred_range /
  flee_below_hp_pct / focus / courage_mod`; `formation` feeds §4.9b;
  `ai_level` feeds §4.9c.
- **Lookup rule (correction 8).** Row = `ai_profiles[kind]`; a `hunter`
  battle reads the `navy` row (mirrors `NpcFleets.composition_kind`); the
  `coaster` row is forward-compat + sandbox-only (coasters are
  intimidate-only, never battle — §4.1.1).
- **T2 priority list** (verbatim semantics; deterministic; top-down first
  match) — per AI ship per turn:
  1. **Surrender roll** (§4.7 — gate widened by morale; effective courage
     = card courage + `courage_mod`).
  2. **Flee** — ship hp% < `flee_below_hp_pct`, or `aggression < 25`, or
     side morale ≤ 20 (the pre-fleet-layer reading): take the first legal
     velocity strictly increasing Chebyshev to the nearest player ship
     (ties §4.11.8); hold when none.
  3. **Fire** — a loaded side's arc contains a target: fire (focus target
     per §4.11.8, rake preference, shot type by the §4.4b rule).
  4. **Kite** — both sides reloading: hold/steer to keep Chebyshev ≈
     `preferred_range` (§4.11.8 tie-breaks).
  5. **Board** — hook legal (§4.6a) AND (own crew + duel rating > target's
     OR target hp% ≤ 25). **Ram** — `floor(‖vel‖) ≥ 2` AND own cannons +
     duel rating > target's. **Close** — otherwise steer toward the
     nearest player ship, decelerating to `‖vel‖ ≤ 1` at Chebyshev ≤ 2 so
     the hook window opens. **Hold** — last resort.

  All tie-breaks are pinned in §4.11.8.

### 4.9b Fleet-command layer (Phase 9)

Per round, for every AI ship, the fleet commander emits an **order
five-tuple** `{station: Vector2i, desired_heading8: int,
desired_speed_band: [lo, hi], assigned_target: unit, discipline: bool}` —
pure deterministic, zero RNG.

**State machine** `form → close → engage → wear → break`, per formation:
`line_ahead` runs all five states; `column` = form/close/engage; `screen`
= flagship-radius-3 screen + free fire; `swarm` = target assignment only.

| State | Behavior | Exit |
|---|---|---|
| `form` | each ship sails to its formation slot (1-cell intervals along the reciprocal of the flagship heading8; column = lateral spacing) | every living ship within station deviation ≤ 2, or after 3 rounds (bail-out to `close`) |
| `close` | column cruise toward the enemy, `desired_speed_band` = full | nearest enemy Chebyshev ≤ 5 → `engage` |
| `engage` | hold broadside-on (`desired_heading8` = perpendicular to the enemy bearing ±90° bucket), attack the **assigned** target, `discipline = true` (off-station candidates are hard-removed from the candidate set) | enemy bearing vs the queue heading buckets 0°/180° → `wear`; side morale ≤ 20 → `break` |
| `wear` | the whole column turns ≤ `turn_rate` per round toward the new heading, LOCKED until every ship is within ±1 bucket | every ship within ±1 bucket → `engage` |
| `break` | dissolve to swarm (target assignment kept) | terminal for the battle |

- **Hysteresis:** every state holds ≥ 2 rounds before a non-forced
  transition; `wear` cannot be interrupted.
- **Anchor & succession:** anchor = flagship pos + heading8; when the
  flagship sinks, the lowest living fleet index takes the anchor AND
  inherits the state machine.
- **Target assignment:** in `engage`, targets distribute round-robin over
  the enemy by the profile `focus` ordering; at `aggression ≥ 80` the
  whole fleet focus-fires the focus-top target.
- Side morale ≤ 20 ⇒ `break` (the §4.9a flee rule covers single-ship /
  side morale before this layer engages).
- Implementation lands as `scripts/combat/fleet_commander.gd`
  (RefCounted, pure) — interface pinned in §4.12.3.

### 4.9c T3 one-ply lookahead (Phase 9)

`ai_level = 1` enumerates, on a `snapshot()`, every legal velocity
(`legal_velocities` — the §4.3a Chebyshev box in (y, x) lexicographic order;
≤ 81 candidates at the `battle_max_speed = 4` tier, §4.3a's derived bound)
× the action set {hold, best-target cannon per side, legal ram, legal
board}, applies each on `restore()`, and scores
`score = θ · φ` over NINE features: φ1 durability diff, φ2 cannon diff,
φ3 reload diff, φ4 arc fit, φ5 rake exposure, φ6 flagship danger, φ7
station deviation, φ8 friendly-blocked line, φ9 expected heading
alignment. Zero dice — deterministic evaluation.

- **Hard-rule layer (shared with T2 — W5-A pin):** the §4.9a ① surrender
  gate and ② flee rule apply to BOTH levels (they fire before the dispatch);
  T3 ranks the remaining candidates ③+.
- **The search leaves no trace:** every candidate is applied on the live sim
  and undone by `restore()`, which restores `rng.state` too (§4.12.1) — a
  cannon/board candidate's dice draws happen inside the candidate and are
  rolled back, so the post-search state is byte-identical to the
  pre-search state (snapshot equality includes the stream).
- **Normative φ feature table (W5-A master pin — the concrete formulas;
  "friendly" = the deciding ship's side, "enemy" = the opposing side; every
  total runs over LIVING ships; a side is *loaded* when `round ≥
  reload_side` and the side carries ≥ 1 cannon; all arithmetic is
  deterministic integers, divisions truncate):**

  | # | Feature | Formula |
  |---|---|---|
  | φ1 | durability diff | `(friendly total durability − enemy total durability) / 20` (integer division), evaluated AFTER the candidate |
  | φ2 | cannon diff | `(friendly total cannons − enemy total cannons) / 4` (integer division) |
  | φ3 | reload diff | `(friendly loaded side-count − enemy loaded side-count)` (each ship contributes 0..2) |
  | φ4 | arc fit | `(friendly loaded sides whose arcs contain a living enemy within Chebyshev 3) − (enemy loaded sides whose arcs contain a living friend within 3)` |
  | φ5 | rake exposure | `(friendly ships sitting in an enemy's rake position) − (enemy ships in a friend's rake position)` — rake = bearing bucket ∈ {0°, 180°} vs the TARGET's heading8; the θ weight is negative, so exposure hurts |
  | φ6 | flagship danger | `(my flagship at ≤ 25% durability ? 1 : 0) + (my flagship inside some enemy loaded arc within range ? 1 : 0) − (the enemy flagship's same two terms)` |
  | φ7 | station deviation | `Chebyshev(pos_after, order.station)` when a station exists (engage/wear/form/close orders), else 0 |
  | φ8 | friendly-blocked line | the count of friendly pairs (a, b) where b is alive, within Chebyshev 3 of a, and b sits exactly on a's heading-ray (the broadside lane blocked) |
  | φ9 | heading alignment | `4 − min(bucket_distance(heading_after, bearing to the nearest enemy), 4)` (0..4, higher = better) |

  Score = Σ θ[i] × φ[i]. The candidate action set pairs every surviving
  velocity with steer/hold, cannon per loaded side (each side's §4.11.8-best
  target: rake pool → profile `focus`), the first legal ram target
  (§4.11.8 pin 4's gates), and the first legal board target (the §4.6a hook
  + §4.11.8 pin 4 board gate). The cannon candidate's shot type derives
  from the §4.4b rule at application time (never enumerated).
- **θ:** one integer 9-array per archetype — `THETA_AGGRESSIVE /
  THETA_BALANCED / THETA_CAUTIOUS` consts in
  `scripts/combat/ai_search.gd`. The doc-first prior is
  `{10, 4, 2, 3, −5, −6, −2, −4, 2}` for all three; final integers come
  from the offline CEM run (`tools/battle_tune.py`) through the named
  master θ-finalization task (correction 11) — the doc is amended first,
  then the consts sync. Ties resolve by enumeration order (same seed ⇒
  same decision).
- **Shot type** stays rule-derived (§4.4b) OUTSIDE the enumeration.
- `discipline = true` removes off-station velocity candidates from the
  enumeration outright.
- **Per-kind `ai_level`** (pinned in `10-*` §4.10):
  pirate/privateer/navy/patrol/tournament = 1;
  treasure/trader/coaster/courier = 0.
- **Archetype → θ mapping:** pirate/privateer → aggressive;
  patrol/navy/tournament → balanced; treasure/trader/coaster/courier →
  cautious.
- **Performance pin:** avg ≤ 30 ms per decision; fallback on breach:
  pre-screen velocity candidates by φ9, halving the set.
- **Adoption gate** (recorded in `IMPLEMENT-Phase9.md`, not here): T3 vs
  T2 ≥ +10 pp win rate, 100% legal-action rate, the perf pin met —
  otherwise `ai_level = 0` content ships.
- Implementation lands as `scripts/combat/ai_search.gd` — interface
  pinned in §4.12.3.

### 4.10 Player retreat

- Menu action `battle.retreat`: ends battle; fleet returns to world map one
  tile back along its approach (must be passable, else adjacent pick);
  enemy marker gets +1 day pursuit cooldown. Retreating forfeits nothing but
  costs no XP; navy battles: rep delta still applies for ships already sunk.

### 4.11 Phase-2 normative pins (resolves every "task-owned" value)

Phase-1 implementation (see `IMPLEMENT-Phase1.md` "Completion record") showed
that a value left to a task gets invented differently by each task. Every
number §4.1–§4.10 leaves open is therefore fixed here, before code.

**Phase 9 rewrite (2026-11-03).** The Phase-9 velocity-physics model
(§4.2–§4.7 with the new §4.3a / §4.4a / §4.4b / §4.6a) moves every battle
number in this block onto that model, with the pins restated in place:
deployment (§4.11.2, the 48×30 grid), the turn engine (§4.11.4), damage
(§4.11.5), the T2 AI tie-breaks (§4.11.8), the end conditions (`stall`,
§4.11.9), the aftermath (§4.11.10) and the equipment wiring (§4.11.12).
The MP-era wording they replace is retired with the model (§4.3 historical
note).

#### 4.11.1 Battle seed

One `RandomNumberGenerator` per battle, seeded with plain integer arithmetic
(no `hash()` of a String, so the value is stable across platforms):

```
seed = day × 1000003 + contact.x × 7919 + contact.y × 104729
     + gold × 31 + fleet.size() × 17
```

`contact` is the player's world tile at contact, `day`/`gold`/`fleet.size()`
are the pre-battle `GameState` values. Duel rolls draw from the *same* stream,
after deployment and enemy composition, so a given seed reproduces the whole
battle including the duel round sequence (§6 "Duel RNG audit").

#### 4.11.2 Deployment (concrete cells — Phase 9, 48×30, correction 15)

Grid `x ∈ 0…47`, `y ∈ 0…29` (§4.2). One ship per cell, no two ever share a
cell.

| Fleet index | Player cell | Enemy cell |
|---|---|---|
| 0 (flagship) | (10, 15) | (37, 15) |
| 1 | (10, 14) | (37, 14) |
| 2 | (10, 16) | (37, 16) |
| 3 | (10, 13) | (37, 13) |
| 4 | (10, 17) | (37, 17) |

The flagship is vertically centred; extras alternate below/above it. Both
bands satisfy §4.2 (`x ≤ 12` / `x ≥ 35`) and open **27 cells apart** with
pinned initial velocities `vel = (1, 0)` (player) / `vel = (−1, 0)` (enemy)
and heading8 east (player) / west (enemy) — the closing start the
tournament variant proven-played; the variant distinction is retired
(correction 15, the sandbox `deployment` field maps to the same start).
A band overflow (more than 5 ships) continues the in-band scan (§4.2).
(The Phase-2 16×10 table this subsection used to pin, and the Phase-9
43-cell version correction 15 replaces, are both retired.)

#### 4.11.3 Enemy fleet composition (seeded, deterministic)

`rng` = the §4.11.1 stream, consumed in this order:

1. **Ship count:** pirate `1 + rng.randi_range(0, 2)` (1–3);
   navy `2 + rng.randi_range(0, 2)` (2–4).
2. **Hulls:** each ship independently rolls its `ship_type_id` uniformly
   from the locked order `["latin", "sloop", "caravel", "brigantine"]`
   (§4.1 "latin…brigantine").
3. **Cannon budget:** pirate `20 + floor(day / 30)`; navy `30 + floor(day / 30)`.
   Deal cannons one at a time, round-robin over ships in fleet order, skipping
   a ship whose `cannons` has reached its `armament_slots`, until the budget is
   exhausted or every ship is full.
4. **Crew / durability:** `crew = ShipType.crew_min`, `durability =
   ShipType.durability`, `provisions = water = 0`.
5. **Cargo (capture loot):** each ship carries `max(1, floor(capacity / 10))`
   units of one good, chosen uniformly from the 20 locked goods ids. This is
   the only cargo an AI ship has; §4.6 capture takes it intact.

#### 4.11.4 Turn engine rules (pin for `battle_sim.gd`)

- **Initiative (built ONCE at battle start):** descending
  `ShipType.speed + sail_speed_delta` (correction 2, §4.11.12), ties
  player-before-enemy, then ascending fleet index. A unit destroyed before
  its slot is skipped and never acts; the list is never re-sorted
  mid-battle (§4.3).
- **Three-phase turn (§4.3/§4.3a):** ① pick a new `vel` — legality enforced
  in this order: bucket angle to the old velocity (≤ `battle_turn_rate`) →
  magnitude delta (≤ `battle_accel`) → cap (`‖vel‖ ≤ cap_eff`, overshoot
  clamping along the chosen direction); ② sweep integration — `pos += vel`
  as the Bresenham walk (§4.3a); ③ at most one action: cannon (naming the
  side) / ram / board / hold.
- **Occupancy = the sweep rule:** a ship may never enter or pass through an
  occupied cell; the **first** occupied cell stops it — enemy-occupied ⇒
  ram (§4.5), friend-occupied or out-of-bounds ⇒ stop at the prior cell
  (zero damage, §4.3a).
- **Reload (per side):** `reload_port` / `reload_starboard`; after a side
  fires, `reload_side = round + reload_turns` (§4.4a); that side may fire
  again only when `round ≥ reload_side`. (The Phase-2 single
  `reload_until_round` / `RELOAD_ROUNDS = 2` pin is retired.)
- **One action per turn:** cannon, ram, board or hold, after the sweep.
- **Damage order:** every action resolves immediately; the log line is the
  only presentation in Phase 2 (unchanged).

#### 4.11.5 Damage numbers (pin)

- **Cannon (broadside stack, §4.4):**
  `damage = floor((side_cannons × 2 × range_factor + bonus) × weather ×
  shot × rake)` — the multipliers (storm ×0.75 / strong ×0.9, the §4.4b
  shot multiplier, rake ×1.25) multiply the whole product and exactly
  **one** floor lands at the end, after the weather term.
  **`bonus` (Phase 8, 2026-11-02):** `floor(effective_gunnery / 25)` for
  the player flagship (the §4.4 gunnery term) and `floor(combat_rating /
  10)` for every captain-card ship (AI ships and appointed player
  escorts). `combat_rating` is computed **once at fleet composition**
  from the ship captain's card (`data/captains.json`): **duel rating** =
  `captain swordplay + floor(captain courage / 20)`; **cannon rating** =
  the duel rating `+ floor(captain gunnery / 25)`. A captain-less player
  escort's cannon rating stays 0. (This replaces the Phase-2 reading —
  the player's effective `combat` stat, `0` for escorts, `5 + fleet
  tier` for AI ships.)
- **Crew casualties (Phase 9, per volley, clamped at 0 — correction 7):**
  standard volley `crew −= floor(damage / 20)`; rake volley
  `crew −= floor(damage / 10)`; a grape volley's casualty is its dedicated
  §4.4b crew kill, `floor(same-range round × 0.5)` (it is the volley's
  term, not an addition to the `/20` divisor); boarding winner
  `crew −= floor(crew × 0.2)` (§4.6a/§4.11.6). The losses feed the
  §4.11.6 duel crew term `min(floor(crew / 5), 20)`.
- **Ram (§4.5, Phase 9):**
  `mult = (1 + 0.25 × (floor(‖attacker vel‖) − 1)) × (bow/stern approach
  ×1.15 else ×1.0)`; `target = floor(att_max_dur × 0.25 × mult)` — an
  `oar`/`hybrid` attacker's ×1.25 folds into the same single floor —
  `attacker = floor(att_max_dur × 0.10 × mult)`.
  `attacker_max_durability` is the **effective** max from §4.11.12.
- **Sinking:** `durability ≤ 0` → the ship is removed immediately and its
  cargo is lost (no salvage while the battle runs). A ram that sinks both
  ships resolves the attacker last (§6).

#### 4.11.6 Duel resolution (pin)

- Both sides roll `base + rng.randi_range(0, 20)` each round.
  Player `base` = `swordplay + floor(courage / 20)` + the sum of `combat`
  modifiers on worn weapon/armor equipment (§4.11.12) — the Phase-2
  effective-`combat` term is retired (Phase 8, 2026-11-02).
  Captain-card ships (every AI ship; a player escort with an appointed
  captain) `base` = `min(floor(crew / 5), 20)` + the **duel rating**
  (captain `swordplay + floor(captain courage / 20)`), computed once at
  fleet composition (§4.11.5) and stored on the ship — the `5 + fleet
  tier` stand-in is retired.
- **Defender bonus (Phase 8):** whichever side defends adds
  `+ floor(charisma / 20)` — the player's own charisma when the player
  defends, the captain card's charisma otherwise.
- Higher roll wins the round; equal rolls score for neither side.
- First side to **3** round wins takes the duel.
- **Undecided after 5 rounds** (only possible with ties): more round wins
  takes it; equal counts → the defender holds, i.e. the boarding attempt
  fails and the attack is spent.

#### 4.11.7 Capture, loss and surrender (pin)

- **Player wins (§4.6):** the enemy ship joins the fleet when
  `fleet.size < FLEET_MAX` **and ≥ 1 idle officer** is available (the
  Phase-8 capture gate, §4.11.15), at `max(1, floor(current durability ×
  0.25))`, `crew = 0`, **cargo intact**, cannons and equipment intact. If
  the hold is then over capacity, `Fleet.normalize_all()` truncates it
  and the after-action dialog reports the overflow (§6). With a full
  fleet **or no idle officer** the ship is looted (its cargo moved to
  fleet capacity flagship-first, the rest reported lost) and scuttled —
  the loot-convert fallback; the dialog names which gate failed.
- **Player loses (§4.6):** the ship the player boarded *from* is taken — hull,
  hold, cannons and equipment all leave with it (a capture is not a sinking:
  nothing relocates). If it was the flagship, the next ship becomes flagship
  (`fleet[0]`, order preserved). No ships left → `gameover.captured`.
- **AI surrender (§4.7):** resolved exactly as a duel win (capture/loot —
  the Phase-8 capture gate applies, §4.11.15), with no duel and no XP for
  the duel rounds; the surrender itself is the §4.7 courage-flavored
  roll.
- **Player offers surrender:** immediate battle end.
  *Pirates:* the flagship's whole hold (goods + provisions + water) is taken;
  every ship is retained.
  *Navy with bounty:* the flagship hull itself is taken (same removal rule as
  a lost duel). If that empties the fleet → `gameover.captured`; otherwise the
  bounty is cleared per `70-*` §4.5 (rep resets to −10).
  *`enemy_kind == "tournament"`:* the battle simply ends, the player keeps
  every ship and the round is a loss for the bracket (`70-*` §4.9.7); no
  reputation changes.

#### 4.11.7.1 Tournament battles (Phase 3 seam)

`BattleSim` already accepts any `enemy_kind` string. Phase-3 tournaments pass
`"tournament"`, which:

- contributes no reputation delta of any kind (`rep_deltas = {}`, no
  battle-start `−20`, `70-*` §4.9.7);
- adds one entry to the §4.11.6 `FLEET_TIER` table —
  `"tournament": 2` (same captain rating as a navy) — the only code change
  the seam requires;
- treats **any** non-`victory` result as a bracket loss for the caller — the
  bracket (`scripts/quests/tournament.gd`) decides prizes, not the battle.

Hull composition per round is pinned in `70-*` §4.9.7 (one hull each:
brigantine, carrack, galleon), crew `crew_min`, durability max, cannons
`armament_slots`; the player's fleet durability carries between rounds
because the bracket never repairs between battles.

#### 4.11.8 AI decision pins (Phase 9 — T2 tie-breaks)

1. **Enumeration is the tie-break.** Every velocity choice enumerates
   `legal_velocities(unit)` in its (y, x) lexicographic order (§4.3a) and
   takes the **FIRST** candidate achieving the best objective; ties never
   reorder. Every §4.9a distance judgment — close, flee, kite, open distance
   — is evaluated on the **§4.3a sweep's landing cell** (W3 gate amendment,
   2026-11-03): a pick the sweep stops short (out-of-grid or occupied cell)
   does not close, flee, kite, or open any distance — judging on
   `pos + vel` lets a cornered ship sail through the map edge every round
   and freeze the battle into a §4.11.9 stall.
2. **Fire:** a rake-position volley beats a non-rake on the same side
   availability; then the profile `focus` picks the target — `weakest` =
   lowest current durability (ties → lower fleet index), `nearest` =
   minimum Chebyshev (ties → lower fleet index), `flagship` = player index
   0 (falls back to `weakest` while the flagship is sunk). Side choice:
   prefer the loaded side with more cannons, tie → port. The shot type is
   the §4.4b rule's output (never an enumerated dimension).
3. **Kite:** the first velocity whose resulting Chebyshev distance to the
   relevant target equals `preferred_range`; if none achieves it exactly,
   the first minimizing `|distance − preferred_range|`.
4. **Board** when hook-legal (§4.6a) **and** (own crew + duel rating > the
   target's **or** target durability ≤ 25% max). **Ram** when
   `floor(‖vel‖) ≥ 2` **and** own cannons + duel rating > the target's.
5. **Flee** (profile `flee_below_hp_pct` exceeded, or aggression < 25, or
   side morale ≤ 20 pre-fleet-layer): the first velocity strictly
   increasing Chebyshev to the nearest player ship; if none, hold.
6. **Surrender roll first:** the §4.7 roll resolves at the unit's turn
   start, before any other rule (§4.7 numbers).

#### 4.11.9 Battle end conditions (pin)

| Outcome | Trigger |
|---|---|
| `victory` | every enemy ship is sunk, captured, surrendered or retreated |
| `defeat_sunk` | the player's last ship sinks → `gameover.sunk` |
| `defeat_captured` | the player's last ship is captured (duel loss or navy surrender) → `gameover.captured` |
| `retreat` | `battle.retreat` chosen |
| `surrender` | player surrender chosen (§4.11.7) |
| `stall` | the stall counter reaches 8 (§4.11.10 aftermath) |

**Stall detection (Phase 9, decision 12):** 8 consecutive rounds with zero
damage **and** zero boarding **and** a net player↔enemy Chebyshev change
≤ 2 ⇒ outcome `stall`; any damage or boarding resets the counter.

#### 4.11.10 Rewards & aftermath (pin)

- **Salvage gold:** `Σ floor(ShipType.base_price × 0.05)` over ships **sunk**
  by the player during this battle. Captured/surrendered ships pay no
  salvage. **Phase 8:** the credited gold gains the haul-valuation
  multiplier (below).
- **Battle XP** (awarded to `player.xp` via `Character.award_xp`):
  `+10` per enemy ship neutralised (sunk/captured/surrendered) and `+5` per
  round the battle lasted. **Phase 8:** the total is ×(1 + level / 20),
  floored once — integer XP. The per-survived-round term is unchanged in
  Phase 9 and simply bounded by the round cap **40** (was 30; the
  §4.12.1 API default re-pins with it, correction 12).
- **`stall` aftermath (Phase 9, correction 4).** Outcome `stall`
  (§4.11.9) is a **mutual disengage**: the fleet returns to the contact
  tile with **no retreat back-step** (differs from §4.10), the enemy fleet
  is **not removed** and gets **+1 day pursuit cooldown** (the §4.10
  mirror), and the awards above still apply for what happened before the
  stall — loot/XP/rep earned so far are kept, nothing further. Tournaments
  treat a `stall` as a bracket loss like any non-victory (§4.11.7.1).
- **Reputation:**
  - Pirates defeated (any outcome except retreat) → `+2` with each of the
    **two nearest ports' nations** measured by Chebyshev distance from the
    contact tile (wrap-aware on x over the 4320×2160 world grid). The **two
    ports** are selected first (ties broken by port id
    ascending) and **then** their nations are deduplicated, so if both nearest
    ports belong to one nation that nation is credited once and no third port
    is considered (the dedupe clause is only observable under that reading).
  - **Navy: exactly one `−20` per navy battle**, charged to that navy's nation
    at **battle start** (`70-*` §4.5: attacking a national fleet is piracy,
    `60-*` §4.11.11.2), or on contact with a hunter. It is **not** charged
    per ship and it is never
    repeated at battle end, so:
    - `BattleRewards` and the battle-start piracy funnel
      (`Bounty.apply_piracy`, §4.11.11.2) apply it on initiation only;
    - the outcome block's `rep_deltas` carries only the pirate `+2` entries,
      and applying it twice is impossible by construction.
    Charged even if the player retreats afterwards (§4.10).
  - **Piracy rival bonus (Phase 3, `70-*` §4.9.5).** The same battle-start
    funnel also applies `+2` to each of the victim nation's two
    `data/nations.json#rivals`, from the data table — never computed from
    port distances. Pirates have no nation and gain no rivals.
  - **Piracy fame extension (Phase 8, 2026-11-02; `70-*` §4.5).** Attacking
    a **non-hostile** fleet keeps its reputation deltas (−20 with the
    owner, +2 its rivals — unchanged) and additionally costs **−20
    fame**, charged once at battle start by the same single funnel as the
    −20 (never at battle end, never per ship). Coasters are unreachable
    through battle: the picker offers no attack verb for them
    (intimidate-only, §4.11.15).
  - **Haul-valuation multiplier (Phase 8).** Every battle-haul gold
    valuation — the salvage gold above, the §4.11.11.2 loot-gold lines and
    the treasure-fleet loot gold — is credited
    ×(1 + (appraisal + negotiation) / 400), clamped to [×1.0, ×1.5] on the
    player's two skills. Captured cargo still moves into the hold as
    goods (§4.11.7); the multiplier prices gold, it never re-weights
    goods.
  - **Tournaments (Phase 3).** `enemy_kind = "tournament"` is not a nation
    and contributes **no** reputation delta of any kind (no −20, no +2, no
    bounty).
- **Rare drops (Phase 7):** a named pirate's captain sunk **or captured**
  credits that captain's `data/named_pirates.json` `drop` item —
  captain-id keyed, granted through the §4.11.13 flow — on top of the
  salvage gold above.
- **Return:** the fleet is placed on the contact tile, the hostile fleet is
  removed (`NpcFleets.remove`), and — Phase 2 — a spawn immunity of **3
  days** was recorded for that marker kind (§4.8; **retired in Phase 5**,
  §4.11.11.1). A `retreat` keeps the fleet instead (§4.10 pursuit cooldown,
  §4.12.4 step 4).

#### 4.11.11 `npc_fleets` save block & the fleet ecology (pairs with `90-*` §8.1) — Phase 5 rewrite

The Phase-2 `hostile_fleets` block is renamed `npc_fleets` and the 3-marker
spawn/pursuit model of the previous revision of this subsection is retired
(its historical record stays in the Phase-2/3 docs). Fleets are persistent
ecology members with a role, a nation, a lane route and a captain:

```json
[
  {
    "id": "nf_7_003_trader",
    "role": "trader",
    "nation_id": "portugal",
    "cell": {"x": 30, "y": 40},
    "route": {"lanes": ["carreira_da_india"], "leg": 0, "tile_index": 112},
    "cargo": {"wine": 30},
    "captain": {"id": "cap_portugal_0003"},
    "specialty": "wine",
    "cooldown_until_day": 0
  }
]
```

- `role` ∈ `trader` \| `coaster` \| `patrol` \| `courier` \| `privateer` \|
  `pirate` \| `hunter` \| `treasure` (§4.1.1); `nation_id` is the fleet's
  nation (empty for a pirate; a `hunter` is its nation's bounty navy).
- `route` persists `{lanes: [ids], leg, tile_index}` — the lane id list and
  the position on the current leg's rasterized tile path, smaller than
  storing the path itself (§4.11.11.1).
- `captain` is `{id}` — the captain's canon id into `data/captains.json`
  (§4.11.11.4; Phase 8, 2026-11-02 retires the `{pool_id, name_index}`
  pool indirection together with `npc_captains.json`; the id scheme is
  `10-*`'s); `specialty` is the trader's persisted specialty good
  (`30-*` §4.4); `cooldown_until_day` is the pursuit cooldown with the
  inclusive reading carried over from the Phase-2 marker rules
  (§4.11.11.1).
- **Wrecks are not fleets:** lootable wreckage lives in `GameState.wrecks`
  and is never counted against the cap (§4.11.11.2):

  ```json
  {
    "id": "wk_12_030_040",
    "cell": {"x": 30, "y": 40},
    "nation_id": "spain",
    "cargo": {"timber": 14},
    "hull_ids": [],
    "despawn_day": 17
  }
  ```

  A trader wreck carries its actual `cargo`; a warship wreck carries
  `hull_ids` and pays `BattleRewards.salvage_for(hull_ids)` on collect —
  the single salvage implementation (§4.11.10). `despawn_day` is always
  the loss day + 5.

#### 4.11.11.1 Lanes, movement & contact (pin for `npc_fleets.gd`)

- **Lane routing (locked).** Runtime: Dijkstra over the junction graph (edge
  weight = tile length, tie-break lane id then (y, x)); a fleet persists
  `route: {lanes: [ids], leg, tile_index}` — smaller than a tile path.
  Lane-locked: `trader`, `coaster`, `courier`, `treasure`. `patrol` cycles
  its nation's lanes. `pirate`/`privateer` anchor within Chebyshev 6 of
  chokepoint tiles and leave only for prey within Chebyshev 10, returning
  when prey is beyond 16 or lost (**10/16 hysteresis**). `hunter` stays
  lane-locked too — it sails the junction graph to its intel target (the
  hunter-intel rule below). Fallback on an impossible route (the validator
  makes this unreachable): one direct A* leg + logged warning.
- **Hunter intel (locked).** Hunters never free-roam: they navigate the
  lane network like every other role, guided by two persisted intel fields
  in the `world` save block (`90-*` §5.4):

  | Rule | Pin |
  |---|---|
  | Intel object | `world.last_departed_port` — the port id recorded at every Set Sail; readable by hunting nations (rep ≤ −50) |
  | Travel | the hunter sails the lane network to that port (junction-graph Dijkstra + tile path — **zero A\***) |
  | Loiter | camps the port's approaches (the chokepoint-camping pattern) for **10 days**, then routes home via its sponsor's lanes (and despawns if its bounty no longer stands) |
  | Chase trigger | the player's fleet within **Chebyshev 30** (wrap-aware) ⇒ direct pursuit — in **any** hunter state: en route, loitering, or homing |
  | Pursuit | short-range A\* only inside that radius, still under the ≤ 250 ms/day budget (unchanged **as the budget** — task H re-measures it at the quadrupled chase area and windows the region only on measured failure, correction 13); losing the player beyond **Chebyshev 40** ends the chase — the hunter returns to the lane network / the intel port (**30/40 hysteresis**) |
  | At-sea intel | contact with any fleet of a hunting nation updates `world.hunter_intel_cell` to the contact cell (one assignment on contact) |

  `world.last_departed_port` (port id string) and `world.hunter_intel_cell`
  (tile position) persist in the v5 `world` block, so hunter placement is
  exactly reproducible after a reload. A new Set Sail re-targets under-way
  hunters at their next day tick (deterministic).
- **Stepping.** Fleets advance along their lane's rasterized tile path at a
  base of **2 tiles/day** (Phase-6 lane-stepping base, before the parity
  factors of the amendment block below — **both superseded by the
  unified-movement amendment further below**; Phase 5 stepped 1 tile/day on the
  10 nm grid) inside the §4.1.2 flow, skipping occupied tiles (that rule
  itself **superseded by the co-location pin below** — fleets share tiles
  under the unified-movement amendment) and never
  entering `#` land, `^` reef or `I` ice; port-bound roles dwell **2 days**
  in port (the §4.1.1 trader row pins the trader dwell). Chokepoint
  anchoring keeps a `pirate`/`privateer` within Chebyshev 6 of its
  chokepoint tiles except during a chase (the 10/16 hysteresis above).
- **Pursuit is the only runtime A\* (locked).** The time-budgeted A*
  (≤ 250 ms/day, §4.1.2 `path_budget_ms_per_day`) survives only for the
  hunter's short-radius chase (the 30/40 hunter-intel hysteresis above); a
  budget overflow **loses the chase that day**. The budget itself is
  unchanged by the Phase-6 rescale; task H re-measures it at the quadrupled
  chase area and introduces windowing only on measured failure
  (correction 13). Lane traffic — now
  including hunter travel — never pathfinds (the §4.11.11.5 zero-A* gate).
- **Contact.** Measured after the fleet step, at Chebyshev distance 1,
  wrap-aware on x — the §4.11.11.2 table's row is the whole rule: only
  `pirate` / `privateer` / `hunter`-with-bounty open battle; every other
  role sails past.
- **Berth truth for dwell holds (amended 2026-11-01).** A legs-empty
  fleet holding its dwell is `docked` **only while standing on a port's
  berth tile** (`_port_at_cell` resolves it from the tile itself);
  holding in open water is `stranded` — the false-mooring case the hover
  reported as `@ <destination port>`. The heal fires **on dwell expiry,
  not mid-hold**: while the hold runs the fleet is genuinely idle (a
  camp's bait, or a just-dropped journey about to re-depart) and moving
  it mid-hold would teleport prey out from under an engagement. On
  expiry the tick snaps it to the nearest resolvable berth (its recorded
  destination's, else its own nation's nearest port) **before** the
  departure, so the depart's origin is always a port it actually stands
  on and a dropped journey can never leave a fleet idling at sea.
- **Spawn dwell holds (amended 2026-11-02).** A freshly spawned
  lane-role fleet (trader / coaster / courier) idles on its **origin
  berth** for its spawn dwell (`dwell_until_day = spawn day + the role's
  dock days`, the §4.11.14 coaster lever) **with its journey already
  pre-planned** — legs non-empty is *not* "under way" while the dwell
  runs. Both movement gates read docked = legs empty **or** dwell not
  expired: the accrual's docked fast path (`_accrue_lane`) banks the
  hold as `skip=docked`, and the day tick's docked branch idles it. On
  expiry the hold releases and the fleet walks its **pre-planned
  journey** (the port call happens at the journey's first arrival);
  `stall_state` reports `docked`/`stranded` for a spawn hold by the
  same rule. Without this the spawned fleet sails out of its hold the
  moment any accrual pass runs at sea, yet sits frozen at `ti=0` on the
  berth in port (day-tick-only accrual) — the "两个舰队一直不动" report.
- **Seam junctions are boarding tiles (amended 2026-11-01).** A spoke's
  terminus is frequently the trunk's first tile (a junction, not a hop) —
  `legs[0]` ends **on** the tile where `legs[1]` starts. The leg-end
  heading must therefore resolve to the next leg's **first real step**
  (index 1), never `_heading_to(cell, cell)` → `""`: an empty heading
  read as a wedge, dropped a healthy journey, and stranded every coaster
  whose spoke fed a trunk at that tile (the user-reported "船在海上发呆",
  `ev=drop wedge:ceuta ti=2`). `_advance` hands the leg over *and* pays
  the next leg's first step in the same accrual, so a junction never
  swallows a day's budget. Header-tile equality is the test seam
  (`test_npc_fleets` "spoke/trunk seam tile").
- **Pursuit cooldown (carried over).** A fleet that lost a battle (player
  retreat) does not move for 1 day (`60-*` §4.10), tracked in
  `cooldown_until_day` with the Phase-2 **inclusive reading**: it is the
  *last idle day*, so a battle on day D stores `D + 1`, the fleet holds on
  D+1 and moves again on D+2; while on cooldown it raises **no contact**,
  which is what stops a retreat (fleet returned to the contact tile, right
  beside the fleet) from re-opening the same battle forever.
- **Spawn immunity retired.** The Phase-2 per-kind spawn immunity
  (`GameState.proximity_cooldowns`) served the retired daily spawn rolls;
  fleet counts are now governed solely by the §4.1.1 budgets and the
  §4.1.2 trickle (wrecks excluded — they live in `GameState.wrecks`). The
  save-key list is `90-*`'s (task A).

**Phase-6 parity & seasons (amendment).** Every rule above keeps its
shape; the Phase-6 sea adds four touches, all deterministic:

- **Physics parity.** Each fleet's daily tile budget multiplies by the
  same `direction_factor`/`current_factor` the player's pipeline applies
  (`20-*` §4.4), evaluated for the fleet's **current leg heading** — pure
  functions of day + position, no RNG, so replays stay exact. Hunters pay
  the factors on their lane travel **and per pursuit step**. Lane stepping
  runs at base **2 tiles/day** before the factors (the Stepping bullet
  above; **superseded by the unified-movement amendment below**).
- **Seasonal lane variants.** Lanes may carry
  `variants: [{id, months, waypoints}]` (`10-*`, amended Phase 6); runtime
  selects the **in-month variant from the built tile paths**
  (`trade_routes_built.json`). Deterministic per day. Resolution
  (amendment 2026-11-02, the arrival-jump fix): **every** lane leg anchors
  on endpoint identity — both walked end tiles must exist on the variant
  path, and the leg walks the variant between those indices; otherwise the
  leg keeps the base geometry and the §4.18 ice refusal governs.
  Proportional (fraction-of-path) mapping and the full-lane wholesale
  replacement are retired: a structurally different variant (the
  `hanseatic_north_winter` North Sea run vs the Baltic base run)
  proportionally mapped onto unrelated water and teleported every journey
  seam on the lane — arrivals snapped the Danzig berth from ~119 tiles
  out. Shared-endpoint legs (hamburg ↔ bergen through the German bight)
  still ride the variant exactly — the Bergenfahrer winter run.
- **Ice-aware stepping & pursuit.** In-month seasonal ice
  (`20-*` §4.18) refuses *entry* for player, NPC, A\* and lane stepping
  alike; a fleet standing on a tile that freezes is **never trapped** — it
  may still move out. Pursuit A\* uses the same in-month passability.
- **Radii sweep note.** The Phase-6 grid sweep (5 nm tiles) doubled the
  gameplay radii pinned above: patrol zone 15 → 30, chokepoint anchor
  3 → 6, pirate hysteresis 5/8 → 10/16, hunter hysteresis 15/20 → 30/40,
  escort radius 10 → 20, trader decision range 60 → 120 (the number
  itself is pinned in `30-*` §4.4), lane stepping base 1 → 2 tiles/day.
  Values not listed here (e.g. the pirate prey-preference radius, convoy
  grouping) are unchanged pins.

**Unified fleet movement (closing Phase-6 amendment; supersedes the
stepping base and the factor-only parity above).** Player and NPC fleets
share ONE movement model — the `20-*` §4.4 pipeline, evaluated per fleet
per day tick:

- **Base speed** is the **slowest `ShipType.speed` among the fleet's
  composed ships** (the §4.11.3 composition, stored on the fleet dict at
  spawn as `ships` — `10-*` §4.15; a fleet without the field composes it
  lazily from its persisted `seed`, bit-identical to the spawn draw). The
  composition's hull draws key off the fleet seed only — never the day —
  so a fleet's base speed is fixed for its life, and two fleets of the
  same role generally differ (pirate 1–3 hulls, navy-band roles 2–4,
  merchant roles 1–3, treasure 4–6, drawn from `latin` 16 / `sloop` 20 /
  `caravel` 20 / `brigantine` 24).
- **Pipeline.** `day allowance = base × wind_factor × direction_factor ×
  current_factor`, with `wind_factor` applied from the global day weather
  (`20-*` §4.7) at the **flagship's class** (the first composed ship);
  `direction_factor` keeps reading the region's **prevailing** wind token
  (the seeded daily jitter is a player-ledger roll, not re-rolled for
  NPCs); `current_factor` unchanged. The player-ledger terms are pinned
  neutral for NPCs: `crew_factor = 1.0`, seamanship bonus `0`, sail trim
  `normal` (1.0). Pure day + position + global-weather inputs — no RNG —
  so replays stay exact. The direction table's class column follows the
  flagship's class (the `sail` column remains the fallback for an unknown
  class).
- **Lane travel** banks `floor(allowance + carry)` tiles through the
  per-fleet fractional accumulator (a sub-tile day banks and holds — the
  task-H carry shape, unchanged). **Raider chase/return** pays one
  allowance per day tick for the bearing to its target and walks it
  greedily tile by tile (the engagement re-checked after every committed
  tile). **Hunter pursuit** pays the allowance **per pursuit step
  heading** — each A* step banks its own heading's allowance — so
  pursuit is speed-matched with the player under the unchanged 30/40
  hysteresis and the unchanged ≤ 250 ms/day budget.
- **Clock accrual (cadence amendment; supersedes the per-day-tick
  reading of the bullets above).** Movement is a pure function of
  elapsed world time: every fleet accrues
  `Δ × base × wind × direction × current` tiles per elapsed Δ
  (`Δ = day + clock_fraction − its own accrual mark`) and steps one tile
  per accrued tile, released in step with the player's own clock — a
  player helm move advances ≈ one tile on every fleet, so the sea never
  jumps at a day boundary and no remainder is ever flushed. Whole-day
  catch-up (port day-skips, headless drivers) walks exactly the daily
  budgets above; a fleet routed by a departure accrues the current
  day-remainder immediately and marks itself accrued-through-now (docked
  time never accrues; the per-fleet marks are runtime-only — a reloaded
  fleet resumes accrual from the load instant). **Clock-rewind rebase
  fleet resumes accrual from the load instant). **Clock-rewind rebase
  (dormant since 2026-11-02):** the world clock is continuous — set sail no
  longer resets `clock_fraction` (`20-*` §4.3 port-hours amendment) — so
  fleet Δ ≤ 0 no longer occurs in play; the rebase path (a pass whose fleet
  Δ ≤ 0 snaps the mark to the clock and grants nothing) is kept as a
  headless/test-seam safety net.
  not stepping: dwell, departures (with the eager route-progress sync),
  the raider/hunter state machines, spawns, wrecks. NPC-vs-NPC
  engagement fires from the accrual walk the moment a raider's committed
  tile lands within Chebyshev 1 of its prey; contact with the player is
  sampled per tile entered exactly as below. Whole-day catch-up evaluates
  the pipeline at the leg's current heading for the batch (the daily-budget
  shape); live fractional accrual pays each tile's own position/heading
  factors — the more faithful reading where a lane crosses wind or
  current regions.
- **Berth consistency (docking pin).** A docked fleet always stands on
  its port's **berth tile** (the water tile within 2 of the shore,
  `20-*` §6.1) — docking "somewhere at sea" is not allowed. The day tick
  self-heals a docked fleet found off its berth back onto the berth in
  the same tick; the diagnostics report `on_berth` (and the S3 badge
  flags `X` until healed, `80-*` §4.5.2). **Patrols anchor to their home
  port:** `_depart_patrol` sets `dest_port_id` = `_patrol_home_port`,
  so a patrol walking its lane span arrives at the span end into the
  home-port berth (the §4.1.1 dock-2-days cycle) and `_lane_step_heading`'s
  berth fallback always resolves — a span-end 0-budget wedge cannot recur
  for patrols.
- **Co-location (fleet-sharing pin, supersedes the occupancy rule).**
  Fleets MAY share tiles: movement entry is gated by **passability only**
  (land / reef / in-month seasonal ice) — tile occupancy never blocks a
  step, and the task-K "skipping occupied tiles" hop rule is retired.
  Interactions are governed by the encounter/contact rules
  (§4.11.11.2 — the Chebyshev 1 encounter, the abstract NPC-vs-NPC
  auto-resolve) and the radius queries (escort, convoy, prey), never by
  tiles. Rationale: tile occupancy was the root of every lane jam (the
  boarding-slice queue and the head-of-queue deadlock — surfaced by the
  stall diagnostics as `blocked×N` holds); with co-location the entire
  jam class is structurally impossible. The `blocked` stall state now
  means passability holds only (in-month seasonal ice on a walked span).
  Docked fleets still share port berths (unchanged), and spawn/camp
  placement keeps its spread preference (aesthetics only).
- **Contact is sampled per tile entered**, not only after the day step:
  any fleet stepping within Chebyshev 1 of the player's tile mid-step
  engages under the §4.11.11.2 row exactly as an end-of-step proximity
  would (hostile roles only, cooldown excepted), and a hunting-nation
  pass-through records the at-sea intel cell on the passed tile.
- **Balance note (recorded, not tuned here):** lane ecology timing
  contracts accordingly — a long lane crossing now takes days-to-weeks
  instead of a season — raising encounter turnover at unchanged §4.1.1
  fleet budgets and unchanged port dwell (2 days).

#### 4.11.11.2 Auto-resolve, wreckage & player combat (locked)

NPC-vs-NPC combat is **abstract** — auto-resolve plus lootable wreckage at
the site; no battle screen. Salvage reuses the existing
`BattleRewards.salvage_for` implementation (single implementation).

| Rule | Pin |
|---|---|
| Raider vs unescorted trader | raider wins 60% (seeded) |
| Raider vs patrol / escorted trader / convoy | raider loses |
| Loser | despawns, leaves a `wreck` at the site; despawn after **5 days** |
| Trader wreck | its actual cargo (collect up to free capacity) |
| Warship wreck | `BattleRewards.salvage_for(hull ids)` gold (single implementation) |
| Player collect | entering the wreck tile collects (no battle) |
| Player contact (Chebyshev 1, wrap-aware) | opens battle only for `pirate` / `privateer` / `hunter`-with-bounty — exactly as today; **Phase 8:** the contact auto-cancels an appointed voyage with a notice first (`60-*` §4.11.15; HUD notice per `80-*` §4.10) |
| Player attacks a fleet (the picker's attack verb, `80-*` §4.10) | non-pirate owner pays `Bounty.apply_piracy` (−20 owner, +2 its rivals) **and −20 fame** (Phase 8 piracy-fame extension, §4.11.10) **once per battle at start** (existing single funnel); loot = actual cargo + `min(1000, 100 + 10 × day)`g, credited through the §4.11.10 haul-valuation multiplier. **No attack verb exists for a coaster** — the §4.1.1 coaster row is the more specific pin: intimidate-only (§4.11.15) |
| Coaster (right-click) | no attack verb; the hail's intimidate is the only way to take from one — success takes half its cargo (floor per good) + pirate fame +5, failure turns it hostile and opens this battle (§4.11.15) |
| Composition | `AiFleet.compose_enemy` unchanged; per-fleet seeded stream; kind→budget map `{"trader": 6, "coaster": 2, "courier": 0, "patrol": 30, "privateer": 20, "pirate": 20}` + `floor(day/30)` |
| Chained battles | existing §4.11.11.3 pattern preserved for hostile contacts; S10 descriptor shape unchanged |

- **Composition detail.** `AiFleet.compose_enemy` is unchanged; each battle
  draws from the **fleet's own seeded stream** (persisted at spawn), so
  save/load reproduces compositions. The kind→budget map above replaces
  §4.11.3 step 3's value for its kinds; ship count uses the §4.11.3 bands —
  `trader`/`coaster`/`courier` roll `1 + rng.randi_range(0, 2)` (1–3),
  `patrol`/`privateer` roll `2 + rng.randi_range(0, 2)` (2–4); hulls, crew
  and durability stay §4.11.3 steps 2/4. The fleet's own `cargo` dict is the
  enemy cargo for the loot rules above (distributed flagship-first);
  §4.11.3 step 5's uniform draw applies only to a fleet with an empty
  `cargo` (fresh raider spawns). The navy-family roles keep the navy path:
  a `hunter` composes exactly as the §4.11.3 `navy` (S10 `kind` stays
  `"navy"`, §4.11.11.3); a `treasure` fleet rolls `3 + rng.randi_range(0, 2)`
  merchant hulls (the 3–5 pin, §4.11.11.4) plus one patrol-escort hull,
  whole-fleet cannon budget `30 + floor(day/30)`. **Phase 8:** the
  composition also prices each ship's captain-card ratings (duel rating /
  cannon rating, §4.11.5) once — stored on the ship, never re-rolled
  mid-battle.
- **Wreck lifecycle.** The loser despawns into a `wreck` at its cell (shape
  in §4.11.11); it despawns after **5 days**; contents per the table —
  trader = actual cargo (collected up to free capacity), warship = hull ids
  → `BattleRewards.salvage_for` gold at collect. Player collect = entering
  the wreck tile (no battle). Wrecks live in `GameState.wrecks`, never
  counted against the §4.1.1 cap.
- **Player-resolved battles** (contact or right-click) keep the §4.11.10
  aftermath exactly (salvage, XP, rep) — wrecks are only ever created by
  NPC-vs-NPC auto-resolve.

#### 4.11.11.3 Contact → battle handoff (pin for S10/S3 — pattern preserved)

`world_map.gd` reacts to `battle_started(encounter)` by routing to
`battle_screen.tscn` with the encounter queued on
`GameState.pending_encounter` (cleared on battle start, so a re-entrant
contact cannot open two battles). `battle_screen.gd` exposes:

```
open_battle(encounter: Dictionary) -> void     # sets up, does not run
run_to_completion(max_rounds: int = 30) -> Dictionary   # headless/test use
last_outcome: Dictionary                        # §4.11.9 outcome block
```

The battle emits `battle_finished(outcome)` exactly once, then (non-headless)
shows the after-action dialog and routes back to S3. Contact with two hostile
fleets in the same tick chains: the second opens after the first finishes
(§6). The **S10 descriptor shape is unchanged** — same field set as Phase 2;
`kind` now also carries a fleet role id for right-click attacks on national
fleets (the §4.11.11.2 map keys), while `hunter` battles keep
`kind = "navy"`; `encounter_id` is the fleet id.

#### 4.11.11.4 Aliveness: convoys, named pirates, treasure fleets, captains (locked)

- **Convoys (locked):** same-lane traders within Chebyshev 3 render as one
  group with a shared escort square; auto-resolve treats a convoy as
  escorted (the §4.11.11.2 table).
- **Named pirates (locked; Phase-8 amended 2026-11-02):** `data/named_pirates.json`:
  4 captains, zh/en, tiers 1–3 (`70-*` §4.5); Phase 8 upgrades each entry to a
  **full canon captain card** with its `drop` preserved (§4.11.13); defeated →
  the **return queue** like every captain (§4.11.15: `return_day = day + 60`,
  same name — names are never reused); `quest_gen` bounty targets prefer named
  captains. (The Phase-5 "respawn as a new name +30 days" rule is retired.)
- **Treasure fleets (locked):** 1/nation/season on day `45 + 15 ×
  nation_index` (mod 90 — under the Phase-6 360-day calendar these mod-90
  "seasons" are 90-day quarters anchored at Month 1 (`20-*` §4.15);
  behavior unchanged), `nation_index` = `nations.json` file order
  (portugal 0 … italy 5) ⇒ days 45/60/75/90/105/120; 3–5 ships + patrol
  escort on the nation's historical lane; loot = cargo (×3 normal volume) +
  `min(3000, 500 + 25 × day)`g.
- **Captain identity (locked; Phase-8 amended 2026-11-02):** every fleet
  draws its captain from the closed canon `data/captains.json` at spawn
  via its seeded stream and persists the captain's canon id (`{id}`,
  §4.11.11) — the `npc_captains.json` name pools are retired; names never
  flicker on reload; famous pirates are canon cards with their `drop`
  preserved (§4.11.13); **captains never die with their fleet** — a
  defeated captain enters the return queue (§4.11.15), which supersedes
  the Phase-5 "a captain dies with its fleet" reading.
- **Sighting surfaces** (market/tavern/inn/palace rows, wanted posters, the
  20g reveal) and the seeded facility/presence rolls are pinned in `80-*`
  §4.7.8; the pure query module `scripts/world/npc_intel.gd` (task L)
  implements them — sightings by port/facility (60/40 + 75% rolls), wanted
  posters within Chebyshev 40, exact-position lookup for the paid reveal,
  rumor row sources. Tavern rumors source from live fleets within Chebyshev
  40, departures/arrivals at the port within 3 days, and demand-event
  telegraphs.
- **Task-L implementation pins (details the tables above left open):**
  - *Captains — the return queue (Phase 8, 2026-11-02; supersedes the
    named-pirate respawn/successor machinery).* A defeat at the single
    removal funnel (`remove()`) books the captain into `captain_states`:
    `status = "returning"`, `return_day = day + 60` (saved, `90-*` §8);
    at `return_day` the captain returns **under its own name** (the canon
    roster is closed — **names are never reused**, regression-pinned) with
    its **tier drift** applied: −1 on a crushing defeat, +1 on each
    victory against the player, clamp 1–3. A pirate/privateer with
    `stance ≤ −3` returns as a **nemesis hunter** (lightweight: it hunts
    the player under the §4.11.11.1 hunter-intel rules). The Phase-5
    machinery — `GameState.named_pirate_respawns`, the `successor_<tier>`
    alias slots and the nationless-pool name rotation — is **retired**
    (the validator asserts `npc_captains.json`'s absence, `10-*` §8). A
    famous pirate mid-queue simply returns on its `return_day` under its
    own card; its `drop` stands again.
  - *Poster eligibility.* Posters are for **bountied** captains (a bounty
    standing per `70-*` §4.5/§4.9.3) — with the Phase-8 canon every
    captain carries a full named card, so the Phase-5 famous-or-successor
    eligibility test is retired. The reward hint uses the `70-*` §4.9.3
    bands `{1: 5000, 2: 10000, 3: 20000}`.
  - *Treasure fleets.* `_schedule_treasure` runs inside the daily tick:
    on `day − (45 + 15 × nation_index) ≥ 0 ∧ ≡ 0 (mod 90)` while the
    nation has no live treasure fleet. The fleet boards the lane the
    **capital's built spoke** attaches to (the historical lane), at the
    tile nearest the capital (the §4.1.1 patrol boarding rule), walks it
    end to end at the unified §4.4 budget (Phase-6 lane-stepping base
    superseded — see the unified-movement amendment above), dwells 2
    days at the far end, then
    despawns — never a port call. Cargo at spawn: **3 ×** the normal
    30-unit call cap of one seeded produced good. Composition per
    §4.11.11.2: `3 + rng(0..2)` merchant hulls + one patrol-escort hull
    at the patrol cannon budget (`ai_fleet.gd` also carries the
    `treasure` kind so any recompose path prices it identically).
    Player-victory loot: carried cargo +
    `min(3000, 500 + 25 × day)`g at the `world_map` loot seam.
  - *Convoys (render).* A grouped trader's render leader is the
    **smallest fleet id** among its `convoy_members`; `markers()` carries
    `convoy_count` (leaders only, ≥ 2) and `convoy_leader` (members name
    their leader) — one entry per fleet, the render layer hides members
    behind the leader's shared square.
  - *Wakes.* Each fleet's last ≤ 5 cells **left behind** (most recent
    first) live in the transient `NpcFleets._wake_trails`
    (`fleet_id → [Vector2i]`), recorded at the movement commit and at
    spawn; `markers()` exposes the trail only for sailing fleets. Never
    saved — a reloaded fleet has no trail until it moves.
  - *Port log.* Arrivals/departures are appended
    (`{port_id, kind, role, nation_id, fleet_id, day}`, newest last,
    capped 128) into the transient `GameState.npc_port_log` at the
    `_arrive` / `_set_route_to` seams — the rumor source
    "departures/arrivals within 3 days" reads it; a fresh run and every
    load start with an empty log.

#### 4.11.11.5 Spatial index & performance gates (locked)

- **Spatial index (locked):** one wrap-aware **cell-bucket hash**
  (cell → fleet) serving occupancy, contact, and neighborhood queries
  (prey-10, escort-20, patrol-30 zones) — every per-day check linear in fleet
  count. **Every "within N tiles" check goes through the bucket index**
  (review gate, tasks J/K).
- **Phase-6 width-derived keys (correction 6).** The cell-key packing
  (`cell.y * 4096 + posmod(cell.x, 4096)`) and the bucket strides
  (`_bucket_index` stride 4096, `buckets_x := 2160 / BUCKET_SIZE`) are
  hardcoded at the old 2160-tile width and **must become width-derived**
  at 4320×2160 — the packing breaks outright at `x > 4095`. Task R
  implements the sweep; task H verifies the semantics against this
  section.

Perf gates (measured in tools suites — tasks J/M):

| Gate | Pin |
|---|---|
| Day tick @ normal (cap 288) | ≤ 75 ms headless, zero runtime pathfinding for lane traffic — re-proven at the Phase-6 scale by task H; **re-pinned 50 → 75 by the unified-movement amendment** (measured ≈ 53) |
| Day tick @ extreme (≈ 1 100 fleets) | **re-pinned ≤ 350 ms by the unified-movement amendment** (was ≤ 150; 2026-11-01: every fleet now steps its §4.4 hull-scale budget per day and departed fleets walk their new route in the same pass, ~10× the retired 2-tile base per tick; measured ≈ 276) |
| Marginal cost | demonstrably linear (extreme ≈ 4× normal, not 16×) |
| Pursuit A* | ≤ 250 ms/day budget, overflow loses the chase — unchanged as the budget; H re-measures at the quadrupled chase area and windows the region only on measured failure (correction 13) |
| Save payload @ extreme | ≤ 2.25 MB (2 MiB through Phase 7; the Phase-8 `captain_states` block adds one §4.15 row per fleet — measured 2,111,818 B at the settled extreme, 2026-11-03) |
| world_e2e wall budget | **runner kill timer 300 s for this suite only** (amended 2026-11-01; re-pinned 540 → 300 by the 2026-11-02 overkill-sweep removal — leg 4 ends at Cape Town instead of re-sailing leg 3's corridor in reverse, and the storm-gate Monte Carlo was retired for the closed form): the unified-movement amendment accrues every fleet on every player move, so the movement proof pays the designed per-move cost × thousands of steps; its fixture scales the ecology budgets ×0.1 process-locally (`test_world_e2e.gd`) and suppresses raiders within Chebyshev 60 of the route — the proof's contract is movement, not population or combat (those stay with test_density / test_npc_fleets / the battle suites) |

#### 4.11.12 Equipment wiring (pairs with `10-*` §4.6, `40-*` §4.1)

- **Ownership:** `weapon` and `armor` are the **player's** two slots, stored in
  `player.equipment = {"weapon": "", "armor": ""}` (equipment id or empty
  string). `figurehead` and `sail` are **per ship**, stored in
  `ship.equipment = {"figurehead": "", "sail": ""}`.
- **Duel:** the player's roll adds the sum of every `combat` modifier across
  the two worn player items.
- **Battle (Phase 9, correction 2):** `sail` adds its `speed` modifier to
  that ship's **`cap_eff`** — after the §4.3a clamp, and **not** clamped
  back into `[0, battle_max_speed]` — **and** to its initiative sort key
  (§4.11.4); the Phases-2–8 MP wording is retired with the MP model (§4.3
  historical note). `figurehead` adds its `durability` modifier to that ship's
  **effective max durability**, which is the base for ram damage (§4.11.5) and
  the cap for its current durability.
- **Purchase:** shipyard, §4.3 refit row plus an equipment list (§4.11.13).
  Buying into an occupied slot sells the old item back at
  `floor(price × 0.5)` in the same transaction.
- Missing `equipment` keys (old save, hand-edited file) read as empty slots —
  the accessors default, they never fail.

**Phase-7 modifier keys (extends the modifier schema; `10-*` §4.6).** Two
new optional keys join `combat`/`luck`/`durability`/`speed`:

- **`storm_damage_pct`** — integer percent (authored **negative** for
  mitigation). Ship-side: read from that ship's two slots (figurehead +
  sail, summed). The hull's storm damage (`SailingSimLib.storm_damage_for`,
  `20-*` §4.7) gains the extra multiplier
  `(100 + Σ storm_damage_pct) / 100` — the same seam the luck multiplier
  and the sail-trim multipliers already flow through, floored once with
  the rest of the product (a −25% sail on a hull taking 4 points takes
  `floor(4 × 0.75)` = 3).
- **`scurvy_delay_days`** — integer ≥ 0. Fleet-side (scurvy is one fleet
  counter, `20-*` §4.9): the water-shortfall counter fires
  `game_over("scurvy")` at `7 + Σ scurvy_delay_days` shortfall days, the
  sum over every equipped item aboard the fleet's ships. The
  per-shortfall-day crew loss (`max(1, floor(crew × 0.05))`) and the
  reset on a fully supplied day are unchanged — only the game-over
  threshold moves.

Any other modifier key is a validator error (`10-*` §8).

#### 4.11.13 Equipment content set (24 items, Phase 7)

Phase 7 replaces the Phase-2 8-item locked table with the **24-item
tiered set** (6 items per slot × the 4 slots). S authors the exact list
(exact-set lock, `10-*` §4.6); the Phase-2 eight — `eq_cutlass`,
`eq_rapier`, `eq_breastplate`, `eq_lucky_charm`, `eq_mermaid_figurehead`,
`eq_dragon_figurehead`, `eq_cotton_sails`, `eq_storm_sails` — stay in the
set, re-tiered, their Phase-2 prices and modifiers preserved (the
historical table lives in the Phase-2 docs). Rules pinned here:

- **Schema.** Every item keeps `id`, `name {zh,en}`, `slot`, `modifiers`,
  `price` (`10-*` §4.6) and gains **`tier: 1|2|3`** plus optional
  **`rare: true`** — exactly **2 tier-1 + 2 tier-2 + 2 tier-3 per slot**
  (2/2/2). Prices sit in the **300g–6,000g** band; guideline: tier 1 ≤
  1,500g, tier 2 ≤ 3,500g, tier 3 above (S finalizes, then locked). Buy
  price = `price`; sell-back = `floor(price × 0.5)` — unchanged.
- **Per-port stock.** `facilities.equipment_stock: [ids]` (**≥ 2** at
  every shipyard port), regional flavor as the ships (`40-*` §4.3.1); the
  universal tier filter applies —
  `purchasable = in_stock ∧ tier ≤ effective_dev(port)` (`30-*` §4.9) —
  with the same grayed rows as `40-*` §4.3.1, **including the neutral
  allegiance gate** (allegiance + dev ≥ 2). The Phase-2 "sold at every
  shipyard" rule is retired.
- **Rare drops (4 items; correction 10).** Exactly four items carry
  `rare: true`:
  - **never in any stock list** (validator-asserted) and **never
    tier-gated** — they are never purchasable at all, so no stock UI ever
    renders them (`80-*` §4.7.12);
  - `data/named_pirates.json` gains **`drop: <equipment_id>`** per entry,
    each referencing one `rare: true` item (validator cross-check);
    **Phase 8:** the four entries upgrade to full canon captain cards
    (`data/captains.json`) with `drop` carried through unchanged
    (validator group relocation, `10-*` §8).
  - **flow (keyed by the sunk/captured captain id):** when a battle ends
    with a named pirate's captain sunk or captured (§4.11.10), the
    aftermath matches the captain's **canon id** against the four famous
    pirate ids (`data/named_pirates.json`, preserved in
    `data/captains.json`) — a match credits that entry's `drop` item; a
    captain with no famous-id match drops nothing (the `drop` table stays
    exactly the four named pirates'; Phase 8, 2026-11-02 wording — the
    Phase-5 "successor captains" alias is retired with the respawn
    machinery, §4.11.11.4). The item equips through the standing replace
    rule (§4.11.12): `weapon`/`armor` fit the player's slots,
    `figurehead`/`sail` fit the **flagship**; an occupied slot sells the
    displaced item back at `floor(price × 0.5)` in the same grant, and
    the after-action dialog reports what was fitted and what sold back.

#### 4.11.14 NPC trade at ports (Phase-7 amendment — pairs with `30-*` §4.9/§4.10)

**Trader docking at aligned ports (decision 12, generalized by 25).**
Traders of nation N on any of the 21 lanes may dock at any port whose
**effective alignment == N** — protected own ports plus contestable ports
aligned to N (sovereign non-core and neutral alike). Standing port-call
rules are unchanged (≤ 30 units of one good per call, hold 40, 2-day
dwell, the `30-*` §4.4 sell rule at `factor > 1.0`). Rival-aligned or
unallied ports get no lane traders. This **amends the Phase-6
own-nation-only docking pin** (`npc_fleets.gd` L4679-4694; the `10-*`
§7.1 "no NPC fleet serves a neutral port" line and the matching `30-*`
wording are reworded by tasks A/B).

**Nationless coasters everywhere (decision 18; correction 15).** Every
neutral port — unallied included — receives ~1 nationless coaster
(中立灰 livery, the nationless-pool precedent) hopping to the **nearest
ports regardless of ownership** — border-crossing local trade. Standing
coaster pins are unchanged: ≤ 5 units traded per call, hold 10,
saturation `qty ≤ 100 − stock`, never sell into `factor ≤ 1.0`, never
triggers contact (§4.1.1; lootable coasters stay Phase-8).

- **Locality is the anti-imbalance guard:** nearest-port hops only, never
  lanes — long-distance specialty trade stays the player's domain.
- **Goods scope (decision 21):** coasters trade **staples ∪ middle only**
  — never luxury/specialty/exclusive; margin selection stays free within
  that set. Lane traders keep the standing exclusive rule (`30-*` §4.4).
- **Spawn budget:** new data line **`neutral_coasters_mult := 0.75`** in
  `data/npc_config.json` (correction 15; the nation-line
  `coasters_mult_per_port` keeps its meaning); task N re-derives the
  fleet-cap **288** arithmetic and re-proves **day tick ≤ 75 ms** and
  **pursuit A\* ≤ 250 ms** at the added spawn count (correction 2; the
  §4.11.11.5 gates are unchanged as budgets).

**NPC tax crediting (decisions 19/20).** Traders and sovereign coasters
pay the unified tariff into the host treasury on their port-call trades —
through `Allegiance.credit_tax` (the C contract, `80-*` §4.9) reusing the
walked totals already computed for the call; no profit-and-loss
accounting anywhere. Nationless coasters credit nothing (no host to pay).
NPC-sourced tax is capped **2,000g per nation per month** (treasuries,
`30-*` §4.9); rates are the unified tariff of `30-*` §4.10 (5% aligned /
20% foreign, permits applied). Flow-economy fit: coasters damp local
extremes, never erase them (the `IMPLEMENT-Phase7.md` §2.9 gate 6).

#### 4.11.15 Interactions, intercept & the captain lifecycle (Phase 8, 2026-11-02)

The right-click attack funnel widens into the interaction layer —
`scripts/world/interactions.gd` dispatches, `scripts/world/hail_options.gd`
builds talk options, `scenes/world/fleet_picker.tscn` /
`scenes/world/hail_modal.tscn` present them (`80-*` §4.10 owns every
screen pin; the combat-side rules live here):

- **Verb surfaces.** Right-click inside sighting radius on a fleet opens
  the `fleet_picker` (flag color / role icon / identified name / tier; a
  multi-fleet tile picks its target first) with the verbs inspect / talk /
  attack. Left-click sail-to is unchanged; right-click on empty water or
  land is a no-op. **A `coaster`-role fleet offers no attack verb**
  (intimidate-only — the §4.1.1 coaster row is the more specific pin).
  Right-click on a port harbor tile opens the port context (dock /
  委任航行 appoint voyage — `80-*` §4.10.3).
- **Hail (talk).** Chebyshev ≤ 2 opens the `hail_modal`; options are built
  from role × stance × skills:
  - *Ask rumours* — **stance ≥ +2** grants one free route/market intel on
    top of the rumour.
  - *Buy supplies* — `trader`/`coaster` captains only: port price ×1.5,
    ×1.25 at `stance ≥ +3`, minus `floor(negotiation / 10)`%.
  - *Intimidate* — `p = clamp(our_strength / total_strength +
    floor(courage / 200) − max(0, −stance) × 0.05, 0.05, 0.95)`;
    `strength` = Σ combat ratings (§4.11.5) of the respective side.
    Success: half the target's cargo is handed over (floor per good) +
    **pirate fame +5**. Failure: the target turns hostile and the
    §4.11.11.2 contact battle opens.
  - *Befriend* — `stance +1`, once per captain per day.
- **Intercept order (attack from range).** The attack verb on a fleet
  beyond contact range issues a click-to-sail movement order onto the
  target; the §4.11.11.2 contact pipeline opens the battle on arrival.
  The order **auto-cancels when the target leaves sighting radius**
  (`48 + floor(navigation / 12)`, `20-*`). An appointed voyage (same
  pipeline, port target) auto-cancels on hostile contact with a notice;
  storms do not cancel it (`80-*` §4.10.4).
- **Piracy.** Attacking a non-hostile fleet stays `70-*` §4.5 piracy —
  reputation −20 with the owner (+2 its rivals, unchanged) **plus −20
  fame** (§4.11.10).
- **Capture gate & loot-convert fallback.** Capturing a defeated ship
  (duel win or AI surrender) requires `fleet.size < FLEET_MAX` **and ≥ 1
  idle officer**; otherwise the prize converts to loot (the §4.11.7
  full-fleet resolution: cargo to fleet capacity, hull scuttled) and the
  after-action dialog names the gate that failed. **Phase 8 has no
  capture-of-NPC-captains**: only ships join the fleet — the gate is
  about ships, and NPC-captain recruitment stays the Phase-9 parking
  lot.
- **Captain lifecycle (return queue — supersedes the Phase-5 respawn
  machinery, §4.11.11.4).** Defeated NPC captains **never die**:
  `active → defeated → returning(return_day = day + 60) → active`
  (`scripts/world/captains.gd`). Tier drift: −1 on a crushing defeat, +1
  on each victory against the player, clamp 1–3. Names are never reused
  (closed canon). A pirate/privateer with `stance ≤ −3` returns as a
  **nemesis hunter** (lightweight: it hunts the player under the
  §4.11.11.1 hunter-intel rules).

### 4.12 Module interfaces (pins for `IMPLEMENT-Phase2.md`)

Parallel tasks must not invent two names for one thing (the Phase-1 lesson:
two divergent reputation models merged). These signatures are fixed; a task
implements exactly these and calls only these.

#### 4.12.1 `scripts/combat/battle_sim.gd` (`class_name BattleSim`)

Pure `RefCounted`; **never** mutates `GameState`. Callers hand it copies.

```
BattleSim.new(config: Dictionary)          # see config below
start() -> void
round_number() -> int
is_over() -> bool
outcome() -> Dictionary                     # §4.12.2, only after is_over()
current_unit() -> Dictionary                # {} when over
end_turn() -> void                          # advances to the next unit/round
unit_cell(unit: Dictionary) -> Vector2i
legal_moves(unit: Dictionary) -> Array[Vector2i]
move_to(unit: Dictionary, cell: Vector2i) -> bool
can_cannon(unit, target) -> bool
cannon(unit, target) -> Dictionary          # {ok, damage, sunk, log}
ram(unit, target) -> Dictionary
board(unit, target) -> Dictionary           # {ok, duel, ...} (duel via §4.12.1.2)
hold(unit) -> Dictionary
run_to_completion(policy: Callable, max_rounds: int = 40) -> Dictionary
```

`config` keys (all required unless marked):

| Key | Type | Meaning |
|---|---|---|
| `player_ships` | `[]Dictionary` | §4.11.11 ship instances, index 0 = flagship |
| `enemy_ships` | `[]Dictionary` | same shape |
| `enemy_kind` | `String` | `pirate` \| `navy` |
| `enemy_nation` | `String` | navy's nation id (`""` for pirates) |
| `day` | `int` | |
| `gold` | `int` | for the §4.11.1 seed |
| `contact` | `Vector2i` | world tile at contact |
| `weather` | `String` | `20-*` §4.7 value (`storm` halves cannon damage) |
| `seed` | `int` | *optional*; overrides the §4.11.1 formula (tests) |
| `player_stats` | `Dictionary` | *optional* (Phase 9) — `{attributes?: {constitution, intellect, charisma, courage, luck}, skills?: {…}, equipment?: {weapon, armor}}`; when present, the player reads (`player_attribute` / `player_effective_skill` / `player_duel_base`) take the override, falling back to `GameState` per key (the S21 seam, §4.12.4); absent ⇒ behavior byte-identical to today |
| `wind_dir` | `String` | *optional* (Phase 9) — the 8-token wind-FROM id at contact (default = `GameState.world["wind_dir"]`); locked for the battle |
| `current` | `Dictionary` | *optional* (Phase 9) — `{dir: <8-token flow-TO id>, strength: 0..3}`, the decoded, reversal-applied current at the contact tile; strength 0 = no current; default = the decoded contact tile regardless of the world's `current_mode` (correction 1) |

`unit` is a plain dict with at least `side` (`"player"`/`"enemy"`), `index`,
`ship` (the instance), and the §4.3a state — `pos` (`Vector2i`), `vel`
(`Vector2i`), `heading8`, `reload_port`, `reload_starboard`,
`speed_debuff_turns`, `crew` — plus `alive`. (The Phase-2 `cell` / `mp` /
`reload_until_round` triple is retired, §4.3a.)

Additional additive seams pinned during implementation (they were missing from
the first draft of this table and are now part of the contract):

```
BattleSim.units() -> Array              # every unit, both sides, deployment order
BattleSim.living_units(side) -> Array   # one side's survivors
BattleSim.flagship_unit() -> Dictionary # side "player", index 0 ({} if gone)
BattleSim.flagship_index() -> int       # -1 when the player has no ships left
BattleSim.is_acting(unit) -> bool       # unit is the current actor
BattleSim.retreat() -> Dictionary       # §4.11.9 `retreat` outcome
BattleSim.offer_surrender() -> Dictionary  # §4.11.7 player surrender
BattleSim.legal_velocities(unit: Dictionary) -> Array[Vector2i]  # §4.3a enumeration
BattleSim.apply_velocity(unit: Dictionary, vel: Vector2i) -> bool  # validate → clamp → integrate → sweep
BattleSim.snapshot() -> Array[int]      # flat mutable-state array (below)
BattleSim.restore(arr: Array[int]) -> void  # exact inverse of snapshot()
```

Phase-9 API pins: `run_to_completion`'s round-cap default is **40**
(correction 12). `snapshot()` is a flat mutable-state array — pos/vel/
heading8/durability/crew/per-side reload + speed-debuff/alive/**both side
morales** (§4.8a)/cursor scalars/`rng.state`; `restore(arr)` is its exact
inverse and is shared by the T3 search (§4.9c) and the tests.

`config` also accepts an optional `rng` (`RandomNumberGenerator`) so a caller
can hand over the **same** stream it used for `AiFleet.compose_enemy`, which
is what §4.11.1 means by "after deployment and enemy composition"; when `rng`
is absent the engine builds one from `seed`.

##### 4.12.1.1 `scripts/combat/ai_fleet.gd` (`class_name AiFleet`)

```
AiFleet.compose_enemy(kind: String, day: int, rng: RandomNumberGenerator) -> Array
AiFleet.decide(sim: BattleSim, unit: Dictionary) -> Dictionary
```

`decide` returns `{action, target, cell, vel}` (Phase 9) where `action` ∈
`cannon|ram|board|move|hold|surrender`; `target` is a unit dict or `{}`;
`vel` is the chosen velocity for `move`; `cell = pos + vel` is **derived**,
never authored. The cannon **shot type is NOT in the dict** — it is derived
at execution (§4.4b for AI, the S10 selector for the player). The T2
priority order is §4.9a exactly; `ai_level = 1` routes the decision through
§4.9c.

##### 4.12.1.2 Duel resolution (single implementation)

```
BattleSim.resolve_duel(
    player_base: int, defender_base: int,
    rng: RandomNumberGenerator) -> Dictionary
```

Returns `{result: "capture"|"defeat", rounds: [String], player_wins: int,
defender_wins: int}`, `rounds[i]` ∈ `"win"|"loss"|"tie"` from the player's
view, per §4.11.6. The battle's `board` action and the S11 modal both call
**this** function — never a second copy of the formula.

#### 4.12.2 Outcome block (§4.11.9/§4.11.10 payload)

```json
{
  "result": "victory",
  "rounds": 6,
  "kind": "pirate",
  "nation_id": "",
  "encounter_id": "nf_12_004_pirate",
  "contact": {"x": 30, "y": 40},
  "sunk_enemy": ["sloop"],
  "captured_enemy": [],
  "surrendered_enemy": 0,
  "sunk_player": [],
  "lost_player": [],
  "salvage_gold": 150,
  "xp": 65,
  "morale_delta": 0,
  "rep_deltas": {"portugal": 2, "spain": 2},
  "cargo_overflow_lost": 0
}
```

- `sunk_enemy` / `sunk_player` are `ship_type_id` lists (for the log/dialog).
- `captured_enemy` / `lost_player` are full ship instances (the §4.11.7
  capture rule consumes them). A ship that **surrendered** also appears in
  `captured_enemy` (§4.11.7 "resolved exactly as a duel win"), and
  `surrendered_enemy` is the dialog-wording count only — never add the two.
- `morale_delta` (int, Phase 9) is the §4.8a side-morale writeback: the
  caller applies it to `GameState.morale` in the §4.12.4 sequence —
  skipped entirely in the sandbox branch (§4.12.4).
- `salvage_gold`, `xp`, `rep_deltas` are the **pre-computed** §4.11.10 numbers;
  applying them is `BattleRewards.apply()` (§4.12.3). `rep_deltas` holds only
  pirate `+2` entries — the navy `−20` is charged once at battle start by
  whoever initiated the battle (§4.11.10), never here.
- `result` ∈ `victory` \| `defeat_sunk` \| `defeat_captured` \| `retreat` \|
  `surrender` \| `stall` — `stall` (Phase 9) is the mutual-disengage
  outcome (§4.11.9 row).

#### 4.12.3 The application seams

| Module | Owner task | API |
|---|---|---|
| `scripts/combat/battle_result.gd` (`class_name BattleResult`) | C | `apply(sim_outcome: Dictionary, enemy_units: Array, player_fleet_ref: Array) -> Dictionary` — fleet-only effects: captures join the fleet (§4.11.7) or are looted+scuttled, lost player ships are removed, flagship promotion, `gameover.captured`/`sunk` emission; returns the outcome with `cargo_overflow_lost` filled in. **Sunk player hulls leave the fleet too:** it removes both the `lost_player` instances and the `sunk_player` hull ids, because §4.7 makes this the only fleet mutator in a battle |
| `scripts/combat/duel.gd` (`class_name Duel`) | C | `start(config: Dictionary) -> Dictionary` — `config` = `{player_base, defender_base, seed, rng?, host?, ship_name, attacker_name, defender_name}`; runs `BattleSim.resolve_duel` and (in a scene tree, unless headless) presents `duel_modal.tscn`; returns **exactly** the `resolve_duel` dict (so it stays byte-comparable to a direct call) |
| `scripts/combat/battle_rewards.gd` (`class_name BattleRewards`) | G | `apply(outcome: Dictionary) -> Dictionary` — adds `salvage_gold`, awards `xp` through `Character.award_xp`, applies `rep_deltas` through `Character.add_reputation`; returns what it applied |
| `scripts/combat/fleet_commander.gd` (`class_name FleetCommander`) | W4-B | `generate_orders(view: Dictionary, profile: Dictionary, state: Dictionary) -> Array` — pure per-round order five-tuples (§4.9b); RefCounted, zero RNG |
| `scripts/combat/ai_search.gd` (`class_name AiSearch`) | W5-A | `decide(sim, unit, theta: Array) -> Dictionary` — the T3 enumeration (§4.9c) — plus the three `THETA_AGGRESSIVE / THETA_BALANCED / THETA_CAUTIOUS` const arrays; zero dice, ties by enumeration order |
| `scripts/world/npc_fleets.gd` (`class_name NpcFleets`) | J (core); K (auto-resolve/wreck methods), L (aliveness schedulers) extend the same file | the API block below — task J implements it exactly |

These two Phase-9 rows pin the **names + purity contract + zero-RNG
semantics**; their owning waves may refine the exact signatures.

`npc_fleets.gd` — pure `RefCounted`, never touches the battle grid
(replaces the retired `Encounters` row of the Phase-2 table):

```
NpcFleets.new(config: Dictionary)
initial_fill(day: int) -> void
tick(day: int) -> Array
fleets() -> Array
markers() -> Array
nearest_contact(cell: Vector2i) -> Dictionary
fleet_at(cell: Vector2i) -> Dictionary
remove(id: String) -> void
set_pursuit_cooldown(id: String, until_day: int) -> void
spawn(role: String, nation_id: String, day: int) -> Dictionary
wrecks() -> Array
collect_wreck(id: String, free_capacity: int) -> Dictionary
reset_rng(seed: int)
advance_clock() -> void
take_fleet_moves() -> Array
stall_reason(fleet: Dictionary) -> Dictionary
stalled_fleets(min_hold: int = 3) -> Array
```

- `new(config)` — `config = {npc_config, preset}`; computes the §4.1.1
  budgets × preset (`ceil` per role).
- `initial_fill(day)` — the §4.1.2 new-game fill to **half the cap**
  (seeded, distributed on lanes near ports); called by `new_game` only.
- `tick(day)` — the daily ecology tick in the `20-*` §4.3 order (after
  `day_advanced`): lane stepping, dwell, auto-resolve, trickle, treasure
  scheduler; returns the fleets spawned this tick (test seam).
  **Owner (amended 2026-11-02):** the `FleetSim` autoload runs it as the
  post-`day_advanced` listener in every scene — port day-advances (rest,
  hour-scale actions crossing midnight, the port Space wait) tick the
  ecology exactly like sea days; the ecology no longer freezes while the
  player is ashore. **Docked-player immunity:** contact checks stay with the
  world scene, so a hostile fleet that accrues onto a docked player's port
  tile opens nothing — it holds there, and the first contact check after
  Set Sail resolves it (`80-*` §4.3 world-scene-only presentation).
- `fleets()` — every live fleet dict (the §4.11.11 shape); the save payload.
- `markers()` — render dicts for `world_map.gd` (`role`, `nation_id`,
  `cell`, `convoy_id` when convoy-grouped, wake path); viewport-culled
  rendering upstream (`80-*` §4.5.2). Each entry also carries the
  diagnostics fields `holds` (the hold streak) and `stall` (the stall
  state, `""` while sailing) — the S3 badge and chart tooltip data.
- `nearest_contact(cell)` — the §4.11.11.2 contact rule: `pirate` /
  `privateer` / `hunter`-with-bounty within Chebyshev 1, wrap-aware;
  `{}` when none.
- `fleet_at(cell)` — any fleet whose cell matches (the right-click
  fleet_picker target, `80-*` §4.10.1); `{}` when none.
- `remove(id)` / `set_pursuit_cooldown(id, until_day)` — battle aftermath
  (§4.12.4 step 4).
- `spawn(role, nation_id, day)` — single seeded spawn (test seam; also the
  quest seam, `70-*` §4.9.3 Phase-5 note).
- **Clock accrual + diagnostics (unified-movement amendment, 2026-11-01;
  report shape amended 2026-11-02).**
  `advance_clock()` — accrues every fleet's movement for the elapsed world
  time (`Δ = day + clock_fraction − its per-fleet mark`; the world scene
  calls it per player move, `tick()` catches up — idempotent, no
  double-count) and reports fleet moves for the marker **path playback**
  (`80-*` §4.5.2): each entry is `{id, from, path, to}` — the pre-/post-
  accrual cells plus every cell the accrual committed, in walked order, so
  the marker replays the real route tile by tile; render-only, never
  saved. **Clock-rewind rebase (dormant since 2026-11-02):** set sail
  no longer resets `clock_fraction` — the world clock is continuous
  (`20-*` §4.3 port-hours amendment) — so fleet Δ ≤ 0 no longer occurs in
  play; the rebase path (a pass whose fleet Δ ≤ 0 snaps the mark to the
  clock and grants nothing) is kept as a headless/test-seam safety net.
  `stall_reason(fleet)` / `stalled_fleets(min_hold = 3)` — the read-only
  stall diagnostics: per-fleet state
  (`docked → cooldown → camping → chasing/pursuing → blocked → sailing`,
  with detail — docked/cooldown until-day, camping radius, sailing pipe
  rate) over the runtime-only hold counter (accrual budgets consumed
  without forward progress). Feeds the S19-gated debug badge and the
  debug chart's stalled-fleets row (`80-*` §4.5.2/§4.6).
- `wrecks()` / `collect_wreck(id, free_capacity)` — the §4.11.11.2 wreck
  view and player collect (cargo up to free capacity + salvage gold via
  `BattleRewards.salvage_for`).
- `reset_rng(seed)` — the test seam (as in Phase 2).

`battle_result.gd`, `battle_rewards.gd` and `npc_fleets.gd` are called
through `ResourceLoader.load(...)` + `has_method` guards where the caller
may run before the module exists (the Phase-1 `apply_fleet_guard`
convention), so no task can be blocked by a sibling's merge order.

#### 4.12.4 Call order at battle end (pin — keeps file ownership disjoint)

| `battle_screen.gd` (task D) owns the sequence below; every other module is
reached through the guards above, so D never edits a sibling's file:

1. `BattleSim` reports `is_over()`; its `outcome()` is the raw block.
2. `BattleResult.apply(raw, enemy_units, GameState.fleet)` — fleet effects
   (captures/losses/flagship promotion, `gameover.*`); returns the outcome
   with `cargo_overflow_lost`.
3. `BattleRewards.apply(outcome)` — gold, XP, reputation (§4.11.10).
4. `NpcFleets.remove(encounter_id)` — the fleet is gone (trickle/budgets
   refill the ecology, no per-kind immunity).
   **Exception — `retreat`:** §4.10's outcome is *not* a resolved battle, so
   the fleet is not removed; step 4 calls
   `NpcFleets.set_pursuit_cooldown(id, day + 1)` instead (the fleet then
   holds its tile and raises no contact for that day; inclusive reading,
   §4.11.11.1). §4.11.10's "fleet is removed" is the aftermath of a resolved
   battle only.
5. `GameState.set_world_tile(contact)`; emit `EventBus.battle_finished(outcome)`;
   show the after-action dialog; route to S3 unless a `gameover.*` fired.

**Sandbox zero-write branch (Phase 9, decision 15).** When
`encounter.sandbox == true`, steps 2/3/4 are **skipped entirely** — no
`BattleResult.apply`, no `BattleRewards.apply`, no `NpcFleets` mutation, no
world routing, no phase-3 hooks. The after-action dialog renders
**read-only** (existing dialog controls; the outcome block's
`morale_delta` may be displayed but is never applied), then the scene
routes back to S21 with its configuration kept (`80-*` §4.7.16). NOTHING
writes `GameState` / `NpcFleets` — audited by test.

`BattleSim` itself never touches `GameState`. `BattleResult` touches only
`GameState.fleet` (+ emits `gameover.*`/`fleet_changed`). `BattleRewards`
touches only `gold`, `player.xp` and `player.reputation`.

#### 4.12.5 Required `ui_strings.json` keys (Phase 2 inventory)

Task G owns this list; D/C/F use these keys and **must not invent others**
(add a note to the report instead). Placeholders must match between zh and en
(the validator enforces it).

| Key | zh | en |
|---|---|---|
| `battle.title` | 海战 | Battle |
| `battle.round` | 第 {round} 回合 | Round {round} |
| `battle.action.cannon` | 炮击 | Cannon |
| `battle.action.ram` | 撞击 | Ram |
| `battle.action.board` | 接舷 | Board |
| `battle.action.hold` | 待命 | Hold |
| `battle.action.retreat` | 撤退 | Retreat |
| `battle.action.surrender` | 投降 | Surrender |
| `battle.reload` | 装填中 | Reloading |
| `battle.target.none` | 未选定目标 | No target selected |
| `battle.log.cannon` | {attacker} 炮击 {target},造成 {damage} 点伤害。 | {attacker} fires on {target} for {damage} damage. |
| `battle.log.ram` | {attacker} 撞击 {target},自身受损 {self_damage} 点。 | {attacker} rams {target}, taking {self_damage} damage. |
| `battle.log.sunk` | {ship} 沉没了。 | {ship} has sunk. |
| `battle.log.turn` | 轮到 {ship}。 | {ship} to act. |
| `battle.duel.start` | 接舷战! | Boarding action! |
| `battle.duel.round` | 第 {round} 回合:{player} 对 {defender} | Round {round}: {player} vs {defender} |
| `battle.result.victory` | 胜利! | Victory! |
| `battle.result.defeat` | 战败。 | Defeat. |
| `battle.result.retreat` | 你脱离了战斗。 | You disengaged from the battle. |
| `battle.result.surrender` | 你投降了。 | You surrendered. |
| `battle.after.title` | 战后 | After the battle |
| `battle.after.loot` | 打捞所得 {gold} 金。 | Salvage: {gold} gold. |
| `battle.after.xp` | 获得 {xp} 点经验。 | Experience gained: {xp}. |
| `battle.after.captured` | 俘获 {ship}! | Captured {ship}! |
| `battle.after.scuttled` | 船队已满,{ship} 被拆解。 | Fleet full — {ship} was scuttled. |
| `battle.after.overflow` | {count} 单位货物因舱位不足而丢失。 | {count} units of cargo were lost for lack of hold space. |
| `battle.after.lost` | 你失去了 {ship}。 | You lost {ship}. |
| `battle.after.rep` | {nation} 声望 {delta} | {nation} reputation {delta} |
| `battle.log.hold` | {ship} 待命。 | {ship} holds position. |
| `battle.log.board` | {attacker} 接舷 {target}! | {attacker} boards {target}! |
| `battle.log.surrender_enemy` | {ship} 投降了。 | {ship} strikes her colours. |
| `battle.reason.no_cannons` | 本船没有火炮 | This ship carries no cannons |
| `battle.reason.out_of_range` | 目标不在射程内 | Target out of range |
| `battle.surrender.confirm` | 确定要投降吗? | Surrender the battle? |
| `battle.retreat.confirm` | 确定要撤退吗? | Retreat from the battle? |
| `duel.title` | 船长决斗 | Captain's Duel |
| `duel.round.win` | 胜 | Win |
| `duel.round.loss` | 负 | Loss |
| `duel.round.tie` | 平 | Tie |
| `duel.result.capture` | 你赢得了决斗,敌船投降! | You win the duel — the enemy ship strikes her colours! |
| `duel.result.defeat` | 你输掉了决斗,舰船被夺。 | You lose the duel and your ship is taken. |
| `duel.committed` | 接舷战无法撤退。 | Boarding commits — there is no retreat. |
| `encounter.pirate` | 海盗船队 | Pirate fleet |
| `encounter.navy` | {nation} 巡逻队 | {nation} patrol |
| `encounter.contact` | {fleet} 逼近! | {fleet} closes in! |
| `encounter.attack_confirm` | 攻击{nation}船队即是海盗行为(声望 −20)。确定吗? | Attacking a {nation} fleet is an act of piracy (−20 reputation). Continue? |
| `gameover.captured` | 你被俘了,船队落入敌手。 | Captured — your fleet is lost to the enemy. |

Phase 8 adds the `hail.*` / `interact.*` / `gate.*` families for the
picker verbs, the hail modal and the locked-reason renderer — inventoried
in `80-*` §4.15; battle-side consumers use those keys and never invent
new `battle.*` / `duel.*` ones.

Phase 9 adds the `battle.*` / `sandbox.*` families (the S10 rebuild and
the S21 editor) — inventoried in `10-*` §7.12; battle-side consumers use
those keys and never invent others.

## 5. Data Examples

Cannon volley (brigantine, 10 cannons, range 2, effective gunnery 30):

```json
{"cannons": 10, "range": 2, "range_factor": 0.75, "gunnery_bonus": 1,
 "damage": 16, "note": "floor(10×2×0.75) + floor(30/25) = 15 + 1"}
```

Duel round sequence (player swordplay 22 + courage 30 → `floor(30/20)` = 1,
cutlass +3; the defender defends with charisma 40 → +2):

```json
{"player_score_base": 26, "defender_base": "floor(crew/5) + captain duel rating + floor(charisma/20)",
 "rounds": ["win", "loss", "win", "win"],
 "result": "capture", "note": "22 + 1 + 3 = 26; best-of-5 decided 3-1"}
```

## 6. Edge Cases & Fail States

- **Both ships sink from a ram** — attacker resolves last; if the attacker's
  flagship sinks and no escorts → `gameover.sunk` (extends to battle).
- **Boarding a ship that surrenders the same round** — initiative order
  decides; surrender check happens on that ship's own turn only.
- **Capture with full fleet and full cargo** — loot-to-capacity then scuttle;
  overflow cargo reported lost in the after-action dialog.
- **Contact with two hostile fleets simultaneously** — battles chain: after
  the first battle resolves, the second opens immediately if still in range.
- **Duel RNG audit** — seeded (§4.9); a test seed must reproduce the exact
  round sequence.
- **Game-over reason set** becomes {starvation, scurvy, sunk, captured} from
  Phase 2 on.
- **Tournament battle with a bounty against its host** — cannot happen: the
  palace refuses entry before a battle can open (`70-*` §4.9.7).
- **A tournament battle that ends in `retreat`** — counts as a bracket loss;
  the consolation and the 50% repair still apply, and the enemy marker never
  existed on the world map, so nothing is removed from `npc_fleets`.

## 7. Acceptance Criteria

- [ ] Grid 16×10, MP/turn/action/increment rules §4.2–4.3 unit-tested.
- [ ] §5 worked cannon example reproduced exactly by `battle_sim.gd`.
- [ ] AI priority list §4.9 implemented in order; unit test per rule with a
      seeded fixture.
- [ ] Duel best-of-5 deterministic under a fixed seed; capture/loss paths
      both reachable in tests.
- [ ] Save v1→v2 migration adds `hostile_fleets` and passes `90-*` §8.2.
- [ ] All battle strings via `ui_strings.json` (`battle.*`, `duel.*`,
      `gameover.captured`).
- [ ] §4.11.1 seed formula reproduces a whole scripted battle, duel included.
- [ ] §4.11.2 deployment tiles and §4.11.3 composition reproduce exactly
      under a fixed seed.
- [ ] §4.11.13's 8 equipment items validate and change duel rolls / MP /
      ram damage as pinned in §4.11.12.

**Phase-5 additions (fleet ecology).**

- [ ] §4.1.1 budgets reproduce 134 traders / 77 coasters / 20 patrols /
      12 couriers / 12 privateers / ≈ 25 pirates at `normal`; core 272,
      global cap 288, `absolute_cap` 2048; `new_game` fills half the cap.
- [ ] Lane-locked roles (`trader`/`coaster`/`courier`/`treasure`) never
      leave their rasterized lanes; the pirate/privateer 10/16 chokepoint
      hysteresis (rescaled from Phase 5's 5/8 by the Phase-6 sweep) and the
      hunter's budgeted pursuit A* (≤ 250 ms/day,
      overflow loses the chase) are unit-testable.
- [ ] Auto-resolve: 60% seeded raider win vs an unescorted trader; raider
      loses vs patrol/escorted trader/convoy; the loser despawns into a
      5-day wreck; trader wreck = actual cargo; warship wreck =
      `BattleRewards.salvage_for` gold; player collect on the wreck tile.
- [ ] Contact opens battle only for `pirate`/`privateer`/
      `hunter`-with-bounty; a right-click attack on any attackable fleet
      charges `Bounty.apply_piracy` (−20 rep + −20 fame) once at battle
      start and loots actual cargo + `min(1000, 100 + 10 × day)`g
      (a coaster offers no attack verb — Phase 8, intimidate-only,
      §4.11.15).
- [ ] Treasure fleets sail their historical lanes on days
      45/60/75/90/105/120; a defeated named pirate re-enters play through
      the return queue (§4.11.15: `return_day = day + 60`, same name, tier
      drift ±1 clamp 1–3 — the Phase-5 "+30 days under a new name"
      respawn is retired); captain names survive save/load
      byte-identically.
- [ ] Perf gates (§4.11.11.5, as re-pinned by the unified-movement
      amendment): day tick ≤ 75 ms @ cap 288 and ≤ 350 ms @ extreme
      (≈ 1100 fleets), linear marginal cost, save ≤ 2.25 MB @ extreme (amended 2026-11-03, the v9 captain_states rows), zero
      runtime pathfinding for lane traffic.

**Phase-7 additions (trade empires).**

- [ ] Equipment set: 24 items validate (6 per slot, 2/2/2 tiers, prices
      300g–6,000g, i18n parity); the Phase-2 eight keep their prices and
      modifiers.
- [ ] `storm_damage_pct` / `scurvy_delay_days` act exactly per §4.11.12
      (ship-side product floored once; scurvy threshold `7 + Σ delay`).
- [ ] Rare items: never in any stock list, never purchasable; defeating a
      named pirate credits its `drop` item exactly once (famous-id keyed;
      a captain with no famous-id match drops nothing — Phase-8 wording,
      the `successor` alias is retired, §4.11.13); the replace rule
      sells the displaced item back at half price in the same grant.
- [ ] A nation-N trader docks at an effective-alignment-N port and never
      at a rival-aligned or unallied one; an unallied neutral port sees
      its grey coaster trade; no coaster ever carries
      luxury/specialty/exclusive goods.
- [ ] Host treasuries rise deterministically after an NPC port-call trade
      (`Allegiance.credit_tax`, walked totals reused); nationless
      coasters credit nothing; the NPC-sourced tax cap is 2,000g per
      nation per month.

**Phase-8 additions (the RPG overhaul, 2026-11-02).**

- [ ] Duel rolls `swordplay + floor(courage / 20) + equipment +
      rand(0, 20)` with the defender adding `+ floor(charisma / 20)`
      (§4.11.6); the seeded round sequence is re-baselined and
      reproducible under a fixed seed.
- [ ] `combat_rating` is computed once at fleet composition from the
      captain's card (§4.11.5): duel rating, cannon rating
      `+floor(gunnery / 25)`; appointed player escorts price the same
      way; a captain-less escort cannon rating stays 0.
- [ ] Gunnery: the flagship volley gains `+floor(effective_gunnery / 25)`;
      chain shot unlocks at gunnery ≥ 25 (damage ×0.75, target MP −1 for
      2 rounds); armor-piercing unlocks at ≥ 50 (damage ×1.25, ignores
      equipment armor) (§4.4).
- [ ] AI surrender rolls `clamp(25 − floor(courage / 10), 10, 40)%`
      (§4.7); capture requires `fleet.size < FLEET_MAX` **and** ≥ 1 idle
      officer, else the loot-convert fallback fires (§4.11.7/§4.11.15).
- [ ] Haul valuation ×(1 + (appraisal + negotiation) / 400) clamp
      [×1.0, ×1.5]; battle XP ×(1 + level / 20); boarding-victory morale
      +5 (§4.8/§4.11.10).
- [ ] Coasters expose no attack verb (intimidate-only); a successful
      intimidate takes half the cargo + pirate fame +5, a failed one
      opens the §4.11.11.2 battle (§4.11.15).
- [ ] The return queue: `return_day = day + 60`, tier drift ±1 clamp 1–3,
      names never reused, `stance ≤ −3` → nemesis hunter;
      `npc_captains.json` / `named_pirate_respawns` / `successor_<tier>`
      are gone (validator-asserted, §4.11.11.4).
- [ ] Attacking a non-hostile fleet charges −20 reputation (+2 rivals)
      **and** −20 fame exactly once at battle start (§4.11.10).
