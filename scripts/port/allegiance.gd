class_name Allegiance
extends RefCounted
## Port allegiance, development, treasuries, tariffs and permits (Phase 7) —
## docs/30-PORTS-AND-TRADE.md §4.9 (allegiance & development) and §4.10 (tax &
## permits), docs/30 §4.3 (the investment ledger effect), docs/70-* §4.1 (the
## allegiance fame paragraph), docs/80-* §4.9 (the symbol contracts — THIS
## module implements exactly those signatures), docs/90-* §5.4 (month-tick
## ordering: one seam in `sailing_sim.advance_clock`, one owner: this module).
##
## **Pure** in the house sense (docs/90-* §4): RefCounted, static functions,
## no node references, headless-testable — the same shape as `economy.gd` /
## `trade_engine.gd`.
##
## **Two port classes (decision 25).** `ports.json` carries
## `protected: true` on the 17 core ports. A protected port's alignment is its
## owner forever, its dev is the authored floor forever, and player investment
## there is discount-only (no ledger, no monthly cap). Every other port is
## **contestable**: a per-nation cumulative gold ledger, allegiance = strictly
## the highest effective ledger ≥ 5,000g (ties keep the incumbent — which is
## why allegiance is persisted state, correction 8), dev derived from the
## ledger thresholds (10,000 / 25,000 / 50,000) over the authored floor.
##
## **Runtime state lives here** (save v7 lands in W4, task V — see
## [method dump_state] / [method restore_state] for the wiring seam): the
## ledgers, the persisted allegiance per contestable port, the monthly
## player-investment counter, the nation treasuries, the permit flags, the
## first-flip fame ledger and the telegraph ring buffer. Nothing in this file
## writes `GameState` save blocks directly, so V can move the four v7 keys
## (`port_allegiance`, `month_invested`, `nation_treasuries`, `fame_commended`
## + `permits`) into the payload without rework.
##
## **Determinism.** The monthly NPC counter-investment is a pure function of
## (month index, nation ordinals, candidate ordinals, treasury state): the
## seed formula is the docs/70 style
## `month_index × 1000003 + nation_ordinal × 7919 + port_ordinal × 104729`
## (docs/30 §4.9), every candidate list is sorted by id, and the RNG draws are
## `randi_range(1, 3)` against the lane-adjacency weight. The same state always
## replays the same investment sequence (`tools/test_allegiance.gd` proves it).

const FameLib := preload("res://scripts/player/fame.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")

# --- §4.9 locked constants ---------------------------------------------------

## Home advantage (decision 26): the sovereign owner's ledger counts
## × 1.25 — integer math `raw × 5 / 4` (docs/30 §4.9).
const EFFECTIVE_NUM := 5
const EFFECTIVE_DEN := 4
## Allegiance line: strictly the highest effective ledger, ≥ 5,000g.
const ALIGNMENT_MIN_GOLD := 5000
## Dev thresholds over the total ledger: dev 1 / 2 / 3 (docs/30 §4.9).
const DEV_THRESHOLD_1 := 10000
const DEV_THRESHOLD_2 := 25000
const DEV_THRESHOLD_3 := 50000
## A contestable sovereign begins `{owner: 6,000}` — allied (7,500 effective),
## below dev-1's 10,000g (docs/30 §4.9).
const SEED_OWNER_LEDGER := 6000

# --- §4.9 treasuries ---------------------------------------------------------

## Every nation starts with 5,000g (docs/30 §4.9).
const TREASURY_START := 5000
## Monthly baseline income, credited on the month tick.
const TREASURY_BASELINE := 1000
## NPC-sourced tax is capped at 2,000g per (host) nation per month
## (decision 19); the player's own tax is uncapped.
const NPC_TAX_MONTHLY_CAP := 2000

# --- §4.9 monthly AI counter-investment -------------------------------------

## Each AI nation makes 0–2 picks per month (docs/30 §4.9).
const AI_PICKS_MAX := 2
## `spend = min(treasury, 1500)` per pick.
const AI_SPEND_CAP := 1500
## The seed formula family (docs/30 §4.9, the docs/70 seed style).
const AI_SEED_MONTH_MULT := 1000003
const AI_SEED_NATION_MULT := 7919
const AI_SEED_PORT_MULT := 104729
## Per-candidate draw: `randi_range(1, 3) <= weight` — base weight 1 picks a
## third of the time, lane-adjacent weight 2 two thirds. The docs pin the
## 0–2 range, the treasury bound and the weighting *direction*; this draw is
## the module's pinned interpretation of "weighted" (reported to the master
## for ratification — the only number here not read off a doc table).
const AI_WEIGHT_BASE := 1
const AI_WEIGHT_LANE := 2
const AI_WEIGHT_SIDES := 3

# --- §4.9 telegraphs ---------------------------------------------------------

## Visible 30 days in the invested port's band (decision 24).
const TELEGRAPH_WINDOW_DAYS := 30
## Ring-buffer cap (the window keeps a month's rows alive anyway).
const TELEGRAPH_BUFFER_MAX := 64

