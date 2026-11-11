/**
 * S8 inn — the UW2 room window (80-* §4.9.1): a toolbar row (back /
 * title), the status panel (morale bar, gold, day) with the rest and
 * harbour-relief odd-job verbs, and the captains' rest table window.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CaptainTableRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Frame, Icon, Row, Toast, ValueBar } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./InnScreen.css";

const SCREEN: ScreenId = "inn";

function captainRoleIcon(captain: CaptainTableRow): string {
  if (captain.roleKey.endsWith(".pirate")) return "role_pirate";
  if (captain.roleKey.endsWith(".patrol")) return "role_patrol";
  if (captain.roleKey.endsWith(".courier")) return "role_courier";
  return "role_trader";
}

export function InnScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("inn");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();

  if (!view) return <ViewFallback status={status} />;

  const portName = t(content.portName(view.portId));

  return (
    <div className="sa-screen inn" data-screen={SCREEN}>
      <div className="inn__page sa-col">
        <div className="inn__header sa-plate">
          <div className="inn__header_line">
            <Button textKey="ui.back" onClick={() => navigate("port")} />
            <Label textKey="inn.title" values={{ port: portName }} title />
          </div>
        </div>

        <div className="inn__content sa-rowline sa-grow">
          <Frame className="inn__main">
            <div className="inn__body">
              <Label textKey="inn.morale" values={{ amount: state.morale }} />
              <div className="inn__bar">
                <ValueBar value={state.morale} max={view.moraleMax} tier={view.moraleTier} />
              </div>
              <div className="inn__pair">
                <Label textKey="ui.gold_amount" values={{ gold: state.gold }} />
                <Label textKey="world.day" values={{ day: state.day }} />
              </div>

              <div className="inn__action">
                <Button
                  text={fmt("inn.rest_cost", { day: view.rest.days, price: view.rest.price })}
                  disabled={!view.rest.canRest}
                  onClick={() => {
                    void client.inn.rest(view.rest.days);
                    showToast("inn.rest_done", { day: view.rest.days }, "good");
                  }}
                />
                <Label textKey="inn.rest" values={{ day: view.rest.days }} tone="dim" />
              </div>
              <div className="inn__action">
                <Button
                  textKey="inn.odd_job.offer"
                  disabled={!view.oddJob.eligible}
                  onClick={() => {
                    void client.inn.oddJob();
                    showToast("inn.odd_job.result", undefined, "good");
                  }}
                />
                <Label
                  textValue={view.oddJob.reasonKey ? tKey(view.oddJob.reasonKey) : tKey("inn.odd_job.offer")}
                  tone={view.oddJob.eligible ? "dim" : "warn"}
                />
              </div>
            </div>
          </Frame>

          <Frame titleKey="captain.section.inn" scroll className="inn__captains sa-grow">
            <div className="sa-table inn__table">
              {view.captains.map((captain) => (
                <Row
                  key={captain.id}
                  cols={[
                    <span className="inn__icon">
                      <Icon id={captainRoleIcon(captain)} />
                    </span>,
                    <div className="sa-cell">{t(captain.name)}</div>,
                    <div className="sa-cell">{tKey(captain.roleKey)}</div>,
                    <div className="sa-cell sa-label--dim">
                      {fmt("captain.table.last_seen", { day: captain.lastSeenDay })}
                    </div>,
                  ]}
                />
              ))}
            </div>
          </Frame>
        </div>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
