/**
 * S4 → S3 provisioning prompt (80-* §4.6.1). Every `provisions` element
 * row is rendered; the `stacks` list block drives the cargo viewport.
 *
 * The supply prices (the pinned 2/1 table), the days-of-supply readout, the
 * hold maths and the set-sail gate are the server projection's
 * (`GET /api/view/provisions`, 90-* §0.4) — no rule math here.
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Field, Icon, Toast, ValueBar, type ValueTier } from "../kit";
import {
  ButtonEl,
  LabelEl,
  PanelEl,
  useScreenView,
  useToastState,
  ViewFallback,
} from "./common";
import { navigate } from "../app/router";

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

  if (!view) return <ViewFallback screen={SCREEN} status={status} elementId="dim" />;

  const adjust = (kind: SupplyKind, delta: number) => {
    const current = Number.parseInt(qty[kind], 10) || 0;
    setQty((prev) => ({ ...prev, [kind]: String(Math.max(0, current + delta)) }));
  };

  const dailyCrew = state.fleet[0];
  const crewMax = dailyCrew ? (content.shipType(dailyCrew.ship_type_id)?.crew_max ?? dailyCrew.crew) : 0;
  const tier: ValueTier =
    view.days >= view.daysGoodMin ? "good" : view.days >= view.daysWarnMin ? "warn" : "bad";

  const supplyRow = (
    kind: SupplyKind,
    ids: {
      row: string;
      label: string;
      minus: string;
      qty: string;
      plus: string;
      buy: string;
      jettison: string;
    },
  ) => {
    const rowId = ids.row;
    const supply = kind === "provisions" ? view.provisions : view.water;
    const labelKey = kind === "provisions" ? "world.provisions" : "world.water";
    const amount = Number.parseInt(qty[kind], 10) || 0;
    const label = supply.days !== undefined
      ? `${fmt(labelKey, { amount: supply.qty })} (${fmt("port.sail.days", { days: supply.days })})`
      : fmt(labelKey, { amount: supply.qty });
    return (
      <Element key={kind} screen={SCREEN} id={rowId} parent="rows">
        <LabelEl
          screen={SCREEN}
          id={ids.label}
          parent={rowId}
          textValue={supply.days === undefined ? fmt(labelKey, { amount: supply.qty }) : label}
        />
        <ButtonEl
          screen={SCREEN}
          id={ids.minus}
          parent={rowId}
          text={MINUS}
          onClick={() => adjust(kind, -1)}
        />
        <Element screen={SCREEN} id={ids.qty} parent={rowId}>
          <Field
            value={qty[kind]}
            onChange={(value) => setQty((prev) => ({ ...prev, [kind]: value }))}
            ariaLabelKey="market.qty"
            maxLength={4}
          />
        </Element>
        <ButtonEl
          screen={SCREEN}
          id={ids.plus}
          parent={rowId}
          text={PLUS}
          onClick={() => adjust(kind, 1)}
        />
        <ButtonEl
          screen={SCREEN}
          id={ids.buy}
          parent={rowId}
          text={fmt("port.sail.buy", { qty: amount, gold: amount * supply.price })}
          kind="primary"
          onClick={() => {
            void client.provisions.buy(kind, amount);
            showToast("port.sail.fill.part", { kind: tKey(labelKey), qty: amount }, "good");
          }}
        />
        <ButtonEl
          screen={SCREEN}
          id={ids.jettison}
          parent={rowId}
          textKey="port.sail.jettison"
          disabled={amount <= 0 || amount > supply.qty}
          onClick={() => void client.provisions.jettison(kind, amount)}
        />
      </Element>
    );
  };

  return (
    <>
      <Element screen={SCREEN} id="dim" className="sa-dim" />

      <PanelEl screen={SCREEN} id="panel">
        <LabelEl screen={SCREEN} id="title" parent="panel" textKey="port.sail.prepare" title />
        <LabelEl
          screen={SCREEN}
          id="header"
          parent="panel"
          textKey="world.day_time"
          values={{ day: state.day, time: view.clock }}
          tone="dim"
        />

        <Element screen={SCREEN} id="table" parent="panel">
          <LabelEl
            screen={SCREEN}
            id="crew"
            parent="table"
            textKey="fleet.stat.crew"
            values={{ crew: dailyCrew?.crew ?? 0, max: crewMax }}
          />
          <Element screen={SCREEN} id="rows" parent="table">
            {supplyRow("provisions", {
              row: "rows.provisions",
              label: "rows.provisions.label",
              minus: "rows.provisions.minus",
              qty: "rows.provisions.qty",
              plus: "rows.provisions.plus",
              buy: "rows.provisions.buy",
              jettison: "rows.provisions.jettison",
            })}
            {supplyRow("water", {
              row: "rows.water",
              label: "rows.water.label",
              minus: "rows.water.minus",
              qty: "rows.water.qty",
              plus: "rows.water.plus",
              buy: "rows.water.buy",
              jettison: "rows.water.jettison",
            })}
          </Element>
          <LabelEl
            screen={SCREEN}
            id="hold"
            parent="table"
            textKey="fleet.stat.cargo"
            values={{ used: view.holdUsed, capacity: view.holdCapacity, free: view.holdFree }}
          />
        </Element>

        <Element screen={SCREEN} id="days_row" parent="panel">
          <LabelEl
            screen={SCREEN}
            id="days_row.days"
            parent="days_row"
            textValue={view.days > 0 ? fmt("port.sail.days", { days: view.days }) : tKey("port.sail.days_zero")}
          />
          <LabelEl
            screen={SCREEN}
            id="days_row.short"
            parent="days_row"
            textValue={
              view.shortWarningDays !== undefined
                ? fmt("port.sail.short_warning", { days: view.shortWarningDays })
                : ""
            }
            tone="warn"
          />
          <ButtonEl
            screen={SCREEN}
            id="days_row.fill"
            parent="days_row"
            textKey="port.sail.fill"
            disabled={view.fillBlocked}
            onClick={() => void client.provisions.fill()}
          />
        </Element>

        <Element screen={SCREEN} id="days_bar" parent="panel">
          <ValueBar value={Math.min(view.days, view.daysBarMax)} max={view.daysBarMax} tier={tier} />
        </Element>

        {view.holdFree <= 0 ? (
          <LabelEl screen={SCREEN} id="hint" parent="panel" textKey="port.sail.jettison_hint" tone="dim" />
        ) : null}

        <Element screen={SCREEN} id="cargo" parent="panel">
          <Element screen={SCREEN} id="cargo.scroll" parent="cargo" className="sa-scroll">
            <ListRows
              screen={SCREEN}
              listId="stacks"
              count={view.cargo.length}
              renderRow={(index) => {
                const stack = view.cargo[index];
                return (
                  <>
                    <Box rect={{ x: 0, y: 0, w: 2, h: 1 }}>
                      <Icon id={`good_${stack.goodId}`} />
                    </Box>
                    <Box rect={{ x: 2, y: 0, w: 21, h: 1 }}>
                      <span className="sa-cell">
                        {fmt("fleet.stack", { name: content.goodName(stack.goodId), qty: stack.qty })}
                      </span>
                    </Box>
                  </>
                );
              }}
            />
          </Element>
        </Element>

        <Element screen={SCREEN} id="footer" parent="panel">
          <LabelEl
            screen={SCREEN}
            id="footer.gate_reason"
            parent="footer"
            textValue={view.gateReasonKey ? tKey(view.gateReasonKey) : ""}
            tone="bad"
          />
          <ButtonEl
            screen={SCREEN}
            id="footer.stay"
            parent="footer"
            textKey="port.sail.stay"
            onClick={() => navigate("port")}
          />
          <ButtonEl
            screen={SCREEN}
            id="footer.sail"
            parent="footer"
            textKey="port.set_sail"
            kind="primary"
            disabled={Boolean(view.gateReasonKey)}
            onClick={() => {
              void client.provisions.sail();
              navigate("world");
            }}
          />
        </Element>
      </PanelEl>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
