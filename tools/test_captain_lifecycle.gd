extends Node
## Phase-8 W4-D acceptance tests: the named-captain canon lifecycle and the
## ecology contracts it rides (docs/60-COMBAT.md §4.1.1, §4.11.11.4,
## §4.11.15; docs/10-DATA-SCHEMA.md §4.11/§4.15; docs/IMPLEMENT-Phase8.md
## §2.4 + the W4-D row).
##
##   godot --headless res://tools/test_captain_lifecycle.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1  canon data pins — the closed roster covers the extreme-preset closed
##      form and no two people (captains ∪ officers) share a zh/en name;
##   2  `Captains.state` lazy defaults (status/return_day/tier_now/stance/
##      familiarity/dossier_seen/defeats/wins);
##   3  the return queue: defeat(day) → returning day+60 → active again,
##      tier_now preserved (§4.11.15);
##   4  tier drift: −1 crushed / +1 win, clamp 1–3 (§4.11.11.4);
##   5  stance/familiarity clamps (±10 per adjustment, fixed-point bounds;
##      familiarity caps at 99; the 3/6/10 career-log thresholds accumulate);
##   6  the nemesis truth table (stance ≤ −3 ∧ role ∈ {pirate, privateer})
##      and the pure captain speed jitter (±10%, stable across a reset);
##   7  deployment exclusivity (deploy → not spawnable → release);
##   8  the BattleRewards seams: defeat(id, day, crushed) / win(id, day),
##      the nemesis defeat's extra −2 (§4.11.15);
##   9  the seeded duel replay: one fixed-seed battle against a canon-card
##      fleet reproduces the identical outcome dict (run twice, compare);
##  10  the NpcFleets integration: spawns draw deployed canon cards, two
##      fleets never hold one captain, the removal funnel releases the
##      deployment and books the return queue;
##  11  the cap-arithmetic closed forms: normal core + 16 slack = global,
##      and the canon count ≥ the extreme-preset total (§4.1.1 × §4.10);
##  12  the day-tick perf probe at the filled normal cap (PROFILE avg/worst;
##      the 75 ms serial gate is evaluated by `test_density` — this probe
##      is the post-canon re-record with +1σ smoke headroom, the
##      `test_npc_fleets` precedent).
##
## Test discipline: contract pins only — every constant below is either read
## from the data files, derived as a closed form in-suite, or cited to its
## owning doc; the one integration observation per rule uses a fixed seed.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

## W4-A's module — loaded by path so the suite reports a clean RED with a
## named check when it is absent instead of failing the scene boot.
const CAPTAINS_PATH := "res://scripts/world/captains.gd"

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

## Open water in the world map's variables band, far from every harbor.
const OPEN_CELL := Vector2i(1400, 640)

## §4.1.1 pirate row, normal preset: `8 + unpatrolled_zones` ≈ 25 — the
## Phase-7 measured composition (8 pirate_base + 17 unpatrolled zones; the
## validator's `UNPATROLLED_ZONES_PHASE7`, docs/60-* §4.1.1 +
## tools/demo_check_phase7.md). The extreme closed form uses it UNCAPPED
## (§7.7: the canon covers the demand, not the module's core-share cap).
const PIRATE_BASE := 8
const UNPATROLLED_ZONES_PHASE7 := 17
## §4.1.1: the global cap adds 6 treasure + ≤ 6 hunters + 4 spare above the
## core budgets (`NpcFleetsLib.GLOBAL_CAP_SLACK`).
const GLOBAL_CAP_SLACK := 16

## The perf probe (docs/60-* §4.11.11.5): ≥ 30 timed ticks at the filled
## normal cap. The 75 ms pin is evaluated serially by `test_density`; this
## suite may run in the runner's parallel batch, so its own smoke gate keeps
## the +1σ headroom (80 ms) `test_npc_fleets` set for the same reason.
const PERF_TICKS := 35
const PERF_SMOKE_GATE_MS := 80.0
## The drive window toward the core cap (the trickle is 7/day at the normal
## cap; spawn-draw failures can leave a handful short — the probe's floor
## below keeps the probe at a real cap population).
const DRIVE_MAX_DAYS := 180
const PERF_POPULATION_FLOOR := 280

## The seeded duel replay's fixed inputs (§4.12.1 config; the same fixture
## family as `test_battle` §13's scripted replay).
const REPLAY_SEED := 4242
const REPLAY_DAY := 12
const REPLAY_GOLD := 3000
const REPLAY_CONTACT := Vector2i(30, 40)

const WATCHDOG_SECONDS := 240.0

var _failures: Array[String] = []
var _checks := 0
var _watchdog: Timer = null
var _section := "<startup>"
var _captains: Script = null
var _canon: Array = []
var _canon_by_id: Dictionary = {}


