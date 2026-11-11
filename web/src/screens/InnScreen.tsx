/**
 * S8 inn — morale/gold/day status, rest, the harbour-relief odd job and the
 * captains' rest table. Every `inn` element row is rendered.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CaptainTableRow } from "../state/views";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Icon, Toast, ValueBar } from "../kit";
import {
  ButtonEl,
  LabelEl,
  PanelEl,
  useScreenView,
  useToastState,
  ViewFallback,
} from "./common";
import { navigate } from "../app/router";

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

  if (!view) return <ViewFallback screen={SCREEN} status={status} />;

  const portName = t(content.portName(view.portId));

  return (
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <LabelEl
          screen={SCREEN}
          id="header.title"
          parent="header"
          textKey="inn.title"
          values={{ port: portName }}
          title
        />
      </Element>

      <PanelEl screen={SCREEN} id="status">
        <LabelEl
          screen={SCREEN}
          id="status.morale"
          parent="status"
          textKey="inn.morale"
          values={{ amount: state.morale }}
        />
        <Element screen={SCREEN} id="status.morale_bar" parent="status">
          <ValueBar value={state.morale} max={view.moraleMax} tier={view.moraleTier} />
        </Element>
        <LabelEl
          screen={SCREEN}
          id="status.gold"
          parent="status"
          textKey="ui.gold_amount"
          values={{ gold: state.gold }}
        />
        <LabelEl
          screen={SCREEN}
          id="status.day"
          parent="status"
          textKey="world.day"
          values={{ day: state.day }}
        />
      </PanelEl>

      <Element screen={SCREEN} id="actions">
        <ButtonEl
          screen={SCREEN}
          id="actions.rest"
          parent="actions"
          text={fmt("inn.rest_cost", { day: view.rest.days, price: view.rest.price })}
          disabled={!view.rest.canRest}
          onClick={() => {
            void client.inn.rest(view.rest.days);
            showToast("inn.rest_done", { day: view.rest.days }, "good");
          }}
        />
        <LabelEl
          screen={SCREEN}
          id="actions.rest_hint"
          parent="actions"
          textKey="inn.rest"
          values={{ day: view.rest.days }}
          tone="dim"
        />
        <ButtonEl
          screen={SCREEN}
          id="actions.work_odd_job"
          parent="actions"
          textKey="inn.odd_job.offer"
          disabled={!view.oddJob.eligible}
          onClick={() => {
            void client.inn.oddJob();
            showToast("inn.odd_job.result", undefined, "good");
          }}
        />
        <LabelEl
          screen={SCREEN}
          id="actions.odd_job_hint"
          parent="actions"
          textValue={view.oddJob.reasonKey ? tKey(view.oddJob.reasonKey) : tKey("inn.odd_job.offer")}
          tone={view.oddJob.eligible ? "dim" : "warn"}
        />
      </Element>

      <LabelEl screen={SCREEN} id="captains.header" textKey="captain.section.inn" heading />
      <Element screen={SCREEN} id="captains.rows">
        <ListRows
          screen={SCREEN}
          listId="captains"
          count={view.captains.length}
          renderRow={(index) => {
            const captain = view.captains[index];
            return (
              <>
                <Box rect={{ x: 0, y: 0, w: 2, h: 2 }}>
                  <Icon id={captainRoleIcon(captain)} />
                </Box>
                <Box rect={{ x: 2, y: 0, w: 20, h: 2 }}>
                  <span className="sa-cell">{t(captain.name)}</span>
                </Box>
                <Box rect={{ x: 22, y: 0, w: 18, h: 2 }}>
                  <span className="sa-cell">{tKey(captain.roleKey)}</span>
                </Box>
                <Box rect={{ x: 40, y: 0, w: 18, h: 2 }}>
                  <span className="sa-cell sa-label--dim">
                    {fmt("captain.table.last_seen", { day: captain.lastSeenDay })}
                  </span>
                </Box>
              </>
            );
          }}
        />
      </Element>

      <Element screen={SCREEN} id="footer">
        <ButtonEl
          screen={SCREEN}
          id="footer.back"
          parent="footer"
          textKey="ui.back"
          onClick={() => navigate("port")}
        />
      </Element>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
