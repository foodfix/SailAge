/**
 * The captain dossier (docs/80-UI-UX.md §4.11.3) — the §4.12 card plus the
 * familiarity-gated career log. Read-only.
 *
 * Familiarity gates only the career log (locked): 3 = last-seen fleet
 * composition, 6 = home port + sighting history, 10 = the full lane picture.
 * The card above is never gated (identify = full reveal, §4.12.1).
 *
 * Missing server projection (reported): `GET /api/view/dossier` should carry
 * the already-localized gated log sections and the familiarity tier. Until
 * it lands this screen derives the *display* from the authoritative state
 * (`captain_states`, `npc_fleets`) and the canon card; the section text is
 * composed from content names and i18n keys, never from a rule.
 */
import { useEffect } from "react";
import { content, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import { Box, ListRows, type ScreenId } from "../layout";
import { ButtonEl, LabelEl, PanelEl } from "./common";
import { CharacterCard, captainCanon } from "./CharacterCard";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "dossier";
const FAMILIARITY_TIERS = [3, 6, 10] as const;
const LOG_SECTIONS = ["dossier.log.composition", "dossier.log.home_port", "dossier.log.lanes"] as const;

interface CaptainRunState {
  tier_now?: number;
  stance?: number;
  familiarity?: number;
  last_seen_day?: number;
  status?: string;
  return_day?: number;
}

interface FleetRecord {
  captain_id?: string;
  ships?: { ship_type_id?: string }[];
  route?: { lanes?: string[] };
  dest_port_id?: string;
}

export function Dossier({ captainId: requestedId }: { captainId?: string } = {}) {
  const { state } = useGameState();
  const captainId = requestedId ?? Object.keys(state.captain_states)[0] ?? "cap_leg_trader_05";
  const { t, tKey, fmt } = useI18n();
  const canon = captainCanon(captainId);
  const runState = (state.captain_states[captainId] ?? {}) as CaptainRunState;
  const familiarity = Number(runState.familiarity ?? 0);
  const tier = FAMILIARITY_TIERS.reduce((count, threshold) => count + (familiarity >= threshold ? 1 : 0), 0);
  const fleet = (state.npc_fleets as unknown as FleetRecord[]).find(
    (entry) => entry.captain_id === captainId,
  );

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      navigate("intel_window");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (!canon) {
    return (
      <div className="sa-screen">
        <PanelEl screen={SCREEN} id="dim" skin="backdrop" />
        <div className="sa-cell">{tKey("ui.not_available")}</div>
      </div>
    );
  }

  const name = t(canon.name);
  const stance = Number(runState.stance ?? 0);
  const tierNow = Number(runState.tier_now ?? canon.tier ?? 1);
  const headerParts = [
    canon.role ? tKey(`captain.role.${canon.role}`) : "",
    `${tKey("captain.table.tier")} ${tierNow}`,
    fmt("char.level", { level: canon.level ?? 1 }),
  ].filter((part) => part !== "");
  if (stance >= 2) {
    headerParts.push(fmt("dossier.header.tier", { tier: tierNow }));
    headerParts.push(
      runState.status === "returning"
        ? tKey("dossier.status.returning")
        : tKey("dossier.status.at_sea"),
    );
  }

  const composition = (fleet?.ships ?? [])
    .map((ship) => (ship.ship_type_id ? t(content.shipName(ship.ship_type_id)) : ""))
    .filter((part) => part !== "")
    .join(" · ");
  const homeLine = [
    canon.home_port ? t(content.portName(canon.home_port)) : "",
    runState.last_seen_day
      ? fmt("captain.table.last_seen", { day: runState.last_seen_day })
      : "",
  ]
    .filter((part) => part !== "")
    .join(" · ");
  const laneLine = (fleet?.route?.lanes ?? []).join(" · ");

  const sectionValue = (index: number): string => {
    const threshold = FAMILIARITY_TIERS[index];
    if (familiarity < threshold) {
      return fmt("dossier.locked.tier", { tier: threshold });
    }
    if (index === 0) return composition || tKey("char.none");
    if (index === 1) return homeLine || tKey("char.none");
    return laneLine || tKey("char.none");
  };

  return (
    <div className="sa-screen">
      <PanelEl screen={SCREEN} id="dim" skin="backdrop" className="sa-dim" />
      <PanelEl screen={SCREEN} id="panel" skin="panel">
        <LabelEl
          screen={SCREEN}
          id="panel.title"
          parent="panel"
          textKey="dossier.title"
          values={{ name }}
          title
        />
        <LabelEl
          screen={SCREEN}
          id="panel.header"
          parent="panel"
          textValue={headerParts.join(" · ")}
          tone="dim"
        />
        <Box rect={{ x: 1, y: 3, w: 20, h: 14 }} className="sa-scroll">
          <CharacterCard kind="npc" personId={captainId} statBlocks />
        </Box>
        <Box rect={{ x: 1, y: 3, w: 20, h: 19 }}>
          <ListRows
            screen={SCREEN}
            listId="content_lines"
            count={2}
            renderRow={(index) => (
              <div className="sa-cell" data-row={index}>
                {index === 0
                  ? `${tKey("dossier.familiarity")}: ${familiarity}`
                  : tier > 0
                    ? tKey(`dossier.tier.${FAMILIARITY_TIERS[tier - 1]}`)
                    : ""}
              </div>
            )}
          />
        </Box>
        <Box rect={{ x: 1, y: 3, w: 20, h: 19 }}>
          <ListRows
            screen={SCREEN}
            listId="log"
            count={LOG_SECTIONS.length}
            renderRow={(index) => {
              const locked = familiarity < FAMILIARITY_TIERS[index];
              return (
                <div data-row={index}>
                  <div className="sa-cell sa-label--heading">{tKey(LOG_SECTIONS[index])}</div>
                  <div className={`sa-cell${locked ? " sa-label--dim" : ""}`}>
                    {sectionValue(index)}
                  </div>
                </div>
              );
            }}
          />
        </Box>
        <ButtonEl
          screen={SCREEN}
          id="panel.close"
          parent="panel"
          textKey="ui.close"
          onClick={() => navigate("intel_window")}
        />
      </PanelEl>
    </div>
  );
}
