# 30 — Ports & Trade

## 1. Purpose & Phase

Specifies port facilities, the trade economy (price formulas, supply/demand,
investment), buy/sell quantity maths, and screen-by-screen UI flows for the
market, shipyard trade-adjacent actions, tavern, and inn. Gates Phase 1
(guild/palace are Phase 3 and only stub-marked here). Phase 6 added the
neutral-tier frontier markets (§4.1); Phase 7 (`IMPLEMENT-Phase7.md`)
replaces the Phase-5 drift-to-rest stock economy with the **flow economy**
(§4.2), re-pins demand events as consumption-rate surges (§4.5), and adds
allegiance & development (§4.9) plus the unified tariff & permits (§4.10).

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/port/port_screen.tscn` | port hub with facility menu |
| `scenes/port/market_screen.tscn` | goods buy/sell + provisions/water |
| `scenes/port/shipyard_screen.tscn` | buy/repair/refit/sell (rules in `40-*`) |
| `scenes/port/tavern_screen.tscn` | crew hire/fire, officer recruit |
| `scenes/port/inn_screen.tscn` | rest, harbor relief |
| `scripts/port/trade_engine.gd` | price + quantity maths (RefCounted) |
| `scripts/port/economy.gd` | stock, flow tick, tranche repricing, demand-event consumption surges (Phase 5, RefCounted; flow rework Phase 7) |
| `scripts/port/allegiance.gd` | port classes, ledgers, dev derivation, monthly counter-investment, treasuries, tariff/permit resolution (Phase 7) |
| `scripts/port/shipyard_engine.gd` | ship transactions |
| GameState keys | `port_investments` (per-port invested gold, saved), `current_port`, `market_stocks` / `market_events` (Phase 5, saved), `permits`, `port_allegiance` ({ledger, allegiance} per contestable port), `month_invested`, `nation_treasuries` (Phase 7, saved; shapes in `90-*` §8.2) |

## 3. Dependencies

`00-*`, `10-DATA-SCHEMA.md` (Port/Good schemas, locked lists), `20-*`
(provisions/water prices, port entry), `40-*` (capacity enforcement),
`50-*` (harbor relief conditions, reputation effects), `80-*` (widget
conventions), `90-*` (scene routing, save blocks).

## 4. Systems / Mechanics

### 4.1 Port facilities

Every `Port.facilities` key lists an activation phase (`10-*` §4.4):

| Facility | Phase | Function |
|---|---|---|
| market | 1 | buy/sell goods; buy provisions & water |
| shipyard | 1 | buy/repair/refit/sell ships (`40-*`) |
| tavern | 1 | hire/fire crew; recruit officers (`50-*`); Phase 3 adds the `Rumors` tab (`70-*` §4.4) |
| inn | 1 | rest (+morale), harbor relief odd jobs |
| guild | 3 | quest offers, discovery reports (`70-*` §4.2/§4.4); stub button disabled with label key `port.stub.phase3` before Phase 3 |
| palace | 3 | royal missions, titles, bounty payment, tournament entry, retirement (`70-*` §4.3/§4.5–§4.7); same stub (only at capital ports) |

The port hub lists facilities in fixed order: Market, Shipyard, Tavern, Inn,
Guild, Palace, plus a "Set Sail" button. Phase-3 facilities render as
disabled rows with the stub label until Phase 3 activates them; from Phase 3
on they are enabled (or replaced by `port.closed_bounty` on a bountied
nation's ports, `70-*` §4.9.6). Neutral ports (`nation_id: ""`, Phase 6,
`10-*` §7.1) run the standard market off their `produces`/`demands` flow
stock (§4.2). **Docking (Phase 7 amendment, `60-*` §4.11):** the Phase-6
"no NPC fleet serves a neutral port" pin is retired — traders of nation N
on **any of the 17 lanes** may dock at any port whose **effective alignment
== N** (protected own + contestable aligned to N, sovereign non-core and
neutral alike, §4.9); standing port-call rules (§4.4) are unchanged, and
every neutral port additionally receives ~1 nationless coaster regardless
of alignment (`60-*`).

### 4.1b Port hours (added 2026-11-02)

Facility opening hours are **data** (`data/facility_hours.json`,
`10-*` §4.19): a default table per facility plus optional per-port overrides.
The shipped defaults — uniform across all ports:

| Facility | Hours |
|---|---|
| market | 08:00–18:00 |
| shipyard | 08:00–18:00 |
| tavern | 10:00–24:00 |
| inn | 24h (always open) |
| guild | 08:00–18:00 |
| palace | 09:00–17:00 |

**Closed rule.** Entering a facility and starting each of its timed actions
both require the **current** time of day to be within the facility's window
(`SailingSim.facility_open`); an action started before closing may finish
after it (the "last order" reading — a 17:59 trade ends 18:59, a 18:01 trade
is refused). A closed facility renders its hub row disabled with the
`port.facility.closed` label carrying the `{open}–{close}` window; the port
Space wait (§4.3, +1h) is the way to wait for opening. The inn never closes,
so rest and odd jobs work at any hour.

**Action hour costs (pinned).** Every timed port action charges hours through
`SailingSim.advance_port_hours` after its effects apply (all-or-nothing: a
refused action charges nothing):

| Action | Hours |
|---|---|
| docking (`20-*` §4.11) | 1 |
| Set Sail (`20-*` §4.11) | 1 |
| port Space wait | 1 |
| market: buy / sell / buy supplies / invest | 1 each |
| shipyard: repair | 2 |
| shipyard: refit | 2 |
| shipyard: buy ship | 3 |
| shipyard: sell ship | 1 |
| tavern: crew hire / fire | 1 each |
| tavern: officer sign / dismiss | 1 each |
| palace: mission accept / report | 1 each |
| palace: repair bays | 2 |
| palace: invest / permit / bounty claim / title / tournament entry | 1 each |
| guild: quest accept / discovery report | 1 each |
| inn: odd job | 1 full day (unchanged) |
| inn: rest | 3 days → 08:00 (§4.7) |

### 4.2 Stock economy & price formulas

For `good` at `port`, prices are a function of the port-good's **stock**
(`economy.gd` owns stock state, the flow tick, and the factor;
`trade_engine.gd` keeps the price plumbing). All arithmetic is integer
per-thousand fixed point — factors are never floats — and each price is
floored exactly once, on the full product.

**Listing rule (Phase 7).** A port-good exists only if **listed**:

```
listed(port, good) = good ∈ port.produces ∪ port.demands
```

Only listed port-goods hold stock, render market rows, and transact —
player and NPC alike; unlisted goods vanish from the market entirely (a
behavior change from the Phase-5/6 list-everything market — correction 7
of `IMPLEMENT-Phase7.md`). The data rule
`demands ⊇ (staples ∖ port.produces)` (validator-asserted, `10-*` §4.2)
keeps every staple listed at every port. `produces ∩ demands = ∅`, so
every listed port-good is exactly one of a **producer** or a **consumer**.

**Stock & flow (Phase 7 flow economy — replaces the Phase-5
drift-to-rest, decision 17).** Every listed port-good holds an integer
stock, hard-clamped `0 … 200` per port-good (saved in
`GameState.market_stocks`, `90-*`). Once per day tick — after the ledger,
before `EventBus.day_advanced` (`20-*` §4.3); port day-advances (inn rest,
odd jobs) run it too — the flow tick moves each port-good's stock by its
real daily flow:

```
producer: stock += prod_rate × dev_mult   # clamped at capacity
consumer: stock −= cons_rate × dev_mult   # floored at 0 — unmet demand sits
```

A starved port cannot sell what it lacks: at stock 0 there is nothing for
the player to buy (the shortfall sits as unmet demand — no negative stock,
and the price stays inside the factor floor). **Tier rates**, read from
`goods.json` flags (`10-*` §7.2; validator pins the 12/16/12 split):
**staples 5/day, middle 3/day, luxuries 2/day** — one rate serves both
production and consumption unless the good's optional
`flow {prod, cons, capacity}` overrides it.

**Capacity.** By tier **160 / 140 / 120**, plus **+20 per dev level**
(§4.9), hard ceiling **200** (`STOCK_MAX` stays 200; the factor formula
and all integer price math stay exact).

**Dev multiplier on both rates.** dev 0/1/2/3 → ×1.0/×1.25/×1.5/×2.0,
integer math `rate × (4 + dev) / 4` (dev per §4.9).

**Initial stocks (new game).** Producers at capacity; consumers at **60**
(derived, no RNG).

**Market direction.** A producing port never buys its own produced goods —
the sell side is disabled there and marked **不收购**; buying requires
stock > 0 (falls out of the tranche walk, §4.4).

**Steady state (intended).** Producers at capacity (cheap), consumers
drained to 0 (dear) — the stable gradient. After a trade disturbs it,
stock recovers at the real flow rates; no rest target exists anymore.

**Price factor (exact).** The factor is an integer-linear function of
stock, in per-thousand units — unchanged from Phase 5 (only the stock
*trajectory* changed):

```
factor_units(port, good) = clamp(1500 − 5 × stock, 500, 2000)
```

The stock range maps `factor_units` into `[500, 1500]`, already inside the
price band; the `2000` bound is a safety net only.

**Price plumbing** (`trade_engine.gd`; integer division `/` throughout):

```
discount_units(port) = 1000 − min(100, port_investments[port] × 10 / 500)
combined_units       = clamp((factor_units × discount_units) / 1000,
                             500, 2000)
