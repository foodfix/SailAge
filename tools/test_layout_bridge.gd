extends Node
## Layout-bridge guard (docs/90-ARCHITECTURE.md §5.7 — the frozen WS
## protocol; docs/80-UI-UX.md §4.8.9; IMPLEMENT-Phase11.md W2-A).
## Headless scene test:
##
##   godot --headless --path . res://tools/test_layout_bridge.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS PINNED — the debug gate + the protocol, asserted
## directly (constants + one live loopback over 127.0.0.1; the
## no-overkill discipline — no sweeps, no Monte Carlo):
##   1. DEFAULT-DISABLED — without `--layout-bridge` neither the autoload
##      nor a fresh instance holds a listening peer or polls.
##   2. HELLO — `start_for_tests` arms the server; a plain
##      `WebSocketPeer` client connects and is greeted: the 32 screen
##      ids, the 60×34 design grid, the 32 px chrome tile.
##   3. TREE — `get_tree` (no screen = the current one) lists the rig's
##      registered row with id/kind/role and its live `rect_tiles`.
##   4. LIVE EDITS — `move` lands on the real Control ((64,32) = tiles
##      × 32) and answers a fresh tree; `revert` re-applies the DATA
##      rect; `resize` lands 256×64; a retired Phase-11 field
##      (`reorder`, a `min_w` resize) answers `error`/`retired_field`
##      and changes nothing; `assign_sheet` reports through the tree row
##      (real sheet when the chrome sheets are present, "" flat fallback
##      when not — no error reply either way).
##   5. SINGLE WRITER — `commit` answers `ok` and touches no file:
##      `data/ui_layout.json` bytes are identical before/after.

