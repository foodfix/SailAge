extends Node
## T18 acceptance tests (docs/IMPLEMENT-Phase1.md T18; docs/40-SHIPS-AND-FLEET.md
## §4.2–§4.4, §5, §6, §7; docs/20-WORLD-AND-SAILING.md §4.10; docs/80-UI-UX.md
## §4.7, §4.8). Headless scene test:
##
##   godot --headless res://tools/test_fleet.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections:
##   1 the §5 valid caravel loadout passes normalization untouched;
##   2 the over-capacity hand-corrupted save is truncated + logged (§6);
##   3 the flagship-first distribution invariant (§4.2);
##   4 empty fleet / single ship / missing fields never crash;
##   5 promotion: free, port-only, order-preserving, delegated (§4.4);
##   6 jettison per stack, immediate `fleet_free`, `fleet_changed` (§4.10);
##   7 the fleet/cargo panel (rows, durability bar, buttons, sea read-only,
##     confirm dialog, locale rebind, port-hub hook) (§4.7, §4.8);
##   8 the Phase-5 §4.5.1 stat block: three stat lines per ship (durability +
##     cargo, crew + guns, speed + wind), the per-ship supplies-with-days line,
##     and the fleet totals row (pooled supplies, combined days, effective
##     speed).

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const FleetPanelScene := preload("res://scenes/ui_shared/fleet_panel.tscn")
const FleetPanelLib := preload("res://scenes/ui_shared/fleet_panel.gd")
const PortScreenScene := preload("res://scenes/port/port_screen.tscn")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

## The §5 worked loadout: 45 provisions + 45 water + 30 wine = 120 = caravel
## capacity ("45+45+30=120 = ShipType.capacity", `valid: true`).
const CARGO_CAPACITY := 120
const DOC_PROVISIONS := 45
const DOC_WATER := 45
const DOC_WINE := 30

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_valid_loadout_passes()
	_test_over_capacity_truncation()
	_test_flagship_first_invariant()
	_test_degenerate_fleets()
	_test_promote()
	_test_jettison()
	await _test_panel()
	_test_days_formula()
	await _test_stat_block()
	_report()


# --- Fixtures --------------------------------------------------------------

## A docked run (`port` = null leaves the fleet at sea).
func _make_fleet(ship_ids: Array, port = "lisbon") -> void:
	GameState.current_port = port
	GameState.fleet = []
	for ship_id in ship_ids:
		GameState.fleet.append(FleetLib.new_ship(str(ship_id), 0))


## The §5 starter caravel (crew 15, 45 provisions, 45 water, 30 wine).
func _doc_loadout_ship() -> Dictionary:
	var ship := FleetLib.new_ship("caravel", 15)
	ship["provisions"] = DOC_PROVISIONS
	ship["water"] = DOC_WATER
	ship["cargo"] = {"wine": DOC_WINE}
	return ship


# --- 1. The §5 valid loadout passes (§4.2, §7) ----------------------------

func _test_valid_loadout_passes() -> void:
	_make_fleet([])
	var ship := _doc_loadout_ship()
	GameState.fleet = [ship]

	_check(FleetLib.used_capacity(ship) == CARGO_CAPACITY,
		"the §5 loadout uses exactly 120/120 capacity (got %d)"
		% FleetLib.used_capacity(ship))
	_check(FleetLib.free_capacity(ship) == 0,
		"the §5 loadout has 0 free capacity (§5 'free_capacity: 0')")

	var before := _snapshot()
	_count_fleet_changes()  # connect + reset the probe before the call
	var repaired := FleetLib.normalize_all()
	_check(not repaired,
		"normalize_all() returns false for the §5 valid loadout (no repair)")
	_check(_snapshot() == before,
		"normalize_all() changes nothing on the §5 valid loadout (%s)"
		% before)
	_check(not _transition_seen,
		"normalize_all() emits no fleet_changed when nothing changed")

	# The second §5 example (crew-light storm dash, 60+60, empty hold).
	_make_fleet([])
	var dash := FleetLib.new_ship("caravel", 8)
	dash["provisions"] = 60
	dash["water"] = 60
	GameState.fleet = [dash]
	_check(FleetLib.used_capacity(dash) == CARGO_CAPACITY,
		"§5 storm-dash loadout also uses exactly 120 capacity")
	_check(not FleetLib.normalize_all(),
		"normalize_all() accepts the §5 storm-dash loadout unchanged")

	# A save round-trip hands us floats (repo gotcha 1): `45.0` *is* `45`, so an
	# otherwise healthy save must still report "already valid".
	_make_fleet([])
	GameState.fleet = [{
		"ship_type_id": "caravel",
		"durability": 90.0,
		"crew": 15.0,
		"provisions": 45.0,
		"water": 45.0,
		"cannons": 0.0,
		"cargo": {"wine": 30.0},
	}]
	var float_repaired := FleetLib.normalize_all()
	_check(not float_repaired,
		"a JSON-parsed (float) copy of the §5 loadout needs no repair")
	_check(GameState.fleet[0]["provisions"] is int,
		"integral floats are still coerced to int for the maths")

	# The same thing through a *real* JSON round-trip of the §8.1 save shape —
	# the exact path T17's SaveSystem feeds into normalize_all().
	var save_block := {
		"save_version": 1, "day": 12, "gold": 7830,
		"fleet": [_doc_loadout_ship()], "current_port": "lisbon",
		"world": {"position": {"x": 7, "y": 57}, "clock_fraction": 0.25},
	}
	var parsed = JSON.parse_string(JSON.stringify(save_block))
	_check(parsed is Dictionary and parsed["fleet"] is Array,
		"the §8.1 save block round-trips through JSON")
	if parsed is Dictionary:
		GameState.fleet = parsed["fleet"]
		GameState.current_port = parsed["current_port"]
		_check(not FleetLib.normalize_all(),
			"a JSON-round-tripped §5 loadout loads with no repair at all")
		_check(FleetLib.used_capacity(GameState.fleet[0]) == CARGO_CAPACITY,
			"the loaded hold still measures 120/120 (%d)"
			% FleetLib.used_capacity(GameState.fleet[0]))

	# …and a hand-corrupted over-capacity save through the same JSON path.
	var corrupt = JSON.parse_string(JSON.stringify({
		"save_version": 1,
		"fleet": [{
			"ship_type_id": "caravel", "durability": 90, "crew": 15,
			"provisions": 200, "water": 0, "cannons": 0, "cargo": {},
		}],
		"current_port": null,
	}))
	GameState.fleet = corrupt["fleet"]
	GameState.current_port = corrupt["current_port"]
	_check(FleetLib.normalize_all(),
		"a hand-corrupted over-capacity save is reported as repaired at load")
	_check(FleetLib.used_capacity(GameState.fleet[0]) <= CARGO_CAPACITY,
		"the corrupt save's hold fits after the load-time truncation (%d/%d)"
		% [FleetLib.used_capacity(GameState.fleet[0]), CARGO_CAPACITY])


