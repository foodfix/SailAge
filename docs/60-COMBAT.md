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

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/combat/battle_screen.tscn` | grid battlefield scene (S10) |
| `scenes/combat/duel_modal.tscn` | captain duel modal (S11) |
| `scripts/combat/battle_sim.gd` | turn engine (RefCounted, deterministic-seedable) |
| `scripts/combat/ai_fleet.gd` | enemy decision rules (§4.9) |
| `scripts/world/npc_fleets.gd` | world-map NPC fleet ecology — 8 roles, lane routing, auto-resolve, wreckage (§4.1, §4.11.11) |
| `data/npc_config.json` `npc_captains.json` `named_pirates.json` `trade_routes_built.json` | Phase-5 fleet content (schemas `10-*`; authored by tasks A/D/E/F) |
| `data/equipment.json` | Phase-2 equipment content set (§4.11.13) |
| GameState additions | `npc_fleets` (fleet dicts, §4.11.11), `wrecks`, battle outcomes; Phase 5 saves as `SAVE_VERSION = 5` (no migration, v4 refused — `90-*` §8.2) |

## 3. Dependencies

`10-*` (ShipType/Equipment schemas; Phase-5 `npc_config.json`/
`npc_captains.json`/`named_pirates.json`/`trade_routes_built.json`),
`20-*` (map constants, weather reuse, day-tick order §4.3), `30-*` §4.4
(the trader market rules NPC traders decide by), `40-*` (ship instances,
durability, cargo, FLEET_MAX), `50-*` (combat stat, equipment modifiers,
reputation), `70-*` §4.5 (bounty tiers, piracy rep), `80-*` (S10/S11
conventions, fleet markers), `90-*` (save v5 blocks, autoload order).

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
  2160×1080 grid, and **all x-distance math is wrap-aware** — a fleet at
  `x = 2158` is 2 tiles from a fleet at `x = 0`, and no distance below ever
  exceeds `2160/2 = 1080`. A tile is 10 nm, so every tile distance below
  is 10 nm per tile.
- **Fleet shape (locked).** All fleets are save-shaped as
  `{id, role, nation_id, cell(vec2), route, cargo, captain, specialty?,
  cooldown_until_day, …}`; pirates keep `nation_id: ""`. Budgets multiply by
  the density preset (`ceil` per role), from `npc_config.json` (`10-*`).
- **Player surface.** Contact and the right-click attack funnel are pinned
  once, in the §4.11.11.2 table; the trader decision rule is `30-*` §4.4.

#### 4.1.1 The 8 fleet roles & budgets (locked)

| Role | Budget (normal) | Computed @ 6 nations / 100 ports | Behavior (pin) |
|---|---|---|---|
| `trader` | `ceil(own_ports × 1.25)`/nation | 25+25+23+23+18+13 = **127** | own-nation routes via lane graph; 2-day dwell; joint profit-per-day decision; sells only where `factor > 1.0` |
| `coaster` | `ceil(own_ports × 0.75)`/nation | 15+15+14+14+11+8 = **77** | visual-life small craft; adjacent-port spokes; hold ≤ 10, trades ≤ 5/call; **never triggers contact**, raiders ignore; attacking one is ordinary piracy; loot `25 + floor(day/10)`g |
| `patrol` | `ceil(own_ports / 6)`, min 1 | **19** | cycles its nation's lanes, docking en route; same-nation traders within Chebyshev 10 count escorted; halves pirate/privateer spawn rolls in its 15-tile zone |
| `courier` | 2/nation | **12** | capital ↔ own-ports dispatch runs (sightings/rumors only — no quest mechanics this phase) |
| `privateer` | 2/undirected rivalry pair | **12** | stations on its sponsor's rivals' major lanes (chokepoint-biased); hunts only those rivals' fleets; defeating one: +2 rep with **each** of the two sponsor rivals |
| `pirate` | `8 + unpatrolled_zones` (computed daily: navy 15-tile zones lacking a patrol) | ≈ **25** | camps tagged chokepoints; prefers nearest trader/patrol within Chebyshev 10 |
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

- Grid: 16×10 square tiles, rendered at 48px (`80-*` sizing); terrain: all
  sea except a 1-tile `land #` ring option? — locked: open sea, no obstacles
  in Phase 2 (reef/coast terrain OUT OF SCOPE (phase 3)).
