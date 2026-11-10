extends Node
## LayoutBridge — the studio layout editor's game-side WebSocket endpoint
## (docs/90-ARCHITECTURE.md §5.7, added 2026-11-09, Phase 11;
## docs/80-UI-UX.md §4.8.9; IMPLEMENT-Phase11.md W2-A).
##
## The singleton is the AUTOLOAD (`project.godot`, registered last after
## FleetSim); scripts reach it through the tree (`get_node_or_null(
## "LayoutBridge")`) or `preload` this file for the static test seams —
## a `class_name` here would hide the autoload singleton and is refused
## by the parser (every other autoload follows the same rule).
##
## The game launched with `-- --layout-bridge` serves a ONE-client JSON
## WebSocket protocol on 127.0.0.1:8765: the studio reads the element
## tree of the running screen, pushes live edits (move/resize/reorder/
## assign_sheet/revert/reset_screen — applied immediately through
## `LayoutRegistry` so the user watches the real screen move), pulls
## viewport PNG frames, and finally commits from ITS side. The frozen
## protocol table lives in `90-*` §5.7; this file implements it verbatim.
##
## Single-writer rule (`80-*` §4.8.9): the GAME never writes files. A
## `commit` message is answered with `ok` and nothing else — the studio
## serializes the session, runs the validator, and writes
## `data/ui_layout.json` itself. Saves, the save format and the EventBus
## contract are untouched; the bridge touches only UI trees and the
## network.
##
## Debug gate: without the flag the autoload is a disabled no-op — no
## listener, no polling, zero cost (`_ready` returns after
## `set_process(false)`). Disabled is also the answer to every other
## failure (a taken port, a bind error): the game keeps running.
##
## Server wiring across Godot versions (the repo features say 4.3, the
## local binary is 4.7 — the class split its server API in 4.5):
##   * 4.5+: `WebSocketPeer` lost `create_server`; one `WebSocketPeer`
##     per connection is built from a `TCPServer` listener via
##     `accept_stream` — a plain WebSocket server any studio client
##     (Python `websockets`, a browser) can talk to.
##   * 4.0–4.4: the legacy single-connection `create_server(port, bind)`
##     mode, reached through dynamic dispatch so this script parses on
##     both. Either wiring speaks plain JSON text frames.
## One client max — a newer connection politely replaces an older one
## (the old peer is closed and pumped until the close handshake lands).

const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const PaletteLib := preload("res://scripts/palette.gd")

## The debug gate flag (`90-*` §5.7) — read from the user args.
const FLAG := "--layout-bridge"
## The bridge port (`90-*` §5.7 — a file constant).
const BRIDGE_PORT := 8765
## The suite port (`start_for_tests` default — keeps the suite off the
## production port).
const TEST_PORT := 8766
## Loopback only: the bridge is a studio tool, never an exposed service.
const BIND_ADDRESS := "127.0.0.1"
## The design canvas in chrome tiles (`80-*` §4.8.9 grid caps:
## 1920×1080 / 32 px ⇒ 60 × 34 — 33.75 rounded up; the 34th row's
## bottom 8 px are the canvas sliver).
const GRID_W := 60
const GRID_H := 34
## The reply delay (the Phase-12 amendment of the Phase-11 settle fix):
## with container flow DELETED there are no re-sort cascades — a single
## deferred frame is kept as a safety margin so the reply always reads
## post-layout rects. A newer edit resets the countdown and coalesces.
const UPDATE_SETTLE_FRAMES := 1
## The WS peer buffer floors (the 2026-11-09 outbound-overflow fix): the
## engine's default outbound buffer is 64 KiB while a `frame` message
## carries a full-viewport PNG in base64 (hundreds of KiB to a few MB) —
## every frame push failed with ERR_OUT_OF_MEMORY (the wslay outbound
## bound) until the accepted peer's buffers are raised. 16 MiB outbound
## covers the largest frame; studio edits inbound are tiny but get a
## modest raise too. Applied on EVERY accepted peer, both wirings.
const PEER_OUTBOUND_BUFFER := 16 * 1024 * 1024
const PEER_INBOUND_BUFFER := 1024 * 1024

# --- State -------------------------------------------------------------------

