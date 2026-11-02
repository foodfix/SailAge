extends Node
## Phase-8 W4-A captains-canon module contract tests
## (docs/60-COMBAT.md §4.11.15 + §4.11.11.4; docs/10-DATA-SCHEMA.md §4.11/
## §4.15; docs/90-* §13 contract: headless, exit 0, `ALL PASS (N checks)`).
##
##   godot --headless res://tools/test_captains.tscn
##
## Exits 0 when every check passes, 1 otherwise. Deterministic contract
## pins only — the state machine, tier drift, stance/nemesis, familiarity
## tiers, deployment bookkeeping and speed-jitter stability. No RNG
## sweeps, no scene boots beyond this one. (The broader ecology/lifecycle
## suites are W4-D's; this suite pins the MODULE contract W4-B/W4-C code
## against.)

const CaptainsLib := preload("res://scripts/world/captains.gd")

## A stable hand-authored canon card (the legend layer ids never move —
## `tools/captain_overrides.json`): a tier-1 pirate.
const PIRATE_ID := "pirate_edward_bloodhand"

## The §4.15 save shape — a met captain's entry carries exactly these keys
## (the module's `deployed` bookkeeping flag is runtime-only and must be
## absent from an idle entry).
const SAVE_SHAPE_KEYS := ["status", "return_day", "tier_now", "stance",
	"familiarity", "dossier_seen", "defeats", "wins"]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_canon_access()
	_test_lazy_state_creation()
	_test_return_queue_machine()
	_test_tier_drift()
	_test_stance_deltas_and_clamps()
	_test_nemesis_predicate()
	_test_familiarity_tiers()
	_test_deployment_exclusivity()
	_test_dossier_flag()
	_test_speed_jitter()
	_report()


# --- Fixtures -----------------------------------------------------------------

func _reset() -> void:
	GameState.captain_states = {}


## The first canon card of `role` at exactly `tier` (a data-driven fixture —
## generated ids are builder-owned; the suite pins behavior, not ids).
func _find_card(role: String, tier: int) -> String:
	for card in CaptainsLib.canon_list():
		if str((card as Dictionary).get("role", "")) == role \
				and int((card as Dictionary).get("tier", 0)) == tier:
			return str((card as Dictionary).get("id", ""))
	return ""


# --- 1. Canon access (docs/10-* §4.11) ----------------------------------------

func _test_canon_access() -> void:
	_reset()
	_check(not CaptainsLib.canon_list().is_empty(),
		"canon_list() is non-empty (the closed roster loaded)")
	var pirate: Dictionary = CaptainsLib.captain(PIRATE_ID)
	_check(str(pirate.get("role", "")) == "pirate" and int(pirate.get("tier", 0)) == 1,
		"captain('%s') reads the legend pirate card (role pirate, tier 1)"
		% PIRATE_ID)
	_check(CaptainsLib.captain("cap_nobody").is_empty(),
		"an unknown captain id resolves {}")
	_check(_find_card("privateer", 3) != ""
		and _find_card("trader", 2) != "",
		"fixtures exist: a privateer at tier 3 and a trader at tier 2")


# --- 2. Lazy state creation (docs/90-* §5.4: full entries only for met) -------

