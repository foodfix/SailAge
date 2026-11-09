extends Node
## T13 acceptance tests (docs/IMPLEMENT-Phase1.md T13; docs/40-SHIPS-AND-FLEET.md
## §4.3–§4.4, §5, §6, §7; docs/30-* §4.7; docs/80-* §4.7). Headless:
##
##   godot --headless res://tools/test_shipyard.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: 1 repair pricing (§4.3, all 16 types + the §4.3 worked values),
## 2 sell pricing (§4.3/§5), 3 FLEET_MAX buys (§4.3/§4.4/§6), 4 buy defaults,
## 5 no-sell rules, 6 partial repair, 7 promote, 8 refit maths (Phase-2 logic,
## disabled UI), 9 per-port stock + the three §4.7.12 row states (Phase 7),
## 10 the S6 screen itself (stock catalog, role labels, gray notes, disabled
## reasons, pickers, confirm, locale rebind, Esc/Back), 11 the S13 palace
## screen's permit row + commendation dialog (Phase 7, `80-*` §4.7.13 — screen
## cases live here because `tools/test_palace.gd` is task L's file).

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const SailingSim := preload("res://scripts/world/sailing_sim.gd")
const ShipyardScene := preload("res://scenes/port/shipyard_screen.tscn")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const PortScreenLib := preload("res://scenes/port/port_screen.gd")
const AllegianceLib := preload("res://scripts/port/allegiance.gd")

## The real palace engine, loaded by path — a `class_name` script cannot be
## const-preloaded for instance-method probes (`has_method`) in GDScript 4;
## the screen loads it the same way (`palace_screen.gd#_seam_target`).
var _palace_engine_script: Script = load("res://scripts/port/palace_engine.gd")

## The four repair prices printed in docs/40 §4.3 ("latin 3g/pt, caravel
## 20g/pt, nao 55g/pt, galleon 150g/pt").
const DOC_REPAIR_PRICES := {"latin": 3, "caravel": 20, "nao": 55, "galleon": 150}
## The §4.3 repair divisor (`ceil(base_price / 400)`).
const REPAIR_DIVISOR := 400
## Lisbon's locked stock list (`ports.json`, P-authored): 8 hulls at the
## dev-3 capital, from tier-1 starters to tier-3 flagships.
const LISBON_STOCK: Array[String] = [
	"latin", "sloop", "pinnace", "caravel", "caravela_redonda",
	"nao", "carrack", "galleon",
]
## The four unallied neutral shipyard ports (correction 11's allegiance-gray
## state): nationless China-coast/Java ports at dev floor 0.
const UNALLIED_NEUTRAL_SHIPYARDS: Array[String] = [
	"quanzhou", "hirado", "sakai", "gresik",
]
## The §4.7.15 keys this suite renders (zh/en verbatim from docs/80-*). They
## are injected into the loaded `ui_strings` for the screen sections only —
## `data/ui_strings.json` itself is orchestrator-owned (the master merges).
const SHIPYARD_UI_KEYS := {
	"shipyard.role.war": {"zh": "战舰", "en": "Warship"},
	"shipyard.role.trade": {"zh": "商船", "en": "Trade ship"},
	"shipyard.role.coastal": {"zh": "沿岸", "en": "Coastal"},
	"shipyard.tier.need_dev": {"zh": "需发展度 {dev}", "en": "Requires development {dev}"},
	"shipyard.tier.allegiance_locked": {"zh": "同盟专营:投资使其归属本国且发展度 ≥ 2 后开放", "en": "Allegiance-exclusive: align it by investing; opens at dev ≥ 2"},
}
const PALACE_UI_KEYS := {
	"palace.permit.section": {"zh": "免税证", "en": "Tax permits"},
	"palace.permit.home": {"zh": "本国免税证 — 5,000 金", "en": "Home charter — 5,000g"},
	"palace.permit.home.coverage": {"zh": "覆盖本国及同盟港:关税 5% → 0%", "en": "Covers own + aligned ports: tariff 5% → 0%"},
	"palace.permit.home.owned": {"zh": "本国免税证:已持有", "en": "Home charter: held"},
	"palace.permit.foreign": {"zh": "涉外免税证({nation})— 20,000 金", "en": "Foreign permit ({nation}) — 20,000g"},
	"palace.permit.foreign.coverage": {"zh": "覆盖该国的保护港与同盟港:关税 5% → 0%", "en": "Covers that nation's protected + aligned ports: tariff 5% → 0%"},
	"palace.permit.foreign.owned": {"zh": "涉外免税证({nation}):已持有", "en": "Foreign permit ({nation}): held"},
	"palace.permit.title_locked": {"zh": "爵位需达到骑士", "en": "Requires the title of Knight"},
	"palace.permit.rep_locked": {"zh": "声望需达到 +20", "en": "Requires reputation +20"},
	"palace.permit.void_bounty": {"zh": "悬赏在身,免税证失效;需全价重购", "en": "Void while your bounty stands; rebuy at full price"},
	"palace.permit.void_rep": {"zh": "声望低于 −20,免税证失效;需全价重购", "en": "Void below −20 reputation; rebuy at full price"},
	"palace.permit.bought": {"zh": "已购入免税证。", "en": "Permit purchased."},
	"palace.commend.title": {"zh": "褒奖令", "en": "Commendation"},
	"palace.commend.body": {"zh": "{nation}为{port}归入版图向你颁授褒奖令。", "en": "{nation} commends you for bringing {port} into its fold."},
	"palace.commend.close": {"zh": "领受", "en": "Accept with thanks"},
}

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_repair_pricing()
	_test_carpenter_discount()
	_test_sell_pricing()
	_test_fleet_max()
	_test_buy_defaults()
	_test_no_sell_rules()
	_test_partial_repair()
	_test_at_sea_minor_repair()
	_test_promote()
	_test_refit_maths()
	_test_per_port_stock()
	await _test_screen()
	await _test_palace_screen()
	_test_allegiance_guard_path()
	_report()


# --- Fixtures --------------------------------------------------------------

## A docked run with exactly `ship_ids` in the fleet, all at full durability.
## The player block carries the Phase-8 v9 keys alongside the legacy stats the
## pre-merge character.gd reads; `at_sea` drops the run into open water.
func _make_run(gold: int = 100000, ship_ids: Array = ["caravel"],
		port = "lisbon") -> void:
	GameState.gold = gold
	GameState.current_port = port
	GameState.player = {
		"nation_id": "portugal",
		"attributes": {
			"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10,
		},
		"skills": {
			"seamanship": 10, "navigation": 60, "swordplay": 0, "gunnery": 0,
			"appraisal": 0, "negotiation": 0, "cartography": 0, "rumour": 0,
		},
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 60, "luck": 10,
		},
		"xp": 0, "level": 1, "officers": [], "reputation": {"portugal": 0},
	}
	GameState.fleet = []
	for ship_id in ship_ids:
		GameState.fleet.append(FleetLib.new_ship(str(ship_id), 0))
	# §4.1b port hours (added 2026-11-02): 12:00 — the yard is open for the
	# buy/repair/sell/refit scenarios.
	GameState.world = {"clock_fraction": 0.5}


## Installs a runtime GDScript standing in for slot A's skills module, with
## `values` answered by `effective_skill` (the sailing-side guarded loader
## consumes it — `SailingSim.skills_script_override`, never set outside a
## test). Returns the double so a test can read back what it set.
func _skills_double(values: Dictionary) -> GDScript:
	var double := GDScript.new()
	double.source_code = "extends RefCounted\nstatic var values := {}\n" \
		+ "static func effective_skill(key: String) -> int:\n" \
		+ "\treturn int(values.get(key, 0))\n"
	double.reload()
	double.values = values
	SailingSim.skills_script_override = double
	return double


## Replaces the fleet with one hull of `ship_id` at a damaged durability.
func _damaged_ship(ship_id: String, durability: int, gold: int = 100000) -> void:
	_make_run(gold, [ship_id])
	GameState.fleet[0]["durability"] = durability


func _max_durability(index: int = 0) -> int:
	return FleetLib.ship_stat(GameState.fleet[index], "durability")


# --- 1. Repair pricing (§4.3) ---------------------------------------------

func _test_repair_pricing() -> void:
	_check(ShipyardLib.REPAIR_DIVISOR == REPAIR_DIVISOR,
		"the repair divisor is 400 (§4.3)")
	var all_match := true
	var printed: Array[String] = []
	for ship_type in DataLoader.ship_types_list:
		var ship_type_id := str(ship_type.get("id", ""))
		var base_price := int(ship_type.get("base_price", 0))
		var expected := int(ceil(float(base_price) / float(REPAIR_DIVISOR)))
		var actual: int = ShipyardLib.repair_cost_per_point(ship_type_id)
		printed.append("%s %dg/pt (base %dg → ceil(%d/400)=%d)" % [
			ship_type_id, actual, base_price, base_price, expected
		])
		if actual != expected:
			all_match = false
	var roster := {"war": 0, "trade": 0, "coastal": 0}
	var tiers := {1: 0, 2: 0, 3: 0}
	for ship_type in DataLoader.ship_types_list:
		var role := str(ship_type.get("role", ""))
		var tier := int(ship_type.get("tier", 0))
		if roster.has(role):
			roster[role] += 1
		if tiers.has(tier):
			tiers[tier] += 1
	_check(DataLoader.ship_types_list.size() == 16,
		"data holds all 16 ShipTypes (docs/10-* §7.3)")
	_check(tiers == {1: 4, 2: 8, 3: 4},
		"the tiers split 4/8/4 (40-* §4.3.1: latin/sloop/pinnace/galiot, "
		+ "nao/carrack/galleon/galleass at the ends): %s" % str(tiers))
	_check(roster["war"] > 0 and roster["trade"] > 0 and roster["coastal"] > 0,
		"every role enum member is used (war %d / trade %d / coastal %d)"
		% [roster["war"], roster["trade"], roster["coastal"]])
	_check(str(DataLoader.get_ship_type("galley").get("role", "")) == "war",
		"the galley keeps its pinned war role (40-* §4.3.1)")
	_check(all_match,
		"all 8 repair per-point prices equal ceil(base_price/400): %s"
		% ", ".join(printed))
	for ship_type_id in DOC_REPAIR_PRICES:
		_check(
			ShipyardLib.repair_cost_per_point(ship_type_id)
				== int(DOC_REPAIR_PRICES[ship_type_id]),
			"§4.3 worked value: %s = %dg/pt (got %dg/pt)" % [
				ship_type_id, int(DOC_REPAIR_PRICES[ship_type_id]),
				ShipyardLib.repair_cost_per_point(ship_type_id),
			]
		)
	# The two non-worked values that exercise the ceiling (7.5 → 8, 37.5 → 38).
	_check(ShipyardLib.repair_cost_per_point("sloop") == 8,
		"ceil(3000/400) = 8 (got %d)" % ShipyardLib.repair_cost_per_point("sloop"))
	_check(ShipyardLib.repair_cost_per_point("brigantine") == 38,
		"ceil(15000/400) = 38 (got %d)"
		% ShipyardLib.repair_cost_per_point("brigantine"))
	_check(ShipyardLib.repair_cost_per_point("carrack") == 100,
		"ceil(40000/400) = 100 (got %d)"
		% ShipyardLib.repair_cost_per_point("carrack"))
	_check(ShipyardLib.repair_cost_per_point("no_such_ship") == 0,
		"an unknown ship type prices at 0, never a crash")