- Deployment: player ships on the west edge column band (x ≤ 2), enemy on the
  east band (x ≥ 13), one ship per tile, flagship centered per side.
- Ship unit = its ship instance: durability, crew, cannons, cargo carried in.
- Weather (from world state at contact) applies: storm ⇒ all cannon damage
  ×0.75 and no wind speed effects beyond MP table below.

### 4.3 Turn structure

- **Rounds:** each round, every living ship acts once in **initiative order**
  = descending `ShipType.speed`; ties break player-before-enemy, then fleet
  index. A unit destroyed before its turn skips it.
- **Per turn:** up to `MOVE` followed by at most 1 action: cannon / ram /
  board / hold. Actions resolve immediately; animations are Phase-2 polish,
  non-blocking log lines suffice as placeholder.
- **Movement points (MP):** `MP = battle_mp(ShipType.speed)` (no crew/wind
  modifiers in battle — locked simplification). Orthogonal step = 1 MP,
  diagonal = 2 MP. Unspent MP does not carry over.
  **`battle_mp` (Phase-4 pin, required because `ShipType.speed` doubled):**
  the battle grid is unchanged at 16×10 while world speeds became tiles/day on
  10 nm tiles, so MP is **not** the raw speed. It is the Phase-1 battle value
  preserved exactly: `battle_mp(speed) = speed / 2` (integer division), i.e.
  `{8→4, 10→5, 12→6}`. This reproduces every Phase-2 MP budget and initiative
  tie-break byte-for-byte (latin 4, sloop 5, caravel 5, galley 6, brigantine 6,
  nao 4, carrack 4, galleon 5) — no battle balance number changes, and a
  brigantine still cannot cross a 16-wide field in one turn. A sail
  equipment's `speed` modifier is added **after** the halving
  (`MP = battle_mp(ShipType.speed) + sail_speed_delta`), so `+1` sail still
  buys exactly the Phase-2 step it bought (latin `4 → 5`).

### 4.4 Cannon

- Requirement: `cannons ≥ 1` and target within Chebyshev range `1..3`.
- Arc: none (360° fire — locked simplification; arcs OUT OF SCOPE (phase 3)).
- Damage: `floor(cannons × 2 × range_factor)`, `range_factor` = 1.0 / 0.75 /
  0.5 at range 1 / 2 / 3.
- **Reload:** after firing, that ship cannot fire on its next turn.
- Gunner officer bonus: +10 combat effective adds +1 damage per volley per 10
  combat (i.e., `+ floor(effective_combat / 10)` damage, attacker).

### 4.5 Ram

- Action against an orthogonally adjacent ship: both take damage —
  target: `floor(0.25 × attacker_max_durability)`;
  attacker: `floor(0.10 × attacker_max_durability)`.
- Oar/hybrid ramming sail: target damage ×1.25 (galley identity rule).

### 4.6 Boarding & captain duel

- Action against an orthogonally adjacent enemy ship → duel modal (S11).
- **Duel:** best-of-5 rounds. Each round both sides roll
  `effective_combat + equipment deltas + rand(0, 20)`; higher wins the round;
  tie = no score. First to 3 round-wins takes the duel. The defender uses the
  ship's effective combat: `floor(crew / 5)` capped 20, plus the enemy
  "captain rating" = 5 + fleet tier (pirate tier 1, navy tier 2) rolled once
  at battle start (no separate NPC stats — locked simplification).
- **Player wins duel:** the ship is **captured**: if `fleet.size <
  FLEET_MAX` it joins at 25% current durability minimum 1, cleared crew,
  cargo intact; else it is looted (cargo taken to capacity) and scuttled.
- **Player loses duel:** the player's ship is captured — if it was the
  flagship: the next ship becomes flagship (rules of `40-*` §4.4); if no
  ships remain → game over `gameover.captured` (new reason added in Phase 2;
  extends `20-*` §4.9 list).
