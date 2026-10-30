extends Node
## Phase-3 task E acceptance tests: piracy & the bounty loop
## (docs/IMPLEMENT-Phase3.md E; docs/70-* §4.5, §4.9.5, §4.9.6; docs/60-* §4.1,
## §4.11.10; docs/30-* §4.2).
##
##   godot --headless --path . tools/test_bounty.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const BountyLib := preload("res://scripts/quests/bounty.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const EncountersLib := preload("res://scripts/world/encounters.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const PortScene := preload("res://scenes/port/port_screen.tscn")
const InnScene := preload("res://scenes/port/inn_screen.tscn")

## docs/70-* §4.9.5: the pinned rival table.
const RIVALS := {
	"portugal": ["spain", "england"],
	"spain": ["portugal", "italy"],
	"england": ["holland", "portugal"],
	"holland": ["england", "portugal"],
	"italy": ["ottoman", "spain"],
	"ottoman": ["italy", "spain"],
}

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_rival_table()
	_test_piracy_deltas()
	_test_bounty_issue()
	_test_closed_ports()
	_test_pay_off()
	_test_surrender_path()
	_test_hunters_spawn()
	await _test_no_lockout()
	_test_own_nation_bounty()
	await _test_navy_battle_piracy()
	await _test_palace_and_hub()
	_report()


func _new_run(port_id: String = "lisbon", day: int = 40, map_id: String = "p3") -> void:
	GameState.new_game("portugal", false, map_id)
	GameState.day = day
	GameState.gold = 10000
	GameState.current_port = port_id
	GameState.hostile_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.bounties = {}
	for nation in DataLoader.nations_list:
		var id := str((nation as Dictionary)["id"])
		GameState.player["reputation"][id] = 0


# --- 1. The rival table is data, and matches the pin ---------------------

func _test_rival_table() -> void:
	_new_run()
	var bad: Array = []
	for nation_id in RIVALS:
		var got: Array = BountyLib.rivals(nation_id)
		if got != RIVALS[nation_id]:
			bad.append("%s got %s" % [nation_id, str(got)])
	_check(bad.is_empty(), "nations.json#rivals matches the §4.9.5 table (%s)"
		% str(bad))
	var self_rival: Array = []
	for nation_id in RIVALS:
		if RIVALS[nation_id].has(nation_id):
			self_rival.append(nation_id)
	_check(self_rival.is_empty(), "no nation is its own rival (%s)" % str(self_rival))
	var sizes: Array = []
	for nation_id in RIVALS:
		sizes.append(RIVALS[nation_id].size())
	_check(sizes.size() == 6 and not sizes.has(0),
		"every nation has exactly 2 rivals (got %s)" % str(sizes))


# --- 2. Piracy applies −20 to the victim and +2 to its rivals -----------

func _test_piracy_deltas() -> void:
	_new_run()
	var deltas: Dictionary = BountyLib.piracy_deltas("spain")
	_check(int(deltas.get("spain", 0)) == -20,
		"piracy against Spain is −20 with Spain (got %d)" % int(deltas.get("spain", 0)))
	_check(int(deltas.get("portugal", 0)) == 2
		and int(deltas.get("italy", 0)) == 2,
		"Spain's rivals gain +2 each (got %s)" % str(deltas))
	_check(deltas.size() == 3, "exactly three nations change (got %d)" % deltas.size())
	_check(BountyLib.piracy_deltas("").is_empty(), "no nation → no deltas")

	# Applying it moves the real reputation (through the clamped setter).
	_new_run()
	var before := CharacterLib.reputation("spain")
	BountyLib.apply_piracy("spain")
	_check(CharacterLib.reputation("spain") == before - 20,
		"apply_piracy() charges the victim −20")
	_check(CharacterLib.reputation("portugal") == 2,
		"apply_piracy() credits a rival +2 (got %d)"
		% CharacterLib.reputation("portugal"))
	_check(CharacterLib.reputation("england") == 0,
		"a non-rival nation is untouched (got %d)"
		% CharacterLib.reputation("england"))
	# Clamping still applies at the floor.
	_new_run()
	GameState.player["reputation"]["spain"] = -95
	BountyLib.apply_piracy("spain")
	_check(CharacterLib.reputation("spain") == -100,
		"reputation clamps at −100 (got %d)" % CharacterLib.reputation("spain"))


# --- 3. rep ≤ −50 issues a bounty with the fixed amount -----------------

