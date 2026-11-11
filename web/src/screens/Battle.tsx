/**
 * S10 — the sea-battle screen (docs/80-UI-UX.md §4.7.1; docs/60-COMBAT.md
 * §4.2–§4.9c, §4.11.9/§4.11.10; the M7 kit composition per 80-* §4.9.1).
 *
 * A pure renderer over the frozen `battle_tick` stream (`90-*` §0.3): the
 * canvas draws the 48×30 world and the DOM chrome is a flow-laid stack of
 * kit atoms — the header plate (battle.title · day · round), the order
 * strip (heading / speed band / assigned target cycles + the §4.9b wind
 * chip and the side morales), the bottom HUD (speed/heading readouts, the
 * reload side pair, action verbs with their gates, the shot selector and
 * the presentation log) and the two overlays (the Esc menu and the
 * §4.12.2 after-action dialog). Every control becomes a frozen WS intent
 * (`battle_order` + `battle_action`). No rule lives here — the server owns
 * the engine; the only client arithmetic is presentation (bars, headings,
 * a Chebyshev read for the shot selector's enabled state).
 *
 * Wire-contract notes (reported, not patched):
 *  · `battle_tick` carries no acting-unit id, log stream, cannon counts,
 *    current vector or formation anchor — the canvas derives what it can
 *    (selection, reload pips, sink detection) and the log panel is a
 *    presentation log of frame observations + issued intents.
 *  · `client/types.ts`'s `BattleOrderIntent` types (string station/band)
 *    disagree with the M2 server's validator (station list/dict, heading8
 *    int, band [lo, hi]); the correct wire shape is sent through one cast.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useGameClient } from "../client/context";
import type { CannonSide, ShotType } from "../client/types";
import { content, useI18n } from "../i18n";
import type { ScreenId } from "./ids";
import { Button, Dialog, Footer, Toast } from "../kit";
import { Label } from "./common";
import {
  ARMOR_PIERCING_GATE,
  BattleCanvas,
  CHAIN_GATE,
  HEADING8,
  SPEED_BANDS,
  chebyshev,
  livingShips,
  toBattleView,
} from "../canvas/battle";
import type { BattleOrder, BattleShip, BattleView } from "../canvas/battle";
import { useGameState } from "../state/context";
import type { GameSnapshot } from "../state/types";
import { navigate } from "../app/router";
import "./Battle.css";

const SCREEN: ScreenId = "battle";

const EMPTY_VIEW: BattleView = {
  round: 0,
  phase: "none",
  ships: [],
  wind: { dir: "E", strength: 0 },
  weather: "calm",
  ordersDue: false,
};

/** The §4.12.2 outcome subset the after-action dialog renders. */
interface OutcomeSlice {
  result: string;
  rounds: number;
  salvage_gold: number;
  xp: number;
  sunk_enemy: string[];
  captured_enemy: string[];
  sunk_player: string[];
  lost_player: string[];
  cargo_overflow_lost: number;
  rep_deltas: Record<string, number>;
  morale_delta: number;
}

interface LogLine {
  key: string;
  values: Record<string, string | number>;
}

function outcomeSlice(raw: unknown): OutcomeSlice | null {
  if (!raw || typeof raw !== "object") return null;
  const block = raw as Record<string, unknown>;
  const ships = (value: unknown): string[] =>
    Array.isArray(value)
      ? value.map((entry) =>
          typeof entry === "string"
            ? entry
            : String((entry as Record<string, unknown>)?.ship_type_id ?? ""),
        )
      : [];
  return {
    result: String(block.result ?? ""),
    rounds: Number(block.rounds ?? 0),
    salvage_gold: Number(block.salvage_gold ?? 0),
    xp: Number(block.xp ?? 0),
    sunk_enemy: ships(block.sunk_enemy),
    captured_enemy: ships(block.captured_enemy),
    sunk_player: ships(block.sunk_player),
    lost_player: ships(block.lost_player),
    cargo_overflow_lost: Number(block.cargo_overflow_lost ?? 0),
    rep_deltas:
      block.rep_deltas && typeof block.rep_deltas === "object"
        ? Object.fromEntries(
            Object.entries(block.rep_deltas as Record<string, unknown>).map(([id, delta]) => [
              id,
              Number(delta),
            ]),
          )
        : {},
    morale_delta: Number(block.morale_delta ?? 0),
  };
}

function resultKey(result: string): string {
  if (result === "victory") return "battle.result.victory";
  if (result === "retreat") return "battle.result.retreat";
  if (result === "surrender") return "battle.result.surrender";
  if (result === "stall") return "battle.result.stall";
  return "battle.result.defeat";
}

