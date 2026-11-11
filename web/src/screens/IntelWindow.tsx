/**
 * The intel window (docs/80-UI-UX.md §4.5, §4.5.1, §4.6.2, §4.12.3; the
 * §4.9.1 composition) — one parchment window centered over the dim layer,
 * hosting the six tabs: 船长 / 声望 / 官员 / 船队 / 海图 (an action, not a
 * page) / 委托. The `.sa-tabs` strip carries the active tab; the window
 * body below it renders the active tab's table/panels. The four
 * person/fleet tabs are embeddable components and are also standalone
 * routes (the M6-c slice).
 *
 * Missing server projections (reported): the four tab bodies carry their
 * own gaps (fleet_view, officer_roster, captain_view); the quest tab uses
 * the `guild` projection's active list when it is available and otherwise
 * renders the raw `state.active_quests` rows. The quest-slot max is not
 * projected, so the slot line shows the used count with `ui.not_available`.
 */
import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { CommissionRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Row } from "../kit";
import { Label, useFetchedView } from "./common";
import { CaptainView } from "./CaptainView";
import { FleetView } from "./FleetView";
import { OfficerRoster } from "./OfficerRoster";
import { ReputationView } from "./ReputationView";
import { navigate } from "../app/router";
import "./IntelWindow.css";

const SCREEN: ScreenId = "intel_window";

type Tab = "captain" | "reputation" | "officers" | "fleet" | "quests";

const TAB_IDS: { tab: Tab; id: string; labelKey: string }[] = [
  { tab: "captain", id: "tabs.captain", labelKey: "char.title" },
  { tab: "reputation", id: "tabs.reputation", labelKey: "char.reputation" },
  { tab: "officers", id: "tabs.officers", labelKey: "officers.title" },
  { tab: "fleet", id: "tabs.fleet", labelKey: "fleet.title" },
  { tab: "quests", id: "tabs.quests", labelKey: "char.quests" },
];

export function IntelWindow() {
  const { state } = useGameState();
  const client = useGameClient();
  const { tKey, fmt } = useI18n();
  const [tab, setTab] = useState<Tab>("captain");
  const { view: guild } = useFetchedView("guild");

  const close = () => navigate(state.current_port ? "port" : "world");

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close();
        return;
      }
      const key = event.key.toLowerCase();
      if (key === "c") setTab("captain");
      else if (key === "o") setTab("officers");
      else if (key === "f") setTab("fleet");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const quests: CommissionRow[] = guild?.active ?? [];
  const rawQuests = state.active_quests;

  const questCount = quests.length > 0 ? quests.length : rawQuests.length;

  const questRow = (index: number) => {
    const projected = quests[index];
    const raw = rawQuests[index];
    const tagKey = projected
      ? `quest.type.${projected.type}`
      : raw
        ? `quest.type.${String(raw.type)}`
        : "char.quests";
    const objective = projected?.lineKey
      ? fmt(projected.lineKey, projected.lineValues)
      : tKey("ui.not_available");
    const days = projected?.daysLeft
      ?? (raw ? Math.max(0, Number(raw.deadline_day ?? 0) - state.day) : 0);
    const instanceId = projected?.id ?? (raw ? String(raw.id) : "");
    return (
      <Row key={instanceId !== "" ? `${index}_${instanceId}` : index} cols={[
        <div className="sa-cell sa-label--accent">{tKey(tagKey)}</div>,
        <div className="sa-cell">{objective}</div>,
        <div className="sa-cell sa-cell--right">{fmt("quest.days_left", { days })}</div>,
        <div className="sa-cell sa-label--dim"> </div>,
        <Button
          textKey="quest.abandon"
          kind="danger"
          disabled={!instanceId || state.current_port === null}
          titleKey={state.current_port === null ? "fleet.port_only" : undefined}
          fill
          compact
          onClick={() => {
            void client.action("guild", "abandon", {
              instance_id: instanceId,
            });
          }}
        />,
      ]} />
    );
  };

  return (
    <div className="sa-screen intel" data-screen={SCREEN}>
      <div className="intel__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center intel__center">
        <div className="sa-window intel__window">
          <div className="sa-window__title">
            {tKey("ui.intel")}
            <div className="sa-grow" />
            <Button textKey="ui.close" compact onClick={close} />
          </div>
          <div className="sa-window__body">
            <div className="intel__stack">
              <div className="sa-tabs intel__tabs">
                {TAB_IDS.map((item) => (
                  <button
                    key={item.id}
                    type="button"
                    className="sa-tab"
                    data-active={tab === item.tab}
                    onClick={() => setTab(item.tab)}
                  >
                    {tKey(item.labelKey)}
                  </button>
                ))}
                <button
                  type="button"
                  className="sa-tab"
                  onClick={() => navigate("chart")}
                >
                  {tKey("chart.title")}
                </button>
              </div>

              <div className="intel__page sa-grow" hidden={tab !== "captain"}>
                <CaptainView embedded />
              </div>
              <div className="intel__page sa-grow" hidden={tab !== "reputation"}>
                <ReputationView embedded />
              </div>
              <div className="intel__page sa-grow" hidden={tab !== "officers"}>
                <OfficerRoster embedded />
              </div>
              <div className="intel__page sa-grow" hidden={tab !== "fleet"}>
                <FleetView embedded />
              </div>

              <div className="intel__page sa-grow" hidden={tab !== "quests"}>
                <div className="intel__quests">
                  <Label
                    textKey="quest.slots"
                    values={{ used: questCount, max: tKey("ui.not_available") }}
                  />
                  <div className="sa-scroll intel__quests_rows sa-grow">
                    <div className="sa-table">
                      {Array.from({ length: questCount }, (_, index) => questRow(index))}
                    </div>
                  </div>
                  {questCount === 0 ? (
                    <Label textKey="quest.no_offer" tone="dim" />
                  ) : null}
                </div>
              </div>

              <Label textKey="intel.hint" tone="dim" />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
