/**
 * The authoritative state types (docs/90-ARCHITECTURE.md §0.3 `state`
 * frame = the §8.1-shaped save payload + transient keys). The TS client
 * never computes rules; these interfaces describe what the server sends.
 */
import type { L10nString, L10nValue, Locale } from "../i18n";

export type { Locale };

export type AttrId = "constitution" | "intellect" | "charisma" | "courage" | "luck";
export type SkillId =
  | "seamanship"
  | "navigation"
  | "swordplay"
  | "gunnery"
  | "appraisal"
  | "negotiation"
  | "cartography"
  | "rumour";
export type Direction8 = "N" | "NE" | "E" | "SE" | "S" | "SW" | "W" | "NW";
export type SailTrim = "furled" | "reefed" | "normal" | "full";
export type Weather = "calm" | "fair" | "strong" | "storm";
export type FacilityId = "market" | "shipyard" | "tavern" | "inn" | "guild" | "palace";

export interface PlayerState {
  nation_id: string;
  background_id: string;
  attributes: Record<AttrId, number>;
  skills: Record<SkillId, number>;
  skill_counters: Record<SkillId, number>;
  alloc_pending: number;
  xp: number;
  level: number;
  autopilot?: { dest_port_id: string };
  officers: string[];
  reputation: Record<string, number>;
  profit_by_nation: Record<string, number>;
  profit_rep_awarded: Record<string, number>;
  equipment: { weapon: string; armor: string; figurehead?: string; sail?: string };
}

export interface ShipState {
  ship_type_id: string;
  durability: number;
  crew: number;
  provisions: number;
  water: number;
  cannons: number;
  cargo: Record<string, number>;
  equipment: { figurehead: string; sail: string };
}

export interface WorldState {
  position: { x: number; y: number };
  map_id: "world";
  weather: Weather;
  sail_trim: SailTrim;
  heading: Direction8;
  wind_dir: Direction8;
}

export interface OfficerState {
  loyalty: number;
  sea_days: number;
  post_id: string;
  ship_id: string;
  talk_cd_day: number;
  gift_cd_day: number;
  defeats: number;
  wage_mult?: number;
  skill_deltas?: Record<string, number>;
}

export interface CaptainState {
  tier: number;
  role: string;
  last_seen_day: number;
  stance?: string;
}

export interface Bounty {
  amount: number;
  day: number;
}

export interface Quest {
  id: string;
  type: string;
  accepted_day: number;
  deadline_day: number;
  [key: string]: unknown;
}

export interface NpcFleet {
  id: string;
  seed: number;
  [key: string]: unknown;
}

export interface Wreck {
  id: string;
  position: { x: number; y: number };
  [key: string]: unknown;
}

/* ---------------------------------------------------------------------- */
/* World / sailing view types (M4, additive)                               */
/*                                                                         */
/* The tick frame is the authoritative sailing slice (client/types.ts).    */
/* NPC fleet markers and wrecks are state projections: the M2 server must  */
/* supply the same §4.5.2 marker rows the oracle's NpcFleets.markers()     */
/* exposes (role, nation, letter, wake). The fixture supplies them here.   */
/* ---------------------------------------------------------------------- */

export interface WorldCell {
  x: number;
  y: number;
}

/** One §4.5.2 world-map marker (nation square + role letter + wake trail). */
export interface NpcMarkerState {
  id: string;
  role: string;
  nation_id: string;
  position: WorldCell;
  heading: Direction8;
  /** §4.5.2 role letter from the state (absent = no letter, e.g. pirate). */
  marker_letter?: string;
  /** Recent walked cells, newest first; §4.5.2 draws a 5-tile dashed wake. */
  wake?: WorldCell[];
  /** Docked markers draw no wake and sit on the port's berth tile. */
  docked?: boolean;
  /** Convoy member count beside the shared marker (§4.5.2). */
  convoy?: number;
}

/** The world-screen projection: NPC markers (wrecks ride `GameState.wrecks`). */
export interface SailingView {
  npc_markers: NpcMarkerState[];
}

export interface MarketEvent {
  id: string;
  good_id: string;
  port_id: string;
  [key: string]: unknown;
}

export interface PermitState {
  home: boolean;
  foreign: Record<string, boolean>;
}