# --- §4.10 tariff & permits --------------------------------------------------

## Per-ten-thousand rates ("mille" per the C contract's basis points):
## 5% in sphere, 20% foreign, 0% under a valid permit.
const TARIFF_SCALE := 10000
const TARIFF_ALIGNED := 500
const TARIFF_FOREIGN := 2000
const TARIFF_EXEMPT := 0
## 本国免税证: 5,000g, own palaces, no title/rep gate (docs/30 §4.10).
const PERMIT_HOME_PRICE := 5000
## 涉外免税证: 20,000g, that nation's palaces, title ≥ Knight, rep ≥ +20.
const PERMIT_FOREIGN_PRICE := 20000
const PERMIT_FOREIGN_MIN_REP := 20
## Phase 8 negotiation gates (docs/30 §4.10, 2026-11-02): the home charter
## sells at ×95% (4,750g) when negotiation ≥ 40, the foreign permit at ×90%
## (18,000g) when ≥ 70; full price below the gate. Thresholds live in
## `data/skill_gates.json` (`permit.home_discount` / `permit.foreign_discount`)
## — read through `permit_price` when slot A's loader lands, else the doc
## numbers.
const PERMIT_HOME_GATE := 40
const PERMIT_FOREIGN_GATE := 70
const PERMIT_HOME_DISCOUNT_NUM := 95
const PERMIT_FOREIGN_DISCOUNT_NUM := 90
## Both kinds are void while that nation's bounty is held or rep < −20.
const PERMIT_VOID_REP := -20

# --- §2.6 fame & §4.9 campaign ----------------------------------------------

## +100 fame the first time a contestable port flips to the player's nation
## (once per port per save); +25 per dev threshold reached at an aligned port.
const FAME_FIRST_FLIP := 100
const FAME_PER_DEV_LEVEL := 25
## Poaching: the player's nation gaining a foreign sovereign port costs −5 rep
## with the previous owner, one-time per flip (none on losing it back).
const POACHING_REP := -5
## ≤ 2,000g player investment per contestable port per month (decision 26).
const MONTHLY_INVEST_CAP := 2000
## The §4.3 fixed chunk (`trade_engine.INVEST_CHUNK` mirrors the same locked
## 500g; a preload would be circular, so the locked value is restated here).
const INVEST_CHUNK := 500
## 30-day months (docs/20-* §4.3; the sailing_sim seam tests `day % 30 == 1`).
const MONTH_DAYS := 30

# --- Runtime state (the W4/V persistence seam — see dump_state) --------------

## `{port_id: {nation_id: gold}}` — cumulative, contestable ports only.
static var _ledgers: Dictionary = {}
## `{port_id: nation_id | ""}` — persisted (the tie rule keeps the incumbent).
static var _allegiances: Dictionary = {}
## `{port_id: gold}` — the ≤ 2,000g/month player counter, reset month-tick.
static var _month_invested: Dictionary = {}
## `{nation_id: gold}` — start 5,000, +1,000/mo + tax + permit sales.
static var _treasuries: Dictionary = {}
## `{host_nation_id: gold}` — NPC-sourced tax credited this month (the cap).
static var _npc_tax_month: Dictionary = {}
## Telegraph ring buffer: `{nation_id, port_id, band, amount, day}` rows.
static var _telegraphs: Array = []
## `{port_id: true}` — first flip to the player's nation honored (+100 fame,
## commendation pending). The save v7 `fame_commended` key.
static var _fame_commended: Dictionary = {}
## Ports flipped to the player whose commendation dialog is unshown
## (transient — the dialog is a palace surface, task F renders it).
static var _pending_commendations: Array = []
## Ports whose commendation dialog was shown (transient session state).
static var _commendations_shown: Dictionary = {}
## `{port_id: dev}` — highest dev level whose +25 fame was already awarded
## (transient; re-derived on restore so thresholds never re-award).
static var _threshold_dev: Dictionary = {}
## `{"home": bool, "foreign": {nation_id: bool}}` — the permit flags
## (the save v7 `permits` key; docs/30 §4.10).
static var _permits: Dictionary = {"home": false, "foreign": {}}
## `{nation_id: {port_id: true}}` — lazy lane-adjacency cache (data-derived).
static var _lane_adjacency: Dictionary = {}
## Seeding/restore guards: allegiance writes stay silent (no flip hooks).
static var _seeding: bool = false
static var _restoring: bool = false


# --- Classes & alignment (docs/80-* §4.9 contract) ---------------------------

## True when `port_id` is a protected core port (`ports.json protected: true`).
## An unknown port is not protected.
static func is_protected(port_id: String) -> bool:
	return bool(DataLoader.get_port(port_id).get("protected", false))


