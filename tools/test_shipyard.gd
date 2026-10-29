extends Node
## T13 acceptance tests (docs/IMPLEMENT-Phase1.md T13; docs/40-SHIPS-AND-FLEET.md
## §4.3–§4.4, §5, §6, §7; docs/30-* §4.7; docs/80-* §4.7). Headless:
##
##   godot --headless res://tools/test_shipyard.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: 1 repair pricing (§4.3, all 8 types + the §4.3 worked values),
## 2 sell pricing (§4.3/§5), 3 FLEET_MAX buys (§4.3/§4.4/§6), 4 buy defaults,
## 5 no-sell rules, 6 partial repair, 7 promote, 8 refit maths (Phase-2 logic,
## disabled UI), 9 the S6 screen itself (catalog, disabled reasons, pickers,
## confirm, locale rebind, Esc/Back).

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const ShipyardScene := preload("res://scenes/port/shipyard_screen.tscn")
const PortScreenLib := preload("res://scenes/port/port_screen.gd")

## The four repair prices printed in docs/40 §4.3 ("latin 3g/pt, caravel
## 20g/pt, nao 55g/pt, galleon 150g/pt").
const DOC_REPAIR_PRICES := {"latin": 3, "caravel": 20, "nao": 55, "galleon": 150}
## The §4.3 repair divisor (`ceil(base_price / 400)`).
const REPAIR_DIVISOR := 400

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_repair_pricing()
	_test_sell_pricing()
	_test_fleet_max()
	_test_buy_defaults()
	_test_no_sell_rules()
	_test_partial_repair()
	_test_promote()
	_test_refit_maths()
	await _test_screen()
	_report()


# --- Fixtures --------------------------------------------------------------

## A docked run with exactly `ship_ids` in the fleet, all at full durability.
func _make_run(gold: int = 100000, ship_ids: Array = ["caravel"],
		port = "lisbon") -> void:
	GameState.gold = gold
	GameState.current_port = port
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0, "level": 1, "officers": [], "reputation": {"portugal": 0},
	}
	GameState.fleet = []
	for ship_id in ship_ids:
		GameState.fleet.append(FleetLib.new_ship(str(ship_id), 0))


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
	_check(DataLoader.ship_types_list.size() == 8,
		"data holds all 8 ShipTypes (docs/10-* §7.3)")
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


# --- 9. The S6 screen ----------------------------------------------------

func _test_screen() -> void:
	var locale_before: String = GameState.locale
	GameState.locale = "en"
	_make_run(50000, ["caravel", "sloop"])
	var screen = ShipyardScene.instantiate()
	screen.route_to_hub = false
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame

	# Catalog: all 8 types, no regional restrictions.
	var catalog: VBoxContainer = screen.get_node(
		"Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogScroll/CatalogRows")
	_check(catalog.get_child_count() == 8,
		"the catalog lists all 8 ShipTypes (got %d)" % catalog.get_child_count())
	_check(screen.buy_button("galleon") != null,
		"every type has a Buy button (galleon present)")
	# No unresolved key may ever reach a label (`I18n.t_key` returns "<key>"
	# for a missing entry), including the awaiting-merge stat/picker keys.
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
		"Layout/VBox/Body/FleetPanel/Margin/Box/FleetScroll/FleetRows/Fleet_0"
		+ "/Margin/Box/RefitRow/RefitNote_0")
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
		"Layout/VBox/Body/FleetPanel/Margin/Box/FleetScroll/FleetRows/Fleet_0"
		+ "/Margin/Box/Actions/PointsMax_0"
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
	var title: Label = screen.get_node("Layout/VBox/Header/Title")
	var catalog_title: Label = screen.get_node(
		"Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogTitle")
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
	screen.get_node("Layout/VBox/Header/Back").pressed.emit()
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
	_check(standalone.get_node("Layout/VBox/Header/Title").text
			== I18n.t_key("port.shipyard"),
		"standalone: the header falls back to the shipyard noun (%s)"
		% standalone.get_node("Layout/VBox/Header/Title").text)
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


# --- Harness --------------------------------------------------------------

## Walks every Label/Button under `node` and collects any text still shaped like
## `"<a.b.c>"` — the `I18n.t_key` missing-entry marker (§6), which must never
## reach a player.
func _collect_unresolved(node: Node, found: Array[String]) -> void:
	var text := ""
	if node is Label:
		text = (node as Label).text
	elif node is Button:
		text = (node as Button).text
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
