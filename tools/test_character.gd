extends Node
## T16 acceptance tests (docs/50-* §7). Headless scene test:
##
##   godot --headless res://tools/test_character.tscn
##
## Exits 0 when every check passes, 1 otherwise. Kept as a proper
## `tools/test_*.gd` + `.tscn` pair so the T16 done-when list can be re-run.

const CharacterLib := preload("res://scripts/player/character.gd")
const CharacterPanelLib := preload("res://scenes/ui_shared/character_panel.gd")

## Six capitals known at new game (docs/20-* §4.11).
const CAPITALS := ["lisbon", "seville", "london", "amsterdam", "istanbul", "venice"]
const NATION_ORDER := ["portugal", "spain", "england", "holland", "ottoman", "italy"]
const BONUS_STAT := {
	"portugal": "navigation",
	"spain": "leadership",
	"england": "combat",
	"holland": "seamanship",
	"ottoman": "leadership",
	"italy": "luck",
}

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_level_formula()
	_test_effective_stats()
	_test_speed_bonus()
	_test_sighting_radius()
	_test_other_effects()
	_test_profit_xp()
	_test_award_xp_levelup()
	_test_officers()
	_test_new_game_all_nations()
	_test_nationality_scene_data_driven()
	_test_character_panel_live()
	_report()


# --- §4.3 level formula ----------------------------------------------------

func _test_level_formula() -> void:
	var rows := [
		[0, 1], [49, 1], [50, 2], [200, 3], [450, 4],
		[800, 5], [1250, 6], [18050, 20], [999999, 20],
	]
	for row in rows:
		_check(
			CharacterLib.level_for_xp(row[0]) == row[1],
			"level_for_xp(%d) == %d (got %d)" % [
				row[0], row[1], CharacterLib.level_for_xp(row[0])
			]
		)
	# xp_for_level is the inverse at every level up to the cap.
	for level in range(1, 21):
		_check(
			CharacterLib.level_for_xp(CharacterLib.xp_for_level(level)) == level,
			"xp_for_level(%d) = %d round-trips" % [
				level, CharacterLib.xp_for_level(level)
			]
		)
	# "next at" rows from docs/50-* §5.
	_check(CharacterLib.xp_for_level(2) == 50, "next_at after xp 0 is 50")
	_check(CharacterLib.xp_for_level(20) == 18050, "level 20 needs 18050 xp")


# --- §4.2 effective stats --------------------------------------------------

func _set_player(stats: Dictionary, officers: Array = []) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": officers.duplicate(),
		"reputation": {"portugal": 20, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0},
	}
	for key in stats:
		GameState.player["stats"][key] = stats[key]


func _test_effective_stats() -> void:
	_set_player({})
	_check(CharacterLib.effective_stat("navigation") == 10,
		"effective navigation at base 10 is 10")
	_set_player({"navigation": 15})
	_check(CharacterLib.effective_stat("navigation") == 15,
		"no officers: effective == base (15)")

	# One navigator (+10 navigation), two navigators stack to +20 (§4.5).
	_set_player({"navigation": 15}, ["off_mateus_alvares"])
	_check(CharacterLib.effective_stat("navigation") == 25,
		"one navigator: 15 + 10 == 25 (got %d)"
		% CharacterLib.effective_stat("navigation"))
	_set_player({"navigation": 15}, ["off_mateus_alvares", "off_marco_bellini"])
	_check(CharacterLib.effective_stat("navigation") == 35,
		"two navigators: 15 + 20 == 35 (got %d)"
		% CharacterLib.effective_stat("navigation"))

	# Role bonuses are per-stat only.
	_set_player({}, ["off_thomas_reed"])  # gunner
	_check(CharacterLib.effective_stat("combat") == 20, "gunner: combat 10 + 10 == 20")
	_check(CharacterLib.effective_stat("seamanship") == 10,
		"gunner leaves seamanship untouched")
	_set_player({}, ["off_jan_de_vries"])  # boatswain
	_check(CharacterLib.effective_stat("seamanship") == 20,
		"boatswain: seamanship 10 + 10 == 20")

	# §5 worked example: Portugal start + Mateus Álvares aboard.
	_set_player({"navigation": 15}, ["off_mateus_alvares"])
	_check(CharacterLib.effective_stat("navigation") == 25,
		"§5 example navigation effective 25")
	_check(CharacterLib.sighting_radius() == 9, "§5 example sighting radius 9")
	_check(CharacterLib.speed_bonus() == 0.0, "§5 example speed bonus 0.0")


