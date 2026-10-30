# 60 — Combat (Sea Battles & Duels)

## 1. Purpose & Phase

Specifies turn-based grid-lite sea combat: encounter generation, battle grid
setup, turn order, movement, cannon/ram/boarding, the captain duel, damage,
surrender, capture, loot, retreat, and enemy AI. Gates **Phase 2**. Uses the
Phase-1 ship/fleet/stat data unchanged.

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/combat/battle_screen.tscn` | grid battlefield scene (S10) |
| `scenes/combat/duel_modal.tscn` | captain duel modal (S11) |
| `scripts/combat/battle_sim.gd` | turn engine (RefCounted, deterministic-seedable) |
| `scripts/combat/ai_fleet.gd` | enemy decision rules (§4.9) |
| `scripts/world/encounters.gd` | world-map hostile fleet spawning (§4.1) |
| `data/equipment.json` | Phase-2 equipment content set (§4.11.13) |
| GameState additions | `hostile_fleets` (world-map roamers), `proximity_cooldowns`, battle outcomes; save `save_version` bumps to 2 (migration `90-*` §8.2) |

## 3. Dependencies

`10-*` (ShipType/Equipment schemas), `20-*` (map constants, weather reuse),
`40-*` (ship instances, durability, cargo, FLEET_MAX), `50-*` (combat stat,
equipment modifiers), `80-*` (S10/S11 conventions), `90-*` (save migration).

## 4. Systems / Mechanics

### 4.1 Encounter generation (world map)

- A hostile fleet is a world-map marker moving 1 tile/day step toward its
  patrol anchor; kinds: `pirate` (red square), `navy` (nation-color square).
- **One world grid.** Markers live on the single Terra Vera world grid
  (`20-*` §4.1): their `position` values are tile coordinates on the
  2160×1080 grid, and **all x-distance math is wrap-aware** — a marker at
  `x = 2158` is 2 tiles from a fleet at `x = 0`, and zone/anchor distances
  never exceed `2160/2 = 1080`. A tile is 10 nm, so every tile distance below
  is 10 nm per tile.
- **Pirate spawn:** at each day tick at sea, 1% chance; zone: within 15 tiles
  (Chebyshev, wrap-aware; 150 nm — the pinned Phase-2 value, not re-derived on
  the new grid) of any of that spawn's anchor ports; composition per §4.11.3
  (1–3 ships, hull tiers rolled from `latin…brigantine`, total cannons ≤
  20 + floor(day/30)). The Phase-2 storm-strip exclusion is retired with the
  strip itself: weather is now latitude-band (`20-*` §4.7), so no tile-based
  spawn exclusion remains.
- **Navy spawn:** only while the player holds a bounty against that nation
  (`70-*` §4.5: rep ≤ −50); chance 2% per day tick at sea, 2–4 ships,
  composition per §4.11.3. (Pinned here in Phase 2; the bounty *trigger* itself
  stays a Phase-3 task.)
- **Contact:** hostile marker entering Chebyshev distance 1 of the player →
  `battle_screen` opens. Pirates are hostile always; navies only with bounty.
- Player may also *initiate* battle against a navy marker (attack action on
  world map); doing so is piracy against that nation (`70-*`, rep −20).

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
- **Movement points (MP):** `MP = ShipType.speed` (no crew/wind modifiers in
  battle — locked simplification). Orthogonal step = 1 MP, diagonal = 2 MP.
  Unspent MP does not carry over.

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
- **MP:** `MP = speed + sail_speed_delta`, refreshed to full at the start of
  each of the ship's turns; unspent MP is discarded. Orthogonal step 1 MP,
  diagonal 2 MP. A diagonal step is legal only when both orthogonally adjacent
  corner tiles are inside the grid (no obstacles exist, §4.2).
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
    at **battle start** (`60-*` §4.1 "attacking a navy marker … rep −20"), or
    on contact with a hunter. It is **not** charged per ship and it is never
    repeated at battle end, so:
    - `BattleRewards`/`encounters.gd` apply it on initiation only;
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
- **Return:** the fleet is placed on the contact tile, the hostile marker is
  removed, and a spawn immunity of **3 days** is recorded for that marker kind
  (§4.8). A `retreat` keeps the marker instead (§4.10 pursuit cooldown, §4.12.4
  step 4).

#### 4.11.11 `hostile_fleets` save block (pairs with `90-*` §8.1)

```json
[
  {
    "id": "hf_7_30_40_pirate",
    "kind": "pirate",
    "nation_id": "",
    "position": {"x": 30, "y": 40},
    "anchor_port_id": "lisbon",
    "ships": [{"ship_type_id": "sloop", "durability": 60, "crew": 10,
               "provisions": 0, "water": 0, "cannons": 4,
               "equipment": {"figurehead": "", "sail": ""},
               "cargo": {"wine": 6}}],
    "spawn_day": 7,
    "cooldown_until_day": 0
  }
]
```

`kind` ∈ `pirate` \| `navy`; `nation_id` is the navy's nation (empty for a
pirate); ships use the §4.11.3 instance shape (the `40-*` §4.1 instance plus
the `equipment` object of §4.11.12).

#### 4.11.11.1 Marker movement & contact (pin for `encounters.gd`)

- **Anchor port:** a spawn's `anchor_port_id` is its anchor per §4.11.11.1
  (nearest known port for pirates, nearest own-nation port for navies;
  Chebyshev; ties by port id ascending); it never changes.
- **Zone check:** a pirate spawn candidate must be within Chebyshev 15 of its
  anchor port's harbor tile, measured **wrap-aware on x** over the 2160×1080
  world grid. The 15-tile radius is the pinned Phase-2 `ZONE_RADIUS` value, not
  re-derived: on the Phase-4 grid (1 tile = 10 nm) it is 150 nm. The Phase-2
  Atlantic-storm-strip exclusion is deleted with the strip; latitude bands
  (`20-*` §4.7) replace it and impose no spawn exclusion.
  Candidate tiles are drawn as described in §4.11.11.2.
- **Movement:** each day tick at sea, after the daily ledger, every marker
  steps **1 tile** toward its anchor port using the greedy Chebyshev reduction
  of §4.11.8 rule 5 (same tie-breaks, `x` taken mod 2160 so the step picks the
  short way across the seam), skipping occupied and occupied-by-fleet tiles; a
  marker never steps onto `#` land, `^` reef or `I` ice, and never onto an
  occupied tile. A marker that reaches its anchor port's cell is removed.
