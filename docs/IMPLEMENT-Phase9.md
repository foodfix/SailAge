# IMPLEMENT — Phase 9: Naval-combat realism & AI (velocity physics, fleet command, 1-ply lookahead)

> Source plan: `.kilo/plans/1793685378588-naval-combat-realism-ai.md`
> (authored 2026-11-03; its §0 decisions were user-locked the same day).
> Reviewed against the live tree on 2026-11-03; corrections below.

**Status (2026-11-03): W1 launched** — slots A/B/C/D running in parallel
worktrees (branches `phase9/phase9-docs-{schema,battle,ai,ui}`), merge
order A → B → C → D; gate runs on `main` after each merge.

**W1 status (2026-11-03): ✅ complete** — slots A (`9f4b118`) → B
(`20cee38`) → C (`e0feee9`) → D (`a7c0b47`) merged in order on `main`;
`validate_data.py` exit 0 after each merge and at the gate; every new
section exists and every cross-doc citation resolves (`60-*` §4.3a/§4.4a/
§4.4b/§4.6a/§4.8a/§4.9a–c, `80-*` §4.7.16, `10-*` §7.12/§4.10 `ai_profiles`).
Master micro-integrations at the gate (ledger): §4.9c candidate bound
re-pinned to the correction-3 derived box (≤ 81 at `battle_max_speed = 4`;
the (y,x) enumeration order stays the normative tie-break — decision 13's
"≤ 49" predated correction 3); §4.12.1 `unit`-dict fields refreshed to the
§4.3a state; `10-*` §2 Artifacts rows name the Phase-9 additions. Master
adjudications folded into the docs: grape's crew kill **is** the volley's
casualty term (decision 4's ×0.5 pin, not additive with the /20 rule);
deployment starts `vel = (0,0)` (standstill rule); the §4.7 surrender gate
drops the old proximity clause (decision 9 owns the gate); W1-B's §7
checklist staleness (16×10/MP rows) is Phase-2 history — the Phase-9
acceptance block lands with W6.

**W2 status (2026-11-03): ✅ complete** — slots A (`7860d43`) → B
(`f019391`) → C (`0e0ae12`) → staged D (`3879bfb`) merged in order on
`main`; the staged-protocol red (group 7 `unexpected ai_profiles`) showed
at the A/B merges exactly as designed and D's amendment turned the gate
green: `validate_data.py` exit 0, groups 1–12 (group 3 now pins the three
ship_types battle fields incl. the 16→2/20→3/24→4 mapping and the 7+9
turn-rate partition; group 7 pins `ai_profiles` nine kinds × nine keys
with the full §4.10 locked-value table, 26/26 negative probes). Sandbox
suite green on main: `test_battle_sandbox` ALL PASS (93 checks — clamps,
`player_stats` override/fallback, export→import→re-export byte-identity,
S21→S10 run determinism, **zero-write audit**, normal-path guard);
regression spots green: `test_battle_screen` 123, `test_battle` 276,
`test_tournament` 145. ui_strings 899 → 987 keys, zh/en parity green.
Master micro-integrations at the gate (ledger): `10-*` §7.12 amended with
the master-authorized `{family}.{value}` label keys (formation ×4,
kind ×9, archetype ×3, ai_level ×2, dir ×9 — the selectors must never
render raw ids; weather reuses `world.weather.*`); C's sandbox-mode
after-action **suppresses the `battle_finished` broadcast** (S3's listener
removes fleets — emitting would breach decision 15; normal battles
unchanged, guard-tested); C's compose stream seeds from the resolved
seed deterministically (stream-continuity unpinned by the docs — noted
for W5-C's full-field pass); the sandbox enemy-captain field edits enemy
row 0's `captain_id` (no enemy-level schema key exists).
## Goal

Replace the Phase-2 MP-grid battle (16×10, 360° cannon, skip-a-turn reload)
with a **realistic physics layer** — integer velocity vectors with inertia,
heading-derived 8-bucket arcs, port/starboard broadsides with independent
reload, wind/current/weather speed caps, four shot types (round, chain,
armor-piercing, grape), sweep-ramming, hook-and-board with crew casualties —
plus a **side-level morale model**, a **fleet-command layer** (per-round
five-tuple orders, form→close→engage→wear→break maneuver state machine,
hysteresis, anchor succession), an AI ramp (T1 profiles → T2 deterministic
greedy → **T3 one-ply lookahead as the shipped ceiling**, `ai_level ∈ {0,1}`),
the S10 presentation rebuild (48×30 battle world, camera, minimap, overlays),
and the **S21 naval-battle sandbox** off S1 (zero-write, forward-compatible
import/export). Save stays at `SAVE_VERSION = 9`.

---

## Source-plan validity verdict

**Valid as a design** — the physics/AI/sandbox pieces compose cleanly, all 16
hull ids partition exactly once into the two turn-rate tiers, the grid /
viewport / minimap arithmetic checks out (48×30 @ 32 px = 1536×960 world over
a 1280×584 viewport; 4 px/cell minimap = 192×120), the 9-row profile table
covers every battle kind the engine can produce (`trader / coaster / courier /
patrol / privateer / pirate / treasure` pass through; `hunter → navy` via
`NpcFleets.composition_kind`; plus `tournament`), `SAVE_VERSION = 9` is
correct as-is (battle state is transient), the grape shot's no-gate rule is
consistent with `skill_gates` (`shot.chain` ≥ 25 / `shot.armor_piercing` ≥ 50
already exist), and `snapshot()/restore()` is cleanly additive — no existing
API conflicts. The 13 defects found are listed as corrections below and are
folded into the decision record; none invalidates the structure (9E0 → 9A →
9B → 9C → 9D → 9E tail).

---

## Review corrections applied to the source plan

| # | Source-plan claim / gap | Verified fact (2026-11-03) | Fix applied |
|---|---|---|---|
| 1 | §0 row 3: both wind and current tables "原文引用 `20-* §4.7/§4.16`" | `direction_factor` lives in **`20-* §4.4`** (§4.7 owns `wind_factor` only); §4.16's current rule is **multiplicative** (`1 ± 0.08 × strength` by alignment, modifier mode) — the source plan's discrete cap ±1 battle rule is a **new battle-domain pin**, not a quote | Docs own: wind tables quoted by reference (wind_factor §4.7, direction_factor §4.4, calm ⇒ direction identity); the current rule is pinned as new battle text (cap +1 when relative bucket ∈ {0°,45°} ∧ strength ≥ 2; cap −1 when ∈ {135°,180°} ∧ strength = 3). Battle reads the **decoded current vector at the contact tile** from `currents.png` (reversal applied) regardless of the world's `current_mode` |
| 2 | No sail-equipment rule in the new speed model | `60-* §4.11.12` pins sail `speed` (+1/+2) into battle MP **and initiative** today — the rewrite silently regresses it | Pin carried into the new model: `cap_eff` gains `+ sail_speed_delta`; the initiative sort key is `ShipType.speed + sail_speed_delta`; docs amend §4.11.12 concurrently |
| 3 | `battle_max_speed` 16→2 / 20→3 / **24→3** | Old MP kept three distinct tiers (16→4, 20→5, 24→6); the new table collapses 24-hulls (galley, brigantine, xebec) onto the 20 tier | Default to **16→2 / 20→3 / 24→4** (three tiers preserved, review-adjustable against the §8 health band); validator bound becomes 2..4 |
| 4 | §0 "僵持 → `retreat`" vs §2.2.6 "outcome() 增 `stall`" | Contradiction; `retreat` already means the player's menu choice | New outcome **`stall`**: mutual disengage — no retreat back-step, attacker marker gets +1 day pursuit cooldown (mirrors the retreat rule), loot/XP/rep earned so far kept, nothing more; §4.11.9 table gains the row |
| 5 | "士气 ≤ 10 → 立即降旗" is side-level | Morale is per-side, surrender is per-ship; `60-* §4.7` says player ships **never** auto-surrender | Pin: instant strike is **AI-side only** — at side morale ≤ 10 every living AI ship strikes colors at its next turn, no roll, resolved as §4.7 surrender; player side never auto-strikes (manual `battle.surrender` unchanged), low player morale is a HUD warning only. Flagship-sunk event is **−30 total**, not additive with the friendly-sunk −15 |
| 6 | "AI 起始 = clamp(40 + courage, …)"; boarding rule uses "captain_rating"; "暴风/降旗" wording | `courage` is the **enemy flagship's captain-card courage** (legacy fleet: `10 + 10 × tier`, same fallback as gunnery); the §4.11.5 name is **duel rating**; weather engine ids are `calm/fair/strong/storm` (`20-* §4.7`) | Terms pinned by those exact names in the docs; all weather wording normalized to engine ids ("storm 禁止勾舷 / 炮伤 ×0.75; strong 炮伤 ×0.9") |
| 7 | Crew can reach 0; hook aftermath velocities unpinned | — | Pin: crew clamps at 0; a 0-crew ship still sails (its penalties are the crew_ratio < 0.5 reload +1 and the weakened `min(floor(crew/5), 20)` duel term — nothing more). A successful hook sets **both** ships' `vel = 0` |
| 8 | ai_profiles table includes `coaster`; no `hunter` row | Coasters are **intimidate-only, never battle** (`60-* §4.1.1`); hunter battles enter as `kind = "navy"` | Pin the profile-lookup rule in §4.9a: hunter → `navy` row (mirrors `composition_kind`); the `coaster` row is forward-compat + sandbox-only (validator still checks its shape) |
| 9 | §1 file list omits the overview doc | Phase-8 W1-A precedent: glossary + phase row land with the docs wave | `docs/00-OVERVIEW.md` added (glossary: heading8 / 舷炮 broadside / 纵射 rake / 勾舷 hook / 弹种 shot type / 档案 profile / 原型 archetype / 指令五元组 order tuple / 迟滞 hysteresis / 前瞻 lookahead / 沙盒 sandbox / 僵持 stall; §5 Phase-9 row) |
| 10 | §1 lists `tools/battle_tune.py` without "(新)"; report files unowned | The file does not exist; `tools/battle_ai_harness_report.md` / `tools/battle_tune_report.md` are generated artifacts | Marked **(new)**; reports are tool-owned, regenerated per wave, never hand-edited |
| 11 | Data keys grow per stage (`formation` at 9C, `ai_level` at 9D); θ lands via per-slot edits | Three data/validator passes for dormant keys; the sandbox already proves the forward-compat schema pattern | **All nine profile keys land in the W2 data wave** (validator checks shape from day one; runtime consumers arrive per stage). θ finalization is a **named master task** after the last wave (doc amend + const sync + test re-run), not slot side-effects |
| 12 | Round cap re-pin mentions the engine only | `battle_sim.gd` API `run_to_completion(policy, max_rounds: int = 30)` exposes the old cap as a default | §4.12.1 API default re-pinned to 40 in the docs wave (W1-B) |
| 13 | Harness baseline is a 9E0 deliverable but harness is a 9A tool | Baseline must be captured on the **old** engine before the rewrite | W3-A runs harness on the old engine **at slot start**, writes the before-section of the report, then rewrites — 9E0 keeps its scope (skeleton, zero-write, seam) without a timing hazard |

### Non-blocking suggestions (for the docs-review pass)

- **S1.** Adopt the ≥ +10pp adoption gate for T3 exactly as specified; treat a
  failed gate as "ship `ai_level = 0` content" rather than a phase failure —
  T2 must be a complete, releasable product on its own (it is).
- **S2.** Publish the harness health band (avg rounds 12–25, cap-hit < 10%,
  stall < 5%) as the *only* 9A balance gate; coefficient tuning (grape, crew
  casualty divisors, strong ×0.9) defers to `battle_tune.py` in W5 as
  designed.
- **S3.** Keep CEM stdlib-only (subprocess-driven headless Godot) — matches
  the repo's zero-dependency tools convention.
- **S4.** Sandbox preset persistence (`user://sandbox/`) stays deferred;
  clipboard import/export is enough for bug-report reproduction.
- **S5.** A fourth `merchant` archetype stays a review item *after* the
  behavior-distinctness metric runs; do not pre-add it.

---

## Decision record (carried from §0 of the source plan, corrections folded in)

1. **Physics**: per-unit `pos/vel (Vector2i), heading8, reload_port/starboard,
   speed_debuff_turns, crew`. Turn = pick new `vel` (angle ≤ `turn_rate`,
   magnitude-delta ≤ `battle_accel`, `‖vel‖ ≤ cap_eff`; from standstill any
   direction, magnitude ≤ accel) → integrate with Bresenham sweep (first
   occupied cell stops: enemy ⇒ ram, friend/out-of-bounds ⇒ stop at prior
   cell) → one action (cannon-side / ram / board / hold). `heading8` derives
   from `vel` at 22.5° boundaries via **integer dot/cross comparisons**
   (float only for magnitude); `vel = 0` keeps the last heading. Overshoot
   clamps along direction (component floor).
2. **`cap_eff`** = `clamp(floor(battle_max_speed × wind_factor(weather, class)
   × direction_factor(heading8, wind_dir)) ± current_mod − debuff, 0,
   battle_max_speed) + sail_speed_delta` (corrections 1–3); calm ⇒
   direction identity (world rule). `battle_accel`: oar 2, else 1.
   `battle_turn_rate`: 90° for latin/sloop/galiot/pinnace/dhow/xebec/galley,
   45° for caravel/brigantine/nao/carrack/galleon/galleass/fluyt/junk/
   caravela_redonda — `battle_mp` and the MP model retire to a historical
   footnote. Chain-shot cap floor 1.
3. **Broadsides**: cannons split port = `floor(n/2)`, starboard the rest
   (kept total for outcome/rewards); arcs relative to attacker heading8 —
   port {45°,90°,135°}, starboard {225°,270°,315°}; damage
   `floor(side_cannons × 2 × range_factor) + bonus`; storm ×0.75, strong
   ×0.9 (new pin); rake (target bearing bucket 0°/180° vs its heading8)
   ×1.25 — multipliers multiply, one floor at the end (after the weather
   term). Shot array per §4.4b below.
4. **Shots (4)**: round (default); chain (gunnery ≥ 25): ×0.75 +
   `speed_debuff_turns += 2`; armor-piercing (≥ 50): ×1.25, ignores `armor`;
   **grape (new, no gate, range 1 only)**: hull `floor(same-range round × 0.5)`
   + crew `floor(same-range round × 0.5)` (crew kill through the §6 casualty
   rules, feeds the duel term). AI picks by the deterministic §4.4b rule —
   always **outside** the T3 search enumeration.
5. **Reload** (replaces `RELOAD_ROUNDS = 2`):
   `reload_turns = clamp(3 − floor(gunnery / 50), 1, 3) + (crew_ratio < 0.5 ?
   1 : 0)`; flagship uses `effective_gunnery`, escorts their captain card's
   `skills.gunnery`, AI canon cards likewise, legacy fleets `10 + 10 × tier`;
   `crew_ratio = crew / crew_min`; sides reload independently
   (`reload_side = round + reload_turns`).
6. **Crew casualties**: standard volley `crew −= floor(damage/20)`, rake
   volley `−= floor(damage/10)`, boarding winner `−= floor(crew × 0.2)`;
   clamped at 0 (correction 7); feeds the §4.11.6 duel crew term.
7. **Ram**: triggered by sweep entry at `floor(‖vel‖) ≥ 1` (adjacent-action
   ram preserved); multiplier `(1 + 0.25 × (floor(‖attacker vel‖) − 1)) ×
   (from target bow/stern ? 1.15 : 1.0)`; target `floor(att_max_dur × 0.25 ×
   mult)`, self `floor(att_max_dur × 0.10 × mult)`; oar/hybrid ×1.25 and
   attacker-resolves-last preserved.
8. **Hook & board**: orthogonal adjacency + both `‖vel‖ ≤ 1` + weather ≠
   storm → hook (both `vel = 0`, correction 7); duel per §4.11.6 unchanged;
   strike semantics — player = §4.11.7 `surrender` (fleet retained, existing
   cargo rules), AI = capture; S10 shows a highlight ring on hookable
   targets; AI decelerates into the hook window (correction 5 for
   auto-strike).
9. **Morale**: per-side 0–100; player starts at `GameState.morale`, AI at
   `clamp(40 + flagship-captain courage, 20, 90)` (correction 6); events —
   friendly sunk −15 / captured −20 / flagship sunk −30 **total**
   (correction 5) / raked −5 / boarding win +10 / boarding loss −10
   (absorbs the old `60-* §4.8` flat +5, which is repinned away);
   side morale ≤ 20 ∧ ship durability ≤ 25% ⇒ the §4.7 surrender roll with
   `+ floor((20 − morale) / 2)` pp; side morale ≤ 10 ⇒ AI-side instant
   strike (correction 5); `morale_delta` clamped [0,100] writes back onto
   `GameState.morale` through the outcome block (replaces the old outcome
   field). Tournament bouts participate normally.
10. **Fleet layer**: per-round **order five-tuple** `{station,
    desired_heading8, desired_speed_band, assigned_target, discipline}` per
    AI ship (pure deterministic, zero RNG); state machine `form → close →
    engage → wear → break` per the source §4.1 table (`line_ahead` full;
    `column` = form/close/engage; `screen` = flagship-radius-3 screen + free
    fire; `swarm` = target assignment only); hysteresis — ≥ 2 rounds per
    state, `wear` locked till all within ±1 bucket; anchor = flagship
    pos+heading8, succession to the lowest living fleet index; side morale ≤
    20 ⇒ `break` (pre-9C: flee rule); `engage` discipline removal of off-station
    candidates is a hard constraint; target assignment round-robin by profile
    `focus`, full focus-fire when `aggression ≥ 80`.
11. **Grid/camera/UI**: 48×30 @ 32 px world (1536×960) over a 1280×584
    viewport; player band x ≤ 5, enemy band x ≥ 42; deployment cells
    (2,15)(2,14)(2,16)(2,13)(2,17) vs (45,…); **tournament variant** — single
    bouts at (10,15) vs (37,15) (27 apart), initial `vel` (1,0)/(−1,0),
    everything else identical. Camera: RMB/MMB drag, 16 px edge scroll at
    600 px/s, wheel zoom 0.6–1.5× anchored, auto-center until manual pan,
    Home/fit; minimap 192×120 with viewport frame, ship dots, wind/current
    arrows, anchor lines; AI-turn speed switch (animate / instant); bottom
    bar `‖vel‖`/heading8/reload pips/wind/weather/[fit]; four-button shot
    selector with gate-disabled states.
12. **Round cap 40** (API default re-pinned, correction 12); **stall** —
    8 consecutive rounds with zero damage and zero boarding **and** net
    player↔enemy Chebyshev change ≤ 2 ⇒ outcome `stall` (correction 4);
    any damage/boarding resets the counter.
13. **AI ramp**: T1 profiles (six live keys + `archetype`) drive T2
    deterministic greedy (surrender roll → flee → loaded-fire by `focus` →
    kite at `preferred_range` → hook/board ≥ ram ≥ close ≥ hold, all
    tie-breaks pinned in §4.11.8); T3 (`ai_level = 1`) = one-ply search over
    `legal_velocities` (Chebyshev box ≤ 49, (y,x) lexicographic) × actions on
    `snapshot()/restore()`, zero dice, linear `score = θ·φ` over the nine
    pinned features, per-archetype θ learned offline by CEM (doc-first
    constants, correction 11); shot type stays rule-derived (decision 4).
    `ai_level` per kind: pirate/privateer/navy/patrol/tournament = 1,
    treasure/trader/coaster/courier = 0. Adoption gate: T3 vs T2 ≥ +10 pp,
    100 % legal-action rate, avg ≤ 30 ms/decision.
14. **Save**: `SAVE_VERSION = 9` unchanged — battle state is transient;
    morale flows through existing fields; broadside split derives from total
    cannons at battle start; fleet instance fields unchanged.
15. **Sandbox (S21, zero-write)**: S1 gains 海战 button (between New Game and
    Load) → S21 full editor → S10 via a fixture encounter (`player_ships`/
    `day`/`gold`/`seed` + forward-compat condition keys) with `player_stats`
    overrides injected through the new §4.12.1 optional key; ending shows a
    read-only after-action dialog and returns to S21 with the configuration
    kept; **nothing writes** `GameState` / `NpcFleets` / phase-3 hooks /
    world routing (audited by test); clipboard import/export schema declares
    all planned fields from day one.
16. **Tooling**: `tools/battle_ai_harness.gd/.tscn` (64-seed mirror self-play
    report — symmetry, rounds, cap hits, stalls, damage exchange, 100 %
    legal-action rate, decision timing; deterministic `log_lines()` audit);
    `tools/battle_tune.py` (new): stdlib CEM over subprocess headless Godot,
    two-stage learning (θ_balanced 50 gen → aggressive/cautious 20-gen
    fine-tunes), frozen 64-train/64-validate seed table with side-swapped
    common random numbers, convergence + learning-gain + validation-droop
    ≤ 2 pp + ±20 % perturbation ≤ 3 pp gates, behavior-distinctness metrics;
    results land doc-first into `ai_search.gd` const tables (correction 11).

---

## Artifacts

- Docs: `docs/00-OVERVIEW.md` (glossary + phase row, correction 9);
  `docs/10-DATA-SCHEMA.md` (ship_types three-field schema, npc_config
  `ai_profiles` nine-key block, §8 group-2/7 spec, ui_strings inventory);
  `docs/60-COMBAT.md` (§4.2–4.9 rewrite + new §4.3a/§4.4a/§4.4b/§4.6a/
  §4.8a/§4.9a/§4.9b/§4.9c; §4.8 repin; §4.11.2/§4.11.4/§4.11.5/§4.11.8/
  §4.11.9 + outcome rows; §4.11.12 sail amend; §4.12.1 `player_stats` +
  40-default + wind/current keys; §4.12.1.1; §4.12.2; §4.12.4 sandbox
  branch); `docs/80-UI-UX.md` (§4.1 S21 row, §4.2 nav edge, §4.3 inputs,
  §4.7.1 S10 rewrite, §4.8 minimap colors, S21 spec); `docs/90-ARCHITECTURE.md`
  (S1→S21→S10→S21 scene-flow edge; module list).
- Data: `data/ship_types.json` (`battle_max_speed`/`battle_accel`/
  `battle_turn_rate` per hull); `data/npc_config.json` (`ai_profiles`, all
  nine keys, correction 11); `data/ui_strings.json` (`battle.*` + `sandbox.*`
  families, both locales).
- Code (existing): `scripts/combat/battle_sim.gd`, `scripts/combat/ai_fleet.gd`,
  `scenes/combat/battle_screen.gd`, `scenes/combat/battle_grid_overlay.gd`,
  `scenes/title/title_screen.gd`, `scripts/world/interactions.gd` (contact
  handoff injects wind/weather/current).
- Code (new): `scripts/combat/fleet_commander.gd` (RefCounted order
  generator), `scripts/combat/ai_search.gd` (T3 + shared evaluation +
  `THETA_AGGRESSIVE/BALANCED/CAUTIOUS` int const arrays),
  `scenes/combat/battle_sandbox.gd` + `.tscn` (S21).
- Tools/tests: `tools/validate_data.py` (group-2 fields, group-7
  `ai_profiles`), `tools/battle_ai_harness.gd` + `.tscn` (new),
  `tools/battle_tune.py` (new), `tools/battle_ai_harness_report.md` +
  `tools/battle_tune_report.md` (tool-owned), `tools/test_battle*.gd/tscn`,
  `tools/test_battle_sandbox.gd/tscn` (new), `tools/test_phase2_acceptance.gd`,
  `tools/test_tournament.gd`, one headless S10 boot, S21 boot.

---

## Parallel-orchestration model (all waves)

- **Max 4 background subagents per wave, one worktree each**
  (`opencode.worktree_create`, branches `phase9/<slot-slug>`), plus the
  **master**, who owns: launching with full context, merging in the stated
  slot order on `main`, running the wave gate after **each** merge,
  bounce-back integration fixes, the micro-integration ledger, the named
  **θ-finalization task** (correction 11), and all status stamps.
- **One writer per file per wave** — slot tables list exclusive file sets.
- **Held-branch / staged protocol** (Phase-7/8 precedent): a slot whose gate
  is red standalone builds against a master-provided snapshot of its
  dependencies and merges **last** in its wave; the gate runs once on main.
- **Wave-internal serialization**: W3-A must merge before W3-B/C/D launch
  (they compile against the rewritten sim API); W3 runs one slot, then three.
  W5-A must merge before W5-B/D launch (they drive the new sim). At no point
  do more than 4 subagents run concurrently.
- **Harness-before-rewrite rule** (correction 13): W3-A's first act on its
  worktree is building the harness and capturing the old-engine baseline.
- **Micro-integration ledger** (master only, ≤ 5-line edits, recorded per
  merge): S1 button-stack ordering, late `ui_strings` keys found in review,
  RNG stream-order fixes, tournament-variant wiring checks, doc status stamps.

---

## W1 — Docs first (4 slots: A, B, C, D · merge order A → B → C → D)

No code, no data. Every number above lands in its owning doc before W2.

- **A** (`phase9-docs-schema`) — `docs/00-OVERVIEW.md` (glossary set per
  correction 9; §5 Phase-9 row), `docs/10-DATA-SCHEMA.md` (ship_types three
  fields with ranges: `battle_max_speed` 2..4 from speed 16/20/24 per
  correction 3, `battle_accel` ∈ {1,2}, `battle_turn_rate` ∈ {45,90};
  npc_config `ai_profiles` nine-key block with enums — `archetype` ∈
  {aggressive,balanced,cautious}, `focus` ∈ {weakest,nearest,flagship},
  `formation` ∈ {line_ahead,column,screen,swarm}, `ai_level` ∈ {0,1} — and
  ranges, validator group-2/7 spec, `battle.*` + `sandbox.*` ui_strings
  family inventory).
- **B** (`phase9-docs-battle`) — `docs/60-COMBAT.md` physics half: §4.2
  (48×30 grid, deployment table + tournament variant, wind/weather lock),
  §4.3 rewrite (three-phase turn, initiative-once with sail delta), new
  §4.3a (velocity/inertia/sweep/clamp rules), §4.4 rewrite (broadside arcs,
  damage stack, weather multipliers, rake), new §4.4a (reload formula), new
  §4.4b (shot array + the four-rule deterministic AI shot selection), §4.5
  rewrite (sweep ram, bow/stern ×1.15), new §4.6a (hook condition, both-vel-0,
  strike semantics), §4.7 repin (surrender roll + morale modifier), §4.11.2
  (deployment), §4.11.4 (turn-engine repin incl. initiative-once), §4.11.5
  (damage incl. crew casualties), §4.11.8 (T2 tie-breaks), §4.11.9/§4.11.10
  (`stall` row + aftermath, round cap 40), §4.11.12 (sail → cap_eff/initiative
  amend, correction 2).
- **C** (`phase9-docs-ai`) — `docs/60-COMBAT.md` AI/interface half: new
  §4.8a (morale ranges/start/events/gates/writeback, correction 5/6
  semantics), §4.8 repin (flat +5 absorbed), new §4.9a (profile keys +
  lookup rule correction 8 + T2 priority list verbatim), new §4.9b (order
  five-tuple, state-machine table, hysteresis, anchor succession, target
  assignment), new §4.9c (T3 search, nine features, θ flow, per-level kind
  table, adoption gate, perf pin), §4.12.1 (config: `player_stats` optional,
  `wind_dir`/`current` keys w/ defaults, `max_rounds` default 40, new
  `legal_velocities`/`apply_velocity`/`snapshot`/`restore` API), §4.12.1.1
  (`{action, target, cell, vel}` decision dict), §4.12.2 (outcome adds
  `stall` + `morale_delta`), §4.12.4 (sandbox zero-write branch).
- **D** (`phase9-docs-ui`) — `docs/80-UI-UX.md` (§4.1 S21 row, §4.2 S1→S21
  →S10→S21 nav edge, §4.3 camera/minimap/edge-scroll/Home/shot-selector
  input lines, §4.7.1 S10 full rewrite — world/viewport/bottom bar/ring/
  selector/AI-speed switch, §4.8 minimap palette, S21 screen spec: layout,
  clamp rules, import/export behavior, zero-write UX),
  `docs/90-ARCHITECTURE.md` (scene-flow edge; module list:
  fleet_commander/ai_search/battle_sandbox).
- **Gate (master)**: every number traceable to the decision record or a
  correction row; cross-doc references consistent (incl. the corrected
  `20-* §4.4/§4.7` citations); `validate_data.py` exit 0; status stamp.

## W2 — Data, strings, sandbox skeleton, validator (4 slots, staged · merge A → B → C → D)

- **A** (`phase9-data`) — owns `data/ship_types.json` (three fields, all 16
  hulls, correction 3 values) and `data/npc_config.json` (`ai_profiles`,
  all nine keys × nine kinds, correction 11; values per the source §2.1
  table + decision 13/formation defaults: navy/patrol line_ahead, privateer/
  pirate swarm, treasure screen, trader/coaster/courier column, tournament
  line_ahead).
- **B** (`phase9-strings`) — owns `data/ui_strings.json`: `battle.*` family
  (`fit/speed/heading/wind/current/weather/reload.port/reload.starboard/
  morale/formation/shot.round/chain/armor_piercing/grape/log.rake/log.strike`
  + selector/ring/switch labels) and the full `sandbox.*` family, both
  locales, per the W1-D inventory.
- **C** (`phase9-sandbox`) — owns `scenes/combat/battle_sandbox.gd` + `.tscn`
  (S21 skeleton: per-ship editing, condition row, clamp rules, run/random/
  import/export buttons, forward-compat full schema, configuration kept on
  return), `scenes/title/title_screen.gd` (海战 button), the §4.12.4 sandbox
  branch in `scenes/combat/battle_screen.gd` (fixture assembly, read-only
  after-action, S21 return), the `player_stats` seam in
  `scripts/combat/battle_sim.gd` (**additive optional key only** — W3 must
  preserve it), new `tools/test_battle_sandbox.gd/.tscn` (S21→S10 headless
  boot, override/fallback unit tests, clamp assertions, **zero-write audit**
  — full `GameState`+`NpcFleets` snapshot equality, same-config same-seed
  `log_lines()` byte-identity).
- **D** (`phase9-validator`, staged — branches off a master snapshot of
  A+B, merges last) — owns `tools/validate_data.py`: group-2 ship_types
  field checks (ranges, per-speed mapping), group-7 `ai_profiles` shape/
  enums/ranges incl. the coaster forward-compat row.
- **Gate (master)**: validator exit 0; sandbox suite green (zero-write audit
  included); strings parity zh/en; status stamp.

## W3 — 9A physics + T2 baseline + S10 rebuild (4 slots · A alone first, then B ∥ C ∥ D; merge A → B → C → D)

- **A** (`phase9-battle-sim`) — **at slot start**: build
  `tools/battle_ai_harness.gd/.tscn`, run the 64-seed mirror set on the
  **current engine**, write the report's before-section (correction 13).
  Then rewrite `scripts/combat/battle_sim.gd` (unit state, `legal_velocities`
  + integer-bucket heading, `cap_eff`, sweep + ram, broadside volleys + the
  four shots + §4.4a reload + crew casualties, hook/board with both-vel-0,
  stall detection, round cap 40, `snapshot()/restore` flat-array, config
  `wind_dir`/`current` keys, `player_stats` seam preserved, decision
  `{action,target,cell,vel}`) and `scripts/world/interactions.gd` (contact
  handoff injects `wind_dir`/`weather`/`current` from world state + the
  decoded contact-tile current).
- **B** (`phase9-t2-ai`, after A) — owns `scripts/combat/ai_fleet.gd`:
  T2 greedy rewrite per §4.9a + decision 13 (surrender roll with
  `courage_mod`, flee by profile, loaded broadside fire with rake
  preference, kite, hook-window deceleration, board/ram conditions, shot
  selection per §4.4b), broadside split in `compose_enemy` (`cannons_port/
  starboard` derived, total retained), profile consumption with the
  correction-8 lookup.
- **C** (`phase9-battle-ui`, after A) — owns `scenes/combat/battle_screen.gd`
  (battle-scene half only — the sandbox branch stays untouched; camera,
  minimap, hook ring, shot selector, bottom-bar readouts, weather/wind
  icons, AI-turn speed switch, single headless S10 boot test in
  `tools/test_battle_screen.gd`), `scenes/combat/battle_grid_overlay.gd`
  (reachable-set vectors, arc fans, side indicators). Camera math extracted
  as pure functions inside the scene script (world↔screen, clamp, zoom
  anchor, minimap mapping, 4 px click/drag threshold) with fixed-value
  assertions in the same suite.
- **D** (`phase9-battle-tests`, staged after A+B+C) — owns
  `tools/test_battle.gd/tscn`, `tools/test_battle_economy.gd/tscn`,
  `tools/test_phase2_acceptance.gd/tscn`, `tools/test_tournament.gd/tscn`
  re-pins (semantic pins already in W1 docs) + the fixed-situation suite
  (velocity legality, `cap_eff` tiered incl. calm identity, bucketing,
  arcs, reload formula at gunnery 0/50/100 + legacy fallback + low crew,
  casualty rules, grape range/half-damage/no-gate, four shot-rule
  situations, rake, three sweep boundaries + bow/stern ×1.15, hook
  condition, stall + counter reset, initiative, tournament variant,
  determinism audit).
- **Gate (master)**: `run_tests.py` green (ZOMBIE/HANG = 0); harness report
  with before/after comparison within the health band (avg rounds 12–25,
  cap < 10 %, stall < 5 %, legal-action 100 %, avg decision ≤ 30 ms);
  `log_lines()` byte-identity audit; status stamp.

## W4 — 9B morale & 9C fleet command (4 slots · merge A → B → C → D)

- **A** (`phase9-morale-sim`) — owns `scripts/combat/battle_sim.gd`: side
  morale state + start formulas, event hook points (sunk/captured/raked/
  boarding), per-ship surrender gating (≤ 20 ∧ ≤ 25 % roll with morale
  modifier; AI-side ≤ 10 instant strike), `morale_delta` outcome + writeback
  path, snapshot additions.
- **B** (`phase9-fleet-command`) — owns `scripts/combat/fleet_commander.gd`
  (new: per-round five-tuple orders, state machine, hysteresis, anchor
  succession, target assignment — RefCounted pure logic) and
  `scripts/combat/ai_fleet.gd` (order consumption: station/heading/speed-band
  steering, discipline removal, engage-side selection, morale flee rule).
- **C** (`phase9-morale-ui`) — owns `scenes/combat/battle_screen.gd` (side
  morale bars, minimap anchor lines + formation label),
  `scenes/combat/battle_sandbox.gd` (initial-morale fields, `formation`
  override), `data/ui_strings.json` (`battle.morale`, `battle.log.strike`,
  `battle.formation` + sandbox field labels, both locales).
- **D** (`phase9-morale-tests`, merges last) — owns the morale/fleet test
  additions in `tools/test_battle.gd/tscn` + new
  `tools/test_fleet_command.gd/tscn` (event-table row assertions, both-side
  strike semantics incl. player-side never-auto, transfer-table fixed
  situations — form→close→engage→wear→engage, break triggers, hysteresis,
  wear lock, anchor succession, five-tuple determinism) + harness re-run
  (navy line_ahead vs pirate swarm stats: rounds/winrate/formation-hold).
- **Gate (master)**: validator exit 0; suites green; harness re-run report
  updated; status stamp.

## W5 — 9D lookahead, tuning & sandbox tail (4 slots · A first, then B ∥ C ∥ D; merge A → B → C → D)

- **A** (`phase9-t3-search`) — owns `scripts/combat/ai_search.gd` (new: T3
  enumeration on `snapshot()/restore`, shared evaluation, three θ const
  arrays seeded with the §5.1 prior, discipline removal, tie-by-enumeration)
  and the `ai_level` dispatch in `scenes/combat/battle_screen.gd` +
  `scripts/combat/ai_fleet.gd` (profile `archetype` → θ selection);
  candidate-bound + single-decision benchmark pins asserted in its own
  suite additions.
- **B** (`phase9-tune`, after A merges — it drives the new sim) — owns
  `tools/battle_tune.py` (new, stdlib CEM, subprocess headless Godot, frozen
  64+64 seed table, side-swapped CRN, two-stage learning, all report items
  per decision 16) and `tools/battle_tune_report.md` (tool-owned).
- **C** (`phase9-sandbox-tail`) — owns `scenes/combat/battle_sandbox.gd`
  (`ai_level`/`archetype` overrides + full-field round-trip: export → import
  → re-export byte-identical; zero-write + determinism audit re-runs).
- **D** (`phase9-t3-tests`, after A merges) — owns T3 assertions in
  `tools/test_battle.gd/tscn` + new `tools/test_ai_search.gd/tscn`
  (candidate bound, same-seed decision identity + `log_lines()` byte
  identity, discipline removal fires, harness T3-vs-T2 extension wiring,
  CEM reproducibility: fixed sampling seed ⇒ identical two runs, adoption-gate
  arithmetic check).
- **Gate (master)**: adoption decision recorded here with measured numbers;
  performance pin met; determinism audit pass.
- **Master named task after the gate** (correction 11): doc-review
  `docs/60-COMBAT.md` §4.9c final integer θ per stage gates (convergence →
  rounding → learning-gain → validation droop ≤ 2 pp → ±20 % perturbation ≤
  3 pp → behavior distinctness), sync the three const arrays in
  `ai_search.gd`, re-run the touched suites, stamp the report.

## W6 — Final acceptance (master + ≤ 2 slots)

- Full `run_tests.py` green; `python3 tools/validate_data.py` exit 0.
- Harness + tune reports final; adoption/θ records complete.
- Day-tick budget re-verified (combat sits outside the day tick; confirm the
  Phase-8 ≤ 75 ms gate at the measured fleet count is unchanged).
- Acceptance record written into this file; `AGENTS.md` backlog line updated
  (Phase-9 acceptance + parking lot); parking-lot carries: per-broadside
  pre-loaded shot types (post-9C review), `merchant` fourth archetype (S5),
  sandbox preset persistence (S4), Phase-7 economic leftovers, NPC-captain
  recruitment, titles/traits, officer quests, chronicle screen.

---

## Verification plan (whole-phase gates)

| Wave | Gate |
|---|---|
| W1 | doc traceability sweep; validator exit 0 |
| W2 | validator exit 0; sandbox suite green incl. zero-write audit; strings parity |
| W3 | `run_tests.py` green (ZOMBIE/HANG = 0); harness before/after within health band; determinism audit |
| W4 | validator exit 0; morale/state-machine assertions green; harness re-run |
| W5 | adoption gate (≥ +10 pp, 100 % legal, ≤ 30 ms avg); CEM convergence + learning-gain + droop ≤ 2 pp + perturbation ≤ 3 pp; behavior distinctness; audit |
| W6 | full-suite green; validator 0; day-tick gate unchanged; acceptance record |

## Risks & fallbacks

- Scope → 4 sequential code waves, each independently green and revertible.
- 1-ply oscillation under inertia → fleet-layer feed-forward + hysteresis +
  engage-hard-discipline (three suppressors, as designed).
- Line formation "never forms" → `form` is its own phase (tolerance 2,
  3-round bail-out); harness formation-hold metric.
- Balance drift (reload/crew/morale/hook/ram land together) → per-wave
  harness re-run against the health band; coefficients finalize in W5.
- Grape+board combo dominance → harness boarding-winrate + grape-share
  metrics; the crew-kill 0.5 coefficient is the tuning lever.
- Tournament regression (S13 reuses S10) → deployment variant repinned and
  `test_tournament` green at every wave gate.
- Prototype convergence (three θ learn to the same point) → stage-2 small
  fine-tune counts preserve directionality; behavior-distinctness gate;
  last resort: ship two θ sets and record it (do not block the phase).
- Sandbox-editor UI bulk → 9E0 skeleton first; per-wave field growth owned
  by that wave's UI slot; clipboard schema forward-compatible from W2.

## Out of scope (Phase 9)

Battle terrain (reef/coast tiles), per-broadside pre-loaded shot states,
deeper-than-1-ply search, online learning at runtime, multiplayer, sandbox
preset persistence (deferred per S4), the merchant archetype (pending S5),
hired escorts, and every Phase-8 parking-lot item except those explicitly
listed in W6.