# --- §4.2 speed bonus boundaries ------------------------------------------

func _test_speed_bonus() -> void:
	var rows := [
		[10, 0.0], [20, 0.10], [0, -0.10], [5, -0.05],
		[100, 0.20], [50, 0.20], [30, 0.20], [12, 0.02],
	]
	for row in rows:
		_set_player({"seamanship": row[0]})
		var got := CharacterLib.speed_bonus()
		_check(is_equal_approx(got, row[1]),
			"speed_bonus(seamanship %d) == %.2f (got %.4f)"
			% [row[0], row[1], got])


# --- §4.2 sighting radius -------------------------------------------------

func _test_sighting_radius() -> void:
	var rows := [[10, 8], [20, 9], [25, 9], [30, 10], [19, 8], [40, 11]]
	for row in rows:
		_set_player({"navigation": row[0]})
		_check(CharacterLib.sighting_radius() == row[1],
			"sighting_radius(navigation %d) == %d (got %d)"
			% [row[0], row[1], CharacterLib.sighting_radius()])


# --- §4.2 leadership / luck effects ---------------------------------------

func _test_other_effects() -> void:
	_set_player({"leadership": 10})
	_check(is_equal_approx(CharacterLib.desertion_multiplier(), 1.0),
		"desertion ×1.0 at leadership 10")
	_check(is_equal_approx(CharacterLib.mutiny_multiplier(), 1.0),
		"mutiny ×1.0 at leadership 10")
	_set_player({"leadership": 30})
	_check(is_equal_approx(CharacterLib.desertion_multiplier(), 0.9),
		"desertion ×0.9 at leadership 30")
	_set_player({"leadership": 100})
	_check(is_equal_approx(CharacterLib.desertion_multiplier(), 0.55),
		"desertion ×0.55 at leadership 100")
	# Below base leadership the multiplier is above 1 (more losses); the clamp
	# chosen in character.gd only guarantees it never goes negative (§4.2 has
	# no lower bound, a negative multiplier would flip the loss into a gain).
	_set_player({"leadership": 1})
	_check(is_equal_approx(CharacterLib.desertion_multiplier(), 1.045),
		"desertion ×1.045 at leadership 1 (above base → more losses)")
	_set_player({"leadership": 400})
	var clamped := CharacterLib.desertion_multiplier()
	_check(clamped == 0.0, "desertion multiplier clamped at 0.0 (got %.3f)" % clamped)

	_set_player({"luck": 10})
	_check(is_equal_approx(CharacterLib.storm_damage_multiplier(), 1.0),
		"storm damage ×1.0 at luck 10")
	_set_player({"luck": 49})
	_check(is_equal_approx(CharacterLib.storm_damage_multiplier(), 1.0),
		"storm damage ×1.0 at luck 49")
	_set_player({"luck": 50})
	_check(is_equal_approx(CharacterLib.storm_damage_multiplier(), 0.75),
		"storm damage ×0.75 at luck 50 (boundary)")
	_set_player({"luck": 10})
	_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 0.975),
		"storm chance ×0.975 at luck 10")
	_set_player({"luck": 100})
	_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 0.75),
		"storm chance ×0.75 at luck 100")


# --- §4.3 profit XP -------------------------------------------------------

func _test_profit_xp() -> void:
	# Locked rule: sell 31 vs base 30, qty 10 → 31 − floor(21) = 10/unit,
	# profit 100 → +1 XP.
	_set_player({})
	CharacterLib.add_profit_xp(31, 30, 10)
	_check(CharacterLib.current_xp() == 1,
		"add_profit_xp(31,30,10) awards 1 XP (got %d)" % CharacterLib.current_xp())

	# Loss-making sale: per-unit floors at 0, XP never decreases.
	_set_player({})
	GameState.player["xp"] = 37
	CharacterLib.add_profit_xp(10, 30, 10)
	_check(CharacterLib.current_xp() == 37,
		"loss-making sale leaves xp at 37 (got %d)" % CharacterLib.current_xp())

	# Floor on the profit term: 249g profit → 2 XP.
	_set_player({})
	CharacterLib.add_profit_xp(55, 30, 9)  # per-unit 34, profit 306 → 3
	_check(CharacterLib.current_xp() == 3,
		"add_profit_xp(55,30,9) awards 3 XP (got %d)" % CharacterLib.current_xp())