func _test_lazy_state_creation() -> void:
	_reset()
	var st: Dictionary = CaptainsLib.state(PIRATE_ID)
	_check(not GameState.captain_states.has(PIRATE_ID),
		"reading an unmet captain creates NO state entry")
	_check(st.keys().size() == SAVE_SHAPE_KEYS.size()
		and str(st["status"]) == "active" and int(st["return_day"]) == 0
		and int(st["tier_now"]) == 1 and int(st["stance"]) == 0
		and int(st["familiarity"]) == 0 and not bool(st["dossier_seen"])
		and int(st["defeats"]) == 0 and int(st["wins"]) == 0
		and not st.has("deployed"),
		"an unmet captain reads the §4.15 defaults (tier_now = canon tier, no deployed key)")
	st["stance"] = 99
	_check(CaptainsLib.state(PIRATE_ID)["stance"] == 0,
		"mutating an unmet captain's default view corrupts nothing")

	CaptainsLib.ensure(PIRATE_ID)
	_check(GameState.captain_states.has(PIRATE_ID),
		"ensure() creates the entry (first touch)")
	CaptainsLib.ensure(PIRATE_ID)["wins"] = 2
	_check(int(CaptainsLib.ensure(PIRATE_ID)["wins"]) == 2,
		"ensure() is idempotent (no reset on re-ensure)")

	# An unknown id still reads safe defaults (tier_now floor 1).
	_check(int(CaptainsLib.state("cap_nobody")["tier_now"]) == 1,
		"an unknown id defaults tier_now to the tier floor 1")


# --- 3. The return-queue machine (docs/60-* §4.11.15) --------------------------

func _test_return_queue_machine() -> void:
	_reset()
	# Deploy first: the defeat must clear the deployment (the fleet is gone).
	CaptainsLib.deploy(PIRATE_ID)
	var st: Dictionary = CaptainsLib.defeat(PIRATE_ID, 100)
	_check(str(st["status"]) == "returning" and int(st["return_day"]) == 160,
		"defeat(id, 100) books returning with return_day day + 60 = 160")
	_check(int(st["defeats"]) == 1 and not CaptainsLib.is_deployed(PIRATE_ID),
		"defeat climbs the defeats counter and clears the deployment")
	_check(not CaptainsLib.is_spawnable(PIRATE_ID, 120),
		"a returning captain is not spawnable")

	CaptainsLib.day_tick(159)
	_check(str(CaptainsLib.state(PIRATE_ID)["status"]) == "returning",
		"day_tick(159) keeps the captain in the queue (159 < 160)")
	CaptainsLib.day_tick(160)
	_check(str(CaptainsLib.state(PIRATE_ID)["status"]) == "active"
		and int(CaptainsLib.state(PIRATE_ID)["return_day"]) == 0,
		"day_tick(160) walks the captain back to active (return_day reset)")
	_check(CaptainsLib.is_spawnable(PIRATE_ID, 160),
		"a returned captain is spawnable again")


# --- 4. Tier drift (docs/60-* §4.11.15: −1 crushed / +1 win, clamp 1–3) -------

func _test_tier_drift() -> void:
	_reset()
	# Drift down: the pirate card is tier 1 — a crushed defeat clamps at 1.
	CaptainsLib.defeat(PIRATE_ID, 10, true)
	_check(int(CaptainsLib.state(PIRATE_ID)["tier_now"]) == 1,
		"a crushed defeat drifts −1 and clamps at the floor 1 (tier 1 card)")

	# Drift up: a tier-2 card wins twice → 3, then clamps at 3.
	var tier2 := _find_card("privateer", 2)
	CaptainsLib.win(tier2, 10)
	_check(int(CaptainsLib.state(tier2)["tier_now"]) == 3,
		"a captain win drifts +1 (tier 2 → 3)")
	_check(int(CaptainsLib.state(tier2)["wins"]) == 1, "win() climbs the wins counter")
	CaptainsLib.win(tier2, 11)
	_check(int(CaptainsLib.state(tier2)["tier_now"]) == 3,
		"the +1 drift clamps at the ceiling 3")

	# A non-crushed defeat drifts nothing; the drifted tier survives the queue.
	var tier3 := _find_card("privateer", 3)
	CaptainsLib.defeat(tier3, 10, false)
	_check(int(CaptainsLib.state(tier3)["tier_now"]) == 3,
		"a non-crushed defeat drifts no tier")
	CaptainsLib.day_tick(70)
	_check(int(CaptainsLib.state(tier3)["tier_now"]) == 3,
		"the drifted tier keeps its value through the return queue")


# --- 5. Stance deltas and clamps (docs/50-* §4.6; the shared constants) -------