buy_price            = max(1, (base_price × combined_units) / 1000)
sell_price           = max(1, (base_price × combined_units × 8 × title_units)
                                / (1000 × 10 × 1000))
title_units          = 1100 | 1050 | 1000   # Phase 3, 70-* §4.9.2
```

`8/10` is the sell-side margin; every price is floored once on the full
product (`max(1, …)` guards the floor), never per multiplier. The Phase-7
tariff composes **after** this plumbing, on the transaction totals (§4.10).

- **Band interaction.** The stock factor lives inside the existing
  `[0.5, 2.0]` band: `factor_units` is band-bounded by construction, and
  `combined_units` re-clamps `factor × discount` to `[0.5, 2.0]`
  (`500–2000` per thousand) exactly as before, so the investment discount
  can never push a price outside the band.
- **Unchanged plumbing.** The tranche walk (§4.4), the 0.8 sell-side
  margin (arbitrage within one port is always a loss), the investment
  discount (§4.3), the title bonus, the `[0.5, 2.0]` price band, and the
  provisions/water exemption (fixed 2g and 1g, `20-*` §4.10, sell-back not
  offered) are all untouched by the flow economy — and the tariff composes
  after all of it (§4.10).
- **`title_bonus` (Phase 3, `70-*` §4.9.2)** multiplies the **sell** side only
  and only at ports of a nation where the player's title is knight or higher:
  1.05 at knight, 1.10 at baron/viscount/count/duke, 1.00 otherwise. It is a
  separate factor after the band clamp and is floored once with the rest of
  the product, so a title can never raise a sale above `2 × base_price × 0.8`.
  The multiplier used is the **port's own nation's** title, never another
  nation's.
- **Closed ports (Phase 3, `70-*` §4.9.6).** While the player holds a bounty
  from port's nation, the port's facility rows are all disabled
  (`port.closed_bounty`) and no facility screen opens — except the bountied
  nation's capital palace, which offers only `Pay bounty`. Pricing itself is
  unaffected (the market is simply unreachable).

### 4.3 Investment

- At the market: "Invest" button, fixed chunk 500g per click, permanent, per
  port, stored in `GameState.port_investments` (`{port_id: gold_total}`).
- Effect: 1% price discount (buy and sell) per chunk, cap 10% (5,000g) —
  the arithmetic is unchanged (§4.2 plumbing).
- **Ledger effect (Phase 7, decision 25).** At a **contestable** port each
  500g chunk also adds **+500g to the player-nation's ledger** there
  (§4.9); at a protected port the discount is the whole effect (no ledger).
- **Monthly cap (Phase 7, decision 26).** Player investment is capped at
  **≤ 2,000g per contestable port per month**, tracked in
  `GameState.month_invested` (`{port_id: gold}`, reset at the month tick,
  §4.9); the Invest button is **three-state** — available /
  allowance-exhausted / diplomacy-blocked — with the allowance hint
  (`market.invest_gate.*`, §4.8).
- **Diplomatic gate (Phase 7, decision 26).** Investing requires
  **rep ≥ 0** with the port's current alignment nation **and no active
  bounty from them** (§4.9; the same conditions that void permits, §4.10);
  unaligned contestable ports have no gate.

### 4.4 Tranche repricing & buy/sell maths

**Tranche repricing.** Every trade — buy or sell, player or NPC — moves
stock and reprices per **10-unit tranche**:

- A quantity `q` splits into `ceil(q / 10)` tranches of 10 units each (the
  last may be smaller).
- Each tranche transacts at the §4.2 price computed from the stock **before**
  the tranche applies: buying lowers stock (price rises per tranche),
  selling raises it (price falls per tranche).
- The market screen shows the **marginal (next-tranche) price** — what the
  *next* 10 units would cost or fetch. It equals the realized price of the
  first tranche only.
- The transaction total is the exact integer sum over tranches
  (`Σ price_t × units_t`), each tranche floored once on its full product;
  that summed total is what gold, the daily ledger, XP, and reputation book
  (`50-*` §4.3/§4.6) — never a per-tranche recomputation.
- Stock stops at its §4.2 hard-clamp: a walk larger than the range parks at
  the bound, and the price lands there continuously — no clamp jump.

**Listing rule (Phase 7).** Only §4.2's listed port-goods
(`port.produces ∪ port.demands`) transact — every walk, player or NPC,
runs on a listed port-good's stock; unlisted goods have no stock and no
rows. A producing port never buys its own produced good: the sell side is
disabled there (**不收购**, §4.2). The NPC candidate scopes below already
run produced → consumer sides, listed by construction; the Phase-7
docking widening for NPC traders is pinned in §4.1 (spec in `60-*`).

**Worked example — 300 wine sold into London** (wine ∈ `london.demands`,
stock 40 — the Phase-5 resting value; the §4.2 factor plumbing shown is
unchanged, `base_price` 30, no investment, no title; sell side):

| Tranche | Stock before | `factor_units` | Sell price | Stock after |
|---|---|---|---|---|
| 1 | 40 | 1300 | 31 | 50 |
| 2 | 50 | 1250 | 30 | 60 |
| 3 | 60 | 1200 | 28 | 70 |
| 4 | 70 | 1150 | 27 | 80 |
| 5 | 80 | 1100 | 26 | 90 |
| 6 | 90 | 1050 | 25 | 100 |
| 7 | 100 | 1000 | 24 | 110 |
| 8 | 110 | 950 | 22 | 120 |
| 9 | 120 | 900 | 21 | 130 |
| 10 | 130 | 850 | 20 | 140 |
| 11 | 140 | 800 | 19 | 150 |
| 12 | 150 | 750 | 18 | 160 |
| 13 | 160 | 700 | 16 | 170 |
| 14 | 170 | 650 | 15 | 180 |
| 15 | 180 | 600 | 14 | 190 |
| 16 | 190 | 550 | 13 | 200 |
| 17–30 | 200 (clamped) | 500 | 12 | 200 |

16 distinct prices before the stock clamp, reached continuously (13 → 12,
no jump). Proceeds = 10 × (31+30+28+27+26+25+24+22+21+20+19+18+16+15+14+13)
+ 14 × 120 = 3 490g + 1 680g = **5 170g** — against 9 300g at the displayed
31g flat, which is exactly why the marginal display matters. Buying walks
the same ladder upward: 30 wine bought at Lisbon (produced, stock 160 at
its capacity) pays `factor_units` 700/750/800 → 21g/22g/24g
(stock 160 → 130).

**Player quantity maths** (picker rules unchanged from T12):

- Quantity picker: 1 / 10 / 100 / Max buttons + direct numeric entry
  (validation per `80-*` dialog rules).
- **One picker per row** serves both the Buy and Sell buttons (the §4.8
  wireframe has a single Qty column). Its live clamp is the *physical* range —
  the pooled free hold, or the held quantity when that is larger (so a full
  hold can always be emptied). Each button then validates against its own
  maximum, and an entry the purse cannot cover is a disabled button with the
  price reason, not a silently rewritten field. `Max` selects that same
  physical ceiling.
- Buy max = the largest quantity whose **full tranche walk** the purse can
  pay and `free_capacity` can hold (`40-*` §capacity) — computed by walking
  tranches, since the marginal price alone no longer decides it.
- Sell max = held quantity. Partial sells allowed.
- A stock-moving trade emits `EventBus.market_changed(port_id)` (`90-*`).
- Transaction errors (insufficient gold/capacity/quantity) show the shared
  error toast (`80-*`) and change nothing. In this screen the "shared error"
  presentation is the disabled button plus its tooltip reason (§4.8); no
  modal dialog is raised for a rejected trade, so a stray click never spams
  dialogs (§6 "no dialog spam").

**NPC port-call caps.** An NPC fleet loads or unloads ≤ **30 units of one
good per call** — 1–3 tranches for the walk. Coasters are smaller: hold
≤ 10 units total, ≤ 5 units traded per call.

**NPC purchase-volume bounds.** A trader buys at most
`min(30-unit cap, free hold, saturation bound)`, where the saturation bound
keeps **every projected sale tranche at the destination** transacting above
`factor_units 1000`: the fleet steps its quantity down by tranches until
the projected post-trade stock at P stays below the factor-1.0 stock, so it
can never self-saturate its own market.

**Trader decision (joint, profit-per-day).** At each port call a trader
picks one (good, destination) jointly by argmax of:

```
score(good, P) = (est_sell_price(P, good) − buy_price) × qty × spec_mult × noise × risk
                 ────────────────────────────────────────────────────────────────────
                                  lane_days(A → P) + 2 dwell days