## The port's effective alignment: the owner at a protected port, the
## persisted allegiance at a contestable port, `""` unaligned
## (docs/30 §4.9/§4.10; the guard-call default elsewhere is the data
## `nation_id` — inside this module the real state is authoritative).
static func effective_alignment(port_id: String) -> String:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return ""
	if bool(port.get("protected", false)):
		return str(port.get("nation_id", ""))
	return str(_allegiances.get(port_id, ""))


## Effective ledger value of `nation_id` at `port_id`: raw, except the
## sovereign owner's × 1.25 (`raw × 5 / 4`, docs/30 §4.9). 0 when unrecorded.
static func effective_value(port_id: String, nation_id: String) -> int:
	var raw := ledger_of(port_id, nation_id)
	if nation_id == str(DataLoader.get_port(port_id).get("nation_id", "")):
		@warning_ignore("integer_division")
		return raw * EFFECTIVE_NUM / EFFECTIVE_DEN
	return raw


## One nation's raw ledger entry (0 when unrecorded / protected / unknown).
static func ledger_of(port_id: String, nation_id: String) -> int:
	if is_protected(port_id):
		return 0
	return int((_ledgers.get(port_id, {}) as Dictionary).get(nation_id, 0))


## The port's total ledger over all nations (the dev-threshold basis).
static func ledger_total(port_id: String) -> int:
	var total := 0
	for nation_id in (_ledgers.get(port_id, {}) as Dictionary):
		total += int((_ledgers[port_id] as Dictionary)[nation_id])
	return total


## Read-only copy of one port's raw ledger (`{nation_id: gold}`) — the
## chart's debug port panel per-nation rows (docs/95-* §7.2). Empty at a
## protected port (no ledger exists there).
static func port_ledger(port_id: String) -> Dictionary:
	return (_ledgers.get(port_id, {}) as Dictionary).duplicate(true)


# --- Development (derived — never saved, correction 8) -----------------------

## `max(authored floor, ledger thresholds)` (docs/30 §4.9): protected ports
## stay at their authored floor forever; a contestable port grows when its
## **total** ledger crosses 10,000 / 25,000 / 50,000. Unknown port → 0.
static func dev(port_id: String) -> int:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return 0
	var level := maxi(0, int(port.get("dev", 0)))
	if bool(port.get("protected", false)):
		return level
	var total := ledger_total(port_id)
	if total >= DEV_THRESHOLD_3:
		return maxi(level, 3)
	if total >= DEV_THRESHOLD_2:
		return maxi(level, 2)
	if total >= DEV_THRESHOLD_1:
		return maxi(level, 1)
	return level


# --- Ledger writes & allegiance resolution -----------------------------------

## Adds `gold` for `nation_id` at a **contestable** `port_id`, then re-resolves
## the allegiance (flip hooks included). Protected ports have no ledger: a
## call there is a no-op. This is the single ledger entry point — the player's
## market chunk and the monthly NPC counter-investment both go through it.
static func add_investment(port_id: String, nation_id: String, gold: int) -> void:
	if gold <= 0 or nation_id.is_empty() or is_protected(port_id):
		return
	if DataLoader.get_port(port_id).is_empty():
		return
	if not _ledgers.has(port_id):
		_ledgers[port_id] = {}
	var ledger: Dictionary = _ledgers[port_id]
	ledger[nation_id] = int(ledger.get(nation_id, 0)) + gold
	_award_threshold_fame(port_id)
	_resolve_allegiance(port_id)


## Strictly the highest effective ledger ≥ 5,000g wins; ties keep the
## incumbent (docs/30 §4.9). Candidates iterate in sorted-nation order so the
## resolution is a pure function of the ledger state.
static func _resolve_allegiance(port_id: String) -> void:
	var ledger: Dictionary = _ledgers.get(port_id, {})
	var best_value := -1
	var best_nation := ""
	var tied: Array = []
	for nation_id in ledger.keys():
		var value := effective_value(port_id, str(nation_id))
		if value > best_value:
			best_value = value
			best_nation = str(nation_id)
			tied = [str(nation_id)]
		elif value == best_value:
			tied.append(str(nation_id))
	var next := ""
	if best_value >= ALIGNMENT_MIN_GOLD:
		tied.sort()
		var incumbent := str(_allegiances.get(port_id, ""))
		next = incumbent if tied.has(incumbent) else str(tied[0])
	_set_allegiance(port_id, next)


