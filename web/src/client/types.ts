/**
 * The frozen wire contract (docs/90-ARCHITECTURE.md §0.3 / §0.4) — types
 * only. The M2 server implements this 1:1; M3 ships a fixture client so
 * the screens run standalone.
 *
 * Frame convention: one JSON object per frame, `{"type": "<name>", …}`,
 * payload keys inlined at the top level.
 */
import type {
  Direction8,
  FacilityId,
  GameSnapshot,
  Locale,
  SailTrim,
  Weather,
} from "../state/types";

/**
 * One §0.3 `tick.markers` row (the §4.5.2 marker projection, server shape):
 * the save-payload `cell` (never `position`) and the ≤5-cell wake trail.
 * `heading` (§4.4 dir id, "" docked) + flagship `ship_type` ride since the
 * 2026-11-14 NPC hull-token amendment (`90-*` §0.3).
 */
export interface NpcTickMarker {
  id: string;
  role: string;
  nation_id: string;
  cell: { x: number; y: number };
  sailing: boolean;
  heading?: string;
  ship_type?: string;
  wake?: { x: number; y: number }[];
}

/* ---------------------------------------------------------------------- */
/* Server -> client frames (§0.3, frozen)                                  */
/* ---------------------------------------------------------------------- */

export interface SaveSlot {
  slot: number;
  day: number;
  nation_id: string;
  port_id: string;
  gold: number;
  saved_at: number;
}

export interface HelloFrame {
  type: "hello";
  save_version: number;
  tick_hz: number;
  broadcast_hz: number;
  locale: Locale;
  has_run: boolean;
  current_screen: string;
  saves: SaveSlot[];
}

/** The §8.1-shaped snapshot plus the transient keys, inlined. */
export type StateFrame = GameSnapshot & { type: "state" };

export interface TickFrame {
  type: "tick";
  day: number;
  clock_min: number;
  position: { x: number; y: number };
  heading: Direction8;
  sail_trim: SailTrim;
  wind_dir: Direction8;
  weather: Weather;
  speed: number;
  gold: number;
  morale: number;
  autopilot: { dest_port_id: string } | null;
  contact_hint: string;
  /** §0.3 `tick.markers` — the living-sea slice within MARKER_VIEW_RADIUS_TILES. */
  markers?: NpcTickMarker[];
}

export interface BattleShipFrame {
  id: string;
  side: string;
  kind: string;
  position: { x: number; y: number };
  velocity: { x: number; y: number };
  heading8: Direction8;
  hull: number;
  crew: number;
  morale: number;
  reload: { port: number; starboard: number };
}

export interface BattleTickFrame {
  type: "battle_tick";
  round: number;
  phase: string;
  ships: BattleShipFrame[];
  wind: { dir: Direction8; strength: number };
  weather: Weather;
  orders_due: boolean;
  /** §0.3 (2026-11-14 amendment): the acting unit's ship id ("" none/over). */
  acting_id?: string;
  /** The acting player unit's `legal_velocities` endpoints (absolute cells). */
  move_range?: { x: number; y: number }[];
}

/** Mirrors the §5.1 EventBus table verbatim. */
export type EventName =
  | "day_advanced"
  | "gold_changed"
  | "port_entered"
  | "game_over"
  | "battle_started"
  | "battle_finished"
  | "quests_changed"
  | (string & {});

export interface EventFrame {
  type: "event";
  name: EventName;
  args: Record<string, unknown>;
}

export interface ErrorFrame {
  type: "error";
  code: string;
  msg: string;
}

export type ServerFrame =
  | HelloFrame
  | StateFrame
  | TickFrame
  | BattleTickFrame
  | EventFrame
  | ErrorFrame;

/* ---------------------------------------------------------------------- */
/* Client -> server intents (§0.3, frozen)                                 */
/* ---------------------------------------------------------------------- */

export type HelmDir = Direction8 | "stop";
export type BattleVerb = "broadside" | "hook" | "hold" | "retreat" | "surrender";
export type CannonSide = "port" | "starboard";
export type ShotType = "round" | "chain" | "armor_piercing" | "grape";

export interface HelmIntent {
  type: "helm";
  dir: HelmDir;
}
export interface SailTrimIntent {
  type: "sail_trim";
  trim: SailTrim;
}
export interface SailToIntent {
  type: "sail_to";
  x: number;
  y: number;
}
export interface WaitIntent {
  type: "wait";
}
export interface InterceptIntent {
  type: "intercept";
  fleet_id?: string;
  cancel?: boolean;
}
export interface AutopilotIntent {
  type: "autopilot";
  dest_port_id?: string;
  cancel?: boolean;
}
export interface BattleOrderIntent {
  type: "battle_order";
  station: string;
  desired_heading8: Direction8;
  desired_speed_band: string;
  assigned_target: string;
  discipline: string;
}
export interface BattleActionIntent {
  type: "battle_action";
  verb: BattleVerb;
  side?: CannonSide;
  shot?: ShotType;
}export interface LocaleIntent {
  type: "locale";
  locale: Locale;
}

export type ClientIntent =
  | HelmIntent
  | SailTrimIntent
  | SailToIntent
  | WaitIntent
  | InterceptIntent
  | AutopilotIntent
  | BattleOrderIntent
  | BattleActionIntent
  | LocaleIntent;

