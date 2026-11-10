# IMPLEMENT — Phase 12: Absolute tile layout for every screen

> Source plan: `.opencode` session plan `absolute-tile-layout.md` of
> 2026-11-09 (user-locked decisions §2 below). Predecessor: Phase 11
> (the studio layout editor — `docs/IMPLEMENT-Phase11.md`; its override
> machinery is largely REPLACED by this phase). Doc owners: `10-*`
> §4.23/§8.9 (v2), `90-*` §5.7 (amended protocol), `80-*` §4.8.9.

## 1. Goal

Remove container FLOW from UI layout entirely: every static element is
absolutely placed on the 32×32 chrome-tile grid, the element tree IS the
node tree, and `data/ui_layout.json` v2 IS the layout (no code defaults
underneath). Dynamic rows become computed stacking (`base + i·row_h`)
inside fixed tile viewports. The initial look is today's look — captured,
not redesigned. Every layout-bug class of the 2026-11-09 live studio
sessions (FILL stretch re-winning over mins, pairs re-flowing siblings
into vacated slots, per-frame sort cascades feeding stale rects to the
bridge, pre-layout baselines, flag pins) is deleted at the root.

## 2. Locked decisions (user, 2026-11-09)

1. **Data file = the layout** — `data/ui_layout.json` v2 holds every
   static element's rect; no code defaults underneath.
2. **All screens at once** — one campaign covers every screen (port,
   title, world, chart, combat, ui_shared).
3. **Computed stacking** for dynamic rows — row *i* at `base_y + i·row_h`
   inside a fixed tile viewport; scrolling allowed (viewport math, not
   flow).
4. **Keep today's look** — capture each screen's settled rects as the
   initial v2 tables; restyling happens AFTER, in the studio.

## 3. Waves & slots

Execution protocol (`AGENTS.md`): ≤ 4 background sub-agents per wave,
one worktree + branch each, master merges A → B → C → D with the
validator + suite gates after each merge (fragments assembled into the
single v2 file at each gate). W3 runs as a 5th slot in parallel with the
W2 waves (studio-side only, file-disjoint); W4 acceptance by master.
Push after every commit.

| Wave | Slot | Deliverable | Done-when |
|---|---|---|---|
| W0 | master | Doc amendments: `10-*` §4.23 + §8.9 + the §8 exit row (v2), `90-*` §5.7 (protocol amendment) + §4 tree lines, `80-*` §4.8.9 (rewrite), this file | every cross-citation resolves; the v2 data spec and the amended protocol are normative |
| W1 | master | Registry v2 (`apply_layout`, `list_rect`, coverage check, the Phase-11 deletions), bridge settle 4→1 frame + tolerated v1 messages, DataLoader v2 shape check, validator group 14 v2 (+ `--self-test-g14`), `tools/layout_capture.gd` + the port-screen capture tables in `data/ui_layout.json`, re-pinned registry/bounds/bridge suites | validator exits 0 on the populated file, rejects each §8.9 rule; port screens apply their captured rects; suites green |
| W2 | A | port ×8: delete the flow containers, apply data rects, emit capture fragments | every port-screen element nests in its registered parent; zero flow containers under registered elements; suites re-pinned to the v2 file |
| W2 | B | title, nationality_select, creation: id pass + restructure + fragments | same per screen |
| W2 | C | world HUD, chart, hail, fleet_picker, autopilot_hud | same per screen |
| W2 | D | battle, sandbox, duel + ui_shared: confirm, save_slot, settings, intel_window, dialog_box, dossier, character_card, captain_view, fleet_view, officer_roster, reputation_view, gameover(+host), ending | same per screen |
| W3 | E | Studio Layout tab v2 (rect drag/resize for everything, lists as locked viewport blocks, commit writes v2 behind the validator gate) | drag/resize/commit/restart loop applies; revert restores the data rect; the deleted v1 paths are gone from the studio |
| W4 | master | Acceptance | the §5 block below, filled |

## 4. Tasks per slot (pointers, not re-specs)

The normative specs live in the docs; this section only names the
inventories:

- **W1 (master):** `scripts/ui/layout_registry.gd`,
  `autoload/layout_bridge.gd`, `autoload/data_loader.gd`,
  `data/ui_layout.json` (v2, port screens populated),
  `tools/validate_data.py` (`check_group14` v2 + the self-test),
  `tools/layout_capture.gd` + `.tscn` (new — the generalized
  `nest_audit`), `tools/test_layout_registry.gd`,
  `tools/test_layout_bounds.gd`, `tools/test_layout_bridge.gd`.
