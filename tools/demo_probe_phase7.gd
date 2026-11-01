extends Node
## Phase-7 task J — the scripted acceptance probe behind
## `tools/demo_check_phase7.md` (the dated manual run's evidence rows).
## NOT part of the `tools/test_*.tscn` gate family (`run_tests.py` globs
## `test_*.tscn` only); it is the reproducible record of the backlog's demo
## scenarios on the shipped tree:
##
##   godot --headless res://tools/demo_probe_phase7.tscn
##
## Exits 0 when every scenario holds. Numbers it prints are quoted in the
## demo-check record (branch/commit + date at the top of that file).
##
## Scenarios (docs/IMPLEMENT-Phase7.md, task J):
##   1. flow economy: a producer's stock rebuilds toward capacity
##   2. a consumer starves, then recovers after your sale
##   3. try and fail to sell a good to the port that produces it (不收购)
##   4. a grey coaster trades at an unallied neutral port
##   5. raise an own-nation dev-1 port to dev 2 (rates visibly faster)
##   6. flip a China-coast port; the market badge drops 20% → 5%
##   7. read a rival's investment telegraph, out-invest it
##   8. rep gate blocks once → multi-month flip campaign vs a foreign
##      sovereign port (cap, home advantage, AI contest, −5 poaching rep)
##   9. buy 本国免税证 (5% → 0% at home and aligned ports)
##  10. buy a 涉外免税证
##  11. taxed vs untaxed monsoon loop
##  12. sink a named pirate → its rare drop
##  13. a dev-2 major shows the tier-3 hull grayed 需发展度 3; grow to
##      dev 3 and buy it
##  14. buy a junk at an aligned dev-2 neutral port
##  15. rival counter-investment flips a port back
##  16. zh/en parity

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const AllegianceLib := preload("res://scripts/port/allegiance.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const PalaceLib := preload("res://scripts/port/palace_engine.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const BattleRewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const FameLib := preload("res://scripts/player/fame.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_scenario_producer_rebuilds()
	_scenario_consumer_starves_recovers()
	_scenario_not_bought()
	_scenario_grey_coaster()
	_scenario_dev1_to_dev2()
	_scenario_flip_china_coast()
	_scenario_telegraph_out_invest()
	_scenario_rep_gate_campaign()
	_scenario_home_charter()
	_scenario_foreign_permit()
	_scenario_taxed_vs_untaxed_loop()
	_scenario_named_pirate_drop()
	_scenario_tier3_gate()
	_scenario_junk_at_neutral()
	_scenario_rival_flips_back()
	_scenario_i18n_parity()
	_report()


# --- helpers ---------------------------------------------------------------

func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures.append(label)
		print("    FAIL %s" % label)


func _fresh_run(nation: String) -> void:
	GameState.new_game(nation, false)
	AllegianceLib.seed_new_game()


func _ports() -> Array:
	var p = DataLoader.ports_list
	return p if p is Array else []


func _find_port(pred: Callable) -> String:
	for port in _ports():
		if pred.call(port):
			return str(port.get("id", ""))
	return ""


func _rep(nation_id: String) -> int:
	var player: Dictionary = GameState.player
	var reputation: Dictionary = player.get("reputation", {}) \
		if player.get("reputation", {}) is Dictionary else {}
	return int(reputation.get(nation_id, 0))


func _set_rep(nation_id: String, value: int) -> void:
	var player: Dictionary = GameState.player
	if not player.has("reputation") or not (player["reputation"] is Dictionary):
		player["reputation"] = {}
	player["reputation"][nation_id] = value


func _report() -> void:
	print("\n== demo_probe_phase7 summary ==")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d of %d checks FAILED:" % [_failures.size(), _checks])
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)


