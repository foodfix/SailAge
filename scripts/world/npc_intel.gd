class_name NpcIntel
extends RefCounted
## Captain sightings, wanted posters, the paid reveal and tavern rumor rows
## (Phase 5 task L) — docs/80-UI-UX.md §4.7.8 (THE pin), docs/60-COMBAT.md
## §4.11.11.4, docs/30-PORTS-AND-TRADE.md §4.5 (event telegraphs).
##
## **Pure** in the house sense (docs/90-* §4): RefCounted, static functions,
## no node references, headless-testable. It reads `GameState.npc_fleets`
## through a throwaway [NpcFleets] index per spatial query (a fresh instance
## builds its bucket index from the live array, so a save loaded into the
## process can never be answered from a stale index) and never mutates
## anything — the paid reveal's gold charge is the *screen's* action.
##
## **Seeded rolls** (docs/80-* §4.7.8, IMPLEMENT-Phase5 decision 9): the
## facility and presence rolls are seeded from
## `(fleet_id, port_id, arrival_day)` — stable within one visit-day (no
## flicker on re-open), re-rolled on the next visit (the next arrival day).
## A hunter is **palace-only**: it never rolls an alternate facility.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")

## Facility ids (docs/80-* §4.7.8 surfaces: market S5, tavern S7, inn S8,
## palace S13 bounty board).
const FACILITY_MARKET := "market"
const FACILITY_TAVERN := "tavern"
const FACILITY_INN := "inn"
const FACILITY_PALACE := "palace"
## The uniform alternate set of the 60/40 facility roll (any docked fleet is
## inn-eligible; market and tavern stay plausible for every national role).
const FACILITY_ALTERNATES: Array[String] = [FACILITY_MARKET, FACILITY_TAVERN,
	FACILITY_INN]

## §4.7.8 facility roll: 60% the role's primary facility.
const FACILITY_PRIMARY_CHANCE := 0.6
## §4.7.8 presence roll: 75% sightable that day, else gone ashore.
const PRESENT_CHANCE := 0.75
## §4.7.8 wanted posters: pirate/privateer captains within Chebyshev 40 of
## the visited port; the paid reveal costs 20g.
const POSTER_RADIUS := 40
const REVEAL_COST := 20
## Tavern rumor rows (§4.7.8): live fleets within Chebyshev 40.
const RUMOR_RADIUS := 40


# --- The seeded rolls (docs/80-* §4.7.8) -------------------------------------

## The visit seed base: `(fleet_id, port_id, arrival_day)` hashed through the
## module's formula family — stable within the visit, new next visit.
static func _visit_seed(fleet_id: String, port_id: String,
		arrival_day: int) -> int:
	return hash("%s|%s|%d" % [fleet_id, port_id, arrival_day])


## The day a docked fleet arrived: its dwell window's start
## (`dwell_until_day − DWELL_DAYS`). 0 when unknown (never docked).
static func arrival_day_of(fleet: Dictionary) -> int:
	return maxi(0, int(fleet.get("dwell_until_day", 0))
		- NpcFleetsLib.DWELL_DAYS)


## The role's primary facility (docs/80-* §4.7.8): trader→market,
## coaster/patrol/courier/privateer→tavern, hunter→palace bounty board, any
## docked fleet→inn eligible. A treasure fleet is the merchant family
## (market — the §4.7.8 map lists no treasure row; reported task-owned gap).
static func primary_facility(role: String) -> String:
	match role:
		NpcFleetsLib.TRADER, NpcFleetsLib.TREASURE:
			return FACILITY_MARKET
		NpcFleetsLib.COASTER, NpcFleetsLib.PATROL, NpcFleetsLib.COURIER, \
				NpcFleetsLib.PRIVATEER, NpcFleetsLib.PIRATE:
			return FACILITY_TAVERN
		NpcFleetsLib.HUNTER:
			return FACILITY_PALACE
	return FACILITY_TAVERN


## The facility a docked fleet's captain is sighted at (the seeded 60/40
## roll): 60% the primary, else a uniform alternate from
## {market, tavern, inn}. A hunter is palace-only — never anywhere else.
static func facility_of(fleet: Dictionary, port_id: String) -> String:
	var role := str(fleet.get("role", ""))
	if role == NpcFleetsLib.HUNTER:
		return FACILITY_PALACE
	var rng := RandomNumberGenerator.new()
	rng.seed = _visit_seed(str(fleet.get("id", "")), port_id,
		arrival_day_of(fleet)) * 31 + hash("facility")
	if rng.randf() < FACILITY_PRIMARY_CHANCE:
		return primary_facility(role)
	return FACILITY_ALTERNATES[rng.randi_range(0, FACILITY_ALTERNATES.size() - 1)]


