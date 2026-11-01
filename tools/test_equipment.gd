extends Node
## Phase-2 task E acceptance tests, reworked for the Phase-7 24-item tiered
## catalog (docs/IMPLEMENT-Phase2.md E; docs/60-COMBAT.md §4.11.6, §4.11.12,
## §4.11.13; docs/40-SHIPS-AND-FLEET.md §4.1, §4.3, §4.3.1;
## docs/50-CHARACTER-AND-PROGRESSION.md §4.8; docs/80-UI-UX.md §4.7.2,
## §4.7.12). Headless:
##
##   godot --headless --path . tools/test_equipment.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: 1 the 24-item tiered data set (2/2/2 per slot, the Phase-2 eight
## preserved, 4 drop-only rares), 2 tolerant accessors & modifiers +
## stock-aware slot lists, 3 equipment prices/sell-back, 4 buying player
## equipment (replace-in-one-transaction, stock gates), 5 unequip, 6 ship
## equipment (figurehead durability, sail speed), 7 the duel hook
## (`player_combat_bonus`), 8 refit buy/sell + the Phase-1 invariants it must
## not disturb, 9 the S6 screen's stock-aware equipment rows.
##
## Flow sections dock at **venice** (dev 3): her equipment_stock carries the
## Phase-2 flow items (rapier, breastplate, mermaid figurehead, storm sails)
## plus the tier-3 angel figurehead, so every transaction is stocked.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const ShipyardScene := preload("res://scenes/port/shipyard_screen.tscn")

## docs/60-COMBAT.md §4.11.13: the Phase-2 eight stay in the 24-item set,
## re-tiered, with their Phase-2 prices and modifiers preserved.
const PHASE2_IDS: Array[String] = [
	"eq_cutlass", "eq_rapier", "eq_breastplate", "eq_lucky_charm",
	"eq_mermaid_figurehead", "eq_dragon_figurehead", "eq_cotton_sails",
	"eq_storm_sails",
]
const PHASE2_SLOTS := {
	"eq_cutlass": "weapon",
	"eq_rapier": "weapon",
	"eq_breastplate": "armor",
	"eq_lucky_charm": "armor",
	"eq_mermaid_figurehead": "figurehead",
	"eq_dragon_figurehead": "figurehead",
	"eq_cotton_sails": "sail",
	"eq_storm_sails": "sail",
}
const PHASE2_PRICES := {
	"eq_cutlass": 400,
	"eq_rapier": 1200,
	"eq_breastplate": 700,
	"eq_lucky_charm": 900,
	"eq_mermaid_figurehead": 1500,
	"eq_dragon_figurehead": 3200,
	"eq_cotton_sails": 1000,
	"eq_storm_sails": 2600,
}
const PHASE2_NAMES := {
	"eq_cutlass": {"zh": "水手弯刀", "en": "Sailor's Cutlass"},
	"eq_rapier": {"zh": "贵族细剑", "en": "Noble's Rapier"},
	"eq_breastplate": {"zh": "胸甲", "en": "Breastplate"},
	"eq_lucky_charm": {"zh": "幸运护符", "en": "Lucky Charm"},
	"eq_mermaid_figurehead": {"zh": "美人鱼船首像", "en": "Mermaid Figurehead"},
	"eq_dragon_figurehead": {"zh": "龙首船像", "en": "Dragon Figurehead"},
	"eq_cotton_sails": {"zh": "棉帆", "en": "Cotton Sails"},
	"eq_storm_sails": {"zh": "风暴帆", "en": "Storm Sails"},
}
const PHASE2_MODIFIERS := {
	"eq_cutlass": {"combat": 3},
	"eq_rapier": {"combat": 5},
	"eq_breastplate": {"combat": 2},
	"eq_lucky_charm": {"combat": 1, "luck": 5},
	"eq_mermaid_figurehead": {"durability": 10},
	"eq_dragon_figurehead": {"durability": 20},
	"eq_cotton_sails": {"speed": 1},
	"eq_storm_sails": {"speed": 1, "durability": 5},
}
## docs/60-* §4.11.13: exactly four rare, drop-only items (one per named
## pirate, `named_pirates.json`).
const RARE_IDS: Array[String] = [
	"eq_khair_scimitar", "eq_bloodhand_cuirass",
	"eq_golden_dragon_figurehead", "eq_red_sail",
]
## The flow port: dev 3, and her equipment_stock holds every item the flow
## sections buy.
const FLOW_PORT := "venice"

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
## and **no** `player.equipment` block (an old save shape) so the tolerance
## of every accessor is exercised first. Default port: venice (dev 3, whose
## equipment_stock carries the flow items).
func _make_run(gold: int = 100000, ship_ids: Array = ["caravel"],
		port = FLOW_PORT) -> void:
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