func _ready() -> void:
	_arm_watchdog()
	_section = "module + map load"
	_captains = load(CAPTAINS_PATH)
	_check(_captains != null,
		"scripts/world/captains.gd loads (W4-A's module)")
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "map loads for the lifecycle fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	NpcFleetsLib.reset_caches()

	_section = "1 canon data pins"
	_test_canon_data()
	if _captains == null:
		# Without W4-A's module the remaining sections cannot run: report
		# what passed and stop (the wave gate merges A before D).
		_section = "report"
		_fail("captains.gd is absent — the lifecycle sections cannot run")
		_report()
		return
	_section = "2 lazy defaults"
	_test_lazy_defaults()
	_section = "3 return queue"
	_test_return_queue()
	_section = "4 tier drift"
	_test_tier_drift()
	_section = "5 stance + familiarity clamps"
	_test_stance_familiarity()
	_section = "6 nemesis + speed jitter"
	_test_nemesis_and_jitter()
	_section = "7 deployment exclusivity"
	_test_deployment()
	_section = "8 battle-reward seams"
	_test_battle_reward_seams()
	_section = "9 seeded duel replay"
	_test_seeded_replay()
	_section = "10 ecology integration"
	_test_ecology_integration()
	_section = "11 cap closed forms"
	_test_cap_closed_forms()
	_section = "12 day-tick perf probe"
	_test_day_tick_perf()
	_section = "report"
	_report()


func _arm_watchdog() -> void:
	_watchdog = Timer.new()
	_watchdog.name = "Watchdog"
	_watchdog.one_shot = true
	_watchdog.wait_time = WATCHDOG_SECONDS
	_watchdog.timeout.connect(_on_watchdog)
	add_child(_watchdog)
	_watchdog.start()


func _on_watchdog() -> void:
	print("")
	print("WATCHDOG: no report after %.0f s — the suite stalled in section '%s'"
		% [WATCHDOG_SECONDS, _section])
	print("%d checks ran, %d failures so far:" % [_checks, _failures.size()])
	for failure in _failures:
		print("  - ", failure)
	_failures.append("WATCHDOG: stalled in section '%s'" % _section)
	get_tree().quit(1)


# --- Fixtures ---------------------------------------------------------------

## One canon card matching (role, tier), generated layer preferred (the
## legend layer is the same lifecycle — this only keeps the pinned cards
## away from the named-pirate `drop` flow). Deterministic file-order scan.
func _card(role: String, tier: int, used: Dictionary = {}) -> Dictionary:
	var fallback: Dictionary = {}
	for card in _canon:
		if str((card as Dictionary).get("role", "")) != role:
			continue
		if int((card as Dictionary).get("tier", 0)) != tier:
			continue
		var id := str((card as Dictionary).get("id", ""))
		if used.has(id):
			continue
		if bool((card as Dictionary).get("legend", false)):
			fallback = card
			continue
		used[id] = true
		return card
	# Every generated card of the shape is used up — hand back a legend one
	# (the quota table guarantees far more generated cards than this suite
	# touches, so this branch is unreachable in practice).
	used[str(fallback.get("id", ""))] = true
	return fallback


## A bare run (no ecology): the W3 Person-model player block, one flagship,
## fixed day — the fixture every state-machine section runs on.
func _make_bare_run() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 14,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"officers": [],
		"equipment": {"weapon": "", "armor": ""},
		"reputation": {},
	}
	for nation_id in NATIONS:
		GameState.player["reputation"][nation_id] = 0
	GameState.fleet = [_ship("brigantine", {"cannons": 10, "crew": 40})]
	GameState.day = 10
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = null
	GameState.npc_fleets = []
	GameState.wrecks = []
	GameState.npc_preset = "normal"
	# The lazy-default store: every section starts from an unmet canon.
	GameState.captain_states = {}


func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0, "water": 0, "cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


func _state(id: String) -> Dictionary:
	return (_captains.call("state", id) as Dictionary)


# --- 1. Canon data pins (docs/10-* §4.11; the validator's §8.6 belt) ---------

func _test_canon_data() -> void:
	# One direct read of the built artifact (never hand-edited; the runtime
	# side reads it exactly like `battle_sim`'s FileAccess fallback).
	var parsed: Variant = _read_json("res://data/captains.json")
	_check(parsed is Dictionary and (parsed as Dictionary).has("captains"),
		"data/captains.json parses with the captains envelope")
	if not (parsed is Dictionary):
		return
	_canon = (parsed as Dictionary).get("captains", [])
	for card in _canon:
		_canon_by_id[str((card as Dictionary).get("id", ""))] = card
	var count := _canon.size()
	_check(count > 0, "the canon roster is non-empty (%d cards)" % count)

	# Names are never reused across every person — canon ∪ officers
	# (§4.11 card rule; §8.6 item 2 is the validator's belt, this is the
	# runtime-side scan).
	var zh_seen: Dictionary = {}
	var en_seen: Dictionary = {}
	var zh_dup := ""
	var en_dup := ""
	var files := ["res://data/captains.json", "res://data/officers.json"]
	for path in files:
		var doc: Variant = _read_json(path)
		if not (doc is Dictionary):
			continue
		var people: Array = (doc as Dictionary).get(
			"captains", (doc as Dictionary).get("officers", []))
		for person in people:
			var name: Dictionary = (person as Dictionary).get("name", {})
			var zh := str(name.get("zh", ""))
			var en := str(name.get("en", ""))
			if zh_seen.has(zh):
				zh_dup = zh
			zh_seen[zh] = true
			if en_seen.has(en):
				en_dup = en
			en_seen[en] = true
	_check(zh_dup.is_empty(),
		"no two people share a zh name ('%s' repeats)" % zh_dup)
	_check(en_dup.is_empty(),
		"no two people share an en name ('%s' repeats)" % en_dup)

	# The closed form: canon count ≥ the extreme-preset total derived from
	# npc_config × the §4.1.1 role formulas (§7.7 — coverage is computed,
	# never magic-numbered; the validator mirrors this in group 11).
	var derived := _derive_extreme_totals()
	var total := 0
	for role in derived:
		total += int(derived[role])
	_check(count >= total,
		"the canon (%d cards) covers the extreme-preset closed form (%d: %s)"
		% [count, total, str(derived)])
	# The measured acceptance pin (W2 record, IMPLEMENT-Phase8 W2 status):
	# 1,275 cards — trader 525 / coaster 450 / pirate 100 / patrol 72 /
	# privateer 56 / courier 48 / hunter 24; treasure rides trader tier-2.
	_check(count == 1275,
		"the canon holds the measured 1,275 cards (got %d)" % count)


