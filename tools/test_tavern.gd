extends Node
## T14 acceptance tests (docs/IMPLEMENT-Phase1.md T14; docs/30-* §4.5, §4.7;
## docs/50-* §4.4–§4.5, §6; docs/40-* §4.4; docs/80-* §4.2–§4.3).
##
##   godot --headless res://tools/test_tavern.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const TavernEngineLib := preload("res://scripts/port/tavern_engine.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")

## Caravel: crew_min 15, crew_max 45 (docs/10-* §7.3).
const CARAVEL := "caravel"
const CARAVEL_MIN := 15
const CARAVEL_MAX := 45

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_hire_cost()
	_test_hire_amounts()
	_test_hire_caps()
	_test_fire_floors()
	_test_fire_morale_unchanged()
	_test_officer_pools()
	_test_recruit()
	_test_recruit_blocked()
	_test_dismiss()
	_test_role_bonuses()
	_test_screen_crew_tab()
	_test_screen_officers_tab()
	_test_screen_rumors_tab()
	_test_screen_back()
	_report()


# --- Fixtures --------------------------------------------------------------

## One caravel with `crew` aboard, `gold` in the purse, morale 70.
func _make_run(crew: int = CARAVEL_MIN, gold: int = 10000) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	GameState.gold = gold
	GameState.day = 1
	GameState.morale = 70
	GameState.fleet = [FleetLib.new_ship(CARAVEL, crew)]
	GameState.current_port = "lisbon"
	GameState.world = {"position": {"x": 7, "y": 57}, "clock_fraction": 0.0}


## Detaches a screen from the tree so its EventBus connections drop.
func _drop(node: Node) -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()


# --- §4.5 hire -------------------------------------------------------------

func _test_hire_cost() -> void:
	_make_run()
	_check(SailingSimLib.CREW_WAGE_DAILY == 2, "ledger crew wage is 2g/day")
	_check(TavernEngineLib.per_head() == 20, "20g per head (2 × 10)")
	_check(TavernEngineLib.hire_cost(1) == 20, "hire_cost(1) == 20")
	_check(TavernEngineLib.hire_cost(10) == 200, "hire_cost(10) == 200")
	_check(TavernEngineLib.hire_cost(TavernEngineLib.max_hire()) ==
		20 * TavernEngineLib.max_hire(), "hire_cost(fill) == 20 × heads")
	_check(TavernEngineLib.hire_cost(0) == 0 and TavernEngineLib.hire_cost(-5) == 0,
		"hire_cost of zero/negative heads is 0")

	# A 1-head hire deducts exactly 20g and adds exactly 1 crew.
	_make_run(CARAVEL_MIN, 100)
	_check(TavernEngineLib.hire(1), "hire(1) succeeds")
	_check(GameState.gold == 80, "gold 100 − 20 == 80 (got %d)" % GameState.gold)
	_check(TavernEngineLib.crew() == CARAVEL_MIN + 1,
		"crew 15 → 16 (got %d)" % TavernEngineLib.crew())
	# A 10-head hire deducts exactly 200g.
	_make_run(CARAVEL_MIN, 1000)
	_check(TavernEngineLib.hire(10), "hire(10) succeeds")
	_check(GameState.gold == 800, "gold 1000 − 200 == 800 (got %d)" % GameState.gold)
	_check(TavernEngineLib.crew() == CARAVEL_MIN + 10,
		"crew 15 → 25 (got %d)" % TavernEngineLib.crew())
	# Failed hires are free.
	_make_run(CARAVEL_MIN, 0)
	_check(not TavernEngineLib.hire(1), "hire blocked with no gold")
	_check(GameState.gold == 0 and TavernEngineLib.crew() == CARAVEL_MIN,
		"a blocked hire changes nothing")


func _test_hire_amounts() -> void:
	# "+1 / +10 / Fill" amounts, all capped by crew_max.
	_make_run(CARAVEL_MIN, 10000)
	_check(TavernEngineLib.max_hire() == CARAVEL_MAX - CARAVEL_MIN,
		"max_hire == crew_max − crew == 30 (got %d)" % TavernEngineLib.max_hire())
	_check(TavernEngineLib.fill_heads() == 30,
		"Fill hires all 30 head when the purse allows (got %d)"
		% TavernEngineLib.fill_heads())
	_check(TavernEngineLib.hire(TavernEngineLib.fill_heads()), "Fill succeeds")
	_check(TavernEngineLib.crew() == CARAVEL_MAX,
		"Fill lands exactly on crew_max 45 (got %d)" % TavernEngineLib.crew())
	_check(GameState.gold == 10000 - 600, "Fill costs 30 × 20 = 600g (got %d gold)"
		% GameState.gold)

	# Fill is purse-limited, never crew_max-limited into unaffordable territory.
	_make_run(CARAVEL_MIN, 65)
	_check(TavernEngineLib.fill_heads() == 3,
		"Fill with 65g hires 3 head (20g each), not 30 (got %d)"
		% TavernEngineLib.fill_heads())

	# Fill with less than one head's fee hires nothing.
	_make_run(CARAVEL_MIN, 19)
	_check(TavernEngineLib.fill_heads() == 0, "Fill with 19g hires 0 head")
	_check(not TavernEngineLib.hire(0), "hire(0) is rejected")
	_check(not TavernEngineLib.hire(-3), "hire(-3) is rejected")

	# "+10" clamps at the cap even when 10 would fit in the purse but not the hull.
	_make_run(CARAVEL_MAX - 4, 10000)
	_check(TavernEngineLib.hire_cost(10) == 200, "10-head price is still 200g")
	_check(not TavernEngineLib.can_hire(10),
		"+10 is disabled with only 4 berths left")
	_check(TavernEngineLib.can_hire(4), "+4 exactly fills the last berths")
	_check(TavernEngineLib.hire(4), "hire(4) succeeds at the margin")
	_check(TavernEngineLib.crew() == CARAVEL_MAX, "crew lands exactly on 45")


