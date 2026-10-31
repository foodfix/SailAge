# 30 — Ports & Trade

## 1. Purpose & Phase

Specifies port facilities, the trade economy (price formulas, supply/demand,
investment), buy/sell quantity maths, and screen-by-screen UI flows for the
market, shipyard trade-adjacent actions, tavern, and inn. Gates Phase 1
(guild/palace are Phase 3 and only stub-marked here).

## 2. Artifacts

| Path | Contents |
|---|---|
| `scenes/port/port_screen.tscn` | port hub with facility menu |
| `scenes/port/market_screen.tscn` | goods buy/sell + provisions/water |
| `scenes/port/shipyard_screen.tscn` | buy/repair/refit/sell (rules in `40-*`) |
| `scenes/port/tavern_screen.tscn` | crew hire/fire, officer recruit |
| `scenes/port/inn_screen.tscn` | rest, harbor relief |
| `scripts/port/trade_engine.gd` | price + quantity maths (RefCounted) |
| `scripts/port/economy.gd` | stock, tier drift, tranche repricing, demand-event rest overrides (Phase 5, RefCounted) |
| `scripts/port/shipyard_engine.gd` | ship transactions |
| GameState keys | `port_investments` (per-port invested gold, saved), `current_port`, `market_stocks` / `market_events` (Phase 5, saved; shapes in `90-*`) |

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
nation's ports, `70-*` §4.9.6).

### 4.2 Stock economy & price formulas

For `good` at `port`, prices are a function of the port-good's **stock**
(`economy.gd` owns stock state, drift, and the factor; `trade_engine.gd`
keeps the price plumbing). All arithmetic is integer per-thousand fixed
point — factors are never floats — and each price is floored exactly once,
on the full product.

**Stock & resting stock.** Every port-good holds an integer stock,
hard-clamped `0 … 200` per port-good (saved in `GameState.market_stocks`,
`90-*`). Resting stock derives from `ports.json` with the same precedence
as the retired static factors — zero new content data:

```
rest(port, good) = 160  if good ∈ port.produces
                    40  else if good ∈ port.demands
                    100 otherwise
```

`new_game` initializes every port-good at its rest (derived, no RNG).

**Price factor (exact).** The factor is an integer-linear function of
stock, in per-thousand units, replacing the retired static 0.7/1.3/1.0
factors:

```
factor_units(port, good) = clamp(1500 − 5 × stock, 500, 2000)
```

At resting stock it equals them exactly: produced 700 (0.7), demanded 1300
(1.3), neutral 1000 (1.0). The stock range maps `factor_units` into
`[500, 1500]`, already inside the price band; the `2000` bound is a safety
net only.

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
product (`max(1, …)` guards the floor), never per multiplier.

- **Band interaction.** The stock factor lives inside the existing
  `[0.5, 2.0]` band: `factor_units` is band-bounded by construction, and
  `combined_units` re-clamps `factor × discount` to `[0.5, 2.0]`
  (`500–2000` per thousand) exactly as before, so the investment discount
  can never push a price outside the band.
- **Unchanged plumbing.** The 0.8 sell-side margin (arbitrage within one
  port is always a loss), the investment discount (§4.3), the title bonus,
  the price band, and the provisions/water exemption (fixed 2g and 1g,
  `20-*` §4.10, sell-back not offered) are all untouched by the stock
  economy.
- **Consumption tiers.** Drift rates derive at load from `goods.json`
  (zero new data): rank all 20 goods by (`base_price` asc, `id` asc);
  indices 0–4 are **staples** (drift ±3/day), 5–14 **middle** (±2/day),
  15–19 **luxuries** (±1/day). The validator asserts the 5/10/5 split.
- **Daily drift.** Once per day tick — after the ledger, before
  `EventBus.day_advanced` (`20-*` §4.3); port day-advances (inn rest, odd
  jobs) run it too — each port-good's stock moves one tier step **toward
  its rest**, never past it, clamped to the stock range. A demand event
  temporarily overrides the rest target itself (§4.5).
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
- Effect: 1% price discount (buy and sell) per chunk, cap 10% (5,000g).
- Phase 1 has no development/unlock reward — the discount is the whole
  effect. Wider effects (investment → demand growth) remain a Phase-6
  candidate (`IMPLEMENT-Phase5.md`, out-of-scope list).

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