## Applies a new allegiance and runs the §2.6 / §4.9 flip hooks: the +100
## first-flip fame (+ pending commendation), the −5 poaching rep on taking a
## foreign sovereign port, and the dev-fame tracker re-baseline. Seeding and
## restoring set allegiances **silently** — the starting state is not an
## event, so no fame/poaching/commendation fires for it.
static func _set_allegiance(port_id: String, next: String) -> void:
	var previous := str(_allegiances.get(port_id, ""))
	if next == previous:
		return
	_allegiances[port_id] = next
	if _seeding or _restoring:
		_threshold_dev[port_id] = dev(port_id)
		return
	var player := _player_nation()
	if next == player and not player.is_empty():
		# §2.6: +100 fame the first time this port flips to the player's nation
		# (once per port per save), plus the one-time palace commendation.
		if not _fame_commended.has(port_id):
			_fame_commended[port_id] = true
			FameLib.add(FAME_FIRST_FLIP)
			if not _pending_commendations.has(port_id):
				_pending_commendations.append(port_id)
		# §4.9 poaching: the port is a foreign sovereign (owned by another
		# nation) and was aligned to a nation — −5 rep with the previous owner,
		# once per flip. Losing it back costs nothing.
		var owner := str(DataLoader.get_port(port_id).get("nation_id", ""))
		if not owner.is_empty() and owner != player \
				and not previous.is_empty() and previous != player:
			CharacterLib.add_reputation(previous, POACHING_REP)
	# The threshold tracker re-baselines at the flip: thresholds reached while
	# aligned to another nation are never retro-awarded (§2.6 awards the
	# crossing, and the crossing already happened).
	_threshold_dev[port_id] = dev(port_id)


## The +25 fame per dev level reached at a contestable port **aligned to the
## player's nation** (§2.6). Called on every ledger add, before the allegiance
## resolves — the alignment read is the pre-add state, which is exactly "the
## port the investment was made into".
static func _award_threshold_fame(port_id: String) -> void:
	if is_protected(port_id):
		return
	var player := _player_nation()
	if player.is_empty() or str(_allegiances.get(port_id, "")) != player:
		_threshold_dev[port_id] = dev(port_id)
		return
	var level := dev(port_id)
	var rewarded := maxi(0, int(_threshold_dev.get(port_id, 0)))
	if level > rewarded:
		FameLib.add(FAME_PER_DEV_LEVEL * (level - rewarded))
	_threshold_dev[port_id] = maxi(rewarded, level)


# --- Player investment hooks (docs/30 §4.3, decision 26) ---------------------

## The month's player-investment gold at `port_id` (0 when none).
static func month_invested_gold(port_id: String) -> int:
	return maxi(0, int(_month_invested.get(port_id, 0)))


## The three-state Invest gate (decision 26): `""` investable, else a
## `market.invest_gate.*` ui_strings key (the caller resolves it through
## `I18n.t`). Allowance first, then the diplomatic gate. Protected ports have
## no monthly allowance; every aligned port gates on rep/bounty vs its
## alignment nation; unaligned contestable ports have no gate at all.
static func invest_block_reason(port_id: String) -> String:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return ""
	if not bool(port.get("protected", false)):
		if month_invested_gold(port_id) + INVEST_CHUNK > MONTHLY_INVEST_CAP:
			return "market.invest_gate.exhausted"
	var alignment := effective_alignment(port_id)
	if not alignment.is_empty():
		if CharacterLib.reputation(alignment) < 0 \
				or BountyLib.has_bounty(alignment):
			return "market.invest_gate.blocked"
	return ""


## The ledger side of one 500g player chunk at a contestable port (docs/30
## §4.3): +500g to the player-nation's ledger, +500g to the monthly counter,
## allegiance re-resolved. The gold charge and the discount block stay with
## `TradeEngine.invest` (the standing arithmetic is unchanged).
static func player_invest_chunk(port_id: String) -> void:
	var nation := _player_nation()
	if nation.is_empty():
		return
	add_investment(port_id, nation, 500)
	_month_invested[port_id] = month_invested_gold(port_id) + 500


# --- Tariff (docs/30 §4.10; docs/80-* §4.9 contract) -------------------------

## 0 / 500 / 2000 per the C contract (basis points over 10,000): 5% when the
## effective alignment == the trader's nation, 20% otherwise, 0% under a valid
## covering permit. An unaligned contestable port is 20% forever — no permit
## can ever cover it (docs/30 §4.10). Called by `trade_engine` (the player's
## trades) and by the NPC crediting (task N, W4) with the fleet's nation.
static func tariff_mille(port_id: String, nation_id: String) -> int:
	var alignment := effective_alignment(port_id)
	if alignment.is_empty():
		return TARIFF_FOREIGN
	if _permit_covers(alignment, nation_id):
		return TARIFF_EXEMPT
	return TARIFF_ALIGNED if alignment == nation_id else TARIFF_FOREIGN


## True when a **valid** permit held by the trader `nation_id` covers a port
## aligned to `alignment`. Only the player holds permits (the palace sales are
## player surfaces), so an NPC trader's nation never exempts.
static func _permit_covers(alignment: String, trader_nation: String) -> bool:
	var player := _player_nation()
	if player.is_empty() or trader_nation != player:
		return false
	if bool(_permits.get("home", false)) and alignment == player \
			and not permit_void(player):
		return true
	var foreign: Dictionary = _permits.get("foreign", {})
	if bool(foreign.get(alignment, false)) and alignment != player \
			and not permit_void(alignment):
		return true
	return false