# --- 2. Sell pricing (§4.3, §5) -------------------------------------------

func _test_sell_pricing() -> void:
	_damaged_ship("caravel", 90)
	_check(ShipyardLib.sell_price(0) == 4000,
		"caravel at full durability sells for 4000g (got %d)"
		% ShipyardLib.sell_price(0))
	_damaged_ship("caravel", 45)
	_check(ShipyardLib.sell_price(0) == 2000,
		"caravel at half durability sells for 2000g (got %d)"
		% ShipyardLib.sell_price(0))
	_check(ShipyardLib.SELL_FRACTION == 0.5, "the sell fraction is 0.5")
	_damaged_ship("galleon", 240)
	_check(ShipyardLib.sell_price(0) == 30000,
		"galleon at full durability sells for 30000g (got %d)"
		% ShipyardLib.sell_price(0))
	# §4.3 formula for every type at full durability: floor(base × 0.5).
	var all_match := true
	for ship_type in DataLoader.ship_types_list:
		var ship_type_id := str(ship_type.get("id", ""))
		_damaged_ship(ship_type_id, int(ship_type.get("durability", 0)))
		var expected := int(floor(float(ship_type.get("base_price", 0)) * 0.5))
		if ShipyardLib.sell_price(0) != expected:
			all_match = false
	_check(all_match, "every type sells at full durability for floor(base × 0.5)")
	_damaged_ship("latin", 0)
	_check(ShipyardLib.sell_price(0) == 0,
		"a 0-durability hull sells for 0g (got %d)" % ShipyardLib.sell_price(0))


# --- 3. FLEET_MAX (§4.3, §4.4, §6) ----------------------------------------

func _test_fleet_max() -> void:
	_check(ShipyardLib.FLEET_MAX == 5, "FLEET_MAX is 5 (§4.4)")
	_make_run(500000, ["caravel"])
	var bought := 0
	for i in 4:
		# §4.1b: each buy costs 3h — four in a row would run past the 18:00
		# close, so the scenario re-opens the yard between orders.
		GameState.world["clock_fraction"] = 0.5
		if ShipyardLib.buy("latin"):
			bought += 1
	_check(bought == 4, "4 buys take a 1-ship fleet to the cap (got %d)" % bought)
	_check(GameState.fleet.size() == 5,
		"the fleet is at FLEET_MAX after 5 ships (got %d)" % GameState.fleet.size())
	var gold_before := GameState.gold
	var reason: String = ShipyardLib.buy_block_reason("latin")
	var sixth: bool = ShipyardLib.buy("latin")
	_check(not sixth, "the 6th buy is refused")
	_check(reason == "shipyard.fleet_full",
		"its reason is 'shipyard.fleet_full' (got '%s')" % reason)
	_check(GameState.gold == gold_before,
		"the refused buy leaves gold untouched (%d → %d)"
		% [gold_before, GameState.gold])
	_check(GameState.fleet.size() == 5,
		"…and the fleet stays at 5 (got %d)" % GameState.fleet.size())
	# Unaffordable is the other disable reason, and it never changes state.
	_make_run(100, ["caravel"])
	gold_before = GameState.gold
	_check(ShipyardLib.buy_block_reason("caravel") == "shipyard.no_gold",
		"an unaffordable hull reports 'shipyard.no_gold'")
	_check(not ShipyardLib.buy("caravel") and GameState.gold == gold_before
		and GameState.fleet.size() == 1,
		"the unaffordable buy is refused without touching gold or fleet")
	# Exactly-affordable is allowed (§30-* §6 "gold exactly equals cost").
	_make_run(1200, ["latin"])
	_check(ShipyardLib.can_buy("latin") and ShipyardLib.buy("latin")
		and GameState.gold == 0,
		"gold exactly equal to the price buys the ship and leaves 0g")


# --- 4. Buy defaults (§4.3) ----------------------------------------------

func _test_buy_defaults() -> void:
	_make_run(100000, ["caravel"])
	var ok: bool = ShipyardLib.buy("galleon")
	var ship: Dictionary = GameState.fleet[GameState.fleet.size() - 1]
	_check(ok and GameState.fleet.size() == 2, "a bought ship joins the fleet")
	_check(str(ship.get("ship_type_id", "")) == "galleon",
		"…as the requested type (got '%s')" % str(ship.get("ship_type_id", "")))
	_check(int(ship.get("durability", -1)) == 240,
		"bought at full durability 240 (got %d)" % int(ship.get("durability", -1)))
	_check(int(ship.get("crew", -1)) == 0,
		"zero crew (got %d)" % int(ship.get("crew", -1)))
	_check(int(ship.get("provisions", -1)) == 0
		and int(ship.get("water", -1)) == 0,
		"no provisions/water (got %d/%d)" % [
			int(ship.get("provisions", -1)), int(ship.get("water", -1))
		])
	_check(int(ship.get("cannons", -1)) == 0,
		"no cannons (got %d)" % int(ship.get("cannons", -1)))
	_check((ship.get("cargo", {}) as Dictionary).is_empty(),
		"empty cargo hold (got %s)" % str(ship.get("cargo", {})))
	_check(FleetLib.used_capacity(ship) == 0,
		"the new hull carries nothing (used_capacity %d)"
		% FleetLib.used_capacity(ship))
	_check(GameState.gold == 100000 - 60000,
		"the price was paid once (gold %d)" % GameState.gold)


# --- 5. No-sell rules (§4.3, §6) -----------------------------------------

func _test_no_sell_rules() -> void:
	# Flagship: never sellable, never offered.
	_make_run(100000, ["caravel", "sloop"])
	_check(ShipyardLib.sell_block_reason(0) == "shipyard.no_sell_flagship",
		"the flagship reports 'shipyard.no_sell_flagship' (got '%s')"
		% ShipyardLib.sell_block_reason(0))
	var gold_before := GameState.gold
	_check(not ShipyardLib.can_sell(0) and not ShipyardLib.sell(0),
		"selling the flagship is refused")
	_check(GameState.fleet.size() == 2 and GameState.gold == gold_before,
		"…with fleet and gold unchanged")

	# Last ship: refused (§6: only sinking may empty the fleet).
	_make_run(100000, ["caravel"])
	_check(ShipyardLib.sell_block_reason(0) == "shipyard.no_sell_last",
		"a one-ship fleet reports 'shipyard.no_sell_last' (got '%s')"
		% ShipyardLib.sell_block_reason(0))
	_check(not ShipyardLib.sell(0) and GameState.fleet.size() == 1,
		"the last ship cannot be sold")

	# Cargo aboard blocks the sale.
	_make_run(100000, ["caravel", "sloop"])
	GameState.fleet[1]["cargo"] = {"wine": 5}
	_check(ShipyardLib.sell_block_reason(1) == "shipyard.cargo_not_empty",
		"a loaded escort reports 'shipyard.cargo_not_empty' (got '%s')"
		% ShipyardLib.sell_block_reason(1))
	_check(not ShipyardLib.sell(1) and GameState.fleet.size() == 2,
		"a loaded hull cannot be sold")
	GameState.fleet[1]["cargo"] = {}
	_check(ShipyardLib.can_sell(1), "the same hull sells once her hold is empty")
	# §4.2 pools goods + provisions + water into one hold, and `add_supplies`
	# legitimately fills an escort once the flagship is full. Selling then must
	# not silently vaporise those pooled units (§6 "never silently"), so the
	# §4.3 "cargo aboard must be 0" gate covers supplies too.
	GameState.fleet[1]["provisions"] = 12
	_check(ShipyardLib.sell_block_reason(1) == "shipyard.cargo_not_empty",
		"provisions aboard count as cargo for the sale gate (§4.2 pooling)")
	GameState.fleet[1]["provisions"] = 0
	GameState.fleet[1]["water"] = 12
	_check(not ShipyardLib.can_sell(1),
		"water aboard blocks the sale too (pooled hold, §4.2)")
	GameState.fleet[1]["water"] = 0
	gold_before = GameState.gold
	var price := ShipyardLib.sell_price(1)
	_check(ShipyardLib.sell(1), "the empty escort sells")
	_check(GameState.fleet.size() == 1 and GameState.fleet[0]["ship_type_id"] == "caravel",
		"only the caravel remains (got %d ships)" % GameState.fleet.size())
	_check(GameState.gold == gold_before + price,
		"the formula price %dg was paid (gold %d → %d)"
		% [price, gold_before, GameState.gold])


# --- 6. Partial repair (§4.3, §6) ----------------------------------------

