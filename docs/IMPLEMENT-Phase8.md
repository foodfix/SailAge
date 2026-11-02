# IMPLEMENT — Phase 8: Characters, Careers & Encounters (the RPG overhaul)

**Status (2026-11-02):** **backlog ratified** — W1 (docs) may launch; W2+
requires W1's merge gate (docs lock every number before code).
**W1 status (2026-11-03): ✅ complete** — slots A/B/C/D merged in order on
`main` (commits `0e066f1`, `5031cfd`, `1d65bd2`, `3fa9048` + master
integration fixes), `validate_data.py` exit 0 after **each** merge; every
locked number now lives in its owning doc. Master micro-integrations at the
gate: charisma price multiplier pinned (`50-*` §4.2/§4.5.2, bounty pinpoint
base 100g in `70-*` §4.5), appraisal price memory pinned session-transient
(`30-*` §4.2), `00-*` §5 completion-style consistency.
**W2 status (2026-11-03): ✅ complete** — slots A/B/C merged, then the
staged validator D last; gate on `main` green: validator groups 1–12 exit 0,
`build_captains.py --check` byte-identical (2 runs), `build_routes.py
--check` / `build_world.py --check-snaps` / `build_ocean.py --check` green.
**Measured canon (the acceptance-record pin, correction 2): 1,275 captain
cards** covering the extreme preset (trader 525 / coaster 450 of which 135
nationless / patrol 72 / courier 48 / privateer 56 / pirate 100 / hunter 24;
treasure 24 covered by trader tier-2), officers 96 = 24 + 72
(captain-qualified 28 ≥ 12; specialty coverage min 10 carriers/skill),
ui_strings 681 → 844 keys. Master deviations, recorded: (a)
`data/npc_captains.json` deletion + the absence assertion move to **W4-B**
with the last runtime reader (W3's `run_tests` gate needs the pool draw
alive; validator TODO left in place); (b) slot A added the `officer_bios`
block to `captain_name_parts.json` (doc row added); (c) the level-up toast
lands on the new `char.level_up.alloc` key beside the Phase-1
`char.level_up` (W6 wiring note).
**W3 status (2026-11-03): ✅ complete** — slots A (Person model +
skills.gd + posts/loyalty) → B (sailing rewires) → C (battle sim on the
Person model, dual captain-card shape) → D (trade wiring) merged in order;
gate on `main`: **`run_tests.py` 42/42 green, exit 0** (baselines: 42
suites incl. the new `test_skills`, 156 checks); speed/sighting/duel/storm
formulas pinned term-by-term in their suites; **vertical-slice headless
check PASS** (fresh boot: background + alloc attribute feel, speed
`seamanship/300` delta, duel base, `alloc_pending` round-trip, training
price closed form; zero SCRIPT ERROR). Master sweep at the gate (recorded):
attribute reads unclamped (1–100 is write-side — formulas stay exact at
fixture boundaries; `test_character` re-pinned), discovery radius rewired
to `36 + floor(cartography/15)` (`discovery.gd`, unowned file),
`test_discovery`/`test_demo_loop` re-baselined to in-post officer
contributions, `test_world_map` helm fixture moved to 07:12 (night-sail
rule), `test_world_e2e` fixture: v9 player block + navigation 40 (night
exemption) + one captain-qualified officer over the brigantine type
(captain-less ×0.8 lifted) + courage 100 (storm-headway retention 0.6125 →
storm-day bound 22; calm 19 stays the envelope floor), `test_phase2_
acceptance` S2/S2b fixtures to the v9 skill block, `test_ocean` luck
fixtures to the v9 attribute block. Doc amends: charisma multiplier
illustrative fixed (×0.55 at CHA 100), `officer_states` optional
`wage_mult`/`skill_deltas` keys specced (`90-*` §8 — `skill_deltas` is
**W6-C's persistence** of the in-post +1/90-days growth). Cross-wave
notes: W4-B carries `captain_id` into fleets + the battle config; W4-C
applies the boarding `morale_bonus` (outcome field) and the
valuation/XP multipliers; W6 wires `char.level_up.alloc` + the battle
screen's chain/AP buttons + boarding presentation bases.
**History:** source plan `.kilo/plans/1793586441004-phase8-rpg-overhaul.md`
(product-owner locked decisions, 2026-11-02). The "Review corrections" table
records every divergence from that plan, all verified against the repo on
2026-11-02; the locked numbers below already reflect the corrections.
**Prerequisite (verified 2026-11-02):** Phase 7 is fully complete — final
gate green on `main` (`tools/demo_check_phase7.md`: validator groups 1–10
exit 0, rebuilds byte-identical, **39 suites** incl. `test_allegiance` /
`test_market_screen` / `test_save_v7`, probe: 16 scenarios / 73 checks,
`sim_trade.py` gates 1–10, day tick within the 75 ms pin @ 307–323 fleets) —
**plus the out-of-band explored-state amendment (2026-11-02), which already
shipped `SAVE_VERSION = 8` / `PHASE = 8`** (`autoload/save_system.gd:107`,
`90-*` §8.2, `tools/test_save_v8.gd`). Everything this phase extends — the
8-role fleet ecology (current cap **323** at normal), `officers.json` v1
(old 4-stat scale, `OFFICER_MAX = 3`), `FLEET_MAX = 5`,
`data/npc_captains.json` name pools, the right-click attack funnel — is in
place to be replaced or retired.

---

## Goal

Replace the four-stat "leadership/seamanship/combat/navigation/luck"
character with a unified **Person model** (5 innate attributes + acquired
skills + personality/appearance/relations) shared by player, officers and
NPC captains; retire `60-* §4.6`'s `5+tier` duel stand-in and the flat
`ROLE_STAT_BONUS` officer stack; add at-sea and in-port people interactions
(inspect / talk / attack / gifts / appointments); and swap the anonymous
name pools for a **closed canon of ~1,200 named captains** with a
defeat → return-queue lifecycle. Two QoL systems ride the same model:
**appointed voyage** (navigator-gated auto-sailing) and a two-step
**new-game creation** (background + free points).

---

## Review corrections applied to the source plan

| # | Source-plan claim | Verified fact (2026-11-02) | Fix applied |
|---|---|---|---|
| 1 | "Save v8 (v7 拒绝)" | v8 is **already taken** by the explored-state amendment (`SAVE_VERSION := 8`, `PHASE := 8`, `save_system.gd:107-109`; `90-*` §8.2 dates it 2026-11-02; `tools/test_save_v8.gd` ships) | Phase 8 ships **`SAVE_VERSION = 9`, `PHASE = 9`, v8 refused, no migration**; `test_save_v8.gd` → `test_save_v9.gd` rework. All "save v8" mentions below read v9 |
| 2 | "建满到极限档 1,118 舰队"; "307 舰队 day tick ≤75ms" | Phase 7 raised the ecology: core 288 → **323** (34 nationless coasters, `demo_check_phase7.md`); presets are `deserted 0 / low 0.5 / normal 1.0 / high 2.0 / extreme 4.0`, `absolute_cap 2048` (`data/npc_config.json`) | Canon roster size is **computed, not magic-numbered**: W1 pins the rule "captains.json count ≥ the extreme-preset fleet total derived from `10-*` §4.11.11 budgets × preset multipliers"; the validator (new group) asserts coverage, and the acceptance record pins the measured number. Day-tick perf pin re-stated at **323** fleets |
| 3 | "坏血病宽限 `base + floor(CON/10)`（base = 现 20-* §4.9 值）" | `20-*` §4.9 has **no grace period** — scurvy's only number is the death threshold `counter ≥ 7` | Pin: scurvy game-over threshold becomes **`7 + floor(CON/10)`**; starvation and sinking untouched |
| 4 | "`battle_sim.gd:398` `combat_rating`" | File is `scripts/combat/battle_sim.gd` (the `world/` subtree has no battle code) | Path corrected in every task reference; no design change |
| 5 | ui_strings baseline "501 keys" (Phase-6 figure implied by reuse) | `data/ui_strings.json` is at **680 keys** after Phase 7 | W2 strings task re-baselines parity counts; W7 gate reports the new exact count |
| 6 | Officers: 6 flagship posts + 1 captain per escort | Current cap is **`OFFICER_MAX = 3`** (`character.gd:15`, `50-*` §4.5), `FLEET_MAX = 5` (`scripts/fleet/fleet.gd:15`) — the post system is unman-able at cap 3 | Pin **`OFFICER_MAX = 12`** in `50-*` (W1, B): 6 flagship posts + up to 4 captain posts (`FLEET_MAX − 1` escorts) + 2 idle bench (the capture/buy "空闲官员 ≥ 1" gate must be reachable when fully staffed) |
| 7 | `named_pirates.json` v2 "4 海盗升级全卡" | Phase 7 gave each pirate a **`drop` → rare equipment id**, pinned by validator group 7 (captain-id-keyed grant in `battle_rewards`) | The 4 pirate overrides **carry their `drop` field into the canon cards**; the rare-drop group-7 pin moves to the new captains group unchanged in semantics |
| 8 | Right-click = new interaction layer | Right-click is **already the attack funnel** (`60-*` §4.1); left-click is sail-to | W5 keeps left-click untouched; right-click opens `fleet_picker` with the old "attack" as one verb (no regression of the existing funnel UX) |
| 9 | Officer card shape unspecified for recruitment | `officers.json` v1 carries `recruit_ports` per officer; tavern hiring lists from it | v2 preserves recruitment placement: legend officers hand-author `recruit_ports`; generated regulars get a per-nation home-port band — enumerated in the T2 schema amend, not invented in code |
| 10 | "NPC 决斗/炮击 `5+tier`" is the only AI stat path | `battle_sim.gd` `combat_rating` is consumed on both AI branches and the escort branch exists for the player side | Escort `combat_rating = 剑术 + floor(胆识/20)` of its appointed captain is pinned into the same §3.3 migration row (already in source §3.7; kept) |
| 11 | W2 was 5+ streams (parts/captains/officers/validator/strings…) | Execution constraint: **max 4 background subagents, each in its own worktree, master merges** | Re-carved into 4 single-writer slots with the **staged-validator protocol** (validator slot builds against staged exports, merges last — the Phase-7 staged-sim precedent); every wave below names its slots, exclusive file sets and merge order |
| 12 | "升级瞬间只 toast + 徽标" | A `pending_levelup` **class static** already exists (`character.gd`); save keeps no such key | Kept: `pending_levelup` stays session-transient (toast), **`alloc_pending` is the persisted counter** (save v9) — no shape conflict |

---

## Decision record (carried from the source plan, corrections folded in)

1. **Attributes/skills two layers.** 5 innate attributes 1–100 start 10:
   constitution / intellect / charisma / courage / luck. Player skills 8
   0–100 start 0: seamanship, navigation, swordplay, gunnery, appraisal,
   negotiation, cartography, rumour. Officers share the space plus
   medicine, carpentry, cooking.
2. **Nation bonus** +5 to one attribute and +5 to one signature skill:
   portugal 悟性+航海, spain 胆识+剑术, england 魅力+炮术, holland 运气+交涉,
   ottoman 胆识+操船, italy 运气+鉴定.
3. **Growth**: level-up grants +2 free points (`alloc_pending`, cap 100 per
   attribute, spend any time); usage growth per skill counters; paid
   training `level×60g × (1−(INT−10)/200)`, training cap 60; officers in
   post +1 per 90 sea-days to the post's skill (idle → native main skill).
4. **Officer contribution**: `effective skill = player skill + the one
   in-post officer's true value` (one person per post; loyalty < 30 derate
   ×0.8; loyalty ≥ 80 native skill +5). `ROLE_STAT_BONUS` and the old
   stacking are deleted.
5. **Posts**: 6 flagship functional posts (prereq matching skill ≥ 20) +
   1 captain post per escort (seamanship ≥ 25 **and** courage ≥ 30); true
   skill feeds the pipeline, no cross-post multiplier; captain-less ship
   speed × 0.8, morale decay − 2 extra; capture/buy requires ≥ 1 idle
   officer (captured ship auto-converts to loot + scuttle instead).
   `OFFICER_MAX = 12` (correction 6).
6. **Officer roster 96** = 24 legends (hand overrides, main skill 45–60,
   wage 40–60g/day) + 72 regulars (generated from name parts, 25–45,
   20–35g); `officers.json` is a **built artifact** of
   `tools/build_captains.py`, rebuilds byte-identical.
7. **Mandated defect fixes**: luck ≥ 50 step → continuous; officer stats
   onto the 1–100 scale; player/officer/NPC scales unified;
   sighting moves to navigation skill, discovery radius to cartography.
8. **NPC captains**: all named, closed canon generated to cover the
   extreme preset (correction 2), byte-identical rebuilds; ~24 legend
   cards hand-authored (4 named pirates + 20 legend captains).
9. **Lifecycle**: captains never die — defeated → return queue
   (day + 60) → refit; tier drift ±1 clamp 1–3; the Phase-5 successor
   machinery (`npc_captains.json`, `named_pirate_respawns`) is retired.
10. **Interactions**: right-click picker (inspect / talk / attack),
    intercept order, in-port facility rows, officer 4 actions, dossier,
    pirate-fame extension, at-sea supply buying (×1.5; ×1.25 at stance
    ≥ +3), intimidation, tavern sparring bets, inform-on-pirates,
    officer advice events, retirement-screen RPG segment.
11. **Unified character card** `scenes/ui/character_card.tscn` renders any
    person; NPC card shows **everything on identification** (familiarity
    only gates the dossier career log).
12. **Level-up allocation** happens on the player's own card (attribute
    tab): toast + badge on level, `alloc_pending` persisted, no modal
    interrupt; points deferrable forever.
