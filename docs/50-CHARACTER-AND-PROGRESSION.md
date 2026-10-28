# 50 — Character & Progression

## 1. Purpose & Phase

Specifies the nationality-choice new-game flow, player stats and their
effects, XP/levels, officer recruitment and assignment, per-nation
reputation, and the harbor-relief anti-softlock flow. Gates Phase 1 (titles,
fame, and royal progression are Phase 3 and only sketched where data fields
already exist).

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/title/nationality_select.tscn` | new-game nation picker |
| `scripts/player/character.gd` | stats, XP/level, officers (RefCounted) |
| GameState key | `player` — save block shape in §4.8 |

## 3. Dependencies

`10-DATA-SCHEMA.md` (Nation/Officer schemas + locked tables), `20-*` (stat
effects on sailing, harbor-relief constants), `30-*` (tavern UI hosting),
`40-*` (crew caps), `80-*` (screen conventions), `90-*`.

## 4. Systems / Mechanics

### 4.1 Nationality choice flow

1. Title screen → New Game → `nationality_select.tscn`.
2. Six nation cards (fixed order: Portugal, Spain, England, Holland, Ottoman,
   Italy), each showing: flag color block, `Nation.name`,
   `Nation.description`, and the start package (port, ship, gold) exactly as
   in `data/nations.json` — nothing is hardcoded in the scene.
3. Confirm → `GameState.new_game(nation_id)`:

```
day = 1
gold = Nation.start_gold
player = { nation_id, stats: base 10 + nation bonus (§4.2),
           xp: 0, level: 1, officers: [],
           reputation: { own: Nation.start_reputation, others: 0 } }
fleet = [ new instance of Nation.start_ship_type_id (40-* §4.3 "Buy ship"
          instance defaults, but crew = ShipType.crew_min ) ]
world.position = Nation.start_port_id's harbor tile (GameState.current_port set,
                 so the game opens on the port screen, not at sea)
known_ports = the 6 capital ports (20-* §4.11)
```

4. Route to `port_screen.tscn` for the start port.

### 4.2 Stats

Five player stats, each 1–100, base 10 at new game plus the nation bonus:

| Stat | Nation bonus | Effect (Phase 1) |
|---|---|---|
| leadership | spain +5, ottoman +5 | desertion losses × (1 − (leadership−10)/200); mutiny chance × (1 − (leadership−10)/200) |
| seamanship | holland +5 | speed bonus `(seamanship−10)/100`, clamp [−0.10, +0.20] (`20-*` §4.4) |
| combat | england +5 | no Phase-1 effect (consumed by `60-*`) |
| navigation | portugal +5 | sighting radius = 8 + floor((navigation−10)/10) (`20-*` §4.11) |
| luck | italy +5 | storm damage ×0.75 when luck ≥ 50; storm chance ×(1 − luck/400) |

Effects read `player.stats` plus assigned-officer bonuses (§4.5), computed on
demand by `character.gd#effective_stat(name)`.

### 4.3 XP & levels

- XP sources (Phase 1, locked): +2 per day tick at sea; +1 per 100g of profit
  (floor) on each sell transaction (profit = sell revenue − purchase cost
  tracked per stack; stacks bought before this system existed count purchase
  cost as 0 → ignored: Phase 1 tracks cost basis per stack from the start,
  see `player` field below? — locked simplification: profit XP uses
  `sell_price − good.base_price × 0.7` floor 0 per unit, no cost tracking).
- Level rule: `level = floor(sqrt(xp / 50)) + 1`, recomputed lazily; level
  cap 20.
