/**
 * S7 tavern — the UW2 room window (80-* §4.9.1): a toolbar row (back /
 * title / gold), the tab strip (crew / officers / rumours) over framed
 * panels, the captains' table section and the sparring row.
 */
import { useEffect, useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CaptainTableRow, RecruitRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Frame, Icon, Row, Toast, ValueBar } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./TavernScreen.css";

const SCREEN: ScreenId = "tavern";
const MINUS = String.fromCharCode(0x2212);
const PLUS = String.fromCharCode(0x2b);

type Tab = "crew" | "officers" | "rumors";

const TAB_KEYS: Record<Tab, string> = {
  crew: "tavern.crew_tab",
  officers: "tavern.officers_tab",
  rumors: "tavern.rumor_tab",
};

function officerIcon(roleKey: string): string {
  if (roleKey.endsWith(".navigator")) return "compass";
  if (roleKey.endsWith(".boatswain")) return "crew";
  if (roleKey.endsWith(".gunner")) return "cannon";
  return "scroll";
}

function captainIcon(captain: CaptainTableRow): string {
  if (captain.roleKey.endsWith(".pirate")) return "role_pirate";
  if (captain.roleKey.endsWith(".patrol")) return "role_patrol";
  if (captain.roleKey.endsWith(".courier")) return "role_courier";
  return "role_trader";
}

