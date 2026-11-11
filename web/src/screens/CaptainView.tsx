/**
 * The captain view (docs/80-UI-UX.md §4.12.3) — the intel window's 船长 tab.
 * A single scrollable page carrying the player card (attributes, level/XP,
 * the §4.12.2 allocation steppers, the eight skill bars + the three
 * officer-only rows). The reputation table and the officer roster moved to
 * their own tabs (2026-11-03 amendment).
 *
 * The missing `GET /api/view/captain_view` projection is reported: the
 * card's effective values, XP-to-next and the allocation commit verb are
 * not server-exposed yet, so the card renders the stored values and the
 * allocation confirm stays disabled with its reason.
 */
import { content, useI18n } from "../i18n";
import { useGameState } from "../state/context";
import { Element, type ScreenId } from "../layout";
import { LabelEl, StandaloneFrame } from "./common";
import { CharacterCard } from "./CharacterCard";

const SCREEN: ScreenId = "captain_view";

export function CaptainView({ embedded = false }: { embedded?: boolean }) {
  const { state } = useGameState();
  const { t } = useI18n();
  const body = (
    <>
      <LabelEl
        screen={SCREEN}
        id="nation"
        textKey="ui.day_nation_gold"
        values={{
          day: state.day,
          nation: t(content.nationName(state.player.nation_id)),
          gold: state.gold,
        }}
      />
      <LabelEl
        screen={SCREEN}
        id="levelup"
        textKey="char.level_up.alloc"
        tone="accent"
        hidden={state.player.alloc_pending <= 0}
      />
      <Element screen={SCREEN} id="page" className="sa-scroll">
        <CharacterCard kind="player" alloc />
      </Element>
    </>
  );
  return embedded ? body : <StandaloneFrame>{body}</StandaloneFrame>;
}
