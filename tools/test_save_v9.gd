extends Node
## Save v9 (Phase 8) acceptance tests: the reshaped Person player block, the
## `officer_states` / `captain_states` top-level blocks, the identity-only
## load rule (docs/90-* §8.1 version 9, §8.2 development-stage scope;
## docs/50-* §4.8; docs/10-* §4.15) and the officer-growth persistence
## (`skill_deltas` — W3's in-post +1/90-sea-days growth, made to survive
## save/load; the retired successor-machinery key `named_pirate_respawns` is
## gone and v8 is refused wholesale, decision 16).
##
##   godot --headless --path . res://tools/test_save_v9.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What this suite is.** Phase 4 deleted the migration chain and Phases 5–9
## keep it removed (decision 16: no migration; a v8 payload is refused like
## any older pre-release save — the v9 bump absorbs the reshaped player block
## (`player.stats` removed: a payload still carrying it is malformed, not
## repairable) and the dropped `named_pirate_respawns` key, so a stale v8
## file — whose people state predates the blocks — must never load into a run
## whose officers/captains the file never carried). This suite therefore
## tests the **current** schema: a v9 payload round-trips byte-equal —
## including both Phase-8 blocks (officers in posts with a ×1.25 `wage_mult`
## and non-empty `skill_deltas`, met captains with stances/familiarity/
## returning statuses), the usage counters mid-growth, `alloc_pending` > 0
## and an appointed voyage (`player.autopilot`) — the older blocks carry over
## unchanged, the documented guards still hold (corrupt payload refused,
## future `save_version` refused, v8 and older refused by name,
## `player.stats` refused as a malformed shape, wrong-typed officer/captain
## entries refused, retired runs summarised not resumed), the runtime-only
## `deployed` key never reaches a payload, the persisted key set is exactly
## the §8.1 v9 list, and the standing proofs run at the end: **mid-month AI
## replay purity** and the **2 MB extreme-save budget** (the W4-B extreme
## was ~1.92 MB; the v9 number is printed for the task report).