- Retreat from duel: none — boarding commits.

### 4.7 Damage, sinking, surrender

- Durability 0 at battle → ship sinks immediately; cargo lost (no salvage in
  battle, consistent with `40-*` §4.4).
- **AI surrender:** at its turn, an AI ship below 25% max durability with a
  player ship within 3 tiles surrenders (becomes a capture as if duel-won,
  no duel). Player ships never auto-surrender; the player may offer
  surrender from the battle menu: battle ends, enemy takes flagship cargo
  only, ships retained (pirates), or flagship itself (navy with bounty —
  which clears the bounty, `70-*`).

### 4.8 Loot & aftermath

- Victory (all enemy ships sunk/captured/surrendered/retreated): loot = all
  cargo of captured ships (already handled) + gold =
  `Σ sunk_ship base_price × 0.05` (salvage sale abstraction).
- Battle XP: +10 combat-relevant XP per sunk/captured ship to sailing XP pool
  (`50-*` §4.3 gains `+2 per battle round survived`? — locked: +10 XP per
  enemy ship neutralized, +5 per round survived).
- Reputation: defeating pirates +2 with the two nearest ports' nations;
  attacking/sinking navy ships applies `70-*` piracy deltas.
- Return: world map at contact tile; the hostile marker despawns; spawn
  immunity 3 days.

### 4.9 Enemy AI (deterministic priority list, top-down first match)

1. If durability < 25% max and any player ship within 3 → surrender (§4.7).
2. If cannons ≥ 1, loaded, and a player ship in range → fire at the
   lowest-durability target.
3. If own cannons > total player cannons and orthogonally adjacent to the
   player flagship → board.
4. If orthogonally adjacent to a player ship and weaker guns → ram.
5. Move toward the nearest player ship, spending full MP (path: greedy
   Chebyshev reduction, avoid occupied tiles).
6. Hold.

Seeded RNG (§4.11.1: one stream per battle, seeded from save state + contact
tile + day) makes AI and duel rolls reproducible for tests.

### 4.10 Player retreat

- Menu action `battle.retreat`: ends battle; fleet returns to world map one
  tile back along its approach (must be passable, else adjacent pick);
  enemy marker gets +1 day pursuit cooldown. Retreating forfeits nothing but
  costs no XP; navy battles: rep delta still applies for ships already sunk.

### 4.11 Phase-2 normative pins (resolves every "task-owned" value)

Phase-1 implementation (see `IMPLEMENT-Phase1.md` "Completion record") showed
that a value left to a task gets invented differently by each task. Every
number §4.1–§4.10 leaves open is therefore fixed here, before code.

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

#### 4.11.2 Deployment (concrete tiles)

Grid `x ∈ 0…15`, `y ∈ 0…9`. One ship per tile, no two ever share a cell.

| Fleet index | Player cell | Enemy cell |
|---|---|---|
| 0 (flagship) | (1, 4) | (14, 4) |
| 1 | (1, 5) | (14, 5) |
| 2 | (1, 3) | (14, 3) |
| 3 | (1, 6) | (14, 6) |
| 4 | (1, 2) | (14, 2) |

The flagship is vertically centred; extras alternate below/above it. Both
bands satisfy §4.2 (`x ≤ 2` / `x ≥ 13`) and start 13 tiles apart, so every
battle opens with a movement phase.

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

- **Round:** build the initiative list at round start from living ships:
  descending `ShipType.speed` (+ sail-equipment speed delta, §4.11.12), ties
  player-before-enemy, then ascending fleet index. A unit destroyed before its
  slot is skipped and never acts.
- **MP:** `MP = battle_mp(ShipType.speed) + sail_speed_delta` (§4.2/§4.3,
  Phase-4 pin: integer division by 2, sail delta added after), refreshed to
  full at the start of each of the ship's turns; unspent MP is discarded.
  Orthogonal step 1 MP, diagonal 2 MP. A diagonal step is legal only when both
  orthogonally adjacent corner tiles are inside the grid (no obstacles exist,
  §4.2).
