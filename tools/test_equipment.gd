extends Node
## Phase-2 task E acceptance tests (docs/IMPLEMENT-Phase2.md E;
## docs/60-COMBAT.md §4.11.6, §4.11.12, §4.11.13; docs/40-SHIPS-AND-FLEET.md
## §4.1, §4.3; docs/50-CHARACTER-AND-PROGRESSION.md §4.8; docs/80-UI-UX.md
## §4.7.2). Headless:
##
##   godot --headless --path . tools/test_equipment.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: 1 the locked 8-item data set, 2 tolerant accessors & modifiers,
## 3 equipment prices/sell-back, 4 buying player equipment (replace-in-one-
## transaction), 5 unequip, 6 ship equipment (figurehead durability, sail
## speed), 7 the duel hook (`player_combat_bonus`), 8 refit buy/sell + the
## Phase-1 invariants it must not disturb, 9 the S6 screen's Phase-2 rows.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const ShipyardScene := preload("res://scenes/port/shipyard_screen.tscn")

## docs/60-COMBAT.md §4.11.13, copied by hand so this suite fails if the data
## or the engine ever drifts from the locked table.
const LOCKED_IDS: Array[String] = [
	"eq_cutlass", "eq_rapier", "eq_breastplate", "eq_lucky_charm",
	"eq_mermaid_figurehead", "eq_dragon_figurehead", "eq_cotton_sails",
	"eq_storm_sails",
]
const LOCKED_SLOTS := {
	"eq_cutlass": "weapon",
	"eq_rapier": "weapon",
	"eq_breastplate": "armor",
	"eq_lucky_charm": "armor",
	"eq_mermaid_figurehead": "figurehead",
	"eq_dragon_figurehead": "figurehead",
	"eq_cotton_sails": "sail",
	"eq_storm_sails": "sail",
}
const LOCKED_PRICES := {
	"eq_cutlass": 400,
	"eq_rapier": 1200,
	"eq_breastplate": 700,
	"eq_lucky_charm": 900,
	"eq_mermaid_figurehead": 1500,
	"eq_dragon_figurehead": 3200,
	"eq_cotton_sails": 1000,
	"eq_storm_sails": 2600,
}
const LOCKED_NAMES := {
	"eq_cutlass": {"zh": "水手弯刀", "en": "Sailor's Cutlass"},
	"eq_rapier": {"zh": "贵族细剑", "en": "Noble's Rapier"},
	"eq_breastplate": {"zh": "胸甲", "en": "Breastplate"},
	"eq_lucky_charm": {"zh": "幸运护符", "en": "Lucky Charm"},
	"eq_mermaid_figurehead": {"zh": "美人鱼船首像", "en": "Mermaid Figurehead"},
	"eq_dragon_figurehead": {"zh": "龙首船像", "en": "Dragon Figurehead"},
	"eq_cotton_sails": {"zh": "棉帆", "en": "Cotton Sails"},
	"eq_storm_sails": {"zh": "风暴帆", "en": "Storm Sails"},
}
const LOCKED_MODIFIERS := {
	"eq_cutlass": {"combat": 3},
	"eq_rapier": {"combat": 5},
	"eq_breastplate": {"combat": 2},
	"eq_lucky_charm": {"combat": 1, "luck": 5},
	"eq_mermaid_figurehead": {"durability": 10},
	"eq_dragon_figurehead": {"durability": 20},
	"eq_cotton_sails": {"speed": 1},
	"eq_storm_sails": {"speed": 1, "durability": 5},
}

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_locked_data()
	_test_accessors()
	_test_prices()
	_test_buy_player_equipment()
	_test_unequip()
	_test_ship_equipment()
	_test_duel_hook()
	_test_refit_and_phase1_invariants()
	await _test_screen()
	_report()


# --- Fixtures --------------------------------------------------------------

## A docked run with exactly `ship_ids` in the fleet, all at full durability,
## and **no** `player.equipment` block (a Phase-1 save shape) so the tolerance
## of every accessor is exercised first.
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


# --- 1. The locked 8-item data set (§4.11.13) -----------------------------