## Whether the gate flag (or the test seam) enabled the bridge.
var _enabled := false
## 4.5+ wiring: the TCP listener handing streams to per-client peers.
var _listener: TCPServer = null
## 4.0–4.4 wiring: the legacy single-connection server peer (kept
## untyped — `create_server` only exists there, and dynamic dispatch
## keeps this script parseable on the 4.5+ classes too).
var _legacy_server = null
## The one current client peer (4.5+ wiring; untyped for the same
## parse-compat reason as `_legacy_server`).
var _client = null
## The replaced client, pumped until its close handshake completes.
var _retiring = null
## Legacy wiring: whether a client session was seen (drives the
## re-listen after a disconnect).
var _legacy_client_seen := false
## Whether the current client already got its `hello`.
var _greeted := false
## The port the server was last started on.
var _port := 0


# --- Lifecycle ---------------------------------------------------------------

func _ready() -> void:
	# Disabled until the flag says otherwise: no listener, no polling,
	# zero cost (90-* §5.7).
	set_process(false)
	for arg in OS.get_cmdline_user_args():
		if arg == FLAG:
			_enabled = true
			break
	if not _enabled:
		return
	_start_server(BRIDGE_PORT)


func _process(_delta: float) -> void:
	if _update_frames_left > 0:
		_update_frames_left -= 1
		if _update_frames_left == 0:
			_send_settled_update()
	if _listener != null:
		_pump_modern()
	elif _legacy_server != null:
		_pump_legacy()


## Starts the listener. `false` + disabled on any failure — the game
## keeps running without the bridge.
func _start_server(port: int) -> bool:
	_port = port
	var probe := WebSocketPeer.new()
	if probe.has_method("create_server"):
		# 4.0–4.4: legacy single-connection server peer.
		_legacy_server = WebSocketPeer.new()
		var legacy_err: int = _legacy_server.create_server(port, BIND_ADDRESS)
		if legacy_err != OK:
			push_error("LayoutBridge: create_server(%d, %s) failed: %s"
					% [port, BIND_ADDRESS, error_string(legacy_err)])
			_legacy_server = null
			set_process(false)
			return false
		_configure_peer(_legacy_server)
	else:
		# 4.5+: plain TCP listener; each accepted stream becomes one
		# WebSocketPeer via `accept_stream`.
		_listener = TCPServer.new()
		var listen_err: int = _listener.listen(port, BIND_ADDRESS)
		if listen_err != OK:
			push_error("LayoutBridge: listen(%d, %s) failed: %s"
					% [port, BIND_ADDRESS, error_string(listen_err)])
			_listener = null
			set_process(false)
			return false
	set_process(true)
	return true


# --- Pumping (4.5+ wiring) ---------------------------------------------------

func _pump_modern() -> void:
	if _listener.is_connection_available():
		var stream := _listener.take_connection()
		var fresh := WebSocketPeer.new()
		if fresh.accept_stream(stream) != OK:
			push_error("LayoutBridge: accept_stream failed — dropped")
		else:
			_replace_client(fresh)
	if _retiring != null:
		_retiring.poll()
		if _retiring.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_retiring = null
	if _client != null:
		_client.poll()
		var state: int = _client.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			if not _greeted:
				_greeted = true
				_send_hello()
				_send_frame()
			_drain(_client)
		elif state == WebSocketPeer.STATE_CLOSED:
			_client = null
			_greeted = false


## One client max, keep the newest: the replaced peer is closed politely
## and pumped (in `_pump_modern`) until the close handshake completes.
func _replace_client(fresh) -> void:
	if _client != null:
		if _retiring != null:
			_retiring.close()  # dropped mid-handshake; best-effort politeness
		_retiring = _client
		_retiring.close()
	_configure_peer(fresh)
	_client = fresh
	_greeted = false


## One peer configuration, both wirings (the buffer floors live in the
## constants block above).
func _configure_peer(peer) -> void:
	peer.outbound_buffer_size = PEER_OUTBOUND_BUFFER
	peer.inbound_buffer_size = PEER_INBOUND_BUFFER


# --- Pumping (4.0–4.4 wiring) ------------------------------------------------

func _pump_legacy() -> void:
	_legacy_server.poll()
	var state: int = _legacy_server.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_legacy_client_seen = true
		if not _greeted:
			_greeted = true
			_send_hello()
			_send_frame()
		_drain(_legacy_server)
	elif state == WebSocketPeer.STATE_CLOSED and _legacy_client_seen:
		# The client left; the legacy server does not re-arm by itself.
		_legacy_client_seen = false
		_greeted = false
		_start_server(_port)


# --- Reading -----------------------------------------------------------------

## Reads every queued packet of one connected peer; JSON text messages
## only (`90-*` §5.7 protocol table).
func _drain(peer) -> void:
	while peer.get_available_packet_count() > 0:
		var packet: PackedByteArray = peer.get_packet()
		if not peer.was_string_packet():
			_send_error("bad_frame", "only JSON text frames are accepted")
			continue
		_handle_message(packet.get_string_from_utf8())