**Worked example — 300 wine sold into London** (wine ∈ `london.demands`,
rest stock 40, `base_price` 30, no investment, no title; sell side):

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
the same ladder upward: 30 wine bought at Lisbon (produced, rest 160) pays
`factor_units` 700/750/800 → 21g/22g/24g (stock 160 → 130).

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
  candidate destinations — own-nation ports within Chebyshev ≤ 60 of A,
  wrap-aware. No cross-nation reach, no forecasting, no global
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

Demand events are timed rest-overrides that create tradeable surges and
shortages. Data lives in `data/market_events.json` (~8 templates; full
schema and validator rules in `10-*`):

```
{"id", "scope": "port", "cadence_days", "duration_days",
 "shifts": {"good_id": ±n}, "name": {zh, en}}
```

- **Effect.** While a port's event is active, each shifted good's §4.2 rest
  target is overridden: `rest += shift`, the result clamped `[10, 190]`,
  for `duration_days` — then the derived rest resumes. Drift rates and the
  price formula are untouched: an event is a temporary rest-override table
  inside `economy.gd` (pure), with the rotation/expiry hook there.
- **Template families (locked; authored as data):** seasonal cycles —
  winter wool/furs, summer wine; one-off surges — harvest festival; war
  provisioning at a capital — −30 timber/cannons for 60 days; plague =
  halved demand. `shifts` reference existing `goods.json` ids; the
  validator asserts each template's worst-case rest after the shift stays
  inside the effect clamp above.
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
  **skipped, never deferred**. Activation appends the instance and writes
  each shifted good's rest override
  (`rest += shift`, clamped `[10, 190]`, until `start + duration`); a
  load re-applies every active instance's overrides
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
  SCOPE (phase 2)).
- Fire: "−1 / −10 / Down to min" buttons; cannot go below `crew_min`; fired
  crew leaves with no severance; morale unchanged.
- Officer recruiting UI and rules live in `50-*` §officers; the tavern screen
  hosts that panel under a second tab.

### 4.7 Inn: rest & harbor relief

- **Rest:** button "Rest 3 days", cost `10g × 3 = 30g`; each rest day runs
  the daily ledger (wages still paid) and applies the in-port morale delta
  (+5/day, cap 80, `20-*` §4.8.1).
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
| Market — <Port>            Gold 7,830g · Hold 34/120                  [Back]|
+------------------------------------------------------------------------------+
| Good        | Stock | Trend | Marginal buy/sell | You have | Qty   | [Buy][Sell]|
| Wheat       |  160  |  —    |    8g / 6g        |    0     | [ 10 ]| [Buy][Sell]|
| ... 20 rows, scrollable ...                                                   |
+------------------------------------------------------------------------------+
| Supplies: Provisions 2g [  ___ ][Buy]   Water 1g [ ___ ][Buy]                 |
| [ Invest 500g ]  invested here: 1,500g (−3%)                                  |
+------------------------------------------------------------------------------+
```

Rows sorted by `base_price` ascending. **Stock** (0–200) and **Trend**
(`market.stock.trend_up` when below rest, `market.stock.trend_down` when
above, blank at rest) come from the §4.2 stock economy; **Marginal
buy/sell** is the next-tranche price (§4.4), the price the shown quantity
actually starts at (per `80-*` §4.7.7). Buy/Sell disabled with
tooltip-reason when unaffordable/over capacity/qty 0. Successful trade
flashes the gold readout (per `80-*` feedback rules) and emits
`gold_changed` + `fleet_changed` + `market_changed`.

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

## 5. Data Examples

All examples at Phase-5 resting stock unless noted (`factor` shown is
`factor_units / 1000`; arithmetic per §4.2, integer division).

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
- [ ] Adding a new good to `goods.json` adds a working market row with zero
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