## `""` valid, else the `palace.permit.void_*` ui_strings key: a held permit is
## void while that nation's bounty stands or rep < −20 (docs/30 §4.10).
static func permit_void_reason(nation_id: String) -> String:
	if BountyLib.has_bounty(nation_id):
		return "palace.permit.void_bounty"
	if CharacterLib.reputation(nation_id) < PERMIT_VOID_REP:
		return "palace.permit.void_rep"
	return ""


static func permit_void(nation_id: String) -> bool:
	return not permit_void_reason(nation_id).is_empty()


# --- Permit price gates (docs/30 §4.10, Phase 8) -----------------------------

## Headless-suite seam for slot A's `Skills` module (the `market_screen.gd`
## `allegiance_override` convention): an object answering
## `effective_skill(key)` / `skill(key)`. The runtime never sets it;
## pre-merge worktrees answer 0 (skills start at 0, docs/50 §4.3).
static var skills_override: Variant = null

## Slot A's Skills script — restated instead of preloaded (a preload of
## `trade_engine.gd`'s guard would be circular; the same convention as
## `INVEST_CHUNK` above).
const SKILLS_PATH := "res://scripts/player/skills.gd"


## The player's **effective** negotiation — the same guard chain as
## `trade_engine.skill_value` (the suite seam, slot A's `Skills` autoload
## node, its script statics, else 0).
static func negotiation_skill() -> int:
	for method in ["effective_skill", "skill"]:
		if skills_override is Object \
				and (skills_override as Object).has_method(method):
			return maxi(0, int(skills_override.call(method, "negotiation")))
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var node := (tree as SceneTree).root.get_node_or_null("Skills")
		if node != null:
			for method in ["effective_skill", "skill"]:
				if node.has_method(method):
					return maxi(0, int(node.call(method, "negotiation")))
	if ResourceLoader.exists(SKILLS_PATH):
		var script: Variant = ResourceLoader.load(SKILLS_PATH)
		if script is Script:
			for method in ["effective_skill", "skill"]:
				if (script as Script).has_method(method):
					return maxi(0,
						int((script as Script).call(method, "negotiation")))
	return 0


## The §4.3.5 gate threshold (`feature_id` → threshold): slot A's
## `DataLoader.skill_gates` first (keyed by `feature_id`), else the doc
## default. Guarded so the suites run standalone.
static func _gate_threshold(feature_id: String, doc_default: int) -> int:
	var gates = DataLoader.get("skill_gates")
	if gates is Dictionary:
		var row = (gates as Dictionary).get(feature_id, {})
		if row is Dictionary and (row as Dictionary).has("threshold"):
			return maxi(0, int((row as Dictionary)["threshold"]))
	return doc_default


## The §4.10 permit price for `kind` (`"home"` / `"foreign"`, `""` → 0) after
## the Phase-8 negotiation gate: the home charter 5,000g → **4,750g** at
## negotiation ≥ 40, the foreign permit 20,000g → **18,000g** at ≥ 70, full
## price below the gate (docs/30 §4.10 — the discounted values are the exact
## products 5000 × 95 / 100 and 20000 × 90 / 100). `palace_engine.permit_offer`
## answers this, so the row display and the `buy_permit` charge agree.
static func permit_price(kind: String) -> int:
	if kind == "home":
		if negotiation_skill() >= _gate_threshold("permit.home_discount",
				PERMIT_HOME_GATE):
			@warning_ignore("integer_division")
			return PERMIT_HOME_PRICE * PERMIT_HOME_DISCOUNT_NUM / 100
		return PERMIT_HOME_PRICE
	if kind == "foreign":
		if negotiation_skill() >= _gate_threshold("permit.foreign_discount",
				PERMIT_FOREIGN_GATE):
			@warning_ignore("integer_division")
			return PERMIT_FOREIGN_PRICE * PERMIT_FOREIGN_DISCOUNT_NUM / 100
		return PERMIT_FOREIGN_PRICE
	return 0


## Writes the permit flags (palace purchase seam — `palace_engine` calls this
## after its price/gate checks). `kind` is `"home"` or `"foreign"`.
static func set_permit(kind: String, nation_id: String) -> void:
	if kind == "home":
		_permits["home"] = true
	elif kind == "foreign" and not nation_id.is_empty():
		var foreign: Dictionary = _permits.get("foreign", {})
		foreign[nation_id] = true
		_permits["foreign"] = foreign


## True when the home charter (本国免税证) is held (void state ignored — the
## void rules gate *coverage*, see `permit_void_reason`).
static func has_permit_home() -> bool:
	return bool(_permits.get("home", false))


## True when the foreign permit (涉外免税证) for `nation_id` is held.
static func has_permit_foreign(nation_id: String) -> bool:
	return bool((_permits.get("foreign", {}) as Dictionary).get(nation_id, false))


# --- Tax crediting (docs/30 §4.9/§4.10; docs/80-* §4.9 contract) -------------