func _test_locked_data() -> void:
	var list: Array = DataLoader.equipment_list
	_check(list.size() == 8,
		"data/equipment.json holds exactly the 8 locked items (got %d)"
		% list.size())
	_check(DataLoader.equipment.size() == 8,
		"DataLoader indexes all 8 by id (got %d)" % DataLoader.equipment.size())

	var ids: Array[String] = []
	var all_phase2 := true
	var all_l10n := true
	var all_slots := true
	var all_prices := true
	var all_modifiers := true
	for item in list:
		var item_id := str(item.get("id", ""))
		ids.append(item_id)
		if not (item_id in LOCKED_IDS):
			_check(false, "unexpected equipment id '%s'" % item_id)
			continue
		if int(item.get("phase", 0)) != 2:
			all_phase2 = false
		if item.get("name", {}) != LOCKED_NAMES[item_id]:
			all_l10n = false
		if str(item.get("slot", "")) != str(LOCKED_SLOTS[item_id]):
			all_slots = false
		if int(item.get("price", -1)) != int(LOCKED_PRICES[item_id]):
			all_prices = false
		if item.get("modifiers", {}) != LOCKED_MODIFIERS[item_id]:
			all_modifiers = false
	_check(ids.size() == LOCKED_IDS.size(),
		"the data holds %d ids (got %d)" % [LOCKED_IDS.size(), ids.size()])
	_check(all_phase2, "every item is `phase: 2` (§10-* §4.6)")
	_check(all_l10n, "every zh/en name matches §4.11.13 exactly")
	_check(all_slots, "every slot matches §4.11.13 exactly")
	_check(all_prices, "every price matches §4.11.13 exactly")
	_check(all_modifiers, "every modifier map matches §4.11.13 exactly")
	_check(DataLoader.get_equipment("eq_cutlass").get("name", {}).get("en", "")
			== "Sailor's Cutlass",
		"DataLoader.get_equipment resolves eq_cutlass by id")
	_check(DataLoader.get_equipment("eq_nope").is_empty(),
		"an unknown equipment id resolves to {} (never a crash)")


# --- 2. Tolerant accessors & modifiers (§4.11.12 "they never fail") -------

func _test_accessors() -> void:
	_make_run(10000, ["caravel"])
	_check(ShipyardLib.equipped_player("weapon") == "",
		"a Phase-1 player block with no `equipment` reads weapon as ''")
	_check(not GameState.player.has("equipment"),
		"…and the read did not create the block (accessors never mutate)")
	_check(ShipyardLib.equipped_ship(0, "figurehead") == "",
		"a hull with no `equipment` reads figurehead as ''")
	_check(ShipyardLib.equipped_ship(9, "sail") == "",
		"an out-of-range ship index reads ''")
	_check(ShipyardLib.equipped_player("figurehead") == "",
		"a ship slot asked of the player reads ''")
	_check(ShipyardLib.equipped_ship(0, "weapon") == "",
		"a player slot asked of a hull reads ''")

	GameState.player["equipment"] = {"weapon": "eq_cutlass", "armor": null}
	_check(ShipyardLib.equipped_player("weapon") == "eq_cutlass",
		"a worn weapon reads back by id")
	_check(ShipyardLib.equipped_player("armor") == "",
		"a null slot value reads as '' (hand-edited save)")
	GameState.fleet[0]["equipment"] = {"figurehead": "", "sail": 7}
	_check(ShipyardLib.equipped_ship(0, "sail") == "",
		"a non-string slot value reads as ''")

	_check(ShipyardLib.equipment_modifier("eq_cutlass", "combat") == 3,
		"eq_cutlass combat is +3")
	_check(ShipyardLib.equipment_modifier("eq_cutlass", "luck") == 0,
		"a modifier the item lacks is 0")
	_check(ShipyardLib.equipment_modifier("eq_nope", "combat") == 0,
		"an unknown item's modifier is 0")
	_check(ShipyardLib.equipment_modifier("", "combat") == 0,
		"an empty id's modifier is 0")

	var weapon_ids: Array[String] = []
	for item in ShipyardLib.equipment_list("weapon"):
		weapon_ids.append(str(item.get("id", "")))
	_check(weapon_ids == ["eq_cutlass", "eq_rapier"],
		"equipment_list('weapon') is the two weapons in data order (got %s)"
		% str(weapon_ids))
	var sail_ids: Array[String] = []
	for item in ShipyardLib.equipment_list("sail"):
		sail_ids.append(str(item.get("id", "")))
	_check(sail_ids == ["eq_cotton_sails", "eq_storm_sails"],
		"equipment_list('sail') is the two sails in data order (got %s)"
		% str(sail_ids))
	_check(ShipyardLib.equipment_list("nonsense").is_empty(),
		"equipment_list('nonsense') is empty")