# --- 1. The 24-item tiered data set (§4.11.13, Phase 7) --------------------

func _test_locked_data() -> void:
	var list: Array = DataLoader.equipment_list
	_check(list.size() == 24,
		"data/equipment.json holds exactly the 24 Phase-7 items (got %d)"
		% list.size())
	_check(DataLoader.equipment.size() == 24,
		"DataLoader indexes all 24 by id (got %d)" % DataLoader.equipment.size())

	var tier_by_slot := {}
	var rare_count := 0
	var prices_ok := true
	var guideline_ok := true
	var modifiers_ok := true
	var phase2_ok := true
	for item in list:
		var item_id := str((item as Dictionary).get("id", ""))
		var slot := str((item as Dictionary).get("slot", ""))
		var tier := int((item as Dictionary).get("tier", 0))
		var price := int((item as Dictionary).get("price", -1))
		tier_by_slot[slot] = int(tier_by_slot.get(slot, 0)) + (1 << (tier - 1))
		if price < 300 or price > 6000:
			prices_ok = false
		if tier == 1 and price > 1500:
			guideline_ok = false
		if tier == 2 and price > 3500:
			guideline_ok = false
		if tier == 3 and price <= 3500:
			guideline_ok = false
		if not ((item as Dictionary).get("modifiers", {}) is Dictionary):
			modifiers_ok = false
		if bool((item as Dictionary).get("rare", false)):
			rare_count += 1
		if item_id in PHASE2_IDS:
			if str((item as Dictionary).get("slot", "")) != PHASE2_SLOTS[item_id] \
				or int((item as Dictionary).get("price", -1)) != PHASE2_PRICES[item_id] \
				or (item as Dictionary).get("name", {}) != PHASE2_NAMES[item_id] \
				or (item as Dictionary).get("modifiers", {}) != PHASE2_MODIFIERS[item_id]:
				phase2_ok = false
	_check(tier_by_slot == {"weapon": 14, "armor": 14, "figurehead": 14, "sail": 14},
		"every slot tiers 2/2/2 (bit-packed per slot, 2·(1+2+4)=14: %s)"
		% str(tier_by_slot))
	_check(rare_count == 4,
		"exactly 4 items carry rare: true (got %d)" % rare_count)
	_check(prices_ok, "every price sits in the 300g–6,000g band")
	_check(guideline_ok,
		"the tier price guideline holds (t1 ≤1500, t2 ≤3500, t3 above)")
	_check(modifiers_ok, "every item carries a modifiers map")
	_check(phase2_ok,
		"the Phase-2 eight keep their §4.11.13 slots, prices, names and "
		+ "modifiers (re-tiered only)")
	for item_id in PHASE2_IDS:
		if DataLoader.get_equipment(item_id).is_empty():
			_check(false, "the Phase-2 id '%s' left the set" % item_id)
	_check(true, "all 8 Phase-2 ids are still present")
	for item_id in RARE_IDS:
		var item: Dictionary = DataLoader.get_equipment(item_id)
		if item.is_empty() or not bool(item.get("rare", false)):
			_check(false, "'%s' should be a rare drop" % item_id)
	_check(true, "the 4 drop ids are all rare:true in the data")
	var drops_ok := true
	for pirate in DataLoader.named_pirates_list:
		if not (str((pirate as Dictionary).get("drop", "")) in RARE_IDS):
			drops_ok = false
	_check(drops_ok and DataLoader.named_pirates_list.size() == 4,
		"all 4 named_pirate drops reference rare items (correction 10)")
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
	# Phase 7 (40-* §4.3.1 / 60-* §4.11.13): slot lists come from the docked
	# port's equipment_stock — venice stocks exactly one weapon, the rapier.
	_check(weapon_ids == ["eq_rapier"],
		"equipment_list('weapon') at venice is her stocked rapier (got %s)"
		% str(weapon_ids))
	var sail_ids: Array[String] = []
	for item in ShipyardLib.equipment_list("sail"):
		sail_ids.append(str(item.get("id", "")))
	_check(sail_ids == ["eq_storm_sails"],
		"equipment_list('sail') at venice is her stocked storm sails (got %s)"
		% str(sail_ids))
	var figurehead_ids: Array[String] = []
	for item in ShipyardLib.equipment_list("figurehead"):
		figurehead_ids.append(str(item.get("id", "")))
	_check(figurehead_ids == ["eq_angel_figurehead", "eq_mermaid_figurehead"],
		"the figurehead list follows venice's stock order (got %s)"
		% str(figurehead_ids))
	_check(ShipyardLib.equipment_list("nonsense").is_empty(),
		"equipment_list('nonsense') is empty")
	# Explicit port argument vs the docked-port resolution.
	var lisbon_weapons: Array[String] = []
	for item in ShipyardLib.equipment_list("weapon", "lisbon"):
		lisbon_weapons.append(str(item.get("id", "")))
	_check(lisbon_weapons == ["eq_zweihander", "eq_cutlass"],
		"equipment_list('weapon', 'lisbon') follows lisbon's stock order "
		+ "(got %s)" % str(lisbon_weapons))
	# No docked port: the full non-rare catalog in data order (standalone
	# screens), rares never (60-* §4.11.13).
	GameState.current_port = ""
	var all_weapons: Array[String] = []
	for item in ShipyardLib.equipment_list("weapon"):
		all_weapons.append(str(item.get("id", "")))
	_check(all_weapons == ["eq_cutlass", "eq_rapier", "eq_backsword",
			"eq_main_gauche", "eq_zweihander"],
		"standalone fallback lists every non-rare weapon in data order "
		+ "(got %s)" % str(all_weapons))
	_make_run(10000, ["caravel"])


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


