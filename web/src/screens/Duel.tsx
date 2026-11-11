/**
 * The captain duel modal (docs/80-UI-UX.md §4.11.6; docs/60-* §4.11.6).
 *
 * The M7 presentation (80-* §4.9.1): the transcript renders as the indigo
 * message window (`.sa-dialog`) over the dim layer — one kit table row per
 * round, the result line and the acknowledge verb beneath.
 *
 * READ-ONLY over whatever duel payload the state/event stream already
 * carries: the server owns the rolls and the win rule. The report flags the
 * missing `duel` WS/HTTP intent (no `duel/*` verb and no duel frame exist in
 * the frozen §0.3/§0.4 tables), so the modal cannot start or advance a duel
 * yet — it only renders the transcript.
 */
import { useGameState } from "../state/context";
import { useI18n } from "../i18n";
import type { ScreenId } from "./ids";
import { Button, Dialog, Row } from "../kit";
import { Label } from "./common";
import { navigate } from "../app/router";
import "./Duel.css";

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
  const resultTone = duel?.result === "capture" ? "good" : duel?.result === "defeat" ? "bad" : undefined;

  return (
    <div className="sa-screen duel" data-screen={SCREEN}>
      <div className="duel__dim sa-dim" aria-hidden="true" />
      <div className="sa-fill-center">
        <Dialog titleKey="duel.title" className="duel__dialog">
          <div className="duel__body">
            {duel?.committed ? <Label textKey="duel.committed" tone="warn" /> : null}
            {duel?.attacker_name || duel?.defender_name ? (
              <Label
                light
                textValue={`${duel?.attacker_name ? t(duel.attacker_name) : ""} · ${duel?.defender_name ? t(duel.defender_name) : ""}`}
              />
            ) : null}
            <div className="duel__rounds sa-scroll">
              <div className="sa-table">
                {rounds.map((roll, index) => {
                  const player = Number(roll?.player ?? 0);
                  const defender = Number(roll?.defender ?? 0);
                  const verdict = player > defender
                    ? "duel.round.win"
                    : player < defender
                      ? "duel.round.loss"
                      : "duel.round.tie";
                  return (
                    <Row
                      key={index}
                      cols={[
                        <span className="sa-cell sa-cell--center" key="number">
                          {String(index + 1)}
                        </span>,
                        <span className="sa-cell sa-cell--right" key="player">
                          {String(player)}
                        </span>,
                        <span className="sa-cell sa-cell--right" key="defender">
                          {String(defender)}
                        </span>,
                        <span className="sa-cell" key="verdict">
                          {tKey(verdict)}
                        </span>,
                      ]}
                    />
                  );
                })}
              </div>
            </div>
            <Label textKey={resultKey} tone={resultTone} light={!resultTone} heading />
            <div className="duel__ack">
              <Button
                textKey="ui.close"
                fill
                onClick={() => navigate(state.current_port ? "port" : "world")}
              />
            </div>
          </div>
        </Dialog>
      </div>
    </div>
  );
}

export function duelTitleKey(): string {
  return "duel.title";
}
