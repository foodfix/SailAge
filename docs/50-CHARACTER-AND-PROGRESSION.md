# 50 — Character & Progression

*(Phase 8 full rewrite, 2026-11-02 — the RPG overhaul. Replaces the Phase-1
four-stat `stats` block with the unified **Person model** 人物. Every number
below is ratified in `IMPLEMENT-Phase8.md` "Decision record" + "Locked
design" §2.1–§2.9 (corrections folded in); W2+ code may not land before this
doc merges.)*

## 1. Purpose & Phase

Specifies the Person model shared by player, officers and NPC captains:
five innate attributes 体魄 constitution / 悟性 intellect / 魅力 charisma /
胆识 courage / 运气 luck (1–100, start 10) plus acquired skills 技能
(player 8 + officer 3, 0–100, start 0); the two-step new-game flow
(nationality → background 出身背景 → free points); usage growth, paid
training 付费训练 and level-up allocation 分配; the officer roster v2
(96 people), posts 职位, loyalty 忠诚 and per-post contribution 贡献;
per-nation reputation 声望; and the harbor-relief anti-softlock flow.
Gates Phase 8. Titles/fame/royal progression stay Phase 3 (`70-*`).

A **Person** is the card data: name, nation, the 5 attributes, the 11
skills, personality tags, appearance tags, plus role-specific state. The
player, every officer in `data/officers.json` v2 and every captain in
`data/captains.json` is a Person. Only the player holds XP/level and
allocates free points; skill growth rules (§4.3) are identical for player
and officers.

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/title/nationality_select.tscn` | creation step 1 — nation picker (unchanged) |
| `scenes/title/creation_screen.tscn` | **new** — creation step 2: background card + free points + live derived preview (`80-*`) |
| `scenes/ui/character_card.tscn` | **new** — unified person card (player / officer / NPC); the player variant hosts the allocation steppers (`80-*`) |
| `scripts/player/character.gd` | player Person, XP/level/`alloc_pending`, officers, reputation |
| `scripts/player/skills.gd` | **new** — skill counters, usage growth, paid training, `skill_gates` lookup |
| `data/backgrounds.json` | 6 backgrounds (creation step 2a) |
| `data/skill_gates.json` | feature gates `{feature_id, stat_or_skill, threshold, reason{zh,en}}` |
| `data/officer_posts.json` | post table: `{post_id, slot_type: flagship\|captain, prereq, desc{zh,en}, advice}` |
| `data/officers.json` | **v2, built artifact** of `tools/build_captains.py` — 96-person roster |
| `data/captains.json` | built NPC canon (same generator; owned by `90-*`/`60-*`) |
| GameState key | `player` — save block shape §4.8; `officer_states` / `captain_states` are **top-level** save blocks (`90-*` §8) |

## 3. Dependencies

`10-DATA-SCHEMA.md` (Person/officers-v2/backgrounds/skill_gates/
officer_posts schemas + locked tables), `20-*` (speed §4.4, morale §4.8,
fail states §4.9, sighting §4.11 — consumers of §4.2/§4.3), `30-*`
(tavern recruit + train hosting, tariff/permit gates), `40-*`
(`FLEET_MAX = 5`, fleet-panel captain rows, capture/idle-officer gate),
`60-*` (duel/gunnery/boarding/ramming consumers; battle-XP multiplier),
`70-*` (Phase-3 reputation sources, bounty board), `80-*` (card,
creation, appointment, hail screens), `90-*` (save v9).

## 4. Systems / Mechanics

### 4.1 New-game flow (two-step)

1. Title screen → New Game → `nationality_select.tscn`: six nation cards
   (fixed order Portugal, Spain, England, Holland, Ottoman, Italy) showing
   flag color block, `Nation.name`, `Nation.description`, and the start
   package (port, ship, gold) exactly as in `data/nations.json` — nothing
   hardcoded in the scene. Confirm → `creation_screen.tscn`.
2. **Step ① background 出身背景** — `data/backgrounds.json`, exactly 6
   choices; each grants one attribute **+3** and one skill **+5**:

   | id | name | bonus |
   |---|---|---|
   | `background_deckhand` | 甲板水手 Deckhand | constitution +3 / seamanship +5 |
   | `background_navy_cadet` | 海军见习生 Naval Cadet | courage +3 / navigation +5 |
   | `background_merchant_apprentice` | 商行学徒 Merchant Apprentice | charisma +3 / negotiation +5 |
   | `background_cartographer_apprentice` | 制图学徒 Cartographer's Apprentice | intellect +3 / cartography +5 |
   | `background_tavern_errand` | 酒馆跑腿 Tavern Runner | luck +3 / rumour +5 |
   | `background_fencing_student` | 剑馆弟子 Fencing Student | courage +3 / swordplay +5 |

3. **Step ② free points 自由点数** — attributes **+5 total**, skills
   **+3 total**, **single-item cap +3**, **must spend all** before confirm
   (steppers per `80-*`; skills allocate here **only** — never after
   creation, §4.4). The **spread evenly 平均分配** shortcut spends
   attributes +1 each and the first three skills (seamanship, navigation,
   swordplay) +1 each. A live derived preview (sighting radius, speed
   factor, duel value) recomputes from the same formulas as the steppers
   move.
4. **Creation extremes (normative):** any attribute ≤ **21** and any skill
   ≤ **13** at creation — the closed forms `10 + 5 (nation) + 3
   (background) + 3 (cap) = 21` and `0 + 5 + 5 + 3 = 13`; creation cannot
   break §4.2/§4.3.
5. Confirm → `GameState.new_game(nation_id, background_id, attr_alloc,
   skill_alloc)`:

```
day = 1
gold = Nation.start_gold
player = { nation_id, background_id,
           attributes: base 10 each + nation attr bonus (§4.2.2)
                       + background attr +3 + attr_alloc (≤ +3/item),
           skills:     0 each + nation signature skill +5
                       + background skill +5 + skill_alloc (≤ +3/item),
           skill_counters: all 0, alloc_pending: 0,
           xp: 0, level: 1, autopilot: absent,
           officers: [], equipment: {weapon: "", armor: ""},
           reputation: { own: Nation.start_reputation, others: 0 } }