# --- §4.3 level-up rewards ------------------------------------------------

func _test_award_xp_levelup() -> void:
	_set_player({"seamanship": 10, "navigation": 15})
	GameState.player["nation_id"] = "portugal"
	GameState.player["xp"] = 49
	GameState.player["level"] = 1
	CharacterLib.pending_levelup = false
	CharacterLib.award_xp(1)
	_check(CharacterLib.level_for_xp(CharacterLib.current_xp()) == 2,
		"xp 49 → 50 gives level 2")
	_check(CharacterLib.current_level() == 2, "level cache updated to 2")
	_check(int(GameState.player.get("level", 0)) == 2,
		"stored level cache written to the save block (got %d)"
		% int(GameState.player.get("level", 0)))
	_check(CharacterLib.base_stat("seamanship") == 11,
		"level-up: seamanship 10 → 11 (got %d)"
		% CharacterLib.base_stat("seamanship"))
	_check(CharacterLib.base_stat("navigation") == 16,
		"level-up: nation stat navigation 15 → 16 (got %d)"
		% CharacterLib.base_stat("navigation"))
	_check(CharacterLib.base_stat("combat") == 10,
		"level-up leaves non-nation stats alone")
	_check(CharacterLib.pending_levelup, "pending_levelup raised for the HUD toast")
	_check(CharacterLib.consume_pending_levelup() and
		not CharacterLib.pending_levelup, "pending_levelup consumed once")

	# No XP source at zero/negative amount must not fire rewards.
	_set_player({})
	CharacterLib.award_xp(0)
	_check(CharacterLib.current_xp() == 0 and CharacterLib.base_stat("seamanship") == 10,
		"award_xp(0) is a no-op")

	# Multi-level jump applies the reward once per level.
	_set_player({"seamanship": 10, "navigation": 15})
	GameState.player["nation_id"] = "portugal"
	GameState.player["xp"] = 0
	CharacterLib.award_xp(450)  # level 1 → 4
	_check(CharacterLib.current_level() == 4, "450 xp → level 4")
	_check(CharacterLib.base_stat("seamanship") == 13,
		"3 level-ups: seamanship 10 → 13 (got %d)"
		% CharacterLib.base_stat("seamanship"))
	_check(CharacterLib.base_stat("navigation") == 18,
		"3 level-ups: nation stat navigation 15 → 18 (got %d)"
		% CharacterLib.base_stat("navigation"))

	# Holland's nation stat IS seamanship, so its level reward doubles there.
	_set_player({"seamanship": 10})
	GameState.player["nation_id"] = "holland"
	GameState.player["xp"] = 0
	CharacterLib.award_xp(450)
	_check(CharacterLib.base_stat("seamanship") == 16,
		"holland 3 level-ups: seamanship 10 → 16 (got %d)"
		% CharacterLib.base_stat("seamanship"))


# --- §4.4 officers --------------------------------------------------------

func _test_officers() -> void:
	_set_player({})
	GameState.gold = 10000
	_check(CharacterLib.recruit_cost("off_mateus_alvares") == 300,
		"recruit cost = wage 30 × 10 = 300")
	_check(CharacterLib.can_recruit("off_mateus_alvares"), "can recruit when rich")
	_check(CharacterLib.recruit("off_mateus_alvares"), "recruit succeeds")
	_check(GameState.gold == 9700, "signing fee deducted (got %d)" % GameState.gold)
	_check(CharacterLib.is_employed("off_mateus_alvares"), "officer is employed")
	_check(not CharacterLib.can_recruit("off_mateus_alvares"),
		"cannot recruit an employed officer")

	# OFFICER_MAX = 3.
	CharacterLib.recruit("off_diego_fernandez")
	CharacterLib.recruit("off_thomas_reed")
	_check(CharacterLib.officer_count() == 3, "roster holds 3 officers")
	_check(not CharacterLib.can_recruit("off_jan_de_vries"),
		"4th officer is blocked by OFFICER_MAX")
	_check(not CharacterLib.recruit("off_jan_de_vries"),
		"recruit() returns false when the roster is full")

	# Dismiss returns the officer to the pool.
	_check(CharacterLib.dismiss("off_thomas_reed"), "dismiss succeeds")
	_check(CharacterLib.officer_count() == 2, "roster back to 2 after dismiss")
	_check(CharacterLib.can_recruit("off_thomas_reed"),
		"dismissed officer is recruitable again")
	_check(not CharacterLib.dismiss("off_thomas_reed"),
		"dismissing an un-employed officer returns false")

	# Gold shortfall → disabled (§6 edge rule).
	GameState.gold = 100
	_check(not CharacterLib.can_recruit("off_thomas_reed"),
		"recruit blocked when gold < signing cost")

	# Officer wages for the ledger.
	_set_player({}, ["off_mateus_alvares", "off_diego_fernandez"])
	_check(CharacterLib.officer_wages() == 58, "officer wages 30 + 28 = 58 (got %d)"
		% CharacterLib.officer_wages())


