/**
 * The fixture GameClient — lets the eight screens run standalone before M2
 * lands. It never computes game rules: every verb is recorded and answered
 * with the §0.4 success envelope; authoritative state comes from the
 * fixture snapshot (and, later, from the server's `state` frame).
 */
import { fixtureState } from "../state/fixture";
import type { FacilityId, GameSnapshot, Locale } from "../state/types";
import type {
  ApiResult,
  ClientIntent,
  GameClient,
  SavesResponse,
  ServerFrame,
  StateFrame,
} from "./types";

export interface RecordedAction {
  facility: string;
  verb: string;
  body?: Record<string, unknown>;
}

const ok = <T = Record<string, unknown>>(extra?: T): ApiResult<T> =>
  ({ ok: true, ...(extra ?? {}) }) as ApiResult<T>;

export class FixtureGameClient implements GameClient {
  readonly transport = "fixture" as const;

  /** Every HTTP action the screens dispatched (debug/tests). */
  readonly actions: RecordedAction[] = [];
  /** Every WS intent the screens dispatched (debug/tests). */
  readonly intents: ClientIntent[] = [];

  connect(handlers: {
    onFrame: (frame: ServerFrame) => void;
    onClose?: (code: number, reason: string) => void;
  }): () => void {
    const hello: ServerFrame = {
      type: "hello",
      save_version: 1,
      tick_hz: 10,
      broadcast_hz: 10,
      locale: fixtureState.locale,
      has_run: true,
      current_screen: "port",
      saves: [
        {
          slot: 1,
          day: fixtureState.day,
          nation_id: fixtureState.player.nation_id,
          port_id: "lisbon",
          gold: fixtureState.gold,
          saved_at: fixtureState.saved_at,
        },
      ],
    };
    const state: StateFrame = { ...fixtureState, type: "state" };
    queueMicrotask(() => {
      handlers.onFrame(hello);
      handlers.onFrame(state);
    });
    return () => undefined;
  }

  send(intent: ClientIntent): void {
    this.intents.push(intent);
  }

  async getState(): Promise<GameSnapshot> {
    return fixtureState;
  }

  async getSaves(): Promise<SavesResponse> {
    return {
      saves: [
        {
          slot: 1,
          day: fixtureState.day,
          nation_id: fixtureState.player.nation_id,
          port_id: "lisbon",
          gold: fixtureState.gold,
          saved_at: fixtureState.saved_at,
        },
      ],
    };
  }

  async newGame(): Promise<ApiResult> {
    return ok();
  }

  async load(): Promise<ApiResult> {
    return ok();
  }

  async save(): Promise<ApiResult> {
    return ok();
  }

  async setLocale(_locale: Locale): Promise<ApiResult> {
    return ok();
  }

  async action<T = Record<string, unknown>>(
    facility: string,
    verb: string,
    body?: Record<string, unknown>,
  ): Promise<ApiResult<T>> {
    this.actions.push({ facility, verb, body });
    return ok<T>();
  }

  port = {
    enter: (facility: FacilityId) => this.action("port", "enter", { facility }),
    setSail: () => this.action("port", "set_sail"),
  };

  market = {
    buy: (goodId: string, qty: number) => this.action("market", "buy", { good_id: goodId, qty }),
    sell: (goodId: string, qty: number) => this.action("market", "sell", { good_id: goodId, qty }),
    invest: (amount: number) => this.action("market", "invest", { amount }),
  };

  provisions = {
    buy: (kind: "provisions" | "water", qty: number) =>
      this.action("provisions", "buy", { kind, qty }),
    jettison: (kind: "provisions" | "water", qty: number) =>
      this.action("provisions", "jettison", { kind, qty }),
    fill: () => this.action("provisions", "fill"),
    sail: () => this.action("provisions", "sail"),
  };

  shipyard = {
    buy: (shipTypeId: string) => this.action("shipyard", "buy", { ship_type_id: shipTypeId }),
    repair: (shipIndex: number, points: number) =>
      this.action("shipyard", "repair", { ship_index: shipIndex, points }),
    refit: (shipIndex: number, cannons: number) =>
      this.action("shipyard", "refit", { ship_index: shipIndex, cannons }),
    sell: (shipIndex: number) => this.action("shipyard", "sell", { ship_index: shipIndex }),
    equip: (shipIndex: number, slot: string, equipmentId: string) =>
      this.action("shipyard", "equip", { ship_index: shipIndex, slot, equipment_id: equipmentId }),
    unequip: (shipIndex: number, slot: string) =>
      this.action("shipyard", "unequip", { ship_index: shipIndex, slot }),
  };

  inn = {
    rest: (days: number) => this.action("inn", "rest", { days }),
    oddJob: () => this.action("inn", "odd_job"),
  };

  guild = {
    acceptOffer: (offerId: string) => this.action("guild", "accept_offer", { offer_id: offerId }),
    report: (discoveryId: string) =>
      this.action("guild", "report", { discovery_id: discoveryId }),
  };

  palace = {
    ceremony: () => this.action("palace", "ceremony"),
    acceptMission: () => this.action("palace", "accept_mission"),
    buyPermit: (kind: "home" | "foreign", nationId?: string) =>
      this.action("palace", "buy_permit", { kind, nation_id: nationId }),
    repairFleet: () => this.action("palace", "repair_fleet"),
    payBounty: (nationId: string) => this.action("palace", "pay_bounty", { nation_id: nationId }),
    inform: (captainId: string) => this.action("palace", "inform", { captain_id: captainId }),
    enterTournament: () => this.action("palace", "enter_tournament"),
    retire: () => this.action("palace", "retire"),
  };

  tavern = {
    hire: (qty: number) => this.action("tavern", "hire", { qty }),
    fire: (qty: number) => this.action("tavern", "fire", { qty }),
    fillCrew: () => this.action("tavern", "fill_crew"),
    downToMin: () => this.action("tavern", "down_to_min"),
    recruit: (officerId: string) => this.action("tavern", "recruit", { officer_id: officerId }),
    dismiss: (officerId: string) => this.action("tavern", "dismiss", { officer_id: officerId }),
    buyRumor: (rumorId: string) => this.action("tavern", "buy_rumor", { rumor_id: rumorId }),
    spar: (stake: number) => this.action("tavern", "spar", { stake }),
  };
}

export const fixtureClient = new FixtureGameClient();
