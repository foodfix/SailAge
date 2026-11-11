/**
 * S13 palace — titles, royal mission, repair, permits, tournament, bounty
 * board, pirate inform and retirement. Every `palace` element row is
 * rendered; `board` / `inform` are the list blocks.
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Button, Frame, Icon, Toast } from "../kit";
import { ButtonEl, LabelEl, PanelEl, useToastState } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "palace";

export function PalaceScreen() {
  const { state, views } = useGameState();
  const view = views.palace;
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [commendDismissed, setCommendDismissed] = useState(false);

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

  const permitRow = (
    kind: "home" | "foreign",
    ids: { row: string; label: string; note: string; buy: string },
  ) => {
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
      <Element key={kind} screen={SCREEN} id={ids.row} parent="rows">
        <LabelEl screen={SCREEN} id={ids.label} parent={ids.row} textValue={label} />
        <LabelEl screen={SCREEN} id={ids.note} parent={ids.row} textValue={note} tone="dim" />
        <ButtonEl
          screen={SCREEN}
          id={ids.buy}
          parent={ids.row}
          textKey="market.buy"
          kind="primary"
          disabled={!offer.canBuy || offer.owned}
          onClick={() => {
            void client.palace.buyPermit(kind, offer.nationId);
            showToast("palace.permit.bought", undefined, "good");
          }}
        />
      </Element>
    );
  };

  return (
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <LabelEl
          screen={SCREEN}
          id="header.title"
          parent="header"
          textKey="palace.title"
          values={{ port: portName, nation: nationName }}
          title
        />
        <LabelEl
          screen={SCREEN}
          id="header.rep"
          parent="header"
          textKey="char.rep_value"
          values={{ amount: state.player.reputation[view.nationId] ?? 0 }}
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

      <Element screen={SCREEN} id="rows">
        <Element screen={SCREEN} id="rows.title" parent="rows">
          <LabelEl
            screen={SCREEN}
            id="rows.title.current"
            parent="rows.title"
            textKey="palace.title.current"
            values={{ rank: tKey(`rank.${view.rank}`) }}
          />
          <LabelEl
            screen={SCREEN}
            id="rows.title.next"
            parent="rows.title"
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
          <ButtonEl
            screen={SCREEN}
            id="rows.title.ceremony"
            parent="rows.title"
            textKey="palace.ceremony"
            kind="primary"
            disabled={!view.ceremonyAvailable}
            onClick={() => {
              void client.palace.ceremony();
              showToast("palace.ceremony.done", { nation: nationName, rank: tKey(`rank.${view.rank}`) }, "good");
            }}
          />
        </Element>

        <Element screen={SCREEN} id="rows.mission" parent="rows">
          <LabelEl screen={SCREEN} id="rows.mission.label" parent="rows.mission" textValue={missionLabel()} />
          <ButtonEl
            screen={SCREEN}
            id="rows.mission.action"
            parent="rows.mission"
            textKey="palace.mission.accept"
            disabled={!view.mission?.canAccept}
            onClick={() => {
              void client.palace.acceptMission();
              showToast("quest.accepted", undefined, "good");
            }}
          />
        </Element>

        <Element screen={SCREEN} id="rows.repair" parent="rows">
          <LabelEl
            screen={SCREEN}
            id="rows.repair.label"
            parent="rows.repair"
            textValue={
              view.repairDiscountPct !== undefined
                ? fmt("palace.repair.discount", { percent: view.repairDiscountPct })
                : tKey("palace.repair")
            }
          />
          <ButtonEl
            screen={SCREEN}
            id="rows.repair.action"
            parent="rows.repair"
            textKey="palace.repair"
            disabled={!view.repairAvailable}
            onClick={() => void client.palace.repairFleet()}
          />
        </Element>

        <Element screen={SCREEN} id="rows.bounty" parent="rows">
          <LabelEl
            screen={SCREEN}
            id="rows.bounty.label"
            parent="rows.bounty"
            textValue={view.bounty ? fmt("bounty.pay", { gold: view.bounty.amount }) : tKey("bounty.none")}
          />
          <ButtonEl
            screen={SCREEN}
            id="rows.bounty.action"
            parent="rows.bounty"
            text={
              view.bounty
                ? fmt("bounty.pay", { gold: view.bounty.amount })
                : tKey("bounty.none")
            }
            disabled={!view.bounty?.canPay}
            onClick={() => void client.palace.payBounty(view.nationId)}
          />
        </Element>

        <LabelEl screen={SCREEN} id="rows.permit_header" parent="rows" textKey="palace.permit.section" heading />
        {permitRow("home", {
          row: "rows.permit_home",
          label: "rows.permit_home.label",
          note: "rows.permit_home.note",
          buy: "rows.permit_home.buy",
        })}
        {permitRow("foreign", {
          row: "rows.permit_foreign",
          label: "rows.permit_foreign.label",
          note: "rows.permit_foreign.note",
          buy: "rows.permit_foreign.buy",
        })}

        <Element screen={SCREEN} id="rows.tournament" parent="rows">
          <LabelEl
            screen={SCREEN}
            id="rows.tournament.label"
            parent="rows.tournament"
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
          <ButtonEl
            screen={SCREEN}
            id="rows.tournament.action"
            parent="rows.tournament"
            textKey={view.tournament?.entered ? "tournament.entered" : "tournament.enter"}
            disabled={!view.tournament?.canEnter || view.tournament?.entered || Boolean(view.tournament?.blockedKey)}
            titleKey={view.tournament?.blockedKey}
            onClick={() => void client.palace.enterTournament()}
          />
        </Element>

        <Element screen={SCREEN} id="rows.retire" parent="rows">
          <ButtonEl
            screen={SCREEN}
            id="rows.retire.button"
            parent="rows.retire"
            textKey="palace.retire"
            kind="danger"
            onClick={() => void client.palace.retire()}
          />
        </Element>
      </Element>

      <LabelEl screen={SCREEN} id="board.header" textKey="captain.section.palace" heading />
      <Element screen={SCREEN} id="board.rows">
        <ListRows
          screen={SCREEN}
          listId="board"
          count={view.board.length}
          renderRow={(index) => {
            const row = view.board[index];
            return (
              <>
                <Box rect={{ x: 0, y: 0, w: 3, h: 2 }}>
                  <Icon id="skull" />
                </Box>
                <Box rect={{ x: 3, y: 0, w: 30, h: 2 }}>
                  <span className="sa-cell">
                    {fmt("captain.poster.title", { name: t(row.name), tier: row.tier })}
                  </span>
                </Box>
                <Box rect={{ x: 33, y: 0, w: 12, h: 2 }}>
                  <span className="sa-cell">{tKey(row.roleKey)}</span>
                </Box>
                <Box rect={{ x: 45, y: 0, w: 13, h: 2 }}>
                  <span className="sa-cell sa-label--dim">
                    {fmt("captain.poster.reward", { gold: row.rewardGold })}
                  </span>
                </Box>
              </>
            );
          }}
        />
      </Element>

      <LabelEl screen={SCREEN} id="inform.header" textKey="palace.inform.header" heading />
      <Element screen={SCREEN} id="inform.rows">
        <ListRows
          screen={SCREEN}
          listId="inform"
          count={view.inform.length}
          renderRow={(index) => {
            const row = view.inform[index];
            return (
              <>
                <Box rect={{ x: 0, y: 0, w: 46, h: 2 }}>
                  <span className="sa-cell">{t(row.text)}</span>
                </Box>
                <Box rect={{ x: 46, y: 0, w: 12, h: 2 }}>
                  <Button
                    textKey="palace.inform.action"
                    disabled={!row.canInform}
                    fill
                    onClick={() => {
                      void client.palace.inform(row.captainId);
                      showToast("palace.inform.action", undefined, "good");
                    }}
                  />
                </Box>
              </>
            );
          }}
        />
      </Element>

      <Element screen={SCREEN} id="confirm_dialog" hidden />
      <Element
        screen={SCREEN}
        id="commend_dialog"
        skin="backdrop"
        hidden={!view.commend || commendDismissed}
      >
        {view.commend ? (
          <Box rect={{ x: 18, y: 9, w: 24, h: 16 }}>
            <Frame titleKey="palace.commend.title">
              <div className="sa-cell">
                {fmt("palace.commend.body", {
                  nation: t(content.nationName(view.commend.nationId)),
                  port: t(content.portName(view.commend.portId)),
                })}
              </div>
              <div className="sa-footer">
                <Button
                  textKey="palace.commend.close"
                  kind="primary"
                  onClick={() => setCommendDismissed(true)}
                />
              </div>
            </Frame>
          </Box>
        ) : null}
      </Element>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
