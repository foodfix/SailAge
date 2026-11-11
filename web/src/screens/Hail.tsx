/**
 * The at-sea hail modal (docs/80-UI-UX.md §4.10.2; docs/60-* §4.11.15).
 *
 * The option matrix (role × stance × skill), its gates and its prices are
 * server-built; the screen renders the rows and posts the frozen
 * `people/hail|talk|befriend` action. There is no `GET /api/view/hail`
 * projection yet (reported): the modal asks the read-only `people/hail`
 * action for the option list while a fleet is known, and otherwise derives
 * a disabled four-row display from the encounter/captain state it already
 * has. No chance, price or clamp is computed here.
 */
import { useEffect, useMemo, useState } from "react";
import { useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Button, Icon, Toast } from "../kit";
import { ButtonEl, getHailFleetId, LabelEl, PanelEl, peopleAction, useToastState } from "./common";
import { captainCanon } from "./CharacterCard";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "hail";
const PLUS = String.fromCharCode(0x2b);
const MINUS = String.fromCharCode(0x2212);

interface HailOption {
  id: string;
  enabled: boolean;
  reason_key?: string;
  intel?: boolean;
  unit_prices?: { provisions: number; water: number };
  max_qty?: number;
  chance?: number;
}

interface EncounterLike {
  id?: string;
  fleet_id?: string;
  captain_id?: string;
  role?: string;
  nation_id?: string;
}

function optionLabelKey(id: string): string {
  if (id === "ask_rumours") return "hail.option.rumours";
  if (id === "buy_supplies") return "hail.option.supplies";
  if (id === "intimidate") return "hail.option.intimidate";
  return "hail.option.befriend";
}

const ACTION_IDS: Record<string, string> = {
  ask_rumours: "rows.ask_rumours.action",
  buy_supplies: "rows.buy_supplies.action",
  intimidate: "rows.intimidate.action",
  befriend: "rows.befriend.action",
};

function termsKey(id: string): string {
  if (id === "ask_rumours") return "hail.rumours.intel_terms";
  if (id === "buy_supplies") return "hail.supplies.terms";
  if (id === "intimidate") return "hail.intimidate.terms";
  return "hail.befriend.terms";
}

