/**
 * S13 palace — the UW2 room windows (80-* §4.9.1): a toolbar row (back /
 * title / reputation / fame), the royal-actions window (titles, mission,
 * repair, bounty, permits, tournament, retirement), the bounty board and
 * inform side windows, and the commend message dialog over the dim layer.
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { ScreenId } from "./ids";
import { Button, Dialog, Frame, Icon, Row, Toast } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./PalaceScreen.css";

const SCREEN: ScreenId = "palace";

export function PalaceScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("palace");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [commendDismissed, setCommendDismissed] = useState(false);

  if (!view) return <ViewFallback status={status} />;

  const portName = t(content.portName(view.portId));
  const nationName = t(content.nationName(view.nationId));

  const missionLabel = (): string => {
    if (view.mission) {
      return fmt("palace.mission.active", {
        objective: fmt(view.mission.objectiveKey, view.mission.objectiveValues),
        days: view.mission.daysLeft,
      });
    }
    if (view.missionRepLock !== undefined) {
      return fmt("palace.rep_locked", { rep: view.missionRepLock });
    }
    return tKey("palace.mission.section");
  };

  const permitRow = (kind: "home" | "foreign") => {
    const offer = kind === "home" ? view.permits.home : view.permits.foreign;
    const label = offer.owned
      ? tKey(kind === "home" ? "palace.permit.home.owned" : "palace.permit.foreign.owned")
      : kind === "home"
        ? tKey("palace.permit.home")
        : fmt("palace.permit.foreign", {
            nation: content.nationName(offer.nationId ?? view.nationId),
          });
    const note = offer.noteKey
      ? tKey(offer.noteKey)
      : tKey(kind === "home" ? "palace.permit.home.coverage" : "palace.permit.foreign.coverage");
    return (
      <div key={kind} className="palace__row">
        <Label textValue={label} />
        <Label className="palace__note" textValue={note} tone="dim" />
        <div className="sa-grow" />
        <Button
          compact
          textKey="market.buy"
          kind="primary"
          disabled={!offer.canBuy || offer.owned}
          onClick={() => {
            void client.palace.buyPermit(kind, offer.nationId);
            showToast("palace.permit.bought", undefined, "good");
          }}
        />
      </div>
    );
  };

  return (
    <div className="sa-screen palace" data-screen={SCREEN}>
      <div className="palace__page sa-col">
        <div className="palace__header sa-plate">
          <div className="palace__header_line">
            <Button textKey="ui.back" onClick={() => navigate("port")} />
            <Label textKey="palace.title" values={{ port: portName, nation: nationName }} title />
            <div className="sa-grow" />
            <Label textKey="char.rep_value" values={{ amount: state.player.reputation[view.nationId] ?? 0 }} />
            <Label textKey="ending.fame" values={{ fame: state.fame }} />
          </div>
        </div>

        <div className="palace__content sa-rowline sa-grow">
          <Frame scroll className="palace__main sa-grow">
            <div className="palace__rows">
              <div className="palace__row">
                <div className="palace__row_labels">
                  <Label textKey="palace.title.current" values={{ rank: tKey(`rank.${view.rank}`) }} />
                  <Label
                    textValue={
                      view.nextRank
                        ? fmt("palace.title.next", {
                            rank: tKey(`rank.${view.nextRank.rank}`),
                            fame: view.nextRank.fame,
                            missions: view.nextRank.missions,
                          })
                        : tKey("palace.title.max")
                    }
                    tone="dim"
                  />
                </div>
                <div className="sa-grow" />
                <Button
                  compact
                  textKey="palace.ceremony"
                  kind="primary"
                  disabled={!view.ceremonyAvailable}
                  onClick={() => {
                    void client.palace.ceremony();
                    showToast("palace.ceremony.done", { nation: nationName, rank: tKey(`rank.${view.rank}`) }, "good");
                  }}
                />
              </div>

              <div className="palace__row">
                <Label textValue={missionLabel()} />
                <div className="sa-grow" />
                <Button
                  compact
                  textKey="palace.mission.accept"
                  disabled={!view.mission?.canAccept}
                  onClick={() => {
                    void client.palace.acceptMission();
                    showToast("quest.accepted", undefined, "good");
                  }}
                />
              </div>

              <div className="palace__row">
                <Label
                  textValue={
                    view.repairDiscountPct !== undefined
                      ? fmt("palace.repair.discount", { percent: view.repairDiscountPct })
                      : tKey("palace.repair")
                  }
                />
                <div className="sa-grow" />
                <Button
                  compact
                  textKey="palace.repair"
                  disabled={!view.repairAvailable}
                  onClick={() => void client.palace.repairFleet()}
                />
              </div>

              <div className="palace__row">
                <Label textValue={view.bounty ? fmt("bounty.pay", { gold: view.bounty.amount }) : tKey("bounty.none")} />
                <div className="sa-grow" />
                <Button
                  compact
                  text={view.bounty ? fmt("bounty.pay", { gold: view.bounty.amount }) : tKey("bounty.none")}
                  disabled={!view.bounty?.canPay}
                  onClick={() => void client.palace.payBounty(view.nationId)}
                />
              </div>

              <Label textKey="palace.permit.section" heading />
              {permitRow("home")}
              {permitRow("foreign")}

              <div className="palace__row">
                <Label
                  textValue={
                    view.tournament
                      ? fmt("tournament.status", {
                          port: t(content.portName(view.tournament.hostPortId)),
                          first: view.tournament.firstDay,
                          last: view.tournament.lastDay,
                        })
                      : ""
                  }
                />
                <div className="sa-grow" />
                <Button
                  compact
                  textKey={view.tournament?.entered ? "tournament.entered" : "tournament.enter"}
                  disabled={!view.tournament?.canEnter || view.tournament?.entered || Boolean(view.tournament?.blockedKey)}
                  titleKey={view.tournament?.blockedKey}
                  onClick={() => void client.palace.enterTournament()}
                />
              </div>

              {view.canRetire !== false ? (
                <div className="palace__row">
                  <div className="sa-grow" />
                  <Button
                    compact
                    textKey="palace.retire"
                    kind="danger"
                    onClick={() => void client.palace.retire()}
                  />
                </div>
              ) : null}
            </div>
          </Frame>

          <div className="palace__side">
            <Frame titleKey="captain.section.palace" scroll className="palace__board">
              <div className="sa-table palace__table_board">
                {view.board.map((row) => (
                  <Row
                    key={row.captainId}
                    cols={[
                      <span className="palace__icon">
                        <Icon id="skull" />
                      </span>,
                      <div className="sa-cell">{fmt("captain.poster.title", { name: t(row.name), tier: row.tier })}</div>,
                      <div className="sa-cell">{tKey(row.roleKey)}</div>,
                      <div className="sa-cell sa-label--dim">
                        {fmt("captain.poster.reward", { gold: row.rewardGold })}
                      </div>,
                    ]}
                  />
                ))}
              </div>
            </Frame>

            <Frame titleKey="palace.inform.header" scroll className="palace__inform">
              <div className="sa-table palace__table_inform">
                {view.inform.map((row) => (
                  <Row
                    key={row.captainId}
                    cols={[
                      <div className="sa-cell">{t(row.text)}</div>,
                      <Button
                        compact
                        fill
                        textKey="palace.inform.action"
                        disabled={!row.canInform}
                        onClick={() => {
                          void client.palace.inform(row.captainId);
                          showToast("palace.inform.action", undefined, "good");
                        }}
                      />,
                    ]}
                  />
                ))}
              </div>
            </Frame>
          </div>
        </div>
      </div>

      {view.commend && !commendDismissed ? (
        <div className="palace__overlay sa-dim">
          <Dialog titleKey="palace.commend.title" className="palace__commend">
            <Label
              textValue={fmt("palace.commend.body", {
                nation: t(content.nationName(view.commend.nationId)),
                port: t(content.portName(view.commend.portId)),
              })}
              light
              wrap
            />
            <div className="sa-footer">
              <Button textKey="palace.commend.close" kind="primary" onClick={() => setCommendDismissed(true)} />
            </div>
          </Dialog>
        </div>
      ) : null}

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
