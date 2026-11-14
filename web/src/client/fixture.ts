/**
 * The fixture GameClient — lets the screens run standalone before M2 lands.
 * It never computes game rules: every verb is recorded and answered with the
 * §0.4 success envelope; authoritative state comes from the fixture snapshots.
 *
 * M4 adds the **sailing scenario loop** (clearly marked FIXTURE below): while
 * the `world` screen is connected, the client emits 10 Hz `tick` frames from a
 * tiny simulated clock/drift and answers `helm` / `sail_to` / `sail_trim` /
 * `wait` by moving its own fixture position. This exists only so the canvas is
 * demoable before the live WS; it is not a second simulation and implements no
 * game rule (the server's tick remains authoritative in M2).
 */
import {
  fixtureBattle,
  fixtureSailing,
  fixtureSailingSnapshot,
  fixtureState,
} from "../state/fixture";
import type { Direction8, FacilityId, GameSnapshot, Locale, SailTrim } from "../state/types";
import type {
  ApiResult,
  BattleShipFrame,
  BattleTickFrame,
  ClientIntent,
  GameClient,
  SavesResponse,
  ServerFrame,
  StateFrame,
  TickFrame,
} from "./types";

export interface RecordedAction {
  facility: string;
  verb: string;
  body?: Record<string, unknown>;
}

const ok = <T = Record<string, unknown>>(extra?: T): ApiResult<T> =>
  ({ ok: true, ...(extra ?? {}) }) as ApiResult<T>;

/* ---------------------------------------------------------------------- */
/* FIXTURE sailing loop (M4)                                               */
/*                                                                         */
/* 10 Hz cadence, a 5-simulated-minute clock per frame and one tile every  */
/* 12 frames when a helm/sail order is active. Numbers are demo values,    */
/* not game rules; the fixture exists to prove the canvas renders a live   */
/* authoritative-position stream.                                          */
/* ---------------------------------------------------------------------- */

const TICK_MS = 100;
const CLOCK_MIN_PER_TICK = 5;
const STEP_TICKS = 12;
const GRID_WIDTH = 4320;
const GRID_HEIGHT = 2160;

const STEP_DELTAS: Record<Direction8, { x: number; y: number }> = {
  N: { x: 0, y: -1 },
  NE: { x: 1, y: -1 },
  E: { x: 1, y: 0 },
  SE: { x: 1, y: 1 },
  S: { x: 0, y: 1 },
  SW: { x: -1, y: 1 },
  W: { x: -1, y: 0 },
  NW: { x: -1, y: -1 },
};

function headingOf(dx: number, dy: number): Direction8 {
  if (dx > 0 && dy < 0) return "NE";
  if (dx < 0 && dy < 0) return "NW";
  if (dx > 0 && dy > 0) return "SE";
  if (dx < 0 && dy > 0) return "SW";
  if (dx > 0) return "E";
  if (dx < 0) return "W";
  if (dy < 0) return "N";
  return "S";
}

class SailingFixture {
  position = { ...fixtureSailingSnapshot.world.position };
  day = fixtureSailingSnapshot.day;
  clockMin: number = fixtureSailing.clock_min;
  heading: Direction8 = fixtureSailingSnapshot.world.heading;
  trim: SailTrim = fixtureSailingSnapshot.world.sail_trim;
  gold = fixtureSailingSnapshot.gold;
  morale = fixtureSailingSnapshot.morale;
  currentPort: string | null = null;
  private helm: Direction8 | null = null;
  private target: { x: number; y: number } | null = null;
  private ticks = 0;
  /** Emitted when the fixture docks (the state frame the host listens for). */
  onDock: ((snapshot: GameSnapshot) => void) | null = null;

  snapshot(): GameSnapshot {
    return {
      ...fixtureSailingSnapshot,
      day: this.day,
      gold: this.gold,
      morale: this.morale,
      world: {
        ...fixtureSailingSnapshot.world,
        position: { ...this.position },
        heading: this.heading,
        sail_trim: this.trim,
      },
      current_port: this.currentPort,
    };
  }

