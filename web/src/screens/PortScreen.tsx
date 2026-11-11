/**
 * S4 port hub — the facility cards + Set Sail (80-* §4.8.1, 4.8.9).
 * Every element row of data/ui_layout.json's `port` screen is rendered.
 */
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { PortFacilityStatus } from "../state/types";
import { Box, Element, type ScreenId } from "../layout";
import { Icon, Toast } from "../kit";
import { ButtonEl, LabelEl, PanelEl, useToastState } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "port";
const FACILITY_ICON = (id: string) => `facility_${id}`;

const CARD_IDS = [
  { id: "market", card: "cards.market", name: "cards.market.name", status: "cards.market.status" },
  { id: "shipyard", card: "cards.shipyard", name: "cards.shipyard.name", status: "cards.shipyard.status" },
  { id: "tavern", card: "cards.tavern", name: "cards.tavern.name", status: "cards.tavern.status" },
  { id: "inn", card: "cards.inn", name: "cards.inn.name", status: "cards.inn.status" },
  { id: "guild", card: "cards.guild", name: "cards.guild.name", status: "cards.guild.status" },
  { id: "palace", card: "cards.palace", name: "cards.palace.name", status: "cards.palace.status" },
] as const;

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
  const { state, views } = useGameState();
  const client = useGameClient();
  const { toast, clearToast } = useToastState();
  const statusText = useStatusText();

  const portId = state.current_port ?? views.market.portId;
  const port = content.port(portId);
  const nationId = port?.nation_id ?? state.player.nation_id;

  const openFacility = (facility: PortFacilityStatus) => {
    void client.port.enter(facility.id);
    navigate(facility.id);
  };

  return (
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <Element screen={SCREEN} id="header.nation_swatch" parent="header">
          <span className={`sa-nation-swatch sa-nation-swatch--${nationId}`} aria-hidden="true" />
        </Element>
        <LabelEl screen={SCREEN} id="header.port_name" parent="header" text={content.portName(portId)} title />
        <LabelEl screen={SCREEN} id="header.nation_name" parent="header" text={content.nationName(nationId)} />
        {port?.flavor ? (
          <LabelEl screen={SCREEN} id="header.greeting" parent="header" text={port.flavor} align="center" />
        ) : (
          <LabelEl screen={SCREEN} id="header.greeting" parent="header" />
        )}
        <LabelEl
          screen={SCREEN}
          id="header.day_greeting"
          parent="header"
          textKey="port.day_greeting"
          values={{ port: content.portName(portId), day: state.day }}
          align="center"
          tone="dim"
        />
      </Element>

      <LabelEl screen={SCREEN} id="facility_heading" textKey="port.facilities" heading />

      <Element screen={SCREEN} id="facility_grid">
        {CARD_IDS.map((card) => {
          const facility = views.port.facilities.find((entry) => entry.id === card.id);
          if (!facility) return null;
          return (
            <Element
              key={card.id}
              screen={SCREEN}
              id={card.card}
              parent="facility_grid"
              skin="panel"
              as="button"
              className="sa-card-button"
              disabled={!facility.enabled}
              onClick={facility.enabled ? () => openFacility(facility) : undefined}
              ariaLabelKey={`port.${facility.id}`}
            >
              <Box rect={{ x: 0, y: 0, w: 2, h: 2 }}>
                <Icon id={FACILITY_ICON(facility.id)} />
              </Box>
              <LabelEl screen={SCREEN} id={card.name} parent={card.card} textKey={`port.${facility.id}`} heading />
              <LabelEl
                screen={SCREEN}
                id={card.status}
                parent={card.card}
                textValue={statusText(facility.status)}
                tone="dim"
              />
            </Element>
          );
        })}
      </Element>

      <Element screen={SCREEN} id="footer">
        <ButtonEl
          screen={SCREEN}
          id="footer.set_sail"
          parent="footer"
          textKey="port.set_sail"
          kind="primary"
          onClick={() => navigate("provisions")}
        />
        <ButtonEl
          screen={SCREEN}
          id="footer.settings"
          parent="footer"
          textKey="settings.title"
          onClick={() => navigate("settings")}
        />
      </Element>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