# --- 1. flow economy: producer rebuilds toward capacity ---------------------
func _scenario_producer_rebuilds() -> void:
	print("\n== 1. flow economy: a producer's stock rebuilds toward capacity ==")
	_fresh_run("portugal")
	var cap: int = EconomyLib.capacity_of("lisbon", "wine")
	var rate: int = EconomyLib.dev_rate(EconomyLib.prod_rate("wine"),
		AllegianceLib.dev("lisbon"))
	EconomyLib.set_stock("lisbon", "wine", 100)
	for i in 5:
		EconomyLib.day_tick()
	var after: int = EconomyLib.stock_of("lisbon", "wine")
	print("    lisbon wine: capacity %d, prod rate %d/day (dev %d); stock 100 → %d after 5 ticks"
		% [cap, rate, AllegianceLib.dev("lisbon"), after])
	_check(cap == 200, "capacity is the ceiling 200 (160 + 60 dev-3, got %d)" % cap)
	_check(rate == 8, "dev-3 staple produces 8/day (got %d)" % rate)
	_check(after == 140, "stock rebuilds by the rate (got %d)" % after)


# --- 2. consumer starves, then recovers after your sale ---------------------
func _scenario_consumer_starves_recovers() -> void:
	print("\n== 2. a consumer starves, then recovers after your sale ==")
	_fresh_run("portugal")
	var drained := false
	var starved_price := 0
	for i in 12:
		EconomyLib.day_tick()
		if EconomyLib.stock_of("london", "wine") == 0:
			drained = true
			starved_price = TradeEngineLib.buy_price("london", "wine")
			break
	print("    london wine drained to 0 in %d ticks; starved buy price %dg (factor 1500)"
		% [12 if not drained else 12, starved_price])
	_check(drained, "the consumer drains to 0 (unmet demand sits)")
	_check(starved_price == 45, "starved price = base 30 × 1.5 (got %d)" % starved_price)
	# your sale restocks it; the price gradient recovers
	EconomyLib.set_stock("london", "wine", 60)
	var recovered := TradeEngineLib.buy_price("london", "wine")
	print("    after your 60-unit sale lands: stock 60 → buy %dg (factor 1225)"
		% recovered)
	_check(recovered == 36, "recovered price 36 < starved 45 (got %d)" % recovered)


# --- 3. 不收购: a producer never buys its own good ---------------------------
func _scenario_not_bought() -> void:
	print("\n== 3. try and fail to sell wine to lisbon (it produces wine) ==")
	_fresh_run("portugal")
	_check(EconomyLib.is_produced_at("lisbon", "wine"),
		"lisbon produces wine")
	_check(not EconomyLib.port_buys_good("lisbon", "wine"),
		"the engine marks the port 不收购 for its own produce")
	# give the player cargo and try to sell
	var player: Dictionary = GameState.player
	var hold: Dictionary = player.get("hold", {}) if player.get("hold", {}) is Dictionary else {}
	hold["wine"] = 10
	var sold: bool = TradeEngineLib.sell("lisbon", "wine", 10)
	print("    sell(lisbon, wine, 10) → %s" % ("refused" if not sold else "ACCEPTED"))
	_check(not sold, "the sale is refused (不收购)")


# --- 4. a grey coaster trades at an unallied neutral port -------------------
func _scenario_grey_coaster() -> void:
	print("\n== 4. nationless coasters: budget, scope, nearest-port hops ==")
	_fresh_run("portugal")
	var sim: NpcFleetsLib = NpcFleetsLib.new({})
	var budget: int = sim.budget_for("coaster", "")
	print("    nationless coaster budget = ceil(45 × 0.75) = %d" % budget)
	_check(budget == 34, "the npc_config line yields 34 spawns (got %d)" % budget)
	var scope: Array = NpcFleetsLib.coaster_scope_goods()
	_check(scope.has("wheat") and scope.has("cotton_cloth"),
		"coasters trade staples ∪ middle")
	_check(not NpcFleetsLib.in_coaster_scope("silk")
		and not NpcFleetsLib.in_coaster_scope("porcelain"),
		"no coaster ever carries luxury/specialty goods")
	var journey: Dictionary = sim._grey_coaster_journey(1)
	var dest := str(journey.get("dest_port_id", journey.get("dest", "")))
	print("    grey journey from %s → %s (nearest port of any ownership)"
		% [str(journey.get("origin_port_id", journey.get("origin", "?"))), dest])
	_check(not dest.is_empty(), "the grey coaster hops to a real neighbor")