fleet = [ new instance of Nation.start_ship_type_id (40-* §4.3 "Buy ship"
          instance defaults, but crew = ShipType.crew_min ) ]
world.position = Nation.start_port_id's harbor-pair berth tile (current_port set,
                 so the game opens on the port screen, not at sea)
known_ports = the 6 capital ports (20-* §4.11)
```

6. Route to `port_screen.tscn` for the start port. `background_id`
   persists in the save v9 player block (§4.8) and feeds the retirement
   bio line (`70-*` retirement segment).

### 4.2 Person attributes & nation bonus

Five attributes, 1–100, base 10 at new game (§4.1). Every attribute drives
≥ 3 formulas; all consumers listed here are normative, and the system docs
that host the pipelines own the surrounding mechanics.

#### 4.2.1 Attribute consumers (all formulas normative)

| Attribute | Consumers (Phase 8) |
|---|---|
| 体魄 constitution CON | scurvy game-over threshold **`7 + floor(CON/10)`** (was fixed 7; `20-*` §4.9). Ramming self-damage × `(1−(CON−10)/200)` (`60-*`). Storm-day morale decay × `(1−(CON−10)/300)` — multiplies the `20-*` §4.8.1 storm row. When the surgeon post is filled, the surgeon's **medicine** skill replaces CON as the scurvy-grace source: same formula, base 7 (§4.3.2) |
| 悟性 intellect INT | training fee × `(1−(INT−10)/200)` (§4.3.4); rumour accuracy / hint-quality tiers (INT-modified; `30-*`/`60-*` hail); chart reveal precision bonus (`20-*` §4.12) |
| 魅力 charisma CHA | desertion/mutiny × `(1−(CHA−10)/200)` — **takes over every leadership site; formula unchanged** (`20-*` §4.8.2/§4.8.3); loyalty gain multiplier `1 + floor((CHA−10)/45)` (§4.5.4); **charisma price multiplier** `price_mult = clamp(1 − (CHA−10)/200, 0.5, 1.0)` applied to the officer signing fee (§4.5.2), rumour purchase prices and the bounty-board pinpoint reveal (`70-*` §4.5 — the base prices live there, this doc owns the multiplier); wage talks otherwise enter via the §4.5.4 raise event |
| 胆识 courage COU | duel attack `+floor(COU/20)` (`60-*`); storm speed retention × `(1−(COU−10)/400)` (`20-*` §4.4/§4.7); boarding-victory morale bonus **+5** (`60-*`) |
| 运气 luck LUCK | storm chance × `(1−luck/400)` (unchanged, `20-*` §4.7); storm damage × `(1−luck/250)` — **player-only, continuous** (the Phase-1 `luck ≥ 50 → ×0.75` step is **deleted**; `20-*` §4.7); named-drop rolls (`60-*` battle rewards) |

#### 4.2.2 Nation bonus (creation-time, `data/nations.json`)

Each nation grants **+5 to one attribute and +5 to one signature skill**;
both are baked into the stored player values at creation (§4.1) and are
not re-applied later:

| Nation | attribute +5 | skill +5 |
|---|---|---|
| portugal 葡萄牙 | intellect 悟性 | navigation 航海 |
| spain 西班牙 | courage 胆识 | swordplay 剑术 |
| england 英格兰 | charisma 魅力 | gunnery 炮术 |
| holland 荷兰 | luck 运气 | negotiation 交涉 |
| ottoman 奥斯曼 | courage 胆识 | seamanship 操船 |
| italy 意大利 | luck 运气 | appraisal 鉴定 |

#### 4.2.3 Formula migration (old → new, Phase 8)

| Old | New | Regression owner |
|---|---|---|
| leadership → desertion/mutiny | charisma, formula unchanged | `20-*` sampling re-run (the morale/mutiny acceptance sampling, `20-*` §4.8.1 note 3) |
| speed `(S−10)/100` clamp `[−0.10, +0.20]` | seamanship skill `/300`, clamp `[0, +0.30]` | `sim_trade.py` gates 1–10 re-run; on failure the cap falls back to **+0.25** and both docs amend same-wave (W7-A) |
| sighting `48 + floor((nav−10)/10)` | `48 + floor(navigation skill /12)` | closes the Phase-6 unswept item (`20-*` §4.11) |
| duel `combat + equip + rand(0,20)` | `swordplay + floor(courage/20) + equip + rand(0,20)`; defender `+floor(charisma/20)` | duel RNG re-baseline (`60-*`) |
| NPC duel/cannon `5 + tier` | captain card: duel `swordplay + floor(courage/20)`; cannon `+floor(gunnery/25)`; player escorts use their appointed captain the same way, computed once at composition | `60-*` (`battle_sim.gd`) |
| NPC surrender fixed < 25% | `25% − floor(courage/10)%`, clamp `[10%, 40%]` | `60-*` §4.7 amend |
| storm damage `luck ≥ 50 → ×0.75` | `×(1−luck/250)`, continuous, player-only | demo-loop storm gate re-verified |
| loot/XP fixed | negotiation/appraisal modify cargo valuation; battle XP × `(1+level/20)` | battle-rewards tests (`60-*`) |

### 4.3 Skills & growth

Two skill families in one 0–100 scale, all starting at 0 for the player:

- **Player skills (8):** seamanship 操船, navigation 航海, swordplay 剑术,
  gunnery 炮术, appraisal 鉴定, negotiation 交涉, cartography 制图,
  rumour 打探.
- **Officer skills (3, officers only):** medicine 医术, carpentry 修造,
  cooking 烹饪.

Skills **never** come from level allocation (§4.4) — only from usage
growth (counters), paid training (§4.3.4), and the creation bonuses
(§4.1). Every counter and threshold below is a contract pin.

#### 4.3.1 Player skills — usage growth / magnitude / gates

| Skill | Growth (+1 per N uses) | Magnitude | Gates (threshold) |
|---|---|---|---|
| 操船 seamanship | 30 sea-days; +1 storm survival (immediate, same counter stream) | fleet speed bonus `skill/300`, clamp `[0, +0.30]` (`20-*` §4.4) | ≥ 60 foul-weather sail repair |
| 航海 navigation | 30 sea-days | port sighting radius `48 + floor(skill/12)` (`20-*` §4.11) | ≥ 40 no night-sail extra slow |
| 剑术 swordplay | every duel round | duel attack value (§4.2.3 migration row; `60-*`) | ≥ 30 / ≥ 60 duel-ladder (tournament) ranks |
| 炮术 gunnery | per 10 cannon shots | hit/damage `+floor(skill/25)` | ≥ 25 chain shot / ≥ 50 armor-piercing shot |
| 鉴定 appraisal | per 20 profitable trades | price-memory entries `floor(skill/10)` | ≥ 30 profit arrows; ≥ 60 other-port memory (`30-*`) |
| 交涉 negotiation | per 15 trades; permit purchase +2 | tariff `−floor(skill/10)%`, cap −5% (`30-*`) | ≥ 40 home permit at 95% price; ≥ 70 foreign permit at 90% price |
| 制图 cartography | per 5 Explores | discovery radius `36 + floor(skill/15)`; chart reveal `+1 + floor(skill/25)` | ≥ 30 reef annotations (`70-*`) |
| 打探 rumour | per 10 rumour buys / bounty views | rumour accuracy tiers (INT-modified, §4.2.1) | ≥ 40 bounty pinpoint at half price (`70-*`) |

#### 4.3.2 Officer skills

| Skill | Growth | Magnitude | Gates |
|---|---|---|---|
| 医术 medicine | +1 per 90 in-post sea-days (surgeon post) | scurvy grace: threshold `7 + floor(medicine/10)` — **same formula as the CON row, base 7**; the surgeon in post supplies the source, else the player's own CON applies (§4.2.1) | surgeon post prereq ≥ 20 |
| 修造 carpentry | +1 per 90 in-post sea-days (carpenter post) | repair fee `−floor(skill/20)%` | ≥ 60 at-sea minor repair; post prereq ≥ 20 (`40-*`) |
| 烹饪 cooking | +1 per 90 in-post sea-days (cook post) | morale daily decay `−floor(skill/25)` (subtracted from the `20-*` §4.8.1 rows) | post prereq ≥ 20 |

Officer growth clock: the officer's `sea_days` counter advances +1 per sea
ledger day while employed (any employment, post or bench); each **90**
accrued → +1 to **the post's skill** if in post, else to the **native
main skill** (idle bench); the per-award counter resets on award and
stops counting at 100.

#### 4.3.3 Usage counters (save `skill_counters`)

Each player skill owns one usage counter (saved, §4.8). The counter
advances by the §4.3.1 "uses" definition; on award: skill +1, counter
reset to 0. Counters **stop counting at skill 100** (the skill is maxed;
further use accrues nothing). Storm-survival seamanship (+1) bypasses the
counter (immediate award, counter untouched).

#### 4.3.4 Paid training 付费训练

- Fee for one +1: `ceil(level × 60 × (1 − (INT−10)/200))` gold — the
  player's level and the player's INT, identical whether the target is
  the player's own skill (player card) or an officer's skill (officer
  card `train` action, one of the officer 4 actions, `80-*`); charged
  from player gold.
- **Training cap 60**: a skill at ≥ 60 cannot be trained (reason shown
  from `skill_gates`-style strings, `80-*`); usage growth can still pass
  60.
- No facility network — the train verb lives on the cards only
  (decision 18: manual skill-training facility networks are out of
  scope).

#### 4.3.5 Skill gates (`data/skill_gates.json`, by reference)

Every §4.3.1/§4.3.2 gate and the appointed-voyage gate (`sail.autopilot`,
`20-*`) is a data row `{feature_id, stat_or_skill, threshold,
reason{zh,en}}`; one UI renderer shows locked reasons everywhere (`80-*`).
This doc pins **thresholds**, not reasons — reasons live in the JSON and
are never enumerated in code or docs.

### 4.4 XP, levels & allocation

- **XP sources unchanged from Phase 1:**
  - +2 per day tick at sea (ledger day at sea only, not in-port day
    advances).
  - +1 per 100g of sale profit (floor) on each sell transaction. Locked
    simplification unchanged: no cost-basis tracking; per-unit profit is
    `max(0, sell_price − floor(base_price × 0.7))` (the 0.7 = the resting
    `produces` factor, `30-*` §4.2), transaction profit is `qty × per-unit`,
    `xp += floor(profit / 100)`; a loss-making sale adds 0 XP and never
    removes XP; with Phase-5 stock prices the `floor(base_price × 0.7)`
    basis deliberately stays fixed (locked metagame approximation).
- **Battle multiplier:** every **battle** XP award scales
  × `(1 + level/20)`; the multiplier is owned by battle rewards (`60-*`),
  not by the trade/sea-day paths above.
- **Level rule unchanged:** `level = floor(sqrt(xp / 50)) + 1`, recomputed
  lazily; cap 20 (`80-*` §level table; `xp` keeps accruing past the cap,
  `level` clamps at 20 and no further `alloc_pending` is granted).
- **On each level-up:** `alloc_pending += 2` (the Phase-1 auto-grant of
  +1 seamanship / +1 nation stat is **deleted**). `alloc_pending` is a
  persisted player-block counter (§4.8); the `pending_levelup` toast flag
  stays a session-transient class static and is **not saved** (correction
  12).
- **Allocation** happens on the player's own card (attribute tab): toast +
  badge on the character button, then per-attribute `+` steppers (enabled
  iff `alloc_pending > 0`), draft → confirm / cancel-rollback; each point
  raises one attribute by 1, clamp **[1, 100]** — an attribute at 100
  disables its stepper; points are deferrable forever. Skills never
  allocate (§4.3).

### 4.5 Officers — roster, posts, loyalty, contribution

#### 4.5.1 Roster v2 (96 = 24 + 72)

- `data/officers.json` **v2 is a built artifact** of
  `tools/build_captains.py` (one tool, one name-part/seed/override family
  with `captains.json`); two consecutive builds are **byte-identical**.
  Never hand-edit the built file — the sources are
  `data/captain_name_parts.json` + `tools/officer_overrides.json`.
- **24 legends** (hand-authored overrides): main skill **45–60**, wage
  **40–60g/day**; recruit placement is hand-authored `recruit_ports`.
- **72 regulars** (generated from name parts): main skill **25–45**, wage
  **20–35g/day**; each gets a **per-nation home-port band** as its
  recruit placement.
- Appearance/personality tags and zh/en name parts follow the `10-*`
  v2 schema; officer ids are stable and save-safe (`officers[]` stores
  ids, §4.8).

#### 4.5.2 Posts & OFFICER_MAX

- **`OFFICER_MAX = 12`** (was 3) = 6 flagship functional posts + up to
  **4** captain posts (`FLEET_MAX − 1 = 4` escorts, `40-*`) + **2 idle
  bench**, so the capture/buy-ship gate "≥ 1 idle officer" (`40-*`,
  `60-*`) stays reachable when fully staffed; a capture with no idle
  officer auto-converts the ship to loot + scuttle instead.
- **Posts** (`data/officer_posts.json`): the 6 flagship posts
  pilot 领航员 / boatswain 水手长 / gunner 炮手 / surgeon 船医 /
  carpenter 修造师 / cook 厨师, prereq = matching skill **≥ 20**; plus
  **1 captain post per escort ship**, prereq = seamanship **≥ 25 ∧
  courage ≥ 30**. One person per post; native role fixes the signature
  skill, initial skill distribution, recruit text and personality pool —
  it never restricts appointment.
- **Post → pipeline** (the derived-effects display is generated from this
  same table):

| Post | In-post skill → pipeline | Derived effect |
|---|---|---|
| pilot | navigation → sighting | `48 + floor(skill/12)`; ≥ 40 night-sail exemption |
| boatswain | seamanship → fleet speed | `+skill/300` (cap +0.30) |
| gunner | gunnery → hit/damage | `+floor(skill/25)`; ≥ 25/≥ 50 chain/AP shot |
| surgeon | medicine → scurvy grace | `7 + floor(skill/10)` (§4.2.1 CON row, base 7) |
| carpenter | carpentry → repairs | fee `−floor(skill/20)%`; ≥ 60 at-sea minor repair |
| cook | cooking → morale | daily decay `−floor(skill/25)` |
| captain (per ship) | seamanship/gunnery/swordplay+courage → that ship | ship speed, ship cannon, `combat_rating = swordplay + floor(courage/20)` |

- **Captain-less ship:** speed × **0.8**, morale decay **+2 extra/day**,
  cannon rating **0** (`40-*`/`20-*` hooks).
- **Sunk/sold ship → its captain returns idle, loyalty −10** (flat; see
  §6 note on the backlog's unpinned "personality-scaled" qualifier).
- Daily wage: `Σ officer.wage_daily` in the ledger (`20-*` §4.5 step 2,
  unchanged). Signing cost: `ceil(wage_daily × 10 × price_mult)` paid once,
  with `price_mult = clamp(1 − (CHA−10)/200, 0.5, 1.0)` (the §4.2 charisma
  price multiplier; CHA 10 → ×1.0, CHA 60 → ×0.75, CHA 100 → ×0.55 — the
  straight line 1 − 90/200; the formula's own clamp bottoms out at ×0.5);
  wage talks otherwise enter via the §4.5.4 raise event.

#### 4.5.3 Contribution (replaces ROLE_STAT_BONUS)

- `effective skill = player skill + the ONE in-post officer's true value`
  per post — one person per post, **no stacking**; the Phase-1 flat
  `ROLE_STAT_BONUS` (+10 per role, stacking) is **deleted**.