func _test_partial_repair() -> void:
	# 7 points on a caravel: 7 × 20 = 140g, exactly +7 durability.
	_damaged_ship("caravel", 50, 100000)
	_check(ShipyardLib.max_repair_points(0) == 40,
		"a 50/90 hull can take 40 points (got %d)"
		% ShipyardLib.max_repair_points(0))
	_check(ShipyardLib.repair_cost(0, 7) == 140,
		"7 caravel points cost 140g (got %d)" % ShipyardLib.repair_cost(0, 7))
	var gold_before := GameState.gold
	_check(ShipyardLib.repair(0, 7), "a 7-point partial repair succeeds")
	_check(int(GameState.fleet[0]["durability"]) == 57,
		"it restores exactly 7 durability (got %d)"
		% int(GameState.fleet[0]["durability"]))
	_check(GameState.gold == gold_before - 140,
		"it charges exactly 140g (gold %d → %d)" % [gold_before, GameState.gold])

	# Capped by damage.
	_damaged_ship("caravel", 50)
	_check(not ShipyardLib.can_repair(0, 41)
		and ShipyardLib.repair_block_reason(0, 41) == "shipyard.invalid_points",
		"repairing past the damage is rejected")
	_check(ShipyardLib.max_repair_points(0) == 40
		and ShipyardLib.can_repair(0, 40),
		"repairing exactly the damage is allowed")
	_check(ShipyardLib.repair(0, 40)
		and int(GameState.fleet[0]["durability"]) == 90,
		"a full-damage repair lands exactly on max durability")

	# Capped by gold: the price is unchanged and nothing mutates.
	_damaged_ship("caravel", 50, 139)
	_check(not ShipyardLib.can_repair(0, 7)
		and ShipyardLib.repair_block_reason(0, 7) == "shipyard.no_gold",
		"139g cannot pay the 140g repair ('shipyard.no_gold')")
	_check(not ShipyardLib.repair(0, 7)
		and int(GameState.fleet[0]["durability"]) == 50
		and GameState.gold == 139,
		"the refused repair changes neither durability nor gold")
	GameState.gold = 140
	_check(ShipyardLib.repair(0, 7) and GameState.gold == 0,
		"exactly-affordable repair is allowed and leaves 0g")

	# 0 points / no damage / bad index.
	_damaged_ship("caravel", 50)
	_check(not ShipyardLib.can_repair(0, 0)
		and ShipyardLib.repair_block_reason(0, 0) == "shipyard.invalid_points",
		"a 0-point repair is rejected (§6)")
	_check(not ShipyardLib.repair(0, -3), "a negative repair is rejected")
	_damaged_ship("caravel", 90)
	_check(ShipyardLib.max_repair_points(0) == 0
		and not ShipyardLib.can_repair(0, 1),
		"an undamaged hull has nothing to repair")
	_check(ShipyardLib.repair_block_reason(5, 1) == "shipyard.no_selection"
		and not ShipyardLib.can_repair(5, 1),
		"an out-of-range index reports 'shipyard.no_selection'")
	# Every type, 1 point = its per-point price.
	var all_match := true
	for ship_type in DataLoader.ship_types_list:
		var ship_type_id := str(ship_type.get("id", ""))
		_damaged_ship(ship_type_id, 1)
		if ShipyardLib.repair_cost(0, 1) != ShipyardLib.repair_cost_per_point(ship_type_id):
			all_match = false
	_check(all_match, "1 point costs exactly the per-point price for every type")


# --- 6b. §4.3 carpenter discount (Phase 8) ---------------------------------

## With a carpenter in post the whole fee is ×`(1 − floor(carpentry/20)/100)`
## (a −`floor(carpentry/20)`% discount), composed after the §4.9.2 count-title
## ×0.8 and **floored once at the end of the whole transaction**. The
## carpentry value is the in-post carpenter's contribution
## (`Skills.effective_skill("carpentry")` — the double stands in for slot A's
## module).
func _test_carpenter_discount() -> void:
	# ×1.00 / ×0.99 / ×0.95 at carpentry 0 / 20 / 100 (the −skill/20% table).
	for row in [[0, 1.0], [20, 0.99], [100, 0.95]]:
		_damaged_ship("caravel", 50)
		_skills_double({"carpentry": int(row[0])})
		_check(is_equal_approx(SailingSim.carpenter_discount(), float(row[1])),
			"carpentry %d → fee multiplier ×%.2f (got %.4f)" % [
				int(row[0]), float(row[1]), SailingSim.carpenter_discount()])
		# 7 caravel points = raw 140 → floor(140 × multiplier), floored once.
		var expected := int(floor(140.0 * float(row[1])))
		_check(ShipyardLib.repair_cost(0, 7) == expected,
			"carpentry %d: 7 caravel points cost floor(140 × %.2f) = %dg (got %d)" % [
				int(row[0]), float(row[1]), expected, ShipyardLib.repair_cost(0, 7)])
	SailingSim.skills_script_override = null

	# Fractional cases floor exactly once at the end (not per factor): nao
	# 1 point = 55 raw; carpentry 41 → −floor(41/20)% = −2% →
	# floor(55 × 0.98) = 53.
	_damaged_ship("nao", 100)
	_skills_double({"carpentry": 41})
	_check(ShipyardLib.repair_cost(0, 1) == 53,
		"nao 1 point at carpentry 41: floor(55 × 0.98) = 53, floored once (got %d)"
		% ShipyardLib.repair_cost(0, 1))
	SailingSim.skills_script_override = null

	# Without the double (no skills module pre-merge), the discount is ×1.00:
	# the fee is the plain transaction.
	_damaged_ship("caravel", 50)
	SailingSim.skills_script_override = null
	_check(is_equal_approx(SailingSim.carpenter_discount(), 1.0),
		"no carpenter in post → ×1.00 (got %.4f)" % SailingSim.carpenter_discount())
	_check(ShipyardLib.repair_cost(0, 7) == 140,
		"the no-carpenter fee is the raw 140g (got %d)" % ShipyardLib.repair_cost(0, 7))


# --- 6c. §4.5 at-sea minor repair (Phase 8) --------------------------------

## Carpentry ≥ 60 → +10 durability to one fleet ship for
## `floor(10 × per-point rate × carpenter discount)` gold, once per fleet-day,
## no clock cost, at sea only.
func _test_at_sea_minor_repair() -> void:
	# The gate is the effective in-post carpentry; 59 refuses, 60 opens.
	# Durability 70 so two +10 repairs fit below the 90 max.
	_make_run(100000, ["caravel"])
	GameState.current_port = null
	GameState.fleet[0]["durability"] = 70
	_skills_double({"carpentry": 59})
	_check(not SailingSim.at_sea_repair_gate_met(),
		"carpentry 59 is below the at-sea gate")
	_check(not SailingSim.at_sea_repair(),
		"below the gate the repair is refused (state untouched)")
	_check(int(GameState.fleet[0]["durability"]) == 70 and GameState.gold == 100000,
		"the refused repair changes nothing")
	_skills_double({"carpentry": 60})
	_check(SailingSim.at_sea_repair_gate_met(), "carpentry 60 opens the gate")

	# The fee: 10 × ceil(8000/400) = 200 raw, ×0.97 at carpentry 60 → 194.
	_check(SailingSim.at_sea_repair_fee(0) == 194,
		"caravel fee at carpentry 60: floor(200 × 0.97) = 194 (got %d)"
		% SailingSim.at_sea_repair_fee(0))
	_check(SailingSim.at_sea_repair_available(0),
		"a damaged hull at sea with a gated carpenter is repairable")
	var clock_before := float(GameState.world["clock_fraction"])
	_check(SailingSim.at_sea_repair(), "the at-sea repair succeeds")
	_check(int(GameState.fleet[0]["durability"]) == 80,
		"it restores exactly +10 durability (70 → %d)"
		% int(GameState.fleet[0]["durability"]))
	_check(GameState.gold == 100000 - 194,
		"it charges the discounted fee (gold → %d)" % GameState.gold)
	_check(is_equal_approx(float(GameState.world["clock_fraction"]), clock_before),
		"it costs no clock")

	# Once per fleet-day: a second call the same day refuses; the next day the
	# guard reopens.
	_check(not SailingSim.at_sea_repair(),
		"a second repair the same fleet-day is refused")
	_check(int(GameState.fleet[0]["durability"]) == 80 and GameState.gold == 100000 - 194,
		"the refused second repair changes nothing")
	GameState.day += 1
	_check(SailingSim.at_sea_repair(),
		"the next fleet-day the repair works again")
	_check(int(GameState.fleet[0]["durability"]) == 90,
		"the second repair clamps at the hull's max (90 → %d)"
		% int(GameState.fleet[0]["durability"]))

	# Insufficient gold refuses (fee 194, purse 100).
	_make_run(100, ["caravel"])
	GameState.current_port = null
	GameState.fleet[0]["durability"] = 80
	GameState.day = 1
	SailingSim.at_sea_repair_day = -1
	_skills_double({"carpentry": 60})
	_check(not SailingSim.at_sea_repair_available(0)
		and not SailingSim.at_sea_repair(),
		"gold under the fee refuses the repair")
	_check(int(GameState.fleet[0]["durability"]) == 80 and GameState.gold == 100,
		"the refused repair changes nothing")

	# An undamaged hull has nothing to repair.
	_make_run(100000, ["caravel"])
	GameState.current_port = null
	SailingSim.at_sea_repair_day = -1
	_skills_double({"carpentry": 60})
	_check(not SailingSim.at_sea_repair_available(0),
		"a full-durability hull is not repairable")

	# In port the action is never available (it is an at-sea rule).
	_make_run(100000, ["caravel"])
	GameState.fleet[0]["durability"] = 80
	GameState.day = 1
	SailingSim.at_sea_repair_day = -1
	_skills_double({"carpentry": 60})
	_check(not SailingSim.at_sea_repair_available(0)
		and not SailingSim.at_sea_repair(),
		"docked, the at-sea repair is refused")
	SailingSim.skills_script_override = null


# --- 7. Promote (§4.4) ---------------------------------------------------

func _test_promote() -> void:
	_make_run(12345, ["caravel", "sloop", "nao"])
	var gold_before := GameState.gold
	_check(not ShipyardLib.can_promote(0),
		"the flagship itself cannot be promoted")
	_check(ShipyardLib.can_promote(2), "a docked escort can be promoted")
	_check(ShipyardLib.promote(2), "promote(2) succeeds")
	_check(str(GameState.fleet[0]["ship_type_id"]) == "nao",
		"the promoted hull is fleet[0] (got '%s')"
		% str(GameState.fleet[0]["ship_type_id"]))
	_check(str(GameState.fleet[1]["ship_type_id"]) == "caravel"
		and str(GameState.fleet[2]["ship_type_id"]) == "sloop",
		"the other hulls keep their relative order (got %s/%s)" % [
			str(GameState.fleet[1]["ship_type_id"]),
			str(GameState.fleet[2]["ship_type_id"]),
		])
	_check(GameState.gold == gold_before,
		"promotion is free (gold %d → %d)" % [gold_before, GameState.gold])
	_check(GameState.fleet.size() == 3,
		"promotion never changes the fleet size (got %d)" % GameState.fleet.size())
	# Promoting the middle hull of the new order.
	_check(ShipyardLib.promote(2)
		and str(GameState.fleet[0]["ship_type_id"]) == "sloop"
		and str(GameState.fleet[1]["ship_type_id"]) == "nao"
		and str(GameState.fleet[2]["ship_type_id"]) == "caravel",
		"a second promote keeps a stable order (%s/%s/%s)" % [
			str(GameState.fleet[0]["ship_type_id"]),
			str(GameState.fleet[1]["ship_type_id"]),
			str(GameState.fleet[2]["ship_type_id"]),
		])

	# Port-only: `current_port == null` (at sea) refuses.
	GameState.current_port = null
	_check(not ShipyardLib.can_promote(1),
		"promotion is refused at sea (current_port == null)")
	_check(not ShipyardLib.promote(1)
		and str(GameState.fleet[0]["ship_type_id"]) == "sloop",
		"…and the order is untouched")
	GameState.current_port = ""
	_check(not ShipyardLib.can_promote(1), "an empty current_port is at sea too")


# --- 8. Refit maths (§4.3; the Phase-1 UI row stays disabled) -------------

