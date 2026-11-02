class_name HailOptions
extends RefCounted
## Phase-8 W5-B — the at-sea hail: option builder + the single resolve funnel
## (docs/60-COMBAT.md §4.11.15 "Hail (talk)"; docs/80-UI-UX.md §4.10.2;
## docs/50-* §4.2 charisma/§4.3 negotiation; docs/30-* §4.2 "at-sea supply
## price source"; IMPLEMENT-Phase8.md §2.5).
##
## Pure statics, no node references (docs/90-ARCHITECTURE.md §4). The modal
## (`scenes/world/hail_modal.tscn`) renders what this module decides; the
## caller (`scripts/world/interactions.gd` / `world_map.gd`, W5-A/master)
## guarantees the Chebyshev ≤ 2 range and turns `made_hostile` into the
## §4.11.11.2 contact battle. Nothing here opens scenes or spawns battles.
##
## Contract (the W5-B pin, term by term per 60-* §4.11.15):
##
##   * `options_for(fleet) -> Array[Dictionary]` — one entry per talk option,
##     `{id, enabled, reason_key?}` plus additive display payloads
##     (`intel` / `unit_prices` / `max_qty` / `chance`), built from
##     **role × stance × skills**:
##       - `ask_rumours` — always enabled; stance ≥ +2 carries
##         `intel = true` (one free route/market intel, payload built from the
##         fleet's `dest_port_id` / route lanes — no RNG).
##       - `buy_supplies` — `trader`/`coaster` captains ONLY (the §4.1.1 rows
##         are the more specific pin; other roles get no supplies row at all).
##         Port supply price ×1.5, ×1.25 at stance ≥ +3, minus the negotiation
##         discount `floor(negotiation / 10)%` capped at the formula's own
##         −5-point reach (`50-*` §4.3.1 / `30-*` §4.10); every price floors
##         at 1g. **Price base pin:** the hailed fleet's `dest_port_id` port's
##         supply prices — its destination is deterministic — falling back to
##         the player's nearest known port when the fleet has none. The port
##         resolves the *seam*; the numbers themselves flow through
##         `TradeEngine.supplies_price` (the same plumbing the market uses —
##         supplies ignore every port factor by design, `30-*` §4.2).
##       - `intimidate` — every role may be intimidated (a coaster's ONLY
##         hostile verb: the picker gives coasters no attack, `60-*` §4.1.1).
##         `p = clamp(ours/(ours+theirs) + floor(COU/200)
##         − max(0, −stance) × 0.05, 0.05, 0.95)`.
##       - `befriend` — stance +1, once per captain per DAY (the session map
##         below; the disabled reason is `hail.befriend.used`).
##
##   * `resolve(option_id, fleet, qty := 0, roll := -1.0) -> Dictionary` —
##     the single funnel that APPLIES gold/cargo/fame/stance (testable
##     headless) and returns
##     `{ok, lines, gold_delta?, cargo_gained?, intel?, made_hostile?,
##     stance_delta?, fame_delta?}` where `lines` is a list of
##     `{key, values}` ui_strings pairs for the modal to `I18n.fmt`.
##     Success/failure effects:
##       - intimidate SUCCESS: the target hands over HALF its cargo (floor
##         per good) + pirate fame +5 + stance −1
##         (`Captains.STANCE_INTIMIDATE_WIN`).
##       - intimidate FAILURE: `made_hostile` (the caller opens the battle)
##         + stance −2 (`Captains.STANCE_INTIMIDATE_FAIL`). No cargo moves.
##
##   * **Roll contract.** `roll ∈ [0,1)` passed by the caller is honored
##     verbatim — the tests pass fixed rolls, the modal draws one from the
##     battle's seeded stream and passes it in ([method roll_seed] is the
##     §4.11.1 seed formula at the fleet's tile). The default −1.0 draws from
##     the same stream here, so a caller that forgets still stays seeded.
##
##   * **Supply qty semantics.** One stepper, one `qty`: buying supplies at
##     sea purchases `qty` provisions **and** the same `qty` water (a matched
##     bundle — the hailed trader stocks both). Each kind's cost is floored
##     once on its own full product (`30-*` §4.2 floor discipline).
##
## Strength pricing (the §4.11.5 card formulas via `battle_sim.gd` statics):
##   ours   = `BattleSim.player_duel_base()` + Σ escort captains' card duel
##            ratings (the officer in the `captain` post for that escort —
##            ship identity is `ship_type_id`, `20-*` `captain_ship_ids`).
##   theirs = the target fleet's captain card duel rating
##            (`swordplay + floor(courage/20)`); 0 without a card (live
##            fleets always carry a canon `captain_id`, W4-B).

