/**
 * The at-sea hail modal (docs/80-UI-UX.md §4.10.2; the §4.9.1 message
 * window; docs/60-* §4.11.15).
 *
 * The option matrix (role × stance × skill), its gates and its prices are
 * server-built; the screen renders the rows and posts the frozen
 * `people/hail|talk|befriend` action. There is no `GET /api/view/hail`
 * projection yet (reported): the modal asks the read-only `people/hail`
 * action for the option list while a fleet is known, and otherwise derives
 * a disabled four-row display from the encounter/captain state it already
 * has. No chance, price or clamp is computed here.
 *
 * Composition (§4.9.1): a centered indigo Dialog over the dim layer —
 * captain portrait + title, the option buttons with their terms inline
 * (the §4.6.1 stepper for buy supplies), the result line and the close verb.
 */
import { useEffect, useMemo, useState } from "react";
import { useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import { Button, Dialog, Icon, Toast } from "../kit";
import { getHailFleetId, Label, peopleAction, useToastState } from "./common";
import { captainCanon } from "./CharacterCard";
import type { ScreenId } from "./ids";
import { navigate } from "../app/router";
import "./Hail.css";

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

  return (
    <div className="sa-screen hail" data-screen={SCREEN}>
      <div className="hail__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center hail__center">
        <Dialog className="hail__dialog" scroll>
          <div className="hail__stack">
            <div className="hail__head">
              <div className="hail__head_text">
                <Label
                  textKey="hail.title"
                  values={{ name: name ?? tKey("interact.unknown_name") }}
                  title
                  light
                />
                {resultKey ? <Label textKey={resultKey} /> : null}
              </div>
              {canon ? (
                <div className="hail__portrait" aria-hidden="true">
                  {portrait.map((sprite) => (
                    <Icon key={sprite} id={sprite} />
                  ))}
                </div>
              ) : null}
            </div>

            {rows.map((option) => (
              <div className="hail__option" key={option.id}>
                <Button
                  textKey={optionLabelKey(option.id)}
                  disabled={!option.enabled}
                  titleKey={option.reason_key}
                  fill
                  onClick={() => run(option)}
                />
                {option.id === "ask_rumours" && !option.intel ? null : (
                  <Label textKey={termsKey(option.id)} tone="dim" wrap />
                )}
                {option.id === "buy_supplies" ? (
                  <div className="hail__stepper">
                    <Button
                      text={MINUS}
                      kind="quiet"
                      compact
                      disabled={(option.max_qty ?? 0) <= 0}
                      onClick={() => setQty((value) => Math.max(0, value - 10))}
                    />
                    <Label textValue={String(qty)} align="center" className="hail__qty" />
                    <Button
                      text={PLUS}
                      kind="quiet"
                      compact
                      disabled={qty + 10 > (option.max_qty ?? 0)}
                      onClick={() => setQty((value) => Math.min(option.max_qty ?? value, value + 10))}
                    />
                    <Label
                      textValue={
                        option.unit_prices
                          ? fmt("ui.gold_amount", {
                              gold: qty * (option.unit_prices.provisions + option.unit_prices.water),
                            })
                          : ""
                      }
                      align="right"
                      className="hail__cost"
                    />
                  </div>
                ) : null}
              </div>
            ))}

            <Button
              textKey="ui.close"
              onClick={() => navigate(state.current_port ? "port" : "world")}
            />
          </div>
        </Dialog>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