## The presence roll (same seed family): 75% sightable that day, else gone
## ashore — absent from every facility that day.
static func is_present(fleet: Dictionary, port_id: String) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = _visit_seed(str(fleet.get("id", "")), port_id,
		arrival_day_of(fleet)) * 31 + hash("presence")
	return rng.randf() < PRESENT_CHANCE


# --- Docked fleets & sightings ----------------------------------------------

## Fleets docked at `port_id` right now (on its berth tile, dwell active).
## One bucket-index query.
static func docked_fleets(port_id: String) -> Array:
	var cell := DataLoader.port_cell(port_id)
	if cell.x < 0:
		return []
	var sim := NpcFleetsLib.new()
	var out: Array = []
	for fleet in sim._within(cell, 0):
		if int(fleet.get("dwell_until_day", 0)) > GameState.day:
			out.append(fleet)
	out.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("id", "")) \
			< str((b as Dictionary).get("id", "")))
	return out


## The captains sighted at `port_id`'s `facility` (docs/80-* §4.7.8): docked,
## present, and their seeded facility is this one. Rows are
## `{fleet, id, name, role, nation_id}` sorted by fleet id.
static func sightings(port_id: String, facility: String) -> Array:
	var out: Array = []
	for fleet in docked_fleets(port_id):
		if not is_present(fleet, port_id):
			continue
		if facility_of(fleet, port_id) != facility:
			continue
		out.append({
			"fleet": fleet,
			"id": str(fleet.get("id", "")),
			"name": NpcFleetsLib.captain_name(fleet),
			"role": str(fleet.get("role", "")),
			"nation_id": str(fleet.get("nation_id", "")),
		})
	return out


## The docked captains that failed today's presence roll — "gone ashore",
## absent from every facility (docs/80-* §4.7.8): `{id, name}` rows.
static func gone_ashore(port_id: String) -> Array:
	var out: Array = []
	for fleet in docked_fleets(port_id):
		if is_present(fleet, port_id):
			continue
		out.append({"id": str(fleet.get("id", "")),
			"name": NpcFleetsLib.captain_name(fleet)})
	return out


# --- Wanted posters & the paid reveal (docs/80-* §4.7.8) ---------------------

## Wanted posters at `port_id`: every at-sea `pirate`/`privateer` captain
## within Chebyshev [constant POSTER_RADIUS] of the port (wrap-aware, bucket
## index). Rows: `{id, name, tier, nearest_port, nearest_port_name,
## reward_gold, cell}` sorted by fleet id. A named captain's tier comes from
## `named_pirates.json` (`70-*` §4.5 tiers 1–3); an unnamed one has no
## poster-worthy identity, so only named captains post.
static func wanted_posters(port_id: String) -> Array:
	var cell := DataLoader.port_cell(port_id)
	if cell.x < 0:
		return []
	var sim := NpcFleetsLib.new()
	var out: Array = []
	for fleet in sim._within(cell, POSTER_RADIUS):
		var role := str(fleet.get("role", ""))
		if role != NpcFleetsLib.PIRATE and role != NpcFleetsLib.PRIVATEER:
			continue
		if int(fleet.get("dwell_until_day", 0)) > GameState.day:
			continue  # at-sea posters only (a docked captain needs no reveal)
		if not NpcFleetsLib.is_named_captain(fleet):
			continue  # only a named captain posts (§4.11.11.4)
		var near := nearest_port(NpcFleetsLib.position_of(fleet))
		var tier := NpcFleetsLib.named_tier_of(fleet)
		out.append({
			"id": str(fleet.get("id", "")),
			"name": NpcFleetsLib.captain_name(fleet),
			"tier": tier,
			"nearest_port": near,
			"nearest_port_name": _port_name(near),
			"reward_gold": int(QuestGenLib.BOUNTY_GOLD_BY_TIER.get(tier, 5000)),
			"cell": NpcFleetsLib.position_of(fleet),
		})
	out.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("id", "")) \
			< str((b as Dictionary).get("id", "")))
	return out


## The paid reveal (docs/80-* §4.7.8): the poster's **exact live position** —
## tile + nearest port — as rumor data. Text only; the screen charges the
## 20g and formats `captain.reveal.text`. `{}` for an unknown/fleet-less id.
static func reveal_position(fleet_id: String) -> Dictionary:
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		if str((fleet as Dictionary).get("id", "")) != fleet_id:
			continue
		var cell := NpcFleetsLib.position_of(fleet)
		var near := nearest_port(cell)
		return {
			"id": fleet_id,
			"name": NpcFleetsLib.captain_name(fleet),
			"cell": cell,
			"nearest_port": near,
			"nearest_port_name": _port_name(near),
		}
	return {}