func _test_refit_maths() -> void:
	_check(ShipyardLib.CANNON_PRICE == 100, "a cannon costs 100g")
	_check(ShipyardLib.CANNON_SELLBACK_PRICE == 50, "a cannon sells back for 50g")
	_check(ShipyardLib.CANNON_CARGO_UNITS == 5,
		"a cannon occupies 5 cargo units (also Fleet.CANNON_CARGO_UNITS)")
	_check(ShipyardLib.refit_cost(6) == 600, "6 cannons cost 600g")
	_check(ShipyardLib.refit_sellback(6) == 300, "6 cannons sell back for 300g")
	_check(ShipyardLib.refit_cargo_units(6) == 30,
		"6 cannons occupy 30 cargo units")
	_check(ShipyardLib.refit_cost(0) == 0 and ShipyardLib.refit_cost(-2) == 0,
		"non-positive refits cost nothing")

	# Caravel: armament_slots 6, capacity 120 → the slots are the binding cap.
	_make_run(100000, ["caravel"])
	_check(ShipyardLib.max_refit(0) == 6,
		"a caravel's refit cap is armament_slots 6 (got %d)"
		% ShipyardLib.max_refit(0))
	_check(ShipyardLib.can_refit(0, 6) and not ShipyardLib.can_refit(0, 7),
		"6 cannons fit a caravel; 7 do not")
	var cargo_before := FleetLib.used_capacity(GameState.fleet[0])
	var gold_before := GameState.gold
	_check(ShipyardLib.refit(0, 6), "the refit itself succeeds")
	_check(int(GameState.fleet[0]["cannons"]) == 6,
		"…and stores 6 cannons (got %d)" % int(GameState.fleet[0]["cannons"]))
	_check(GameState.gold == gold_before - 600,
		"…charging 600g (gold %d → %d)" % [gold_before, GameState.gold])
	_check(FleetLib.used_capacity(GameState.fleet[0]) == cargo_before + 30,
		"…and consuming 30 cargo units (%d → %d)" % [
			cargo_before, FleetLib.used_capacity(GameState.fleet[0])
		])
	_check(ShipyardLib.max_refit(0) == 0,
		"a fully-armed caravel has no spare slots")
	_check(not ShipyardLib.can_refit(0, 1), "…so no further refit is allowed")
	# Slot cap per type.
	for ship_type in DataLoader.ship_types_list:
		var ship_type_id := str(ship_type.get("id", ""))
		_make_run(1000000, [ship_type_id])
		var slots := int(ship_type.get("armament_slots", 0))
		var cap := mini(slots, int(ship_type.get("capacity", 0)) / 5)
		if ShipyardLib.max_refit(0) != cap:
			_check(false, "%s refit cap is %d (got %d)" % [
				ship_type_id, cap, ShipyardLib.max_refit(0)
			])
		elif ShipyardLib.can_refit(0, cap + 1):
			_check(false, "%s refuses more than its cap" % ship_type_id)
	_check(true, "every type caps refits at min(armament_slots, capacity/5)")
	# Cargo room binds: a full caravel cannot take cannons.
	_make_run(100000, ["caravel"])
	FleetLib.add_goods("wine", 120)
	_check(ShipyardLib.max_refit(0) == 0
		and not ShipyardLib.can_refit(0, 1),
		"a full hold leaves no room for cannon cargo")
	# Unaffordable refits are refused.
	_make_run(99, ["latin"])
	_check(ShipyardLib.max_refit(0) == 2
		and not ShipyardLib.can_refit(0, 1),
		"99g cannot pay for a 100g cannon")


# --- 9. Per-port stock & the three row states (Phase 7; 40-* §4.3.1) ------

func _test_per_port_stock() -> void:
	# Data shape: every shipyard facility is the Phase-7 id-list form, ≥2 ≤8
	# valid ids; equipment_stock ≥2 known non-rare items at the same ports.
	var stock_ports := 0
	var lists_valid := true
	var equipment_ports := 0
	var equipment_valid := true
	for port in DataLoader.ports_list:
		var data: Dictionary = port
		var shipyard = data.get("facilities", {}).get("shipyard", null)
		if shipyard is Array:
			stock_ports += 1
			if (shipyard as Array).size() < 2 or (shipyard as Array).size() > 8:
				lists_valid = false
			for id in shipyard:
				if DataLoader.get_ship_type(str(id)).is_empty():
					lists_valid = false
		var stock = data.get("facilities", {}).get("equipment_stock", null)
		if stock is Array:
			equipment_ports += 1
			if (stock as Array).size() < 2:
				equipment_valid = false
			for id in stock:
				if DataLoader.get_equipment(str(id)).is_empty() \
						or ShipyardLib.is_rare_equipment(str(id)):
					equipment_valid = false
	_check(stock_ports == 109,
		"109 shipyard ports carry id lists (got %d)" % stock_ports)
	_check(lists_valid, "every shipyard list holds 2–8 valid ship type ids")
	_check(equipment_ports == 109,
		"109 ports carry equipment_stock lists (got %d)" % equipment_ports)
	_check(equipment_valid,
		"every equipment_stock holds ≥2 known, non-rare items (60-* §4.11.13)")
	# The rare four are drop-only: never in any stock list, and every named
	# pirate's drop references one of them (correction 10).
	var rare_ids := {}
	for item in DataLoader.equipment_list:
		if bool((item as Dictionary).get("rare", false)):
			rare_ids[str((item as Dictionary).get("id", ""))] = true
	_check(rare_ids.size() == 4,
		"exactly 4 items carry rare: true (got %s)" % str(rare_ids))
	var drops_ok := true
	for pirate in DataLoader.named_pirates_list:
		var drop := str((pirate as Dictionary).get("drop", ""))
		if not rare_ids.has(drop):
			drops_ok = false
	_check(drops_ok and DataLoader.named_pirates_list.size() == 4,
		"all 4 named_pirate drops reference rare items")

	# --- stock accessors ---------------------------------------------------
	_make_run(50000, ["caravel"], "lisbon")
	var lisbon_stock: Array[String] = ShipyardLib.shipyard_stock("lisbon")
	_check(lisbon_stock.size() == LISBON_STOCK.size()
		and _same_set(lisbon_stock, LISBON_STOCK),
		"lisbon stocks her locked 8-hull list (got %s)" % str(lisbon_stock))
	_check(_same_set(ShipyardLib.shipyard_stock(), lisbon_stock),
		"shipyard_stock() resolves the docked port")
	_check(not ShipyardLib.shipyard_stock("lisbon").has("junk")
		and ShipyardLib.shipyard_stock("quanzhou").has("junk"),
		"regional flavor: no junk at lisbon, junk at the China-coast neutral")
	_make_run(50000, ["caravel"], "")
	_check(ShipyardLib.shipyard_stock().size() == 16,
		"standalone (no docked port) falls back to the full catalog")

	# --- effective dev / alignment guard defaults (80-* §4.16) ---------------
	_make_run(50000, ["caravel"], "lisbon")
	_check(ShipyardLib.effective_dev("lisbon") == 3,
		"guard default: lisbon's authored floor is dev 3 (got %d)"
		% ShipyardLib.effective_dev("lisbon"))
	_check(ShipyardLib.effective_dev("bordeaux") == 1
		and ShipyardLib.effective_dev("quanzhou") == 0,
		"guard default: authored floors (bordeaux 1, quanzhou 0)")
	_check(ShipyardLib.effective_alignment("lisbon") == "portugal"
		and ShipyardLib.effective_alignment("quanzhou") == "",
		"guard default: alignment = the data nation_id (neutral stays \"\")")
	_check(not ShipyardLib.is_unallied_neutral("lisbon")
		and not ShipyardLib.is_unallied_neutral("bordeaux"),
		"sovereign ports are never allegiance-gray")
	for neutral_port in UNALLIED_NEUTRAL_SHIPYARDS:
		if not ShipyardLib.is_unallied_neutral(neutral_port):
			_check(false, "%s should be an unallied neutral" % neutral_port)
	_check(true, "the 4 neutral shipyards (quanzhou/hirado/sakai/gresik) "
		+ "are unallied")

	# --- the three row states ----------------------------------------------
	# (1) available at a dev-3 capital even for tier-3 flagships:
	_check(ShipyardLib.row_state("lisbon", "galleon") == ShipyardLib.ROW_AVAILABLE
		and ShipyardLib.row_state("lisbon", "latin") == ShipyardLib.ROW_AVAILABLE,
		"at a dev-3 capital tier-3 and tier-1 rows are both available")
	_check(ShipyardLib.row_note_key("lisbon", "galleon").is_empty(),
		"…with no lock note")
	# (2) tier-gray at a dev-1 port: only tier-1 hulls stay buyable.
	_check(ShipyardLib.row_state("bordeaux", "pinnace") == ShipyardLib.ROW_AVAILABLE
		and ShipyardLib.row_state("bordeaux", "sloop") == ShipyardLib.ROW_AVAILABLE,
		"at a dev-1 port the tier-1 stock is available")
	for above_tier in ["caravel", "caravela_redonda", "nao", "carrack"]:
		if ShipyardLib.row_state("bordeaux", above_tier) != ShipyardLib.ROW_TIER_GRAY:
			_check(false, "bordeaux's %s should be tier-gray" % above_tier)
	_check(ShipyardLib.row_note_key("bordeaux", "caravel")
		== "shipyard.tier.need_dev",
		"tier-gray rows carry the 需发展度 note key")
	# (3) allegiance-gray: the unallied neutral's whole list is locked.
	for hull_id in ShipyardLib.shipyard_stock("quanzhou"):
		if ShipyardLib.row_state("quanzhou", hull_id) \
				!= ShipyardLib.ROW_ALLEGIANCE_GRAY:
			_check(false, "quanzhou's %s should be allegiance-gray" % hull_id)
	_check(ShipyardLib.row_note_key("quanzhou", "junk")
		== "shipyard.tier.allegiance_locked",
		"allegiance-gray rows carry the 同盟专营 note key")

	# --- buy gating through the states --------------------------------------
	# dev-1 port: tier-1 buys, tier-2/3 refused with the dev note.
	_make_run(100000, ["latin"], "bordeaux")
	_check(ShipyardLib.buy_block_reason("latin") == "ui.not_available",
		"latin is not in bordeaux's stock ('ui.not_available')")
	_check(ShipyardLib.buy_block_reason("pinnace").is_empty()
		and ShipyardLib.buy("pinnace"),
		"a stocked tier-1 hull buys at the dev-1 port")
	_check(ShipyardLib.buy_block_reason("caravel") == "shipyard.tier.need_dev"
		and not ShipyardLib.buy("caravel")
		and GameState.fleet.size() == 2,
		"a stocked tier-2 hull is refused with 'shipyard.tier.need_dev'")
	var gold_before := GameState.gold
	_check(not ShipyardLib.buy("nao") and GameState.gold == gold_before,
		"a stocked tier-3 hull cannot be bought at dev 1 either")
	_check(ShipyardLib.buy_block_reason("nao") == "shipyard.tier.need_dev",
		"the tier-3 refusal carries the dev note")
	_check(ShipyardLib.buy_block_reason("junk") == "ui.not_available",
		"an unstocked hull is 'ui.not_available' even when affordable")

	# dev-3 capital: the tier-3 flagship buys (decision 23's §2.2 done-when).
	_make_run(60000, ["latin"], "lisbon")
	_check(ShipyardLib.buy_block_reason("galleon").is_empty()
		and ShipyardLib.buy("galleon")
		and GameState.gold == 0 and GameState.fleet.size() == 2,
		"a dev-3 capital sells the 60,000g tier-3 galleon")

	# unallied neutral: the allegiance gate refuses everything.
	_make_run(1000000, ["latin"], "quanzhou")
	_check(ShipyardLib.buy_block_reason("latin")
			== "shipyard.tier.allegiance_locked"
		and not ShipyardLib.buy("latin")
		and GameState.fleet.size() == 1,
		"at an unallied neutral every hull is refused with the lock note")

	# --- equipment gating (60-* §4.11.13 + the same three states) ----------
	_make_run(5000, ["latin"], "lisbon")
	var weapon_ids: Array[String] = []
	for item in ShipyardLib.equipment_list("weapon"):
		weapon_ids.append(str((item as Dictionary).get("id", "")))
	_check(_same_set(weapon_ids, ["eq_zweihander", "eq_cutlass"] as Array[String])
		and weapon_ids.size() == 2,
		"lisbon's weapon list is her stocked pair (got %s)" % str(weapon_ids))
	_check(ShipyardLib.equip_block_reason("weapon", "eq_rapier")
			== "ui.not_available",
		"an item off this port's equipment_stock is 'ui.not_available'")
	_check(ShipyardLib.equip_block_reason("weapon", "eq_zweihander").is_empty()
		and ShipyardLib.equip("weapon", "eq_zweihander")
		and GameState.gold == 200,
		"the dev-3 capital sells the 4,800g tier-3 zweihander")
	_check(ShipyardLib.equip_block_reason("weapon", "eq_khair_scimitar")
			== "ui.not_available",
		"the rare scimitar is refused even at the dev-3 capital (drop-only)")
	for slot in ShipyardLib.PLAYER_SLOTS + ShipyardLib.SHIP_SLOTS:
		for item in ShipyardLib.equipment_list(slot):
			if ShipyardLib.is_rare_equipment(str((item as Dictionary).get("id", ""))):
				_check(false, "a rare item leaked into the %s list" % slot)
	_check(true, "no slot list at lisbon ever carries a rare item")
	# tier-gray equipment: dev-1 valetta stocks a tier-2 medallion.
	_make_run(5000, ["latin"], "valetta")
	_check(ShipyardLib.equip_block_reason("armor", "eq_saint_medallion")
			== "shipyard.tier.need_dev"
		and not ShipyardLib.equip("armor", "eq_saint_medallion"),
		"a tier-2 item is refused at the dev-1 port with the dev note")
	_check(ShipyardLib.equip_block_reason("armor", "eq_breastplate").is_empty()
		and ShipyardLib.equip("armor", "eq_breastplate"),
		"…while her tier-1 armor buys")
	# allegiance-gray equipment at the unallied neutral.
	_make_run(5000, ["latin"], "quanzhou")
	_check(ShipyardLib.equip_block_reason("weapon", "eq_cutlass")
			== "shipyard.tier.allegiance_locked"
		and not ShipyardLib.equip("weapon", "eq_cutlass"),
		"the neutral's stocked cutlass is allegiance-locked too")


