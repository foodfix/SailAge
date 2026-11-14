/**
 * The live transport — the frozen `GameClient` (client/types.ts) over the
 * M2 FastAPI server (docs/90-ARCHITECTURE.md §0.3/§0.4).
 *
 *  * one WebSocket per session at `ws://<host>/ws` (same origin; the Vite
 *    dev proxy forwards `/ws`, the production build is served by FastAPI);
 *  * HTTP actions `POST /api/<facility>/<verb>` with the frozen envelope;
 *  * the six fixed endpoints;
 *  * the M3 screen-projection channel `GET /api/view/<screen_id>` (§0.4).
 *
 * Refusal handling is the frozen envelope: an in-game refusal is a 200 body
 * `{ok:false, error:{code, msg}}` where `msg` is a `ui_strings` key; a
 * malformed request is 400/404. Transport faults become an honest envelope
 * (`code: "network"`) so a screen never crashes.
 *
 * Reconnect: a closed socket retries with an exponential backoff (0.5 s
 * doubling to 8 s). The one exception is close code **4001** — the server's
 * "another client is connected" refusal (§0.3): no retry, the notice is
 * surfaced to the shell.
 */
import type {
  ActionFacility,
  ApiResult,
  ClientIntent,
  GameClient,
  SavesResponse,
  ServerFrame,
} from "./types";
import type { GameSnapshot, FacilityId, Locale } from "../state/types";
import type { TickFrame } from "../client/types";
import type { ScreenViewId, ViewEnvelope } from "../state/views";

/** The frozen GameClient plus the M3 projection channel. */
export interface LiveGameClient extends GameClient {
  readonly transport: "http";
  /** GET /api/view/<screen_id> (§0.4). */
  getView<S extends ScreenViewId>(screen: S): Promise<ViewEnvelope<S>>;
}

export interface HttpClientOptions {
  /** HTTP origin; "" = same origin (the default). */
  baseUrl?: string;
  /** WS URL override (tests); default derives from the page origin. */
  wsUrl?: string;
  /** Injected for tests/headless use. */
  fetchImpl?: typeof fetch;
  webSocketImpl?: typeof WebSocket;
}

/** Close code the server uses to refuse a second concurrent client (§0.3). */
export const CLOSE_OTHER_CLIENT = 4001;

/**
 * Dev-only transport counters (`?dev=1` world chip reads them). A plain
 * window-scoped record — never read by game code.
 */
export interface WsDebugInfo {
  ws: "open" | "closed" | "refused" | "idle";
  states: number;
  ticks: number;
  lastTickAt?: number;
  lastTickPos?: string;
}

const debugStore: WsDebugInfo = { ws: "idle", states: 0, ticks: 0 };

function debugNote(patch: Partial<WsDebugInfo>): void {
  Object.assign(debugStore, patch);
  (window as unknown as { __saWsDebug?: WsDebugInfo }).__saWsDebug = debugStore;
}

/** The live transport counters (dev diagnostics only). */
export function wsDebugInfo(): WsDebugInfo {
  return { ...debugStore };
}

const RETRY_BASE_MS = 500;
const RETRY_MAX_MS = 8000;

