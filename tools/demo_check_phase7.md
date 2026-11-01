# J — Phase-7 Acceptance Record

Definition of "Phase 7 complete": `docs/IMPLEMENT-Phase7.md` **J** — trade
empires: ports *matter*. A **flow economy** replaces drift-to-rest (every
listed port-good is produced or consumed; producers fill toward capacity,
consumers drain; the stable gradient is producers cheap / consumers dear),
**40 goods** with `staple`/`specialty`/`exclusive` flags over the
produces/demands listing rule, **16 ships** and **24 equipment items** with
per-port stock lists and `tier ≤ effective_dev` gating (three row states at
every yard, rare drop-only items from named pirates), a living **allegiance
tug-of-war** (protected vs contestable ports, per-nation ledgers with the
×5/4 home advantage, monthly seeded NPC counter-investment from treasuries,
tavern telegraphs, flipping paced as a campaign), a **unified tariff**
(5%/20% for player and NPC alike) with two permit kinds funding the
allegiance nation's treasury, and a **measured economy** — `sim_trade.py`
gates 1–10 guarding the data lock.

Two layers of evidence, the same shape as the Phase-2–6 records:

1. **Scripted** — 39 shipped suites (incl. the new `test_allegiance` /
   `test_market_screen` / `test_save_v7`, and the reworked `test_economy` /
   `test_trade` / `test_palace` / `test_shipyard` / `test_equipment`), the
   `tools/demo_probe_phase7.tscn` acceptance probe (the sixteen J scenarios,
   73 checks), `tools/sim_trade.py` (gates 1–10), and the validator at
   groups 1–10.
