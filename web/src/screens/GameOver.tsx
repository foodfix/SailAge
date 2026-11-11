/**
 * S9 game over (docs/80-UI-UX.md §4.1, §4.2, §4.9.1; docs/20-* §4.9).
 *
 * A full-screen bookend shown when the sea kills the run. The composition
 * (§4.9.1): a full-canvas dim layer carrying one centered indigo dialog —
 * the `gameover.title` band, the run's day / gold / fame lines, the death
 * cause and the return-to-title button. The cause comes from the
 * `game_over` event transcript (§5.1) with the state payload's transient
 * `game_over_reason` as the reload fallback. Any key or the return button
 * goes back to the title.
 */
import { useEffect } from "react";
import { content, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import type { GameSnapshotExtras } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Dialog } from "../kit";
import { Label } from "./common";
import { navigate } from "../app/router";
import "./GameOver.css";

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
    <div className="sa-screen gameover" data-screen={SCREEN}>
      <div className="gameover__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center gameover__layer">
        <Dialog titleKey="gameover.title" className="gameover__window">
          <Label
            textValue={fmt("ui.day_nation_gold", { day: state.day, nation, gold: state.gold })}
            light
            align="center"
          />
          <Label
            className="gameover__line"
            textValue={fmt("ending.fame", { fame: state.fame })}
            light
            align="center"
          />
          <Label
            className="gameover__line"
            textValue={known ? fmt("gameover.reason", { reason: tKey(`gameover.${reason}`) }) : ""}
            light
            align="center"
          />
          <div className="gameover__actions">
            <Button textKey="gameover.return" kind="primary" onClick={() => navigate("title")} />
          </div>
        </Dialog>
      </div>
    </div>
  );
}
