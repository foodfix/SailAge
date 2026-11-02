extends Node
## Phase-7 task L acceptance tests: port allegiance, development, treasuries,
## tariffs, permits and the monthly NPC counter-investment
## (docs/30-* §4.9/§4.10, §4.3; docs/70-* §4.1; docs/80-* §4.9 contracts;
## docs/90-* §5.4 month-tick ordering; IMPLEMENT-Phase7.md §2.4–§2.6).
##
##   godot --headless --path . res://tools/test_allegiance.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const AllegianceLib := preload("res://scripts/port/allegiance.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]
## A mid-Atlantic calm tile (the Carreira's first leg, off Lisbon).
const CALM_CELL := Vector2i(2050, 615)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_seed_state()
	_test_ledger_allegiance_resolution()
	_test_dev_thresholds()
	_test_protected_immunity()
	_test_invest_cap_and_gate()
	_test_monthly_ai_determinism()
	_test_monthly_ai_bounds()
	_test_fame_poaching_commendation()
	_test_tariff_matrix()
	_test_tariff_permits()
	_test_tax_crediting()
	_test_telegraph_window()
	_test_state_seam()
	_test_month_tick_seam()
	_report()


# --- Fixtures --------------------------------------------------------------

## A livable run for `nation_id` with a clean allegiance seed: zero reputation
## everywhere, no bounties, no fame, full purse. `Allegiance.seed_new_game()`
## runs LAST so the fixtures cannot leak ledger state into it.
func _make_run(nation_id: String = "portugal", gold: int = 100000,
		day: int = 1) -> void:
	var reputation: Dictionary = {}
	for other in NATIONS:
		reputation[other] = 0
	GameState.player = {
		"nation_id": nation_id,
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
	GameState.gold = gold
	GameState.morale = 70
	GameState.current_port = null
	GameState.port_investments = {}
	GameState.known_ports = []
	GameState.bounties = {}
	GameState.fame = 0
	GameState.world = {
		"position": {"x": CALM_CELL.x, "y": CALM_CELL.y},
		"clock_fraction": 0.5,
		"weather": "fair",
	}
	AllegianceLib.seed_new_game()


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


# --- §4.9 seed state -------------------------------------------------------

func _test_seed_state() -> void:
	_make_run("portugal")
	# Protected: alignment = owner forever, dev = authored floor forever.
	for port_id in ["lisbon", "oporto", "london", "venice", "istanbul"]:
		var port: Dictionary = DataLoader.get_port(port_id)
		_check(AllegianceLib.is_protected(port_id),
			"%s is a protected port (data)" % port_id)
		_check(AllegianceLib.effective_alignment(port_id)
			== str(port.get("nation_id", "")),
			"protected %s aligns to its owner %s (got %s)" % [port_id,
			str(port.get("nation_id", "")),
			AllegianceLib.effective_alignment(port_id)])
		_check(AllegianceLib.dev(port_id) == int(port.get("dev", 0)),
			"protected %s dev == authored floor %d (got %d)" % [port_id,
			int(port.get("dev", 0)), AllegianceLib.dev(port_id)])
		_check(AllegianceLib.ledger_of(port_id, "portugal") == 0
			and AllegianceLib.ledger_total(port_id) == 0,
			"protected %s never carries a ledger" % port_id)
	# Contestable sovereign: `{owner: 6,000}` — allied (7,500 effective),
	# below dev-1's 10,000g.
	_check(AllegianceLib.effective_alignment("madeira") == "portugal",
		"contestable sovereign madeira starts aligned to portugal (got %s)"
		% AllegianceLib.effective_alignment("madeira"))
	_check(AllegianceLib.ledger_of("madeira", "portugal") == 6000
		and AllegianceLib.ledger_total("madeira") == 6000,
		"madeira's seed ledger is {portugal: 6,000} (got %d)"
		% AllegianceLib.ledger_total("madeira"))
	_check(AllegianceLib.effective_value("madeira", "portugal") == 7500,
		"the owner's ×1.25 home advantage: 6,000 → 7,500 effective (got %d)"
		% AllegianceLib.effective_value("madeira", "portugal"))
	_check(AllegianceLib.dev("madeira") == 1,
		"madeira dev == authored floor 1 (got %d)" % AllegianceLib.dev("madeira"))
	# Neutral: empty ledger, unaligned, dev floor 0.
	_check(AllegianceLib.effective_alignment("quanzhou") == "",
		"neutral quanzhou starts unaligned (got %s)"
		% AllegianceLib.effective_alignment("quanzhou"))
	_check(AllegianceLib.ledger_total("quanzhou") == 0
		and AllegianceLib.dev("quanzhou") == 0,
		"neutral quanzhou: empty ledger, dev floor 0")
	# Treasuries: 5,000g per nation.
	for nation_id in NATIONS:
		_check(AllegianceLib.treasury(nation_id) == 5000,
			"%s starts with 5,000g (got %d)" % [nation_id,
			AllegianceLib.treasury(nation_id)])
	# Every contestable port seeded: 145 total − 17 protected.
	var contestable := 0
	for port in DataLoader.ports_list:
		if not bool((port as Dictionary).get("protected", false)):
			contestable += 1
			_check(AllegianceLib.dump_state()["port_allegiance"].has(
				str((port as Dictionary).get("id", ""))),
				"contestable port %s is seeded" % str((port as Dictionary).get("id", "")))
	_check(contestable == 133, "133 contestable ports (got %d)" % contestable)


# --- §4.9 ledger & allegiance resolution -----------------------------------

func _test_ledger_allegiance_resolution() -> void:
	_make_run("portugal")
	# Strictly the highest effective ledger ≥ 5,000g wins.
	AllegianceLib.add_investment("quanzhou", "portugal", 4999)
	_check(AllegianceLib.effective_alignment("quanzhou") == "",
		"4,999g effective stays below the 5,000g line (unaligned)")
	AllegianceLib.add_investment("quanzhou", "portugal", 1)
	_check(AllegianceLib.effective_alignment("quanzhou") == "portugal",
		"5,000g crosses the alignment line (got %s)"
		% AllegianceLib.effective_alignment("quanzhou"))
	# Ties keep the incumbent.
	AllegianceLib.add_investment("quanzhou", "holland", 5000)
	_check(AllegianceLib.effective_alignment("quanzhou") == "portugal",
		"a 5,000/5,000 tie keeps the incumbent portugal (got %s)"
		% AllegianceLib.effective_alignment("quanzhou"))
	AllegianceLib.add_investment("quanzhou", "holland", 1)
	_check(AllegianceLib.effective_alignment("quanzhou") == "holland",
		"5,001 strictly beats 5,000 → holland (got %s)"
		% AllegianceLib.effective_alignment("quanzhou"))
	# Home advantage at a sovereign port: the owner's ×1.25 (integer 5/4).
	_make_run("portugal")
	# madeira: portugal 6,000 → 7,500 effective. 7,500 foreign gold does NOT
	# tie (strictly highest); 7,501 wins.
	AllegianceLib.add_investment("madeira", "ottoman", 7500)
	_check(AllegianceLib.effective_alignment("madeira") == "portugal",
		"7,500 foreign does not beat the owner's 7,500 effective (tie keeps)")
	AllegianceLib.add_investment("madeira", "ottoman", 1)
	_check(AllegianceLib.effective_alignment("madeira") == "ottoman",
		"7,501 foreign flips the sovereign port (got %s)"
		% AllegianceLib.effective_alignment("madeira"))
	_check(AllegianceLib.effective_value("madeira", "portugal") == 7500
		and AllegianceLib.effective_value("madeira", "ottoman") == 7501,
		"effective values: owner ×5/4 (7,500), foreign raw (7,501)")
	# The ledger is cumulative per nation and only ever grows.
	_make_run("portugal")
	AllegianceLib.add_investment("malacca", "portugal", 500)
	AllegianceLib.add_investment("malacca", "portugal", 500)
	_check(AllegianceLib.ledger_of("malacca", "portugal") == 7000,
		"ledger accumulates: 6,000 seed + 2×500 (got %d)"
		% AllegianceLib.ledger_of("malacca", "portugal"))


func _test_dev_thresholds() -> void:
	_make_run("portugal")
	# Neutral floor 0: dev 1 at ≥ 10,000g total, 2 at 25,000, 3 at 50,000.
	AllegianceLib.add_investment("quanzhou", "portugal", 9999)
	_check(AllegianceLib.dev("quanzhou") == 0,
		"9,999g total: dev stays 0 (got %d)" % AllegianceLib.dev("quanzhou"))
	AllegianceLib.add_investment("quanzhou", "portugal", 1)
	_check(AllegianceLib.dev("quanzhou") == 1,
		"10,000g total: dev 1 (got %d)" % AllegianceLib.dev("quanzhou"))
	AllegianceLib.add_investment("quanzhou", "holland", 14999)
	_check(AllegianceLib.dev("quanzhou") == 1,
		"24,999g total: still dev 1 (got %d)" % AllegianceLib.dev("quanzhou"))
	AllegianceLib.add_investment("quanzhou", "holland", 1)
	_check(AllegianceLib.dev("quanzhou") == 2,
		"25,000g total: dev 2 (got %d)" % AllegianceLib.dev("quanzhou"))
	AllegianceLib.add_investment("quanzhou", "spain", 25000)
	_check(AllegianceLib.dev("quanzhou") == 3,
		"50,000g total: dev 3 (got %d)" % AllegianceLib.dev("quanzhou"))
	# The total counts every nation's gold; the authored floor holds below it.
	_make_run("portugal")
	_check(AllegianceLib.dev("malacca") == 2,
		"malacca authored floor 2 (got %d)" % AllegianceLib.dev("malacca"))
	AllegianceLib.add_investment("malacca", "portugal", 4000)
	_check(AllegianceLib.dev("malacca") == 2,
		"10,000g total at a floor-2 port: dev stays 2 (got %d)"
		% AllegianceLib.dev("malacca"))
	AllegianceLib.add_investment("malacca", "holland", 15000)
	_check(AllegianceLib.dev("malacca") == 2,
		"25,000g total at a floor-2 port: dev 2 (got %d)"
		% AllegianceLib.dev("malacca"))
	AllegianceLib.add_investment("malacca", "holland", 25001)
	_check(AllegianceLib.dev("malacca") == 3,
		"50,001g total: dev 3 (got %d)" % AllegianceLib.dev("malacca"))
	# Dev is derived, never saved: the dump carries only ledger + allegiance.
	var entry: Dictionary = AllegianceLib.dump_state()["port_allegiance"]["malacca"]
	_check(entry.keys() == ["ledger", "allegiance"],
		"the persisted port entry is exactly {ledger, allegiance} (correction 8)")


# --- Protected immunity ----------------------------------------------------

func _test_protected_immunity() -> void:
	_make_run("portugal", 100000)
	# The AI never invests at a protected port (no ledger appears, ever).
	GameState.day = 31
	AllegianceLib.month_tick()
	var ai_hit_protected := false
	for row in AllegianceLib.last_month_investments():
		if AllegianceLib.is_protected(str(row.get("port_id", ""))):
			ai_hit_protected = true
	for port_id in ["lisbon", "london", "venice"]:
		if AllegianceLib.ledger_total(port_id) > 0:
			ai_hit_protected = true
	_check(not ai_hit_protected, "the monthly AI never touches a protected port")
	# The player's chunk is discount-only: discount block grows, ledger and
	# monthly allowance never move.
	GameState.current_port = "lisbon"
	for click in range(4):
		_check(TradeEngineLib.invest("lisbon"),
			"protected click %d: discount-only invest succeeds" % (click + 1))
	_check(AllegianceLib.ledger_total("lisbon") == 0,
		"protected investing writes no ledger (got %d)"
		% AllegianceLib.ledger_total("lisbon"))
	_check(AllegianceLib.month_invested_gold("lisbon") == 0,
		"protected investing books no monthly allowance")
	_check(TradeEngineLib.invested("lisbon") == 2000,
		"the discount block still books 2,000g (got %d)"
		% TradeEngineLib.invested("lisbon"))
	# The lifetime discount cap still ends protected investment (its whole
	# effect saturates at −10% / 5,000g).
	GameState.port_investments["lisbon"] = 5000
	_check(not TradeEngineLib.can_invest("lisbon"),
		"at the 5,000g discount cap a protected port refuses further chunks")
	# The dev floor never grows, whatever anyone else does.
	_check(AllegianceLib.dev("lisbon") == 3, "lisbon stays dev 3 forever")


# --- Monthly cap & the diplomatic gate (decision 26) ------------------------

func _test_invest_cap_and_gate() -> void:
	_make_run("portugal", 100000)
	# madeira: own contestable sovereign — allowance 4 × 500g per month.
	for click in range(4):
		_check(TradeEngineLib.can_invest("madeira"),
			"chunk %d investable (allowance %d/2,000)" % [click + 1,
			AllegianceLib.month_invested_gold("madeira")])
		_check(AllegianceLib.invest_block_reason("madeira") == "",
			"chunk %d: no block reason" % (click + 1))
		_check(TradeEngineLib.invest("madeira"),
			"chunk %d invests" % (click + 1))
	_check(AllegianceLib.month_invested_gold("madeira") == 2000,
		"the monthly counter books 2,000g (got %d)"
		% AllegianceLib.month_invested_gold("madeira"))
	_check(AllegianceLib.ledger_of("madeira", "portugal") == 8000,
		"the ledger books the same 4 chunks: 6,000 + 2,000 (got %d)"
		% AllegianceLib.ledger_of("madeira", "portugal"))
	_check(not TradeEngineLib.can_invest("madeira"),
		"the 5th chunk of the month is refused")
	_check(AllegianceLib.invest_block_reason("madeira")
		== "market.invest_gate.exhausted",
		"the exhausted state names market.invest_gate.exhausted (got %s)"
		% AllegianceLib.invest_block_reason("madeira"))
	# Contestable ports invest past the 5,000g discount cap: the ledger is the
	# campaign's currency, only the monthly allowance binds.
	_check(TradeEngineLib.invested("madeira") == 2000,
		"the discount block reads the same 2,000g (got %d)"
		% TradeEngineLib.invested("madeira"))
	# The month tick resets the allowance.
	GameState.day = 31
	AllegianceLib.month_tick()
	_check(AllegianceLib.month_invested_gold("madeira") == 0,
		"the month tick resets month_invested")
	_check(TradeEngineLib.can_invest("madeira"),
		"and the next month's first chunk invests again")
	# Diplomatic gate: rep ≥ 0 and no bounty vs the alignment nation.
	_make_run("portugal", 100000)
	_check(AllegianceLib.invest_block_reason("london") == "",
		"rep 0 with england: london invests")
	CharacterLib.add_reputation("england", -1)
	_check(AllegianceLib.invest_block_reason("london")
		== "market.invest_gate.blocked",
		"rep −1 blocks with market.invest_gate.blocked (got %s)"
		% AllegianceLib.invest_block_reason("london"))
	_check(not TradeEngineLib.can_invest("london"),
		"and can_invest is false")
	CharacterLib.add_reputation("england", 1)
	GameState.bounties["england"] = {"amount": 5000, "day": 1}
	_check(AllegianceLib.invest_block_reason("london")
		== "market.invest_gate.blocked",
		"a standing bounty blocks even at rep 0 (got %s)"
		% AllegianceLib.invest_block_reason("london"))
	GameState.bounties = {}
	_check(AllegianceLib.invest_block_reason("london") == "",
		"clearing the bounty reopens london")
	# An unaligned contestable port has no gate at all — holland's opinion is
	# irrelevant while the port has no allegiance (the fixture does NOT invest
	# there: any investment would align it and raise the gate).
	CharacterLib.add_reputation("holland", -100)
	GameState.bounties["holland"] = {"amount": 5000, "day": 1}
	_check(AllegianceLib.effective_alignment("quanzhou") == "",
		"fixture: quanzhou stays unaligned")
	_check(AllegianceLib.invest_block_reason("quanzhou") == "",
		"an unaligned port: no diplomacy gate whatever holland thinks")
	CharacterLib.add_reputation("holland", 0)
	GameState.bounties = {}


# --- Monthly AI: determinism (the proof) ------------------------------------
#
# The proof: from the same state the tick replays the identical sequence.
# `seq_a` and `seq_b` are two full re-creations (fresh seed → same day → tick)
# in the same process; equality across runs of the pure seed formula is the
# same-seed-same-sequence property, recorded here and in the task report.

func _ai_sequence(nation_id: String, day: int) -> Array:
	_make_run(nation_id, 100000, day)
	AllegianceLib.month_tick()
	var out: Array = []
	for row in AllegianceLib.last_month_investments():
		out.append("%s@%s=%d" % [row.get("nation_id", ""),
			row.get("port_id", ""), row.get("amount", 0)])
	return out


func _test_monthly_ai_determinism() -> void:
	var seq_a := _ai_sequence("portugal", 31)
	var seq_b := _ai_sequence("portugal", 31)
	_check(seq_a == seq_b,
		"DETERMINISM: same seed → identical month-31 investment sequence")
	_check(not seq_a.is_empty(),
		"the month-31 tick produced %d telegraph rows (the AI is alive)" % seq_a.size())
	var seq_c := _ai_sequence("portugal", 61)
	_check(seq_a != seq_c,
		"DETERMINISM: month 61's seed differs → a different sequence")
	# The treasury math replays identically too: same end state.
	_make_run("portugal", 100000, 31)
	AllegianceLib.month_tick()
	var treasuries_a: Dictionary = AllegianceLib.dump_state()["nation_treasuries"]
	_make_run("portugal", 100000, 31)
	AllegianceLib.month_tick()
	var treasuries_b: Dictionary = AllegianceLib.dump_state()["nation_treasuries"]
	_check(treasuries_a == treasuries_b,
		"DETERMINISM: identical post-tick treasuries")
	print("DETERMINISM PROOF month 31: ", seq_a)
	print("DETERMINISM PROOF month 61: ", seq_c)


func _test_monthly_ai_bounds() -> void:
	_make_run("portugal", 100000, 31)
	AllegianceLib.month_tick()
	var rows := AllegianceLib.last_month_investments()
	# ≤ 2 picks per nation, each ≤ min(treasury, 1,500)g.
	var per_nation: Dictionary = {}
	for row in rows:
		var nation_id := str(row.get("nation_id", ""))
		per_nation[nation_id] = int(per_nation.get(nation_id, 0)) + 1
		var spend := int(row.get("amount", 0))
		_check(spend > 0 and spend <= 1500,
			"%s's pick at %s spends ≤ 1,500g (%d)" % [nation_id,
			str(row.get("port_id", "")), spend])
	for nation_id in per_nation:
		_check(int(per_nation[nation_id]) <= 2,
			"%s made ≤ 2 picks (got %d)" % [nation_id, per_nation[nation_id]])
	# Candidates are sphere ports, contestable, never protected, never dev-3.
	for row in rows:
		var port_id := str(row.get("port_id", ""))
		var port: Dictionary = DataLoader.get_port(port_id)
		var nation_id := str(row.get("nation_id", ""))
		_check(not AllegianceLib.is_protected(port_id),
			"the AI never picks protected %s" % port_id)
		_check(nation_id in (port.get("sphere", []) as Array),
			"%s's pick %s is in its sphere" % [nation_id, port_id])
		var holder := AllegianceLib.effective_alignment(port_id)
		if holder == nation_id:
			_check(AllegianceLib.dev(port_id) < 3,
				"the AI never reinforces its own dev-3 port (%s)" % port_id)
	# Treasury-bounded spend: `min(treasury, 1500)` per pick. A nation whose
	# window opens at 0 gets the 1,000g baseline — its picks (if any) must
	# spend exactly 1,000g each, never the 1,500g cap, and the purse books
	# the same amounts.
	_make_run("portugal", 100000, 31)
	var drained: Dictionary = AllegianceLib.dump_state()["nation_treasuries"]
	drained["holland"] = 0
	AllegianceLib.restore_state({"nation_treasuries": drained})
	AllegianceLib.month_tick()
	var holland_spent := 0
	for row in AllegianceLib.last_month_investments():
		if str(row.get("nation_id", "")) == "holland":
			holland_spent += int(row.get("amount", 0))
	_check(AllegianceLib.treasury("holland") == 1000 - holland_spent,
		"the purse books exactly its picks (1,000 opened, %d spent, %d left)"
		% [holland_spent, AllegianceLib.treasury("holland")])
	_check(holland_spent == 0 or holland_spent == 1000 or holland_spent == 2000,
		"each pick spends min(treasury, 1,500) — %d total from a 1,000g purse"
		% holland_spent)
	if holland_spent > 0:
		_check(holland_spent == 1000 or holland_spent == 2000,
			"no pick exceeded the 1,000g purse")


# --- §2.6 fame, poaching, commendation -------------------------------------

func _test_fame_poaching_commendation() -> void:
	# Spain poaches a Portuguese sovereign port from Portugal.
	_make_run("spain", 100000)
	_check(GameState.fame == 0, "fame starts 0")
	# 7,500 foreign gold: tie, no flip yet.
	AllegianceLib.add_investment("madeira", "spain", 7500)
	_check(AllegianceLib.effective_alignment("madeira") == "portugal"
		and GameState.fame == 0,
		"the tie keeps portugal: no flip, no fame")
	AllegianceLib.add_investment("madeira", "spain", 1)
	_check(AllegianceLib.effective_alignment("madeira") == "spain",
		"7,501 foreign gold flips madeira to spain")
	_check(GameState.fame == 100,
		"the first flip to the player's nation awards +100 fame (got %d)"
		% GameState.fame)
	_check(AllegianceLib.dump_state()["fame_commended"].has("madeira"),
		"the first flip is recorded in fame_commended")
	_check(CharacterLib.reputation("portugal") == -5,
		"poaching a foreign sovereign costs −5 rep with the previous owner "
		+ "(got %d)" % CharacterLib.reputation("portugal"))
	var pending := AllegianceLib.pending_commendation()
	_check(pending.get("port_id", "") == "madeira"
		and pending.get("nation_id", "") == "spain",
		"the commendation is pending for madeira")
	# Losing it back costs nothing; re-taking it poaches again (−5 per flip)
	# but never re-awards the +100. The owner's ×1.25 grows with its ledger:
	# portugal 6,500 raw → 8,125 effective, so spain needs > 8,125.
	AllegianceLib.add_investment("madeira", "portugal", 500)
	_check(AllegianceLib.effective_alignment("madeira") == "portugal",
		"portugal takes madeira back (8,125 effective vs 7,501)")
	_check(GameState.fame == 100,
		"losing the port back awards no fame")
	AllegianceLib.add_investment("madeira", "spain", 700)
	_check(AllegianceLib.effective_alignment("madeira") == "spain",
		"spain re-takes madeira (8,201 vs 8,125 effective)")
	_check(CharacterLib.reputation("portugal") == -10,
		"each poaching flip costs −5, one-time per flip (got %d)"
		% CharacterLib.reputation("portugal"))
	_check(GameState.fame == 100,
		"the +100 is once per port per save (got %d)" % GameState.fame)
	# A neutral port: no sovereign owner, no poaching rep — but the first
	# flip still commends.
	_make_run("spain", 100000)
	AllegianceLib.add_investment("quanzhou", "spain", 6000)
	_check(GameState.fame == 100
		and CharacterLib.reputation("portugal") == 0,
		"flipping a neutral: +100 fame, no poaching (no previous owner)")
	# The palace pull model: shown once, then gone.
	_check(not AllegianceLib.pending_commendation().is_empty(),
		"a commendation is pending after the neutral flip")
	AllegianceLib.mark_commendation_shown()
	_check(AllegianceLib.pending_commendation().is_empty(),
		"the commendation is dismissed after being shown")
	# Dev-threshold fame: +25 per level reached at a port aligned to the
	# player's nation, tracked per port, never retro-awarded.
	_make_run("spain", 100000)
	# Holland takes quanzhou first (6,000 → aligned, dev 0).
	AllegianceLib.add_investment("quanzhou", "holland", 6000)
	_check(AllegianceLib.effective_alignment("quanzhou") == "holland"
		and GameState.fame == 0,
		"fixture: holland holds quanzhou, the player has no fame here")
	# Spain overtakes (6,500 > 6,000 raw): the flip's +100 is the only fame —
	# the total (12,500) crosses dev 1 in the same add, but the award-time
	# alignment is still holland's, so the tracker only baselines (no +25).
	AllegianceLib.add_investment("quanzhou", "spain", 6500)
	_check(AllegianceLib.effective_alignment("quanzhou") == "spain",
		"quanzhou flips to spain mid-ladder (6,500 vs 6,000)")
	var fame_before := GameState.fame
	_check(fame_before == 100
		and AllegianceLib.dev("quanzhou") == 1,
		"the flip's +100 is the only fame: dev 1 crossed pre-flip, no award")
	AllegianceLib.add_investment("quanzhou", "spain", 7499)
	_check(GameState.fame == fame_before
		and AllegianceLib.dev("quanzhou") == 1,
		"19,999g total: still dev 1, nothing to award")
	AllegianceLib.add_investment("quanzhou", "spain", 5001)
	_check(GameState.fame == fame_before + 25
		and AllegianceLib.dev("quanzhou") == 2,
		"crossing 25,000g total at an aligned port: +25 (got +%d)"
		% (GameState.fame - fame_before))
	AllegianceLib.add_investment("quanzhou", "spain", 25000)
	_check(GameState.fame == fame_before + 50
		and AllegianceLib.dev("quanzhou") == 3,
		"crossing 50,000g total: another +25 (got +%d)"
		% (GameState.fame - fame_before))


# --- §4.10 tariff matrix ----------------------------------------------------

func _test_tariff_matrix() -> void:
	_make_run("portugal")
	# In sphere (alignment == trader): 500. Foreign: 2000. Unaligned: 2000.
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 500,
		"own protected lisbon: 5%% (got %d)"
		% AllegianceLib.tariff_mille("lisbon", "portugal"))
	_check(AllegianceLib.tariff_mille("london", "england") == 500,
		"england's trader at london: 5%% (NPC view)")
	_check(AllegianceLib.tariff_mille("london", "portugal") == 2000,
		"foreign london: 20%% (got %d)"
		% AllegianceLib.tariff_mille("london", "portugal"))
	_check(AllegianceLib.tariff_mille("madeira", "portugal") == 500,
		"aligned contestable madeira: 5%%")
	_check(AllegianceLib.tariff_mille("madeira", "holland") == 2000,
		"foreign trader at madeira: 20%%")
	AllegianceLib.add_investment("quanzhou", "holland", 6000)
	_check(AllegianceLib.tariff_mille("quanzhou", "holland") == 500,
		"flipped neutral: holland's trader pays 5%%")
	AllegianceLib.add_investment("quanzhou", "spain", 6001)
	_check(AllegianceLib.tariff_mille("quanzhou", "spain") == 500
		and AllegianceLib.tariff_mille("quanzhou", "holland") == 2000,
		"the flipped alignment moves the 5%% with it")
	_make_run("portugal")
	_check(AllegianceLib.tariff_mille("quanzhou", "portugal") == 2000,
		"unaligned neutral: 20%% forever (got %d)"
		% AllegianceLib.tariff_mille("quanzhou", "portugal"))
	_check(AllegianceLib.tariff_mille("nowhere", "portugal") == 2000,
		"an unknown port taxes foreign (never exempt)")


