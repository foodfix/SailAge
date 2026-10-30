# H — Phase-2 Acceptance Record

Definition of "Phase 2 playable": `docs/IMPLEMENT-Phase2.md` **H** — four
scripted end-to-end scenarios, each starting from a **Phase-1 save file**, all
four running clean:

1. win by cannons,
2. win by boarding + capture,
3. retreat,
4. lose a duel as the last ship → `gameover.captured`.

Two layers of evidence, the same shape as `tools/demo_check.md`:

1. **Scripted** — `tools/test_phase2_acceptance.tscn` writes a real
   `save_version: 1` payload to `user://saves/save_1.json`, loads it through
   `SaveSystem.load(1)` so the v1 → v2 migration runs, then drives the shipped
   scenes (`world_map.tscn` for the contact, `battle_screen.tscn` for the
   fight, the §4.12.4 sequence for the aftermath). Run:

   ```bash
   godot --headless --path . tools/test_phase2_acceptance.tscn
   ```

   → must print `ALL PASS (142 checks)` and exit 0.
2. **Manual** — the play-it-by-hand section below covers what a headless suite
   cannot judge (feel, layout, whether the encounter is *findable*).

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/validate_data.py                                  # exit 0
godot --headless --path . tools/test_phase2_acceptance.tscn      # ALL PASS (142 checks)
for t in tools/test_*.tscn; do godot --headless --path . "$t"; done
godot --headless --path . --quit-after 3                         # exit 0, no SCRIPT ERROR
```

The full suite count at the Phase-2 gate is **3 599 checks across 22 suites**
(see the table at the bottom). The counts are compared, not just the green
summary — Phase 1 once lost 141 → 103 checks behind an `ALL PASS` line.

---

## How to play it by hand

```bash
godot --path .          # title screen at 1280×720
```

1. **Title** → **New Game** → pick a nation (Portugal is the reference run) →
   **Confirm**. You start docked in Lisbon with 5 000g and a caravel.
2. Click **Set Sail**. You are at sea on Lisbon's harbour tile.
3. Sail east into open water. Each sea day ticks a ~1 % pirate roll
   (`60-*` §4.1); within a dozen or two days a red square marker appears and
   walks one tile per day toward its anchor port.
4. **Let it reach you** (or right-click an adjacent marker to attack it). A
   pirate contact opens **S10** automatically with
   `encounter.contact`; nothing else happens on the map until the battle ends.
5. Fight with the action buttons: **Cannon** (fires in range 1–3, then reloads
   for a turn), **Board** (a best-of-5 captain duel; winning captures the hull),
   **Ram**, **Hold**. `Esc` opens **Retreat / Surrender** (both confirm first).
6. Win → the after-action dialog lists loot gold, XP, captures and reputation
   deltas; **Continue** returns you to the world map on the contact tile, the
   marker is gone, and no pirate spawns for 3 days.
   Retreat → the marker stays, stands still for one day, and does **not**
   immediately re-open the battle.
7. Press **L** anywhere to toggle zh ↔ en; no `<key>` literal should ever
   appear.

### Reported bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Console output
from the terminal running Godot is the most useful attachment; any
`SCRIPT ERROR` there is a real defect, but `Fleet.normalize_all` warnings on a
hand-edited save (or a capture that over-fills a hold) are expected.

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-10-30 |
| Branch / commit | `p2/w4-h` — see `git log -1` |
| Godot | 4.7.stable.official.5b4e0cb0f |
| Command | `godot --headless --path . tools/test_phase2_acceptance.tscn` |
| Result | **ALL PASS (142 checks)**, exit 0, zero `SCRIPT ERROR` |

### Shared fixture (all four scenarios)

| Item | Value |
|---|---|
| Save | a real `save_version: 1`, `phase: 1` payload on `user://saves/save_1.json` (§90-* §8.1 keys, no Phase-2 field, no `equipment` block) |
| Load path | `SaveSystem.load(1)` → `MIGRATIONS[1]` (`hostile_fleets: []`, `proximity_cooldowns: {}`, `player.equipment`, per-ship `equipment`, `phase: 2`) |
| Map / tile | shipped `p1_mediterranean.txt`, open water at `(20, 20)` |
| Marker | `hf_<spawn day>_21_20_pirate` two tiles east, walks 1 tile/day into Chebyshev 1 contact |
| Contact → battle | `Encounters.tick` → `world_map._open_encounter` → `GameState.pending_encounter` → `battle_screen._ready` (the §4.11.11.3 handoff) |
| Round trip | `SaveSystem.save(1)` → `save_version == 2` on disk → `SaveSystem.load(1)` restores fleet / `hostile_fleets` / `proximity_cooldowns` byte-equal |

