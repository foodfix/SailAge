/**
 * The M3 fixture — a hand-authored, typed snapshot of the §8.1 save payload
 * shape covering the demo loop: a docked player at Lisbon with gold, cargo,
 * a two-ship fleet and an officer.
 *
 * Every displayed number comes from this fixture (or from data/*.json via
 * the content registry), never from a literal inside TSX. The `views` block
 * is the presentation projection the pure renderer needs (prices, gate
 * reasons, open/closed status) — M2 must supply the same projections.
 */
import { content } from "../i18n";
import type { GameSnapshot, NpcMarkerState, ScreenViews, SailingView } from "./types";

const LISBON = "lisbon";
const PORTUGAL = "portugal";
const SPAIN = "spain";

export const fixtureState: GameSnapshot = {
  save_version: 1,
  saved_at: 1793119712,
  phase: 9,
  locale: "en",
  day: 12,
  gold: 7830,
  player: {
    nation_id: PORTUGAL,
    background_id: "background_deckhand",
    attributes: { constitution: 16, intellect: 17, charisma: 10, courage: 10, luck: 10 },
    skills: {
      seamanship: 8,
      navigation: 5,
      swordplay: 0,
      gunnery: 0,
      appraisal: 0,
      negotiation: 0,
      cartography: 0,
      rumour: 0,
    },
    skill_counters: {
      seamanship: 12,
      navigation: 5,
      swordplay: 0,
      gunnery: 0,
      appraisal: 0,
      negotiation: 0,
      cartography: 0,
      rumour: 0,
    },
    alloc_pending: 4,
    xp: 137,
    level: 2,
    officers: ["off_mateus_alvares"],
    reputation: { portugal: 20, spain: 0, england: 0, holland: 0, ottoman: 0, italy: 0 },
    profit_by_nation: { england: 1100 },
    profit_rep_awarded: { england: 1 },
    equipment: { weapon: "eq_cutlass", armor: "" },
  },
  fleet: [
    {
      ship_type_id: "caravel",
      durability: 82,
      crew: 15,
      provisions: 40,
      water: 38,
      cannons: 4,
      cargo: { wine: 30, salt: 10 },
      equipment: { figurehead: "", sail: "" },
    },
    {
      ship_type_id: "latin",
      durability: 40,
      crew: 0,
      provisions: 0,
      water: 0,
      cannons: 0,
      cargo: {},
      equipment: { figurehead: "", sail: "" },
    },
  ],
  morale: 70,
  world: {
    position: { x: 2050, y: 615 },
    map_id: "world",
    weather: "calm",
    sail_trim: "normal",
    heading: "E",
    wind_dir: "E",
  },
  current_port: LISBON,
  known_ports: [LISBON, "madeira", "cadiz", "seville", "london"],
  explored_tiles: "",
  port_investments: { [LISBON]: 500 },
  quests: [],
  discoveries_found: ["disc_atlas_cedars"],
  npc_fleets: [],
  officer_states: {
    off_mateus_alvares: {
      loyalty: 60,
      sea_days: 12,
      post_id: "",
      ship_id: "",
      talk_cd_day: 0,
      gift_cd_day: 0,
      defeats: 0,
    },
  },
  captain_states: {},
  proximity_cooldowns: {},
  market_stocks: { [LISBON]: { wine: 120, salt: 90 } },
  wrecks: [],
  npc_preset: "normal",
  market_events: [],
  control_prefs: { input_mode: "step", current_mode: "modifier" },
  permits: { home: false, foreign: {} },
  port_allegiance: { [LISBON]: PORTUGAL },
  month_invested: { [LISBON]: 500 },
  nation_treasuries: { [PORTUGAL]: 42000 },
  fame_commended: {},
  fame: 120,
  titles: { portugal: "none", spain: "none", england: "none", holland: "none", ottoman: "none", italy: "none" },
  bounties: {},
  active_quests: [],
  completed_royal_missions: { [PORTUGAL]: 0 },
  discoveries_reported: [],
  discovery_hints: {},
  battles_won: 0,
  retired: false,
  retired_at: 0,
  pending_encounter: null,
  npc_port_log: [],
  levelup: null,
};

const captainName = (id: string) => content.officerName(id);