function defaultWsUrl(): string {
  if (typeof window === "undefined") return "ws://127.0.0.1:8000/ws";
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}/ws`;
}

function refusal(code: string, msg: string): ApiResult<never> {
  return { ok: false, error: { code, msg } };
}

export class HttpClient implements LiveGameClient {
  readonly transport = "http" as const;

  private readonly baseUrl: string;
  private readonly wsUrl: string;
  private readonly fetchImpl: typeof fetch;
  private readonly webSocketImpl: typeof WebSocket;

  private socket: WebSocket | null = null;
  /**
   * Concurrent subscribers share the one socket: the app shell keeps its
   * subscription for the whole run (it owns `state`/`event` routing), while
   * the active screen (world/battle) subscribes on mount. A screen-level
   * connect must never silence the shell — that was the sea→port freeze
   * (the dropped `port_entered` event left the sailing screen stuck).
   */
  private handlers = new Set<{
    onFrame: (frame: ServerFrame) => void;
    onClose?: (code: number, reason: string) => void;
  }>();
  private stopped = false;
  private retryTimer: number | null = null;
  private closeTimer: number | null = null;
  private attempt = 0;

  constructor(options: HttpClientOptions = {}) {
    this.baseUrl = (options.baseUrl ?? "").replace(/\/$/, "");
    this.wsUrl = options.wsUrl ?? defaultWsUrl();
    this.fetchImpl = options.fetchImpl
      ?? ((input: RequestInfo | URL, init?: RequestInit) => fetch(input, init));
    this.webSocketImpl = options.webSocketImpl ?? WebSocket;
  }

  /* ------------------------------------------------------------------ */
  /* WebSocket (§0.3)                                                    */
  /* ------------------------------------------------------------------ */

  connect(handlers: {
    onFrame: (frame: ServerFrame) => void;
    onClose?: (code: number, reason: string) => void;
  }): () => void {
    this.handlers.add(handlers);
    this.stopped = false;
    // A StrictMode double-mount connects, unsubscribes and connects again in
    // the same tick; reusing the live socket avoids a spurious 4001.
    if (this.closeTimer !== null) {
      window.clearTimeout(this.closeTimer);
      this.closeTimer = null;
    }
    if (this.socket && (
      this.socket.readyState === this.webSocketImpl.OPEN
      || this.socket.readyState === this.webSocketImpl.CONNECTING
    )) {
      return () => this.unsubscribe(handlers);
    }
    this.clearRetry();
    this.open();
    return () => this.unsubscribe(handlers);
  }

  /** Drop one subscriber; the socket closes only when the last one leaves. */
  private unsubscribe(handlers: {
    onFrame: (frame: ServerFrame) => void;
    onClose?: (code: number, reason: string) => void;
  }): void {
    this.handlers.delete(handlers);
    if (this.handlers.size === 0) this.queueClose();
  }

  private queueClose(): void {
    this.stopped = true;
    this.clearRetry();
    if (this.closeTimer !== null) return;
    this.closeTimer = window.setTimeout(() => {
      this.closeTimer = null;
      const socket = this.socket;
      this.socket = null;
      if (socket && socket.readyState === this.webSocketImpl.OPEN) {
        socket.close();
      }
    }, 0);
  }

  send(intent: ClientIntent): void {
    const socket = this.socket;
    if (!socket || socket.readyState !== this.webSocketImpl.OPEN) return;
    socket.send(JSON.stringify(intent));
  }

  private open(): void {
    if (this.stopped || typeof this.webSocketImpl === "undefined") return;
    let socket: WebSocket;
    try {
      socket = new this.webSocketImpl(this.wsUrl);
    } catch {
      this.scheduleRetry();
      return;
    }
    this.socket = socket;

    socket.onopen = () => {
      this.attempt = 0;
      debugNote({ ws: "open" });
    };
    socket.onmessage = (event: MessageEvent) => {
      if (typeof event.data !== "string") return;
      let frame: ServerFrame;
      try {
        frame = JSON.parse(event.data) as ServerFrame;
      } catch {
        return; // a malformed frame is never allowed to crash the shell
      }
      if (frame && typeof (frame as { type?: unknown }).type === "string") {
        if (frame.type === "state") debugNote({ states: wsDebugInfo().states + 1 });
        if (frame.type === "tick") {
          const tick = frame as TickFrame;
          debugNote({
            ticks: wsDebugInfo().ticks + 1,
            lastTickAt: Date.now(),
            lastTickPos: `${tick.position.x},${tick.position.y}`,
          });
        }
        // Snapshot: a handler may subscribe/unsubscribe mid-dispatch.
        for (const handler of [...this.handlers]) handler.onFrame(frame);
      }
    };
    socket.onerror = () => {
      // The close handler owns the retry; nothing to do here.
    };
    socket.onclose = (event: CloseEvent) => {
      if (this.socket === socket) this.socket = null;
      debugNote({ ws: event.code === CLOSE_OTHER_CLIENT ? "refused" : "closed" });
      for (const handler of [...this.handlers]) {
        handler.onClose?.(event.code, event.reason ?? "");
      }
      if (event.code === CLOSE_OTHER_CLIENT) {
        this.stopped = true; // one client only: never fight for the socket
        return;
      }
      this.scheduleRetry();
    };
  }

  private scheduleRetry(): void {
    if (this.stopped || this.retryTimer !== null) return;
    const delay = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** this.attempt);
    this.attempt += 1;
    this.retryTimer = window.setTimeout(() => {
      this.retryTimer = null;
      this.open();
    }, delay);
  }

  private clearRetry(): void {
    if (this.retryTimer !== null) {
      window.clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }

  /* ------------------------------------------------------------------ */
  /* HTTP (§0.4)                                                         */
  /* ------------------------------------------------------------------ */

  private async request<T>(
    path: string,
    init: RequestInit = {},
  ): Promise<ApiResult<T>> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        headers: { "content-type": "application/json" },
        ...init,
      });
    } catch {
      return refusal("network", "error.network") as ApiResult<T>;
    }
    let body: unknown = null;
    try {
      body = await response.json();
    } catch {
      body = null;
    }
    if (body && typeof body === "object") {
      const envelope = body as ApiResult<T>;
      if (typeof envelope.ok === "boolean") return envelope;
    }
    return refusal(`http_${response.status}`, "error.request_failed") as ApiResult<T>;
  }

  private post<T>(path: string, body: unknown): Promise<ApiResult<T>> {
    return this.request<T>(path, {
      method: "POST",
      body: JSON.stringify(body ?? {}),
    });
  }

  async getState(): Promise<GameSnapshot> {
    const response = await this.request<{ state: GameSnapshot }>("/api/state");
    if (response.ok && "state" in response) return response.state;
    throw new Error("GET /api/state failed");
  }

  async getSaves(): Promise<SavesResponse> {
    const response = await this.request<SavesResponse>("/api/saves");
    if (response.ok && "saves" in response) {
      return { saves: response.saves };
    }
    throw new Error("GET /api/saves failed");
  }

  newGame(body: {
    nation_id: string;
    background_id: string;
    attr_alloc: Record<string, number>;
    skill_alloc: Record<string, number>;
  }): Promise<ApiResult> {
    return this.post("/api/new_game", body);
  }

  load(slot: number): Promise<ApiResult> {
    return this.post("/api/load", { slot });
  }

  save(slot: number): Promise<ApiResult> {
    return this.post("/api/save", { slot });
  }

  setLocale(locale: Locale): Promise<ApiResult> {
    return this.post("/api/locale", { locale });
  }

  async action<T = Record<string, unknown>>(
    facility: ActionFacility,
    verb: string,
    body?: Record<string, unknown>,
  ): Promise<ApiResult<T>> {
    return this.post<T>(`/api/${facility}/${verb}`, body ?? {});
  }

  async getView<S extends ScreenViewId>(screen: S): Promise<ViewEnvelope<S>> {
    return this.request<never>(`/api/view/${screen}`) as Promise<ViewEnvelope<S>>;
  }

  /* ------------------------------------------------------------------ */
  /* The facade — the frozen inventory routes (90-* §0.4)                */
  /* ------------------------------------------------------------------ */

  port = {
    // Entering a facility is pure client routing; the hub card's open/closed
    // gate already came from the server view.
    enter: (_facility: FacilityId) => Promise.resolve({ ok: true }) as Promise<ApiResult>,
    setSail: () => this.action("provisions", "set_sail"),
  };

  market = {
    buy: (goodId: string, qty: number) =>
      this.action("market", "buy", { good_id: goodId, qty }),
    sell: (goodId: string, qty: number) =>
      this.action("market", "sell", { good_id: goodId, qty }),
    invest: (amount: number) => this.action("market", "invest", { amount }),
  };

  provisions = {
    buy: (kind: "provisions" | "water", qty: number) =>
      this.action("provisions", "buy_supplies", { kind, qty }),
    // The frozen inventory has no per-quantity supply jettison verb; the
    // server answers the honest `unknown_action` refusal (reported in the
    // M3 record rather than invented client-side).
    jettison: (kind: "provisions" | "water", qty: number) =>
      this.action("provisions", "jettison", { kind, qty }),
    fill: () => this.action("provisions", "fill"),
    sail: () => this.action("provisions", "set_sail"),
  };

  shipyard = {
    buy: (shipTypeId: string) =>
      this.action("shipyard", "buy", { ship_type_id: shipTypeId }),
    repair: (shipIndex: number, points: number) =>
      this.action("shipyard", "repair", { index: shipIndex, points }),
    refit: (shipIndex: number, cannons: number) =>
      this.action("shipyard", "refit", { index: shipIndex, cannons }),
    sell: (shipIndex: number) =>
      this.action("shipyard", "sell", { index: shipIndex }),
    equip: (shipIndex: number, slot: string, equipmentId: string) =>
      this.action("shipyard", "equip", {
        ship_index: shipIndex,
        slot,
        equipment_id: equipmentId,
      }),
    unequip: (shipIndex: number, slot: string) =>
      this.action("shipyard", "unequip", { ship_index: shipIndex, slot }),
  };

  inn = {
    rest: (days: number) => this.action("inn", "rest", { days }),
    oddJob: () => this.action("inn", "odd_job"),
  };

  guild = {
    acceptOffer: (offerId: string) =>
      this.action("guild", "accept", { instance_id: offerId }),
    report: (discoveryId: string) =>
      this.action("guild", "report", { discovery_id: discoveryId }),
  };

  palace = {
    ceremony: () => this.action("palace", "ceremony"),
    acceptMission: () => this.action("palace", "mission"),
    buyPermit: (kind: "home" | "foreign", nationId?: string) =>
      this.action("palace", "permit", { kind, nation_id: nationId }),
    repairFleet: () => this.action("palace", "repair_fleet"),
    payBounty: (nationId: string) =>
      this.action("palace", "pay_bounty", { nation_id: nationId }),
    inform: (captainId: string) =>
      this.action("palace", "inform", { captain_id: captainId }),
    enterTournament: () => this.action("palace", "tournament_enter"),
    retire: () => this.action("palace", "retire"),
  };

  tavern = {
    hire: (qty: number) => this.action("tavern", "hire", { heads: qty }),
    fire: (qty: number) => this.action("tavern", "fire", { heads: qty }),
    fillCrew: () => this.action("tavern", "fill_crew"),
    downToMin: () => this.action("tavern", "down_to_min"),
    recruit: (officerId: string) =>
      this.action("tavern", "hire", { officer_id: officerId }),
    dismiss: (officerId: string) =>
      this.action("tavern", "dismiss", { officer_id: officerId }),
    buyRumor: (rumorId: string) =>
      this.action("tavern", "hint", { discovery_id: rumorId }),
    spar: (stake: number) => this.action("tavern", "spar", { stake }),
  };
}

export function createHttpClient(options: HttpClientOptions = {}): LiveGameClient {
  return new HttpClient(options);
}