const BridgeLib := preload("res://autoload/layout_bridge.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const PaletteLib := preload("res://scripts/palette.gd")

## The per-step loopback deadline (harness plumbing, not a game number).
const WAIT_MS := 5000

var _failures: Array[String] = []
var _checks := 0
var _ws: WebSocketPeer = null


func _ready() -> void:
	_test_default_disabled()
	await _test_hello()
	await _test_tree_and_edits()
	await _test_commit_single_writer()
	_cleanup()
	_report()


# --- Harness ----------------------------------------------------------------

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


## The autoload instance (untyped on purpose — its debug-gate internals
## are bridge-script members, not Node members).
func _bridge() -> Variant:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("LayoutBridge")


func _send_msg(payload: Dictionary) -> void:
	_ws.send_text(JSON.stringify(payload))


## Reads queued client messages until one of the wanted type arrives
## (the protocol pushes `screen_changed`/`tree`/`frame` interleaved;
## they are skipped here) — empty dict on timeout.
func _recv_msg(wanted: String) -> Dictionary:
	if _ws == null:
		return {}
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		_ws.poll()
		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			var parsed: Variant = JSON.parse_string(
					packet.get_string_from_utf8())
			if parsed is Dictionary \
					and String(parsed.get("type", "")) == wanted:
				return parsed
		await get_tree().process_frame
	return {}


func _row(tree_msg: Dictionary) -> Dictionary:
	var elements: Array = tree_msg.get("elements", [])
	return elements[0] if not elements.is_empty() else {}


func _file_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	return file.get_buffer(file.get_length())


# --- 1. Default-disabled (the debug gate) ------------------------------------

func _test_default_disabled() -> void:
	var bridge: Variant = _bridge()
	_check(bridge != null, "the LayoutBridge autoload booted (last, after FleetSim)")
	if bridge == null:
		return
	_check(bridge._listener == null and bridge._legacy_server == null,
			"default-disabled: the autoload holds no listening peer")
	_check(not bridge.is_processing(),
			"default-disabled: the autoload does not poll")
	var fresh := BridgeLib.new()
	add_child(fresh)  # runs _ready — still no `--layout-bridge` in the args
	_check(fresh._listener == null and fresh._legacy_server == null,
			"default-disabled: a fresh instance holds no listening peer")
	_check(not fresh.is_processing(),
			"default-disabled: a fresh instance does not poll")
	fresh.free()


# --- 2. Hello (the connect greeting) -------------------------------------------

func _test_hello() -> void:
	_check(BridgeLib.start_for_tests(),
			"start_for_tests arms the server on 127.0.0.1:%d" % BridgeLib.TEST_PORT)
	_ws = WebSocketPeer.new()
	var connect_err: int = _ws.connect_to_url(
			"ws://127.0.0.1:%d" % BridgeLib.TEST_PORT)
	_check(connect_err == OK,
			"a plain WebSocketPeer client can dial the bridge (err=%d)" % connect_err)
	if connect_err != OK:
		return
	var deadline := Time.get_ticks_msec() + WAIT_MS
	var connected := false
	while Time.get_ticks_msec() < deadline:
		_ws.poll()
		var state := _ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			connected = true
			break
		if state == WebSocketPeer.STATE_CLOSED:
			break
		await get_tree().process_frame
	_check(connected, "the client handshake completes against the bridge")
	if not connected:
		return
	var hello := await _recv_msg("hello")
	_check(not hello.is_empty(), "hello arrives on connect")
	if hello.is_empty():
		return
	# The outbound-overflow fix (2026-11-09): the ACCEPTED server peer
	# carries the raised buffer floors BEFORE the first frame push — the
	# engine default (64 KiB) cannot hold a viewport PNG in base64 and
	# every `frame` failed with ERR_OUT_OF_MEMORY.
	var accepted = _bridge()
	_check(accepted != null and accepted._client != null
			and accepted._client.outbound_buffer_size \
					== BridgeLib.PEER_OUTBOUND_BUFFER,
			"the accepted peer's outbound buffer is raised (%d)"
					% BridgeLib.PEER_OUTBOUND_BUFFER)
	_check(accepted != null and accepted._client != null
			and accepted._client.inbound_buffer_size \
					== BridgeLib.PEER_INBOUND_BUFFER,
			"the accepted peer's inbound buffer is raised (%d)"
					% BridgeLib.PEER_INBOUND_BUFFER)
	var screens: Array[String] = [
		"port", "market", "inn", "guild", "provisions", "palace",
		"tavern", "shipyard",
		"title", "nationality_select", "creation",
		"world", "chart", "hail", "fleet_picker", "autopilot_hud",
		"battle", "sandbox", "duel",
		"confirm", "save_slot", "settings", "intel_window", "dialog_box",
		"dossier", "character_card", "captain_view", "fleet_view",
		"officer_roster", "reputation_view", "gameover", "ending",
	]
	_check(RegistryLib.SCREENS == screens,
			"(pin) the registry screen set is the 32 §4.23 ids")
	var hello_screens: Array = hello.get("screens", [])
	_check(hello_screens == screens,
			"hello carries the 32 screen ids")
	var grid: Dictionary = hello.get("grid", {})
	_check(int(grid.get("w", 0)) == 60 and int(grid.get("h", 0)) == 34,
			"hello carries the 60x34 design grid (33.75 rounded; the "
			+ "34th row's bottom 8 px are the sliver)")
	_check(int(hello.get("tile", 0)) == PaletteLib.CHROME_TILE,
			"hello carries the chrome tile (%d)" % PaletteLib.CHROME_TILE)


# --- 3/4. The rig: get_tree + live edits -----------------------------------------

func _test_tree_and_edits() -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	RegistryLib._reset_for_tests()
	# A data row for the rig element — the Phase-12 revert restores the
	# DATA rect (a no-row element has nothing to restore).
	RegistryLib.set_table_for_tests({
		"market": {"elements": {"toolbar": {"x": 0, "y": 0, "w": 2, "h": 1}}},
	})
	var root := Control.new()
	root.name = "RigRoot"
	root.size = Vector2(1920, 1080)
	add_child(root)
	var panel := Panel.new()
	root.add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(64, 32)
	RegistryLib.register("market", panel, "toolbar", {"role": "panel"})
	RegistryLib.screen_active("market", root)
	var tree_msg := await _recv_msg("tree")
	_check(not tree_msg.is_empty(), "get_tree answers with a tree")
	if tree_msg.is_empty():
		_cleanup_rig(root)
		return
	_check(String(tree_msg.get("screen", "")) == "market",
			"the tree reply names the screen (get_tree defaulted to the current one)")
	var row := _row(tree_msg)
	_check(String(row.get("id", "")) == "toolbar"
			and String(row.get("kind", "")) == "free"
			and String(row.get("role", "")) == "panel",
			"the row carries the registration id/kind/role")
	var rect: Dictionary = row.get("rect_tiles", {})
	_check(int(rect.get("x", -1)) == 0 and int(rect.get("y", -1)) == 0
			and int(rect.get("w", -1)) == 2 and int(rect.get("h", -1)) == 1,
			"rect_tiles reads the data rect (0,0,2,1) tiles")

	_send_msg({"type": "move", "screen": "market", "id": "toolbar",
			"x": 2, "y": 1})
	tree_msg = await _recv_msg("tree")
	_check(not tree_msg.is_empty(), "move answers with a fresh tree")
	row = _row(tree_msg)
	rect = row.get("rect_tiles", {})
	_check(int(rect.get("x", -1)) == 2 and int(rect.get("y", -1)) == 1,
			"the fresh tree reports the moved tiles (2,1)")
	_check(panel.position == Vector2(64, 32),
			"move applied live: the panel sits at (64,32) = tiles × 32")

	_send_msg({"type": "revert", "screen": "market", "id": "toolbar"})
	tree_msg = await _recv_msg("tree")
	_check(not tree_msg.is_empty(), "revert answers with a fresh tree")
	_check(panel.position == Vector2.ZERO
			and panel.size == Vector2(64, 32),
			"revert re-applied the DATA rect (0,0,2,1)")

	_send_msg({"type": "resize", "screen": "market", "id": "toolbar",
			"w": 8, "h": 2})
	tree_msg = await _recv_msg("tree")
	_check(not tree_msg.is_empty(), "resize answers with a fresh tree")
	_check(panel.size == Vector2(256, 64),
			"resize applied live: the panel is 256x64")

	# The retired Phase-11 fields (a v1 studio message): answered
	# `error`/`retired_field`, the tree untouched.
	_send_msg({"type": "reorder", "screen": "market", "id": "toolbar",
			"order": 0})
	var err := await _recv_msg("error")
	_check(not err.is_empty()
			and String(err.get("code", "")) == "retired_field",
			"reorder answers retired_field (tolerated, no effect)")
	_send_msg({"type": "resize", "screen": "market", "id": "toolbar",
			"min_w": 3})
	err = await _recv_msg("error")
	_check(not err.is_empty()
			and String(err.get("code", "")) == "retired_field",
			"a min_w resize answers retired_field (tolerated, no effect)"
					+ " [got %s]" % JSON.stringify(err))

	var sheet_exists := ResourceLoader.exists(
			"res://assets/ui/chrome/ninepatch_panel.png")
	_send_msg({"type": "assign_sheet", "screen": "market",
			"id": "toolbar", "sheet": "panel"})
	tree_msg = await _recv_msg("tree")
	_check(not tree_msg.is_empty(), "assign_sheet answers with a fresh tree")
	row = _row(tree_msg)
	if sheet_exists:
		_check(String(row.get("sheet", "-")) == "panel",
				"assign_sheet: the tree row reports sheet=panel (sheets present)")
	else:
		_check(String(row.get("sheet", "-")) == "",
				"assign_sheet: flat fallback — sheet stays empty, no error reply")
	_cleanup_rig(root)


# --- 5. Commit — the single-writer pin --------------------------------------------

func _test_commit_single_writer() -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var before := _file_bytes("res://data/ui_layout.json")
	_check(not before.is_empty(),
			"data/ui_layout.json is readable before commit")
	_send_msg({"type": "commit"})
	var ok := await _recv_msg("ok")
	_check(not ok.is_empty(), "commit answers with ok")
	var after := _file_bytes("res://data/ui_layout.json")
	_check(after == before,
			"commit wrote nothing: data/ui_layout.json bytes unchanged")


# --- Cleanup -----------------------------------------------------------------------

func _cleanup_rig(root: Control) -> void:
	root.free()
	RegistryLib._reset_for_tests()
	RegistryLib.set_table_for_tests({})


func _cleanup() -> void:
	for child in get_children():
		if child.name == "RigRoot":
			child.free()
	RegistryLib._reset_for_tests()
	RegistryLib.set_table_for_tests({})
	BridgeLib._reset_for_tests()
	if _ws != null:
		_ws.close()
	_ws = null