```

- **Candidates:** the argmax runs over the nation's **produced** goods ×
  candidate destinations — own-nation ports within Chebyshev ≤ 120 of A,
  wrap-aware (Phase-6 grid sweep: 60 → 120 — nm semantics preserved at
  12 tiles/degree, 5 nm tiles). No cross-nation reach, no forecasting, no global
  coordination: cross-nation arbitrage stays the player's protected profit
  space by construction.
- **`est_sell_price(P, good)`** is the live §4.2 sell-side price at P's
  current stock — the same plumbing the market screen shows.
- **`buy_price`** is the §4.2 buy price at A (the good is own-nation
  produced, so A always buys on the produced side).
- **Specialty:** `spec_mult = 1.5` for the fleet's `specialty: good_id`,
  drawn once at spawn from the nation's produced goods (fleet seed) and
  persisted; a fleet predating the field draws lazily from its own seed
  (no data migration).
- **Noise:** seeded ×`0.8 … 1.25`, redrawn from the fleet's stream at every
  decision.
- **Risk:** ×`0.5` if any hostile fleet lies within Chebyshev 5 of a sample
  point of the candidate lane path, else ×`1.0` — one bucket-index query
  per sample, deterministic (`60-*`).
- **Sell rule:** sell cargo only where `factor > 1.0`; else pick the next
  candidate — never sell into a saturated market.
- **Not implemented (doc-only Phase-6 lever):** the sub-linear volume knob
  `round(30/√preset)` — a per-preset scaling of the port-call cap; recorded
  as a balance candidate only.

### 4.5 Demand events

Demand events are timed **consumption-rate surges** that create tradeable
shortages. Phase 7 re-pin (decision 17 / correction 9 of
`IMPLEMENT-Phase7.md`): the Phase-5 rest-override semantics are retired —
an event now **triples consumption** for its duration. The atomic
`market_events.json` + code + validator transition is task K's (W3); the
validator's group-7 event checks are untouched until then. Data lives in
`data/market_events.json` (~8 templates; full schema and validator rules
in `10-*` §4.13):

```
{"id", "scope": "port", "cadence_days", "duration_days",
 <rate_override naming the surged goods>, "name": {zh, en}}