func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed


## The extreme-preset per-role closed form — the suite's own derivation from
## data (npc_config budgets × preset 4.0, multiply-then-ceil inside the ceil,
## per §4.1.1 / §8.6 item 3's mirror of `budget_for`). Pirates count the
## UNCAPPED §4.1.1 demand; hunters count the transient row's worst case
## (every nation bountied) × the preset.
func _derive_extreme_totals() -> Dictionary:
	var config: Dictionary = DataLoader.npc_config
	var extreme := float((config.get("presets", {}) as Dictionary).get(
		"extreme", 4.0))
	var budgets: Dictionary = config.get("budgets", {})
	var own: Dictionary = {}
	var neutral := 0
	for port in DataLoader.ports_list:
		var nation_id := str((port as Dictionary).get("nation_id", ""))
		if nation_id.is_empty():
			neutral += 1
		else:
			own[nation_id] = int(own.get(nation_id, 0)) + 1
	var totals := {
		"trader": 0, "coaster": 0, "patrol": 0, "courier": 0,
		"privateer": 0, "pirate": 0, "hunter": 0,
	}
	for nation_id in own:
		var n := int(own[nation_id])
		totals["trader"] += ceili(n
			* float(budgets.get("traders_mult_per_port", 1.25)) * extreme)
		totals["coaster"] += ceili(n
			* float(budgets.get("coasters_mult_per_port", 0.75)) * extreme)
		var raw := ceili(n / float(budgets.get("patrols_div_ports", 6))
			* extreme)
		totals["patrol"] += maxi(int(budgets.get("patrols_min", 1)), raw)
		totals["courier"] += ceili(
			float(budgets.get("couriers_per_nation", 2)) * extreme)
	totals["coaster"] += ceili(neutral
		* float(config.get("neutral_coasters_mult", 0.75)) * extreme)
	var pairs := {}
	for nation in DataLoader.nations_list:
		for rival in (nation as Dictionary).get("rivals", []):
			var key := [str((nation as Dictionary).get("id", "")), str(rival)]
			key.sort()
			pairs[key] = true
	totals["privateer"] += pairs.size() * ceili(
		float(budgets.get("privateers_per_rivalry", 2)) * extreme)
	totals["pirate"] += ceili(float(PIRATE_BASE + UNPATROLLED_ZONES_PHASE7)
		* extreme)
	# The transient hunter row: ≤ 1 per bountied nation (§4.1.1), all six
	# bountied at worst × the preset.
	totals["hunter"] += ceili(float(own.size()) * extreme)
	return totals


## The normal-preset core cap, the same closed form at multiplier 1.0 with
## the pirate row capped at its §4.1.1 core share (≈ 25).
func _derive_normal_core() -> int:
	var config: Dictionary = DataLoader.npc_config
	var budgets: Dictionary = config.get("budgets", {})
	var own: Dictionary = {}
	var neutral := 0
	for port in DataLoader.ports_list:
		var nation_id := str((port as Dictionary).get("nation_id", ""))
		if nation_id.is_empty():
			neutral += 1
		else:
			own[nation_id] = int(own.get(nation_id, 0)) + 1
	# Per-nation sums, exactly the module's `core_cap` walk: privateers
	# budget 2 per nation that sits in a rivalry pair (§4.1.1).
	var pairs := {}
	for nation in DataLoader.nations_list:
		for rival in (nation as Dictionary).get("rivals", []):
			var key := [str((nation as Dictionary).get("id", "")), str(rival)]
			key.sort()
			pairs[key] = true
	var total := 0
	for nation_id in own:
		var n := int(own[nation_id])
		total += ceili(n * float(budgets.get("traders_mult_per_port", 1.25)))
		total += ceili(n * float(budgets.get("coasters_mult_per_port", 0.75)))
		var raw := ceili(n / float(budgets.get("patrols_div_ports", 6)))
		total += maxi(int(budgets.get("patrols_min", 1)), raw)
		total += ceili(float(budgets.get("couriers_per_nation", 2)))
		var in_pair := false
		for rival in _rivals_of(nation_id):
			var key := [nation_id, str(rival)]
			key.sort()
			if pairs.has(key):
				in_pair = true
		if in_pair:
			total += ceili(float(budgets.get("privateers_per_rivalry", 2)))
	# The §4.11.14 nationless-coaster line over the neutral ports.
	total += ceili(neutral * float(config.get("neutral_coasters_mult", 0.75)))
	# The §4.1.1 pirate row at normal: 8 base + 17 unpatrolled zones ≈ 25 —
	# exactly the module's core share (its PIRATE_CORE_CAP).
	total += PIRATE_BASE + UNPATROLLED_ZONES_PHASE7
	return total


