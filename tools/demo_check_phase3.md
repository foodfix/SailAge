# J — Phase-3 Acceptance Record

Definition of "Phase 3 playable": `docs/IMPLEMENT-Phase3.md` **J** — the two
scripted end-to-end runs, all clean:

1. new game → trade to fund expeditions → report 2 discoveries → climb to Duke
   with one nation → win one tournament → retire;
2. piracy run: raid → bounty → hunters → clear the bounty (both paths).

Two layers of evidence, the same shape as `tools/demo_check_phase2.md`:

1. **Scripted** — `tools/test_phase3_acceptance.tscn` starts on the shipped
   Phase-3 world (`new_game(..., "p3")`) and drives the shipped scenes only:
   the market engine for trading, `TavernScreen`'s Rumors tab for hints,
   `WorldMap.explore_here()` for the `E` action, `GuildScreen` for reports,
   `PalaceScreen` for missions/ceremony/tournament/retire, the real
   `BattleScreen` scenes for the bracket, `Encounters.spawn` for hunters,
   `EndingScreen` for the summary and `SaveSystem` for the round trip. Run:

   ```bash
   godot --headless --path . tools/test_phase3_acceptance.tscn
   ```

   → must print `ALL PASS (102 checks)` and exit 0.
2. **Manual** — the play-it-by-hand section below covers what a headless suite
   cannot judge (feel, layout, whether a rumour is *followable*).

---

## How to run the whole gate

From the repo root:

```bash
python3 tools/validate_data.py                                   # exit 0
godot --headless --path . tools/test_phase3_acceptance.tscn       # ALL PASS (102 checks)
for t in tools/test_*.tscn; do godot --headless --path . "$t"; done
godot --headless --path . --quit-after 3                          # exit 0, no SCRIPT ERROR
```

The full suite count at the Phase-3 gate is **4 537 checks across 30 suites**
(see the table at the bottom). Counts are compared, not just the green summary.

---

## How to play it by hand

```bash
godot --path .          # title screen at 1280×720
```

1. **Title** → **New Game** → pick a nation (Portugal is the reference run) →
   pick **The Wider World (100 ports)** → **Confirm**. You start docked in
   Lisbon with 5 000g and a caravel.
2. **Market**: buy wine at Lisbon (it produces it), **Set Sail**, cross to
   London (it demands wine) and sell. Repeat a few times; each profitable sale
   awards trade XP and reputation (`30-*` §4.2, `50-*` §4.3/§4.6).
3. **Tavern → Rumours**: three rumour rows appear. `Buy the rumour` costs 100g
   and reveals a discovery's name; the region hint is shown free. Note the
   coordinates in the hint and sail there.
4. At sea press **E** where the HUD hint `Something unusual is nearby (E)`
   shows: every in-range discovery is found and a `Discovery: …` dialog names
   it (radius 3, `70-*` §4.4). Found ≠ reported.
5. **Guild (S12)**: the *Discovery reports* section lists what you found with
   the exact gold/fame. Press **Report** — the gold lands and the fame rises.
   The *Commissions* section above lists three seeded offers; **Accept** one
   and deliver the cargo to the named port (entering it completes the quest).
6. **Palace (S13)** at a capital: with reputation ≥ 30 a **royal mission** is
   offered (rotating through delivery / patrol / chart each month). Completing
   one adds +25 fame and counts toward the ladder. The title row shows the next
   rank and its two requirements (fame · royal missions) and **Attend the
   ceremony** grants exactly one rung per click:
   knight 100/1 → baron 300/2 → viscount 700/3 → count 1500/5 → duke 3000/8.
   The grants bite immediately: sell prices at that nation's ports ×1.05/×1.10,
   +1 quest slot at viscount, repairs ×0.8 at count.
7. **Tournament**: cycle day 1–5 at the cycle's host capital, the palace's
   tournament row offers **Enter the tournament (1,000 gold)**. Three real S10
   battles follow (brigantine → carrack → galleon) with durability carried,
   no repairs between rounds; **Continue** returns to the palace and the next
   bout starts automatically. Win all three: +10,000g, +100 fame. Lose one:
   +500g and a free repair to half.
8. **Retire** at a capital whose nation you are Duke of: the row opens a
   confirm; accepting opens **S16** with the six summary rows, and the next
   save marks the slot retired. Loading a retired slot from the title screen
   shows `This captain has retired` and never resumes play.
9. **Piracy run**: right-click a *national* (navy) marker to attack. Each act
   costs −20 with that nation and +2 with its two rivals. At ≤ −50 that nation
   issues a bounty equal to `500 × |rep|`, spawns navy hunters and closes its
   ports (`Closed by bounty` on every facility row). Clear it either by
   **Pay the bounty** at that nation's capital palace, or by surrendering the
   flagship to a hunter — both land on exactly −10.