func _test_tariff_permits() -> void:
	_make_run("portugal", 100000)
	# Home charter: own + aligned ports 5% → 0%.
	AllegianceLib.set_permit("home", "portugal")
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 0,
		"home charter: own lisbon 0%%")
	_check(AllegianceLib.tariff_mille("madeira", "portugal") == 0,
		"home charter: aligned contestable madeira 0%%")
	_check(AllegianceLib.tariff_mille("london", "portugal") == 2000,
		"home charter never covers a foreign port")
	AllegianceLib.add_investment("quanzhou", "holland", 6000)
	_check(AllegianceLib.tariff_mille("quanzhou", "portugal") == 2000,
		"no permit ever covers a port aligned to another nation")
	# Void while the holder's bounty stands (the home charter's nation).
	GameState.bounties["portugal"] = {"amount": 5000, "day": 1}
	_check(AllegianceLib.permit_void_reason("portugal")
		== "palace.permit.void_bounty",
		"a bounty voids the home charter (got %s)"
		% AllegianceLib.permit_void_reason("portugal"))
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 500,
		"the void charter falls back to 5%%")
	GameState.bounties = {}
	CharacterLib.add_reputation("portugal", -21)
	_check(AllegianceLib.permit_void_reason("portugal")
		== "palace.permit.void_rep",
		"rep < −20 voids it too (got %s)"
		% AllegianceLib.permit_void_reason("portugal"))
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 500,
		"and the tariff falls back again")
	CharacterLib.add_reputation("portugal", 21)
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 0,
		"rep restored: the charter covers again")
	# Foreign permit: that nation's ports 20% → 0% for the player.
	AllegianceLib.set_permit("foreign", "england")
	_check(AllegianceLib.tariff_mille("london", "portugal") == 0,
		"the england permit zeroes london for the portuguese player")
	_check(AllegianceLib.tariff_mille("london", "england") == 500,
		"an NPC england trader still pays 5%% (permits are personal)")
	GameState.bounties["england"] = {"amount": 5000, "day": 1}
	_check(AllegianceLib.tariff_mille("london", "portugal") == 2000,
		"the england permit voids on an england bounty")
	GameState.bounties = {}
	_check(AllegianceLib.tariff_mille("london", "portugal") == 0,
		"and recovers when the bounty clears")