func _test_hire_caps() -> void:
	_make_run(CARAVEL_MAX, 10000)
	_check(TavernEngineLib.max_hire() == 0, "at crew_max max_hire is 0")
	_check(not TavernEngineLib.can_hire(1), "hire disabled at crew_max")
	_check(not TavernEngineLib.hire(1), "hire() refuses past crew_max")
	_check(TavernEngineLib.crew() == CARAVEL_MAX and GameState.gold == 10000,
		"a capped hire costs nothing")
	_check(TavernEngineLib.fill_heads() == 0, "Fill is 0 at crew_max")

	# Gold shortfall disables hire even with berths free (§6 edge rule).
	_make_run(CARAVEL_MIN, 19)
	_check(TavernEngineLib.max_hire() > 0, "berths are free")
	_check(not TavernEngineLib.can_hire(1), "1-head hire disabled with 19g")
	_make_run(CARAVEL_MIN, 20)
	_check(TavernEngineLib.can_hire(1), "gold exactly == cost is allowed")
	_check(TavernEngineLib.hire(1), "hire succeeds at exactly 20g")
	_check(GameState.gold == 0, "gold becomes 0")

	# crew_max comes from the flagship's ShipType, not a constant.
	_make_run(CARAVEL_MIN, 10000)
	GameState.fleet = [FleetLib.new_ship("galleon", 100)]
	_check(TavernEngineLib.crew_max() == 150,
		"galleon flagship: crew_max 150 (got %d)" % TavernEngineLib.crew_max())
	_check(TavernEngineLib.crew_min() == 40,
		"galleon flagship: crew_min 40 (got %d)" % TavernEngineLib.crew_min())
	_check(not TavernEngineLib.hire(TavernEngineLib.max_hire() + 1),
		"hire never exceeds the galleon's crew_max")
	_check(TavernEngineLib.hire(50), "50 head fit a galleon")
	_check(TavernEngineLib.crew() == 150, "galleon crew lands on 150")


# --- §4.5 fire -------------------------------------------------------------

func _test_fire_floors() -> void:
	_make_run(CARAVEL_MIN, 1000)
	_check(TavernEngineLib.min_fire() == 0, "at crew_min nothing can be fired")
	_check(not TavernEngineLib.can_fire(1), "fire disabled at crew_min")
	_check(not TavernEngineLib.fire(1), "fire() refuses below crew_min")
	_check(TavernEngineLib.crew() == CARAVEL_MIN, "crew unchanged at the floor")

	_make_run(CARAVEL_MAX, 1000)
	_check(TavernEngineLib.min_fire() == CARAVEL_MAX - CARAVEL_MIN,
		"min_fire == crew − crew_min == 30 (got %d)" % TavernEngineLib.min_fire())
	_check(TavernEngineLib.fire(1), "fire(1) succeeds above the floor")
	_check(TavernEngineLib.crew() == CARAVEL_MAX - 1, "crew 45 → 44")
	_check(TavernEngineLib.fire(10), "fire(10) succeeds above the floor")
	_check(TavernEngineLib.crew() == CARAVEL_MAX - 11, "crew 44 → 34")
	_check(TavernEngineLib.fire(TavernEngineLib.min_fire()),
		"Down to min succeeds")
	_check(TavernEngineLib.crew() == CARAVEL_MIN,
		"Down to min lands exactly on crew_min 15 (got %d)" % TavernEngineLib.crew())

	# −1 / −10 clamp: the clamping variant fires only what the floor allows and
	# reports the actual number (docs/30-* §6 "−1/−10 clamp likewise").
	_make_run(CARAVEL_MIN + 5, 1000)
	_check(TavernEngineLib.min_fire() == 5, "5 head are fireable above the floor")
	_check(TavernEngineLib.fire_clamped(10) == 5, "fire_clamped(10) fires 5")
	_check(TavernEngineLib.crew() == CARAVEL_MIN, "crew lands on crew_min")
	_check(TavernEngineLib.fire_clamped(1) == 0, "fire_clamped(1) fires 0 at the floor")
	_check(TavernEngineLib.crew() == CARAVEL_MIN, "the floor holds after a clamped fire")

	# The strict variant refuses outright instead of partially firing.
	_make_run(CARAVEL_MIN + 5, 1000)
	_check(not TavernEngineLib.fire(10), "fire(10) refuses with only 5 above the floor")
	_check(TavernEngineLib.crew() == CARAVEL_MIN + 5,
		"a refused strict fire changes nothing")

	_make_run(CARAVEL_MIN)
	_check(not TavernEngineLib.fire(0), "fire(0) is rejected")
	_check(not TavernEngineLib.fire(-2), "fire(-2) is rejected")
	_check(TavernEngineLib.fire_clamped(0) == 0, "fire_clamped(0) fires 0")
	_check(TavernEngineLib.fire_clamped(-2) == 0, "fire_clamped(-2) fires 0")

	# No severance: gold is untouched by firing.
	_make_run(CARAVEL_MAX, 777)
	TavernEngineLib.fire(10)
	_check(GameState.gold == 777, "firing pays no severance (gold 777, got %d)"
		% GameState.gold)

	# crew_min follows the flagship type.
	_make_run(100, 1000)
	GameState.fleet = [FleetLib.new_ship("galleon", 100)]
	_check(TavernEngineLib.crew_min() == 40, "galleon crew_min 40")
	_check(TavernEngineLib.fire(60), "60 of 100 galleon crew can go")
	_check(TavernEngineLib.crew() == 40, "galleon crew lands on 40")
	_check(not TavernEngineLib.fire(1), "galleon floor is enforced too")