const SkillsLib := preload("res://scripts/player/skills.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")

# --- Options -----------------------------------------------------------------

const OPTION_RUMOURS := "ask_rumours"
const OPTION_SUPPLIES := "buy_supplies"
const OPTION_INTIMIDATE := "intimidate"
const OPTION_BEFRIEND := "befriend"

# --- Locked constants (docs/60-* §4.11.15; docs/50-* §4.3.1) -----------------

## Hail range: Chebyshev ≤ 2 (the talk verb's guarantee; defended here).
const HAIL_RANGE := 2

## Roles whose captains sell supplies at sea (60-* §4.11.15: trader/coaster
## only; the §4.1.1 rows are the more specific pin).
const SUPPLY_ROLES: Array[String] = ["trader", "coaster"]

## Supply price multipliers, per-thousand: ×1.5 always; ×1.25 more at
## stance ≥ +3 (folded into one ×1.875 per-thousand product below).
const SUPPLY_MULT_UNITS := 1500
const SUPPLY_WARM_STANCE := 3
const SUPPLY_WARM_MULT_UNITS := 1250

## Negotiation discount: `floor(skill / 10)` points, capped at the formula's
## own reach of −5 points (50-* §4.3.1 magnitude / 30-* §4.10).
const NEGOTIATION_DIVISOR := 10
const NEGOTIATION_CAP_POINTS := 5

## Intimidate: `p = clamp(share + floor(COU/200) − max(0,−stance)×0.05,
## 0.05, 0.95)` (60-* §4.11.15).
const INTIMIDATE_P_MIN := 0.05
const INTIMIDATE_P_MAX := 0.95
const COURAGE_DIVISOR := 200.0
const STANCE_PENALTY_PER_POINT := 0.05

## Intimidate SUCCESS: half the target's cargo (floor per good) + pirate
## fame +5 (60-* §4.11.15). The stance deltas are Captains' shared constants.
const INTIMIDATE_CARGO_SHARE := 2
const INTIMIDATE_FAME := 5

## Free intel gate: stance ≥ +2 (60-* §4.11.15).
const INTEL_STANCE := 2


# --- Session state -----------------------------------------------------------

## Befriend once per captain per day — session-transient (`{captain_id: day}`),
## never saved. [method reset_session] clears it (a fresh sim / the suites).
static var _befriended_today: Dictionary = {}


static func reset_session() -> void:
	_befriended_today = {}


## True when `captain_id` was befriended on game-day `day` (or any day ≥ it —
## the map stores the last befriend day).
static func befriended_on(captain_id: String, day: int) -> bool:
	return int(_befriended_today.get(captain_id, -1)) == int(day)


# --- Reading the fleet -------------------------------------------------------

## The fleet's canon captain card (`{}` without one) — read through
## `BattleSim.captain_canon_card`, the §4.11.5 canon seam (the DataLoader
## index, the file fallback, and the suites' card doubles all resolve here).
static func captain_card_of(fleet: Dictionary) -> Dictionary:
	return BattleSimLib.captain_canon_card(str(fleet.get("captain_id", "")))