# --- 2. Over-capacity hand-corrupted save (§6) ---------------------------

func _test_over_capacity_truncation() -> void:
	# A caravel's hold is 120; somebody hand-edited the save to 200 provisions.
	_make_fleet([])
	var ship := FleetLib.new_ship("caravel", 15)
	ship["provisions"] = 200
	GameState.fleet = [ship]
	_check(FleetLib.used_capacity(ship) == 200,
		"the corrupt save starts at 200 units in a 120-unit hold")

	var repaired := FleetLib.normalize_all()
	_check(repaired, "normalize_all() reports the over-capacity repair (§6)")
	_check(FleetLib.used_capacity(ship) <= CARGO_CAPACITY,
		"after truncation used %d <= capacity %d"
		% [FleetLib.used_capacity(ship), CARGO_CAPACITY])
	_check(FleetLib.free_capacity(ship) >= 0,
		"after truncation free_capacity is not negative (%d)"
		% FleetLib.free_capacity(ship))
	_check(int(ship["provisions"]) == CARGO_CAPACITY,
		"truncation keeps the last-ditch supplies, dropping the excess (%d)"
		% int(ship["provisions"]))
	_check(FleetLib.normalize_all() == false,
		"the truncated fleet is stable: a second normalize_all() returns false")

	# Trade goods are dropped before supplies (supplies are survival resources).
	_make_fleet([])
	var mixed := FleetLib.new_ship("caravel", 15)
	mixed["provisions"] = 100
	mixed["water"] = 100
	mixed["cargo"] = {"wine": 40}
	GameState.fleet = [mixed]
	_check(FleetLib.normalize_all(), "a mixed over-capacity hold is repaired")
	_check(int(GameState.fleet[0]["cargo"].get("wine", 0)) == 0,
		"trade goods go first when truncating (wine %d)"
		% int(GameState.fleet[0]["cargo"].get("wine", 0)))
	_check(FleetLib.used_capacity(GameState.fleet[0]) <= CARGO_CAPACITY,
		"the mixed corrupt hold fits after truncation (%d)"
		% FleetLib.used_capacity(GameState.fleet[0]))

	# A per-ship overflow on an escort is truncated too, not just the flagship.
	_make_fleet(["caravel", "latin"])
	GameState.fleet[1]["cargo"] = {"salt": 90}  # latin capacity = 30
	_check(FleetLib.normalize_all(), "an over-capacity escort is repaired (§6)")
	_check(FleetLib.used_capacity(GameState.fleet[1]) <= FleetLib.ship_stat(
		GameState.fleet[1], "capacity"),
		"the escort fits its 30-unit hold after truncation (%d)"
		% FleetLib.used_capacity(GameState.fleet[1]))


# --- 3. Flagship-first distribution (§4.2) --------------------------------

func _test_flagship_first_invariant() -> void:
	# Cargo stranded on the escort while the flagship has room.
	_make_fleet(["caravel", "caravel"])
	GameState.fleet[1]["cargo"] = {"wine": 20}
	var repaired := FleetLib.normalize_all()
	_check(repaired,
		"normalize_all() reports the flagship-first repair (§4.2 invariant)")
	_check(int(GameState.fleet[0]["cargo"].get("wine", 0)) == 20,
		"the stranded wine moved to the flagship (flagship %d)"
		% int(GameState.fleet[0]["cargo"].get("wine", 0)))
	_check(int(GameState.fleet[1]["cargo"].get("wine", 0)) == 0,
		"the escort is empty again (escort %d)"
		% int(GameState.fleet[1]["cargo"].get("wine", 0)))
	_check(FleetLib.held("wine") == 20,
		"the repair conserves units (pooled wine %d)" % FleetLib.held("wine"))

	# Already-valid distribution: flagship full, then the escort.
	_make_fleet(["caravel", "caravel"])
	GameState.fleet[0]["cargo"] = {"wine": CARGO_CAPACITY}
	GameState.fleet[1]["cargo"] = {"wine": 10}
	var before := _snapshot()
	_check(not FleetLib.normalize_all(),
		"a flagship-first distribution needs no repair")
	_check(_snapshot() == before,
		"the valid distribution is untouched (%s)" % before)

	# Supplies stranded behind a flagship with room move too.
	_make_fleet(["caravel", "caravel"])
	GameState.fleet[1]["provisions"] = 12
	GameState.fleet[1]["water"] = 6
	_check(FleetLib.normalize_all(), "stranded supplies are moved flagship-first")
	_check(int(GameState.fleet[0]["provisions"]) == 12
			and int(GameState.fleet[0]["water"]) == 6,
		"provisions/water moved to the flagship (%d/%d)"
		% [int(GameState.fleet[0]["provisions"]), int(GameState.fleet[0]["water"])])

	# Leftovers that no earlier hull can take stay put — and the invariant
	# "non-flagship non-empty only if the previous ship is full" still holds.
	_make_fleet(["latin", "caravel"])
	GameState.fleet[0]["cargo"] = {"wine": FleetLib.ship_stat(GameState.fleet[0], "capacity")}
	GameState.fleet[1]["cargo"] = {"wine": 10}
	_check(not FleetLib.normalize_all(),
		"a full flagship legitimately fronts a loaded escort (no repair)")


# --- 4. Empty / single / missing fields ----------------------------------