func _rivals_of(nation_id: String) -> Array:
	for nation in DataLoader.nations_list:
		if str((nation as Dictionary).get("id", "")) == nation_id:
			return (nation as Dictionary).get("rivals", [])
	return []


# --- 2. `Captains.state` lazy defaults (§4.15 captain_states) -----------------

func _test_lazy_defaults() -> void:
	_make_bare_run()
	var used := {}
	var card := _card("trader", 1, used)
	var id := str(card.get("id", ""))
	var state := _state(id)
	_check(str(state.get("status", "")) == "active",
		"an unmet captain defaults to status 'active'")
	_check(int(state.get("return_day", -1)) == 0,
		"an unmet captain defaults to return_day 0")
	_check(int(state.get("tier_now", -1)) == int(card.get("tier", -1)),
		"tier_now defaults to the card's tier (%d)" % int(card.get("tier", -1)))
	_check(int(state.get("stance", 1)) == 0,
		"an unmet captain defaults to stance 0")
	_check(int(state.get("familiarity", -1)) == 0,
		"an unmet captain defaults to familiarity 0")
	_check(bool(state.get("dossier_seen", true)) == false,
		"an unmet captain defaults to dossier_seen false")
	_check(int(state.get("defeats", -1)) == 0 and int(state.get("wins", -1)) == 0,
		"an unmet captain defaults to defeats/wins 0")
	# The defaults are a THROWAWAY copy — the read never materialises the
	# entry (the W4-A contract; `ensure()` is the only creator). Full entries
	# exist only for captains the run actually touched.
	_check(not GameState.captain_states.has(id),
		"the lazy read does not materialise the entry — ensure() is the only creator")


# --- 3. The return queue (§4.11.15: day + 60, tier preserved) -----------------

func _test_return_queue() -> void:
	_make_bare_run()
	var used := {}
	var card := _card("pirate", 2, used)
	var id := str(card.get("id", ""))
	_captains.call("defeat", id, 100, false)
	var state := _state(id)
	_check(str(state.get("status", "")) == "returning",
		"defeat books the captain as 'returning'")
	_check(int(state.get("return_day", -1)) == 160,
		"return_day is day + 60 (100 → 160, got %d)"
		% int(state.get("return_day", -1)))
	_check(int(state.get("defeats", -1)) == 1,
		"defeat counts one defeat (got %d)" % int(state.get("defeats", -1)))
	_check(int(state.get("tier_now", -1)) == 2,
		"an uncrushed defeat preserves tier_now (got %d)"
		% int(state.get("tier_now", -1)))
	_check(not _captains.call("is_spawnable", id),
		"a returning captain is not spawnable")
	# Ticks before the return day change nothing; the return day activates.
	_captains.call("day_tick", 101)
	_captains.call("day_tick", 159)
	_check(str(_state(id).get("status", "")) == "returning",
		"day_tick(159) keeps the captain returning")
	_captains.call("day_tick", 160)
	_check(str(_state(id).get("status", "")) == "active",
		"day_tick(160) returns the captain to 'active' under its own name")
	_check(int(_state(id).get("tier_now", -1)) == 2,
		"the return preserves tier_now (drift applied only at defeat/win)")
	_check(_captains.call("is_spawnable", id),
		"the returned captain is spawnable again")


# --- 4. Tier drift (§4.11.11.4: −1 crushed / +1 win, clamp 1–3) ---------------

func _test_tier_drift() -> void:
	_make_bare_run()
	var used := {}
	# A crushed defeat drops one tier: 2 → 1.
	var mid := _card("pirate", 2, used)
	var mid_id := str(mid.get("id", ""))
	_captains.call("defeat", mid_id, 20, true)
	_check(int(_state(mid_id).get("tier_now", -1)) == 1,
		"a crushed defeat drops tier 2 → 1 (got %d)"
		% int(_state(mid_id).get("tier_now", -1)))
	# Wins climb one tier each and clamp at 3: 1 → 2 → 3 → 3.
	var low := _card("pirate", 1, used)
	var low_id := str(low.get("id", ""))
	_captains.call("win", low_id, 21)
	_check(int(_state(low_id).get("tier_now", -1)) == 2,
		"a victory raises tier 1 → 2 (got %d)"
		% int(_state(low_id).get("tier_now", -1)))
	_captains.call("win", low_id, 22)
	_check(int(_state(low_id).get("tier_now", -1)) == 3,
		"a second victory raises tier 2 → 3 (got %d)"
		% int(_state(low_id).get("tier_now", -1)))
	_captains.call("win", low_id, 23)
	_check(int(_state(low_id).get("tier_now", -1)) == 3,
		"the tier clamp holds at 3 (got %d)" % int(_state(low_id).get("tier_now", -1)))
	_check(int(_state(low_id).get("wins", -1)) == 3,
		"the win counter keeps counting at the clamp (got %d)"
		% int(_state(low_id).get("wins", -1)))
	# A crushed defeat at tier 1 clamps at 1 (never below the floor).
	var floor_card := _card("pirate", 1, used)
	var floor_id := str(floor_card.get("id", ""))
	_captains.call("defeat", floor_id, 24, true)
	_check(int(_state(floor_id).get("tier_now", -1)) == 1,
		"a crushed defeat at tier 1 clamps at 1 (got %d)"
		% int(_state(floor_id).get("tier_now", -1)))