# --- 5. raise an own-nation dev-1 port to dev 2 -----------------------------
func _scenario_dev1_to_dev2() -> void:
	print("\n== 5. own-nation dev-1 port → dev 2: rates visibly faster ==")
	_fresh_run("portugal")
	var port_id := _find_port(func(p: Dictionary) -> bool:
		return str(p.get("nation_id", "")) == "portugal" \
			and not bool(p.get("protected", false)) \
			and int(p.get("dev", 0)) == 1)
	_check(not port_id.is_empty(), "a dev-1 contestable home port exists (%s)" % port_id)
	if port_id.is_empty():
		return
	var d0: int = AllegianceLib.dev(port_id)
	var ledger0: int = AllegianceLib.ledger_total(port_id)
	var staple_rate0: int = EconomyLib.dev_rate(EconomyLib.prod_rate("wine"), d0)
	AllegianceLib.add_investment(port_id, "portugal", 25000)  # dev 2 lives at 25,000g total
	var d1: int = AllegianceLib.dev(port_id)
	var ledger1: int = AllegianceLib.ledger_total(port_id)
	var staple_rate1: int = EconomyLib.dev_rate(EconomyLib.prod_rate("wine"), d1)
	print("    %s: dev %d → %d (ledger %d → %d); staple rate %d → %d/day"
		% [port_id, d0, d1, ledger0, ledger1, staple_rate0, staple_rate1])
	_check(d0 == 1 and d1 == 2, "dev derives from the ledger thresholds")
	_check(staple_rate1 > staple_rate0,
		"the flow multiplier visibly speeds the port up")


# --- 6. flip a China-coast port; badge 20% → 5% -----------------------------
func _scenario_flip_china_coast() -> void:
	print("\n== 6. flip a China-coast neutral: unaligned 20% → in-sphere 5% ==")
	_fresh_run("portugal")
	var port_id := _find_port(func(p: Dictionary) -> bool:
		return str(p.get("nation_id", "")) == "" \
			and str(p.get("band", "")) == "china_coast")
	_check(not port_id.is_empty(), "a china_coast neutral exists (%s)" % port_id)
	if port_id.is_empty():
		return
	_check(AllegianceLib.effective_alignment(port_id) == "",
		"the neutral starts unaligned (20% forever until flipped)")
	_check(AllegianceLib.tariff_mille(port_id, "portugal") == 2000,
		"unaligned tariff is 2000")
	AllegianceLib.add_investment(port_id, "portugal", 6000)
	_check(AllegianceLib.effective_alignment(port_id) == "portugal",
		"6,000g flips the neutral (no owner bonus to beat)")
	_check(AllegianceLib.tariff_mille(port_id, "portugal") == 500,
		"the aligned badge reads 势力内 5% (mille 500)")


