extends Control
## S10 battle FX layer (Phase-10 W5-A) — the presentation-only event
## sequencer (docs/80-UI-UX.md §4.7.17; IMPLEMENT-Phase10.md §0 decision 8).
##
## The layer sits over the battle world view (same rect as the grid overlay,
## mouse-transparent) and draws the battle's visual effects in WORLD
## pixels: the screen keeps this node's `position`/`scale` in sync with its
## camera (the same transform the water layer rides), so everything below
## is camera-free.
##
## **Event sequencer.** The screen calls [method observe] on every repaint
## (`_bind`). The layer OBSERVES the engine's existing event stream —
## `BattleSim.log_lines()` plus unit-position diffs — and queues the §4.7.17
## presentation chain move → volley → flight → impact (→ sink). It never
## writes the sim, the log, or anything deterministic; it only reads.
##
## **Timings are the §4.7.17 pins** (flight 300 · splash 400 · impact 300 ·
## smoke 500 · sink 600 · per-event pause 150 ms). Every duration reads
## through the `UiMotion.dur` gate semantics: the screen passes the effective
## instant flag (`battle instant switch OR UiMotion off`) into [method
## observe]. Instant mode resolves every event immediately — no Tween node
## and no `SceneTreeTimer` is ever created here, in any mode (the §5 Motion
## pin "the sequencer in instant mode produces no timers" holds by
## construction); if a static shot is shown it renders frame 0 (§4.8 A.7).
##
## **Texture misses are silent.** Every sprite resolves through the §4.9
## registry (`UiKit.icon_texture`); a null texture skips that VISUAL while
## the timing is still honored (§4.7.17) — a fresh checkout or a headless
## suite renders the timings against nothing, never an error.
##
## The token slide (a `move` event) is the one effect this layer does not
## draw: the world tokens live in the screen's `_on_world_draw`, which asks
## [method move_offset_for] for the active interpolation offset. The sink
## ghost is drawn here (the sim has already removed the hull) from the
## snapshot sprite id the screen's mapper supplied.
##
## This layer never emits an EventBus signal.

const UiKitLib := preload("res://scripts/ui_kit.gd")

## §4.2: 32 px per battle tile (mirrors the screen/overlay constants).
const TILE_PX := 32.0

# --- §4.7.17 pinned timings (ms) ---------------------------------------------

## Cannonball parabolic flight (§4.7.17 table).
const FLIGHT_MS := 300
## Splash frame set (§4.7.17 table) — the miss variant of an impact.
const SPLASH_MS := 400
## Impact frame set (§4.7.17 table).
const IMPACT_MS := 300
## Smoke frame set (§4.7.17 table).
const SMOKE_MS := 500
## Sink fade (§4.7.17 table).
const SINK_MS := 600
## Per-event pause between sequencer steps (§4.7.17 table).
const PAUSE_MS := 150
## The move presentation has NO §4.7.17 row of its own — it rides the pinned
## per-event pause (the W5-A ledger note: no separate duration is invented).
const MOVE_MS := PAUSE_MS

## Parabola peak of the cannonball arc, in world px at t = 0.5. W5-A proposal
## (24 px ≈ ¾ tile, reads as a lobbed shot at 1:1); ONLY the 300 ms flight
## duration is doc-pinned — this height is a pinned code constant so it can
## never drift silently.
const FLIGHT_PEAK_PX := 24.0

## Frame counts per §4.8 A.7 (`fx_splash_{0..3}`, `fx_impact_{0..2}`,
## `fx_smoke_{0..2}`; `fx_cannonball` is a single sprite).
const SPLASH_FRAMES := 4
const IMPACT_FRAMES := 3
const SMOKE_FRAMES := 3

# --- Sequencer state ----------------------------------------------------------

## Queued events (`{kind, cell?, from?, to?, unit_key?, sprite_id?}`), oldest
## first. Empty in instant mode (events resolve as they are observed).
var _queue: Array = []
## The event currently playing ({} when idle).
var _active: Dictionary = {}
## The finished event held through the per-event pause so its end state
## (final frame / arc end) does not pop off one frame early.
var _linger: Array = []
## Pause countdown (seconds) before the next queued event starts.
var _pause_left := 0.0
## Instant-mode static shot: the last visual event of the drained batch,
## rendered at frame 0 until the next observation replaces it ({} = none).
var _static: Dictionary = {}
## Last-seen live state per unit key (`"{side}:{index}"` →
## `{cell: Vector2i, sprite_id: String}`) — the move detector and the sink
## ghost's source. Entries of dead units are kept (the ghost needs them).
var _snap: Dictionary = {}
## Cursor into `sim.log_lines()` — this layer's own presentation cursor,
## never the log renderer's.
var _log_n := 0
## The effective instant flag (battle animate/instant switch OR `UiMotion`
## off — the screen computes it; §4.7.17 "instant ⇒ every duration 0").
var _instant := true
## The screen's hull-sprite mapper (`set_mapper`), supplying the snapshot's
## sprite ids (the §4.8.6 heading8 → dir contract lives on the screen).
var _mapper := Callable()