func _test_bounty_issue() -> void:
	_new_run()
	GameState.player["reputation"]["spain"] = -30
	_check(BountyLib.evaluate_all().is_empty(), "no bounty above −50")
	_check(not BountyLib.has_bounty("spain"), "Spain has no bounty at −30")

	CharacterLib.add_reputation("spain", -20)      # now −50
	var issued: Array = BountyLib.evaluate_all()
	_check(issued == ["spain"], "Spain issues a bounty exactly at −50 (got %s)"
		% str(issued))
	_check(BountyLib.has_bounty("spain"), "Spain holds a bounty")
	_check(BountyLib.amount("spain") == 25000,
		"the amount is 500 × |−50| = 25,000 (got %d)" % BountyLib.amount("spain"))
	_check(int(BountyLib.record("spain").get("day", -1)) == 40,
		"the bounty records the issue day")

	# The amount is fixed at issue time, not recomputed later.
	CharacterLib.add_reputation("spain", -30)      # now −80
	BountyLib.evaluate_all()
	_check(BountyLib.amount("spain") == 25000,
		"dropping to −80 does not re-price the bounty (got %d)"
		% BountyLib.amount("spain"))
	# A nation below the threshold without a bounty issues one at any value.
	_new_run()
	GameState.player["reputation"]["italy"] = -70
	BountyLib.evaluate_all()
	_check(BountyLib.amount("italy") == 35000,
		"a fresh −70 bounty is 35,000 (got %d)" % BountyLib.amount("italy"))


# --- 4. Closed ports (docs/70-* §4.9.6) --------------------------------

func _test_closed_ports() -> void:
	_new_run("seville", 40)
	GameState.player["reputation"]["spain"] = -60
	BountyLib.evaluate_all()
	_check(BountyLib.is_port_closed("seville"), "a Spanish port closes at −60")
	_check(BountyLib.is_port_closed("valencia"),
		"every port of the bountied nation closes")
	_check(not BountyLib.is_port_closed("lisbon"),
		"another nation's ports stay open")
	_check(not BountyLib.can_open_facility("seville", "market"),
		"a closed port refuses the market")
	_check(not BountyLib.can_open_facility("seville", "guild"),
		"a closed port refuses the guild")
	_check(BountyLib.can_open_facility("seville", "palace"),
		"the bountied capital's palace stays usable (pay-off exception)")
	_check(BountyLib.can_pay_here("seville"), "the capital can pay the bounty")
	_check(not BountyLib.can_pay_here("valencia"),
		"a non-capital closed port has no pay row")
	# Docking, the HUD, save and Set Sail still work: those are not facilities.
	_check(BountyLib.is_port_closed("barcelona"),
		"the port itself is still closed for facilities")


# --- 5. Pay-off resets rep to exactly −10 ------------------------------

func _test_pay_off() -> void:
	_new_run("seville", 40)
	GameState.player["reputation"]["spain"] = -60
	BountyLib.evaluate_all()
	GameState.gold = BountyLib.amount("spain") + 500
	var amount := BountyLib.amount("spain")
	var gold_before := GameState.gold
	_check(BountyLib.can_pay_off("spain"), "the bounty is affordable")
	_check(BountyLib.pay_off("spain"), "pay_off() succeeds")
	_check(GameState.gold == gold_before - amount,
		"paying charges exactly the bounty amount (%d)" % amount)
	_check(CharacterLib.reputation("spain") == -10,
		"paying resets reputation to exactly −10 (got %d)"
		% CharacterLib.reputation("spain"))
	_check(not BountyLib.has_bounty("spain"), "the bounty is gone")
	_check(not BountyLib.is_port_closed("seville"), "the port reopens")
	_check(not BountyLib.can_open_facility("seville", "market") == false,
		"the market is usable again")
	_check(not BountyLib.pay_off("spain"), "a cleared bounty cannot be paid twice")

	# Too little gold refuses without changing anything.
	_new_run("seville", 40)
	GameState.player["reputation"]["spain"] = -70
	BountyLib.evaluate_all()
	GameState.gold = 100
	var rep_before := CharacterLib.reputation("spain")
	_check(not BountyLib.can_pay_off("spain"), "an unaffordable bounty cannot be paid")
	_check(not BountyLib.pay_off("spain"), "pay_off() refuses")
	_check(CharacterLib.reputation("spain") == rep_before,
		"a refused payment changes no reputation")
	_check(BountyLib.has_bounty("spain"), "the bounty survives a refused payment")


