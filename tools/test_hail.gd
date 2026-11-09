extends Node
## Phase-8 W5-B hail contract tests (docs/60-COMBAT.md §4.11.15; docs/80-UI-UX.md
## §4.10.2; docs/50-* §4.2/§4.3; docs/30-* §4.2; docs/90-* §13 contract:
## headless, exit 0, `ALL PASS (N checks)`).
##
##   godot --headless res://tools/test_hail.tscn
##
## Deterministic contract pins only — the role × stance option matrix, the
## supply price matrix (×1.5 / ×1.25 / the negotiation cap), the intimidate
## chance clamps and outcome funnel, the befriend day gate, the free-intel
## payload and one modal boot. The intimidate ROLL is always passed in
## explicitly (the `roll` contract); the one seeded-default observation
## predicts the draw through the documented §4.11.1 seed formula — no RNG
## sweeps, no Monte-Carlo re-derivations.

const HailOptionsLib := preload("res://scripts/world/hail_options.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const HailModalScene := preload("res://scenes/world/hail_modal.tscn")

# Canon fixture ids — data-driven (generated ids are builder-owned; the suite
# pins behavior, not ids), same convention as tools/test_captains.gd.
var trader_id := ""
var coaster_id := ""
var pirate_id := ""
var hunter_id := ""

# Canon-card doubles injected through `BattleSim._captains_test_doubles` (the
# documented test seam): controlled duel ratings for the chance pins.
const EVEN_CARD := {
	"id": "cap_double_even", "name": {"zh": "平卡", "en": "Even Card"},
	"role": "pirate", "tier": 2,
	"skills": {"swordplay": 36, "gunnery": 0},
	"attributes": {"courage": 80, "charisma": 10},
}  # duel rating 36 + floor(80/20) = 40
const WEAK_CARD := {
	"id": "cap_double_weak", "name": {"zh": "弱卡", "en": "Weak Card"},
	"role": "pirate", "tier": 1,
	"skills": {"swordplay": 0, "gunnery": 0},
	"attributes": {"courage": 0, "charisma": 0},
}  # duel rating 0
const FIRST_OFFICER := "off_leg_duarte_silveira"  # swordplay 6, courage 19 → 6

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	trader_id = _find_card("trader", 1)
	coaster_id = _find_card("coaster", 1)
	pirate_id = _find_card("pirate", 1)
	hunter_id = _find_card("hunter", 2)
	_check(trader_id != "" and coaster_id != "" and pirate_id != ""
		and hunter_id != "",
		"canon fixtures exist: a trader/coaster/pirate at tier 1 and a hunter at tier 2")
	_test_range_guard()
	_test_role_stance_matrix()
	_test_price_base_port()
	_test_price_matrix()
	_test_supplies_resolve()
	_test_intimidate_bounds()
	_test_intimidate_outcomes()
	_test_befriend()
	_test_ask_rumours()
	_test_modal()
	_report()


# --- Fixtures -------------------------------------------------------------------

func _reset_world(gold: int = 10000, pos: Vector2i = Vector2i(100, 100),
		known: Array = ["lisbon", "seville"], day: int = 100) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {},
		"alloc_pending": 0,
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {},
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	GameState.fleet = [_ship("sloop")]
	GameState.gold = gold
	GameState.day = day
	GameState.world = {"position": {"x": pos.x, "y": pos.y}}
	GameState.known_ports = known.duplicate()
	GameState.captain_states = {}
	GameState.officer_states = {}
	GameState.fame = 0
	HailOptionsLib.reset_session()


func _ship(ship_type_id: String) -> Dictionary:
	var st: Dictionary = DataLoader.get_ship_type(ship_type_id)
	return {
		"ship_type_id": ship_type_id,
		"durability": int(st.get("durability", 0)),
		"crew": 20,
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"cargo": {},
	}


## A §4.15-shaped fleet fixture at the player tile (in hail range) unless
## `opts.x` says otherwise.
func _fleet(role: String, captain_id: String, opts: Dictionary = {}) -> Dictionary:
	return {
		"id": str(opts.get("id", "nf_test")),
		"role": role,
		"nation_id": str(opts.get("nation_id", "")),
		"cell": {"x": int(opts.get("x", 100)), "y": int(opts.get("y", 100))},
		"route": {"lanes": opts.get("lanes", ["lane_a"] as Array).duplicate(),
			"leg": 0, "tile_index": 0, "legs": []},
		"cargo": (opts.get("cargo", {}) as Dictionary).duplicate(),
		"captain_id": captain_id,
		"dest_port_id": str(opts.get("dest", "")),
		"cooldown_until_day": 0,
		"seed": 0,
		"dwell_until_day": 0,
		"anchor_cell": null,
	}


func _find_card(role: String, tier: int) -> String:
	for card in CaptainsLib.canon_list():
		if str((card as Dictionary).get("role", "")) == role \
				and int((card as Dictionary).get("tier", 0)) == tier:
			return str((card as Dictionary).get("id", ""))
	return ""


func _options_by_id(fleet: Dictionary) -> Dictionary:
	var by_id := {}
	for option in HailOptionsLib.options_for(fleet):
		by_id[str(option.get("id", ""))] = option
	return by_id


## True when any Label under `row` renders `text` (the terms lines).
## Phase 12 (the W2-C absolute layout): the terms lines are `rows` list
## rows of their own beneath the option's button row, so the search walks
## the content subtree (the guarantee is unchanged: the terms text renders).
func _row_has_terms(row: Node, text: String) -> bool:
	if (row is Label) and str(row.text) == text:
		return true
	for child in row.get_children():
		if _row_has_terms(child, text):
			return true
	return false


func _inject_cards() -> void:
	BattleSimLib._captains_test_doubles["cap_double_even"] = EVEN_CARD
	BattleSimLib._captains_test_doubles["cap_double_weak"] = WEAK_CARD


func _restore_cards() -> void:
	BattleSimLib._captains_test_doubles.erase("cap_double_even")
	BattleSimLib._captains_test_doubles.erase("cap_double_weak")


# --- 1. The range guard (the talk verb guarantees Chebyshev ≤ 2) ----------------

func _test_range_guard() -> void:
	_reset_world()
	var near := _fleet("trader", trader_id)  # cell 100,100 == the player tile
	_check(HailOptionsLib.options_for(near).size() == 4,
		"in-range hail builds all four options (trader)")

	var at_two := _fleet("trader", trader_id, {"x": 102, "y": 100})
	_check(HailOptionsLib.in_range(at_two),
		"Chebyshev exactly 2 is in hail range")
	_check(not HailOptionsLib.options_for(at_two).is_empty(),
		"options build at the range edge")

	var far := _fleet("trader", trader_id, {"x": 103, "y": 100})
	_check(not HailOptionsLib.in_range(far), "Chebyshev 3 is out of range")
	_check(HailOptionsLib.options_for(far).is_empty(),
		"out-of-range hail builds NOTHING (defensive)")
	_check(HailOptionsLib.resolve(
		HailOptionsLib.OPTION_RUMOURS, far).get("ok", true) == false,
		"out-of-range resolve refuses")

	var unknown := _fleet("pirate", "")
	_check(HailOptionsLib.display_name(unknown) == "Unidentified fleet",
		"a card-less fleet displays interact.unknown_name")


# --- 2. The role × stance option matrix (60-* §4.11.15) --------------------------

func _test_role_stance_matrix() -> void:
	var supplies_roles := {"trader": trader_id, "coaster": coaster_id}
	var bare_roles := {"pirate": pirate_id, "hunter": hunter_id}
	var supplies_ok := true
	var rumours_ok := true
	var intel_ok := true
	var intimidate_ok := true
	var befriend_ok := true
	for stance_val in [-5, 0, 2, 3]:
		for role in supplies_roles:
			_reset_world()
			CaptainsLib.ensure(supplies_roles[role])["stance"] = stance_val
			var by_id := _options_by_id(_fleet(role, supplies_roles[role]))
			supplies_ok = supplies_ok and by_id.has(HailOptionsLib.OPTION_SUPPLIES)
			rumours_ok = rumours_ok and bool(
				by_id.get(HailOptionsLib.OPTION_RUMOURS, {}).get("enabled", false))
			intel_ok = intel_ok and bool(
				by_id.get(HailOptionsLib.OPTION_RUMOURS, {}).get("intel", false)) \
				== (stance_val >= 2)
			intimidate_ok = intimidate_ok and bool(
				by_id.get(HailOptionsLib.OPTION_INTIMIDATE, {}).get("enabled", false))
			befriend_ok = befriend_ok and bool(
				by_id.get(HailOptionsLib.OPTION_BEFRIEND, {}).get("enabled", false))
		for role in bare_roles:
			_reset_world()
			CaptainsLib.ensure(bare_roles[role])["stance"] = stance_val
			var by_id := _options_by_id(_fleet(role, bare_roles[role]))
			supplies_ok = supplies_ok \
				and not by_id.has(HailOptionsLib.OPTION_SUPPLIES)
			rumours_ok = rumours_ok and bool(
				by_id.get(HailOptionsLib.OPTION_RUMOURS, {}).get("enabled", false))
			intel_ok = intel_ok and bool(
				by_id.get(HailOptionsLib.OPTION_RUMOURS, {}).get("intel", false)) \
				== (stance_val >= 2)
			intimidate_ok = intimidate_ok and bool(
				by_id.get(HailOptionsLib.OPTION_INTIMIDATE, {}).get("enabled", false))
			befriend_ok = befriend_ok and bool(
				by_id.get(HailOptionsLib.OPTION_BEFRIEND, {}).get("enabled", false))
	_check(supplies_ok,
		"buy_supplies appears for trader/coaster ONLY (all 16 matrix cells)")
	_check(rumours_ok, "ask_rumours is always enabled (all 16 matrix cells)")
	_check(intel_ok,
		"the rumours intel flag is exactly stance >= +2 (all 16 matrix cells)")
	_check(intimidate_ok,
		"intimidate is enabled for every role (all 16 matrix cells; coaster's only hostile verb)")
	_check(befriend_ok,
		"befriend starts enabled on a fresh day (all 16 matrix cells)")

	# The intimidate row carries its chance; the supplies row carries prices.
	_reset_world()
	var by_id := _options_by_id(_fleet("trader", trader_id))
	var chance: float = by_id[HailOptionsLib.OPTION_INTIMIDATE]["chance"]
	_check(chance >= HailOptionsLib.INTIMIDATE_P_MIN
		and chance <= HailOptionsLib.INTIMIDATE_P_MAX,
		"the intimidate row reports its chance inside [.05, .95]")
	var prices: Dictionary = by_id[HailOptionsLib.OPTION_SUPPLIES]["unit_prices"]
	_check(prices.get("provisions", 0) == 3 and prices.get("water", 0) == 1,
		"the supplies row reports the ×1.5 unit prices (3g / 1g)")


# --- 3. The price base pin (fleet dest port; nearest known port fallback) -------

func _test_price_base_port() -> void:
	_reset_world(10000, Vector2i(2083, 636))  # seville's projection
	var dest_fleet := _fleet("trader", trader_id, {"dest": "seville"})
	_check(HailOptionsLib.price_base_port(dest_fleet) == "seville",
		"the price base is the hailed fleet's dest_port_id port (seville)")

	var no_dest := _fleet("trader", trader_id)
	_check(HailOptionsLib.price_base_port(no_dest) == "seville",
		"a dest-less fleet prices from the NEAREST known port (still seville)")

	_reset_world(10000, Vector2i(2050, 615))  # lisbon's projection
	_check(HailOptionsLib.price_base_port(no_dest) == "lisbon",
		"the nearest-known fallback follows the player tile (lisbon)")

	_reset_world(10000, Vector2i(2050, 615), [])
	_check(HailOptionsLib.price_base_port(no_dest) == "",
		"no known ports → no base port (prices still resolve)")

	var bad_dest := _fleet("trader", trader_id, {"dest": "atlantis"})
	_reset_world(10000, Vector2i(2083, 636))
	_check(HailOptionsLib.price_base_port(bad_dest) == "seville",
		"an unknown dest_port_id falls back to the nearest known port")


# --- 4. The supply price matrix (×1.5; ×1.25 at stance +3; negotiation cap) -----

func _test_price_matrix() -> void:
	_reset_world()
	_check(HailOptionsLib.negotiation_discount_points() == 0,
		"negotiation 0 → 0 discount points")
	GameState.player["skills"]["negotiation"] = 40
	_check(HailOptionsLib.negotiation_discount_points() == 4,
		"negotiation 40 → floor(40/10) = 4 points")
	GameState.player["skills"]["negotiation"] = 100
	_check(HailOptionsLib.negotiation_discount_points() == 5,
		"negotiation 100 → capped at the formula's own reach of 5 points")
	GameState.player["skills"]["negotiation"] = 0

	# The closed form: units = 1500 × (1250 if stance ≥ +3) × (1000 − 10·pts),
	# floored once per kind on the full product (incl. qty).
	var fleet := _fleet("trader", trader_id, {"dest": "seville"})
	var matrix := {
		# [stance, negotiation skill, qty, expected total, expected prov unit]
		"base": [0, 0, 10, 45, 3],       # 30 + 15
		"warm": [3, 0, 10, 55, 3],       # 37.5 → 37 + 18.75 → 18
		"warm_neg40": [3, 40, 10, 54, 3],  # 36 + 18
		"warm_neg100": [3, 100, 10, 52, 3],  # 35.625 → 35 + 17.8 → 17
		"neg40": [0, 40, 10, 42, 2],     # 28.8 → 28 + 14.4 → 14
	}
	for case_name in matrix:
		var case: Array = matrix[case_name]
		_reset_world()
		CaptainsLib.ensure(trader_id)["stance"] = int(case[0])
		GameState.player["skills"]["negotiation"] = int(case[1])
		var qty := int(case[2])
		_check(HailOptionsLib.supplies_pair_cost(fleet, qty) == int(case[3]),
			"pair cost %s: stance %+d, neg %d, qty %d → %dg (floored once per kind)"
				% [case_name, int(case[0]), int(case[1]), qty, int(case[3])])
		_check(HailOptionsLib.supply_unit_price(fleet, "provisions") == int(case[4]),
			"provisions unit price %s floors to %dg" % [case_name, int(case[4])])

	_reset_world()
	CaptainsLib.ensure(trader_id)["stance"] = 3
	GameState.player["skills"]["negotiation"] = 100
	_check(HailOptionsLib.supply_unit_price(fleet, "water") >= 1,
		"prices floor at 1g (water 1.78 → 1 under the deepest discount)")
	_check(HailOptionsLib.supplies_pair_cost(fleet, 10) == 52,
		"the deepest discount still prices ABOVE the ×1.5 base (52 > 45)")


# --- 5. Supplies resolve: the applied funnel + refusals --------------------------

func _test_supplies_resolve() -> void:
	_reset_world()
	var fleet := _fleet("trader", trader_id, {"dest": "seville"})
	var payload := HailOptionsLib.resolve(HailOptionsLib.OPTION_SUPPLIES,
		fleet, 10)
	_check(bool(payload.get("ok", false)),
		"buy_supplies resolves for a trader")
	_check(int(payload.get("gold_delta", 0)) == -45,
		"the charge is −45g for 10+10 units at ×1.5 (single funnel)")
	_check(payload.get("cargo_gained", {}).get("provisions", 0) == 10
		and payload.get("cargo_gained", {}).get("water", 0) == 10,
		"the bundle reports 10 provisions + 10 water gained")
	_check(GameState.gold == 10000 - 45
		and FleetLib.supplies("provisions") == 10
		and FleetLib.supplies("water") == 10,
		"the purchase moved gold and both supply pools")
	_check(str(payload.get("lines", [{}])[0].get("key", "")) == "hail.supplies.result",
		"the result line is hail.supplies.result")
	_check(GameState.captain_states.is_empty() and GameState.fame == 0,
		"buying supplies touches no stance and no fame")

	_check(HailOptionsLib.resolve(
		HailOptionsLib.OPTION_SUPPLIES, fleet, 0).get("ok", true) == false,
		"a zero bundle refuses")
	_reset_world(44)
	_check(HailOptionsLib.resolve(
		HailOptionsLib.OPTION_SUPPLIES, fleet, 10).get("ok", true) == false,
		"a short purse refuses whole (nothing applied)")
	_check(GameState.gold == 44 and FleetLib.supplies("provisions") == 0,
		"a refused purchase left gold and hold untouched")

	# Capacity bound: the sloop holds 60 → max bundle 30 (2 × qty units).
	_reset_world()
	_check(HailOptionsLib.supplies_max_qty(fleet) == 30,
		"max_qty is capacity-bound: 60 free / 2 units per bundle = 30")
	_reset_world(11)
	_check(HailOptionsLib.supplies_max_qty(fleet) == 2,
		"max_qty is affordability-bound at a short purse (11g / 4g per bundle = 2)")

	# A full hold refuses.
	_reset_world()
	FleetLib.add_goods("cloth", 60)
	_check(FleetLib.fleet_free() == 0
		and HailOptionsLib.resolve(
			HailOptionsLib.OPTION_SUPPLIES, fleet, 10).get("ok", true) == false,
		"a full hold refuses the bundle")


# --- 6. The intimidate chance (60-* §4.11.15, clamps + the COU term) -------------

func _test_intimidate_bounds() -> void:
	_inject_cards()
	var fleet := _fleet("pirate", "cap_double_even")  # theirs 40

	# share 0.5, courage 10 → term 0 → p exactly 0.5.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 40
	_check(is_equal_approx(HailOptionsLib.intimidate_chance(fleet), 0.5),
		"even strengths, stance 0 → p = 0.5 exactly")

	# Stance −5 penalty: 0.5 − 5 × 0.05 = 0.25.
	CaptainsLib.ensure("cap_double_even")["stance"] = -5
	_check(is_equal_approx(HailOptionsLib.intimidate_chance(fleet), 0.25),
		"stance −5 subtracts 0.25 (5 × 0.05)")

	# floor(COU/200) is 0 across the whole attribute band: the p-term adds 0
	# for courage 100 too. Courage also feeds the DUEL base (+floor(COU/20)),
	# so the swordplay input is stepped down to hold `ours` at exactly 40 —
	# the chance then reads identical to the courage-10 case above.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 35  # 35 + floor(100/20) = 40
	GameState.player["attributes"]["courage"] = 100
	CaptainsLib.ensure("cap_double_even")["stance"] = -5
	_check(is_equal_approx(HailOptionsLib.intimidate_chance(fleet), 0.25),
		"courage 100 still adds floor(100/200) = 0 (the term's reach)")

	# Upper clamp: ours 100 vs theirs 0 → 1.0 → 0.95 (courage 10 and 100).
	_reset_world()
	GameState.player["skills"]["swordplay"] = 100
	var weak := _fleet("pirate", "cap_double_weak")
	_check(is_equal_approx(HailOptionsLib.intimidate_chance(weak), 0.95),
		"overwhelming strength clamps p at 0.95 (courage 10)")
	GameState.player["attributes"]["courage"] = 100
	_check(is_equal_approx(HailOptionsLib.intimidate_chance(weak), 0.95),
		"the clamp holds at courage 100")

	# Lower clamp: ours 0 vs theirs 40 at stance −5 → −0.25 → 0.05.
	_reset_world()
	GameState.player["attributes"]["courage"] = 10
	CaptainsLib.ensure("cap_double_even")["stance"] = -5
	_check(is_equal_approx(HailOptionsLib.intimidate_chance(fleet), 0.05),
		"hopeless odds at stance −5 clamp p at 0.05")

	# Ours = flagship duel base + Σ escort captain card ratings. Escort
	# captains are keyed by `ship_type_id` (the fleet ships' only stable key,
	# `20-*`), so the second escort is a DIFFERENT type to stay captain-less.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 40
	GameState.fleet = [_ship("sloop"), _ship("sloop"), _ship("latin")]
	GameState.officer_states = {
		FIRST_OFFICER: {"loyalty": 50, "sea_days": 0, "post_id": "captain",
			"ship_id": "sloop", "talk_cd_day": 0, "gift_cd_day": 0,
			"defeats": 0, "wage_mult": 1.0},
	}
	var officer: Dictionary = DataLoader.get_officer(FIRST_OFFICER)
	var escort_rating := BattleSimLib.card_duel_rating(officer)  # 6 + floor(19/20)
	_check(escort_rating == 6, "the fixture officer prices at duel rating 6")
	_check(HailOptionsLib.player_strength() == 40 + 6,
		"ours = flagship base 40 + the captained sloop escort's rating 6 "
		+ "(the captain-less latin escort adds 0)")
	_restore_cards()


# --- 7. Intimidate outcomes (the resolve funnel, roll contract) ------------------

func _test_intimidate_outcomes() -> void:
	# SUCCESS: roll 0.0 < any chance → half cargo floor per good + fame +5
	# + stance −1.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 100
	var fleet := _fleet("pirate", pirate_id,
		{"cargo": {"cloth": 10, "spices": 7}})
	var payload := HailOptionsLib.resolve(HailOptionsLib.OPTION_INTIMIDATE,
		fleet, 0, 0.0)
	_check(bool(payload.get("ok", false))
		and not bool(payload.get("made_hostile", false)),
		"roll 0.0 succeeds: the attempt resolved without hostility")
	_check(payload.get("cargo_gained", {}).get("cloth", 0) == 5
		and payload.get("cargo_gained", {}).get("spices", 0) == 3,
		"half the cargo is handed over, FLOORED per good (5 + 3)")
	_check(fleet["cargo"].get("cloth", 0) == 5
		and fleet["cargo"].get("spices", 0) == 4,
		"the target's own hold keeps the other half (5 + 4)")
	_check(FleetLib.held("cloth") == 5 and FleetLib.held("spices") == 3,
		"the goods entered the player's hold")
	_check(int(payload.get("fame_delta", 0)) == 5 and GameState.fame == 5,
		"pirate fame +5 (single funnel)")
	_check(int(payload.get("stance_delta", 0)) == CaptainsLib.STANCE_INTIMIDATE_WIN
		and CaptainsLib.stance(pirate_id) == -1,
		"success shifts stance by STANCE_INTIMIDATE_WIN (−1)")
	_check(str(payload.get("lines", [{}])[0].get("key", "")) == "hail.intimidate.win",
		"the win line is hail.intimidate.win")

	# Supplies keys in the target cargo route through the supplies pools.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 100
	var mixed := _fleet("trader", trader_id,
		{"cargo": {"provisions": 4, "cloth": 6}})
	var mixed_payload := HailOptionsLib.resolve(HailOptionsLib.OPTION_INTIMIDATE,
		mixed, 0, 0.0)
	_check(mixed_payload.get("cargo_gained", {}).get("provisions", 0) == 2
		and FleetLib.supplies("provisions") == 2
		and mixed_payload.get("cargo_gained", {}).get("cloth", 0) == 3,
		"provisions in the target's cargo half into the supplies pools "
		+ "(goods stay goods)")

	# FAILURE: roll ≥ chance → made_hostile + stance −2, nothing moves.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 0
	var hostile_fleet := _fleet("pirate", pirate_id,
		{"cargo": {"cloth": 10}})
	var fail := HailOptionsLib.resolve(HailOptionsLib.OPTION_INTIMIDATE,
		hostile_fleet, 0, 0.99)
	_check(bool(fail.get("ok", false))
		and bool(fail.get("made_hostile", false)),
		"roll 0.99 ≥ p: an executed outcome that turns the fleet hostile")
	_check(int(fail.get("stance_delta", 0)) == CaptainsLib.STANCE_INTIMIDATE_FAIL
		and CaptainsLib.stance(pirate_id) == -2,
		"failure shifts stance by STANCE_INTIMIDATE_FAIL (−2)")
	_check(GameState.fame == 0 and FleetLib.held("cloth") == 0
		and hostile_fleet["cargo"].get("cloth", 0) == 10,
		"failure moves no fame and no cargo")
	_check(str(fail.get("lines", [{}])[0].get("key", "")) == "hail.intimidate.lose",
		"the loss line is hail.intimidate.lose")

	# The default roll (−1) draws from the §4.11.1 seeded stream: identical
	# state → identical outcome, and the prediction matches the formula.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 0
	var seed_fleet := _fleet("pirate", pirate_id, {"cargo": {"cloth": 10}})
	var rng := RandomNumberGenerator.new()
	rng.seed = HailOptionsLib.roll_seed(seed_fleet)
	var predicted_hostile: bool = rng.randf() \
		>= HailOptionsLib.intimidate_chance(seed_fleet)
	var first := HailOptionsLib.resolve(HailOptionsLib.OPTION_INTIMIDATE,
		seed_fleet, 0)
	_check(bool(first.get("made_hostile", false)) == predicted_hostile,
		"the seeded default roll resolves exactly as the §4.11.1 formula predicts")
	_reset_world()
	GameState.player["skills"]["swordplay"] = 0
	var seed_fleet_2 := _fleet("pirate", pirate_id, {"cargo": {"cloth": 10}})
	var second := HailOptionsLib.resolve(HailOptionsLib.OPTION_INTIMIDATE,
		seed_fleet_2, 0)
	_check(bool(second.get("made_hostile", false)) == predicted_hostile,
		"an identical reset replays the identical seeded outcome")

	# An empty-handed target still pays fame + stance on success.
	_reset_world()
	GameState.player["skills"]["swordplay"] = 100
	var empty := HailOptionsLib.resolve(HailOptionsLib.OPTION_INTIMIDATE,
		_fleet("pirate", pirate_id), 0, 0.0)
	_check(bool(empty.get("ok", false)) and int(empty.get("fame_delta", 0)) == 5
		and (empty.get("cargo_gained", {}) as Dictionary).is_empty(),
		"success over an empty hold still grants fame +5 with no cargo")


# --- 8. Befriend: stance +1, once per captain per day -----------------------------

func _test_befriend() -> void:
	_reset_world()
	var fleet := _fleet("trader", trader_id)
	var payload := HailOptionsLib.resolve(HailOptionsLib.OPTION_BEFRIEND, fleet)
	_check(bool(payload.get("ok", false))
		and int(payload.get("stance_delta", 0)) == CaptainsLib.STANCE_BEFRIEND
		and CaptainsLib.stance(trader_id) == 1,
		"befriend applies STANCE_BEFRIEND (+1) through the funnel")
	_check(str(payload.get("lines", [{}])[0].get("key", "")) == "hail.befriend.result",
		"the befriend line is hail.befriend.result")

	var again := HailOptionsLib.resolve(HailOptionsLib.OPTION_BEFRIEND, fleet)
	_check(bool(again.get("ok", true)) == false
		and (again.get("lines", [{}]) as Array).size() == 1
		and str(again["lines"][0]["key"]) == "hail.befriend.used",
		"a same-day repeat refuses with hail.befriend.used")
	_check(CaptainsLib.stance(trader_id) == 1,
		"a refused befriend shifts no stance")

	var by_id := _options_by_id(fleet)
	_check(not bool(by_id[HailOptionsLib.OPTION_BEFRIEND]["enabled"])
		and str(by_id[HailOptionsLib.OPTION_BEFRIEND].get("reason_key", "")) == "hail.befriend.used",
		"the used befriend row grays out with its reason_key")

	GameState.day = 101
	by_id = _options_by_id(fleet)
	_check(bool(by_id[HailOptionsLib.OPTION_BEFRIEND]["enabled"]),
		"the next day the befriend row re-enables")
	var payload2 := HailOptionsLib.resolve(HailOptionsLib.OPTION_BEFRIEND, fleet)
	_check(bool(payload2.get("ok", false))
		and CaptainsLib.stance(trader_id) == 2,
		"a next-day befriend applies again (stance 2)")

	HailOptionsLib.reset_session()
	var payload3 := HailOptionsLib.resolve(HailOptionsLib.OPTION_BEFRIEND, fleet)
	_check(bool(payload3.get("ok", false))
		and CaptainsLib.stance(trader_id) == 3,
		"reset_session() clears the day map (the fresh-sim path)")

	# Two captains on the same day are independent.
	GameState.day = 200
	HailOptionsLib.reset_session()
	_reset_world()
	_check(bool(HailOptionsLib.resolve(
		HailOptionsLib.OPTION_BEFRIEND, _fleet("trader", trader_id)).get("ok", false))
		and bool(HailOptionsLib.resolve(HailOptionsLib.OPTION_BEFRIEND,
			_fleet("pirate", pirate_id)).get("ok", false)),
		"befriend is once per CAPTAIN per day, not per fleet")


# --- 9. Ask rumours: free, intel at stance ≥ +2 only -------------------------------

func _test_ask_rumours() -> void:
	_reset_world()
	var fleet := _fleet("trader", trader_id, {"dest": "seville"})
	var plain := HailOptionsLib.resolve(HailOptionsLib.OPTION_RUMOURS, fleet)
	_check(bool(plain.get("ok", false)) and not plain.has("intel"),
		"stance 0: a plain rumour, no intel payload")
	_check((plain.get("lines", []) as Array).size() == 1,
		"the plain rumour renders one line")
	_check(GameState.gold == 10000, "asking rumours is free")

	CaptainsLib.ensure(trader_id)["stance"] = 1
	_check(not HailOptionsLib.resolve(
		HailOptionsLib.OPTION_RUMOURS, fleet).has("intel"),
		"stance +1 is below the intel gate")

	CaptainsLib.ensure(trader_id)["stance"] = 2
	var intel_payload := HailOptionsLib.resolve(HailOptionsLib.OPTION_RUMOURS, fleet)
	_check(intel_payload.has("intel"),
		"stance +2 grants the one free intel")
	var intel: Dictionary = intel_payload["intel"]
	_check(str(intel.get("dest_port_id", "")) == "seville"
		and (intel.get("lanes", []) as Array) == (["lane_a"] as Array),
		"the intel payload is the fleet's dest + route lanes (no RNG)")
	_check((intel_payload.get("lines", []) as Array).size() == 2
		and str(intel_payload["lines"][1]["key"]) == "hail.rumours.result_intel",
		"the intel renders as the extra hail.rumours.result_intel line")
	_check(GameState.gold == 10000 and CaptainsLib.stance(trader_id) == 2,
		"the free intel moves no gold and no stance")


# --- 10. The modal (one boot; scene + funnel integration) ---------------------------

func _test_modal() -> void:
	# Options view: a warm trader with supplies and the intel terms.
	_reset_world()
	CaptainsLib.ensure(trader_id)["stance"] = 2
	var fleet := _fleet("trader", trader_id, {"dest": "seville"})
	var modal := HailModalScene.instantiate()
	add_child(modal)
	modal.call("setup", fleet)

	_check(modal.call("is_open"), "the modal opens over the hail")
	_check(str((modal.get_node("Panel/Title") as Label).text) \
		== I18n.fmt("hail.title", {"name": "Walter Selwyn"}),
		"the title is hail.title with the identified captain name")
	var content := modal.get_node("Panel/Scroll/Content")
	for option_id in ["ask_rumours", "buy_supplies", "intimidate", "befriend"]:
		_check(content.get_node_or_null("Row_%s" % option_id) != null,
			"the %s row renders" % option_id)
	var supplies_row := content.get_node("Row_buy_supplies")
	_check(supplies_row.get_node_or_null("StepMinus") != null
		and supplies_row.get_node_or_null("StepPlus") != null
		and supplies_row.get_node_or_null("Qty") != null,
		"the supply row carries the [- qty +] stepper")
	_check(int(modal.call("staged_qty")) == 0, "the stepper starts at 0")

	# Terms render from the authored keys, inline (80-* §4.10.2): the intel
	# terms at stance ≥ +2, the ×1.5 terms always.
	_check(_row_has_terms(content, I18n.t_key("hail.rumours.intel_terms")),
		"the rumours row renders the intel terms at stance ≥ +2")
	_check(_row_has_terms(content, I18n.t_key("hail.supplies.terms")),
		"the supply row renders the ×1.5 terms")

	modal.call("_on_step", 10)
	_check(int(modal.call("staged_qty")) == 10,
		"a +10 step stages 10 bundles")
	_check(str((supplies_row.get_node("Cost") as Label).text) == "45g",
		"the cost caption shows the ×1.5 bundle total (45g)")

	# Buying through the modal moves state only via the funnel.
	var gold_before := GameState.gold
	modal.call("_on_option_pressed", HailOptionsLib.OPTION_SUPPLIES)
	_check(modal.call("is_showing_results"),
		"an executed resolve switches the modal to its result lines")
	_check(GameState.gold == gold_before - 45
		and FleetLib.supplies("water") == 10,
		"the modal bought through HailOptions.resolve only")
	_check((modal.call("result_payload") as Dictionary).get("gold_delta", 0) == -45,
		"the result payload carries the gold delta")
	modal.call("close")
	_check(not modal.call("is_open"),
		"close() hides the modal after a purchase")

	# Rumours press (stance 2 → the intel line); the modal itself mutates nothing.
	_reset_world()
	CaptainsLib.ensure(trader_id)["stance"] = 2
	var modal2 := HailModalScene.instantiate()
	add_child(modal2)
	modal2.call("setup", fleet)
	var gold2 := GameState.gold
	modal2.call("_on_option_pressed", HailOptionsLib.OPTION_RUMOURS)
	var rumour_payload: Dictionary = modal2.call("result_payload")
	_check((rumour_payload.get("lines", []) as Array).size() == 2
		and rumour_payload.has("intel"),
		"the modal's rumours press surfaces the free intel")
	_check(GameState.gold == gold2, "the rumour press spent no gold")
	modal2.call("close")

	# Befriend press shifts stance through the funnel; close emits `closed`.
	_reset_world()
	var modal3 := HailModalScene.instantiate()
	add_child(modal3)
	modal3.call("setup", _fleet("trader", trader_id))
	var events: Array[String] = []
	modal3.closed.connect(func() -> void: events.append("closed"))
	modal3.hostile_encounter_requested.connect(
		func(_f: Dictionary) -> void: events.append("hostile"))
	modal3.call("_on_option_pressed", HailOptionsLib.OPTION_BEFRIEND)
	_check(CaptainsLib.stance(trader_id) == 1
		and str((modal3.call("result_payload") as Dictionary)
			.get("stance_delta", 0)) == "1",
		"the modal's befriend press applied STANCE_BEFRIEND")
	modal3.call("close")
	_check(events.size() == 1 and events[0] == "closed",
		"a peaceful close emits closed and never the hostile signal")

	# A refused press (befriend already used today) keeps the options view
	# with the row grayed out.
	_reset_world()
	var used_fleet := _fleet("trader", trader_id)
	HailOptionsLib.resolve(HailOptionsLib.OPTION_BEFRIEND, used_fleet)
	var modal4 := HailModalScene.instantiate()
	add_child(modal4)
	modal4.call("setup", used_fleet)
	modal4.call("_on_option_pressed", HailOptionsLib.OPTION_BEFRIEND)
	var befriend_button: Button = modal4.get_node(
		"Panel/Scroll/Content/Row_befriend/Action_befriend")
	_check(not modal4.call("is_showing_results") and befriend_button.disabled,
		"a refused befriend re-renders the options with the row grayed out")
	modal4.call("close")

	# Coaster: supplies ARE offered (the §4.11.15 role gate is trader AND
	# coaster), plus the coaster note; intimidate is its only hostile verb.
	_reset_world()
	var modal5 := HailModalScene.instantiate()
	add_child(modal5)
	modal5.call("setup", _fleet("coaster", coaster_id,
		{"cargo": {"cloth": 8}}))
	var content5: Node = modal5.get_node(
		"Panel/Scroll/Content")
	_check(content5.get_node_or_null("Row_buy_supplies") != null,
		"a coaster's modal offers the supplies row (the role gate is trader AND coaster)")
	_check(_row_has_terms(content5, I18n.t_key("hail.coaster_note")),
		"a coaster's modal renders hail.coaster_note")

	# Hostile determinism: predict the modal's own seeded draw, then assert
	# the outcome and the signal order (closed BEFORE hostile — the battle
	# opens on a closed modal).
	_reset_world()
	GameState.player["skills"]["swordplay"] = 0
	var pirate_fleet := _fleet("pirate", pirate_id, {"cargo": {"cloth": 10}})
	var rng := RandomNumberGenerator.new()
	rng.seed = HailOptionsLib.roll_seed(pirate_fleet)
	var predicted_hostile: bool = rng.randf() \
		>= HailOptionsLib.intimidate_chance(pirate_fleet)
	var modal6 := HailModalScene.instantiate()
	add_child(modal6)
	modal6.call("setup", pirate_fleet)
	var events6: Array[String] = []
	modal6.closed.connect(func() -> void: events6.append("closed"))
	modal6.hostile_encounter_requested.connect(
		func(_f: Dictionary) -> void: events6.append("hostile"))
	modal6.call("_on_option_pressed", HailOptionsLib.OPTION_INTIMIDATE)
	var payload6: Dictionary = modal6.call("result_payload")
	_check(bool(payload6.get("made_hostile", false)) == predicted_hostile,
		"the modal's drawn roll resolves as the seeded formula predicts "
		+ "(hostile = %s)" % str(predicted_hostile))
	if bool(payload6.get("made_hostile", false)):
		_check(CaptainsLib.stance(pirate_id) == -2,
			"the hostile outcome applied STANCE_INTIMIDATE_FAIL")
	else:
		_check(CaptainsLib.stance(pirate_id) == -1,
			"the winning outcome applied STANCE_INTIMIDATE_WIN")
	modal6.call("close")
	if bool(payload6.get("made_hostile", false)):
		_check(events6.size() == 2 and events6[0] == "closed"
			and events6[1] == "hostile",
			"a hostile close emits closed FIRST, then hostile_encounter_requested")
	else:
		_check(events6.size() == 1 and events6[0] == "closed",
			"a won intimidation closes without the hostile signal")


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