- **Contact:** measured after both the player move and the marker step, at
  Chebyshev distance 1, wrap-aware on x. A pirate is hostile always; a navy
  only while the player's reputation with its nation is ≤ −50 (`70-*` §4.5).
- **Pursuit cooldown:** a marker that lost a battle (player retreat) does not
  move for 1 day (`60-*` §4.10), tracked in `marker.cooldown_until_day`.
  **Inclusive reading:** `cooldown_until_day` is the *last idle day*, so a
  battle on day D stores `D + 1`, the marker stays put on D+1 and moves again
  on D+2. While a marker is on pursuit cooldown it also raises **no contact**,
  which is what stops a retreat (fleet returned to the contact tile, right
  beside the marker) from re-opening the same battle forever.
  This deliberately differs from `proximity_cooldowns`, which §4.11.11.2 pins
  as a *first legal day*.
- **Spawn immunity:** after any battle the kind's next legal spawn day is
  `day + 3`, stored in `GameState.proximity_cooldowns[kind]` (`90-*` §8.1).
- **Anchor by kind:** a pirate anchors to the nearest **known** port; a navy
  anchors to the nearest port **of its own nation** (a patrol belongs to its
  own navy), else the nearest port. Both use Chebyshev distance over the
  2160×1080 world grid, wrap-aware on x, ties by port id. No storm-strip
  exclusion exists (deleted with the strip, `20-*` §4.7).

#### 4.11.11.2 Spawn rolls (pin)

At each **day tick at sea** (`EventBus.day_advanced` while `current_port` is
null), in this order, using a dedicated world RNG seeded from the same
formula family as §4.11.1 (`seed = day × 1000003 + x × 7919 + y × 104729`):

1. If `day < proximity_cooldowns.get("pirate", 0)` → skip the pirate roll.
2. Pirate: `rng.randf() < 0.01` → spawn one `pirate` marker on a random
   candidate tile in the §4.11.11.1 zone (uniform over candidates, rejected
   if occupied); if no candidate exists the roll is spent.
3. Navy: for each nation with `reputation[nation] ≤ −50` whose last navy spawn
   is not on cooldown, `rng.randf() < 0.02` → spawn one `navy` marker of that
   nation inside its own ports' 15-tile zone.