func _handle_message(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_send_error("bad_json", "messages must be JSON objects")
		return
	var msg: Dictionary = parsed
	match String(msg.get("type", "")):
		"get_tree":
			_msg_get_tree(msg)
		"get_frame":
			_send_frame()
		"move":
			_msg_move(msg)
		"resize":
			_msg_resize(msg)
		"reorder":
			_msg_reorder(msg)
		"assign_sheet":
			_msg_assign_sheet(msg)
		"revert":
			_msg_revert(msg)
		"reset_screen":
			_msg_reset_screen(msg)
		"commit":
			# Single-writer rule: `ok` and NOTHING else — no file I/O.
			_send_json({"type": "ok"})
		_:
			_send_error("bad_type", "unknown message type '%s'"
					% String(msg.get("type", "")))


# --- Message handlers ---------------------------------------------------------

func _msg_get_tree(msg: Dictionary) -> void:
	var screen := String(msg.get("screen", ""))
	if screen.is_empty():
		screen = RegistryLib.current_screen()
	if not _known_screen(screen):
		return
	_send_tree(screen)


func _msg_move(msg: Dictionary) -> void:
	if _reject_retired(msg):
		return
	var overrides := {}
	for key in ["x", "y"]:
		if not _add_int_field(msg, key, overrides):
			return
	_edit(msg, overrides)


func _msg_resize(msg: Dictionary) -> void:
	if _reject_retired(msg):
		return
	var overrides := {}
	for key in ["w", "h"]:
		_add_int_field(msg, key, overrides)
	if overrides.is_empty():
		_send_error("bad_field", "resize needs at least one of w/h")
		return
	_edit(msg, overrides)


## A v1 message carrying a retired Phase-11 field is answered
## `retired_field` and changes nothing (the registry's guard is the
## second net).
func _reject_retired(msg: Dictionary) -> bool:
	for key in ["min_w", "min_h", "order", "anchor"]:
		if msg.has(key):
			_send_error("retired_field", ("'%s' is retired — Phase 12 "
					+ "edits carry x/y/w/h + sheet only") % key)
			return true
	return false


func _msg_reorder(_msg: Dictionary) -> void:
	# Retired (Phase 12, 90-* §5.7): there is no flow to re-order.
	# Tolerated without effect until the studio's W3 lands.
	_send_error("retired_field", "reorder is retired — Phase 12 edits "
			+ "carry x/y/w/h + sheet only")


func _msg_assign_sheet(msg: Dictionary) -> void:
	var sheet: Variant = msg.get("sheet", "")
	if not (sheet is String) or String(sheet).is_empty():
		_send_error("bad_field", "assign_sheet needs a non-empty 'sheet' id")
		return
	_edit(msg, {"sheet": sheet})


func _msg_revert(msg: Dictionary) -> void:
	var screen := String(msg.get("screen", ""))
	var id := String(msg.get("id", ""))
	if not _known_screen(screen):
		return
	if id.is_empty():
		_send_error("bad_field", "missing 'id'")
		return
	RegistryLib.revert_element(screen, id)
	_queue_update(screen)


func _msg_reset_screen(msg: Dictionary) -> void:
	var screen := String(msg.get("screen", ""))
	if not _known_screen(screen):
		return
	RegistryLib.reset_screen(screen)
	_queue_update(screen)


## The shared edit path: apply through the registry immediately (the
## user watches the real screen move), then answer with the fresh tree
## + a frame (`90-*` §5.7) — DEFERRED one frame (see `_queue_update`).
## (Retired fields are rejected upstream, in `_reject_retired`; the
## registry's own guard is the second net.)
func _edit(msg: Dictionary, overrides: Dictionary) -> void:
	var screen := String(msg.get("screen", ""))
	var id := String(msg.get("id", ""))
	if not _known_screen(screen):
		return
	if id.is_empty():
		_send_error("bad_field", "missing 'id'")
		return
	RegistryLib.apply_overrides(screen, id, overrides)
	_queue_update(screen)


## Validates one integer-tile field; appends it to `overrides` and
## answers `true` on success, sends `error` and answers `false` on a
## missing/non-numeric value.
func _add_int_field(msg: Dictionary, key: String, overrides: Dictionary) -> bool:
	var value: Variant = msg.get(key, null)
	if value == null or not (value is int or value is float):
		_send_error("bad_field", "missing or non-numeric '%s'" % key)
		return false
	overrides[key] = value
	return true


func _known_screen(screen: String) -> bool:
	if not (screen in RegistryLib.SCREENS):
		_send_error("bad_screen", "unknown screen '%s'" % screen)
		return false
	return true


# --- Writing -------------------------------------------------------------------

## The peer to write to, or null when no client is connected.
func _active_peer():
	if _client != null and _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return _client
	if _legacy_server != null \
			and _legacy_server.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return _legacy_server
	return null


func _send_json(payload: Dictionary) -> void:
	var peer: Variant = _active_peer()
	if peer == null:
		return
	peer.send_text(JSON.stringify(payload))


## `hello` — on connect (`90-*` §5.7): the screen set, the design grid
## and the chrome tile the editor snaps to.
func _send_hello() -> void:
	_send_json({
		"type": "hello",
		"screens": RegistryLib.SCREENS,
		"grid": {"w": GRID_W, "h": GRID_H},
		"tile": PaletteLib.CHROME_TILE,
	})


func _send_screen_changed(screen_id: String) -> void:
	_send_json({"type": "screen_changed", "screen": screen_id})


func _send_tree(screen_id: String) -> void:
	_send_json({
		"type": "tree",
		"screen": screen_id,
		"elements": RegistryLib.tree(screen_id),
	})


## `frame` — the viewport capture as base64 PNG; degrades to an empty
## payload when the image read fails (headless).
func _send_frame() -> void:
	_send_json({"type": "frame", "png_b64": _capture_frame()})


func _send_error(code: String, msg: String) -> void:
	_send_json({"type": "error", "code": code, "msg": msg})


func _capture_frame() -> String:
	if DisplayServer.get_name() == "headless":
		return ""  # the dummy renderer has no pixels to read
	var viewport := get_viewport()
	if viewport == null:
		return ""
	var texture := viewport.get_texture()
	if texture == null:
		return ""
	var image := texture.get_image()
	if image == null or image.is_empty():
		return ""
	return Marshalls.raw_to_base64(image.save_png_to_buffer())


# --- Registry callback ----------------------------------------------------------

## Called by `LayoutRegistry.screen_active` (a has_method-guarded call,
## no hard autoload dependency): pushes `screen_changed` + `tree` +
## `frame` to the connected client. A no-op while disabled or alone.
func on_screen_changed(screen_id: String) -> void:
	if not _enabled or _active_peer() == null:
		return
	_send_screen_changed(screen_id)
	_queue_update(screen_id)


# --- Deferred reply (the 2026-11-09 grid-guarantee fix) -------------------------

## The screen id awaiting its deferred tree+frame reply (`""` = none).
## Coalesced: several edits in one frame answer once.
var _pending_update: String = ""
## The countdown to the settled reply (see UPDATE_SETTLE_FRAMES).
var _update_frames_left: int = 0


## Queues the post-edit reply `UPDATE_SETTLE_FRAMES` frames out. A
## synchronous reply reads the control's rect BEFORE the containers have
## re-sorted (the sort cascades one level per frame), so the studio
## received a stale mid-cascade rect and re-rendered its box from it —
## mid-drag that fought the optimistic box and on release it landed on
## the wrong size. The countdown resets on every newer edit, so bursts
## coalesce into one settled reply.
func _queue_update(screen_id: String) -> void:
	_pending_update = screen_id
	_update_frames_left = UPDATE_SETTLE_FRAMES


func _send_settled_update() -> void:
	var screen := _pending_update
	_pending_update = ""
	if screen.is_empty() or not _enabled or _active_peer() == null:
		return
	_send_tree(screen)
	_send_frame()


# --- Test seams (the suite only; production never calls these) -------------------

## Starts the server regardless of the debug flag — the autoload's
## `_ready` already ran disabled when the suite scene boots.
static func start_for_tests(port := TEST_PORT) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return false
	var bridge: Node = tree.root.get_node_or_null("LayoutBridge")
	if bridge == null:
		push_error("LayoutBridge: start_for_tests — autoload not in the tree")
		return false
	bridge._enabled = true
	return bridge._start_server(port)


## Drops every connection and forgets the server + flags.
static func _reset_for_tests() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var bridge: Node = tree.root.get_node_or_null("LayoutBridge")
	if bridge == null:
		return
	if bridge._client != null:
		bridge._client.close()
	bridge._client = null
	bridge._retiring = null
	bridge._greeted = false
	bridge._legacy_client_seen = false
	if bridge._listener != null:
		bridge._listener.stop()
	bridge._listener = null
	bridge._legacy_server = null
	bridge._enabled = false
	bridge._port = 0
	bridge.set_process(false)