- **Occupancy:** a ship may never enter or pass through an occupied tile.
- **Reload:** firing sets `reload_until_round = round + 2`; a ship may fire
  only when `round ≥ reload_until_round`. Firing in round 1 therefore blocks
  round 2 and allows round 3 (§4.4 "cannot fire on its next turn").
- **One action per turn:** cannon, ram, board or hold, after any movement.
- **Damage order:** every action resolves immediately; the log line is the
  only presentation in Phase 2.

#### 4.11.5 Damage numbers (pin)

- **Cannon:** `base = floor(cannons × 2 × range_factor) +
  floor(combat_rating / 10)`; in storm weather `damage = floor(base × 0.75)`
  (§4.2 "all cannon damage ×0.75"), otherwise `damage = base`.
  `combat_rating` = the player's effective `combat` stat for a player
  flagship, `0` for player escorts, `5 + fleet tier` for AI ships.
- **Ram:** `target = floor(0.25 × attacker_max_durability)`,
  `attacker = floor(0.10 × attacker_max_durability)`; if the attacker's
  `ShipType.class` is `oar` or `hybrid` then
  `target = floor(target × 1.25)` (§4.5, galley identity rule).
  `attacker_max_durability` is the **effective** max from §4.11.12.
- **Sinking:** `durability ≤ 0` → the ship is removed immediately and its
  cargo is lost (no salvage while the battle runs). A ram that sinks both
  ships resolves the attacker last (§6).

#### 4.11.6 Duel resolution (pin)

- Both sides roll `base + rng.randi_range(0, 20)` each round.
  Player `base` = effective `combat` + the sum of `combat` modifiers on worn
  weapon/armor equipment (§4.11.12).
  Defender `base` = `min(floor(crew / 5), 20) + (5 + fleet tier)`; the captain
  rating is rolled once at battle start (§4.6) and stored on the ship.
- Higher roll wins the round; equal rolls score for neither side.
- First side to **3** round wins takes the duel.
- **Undecided after 5 rounds** (only possible with ties): more round wins
  takes it; equal counts → the defender holds, i.e. the boarding attempt
  fails and the attack is spent.

#### 4.11.7 Capture, loss and surrender (pin)

- **Player wins (§4.6):** the enemy ship joins the fleet when
  `fleet.size < FLEET_MAX`, at `max(1, floor(current durability × 0.25))`,
  `crew = 0`, **cargo intact**, cannons and equipment intact. If the hold is
  then over capacity, `Fleet.normalize_all()` truncates it and the
  after-action dialog reports the overflow (§6). With a full fleet the ship is
  looted (its cargo moved to fleet capacity flagship-first, the rest reported
  lost) and scuttled.
- **Player loses (§4.6):** the ship the player boarded *from* is taken — hull,
  hold, cannons and equipment all leave with it (a capture is not a sinking:
  nothing relocates). If it was the flagship, the next ship becomes flagship
  (`fleet[0]`, order preserved). No ships left → `gameover.captured`.
- **AI surrender (§4.7):** resolved exactly as a duel win (capture/loot), with
  no duel and no XP for the duel rounds.
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

#### 4.11.8 AI decision pins (§4.9)

- Rule 2 ("lowest-durability target"): lowest current durability, ties to the
  lower fleet index.
- Rule 3/4 comparisons use **current cannon counts** (`ship.cannons`), summed
  over living player ships for the "total player cannons" term.
- Rule 5 pathing: greedy Chebyshev reduction; among reachable tiles prefer the
  one minimising `max(|dx|, |dy|)` to the nearest player ship, then
  minimising `|dx| + |dy|`, then the lowest `(y, x)` cell. If no tile improves
  the distance, spend nothing and hold.

#### 4.11.9 Battle end conditions (pin)