## The captain's identified display name; "陌生船队 / Unidentified fleet"
## (`interact.unknown_name`) when the card does not resolve.
static func display_name(fleet: Dictionary) -> String:
	var card := captain_card_of(fleet)
	if card.is_empty() or not (card.get("name", {}) is Dictionary):
		return I18n.t_key("interact.unknown_name")
	return I18n.t(card.get("name", {}))


## The fleet's stance (0 for an unmet captain).
static func stance_of(fleet: Dictionary) -> int:
	return CaptainsLib.stance(str(fleet.get("captain_id", "")))


## Chebyshev ≤ [constant HAIL_RANGE] between the player tile
## (`GameState.world.position`) and the fleet cell.
static func in_range(fleet: Dictionary) -> bool:
	var world_pos = GameState.world.get("position", {}) \
		if GameState.world is Dictionary else {}
	if not (world_pos is Dictionary) or (world_pos as Dictionary).is_empty():
		return false
	var cell = fleet.get("cell", {})
	if not (cell is Dictionary) or (cell as Dictionary).is_empty():
		return false
	var dx: int = int((world_pos as Dictionary).get("x", 0)) \
		- int((cell as Dictionary).get("x", 0))
	var dy: int = int((world_pos as Dictionary).get("y", 0)) \
		- int((cell as Dictionary).get("y", 0))
	return maxi(absi(dx), absi(dy)) <= HAIL_RANGE


# --- Supply pricing (docs/30-* §4.2 "at-sea supply price source") ------------

## The §6.1 projection (`ocean_layers.gd` grid — 12 tiles/degree), the same
## re-derivation `chart_view.gd` uses.
static func _tiles_per_degree() -> float:
	return float(OceanLayersLib.GRID_WIDTH) / 360.0


static func _port_tile(port: Dictionary) -> Vector2i:
	var tpd := _tiles_per_degree()
	var lon := float(port.get("lon", 0.0))
	var lat := float(port.get("lat", 0.0))
	return Vector2i(
		int(floor((lon + 180.0) * tpd)) % OceanLayersLib.GRID_WIDTH,
		clampi(int(floor((90.0 - lat) * tpd)), 0, OceanLayersLib.GRID_HEIGHT - 1))


## **The price base pin.** The hailed fleet's `dest_port_id` port (its
## destination — deterministic); the player's nearest known port (tile-space
## Chebyshev from the player tile, port id ascending on ties) when the fleet
## has none; "" when no port resolves at all.
static func price_base_port(fleet: Dictionary) -> String:
	var dest := str(fleet.get("dest_port_id", ""))
	if not dest.is_empty() and not DataLoader.get_port(dest).is_empty():
		return dest
	var world_pos = GameState.world.get("position", {}) \
		if GameState.world is Dictionary else {}
	if not (world_pos is Dictionary) or (world_pos as Dictionary).is_empty():
		return ""
	var here := Vector2i(int((world_pos as Dictionary).get("x", 0)),
		int((world_pos as Dictionary).get("y", 0)))
	var best_id := ""
	var best_dist := -1
	var known: Array = GameState.known_ports if GameState.known_ports is Array \
		else []
	var ids: Array[String] = []
	for value in known:
		ids.append(str(value))
	ids.sort()
	for port_id in ids:
		var port: Dictionary = DataLoader.get_port(port_id)
		if port.is_empty():
			continue
		var dist: int = maxi(absi(here.x - _port_tile(port).x),
			absi(here.y - _port_tile(port).y))
		if best_dist < 0 or dist < best_dist:  # ids pre-sorted → ties keep the lower id
			best_dist = dist
			best_id = port_id
	return best_id


## The negotiation discount points `min(floor(effective_negotiation / 10), 5)`
## (the §2.2 magnitude — the cap is the negotiation formula's own reach).
static func negotiation_discount_points() -> int:
	var skill := SkillsLib.effective_skill("negotiation")
	@warning_ignore("integer_division")
	return mini(skill / NEGOTIATION_DIVISOR, NEGOTIATION_CAP_POINTS)