export function Hail({ fleetId }: { fleetId?: string }) {
  const { state } = useGameState();
  const client = useGameClient();
  const { t, tKey, fmt } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const encounter = (state.pending_encounter ?? {}) as EncounterLike;
  const knownFleet = useMemo(() => {
    if (fleetId) return fleetId;
    const handedOff = getHailFleetId();
    if (handedOff) return handedOff;
    if (encounter.id) return encounter.id;
    if (encounter.fleet_id) return encounter.fleet_id;
    const first = state.npc_fleets[0];
    return first ? String(first.id ?? "") : "";
  }, [fleetId, encounter.id, encounter.fleet_id, state.npc_fleets]);
  const [options, setOptions] = useState<HailOption[] | null>(null);
  const [name, setName] = useState<string | null>(null);
  const [qty, setQty] = useState(10);
  const [resultKey, setResultKey] = useState<string | null>(null);

  useEffect(() => {
    if (!knownFleet) {
      setOptions([]);
      return;
    }
    let live = true;
    void peopleAction<{ name?: unknown; options?: HailOption[] }>(client, "hail", {
      fleet_id: knownFleet,
    }).then((result) => {
      if (!live) return;
      if (result.ok && Array.isArray(result.options)) {
        setOptions(result.options);
        const display = result.name as { zh?: string; en?: string } | undefined;
        setName(display ? t({ zh: display.zh ?? "", en: display.en ?? "" }) : null);
      } else {
        setOptions([]);
      }
    });
    return () => {
      live = false;
    };
  }, [client, knownFleet, t]);

  const fallback: HailOption[] = [
    { id: "ask_rumours", enabled: false, reason_key: "ui.not_available" },
    { id: "buy_supplies", enabled: false, reason_key: "ui.not_available" },
    { id: "intimidate", enabled: false, reason_key: "ui.not_available" },
    { id: "befriend", enabled: false, reason_key: "ui.not_available" },
  ];
  const rows = options === null ? [] : options.length > 0 ? options : fallback;

  const applyResult = (payload: unknown) => {
    if (!payload || typeof payload !== "object") return;
    const lines = (payload as { lines?: { key?: string; values?: Record<string, unknown> }[] }).lines;
    const first = lines?.[0];
    if (first?.key) {
      setResultKey(first.key);
      showToast(first.key, first.values as Record<string, string | number> | undefined, "good");
    }
  };

  const run = (option: HailOption) => {
    if (!knownFleet || !option.enabled) return;
    const verb = option.id === "befriend" ? "befriend" : "talk";
    void peopleAction<{ result?: unknown }>(client, verb, {
      fleet_id: knownFleet,
      ...(verb === "talk" ? { option_id: option.id } : {}),
      ...(option.id === "buy_supplies" ? { qty } : {}),
    }).then((result) => {
      if (!result.ok) {
        showToast(result.error.msg, undefined, "bad");
        return;
      }
      applyResult(result.result);
      if (option.id === "buy_supplies") setResultKey("hail.supplies.result");
    });
  };

  const captainId = encounter.captain_id
    ?? String((state.npc_fleets[0] as { captain_id?: string } | undefined)?.captain_id ?? "");
  const canon = captainId ? captainCanon(captainId) : undefined;
  const cloth = canon?.role ? `pp_cloth_${canon.role}` : "pp_cloth_trader";
  const portrait = ["pp_base", cloth];

  const rowModels: { kind: "portrait" | "option" | "terms"; option?: HailOption; hidden?: boolean }[] = [
    { kind: "portrait" },
  ];
  for (const option of rows) {
    rowModels.push({ kind: "option", option });
    rowModels.push({ kind: "terms", option, hidden: option.id === "ask_rumours" && !option.intel });
  }

  return (
    <div className="sa-screen">
      <PanelEl screen={SCREEN} id="dim" skin="backdrop" className="sa-dim" />
      <PanelEl screen={SCREEN} id="panel" skin="panel">
        <LabelEl
          screen={SCREEN}
          id="panel.title"
          parent="panel"
          textKey="hail.title"
          values={{ name: name ?? tKey("interact.unknown_name") }}
          title
        />
        <Box rect={{ x: 1, y: 1, w: 13, h: 12 }} className="sa-scroll">
          <ListRows
            screen={SCREEN}
            listId="rows"
            count={rowModels.length}
            renderRow={(index) => {
              const model = rowModels[index];
              if (!model) return null;
              if (model.kind === "portrait") {
                return (
                  <Element screen={SCREEN} id="rows.portrait.bust" hidden={!canon}>
                    {portrait.map((sprite) => (
                      <Box key={sprite} rect={{ x: 0, y: 0, w: 2, h: 2 }}>
                        <Icon id={sprite} />
                      </Box>
                    ))}
                  </Element>
                );
              }
              const option = model.option;
              if (!option) return null;
              if (model.kind === "terms") {
                const termsId = option.id === "ask_rumours"
                  ? "rows.terms_rumours.terms"
                  : option.id === "buy_supplies"
                    ? "rows.terms_supplies.terms"
                    : option.id === "befriend"
                      ? "rows.terms_befriend.terms"
                      : "";
                if (!termsId) {
                  return (
                    <span className="sa-cell sa-label--dim">{tKey(termsKey(option.id))}</span>
                  );
                }
                return (
                  <Element screen={SCREEN} id={termsId} hidden={model.hidden}>
                    <span className="sa-cell sa-label--dim">{tKey(termsKey(option.id))}</span>
                  </Element>
                );
              }
              return (
                <>
                  <Element screen={SCREEN} id={ACTION_IDS[option.id] ?? "rows.ask_rumours.action"}>
                    <Button
                      textKey={optionLabelKey(option.id)}
                      disabled={!option.enabled}
                      titleKey={option.reason_key}
                      fill
                      onClick={() => run(option)}
                    />
                  </Element>
                  {option.id === "buy_supplies" ? (
                    <>
                      <Element screen={SCREEN} id="rows.buy_supplies.minus">
                        <Button
                          text={MINUS}
                          kind="quiet"
                          disabled={(option.max_qty ?? 0) <= 0}
                          fill
                          onClick={() => setQty((value) => Math.max(0, value - 10))}
                        />
                      </Element>
                      <Element screen={SCREEN} id="rows.buy_supplies.qty">
                        <span className="sa-cell sa-label--center">{qty}</span>
                      </Element>
                      <Element screen={SCREEN} id="rows.buy_supplies.plus">
                        <Button
                          text={PLUS}
                          kind="quiet"
                          disabled={qty + 10 > (option.max_qty ?? 0)}
                          fill
                          onClick={() => setQty((value) => Math.min(option.max_qty ?? value, value + 10))}
                        />
                      </Element>
                      <Element screen={SCREEN} id="rows.buy_supplies.cost">
                        <span className="sa-cell sa-label--right">
                          {option.unit_prices
                            ? fmt("ui.gold_amount", {
                                gold: qty * (option.unit_prices.provisions + option.unit_prices.water),
                              })
                            : ""}
                        </span>
                      </Element>
                    </>
                  ) : null}
                </>
              );
            }}
          />
        </Box>
        {resultKey ? (
          <Box rect={{ x: 1, y: 13, w: 9, h: 1 }}>
            <span className="sa-cell">{tKey(resultKey)}</span>
          </Box>
        ) : null}
        <ButtonEl
          screen={SCREEN}
          id="panel.ok"
          parent="panel"
          textKey="ui.close"
          onClick={() => navigate(state.current_port ? "port" : "world")}
        />
      </PanelEl>
      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
