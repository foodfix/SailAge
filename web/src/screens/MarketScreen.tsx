/**
 * S5 market — header, goods table, specialty strip, captain intel and the
 * investment footer. Every `market` element row from data/ui_layout.json is
 * rendered; dynamic rows come from the `rows` / `captains` / `intel` list
 * blocks (10-* §4.23).
 *
 * Prices, the tax badge, ownership, trend and the invest gate all come from
 * `GET /api/view/market` (90-* §0.4) — this screen performs no rule math.
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { MarketGoodRow } from "../state/views";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Field, Icon, Toast } from "../kit";
import {
  ButtonEl,
  IconBox,
  LabelEl,
  PanelEl,
  useScreenView,
  useToastState,
  ViewFallback,
} from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "market";

const COL = {
  good: { x: 2, y: 0, w: 6, h: 2 },
  stock: { x: 8, y: 0, w: 2, h: 2 },
  trend: { x: 10, y: 0, w: 4, h: 2 },
  marginal: { x: 14, y: 0, w: 6, h: 2 },
  owned: { x: 20, y: 0, w: 2, h: 2 },
  qty: { x: 22, y: 0, w: 6, h: 2 },
  buy: { x: 32, y: 0, w: 3, h: 2 },
  sell: { x: 35, y: 0, w: 3, h: 2 },
} as const;

export function MarketScreen() {
  const { state, views } = useGameState();
  const { view, status } = useScreenView("market");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [qty, setQty] = useState<Record<string, string>>({});

  if (!view) return <ViewFallback screen={SCREEN} status={status} />;

  const hold = views.provisions;
  const portName = t(content.portName(view.portId));  const specialtyNames = view.specialtyGoodIds.map((id) => t(content.goodName(id))).join(", ");
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
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <LabelEl
          screen={SCREEN}
          id="header.title"
          parent="header"
          textKey="market.title"
          values={{ port: portName }}
          title
        />
        <LabelEl
          screen={SCREEN}
          id="header.gold"
          parent="header"
          textKey="ui.gold_amount"
          values={{ gold: state.gold }}
          align="right"
        />
        <LabelEl
          screen={SCREEN}
          id="header.hold"
          parent="header"
          textKey="fleet.stat.cargo"
          values={{
            used: view.holdUsed ?? hold?.holdUsed ?? 0,
            capacity: view.holdCapacity ?? hold?.holdCapacity ?? 0,
            free: view.holdFree ?? hold?.holdFree ?? 0,
          }}
          align="right"
        />
        <LabelEl
          screen={SCREEN}
          id="header.tax_badge"
          parent="header"
          textKey={`market.tax.badge.${view.taxBadge}`}
          tone="accent"
          align="right"
        />
        <ButtonEl
          screen={SCREEN}
          id="header.back"
          parent="header"
          textKey="ui.back"
          onClick={() => navigate("port")}
        />
      </Element>

      <PanelEl screen={SCREEN} id="table_frame">
        <Element screen={SCREEN} id="table" parent="table_frame">
          <Element screen={SCREEN} id="column_header" parent="table">
            <LabelEl screen={SCREEN} id="column_header.good" parent="column_header" textKey="market.good" heading />
            <LabelEl screen={SCREEN} id="column_header.stock" parent="column_header" textKey="market.stock.header" />
            <LabelEl screen={SCREEN} id="column_header.trend" parent="column_header" textKey="market.stock.trend" />
            <Element screen={SCREEN} id="column_header.arrows" parent="column_header">
              <Icon id="trend_up" />
            </Element>
            <LabelEl
              screen={SCREEN}
              id="column_header.marginal"
              parent="column_header"
              textKey="market.stock.marginal"
            />
            <LabelEl
              screen={SCREEN}
              id="column_header.you_have"
              parent="column_header"
              textKey="market.you_have"
            />
            <LabelEl screen={SCREEN} id="column_header.qty" parent="column_header" textKey="market.qty" />
            <LabelEl screen={SCREEN} id="column_header.buy" parent="column_header" textKey="market.buy" />
            <LabelEl screen={SCREEN} id="column_header.sell" parent="column_header" textKey="market.sell" />
          </Element>

          <LabelEl
            screen={SCREEN}
            id="specialty_header"
            parent="table"
            textKey="market.specialty.header"
            values={{ names: specialtyNames }}
            tone="accent"
          />

          <Element screen={SCREEN} id="goods_scroll" parent="table" className="sa-scroll">
            <ListRows
              screen={SCREEN}
              listId="rows"
              count={view.rows.length}
              renderRow={(index) => {
                const row = view.rows[index];
                return (
                  <>
                    <IconBox rect={{ x: 0, y: 0, w: 2, h: 2 }} id={`good_${row.goodId}`} />
                    <Box rect={COL.good}>
                      <span className="sa-cell">{t(content.goodName(row.goodId))}</span>
                    </Box>
                    <Box rect={COL.stock}>
                      <span className="sa-cell">{row.stock}</span>
                    </Box>
                    <Box rect={COL.trend}>
                      <span className="sa-cell">{trendText(row)}</span>
                    </Box>
                    <Box rect={COL.marginal}>
                      <span className="sa-cell">
                        {`${row.buyPrice ?? row.unitPrice ?? row.marginal} / ${row.sellPrice ?? row.marginal}`}
                      </span>
                    </Box>
                    <Box rect={COL.owned}>
                      <span className="sa-cell">{row.owned}</span>
                    </Box>
                    <Box rect={COL.qty}>
                      <Field
                        value={qtyFor(row.goodId)}
                        onChange={(value) => setQty((prev) => ({ ...prev, [row.goodId]: value }))}
                        ariaLabelKey="market.qty"
                        maxLength={4}
                      />
                    </Box>
                    <Box rect={COL.buy}>
                      <button
                        type="button"
                        className="sa-button sa-button--primary sa-button--fill"
                        disabled={row.exclusiveLocked || row.notBought}
                        onClick={() => trade("buy", row)}
                      >
                        <span className="sa-button__label">{tKey("market.buy")}</span>
                      </button>
                    </Box>
                    <Box rect={COL.sell}>
                      <button
                        type="button"
                        className="sa-button sa-button--fill"
                        disabled={row.owned <= 0 || row.notBought}
                        title={row.notBought ? tKey("market.not_bought") : undefined}
                        onClick={() => trade("sell", row)}
                      >
                        <span className="sa-button__label">{tKey("market.sell")}</span>
                      </button>
                    </Box>
                  </>
                );
              }}
            />
          </Element>

          <Element screen={SCREEN} id="hero_slot" parent="table">
            <Icon id={`good_${view.specialtyGoodIds[0] ?? firstRow?.goodId ?? "wine"}`} />
          </Element>
          <LabelEl
            screen={SCREEN}
            id="info_strip"
            parent="table"
            textKey="market.total.buy"
            values={{ qty: 1, name: firstGood, gold: firstRow?.buyPrice ?? firstRow?.unitPrice ?? 0 }}
            tone="dim"
          />
        </Element>
      </PanelEl>

      <Element screen={SCREEN} id="footer">
        <ButtonEl
          screen={SCREEN}
          id="footer.invest"
          parent="footer"
          textKey="market.invest"
          text={fmt("market.invest", { amount: view.investAmount })}
          kind="primary"
          disabled={view.investGate.kind !== "ok"}
          onClick={() => void client.market.invest(view.investAmount)}
        />
        <LabelEl
          screen={SCREEN}
          id="footer.invest_status"
          parent="footer"
          textValue={investStatus()}
          tone="dim"
        />
      </Element>

      <LabelEl screen={SCREEN} id="captains_header" textKey="captain.section.market" heading />
      <PanelEl screen={SCREEN} id="captains">
        <ListRows
          screen={SCREEN}
          listId="captains"
          count={view.captains.length}
          renderRow={(index) => {
            const captain = view.captains[index];
            return (
              <>
                <Box rect={{ x: 0, y: 0, w: 8, h: 2 }}>
                  <span className="sa-cell">{t(captain.name)}</span>
                </Box>
                <Box rect={{ x: 8, y: 0, w: 2, h: 2 }}>
                  <Icon id="role_trader" />
                </Box>
                <Box rect={{ x: 10, y: 0, w: 7, h: 2 }}>
                  <span className="sa-cell">{tKey(captain.roleKey)}</span>
                </Box>
              </>
            );
          }}
        />
      </PanelEl>

      <LabelEl screen={SCREEN} id="intel_header" textKey="market.intel.header" heading />
      <PanelEl screen={SCREEN} id="intel">
        <ListRows
          screen={SCREEN}
          listId="intel"
          count={hasIntel ? intelRows.length : 1}
          renderRow={(index) => {
            if (!hasIntel) {
              return (
                <Box rect={{ x: 0, y: 0, w: 50, h: 2 }}>
                  <span className="sa-cell">{fmt("market.intel.free", { port: freeIntelPort })}</span>
                </Box>
              );
            }
            const row = intelRows[index];
            const line = row.free && row.destPortId
              ? fmt("market.intel.free", { port: content.portName(row.destPortId) })
              : tKey(row.roleKey);
            return (
              <Box rect={{ x: 0, y: 0, w: 50, h: 2 }}>
                <span className={`sa-cell${row.free ? " sa-label--accent" : ""}`}>
                  {`${t(row.name)} · ${line}`}
                </span>
              </Box>
            );
          }}
        />
      </PanelEl>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
