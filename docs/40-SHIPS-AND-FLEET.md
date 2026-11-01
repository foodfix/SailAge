# 40 — Ships & Fleet

## 1. Purpose & Phase

Specifies ship instances and their stats, purchase/repair/refit/sale at the
shipyard, fleet composition and flagship rules, and cargo-hold maths (goods
vs provisions vs water vs armament sharing capacity). Gates Phase 1; combat
use of `armament_slots`/`cannons` is Phase 2. **Phase 7** grows the roster
8 → 16 with a `role` field and per-port stock lists under development-gated
tiers (§4.3.1).

## 2. Artifacts

| Path | Contents |
|---|---|
| `scripts/fleet/fleet.gd` | fleet container + cargo maths (RefCounted) |
| `scripts/port/shipyard_engine.gd` | shipyard transactions |
| `scenes/port/shipyard_screen.tscn` | shipyard UI |
| GameState key | `fleet` — array of ship instances (§4.1) |

## 3. Dependencies

`10-DATA-SCHEMA.md` (ShipType schema + locked stats), `20-*` (speed use,
consumption pooling), `30-*` (shipyard screen wiring), `90-*`.

## 4. Systems / Mechanics

### 4.1 Ship instance schema (runtime + save shape)

```json
{
  "ship_type_id": "caravel",
  "durability": 90,
  "crew": 15,
  "provisions": 60,
  "water": 60,
  "cannons": 0,
  "cargo": {"wine": 40, "salt": 10},
  "equipment": {"figurehead": "", "sail": ""}
}
```

| Field | Type | Rule |
|---|---|---|
| `ship_type_id` | id | → ShipType (static stats from data) |
| `durability` | int `0..effective_max` | current hull HP; 0 = sunk |
| `crew` | int `0..ShipType.crew_max` | sailors aboard (Phase 1: flagship only, see §4.4) |
| `provisions` | int ≥ 0 | units aboard |
| `water` | int ≥ 0 | units aboard |
| `cannons` | int `0..ShipType.armament_slots` | Phase 2 effect; locked at 0 in P1 |
| `cargo` | object id → int ≥ 0 | trade goods only; provisions/water are separate fields |
| `equipment` | object | Phase-2 ship slots: `{"figurehead": id-or-"", "sail": id-or-""}` (`60-*` §4.11.12). Absent in a Phase-1 save; the migration and every accessor default it to empty slots. |

**Effective max durability (Phase 2).** `effective_max = ShipType.durability +
figurehead durability modifier` (`60-*` §4.11.12). Ram damage and repairs use
this value; `durability` is clamped to it.

**Normative clarifications for the effective max.**

- The sell price of §4.3 uses `effective_max_durability` as its denominator, so
  a figurehead can never raise a sale above `floor(base_price × 0.5)`, and with
  no figurehead fitted every Phase-1 price is byte-identical.
- Equipping a figurehead does **not** heal current durability; only the cap
  moves. Removing a figurehead clamps the current value down to the new cap
  (a loss, never a gain), which is the only place the cap can shrink.

### 4.2 Cargo-hold maths

```
used_capacity(ship) =
      Σ cargo values
    + provisions
    + water
    + cannons × CANNON_CARGO_UNITS        # CANNON_CARGO_UNITS = 5
free_capacity(ship) = ShipType.capacity − used_capacity(ship)
```

Phase-1 fleet pooling (single trade UI):

- `fleet_capacity = Σ ShipType.capacity` over the fleet;
  `fleet_free = Σ free_capacity`.
- Goods/provisions/water are *stored* distributed: purchases fill flagship
  first, then ships in order; consumption drains flagship first, then in
  order (`fleet.gd` normalizes after every mutation so invariant holds:
  non-flagship non-empty iff the previous ship is full).
- Market/capacity checks use `fleet_free` (`30-*` §4.4).

**Distribution invariant (locked wording).** For every index `i`,
`fleet[i]` is non-empty ⟹ `fleet[0..i-1]` are all full. `Fleet.normalize_all()`
is the single enforcement point: it truncates any over-capacity hold (trade
goods first, in id order, then provisions, then water — supplies are survival
resources) and then moves any stranded hold units flagship-first. It returns
`true` iff it changed something; `SaveSystem` calls it after deserialization
(§6) and logs every repair. Integral JSON floats (`45.0`) are coerced to int
silently (parse artifact, not a repair); fractional/negative/null values are
repairs and are logged.