func _test_degenerate_fleets() -> void:
	_make_fleet([])
	var empty_repaired := FleetLib.normalize_all()
	_check(empty_repaired == false,
		"normalize_all() on an empty fleet returns false and does not crash")

	_make_fleet(["caravel"])
	_check(not FleetLib.normalize_all(), "a single valid ship needs no repair")
	_check(FleetLib.can_promote(0) == false,
		"promoting the flagship is impossible (index 0)")
	_check(FleetLib.can_promote(1) == false,
		"promoting a non-existent ship is refused, not a crash")
	_check(FleetLib.promote(5) == false, "promote(5) on a 1-ship fleet returns false")
	_check(FleetLib.jettison_good(9, "wine") == 0,
		"jettison on an out-of-range index returns 0")
	_check(FleetLib.jettison_supplies(0, "rum") == 0,
		"jettison of an unknown supply kind is refused")

	# A hostile hand-edited save: missing fields, nulls, floats, bad cargo.
	GameState.fleet = [{
		"ship_type_id": "caravel",
		"durability": 90,
		"crew": 15,
		"provisions": null,
		"water": 45.7,
		"cargo": {"wine": 30.2, "salt": -4, "silk": 0},
	}]
	var repaired := FleetLib.normalize_all()
	_check(repaired, "a save with null/float/negative fields is repaired")
	var ship: Dictionary = GameState.fleet[0]
	_check(int(ship["provisions"]) == 0, "null provisions became 0")
	_check(int(ship["water"]) == 45, "float water truncated to 45 (got %s)" % str(ship["water"]))
	_check(int(ship["cannons"]) == 0, "a missing 'cannons' field became 0")
	_check(int(ship["cargo"].get("wine", 0)) == 30,
		"float cargo truncated to 30 (got %s)" % str(ship["cargo"].get("wine", 0)))
	_check(not ship["cargo"].has("salt"), "negative cargo was dropped")
	_check(not ship["cargo"].has("silk"), "zero-quantity cargo was cleaned up")
	_check(FleetLib.used_capacity(ship) <= CARGO_CAPACITY,
		"the repaired ship fits its capacity")

	# Non-dictionary entries and non-array state never crash.
	GameState.fleet = [FleetLib.new_ship("caravel", 0), "not a ship", null]
	var survived := FleetLib.normalize_all()
	_check(survived, "non-dictionary fleet entries are reported, not fatal")
	_check(GameState.fleet.size() == 3,
		"normalize_all() does not silently delete hulls (size %d)"
		% GameState.fleet.size())

	# Unknown ship type: capacity unknown, so the capacity guard is skipped with
	# a warning rather than silently emptying a hold it cannot reason about.
	GameState.fleet = [{"ship_type_id": "ghost_ship", "cargo": {"wine": 5}}]
	_check(FleetLib.normalize_all(), "an unknown ship type is repaired, not fatal")
	_check(FleetLib.held("wine") == 5,
		"an unknown hull keeps its cargo (nothing is destroyed blind): %d"
		% FleetLib.held("wine"))


# --- 5. Promotion (§4.4) --------------------------------------------------

func _test_promote() -> void:
	# Order is preserved for everyone else: [A,B,C,D] → promote(2) → [C,A,B,D].
	_make_fleet(["caravel", "latin", "sloop", "galley"])
	var ids_before: Array = []
	for ship in GameState.fleet:
		ids_before.append(str(ship["ship_type_id"]))
	GameState.gold = 4321
	var gold_before := GameState.gold
	_count_fleet_changes()

	_check(FleetLib.can_promote(2),
		"can_promote(2) is true at port for a non-flagship row")
	_check(FleetLib.promote(2), "promote(2) succeeds at port")
	_check(GameState.gold == gold_before,
		"promotion is free (gold %d → %d)" % [gold_before, GameState.gold])
	var ids_after: Array = []
	for ship in GameState.fleet:
		ids_after.append(str(ship["ship_type_id"]))
	_check(ids_after == ["sloop", "caravel", "latin", "galley"],
		"promote(2) preserves everyone else's order (got %s)" % str(ids_after))
	_check(ids_before.size() == ids_after.size(),
		"promotion keeps the fleet size (%d)" % ids_after.size())
	_check(_transition_seen,
		"promotion emits fleet_changed")
	_check(FleetLib.promote(0) == false, "promoting the flagship is refused")
	_check(FleetLib.promote(2) == true and FleetLib.can_promote(1) == true,
		"promotion is repeatable at port")

	# Port-only: at sea the same call is refused and nothing moves.
	_make_fleet(["caravel", "latin"], null)
	var at_sea_before: Array = []
	for ship in GameState.fleet:
		at_sea_before.append(str(ship["ship_type_id"]))
	_check(not FleetLib.can_promote(1), "can_promote() is false at sea (§4.4)")
	var sea_reason := FleetLib.promote_block_reason(1)
	_check(sea_reason == "fleet.port_only",
		"the at-sea refusal names the port-only rule (%s)" % sea_reason)
	_check(FleetLib.promote(1) == false, "promote() is refused at sea")
	var at_sea_after: Array = []
	for ship in GameState.fleet:
		at_sea_after.append(str(ship["ship_type_id"]))
	_check(at_sea_before == at_sea_after,
		"a refused promotion leaves the fleet untouched (%s)" % str(at_sea_after))

	# Delegation, not duplication: the panel's rule *is* ShipyardEngine's.
	_make_fleet(["caravel", "latin", "sloop"])
	for index in 4:
		_check(FleetLib.can_promote(index) == ShipyardLib.can_promote(index),
			"Fleet.can_promote(%d) delegates to ShipyardEngine (%s)"
			% [index, str(ShipyardLib.can_promote(index))])
	_check(FleetLib.promote_block_reason(0) == "ui.not_available",
		"the flagship row has no promotion reason to offer (ui.not_available)")


# --- 6. Jettison (§4.10) --------------------------------------------------

