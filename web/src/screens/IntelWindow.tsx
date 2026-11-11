/**
 * The intel window (docs/80-UI-UX.md §4.5, §4.5.1, §4.6.2, §4.12.3) — the
 * one modal over S3/S4 hosting the six tabs: 船长 / 声望 / 官员 / 船队 /
 * 海图 (an action, not a page) / 委托. The four person/fleet tabs are
 * embeddable components and are also standalone routes (the M6-c slice).
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
import { Box, Element, ListRows, type ScreenId } from "../layout";
import type { ReactNode } from "react";
import { Button } from "../kit";
import {
  ButtonEl,
  LabelEl,
  PanelEl,
  useFetchedView,
} from "./common";
import { CaptainView } from "./CaptainView";
import { FleetView } from "./FleetView";
import { OfficerRoster } from "./OfficerRoster";
import { ReputationView } from "./ReputationView";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "intel_window";

type Tab = "captain" | "reputation" | "officers" | "fleet" | "quests";

const QUEST_CELLS: Record<string, { x: number; y: number; w: number; h: number }> = {
  tag: { x: 0, y: 0, w: 4, h: 1 },
  objective: { x: 4, y: 0, w: 23, h: 1 },
  destination: { x: 0, y: 1, w: 26, h: 1 },
  days: { x: 27, y: 0, w: 5, h: 1 },
  abandon: { x: 26, y: 1, w: 6, h: 1 },
};

function QuestCell({
  index,
  part,
  children,
}: {
  index: number;
  part: string;
  children: ReactNode;
}) {
  if (index === 0) {
    const id = part === "tag"
      ? "quests.0.tag"
      : part === "objective"
        ? "quests.0.objective"
        : part === "destination"
          ? "quests.0.destination"
          : part === "days"
            ? "quests.0.days"
            : "quests.0.abandon";
    return (
      <Element screen={SCREEN} id={id}>
        {children}
      </Element>
    );
  }
  return <Box rect={QUEST_CELLS[part]}>{children}</Box>;
}

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

  return (
    <div className="sa-screen">
      <PanelEl screen={SCREEN} id="dim" skin="backdrop" className="sa-dim" />
      <PanelEl screen={SCREEN} id="panel" skin="panel">
        <LabelEl screen={SCREEN} id="panel.title" parent="panel" textKey="ui.intel" title />
        <ButtonEl
          screen={SCREEN}
          id="panel.close"
          parent="panel"
          textKey="ui.close"
          onClick={close}
        />

        {TAB_IDS.map((item) => (
          <ButtonEl
            key={item.id}
            screen={SCREEN}
            id={item.id}
            parent="panel"
            textKey={item.labelKey}
            kind={tab === item.tab ? "primary" : "default"}
            onClick={() => setTab(item.tab)}
          />
        ))}
        <ButtonEl
          screen={SCREEN}
          id="tabs.chart"
          parent="panel"
          textKey="chart.title"
          onClick={() => navigate("chart")}
        />

        <Element screen={SCREEN} id="panel.content" parent="panel">
          <Element screen={SCREEN} id="content.captain" parent="panel.content" hidden={tab !== "captain"}>
            <CaptainView embedded />
          </Element>
          <Element screen={SCREEN} id="content.reputation" parent="panel.content" hidden={tab !== "reputation"}>
            <ReputationView embedded />
          </Element>
          <Element screen={SCREEN} id="content.officers" parent="panel.content" hidden={tab !== "officers"}>
            <OfficerRoster embedded />
          </Element>
          <Element screen={SCREEN} id="content.fleet" parent="panel.content" hidden={tab !== "fleet"}>
            <FleetView embedded />
          </Element>
        </Element>

        <LabelEl
          screen={SCREEN}
          id="quests.slots_line"
          parent="panel"
          textKey="quest.slots"
          values={{ used: questCount, max: tKey("ui.not_available") }}
          hidden={tab !== "quests"}
        />
        <Element screen={SCREEN} id="quests.viewport" parent="panel" className="sa-scroll" hidden={tab !== "quests"}>
          <ListRows
            screen={SCREEN}
            listId="quests"
            count={quests.length > 0 ? quests.length : rawQuests.length}
            renderRow={(index) => {
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
                <>
                  <QuestCell index={index} part="tag">
                    <span className="sa-cell sa-label--accent">{tKey(tagKey)}</span>
                  </QuestCell>
                  <QuestCell index={index} part="objective">
                    <span className="sa-cell">{objective}</span>
                  </QuestCell>
                  <QuestCell index={index} part="days">
                    <span className="sa-cell sa-label--right">
                      {fmt("quest.days_left", { days })}
                    </span>
                  </QuestCell>
                  <QuestCell index={index} part="destination">
                    <span className="sa-cell sa-label--dim"> </span>
                  </QuestCell>
                  <QuestCell index={index} part="abandon">
                    <Button
                      textKey="quest.abandon"
                      kind="danger"
                      disabled={!instanceId || state.current_port === null}
                      titleKey={state.current_port === null ? "fleet.port_only" : undefined}
                      fill
                      onClick={() => {
                        void client.action("guild", "abandon", {
                          instance_id: instanceId,
                        });
                      }}
                    />
                  </QuestCell>
                </>
              );
            }}
          />
        </Element>
        <LabelEl
          screen={SCREEN}
          id="quests.empty"
          parent="panel"
          textKey="quest.no_offer"
          tone="dim"
          hidden={tab !== "quests" || questCount > 0}
        />
        <LabelEl screen={SCREEN} id="panel.hint" parent="panel" textKey="intel.hint" tone="dim" />
      </PanelEl>
    </div>
  );
}