```

The Phase-5 `shifts` delta object is re-pinned as a **rate override**
naming the goods whose consumption is surged; the exact envelope lands
with K's transition.

- **Effect.** While a port's event is active, each overridden good's
  **consumption rate is ×3** for `duration_days` — then the normal flow
  rate (§4.2) resumes. Production, capacities, other tier rates, and the
  price formula are untouched: an event is a temporary rate-override
  inside `economy.gd` (pure), with the rotation/expiry hook there.
- **Template families (locked; authored as data):** seasonal cycles —
  winter wool/furs, summer wine; one-off surges — harvest festival; war
  provisioning at a capital; plague. The Phase-5 shift magnitudes are
  re-authored as ×3 consumption overrides over the families' goods in K's
  transition; overrides reference existing `goods.json` ids, and the
  group-7 event-shape check pins the override shape (`10-*` §8.2).
- **Budget & schedule.** ≤ **1 active event per nation**, ≤ **4
  world-wide**. The schedule is seeded per template × cadence window
  (formula family), so runs replay exactly; active instances are saved in
  `GameState.market_events` (`90-*`).
- **Task-L rotation pins (the details §4.5 left to the task):** the
  rotation is `Economy.market_events_tick(day)`, run **inside the economy
  day step** (`Economy.day_tick`, after the ledger and before
  `day_advanced` — `20-*` §4.3; port day-advances share the path), once
  per day: expiries first (`day ≥ start + duration` — the duration comes
  from the template, so the instance stays the pinned
  `{template_id, port_id, start_day}` of `10-*` §4.15), then each
  template whose seeded fire day is today. Cadence window
  `w = ⌊(day − 1) / cadence_days⌋`; the fire day and the affected port
  (uniform over `ports.json`) draw from the §4.11.1 formula family salted
  by `(window, template index, template id)` — a budget-blocked start is
  **skipped, never deferred**. Activation appends the instance and applies
  each overridden good's **×3 consumption rate** until `start + duration`;
  a load re-applies every active instance's override
  (`Economy.ensure_event_overrides`, called from the save `_apply`) before
  any port screen can price against them. Demand events are market
  weather, independent of the fleet density dial.
- **Telegraph.** On start, a tavern rumor row appears in the affected
  region's ports (`ui_strings.json`, zh/en) — information is profit.
- **Self-limiting by emergence.** NPC traders' §4.4 sell rule swarms the
  inflated port and partially refills the shortage on its own; events are
  never clamp-pinned.

### 4.6 Tavern: crew hire/fire

- Hire: 1-click buttons "+1 / +10 / Fill"; cost = `crew_wage_daily × 10` per
  head as signing bonus (locked: 2 × 10 = 20g/head). Hard cap: flagship
  `crew_max` (Phase-1 fleet = flagship only for crew; multi-ship crew OUT OF
  SCOPE (phase 2)). Each hire/fire charge costs 1 hour (§4.1b).
- Fire: "−1 / −10 / Down to min" buttons; cannot go below `crew_min`; fired
  crew leaves with no severance; morale unchanged.
- Officer recruiting UI and rules live in `50-*` §officers; the tavern screen
  hosts that panel under a second tab. Signing or dismissing an officer costs
  1 hour (§4.1b).

### 4.7 Inn: rest & harbor relief

- **Rest (amended 2026-11-02):** button "Rest 3 days", cost `10g × 3 = 30g`;
  the clock advances by exactly `Δ = 10/3 − clock_fraction` days
  (`20-*` §4.3), so the run wakes on **day + 3 at 08:00** whatever the
  arrival hour, and exactly **three** ledger days charge (wages still paid)
  with the in-port morale delta (+5/day, cap 80, `20-*` §4.8.1). The inn is
  open 24h (§4.1b), so rest is offered at any time.
- **Harbor relief (odd jobs):** visible only when the `10-*` §5 condition
  holds (`gold < 100` and fleet empty). Button "Work an odd job":
  `gold += 100`, one ledger day passes. Strings `inn.odd_job.offer`,
  `inn.odd_job.result`.

### 4.8 UI flows (textual wireframes)

Full widget/sizing conventions in `80-*`; these define content and
interactions per screen.

#### Port hub (`port_screen`)

```
+--------------------------------------------------------------+
| <Port name>  ·  <Nation name>      Day 12 · 7,830g             |
+--------------------------------------------------------------+
| "<flavor line>"                                              |
|                                                              |
|  [ Market ]   [ Shipyard ]                                   |
|  [ Tavern ]   [ Inn    ]                                     |
|  [ Guild — opens in Phase 3 ]  (disabled)                    |
|  [ Palace — opens in Phase 3 ] (disabled, capitals only row) |
|                                                              |
|  [ Set Sail ]                                                |
+--------------------------------------------------------------+
```

Interactions: click a facility → route to its screen; Esc from a facility
returns here; Set Sail → `20-*` §4.11 exit.

#### Market (`market_screen`)

```
+------------------------------------------------------------------------------+
| Market — <Port>       Gold 7,830g · Hold 34/120 · 势力内 5%           [Back] |
+------------------------------------------------------------------------------+
| 特产: 小麦, 葡萄酒                                                            |
| Good        | Stock | Trend | Marginal buy/sell | You have | Qty   | [Buy][Sell]|
| ★ Wheat     |  160  |  ↑    |    8g / —         |    0     | [ 10 ]| [Buy][不收购]|
| ... listed-goods rows only (produces ∪ demands), scrollable ...              |
+------------------------------------------------------------------------------+
| Supplies: Provisions 2g [  ___ ][Buy]   Water 1g [ ___ ][Buy]                 |
| [ Invest 500g ]  invested here: 1,500g (−3%)                                  |
+------------------------------------------------------------------------------+
```

Rows are the **per-port listed set** — `port.produces ∪ port.demands`
only (§4.2); unlisted goods render no row at all (a behavior change from
the Phase-5/6 all-20-goods market — correction 7). **★** marks
`port.produces` rows and the `特产:` header line names up to 3 of them
(`market.specialty.*`); the Sell button is disabled with **不收购** on
those rows (§4.2 market direction). Exclusive 专营货 rows render for
everyone but stay grayed with the lock note until dev ≥ 2 at a port
aligned to the player's nation (§4.9). **Trend**
(`market.stock.trend_up` / `market.stock.trend_down`) shows the §4.2
flow direction — produced rows rebuild toward capacity, demanded rows
drain toward 0 (the rest-relative blank state is gone with rest itself).
The header badge shows the tariff state — 势力内 5% / 免税 / 外国 20% /
未同盟 20% — and each buy/sell action adds the tax on a **separate
displayed line** (`market.tax.*`, §4.10). Rows sorted by `base_price`
ascending. **Stock** (0–200) comes from the §4.2 flow economy;
**Marginal buy/sell** is the next-tranche price (§4.4), the price the
shown quantity actually starts at (per `80-*` §4.7.7). Buy/Sell disabled
with tooltip-reason when unaffordable/over capacity/qty 0/不收购. The
**Invest** button is three-state (§4.3): available /
allowance-exhausted (month hint) / diplomacy-blocked
(`market.invest_gate.*`). Successful trade flashes the gold readout (per
`80-*` feedback rules) and emits `gold_changed` + `fleet_changed` +
`market_changed`.

#### Tavern (`tavern_screen`)

Tab row: `Crew | Officers` in Phase 1–2; Phase 3 adds a third tab
`Rumors` (`70-*` §4.4, `80-*` §4.7.3).

- Crew tab: current crew `n / crew_max`, morale tier label, hire/fire buttons
  (§4.6), cost preview "20g per head".
- Officers tab: list of officers recruitable at this port
  (`Officer.recruit_ports`), each row: name, role, stats line, daily wage,
  bio; `Recruit` button (rules incl. one-time hire in `50-*`). Below: current
  officers with a `Dismiss` button.
- Rumors tab (Phase 3): up to three hint rows for unfound discoveries at
  100g each (`70-*` §4.4).

#### Inn (`inn_screen`)

- Status box: morale, days-since? none. Buttons: `[Rest 3 days — 30g]`,
  `[Work an odd job — +100g]` (only when eligible, §4.7), else a disabled
  greyed button with reason key `inn.odd_job.ineligible`.

#### Guild (`guild_screen`, S12, Phase 3)

```
+--------------------------------------------------------------+
| Guild — <Port>            Gold 7,830g · Fame 480      [Back] |
+--------------------------------------------------------------+
| Offers (refresh in 3 days)                                   |
| [Delivery] Timber for Tunis   40 × timber → Tunis  20d  1,200g|
| [Bounty]   Hunt the Sea Wolf  tier 2               30d 10,000g|
| [Explore]  Rumour of the Cedars                    30d       |
|                                        [Accept] [Hint]        |
+--------------------------------------------------------------+
| Reports                                                       |
| Cedars of the Atlas  [Report — 2,000g · +150 fame]            |
+--------------------------------------------------------------+
```

- Offers refresh whenever `day // 7` changes (§`70-*` §4.9.3); a `Rumors`-bought
  hint shows inline in an exploration offer row.