- **Loyalty derate:** loyalty < 30 → that officer's contribution
  × 0.8, floored: `floor(true_value × 0.8)`.
- **Signature bonus:** loyalty ≥ 80 → the officer's **native signature
  skill** contributes +5 (§4.5.4).
- True skill feeds the pipeline; there is no cross-post multiplier.

#### 4.5.4 Loyalty 忠诚

0–100, starts **50** at hire. Every **positive** delta is multiplied by
the charisma gain multiplier `1 + floor((CHA−10)/45)` (player charisma;
at CHA 10 ×1, at CHA 100 ×3); negative deltas are flat.

| Event | Effect |
|---|---|
| Talk 交谈 | loyalty +1, **10-day cooldown** (`talk_cd_day`) |
| Gift 送礼 200g | loyalty +5; greedy 贪婪 personality +8, honest 诚实 +3; **10-day cooldown** (`gift_cd_day`) |
| Loyalty < 30 | in-post contribution × 0.8 (§4.5.3) **+ raise-demand event**: accept → wage × **1.25** permanent, loyalty **+10**; refuse → loyalty **−10** |
| Loyalty < 15 | resigns 辞职 — leaves the roster, post freed; state entry cleared (a re-hire starts fresh at 50) |
| Loyalty ≥ 80 | native signature skill **+5** (§4.5.3) |

