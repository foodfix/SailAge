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
| `scripts/port/shipyard_engine.gd` | ship transactions |
| GameState keys | `port_investments` (per-port invested gold, saved), `current_port` |

## 3. Dependencies

`00-*`, `10-DATA-SCHEMA.md` (Port/Good schemas, locked lists), `20-*`
(provisions/water prices, port entry), `40-*` (capacity enforcement),
`50-*` (harbor relief conditions, reputation effects), `80-*` (widget
conventions), `90-*` (scene routing).

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

### 4.2 Price formulas

For `good` at `port` (`trade_engine.gd`, all integer gold, floor on every
multiplication):

```
factor(port, good) =
    0.7  if good.id ∈ port.produces
    1.3  if good.id ∈ port.demands
    1.0  otherwise

buy_price  = max(1, floor(base_price × factor × investment_discount))
sell_price = max(1, floor(base_price × factor × 0.8 × investment_discount
                          × title_bonus))
investment_discount = 1 − min(0.10, port_investments[port.id] / 500 × 0.01)
title_bonus = 1.05 | 1.10 | 1.00   # Phase 3, 70-* §4.9.2
```

- The 0.8 sell-side margin is locked; arbitrage within one port is always a
  loss.
- Provisions and water are exempt from all factors: fixed 2g and 1g
  (`20-*` §4.10), sell-back not offered.
- Price band enforcement `[0.5×, 2×]`: `factor × investment_discount` is
  clamped to `[0.5, 2.0]` before use (investment discount cannot push a
  `produces` good below half base price).
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
  effect. Wider effects OUT OF SCOPE (phase 3).

### 4.4 Buy/sell quantity maths

- Quantity picker: 1 / 10 / 100 / Max buttons + direct numeric entry
  (validation per `80-*` dialog rules).
- **One picker per row** serves both the Buy and Sell buttons (the §4.7
  wireframe has a single Qty column). Its live clamp is the *physical* range —
  the pooled free hold, or the held quantity when that is larger (so a full
  hold can always be emptied). Each button then validates against its own
  maximum, and an entry the purse cannot cover is a disabled button with the
  price reason, not a silently rewritten field. `Max` selects that same
  physical ceiling. (Normative clarification, T12.)
- Buy max = `min(floor(gold / buy_price), free_capacity)` where
  `free_capacity` is pooled fleet free cargo (`40-*` §capacity).
- Sell max = held quantity. Partial sells allowed.
- No market stock limits in Phase 1: ports buy/sell unlimited quantities at
  the fixed computed price (no price movement per transaction — dynamic
  pricing OUT OF SCOPE (phase 3)).
- Transaction errors (insufficient gold/capacity/quantity) show the shared
  error toast (`80-*`) and change nothing. In this screen the "shared error"
  presentation is the disabled button plus its tooltip reason (§4.7); no
  modal dialog is raised for a rejected trade, so a stray click never spams
  dialogs (§6 "no dialog spam").

### 4.5 Tavern: crew hire/fire

- Hire: 1-click buttons "+1 / +10 / Fill"; cost = `crew_wage_daily × 10` per
  head as signing bonus (locked: 2 × 10 = 20g/head). Hard cap: flagship
  `crew_max` (Phase-1 fleet = flagship only for crew; multi-ship crew OUT OF
  SCOPE (phase 2)).
- Fire: "−1 / −10 / Down to min" buttons; cannot go below `crew_min`; fired
  crew leaves with no severance; morale unchanged.
- Officer recruiting UI and rules live in `50-*` §officers; the tavern screen
  hosts that panel under a second tab.

### 4.6 Inn: rest & harbor relief

- **Rest:** button "Rest 3 days", cost `10g × 3 = 30g`; each rest day runs
  the daily ledger (wages still paid) and applies the in-port morale delta
  (+5/day, cap 80, `20-*` §4.8.1).
- **Harbor relief (odd jobs):** visible only when the `10-*` §5 condition
  holds (`gold < 100` and fleet empty). Button "Work an odd job":
  `gold += 100`, one ledger day passes. Strings `inn.odd_job.offer`,
  `inn.odd_job.result`.

### 4.7 UI flows (textual wireframes)

Full widget/sizing conventions in `80-*`; these define content and
interactions per screen.

#### Port hub (`port_screen`)

```
+--------------------------------------------------------------+
| <Port name>  ·  <Nation name>      Day 12 · 7,830g     [ Lang ]|
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
+--------------------------------------------------------------+
| Market — <Port>            Gold 7,830g · Hold 34/120   [Back]|
+--------------------------------------------------------------+
| Good        | Price buy/sell | You have | Qty   | [Buy][Sell]|
| Wheat       |   8g / 6g      |    0     | [ 10 ]| [Buy][Sell]|
| ... 20 rows, scrollable ...                                  |
+--------------------------------------------------------------+
| Supplies: Provisions 2g [  ___ ][Buy]   Water 1g [ ___ ][Buy]|
| [ Invest 500g ]  invested here: 1,500g (−3%)                 |
+--------------------------------------------------------------+
```

Rows sorted by `base_price` ascending. Buy/Sell disabled with tooltip-reason
when unaffordable/over capacity/qty 0. Successful trade flashes the gold
readout (per `80-*` feedback rules) and emits `gold_changed` +
`fleet_changed`.

#### Tavern (`tavern_screen`)

Tab row: `Crew | Officers` in Phase 1–2; Phase 3 adds a third tab
`Rumors` (`70-*` §4.4, `80-*` §4.7.3).

- Crew tab: current crew `n / crew_max`, morale tier label, hire/fire buttons
  (§4.5), cost preview "20g per head".
- Officers tab: list of officers recruitable at this port
  (`Officer.recruit_ports`), each row: name, role, stats line, daily wage,
  bio; `Recruit` button (rules incl. one-time hire in `50-*`). Below: current
  officers with a `Dismiss` button.
- Rumors tab (Phase 3): up to three hint rows for unfound discoveries at
  100g each (`70-*` §4.4).

#### Inn (`inn_screen`)

- Status box: morale, days-since? none. Buttons: `[Rest 3 days — 30g]`,
  `[Work an odd job — +100g]` (only when eligible, §4.6), else a disabled
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

A worked trade (Lisbon, buys its `produces` good wine):

```json
{
  "port": "lisbon",
  "good": "wine",
  "base_price": 30,
  "factor": 0.7,
  "investment_discount": 1.0,
  "buy_price": 21,
  "sell_price": 16,
  "note": "buy floor(30×0.7)=21; sell floor(30×0.7×0.8)=16"
}
```

Selling at London (wine ∈ `london.demands`):

```json
{
  "port": "london",
  "good": "wine",
  "base_price": 30,
  "factor": 1.3,
  "buy_price": 39,
  "sell_price": 31,
  "note": "sell floor(30×1.3×0.8)=31; route Lisbon→London nets 10g/unit before costs"
}
```

Phase-3 title bonus (same London sale, player is baron of England):

```json
{
  "port": "london",
  "good": "wine",
  "base_price": 30,
  "factor": 1.3,
  "investment_discount": 1.0,
  "title_bonus": 1.1,
  "buy_price": 39,
  "sell_price": 34,
  "note": "floor(30×1.3×0.8×1.1) = floor(34.32) = 34; the bonus is sell-side only"
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