func _test_fire_morale_unchanged() -> void:
	for morale in [70, 10, 95]:
		_make_run(CARAVEL_MAX, 1000)
		GameState.morale = morale
		TavernEngineLib.fire(10)
		_check(GameState.morale == morale,
			"firing 10 at morale %d leaves morale untouched (got %d)"
			% [morale, GameState.morale])
	# Neither does hiring.
	_make_run(CARAVEL_MIN, 1000)
	GameState.morale = 42
	TavernEngineLib.hire(5)
	_check(GameState.morale == 42,
		"hiring 5 leaves morale untouched (got %d)" % GameState.morale)


# --- §4.4 officers at port -------------------------------------------------

func _test_officer_pools() -> void:
	_make_run()
	# The six locked mappings from data/officers.json (docs/10-* §7.5), asserted
	# literally so a data edit that silently drops a port fails this test.
	var expected := {
		"off_mateus_alvares": ["lisbon", "madeira"],
		"off_diego_fernandez": ["seville", "ceuta"],
		"off_thomas_reed": ["london"],
		"off_jan_de_vries": ["amsterdam", "antwerp"],
		"off_kemal_agha": ["istanbul", "smyrna"],
		"off_marco_bellini": ["venice", "genoa"],
	}
	for officer_id in expected:
		var ports: Array = DataLoader.get_officer(str(officer_id)).get(
			"recruit_ports", []
		)
		_check(ports == expected[officer_id], "%s recruit_ports == %s (got %s)"
			% [officer_id, str(expected[officer_id]), str(ports)])
		for port_id in expected[officer_id]:
			_check(TavernEngineLib.officers_at_port(str(port_id)) == [officer_id],
				"%s is the only officer at %s (got %s)" % [
					officer_id, port_id,
					str(TavernEngineLib.officers_at_port(str(port_id))),
				])

	# All six officers, each only where its data says (docs/10-* §7.5).
	var seen := 0
	for officer in DataLoader.officers_list:
		seen += 1
		var officer_id := str(officer.get("id", ""))
		var ports: Array = officer.get("recruit_ports", [])
		_check(not ports.is_empty(), "%s declares recruit_ports" % officer_id)
		for port_id in ports:
			_check(TavernEngineLib.officers_at_port(str(port_id)).has(officer_id),
				"%s appears at its recruit port %s" % [officer_id, port_id])
		# Every other port in the world must not list it.
		var strays := 0
		for port in DataLoader.ports_list:
			var port_id := str(port.get("id", ""))
			if ports.has(port_id):
				continue
			if TavernEngineLib.officers_at_port(port_id).has(officer_id):
				strays += 1
		_check(strays == 0, "%s appears at no other port (%d strays)"
			% [officer_id, strays])
	_check(seen == 6, "the locked roster has exactly 6 officers (got %d)" % seen)

	# Spot-checks against data/officers.json.
	_check(TavernEngineLib.officers_at_port("lisbon") == ["off_mateus_alvares"],
		"lisbon lists only Mateus Álvares (%s)"
		% str(TavernEngineLib.officers_at_port("lisbon")))
	_check(TavernEngineLib.officers_at_port("madeira") == ["off_mateus_alvares"],
		"madeira lists Mateus Álvares")
	_check(TavernEngineLib.officers_at_port("london") == ["off_thomas_reed"],
		"london lists Thomas Reed")
	_check(TavernEngineLib.officers_at_port("athens").is_empty(),
		"a port outside every recruit_ports list is empty")
	_check(TavernEngineLib.officers_at_port("").is_empty(),
		"an empty port id lists nobody")
	_check(TavernEngineLib.officers_at_port("not_a_port").is_empty(),
		"an unknown port id lists nobody")

	# Data-driven: a fake officer added to the cache appears with no code edit.
	var fake := {
		"id": "off_test_fake", "role": "navigator", "wage_daily": 1,
		"recruit_ports": ["athens"], "name": {"zh": "测试", "en": "Test"},
		"bio": {"zh": "测试", "en": "Test"}, "stats": {},
	}
	DataLoader.officers_list.append(fake)
	DataLoader.officers["off_test_fake"] = fake
	_check(TavernEngineLib.officers_at_port("athens") == ["off_test_fake"],
		"a data-only officer shows up at its port")
	DataLoader.officers_list.pop_back()
	DataLoader.officers.erase("off_test_fake")


# --- §4.4 recruit ----------------------------------------------------------

func _test_recruit() -> void:
	_make_run(CARAVEL_MIN, 5000)
	_check(CharacterLib.recruit_cost("off_mateus_alvares") == 300,
		"Mateus signs for wage 30 × 10 = 300g")
	_check(CharacterLib.recruit("off_mateus_alvares"), "recruit succeeds")
	_check(GameState.gold == 4700, "signing fee 300g deducted (got %d)" % GameState.gold)
	_check(GameState.player["officers"] == ["off_mateus_alvares"],
		"roster stores the officer id in player.officers")

	# Vanishes from every tavern while employed (both its recruit ports).
	for port_id in ["lisbon", "madeira", "london", "venice", "athens"]:
		_check(not TavernEngineLib.officers_at_port(port_id).has("off_mateus_alvares"),
			"%s no longer lists the employed officer" % port_id)

	# One-time hire: a second recruit of the same officer is impossible.
	_check(not CharacterLib.can_recruit("off_mateus_alvares"),
		"an employed officer cannot be re-recruited")
	_check(not CharacterLib.recruit("off_mateus_alvares"),
		"recruit() refuses a second signing")


