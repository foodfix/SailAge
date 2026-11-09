## The hero-render regression suite (the §4.8 hero-64 display rule,
## 2026-11-08): "this CANNOT happen again". Every committed hero id must
## resolve through the kit registry at 64×64 through the exact lazy
## raw-bytes path the game uses, and the hero HOSTS (the port hub facility
## cards, the market good/trend/info-strip slots) must carry a 64 texture
## in a 64 slot at runtime — a fallback-to-32 on a generated id is a RED
## suite, never a silent visual regression.
##
##   godot --headless res://tools/test_hero_render.tscn
extends Node

const PortScene := preload("res://scenes/port/port_screen.tscn")
const MarketScene := preload("res://scenes/port/market_screen.tscn")
const TextureRegistryScript := preload("res://scripts/ui/texture_registry.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")

const HERO_DIRS := {
	"icon64_": "res://assets/ui/icons64",
	"marker64_": "res://assets/ui/markers64",
	"facility64_": "res://assets/ui/tokens64",
}
const FleetLib := preload("res://scripts/fleet/fleet.gd")

var _failures: Array[String] = []
var _checks := 0
var _host: Control = null


func _ready() -> void:
	_host = Control.new()
	_host.size = Vector2(1920, 1080)
	add_child(_host)
	TextureRegistryScript.ensure_registered()
	await get_tree().process_frame
	_test_hero_files_resolve()
	await _test_port_facility_cards()
	await _test_market_hero_slots()
	_report()


# --- The hero files resolve at 64 through the registry ----------------------

func _hero_ids(dir_path: String) -> Array[String]:
	var ids: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ids
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.ends_with(".png") \
				and not name.begins_with("."):
			ids.append(name.get_basename())
		name = dir.get_next()
	dir.list_dir_end()
	ids.sort()
	return ids


func _test_hero_files_resolve() -> void:
	var total := 0
	var markers_seen := 0
	var facility_seen := 0
	for prefix in HERO_DIRS:
		for id in _hero_ids(HERO_DIRS[prefix]):
			total += 1
			if prefix == "marker64_":
				markers_seen += 1
			elif prefix == "facility64_":
				facility_seen += 1
			var tex := UiKitLib.icon_texture("%s%s" % [prefix, id])
			if tex == null:
				_check(false, "%s%s resolves through the registry"
					% [prefix, id])
				continue
			_check(tex.get_size() == Vector2(64, 64),
				"%s%s decodes at 64×64 (got %s)" % [prefix, id,
					str(tex.get_size())])
	_check(total >= 129 and markers_seen == 6 and facility_seen == 6,
		"the hero families are complete: ≥129 hero files, 6 markers, "
			+ "6 facility tokens (got %d/%d/%d)" % [total, markers_seen,
				facility_seen])


# --- The port hub facility cards carry the 64 hero ---------------------------

func _make_run(port_id: String = "lisbon") -> void:
	# The test_port_hub docked-run fixture (copied — the hero suite owns
	# its own fixture so a hub-suite drift cannot mask a render regression).
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
	GameState.gold = 7830
	GameState.day = 12
	GameState.morale = 70
	GameState.fleet = [FleetLib.new_ship("caravel", 15)]
	var flagship: Dictionary = GameState.fleet[0]
	flagship["provisions"] = 200
	flagship["water"] = 200
	GameState.current_port = port_id
	GameState.world = {
		"position": {"x": 118, "y": 176},
		"clock_fraction": 0.5,
	}
	GameState.known_ports = [port_id]
	GameState.locale = "en"


func _test_port_facility_cards() -> void:
	_make_run("lisbon")
	var hub: Control = PortScene.instantiate()
	hub.route_to_facility = false
	hub.route_to_world = false
	_host.add_child(hub)
	await get_tree().process_frame
	var buttons: Array = hub.facility_buttons()
	_check(buttons.size() >= 4,
		"the docked hub builds its facility cards (got %d)" % buttons.size())
	for button in buttons:
		var facility_id := str(button.get_meta("facility_id"))
		# Phase 12: the token is a direct child of the card button at its
		# authored 2×2-tile slot (the Card/NameRow flow stack is gone).
		var token: TextureRect = button.get_node_or_null("Token")
		if token == null:
			_check(false, "%s: the card carries a Token slot" % facility_id)
			continue
		if token.texture == null or token.texture.get_size() != Vector2(64, 64):
			# diagnostic: where did the facility64 resolution die?
			var raw := "res://assets/ui/tokens64/%s.png" % facility_id
			print("      [diag %s] file_exists(%s)=%s registered=%s" % [
				facility_id, raw,
				str(FileAccess.file_exists(raw)),
				str(TextureRegistryScript.registered_count)])
		_check(token.texture != null
			and token.texture.get_size() == Vector2(64, 64),
			"%s: the token renders the 64 hero 1:1 (got %s)" % [facility_id,
				str(token.texture.get_size()) if token.texture != null
				else "null"])
		_check(int(token.size.x) == 64 and int(token.size.y) == 64,
			"%s: the token slot is the authored 64×64 rect (no 32 fallback)"
				% facility_id)
	hub.queue_free()


# --- The market hero slots ----------------------------------------------------

func _test_market_hero_slots() -> void:
	_make_run("lisbon")
	var screen: Control = MarketScene.instantiate()
	screen.set("route_to_port", false)
	_host.add_child(screen)
	await get_tree().process_frame
	# The selected-row hero (the §4.8 info strip): selecting a good mounts
	# the 64 hero in the strip slot.
	screen.set("_selected_good", "wine")
	screen._refresh_info_strip()
	var hero: TextureRect = screen.get_node_or_null(
		"TableFrame/Table/GoodHero")
	if hero == null:
		_check(false, "the market info strip mounts its hero slot")
	else:
		_check(hero.texture != null
			and hero.texture.get_size() == Vector2(64, 64),
			"the info-strip hero renders the 64 good hero (got %s)"
				% str(hero.texture.get_size() if hero.texture != null
					else "null"))
		_check(int(hero.size.x) == 64,
			"the info-strip hero slot is the authored 2-tile rect (64px)")
	# The row slots: every GoodIcon carries a 64 texture in a 64 slot; a
	# TrendMark, when visible, is 64 too.
	var rows_box: Control = screen.get_node(
		"TableFrame/Table/GoodsScroll/GoodsRows")
	var icons_ok := true
	var trends_seen := 0
	for row in rows_box.get_children():
		if not str(row.name).begins_with("Row_"):
			continue
		var good_icon: TextureRect = row.get_node_or_null("GoodIcon")
		if good_icon == null or good_icon.texture == null \
				or good_icon.texture.get_size() != Vector2(64, 64):
			icons_ok = false
		var trend: TextureRect = _find_descendant(row, "TrendMark")
		if trend != null and trend.visible:
			trends_seen += 1
			if trend.texture == null \
					or trend.texture.get_size() != Vector2(64, 64):
				icons_ok = false
	_check(icons_ok,
		"every row's GoodIcon renders the 64 hero (and any visible "
			+ "TrendMark is 64; %d trend mark(s) visible)" % trends_seen)
	screen.queue_free()


## First descendant Control with the given name (pre-order).
func _find_descendant(root: Node, node_name: String) -> TextureRect:
	for child in root.get_children():
		if child is TextureRect and child.name == node_name:
			return child
		if child is TextureRect and child.name == node_name:
			return child
		var found: TextureRect = _find_descendant(child, node_name)
		if found != null:
			return found
	return null


# --- Report -------------------------------------------------------------------

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