  apply(intent: ClientIntent): void {
    switch (intent.type) {
      case "helm":
        if (intent.dir === "stop") {
          this.helm = null;
          this.target = null;
        } else {
          this.helm = intent.dir;
          this.target = null;
          this.heading = intent.dir;
        }
        return;
      case "sail_to":
        this.target = { x: intent.x, y: intent.y };
        this.helm = null;
        return;
      case "sail_trim":
        this.trim = intent.trim;
        return;
      case "wait":
        this.day += 1;
        return;
      default:
        return;
    }
  }

  tick(): TickFrame {
    this.ticks += 1;
    this.clockMin += CLOCK_MIN_PER_TICK;
    while (this.clockMin >= 1440) {
      this.clockMin -= 1440;
      this.day += 1;
    }
    if (this.ticks % STEP_TICKS === 0) this.step();
    return {
      type: "tick",
      day: this.day,
      clock_min: this.clockMin,
      position: { ...this.position },
      heading: this.heading,
      sail_trim: this.trim,
      wind_dir: fixtureSailingSnapshot.world.wind_dir,
      weather: fixtureSailingSnapshot.world.weather,
      speed: fixtureSailing.speed,
      gold: this.gold,
      morale: this.morale,
      autopilot: null,
      contact_hint: "",
    };
  }

  private step(): void {
    if (this.currentPort) return;
    let dir: Direction8 | null = this.helm;
    if (this.target) {
      const dx = this.shortestDx(this.target.x - this.position.x);
      const dy = this.target.y - this.position.y;
      if (dx === 0 && dy === 0) {
        this.target = null;
        this.helm = null;
        return;
      }
      dir = headingOf(Math.sign(dx), Math.sign(dy));
      this.heading = dir;
    }
    if (!dir) return;
    const delta = STEP_DELTAS[dir];
    this.position = {
      x: (this.position.x + delta.x + GRID_WIDTH) % GRID_WIDTH,
      y: Math.max(0, Math.min(GRID_HEIGHT - 1, this.position.y + delta.y)),
    };
    this.heading = dir;
    if (
      this.position.x === fixtureSailing.dock.x &&
      this.position.y === fixtureSailing.dock.y &&
      !this.currentPort
    ) {
      this.currentPort = fixtureSailing.dock.port_id;
      this.helm = null;
      this.target = null;
      this.onDock?.(this.snapshot());
    }
  }

  private shortestDx(dx: number): number {
    let value = dx;
    if (value > GRID_WIDTH / 2) value -= GRID_WIDTH;
    if (value < -GRID_WIDTH / 2) value += GRID_WIDTH;
    return value;
  }
}

/* ---------------------------------------------------------------------- */
/* FIXTURE battle loop (M5)                                                */
/*                                                                         */
/* A scripted presentation sequence so the S10 canvas is demoable under    */
/* `?fixture=1` without the server: ships glide along their initial        */
/* velocities, a round counter ticks, and `battle_action` intents move a   */
/* hull bar. It implements NO game rule — the live server's BattleSim      */
/* stays authoritative; numbers here are authored demo values.             */
/* ---------------------------------------------------------------------- */

const BATTLE_TICK_MS = 100;
const BATTLE_MOVE_TICKS = 4;
const BATTLE_ROUND_TICKS = 20;
const BATTLE_VOLLEY_TICKS = 30;
const BATTLE_CLOSE_CELLS = 3;
const BATTLE_BROADSIDE_DAMAGE = 25;
const BATTLE_HOOK_DAMAGE = 35;
const BATTLE_ENEMY_VOLLEY = 8;

interface FixtureBattleShipState {
  id: string;
  side: "player" | "enemy";
  kind: string;
  position: { x: number; y: number };
  velocity: { x: number; y: number };
  heading8: Direction8;
  hull: number;
  crew: number;
  alive: boolean;
}

class BattleFixture {
  ships: FixtureBattleShipState[] = fixtureBattle.ships.map((ship) => ({
    ...ship,
    position: { ...ship.position },
    velocity: { ...ship.velocity },
    alive: true,
  }));
  round = 1;
  phase = "player";
  ticks = 0;
  finished = false;
  result = "";

  reset(): void {
    this.ships = fixtureBattle.ships.map((ship) => ({
      ...ship,
      position: { ...ship.position },
      velocity: { ...ship.velocity },
      alive: true,
    }));
    this.round = 1;
    this.phase = "player";
    this.ticks = 0;
    this.finished = false;
    this.result = "";
  }