# --- 5. Stance & familiarity clamps (§4.11.15 hail verbs, §2.4 dossier) -------

func _test_stance_familiarity() -> void:
	_make_bare_run()
	var used := {}
	var card := _card("coaster", 1, used)
	var id := str(card.get("id", ""))
	# A single adjustment moves at most ±10 …
	_captains.call("adjust_stance", id, 50)
	var after := int(_state(id).get("stance", 0))
	_check(after > 0 and after <= 10,
		"one oversized adjustment clamps to a ≤ +10 step (got %+d)" % after)
	# … and repeated adjustments settle at the module's fixed-point ceiling
	# (observed, never assumed — the doc pins the thresholds ±2/±3, not the
	# clamp bound).
	for _i in 12:
		_captains.call("adjust_stance", id, 50)
	var ceiling := int(_state(id).get("stance", 0))
	_captains.call("adjust_stance", id, 50)
	_check(int(_state(id).get("stance", 0)) == ceiling,
		"the positive adjustments reach a fixed-point ceiling (%+d)" % ceiling)
	# Small deltas pass through exactly (befriend +1, the nemesis −2).
	_captains.call("adjust_stance", id, -ceiling)
	_captains.call("adjust_stance", id, 1)
	_check(int(_state(id).get("stance", 0)) == 1,
		"a +1 befriend adjustment passes through exactly (got %+d)"
		% int(_state(id).get("stance", 0)))
	_captains.call("adjust_stance", id, -2)
	_check(int(_state(id).get("stance", 0)) == -1,
		"a −2 adjustment passes through exactly (got %+d)"
		% int(_state(id).get("stance", 0)))

	# Familiarity accumulates and caps at 99 (§2.6 career log).
	_captains.call("add_familiarity", id, 200)
	_check(int(_state(id).get("familiarity", -1)) == 99,
		"familiarity caps at 99 (got %d)" % int(_state(id).get("familiarity", -1)))
	var fam := _card("courier", 1, used)
	var fam_id := str(fam.get("id", ""))
	_captains.call("add_familiarity", fam_id, 3)
	_check(int(_state(fam_id).get("familiarity", -1)) == 3,
		"familiarity reaches the tier-1 career-log threshold 3 (got %d)"
		% int(_state(fam_id).get("familiarity", -1)))
	_captains.call("add_familiarity", fam_id, 3)
	_check(int(_state(fam_id).get("familiarity", -1)) == 6,
		"familiarity reaches the tier-2 career-log threshold 6 (got %d)"
		% int(_state(fam_id).get("familiarity", -1)))
	_captains.call("add_familiarity", fam_id, 4)
	_check(int(_state(fam_id).get("familiarity", -1)) == 10,
		"familiarity reaches the tier-3 career-log threshold 10 (got %d)"
		% int(_state(fam_id).get("familiarity", -1)))


# --- 6. The nemesis truth table + the pure speed jitter (§4.11.15) ------------

func _test_nemesis_and_jitter() -> void:
	_make_bare_run()
	var used := {}
	# A pirate at stance ≤ −3 is a nemesis.
	var pirate := _card("pirate", 1, used)
	var pirate_id := str(pirate.get("id", ""))
	_captains.call("adjust_stance", pirate_id, -3)
	_check(_captains.call("is_nemesis", pirate_id),
		"stance −3 on a pirate card reads as a nemesis")
	# A privateer at stance −2 is not; at −4 it is (the role gate).
	var priv := _card("privateer", 2, used)
	var priv_id := str(priv.get("id", ""))
	_captains.call("adjust_stance", priv_id, -2)
	_check(not _captains.call("is_nemesis", priv_id),
		"stance −2 on a privateer is no nemesis")
	_captains.call("adjust_stance", priv_id, -2)
	_check(_captains.call("is_nemesis", priv_id),
		"stance −4 on a privateer reads as a nemesis (role gate)")
	# A merchant role never reads as a nemesis, however deep the grudge.
	var trader := _card("trader", 1, used)
	var trader_id := str(trader.get("id", ""))
	_captains.call("adjust_stance", trader_id, -10)
	_check(not _captains.call("is_nemesis", trader_id),
		"a trader at the stance floor is never a nemesis (role gate)")

	# The speed jitter is pure: same id ⇒ same value, across calls, across a
	# state reset (§2.4: ±10% captain jitter at composition).
	for probe in [pirate_id, priv_id, trader_id]:
		var first: float = _captains.call("speed_jitter", probe)
		var again: float = _captains.call("speed_jitter", probe)
		_check(first == again,
			"speed_jitter is stable across calls (%s: %f)" % [probe, first])
		_check(first >= -0.10 and first <= 0.10,
			"speed_jitter stays within ±0.10 (%s: %f)" % [probe, first])
	GameState.captain_states = {}
	_check(_captains.call("speed_jitter", pirate_id) \
			== _captains.call("speed_jitter", pirate_id),
		"speed_jitter survives a GameState reset unchanged")


# --- 7. Deployment exclusivity (§4.11.15: the spawn draw skips deployed) ------