## The folded per-thousand price units for a hail purchase at `stance`:
## ×1.5 (1500), ×1.875 (1875) at stance ≥ +3 — the stance term folded before
## the negotiation term so the whole product floors exactly once.
static func _supply_price_units(stance: int) -> int:
	var units := SUPPLY_MULT_UNITS
	if stance >= SUPPLY_WARM_STANCE:
		units = units * SUPPLY_WARM_MULT_UNITS / 1000
	return units


## Per-unit supply price of `kind` ("provisions" | "water") at the hail's
## price base port, floored once and floored at 1g (`30-*` §4.2). The BASE
## itself comes through `_supply_base_price` — the market's supply plumbing.
static func supply_unit_price(fleet: Dictionary, kind: String) -> int:
	var base := _supply_base_price(price_base_port(fleet), kind)
	var units := _supply_price_units(stance_of(fleet)) \
		* (1000 - negotiation_discount_points() * 10)
	@warning_ignore("integer_division")
	return maxi(TradeEngineLib.MIN_PRICE, base * units / 1000000)


## Both unit prices, `{provisions: n, water: m}`.
static func supplies_unit_prices(fleet: Dictionary) -> Dictionary:
	return {
		"provisions": supply_unit_price(fleet, "provisions"),
		"water": supply_unit_price(fleet, "water"),
	}


## The full charge for a `qty` bundle (`qty` provisions + `qty` water): each
## kind's total is floored once on its own full product, never per unit
## (`30-*` §4.2 floor discipline — the ×1.25 stance term is observable in the
## totals even where the unit floor hides it).
static func supplies_pair_cost(fleet: Dictionary, qty: int) -> int:
	var units := _supply_price_units(stance_of(fleet)) \
		* (1000 - negotiation_discount_points() * 10)
	var total := 0
	for kind in ["provisions", "water"]:
		var base := _supply_base_price(price_base_port(fleet), kind)
		@warning_ignore("integer_division")
		total += maxi(TradeEngineLib.MIN_PRICE,
			int(qty) * base * units / 1000000)
	return total


## The supply BASE price at `port_id` — `TradeEngine.supplies_price`, the same
## plumbing the market uses. The port is validated, never priced: supplies
## ignore every port factor by design (`30-*` §4.2), so the resolved base port
## pins the seam (and keeps the nearest-known fallback deterministic) rather
## than moving the number.
static func _supply_base_price(port_id: String, kind: String) -> int:
	if not port_id.is_empty() and DataLoader.get_port(port_id).is_empty():
		push_error("HailOptions: unresolvable price base port '%s'" % port_id)
	return TradeEngineLib.supplies_price(kind)


## The stepper ceiling: the largest bundle the purse can pay **and** the hold
## can carry (2 × qty cargo units — provisions and water each occupy 1 unit,
## `20-*` §4.10).
static func supplies_max_qty(fleet: Dictionary) -> int:
	var one := supplies_pair_cost(fleet, 1)
	if one <= 0:
		return 0
	@warning_ignore("integer_division")
	var affordable := GameState.gold / one
	var free := FleetLib.fleet_free()
	@warning_ignore("integer_division")
	return maxi(0, mini(affordable, free / 2))


# --- Strength pricing (docs/60-* §4.11.5 card formulas) ----------------------

