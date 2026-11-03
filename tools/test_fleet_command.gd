extends Node
## Phase-9 W4-D — the §4.9b fleet-command suite (docs/IMPLEMENT-Phase9.md
## W4-D; docs/60-COMBAT.md §4.9b, §4.9a, §4.11.8, §4.12.3). Headless:
##
##   godot --headless res://tools/test_fleet_command.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Every check pins a doc number: the §4.9b state machine, hysteresis,
## succession and assignment rules are asserted as fixed situations — one
## deterministic observation per behavior, no Monte Carlo (the repo's test
## discipline). The pure-logic sections drive `fleet_commander.gd` with
## hand-authored views (the §4.12.3 caller shape); the consumption sections
## drive the merged `ai_fleet.gd` order seam on a real sim.
##
## Sections:
##   1  five-tuple determinism: identical (view, profile, state-copy) pairs
##      ⇒ identical orders AND identical outgoing state, in place (§4.12.3);
##   2  the §4.9b state-machine transfer table: form→close (settled + the
##      3-round bail-out), close→engage (Chebyshev ≤ 5, hysteresis ≥ 2
##      first), engage→wear (parallel bearing), the wear LOCK (a bearing
##      flip cannot interrupt), wear→engage (all within ±1 bucket), morale
##      ≤ 20 break (forced, terminal, from any line state, boundary 21);
##   3  formation vocabularies: line_ahead stations on the reciprocal ray,
##      column lateral spacing (+ hysteresis-exempt wear), screen (anchor
##      station, free fire, never walks line states), swarm (assignment
##      only);
##   4  anchor succession: the lowest living index takes pos + heading,
##      phase/assignments inherit, the anchor re-reads on the successor's
##      death and is stable while the holder lives;
##   5  target assignment: round-robin over the focus order in engage,
##      aggression ≥ 80 focus fire, assignments frozen through wear/break;
##   6  order consumption through `AiFleet.decide`: discipline removes
##      off-station candidates (a station-keeping pick beats the better
##      fire position), `assigned_target` restricts fire (alive-but-
##      unfireable ⇒ hold fire; dead/absent ⇒ free ranking), and the empty
##      order is the free T2 byte-for-byte (same-seed log_lines() identity);
##   7  the §4.11.8 landing discipline at the corner: an eaten pick lands on
##      the origin and never advances distance (no sailing through the wall).