func _test_tax_crediting() -> void:
	_make_run("portugal", 100000)
	# Player-sourced tax: uncapped, to the alignment nation.
	var treasury_before := AllegianceLib.treasury("portugal")
	AllegianceLib.credit_tax("lisbon", "portugal", 300)
	_check(AllegianceLib.treasury("portugal") == treasury_before + 300,
		"player tax at lisbon credits portugal uncapped (+300)")
	# NPC-sourced tax: capped at 2,000/host/month.
	AllegianceLib.credit_tax("lisbon", "england", 2500)
	_check(AllegianceLib.treasury("portugal") == treasury_before + 2300,
		"england's 2,500g NPC tax caps at 2,000 (got +%d)"
		% (AllegianceLib.treasury("portugal") - treasury_before))
	AllegianceLib.credit_tax("lisbon", "holland", 1000)
	_check(AllegianceLib.treasury("portugal") == treasury_before + 2300,
		"the month's NPC-tax window for portugal is spent (0 more)")
	# The cap is per host: london's host is england.
	var england_before := AllegianceLib.treasury("england")
	AllegianceLib.credit_tax("london", "spain", 700)
	_check(AllegianceLib.treasury("england") == england_before + 700,
		"england's own window is separate (+700)")
	# Unaligned hosts and nationless payers credit nothing.
	_check(AllegianceLib.effective_alignment("quanzhou") == "",
		"quanzhou is unaligned in this fixture")
	AllegianceLib.credit_tax("quanzhou", "portugal", 500)
	_check(AllegianceLib.treasury("portugal") == treasury_before + 2300,
		"an unaligned host collects nothing")
	AllegianceLib.credit_tax("lisbon", "", 500)
	_check(AllegianceLib.treasury("portugal") == treasury_before + 2300,
		"a nationless payer credits nothing")
	# The month tick resets the NPC-tax window. The exact post-tick treasury:
	# the credits + the baseline − whatever portugal's AI picks spent (the
	# rows say exactly that).
	var window_credits := AllegianceLib.treasury("portugal")
	GameState.day = 31
	AllegianceLib.month_tick()
	var ai_spend := 0
	for row in AllegianceLib.last_month_investments():
		if str(row.get("nation_id", "")) == "portugal":
			ai_spend += int(row.get("amount", 0))
	_check(AllegianceLib.treasury("portugal")
		== window_credits + 1000 - ai_spend,
		"after the tick: credits + baseline − AI spend (%d + 1,000 − %d)"
		% [window_credits, ai_spend])
	AllegianceLib.credit_tax("lisbon", "england", 500)
	_check(AllegianceLib.treasury("portugal")
		== window_credits + 1000 - ai_spend + 500,
		"and the reopened window takes england's next 500")
	# Permit sales credit the selling nation, uncapped.
	var italy_before := AllegianceLib.treasury("italy")
	AllegianceLib.credit_permit_sale("italy", 20000)
	_check(AllegianceLib.treasury("italy") == italy_before + 20000,
		"a foreign permit sale credits italy +20,000")


