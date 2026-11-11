/**
 * The captain view (docs/80-UI-UX.md §4.12.3; the §4.9.1 composition) — the
 * intel window's 船长 tab and the standalone route. A single scrollable
 * column carrying the day/nation/gold line, the §4.12.2 alloc-pending
 * notice and the player card (attributes, level/XP, the allocation
 * steppers, the eight skill bars + the three officer-only rows).
 *
 * The missing `GET /api/view/captain_view` projection is reported: the
 * card's effective values, XP-to-next and the allocation commit verb are
 * not server-exposed yet, so the card renders the stored values and the
 * allocation confirm stays disabled with its reason.
 */
import { content, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import type { ScreenId } from "./ids";
import { Label, StandaloneFrame } from "./common";
import { CharacterCard } from "./CharacterCard";
import "./CaptainView.css";

const SCREEN: ScreenId = "captain_view";

export function CaptainView({ embedded = false }: { embedded?: boolean }) {
  const { state } = useGameState();
  const { t } = useI18n();
  const body = (
    <div className="capview__body" data-screen={SCREEN}>
      <Label
        textKey="ui.day_nation_gold"
        values={{
          day: state.day,
          nation: t(content.nationName(state.player.nation_id)),
          gold: state.gold,
        }}
      />
      {state.player.alloc_pending > 0 ? (
        <Label textKey="char.level_up.alloc" tone="accent" />
      ) : null}
      <div className="sa-scroll capview__page">
        <CharacterCard kind="player" alloc />
      </div>
    </div>
  );
  return embedded ? body : <StandaloneFrame className="capview__window">{body}</StandaloneFrame>;
}
