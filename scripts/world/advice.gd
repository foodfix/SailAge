class_name Advice
extends RefCounted
## Officer advice events (docs/IMPLEMENT-Phase8.md §2.5; `50-*` §4.5.2's
## post→pipeline table; trigger table `data/officer_posts.json` `advice`).
##
## Each sea-day tick, every **in-post flagship officer** has a seeded **3%**
## chance to fire its post's situational hint — only when the post's
## situation condition holds. Pure text (`ui_strings advice.{post}.{situation}`),
## collected into a session queue the world scene drains into its notice
## flow. Deterministic: the roll is `hash(day, officer_id) % 100 < 3`, no RNG
## state anywhere.

const SkillLib := preload("res://scripts/player/skills.gd")
const SailingLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

## The locked per-officer-per-sea-day fire chance (§2.5).
const FIRE_PCT := 3
## The situation ids, one per flagship post (the closed `advice.*` table).
const SITUATIONS := {
	"pilot": "wind_band",
	"boatswain": "storm_sail",
	"gunner": "first_contact",
	"surgeon": "water_low",
	"carpenter": "durability_low",
	"cook": "morale_low",
}


## The session queue (transient, never saved — a fresh run and every load
## start empty, like `npc_port_log`).
static var _pending: Array = []


## The sea-day tick: roll every in-post flagship officer; a fire whose
## situation holds queues `advice.{post}.{situation}`. Returns the queue
## length after the tick (test seam).
static func day_tick(day: int) -> int:
	for post_id in SITUATIONS.keys():
		var holder := SkillLib.post_holder(str(post_id))
		if holder.is_empty():
			continue
		var roll: int = abs(hash("%d|%s" % [day, holder])) % 100
		if roll >= FIRE_PCT:
			continue
		if not _condition_holds(str(post_id)):
			continue
		_pending.append({
			"key": "advice.%s.%s" % [str(post_id), str(SITUATIONS[post_id])],
			"post": str(post_id),
			"officer_id": holder,
		})
	return _pending.size()


## The gunner's hint fires at the first contact round instead of a day tick
## (§2.5's trigger row). Returns the advice entry or {} — the world's
## encounter funnel queues it once per battle.
static func battle_start() -> Dictionary:
	var holder := SkillLib.post_holder("gunner")
	if holder.is_empty():
		return {}
	if _fired_battles.has(GameState.day):
		return {}
	_fired_battles[GameState.day] = true
	return {
		"key": "advice.gunner.first_contact",
		"post": "gunner",
		"officer_id": holder,
	}


static var _fired_battles: Dictionary = {}


## Drains the queue (the world scene renders each entry as a notice line).
static func drain() -> Array:
	var out: Array = _pending
	_pending = []
	return out


## Test seam.
static func reset() -> void:
	_pending = []
	_fired_battles = {}


## The post's situation condition (the `officer_posts.json` `advice`
## thresholds, mirrored here as the engine reads — water_low {days: 5},
## durability_low {pct: 50}, morale_low {threshold: 40}).
static func _condition_holds(post_id: String) -> bool:
	match post_id:
		"surgeon":
			# Fresh water ≤ 5 days remaining (§4.5: 1 unit waters 5 crew
			# for 1 day).
			var crew: int = maxi(1, FleetLib.total_crew())
			var water_days := 0
			for ship in GameState.fleet:
				if ship is Dictionary:
					water_days += int((ship as Dictionary).get("water", 0))
			return water_days * 5 <= crew * 5
		"carpenter":
			# Any hull below 50% of its type's durability.
			for ship in GameState.fleet:
				if not (ship is Dictionary):
					continue
				var ship_type: Dictionary = DataLoader.get_ship_type(
					str((ship as Dictionary).get("ship_type_id", "")))
				var max_dur := int(ship_type.get("durability", 0))
				if max_dur > 0 and int((ship as Dictionary).get("durability", 0)) * 2 < max_dur:
					return true
			return false
		"cook":
			return GameState.morale < 40
		"boatswain":
			# The sail plan is wrong for a storm day (§4.17: reefed is the
			# storm trim — anything else in a storm reads as wrong).
			return str(GameState.world.get("weather", "")) == "storm" \
				and str(GameState.world.get("sail_trim", "normal")) != "reefed"
		"pilot":
			# The wind band changes "tomorrow": the zone at the tile one
			# heading-step band ahead differs from the current zone (§4.14).
			var tile := GameState.world_tile()
			var here: String = SailingLib.weather_zone_for(tile)
			var ahead := tile + Vector2i(0, -12) # one degree north
			return SailingLib.weather_zone_for(ahead) != here
		_:
			return false