# --- 4. Buying player equipment (§4.3, §4.11.12; Phase-7 stock gates) -----

func _test_buy_player_equipment() -> void:
	# venice stocks the rapier: a plain 1200g buy into the empty slot.
	_make_run(5000, ["caravel"])
	var gold_before := GameState.gold
	_check(ShipyardLib.equip("weapon", "eq_rapier"), "buying the rapier succeeds")
	_check(GameState.player["equipment"]["weapon"] == "eq_rapier",
		"…and it is the worn weapon (got %s)"
		% str(GameState.player["equipment"]["weapon"]))
	_check(GameState.gold == gold_before - 1200,
		"…for exactly 1200g (gold %d → %d)" % [gold_before, GameState.gold])
	_check(GameState.player["equipment"]["armor"] == "",
		"…leaving the armor slot empty (created, not filled)")

	# Replace cutlass (worn from a drop, not bought here) with the rapier:
	# −1200 + 200 = −1000 net, one transaction. Stock gates the BUY, never
	# the sell-back of what is already worn (§4.3 "in the same action").
	GameState.player["equipment"]["weapon"] = "eq_cutlass"
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

	# Phase-7 stock gates: an item off this port's equipment_stock, and a
	# rare drop-only item, are never purchasable ('ui.not_available').
	_check(ShipyardLib.equip_block_reason("weapon", "eq_cutlass")
			== "ui.not_available",
		"venice does not stock the cutlass — the buy is refused")
	_check(ShipyardLib.equip_block_reason("weapon", "eq_khair_scimitar")
			== "ui.not_available",
		"the rare khair scimitar is refused even where a stock list might "
		+ "name it (defensive, 60-* §4.11.13)")
	GameState.current_port = "lisbon"
	_check(ShipyardLib.equip_block_reason("weapon", "eq_rapier")
			== "ui.not_available",
		"lisbon stocks no rapier — the same buy is refused there")
	_make_run(5000, ["caravel"])

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
	# Cutlass unequip pays 200g, the §4.11.13 example (worn from a drop —
	# unequipping never re-checks the local stock).
	GameState.player["equipment"]["weapon"] = "eq_cutlass"
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
	# Replace with venice's tier-3 angel (+25, 4,800g): mermaid sells back
	# 750 in the same transaction (net −4,050).
	var gold_before := GameState.gold
	_check(ShipyardLib.equip("figurehead", "eq_angel_figurehead", 0),
		"replacing it with the tier-3 angel figurehead succeeds")
	_check(GameState.gold == gold_before - 4050,
		"…netting −4800 + 750 = −4050g (gold %d → %d)"
		% [gold_before, GameState.gold])
	_check(ShipyardLib.ship_max_durability(0) == 115,
		"the angel figurehead raises the max by 25 → 115 (got %d)"
		% ShipyardLib.ship_max_durability(0))
	_check(ShipyardLib.ship_max_durability(1) == 60,
		"the other hull is unaffected (sloop 60, got %d)"
		% ShipyardLib.ship_max_durability(1))

	_check(ShipyardLib.equip("sail", "eq_storm_sails", 1),
		"buying storm sails onto the sloop succeeds")
	_check(ShipyardLib.ship_speed_bonus(1) == 1,
		"the storm sail adds +1 speed (got %d)"
		% ShipyardLib.ship_speed_bonus(1))
	_check(ShipyardLib.ship_speed_bonus(0) == 0,
		"…only to its own hull (caravel still 0)")
	_check(ShipyardLib.equipment_modifier("eq_storm_sails", "durability") == 5,
		"storm sails carry their +5 durability modifier too")

	# Ship slots write the hull's own block, never the player's.
	_check((GameState.fleet[1]["equipment"] as Dictionary).get("sail", "")
			== "eq_storm_sails",
		"the sail is stored in fleet[1].equipment")
	_check(GameState.player.get("equipment", {}) == {},
		"…and never on the player block")
	_check(ShipyardLib.equip_block_reason("sail", "eq_storm_sails", 9)
			== "ui.not_available",
		"equipping onto a missing hull reports 'ui.not_available'")

	# §4.1: repairs use the effective max, so a figurehead can be repaired onto.
	GameState.fleet[0]["durability"] = 100
	_check(ShipyardLib.max_repair_points(0) == 15,
		"a 100/115 hull has 15 points of damage under the effective max (got %d)"
		% ShipyardLib.max_repair_points(0))
	GameState.fleet[0]["durability"] = 60
	_check(ShipyardLib.max_repair_points(0) == 55,
		"a 60/115 hull has 55 points of damage (got %d)"
		% ShipyardLib.max_repair_points(0))
	ShipyardLib.repair(0, 55)
	_check(int(GameState.fleet[0]["durability"]) == 115,
		"a full repair lands on the effective max 115 (got %d)"
		% int(GameState.fleet[0]["durability"]))
	# §4.1: current durability is clamped to the effective max, so removing a
	# figurehead lowers the hull with its cap instead of leaving it above it.
	_check(ShipyardLib.unequip("figurehead", 0), "unequipping the angel figurehead succeeds")
	_check(ShipyardLib.ship_max_durability(0) == 90,
		"…dropping the max back to 90 (got %d)"
		% ShipyardLib.ship_max_durability(0))
	_check(int(GameState.fleet[0]["durability"]) == 90,
		"…and clamping the 115/115 hull to 90/90 (got %d)"
		% int(GameState.fleet[0]["durability"]))