13. **Relations**: officer loyalty 0–100 (<30 derate + raise event, <15
    quits, ≥80 signature +5, increments charisma-modified); NPC captain
    stance (≥+2 free intel, ≥+3 supply price ×1.25, ≤−3 nemesis hunter)
    + familiarity (3/6/10 career-log tiers).
14. **New game**: nationality (unchanged) → background (6-choice card,
    attribute +3 / skill +5) → free points (attributes +5 total,
    skills +3 total, single-item cap +3, must spend all, "spread evenly"
    shortcut). Extremes: attribute ≤ 21, skill ≤ 13 at creation.
15. **Appointed voyage**: known-port auto-sailing gated on pilot-officer
    in post with navigation ≥ 40 (`skill_gates` `sail.autopilot`);
    40–69 shortest water path; ≥ 70 wind/current-weighted A*; auto-cancel
    on hostile contact, storms do not cancel (auto-reef);
    supplies/wages still charged; no gold fee.
16. **Save v9, no migration** — v8 refused (correction 1).
17. **Balance gated by measurement** — `sim_trade.py` gates 1–10 re-run on
    the new speed clamp; duel RNG re-baselined; storm gate re-verified.
18. **Not doing**: hired escorts (Phase-9 candidate), release/ransom,
    informant networks, personality-friction events, per-crew rosters.