#### 4.5.5 Recruit / dismiss / resign

- Source: the v2 roster. An officer appears in a port's tavern (officers
  tab, `30-*`) iff this port ∈ the officer's recruit placement
  (legends: hand `recruit_ports`; regulars: the per-nation home-port
  band) and the officer is not employed.
- **Recruit:** added to `player.officers` (loyalty 50, state entry
  created); signing cost `wage_daily × 10`; the 13th recruit is refused
  (`OFFICER_MAX = 12`, §4.5.2).
- **Dismiss** (no severance, player action from the officer row):
  employment ends, post freed, officer returns to the recruit pool;
  state entry cleared.
- **Resign** is the §4.5.4 loyalty < 15 path (same roster/pool effects,
  automatic).
- An employed officer never appears in any tavern list (persistence via
  §4.8 + `officer_states`, `90-*` §8).

### 4.6 Reputation

- Per nation, integer −100…+100, stored in `player.reputation`.
- Phase-1 sources: +1 per 1,000g **cumulative** profit sold at a nation's
  ports. No decay.
- **Phase-3 sources** (`70-*` §4.2/§4.3/§4.5): quest rewards
  (`rewards.reputation`), royal missions (+10), piracy (−20 with the
  victim, +2 with each of its two `rivals`), piracy bounties (rep reset
  to exactly −10 on clearing), and quest failure (−5, or −10 for a royal
  mission). Every delta funnels through `add_reputation()` so the clamp
  is applied once.