## The player's priced strength: flagship duel base + Σ escort captains'
## card duel ratings. Escort captain = the officer in the `captain` post whose
## `ship_id` matches the escort's `ship_type_id` (ship identity, `20-*`
## §4.4). Captain-less escorts add 0 (the §4.11.5 escort branch).
static func player_strength() -> int:
	var ours := BattleSimLib.player_duel_base()
	var captained: Dictionary = {}
	var states: Dictionary = GameState.officer_states \
		if GameState.officer_states is Dictionary else {}
	for officer_id in states:
		var state = states[officer_id]
		if not (state is Dictionary):
			continue
		if str((state as Dictionary).get("post_id", "")) != "captain":
			continue
		var ship_id := str((state as Dictionary).get("ship_id", ""))
		if ship_id.is_empty():
			continue
		var officer: Dictionary = DataLoader.get_officer(str(officer_id))
		if officer.is_empty():
			continue
		captained[ship_id] = BattleSimLib.card_duel_rating(officer)
	for index in range(1, GameState.fleet.size()):
		var ship = GameState.fleet[index]
		if not (ship is Dictionary):
			continue
		var ship_id := str((ship as Dictionary).get("ship_type_id", ""))
		ours += int(captained.get(ship_id, 0))
	return ours


## The target fleet's priced strength: its captain card duel rating
## (`swordplay + floor(courage/20)`, §4.11.5); 0 without a card.
static func target_strength(fleet: Dictionary) -> int:
	return BattleSimLib.card_duel_rating(captain_card_of(fleet))


## The intimidate success chance (60-* §4.11.15):
## `clamp(ours/(ours+theirs) + floor(COU/200) − max(0,−stance)×0.05, .05, .95)`.
static func intimidate_chance(fleet: Dictionary) -> float:
	var ours := float(player_strength())
	var theirs := float(target_strength(fleet))
	var total := ours + theirs
	var share := ours / total if total > 0.0 else 0.0
	var courage_term := floorf(float(CharacterLib.attribute("courage"))
		/ COURAGE_DIVISOR)
	var stance := stance_of(fleet)
	var penalty := maxf(0.0, float(-stance)) * STANCE_PENALTY_PER_POINT
	return clampf(share + courage_term - penalty,
		INTIMIDATE_P_MIN, INTIMIDATE_P_MAX)


# --- The roll (docs/60-* §4.11.1 seed formula, reused at the fleet's tile) ---

## The hail roll's seed: the §4.11.1 battle seed formula over (day, the
## fleet's tile, gold, fleet size) — a closed form, so the modal's draw is
## reproducible and the tests can predict it without touching RNG state.
static func roll_seed(fleet: Dictionary) -> int:
	var cell = fleet.get("cell", {})
	var tile := Vector2i.ZERO
	if cell is Dictionary:
		tile = Vector2i(int((cell as Dictionary).get("x", 0)),
			int((cell as Dictionary).get("y", 0)))
	return BattleSimLib.battle_seed_formula(int(GameState.day), tile,
		int(GameState.gold), GameState.fleet.size())


## One draw from the seeded stream above, ∈ [0, 1).
static func draw_roll(fleet: Dictionary) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = roll_seed(fleet)
	return rng.randf()


# --- Option builder ----------------------------------------------------------