---

## Locked design (the numbers W1 writes into the system docs)

### 2.1 Attribute consumers (every attribute ≥ 3 formulas)

| Attribute | Locked formulas |
|---|---|
| 体魄 constitution | scurvy game-over threshold **`7 + floor(CON/10)`** (correction 3); ramming self-damage × `(1−(CON−10)/200)`; storm-day morale decay × `(1−(CON−10)/300)` |
| 悟性 intellect | training fee × `(1−(INT−10)/200)`; rumour accuracy / hint-quality tiers; chart reveal precision bonus |
| 魅力 charisma | desertion/mutiny × `(1−(CHA−10)/200)` (takes over all leadership sites, formula unchanged); loyalty growth rate, signing fee / wage talks, rumour & bounty-board discount |
| 胆识 courage | duel `+floor(COU/20)`; speed retention in storm × `(1−(COU−10)/400)`; boarding-victory morale |
| 运气 luck | storm chance × `(1−luck/400)` (unchanged); storm damage × `(1−luck/250)` (replaces the ≥50 step, player-only); named-drop rolls |

### 2.2 Skills — usage growth / magnitude / gates

| Skill | Growth (+1 per N uses) | Magnitude | Gates |
|---|---|---|---|
| 操船 seamanship | 30 sea-days; storm survival +1 | speed `skill/300` clamp `[0, +0.30]` | ≥60 foul-weather sail repair |
| 航海 navigation | 30 sea-days | sighting `48 + floor(skill/12)` | ≥40 no night-sail extra slow |
| 剑术 swordplay | every duel round | duel attack value (§3.3) | ≥30 / ≥60 duel-ladder ranks |
| 炮术 gunnery | per 10 cannon shots | hit/damage `+floor(skill/25)` | ≥25 / ≥50 chain / armor-piercing shot |
| 鉴定 appraisal | per 20 profitable trades | price-memory entries `skill/10` | ≥30 profit arrows; ≥60 other-port memory |
| 交涉 negotiation | per 15 trades; permit purchase +2 | tariff −`floor(skill/10)`% cap −5% | ≥40 home permit 95%; ≥70 foreign permit 90% |
| 制图 cartography | per 5 Explores | discovery radius `36 + floor(skill/15)`; chart reveal `+1+floor(skill/25)` | ≥30 reef annotations |
| 打探 rumour | per 10 rumour buys / bounty views | rumour accuracy tiers (INT-modified) | ≥40 bounty pinpoint at half price |
| 医术 medicine (officer) | in-post 90 sea-days +1 | feeds scurvy grace (same source as CON row) | ship-surgeon post prereq ≥20 |
| 修造 carpentry (officer) | in-post 90 sea-days +1 | repair fee −`floor(skill/20)`% | ≥60 at-sea minor repair; post prereq ≥20 |
| 烹饪 cooking (officer) | in-post 90 sea-days +1 | morale daily decay −`floor(skill/25)` | post prereq ≥20 |

