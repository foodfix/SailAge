# N — Phase-4 Acceptance Record

Definition of "Phase 4 playable": `docs/IMPLEMENT-Phase4.md` **N** — the
**ten**-step demo loop of `docs/00-OVERVIEW.md` §7 on the single Terra Vera
world map, in both locales (`zh` and `en`).

Phase 4 replaced the two hand-authored ASCII maps with one generated
real-Earth world (2160 × 1080 tiles, 6 tiles/degree, 1 tile = 10 nm), moved
every port to real `lat`/`lon`, and re-anchored the demo loop's storm step to
a coordinate destination. The loop therefore grew a tenth step: the Chart.

Two layers of evidence, the same shape as the Phase-2/3 records:

1. **Scripted** — the shipped suites, headed by `tools/test_world_e2e.tscn`
   (the four voyages that prove the Earth works) and `tools/test_demo_loop.tscn`
   (the loop's own scripted run).
2. **Manual** — the play-it-by-hand section below for what a headless suite
   cannot judge (feel, layout, whether a storm is *followable*, whether the
   Chart is usable at a glance).

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/build_world.py                                      # regenerates world.png (idempotent)
python3 tools/validate_data.py                                    # exit 0, groups 1-6
godot --headless --path . tools/test_world_e2e.tscn                # ALL PASS (86 checks)
godot --headless --path . tools/test_demo_loop.tscn                # ALL PASS (82 checks)
for t in tools/test_*.tscn; do godot --headless --path . "$t"; done # 30 suites
godot --headless --path . --quit-after 3                           # exit 0, no SCRIPT ERROR
```

**The full suite count at the Phase-4 gate is 5 009 checks across 30 suites.**
Counts are compared, not just the green summary (table at the bottom).

---

## The ten amended steps — how each is verified

| # | Step (`00-*` §7) | Phase-4 change | Verified by |
|---|---|---|---|
| 1 | Title at 1280×720; New Game / Load / language toggle | unchanged | viewport setting + `title_screen`; suite `test_save` |
| 2 | Six nationalities → start port, ship, gold (localized) | unchanged; one map now, so the S2 map selector is gone | `nations.json` drives all six; `test_character` |
| 3 | Spawn in home port; buy a good; gold + cargo update | unchanged; spawn is the derived harbour tile | `test_port_hub`, `test_trade` |
| 4 | Sail 8-directionally; daily provisions/water/wages; land blocks | **hold-to-repeat + click-to-sail** replace tap-stepping | `test_movement` (297 checks; cadence 8 tiles/s after 0.25 s, 20 steps = 20 moves = 2.0 days) |
| 5 | A storm is reachable | **re-anchored**: Lisbon → the open water off Santa Cruz de Tenerife (coordinate destination, no docking) | `test_world_e2e` leg 1: 61 steps / 6 days, one `variables → trade_winds` transition at 29.83°N, storm gate **0.9183** closed form and **0.9183** over 10 000 seeded 6-day windows (≥ 0.90) |
| 6 | Second port; sell; supply/demand modifier shown | unchanged | `test_trade` (278 checks) |
| 7 | Shipyard, tavern (recruit an officer), inn | unchanged | `test_shipyard`, `test_tavern`, `test_inn` |
| 8 | Save in port; quit; Load; state fully restored | **save v4**; pre-release saves need not load (`90-*` §8.2) | `test_save` (205) + `test_save_v4` (157), round-trip byte-equal |
| 9 | Toggle zh ↔ en; no missing keys | unchanged, plus the new `chart.*` / `world.sail.*` keys | key audit below: **163 literal keys + 6 format-key families, 0 missing** in either locale |
| 10 | **(new)** Open the Chart (`Tab`), close it (`Esc`), see explored state | **new S17 Chart screen** | `test_discovery` (221 checks: open < 0.5 s measured 3.9–5.1 ms, `Tab`/`Esc` round-trip, 2401/2401 tiles identical to the minimap) |

---

## The Earth itself (phase-defining proofs)

`tools/test_world_e2e.tscn` sails four real voyages through the shipped
movement path — not teleports, except the provisioning stops leg 4 allows:

```
LEG     STEPS  DAYS  ENVELOPE (days)   START        GOAL         OK
leg1       61     6    3.4 ..   9.8   (1024, 308)  (980, 369)   yes
leg2      246    20   13.7 ..  30.3   (1024, 308)  (1254, 292)  yes
leg3     1146    90   63.7 .. 154.3   (1024, 308)  (1858, 343)  yes
leg4     2453   192  136.3 .. 338.6   (1024, 308)  (1024, 308)  yes
```

- **Leg 1** — arrival is open water (`port_id_at` empty): Tenerife's exact
  coordinate is land, and §6.1's snap puts the destination on `(980, 369)`.
  The storm gate is met both ways (closed form and 10 000 seeded windows).
- **Leg 2** — the **Bosphorus/Dardanelles override is provably in play**:
  refilling the 11 carved cells as land on a *copy* of the world makes
  `find_path(lisbon, istanbul)` return nothing at all, while the shipped map
  routes it in 246 steps.
- **Leg 3** — the long way really is long: reaches 34.83°S (rounds the Cape),
  threads 10 Malacca channel tiles, and touches **zero** ice-band tiles, so
  there is no northern passage.
- **Leg 4** — circumnavigation: **three seam crossings** (2 west at steps
  880/920, 1 east at step 899), netting −2013 columns westward and returning
  to exactly `(1024, 308)`.

Map integrity (validator group 6, 0.6 s): the artifact is a 2160 × 1080
indexed PNG with palette ⊆ `~ . # ^ I`; **100/100 harbours** recompute
independently from `lat`/`lon` and match `world_report.json`; a wrap-aware,
no-corner-cut BFS from Lisbon reaches **all 100 harbours and all 30
discoveries**; the eight probe ports (Istanbul, Danzig, Stockholm, Aden,
Nagasaki, Venice, London, Hamburg) are all in that component.

---

## How to play it by hand

```bash
godot --path .          # title screen at 1280×720
```

1. **Title → New Game → Portugal → Confirm.** You start docked in Lisbon with
   5 000g and a caravel. (There is no map choice any more: one world.)
2. **Market:** buy wine at Lisbon, **Set Sail**, cross to London, sell. Repeat;
   each profitable sale awards trade XP and reputation.
3. **Sail:** hold an arrow key — after a quarter second the fleet repeats at
   about 8 tiles a second. Now **click a water tile a few hundred tiles away**
   and watch it sail there by itself: the route never cuts a corner and it
   wraps across the dateline the short way. Click land: nothing happens but a
   toast, and no day passes.
4. **Storm run (step 5):** from Lisbon sail south-west to the open water off
   **Santa Cruz de Tenerife** (≈28.3°N 16.5°W — *not* a port; you cannot
   dock there). Crossing 30°N puts you in the trade-wind belt; within about
   six days at sea a storm is more likely than not (≥ 0.90 within 6 in-band
   days). Confirm the HUD weather glyph flashes and `Storm: …` damage reports
   appear in the dialog queue before the daily morale line.
5. **Second port:** dock somewhere else, sell the wine, read the supply/demand
   line and the profit/loss.
6. **Shipyard / Tavern / Inn:** repair, recruit Mateus Álvares (his +10
   navigation raises the sighting radius from 24 to 25 — hover a port and see
   it appear from further off), rest a day at the inn.
7. **Chart (step 10):** press **Tab**. The whole Earth appears at ~0.57×,
   explored water lit and unknown water dark, known ports as nation-coloured
   dots, the fleet as a white square, discovery leads as accent crosses. It
   opens in a few milliseconds and never pauses the game. **Esc** returns you
   to exactly where you were — the fleet has not moved and no day has passed.
   Press **M**: nothing happens (the old enlarged minimap is retired; the
   Chart replaced it).
8. **Minimap at the dateline:** sail west past 180°W and watch the corner
   minimap: it keeps showing a continuous 128-tile window across the seam,
   never a black gutter.
9. **Save / Load:** save in port, quit to title, load — day, gold, cargo,
   crew, morale, officers, reputation all return, and you are back on the
   *same* harbour tile.
10. **Language:** press **L** anywhere. Every label, port name, good name,
    dialog and warning flips between 中文 and English; no `<key>` literal
    ever appears (audit: 0 missing in both locales).

### Reported bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Console output
from the terminal running Godot is the most useful attachment; any
`SCRIPT ERROR` there is a real defect. `Fleet.normalize_all` warnings on a
hand-edited save are expected.

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-10-30 |
| Branch / commit | `main` — `0e57a5f` (`test(phase4): circumnavigation + chokepoint E2E`) |
| Godot | 4.7.stable.official.5b4e0cb0f |
| World artifact | `data/maps/world.png` — 29 725 B, sha256 `21b01368…9f78f` (byte-identical on rebuild, 1.2 s) |
| Command | `godot --headless --path . tools/test_world_e2e.tscn` |
| Result | **ALL PASS (86 checks)**, exit 0, 40 s wall clock |

### Gate results

| Gate | Result |
|---|---|
| `python3 tools/build_world.py` twice | byte-identical (`sha256` equal both runs) |
| `python3 tools/validate_data.py` | **exit 0** — groups 1–6 PASS |
| `tools/test_world_e2e.tscn` | **ALL PASS (86)**, four voyages |
| `tools/test_demo_loop.tscn` | **ALL PASS (82)**, demo loop complete |
| all 30 suites | **5 009 checks, 0 failures, 0 `SCRIPT ERROR`** |
| `godot --headless --quit-after 3` | exit 0, zero `SCRIPT ERROR` |
| locale audit | 163 literal keys + 6 format families → **0 missing** in `zh` and `en` |

### Suite counts at the gate

| Suite | Checks | | Suite | Checks |
|---|---:|---|---|---:|
| test_battle_economy | 68 | | test_palace | 183 |
| test_battle_screen | 122 | | test_phase2_acceptance | 142 |
| test_battle | 218 | | test_phase3_acceptance | 102 |
| test_bounty | 80 | | test_port_hub | 142 |
| test_character | 409 | | test_quests | 105 |
| test_demo_loop | 82 | | test_retirement | 78 |
| test_discovery | 221 | | test_sailing | 94 |
| test_duel | 148 | | test_save | 205 |
| test_encounters | 161 | | test_save_v4 | 157 |
| test_equipment | 149 | | test_shipyard | 141 |
| test_fleet | 157 | | test_tavern | 268 |
| test_inn | 116 | | test_tournament | 144 |
| test_morale | 260 | | test_trade | 278 |
| test_movement | 297 | | test_weather | 224 |
| test_world_e2e | 86 | | test_world_map | 172 |
| | | | **total** | **5 009** |

### Phase-4 deltas worth recording

- **Suites 30 → 30**, checks **4 545 → 5 009** (+464).
- `test_save_v2` was **removed**: it existed only to test the `1 → 2` save
  migration, and the migration chain is gone under the dev-stage scope
  (`90-*` §8.2). Its useful coverage (optional-key defaults, `hostile_fleets`
  / `proximity_cooldowns` round-trip, bad-type rejection) was folded into
  `test_save_v4`; no unique assertion was lost. `test_save_v3` became
  `test_save_v4`.
- `test_movement` 170 → 297 (hold cadence, A* click-to-sail, seam, corner-cut).
- `test_discovery` 138 → 221 (minimap crop, dateline, Chart, 24/18 reveal).
- `test_world_map` 62 → 172 (world artifact, chunks, harbour tiles).
- `test_encounters` 156 → 161, and its runtime went from minutes to **22.5 s**
  after the port-centric candidate rewrite (6.6 s → 8.8 ms).

### Known limitations carried forward (not defects)

- **Explored state is not saved** (Phase-1 limitation, unchanged): the
  minimap and Chart rebuild from the session as you sail. Both read the same
  model, so they can never disagree *within* a session.
- **`test_world_e2e` spends ~36 s of its 40 s in scene-UI refresh**, not
  simulation: `WorldMap.try_step()` is ~2.5 ms/step in headless because each
  step re-runs the 24-tile reveal and redraws the minimap, while the pure
  `SailingSim.try_move` path is 0.009 ms/step. If a future suite needs many
  more voyages, throttle the HUD refresh (every N steps) rather than touching
  the movement path.
- **Pre-release saves do not migrate** by design (`90-*` §8.2). A save from
  an older phase is refused with `pre-release save_version N (this build
  reads 4)`.