2. **Manual** — the play-it-by-hand section below, in both locales.

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/validate_data.py            # exit 0, groups 1-10
python3 tools/build_world.py --check-snaps data/ports.json   # exit 0
python3 tools/build_ocean.py --check      # byte-identical rebuild, exit 0
python3 tools/build_routes.py --check     # byte-identical rebuild, exit 0
python3 tools/sim_trade.py                # gates 1-10, overall PASS (byte-stable)
python3 tools/run_tests.py                # 39 suites; exit 0; 0 zombie/hang
godot --headless res://tools/demo_probe_phase7.tscn   # ALL PASS (73 checks)
godot --headless --quit-after 3           # exit 0, no SCRIPT ERROR
```

**The full suite count at the Phase-7 gate is 7 689 checks across 39
suites** (Phase 6: 6 538 / 37). Counts are compared, not just the green
summary.

---

## The J scenarios — how each is verified

| # | Task-J scenario | Verified by | Recorded result |
|---|---|---|---|
| 1 | Watch the flow economy live — a producer's stock rebuilds toward capacity | probe scenario 1 + `test_economy` | lisbon wine: capacity **200** (160+60 dev-3, ceiling 200), prod **8/day** (5 × 7/4); stock 100 → **140** in 5 ticks |
| 2 | A consumer starves and recovers after your sale | probe scenario 2 + `test_economy` gradient pins | london wine drains 60 → **0** (8 ticks at dev-3); starved buy **45g** (factor 1500); after a 60-unit sale lands: **36g** (factor 1225) |
| 3 | Try and fail to sell a good to the port that produces it (不收购) | probe scenario 3 + `test_market_screen` row pins | `is_produced_at` ✓, `port_buys_good` ✗; `sell(lisbon, wine, 10)` → **refused**; the market row renders 不收购 sell-disabled |
| 4 | Sight a grey coaster trading at an unallied neutral port | probe scenario 4 + `test_npc_fleets` §22c (quanzhou sells 5 wheat, hops to xiamen) | budget ceil(45 × 0.75) = **34**; scope staples ∪ middle only (silk/porcelain refused both ways); seeded journey **sulu → brunei**, nearest port of any ownership |
| 5 | Raise an own-nation dev-1 port to dev 2 (rates visibly faster) | probe scenario 5 | ceuta: ledger 6 000 → **31 000**, dev **1 → 2**, staple rate **6 → 7/day** (×(4+dev)/4) |
| 6 | Flip a China-coast port (invest vs monthly AI); its badge drops 20% → 5% | probe scenario 6 | the band-neutral starts tariff **2000** (未同盟); **6 000g** flips it (no owner bonus on a neutral) → effective alignment portugal, tariff **500** (势力内 5%) |
| 7 | Read a rival's investment telegraph in a China-coast tavern and out-invest it | probe scenario 7 + `test_allegiance` determinism | month tick produced **36 rows** (12 picks × 3 windows); e.g. `england @ anotsu (1 500g)`, band japan; out-investing **5 500g** clears the 5 000g line → alignment **portugal** |
| 8 | Be blocked once by the rep gate, then run a multi-month flip campaign against a foreign sovereign port — cap, home advantage, AI contest — and eat the −5 rep | probe scenario 8 + `test_allegiance` | at rep −5: `invest_block_reason` = `market.invest_gate.blocked`; campaign **4 months × 2 000g** (the cap) beats spain's **7 500 effective** (6 000 × 5/4) → flipped; fame **+100**, rep with spain **−5**, the commendation pends at the palace |
| 9 | Buy 本国免税证 (5% → 0% at home and aligned ports) | probe scenario 9 + `test_palace` permit gates | lisbon offer: home / **5 000g**; purse −5 000 exactly; `has_permit_home` ✓; lisbon tariff **500 → 0** |
| 10 | Buy a 涉外免税证 | probe scenario 10 + `test_palace` | below Knight: `title_locked=true`; after fame + mission + grant: **Knight of spain**, price **20 000g**, gates false/false; seville tariff **2000 → 0** for the holder |
| 11 | Run a taxed vs untaxed monsoon loop | probe scenario 11 + `sim_trade.py` gates 1–4 | 20 spices amboina (holland) → seville (spain): **20%/20% round trip loses (−660g)** vs permitted **+410g** — the tax bites exactly as gate 2 asserts (worst foreign ratio 0.419) |
| 12 | Sink/capture a named pirate for a rare drop | probe scenario 12 + `test_shipyard` §rare | khair ad-din defeated → drop **eq_khair_scimitar** (combat 10) fitted to the weapon slot; an unnamed captain drops nothing; rares never appear in any stock UI |
| 13 | At a dev-2 major see the galleon grayed 需发展度 3, grow the port to dev 3, buy it | probe scenario 13 + `test_shipyard` row states | marseille stocks the galleon: state **tier_gray**, note `shipyard.tier.need_dev`; ledger → 50 000g total → dev 3 → state **available**; the docked yard sells it (gold asserted) |
| 14 | Buy a junk at an aligned dev-2 neutral port | probe scenario 14 + `test_shipyard` §12 | the neutral yard's junk starts **allegiance_gray** (同盟专营, the flip path in the note); align + 25 000g → aligned dev 2 → state **available** → the junk buys |
| 15 | Watch rival counter-investment flip a port back | probe scenario 15 + `test_allegiance` ties/incumbency | the player-held neutral flips to england under a 9 000g rival ledger; **reputation deltas: none** — losing a port costs nothing |
| 16 | zh/en parity | validator group 2 + probe scenario 16 | **570 ui_strings keys** (535 → 570; the +35 are the Phase-7 families of `80-*` §4.7.15), zh/en complete, zero `<key>` fallbacks |

### Debug-chart sanity eyeball (unchanged from Phase 6)

The omniscient chart (`D`), lane network, fleet layer, hunter-intel rings
and the month scrubber are Phase-6 surfaces and re-proven by
`test_chart` (141) / `test_world_map` (287); Phase 7 adds no chart surface.
The market/shipyard/palace screens carry the Phase-7 rows instead
(`test_market_screen` 188 / `test_shipyard` 248 / `test_port_hub` 264).

---

## How to play it by hand

```bash
godot --path .
```

1. **New Game → Portugal** (5 000g, caravel at Lisbon). Dock: the market
   lists only what Lisbon produces or demands — no 40-row wall. Wheat you
   buy at the producer's capacity price is *cheap*; sail it to a drained
   consumer for the gradient.
2. **Try to sell wine at Lisbon** — the row says 不收购 and the sell button
   refuses. Sail it to London instead and watch the price walk.
3. **Invest:** at any contestable port (Ceuta is the tutorial one), the
   Invest button takes 500g chunks — 4 per month, then the button reads
   本月投资上限已达. Watch the tariff badge tick 势力内 5% once your ledger
   clears 5 000g, and 专营货 rows unlock at dev ≥ 2.
4. **The tug-of-war:** park in a China-coast tavern for a few months —
   投资动向 rows appear (`{nation} 在 {port} 投资 {amount}g`, 30 days,
   band-scoped). Out-invest the rival or lose the port; losing costs
   nothing but pride.
5. **Palace (capitals):** 免税证 section — the home charter at 5 000g turns
   every 势力内 5% badge into 免税; the foreign permit needs Knight **of
   that nation** and rep ≥ +20, and voids while you carry their bounty.
6. **Shipyards:** at a dev-2 major the tier-3 hull sits grayed 需发展度 3;
   at an unallied neutral every hull row reads 同盟专营. The 4 rare items
   are never on any shelf — hunt the four named pirates for them.
7. **Hunt Redbeard:** sink 「红胡子」海雷丁 and the after-action report
   credits his scimitar (occupied weapon slot sells the old blade back at
   half price, same transaction).
8. **Language:** flip 中文/EN in S19 — every new label (特产, 不收购, 关税
   badge lines, 免税证, 需发展度, 同盟专营, 投资动向) flips with no `<key>`
   literal.

### Reported-bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Any
`SCRIPT ERROR` in the terminal is a real defect. A pre-Phase-7 save is
refused by design (`pre-release save_version 6 (this build reads 7)`).

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-11-02 |
| Branch / commit | `main` @ the Phase-7 completion commit (see the backlog's completion record) |
| Godot | 4.7.stable.official.5b4e0cb0f |
| World / ocean artifacts | unchanged from Phase 6; **byte-identical** rebuilds (`--check` exit 0 ×3: `build_world.py`, `build_ocean.py`, `build_routes.py`) |
| Route artifact | `data/trade_routes_built.json` — rebuilt over the Phase-7 sources by task T: 17 lanes / 624 waypoints / 145 spokes (90 lane + 55 override) / 1 161 junction nodes · 1 223 edges; sha `dbab2811…`; three consecutive rebuilds **byte-identical** |
| Economy harness | `tools/sim_trade.py` — gates 1–10 **PASS** (two consecutive runs diff empty, 5 281 bytes); steady state converges in 21 days; price-plumbing parity vs `30-*` §5 PASS |
| Command | `python3 tools/run_tests.py` |
| Result | **39 suites, 7 689 checks, 0 failures, 0 zombie/hang**, exit 0 |
| Acceptance probe | `demo_probe_phase7.tscn` — **ALL PASS (73 checks)**, exit 0 |

### Gate results

| Gate | Result |
|---|---|
| `python3 tools/validate_data.py` | **exit 0** — groups 1–10 PASS (flag-driven 12/16/12 tier split; ≥2 producers/≥4 consumers per good; staple coverage 120/240 + ≥2/band; ≥1 exclusive per neutral band; protected ⊇ capitals ≤4/nation; hardware tier rules; 40/16/24 exact sets; 15-band partition; `neutral_coasters_mult` bounds; rate-surge event shape) |
| `build_world.py` / `build_ocean.py` / `build_routes.py` | **byte-identical** rebuilds (three `--check` runs) |
| `sim_trade.py` gates 1–10 | **all PASS**: ① every starter profitable under the 5% sphere tax (worst england 13.8 g/day); ② fully-foreign ≤ 60% of permitted (worst **0.419**); ③ allied monsoon specialty ≥ 1.2× home (worst **1.800×**); ④ ≤ 3× pre-tax (worst 0.419×); ⑤ recovery ≤ 30 days (worst exactly 30); ⑥ coaster damping ≥ 0.5× (worst **0.718**); ⑦ greedy bot **68 970g**/360d ≤ 80 000g; ⑧ 120-unit < 2.2× 60-unit (worst **0.600×**); ⑨ furthest staple run **65 tiles** ≤ 120; ⑩ producer health **0.985** ≥ 0.5 capacity |
| 39 suites (`tools/run_tests.py`) | **7 689 checks, 0 failures, 0 zombie/hang** |
| `godot --headless --quit-after 3` | exit 0, zero `SCRIPT ERROR` |
| day tick @ 307 fleets (cap arithmetic: traders 128 + nation coasters 77 + patrols/couriers/privateers 43 + pirates 25 + nationless coasters 34 = core **307**, + 16 slack = **323** global; trickle 7/day) | **61.8 avg / 70.0 worst ms** (gate ≤ 75 ms — met after the pinned dwell-cadence fallback, `COASTER_DWELL_DAYS := 4`; the `neutral_coasters_mult` retune was not needed) |
| day tick @ extreme ≈1 100 | **252 ms** (gate ≤ 350 ms) |
| pursuit A* (chase radii 30/40, replanned daily, worst water) | **20.6 ms worst** vs the 250 ms/day budget |
| save payload @ extreme | **1 858 515 B ≈ 1.77 MB** (gate ≤ 2 MB); density's real-world probe 1 752 101 B |
| save version | **v7 round-trips; v6 refused** (pre-release message; state untouched); mid-month AI **replay purity** proven (save day 17 → identical month-31 investment sequence) |
| locale audit | **570 keys, zh/en complete**; zero literal `t_key` misses |
| determinism proofs | allegiance monthly AI (same seed → identical sequences + treasuries, L) · economy ticks (byte-identical `market_stocks` + 720-rotation event schedule, K) · NPC spawn/docking with coasters (byte-identical port-traffic logs, N) · mid-month save/load replay (V) |

### Suite counts at the gate

| Suite | Checks | | Suite | Checks |
|---|---:|---|---|---:|
| aliveness | 139 | | allegiance | 384 |
| battle | 218 | | battle_economy | 68 |
| battle_screen | 122 | | bounty | 80 |
| character | 409 | | chart | 141 |
| demo_loop | 83 | | density | 82 |
| discovery | 236 | | duel | 148 |
| ecology | 76 | | economy | 140 |
| equipment | 158 | | fleet | 193 |
| inn | 116 | | market_screen | 188 |
| morale | 260 | | movement | 451 |
| npc_fleets | 438 | | ocean | 133 |
| officers | 104 | | palace | 219 |
| phase2_acceptance | 140 | | phase3_acceptance | 102 |
| port_hub | 264 | | quests | 105 |
| retirement | 78 | | sailing | 118 |
| save | 220 | | save_v7 | 429 |
| shipyard | 248 | | tavern | 268 |
| tournament | 144 | | trade | 367 |
| weather | 225 | | world_e2e | 108 |
| world_map | 287 | |  |  |

### Phase-7 deltas worth recording

- **Staged-sim protocol (correction 14) worked as designed.** W2's four
  branches were held; T iterated gates 1–10 against a master-assembled
  staging export (two full rounds). Data-side fixes found by measurement,
  all via the sanctioned levers: the 12 specialties' `flow` overrides
  (gate 5's 30-day pacing), goa/bahia demand edges + calicut dev 2 (gate
  3's 1.800×), equipment_stock coverage (S-id alignment). Two master
  rulings pinned during iteration: staple-coverage self-counts at
  distance 0, and the protected set asserted by membership (17 ports),
  not by count.
- **Gate 2's shape note:** the ≤ 0.6 cap binds the *fully-foreign* trader;
  mixed runs (buy home 5%, sell foreign 20%) are reported informationally
  (worst ratio 0.804 — tranche-walk-structural, not authorable data).
  Recorded so nobody "fixes" the harness into an unattainable cap.
- **Three integration waves after the merges** (each a bounce to the
  owning session, disjoint files): the flow-economy seed × tariff cross-pins
  (trade/palace/demo_loop), the live-allegiance dev fixtures (economy),
  and the merged-keys fallback pins (shipyard). Plus one real
  parse-time bug the suite gate caught (market screen's old `goods_rows()`
  arity) and one silent gap (`facilities.shipyard` int → list emptied
  every port hub's facility rows — `port_screen` hotfix).
- **Named-pirate rare drops** had data + docs but no owning task; the
  master completed the §4.11.13 grant in `battle_rewards` (captain-id
  keyed, standing replace rule, displaced item sold back at half price).
- **Fleet-cap growth is persistent, not slack-absorbed:** the 34
  nationless coasters raise the core line 272 → 307 (global 288 → 323),
  exactly the risk the backlog's cap row anticipated; the day-tick gate
  held via the dwell-cadence fallback, and the `neutral_coasters_mult`
  lever stayed at 0.75.

### Known limitations carried forward (not defects)

- **Pre-release saves do not migrate** by design (`90-*` §8.2, decision
  13): a v6 payload is refused, state untouched.
- **Mid-phase saves never load** (dev-stage rule).
- **The commendation "shown" flag is session state** — a reload can
  re-surface a converted port's dialog once; the +100 fame and the
  `fame_commended` persistence are save-proof (L, informational).
- **The AI's "weighted toward lanes" draw is pinned as
  `randi_range(1,3) ≤ weight`** (weights 1 inland / 2 lane-adjacent) —
  the one number not read off a doc table, constant-named in the source,
  determinism-proven (L).
- **Gate 2 binds fully-foreign routes only** (see the shape note above);
  mixed-run ratios are reported, not gated.
- **Coaster dwell cadence is a module const** (`COASTER_DWELL_DAYS := 4`),
  not a config line — the validator exactly-locks the §4.10 config key
  sets, so the pinned fallback lever landed in code; a future retune is a
  one-constant change (N).
- **Exclusive goods trade at 20% for non-aligned traders forever** — no
  permit can ever cover an unallied contestable port (decision 20), so
  the grayed exclusive rows at your rival's specialty ports are a
  permanent feature, not a defect.