- **W2-A:** `scenes/port/{port_screen, market_screen, provisions_dialog,
  shipyard_screen, inn_screen, guild_screen, palace_screen,
  tavern_screen}.gd` (+ `.tscn`) — the registered-parent restructure,
  list blocks for the dynamic sections, capture fragments under
  `data/layout_fragments/`.
- **W2-B:** `scenes/title/{title_screen, nationality_select,
  creation_screen}`.
- **W2-C:** `scenes/ui_shared/hud.gd` (world HUD), `scenes/world/
  {chart_screen, hail_modal, fleet_picker, autopilot_hud}`.
- **W2-D:** `scenes/combat/{battle_screen, battle_sandbox, duel_modal}`,
  `scenes/ui_shared/{confirm_dialog, save_slot_dialog, settings_panel,
  intel_window, dialog_box, dossier_panel, character_card (scenes/ui/),
  captain_view, fleet_view, officer_roster_view, reputation_view,
  gameover_screen + game_over_host, ending_screen}`.
- **W3-E:** `tools/model_studio/www/` (the Layout tab's canvas,
  inspector, tree), `tools/model_studio/server.py` (commit
  serialization → v2), `tools/model_studio/README.md`.

Fragments: each W2 agent writes its screens' v2 tables as per-screen
fragment files (`data/layout_fragments/<screen>.json`) and the master
assembles them into the single `data/ui_layout.json` at each merge gate
(one shared file ⇒ agents never edit it concurrently).

## 5. Acceptance criteria (filled at W4)

- [x] `python3 tools/validate_data.py` exit 0 (groups 1–14, v2 rules) on
      the shipped populated file; negative probes per rule
      (`--self-test-g14`, 18/18 cases).