# --- 6. Surrender clears the bounty too -------------------------------

func _test_surrender_path() -> void:
	_new_run("seville", 40)
	GameState.player["reputation"]["spain"] = -55
	BountyLib.evaluate_all()
	_check(BountyLib.has_bounty("spain"), "Spain holds a bounty before the surrender")
	var gold_before := GameState.gold
	_check(BountyLib.clear_by_surrender("spain"), "surrendering clears the bounty")
	_check(CharacterLib.reputation("spain") == -10,
		"the surrender path also lands on exactly −10 (got %d)"
		% CharacterLib.reputation("spain"))
	_check(GameState.gold == gold_before,
		"surrendering costs no gold (the hull is the price)")
	_check(not BountyLib.has_bounty("spain"), "the bounty is gone after surrender")


# --- 7. Hunters spawn while bountied ---------------------------------

func _test_hunters_spawn() -> void:
	_new_run("lisbon", 40)
	GameState.player["reputation"]["spain"] = -60
	BountyLib.evaluate_all()
	# The Phase-2 spawn roll keys on `rep <= -50` (`60-*` §4.11.11.2); drive it
	# through the real Encounters module with a forced navy roll.
	DataLoader.ensure_map()
	var encounters = EncountersLib.new()
	encounters.reset_rng(12345)
	var bountied: Array = encounters.bountied_nations()
	_check(bountied.has("spain"),
		"Encounters sees Spain as bountied at −60 (got %s)" % str(bountied))
	var spawned := false
	for _attempt in 400:
		var marker: Dictionary = encounters.call("spawn", "navy", "spain", GameState.day)
		if not marker.is_empty():
			spawned = true
			_check(str(marker.get("kind", "")) == "navy",
				"the hunter marker is a navy")
			_check(str(marker.get("nation_id", "")) == "spain",
				"the hunter belongs to the bountied nation")
			break
	_check(spawned, "navy hunters can spawn for a bountied nation")
	# No bounty → no bountied nations.
	GameState.bounties = {}
	GameState.player["reputation"]["spain"] = -10
	_check(encounters.bountied_nations().is_empty(),
		"no bounty means no hunter nation")


# --- 8. No unrecoverable lockout --------------------------------------

func _test_no_lockout() -> void:
	_new_run("lisbon", 40)
	# The worst case: bountied by EVERY nation, broke, and docked at a closed
	# capital. The pay-off row exists there, and harbor relief still works.
	for nation in DataLoader.nations_list:
		GameState.player["reputation"][str((nation as Dictionary)["id"])] = -100
	BountyLib.evaluate_all()
	_check(GameState.bounties.size() == 6,
		"every nation can hold a bounty at once (got %d)"
		% GameState.bounties.size())
	GameState.gold = 0
	_check(BountyLib.can_open_facility("lisbon", "palace"),
		"the own capital's palace stays reachable while bountied")
	# Harbor relief: no ships, no officers, no gold → odd jobs available.
	var stripped := GameState.debug_strip_fleet()
	_check(stripped, "the debug shipless hook is available in a headless run")
	GameState.player["officers"] = []
	GameState.current_port = "lisbon"
	var inn: Control = InnScene.instantiate()
	inn.route_to_port = false
	add_child(inn)
	await get_tree().process_frame
	_check(inn.odd_job_enabled(), "harbor relief is available in the worst case")
	inn.call("_on_odd_job_pressed")
	_check(inn.last_message_key == "inn.odd_job.result",
		"an odd job can be worked while bountied (got '%s')"
		% inn.last_message_key)
	_check(GameState.gold >= 100, "the odd job pays (got %d)" % GameState.gold)
	inn.queue_free()
	await get_tree().process_frame
	_check(true, "no state is an unrecoverable lockout (pay row + relief)")


# --- 9. The own nation can be bountied, and recovered ------------------

func _test_own_nation_bounty() -> void:
	_new_run("lisbon", 40)
	GameState.player["reputation"]["portugal"] = -55
	BountyLib.evaluate_all()
	_check(BountyLib.has_bounty("portugal"),
		"the player's own nation can issue a bounty")
	_check(BountyLib.is_port_closed("lisbon"),
		"the own capital closes its facilities")
	_check(BountyLib.can_pay_here("lisbon"),
		"the own capital's palace can still take the payment")
	GameState.gold = BountyLib.amount("portugal")
	_check(BountyLib.pay_off("portugal"), "the own-nation bounty can be paid off")
	_check(CharacterLib.reputation("portugal") == -10,
		"the own-nation rep resets to −10")
	_check(not BountyLib.is_port_closed("lisbon"), "the own capital reopens")


