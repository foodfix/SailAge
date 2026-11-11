/**
 * S7 tavern — crew hire/fire, officer recruiting/roster, rumours and the
 * captains' table + sparring row. Every `tavern` element row is rendered;
 * `recruitable` / `rumors` / `table` are the declared list blocks.
 */
import { useEffect, useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CaptainTableRow, RecruitRow } from "../state/views";
import { Box, Element, ListRows, StackRows, type ScreenId } from "../layout";
import { Button, Icon, Toast, ValueBar } from "../kit";
import {
  ButtonEl,
  LabelEl,
  PanelEl,
  useScreenView,
  useToastState,
  ViewFallback,
} from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "tavern";
const MINUS = String.fromCharCode(0x2212);
const PLUS = String.fromCharCode(0x2b);

type Tab = "crew" | "officers" | "rumors";

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

  if (!view) return <ViewFallback screen={SCREEN} status={status} />;

  const portName = t(content.portName(view.portId));

  const recruitRow = (row: RecruitRow) => (
    <>
      <Box rect={{ x: 0, y: 0, w: 2, h: 4 }}>
        <Icon id={officerIcon(row.roleKey)} />
      </Box>
      <Box rect={{ x: 2, y: 0, w: 16, h: 1 }}>
        <span className="sa-cell sa-label--heading">{t(content.officerName(row.officerId))}</span>
      </Box>
      <Box rect={{ x: 18, y: 0, w: 12, h: 1 }}>
        <span className="sa-cell">{tKey(row.roleKey)}</span>
      </Box>
      <Box rect={{ x: 30, y: 0, w: 14, h: 1 }}>
        <span className="sa-cell">{fmt("tavern.wage", { price: row.wage })}</span>
      </Box>
      <Box rect={{ x: 2, y: 1, w: 24, h: 1 }}>
        <span className="sa-cell">
          {fmt("tavern.stats", {
            leadership: row.skills.leadership ?? 0,
            seamanship: row.skills.seamanship ?? 0,
            combat: row.skills.combat ?? 0,
            navigation: row.skills.navigation ?? 0,
          })}
        </span>
      </Box>
      <Box rect={{ x: 26, y: 1, w: 18, h: 1 }}>
        <span className="sa-cell">{fmt("tavern.signing_cost", { amount: row.signingFee })}</span>
      </Box>
      <Box rect={{ x: 46, y: 2, w: 12, h: 2 }}>
        <Button
          textKey="tavern.recruit"
          kind="primary"
          disabled={!row.canRecruit}
          fill
          onClick={() => {
            void client.tavern.recruit(row.officerId);
            showToast("tavern.recruited", { name: content.officerName(row.officerId) }, "good");
          }}
        />
      </Box>
    </>
  );

  const crewRow = (
    kind: "hire" | "fire",
    ids: { row: string; one: string; ten: string; third: string },
  ) => {
    const isHire = kind === "hire";
    const rowId = ids.row;
    return (
      <Element key={kind} screen={SCREEN} id={rowId} parent="crew">
        <ButtonEl
          screen={SCREEN}
          id={ids.one}
          parent={rowId}
          text={isHire ? fmt("tavern.hire", { qty: 1 }) : fmt("tavern.fire", { qty: 1 })}
          disabled={isHire ? !view.crew.canHire : view.crew.canFire === false}
          onClick={() => void (isHire ? client.tavern.hire(1) : client.tavern.fire(1))}
        />
        <ButtonEl
          screen={SCREEN}
          id={ids.ten}
          parent={rowId}
          text={isHire ? fmt("tavern.hire", { qty: 10 }) : fmt("tavern.fire", { qty: 10 })}
          disabled={isHire ? !view.crew.canHire : view.crew.canFire === false}
          onClick={() => void (isHire ? client.tavern.hire(10) : client.tavern.fire(10))}
        />
        <ButtonEl
          screen={SCREEN}
          id={ids.third}
          parent={rowId}
          textKey={isHire ? "tavern.fill" : "tavern.down_to_min"}
          disabled={isHire ? !view.crew.fillAvailable : view.crew.canFire === false}
          onClick={() => void (isHire ? client.tavern.fillCrew() : client.tavern.downToMin())}
        />
      </Element>
    );
  };

  return (
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <LabelEl
          screen={SCREEN}
          id="header.title"
          parent="header"
          textKey="tavern.title"
          values={{ port: portName }}
          title
        />
        <LabelEl
          screen={SCREEN}
          id="header.gold"
          parent="header"
          textKey="ui.gold_amount"
          values={{ gold: state.gold }}
          align="right"
        />
        <ButtonEl
          screen={SCREEN}
          id="header.back"
          parent="header"
          textKey="ui.back"
          onClick={() => navigate("port")}
        />
      </Element>

      <Element screen={SCREEN} id="tabs">
        <ButtonEl
          screen={SCREEN}
          id="tabs.crew"
          parent="tabs"
          textKey="tavern.crew_tab"
          kind={tab === "crew" ? "primary" : "default"}
          onClick={() => setTab("crew")}
        />
        <ButtonEl
          screen={SCREEN}
          id="tabs.officers"
          parent="tabs"
          textKey="tavern.officers_tab"
          kind={tab === "officers" ? "primary" : "default"}
          onClick={() => setTab("officers")}
        />
        <ButtonEl
          screen={SCREEN}
          id="tabs.rumors"
          parent="tabs"
          textKey="tavern.rumor_tab"
          kind={tab === "rumors" ? "primary" : "default"}
          onClick={() => setTab("rumors")}
        />
      </Element>

      <Element screen={SCREEN} id="body">
        <Element screen={SCREEN} id="crew" parent="body" hidden={tab !== "crew"}>
          <LabelEl
            screen={SCREEN}
            id="crew.count"
            parent="crew"
            textKey="tavern.crew_count"
            values={{ crew: view.crew.count, max: view.crew.max }}
          />
          <LabelEl
            screen={SCREEN}
            id="crew.morale"
            parent="crew"
            textKey="inn.morale"
            values={{ amount: view.crew.morale }}
          />
          <Element screen={SCREEN} id="crew.morale_bar" parent="crew">
            <ValueBar value={view.crew.morale} max={view.moraleMax} tier={view.moraleTier} />
          </Element>
          <LabelEl
            screen={SCREEN}
            id="crew.per_head"
            parent="crew"
            textKey="tavern.per_head"
            values={{ price: view.crew.perHead }}
            tone="dim"
          />
          {crewRow("hire", {
            row: "crew.hire_row",
            one: "crew.hire_row.hire_1",
            ten: "crew.hire_row.hire_10",
            third: "crew.hire_row.fill",
          })}
          {crewRow("fire", {
            row: "crew.fire_row",
            one: "crew.fire_row.fire_1",
            ten: "crew.fire_row.fire_10",
            third: "crew.fire_row.down_to_min",
          })}
          <LabelEl
            screen={SCREEN}
            id="crew.reason"
            parent="crew"
            textValue={view.crew.reasonKey ? tKey(view.crew.reasonKey) : ""}
            tone="warn"
          />
          <LabelEl
            screen={SCREEN}
            id="crew.min_note"
            parent="crew"
            textKey="tavern.crew_min_note"
            values={{ crew: view.crew.min }}
            tone="dim"
          />
        </Element>

        <Element screen={SCREEN} id="officers" parent="body" hidden={tab !== "officers"}>
          <Element screen={SCREEN} id="officers.recruitable_scroll" parent="officers" className="sa-scroll">
            <ListRows
              screen={SCREEN}
              listId="recruitable"
              count={view.recruitable.length}
              renderRow={(index) => recruitRow(view.recruitable[index])}
            />
          </Element>
          <LabelEl
            screen={SCREEN}
            id="officers.roster_header"
            parent="officers"
            textKey="char.officers"
            heading
          />
          <Element screen={SCREEN} id="officers.roster_scroll" parent="officers" className="sa-scroll">
            <StackRows
              count={view.roster.length}
              renderRow={(index) => {
                const row = view.roster[index];
                return (
                  <>
                    <Box rect={{ x: 0, y: 0, w: 20, h: 1 }}>
                      <span className="sa-cell">{t(content.officerName(row.officerId))}</span>
                    </Box>
                    <Box rect={{ x: 20, y: 0, w: 12, h: 1 }}>
                      <span className="sa-cell">{tKey(row.roleKey)}</span>
                    </Box>
                    <Box rect={{ x: 32, y: 0, w: 14, h: 1 }}>
                      <span className="sa-cell">{fmt("tavern.wage", { price: row.wage })}</span>
                    </Box>
                    <Box rect={{ x: 48, y: 0, w: 10, h: 1 }}>
                      <Button
                        textKey="tavern.dismiss"
                        disabled={!(row.canDismiss ?? row.canRecruit)}
                        fill
                        onClick={() => void client.tavern.dismiss(row.officerId)}
                      />
                    </Box>
                  </>
                );
              }}
            />
          </Element>
          <LabelEl
            screen={SCREEN}
            id="officers.roster.empty"
            parent="officers"
            textKey="char.no_officers"
            hidden={view.roster.length > 0}
          />
          <LabelEl screen={SCREEN} id="officers.reason" parent="officers" />
        </Element>

        <Element screen={SCREEN} id="rumors" parent="body" hidden={tab !== "rumors"}>
          <LabelEl
            screen={SCREEN}
            id="rumors.tournament"
            parent="rumors"
            textValue={view.rumors.tournament ? t(view.rumors.tournament) : ""}
            tone="accent"
          />
          <LabelEl
            screen={SCREEN}
            id="rumors.price"
            parent="rumors"
            textKey="tavern.rumor.price"
            values={{ gold: view.rumors.price }}
            tone="dim"
          />
          <Element screen={SCREEN} id="rumors.scroll" parent="rumors" className="sa-scroll">
            <ListRows
              screen={SCREEN}
              listId="rumors"
              count={view.rumors.rows.length + view.investments.length}
              renderRow={(index) => {
                if (index >= view.rumors.rows.length) {
                  const invest = view.investments[index - view.rumors.rows.length];
                  return (
                    <Box rect={{ x: 0, y: 0, w: 58, h: 2 }}>
                      <span className="sa-cell sa-label--accent">
                        {fmt("tavern.invest.row", {
                          nation: content.nationName(invest.nationId),
                          amount: invest.amount,
                          port: content.portName(invest.portId),
                        })}
                      </span>
                    </Box>
                  );
                }
                const rumor = view.rumors.rows[index];
                return (
                  <>
                    <Box rect={{ x: 0, y: 0, w: 46, h: 2 }}>
                      <span className={rumor.purchasable === false ? "sa-cell sa-label--dim" : "sa-cell"}>
                        {t(rumor.text)}
                      </span>
                    </Box>
                    {rumor.purchasable === false ? null : (
                      <Box rect={{ x: 46, y: 0, w: 12, h: 2 }}>
                        <Button
                          textKey={rumor.known ? "tavern.rumor.bought" : "tavern.rumor.buy"}
                          disabled={rumor.known}
                          fill
                          onClick={() => void client.tavern.buyRumor(rumor.id)}
                        />
                      </Box>
                    )}
                  </>
                );
              }}
            />
          </Element>
          <LabelEl
            screen={SCREEN}
            id="rumors.empty"
            parent="rumors"
            textKey="tavern.rumor.none"
            hidden={view.rumors.rows.length > 0 || view.investments.length > 0}
          />
        </Element>

        <Element screen={SCREEN} id="captains_table" parent="body">
          <LabelEl
            screen={SCREEN}
            id="captains_table.header"
            parent="captains_table"
            textKey="captain.table.title"
            heading
          />
          <ListRows
            screen={SCREEN}
            listId="table"
            count={view.captains.length}
            renderRow={(index) => {
              const captain = view.captains[index];
              return (
                <>
                  <Box rect={{ x: 0, y: 0, w: 2, h: 2 }}>
                    <Icon id={captainIcon(captain)} />
                  </Box>
                  <Box rect={{ x: 2, y: 0, w: 20, h: 2 }}>
                    <span className="sa-cell">{t(captain.name)}</span>
                  </Box>
                  <Box rect={{ x: 22, y: 0, w: 15, h: 2 }}>
                    <span className="sa-cell">{tKey(captain.roleKey)}</span>
                  </Box>
                  <Box rect={{ x: 37, y: 0, w: 5, h: 2 }}>
                    <span className="sa-cell">
                      {`${tKey("captain.table.tier")} ${captain.tier}`}
                    </span>
                  </Box>
                  <Box rect={{ x: 42, y: 0, w: 16, h: 2 }}>
                    <span className="sa-cell sa-label--dim">
                      {fmt("captain.table.last_seen", { day: captain.lastSeenDay })}
                    </span>
                  </Box>
                </>
              );
            }}
          />
        </Element>

        <Element screen={SCREEN} id="spar" parent="body">
          <LabelEl screen={SCREEN} id="spar.header" parent="spar" textKey="tavern.spar.title" heading />
          <LabelEl
            screen={SCREEN}
            id="spar.terms"
            parent="spar"
            textKey="tavern.spar.stake"
            values={{ gold: stake, pct: view.spar.winPct }}
          />
          <LabelEl screen={SCREEN} id="spar.result" parent="spar" />
          <ButtonEl
            screen={SCREEN}
            id="spar.controls.stake_down"
            parent="spar"
            text={MINUS}
            onClick={() => setStake((value) => Math.max(0, value - view.spar.step))}
          />
          <ButtonEl
            screen={SCREEN}
            id="spar.controls.stake_up"
            parent="spar"
            text={PLUS}
            onClick={() => setStake((value) => value + view.spar.step)}
          />
          <ButtonEl
            screen={SCREEN}
            id="spar.controls.bet"
            parent="spar"
            textKey="tavern.spar.go"
            kind="primary"
            disabled={stake <= 0 || view.spar.canSpar === false}
            onClick={() => void client.tavern.spar(stake)}
          />
        </Element>
      </Element>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