func _test_stance_deltas_and_clamps() -> void:
	_reset()
	_check(CaptainsLib.STANCE_BEFRIEND == 1
		and CaptainsLib.STANCE_INTIMIDATE_WIN == -1
		and CaptainsLib.STANCE_INTIMIDATE_FAIL == -2
		and CaptainsLib.STANCE_NEMESIS_DEFEAT == -2
		and CaptainsLib.STANCE_ATTACK_NONHOSTILE == -1,
		"the five shared STANCE_* deltas are pinned (W5 hail + W4-C hooks)")
	_check(CaptainsLib.stance(PIRATE_ID) == 0, "a fresh stance reads 0")
	_check(CaptainsLib.adjust_stance(PIRATE_ID, CaptainsLib.STANCE_BEFRIEND) == 1,
		"adjust_stance returns the new value (befriend 0 → 1)")
	_check(CaptainsLib.adjust_stance(PIRATE_ID, CaptainsLib.STANCE_NEMESIS_DEFEAT) == -1,
		"the nemesis-defeat delta lands (1 → −1)")
	_check(CaptainsLib.adjust_stance(PIRATE_ID, -100) == -10,
		"stance clamps at −10")
	_check(CaptainsLib.adjust_stance(PIRATE_ID, 100) == 10,
		"stance clamps at +10")
	_check(CaptainsLib.adjust_stance(PIRATE_ID, CaptainsLib.STANCE_ATTACK_NONHOSTILE) == 9,
		"the piracy grudge reads off the +10 ceiling (10 → 9)")


# --- 6. The nemesis predicate (docs/60-* §4.11.15: role × stance ≤ −3) --------

func _test_nemesis_predicate() -> void:
	_reset()
	_check(not CaptainsLib.is_nemesis(PIRATE_ID),
		"a pirate at stance 0 is no nemesis")
	CaptainsLib.adjust_stance(PIRATE_ID, -3)
	_check(CaptainsLib.is_nemesis(PIRATE_ID),
		"a pirate at stance −3 IS a nemesis")
	CaptainsLib.adjust_stance(PIRATE_ID, -7)
	_check(CaptainsLib.is_nemesis(PIRATE_ID),
		"deeper grudge −10 stays a nemesis (the gate is ≤ −3)")
	CaptainsLib.adjust_stance(PIRATE_ID, 8)
	_check(not CaptainsLib.is_nemesis(PIRATE_ID),
		"stance −2 drops out of the nemesis band")

	var privateer := _find_card("privateer", 2)
	CaptainsLib.adjust_stance(privateer, -4)
	_check(CaptainsLib.is_nemesis(privateer),
		"a privateer in the band is a nemesis (both roles qualify)")

	var trader := _find_card("trader", 1)
	CaptainsLib.adjust_stance(trader, -10)
	_check(not CaptainsLib.is_nemesis(trader),
		"a trader at −10 is NOT a nemesis (role gate)")
	var hunter := _find_card("hunter", 2)
	CaptainsLib.adjust_stance(hunter, -10)
	_check(not CaptainsLib.is_nemesis(hunter),
		"a hunter at −10 is NOT a nemesis (already hunts by role)")
	_check(not CaptainsLib.is_nemesis("cap_nobody"),
		"an unknown id is never a nemesis")


# --- 7. Familiarity tiers (docs/80-* dossier: 3/6/10) --------------------------

