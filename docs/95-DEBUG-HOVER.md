# 95 — Fleet debug hover: how to read it

A reader's guide to the fleet debug floating window (the chart screen's
hover report over a fleet marker). It decodes every field so you never
have to re-read the code to interpret a screenshot.

Ownership: the payload is built by `NpcFleetsLib.markers()`
(`scripts/world/npc_fleets.gd`, the `dbg`/`dbg2`/`dbg3` strings); the
localization and line-folding live in `scenes/world/chart_screen.gd`
(`_annotate_raw_line`, `80-*` §4.6); every label is
`debug.raw.*`/`debug.stall.*`/`debug.role.*` in `data/ui_strings.json`
(the §4.7.10 rule — debug surfaces speak the ui_strings locale). The
sim semantics behind the numbers are `60-*` §4.11.11 (unified
movement). Labels below are quoted as `zh / en`.

---

## 1. The summary line (fleet id + badges)

    nf_1_0079_coaster
    沿海商船 · 葡萄牙 · 航向 W · 航速 18 格/天 · 目的地 里斯本

In order: the fleet id (raw, never localized), then:

| Piece | Source | Meaning |
|---|---|---|
| 沿海商船 | `debug.role.*` | role: 商船 trader · 沿海商船 coaster · 信使船 courier · 巡逻舰 patrol · 海盗 pirate · 私掠船 privateer · 猎捕舰队 hunter · 运宝船 treasure ship |
| 葡萄牙 | the nation's L10n name | owner nation (absent for the nationless grey coasters) |
| 停靠中 / 受阻 ×3 / 冷却中 / 锚点驻扎 @格 / 追猎中 / 追捕中 / 搁置海上 | `debug.stall.*` | the stall badge (§4 below). **Absent = sailing.** `受阻` appends `×N` (the hold streak) plus its 航向/航速; `锚点驻扎` appends `@<cell>`; `停靠中` appends `@<port name>`; `搁置海上` appends `@<x,y>` — where it actually stands, never a port name it is nowhere near |
| 航向 W · 航速 18 格/天 · 目的地 里斯本 | `debug.info.*` | shown when a step heading resolves: the current leg heading, the pipeline rate (tiles/day), the destination port |

A fleet with no heading yet but planned lanes shows 航线巡回
(`debug.info.circuit`) with its lane names instead — the drop/re-depart
gap state — so an entry is never bare.

---

## 2. 状态 section (`dbg`)

Raw shape: `cell=(x,y) dwell=D day=D legs=N ti=N holds=N carry=F mark=F`

| Label (zh/en) | Field | Meaning |
|---|---|---|
| 所在格 tile | `cell` | the fleet's world tile (1 px = 1 tile, `10-*` §6.3) |
| 停留截止日 dwell-until | `dwell` | `dwell_until_day` — the dock/hold deadline. `> 世界天数` ⇒ the fleet is inside a hold: a post-arrival dock (2 days; coasters ride the §4.11.14 lever, default 4) **or a spawn hold** (a freshly spawned lane fleet idles on its origin berth with its journey pre-planned — the 2026-11-02 amendment). `0` or `≤ day` ⇒ not holding |
| 世界天数 world day | `day` | `GameState.day` — the world clock's day |
| 航段数 leg count | `legs` | `route.legs.size()` — journeys are leg lists (spoke → trunk → spoke). `0` = docked/no journey |
| 段内格序 leg tile idx | `ti` | `route.tile_index` — progress within the CURRENT leg (0 = at its first walked tile; `-1` = unsynced) |
| 停滞计数 hold ticks | `holds` | consecutive accrual passes that committed **zero** tiles. Any committed tile resets it. `≥ 3` (`STALL_HOLD_TICKS`) ⇒ the 受阻 badge (in-month seasonal ice on the walked span is the only in-play cause) |
| 步进余量 step carry | `carry` | the banked sub-tile remainder (a slow hull against wind/current banks fractions until a whole tile accrues). `0.00` on a healthy fast fleet between passes |
| 时钟标记 clock mark | `mark` | this fleet's accrual mark (runtime-only — never saved). Negative display = **no entry** → `(未设标记)`. That alone does NOT freeze anything: a mark-less fleet owes the pass delta (the mark falls back to the pass's previous clock) |

