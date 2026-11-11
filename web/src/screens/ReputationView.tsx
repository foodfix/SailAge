/**
 * The reputation view (docs/80-UI-UX.md §4.5/§4.12.3, docs/50-* §4.6; the
 * §4.9.1 composition) — the intel window's 声望 tab and the standalone
 * route: one kit table row per nation, the integer standing from
 * `player.reputation`. Six fixed nation rows (no dynamic list). The sign is
 * composed by the UI (`+20` / `0` / `-5`), never baked into an L10nString.
 */
import { content, uiStrings, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import type { ScreenId } from "./ids";
import { Label, StandaloneFrame } from "./common";
import { Row } from "../kit";
import "./ReputationView.css";

const SCREEN: ScreenId = "reputation_view";

const NATIONS = ["portugal", "spain", "england", "holland", "ottoman", "italy"] as const;

function toneFor(value: number): "good" | "warn" | "bad" {
  if (value > 0) return "good";
  if (value < 0) return "bad";
  return "warn";
}

function signed(value: number): string {
  return value > 0 ? `+${value}` : String(value);
}

export function ReputationView({ embedded = false }: { embedded?: boolean }) {
  const { state } = useGameState();
  const { t } = useI18n();
  const body = (
    <div className="repview__body" data-screen={SCREEN}>
      <Label textKey="char.reputation" title />
      <div className="sa-table repview__table">
        {NATIONS.map((nationId) => {
          const value = Number(state.player.reputation[nationId] ?? 0);
          const own = nationId === state.player.nation_id;
          return (
            <Row key={nationId} cols={[
              <div className={`sa-cell${own ? " sa-label--accent" : ""}`} data-row={nationId}>
                {t(content.nationName(nationId))}
              </div>,
              <div className={`sa-cell sa-cell--right sa-label--${toneFor(value)}`}>
                {signed(value)}
              </div>,
            ]} />
          );
        })}
      </div>
      {uiStrings["char.reputation.hint"] ? (
        <Label textKey="char.reputation.hint" tone="dim" />
      ) : null}
    </div>
  );
  return embedded ? body : <StandaloneFrame>{body}</StandaloneFrame>;
}

export const REPUTATION_NATIONS = NATIONS;

export function reputationLabelKey(): string {
  return "char.reputation";
}

export function reputationTone(value: number): "good" | "warn" | "bad" {
  return toneFor(value);
}
