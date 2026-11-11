/**
 * The captain duel modal (docs/80-UI-UX.md §4.11.6; docs/60-* §4.11.6).
 *
 * READ-ONLY over whatever duel payload the state/event stream already
 * carries: the server owns the rolls and the win rule. The report flags the
 * missing `duel` WS/HTTP intent (no `duel/*` verb and no duel frame exist in
 * the frozen §0.3/§0.4 tables), so the modal cannot start or advance a duel
 * yet — it only renders the transcript.
 */
import { useGameState } from "../state/context";
import { useI18n } from "../i18n";
import { Element, ListRows, tile, type ScreenId } from "../layout";
import { Button } from "../kit";
import { LabelEl, PanelEl } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "duel";

interface DuelRoll {
  player?: number;
  defender?: number;
}

interface DuelPayload {
  result?: string;
  rolls?: DuelRoll[];
  player_base?: number;
  defender_base?: number;
  player_wins?: number;
  defender_wins?: number;
  committed?: boolean;
  attacker_name?: { zh: string; en: string };
  defender_name?: { zh: string; en: string };
}

const ROUND_IDS: Record<number, Record<"number" | "player" | "defender" | "verdict", string>> = {
  0: { number: "rounds.0.number", player: "rounds.0.player", defender: "rounds.0.defender", verdict: "rounds.0.verdict" },
  1: { number: "rounds.1.number", player: "rounds.1.player", defender: "rounds.1.defender", verdict: "rounds.1.verdict" },
  2: { number: "rounds.2.number", player: "rounds.2.player", defender: "rounds.2.defender", verdict: "rounds.2.verdict" },
  3: { number: "rounds.3.number", player: "rounds.3.player", defender: "rounds.3.defender", verdict: "rounds.3.verdict" },
};

function extractDuel(source: unknown): DuelPayload | null {
  if (!source || typeof source !== "object") return null;
  const block = source as Record<string, unknown>;
  const direct = block.duel;
  if (direct && typeof direct === "object") return direct as DuelPayload;
  const outcome = block.outcome;
  if (outcome && typeof outcome === "object") {
    const nested = (outcome as Record<string, unknown>).duel;
    if (nested && typeof nested === "object") return nested as DuelPayload;
  }
  if (typeof block.rounds === "object" || typeof block.result === "string") {
    return block as DuelPayload;
  }
  return null;
}

export function Duel() {
  const { state, lastEvent } = useGameState();
  const { tKey, t } = useI18n();
  const duel = extractDuel(state.pending_encounter) ?? extractDuel(lastEvent?.args ?? null);
  const rounds = duel?.rolls ?? [];
  const resultKey = duel?.result === "capture"
    ? "duel.result.capture"
    : duel?.result === "defeat"
      ? "duel.result.defeat"
      : "ui.not_available";

  const roundCell = (index: number, part: "number" | "player" | "defender" | "verdict", value: string) => {
    const rect = {
      number: { x: 0, y: 0, w: 2, h: 1 },
      player: { x: 2, y: 0, w: 3, h: 1 },
      defender: { x: 5, y: 0, w: 4, h: 1 },
      verdict: { x: 8, y: 0, w: 4, h: 1 },
    }[part];
    if (index <= 3) {
      return (
        <Element screen={SCREEN} id={ROUND_IDS[index][part]}>
          <span className="sa-cell">{value}</span>
        </Element>
      );
    }
    return (
      <div className="sa-el" style={{ left: tile(rect.x), top: tile(0), width: tile(rect.w), height: tile(rect.h) }}>
        <span className="sa-cell">{value}</span>
      </div>
    );
  };

  return (
    <div className="sa-screen">
      <PanelEl screen={SCREEN} id="dim" skin="backdrop" className="sa-dim" />
      <PanelEl screen={SCREEN} id="panel" skin="panel">
        <LabelEl screen={SCREEN} id="panel.title" parent="panel" textKey="duel.title" title />
        <LabelEl
          screen={SCREEN}
          id="panel.committed"
          parent="panel"
          textKey="duel.committed"
          tone="warn"
          hidden={!duel?.committed}
        />
        <LabelEl
          screen={SCREEN}
          id="panel.header"
          parent="panel"
          textValue={
            duel?.attacker_name || duel?.defender_name
              ? `${duel?.attacker_name ? t(duel.attacker_name) : ""} · ${duel?.defender_name ? t(duel.defender_name) : ""}`
              : ""
          }
          tone="dim"
        />
        <Element screen={SCREEN} id="panel.rounds_viewport" parent="panel" className="sa-scroll">
          <ListRows
            screen={SCREEN}
            listId="rounds"
            count={rounds.length}
            renderRow={(index) => {
              const roll = rounds[index];
              const player = Number(roll?.player ?? 0);
              const defender = Number(roll?.defender ?? 0);
              const verdict = player > defender
                ? "duel.round.win"
                : player < defender
                  ? "duel.round.loss"
                  : "duel.round.tie";
              return (
                <>
                  {roundCell(index, "number", String(index + 1))}
                  {roundCell(index, "player", String(player))}
                  {roundCell(index, "defender", String(defender))}
                  {roundCell(index, "verdict", tKey(verdict))}
                </>
              );
            }}
          />
        </Element>
        <LabelEl
          screen={SCREEN}
          id="panel.result"
          parent="panel"
          textKey={resultKey}
          tone={duel?.result === "capture" ? "good" : duel?.result === "defeat" ? "bad" : "dim"}
          heading
        />
        <Element screen={SCREEN} id="panel.acknowledge" parent="panel">
          <Button
            textKey="ui.close"
            fill
            onClick={() => navigate(state.current_port ? "port" : "world")}
          />
        </Element>
      </PanelEl>
    </div>
  );
}

export function duelTitleKey(): string {
  return "duel.title";
}