func _test_jettison() -> void:
	_make_fleet(["caravel"])
	var ship: Dictionary = GameState.fleet[0]
	ship["provisions"] = 20
	ship["water"] = 15
	ship["cargo"] = {"wine": 40, "salt": 10}
	var free_before := FleetLib.fleet_free()
	_check(free_before == CARGO_CAPACITY - 20 - 15 - 50,
		"the fixture starts at %d free" % free_before)

	# Per stack: the whole wine stack leaves, salt keeps its units.
	_count_fleet_changes()
	var removed := FleetLib.jettison_good(0, "wine")
	_check(removed == 40, "jettison_good removes exactly the wine stack (40, got %d)"
		% removed)
	_check(not ship["cargo"].has("wine"), "the wine stack is gone from the hold")
	_check(int(ship["cargo"].get("salt", 0)) == 10,
		"salt is untouched by the wine jettison (%d)"
		% int(ship["cargo"].get("salt", 0)))
	_check(FleetLib.fleet_free() == free_before + 40,
		"fleet_free updates immediately (+40: %d → %d)"
		% [free_before, FleetLib.fleet_free()])
	_check(_transition_seen, "jettison_good emits fleet_changed")

	# Clamps at 0: jettisoning an absent stack removes nothing, drops nothing.
	var free_now := FleetLib.fleet_free()
	_check(FleetLib.jettison_good(0, "wine") == 0,
		"jettisoning an absent stack returns 0")
	_check(FleetLib.fleet_free() == free_now,
		"the no-op jettison leaves fleet_free unchanged (%d)" % FleetLib.fleet_free())
	_check(FleetLib.jettison_good(0, "unknown_good") == 0,
		"jettisoning an unknown good returns 0")

	# Provisions and water are stacks too, with their own call.
	var removed_water := FleetLib.jettison_supplies(0, "water")
	_check(removed_water == 15, "jettison_supplies('water') removes 15 (got %d)"
		% removed_water)
	_check(int(ship["water"]) == 0, "the water stack is zeroed, never negative")
	_check(FleetLib.fleet_free() == free_now + 15,
		"fleet_free follows the water jettison (%d)" % FleetLib.fleet_free())
	var removed_prov := FleetLib.jettison_supplies(0, "provisions")
	_check(removed_prov == 20, "jettison_supplies('provisions') removes 20 (got %d)"
		% removed_prov)
	_check(int(ship["provisions"]) == 0, "provisions clamp at 0")
	var full := FleetLib.ship_stat(ship, "capacity")
	_check(FleetLib.fleet_free() == full - 10,
		"only the salt remains aboard: %d free (got %d)"
		% [full - 10, FleetLib.fleet_free()])
	_check(FleetLib.jettison_supplies(0, "water") == 0,
		"a second water jettison is a clamped no-op")

	# A stack on the escort is jettisoned on that ship only.
	_make_fleet(["caravel", "caravel"])
	GameState.fleet[0]["cargo"] = {"wine": CARGO_CAPACITY}
	GameState.fleet[1]["cargo"] = {"salt": 30}
	_check(FleetLib.jettison_good(1, "salt") == 30,
		"jettison targets the requested ship's stack")
	_check(FleetLib.held("salt") == 0, "the pooled salt count drops to 0")
	_check(FleetLib.held("wine") == CARGO_CAPACITY,
		"the flagship's wine is unaffected by an escort jettison")

	# Jettison is the documented way to make room for supplies (§4.10).
	_make_fleet(["caravel"])
	GameState.fleet[0]["cargo"] = {"wine": CARGO_CAPACITY}
	_check(FleetLib.add_supplies("provisions", 10) == 0,
		"a full hold cannot take provisions")
	FleetLib.jettison_good(0, "wine")
	_check(FleetLib.add_supplies("provisions", 10) == 10,
		"jettison freed room for provisions immediately")


# --- 7. The panel (§4.7, §4.8) -------------------------------------------

