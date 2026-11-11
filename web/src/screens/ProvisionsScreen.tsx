/**
 * S4 → S3 provisioning prompt (80-* §4.6.1) — the UW2 prepare-to-sail
 * window (80-* §4.9.1): a centered framed window with the day/crew
 * header, the two supply rows (label / − / qty / + / buy / jettison),
 * the days-of-supply bar, the cargo viewport and the stay / set-sail
 * footer.
 *
 * The supply prices (the pinned 2/1 table), the days-of-supply readout, the
 * hold maths and the set-sail gate are the server projection's
 * (`GET /api/view/provisions`, 90-* §0.4) — no rule math here.
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { ScreenId } from "./ids";
import { Button, Field, Frame, Icon, Row, Toast, ValueBar, type ValueTier } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./ProvisionsScreen.css";

const SCREEN: ScreenId = "provisions";
const MINUS = String.fromCharCode(0x2212);
const PLUS = String.fromCharCode(0x2b);

type SupplyKind = "provisions" | "water";

export function ProvisionsScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("provisions");
  const { tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [qty, setQty] = useState<Record<SupplyKind, string>>({ provisions: "5", water: "5" });

  if (!view) return <ViewFallback status={status} />;

  const adjust = (kind: SupplyKind, delta: number) => {
    const current = Number.parseInt(qty[kind], 10) || 0;
    setQty((prev) => ({ ...prev, [kind]: String(Math.max(0, current + delta)) }));
  };

  const dailyCrew = state.fleet[0];
  const crewMax = dailyCrew ? (content.shipType(dailyCrew.ship_type_id)?.crew_max ?? dailyCrew.crew) : 0;
  const tier: ValueTier =
    view.days >= view.daysGoodMin ? "good" : view.days >= view.daysWarnMin ? "warn" : "bad";

  const supplyRow = (kind: SupplyKind, labelKey: string) => {
    const supply = kind === "provisions" ? view.provisions : view.water;
    const amount = Number.parseInt(qty[kind], 10) || 0;
    return (
      <div key={kind} className="provisions__row">
        <Label
          className="provisions__row_label"
          textValue={supply.days === undefined
            ? fmt(labelKey, { amount: supply.qty })
            : `${fmt(labelKey, { amount: supply.qty })} (${fmt("port.sail.days", { days: supply.days })})`}
        />
        <Button text={MINUS} onClick={() => adjust(kind, -1)} />
        <span className="provisions__qty">
          <Field
            value={qty[kind]}
            onChange={(value) => setQty((prev) => ({ ...prev, [kind]: value }))}
            ariaLabelKey="market.qty"
            maxLength={4}
          />
        </span>
        <Button text={PLUS} onClick={() => adjust(kind, 1)} />
        <Button
          text={fmt("port.sail.buy", { qty: amount, gold: amount * supply.price })}
          kind="primary"
          onClick={() => {
            void client.provisions.buy(kind, amount);
            showToast("port.sail.fill.part", { kind: tKey(labelKey), qty: amount }, "good");
          }}
        />
        <Button
          textKey="port.sail.jettison"
          disabled={amount <= 0 || amount > supply.qty}
          onClick={() => void client.provisions.jettison(kind, amount)}
        />
      </div>
    );
  };

  return (
    <div className="sa-screen provisions" data-screen={SCREEN}>
      <div className="provisions__page sa-fill-center">
        <Frame titleKey="port.sail.prepare" className="provisions__window">
          <div className="provisions__body">
            <Label textKey="world.day_time" values={{ day: state.day, time: view.clock }} tone="dim" />
            <Label textKey="fleet.stat.crew" values={{ crew: dailyCrew?.crew ?? 0, max: crewMax }} />

            {supplyRow("provisions", "world.provisions")}
            {supplyRow("water", "world.water")}

            <Label
              textKey="fleet.stat.cargo"
              values={{ used: view.holdUsed, capacity: view.holdCapacity, free: view.holdFree }}
            />

            <div className="provisions__days">
              <Label
                className="provisions__days_label"
                textValue={view.days > 0 ? fmt("port.sail.days", { days: view.days }) : tKey("port.sail.days_zero")}
              />
              <Label
                textValue={
                  view.shortWarningDays !== undefined
                    ? fmt("port.sail.short_warning", { days: view.shortWarningDays })
                    : ""
                }
                tone="warn"
              />
              <div className="sa-grow" />
              <Button
                textKey="port.sail.fill"
                disabled={view.fillBlocked}
                onClick={() => void client.provisions.fill()}
              />
            </div>

            <div className="provisions__bar">
              <ValueBar value={Math.min(view.days, view.daysBarMax)} max={view.daysBarMax} tier={tier} />
            </div>

            {view.holdFree <= 0 ? <Label textKey="port.sail.jettison_hint" tone="dim" /> : null}

            <div className="sa-scroll provisions__cargo">
              <div className="sa-table provisions__table_cargo">
                {view.cargo.map((stack, index) => (
                  <Row
                    key={`${stack.goodId}_${index}`}
                    cols={[
                      <span className="provisions__icon">
                        <Icon id={`good_${stack.goodId}`} />
                      </span>,
                      <div className="sa-cell">
                        {fmt("fleet.stack", { name: content.goodName(stack.goodId), qty: stack.qty })}
                      </div>,
                    ]}
                  />
                ))}
              </div>
            </div>

            <div className="provisions__footer">
              <Label
                className="provisions__gate"
                textValue={view.gateReasonKey ? tKey(view.gateReasonKey) : ""}
                tone="bad"
              />
              <Button textKey="port.sail.stay" onClick={() => navigate("port")} />
              <Button
                textKey="port.set_sail"
                kind="primary"
                disabled={Boolean(view.gateReasonKey)}
                onClick={() => {
                  void client.provisions.sail();
                  navigate("world");
                }}
              />
            </div>
          </div>
        </Frame>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