| Outcome | Trigger |
|---|---|
| `victory` | every enemy ship is sunk, captured, surrendered or retreated |
| `defeat_sunk` | the player's last ship sinks → `gameover.sunk` |
| `defeat_captured` | the player's last ship is captured (duel loss or navy surrender) → `gameover.captured` |
| `retreat` | `battle.retreat` chosen |
| `surrender` | player surrender chosen (§4.11.7) |

#### 4.11.10 Rewards & aftermath (pin)

- **Salvage gold:** `Σ floor(ShipType.base_price × 0.05)` over ships **sunk**
  by the player during this battle. Captured/surrendered ships pay no salvage.
- **Battle XP** (awarded to `player.xp` via `Character.award_xp`):
  `+10` per enemy ship neutralised (sunk/captured/surrendered) and `+5` per
  round the battle lasted.
- **Reputation:**
  - Pirates defeated (any outcome except retreat) → `+2` with each of the
    **two nearest ports' nations** measured by Chebyshev distance from the
    contact tile (wrap-aware on x over the 2160×1080 world grid). The **two
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
  - **Tournaments (Phase 3).** `enemy_kind = "tournament"` is not a nation
    and contributes **no** reputation delta of any kind (no −20, no +2, no
    bounty).
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
    "captain": {"pool_id": "portugal", "name_index": 3},
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
- `captain` is `{pool_id, name_index}` into `data/npc_captains.json`
  (§4.11.11.4); `specialty` is the trader's persisted specialty good
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
  its nation's lanes. `pirate`/`privateer` anchor within Chebyshev 3 of
  chokepoint tiles and leave only for prey within Chebyshev 5, returning
  when prey is beyond 8 or lost (**5/8 hysteresis**). `hunter` stays
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
  | Chase trigger | the player's fleet within **Chebyshev 15** (wrap-aware) ⇒ direct pursuit — in **any** hunter state: en route, loitering, or homing |
  | Pursuit | short-range A\* only inside that radius, still under the ≤ 250 ms/day budget; losing the player beyond **Chebyshev 20** ends the chase — the hunter returns to the lane network / the intel port (**15/20 hysteresis**) |
  | At-sea intel | contact with any fleet of a hunting nation updates `world.hunter_intel_cell` to the contact cell (one assignment on contact) |

  `world.last_departed_port` (port id string) and `world.hunter_intel_cell`
  (tile position) persist in the v5 `world` block, so hunter placement is
  exactly reproducible after a reload. A new Set Sail re-targets under-way
  hunters at their next day tick (deterministic).
- **Stepping.** Fleets advance along their lane's rasterized tile path at
  **1 tile/day** inside the §4.1.2 flow, skipping occupied tiles and never
  entering `#` land, `^` reef or `I` ice; port-bound roles dwell **2 days**
  in port (the §4.1.1 trader row pins the trader dwell). Chokepoint
  anchoring keeps a `pirate`/`privateer` within Chebyshev 3 of its
  chokepoint tiles except during a chase (the 5/8 hysteresis above).
- **Pursuit is the only runtime A\* (locked).** The time-budgeted A*
  (≤ 250 ms/day, §4.1.2 `path_budget_ms_per_day`) survives only for the
  hunter's short-radius chase (the 15/20 hunter-intel hysteresis above); a
  budget overflow **loses the chase that day**. Lane traffic — now
  including hunter travel — never pathfinds (the §4.11.11.5 zero-A* gate).
- **Contact.** Measured after the fleet step, at Chebyshev distance 1,
  wrap-aware on x — the §4.11.11.2 table's row is the whole rule: only
  `pirate` / `privateer` / `hunter`-with-bounty open battle; every other
  role sails past.
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
| Player contact (Chebyshev 1, wrap-aware) | opens battle only for `pirate` / `privateer` / `hunter`-with-bounty — exactly as today |
| Player attacks any fleet (right-click) | non-pirate owner pays `Bounty.apply_piracy` (−20 owner, +2 its rivals) **once per battle at start** (existing single funnel); loot = actual cargo + `min(1000, 100 + 10 × day)`g |
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
  whole-fleet cannon budget `30 + floor(day/30)`.
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
- **Named pirates (locked):** `data/named_pirates.json`: 4 captains, zh/en,
  tiers 1–3 (`70-*` §4.5); defeated → respawn as a new name **+30 days**;
  `quest_gen` bounty targets prefer named captains.