# --- Pure mapping (the sequencer's event table) -------------------------------

## Maps one engine log entry to its §4.7.17 presentation events, using
## `snap` (the last-seen `{side:index} → {cell, sprite_id}` snapshot) for the
## attacker/target cells. Pure: the same entry + snapshot always map to the
## same event list. Mappings (W5-A, ledgered):
##   * `cannon` → volley (smoke at the attacker) → flight (arc) → impact at
##     the target when the volley drew hull damage, splash when it did not
##     (a bloodless volley splashes short) → sink when the target sank;
##   * `ram` → impact at the target, smoke at the target → sink(s) for the
##     target, then the attacker (§4.5 "the attacker resolves last");
##   * `board` → nothing (S11 owns the duel presentation); `hold`, `strike`,
##     `surrender_enemy`, `retreat`, `surrender` → nothing.
static func map_entry(entry: Dictionary, snap: Dictionary) -> Array:
	var values = entry.get("values", {})
	if not (values is Dictionary):
		return []
	var payload: Dictionary = values
	var attacker := _snap_entry(snap, str(payload.get("side", "")),
		int(payload.get("unit", -1)))
	var target := _snap_entry(snap, str(payload.get("target_side", "")),
		int(payload.get("target", -1)))
	if attacker.is_empty() or target.is_empty():
		return []
	var from: Vector2i = attacker["cell"]
	var to: Vector2i = target["cell"]
	match str(entry.get("kind", "")):
		"cannon":
			var events: Array = [
				{"kind": "volley", "cell": from},
				{"kind": "flight", "from": from, "to": to},
				{"kind": "impact" if int(payload.get("damage", 0)) > 0
					else "splash", "cell": to},
			]
			if bool(payload.get("sunk", false)):
				events.append({"kind": "sink", "cell": to,
					"sprite_id": str(target.get("sprite_id", ""))})
			return events
		"ram":
			var events: Array = [
				{"kind": "impact", "cell": to},
				{"kind": "smoke", "cell": to},
			]
			if bool(payload.get("sunk", false)):
				events.append({"kind": "sink", "cell": to,
					"sprite_id": str(target.get("sprite_id", ""))})
			if bool(payload.get("attacker_sunk", false)):
				events.append({"kind": "sink", "cell": from,
					"sprite_id": str(attacker.get("sprite_id", ""))})
			return events
		_:
			return []


## The snapshot entry of `{side, index}` ({} when the unit was never seen).
static func _snap_entry(snap: Dictionary, side: String, index: int) -> Dictionary:
	var key := "%s:%d" % [side, index]
	var found = snap.get(key, null)
	return found if found is Dictionary else {}


## The last visual event of a drained batch (instant mode's static shot;
## frame 0 per §4.8 A.7). `{}` when the batch carries nothing visual.
static func _last_static(fresh: Array, snap: Dictionary) -> Dictionary:
	for index in range(fresh.size() - 1, -1, -1):
		var entry = fresh[index]
		if not (entry is Dictionary):
			continue
		var events := map_entry(entry, snap)
		for event_index in range(events.size() - 1, -1, -1):
			var event: Dictionary = events[event_index]
			if str(event.get("kind", "")) in ["impact", "splash", "smoke",
					"volley"]:
				return event
	return {}


# --- Screen seam --------------------------------------------------------------

## Registers the hull-sprite mapper: `Callable(unit: Dictionary) -> String`
## building the §4.8.6 `hull_{type}_{owner}_{dir}` id (the screen owns the
## mapping contract; this layer only stores what the mapper returns).
func set_mapper(mapper: Callable) -> void:
	_mapper = mapper


## Forgets the whole presentation state (a new battle opened).
func reset() -> void:
	_queue.clear()
	_active = {}
	_linger = []
	_static = {}
	_pause_left = 0.0
	_snap = {}
	_log_n = 0
	_instant = true
	queue_redraw()


# --- Observation --------------------------------------------------------------