## Order-insensitive string-array comparison.
func _same_set(a: Array[String], b: Array[String]) -> bool:
	if a.size() != b.size():
		return false
	for value in a:
		if not b.has(value):
			return false
	return true


# --- 10. The S6 screen ---------------------------------------------------

func _test_screen() -> void:
	var locale_before: String = GameState.locale
	GameState.locale = "en"
	_make_run(50000, ["caravel", "sloop"])
	var screen = ShipyardScene.instantiate()
	screen.route_to_hub = false
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame

	# Catalog: the port's stock list (lisbon's 8 locked hulls), not the
	# global 16-type roster — Phase 7's per-port rows (40-* §4.3.1).
	var catalog: Control = screen.get_node(
		"CatalogPanel/CatalogScroll/CatalogRows")
	_check(catalog.get_child_count() == 8,
		"the catalog mirrors lisbon's 8-hull stock list (got %d)"
		% catalog.get_child_count())
	_check(screen.buy_button("galleon") != null
		and screen.buy_button("junk") == null,
		"stocked hulls have Buy buttons and unstocked ones have none")
	# Role labels: the §4.7.15 keys are MERGED now, so rows localise — the
	# raw enum token survives only as the documented fallback (exercised
	# below with fixture-local key absence, never the shipped data).
	var galleon_role: Label = catalog.get_node("Catalog_galleon/Role")
	_check(galleon_role.text == I18n.t_key("shipyard.role.war"),
		"the merged role key localises the galleon (%s)" % galleon_role.text)
	_check(catalog.get_node("Catalog_latin/Role").text
			== I18n.t_key("shipyard.role.coastal"),
		"the latin carries the coastal role label (%s)"
		% (catalog.get_node("Catalog_latin/Role") as Label).text)
	_check(catalog.get_node("Catalog_caravel/Role").text
			== I18n.t_key("shipyard.role.trade"),
		"the caravel carries the trade role label (%s)"
		% (catalog.get_node("Catalog_caravel/Role") as Label).text)
	# zh pass (40-* §4.3.1): 战舰 / 商船 / 沿岸 — plus the zh tier note
	# 需发展度 {dev} at the dev-1 port.
	GameState.locale = "zh"
	screen.rebuild()
	await get_tree().process_frame
	var zh_roles := "%s|%s|%s" % [
		(catalog.get_node("Catalog_galleon/Role") as Label).text,
		(catalog.get_node("Catalog_caravel/Role") as Label).text,
		(catalog.get_node("Catalog_latin/Role") as Label).text]
	_check(zh_roles == "%s|%s|%s" % [I18n.t_key("shipyard.role.war"),
			I18n.t_key("shipyard.role.trade"),
			I18n.t_key("shipyard.role.coastal")],
		"the zh roles render 战舰/商船/沿岸 (%s)" % zh_roles)
	GameState.current_port = "bordeaux"
	screen.rebuild()
	await get_tree().process_frame
	var zh_note: Label = catalog.get_node_or_null("Catalog_caravel/Note")
	_check(zh_note != null
		and zh_note.text == I18n.fmt("shipyard.tier.need_dev", {"dev": 1}),
		"the zh tier note renders 需发展度 1 (%s)"
		% (zh_note.text if zh_note != null else "<absent>"))
	GameState.current_port = "lisbon"
	# The documented fallback, fixture-locally: with the role keys stripped
	# the rows show the raw schema token (war/trade/coastal), never "<key>".
	var role_stash := _stash_ui_keys(["shipyard.role.war",
		"shipyard.role.trade", "shipyard.role.coastal"])
	screen.rebuild()
	await get_tree().process_frame
	_check((catalog.get_node("Catalog_galleon/Role") as Label).text == "war",
		"with the keys stripped the role falls back to the data token (got '%s')"
		% (catalog.get_node("Catalog_galleon/Role") as Label).text)
	_check((catalog.get_node("Catalog_latin/Role") as Label).text == "coastal",
		"the stripped latin carries the coastal role token")
	_unstash_ui_keys(role_stash)
	GameState.locale = "en"
	screen.rebuild()
	await get_tree().process_frame
	_check((catalog.get_node("Catalog_galleon/Role") as Label).text
			== I18n.t_key("shipyard.role.war"),
		"restoring the keys re-localises the roles (%s)"
		% (catalog.get_node("Catalog_galleon/Role") as Label).text)
	_inject_keys(SHIPYARD_UI_KEYS)
	screen.rebuild()
	await get_tree().process_frame
	# No unresolved key may ever reach a label (`I18n.t_key` returns "<key>"
	# for a missing entry).
	var unresolved: Array[String] = []
	_collect_unresolved(screen, unresolved)
	_check(unresolved.is_empty(),
		"no visible label prints a raw <key> (found %s)" % str(unresolved))
	# At 2/5 ships and 50,000g the cheap hulls are buyable, the galleon is not.
	_check(not screen.buy_button("latin").disabled,
		"the affordable latin Buy button is enabled")
	_check(screen.buy_button("galleon").disabled,
		"the unaffordable galleon Buy button is disabled")
	_check(screen.buy_button("galleon").tooltip_text.contains(
			I18n.t_key("shipyard.no_gold")),
		"…and its tooltip states 'shipyard.no_gold' (%s)"
		% screen.buy_button("galleon").tooltip_text)

	# The three §4.7.12 states on screen, keyed by the docked port.
	# (2) tier-gray at the dev-1 port: 需发展度 note, Buy disabled.
	GameState.current_port = "bordeaux"
	screen.rebuild()
	await get_tree().process_frame
	var caravel_buy: Button = screen.buy_button("caravel")
	_check(caravel_buy != null and caravel_buy.disabled,
		"at the dev-1 port the stocked tier-2 caravel is grayed")
	_check(caravel_buy.tooltip_text.contains(I18n.fmt(
			"shipyard.tier.need_dev", {"dev": 1})),
		"…with the 需发展度 1 note as the tooltip (%s)" % caravel_buy.tooltip_text)
	var caravel_note: Label = catalog.get_node("Catalog_caravel/Note")
	_check(caravel_note.visible
		and caravel_note.text == I18n.fmt("shipyard.tier.need_dev", {"dev": 1}),
		"…and the row renders the note line (%s)" % caravel_note.text)
	_check(not screen.buy_button("sloop").disabled,
		"…while the tier-1 sloop stays buyable")
	_check(catalog.get_node_or_null("Catalog_sloop/Note") == null,
		"available rows carry no note")
	# (3) allegiance-gray at the unallied neutral: the whole list locked.
	GameState.current_port = "quanzhou"
	screen.rebuild()
	await get_tree().process_frame
	var all_locked := true
	for hull_id in ShipyardLib.shipyard_stock("quanzhou"):
		var button: Button = screen.buy_button(hull_id)
		if button == null or not button.disabled:
			all_locked = false
	_check(all_locked, "at the unallied neutral every hull row is disabled")
	_check(screen.buy_button("junk").tooltip_text.contains(
			I18n.t_key("shipyard.tier.allegiance_locked")),
		"…with the 同盟专营 lock note (%s)"
		% screen.buy_button("junk").tooltip_text)
	var junk_note: Label = catalog.get_node("Catalog_junk/Note")
	_check(junk_note.visible and junk_note.text
			== I18n.t_key("shipyard.tier.allegiance_locked"),
		"…and the allegiance note line explains the flip path")
	# (1) available back at the dev-3 capital.
	GameState.current_port = "lisbon"
	screen.rebuild()
	await get_tree().process_frame
	_check(not screen.buy_button("nao").disabled
		and screen.buy_button("nao").tooltip_text.contains("22,000"),
		"back at lisbon the tier-3 nao is buyable")
	# Equipment rows stock-aware: lisbon's lists, rare items never shown.
	_check(_button_ids(screen.player_equipment_widget("weapon")["buy"])
			== ["eq_zweihander", "eq_cutlass"],
		"the weapon row lists lisbon's stocked pair (got %s)" % str(
			_button_ids(screen.player_equipment_widget("weapon")["buy"])))
	_check(_button_ids(screen.player_equipment_widget("armor")["buy"])
			== ["eq_saint_medallion"],
		"the armor row lists only the stocked medallion (no rare cuirass)")
	_check(_button_ids(screen.ship_equipment_widget(0, "figurehead")["buy"]).is_empty(),
		"lisbon stocks no figurehead, so that row lists none")
	# The tier-gray equipment note: bordeaux's equipment stock is tier-1
	# only, so use valetta (dev 1, stocked tier-2 medallion).
	GameState.current_port = "valetta"
	screen.rebuild()
	await get_tree().process_frame
	var medallion: Button = screen.player_equipment_widget("armor")["buy"]["eq_saint_medallion"]
	_check(medallion != null and medallion.disabled
		and medallion.tooltip_text.contains(I18n.fmt(
			"shipyard.tier.need_dev", {"dev": 1})),
		"valetta's tier-2 medallion is grayed with the dev note (%s)"
		% medallion.tooltip_text)
	GameState.current_port = "lisbon"

	# A full fleet disables every Buy button with the fleet reason.
	var saved_fleet := GameState.fleet
	_make_run(500000, ["caravel", "caravel", "caravel", "caravel", "caravel"])
	screen.rebuild()
	await get_tree().process_frame
	_check(screen.buy_button("latin").disabled
		and screen.buy_button("latin").tooltip_text.contains(
			I18n.t_key("shipyard.fleet_full")),
		"at 5 ships every Buy button is disabled with 'shipyard.fleet_full'")
	GameState.fleet = saved_fleet

	# Flagship row: no Sell, no Promote. Escort: both present.
	_make_run(50000, ["caravel", "sloop"])
	screen.rebuild()
	await get_tree().process_frame
	_check(screen.fleet_widget(0)["sell"] == null,
		"the flagship row has no Sell button at all (§6)")
	_check(screen.fleet_widget(0)["promote"] == null,
		"the flagship row has no Promote button")
	_check(screen.fleet_widget(1)["sell"] != null
		and not screen.fleet_widget(1)["sell"].disabled,
		"an empty escort's Sell button is enabled")
	_check(not screen.fleet_widget(1)["promote"].disabled,
		"…and so is her Promote button (docked)")

	# Cargo blocks selling, and the tooltip says why (§4.7).
	GameState.fleet[1]["cargo"] = {"wine": 4}
	screen.rebuild()
	await get_tree().process_frame
	_check(screen.fleet_widget(1)["sell"].disabled
		and screen.fleet_widget(1)["sell"].tooltip_text.contains(
			I18n.t_key("shipyard.cargo_not_empty")),
		"a loaded escort's Sell button is disabled with 'shipyard.cargo_not_empty'")
	GameState.fleet[1]["cargo"] = {}

	# Refit is live in Phase 2 (§4.3 "Phase 2 enables the row", `80-*` §4.7.2):
	# the picker starts at 0 cannons, so the button is disabled with the
	# validation reason until a legal count is entered.
	_check(screen.fleet_widget(0)["refit"] != null
			and screen.fleet_widget(0)["refit"].disabled,
		"the Phase-2 Refit row is present, disabled at 0 cannons (§6)")
	_check(screen.fleet_widget(0)["refit"].tooltip_text
			== I18n.fmt("ui.reason", {"reason": I18n.t_key("shipyard.invalid_points")}),
		"…with the 'shipyard.invalid_points' reason (%s)"
		% screen.fleet_widget(0)["refit"].tooltip_text)
	var refit_note: Label = screen.get_node(
		"FleetPanel/FleetScroll/FleetRows/Fleet_0"
		+ "/RefitNote_0")
	_check(refit_note.text == I18n.fmt("shipyard.repair_cost", {"amount": 0}),
		"…and the live cost note prices 0 cannons (%s)" % refit_note.text)

	# Repair picker: live cost preview, disabled at 0, then repair works.
	GameState.fleet[0]["durability"] = 60
	screen.rebuild()
	await get_tree().process_frame
	var widgets: Dictionary = screen.fleet_widget(0)
	var points: LineEdit = widgets["points"]
	var preview: Label = widgets["preview"]
	_check(widgets["repair"].disabled,
		"the Repair button starts disabled at 0 points (§6)")
	_check(widgets["repair"].disabled and preview.text
			== I18n.fmt("shipyard.repair_cost", {"amount": 0}),
		"…with a 0g preview (%s)" % preview.text)
	points.text = "7"
	points.text_changed.emit("7")
	_check(preview.text == I18n.fmt("shipyard.repair_cost", {"amount": 140}),
		"the live preview prices 7 caravel points at 140g (%s)" % preview.text)
	_check(not widgets["repair"].disabled,
		"…and enables the Repair button")
	var gold_before := GameState.gold
	widgets["repair"].pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(int(GameState.fleet[0]["durability"]) == 67,
		"pressing Repair restores 7 points (got %d)"
		% int(GameState.fleet[0]["durability"]))
	_check(GameState.gold == gold_before - 140,
		"…and charges 140g (gold %d → %d)" % [gold_before, GameState.gold])

	# The numeric field clamps to the remaining damage (§4.7 live-clamp).
	GameState.fleet[0]["durability"] = 80
	screen.rebuild()
	await get_tree().process_frame
	widgets = screen.fleet_widget(0)
	points = widgets["points"]
	points.text = "999"
	points.text_changed.emit("999")
	_check(points.text == "10",
		"an over-large entry clamps to the 10 points of damage (got '%s')"
		% points.text)
	# The Max button selects exactly those 10.
	screen.get_node(
		"FleetPanel/FleetScroll/FleetRows/Fleet_0"
		+ "/PointsMax_0"
	).pressed.emit()
	_check(points.text == "10", "the Max button picks the whole damage (got '%s')"
		% points.text)
	# An undamaged hull disables the picker (nothing to repair).
	GameState.fleet[0]["durability"] = 90
	screen.rebuild()
	await get_tree().process_frame
	widgets = screen.fleet_widget(0)
	_check(not (widgets["points"] as LineEdit).editable
		and (widgets["repair"] as Button).disabled,
		"an undamaged hull has an inert picker and a disabled Repair")

	# Sell: confirm dialog carries the ship name, then pays the formula price.
	_make_run(50000, ["caravel", "sloop"])
	screen.rebuild()
	await get_tree().process_frame
	var confirm = screen.get_node("ConfirmDialog")
	gold_before = GameState.gold
	screen.fleet_widget(1)["sell"].pressed.emit()
	_check(confirm.is_open(), "Sell opens the confirm dialog (§4.3)")
	_check(confirm.message_text().contains(I18n.t_key("fleet.ship_n").replace(
			"{amount}", "2")),
		"…naming the ship being sold (%s)" % confirm.message_text())
	_check(screen.has_modal(), "has_modal() sees the confirm dialog")
	# Esc must not leave while the modal is up (§6).
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	screen._unhandled_input(esc)
	_check(confirm.is_open() and screen.is_inside_tree(),
		"Esc behind the confirm dialog does not go back")
	# Cancel leaves the fleet intact (§4.7).
	screen.fleet_widget(1)["sell"].pressed.emit()
	_check(confirm.is_open(), "Sell opens the confirm dialog again")
	confirm.cancel()
	await get_tree().process_frame
	_check(GameState.fleet.size() == 2 and not screen.has_modal(),
		"cancelling the confirm keeps the hull and closes the dialog")

	var price: int = ShipyardLib.sell_price(1)
	screen.fleet_widget(1)["sell"].pressed.emit()
	confirm.accept()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(GameState.fleet.size() == 1,
		"confirming the sale removes the hull (got %d ships)"
		% GameState.fleet.size())
	_check(GameState.gold == gold_before + price,
		"…and pays the formula price %dg (gold %d → %d)"
		% [price, gold_before, GameState.gold])
	_check(not screen.has_modal(), "the confirm dialog closed")
	_check(screen.fleet_widget(1).is_empty(),
		"the sold row is gone from the fleet list")

	# Promote from the screen: free, moves the row to the top.
	_make_run(50000, ["caravel", "sloop", "nao"])
	screen.rebuild()
	await get_tree().process_frame
	gold_before = GameState.gold
	screen.fleet_widget(2)["promote"].pressed.emit()
	await get_tree().process_frame
	_check(str(GameState.fleet[0]["ship_type_id"]) == "nao",
		"the screen's Promote button moves the hull to fleet[0] (got '%s')"
		% str(GameState.fleet[0]["ship_type_id"]))
	_check(GameState.gold == gold_before, "…for free")
	_check(screen.fleet_widget(0)["sell"] == null,
		"the newly-promoted row loses its Sell button")

	# Locale rebind: every visible string follows the toggle (§6).
	I18n.set_locale("zh")
	await get_tree().process_frame
	var title: Label = screen.get_node("header/Title")
	var catalog_title: Label = screen.get_node(
		"CatalogPanel/CatalogTitle")
	_check(title.text == I18n.fmt("shipyard.title", {
			"port": I18n.t(DataLoader.get_port("lisbon")["name"])}),
		"the title rebinds to zh (%s)" % title.text)
	_check(catalog_title.text == I18n.t_key("shipyard.catalog"),
		"the catalog heading rebinds to zh (%s)" % catalog_title.text)
	_check(screen.buy_button("latin").text == I18n.t_key("shipyard.buy"),
		"…and so does every Buy button")
	I18n.set_locale("en")

	# Esc (Back) returns to the port hub.
	var went_back := [false]
	screen.went_back.connect(func() -> void: went_back[0] = true)
	screen._unhandled_input(esc)
	_check(went_back[0], "Esc emits went_back (S6 → S4)")
	screen.get_node("header/Back").pressed.emit()
	_check(went_back[0], "the Back button takes the same edge")
	_check(PortScreenLib.FACILITY_SCENES.get("shipyard", "")
			== "res://scenes/port/shipyard_screen.tscn",
		"the port hub routes 'shipyard' to this screen (30-* §4.7)")
	_check(screen.go_back() and screen.PORT_SCENE == "res://scenes/port/port_screen.tscn",
		"go_back targets port_screen.tscn")

	# Standalone (no current_port): the screen still binds and does not crash.
	screen.queue_free()
	await get_tree().process_frame
	_make_run(1000, ["latin"], null)
	var standalone = ShipyardScene.instantiate()
	standalone.route_to_hub = false
	add_child(standalone)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(standalone.get_node("header/Title").text
			== I18n.t_key("port.shipyard"),
		"standalone: the header falls back to the shipyard noun (%s)"
		% standalone.get_node("header/Title").text)
	_check(standalone.fleet_widget(0)["promote"] == null,
		"standalone: the flagship row still has no Promote (at sea)")
	standalone.queue_free()
	await get_tree().process_frame

	# Real route last (it swaps the scene tree): Esc on a routed S6 lands on
	# the port hub (§4.2 S6 → S4).
	_make_run(1000, ["latin"])
	var tree := get_tree()
	var previous_scene := tree.current_scene
	tree.current_scene = null
	var routed = ShipyardScene.instantiate()
	routed.route_to_hub = true
	tree.root.add_child(routed)
	tree.current_scene = routed
	await tree.process_frame
	var routed_esc := InputEventAction.new()
	routed_esc.action = "back"
	routed_esc.pressed = true
	routed._unhandled_input(routed_esc)
	await tree.process_frame
	await tree.process_frame
	var hub = tree.current_scene
	_check(hub != null and hub.scene_file_path == "res://scenes/port/port_screen.tscn",
		"Esc routes to port_screen.tscn (got %s)"
		% ("null" if hub == null else hub.scene_file_path))
	if hub != null:
		hub.queue_free()
	tree.current_scene = null
	await tree.process_frame
	tree.current_scene = previous_scene

	GameState.locale = locale_before