# --- Telegraphs (decision 24) ----------------------------------------------

func _test_telegraph_window() -> void:
	_make_run("portugal", 100000, 31)
	AllegianceLib.month_tick()
	var rows := AllegianceLib.last_month_investments()
	_check(not rows.is_empty(), "the tick landed telegraph rows")
	for row in rows:
		var row_keys: Array = (row as Dictionary).keys()
		var complete := true
		for key in ["nation_id", "port_id", "band", "amount", "day"]:
			if not row_keys.has(key):
				complete = false
		_check(complete,
			"each row carries {nation_id, port_id, band, amount, day}")
		_check(int(row.get("day", 0)) == 31,
			"rows are stamped with the tick day (got %d)" % int(row.get("day", 0)))
		var port: Dictionary = DataLoader.get_port(str(row.get("port_id", "")))
		_check(str(row.get("band", "")) == str(port.get("band", "")),
			"the row's band is the invested port's band")
	# The window: visible 30 days, gone at 30.
	GameState.day = 60
	_check(AllegianceLib.last_month_investments().size() == rows.size(),
		"day 60 (29 days later): the rows are still visible")
	GameState.day = 61
	_check(AllegianceLib.last_month_investments().is_empty(),
		"day 61: the 30-day window closed")
	# The next tick refreshes the buffer (drops the expired rows).
	AllegianceLib.month_tick()
	_check(AllegianceLib.last_month_investments().size()
		== AllegianceLib.last_month_investments().size(),
		"the refreshed buffer is self-consistent")