# --- 7. The duel hook (60-* §4.6, §4.11.6) -------------------------------

func _test_duel_hook() -> void:
	_make_run(10000, ["caravel"])
	_check(ShipyardLib.player_combat_bonus() == 0,
		"a naked captain's duel bonus is 0")
	# The cutlass is worn from a drop (venice does not stock it); the worn
	# state — not where it was bought — is what the duel roll reads.
	GameState.player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
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
	# when the hull is repaired to the effective max (venice stocks the
	# tier-3 angel, +25 durability: latin base max 40 → effective 65).
	_make_run(100000, ["caravel", "latin"])
	ShipyardLib.equip("figurehead", "eq_angel_figurehead", 1)
	GameState.fleet[1]["durability"] = 40
	_check(ShipyardLib.sell_price(1) == 369,
		"a 40/65 latin with an angel figurehead sells for floor(600 × 40/65) "
		+ "= 369g, never over half base (got %d)" % ShipyardLib.sell_price(1))
	GameState.fleet[1]["durability"] = 40
	ShipyardLib.repair(1, 25)
	_check(ShipyardLib.sell_price(1) == 600,
		"…and a repair onto the effective max keeps it at exactly 600g (got %d)"
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
	# Lisbon for the screen flows: her equipment_stock carries the 400g
	# cutlass this section buys (venice, the engine-flow port, does not).
	_make_run(50000, ["caravel", "sloop"], "lisbon")
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
	# The screen prefers `shipyard.cannons_sellback` and falls back to
	# `shipyard.repair_cost` until that key lands (see _fmt_or); assert the
	# resolved label either way so the check survives the ui_strings merge.
	_check((widgets["refit_sellback"] as Label).text
			== _refit_label("shipyard.cannons_sellback",
				"shipyard.repair_cost", {"amount": 0}),
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
			== _refit_label("shipyard.cannons_sellback",
				"shipyard.repair_cost", {"amount": 250}),
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

	# Empty slot shows `ui.empty`; the weapon buy list is lisbon's stocked
	# pair — stock-aware rows (40-* §4.3.1), rares never rendered
	# (60-* §4.11.13).
	var weapon_row: Dictionary = screen.player_equipment_widget("weapon")
	_check((weapon_row["worn"] as Label).text == I18n.t_key("ui.empty"),
		"an empty weapon slot shows 'ui.empty' (%s)"
		% (weapon_row["worn"] as Label).text)
	var weapon_buys: Dictionary = weapon_row["buy"]
	_check(weapon_buys.size() == 2 and weapon_buys.has("eq_cutlass")
		and weapon_buys.has("eq_zweihander") and not weapon_buys.has("eq_rapier"),
		"the weapon row lists lisbon's stocked pair (got %s)"
		% str(weapon_buys.keys()))
	var cutlass_button: Button = weapon_buys["eq_cutlass"]
	_check(cutlass_button.disabled == false,
		"the affordable cutlass Buy button is enabled")
	_check(cutlass_button.text.contains("400"),
		"…and its label carries the 400g price (%s)" % cutlass_button.text)
	var armor_buys: Dictionary = screen.player_equipment_widget("armor")["buy"]
	_check(armor_buys.size() == 1 and armor_buys.has("eq_saint_medallion"),
		"the armor row lists lisbon's stocked medallion only — no rare "
		+ "cuirass (got %s)" % str(armor_buys.keys()))
	var figurehead_buys: Dictionary = \
		screen.ship_equipment_widget(0, "figurehead")["buy"]
	_check(figurehead_buys.is_empty(),
		"lisbon stocks no figurehead, so that row lists none (got %d)"
		% figurehead_buys.size())
	var sail_buys: Dictionary = screen.ship_equipment_widget(0, "sail")["buy"]
	_check(sail_buys.size() == 2 and sail_buys.has("eq_brocade_sails")
		and sail_buys.has("eq_cotton_sails"),
		"the sail row lists lisbon's two stocked sails (got %d)"
		% sail_buys.size())
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

	# A loaded screen: the unaffordable 5,000g brocade sails are disabled
	# with the no_gold reason as their tooltip (§4.7 "tooltip-reason").
	_make_run(500, ["caravel"], "lisbon")
	screen.rebuild()
	await get_tree().process_frame
	var brocade: Button = screen.ship_equipment_widget(0, "sail")["buy"][
		"eq_brocade_sails"]
	_check(brocade.disabled, "with 500g the 5000g brocade sails are disabled")
	_check(brocade.tooltip_text.contains(I18n.t_key("shipyard.no_gold")),
		"…with the 'shipyard.no_gold' reason (%s)" % brocade.tooltip_text)
	# The stock gate speaks through the same tooltip channel: lisbon's rows
	# never offered the rapier, so the button simply does not exist.
	_check(not screen.player_equipment_widget("weapon")["buy"].has("eq_rapier"),
		"an unstocked item never renders a button at all (40-* §4.3.1)")

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
		"eq_rapier"]
	_check(buy_zh.text.contains("贵族细剑"),
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


## The screen's `_fmt_or()` contract (owned by `shipyard_screen.gd`): render the
## specific key once `ui_strings.json` carries it, else the shared fallback.
## Tests must mirror it rather than freeze the fallback, or applying the
## pending keys at merge time breaks a green suite.
func _refit_label(key: String, fallback_key: String, values: Dictionary) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.fmt(key, values)
	return I18n.fmt(fallback_key, values)