## Every v9 §8.1 optional key and its documented default (the
## Phase-2/3/5/6/7 blocks and the two Phase-8 blocks are unchanged in their
## absent-key behavior; `market_stocks`' documented default is the derived
## resting stock, asserted through the loader in the defaults test; the five
## Phase-7 keys' documented default is the **seeded** new-game state —
## asserted through `Allegiance.dump_state()`; the v8 `explored_tiles`
## default is the empty set — the "" string).
const V9_DEFAULTS := {
	"wrecks": [],
	"npc_preset": "normal",
	"control_prefs": {"input_mode": "step", "current_mode": "modifier"},
	"market_events": [],
	"fame": 0,
	"bounties": {},
	"active_quests": [],
	"discoveries_reported": [],
	"discovery_hints": {},
	"battles_won": 0,
	"retired": false,
	"retired_at": 0,
	"explored_tiles": "",
	"officer_states": {},
	"captain_states": {},
}
## The §8.1 Phase-7 payload keys, exactly `Allegiance.dump_state()`'s five
## (docs/90-* §8.1 Phase-7 additions; docs/30-* §4.9).
const V7_ALLEGIANCE_KEYS: Array[String] = [
	"permits", "port_allegiance", "month_invested", "nation_treasuries",
	"fame_commended",
]
## The §8.1 v9 persisted key set — exactly what `snapshot()` writes (the
## three header keys plus the •-marked GameState fields in §8.1 order; the
## superseded `quests` placeholder is never written). The v9 change set:
## `officer_states` / `captain_states` join after `npc_fleets`, and the
## retired Phase-5 `named_pirate_respawns` is gone (docs/90-* §8.1 v9).
const V9_PAYLOAD_KEYS: Array[String] = [
	"save_version", "saved_at", "phase",
	"locale", "day", "gold", "player", "fleet", "morale", "world",
	"current_port", "known_ports", "explored_tiles", "port_investments",
	"discoveries_found", "npc_fleets", "officer_states", "captain_states",
	"proximity_cooldowns", "market_stocks", "wrecks", "npc_preset",
	"control_prefs", "market_events",
	"fame", "titles", "bounties", "active_quests",
	"completed_royal_missions", "discoveries_reported", "discovery_hints",
	"battles_won", "retired", "retired_at",
	"permits", "port_allegiance", "month_invested", "nation_treasuries",
	"fame_commended",
]
## The §8.1 `world`-block defaults (docs/90-* §5.4): absent keys take
## these, and the panel/engines read them guard-style with the same values.
const WORLD_DEFAULTS := {"sail_trim": "normal", "heading": "E", "wind_dir": "E"}
const NATION_IDS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]
## The v8 explored encoding pins (docs/90-* §8.1 version 8) — mirrored from
## SaveSystem so the suite asserts the *documented* numbers, not the code's.
const EXPLORED_GRID := Vector2i(4320, 2160)
const EXPLORED_RUN_BYTES := 6
const EconomyLib := preload("res://scripts/port/economy.gd")
const AllegianceLib := preload("res://scripts/port/allegiance.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const SettingsPanelLib := preload("res://scenes/ui_shared/settings_panel.gd")
const SettingsScene := preload("res://scenes/ui_shared/settings_panel.tscn")

## Fixture officers/captains (data canon ids the round trip grows).
const OFFICER_ID := "off_mateus_alvares"      # main skill: navigation
const OFFICER_CONTROL_ID := "off_diego_fernandez"
const OFFICER_IDLE_ID := "off_leg_blasco_miranda"
const CAPTAIN_PIRATE_ID := "cap_pirate_0042"
const CAPTAIN_TRADER_ID := "cap_trader_0207"

## The extreme-save budget (docs/90-* completion gate: save ≤ 2 MB @ extreme).
const EXTREME_SAVE_BUDGET := 2000000

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	_test_v9_round_trip()
	_test_fixture_shape()
	_test_no_migration_chain()
	_test_older_versions_refused()
	_test_v8_refused()
	_test_future_version_refused()
	_test_player_stats_refused()
	_test_corrupt_phase_fields_rejected()
	_test_wrong_typed_entries_refused()
	_test_explored_codec()
	_test_optional_keys_default()
	_test_new_fields_round_trip()
	_test_debug_overlays_never_saved()
	_test_retired_save()
	_test_mid_month_replay_purity()
	_test_extreme_save_size()
	await _test_s19_rows_and_new_game_carry()
	_cleanup()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A complete **v9** save: every §8.1 key, `phase: 9`, the reshaped v9
## player block (counters mid-growth, `alloc_pending` 4, an appointed
## voyage), officers in posts (`officer_states` with a ×1.25 `wage_mult`
## and the persisted in-post growth `skill_deltas`), met captains
## (`captain_states` with a returning nemesis-track pirate and a friendly
## trader), the world block on the 4320×2160 grid (the §8.1 Lisbon berth
## example), the carried Phase-5 hunter keys, every Phase-6 key at a
## NON-default value, every Phase-7 key at a NON-default value, and the
## explored set at a NON-default value. The fleet is capacity-compliant so
## `Fleet.normalize_all()` is a no-op on load. The retired
## `named_pirate_respawns` key is deliberately absent (v9 dropped it).
func _v9_payload() -> Dictionary:
	return {
		"save_version": 9,
		"saved_at": 1793119712,
		"phase": 9,
		"locale": "en",
		"day": 64,
		"gold": 12540,
		"player": {
			"nation_id": "portugal",
			"background_id": "background_deckhand",
			"attributes": {"constitution": 16, "intellect": 17, "charisma": 10,
				"courage": 10, "luck": 10},
			"skills": {"seamanship": 8, "navigation": 5, "swordplay": 0,
				"gunnery": 0, "appraisal": 0, "negotiation": 0,
				"cartography": 0, "rumour": 0},
			"skill_counters": {"seamanship": 12, "navigation": 5,
				"swordplay": 0, "gunnery": 0, "appraisal": 0, "negotiation": 0,
				"cartography": 0, "rumour": 0},
			"alloc_pending": 4,
			"xp": 400,
			"level": 3,
			"autopilot": {"dest_port_id": "madeira"},
			"officers": [OFFICER_ID],
			"reputation": {
				"portugal": 31, "spain": -4, "england": 6, "holland": 0,
				"ottoman": 0, "italy": 0,
			},
			"profit_by_nation": {"england": 2100},
			"profit_rep_awarded": {"england": 2},
			"equipment": {"weapon": "eq_cutlass", "armor": ""},
		},
		"fleet": [
			{
				"ship_type_id": "caravel",
				"durability": 78,
				"crew": 30,
				"provisions": 40,
				"water": 30,
				"cannons": 6,
				"cargo": {"wine": 20},
				"equipment": {"figurehead": "", "sail": "eq_cotton_sails"},
			},
		],
		"morale": 61,
		"world": {
			"position": {"x": 2050, "y": 615},
			"weather": "fair",
			"map_id": "world",
			"last_departed_port": "lisbon",
			"hunter_intel_cell": {"x": 2213, "y": 1002},
			"sail_trim": "reefed",
			"heading": "NW",
			"wind_dir": "SE",
		},
		"current_port": "lisbon",
		"known_ports": ["lisbon", "seville", "london", "madeira"],
		# v8 explored-state amendment (docs/90-* §8.1 version 8): a NON-default
		# explored set so the round trip proves exact restoration — three runs
		# on three rows, one hugging the seam (x = 4319) and one at y = 0.
		"explored_tiles": _encode_runs([[0, 4319, 1], [615, 2050, 2],
			[1002, 2213, 1]]),
		"port_investments": {"lisbon": 1000},
		"discoveries_found": [],
		"npc_fleets": [],
		# Phase-8 blocks (docs/90-* §8.1 version 9, docs/10-* §4.15): exactly
		# the §4.15 entry shapes — the optional `wage_mult` (≠ 1.0) and
		# `skill_deltas` (the growth this run's pilot accrued in post), and
		# the resting statuses only (`active` / the queued `returning`; no
		# runtime `deployed` key anywhere).
		"officer_states": {
			OFFICER_ID: {
				"loyalty": 62, "sea_days": 95, "post_id": "pilot",
				"ship_id": "", "talk_cd_day": 70, "gift_cd_day": 65,
				"defeats": 1, "wage_mult": 1.25,
				"skill_deltas": {"navigation": 3},
			},
		},
		"captain_states": {
			CAPTAIN_PIRATE_ID: {
				"status": "returning", "return_day": 100, "tier_now": 2,
				"stance": -4, "familiarity": 7, "dossier_seen": true,
				"defeats": 1, "wins": 2,
			},
			CAPTAIN_TRADER_ID: {
				"status": "active", "return_day": 0, "tier_now": 1,
				"stance": 1, "familiarity": 2, "dossier_seen": false,
				"defeats": 0, "wins": 0,
			},
		},
		"proximity_cooldowns": {"pirate": 61},
		"market_stocks": {"lisbon": {"wine": 87, "salt": 12}},
		"wrecks": [],
		"npc_preset": "normal",
		"control_prefs": {"input_mode": "helm", "current_mode": "drift"},
		"market_events": [],
		"fame": 0,
		"titles": {
			"portugal": "none", "spain": "none", "england": "none",
			"holland": "none", "ottoman": "none", "italy": "none",
		},
		"bounties": {},
		"active_quests": [],
		"completed_royal_missions": {
			"portugal": 0, "spain": 0, "england": 0,
			"holland": 0, "ottoman": 0, "italy": 0,
		},
		"discoveries_reported": [],
		"discovery_hints": {},
		"battles_won": 0,
		"retired": false,
		"retired_at": 0,
		# Phase-7 keys (docs/90-* §8.1 Phase-7 additions): non-default values
		# everywhere, `port_allegiance` entries exactly the correction-8
		# shape {ledger, allegiance} (docs/30-* §4.9 — no `development`).
		"permits": {"home": true, "foreign": {"spain": true, "holland": true}},
		"port_allegiance": {
			"madeira": {"ledger": {"portugal": 6000}, "allegiance": "portugal"},
			"malacca": {"ledger": {"england": 6000, "holland": 6000},
				"allegiance": "holland"},
			"quanzhou": {"ledger": {}, "allegiance": ""},
		},
		"month_invested": {"madeira": 1500},
		"nation_treasuries": {
			"portugal": 4200, "spain": 2000, "england": 0, "ottoman": 999999,
		},
		"fame_commended": {"malacca": true, "madeira": true},
	}


# --- 1. The done-when: a v9 save loads and re-saves as v9 ------------------

func _test_v9_round_trip() -> void:
	var fixture := _v9_payload()
	var base_navigation := _base_skill(OFFICER_ID, "navigation")
	var control_navigation := _base_skill(OFFICER_CONTROL_ID, "navigation")
	_ensure_dir()
	_check(_write_json(1, fixture), "the v9 fixture is written to slot 1")

	# Quit-and-restart: wipe the state, then load the v9 file.
	_clobber_state()
	_check(SaveSystem.load(1), "a v9 save loads")
	_check(SaveSystem.last_read_error.is_empty(),
		"the load reports no error (got '%s')" % SaveSystem.last_read_error)
	_check(GameState.fame == 0, "fame restored (0)")
	_check(_nation_map_is(GameState.titles, "none"),
		"every nation's title restored as 'none' (got %s)" % str(GameState.titles))
	_check(GameState.bounties == {} and GameState.bounties is Dictionary,
		"bounties restored as {}")
	_check(GameState.retired == false and GameState.retired_at == 0,
		"retired/retired_at restored as false/0")
	_check(GameState.world.get("map_id") == "world",
		"world.map_id restored as the shipped id (got %s)"
		% str(GameState.world.get("map_id")))
	_check(GameState.quests == [], "the superseded quests list is empty")

	# Nothing else moved: every carried value survives.
	_check(GameState.day == 64 and typeof(GameState.day) == TYPE_INT,
		"day restored exactly (64, got %s)" % str(GameState.day))
	_check(GameState.gold == 12540, "gold restored exactly (12540)")
	_check(GameState.morale == 61, "morale restored exactly (61)")
	_check(GameState.current_port == "lisbon", "current_port restored (lisbon)")
	_check(GameState.world["position"] == {"x": 2050, "y": 615},
		"the re-based world.position restored byte-equal")
	_check(GameState.known_ports == fixture["known_ports"],
		"known_ports restored byte-equal")
	_check(GameState.port_investments == fixture["port_investments"],
		"port_investments restored byte-equal")
	var explored_expected := {
		Vector2i(4319, 0): true,
		Vector2i(2050, 615): true, Vector2i(2051, 615): true,
		Vector2i(2213, 1002): true,
	}
	_check(GameState.explored_tiles == explored_expected,
		"explored_tiles restored byte-equal (4 tiles across 3 runs)")
	_check(GameState.control_prefs == {"input_mode": "helm", "current_mode": "drift"},
		"control_prefs restored exactly (helm + drift)")
	_check(GameState.world["sail_trim"] == "reefed"
		and GameState.world["heading"] == "NW"
		and GameState.world["wind_dir"] == "SE",
		"the Phase-6 ocean keys restored exactly")
	_check(GameState.world["hunter_intel_cell"] == {"x": 2213, "y": 1002},
		"the carried hunter_intel_cell restored")

	# The v9 player block (docs/50-* §4.8): counters mid-growth, the
	# persisted allocation counter and the appointed voyage all round-trip.
	_check(GameState.player == fixture["player"],
		"the v9 player block restored byte-equal")
	_check(GameState.player.get("autopilot") == {"dest_port_id": "madeira"},
		"the appointed voyage restored (player.autopilot)")
	_check(int(GameState.player["alloc_pending"]) == 4,
		"alloc_pending round-trips (the persisted counter, docs/50-* §4.8; "
		+ "the W6-A badge stays a UI matter — the value is the contract)")
	_check(int(GameState.player["skill_counters"]["seamanship"]) == 12,
		"the usage counters round-trip mid-growth (docs/50-* §4.3.3)")

	# The Phase-8 officer block restored byte-equal…
	_check(GameState.officer_states == fixture["officer_states"],
		"officer_states restored byte-equal (docs/90-* §8.1 v9)")
	_check(GameState.captain_states == fixture["captain_states"],
		"captain_states restored byte-equal (docs/90-* §8.1 v9)")
	_check(str(GameState.officer_states[OFFICER_ID]["post_id"]) == "pilot"
		and float(GameState.officer_states[OFFICER_ID]["wage_mult"]) == 1.25,
		"the pilot's post and ×1.25 raise wage_mult restored")
	_check(str(GameState.captain_states[CAPTAIN_PIRATE_ID]["status"]) == "returning"
		and int(GameState.captain_states[CAPTAIN_PIRATE_ID]["return_day"]) == 100,
		"the defeated pirate's return-queue row restored")
	# …and the skill_deltas were APPLIED to the loaded officers.json record —
	# the W3 growth now survives save/load (docs/90-* §8.1 v9): contributions
	# read the grown values after a load.
	_check(_live_skill(OFFICER_ID, "navigation") == base_navigation + 3,
		"skill_deltas applied to the loaded record (%s navigation %d → %d)"
			% [OFFICER_ID, base_navigation, _live_skill(OFFICER_ID, "navigation")])
	_check(_live_skill(OFFICER_CONTROL_ID, "navigation") == control_navigation,
		"the control officer's record stayed at canon (no deltas, no drift)")

	# The Phase-5/7 blocks restore byte-equal too.
	_check(GameState.market_stocks == fixture["market_stocks"],
		"market_stocks restored byte-equal")
	var dump: Dictionary = AllegianceLib.dump_state()
	_check(dump["permits"] == fixture["permits"],
		"permits restored exactly (home + foreign {spain, holland})")
	_check((dump["port_allegiance"] as Dictionary).get("malacca")
		== {"ledger": {"england": 6000, "holland": 6000}, "allegiance": "holland"},
		"port_allegiance: the tie-incumbent allegiance restored (malacca)")

	# --- Re-save: the run is written as version 9 -------------------------
	_check(SaveSystem.save(1), "the run re-saves to slot 1")
	var resaved := _read_json(1)
	_check(not resaved.is_empty(), "the re-saved file parses as JSON")
	_check(int(resaved.get("save_version", -1)) == 9,
		"the re-saved file is save_version 9 (got %s)"
		% str(resaved.get("save_version")))
	_check(int(resaved.get("phase", -1)) == 9,
		"the re-saved file is phase 9 (got %s)" % str(resaved.get("phase")))
	# The persisted key set is EXACTLY the §8.1 v9 list — nothing extra leaks.
	var keys_ok := resaved.keys().size() == V9_PAYLOAD_KEYS.size()
	for key in V9_PAYLOAD_KEYS:
		keys_ok = keys_ok and resaved.has(key)
	_check(keys_ok, "the persisted key set matches the §8.1 v9 list exactly "
		+ "(%d keys, got %d)" % [V9_PAYLOAD_KEYS.size(), resaved.keys().size()])
	_check(not resaved.has("quests"),
		"the re-saved file has no superseded 'quests' key")
	_check(not resaved.has("named_pirate_respawns"),
		"the re-saved file carries no retired named_pirate_respawns key")
	_check(not (resaved["player"] as Dictionary).has("stats"),
		"the re-saved player block carries no retired 'stats' key")
	_check(not JSON.stringify(resaved).contains("deployed"),
		"the runtime-only 'deployed' key never reaches the payload")
	for key in V9_DEFAULTS:
		_check(resaved.has(key),
			"the re-saved file carries '%s' (docs/90-* §8.1)" % key)
	_check(resaved.has("market_stocks"),
		"the re-saved file carries 'market_stocks' (docs/90-* §8.1)")
	for key in V7_ALLEGIANCE_KEYS:
		_check(resaved.has(key),
			"the re-saved file carries the Phase-7 key '%s' (docs/90-* §8.1)" % key)
	_check(resaved.get("explored_tiles") == fixture["explored_tiles"],
		"the re-saved explored_tiles is byte-equal to the loaded one")
	# Both Phase-8 blocks re-save byte-equal: the skill_deltas were re-derived
	# from the (grown) record and the entries rebuilt in the §4.15 shape.
	_check(resaved["officer_states"] == fixture["officer_states"],
		"the re-saved officer_states is byte-equal (deltas re-derived, "
		+ "wage_mult kept, no runtime keys)")
	_check(resaved["captain_states"] == fixture["captain_states"],
		"the re-saved captain_states is byte-equal (statuses/tiers/stances)")
	_check(resaved["player"] == fixture["player"],
		"the re-saved v9 player block is byte-equal")

	# …and the v9 file re-loads to the same state (second cycle — the deltas
	# reset-then-reapply, so a repeated load converges instead of compounding).
	var first_cycle := _loaded_values()
	_clobber_state()
	_check(SaveSystem.load(1), "the re-saved v9 file loads")
	_check(_loaded_values() == first_cycle, "a second save/load cycle changes nothing")
	_check(_live_skill(OFFICER_ID, "navigation") == base_navigation + 3,
		"the second load re-applies the same deltas (no compounding)")


# --- 2. The fixture really is the v9 §8.1 shape ----------------------------

func _test_fixture_shape() -> void:
	var fixture := _v9_payload()
	_check(int(fixture["save_version"]) == SaveSystem.SAVE_VERSION,
		"the fixture is save_version %d" % SaveSystem.SAVE_VERSION)
	_check(int(fixture["phase"]) == SaveSystem.PHASE,
		"the fixture is phase %d" % SaveSystem.PHASE)
	_check(SaveSystem.validate_payload(fixture).is_empty(),
		"validate_payload() accepts the fixture (%s)"
		% SaveSystem.validate_payload(fixture))
	_check(SaveSystem.SAVE_VERSION == 9 and SaveSystem.PHASE == 9,
		"this build ships save_version 9 / phase 9 (Phase 8, decision 16)")
	_check(SaveSystem.DEFAULT_MAP_ID == "world",
		"the shipped map id is 'world' (docs/90-* §9.1)")
	# A snapshot this build writes always validates too — including the
	# officer/captain payloads it derives.
	_load_fixture_into_memory()
	var reason := SaveSystem.validate_payload(SaveSystem.snapshot())
	_check(reason.is_empty(), "a live snapshot validates (%s)" % reason)


# --- 3. No migration chain survives (docs/90-* §8.2 dev scope) -------------

func _test_no_migration_chain() -> void:
	_check(not ("MIGRATIONS" in SaveSystem),
		"SaveSystem carries no MIGRATIONS table any more (dev-stage scope)")
	for name in ["migrate_v1_to_v2", "migrate_v2_to_v3", "migrate_v3_to_v4",
			"migrate_v4_to_v5", "migrate_v5_to_v6", "migrate_v6_to_v7",
			"migrate_v7_to_v8", "migrate_v8_to_v9"]:
		_check(not SaveSystem.has_method(name),
			"the historical migration step %s() is gone" % name)


# --- 4. Older (pre-release) versions are refused by name -------------------

func _test_older_versions_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	for version in [1, 2, 3, 4, 5, 6, 7]:
		var older := _v9_payload()
		older["save_version"] = version
		older["phase"] = version
		_write_json(1, older)
		_check(SaveSystem.load(1) == false,
			"a save_version %d payload fails to load (pre-release)" % version)
		_check(SaveSystem.last_read_error.contains("pre-release")
			and SaveSystem.last_read_error.contains(str(version)),
			"the reason names the pre-release version %d (got '%s')"
			% [version, SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting save_version %d" % version)
		_check(not bool(SaveSystem.list_saves()[0]["valid"]),
			"list_saves() reports the v%d slot invalid" % version)


# --- 4b. A v8 payload is refused (decision 16) ------------------------------

## The §8.2 normative case: a payload exactly as the explored-state amendment
## wrote it (the v9 fixture downgraded to 8 — the version check fires before
## any shape rule, so its extra blocks never matter) refused with the standard
## pre-release message; GameState and the allegiance statics are untouched.
func _test_v8_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	var v8 := _v9_payload()
	v8["save_version"] = 8
	v8["phase"] = 8
	_write_json(1, v8)
	_check(SaveSystem.load(1) == false,
		"a v8 payload fails to load (pre-release save)")
	_check(SaveSystem.last_read_error.contains("pre-release")
		and SaveSystem.last_read_error.contains("8"),
		"the reason is the standard pre-release message (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after refusing the v8 payload (no partial restore)")
	_check(SaveSystem.read_save(1).is_empty(),
		"read_save() refuses the v8 payload too")
	_check(AllegianceLib.dump_state() == before["allegiance"],
		"the allegiance statics were not reseeded by the refused v8 file")
	_check(GameState.officer_states == before["officer_states"]
		and GameState.captain_states == before["captain_states"],
		"the Phase-8 blocks were not touched by the refused v8 file")


# --- 5. A future version is refused ---------------------------------------

func _test_future_version_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	var future := _v9_payload()
	future["save_version"] = SaveSystem.SAVE_VERSION + 1
	future["phase"] = SaveSystem.PHASE + 1
	_write_json(1, future)
	_check(SaveSystem.load(1) == false, "a future save_version fails to load")
	_check(SaveSystem.last_read_error.contains("newer than"),
		"the reason names a newer version (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the future-version rejection")


# --- 5b. A v9 payload carrying `player.stats` is malformed -----------------

## docs/50-* §4.8: `player.stats` is removed at v9 with no migration — a v9
## payload still carrying it is a wrong-typed block, refused loudly, never
## repaired in place (resurrecting retired stats would silently desync every
## §4.2 consumer).
func _test_player_stats_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	var bad := _v9_payload()
	(bad["player"] as Dictionary)["stats"] = {
		"leadership": 10, "seamanship": 10, "combat": 10,
		"navigation": 10, "luck": 10,
	}
	_write_json(1, bad)
	_check(SaveSystem.load(1) == false,
		"a v9 payload carrying player.stats is refused (malformed shape)")
	_check(SaveSystem.last_read_error.contains("player.stats"),
		"the reason names player.stats (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the player.stats rejection")


# --- 6. A wrong-typed or out-of-shape field is rejected -------------------

## Type probes reuse the file's existing convention: a payload this build
## wrote, with one field replaced by a wrong-typed value → refused, reason
## names the key, state untouched.
func _test_corrupt_phase_fields_rejected() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	for probe in [
		{"key": "fame", "value": "lots", "why": "fame as a string"},
		{"key": "titles", "value": [], "why": "titles as an array"},
		{"key": "bounties", "value": 3, "why": "bounties as a number"},
		{"key": "active_quests", "value": {}, "why": "active_quests as an object"},
		{"key": "completed_royal_missions", "value": [], "why":
			"completed_royal_missions as an array"},
		{"key": "discoveries_reported", "value": {}, "why":
			"discoveries_reported as an object"},
		{"key": "discovery_hints", "value": [], "why": "discovery_hints as an array"},
		{"key": "battles_won", "value": "3", "why": "battles_won as a string"},
		{"key": "retired", "value": 1, "why": "retired as a number"},
		{"key": "retired_at", "value": "now", "why": "retired_at as a string"},
		{"key": "npc_fleets", "value": {}, "why": "npc_fleets as an object"},
		{"key": "proximity_cooldowns", "value": [], "why":
			"proximity_cooldowns as an array"},
		{"key": "market_stocks", "value": [], "why":
			"market_stocks as an array"},
		{"key": "wrecks", "value": {}, "why": "wrecks as an object"},
		{"key": "npc_preset", "value": 3, "why": "npc_preset as a number"},
		{"key": "control_prefs", "value": [], "why":
			"control_prefs as an array"},
		{"key": "market_events", "value": {}, "why":
			"market_events as an object"},
		# The Phase-8 blocks: wrong top-level types are rejections like any
		# block (docs/90-* §8.1 version 9).
		{"key": "officer_states", "value": [], "why":
			"officer_states as an array"},
		{"key": "officer_states", "value": 5, "why":
			"officer_states as a number"},
		{"key": "captain_states", "value": [], "why":
			"captain_states as an array"},
		{"key": "captain_states", "value": "none", "why":
			"captain_states as a string"},
		# Phase-7 keys: wrong top-level types are rejections like any block.
		{"key": "permits", "value": [], "why": "permits as an array"},
		{"key": "port_allegiance", "value": [], "why": "port_allegiance as an array"},
		{"key": "month_invested", "value": [], "why": "month_invested as an array"},
		{"key": "nation_treasuries", "value": [], "why":
			"nation_treasuries as an array"},
		{"key": "fame_commended", "value": [], "why": "fame_commended as an array"},
		# The explored key: wrong top-level types are rejections like any
		# block (docs/90-* §8.1 version 8).
		{"key": "explored_tiles", "value": 5, "why": "explored_tiles as a number"},
		{"key": "explored_tiles", "value": [], "why": "explored_tiles as an array"},
		{"key": "explored_tiles", "value": {}, "why": "explored_tiles as an object"},
	]:
		var bad: Dictionary = SaveSystem.snapshot()
		bad[probe["key"]] = probe["value"]
		_write_json(1, bad)
		_check(SaveSystem.load(1) == false, "%s is rejected" % probe["why"])
		_check(SaveSystem.last_read_error.contains(str(probe["key"])),
			"the reason names %s (got '%s')"
			% [probe["key"], SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting %s" % probe["why"])

	# Nested probes: `["path", "to", "key"]` is overwritten by `value` in an
	# otherwise-valid snapshot.
	for probe in [
		{"path": ["control_prefs", "input_mode"], "value": "joystick", "fragment":
			"control_prefs.input_mode", "why":
			"an unknown control_prefs.input_mode id"},
		{"path": ["world", "sail_trim"], "value": "half", "fragment":
			"world.sail_trim", "why": "an unknown world.sail_trim state"},
		{"path": ["world", "heading"], "value": "NNE", "fragment":
			"world.heading", "why": "an off-domain world.heading id"},
		{"path": ["world", "wind_dir"], "value": 90, "fragment":
			"world.wind_dir", "why": "world.wind_dir as a number"},
		{"path": ["world", "last_departed_port"], "value": 5, "fragment":
			"last_departed_port", "why": "world.last_departed_port as a number"},
		{"path": ["world", "hunter_intel_cell"], "value": 5, "fragment":
			"hunter_intel_cell", "why": "world.hunter_intel_cell as a number"},
		{"path": ["permits", "home"], "value": "yes", "fragment":
			"permits.home", "why": "permits.home as a string"},
		{"path": ["port_allegiance", "malacca"], "value": 5, "fragment":
			"port_allegiance.malacca", "why": "a port_allegiance entry as a number"},
		{"path": ["port_allegiance", "malacca", "ledger"], "value": [], "fragment":
			"port_allegiance.malacca.ledger", "why":
			"a port ledger as an array"},
		{"path": ["month_invested", "madeira"], "value": "1500", "fragment":
			"month_invested.madeira", "why":
			"a month_invested counter as a string"},
		{"path": ["nation_treasuries", "spain"], "value": "2000", "fragment":
			"nation_treasuries.spain", "why":
			"a treasury as a string"},
		{"path": ["fame_commended", "malacca"], "value": 1, "fragment":
			"fame_commended.malacca", "why":
			"a commendation flag as a number"},
	]:
		var bad: Dictionary = SaveSystem.snapshot()
		var parent: Dictionary = bad
		var path: Array = probe["path"]
		for i in range(path.size() - 1):
			parent = parent[path[i]]
		parent[path[path.size() - 1]] = probe["value"]
		_write_json(1, bad)
		_check(SaveSystem.load(1) == false, "%s is rejected" % probe["why"])
		_check(SaveSystem.last_read_error.contains(str(probe["fragment"])),
			"the reason names %s (got '%s')"
			% [probe["fragment"], SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting %s" % probe["why"])

	# An unknown map id is rejected too (§8.1/§9.1: "world" is the only id).
	var bad_map: Dictionary = SaveSystem.snapshot()
	bad_map["world"] = {"position": {"x": 1, "y": 1}, "weather": "calm",
		"map_id": "p9"}
	_write_json(1, bad_map)
	_check(SaveSystem.load(1) == false, "an unknown world.map_id is rejected")
	_check(SaveSystem.last_read_error.contains("map_id"),
		"the reason names map_id (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before, "state untouched after the map-id rejection")

	# read_save() applies the same rule without touching GameState.
	_check(SaveSystem.read_save(1).is_empty(),
		"read_save() rejects the same wrong-typed payload")


# --- 6b. The v9 entry shapes themselves (docs/10-* §4.15) ------------------

## The Phase-8 entries are exactly-shaped: every wrong type, out-of-range
## value, missing base key, unknown skill id or runtime-only key (`deployed`)
## is a rejection naming the entry and the field — and one positive control
## proves an officer-only skill delta is accepted.
func _test_wrong_typed_entries_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	# Officer entries (docs/10-* §4.15: loyalty 0–100, non-negative days and
	# counters, string ids, positive wage multiplier, positive deltas over
	# the 11-skill space).
	for probe in [
		{"path": ["officer_states", OFFICER_ID], "value": 5, "fragment":
			"officer_states.%s" % OFFICER_ID, "why": "an officer entry as a number"},
		{"path": ["officer_states", OFFICER_ID, "loyalty"], "value": 101,
			"fragment": "officer_states.%s.loyalty" % OFFICER_ID, "why":
			"loyalty above 100"},
		{"path": ["officer_states", OFFICER_ID, "loyalty"], "value": "62",
			"fragment": "officer_states.%s.loyalty" % OFFICER_ID, "why":
			"loyalty as a string"},
		{"path": ["officer_states", OFFICER_ID, "loyalty"], "value": true,
			"fragment": "officer_states.%s.loyalty" % OFFICER_ID, "why":
			"loyalty as a boolean"},
		{"path": ["officer_states", OFFICER_ID, "sea_days"], "value": -1,
			"fragment": "officer_states.%s.sea_days" % OFFICER_ID, "why":
			"a negative sea_days counter"},
		{"path": ["officer_states", OFFICER_ID, "post_id"], "value": 7,
			"fragment": "officer_states.%s.post_id" % OFFICER_ID, "why":
			"post_id as a number"},
		{"path": ["officer_states", OFFICER_ID, "ship_id"], "value": {},
			"fragment": "officer_states.%s.ship_id" % OFFICER_ID, "why":
			"ship_id as an object"},
		{"path": ["officer_states", OFFICER_ID, "talk_cd_day"], "value": -3,
			"fragment": "officer_states.%s.talk_cd_day" % OFFICER_ID, "why":
			"a negative talk cooldown"},
		{"path": ["officer_states", OFFICER_ID, "gift_cd_day"], "value": "65",
			"fragment": "officer_states.%s.gift_cd_day" % OFFICER_ID, "why":
			"the gift cooldown as a string"},
		{"path": ["officer_states", OFFICER_ID, "defeats"], "value": -1,
			"fragment": "officer_states.%s.defeats" % OFFICER_ID, "why":
			"a negative defeats counter"},
		{"path": ["officer_states", OFFICER_ID, "wage_mult"], "value": 0,
			"fragment": "officer_states.%s.wage_mult" % OFFICER_ID, "why":
			"a zero wage multiplier"},
		{"path": ["officer_states", OFFICER_ID, "wage_mult"], "value": "1.25",
			"fragment": "officer_states.%s.wage_mult" % OFFICER_ID, "why":
			"the wage multiplier as a string"},
		{"path": ["officer_states", OFFICER_ID, "skill_deltas"], "value": [],
			"fragment": "officer_states.%s.skill_deltas" % OFFICER_ID, "why":
			"skill_deltas as an array"},
		{"path": ["officer_states", OFFICER_ID, "skill_deltas", "navigation"],
			"value": 0, "fragment":
			"officer_states.%s.skill_deltas.navigation" % OFFICER_ID, "why":
			"a zero skill delta"},
		{"path": ["officer_states", OFFICER_ID, "skill_deltas", "navigation"],
			"value": -2, "fragment":
			"officer_states.%s.skill_deltas.navigation" % OFFICER_ID, "why":
			"a negative skill delta"},
		{"path": ["officer_states", OFFICER_ID, "skill_deltas", "navigation"],
			"value": "3", "fragment":
			"officer_states.%s.skill_deltas.navigation" % OFFICER_ID, "why":
			"a skill delta as a string"},
		{"path": ["officer_states", OFFICER_ID, "skill_deltas", "leadership"],
			"value": 1, "fragment":
			"officer_states.%s.skill_deltas" % OFFICER_ID, "why":
			"a delta over the retired skill name"},
		# The runtime-only deployment key never persists — in an officer or a
		# captain entry it is a rejection, not a silent strip.
		{"path": ["officer_states", OFFICER_ID, "deployed"], "value": true,
			"fragment": "officer_states.%s" % OFFICER_ID, "why":
			"an officer entry carrying the runtime-only 'deployed' key"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID], "value": 9, "fragment":
			"captain_states.%s" % CAPTAIN_PIRATE_ID, "why":
			"a captain entry as a number"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "status"], "value":
			"defeated", "fragment": "captain_states.%s.status" % CAPTAIN_PIRATE_ID,
			"why": "the instantaneous 'defeated' reading as a persisted status"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "status"], "value": 3,
			"fragment": "captain_states.%s.status" % CAPTAIN_PIRATE_ID, "why":
			"a captain status as a number"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "return_day"], "value": -1,
			"fragment": "captain_states.%s.return_day" % CAPTAIN_PIRATE_ID, "why":
			"a negative return day"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "tier_now"], "value": 4,
			"fragment": "captain_states.%s.tier_now" % CAPTAIN_PIRATE_ID, "why":
			"a tier above the 1..3 clamp"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "tier_now"], "value": 0,
			"fragment": "captain_states.%s.tier_now" % CAPTAIN_PIRATE_ID, "why":
			"tier 0"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "stance"], "value": 11,
			"fragment": "captain_states.%s.stance" % CAPTAIN_PIRATE_ID, "why":
			"a stance above +10"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "stance"], "value": -11,
			"fragment": "captain_states.%s.stance" % CAPTAIN_PIRATE_ID, "why":
			"a stance below −10"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "familiarity"], "value": 100,
			"fragment": "captain_states.%s.familiarity" % CAPTAIN_PIRATE_ID, "why":
			"familiarity above 99"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "familiarity"], "value": -1,
			"fragment": "captain_states.%s.familiarity" % CAPTAIN_PIRATE_ID, "why":
			"negative familiarity"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "dossier_seen"], "value": 1,
			"fragment": "captain_states.%s.dossier_seen" % CAPTAIN_PIRATE_ID, "why":
			"the dossier flag as a number"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "wins"], "value": -2,
			"fragment": "captain_states.%s.wins" % CAPTAIN_PIRATE_ID, "why":
			"a negative wins counter"},
		{"path": ["captain_states", CAPTAIN_PIRATE_ID, "deployed"], "value": true,
			"fragment": "captain_states.%s" % CAPTAIN_PIRATE_ID, "why":
			"a captain entry carrying the runtime-only 'deployed' key"},
	]:
		var bad: Dictionary = SaveSystem.snapshot()
		var parent: Dictionary = bad
		var path: Array = probe["path"]
		for i in range(path.size() - 1):
			parent = parent[path[i]]
		parent[path[path.size() - 1]] = probe["value"]
		_write_json(1, bad)
		_check(SaveSystem.load(1) == false, "%s is rejected" % probe["why"])
		_check(SaveSystem.last_read_error.contains(str(probe["fragment"])),
			"the reason names %s (got '%s')"
			% [probe["fragment"], SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting %s" % probe["why"])

	# Missing-key probes: an officer entry without a base key and a captain
	# entry without its eighth key are shape rejections.
	var missing_sea: Dictionary = SaveSystem.snapshot()
	(missing_sea["officer_states"] as Dictionary)[OFFICER_ID].erase("sea_days")
	_write_json(1, missing_sea)
	_check(SaveSystem.load(1) == false,
		"an officer entry missing 'sea_days' is rejected")
	_check(SaveSystem.last_read_error.contains("sea_days"),
		"the reason names the missing officer key (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before, "state untouched after the missing-key rejection")

	var missing_wins: Dictionary = SaveSystem.snapshot()
	(missing_wins["captain_states"] as Dictionary)[CAPTAIN_TRADER_ID].erase("wins")
	_write_json(1, missing_wins)
	_check(SaveSystem.load(1) == false,
		"a captain entry missing 'wins' is rejected")
	_check(SaveSystem.last_read_error.contains("captain_states.%s" % CAPTAIN_TRADER_ID),
		"the reason names the incomplete captain entry (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the captain missing-key rejection")

	# The player sub-blocks (docs/50-* §4.8): exactly 5 attributes / 8 skills
	# / 8 counters, in range; alloc_pending ≥ 0; autopilot is exactly
	# {dest_port_id}.
	for probe in [
		{"path": ["player", "attributes", "luck"], "value": 0, "fragment":
			"player.attributes.luck", "why": "an attribute below 1"},
		{"path": ["player", "attributes", "luck"], "value": 101, "fragment":
			"player.attributes.luck", "why": "an attribute above 100"},
		{"path": ["player", "attributes", "luck"], "value": "10", "fragment":
			"player.attributes.luck", "why": "an attribute as a string"},
		{"path": ["player", "attributes", "willpower"], "value": 10, "fragment":
			"player.attributes", "why": "an unknown attribute key"},
		{"path": ["player", "skills", "swordplay"], "value": 101, "fragment":
			"player.skills", "why": "a skill above 100"},
		{"path": ["player", "skills", "swordplay"], "value": -1, "fragment":
			"player.skills", "why": "a negative skill"},
		{"path": ["player", "skills", "leadership"], "value": 1, "fragment":
			"player.skills", "why": "a 9-key skills block over the retired name"},
		{"path": ["player", "skill_counters", "seamanship"], "value": -1,
			"fragment": "player.skill_counters", "why":
			"a negative usage counter"},
		{"path": ["player", "alloc_pending"], "value": -2, "fragment":
			"player.alloc_pending", "why": "a negative alloc_pending"},
		{"path": ["player", "alloc_pending"], "value": "4", "fragment":
			"player.alloc_pending", "why": "alloc_pending as a string"},
		{"path": ["player", "autopilot"], "value": {}, "fragment":
			"player.autopilot", "why": "an empty autopilot block"},
		{"path": ["player", "autopilot", "extra"], "value": 1, "fragment":
			"player.autopilot", "why":
			"an autopilot block carrying more than dest_port_id"},
		{"path": ["player", "autopilot", "dest_port_id"], "value": 5, "fragment":
			"player.autopilot.dest_port_id", "why":
			"the appointed destination as a number"},
	]:
		var bad: Dictionary = SaveSystem.snapshot()
		var parent: Dictionary = bad
		var path: Array = probe["path"]
		for i in range(path.size() - 1):
			parent = parent[path[i]]
		parent[path[path.size() - 1]] = probe["value"]
		_write_json(1, bad)
		_check(SaveSystem.load(1) == false, "%s is rejected" % probe["why"])
		_check(SaveSystem.last_read_error.contains(str(probe["fragment"])),
			"the reason names %s (got '%s')"
			% [probe["fragment"], SaveSystem.last_read_error])
		_check(_loaded_values() == before,
			"state untouched after rejecting %s" % probe["why"])

	# A 4-key attributes block (one key dropped) cannot address the §4.2
	# formulas — a shape rejection, not a partial repair.
	var four_attrs: Dictionary = SaveSystem.snapshot()
	(four_attrs["player"] as Dictionary)["attributes"].erase("luck")
	_write_json(1, four_attrs)
	_check(SaveSystem.load(1) == false,
		"a 4-key attributes block is rejected")
	_check(SaveSystem.last_read_error.contains("player.attributes"),
		"the reason names the attributes block (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the attributes-shape rejection")

	# Positive control: an officer-only skill (cooking) is a legal delta key,
	# and a v9 payload without autopilot stays valid (absent = not appointed).
	var ok := SaveSystem.snapshot()
	(ok["officer_states"] as Dictionary)[OFFICER_ID]["skill_deltas"]["cooking"] = 2
	(ok["player"] as Dictionary).erase("autopilot")
	_check(SaveSystem.validate_payload(ok).is_empty(),
		"an officer-only skill delta and an absent autopilot validate (%s)"
		% SaveSystem.validate_payload(ok))


# --- 6c. The explored_tiles encoding itself (docs/90-* §8.1 version 8) -----

## The test-side twin of the v8 encoding: hand-built
## `[u16 y][u16 x0][u16 span−1]` little-endian runs → base64. Used both to
## cross-prove the encoder and to craft exact malformed payloads.
func _encode_runs(runs: Array) -> String:
	var bytes := PackedByteArray()
	for run in runs:
		var y := int(run[0])
		var x0 := int(run[1])
		var span := int(run[2])
		bytes.append(y & 0xFF)
		bytes.append((y >> 8) & 0xFF)
		bytes.append(x0 & 0xFF)
		bytes.append((x0 >> 8) & 0xFF)
		bytes.append((span - 1) & 0xFF)
		bytes.append(((span - 1) >> 8) & 0xFF)
	return Marshalls.raw_to_base64(bytes)


func _test_explored_codec() -> void:
	# The empty set encodes to the documented "" (and is valid).
	_check(SaveSystem._encode_explored({}) == "",
		"an empty explored set encodes to the empty string")
	_check(SaveSystem._explored_error("").is_empty(),
		"the empty string is a valid explored_tiles value")
	_check(SaveSystem._explored_error(null).is_empty(),
		"an absent explored_tiles value is valid (optional key)")

	# Canonical form: same-row neighbours merge into ONE run, and the
	# encoding is deterministic (a re-save stays byte-equal).
	var pair := SaveSystem._encode_explored({
		Vector2i(10, 5): true, Vector2i(11, 5): true,
	})
	_check(pair == SaveSystem._encode_explored({
		Vector2i(11, 5): true, Vector2i(10, 5): true,
	}), "the encoding is key-order independent")
	_check(pair == _encode_runs([[5, 10, 2]]),
		"touching same-row tiles merge into one canonical run")

	# The fixture cross-proof: the encoder produces exactly the string the v9
	# fixture hand-writes for the same set (rows 0 / 615 / 1002).
	var fixture_set := {
		Vector2i(4319, 0): true,
		Vector2i(2050, 615): true, Vector2i(2051, 615): true,
		Vector2i(2213, 1002): true,
	}
	_check(SaveSystem._encode_explored(fixture_set) == _v9_payload()["explored_tiles"],
		"the encoder reproduces the fixture's hand-written explored_tiles")

	# Decode identity: the decoded set is exactly the encoded one.
	var decoded: Dictionary = SaveSystem._decode_explored(
		SaveSystem._encode_explored(fixture_set))
	_check(decoded == fixture_set,
		"decode(encode(set)) == set across seam-adjacent rows")

	# Refusals: every non-canonical or out-of-domain encoding is named.
	_check(SaveSystem._explored_error(5).contains("not a string"),
		"a number is refused with the key named")
	_check(SaveSystem._explored_error("!!!").contains("base64"),
		"a non-base64 string is refused")
	_check(SaveSystem._explored_error(
		Marshalls.raw_to_base64(PackedByteArray([0, 0, 0, 0, 0])))
		.contains("multiple of 6"), "a non-multiple of the run record is refused")
	_check(SaveSystem._explored_error(_encode_runs([[2160, 0, 1]]))
		.contains("outside"), "a run on y = 2160 is refused (grid is 2160 tall)")
	_check(SaveSystem._explored_error(
		_encode_runs([[5, 100, 1], [4, 100, 1]])).contains("sorted"),
		"row-descending runs are refused")
	_check(SaveSystem._explored_error(
		_encode_runs([[5, 10, 2], [5, 12, 2]])).contains("sorted"),
		"touching same-row runs are refused (the canonical form merges them)")

	# One full-load proof: a valid-everything-else payload with an
	# out-of-grid run is refused with the key named, state untouched.
	_load_fixture_into_memory()
	var before := _loaded_values()
	var bad: Dictionary = SaveSystem.snapshot()
	bad["explored_tiles"] = _encode_runs([[999999, 0, 1]])
	_write_json(1, bad)
	_check(SaveSystem.load(1) == false,
		"an out-of-grid explored run rejects the whole payload")
	_check(SaveSystem.last_read_error.contains("explored_tiles"),
		"the rejection reason names explored_tiles (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the explored-encoding rejection")


# --- 7. Every optional field defaults when absent --------------------------

## docs/90-* §8.1 "Default when absent": the optional blocks may be omitted by
## a hand-edited payload and are then restored from the documented default.
## The two Phase-8 blocks default to {} — no employed officers, no met
## captains. An absent Phase-7 quintet restores the **seeded** new-game
## state (`Allegiance.restore_state` seeds first).
func _test_optional_keys_default() -> void:
	_load_fixture_into_memory()
	var payload := _v9_payload()
	for key in ["npc_fleets", "proximity_cooldowns", "market_stocks",
			"wrecks", "npc_preset", "control_prefs",
			"market_events", "fame", "titles",
			"bounties", "active_quests", "completed_royal_missions",
			"discoveries_reported", "discovery_hints", "battles_won",
			"retired", "retired_at", "discoveries_found", "explored_tiles",
			"officer_states", "captain_states"]:
		payload.erase(key)
	for key in V7_ALLEGIANCE_KEYS:
		payload.erase(key)
	var world: Dictionary = payload["world"]
	for key in WORLD_DEFAULTS:
		world.erase(key)
	_write_json(1, payload)
	_clobber_state()
	_check(SaveSystem.load(1),
		"a payload omitting the optional keys (incl. both Phase-8 blocks) loads")
	_check(GameState.officer_states == {} and GameState.officer_states is Dictionary,
		"absent officer_states defaults to {} (no employed officers)")
	_check(GameState.captain_states == {} and GameState.captain_states is Dictionary,
		"absent captain_states defaults to {} (no met captains)")
	_check(GameState.control_prefs == {"input_mode": "step", "current_mode": "modifier"},
		"an absent control_prefs defaults to Step + Modifier")
	_check(GameState.npc_fleets == [] and GameState.npc_fleets is Array,
		"an absent npc_fleets defaults to []")
	_check(GameState.market_stocks.size() == DataLoader.ports_list.size(),
		"an absent market_stocks defaults to the derived initial stock "
		+ "(all %d ports)" % GameState.market_stocks.size())
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 200,
		"the derived default stocks lisbon wine at its capacity 200")
	_check(GameState.fame == 0, "an absent fame defaults to 0")
	_check(GameState.discoveries_found == [],
		"an absent discoveries_found defaults to []")
	_check(GameState.explored_tiles.is_empty()
		and GameState.explored_tiles is Dictionary,
		"an absent explored_tiles defaults to the empty set")
	var dump: Dictionary = AllegianceLib.dump_state()
	_check(dump["permits"] == {"home": false, "foreign": {}},
		"absent permits default to the seeded none")
	_check((dump["port_allegiance"] as Dictionary).size() == _contestable_count(),
		"absent port_allegiance defaults to the full seeded map (%d contestable)"
		% _contestable_count())
	_check((dump["nation_treasuries"] as Dictionary).get("portugal", -1) == 5000,
		"absent nation_treasuries default to the seeded 5,000g each")
	_check(GameState.day == 64 and GameState.gold == 12540,
		"the required fields still restore around the defaults")


# --- 7b. The Phase-8 blocks are real saved state ---------------------------

## Drives the runtime owners the way W3/W4/W5 write them — an in-post officer
## with an accepted raise and a grown record, met captains via the captains
## module (including a `deployed` flag that must never reach the payload),
## counters/alloc/autopilot on the player block — then proves the full
## save → load round trip byte-equal, with the skill_deltas derived from the
## live record over the boot-time canon and re-applied on load.
func _test_new_fields_round_trip() -> void:
	_load_fixture_into_memory()
	var base_navigation := _base_skill(OFFICER_ID, "navigation")
	var idle_seamanship := _base_skill(OFFICER_IDLE_ID, "seamanship")
	var trader_stance := 2
	var trader_familiarity := 5

	# The employed pilot: a raise accepted (×1.25) and one more growth step
	# on the record (the §4.3.2 in-post award writes the card in memory).
	GameState.officer_states[OFFICER_ID]["wage_mult"] = 1.25
	GameState.officer_states[OFFICER_ID]["skill_deltas"] = \
		{"navigation": 1}  # the persisted growth, self-consistent with below
	var pilot: Dictionary = DataLoader.get_officer(OFFICER_ID)
	var skills: Dictionary = pilot.get("skills", {})
	skills["navigation"] = base_navigation + 1
	pilot["skills"] = skills
	# An idle bench officer with no growth and no raise: both optional keys
	# must stay ABSENT from the payload (the §4.15 canonical form). His
	# record stays at canon here — any growth he carried would derive
	# deltas; the stale-growth reset is proven on the load-back side below.
	GameState.officer_states[OFFICER_IDLE_ID] = {
		"loyalty": 50, "sea_days": 3, "post_id": "", "ship_id": "",
		"talk_cd_day": 0, "gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0,
	}
	# Met captains: a friendly trader (dossier seen) and a deployed pirate —
	# the deployment flag is runtime-only (`captains.gd` header contract).
	var trader: Dictionary = CaptainsLib.ensure(CAPTAIN_TRADER_ID)
	trader["stance"] = trader_stance
	trader["familiarity"] = trader_familiarity
	trader["dossier_seen"] = true
	CaptainsLib.ensure(CAPTAIN_PIRATE_ID)
	CaptainsLib.deploy(CAPTAIN_PIRATE_ID)
	var snap := SaveSystem.snapshot()
	_check(not ((snap["captain_states"] as Dictionary)[CAPTAIN_PIRATE_ID]
		as Dictionary).has("deployed"),
		"snapshot() strips the runtime-only 'deployed' key")
	_check(((snap["captain_states"] as Dictionary)[CAPTAIN_PIRATE_ID]
		as Dictionary).size() == 8,
		"the deployed captain's payload entry is exactly the 8 save keys")
	_check(not ((snap["officer_states"] as Dictionary).get(OFFICER_IDLE_ID, {})
		as Dictionary).has("wage_mult"),
		"a wage_mult of 1.0 is not written (the §4.15 optional key)")
	_check(not ((snap["officer_states"] as Dictionary).get(OFFICER_IDLE_ID, {})
		as Dictionary).has("skill_deltas"),
		"an un-grown officer carries no skill_deltas key")
	var pilot_payload: Dictionary = (snap["officer_states"] as Dictionary)[OFFICER_ID]
	_check(int(pilot_payload.get("skill_deltas", {}).get("navigation", -1)) == 1,
		"snapshot() derives skill_deltas from the record over the boot canon")
	# Back to the canonical entry the payload will carry (the round-trip
	# comparison is against the §4.15 save shape, not the seeded superset).
	GameState.officer_states[OFFICER_IDLE_ID].erase("wage_mult")
	CaptainsLib.release(CAPTAIN_PIRATE_ID)  # back to the pure 8-key entry

	# The player block: another level's alloc and a further-grown counter.
	GameState.player["alloc_pending"] = 6
	GameState.player["skill_counters"]["navigation"] = 29
	GameState.player["autopilot"] = {"dest_port_id": "seville"}
	var expected := _loaded_values()

	_check(SaveSystem.save(1), "a run with Phase-8 people state saves")
	var on_disk := _read_json(1)
	_check(on_disk["officer_states"] == expected["officer_states"],
		"snapshot() writes officer_states exactly as driven")
	_check(on_disk["captain_states"] == expected["captain_states"],
		"snapshot() writes captain_states exactly as driven")
	_check(int(((on_disk["captain_states"] as Dictionary)[CAPTAIN_TRADER_ID]
		as Dictionary).get("stance", 0)) == trader_stance,
		"snapshot() writes the captain stance")
	_check(bool(((on_disk["captain_states"] as Dictionary)[CAPTAIN_TRADER_ID]
		as Dictionary).get("dossier_seen", true)) == true,
		"snapshot() writes the dossier flag")
	_check((on_disk["player"] as Dictionary).get("autopilot")
		== {"dest_port_id": "seville"},
		"snapshot() writes the appointed voyage")

	# Load back into a fresh session: records reset to canon, deltas applied.
	_clobber_state()
	var pilot_record: Dictionary = DataLoader.get_officer(OFFICER_ID)
	var reset_skills: Dictionary = pilot_record.get("skills", {})
	reset_skills["navigation"] = base_navigation
	pilot_record["skills"] = reset_skills  # simulate a fresh boot's canon
	var idle_record: Dictionary = DataLoader.get_officer(OFFICER_IDLE_ID)
	var idle_skills: Dictionary = idle_record.get("skills", {})
	idle_skills["seamanship"] = idle_seamanship + 4  # stale in-session growth
	idle_record["skills"] = idle_skills
	_check(SaveSystem.load(1), "the Phase-8 run loads back")
	_check(_loaded_values() == expected,
		"every Phase-2…9 field restores byte-equal after the round trip")
	_check(_live_skill(OFFICER_ID, "navigation") == base_navigation + 1,
		"the loaded record grew by the payload's skill_deltas again")
	_check(_live_skill(OFFICER_IDLE_ID, "seamanship") == idle_seamanship,
		"the idle officer's record was reset to canon (no deltas, no stale "
		+ "in-session growth survives a load)")
	_check(not GameState.captain_states[CAPTAIN_PIRATE_ID].has("deployed"),
		"the restored captain_states carries no runtime 'deployed' key")
	_check(int(GameState.player["alloc_pending"]) == 6,
		"alloc_pending round-trips (docs/50-* §4.8)")
	_check(GameState.player["autopilot"] == {"dest_port_id": "seville"},
		"the appointed voyage round-trips")

	# The snapshot deep-copies: mutating live state cannot rewrite a save.
	var saved_snap := SaveSystem.snapshot()
	GameState.officer_states[OFFICER_ID]["loyalty"] = 1
	GameState.captain_states[CAPTAIN_TRADER_ID]["stance"] = -10
	GameState.player["alloc_pending"] = 0
	_check(int(((saved_snap["officer_states"] as Dictionary)[OFFICER_ID]
		as Dictionary)["loyalty"]) == 62,
		"snapshot() deep-copies officer_states")
	_check(int(((saved_snap["captain_states"] as Dictionary)[CAPTAIN_TRADER_ID]
		as Dictionary)["stance"]) == trader_stance,
		"snapshot() deep-copies captain_states")
	_check(int((saved_snap["player"] as Dictionary)["alloc_pending"]) == 6,
		"snapshot() deep-copies the player block")


# --- 7c. The session-only debug flag never enters a payload ---------------

## docs/80-* §4.6.3 / §4.6 symbol contract: `SettingsPanel.debug_overlays` is
## a static, session-only flag — never saved, never read from a save.
func _test_debug_overlays_never_saved() -> void:
	_load_fixture_into_memory()
	SettingsPanelLib.debug_overlays = true
	var snap := SaveSystem.snapshot()
	_check(not snap.has("debug_overlays"),
		"snapshot() carries no top-level debug_overlays")
	var text := JSON.stringify(snap, "\t")
	_check(not text.contains("debug_overlays"),
		"the serialized payload never names debug_overlays")
	_check(SaveSystem.save(1), "the run with the flag on saves")
	var on_disk := _read_json(1)
	_check(not JSON.stringify(on_disk).contains("debug_overlays"),
		"the on-disk file never names debug_overlays")
	SettingsPanelLib.debug_overlays = false
	_clobber_state()
	_check(SaveSystem.load(1), "the payload loads back")
	_check(SettingsPanelLib.debug_overlays == false,
		"loading a save leaves the session-only flag alone (still off)")
	SettingsPanelLib.debug_overlays = false


# --- 8. A retired save is never playable ----------------------------------

func _test_retired_save() -> void:
	_load_fixture_into_memory()
	GameState.fame = 3100
	GameState.titles["portugal"] = "duke"
	GameState.battles_won = 12
	GameState.retired = true
	GameState.retired_at = 1793120000
	_check(SaveSystem.save(1), "a retired run saves")
	var on_disk := _read_json(1)
	_check(on_disk["retired"] == true,
		"snapshot() writes retired: true (docs/70-* §4.7)")
	_check(int(on_disk.get("retired_at", 0)) == 1793120000,
		"snapshot() writes retired_at")

	_clobber_state()
	var before := _loaded_values()
	_check(SaveSystem.load(1), "a retired save still loads (as a summary)")
	_check(SaveSystem.last_loaded_retired,
		"load() reports the slot as retired")
	_check(_loaded_values() == before,
		"a retired load restores no play state (GameState untouched)")
	_check(AllegianceLib.dump_state() == before["allegiance"],
		"a retired load restores no allegiance state either (statics untouched)")

	var summary: Dictionary = SaveSystem.last_retired_summary
	_check(int(summary.get("day", -1)) == 64, "the summary carries the day count")
	_check(int(summary.get("gold", -1)) == 12540, "the summary carries the gold")
	_check(int(summary.get("fame", -1)) == 3100, "the summary carries the fame")
	_check(int(summary.get("battles", -1)) == 12, "the summary carries battles won")

	# list_saves/slot_summary keep reporting a retired slot as a valid save.
	_check(bool(SaveSystem.list_saves()[0]["valid"]),
		"a retired slot is still a valid, summarisable save")

	# …and a playable save clears the retired flags on the next load.
	_load_fixture_into_memory()
	_check(GameState.retired == false, "the fixture loads as a playable run")
	_check(SaveSystem.save(1), "the run re-saves as playable")
	_clobber_state()
	_check(SaveSystem.load(1), "the playable save loads")
	_check(not SaveSystem.last_loaded_retired,
		"a playable slot reports last_loaded_retired = false")


# --- 9. Mid-month AI replay purity (the Phase-7 proof) ---------------------
#
# docs/90-* §8.2 / docs/30-* §4.9: a save/load mid-month replays the month's
# counter-investment identically — the persisted ledger/allegiance state is
# the AI's only input, so `restore_state` re-deriving the transient trackers
# must leave the month tick a pure function of the payload.

## A lean but fully saveable run (player/fleet/world/stocks) with a clean
## allegiance seed, standing at `day`.
func _make_replay_run(day: int) -> void:
	var reputation: Dictionary = {}
	for nation_id in NATION_IDS:
		reputation[nation_id] = 0
	GameState.locale = "en"
	GameState.player = {
		"nation_id": "portugal",
		"background_id": "",
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 10, "luck": 10},
		"skills": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"skill_counters": {"seamanship": 0, "navigation": 0, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0},
		"alloc_pending": 0,
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": reputation,
		"profit_by_nation": {},
		"profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	GameState.officer_states = {}
	GameState.captain_states = {}
	GameState.fleet = []
	GameState.day = day
	GameState.gold = 50000
	GameState.morale = 70
	GameState.current_port = "lisbon"
	GameState.known_ports = ["lisbon"]
	GameState.port_investments = {}
	GameState.bounties = {}
	GameState.fame = 0
	GameState.world = {
		"position": {"x": 2050, "y": 615},
		"clock_fraction": 0.0,
		"weather": "fair",
		"map_id": "world",
		"last_departed_port": "",
		"hunter_intel_cell": null,
		"sail_trim": "normal",
		"heading": "E",
		"wind_dir": "E",
	}
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list)
	AllegianceLib.seed_new_game()


## One timeline: seed → month-tick 1 (day 1) → mid-month day 17 → (save/load
## when `save_mid_month`) → month-tick 2 (day 31).
func _replay_branch(save_mid_month: bool) -> Dictionary:
	_make_replay_run(1)
	AllegianceLib.month_tick()
	GameState.day = 17
	if save_mid_month:
		_check(SaveSystem.save(1), "the day-17 state saves mid-month")
		_clobber_state()
		_check(SaveSystem.load(1), "the day-17 state loads back")
		_check(GameState.day == 17 and GameState.gold == 50000,
			"the day-17 load restores the clock and purse")
	GameState.day = 31
	AllegianceLib.month_tick()
	var rows: Array = []
	for row in AllegianceLib.last_month_investments():
		rows.append("%s@%s=%d" % [row.get("nation_id", ""),
			row.get("port_id", ""), int(row.get("amount", 0))])
	return {
		"telegraphs": rows,
		"state": AllegianceLib.dump_state(),
		"fame": GameState.fame,
		"reputation": (GameState.player.get("reputation", {}) as Dictionary)
			.duplicate(true),
	}


func _test_mid_month_replay_purity() -> void:
	var saved := _replay_branch(true)
	var never := _replay_branch(false)
	var saved_rows: Array = saved["telegraphs"]
	_check(not saved_rows.is_empty(),
		"the month-2 tick produced %d telegraph rows (the AI is alive)"
		% saved_rows.size())
	_check(saved["telegraphs"] == never["telegraphs"],
		"REPLAY PURITY: the save/load branch's month-2 investment sequence "
		+ "is identical to the never-saved branch's")
	_check(saved["state"] == never["state"],
		"REPLAY PURITY: ledgers, allegiances, treasuries and flags are "
		+ "identical after month-tick 2")
	_check(saved["fame"] == never["fame"] and saved["reputation"] == never["reputation"],
		"REPLAY PURITY: the flip hooks (fame, poaching rep) replay identically")


# --- 10. The extreme-save budget -------------------------------------------

## docs/90-* completion gate: save ≤ 2 MB @ extreme (the W4-B extreme was
## ~1.92 MB; the v9 blocks add the met-captain rows of the populated
## ecology — measured and printed for the task report).
func _test_extreme_save_size() -> void:
	GameState.npc_preset = "extreme"
	GameState.new_game("portugal", false)
	# A late-campaign allegiance world on top of the populated ecology.
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty() or AllegianceLib.is_protected(port_id):
			continue
		for nation_id in NATION_IDS:
			AllegianceLib.add_investment(port_id, nation_id, 2500)
		AllegianceLib.add_investment(port_id, "portugal", 6000)
	var invested := 0
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty() or AllegianceLib.is_protected(port_id) \
				or invested >= 40:
			continue
		AllegianceLib.player_invest_chunk(port_id)
		invested += 1
	AllegianceLib.set_permit("home", "")
	for nation_id in ["spain", "england", "holland", "ottoman", "italy"]:
		AllegianceLib.set_permit("foreign", nation_id)
	# The payload validates and measures within the budget.
	var payload := SaveSystem.snapshot()
	var reason := SaveSystem.validate_payload(payload)
	_check(reason.is_empty(), "the extreme payload validates (%s)" % reason)
	var payload_bytes: int = JSON.stringify(payload, "\t").to_utf8_buffer().size()
	print("MEASURED extreme save payload: %d bytes (%.2f MB; budget %d)"
		% [payload_bytes, payload_bytes / 1048576.0, EXTREME_SAVE_BUDGET])
	print("PROFILE save_v9_extreme_bytes %d" % payload_bytes)
	_check(payload_bytes <= EXTREME_SAVE_BUDGET,
		"the extreme save stays within the 2 MB budget (%d bytes)" % payload_bytes)
	_check((payload["npc_fleets"] as Array).size() >= 100,
		"the extreme fixture carries a populated fleet ecology (%d fleets)"
		% (payload["npc_fleets"] as Array).size())
	# The initial fill deployed one canon captain per fleet (the W4 gate
	# amendment): the v9 captain_states block carries their rows, and every
	# persisted entry is exactly the §4.15 shape (deployed stripped).
	var captain_payload: Dictionary = payload["captain_states"]
	_check(captain_payload.size() >= 100,
		"the extreme fixture carries the met-captain rows (%d captains; "
		+ "extreme payload %d KB total)"
			% [captain_payload.size(), payload_bytes / 1024])
	var entries_ok := true
	for captain_id in captain_payload:
		if (captain_payload[captain_id] as Dictionary).size() != 8:
			entries_ok = false
	_check(entries_ok,
		"every extreme captain_states payload entry is exactly the 8 save keys")
	_check((payload["officer_states"] as Dictionary) == {},
		"the fresh extreme run has no employed officers yet")


# --- 11. The S19 rows flip GameState live; new_game carries the choice -----

## docs/80-* §4.6.3 (task V): the input-mode and current-mode rows write
## `GameState.control_prefs` LIVE on both mounts; the debug row writes ONLY
## the session-only static. Carried from the v8 suite; the new-game carry
## also proves the Phase-8 blocks start at their §8.2 v9 defaults.
func _test_s19_rows_and_new_game_carry() -> void:
	_ensure_dir()
	GameState.control_prefs = {"input_mode": "step", "current_mode": "modifier"}
	var panel: Control = SettingsScene.instantiate()
	add_child(panel)
	await get_tree().process_frame
	_check(panel.apply_input_mode("helm"), "the input-mode setter applies 'helm'")
	_check(str(GameState.control_prefs.get("input_mode")) == "helm",
		"the input-mode row flipped GameState.control_prefs.input_mode live")
	_check(panel.apply_current_mode("drift"),
		"the current-mode setter applies 'drift'")
	_check(panel.apply_input_mode("joystick") == false,
		"an unknown input mode is refused")
	_check(panel.apply_current_mode("tidal") == false,
		"an unknown current mode is refused")
	var debug_button: Button = panel.debug_overlays_button()
	_check(debug_button != null, "the debug row renders")
	panel.queue_free()
	await get_tree().process_frame

	# Pre-game carry (docs/80-* §4.6.3) + the Phase-8 fresh-run defaults
	# (docs/90-* §8.2 v9): officer_states starts empty, captain_states
	# starts as the initial fill's deployed captains.
	GameState.control_prefs = {"input_mode": "helm", "current_mode": "drift"}
	GameState.new_game("portugal", false)
	_check(GameState.control_prefs == {"input_mode": "helm", "current_mode": "drift"},
		"new_game carries the pre-game control_prefs (helm + drift)")
	_check(GameState.officer_states == {},
		"new_game starts officer_states empty (no officers hired yet)")
	_check(not GameState.captain_states.is_empty(),
		"new_game seeds captain_states with the initial fill's deployed "
		+ "captains (%d met)" % GameState.captain_states.size())
	var shape_ok := true
	for captain_id in GameState.captain_states:
		var entry: Dictionary = GameState.captain_states[captain_id]
		for key in ["status", "return_day", "tier_now", "stance",
				"familiarity", "dossier_seen", "defeats", "wins"]:
			if not entry.has(key):
				shape_ok = false
	_check(shape_ok,
		"every seeded captain entry carries the §4.15 save keys")
	_check(GameState.player.get("alloc_pending", -1) == 0
		and not (GameState.player as Dictionary).has("autopilot")
		and not (GameState.player as Dictionary).has("stats"),
		"the fresh player block is the §4.8 default (no stats, no autopilot, "
		+ "alloc_pending 0)")
	_check(SaveSystem.validate_payload(SaveSystem.snapshot()).is_empty(),
		"the fresh run's snapshot validates (the v9 defaults are loadable)")
	# An out-of-domain pre-game value (never written by the panel) falls back.
	GameState.control_prefs = {"input_mode": "bogus", "current_mode": "sideways"}
	GameState.new_game("portugal", false)
	_check(GameState.control_prefs == {"input_mode": "step", "current_mode": "modifier"},
		"new_game repairs an out-of-domain carry to the defaults")
	GameState.control_prefs = {"input_mode": "step", "current_mode": "modifier"}


# --- Helpers --------------------------------------------------------------
# (the Phase-5/6 pair, extended with the allegiance dump and the Phase-8
# blocks so the "state untouched" comparisons cover every restored field)

func _contestable_count() -> int:
	var count := 0
	for port in DataLoader.ports_list:
		if not bool((port as Dictionary).get("protected", false)):
			count += 1
	return count


func _nation_map_is(map: Dictionary, value) -> bool:
	for nation_id in NATION_IDS:
		if not map.has(nation_id) or map[nation_id] != value:
			return false
	return map.size() == NATION_IDS.size()


## The boot-time canon value of one officer skill (SaveSystem's own
## baseline — the deltas are derived against it).
func _base_skill(officer_id: String, skill_id: String) -> int:
	var base: Dictionary = SaveSystem._officer_skill_base.get(officer_id, {})
	return int(base.get(skill_id, 0))


## The live (possibly grown) value of one officer skill.
func _live_skill(officer_id: String, skill_id: String) -> int:
	var officer: Dictionary = DataLoader.get_officer(officer_id)
	return int((officer.get("skills", {}) as Dictionary).get(skill_id, 0))


## Wipes every GameState field with values that cannot be confused with the
## fixture, so a load that silently did nothing is visible. The Phase-8
## blocks are clobbered with malformed sentinels — a load that skipped the
## v9 restore would leave them in `_loaded_values()` and fail the compare.
func _clobber_state() -> void:
	GameState.locale = "zh"
	GameState.day = 1
	GameState.gold = 1
	GameState.morale = 99
	GameState.current_port = null
	GameState.player = {
		"nation_id": "spain", "background_id": "", "attributes": {},
		"skills": {}, "skill_counters": {}, "alloc_pending": 0,
		"xp": 0, "level": 1, "officers": [], "reputation": {},
		"profit_by_nation": {}, "profit_rep_awarded": {},
		"equipment": {"weapon": "", "armor": ""},
	}
	GameState.officer_states = {
		"clobber_officer": {"loyalty": -5, "sea_days": -1},
	}
	GameState.captain_states = {
		"cap_clobber": {"status": "clobbered", "tier_now": 99},
	}
	GameState.fleet = []
	GameState.world = {
		"position": {"x": 0, "y": 0}, "clock_fraction": 0.0,
		"sail_trim": "clobber", "heading": "clobber", "wind_dir": "clobber",
		"last_departed_port": "clobber", "hunter_intel_cell": "clobber",
	}
	GameState.control_prefs = {"input_mode": "clobber", "current_mode": "clobbered"}
	GameState.known_ports = []
	GameState.port_investments = {}
	# A sentinel explored set the fixture never carries — a load that skipped
	# the v8 restore would leave it in `_loaded_values()` and fail the compare.
	GameState.explored_tiles = {Vector2i(7, 7): true}
	GameState.quests = []
	GameState.discoveries_found = []
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {}
	GameState.market_stocks = {"clobber": {"clobber": 1}}
	GameState.wrecks = ["clobber"]
	GameState.npc_preset = "clobbered"
	GameState.market_events = ["clobber"]
	GameState.fame = -1
	GameState.titles = {}
	GameState.bounties = {}
	GameState.active_quests = []
	GameState.completed_royal_missions = {}
	GameState.discoveries_reported = []
	GameState.discovery_hints = {}
	GameState.battles_won = -1
	GameState.retired = false
	GameState.retired_at = -1
	# The allegiance sentinel (seed first, then out-of-fixture keys).
	AllegianceLib.restore_state({
		"permits": {"home": true, "foreign": {"clobber_nation": true}},
		"month_invested": {"clobber_port": 7},
		"nation_treasuries": {"clobber_nation": 7},
		"fame_commended": {"clobber_port": true},
	})


## Everything a load must reproduce (used for "state untouched" comparisons):
## the GameState fields, the Phase-8 blocks, plus the allegiance quintet
## through the runtime owner's dump.
func _loaded_values() -> Dictionary:
	return {
		"locale": GameState.locale,
		"day": GameState.day,
		"gold": GameState.gold,
		"morale": GameState.morale,
		"current_port": GameState.current_port,
		"player": GameState.player.duplicate(true),
		"officer_states": GameState.officer_states.duplicate(true),
		"captain_states": GameState.captain_states.duplicate(true),
		"fleet": GameState.fleet.duplicate(true),
		"world": GameState.world.duplicate(true),
		"control_prefs": GameState.control_prefs.duplicate(true),
		"known_ports": GameState.known_ports.duplicate(),
		"explored_tiles": GameState.explored_tiles.duplicate(),
		"port_investments": GameState.port_investments.duplicate(true),
		"npc_fleets": GameState.npc_fleets.duplicate(true),
		"proximity_cooldowns": GameState.proximity_cooldowns.duplicate(true),
		"market_stocks": GameState.market_stocks.duplicate(true),
		"wrecks": GameState.wrecks.duplicate(true),
		"npc_preset": GameState.npc_preset,
		"market_events": GameState.market_events.duplicate(true),
		"fame": GameState.fame,
		"titles": GameState.titles.duplicate(true),
		"bounties": GameState.bounties.duplicate(true),
		"active_quests": GameState.active_quests.duplicate(true),
		"completed_royal_missions":
			GameState.completed_royal_missions.duplicate(true),
		"discoveries_reported": GameState.discoveries_reported.duplicate(),
		"discovery_hints": GameState.discovery_hints.duplicate(true),
		"battles_won": GameState.battles_won,
		"retired": GameState.retired,
		"retired_at": GameState.retired_at,
		"allegiance": AllegianceLib.dump_state(),
	}


## Loads the v9 fixture once so the "before" state of a rejection test is a
## real loaded run rather than the clobbered sentinel.
func _load_fixture_into_memory() -> void:
	_ensure_dir()
	_write_json(1, _v9_payload())
	_clobber_state()
	if not SaveSystem.load(1):
		_check(false, "setup: the v9 fixture loads before the test")


func _read_json(slot: int) -> Dictionary:
	var text := FileAccess.get_file_as_string(SaveSystem.slot_path(slot))
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	return SaveSystem.normalize_numbers(parsed)


func _write_json(slot: int, data: Dictionary) -> bool:
	_ensure_dir()
	var file := FileAccess.open(SaveSystem.slot_path(slot), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(SaveSystem.SLOT_DIR):
		DirAccess.make_dir_recursive_absolute(SaveSystem.SLOT_DIR)


func _delete_all_slots() -> void:
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")


## Moves any pre-existing save into [member _backup] so the suite never depends
## on (or destroys) the developer's own saves.
func _backup_saves() -> void:
	_backup.clear()
	for slot in range(SaveSystem.SLOT_MIN, SaveSystem.SLOT_MIN + SaveSystem.SLOT_COUNT):
		var path := SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_bytes(path)
			DirAccess.remove_absolute(path)
	_delete_all_slots()


func _cleanup() -> void:
	_delete_all_slots()
	if not _backup.is_empty():
		_ensure_dir()
		for slot in _backup:
			var file := FileAccess.open(SaveSystem.slot_path(int(slot)), FileAccess.WRITE)
			if file != null:
				file.store_buffer(_backup[slot])
				file.close()
		_backup.clear()
	DirAccess.remove_absolute(SaveSystem.SLOT_DIR)


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