export function TavernScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("tavern");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [tab, setTab] = useState<Tab>("crew");
  const [stake, setStake] = useState<number>(view?.spar.stake ?? 0);

  useEffect(() => {
    if (!view) return;
    setStake((current) => (current > 0 ? current : view.spar.stake));
  }, [view]);

  if (!view) return <ViewFallback status={status} />;

  const portName = t(content.portName(view.portId));

  const recruitRow = (row: RecruitRow) => (
    <Row
      key={row.officerId}
      height={104}
      cols={[
        <div className="tavern__recruit">
          <div className="tavern__line">
            <span className="tavern__icon">
              <Icon id={officerIcon(row.roleKey)} />
            </span>
            <div className="sa-cell sa-label--heading">{t(content.officerName(row.officerId))}</div>
            <div className="sa-cell sa-grow">{tKey(row.roleKey)}</div>
            <div className="sa-cell sa-cell--right">{fmt("tavern.wage", { price: row.wage })}</div>
          </div>
          <div className="tavern__line">
            <div className="sa-cell sa-grow">
              {fmt("tavern.stats", {
                leadership: row.skills.leadership ?? 0,
                seamanship: row.skills.seamanship ?? 0,
                combat: row.skills.combat ?? 0,
                navigation: row.skills.navigation ?? 0,
              })}
            </div>
            <div className="sa-cell">{fmt("tavern.signing_cost", { amount: row.signingFee })}</div>
          </div>
          <div className="tavern__line">
            <div className="sa-grow" />
            <Button
              compact
              textKey="tavern.recruit"
              kind="primary"
              disabled={!row.canRecruit}
              onClick={() => {
                void client.tavern.recruit(row.officerId);
                showToast("tavern.recruited", { name: content.officerName(row.officerId) }, "good");
              }}
            />
          </div>
        </div>,
      ]}
    />
  );

  const crewRow = (kind: "hire" | "fire") => {
    const isHire = kind === "hire";
    return (
      <div key={kind} className="tavern__actions">
        <Button
          text={isHire ? fmt("tavern.hire", { qty: 1 }) : fmt("tavern.fire", { qty: 1 })}
          disabled={isHire ? !view.crew.canHire : view.crew.canFire === false}
          onClick={() => void (isHire ? client.tavern.hire(1) : client.tavern.fire(1))}
        />
        <Button
          text={isHire ? fmt("tavern.hire", { qty: 10 }) : fmt("tavern.fire", { qty: 10 })}
          disabled={isHire ? !view.crew.canHire : view.crew.canFire === false}
          onClick={() => void (isHire ? client.tavern.hire(10) : client.tavern.fire(10))}
        />
        <Button
          textKey={isHire ? "tavern.fill" : "tavern.down_to_min"}
          disabled={isHire ? !view.crew.fillAvailable : view.crew.canFire === false}
          onClick={() => void (isHire ? client.tavern.fillCrew() : client.tavern.downToMin())}
        />
      </div>
    );
  };

  return (
    <div className="sa-screen tavern" data-screen={SCREEN}>
      <div className="tavern__page sa-col">
        <div className="tavern__header sa-plate">
          <div className="tavern__header_line">
            <Button textKey="ui.back" onClick={() => navigate("port")} />
            <Label textKey="tavern.title" values={{ port: portName }} title />
            <div className="sa-grow" />
            <Label textKey="ui.gold_amount" values={{ gold: state.gold }} />
          </div>
        </div>

        <Frame className="tavern__window sa-grow">
          <div className="tavern__body">
            <div className="sa-tabs">
              {(Object.keys(TAB_KEYS) as Tab[]).map((id) => (
                <button
                  key={id}
                  type="button"
                  className="sa-tab"
                  data-active={tab === id ? "true" : "false"}
                  onClick={() => setTab(id)}
                >
                  {tKey(TAB_KEYS[id])}
                </button>
              ))}
            </div>

            {tab === "crew" ? (
              <div className="tavern__panel">
                <div className="tavern__pair">
                  <Label textKey="tavern.crew_count" values={{ crew: view.crew.count, max: view.crew.max }} />
                  <Label textKey="inn.morale" values={{ amount: view.crew.morale }} />
                </div>
                <div className="tavern__bar">
                  <ValueBar value={view.crew.morale} max={view.moraleMax} tier={view.moraleTier} />
                </div>
                <Label textKey="tavern.per_head" values={{ price: view.crew.perHead }} tone="dim" />
                {crewRow("hire")}
                {crewRow("fire")}
                <Label textValue={view.crew.reasonKey ? tKey(view.crew.reasonKey) : ""} tone="warn" />
                <Label textKey="tavern.crew_min_note" values={{ crew: view.crew.min }} tone="dim" />
              </div>
            ) : null}

            {tab === "officers" ? (
              <div className="tavern__panel">
                <div className="sa-scroll tavern__recruit_rows">
                  <div className="sa-table">
                    {view.recruitable.map((row) => recruitRow(row))}
                  </div>
                </div>
                <Label textKey="char.officers" heading />
                <div className="sa-scroll tavern__roster_rows">
                  <div className="sa-table tavern__table_roster">
                    {view.roster.map((row) => (
                      <Row
                        key={row.officerId}
                        cols={[
                          <div className="sa-cell">{t(content.officerName(row.officerId))}</div>,
                          <div className="sa-cell">{tKey(row.roleKey)}</div>,
                          <div className="sa-cell">{fmt("tavern.wage", { price: row.wage })}</div>,
                          <Button
                            compact
                            fill
                            textKey="tavern.dismiss"
                            disabled={!(row.canDismiss ?? row.canRecruit)}
                            onClick={() => void client.tavern.dismiss(row.officerId)}
                          />,
                        ]}
                      />
                    ))}
                  </div>
                </div>
                {view.roster.length === 0 ? <Label textKey="char.no_officers" /> : null}
              </div>
            ) : null}

            {tab === "rumors" ? (
              <div className="tavern__panel">
                <Label
                  textValue={view.rumors.tournament ? t(view.rumors.tournament) : ""}
                  tone="accent"
                />
                <Label textKey="tavern.rumor.price" values={{ gold: view.rumors.price }} tone="dim" />
                <div className="sa-scroll tavern__rumor_rows">
                  <div className="sa-table tavern__table_rumors">
                    {view.rumors.rows.map((rumor) => (
                      <Row
                        key={rumor.id}
                        cols={[
                          <div className={`sa-cell${rumor.purchasable === false ? " sa-label--dim" : ""}`}>
                            {t(rumor.text)}
                          </div>,
                          rumor.purchasable === false ? (
                            <div className="sa-cell" />
                          ) : (
                            <Button
                              compact
                              fill
                              textKey={rumor.known ? "tavern.rumor.bought" : "tavern.rumor.buy"}
                              disabled={rumor.known}
                              onClick={() => void client.tavern.buyRumor(rumor.id)}
                            />
                          ),
                        ]}
                      />
                    ))}
                    {view.investments.map((invest, index) => (
                      <Row
                        key={`invest_${index}`}
                        cols={[
                          <div className="sa-cell sa-label--accent">
                            {fmt("tavern.invest.row", {
                              nation: content.nationName(invest.nationId),
                              amount: invest.amount,
                              port: content.portName(invest.portId),
                            })}
                          </div>,
                          <div className="sa-cell" />,
                        ]}
                      />
                    ))}
                  </div>
                </div>
                {view.rumors.rows.length === 0 && view.investments.length === 0 ? (
                  <Label textKey="tavern.rumor.none" />
                ) : null}
              </div>
            ) : null}

            <div className="tavern__caps">
              <Label textKey="captain.table.title" heading />
              <div className="sa-scroll tavern__caps_rows">
                <div className="sa-table tavern__table_caps">
                  {view.captains.map((captain) => (
                    <Row
                      key={captain.id}
                      cols={[
                        <span className="tavern__icon">
                          <Icon id={captainIcon(captain)} />
                        </span>,
                        <div className="sa-cell">{t(captain.name)}</div>,
                        <div className="sa-cell">{tKey(captain.roleKey)}</div>,
                        <div className="sa-cell">{`${tKey("captain.table.tier")} ${captain.tier}`}</div>,
                        <div className="sa-cell sa-label--dim">
                          {fmt("captain.table.last_seen", { day: captain.lastSeenDay })}
                        </div>,
                      ]}
                    />
                  ))}
                </div>
              </div>
            </div>

            <div className="tavern__spar">
              <Label textKey="tavern.spar.title" heading />
              <div className="tavern__line">
                <Label textKey="tavern.spar.stake" values={{ gold: stake, pct: view.spar.winPct }} />
                <div className="sa-grow" />
                <Button text={MINUS} onClick={() => setStake((value) => Math.max(0, value - view.spar.step))} />
                <Button text={PLUS} onClick={() => setStake((value) => value + view.spar.step)} />
                <Button
                  textKey="tavern.spar.go"
                  kind="primary"
                  disabled={stake <= 0 || view.spar.canSpar === false}
                  onClick={() => void client.tavern.spar(stake)}
                />
              </div>
            </div>
          </div>
        </Frame>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
