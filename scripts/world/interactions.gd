class_name Interactions
extends RefCounted
## Phase-8 W5-A at-sea interaction layer (docs/60-COMBAT.md §4.11.15;
## docs/80-UI-UX.md §4.10; docs/90-ARCHITECTURE.md §4: pure statics, no node
## references) — the right-click interaction layer's brain, in the style of
## `scripts/player/skills.gd`.
##
## Owns the *pure* half of every §4.10 surface: targeting (which fleet holds
## a tile), attribution (the verbs a fleet offers, the coaster pin), the
## intercept order's arithmetic (set shape, cancel evaluation), the encounter
## dict the existing §4.11.11.2 funnel opens, the inspect summary line and
## the appointed-voyage gate read. The world scene
## (`scenes/world/world_map.gd`) owns every side effect — the picker modal,
## the sail route an intercept rides, the battle handoff, the toasts — this
## module only computes and never mutates GameState.
##
## Deterministic: pure functions of GameState and the loaded data, no RNG
## (docs/60-* §4.11.15's interaction layer is seeded-replayable by
## construction).

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
## The pilot-post read for the `sail.autopilot` gate (20-* §4.19). One-way
## preload — `skills.gd` never loads this file back.
const SkillsLib := preload("res://scripts/player/skills.gd")

## The §4.10.1 verbs, in row order. A `coaster`-role fleet offers no attack
## verb (intimidate-only — the §4.1.1 coaster row is the more specific pin;
## [method verbs_for] is the single place the rule lives).
const VERB_INSPECT := "inspect"
const VERB_TALK := "talk"
const VERB_ATTACK := "attack"

## §4.11.15: the hail (the talk verb) opens at Chebyshev ≤ 2.
const HAIL_RANGE := 2

## The one auto-cancel reason an intercept order can carry (§4.11.15: the
## order cancels when the target leaves the sighting radius — a target that
## is gone from the world entirely reads the same way: nothing is left in
## sight to chase).
const CANCEL_LEFT_SIGHTING := "left_sighting"

## The appointed-voyage gate row (`data/skill_gates.json` feature_id,
## 20-* §4.19): a pilot in post with navigation ≥ the row threshold, and the
## destination ∈ `known_ports`.
const AUTOPILOT_GATE_ID := "sail.autopilot"
## Doc-pinned threshold fallback (20-* §4.19 "navigation ≥ 40") used only if
## the data row is missing — the JSON row is the source of truth (50-*
## §4.3.5: thresholds live in the data, never in code), this constant keeps a
## broken data file from crashing the menu.
const AUTOPILOT_NAV_FALLBACK := 40


# --- Targeting (docs/80-* §4.10.1 hit rules) ---------------------------------

## Every live fleet standing exactly on `cell`, sorted by id ascending —
## the deterministic pick list behind a multi-fleet tile (§4.10.1 "a
## multi-fleet tile picks its target first"). Reads `GameState.npc_fleets`
## through a throwaway [NpcFleets] index per query (the `npc_intel.gd`
## pattern: a fresh instance builds its bucket index from the live array, so
## a save loaded into the process can never be answered from a stale index).
## The exact-tile match is wrap-aware on x (a query at x = 4320 is a query
## at x = 0, `20-*` §4.1).
static func fleets_at(cell: Vector2i) -> Array:
	var sim := NpcFleetsLib.new()
	var out: Array = sim._within(cell, 0)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str((a as Dictionary).get("id", "")) \
			< str((b as Dictionary).get("id", "")))
	return out


## The NPC fleet at `cell` — the first of [method fleets_at] by id ({} when
## the tile holds none). The same exact-tile, wrap-aware match the retired
## right-click attack used (`NpcFleets.fleet_at`).
static func target_at(cell: Vector2i) -> Dictionary:
	var fleets := fleets_at(cell)
	return fleets[0] if not fleets.is_empty() else {}


## A live fleet dict by id ({} when gone — removed by a battle, an
## auto-resolve or a budget shrink). Linear read of the save block; the
## intercept tick calls this once per player step.
static func fleet_by_id(fleet_id: String) -> Dictionary:
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary \
				and str((fleet as Dictionary).get("id", "")) == fleet_id:
			return fleet
	return {}


# --- Range & verbs (docs/80-* §4.10.1, docs/60-* §4.11.15) -------------------

