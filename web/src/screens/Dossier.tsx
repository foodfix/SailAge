/**
 * The captain dossier (docs/80-UI-UX.md §4.11.3; the §4.9.1 composition) —
 * the §4.12 card plus the familiarity-gated career log, one scrollable
 * parchment window centered over the dim layer. Read-only; `ui.close` (and
 * `Escape`) step back to the intel window.
 *
 * Familiarity gates only the career log (locked): 3 = last-seen fleet
 * composition, 6 = home port + sighting history, 10 = the full lane picture.
 * The card above is never gated (identify = full reveal, §4.12.1); locked
 * sections render their hint lines dimmed.
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
import type { ScreenId } from "./ids";
import { Button, Frame } from "../kit";
import { Label } from "./common";
import { CharacterCard, captainCanon } from "./CharacterCard";
import { navigate } from "../app/router";
import "./Dossier.css";

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
        <div className="sa-fill-center">
          <Frame titleKey="dossier.title" className="dossier__fallback">
            <div className="sa-cell">{tKey("ui.not_available")}</div>
          </Frame>
        </div>
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
    <div className="sa-screen dossier" data-screen={SCREEN}>
      <div className="dossier__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center dossier__center">
        <Frame scroll className="dossier__window">
          <div className="dossier__stack">
            <Label textKey="dossier.title" values={{ name }} title />
            <Label textValue={headerParts.join(" · ")} tone="dim" />

            <CharacterCard kind="npc" personId={captainId} statBlocks />

            <div className="dossier__log">
              <Label textValue={`${tKey("dossier.familiarity")}: ${familiarity}`} />
              {tier > 0 ? (
                <Label textKey={`dossier.tier.${FAMILIARITY_TIERS[tier - 1]}`} tone="dim" />
              ) : null}
              {LOG_SECTIONS.map((sectionKey, index) => {
                const locked = familiarity < FAMILIARITY_TIERS[index];
                return (
                  <div key={sectionKey} className="dossier__log_section" data-log={sectionKey}>
                    <Label textKey={sectionKey} heading />
                    <Label textValue={sectionValue(index)} tone={locked ? "dim" : "default"} wrap />
                  </div>
                );
              })}
            </div>

            <Button textKey="ui.close" onClick={() => navigate("intel_window")} />
          </div>
        </Frame>
      </div>
    </div>
  );
}
