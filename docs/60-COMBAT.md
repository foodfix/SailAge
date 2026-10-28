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
| GameState additions | `hostile_fleets` (world-map roamers), battle outcomes; save `save_version` bumps to 2 (migration `90-*` §8.2) |

## 3. Dependencies

`10-*` (ShipType/Equipment schemas), `20-*` (map constants, weather reuse),
`40-*` (ship instances, durability, cargo, FLEET_MAX), `50-*` (combat stat,
equipment modifiers), `80-*` (S10/S11 conventions), `90-*` (save migration).

## 4. Systems / Mechanics

### 4.1 Encounter generation (world map)

- A hostile fleet is a world-map marker moving 1 tile/day step toward its
  patrol anchor; kinds: `pirate` (red square), `navy` (nation-color square).
- **Pirate spawn:** at each day tick at sea, 1% chance; zone: within 15 tiles
  of any of that spawn's anchor ports but outside the Atlantic storm strip;
  composition: 1–3 ships, hull tiers rolled from `latin…brigantine`, total
  cannons ≤ 20 + floor(day/30) (scaled to progress).
- **Navy spawn:** only while the player holds a bounty against that nation
  (`70-*` §piracy); Phase-2 hunters: 2–4 ships, tolerance for detail
  task-owned in `IMPLEMENT-Phase2.md`.
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

Seeded RNG (battle seed = hash(save state + contact tile + day)) makes AI and
duel rolls reproducible for tests.

### 4.10 Player retreat

- Menu action `battle.retreat`: ends battle; fleet returns to world map one
  tile back along its approach (must be passable, else adjacent pick);
  enemy marker gets +1 day pursuit cooldown. Retreating forfeits nothing but
  costs no XP; navy battles: rep delta still applies for ships already sunk.

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