# --- 3. Prices & sell-back (§4.3) ----------------------------------------

func _test_prices() -> void:
	_check(ShipyardLib.equip_price("weapon", "eq_cutlass") == 400,
		"cutlass buy price is 400g")
	_check(ShipyardLib.equip_price("weapon", "eq_rapier") == 1200,
		"rapier buy price is 1200g")
	_check(ShipyardLib.equip_sellback("weapon", "eq_cutlass") == 200,
		"cutlass sell-back is floor(400 × 0.5) = 200g")
	_check(ShipyardLib.equip_sellback("weapon", "eq_rapier") == 600,
		"rapier sell-back is floor(1200 × 0.5) = 600g")
	_check(ShipyardLib.equip_sellback("armor", "eq_lucky_charm") == 450,
		"a 900g item sells back for 450g")
	_check(ShipyardLib.EQUIP_SELL_FRACTION == 0.5,
		"the equipment sell-back fraction is 0.5 (§4.3)")
	_check(ShipyardLib.equip_price("weapon", "eq_nope") == 0
		and ShipyardLib.equip_sellback("weapon", "eq_nope") == 0,
		"an unknown item prices at 0")


# --- 4. Buying player equipment (§4.3, §4.11.12) -------------------------

func _test_buy_player_equipment() -> void:
	_make_run(5000, ["caravel"])
	var gold_before := GameState.gold
	_check(ShipyardLib.equip("weapon", "eq_cutlass"), "buying the cutlass succeeds")
	_check(GameState.player["equipment"]["weapon"] == "eq_cutlass",
		"…and it is the worn weapon (got %s)"
		% str(GameState.player["equipment"]["weapon"]))
	_check(GameState.gold == gold_before - 400,
		"…for exactly 400g (gold %d → %d)" % [gold_before, GameState.gold])
	_check(GameState.player["equipment"]["armor"] == "",
		"…leaving the armor slot empty (created, not filled)")

	# Replace cutlass with rapier: −1200 + 200 = −1000 net, one transaction.
	gold_before = GameState.gold
	_check(ShipyardLib.equip_net_cost("weapon", "eq_rapier") == -1000,
		"replacing the cutlass nets −1200 + 200 = −1000g (got %d)"
		% ShipyardLib.equip_net_cost("weapon", "eq_rapier"))
	var gold_events: Array = []
	var listener := func(new_gold: int) -> void: gold_events.append(new_gold)
	EventBus.gold_changed.connect(listener)
	_check(ShipyardLib.equip("weapon", "eq_rapier"), "replacing it with the rapier succeeds")
	EventBus.gold_changed.disconnect(listener)
	_check(GameState.player["equipment"]["weapon"] == "eq_rapier",
		"…and eq_rapier is worn (got %s)"
		% str(GameState.player["equipment"]["weapon"]))
	_check(GameState.gold == gold_before - 1000,
		"…with a net gold change of −1000g (gold %d → %d)"
		% [gold_before, GameState.gold])
	_check(gold_events.size() == 1 and int(gold_events[0]) == GameState.gold,
		"…announcing exactly one gold_changed, with the net delta (got %s)"
		% str(gold_events))

	# The net cost gates affordability, not the gross price: 1000g suffices.
	GameState.player["equipment"]["weapon"] = "eq_cutlass"
	GameState.gold = 1000
	_check(ShipyardLib.equip_block_reason("weapon", "eq_rapier") == "",
		"1000g is enough to upgrade cutlass → rapier (net cost)")
	_check(ShipyardLib.equip("weapon", "eq_rapier") and GameState.gold == 0,
		"…and the upgrade leaves exactly 0g")
	GameState.player["equipment"]["weapon"] = ""
	GameState.gold = 999
	_check(ShipyardLib.equip_block_reason("weapon", "eq_rapier")
			== "shipyard.no_gold",
		"999g cannot buy the 1200g rapier into an empty slot ('shipyard.no_gold')")
	var gold_refused := GameState.gold
	_check(not ShipyardLib.equip("weapon", "eq_rapier")
		and GameState.gold == gold_refused
		and GameState.player["equipment"]["weapon"] == "",
		"the refused buy changes neither gold nor the slot")

	# Unknown item / slot mismatch.
	_check(ShipyardLib.equip_block_reason("weapon", "eq_nope") == "ui.not_available",
		"an unknown item reports 'ui.not_available'")
	_check(ShipyardLib.equip_block_reason("weapon", "eq_cotton_sails")
			== "ui.not_available",
		"a sail offered to the weapon slot reports 'ui.not_available'")
	_check(ShipyardLib.equip_block_reason("figurehead", "eq_cutlass")
			== "ui.not_available",
		"a weapon offered to a ship slot reports 'ui.not_available'")
	_check(not ShipyardLib.equip("weapon", "eq_nope"),
		"an unknown item cannot be equipped")