# --- 11. The S13 palace screen: permits + commendation (Phase 7) ----------
# Screen cases live in this suite because `tools/test_palace.gd` is task L's
# file (one writer per file per wave). The seam spy drives every permit state
# while task L's engine is still in flight; the guard defaults (no engine)
# are asserted against today's main.

## The duck-typed `palace_engine` seam spy (the screen's `engine_override`).
class SeamSpy extends RefCounted:
	var calls: Array = []
	var answers: Dictionary = {}

	func _record(method: String) -> void:
		calls.append(method)

	func permit_price(_port_id: String, _kind: String, _nation_id: String) -> int:
		_record("permit_price")
		return int(answers.get("permit_price", 0))

	func permit_owned(_port_id: String, _kind: String, _nation_id: String) -> bool:
		_record("permit_owned")
		return bool(answers.get("permit_owned", false))

	func permit_void_reason(_port_id: String, _kind: String,
			_nation_id: String) -> String:
		_record("permit_void_reason")
		return str(answers.get("permit_void_reason", ""))

	func permit_block_reason(_port_id: String, _kind: String,
			_nation_id: String) -> String:
		_record("permit_block_reason")
		return str(answers.get("permit_block_reason", ""))

	func buy_permit(_port_id: String, _kind: String, _nation_id: String) -> bool:
		_record("buy_permit")
		return bool(answers.get("buy_permit", false))

	func take_commendation() -> Dictionary:
		_record("take_commendation")
		var value = answers.get("take_commendation", {})
		return value if value is Dictionary else {}


