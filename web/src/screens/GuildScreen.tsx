/**
 * S12 guild — the UW2 room windows (80-* §4.9.1): a toolbar row (back /
 * title / gold / fame), the commission offers window (refresh hint,
 * announce strip, tall zebra rows with the accept verb) and the discovery
 * report window.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CommissionRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Frame, Icon, Row, Toast } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./GuildScreen.css";

const SCREEN: ScreenId = "guild";

const TYPE_ICON: Record<CommissionRow["type"], string> = {
  delivery: "scroll",
  bounty: "skull",
  exploration: "compass",
  royal: "crown",
};

export function GuildScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("guild");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();

  if (!view) return <ViewFallback status={status} />;

  const portName = t(content.portName(view.portId));

  return (
    <div className="sa-screen guild" data-screen={SCREEN}>
      <div className="guild__page sa-col">
        <div className="guild__header sa-plate">
          <div className="guild__header_line">
            <Button textKey="ui.back" onClick={() => navigate("port")} />
            <Label textKey="guild.title" values={{ port: portName }} title />
            <div className="sa-grow" />
            <Label textKey="ui.gold_amount" values={{ gold: state.gold }} />
            <Label textKey="ending.fame" values={{ fame: state.fame }} />
          </div>
        </div>

        <div className="guild__content sa-rowline sa-grow">
          <Frame titleKey="guild.offers" className="guild__offers">
            <div className="guild__offers_body">
              <Label textKey="guild.offers_refresh" values={{ day: view.offersRefreshDay }} tone="dim" />
              <Label
                textValue={view.offersAnnounce ? t(view.offersAnnounce) : view.tournament ? t(view.tournament) : ""}
                tone="accent"
              />
              <div className="sa-scroll guild__offers_rows">
                <div className="sa-table">
                  {view.offers.map((offer) => (
                    <Row
                      key={offer.id}
                      height={104}
                      cols={[
                        <div className="guild__offer">
                          <div className="guild__offer_line">
                            <span className="guild__icon">
                              <Icon id={TYPE_ICON[offer.type]} />
                            </span>
                            <div className="sa-cell sa-label--heading">{tKey(`quest.type.${offer.type}`)}</div>
                            <div className="sa-cell sa-grow">{fmt(offer.lineKey, offer.lineValues)}</div>
                            <div className="sa-cell">{fmt("quest.days_left", { days: offer.daysLeft })}</div>
                          </div>
                          <div className="sa-cell sa-label--dim">
                            {fmt("quest.reward", { gold: offer.rewardGold, rep: offer.rep })}
                          </div>
                          <div className="guild__offer_line">
                            <div className="sa-cell sa-label--dim sa-grow">
                              {offer.hintText ? t(offer.hintText) : offer.hintKey ? tKey(offer.hintKey) : ""}
                            </div>
                            <Button
                              compact
                              textKey="quest.accept"
                              kind="primary"
                              disabled={!offer.canAccept}
                              titleKey={offer.reasonKey}
                              onClick={() => {
                                void client.guild.acceptOffer(offer.id);
                                showToast("quest.accepted", undefined, "good");
                              }}
                            />
                          </div>
                        </div>,
                      ]}
                    />
                  ))}
                </div>
              </div>
              {view.offers.length === 0 ? (
                <Label textValue={tKey(view.offersBlockedKey ?? "ui.not_available")} />
              ) : null}
            </div>
          </Frame>

          <Frame titleKey="guild.report.section" scroll className="guild__reports">
            <div className="sa-table guild__table_reports">
              {view.reports.map((report) => (
                <Row
                  key={report.discoveryId}
                  cols={[
                    <div className="sa-cell">{t(content.discoveryName(report.discoveryId))}</div>,
                    <div className="sa-cell sa-label--dim">
                      {fmt("guild.report_reward", { gold: report.rewardGold, fame: report.fame })}
                    </div>,
                    <Button
                      compact
                      fill
                      textKey="guild.report.action"
                      kind="primary"
                      onClick={() => {
                        void client.guild.report(report.discoveryId);
                        showToast("guild.report_reward", {
                          gold: report.rewardGold,
                          fame: report.fame,
                        }, "good");
                      }}
                    />,
                  ]}
                />
              ))}
            </div>
            {view.reports.length === 0 ? <Label textKey="guild.report.none" /> : null}
          </Frame>
        </div>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
