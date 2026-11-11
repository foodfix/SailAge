/**
 * The right-click fleet picker (docs/80-UI-UX.md §4.10.1).
 *
 * One row per fleet on the contacted tile: flag, role letter, identified
 * name, tier, and the inspect / talk / attack verbs. `inspect` opens the
 * §4.12 card in place; `talk` opens the hail; `attack` posts the frozen
 * `people/attack` funnel; a coaster row renders no attack verb.
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
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Button, Icon, Toast } from "../kit";
import { LabelEl, PanelEl, peopleAction, setHailFleetId, useToastState } from "./common";
import { CharacterCard, captainCanon } from "./CharacterCard";
import type { ReactNode } from "react";
import { navigate } from "../app/router";

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

const ROW_IDS: Record<number, Record<string, string>> = {
  0: {
    flag: "fleet_rows.0.flag",
    role: "fleet_rows.0.role",
    role_letter: "fleet_rows.0.role_letter",
    name: "fleet_rows.0.name",
    tier: "fleet_rows.0.tier",
    "verb.inspect": "fleet_rows.0.verb.inspect",
    "verb.talk": "fleet_rows.0.verb.talk",
    "verb.attack": "fleet_rows.0.verb.attack",
  },
  1: {
    flag: "fleet_rows.1.flag",
    role: "fleet_rows.1.role",
    role_letter: "fleet_rows.1.role_letter",
    name: "fleet_rows.1.name",
    tier: "fleet_rows.1.tier",
    "verb.inspect": "fleet_rows.1.verb.inspect",
    "verb.talk": "fleet_rows.1.verb.talk",
    "verb.attack": "fleet_rows.1.verb.attack",
  },
};

const ROW_CELLS: Record<string, { x: number; y: number; w: number; h: number }> = {
  flag: { x: 0, y: 0, w: 1, h: 1 },
  role: { x: 1, y: 0, w: 1, h: 1 },
  role_letter: { x: 0, y: 0, w: 1, h: 1 },
  name: { x: 2, y: 0, w: 4, h: 1 },
  tier: { x: 6, y: 0, w: 1, h: 1 },
  "verb.inspect": { x: 7, y: 0, w: 3, h: 2 },
  "verb.talk": { x: 10, y: 0, w: 3, h: 2 },
  "verb.attack": { x: 13, y: 0, w: 3, h: 2 },
};

function roleIcon(role: string): string {
  if (role === "treasure") return "treasure";
  if (role === "navy") return "role_patrol";
  return `role_${role}`;
}

function Cell({ index, part, children }: { index: number; part: string; children: ReactNode }) {
  const rect = ROW_CELLS[part];
  if (index <= 1) {
    return (
      <Element screen={SCREEN} id={ROW_IDS[index][part]}>
        {children}
      </Element>
    );
  }
  return <Box rect={rect}>{children}</Box>;
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
    <div className="sa-screen">
      <PanelEl screen={SCREEN} id="dim" skin="backdrop" className="sa-dim" />
      <PanelEl screen={SCREEN} id="panel" skin="panel">
        <LabelEl
          screen={SCREEN}
          id="panel.title"
          parent="panel"
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
            <Box rect={{ x: 1, y: 1, w: 16, h: 11 }} className="sa-scroll">
              <CharacterCard kind="npc" personId={cardFleet.captainId} />
            </Box>
            <Box rect={{ x: 1, y: 11, w: 16, h: 2 }}>
              <Button textKey="ui.back" fill onClick={() => setCardFleet(null)} />
            </Box>
          </>
        ) : (
          <Box rect={{ x: 1, y: 1, w: 16, h: 8 }} className="sa-scroll">
            <ListRows
              screen={SCREEN}
              listId="fleet_rows"
              count={rows.length}
              renderRow={(index) => {
                const row = rows[index];
                if (!row) return null;
                const card = row.captainId ? captainCanon(row.captainId) : undefined;
                const name = card ? t(card.name) : tKey("interact.unknown_name");
                return (
                  <>
                    <Cell index={index} part="flag">
                      <span
                        className={`sa-nation-swatch sa-nation-swatch--${row.nationId}`}
                        aria-hidden="true"
                      />
                    </Cell>
                    <Cell index={index} part="role">
                      {row.role ? (
                        <Icon id={roleIcon(row.role)} />
                      ) : (
                        <span className="sa-cell" title={tKey("interact.pick.role_icon")} />
                      )}
                    </Cell>
                    <Cell index={index} part="role_letter">
                      <span className="sa-cell sa-label--center">{row.letter}</span>
                    </Cell>
                    <Cell index={index} part="name">
                      <span className="sa-cell">{fmt("interact.pick.row", { name, tier: row.tier })}</span>
                    </Cell>
                    <Cell index={index} part="tier">
                      <span className="sa-badge">{row.tier}</span>
                    </Cell>
                    <Cell index={index} part="verb.inspect">
                      <Button
                        textKey="interact.verb.inspect"
                        fill
                        onClick={() => inspect(row)}
                      />
                    </Cell>
                    <Cell index={index} part="verb.talk">
                      <Button
                        textKey="interact.verb.talk"
                        fill
                        onClick={() => {
                          if (!row.fleetId) return;
                          setHailFleetId(row.fleetId);
                          navigate("hail");
                        }}
                      />
                    </Cell>
                    {row.role !== "coaster" ? (
                      <Cell index={index} part="verb.attack">
                        <Button
                          textKey="interact.verb.attack"
                          kind="danger"
                          disabled={state.current_port !== null}
                          fill
                          onClick={() => attack(row)}
                        />
                      </Cell>
                    ) : null}
                  </>
                );
              }}
            />
          </Box>
        )}
        <LabelEl
          screen={SCREEN}
          id="panel.status"
          parent="panel"
          textKey={statusKey ?? undefined}
          tone="dim"
        />
      </PanelEl>
      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