## The talk options for `fleet`, in render order: rumours, supplies (trader/
## coaster only), intimidate, befriend. Out-of-range hails build NOTHING
## (the talk verb guarantees Chebyshev ≤ 2 — defended here).
static func options_for(fleet: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not in_range(fleet):
		push_error("HailOptions.options_for: fleet %s out of hail range"
			% str(fleet.get("id", "?")))
		return out
	var stance := stance_of(fleet)

	# Ask rumours — always enabled; stance ≥ +2 grants one free intel.
	out.append({
		"id": OPTION_RUMOURS,
		"enabled": true,
		"intel": stance >= INTEL_STANCE,
	})

	# Buy supplies — trader/coaster captains only.
	var role := str(fleet.get("role", ""))
	if role in SUPPLY_ROLES:
		var prices := supplies_unit_prices(fleet)
		out.append({
			"id": OPTION_SUPPLIES,
			"enabled": true,
			"unit_prices": prices,
			"max_qty": supplies_max_qty(fleet),
		})

	# Intimidate — every role (a coaster's ONLY hostile verb).
	out.append({
		"id": OPTION_INTIMIDATE,
		"enabled": true,
		"chance": intimidate_chance(fleet),
	})

	# Befriend — once per captain per day.
	var captain_id := str(fleet.get("captain_id", ""))
	var befriended := befriended_on(captain_id, int(GameState.day))
	var befriend: Dictionary = {
		"id": OPTION_BEFRIEND,
		"enabled": not befriended,
	}
	if befriended:
		befriend["reason_key"] = "hail.befriend.used"
	out.append(befriend)
	return out


# --- The resolve funnel ------------------------------------------------------

## Applies one hail option and returns the render/apply payload (see the
## header for the shape). `qty` is the supplies bundle size; `roll ∈ [0,1)`
## decides an intimidate attempt verbatim (the default −1.0 draws from the
## seeded stream). Unknown options and out-of-range hails resolve
## `{ok: false}` with empty lines — nothing is applied.
static func resolve(option_id: String, fleet: Dictionary, qty: int = 0,
		roll: float = -1.0) -> Dictionary:
	if not in_range(fleet):
		return {"ok": false, "lines": []}
	match option_id:
		OPTION_RUMOURS:
			return _resolve_rumours(fleet)
		OPTION_SUPPLIES:
			return _resolve_supplies(fleet, qty)
		OPTION_INTIMIDATE:
			return _resolve_intimidate(fleet, roll)
		OPTION_BEFRIEND:
			return _resolve_befriend(fleet)
		_:
			return {"ok": false, "lines": []}


## Ask rumours — free. Stance ≥ +2 appends one free route/market intel: the
## fleet's current lane/dest hint, built from `dest_port_id` / route lanes
## (no RNG).
static func _resolve_rumours(fleet: Dictionary) -> Dictionary:
	var name := display_name(fleet)
	var lines: Array = [{"key": "hail.rumours.result", "values": {"name": name}}]
	var out := {"ok": true, "lines": lines}
	if stance_of(fleet) >= INTEL_STANCE:
		lines.append({
			"key": "hail.rumours.result_intel",
			"values": {"name": name},
		})
		out["intel"] = _intel_payload(fleet)
	return out


## The intel payload: the fleet's destination port and its current route
## lanes (read-only seam — what the captain's table points at).
static func _intel_payload(fleet: Dictionary) -> Dictionary:
	var route = fleet.get("route", {}) if fleet.get("route", {}) is Dictionary \
		else {}
	var lanes: Array[String] = []
	var raw_lanes: Array = (route as Dictionary).get("lanes", []) \
		if (route as Dictionary).get("lanes", []) is Array else []
	for lane in raw_lanes:
		lanes.append(str(lane))
	return {
		"dest_port_id": str(fleet.get("dest_port_id", "")),
		"lanes": lanes,
	}


## Buy supplies — `qty` provisions + `qty` water at the hail prices. Refused
## (nothing applied) for a non-positive bundle, a short purse or a full hold;
## the modal caps the stepper at [method supplies_max_qty] up front.
static func _resolve_supplies(fleet: Dictionary, qty: int) -> Dictionary:
	if qty <= 0:
		return {"ok": false, "lines": []}
	var cost := supplies_pair_cost(fleet, qty)
	if cost > GameState.gold or 2 * qty > FleetLib.fleet_free():
		return {"ok": false, "lines": []}
	GameState.add_gold(-cost)
	var gained := {
		"provisions": FleetLib.add_supplies("provisions", qty),
		"water": FleetLib.add_supplies("water", qty),
	}
	FleetLib.notify_changed()
	return {
		"ok": true,
		"lines": [{
			"key": "hail.supplies.result",
			"values": {"qty": qty},
		}],
		"gold_delta": -cost,
		"cargo_gained": gained,
	}


## Intimidate. `roll ∈ [0,1)` decides verbatim (the default −1.0 draws from
## the seeded stream, [method draw_roll]). SUCCESS: the target hands over
## half its cargo (floor per good) — routed goods through the fleet hold,
## supplies keys through the supplies pools — pirate fame +5, stance −1.
## FAILURE: `made_hostile` (the caller opens the §4.11.11.2 battle) and
## stance −2; nothing moves.
static func _resolve_intimidate(fleet: Dictionary, roll: float) -> Dictionary:
	var chance := intimidate_chance(fleet)
	var draw := roll if (roll >= 0.0 and roll < 1.0) else draw_roll(fleet)
	if draw >= chance:
		# An executed outcome, not a refusal — `ok` stays true and
		# `made_hostile` tells the caller to open the battle.
		var stance := _apply_stance(fleet, CaptainsLib.STANCE_INTIMIDATE_FAIL)
		return {
			"ok": true,
			"lines": [{
				"key": "hail.intimidate.lose",
				"values": {"name": display_name(fleet)},
			}],
			"made_hostile": true,
			"stance_delta": stance,
			"chance": chance,
		}
	var gained := _take_half_cargo(fleet)
	var fame_before := FameLib.value()
	FameLib.add(INTIMIDATE_FAME)
	var fame := FameLib.value() - fame_before
	var stance := _apply_stance(fleet, CaptainsLib.STANCE_INTIMIDATE_WIN)
	return {
		"ok": true,
		"lines": [{
			"key": "hail.intimidate.win",
			"values": {"name": display_name(fleet)},
		}],
		"cargo_gained": gained,
		"fame_delta": fame,
		"stance_delta": stance,
		"chance": chance,
	}


## Half the target's cargo, floor per good (`60-*` §4.11.15). The handed-over
## goods leave the target dict and enter the player's fleet up to free
## capacity; `cargo_gained` reports what actually moved. Provisions/water
## keys route through the supplies pools (they are not trade goods).
static func _take_half_cargo(fleet: Dictionary) -> Dictionary:
	var cargo = fleet.get("cargo", {}) if fleet.get("cargo", {}) is Dictionary \
		else {}
	var gained: Dictionary = {}
	for good_id in cargo.keys():
		good_id = str(good_id)
		var held := int(cargo[good_id])
		if held <= 0:
			continue
		@warning_ignore("integer_division")
		var half := held / INTIMIDATE_CARGO_SHARE  # floor per good
		if half <= 0:
			continue
		var stored := 0
		if good_id in FleetLib.SUPPLY_KINDS:
			stored = FleetLib.add_supplies(good_id, half)
		else:
			stored = FleetLib.add_goods(good_id, half)
		if stored <= 0:
			continue
		cargo[good_id] = held - stored
		gained[good_id] = stored
	FleetLib.notify_changed()
	return gained


## Befriend — stance +1, once per captain per day (the session map). A repeat
## on the same day resolves `{ok: false}` with the used reason and applies
## nothing.
static func _resolve_befriend(fleet: Dictionary) -> Dictionary:
	var captain_id := str(fleet.get("captain_id", ""))
	var day := int(GameState.day)
	if befriended_on(captain_id, day):
		return {
			"ok": false,
			"lines": [{"key": "hail.befriend.used", "values": {}}],
		}
	_befriended_today[captain_id] = day
	var stance := _apply_stance(fleet, CaptainsLib.STANCE_BEFRIEND)
	return {
		"ok": true,
		"lines": [{
			"key": "hail.befriend.result",
			"values": {"name": display_name(fleet)},
		}],
		"stance_delta": stance,
	}


## Applies a stance delta through `Captains.adjust_stance` (the shared
## constants' funnel) when the fleet carries a captain id; an id-less fixture
## skips the state write and reports the raw delta.
static func _apply_stance(fleet: Dictionary, delta: int) -> int:
	var captain_id := str(fleet.get("captain_id", ""))
	if captain_id.is_empty():
		return delta
	return CaptainsLib.adjust_stance(captain_id, delta)