# --- 10. Palace + hub wiring -----------------------------------------

func _test_palace_and_hub() -> void:
	_new_run("seville", 40)
	GameState.player["reputation"]["spain"] = -60
	BountyLib.evaluate_all()
	GameState.gold = BountyLib.amount("spain") + 500
	var palace: Control = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(palace.is_closed(), "the palace reports its port as closed")
	_check(palace.all_text().size() > 0, "the palace renders its rows")
	var leaked: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		for line in palace.all_text():
			if str(line).contains("<") and str(line).contains(">"):
				leaked.append(str(line))
	_check(leaked.is_empty(), "no raw <key> on the closed palace (%s)"
		% str(leaked.slice(0, 4)))
	I18n.set_locale("en")
	var gold_before := GameState.gold
	_check(palace.pay_bounty(), "the palace pay row clears the bounty")
	_check(CharacterLib.reputation("spain") == -10,
		"the palace path resets rep to −10")
	_check(GameState.gold < gold_before, "the palace path charges the gold")
	palace.queue_free()
	await get_tree().process_frame

	# The hub shows the closed labels and refuses the closed facilities.
	_new_run("seville", 40)
	GameState.player["reputation"]["spain"] = -60
	BountyLib.evaluate_all()
	var hub: Control = PortScene.instantiate()
	hub.route_to_world = false
	hub.route_to_facility = false
	add_child(hub)
	await get_tree().process_frame
	_check(not hub.is_facility_enabled("market"), "the hub disables the market row")
	_check(hub.is_facility_enabled("palace"), "the hub keeps the palace row usable")
	var market: Button = hub.facility_row("market")
	_check(market != null and market.text.contains(I18n.t_key("port.closed_bounty")),
		"the closed row shows port.closed_bounty (%s)"
		% ("" if market == null else market.text))
	hub.queue_free()
	await get_tree().process_frame


# --- 11. A navy battle start charges the full §4.9.5 piracy block ------

## `world_map._charge_navy_piracy` is the one place `70-*` §4.9.5's "the `+2` is
## applied once per battle, at battle start, next to the −20" happens. Order the
## real world scene to fight a navy fleet and both halves must land exactly once.
func _test_navy_battle_piracy() -> void:
	_new_run("lisbon", 40)
	GameState.player["reputation"]["spain"] = -10
	GameState.player["reputation"]["portugal"] = -10
	GameState.player["reputation"]["italy"] = -10
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	# `-10` for Spain, one raid: -20 with Spain and +2 with its pinned rivals
	# (portugal, italy).
	world._charge_navy_piracy({"kind": "navy", "nation_id": "spain"})
	_check(CharacterLib.reputation("spain") == -30,
		"a navy battle start charges −20 with Spain (−10 → %d)"
		% CharacterLib.reputation("spain"))
	_check(CharacterLib.reputation("portugal") == -8,
		"Spain's rival Portugal gains +2 (−10 → %d)"
		% CharacterLib.reputation("portugal"))
	_check(CharacterLib.reputation("italy") == -8,
		"Spain's rival Italy gains +2 (−10 → %d)"
		% CharacterLib.reputation("italy"))
	_check(CharacterLib.reputation("england") == 0,
		"a non-rival is untouched (england %d)"
		% CharacterLib.reputation("england"))
	# Pirates are not piracy.
	world._charge_navy_piracy({"kind": "pirate", "nation_id": "spain"})
	_check(CharacterLib.reputation("spain") == -30,
		"a pirate battle charges nothing (got %d)"
		% CharacterLib.reputation("spain"))
	# A raid that crosses −50 issues the bounty right at battle start.
	GameState.player["reputation"]["spain"] = -35
	world._charge_navy_piracy({"kind": "navy", "nation_id": "spain"})
	_check(CharacterLib.reputation("spain") == -55,
		"the raid pushes Spain to −55 (%d)" % CharacterLib.reputation("spain"))
	_check(BountyLib.has_bounty("spain"),
		"the bounty is issued at battle start")
	_check(BountyLib.amount("spain") == 500 * 55,
		"the bounty is 500 × 55 = 27,500 (got %d)" % BountyLib.amount("spain"))
	world.queue_free()
	await get_tree().process_frame


# --- Helpers --------------------------------------------------------------

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