10. Press **L** anywhere to toggle zh ↔ en; no `<key>` literal should ever
    appear.

### Reported bug checklist (hand runs)

Note the screen, the exact key/click, and what you expected. Console output
from the terminal running Godot is the most useful attachment; any
`SCRIPT ERROR` there is a real defect, but `Fleet.normalize_all` warnings on a
hand-edited save are expected.

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-10-30 |
| Branch / commit | `main` — see `git log -1` |
| Godot | 4.7.stable.official.5b4e0cb0f |
| Command | `godot --headless --path . tools/test_phase3_acceptance.tscn` |
| Result | **ALL PASS (102 checks)**, exit 0, zero `SCRIPT ERROR` |

### S1 — trade → 2 discoveries → Duke → tournament → retire

| | |
|---|---|
| Start | `new_game("portugal", false, "p3")`, day 4, docked at Lisbon on the p3 map |
| Trade leg | wine bought at Lisbon, sold at London; the best arbitrage is found by scanning every good × port with the shipped `buy_price`/`sell_price` (no hardcoded route). 42 round trips take the purse 5 000g → 55 800g; +4 XP from the first sale |
| Rumour leg | `TavernScreen.select_tab("rumors")` lists exactly 3 hints; buying one costs 100g and marks the discovery hinted |
| Explore leg | `WorldMap.explore_here()` at the hinted landmark finds it (Chebyshev 3); a second landmark found the same way |
| Report leg | `GuildScreen.report_discovery()` ×2 pays **4 050g** and **320 fame** exactly (both reports' own numbers), both leave the report list, a second report of the same id pays nothing |
| Ladder leg | 8 royal missions accepted/completed through `PalaceScreen.accept_mission()` + the kind's completion call; at fame 3 000 + 8 missions the ceremony grants `knight → baron → viscount → count → duke`, one rung per click |
| Grants leg | Lisbon `title_units == 1100` (duke ×1.10), `max_active_quests() == 4` (viscount grant), palace repair bays run at the count discount |
| Tournament leg | entry at the rotating host inside its day 1–5 window, fee 1 000g charged; three real `BattleScreen` bouts won; prize **10 000g + 100 fame**; net **+9 750g** (9 000 after the fee, plus combat salvage) |
| Retire leg | the dukedom enables the row; `palace.retire()` flags the run; S16 shows six rows including the dukedom |
| Round trip | `save(1)` writes **save_version 3** with `retired: true`, the 2 reports, `titles.portugal == "duke"` and the fame; `load(1)` reports a retired run, restores nothing playable, and its summary carries the fame |
| Result | **PASS** |

### S2 — raid → bounty → hunters → clear the bounty

| | |
|---|---|
| Start | `new_game("spain", false, "p3")`, day 40, docked at Seville; portugal rep 60, spain rep 10 |
| Raid leg | `Bounty.apply_piracy("portugal")` six times: −20 per act (60 → −60) **and** +2 with each rival from `data/nations.json#rivals` (spain 10 → 22) |
| Bounty leg | issued at the threshold: rep −60 → **30 000g** (`500 × 60`), navy hunters spawn from `Encounters.spawn` |
| Closed ports | the Lisbon hub disables the market row and prints `Closed by bounty`; the Lisbon palace is closed |
| Clear path 1 | `PalaceScreen.pay_bounty()` charges exactly 30 000g, resets rep to **−10**, deletes the bounty, and Lisbon reopens immediately on the next bind |
| Clear path 2 | a second bounty issued after a further −50 clears through `Bounty.clear_by_surrender("portugal")`, also landing on **−10** |
| No lockout | with the **own** nation (spain) bountied: a non-bountied port (Lisbon) stays fully open for recovery, and Seville's palace keeps the single `Pay bounty` row, which clears it to −10 |
| Round trip | `save(2)` writes save_version 3 with `retired: false`, the per-nation `titles` and `completed_royal_missions` blocks; `load(2)` restores the purse (23 456g) and the cleared reputation (−10) |
| Result | **PASS** |

### Locale sweep

Every screen the two runs touch (`tavern`, `guild`, `palace`, `hub`, `inn`,
`ending`) is walked in **both** locales during the run: 224 player-facing lines
are collected and the closing check asserts none of them contains a raw
`<key>`. Spot checks additionally pin `rank.knight` (骑士 / Knight),
`ending.title` (航程终章 / Voyage's End) and
`ending.retired_title` (这位船长已经退休 / This captain has retired).

---

## Suite counts at the Phase-3 gate

| Suite | Checks | Phase |
|---|---|---|
| `test_battle_economy.tscn` | 68 | 2 |
| `test_battle_screen.tscn` | 122 | 2 |
| `test_battle.tscn` | 218 | 2 |
| `test_bounty.tscn` | 80 | **3** |
| `test_character.tscn` | 409 | 1 (+24 for the Quests tab) |
| `test_demo_loop.tscn` | 87 | 1 |
| `test_discovery.tscn` | 141 | 1 |
| `test_duel.tscn` | 148 | 2 |
| `test_encounters.tscn` | 156 | 2 |
| `test_equipment.tscn` | 149 | 2 |
| `test_fleet.tscn` | 157 | 1 |
| `test_inn.tscn` | 116 | 1 |
| `test_morale.tscn` | 260 | 1 |
| `test_movement.tscn` | 158 | 1 |
| `test_palace.tscn` | 182 | **3** |
| `test_phase2_acceptance.tscn` | 142 | 2 |
| `test_phase3_acceptance.tscn` | **102** | **3** |
| `test_port_hub.tscn` | 142 | 1 (+2 for the guild/palace rows) |
| `test_quests.tscn` | 100 | **3** |
| `test_retirement.tscn` | 78 | **3** |
| `test_sailing.tscn` | 84 | 1 |
| `test_save.tscn` | 196 | 1 (+1 for the v3 payload) |
| `test_save_v2.tscn` | 81 | 2 (+1, version-agnostic) |
| `test_save_v3.tscn` | 141 | **3** |
| `test_shipyard.tscn` | 141 | 1 |
| `test_tavern.tscn` | 268 | 1 (+23 for the Rumors tab) |
| `test_tournament.tscn` | 142 | **3** |
| `test_trade.tscn` | 278 | 1 |
| `test_weather.tscn` | 129 | 1 |
| `test_world_map.tscn` | 62 | **3** |
| **Total** | **4 537** | |

Phase-2's gate was 22 suites / 3 599 checks; Phase 3 adds 8 suites / 887 checks
and 51 checks inside five existing suites (character +24, tavern +23,
port_hub +2, save +1, save_v2 +1) — every one of them an assertion about a
Phase-3 behaviour, none a silently dropped count.

---

## Integration defects found while building this harness

Two real defects surfaced only when the whole loop ran; both are fixed in this
branch:

1. **A tournament bout returned to the world map.** `battle_screen`'s
   after-action `Continue` always routed to S3, so the bracket lost the palace
   between bouts and the next round never started — `70-*` §4.9.7's "three
   successive battles" was unreachable in play. Fixed with `return_scene()`:
   an encounter id tagged `tournament_` returns to S13, everything else to S3,
   and `Phase3Hooks.on_tournament_bout` hands the next round / the settled block
   back through two transient `GameState` fields.
2. **A delivery quest could never complete in play.** §4.9.3 pins "entering
   `dest_port_id` with ≥ quantity … goods removed, reward paid", and a cargo
   mutation failing the quest immediately, but neither hook was ever called:
   `world_map._enter_port` only docked and greeted. Fixed by wiring
   `Phase3Hooks.on_port_entered` into port entry (report queued as a dialog) and
   `Phase3Hooks.on_cargo_changed` into the `fleet_changed` funnel every cargo
   change already emits.
3. **A navy battle start charged only the −20.** §4.9.5's "+2 with the two
   rivals, once per battle, at battle start" never fired: the scene charged the
   −20 alone. Fixed by routing `world_map._charge_navy_piracy` through
   `Bounty.apply_piracy`, which also re-evaluates the bounty threshold.
4. **The Retire row was always visible, just disabled.** §4.7 pins "the palace
   shows the `Retire` row only while the docked nation's title is duke"; the
   screen rendered it greyed for everyone. Fixed by hiding it outside the gate.
5. **The palace's tournament row hid its own reason.** The entered case was
   handled before the generic `blocked` branch, so an out-of-window or
   wrong-host palace still printed `Entry recorded`. Fixed by letting
   `status.blocked` drive both the label and the tooltip for every reason.
6. **`PalaceEngine._delivery_offer` read the live day.** A royal delivery
   previewed for another day (a test, or a screen showing tomorrow's offer)
   silently used `GameState.day`; fixed by threading the day through.
7. **The palace repair path refunded a discount instead of quoting it.** Two
   prices could drift; `ShipyardEngine.repair()` now takes the port and charges
   the discounted amount once.

---

## Deviations recorded for the wave plan

The sanctioned plan was `W1 A∥G → W2 B∥E → W3 C∥D → W4 F∥I → W5 H → W6 J`
with one worktree per subagent. This run executed the same order as a single
serial stream in the master tree instead of background worktrees, because the
worktree machinery was not needed to keep file ownership disjoint: each wave's
tasks were finished and committed before the next started, so no two tasks ever
had uncommitted edits in the same file. The pins (`83eeb2c`) were still landed
*before* any code, which is the part of the protocol that prevents two models
of one rule. Task **I** (the optional art pass) was skipped as the backlog
allows.