All gates data-driven in `data/skill_gates.json`:
`{feature_id, stat_or_skill, threshold, reason{zh,en}}`, one UI renderer
for locked reasons.

### 2.3 Formula migration (old → new, with regression owner)

| Old | New | Regression |
|---|---|---|
| leadership → desertion/mutiny | charisma, formula unchanged | `20-*` §4.14 sampling re-run |
| speed `(S−10)/100` clamp `[−.10,+.20]` | `seamanship/300` clamp `[0,+.30]` | **sim_trade gates 1–10 re-run** (fallback +0.25) |
| sighting `48+floor((nav−10)/10)` | `48+floor(navigation/12)` | closes the Phase-6 unswept item |
| duel `combat+equip+rand(0,20)` | `剑术+floor(胆识/20)+equip+rand(0,20)`, defender `+floor(魅力/20)` | duel RNG re-baseline |
| NPC duel/cannon `5+tier` (`scripts/combat/battle_sim.gd` `combat_rating`) | captain card: duel `剑术+floor(胆识/20)`; cannon `+floor(炮术/25)`; player escort ships use their appointed captain the same way | computed once at composition |
| NPC surrender fixed <25% | `25% − floor(胆识/10)%` clamp `[10%,40%]` | `60-*` §4.7 amend |
| luck ≥50 ×0.75 storm damage | ×`(1−luck/250)` | demo-loop storm gate re-verified |
| loot/XP fixed | negotiation/appraisal mod cargo valuation; XP ×`(1+level/20)` | battle-rewards tests |

### 2.4 Named-captain canon (closed roster)

- **Generator** `tools/build_captains.py` ← `data/captain_name_parts.json`
  (6 nations, ~30 surnames × ~30 given names, zh/en parts) + role × tier ×
  nation quota table (derived from `60-*` §4.1.1 budgets ×
  `npc_config.json` presets, covering the extreme preset — correction 2) +
  `tools/captain_overrides.json` (legend layer: 4 named pirates **with
  their `drop` fields**, correction 7 + 20 legend captains) +
  `tools/officer_overrides.json` (24 legend officers). Outputs
  `data/captains.json` (**and** `data/officers.json` v2 — one tool, one
  name-part/seed/override family), byte-identical rebuilds.
- **Card generation**: level `1+tier×4` (+2 pirate/hunter); attributes 10
  base, main `+3×tier`, secondary `+2×tier`, others `+1×tier`, seeded ±3;
  signature skill `8×tier+seeded(0..6)`; secondary `4×tier`; personality
  1–2 from the role pool; appearance as structured tags `{face, beard,
  eyes, …}` rendered by string-part assembly.
- **Role templates**: trader 魅/运-交涉·鉴定; coaster 体/运-low;
  patrol 胆/魅-炮术·操船; courier 体/悟-航海·操船; privateer 胆/运-剑术·炮术;
  pirate 胆/魅-剑术·炮术; hunter 胆/悟-剑术·航海.
- **Tier ranges**: coaster 1; trader/courier 1–2; patrol 2;
  privateer/hunter 2–3; pirate 1–3.
- **State machine** (`scripts/world/captains.gd`):
  `active → defeated → returning(day+60) → active`; tier drift −1 crushed /
  +1 wins, clamp 1–3; stance ≤ −3 pirate/privateer returns as a nemesis
  hunter (lightweight).
- **Canon/state split**: cards in `data/` (save-independent);
  `captain_states` (status/return_day/tier_now/stance/familiarity/
  dossier_seen/defeats/wins) in save v9, full entries only for met
  captains. **Names are never reused** (regression-pinned).

### 2.5 Interactions

- **At sea**: right-click inside sighting radius → `fleet_picker`
  (flag color / role icon / identified name / tier; multi-fleet pick
  first) → inspect / talk / attack. Left-click sail-to unchanged;
  empty-water/land right-click is a no-op (correction 8).
- **Hail** (Chebyshev ≤ 2, `hail_modal`): options from role × stance ×
  skills — ask rumours (**stance ≥ +2 grants one free route/market
  intel**), buy supplies (trader/coaster, port price ×1.5, stance ≥ +3
  ×1.25, negotiation −`floor(skill/10)`%), intimidate
  (`p = clamp(our_strength/total + 胆识/200 − stance_penalty, .05, .95)`,
  success = goods + pirate fame, failure = battle), befriend (stance +1).
- **Attack / intercept order**: reuses click-to-sail movement + contact
  pipeline; cancel when target leaves sighting; attacking a non-hostile =
  piracy (`70-*` §4.5 −20 fame extension); coasters are not attackable
  (intimidate-only).
- **In port**: `80-*` §4.7.8 dice layer kept; facility sighting rows gain
  in-place verb matrices (market = quotes/supply pre-order; tavern =
  befriend/sparring bet 100–1000g; inn = limited talk, +1 extra
  familiarity; palace = bounty business/inform); tavern gains the
  **captain's table** index (this port's sightings + facility pointers).
- **Officer 4 actions**: talk (loyalty +1, 10-day cooldown), gift (200g →
  +5; greedy +8 / honest +3, 10-day cooldown), train (§2.2 formula),
  appoint (post table + prereqs). Loyalty <30 → post contribution ×0.8
  + raise-demand event; <15 → resigns.
- **Dossier**: card-external info layer; familiarity unlocks only the
  career log (3 fleet composition / 6 home port + sighting history /
  10 full lanes incl. month variants); card numbers never gated.
  Stance ≥ +2 adds current tier + status to the header. Bounty board
  links to dossiers.
- **Officer advice events**: each sea-day tick, 3% per **in-post** officer
  (seeded) fires a situational hint when its post threshold is met
  (pilot = wind band tomorrow; surgeon = water ≤ 5 days; boatswain = sail
  plan wrong in storm; gunner = first contact round; carpenter = fleet
  durability < 50%; cook = morale < 40). Pure text
  (`ui_strings advice.{post}.{situation}`), trigger table in
  `officer_posts.json`'s `advice` field.
