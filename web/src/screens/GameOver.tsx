/**
 * S9 game over (docs/80-UI-UX.md §4.1, §4.2; docs/20-* §4.9).
 *
 * A full-screen bookend shown when the sea kills the run. The cause comes
 * from the `game_over` event transcript (§5.1) with the state payload's
 * transient `game_over_reason` as the reload fallback; the summary lines
 * are the run's day / gold / fame. Any key or the return button goes back
 * to the title.
 *
 * Every `gameover` element row is rendered: `dim`, `panel`,
 * `panel.title`, `panel.reason`, `panel.return`.
 */
import { useEffect } from "react";
import { content, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import type { GameSnapshotExtras } from "../state/views";
import { Box, Element, type ScreenId } from "../layout";
import { ButtonEl, LabelEl } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "gameover";

const KNOWN_REASONS = ["starvation", "scurvy", "sunk", "captured"] as const;

export function GameOverScreen() {
  const { state, lastEvent } = useGameState();
  const { t, tKey, fmt } = useI18n();

  const fromState = (state as typeof state & GameSnapshotExtras).game_over_reason ?? "";
  const fromEvent =
    lastEvent && lastEvent.name === "game_over" ? String(lastEvent.args.reason ?? "") : "";
  const reason = fromState || fromEvent;
  const known = (KNOWN_REASONS as readonly string[]).includes(reason);

  useEffect(() => {
    const onKey = () => navigate("title");
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const nation = state.player.nation_id ? t(content.nationName(state.player.nation_id)) : "";

  return (
    <>
      <Element screen={SCREEN} id="dim" className="sa-dim" />
      <Element screen={SCREEN} id="panel" parent="dim" skin="panel">
        <Element screen={SCREEN} id="panel.title" parent="panel">
          <Box rect={{ x: 0, y: 0, w: 13, h: 1 }}>
            <span className="sa-label sa-label--title">{tKey("gameover.title")}</span>
          </Box>
          <Box rect={{ x: 0, y: 1, w: 13, h: 1 }}>
            <span className="sa-label sa-label--dim">
              {fmt("ui.day_nation_gold", { day: state.day, nation, gold: state.gold })}
            </span>
          </Box>
          <Box rect={{ x: 0, y: 2, w: 13, h: 1 }}>
            <span className="sa-label sa-label--accent">
              {fmt("ending.fame", { fame: state.fame })}
            </span>
          </Box>
        </Element>

        <LabelEl
          screen={SCREEN}
          id="panel.reason"
          parent="panel"
          textValue={
            known
              ? fmt("gameover.reason", { reason: tKey(`gameover.${reason}`) })
              : ""
          }
          tone="warn"
          align="center"
        />

        <ButtonEl
          screen={SCREEN}
          id="panel.return"
          parent="panel"
          textKey="gameover.return"
          kind="primary"
          onClick={() => navigate("title")}
        />
      </Element>
    </>
  );
}