- `Accept` on a delivery quest takes the goods from the pool and refuses with
  `quest.no_hold`/`quest.slots_full` where applicable. `Report` is present
  only while an unreported discovery exists (`guild.report.none` otherwise).

#### Palace (`palace_screen`, S13, Phase 3; capital ports only)

```
+--------------------------------------------------------------+
| Palace — <Port> · <Nation>    Rep 42 · Fame 480       [Back] |
+--------------------------------------------------------------+
| Your title: Baron          [Attend ceremony — Viscount]       |
| Royal mission:  Deliver the King's dispatches   [Accept]      |
| Bays: [Repair fleet — 20% off]                                |
| Bounty: none                                                  |
| Tournament: Lisbon, day 1 of this cycle   [Enter — 1,000g]    |
| Retire (Duke only)                                            |
+--------------------------------------------------------------+
```

- The mission row is disabled below `rep ≥ 30` (`palace.rep_locked`) and while
  a mission of that nation is already active (`palace.mission_active`).
- `Attend ceremony` appears only when both ladder requirements are met
  (`70-*` §4.9.2); `Retire` only at duke.
- With an active bounty from this nation, every row except `Pay bounty`
  (`bounty.pay`) and `Leave` is replaced by `port.closed_bounty`.

### 4.9 Allegiance & development (Phase 7)

