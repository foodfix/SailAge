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

- XP sources (Phase 1, locked):
  - +2 per day tick at sea (ledger day at sea only, not in-port day advances).
  - +1 per 100g of sale profit (floor) on each sell transaction. Locked
    simplification: no cost-basis tracking; per-unit profit is
    `max(0, sell_price − floor(base_price × 0.7))` (the 0.7 = the
    `produces`-port factor from `30-*` §4.2), transaction profit is
    `qty × per-unit profit`, and `xp += floor(profit / 100)`. A loss-making
    sale therefore adds 0 XP and never removes XP.
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
- Phase-1 sources: +1 per 1,000g **cumulative** profit sold at a nation's
  ports. No decay.
- **Phase-3 sources** (`70-*` §4.2/§4.3/§4.5): quest rewards
  (`rewards.reputation`), royal missions (+10), piracy (−20 with the victim,
  +2 with each of its two `rivals`), piracy bounties (rep reset to exactly
  −10 on clearing), and quest failure (−5, or −10 for a royal mission). Every
  delta funnels through `add_reputation()` so the clamp is applied once.
- **Cumulative accounting (normative).** The 1,000g threshold carries across
  transactions — 600g then 400g at the same nation grants the point neither
  sale earns alone. Two `player`-block fields track it:
  `profit_by_nation` (`{nation_id: lifetime sale profit}`) and
  `profit_rep_awarded` (`{nation_id: reputation points already paid out}`).
  Only the difference between `floor(profit_by_nation / 1000)` and
  `profit_rep_awarded` is granted through `add_reputation()`, so the reputation
  clamp and points from other sources (officers, quests) are unaffected. Both
  fields are persisted (§4.8) because the accumulator must survive save/load;
  a save predating the first sale simply omits them, which reads as all-zero.
  `character.gd#add_profit_reputation()` owns the rule; the market only
  supplies the transaction's profit. This model is idempotent — replaying a
  sale cannot double-award, because the paid-out counter is stored.
- Phase-1 effects: display only (shown on the character panel). Trade refusal
  and title gating OUT OF SCOPE in Phase 1; **Phase 3 activates them**:
  titles gate retirement and boost sell prices (`70-*` §4.9.2), and a
  reputation ≤ −50 issues a bounty that closes that nation's ports
  (`70-*` §4.9.5/§4.9.6).

### 4.7 Harbor relief (full flow; spec constants in `10-*` §5)

1. Condition evaluated whenever `inn_screen` opens and after each odd job:
   `fleet.is_empty() && officer_count() == 0 && gold < 1200` — the threshold is
   the cheapest hull price (`latin`, `10-*` §7.3), not 100; gating on
   `gold < 100` while paying `+100` would close the gate after one job and
   make the 1,200g hull unreachable (`10-*` §5 "Why the threshold is 1,200").
2. If eligible: "Work an odd job" enabled; each click: `gold += 100`,
   advance one ledger day (`20-*` §4.5 — with no fleet there is no
   consumption; wages: no crew, no officers → 0 cost; morale delta +5/day
   applies but morale is moot without crew).
3. If ineligible: button disabled with a specific reason label — key
   `inn.odd_job.ineligible` plus one of `inn.odd_job.has_ship`,
   `inn.odd_job.not_broke` (gold ≥ 1,200), `inn.odd_job.officers`.
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
  "reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0, "ottoman": 0, "italy": 0},
  "profit_by_nation": {"england": 1100},
  "profit_rep_awarded": {"england": 1},
  "equipment": {"weapon": "eq_cutlass", "armor": ""}
}
```

- `officers` stores ids (full records live in `data/officers.json`).
- `level` is stored but re-derived from `xp` on load (stored value is a
  cache; derivation wins on mismatch, logged).
- `profit_by_nation` / `profit_rep_awarded` are the §4.6 cumulative-profit
  accumulator, written by `character.gd#add_profit_reputation()` on every
  profitable sale; absent keys read as zero.
- `equipment` is the Phase-2 player-worn block (`60-*` §4.11.12): `weapon` and
  `armor` hold equipment ids or `""`. Absent in a Phase-1 save; the migration
  (`90-*` §8.2) and every accessor default it to empty slots.

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
{"xp": 0, "level": 1, "next_at": 50,
 "table": "50→L2; 200→L3; 450→L4; 800→L5; 1250→L6; cap L20 at 18050 xp"}
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
      only, with the 1,000g threshold accumulating across transactions.
- [ ] Phase-3 fame/title fields exist on `GameState` and save as v3; every
      Phase-3 reputation source in §4.6 is applied through
      `Character.add_reputation()` and clamped once.