func _test_recruit_blocked() -> void:
	# OFFICER_MAX = 3 blocks the fourth.
	_make_run(CARAVEL_MIN, 20000)
	_check(CharacterLib.OFFICER_MAX == 3, "OFFICER_MAX is 3")
	CharacterLib.recruit("off_mateus_alvares")
	CharacterLib.recruit("off_diego_fernandez")
	CharacterLib.recruit("off_thomas_reed")
	_check(CharacterLib.officer_count() == 3, "three officers aboard")
	_check(not CharacterLib.can_recruit("off_kemal_agha"),
		"a 4th officer is blocked by OFFICER_MAX")
	_check(not CharacterLib.recruit("off_kemal_agha"), "recruit() refuses the 4th")
	_check(CharacterLib.officer_count() == 3, "roster stays at 3")
	_check(GameState.gold == 20000 - 300 - 280 - 320,
		"only three signing fees were paid (got %d gold)" % GameState.gold)

	# Gold shortfall blocks the signing and shows a price (§6).
	_make_run(CARAVEL_MIN, 299)
	_check(not CharacterLib.can_recruit("off_mateus_alvares"),
		"recruit disabled at 299g for a 300g signing fee")
	_make_run(CARAVEL_MIN, 300)
	_check(CharacterLib.can_recruit("off_mateus_alvares"),
		"gold exactly == signing fee is allowed")
	_check(CharacterLib.recruit("off_mateus_alvares"), "recruit at exactly 300g")
	_check(GameState.gold == 0, "gold becomes 0 after the signing fee")


func _test_dismiss() -> void:
	_make_run(CARAVEL_MIN, 5000)
	CharacterLib.recruit("off_mateus_alvares")
	CharacterLib.recruit("off_diego_fernandez")
	_check(GameState.player["officers"].size() == 2, "two officers aboard")

	_check(CharacterLib.dismiss("off_mateus_alvares"), "dismiss succeeds")
	_check(GameState.player["officers"] == ["off_diego_fernandez"],
		"player.officers shrinks to the remaining officer")
	_check(CharacterLib.officer_count() == 1, "officer_count is 1")
	_check(GameState.gold == 5000 - 300 - 280,
		"dismissal pays no severance (got %d gold)" % GameState.gold)

	# Back in the pool: visible again at every one of its recruit ports.
	for port_id in ["lisbon", "madeira"]:
		_check(TavernEngineLib.officers_at_port(port_id).has("off_mateus_alvares"),
			"%s lists the dismissed officer again" % port_id)
	_check(not TavernEngineLib.officers_at_port("london").has("off_mateus_alvares"),
		"returning to the pool does not leak it to other ports")

	# And recruitable again (paying the fee a second time — one-time = per hire).
	_check(CharacterLib.can_recruit("off_mateus_alvares"),
		"a dismissed officer can be signed again")
	_check(CharacterLib.recruit("off_mateus_alvares"), "re-recruit succeeds")
	_check(GameState.gold == 5000 - 300 - 280 - 300,
		"re-recruiting pays the fee again (got %d gold)" % GameState.gold)

	# Dismissing someone not aboard is a no-op.
	_check(not CharacterLib.dismiss("off_marco_bellini"),
		"dismissing an un-employed officer returns false")


# --- §4.5 role bonuses through effective_stat ------------------------------

func _test_role_bonuses() -> void:
	_make_run(CARAVEL_MIN, 20000)
	_check(CharacterLib.effective_stat("navigation") == 10,
		"no officers: navigation 10")
	_check(CharacterLib.effective_stat("seamanship") == 10,
		"no officers: seamanship 10")
	_check(CharacterLib.effective_stat("combat") == 10,
		"no officers: combat 10")

	CharacterLib.recruit("off_mateus_alvares")  # navigator
	_check(CharacterLib.effective_stat("navigation") == 20,
		"navigator raises navigation by 10 (10 → %d)"
		% CharacterLib.effective_stat("navigation"))
	CharacterLib.recruit("off_jan_de_vries")  # boatswain
	_check(CharacterLib.effective_stat("seamanship") == 20,
		"boatswain raises seamanship by 10 (10 → %d)"
		% CharacterLib.effective_stat("seamanship"))
	CharacterLib.recruit("off_thomas_reed")  # gunner
	_check(CharacterLib.effective_stat("combat") == 20,
		"gunner raises combat by 10 (10 → %d)"
		% CharacterLib.effective_stat("combat"))
	_check(CharacterLib.officer_count() == 3, "three roles aboard")

	# Two same-role officers stack (+20).
	_make_run(CARAVEL_MIN, 20000)
	CharacterLib.recruit("off_mateus_alvares")
	CharacterLib.recruit("off_marco_bellini")
	_check(CharacterLib.effective_stat("navigation") == 30,
		"two navigators stack: 10 + 10 + 10 == 30 (got %d)"
		% CharacterLib.effective_stat("navigation"))

	# Two boatswains stack as well.
	_make_run(CARAVEL_MIN, 20000)
	CharacterLib.recruit("off_diego_fernandez")
	CharacterLib.recruit("off_jan_de_vries")
	_check(CharacterLib.effective_stat("seamanship") == 30,
		"two boatswains stack: 10 + 10 + 10 == 30 (got %d)"
		% CharacterLib.effective_stat("seamanship"))

	# Dismissal removes the bonus again.
	_make_run(CARAVEL_MIN, 20000)
	CharacterLib.recruit("off_mateus_alvares")
	CharacterLib.dismiss("off_mateus_alvares")
	_check(CharacterLib.effective_stat("navigation") == 10,
		"dismissing the navigator drops navigation back to 10 (got %d)"
		% CharacterLib.effective_stat("navigation"))

	# The navigator's +10 flows into the §4.2 derived sighting radius.
	_make_run(CARAVEL_MIN, 20000)
	_check(CharacterLib.sighting_radius() == 8, "sighting radius 8 without officers")
	CharacterLib.recruit("off_mateus_alvares")
	_check(CharacterLib.sighting_radius() == 9,
		"navigator raises the sighting radius to 9 (got %d)"
		% CharacterLib.sighting_radius())


