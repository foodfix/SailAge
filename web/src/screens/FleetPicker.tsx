/**
 * The right-click fleet picker (docs/80-UI-UX.md §4.10.1; the §4.9.1
 * composition).
 *
 * One row per fleet on the contacted tile: flag, role letter, identified
 * name, tier, and the inspect / talk / attack verbs. `inspect` opens the
 * §4.12 card in place; `talk` opens the hail; `attack` posts the frozen
 * `people/attack` funnel; a coaster row renders no attack verb.
 *
 * Composition (§4.9.1): a centered parchment window whose contact rows are
 * a kit `.sa-table` (compact row verbs); the inspect card replaces the
 * table in place.
 *
 * Missing server projection (reported): `GET /api/view/fleet_picker` should
 * carry the sighting rows and the per-verb enabled/reason gates (range,
 * coaster rule). Until it lands the screen reads the encounter + NPC state
 * and leaves range decisions to the authoritative action.
 */
import { useMemo, useState } from "react";
import { useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Button, Icon, Toast } from "../kit";
import { Label, peopleAction, setHailFleetId, useToastState } from "./common";
import { CharacterCard, captainCanon } from "./CharacterCard";
import type { ScreenId } from "./ids";
import { navigate } from "../app/router";
import "./FleetPicker.css";

const SCREEN: ScreenId = "fleet_picker";

interface EncounterLike {
  id?: string;
  fleet_id?: string;
  captain_id?: string;
  role?: string;
  nation_id?: string;
  tier?: number;
  contact?: { x: number; y: number };
}

interface NpcFleetLike {
  id?: string;
  captain_id?: string;
  role?: string;
  nation_id?: string;
  position?: { x: number; y: number };
  marker_letter?: string;
  tier?: number;
}

function roleIcon(role: string): string {
  if (role === "treasure") return "treasure";
  if (role === "navy") return "role_patrol";
  return `role_${role}`;
}

interface PickerRow {
  fleetId: string;
  captainId: string;
  role: string;
  nationId: string;
  tier: number;
  letter: string;
}

export function FleetPicker() {
  const { state } = useGameState();
  const client = useGameClient();
  const { t, tKey, fmt } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const [cardFleet, setCardFleet] = useState<PickerRow | null>(null);
  const [statusKey, setStatusKey] = useState<string | null>(null);

  const encounter = (state.pending_encounter ?? {}) as EncounterLike;
  const fleets = state.npc_fleets as unknown as NpcFleetLike[];

  const rows = useMemo<PickerRow[]>(() => {
    const contact = encounter.contact;
    const sameTile = contact
      ? fleets.filter(
          (fleet) =>
            fleet.position?.x === contact.x && fleet.position?.y === contact.y,
        )
      : [];
    const source = sameTile.length > 0 ? sameTile : fleets;
    const fromFleets = source.map((fleet) => {
      const captainId = String(fleet.captain_id ?? "");
      const canon = captainId ? captainCanon(captainId) : undefined;
      return {
        fleetId: String(fleet.id ?? ""),
        captainId,
        role: String(fleet.role ?? canon?.role ?? ""),
        nationId: String(fleet.nation_id ?? canon?.nation_id ?? ""),
        tier: Number(fleet.tier ?? canon?.tier ?? 1),
        letter: String(fleet.marker_letter ?? ""),
      };
    });
    if (fromFleets.length > 0) return fromFleets;
    if (!encounter.id && !encounter.fleet_id) return [];
    const canon = encounter.captain_id ? captainCanon(encounter.captain_id) : undefined;
    return [
      {
        fleetId: String(encounter.id ?? encounter.fleet_id ?? ""),
        captainId: String(encounter.captain_id ?? ""),
        role: String(encounter.role ?? canon?.role ?? ""),
        nationId: String(encounter.nation_id ?? canon?.nation_id ?? ""),
        tier: Number(encounter.tier ?? canon?.tier ?? 1),
        letter: "",
      },
    ];
  }, [encounter, fleets]);

  const inspect = (row: PickerRow) => {
    if (!row.captainId) {
      setStatusKey("interact.unknown_name");
      return;
    }
    setCardFleet(row);
  };

  const attack = (row: PickerRow) => {
    if (!row.fleetId) return;
    void peopleAction(client, "attack", { fleet_id: row.fleetId }).then((result) => {
      if (!result.ok) {
        showToast(result.error.msg, undefined, "bad");
        return;
      }
      navigate("battle");
    });
  };

  const cardMode = cardFleet !== null;

  return (
    <div className="sa-screen picker" data-screen={SCREEN}>
      <div className="picker__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center picker__center">
        <div className="sa-window picker__window">
          <div className="picker__stack">
            <Label
              textKey={cardMode ? "dossier.title" : "interact.pick.title"}
              values={
                cardMode
                  ? {
                      name: cardFleet?.captainId
                        ? (() => {
                            const card = captainCanon(cardFleet.captainId);
                            return card ? t(card.name) : tKey("interact.unknown_name");
                          })()
                        : tKey("interact.unknown_name"),
                    }
                  : undefined
              }
              title
            />

            {cardMode && cardFleet ? (
              <>
                <div className="picker__body sa-scroll">
                  <CharacterCard kind="npc" personId={cardFleet.captainId} />
                </div>
                <Button textKey="ui.back" onClick={() => setCardFleet(null)} />
              </>
            ) : (
              <>
                <div className="picker__body sa-scroll">
                  <div className="sa-table">
                    {rows.map((row, index) => {
                      const card = row.captainId ? captainCanon(row.captainId) : undefined;
                      const name = card ? t(card.name) : tKey("interact.unknown_name");
                      return (
                        <div className="sa-row picker__row" key={`${row.fleetId}:${index}`}>
                          <span className="picker__flag" aria-hidden="true">
                            <span className={`sa-nation-swatch sa-nation-swatch--${row.nationId}`} />
                          </span>
                          <span className="picker__role" aria-hidden="true">
                            {row.role ? (
                              <Icon id={roleIcon(row.role)} />
                            ) : (
                              <span title={tKey("interact.pick.role_icon")} />
                            )}
                          </span>
                          <span className="picker__letter sa-cell sa-cell--center">{row.letter}</span>
                          <span className="picker__name sa-cell">
                            {fmt("interact.pick.row", { name, tier: row.tier })}
                          </span>
                          <span className="picker__tier">
                            <span className="sa-badge">{row.tier}</span>
                          </span>
                          <span className="picker__verb">
                            <Button
                              textKey="interact.verb.inspect"
                              compact
                              fill
                              onClick={() => inspect(row)}
                            />
                          </span>
                          <span className="picker__verb">
                            <Button
                              textKey="interact.verb.talk"
                              compact
                              fill
                              onClick={() => {
                                if (!row.fleetId) return;
                                setHailFleetId(row.fleetId);
                                navigate("hail");
                              }}
                            />
                          </span>
                          <span className="picker__verb">
                            {row.role !== "coaster" ? (
                              <Button
                                textKey="interact.verb.attack"
                                kind="danger"
                                compact
                                fill
                                disabled={state.current_port !== null}
                                onClick={() => attack(row)}
                              />
                            ) : null}
                          </span>
                        </div>
                      );
                    })}
                  </div>
                </div>
                <Label textKey={statusKey ?? undefined} tone="dim" />
              </>
            )}
          </div>
        </div>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