## Drains the engine's event stream into the sequencer. `instant` is the
## effective §4.7.17 gate (the battle's animate/instant switch OR `UiMotion`
## off): true ⇒ every event resolves immediately — the queue is never filled,
## no timer/tween exists, and at most a static frame-0 shot remains.
func observe(sim, instant: bool) -> void:
	_instant = instant
	if sim == null:
		return
	var logs: Array = sim.log_lines()
	var fresh: Array = []
	while _log_n < logs.size():
		fresh.append(logs[_log_n])
		_log_n += 1
	# Position diffs → move events (the sim log has no move rows; the fleet's
	# positions are the authoritative §4.3a stream). Player-side units are
	# iterated first (deployment order), so a turn's move precedes its volley.
	var moves: Array = []
	for unit in sim.units():
		if not (unit is Dictionary) or not bool(unit.get("alive", false)):
			continue
		var key := "%s:%d" % [str(unit.get("side", "")),
			int(unit.get("index", -1))]
		var cell: Vector2i = sim.unit_cell(unit)
		var sprite_id := ""
		if _mapper.is_valid():
			var mapped = _mapper.call(unit)
			sprite_id = str(mapped) if mapped != null else ""
		var previous: Dictionary = _snap_entry(_snap,
			str(unit.get("side", "")), int(unit.get("index", -1)))
		if not previous.is_empty() \
				and Vector2i(previous["cell"]) != cell:
			moves.append({
				"kind": "move", "unit_key": key,
				"from": Vector2i(previous["cell"]), "to": cell,
				"sprite_id": sprite_id,
			})
		_snap[key] = {"cell": cell, "sprite_id": sprite_id}
	if _instant:
		# Instant resolution (§4.7.17): the queue never fills, nothing
		# animates, no timer exists; at most the batch's last visual event
		# shows its frame 0 as a static shot until the next observation.
		_queue.clear()
		_active = {}
		_linger = []
		_pause_left = 0.0
		_static = _last_static(fresh, _snap)
		queue_redraw()
		return
	for move_event in moves:
		_queue.append(move_event)
	for entry in fresh:
		if entry is Dictionary:
			_queue.append_array(map_entry(entry, _snap))
	queue_redraw()


## True while the sequencer still owes presentation time (animate mode only).
## The screen's per-frame AI stepper waits on this so a turn is never played
## on top of its predecessor's effects. Instant mode is never busy.
func busy() -> bool:
	if _instant:
		return false
	return not _queue.is_empty() or not _active.is_empty() or _pause_left > 0.0


## True while a `move` event is animating (the screen re-draws the world
## tokens each frame so the slide is visible).
func needs_world_redraw() -> bool:
	if _instant:
		return false
	for event in _shown_chain():
		if str(event.get("kind", "")) == "move":
			return true
	return false


## The event whose visual is on screen right now: the active one, else the
## lingering one (a move keeps resolving through its pause so the token
## lands before the next step starts).
func _shown_chain() -> Array:
	var chain: Array = []
	if not _active.is_empty():
		chain.append(_active)
	elif not _linger.is_empty():
		chain.append(_linger[0])
	return chain


## The world-pixel offset a unit's token currently carries (its slide from
## the previous cell toward the sim's authoritative cell). ZERO when idle or
## in instant mode — the token then sits exactly where the engine says.
func move_offset_for(unit_key: String) -> Vector2:
	if _instant:
		return Vector2.ZERO
	for event in _shown_chain():
		if str(event.get("kind", "")) != "move" \
				or str(event.get("unit_key", "")) != unit_key:
			continue
		var phase := _event_phase(event)
		var eased := phase * phase * (3.0 - 2.0 * phase)
		return (Vector2(event["from"] - event["to"])) * TILE_PX * (1.0 - eased)
	return Vector2.ZERO


# --- Sequencer loop -----------------------------------------------------------

func _process(delta: float) -> void:
	if _instant:
		return
	if _active.is_empty():
		if _pause_left > 0.0:
			_pause_left = maxf(_pause_left - delta, 0.0)
			queue_redraw()  # the linger state may still be on screen
		if _pause_left <= 0.0 and not _queue.is_empty():
			_start_next()
			queue_redraw()
		return
	var duration := _duration_of(_active)
	_active["t"] = float(_active.get("t", 0.0)) \
		+ (delta / duration if duration > 0.0 else 1.0)
	if float(_active["t"]) >= 1.0:
		_linger = [_active]
		_active = {}
		_pause_left = _gated_ms(PAUSE_MS) / 1000.0
	queue_redraw()


## Starts the next queued event with its pinned duration and a zero phase.
func _start_next() -> void:
	var event: Dictionary = _queue.pop_front()
	event["t"] = 0.0
	_active = event