  frame(): BattleTickFrame {
    const ships: BattleShipFrame[] = this.ships.map((ship) => ({
      id: ship.id,
      side: ship.side,
      kind: ship.kind,
      position: { ...ship.position },
      velocity: { ...ship.velocity },
      heading8: ship.heading8,
      hull: ship.hull,
      crew: ship.crew,
      morale: ship.side === "player" ? 70 : 60,
      reload: {
        port: this.round - (this.round % 2 === 0 ? 0 : 1),
        starboard: this.round - 1,
      },
    }));
    return {
      type: "battle_tick",
      round: this.round,
      phase: this.finished ? "over" : this.phase,
      ships,
      wind: { ...fixtureBattle.wind },
      weather: fixtureBattle.weather,
      orders_due: !this.finished && this.phase === "player",
      // The 2026-11-14 §0.3 amendment (the fixture reproduces the shape).
      acting_id: this.finished ? "" : (this.phase === "player"
        ? (ships.find((ship) => ship.side === "player")?.id ?? "")
        : (ships.find((ship) => ship.side === "enemy")?.id ?? "")),
      move_range: [],
    };
  }

  tick(): BattleTickFrame {
    if (!this.finished) {
      this.ticks += 1;
      if (this.ticks % BATTLE_ROUND_TICKS === 0) {
        this.round += 1;
        this.phase = this.round % 2 === 0 ? "enemy" : "player";
      }
      if (this.ticks % BATTLE_MOVE_TICKS === 0) this.advance();
      if (this.ticks % BATTLE_VOLLEY_TICKS === 0) this.enemyVolley();
    }
    return this.frame();
  }

  private advance(): void {
    const livingPlayers = this.ships.filter((ship) => ship.side === "player" && ship.alive);
    const livingEnemies = this.ships.filter((ship) => ship.side === "enemy" && ship.alive);
    if (livingPlayers.length === 0 || livingEnemies.length === 0) return;
    let closest = Number.POSITIVE_INFINITY;
    for (const player of livingPlayers) {
      for (const enemy of livingEnemies) {
        closest = Math.min(
          closest,
          Math.max(
            Math.abs(player.position.x - enemy.position.x),
            Math.abs(player.position.y - enemy.position.y),
          ),
        );
      }
    }
    if (closest <= BATTLE_CLOSE_CELLS) return;
    for (const ship of [...livingPlayers, ...livingEnemies]) {
      ship.position = {
        x: Math.max(0, Math.min(47, ship.position.x + ship.velocity.x)),
        y: Math.max(0, Math.min(29, ship.position.y + ship.velocity.y)),
      };
    }
  }

  private enemyVolley(): void {
    const player = this.ships.find((ship) => ship.side === "player" && ship.alive);
    if (!player) return;
    player.hull = Math.max(1, player.hull - BATTLE_ENEMY_VOLLEY);
  }

  private nearestEnemy(from: FixtureBattleShipState): FixtureBattleShipState | null {
    let best: FixtureBattleShipState | null = null;
    let distance = Number.POSITIVE_INFINITY;
    for (const ship of this.ships) {
      if (ship.side !== "enemy" || !ship.alive) continue;
      const value = Math.max(
        Math.abs(ship.position.x - from.position.x),
        Math.abs(ship.position.y - from.position.y),
      );
      if (value < distance) {
        distance = value;
        best = ship;
      }
    }
    return best;
  }

  /** Applies one intent; returns true when the battle just finished. */
  apply(intent: ClientIntent): boolean {
    if (this.finished) {
      if (intent.type === "battle_action") this.reset();
      return false;
    }
    if (intent.type === "battle_action") {
      if (intent.verb === "retreat" || intent.verb === "surrender") {
        this.finished = true;
        this.result = intent.verb;
        return true;
      }
      if (intent.verb === "hold") {
        // The pure-move verb: no volley — the loop advances the round.
        return false;
      }
      const player = this.ships.find((ship) => ship.side === "player" && ship.alive);
      if (!player) return false;
      const target = this.nearestEnemy(player);
      if (!target) return false;
      target.hull = Math.max(
        0,
        target.hull - (intent.verb === "hook" ? BATTLE_HOOK_DAMAGE : BATTLE_BROADSIDE_DAMAGE),
      );
      target.alive = target.hull > 0;
      if (!this.ships.some((ship) => ship.side === "enemy" && ship.alive)) {
        this.finished = true;
        this.result = "victory";
        return true;
      }
    }
    return false;
  }
}

