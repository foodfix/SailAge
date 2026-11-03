# W7-B — Phase-8 Acceptance Record

Definition of "Phase 8 complete": `docs/IMPLEMENT-Phase8.md` **W7** — the
balance & acceptance wave on top of W1–W6. The RPG overhaul is in: the
unified **Person model** (5 attributes + 11 skills) shared by player,
officers and NPC captains, officer posts + loyalty + advice events, the
**closed named-captain canon** (1,275 cards) with the defeat → return-queue
lifecycle, at-sea/in-port interactions, the **appointed voyage**
(navigator-gated auto-sailing with a weighted A* tier), the two-step
**new-game creation**, **save v9** (v8 refused, no migration), the unified
character card, and the retirement screen's RPG segment. Two layers of
evidence, the same shape as the Phase-2–7 records:

1. **Scripted** — 50 shipped suites (incl. the Phase-8 families
   `test_skills` / `test_captains` / `test_captain_lifecycle` /
   `test_interactions` / `test_hail` / `test_captains_table` /
   `test_autopilot` / `test_character_card` / `test_creation` /
   `test_retirement` / `test_save_v9`), the
   `tools/demo_probe_phase8.tscn` acceptance probe (the nine W7-B
   scenarios, 99 checks), `tools/sim_trade.py` (gates 1–10 at the
   `seamanship/300` clamp [0, +0.30]), and the validator at groups 1–12.
