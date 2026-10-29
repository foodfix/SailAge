class_name InnEngine
extends RefCounted
## Inn facility logic (S8): rest + harbor relief
## (docs/30-PORTS-AND-TRADE.md §4.6, docs/50-CHARACTER-AND-PROGRESSION.md
## §4.7 and §6, docs/20-WORLD-AND-SAILING.md §4.5/§4.8.1,
## docs/10-DATA-SCHEMA.md §5).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): every function
## is static and reads/mutates `GameState` through the singleton, so the inn's
## numbers are unit-testable headless.
##
## **The daily ledger is not duplicated here.** Every day this file charges
## runs through `SailingSim.advance_port_day()` (docs/20-* §4.3: "port actions
## advancing the day run the same ledger"), which pays wages, rolls weather,
## applies the in-port morale `+5` up to the port cap 80 and runs the §4.9 fail
## states. Rest therefore never touches morale itself — adding `+5` here would
## double-apply the ledger's own delta.

const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

# --- Rest (docs/30-* §4.6) --------------------------------------------------

## "Rest 3 days" — the fixed rest length.
const REST_DAYS := 3
## `10g × 3 = 30g`: the per-day lodging price the button shows.
const REST_COST_PER_DAY := 10
## Total price charged in one go when the rest starts (`10g × 3`).
##
## **Charged up front**, before the first ledger day, because the button's
## advertised price is the total (`inn.rest_cost` renders `{price}` = 30). The
## three ledger days then run exactly as any other port day: wages are still
## paid on top of the lodging (docs/30-* §4.6 "wages still paid"), so a rest
## costs `30g + 3 × daily wages` in total. This is the split the T15 tests
## assert separately.
const REST_COST := REST_DAYS * REST_COST_PER_DAY

# --- Harbor relief (docs/10-* §5, docs/50-* §4.7) ---------------------------

## Payout of one odd job (`gold += 100`).
const ODD_JOB_GOLD := 100
## Relief condition: the purse must be strictly below this. Amended from 100
## to the cheapest hull price (`latin`, 1,200g): gating on `gold < 100` while
## paying `+100` closes the gate after one job and makes the 1,200g hull
## unreachable, i.e. the fallback would *cause* the softlock it prevents.
## See docs/10-* §5 "Why the threshold is 1,200, not 100".
const RELIEF_GOLD_THRESHOLD := 1200

## Disabled-reason keys (docs/50-* §4.7 step 3, §6). `inn.odd_job.ineligible`
## is the generic disabled label; these name *why* the button is off.
const REASON_HAS_SHIP := "inn.odd_job.has_ship"
const REASON_NOT_BROKE := "inn.odd_job.not_broke"
const REASON_OFFICERS := "inn.odd_job.officers"


# --- Rest ------------------------------------------------------------------

## True when the purse covers the whole `10g × 3` up-front price.
static func can_rest() -> bool:
	return GameState.gold >= REST_COST


## "Rest 3 days" (docs/30-* §4.6):
##   1. charge the 30g lodging up front (one `gold_changed`);
##   2. run exactly [constant REST_DAYS] ledger days, in port, via
##      [method SailingSim.advance_port_day] — wages paid each day, in-port
##      morale `+5`/day capped at 80, weather/fail-state steps included.
##
## Returns false (state untouched: no gold, no day, no morale) when
## [method can_rest] is false. If the ledger ends the run mid-rest (a §4.9
## game over) the remaining days are skipped, exactly as the clock freeze in
## `SailingSim.advance_clock` does.
static func rest() -> bool:
	if not can_rest():
		return false
	GameState.add_gold(-REST_COST)
	for _rest_day in range(REST_DAYS):
		if SailingSimLib.is_game_over():
			break
		SailingSimLib.advance_port_day()
	return true


# --- Harbor relief (odd jobs) ----------------------------------------------

## docs/50-* §4.7 step 1: `gold < 1200 && fleet.is_empty()`, plus the §6
## "officers employed" lockout ("odd jobs are disabled while officers are
## employed (dismiss first)"). Evaluated on inn open and after each job; this
## single implementation is what both call sites read, so the button and the
## engine can never disagree.
static func odd_job_eligible() -> bool:
	return ineligible_reason().is_empty()


## `""` when an odd job is available, else the specific disabled-reason key.
## The reason order is fixed so a multi-fault state always renders the same
## label: no ship first (the defining relief state), then the purse, then the
## officer lockout.
static func ineligible_reason() -> String:
	if not GameState.fleet.is_empty():
		return REASON_HAS_SHIP
	if GameState.gold >= RELIEF_GOLD_THRESHOLD:
		return REASON_NOT_BROKE
	if CharacterLib.officer_count() > 0:
		return REASON_OFFICERS
	return ""


## One odd job (docs/10-* §5, docs/50-* §4.7 step 2): exactly `gold += 100`
## and exactly one ledger day. With no fleet there is no consumption, no crew
## and (by the lockout above) no officer wages, so the ledger's only visible
## effect is the day counter; the in-port `+5` morale row still runs and is
## untouched here (§4.7: "morale +5 still applies but is moot").
##
## Returns false (state untouched) when [method odd_job_eligible] is false.
static func work_odd_job() -> bool:
	if not odd_job_eligible():
		return false
	GameState.add_gold(ODD_JOB_GOLD)
	SailingSimLib.advance_port_day()
	return true
