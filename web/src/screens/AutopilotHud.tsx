/**
 * The appointed-voyage HUD bar (docs/80-UI-UX.md §4.10.4; docs/20-* §4.19).
 *
 * Destination / ETA / cancel while a voyage stands. Cancel is the frozen
 * `autopilot {cancel:true}` WS intent. Missing server projection (reported):
 * the bar's ETA (`autopilot.hud_state` carries `eta_days` + `days`) is not
 * on the `tick` frame, so the days slot renders `ui.not_available` until the
 * server projects it; only the persisted destination is client-visible.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Element, type ScreenId } from "../layout";
import { Button } from "../kit";
import { LabelEl } from "./common";

const SCREEN: ScreenId = "autopilot_hud";

export function AutopilotHud({ embedded = false }: { embedded?: boolean }) {
  const { state, tick } = useGameState();
  const client = useGameClient();
  const { t, tKey } = useI18n();
  const dest = tick?.autopilot?.dest_port_id ?? state.player.autopilot?.dest_port_id ?? "";
  const body = (
    <Element screen={SCREEN} id="bar" skin="panel">
      <LabelEl
        screen={SCREEN}
        id="bar.info"
        parent="bar"
        textKey="sail.autopilot.hud.bar"
        values={{
          port: dest ? t(content.portName(dest)) : tKey("ui.not_available"),
          days: tKey("ui.not_available"),
        }}
      />
      <Element screen={SCREEN} id="bar.cancel" parent="bar">
        <Button
          textKey="sail.autopilot.cancel"
          kind="quiet"
          disabled={!dest}
          fill
          onClick={() => client.send({ type: "autopilot", cancel: true })}
        />
      </Element>
    </Element>
  );
  return embedded ? body : <div className="sa-screen">{body}</div>;
}

export function autopilotDaysKey(): string {
  return "ui.not_available";
}

export function autopilotTitleKey(): string {
  return "sail.autopilot.hud.bar";
}