## Every tax coin flows to the port's effective-alignment nation (decision 19).
## `payer_nation` distinguishes the cap: an NPC payer's credit into a host is
## capped at 2,000g/host/month; the player's own tax is uncapped. Nationless
## payers (`""`) and unaligned hosts (`""`) credit nothing — no host to pay.
## THE NPC crediting entry point (task N, W4): call this on every port-call
## trade with the walked total's tax and the fleet's nation.
static func credit_tax(port_id: String, payer_nation: String, gold: int) -> void:
	var amount := maxi(0, gold)
	if amount <= 0 or payer_nation.is_empty():
		return
	var host := effective_alignment(port_id)
	if host.is_empty():
		return
	var player := _player_nation()
	if player.is_empty() or payer_nation != player:
		var used := maxi(0, int(_npc_tax_month.get(host, 0)))
		amount = mini(amount, NPC_TAX_MONTHLY_CAP - used)
		if amount <= 0:
			return
		_npc_tax_month[host] = used + amount
	_treasuries[host] = maxi(0, int(_treasuries.get(host, 0))) + amount


## A permit sale credits the selling nation's treasury (uncapped, docs/30
## §4.10). Called by `palace_engine.buy_permit`.
static func credit_permit_sale(nation_id: String, gold: int) -> void:
	if nation_id.is_empty() or gold <= 0:
		return
	_treasuries[nation_id] = maxi(0, int(_treasuries.get(nation_id, 0))) + gold


## The nation's current treasury gold (0 when unseeded).
static func treasury(nation_id: String) -> int:
	return maxi(0, int(_treasuries.get(nation_id, 0)))


# --- Telegraphs (decision 24; docs/80-* §4.9 contract) ----------------------

## The investment telegraph rows still inside their 30-day window, oldest
## first: `{nation_id, port_id, band, amount, day}`. The tavern's rumor
## pipeline (task M's `npc_intel.gd` guard read) scopes them to the invested
## port's band and formats `tavern.invest.row`.
static func last_month_investments() -> Array:
	var today := int(GameState.day)
	var out: Array = []
	for row in _telegraphs:
		if not (row is Dictionary):
			continue
		if today - int((row as Dictionary).get("day", 0)) >= TELEGRAPH_WINDOW_DAYS:
			continue
		out.append((row as Dictionary).duplicate())
	return out


## Drops rows whose 30-day window closed and trims the ring buffer.
static func _refresh_telegraphs(today: int) -> void:
	var kept: Array = []
	for row in _telegraphs:
		if not (row is Dictionary):
			continue
		if today - int((row as Dictionary).get("day", 0)) < TELEGRAPH_WINDOW_DAYS:
			kept.append(row)
	_telegraphs = kept
	while _telegraphs.size() > TELEGRAPH_BUFFER_MAX:
		_telegraphs.pop_front()


static func _record_telegraph(nation_id: String, port_id: String,
		amount: int, day: int) -> void:
	_telegraphs.append({
		"nation_id": nation_id,
		"port_id": port_id,
		"band": str(DataLoader.get_port(port_id).get("band", "")),
		"amount": amount,
		"day": day,
	})
	while _telegraphs.size() > TELEGRAPH_BUFFER_MAX:
		_telegraphs.pop_front()


# --- Commendations (§2.6; the palace dialog seam, task F) --------------------

## The oldest unshown conversion to the player's nation:
## `{port_id, nation_id}` or `{}`. The palace surface (task F) reads this at
## the player's nation's palaces and calls [method mark_commendation_shown].
static func pending_commendation() -> Dictionary:
	while not _pending_commendations.is_empty():
		var port_id := str(_pending_commendations[0])
		if _commendations_shown.has(port_id):
			_pending_commendations.pop_front()
			continue
		var nation := _player_nation()
		if nation.is_empty():
			return {}
		return {"port_id": port_id, "nation_id": nation}
	return {}


## Marks the oldest pending commendation shown (one-time per port per save
## within the session; the shown set is transient).
static func mark_commendation_shown() -> void:
	if _pending_commendations.is_empty():
		return
	var port_id := str(_pending_commendations.pop_front())
	_commendations_shown[port_id] = true


# --- Seeding & the month tick (docs/90-* §5.4; docs/80-* §4.9 contract) -----

## The player's nation id (`""` before a run exists).
static func _player_nation() -> String:
	return str(GameState.player.get("nation_id", ""))