func _test_panel() -> void:
	_make_fleet(["caravel", "latin"])
	var flagship: Dictionary = GameState.fleet[0]
	flagship["crew"] = 15
	flagship["provisions"] = 12
	flagship["water"] = 8
	flagship["cargo"] = {"wine": 30}
	GameState.fleet[0]["durability"] = 45  # half-damaged → WARN bar
	GameState.gold = 5000

	var panel: Control = FleetPanelScene.instantiate()
	add_child(panel)
	await get_tree().process_frame

	_check(panel.has_method("attach_to"), "the panel offers attach_to() (host hook)")
	_check(panel.has_method("has_modal") and panel.has_method("is_read_only"),
		"the panel exposes has_modal()/is_read_only() for hosts")

	panel.open()
	await get_tree().process_frame
	_check(panel.is_open(), "open() shows the panel")
	_check(get_tree().get_nodes_in_group("modal_overlay").has(panel),
		"an open panel joins modal_overlay (§6)")
	_check(panel.has_modal(), "has_modal() is true while open")

	var rows: VBoxContainer = panel.get_node("Center/Panel/Margin/Body/Scroll/Rows")
	_check(rows.get_child_count() == 2,
		"one row per hull in GameState.fleet (got %d)" % rows.get_child_count())

	# Row 1: name + flagship tag, durability bar, crew, supplies, cargo stack.
	var row0: Node = rows.get_child(0)
	var top0: HBoxContainer = row0.get_node("Top")
	var name0: Label = top0.get_node("Name")
	_check(name0.text.contains(I18n.t_key("fleet.flagship")),
		"the flagship row is marked (§4.4): %s" % name0.text)
	_check(name0.text.contains(I18n.t(DataLoader.get_ship_type("caravel")["name"])),
		"the flagship row names its data-driven ship type: %s" % name0.text)
	_check(panel.promote_button(0) == null,
		"the flagship row has no Promote button at all")
	_check(panel.promote_button(1) != null,
		"a non-flagship row has a Promote button")

	# §4.5.1 stat block: `Stats` now holds three named lines (durability+cargo,
	# crew+guns, speed), with one supplies line beneath.
	var stats: VBoxContainer = row0.get_node("Stats")
	var durability_line: HBoxContainer = stats.get_node("DurabilityLine")
	var bar: Control = durability_line.get_child(0)
	var fill: ColorRect = bar.get_node("BarFill")
	_check(is_equal_approx(fill.anchor_right, 0.5),
		"the durability bar fills to durability/max (%.2f)" % fill.anchor_right)
	_check(fill.color == Color("#d9a441"),
		"a half-damaged hull paints the WARN tier (§4.8): %s" % str(fill.color))
	_check((stats.get_node("CrewLine/Crew") as Label).text == I18n.fmt(
		"fleet.stat.crew", {"crew": 15, "max": FleetLib.ship_stat(flagship, "crew_max")}),
		"the crew line is localised through fleet.stat.crew")

	var supplies: HBoxContainer = row0.get_node("Supplies")
	_check(supplies.get_child_count() >= 4,
		"provisions and water each render a label + Jettison button")
	var stacks: Array = panel.jettison_buttons(0)
	var kinds: Array = []
	var goods: Array = []
	for entry in stacks:
		if str(entry["kind"]) == "cargo":
			goods.append(str(entry["good_id"]))
		else:
			kinds.append(str(entry["kind"]))
	_check("provisions" in kinds and "water" in kinds,
		"jettison exists for provisions and water (got %s)" % str(kinds))
	_check(goods == ["wine"],
		"jettison exists per trade-good stack (got %s)" % str(goods))

	# At port everything is live; Promote/jettison are enabled.
	var promote: Button = panel.promote_button(1)
	_check(not promote.disabled, "Promote is enabled at port")
	_check(promote.text == I18n.t_key("fleet.promote"),
		"Promote uses fleet.promote (%s)" % promote.text)
	_check(not (panel.jettison_buttons(0)[0]["button"] as Button).disabled,
		"Jettison is enabled at port")

	# Promote through the UI: free, flagship moves to row 0.
	var gold_before := GameState.gold
	promote.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(GameState.gold == gold_before,
		"the panel's Promote is free (gold %d)" % GameState.gold)
	_check(str(GameState.fleet[0]["ship_type_id"]) == "latin",
		"the panel promoted fleet[1] to fleet[0] (got %s)"
		% str(GameState.fleet[0]["ship_type_id"]))
	_check(panel.get_node("Center/Panel/Margin/Body/Scroll/Rows").get_child_count() == 2,
		"the panel rebuilt after promotion")

	# Header: fleet count n/5 + fleet_free.
	var summary: Label = panel.get_node("Center/Panel/Margin/Body/Summary")
	_check(summary.text.contains("/%d" % FleetLib.FLEET_MAX),
		"the header shows the n/5 fleet count: %s" % summary.text)
	_check(summary.text.contains(str(FleetLib.fleet_free())),
		"the header shows fleet_free: %s" % summary.text)

	# Jettison asks for confirmation, then frees the capacity immediately.
	_make_fleet(["caravel"])
	GameState.fleet[0]["cargo"] = {"wine": 40}
	panel.rebuild()
	await get_tree().process_frame
	var free_before := FleetLib.fleet_free()
	var jettison: Button = panel.jettison_button(0, "cargo", "wine")
	_check(jettison != null, "the wine stack has its own Jettison button")
	jettison.pressed.emit()
	await get_tree().process_frame
	_check(panel.has_modal(), "jettison opens a confirm (§4.7)")
	_check(FleetLib.held("wine") == 40,
		"nothing is dropped before the player confirms")
	var confirm: Control = panel.get_node("ConfirmDialog")
	confirm.accept()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(FleetLib.held("wine") == 0, "confirming drops the stack")
	_check(FleetLib.fleet_free() == free_before + 40,
		"the panel shows the new fleet_free immediately (%d)" % FleetLib.fleet_free())

	# Cancel leaves the hold untouched.
	GameState.fleet[0]["cargo"] = {"salt": 25}
	panel.rebuild()
	await get_tree().process_frame
	var salt_button: Button = panel.jettison_button(0, "cargo", "salt")
	_check(salt_button != null, "the salt stack has its own Jettison button")
	salt_button.pressed.emit()
	await get_tree().process_frame
	_check(confirm.is_open(), "jettison opens the confirm dialog (§4.7)")
	confirm.cancel()
	await get_tree().process_frame
	_check(FleetLib.held("salt") == 25, "cancelling the confirm keeps the stack")

	# At sea: read-only, every action disabled with a reason tooltip.
	GameState.current_port = null
	_make_fleet(["caravel", "latin"], null)
	GameState.fleet[0]["cargo"] = {"salt": 25}
	panel.rebuild()
	await get_tree().process_frame
	_check(panel.is_read_only(), "the panel is read-only at sea (§4.4)")
	var sea_promote: Button = panel.promote_button(1)
	_check(sea_promote != null and sea_promote.disabled,
		"Promote is disabled at sea")
	var sea_jettison: Button = panel.jettison_button(0, "cargo", "salt")
	_check(sea_jettison != null and sea_jettison.disabled,
		"Jettison is disabled at sea")
	_check(not sea_jettison.tooltip_text.is_empty(),
		"a disabled Jettison states a reason tooltip (%s)" % sea_jettison.tooltip_text)
	var mode_note: Label = panel.get_node("Center/Panel/Margin/Body/ModeNote")
	_check(mode_note.visible and not mode_note.text.is_empty(),
		"the panel explains the at-sea read-only mode (%s)" % mode_note.text)
	# The click cannot act even if it somehow fires.
	sea_jettison.pressed.emit()
	await get_tree().process_frame
	_check(FleetLib.held("salt") == 25, "a sea jettison click changes nothing")

	# Locale rebind: every visible string follows zh↔en.
	GameState.current_port = "lisbon"
	_make_fleet(["caravel", "latin"])
	GameState.fleet[0]["cargo"] = {"salt": 25}
	panel.rebuild()
	await get_tree().process_frame
	I18n.set_locale("zh")
	await get_tree().process_frame
	var title: Label = panel.get_node("Center/Panel/Margin/Body/Title")
	_check(title.text == I18n.t_key("fleet.title") and title.text == "船队",
		"the panel title rebinds on locale_changed (%s)" % title.text)
	var zh_promote: Button = panel.promote_button(1)
	_check(zh_promote != null and zh_promote.text == I18n.t_key("fleet.promote"),
		"Promote rebinds on locale_changed (%s)"
		% ("-" if zh_promote == null else zh_promote.text))
	I18n.set_locale("en")
	await get_tree().process_frame
	_check(panel.get_node("Center/Panel/Margin/Body/Title").text == I18n.t_key("fleet.title"),
		"the panel returns to en cleanly")

	# No raw "<key>" anywhere in the rendered panel (§6), and no unsubstituted
	# "{placeholder}" left in a visible label or a button tooltip (§4.4).
	var unresolved: Array[String] = []
	_collect_unresolved(panel, unresolved)
	_check(unresolved.is_empty(), "no unresolved <key> text in the panel (%s)"
		% str(unresolved))
	var placeholders: Array[String] = []
	_collect_placeholders(panel, placeholders)
	_check(placeholders.is_empty(),
		"no unsubstituted {placeholder} reaches the player (%s)"
		% str(placeholders))

	# A hand-corrupted fleet must not crash the renderer either (gotcha 5).
	GameState.fleet = [{"ship_type_id": "caravel", "cargo": null}, "junk", null]
	panel.rebuild()
	await get_tree().process_frame
	_check(panel.get_node("Center/Panel/Margin/Body/Scroll/Rows").get_child_count() == 3,
		"the panel renders a corrupted fleet without crashing (3 rows)")
	_check(panel.row_widget(1).is_empty() == false,
		"a non-dictionary fleet entry still gets a row widget")
	# Leave a healthy fleet behind: the shared HUD (not a T18 file) assumes the
	# §4.1 shape and would log on every repaint otherwise.
	_make_fleet(["caravel", "latin"])

	# Esc closes the panel (S4's back edge stays Set Sail).
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	panel._unhandled_input(esc)
	_check(not panel.is_open(), "Esc closes the fleet panel")
	_check(not get_tree().get_nodes_in_group("modal_overlay").has(panel),
		"a closed panel leaves modal_overlay")
	# Closing while a jettison confirm is up must take the confirm with it.
	GameState.fleet[0]["cargo"] = {"wine": 5}
	panel.open()
	await get_tree().process_frame
	(panel.jettison_button(0, "cargo", "wine") as Button).pressed.emit()
	await get_tree().process_frame
	_check((panel.get_node("ConfirmDialog") as Control).is_open(),
		"the confirm is up before the panel closes")
	panel.close()
	await get_tree().process_frame
	_check(not (panel.get_node("ConfirmDialog") as Control).is_open(),
		"closing the panel dismisses its pending confirm")
	_check(not panel.has_modal(), "no modal is left behind by close()")

	# `F` toggles it, like `C` for S14 (docs/80 §4.3).
	var fleet_key := InputEventAction.new()
	fleet_key.action = "toggle_fleet"
	fleet_key.pressed = true
	panel._unhandled_input(fleet_key)
	_check(panel.is_open(), "the toggle_fleet action opens the panel")
	panel._unhandled_input(fleet_key)
	_check(not panel.is_open(), "the toggle_fleet action closes the panel again")

	# F must not stack the panel on top of another open modal (§6).
	var blocker := ColorRect.new()
	blocker.size = Vector2(1, 1)
	add_child(blocker)
	blocker.add_to_group("modal_overlay")
	panel._unhandled_input(fleet_key)
	_check(not panel.is_open(), "F cannot open the panel behind another modal")
	blocker.queue_free()
	panel.queue_free()
	await get_tree().process_frame

	# --- Attach + open from the port hub (S4) ---------------------------
	GameState.current_port = "lisbon"
	var hub: Control = PortScreenScene.instantiate()
	hub.route_to_world = false
	hub.route_to_facility = false
	add_child(hub)
	await get_tree().process_frame
	_check(hub.has_method("open_fleet_panel"),
		"port_screen exposes open_fleet_panel() (the T18 hook)")
	var footer_button: Button = hub.get_node_or_null("Layout/VBox/Footer/Fleet")
	_check(footer_button != null, "the port hub footer has a Fleet row")
	if footer_button != null:
		_check(footer_button.text == I18n.t_key("fleet.title"),
			"the Fleet row is localised (%s)" % footer_button.text)
		_check(footer_button.custom_minimum_size.y == 40.0,
			"the Fleet row uses the 40px button height (§4.8)")
		footer_button.pressed.emit()
		await get_tree().process_frame
		var attached: Control = hub.fleet_panel()
		_check(attached != null and attached.is_open(),
			"the Fleet row opens the fleet panel over S4")
		_check(hub.has_modal(), "the port hub knows the panel is a modal")
		# The `F` action reaches the panel through the real input chain
		# (`push_input` → `_unhandled_input`), not just a direct call.
		attached.close()
		await get_tree().process_frame
		var key := InputEventAction.new()
		key.action = "toggle_fleet"
		key.pressed = true
		get_viewport().push_input(key)
		await get_tree().process_frame
		_check(attached.is_open(),
			"the toggle_fleet action opens the panel from the port hub")
		# Esc while the panel is up closes the panel, not the harbour (§4.3).
		var hub_esc := InputEventAction.new()
		hub_esc.action = "back"
		hub_esc.pressed = true
		hub._unhandled_input(hub_esc)
		await get_tree().process_frame
		_check(GameState.current_port == "lisbon",
			"Esc behind the fleet panel does not leave harbour (current_port %s)"
			% str(GameState.current_port))
		if attached != null:
			I18n.set_locale("zh")
			await get_tree().process_frame
			_check(footer_button.text == I18n.t_key("fleet.title"),
				"the Fleet row rebinds on locale_changed (%s)" % footer_button.text)
			I18n.set_locale("en")
			attached.close()
			await get_tree().process_frame
	hub.queue_free()
	await get_tree().process_frame
	GameState.current_port = null

	# --- Attached to the world map, read-only at sea (S3) ---------------
	var world_scene := load("res://scenes/world/world_map.tscn")
	if world_scene != null:
		var world: Node = world_scene.instantiate()
		add_child(world)
		await get_tree().process_frame
		var sea_panel: Control = world.get_node_or_null("FleetPanelLayer/FleetPanel")
		_check(sea_panel != null,
			"the world map attaches the fleet panel (S3 → S15)")
		if sea_panel != null:
			GameState.current_port = null
			sea_panel.open()
			await get_tree().process_frame
			_check(sea_panel.is_read_only(),
				"the at-sea panel is read-only (§4.4, §6)")
			_check(world.has_method("_modal_open") and world._modal_open(),
				"an open fleet panel freezes world-map input (§6)")
			sea_panel.close()
			await get_tree().process_frame
			_check(not world._modal_open(),
				"closing the panel unfreezes the world map")
		world.queue_free()
		await get_tree().process_frame



