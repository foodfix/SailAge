/**
 * The M3 screen-projection contract (docs/90-ARCHITECTURE.md §0.4 — the
 * "no-rules-in-TS" channel):
 *
 *   GET /api/view/<screen_id> -> {ok: true, screen, views}
 *
 * `views` is the server-computed projection the screen renders: prices,
 * tax badges, gate reasons, facility open/closed state, recruit lists,
 * offers, permits, tournament state. The client performs no rule math; it
 * requests the view for the screen it shows and refreshes it on every
 * `state` frame.
 *
 * This module is the single typed contract the eight screens import. The
 * shapes ratify the M3 fixture (`state/types.ts`'s `ScreenViews`) where a
 * screen already rendered it; every addition is optional so the
 * `?fixture=1` demo keeps type-checking and running unchanged.
 */
import type { L10nString, L10nValue } from "../i18n";
import type { ApiErrorBody } from "../client/types";
import type { FacilityId } from "./types";

export type ScreenViewId =
  | "port"
  | "market"
  | "provisions"
  | "shipyard"
  | "inn"
  | "guild"
  | "palace"
  | "tavern";

export const VIEW_SCREENS: readonly ScreenViewId[] = [
  "port",
  "market",
  "provisions",
  "shipyard",
  "inn",
  "guild",
  "palace",
  "tavern",
] as const;

export function isScreenViewId(id: string): id is ScreenViewId {
  return (VIEW_SCREENS as readonly string[]).includes(id);
}

export type ViewStatus = "idle" | "loading" | "ready" | "error";

export interface ScreenViewState {
  status: ViewStatus;
  /** The refusal's ui_strings key (§0.4 `error.msg`), when status is "error". */
  errorKey?: string;
}

/* ---------------------------------------------------------------------- */
/* Shared row shapes                                                       */
/* ---------------------------------------------------------------------- */

export interface CaptainTableRow {
  id: string;
  name: L10nString;
  roleKey: string;
  tier: number;
  lastSeenDay: number;
  facility?: FacilityId;
}

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

/* ---------------------------------------------------------------------- */
/* S4 port hub — facility cards + header                                   */
/* ---------------------------------------------------------------------- */

export interface PortView {
  portId?: string;
  /** The port's effective alignment (falls back to its data nation). */
  nationId?: string;
  facilities: PortFacilityStatus[];
}

/* ---------------------------------------------------------------------- */
/* S5 market                                                               */
/* ---------------------------------------------------------------------- */

export type MarketTrend = "up" | "down" | "flat";
export type UiTier = "good" | "warn" | "bad";
export type MarketTaxBadge = "in_sphere" | "exempt" | "foreign" | "unallied";
export type ArrowDirection = "up" | "down" | "";

export interface MarketGoodRow {
  goodId: string;
  stock: number;
  trend: MarketTrend;
  /** The marginal (next-tranche) buy price. */
  marginal: number;
  /** The fixture's single unit price (kept for `?fixture=1`). */
  unitPrice?: number;
  buyPrice?: number;
  sellPrice?: number;
  owned: number;
  specialty: boolean;
  /** A producing port never buys its own produce (sell disabled 不收购). */
  notBought?: boolean;
  /** A 专营货 row below the allegiance/dev entitlement. */
  exclusiveLocked?: boolean;
  /** Appraisal-gated arrows (docs/30 §4.2); "" below the gates. */
  profitArrow?: ArrowDirection;
  memoryArrow?: ArrowDirection;
}

export interface MarketIntelRow {
  captainId: string;
  name: L10nString;
  roleKey: string;
  nationId: string;
  /** Stance ≥ the intel gate: the next-lane hint is free. */
  free: boolean;
  destPortId: string;
}

export type InvestGateKind =
  | "ok"
  | "allowance"
  | "exhausted"
  | "blocked"
  | "no_gold";

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
  investGate: { kind: InvestGateKind; nationId?: string };
  captains: CaptainTableRow[];
  /** The pooled hold figures (the header row; docs/40 §4.2). */
  holdUsed?: number;
  holdCapacity?: number;
  holdFree?: number;
  /** The captain lane intel rows (server projection, M3). */
  intel?: MarketIntelRow[];
  freeIntelPortId?: string;
}

/* ---------------------------------------------------------------------- */
/* S3 provisioning prompt                                                  */
/* ---------------------------------------------------------------------- */

export interface SupplyRow {
  qty: number;
  price: number;
  /** This kind's own days-of-supply (the §4.10 formula on the pooled stack). */
  days?: number;
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
  provisions: SupplyRow;
  water: SupplyRow;
  holdUsed: number;
  holdCapacity: number;
  holdFree: number;
  cargo: { goodId: string; qty: number }[];
  fillBlocked: boolean;
}

/* ---------------------------------------------------------------------- */
/* S6 shipyard                                                             */
/* ---------------------------------------------------------------------- */

export type RowState = "available" | "tier_gray" | "allegiance_gray";