func _test_deployment() -> void:
	_make_bare_run()
	var used := {}
	var card := _card("pirate", 2, used)
	var id := str(card.get("id", ""))
	_check(_captains.call("is_spawnable", id),
		"an active, undeployed captain is spawnable")
	_captains.call("deploy", id)
	_check(_captains.call("is_deployed", id), "deploy marks the captain deployed")
	_check(not _captains.call("is_spawnable", id),
		"a deployed captain is not spawnable (the draw skips it)")
	_captains.call("release", id)
	_check(not _captains.call("is_deployed", id), "release clears the deployment")
	_check(_captains.call("is_spawnable", id),
		"a released captain is spawnable again")
	# A defeated (returning) captain is unspawnable regardless of deployment.
	_captains.call("defeat", id, 30, false)
	_captains.call("release", id)
	_check(not _captains.call("is_spawnable", id),
		"a released but returning captain stays unspawnable")


# --- 8. The BattleRewards seams (§4.11.15: defeat/win fire the lifecycle) -----

## The seam module behind an Object-typed reference: `defeat`/`win` are
## W4-C's additions, so the calls stay dynamic (the suite parses and boots
## before C merges, then pins the real seam at the wave gate).
var _rewards: Object = preload("res://scripts/combat/battle_rewards.gd")


func _test_battle_reward_seams() -> void:
	_make_bare_run()
	var used := {}
	# A wiped enemy fleet (crushed = every hull lost, not surrendered or
	# captured) drops the tier: 2 → 1 through the battle seam.
	var crushed := _card("pirate", 2, used)
	var crushed_id := str(crushed.get("id", ""))
	_rewards.call("defeat", crushed_id, GameState.day, true)
	var state := _state(crushed_id)
	_check(str(state.get("status", "")) == "returning",
		"BattleRewards.defeat books the return queue")
	_check(int(state.get("return_day", -1)) == GameState.day + 60,
		"the seam books return_day = day + 60 (got %d)"
		% int(state.get("return_day", -1)))
	_check(int(state.get("tier_now", -1)) == 1,
		"the crushed seam drops tier 2 → 1 (got %d)"
		% int(state.get("tier_now", -1)))
	# A non-crushed defeat (hulls surrendered/captured) keeps the tier.
	var spared := _card("pirate", 2, used)
	var spared_id := str(spared.get("id", ""))
	_rewards.call("defeat", spared_id, GameState.day, false)
	_check(int(_state(spared_id).get("tier_now", -1)) == 2,
		"the uncrushed defeat seam preserves tier_now (got %d)"
		% int(_state(spared_id).get("tier_now", -1)))
	# The player losing the flagship duel is the captain's victory: +1 tier.
	var victor := _card("pirate", 1, used)
	var victor_id := str(victor.get("id", ""))
	_rewards.call("win", victor_id, GameState.day)
	var win_state := _state(victor_id)
	_check(int(win_state.get("wins", -1)) == 1,
		"BattleRewards.win counts the captain's win (got %d)"
		% int(win_state.get("wins", -1)))
	_check(int(win_state.get("tier_now", -1)) == 2,
		"the win seam raises tier 1 → 2 (got %d)"
		% int(win_state.get("tier_now", -1)))
	# A nemesis defeat deepens the grudge by the extra −2 (§4.11.15),
	# clamped at the module's own floor (observed, never assumed).
	var nemesis := _card("pirate", 2, used)
	var nemesis_id := str(nemesis.get("id", ""))
	_captains.call("adjust_stance", nemesis_id, -3)
	_check(_captains.call("is_nemesis", nemesis_id),
		"the seam fixture reads as a nemesis (control)")
	var floor_id := str(_card("pirate", 3, used).get("id", ""))
	var stance_floor := _observed_stance_floor(floor_id)
	var before := int(_state(nemesis_id).get("stance", 0))
	_rewards.call("defeat", nemesis_id, GameState.day, false)
	var after := int(_state(nemesis_id).get("stance", 0))
	_check(after == maxi(before - 2, stance_floor),
		"the nemesis defeat adds the extra −2 within the clamp (%+d → %+d, floor %+d)"
		% [before, after, stance_floor])


## Walks the stance to its fixed-point floor with oversized adjustments and
## reports the observed bound — the nemesis −2 pin clamps against this, so
## no undocumented range number enters the suite.
func _observed_stance_floor(id: String) -> int:
	var previous := int(_state(id).get("stance", 0))
	for _i in 20:
		_captains.call("adjust_stance", id, -100)
		var current := int(_state(id).get("stance", 0))
		if current == previous:
			break
		previous = current
	return previous


# --- 9. The seeded duel replay (one fixed-seed integration observation) -------

func _test_seeded_replay() -> void:
	_make_bare_run()
	# The same seed reproduces the same battle against a canon-card fleet,
	# byte for byte (§4.12.1 config seed override; §13 of test_battle's
	# replay family — one observation, two runs, compared).
	var used := {}
	var card := _card("pirate", 2, used)
	var captain_id := str(card.get("id", ""))
	var first := _replay_outcome(captain_id)
	var second := _replay_outcome(captain_id)
	_check(not first.is_empty(), "the seeded battle resolves to an outcome")
	_check(str(first.get("result", "")) != "",
		"the outcome carries a §4.11.9 result (%s)" % str(first.get("result", "")))
	_check(JSON.stringify(first) == JSON.stringify(second),
		"the same seed replays the identical outcome dict byte-for-byte")