# --- 5. Unequip (§4.3) ---------------------------------------------------

func _test_unequip() -> void:
	_make_run(5000, ["caravel"])
	_check(not ShipyardLib.can_unequip("weapon"),
		"an empty slot cannot be unequipped")
	_check(not ShipyardLib.unequip("weapon"),
		"…and unequip() is a no-op (no gold printed from nothing)")
	ShipyardLib.equip("weapon", "eq_rapier")
	var gold_before := GameState.gold
	_check(ShipyardLib.can_unequip("weapon"), "a worn rapier can be unequipped")
	_check(ShipyardLib.unequip("weapon"), "unequip succeeds")
	_check(ShipyardLib.equipped_player("weapon") == "",
		"…and the weapon slot is empty again")
	_check(GameState.gold == gold_before + 600,
		"…paying the 600g rapier sell-back (gold %d → %d)"
		% [gold_before, GameState.gold])
	_check(not ShipyardLib.unequip("weapon"),
		"a second unequip is refused and pays nothing")
	# Cutlass unequip pays 200g, the §4.11.13 example.
	ShipyardLib.equip("weapon", "eq_cutlass")
	gold_before = GameState.gold
	ShipyardLib.unequip("weapon")
	_check(GameState.gold == gold_before + 200,
		"the cutlass sells back for 200g (gold %d → %d)"
		% [gold_before, GameState.gold])


# --- 6. Ship equipment (§4.1, §4.11.12) ---------------------------------

func _test_ship_equipment() -> void:
	_make_run(10000, ["caravel", "sloop"])
	_check(ShipyardLib.ship_max_durability(0) == 90,
		"a bare caravel's effective max is 90 (got %d)"
		% ShipyardLib.ship_max_durability(0))
	_check(ShipyardLib.ship_speed_bonus(0) == 0,
		"a bare caravel has no speed bonus")

	_check(ShipyardLib.equip("figurehead", "eq_mermaid_figurehead", 0),
		"buying the mermaid figurehead onto the caravel succeeds")
	_check(ShipyardLib.ship_max_durability(0) == 100,
		"the mermaid figurehead raises the max by 10 → 100 (got %d)"
		% ShipyardLib.ship_max_durability(0))
	_check(GameState.fleet[0]["durability"] == 90,
		"…without silently healing the current durability")
	_check(ShipyardLib.equip("figurehead", "eq_dragon_figurehead", 0),
		"replacing it with the dragon figurehead succeeds")
	_check(ShipyardLib.ship_max_durability(0) == 110,
		"the dragon figurehead raises the max by 20 → 110 (got %d)"
		% ShipyardLib.ship_max_durability(0))
	_check(ShipyardLib.ship_max_durability(1) == 60,
		"the other hull is unaffected (sloop 60, got %d)"
		% ShipyardLib.ship_max_durability(1))

	_check(ShipyardLib.equip("sail", "eq_cotton_sails", 1),
		"buying cotton sails onto the sloop succeeds")
	_check(ShipyardLib.ship_speed_bonus(1) == 1,
		"the cotton sail adds +1 speed (got %d)"
		% ShipyardLib.ship_speed_bonus(1))
	_check(ShipyardLib.ship_speed_bonus(0) == 0,
		"…only to its own hull (caravel still 0)")
	_check(ShipyardLib.equip("sail", "eq_storm_sails", 1),
		"replacing them with storm sails succeeds")
	_check(ShipyardLib.ship_speed_bonus(1) == 1,
		"storm sails also add +1 speed (got %d)"
		% ShipyardLib.ship_speed_bonus(1))
	_check(ShipyardLib.equipment_modifier("eq_storm_sails", "durability") == 5,
		"storm sails carry their +5 durability modifier too")

	# Ship slots write the hull's own block, never the player's.
	_check((GameState.fleet[1]["equipment"] as Dictionary).get("sail", "")
			== "eq_storm_sails",
		"the sail is stored in fleet[1].equipment")
	_check(GameState.player.get("equipment", {}) == {},
		"…and never on the player block")
	_check(ShipyardLib.equip_block_reason("sail", "eq_cotton_sails", 9)
			== "ui.not_available",
		"equipping onto a missing hull reports 'ui.not_available'")

	# §4.1: repairs use the effective max, so a figurehead can be repaired onto.
	GameState.fleet[0]["durability"] = 100
	_check(ShipyardLib.max_repair_points(0) == 10,
		"a 100/110 hull has 10 points of damage under the effective max (got %d)"
		% ShipyardLib.max_repair_points(0))
	GameState.fleet[0]["durability"] = 60
	_check(ShipyardLib.max_repair_points(0) == 50,
		"a 60/110 hull has 50 points of damage (got %d)"
		% ShipyardLib.max_repair_points(0))
	ShipyardLib.repair(0, 50)
	_check(int(GameState.fleet[0]["durability"]) == 110,
		"a full repair lands on the effective max 110 (got %d)"
		% int(GameState.fleet[0]["durability"]))
	# §4.1: current durability is clamped to the effective max, so removing a
	# figurehead lowers the hull with its cap instead of leaving it above it.
	_check(ShipyardLib.unequip("figurehead", 0), "unequipping the dragon figurehead succeeds")
	_check(ShipyardLib.ship_max_durability(0) == 90,
		"…dropping the max back to 90 (got %d)"
		% ShipyardLib.ship_max_durability(0))
	_check(int(GameState.fleet[0]["durability"]) == 90,
		"…and clamping the 110/110 hull to 90/90 (got %d)"
		% int(GameState.fleet[0]["durability"]))