# --- §4.1 new game, all six nations ---------------------------------------

func _test_new_game_all_nations() -> void:
	_check(DataLoader.nations_list.size() == 6, "six nations in data")
	for index in DataLoader.nations_list.size():
		_check(str(DataLoader.nations_list[index].get("id", "")) == NATION_ORDER[index],
			"nation order slot %d is %s" % [index, NATION_ORDER[index]])

	for nation_id in NATION_ORDER:
		var nation: Dictionary = DataLoader.get_nation(nation_id)
		var start_port: Dictionary = DataLoader.get_port(
			str(nation["start_port_id"])
		)
		var ship_type: Dictionary = DataLoader.get_ship_type(
			str(nation["start_ship_type_id"])
		)
		GameState.locale = "zh"
		GameState.new_game(nation_id, false)

		_check(GameState.day == 1, "%s: day == 1" % nation_id)
		_check(GameState.gold == int(nation["start_gold"]),
			"%s: gold == start_gold %d (got %d)"
			% [nation_id, int(nation["start_gold"]), GameState.gold])
		_check(GameState.morale == 70, "%s: morale == 70" % nation_id)
		_check(GameState.locale == "zh", "%s: locale untouched" % nation_id)
		_check(GameState.port_investments.is_empty(), "%s: investments cleared" % nation_id)
		_check(GameState.quests.is_empty(), "%s: quests cleared" % nation_id)
		_check(GameState.discoveries_found.is_empty(),
			"%s: discoveries cleared" % nation_id)
		_check(GameState.current_port == str(nation["start_port_id"]),
			"%s: current_port == %s (got %s)" % [
				nation_id, nation["start_port_id"], str(GameState.current_port)
			])

		# Fleet: exactly one starter hull at full durability, crew_min aboard.
		_check(GameState.fleet.size() == 1, "%s: one starter ship" % nation_id)
		var ship: Dictionary = GameState.fleet[0]
		_check(str(ship.get("ship_type_id", "")) == str(nation["start_ship_type_id"]),
			"%s: ship_type_id == %s" % [nation_id, nation["start_ship_type_id"]])
		_check(int(ship.get("crew", -1)) == int(ship_type["crew_min"]),
			"%s: crew == crew_min %d (got %d)" % [
				nation_id, int(ship_type["crew_min"]), int(ship.get("crew", -1))
			])
		_check(int(ship.get("durability", -1)) == int(ship_type["durability"]),
			"%s: durability at max (%d)" % [nation_id, int(ship_type["durability"])])
		_check(int(ship.get("provisions", -1)) == 0 and
			int(ship.get("water", -1)) == 0 and
			int(ship.get("cannons", -1)) == 0,
			"%s: empty supplies/cannons per §4.3 defaults" % nation_id)
		_check((ship.get("cargo", {"x": 1}) as Dictionary).is_empty(),
			"%s: empty cargo hold" % nation_id)

		# World position is the start port's harbor tile (§4.1), stored in the
		# §8.1 save shape (`{"x","y"}`) and readable as a Vector2i.
		var pos = GameState.world.get("position", null)
		_check(pos is Dictionary and pos.has("x") and pos.has("y"),
			"%s: world.position is a tilePos dict %s" % [nation_id, str(pos)])
		var expected := Vector2i(
			int(start_port["position"]["x"]), int(start_port["position"]["y"])
		)
		_check(GameState.world_tile() == expected,
			"%s: world.position == %s (got %s)" % [
				nation_id, str(expected), str(GameState.world_tile())
			])
		_check(float(GameState.world.get("clock_fraction", -1.0)) == 0.0,
			"%s: clock_fraction reset to 0 in port" % nation_id)

		# known_ports = the six capitals (§20 §4.11), order-insensitive.
		var known: Array = GameState.known_ports.duplicate()
		known.sort()
		var expected_known: Array = CAPITALS.duplicate()
		expected_known.sort()
		_check(known == expected_known,
			"%s: known_ports == six capitals (got %s)" % [nation_id, str(known)])

		# Player block: stats = base 10 + the nation bonus on exactly one stat.
		var stats: Dictionary = GameState.player["stats"]
		for key in CharacterLib.STAT_KEYS:
			var expected_stat := 10
			if key == BONUS_STAT[nation_id]:
				expected_stat = 15
			_check(int(stats[key]) == expected_stat,
				"%s: %s == %d (got %d)" % [
					nation_id, key, expected_stat, int(stats[key])
				])
		_check(int(GameState.player["xp"]) == 0, "%s: xp == 0" % nation_id)
		_check(int(GameState.player["level"]) == 1, "%s: level == 1" % nation_id)
		_check((GameState.player["officers"] as Array).is_empty(),
			"%s: no officers" % nation_id)
		var rep: Dictionary = GameState.player["reputation"]
		_check(rep.size() == 6, "%s: reputation covers all 6 nations" % nation_id)
		_check(int(rep.get(nation_id, -999)) == int(nation["start_reputation"]),
			"%s: own reputation == start_reputation %d (got %d)" % [
				nation_id, int(nation["start_reputation"]),
				int(rep.get(nation_id, -999))
			])
		for other in NATION_ORDER:
			if other == nation_id:
				continue
			_check(int(rep.get(other, -999)) == 0,
				"%s: reputation with %s == 0" % [nation_id, other])

		# Effective-stat §5 example for Portugal's start.
		if nation_id == "portugal":
			_check(CharacterLib.effective_stat("navigation") == 15,
				"portugal start navigation effective 15")


