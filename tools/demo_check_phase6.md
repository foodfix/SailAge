# J — Phase-6 Acceptance Record

Definition of "Phase 6 complete": `docs/IMPLEMENT-Phase6.md` **J** — the sea
has navigation depth: the world is at **4320×2160** (12 tiles/degree, 1 tile =
5 nm), a **30-day/360-day calendar** drives **prevailing winds + monsoons**,
**ocean currents** (modifier/drift), **sail trim + wait-at-sea**, **Step/Helm
input modes** with interpolated rendering, **seasonal sea ice**, and **NPC
parity** on 17 lanes (12 historical + 5 regional) serving 145 ports (100
sovereign + **45 neutral**, nation-free frontier markets) — with an
omniscient debug chart as the phase's sanity window. Everything here is
checkable from the shipped tools.

Two layers of evidence, the same shape as the Phase-2–5 records:

1. **Scripted** — 37 shipped suites (incl. the new `test_ocean` / `test_chart`
   / `test_save_v6`), the `tools/demo_probe_phase6.tscn` acceptance probe
   (the ten J scenarios, 21 checks), and the validator at groups 1–10.
2. **Manual** — the play-it-by-hand section below, including the debug-chart
   sanity eyeball, in both locales.

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/validate_data.py            # exit 0, groups 1-10
python3 tools/build_world.py --check-snaps data/ports.json   # exit 0
python3 tools/build_ocean.py --check      # byte-identical rebuild, exit 0
python3 tools/build_routes.py --check     # byte-identical rebuild, exit 0
python3 tools/run_tests.py                # 37 suites; exit 0; 0 zombie/hang
godot --headless res://tools/demo_probe_phase6.tscn   # ALL PASS (21 checks)
godot --headless --quit-after 3           # exit 0, no SCRIPT ERROR
```

`tools/run_tests.py` is the canonical runner (`90-*` §13): save-touching
suites serialized (the set now reads `test_save`, `test_save_v6`,
`test_world_e2e`), the rest 8-way parallel, per-suite wall + CPU profiling,
zombie/hang detection.

**The full suite count at the Phase-6 gate is 6 538 checks across 37 suites**
(Phase 5: 6 008 / 35). Counts are compared, not just the green summary.

---

## The J scenarios — how each is verified

| # | Task-J scenario | Verified by | Recorded result |
|---|---|---|---|
| 1 | Lisbon→open sea upwind vs downwind (different tile/day rates) | `demo_probe_phase6` scenario 1 | caravel (base 20) at wind E: **10 tiles/day beating (1/10 d/tile) vs 26 running (1/26)** |
| 2 | Tack by hand and beat the autopilot's straight line | probe scenario 2 | beating the same 20-tile leg: **2.00 days vs 0.77 running** — the human times the season; the 45° tack is break-even by the locked buckets (28.3 tiles at 1/14 = 2.02, recorded honestly; the skill is timing + route choice, decision 4) |
| 3 | Wait out a storm reefed | probe scenario 3 + `test_ocean` trim table | trim storm table **3/4/5/7** hull damage (caravel 90); `wait_at_sea()` in a storm → day 2, position held |
| 4 | Ride the Gulf Stream (modifier); watch drift move the fleet (Drift mode) | probe scenario 4 + `test_ocean` | corridor decodes **N/3**; ±0.08×strength bands **×1.24 / ×0.76**; 3 Drift-mode sea days pushed the fleet **(0, −12)** along the flow, stopping before land |
| 5 | Winter-close the Baltic; `hanseatic_north` takes its winter variant | probe scenario 5 + `test_ocean` ice + `test_npc_fleets` §17 | Baltic tile frozen in **month 1, open by month 7**; the lane carries `hanseatic_north_winter` (months 12–3, the Hamburg Bergenfahrer run); a patrol flips base→variant at the month boundary, progress preserved by fraction |
| 6 | **Ride the summer monsoon to a neutral China-coast port and sell** (signature loop) | probe scenario 6 + `test_discovery`/`test_world_map` (145 ports) | SCS prevailing **NE (m1) → SW (m6)**; quanzhou is `nation_id: ""`; its market works off resting stock — **silk stock 160, first-unit quote 84 g; bought 20, sold 20** |
| 7 | Patrol/treasure on `canton_country_trade`; pirates camping `taiwan_strait` | `test_npc_fleets` §20 (lanes + anchor probes) | fill + 60 live ticks put role traffic on **all five new lanes**; the anchor primitive camps `taiwan_strait` + `ceylon_south` within Chebyshev 6 |
| 8 | Draw a hunter, slip away, watch it camp the wrong harbor (rescaled radii) | `test_npc_fleets` §13 (regression, unchanged) | routes to `last_departed_port`, camps 10 days, chases only inside **30**, gives up beyond **40**, intel cell updates; pursuit A* re-measured **≤ 61 ms worst/day vs the 250 ms budget** (no windowing needed) |
| 9 | Flip both S19 toggles mid-run | probe scenario 8 + `test_save_v6` | `control_prefs` flips live (helm + drift), persists in the v6 payload; `debug_overlays` never enters a payload (asserted) |
| 10 | zh/en parity | validator group 2 + the orchestrator audit | **501 ui_strings keys** (448 → 501), every `t_key` reference resolves, zero `<key>` fallbacks; placeholder parity enforced per key |

### Debug-chart sanity eyeball (§2.12)

Scrub month 1 vs 7 with the S19 row on (evidence: `test_chart` 100 checks +
probe scenario 7; hand-run = same reads):

- Monsoon wind arrows reverse (SCS NE→SW; Somali current flips at lookup).
- Baltic ice appears (12–3) and disappears; Hudson/White Sea likewise.
- `hanseatic_north` swaps variant (winter solid in month 1, base in month 4).
- No lane crosses land (builder walk + group 8/10); no port dot sits in open
  sea or permanent ice (group 6 harbor agreement, 145 ports).
- The neutral China-coast cluster is visible (grey, `PORT_NEUTRAL`).
- Currents form coherent gyres (Gulf Stream N/3 up the American coast, ACC
  all-E, Somali stored S flipping N in summer).
- `taiwan_strait` chokepoint diamonds render; fleets dwell/dock on their
  lanes day over day (`test_ecology`/`test_aliveness`).
- The scrubber is pure view state: a save taken mid-preview round-trips
  byte-identically (snapshot-digest suite).

---

## How to play it by hand

```bash
godot --path .
```

1. **Title → Settings (S19 via S1):** set 输入模式 Input mode = 掌舵 Helm, and
   调试图层 Debug overlays = 开 On. Close → **New Game → Portugal → Confirm**.
2. **Sail (Helm):** a direction key sets the heading; the fleet steams on its
   own, re-timing as weather/trim/currents change. `Space` stops; again = wait
   one day. `[` / `]` trim the sails — watch the interval change when you reef
   into a storm. **Esc does not touch the helm** (it still closes modals/opens
   the Chart edges as before).
3. **Feel the buckets:** point the bow east out of Lisbon with an easterly —
   you crawl at 10 tiles/day; turn and run west — 26. Click a destination and
   watch the helm cancel itself (click-to-sail is wind-blind; timing the
   monsoon is your job).
4. **The Gulf Stream (Chart → `C`):** ride it north in Modifier mode and feel
   ×1.24; flip 洋流模式 to 漂移 Drift in S19 and watch the fleet drift 4
   tiles/day with the stream on day ticks.
5. **Wait for the wind:** reef (or furl) and `Space` through a storm — hull
   damage 3–4 instead of 5–7; morale still pays, the tactic is the point.
6. **Winter sailing:** point at the Baltic in month 12 — the sea refuses you
   (海冰封冻 toast); open the Chart (`Tab`), scrub `,`/`.` to month 7 — the
   ice melts on the preview only.
7. **The monsoon run:** in month 6 ride the SW monsoon east to **Quanzhou
   (泉州)** — a grey 中立港 with no nation. Dock (the market/inn/tavern all
   work; no NPC fleet will ever serve it). Sell silk, watch the stock walk.
8. **The debug chart:** with the row on, the Chart gains `D` (omniscient),
   the 17-lane network + spokes + chokepoints + legend, live fleets, wrecks,
   hunter-intel ring/cross, and the month scrubber. Nothing you do there can
   change the game (read-only, suite-proven).
9. **Hunters:** pirate hard, sail from a port, and watch the bounty hunter
   sail the lanes to your last port, chase inside 30, give up at 40.
10. **Language:** flip 中文/EN in S19 — every new label (帆位, 洋流, 海冰,
    调试图层, Year·Month, 一月…十二月) flips with no `<key>` literal.

### Reported-bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Any
`SCRIPT ERROR` in the terminal is a real defect. A pre-Phase-6 save is
refused by design (`pre-release save_version 5 (this build reads 6)`).

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-11-01 |
| Branch / commit | `main` @ the Phase-6 completion commit (see the backlog's completion record) |
| Godot | 4.7.stable.official.5b4e0cb0f |
| World artifact | `data/maps/world.png` — regenerated at 4320×2160 by `build_world.py`; **byte-identical** rebuilds (sha `8f9daee4…`); 4 677 491-tile connected sea from Lisbon |
| Ocean artifacts | `wind_regions.png` (4 696 104 painted tiles / 25 regions; 614 VAR-fallback tiles) · `currents.png` (61 007 tiles / 23 systems); **byte-identical** rebuilds |
| Route artifact | `data/trade_routes_built.json` — 17 lanes / 633 waypoints / 28 345 route tiles / **1 161 junction nodes · 1 223 edges**; spokes 90 lane + 55 override + 0 capital + 0 fallback = **145/145 ports**; **byte-identical** rebuilds |
| Command | `python3 tools/run_tests.py` |
| Result | **37 suites, 6 538 checks, 0 failures, 0 zombie/hang**, exit 0 |
| Acceptance probe | `demo_probe_phase6.tscn` — **ALL PASS (21 checks)**, exit 0 |

### Gate results

| Gate | Result |
|---|---|
| `python3 tools/validate_data.py` | **exit 0** — groups 1–10 PASS (100 sovereign + 45 neutral ports; 17 lanes; 3 ice regions × 12-month window passability; 2 ocean rasters) |
| `build_world.py` / `build_ocean.py` / `build_routes.py` | **byte-identical** rebuilds (three `--check` runs) |
| 37 suites (`tools/run_tests.py`) | **6 538 checks, 0 failures, 0 zombie/hang** |
| `godot --headless --quit-after 3` | exit 0, zero `SCRIPT ERROR` |
| day tick @ 288 fleets | **19.2–20 ms avg / 28–29 ms worst** (gate ≤ 50 ms) — parity lookups add ~2 µs/fleet/tick |
| day tick @ extreme ≈1 100 | **71–74 ms** (gate ≤ 150 ms) |
| pursuit A* (chase radii 30/40, replanned daily, worst water) | **60.6–61.5 ms worst/day** vs the 250 ms/day budget — **no windowing needed** (correction 13 verdict) |
| save payload @ extreme | **1.19 MB** (gate ≤ 2 MB) |
| save version | **v6 round-trips; v5 refused** (pre-release message; state untouched) |
| locale audit | **501 keys, 0 bad** in zh and en; zero literal `t_key` misses |
| demo loop (`00-*` §7) | green via `test_demo_loop` (83) + `test_world_e2e` (108; 4 real voyages 128–4 872 tiles inside their envelopes) |

### Suite counts at the gate

| Suite | Checks | | Suite | Checks |
|---|---:|---|---|---:|
| test_aliveness | 144 | | test_officers | 104 |
| test_battle | 218 | | test_ocean *(new)* | 133 |
| test_battle_economy | 68 | | test_palace | 183 |
| test_battle_screen | 122 | | test_phase2_acceptance | 140 |
| test_bounty | 80 | | test_phase3_acceptance | 102 |
| test_chart *(new)* | 100 | | test_port_hub | 253 |
| test_character | 409 | | test_quests | 105 |
| test_demo_loop | 83 | | test_retirement | 78 |
| test_density | 82 | | test_sailing | 118 |
| test_discovery | 236 | | test_save | 220 |
| test_duel | 148 | | test_save_v6 *(renamed)* | 307 |
| test_ecology | 76 | | test_shipyard | 141 |
| test_economy | 80 | | test_tavern | 268 |
| test_equipment | 149 | | test_tournament | 144 |
| test_fleet | 193 | | test_trade | 350 |
| test_inn | 116 | | test_weather | 225 |
| test_morale | 260 | | test_world_e2e | 108 |
| test_movement | 451 | | test_world_map | 287 |
| test_npc_fleets | 365 | | **total** | **6 538** |

### Phase-6 deltas worth recording

- **Suites 35 → 37**, checks **6 008 → 6 538** (+530). New: `test_ocean`
  (133, the direction-aware core), `test_chart` (100, overlays + debug
  purity); `test_save_v5` → `test_save_v6` (307; v6 round-trip, v5 refusal,
  `debug_overlays` leak-proofing).
- **World 2160×1080 → 4320×2160** at 12 tiles/° (5 nm): every tile-domain
  constant swept by task R (speeds {16,20,24}, sighting 48/36, hunter 30/40,
  lane stepping 2/day base, coastal band 6, `battle_mp = speed / 4`); the
  two-stage `sail_path.gd` benchmark re-run at 9.33 M cells — **full-stage
  worst real route ≈ 1.4–1.9 s, over the 1 s budget; verdict ship-as-is**
  (every legal click is answered by the sub-millisecond near stage; the
  coarse-waypoint escape hatch stays unimplemented per correction 3).
- **The monsoon world got destinations:** +45 neutral ports (China 13, Japan
  7, Korea 2, SE Asia 7, India/Persia/Arabia 10, Swahili/Red Sea 6) + 5
  regional lanes; `botany_bay` re-placed to Shark Bay (Dirck Hartog 1616;
  nation holland; id kept) — the one content amendment to the sovereign 100.
- **Ocean layers:** 25 wind regions (5 VAR-justified), 23 current systems
  (Somali reversal at lookup), 3 seasonal ice regions with month-keyed
  passability; decoded once per session (~1 s each, split eager/lazy), ~2 µs
  per live lookup.
- **Save v6** (no migration, v5 refused): `control_prefs`, `world.sail_trim`,
  `world.heading`, `world.wind_dir` join the payload; hunter keys carry over
  re-based; `debug_overlays` is session-only and provably never saved.

### Known limitations carried forward (not defects)

- **Pre-release saves do not migrate** by design (`90-*` §8.2, decision 12).
- **Mid-phase saves never load** (dev-stage rule): a save from before a wave
  in this phase's development is refused by the version bump.
- **NPC parity accumulators are transient** (per-fleet fractional carry resets
  on load/new-game — deterministic within a session; never persisted, §2.8).
- **Neutral ports are player-only frontier markets** this phase: no NPC fleet
  serves them (probe-proven), and they can never close — a documented safe
  haven until a later phase adds local nations.
- **The autopilot stays wind-blind** by design (decision 4); chart-click
  long-distance autopilot remains the Phase-7 candidate.
- **45° tacking is arithmetic break-even** (0.70/√2 ≈ 0.495 vs 0.50) under
  the locked direction buckets — the real seam skill is seasonal timing
  (scenario 2's 2.00-vs-0.77-day spread), recorded so nobody "fixes" the
  buckets by accident later.