### 4.3 Shipyard transactions

The four actions run at every shipyard port. **Phase-7 amendment:** the
Phase-1 rule "all 8 ShipTypes sold everywhere" is retired — hulls (and
equipment, `60-*` §4.11.13) come from the port's per-port stock list
through the universal tier gate (§4.3.1), and Buy requires the item to be
purchasable there. Every rule in the table below is otherwise unchanged:

| Action | Rule |
|---|---|
| Buy ship | cost `ShipType.base_price`; new instance at `durability = max`, `crew = 0`, `provisions/water = 0`, `cannons = 0`, empty cargo. Requires `gold ≥ price` and fleet size < `FLEET_MAX` (§4.4). |
| Repair ship | cost per durability point = `ceil(ShipType.base_price / 400)`; partial repair allowed (player picks points, capped by gold and damage). |
| Refit (armament) | cannon price 100g each, occupies 5 cargo units, ≤ `armament_slots`; sell-back 50g each. **Phase 2 enables the row**; see `60-*` §4.11.4 for the battle effect. |
| Buy equipment | `data/equipment.json` item at its `price`; occupies its slot (`weapon`/`armor` player, `figurehead`/`sail` ship); replacing sells the old item back at `floor(price × 0.5)` in the same action (`60-*` §4.11.12). Phase 2; **Phase 7:** the buy list becomes the port's `facilities.equipment_stock` under the same §4.3.1 tier gate (`60-*` §4.11.13) — rare items never render in it. |
| Sell ship | price `floor(base_price × 0.5 × durability / effective_max_durability)`; the ship's **pooled hold must be empty** (§4.2: goods + provisions + water — checking only the `cargo` object would let a sale silently destroy pooled supplies, which §6 forbids) and the ship must not be the flagship; crew aboard is lost (warning confirm dialog `shipyard.sell.confirm`). Equipment leaves with the ship. |

Repair pricing examples: latin 3g/pt, caravel 20g/pt, nao 55g/pt, galleon
150g/pt.

#### 4.3.1 Per-port stock, roles & tier gating (Phase 7)

**Roster 16.** The locked ship list (`10-*` §7.3) grows 8 → 16 — **the
existing 8 are unchanged** (every locked stat stays byte-identical; they
gain only `role` + `tier`). New ids with first-pass stats (S may tune
within ±20% at authoring, then the exact set is locked; zh/en names
first-pass, S finalizes; speeds are the Phase-6 `{16, 20, 24}` tiles/day
values — `10-*` §7.3):