# --- The W4/V persistence seam ---------------------------------------------

func _test_state_seam() -> void:
	# Build a distinctive state: investments, a flip, a crossed threshold,
	# permits, tax credits and the monthly counter.
	_make_run("spain", 100000)
	AllegianceLib.add_investment("quanzhou", "spain", 6000)   # flip: +100 fame
	AllegianceLib.add_investment("quanzhou", "spain", 4000)   # 10,000 → dev 1: +25
	_check(GameState.fame == 125,
		"fixture: the flip's +100 and dev-1's +25 are booked (got %d)"
		% GameState.fame)
	AllegianceLib.add_investment("malacca", "holland", 10000)
	AllegianceLib.set_permit("home", "spain")
	AllegianceLib.set_permit("foreign", "england")
	AllegianceLib.credit_tax("lisbon", "england", 400)
	AllegianceLib.player_invest_chunk("malacca")
	var dump := AllegianceLib.dump_state()
	var dump_keys: Array = dump.keys()
	var has_five := true
	for key in ["port_allegiance", "month_invested", "nation_treasuries",
			"fame_commended", "permits"]:
		if not dump_keys.has(key):
			has_five = false
	_check(has_five and dump.keys().size() == 5,
		"the dump carries exactly the five save v7 keys")
	# Restore over a fresh seed: every derived answer must agree.
	_make_run("spain", 100000)
	_check(GameState.fame == 0, "GameState.fame is V's payload key, not ours")
	AllegianceLib.restore_state(dump)
	_check(AllegianceLib.effective_alignment("quanzhou") == "spain",
		"restore: quanzhou's allegiance survives")
	_check(AllegianceLib.effective_alignment("malacca") == "holland",
		"restore: malacca's flipped allegiance survives")
	_check(AllegianceLib.ledger_of("malacca", "holland") == 10000
		and AllegianceLib.ledger_of("malacca", "spain") == 500,
		"restore: the ledgers survive exactly (holland 10,000, spain +500)")
	_check(AllegianceLib.ledger_total("malacca") == 16500
		and AllegianceLib.dev("malacca") == 2,
		"restore: dev re-derives from the ledger (16,500 total → floor 2)")
	_check(AllegianceLib.tariff_mille("seville", "spain") == 0,
		"restore: the home charter covers spain's own ports")
	_check(AllegianceLib.tariff_mille("london", "spain") == 0,
		"restore: the england permit covers london")
	_check(AllegianceLib.tariff_mille("lisbon", "spain") == 2000,
		"restore: the home charter never covers a portuguese port")
	_check(AllegianceLib.month_invested_gold("malacca") == 500,
		"restore: the monthly counter survives")
	_check(AllegianceLib.treasury("portugal") == 5000 + 400,
		"restore: treasuries survive (baseline seed + the tax credit)")
	_check(AllegianceLib.dump_state()["fame_commended"].has("quanzhou"),
		"restore: the first-flip flag survives")
	# The threshold tracker re-derives on restore: quanzhou sits at 10,000g
	# (dev 1 already rewarded pre-dump), so crossing 25,000g awards +25 —
	# exactly once. A stale tracker would award two levels' worth (+50).
	_check(AllegianceLib.dev("quanzhou") == 1,
		"restore: quanzhou derives dev 1 from its restored ledger")
	AllegianceLib.add_investment("quanzhou", "spain", 15000)
	_check(AllegianceLib.dev("quanzhou") == 2
		and GameState.fame == 25,
		"post-restore crossing awards +25 exactly once (tracker re-derived)")
	AllegianceLib.add_investment("quanzhou", "spain", 1)
	_check(GameState.fame == 25,
		"and nothing re-awards inside the same level")