Every port is one of two classes (decision 25, `IMPLEMENT-Phase7.md`
§2.4). `ports.json` carries `protected: true`, the authored `dev` floor,
and — per contestable port — `sphere: [nation_ids]` (`10-*` §4.4).
Runtime state is save v7 (`90-*` §8.2):
`port_allegiance {port_id: {ledger, allegiance}}` (dev is **derived**,
never saved; `allegiance` is persisted because the tie rule keeps the
incumbent), `month_invested {port_id: gold}`, and
`nation_treasuries {nation_id: gold}`.

**Protected ports** (≤ 4 per nation; validator: protected ⊇ the 6
capitals, ≤ 4 per nation, never a ledger):

- The set (decision 25): portugal {lisbon, oporto}; spain {seville,
  cadiz, valencia, barcelona}; england {london, plymouth}; holland
  {amsterdam, antwerp}; ottoman {istanbul, athens, smyrna}; italy
  {venice, genoa, naples, palermo}.
- Mechanics: alignment = owner **permanently**; investment =
  discount-only (the standing §4.3 behavior, no ledger effect); dev =
  authored floor, never grows (capitals stay dev 3 forever).

**Contestable ports** (everything else — sovereign non-core + all 45
neutral ports):

- **Ledger & allegiance.** `ledger {nation_id: gold}`, cumulative per
  nation. Allegiance = strictly the highest **effective** ledger with
  effective ≥ **5,000g**; effective = raw except the sovereign owner's
  **× 1.25** (integer `ledger × 5 / 4`); ties keep the incumbent; below
  5,000g effective → unaligned.
