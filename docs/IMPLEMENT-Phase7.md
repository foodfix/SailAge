# IMPLEMENT — Phase 7: Trade Empires

**Status (2026-11-01):** **backlog ratified** — A0 (this file) landed; W1
(docs) may launch. W2+ requires the Phase-6 final gate, verified below.
**History:** source plan `.kilo/plans/1793457374158-phase7-trade-empires-plan.md`
(product-owner decisions 1–26, interviews 2026-10-31 / 2026-11-01); the
"Review corrections" table records every divergence from that plan,
verified against the repo on 2026-11-01.
**Prerequisite (verified 2026-11-01):** Phase 6 is **fully complete** —
final gate green on `main` (`tools/demo_check_phase6.md`: validator groups
1–10 exit 0, all three rebuilds byte-identical, **37 suites / 6 538
checks**, `godot --headless --quit-after 3` clean, day tick 19.2–20 ms avg /
28–29 ms worst @ 288 fleets, pursuit A* 61 ms worst, save 1.19 MB @
extreme, 501 ui_strings keys zh/en parity). Everything this phase builds
on — the 145 ports (100 sovereign + **45** `nation_id: ""` neutral), the 17
locked lanes (5 regional), the month calendar (30-day months,
`sailing_sim.gd`), save v6 — has landed.

---

## Goal

Make ports *matter* — Phase 6 gave the monsoon world destinations and
pinned them inert (player-only markets, no NPC fleet, every port listing
every one of 20 goods, 8 ships and 8 stat-stick equipment sold everywhere).
Phase 7 delivers, in one phase:

1. **A flow economy** (decision 17): real daily production/consumption
   replace the Phase-5 drift-to-rest; producers fill toward capacity,
   consumers drain; every listed port-good is produced or consumed.
2. **Goods 20 → 40** with `staple`/`specialty`/`exclusive` flags and a
   per-port listing rule — knowing *where* a specialty exists is the trade
   (pillar 2).
3. **Ships 8 → 16** with a `role` field, per-port shipyard stock lists,
   and **equipment 8 → 24** with rare drop-only items.
4. **Development-gated hardware** (decision 23): `tier ≤ effective_dev`
   at both port kinds, grayed 需发展度 rows.
5. **A living allegiance tug-of-war** (decisions 15/25/26): protected vs
   contestable port classes, per-nation investment ledgers, monthly seeded
   NPC counter-investment from treasuries, tavern telegraphs, and flipping
   paced as a campaign (monthly cap, home advantage, diplomatic gate,
   poaching rep).
6. **A unified tariff + permits** (decisions 19/20): 5% in-sphere / 20%
   foreign for player and NPC alike, two permit kinds, taxes funding the
   allegiance nation's treasury (pillar 1: the sea has a cost).
7. **A measured economy** (decisions 14/22): `tools/sim_trade.py` with ten
   pinned gates guards the data lock.

---

## Review corrections applied to the source plan

Every correction below was verified against the repo on 2026-11-01. The
plan text below (locked constants, tasks, waves) already reflects the
corrected values; this table is the record.