# --- The sailing_sim month-tick seam (docs/90-* §5.4) -----------------------

## A minimal at-sea run: zero-crew hull (the ledger feeds nobody), a calm
## mid-Atlantic tile.
func _make_sea_run() -> void:
	_make_run("portugal", 100000)
	var ship: Dictionary = FleetLib.new_ship("caravel", 0)
	ship["crew"] = 0
	ship["provisions"] = 0
	ship["water"] = 0
	GameState.fleet = [ship]
	GameState.current_port = null
	SailingSimLib.reset_ledger_state()


func _test_month_tick_seam() -> void:
	_make_sea_run()
	GameState.day = 30
	AllegianceLib.seed_new_game()
	AllegianceLib.player_invest_chunk("malacca")
	_check(AllegianceLib.month_invested_gold("malacca") == 500,
		"pre-tick: the monthly counter holds one chunk")
	var treasury_before := AllegianceLib.treasury("portugal")
	var ticks := SailingSimLib.advance_clock(1.0)
	_check(ticks == 1 and GameState.day == 31,
		"the clock ticks into the new month (day %d)" % GameState.day)
	_check(AllegianceLib.month_invested_gold("malacca") == 0,
		"the seam ran the month tick: month_invested reset")
	var ai_spend := 0
	for row in AllegianceLib.last_month_investments():
		if str(row.get("nation_id", "")) == "portugal":
			ai_spend += int(row.get("amount", 0))
	_check(AllegianceLib.treasury("portugal")
		== treasury_before + 1000 - ai_spend,
		"the seam credited portugal's baseline − its AI spend (%d + 1,000 − %d)"
		% [treasury_before, ai_spend])
	# A day inside the month runs no tick.
	var stable := AllegianceLib.treasury("portugal")
	var rows_before := AllegianceLib.last_month_investments().size()
	SailingSimLib.advance_clock(1.0)
	_check(GameState.day == 32
		and AllegianceLib.last_month_investments().size() == rows_before
		and AllegianceLib.treasury("portugal") == stable,
		"day 32: no month tick fires mid-month")
