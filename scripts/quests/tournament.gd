class_name Tournament
extends RefCounted
## The monthly tournament: rotation, entry window, the 3-bout bracket with
## durability carry, prizes and consolation
## (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.6, §4.9.7; `60-*` §4.11.7.1;
## `80-*` §4.7.3).
##
## Pure static logic (`RefCounted`, no node refs, docs/90-* §4). The bracket
## runs real `60-*` battles through `BattleScreen`/`BattleSim`; this module owns
## only the *arrangement* (who, when, how many) and the *payout*.

const FameLib := preload("res://scripts/player/fame.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")

## §4.9.7: one cycle is 30 days; the host rotates through the six capitals.
const CYCLE_DAYS := 30
const ENTRY_FEE := 1000
const ENTRY_WINDOW_FIRST := 1
const ENTRY_WINDOW_LAST := 5
const ROUNDS := 3
## §4.9.7: the escalating hull per round, in order.
const ROUND_HULLS: Array[String] = ["brigantine", "carrack", "galleon"]
## §4.9.7: win all three → 10,000g + 100 fame.
const PRIZE_GOLD := 10000
const PRIZE_FAME := 100
## §4.9.7: lose any round → 500g and a free repair to 50% of effective max.
const CONSOLATION_GOLD := 500
const CONSOLATION_REPAIR_FRACTION := 0.5
## §4.9.7: the battle kind that carries no reputation delta (`60-*` §4.11.7.1).
const ENEMY_KIND := "tournament"
## The saved marker of "this cycle is already entered".
const ENTERED_KEY := "tournament_entered_cycle"


# --- Rotation (docs/70-* §4.9.7) -----------------------------------------

## The 30-day cycle index of `day` (`(day - 1) // 30`).
static func cycle_of(day: int) -> int:
	return int(maxi(day - 1, 0) / CYCLE_DAYS)


## Day within the cycle, 1-based.
static func day_of_cycle(day: int) -> int:
	return ((maxi(day - 1, 0)) % CYCLE_DAYS) + 1


## The six capitals in the locked §7.4 order (`10-*` §7.4).
static func capitals() -> Array:
	var out: Array = []
	for entry in DataLoader.nations_list:
		var capital := str((entry as Dictionary).get("capital_port_id", ""))
		if not capital.is_empty():
			out.append(capital)
	return out


## The host capital of `day`'s cycle: the §7.4 order rotated by `cycle % 6`.
static func host(day: int) -> String:
	var list := capitals()
	if list.is_empty():
		return ""
	return str(list[posmod(cycle_of(day), list.size())])


## `true` when `day` is inside the entry window (cycle days 1–5).
static func in_entry_window(day: int) -> bool:
	var index := day_of_cycle(day)
	return index >= ENTRY_WINDOW_FIRST and index <= ENTRY_WINDOW_LAST


## The cycle marker key used to remember that this cycle is already entered.
static func entered_key(day: int) -> String:
	return "%s_%d" % [ENTERED_KEY, cycle_of(day)]


## `true` when the run already entered this cycle's tournament.
static func already_entered(day: int) -> bool:
	return bool(GameState.discovery_hints.get(entered_key(day), false))


# --- Status / entry (docs/70-* §4.9.7) -----------------------------------

## `{host, open, window_first, window_last, entered, blocked, fee, round_hulls}`
## for the palace row. `blocked` is the `ui_strings` reason key ("" = available).
static func status(port_id: String, day: int) -> Dictionary:
	var host_id := host(day)
	var first := (cycle_of(day)) * CYCLE_DAYS + ENTRY_WINDOW_FIRST
	var last := (cycle_of(day)) * CYCLE_DAYS + ENTRY_WINDOW_LAST
	var blocked := ""
	if port_id != host_id:
		blocked = "tournament.not_host"
	elif not in_entry_window(day):
		blocked = "tournament.closed"
	elif BountyLib.is_port_closed(port_id):
		blocked = "tournament.blocked_bounty"
	elif already_entered(day):
		blocked = "tournament.entered"
	elif GameState.gold < ENTRY_FEE:
		blocked = "market.no_gold"
	return {
		"host": host_id,
		"open": blocked.is_empty(),
		"window_first": first,
		"window_last": last,
		"entered": already_entered(day),
		"blocked": blocked,
		"fee": ENTRY_FEE,
		"round_hulls": ROUND_HULLS.duplicate(),
	}