## New-game seeding (docs/30 §4.9): every contestable sovereign begins
## `{owner: 6,000}` (allied — 7,500 effective, below dev-1's 10,000g), every
## neutral begins empty; treasuries start at 5,000g per nation; permits,
## fame flags, counters and telegraphs reset. `GameState.new_game` (task V,
## W4) calls this right after its own reset — until then a fresh run's first
## frames see unseeded (empty) allegiance state.
static func seed_new_game() -> void:
	_ledgers = {}
	_allegiances = {}
	_month_invested = {}
	_treasuries = {}
	_npc_tax_month = {}
	_telegraphs = []
	_fame_commended = {}
	_pending_commendations = []
	_commendations_shown = {}
	_threshold_dev = {}
	_permits = {"home": false, "foreign": {}}
	_lane_adjacency = {}
	_seeding = true
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty() or bool((port as Dictionary).get("protected", false)):
			continue
		_ledgers[port_id] = {}
		var owner := str((port as Dictionary).get("nation_id", ""))
		if not owner.is_empty():
			_ledgers[port_id][owner] = SEED_OWNER_LEDGER
	for nation in DataLoader.nations_list:
		var nation_id := str((nation as Dictionary).get("id", ""))
		if not nation_id.is_empty():
			_treasuries[nation_id] = TREASURY_START
	for port_id in _ledgers.keys():
		_resolve_allegiance(str(port_id))
		_threshold_dev[str(port_id)] = dev(str(port_id))
	_seeding = false


## The month tick (docs/90-* §5.4 — called from the sailing_sim seam when the
## day ledger ticks INTO a new month, i.e. `GameState.day % 30 == 1` after the
## increment; docs/30 §4.9 order): reset the monthly player allowance, credit
## each nation's baseline income, resolve the seeded NPC counter-investment,
## refresh the telegraph windows. The NPC-tax cap counters reset with the
## allowance (they are per-month by definition).
static func month_tick() -> void:
	_month_invested = {}
	_npc_tax_month = {}
	for nation_id in _treasuries.keys():
		_treasuries[nation_id] = int(_treasuries[nation_id]) + TREASURY_BASELINE
	var today := maxi(1, int(GameState.day))
	_npc_counter_invest(today)
	_refresh_telegraphs(today)


## The deterministic monthly AI (docs/30 §4.9): each nation makes 0–2
## treasury-bounded picks among its sphere's contestable ports — never
## protected ports, never ports it already holds at dev 3 — weighted toward
## its own lanes (the `data/trade_routes_built.json` spokes of lanes whose
## `data/trade_routes.json` `nations` include it).
static func _npc_counter_invest(today: int) -> void:
	@warning_ignore("integer_division")
	var month_index := (today - 1) / MONTH_DAYS
	var nations: Array = []
	for nation in DataLoader.nations_list:
		var nation_id := str((nation as Dictionary).get("id", ""))
		if not nation_id.is_empty():
			nations.append(nation_id)
	nations.sort()
	for nindex in nations.size():
		var nation_id := str(nations[nindex])
		var treasury_gold := treasury(nation_id)
		if treasury_gold <= 0:
			continue
		var candidates := _ai_candidates(nation_id)
		var lane_ports: Dictionary = _lane_adjacent_ports(nation_id)
		var picks := 0
		for pindex in candidates.size():
			if picks >= AI_PICKS_MAX or treasury_gold <= 0:
				break
			var port_id := str(candidates[pindex])
			var rng := RandomNumberGenerator.new()
			rng.seed = month_index * AI_SEED_MONTH_MULT \
				+ nindex * AI_SEED_NATION_MULT \
				+ pindex * AI_SEED_PORT_MULT
			var weight := AI_WEIGHT_LANE if lane_ports.has(port_id) \
				else AI_WEIGHT_BASE
			if rng.randi_range(1, AI_WEIGHT_SIDES) > weight:
				continue
			var spend := mini(treasury_gold, AI_SPEND_CAP)
			treasury_gold -= spend
			_treasuries[nation_id] = treasury_gold
			add_investment(port_id, nation_id, spend)
			_record_telegraph(nation_id, port_id, spend, today)
			picks += 1


## A nation's AI candidate list: the contestable (never protected) ports whose
## `sphere` includes the nation, excluding ports it already holds at dev 3
## ("away from ports they already hold at dev 3", docs/30 §4.9). Sorted by
## port id — the stable `port_ordinal` of the seed formula.
static func _ai_candidates(nation_id: String) -> Array:
	var out: Array = []
	for port in DataLoader.ports_list:
		var p: Dictionary = port
		var port_id := str(p.get("id", ""))
		if port_id.is_empty() or bool(p.get("protected", false)):
			continue
		var sphere: Array = p.get("sphere", [])
		if not (nation_id in sphere):
			continue
		if str(_allegiances.get(port_id, "")) == nation_id and dev(port_id) >= 3:
			continue
		out.append(port_id)
	out.sort()
	return out


## `{port_id: true}` — the ports on/adjacent to `nation_id`'s lanes: the
## built artifact's spokes joined with the lane `nations` of
## `data/trade_routes.json` (the built lanes carry no nations; the sources
## remain the single truth, docs/10-* §4.14). Cached per nation.
static func _lane_adjacent_ports(nation_id: String) -> Dictionary:
	if _lane_adjacency.has(nation_id):
		return _lane_adjacency[nation_id]
	var lane_nations := _lane_nations()
	var out: Dictionary = {}
	for spoke in DataLoader.route_spokes.values():
		var lane_id := str((spoke as Dictionary).get("lane", ""))
		if not (nation_id in (lane_nations.get(lane_id, []) as Array)):
			continue
		var port_id := str((spoke as Dictionary).get("port", ""))
		if not port_id.is_empty():
			out[port_id] = true
	_lane_adjacency[nation_id] = out
	return out