const FleetCommanderLib := preload("res://scripts/combat/fleet_commander.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_determinism()
	_test_transfer_table()
	_test_formations()
	_test_anchor_succession()
	_test_target_assignment()
	_test_order_consumption()
	_test_landing_discipline()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A §4.12.3 view unit — the sim's unit shape (side / index / pos / vel /
## heading8 / ship / alive), hand-authored for the pure-logic sections.
func _view_unit(side: String, index: int, cell: Vector2i, heading: int,
		durability: int, alive: bool = true) -> Dictionary:
	return {
		"side": side, "index": index,
		"pos": cell, "vel": Vector2i.ZERO, "heading8": heading,
		"ship": {"ship_type_id": "latin", "durability": durability},
		"alive": alive,
	}


## The §4.12.3 view: `{units, round, enemy_kind}` (+ optional side_morale).
func _view(units: Array, round_no: int = 1, side_morale = null) -> Dictionary:
	var view := {
		"units": units, "round": round_no, "enemy_kind": "navy",
	}
	if side_morale != null:
		view["side_morale"] = side_morale
	return view


## Three-ship AI line at (40,15)/(41,15)/(42,15) heading west, two player
## ships east of them — the standard transfer-table arrangement.
func _line_view(side_morale = null) -> Dictionary:
	return _view([
		_view_unit("enemy", 0, Vector2i(40, 15), 4, 40),
		_view_unit("enemy", 1, Vector2i(41, 15), 4, 40),
		_view_unit("enemy", 2, Vector2i(42, 15), 4, 40),
		_view_unit("player", 0, Vector2i(20, 15), 0, 50),
		_view_unit("player", 1, Vector2i(22, 15), 0, 50),
	], 1, side_morale)


## A controlled navy-row profile (the §4.10 row shape; focus/aggression
## parameterized so each assignment pin is a closed situation).
func _profile(focus: String = "weakest", aggression: int = 60) -> Dictionary:
	return {
		"kind": "navy", "archetype": "balanced", "aggression": aggression,
		"preferred_range": 3, "flee_below_hp_pct": 0, "focus": focus,
		"courage_mod": 0, "formation": "line_ahead", "ai_level": 1,
	}


func _order_by_index(orders: Array, index: int) -> Dictionary:
	for entry in orders:
		if entry is Dictionary and int(entry.get("index", -1)) == index:
			return entry.get("order", {}) as Dictionary
	return {}


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func origin_cell(sim: BattleSimLib, unit: Dictionary) -> Vector2i:
	return sim.unit_cell(unit)


# --- 1. Five-tuple determinism (§4.12.3 purity) ------------------------------

func _test_determinism() -> void:
	var profile := _profile()
	var state_a := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	var state_b: Dictionary = state_a.duplicate(true)
	var view := _line_view()
	var view_copy: Dictionary = view.duplicate(true)
	var orders_a: Array = FleetCommanderLib.generate_orders(view, profile, state_a)
	var orders_b: Array = FleetCommanderLib.generate_orders(view_copy, profile, state_b)
	_check(orders_a.size() == 3,
		"§4.9b: one order per living AI ship (%d)" % orders_a.size())
	_check(JSON.stringify(orders_a) == JSON.stringify(orders_b),
		"§4.12.3: identical (view, profile, state-copy) pairs ⇒ identical orders")
	_check(JSON.stringify(state_a) == JSON.stringify(state_b),
		"§4.12.3: …and identical outgoing state (the in-place advance is pure)")
	_check(str(state_a["phase"]) == FleetCommanderLib.PHASE_FORM
			and int(state_a["phase_rounds"]) == 1,
		"§4.9b: the state advanced in place (form, phase_rounds 0 → %d)"
			% int(state_a["phase_rounds"]))
	_check(JSON.stringify(view) == JSON.stringify(view_copy),
		"§4.12.3: the view is never mutated")
	# Zero-RNG purity: the orders carry the §4.9b five-tuple keys + the rider.
	var first: Dictionary = _order_by_index(orders_a, 0)
	_check(first.has("station") and first.has("desired_heading8")
			and first.has("desired_speed_band") and first.has("assigned_target")
			and first.has("discipline") and first.has("phase"),
		"§4.9b: each order is the five-tuple + the phase rider (%s)"
			% str(first.keys()))


# --- 2. The §4.9b state-machine transfer table -------------------------------

## Drives `rounds` generate_orders calls, returning the phase after each.
func _drive(state: Dictionary, view: Dictionary, profile: Dictionary,
		rounds: int) -> Array:
	var phases: Array = []
	for _index in rounds:
		FleetCommanderLib.generate_orders(view, profile, state)
		phases.append(str(state["phase"]))
	return phases


func _test_transfer_table() -> void:
	var profile := _profile()

	# form→close, settled: the exit needs the deviation ≤ 2 test AND the
	# ≥ 2-round hysteresis hold (§4.9b form row + hysteresis bullet).
	var settled := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	var settled_phases: Array = _drive(settled, _line_view(), profile, 3)
	_check(settled_phases == ["form", "form", "close"],
		"§4.9b form: settled + hysteresis ⇒ form, form, close (%s)"
			% str(settled_phases))

	# form→close, the 3-round bail-out (ships scattered past deviation 2).
	var scattered_view := _view([
		_view_unit("enemy", 0, Vector2i(30, 15), 4, 40),
		_view_unit("enemy", 1, Vector2i(40, 10), 4, 40),
		_view_unit("enemy", 2, Vector2i(40, 20), 4, 40),
		_view_unit("player", 0, Vector2i(20, 15), 0, 50),
		_view_unit("player", 1, Vector2i(22, 15), 0, 50),
	])
	var bailout := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	var bailout_phases: Array = _drive(bailout, scattered_view, profile, 4)
	_check(bailout_phases == ["form", "form", "form", "close"],
		"§4.9b form: the 3-round bail-out fires after exactly 3 held rounds (%s)"
			% str(bailout_phases))

	# close→engage: nearest enemy Chebyshev ≤ 5 AND ≥ 2 held rounds first
	# (§4.9b close row + hysteresis). The anchor steps one cell per close
	# call toward the enemy at (36,15) — in range from the first call, so
	# the two early calls pin the hysteresis alone.
	var closing := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	closing["phase"] = FleetCommanderLib.PHASE_CLOSE
	closing["phase_rounds"] = 0
	closing["anchor_pos"] = Vector2i(40, 15)
	closing["anchor_heading"] = 4
	var close_view := _view([
		_view_unit("enemy", 0, Vector2i(40, 15), 4, 40),
		_view_unit("enemy", 1, Vector2i(41, 15), 4, 40),
		_view_unit("enemy", 2, Vector2i(42, 15), 4, 40),
		_view_unit("player", 0, Vector2i(36, 15), 0, 50),
		_view_unit("player", 1, Vector2i(22, 15), 0, 50),
	])
	var close_phases: Array = []
	var anchor_track: Array = []
	for _index in 3:
		FleetCommanderLib.generate_orders(close_view, profile, closing)
		close_phases.append(str(closing["phase"]))
		anchor_track.append((closing["anchor_pos"] as Vector2i).x)
	_check(close_phases == ["close", "close", "engage"],
		"§4.9b close: within 5 from the first call, engage waits for the "
			+ "≥ 2-round hold (%s)" % str(close_phases))
	_check(anchor_track == [39, 38, 37],
		"§4.9b close: the anchor cruises one cell per round toward the enemy (%s)"
			% str(anchor_track))
	# Engage entry heads the queue perpendicular to the enemy bearing,
	# smaller turn wins, tie → +90°: bearing W (4) from heading W → tie → S.
	_check(int(closing["anchor_heading"]) == 6,
		"§4.9b engage: the queue heading enters perpendicular to the bearing "
			+ "(tie → +90°): %d" % int(closing["anchor_heading"]))

	# engage→wear: the enemy bearing turns parallel (0°/180°) to the queue;
	# line_ahead's wear exit is non-forced ⇒ hysteresis ≥ 2 first.
	var engage_view := _line_view()
	for unit in engage_view["units"]:
		if str(unit["side"]) == "player" and int(unit["index"]) == 0:
			unit["pos"] = Vector2i(37, 10)  # bearing N off anchor (37,15)
	var wear_phases: Array = _drive(closing, engage_view, profile, 3)
	_check(wear_phases == ["engage", "engage", "wear"],
		"§4.9b engage: parallel bearing ⇒ wear after the ≥ 2-round hold (%s)"
			% str(wear_phases))
	# Wear entry: ±90° toward the new bearing, smaller step wins (tie → +90°):
	# old S (6), bearing N (2) → tie → clockwise E (0).
	_check(int(closing["anchor_heading"]) == 0,
		"§4.9b wear: the wear heading is ±90° toward the bearing (tie → +90°): %d"
			% int(closing["anchor_heading"]))

	# The wear LOCK: nothing but "every ship within ±1 bucket" ends wear —
	# an intermediate bearing flip must NOT interrupt the maneuver.
	var lock_view := _line_view()
	for unit in lock_view["units"]:
		if str(unit["side"]) == "enemy":
			unit["heading8"] = 4  # far from the wear heading 0
	var flip := _drive(closing, lock_view, profile, 1)
	_check(flip == ["wear"],
		"§4.9b wear: misaligned ships hold the lock (%s)" % str(flip))
	for unit in lock_view["units"]:
		if str(unit["side"]) == "player" and int(unit["index"]) == 0:
			unit["pos"] = Vector2i(31, 11)  # the bearing flips to NW mid-wear
	var flipped: Array = _drive(closing, lock_view, profile, 1)
	_check(flipped == ["wear"],
		"§4.9b wear: an intermediate bearing flip does not interrupt the lock (%s)"
			% str(flipped))

	# wear→engage: every living ship within ±1 bucket of the wear heading.
	for unit in lock_view["units"]:
		if str(unit["side"]) == "enemy":
			unit["heading8"] = 0
	var reengaged: Array = _drive(closing, lock_view, profile, 1)
	_check(reengaged == ["engage"],
		"§4.9b wear: all ships within ±1 bucket ⇒ back to engage (%s)"
			% str(reengaged))
	_check(int(closing["anchor_heading"]) == 1,
		"§4.9b engage: re-entry heads perpendicular to the NEW bearing (%d)"
			% int(closing["anchor_heading"]))

	# morale ≤ 20 ⇒ break: forced (no hysteresis), terminal, from any line
	# state (§4.9b bullet); the boundary is ≤ 20 — morale 21 never breaks.
	for phase in [FleetCommanderLib.PHASE_FORM, FleetCommanderLib.PHASE_CLOSE,
			FleetCommanderLib.PHASE_ENGAGE, FleetCommanderLib.PHASE_WEAR]:
		var broken := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
		broken["phase"] = phase
		var low_view := _line_view(20)
		FleetCommanderLib.generate_orders(low_view, profile, broken)
		_check(str(broken["phase"]) == FleetCommanderLib.PHASE_BREAK,
			"§4.9b: side morale 20 breaks from %s (forced)" % str(phase))
	var terminal := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	terminal["phase"] = FleetCommanderLib.PHASE_BREAK
	FleetCommanderLib.generate_orders(_line_view(80), profile, terminal)
	_check(str(terminal["phase"]) == FleetCommanderLib.PHASE_BREAK,
		"§4.9b: break is terminal for the battle (morale 80 does not restore)")
	var boundary := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	boundary["phase"] = FleetCommanderLib.PHASE_CLOSE
	FleetCommanderLib.generate_orders(_line_view(21), profile, boundary)
	_check(str(boundary["phase"]) == FleetCommanderLib.PHASE_CLOSE,
		"§4.9b: side morale 21 stays short of the break gate (%s)"
			% str(boundary["phase"]))


# --- 3. Formation vocabularies (§4.9b table, per formation) ------------------

func _test_formations() -> void:
	var profile := _profile()

	# line_ahead: stations trail the anchor on the reciprocal ray.
	var line := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	var line_orders: Array = FleetCommanderLib.generate_orders(_line_view(), profile, line)
	_check(_order_by_index(line_orders, 0)["station"] == Vector2i(40, 15)
			and _order_by_index(line_orders, 1)["station"] == Vector2i(41, 15)
			and _order_by_index(line_orders, 2)["station"] == Vector2i(42, 15),
		"§4.9b form: line_ahead stations at 1-cell intervals on the reciprocal (%s)"
			% str([_order_by_index(line_orders, 0)["station"],
			_order_by_index(line_orders, 1)["station"],
			_order_by_index(line_orders, 2)["station"]]))
	_check(int(_order_by_index(line_orders, 1)["desired_heading8"]) == 4
			and not bool(_order_by_index(line_orders, 1)["discipline"]),
		"§4.9b form: the queue heading rides along; discipline off outside "
			+ "engage/wear")

	# column: lateral spacing (the ray turns +90°).
	var column := FleetCommanderLib.initial_state("column", Vector2i(40, 15), 4)
	var column_orders: Array = FleetCommanderLib.generate_orders(_line_view(), profile, column)
	_check(_order_by_index(column_orders, 1)["station"] == Vector2i(40, 14),
		"§4.9b form: column stations space laterally (%s)"
			% str(_order_by_index(column_orders, 1)["station"]))

	# column's engage→wear is hysteresis-EXEMPT ("+wear as a forced state"):
	# a parallel bearing at held 0 wears on the first call.
	var column_drive := FleetCommanderLib.initial_state("column", Vector2i(40, 15), 4)
	var column_view := _view([
		_view_unit("enemy", 0, Vector2i(40, 15), 4, 40),
		_view_unit("enemy", 1, Vector2i(40, 14), 4, 40),
		_view_unit("enemy", 2, Vector2i(40, 13), 4, 40),
		_view_unit("player", 0, Vector2i(36, 15), 0, 50),
		_view_unit("player", 1, Vector2i(22, 15), 0, 50),
	])
	var column_phases: Array = _drive(column_drive, column_view, profile, 3)
	column_phases.append_array(_drive(column_drive, column_view, profile, 3))
	for unit in column_view["units"]:
		if str(unit["side"]) == "player" and int(unit["index"]) == 0:
			unit["pos"] = Vector2i(37, 10)  # bearing N — parallel to the S queue
	column_phases.append_array(_drive(column_drive, column_view, profile, 1))
	_check(column_phases == ["form", "form", "close", "close", "close",
			"engage", "wear"],
		"§4.9b column: form→close→engage and a hysteresis-exempt wear (%s)"
			% str(column_phases))

	# screen: the phase never walks the line states — not even the morale
	# break reaches it (screen/swarm are not line states).
	var screen := FleetCommanderLib.initial_state("screen", Vector2i(40, 15), 4)
	var screen_phases: Array = _drive(screen, _line_view(10), profile, 3)
	_check(screen_phases == ["screen", "screen", "screen"],
		"§4.9b screen: the phase never walks form/close/engage/wear/break (%s)"
			% str(screen_phases))
	var screen_orders: Array = FleetCommanderLib.generate_orders(_line_view(), profile, screen)
	var screen_order: Dictionary = _order_by_index(screen_orders, 2)
	_check(screen_order["station"] == Vector2i(40, 15)
			and not bool(screen_order["discipline"])
			and int(screen_order["assigned_target"]) == -1,
		"§4.9b screen: the station is the screen center (the anchor), free fire")

	# swarm: assignment only — steering and heading stay free.
	var swarm := FleetCommanderLib.initial_state("swarm", Vector2i(40, 15), 4)
	var swarm_orders: Array = FleetCommanderLib.generate_orders(_line_view(), profile, swarm)
	var swarm_order: Dictionary = _order_by_index(swarm_orders, 1)
	_check(str(swarm["phase"]) == FleetCommanderLib.PHASE_SWARM
			and swarm_order["station"] == Vector2i(41, 15)
			and not bool(swarm_order["discipline"]),
		"§4.9b swarm: assignment only — station = own cell, no discipline")
	_check(int(swarm_order["assigned_target"]) >= 0,
		"§4.9b swarm: the swarm order still carries its assigned target (%d)"
			% int(swarm_order["assigned_target"]))


# --- 4. Anchor succession (§4.9b) --------------------------------------------

func _test_anchor_succession() -> void:
	var profile := _profile()
	# An engage state with a live assignment map, then forced break (the
	# phase where assignments are kept) — succession must inherit both.
	var state := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	state["phase"] = FleetCommanderLib.PHASE_ENGAGE
	var view := _view([
		_view_unit("enemy", 0, Vector2i(40, 15), 4, 40),
		_view_unit("enemy", 1, Vector2i(41, 15), 4, 40),
		_view_unit("enemy", 2, Vector2i(42, 15), 4, 40),
		_view_unit("player", 0, Vector2i(36, 15), 0, 30),
		_view_unit("player", 1, Vector2i(38, 12), 0, 50),
		_view_unit("player", 2, Vector2i(30, 18), 0, 50),
	])
	FleetCommanderLib.generate_orders(view, profile, state)
	var assignments: Dictionary = (state["assignments"] as Dictionary).duplicate(true)
	_check(assignments.size() == 3,
		"§4.9b engage: an assignment per ship (%s)" % str(assignments))
	var morale_view := _view(view["units"].duplicate(true), 1, 15)
	FleetCommanderLib.generate_orders(morale_view, profile, state)
	_check(str(state["phase"]) == FleetCommanderLib.PHASE_BREAK
			and (state["assignments"] as Dictionary) == assignments,
		"§4.9b break: dissolve keeps the assignment distribution")

	# Flagship dead → the LOWEST living index takes anchor pos + heading;
	# phase/phase_rounds inherit unchanged.
	var successor_view := _view(view["units"].duplicate(true), 1, 15)
	for unit in successor_view["units"]:
		if str(unit["side"]) == "enemy" and int(unit["index"]) == 0:
			unit["alive"] = false
		if str(unit["side"]) == "enemy" and int(unit["index"]) == 1:
			unit["heading8"] = 2  # N — distinguishable from the old anchor
		FleetCommanderLib.generate_orders(successor_view, profile, state)
	_check(bool(state["flagship_down"])
			and state["anchor_pos"] == Vector2i(41, 14)
			and int(state["anchor_heading"]) == 2,
		"§4.9b succession: ship 1's pos + heading becomes the anchor (%s/%d)"
			% [str(state["anchor_pos"]), int(state["anchor_heading"])])
	_check(str(state["phase"]) == FleetCommanderLib.PHASE_BREAK
			and (state["assignments"] as Dictionary) == assignments,
		"§4.9b succession: the state machine + assignments inherit")
	var held: Dictionary = _order_by_index(
		FleetCommanderLib.generate_orders(successor_view, profile, state), 1)
	var held_again: Dictionary = _order_by_index(
		FleetCommanderLib.generate_orders(successor_view, profile, state), 1)
	_check(int(held["assigned_target"]) == int(assignments[1])
			and int(held_again["assigned_target"]) == int(assignments[1]),
		"§4.9b succession: the anchor succession is stable while the holder "
			+ "lives (assigned %d twice)" % int(held["assigned_target"]))

	# The successor dies too → the anchor re-reads onto the next lowest.
	for unit in successor_view["units"]:
		if str(unit["side"]) == "enemy" and int(unit["index"]) == 1:
			unit["alive"] = false
		if str(unit["side"]) == "enemy" and int(unit["index"]) == 2:
			unit["heading8"] = 6  # S — distinguishable again
	FleetCommanderLib.generate_orders(successor_view, profile, state)
	_check(state["anchor_pos"] == Vector2i(42, 16)
			and int(state["anchor_heading"]) == 6,
		"§4.9b succession: the successor's death reassigns the anchor again (%s)"
			% str(state["anchor_pos"]))


# --- 5. Target assignment (§4.9b) --------------------------------------------

func _assignment_view() -> Dictionary:
	return _view([
		_view_unit("enemy", 0, Vector2i(40, 15), 4, 40),
		_view_unit("enemy", 1, Vector2i(41, 15), 4, 40),
		_view_unit("enemy", 2, Vector2i(42, 15), 4, 40),
		_view_unit("enemy", 3, Vector2i(43, 15), 4, 40),
		_view_unit("player", 0, Vector2i(36, 15), 0, 50),
		_view_unit("player", 1, Vector2i(38, 12), 0, 40),
		_view_unit("player", 2, Vector2i(30, 18), 0, 30),
	])


func _test_target_assignment() -> void:
	# Round-robin over the focus ordering (weakest: durability 30, 40, 50
	# → indices 2, 1, 0), ships in fleet-index order, wrapping.
	var engage := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	engage["phase"] = FleetCommanderLib.PHASE_ENGAGE
	var orders: Array = FleetCommanderLib.generate_orders(_assignment_view(),
		_profile("weakest", 60), engage)
	var picked: Dictionary = (engage["assignments"] as Dictionary)
	_check(int(picked[0]) == 2 and int(picked[1]) == 1 and int(picked[2]) == 0,
		"§4.9b engage: round-robin over the focus order (%s)" % str(picked))
	_check(int(picked[3]) == 2,
		"§4.9b engage: a fourth ship wraps the round-robin (%s)" % str(picked))
	_check(int(_order_by_index(orders, 2)["assigned_target"]) == 0,
		"§4.9b engage: the order carries the assignment (ship 2 → player 0)")

	# aggression ≥ 80: the whole fleet focus-fires the focus-top target.
	var focus := FleetCommanderLib.initial_state("line_ahead", Vector2i(40, 15), 4)
	focus["phase"] = FleetCommanderLib.PHASE_ENGAGE
	FleetCommanderLib.generate_orders(_assignment_view(),
		_profile("weakest", 85), focus)
	var focus_picked: Dictionary = (focus["assignments"] as Dictionary)
	_check(int(focus_picked[0]) == 2 and int(focus_picked[1]) == 2
			and int(focus_picked[2]) == 2 and int(focus_picked[3]) == 2,
		"§4.9b engage: aggression ≥ 80 focus-fires one target (%s)"
			% str(focus_picked))

	# Assignments freeze through wear and break (only engage/swarm re-pick).
	var frozen := engage.duplicate(true)
	frozen["phase"] = FleetCommanderLib.PHASE_WEAR
	var wear_view := _assignment_view()
	for unit in wear_view["units"]:
		if str(unit["side"]) == "enemy":
			unit["heading8"] = 4  # misaligned ⇒ wear holds (the lock)
	FleetCommanderLib.generate_orders(wear_view, _profile(), frozen)
	_check((frozen["assignments"] as Dictionary) == (engage["assignments"] as Dictionary),
		"§4.9b wear: the maneuver holds the distribution it engaged with")
	var broken := engage.duplicate(true)
	broken["phase"] = FleetCommanderLib.PHASE_BREAK
	var break_orders: Array = FleetCommanderLib.generate_orders(_assignment_view(),
		_profile(), broken)
	_check((broken["assignments"] as Dictionary) == (engage["assignments"] as Dictionary)
			and int(_order_by_index(break_orders, 1)["assigned_target"])
				== int((engage["assignments"] as Dictionary)[1]),
		"§4.9b break: dissolve to swarm keeps the assignments")


# --- 6. Order consumption (AiFleet.decide with an order) ---------------------

## A real sim for the consumption sections: enemy_kind navy (the §4.10 row
## the consumer reads internally), hermetic weather/current like test_battle.
func _sim(player_ships: Array, enemy_ships: Array, seed_value: int,
		enemy_morale = null) -> BattleSimLib:
	var config := {
		"player_ships": player_ships, "enemy_ships": enemy_ships,
		"enemy_kind": "navy", "enemy_nation": "spain",
		"day": 20, "gold": 500, "contact": Vector2i(30, 40),
		"weather": "calm", "wind_dir": "E",
		"current": {"dir": "", "strength": 0}, "seed": seed_value,
	}
	if enemy_morale != null:
		config["enemy_morale"] = enemy_morale
	return BattleSimLib.new(config)


func _ship(ship_type_id: String, overrides: Dictionary = {}) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	var ship := {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0, "water": 0, "cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}
	for key in overrides:
		ship[key] = overrides[key]
	return ship


func _unit(sim: BattleSimLib, side: String, index: int) -> Dictionary:
	for unit in sim.units():
		if str(unit.get("side", "")) == side and int(unit.get("index", -1)) == index:
			return unit
	return {}


func _place(sim: BattleSimLib, side: String, index: int, cell: Vector2i) -> void:
	var unit := _unit(sim, side, index)
	if not unit.is_empty():
		unit["pos"] = cell


func _face(unit: Dictionary, heading8: int) -> void:
	if not unit.is_empty():
		unit["heading8"] = heading8


func _test_order_consumption() -> void:
	# (a) discipline hard-removes off-station candidates: the only
	#     fire-enabling move (east, (11,15) → range 3 of the player at
	#     (14,17)) WORSENS the deviation to station (9,14) — a disciplined
	#     ship picks a station-keeping velocity instead; the same situation
	#     without the order takes the fire position.
	var sim := _sim(
		[_ship("brigantine", {"cannons": 0})],
		[_ship("latin", {"cannons": 4})], 911)
	sim.start()
	_place(sim, "player", 0, Vector2i(14, 17))
	var hunter := _unit(sim, "enemy", 0)
	_place(sim, "enemy", 0, Vector2i(10, 15))
	_face(hunter, BattleSimLib.HEADING_EAST)
	hunter["vel"] = Vector2i.ZERO
	var station := Vector2i(9, 14)
	var disciplined := AiFleetLib.decide(sim, hunter, {
		"station": station, "desired_heading8": 4,
		"desired_speed_band": [0, 2], "assigned_target": -1,
		"discipline": true, "phase": "close",
	})
	_check((disciplined["vel"] as Vector2i) == Vector2i(0, -1),
		"§4.9b discipline: the station-keeping pick wins over the off-station "
			+ "fire position (%s)" % str(disciplined["vel"]))
	var origin := sim.unit_cell(hunter)
	var landing: Vector2i = origin + (disciplined["vel"] as Vector2i)
	_check(_chebyshev(landing, station) <= _chebyshev(origin, station),
		"§4.9b discipline: the pick's landing never worsens the station "
			+ "deviation (%d ≤ %d)" % [_chebyshev(landing, station),
			_chebyshev(origin, station)])
	var free := AiFleetLib.decide(sim, hunter)
	_check((free["vel"] as Vector2i) == Vector2i(1, 0),
		"§4.9a close: without the order the same ship takes the fire "
			+ "position (%s)" % str(free["vel"]))

	# (b) assigned_target restricts fire: alive-but-unfireable ⇒ hold fire;
	#     dead/absent ⇒ the free ranking falls back.
	var fire_sim := _sim(
		[_ship("sloop", {"cannons": 0, "durability": 60}),
		_ship("sloop", {"cannons": 0, "durability": 40})],
		[_ship("latin", {"cannons": 4})], 912)
	fire_sim.start()
	_place(fire_sim, "player", 0, Vector2i(13, 15))  # dead-ahead: no arc
	_place(fire_sim, "player", 1, Vector2i(13, 17))  # starboard: fireable
	var gunner := _unit(fire_sim, "enemy", 0)
	_place(fire_sim, "enemy", 0, Vector2i(10, 15))
	_face(gunner, BattleSimLib.HEADING_EAST)
	gunner["vel"] = Vector2i.ZERO
	var blank := {
		"station": Vector2i(10, 15), "desired_heading8": 0,
		"desired_speed_band": [0, 2], "discipline": false, "phase": "",
	}
	var hold_fire := AiFleetLib.decide(fire_sim, gunner,
		(blank as Dictionary).merged({"assigned_target": 0}, true))
	_check(str(hold_fire["action"]) != "cannon",
		"§4.9b: assigned + alive but unfireable ⇒ HOLD fire (action %s)"
			% str(hold_fire["action"]))
	var on_target := AiFleetLib.decide(fire_sim, gunner,
		(blank as Dictionary).merged({"assigned_target": 1}, true))
	_check(str(on_target["action"]) == "cannon"
			and (on_target["target"] as Dictionary).get("index", -1) == 1,
		"§4.9b: the fireable assignment concentrates the guns (action %s, "
			+ "target %d)" % [str(on_target["action"]),
				int((on_target["target"] as Dictionary).get("index", -1))])
	var fallback := AiFleetLib.decide(fire_sim, gunner,
		(blank as Dictionary).merged({"assigned_target": 7}, true))
	_check(str(fallback["action"]) == "cannon"
			and (fallback["target"] as Dictionary).get("index", -1) == 1,
		"§4.9b: a dead/absent assignment falls back to the free ranking "
			+ "(action %s, target %d)" % [str(fallback["action"]),
				int((fallback["target"] as Dictionary).get("index", -1))])

	# (c) the empty order IS the free T2 — byte-for-byte: two same-seed
	#     battles differing only in the `{}` wrapper replay identical logs.
	var runs: Array = []
	for wrapped in [false, true]:
		var rng := RandomNumberGenerator.new()
		rng.seed = 4242
		var foes: Array = AiFleetLib.compose_enemy("pirate", 30, rng)
		for foe in foes:
			foe["durability"] = int(foe.get("durability", 40))
		var battle := BattleSimLib.new({
			"player_ships": [
				_ship("sloop", {"cannons": 0}),
				_ship("sloop", {"cannons": 0}),
			],
			"enemy_ships": foes, "enemy_kind": "pirate",
			"day": 30, "gold": 0, "contact": Vector2i(30, 40),
			"weather": "calm", "wind_dir": "E",
			"current": {"dir": "", "strength": 0},
			"seed": 4242, "rng": rng,
		})
		battle.start()
		for entry in battle.units():
			if str(entry["side"]) == "enemy" and int(entry["index"]) > 1:
				entry["pos"] = Vector2i(12, 15 + int(entry["index"]))
			elif str(entry["side"]) == "enemy":
				entry["pos"] = Vector2i(12, 15 + int(entry["index"]))
		var policy := func(active_sim, unit) -> Dictionary:
			if str(unit.get("side", "")) == "enemy":
				return AiFleetLib.decide(active_sim, unit,
					{} if wrapped else Dictionary())
			return {"action": "hold"}
		var outcome := battle.run_to_completion(policy, BattleSimLib.MAX_ROUNDS)
		runs.append({
			"log": JSON.stringify(battle.log_lines()),
			"outcome": JSON.stringify(outcome),
			"result": str(outcome.get("result", "")),
		})
	_check(runs.size() == 2 and str(runs[0]["log"]) == str(runs[1]["log"])
			and str(runs[0]["outcome"]) == str(runs[1]["outcome"]),
		"§4.9b: the empty-order wrapper replays the free T2 byte-for-byte "
			+ "(%s)" % str(runs[0]["result"]))


# --- 7. The landing discipline at the corner (§4.11.8 pin 1) -----------------

func _test_landing_discipline() -> void:
	# A cornered fleer: side morale ≤ 20 opens the §4.9a flee rule; every
	# candidate's §4.3a landing is eaten (out-of-grid west, friendly
	# north/south) — the naive pos+vel reading would "flee" through the
	# map edge; the landing ruling holds instead.
	var corner := _sim(
		[_ship("sloop", {"cannons": 0})],
		[_ship("latin", {"cannons": 4}), _ship("latin", {"cannons": 0}),
		_ship("latin", {"cannons": 0})], 913, 15)
	corner.start()
	_place(corner, "player", 0, Vector2i(5, 10))
	var trapped := _unit(corner, "enemy", 0)
	_place(corner, "enemy", 0, Vector2i(0, 10))
	trapped["vel"] = Vector2i(-1, 0)
	_face(trapped, BattleSimLib.HEADING_WEST)
	_place(corner, "enemy", 1, Vector2i(0, 9))
	_place(corner, "enemy", 2, Vector2i(0, 11))
	# The mechanism pin: an out-of-grid pick lands on the origin.
	_check(AiFleetLib._landing(corner, trapped, origin_cell(corner, trapped),
			Vector2i(-2, 0)) == Vector2i(0, 10),
		"§4.11.8 pin 1: an out-of-grid pick's landing equals the origin")
	_check(AiFleetLib._landing(corner, trapped, origin_cell(corner, trapped),
			Vector2i(1, 0)) == Vector2i(1, 10),
		"§4.11.8 pin 1: an open pick lands where the sweep puts it")
	var stuck := AiFleetLib.decide(corner, trapped)
	_check(str(stuck["action"]) == "hold",
		"§4.11.8 pin 1 / §4.9a flee: a cornered fleer holds — it never sails "
			+ "through the wall (action %s)" % str(stuck["action"]))

	# The ordered close at the corner: every candidate's landing is eaten,
	# so the station pick cannot advance distance either.
	var order := {
		"station": Vector2i(4, 10), "desired_heading8": 4,
		"desired_speed_band": [0, 2], "assigned_target": -1,
		"discipline": false, "phase": "close",
	}
	var ordered := AiFleetLib.decide(corner, trapped, order)
	var pick := ordered.get("vel", Vector2i.ZERO) as Vector2i
	var landing_cell: Vector2i = AiFleetLib._landing(corner, trapped,
		origin_cell(corner, trapped), pick)
	_check(_chebyshev(landing_cell, Vector2i(4, 10))
			>= _chebyshev(origin_cell(corner, trapped), Vector2i(4, 10)),
		"§4.9b close: an eaten pick never advances the station distance "
			+ "(landing %s)" % str(landing_cell))


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