---

## 3. 结算 section (`dbg2`)

Raw shape: `now=F pend=F|n/a lastd=F moved=0|1 skip=s committed=N budget=N pipe=F cd=D leg0=…`

| Label (zh/en) | Field | Meaning |
|---|---|---|
| 当前时钟 clock now | `now` | `day + clock_fraction` — the absolute world clock this pass ran at |
| 待结算增量 pending accrual | `pend` | `now − mark`: what the fleet still owes. `n/a` = no mark yet. Negative renders `(冻结：标记超前于时钟)` — a clock rewind under the mark; the next pass rebases it (grants nothing once, then resumes) |
| 上次结算 last pass / 上次增量 last accrual | `last`/`lastd` | the previous accrual pass's delta for this fleet. **`last=-` ⇒ this fleet was never accrued by the live sim** (fresh adoption, or a session where the daily tick never ran) |
| 是否移动 moved | `moved` | did the pass change the fleet's tile |
| 跳过原因 skip reason | `skip` | why the pass granted nothing: `停靠` docked (legs empty **or** a spawn hold — the 2026-11-02 amendment) · `冷却` cooldown (`cd ≥ day`) · `标记过期` stale mark (the rewind rebase pass). Absent = the pass accrued normally |
| 日已走格 committed tiles | `committed` | tiles the pass actually walked |
| 日预算 day budget | `budget` | the whole-day catch-up budget (≈ one day of `pipe` plus the banked carry) |
| 管道速率 pipe rate | `pipe` | `base × wind × direction × current` tiles/day for the current leg heading — the §4.4 pipeline. `0` = doldrums (headwind/current), a legitimate crawl, never a wedge by itself |
| 冷却截止日 cooldown-until | `cd` | `cooldown_until_day` — post-battle pursuit cooldown (inclusive: a battle on day D stores D+1) |
| 当前腿 current leg | `leg0` | see below |

### Reading `leg0` — `休达[0..2]R0 0/3`

    <lane/spoke id> [a..b] R<0|1> <ti>/<walked_len>

- **休达** — the leg's lane or spoke id, localized when it resolves
  (`debug.lane.*`), else the raw id.
- **[0..2]** — the leg's saved walked range `a..b`, indices into the
  leg's tile path.
- **R0 / R1** — walk direction: `R0` forward (`path[a] → path[b]`),
  `R1` backward.