- **Cumulative accounting (normative).** The 1,000g threshold carries
  across transactions — 600g then 400g at the same nation grants the
  point neither sale earns alone. Two `player`-block fields track it:
  `profit_by_nation` (`{nation_id: lifetime sale profit}`) and
  `profit_rep_awarded` (`{nation_id: reputation points already paid
  out}`). Only the difference between `floor(profit_by_nation / 1000)`
  and `profit_rep_awarded` is granted through `add_reputation()`, so the
  reputation clamp and points from other sources are unaffected. Both
  fields are persisted (§4.8) because the accumulator must survive
  save/load; a save predating the first sale simply omits them, which
  reads as all-zero. `character.gd#add_profit_reputation()` owns the
  rule; the market only supplies the transaction's profit. This model is
  idempotent — replaying a sale cannot double-award, because the paid-out
  counter is stored.
- Effects: display on the character panel; **Phase 3 activates** trade
  refusal, titles gating retirement and sell-price boosts (`70-*`
  §4.9.2), and the reputation ≤ −50 bounty that closes that nation's
  ports (`70-*` §4.9.5/§4.9.6). Unchanged by Phase 8.

### 4.7 Harbor relief (full flow; spec constants in `10-*` §5)

1. Condition evaluated whenever `inn_screen` opens and after each odd
   job: `fleet.is_empty() && officer_count() == 0 && gold < 1200` — the
   threshold is the cheapest hull price (`latin`, `10-*` §7.3), not 100;
   gating on `gold < 100` while paying `+100` would close the gate after
   one job and make the 1,200g hull unreachable (`10-*` §5 "Why the
   threshold is 1,200").
2. If eligible: "Work an odd job" enabled; each click: `gold += 100`,
   advance one ledger day (`20-*` §4.5 — with no fleet there is no
   consumption; wages: no crew, no officers → 0 cost; morale delta +5/day
   applies but morale is moot without crew).
3. If ineligible: button disabled with a specific reason label — key
   `inn.odd_job.ineligible` plus one of `inn.odd_job.has_ship`,
   `inn.odd_job.not_broke` (gold ≥ 1,200), `inn.odd_job.officers`.
4. There is no GUI path to sell your last ship (`40-*` §6), so this state
   is reached only after sinking-without-escort game over — which ends
   the run — OR by starting shipless, which never happens. **Locked
   clarification:** harbor relief exists to satisfy the anti-softlock
   rule (a Phase-8 capture can still leave the player with no ship only
   via sinking game-over; captured ships convert to loot + scuttle when
   no idle officer exists, `60-*`). In normal play it is implemented and
   tested via the debug hook (`GameState.debug_strip_fleet()`). This is
   intentional and documented to avoid implementing a fake path.

### 4.8 Save block shape (`player`, save v9)

`SAVE_VERSION = 9`, `PHASE = 9`; **v8 refused wholesale — no migration,
no `player.stats` carry-over** (`90-*` §8.2). Shape:

```json
{
  "nation_id": "portugal",
  "background_id": "background_deckhand",
  "attributes": {"constitution": 16, "intellect": 17, "charisma": 10, "courage": 10, "luck": 10},
  "skills": {"seamanship": 8, "navigation": 5, "swordplay": 0, "gunnery": 0,
             "appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0},
  "skill_counters": {"seamanship": 12, "navigation": 5, "swordplay": 0, "gunnery": 0,
                     "appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0},
  "alloc_pending": 4,
  "xp": 137,
  "level": 2,
  "autopilot": {"dest_port_id": "madeira"},
  "officers": ["off_mateus_alvares"],
  "reputation": {"portugal": 20, "spain": 0, "england": 0, "holland": 0, "ottoman": 0, "italy": 0},
  "profit_by_nation": {"england": 1100},
  "profit_rep_awarded": {"england": 1},
  "equipment": {"weapon": "eq_cutlass", "armor": ""}
}
```

- `attributes` (5 keys) and `skills` (8 keys) store the player's **own**
  values; officer contribution is computed at read time (§4.5.3), never
  stored here.
- `skill_counters` are the §4.3.3 usage counters (8 keys, reset on award,
  stop counting at 100).
- `alloc_pending` is persisted (§4.4); `pending_levelup` is a class
  static and absent from the payload.
- `autopilot` is `{"dest_port_id": ...}` while an appointed voyage is
  active, **absent** otherwise (gates/interrupts owned by `20-*`
  appointed-voyage section; the top-level wiring is `90-*` §8).
- `officers` stores ids (full records live in `data/officers.json` v2).
- `level` is stored but re-derived from `xp` on load (stored value is a
  cache; derivation wins on mismatch, logged).
- `profit_by_nation` / `profit_rep_awarded` are the §4.6
  cumulative-profit accumulator, written by
  `character.gd#add_profit_reputation()` on every profitable sale;
  absent keys read as zero.
- `equipment` is the player-worn block (`60-*` §4.11.12): `weapon` and
  `armor` hold equipment ids or `""`.
- **Removed: `player.stats`** (the leadership/seamanship/combat/
  navigation block) — no migration; any v8 payload is refused.
- `officer_states` and `captain_states` are **top-level save blocks**, not
  inside `player` — shapes normative in `90-*` §8 (officer entries:
  `{loyalty, sea_days, post_id, ship_id, talk_cd_day, gift_cd_day,
  defeats}` plus the optional `wage_mult` (default `1.0`) and
  `skill_deltas` keys, `90-*` §8); `post_id = ""` = idle; `ship_id`
  non-empty only for captain posts).