| id | zh | en | class | role (first-pass) | tier | dur | cap | spd | crew | slots | price |
|---|---|---|---|---|---|---|---|---|---|---|---|
| latin | 拉丁帆船 | Latin | sail | *(S)* | 1 | 40 | 30 | 16 | 8/20 | 2 | 1,200g |
| sloop | 单桅纵帆船 | Sloop | sail | *(S)* | 1 | 60 | 60 | 20 | 10/30 | 4 | 3,000g |
| caravel | 卡拉维尔帆船 | Caravel | sail | *(S)* | 2 | 90 | 120 | 20 | 15/45 | 6 | 8,000g |
| galley | 桨帆船 | Galley | oar | **war** (re-role) | 2 | 70 | 50 | 24 | 40/120 | 4 | 10,000g |
| brigantine | 双桅帆船 | Brigantine | sail | *(S)* | 2 | 110 | 150 | 24 | 20/60 | 10 | 15,000g |
| nao | 瑙船 | Nao | sail | *(S)* | 3 | 140 | 300 | 16 | 25/80 | 10 | 22,000g |
| carrack | 卡拉克帆船 | Carrack | sail | *(S)* | 3 | 180 | 450 | 16 | 30/100 | 16 | 40,000g |
| galleon | 盖伦帆船 | Galleon | hybrid | *(S)* | 3 | 240 | 400 | 20 | 40/150 | 24 | 60,000g |
| galiot | 小型桨帆船 | Galiot | oar | war (cheap) | 1 | 35 | 25 | 16 | 15/40 | 2 | 2,400g |
| galleass | 加莱赛战船 | Galleass | oar | war (heavy) | 3 | 110 | 70 | 16 | 60/160 | 6 | 22,000g |
| fluyt | 弗鲁特商船 | Fluyt | sail | trade (bulk) | 2 | 70 | 180 | 16 | 12/30 | 2 | 14,000g |
| junk | 福船 | Junk | sail | trade (regional) | 2 | 90 | 140 | 18 | 20/60 | 3 | 16,000g |
| dhow | 单桅三角帆船 | Dhow | sail | trade (regional) | 2 | 60 | 90 | 18 | 10/30 | 2 | 9,000g |
| pinnace | 平底船 | Pinnace | sail | trade (coastal) | 1 | 40 | 45 | 16 | 8/20 | 2 | 2,200g |
| caravela_redonda | 卡拉维拉方形帆船 | Round Caravel | sail | trade (mid) | 2 | 70 | 100 | 20 | 15/40 | 3 | 11,000g |
| xebec | 小型三桅船 | Xebec | hybrid | war (fast raider) | 2 | 60 | 60 | 24 | 25/80 | 4 | 15,000g |

Role-column note: the new-8 values are the first-pass pins (the
parentheticals are flavor — the stored value is the enum member); existing
8 marked *(S)* — S authors them within the role meanings below, except the
galley whose `war` is pinned. The xebec is the roster's **dated exception
(~1690s)** — S writes the one-line note in `LICENSE-NOTES.md`.

**`role` meaning** (enum `war | trade | coastal`, locked by A in `10-*`
§7.3; the semantics live here):

- `war` — combat-first hull: durability and armament dominate the hold.
- `trade` — hold-first hull for lane cargo runs.
- `coastal` — small short-range craft (starter- and coaster-class hulls).

Every shipyard row carries the role label 战舰/商船/沿岸
(`shipyard.role.*`, `80-*` §4.7.12).

**Galley re-role (decision 2 — realism over convenience).** The galley is
re-rolled as a **warship** by availability and framing, never buffed into
a trader: `role: "war"`, **price unchanged (10,000g)**, and its stock-list
entries restricted to **Mediterranean/North-African ports** (P authors the
lists). Its 2-day endurance stays an **honest warship trait** — a
raider's hull, not a lane runner.

**Per-port stock.** `facilities.shipyard: 1` (int) becomes
`facilities.shipyard: [ship_type_ids]` (**≥ 2, ≤ 8**) at all **104**
shipyard ports (`10-*` §4.4; P is the single writer). Regional flavor:
Mediterranean → galley/galiot/galleass/xebec; China coast → junk;
Arabia/India → dhow; Holland → fluyt; capitals stock the widest set.
Saved ships keep storing `ship_type_id` as today — no save impact.

**Tier gating (decision 23).** Every type gains `tier: 1|2|3` —
first-pass assignment: tier 1 {latin, sloop, pinnace, galiot}; tier 2
{caravel, brigantine, galley, dhow, caravela_redonda, fluyt, junk, xebec};
tier 3 {nao, carrack, galleon, galleass} (S finalizes, then locked;
validator: ≥ 2 per tier; ≥ 4 dev-3 sovereign ports stock tier-3 hulls).
The universal filter at **both port kinds** (ships and equipment):

```
purchasable(port, item) = in_stock ∧ tier ≤ effective_dev(port)
```

`effective_dev` is the derived development level of `30-*` §4.9 (authored
floor vs ledger thresholds). An above-dev row grays 需发展度 — it never
disappears (`80-*` §4.7.12). At start only the 6 dev-3 capitals sell
tier-3 hulls; a major contestable port grown to dev 3 (the 25,000g ledger
threshold) unlocks them too.