## True when `fleet` stands within `radius` tiles of the player's fleet
## (Chebyshev, wrap-aware on x). `radius < 0` means the sighting radius
## `48 + floor(effective navigation / 12)` (20-* §4.11) — the §4.10.1 hit
## rule "right-click inside sighting radius".
static func in_range(fleet: Dictionary, radius: int = -1) -> bool:
	if fleet.is_empty():
		return false
	var limit := radius
	if limit < 0:
		limit = SailingSimLib.sighting_radius()
	return NpcFleetsLib.chebyshev(GameState.world_tile(),
		NpcFleetsLib.position_of(fleet)) <= limit


## True when `fleet` is close enough to hail (§4.11.15: Chebyshev ≤ 2) —
## the talk verb's gate; beyond it the picker grays the row with
## `interact.talk.too_far` (80-* §4.10.1).
static func hail_in_range(fleet: Dictionary) -> bool:
	if fleet.is_empty():
		return false
	return NpcFleetsLib.chebyshev(GameState.world_tile(),
		NpcFleetsLib.position_of(fleet)) <= HAIL_RANGE


## The verbs `fleet` offers the picker, in row order: inspect / talk / attack.
## **A `coaster`-role fleet offers no attack verb** (§4.1.1's more specific
## pin, restated by §4.11.15 and 80-* §4.10.1: intimidate-only — talk still
## opens the hail, where intimidate lives). The fleet picker renders exactly
## this list, so the surface and the rule cannot drift apart.
static func verbs_for(fleet: Dictionary) -> Array[String]:
	var verbs: Array[String] = [VERB_INSPECT, VERB_TALK]
	if str(fleet.get("role", "")) != NpcFleetsLib.COASTER:
		verbs.append(VERB_ATTACK)
	return verbs


# --- Intercept order (docs/60-* §4.11.15) ------------------------------------
#
# "The attack verb on a fleet beyond contact range issues a click-to-sail
# movement order onto the target; the §4.11.11.2 contact pipeline opens the
# battle on arrival. The order auto-cancels when the target leaves sighting
# radius." The order itself lives in the world scene (it rides the existing
# click-to-sail path); these two statics pin its shape and its cancel rule.

## The intercept order against `fleet`: the target's id and its cell **at
## set time**. The world scene issues the movement through the existing
## click-to-sail path ([method sail_to] onto this cell) and re-targets the
## order on every contact-check tick while the target is alive — the cell
## here is where the chase starts, never a persistent destination.
static func intercept(fleet: Dictionary) -> Dictionary:
	var cell := NpcFleetsLib.position_of(fleet)
	return {
		"target_id": str(fleet.get("id", "")),
		"target_cell": cell,
	}


## The cancel evaluation the world scene runs on every contact-check tick
## while an order is active: `""` while valid —
## [constant CANCEL_LEFT_SIGHTING] when the target's Chebyshev distance from
## the intercepting fleet's current position exceeds the sighting radius
## (auto-cancel + the `interact.intercept.cancelled` line, §4.11.15), `""`
## never otherwise. A target that no longer exists in `GameState.npc_fleets`
## answers [constant CANCEL_LEFT_SIGHTING] too: nothing is left in sight to
## chase, which is the same reason with the same handling.
static func intercept_cancel_reason(order: Dictionary) -> String:
	if order.is_empty():
		return ""
	var fleet := fleet_by_id(str(order.get("target_id", "")))
	if fleet.is_empty():
		return CANCEL_LEFT_SIGHTING
	if NpcFleetsLib.chebyshev(GameState.world_tile(),
			NpcFleetsLib.position_of(fleet)) \
			> SailingSimLib.sighting_radius():
		return CANCEL_LEFT_SIGHTING
	return ""


# --- The attack funnel's encounter dict (docs/60-* §4.11.11.2/§4.11.11.3) ----

