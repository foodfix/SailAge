/**
 * The fleet view (docs/80-UI-UX.md §4.5.1; the §4.9.1 composition) — the
 * intel window's 船队 tab and the standalone route. A scrollable column of
 * per-ship blocks (name/flagship line + promote verb, the stat lines with
 * the durability value bar, the cargo stacks with their jettison verbs)
 * over the pooled totals plate. Every number is a read of the authoritative
 * state / the content tables; every action is the frozen `fleet:*` verb.
 *
 * Missing server projection (reported): `GET /api/view/fleet_view` should
 * carry each hull's effective speed + wind factor and each stack's own
 * days-of-supply (§4.10). The screen currently renders the base hull speed,
 * the weather label and the pooled `provisions` view's days; it performs no
 * formula. Promotion and jettison are port actions (§4.4), so the whole
 * view is read-only at sea with its reason.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { ScreenId } from "./ids";
import { Button, Toast, ValueBar } from "../kit";
import { Label, StandaloneFrame, fleetAction, useFetchedView, useToastState } from "./common";
import type { ShipState } from "../state/types";
import "./FleetView.css";

const SCREEN: ScreenId = "fleet_view";
const FLEET_MAX = 5;

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

  const weather = tKey(`world.weather.${state.world.weather}`);

  const shipBlocks = state.fleet.map((ship: ShipState, index) => {
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
    return (
      <div key={`${ship.ship_type_id}_${index}`} className="fleet__ship" data-ship-index={index}>
        <div className="fleet__ship_head">
          <Label
            heading
            textValue={`${fmt("fleet.ship_n", { amount: index + 1 })} · ${shipName}${index === 0 ? ` · ${tKey("fleet.flagship")}` : ""}`}
          />
          {index > 0 ? (
            <div className="fleet__promote">
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
            </div>
          ) : null}
        </div>
        <div className="fleet__statline">
          <Label textValue={fmt("fleet.stat.durability", { current: ship.durability, max: durabilityMax })} />
          <div className="fleet__bar">
            <ValueBar
              value={ship.durability}
              max={durabilityMax}
              tier={durabilityTier(ship.durability, durabilityMax)}
            />
          </div>
          <Label
            textValue={fmt("fleet.stat.cargo", {
              used,
              capacity,
              free: Math.max(0, capacity - used),
            })}
            align="right"
          />
        </div>
        <div className="fleet__statline">
          <Label textValue={fmt("fleet.stat.crew", { crew: ship.crew, max: def?.crew_max ?? ship.crew })} />
          <Label
            textValue={fmt("fleet.stat.guns", { cannons: ship.cannons, slots: def?.armament_slots ?? ship.cannons })}
            align="right"
          />
        </div>
        <Label textValue={fmt("fleet.stat.speed", { speed, max: speed, wind: weather })} />
        <div className="fleet__statline">
          <Label
            textValue={fmt("fleet.stat.supply", {
              kind: shortKind("world.provisions", tKey),
              amount: ship.provisions,
              days: pooledDays ?? tKey("ui.not_available"),
            })}
          />
          <Label
            textValue={fmt("fleet.stat.supply", {
              kind: shortKind("world.water", tKey),
              amount: ship.water,
              days: pooledDays ?? tKey("ui.not_available"),
            })}
            align="right"
          />
        </div>
        <Label
          tone="dim"
          textValue={captain ? t(content.officerName(captain[0])) : tKey("officer.post.no_captain")}
        />
        <div className="fleet__stacks">
          {stacks.map((stack) => (
            <div key={stack.key} className="fleet__stack">
              <Label textValue={`${stack.label} × ${stack.qty}`} />
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
    <div className="fleet__body" data-screen={SCREEN}>
      <Label textKey="fleet.count" values={{ count: state.fleet.length, max: FLEET_MAX }} />
      {atPort ? null : (
        <Label textKey={reason ?? "fleet.full"} values={{ max: FLEET_MAX }} tone="warn" />
      )}
      <Label textKey="fleet.ship_header" heading />
      <div className="sa-scroll fleet__ships">
        {shipBlocks}
      </div>
      <div className="fleet__totals">
        <Label textKey="fleet.totals" heading />
        <div className="fleet__totals_line">
          <Label
            textValue={`${fmt("world.provisions", { amount: pooledProvisions })} · ${fmt("world.water", { amount: pooledWater })}`}
          />
          <div className="sa-grow" />
          <Label
            align="right"
            textValue={fmt("fleet.total_days", { days: pooledDays ?? tKey("ui.not_available") })}
          />
        </div>
        <div className="fleet__totals_line">
          <div className="sa-grow" />
          <Label align="right" textValue={fmt("world.speed", { speed: slowest })} />
        </div>
      </div>
      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );

  return embedded ? body : <StandaloneFrame className="fleet__window">{body}</StandaloneFrame>;
}