# --- Screen: Crew tab ------------------------------------------------------

func _test_screen_crew_tab() -> void:
	_make_run(CARAVEL_MIN, 1000)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var screen = TavernScene.instantiate()
	screen.route_to_port = false
	host.add_child(screen)
	_check(screen.active_tab() == "crew", "the crew tab opens first")
	_check(screen.get_node("Layout/VBox/Body/CrewPanel").visible,
		"the crew panel is visible on open")
	_check(not screen.get_node("Layout/VBox/Body/OfficersPanel").visible,
		"the officers panel is hidden on open")

	var count: Label = screen.get_node("Layout/VBox/Body/CrewPanel/CrewCount")
	_check(count.text == I18n.fmt("tavern.crew_count", {"crew": 15, "max": 45}),
		"crew row reads 15/45 (%s)" % count.text)
	var per_head: Label = screen.get_node("Layout/VBox/Body/CrewPanel/PerHead")
	_check(per_head.text == I18n.fmt("tavern.per_head", {"price": 20}),
		"cost preview reads 20g per head (%s)" % per_head.text)

	var hire_1: Button = screen.get_node("Layout/VBox/Body/CrewPanel/HireRow/Hire1")
	var hire_10: Button = screen.get_node("Layout/VBox/Body/CrewPanel/HireRow/Hire10")
	var fill: Button = screen.get_node("Layout/VBox/Body/CrewPanel/HireRow/Fill")
	_check(hire_1.text == I18n.fmt("tavern.hire", {"qty": 1}), "Hire 1 label")
	_check(hire_10.text == I18n.fmt("tavern.hire", {"qty": 10}), "Hire 10 label")
	_check(fill.text == I18n.t_key("tavern.fill"), "Fill label")

	# +1 through the button.
	hire_1.pressed.emit()
	_check(TavernEngineLib.crew() == 16, "the Hire 1 button hires one head")
	_check(GameState.gold == 980, "the Hire 1 button pays 20g (got %d)" % GameState.gold)
	_check(count.text == I18n.fmt("tavern.crew_count", {"crew": 16, "max": 45}),
		"the crew row rebinds after hiring (%s)" % count.text)

	# +10 through the button.
	hire_10.pressed.emit()
	_check(TavernEngineLib.crew() == 26, "the Hire 10 button hires ten head")
	_check(GameState.gold == 780, "the Hire 10 button pays 200g (got %d)" % GameState.gold)

	# Fill through the button.
	fill.pressed.emit()
	_check(TavernEngineLib.crew() == CARAVEL_MAX, "the Fill button tops up to 45")
	_check(hire_1.disabled and hire_10.disabled and fill.disabled,
		"all hire buttons disable at crew_max")
	var reason: Label = screen.get_node("Layout/VBox/Body/CrewPanel/Reason")
	_check(reason.visible and not reason.text.is_empty(),
		"a disabled reason is shown at the cap (%s)" % reason.text)
	_check(reason.text.contains("45"), "the cap reason names crew_max 45 (%s)"
		% reason.text)
	_check(not hire_1.tooltip_text.is_empty(),
		"the capped hire button repeats the reason as a tooltip")

	# Short of gold → disabled with the no-gold reason.
	_make_run(CARAVEL_MIN, 19)
	screen.refresh()
	_check(hire_1.disabled, "Hire 1 disables at 19g")
	_check(not hire_1.tooltip_text.is_empty(),
		"the disabled hire button explains the price (%s)" % hire_1.tooltip_text)
	_check(reason.visible and reason.text == I18n.t_key("market.no_gold"),
		"the no-gold reason is shown (%s)" % reason.text)

	# Fire buttons: disabled at crew_min, enabled above, "Down to min" exact.
	_make_run(CARAVEL_MIN, 1000)
	screen.refresh()
	var fire_1: Button = screen.get_node("Layout/VBox/Body/CrewPanel/FireRow/Fire1")
	var fire_10: Button = screen.get_node("Layout/VBox/Body/CrewPanel/FireRow/Fire10")
	var down: Button = screen.get_node("Layout/VBox/Body/CrewPanel/FireRow/DownToMin")
	_check(fire_1.disabled and fire_10.disabled and down.disabled,
		"all fire buttons disable at crew_min")
	_check(not fire_1.tooltip_text.is_empty(),
		"a disabled fire button explains the floor (%s)" % fire_1.tooltip_text)
	var min_note: Label = screen.get_node("Layout/VBox/Body/CrewPanel/MinNote")
	_check(min_note.text == I18n.fmt("tavern.crew_min_note", {"crew": 15}),
		"the crew_min note reads 15 (%s)" % min_note.text)

	_make_run(CARAVEL_MAX, 1000)
	screen.refresh()
	_check(not fire_1.disabled and not fire_10.disabled and not down.disabled,
		"fire buttons enable above crew_min")
	fire_1.pressed.emit()
	_check(TavernEngineLib.crew() == CARAVEL_MAX - 1, "the Fire 1 button fires one")
	fire_10.pressed.emit()
	_check(TavernEngineLib.crew() == CARAVEL_MAX - 11, "the Fire 10 button fires ten")
	down.pressed.emit()
	_check(TavernEngineLib.crew() == CARAVEL_MIN,
		"the Down to min button lands on crew_min (got %d)" % TavernEngineLib.crew())
	_check(GameState.gold == 1000, "no firing button pays severance")

	# Locale rebind: every crew-tab string follows the toggle (docs/80-* §7).
	_make_run(CARAVEL_MIN, 1000)
	screen.refresh()
	I18n.set_locale("zh")
	screen.refresh()
	_check(count.text == I18n.fmt("tavern.crew_count", {"crew": 15, "max": 45}),
		"the crew row rebinds in zh (%s)" % count.text)
	_check(per_head.text == I18n.fmt("tavern.per_head", {"price": 20}),
		"the per-head preview rebinds in zh (%s)" % per_head.text)
	_check(screen.get_node("Layout/VBox/Tabs/CrewTab").text ==
		I18n.t_key("tavern.crew_tab"), "the crew tab label rebinds in zh")
	_check(screen.get_node("Layout/VBox/Tabs/OfficersTab").text ==
		I18n.t_key("tavern.officers_tab"), "the officers tab label rebinds in zh")
	I18n.set_locale("en")
	screen.refresh()
	_check(count.text == I18n.fmt("tavern.crew_count", {"crew": 15, "max": 45}),
		"the crew row rebinds back to en (%s)" % count.text)

	# No run / no flagship (editor standalone): crew row shows 0/0 and every
	# crew button is inert, but nothing crashes and no bogus reason appears.
	_make_run(CARAVEL_MIN, 1000)
	GameState.fleet = []
	screen.refresh()
	_check(TavernEngineLib.crew_max() == 0 and TavernEngineLib.crew() == 0,
		"no flagship: crew_max and crew read 0")
	_check(hire_1.disabled and fill.disabled, "no flagship: hire buttons disabled")
	_check(not reason.visible, "no flagship: no bogus disabled reason")
	_check(not TavernEngineLib.hire(1) and not TavernEngineLib.fire(1),
		"no flagship: hire/fire refuse")

	# −10 clamps: it fires down to the floor rather than refusing (§6).
	_make_run(CARAVEL_MIN + 3, 1000)
	screen.refresh()
	_check(not fire_10.disabled, "Fire 10 stays enabled with 3 head above the floor")
	_check(fire_10.tooltip_text.is_empty(),
		"an enabled Fire 10 carries no floor tooltip")
	fire_10.pressed.emit()
	_check(TavernEngineLib.crew() == CARAVEL_MIN,
		"Fire 10 clamps down to crew_min 15 (got %d)" % TavernEngineLib.crew())
	fire_10.pressed.emit()
	_check(TavernEngineLib.crew() == CARAVEL_MIN,
		"Fire 10 at the floor fires nobody (got %d)" % TavernEngineLib.crew())
	_drop(screen)
	host.queue_free()