- **Retirement screen segment**: nemesis list (`captain_states` wins
  ranking), deepest grudge (lowest stance), most loyal veteran (highest
  loyalty with ≥ 90 sea-days served), one background bio line — all
  read-only from existing state.

### 2.6 Unified character card (identify = full reveal)

- One scene `scenes/ui/character_card.tscn` renders player / officer /
  NPC captain: color-block portrait from appearance tags, name / flag
  block / role / tier badge / level, five attribute bars, skill bars
  (signature highlighted, unlearned grayed), personality tags, appearance
  sentence from part keys, relation block (officer: loyalty + native
  role/current post; NPC: stance/familiarity), career block (player:
  XP/level; NPC: wins/defeats/return day).
- Player card adds the **effective-values split** (base + officer
  contribution + native +5; the "without this officer" diff logic).
- Entries everywhere: panel header (player), officer row / tavern recruit
  dialog (officers), picker inspect / captain's-table row / bounty row /
  hail modal / battle intro preview (NPC); dossier = full card + career
  log. The same captain's card is identical from every entry
  (acceptance-pinned).
- **Allocation UX**: `award_xp` → toast + `alloc_pending += 2` (persisted)
  → badge on the character button → allocate on own card at leisure:
  per-attribute `+` stepper (enabled iff `alloc_pending > 0`) → draft →
  confirm / cancel rollback; clamp 1–100; no second confirm; skills never
  allocate (usage + paid training only).

### 2.7 Officer posts (native role fixed, post appointable)

- `data/officer_posts.json`: `{post_id, slot_type: flagship|captain,
  prereq{skill/stat: ≥v}, desc{zh,en}, advice{…}}`; 6 flagship posts
  (pilot/boatswain/gunner/surgeon/carpenter/cook, matching skill ≥ 20)
  + captain per escort (seamanship ≥ 25 and courage ≥ 30).
- Native role fixes: signature skill (loyalty ≥ 80 → +5), initial skill
  distribution, recruit text and personality pool; never restricts
  appointment.
- Post → pipeline (the derived-effects display is generated from this
  same table):

| Post | In-post skill → pipeline | Derived effect |
|---|---|---|
| pilot | navigation → sighting | `48 + floor(skill/12)`; ≥40 night-sail exemption |
| boatswain | seamanship → fleet speed | `+skill/300` (cap +0.30) |
| gunner | gunnery → hit/damage | `+floor(skill/25)`; ≥25/≥50 chain/AP shot |
| surgeon | medicine → scurvy grace | same-source as §2.1 CON row (base 7) |
| carpenter | carpentry → repairs | fee −`floor(skill/20)`%; ≥60 at-sea minor repair |
| cook | cooking → morale | daily decay −`floor(skill/25)` |
| captain (per ship) | seamanship/gunnery/swordplay+courage → that ship | ship speed, ship cannon, `combat_rating = 剑术+floor(胆识/20)` |

- Captain-less: ship speed ×0.8, morale decay −2 extra (cannon rating
  stays 0). Sunk/sold ship → captain returns to idle pool, loyalty −10
  (personality-scaled). Appointment UI: post column with prereq-gray +
  reason; fleet panel per-ship "captain: ___" row.

### 2.8 New-game creation (background + free points)

- Flow: nationality card (unchanged) → ① background → ② free points →
  confirm. New screen `scenes/title/creation_screen.tscn`, reusing the
  nationality card component and the §2.6 steppers.
- **Backgrounds** `data/backgrounds.json` (6, `{id, name, attribute_bonus,
  skill_bonus, bio}` zh/en): 甲板水手 体+3/操船+5; 海军见习生 胆+3/航海+5;
  商行学徒 魅+3/交涉+5; 制图学徒 悟+3/制图+5; 酒馆跑腿 运+3/打探+5;
  剑馆弟子 胆+3/剑术+5.
- **Free points**: attributes +5 and skills +3, per-item cap +3, must
  spend all; "spread evenly" shortcut (attributes +1 each; first three
  skills +1 each). Extremes: attribute ≤ 21, skill ≤ 13 — inside the
  existing balance band (creation cannot break §2.1–2.3).
- Live derived preview (sighting/speed/duel value move with the
  steppers, same-source formulas).
- `GameState.new_game(nation_id, background_id, attr_alloc, skill_alloc)`;
  `background_id` persists in save v9's player block.

### 2.9 Appointed voyage

- Entry: chart screen select a known port → 委任航行; or right-click a
  port harbor tile (same right-click pipeline, port target). HUD shows
  destination / ETA / cancel while appointed.
- Gate (`skill_gates` `sail.autopilot`): pilot in post **and** navigation
  ≥ 40, destination ∈ `known_ports`; grayed + reason otherwise; no fee.
- Route quality: 40–69 shortest water A* (plain); ≥ 70 wind/current
  weighted A* — cost = base × month-prevailing-wind heading factor ×
  current vector factor; avoids head-wind bands and ice, rides trades;
  hugging the 17 lanes is emergent, not authored. Data sources exist:
  `wind_regions.png` (month keys), `currents.png`, seasonal ice window.
- Interrupts: hostile contact → auto-cancel + notice; any manual input →
  cancel; storms do **not** cancel (auto-reef). Costs unchanged (the sea
  has a cost).
- Shared-A* rule: extract the common A* core from `npc_fleets.gd`
  pursuit as a **pure move first** (no behavior change), then the
  weighted cost function lands on top (see W5-D).

---

## Artifacts