## The gated duration of `event` in seconds (§4.7.17 pins; instant ⇒ 0).
func _duration_of(event: Dictionary) -> float:
	return _gated_ms(event_ms(str(event.get("kind", "")))) / 1000.0


## The §4.7.17 duration of one event kind (0 = no timed presentation).
static func event_ms(kind: String) -> int:
	match kind:
		"flight":
			return FLIGHT_MS
		"splash":
			return SPLASH_MS
		"impact":
			return IMPACT_MS
		"smoke", "volley":
			return SMOKE_MS
		"sink":
			return SINK_MS
		"move":
			return MOVE_MS
	return 0


## A pinned duration in milliseconds through the gate semantics (instant ⇒ 0;
## the screen computes the effective gate, keeping this layer dependency-light).
func _gated_ms(ms: int) -> float:
	return 0.0 if _instant else float(ms)


## The play phase of `event` (0..1; 0 while it has not started animating).
func _event_phase(event: Dictionary) -> float:
	var duration := _duration_of(event)
	if duration <= 0.0:
		return 1.0
	return clampf(float(event.get("t", 0.0)) / duration, 0.0, 1.0)


# --- Drawing (world px; the screen keeps this node camera-transformed) --------

func _draw() -> void:
	# The active event plays; the previous one lingers at its end state
	# through the pause; instant mode may hold a static frame-0 shot.
	if not _active.is_empty():
		_draw_event(_active, _event_phase(_active))
		return
	if not _linger.is_empty():
		_draw_event(_linger[0], 1.0)
		return
	if not _static.is_empty():
		_draw_event(_static, 0.0)


## One event's visual. A missing texture skips the visual silently (the
## timing is honored by the sequencer either way, §4.7.17).
func _draw_event(event: Dictionary, phase: float) -> void:
	var kind := str(event.get("kind", ""))
	match kind:
		"flight":
			_draw_flight(event, phase)
		"volley", "smoke":
			_draw_frames("fx_smoke", SMOKE_FRAMES, event["cell"], phase,
				16.0)
		"impact":
			_draw_frames("fx_impact", IMPACT_FRAMES, event["cell"], phase,
				32.0)
		"splash":
			_draw_frames("fx_splash", SPLASH_FRAMES, event["cell"], phase,
				32.0)
		"sink":
			_draw_sink(event, phase)
		_:
			pass  # "move" draws nothing here (the world token slides)


## The parabolic cannonball arc: linear ground track `from → to`, quadratic
## height offset peaking at FLIGHT_PEAK_PX (t = 0.5).
func _draw_flight(event: Dictionary, phase: float) -> void:
	var texture := UiKitLib.icon_texture("fx_cannonball")
	if texture == null:
		return
	var from := _cell_center(event["from"])
	var to := _cell_center(event["to"])
	var pos := from.lerp(to, phase)
	pos.y -= FLIGHT_PEAK_PX * 4.0 * phase * (1.0 - phase)
	_draw_sprite(texture, pos, 16.0)


## One frame-set player: the sprite index follows the phase through the
## set's frames; instant mode's zero phase renders frame 0 (§4.8 A.7).
func _draw_frames(base_id: String, count: int, cell, phase: float,
		size_px: float) -> void:
	var index := clampi(int(phase * float(count)), 0, count - 1)
	var texture := UiKitLib.icon_texture("%s_%d" % [base_id, index])
	if texture == null:
		return
	_draw_sprite(texture, _cell_center(cell), size_px)


## The sunk hull's ghost: the last-seen token sprite fading out over the
## pinned 600 ms (alpha 1 → 0 with the phase).
func _draw_sink(event: Dictionary, phase: float) -> void:
	var texture := UiKitLib.icon_texture(str(event.get("sprite_id", "")))
	if texture == null:
		return
	var ink := Color(1.0, 1.0, 1.0, 1.0 - phase)
	var center := _cell_center(event["cell"])
	var size := TILE_PX
	draw_texture_rect(texture,
		Rect2(center - Vector2(size, size) * 0.5, Vector2(size, size)),
		false, ink)


func _draw_sprite(texture: Texture2D, center: Vector2, size_px: float) -> void:
	draw_texture_rect(texture,
		Rect2(center - Vector2(size_px, size_px) * 0.5,
			Vector2(size_px, size_px)), false)


## A cell's centre in this layer's WORLD-px space.
func _cell_center(cell) -> Vector2:
	return Vector2(Vector2i(cell)) * TILE_PX + Vector2(TILE_PX, TILE_PX) * 0.5