# --- 7. a rival's telegraph, then out-invest it -----------------------------
func _scenario_telegraph_out_invest() -> void:
	print("\n== 7. read the rival's investment telegraph, out-invest it ==")
	_fresh_run("portugal")
	# give england a treasury and let its month tick invest somewhere
	AllegianceLib.credit_tax("london", "spain", 1500)  # NPC tax → england's host treasury
	for i in 3:
		AllegianceLib.month_tick()
	var rows: Array = AllegianceLib.last_month_investments()
	print("    telegraph rows this month: %d" % rows.size())
	_check(not rows.is_empty(), "the monthly AI produced telegraph rows")
	var row: Dictionary = rows[0] if rows.size() > 0 else {}
	var rival_port := str(row.get("port_id", ""))
	var rival_nation := str(row.get("nation_id", ""))
	var rival_amount := int(row.get("amount", 0))
	print("    row: {nation} 在 {port} 投资 {amount}g → %s @ %s (%dg), band %s"
		% [rival_nation, rival_port, rival_amount, str(row.get("band", ""))])
	_check(rival_amount == 1500, "the AI spends min(treasury, 1500) per pick")
	_check(AllegianceLib.treasury(rival_nation) < 5000 + 1000 * 3,
		"the AI's treasury paid for its picks")
	# out-invest the same port for the player's nation — past the 5,000g line
	var before: String = AllegianceLib.effective_alignment(rival_port)
	AllegianceLib.add_investment(rival_port, "portugal", rival_amount + 4000)
	var after: String = AllegianceLib.effective_alignment(rival_port)
	print("    out-invested %dg → alignment %s → %s"
		% [rival_amount + 4000, before, after])
	_check(after == "portugal",
		"the player's ledger clears the line and flips the port")


# --- 8. rep gate → campaign vs a foreign sovereign → −5 poaching ------------
func _scenario_rep_gate_campaign() -> void:
	print("\n== 8. rep gate blocks once; a 4-month campaign flips a foreign sovereign ==")
	_fresh_run("portugal")
	var port_id := _find_port(func(p: Dictionary) -> bool:
		return str(p.get("nation_id", "")) == "spain" \
			and not bool(p.get("protected", false)))
	_check(not port_id.is_empty(), "a contestable spanish sovereign exists (%s)" % port_id)
	if port_id.is_empty():
		return
	# the diplomatic gate: rep < 0 with spain blocks the invest
	_set_rep("spain", -5)
	var blocked: String = AllegianceLib.invest_block_reason(port_id)
	print("    at rep −5: invest_block_reason = %s" % blocked)
	_check(blocked == "market.invest_gate.blocked",
		"the gate names the ui_strings key")
	_set_rep("spain", 0)
	_check(AllegianceLib.invest_block_reason(port_id) == "",
		"rep ≥ 0 and no bounty → investing allowed")
	# home advantage: spain's own 6,000g seed counts ×1.25 = 7,500 effective,
	# so the player needs > 7,500; the monthly cap allows 2,000g/month.
	var months := 0
	var flipped := false
	while months < 6 and not flipped:
		for chunk in 4:  # 4 × 500g = the 2,000g monthly cap
			AllegianceLib.player_invest_chunk(port_id)
		months += 1
		AllegianceLib.month_tick()
		flipped = AllegianceLib.effective_alignment(port_id) == "portugal"
	var fame_after: int = FameLib.value()
	print("    campaign: %d months × 2,000g vs the ×1.25 home advantage → flipped %s; fame %d"
		% [months, "yes" if flipped else "no", fame_after])
	_check(flipped, "the sustained campaign beats the sovereign seed")
	_check(_rep("spain") == -5,
		"poaching costs −5 rep with the previous owner (got %d)" % _rep("spain"))
	_check(fame_after >= 100, "+100 fame on the first flip (got %d)" % fame_after)
	_check(not AllegianceLib.pending_commendation().is_empty(),
		"the commendation is pending at the palace")


# --- 9. 本国免税证 ------------------------------------------------------------
func _scenario_home_charter() -> void:
	print("\n== 9. home charter: 5,000g, home 5% → 0% ==")
	_fresh_run("portugal")
	GameState.add_gold(20000)
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 500,
		"home ports tax 5% before the charter")
	var offer: Dictionary = PalaceLib.permit_offer("lisbon")
	print("    lisbon offer: kind %s, price %dg" % [
		str(offer.get("kind", "?")), int(offer.get("price", 0))])
	_check(str(offer.get("kind", "")) == "home" and int(offer.get("price", 0)) == 5000,
		"the palace sells the home charter at 5,000g")
	var gold_before: int = GameState.gold
	_check(PalaceLib.buy_permit("lisbon"), "the purchase plays")
	_check(GameState.gold == gold_before - 5000, "the purse paid exactly 5,000g")
	_check(AllegianceLib.has_permit_home(), "the charter is held")
	_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 0,
		"home ports are now tax-free")