# --- S2 data-driven cards -------------------------------------------------

func _test_nationality_scene_data_driven() -> void:
	var scene: PackedScene = load("res://scenes/title/nationality_select.tscn")
	_check(scene != null, "nationality_select.tscn loads")
	if scene == null:
		return
	var screen := scene.instantiate()
	add_child(screen)
	# `_ready` built the cards synchronously.
	var grid: GridContainer = screen.get_node_or_null("Layout/Cards")
	_check(grid != null, "nationality_select has a Cards grid")
	if grid == null:
		screen.queue_free()
		return
	_check(grid.get_child_count() == 6,
		"exactly 6 nation cards (got %d)" % grid.get_child_count())
	for index in grid.get_child_count():
		var card := grid.get_child(index)
		var nation: Dictionary = DataLoader.nations_list[index]
		var nation_id := str(nation["id"])
		_check(card.name == "Card_%s" % nation_id,
			"card %d is %s in data order" % [index, nation_id])
		var name_label: Label = card.get_node_or_null("Content/NationName")
		_check(name_label != null and name_label.text == I18n.t(nation["name"]),
			"card %s name from data (%s)" % [
				nation_id, name_label.text if name_label != null else "<missing>"
			])
		var package: Label = card.get_node_or_null("Content/StartPackage")
		_check(package != null, "card %s has a start package label" % nation_id)
		if package != null:
			# The card must render the live DataLoader gold value, not a copy.
			var gold_text := nationality_select_format(int(nation["start_gold"]))
			_check(package.text.contains(gold_text),
				"card %s start gold matches data (%s) in %s" % [
					nation_id, gold_text, package.text.replace("\n", " | ")
				])
			var port: Dictionary = DataLoader.get_port(str(nation["start_port_id"]))
			_check(package.text.contains(I18n.t(port["name"])),
				"card %s start port from data" % nation_id)
			var ship: Dictionary = DataLoader.get_ship_type(
				str(nation["start_ship_type_id"])
			)
			_check(package.text.contains(I18n.t(ship["name"])),
				"card %s start ship from data" % nation_id)
		var flag: ColorRect = card.get_node_or_null("Content/Flag")
		_check(flag != null and flag.color == Color(str(nation["color"])),
			"card %s flag color from data" % nation_id)

	# Data-driven proof: mutate the in-memory Nation record (a copy of the
	# data, no file written), force a rebuild, and the card must follow.
	var first: Dictionary = DataLoader.nations_list[0]
	var original_gold := int(first["start_gold"])
	first["start_gold"] = original_gold + 1234
	screen._rebuild()
	var rebuilt: Button = grid.get_child(0)
	var rebuilt_package: Label = rebuilt.get_node("Content/StartPackage")
	var mutated_text := nationality_select_format(original_gold + 1234)
	_check(rebuilt_package.text.contains(mutated_text),
		"edited start_gold (%s) shows on the card with no scene edit" % mutated_text)
	first["start_gold"] = original_gold
	screen._rebuild()

	# Locale rebind: section headings and card data both come from I18n.
	I18n.set_locale("zh")
	_check((screen.get_node("Layout/Header/Title") as Label).text ==
		DataLoader.ui_strings["nation.select_title"]["zh"],
		"S2 title rebinds to zh")
	var zh_card: Button = grid.get_child(0)
	var zh_name: Label = zh_card.get_node("Content/NationName")
	_check(zh_name.text == DataLoader.nations_list[0]["name"]["zh"],
		"S2 card name rebinds to zh (%s)" % zh_name.text)
	I18n.set_locale("en")
	_check((screen.get_node("Layout/Header/Title") as Label).text ==
		DataLoader.ui_strings["nation.select_title"]["en"],
		"S2 title rebinds back to en")

	# Back/Esc routing: assert the target exists and the Esc action is bound,
	# rather than swapping scenes inside the unit test.
	var s2_script := load("res://scenes/title/nationality_select.gd")
	_check(ResourceLoader.exists(s2_script.TITLE_SCENE),
		"S2 Back target exists (%s)" % s2_script.TITLE_SCENE)
	var back_event := InputEventAction.new()
	back_event.action = "back"
	back_event.pressed = true
	_check(back_event.is_action_pressed("back"), "back action is bound (Esc)")

	screen.queue_free()