### S1 — win by cannons

| | |
|---|---|
| Setup | Phase-1 save, day 5, 5 000g, 2 brigantines (10 cannons, crew 30), combat 12; one composed 3-ship pirate on `(21, 20)` |
| Actions | one sea day (marker walks into contact) → Cannon button only, click-to-close and Hold when out of range; **no** Board/Ram ever |
| Asserts | `result == "victory"`; player used 0 board/ram actions; ≥1 hull sunk; **salvage = Σ floor(base_price × 0.05)** of the sunk hulls = 150 (sloop 3 000g), purse +150; **XP = 10 × neutralised + 5 × rounds** = 30 (1 sunk, 4 rounds) and it reached `player.xp`; pirate rep **+2 with the two nearest ports' nations** (`england`, `spain`; two ports selected first, nations deduplicated) and no other nation moved; `rep_deltas` exactly `{england: 2, spain: 2}`; marker removed; spawn immunity `day + 3 = 9`; fleet on contact tile `(20, 20)`; §4.11.1 seed = formula over day/contact/gold/fleet; after-action dialog up and `<key>`-free in both locales; v2 round trip |
| Result | **PASS** |

### S2 — win by boarding + capture

| | |
|---|---|
| Setup | Phase-1 save, 1 brigantine (crew 30), combat 12; one pirate sloop (crew 10 → defender base 8, 6 wine); fixture day selected so the §4.11.1 duel stream is a **capture** (`["win","loss","win","loss","win"]`) |
| Actions | contact → Board button once adjacent (click-to-close) |
| Asserts | `result == "victory"`; a `board` entry in the engine log; 1 captured hull, 0 sunk; fleet 1 → 2 (≤ `FLEET_MAX` 5); captured sloop joins at **max(1, floor(current × 0.25)) = 15**, **crew 0**, cannons + equipment intact, cargo intact (6 wine pooled); XP = 10 × 1 + 5 × 2 = 20; dialog localised |
| S2b (full fleet) | 5 caravels, every hold exactly full (120 wine each); same seeded capture → fleet stays at 5, `captured_ships == []`, `scuttled_ships == ["sloop"]`, **`cargo_overflow_lost == 6`**, holds unchanged (600 wine), no salvage gold (captured ≠ sunk); the dialog prints the scuttle and the overflow |
| Result | **PASS** |

### S3 — retreat

| | |
|---|---|
| Setup | Phase-1 save, 1 caravel (crew 15), combat 10; one composed pirate |
| Actions | contact → `Esc` → **Retreat** → confirm (`battle.retreat.confirm`) |
| Asserts | `result == "retreat"`; **xp 0** on the outcome *and* on `player.xp`; **salvage 0**, purse unchanged; `rep_deltas == {}`; fleet on the contact tile `(20, 20)` and that tile is passable (fallback not needed); the marker **still exists** on the tile it held at contact, with **`cooldown_until_day == day + 1`**; it raises no contact while cooling, so the battle cannot re-open; the 3-day spawn immunity is still recorded; no `game_over` fired; dialog localised; v2 round trip keeps 1 marker |
| Result | **PASS** |

### S4 — lose a duel as the last ship

| | |
|---|---|
| Setup | Phase-1 save, **one** brigantine (crew 30) but combat 1; a pirate galleon (crew 120 → defender base 26); fixture day selected so the §4.11.1 duel stream is a **defeat** |
| Actions | contact → Board |
| Asserts | `result == "defeat_captured"`; the loss came from a `board` duel; 1 hull in `lost_player`; **fleet ends empty**; `EventBus.game_over` fires **exactly once** with `"captured"`; Continue opens **S9** (not S3) and `world_route_target() == ""`; S9 accepts `captured` and renders `gameover.captured` through `gameover.reason` **in en and zh** with no `<key>` and different text per locale; v2 round trip with an empty fleet |
| Result | **PASS** |

---

## Suite counts at the Phase-2 gate

| Suite | Checks |
|---|---|
| `test_battle_economy.tscn` | 68 |
| `test_battle_screen.tscn` | 122 |
| `test_battle.tscn` | 218 |
| `test_character.tscn` | 385 |
| `test_demo_loop.tscn` | 87 |
| `test_discovery.tscn` | 141 |
| `test_duel.tscn` | 148 |
| `test_encounters.tscn` | 156 |
| `test_equipment.tscn` | 149 |
| `test_fleet.tscn` | 157 |
| `test_inn.tscn` | 116 |
| `test_morale.tscn` | 260 |
| `test_movement.tscn` | 158 |
| `test_phase2_acceptance.tscn` | **142** |
| `test_port_hub.tscn` | 140 |
| `test_sailing.tscn` | 84 |
| `test_save.tscn` | 195 |
| `test_save_v2.tscn` | 80 |
| `test_shipyard.tscn` | 141 |
| `test_tavern.tscn` | 245 |
| `test_trade.tscn` | 278 |
| `test_weather.tscn` | 129 |
| **Total** | **3 599** |