export function BattleScreen() {
  const client = useGameClient();
  const { state } = useGameState();
  const { t, tKey, fmt } = useI18n();

  const [snapshot, setSnapshot] = useState<GameSnapshot>(state);
  const [view, setView] = useState<BattleView>(EMPTY_VIEW);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedSide, setSelectedSide] = useState<CannonSide>("port");
  const [selectedShot, setSelectedShot] = useState<ShotType>("round");
  const [order, setOrder] = useState<BattleOrder>({
    station: [10, 15],
    headingBucket: 0,
    speedBand: [1, 1],
    assignedTargetId: null,
    discipline: false,
  });
  const [menuOpen, setMenuOpen] = useState(false);
  const [pendingVerb, setPendingVerb] = useState<"retreat" | "surrender" | null>(null);
  const [aiInstant, setAiInstant] = useState(false);
  const [outcome, setOutcome] = useState<OutcomeSlice | null>(null);
  const [logLines, setLogLines] = useState<LogLine[]>([]);
  const [toast, setToast] = useState<string | null>(null);
  const [fitSignal, setFitSignal] = useState(0);

  const orderTouched = useRef(false);
  const previousShips = useRef<Map<string, boolean>>(new Map());
  const tRef = useRef(t);
  tRef.current = t;

  const pushLog = useCallback((line: LogLine) => {
    setLogLines((current) => [...current.slice(-2), line]);
  }, []);

  useEffect(
    () =>
      client.connect({
        onFrame: (frame) => {
          if (frame.type === "battle_tick") {
            setView(toBattleView(frame));
            // Sink detection for the presentation log (frame-observed only).
            const seen = previousShips.current;
            const dead: string[] = [];
            for (const ship of frame.ships) {
              const wasAlive = seen.get(ship.id) ?? ship.hull > 0;
              seen.set(ship.id, ship.hull > 0);
              if (wasAlive && ship.hull <= 0) dead.push(ship.kind);
            }
            for (const kind of dead) {
              pushLog({
                key: "battle.log.sunk",
                values: { ship: tRef.current(content.shipName(kind)) },
              });
            }
          } else if (frame.type === "state") {
            setSnapshot(frame);
          } else if (frame.type === "event") {
            if (frame.name === "battle_finished") {
              setOutcome(outcomeSlice(frame.args.outcome));
            } else if (frame.name === "battle_started") {
              setOutcome(null);
              setLogLines([]);
              previousShips.current.clear();
              orderTouched.current = false;
            }
          } else if (frame.type === "error") {
            setToast(frame.msg);
          }
        },
      }),
    [client, pushLog],
  );

  const ownShips = useMemo(() => livingShips(view, "player"), [view]);
  const enemyShips = useMemo(() => livingShips(view, "enemy"), [view]);
  const selected =
    view.ships.find((ship) => ship.id === selectedId && ship.alive) ?? ownShips[0] ?? null;
  const target = enemyShips.find((ship) => ship.id === order.assignedTargetId) ?? null;
  const gunnery = Number(snapshot.player.skills.gunnery ?? 0);
  const moralePlayer = ownShips[0]?.morale ?? 0;
  const moraleEnemy = enemyShips[0]?.morale ?? 0;

  // First frame: seed the order from the flagship (heading + nearest enemy).
  useEffect(() => {
    if (orderTouched.current || ownShips.length === 0) return;
    const flagship = ownShips[0];
    let nearest: BattleShip | null = null;
    let best = Number.POSITIVE_INFINITY;
    for (const enemy of enemyShips) {
      const distance = chebyshev(flagship.position, enemy.position);
      if (distance < best) {
        best = distance;
        nearest = enemy;
      }
    }
    orderTouched.current = true;
    setOrder({
      station: [flagship.position.x, flagship.position.y],
      headingBucket: flagship.headingBucket,
      speedBand: [1, 1],
      assignedTargetId: nearest?.id ?? null,
      discipline: false,
    });
  }, [ownShips, enemyShips]);

  // A dead assigned target falls through to the next living enemy (the
  // presentation retarget; the server still validates the target index).
  useEffect(() => {
    if (!order.assignedTargetId || enemyShips.length === 0) return;
    if (enemyShips.some((ship) => ship.id === order.assignedTargetId)) return;
    setOrder((current) => ({ ...current, assignedTargetId: enemyShips[0].id }));
  }, [enemyShips, order.assignedTargetId]);

  const sendOrder = useCallback(() => {
    const station: [number, number] = selected
      ? [selected.position.x, selected.position.y]
      : order.station;
    const assignedIndex = order.assignedTargetId
      ? Number.parseInt(order.assignedTargetId.split("_").pop() ?? "-1", 10)
      : -1;
    // The M2 validator wants a station list|dict, an integer heading8, a
    // [lo, hi] band and the target fleet index (§0.3/§4.9b). The frozen TS
    // intent type spells these as strings — one cast keeps the wire honest.
    client.send({
      type: "battle_order",
      station,
      desired_heading8: order.headingBucket,
      desired_speed_band: [order.speedBand[0], order.speedBand[1]],
      assigned_target: Number.isFinite(assignedIndex) ? assignedIndex : -1,
      discipline: order.discipline,
    } as unknown as Parameters<typeof client.send>[0]);
  }, [client, order, selected]);

  const act = useCallback(
    (verb: "broadside" | "hook" | "retreat" | "surrender") => {
      if (verb === "retreat" || verb === "surrender") {
        client.send({ type: "battle_action", verb });
      } else {
        sendOrder();
        client.send({
          type: "battle_action",
          verb,
          ...(verb === "broadside" ? { side: selectedSide, shot: selectedShot } : {}),
        });
      }
      pushLog({
        key:
          verb === "broadside"
            ? "battle.action.cannon"
            : verb === "hook"
              ? "battle.action.board"
              : verb === "retreat"
                ? "battle.action.retreat"
                : "battle.action.surrender",
        values: {},
      });
      setMenuOpen(false);
      setPendingVerb(null);
    },
    [client, pushLog, selectedShot, selectedSide, sendOrder],
  );

  const cycleHeading = useCallback(() => {
    orderTouched.current = true;
    setOrder((current) => ({
      ...current,
      headingBucket: (current.headingBucket + 1) % HEADING8.length,
    }));
  }, []);

  const cycleBand = useCallback(() => {
    orderTouched.current = true;
    setOrder((current) => {
      const index = SPEED_BANDS.findIndex(
        (band) => band[0] === current.speedBand[0] && band[1] === current.speedBand[1],
      );
      const next = SPEED_BANDS[(index + 1) % SPEED_BANDS.length];
      return { ...current, speedBand: [next[0], next[1]] };
    });
  }, []);

  const cycleTarget = useCallback(() => {
    orderTouched.current = true;
    setOrder((current) => {
      if (enemyShips.length === 0) return { ...current, assignedTargetId: null };
      const index = enemyShips.findIndex((ship) => ship.id === current.assignedTargetId);
      return {
        ...current,
        assignedTargetId: enemyShips[(index + 1) % enemyShips.length].id,
      };
    });
  }, [enemyShips]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const targetElement = event.target;
      if (targetElement instanceof HTMLElement) {
        const tag = targetElement.tagName.toLowerCase();
        if (tag === "input" || tag === "textarea" || targetElement.isContentEditable) return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        if (pendingVerb) setPendingVerb(null);
        else setMenuOpen((open) => !open);
        return;
      }
      if (event.key === "Tab") {
        event.preventDefault();
        if (ownShips.length === 0) return;
        const index = ownShips.findIndex((ship) => ship.id === selected?.id);
        setSelectedId(ownShips[(index + 1) % ownShips.length].id);
        return;
      }
      if (event.key === "Home") {
        event.preventDefault();
        setFitSignal((value) => value + 1);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [ownShips, pendingVerb, selected]);

  const headingToken = HEADING8[order.headingBucket];
  const shotLockedValue = (shot: ShotType): number | null => {
    if (shot === "chain") return gunnery >= CHAIN_GATE ? null : CHAIN_GATE;
    if (shot === "armor_piercing") {
      return gunnery >= ARMOR_PIERCING_GATE ? null : ARMOR_PIERCING_GATE;
    }
    return null;
  };
  const targetAdjacent = Boolean(
    selected && target && chebyshev(selected.position, target.position) === 1,
  );
  const canFire = Boolean(selected && target);
  const canHook = Boolean(selected && target && targetAdjacent);

  const afterLines: LogLine[] = [];
  if (outcome) {
    afterLines.push({ key: resultKey(outcome.result), values: {} });
    afterLines.push({ key: "battle.after.loot", values: { gold: outcome.salvage_gold } });
    afterLines.push({ key: "battle.after.xp", values: { xp: outcome.xp } });
    for (const kind of outcome.captured_enemy) {
      afterLines.push({
        key: "battle.after.captured",
        values: { ship: t(content.shipName(kind)) },
      });
    }
    for (const kind of outcome.lost_player) {
      afterLines.push({ key: "battle.after.lost", values: { ship: t(content.shipName(kind)) } });
    }
    if (outcome.cargo_overflow_lost > 0) {
      afterLines.push({
        key: "battle.after.overflow",
        values: { count: outcome.cargo_overflow_lost },
      });
    }
    for (const [nationId, delta] of Object.entries(outcome.rep_deltas)) {
      if (delta === 0) continue;
      afterLines.push({
        key: "battle.after.rep",
        values: { nation: t(content.nationName(nationId)), delta },
      });
    }
  }

  const logAt = (index: number): string => {
    const line = logLines[index];
    return line ? fmt(line.key, line.values) : "";
  };

  return (
    <div className="sa-screen battle" data-screen={SCREEN} data-battle-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />
      <div className="battle__top sa-plate">
        <div className="battle__top_names">
          <Label textKey="battle.title" title />
          <Label
            textValue={fmt("ui.day_nation_gold", {
              day: snapshot.day,
              nation: t(content.nationName(snapshot.player.nation_id)),
              gold: snapshot.gold,
            })}
          />
        </div>
        <Label
          className="battle__top_round"
          textValue={fmt("battle.round", { round: view.round })}
          tone={view.ordersDue ? "accent" : "default"}
        />
      </div>

      <div className="battle__field sa-grow">
        <BattleCanvas
          scene={{
            view,
            selectedId: selected?.id ?? null,
            targetId: order.assignedTargetId,
            aiInstant,
          }}
          fitSignal={fitSignal}
          onSelect={(id) => {
            const ship = view.ships.find((entry) => entry.id === id);
            if (!ship) return;
            if (ship.side === "player") setSelectedId(ship.id);
            else {
              orderTouched.current = true;
              setOrder((current) => ({ ...current, assignedTargetId: ship.id }));
            }
          }}
        />
      </div>

      {/* The §4.9b order strip: wind/weather chip, the heading / speed /
          target cycles and the two side morales. */}
      <div className="battle__order sa-verb-bar">
        <Label
          className="battle__order_weather"
          textValue={`${tKey(`world.weather.${view.weather}`)} · ${view.wind.dir}`}
          tone="accent"
        />
        <div className="battle__order_main">
          <Button
            text={`${tKey("battle.heading")} ${headingToken}`}
            onClick={cycleHeading}
          />
          <Button
            text={`${tKey("battle.speed")} ${order.speedBand[0]}–${order.speedBand[1]}`}
            onClick={cycleBand}
          />
          <Button
            text={target ? t(content.shipName(target.kind)) : tKey("battle.target.none")}
            onClick={cycleTarget}
          />
        </div>
        <div className="battle__order_morale">
          <Label textValue={`${tKey("battle.morale")} ${moralePlayer}`} tone="dim" />
          <Label textValue={`${tKey("battle.morale")} ${moraleEnemy}`} tone="dim" />
        </div>
      </div>

      <div className="battle__bottom sa-plate">
        <div className="battle__row">
          <Label
            textValue={
              selected
                ? `${tKey("battle.speed")} ${Math.hypot(selected.velocity.x, selected.velocity.y).toFixed(1)}`
                : tKey("battle.speed")
            }
          />
          <Label
            textValue={selected ? `${tKey("battle.heading")} ${selected.heading8}` : tKey("battle.heading")}
          />
          <Button
            textKey="battle.reload.port"
            kind={selectedSide === "port" ? "primary" : "default"}
            onClick={() => setSelectedSide("port")}
          />
          <Button
            textKey="battle.reload.starboard"
            kind={selectedSide === "starboard" ? "primary" : "default"}
            onClick={() => setSelectedSide("starboard")}
          />
          <Label textValue={`${tKey("battle.wind")} ${view.wind.dir}`} tone="accent" />
          <Label
            textValue={tKey(`world.weather.${view.weather}`)}
            tone={view.weather === "storm" ? "bad" : view.weather === "strong" ? "warn" : "accent"}
          />
          <Button textKey="battle.fit" onClick={() => setFitSignal((value) => value + 1)} />
        </div>

        <div className="battle__row">
          <Button
            text={target ? t(content.shipName(target.kind)) : tKey("battle.target.none")}
            onClick={cycleTarget}
          />
          <Button
            textKey="battle.action.cannon"
            kind="primary"
            disabled={!canFire}
            onClick={() => act("broadside")}
          />
          {/* No `ram` verb exists in the frozen §0.3 intent table — the Phase-9
              action set is broadside/hook/retreat/surrender. Rendered disabled. */}
          <Button textKey="battle.action.ram" disabled />
          <Button
            textKey="battle.action.board"
            disabled={!canHook}
            onClick={() => act("hook")}
          />
          {/* No `hold` verb either: this issues the order five-tuple only. */}
          <Button
            textKey="battle.action.hold"
            onClick={() => {
              sendOrder();
              pushLog({ key: "battle.action.hold", values: {} });
            }}
          />
        </div>

        <div className="battle__row">
          <Button
            textKey="battle.shot.round"
            kind={selectedShot === "round" ? "primary" : "default"}
            onClick={() => setSelectedShot("round")}
          />
          <Button
            text={
              shotLockedValue("chain") === null
                ? tKey("battle.shot.chain")
                : fmt("battle.shot.locked", { value: CHAIN_GATE })
            }
            kind={selectedShot === "chain" ? "primary" : "default"}
            disabled={shotLockedValue("chain") !== null}
            onClick={() => setSelectedShot("chain")}
          />
          <Button
            text={
              shotLockedValue("armor_piercing") === null
                ? tKey("battle.shot.armor_piercing")
                : fmt("battle.shot.locked", { value: ARMOR_PIERCING_GATE })
            }
            kind={selectedShot === "armor_piercing" ? "primary" : "default"}
            disabled={shotLockedValue("armor_piercing") !== null}
            onClick={() => setSelectedShot("armor_piercing")}
          />
          <Button
            textKey="battle.shot.grape"
            kind={selectedShot === "grape" ? "primary" : "default"}
            disabled={!targetAdjacent}
            onClick={() => setSelectedShot("grape")}
          />
        </div>

        <div className="battle__log">
          <Label textValue={logAt(0)} />
          <Label textValue={logAt(1)} />
          <Label textValue={logAt(2)} />
        </div>
      </div>

      {/* --- Battle menu (Esc): retreat / surrender / AI speed / back --- */}
      {menuOpen ? (
        <div className="battle__overlay">
          <div className="battle__overlay_dim sa-dim" aria-hidden="true" />
          <Dialog
            titleKey={
              pendingVerb
                ? pendingVerb === "retreat"
                  ? "battle.retreat.confirm"
                  : "battle.surrender.confirm"
                : "battle.title"
            }
            className="battle__dialog"
          >
            <div className="battle__stack">
              <Button
                textKey={pendingVerb === "retreat" ? "ui.confirm" : "battle.action.retreat"}
                kind={pendingVerb === "retreat" ? "danger" : "default"}
                onClick={() => {
                  if (pendingVerb === "retreat") act("retreat");
                  else setPendingVerb("retreat");
                }}
              />
              <Button
                textKey={pendingVerb === "surrender" ? "ui.confirm" : "battle.action.surrender"}
                kind={pendingVerb === "surrender" ? "danger" : "default"}
                onClick={() => {
                  if (pendingVerb === "surrender") act("surrender");
                  else setPendingVerb("surrender");
                }}
              />
              <Button
                textKey="battle.ai_speed.animate"
                disabled={!aiInstant}
                onClick={() => setAiInstant(false)}
              />
              <Button
                textKey="battle.ai_speed.instant"
                disabled={aiInstant}
                onClick={() => setAiInstant(true)}
              />
              <Button
                textKey={pendingVerb ? "ui.cancel" : "ui.back"}
                onClick={() => {
                  if (pendingVerb) setPendingVerb(null);
                  else setMenuOpen(false);
                }}
              />
            </div>
          </Dialog>
        </div>
      ) : null}

      {/* --- After-action dialog (§4.12.2 outcome block) --- */}
      {outcome ? (
        <div className="battle__overlay">
          <div className="battle__overlay_dim sa-dim" aria-hidden="true" />
          <Dialog titleKey="battle.after.title" className="battle__dialog">
            <div className="battle__stack">
              <div className="battle__after_lines">
                {afterLines.slice(0, 4).map((line, index) => (
                  <Label key={index} textValue={fmt(line.key, line.values)} light />
                ))}
              </div>
              <Footer
                buttons={[
                  <Button
                    key="continue"
                    textKey="ui.back"
                    kind="primary"
                    onClick={() => {
                      setOutcome(null);
                      navigate("world");
                    }}
                  />,
                ]}
              />
            </div>
          </Dialog>
        </div>
      ) : null}

      {toast ? <Toast messageKey={toast} tone="bad" onDismiss={() => setToast(null)} /> : null}
    </div>
  );
}