# --- 8. Days of supply + the §4.5.1 stat block ----------------------------

## The locked §4.10 formula, proven against the doc's own worked examples.
func _test_days_formula() -> void:
	_check(SailingSimLib.RATION_SIZE == 5, "RATION_SIZE is 5 (§4.5)")
	_check(SailingSimLib.daily_need(15) == 3,
		"15 crew eat ceil(15/5) = 3 units/day")
	_check(SailingSimLib.daily_need(1) == 1, "1 crew eats 1 unit/day")
	_check(SailingSimLib.daily_need(6) == 2, "6 crew eat ceil(6/5) = 2")
	_check(SailingSimLib.daily_need(0) == 0, "0 crew need nothing")
	_check(SailingSimLib.supply_days(45, 45, 15) == 15,
		"starter caravel: 15 crew, 45/45 → 15 days")
	_check(SailingSimLib.supply_days(60, 60, 15) == 20,
		"§4.10 worked example: 60 + 60 units = 20 days")
	_check(SailingSimLib.supply_days(45, 9, 15) == 3,
		"the lesser of the two stacks binds (water 9 / 3 = 3 days)")
	_check(SailingSimLib.supply_days(0, 0, 0) == 0,
		"no crew / no stock is 0 days (the gate reports no_crew first)")


## The §4.5.1 block: three named stat lines + supplies with days per hull, and
## the fleet totals row at the bottom.
func _test_stat_block() -> void:
	_make_fleet(["caravel", "latin"])
	var flagship: Dictionary = GameState.fleet[0]
	flagship["crew"] = 15
	flagship["provisions"] = 45
	flagship["water"] = 45
	flagship["cargo"] = {"wine": 30}
	flagship["durability"] = 45
	flagship["cannons"] = 2
	GameState.fleet[1]["provisions"] = 12
	GameState.fleet[1]["water"] = 12
	GameState.world["weather"] = "fair"
	GameState.gold = 5000
	GameState.current_port = "lisbon"

	var panel: Control = FleetPanelScene.instantiate()
	add_child(panel)
	await get_tree().process_frame
	panel.open()
	await get_tree().process_frame

	var rows: VBoxContainer = panel.get_node(
		"Center/Panel/Margin/Body/Scroll/Rows"
	)
	_check(rows.get_child_count() == 2,
		"one row per hull; the totals row lives outside the list (got %d)"
		% rows.get_child_count())
	var ship_row: Node = rows.get_child(0)
	var stats: VBoxContainer = ship_row.get_node("Stats")
	_check(stats.get_child_count() == 3,
		"three stat lines per ship (§4.5.1): got %d" % stats.get_child_count())

	# Line 1: durability bar + `fleet.stat.durability` + `fleet.stat.cargo`.
	var line1: HBoxContainer = stats.get_node("DurabilityLine")
	var bar: Control = line1.get_node("DurabilityBar")
	_check(bar != null, "line 1 carries the durability bar")
	_check((line1.get_node("Durability") as Label).text == I18n.fmt(
			"fleet.stat.durability", {"current": 45, "max": 90}),
		"line 1 uses fleet.stat.durability (%s)"
		% (line1.get_node("Durability") as Label).text)
	var used := FleetLib.used_capacity(flagship)
	var capacity := FleetLib.ship_stat(flagship, "capacity")
	_check((line1.get_node("Cargo") as Label).text == I18n.fmt(
			"fleet.stat.cargo", {
				"used": used, "capacity": capacity,
				"free": FleetLib.free_capacity(flagship),
			}),
		"line 1 uses fleet.stat.cargo with {used}/{capacity} and {free} (%s)"
		% (line1.get_node("Cargo") as Label).text)

	# Line 2: `fleet.stat.crew` + `fleet.stat.guns`.
	var line2: HBoxContainer = stats.get_node("CrewLine")
	_check((line2.get_node("Crew") as Label).text == I18n.fmt(
			"fleet.stat.crew", {"crew": 15, "max": 45}),
		"line 2 uses fleet.stat.crew (%s)"
		% (line2.get_node("Crew") as Label).text)
	_check((line2.get_node("Guns") as Label).text == I18n.fmt(
			"fleet.stat.guns", {"cannons": 2, "slots": 6}),
		"line 2 uses fleet.stat.guns with {cannons}/{slots} (%s)"
		% (line2.get_node("Guns") as Label).text)

	# Line 3: current effective speed for the flagship + the wind factor.
	var line3: HBoxContainer = stats.get_node("SpeedLine")
	var speed_text := (line3.get_node("Speed") as Label).text
	_check(speed_text == I18n.fmt("fleet.stat.speed", {
			"speed": SailingSimLib.effective_speed(),
			"max": FleetLib.ship_stat(flagship, "speed"),
			"wind": I18n.t_key("world.weather.fair"),
		}),
		"the flagship line shows the current effective speed + the wind (%s)"
		% speed_text)
	_check(speed_text.contains(I18n.t_key("world.weather.fair")),
		"the wind factor is the localised weather name (%s)" % speed_text)
	# A non-flagship shows its hull's base speed (the fleet moves at the slowest).
	var escort_line: HBoxContainer = rows.get_child(1).get_node("Stats/SpeedLine")
	_check((escort_line.get_node("Speed") as Label).text == I18n.fmt(
			"fleet.stat.speed", {
				"speed": FleetLib.ship_stat(GameState.fleet[1], "speed"),
				"max": FleetLib.ship_stat(GameState.fleet[1], "speed"),
				"wind": I18n.t_key("world.weather.fair"),
			}),
		"a non-flagship shows its hull's base speed (%s)"
		% (escort_line.get_node("Speed") as Label).text)

	# Line 4: supplies with days, per ship (§4.10 on its own stack).
	var supplies: HBoxContainer = ship_row.get_node("Supplies")
	_check(supplies.get_child_count() >= 4,
		"provisions and water each render a stat + a Jettison button")
	var provisions_text := (supplies.get_node("Stack_provisions") as Label).text
	_check(provisions_text == I18n.fmt("fleet.stat.supply", {
			"kind": I18n.fmt("world.provisions", {"amount": ""}).strip_edges(),
			"amount": 45, "days": 15,
		}),
		"the provisions line carries its own 15 days (%s)" % provisions_text)
	var water_text := (supplies.get_node("Stack_water") as Label).text
	_check(water_text.contains("15"),
		"the water line carries its own 15 days (%s)" % water_text)

	# The fleet totals row: pooled supplies, combined days, effective speed.
	var totals: VBoxContainer = panel.get_node(
		"Center/Panel/Margin/Body/Totals"
	)
	_check(totals.get_child_count() == 2,
		"the totals row renders a title line and a supplies line")
	var totals_title: Label = totals.get_node("TitleRow/Title")
	_check(totals_title.text == I18n.t_key("fleet.totals"),
		"the totals row is labelled fleet.totals (%s)" % totals_title.text)
	_check(totals.get_node("TitleRow/Speed") != null,
		"the totals row shows the fleet's effective speed")
	var pooled_days := SailingSimLib.fleet_supply_days()
	var total_days: Label = totals.get_node("Supplies/TotalDays")
	_check(total_days.text == I18n.fmt("fleet.total_days", {"days": pooled_days}),
		"the totals row uses fleet.total_days with the pooled days (%s)"
		% total_days.text)
	_check(pooled_days == SailingSimLib.supply_days(
			FleetLib.supplies("provisions"), FleetLib.supplies("water"),
			FleetLib.total_crew()),
		"the pooled days use the same §4.10 formula (%d)" % pooled_days)
	_check(pooled_days == 19,
		"pooled 57 provisions / 57 water at 3/day = 19 days (got %d)"
		% pooled_days)
	_check((totals.get_node("Supplies/Total_provisions") as Label).text
		== I18n.fmt("fleet.stat.supply", {
			"kind": I18n.fmt("world.provisions", {"amount": ""}).strip_edges(),
			"amount": 57, "days": 19,
		}),
		"the totals row pools provisions across the fleet (%s)"
		% (totals.get_node("Supplies/Total_provisions") as Label).text)
	_check((totals.get_node("Supplies/Total_water") as Label).text
		== I18n.fmt("fleet.stat.supply", {
			"kind": I18n.fmt("world.water", {"amount": ""}).strip_edges(),
			"amount": 57, "days": 19,
		}),
		"the totals row pools water across the fleet")

	# Locale rebind covers the new lines.
	I18n.set_locale("zh")
	await get_tree().process_frame
	var zh_rows: VBoxContainer = panel.get_node(
		"Center/Panel/Margin/Body/Scroll/Rows"
	)
	_check((zh_rows.get_child(0).get_node("Stats/CrewLine/Crew") as Label).text
		== I18n.fmt("fleet.stat.crew", {"crew": 15, "max": 45}),
		"the crew line rebinds to zh (%s)"
		% (zh_rows.get_child(0).get_node("Stats/CrewLine/Crew") as Label).text)
	_check((panel.get_node("Center/Panel/Margin/Body/Totals/TitleRow/Title")
		as Label).text == "船队合计", "the totals title rebinds to zh (%s)"
		% (panel.get_node("Center/Panel/Margin/Body/Totals/TitleRow/Title")
			as Label).text)
	I18n.set_locale("en")
	await get_tree().process_frame

	# The at-sea read-only rule still holds with the new block.
	GameState.current_port = null
	panel.rebuild()
	await get_tree().process_frame
	_check(panel.is_read_only(), "the richer panel is still read-only at sea")
	var sea_jettison: Button = panel.jettison_button(0, "cargo", "wine")
	_check(sea_jettison != null and sea_jettison.disabled,
		"jettison is still disabled at sea")

	# A degenerate fleet must not crash the new lines (`_row_speed`/totals).
	GameState.fleet = [{"ship_type_id": "caravel", "cargo": null}, "junk", null]
	panel.rebuild()
	await get_tree().process_frame
	_check(panel.get_node("Center/Panel/Margin/Body/Scroll/Rows")
		.get_child_count() == 3,
		"the stat block renders a corrupted fleet without crashing")
	_check(panel.get_node("Center/Panel/Margin/Body/Totals")
		.get_child_count() == 2,
		"the totals row still renders for a corrupted fleet")

	panel.queue_free()
	await get_tree().process_frame