## Pays the fee and records the entry. Returns `true` on success.
static func enter(port_id: String, day: int) -> bool:
	if not bool(status(port_id, day).get("open", false)):
		return false
	GameState.add_gold(-ENTRY_FEE)
	GameState.discovery_hints[entered_key(day)] = true
	return true


## The enemy fleet of `round` (1-based): one hull of `ROUND_HULLS`, at full
## durability, `crew_min` crew and `armament_slots` cannons (`70-*` §4.9.7).
static func round_fleet(round_number: int) -> Array:
	var index := clampi(round_number - 1, 0, ROUND_HULLS.size() - 1)
	var ship_type_id := ROUND_HULLS[index]
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	if ship_type.is_empty():
		return []
	return [{
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 1)),
		"crew": int(ship_type.get("crew_min", 1)),
		"provisions": 0,
		"water": 0,
		"cannons": int(ship_type.get("armament_slots", 0)),
		"cargo": {},
		"equipment": {"figurehead": "", "sail": ""},
	}]


## The `60-*` encounter descriptor for one bout; `enemy_kind` is
## `"tournament"` so no reputation is charged.
static func encounter(round_number: int, day: int) -> Dictionary:
	return {
		"id": "tournament_%d_%d" % [cycle_of(day), round_number],
		"kind": ENEMY_KIND,
		"nation_id": "",
		"position": {"x": 0, "y": 0},
		"ships": round_fleet(round_number),
		"day": day,
	}


# --- Payout (docs/70-* §4.9.7) -------------------------------------------

## Settles a finished bracket. `round_reached` = the bout the run **lost**
## (0 = the run won all three). Returns the outcome block the palace screen
## reports and the `tournament_finished` signal carries.
static func settle(won: bool, round_reached: int) -> Dictionary:
	var outcome := {
		"won": won,
		"round_reached": round_reached,
		"gold": PRIZE_GOLD if won else CONSOLATION_GOLD,
		"fame": PRIZE_FAME if won else 0,
		"repaired": 0,
	}
	GameState.add_gold(int(outcome["gold"]))
	if won:
		FameLib.add(PRIZE_FAME)
	else:
		outcome["repaired"] = repair_to_half()
	EventBus.tournament_finished.emit(outcome)
	return outcome


## §4.9.7 consolation: every surviving hull is repaired to
## `max(current, ceil(effective_max × 0.5))` for free. Returns the points
## restored in total.
static func repair_to_half() -> int:
	var restored := 0
	for ship in GameState.fleet:
		if not (ship is Dictionary):
			continue
		var hull: Dictionary = ship
		var ship_type: Dictionary = DataLoader.get_ship_type(
			str(hull.get("ship_type_id", "")))
		var equipment: Dictionary = hull.get("equipment", {})
		var figurehead: Dictionary = DataLoader.get_equipment(
			str((equipment as Dictionary).get("figurehead", "")))
		var max_durability := int(ship_type.get("durability", 0)) \
			+ int((figurehead.get("modifiers", {}) as Dictionary).get("durability", 0))
		var floor_value := int(ceil(float(max_durability) * CONSOLATION_REPAIR_FRACTION))
		var current := int(hull.get("durability", 0))
		if floor_value > current:
			restored += floor_value - current
			hull["durability"] = floor_value
	FleetLib.notify_changed()
	return restored


## Runs the whole bracket headlessly against `BattleScreen`, one bout at a
## time, carrying durability between bouts and settling the payout. This is the
## acceptance suite's driver; the palace screen runs the same three bouts
## interactively and calls [method settle] itself.
##
## Returns the [method settle] outcome plus `results` (each bout's §4.11.9
## result string).
static func run_bracket(battle_screen_builder: Callable, day: int) -> Dictionary:
	var results: Array = []
	var round_number := 1
	while round_number <= ROUNDS:
		var screen = battle_screen_builder.call(encounter(round_number, day))
		if screen == null:
			return settle(false, round_number)
		var outcome: Dictionary = screen.call("run_to_completion")
		var result := str((outcome as Dictionary).get("result", ""))
		results.append(result)
		# Durability and crew carry: the screen fought with `GameState.fleet`
		# copies and `BattleResult.apply` wrote the survivors back.
		if result != "victory":
			var settled := settle(false, round_number)
			settled["results"] = results
			return settled
		round_number += 1
	var won := settle(true, 0)
	won["results"] = results
	return won