4. Markers never exceed **3 at once**; a roll that would exceed the cap is
   spent with no spawn.
5. A marker's `id` is `hf_<day>_<x>_<y>_<kind>` — deterministic and unique
   per spawn day.

#### 4.11.11.3 Contact → battle handoff (pin for S10/S3)

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
shows the after-action dialog and routes back to S3. Contact with two markers
in the same tick chains: the second opens after the first finishes (§6).

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
  "encounter_id": "hf_12_30_40_pirate",
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

#### 4.12.3 The three application seams

| Module | Owner task | API |
|---|---|---|
| `scripts/combat/battle_result.gd` (`class_name BattleResult`) | C | `apply(sim_outcome: Dictionary, enemy_units: Array, player_fleet_ref: Array) -> Dictionary` — fleet-only effects: captures join the fleet (§4.11.7) or are looted+scuttled, lost player ships are removed, flagship promotion, `gameover.captured`/`sunk` emission; returns the outcome with `cargo_overflow_lost` filled in. **Sunk player hulls leave the fleet too:** it removes both the `lost_player` instances and the `sunk_player` hull ids, because §4.7 makes this the only fleet mutator in a battle |
| `scripts/combat/duel.gd` (`class_name Duel`) | C | `start(config: Dictionary) -> Dictionary` — `config` = `{player_base, defender_base, seed, rng?, host?, ship_name, attacker_name, defender_name}`; runs `BattleSim.resolve_duel` and (in a scene tree, unless headless) presents `duel_modal.tscn`; returns **exactly** the `resolve_duel` dict (so it stays byte-comparable to a direct call) |
| `scripts/combat/battle_rewards.gd` (`class_name BattleRewards`) | G | `apply(outcome: Dictionary) -> Dictionary` — adds `salvage_gold`, awards `xp` through `Character.award_xp`, applies `rep_deltas` through `Character.add_reputation`; returns what it applied |
| `scripts/world/encounters.gd` (`class_name Encounters`) | F | `tick(is_at_sea: bool) -> Array`, `markers() -> Array`, `nearest_contact(cell: Vector2i) -> Dictionary`, `remove(id: String)`, `set_cooldown(kind: String, until_day: int)`, `spawn(kind, nation_id, day) -> Dictionary` (test seam), `reset_rng(seed: int)` |

`battle_result.gd` and `battle_rewards.gd` are called through
`ResourceLoader.load(...)` + `has_method` guards where the caller may run
before the module exists (the Phase-1 `apply_fleet_guard` convention), so no
task can be blocked by a sibling's merge order.

#### 4.12.4 Call order at battle end (pin — keeps file ownership disjoint)

| `battle_screen.gd` (task D) owns the sequence below; every other module is
reached through the guards above, so D never edits a sibling's file:

1. `BattleSim` reports `is_over()`; its `outcome()` is the raw block.
2. `BattleResult.apply(raw, enemy_units, GameState.fleet)` — fleet effects
   (captures/losses/flagship promotion, `gameover.*`); returns the outcome
   with `cargo_overflow_lost`.
3. `BattleRewards.apply(outcome)` — gold, XP, reputation (§4.11.10).
4. `Encounters.remove(encounter_id)` + `Encounters.set_cooldown(kind, day + 3)`.
   **Exception — `retreat`:** §4.10's outcome is *not* a resolved battle, so the
   marker is not removed; step 4 calls
   `Encounters.set_pursuit_cooldown(id, day + 1)` instead (the marker then holds
   its tile and raises no contact for that day) and still records the 3-day
   spawn immunity. §4.11.10's "marker is removed" is the aftermath of a resolved
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
- **Contact with two hostile markers simultaneously** — battles chain: after
  the first battle resolves, the second opens immediately if still in range.
- **Duel RNG audit** — seeded (§4.9); a test seed must reproduce the exact
  round sequence.
- **Game-over reason set** becomes {starvation, scurvy, sunk, captured} from
  Phase 2 on.
- **Tournament battle with a bounty against its host** — cannot happen: the
  palace refuses entry before a battle can open (`70-*` §4.9.7).
- **A tournament battle that ends in `retreat`** — counts as a bracket loss;
  the consolation and the 50% repair still apply, and the enemy marker never
  existed on the world map, so nothing is removed from `hostile_fleets`.

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