# --- Screen: Officers tab --------------------------------------------------

func _test_screen_officers_tab() -> void:
	_make_run(CARAVEL_MIN, 5000)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var screen = TavernScene.instantiate()
	screen.route_to_port = false
	host.add_child(screen)

	screen.select_tab("officers")
	_check(screen.active_tab() == "officers", "the officers tab can be selected")
	_check(screen.get_node("Layout/VBox/Body/OfficersPanel").visible,
		"the officers panel is visible")
	_check(not screen.get_node("Layout/VBox/Body/CrewPanel").visible,
		"the crew panel is hidden")

	var list: VBoxContainer = screen.get_node(
		"Layout/VBox/Body/OfficersPanel/RecruitableScroll/Recruitable"
	)
	_check(list.get_child_count() == 1,
		"lisbon lists exactly one recruitable officer (%d rows)"
		% list.get_child_count())
	var row: Control = list.get_child(0)
	_check(row.name == "Officer_off_mateus_alvares",
		"the row is Mateus Álvares (%s)" % row.name)
	var info: VBoxContainer = row.get_child(0)
	_check(info.get_node("Name").text ==
		I18n.t(DataLoader.get_officer("off_mateus_alvares")["name"]),
		"the row shows the officer's name")
	_check(info.get_node("Role").text.contains(I18n.t_key("tavern.role.navigator")),
		"the row shows the role (%s)" % info.get_node("Role").text)
	_check(info.get_node("Role").text.contains(
		I18n.fmt("tavern.wage", {"price": 30})),
		"the row shows the daily wage")
	_check(info.get_node("Stats").text == I18n.fmt("tavern.stats", {
		"leadership": 10, "seamanship": 14, "combat": 6, "navigation": 16,
	}), "the row shows the stats line (%s)" % info.get_node("Stats").text)
	_check(info.get_node("Bio").text ==
		I18n.t(DataLoader.get_officer("off_mateus_alvares")["bio"]),
		"the row shows the bio")

	var action: VBoxContainer = row.get_child(1)
	var cost: Label = action.get_node("Cost")
	var recruit: Button = action.get_node("Recruit")
	_check(cost.text == I18n.fmt("tavern.signing_cost", {"amount": 300}),
		"the signing cost reads 300g (%s)" % cost.text)
	_check(recruit.text == I18n.t_key("tavern.recruit"), "the button says Recruit")
	_check(not recruit.disabled, "Recruit is enabled when affordable")

	# Recruiting through the button: fee, roster, disappearance.
	recruit.pressed.emit()
	_check(CharacterLib.is_employed("off_mateus_alvares"),
		"the Recruit button signs the officer")
	_check(GameState.gold == 4700, "the signing fee is 300g (got %d)" % GameState.gold)
	_check(list.get_child_count() == 1 and
		list.get_child(0).name == "Empty",
		"the officer leaves the recruitable list")

	var roster: VBoxContainer = screen.get_node(
		"Layout/VBox/Body/OfficersPanel/RosterScroll/Roster"
	)
	_check(roster.get_child_count() == 1,
		"the roster shows the signed officer (%d rows)" % roster.get_child_count())
	var employed_row: Control = roster.get_child(0)
	_check(employed_row.name == "Employed_off_mateus_alvares",
		"the roster row carries the officer id (%s)" % employed_row.name)
	var dismiss: Button = employed_row.get_node("Dismiss")
	_check(dismiss.text == I18n.t_key("tavern.dismiss"), "the button says Dismiss")

	# Other ports never show it while employed; the screen uses its port only.
	_check(TavernEngineLib.officers_at_port("madeira").is_empty(),
		"madeira's pool is empty while the officer is employed")

	# Dismiss through the button: returns to the pool and to this screen.
	dismiss.pressed.emit()
	_check(not CharacterLib.is_employed("off_mateus_alvares"),
		"the Dismiss button dismisses the officer")
	_check(roster.get_child_count() == 1 and roster.get_child(0).name == "Empty",
		"the roster shows the empty state")
	_check(list.get_child_count() == 1 and
		list.get_child(0).name == "Officer_off_mateus_alvares",
		"the dismissed officer is recruitable here again")

	# OFFICER_MAX: a full roster disables Recruit with char.officers_full.
	_make_run(CARAVEL_MIN, 20000)
	CharacterLib.recruit("off_mateus_alvares")
	CharacterLib.recruit("off_diego_fernandez")
	CharacterLib.recruit("off_thomas_reed")
	screen.refresh()
	var reason: Label = screen.get_node("Layout/VBox/Body/OfficersPanel/Reason")
	_check(reason.visible, "a full-roster reason is shown")
	_check(reason.text == I18n.fmt("char.officers_full", {"max": 3}),
		"the reason uses char.officers_full (%s)" % reason.text)
	_check(roster.get_child_count() == 3, "the roster lists all three officers")

	# Gold shortfall: price is shown, button disabled.
	_make_run(CARAVEL_MIN, 100)
	screen.refresh()
	var fresh_row: Control = list.get_child(0)
	var button2: Button = fresh_row.get_child(1).get_node("Recruit")
	_check(button2.disabled, "Recruit is disabled at 100g for a 300g officer")
	_check(not button2.tooltip_text.is_empty(),
		"the disabled recruit button shows the price (%s)" % button2.tooltip_text)

	# Empty state at a port with no pool.
	GameState.current_port = "athens"
	screen.refresh()
	_check(list.get_child_count() == 1 and list.get_child(0).name == "Empty",
		"a port with no officers shows the empty state")
	_check(list.get_child(0).text == I18n.t_key("tavern.no_officers"),
		"the empty state uses tavern.no_officers")

	# Locale rebind.
	GameState.current_port = "lisbon"
	I18n.set_locale("zh")
	screen.refresh()
	_check(screen.get_node("Layout/VBox/Header/Title").text ==
		I18n.fmt("tavern.title", {
			"port": I18n.t(DataLoader.get_port("lisbon")["name"]),
		}), "the title rebinds in zh (%s)"
		% screen.get_node("Layout/VBox/Header/Title").text)
	I18n.set_locale("en")

	_drop(screen)
	host.queue_free()