**New data**: `data/captains.json` (built), `data/captain_name_parts.json`,
`data/skill_gates.json`, `data/officer_posts.json`, `data/backgrounds.json`,
`tools/build_captains.py` (two products: captains + officers v2),
`tools/captain_overrides.json`, `tools/officer_overrides.json`.
**Changed data**: `data/officers.json` v2 (built artifact, 96 = 24 + 72),
`data/named_pirates.json` v2 (full cards, `drop` preserved), `data/nations.json`
(new nation bonuses), `data/ui_strings.json` (char./skill./gate./hail./
interact./dossier./captain.table./officer.post./creation./sail.autopilot./
advice. families + personality/appearance part keys),
**`data/npc_captains.json` retired** (validator group for its absence).
**New code**: `scripts/player/skills.gd`, `scripts/world/captains.gd`,
`scripts/world/interactions.gd`, `scripts/world/hail_options.gd`,
`scripts/world/autopilot.gd`, `scenes/ui/character_card.tscn`,
`scenes/title/creation_screen.tscn`, `scenes/world/hail_modal.tscn`,
`scenes/world/fleet_picker.tscn`, dossier panel.
**Changed code**: `scripts/player/character.gd`, `scripts/world/sailing_sim.gd`,
`scripts/combat/battle_sim.gd`, `scripts/combat/battle_rewards.gd`,
`scripts/world/npc_fleets.gd`, `scripts/world/npc_intel.gd`,
`scenes/world/world_map.gd` (right-click), port screens (tavern/market/inn/
palace), `autoload/game_state.gd`, `autoload/save_system.gd`.

---

## Save v9 (v8 refused — correction 1)

```
player: { nation_id, background_id, attributes{5}, skills{8},
          skill_counters{8}, alloc_pending, xp, level,
          autopilot: {dest_port_id} (absent = not appointed),
          officers[], reputation{}, profit_by_nation{},
          profit_rep_awarded{}, equipment{} }
officer_states: {id: {loyalty, sea_days, post_id, ship_id,
                      talk_cd_day, gift_cd_day, defeats}}
captain_states: {id: {status, return_day, tier_now, stance,
                      familiarity, dossier_seen, defeats, wins}}
```

- All v8 keys carry forward (incl. `explored_tiles`) unless listed here.
- Removed: `player.stats` (leadership/seamanship/combat/navigation block)
  — no migration, old payloads refused wholesale.
- `level` remains the cached derivation of `xp`; counters follow the
  usage-growth rule (reset on award; stop counting at 100).
- `post_id = ""` = idle; `ship_id` non-empty only for captain posts.

---

## Parallel-orchestration model (all waves)

- **Max 4 background subagents per wave, one worktree each**
  (`opencode.worktree_create`, branches `phase8/<slot-slug>`), plus the
  **master**, who owns: launching with full context, merging in the
  stated order on `main`, running the wave gate after **each** merge,
  bounce-back integration fixes, micro-integrations (enumerated below),
  and all AGENTS.md / IMPLEMENT status stamps.
- **One writer per file per wave** — the slot tables below list exclusive
  file sets; a file appears in at most one slot per wave.
- **Held-branch / staged protocol** (Phase-7 precedent): a slot whose
  gate is red standalone (validator before its data lands, tests before
  their model) builds against a master-provided staging export of its
  dependencies and merges **last** in its wave; the gate runs once on
  main.
- **Wave-internal serialization**: a wave may spend fewer than 4 slots
  concurrently and reuse a freed slot for a dependent tail task (W2-D,
  W6-D do this) without ever exceeding 4 concurrent.
- **Micro-integration ledger** (master only, ≤ 5-line edits, recorded per
  merge): instancing `autopilot_hud` into the world HUD, the 2-line
  `interactions.gd` ↔ `hail_options.gd` hookup, late string keys found by
  code review, doc-status stamps.

---

## W1 — Docs first (4 slots: A, B, C, D · merge order A → B → C → D)

No code, no data. Every number above lands in its owning doc before W2.

- **A** (`phase8-docs-core`) — `docs/00-OVERVIEW.md` (glossary: 属性/技能/
  忠诚/恩仇/档案/船长桌/拦截令/名册/归队/威吓/切磋/出身背景/委任航行…;
  §5 Phase-8 row; §7 demo-loop step 2 → 国籍→出身→分配 two steps),
  `docs/10-DATA-SCHEMA.md` (schemas: captains / captain_name_parts /
  officers v2 / skill_gates / officer_posts / backgrounds; validator group
  spec: canon quotas ≥ extreme-preset total, name uniqueness, zh/en parts,
  field ranges, officer specialty coverage ≥ 10 per specialty,
  captain-qualified (seamanship ≥ 25 ∧ courage ≥ 30) ≥ 12, backgrounds
  keys/ranges; ui_strings family inventory),
  `docs/90-ARCHITECTURE.md` (module list: captains/interactions/autopilot/
  skills; save v9 §8 entries; v8-refused wording; tests conventions).
- **B** (`phase8-docs-character`) — `docs/50-CHARACTER-AND-PROGRESSION.md`
  full rewrite: Person model, §2.1–2.3 numbers, growth, nation mapping,
  officer v2 (96 roster, posts, `OFFICER_MAX = 12`, loyalty, native +5),
  §4.1 new-game flow two-step, gates by reference.
- **C** (`phase8-docs-world`) — `docs/20-WORLD-AND-SAILING.md` (luck
  continuous, CON trio, speed clamp, sighting formula; appointed-voyage
  input-mode section: gates/interrupts/quality tiers/wind-current cost),
  `docs/30-PORTS-AND-TRADE.md` (appraisal/negotiation effects & gates,
  market captain-intel rows), `docs/40-SHIPS-AND-FLEET.md` (carpentry
  discount & at-sea repair gate, captain-less penalties, capture/idle
  officer gate), `docs/70-QUESTS-DISCOVERY-ENDGAME.md` (retirement RPG
  segment; discovery-radius ownership moves to cartography).
- **D** (`phase8-docs-combat-ui`) — `docs/60-COMBAT.md` (duel/gunnery/
  surrender/loot/XP/intimidate/hail/intercept/nemesis/capture-officer
  gate + loot-convert fallback; §4.11 family extensions),
  `docs/80-UI-UX.md` (right-click spec, fleet_picker, verb matrices,
  captain's table, dossier, unified card spec: layout/entries/
  identify-full/familiarity-carrer-log-only; allocation UX: steppers/
  draft/badge/deferral; appointment flow incl. fleet-panel captain rows;
  creation screen; retirement segment; appointed-voyage entries + HUD bar;
  character panel three tabs; hail modal + key list).