- **Treasure fleets (locked):** 1/nation/season on day `45 + 15 ×
  nation_index` (mod 90), `nation_index` = `nations.json` file order
  (portugal 0 … italy 5) ⇒ days 45/60/75/90/105/120; 3–5 ships + patrol
  escort on the nation's historical lane; loot = cargo (×3 normal volume) +
  `min(3000, 500 + 25 × day)`g.
- **Captain identity (locked):** every fleet draws
  `captain: {"pool_id", "name_index"}` at spawn from
  `data/npc_captains.json` (6 nation pools + `""` nationless pool, ≥ 8
  zh/en names each) via its seeded stream; names never flicker on reload;
  famous pirates override; a captain dies with its fleet.
- **Sighting surfaces** (market/tavern/inn/palace rows, wanted posters, the
  20g reveal) and the seeded facility/presence rolls are pinned in `80-*`
  §4.7.8; the pure query module `scripts/world/npc_intel.gd` (task L)
  implements them — sightings by port/facility (60/40 + 75% rolls), wanted
  posters within Chebyshev 40, exact-position lookup for the paid reveal,
  rumor row sources. Tavern rumors source from live fleets within Chebyshev
  40, departures/arrivals at the port within 3 days, and demand-event
  telegraphs.

#### 4.11.11.5 Spatial index & performance gates (locked)

- **Spatial index (locked):** one wrap-aware **cell-bucket hash**
  (cell → fleet) serving occupancy, contact, and neighborhood queries
  (prey-10, escort-10, patrol zones) — every per-day check linear in fleet
  count. **Every "within N tiles" check goes through the bucket index**
  (review gate, tasks J/K).

Perf gates (measured in tools suites — tasks J/M):

| Gate | Pin |
|---|---|
| Day tick @ normal (cap 288) | ≤ 50 ms headless, zero runtime pathfinding for lane traffic |
| Day tick @ extreme (≈ 1 100 fleets) | ≤ 150 ms headless |
| Marginal cost | demonstrably linear (extreme ≈ 4× normal, not 16×) |
| Pursuit A* | ≤ 250 ms/day budget, overflow loses the chase |
| Save payload @ extreme | ≤ 2 MB |

#### 4.11.12 Equipment wiring (pairs with `10-*` §4.6, `40-*` §4.1)

- **Ownership:** `weapon` and `armor` are the **player's** two slots, stored in
  `player.equipment = {"weapon": "", "armor": ""}` (equipment id or empty
  string). `figurehead` and `sail` are **per ship**, stored in
  `ship.equipment = {"figurehead": "", "sail": ""}`.
- **Duel:** the player's roll adds the sum of every `combat` modifier across
  the two worn player items.
- **Battle:** `sail` adds its `speed` modifier to that ship's MP and to its
  initiative value; `figurehead` adds its `durability` modifier to that ship's
  **effective max durability**, which is the base for ram damage (§4.11.5) and
  the cap for its current durability.
- **Purchase:** shipyard, §4.3 refit row plus an equipment list (§4.11.13).
  Buying into an occupied slot sells the old item back at
  `floor(price × 0.5)` in the same transaction.
- Missing `equipment` keys (old save, hand-edited file) read as empty slots —
  the accessors default, they never fail.

#### 4.11.13 Equipment content set (8 items, Phase 2)

Locked list for `data/equipment.json` (same field schema as `10-*` §4.6).
Prices are `money`; modifiers use §4.11.12 semantics.