| # | Source-plan claim | Verified fact | Fix applied |
|---|---|---|---|
| 1 | "`port_development` save key is deleted" (§3.8, decisions 15→25) | `port_development` has **never existed** (`game_state.gd`, `save_system.gd:106-115` STATE_KEYS, repo-wide grep clean) — decision 25 killed it inside the planning stage. Dev levels are introduced for the first time | reworded as a non-change; §2.4 introduces dev from scratch; B also fixes `30-*` §4.3's stale line ("development rewards remain a Phase-6 candidate" — it became Phase 7) |
| 2 | Day-tick budget "≤ 50 ms" (§3.7, task N) | The pin was **re-pinned 50 → 75 ms** by the unified-movement amendment (`60-*` §4.11.11.5; Phase-6 gate measured 19.2–29 ms @ 288) | task N re-probes **≤ 75 ms** day tick and ≤ 250 ms pursuit A* at the added spawn count |
| 3 | "Every port demands every staple" (decision 17) **and** "produces/demands disjoint per port" (§3.1) | Directly contradictory for every port that produces a staple (e.g. lisbon produces `salt`, a staple) | per-port rule pinned as **`demands ⊇ (staples ∖ port.produces)`**; validator asserts `staples ⊆ produces ∪ demands` and `produces ∩ demands = ∅` |
| 4 | Telegraph and coverage rules keyed on "region band" (decisions 21/24) | Bands exist **only as prose** (IMPLEMENT-Phase6 §2.11, `10-*` §7.1 tail, `LICENSE-NOTES.md`); `ports.json` fields are exactly `demands, facilities, flavor, id, lat, lon, name, nation_id, produces` | new **`band: <band_id>`** field on **all 145 ports** (three consumers: staple-coverage validator checks, exclusive-per-neutral-band check, tavern telegraph scoping); band id set authored by P, locked in `10-*` (A) |
| 5 | Allegiance = `30-*` new §4.6, tax = new §4.7 | `30-*` §4.6 is **Tavern crew hire/fire**, §4.7 is **Inn**, §4.8 is UI flows | allegiance/development → new **§4.9**, tax & permits → new **§4.10**; flow economy amends §4.2; listing rule amends §4.4/§4.8. M also fixes the stale `trade_engine.gd:437` "docs/30 §4.7" comment |
| 6 | "All 140–160 ports' `produces`/`demands` rewritten" | Exactly **145** ports (100 sovereign + 45 neutral; validator neutral tier 40–60 at L515-518) | 145 pinned everywhere (P's checklist, validator counts, §2.9 gates) |
| 7 | §3.1's listing rule reads as a data-only change | Today `TradeEngine.goods_rows()` (`scripts/port/trade_engine.gd:438-448`) returns **all 20 goods at every port** — the listing filter is a real engine + market-screen behavior change; unlisted goods vanish from rows | flagged as behavioral change; L owns the engine filter, M the screen; `test_trade` re-baselined in W3 (risk row: market-row shock) |
| 8 | Save key `port_allegiance {port_id: {ledger, development, allegiance}}` | `development` is derivable (`max(authored floor, ledger thresholds)`) — persisting it invites desync between ledger and dev | persist **`{ledger, allegiance}`** only; dev is derived on load; `allegiance` stays persisted because the tie rule is "keep the incumbent" |
| 9 | T (W2) owns "validator amendments", implicating the demand-event data shape | `market_events.json` `shifts` → consumption-rate surge is an atomic **data + code** transition (`economy.gd`'s static `_rest_overrides` table) | T leaves the group-7 event checks **alone** in W2; **K owns the transition in W3** (data + code + group-7 event-shape check, one merge — one writer per file per wave: `validate_data.py` is T in W2, K in W3) |
| 10 | "Deterministic drop table keyed by captain id" (§3.3) | `data/named_pirates.json` (4 entries: `id`, `name`, `tier` only) is the natural home | it gains **`drop: <equipment_id>`**; folded into task S (one W2 worktree carries ships + equipment + pirates); validator group 7 pins the 4 pirate ids and that every `drop` references a `rare: true` equipment item |
| 11 | Neutral ports stock hulls "only under allegiance + dev ≥ 2" (§3.2) | An unallied neutral (dev floor 0) then sells **nothing** — the shipyard must render an allegiance-gated state, not an empty crash; only 4 neutrals carry a shipyard today | shipyard rows gain **three states** (available / tier-gray 需发展度 / allegiance-gray 同盟专营), pinned in §2.2, implemented by F, strings inventoried by C |
| 12 | "P is the single writer of `ports.json`; validator cross-checks refs" | `LOCKED_PORTS` tuples embed **each port's exact `produces`/`demands`** — P's sim-gated economy iteration would re-churn 145 tuples per loop | **lock-model amendment** (A pins, T implements): group 5 keeps identity locks (id/zh/en/nation/lat/lon exact, 145-set exact); economy fields move to structural + graph-shape checks (§2.1, decisions 21/22). Ships/equipment stay exact-set locked (authored-to-final, no sim loop) |
| 13 | W2 tasks are G, S, E, P, T (five) | Execution constraint: **max 4 background subagents** | **S absorbs E** (ships + equipment + named-pirate drops — one worktree). W2 = G, S, P, T |
| 14 | "Held-branch protocol if P lands before T's locks" | Understated: **G, S and P all fail the old exact-set locks** standalone, and T's sim gates need the G/S/P data *before* anything merges | **staged-sim protocol** (new, §waves): T runs `sim_trade.py` against a staging export of the three content branches pre-merge; gates 1–10 iterate **in worktrees**; the master merges **G → S → P → T** and the W2 gate runs **once** |
| 15 | "`coasters_mult_per_port` 0.75 applies to neutral ports" (§3.7) | The budget counts **nation ports only** (`npc_fleets.gd:535-538` skips `nation_id == ""`); reinterpreting it silently would be an unexplained semantic shift | task N adds an explicit data line **`neutral_coasters_mult := 0.75`** in `data/npc_config.json` (data-side lever, group-7 bounds), cap 288 arithmetics re-derived and recorded |
| 16 | — (not mentioned in source plan) | `80-*` §4.7 still claims "current format is version 4 … migrates it forward" — stale since the v5→v6 no-migration ship | C's stale-line sweep gains it (save v7, refused-below-v7 wording) |

---

## Decision record

Carried from the source plan (product-owner decisions 1–26) with the
corrections above folded in:

1. **Full package, one phase.** Economy overhaul + ships + equipment +
   allegiance/tax/permits/专营货/patrol umbrella/fame. Warehouse/consignment,
   contracts board, dividends, intelligence perks → Phase 8.
2. **Realism over convenience.** Shared-hold physics kept (provisions/water
   compete with cargo); the galley is re-rolled as a **warship** (availability
   + framing), not buffed into a trader; no dedicated tanks.
3. **Goods 20 → 40.** Listing rule: a port lists a good iff it produces or
   demands it; staples listed everywhere by the data rule (correction 3);
   tier split 12 staples / 16 middle / 12 luxury.
4. **Ship types 8 → 16** (galiot, galleass, fluyt, junk, dhow, pinnace,
   caravela_redonda, xebec — dated exception ~1690s, one-line note in
   `LICENSE-NOTES.md`). Per-port shipyard stock lists.
5. **Equipment 8 → 24** (6 per slot), per-port stock, 1 rare drop-only
   item per slot from named pirates.
6. **Allegiance** (dev 0–3, per-nation ledgers, monthly seeded NPC
   counter-investment) — as revised by 15 and rewritten by 25.
7. **Tax on both buy and sell** (owner override of a sell-only
   recommendation) — rates revised by 20.
8. **Permits** (免税证) — as revised by 20 (two kinds, below).
9. **Warehouse removed from Phase 7** (by 16).
10. **专营货** absolute allegiance gate at dev ≥ 2; grayed row with lock note.
11. **Fame-only title tie-in** (+100 first flip, +25 per dev threshold,
    one commendation per converted port); the `70-*` title ladder untouched.
12. **Allied ports open to NPC trade** on the regional lanes — generalized
    by 25 to effective alignment == trader's nation, all 17 lanes.
13. **Save v7, no migration** — v6 refused, `SAVE_VERSION = 7`, `PHASE = 7`.
14. **Balance gated by measurement** — `tools/sim_trade.py` gates 1–10
    before the economy data locks.
15. **Unified development model** — largely rewritten by 25.
16. **Warehouse & consignment out** (no 仓库 tab, no consignment logic, no
    warehouse save keys).
17. **Flow economy** — every listed port-good produced or consumed; daily
    tick moves stock by rate × dev multiplier; producing ports never buy
    their own goods; staples ubiquitous by data rule (correction 3);
    demand events re-pinned as consumption-rate surges (×3).
18. **Coastal trade for every neutral port** — nationless coasters (中立灰),
    nearest-port hops regardless of ownership, local only; goods scope
    staples ∪ middle (per 21); never-triggers-contact unchanged.
19. **NPC trade feeds treasuries — tax-only**, no profit-and-loss
    accounting; nationless coasters exempt; NPC-sourced tax capped
    2,000g/nation/month; permit sales flow to the selling nation.
20. **Unified tariff:** effective alignment == trader's nation → **5%**
    buy+sell; else **20%**; unallied contestable 20% forever, no permit
    ever covers it. **本国免税证** (home charter): 5,000g, own palaces, no
    title/rep gate, covers own + aligned ports (5% → 0%). **涉外免税证**
    (foreign permit): 20,000g, that nation's palaces, title ≥ Knight, rep
    ≥ +20, covers that nation's sphere. Both void at bounty or rep < −20;
    re-buy at full price.
21. **Staple access guarantee** — provisions/water stay fixed-price
    everywhere; validator: ≥1 staple producer within **120 tiles** of every
    port, ≥2 within 240, ≥2 per region band; coasters trade staples ∪
    middle (the grain-rotation layer).
22. **Anti-imbalance gates** — greedy-bot ceiling ≤ 80,000g/360d;
    diminishing returns (120-unit run < 2.2 × 60-unit); producer health ≥
    50% capacity average; data-shape: every good ≥2 producers / ≥4
    consumers. Tuning levers stay data-side (`base_price`, `flow`
    overrides, graph shape).
23. **High-tier hardware is development-gated** — `tier: 1|2|3` on ships
    and equipment; `purchasable(port, item) = in_stock ∧ tier ≤
    effective_dev`; above-dev rows grayed 需发展度; rare drops never
    purchasable.
24. **Investment telegraphs** — monthly NPC investments land as tavern
    rumor rows (`{nation} 在 {port} 投资 {amount}g`), 30-day visibility in
    the invested port's **band**; `allegiance.gd` exposes
    `last_month_investments()`. Entity convoys rejected (Phase-8).
25. **Every non-core port is contestable** — **protected** (capital +
    authored home core, ≤4/nation, `protected: true`, no ledger, permanent
    alignment, discount-only investment, dev floor never grows) vs
    **contestable** (everything else; sovereign non-core starts
    `{owner: 6,000}`, neutrals empty; dev = max(authored floor, ledger
    thresholds 10k/25k/50k)). AI spheres may include foreign contestable
    sovereigns. Poaching costs **−5 rep** with the previous owner. Core set:
    portugal {lisbon, oporto}; spain {seville, cadiz, valencia, barcelona};
    england {london, plymouth}; holland {amsterdam, antwerp}; ottoman
    {istanbul, athens, smyrna}; italy {venice, genoa, naples, palermo}.
26. **Flipping is a campaign** — player investment ≤ **2,000g/port/month**
    (`month_invested`, reset at the month tick, button disables with an
    allowance hint); home advantage **× 1.25** (`ledger × 5 / 4`) for the
    sovereign owner in the allegiance comparison; diplomatic gate **rep ≥ 0
    + no bounty** vs the port's current alignment nation. Pacing: empty
    neutral ≥ 3 months; mature foreign sovereign ≥ 4, longer under AI
    contest.

---

## Pre-state (verified 2026-11-01)

- Autoloads: `autoload/{game_state,event_bus,data_loader,i18n,save_system}.gd`;
  `SAVE_VERSION := 6` / `PHASE := 6` at `save_system.gd:71-73`; no
  migration chain, v6 payload keys at `STATE_KEYS` (L106-115).
- Economy: `scripts/port/economy.gd` — drift-to-rest ticks
  (`REST_PRODUCED 160 / REST_DEMANDED 40 / REST_NEUTRAL 100`, tier rates
  ±3/±2/±1/day **derived from `goods.json` order**, L57-64);
  `factor = clamp(1500 − 5 × stock, 500, 2000)`; `STOCK_MAX 200`; demand
  events = static `_rest_overrides` + `data/market_events.json`
  `shifts` (8 templates); `event_telegraphs()` feeds tavern rumors via
  `npc_intel.rumor_rows` (same-nation scope).
- Trade: `scripts/port/trade_engine.gd` — tranche walks ±10 units, 0.8
  sell margin (`SELL_MARGIN_NUM/DEN`), title bonus 1000/1050/1100, band
  [0.5, 2.0]; investment `INVEST_CHUNK 500`, `INVEST_CAP_CHUNKS 10` (10%
  cap) into `GameState.port_investments`; **`goods_rows()` returns all 20
  goods at every port** (L438-448); supplies (provisions 2g / water 1g)
  exempt from all factors; **no tax logic anywhere** (grep `tax|tariff`
  in `scripts/` → zero).
- Palace: `scripts/port/palace_engine.gd` exists — royal missions, title
  ceremony, repair bays, bounty payoff, tournament, retirement. Rep lives
  in `CharacterLib`/`GameState.fame`/titles/bounties.
- Ships/equipment: `data/ship_types.json` 8 entries (no `tier`/`role`);
  `data/equipment.json` 8 (no `tier`/`rare`); shipyard rows and
  `shipyard_engine.equipment_list()` are built from the **global** data
  lists — no per-port stock today; `facilities.shipyard: 1` (int) or
  absent; 41 neutrals have no shipyard.
- Ecology: `scripts/world/npc_fleets.gd` (8 roles) — coaster pins:
  `COASTER_HOLD_CAPACITY 10`, ≤5-unit calls, saturation
  `qty ≤ 100 − stock` (L3903), never sell into factor ≤ 1.0 (L3642);
  neutral ports excluded from budgets (L535-538) and docking (pin at
  L4679-4694: "a trader NEVER docks at a `nation_id: ""` neutral port");
  `coasters_mult_per_port 0.75` / `traders_mult_per_port 1.25` in
  `data/npc_config.json`; cap = core 272 + slack 16 = **288**; perf pins
  75 ms day tick / 250 ms pursuit A*.
- Data: 145 ports (100 sovereign exact-set locked incl. per-port
  produces/demands tuples + 45-neutral tier, bounded 40–60); goods 20
  (5/10/5 derived split); `LOCKED_GOODS`/`LOCKED_SHIP_TYPES`/
  `LOCKED_EQUIPMENT` exact-set locks (`validate_data.py` L208-494);
  `named_pirates.json` 4 entries (id/name/tier); 17 lanes, builder
  byte-identical.
- Suites: **37 / 6 538 checks** (`tools/run_tests.py` auto-discovers
  `tools/test_*.tscn`); `test_save_v6` is the current save suite (307
  checks); `test_economy` pins drift/rest/event semantics.
- UI: `data/ui_strings.json` 501 keys (market 24, shipyard 41, palace 17,
  tavern 28); screens `scenes/port/{market,shipyard,palace,tavern}_screen`;
  tavern Rumors tab renders `npc_intel.rumor_rows` (event telegraphs →
  port log → live fleets).
- Stale-doc cleanup owed: `30-*` §4.3 "Phase-6 candidate" line
  (correction 1); `80-*` §4.7 "version 4" line (correction 16);
  `trade_engine.gd:437` "docs/30 §4.7" comment (correction 5).

---

## Locked constants

All numbers here get ratified into the owning docs by the Phase-7 doc
tasks before any data/code starts (`00-*` §13). Task-owned values are
marked; everything else is final-for-now per `00-*` §11. Corrections above
are already folded in.

### 2.1 Economy overhaul (`30-*` §4.2 amendment, `10-*` §7.2)

- **Goods 20 → 40.** 20 new, era-appropriate ~1550–1620 (tea, coffee,
  tobacco, silver, gold, porcelain, pearls, indigo, sandalwood,
  lacquerware, gems, musk, rhubarb, raw silk, dye_wood, …; exact id set
  task-owned by G **after A pins the list skeleton in `10-*` §7.2** —
  the cross-worktree contract for P's graph authoring). Every entry:
  `id`, `name {zh,en}`, `category`, `base_price`, `unit_size`, plus new
  optional fields:
  - `staple: true` — the cheap basics (12 of 40). **Authoring rule
    (validator-asserted, correction 3):** for every port,
    `demands ⊇ (staples ∖ port.produces)`; produces ∩ demands = ∅.
    No code staple special case — the derived 5/10/5 split in
    `economy.gd` L57-64 is replaced by the data flag (K).
  - `specialty: true` — produced at ≤ 6 ports worldwide; subset carries
    `exclusive: true` (≥ 1 per neutral region band — machine-checked via
    the new `band` field, correction 4).
  - `flow: {prod, cons, capacity}` — optional per-good overrides of the
    tier defaults below.
- **Tier split re-pin:** 12 staples / 16 middle / 12 luxuries (validator
  re-pins 5/10/5 → 12/16/12, group 7; the split now derives flow rates
  and capacities and is **flag-driven**, not order-driven).
- **Listing rule (behavior change — correction 7):**
  `listed(port, good) = good ∈ port.produces ∪ port.demands`. Market rows
  show listed goods only. Exclusive goods render for everyone but
  buy/sell is alignment-gated (§2.5).
- **特产 display:** ★ badge on rows for `port.produces` members; header
  line `特产: <up to 3 names>` (`market.specialty.*`).
- **All 145 ports' `produces`/`demands` rewritten over the 40 goods**
  (P; every port lists every staple it does not produce). Every lane's
  `goods` tags extended to new ids where history warrants (P owns);
  the built artifact must stay byte-identical (T re-verifies; if the
  builder ever embeds goods tags, T rebuilds over merged sources).
- **Graph-shape constraints (validator, decisions 21/22):** every good
  ≥ **2 producers** and ≥ **4 consumers** worldwide; every port has ≥ 1
  staple producer within **120 tiles** (≈600 nm straight-line) and ≥ 2
  within 240; every region band ≥ 2 staple producers.
- **Flow economy (decision 17 — replaces drift-to-rest):**
  - Daily tick (replacing `_drift_step`): produced
    `stock += prod_rate × dev_mult`, clamped at capacity; consumed
    `stock −= cons_rate × dev_mult`, floored at 0 (unmet demand sits — a
    starved port cannot sell what it lacks).
  - Tier rates: staples **5/day**, middle **3/day**, luxuries **2/day**
    (one rate serves both prod and cons unless overridden).
  - Capacity: by tier **160 / 140 / 120**, plus **+20 per dev level**,
    hard ceiling **200** (`STOCK_MAX` stays 200; factor formula and all
    integer price math stay exact).
  - Dev multiplier on both rates: dev 0/1/2/3 → ×1.0/×1.25/×1.5/×2.0,
    integer math `rate × (4 + dev) / 4`.
  - Initial stocks (new game): producers at capacity; consumers at **60**.
  - **Market direction:** a producing port never buys its own produced
    goods — sell disabled, marked 不收购; buying requires stock > 0
    (falls out of the walk).
  - **Demand events re-pinned** (decision 17 / correction 9): temporary
    **consumption-rate surge ×3** for the duration, replacing the
    rest-override; same seeded scheduler, budgets, tavern telegraphs;
    `data/market_events.json` `shifts` becomes a rate-override (K owns
    the atomic data+code+validator transition in W3).
  - **Untouched:** factor-from-stock plumbing — tranches, the
    [0.5, 2.0] band, 0.8 margin, investment discount, title bonus
    (`trade_engine.gd` keeps reading `Economy.factor_units`).
  - **Steady state (intended):** producers at capacity (cheap), consumers
    drained to 0 (dear) — the stable gradient; recovery at real rates
    (harness gate 5).
- **`band` field (correction 4):** `ports.json` gains `band: <band_id>`
  on all 145 ports; band id set task-owned by P (superset of the six
  Phase-6 neutral bands + European bands), locked by A in `10-*`;
  consumers: staple-coverage checks, exclusive-per-neutral-band check,
  telegraph scoping (§2.4).

### 2.2 Ships (`40-*`, `10-*` §7.3)

- **Roster 8 → 16.** Existing 8 unchanged (stats locked). New ids:
  | id | zh | class | role | first-pass stats |
  |---|---|---|---|---|
  | galiot | 小型桨帆船 | oar | war (cheap) | dur 35, cap 25, spd 16, crew 15/40, slots 2, 2,400g |
  | galleass | 加莱赛战船 | oar | war (heavy) | dur 110, cap 70, spd 16, crew 60/160, slots 6, 22,000g |
  | fluyt | 弗鲁特商船 | sail | trade (bulk) | dur 70, cap 180, spd 16, crew 12/30, slots 2, 14,000g |
  | junk | 福船 | sail | trade (regional) | dur 90, cap 140, spd 18, crew 20/60, slots 3, 16,000g |
  | dhow | 单桅三角帆船 | sail | trade (regional) | dur 60, cap 90, spd 18, crew 10/30, slots 2, 9,000g |
  | pinnace | 平底船 | sail | trade (coastal) | dur 40, cap 45, spd 16, crew 8/20, slots 2, 2,200g |
  | caravela_redonda | 卡拉维拉方形帆船 | sail | trade (mid) | dur 70, cap 100, spd 20, crew 15/40, slots 3, 11,000g |
  | xebec | 小型三桅船 | hybrid | war (fast raider) | dur 60, cap 60, spd 24, crew 25/80, slots 4, 15,000g — **dated exception ~1690s**, one-line note in `LICENSE-NOTES.md` |

  Speeds are the Phase-6 {16,20,24} tiles/day values; S may tune within
  ±20% at authoring, then locked (exact-set validator tuples).
- **Shared-hold physics kept** (decision 2): `used_capacity` still sums
  cargo + provisions + water. No tank fields.
- **Galley re-role:** `role: "war"`, price unchanged (10,000g), stock
  list restricted to Mediterranean/North-African ports (P); role label
  战舰/商船/沿岸 on every shipyard row (`shipyard.role.*`). Its 2-day
  endurance stays an honest warship trait. (Role values locked:
  `war | trade | coastal` — task-owned by F/C wording, A pins the enum.)
- **Per-port availability:** `facilities.shipyard: 1` →
  `facilities.shipyard: [ship_type_ids]` (≥ 2, ≤ 8) at all 104 shipyard
  ports. Regional flavor: Mediterranean → galley/galiot/galleass/xebec;
  China coast → junk; Arabia/India → dhow; Holland → fluyt; capitals
  stock the widest set. Save ships store `ship_type_id` as today (no save
  impact).
- **Tier gating (decision 23):** every type gains `tier: 1|2|3` —
  first-pass: tier 1 {latin, sloop, pinnace, galiot}; tier 2 {caravel,
  brigantine, galley, dhow, caravela_redonda, fluyt, junk, xebec}; tier 3
  {nao, carrack, galleon, galleass} (S finalizes, then locked; validator:
  ≥ 2 per tier; ≥ 4 dev-3 sovereign ports stock tier-3 hulls).
  Universal filter at **both port kinds**:
  `purchasable = in_stock ∧ tier ≤ effective_dev(port)`.
- **Three row states (correction 11):** available / tier-gray with
  需发展度 note (`shipyard.tier.*`) / allegiance-gray at neutral ports —
  neutral shipyards stock their regional hulls **only under allegiance +
  dev ≥ 2**; an unallied neutral shows the full list allegiance-grayed
  (no empty-crash state; the lock note explains the flip path).
- At start only the 6 dev-3 capitals sell tier-3 hulls; a major
  contestable port grown to dev 3 (25,000g ledger) unlocks them too.

### 2.3 Equipment (`60-*` §4.11.12/13 extension, `10-*`)

- **24 items, 6 per slot** (weapon/armor player; figurehead/sail ship).
  Sideways modifiers beyond combat stats: existing keys (`combat`,
  `luck`, `durability`, `speed`) plus two new: **`storm_damage_pct`**
  (−%, multiplies `storm_damage_for`), **`scurvy_delay_days`**.
- **Per-port stock:** `facilities.equipment_stock: [ids]` (≥ 2 at every
  shipyard port); regional flavor as ships; same tier filter and grayed
  rows as §2.2, including the neutral allegiance gate.
- **Tier gating:** `tier: 1|2|3` — **2/2/2 per slot** (price guideline:
  tier 1 ≤ 1,500g, tier 2 ≤ 3,500g, tier 3 above; S finalizes).
- **Rare drops (correction 10):** 4 items carry `rare: true` — never in
  any stock list (validator-asserted); `data/named_pirates.json` gains
  `drop: <equipment_id>` per entry; `60-*`'s loot flow keys the drop off
  the sunk/captured captain id; rare items are never tier-gated (never
  purchasable at all).
- Prices 300g–6,000g band; zh/en names required.

### 2.4 Allegiance & development (`30-*` new §4.9, `10-*` §7.1 amendment) — correction 5 numbering

**Two port classes (decision 25):**

**Protected ports** (≤ 4 per nation; `protected: true` in `ports.json`):
- The set (decision 25): portugal {lisbon, oporto}; spain {seville,
  cadiz, valencia, barcelona}; england {london, plymouth}; holland
  {amsterdam, antwerp}; ottoman {istanbul, athens, smyrna}; italy
  {venice, genoa, naples, palermo}.
- Validator: protected ⊇ the 6 capitals; ≤ 4 per nation; protected ports
  never carry a ledger.
- Mechanics: alignment = owner **permanently**; investment =
  discount-only (the standing P1 behavior, no ledger effect); dev =
  authored floor, never grows (capitals stay dev 3 forever).

**Contestable ports** (everything else — sovereign non-core + all 45
neutral):
- Runtime state (save v7, correction 8): `ledger {nation_id: gold}`
  (cumulative per nation), `allegiance: nation_id | ""` — strictly the
  highest **effective** ledger ≥ **5,000g**; effective = raw except the
  sovereign owner's **× 1.25** (integer `ledger × 5 / 4`); **ties keep
  the incumbent** (why `allegiance` is persisted); below 5,000g effective
  → unalligned. Dev is **derived**, never saved.
- **Starting state is the only sovereign/neutral difference:** a
  contestable sovereign begins `{owner: 6,000}` (allied, above the line,
  below dev-1's 10k); a neutral begins empty.
- **development = max(authored floor, ledger thresholds)** — derived at
  load and on every ledger change: dev 1 at ≥ **10,000g** total ledger,
  dev 2 ≥ **25,000g**, dev 3 ≥ **50,000g**. Floors: capitals/protected 3
  (authored `dev` in `ports.json` — sovereign contestable major 2, rest
  1; neutral floor 0). (Correction 1: no such map/key exists to delete;
  this subsection is the introduction.)
- **Player investment** (market Invest button, 500g chunk, any
  contestable port): standing **1%/chunk discount, cap 10%** (the
  existing `INVEST_CAP_CHUNKS = 10` arithmetic is unchanged) **and**
  +500g to the player-nation ledger there.
- **Flip-campaign rules (decision 26):**
  - **Monthly cap:** ≤ **2,000g** player investment per contestable port
    per month; three-state Invest button (available / allowance-exhausted
    / diplomacy-blocked) with hint (`market.invest_gate.*`); state in
    `month_invested {port_id: gold}`, reset at the month tick.
  - **Home advantage:** the sovereign owner's ledger counts **× 1.25**
    in the allegiance comparison (a mature foreign sovereign port needs
    > 7,500 effective value; neutrals: no owner, no bonus).
  - **Diplomatic gate:** investing requires **rep ≥ 0** with the port's
    current alignment nation **and no active bounty from them** (the
    permit-void conditions, §2.5) — wanted pirates cannot buy ports.
    Unallined contestable ports have no gate.
- **Poaching rep hit:** the player's nation **gaining** a foreign
  sovereign port costs the player **−5 rep** with its previous owner
  (one-time per flip; none on losing it back).

**NPC counter-investment (monthly, deterministic):** on day 1 of each
30-day month, each AI nation invests in 0–2 sphere ports, seeded
`seed = month_index × 1000003 + nation_ordinal × 7919 + port_ordinal × 104729`
(the `70-*` seed style): `spend = min(treasury, 1500)` per pick, weighted
toward ports on/adjacent to their lanes and away from ports they already
hold at dev 3. Spheres: `ports.json` gains `sphere: [nation_ids]` per
contestable port — **including foreign contestable sovereigns** (P;
historical claimant nations). Protected ports are never investable by AI.
**Telegraph (decision 24):** each investment lands as a tavern rumor row
`{nation} 在 {port} 投资 {amount}g`, visible 30 days in taverns of the
invested port's **band** (new `band` field — correction 4; same plumbing
family as `economy.gd` `event_telegraphs`). `allegiance.gd` exposes
`last_month_investments()`.

**Nation treasuries (runtime, save v7):** start **5,000g** each; monthly
income = **1,000g** baseline + **all tax** collected at their ports and
allied ports (player and NPC trades alike, decisions 19/20) + **permit
sales**; NPC-sourced tax capped **2,000g/nation/month**; spend only on
counter-investment. No decay, no other sinks this phase.

**Month-tick ordering (pinned by A in `90-*`):** the day ledger calls
`Economy.day_tick` first (stock movement + event bookkeeping — existing
position), then, on a month boundary, `allegiance.month_tick()` — which
resets `month_invested`, credits baseline income, resolves counter-
investment, and refreshes telegraph windows. One seam, one owner (L).

**Effects ladder (both port classes; alignment = allegiance at
contestable, owner at protected; rates/capacity per §2.1):**
| dev | flow rates | capacity | extras |
|---|---|---|---|
| 1 | ×1.25 | +20 | — |
| 2 | ×1.5 | +40 | 专营货 rows activate for the alignment nation |
| 3 | ×2.0 | +60 (ceiling 200) | contestable ports only: patrol umbrella (alignment-nation escort patrols extend, spoke ≤ 40 tiles; hunters cannot camp it) |

Ship/equipment tier availability follows dev via the universal §2.2/§2.3
filter — no per-level ladder entries.

### 2.5 Tax & permits (`30-*` new §4.10, `80-*` market/palace) — correction 5 numbering

- **Unified tariff (decisions 19/20) — one rule for everyone:** effective
  alignment == trader's nation → **5%** on buy cost and sell proceeds;
  otherwise **20%**. Effective alignment = owner at protected, allegiance
  at contestable. Unallied contestable 20% forever — **no permit can ever
  exempt it** (no palace). Nationless coasters exempt (no host to pay).
  Provisions/water exempt (existing rule). Tax applies **after** all
  existing price math (band, margin, tranches, discount, title bonus —
  all untouched); separate displayed line (`market.tax.*`).
- **Permits (two kinds):**
  - **本国免税证 (home charter):** 5,000g, own palaces only, **no
    title/rep gate** (the early gold sink); covers every port whose
    effective alignment == the player's nation (protected own + aligned
    contestable), 5% → 0%.
  - **涉外免税证 (foreign permit):** per nation, that nation's palaces,
    20,000g, title ≥ Knight, rep ≥ +20 (unchanged); covers that nation's
    protected + aligned contestable ports.
  - Both **void** while that nation's bounty is held or rep < −20;
    re-buy at full price. `GameState.permits {home: bool, foreign:
    {nation_id: bool}}` (save v7).
- **Treasury flow (decision 19 — tax-only, no profit accounting):** every
  tax coin flows to the port's effective-alignment nation (player and NPC
  alike); permit purchases flow to the selling nation; NPC-sourced tax
  capped 2,000g/nation/month; the player's home-sphere 5% funds their own
  nation's counter-investment.
- **UI:** market header badge (势力内 5% / 免税 / 外国 20% / 未同盟 20%);
  tax line each side of the trade dialog.

### 2.6 Fame & ceremony (`70-*` §4.1 extension, one paragraph)

+100 fame the first time each **contestable** port flips to the player's
nation (once per port per save); +25 fame each time a dev threshold is
reached at a contestable port aligned to the player's nation; one-time
palace commendation dialog per converted port (ceremony pattern reuse;
`palace.commend.*`). Title ladder untouched. The poaching −5 rep fires
alongside the fame award.

### 2.7 NPC trade at ports (`60-*` §4.11 amendment)

**Trader docking at aligned ports (decision 12 generalized by 25):**
traders of nation N on any lane may dock at any port whose **effective
alignment == N** (protected own + contestable aligned to N — sovereign
non-core and neutral alike); standing port-call rules (≤ 30 units/call,
hold 40) unchanged. Rival-aligned or unallied ports get no lane traders.
The Phase-6 own-nation docking pin (`npc_fleets.gd` L4679-4694, `10-*`
§7.1 "no NPC fleet serves") is **amended** by this rule.

**Nationless coasters everywhere (decision 18; correction 15):** every
neutral port (unallied included) receives ~1 nationless coaster (中立灰
livery, pirate-fleet precedent) hopping to the **nearest ports regardless
of ownership** — border-crossing local trade; standing coaster rules
(≤ 5 units/call, hold 10, saturation `qty ≤ 100 − stock`, never sell
into factor ≤ 1.0) unchanged.
- Locality is the anti-imbalance guard: nearest-port hops only, never
  lanes — long-distance specialty trade stays the player's domain.
- **Goods scope (decision 21):** coasters trade **staples ∪ middle
  only** — never luxury/specialty/exclusive; margin selection stays free
  within that set. Lane traders keep the standing exclusive rule.
- **NPC tax (decisions 19/20):** traders and sovereign coasters pay the
  unified tariff into the host treasury on their port-call trades —
  reusing the walked totals already computed, no profit accounting;
  nationless coasters credit nothing.
- Flow-economy fit: coasters damp local extremes, never erase them
  (harness gate 6).
- **Spawn budget:** new data line `neutral_coasters_mult := 0.75` in
  `data/npc_config.json` (correction 15; the nation-line
  `coasters_mult_per_port` keeps its meaning); fleet cap 288 arithmetic
  re-derived and recorded; **day tick ≤ 75 ms and pursuit A* ≤ 250 ms
  re-proven** at full spawn count (correction 2; fallbacks: dwell-day
  cadence or multiplier retune, both data-side).
- Never-triggers-contact unchanged (lootable coasters are Phase-8).

### 2.8 Save v7 (`90-*` §8.2)

`SAVE_VERSION = 7`, `PHASE = 7` (`autoload/save_system.gd`), v6 refused,
no migration chain. New persisted keys:
`permits {home: bool, foreign: {nation_id: bool}}`,
`port_allegiance {port_id: {ledger, allegiance}}` — **correction 8
shape** (dev derived; allegiance persisted for the tie rule) for **all**
contestable ports (sovereign non-core incl. their `{owner: 6,000}` seed,
and all 45 neutrals),
`month_invested {port_id: gold}`,
`nation_treasuries {nation_id: gold}`,
`fame_commended {port_id: true}`.
`market_stocks` keeps its shape (flow economy changes tick semantics, not
the format). New-game seeding runs through `allegiance.seed_new_game()`
(C-pinned contract) so v7 payloads replay pure. One owner task (V), the
Phase-6 correction-14 pattern; `tools/test_save_v6.*` → renamed/reworked
`tools/test_save_v7.*`.

### 2.9 Balance harness (task T: `tools/sim_trade.py`)

Headless; loads goods/ports/`trade_routes_built.json`; simulates the flow
economy day by day to steady state, then walks lane-adjacent port pairs;
reports profit/day CSV plus per-route recovery times. The harness mirrors
the **exact integer formulas** of §2.1 (+ §2.4 dev multipliers, §2.5
tariffs) — both implementations read the same docs-pinned numbers; K's
`test_economy` pins one scenario that T re-asserts numerically in the sim
report (double-implementation drift guard). **Pinned gates
(first-pass):**

1. Home-nation staple routes **with the 5%/5% sphere tax applied**:
   profit/day > 0 for every starter ship.
2. Foreign unpermitted routes: profit ≤ 60% of the equivalent permitted
   run (the tax must bite).
3. Regional specialty routes (monsoon lanes, allied port at 5%):
   profit ≥ 1.2 × the best home-nation route of equal distance.
4. Under 20/20 tax no route exceeds 3 × the pre-tax profit.
5. Flow pacing: after a max-hold sale dumps into a consumer, its price
   recovers to within 10% of steady state in ≤ 30 days.
6. Coaster damping: between coaster-connected neighbors the steady-state
   price gap stays ≥ 50% of the coasters-disabled gap.
7. Greedy-bot ceiling (decision 22): optimal-greedy nets ≤ **80,000g**
   over 360 days.
8. Diminishing returns (decision 22): a 120-unit run's profit < 2.2 × a
   60-unit run's.
9. Staple access (decision 21): from every port the nearest staple
   producer ≤ 120 tiles; the report ranks the furthest staple runs
   (P iterates on the ranking).
10. Producer health (decision 22): with NPCs active, steady-state average
    producer stock ≥ 50% capacity.

Failing a gate blocks the economy data lock (the W2 gate), not the docs.
Tuning levers stay data-side (`base_price`, `flow` overrides,
produces/demands graph shape).

---

## New artifacts

| Artifact | Owner | Notes |
|---|---|---|
| `docs/IMPLEMENT-Phase7.md` | A0 (master) | this file |
| `data/goods.json` (40 + flags + optional `flow`) | G | ids per A's pinned list skeleton |
| `data/ship_types.json` (16 + `role` + `tier`) | S | existing 8 unchanged |
| `data/equipment.json` (24 + `rare` + `tier`) | S | 2/2/2 per slot |
| `data/named_pirates.json` (+ `drop`) | S | correction 10 |
| `data/ports.json` (economy rewrite, `band`, `protected`, `dev` floors, `sphere`, `shipyard`/`equipment_stock` lists) | P | single writer; all 145 |
| `data/trade_routes.json` lane `goods` extensions | P | built artifact stays byte-identical (T verifies) |
| `tools/validate_data.py` W2 amendments (group 3 schemas, group 5 lock model + exact sets 40/16/24, group 7: tier split 12/16/12, staple ubiquity, graph shape, coverage, tiers, protected rules, drop refs) | T | **event checks untouched** (correction 9) |
| `tools/sim_trade.py` + gates 1–10 report | T | staged-sim protocol (correction 14) |
| `scripts/port/economy.gd` flow rework + `data/market_events.json` rate-surge + validator group-7 event shape | K | atomic transition, W3 (correction 9) |
| `scripts/port/allegiance.gd` (new module) | L | classes, ledgers, dev, monthly AI, treasuries, campaign rules, telegraph source |
| tax/permits/listing in `scripts/port/trade_engine.gd` + permit sales in `scripts/port/palace_engine.gd` | L | + treasury income hooks |
| market screen + tavern telegraph rows | M | screens + `npc_intel.gd` row kind |
| shipyard engine/screen + palace screen | F | three row states, permit row, commendation |
| `scripts/world/npc_fleets.gd` amendments + `data/npc_config.json` | N | docking, nationless coasters, NPC tax |
| save v7 (`save_system.gd`, `game_state.gd`, `test_save_v7.*`) | V | one owner for the breaking bump |
| `tools/demo_check_phase7.md` | J (master-led) | acceptance record |

---

## Tasks

### A0 — Author this backlog (master, no worktree)

- **Goal:** this file, ratified.
- **Done-when:** corrections verified against the repo; `python3
  tools/validate_data.py` exit 0 after the docs-only change; AGENTS.md
  task-backlog pointer updated.

### A — Amend `10-DATA-SCHEMA.md`, `90-ARCHITECTURE.md`, `00-OVERVIEW.md`, AGENTS.md (doc-first)

- **Goal:** the data contract + architecture pins for trade empires.
- **Changes:** `10-*` — goods schema gains `staple`/`specialty`/
  `exclusive`/`flow` and the §7.2 list extension (40; **id list skeleton
  pinned here** as the G/P cross-worktree contract); §7.3 ship list
  extension (16, `role` enum `war|trade|coastal`, `tier` rules); new
  equipment locked-list section (24, `tier` 2/2/2, `rare` never-stocked,
  `named_pirates.drop` refs); port schema gains **`band`** (band id set
  container — P authors members), `protected`, `dev` floors, `sphere`,
  `facilities.shipyard: [ids]`, `facilities.equipment_stock`; validator
  amendment specs — group 3 schemas, **group 5 lock-model change**
  (identity locks only for ports; exact-set for ships/equipment/goods),
  group 7 (tier split 12/16/12, staple ubiquity per correction 3,
  produces/demands disjoint, graph shape ≥2/≥4, staple coverage
  120/240 tiles + ≥2/band, exclusive ≥1 per neutral band, protected ⊇
  capitals ≤4/nation, tier rules ≥2/tier + ≥4 dev-3 ports stocking
  tier-3, rare-drop refs). `90-*` — save v7 keys (correction 8 shape) + "
  no migration; v6 refused"; new module row `allegiance.gd`;
  **month-tick ordering pin** (§2.4); GameState additions (`permits`,
  `month_invested`, `nation_treasuries`, `fame_commended`,
  `port_allegiance`). `00-*` — phase table Phase-7 row; glossary:
  免税证 tax permit (本国 home charter / 涉外 foreign), 同盟港 allied
  port, 专营货 exclusive goods, 特产 specialty, 战舰 warship role, 仓储上限
  market capacity, 流动经济 flow economy, 保护港 protected port, 可争港
  contestable port, 国库 treasury, 关税 tariff; 沿岸货船 entry refreshed
  (local distributor at every port, nationless at neutrals, staples ∪
  middle scope). `AGENTS.md` — task-backlog pointer to Phase 7.
- **Done-when:** every §2.1–§2.9 constant with owning doc
  `10-*`/`90-*`/`00-*` appears there exactly once; band/sphere/protected
  schema wordings match §2.1/§2.4; no file outside `docs/` and
  `AGENTS.md` touched.

### B — Amend `30-PORTS-AND-TRADE.md` (doc-first)

- **Goal:** the port/trade spec, on paper.
- **Changes:** §4.2 amendment — flow economy replaces drift-to-rest
  (rates 5/3/2, capacities 160/140/120 +20/dev ceiling 200, dev
  multipliers ×(4+dev)/4, initial stocks, starved-port semantics, the
  intended steady state); §4.3 investment amendment — ledger effect,
  monthly cap, diplomatic gate (cross-ref §4.9), discount arithmetic
  unchanged; §4.4/§4.8 amendment — the listing rule + per-port row sets +
  特产 badge + 不收购 rows + tax lines in the wireframe; §4.5 demand
  events re-pinned as consumption-rate surges (×3, same
  scheduler/budgets/telegraphs); **new §4.9** allegiance & development
  (§2.4 verbatim: classes, ledgers, thresholds, campaign rules, NPC
  counter-investment + telegraphs, treasuries, effects ladder); **new
  §4.10** tax & permits (§2.5 verbatim); the §2.7 docking amendment note
  replacing the Phase-6 "no NPC fleet serves" line; **stale-line
  sweep:** §4.3's "Phase-6 candidate" line (correction 1).
- **Done-when:** section numbers per correction 5 (§4.9/§4.10 new; no
  renumber of Tavern/Inn/UI sections); cross greps vs `10-*`/`90-*` clean
  (rates, thresholds, tariffs, permit prices, treasury numbers); no file
  outside `docs/` touched.

### C — Amend `40-SHIPS-AND-FLEET.md`, `60-COMBAT.md`, `70-QUESTS-*.md`, `80-UI-UX.md` + UI contracts (doc-first)

- **Goal:** the ship/combat/fame/UI spec + the cross-worktree contracts.
- **Changes:** `40-*` — roster 16 table (§2.2), `role` meaning, per-port
  stock + tier-gating rule, galley re-role rationale. `60-*` — §4.11.12
  modifier-key extension (`storm_damage_pct`, `scurvy_delay_days`),
  §4.11.13 content-set table replaced by the 24-item schema + rare-drop
  flow (keyed by captain id); §4.11 amendment — trader docking at aligned
  ports, nationless coasters (§2.7), NPC tax crediting. `70-*` — the
  §2.6 fame/commendation paragraph. `80-*` — market screen rows (listing
  rule, ★, 不收购, grayed exclusive, three-state Invest, tax badge/lines);
  shipyard row states (three, §2.2); palace permit row + commendation;
  tavern telegraph rows; **the full ui_strings family inventory**
  (`market.specialty.*`, `market.tax.*`, `market.exclusive.*`,
  `market.invest_gate.*`, `shipyard.role.*`, `shipyard.tier.*`,
  `palace.permit.*`, `palace.commend.*`, `tavern.invest.*` — zh/en
  complete); **stale-line sweep:** §4.7 "version 4" line (correction 16).
  **Symbol contracts (the W3/W4 launch condition — names exact, guard
  defaults documented):** `Allegiance.effective_alignment(port_id) ->
  String`, `Allegiance.dev(port_id) -> int`,
  `Allegiance.tariff_mille(port_id, nation_id) -> int` (0/500/2000 after
  permits — called by trade_engine and the NPC crediting),
  `Allegiance.invest_block_reason(port_id) -> String` ("" or a
  ui_strings key),
  `Allegiance.last_month_investments() -> Array`,
  `Allegiance.credit_tax(port_id, payer_nation, gold) -> void`,
  `Allegiance.seed_new_game() -> void`,
  `Allegiance.month_tick() -> void`; `npc_config.json` key
  `neutral_coasters_mult`; rumor row kind `"investment"`.
- **Done-when:** cross-doc greps clean (tier tables, tariff numbers,
  docking rule vs `30-*`); the symbol list above appears exactly once in
  `80-*`; no file outside `docs/` touched.

### G — `data/goods.json`: 40 goods with flags and flow overrides

- **Goal:** the 40-good content set, green against T's future locks.
- **Docs:** `10-*` (A) — author over A's pinned id-list skeleton only.
- **Creates/changes:** 20 new entries (`id`, `name{zh,en}`, `category`,
  `base_price`, `unit_size`); `staple` ×12 / middle ×16 / luxury ×12 by
  tier; `specialty` (≤ 6 producers each) and `exclusive` (≥ 1 per neutral
  band once P's ports land — coordinate via the staged-sim loop);
  optional `flow` overrides only where the tier defaults misprice a good
  (each override justified in the report); **existing 20 entries' fields
  gain tier flags — no other value changes** (prices locked).
- **Done-when:** content complete + self-checked (i18n parity, tier
  counts, producer counts per good ≥ 2 against the planned port graph —
  a throwaway local script, not shipped); **held unmerged** through the
  W2 gate (correction 14).

### S — `data/ship_types.json` + `data/equipment.json` + `data/named_pirates.json`

- **Goal:** the 16-ship roster and 24-item equipment set, authored final.
- **Docs:** `10-*` (A), `40-*`/`60-*` (C).
- **Creates/changes:** ship_rows — 8 new types per §2.2 (±20% tuning
  budget, then final), `role` on all 16, `tier` per §2.2 first-pass
  (finalize); equipment — 16 new + 8 re-tiered + modifiers incl. the two
  new keys, 2/2/2 tiers per slot, 4 `rare: true`; `named_pirates.json`
  +`drop` (each references a rare item); `LICENSE-NOTES.md` new "Phase 7
  ships & equipment" section (era basis, the xebec one-line dated
  exception).
- **Done-when:** content complete + self-checked (price bands, tier
  counts, modifier-key validity); zh/en complete; **held unmerged**
  through the W2 gate.

### P — `data/ports.json` full pass + lane goods extensions (one writer)

- **Goal:** the 145-port economy graph + class metadata, authored.
- **Docs:** `10-*` as unlocked (A); §2.1/§2.4 checklists; `30-*` (B).
- **Creates/changes:** `data/ports.json` — produces/demands rewrite over
  the 40 goods (every port lists every staple it does not produce —
  correction 3; produces ∩ demands = ∅; graph-shape checklist: ≥2
  producers/≥4 consumers per good, staple coverage 120/240, ≥2 staple
  producers per band, ≥1 exclusive per neutral band); `band` on all 145
  (band id set — superset of the Phase-6 neutral bands + European bands;
  members finalized here, appended to `10-*`); `protected: true` per the
  decision-25 set; `dev` floors (capitals/protected 3, major 2, rest 1,
  neutral 0 — majors chosen with historical rationale, cited);
  `sphere: [nation_ids]` per contestable port incl. foreign sovereigns;
  `facilities.shipyard: [ids]` (≥2 ≤8, regional flavor, tier-checked so
  every reachable dev level sells something; ≥4 dev-3 sovereign ports
  stock tier-3 hulls) and `facilities.equipment_stock` (≥2) at all 104
  shipyard ports; `data/trade_routes.json` lane `goods` extensions where
  history warrants (built artifact must stay byte-identical — if not, P
  reports and T rebuilds over merged sources); `docs/10-*` §7.1/§7.2 /
  new sections content appends (ids finalized after authoring);
  `LICENSE-NOTES.md` new port-economy + band sections (per-port basis,
  historical citations).
- **Done-when (worktree-local):** graph self-checks pass with a local
  throwaway script (coverage distances recomputed from lat/lon at 12
  t/°); tier/stock spot-checks recorded; **held unmerged** through the
  W2 staged-sim loop and gate (correction 14).

### T — Validator amendments (W2 set) + `tools/sim_trade.py` + gates 1–10 report

- **Goal:** the lock model for the new content + the measured economy.
- **Docs:** `10-*` (A); §2.9.
- **Creates/changes:** `tools/validate_data.py` — group 3 schemas (new
  port fields, goods flags, ship/equipment fields); group 5 — **lock-model
  amendment** (ports: identity locks id/zh/en/nation/lat/lon exact,
  145-set exact, produces/demands demoted to structural checks; goods
  exact 40, ships exact 16, equipment exact 24); group 7 — tier split
  12/16/12 flag-driven, staple ubiquity (correction 3), disjointness,
  graph shape (≥2/≥4), staple coverage (120/240, ≥2/band), exclusive
  per neutral band, protected rules, tier rules, rare-never-stocked +
  `drop` refs, band id set; **group-7 event checks untouched**
  (correction 9 — K owns that in W3); group 8 unchanged (17-lane set);
  `tools/sim_trade.py` — the §2.9 mirror + gates 1–10 + the
  furthest-staple ranking + greedy-bot report; **staged-sim protocol
  (correction 14):** iterate gates against a staging export of the G/S/P
  branch data pre-merge (master exports; reports per iteration in the
  task report); two `sim_trade.py` runs byte-stable output.
- **Done-when (at the W2 gate, after merges G→S→P→T):** validator exit 0
  groups 1–10; all ten sim gates pass with the merged data; the staged
  iteration history recorded; if the lane `goods` edits touched the built
  artifact, `trade_routes_built.json` rebuilds byte-identical over merged
  sources; all suites green (validator-only wave behavior).

### K — `economy.gd` flow rework + demand-event transition (one owner for the stock tick)

- **Goal:** the flow economy live, deterministic.
- **Docs:** `30-*` §4.2/§4.5 (B); §2.1.
- **Creates/changes:** `scripts/port/economy.gd` — replace drift with the
  §2.1 tick (tier rates 5/3/2 **flag-driven** from `goods.json`, capacities
  by tier +20/dev ceiling 200, dev multiplier via C's
  `Allegiance.dev()` contract with guard default 0, starved-consumer
  semantics, producers-don't-buy exposed for the engine);
  `data/market_events.json` `shifts` → `rate_override` (×3 consumption
  surge; **atomic with code** — correction 9); `tools/validate_data.py`
  group-7 event-shape check (single W3 writer); `data_loader.gd`
  registrations if the factory needs them; rework `tools/test_economy.*`
  (determinism: same seed → same ticks; steady-state gradient producers
  full/consumers drained; recovery pacing ≤ 30d within 10%; the one
  scenario T re-asserts numerically — value pinned in the task report);
  initial-stock seeding (producers at capacity, consumers 60).
- **Done-when:** all suites green incl. reworked `test_economy`;
  determinism proof recorded; `sim_trade.py` scenario parity check
  passes; no drift constant survives except in the changelog comment.

### L — `allegiance.gd` + tax/permits/listing engines (one owner for alignment money)

- **Goal:** the allegiance tug-of-war, tariffs, and permits.
- **Docs:** `30-*` §4.9/§4.10 (B), `70-*` paragraph, `80-*` contracts (C).
- **Creates/changes:** new `scripts/port/allegiance.gd` (class_name per
  C's contract) — protected/contestable classes read from data, ledgers
  with the `{owner: 6,000}` seed, effective-value ×1.25 integer math,
  allegiance resolution with incumbent ties, dev derivation (thresholds
  10k/25k/50k + floors), monthly AI per §2.4 (seeded formula, ≥0–2
  picks, treasury-bounded spend), treasuries (start 5,000, +1,000/mo,
  cap 2,000 NPC tax), fame hooks (+100/+25, commend event), poaching
  −5 rep, telegraph ring buffer + `last_month_investments()`,
  `month_invested` cap + month-tick reset, diplomatic gate (rep ≥ 0, no
  bounty); `scripts/port/trade_engine.gd` — listing-filtered
  `goods_rows(port_id)` (behavior change — correction 7), tariff compose
  on both buy/sell after existing math (displayed lines), permit
  resolution (home/foreign, void rules), invest() wiring through
  allegiance (discount unchanged, ledger add, cap/gate enforcement);
  `scripts/port/palace_engine.gd` — permit sales (both kinds, price/title/
  rep gates, treasury credit), commendation hook; new
  `tools/test_allegiance.*` (ledger/dev/allegiance resolution, sovereign
  seed state, protected immunity, monthly-AI determinism — same seed →
  same investment sequence, cap/gate/home-advantage edge cases, poaching
  rep, telegraph window) + rework `tools/test_trade.*` (listing filter,
  5%/20% math on both sides, permit 5%→0% and void rules, treasury
  credit) and `tools/test_palace.*` (permit sales gates).
- **Done-when:** all suites green; monthly-AI determinism proof recorded;
  `month_tick` wired at the A-pinned ledger seam; api signatures exactly
  C's contract; the NPC crediting entry point documented for N (W4).

### M — Market screen + tavern telegraph rows (one owner for market/trade-player surfaces)

- **Goal:** the flow economy and tariffs made visible at market, and the
  investment telegraph in taverns.
- **Docs:** `30-*` §4.8 (B), `80-*` (C).
- **Creates/changes:** `scenes/port/market_screen.{tscn,gd}` —
  listing-rule rows (unlisted goods gone), ★ 特产 badge + header line,
  不收购 sell-disabled rows on own produces, tax lines + header badge
  (4 states), grayed exclusive rows with lock note (dev ≥ 2 + alignment),
  **three-state Invest button** (available / allowance-exhausted /
  diplomacy-blocked with the allowance hint — decision 26);
  `scripts/world/npc_intel.gd` rumor row kind `"investment"` guard-reading
  `Allegiance.last_month_investments()` (default: no rows) scoped by the
  port's `band`; `scenes/port/tavern_screen.gd` rendering for the new
  kind (existing row machinery); stale comment fix at
  `trade_engine.gd:437` (correction 5); market cases added to
  `tools/test_trade.*`-adjacent screen suite (row presence/absence,
  button states — owned jointly with L, see pins).
- **Done-when:** unlisted goods never render; each row state reachable in
  suites; telegraph rows appear/expire with the 30-day window; zero
  `<key>` fallbacks (orchestrator-merged strings); all suites green.

### F — Shipyard engine/screen + palace screen (one owner for shipyard/palace surfaces)

- **Goal:** per-port hardware with honest gating.
- **Docs:** `40-*` (C), `60-*` (C), `80-*` (C).
- **Creates/changes:** `scripts/port/shipyard_engine.gd` — per-port
  `shipyard` stock lists and `equipment_stock` filter (replaces the
  global-list rows), tier filter via guard-read `Allegiance.dev()`
  (protected/get-the-floor fallback per C's contract), **three row
  states** (correction 11) incl. the unallied-neutral allegiance gate;
  `scenes/port/shipyard_screen.{tscn,gd}` — role labels
  (`shipyard.role.*`), grayed rows with 需发展度 / 同盟专营 notes, refit
  tab stock-aware; `scenes/port/palace_screen.{tscn,gd}` — permit row
  (both kinds; price/title/rep/void display through L's palace_engine
  APIs), commendation dialog (`palace.commend.*`); shipyard/palace cases
  in existing screen suites.
- **Done-when:** at a dev-1 port only tier-1 rows buyable, tier-2/3
  grayed with the dev note; at an unallied neutral every hull row shows
  the allegiance gate; at a dev-3 capital tier-3 buys work; rare items
  never appear in any stock UI; permit purchase/void flows play
  end-to-end; all suites green.

### N — `npc_fleets.gd` ecology amendments + budget/perf re-probe (one owner for the NPC world)

- **Goal:** NPC fleets trade the new world.
- **Docs:** `60-*` §4.11 amendment (C); §2.7; `30-*` pin update (B).
- **Creates/changes:** `scripts/world/npc_fleets.gd` — docking adoptions
  to effective alignment (guard-read `Allegiance.effective_alignment`,
  default = data `nation_id`) at spawn-pool and departure decisions, the
  L4679 pin rewritten per B/C; nationless coaster spawns at every neutral
  port (livery, role reuse), departure/destination logic (nearest ports
  regardless of ownership, staples∪middle scope clamp at buy/sell);
  NPC tax crediting through `Allegiance.credit_tax` on port-call walks
  (reusing walked totals; nationless exempt); `data/npc_config.json` —
  `neutral_coasters_mult := 0.75` (correction 15); rework
  `tools/test_{npc_fleets,ecology,aliveness,density}.*` **probes:** a
  trader docks at a flipped sovereign port of its alignment and never at
  a rival/unallied one; an unallied China-coast port sees its grey
  coaster trade; no coaster ever carries luxury/specialty/exclusive; host
  treasury rises deterministically after an NPC port call; nationless
  coasters credit nothing; determinism holds with the added spawns.
- **Done-when:** probes pass; cap 288 arithmetic re-derived and recorded;
  **day tick ≤ 75 ms and pursuit A* ≤ 250 ms re-measured at the new
  spawn count** (numbers in the report; correction 2); all suites green.

### V — Save v7 (one owner for the breaking bump)

- **Goal:** the phase's single breaking save moment, shipped whole.
- **Docs:** `90-*` §8.2 (A); §2.8.
- **Creates/changes:** `autoload/save_system.gd` — `SAVE_VERSION = 7`,
  `PHASE = 7`, v6 refused, STATE_KEYS + payload validation for
  `permits`, `port_allegiance`, `month_invested`, `nation_treasuries`,
  `fame_commended`; `autoload/game_state.gd` — new blocks with defaults,
  `new_game` wiring through `Allegiance.seed_new_game()` (C contract;
  contestable sovereign `{owner: 6,000}` seeds, empty neutrals);
  `tools/test_save_v6.*` → renamed `tools/test_save_v7.*`, reworked
  (round-trip every new key; v6 refusal with the standard pre-release
  message; **mid-month AI replay purity** — a save/load mid-month
  replays the month's counter-investment identically).
- **Done-when:** round-trips pass; v6 refused; replay purity asserted;
  `run_tests.py` discovery picks the renamed suite; all suites green.

### J — Acceptance (master-led, dated manual run)

- **Goal:** `tools/demo_check_phase7.md` + this file's completion record.
- **Scenario (all recorded):** watch the flow economy live — a producer's
  stock rebuilds toward capacity; a consumer starves and recovers after
  your sale; try and fail to sell a good to the port that produces it
  (不收购); sight a grey coaster trading at an unallied neutral port;
  raise an own-nation dev-1 port to dev 2 (专营货 activate, rates visibly
  faster); flip a China-coast port (invest vs monthly AI) and watch its
  badge drop 20% → 5%; read a rival's investment telegraph in a
  China-coast tavern and out-invest it; **be blocked once by the rep gate
  then run a multi-month flip campaign against a foreign sovereign port —
  cap, home advantage, AI contest all observed — and eat the −5 rep on
  the flip**; buy 本国免税证 (5% → 0% at home and aligned ports); buy a
  涉外免税证; run a taxed vs untaxed monsoon loop; sink/capture a named
  pirate for a rare drop; at a dev-2 major port see the galleon grayed
  需发展度 3, grow the port to dev 3 (25,000g), buy it; buy a junk at an
  aligned dev-2 neutral port; watch rival counter-investment flip a port
  back; zh/en parity.
- **Done-when:** every scenario recorded with version + results; the
  final-gate table below re-run and pasted; this file's completion
  record filled in.

---

## Task dependency note

A/B/C unblock everything (pure docs; nothing launches before W1 merges;
C's symbol contracts are the W3/W4 launch condition). G/S/P need A
(schemas + id list skeleton + lock-model wording) and are mutually
independent across files; they author **against doc-pinned id sets**, not
against each other's branches. T needs A (group specs) and *integrates*
G/S/P via the staged-sim loop (correction 14). K needs B and C's
`Allegiance.dev()` contract. L needs B/C; K and L are disjoint by file
(`economy.gd` vs `allegiance.gd`/`trade_engine.gd`/`palace_engine.gd`) and
mutually guard-read. M and F need C's contracts + W3's engines in their
done-when but launch with W3 using guard-reads (Phase-6 correction-12
pattern). N needs C's contracts + L's crediting API pinned (guard-read
with no-op default) — it launches in W4 against merged L. V needs A's key
list + C's `seed_new_game()` contract. J needs all.

The critical path is A0 → A/B/C → {G/S/P} → T(sim gates) → L → N/V → J:
**five subagent waves + master-led acceptance**.

## Shared-file pins (hard rule: one writer per file per wave)

- **W1:** A owns `docs/10-*`, `docs/90-*`, `docs/00-*`, `AGENTS.md`;
  B owns `docs/30-*`; C owns `docs/40-*`, `docs/60-*`, `docs/70-*`,
  `docs/80-*`. Disjoint.
- **W2:** G owns `data/goods.json`. S owns `data/ship_types.json`,
  `data/equipment.json`, `data/named_pirates.json`, `LICENSE-NOTES.md`
  (new ships/equipment section). P owns `data/ports.json`,
  `data/trade_routes.json`, `tools/route_overrides.json` (only if needed),
  `docs/10-*` (content-list appends after authoring), `LICENSE-NOTES.md`
  (new port-economy/band sections). T owns `tools/validate_data.py`,
  `tools/sim_trade.py`. Disjoint **except** `LICENSE-NOTES.md`: S and P
  append to *different new sections only* (line-additive; the Phase-5/6
  D/E precedent).
- **W3:** K owns `scripts/port/economy.gd`, `data/market_events.json`,
  `tools/validate_data.py` (group-7 event shape only), `autoload/
  data_loader.gd` (if needed), `tools/test_economy.*`. L owns
  `scripts/port/allegiance.gd` (new), `scripts/port/trade_engine.gd`,
  `scripts/port/palace_engine.gd`, `tools/test_allegiance.*` (new),
  `tools/test_trade.*`, `tools/test_palace.*`. M owns
  `scenes/port/market_screen.*`, `scenes/port/tavern_screen.gd`,
  `scripts/world/npc_intel.gd`. F owns `scripts/port/shipyard_engine.gd`,
  `scenes/port/shipyard_screen.*`, `scenes/port/palace_screen.*`.
  Cross-worktree reads use C's symbol contracts + the guard-call
  convention; M's screen-level market cases go in a **new**
  `tools/test_market_screen.*` (M-owned) so W3 shares no suite files.
- **W4:** N owns `scripts/world/npc_fleets.gd`, `data/npc_config.json`,
  `tools/test_{npc_fleets,ecology,aliveness,density}.*`. V owns
  `autoload/{save_system,game_state}.gd`,
  `tools/test_save_v7.*` (renamed from v6). Disjoint.
- **`data/ui_strings.json` is orchestrator-owned** (Phase-4/5/6
  protocol): every task lists its zh/en keys (C's W1 inventory is the
  checklist) in its report; the master merges after each wave. No
  subagent edits it directly.

## Subagent execution plan (max 4 background subagents, one worktree each)

Same protocol as Phases 3–6: the master owns the base branch, creates
and removes one named worktree per subagent
(`tools.opencode.worktree_create`), launches tasks as background
subagents with full-context prompts, merges every branch itself, and
runs the validator + full suite at each wave gate. Numbers not in the
locked tables are invented by no one (`00-*` §13 applies to subagents
first); the master re-quotes C's symbol contracts in every W3/W4 prompt.

| Wave | Launch (parallel, background) | Merge & gate |
|---|---|---|
| W1 | A, B, C | master merges all three; gate: docs greps per done-when; tree untouched outside `docs/`/`AGENTS.md` |
| W2 | G, S, P, T | **staged-sim loop first** (correction 14): T iterates gates 1–10 against staging exports of G/S/P branches; fix bounces stay in open worktrees. Then master merges **G → S → P → T**; gate runs **once**: validator exit 0 groups 1–10, sim gates 1–10 pass, built artifact byte-identical (or rebuilt + byte-identical by T), all suites green |
| W3 | K, L, M, F | master merges all four; gate: all suites green incl. reworked `test_economy`, new `test_allegiance`, reworked `test_trade`/`test_palace`; zh/en parity (orchestrator merge); determinism proofs recorded |
| W4 | N, V | master merges both; gate: all suites green incl. `test_save_v7`; day tick ≤ 75 ms + pursuit A* ≤ 250 ms re-proven and recorded; cap arithmetic recorded |
| W5 | J (master-led) | acceptance record + completion record in this file; final gates re-run |

- **Peak concurrency: 4 subagents** (W2, W3); W1 runs 3, W4 runs 2.
  Worktrees open at once never exceed 4. In W1/W4 the free slot is the
  Phase-6 master-verification reserve — never a fifth content task; in
  W2/W3 the master verifies merges in the main tree.
- **Held-branch rule** (Phase-6 correction-10, generalized by
  correction 14): a branch is held only when exact-set locks or tuning
  gates make a standalone merge unverifiable. W2's four branches are
  named held; they merge at one gate in pinned order G → S → P → T.
- **No sanctioned red window** (Phase-5 rule): every wave gate runs on a
  fully merged, fully green tree; W2's staged-sim loop exists precisely
  so the merged state is green by pre-verified prediction, not by luck.
- Subagent prompts must carry: this file's path, the task letter, its
  docs, the locked-constants pointer, the done-when list, the
  shared-file ownership list, the ui_strings reporting duty, C's symbol
  contracts (W3/W4 prompt quoted verbatim), and the wave gate (incl.
  held-branch status in W2).
- J is master-led (dated manual run), as in every phase.

## Risks & pinned mitigations

| Risk | Pinned mitigation |
|---|---|
| Early-game tax burden (home no longer free — 5%/5% sphere tax) | typical route margins (buy ≤0.7×, sell ≥1.0×) dwarf the ~10% round-trip tax; harness gate 1 asserts it for every starter ship; the 5,000g home charter is the designed relief valve |
| Monthly AI runaway or dormancy | cap 1,500g/port/month, treasury starts 5,000g, NPC-tax income capped 2,000g/nation/month, dev-3 de-prioritized; determinism suite; harness watches flip cadence (neutral ≥ 3 months, sovereign ≥ 4) |
| Passive port loss feels bad (decision 25 opens own non-core ports) | protected core guarantees the baseline experience; sovereign ports cost >6,000g of sustained rival investment; telegraphs (decision 24) give a month of warning |
| Flow steady state pins prices at extremes (0.5×/1.5×–2.0×) | intended gradient; harness gates 5/6 verify recovery and damping; per-good `flow` overrides are the tuning lever |
| **Staged-sim stall (W2 gate depends on a tuning loop)** | first-pass `flow` overrides are task-allowed and data-side; two full iteration rounds, then the owner decides a gate amendment per `00-*` §11 (never a silent relaxation); fix bounces stay in open worktrees |
| **Double-implementation drift (`sim_trade.py` mirrors GDScript tick math)** | both read the same docs-pinned integer formulas; K pins one scenario in `test_economy` that T re-asserts numerically in every sim report; a mismatch fails K's done-when |
| **Market-row behavior shock (20-rows-everywhere suites)** | called out as a behavior change (correction 7); L re-baselines `test_trade`, M owns a new screen suite; nothing else inherits the old assumption (grep audit in L's done-when) |
| **Alignment-dependent NPC determinism** | docking sets are pure functions of persisted ledger state; V asserts mid-month replay purity; N's probes run from pinned save states |
| `ports.json` multi-concern collisions | P is the single writer; G/S/T are separate files; the correction-12 lock model makes P's iterations cheap; validator cross-checks refs |
| Content volume (40 goods + 16 ships + 24 equipment, zh/en) | region-band checklists per task; validator i18n completeness is already group-2 |
| Phase-6 dependency | W2+ gated on the Phase-6 final gate (verified above); no ports.json work predates this file |
| +40–60 nationless coaster spawns strain cap 288 / 75 ms day tick | N re-probes both at full neutral count; fallbacks: dwell-day cadence or multiplier retune (correction 15), both data-side |
| Tax + allegiance UI sprawl | all new strings enumerated in C's W1 inventory up front (Phase-6 §2.9 pattern); orchestrator-merge protocol unchanged |
| Unallied-neutral shipyard empty state | three row states pinned in §2.2 (correction 11); F's done-when makes the allegiance-gated state suite-reachable |

## Out of scope (Phase-8 candidates)

Warehouse & consignment (incl. the sell-limit threshold option; decision
16), contracts board (商约), quarterly dividends, remote demand-event
intelligence, price logbook, regional coaster hulls (junk/dhow visuals
for the nationless coasters), lootable coasters, fleet hail/look/attack
interactions, cargo jettison, officer roles, fishing, investment-convoy
entities (decision 24's rejected alternative).

---

## Completion record

_Filled by task J (master-led), 2026-11-02. Full evidence:
`tools/demo_check_phase7.md`._

| Gate | Result | Date |
|---|---|---|
| validator groups 1–10 | **exit 0** (40 goods / 16 ships / 24 equipment / 145 ports / 15 bands / rate-surge events) | 2026-11-02 |
| `build_world.py` / `build_routes.py` / `build_ocean.py` rebuild byte-identity | **all three exit 0** (`--check`); route artifact rebuilt once over the merged sources by T (sha `dbab2811…`), three consecutive rebuilds byte-identical | 2026-11-02 |
| `sim_trade.py` gates 1–10 | **10/10 PASS**, two runs byte-identical (5 281 B); worst margins: gate 2 ratio 0.419, gate 3 1.800×, gate 5 exactly 30 days, gate 6 0.718, gate 7 68 970g ≤ 80 000g, gate 9 65 tiles, gate 10 0.985 | 2026-11-02 |
| test suites (`run_tests.py`) — count / checks | **39 suites / 7 689 checks, 0 failures, 0 zombie/hang** (Phase 6: 37 / 6 538) | 2026-11-02 |
| `godot --headless --quit-after 3` | exit 0, zero `SCRIPT ERROR` | 2026-11-02 |
| day tick @ cap (ms, ≤ 75) / pursuit A* (ms, ≤ 250) | **61.8 avg / 70.0 worst @ 307 fleets** (dwell-cadence fallback applied; mult 0.75 kept) / **20.6 worst**; extreme day tick 252 ms @ 1 118 (≤ 350) | 2026-11-02 |
| ui_strings keys zh/en parity | **570 keys, zh/en complete** (535 → 570; the +35 are C's §4.7.15 families, orchestrator-merged) | 2026-11-02 |
| save size @ extreme (≤ 2 MB) | **1 858 515 B ≈ 1.77 MB** (density probe: 1 752 101 B); save **v7**, v6 refused, mid-month AI replay purity proven | 2026-11-02 |
| acceptance probe | `tools/demo_probe_phase7.tscn` — **ALL PASS (73 checks)**, the sixteen J scenarios (table in `demo_check_phase7.md`) | 2026-11-02 |

**Phase 7 complete.** All waves landed per the execution plan: W1 (A/B/C
docs), W2 (G/S/P/T staged-sim, held branches, pinned merge order
G → S → P → T), W3 (K/L/M/F + one integration-bounce round each), W4
(N/V), W5 (this record). Master-led completions recorded in
`demo_check_phase7.md`'s deltas section: the `port_screen` facility-list
hotfix, the named-pirate drop grant (§4.11.13 had no owning task), the
orchestrator ui_strings merge, and the two staged-sim rulings.

| Gate | Result | Date |
|---|---|---|
| validator groups 1–10 | — | — |
| `build_world.py` / `build_routes.py` / `build_ocean.py` rebuild byte-identity | — | — |
| `sim_trade.py` gates 1–10 | — | — |
| test suites (`run_tests.py`) — count / checks | — | — |
| `godot --headless --quit-after 3` | — | — |
| day tick @ cap (ms, ≤ 75) / pursuit A* (ms, ≤ 250) | — | — |
| ui_strings keys zh/en parity | — | — |
| save size @ extreme (≤ 2 MB) | — | — |