**Three row states (correction 11).** Shipyard rows render in exactly
three states — **available / tier-gray 需发展度 / allegiance-gray
同盟专营** (the render contract is `80-*` §4.7.12). Neutral shipyards
stock their regional hulls **only under allegiance + dev ≥ 2**; an
**unallied neutral shows the full list allegiance-grayed** — no
empty-catalog crash state, and the lock note explains the flip path
(invest to align the port, grow dev to 2).

**Shared-hold physics kept (decision 2).** `used_capacity` still sums
cargo + provisions + water (+ cannons × 5, §4.2) on all 16 hulls; no tank
fields anywhere.

### 4.4 Fleet composition & flagship rules

- `FLEET_MAX = 5` ships (locked; battle-grid width reference for `60-*`).
- **Flagship** = `fleet[0]`; moving the flagship row to another slot is a
  free action at port (fleet panel S15 `80-*` §4.5.1, drag or "Promote" button
  per `80-*`). The rule itself lives in `ShipyardEngine.can_promote/promote`;
  `Fleet.can_promote/promote` delegate to it (port = `current_port` non-empty).
- Fleet speed = `min(effective stats)`: the flagship's speed formula result
  (`20-*` §4.4) computed with the **slowest `ShipType.speed` in the fleet**
  as `base_speed`. (§locked simplification: flagship supplies crew/sim
  fields; cargo ships tow along.)
- **Speed units.** `ShipType.speed` is **tiles/day on 5 nm tiles**
  (`20-*` §4.1, Phase-6 grid): the Phase-6 base speeds are `{16, 20, 24}`
  tiles/day = 80–120 nm/day (`10-*` §7.3; latin 16, sloop 20, caravel 20,
  galley 24, brigantine 24, nao 16, carrack 16, galleon 20). The
  fleet-speed rule (slowest hull) is unchanged. The Phase-6 sailing-sim
  factors — wind strength, heading-relative direction factor, current
  factor and sail trim (`20-*` §4.4) — act on the composed fleet speed
  through the same pipeline; the composition rule itself (flagship
  supplies crew/sim fields, slowest hull as `base_speed`) is untouched.
- Phase-1 crew simplification (from `20-*` §4.6): all crew lives on the
  flagship; non-flagship hulls require no crew. Consumption pool = flagship
  crew only.
- **Sinking at sea (non-flagship):** immediate loss of the hull and its
  cargo; cargo is lost entirely (locked: no salvage in Phase 1); event dialog
  `world.ship_lost`.
- **Flagship sinking with escorts present:** crew/provisions/water/cargo
  relocate in fleet order up to capacity (overflow lost), the next ship
  becomes flagship, event dialog `world.flagship_lost`. With no escort →
  `20-*` §4.9 game over `"sunk"`.

### 4.5 Durability damage sources (Phase 1)

Only storms (`20-*` §4.7) reduce durability at sea. Repair is the only way to
restore it. Reef `^` tiles block movement without damage in Phase 1 (damage
rule OUT OF SCOPE (phase 2)).

## 5. Data Examples

Starter caravel loaded at Lisbon for the Seville hop (Lisbon 38.72/−9.14 →
Seville 37.39/−6.00: 3.14° of longitude ≈ 38 tiles at 12 tiles/degree, so
≈ 2 days at speed 16–20 (38 tiles ÷ 16–20 tiles/day); 15 crew →
`ceil(15/5) = 3` provisions + 3 water per day, `20-*` §4.5). Loadout:
15 days of supplies + 30 cargo (the per-day consumption arithmetic is
distance-independent, so the loadout numbers are unchanged by the
Phase-6 rescale):

```json
{
  "ship_type_id": "caravel",
  "durability": 90,
  "crew": 15,
  "provisions": 45,
  "water": 45,
  "cannons": 0,
  "cargo": {"wine": 30},
  "used_capacity": 120,
  "free_capacity": 0,
  "valid": true,
  "note": "45+45+30=120 = ShipType.capacity"
}
```

The same hull under a crew-light storm dash (crew 8 < crew_min 15 → speed
penalty per `20-*` §4.6; 30 days of supplies, no cargo):