- On each level-up (detected after XP award): +1 seamanship, +1 to the
  player's nation-bonus stat; a toast reports it (`ui_strings
  char.level_up`). No manual allocation in Phase 1.

### 4.4 Officers — recruit & dismiss

- Source: `data/officers.json` locked roster of 6 (`10-*` §7.5). An officer
  appears in a port's tavern (officers tab, `30-*` §tavern) iff this port ∈
  `Officer.recruit_ports` and the officer is not employed.
- **Recruit:** click `Recruit` → added to `player.officers`; signing cost =
  `wage_daily × 10` (paid once). Max 3 officers (locked `OFFICER_MAX = 3`).
- **Dismiss:** from the same tab; no severance; the officer returns to its
  recruit pool (visible again at its recruit ports).
- Daily wage: `Σ officer.wage_daily` in the ledger (`20-*` §4.5 step 2).
- One-time hire: an employed officer never appears in any tavern list
  (persistence via the save block §4.8).

### 4.5 Officer assignment & effects

Phase-1 simplification: officers are auto-assigned to the flagship; roles
give flat stat bonuses to `effective_stat`, stacking if multiple officers
share a role:

| Role | Bonus |
|---|---|
| navigator | +10 navigation |
| boatswain | +10 seamanship |
| gunner | +10 combat (Phase-2 relevant; crib notes shown greyed in P1) |

Manual ship-role assignment UI OUT OF SCOPE (phase 2, multi-ship crews).

### 4.6 Reputation

- Per nation, integer −100…+100, stored in `player.reputation`.
- Phase-1 sources: +1 per 1,000g cumulative profit sold at a nation's ports
  (per nation, per transaction sum). No decay.
- Phase-1 effects: display only (shown on the character panel). Trade refusal
  and title gating OUT OF SCOPE (phase 3, `70-*`).

### 4.7 Harbor relief (full flow; spec constants in `10-*` §5)

1. Condition evaluated whenever `inn_screen` opens and after each odd job:
   `gold < 100 && fleet.is_empty()`.
2. If eligible: "Work an odd job" enabled; each click: `gold += 100`,
   advance one ledger day (`20-*` §4.5 — with no fleet there is no
   consumption; wages: no crew, no officers → 0 cost; morale delta +5/day
   applies but morale is moot without crew).
3. If ineligible: button disabled with reason label (`guest has a ship` /
   `not broke`), key `inn.odd_job.ineligible`.
4. There is no GUI path to sell your last ship (`40-*` §6), so this state is
   reached only after sinking-without-escort game over — which ends the run —
   OR by starting shipless, which never happens. **Locked clarification:**
   harbor relief exists to satisfy the anti-softlock rule for future
   mechanics (Phase-2 capture/loss); in Phase 1 it is implemented and tested
   via a debug hook (`GameState.debug_strip_fleet()`) but is normally
   unreachable in play. This is intentional and documented to avoid
   implementing a fake path.

### 4.8 Save block shape (`player`)

```json
{
  "nation_id": "portugal",
  "stats": {"leadership": 10, "seamanship": 10, "combat": 10, "navigation": 15, "luck": 10},
  "xp": 37,
  "level": 1,
  "officers": ["off_mateus_alvares"],
  "reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0, "ottoman": 0, "italy": 0}
}
```

- `officers` stores ids (full records live in `data/officers.json`).
- `level` is stored but re-derived from `xp` on load (stored value is a
  cache; derivation wins on mismatch, logged).

## 5. Data Examples

Effective-stat computation (Portugal start + Mateus Álvares aboard):

```json
{
  "base": {"navigation": 15, "seamanship": 10},
  "officer_bonus": {"navigation": 10, "seamanship": 0},
  "effective": {"navigation": 25, "seamanship": 10},
  "derived": {"sighting_radius": 9, "speed_bonus": 0.0},
  "note": "sighting 8 + floor((25-10)/10) = 9; speed (10-10)/100 = 0"
}
```

Level table (first rows of `level = floor(sqrt(xp/50)) + 1`):

```json
{"xp": 0, "level": 1, "next_at": 50}
// xp 50→L2; 200→L3; 450→L4; 800→L5; 1250→L6; cap L20 at 18050 xp
```

## 6. Edge Cases & Fail States

- **Recruit with gold < signing cost** → button disabled with price shown.
- **4th officer recruit attempt** → Roster full; button disabled
  (`char.officers_full`).
- **Level computed on load disagreement** → xp wins (§4.8).
- **XP from a loss-making sale** → profit term floors at 0; sales never
  remove XP.
- **Reputation display before any trade** → all-zero except own nation; no
  Nation rows hidden.
- **Multiple navigators** → bonuses stack (§4.5) but overlap clamped by the
  sighting/speed formulas' own clamps.
- **Harbor relief with officers employed** → officer wages still run in the
  ledger; if that drains gold below 0 the wage rule (`20-*` §4.5) applies.
  Locked: odd jobs are disabled while officers are employed (dismiss first);
  reason shown in the disabled label.

## 7. Acceptance Criteria

- [ ] Nationality select renders exactly 6 cards from `nations.json`; no
      scene hardcoding (test: edit a start_gold value → card reflects it).
- [ ] §4.1 new-game block initializes exactly as specified (unit test on
      `GameState.new_game`).
- [ ] Stat effect formulas (§4.2 table) are implemented in `character.gd` and
      unit-tested at boundaries (stat 10, 20, 100).
- [ ] Level formula and level-up rewards match §4.3 for xp ∈ {0, 49, 50,
      200, 18050}.
- [ ] Tavern officer flow: recruit → disappears from list, appears in panel,
      survives save/load; dismiss → reappears.
- [ ] Harbor-relief button state machine matches §6 rules including the
      officers-employed lockout.
- [ ] Reputation increments on profitable sales at the correct nation's ports
      only.