## 5. Data Examples

**Worked Person example** — Portugal start + `background_deckhand` + full
alloc (`attr_alloc`: constitution +3, intellect +2; `skill_alloc`:
seamanship +3), with a pilot (navigation 45, loyalty 60) and a boatswain
(seamanship 52, loyalty 50) appointed:

```json
{
  "setup": "new_game('portugal', 'background_deckhand', {constitution: +3, intellect: +2}, {seamanship: +3})",
  "arithmetic": "base 10 + portugal INT+5/NAV+5 + deckhand CON+3/SEA+5 + free points",
  "person": {
    "attributes": {"constitution": 16, "intellect": 17, "charisma": 10, "courage": 10, "luck": 10},
    "skills": {"seamanship": 8, "navigation": 5, "swordplay": 0, "gunnery": 0,
               "appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0}
  },
  "effective": {
    "navigation_skill": "5 + 45 = 50",
    "sighting_radius": "48 + floor(50/12) = 52 tiles",
    "seamanship_skill": "8 + 52 = 60",
    "speed_bonus": "60/300 = +0.200 (clamp [0, +0.30])",
    "scurvy_threshold": "7 + floor(16/10) = 8 short days (no surgeon; a surgeon with medicine 45 gives 7 + 4 = 11)",
    "training_fee": "ceil(level 1 × 60 × (1 − (17−10)/200)) = ceil(57.9) = 58g per +1",
    "loyalty_gift": "200g → +5 × (1 + floor((10−10)/45)) = +5"
  }
}
```