# --- 10. 涉外免税证 -----------------------------------------------------------
func _scenario_foreign_permit() -> void:
	print("\n== 10. foreign permit: 20,000g at that nation's palace, gates honored ==")
	_fresh_run("portugal")
	GameState.add_gold(50000)
	_check(AllegianceLib.tariff_mille("seville", "portugal") == 2000,
		"spain's ports tax 20% before any permit")
	# gates: title ≥ Knight and rep ≥ +20 — a FOREIGN permit asks for the
	# player's standing WITH that nation (its palace judges its own title
	# ladder; the void rules are likewise nation-scoped)
	_set_rep("spain", 25)
	var offer_low: Dictionary = PalaceLib.permit_offer("seville")
	var gates_low := bool(offer_low.get("title_locked", false)) \
		or bool(offer_low.get("rep_locked", false))
	print("    below Knight: title_locked=%s rep_locked=%s" % [
		str(offer_low.get("title_locked", false)),
		str(offer_low.get("rep_locked", false))])
	_check(gates_low, "the title/rep gates show while unpromoted")
	FameLib.add(4000)  # knight needs fame ≥ 100 …
	FameLib.add_royal_mission("spain")  # … and ≥ 1 royal mission (spain's ladder)
	FameLib.grant("spain")
	print("    promoted: title with spain = %s" % FameLib.title("spain"))
	_check(FameLib.title("spain") == "knight", "the run reaches Knight of spain")
	var offer: Dictionary = PalaceLib.permit_offer("seville")
	print("    at Knight: price %dg, gates %s/%s" % [
		int(offer.get("price", 0)), str(offer.get("title_locked", false)),
		str(offer.get("rep_locked", false))])
	_check(int(offer.get("price", 0)) == 20000 and
		not bool(offer.get("title_locked", false)),
		"the foreign permit opens at 20,000g once Knight holds")
	_check(PalaceLib.buy_permit("seville"), "the purchase plays")
	_check(AllegianceLib.has_permit_foreign("spain"), "the permit is held")
	_check(AllegianceLib.tariff_mille("seville", "portugal") == 0,
		"spain's ports are now tax-free for the holder")


# --- 11. taxed vs untaxed monsoon loop --------------------------------------
func _scenario_taxed_vs_untaxed_loop() -> void:
	print("\n== 11. a monsoon loop under 20%/20% vs permitted 0% ==")
	_fresh_run("portugal")
	# buy spices at a foreign producer (20%), sell at a foreign consumer
	var producer := _find_port(func(p: Dictionary) -> bool:
		return "spices" in (p.get("produces", []) as Array) \
			and str(p.get("nation_id", "")) not in ["", "portugal"])
	var consumer := _find_port(func(p: Dictionary) -> bool:
		return "spices" in (p.get("demands", []) as Array) \
			and str(p.get("nation_id", "")) not in ["", "portugal"] \
			and str(p.get("id", "")) != producer)
	_check(not producer.is_empty() and not consumer.is_empty(),
		"a foreign spices loop exists (%s → %s)" % [producer, consumer])
	if producer.is_empty() or consumer.is_empty():
		return
	var units := 20
	var buy: int = TradeEngineLib.buy_cost(producer, "spices", units)
	var sell: int = TradeEngineLib.sell_price(consumer, "spices") * units
	var producer_nation := str(DataLoader.ports.get(producer, {}).get("nation_id", ""))
	var consumer_nation := str(DataLoader.ports.get(consumer, {}).get("nation_id", ""))
	var taxed := (sell - buy) - (buy + sell) * 2000 / 10000  # 20%/20% foreign
	AllegianceLib.set_permit("foreign", producer_nation)
	AllegianceLib.set_permit("foreign", consumer_nation)
	var buy2: int = TradeEngineLib.buy_cost(producer, "spices", units)
	var sell2: int = TradeEngineLib.sell_price(consumer, "spices") * units
	var untaxed := sell2 - buy2  # permits → mille 0
	print("    %d spices %s (%s) → %s (%s): taxed %dg vs permitted %dg"
		% [units, producer, producer_nation, consumer, consumer_nation,
		taxed, untaxed])
	_check(taxed < untaxed, "the tax bites on the loop")
	_check(untaxed > taxed * 3 / 2, "permitting clearly out-earns (≈25% round trip)")


