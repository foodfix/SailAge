/**
 * S5 market — the UW2 framed table window (80-* §4.9.1): a toolbar row
 * (back / title / tax badge), the goods table window and the summary side
 * plate (gold, hold, the specialty strip with its hero icon, the invest
 * footer, the captains' table and the lane intel).
 *
 * Prices, the tax badge, ownership, trend and the invest gate all come from
 * `GET /api/view/market` (90-* §0.4) — this screen performs no rule math.
 */
import { Fragment, useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { MarketGoodRow, MarketIntelRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Field, Frame, Icon, Row, Toast } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./MarketScreen.css";

const SCREEN: ScreenId = "market";

export function MarketScreen() {
  const { state, views } = useGameState();
  const { view, status } = useScreenView("market");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [qty, setQty] = useState<Record<string, string>>({});

  if (!view) return <ViewFallback status={status} />;

  const hold = views.provisions;
  const portName = t(content.portName(view.portId));
  const specialtyNames = view.specialtyGoodIds.map((id) => t(content.goodName(id))).join(", ");
  const firstRow = view.rows[0];
  const firstGood = firstRow ? content.goodName(firstRow.goodId) : content.goodName(view.specialtyGoodIds[0]);
  const freeIntelPort = view.freeIntelPortId ? content.portName(view.freeIntelPortId) : content.portName(view.portId);

  const qtyFor = (goodId: string) => qty[goodId] ?? "1";

  const trade = (kind: "buy" | "sell", row: MarketGoodRow) => {
    const amount = Number.parseInt(qtyFor(row.goodId), 10);
    if (!Number.isFinite(amount) || amount <= 0) {
      showToast("market.invalid_qty", undefined, "bad");
      return;
    }
    if (kind === "buy") void client.market.buy(row.goodId, amount);
    else void client.market.sell(row.goodId, amount);
    showToast("market.traded", { qty: amount, name: content.goodName(row.goodId) }, "good");
  };

  const trendText = (row: MarketGoodRow): string => {
    const arrow = row.profitArrow === "up" ? "\u2191" : row.profitArrow === "down" ? "\u2193" : "";
    const trend = row.trend === "up"
      ? tKey("market.stock.trend_up")
      : row.trend === "down"
        ? tKey("market.stock.trend_down")
        : "";
    return [arrow, trend].filter(Boolean).join(" ");
  };

  const intelLine = (row: MarketIntelRow): string =>
    row.free && row.destPortId
      ? fmt("market.intel.free", { port: content.portName(row.destPortId) })
      : tKey(row.roleKey);

  const investStatus = (): string => {
    switch (view.investGate.kind) {
      case "exhausted":
        return tKey("market.invest_gate.exhausted");
      case "allowance":
        return fmt("market.invest_gate.allowance", {
          invested: view.investedGold,
          cap: view.investAmount,
        });
      case "blocked":
        return fmt("market.invest_gate.blocked", {
          nation: content.nationName(view.investGate.nationId ?? state.player.nation_id),
        });
      case "no_gold":
        return tKey("market.no_gold");
      case "ok":
        return fmt("market.invested_here", {
          gold: view.investedGold,
          count: view.investedPct,
        });
    }
  };

  const intelRows = view.intel ?? [];
  const hasIntel = intelRows.length > 0;

  return (
    <div className="sa-screen market" data-screen={SCREEN}>
      <div className="market__page sa-col">
        <div className="market__header sa-plate">
          <div className="market__header_line">
            <Button textKey="ui.back" onClick={() => navigate("port")} />
            <Label textKey="market.title" values={{ port: portName }} title />
            <div className="sa-grow" />
            <Label textKey={`market.tax.badge.${view.taxBadge}`} tone="accent" />
          </div>
        </div>

        <div className="market__content sa-rowline sa-grow">
          <Frame className="market__window sa-grow" scroll>
            <div className="sa-table market__table">
              <Row
                head
                cols={[
                  <div className="sa-cell" />,
                  <div className="sa-cell">{tKey("market.good")}</div>,
                  <div className="sa-cell sa-cell--right">{tKey("market.stock.header")}</div>,
                  <div className="sa-cell">
                    {tKey("market.stock.trend")}
                    <span className="market__icon">
                      <Icon id="trend_up" />
                    </span>
                  </div>,
                  <div className="sa-cell sa-cell--right">{tKey("market.stock.marginal")}</div>,
                  <div className="sa-cell sa-cell--right">{tKey("market.you_have")}</div>,
                  <div className="sa-cell">{tKey("market.qty")}</div>,
                  <div className="sa-cell">{tKey("market.buy")}</div>,
                  <div className="sa-cell">{tKey("market.sell")}</div>,
                ]}
              />
              {view.rows.map((row, index) => (
                <Fragment key={row.goodId}>
                  <Row
                    cols={[
                      <span className="market__icon">
                        <Icon id={`good_${row.goodId}`} />
                      </span>,
                      <div className="sa-cell market__good">
                        <span className="market__badge">
                          {row.specialty ? `\u2605 ${tKey("market.specialty.badge")}` : ""}
                        </span>
                        {t(content.goodName(row.goodId))}
                      </div>,
                      <div className="sa-cell sa-cell--right">{row.stock}</div>,
                      <div className="sa-cell">{trendText(row)}</div>,
                      <div className="sa-cell sa-cell--right">
                        {`${row.buyPrice ?? row.unitPrice ?? row.marginal} / ${row.sellPrice ?? row.marginal}`}
                      </div>,
                      <div className="sa-cell sa-cell--right">{row.owned}</div>,
                      <Field
                        value={qtyFor(row.goodId)}
                        onChange={(value) => setQty((prev) => ({ ...prev, [row.goodId]: value }))}
                        ariaLabelKey="market.qty"
                        maxLength={4}
                      />,
                      <Button
                        compact
                        fill
                        kind="primary"
                        textKey="market.buy"
                        disabled={row.exclusiveLocked}
                        titleKey={row.exclusiveLocked ? "market.exclusive.locked" : undefined}
                        onClick={() => trade("buy", row)}
                      />,
                      <Button
                        compact
                        fill
                        textKey="market.sell"
                        disabled={row.owned <= 0 || row.notBought || row.exclusiveLocked}
                        titleKey={
                          row.exclusiveLocked
                            ? "market.exclusive.locked"
                            : row.notBought
                              ? "market.not_bought"
                              : undefined
                        }
                        onClick={() => trade("sell", row)}
                      />,
                    ]}
                  />
                  {row.specialty && view.rows[index + 1]?.specialty === false ? (
                    <div className="market__divider" />
                  ) : null}
                </Fragment>
              ))}
            </div>
          </Frame>

          <div className="market__aside sa-plate">
            <Label textKey="ui.gold_amount" values={{ gold: state.gold }} />
            <Label
              textKey="fleet.stat.cargo"
              values={{
                used: view.holdUsed ?? hold?.holdUsed ?? 0,
                capacity: view.holdCapacity ?? hold?.holdCapacity ?? 0,
                free: view.holdFree ?? hold?.holdFree ?? 0,
              }}
            />
            <Label textKey="market.specialty.header" values={{ names: specialtyNames }} tone="accent" />
            <div className="market__hero">
              <Icon id={`good_${view.specialtyGoodIds[0] ?? firstRow?.goodId ?? "wine"}`} />
            </div>
            <Label
              textKey="market.total.buy"
              values={{ qty: 1, name: firstGood, gold: firstRow?.buyPrice ?? firstRow?.unitPrice ?? 0 }}
              tone="dim"
            />
            <div className="market__invest">
              <Button
                textKey="market.invest"
                text={fmt("market.invest", { amount: view.investAmount })}
                kind="primary"
                disabled={view.investGate.kind !== "ok"}
                onClick={() => void client.market.invest(view.investAmount)}
              />
              <Label textValue={investStatus()} tone="dim" />
            </div>

            <div className="market__section">
              <Label textKey="captain.section.market" heading />
              <div className="sa-scroll market__section_rows">
                <div className="sa-table market__table_caps">
                  {view.captains.map((captain) => (
                    <Row
                      key={captain.id}
                      cols={[
                        <div className="sa-cell">{t(captain.name)}</div>,
                        <span className="market__icon">
                          <Icon id="role_trader" />
                        </span>,
                        <div className="sa-cell">{tKey(captain.roleKey)}</div>,
                      ]}
                    />
                  ))}
                </div>
              </div>
            </div>

            <div className="market__section">
              <Label textKey="market.intel.header" heading />
              <div className="sa-scroll market__section_rows">
                <div className="sa-table">
                  {hasIntel
                    ? intelRows.map((row) => (
                        <Row
                          key={row.captainId}
                          cols={[
                            <div className={`sa-cell${row.free ? " sa-label--accent" : ""}`}>
                              {`${t(row.name)} · ${intelLine(row)}`}
                            </div>,
                          ]}
                        />
                      ))
                    : (
                      <Row
                        cols={[
                          <div className="sa-cell">{fmt("market.intel.free", { port: freeIntelPort })}</div>,
                        ]}
                      />
                    )}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
