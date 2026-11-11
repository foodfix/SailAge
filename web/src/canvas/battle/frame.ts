/**
 * `battle_tick` → normalized `BattleView`.
 *
 * The frozen TS type (`client/types.ts`) says `heading8: Direction8` and
 * `wind: {dir, strength}`, while the M2 server's `battle_frame()` emits the
 * §4.8.6 **bucket index** and the wind direction as a token string. The
 * renderer accepts both shapes (the wire contract note is reported, not
 * patched server-side from M5): this is presentation normalization, not a
 * rule.
 */
import { content } from "../../i18n";
import type { Direction8, Weather } from "../../state/types";
import type { BattleShip, BattleSide, BattleView, Vec2 } from "./types";
import { HEADING8 } from "./constants";

/** A heading8 in either wire shape → its §4.8.6 bucket index 0..7. */
export function headingBucket(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return ((Math.trunc(value) % HEADING8.length) + HEADING8.length) % HEADING8.length;
  }
  if (typeof value === "string") {
    const index = HEADING8.indexOf(value as Direction8);
    if (index >= 0) return index;
  }
  return 0;
}

export function headingToken(value: unknown): Direction8 {
  return HEADING8[headingBucket(value)];
}

function vec(value: unknown): Vec2 {
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    const x = Number(record.x);
    const y = Number(record.y);
    if (Number.isFinite(x) && Number.isFinite(y)) return { x, y };
  }
  return { x: 0, y: 0 };
}

function number(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function windOf(value: unknown): { dir: Direction8; strength: number } {
  if (typeof value === "string") return { dir: headingToken(value), strength: 0 };
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return {
      dir: headingToken(record.dir ?? record.direction),
      strength: number(record.strength),
    };
  }
  return { dir: "E", strength: 0 };
}

function sideOf(value: unknown): BattleSide {
  return value === "player" ? "player" : "enemy";
}

/** One frame ship → the render model (hull/crew maxima from content data). */
export function toBattleShip(raw: Record<string, unknown>): BattleShip {
  const kind = String(raw.kind ?? raw.ship_type_id ?? "");
  const type = content.shipType(kind);
  const reload = (raw.reload ?? {}) as Record<string, unknown>;
  const side = sideOf(raw.side);
  return {
    id: String(raw.id ?? `${side}_0`),
    side,
    kind,
    position: vec(raw.position),
    velocity: vec(raw.velocity),
    heading8: headingToken(raw.heading8),
    headingBucket: headingBucket(raw.heading8),
    hull: number(raw.hull),
    hullMax: number(type?.durability, 0),
    crew: number(raw.crew),
    crewMax: number(type?.crew_max, 0),
    morale: number(raw.morale),
    reload: {
      port: number(reload.port),
      starboard: number(reload.starboard),
    },
    // A destroyed hull stays in the frame (§0.3) so the canvas can show it.
    alive: raw.alive === undefined ? number(raw.hull) > 0 : Boolean(raw.alive),
  };
}

export function toBattleView(frame: {
  round?: unknown;
  phase?: unknown;
  ships?: unknown;
  wind?: unknown;
  weather?: unknown;
  orders_due?: unknown;
}): BattleView {
  const ships = Array.isArray(frame.ships)
    ? frame.ships
        .filter((entry): entry is Record<string, unknown> => Boolean(entry) && typeof entry === "object")
        .map(toBattleShip)
    : [];
  return {
    round: number(frame.round, 0),
    phase: String(frame.phase ?? "none"),
    ships,
    wind: windOf(frame.wind),
    weather: (typeof frame.weather === "string" ? frame.weather : "calm") as Weather,
    ordersDue: Boolean(frame.orders_due),
  };
}

export function livingShips(view: BattleView, side: BattleSide): BattleShip[] {
  return view.ships.filter((ship) => ship.side === side && ship.alive);
}

export function sideMorale(view: BattleView, side: BattleSide): number {
  return view.ships.find((ship) => ship.side === side)?.morale ?? 0;
}

/** Chebyshev distance in cells (presentation geometry only). */
export function chebyshev(a: Vec2, b: Vec2): number {
  return Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y));
}

/** `floor(‖vel‖)` — the §4.3a reading the arc/hook overlays use. */
export function speedOf(ship: BattleShip): number {
  return Math.floor(Math.hypot(ship.velocity.x, ship.velocity.y));
}