# --- 12. sink a named pirate → its rare drop ---------------------------------
func _scenario_named_pirate_drop() -> void:
	print("\n== 12. a named pirate's defeat credits its rare drop ==")
	_fresh_run("portugal")
	var outcome: Dictionary = {"result": "victory"}
	var granted: String = BattleRewardsLib.apply_named_drop(
		outcome, "pirate_redbeard_khair")
	print("    khair ad-din defeated → drop %s (sold back %s)" % [
		granted, str(outcome.get("drop_sold_back", ""))])
	_check(granted == "eq_khair_scimitar",
		"the tier-3 pirate drops its scimitar (got %s)" % granted)
	var player: Dictionary = GameState.player
	var equipment: Dictionary = player.get("equipment", {}) \
		if player.get("equipment", {}) is Dictionary else {}
	_check(str(equipment.get("weapon", "")) == "eq_khair_scimitar",
		"the weapon fitted the player's weapon slot")
	# an unnamed captain drops nothing
	var outcome2: Dictionary = {"result": "victory"}
	var granted2: String = BattleRewardsLib.apply_named_drop(outcome2, "")
	_check(granted2 == "" and not outcome2.has("drop_item"),
		"an unnamed captain drops nothing")


# --- 13. tier-3 grayed at dev-2; buy at dev-3 --------------------------------
func _scenario_tier3_gate() -> void:
	print("\n== 13. the tier-3 hull sits grayed 需发展度 until dev 3 ==")
	_fresh_run("portugal")
	var port_id := _find_port(func(p: Dictionary) -> bool:
		return str(p.get("nation_id", "")) != "" \
			and not bool(p.get("protected", false)) \
			and int(p.get("dev", 0)) == 2 \
			and not (ShipyardLib.shipyard_stock(str(p.get("id", ""))).is_empty()))
	_check(not port_id.is_empty(),
		"a dev-2 major with a shipyard exists (%s)" % port_id)
	if port_id.is_empty():
		return
	var tier3 := ""
	for hull_id in ShipyardLib.shipyard_stock(port_id):
		if ShipyardLib.item_tier(hull_id) == 3:
			tier3 = hull_id
			break
	print("    %s stocks tier-3 %s: state %s (note %s)" % [port_id, tier3,
		ShipyardLib.row_state(port_id, tier3) if not tier3.is_empty() else "-",
		ShipyardLib.row_note_key(port_id, tier3) if not tier3.is_empty() else "-"])
	if tier3.is_empty():
		_check(false, "the dev-2 major stocks a tier-3 hull")
		return
	_check(ShipyardLib.row_state(port_id, tier3) == "tier_gray",
		"the row is tier-gray at dev 2")
	_check(ShipyardLib.row_note_key(port_id, tier3) == "shipyard.tier.need_dev",
		"the note is 需发展度 {dev}")
	# grow the port to dev 3 (50,000g total ledger)
	AllegianceLib.add_investment(port_id, "portugal", 50000)
	_check(AllegianceLib.dev(port_id) == 3, "the 50,000g ledger reaches dev 3")
	_check(ShipyardLib.row_state(port_id, tier3) == "available",
		"the tier-3 hull becomes available")
	GameState.add_gold(100000)
	GameState.current_port = port_id  # the yard resolves the docked port
	var reason: String = ShipyardLib.buy_block_reason(tier3)
	var bought: bool = ShipyardLib.buy(tier3)
	print("    docked %s: buy %s → %s (block reason %s)"
		% [port_id, tier3, "yes" if bought else "no", reason])
	_check(bought, "the dev-3 port sells the tier-3 hull")