**Level table** (unchanged; `level = floor(sqrt(xp/50)) + 1`, cap 20):

```json
{"xp": 0, "level": 1, "next_at": 50,
 "table": "50→L2; 200→L3; 450→L4; 800→L5; 1250→L6; cap L20 at 18050 xp",
 "alloc_pending": "+2 per level reached; 19 level-ups to L20 = 38 points if never spent"}
```

**`officer_states` entry** (top-level save block; `90-*` §8) — Mateus
Álvares as an in-post pilot, 93 sea-days served (one +1 navigation growth
awarded at day 90):

```json
"officer_states": {
  "off_mateus_alvares": {"loyalty": 55, "sea_days": 93, "post_id": "pilot",
                          "ship_id": "", "talk_cd_day": 12, "gift_cd_day": 0, "defeats": 0}
}
```

## 6. Edge Cases & Fail States

- **Recruit with gold < signing cost** → button disabled with price shown.
- **13th officer recruit attempt** → roster full; button disabled
  (`char.officers_full`, `OFFICER_MAX = 12`).
- **Second appointee for an occupied post** → refused: one person per
  post, no stacking (§4.5.3); prereq-gray + reason in the UI (`80-*`).
- **Prereq unmet** → post column grayed with the reason; appointment
  disabled (flagship skill ≥ 20; captain seamanship ≥ 25 ∧ courage ≥ 30).
- **Captain resigned/dismissed mid-voyage** → that ship immediately runs
  the captain-less penalties (speed ×0.8, morale decay +2/day, cannon
  rating 0) until a new captain is appointed.