---

## Integration defects found while building this harness

Three genuine defects in the merged Phase-2 code surfaced only when the *whole*
loop ran; each is fixed minimally in this branch (the fix is part of the task,
`IMPLEMENT-Phase2.md` H item 5):

1. **`battle_screen.open_battle` used the marker's tile as `contact`.**
   `60-*` §4.11.1 pins `contact` as *the player's world tile*, so the §4.11.1
   seed and the §4.11.10 return tile were both computed from the wrong cell
   whenever the marker was not exactly on the fleet. Fixed by preferring the
   descriptor's `contact` (written by `world_map._encounter_for`) and keeping
   `position` as the fallback for hand-built encounters. Detected by the "seed =
   formula" and "fleet back on the contact tile" assertions.
2. **A retreat deleted the enemy marker.** `battle_screen._cleanup_encounter`
   called `Encounters.remove(id)` for every outcome, including `retreat`, so
   `world_map._on_battle_finished` then had no marker to put on its §4.10 +1 day
   pursuit cooldown — the documented retreat rule was unreachable and the pirate
   fleet simply vanished. Fixed by keeping the marker and calling
   `set_pursuit_cooldown(id, day + PURSUIT_COOLDOWN_DAYS)` on a retreat (both
   writes are idempotent, so S3 re-applying it is harmless).
3. **`BattleResult.apply` got bare ship instances instead of `BattleSim.units()`.**
   §4.12.3 pins the second argument as the engine's unit list; the screen passed
   `_enemy_instances()`, so `captured_units[].index` was always `-1` and the
   capture report could not name the enemy fleet slot. Fixed by passing
   `sim.units()` and dropping the now-unused helper.

None of the three changes a doc-pinned number, and all four scenarios plus every
other suite stay green.

### The stale Phase-1 assertion

`tools/test_demo_loop.gd` step 7 asserted the shipyard refit row was
**disabled** ("Phase 1"). Phase 2 enables it, so the check now asserts the Phase-2
truth — **present, disabled at 0 cannons** (the §6 "invalid points" validation),
**enabled once 5 cannons are picked** — in the same single check. The Phase-1
suite stays at **87 checks**, and no other Phase-1 assertion was touched.

---

## Manual run (human, dated)

| Date | Tester | Build | Result | Notes |
|---|---|---|---|---|
| 2026-10-30 | orchestrator (automated verification only) | `p2/w4-h` @ H | **PASS (scripted layer)** | No human visual pass recorded; the checklist below is for a tester |

### Manual checklist (to be completed by a human tester)

- [ ] A pirate marker appears within a realistic number of sea days and is
      visible as a red square on the minimap and the map.
- [ ] Contact opens S10 without a freezeframe and without leaving the marker
      drawn over the battle.
- [ ] Cannon / Board / Ram / Hold buttons enable and disable sensibly; the
      tooltip explains a refusal.
- [ ] The boarding duel modal (S11) appears on a board and cannot be cancelled.
- [ ] The after-action dialog names loot, XP, captures and reputation; Continue
      returns to the map on the contact tile.
- [ ] Retreat leaves the pirate on the map and does not immediately re-open the
      fight.
- [ ] Losing the last ship shows S9 with the "captured" cause; any key returns
      to the title with no save written.
- [ ] A full run in zh: no `<key>` literal and no English leaking through.
- [ ] No console `SCRIPT ERROR` for the whole session.

---

## Post-Phase-4 note (task L, save v4)

This record is the **Phase-2 gate** and is kept as history. Two of its facts
moved in Phase 4:

- The fixture is a current-version (`save_version` 4) payload rather than a
  `save_version: 1` file, because pre-release saves need not load (`90-*` §8.2
  development-stage scope) and the `1 → 2` migration was deleted.
- The map is the single generated world (`data/maps/world.png`); the Phase-1
  ASCII map no longer exists.

`tools/test_phase2_acceptance.tscn` still passes (`ALL PASS (142 checks)`);
`tools/test_save_v2.tscn` was deleted and its coverage folded into
`tools/test_save_v4.tscn`.