- [x] Full suite sweep green — **66/66, 380 s, zombie/hang 0** (the
      quiet-machine W4 run; every re-pinned suite named in the status
      log's merge records).
- [x] `nest_audit` extended to ALL screens — the capture tool's
      `--audit` mode: **32/32 screens OK** (every registered-child →
      registered-parent chain walks only registered/plain Controls; no
      Container subclass except the clipped ScrollContainer viewports;
      0 nest violations — clipped list members exempted per the
      containment guard's convention).
- [x] Both locales fit (the zh/en legs of the bounds suite, the chart's
      locale-rebind section, test_ui_window_sizes, and the per-screen
      locale suites — all green against the v2 file).
- [x] Live studio loop: the W3-E probe transcript (valid v2 commit
      writes canonical bytes behind the validator gate; an invalid
      commit is refused with the file byte-unchanged; the v1-shape
      pre-gate fails fast) + the merged-tree endpoint spot-check; the
      deleted flow paths verified gone from the code (one docstring
      mention of their deletion is the only hit).
- [x] `build_ui_art`/`build_shore` rebuilds byte-identical (validator
      group 13, green in every gate run); save format, EventBus,
      `SAVE_VERSION` 9 untouched.
- [x] Capture determinism: `--all` twice ⇒ byte-identical 32/32;
      `assemble_layout --check` canonical against the shipped file.

## 5a. W4 findings worth the record

- **The capture ⇔ file fixpoint**: the first all-screens capture on the
  managed tree drifted 32 rows (content-min floors applied — heights
  grew a tile where fonts demanded) and exposed one INERT row
  (`chart.debug_panel` — the panel renders authored; its stale file row
  never applied). One assemble → re-capture iteration reached the
  fixpoint; the double-capture protocol then ran on the SHIPPED file.
- **The O(n³) apply**: the per-element ancestor walk blew the chart's
  §4.6 500 ms open budget at 1848 ms once the chart was managed —
  fixed by the per-pass `_parent_map` memoization (1848 → 41 ms,
  45×); behavior identical, audit + captures stable.
- **The battle-bar clamp**: the parent-bounds clamp bounds quantized UP
  to whole tiles (the §4.23 canvas-sliver row is in bounds — a raw
  1080-px clamp pulled the §4.7.1 bar up 8 px).
- **Visual notes for user review** (the locked "keep today's look" has
  three known, recorded deltas, all restudio-able): the market/inn/
  guild/palace/tavern lower bands re-flowed onto the canvas (the old
  flow overflowed 34 tiles); the hail portrait bust quantized 72×96 →
  48×64 (aspect kept, 2-tile row rhythm); fixed plates replace the
  content-hugging dialogs (confirm/dialog_box/duel/gameover) whose
  bodies now scroll in their viewports.

## 6. Status log

- **W0 (2026-11-09): ✅ complete** — master direct. `10-*` §4.23
  rewritten to the v2 absolute-rect spec (populated tables, `elements`
  + `lists`, the 32-screen set, serialization byte rules), §8.9 to the
  v2 normative validator spec, the §8 exit row amended; `90-*` §5.7
  protocol amended (edits carry `{x,y,w,h}` + `sheet` only;
  `min_w/min_h/order/anchor` retired; v1 messages tolerated until W3;
  1-frame deferred reply), §4 tree lines updated; `80-*` §4.8.9
  rewritten (the absolute model, the two kept rules, the deletions);
  this file created from the locked plan.
- **W1 (2026-11-09): ✅ complete** — master direct. The registry v2
  (`apply_layout` parents-first rect walk with the content-min +
  children-extent floors and the parent clamp; `list_rect` content-
  space rows; the coverage fallback (0,0,2,2) + push_error; rect edits
  `{x,y,w,h}` + `sheet` with retired-key rejection; revert = the data
  rect, with `applied` vs `data_rect` tracked separately so
  move→resize composes; `capture_rows` for the tool; the Phase-11
  machinery deleted — break-out, flow_parent/flow_bounds, the co-flow
  freeze, flag pins, the anchored kind, the 4-frame settle), the
  bridge (settle 1 frame, hello 60×34, `reorder`/retired fields
  answered `retired_field` without effect), the DataLoader v2 shape
  check, `check_group14` v2 + the self-test (18 cases),
  `tools/layout_capture.gd` + the 8 port rigs (double capture
  byte-identical 8/8), `tools/assemble_layout.py` (`--only` scopes
  each merge gate to the converted screens), the v2 interim
  `data/ui_layout.json`. A bounds-rule discovery: `y + h ≤ 34` (the
  33.75 canvas rounds up; a full-height element's 1080 px measures
  34 tiles — the plan's own 60×34 example; the doc owns the
  resolution). One registry fix found by the bridge suite: `%`
  operator precedence in the retired-key error string. Gates:
  validator exit 0 (1–14); test_layout_registry 52, test_layout_bridge
  33, test_layout_bounds 5 ALL PASS; market/port_hub/shipyard/inn/
  tavern/palace/quests + the UI sweep green.
- **W2+W3 launched (2026-11-09)** — five background slots, one
  worktree + branch each off the W1 commit: A `phase12-port-a` (the
  port eight), B `phase12-title-b` (title/nationality_select/
  creation), C `phase12-world-c` (world HUD/chart/hail/fleet_picker/
  autopilot_hud), D `phase12-combat-d` (battle/sandbox/duel + the 13
  ui_shared screens), E `phase12-studio-e` (the Layout tab v2,
  file-disjoint). Merge order A → B → C → D with the validator +
  suite gates after each merge (fragments assembled via
  `tools/assemble_layout.py --only <converted screens>`); E merges
  after its W2 neighbors.
- **W2-C merged (2026-11-10): ✅** — world 25 / chart 134+1 / hail
  16+1 / fleet_picker 20+1 / autopilot_hud 3. Master micro-
  integration: `LayoutRegistry.is_managed()` (the HUD's private
  `_screen_data` read-in re-pointed). The registry suite's data-seam
  pin evolved to the v2 shape (the file grows per merge gate).
  Gates: sailing/world_map/hail/autopilot/arrival_jump/bridge/bounds/
  registry ALL PASS. PENDING-QUIET: the chart §4.6 500 ms pin
  measured 1918 ms under load 4.0 (two agents' suites concurrently);
  C's quiet-branch run passed.
- **W2-D merged (2026-11-10): ✅** — 15 of 16 ids landed (confirm/
  dialog_box/save_slot/settings/gameover/ending/duel/intel_window/
  reputation_view/captain_view/battle full; sandbox/dossier/
  fleet_view/officer_roster partial with flow INSIDE registered
  containers; character_card not landed). Two master fixes at the
  gate: the parent-bounds clamp quantizes UP to whole tiles (the
  §4.7.1 battle bar sits at row 31 with the blessed 8 px sliver —
  the raw-1080 clamp pulled it up), and the `%`-precedence +
  `set_table_for_tests({})`-means-unmanaged seam fixes. Cross-slot
  integration (the shared-modal reach-ins the slots could not own):
  port_screen officers_panel/fleet_panel, palace commend
  trophy/OK, hud mutiny Confirm/Cancel re-pointed at D's restructured
  trees. battle 231 / duel 150 / intel 65→57 / save 224+493 /
  ui_window_sizes 31 ALL PASS.
- **W2-A merged (2026-11-10): ✅** — the port eight: 224 element rows
  + 12 list blocks (the §4.8.1 facility grid stays statics two per
  row); row internals unregistered (locked viewport blocks). Gates:
  port_hub 314 / market 270 / shipyard 274 / inn / tavern / palace /
  quests / registry / bounds / bridge ALL PASS.
- **W2-B merged (2026-11-10): ✅** — title 10 / nationality_select 37
  / creation 103 (no list blocks — fixed data orders are absolute
  elements). The trio's fragments re-captured on the MANAGED tree
  (the applied content-min floors are what ships) — double capture
  byte-identical. B also fixed the pre-existing test_ui_theme
  backdrop-spec gap (79→151 checks). Gates: creation / demo_loop /
  ui_theme ALL PASS.
- **W3-E merged (2026-11-10): ✅** — the studio Layout tab speaks v2
  (one drag/resize path, list blocks locked, retired fields gone,
  the commit gate intact); merged-tree probe: the file endpoint
  serves the 31-screen v2 doc, an invalid commit is refused with the
  file byte-unchanged.
- **Campaign state after the five merges**: 31 screens managed, 787
  element rows + 21 list blocks shipped in `data/ui_layout.json`;
  validator exit 0. D2 (the finish-up slot) launched for the W2-D
  debt: sandbox/dossier/fleet_view/officer_roster interiors +
  character_card.
- **D2 merged (2026-11-10): ✅** — the W2-D debt cleared:
  sandbox/dossier/fleet_view/officer_roster interiors flattened;
  character_card landed whole (39 elements + attributes/skills lists,
  one rect set across the player/officer/NPC variants — **32/32
  screens managed**). D2 also caught test_fleet's fleet-view section
  silently crashing since the partial (103 → 185 checks). Gates:
  battle_sandbox 155 / character_card 141 / fleet 185 / intel_window
  65 ALL PASS; D2's structural probe 98 records, 0 flow containers.
- **Post-acceptance fix (2026-11-10, user-reported — the 10:00 layout
  snap):** an hour-crossing rebuilt the §4.8.1 facility cards at the
  AUTHORED CARD_SLOTS — the §4.8.1 rebuild signature includes each
  card's open state, and port_screen was the only port screen whose
  rebuild path never called `apply_layout`, so the user's committed
  studio layout was lost the moment a facility opened (tavern 10:00,
  palace 09:00). The rebuild now re-applies the committed layout after
  re-registering the cards. test_port_hub gained the regression pin
  (a fixture rect survives an 08:00→12:00 crossing) and the §4.8.1
  grid pin now derives its expectation from the committed `cards.*`
  rows — the file is the pin, so a user restyle passes iff the build
  honors it.
- **Post-acceptance fix (2026-11-10, user-reported — the empty-port
  coverage errors):** the facility screens' conditionally-BUILT empty
  markers (`market captains.empty`, `inn captains.rows.empty`,
  `palace board.rows.empty`, `tavern captains_table.empty`) carried no
  rect rows — the seeded capture rigs always had sightings, so the
  coverage check fired the (0,0,2,2) fallback on every real
  empty-port boot. Each marker is now its owning list's MEMBER placed
  at the block's row 0. The static-id cross-check sweep then found
  five more of the class (tavern `officers.recruitable.empty`,
  `rumors.rows.invest_header`, the fleet_picker dock/appoint buttons,
  `spar.result`) — all closed; `spar.result` became the guild's
  persistent-label pattern with its row authored from
  `SPAR_RESULT_RECT` (the capture fixpoint holds). New permanent
  suite `test_layout_empty_states` (12 checks: zero-sightings boots,
  membership + row-0 placement pins); the sweep reports 0
  unaccounted ids. Gates: tavern/market/inn/palace/hail/fleet + the
  layout quartet + the audit 32/32 + assemble --check + validator
  ALL PASS.
- **W4 acceptance (2026-11-10): ✅** — the §5 block above, all boxes
  checked. The record's highlights: the structural audit lives in the
  capture tool (`--audit`, 32/32 OK); the capture ⇔ file fixpoint
  ran to byte-stability (the first managed capture drifted 32 rows —
  content-min floors + one inert `chart.debug_panel` row found and
  resolved); the double capture byte-identical 32/32 on the SHIPPED
  file; and the quiet-machine sweep caught the managed chart's O(n³)
  apply (1848 ms open) — fixed by the `_parent_map` memoization
  (41 ms). Final state: **66/66 suites green (380 s, zombie/hang 0);
  validator exit 0 (1–14); 32 screens / 825 element rows + 21 list
  blocks shipped; the studio writes the v2 file behind the validator
  gate.** Phase 12 complete.
