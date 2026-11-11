/**
 * The appointed-voyage HUD bar (docs/80-UI-UX.md §4.10.4; the §4.9.1 HUD
 * plate; docs/20-* §4.19).
 *
 * Destination / ETA / cancel while a voyage stands — a verb-bar plate along
 * the bottom edge of the world HUD (or the bare plate when embedded).
 * Cancel is the frozen `autopilot {cancel:true}` WS intent. Missing server
 * projection (reported): the bar's ETA (`autopilot.hud_state` carries
 * `eta_days` + `days`) is not on the `tick` frame, so the days slot renders
 * `ui.not_available` until the server projects it; only the persisted
 * destination is client-visible.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Button } from "../kit";
import { Label } from "./common";
import type { ScreenId } from "./ids";
import "./AutopilotHud.css";

const SCREEN: ScreenId = "autopilot_hud";

export function AutopilotHud({ embedded = false }: { embedded?: boolean }) {
  const { state, tick } = useGameState();
  const client = useGameClient();
  const { t, tKey } = useI18n();
  const dest = tick?.autopilot?.dest_port_id ?? state.player.autopilot?.dest_port_id ?? "";
  const body = (
    <div className="autopilot__bar sa-verb-bar" data-screen={SCREEN}>
      <Label
        textKey="sail.autopilot.hud.bar"
        values={{
          port: dest ? t(content.portName(dest)) : tKey("ui.not_available"),
          days: tKey("ui.not_available"),
        }}
        className="autopilot__info"
      />
      <Button
        textKey="sail.autopilot.cancel"
        kind="quiet"
        disabled={!dest}
        onClick={() => client.send({ type: "autopilot", cancel: true })}
      />
    </div>
  );
  return embedded ? body : <div className="sa-screen autopilot">{body}</div>;
}

export function autopilotDaysKey(): string {
  return "ui.not_available";
}

export function autopilotTitleKey(): string {
  return "sail.autopilot.hud.bar";
}