```json
{
  "ship_type_id": "caravel",
  "durability": 90,
  "crew": 8,
  "provisions": 60,
  "water": 60,
  "cannons": 0,
  "cargo": {},
  "used_capacity": 120,
  "free_capacity": 0,
  "valid": true,
  "note": "8 crew needs ceil(8/5)=2 provisions + 2 water per day; 60/2 = 30 days of each nominally, carried as 60+60"
}
```

Shipyard worked numbers (from `10-*` §7.3):

```json
{
  "caravel": {"buy": 8000, "repair_per_point": 20, "sell_at_full": 4000, "sell_at_half_dur": 2000},
  "galleon": {"buy": 60000, "repair_per_point": 150, "sell_at_full": 30000},
  "note": "repair = ceil(base_price/400); sell = floor(base_price × 0.5 × dur/max)"
}
```

## 6. Edge Cases & Fail States

- **Buying a 6th ship** → Buy buttons disabled; reason `fleet.full`.
- **Buying while flagship undercrewed** → allowed; speed penalty is the
  natural consequence (`20-*` §4.6).
- **Repair 0 points / confirm with no gold** → buttons disabled by validation.
- **Selling flagship** → Sell button absent on the flagship row, always.
- **Selling last ship** (`fleet.size == 1`) → disabled; ships can only be
  lost by sinking, preventing a deliberate-shipless state that confusingly
  triggers harbor relief.
- **Normalization overflow after sinking** — overflow cargo is discarded and
  reported in the loss dialog (§4.4), never silently.
- **Capacity invariant violation found at load** → `SaveSystem` logs and
  truncates cargo to fit (data corruption guard; also logged for bug report).
  `Fleet.normalize_all()` does the work (§4.2) and reports whether anything
  changed.
- **Jettison (fleet panel S15, `80-*` §4.5.1)** → drops one whole stack (a
  trade good, or the provisions/water stack) from one ship after a confirm
  dialog, freeing `fleet_free` immediately; it is the documented way to make
  room for supplies (`20-*` §4.10) and is port-only, like promotion.
- **Unknown `ship_type_id` in a hand-edited save** → the capacity guard is
  skipped with a logged warning (capacity is unknown, and guessing 0 would
  destroy the hold blind); every other invariant is still enforced.
- **Shipyard at an unallied neutral port** → every hull row renders
  allegiance-grayed (§4.3.1, `80-*` §4.7.12); the catalog is never empty
  and never crashes — the stock list exists, it is only buy-gated.
- **Tier-gray buy attempt** (row above the port's `effective_dev`) → the
  Buy button is disabled with the 需发展度 note; no transaction path
  bypasses the §4.3.1 filter.

## 7. Acceptance Criteria

- [ ] `used_capacity`/`free_capacity` formulas (§4.2) unit-tested incl. the
      cannon term (`cannons × 5`).
- [ ] Repair per-point prices match `ceil(base_price/400)` for all 16
      types.
- [ ] Sell price formula exactly `floor(base × 0.5 × dur/max)`.
- [ ] Flagship promotion is free, port-only, and preserves instance order.
- [ ] Fleet speed uses the slowest hull (`20-*` §4.4 integration test).
- [ ] §5's valid `nao` loadout passes normalization; the invalid examples are
      rejected by invariants and tests.
- [ ] Cannon UI disabled with the Phase-2 label in P1; refit logic itself
      unit-tested (ready for Phase 2).

**Phase-7 additions (trade empires).**

- [ ] All 16 ShipTypes validate (exact set, i18n parity, ≥ 2 per tier);
      the existing 8 keep every locked stat byte-identically.
- [ ] Shipyard rows come from the port's stock list;
      `purchasable = in_stock ∧ tier ≤ effective_dev` holds at dev-1/2/3
      ports, tier-3 hulls sell at exactly the dev-3 ports (the 6 capitals
      at start), and ≥ 4 dev-3 sovereign ports stock tier-3 hulls.
- [ ] The three row states (§4.3.1) are each reachable in suites,
      including the unallied-neutral allegiance-gray catalog (no empty
      state) and the tier-gray 需发展度 note.
- [ ] The galley sells only at Mediterranean/North-African ports and its
      price is still 10,000g.
- [ ] Every stock list includes ≥ 2 hulls at each of the 104 shipyard
      ports and something buyable at every reachable dev level.