/* ---------------------------------------------------------------------- */
/* HTTP actions (§0.4, frozen endpoints)                                   */
/* ---------------------------------------------------------------------- */

export interface ApiErrorBody {
  code: string;
  msg: string;
}

export type ApiResult<T = Record<string, unknown>> =
  | ({ ok: true } & T)
  | { ok: false; error: ApiErrorBody };

export interface NewGameRequest {
  nation_id: string;
  background_id: string;
  attr_alloc: Record<string, number>;
  skill_alloc: Record<string, number>;
}

export interface SavesResponse {
  saves: SaveSlot[];
}

/** The frozen fixed endpoints: new_game / load / save / saves / state / locale. */
export type FrozenEndpoint =
  | "POST /api/new_game"
  | "POST /api/load"
  | "POST /api/save"
  | "GET /api/saves"
  | "GET /api/state"
  | "POST /api/locale";

/**
 * Facility verbs. The inventory freezes in the M2 acceptance record before
 * the first screen consumes it (§0.4); these are the M3 proposal used by
 * the eight screens (one route per verb: POST /api/<facility>/<verb>).
 */
export type ActionFacility = FacilityId | "port" | "provisions" | "settings" | "people" | "fleet" | "sandbox";

/* ---------------------------------------------------------------------- */
/* The screen-facing client                                                */
/* ---------------------------------------------------------------------- */

export interface MarketActions {
  buy(goodId: string, qty: number): Promise<ApiResult>;
  sell(goodId: string, qty: number): Promise<ApiResult>;
  invest(amount: number): Promise<ApiResult>;
}
export interface ProvisionsActions {
  buy(kind: "provisions" | "water", qty: number): Promise<ApiResult>;
  jettison(kind: "provisions" | "water", qty: number): Promise<ApiResult>;
  fill(): Promise<ApiResult>;
  sail(): Promise<ApiResult>;
}
export interface ShipyardActions {
  buy(shipTypeId: string): Promise<ApiResult>;
  repair(shipIndex: number, points: number): Promise<ApiResult>;
  refit(shipIndex: number, cannons: number): Promise<ApiResult>;
  sell(shipIndex: number): Promise<ApiResult>;
  equip(shipIndex: number, slot: string, equipmentId: string): Promise<ApiResult>;
  unequip(shipIndex: number, slot: string): Promise<ApiResult>;
}
export interface InnActions {
  rest(days: number): Promise<ApiResult>;
  oddJob(): Promise<ApiResult>;
}
export interface GuildActions {
  acceptOffer(offerId: string): Promise<ApiResult>;
  report(discoveryId: string): Promise<ApiResult>;
}
export interface PalaceActions {
  ceremony(): Promise<ApiResult>;
  acceptMission(): Promise<ApiResult>;
  buyPermit(kind: "home" | "foreign", nationId?: string): Promise<ApiResult>;
  repairFleet(): Promise<ApiResult>;
  payBounty(nationId: string): Promise<ApiResult>;
  inform(captainId: string): Promise<ApiResult>;
  enterTournament(): Promise<ApiResult>;
  retire(): Promise<ApiResult>;
}
export interface TavernActions {
  hire(qty: number): Promise<ApiResult>;
  fire(qty: number): Promise<ApiResult>;
  fillCrew(): Promise<ApiResult>;
  downToMin(): Promise<ApiResult>;
  recruit(officerId: string): Promise<ApiResult>;
  dismiss(officerId: string): Promise<ApiResult>;
  buyRumor(rumorId: string): Promise<ApiResult>;
  spar(stake: number): Promise<ApiResult>;
}
export interface PortActions {
  enter(facility: FacilityId): Promise<ApiResult>;
  setSail(): Promise<ApiResult>;
}

export interface GameClient {
  readonly transport: "fixture" | "http";
  /** One WS per session; returns the unsubscribe. */
  connect(handlers: {
    onFrame: (frame: ServerFrame) => void;
    onClose?: (code: number, reason: string) => void;
  }): () => void;
  /** WS intent (§0.3). */
  send(intent: ClientIntent): void;
  /** GET /api/state */
  getState(): Promise<GameSnapshot>;
  /** GET /api/saves */
  getSaves(): Promise<SavesResponse>;
  /** POST /api/new_game */
  newGame(body: NewGameRequest): Promise<ApiResult>;
  /** POST /api/load {slot} */
  load(slot: number): Promise<ApiResult>;
  /** POST /api/save {slot} */
  save(slot: number): Promise<ApiResult>;
  /** POST /api/locale {locale} */
  setLocale(locale: Locale): Promise<ApiResult>;
  /** POST /api/<facility>/<verb> — the facility inventory freezes at M2. */
  action<T = Record<string, unknown>>(
    facility: ActionFacility,
    verb: string,
    body?: Record<string, unknown>,
  ): Promise<ApiResult<T>>;

  port: PortActions;
  market: MarketActions;
  provisions: ProvisionsActions;
  shipyard: ShipyardActions;
  inn: InnActions;
  guild: GuildActions;
  palace: PalaceActions;
  tavern: TavernActions;
}