## The S10 encounter dict for a player attack on `fleet` — the exact shape
## the world scene's contact funnel queues ([method _open_encounter] side:
## piracy + the double-contact guard stay single-funnel; the dict only
## carries the data). The fleet's saved fields ride unchanged plus:
## `kind` = the §4.11.11.3 mapping (a `hunter` keeps the navy kind, every
## other role its role id), `encounter_id` = the fleet id, `ships` = the
## fleet's own seeded composition (a fleet-carried `ships` override — a
## fixture/K seam — is honored verbatim), and `contact` = the player's
## current tile (where the battle returns the fleet, §4.11.11.3).
static func attack_encounter(fleet: Dictionary) -> Dictionary:
	var encounter := fleet.duplicate(true)
	encounter["kind"] = NpcFleetsLib.composition_kind(
		str(fleet.get("role", "")))
	encounter["encounter_id"] = str(fleet.get("id", ""))
	if (fleet.get("ships", []) as Array).is_empty():
		# §4.11.11.2: the battle draws from the fleet's own seeded stream.
		encounter["ships"] = NpcFleetsLib.compose_fleet_ships(
			fleet, int(GameState.day))
	encounter["contact"] = {
		"x": GameState.world_tile().x, "y": GameState.world_tile().y,
	}
	return encounter


# --- Inspect (docs/80-* §4.10.1; the unified card is W6's) -------------------

## The inspect verb's summary text until W6's unified character card lands
## (`80-*` §4.12.1): name / role / tier / level plus the relation block
## (stance) and familiarity, composed from the existing ui_strings keys —
## `dossier.title`, `captain.role.*`, `dossier.header.tier`, `char.level`,
## `char.card.relations`, `dossier.familiarity`. An unidentified fleet (no
## canon captain card) shows the `interact.unknown_name` line and only what
## the fleet itself knows. Deterministic: the same fleet always renders the
## same card (the §2.6 acceptance pin's W5 half).
static func inspect_summary(fleet: Dictionary) -> String:
	var name := display_name(fleet)
	var lines: Array[String] = [I18n.fmt("dossier.title", {"name": name})]
	var detail: Array[String] = [I18n.t_key("captain.role.%s"
		% str(fleet.get("role", "")))]
	var tier := NpcFleetsLib.captain_tier_of(fleet)
	var card := NpcFleetsLib.captain_card_of(fleet)
	if tier > 0:
		detail.append(I18n.fmt("dossier.header.tier", {"tier": tier}))
	if not card.is_empty():
		detail.append(I18n.fmt("char.level",
			{"level": int(card.get("level", 1))}))
	lines.append(" · ".join(detail))
	var captain_id := str(fleet.get("captain_id", ""))
	if not captain_id.is_empty():
		var state := CaptainsLib.state(captain_id)
		lines.append("%s: %d" % [I18n.t_key("char.card.relations"),
			int(state.get("stance", 0))])
		lines.append("%s: %d" % [I18n.t_key("dossier.familiarity"),
			int(state.get("familiarity", 0))])
	return "\n".join(lines)


## The row/summary name for `fleet`: the canon captain's name when the
## captain is known (every Phase-8 captain carries a canon card — the row
## shows it, 80-* §4.10.1), else the `interact.unknown_name` fallback line.
static func display_name(fleet: Dictionary) -> String:
	var name := NpcFleetsLib.captain_name(fleet)
	return name if not name.is_empty() else I18n.t_key("interact.unknown_name")


# --- The appointed-voyage gate (docs/20-* §4.19, docs/80-* §4.10.3) ----------

## The `sail.autopilot` gate for appointing a voyage to `port_id`:
## `{ok: bool, reason: String}` — ok when a pilot officer is in post with
## navigation ≥ the data row's threshold **and** the destination is a known
## port. The reason is the row's own localized `reason` (50-* §4.3.5: the
## reasons live in the JSON), empty when ok. The actual appointment is the
## autopilot module's (W5-D); this read is what grays the port-context row.
static func appoint_gate(port_id: String) -> Dictionary:
	var gate: Dictionary = DataLoader.get_skill_gate(AUTOPILOT_GATE_ID)
	var threshold := int(gate.get("threshold", AUTOPILOT_NAV_FALLBACK))
	var pilot_id := SkillsLib.post_holder("pilot")
	var navigation := 0
	if not pilot_id.is_empty():
		navigation = int(DataLoader.get_officer(pilot_id)
			.get("skills", {}).get("navigation", 0))
	var known: bool = port_id in (GameState.known_ports as Array)
	if pilot_id.is_empty() or navigation < threshold or not known:
		return {"ok": false,
			"reason": I18n.t(gate.get("reason", {}))}
	return {"ok": true, "reason": ""}
