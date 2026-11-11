/**
 * The reputation view (docs/80-UI-UX.md §4.5/§4.12.3, docs/50-* §4.6) —
 * the intel window's 声望 tab: one row per nation, the integer standing from
 * `player.reputation`. Six fixed nation rows are authored in the layout, so
 * the screen renders those exact ids (no dynamic list). The sign is composed
 * by the UI (`+20` / `0` / `-5`), never baked into an L10nString.
 */
import { content, uiStrings, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import { Element, type ScreenId } from "../layout";
import { LabelEl, StandaloneFrame } from "./common";

const SCREEN: ScreenId = "reputation_view";

const NATIONS = ["portugal", "spain", "england", "holland", "ottoman", "italy"] as const;

const REPUTATION_IDS: Record<(typeof NATIONS)[number], { name: string; value: string }> = {
  portugal: { name: "rows.portugal.name", value: "rows.portugal.value" },
  spain: { name: "rows.spain.name", value: "rows.spain.value" },
  england: { name: "rows.england.name", value: "rows.england.value" },
  holland: { name: "rows.holland.name", value: "rows.holland.value" },
  ottoman: { name: "rows.ottoman.name", value: "rows.ottoman.value" },
  italy: { name: "rows.italy.name", value: "rows.italy.value" },
};

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
    <>
      <LabelEl screen={SCREEN} id="title" textKey="char.reputation" title />
      <Element screen={SCREEN} id="rows">
        {NATIONS.map((nationId) => {
          const value = Number(state.player.reputation[nationId] ?? 0);
          const own = nationId === state.player.nation_id;
          return (
            <div key={nationId} data-row={nationId}>
              <Element screen={SCREEN} id={REPUTATION_IDS[nationId].name} parent="rows">
                <span className={`sa-cell${own ? " sa-label--accent" : ""}`}>
                  {t(content.nationName(nationId))}
                </span>
              </Element>
              <Element screen={SCREEN} id={REPUTATION_IDS[nationId].value} parent="rows">
                <span className={`sa-cell sa-label--right sa-label--${toneFor(value)}`}>
                  {signed(value)}
                </span>
              </Element>
            </div>
          );
        })}
      </Element>
      <LabelEl
        screen={SCREEN}
        id="hint"
        textKey={uiStrings["char.reputation.hint"] ? "char.reputation.hint" : undefined}
        tone="dim"
        hidden={!uiStrings["char.reputation.hint"]}
      />
    </>
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