- **Starting state is the only sovereign/neutral difference:** a
  contestable sovereign begins `{owner: 6,000}` (allied, above the line,
  below dev-1's 10,000g); a neutral begins empty.
- **Development = max(authored floor, ledger thresholds)** — derived at
  load and on every ledger change: dev 1 at ≥ **10,000g** total ledger,
  dev 2 ≥ **25,000g**, dev 3 ≥ **50,000g**. Floors (authored `dev` in
  `ports.json`): capitals/protected **3**; sovereign contestable major
  **2**, rest **1**; neutral **0**.
- **Player investment** (§4.3): the 500g chunk buys the standing 1%/chunk
  discount, cap 10%, **and** adds +500g to the player-nation ledger there.
- **Flip-campaign rules (decision 26):**
  - **Monthly cap:** ≤ **2,000g** player investment per contestable port
    per month; three-state Invest button with hint (`market.invest_gate.*`).
  - **Home advantage:** the sovereign owner's ledger counts **× 1.25**
    in the allegiance comparison (a mature foreign sovereign port needs
    > 7,500 effective value; neutrals have no owner, no bonus).
  - **Diplomatic gate:** investing requires **rep ≥ 0** with the port's
    current alignment nation **and no active bounty from them** (the
    §4.10 permit-void conditions) — wanted pirates cannot buy ports;
    unaligned contestable ports have no gate.
  - **Poaching rep hit:** the player's nation **gaining** a foreign
    sovereign port costs the player **−5 rep** with its previous owner
    (one-time per flip; none on losing it back).

**NPC counter-investment (monthly, deterministic).** On day 1 of each
30-day month, each AI nation invests in **0–2 sphere ports** (spheres may
include foreign contestable sovereigns), seeded
`seed = month_index × 1000003 + nation_ordinal × 7919 + port_ordinal × 104729`,
`spend = min(treasury, 1500)` per pick, weighted toward ports on/adjacent
to their lanes and away from ports they already hold at dev 3. Protected
ports are never AI-investable.

**Telegraph (decision 24).** Each investment lands as a tavern rumor row
`{nation} 在 {port} 投资 {amount}g`, visible **30 days** in taverns of
the invested port's **band** (same plumbing family as `economy.gd`
`event_telegraphs`); `Allegiance.last_month_investments()` exposes the
month's rows.

**Nation treasuries (runtime, save v7).** Start **5,000g** each; monthly
income = **1,000g** baseline + **all tax** collected at their ports and
allied ports (player and NPC trades alike, §4.10) + **permit sales**;
NPC-sourced tax capped **2,000g/nation/month**; spend only on
counter-investment. No decay, no other sinks this phase.

**Month-tick ordering (pinned in `90-*`).** The day ledger calls
`Economy.day_tick` first (stock movement + event bookkeeping — existing
position), then, on a month boundary, `allegiance.month_tick()` — which
resets `month_invested`, credits baseline income, resolves
counter-investment, and refreshes telegraph windows. One seam, one owner.

**Effects ladder** (both port classes; alignment = allegiance at
contestable, owner at protected; rates/capacity per §4.2):

| dev | flow rates | capacity | extras |
|---|---|---|---|
| 1 | ×1.25 | +20 | — |
| 2 | ×1.5 | +40 | 专营货 rows activate for the alignment nation |
| 3 | ×2.0 | +60 (ceiling 200) | contestable ports only: patrol umbrella (alignment-nation escort patrols extend, spoke ≤ 40 tiles; hunters cannot camp it; mechanics in `60-*`) |

Ship/equipment tier availability follows dev via the universal tier
filter (`40-*`) — no per-level ladder entries.

### 4.10 Tax & permits (Phase 7)

**Unified tariff (decisions 19/20) — one rule for everyone.** Effective
alignment == trader's nation → **5%** on buy cost **and** sell proceeds;
otherwise **20%**. Effective alignment = owner at protected, allegiance
at contestable (§4.9). Unallied contestable ports tax **20% forever** —
no permit can ever exempt them (no palace to buy one at). Nationless
coasters are exempt (no host to pay). Provisions/water exempt (the
standing §4.2 rule). Tax applies **after** all existing price math —
band, margin, tranches, discount, title bonus, all untouched (§4.2/§4.4)
— on the transaction totals, and shows as a **separate displayed line**
(`market.tax.*`).

**Permits (two kinds):**

- **本国免税证 (home charter):** **5,000g**, own palaces only, **no
  title/rep gate** (the early gold sink); covers every port whose
  effective alignment == the player's nation (protected own + aligned
  contestable), 5% → **0%**.
- **涉外免税证 (foreign permit):** per nation, that nation's palaces,
  **20,000g**, title ≥ **Knight**, rep ≥ **+20**; covers that nation's
  protected + aligned contestable ports.
- Both are **void** while that nation's bounty is held or rep < **−20**;
  re-buy at full price. State:
  `GameState.permits {home: bool, foreign: {nation_id: bool}}` (save v7,
  `90-*` §8.2).

**Treasury flow (decision 19 — tax-only, no profit accounting).** Every
tax coin flows to the port's effective-alignment nation (player and NPC
alike); permit purchases flow to the selling nation; NPC-sourced tax is
capped 2,000g/nation/month (§4.9 treasuries); the player's home-sphere
5% funds their own nation's counter-investment.