/**
 * The §8.1 payload shape carried into the web era (SAVE_VERSION = 1).
 * The `phase` key is the design-phase number (9 at the cutover); it is not
 * the save version (90-ARCHITECTURE.md §0.5).
 */
export interface GameState {
  save_version: 1;
  saved_at: number;
  phase: number;
  locale: Locale;
  day: number;
  gold: number;
  player: PlayerState;
  fleet: ShipState[];
  morale: number;
  world: WorldState;
  current_port: string | null;
  known_ports: string[];
  explored_tiles: string;
  port_investments: Record<string, number>;
  quests: never[];
  discoveries_found: string[];
  npc_fleets: NpcFleet[];
  officer_states: Record<string, OfficerState>;
  captain_states: Record<string, CaptainState>;
  proximity_cooldowns: Record<string, number>;
  market_stocks: Record<string, Record<string, number>>;
  wrecks: Wreck[];
  npc_preset: string;
  market_events: MarketEvent[];
  control_prefs: { input_mode: string; current_mode: string };
  permits: PermitState;
  port_allegiance: Record<string, string>;
  month_invested: Record<string, number>;
  nation_treasuries: Record<string, number>;
  fame_commended: Record<string, boolean>;
  // Phase-3+ fields.
  fame: number;
  titles: Record<string, string>;
  bounties: Record<string, Bounty>;
  active_quests: Quest[];
  completed_royal_missions: Record<string, number>;
  discoveries_reported: string[];
  discovery_hints: Record<string, boolean>;
  battles_won: number;
  retired: boolean;
  retired_at: number;
}

/** The transient keys the server rides on the state frame (§0.3). */
export interface GameSnapshot extends GameState {
  pending_encounter: unknown | null;
  npc_port_log: unknown[];
  levelup: unknown | null;
}

/* ---------------------------------------------------------------------- */
/* Screen projections (M3 fixture contract)                                */
/*                                                                         */
/* These are PRESENTATION projections the pure renderer needs. They are    */
/* NOT part of the frozen §8.1 save shape: prices, gate reasons and        */
/* open/closed status are server-computed rules. The M3 fixture supplies   */
/* them; M2 must supply the same projections (see the final report).       */
/* ---------------------------------------------------------------------- */

export interface PortFacilityStatus {
  id: FacilityId;
  phase: number;
  enabled: boolean;
  status:
    | { kind: "open"; open: string; close: string }
    | { kind: "closed"; open: string; close: string }
    | { kind: "always" }
    | { kind: "stub"; reasonKey: string };
}

export interface PortView {
  portId?: string;
  nationId?: string;
  /** The server wall-clock text ("HH:MM") the header plate prints. */
  clock?: string;
  facilities: PortFacilityStatus[];
}

export type MarketTrend = "up" | "down" | "flat";
export type UiTier = "good" | "warn" | "bad";
export type MarketTaxBadge = "in_sphere" | "exempt" | "foreign" | "unallied";

export interface MarketGoodRow {
  goodId: string;
  stock: number;
  trend: MarketTrend;
  marginal: number;
  unitPrice: number;
  owned: number;
  specialty: boolean;
  notBought?: boolean;
  exclusiveLocked?: boolean;
}

export interface CaptainTableRow {
  id: string;
  name: L10nString;
  roleKey: string;
  tier: number;
  lastSeenDay: number;
  facility?: FacilityId;
}

export interface MarketIntelRow {
  id: string;
  portId: string;
}

export interface MarketView {
  portId: string;
  taxBadge: MarketTaxBadge;
  taxRatePct: number;
  buyTariffGold: number;
  sellTariffGold: number;
  rows: MarketGoodRow[];
  specialtyGoodIds: string[];
  investedGold: number;
  investedPct: number;
  investCapPct: number;
  investAmount: number;
  investGate: { kind: "ok" | "allowance" | "exhausted" | "blocked"; nationId?: string };
  captains: CaptainTableRow[];
  freeIntelPortId?: string;
}

export interface ProvisionsView {
  portId: string;
  clock: string;
  days: number;
  daysBarMax: number;
  daysGoodMin: number;
  daysWarnMin: number;
  shortWarningDays?: number;
  gateReasonKey?: string;
  provisions: { qty: number; price: number };
  water: { qty: number; price: number };
  holdUsed: number;
  holdCapacity: number;
  holdFree: number;
  cargo: { goodId: string; qty: number }[];
  fillBlocked: boolean;
}

