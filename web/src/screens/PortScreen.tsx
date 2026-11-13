/**
 * S4 port hub — the UW2 scene composition (80-* §4.9.1): a sea/land
 * backdrop with the port plate top-left and the facility verb bar along
 * the bottom edge.
 *
 * The card state (present / activation phase / bounty-closed / hours-open)
 * is the server projection's (`GET /api/view/port`, 90-* §0.4); this
 * screen only renders it and routes.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { PortFacilityStatus } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Icon, Toast } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./PortScreen.css";

const SCREEN: ScreenId = "port";
const FACILITY_ICON = (id: string) => `facility_${id}`;

const FACILITIES = ["market", "shipyard", "tavern", "inn", "guild", "palace"] as const;

function useStatusText() {
  const { tKey, fmt } = useI18n();
  return (status: PortFacilityStatus["status"]): string => {
    switch (status.kind) {
      case "always":
        return tKey("port.facility.open_always");
      case "open":
        return fmt("port.facility.open_now", { open: status.open, close: status.close });
      case "closed":
        return fmt("port.facility.closed", { open: status.open, close: status.close });
      case "stub":
        return tKey(status.reasonKey);
    }
  };
}

export function PortScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("port");
  const client = useGameClient();
  const { toast, clearToast } = useToastState();
  const statusText = useStatusText();

  if (!view) return <ViewFallback status={status} />;

  const portId = view.portId ?? state.current_port ?? "";
  const port = content.port(portId);
  const nationId = view.nationId ?? port?.nation_id ?? state.player.nation_id;

  const openFacility = (facility: PortFacilityStatus) => {
    void client.port.enter(facility.id);
    navigate(facility.id);
  };

  return (
    <div className="sa-screen port" data-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />

      <div className="port__header sa-plate">
        <div className="port__nation" aria-hidden="true">
          <span className={`sa-nation-swatch sa-nation-swatch--${nationId}`} />
        </div>
        <div className="port__header_names">
          <Label text={content.portName(portId)} title />
          <Label text={content.nationName(nationId)} />
          {port?.flavor ? <Label text={port.flavor} align="center" wrap /> : null}
          <Label textKey="world.day_time" values={{ day: state.day, time: view.clock ?? "" }} tone="dim" />
        </div>
      </div>

      <div className="port__verb_bar sa-verb-bar">
        <div className="port__facilities">
          {FACILITIES.map((id) => {
            const facility = view.facilities.find((entry) => entry.id === id);
            if (!facility) return null;
            return (
              <Button
                key={id}
                fill
                disabled={!facility.enabled}
                onClick={facility.enabled ? () => openFacility(facility) : undefined}
                titleKey={`port.${facility.id}`}
              >
                <span className="port__verb_stack">
                  <span className="port__verb_icon">
                    <Icon id={FACILITY_ICON(facility.id)} />
                  </span>
                  <Label textKey={`port.${facility.id}`} heading />
                  <Label textValue={statusText(facility.status)} tone="dim" className="port__verb_status" />
                </span>
              </Button>
            );
          })}
        </div>
        <div className="port__actions">
          <Button textKey="port.set_sail" kind="primary" onClick={() => navigate("provisions")} />
          <Button textKey="settings.title" onClick={() => navigate("settings")} />
        </div>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