**UI.** Market header badge — 势力内 5% / 免税 / 外国 20% / 未同盟 20%
— plus a tax line on each side of the trade dialog (`market.tax.*`,
§4.8).

## 5. Data Examples

All examples are computed at Phase-5 resting stock (that economy is
retired by the §4.2 flow economy in Phase 7); the §4.2 price plumbing
they exercise — factor-from-stock, tranches, band, margin, title bonus —
is unchanged, so the arithmetic stands as written. `factor` shown is
`factor_units / 1000`; arithmetic per §4.2, integer division.

A worked trade at rest (Lisbon buys its `produces` good wine):

```json
{
  "port": "lisbon",
  "good": "wine",
  "stock": 160,
  "base_price": 30,
  "factor_units": 700,
  "factor": 0.7,
  "investment_discount": 1.0,
  "buy_price": 21,
  "sell_price": 16,
  "note": "rest 160: 1500 − 5×160 = 700 → 0.7; buy (30×700)/1000 = 21; sell (30×700×8)/10000 = 16"
}
```

Selling at London at rest (wine ∈ `london.demands`):

```json
{
  "port": "london",
  "good": "wine",
  "stock": 40,
  "base_price": 30,
  "factor_units": 1300,
  "factor": 1.3,
  "buy_price": 39,
  "sell_price": 31,
  "note": "rest 40: 1500 − 5×40 = 1300 → 1.3; buy (30×1300)/1000 = 39; sell (30×1300×8)/10000 = 31; route Lisbon→London nets 10g/unit at rest, before costs"
}
```

A neutral port at rest (wine ∉ `valencia.produces`/`demands`):

```json
{
  "port": "valencia",
  "good": "wine",
  "stock": 100,
  "base_price": 30,
  "factor_units": 1000,
  "factor": 1.0,
  "buy_price": 30,
  "sell_price": 24,
  "note": "rest 100: 1500 − 5×100 = 1000 → 1.0; buy 30; sell (30×1000×8)/10000 = 24"
}
```

Phase-3 title bonus (same London sale at rest, player is baron of England):

```json
{
  "port": "london",
  "good": "wine",
  "stock": 40,
  "base_price": 30,
  "factor_units": 1300,
  "factor": 1.3,
  "investment_discount": 1.0,
  "title_bonus": 1.1,
  "buy_price": 39,
  "sell_price": 34,
  "note": "(30×1300×8×1100)/(1000×10×1000) = 34.32 → 34; the bonus is sell-side only"
}
```

A displaced-stock trade (sell 100 wine into London from rest, per §4.4):

```json
{
  "port": "london",
  "good": "wine",
  "base_price": 30,
  "before": {"stock": 40, "factor_units": 1300, "marginal_sell": 31},
  "trade": "sell 100 → 10 tranches",
  "tranche_sell_prices": [31, 30, 28, 27, 26, 25, 24, 22, 21, 20],
  "proceeds": 2540,
  "after": {"stock": 140, "factor_units": 800, "factor": 0.8,
            "marginal_sell": 19, "buy_price": 24},
  "drift_10_days": {"stock": 120, "factor_units": 900, "sell": 21, "buy": 27},
  "note": "proceeds 10×(31+30+28+27+26+25+24+22+21+20) = 2540 vs 3100 flat; wine is tier idx 9 (middle, ±2/day), so 140 drifts toward rest 40 at 2/day"
}
```

## 6. Edge Cases & Fail States

- **Buy 0 / empty quantity field** → button disabled; no dialog spam.
- **free_capacity = 0** → all Buy buttons disabled with reason `market.hold_full`.
- **Selling the last unit** → allowed; row updates to 0.
- **Investment cap reached** → Invest button disabled, shows cap string.
  Monthly allowance exhausted or the diplomatic gate blocking → same
  disabled-with-reason presentation (`market.invest_gate.*`, §4.3/§4.9).
- **gold exactly equals cost** → allowed (gold becomes 0; harbor-relief
  safety net only applies when shipless, so 0-gold-with-ship is valid).
- **Firing below crew_min** → "Down to min" stops at `crew_min`; −1/−10 clamp
  likewise.
- **Officer recruited, save, load** → officer appears in roster, not in the
  tavern list again (persistence via `50-*` player block).
- **Entering port during dialog** — impossible; modals block navigation
  (`90-*` §11).

## 7. Acceptance Criteria

- [ ] Worked examples in §5 reproduce exactly when computed by
      `trade_engine.gd` (unit test asserts 21/16 at Lisbon, 39/31 at London,
      and 39/34 at London with a baron's `title_bonus`).
- [ ] Adding a new good to `goods.json` adds a working market row at every
      port that lists it (`port.produces ∪ port.demands`, §4.2) with zero
      code edits (architecture rule, `90-*` §12).
- [ ] Investment: 10 clicks (5,000g) caps discount at 10%; 11th click
      impossible.
- [ ] Provisions/water rows ignore produces/demands/investment everywhere.
- [ ] Tavern hire cost is 20g/head and respects `crew_max`; fire respects
      `crew_min`.
- [ ] Harbor-relief button appears iff `gold < 1200` and fleet empty, and
      grants exactly +100g/+1 day.
- [ ] All wireframe labels resolve through `ui_strings.json` keys listed in
      `80-*` §string inventory.
- [ ] A bountied nation's port hub disables every facility row except the
      capital's `Pay bounty` row (`70-*` §4.9.6).