export const fixtureViews: ScreenViews = {
  port: {
    facilities: [
      { id: "market", phase: 1, enabled: true, status: { kind: "open", open: "08:00", close: "18:00" } },
      { id: "shipyard", phase: 1, enabled: true, status: { kind: "open", open: "08:00", close: "18:00" } },
      { id: "tavern", phase: 1, enabled: true, status: { kind: "open", open: "10:00", close: "24:00" } },
      { id: "inn", phase: 1, enabled: true, status: { kind: "always" } },
      { id: "guild", phase: 3, enabled: true, status: { kind: "open", open: "08:00", close: "18:00" } },
      { id: "palace", phase: 3, enabled: true, status: { kind: "open", open: "09:00", close: "17:00" } },
    ],
  },
  market: {
    portId: LISBON,
    taxBadge: "in_sphere",
    taxRatePct: 5,
    buyTariffGold: 14,
    sellTariffGold: 6,
    rows: [
      { goodId: "wheat", stock: 180, trend: "up", marginal: 9, unitPrice: 9, owned: 0, specialty: false },
      { goodId: "olive_oil", stock: 96, trend: "flat", marginal: 23, unitPrice: 23, owned: 0, specialty: false },
      { goodId: "wine", stock: 120, trend: "up", marginal: 27, unitPrice: 27, owned: 30, specialty: true },
      { goodId: "salt", stock: 90, trend: "down", marginal: 11, unitPrice: 11, owned: 10, specialty: true },
      { goodId: "wool", stock: 74, trend: "flat", marginal: 19, unitPrice: 19, owned: 0, specialty: false },
      { goodId: "cotton_cloth", stock: 58, trend: "down", marginal: 46, unitPrice: 46, owned: 0, specialty: false },
      { goodId: "silk", stock: 22, trend: "down", marginal: 123, unitPrice: 123, owned: 0, specialty: false },
      { goodId: "spices", stock: 18, trend: "down", marginal: 154, unitPrice: 154, owned: 0, specialty: false },
      { goodId: "sugar", stock: 66, trend: "up", marginal: 41, unitPrice: 41, owned: 0, specialty: false },
      { goodId: "dried_fish", stock: 140, trend: "flat", marginal: 10, unitPrice: 10, owned: 0, specialty: false },
    ],
    specialtyGoodIds: ["wine", "salt"],
    investedGold: 500,
    investedPct: 5,
    investCapPct: 20,
    investAmount: 1000,
    investGate: { kind: "allowance" },
    captains: [
      { id: "cap_market_1", name: captainName("off_leg_duarte_silveira"), roleKey: "captain.role.trader", tier: 2, lastSeenDay: 11 },
      { id: "cap_market_2", name: captainName("off_leg_blasco_miranda"), roleKey: "captain.role.coaster", tier: 1, lastSeenDay: 12 },
    ],
    freeIntelPortId: "madeira",
  },
  provisions: {
    portId: LISBON,
    clock: "14:20",
    days: 18,
    daysBarMax: 10,
    daysGoodMin: 10,
    daysWarnMin: 3,
    provisions: { qty: 40, price: 3 },
    water: { qty: 38, price: 2 },
    holdUsed: 40,
    holdCapacity: 120,
    holdFree: 80,
    cargo: [
      { goodId: "wine", qty: 30 },
      { goodId: "salt", qty: 10 },
    ],
    fillBlocked: false,
  },
  shipyard: {
    portId: LISBON,
    catalog: [
      { shipTypeId: "latin", price: 1200, canBuy: true },
      { shipTypeId: "sloop", price: 3000, canBuy: true },
      { shipTypeId: "pinnace", price: 4800, canBuy: true },
      { shipTypeId: "caravel", price: 8000, canBuy: false, requirementKey: "shipyard.no_gold" },
      { shipTypeId: "nao", price: 22000, canBuy: false, requirementKey: "shipyard.tier.need_dev" },
    ],
    fleet: [
      {
        index: 0,
        shipTypeId: "caravel",
        durability: 82,
        maxDurability: 90,
        crew: 15,
        crewMax: 45,
        cannons: 4,
        slots: 6,
        cargoUsed: 40,
        cargoCapacity: 120,
        cargoFree: 80,
        canSell: false,
        sellPrice: 3644,
        canRepair: true,
        repairCostPerPoint: 20,
      },
      {
        index: 1,
        shipTypeId: "latin",
        durability: 40,
        maxDurability: 40,
        crew: 0,
        crewMax: 20,
        cannons: 0,
        slots: 2,
        cargoUsed: 0,
        cargoCapacity: 30,
        cargoFree: 30,
        canSell: true,
        sellPrice: 600,
        canRepair: false,
        repairCostPerPoint: 3,
      },
    ],
    equipment: { weapon: "eq_cutlass", armor: "" },
  },
  inn: {
    portId: LISBON,
    rest: { days: 3, price: 60, canRest: true },
    moraleTier: "good",
    moraleMax: 100,
    oddJob: { eligible: false, reasonKey: "inn.odd_job.not_broke" },
    captains: [
      { id: "cap_inn_1", name: captainName("off_leg_tome_pires"), roleKey: "captain.role.courier", tier: 2, lastSeenDay: 10 },
      { id: "cap_inn_2", name: captainName("off_leg_goncalo_marinheiro"), roleKey: "captain.role.patrol", tier: 2, lastSeenDay: 12 },
    ],
  },
  guild: {
    portId: LISBON,
    offersRefreshDay: 13,
    offers: [
      {
        id: "qt_delivery_wheat",
        type: "delivery",
        lineKey: "quest.line.delivery",
        lineValues: {
          quantity: 20,
          good: content.goodName("wheat"),
          port: content.portName("lisbon"),
        },
        daysLeft: 22,
        rewardGold: 320,
        rep: 5,
        canAccept: true,
      },
      {
        id: "qt_delivery_timber",
        type: "delivery",
        lineKey: "quest.line.delivery",
        lineValues: {
          quantity: 20,
          good: content.goodName("timber"),
          port: content.portName("tunis"),
        },
        daysLeft: 18,
        rewardGold: 600,
        rep: 5,
        canAccept: false,
        reasonKey: "quest.no_hold",
      },
    ],
    reports: [{ discoveryId: "disc_atlas_cedars", rewardGold: 2000, fame: 150 }],
  },
  palace: {
    portId: LISBON,
    nationId: PORTUGAL,
    rank: "none",
    nextRank: { rank: "knight", fame: 200, missions: 1 },
    ceremonyAvailable: false,
    mission: {
      objectiveKey: "quest.line.delivery",
      objectiveValues: {
        quantity: 20,
        good: content.goodName("wheat"),
        port: content.portName("cadiz"),
      },
      daysLeft: 14,
      canAccept: true,
    },
    repairAvailable: true,
    permits: {
      home: { price: 5000, owned: false, canBuy: true },
      foreign: { price: 20000, owned: false, canBuy: false, noteKey: "palace.permit.title_locked", nationId: SPAIN },
    },
    tournament: {
      hostPortId: LISBON,
      firstDay: 10,
      lastDay: 20,
      prizeGold: 3000,
      fame: 50,
      entered: false,
      canEnter: true,
    },
    board: [
      {
        captainId: "cap_board_1",
        name: captainName("off_leg_john_blackwood"),
        tier: 2,
        roleKey: "captain.role.pirate",
        rewardGold: 1800,
        portId: "cadiz",
      },
    ],
    inform: [
      {
        captainId: "cap_board_1",
        text: { zh: "黑胡子约翰在加的斯外海出没。", en: "Blackwood was last seen off Cadiz." },
        cost: 500,
        canInform: true,
      },
    ],
  },
  tavern: {
    portId: LISBON,
    moraleTier: "good",
    moraleMax: 100,
    captains: [
      { id: "cap_tavern_1", name: captainName("off_leg_john_blackwood"), roleKey: "captain.role.pirate", tier: 2, lastSeenDay: 11 },
      { id: "cap_tavern_2", name: captainName("off_leg_arend_grootveld"), roleKey: "captain.role.trader", tier: 1, lastSeenDay: 12 },
    ],
    crew: {
      count: 15,
      max: 45,
      min: 8,
      morale: 70,
      perHead: 12,
      hireCost: 120,
      canHire: true,
      fillAvailable: true,
    },
    recruitable: [
      {
        officerId: "off_leg_duarte_silveira",
        roleKey: "tavern.role.navigator",
        wage: 55,
        signingFee: 550,
        skills: { leadership: 17, seamanship: 22, combat: 6, navigation: 58 },
        canRecruit: true,
      },
      {
        officerId: "off_leg_vicente_gouveia",
        roleKey: "tavern.role.boatswain",
        wage: 58,
        signingFee: 580,
        skills: { leadership: 19, seamanship: 60, combat: 14, navigation: 20 },
        canRecruit: false,
      },
    ],
    roster: [
      {
        officerId: "off_mateus_alvares",
        roleKey: "tavern.role.navigator",
        wage: 30,
        signingFee: 300,
        skills: { leadership: 12, seamanship: 18, combat: 5, navigation: 30 },
        canRecruit: true,
      },
    ],
    rumors: {
      price: 20,
      rows: [
        {
          id: "rumor_1",
          text: { zh: "加的斯的小麦歉收，价格看涨。", en: "Cadiz's wheat harvest failed; prices are climbing." },
          known: false,
        },
        {
          id: "rumor_2",
          text: { zh: "一支西班牙船队正驶向里斯本。", en: "A Spanish convoy is bound for Lisbon." },
          known: false,
        },
        {
          id: "rumor_3",
          text: { zh: "马德拉外海有一处新发现。", en: "A discovery lies off Madeira." },
          known: true,
        },
      ],
      tournament: {
        zh: "本月比武大会在里斯本举行。",
        en: "This month's tournament is held at Lisbon.",
      },
    },
    investments: [{ nationId: "england", amount: 1200, portId: LISBON }],
    spar: { stake: 100, step: 10, winPct: 45 },
  },
};