## `{lane_id: [nation_id, …]}` read straight from the route sources (a pure
## data read; the loader does not index the source file's nations).
static func _lane_nations() -> Dictionary:
	var out: Dictionary = {}
	var text := FileAccess.get_file_as_string("res://data/trade_routes.json")
	if text.is_empty():
		return out
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return out
	for lane in (parsed as Dictionary).get("lanes", []):
		if not (lane is Dictionary):
			continue
		var ids: Array = []
		for nation_id in (lane as Dictionary).get("nations", []):
			ids.append(str(nation_id))
		out[str((lane as Dictionary).get("id", ""))] = ids
	return out


# --- W4/V persistence seam (correction 8 shape; docs/90-* §8.2) --------------
#
# V owns `save_system.gd` / `game_state.gd` and wires:
#   save:   payload[<key>] = Allegiance.dump_state()[<key>] for the five keys
#           below (all contestable ports serialize, docs/90-* §8.2);
#   load:   Allegiance.restore_state(payload) right after GameState's blocks
#           are applied (it re-derives the transient trackers, so a save/load
#           mid-month replays the month identically);
#   new_game: Allegiance.seed_new_game() right after the GameState reset.
# Until that lands, this module's statics are the only home of the state and
# `restore_state` doubles as the load-path default (missing keys → seeded).

## The five save v7 keys under their docs/90-* §8.2 names, plus nothing else:
## `port_allegiance` (`{port_id: {ledger, allegiance}}`, correction 8 shape —
## dev is derived and never serialized), `month_invested`,
## `nation_treasuries`, `fame_commended`, `permits`.
static func dump_state() -> Dictionary:
	var port_allegiance: Dictionary = {}
	for port_id in _ledgers.keys():
		port_allegiance[str(port_id)] = {
			"ledger": (_ledgers[port_id] as Dictionary).duplicate(true),
			"allegiance": str(_allegiances.get(port_id, "")),
		}
	return {
		"port_allegiance": port_allegiance,
		"month_invested": _month_invested.duplicate(true),
		"nation_treasuries": _treasuries.duplicate(true),
		"fame_commended": _fame_commended.duplicate(true),
		"permits": _permits.duplicate(true),
	}


## Restores the five keys (missing keys keep their seeded defaults), then
## re-derives the transient trackers: the threshold-fame baseline per port and
## the unshown commendation queue (every honored flip re-surfaces once per
## session — the dialog is informational and one-time per save in spirit).
static func restore_state(data: Dictionary) -> void:
	if not (data is Dictionary):
		seed_new_game()
		return
	seed_new_game()
	_restoring = true
	var payload: Dictionary = data
	var port_allegiance: Dictionary = payload.get("port_allegiance", {})
	if port_allegiance is Dictionary:
		for port_id in port_allegiance.keys():
			var pid := str(port_id)
			var entry: Dictionary = port_allegiance[pid]
			if not (entry is Dictionary) or not _ledgers.has(pid):
				continue
			var ledger: Dictionary = entry.get("ledger", {})
			var clean: Dictionary = {}
			if ledger is Dictionary:
				for nation_id in ledger.keys():
					clean[str(nation_id)] = maxi(0, int(ledger[nation_id]))
			_ledgers[pid] = clean
			_allegiances[pid] = str(entry.get("allegiance", ""))
	var month_invested: Dictionary = payload.get("month_invested", {})
	if month_invested is Dictionary:
		for port_id in month_invested.keys():
			_month_invested[str(port_id)] = maxi(0, int(month_invested[port_id]))
	var treasuries: Dictionary = payload.get("nation_treasuries", {})
	if treasuries is Dictionary:
		for nation_id in treasuries.keys():
			_treasuries[str(nation_id)] = maxi(0, int(treasuries[nation_id]))
	var fame_commended: Dictionary = payload.get("fame_commended", {})
	if fame_commended is Dictionary:
		for port_id in fame_commended.keys():
			_fame_commended[str(port_id)] = true
			if not _pending_commendations.has(str(port_id)):
				_pending_commendations.append(str(port_id))
	var permits: Dictionary = payload.get("permits", {})
	if permits is Dictionary:
		var foreign = permits.get("foreign", {})
		_permits = {
			"home": bool(permits.get("home", false)),
			"foreign": (foreign as Dictionary).duplicate(true)
				if foreign is Dictionary else {},
		}
	# Re-derive the transient trackers from the restored ledgers.
	_threshold_dev = {}
	for port_id in _ledgers.keys():
		_threshold_dev[str(port_id)] = dev(str(port_id))
	_restoring = false