func _test_familiarity_tiers() -> void:
	_reset()
	_check(CaptainsLib.familiarity_tier(PIRATE_ID) == 0,
		"an unmet captain sits at familiarity tier 0")
	var expected := {"2": 0, "3": 1, "5": 1, "6": 2, "9": 2, "10": 3, "11": 3}
	for value in expected:
		var id := "probe_%s" % value
		CaptainsLib.ensure(id)["familiarity"] = int(value)
		_check(CaptainsLib.familiarity_tier(id) == int(expected[value]),
			"familiarity %s → tier %d (thresholds 3/6/10)" % [value, expected[value]])

	# add_familiarity: default +1, clamped both ends.
	var a := _find_card("trader", 1)
	CaptainsLib.add_familiarity(a)
	_check(CaptainsLib.familiarity(a) == 1, "add_familiarity defaults to +1")
	CaptainsLib.add_familiarity(a, 200)
	_check(CaptainsLib.familiarity(a) == CaptainsLib.FAMILIARITY_MAX,
		"familiarity clamps at 99")
	_check(CaptainsLib.add_familiarity(a, -500) == 0,
		"familiarity clamps at 0 (and returns the new value)")


# --- 8. Deployment bookkeeping (the two-live-fleets exclusivity pin) ----------

func _test_deployment_exclusivity() -> void:
	_reset()
	var trader := _find_card("trader", 1)
	_check(CaptainsLib.is_spawnable(trader, 5),
		"an unmet captain is spawnable")
	CaptainsLib.deploy(trader)
	_check(GameState.captain_states.has(trader),
		"deploy() touches the entry lazily (B's spawn draw)")
	_check(CaptainsLib.is_deployed(trader) and not CaptainsLib.is_spawnable(trader, 5),
		"a deployed captain is not spawnable (no second live fleet)")
	CaptainsLib.release(trader)
	_check(not CaptainsLib.is_deployed(trader)
		and CaptainsLib.is_spawnable(trader, 5),
		"release() clears the flag: immediately spawnable again (budget shrink)")
	_check(not GameState.captain_states[trader].has("deployed"),
		"release erases the runtime key (an idle entry matches the save shape)")

	# Defeat keeps the captain out even though the deployment already cleared.
	CaptainsLib.defeat(trader, 5, false)
	_check(not CaptainsLib.is_spawnable(trader, 5),
		"a released-then-returning captain is still not spawnable (queue first)")

	# Release of an untouched captain is a safe no-op (no phantom entry).
	CaptainsLib.release("cap_nobody")
	_check(not GameState.captain_states.has("cap_nobody"),
		"release of an unmet captain creates no entry")
	_check(not CaptainsLib.is_spawnable("cap_nobody", 5),
		"an unknown id is never spawnable (no canon card)")


# --- 9. Dossier flag (docs/80-*: the card-external info layer) -----------------

func _test_dossier_flag() -> void:
	_reset()
	_check(not CaptainsLib.dossier_seen(PIRATE_ID),
		"an unmet captain's dossier is unseen")
	CaptainsLib.mark_dossier_seen(PIRATE_ID)
	_check(CaptainsLib.dossier_seen(PIRATE_ID),
		"mark_dossier_seen persists on the state entry")


# --- 10. Speed jitter (docs/60-* §4.11.15: the ±10% captain speed cap) --------

func _test_speed_jitter() -> void:
	# Stable across calls: a pure hash of the id (no RNG, no state).
	var first := CaptainsLib.speed_jitter(PIRATE_ID)
	_check(is_equal_approx(first, CaptainsLib.speed_jitter(PIRATE_ID)),
		"speed_jitter is stable across calls (same id, same value)")
	_check(is_equal_approx(CaptainsLib.speed_jitter("cap_pirate_0001"),
		CaptainsLib.speed_jitter("cap_pirate_0001")),
		"speed_jitter is stable on a generated id too")
	# In range, ends inclusive, for a fixed id sample (no sweep).
	var in_range := true
	for id in [PIRATE_ID, "cap_pirate_0001", "cap_trader_0001", "cap_leg_trader_05",
		"", "cap_nobody"]:
		var v := CaptainsLib.speed_jitter(str(id))
		if v < -CaptainsLib.SPEED_JITTER_MAX or v > CaptainsLib.SPEED_JITTER_MAX:
			in_range = false
	_check(in_range, "every sampled jitter sits in [−0.10, +0.10]")


# --- Harness (docs/90-* §13) ---------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