/* ---------------------------------------------------------------------- */
/* M4 sailing scenario (fixture only)                                      */
/*                                                                         */
/* A second snapshot beside the docked-at-Lisbon port fixture: the player  */
/* is at sea just off Lisbon's berth, with a handful of NPC markers, a      */
/* wreck and a known explored band so the canvas + minimap are demoable     */
/* before the M2 live stream lands. The port fixture above is untouched —  */
/* this object is what the fixture GameClient streams while the `world`     */
/* screen runs. Every number is a fixture value, not a game rule.           */
/* ---------------------------------------------------------------------- */

/** Encode the §8.1 `explored_tiles` runs (base64, 6-byte LE runs). */
function encodeExploredRows(rows: { y: number; x0: number; len: number }[]): string {
  const bytes = new Uint8Array(rows.length * 6);
  rows.forEach((row, index) => {
    const offset = index * 6;
    const length = row.len - 1;
    bytes[offset] = row.y & 0xff;
    bytes[offset + 1] = (row.y >> 8) & 0xff;
    bytes[offset + 2] = row.x0 & 0xff;
    bytes[offset + 3] = (row.x0 >> 8) & 0xff;
    bytes[offset + 4] = length & 0xff;
    bytes[offset + 5] = (length >> 8) & 0xff;
  });
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

const EXPLORED_ROWS: { y: number; x0: number; len: number }[] = [];
for (let y = 560; y <= 655; y += 1) {
  EXPLORED_ROWS.push({ y, x0: 1985, len: 100 });
}

/** The fixture sailing save (at sea off Lisbon; `current_port` is null). */
export const fixtureSailingSnapshot: GameSnapshot = {
  ...fixtureState,
  world: {
    ...fixtureState.world,
    position: { x: 2043, y: 608 },
    weather: "fair",
    sail_trim: "normal",
    heading: "E",
    wind_dir: "E",
  },
  current_port: null,
  known_ports: [LISBON, "madeira", "cadiz", "seville", "london"],
  explored_tiles: encodeExploredRows(EXPLORED_ROWS),
  npc_fleets: [],
  wrecks: [{ id: "wreck_lisbon_1", position: { x: 2043, y: 618 }, kind: "salvage" }],
};

/** §4.5.2 marker rows for the sailing scenario (letters ride the state). */
export const fixtureSailingMarkers: NpcMarkerState[] = [
  {
    id: "npc_trader_lisbon",
    role: "trader",
    nation_id: PORTUGAL,
    position: { x: 2045, y: 600 },
    heading: "SW",
    marker_letter: "T",
    wake: [
      { x: 2046, y: 599 },
      { x: 2047, y: 598 },
    ],
  },
  {
    id: "npc_pirate_1",
    role: "pirate",
    nation_id: "",
    position: { x: 2038, y: 605 },
    heading: "E",
    wake: [
      { x: 2037, y: 605 },
      { x: 2036, y: 605 },
    ],
  },
  {
    id: "npc_patrol_1",
    role: "patrol",
    nation_id: SPAIN,
    position: { x: 2049, y: 619 },
    heading: "N",
    marker_letter: "P",
  },
  {
    id: "npc_coaster_1",
    role: "coaster",
    nation_id: "holland",
    position: { x: 2032, y: 612 },
    heading: "NE",
    marker_letter: "c",
    wake: [{ x: 2031, y: 613 }],
  },
];

export const fixtureSailingView: SailingView = {
  npc_markers: fixtureSailingMarkers,
};

/** Scenario constants the fixture client and the screen share. */
export const fixtureSailing = {
  snapshot: fixtureSailingSnapshot,
  view: fixtureSailingView,
  /** Day 12, 08:30 — the same wall clock the port fixture shows. */
  clock_min: 510,
  /** Fixture display speed (knots); M2's tick carries the real number. */
  speed: 4.2,
  /** Lisbon's committed berth tile — the fixture's one docking target. */
  dock: { port_id: LISBON, x: 2050, y: 615 },
} as const;