## One full headless battle against a fleet whose captain is the canon card
## `captain_id`, resolved from the fixed fixture inputs. Pure: the sim never
## touches GameState, so the two replay calls are independent.
func _replay_outcome(captain_id: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var enemy: Array = AiFleetLib.compose_enemy("pirate", REPLAY_DAY, rng)
	var sim := BattleSimLib.new({
		"player_ships": [_ship("brigantine", {"cannons": 10, "crew": 40})],
		"enemy_ships": enemy,
		"enemy_kind": "pirate",
		"enemy_nation": "",
		"day": REPLAY_DAY,
		"gold": REPLAY_GOLD,
		"contact": REPLAY_CONTACT,
		"weather": "calm",
		"seed": REPLAY_SEED,
		"captain_id": captain_id,
	})
	sim.start()
	var policy := func(active_sim) -> Dictionary:
		var current: Dictionary = active_sim.current_unit()
		if str(current.get("side", "")) == "enemy":
			return AiFleetLib.decide(active_sim, current)
		return _player_policy(active_sim, current)
	return sim.run_to_completion(policy, 30)


## The deterministic player policy of `test_battle`'s full-battle fixture:
## fire when in range, else close the distance, else hold.
func _player_policy(sim: BattleSimLib, unit: Dictionary) -> Dictionary:
	var enemies: Array = sim.living_units("enemy")
	if enemies.is_empty():
		return {"action": "hold", "target": {}, "cell": BattleSimLib.NO_CELL}
	var boardable: Dictionary = {}
	for enemy in enemies:
		if sim.can_cannon(unit, enemy):
			return {"action": "cannon", "target": enemy, "cell": BattleSimLib.NO_CELL}
		if sim.can_board(unit, enemy):
			boardable = enemy
	if not boardable.is_empty():
		return {"action": "board", "target": boardable, "cell": BattleSimLib.NO_CELL}
	var origin := sim.unit_cell(unit)
	var nearest: Dictionary = enemies[0]
	var best := maxi(absi(origin.x - sim.unit_cell(nearest).x),
		absi(origin.y - sim.unit_cell(nearest).y))
	for enemy in enemies:
		var cell := sim.unit_cell(enemy)
		var distance := maxi(absi(origin.x - cell.x), absi(origin.y - cell.y))
		if distance < best:
			best = distance
			nearest = enemy
	var target_cell := sim.unit_cell(nearest)
	var destination := BattleSimLib.NO_CELL
	var best_distance := best
	for cell in sim.legal_moves(unit):
		var distance := maxi(absi(cell.x - target_cell.x), absi(cell.y - target_cell.y))
		if distance < best_distance:
			best_distance = distance
			destination = cell
	if destination != BattleSimLib.NO_CELL:
		return {"action": "move", "target": {}, "cell": destination}
	return {"action": "hold", "target": {}, "cell": BattleSimLib.NO_CELL}


# --- 10. The NpcFleets integration (§4.11.11.4 captain identity) --------------

func _test_ecology_integration() -> void:
	# A fresh normal run: the fill and every spawn below draw canon cards.
	GameState.npc_preset = "normal"
	GameState.new_game("portugal", false)
	var sim := NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	# Every live fleet carries a canon captain id, deployed and unique —
	# two fleets never hold one captain (the draw skips deployed ids).
	var seen: Dictionary = {}
	var missing := 0
	var dup := ""
	var undeployed := ""
	var unknown := ""
	for fleet in GameState.npc_fleets:
		var id := str((fleet as Dictionary).get("captain_id", ""))
		if id.is_empty():
			missing += 1
			continue
		if seen.has(id):
			dup = id
		seen[id] = true
		if not _canon_by_id.has(id):
			unknown = id
		elif not _captains.call("is_deployed", id):
			undeployed = id
	_check(missing == 0,
		"every live fleet carries a canon captain_id (%d without)" % missing)
	_check(dup.is_empty(),
		"no two live fleets hold one captain ('%s' repeats)" % dup)
	_check(unknown.is_empty(),
		"every drawn captain_id is a canon id ('%s' unknown)" % unknown)
	_check(undeployed.is_empty(),
		"every drawn captain reads as deployed ('%s' undeployed)" % undeployed)

	# Seeded pirate spawns draw spawnable canon cards of the fleet's role.
	var spawned: Array = []
	var day := 12
	while spawned.size() < 3 and day < 30:
		var fleet: Dictionary = sim.spawn("pirate", "", day)
		if not fleet.is_empty():
			spawned.append(fleet)
		day += 1
	_check(spawned.size() >= 2,
		"the seeded pirate spawns fill the observation (%d fleets)" % spawned.size())
	if spawned.is_empty():
		_fail("the seeded pirate spawns produced no fleet to observe")
		return
	for fleet in spawned:
		var id := str(fleet.get("captain_id", ""))
		var card: Dictionary = _canon_by_id.get(id, {})
		_check(str(card.get("role", "")) == "pirate",
			"the spawn drew a pirate-role canon card (%s)" % id)
		_check(_captains.call("is_deployed", id),
			"the spawn deployed its drawn captain (%s)" % id)
	_check(_all_distinct(spawned.map(
		func(fleet: Dictionary) -> String:
			return str(fleet.get("captain_id", "")))),
		"the spawned fleets hold distinct captains")

	# The single removal funnel RELEASES the deployment (the captain is
	# immediately spawnable again) — the RETURN QUEUE books only at the battle
	# seam (`BattleRewards.apply` → `Captains.defeat`, W4-C), per the W4 gate
	# reading of §4.11.11.4: a budget-shrink/lane-end despawn is not a defeat.
	var doomed: Dictionary = spawned[0]
	var doomed_id := str(doomed.get("captain_id", ""))
	GameState.day = 40
	sim.remove(str(doomed.get("id", "")))
	_check(not _captains.call("is_deployed", doomed_id),
		"the removal funnel releases the captain's deployment")
	_check(str(_state(doomed_id).get("status", "")) == "active",
		"a plain removal leaves the captain active (no defeat booked)")
	_check(_captains.call("is_spawnable", doomed_id),
		"the released captain is immediately spawnable again")
	# The battle seam books the queue: defeat at day 40 → return_day 100.
	_captains.call("defeat", doomed_id, 40, false)
	_check(str(_state(doomed_id).get("status", "")) == "returning",
		"the battle seam books the captain as returning")
	_check(int(_state(doomed_id).get("return_day", -1)) == 100,
		"the battle seam books return_day = day + 60 (40 → 100, got %d)"
		% int(_state(doomed_id).get("return_day", -1)))
	_check(not _captains.call("is_spawnable", doomed_id),
		"the booked captain is not spawnable while returning")
	_captains.call("day_tick", 100)
	_check(_captains.call("is_spawnable", doomed_id),
		"the returned captain re-enters the draw at its return day")


func _all_distinct(ids: Array) -> bool:
	var seen: Dictionary = {}
	for id in ids:
		if seen.has(id):
			return false
		seen[id] = true
	return true


# --- 11. The cap-arithmetic closed forms (§4.1.1 × §4.10) ---------------------

func _test_cap_closed_forms() -> void:
	var sim := NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	var core := _derive_normal_core()
	_check(sim.core_cap() == core,
		"the normal core cap equals the data closed form (derived %d, module %d)"
		% [core, sim.core_cap()])
	_check(sim.global_cap() == core + GLOBAL_CAP_SLACK,
		"global cap = core + %d slack (derived %d + %d = %d, module %d)"
		% [GLOBAL_CAP_SLACK, core, GLOBAL_CAP_SLACK, core + GLOBAL_CAP_SLACK,
		sim.global_cap()])
	# The extreme closed form is covered by the closed canon (§7.7); the
	# totals themselves were pinned in section 1.
	var extreme := NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "extreme",
	})
	_check(extreme.global_cap() <= int(DataLoader.npc_config.get(
		"absolute_cap", 2048)),
		"even the extreme preset stays under the absolute cap (%d)"
		% extreme.global_cap())
	print(("  cap arithmetic: normal core %d + %d slack = %d global; "
		+ "extreme closed form %d ≤ canon %d")
		% [core, GLOBAL_CAP_SLACK, core + GLOBAL_CAP_SLACK,
		_derive_extreme_totals().values().reduce(
			func(a, b) -> int: return int(a) + int(b), 0), _canon.size()])
	print("  note: the Phase-7 record's 307 + 16 = 323 predates the "
		+ "2026-11-02 five-port amendment (145 → 150 ports), which "
		+ "re-derives the normal cap; test_npc_fleets §1 pins the numbers")