export interface ShipCatalogRow {
  shipTypeId: string;
  price: number;
  canBuy: boolean;
  /** The sim's buy-block reason key ("" when buyable). */
  requirementKey?: string;
  requirementValues?: Record<string, L10nValue>;
  rowState?: RowState;
  noteKey?: string;
  noteValues?: Record<string, L10nValue>;
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
  sellReasonKey?: string;
  canRepair: boolean;
  /** The exact discounted price of one durability point. */
  repairCostPerPoint: number;
  repairReasonKey?: string;
  maxRepairPoints?: number;
  maxRefit?: number;
}

export interface EquipmentItemRow {
  equipmentId: string;
  price: number;
  netCost: number;
  canBuy: boolean;
  rowState: RowState;
  reasonKey?: string;
  noteKey?: string;
  noteValues?: Record<string, L10nValue>;
}

export interface EquipmentSlotRow {
  slot: string;
  /** -1 = the player's own slot; >= 0 = that hull's slot. */
  shipIndex: number;
  worn: string;
  canUnequip: boolean;
  items: EquipmentItemRow[];
}

export interface ShipyardView {
  portId: string;
  catalog: ShipCatalogRow[];
  fleet: FleetRow[];
  equipment: { weapon?: string; armor?: string };
  /** The player's and every hull's equipment slots (server projection). */
  equipmentSlots?: EquipmentSlotRow[];
}

/* ---------------------------------------------------------------------- */
/* S8 inn                                                                  */
/* ---------------------------------------------------------------------- */

export interface InnView {
  portId: string;
  rest: { days: number; price: number; canRest: boolean };
  moraleTier: UiTier;
  moraleMax: number;
  oddJob: { eligible: boolean; reasonKey?: string };
  captains: CaptainTableRow[];
}

/* ---------------------------------------------------------------------- */
/* S12 guild                                                               */
/* ---------------------------------------------------------------------- */

export type CommissionType = "delivery" | "bounty" | "exploration" | "royal";

export interface CommissionRow {
  id: string;
  type: CommissionType;
  lineKey: string;
  lineValues: Record<string, L10nValue>;
  daysLeft: number;
  rewardGold: number;
  rep: number;
  fame?: number;
  canAccept: boolean;
  /** The exploration offer's region hint (already an L10nString). */
  hintText?: L10nString;
  hintKey?: string;
  reasonKey?: string;
  status?: string;
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
  /** Accepted quests (the M6 quest log's server projection). */
  active?: CommissionRow[];
  tournament?: L10nString;
  offersBlockedKey?: string;
}

/* ---------------------------------------------------------------------- */
/* S13 palace                                                              */
/* ---------------------------------------------------------------------- */

export interface PermitOffer {
  price: number;
  owned: boolean;
  canBuy: boolean;
  noteKey?: string;
  nationId?: string;
}

export interface PalaceMission {
  objectiveKey: string;
  objectiveValues: Record<string, L10nValue>;
  daysLeft: number;
  canAccept: boolean;
  active?: boolean;
  reasonKey?: string;
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

export interface PalaceTournament {
  hostPortId: string;
  firstDay: number;
  lastDay: number;
  prizeGold: number;
  fame: number;
  entered: boolean;
  canEnter: boolean;
  fee?: number;
  blockedKey?: string;
}

export interface PalaceView {
  portId: string;
  nationId: string;
  rank: string;
  nextRank?: { rank: string; fame: number; missions: number };
  ceremonyAvailable: boolean;
  mission?: PalaceMission;
  missionRepLock?: number;
  repairDiscountPct?: number;
  repairAvailable: boolean;
  bounty?: { amount: number; canPay: boolean };
  permits: { home: PermitOffer; foreign: PermitOffer };
  tournament?: PalaceTournament;
  board: BountyBoardRow[];
  inform: InformRow[];
  commend?: { nationId: string; portId: string };
  /** The retire row exists only at a duke's palace (docs/70-* §4.7). */
  canRetire?: boolean;
}

/* ---------------------------------------------------------------------- */
/* S7 tavern                                                               */
/* ---------------------------------------------------------------------- */

export interface RecruitRow {
  officerId: string;
  roleKey: string;
  wage: number;
  signingFee: number;
  skills: Record<string, number>;
  canRecruit: boolean;
  /** Roster rows only: the Dismiss button's gate. */
  canDismiss?: boolean;
}

export interface RumorRow {
  id: string;
  text: L10nString;
  known: boolean;
  /** Discovery hints are purchasable; traffic/telegraph rows are not. */
  purchasable?: boolean;
  price?: number;
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
    canFire?: boolean;
    reasonKey?: string;
  };
  recruitable: RecruitRow[];
  roster: RecruitRow[];
  rumors: { price: number; rows: RumorRow[]; tournament?: L10nString };
  investments: { nationId: string; amount: number; portId: string }[];
  spar: { stake: number; step: number; winPct: number; canSpar?: boolean };
}

/* ---------------------------------------------------------------------- */
/* The envelope + the per-screen lookup                                    */
/* ---------------------------------------------------------------------- */

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

export type ScreenViewOf<S extends ScreenViewId> = ScreenViews[S];

export type ViewEnvelope<S extends ScreenViewId> =
  | { ok: true; screen: S; views: ScreenViewOf<S> }
  | { ok: false; error: ApiErrorBody };