2. **Manual** — the demo loop (`00-*` §7, the amended two-step creation) on
   a fresh v9 save, re-proven by `test_demo_loop` (84 checks) at the W6
   gate and re-runnable by hand per §"How to play it by hand" below.

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/validate_data.py            # exit 0, groups 1-12
python3 tools/build_captains.py --check   # byte-identical rebuild, exit 0
python3 tools/build_routes.py --check     # byte-identical rebuild, exit 0
python3 tools/build_world.py --check-snaps data/ports.json   # exit 0
python3 tools/build_ocean.py --check      # byte-identical rebuild, exit 0
python3 tools/sim_trade.py                # gates 1-10, overall PASS (byte-stable)
python3 tools/run_tests.py                # 50 suites; exit 0; 0 zombie/hang
godot --headless res://tools/demo_probe_phase8.tscn   # ALL PASS (99 checks)
godot --headless --quit-after 3           # exit 0, no SCRIPT ERROR
```

---

## The W7-B scenarios — how each is verified

| # | W7-B scenario | Verified by | Recorded result |
|---|---|---|---|
| 1 | Appointment & prereqs | probe scenario 1 + `test_autopilot` gate matrix | no pilot → gate not ok, the `sail.autopilot` reason (threshold **40**, text via I18n); a nav-35 pilot hired through the REAL `Character.recruit` + `Skills.appoint` path (**200 g** signing at wage 20, CHA 10 → ×1.0) still leaves the gate closed; nav 45 + known destination → ok; `Autopilot.appoint` lands the save-v9 `player.autopilot` key + a **54-step** route; purse untouched (no gold fee) |
| 2 | Captain commissioning | probe scenario 2 + `test_skills` / `test_character` | signing cost carries the charisma multiplier: CHA 60 → **188 g** = ceil(25×10×0.75); the §4.8 `officer_states` entry seeds loyalty 50 / sea_days 0 / idle / ×1.0 wage; the pilot post seats (prereq navigation 36 ≥ 20) and the contribution reads through `Skills.effective_skill` — sighting **48 → 51**; the ledger charges **25 g/day** |
| 3 | Capture-no-idle ⇒ loot convert | probe scenario 3 + `test_battle_economy` / `test_captain_lifecycle` | a `BattleResult.apply` victory with zero idle officers → `capture_gate_failed == "no_idle_officer"`, the hull loot-converted and scuttled (6 wine → hold flagship-first, **8 units burn** with her), no fleet growth; with an idle officer the prize joins: durability **80 → 20** (the 25% transform), crew 0, fleet 1 → 2 |
| 4 | Two-step creation | probe scenario 4 + `test_creation` (80) | the S2→S20 static handoff (`pending_nation_id`) is consumed by the screen's `_ready`; steppers cap at +3 (attribute extreme **21** shown as 10+5+3+3; skill extreme 8 ≤ **13**); 均匀分配 spends exactly +1×5 attributes + first-three skills (+5/+3); the must-spend-all gate disables confirm with a leftover point; confirm runs `new_game` and the block carries nation `spain` / background `background_navy_cadet` / the allocs (courage 19 = 10+5+3+1); the derived preview equals the closed forms (sighting 48, speed 0.0033 = 1/300, duel 5 → 6) |
| 5 | Advice event | probe scenario 5 + `data/officer_posts.json` triggers | a seated cook (cooking 30 ≥ 20) + morale 30 (< 40): scanning days 1..200 deterministically, the seeded 3% roll (`hash(day|officer) % 100 < 3`) fires on day **20**; `Advice.day_tick` queues exactly `advice.cook.morale_low`, `drain()` hands it to the notice flow once, non-firing days queue nothing |
| 6 | Retirement segment | probe scenario 6 + `test_retirement` (97) | fixture `captain_states` (a 5-win nemesis leader, a 2-2 win tie, a 0-win stance −9 grudge) + `officer_states` (loyalty 88 over 120 sea-days vs 95 over 89) → the ending screen's RPG rows read exactly those: the wins-ranked nemesis rows (tie by captain id), the deepest **negative** stance (−9, 0 wins), the ≥90-day veteran (88/120; 95/89 ineligible), the background bio |
| 7 | Appointed voyage | probe scenario 7 + `test_autopilot` (96) | gate gray without a pilot (reason renders); auto-cancel on hostile contact — `cancel("contact")` returns true and clears the key; a storm does **not** cancel — the trim auto-reefs, the key survives, the first fair tick restores; weights: a nav-70 pilot's route measurably differs from a nav-50 pilot's on lisbon→malacca in month 1 — **1885 steps / 113.6 cost-days vs 1885 steps / 121.4 cost-days (ratio 0.935), different wind-region crossings** |
| 8 | Nemesis lifecycle | probe scenario 8 + `test_captain_lifecycle` (67) / `test_npc_fleets` §9c | a pirate canon card at stance −3 ⇒ `is_nemesis` (a trader at −3 never); defeat books `returning @ day+60` (65); the re-spawn path books a **hunter-role, nationless, hostile** fleet under its own name (spawned day 65); tier drift clamps at **1 and 3** (5 wins from tier 1 → 3; crushed defeat at 1 → 1) |
| 9 | zh/en parity | probe scenario 9 + validator group 2 | the locale toggle flips sampled strings both ways (`advice.cook.morale_low`, `creation.spread`, `sail.autopilot.cancelled_contact`) and canon card names resolve per locale; **878 ui_strings keys, zh/en complete** (844 after W2 + master +2 + W6-D +32) |

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-11-03 |
| Branch / commit | `phase8-acceptance` = `main` @ **`7bdcd26`** (the W7 master freeze: the advice module `9c693fb` + the attr-family unification) + this commit's two probe/record files only — every gate below ran in the slot worktree at that merged HEAD |
| Godot | 4.7.stable.official.5b4e0cb0f |
| World / ocean / route / roster artifacts | **byte-identical** rebuilds (`--check` ×4, see the gate table) |
| Economy harness | `tools/sim_trade.py` — gates 1–10 **overall: PASS** at the `seamanship/300` clamp [0, +0.30] (no fallback to +0.25 needed; byte-stable across runs) |
| Command | `python3 tools/run_tests.py` |
| Result | **50 suites, green=50, red=0, zombie/hang=0**, exit 0, total wall **290.1 s** |
| Acceptance probe | `demo_probe_phase8.tscn` — **ALL PASS (99 checks, 9 scenarios)**, exit 0 (~18 s headless) |

### Gate results

| Gate | Result |
|---|---|
| `python3 tools/validate_data.py` | **exit 0** — `OK all check groups passed (1-12)` (the canon-quota & uniqueness groups, officers-v2 specialty/captain quotas, gates/posts/backgrounds shapes, pirate `drop` pins, `npc_captains.json` absence, ui_strings parity; the map WARN lines are the §8.1 informational disconnected components, never failures) |
| `build_captains.py --check` | `--check ok (3 files byte-identical)` |
| `build_routes.py --check` | `check OK — rebuild is byte-identical (1764589 bytes)` |
| `build_world.py --check-snaps` | `check-snaps OK — 150 ports snapped within 2 tiles with a shore tile` |
| `build_ocean.py --check` | `check OK — both rasters rebuild byte-identical` |
| `sim_trade.py` gates 1–10 | **all PASS** at the +0.30 speed clamp: ① every starter profitable (worst england 13.792 g/day); ② fully-foreign ≤ 0.6× permitted (worst **0.419**); ③ monsoon specialty ≥ 1.2× home (worst **1.800×**); ④ ≤ 3× pre-tax (worst 0.419×); ⑤ recovery ≤ 30 days (worst exactly 30); ⑥ coaster damping ≥ 0.5× (worst **0.781**); ⑦ greedy bot **68 970g**/360d ≤ 80 000g; ⑧ 120-unit < 2.2× 60-unit; ⑨ nearest staple ≤ 120 tiles; ⑩ producer health **0.982** ≥ 0.5 capacity |
| 50 suites (`tools/run_tests.py`) | **green=50, red=0, zombie/hang=0**, exit 0, **290.1 s** total wall |
| `godot --headless --quit-after 3` | exit 0, **zero `SCRIPT ERROR`** (zero error lines at all) |
| day tick @ the filled normal cap | **68 ms avg** @ **318 fleets** (`test_density` PROFILE `density_normal_avg_ms=68`, gate ≤ 75 ms). **Cap arithmetic correction:** the 2026-11-02 five-port amendment re-derives the normal cap to **318 core + 16 slack = 334 global** (`npc_config.json` `absolute_cap` bounds it; the suites pin the closed form `core_cap() == 318`, not the backlog's stale "323" which predates the 150th port) |
| day tick @ extreme ≈ 1 172 fleets | **285 ms** (gate ≤ 350 ms; marginal cost linear: 1172 ≈ 3.7× 318) |
| pursuit A* | **21 ms worst** (test_npc_fleets PROFILE `pursuit_worst_ms=21` vs the 250 ms/day budget) |
| save payload @ extreme | **2 111 818 B ≈ 2.01 MB** (`test_density` PROFILE `density_extreme_save_bytes`, gate ≤ **2.25 MB** — the 60-* §4.11.11.5 row amended 2026-11-03: the v9 `captain_states` rows add ~190 KB at extreme) |
| save v9 round-trip | `test_save_v9` **493 checks** green; synthetic extreme-save fixture **1 166 226 B** (PROFILE `save_v9_extreme_bytes`); v8 refused; mid-phase saves never load (90-* §8.2) |
| locale audit | **878 ui_strings keys, zh/en complete** (probe scenario 9 + validator group 2; zero `<key>` fallbacks) |

### Suite counts at the gate

| Suite | Checks | | Suite | Checks |
|---|---:|---|---|---:|
| aliveness | 138 | | market_screen | 218 |
| allegiance | 390 | | morale | 264 |
| autopilot | 96 | | movement | 479 |
| battle | 276 | | npc_fleets | 956 |
| battle_economy | 151 | | ocean | 130 |
| battle_screen | 123 | | officers | 51 |
| bounty | 80 | | palace | 219 |
| captain_lifecycle | 67 | | phase2_acceptance | 140 |
| captains | 61 | | phase3_acceptance | 102 |
| captains_table | 125 | | port_hours | 55 |
| character | 426 | | port_hub | 329 |
| character_card | 138 | | quests | 105 |
| chart | 191 | | retirement | 97 |
| creation | 80 | | sailing | 149 |
| demo_loop | 84 | | save | 224 |
| density | 78 | | save_v9 | 493 |
| discovery | 208 | | shipyard | 274 |
| duel | 160 | | skills | 156 |
| ecology | 76 | | tavern | 646 |
| economy | 140 | | tournament | 145 |
| equipment | 158 | | trade | 441 |
| fleet | 193 | | weather | 250 |
| hail | 113 | | world_e2e | 94 |
| inn | 115 | | world_map | 298 |
| interactions | 89 | | arrival_jump | (waypoint audit: 85 510 waypoints, 0 heal snaps) |

**Σ 10 071 checks across 50 suites** (the probe is NOT in the test family —
`run_tests.py` globs `test_*.tscn` only; the Phase-7 gate was 7 689 / 39).

### The W1–W6 stamps' cross-references (corrections & concretizations the record quotes)

| # | Item | Where it landed | What the gate shows |
|---|---|---|---|
| 1 | **Fleet-cap arithmetic correction (323 → 334)** | W4 status stamp + `test_density` (`core_cap() == 318` pin) | the 150-port normal cap re-derives to **318 core + 16 slack = 334 global**; the backlog's "323" rows read as their 145-port measurements; the day-tick gate held at the new population (**68 ms ≤ 75 ms**) |
| 2 | **Storm-headway anchor** | W1 slot-A gate concretization (`20-*` §4.7) + W3's `test_world_e2e` fixture (courage 100 → retention 0.6125, storm-day bound 22, calm 19 the envelope floor) | `test_weather` (250) + `test_world_e2e` (94) green at the anchor |
| 3 | **Sparring in-band values** | W5 status stamp (`80-*` §4.11 illustrative fixed) | in-band **0.30 / 0.50 / 0.80** at swordplay 0/40/100; `test_tavern` (646) pins the seeded bets |
| 4 | **Removal-funnel reading** | W4 master integrations (`test_captain_lifecycle` 67) | a lazy read creates nothing; removal releases; **the return queue books only at the battle seam** (`Captains.defeat` via `BattleRewards.apply_captain_lifecycle`) — probe scenario 8 re-observes the booking |
| 5 | **Grudge negative-stance gating** | W6 master fix (`70-*` grudge row; `80-*` §4.14 empty-state convention) | a merely-met captain at stance 0 holds no grudge — the row renders `ui.empty`; probe scenario 6's −9 grudge is the eligible case |
| 6 | **Advice-event master landing** | the master's advice module (`scripts/world/advice.gd`, `9c693fb`: 3% seeded roll per in-post officer, situation-gated, ledger day-tick call, world notice drain) over W2's data | the trigger table (`officer_posts.json` `advice`), the closed 6-key `advice.*` string family, and the validator's §4.21 closed-set check pre-date it; the runtime is probe scenario 5 (fire day 20/200 for the probe cook) |
| 7 | **Charisma price multiplier** | W1 master micro-integration (`50-*` §4.2/§4.5.2) | signing cost ×`clamp(1−(CHA−10)/200, 0.5, 1.0)`: probe scenario 2's **188 g at CHA 60** (×0.75), 200 g at CHA 10 (×1.0) |
| 8 | **Bounty pinpoint base** | W1 master micro-integration (`70-*` §4.5) | base 100 g, then the charisma multiplier, then the rumour ≥ 40 half — `test_bounty` (80) green |
| 9 | **Appraisal price memory session-transient** | W1 master micro-integration (`30-*` §4.2) | `test_trade` (441) / `test_market_screen` (218) green |
| 10 | **Speed clamp +0.30 measured, not fallen back** | W7-A's brief, re-run here | sim_trade gates 1–10 **overall: PASS** (worst fully-foreign ratio 0.419 ≤ 0.6; greedy bot 68 970 g ≤ 80 000 g) — the +0.25 fallback never triggered, `20-*`/`50-*` stand unamended |
| 11 | **attr-family unification** | the master's `7bdcd26`: the W6-D duplicate `attr.*` family retired from lookups onto `char.attr.*` | ui_strings stays **878 keys** zh/en complete (a key-rename, not a count change); validator group 2 green at the merged HEAD |

---

## How to play it by hand

```bash
godot --path .
```

1. **New Game → 国籍 → 出身 → 自由点数** (the amended two-step creation,
   `00-*` §7 step 2): pick a background card, spend the +5/+3 with the
   steppers (均匀分配 if you like), watch the sighting/speed/duel preview
   move, confirm. You spawn at the nation's start port.
2. **Recruit & appoint** (tavern): hire an officer (the signing fee shows
   the charisma discount), open their card, 任命 into a post — the pilot's
   sighting, the boatswain's speed, the cook's morale decay all move the
   derived numbers on your own card (the "without this officer" diff).
3. **委任航行** (chart screen or right-click a known harbor): gray until a
   navigation ≥ 40 pilot sits in post; then the HUD bar shows
   destination/ETA/取消. A nav ≥ 70 pilot rides the wind — same OD,
   measurably cheaper days. Hostile contact cancels with a notice; storms
   just reef the sails.
4. **Advice events**: sail with a cook and let morale sag below 40 — the
   cook's hot-meal hint surfaces as a notice line.
5. **Hunt a nemesis**: grind a pirate's stance to ≤ −3 (attack him,
   intimidate him), sink him — he comes back on day +60 as a nationless
   hunter flying his own name.
6. **Retire** (S13): the ending screen's 宿敌榜 / 最深恩仇 / 最忠诚老部下 /
   出身回望 rows summarize the run's grudges and veterans.
7. **Language**: flip 中文/EN in S19 — every Phase-8 surface (creation,
   cards, posts, advice, gates, hail, autopilot HUD) flips with no `<key>`
   literal.

### Reported-bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Any
`SCRIPT ERROR` in the terminal is a real defect. A pre-Phase-8 save is
refused by design (`save_system.gd`: any payload whose `save_version` is
not 9 — v8 included — is a pre-release save and is refused by name, state
untouched).

---

## Known limitations carried forward (not defects)

- **Pre-release saves do not migrate** by design (`90-*` §8.2): a v8 or
  older payload is refused wholesale, state untouched. Mid-phase saves
  never load (dev-stage rule).
- **The weighted route's ≥15%-cheaper arm is bounded by the wind field**
  (regions are flat per month): on lisbon→malacca the measured saving is
  6.5% of model cost-days, and the locked gate's second arm (different
  wind-region crossings) is the satisfied discriminator — the same
  documented shape as `test_autopilot`'s NOTE lines.
- **The advice roll is per (day, officer) hash, 3%** — a given officer's
  hints are reproducible per day; the queue is session-transient and a
  load starts it empty (like `npc_port_log`).
- **The capture gate's idle-officer arm is reachable only through the
  2-slot idle bench** (`OFFICER_MAX = 12` = 6 flagship + 4 captain + 2
  bench) — manning a prize is a post appointment, never a 13th recruit.

---

## Acceptance checklist

- [x] `python3 tools/validate_data.py` exit 0, groups 1–12
- [x] `build_captains.py --check` byte-identical
- [x] `build_routes.py --check` byte-identical
- [x] `build_world.py --check-snaps data/ports.json` exit 0
- [x] `build_ocean.py --check` byte-identical
- [x] `python3 tools/run_tests.py` — 50 suites green, 0 zombie/hang
- [x] `godot --headless res://tools/demo_probe_phase8.tscn` — ALL PASS
- [x] `godot --headless --quit-after 3` — zero `SCRIPT ERROR`
- [x] day tick ≤ 75 ms at the filled normal cap (68 ms @ 318 fleets)
- [x] save payload ≤ 2.25 MB at extreme (2 111 818 B)
- [x] zh/en parity — 878 keys, complete both locales
- [x] `tools/sim_trade.py` gates 1–10 — overall PASS at the +0.30 clamp
- [x] `tools/demo_check_phase8.md` — this record, dated 2026-11-03