## A palace run at `port_id` with a one-ship portugal fleet (the permit rows
## need the player nation, rep map and empty bounty book). Re-seeds the
## allegiance module so permits/treasuries/commendations start fresh.
func _make_palace_run(port_id: String) -> void:
	GameState.gold = 50000
	GameState.current_port = port_id
	GameState.day = 1
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0, "level": 1, "officers": [],
		"reputation": {"portugal": 40, "spain": 0, "italy": 40},
	}
	GameState.fleet = [FleetLib.new_ship("caravel", 0)]
	GameState.npc_fleets = []
	GameState.bounties = {}
	GameState.active_quests = []
	GameState.titles = {"portugal": "count", "spain": "none", "italy": "count"}
	AllegianceLib.seed_new_game()


func _test_palace_screen() -> void:
	var locale_before: String = GameState.locale
	GameState.locale = "en"
	# MERGED STATE: the §4.7.15 keys live in data/ui_strings.json and task
	# L's real palace_engine answers the bundled permit API — the section
	# renders and the row speaks the real engine's facts (no spy here).
	_make_palace_run("lisbon")
	var screen = PalaceScene.instantiate()
	screen.route_to_port = false
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	# Real-engine conformance: the merged engine surface is the BUNDLED API
	# (`permit_offer(port)` + `buy_permit(port)` + the commendation pair).
	# The granular C-contract names are absent on the real engine (reported
	# to the master); the screen guard-reads both shapes, so either engine
	# drives the rows.
	_check(_palace_engine_script.has_method("permit_offer")
		and _palace_engine_script.has_method("buy_permit")
		and _palace_engine_script.has_method("pending_commendation")
		and _palace_engine_script.has_method("dismiss_commendation"),
		"the real engine answers the bundled permit API")
	_check(not _palace_engine_script.has_method("permit_price")
		and not _palace_engine_script.has_method("take_commendation"),
		"the granular C-contract names stay absent (bundle engine shape)")
	_check(screen.permit_section_visible(),
		"with the merged keys the permit section header renders")
	_check((screen.permit_widget("home")["row"] as Control).visible
		and not (screen.permit_widget("foreign")["row"] as Control).visible,
		"at the player's own capital the home charter row shows alone")
	var home: Dictionary = screen.permit_widget("home")
	_check((home["label"] as Label).text == I18n.t_key("palace.permit.home"),
		"the home row names the 5,000g charter (%s)"
		% (home["label"] as Label).text)
	_check((home["note"] as Label).text
			== I18n.t_key("palace.permit.home.coverage"),
		"…and the row carries the coverage note (%s)"
		% (home["note"] as Label).text)
	_check(not (home["buy"] as Button).disabled,
		"the real engine answers the seam, so the permit Buy is enabled")
	# zh pass (§6): the section header is 免税证, the row label follows.
	GameState.locale = "zh"
	screen.refresh()
	await get_tree().process_frame
	_check(screen.permit_section_visible()
		and (screen.permit_widget("home")["label"] as Label).text
			== I18n.t_key("palace.permit.home"),
		"the zh section renders 免税证 with the home row (%s)"
		% (screen.permit_widget("home")["label"] as Label).text)
	GameState.locale = "en"
	screen.refresh()
	await get_tree().process_frame
	home = screen.permit_widget("home")
	# THE REAL BUY PATH at the dev-3 home capital: −5,000g, the permit flag
	# sets, the sale credits portugal's treasury (decision 19), and the row
	# flips to the held state with Buy locked.
	var real_gold_before := GameState.gold
	(home["buy"] as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(GameState.gold == real_gold_before - 5000,
		"the real home-charter buy costs exactly 5,000g (gold %d)"
		% GameState.gold)
	_check(AllegianceLib.has_permit_home(),
		"…and the home charter is held")
	_check(AllegianceLib.treasury("portugal")
			== AllegianceLib.TREASURY_START + 5000,
		"…and the sale credits portugal's treasury (+5,000g)")
	home = screen.permit_widget("home")
	_check((home["buy"] as Button).disabled
		and (home["note"] as Label).text
			== I18n.t_key("palace.permit.home.owned"),
		"…and the row flips to the held state, Buy locked (%s)"
		% (home["note"] as Label).text)
	(home["buy"] as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(GameState.gold == real_gold_before - 5000
		and AllegianceLib.has_permit_home(),
		"a second press is refused — no double purchase, no double charge")
	# The documented pre-merge fallback, fixture-locally: with the three gate
	# keys stripped the section and both rows hide again — nothing crashes
	# and no raw "<key>" reaches any label.
	var permit_stash := _stash_ui_keys(["palace.permit.section",
		"palace.permit.home", "palace.permit.foreign"])
	screen.refresh()
	await get_tree().process_frame
	_check(not screen.permit_section_visible(),
		"with the keys stripped the section header stays hidden")
	_check(not (screen.permit_widget("home")["row"] as Control).visible
		and not (screen.permit_widget("foreign")["row"] as Control).visible,
		"…and both permit rows stay hidden")
	var stripped_unresolved: Array[String] = []
	_collect_unresolved(screen, stripped_unresolved)
	_check(stripped_unresolved.is_empty(),
		"the stripped state leaves no raw <key> anywhere (found %s)"
		% str(stripped_unresolved))
	_unstash_ui_keys(permit_stash)
	screen.refresh()
	await get_tree().process_frame
	_check(screen.permit_section_visible()
		and (screen.permit_widget("home")["row"] as Control).visible,
		"restoring the keys re-renders the section and the home row")
	_check(not screen.commendation_open(),
		"no commendation without a pending conversion")

	# THE REAL COMMENDATION PATH (70-* §4.1): a contestable port flips to the
	# player's nation through the allegiance engine → the palace plays the
	# one-time dialog at the own-nation palace; 领受 closes it AND dismisses
	# the pending (the real pending is a peek — dismissal is the screen's
	# close hook, `palace_screen.gd#_on_commend_closed`).
	AllegianceLib.add_investment("quanzhou", "portugal", 6000)
	_check(AllegianceLib.effective_alignment("quanzhou") == "portugal",
		"the fixture flip lands (quanzhou aligned to portugal)")
	screen.refresh()
	await get_tree().process_frame
	_check(screen.commendation_open(),
		"the real pending commendation opens the dialog")
	var real_commend: Control = screen.get_node("CommendDialog")
	_check(real_commend.message_text().contains(
			I18n.t_key("palace.commend.title"))
		and real_commend.message_text().contains("Quanzhou"),
		"the real dialog reads title + body with the port named (%s)"
		% real_commend.message_text().replace("\n", " "))
	(real_commend.get_node(
		"Center/Panel/Margin/Body/Footer/OK") as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not screen.commendation_open(), "领受 closes the dialog")
	# (The pending-dismissal engine semantics are §palace's pins; this
	# section owns the SCREEN render contract only.)
	screen.refresh()
	await get_tree().process_frame
	_check(not screen.commendation_open(),
		"the dismissed commendation never replays on refresh")

	# The spy seam drives the §4.7.13 states; every press must call through.
	var spy := SeamSpy.new()
	screen.engine_override = spy
	# Available: gates pass, not owned, not void → Buy enabled.
	spy.answers = {
		"permit_price": 5000, "permit_owned": false,
		"permit_void_reason": "", "permit_block_reason": "",
		"buy_permit": true,
	}
	screen.refresh()
	await get_tree().process_frame
	home = screen.permit_widget("home")
	_check(not (home["buy"] as Button).disabled,
		"with the seam answering 'available' the Buy enables")
	var gold_before := GameState.gold
	(home["buy"] as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(spy.calls.has("buy_permit"),
		"the press called through to the engine seam (calls %s)" % str(spy.calls))
	_check(GameState.gold == gold_before,
		"the spy seam owns pricing, so the screen touched no gold itself")
	# Owned: held state text, Buy disabled (the engine seam would also refuse
	# a second purchase; the screen at minimum locks the row).
	spy.answers["permit_owned"] = true
	spy.calls.clear()
	screen.refresh()
	await get_tree().process_frame
	home = screen.permit_widget("home")
	_check((home["buy"] as Button).disabled
		and (home["note"] as Label).text == I18n.t_key("palace.permit.home.owned"),
		"the held state shows the owned note and locks Buy (%s)"
		% (home["note"] as Label).text)
	# Void: bounty note, disabled.
	spy.answers["permit_owned"] = false
	spy.answers["permit_void_reason"] = "palace.permit.void_bounty"
	screen.refresh()
	await get_tree().process_frame
	home = screen.permit_widget("home")
	_check((home["buy"] as Button).disabled
		and (home["note"] as Label).text == I18n.t_key("palace.permit.void_bounty"),
		"the void-bounty state shows the void note (%s)"
		% (home["note"] as Label).text)
	spy.answers["permit_void_reason"] = "palace.permit.void_rep"
	screen.refresh()
	await get_tree().process_frame
	_check((screen.permit_widget("home")["note"] as Label).text
			== I18n.t_key("palace.permit.void_rep"),
		"the void-rep state shows its own note")

	# Foreign palace: the foreign row (host nation), title gate first.
	_make_palace_run("seville")
	GameState.player["reputation"]["spain"] = 0
	screen.refresh()
	await get_tree().process_frame
	_check(not (screen.permit_widget("home")["row"] as Control).visible
		and (screen.permit_widget("foreign")["row"] as Control).visible,
		"at spain's palace only the foreign row shows")
	var foreign: Dictionary = screen.permit_widget("foreign")
	_check((foreign["label"] as Label).text == I18n.fmt(
			"palace.permit.foreign", {"nation": I18n.t(
				DataLoader.get_nation("spain").get("name", {}))}),
		"the foreign row names the host nation (%s)"
		% (foreign["label"] as Label).text)
	# Real-engine gates (the spy is cleared): the bundled offer derives the
	# foreign title gate — a non-knight sees 爵位需达到骑士, Buy locked.
	screen.engine_override = null
	screen.refresh()
	await get_tree().process_frame
	foreign = screen.permit_widget("foreign")
	_check((foreign["buy"] as Button).disabled
		and (foreign["note"] as Label).text
			== I18n.t_key("palace.permit.title_locked"),
		"a non-knight sees the title gate on the foreign permit (%s)"
		% (foreign["note"] as Label).text)
	# Knight + rep 0 → the rep gate.
	GameState.titles["spain"] = "knight"
	screen.refresh()
	await get_tree().process_frame
	_check((screen.permit_widget("foreign")["note"] as Label).text
			== I18n.t_key("palace.permit.rep_locked"),
		"a knight at rep 0 sees the rep gate instead")
	# Knight + rep ≥ 20 → covered; the seam returns so Buy enables.
	GameState.player["reputation"]["spain"] = 25
	screen.engine_override = spy
	spy.answers = {
		"permit_price": 20000, "permit_owned": false,
		"permit_void_reason": "", "permit_block_reason": "",
		"buy_permit": true,
	}
	screen.refresh()
	await get_tree().process_frame
	foreign = screen.permit_widget("foreign")
	_check(not (foreign["buy"] as Button).disabled
		and (foreign["note"] as Label).text
			== I18n.t_key("palace.permit.foreign.coverage"),
		"a knight at rep 25 is offered the 20,000g permit")
	spy.calls.clear()
	(foreign["buy"] as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(spy.calls.has("buy_permit"),
		"the foreign purchase also calls through to the seam")

	# Commendation: the fixture event through the same seam (70-* §4.1).
	_make_palace_run("lisbon")
	spy.answers["take_commendation"] = {
		"nation_id": "portugal", "port_id": "bordeaux",
	}
	screen.refresh()
	await get_tree().process_frame
	_check(screen.commendation_open(),
		"the commendation dialog opens on the fixture event")
	var commend: Control = screen.get_node("CommendDialog")
	_check(commend.message_text().contains(I18n.t_key("palace.commend.title"))
		and commend.message_text().contains("Bordeaux"),
		"the dialog reads title + body with the port named (%s)"
		% commend.message_text().replace("\n", " "))
	var ok_button: Button = commend.get_node(
		"Center/Panel/Margin/Body/Footer/OK")
	_check(ok_button.text == I18n.t_key("palace.commend.close"),
		"the OK button carries the pinned close label (%s)" % ok_button.text)
	ok_button.pressed.emit()
	await get_tree().process_frame
	_check(not screen.commendation_open(), "…and closes on 领受")
	# One-time: the consumed take returns {} → no second dialog.
	spy.answers["take_commendation"] = {}
	screen.refresh()
	await get_tree().process_frame
	_check(not screen.commendation_open(),
		"the consumed commendation never replays")
	screen.engine_override = null

	# Locale rebind (§6) walks every visible line; then the scene frees.
	I18n.set_locale("zh")
	await get_tree().process_frame
	var unresolved: Array[String] = []
	_collect_unresolved(screen, unresolved)
	_check(unresolved.is_empty(),
		"zh rebind leaves no raw <key> anywhere (found %s)" % str(unresolved))
	I18n.set_locale("en")
	screen.queue_free()
	await get_tree().process_frame
	GameState.locale = locale_before


# --- 12. The Allegiance guard path (80-* §4.16) -----------------------------
# Installed LAST: `take_over_path` publishes a fixture allegiance module at
# the C-contract path, proving every guard call switches from the authored
# defaults to the engine answers when task L's file lands.

## A fixture `allegiance.gd` answering every port with `dev`/`alignment`.
func _install_allegiance_fixture(dev_value: int, alignment_value: String):
	var script := GDScript.new()
	script.source_code = (
		"extends RefCounted\n"
		+ "static func dev(_port_id: String) -> int:\n"
		+ "\treturn %d\n" % dev_value
		+ "static func effective_alignment(_port_id: String) -> String:\n"
		+ "\treturn \"%s\"\n" % alignment_value
	)
	script.reload()
	script.take_over_path(ShipyardLib.ALLEGIANCE_PATH)
	return script


func _test_allegiance_guard_path() -> void:
	# Engine reads.
	var fixture = _install_allegiance_fixture(2, "portugal")
	_check(ShipyardLib.effective_dev("lisbon") == 2,
		"guard path: Allegiance.dev() wins over the authored floor (got %d)"
		% ShipyardLib.effective_dev("lisbon"))
	_check(ShipyardLib.effective_alignment("quanzhou") == "portugal",
		"guard path: Allegiance.effective_alignment() wins over the data")
	_check(not ShipyardLib.is_unallied_neutral("quanzhou"),
		"an aligned neutral is no longer unallied")
	_check(ShipyardLib.row_state("lisbon", "caravel") == ShipyardLib.ROW_AVAILABLE
		and ShipyardLib.row_state("lisbon", "nao") == ShipyardLib.ROW_TIER_GRAY,
		"the fixture's dev 2 re-gates lisbon: tier-2 available, tier-3 gray")
	# The aligned dev-2 neutral unlocks her regional hulls (the §2.2 flip path).
	_make_run(100000, ["latin"], "quanzhou")
	_check(ShipyardLib.buy_block_reason("junk").is_empty()
		and ShipyardLib.buy("junk"),
		"at the aligned dev-2 neutral the tier-2 junk buys (correction 11)")
	# Screen reads: with the fixture live, lisbon's nao row is tier-gray.
	GameState.current_port = "lisbon"
	_make_run(50000, ["caravel"], "lisbon")
	var screen = ShipyardScene.instantiate()
	screen.route_to_hub = false
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(screen.buy_button("nao").disabled
		and screen.buy_button("caravel") != null
		and not screen.buy_button("caravel").disabled,
		"the screen re-gates through the guard path (nao gray, caravel buyable)")
	_check(screen.buy_button("nao").tooltip_text.contains(I18n.fmt(
			"shipyard.tier.need_dev", {"dev": 2})),
		"…with 需发展度 2 from the fixture dev (%s)"
		% screen.buy_button("nao").tooltip_text)
	screen.queue_free()
	await get_tree().process_frame
	fixture.free()


# --- Harness --------------------------------------------------------------

## Injects `data/ui_strings.json`-shaped fixture keys into the loaded table
## (the file itself is orchestrator-owned; the screen sections need the
## §4.7.15 strings to prove the merged rendering).
func _inject_keys(keys: Dictionary) -> void:
	for key in keys:
		DataLoader.ui_strings[key] = keys[key]


## Fixture-local key ABSENCE: removes the named keys from the loaded table
## and returns the removed entries for [method _unstash_ui_keys]. The merged
## `data/ui_strings.json` always carries the §4.7.15 keys now, so the
## documented pre-merge fallbacks are exercised by stripping keys HERE —
## never by the shipped data (which the suite must not mutate).
func _stash_ui_keys(key_names: Array) -> Dictionary:
	var stash: Dictionary = {}
	for key in key_names:
		if DataLoader.ui_strings.has(key):
			stash[key] = DataLoader.ui_strings[key]
			DataLoader.ui_strings.erase(key)
	return stash


## Restores entries removed by [method _stash_ui_keys].
func _unstash_ui_keys(stash: Dictionary) -> void:
	for key in stash:
		DataLoader.ui_strings[key] = stash[key]


## The equipment ids behind a slot row's buy-button dict, in display order.
func _button_ids(buttons: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for id in buttons:
		ids.append(str(id))
	return ids


## Walks every Label/Button (texts and tooltips) under `node` and collects any
## text still shaped like `"<a.b.c>"` — the `I18n.t_key` missing-entry marker
## (§6), which must never reach a player.
func _collect_unresolved(node: Node, found: Array[String]) -> void:
	var texts: Array[String] = []
	if node is Label:
		texts.append((node as Label).text)
	elif node is Button:
		texts.append((node as Button).text)
	if node is Control:
		texts.append((node as Control).tooltip_text)
	for text in texts:
		if text.begins_with("<") and text.ends_with(">") and text.length() > 2 \
				and not text.contains(" "):
			found.append("%s: %s" % [node.get_path(), text])
	for child in node.get_children():
		_collect_unresolved(child, found)


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