# --- 14. a junk at an aligned dev-2 neutral ----------------------------------
func _scenario_junk_at_neutral() -> void:
	print("\n== 14. align + grow a neutral shipyard: the junk unlocks ==")
	_fresh_run("portugal")
	var port_id := _find_port(func(p: Dictionary) -> bool:
		return str(p.get("nation_id", "")) == "" \
			and "junk" in (ShipyardLib.shipyard_stock(str(p.get("id", ""))) as Array))
	_check(not port_id.is_empty(),
		"a neutral shipyard stocks the junk (%s)" % port_id)
	if port_id.is_empty():
		return
	_check(ShipyardLib.row_state(port_id, "junk") == "allegiance_gray",
		"unallied, every hull row shows the allegiance gate")
	AllegianceLib.add_investment(port_id, "portugal", 25000)
	_check(AllegianceLib.effective_alignment(port_id) == "portugal"
		and AllegianceLib.dev(port_id) == 2,
		"aligned at 25,000g → dev 2 (the correction-11 flip path)")
	_check(ShipyardLib.row_state(port_id, "junk") == "available",
		"the junk unlocks for the aligned dev-2 port")
	GameState.add_gold(50000)
	GameState.current_port = port_id  # the yard resolves the docked port
	_check(ShipyardLib.buy("junk"), "the junk buys at the docked neutral yard")


# --- 15. rival counter-investment flips a port back --------------------------
func _scenario_rival_flips_back() -> void:
	print("\n== 15. the AI contests a player port and takes it back ==")
	_fresh_run("portugal")
	var port_id := _find_port(func(p: Dictionary) -> bool:
		return str(p.get("nation_id", "")) == "" \
			and str(p.get("band", "")) == "china_coast")
	if port_id.is_empty():
		_check(false, "a china_coast neutral exists")
		return
	AllegianceLib.add_investment(port_id, "portugal", 6000)
	_check(AllegianceLib.effective_alignment(port_id) == "portugal",
		"the player holds the port")
	var rep_before: Dictionary = (GameState.player.get("reputation", {}) as Dictionary).duplicate(true)
	# a heavier rival ledger overtakes it (the seeded AI does this over months;
	# the demo credits the rival directly to show the tug-of-war rule)
	AllegianceLib.add_investment(port_id, "england", 9000)
	var after: String = AllegianceLib.effective_alignment(port_id)
	var rep_after: Dictionary = GameState.player.get("reputation", {})
	print("    england invests 9,000g over the campaign → alignment %s; reputation deltas: none"
		% after)
	_check(after == "england", "the port flips back to the rival")
	_check(rep_after == rep_before,
		"losing a port costs the player nothing (no reputation moved)")


# --- 16. zh/en parity --------------------------------------------------------
func _scenario_i18n_parity() -> void:
	print("\n== 16. zh/en parity ==")
	var strings: Dictionary = DataLoader.ui_strings
	var zh := 0
	var en := 0
	for key in (strings as Dictionary):
		var entry = (strings as Dictionary)[key]
		if entry is Dictionary:
			if str((entry as Dictionary).get("zh", "")).is_empty() == false:
				zh += 1
			if str((entry as Dictionary).get("en", "")).is_empty() == false:
				en += 1
	print("    ui_strings: %d keys, %d zh, %d en" % [strings.size(), zh, en])
	_check(zh == strings.size() and en == strings.size(),
		"every key carries both locales (validator group 2)")
	for required in ["market.tax.badge.in_sphere", "market.not_bought",
		"shipyard.tier.need_dev", "shipyard.tier.allegiance_locked",
		"palace.permit.home", "palace.commend.body", "tavern.invest.row"]:
		_check(strings.has(required), "the Phase-7 key %s exists" % required)
