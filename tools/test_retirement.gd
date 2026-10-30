extends Node
## Phase-3 task H acceptance tests: retirement, the ending screen and retired
## saves (docs/IMPLEMENT-Phase3.md H; docs/70-* §4.7, §4.9.2; docs/80-* §4.1,
## §4.2, §4.7.3; docs/90-* §8.1).
##
##   godot --headless --path . tools/test_retirement.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const FameLib := preload("res://scripts/player/fame.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")
const EndingScene := preload("res://scenes/ui_shared/ending_screen.tscn")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_duke_gate()
	_test_retire_flags()
	_test_summary_block()
	await _test_ending_screen_live()
	await _test_retired_save_round_trip()
	await _test_load_retired_shows_summary()
	_report()


# --- Fixtures -------------------------------------------------------------

func _new_run(port_id: String = "lisbon", day: int = 240) -> void:
	GameState.new_game("portugal", false, "p3")
	GameState.day = day
	GameState.gold = 42000
	GameState.current_port = port_id
	GameState.fame = 0
	GameState.titles = {}
	for nation in DataLoader.nations_list:
		GameState.titles[str(nation["id"])] = "none"
		GameState.completed_royal_missions[str(nation["id"])] = 0
	GameState.discoveries_found = []
	GameState.discoveries_reported = []
	GameState.battles_won = 0
	GameState.retired = false
	GameState.retired_at = 0
	GameState.bounties = {}
	GameState.active_quests = []


## A run one ceremony away from duke (fame 3000 + 8 royal missions).
func _prepare_duke_run() -> void:
	_new_run()
	GameState.fame = 3000
	GameState.completed_royal_missions["portugal"] = 8
	GameState.titles["portugal"] = "count"


# --- 1. The Duke gate -----------------------------------------------------

func _test_duke_gate() -> void:
	_new_run()
	_check(not PalaceEngineLib.can_retire("lisbon"),
		"a commoner cannot retire")
	_check(not PalaceEngineLib.retire("lisbon"), "the retire call is refused")
	_check(not GameState.retired, "the run stays live after a refusal")

	# Famous but untitled: still no (the gate is the title, not fame).
	GameState.fame = 5000
	_check(not PalaceEngineLib.can_retire("lisbon"),
		"fame alone does not unlock retirement")

	# Viscount/count/baron/knight: no.
	for rank in ["knight", "baron", "viscount", "count"]:
		GameState.titles["portugal"] = rank
		_check(not PalaceEngineLib.can_retire("lisbon"),
			"%s cannot retire" % rank)

	# Duke with a *different* nation: the docked nation's title decides.
	GameState.titles["portugal"] = "count"
	GameState.titles["spain"] = "duke"
	_check(not PalaceEngineLib.can_retire("lisbon"),
		"a Spanish dukedom does not unlock the Lisbon palace")
	_check(PalaceEngineLib.can_retire("seville"),
		"the Spanish duke can retire at Seville")

	# Duke with this nation: yes.
	GameState.titles["portugal"] = "duke"
	_check(PalaceEngineLib.can_retire("lisbon"), "a Portuguese duke can retire")
	_check(not PalaceEngineLib.can_retire("athens"),
		"a non-capital never offers retirement")

	# The ceremony really reaches duke from count.
	_prepare_duke_run()
	_check(FameLib.can_promote("portugal"), "count → duke is offered")
	_check(PalaceEngineLib.attend_ceremony("lisbon") == "duke",
		"the ceremony grants duke")
	_check(PalaceEngineLib.can_retire("lisbon"),
		"and retirement is unlocked immediately after")


# --- 2. Retiring flags the run -------------------------------------------

func _test_retire_flags() -> void:
	_prepare_duke_run()
	PalaceEngineLib.attend_ceremony("lisbon")
	var emitted := [false]
	var handler := func() -> void: emitted[0] = true
	EventBus.retired.connect(handler)
	var ok := PalaceEngineLib.retire("lisbon")
	EventBus.retired.disconnect(handler)
	_check(ok, "retire() succeeds at duke")
	_check(GameState.retired, "the run is flagged retired")
	_check(GameState.retired_at > 0, "retired_at records a timestamp (%d)"
		% GameState.retired_at)
	_check(emitted[0], "EventBus.retired fires once")
	# Retiring twice is idempotent (still retired, no error).
	_check(PalaceEngineLib.retire("lisbon"), "a second retire is harmless")
	_check(GameState.retired, "and the run stays retired")


# --- 3. The six-row summary block ---------------------------------------

