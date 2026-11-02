extends Node
## Explored-state amendment (2026-11-02) acceptance tests: the v8 save schema
## and the identity-only load rule (docs/90-* §8.1 version 8, §8.2
## development-stage scope; docs/20-* §4.12 the explored set; docs/30-*
## §4.9/§4.10 the allegiance state carried over from v7).
##
##   godot --headless --path . res://tools/test_save_v8.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **What this suite is.** Phase 4 deleted the migration chain and Phases 5–8
## keep it removed (decision 13: no migration; a v7 payload is refused like
## any older pre-release save — the v8 bump absorbs the `explored_tiles`
## key, so a stale v7 file — whose shape predates the key — must never load
## into a run whose fog boundary the file never carried). This suite
## therefore tests the **current** schema: a v8 payload round-trips byte-equal
## — including the explored set (`explored_tiles`, the base64 row-run
## encoding of docs/90-* §8.1 v8) and the five allegiance keys — the older
## blocks carry over unchanged, the documented guards still hold
## (corrupt payload refused, future `save_version` refused, v7 and older
## refused by name, retired runs summarised not resumed), an out-of-shape
## value is refused exactly like any other wrong-typed block — including the
## explored encoding itself (not base64, a non-multiple of the run record,
## an out-of-grid or unsorted/touching run) — and the standing proofs run at
## the end: **mid-month AI replay purity** (a save/load on day 17 replays
## month-tick 2's counter-investment identically to a never-saved run
## reaching the same day) and the **2 MB extreme-save budget** (measured size
## printed for the task report). Sections at the end drive the S19 rows
## (§4.6.3) through the panel API and prove the `new_game` carry — including
## the `Allegiance.seed_new_game()` seeding contract (contestable sovereign
## `{owner: 6,000}`, neutrals empty).
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved
## into memory and written back at the end; every file this suite creates is
## removed again (start AND end), exactly like `tools/test_save.gd`.