# --- Screen: Rumors tab (Phase 3, docs/70-* §4.4) --------------------------

func _test_screen_rumors_tab() -> void:
	_make_run(CARAVEL_MIN, 1000)
	GameState.day = 12
	GameState.discoveries_found = []
	GameState.discovery_hints = {}
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var screen = TavernScene.instantiate()
	screen.route_to_port = false
	host.add_child(screen)

	screen.select_tab("rumors")
	_check(screen.active_tab() == "rumors", "the rumours tab can be selected")
	_check(screen.get_node("Layout/VBox/Body/RumorsPanel").visible,
		"the rumours panel is visible")
	_check(not screen.get_node("Layout/VBox/Body/CrewPanel").visible,
		"the crew panel is hidden on the rumours tab")
	_check(screen.get_node("Layout/VBox/Tabs/RumorsTab").text
		== I18n.t_key("tavern.rumor_tab"), "the tab says Rumours")

	var price: Label = screen.get_node("Layout/VBox/Body/RumorsPanel/Price")
	_check(price.text == I18n.fmt("tavern.rumor.price", {"gold": 100}),
		"the tab shows the 100g price (%s)" % price.text)

	# The monthly tournament is announced here too (§4.6).
	var announce: Label = screen.get_node(
		"Layout/VBox/Body/RumorsPanel/Tournament")
	var status: Dictionary = TournamentLib.status("lisbon", GameState.day)
	var expected_announce := I18n.fmt("tournament.status", {
		"port": I18n.t(DataLoader.get_port(str(status["host"]))["name"]),
		"first": int(status["window_first"]),
		"last": int(status["window_last"]),
	})
	var blocked := str(status.get("blocked", ""))
	if blocked in ["tournament.not_host", "tournament.closed"]:
		expected_announce += " — %s" % I18n.t_key(blocked)
	_check(announce.text == expected_announce,
		"the tab announces this month's tournament (%s)" % announce.text)

	var rows: VBoxContainer = screen.get_node(
		"Layout/VBox/Body/RumorsPanel/Scroll/Rows"
	)
	_check(rows.get_child_count() == DiscoveryLib.HINTS_PER_VISIT,
		"up to three hint rows are listed (%d)" % rows.get_child_count())
	var listed: Array = screen.rumor_rows()
	_check(listed == DiscoveryLib.hints("lisbon", 12),
		"the rows are exactly DiscoverySight.hints() (%s)" % str(listed))

	var row: Control = rows.get_child(0)
	var hint_label: Label = row.get_node("Hint")
	var discovery_id := str(listed[0])
	_check(hint_label.text == I18n.t(
		DataLoader.get_discovery(discovery_id)["region_hint"]),
		"the row shows the region hint free")
	var buy: Button = row.get_node("Bottom/Buy")
	_check(buy.text == I18n.t_key("tavern.rumor.buy"),
		"the buy button says Buy the rumour (%s)" % buy.text)
	_check(not buy.disabled, "Buy is enabled with 1000g")

	# Buying through the button: 100g, hinted, name revealed, row disabled.
	buy.pressed.emit()
	_check(GameState.gold == 900, "buying a rumour costs 100g (got %d)"
		% GameState.gold)
	_check(DiscoveryLib.is_hinted(discovery_id),
		"the bought hint is marked hinted")
	row = rows.get_child(0)
	_check(row.get_node("Bottom/Name").text
		== I18n.t(DataLoader.get_discovery(discovery_id)["name"]),
		"the discovery name is revealed after buying")
	var buy2: Button = row.get_node("Bottom/Buy")
	_check(buy2.disabled, "a hinted rumour cannot be bought twice")
	_check(buy2.text == I18n.t_key("tavern.rumor.bought"),
		"the bought row reads Already known (%s)" % buy2.text)

	# Short of gold: disabled with tavern.rumor.no_gold.
	GameState.discovery_hints = {}
	_make_run(CARAVEL_MIN, 99)
	GameState.day = 12
	screen.refresh()
	var poor: Button = rows.get_child(0).get_node("Bottom/Buy")
	_check(poor.disabled, "Buy is disabled with 99g")
	_check(poor.tooltip_text == I18n.t_key("tavern.rumor.no_gold"),
		"the disabled reason is tavern.rumor.no_gold (%s)" % poor.tooltip_text)

	# Every discovery found → the empty state.
	_make_run(CARAVEL_MIN, 1000)
	for entry in DataLoader.discoveries_list:
		GameState.discoveries_found.append(str((entry as Dictionary)["id"]))
	screen.refresh()
	var empty: Label = screen.get_node("Layout/VBox/Body/RumorsPanel/Empty")
	_check(empty.visible and empty.text == I18n.t_key("tavern.rumor.none"),
		"all discoveries found shows tavern.rumor.none (%s)" % empty.text)

	# Deterministic per (port, day) and distinct per port.
	_make_run(CARAVEL_MIN, 1000)
	GameState.discoveries_found = []
	_check(DiscoveryLib.hints("lisbon", 12) == DiscoveryLib.hints("lisbon", 12),
		"the same (port, day) yields the same hints")
	_check(DiscoveryLib.hints("lisbon", 12) != DiscoveryLib.hints("lisbon", 13),
		"the next day yields a different draw")
	var others: Array = DiscoveryLib.hints("tunis", 12)
	_check(not others.is_empty(), "a second port also draws hints (%d)"
		% others.size())

	# Locale rebind.
	I18n.set_locale("zh")
	screen.refresh()
	_check(price.text == I18n.fmt("tavern.rumor.price", {"gold": 100}),
		"the price line rebinds in zh (%s)" % price.text)
	I18n.set_locale("en")

	_drop(screen)
	host.queue_free()