- **Sunk/sold escort** → captain returns idle, loyalty −10 (§4.5.2).
  Backlog note: the source backlog's "(personality-scaled)" qualifier for
  this delta has no locked numbers — flat −10 is the W1 pin (flagged to
  master; amend here first if personality scaling is ratified).
- **Attribute at 100** → allocation stepper disabled for that attribute;
  leftover `alloc_pending` stays pending. Attribute/skill writes clamp to
  [1, 100] / [0, 100] everywhere.
- **Training a skill ≥ 60** → refused with reason (§4.3.4); usage growth
  past 60 still works.
- **Skill at 100** → its counter stops counting (§4.3.3).
- **Level computed on load disagreement** → xp wins (§4.8).
- **XP from a loss-making sale** → profit term floors at 0; sales never
  remove XP.
- **Reputation display before any trade** → all-zero except own nation;
  no Nation rows hidden.
- **Harbor relief with officers employed** → officer wages still run in
  the ledger; if that drains gold below 0 the wage rule (`20-*` §4.5)
  applies. Locked: odd jobs are disabled while officers are employed
  (dismiss first); reason shown in the disabled label.
- **`alloc_pending` > 0 at save** → round-trips exactly (§4.8); the
  toast/badge state does not.

## 7. Acceptance Criteria

- [ ] Nationality select renders exactly 6 cards from `nations.json`; no
      scene hardcoding (test: edit a start_gold value → card reflects it).
- [ ] Two-step creation: `GameState.new_game(nation_id, background_id,
      attr_alloc, skill_alloc)` initializes exactly the §4.1 block;
      must-spend-all enforced; the spread-evenly shortcut yields
      attributes +1 each and seamanship/navigation/swordplay +1 each;
      creation extremes hold (attribute ≤ 21, skill ≤ 13 — max-alloc
      build hits both caps exactly); `background_id` round-trips.
- [ ] Attribute consumers (§4.2.1) pinned at boundaries 10 / 20 / 100:
      e.g. scurvy threshold `7 + floor(CON/10)` = 8 @ CON 10 and 17 @ CON
      100; desertion/mutiny × 1.0 @ CHA 10 (charisma formula identical to
      the old leadership formula); storm damage ×(1−luck/250) is
      continuous (no ≥ 50 step).
- [ ] Growth counters: seamanship +1 at 30 sea-days and on storm
      survival; navigation +1 at 30 sea-days; counters reset on award and
      stop counting at skill 100 (`skill_counters` round-trips).
- [ ] Paid training: fee = `ceil(level × 60 × (1 − (INT−10)/200))`
      (INT 10 → `level × 60`; INT 100 → `ceil(level × 60 × 0.55)`);
      training refused at skill ≥ 60.
- [ ] Officer contribution: effective skill = player + the one in-post
      officer's true value; a second officer for an occupied post is
      refused; loyalty < 30 → `floor(true × 0.8)`; loyalty ≥ 80 → native
      signature +5; `ROLE_STAT_BONUS` is gone (no flat role bonuses
      anywhere).
- [ ] Allocation: each level-up adds exactly +2 `alloc_pending` (levels
      capped at 20 grant no more); steppers decrement pending, clamp at
      attribute 100; cancel rolls back; `alloc_pending` round-trips
      save/load while `pending_levelup` does not exist in the payload.
- [ ] `OFFICER_MAX = 12` gate: 12 recruits fit (6 flagship + 4 captains +
      2 bench); the 13th is refused; capture with 0 idle officers
      converts to loot + scuttle (`60-*` asserts the outcome).
- [ ] Loyalty events: talk +1 then 10-day cooldown; gift 200g → +5
      (greedy +8 / honest +3) with cooldown; gain multiplier
      `1 + floor((CHA−10)/45)` (CHA 10 → ×1, CHA 100 → ×3); < 30 derate +
      raise event (accept: wage ×1.25 + loyalty +10; refuse: −10); < 15
      resigns and frees the post; ≥ 80 signature +5.
- [ ] Level formula and XP sources match §4.4 for xp ∈ {0, 49, 50, 200,
      18050}; loss-making sales add 0 XP; battle awards scale
      ×(1 + level/20) (asserted from battle rewards, `60-*`).
- [ ] Reputation increments on profitable sales at the correct nation's
      ports only, with the 1,000g threshold accumulating across
      transactions; every Phase-3 reputation source in §4.6 is applied
      through `Character.add_reputation()` and clamped once.
- [ ] Harbor-relief button state machine matches §4.7/§6 rules including
      the officers-employed lockout.
- [ ] Save v9: `player` block matches §4.8 exactly (no `stats` key);
      `officer_states` / `captain_states` are top-level; a v8 payload is
      refused (`test_save_v9`).