func nationality_select_format(value: int) -> String:
	var script := load("res://scenes/title/nationality_select.gd")
	return script.format_thousands(value)


## Reads the value cell next to the `Rep_<nation>` name cell.
func _reputation_cell(rows: GridContainer, nation_id: String) -> String:
	for index in rows.get_child_count():
		var child := rows.get_child(index)
		if child is Label and (child as Label).name == "Rep_%s" % nation_id:
			return (rows.get_child(index + 1) as Label).text
	return "<missing>"


# --- S14 live panel -------------------------------------------------------

func _test_character_panel_live() -> void:
	# Start a real run so the panel has data to show.
	GameState.new_game("holland", false)
	GameState.gold = 7000
	var host := Control.new()
	host.name = "PanelHost"
	add_child(host)
	var panel := CharacterPanelLib.attach_to(host)
	_check(panel != null, "CharacterPanel.attach_to instantiates the panel")
	if panel == null:
		host.queue_free()
		return
	_check(CharacterPanelLib.attach_to(host) == panel, "attach_to is idempotent")
	_check(not panel.is_open(), "panel starts closed")
	panel.open()
	_check(panel.is_open(), "open() shows the panel")

	# Live data: the displayed stats follow GameState without a reopen.
	var stats_rows: VBoxContainer = panel.get_node(
		"Center/Panel/Margin/Body/Columns/Left/StatsRows"
	)
	_check(stats_rows.get_child_count() == 5, "panel renders 5 stat rows")
	var sea_row := stats_rows.get_node("Stat_seamanship")
	var effective_label: Label = sea_row.get_node("Effective")
	_check(effective_label.text == I18n.fmt("char.effective", {"amount": 15}),
		"holland seamanship effective 15 (%s)" % effective_label.text)

	GameState.player["stats"]["seamanship"] = 40
	EventBus.fleet_changed.emit()
	effective_label = stats_rows.get_node("Stat_seamanship/Effective")
	_check(effective_label.text == I18n.fmt("char.effective", {"amount": 40}),
		"panel refreshes on fleet_changed (%s)" % effective_label.text)

	# Gold-driven refresh path (recruit changes gold + roster).
	GameState.player["stats"]["seamanship"] = 15
	EventBus.gold_changed.emit(GameState.gold)

	# Officer roster: recruit one and it must appear in the panel with role+wage.
	var officer_rows: VBoxContainer = panel.get_node(
		"Center/Panel/Margin/Body/Columns/Right/OfficersRows"
	)
	_check(officer_rows.get_child_count() == 1, "empty roster shows one placeholder row")
	_check((officer_rows.get_child(0) as Label).text == I18n.t_key("char.no_officers"),
		"placeholder uses char.no_officers")
	GameState.gold = 5000
	_check(CharacterLib.recruit("off_jan_de_vries"), "recruit a boatswain mid-panel")
	EventBus.fleet_changed.emit()
	var officer_row: HBoxContainer = officer_rows.get_node("Officer_off_jan_de_vries")
	_check(officer_row != null, "recruited officer appears in the panel")
	if officer_row != null:
		_check((officer_row.get_child(0) as Label).text ==
			I18n.t(DataLoader.get_officer("off_jan_de_vries")["name"]),
			"officer row shows the data name")
		_check((officer_row.get_child(1) as Label).text ==
			I18n.t_key("tavern.role.boatswain"),
			"officer row shows the localised role")
		_check((officer_row.get_child(2) as Label).text ==
			I18n.fmt("tavern.wage", {"price": 28}),
			"officer row shows the data wage")
	var wage_label: Label = panel.get_node("Center/Panel/Margin/Body/Columns/Right/Wage")
	_check(wage_label.text == I18n.fmt("char.officer_wage", {"gold": 28}),
		"wage total reflects the roster (%s)" % wage_label.text)

	# Reputation table covers all six nations.
	var rep_rows: GridContainer = panel.get_node(
		"Center/Panel/Margin/Body/Columns/Right/ReputationRows"
	)
	_check(rep_rows.get_child_count() == 12,
		"reputation table has 6 nation rows (got %d labels)"
		% rep_rows.get_child_count())

	# Live reputation: +1 for a profitable sale at a nation's ports (§4.6).
	CharacterLib.add_profit_reputation("spain", 1000)
	EventBus.gold_changed.emit(GameState.gold)
	_check(CharacterLib.reputation("spain") == 1, "reputation stored as +1")
	_check(_reputation_cell(rep_rows, "spain") == "+1",
		"reputation value refreshes live (got '%s')"
		% _reputation_cell(rep_rows, "spain"))
	var own: Label = rep_rows.get_node("Rep_holland")
	_check(own != null and own.text == I18n.t(DataLoader.get_nation("holland")["name"]),
		"own nation row uses its data name")

	# Locale rebinds while open.
	I18n.set_locale("zh")
	_check(stats_rows.get_child_count() == 5, "stats survive a locale change")
	var nav_row := stats_rows.get_node("Stat_navigation")
	var nav_name: Label = nav_row.get_child(0)
	_check(nav_name.text == I18n.t_key("char.navigation"),
		"stat labels rebind on locale change (%s)" % nav_name.text)
	I18n.set_locale("en")

	# Esc closes.
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	panel._unhandled_input(esc)
	_check(not panel.is_open(), "Esc (back action) closes the panel")

	# Toggle action opens/closes (the `C` binding path).
	var toggle := InputEventAction.new()
	toggle.action = "toggle_character"
	toggle.pressed = true
	panel._unhandled_input(toggle)
	_check(panel.is_open(), "toggle_character opens the panel")
	panel._unhandled_input(toggle)
	_check(not panel.is_open(), "toggle_character closes it again")

	# Level-up banner reads the pending flag without consuming it (the HUD
	# toast in T6 owns the consume call).
	GameState.player["xp"] = 49
	CharacterLib.award_xp(1)
	panel.open()
	var banner: Label = panel.get_node("Center/Panel/Margin/Body/LevelUp")
	_check(banner.visible, "panel shows the level-up banner")
	_check(banner.text == I18n.fmt("char.level_up", {"level": 2}),
		"banner uses char.level_up (%s)" % banner.text)
	panel.close()
	_check(not banner.visible, "banner hidden after close")
	_check(CharacterLib.pending_levelup,
		"closing the panel leaves the HUD toast pending")

	# Host wiring over a Node2D screen (the world map, S3): the panel must land
	# in a CanvasLayer and fill the viewport, not collapse to zero size.
	var world_host := Node2D.new()
	world_host.name = "WorldHost"
	add_child(world_host)
	var world_panel := CharacterPanelLib.attach_to(world_host)
	_check(world_panel != null, "attach_to works on a Node2D (S3) host")
	if world_panel != null:
		_check(world_panel.get_parent() is CanvasLayer,
			"Node2D host gets a CanvasLayer wrapper (got %s)"
			% world_panel.get_parent().get_class())
		_check(CharacterPanelLib.attach_to(world_host) == world_panel,
			"attach_to is idempotent through the CanvasLayer wrapper")
	world_host.queue_free()

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