# --- Screen: Back edge -----------------------------------------------------

func _test_screen_back() -> void:
	_make_run(CARAVEL_MIN, 1000)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child(host)
	var screen = TavernScene.instantiate()
	screen.route_to_port = false
	host.add_child(screen)
	var fired := [false]
	screen.back_requested.connect(func() -> void: fired[0] = true)

	_check(screen.port_id() == "lisbon", "the screen reads current_port (lisbon)")

	# Esc is the same edge as Back (docs/80-* §4.2, §4.3).
	var event := InputEventAction.new()
	event.action = "back"
	event.pressed = true
	screen._unhandled_input(event)
	_check(fired[0], "Esc requests the back edge")
	_check(GameState.current_port == "lisbon",
		"leaving the tavern keeps current_port (only Set Sail clears it)")

	# The port hub routes to this screen (S4 → S7 edge). `open_facility` swaps
	# the whole scene tree, which cannot happen inside a test's `_ready`, so the
	# check is that the wired path resolves to this scene and exists.
	var port = PortScene.instantiate()
	port.route_to_world = false
	host.add_child(port)
	_check(str(port.FACILITY_SCENES["tavern"]) ==
		"res://scenes/port/tavern_screen.tscn", "the port hub routes to this scene")
	_check(ResourceLoader.exists(port.FACILITY_SCENES["tavern"]),
		"the tavern scene exists so open_facility() can route to it")
	_drop(port)

	_drop(screen)
	host.queue_free()


# --- Harness --------------------------------------------------------------

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