- **Gate (master)**: every changed number traceable to a doc; cross-doc
  references consistent; `validate_data.py` still exit 0; status stamp.
  **→ PASSED 2026-11-03** (see the W1 status line at the top of this file).
  Slot-flagged concretizations ratified at the gate: coaster cards carry no
  named skills (all 0, attributes per the `-low` template); treasure fleets
  commission `trader`-role canon cards of their nation at tier 2; officer
  "specialty coverage ≥ 10" reads as **each of the 11 skills carried at
  ≥ 20 by ≥ 10 officers**; captains.json is entity version 1 (new file),
  officers.json bumps to entity version 2; storm headway base loss 0.5 of
  the day's budget, courage-scaled ×`(1−(COU−10)/400)` (`20-*` §4.7);
  bounty-business pinpoint base 100g with the charisma multiplier then the
  rumour ≥ 40 half (`70-*` §4.5).

## W2 — Data & tools (4 slots, staged · merge A → B → C → D, gate once)

- **A** (`phase8-captains`) — owns `tools/build_captains.py`,
  `tools/captain_overrides.json`, `tools/officer_overrides.json`,
  `data/captain_name_parts.json`, `data/captains.json` (built),
  `data/officers.json` (v2 built), `data/named_pirates.json` (v2, `drop`
  preserved). Quota table derived from `60-*` §4.1.1 × presets; two
  consecutive builds byte-identical.
- **B** (`phase8-games-data`) — owns `data/skill_gates.json` (incl.
  `sail.autopilot`), `data/officer_posts.json` (incl. `advice` table),
  `data/backgrounds.json`, `data/nations.json`.
- **C** (`phase8-strings`) — owns `data/ui_strings.json` (all W1-inventoried
  families, both locales).
- **D** (`phase8-validator`, staged — starts naming/schema code on a branch
  off a master snapshot of A+B+C; finalizes post-merge) — owns
  `tools/validate_data.py` (new groups: canon quotas & uniqueness,
  officers v2 shape + specialty/captain quotas, gates/posts/backgrounds,
  pirate `drop` pin relocation, `npc_captains.json` absence) and deletes
  `data/npc_captains.json`.
- **Gate (master)**: validator exit 0; `build_captains.py --check`; canon
  counts cover the extreme preset; officer quotas met.
  **→ PASSED 2026-11-03** (see the W2 status line at the top of this file
  for the measured counts and the recorded deviations).

## W3 — Core model (4 slots · merge A → B → C → D)

- **A** (`phase8-character`) — owns `scripts/player/character.gd`,
  `scripts/player/skills.gd` (new), `autoload/game_state.gd` (new_game
  signature + v9 player-block shape only — save versioning itself is W6),
  `tools/test_character.gd` rework, new `tools/test_skills.gd`
  (boundaries 10/20/100, growth counters, training cap, officer
  contribution, allocation, `alloc_pending`).
- **B** (`phase8-sailing`) — owns `scripts/world/sailing_sim.gd` (CON trio,
  luck continuous, speed/sighting rewires, captain-less penalties hook
  points), shipyard/repair-fee engine touchpoints, re-baselined
  `test_movement` / sailing suites.
- **C** (`phase8-combat-core`) — owns `scripts/combat/battle_sim.gd` (duel
  values, gunnery, surrender line, captain-card `combat_rating` on both AI
  branches + escort officer-captain branch), re-baselined `test_duel` /
  `test_battle`.
- **D** (`phase8-trade-wiring`) — owns appraisal/negotiation consumers
  (trade engine tariff discount, price-memory entries, market arrows
  gates), re-baselined `test_trade` / `test_market_screen` formula rows.
- **Gate (master)**: `run_tests.py` green; speed/sighting/duel/storm match
  the doc formulas term-by-term; **vertical-slice headless check** (fresh
  boot, seeded days: attribute feel, speed delta, duel win-rate sanity,
  allocation value) — pass before W4/W5/W6 launch.
  **→ PASSED 2026-11-03** (see the W3 status line at the top; 42/42 suites,
  vertical slice PASS, zero SCRIPT ERROR).

## W4 — Roster & ecology (4 slots · merge A → B → C → D)

- **A** (`phase8-canon`) — owns `scripts/world/captains.gd` (canon read,
  state machine, tier drift, stance/nemesis), `captain_states` runtime
  block wiring.
- **B** (`phase8-npc-fleets`) — owns `scripts/world/npc_fleets.gd`
  (successor machinery + `named_pirate_respawns` deleted, card-driven
  spawn/return/speed ±10% cap/detection/engagement, name attribution).
- **C** (`phase8-battle-eco`) — owns `scripts/combat/battle_rewards.gd`
  (loot/XP per §2.3, capture officer gate + loot-convert fallback,
  nemesis variants), banner/boarding touches.
- **D** (`phase8-ecology-tests`) — owns ecology/lifecycle suites
  (return-queue day+60, tier drift, **name-never-reused**, seeded duel
  replay, cap arithmetic at 323), day-tick perf probe ≤ 75 ms.
- **Gate**: suites green; perf recorded vs Phase-7 baseline.

## W5 — Interactions (4 slots · merge A → B → C → D)

- **A** (`phase8-world-input`) — owns `scenes/world/world_map.gd/.tscn`
  input sections, `scripts/world/interactions.gd` (targeting/fleet
  attribution/verb dispatch), `scenes/world/fleet_picker.tscn`, intercept
  order + piracy-fame extension + **coaster not attackable** (pinned
  test).
- **B** (`phase8-hail`) — owns `scripts/world/hail_options.gd` (role ×
  stance × skill option builder; stance ≥+2 free intel, ≥+3 ×1.25 price),
  `scenes/world/hail_modal.tscn`; leaves the 2-line dispatch hookup to the
  master micro-ledger.