# --- 7. The duel hook (60-* §4.6, §4.11.6) -------------------------------

func _test_duel_hook() -> void:
	_make_run(10000, ["caravel"])
	_check(ShipyardLib.player_combat_bonus() == 0,
		"a naked captain's duel bonus is 0")
	ShipyardLib.equip("weapon", "eq_cutlass")
	var base: int = ShipyardLib.player_combat_bonus()
	_check(base == 3, "the cutlass adds +3 to the duel base (got %d)" % base)
	# §4.11.6: "Player base = effective combat + Σ combat modifiers on worn
	# weapon/armor". Asserting on the sum is the hook itself; `battle_sim.gd`
	# is another task's file this wave.
	_check(ShipyardLib.player_combat_bonus() == 3,
		"…exactly +3, not +3 twice or a scaled value")
	ShipyardLib.equip("armor", "eq_breastplate")
	_check(ShipyardLib.player_combat_bonus() == 5,
		"cutlass + breastplate = +5 (got %d)"
		% ShipyardLib.player_combat_bonus())
	ShipyardLib.unequip("weapon")
	_check(ShipyardLib.player_combat_bonus() == 2,
		"the breastplate alone = +2 (got %d)"
		% ShipyardLib.player_combat_bonus())
	ShipyardLib.equip("weapon", "eq_rapier")
	_check(ShipyardLib.player_combat_bonus() == 7,
		"rapier + breastplate = +7 (got %d)"
		% ShipyardLib.player_combat_bonus())
	_check(ShipyardLib.equipment_modifier("eq_lucky_charm", "luck") == 5,
		"the lucky charm's +5 luck is a luck modifier, not a combat one")
	ShipyardLib.unequip("weapon")
	ShipyardLib.unequip("armor")
	_check(ShipyardLib.player_combat_bonus() == 0,
		"nothing worn → duel bonus 0 again (got %d)"
		% ShipyardLib.player_combat_bonus())


# --- 8. Refit + the Phase-1 invariants it must not disturb ----------------