- **0/3** — `ti` (the tile index inside the leg) / `walked_len`
  (the range's tile count). `0/3` = standing at the leg's very start;
  note the second number is leg 0's length, **not** the 航段数.

`leg0=-` ⇒ no legs (docked / journey dropped).

---

## 4. 旅程 section (`dbg3`)

Raw shape: `dest=<port> mooring=<port> cell=x,y ev=<event ring>`

| Label (zh/en) | Field | Meaning |
|---|---|---|
| 目的港 dest port | `dest` | `dest_port_id`, localized; `-` = none |
| 实际泊位港 berth port | `mooring` | **berth truth**: the port resolved from the tile the fleet stands ON (`_port_at_cell`), not the destination. `-` = off-berth (a "docked" fleet in open water is 搁置海上 stranded and the day tick heals it on dwell expiry) |
| 所在格 tile | `cell` | same tile as the 状态 section, for grep-ability |
| 旅程事件 journey events | `ev` | the event ring, newest last, each stamped `@<day>` |

Event grammar (each becomes its own localized field):

| Raw | Renders as | Meaning |
|---|---|---|
| `spawn@1` | 出生@1 | spawned |
| `dep 休达->里斯本@3` | 起航 休达→里斯本@3 | departed (route planned) |
| `depX A->B@5` | 起航失败 A→B@5 | departure failed (no route) — idles one dwell and retries |
| `arr 里斯本@12` | 抵达 里斯本@12 | arrived, docked (sets 停留截止日) |
| `drop wedge:<lane> ti=2@7` | 丢弃 楔形段:<lane> 段内序2@7 | the leg had no resolvable step (wedge) — journey dropped, the day tick re-departs fresh |
| `drop leg:<id>@7` / `drop seam:<id>@7` | 丢弃 航段/接缝:<id>@7 | broken leg/seam (unknown id) — journey dropped |

A dropped journey is self-healing (re-depart next tick), so `drop …`
followed by a fresh `dep …` is recovery, not a bug.

---

## 5. The stall badges (`stall_state`) — evaluation order

| Badge (zh/en) | Fires when | Note |
|---|---|---|
| 停靠中 docked | `dwell > day` and standing on a berth tile — an arrival dock **or a spawn hold** (legs non-empty does not matter, 2026-11-02 amendment) | normal idling |
| 搁置海上 stranded | `dwell > day` but NOT on a berth tile | the false-mooring case; healed on expiry |
| 冷却中 cooldown | `cooldown_until_day ≥ day` | post-battle |
| 锚点驻扎 camping | targetless raider within its anchor radius, off-lane | the chokepoint-camp pattern |
| 追猎中 chasing | raider with a target | |
| 追捕中 pursuing | hunter in chase state | |
| 受阻 blocked ×N | `holds ≥ 3` while having legs | ice holds on the walked span |
| *(no badge)* sailing | everything else | under way, accruing |

---

## 6. Recipe: why is this fleet not moving?

Check in this order:

1. **上次结算 shows `-`** — the live sim never accrued this fleet.
   In play that means the daily tick never reached the sim (e.g. the
   session never ensured it — fixed 2026-11-02: the FleetSim day tick
   ensures itself). Caveat: a chart opened **outside** the world scene
   reads a fresh never-ticked *view* sim, whose `mark`/telemetry are
   always empty — there `未设标记`/`last=-` prove nothing about the
   live sim.
2. **跳过原因 `停靠`** — it is HOLDING: compare 停留截止日 with 世界天数.
   Future ⇒ genuine idle (spawn hold or arrival dock); it departs/walks
   when the day passes the deadline. This is the normal cadence, not a
   stall.
3. **跳过原因 `冷却`** — pursuit cooldown; sails again after 冷却截止日.
4. **`pend` 冻结 (negative)** — a clock rewind under the mark; the next
   pass rebases and movement resumes.
5. **受阻 ×N** — ice blocking the walked span; melts with the month.
6. **`drop wedge/leg/seam` in 旅程事件** — the journey was dropped; the
   next day tick re-departs it fresh (watch for the following
   `起航 …`).
7. **管道速率 `0.0` with committed 0** — wind/current doldrums on the
   leg heading; it crawls or banks carry until the heading/region
   changes.
8. **实际泊位港 `-` while 停靠中** — stranded off-berth; the day tick
   snaps it to a berth on dwell expiry.

### Worked example (the 2026-11-02 report)

    nf_1_0079_coaster  沿海商船 · 葡萄牙 · 航向 W · 航速 18 格/天 · 目的地 里斯本
    状态   所在格 (2095,649) · 停留截止日 5 · 世界天数 2 · 航段数 3 ·
           段内格序 0 · 停滞计数 0 · 步进余量 0.00 · 时钟标记 -1.000 (未设标记)
    结算   当前时钟 2.000 · 待结算增量 n/a · 上次结算 - · 冷却截止日 0 ·
           当前腿 休达[0..2]R0 0/3
    旅程   目的港 里斯本 · 实际泊位港 休达 · 所在格 2095,649 · 旅程事件 -

Decoded: a coaster spawned day 1 (`nf_1_*`), idling on its **origin
berth at Ceuta** (实际泊位港 休达 = the berth it stands on; 目的港
里斯本 = the pre-planned journey's destination) inside its **spawn
hold** (停留截止日 5 > 世界天数 2; 航段数 3 = the pre-planned journey;
当前腿 0/3 = not one tile walked). Not a wedge, not frozen by a mark —
it is legitimately docked until day 5. The 2026-11-02 bug was that
*nothing* would ever release it in port (the legs-only docked gates
skipped the hold both in the day tick and in the accrual, and the port
midnight tick never ensured the sim); after the fix the hold is
reported as 停靠中 and released on schedule.
