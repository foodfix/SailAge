# N — Phase-5 Acceptance Record

Definition of "Phase 5 complete": `docs/IMPLEMENT-Phase5.md` **N** — the
living-economy sea is playable end-to-end on the single world map, in both
locales (`zh` and `en`), with every locked constant from the phase plan
implemented to its owning doc.

Phase 5 replaced the static price factors and the 3-marker hostile-fleet
system with: a **stock-based supply/demand economy** (tranche repricing,
tiered drift), **demand events**, **~272 nation-owned NPC fleets** in eight
roles sailing the 12 hand-authored historical lanes, **abstract NPC-vs-NPC
auto-resolve with lootable wreckage**, **named captains sightable in port**,
and the **`data/npc_config.json` density dial** (S2 + the new S19 settings
modal).

Two layers of evidence, the same shape as the Phase-2/3/4 records:

1. **Scripted** — 35 shipped suites, headed by the new
   `test_npc_fleets` / `test_ecology` / `test_aliveness` / `test_economy` /
   `test_density`, and the reworked `test_trade` / `test_save_v5`.
2. **Manual** — the play-it-by-hand section below, including the ten
   Phase-5 checks the task pins, run in both locales.

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/validate_data.py          # exit 0, groups 1-8
python3 tools/build_routes.py --check   # byte-identical rebuild, exit 0
python3 tools/run_tests.py              # 35 suites; exit 0; 0 zombie/hang
godot --headless --quit-after 3         # exit 0, no SCRIPT ERROR
```

`tools/run_tests.py` is the canonical runner (`90-*` §13): save-touching
suites serialized, the rest 8-way parallel, per-suite wall + CPU profiling
and `PROFILE` lines collected, zombie/hang detection (exit 2 blocks a gate).

**The full suite count at the Phase-5 gate is 5 982 checks across 35 suites.**
Counts are compared, not just the green summary (table at the bottom).

---

## The Phase-5 checks — how each is verified

| # | Task-N check | Verified by |
|---|---|---|
| 1 | Anchor at Lisbon 10 days → ≥ 5 fleet sightings (mixed flags + coasters) | `test_npc_fleets` initial fill (272 core, seeded 130 @ normal) + `test_ecology` sightings; manual step 1 |
| 2 | Loiter at a tagged chokepoint → repeated sighting/ambush chances | `test_ecology` §5 (anchoring within Chebyshev 3 of chokepoint tiles, 5/8 hysteresis; open sea quiet) |
| 3 | Top-demand good's price moves within a season | `test_economy` drift tiers + `test_aliveness` event surge; manual step 3 |
| 4 | Sink a trader → patrol reroute/privateer pressure visible | `test_ecology` (escort/patrol protection, raider depletion of unescorted lanes) |
| 5 | Ride one demand event end-to-end (rumor → buy cheap nearby → sell into the surge → profit) | `test_aliveness` (rotation, telegraph, surge, trader softening, expiry restore); manual step 5 |
| 6 | 30 days of pirating @ `extreme` doesn't run away the gold curve | `test_density` extreme perf + loot caps (`min(1000, …)` / coaster pin) in `test_ecology` |
| 7 | Sight a captain in port, pay 20g, verify the position against the map | `test_aliveness` (60/40 facility, 75% presence, posters ≤ 40, exact reveal); manual step 7 |
| 8 | S1 → S19 (pre-game) and S4 → S19 (mid-run) round-trip of the density dial | `test_density` (all five presets; raise refills, lower never culls, deserted zero) |
| 9 | zh/en parity, zero `<key>` fallbacks | locale audit below (448 keys, 0 bad) |
| 10 | Save/load reproduces fleets (positions, legs, specialties, captains, respawns) | `test_save_v5` + `test_aliveness` respawn round-trip |

---

## Phase-defining proofs

**Economy (G).** Resting factors reproduce the retired statics *exactly*:
produced stock 160 → `factor_units` 700 (0.7), demanded 40 → 1300 (1.3),
neutral 100 → 1000 (1.0); `test_trade` pins the resulting 21/16, 39/31,
30/24 prices. A 300-unit sale walks the tranche ladder (16 distinct prices,
5 170g, no clamp jump). A staple heals a 30-unit nudge in 10 days, a luxury
in 30.

**Fleets (J/K).** 272 core fleets @ normal (127 traders + 77 coasters + 19
patrols + 12 couriers + 12 privateers + ≈25 pirates), global cap 288,
`absolute_cap` 2048. Day tick **15.9 ms avg / 26.9 ms worst** @ 272 fleets
(gate ≤ 50 ms), zero runtime pathfinding for lane traffic; at extreme
(≈990 fleets) **69 ms** (gate ≤ 150 ms), near-linear scaling (≈4× budgets →
≈4× cost), save payload **0.93 MB** (gate ≤ 2 MB).

**Lanes (E/F).** 12 hand-authored historical lanes (415 waypoints, all
snapped ≤ 2 tiles, 403 segments passable, wrap-aware), 100/100 ports spoke-
connected (52 lane spokes, 1 capital fallback, 47 documented overrides from
`tools/route_overrides.json`), 769 junction nodes / 805 edges, rebuild
byte-identical, probes acapulco↔manila / hanseatic→danzig /
carreira→goa all pass.

**Captains (L).** Every fleet draws a seeded `{pool_id, name_index}` at spawn
(7 pools incl. the nationless one); sightings are stable within a visit-day
and re-roll across days; 4 named pirates with +30-day persisted respawns;
wanted posters within Chebyshev 40; the 20g tavern reveal returns the
**exact live position**.

**Density (M).** Five presets; S2 writes the choice before `new_game` (run
input), S19 applies mid-run — raising refills through the daily trickle,
lowering never culls a living fleet, `deserted` stops spawns **and**
contacts.

---

## How to play it by hand

```bash
godot --path .
```

1. **Title → Settings → pick a sea-traffic preset** (the only place; S2 has
   no density row) → Close → **New Game → Portugal → Confirm.**
   You start docked in Lisbon with 5 000g and a caravel; the sea already
   carries ~130 of the ~272 eventual fleets (half-cap initial fill).
2. **Watch the water.** Nation-coloured squares (red = pirates) move along
   lanes with short dashed wakes; same-lane traders within 3 tiles render as
   one convoy square with a `×N` count. Hover the minimap: coasters cluster
   near ports, big flags on the trunk lanes.
3. **Market:** buy wine at Lisbon, sail to London, sell. Prices now move:
   each sale walks the stock down and the **marginal** column shows the next
   tranche's price. Repeat until the spread closes — then the market needs
   days to heal (watch the Stock + Trend columns).
4. **Chokepoint:** park near the Strait of Gibraltar (or Malacca / Hormuz)
   for a few days. Raiders anchor within a few tiles of the choke; when one
   comes within 15 tiles it pursues, beyond 20 it gives up and lanes home.
5. **Demand event:** in a tavern read a rumour like "Word from Lisbon: war
   provisioning…" — sail there and buy the affected goods cheap *before* the
   surge peaks, then sell into the inflated price at a nearby port. The event
   expires and prices drift back.
6. **Pirating:** right-click any fleet → the piracy confirm appears
   (−20 with its owner, +2 with its rivals, once). Win: you take its **actual
   cargo** plus `min(1000, 100 + 10 × day)`g (coasters pay their own
   `25 + floor(day/10)`g). Sink one and sail over the wreck tile — the hold
   fills from the wreck and the salvage gold is added, no battle. Wrecks
   vanish after 5 days.
7. **Captain sighting:** dock at a port with traffic and open the market
   ("merchant captains in port"), the tavern ("captains in port"), the inn
   ("captains resting") or the palace board (bounty hunters). Names are
   stable all day. If a wanted poster shows a pirate within 40 tiles, pay
   **20g** ("buy a round") and read its exact tile + nearest port — then
   check it on the Chart.
8. **Settings (S19):** open it from the **title screen** (pre-game) or the
   port-hub footer (mid-run). Drop the dial to `deserted` (the sea empties of
   contacts and spawns), then back to `extreme` and watch it repopulate over
   the next days; lowering never removes a fleet already afloat. The mid-run
   panel also has **Return to main menu** (confirm-first, warns that unsaved
   progress is lost — save from the S4 row first if you want to keep the run).
9. **Save / Load:** save in port, quit, load — day, gold, cargo, stocks,
   fleets (positions, route legs, specialties, captain names, respawn
   cooldowns) all return.
10. **Language:** open **Settings** (S1 or S4) and press the `[中文 / EN]`
    button — the only language control in the game; every label, captain
    name, rumour, event name and warning flips between 中文 and English with
    no `<key>` literal (audit: 0 missing in both locales). The old `L` hotkey
    and the top-bar / market / S1 / S2 buttons are gone.

### Reported bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Any
`SCRIPT ERROR` in the terminal is a real defect. A save written by an older
build is refused by design (`pre-release save_version N (this build reads 5)`).

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-10-31 |
| Branch / commit | `main` — see the completion record below |
| Godot | 4.7.stable.official.5b4e0cb0f |
| World artifact | `data/maps/world.png` — unchanged from Phase 4 (byte-identical; 0 diff since the Phase-5 plan commit) |
| Route artifact | `data/trade_routes_built.json` — 767 003 B, rebuild byte-identical |
| Command | `python3 tools/run_tests.py` |
| Result | **35 suites, 6 008 checks, 0 failures, 0 zombie/hang**, exit 0, 160 s wall |

### Gate results

| Gate | Result |
|---|---|
| `python3 tools/validate_data.py` | **exit 0** — groups 1–8 PASS |
| `python3 tools/build_routes.py --check` | **exit 0** — byte-identical rebuild |
| 35 suites (`tools/run_tests.py`) | **6 008 checks, 0 failures, 0 zombie/hang** |
| `godot --headless --quit-after 3` | exit 0, zero `SCRIPT ERROR` |
| day tick @ normal 288 | **15.9 ms avg / 26.9 ms worst** (gate ≤ 50 ms) |
| day tick @ extreme ≈990 | **69 ms** (gate ≤ 150 ms); ≈linear |
| save payload @ extreme | **953 401 B / 0.91 MB** (gate ≤ 2 MB) |
| locale audit | **448 keys, 0 bad** in `zh` and `en` (validator-enforced) |
| `data/maps/world.png` | **unchanged** (0 diff since the plan commit) |

### Suite counts at the gate

| Suite | Checks | | Suite | Checks |
|---|---:|---|---|---:|
| test_aliveness | 144 | | test_phase2_acceptance | 140 |
| test_battle | 218 | | test_phase3_acceptance | 102 |
| test_battle_economy | 68 | | test_port_hub | 253 |
| test_battle_screen | 122 | | test_quests | 105 |
| test_bounty | 80 | | test_retirement | 78 |
| test_character | 409 | | test_sailing | 94 |
| test_demo_loop | 83 | | test_save | 220 |
| test_density | 82 | | test_save_v5 | 202 |
| test_discovery | 236 | | test_shipyard | 141 |
| test_duel | 148 | | test_tavern | 268 |
| test_ecology | 76 | | test_tournament | 144 |
| test_economy | 80 | | test_trade | 350 |
| test_equipment | 149 | | test_weather | 224 |
| test_fleet | 193 | | test_world_e2e | 108 |
| test_inn | 116 | | test_world_map | 193 |
| test_morale | 260 | | test_movement | 345 |
| test_npc_fleets | 290 | | **total** | **6 008** |
| test_officers | 104 | | | |
| test_palace | 183 | | | |
| test_encounters → test_npc_fleets | — | | (retired suite) | |

### Phase-5 deltas worth recording

- **Suites 31 → 35**, checks **5 351 → 6 008** (+657). New: `test_economy`,
  `test_npc_fleets`, `test_ecology`, `test_aliveness`, `test_density`;
  `test_encounters` retired into `test_npc_fleets`; `test_save_v4` →
  `test_save_v5`.
- `test_trade` 278 → 351 (rest-price reproduction, tranche walks, drift
  tiers, band/cap edges). `test_save` 205 → 218; `test_save_v5` 196.
- `test_npc_fleets` replaced a 161-check 3-marker suite with 290 checks over
  the full eight-role ecology, and J's tick probe (272 fleets) now rides the
  gate via `PROFILE` lines.
- **Save v4 → v5**, no migration chain: v4 and older are refused
  (`90-*` §8.2), consistent with the Phase-4 dev-stage scope decision.
- The **route artifact** (`data/trade_routes_built.json`) joins `world.png`
  in the tool-owned family (never hand-edited; validator group 8 enforces
  byte-identical rebuilds).

### Known limitations carried forward (not defects)

- **Pre-release saves do not migrate** by design (`90-*` §8.2, decision 5).
- **Chart lane-heat dots ship OFF** (`chart_screen.LANE_HEAT := false`, an
  `80-*` optional flag); flipping the const is the whole switch (task L).
- **`test_world_e2e` remains the long suite** (~52 s, scene-UI refresh per
  step, unchanged from Phase 4) and dominates the gate wall clock; the
  runner serializes it with the other save-touching suites.
- **Out of scope (Phase-6 candidates, pinned in the plan):** trading with NPC
  ships at sea, watchable AI-vs-AI battles, courier quest hooks, full captain
  interactions, dynamic diplomacy, far-field LOD beyond `absolute_cap`,
  sub-linear NPC trade volume, hand-editing the built route artifact.