| id | zh | en | slot | modifiers | price |
|---|---|---|---|---|---|
| `eq_cutlass` | 水手弯刀 | Sailor's Cutlass | weapon | `combat` +3 | 400 |
| `eq_rapier` | 贵族细剑 | Noble's Rapier | weapon | `combat` +5 | 1200 |
| `eq_breastplate` | 胸甲 | Breastplate | armor | `combat` +2 | 700 |
| `eq_lucky_charm` | 幸运护符 | Lucky Charm | armor | `combat` +1, `luck` +5 | 900 |
| `eq_mermaid_figurehead` | 美人鱼船首像 | Mermaid Figurehead | figurehead | `durability` +10 | 1500 |
| `eq_dragon_figurehead` | 龙首船像 | Dragon Figurehead | figurehead | `durability` +20 | 3200 |
| `eq_cotton_sails` | 棉帆 | Cotton Sails | sail | `speed` +1 | 1000 |
| `eq_storm_sails` | 风暴帆 | Storm Sails | sail | `speed` +1, `durability` +5 | 2600 |

Buy price = `price`; sell-back = `floor(price × 0.5)`. All items are sold at
every Phase-1 shipyard (regional restrictions OUT OF SCOPE (phase 3)).

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
run_to_completion(policy: Callable, max_rounds: int = 30) -> Dictionary
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

`unit` is a plain dict with at least `side` (`"player"`/`"enemy"`), `index`,
`ship` (the instance), `cell` (`Vector2i`), `mp`, `reload_until_round`,
`alive`.

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
```

`config` also accepts an optional `rng` (`RandomNumberGenerator`) so a caller
can hand over the **same** stream it used for `AiFleet.compose_enemy`, which
is what §4.11.1 means by "after deployment and enemy composition"; when `rng`
is absent the engine builds one from `seed`.

##### 4.12.1.1 `scripts/combat/ai_fleet.gd` (`class_name AiFleet`)

```
AiFleet.compose_enemy(kind: String, day: int, rng: RandomNumberGenerator) -> Array
AiFleet.decide(sim: BattleSim, unit: Dictionary) -> Dictionary
```

`decide` returns `{action, target, cell}` where `action` ∈
`cannon|ram|board|move|hold|surrender`; `target` is a unit dict or `{}`;
`cell` is the destination for `move`. The priority order is §4.9 exactly.

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
  "rep_deltas": {"portugal": 2, "spain": 2},
  "cargo_overflow_lost": 0
}
```

- `sunk_enemy` / `sunk_player` are `ship_type_id` lists (for the log/dialog).
- `captured_enemy` / `lost_player` are full ship instances (the §4.11.7
  capture rule consumes them). A ship that **surrendered** also appears in
  `captured_enemy` (§4.11.7 "resolved exactly as a duel win"), and
  `surrendered_enemy` is the dialog-wording count only — never add the two.
- `salvage_gold`, `xp`, `rep_deltas` are the **pre-computed** §4.11.10 numbers;
  applying them is `BattleRewards.apply()` (§4.12.3). `rep_deltas` holds only
  pirate `+2` entries — the navy `−20` is charged once at battle start by
  whoever initiated the battle (§4.11.10), never here.
- `result` ∈ `victory` \| `defeat_sunk` \| `defeat_captured` \| `retreat` \|
  `surrender`.

#### 4.12.3 The application seams