## Every v8 §8.1 optional key and its documented default (the
## Phase-2/3/5/6/7 blocks are unchanged; `market_stocks`' documented default
## is the derived resting stock, asserted through the loader in the defaults
## test; the five Phase-7 keys' documented default is the **seeded**
## new-game state — asserted through `Allegiance.dump_state()`; the v8
## `explored_tiles` default is the empty set — the "" string).
const V8_DEFAULTS := {
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
}
## The §8.1 Phase-7 payload keys, exactly `Allegiance.dump_state()`'s five
## (docs/90-* §8.1 Phase-7 additions; docs/30-* §4.9).
const V7_ALLEGIANCE_KEYS: Array[String] = [
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
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const SettingsPanelLib := preload("res://scenes/ui_shared/settings_panel.gd")
const SettingsScene := preload("res://scenes/ui_shared/settings_panel.tscn")

## The extreme-save budget (docs/90-* completion gate: save ≤ 2 MB @ extreme).
const EXTREME_SAVE_BUDGET := 2000000

var _failures: Array[String] = []
var _checks := 0
## `{slot: bytes}` of saves that existed before the suite ran (restored at end).
var _backup: Dictionary = {}


func _ready() -> void:
	_backup_saves()
	_test_v8_round_trip()
	_test_fixture_shape()
	_test_no_migration_chain()
	_test_older_versions_refused()
	_test_v7_shape_refused()
	_test_future_version_refused()
	_test_corrupt_phase_fields_rejected()
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

## A complete **v8** save: every §8.1 key, `phase: 8`, the world block on the
## 4320×2160 grid (the §8.1 Lisbon berth example), the carried Phase-5 hunter
## keys, every Phase-6 key at a NON-default value, every Phase-7 key at a
## NON-default value (so the round trip can prove exact restoration:
## `permits` home + a two-nation foreign map, `port_allegiance` with the
## sovereign-seed shape (madeira), the **tie-incumbent** allegiance (malacca:
## england and holland tie at 6,000g and the persisted allegiance holland
## wins over sorted-first england — the reason allegiance is persisted at
## all, correction 8) and an empty neutral (quanzhou), a spent
## `month_invested` counter, `nation_treasuries` with a nation pinned at the
## 2,000g NPC-tax cap constant, one drained to 0 and one large, and two
## `fame_commended` flags, and the v8 explored set at a NON-default value
## (three canonical runs, one hugging the seam). The fleet is
## capacity-compliant so `Fleet.normalize_all()` is a no-op on load.
func _v8_payload() -> Dictionary:
	return {
		"save_version": 8,
		"saved_at": 1793119712,
		"phase": 8,
		"locale": "en",
		"day": 64,
		"gold": 12540,
		"player": {
			"nation_id": "portugal",
			"stats": {
				"leadership": 12, "seamanship": 14, "combat": 11,
				"navigation": 21, "luck": 10,
			},
			"xp": 400,
			"level": 3,
			"officers": ["off_mateus_alvares"],
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
		# The bytes are `SaveSystem._encode_explored`'s canonical output for
		# {row 0: x 4319; row 615: x 2050..2051; row 1002: x 2213} — hand-
		# writing them keeps the fixture an honest v8 document; the codec test
		# proves the encoder produces exactly this string for that set.
		"explored_tiles": _encode_runs([[0, 4319, 1], [615, 2050, 2],
			[1002, 2213, 1]]),
		"port_investments": {"lisbon": 1000},
		"discoveries_found": [],
		"npc_fleets": [],
		"proximity_cooldowns": {"pirate": 61},
		"market_stocks": {"lisbon": {"wine": 87, "salt": 12}},
		"wrecks": [],
		"npc_preset": "normal",
		"control_prefs": {"input_mode": "helm", "current_mode": "drift"},
		"market_events": [],
		"named_pirate_respawns": {},
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


## A **true v7-shaped** payload (what Phase 7 actually wrote): exactly the v8
## fixture minus the `explored_tiles` key, with `save_version` / `phase` 7.
## Refused on load, never repaired in place.
func _v7_payload() -> Dictionary:
	var payload := _v8_payload()
	payload["save_version"] = 7
	payload["phase"] = 7
	payload.erase("explored_tiles")
	return payload


# --- 1. The done-when: a v8 save loads and re-saves as v8 ------------------

func _test_v8_round_trip() -> void:
	var fixture := _v8_payload()
	_ensure_dir()
	_check(_write_json(1, fixture), "the v8 fixture is written to slot 1")

	# Quit-and-restart: wipe the state, then load the v8 file.
	_clobber_state()
	_check(SaveSystem.load(1), "a v8 save loads")
	_check(SaveSystem.last_read_error.is_empty(),
		"the load reports no error (got '%s')" % SaveSystem.last_read_error)
	_check(GameState.fame == 0, "fame restored (0)")
	_check(_nation_map_is(GameState.titles, "none"),
		"every nation's title restored as 'none' (got %s)" % str(GameState.titles))
	_check(_nation_map_is(GameState.completed_royal_missions, 0),
		"every nation's royal-mission count restored as 0")
	_check(GameState.bounties == {} and GameState.bounties is Dictionary,
		"bounties restored as {}")
	_check(GameState.active_quests == [] and GameState.active_quests is Array,
		"active_quests restored as []")
	_check(GameState.discoveries_reported == [], "discoveries_reported restored as []")
	_check(GameState.discovery_hints == {} and GameState.discovery_hints is Dictionary,
		"discovery_hints restored as {}")
	_check(GameState.battles_won == 0, "battles_won restored as 0")
	_check(GameState.retired == false and GameState.retired_at == 0,
		"retired/retired_at restored as false/0")
	_check(GameState.world.get("map_id") == "world",
		"world.map_id restored as the shipped id (got %s)"
		% str(GameState.world.get("map_id")))
	_check(GameState.quests == [], "the superseded quests list is empty")

	# Nothing else moved: every pre-existing value survives.
	_check(GameState.day == 64 and typeof(GameState.day) == TYPE_INT,
		"day restored exactly (64, got %s)" % str(GameState.day))
	_check(GameState.gold == 12540, "gold restored exactly (12540)")
	_check(GameState.morale == 61, "morale restored exactly (61)")
	_check(GameState.current_port == "lisbon", "current_port restored (lisbon)")
	_check(GameState.world["position"] == {"x": 2050, "y": 615},
		"the re-based world.position restored byte-equal")
	_check(GameState.world["weather"] == "fair", "world.weather restored (fair)")
	_check(GameState.known_ports == fixture["known_ports"],
		"known_ports restored byte-equal")
	_check(GameState.port_investments == fixture["port_investments"],
		"port_investments restored byte-equal")
	# v8 explored-state amendment (docs/90-* §8.1 version 8): the explored set
	# restores EXACTLY as Vector2i keys — the fixture's three runs decode to
	# four tiles (row 615 carries a two-tile run), seam tile included.
	var explored_expected := {
		Vector2i(4319, 0): true,
		Vector2i(2050, 615): true, Vector2i(2051, 615): true,
		Vector2i(2213, 1002): true,
	}
	_check(GameState.explored_tiles == explored_expected,
		"explored_tiles restored byte-equal (4 tiles across 3 runs, got %s)"
		% str(GameState.explored_tiles))
	_check(GameState.proximity_cooldowns == {"pirate": 61},
		"proximity_cooldowns restored byte-equal")
	_check(GameState.player.get("equipment") == {"weapon": "eq_cutlass", "armor": ""},
		"the player equipment block is restored")
	_check((GameState.fleet[0] as Dictionary).get("equipment")
		== {"figurehead": "", "sail": "eq_cotton_sails"},
		"the ship equipment block is restored")

	# The Phase-5 blocks restore byte-equal too.
	_check(GameState.market_stocks == fixture["market_stocks"],
		"market_stocks restored byte-equal")
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 87,
		"a displaced stock restores its exact value (87)")
	_check(GameState.wrecks == [] and GameState.npc_preset == "normal"
		and GameState.market_events == [],
		"wrecks/npc_preset/market_events restore from the fixture")

	# The Phase-6 keys restore EXACTLY (docs/90-* §8.1 Phase-6 additions).
	_check(GameState.control_prefs == {"input_mode": "helm", "current_mode": "drift"},
		"control_prefs restored exactly (helm + drift, got %s)"
		% str(GameState.control_prefs))
	_check(GameState.world["sail_trim"] == "reefed",
		"world.sail_trim restored exactly (reefed, got '%s')"
		% str(GameState.world.get("sail_trim")))
	_check(GameState.world["heading"] == "NW",
		"world.heading restored exactly (NW, got '%s')"
		% str(GameState.world.get("heading")))
	_check(GameState.world["wind_dir"] == "SE",
		"world.wind_dir restored exactly (SE, got '%s')"
		% str(GameState.world.get("wind_dir")))
	# The Phase-5 hunter keys carry over unchanged in shape (docs/90-* §8.1:
	# cell re-based to the 4320×2160 grid — the breaking change v6 absorbed).
	_check(GameState.world["last_departed_port"] == "lisbon",
		"world.last_departed_port carried over (lisbon)")
	_check(GameState.world["hunter_intel_cell"] == {"x": 2213, "y": 1002},
		"the re-based hunter_intel_cell carried over (got %s)"
		% str(GameState.world.get("hunter_intel_cell")))

	# The Phase-7 keys restore EXACTLY (docs/90-* §8.1 Phase-7 additions),
	# read back through the runtime owner's dump (the persistence seam).
	var dump: Dictionary = AllegianceLib.dump_state()
	_check(dump["permits"] == fixture["permits"],
		"permits restored exactly (home + foreign {spain, holland}, got %s)"
		% str(dump.get("permits")))
	_check(AllegianceLib.has_permit_home() and AllegianceLib.has_permit_foreign("spain")
		and AllegianceLib.has_permit_foreign("holland"),
		"the restored permits read live through the allegiance accessors")
	_check((dump["port_allegiance"] as Dictionary).get("madeira")
		== {"ledger": {"portugal": 6000}, "allegiance": "portugal"},
		"port_allegiance: the sovereign-seed shape restored exactly (madeira)")
	_check((dump["port_allegiance"] as Dictionary).get("malacca")
		== {"ledger": {"england": 6000, "holland": 6000}, "allegiance": "holland"},
		"port_allegiance: the tie-incumbent allegiance restored exactly "
		+ "(malacca keeps holland, not sorted-first england — correction 8)")
	_check((dump["port_allegiance"] as Dictionary).get("quanzhou")
		== {"ledger": {}, "allegiance": ""},
		"port_allegiance: the empty neutral restored exactly (quanzhou)")
	_check(AllegianceLib.effective_alignment("malacca") == "holland",
		"the restored tie-incumbent allegiance drives effective_alignment")
	_check(dump["month_invested"] == fixture["month_invested"],
		"month_invested restored exactly (madeira 1,500, got %s)"
		% str(dump.get("month_invested")))
	_check(AllegianceLib.month_invested_gold("madeira") == 1500,
		"the restored allowance counter reads live (madeira 1,500)")
	_check(dump["nation_treasuries"].get("portugal") == 4200
		and dump["nation_treasuries"].get("spain") == 2000
		and dump["nation_treasuries"].get("england") == 0
		and dump["nation_treasuries"].get("ottoman") == 999999,
		"nation_treasuries restored exactly (2,000g-cap literal, a 0, a large)")
	_check(dump["fame_commended"] == fixture["fame_commended"],
		"fame_commended restored exactly ({malacca, madeira}, got %s)"
		% str(dump.get("fame_commended")))
	# Unlisted contestable ports keep the seeded defaults (the payload is the
	# delta over `seed_new_game`, docs/90-* §8.1 "Default when absent").
	_check((dump["port_allegiance"] as Dictionary).size() == _contestable_count(),
		"every contestable port is serialized (%d, got %d)"
		% [_contestable_count(), (dump["port_allegiance"] as Dictionary).size()])
	_check(not (dump["port_allegiance"] as Dictionary).has("lisbon"),
		"the protected port lisbon is never serialized (no ledger exists)")

	# --- Re-save: the run is written as version 8 -------------------------
	_check(SaveSystem.save(1), "the run re-saves to slot 1")
	var resaved := _read_json(1)
	_check(not resaved.is_empty(), "the re-saved file parses as JSON")
	_check(int(resaved.get("save_version", -1)) == 8,
		"the re-saved file is save_version 8 (got %s)"
		% str(resaved.get("save_version")))
	_check(int(resaved.get("phase", -1)) == 8,
		"the re-saved file is phase 8 (got %s)" % str(resaved.get("phase")))
	for key in V8_DEFAULTS:
		_check(resaved.has(key),
			"the re-saved file carries '%s' (docs/90-* §8.1)" % key)
	_check(resaved.has("market_stocks"),
		"the re-saved file carries 'market_stocks' (docs/90-* §8.1)")
	for key in V7_ALLEGIANCE_KEYS:
		_check(resaved.has(key),
			"the re-saved file carries the Phase-7 key '%s' (docs/90-* §8.1)" % key)
	var resaved_world: Dictionary = resaved["world"]
	for key in WORLD_DEFAULTS:
		_check(resaved_world.has(key),
			"the re-saved world block carries '%s' (docs/90-* §8.1)" % key)
	_check(not resaved.has("quests"),
		"the re-saved file has no superseded 'quests' key")
	_check(resaved_world.get("map_id") == "world",
		"the re-saved world block carries the shipped map id")
	_check(not resaved_world.has("clock_fraction") and not resaved.has("debug_overlays"),
		"the re-save still omits clock_fraction / debug_overlays")
	# The v8 amendment's determinism proof: the restored set re-encodes to the
	# fixture's exact bytes (sorted canonical runs — no drift across cycles).
	_check(resaved.get("explored_tiles") == fixture["explored_tiles"],
		"the re-saved explored_tiles is byte-equal to the loaded one")
	# Correction 8: the persisted allegiance shape is exactly
	# {ledger, allegiance} — development is derived and never serialized.
	var resaved_pa: Dictionary = resaved["port_allegiance"]
	_check(resaved_pa.size() == _contestable_count(),
		"the re-saved port_allegiance covers every contestable port (%d)"
		% resaved_pa.size())
	var shape_ok := true
	for port_id in resaved_pa:
		var entry: Dictionary = resaved_pa[port_id]
		if entry.keys().size() != 2 or not entry.has("ledger") \
				or not entry.has("allegiance"):
			shape_ok = false
	_check(shape_ok, "every re-saved port_allegiance entry is exactly {ledger, allegiance}")
	_check(not JSON.stringify(resaved).contains("development"),
		"the re-saved file never names the derived 'development' field")
	_check(resaved_pa.get("malacca") == {"ledger": {"england": 6000, "holland": 6000},
		"allegiance": "holland"},
		"the re-saved malacca entry keeps the tie-incumbent allegiance")
	_check(int((resaved["nation_treasuries"] as Dictionary).get("spain", -1)) == 2000,
		"the re-saved treasuries keep the 2,000g-cap literal")

	# …and the v8 file re-loads to the same state (second cycle).
	var first_cycle := _loaded_values()
	_clobber_state()
	_check(SaveSystem.load(1), "the re-saved v8 file loads")
	_check(_loaded_values() == first_cycle, "a second save/load cycle changes nothing")


# --- 2. The fixture really is the v8 §8.1 shape ----------------------------

func _test_fixture_shape() -> void:
	var fixture := _v8_payload()
	_check(int(fixture["save_version"]) == SaveSystem.SAVE_VERSION,
		"the fixture is save_version %d" % SaveSystem.SAVE_VERSION)
	_check(int(fixture["phase"]) == SaveSystem.PHASE,
		"the fixture is phase %d" % SaveSystem.PHASE)
	_check(SaveSystem.validate_payload(fixture).is_empty(),
		"validate_payload() accepts the fixture (%s)"
		% SaveSystem.validate_payload(fixture))
	_check(SaveSystem.SAVE_VERSION == 8 and SaveSystem.PHASE == 8,
		"this build ships save_version 8 / phase 8 (the explored-state amendment)")
	_check(SaveSystem.DEFAULT_MAP_ID == "world",
		"the shipped map id is 'world' (docs/90-* §9.1)")


# --- 3. No migration chain survives (docs/90-* §8.2 dev scope) -------------

func _test_no_migration_chain() -> void:
	_check(not ("MIGRATIONS" in SaveSystem),
		"SaveSystem carries no MIGRATIONS table any more (dev-stage scope)")
	for name in ["migrate_v1_to_v2", "migrate_v2_to_v3", "migrate_v3_to_v4",
			"migrate_v4_to_v5", "migrate_v5_to_v6", "migrate_v6_to_v7",
			"migrate_v7_to_v8"]:
		_check(not SaveSystem.has_method(name),
			"the historical migration step %s() is gone" % name)


# --- 4. Older (pre-release) versions are refused by name -------------------

func _test_older_versions_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	for version in [1, 2, 3, 4, 5, 6, 7]:
		var older := _v8_payload()
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


# --- 4b. A true v7-shaped payload is refused -------------------------------

## The §8.2 normative case (the explored-state amendment): a payload exactly
## as Phase 7 wrote it — no `explored_tiles` — refused with the standard
## pre-release message and `GameState` (and the allegiance statics) untouched.
func _test_v7_shape_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	_write_json(1, _v7_payload())
	_check(SaveSystem.load(1) == false,
		"a true v7-shaped payload fails to load (pre-release)")
	_check(SaveSystem.last_read_error.contains("pre-release")
		and SaveSystem.last_read_error.contains("7"),
		"the reason is the standard pre-release message (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after refusing the v7 payload (no silent fog reset)")
	_check(SaveSystem.read_save(1).is_empty(),
		"read_save() refuses the v7 payload too")
	_check(AllegianceLib.dump_state() == before["allegiance"],
		"the allegiance statics were not reseeded by the refused v7 file")


# --- 5. A future version is refused ---------------------------------------

func _test_future_version_refused() -> void:
	_load_fixture_into_memory()
	var before := _loaded_values()
	var future := _v8_payload()
	future["save_version"] = SaveSystem.SAVE_VERSION + 1
	future["phase"] = SaveSystem.PHASE + 1
	_write_json(1, future)
	_check(SaveSystem.load(1) == false, "a future save_version fails to load")
	_check(SaveSystem.last_read_error.contains("newer than"),
		"the reason names a newer version (got '%s')" % SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the future-version rejection")


# --- 6. A wrong-typed or out-of-shape field is rejected -------------------

## Type probes reuse the file's existing convention: a payload this build
## wrote, with one field replaced by a wrong-typed value → refused, reason
## names the key, state untouched. The Phase-7 additions extend both lists:
## wrong TYPES anywhere in the five allegiance keys, and the correction-8
## shape rule — a `port_allegiance` entry that is not exactly
## `{ledger, allegiance}` (a retired `development` key, a missing allegiance)
## is a rejection, not a silent repair (docs/30-* §4.9).
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
		{"key": "named_pirate_respawns", "value": [], "why":
			"named_pirate_respawns as an array"},
		# Phase-7 keys: wrong top-level types are rejections like any block.
		{"key": "permits", "value": [], "why": "permits as an array"},
		{"key": "port_allegiance", "value": [], "why": "port_allegiance as an array"},
		{"key": "month_invested", "value": [], "why": "month_invested as an array"},
		{"key": "nation_treasuries", "value": [], "why":
			"nation_treasuries as an array"},
		{"key": "fame_commended", "value": [], "why": "fame_commended as an array"},
		# The v8 explored key: wrong top-level types are rejections like any
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
		{"path": ["control_prefs", "input_mode"], "value": 3, "fragment":
			"control_prefs.input_mode", "why":
			"control_prefs.input_mode as a number"},
		{"path": ["control_prefs", "current_mode"], "value": "tidal", "fragment":
			"control_prefs.current_mode", "why":
			"an unknown control_prefs.current_mode id"},
		{"path": ["control_prefs", "current_mode"], "value": [], "fragment":
			"control_prefs.current_mode", "why":
			"control_prefs.current_mode as an array"},
		{"path": ["world", "sail_trim"], "value": "half", "fragment":
			"world.sail_trim", "why": "an unknown world.sail_trim state"},
		{"path": ["world", "sail_trim"], "value": 2, "fragment":
			"world.sail_trim", "why": "world.sail_trim as a number"},
		{"path": ["world", "heading"], "value": "NNE", "fragment":
			"world.heading", "why": "an off-domain world.heading id"},
		{"path": ["world", "heading"], "value": true, "fragment":
			"world.heading", "why": "world.heading as a boolean"},
		{"path": ["world", "wind_dir"], "value": 90, "fragment":
			"world.wind_dir", "why": "world.wind_dir as a number"},
		{"path": ["world", "wind_dir"], "value": "west", "fragment":
			"world.wind_dir", "why": "an off-domain world.wind_dir id"},
		# The carried Phase-5 hunter keys keep their v5 type checks.
		{"path": ["world", "last_departed_port"], "value": 5, "fragment":
			"last_departed_port", "why": "world.last_departed_port as a number"},
		{"path": ["world", "hunter_intel_cell"], "value": 5, "fragment":
			"hunter_intel_cell", "why": "world.hunter_intel_cell as a number"},
		# Phase-7 nested probes (docs/90-* §8.1 Phase-7 additions).
		{"path": ["permits", "home"], "value": "yes", "fragment":
			"permits.home", "why": "permits.home as a string"},
		{"path": ["permits", "home"], "value": 1, "fragment":
			"permits.home", "why": "permits.home as a number"},
		{"path": ["permits", "foreign"], "value": 3, "fragment":
			"permits.foreign", "why": "permits.foreign as a number"},
		{"path": ["permits", "foreign", "spain"], "value": "yes", "fragment":
			"permits.foreign.spain", "why": "a foreign permit flag as a string"},
		{"path": ["port_allegiance", "malacca"], "value": 5, "fragment":
			"port_allegiance.malacca", "why": "a port_allegiance entry as a number"},
		{"path": ["port_allegiance", "malacca", "ledger"], "value": [], "fragment":
			"port_allegiance.malacca.ledger", "why":
			"a port ledger as an array"},
		{"path": ["port_allegiance", "malacca", "ledger", "england"], "value": "6k",
			"fragment": "port_allegiance.malacca.ledger.england", "why":
			"a ledger entry as a string"},
		{"path": ["port_allegiance", "malacca", "allegiance"], "value": 7, "fragment":
			"port_allegiance.malacca.allegiance", "why":
			"a persisted allegiance as a number"},
		# Correction 8: the retired `development` key is a shape rejection.
		{"path": ["port_allegiance", "malacca", "development"], "value": 2, "fragment":
			"correction-8 shape", "why":
			"a port_allegiance entry carrying the retired 'development' key"},
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

	# The ledger-only entry shape (allegiance key missing) is the other
	# correction-8 rejection: the tie rule needs the persisted allegiance.
	var ledger_only: Dictionary = SaveSystem.snapshot()
	(ledger_only["port_allegiance"] as Dictionary)["malacca"] \
		.erase("allegiance")
	_write_json(1, ledger_only)
	_check(SaveSystem.load(1) == false,
		"a ledger-only port_allegiance entry (no allegiance) is rejected")
	_check(SaveSystem.last_read_error.contains("correction-8 shape"),
		"the reason names the correction-8 shape (got '%s')"
		% SaveSystem.last_read_error)
	_check(_loaded_values() == before,
		"state untouched after the ledger-only rejection")

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


# --- 6b. The explored_tiles encoding itself (docs/90-* §8.1 version 8) -----

## The test-side twin of the §8.1 v8 encoding: hand-built
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

	# Canonical form: same-row neighbours merge into ONE run, so two tiles
	# encode to exactly one 6-byte record (8 base64 chars), and the encoding
	# is deterministic.
	var pair := SaveSystem._encode_explored({
		Vector2i(10, 5): true, Vector2i(11, 5): true,
	})
	_check(pair == SaveSystem._encode_explored({
		Vector2i(11, 5): true, Vector2i(10, 5): true,
	}), "the encoding is key-order independent")
	_check(pair == _encode_runs([[5, 10, 2]]),
		"touching same-row tiles merge into one canonical run")
	_check(pair.length() == 8,
		"one merged run is exactly one 6-byte record (8 base64 chars)")

	# The fixture cross-proof: the encoder produces exactly the string the v8
	# fixture hand-writes for the same set (rows 0 / 615 / 1002).
	var fixture_set := {
		Vector2i(4319, 0): true,
		Vector2i(2050, 615): true, Vector2i(2051, 615): true,
		Vector2i(2213, 1002): true,
	}
	_check(SaveSystem._encode_explored(fixture_set) == _v8_payload()["explored_tiles"],
		"the encoder reproduces the fixture's hand-written explored_tiles")

	# Decode identity: the decoded set is exactly the encoded one (value
	# equality across seam-adjacent rows; the fresh-dictionary property is
	# load-path behavior asserted by the round trip's clobber cycle).
	var decoded: Dictionary = SaveSystem._decode_explored(
		SaveSystem._encode_explored(fixture_set))
	_check(decoded == fixture_set,
		"decode(encode(set)) == set across seam-adjacent rows")
	var seam_decode: Dictionary = SaveSystem._decode_explored(
		SaveSystem._encode_explored({
			Vector2i(0, 2159): true, Vector2i(4319, 2159): true,
		}))
	_check(seam_decode.has(Vector2i(0, 2159))
		and seam_decode.has(Vector2i(4319, 2159)),
		"the grid edges (y = 2159, x = 4319) survive the codec")

	# Refusals: every non-canonical or out-of-domain encoding is named.
	_check(SaveSystem._explored_error(5).contains("not a string"),
		"a number is refused with the key named")
	_check(SaveSystem._explored_error("!!!").contains("base64"),
		"a non-base64 string is refused")
	_check(SaveSystem._explored_error("ABC").contains("base64"),
		"a length-3 string is refused (base64 is a multiple of 4)")
	_check(SaveSystem._explored_error("A===BC==").contains("base64"),
		"padding not in the tail is refused")
	_check(SaveSystem._explored_error(
		Marshalls.raw_to_base64(PackedByteArray([0, 0, 0, 0, 0])))
		.contains("multiple of 6"), "a non-multiple of the run record is refused")
	_check(SaveSystem._explored_error(_encode_runs([[2160, 0, 1]]))
		.contains("outside"), "a run on y = 2160 is refused (grid is 2160 tall)")
	_check(SaveSystem._explored_error(_encode_runs([[0, 4319, 2]]))
		.contains("outside"), "a run crossing x = 4320 is refused")
	_check(SaveSystem._explored_error(
		_encode_runs([[5, 100, 1], [4, 100, 1]])).contains("sorted"),
		"row-descending runs are refused")
	_check(SaveSystem._explored_error(
		_encode_runs([[5, 10, 2], [5, 12, 2]])).contains("sorted"),
		"touching same-row runs are refused (the canonical form merges them)")
	_check(SaveSystem._explored_error(
		_encode_runs([[5, 10, 3], [5, 12, 1]])).contains("sorted"),
		"overlapping same-row runs are refused")
	_check(SaveSystem._explored_error(_encode_runs([[5, 100, 1], [5, 102, 1]])
		).is_empty(), "two disjoint runs on one row are valid")
	_check(SaveSystem._explored_error(
		_encode_runs([[5, 100, 1], [6, 0, 1]])).is_empty(),
		"adjacent rows are valid (only same-row runs must not touch)")

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
## Phase 7: an absent allegiance quintet restores the **seeded** new-game
## state (`Allegiance.restore_state` seeds first): contestable sovereigns
## `{owner: 6,000}`, neutrals empty, treasuries 5,000g, no permits, no
## commendations, no spent allowance.
func _test_optional_keys_default() -> void:
	_load_fixture_into_memory()
	var payload := _v8_payload()
	for key in ["npc_fleets", "proximity_cooldowns", "market_stocks",
			"wrecks", "npc_preset", "control_prefs",
			"market_events", "named_pirate_respawns", "fame", "titles",
			"bounties", "active_quests", "completed_royal_missions",
			"discoveries_reported", "discovery_hints", "battles_won",
			"retired", "retired_at", "discoveries_found", "explored_tiles"]:
		payload.erase(key)
	for key in V7_ALLEGIANCE_KEYS:
		payload.erase(key)
	var world: Dictionary = payload["world"]
	for key in WORLD_DEFAULTS:
		world.erase(key)
	_write_json(1, payload)
	_clobber_state()
	_check(SaveSystem.load(1),
		"a payload omitting the optional keys (incl. every Phase-7 key) loads")
	_check(GameState.control_prefs == {"input_mode": "step", "current_mode": "modifier"}
		and GameState.control_prefs is Dictionary,
		"an absent control_prefs defaults to Step + Modifier (got %s)"
		% str(GameState.control_prefs))
	_check(GameState.world["sail_trim"] == "normal",
		"an absent world.sail_trim defaults to 'normal'")
	_check(GameState.world["heading"] == "E",
		"an absent world.heading defaults to 'E'")
	_check(GameState.world["wind_dir"] == "E",
		"an absent world.wind_dir defaults to 'E'")
	_check(GameState.npc_fleets == [] and GameState.npc_fleets is Array,
		"an absent npc_fleets defaults to []")
	_check(GameState.proximity_cooldowns == {}
		and GameState.proximity_cooldowns is Dictionary,
		"an absent proximity_cooldowns defaults to {}")
	# `market_stocks`' documented default is the DERIVED initial stock
	# (docs/30-* §4.2 flow economy, no RNG) — computed at load, not a literal.
	_check(GameState.market_stocks.size() == DataLoader.ports_list.size(),
		"an absent market_stocks defaults to the derived initial stock "
		+ "(all %d ports)" % GameState.market_stocks.size())
	_check(int(GameState.market_stocks["lisbon"]["wine"]) == 200,
		"the derived default stocks lisbon wine at its capacity 200 "
		+ "(staple 160 + dev 3, ceiling 200; got %d)"
		% int(GameState.market_stocks["lisbon"]["wine"]))
	_check(int(GameState.market_stocks["london"]["wine"]) == 60,
		"the derived default stocks london wine at the consumer seed 60 "
		+ "(got %d)" % int(GameState.market_stocks["london"]["wine"]))
	_check(GameState.wrecks == [] and GameState.wrecks is Array,
		"an absent wrecks defaults to []")
	_check(GameState.npc_preset == "normal",
		"an absent npc_preset defaults to 'normal' (got '%s')"
		% GameState.npc_preset)
	_check(GameState.market_events == [] and GameState.market_events is Array,
		"an absent market_events defaults to []")
	_check(GameState.named_pirate_respawns == {}
			and GameState.named_pirate_respawns is Dictionary,
		"an absent named_pirate_respawns defaults to {}")
	_check(GameState.fame == 0, "an absent fame defaults to 0")
	_check(GameState.titles == {}, "an absent titles defaults to {}")
	_check(GameState.bounties == {}, "an absent bounties defaults to {}")
	_check(GameState.active_quests == [], "an absent active_quests defaults to []")
	_check(GameState.completed_royal_missions == {},
		"an absent completed_royal_missions defaults to {}")
	_check(GameState.discoveries_reported == [],
		"an absent discoveries_reported defaults to []")
	_check(GameState.discovery_hints == {}, "an absent discovery_hints defaults to {}")
	_check(GameState.battles_won == 0, "an absent battles_won defaults to 0")
	_check(GameState.retired == false and GameState.retired_at == 0,
		"absent retired/retired_at default to false/0")
	_check(GameState.discoveries_found == [],
		"an absent discoveries_found defaults to []")
	# The v8 explored key defaults to the EMPTY SET (docs/90-* §8.1 version 8:
	# "" → nothing explored).
	_check(GameState.explored_tiles.is_empty()
		and GameState.explored_tiles is Dictionary,
		"an absent explored_tiles defaults to the empty set")
	# The Phase-7 quintet defaults to the SEEDED state (docs/90-* §8.1:
	# "{}` — then Allegiance.seed_new_game() reseeds").
	var dump: Dictionary = AllegianceLib.dump_state()
	_check(dump["permits"] == {"home": false, "foreign": {}},
		"absent permits default to the seeded none (got %s)" % str(dump.get("permits")))
	_check((dump["port_allegiance"] as Dictionary).size() == _contestable_count(),
		"absent port_allegiance defaults to the full seeded map (%d contestable)"
		% _contestable_count())
	_check((dump["port_allegiance"] as Dictionary).get("madeira")
		== {"ledger": {"portugal": 6000}, "allegiance": "portugal"},
		"absent port_allegiance seeds the contestable sovereign {owner: 6,000} "
		+ "(madeira, got %s)"
		% str((dump["port_allegiance"] as Dictionary).get("madeira")))
	_check((dump["port_allegiance"] as Dictionary).get("quanzhou")
		== {"ledger": {}, "allegiance": ""},
		"absent port_allegiance seeds the neutral empty (quanzhou)")
	_check(not (dump["port_allegiance"] as Dictionary).has("lisbon"),
		"the seeded map never carries a protected port (lisbon)")
	var treasuries: Dictionary = dump["nation_treasuries"]
	var treasuries_ok := treasuries.size() == NATION_IDS.size()
	for nation_id in NATION_IDS:
		treasuries_ok = treasuries_ok and int(treasuries.get(nation_id, -1)) == 5000
	_check(treasuries_ok,
		"absent nation_treasuries default to the seeded 5,000g each (got %s)"
		% str(treasuries))
	_check(dump["month_invested"] == {},
		"an absent month_invested defaults to the seeded empty")
	_check(dump["fame_commended"] == {},
		"an absent fame_commended defaults to the seeded empty")
	_check(GameState.day == 64 and GameState.gold == 12540,
		"the required fields still restore around the defaults")


# --- 7b. The Phase-7 blocks are real saved state --------------------------

func _test_new_fields_round_trip() -> void:
	_load_fixture_into_memory()
	GameState.fame = 480
	GameState.titles = {
		"portugal": "baron", "spain": "none", "england": "knight",
		"holland": "none", "ottoman": "none", "italy": "none",
	}
	GameState.bounties = {"spain": {"amount": 2350, "day": 66}}
	GameState.active_quests = [{
		"instance_id": "q_lisbon_9_0",
		"template_id": "qt_delivery_timber",
		"type": "delivery",
		"giver": "guild",
		"origin_port_id": "lisbon",
		"requirements": {"good_id": "timber", "quantity": 40,
			"dest_port_id": "tunis"},
		"rewards": {"gold": 1200, "reputation": {"ottoman": 5}, "fame": 10},
		"expiry_days": 20,
		"accepted_day": 64,
		"deadline_day": 84,
		"status": "active",
	}]
	GameState.completed_royal_missions = {
		"portugal": 2, "spain": 0, "england": 0,
		"holland": 0, "ottoman": 0, "italy": 0,
	}
	GameState.discoveries_reported = ["disc_atlas_cedars", "disc_red_sea_corals"]
	GameState.discovery_hints = {"disc_atlas_cedars": true}
	GameState.battles_won = 7
	GameState.market_stocks = {}
	var stocks := EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	stocks["lisbon"]["wine"] = 12
	stocks["seville"]["olive_oil"] = 200
	GameState.market_stocks = stocks
	GameState.wrecks = [{
		"id": "wreck_64_100_200", "position": {"x": 100, "y": 200},
		"day": 64, "cargo": {"raw_silk": 12},
	}]
	GameState.npc_preset = "extreme"
	GameState.market_events = [{
		"template_id": "ev_war_provisioning", "port_id": "seville",
		"start_day": 64, "end_day": 124,
	}]
	# Task L (docs/60-* §4.11.11.4, docs/90-* §8.1): the respawn map is a
	# bare `{named_pirate_id: available_day}` object, saved as of v5.
	GameState.named_pirate_respawns = {
		"pirate_redbeard_khair": 94,
		"successor_2": 70,
	}
	# Phase-6 (docs/90-* §8.1): control preferences and the world ocean keys
	# at non-default values, plus the carried hunter keys.
	GameState.control_prefs = {"input_mode": "helm", "current_mode": "drift"}
	GameState.world["sail_trim"] = "furled"
	GameState.world["heading"] = "SW"
	GameState.world["wind_dir"] = "NE"
	GameState.world["last_departed_port"] = "seville"
	GameState.world["hunter_intel_cell"] = {"x": 1900, "y": 860}
	# v8 explored-state amendment (docs/90-* §8.1 version 8): a non-default
	# explored set rides the same round trip (edges and a two-tile run).
	GameState.explored_tiles = {
		Vector2i(2050, 615): true, Vector2i(2051, 615): true,
		Vector2i(4319, 0): true, Vector2i(0, 2159): true,
	}
	# The §4.15 fleet shape (docs/10-* §4.15): the pirate's saved fields are
	# exactly the pinned set plus the task-owned extensions.
	GameState.npc_fleets = [{
		"id": "nf_7_0000_pirate",
		"role": "pirate",
		"nation_id": "",
		"cell": {"x": 30, "y": 40},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": "", "name_index": 0},
		"cooldown_until_day": 0,
		"seed": 7 * 1000003 + 30 * 7919 + 40 * 104729,
		"dest_port_id": "",
		"dwell_until_day": 0,
		"anchor_cell": null,
		"target_fleet_id": "",
		"hunter_state": "",
		"loiter_until_day": 0,
		"home_port_id": "",
	}]
	GameState.proximity_cooldowns = {"pirate": 12}
	# Phase-7 (docs/90-* §8.1): drive the allegiance runtime APIs — the state
	# the five keys persist — from the fixture's loaded values.
	AllegianceLib.set_permit("home", "")
	AllegianceLib.set_permit("foreign", "ottoman")
	AllegianceLib.add_investment("malacca", "england", 3000)
	AllegianceLib.player_invest_chunk("malacca")
	AllegianceLib.credit_permit_sale("spain", 20000)
	AllegianceLib.credit_tax("malacca", "england", 700)
	var expected := _loaded_values()

	_check(SaveSystem.save(1), "a run with Phase-2/3/5/6/7/8 state saves")
	var on_disk := _read_json(1)
	_check(int(on_disk.get("fame", -1)) == 480, "snapshot() writes fame")
	_check(on_disk.get("explored_tiles") == SaveSystem._encode_explored({
		Vector2i(2050, 615): true, Vector2i(2051, 615): true,
		Vector2i(4319, 0): true, Vector2i(0, 2159): true,
		}), "snapshot() writes explored_tiles in the canonical encoding")
	_check((on_disk.get("titles") as Dictionary).get("portugal") == "baron",
		"snapshot() writes titles")
	_check(((on_disk.get("bounties") as Dictionary).get("spain") as Dictionary)
		.get("amount") == 2350, "snapshot() writes the bounty amount")
	_check((on_disk.get("active_quests") as Array).size() == 1,
		"snapshot() writes active_quests")
	_check((on_disk.get("discoveries_reported") as Array).size() == 2,
		"snapshot() writes discoveries_reported")
	_check((on_disk.get("discovery_hints") as Dictionary).has("disc_atlas_cedars"),
		"snapshot() writes discovery_hints")
	_check(int(on_disk.get("battles_won", -1)) == 7, "snapshot() writes battles_won")
	_check((on_disk.get("npc_fleets") as Array).size() == 1
		and (on_disk["npc_fleets"] as Array)[0]["id"] == "nf_7_0000_pirate",
		"snapshot() writes the fleet (docs/90-* §8.1)")
	_check(on_disk.get("proximity_cooldowns") == {"pirate": 12},
		"snapshot() writes proximity_cooldowns")
	_check((on_disk.get("market_stocks") as Dictionary)["lisbon"]["wine"] == 12,
		"snapshot() writes market_stocks")
	_check((on_disk.get("wrecks") as Array).size() == 1,
		"snapshot() writes wrecks")
	_check(str(on_disk.get("npc_preset")) == "extreme",
		"snapshot() writes npc_preset")
	_check((on_disk.get("market_events") as Array).size() == 1,
		"snapshot() writes market_events")
	_check((on_disk.get("named_pirate_respawns") as Dictionary)
		.get("pirate_redbeard_khair") == 94,
		"snapshot() writes named_pirate_respawns")
	_check(on_disk.get("control_prefs") == {"input_mode": "helm",
		"current_mode": "drift"}, "snapshot() writes control_prefs")
	var on_disk_world: Dictionary = on_disk["world"]
	_check(str(on_disk_world.get("sail_trim")) == "furled",
		"snapshot() writes world.sail_trim")
	_check(str(on_disk_world.get("heading")) == "SW",
		"snapshot() writes world.heading")
	_check(str(on_disk_world.get("wind_dir")) == "NE",
		"snapshot() writes world.wind_dir")
	_check(str(on_disk_world.get("last_departed_port")) == "seville",
		"snapshot() writes world.last_departed_port")
	_check(on_disk_world.get("hunter_intel_cell") == {"x": 1900, "y": 860},
		"snapshot() writes world.hunter_intel_cell")
	# Phase-7 keys: snapshot() writes the live allegiance state verbatim.
	_check(on_disk.get("permits") == {"home": true,
		"foreign": {"spain": true, "holland": true, "ottoman": true}},
		"snapshot() writes permits (home + the grown foreign map)")
	var disk_pa: Dictionary = on_disk["port_allegiance"]
	_check((disk_pa.get("malacca") as Dictionary).get("ledger")
		== {"england": 9000, "holland": 6000, "portugal": 500},
		"snapshot() writes the grown malacca ledger (england +3,000, "
		+ "player chunk +500)")
	_check(str((disk_pa.get("malacca") as Dictionary).get("allegiance")) == "england",
		"snapshot() writes the re-resolved allegiance (england 9,000 > holland 6,000)")
	_check((on_disk["month_invested"] as Dictionary).get("madeira") == 1500
		and (on_disk["month_invested"] as Dictionary).get("malacca") == 500,
		"snapshot() writes month_invested (fixture counter + the new chunk)")
	_check((on_disk["nation_treasuries"] as Dictionary).get("spain") == 22000
		and (on_disk["nation_treasuries"] as Dictionary).get("england") == 700,
		"snapshot() writes nation_treasuries (permit sale + the capped tax credit)")
	_check((on_disk["fame_commended"] as Dictionary).get("madeira") == true,
		"snapshot() writes fame_commended")

	_clobber_state()
	_check(SaveSystem.load(1), "the v8 file with Phase-2/3/5/6/7/8 state loads")
	_check(_loaded_values() == expected,
		"every Phase-2/3/5/6/7/8 field restores byte-equal after a v8 round trip")
	_check(typeof(GameState.market_stocks["lisbon"]["wine"]) == TYPE_INT,
		"stock counts come back as ints, not json floats")
	_check(typeof(GameState.wrecks[0]["position"]["x"]) == TYPE_INT,
		"wreck coordinates come back as ints, not json floats")
	_check(typeof(((GameState.bounties["spain"] as Dictionary)["amount"])) == TYPE_INT,
		"the bounty amount comes back as an int, not a json float")
	_check(typeof((GameState.npc_fleets[0] as Dictionary)["cell"]["x"])
		== TYPE_INT, "fleet coordinates come back as ints, not json floats")
	_check(typeof(GameState.world["hunter_intel_cell"]["x"]) == TYPE_INT,
		"the hunter intel cell comes back with int coordinates")
	_check(typeof((AllegianceLib.dump_state()["month_invested"]
		as Dictionary)["malacca"]) == TYPE_INT,
		"the month_invested counter comes back as an int, not a json float")
	_check(typeof((AllegianceLib.dump_state()["nation_treasuries"]
		as Dictionary)["spain"]) == TYPE_INT,
		"treasury gold comes back as an int, not a json float")

	# The snapshot deep-copies: mutating live state cannot rewrite a save.
	var snap := SaveSystem.snapshot()
	GameState.titles["portugal"] = "duke"
	GameState.active_quests[0]["status"] = "failed"
	GameState.discoveries_reported.append("disc_mutated")
	GameState.npc_fleets[0]["id"] = "mutated"
	GameState.proximity_cooldowns["pirate"] = 999
	GameState.market_stocks["lisbon"]["wine"] = 999
	GameState.wrecks[0]["id"] = "mutated"
	GameState.npc_preset = "mutated"
	GameState.market_events[0]["template_id"] = "mutated"
	GameState.named_pirate_respawns["pirate_redbeard_khair"] = 999
	GameState.control_prefs["input_mode"] = "mutated"
	GameState.world["sail_trim"] = "mutated"
	GameState.world["hunter_intel_cell"]["x"] = 999
	GameState.explored_tiles[Vector2i(9, 9)] = true
	var explored_before: String = snap["explored_tiles"]
	AllegianceLib.set_permit("foreign", "italy")
	AllegianceLib.add_investment("malacca", "holland", 12000)
	AllegianceLib.credit_permit_sale("italy", 999999)
	_check((snap["titles"] as Dictionary)["portugal"] == "baron",
		"snapshot() deep-copies titles")
	_check(((snap["active_quests"] as Array)[0] as Dictionary)["status"] == "active",
		"snapshot() deep-copies active_quests")
	_check((snap["discoveries_reported"] as Array).size() == 2,
		"snapshot() deep-copies discoveries_reported")
	_check((snap["npc_fleets"] as Array)[0]["id"] == "nf_7_0000_pirate",
		"snapshot() deep-copies npc_fleets")
	_check(snap["proximity_cooldowns"] == {"pirate": 12},
		"snapshot() deep-copies proximity_cooldowns")
	_check((snap["market_stocks"] as Dictionary)["lisbon"]["wine"] == 12,
		"snapshot() deep-copies market_stocks")
	_check((snap["wrecks"] as Array)[0]["id"] == "wreck_64_100_200",
		"snapshot() deep-copies wrecks")
	_check(snap["npc_preset"] == "extreme", "snapshot() copies npc_preset")
	_check((snap["market_events"] as Array)[0]["template_id"]
		== "ev_war_provisioning", "snapshot() deep-copies market_events")
	_check(int((snap["named_pirate_respawns"] as Dictionary)
		.get("pirate_redbeard_khair", -1)) == 94,
		"snapshot() deep-copies named_pirate_respawns")
	_check((snap["control_prefs"] as Dictionary)["input_mode"] == "helm",
		"snapshot() deep-copies control_prefs")
	_check((snap["world"] as Dictionary)["sail_trim"] == "furled",
		"snapshot() deep-copies the world block")
	_check(((snap["world"] as Dictionary)["hunter_intel_cell"]
		as Dictionary)["x"] == 1900, "snapshot() deep-copies the intel cell")
	_check(snap["explored_tiles"] == explored_before
		and not explored_before.is_empty(),
		"snapshot() deep-copies the explored set")
	_check(not ((snap["permits"] as Dictionary)["foreign"]
		as Dictionary).has("italy"),
		"snapshot() deep-copies permits")
	_check(((snap["port_allegiance"] as Dictionary)["malacca"]
		as Dictionary)["ledger"] == {"england": 9000, "holland": 6000,
		"portugal": 500},
		"snapshot() deep-copies port_allegiance ledgers")
	_check(int((snap["nation_treasuries"] as Dictionary).get("italy", -1)) == 5000,
		"snapshot() deep-copies nation_treasuries")


# --- 7c. The session-only debug flag never enters a payload ---------------

## docs/80-* §4.6.3 / §4.6 symbol contract: `SettingsPanel.debug_overlays` is
## a static, session-only flag — never saved, never read from a save. Asserted
## on the serialized dict AND the file bytes; and a load must leave the flag
## exactly as the session set it.
func _test_debug_overlays_never_saved() -> void:
	_load_fixture_into_memory()
	SettingsPanelLib.debug_overlays = true
	_check(SettingsPanelLib.debug_overlays,
		"setup: the session-only debug flag is on")
	var snap := SaveSystem.snapshot()
	_check(not snap.has("debug_overlays"),
		"snapshot() carries no top-level debug_overlays")
	_check(not (snap["world"] as Dictionary).has("debug_overlays"),
		"the world block carries no debug_overlays")
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
	SettingsPanelLib.debug_overlays = true
	_clobber_state()
	_check(SaveSystem.load(1), "the payload loads again")
	_check(SettingsPanelLib.debug_overlays == true,
		"loading never resets the session-only flag (still on)")
	SettingsPanelLib.debug_overlays = false


# --- 8. A retired save is never playable ----------------------------------

func _test_retired_save() -> void:
	_load_fixture_into_memory()
	GameState.fame = 3100
	GameState.titles["portugal"] = "duke"
	GameState.completed_royal_missions["portugal"] = 8
	GameState.discoveries_reported = ["disc_atlas_cedars"]
	GameState.battles_won = 12
	GameState.retired = true
	GameState.retired_at = 1793120000
	_check(SaveSystem.save(1), "a retired run saves")
	var on_disk := _read_json(1)
	_check(bool(on_disk.get("retired", false)) is bool and on_disk["retired"] == true,
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
	_check(int(summary.get("discoveries", -1)) == 1,
		"the summary counts reported discoveries")
	_check(int(summary.get("battles", -1)) == 12, "the summary carries battles won")
	_check((summary.get("titles") as Array) == [["portugal", "duke"]],
		"the summary lists every non-none title (got %s)" % str(summary.get("titles")))

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
	_check(GameState.day == 64 and GameState.player.is_empty() == false,
		"a playable load restores state again")


# --- 9. Mid-month AI replay purity (the Phase-7 proof) ---------------------
#
# docs/90-* §8.2 / docs/30-* §4.9: a save/load mid-month replays the month's
# counter-investment identically — the persisted ledger/allegiance state is
# the AI's only input, so `restore_state` re-deriving the transient trackers
# must leave the month tick a pure function of the payload. Two full
# re-creations of the same timeline: one saves at day 17 and loads back
# before month-tick 2, the other never touches a slot. L's determinism
# fixture pattern (test_allegiance.gd), extended across a save/load boundary.

## A lean but fully saveable run (player/fleet/world/stocks) with a clean
## allegiance seed, standing at `day`.
func _make_replay_run(day: int) -> void:
	var reputation: Dictionary = {}
	for nation_id in NATION_IDS:
		reputation[nation_id] = 0
	GameState.locale = "en"
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": reputation,
	}
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
## when `save_mid_month`) → month-tick 2 (day 31). Returns everything the
## purity claim covers: the telegraph sequence, the full allegiance dump and
## the player-facing ledgers the flip hooks write.
func _replay_branch(save_mid_month: bool) -> Dictionary:
	_make_replay_run(1)
	AllegianceLib.month_tick()
	GameState.day = 17
	var mid_state: Dictionary = AllegianceLib.dump_state()
	if save_mid_month:
		_check(SaveSystem.save(1), "the day-17 state saves mid-month")
		_clobber_state()
		_check(SaveSystem.load(1), "the day-17 state loads back")
		_check(AllegianceLib.dump_state() == mid_state,
			"the day-17 round trip restores the allegiance state byte-equal")
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
		"fame_commended": (AllegianceLib.dump_state()["fame_commended"]
			as Dictionary).duplicate(true),
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
	var window_ok := true
	for row in AllegianceLib.last_month_investments():
		if int(row.get("day", -1)) != 31:
			window_ok = false
	_check(window_ok,
		"the telegraph window holds only month-2 rows in both branches "
		+ "(the day-1 rows aged out identically)")
	print("REPLAY PROOF month 31: ", saved_rows)


# --- 10. The extreme-save budget -------------------------------------------

## docs/90-* completion gate: save ≤ 2 MB @ extreme. The honest extreme
## world, measured the way `test_density` measures it (on the exact
## slot-write bytes of a REAL payload): the extreme density preset seeds the
## fleet ecology through `new_game`'s initial fill, a 90-day trickle window
## grows it toward the 288 cap, the full derived stock table rides along
## (145 ports × the listed goods), and the allegiance state is a
## late-campaign world — every contestable port carrying a six-nation
## ledger, a player sweep flipping the contestables, the monthly allowance
## spent at 40 ports, every foreign permit held. Measured size printed for
## the task report.
func _test_extreme_save_size() -> void:
	GameState.npc_preset = "extreme"
	GameState.new_game("portugal", false)
	var sim := NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "extreme",
	})
	for offset in range(90):
		GameState.day = 200 + offset
		sim.tick(GameState.day)
	# A late-campaign allegiance world on top of the populated ecology.
	var flipped := 0
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty() or AllegianceLib.is_protected(port_id):
			continue
		for nation_id in NATION_IDS:
			AllegianceLib.add_investment(port_id, nation_id, 2500)
		AllegianceLib.add_investment(port_id, "portugal", 6000)
		flipped += 1
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
	print("PROFILE save_v8_extreme_bytes %d" % payload_bytes)
	_check(payload_bytes <= EXTREME_SAVE_BUDGET,
		"the extreme save stays within the 2 MB budget (%d bytes)" % payload_bytes)
	_check((payload["npc_fleets"] as Array).size() >= 100,
		"the extreme fixture carries a populated fleet ecology (%d fleets)"
		% (payload["npc_fleets"] as Array).size())
	_check((payload["port_allegiance"] as Dictionary).size() == _contestable_count(),
		"the extreme fixture serializes every contestable port (%d)"
		% _contestable_count())
	_check((payload["market_stocks"] as Dictionary).size() == DataLoader.ports_list.size(),
		"the extreme fixture carries the full stock table (%d ports)"
		% (payload["market_stocks"] as Dictionary).size())


# --- 11. The S19 rows flip GameState live; new_game carries the choice -----

## docs/80-* §4.6.3 (task V): the input-mode and current-mode rows write
## `GameState.control_prefs` LIVE on both mounts; the debug row writes ONLY
## the session-only static. A pre-game S1 choice is carried into the run by
## `new_game` exactly like `npc_preset` (out-of-domain values fall back to
## the pinned defaults), and the fresh run seeds the allegiance quintet
## through `Allegiance.seed_new_game()` (docs/30-* §4.9). Labels are NOT
## asserted: the ui_strings keys are orchestrator-merged and render as
## `<key>` placeholders until then.
func _test_s19_rows_and_new_game_carry() -> void:
	_ensure_dir()
	GameState.control_prefs = {"input_mode": "step", "current_mode": "modifier"}
	var prefs_signals: Array = []
	var debug_signals: Array = []
	var panel: Control = SettingsScene.instantiate()
	add_child(panel)
	await get_tree().process_frame
	panel.control_prefs_changed.connect(
		func(key: String, value: String) -> void:
			prefs_signals.append([key, value]))
	panel.debug_overlays_changed.connect(
		func(on: bool) -> void: debug_signals.append(on))

	# The setters write GameState live.
	_check(panel.apply_input_mode("helm"), "the input-mode setter applies 'helm'")
	_check(str(GameState.control_prefs.get("input_mode")) == "helm",
		"the input-mode row flipped GameState.control_prefs.input_mode live")
	_check(panel.apply_current_mode("drift"),
		"the current-mode setter applies 'drift'")
	_check(str(GameState.control_prefs.get("current_mode")) == "drift",
		"the current-mode row flipped GameState.control_prefs.current_mode live")
	_check(prefs_signals == [["input_mode", "helm"], ["current_mode", "drift"]],
		"control_prefs_changed fired for both rows (got %s)" % str(prefs_signals))
	# Selection styling follows the applied state (the density-row pattern).
	var helm_button: Button = panel.input_mode_button("helm")
	var step_button: Button = panel.input_mode_button("step")
	_check(helm_button != null and step_button != null,
		"the input-mode row renders both buttons")
	_check(helm_button.button_pressed and not step_button.button_pressed,
		"the applied input mode is the pressed button")
	_check(panel.current_mode_button("drift").button_pressed
		and not panel.current_mode_button("modifier").button_pressed,
		"the applied current mode is the pressed button")

	# The buttons drive the same writers (the density-row test pattern).
	step_button.emit_signal("pressed")
	_check(str(GameState.control_prefs.get("input_mode")) == "step",
		"pressing the Step button flips input_mode back live")
	panel.current_mode_button("modifier").emit_signal("pressed")
	_check(str(GameState.control_prefs.get("current_mode")) == "modifier",
		"pressing the Modifier button flips current_mode back live")

	# Unknown ids are refused (the current mode stands).
	_check(not panel.apply_input_mode("joystick"),
		"an unknown input mode is refused")
	_check(not panel.apply_current_mode("tidal"),
		"an unknown current mode is refused")
	_check(GameState.control_prefs == {"input_mode": "step", "current_mode": "modifier"},
		"the refused ids left control_prefs untouched")

	# The debug row writes ONLY the session-only static.
	panel.apply_debug_overlays(true)
	_check(SettingsPanelLib.debug_overlays,
		"the debug row flips SettingsPanel.debug_overlays")
	_check(not GameState.control_prefs.has("debug_overlays"),
		"the debug flag never enters GameState.control_prefs")
	_check(not JSON.stringify(SaveSystem.snapshot()).contains("debug_overlays"),
		"the debug flag never enters a snapshot")
	var debug_button: Button = panel.debug_overlays_button()
	_check(debug_button != null and debug_button.button_pressed,
		"the debug button reflects the on state")
	debug_button.emit_signal("pressed")
	_check(not SettingsPanelLib.debug_overlays,
		"pressing the debug button flips the static back off (session-only)")
	_check(debug_signals == [true, false],
		"debug_overlays_changed fired for both flips (got %s)" % str(debug_signals))
	panel.queue_free()
	await get_tree().process_frame

	# Pre-game carry (docs/80-* §4.6.3): the S1 mount writes the field BEFORE
	# new_game; the fresh-run reset preserves it as run input — and seeds the
	# allegiance quintet (task V's new_game wiring, docs/30-* §4.9).
	GameState.control_prefs = {"input_mode": "helm", "current_mode": "drift"}
	GameState.new_game("portugal", false)
	_check(GameState.control_prefs == {"input_mode": "helm", "current_mode": "drift"},
		"new_game carries the pre-game control_prefs (helm + drift, got %s)"
		% str(GameState.control_prefs))
	_check(GameState.world["sail_trim"] == "normal" and GameState.world["heading"] == "E"
		and GameState.world["wind_dir"] == "E",
		"new_game starts the world ocean keys at the pinned defaults")
	var seeded: Dictionary = AllegianceLib.dump_state()
	_check((seeded["port_allegiance"] as Dictionary).get("madeira")
		== {"ledger": {"portugal": 6000}, "allegiance": "portugal"},
		"new_game seeds the contestable sovereign {owner: 6,000} (madeira)")
	_check((seeded["port_allegiance"] as Dictionary).get("quanzhou")
		== {"ledger": {}, "allegiance": ""},
		"new_game seeds the neutral empty (quanzhou)")
	_check(int((seeded["nation_treasuries"] as Dictionary).get("portugal", -1)) == 5000
		and (seeded["nation_treasuries"] as Dictionary).size() == NATION_IDS.size(),
		"new_game seeds every treasury at 5,000g")
	_check(seeded["permits"] == {"home": false, "foreign": {}},
		"new_game resets the permits (got %s)" % str(seeded.get("permits")))
	_check(seeded["fame_commended"] == {} and seeded["month_invested"] == {},
		"new_game resets the commendation flags and the monthly allowance")
	_check(AllegianceLib.last_month_investments().is_empty(),
		"new_game starts with no investment telegraphs")
	# An out-of-domain pre-game value (never written by the panel) falls back.
	GameState.control_prefs = {"input_mode": "bogus", "current_mode": "sideways"}
	GameState.new_game("portugal", false)
	_check(GameState.control_prefs == {"input_mode": "step", "current_mode": "modifier"},
		"new_game repairs an out-of-domain carry to the defaults (got %s)"
		% str(GameState.control_prefs))
	GameState.control_prefs = {"input_mode": "step", "current_mode": "modifier"}


# --- Helpers --------------------------------------------------------------
# (the Phase-5/6 pair, extended with the allegiance dump so the "state
# untouched" comparisons cover the runtime statics too)

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


## Wipes every GameState field with values that cannot be confused with the
## fixture, so a load that silently did nothing is visible. The Phase-6 keys
## are clobbered with out-of-domain sentinels and the allegiance statics are
## reseeded to a **sentinel state** (a home permit, a `clobber` nation
## everywhere) — a load that skipped the restore seam would leave those
## sentinels in `_loaded_values()` and fail the comparison.
func _clobber_state() -> void:
	GameState.locale = "zh"
	GameState.day = 1
	GameState.gold = 1
	GameState.morale = 99
	GameState.current_port = null
	GameState.player = {
		"nation_id": "spain", "stats": {}, "xp": 0, "level": 1,
		"officers": [], "reputation": {},
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
	GameState.named_pirate_respawns = {"clobber": -1}
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
## the GameState fields plus the allegiance quintet through the runtime
## owner's dump.
func _loaded_values() -> Dictionary:
	return {
		"locale": GameState.locale,
		"day": GameState.day,
		"gold": GameState.gold,
		"morale": GameState.morale,
		"current_port": GameState.current_port,
		"player": GameState.player.duplicate(true),
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
		"named_pirate_respawns":
			GameState.named_pirate_respawns.duplicate(true),
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


## Loads the v8 fixture once so the "before" state of a rejection test is a
## real loaded run rather than the clobbered sentinel.
func _load_fixture_into_memory() -> void:
	_ensure_dir()
	_write_json(1, _v8_payload())
	_clobber_state()
	if not SaveSystem.load(1):
		_check(false, "setup: the v8 fixture loads before the test")


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