export interface ShipCatalogRow {
  shipTypeId: string;
  price: number;
  canBuy: boolean;
  requirementKey?: string;
}

export interface FleetRow {
  index: number;
  shipTypeId: string;
  durability: number;
  maxDurability: number;
  crew: number;
  crewMax: number;
  cannons: number;
  slots: number;
  cargoUsed: number;
  cargoCapacity: number;
  cargoFree: number;
  canSell: boolean;
  sellPrice: number;
  canRepair: boolean;
  repairCostPerPoint: number;
}

export interface ShipyardView {
  portId: string;
  catalog: ShipCatalogRow[];
  fleet: FleetRow[];
  equipment: { weapon?: string; armor?: string };
}

export interface InnView {
  portId: string;
  rest: { days: number; price: number; canRest: boolean };
  moraleTier: UiTier;
  moraleMax: number;
  oddJob: { eligible: boolean; reasonKey?: string };
  captains: CaptainTableRow[];
}

export type CommissionType = "delivery" | "bounty" | "exploration" | "royal";

export interface CommissionRow {
  id: string;
  type: CommissionType;
  lineKey: string;
  lineValues: Record<string, L10nValue>;
  daysLeft: number;
  rewardGold: number;
  rep: number;
  canAccept: boolean;
  hintKey?: string;
  reasonKey?: string;
}

export interface ReportRow {
  discoveryId: string;
  rewardGold: number;
  fame: number;
}

export interface GuildView {
  portId: string;
  offersRefreshDay: number;
  offers: CommissionRow[];
  offersAnnounce?: L10nString;
  reports: ReportRow[];
  tournament?: L10nString;
  offersBlockedKey?: string;
}

export interface PermitOffer {
  price: number;
  owned: boolean;
  canBuy: boolean;
  noteKey?: string;
  nationId?: string;
}

export interface PalaceView {
  portId: string;
  nationId: string;
  rank: string;
  nextRank?: { rank: string; fame: number; missions: number };
  ceremonyAvailable: boolean;
  mission?: {
    objectiveKey: string;
    objectiveValues: Record<string, L10nValue>;
    daysLeft: number;
    canAccept: boolean;
  };
  missionRepLock?: number;
  repairDiscountPct?: number;
  repairAvailable: boolean;
  bounty?: { amount: number; canPay: boolean };
  permits: { home: PermitOffer; foreign: PermitOffer };
  tournament?: {
    hostPortId: string;
    firstDay: number;
    lastDay: number;
    prizeGold: number;
    fame: number;
    entered: boolean;
    canEnter: boolean;
    blockedKey?: string;
  };
  board: BountyBoardRow[];
  inform: InformRow[];
  commend?: { nationId: string; portId: string };
}

export interface BountyBoardRow {
  captainId: string;
  name: L10nString;
  tier: number;
  roleKey: string;
  rewardGold: number;
  portId?: string;
}

export interface InformRow {
  captainId: string;
  text: L10nString;
  cost: number;
  canInform: boolean;
}

export interface RecruitRow {
  officerId: string;
  roleKey: string;
  wage: number;
  signingFee: number;
  skills: Record<string, number>;
  canRecruit: boolean;
}

export interface RumorRow {
  id: string;
  text: L10nString;
  known: boolean;
}

export interface TavernView {
  portId: string;
  moraleTier: UiTier;
  moraleMax: number;
  captains: CaptainTableRow[];
  crew: {
    count: number;
    max: number;
    min: number;
    morale: number;
    perHead: number;
    hireCost: number;
    canHire: boolean;
    fillAvailable: boolean;
    reasonKey?: string;
  };
  recruitable: RecruitRow[];
  roster: RecruitRow[];
  rumors: { price: number; rows: RumorRow[]; tournament?: L10nString };
  investments: { nationId: string; amount: number; portId: string }[];
  spar: { stake: number; step: number; winPct: number };
}

export interface ScreenViews {
  port: PortView;
  market: MarketView;
  provisions: ProvisionsView;
  shipyard: ShipyardView;
  inn: InnView;
  guild: GuildView;
  palace: PalaceView;
  tavern: TavernView;
}