# --- Rumor row sources (docs/80-* §4.7.8, docs/30-* §4.5) --------------------

## Tavern rumor rows at `port_id`, in display order: demand-event telegraphs
## first (information is profit), then the port-traffic log's arrivals and
## departures within 3 days (`GameState.npc_port_log`, §4.11.11.4 task L
## pin), then live fleets within [constant RUMOR_RADIUS]. Rows:
## `{kind: "event"|"departed"|"arrived"|"fleet", …}` — the screen formats
## each kind with its ui_strings key.
static func rumor_rows(port_id: String) -> Array:
	var out: Array = []
	for entry in EconomyLib.event_telegraphs(port_id):
		out.append({
			"kind": "event",
			"port_id": str((entry.get("instance") as Dictionary)
				.get("port_id", "")),
			"port_name": _port_name(str((entry.get("instance") as Dictionary)
				.get("port_id", ""))),
			"event_name": I18n.t((entry.get("template") as Dictionary)
				.get("name", {})),
		})
	var cell := DataLoader.port_cell(port_id)
	# Departures/arrivals at this port within 3 days (§4.7.8): the ecology's
	# transient traffic log, newest last.
	var traffic: Array = []
	for record in GameState.npc_port_log:
		if not (record is Dictionary):
			continue
		if str((record as Dictionary).get("port_id", "")) != port_id:
			continue
		if int((record as Dictionary).get("day", 0)) < GameState.day - 3:
			continue
		traffic.append(record)
	for record in traffic:
		var kind := str((record as Dictionary).get("kind", ""))
		if kind == "arrival":
			out.append({"kind": "arrived",
				"id": str((record as Dictionary).get("fleet_id", "")),
				"role": str((record as Dictionary).get("role", "")),
				"nation_id": str((record as Dictionary).get("nation_id", "")),
				"day": int((record as Dictionary).get("day", 0))})
		elif kind == "departure":
			var fleet := _fleet_by_id(
				str((record as Dictionary).get("fleet_id", "")))
			var dest := str(fleet.get("dest_port_id", ""))
			out.append({"kind": "departed",
				"id": str((record as Dictionary).get("fleet_id", "")),
				"role": str((record as Dictionary).get("role", "")),
				"nation_id": str((record as Dictionary).get("nation_id", "")),
				"dest_port": dest,
				"dest_port_name": _port_name(dest),
				"day": int((record as Dictionary).get("day", 0))})
	if cell.x < 0:
		return out
	var sim := NpcFleetsLib.new()
	var spoken_for: Dictionary = {}
	for entry in traffic:
		spoken_for[str((entry as Dictionary).get("fleet_id", ""))] = true
	for fleet in sim._within(cell, RUMOR_RADIUS):
		var id := str(fleet.get("id", ""))
		if spoken_for.has(id):
			continue  # already reported through the traffic log
		spoken_for[id] = true
		var fleet_cell := NpcFleetsLib.position_of(fleet)
		var near := nearest_port(fleet_cell)
		out.append({"kind": "fleet", "id": id,
			"role": str(fleet.get("role", "")),
			"nation_id": str(fleet.get("nation_id", "")),
			"nearest_port": near,
			"nearest_port_name": _port_name(near)})
	return out


## A live fleet dict by id (`{}` when gone — a departed fleet may have died
## since its log entry).
static func _fleet_by_id(fleet_id: String) -> Dictionary:
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary \
				and str((fleet as Dictionary).get("id", "")) == fleet_id:
			return fleet
	return {}


# --- Helpers -----------------------------------------------------------------

## The port whose berth tile is nearest `cell` (Chebyshev, wrap-aware; ties
## by port id) — the reveal text's "near {port}".
static func nearest_port(cell: Vector2i) -> String:
	var best := ""
	var best_distance := -1
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty():
			continue
		var distance := NpcFleetsLib.chebyshev(cell,
			DataLoader.port_cell(port_id))
		if best_distance < 0 or distance < best_distance \
				or (distance == best_distance and port_id < best):
			best = port_id
			best_distance = distance
	return best


static func _port_name(port_id: String) -> String:
	if port_id.is_empty():
		return "-"
	return I18n.t(DataLoader.get_port(port_id).get("name", {}))