# --- Harness --------------------------------------------------------------

## True when `fleet_changed` fired since the last [_count_fleet_changes] reset.
var _transition_seen := false


## Starts a fresh fleet_changed observation and returns 0; read
## [_transition_seen] afterwards to see whether the call under test announced a
## change (`fleet_changed` is the only transition signal here, docs/90 §5.1).
func _count_fleet_changes() -> int:
	_transition_seen = false
	if not EventBus.fleet_changed.is_connected(_on_fleet_changed_probe):
		EventBus.fleet_changed.connect(_on_fleet_changed_probe)
	return 0


func _on_fleet_changed_probe() -> void:
	_transition_seen = true


## A comparable dump of the fleet's hold-relevant fields.
func _snapshot() -> String:
	var parts: Array[String] = []
	for ship in GameState.fleet:
		if not (ship is Dictionary):
			parts.append("?")
			continue
		var cargo: Dictionary = ship.get("cargo", {})
		var keys: Array = cargo.keys()
		keys.sort()
		var entries: Array[String] = []
		for key in keys:
			entries.append("%s=%s" % [str(key), str(cargo[key])])
		parts.append("%s|p=%s|w=%s|%s" % [
			str(ship.get("ship_type_id", "")),
			str(ship.get("provisions", 0)),
			str(ship.get("water", 0)),
			",".join(entries),
		])
	return "; ".join(parts)


## Collects any text still shaped like "<a.b.c>" — the `I18n.t_key` missing-key
## marker (§6), which must never reach a player. Checks visible text *and*
## disabled-reason tooltips (§4.7).
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
				and not text.contains(" ") and not found.has(text):
			found.append("%s: %s" % [node.get_path(), text])
		elif text.contains(" <") and text.ends_with(">") and not text.contains(" "):
			found.append("%s: %s" % [node.get_path(), text])
	for child in node.get_children():
		_collect_unresolved(child, found)


## Collects any visible text or tooltip still carrying an unsubstituted
## `{placeholder}` — `I18n.fmt` was skipped somewhere (§4.4).
func _collect_placeholders(node: Node, found: Array[String]) -> void:
	var texts: Array[String] = []
	if node is Label:
		texts.append((node as Label).text)
	elif node is Button:
		texts.append((node as Button).text)
	if node is Control:
		texts.append((node as Control).tooltip_text)
	for text in texts:
		var start := text.find("{")
		if start >= 0 and text.find("}", start) > 0 and not found.has(text):
			found.append("%s: %s" % [node.get_path(), text])
	for child in node.get_children():
		_collect_placeholders(child, found)


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