# --- 12. The day-tick perf probe (docs/60-* §4.11.11.5) ------------------------

func _test_day_tick_perf() -> void:
	# The filled normal cap, exactly the world scene's one-tick-per-day call.
	GameState.npc_preset = "normal"
	GameState.new_game("portugal", false)
	var sim := NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	var day := 2
	var target := sim.core_cap()
	for offset in DRIVE_MAX_DAYS:
		day = 2 + offset
		GameState.day = day
		sim.tick(day)
		if GameState.npc_fleets.size() >= target:
			break
	var population: int = GameState.npc_fleets.size()
	var worst := 0.0
	var total_ms := 0.0
	for offset in PERF_TICKS:
		var tick_day := day + 1 + offset
		GameState.day = tick_day
		var started := Time.get_ticks_usec()
		sim.tick(tick_day)
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		total_ms += elapsed
		worst = maxf(worst, elapsed)
	var avg := total_ms / float(PERF_TICKS)
	print(("  perf probe: %d fleets (normal core cap %d), avg %.1f ms, "
		+ "worst %.1f ms over %d ticks")
		% [population, target, avg, worst, PERF_TICKS])
	print("PROFILE day_tick_avg_ms %d" % int(round(avg)))
	print("PROFILE day_tick_worst_ms %d" % int(round(worst)))
	_check(population >= PERF_POPULATION_FLOOR,
		"the probe runs at the filled normal cap (%d of %d core)"
		% [population, target])
	_check(avg <= PERF_SMOKE_GATE_MS,
		("the day tick smoke gate holds at the filled cap (%.1f ms ≤ %.0f ms; "
		+ "the 75 ms serial gate is test_density's)")
		% [avg, PERF_SMOKE_GATE_MS])


# --- Report -------------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok  %s" % label)
	else:
		_failures.append(label)
		print("  FAIL %s" % label)


func _fail(label: String) -> void:
	_checks += 1
	_failures.append(label)
	print("  FAIL %s" % label)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d of %d checks FAILED:" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - ", failure)
		get_tree().quit(1)
