# T19 — Phase-1 Demo-Loop Acceptance Record

Definition of "playable": `docs/00-OVERVIEW.md` §7 (nine steps).
Backlog item: `docs/IMPLEMENT-Phase1.md` T19.

Two layers of evidence:

1. **Scripted** — `tools/test_demo_loop.tscn` walks all nine steps through the
   real engines and asserts the documented numbers (87 checks). Run:
   `godot --headless --path . tools/test_demo_loop.tscn` → must print
   `ALL PASS (87 checks) — demo loop complete` and exit 0.
2. **Manual** — the dated run below covers what a headless test cannot judge
   (visual layout, on-screen feel, the zh spot-check list).

---

## Recorded scripted run

| Field | Value |
|---|---|
| Date | 2026-10-29 |
| Commit | see `git log -1` at the merge of T19 |
| Godot | 4.7.stable.official.5b4e0cb0f |
| Command | `godot --headless --path . tools/test_demo_loop.tscn` |
| Result | **ALL PASS (87 checks) — demo loop complete**, exit 0, stable over 3 consecutive runs |

### Step-by-step (scripted)

| # | Step | Verified by | Result |
|---|---|---|---|
| 1 | 1280×720 title with New / Load / language toggle | project settings + title scene buttons | PASS |
| 2 | 6 nationality cards correct per `nations.json` | card count, start port/ship resolve from data, Portugal = 5000g / caravel / crew 15 / Lisbon / day 1 | PASS |
| 3 | Market buy updates gold and cargo immediately | Lisbon wine 21g; buy 10 → gold −210, hold +10 | PASS |
| 4 | At sea: 8-dir, land blocks, 3+3 consumption, −2g/crew/day | all 8 directions step; land blocks at zero clock cost; 15 crew → 3 provisions + 3 water; wages −30g; day advances | PASS |
| 5 | Storm reachable west of Lisbon; starvation → game over | x≤6 is the Atlantic strip, Lisbon (x=7) is not; a storm occurs within 5 days; 7 shortfall days → `game_over("starvation")`, latched, S9 screen loads and can return to title | PASS |
| 6 | Second port; sale price per supply/demand | Lisbon 21g → London 31g (net 10g/unit); selling 10 → +310g, cargo cleared, XP awarded, England profit booked | PASS |
| 7 | Shipyard repair + refit visible (refit disabled P1); one officer recruited and visible in the panel | caravel 20g/point, 10 points = 200g, durability +10; refit row present and disabled; Mateus recruited for 300g, navigation 15→25; inn rest = 3 days, +5 morale/day | PASS |
| 8 | Save → quit → Load restores all state | day, gold, morale, position, officers, reputation, known_ports, investments, provisions, water, cargo, crew, ship type | PASS |
| 9 | Locale toggle with zero missing keys | en→zh→en for `market.buy`, port name, good name; **every** `ui_strings` key resolves in both locales (0 missing) | PASS |

---

## Manual run (human, dated)

Fill one row per tester. "PASS" means every observation matched; note anything
that felt wrong even if it technically passed.

| Date | Tester | Build | Result | Notes |
|---|---|---|---|---|
| 2026-10-29 | orchestrator (automated verification only) | main @ T19 | **PASS (scripted layer)** | No human visual pass recorded yet; see checklist below |

### Manual checklist (to be completed by a human tester)

- [ ] **1. Title** — window opens 1280×720; New Game, Load, and the language
      button are visible and clickable; no clipped text.
- [ ] **1b.** Press the language button: every visible string flips
      zh↔en **immediately**, nothing stays in the old language.
- [ ] **2. Nationality** — six cards in the fixed order (Portugal, Spain,
      England, Holland, Ottoman, Italy), each showing its flag colour,
      name, description, and start package; confirm one.
- [ ] **3. Market** — gold and hold counters update the instant a purchase
      completes, with no stale frame.
- [ ] **4. Sailing** — arrow keys and numpad both step; a diagonal into a
      land corner is refused with no day change; the ship never leaves the
      map or shows void past the edges; camera follows smoothly.
- [ ] **4b.** HUD bottom bar (provisions/water/crew/cargo/speed) updates as
      days pass; the minimap reveals only explored tiles.
- [ ] **5. Storm** — sail west from Lisbon; a storm arrives; the storm glyph
      flashes; damage is reported in a dialog.
- [ ] **5b. Starvation** — run provisions out; the game-over screen appears
      with the right reason; any key returns to the title.
- [ ] **6. Second port** — arrival shows the greeting with day count and
      flavour; selling shows profit/loss in the trade feedback.
- [ ] **7. Facilities** — market/shipyard/tavern/inn each open and Esc
      returns to the hub; the Guild and Palace rows show the Phase-3 stub
      label and do nothing when clicked.
- [ ] **8. Save/load** — Save from the port menu (3 slots, summaries,
      overwrite confirm), quit to title, Load, and confirm the HUD, fleet
      panel, and character panel all show the restored values.
- [ ] **9. Chinese run** — repeat the loop in zh; no `<key>` literals and no
      English leaking through.
- [ ] **General** — no console errors during the whole run; no texture or
      audio assets were required (placeholder art only).

---

## Known limitations accepted for Phase 1

- **Explored tiles are not saved** (`docs/20-*` §4.12): after a load the
  minimap re-reveals as you sail. Documented, not a bug.
- **`clock_fraction` is not saved** (`docs/20-*` §4.3): saves happen only in
  port, where the fraction is 0 by definition.
- **Harbor relief is normally unreachable** (`docs/50-*` §4.7): there is no
  in-game path to a shipless player in Phase 1; it is exercised via
  `GameState.debug_strip_fleet()` in debug builds only.
- **Refit (armaments) is present but disabled** (`docs/40-*` §4.3): the maths
  is implemented and unit-tested, ready for Phase 2.