func _test_summary_block() -> void:
	_new_run("lisbon", 240)
	GameState.gold = 12345
	GameState.fame = 4200
	GameState.battles_won = 17
	GameState.discoveries_reported = ["disc_a", "disc_b", "disc_c"]
	GameState.titles["portugal"] = "duke"
	GameState.titles["spain"] = "baron"
	GameState.retired = true
	GameState.retired_at = 1700000000
	var payload: Dictionary = SaveSystem.snapshot()
	var summary: Dictionary = SaveSystem.retired_summary(payload)
	_check(int(summary["day"]) == 240, "the summary records the day (got %d)"
		% int(summary["day"]))
	_check(int(summary["gold"]) == 12345, "the summary records the gold")
	_check(int(summary["fame"]) == 4200, "the summary records the fame")
	_check(int(summary["discoveries"]) == 3,
		"the summary counts reported discoveries (got %d)"
		% int(summary["discoveries"]))
	_check(int(summary["battles"]) == 17, "the summary counts battles won")
	var titles: Array = summary["titles"]
	_check(titles.size() == 2, "two earned titles are listed (%d)" % titles.size())
	_check((titles[0] as Array) == ["portugal", "duke"],
		"titles are nation-id sorted (%s)" % str(titles))
	_check((titles[1] as Array) == ["spain", "baron"],
		"the second title is Spain's barony")
	_check(int(summary["retired_at"]) == 1700000000,
		"the summary keeps retired_at")
	# The payload really carries the flag (docs/90-* §8.1).
	_check(payload.has("retired") and bool(payload["retired"]),
		"the payload carries retired: true")
	_check(int(payload["retired_at"]) == 1700000000,
		"the payload carries retired_at")


# --- 4. The ending screen in live mode ----------------------------------

func _test_ending_screen_live() -> void:
	_new_run("lisbon", 300)
	GameState.gold = 9876
	GameState.fame = 3100
	GameState.battles_won = 5
	GameState.discoveries_reported = ["disc_a", "disc_b"]
	GameState.titles["portugal"] = "duke"
	GameState.retired = true
	SaveSystem.last_loaded_retired = false
	SaveSystem.last_retired_summary = {}
	var screen: Control = EndingScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	_check(not screen.summary_mode, "a fresh retirement uses live mode")
	_check(not screen.lines().is_empty(), "the screen renders its rows")
	_check(screen.summary["gold"] == 9876, "the live summary reads GameState")


	var title: Label = screen.get_node("Center/Panel/Margin/Body/Title")
	_check(title.text == I18n.t_key("ending.title"),
		"the title is ending.title (%s)" % title.text)
	var rows: VBoxContainer = screen.get_node("Center/Panel/Margin/Body/Rows")
	_check(rows.get_child_count() == 6,
		"exactly six summary rows are shown (%d)" % rows.get_child_count())
	_check(rows.has_node("Row_ending_days"), "the days row exists")
	_check(rows.has_node("Row_ending_gold"), "the gold row exists")
	_check(rows.has_node("Row_ending_fame"), "the fame row exists")
	_check(rows.has_node("Row_ending_titles"), "the titles row exists")
	_check(rows.has_node("Row_ending_discoveries"), "the discoveries row exists")
	_check(rows.has_node("Row_ending_battles"), "the battles row exists")
	_check((rows.get_node("Row_ending_gold") as Label).text
		== I18n.fmt("ending.gold", {"gold": HudLib.format_thousands(9876)}),
		"the gold row uses ending.gold (%s)"
		% (rows.get_node("Row_ending_gold") as Label).text)
	_check((rows.get_node("Row_ending_fame") as Label).text
		== I18n.fmt("ending.fame", {"fame": 3100}),
		"the fame row uses ending.fame")
	_check((rows.get_node("Row_ending_battles") as Label).text
		== I18n.fmt("ending.battles", {"count": 5}),
		"the battles row uses ending.battles")
	var titles_text: String = (rows.get_node("Row_ending_titles") as Label).text
	_check(titles_text.contains(I18n.t_key("rank.duke")),
		"the titles row names the dukedom (%s)" % titles_text)

	# Both locales, no raw keys.
	var leaked: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		for line in screen.lines():
			if str(line).contains("<") and str(line).contains(">"):
				leaked.append("%s: %s" % [locale, str(line)])
	_check(leaked.is_empty(), "S16 prints no raw <key> (%s)"
		% str(leaked.slice(0, 3)))
	I18n.set_locale("zh")
	_check(title.text == _ui_zh("ending.title"),
		"the zh title is 航程终章 (%s)" % title.text)
	I18n.set_locale("en")
	_check(title.text == _ui_en("ending.title"), "the en title is Voyage's End")

	var cont: Button = screen.get_node("Center/Panel/Margin/Body/Footer/Continue")
	_check(cont.text == I18n.t_key("ending.continue"),
		"the button says ending.continue (%s)" % cont.text)
	screen.queue_free()
	await get_tree().process_frame


# --- 5. Retired save round trip ----------------------------------------