| Module | Owner task | API |
|---|---|---|
| `scripts/combat/battle_result.gd` (`class_name BattleResult`) | C | `apply(sim_outcome: Dictionary, enemy_units: Array, player_fleet_ref: Array) -> Dictionary` — fleet-only effects: captures join the fleet (§4.11.7) or are looted+scuttled, lost player ships are removed, flagship promotion, `gameover.captured`/`sunk` emission; returns the outcome with `cargo_overflow_lost` filled in. **Sunk player hulls leave the fleet too:** it removes both the `lost_player` instances and the `sunk_player` hull ids, because §4.7 makes this the only fleet mutator in a battle |
| `scripts/combat/duel.gd` (`class_name Duel`) | C | `start(config: Dictionary) -> Dictionary` — `config` = `{player_base, defender_base, seed, rng?, host?, ship_name, attacker_name, defender_name}`; runs `BattleSim.resolve_duel` and (in a scene tree, unless headless) presents `duel_modal.tscn`; returns **exactly** the `resolve_duel` dict (so it stays byte-comparable to a direct call) |
| `scripts/combat/battle_rewards.gd` (`class_name BattleRewards`) | G | `apply(outcome: Dictionary) -> Dictionary` — adds `salvage_gold`, awards `xp` through `Character.award_xp`, applies `rep_deltas` through `Character.add_reputation`; returns what it applied |
| `scripts/world/npc_fleets.gd` (`class_name NpcFleets`) | J (core); K (auto-resolve/wreck methods), L (aliveness schedulers) extend the same file | the API block below — task J implements it exactly |

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
```

- `new(config)` — `config = {npc_config, preset}`; computes the §4.1.1
  budgets × preset (`ceil` per role).
- `initial_fill(day)` — the §4.1.2 new-game fill to **half the cap**
  (seeded, distributed on lanes near ports); called by `new_game` only.
- `tick(day)` — the daily ecology tick in the `20-*` §4.3 order (after
  `day_advanced`): lane stepping, dwell, auto-resolve, trickle, treasure
  scheduler; returns the fleets spawned this tick (test seam).
- `fleets()` — every live fleet dict (the §4.11.11 shape); the save payload.
- `markers()` — render dicts for `world_map.gd` (`role`, `nation_id`,
  `cell`, `convoy_id` when convoy-grouped, wake path); viewport-culled
  rendering upstream (`80-*` §4.5.2).
- `nearest_contact(cell)` — the §4.11.11.2 contact rule: `pirate` /
  `privateer` / `hunter`-with-bounty within Chebyshev 1, wrap-aware;
  `{}` when none.
- `fleet_at(cell)` — any fleet whose cell matches (the right-click attack
  target); `{}` when none.
- `remove(id)` / `set_pursuit_cooldown(id, until_day)` — battle aftermath
  (§4.12.4 step 4).
- `spawn(role, nation_id, day)` — single seeded spawn (test seam; also the
  quest seam, `70-*` §4.9.3 Phase-5 note).
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

## 5. Data Examples

Cannon volley (brigantine, 10 cannons, range 2, gunner effective combat 14):

```json
{"cannons": 10, "range": 2, "range_factor": 0.75, "combat_bonus": 1,
 "damage": 16, "note": "floor(10×2×0.75) + floor(14/10) = 15 + 1"}
```

Duel round sequence (player combat 12 + cutlass 3):

```json
{"player_score_base": 15, "defender_base": "floor(crew/5) + captain_rating",
 "rounds": ["win", "loss", "win", "win"],
 "result": "capture", "note": "best-of-5 decided 3-1"}
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

- [ ] §4.1.1 budgets reproduce 127 traders / 77 coasters / 19 patrols /
      12 couriers / 12 privateers / ≈ 25 pirates at `normal`; core 272,
      global cap 288, `absolute_cap` 2048; `new_game` fills half the cap.
- [ ] Lane-locked roles (`trader`/`coaster`/`courier`/`treasure`) never
      leave their rasterized lanes; the pirate/privateer 5/8 chokepoint
      hysteresis and the hunter's budgeted pursuit A* (≤ 250 ms/day,
      overflow loses the chase) are unit-testable.
- [ ] Auto-resolve: 60% seeded raider win vs an unescorted trader; raider
      loses vs patrol/escorted trader/convoy; the loser despawns into a
      5-day wreck; trader wreck = actual cargo; warship wreck =
      `BattleRewards.salvage_for` gold; player collect on the wreck tile.
- [ ] Contact opens battle only for `pirate`/`privateer`/
      `hunter`-with-bounty; a right-click attack on any fleet charges
      `Bounty.apply_piracy` once at battle start and loots actual cargo +
      `min(1000, 100 + 10 × day)`g.
- [ ] Treasure fleets sail their historical lanes on days
      45/60/75/90/105/120; a defeated named pirate respawns +30 days under
      a new name; captain names survive save/load byte-identically.
- [ ] Perf gates (§4.11.11.5): day tick ≤ 50 ms @ cap 288 and ≤ 150 ms @
      extreme (≈ 1100 fleets), linear marginal cost, save ≤ 2 MB @ extreme,
      zero runtime pathfinding for lane traffic.