- **C** (`phase8-port-interact`) — owns tavern/market/inn/palace screens &
  row components: verb matrices, captain's table, sparring bets
  (100–1000g, seeded), inform-on-pirates, inn +1 familiarity.
- **D** (`phase8-autopilot`) — owns `scripts/world/autopilot.gd` +
  `scenes/world/chart_screen.gd/.tscn` + new `scenes/world/
  autopilot_hud.tscn`; ** A* extraction lands as a pure-move refactor
  before any weighted-cost change** (NPC pursuit determinism re-verified
  by existing suites between the two); `skill_gates` `sail.autopilot`
  wiring; HUD instancing to the master micro-ledger.
- **Gate**: interactions seeded-replayable; coaster test green; appointed
  voyage auto-cancels on contact but not on storm; ≥70-pilot weighted
  route measurably differs from the 40–69 straight route (same OD ≥ 15%
  faster or different wind-region crossings).

## W6 — UI & save (4 slots, W6-D staged · merge A → B → C → D)

- **A** (`phase8-card`) — owns `scenes/ui/character_card.tscn`,
  character-panel three tabs, dossier panel, all card entries,
  allocation flow (steppers/draft/badge-clear).
- **B** (`phase8-creation`) — owns `scenes/title/creation_screen.tscn`
  (two-step flow, derived preview, spread-evenly), retirement-screen RPG
  segment, `nationality_select` handoff.
- **C** (`phase8-save9`) — owns `autoload/save_system.gd`
  (`SAVE_VERSION = 9`, `PHASE = 9`, v8 refused), `autoload/game_state.gd`
  v9 keys (officer_states/captain_states persistence, counters),
  `tools/test_save_v8.gd` → `test_save_v9.gd` rework, round-trip incl.
  counters, file-size re-check (≤ 2 MB; ~50 KB increment expected).
- **D** (`phase8-i18n`, staged — branches off the post-A/B/C snapshot) —
  owns `data/ui_strings.json` residuals discovered by W6 code, parity
  report (key counts recorded in the acceptance record).
- **Gate**: demo-loop §7's ten steps on a fresh save; the same captain's
  card identical from every entry; `alloc_pending` round-trips and the
  badge clears; zh/en parity green; **mid-phase-saves-never-load** note
  re-stated.

## W7 — Balance & acceptance (master + ≤ 2 slots)

- **A** (`phase8-balance`) — `sim_trade.py` gates 1–10 (speed clamp;
  failing ⇒ cap falls back to **+0.25** and `20-*`/`50-*` are amended in
  the same wave), duel RNG re-baseline, storm gate re-verify, `20-*`
  §4.14 sampling.
- **B** (`phase8-acceptance`) — `tools/demo_probe_phase8.tscn` scenarios
  (appointment & prereqs, captain commissioning, capture-no-idle ⇒ loot
  convert, two-step creation, advice event, retirement segment, appointed
  voyage: gate gray + weights + auto-cancel, nemesis lifecycle), then the
  full gate run recorded in **`tools/demo_check_phase8.md`** (portal for
  "done": validator, rebuilds byte-identical, suites, probe ALL PASS,
  headless boot zero SCRIPT ERROR, day tick ≤ 75 ms @ 323, save size,
  parity count).
- **Master**: final merges, status stamps, `AGENTS.md` task-backlog line
  update (Phase 8 complete → acceptance record).

---

## Verification plan (whole-phase gates)

- `python3 tools/validate_data.py` exit 0 with the new groups.
- `python3 tools/build_captains.py --check` + the three existing rebuild
  tools byte-identical.
- `python3 tools/run_tests.py` green (baselines: 39 suites; new: skills /
  posts / roster / lifecycle / interactions / autopilot / save9; no
  Monte-Carlo re-derivations — contract pins only, per test discipline).
- `godot --headless --quit-after 3` zero SCRIPT ERROR.
- `tools/sim_trade.py` gates 1–10 PASS; `tools/demo_probe_phase8.tscn`
  ALL PASS; `tools/demo_check_phase8.md` fully recorded.
- ui_strings zh/en parity + placeholder match (count pinned in W7).

## Risks & fallbacks

| Risk | Handling |
|---|---|
| Speed clamp +0.30 breaks trade balance | sim gates are the guard; fallback cap +0.25 with same-wave doc amend |
| Legend officers (45–60) over-saturate formulas | sim/probe shows it ⇒ contribution ×0.8 fallback + doc amend |
| Cross-wave file hotspots (`sailing_sim.gd`, `battle_sim.gd`, `ui_strings.json`, `game_state.gd`) | resolved by the slot ownership matrices + held branches + master micro-ledger (see orchestration) |
| Weighted A* perf | reuses the NPC pursuit budget (measured ≤ 61 ms worst Phase-6/7); player recomputes once/day; fallback: 8-way wind-cost table |
| Quota miscount (extreme preset) | validator group forces coverage in W2, no runtime starvation |
| Concatenated-name quality | legend layer hand-authored; regulars only ever in short sightings/dossier text |
| A* extraction breaks pursuit determinism | pure-move refactor first; ecology suites re-run between the two changes (W5-D) |
| Scope size | enhancement layer (sea supply/intimidation/sparring/inform) droppable item-by-item; core layer never includes escorts/ransom |
| Save increment size | ~50 KB expected ≠ 2 MB cap; W6-C re-checks |

## Out of scope (Phase 8)

Hired escorts (a Phase-9 quest-framework candidate), release/ransom/
prisoners, informant networks, personality-friction events (beyond
loyalty raise/resign), manual skill-training facility networks, per-crew
rosters (one captain per escort; sailors stay aggregated).

**Phase-9 parking lot**: NPC captain → officer recruitment (stance ≥ +5),
titles/traits from deeds, officer personal quests at loyalty 100, a
player-side chronicle screen, and the Phase-7 economic leftovers
(warehouse consignment, contracts board, dividends, remote demand intel,
price ledgers, coasters as a ship class, salvageable coasters, cargo
jettison-at-sea refinement, fishing).