func _test_refit_and_phase1_invariants() -> void:
	# §4.3 worked example: 5 cannons on a caravel = 500g, 25 cargo units.
	_make_run(100000, ["caravel"])
	var gold_before := GameState.gold
	var cargo_before: int = FleetLib.used_capacity(GameState.fleet[0])
	_check(ShipyardLib.refit_cost(5) == 500, "5 cannons cost 500g (§4.3)")
	_check(ShipyardLib.refit_cargo_units(5) == 25,
		"5 cannons occupy 25 cargo units (got %d)"
		% ShipyardLib.refit_cargo_units(5))
	_check(ShipyardLib.refit_sellback(5) == 250,
		"5 cannons sell back for 250g (50g each)")
	_check(ShipyardLib.max_refit(0) == 6,
		"a caravel's refit cap is armament_slots 6 (got %d)"
		% ShipyardLib.max_refit(0))
	_check(ShipyardLib.can_refit(0, 5) and not ShipyardLib.can_refit(0, 7),
		"5 cannons fit a caravel; 7 exceed armament_slots")
	_check(ShipyardLib.refit_block_reason(0, 5) == "",
		"an affordable, legal refit has no block reason")
	_check(ShipyardLib.refit_block_reason(0, 0) == "shipyard.invalid_points",
		"0 cannons reports 'shipyard.invalid_points'")
	_check(ShipyardLib.refit_block_reason(0, 7) == "shipyard.invalid_points",
		"7 cannons reports 'shipyard.invalid_points' (cap)")
	_check(ShipyardLib.refit(0, 5), "the 5-cannon refit succeeds")
	_check(GameState.gold == gold_before - 500,
		"…charging exactly 500g (gold %d → %d)" % [gold_before, GameState.gold])
	_check(int(GameState.fleet[0]["cannons"]) == 5,
		"…storing 5 cannons (got %d)" % int(GameState.fleet[0]["cannons"]))
	_check(FleetLib.used_capacity(GameState.fleet[0]) == cargo_before + 25,
		"…and consuming 25 cargo units (%d → %d)" % [
			cargo_before, FleetLib.used_capacity(GameState.fleet[0])
		])
	_check(ShipyardLib.max_refit(0) == 1,
		"after 5 cannons a caravel has 1 spare slot (got %d)"
		% ShipyardLib.max_refit(0))
	_check(not ShipyardLib.can_refit(0, 2),
		"…so a 2-cannon refit is refused")

	# Phase-1 invariants: buy / repair / sell / promote still behave.
	_make_run(100000, ["caravel", "sloop"])
	_check(ShipyardLib.buy("latin") and GameState.fleet.size() == 3,
		"Phase-1 buy still appends a hull")
	_check(ShipyardLib.buy_price("latin") == 1200,
		"Phase-1 buy_price is still ShipType.base_price")
	GameState.fleet[0]["durability"] = 60
	_check(ShipyardLib.max_repair_points(0) == 30,
		"Phase-1 repair cap on an unequipped hull is unchanged (got %d)"
		% ShipyardLib.max_repair_points(0))
	_check(ShipyardLib.repair(0, 10)
		and int(GameState.fleet[0]["durability"]) == 70,
		"Phase-1 partial repair still restores exactly 10 points")
	_check(ShipyardLib.repair_cost(0, 10) == 200,
		"Phase-1 caravel repair is still 20g/point")
	# Sell price: effective max equals the ShipType max while unequipped, so
	# the Phase-1 formula is byte-for-byte the same.
	_check(ShipyardLib.sell_price(1) == 1500,
		"Phase-1 sloop sale is still floor(3000 × 0.5) = 1500g (got %d)"
		% ShipyardLib.sell_price(1))
	_check(ShipyardLib.sell_block_reason(0) == "shipyard.no_sell_flagship",
		"the flagship still cannot be sold")
	_check(ShipyardLib.promote(1)
		and str(GameState.fleet[0]["ship_type_id"]) == "sloop",
		"Phase-1 promote still moves the hull to fleet[0]")

	# A figurehead must not push the sale price over half the base price, even
	# when the hull is repaired to the effective max.
	_make_run(100000, ["caravel", "latin"])
	ShipyardLib.equip("figurehead", "eq_dragon_figurehead", 1)
	GameState.fleet[1]["durability"] = 60
	_check(ShipyardLib.sell_price(1) == 600,
		"a 60/60 latin with a dragon figurehead still sells for 600g (got %d)"
		% ShipyardLib.sell_price(1))
	GameState.fleet[1]["durability"] = 60
	ShipyardLib.repair(1, 10)
	_check(ShipyardLib.sell_price(1) == 600,
		"…and a repair onto the effective max keeps it at 600g (got %d)"
		% ShipyardLib.sell_price(1))

	# FLEET_MAX and the fleet panel's delegation are untouched.
	_make_run(500000, ["caravel"])
	for i in 4:
		ShipyardLib.buy("latin")
	_check(GameState.fleet.size() == 5
		and ShipyardLib.buy_block_reason("latin") == "shipyard.fleet_full",
		"FLEET_MAX 5 and 'shipyard.fleet_full' are unchanged")