export class FixtureGameClient implements GameClient {
  readonly transport = "fixture" as const;

  /** Every HTTP action the screens dispatched (debug/tests). */
  readonly actions: RecordedAction[] = [];
  /** Every WS intent the screens dispatched (debug/tests). */
  readonly intents: ClientIntent[] = [];
  /** FIXTURE sailing state (see the class comment above). */
  readonly sailing = new SailingFixture();
  /** FIXTURE battle state (see the class comment above). */
  readonly battle = new BattleFixture();
  /** Frames emitted so far (debug/tests). */
  tickFrames = 0;
  battleTickFrames = 0;

  private handlers = new Set<(frame: ServerFrame) => void>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private battleTimer: ReturnType<typeof setInterval> | null = null;

  connect(handlers: {
    onFrame: (frame: ServerFrame) => void;
    onClose?: (code: number, reason: string) => void;
  }): () => void {
    this.handlers.add(handlers.onFrame);
    const current = this.sailing.snapshot();
    const hello: ServerFrame = {
      type: "hello",
      save_version: 1,
      tick_hz: 10,
      broadcast_hz: 10,
      locale: current.locale,
      has_run: true,
      current_screen: "world",
      saves: [
        {
          slot: 1,
          day: current.day,
          nation_id: current.player.nation_id,
          port_id: fixtureSailing.dock.port_id,
          gold: current.gold,
          saved_at: current.saved_at,
        },
      ],
    };
    const state: StateFrame = { ...current, type: "state" };
    const battleTick = this.battle.frame();
    queueMicrotask(() => {
      if (!this.handlers.has(handlers.onFrame)) return;
      handlers.onFrame(hello);
      handlers.onFrame(state);
      handlers.onFrame(battleTick);
    });

    this.sailing.onDock = (snapshot) => {
      const frame: StateFrame = { ...snapshot, type: "state" };
      for (const handler of this.handlers) handler(frame);
    };
    if (!this.timer) {
      this.timer = setInterval(() => this.emitTick(), TICK_MS);
    }
    if (!this.battleTimer) {
      this.battleTimer = setInterval(() => this.emitBattleTick(), BATTLE_TICK_MS);
    }
    return () => {
      this.handlers.delete(handlers.onFrame);
      if (this.handlers.size === 0 && this.timer) {
        clearInterval(this.timer);
        this.timer = null;
      }
      if (this.handlers.size === 0 && this.battleTimer) {
        clearInterval(this.battleTimer);
        this.battleTimer = null;
      }
    };
  }

  private emitTick(): void {
    if (this.handlers.size === 0) return;
    const frame = this.sailing.tick();
    this.tickFrames += 1;
    for (const handler of this.handlers) handler(frame);
  }

  private emitBattleTick(): void {
    if (this.handlers.size === 0) return;
    const frame = this.battle.tick();
    this.battleTickFrames += 1;
    for (const handler of this.handlers) handler(frame);
  }

  send(intent: ClientIntent): void {
    this.intents.push(intent);
    this.sailing.apply(intent);
    const finished = this.battle.apply(intent);
    if (finished) {
      const outcome =
        this.battle.result === "victory"
          ? { ...fixtureBattle.outcome }
          : {
              ...fixtureBattle.outcome,
              result: this.battle.result,
              rounds: this.battle.round,
              salvage_gold: 0,
              xp: 0,
              sunk_enemy: [],
              captured_enemy: [],
              surrendered_enemy: 0,
              sunk_player: [],
              lost_player: [],
              cargo_overflow_lost: 0,
              rep_deltas: {},
              morale_delta: 0,
            };
      const event: ServerFrame = {
        type: "event",
        name: "battle_finished",
        args: {
          encounter_id: fixtureBattle.encounter_id,
          result: this.battle.result,
          outcome,
        },
      };
      for (const handler of this.handlers) handler(event);
    }
  }

  async getState(): Promise<GameSnapshot> {
    return this.sailing.snapshot();
  }

  async getSaves(): Promise<SavesResponse> {
    return {
      saves: [
        {
          slot: 1,
          day: this.sailing.day,
          nation_id: fixtureState.player.nation_id,
          port_id: fixtureSailing.dock.port_id,
          gold: this.sailing.gold,
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