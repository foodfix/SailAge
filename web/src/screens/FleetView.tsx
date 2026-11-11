/**
 * The fleet view (docs/80-UI-UX.md §4.5.1) — the intel window's 船队 tab and
 * the retired S15 body. Every number is a read of the authoritative state /
 * the content tables; every action is the frozen `fleet:*` verb.
 *
 * Missing server projection (reported): `GET /api/view/fleet_view` should
 * carry each hull's effective speed + wind factor and each stack's own
 * days-of-supply (§4.10). The screen currently renders the base hull speed,
 * the weather label and the pooled `provisions` view's days; it performs no
 * formula. Promotion and jettison are port actions (§4.4), so the whole view
 * is read-only at sea with its reason.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Box, Element, type ScreenId } from "../layout";
import { Button, Toast, ValueBar } from "../kit";
import {
  fleetAction,
  LabelEl,
  StandaloneFrame,
  useFetchedView,
  useToastState,
} from "./common";
import type { ShipState } from "../state/types";

const SCREEN: ScreenId = "fleet_view";
const FLEET_MAX = 5;
const ROW_TILES = 7;

function shortKind(key: "world.provisions" | "world.water", tKey: (key: string) => string): string {
  return tKey(key).replace("{amount}", "").trim();
}

function durabilityTier(value: number, max: number): "good" | "warn" | "bad" {
  const ratio = max > 0 ? value / max : 0;
  if (ratio > 0.6) return "good";
  if (ratio > 0.25) return "warn";
  return "bad";
}

export function FleetView({ embedded = false }: { embedded?: boolean }) {
  const { state } = useGameState();
  const { view: provisions } = useFetchedView("provisions");
  const client = useGameClient();
  const { t, tKey, fmt } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const atPort = state.current_port !== null;
  const reason = atPort ? undefined : "fleet.port_only";
  const pooledDays = provisions?.days;

  const jettison = (
    shipIndex: number,
    shipName: string,
    kind: "provisions" | "water" | "cargo",
    goodId: string,
    qty: number,
  ) => {
    const good = kind === "cargo" ? t(content.goodName(goodId)) : shortKind(
      kind === "provisions" ? "world.provisions" : "world.water",
      tKey,
    );
    const message = fmt("fleet.jettison.confirm", { ship: shipName, good, qty });
    if (typeof window !== "undefined" && !window.confirm(message)) return;
    void fleetAction(client, "jettison", {
      ship_index: shipIndex,
      ...(kind === "cargo" ? { good_id: goodId } : { kind }),
    }).then((result) => {
      if (!result.ok) showToast(result.error.msg, undefined, "bad");
      else showToast("fleet.jettison", { qty }, "good");
    });
  };

  const shipRows = state.fleet.map((ship: ShipState, index) => {
    const def = content.shipType(ship.ship_type_id);
    const shipName = t(content.shipName(ship.ship_type_id));
    const captain = Object.entries(state.officer_states).find(
      ([, row]) => row.post_id === "captain" && row.ship_id === ship.ship_type_id,
    );
    const stacks: { key: string; label: string; kind: "provisions" | "water" | "cargo"; goodId?: string; qty: number }[] = [
      { key: "provisions", label: shortKind("world.provisions", tKey), kind: "provisions", qty: ship.provisions },
      { key: "water", label: shortKind("world.water", tKey), kind: "water", qty: ship.water },
      ...Object.entries(ship.cargo)
        .filter(([, qty]) => qty > 0)
        .map(([goodId, qty]) => ({
          key: `good_${goodId}`,
          label: t(content.goodName(goodId)),
          kind: "cargo" as const,
          goodId,
          qty,
        })),
    ];
    const capacity = def?.capacity ?? 0;
    const used = Object.values(ship.cargo).reduce((a, b) => a + b, 0);
    const durabilityMax = def?.durability ?? ship.durability;
    const speed = def?.speed ?? 0;
    const weather = tKey(`world.weather.${state.world.weather}`);
    return (
      <div key={`${ship.ship_type_id}_${index}`} data-ship-index={index}>
        <Box rect={{ x: 0, y: 0, w: 22, h: 1 }}>
          <div className="sa-cell sa-label--heading">
            {`${fmt("fleet.ship_n", { amount: index + 1 })} · ${shipName}${index === 0 ? ` · ${tKey("fleet.flagship")}` : ""}`}
          </div>
        </Box>
        {index > 0 ? (
          <Box rect={{ x: 26, y: 0, w: 6, h: 1 }}>
            <Button
              textKey="fleet.promote"
              disabled={!atPort}
              titleKey={reason}
              fill
              onClick={() => {
                void fleetAction(client, "promote", { index }).then((result) => {
                  if (!result.ok) showToast(result.error.msg, undefined, "bad");
                });
              }}
            />
          </Box>
        ) : null}
        <Box rect={{ x: 0, y: 1, w: 32, h: 1 }}>
          <div className="sa-row">
            <div className="sa-row__cell">
              <span className="sa-cell">
                {fmt("fleet.stat.durability", { current: ship.durability, max: durabilityMax })}
              </span>
            </div>
            <div className="sa-row__cell">
              <ValueBar
                value={ship.durability}
                max={durabilityMax}
                tier={durabilityTier(ship.durability, durabilityMax)}
              />
            </div>
            <div className="sa-row__cell">
              <span className="sa-cell">
                {fmt("fleet.stat.cargo", {
                  used,
                  capacity,
                  free: Math.max(0, capacity - used),
                })}
              </span>
            </div>
          </div>
        </Box>
        <Box rect={{ x: 0, y: 2, w: 32, h: 1 }}>
          <div className="sa-row">
            <div className="sa-row__cell">
              <span className="sa-cell">
                {fmt("fleet.stat.crew", { crew: ship.crew, max: def?.crew_max ?? ship.crew })}
              </span>
            </div>
            <div className="sa-row__cell">
              <span className="sa-cell">
                {fmt("fleet.stat.guns", { cannons: ship.cannons, slots: def?.armament_slots ?? ship.cannons })}
              </span>
            </div>
          </div>
        </Box>
        <Box rect={{ x: 0, y: 3, w: 32, h: 1 }}>
          <span className="sa-cell">
            {fmt("fleet.stat.speed", { speed, max: speed, wind: weather })}
          </span>
        </Box>
        <Box rect={{ x: 0, y: 4, w: 32, h: 1 }}>
          <div className="sa-row">
            <div className="sa-row__cell">
              <span className="sa-cell">
                {fmt("fleet.stat.supply", {
                  kind: shortKind("world.provisions", tKey),
                  amount: ship.provisions,
                  days: pooledDays ?? tKey("ui.not_available"),
                })}
              </span>
            </div>
            <div className="sa-row__cell">
              <span className="sa-cell">
                {fmt("fleet.stat.supply", {
                  kind: shortKind("world.water", tKey),
                  amount: ship.water,
                  days: pooledDays ?? tKey("ui.not_available"),
                })}
              </span>
            </div>
          </div>
        </Box>
        <Box rect={{ x: 0, y: 5, w: 32, h: 1 }}>
          <span className="sa-cell sa-label--dim">
            {captain
              ? t(content.officerName(captain[0]))
              : tKey("officer.post.no_captain")}
          </span>
        </Box>
        <Box rect={{ x: 0, y: 6, w: 32, h: 1 }}>
          <div className="sa-row">
            {stacks.map((stack) => (
              <div className="sa-row__cell" key={stack.key}>
                <span className="sa-cell">{`${stack.label} × ${stack.qty}`}</span>
                <Button
                  textKey="fleet.jettison"
                  kind="quiet"
                  disabled={!atPort || stack.qty <= 0}
                  titleKey={reason}
                  fill
                  onClick={() =>
                    jettison(index, shipName, stack.kind, stack.goodId ?? "", stack.qty)
                  }
                />
              </div>
            ))}
          </div>
        </Box>
      </div>
    );
  });

  const pooledProvisions = state.fleet.reduce((sum, ship) => sum + ship.provisions, 0);
  const pooledWater = state.fleet.reduce((sum, ship) => sum + ship.water, 0);
  const slowest = state.fleet.reduce((speed, ship) => {
    const value = content.shipType(ship.ship_type_id)?.speed ?? 0;
    return speed === 0 ? value : Math.min(speed, value);
  }, 0);

  const body = (
    <>
      <LabelEl
        screen={SCREEN}
        id="summary"
        textKey="fleet.count"
        values={{ count: state.fleet.length, max: FLEET_MAX }}
      />
      <LabelEl
        screen={SCREEN}
        id="mode_note"
        textKey={reason ?? "fleet.full"}
        values={{ max: FLEET_MAX }}
        tone="warn"
        hidden={atPort}
      />
      <LabelEl screen={SCREEN} id="ships_header" textKey="fleet.ship_header" heading />
      <Element screen={SCREEN} id="ships_viewport" className="sa-scroll">
        <Element screen={SCREEN} id="ships" parent="ships_viewport" hidden />
        {shipRows.map((row, index) => (
          <Box key={index} rect={{ x: 0, y: index * ROW_TILES, w: 32, h: ROW_TILES }}>
            {row}
          </Box>
        ))}
      </Element>
      <Element screen={SCREEN} id="totals">
        <Box rect={{ x: 1, y: 0, w: 30, h: 1 }}>
          <div className="sa-cell sa-label--heading">{tKey("fleet.totals")}</div>
        </Box>
        <Box rect={{ x: 1, y: 1, w: 20, h: 1 }}>
          <span className="sa-cell">
            {`${fmt("world.provisions", { amount: pooledProvisions })} · ${fmt("world.water", { amount: pooledWater })}`}
          </span>
        </Box>
        <Box rect={{ x: 20, y: 1, w: 11, h: 1 }}>
          <span className="sa-cell sa-label--right">
            {fmt("fleet.total_days", { days: pooledDays ?? tKey("ui.not_available") })}
          </span>
        </Box>
        <Box rect={{ x: 20, y: 2, w: 11, h: 1 }}>
          <span className="sa-cell sa-label--right">
            {fmt("world.speed", { speed: slowest })}
          </span>
        </Box>
      </Element>
      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );

  return embedded ? body : <StandaloneFrame>{body}</StandaloneFrame>;
}