func _test_retired_save_round_trip() -> void:
	_prepare_duke_run()
	PalaceEngineLib.attend_ceremony("lisbon")
	GameState.gold = 5555
	GameState.battles_won = 9
	GameState.discoveries_reported = ["disc_a"]
	PalaceEngineLib.retire("lisbon")
	_check(GameState.retired, "the run is retired before saving")
	var saved := SaveSystem.save(2)
	_check(saved, "the retired run saves to slot 2")
	if not saved:
		return
	# The payload on disk carries the flags.
	var on_disk: Dictionary = SaveSystem.read_save(2)
	_check(bool(on_disk.get("retired", false)), "the saved file says retired: true")
	_check(int(on_disk.get("retired_at", 0)) > 0, "the saved file keeps retired_at")
	_check((on_disk.get("discoveries_reported", []) as Array).has("disc_a"),
		"the payload carries the discovered report")

	# A load restores **nothing** and reports the summary instead.
	GameState.gold = 1
	GameState.day = 1
	var restored := SaveSystem.load(2)
	_check(restored, "a retired slot loads without error")
	_check(SaveSystem.last_loaded_retired,
		"the load reports it was a retired save")
	_check(GameState.gold == 1 and GameState.day == 1,
		"GameState is untouched by a retired load (gold %d, day %d)"
		% [GameState.gold, GameState.day])
	var summary: Dictionary = SaveSystem.last_retired_summary
	_check(int(summary["gold"]) == 5555,
		"the summary carries the saved gold (got %d)" % int(summary["gold"]))
	_check(int(summary["battles"]) == 9, "the summary carries the battle count")
	_check(int(summary["discoveries"]) == 1, "the summary carries the discoveries")
	_check((summary["titles"] as Array).size() == 1,
		"the summary carries the earned title")


# --- 6. Loading a retired slot opens S16 in summary mode ---------------

func _test_load_retired_shows_summary() -> void:
	_prepare_duke_run()
	PalaceEngineLib.attend_ceremony("lisbon")
	GameState.gold = 7777
	GameState.fame = 3000
	GameState.battles_won = 3
	GameState.discoveries_reported = ["disc_a", "disc_b"]
	PalaceEngineLib.retire("lisbon")
	SaveSystem.save(3)
	SaveSystem.load(3)
	_check(SaveSystem.last_loaded_retired, "the slot is a retired save")

	# The ending screen reads `SaveSystem`'s summary, not the live state.
	GameState.gold = 0
	GameState.fame = 0
	GameState.titles["portugal"] = "none"
	var screen: Control = EndingScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	_check(screen.summary_mode, "S16 opens in summary mode")
	var title: Label = screen.get_node("Center/Panel/Margin/Body/Title")
	_check(title.text == I18n.t_key("ending.retired_title"),
		"the retired title is ending.retired_title (%s)" % title.text)
	var rows: VBoxContainer = screen.get_node("Center/Panel/Margin/Body/Rows")
	_check((rows.get_node("Row_ending_gold") as Label).text
		== I18n.fmt("ending.gold", {"gold": HudLib.format_thousands(7777)}),
		"the summary shows the saved gold, not the live 0 (%s)"
		% (rows.get_node("Row_ending_gold") as Label).text)
	_check((rows.get_node("Row_ending_fame") as Label).text
		== I18n.fmt("ending.fame", {"fame": 3000}),
		"the summary shows the saved fame")
	_check((rows.get_node("Row_ending_titles") as Label).text
		.contains(I18n.t_key("rank.duke")),
		"the summary shows the saved dukedom")

	# Both locales.
	var leaked: Array = []
	for locale in ["en", "zh"]:
		I18n.set_locale(locale)
		await get_tree().process_frame
		for line in screen.lines():
			if str(line).contains("<") and str(line).contains(">"):
				leaked.append("%s: %s" % [locale, str(line)])
	_check(leaked.is_empty(), "the retired summary prints no raw <key> (%s)"
		% str(leaked.slice(0, 3)))
	I18n.set_locale("zh")
	_check(title.text == _ui_zh("ending.retired_title"),
		"the zh retired title is 这位船长已经退休 (%s)" % title.text)
	I18n.set_locale("en")
	_check(title.text == _ui_en("ending.retired_title"),
		"the en retired title is This captain has retired")

	# S13's Retire row routes here in production (the call path, not the swap).
	_check(ResourceLoader.exists("res://scenes/ui_shared/ending_screen.tscn"),
		"the S16 scene exists for the S13 route")
	_new_run()
	_prepare_duke_run()
	PalaceEngineLib.attend_ceremony("lisbon")
	var palace: Control = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(palace.retire(), "the palace's retire path succeeds at duke")
	_check(GameState.retired, "the palace flagged the run")
	palace.queue_free()
	await get_tree().process_frame

	# The retire confirm modal: declining changes nothing (§4.7 pin).
	_new_run()
	_prepare_duke_run()
	PalaceEngineLib.attend_ceremony("lisbon")
	GameState.retired = false
	palace = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(palace.request_retire(), "the Retire row opens a confirm")
	var confirm: Control = palace.get_node("ConfirmDialog")
	_check(confirm.is_open(), "the confirm dialog is open")
	confirm.cancel()
	await get_tree().process_frame
	_check(not GameState.retired, "declining changes nothing")
	palace.queue_free()
	await get_tree().process_frame

	screen.queue_free()
	await get_tree().process_frame

	# Clean up the slot so a later run starts clean.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		SaveSystem.slot_path(3)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		SaveSystem.slot_path(2)))


# --- Helpers -------------------------------------------------------------

func _ui_en(key: String) -> String:
	return str((DataLoader.ui_strings.get(key, {}) as Dictionary).get("en", ""))


func _ui_zh(key: String) -> String:
	return str((DataLoader.ui_strings.get(key, {}) as Dictionary).get("zh", ""))


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
