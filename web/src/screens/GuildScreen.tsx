/**
 * S12 guild — commissions, discovery reports and the refresh hint.
 * Every `guild` element row is rendered; `offers` / `reports` are the list
 * blocks.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CommissionRow } from "../state/types";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Button, Icon, Toast } from "../kit";
import { ButtonEl, LabelEl, PanelEl, useToastState } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "guild";

const TYPE_ICON: Record<CommissionRow["type"], string> = {
  delivery: "scroll",
  bounty: "skull",
  exploration: "compass",
  royal: "crown",
};

export function GuildScreen() {
  const { state, views } = useGameState();
  const view = views.guild;
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();

  const portName = t(content.portName(view.portId));

  return (
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <LabelEl
          screen={SCREEN}
          id="header.title"
          parent="header"
          textKey="guild.title"
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
          id="header.fame"
          parent="header"
          textKey="ending.fame"
          values={{ fame: state.fame }}
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

      <Element screen={SCREEN} id="offers">
        <LabelEl screen={SCREEN} id="offers.heading" parent="offers" textKey="guild.offers" heading />
        <LabelEl
          screen={SCREEN}
          id="offers.refresh_hint"
          parent="offers"
          textKey="guild.offers_refresh"
          values={{ day: view.offersRefreshDay }}
          tone="dim"
        />
        <LabelEl
          screen={SCREEN}
          id="offers.announce"
          parent="offers"
          textValue={view.offersAnnounce ? t(view.offersAnnounce) : view.tournament ? t(view.tournament) : ""}
          tone="accent"
        />
        <Element screen={SCREEN} id="offers.scroll" parent="offers" className="sa-scroll">
          <ListRows
            screen={SCREEN}
            listId="offers"
            count={view.offers.length}
            renderRow={(index) => {
              const offer = view.offers[index];
              return (
                <>
                  <Box rect={{ x: 0, y: 0, w: 2, h: 3 }}>
                    <Icon id={TYPE_ICON[offer.type]} />
                  </Box>
                  <Box rect={{ x: 2, y: 0, w: 10, h: 1 }}>
                    <span className="sa-cell sa-label--heading">{tKey(`quest.type.${offer.type}`)}</span>
                  </Box>
                  <Box rect={{ x: 12, y: 0, w: 30, h: 1 }}>
                    <span className="sa-cell">{fmt(offer.lineKey, offer.lineValues)}</span>
                  </Box>
                  <Box rect={{ x: 42, y: 0, w: 8, h: 1 }}>
                    <span className="sa-cell">{fmt("quest.days_left", { days: offer.daysLeft })}</span>
                  </Box>
                  <Box rect={{ x: 12, y: 1, w: 30, h: 1 }}>
                    <span className="sa-cell sa-label--dim">
                      {fmt("quest.reward", { gold: offer.rewardGold, rep: offer.rep })}
                    </span>
                  </Box>
                  {offer.hintKey ? (
                    <Box rect={{ x: 12, y: 2, w: 30, h: 1 }}>
                      <span className="sa-cell sa-label--dim">{tKey(offer.hintKey)}</span>
                    </Box>
                  ) : null}
                  <Box rect={{ x: 50, y: 1, w: 8, h: 2 }}>
                    <Button
                      textKey="quest.accept"
                      kind="primary"
                      disabled={!offer.canAccept}
                      titleKey={offer.reasonKey}
                      fill
                      onClick={() => {
                        void client.guild.acceptOffer(offer.id);
                        showToast("quest.accepted", undefined, "good");
                      }}
                    />
                  </Box>
                </>
              );
            }}
          />
        </Element>
        <LabelEl
          screen={SCREEN}
          id="offers.empty"
          parent="offers"
          textValue={view.offers.length === 0 ? tKey(view.offersBlockedKey ?? "ui.not_available") : ""}
          hidden={view.offers.length > 0}
        />
      </Element>

      <Element screen={SCREEN} id="reports">
        <LabelEl screen={SCREEN} id="reports.heading" parent="reports" textKey="guild.report.section" heading />
        <Element screen={SCREEN} id="reports.scroll" parent="reports" className="sa-scroll">
          <ListRows
            screen={SCREEN}
            listId="reports"
            count={view.reports.length}
            renderRow={(index) => {
              const report = view.reports[index];
              return (
                <>
                  <Box rect={{ x: 0, y: 0, w: 20, h: 2 }}>
                    <span className="sa-cell">{t(content.discoveryName(report.discoveryId))}</span>
                  </Box>
                  <Box rect={{ x: 20, y: 0, w: 22, h: 2 }}>
                    <span className="sa-cell sa-label--dim">
                      {fmt("guild.report_reward", { gold: report.rewardGold, fame: report.fame })}
                    </span>
                  </Box>
                  <Box rect={{ x: 44, y: 0, w: 14, h: 2 }}>
                    <Button
                      textKey="guild.report.action"
                      kind="primary"
                      fill
                      onClick={() => {
                        void client.guild.report(report.discoveryId);
                        showToast("guild.report_reward", {
                          gold: report.rewardGold,
                          fame: report.fame,
                        }, "good");
                      }}
                    />
                  </Box>
                </>
              );
            }}
          />
        </Element>
        <LabelEl
          screen={SCREEN}
          id="reports.empty"
          parent="reports"
          textKey="guild.report.none"
          hidden={view.reports.length > 0}
        />
      </Element>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