# --- 9. The S6 screen's Phase-2 rows (§4.7.2) ----------------------------

func _test_screen() -> void:
	var locale_before: String = GameState.locale
	GameState.locale = "en"
	_make_run(50000, ["caravel", "sloop"])
	var screen = ShipyardScene.instantiate()
	screen.route_to_hub = false
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame

	# §4.7.2: the refit row is live in Phase 2 — a legal count enables it.
	var widgets: Dictionary = screen.fleet_widget(0)
	var refit: Button = widgets["refit"]
	var cannons: LineEdit = widgets["cannons"]
	_check(refit != null and cannons != null and cannons.editable,
		"the shipyard screen instantiates with a live cannons picker")
	_check(refit.disabled,
		"at 0 cannons the Refit button is disabled (§6 validation)")
	cannons.text = "5"
	cannons.text_changed.emit("5")
	_check(not refit.disabled,
		"…and it is ENABLED in Phase 2 once 5 cannons are picked")
	_check((widgets["refit_note"] as Label).text
			== I18n.fmt("shipyard.repair_cost", {"amount": 500}),
		"…with a 500g cost preview (%s)" % (widgets["refit_note"] as Label).text)
	_check((widgets["refit_sellback"] as Label).text
			== I18n.fmt("shipyard.repair_cost", {"amount": 0}),
		"…and the 0g sell-back of the current 0 cannons (%s)"
		% (widgets["refit_sellback"] as Label).text)
	var gold_before := GameState.gold
	refit.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(int(GameState.fleet[0]["cannons"]) == 5,
		"pressing Refit mounts 5 cannons (got %d)"
		% int(GameState.fleet[0]["cannons"]))
	_check(GameState.gold == gold_before - 500,
		"…and charges 500g (gold %d → %d)" % [gold_before, GameState.gold])
	_check((screen.fleet_widget(0)["refit_sellback"] as Label).text
			== I18n.fmt("shipyard.repair_cost", {"amount": 250}),
		"…and the sell-back note now shows 5 × 50g (%s)"
		% (screen.fleet_widget(0)["refit_sellback"] as Label).text)
	# The picker clamps to max_refit.
	var picker: LineEdit = screen.fleet_widget(0)["cannons"]
	picker.text = "99"
	picker.text_changed.emit("99")
	_check(picker.text == "1",
		"an over-large entry clamps to the 1 spare slot (got '%s')" % picker.text)

	# Four slot rows: weapon/armor on the player, figurehead/sail per ship.
	_check(screen.player_equipment_widget("weapon") != null,
		"the player has a weapon equipment row")
	_check(screen.player_equipment_widget("armor") != null,
		"the player has an armor equipment row")
	_check(screen.ship_equipment_widget(0, "figurehead") != null,
		"the caravel has a figurehead equipment row")
	_check(screen.ship_equipment_widget(0, "sail") != null,
		"the caravel has a sail equipment row")
	_check(screen.ship_equipment_widget(1, "sail") != null,
		"every hull has its own sail row")

	# Empty slot shows `ui.empty`; weapon buy list is the two weapons.
	var weapon_row: Dictionary = screen.player_equipment_widget("weapon")
	_check((weapon_row["worn"] as Label).text == I18n.t_key("ui.empty"),
		"an empty weapon slot shows 'ui.empty' (%s)"
		% (weapon_row["worn"] as Label).text)
	var weapon_buys: Dictionary = weapon_row["buy"]
	_check(weapon_buys.size() == 2 and weapon_buys.has("eq_cutlass")
		and weapon_buys.has("eq_rapier"),
		"the weapon row lists both weapons (got %s)" % str(weapon_buys.keys()))
	var cutlass_button: Button = weapon_buys["eq_cutlass"]
	_check(cutlass_button.disabled == false,
		"the affordable cutlass Buy button is enabled")
	_check(cutlass_button.text.contains("400"),
		"…and its label carries the 400g price (%s)" % cutlass_button.text)
	var armor_buys: Dictionary = screen.player_equipment_widget("armor")["buy"]
	_check(armor_buys.size() == 2,
		"the armor row lists both armor items (got %d)" % armor_buys.size())
	var figurehead_buys: Dictionary = \
		screen.ship_equipment_widget(0, "figurehead")["buy"]
	_check(figurehead_buys.size() == 2,
		"the figurehead row lists both figureheads (got %d)"
		% figurehead_buys.size())
	var sail_buys: Dictionary = screen.ship_equipment_widget(0, "sail")["buy"]
	_check(sail_buys.size() == 2,
		"the sail row lists both sails (got %d)" % sail_buys.size())
	var unequip: Button = weapon_row["unequip"]
	_check(unequip.disabled,
		"Unequip is disabled while the slot is empty")

	# Buying from the screen: gold and worn item move together.
	gold_before = GameState.gold
	cutlass_button.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(ShipyardLib.equipped_player("weapon") == "eq_cutlass",
		"pressing Buy wears the cutlass (got '%s')"
		% ShipyardLib.equipped_player("weapon"))
	_check(GameState.gold == gold_before - 400,
		"…and charges 400g (gold %d → %d)" % [gold_before, GameState.gold])
	weapon_row = screen.player_equipment_widget("weapon")
	_check((weapon_row["worn"] as Label).text != I18n.t_key("ui.empty"),
		"the worn slot now shows the item name, not 'ui.empty' (%s)"
		% (weapon_row["worn"] as Label).text)
	_check(not (weapon_row["unequip"] as Button).disabled,
		"…and Unequip becomes enabled")

	# Unequip from the screen pays the half-price sell-back.
	gold_before = GameState.gold
	(weapon_row["unequip"] as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(ShipyardLib.equipped_player("weapon") == "",
		"pressing Unequip clears the slot")
	_check(GameState.gold == gold_before + 200,
		"…and pays the 200g sell-back (gold %d → %d)"
		% [gold_before, GameState.gold])

	# A hull with no spare cannon slots has an inert picker (§6, max_refit 0).
	_make_run(50000, ["caravel"])
	FleetLib.add_goods("wine", 120)
	screen.rebuild()
	await get_tree().process_frame
	_check(ShipyardLib.max_refit(0) == 0, "a full caravel hold leaves no refit room")
	_check(not (screen.fleet_widget(0)["cannons"] as LineEdit).editable
		and (screen.fleet_widget(0)["refit"] as Button).disabled,
		"…so the screen's cannons picker is inert and Refit disabled")

	# A loaded screen: the unaffordable galleon-priced figurehead is disabled
	# with the no_gold reason as its tooltip (§4.7 "tooltip-reason").
	_make_run(500, ["caravel"])
	screen.rebuild()
	await get_tree().process_frame
	var dragon: Button = screen.ship_equipment_widget(0, "figurehead")["buy"][
		"eq_dragon_figurehead"]
	_check(dragon.disabled, "with 500g the 3200g dragon figurehead is disabled")
	_check(dragon.tooltip_text.contains(I18n.t_key("shipyard.no_gold")),
		"…with the 'shipyard.no_gold' reason (%s)" % dragon.tooltip_text)

	# No visible label may print a raw "<key>" (the awaiting-merge keys of
	# §4.7.2 all have fallbacks).
	var unresolved: Array[String] = []
	_collect_unresolved(screen, unresolved)
	_check(unresolved.is_empty(),
		"no visible label prints a raw <key> (found %s)" % str(unresolved))

	# Locale rebind keeps the equipment rows alive and localised.
	_make_run(50000, ["caravel"])
	I18n.set_locale("zh")
	await get_tree().process_frame
	_check(screen.player_equipment_widget("weapon") != null,
		"the equipment rows survive a locale rebind")
	var buy_zh: Button = screen.player_equipment_widget("weapon")["buy"][
		"eq_cutlass"]
	_check(buy_zh.text.contains("水手弯刀"),
		"…and the item name rebinds to zh (%s)" % buy_zh.text)
	I18n.set_locale("en")

	screen.queue_free()
	await get_tree().process_frame
	GameState.locale = locale_before


# --- Harness --------------------------------------------------------------

## Walks every Label/Button/Tooltip under `node` and collects any text shaped
## like `"<a.b.c>"` — the `I18n.t_key` missing-entry marker (§6), which must
## never reach a player.
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
