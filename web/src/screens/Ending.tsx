/**
 * S16 retirement summary (docs/70-* §4.7; docs/80-UI-UX.md §4.1, §4.2,
 * §4.14, §4.9.1). Read-only: six summary lines then the Phase-8 RPG
 * segment, in one centered window over the scene.
 *
 * Summary: days sailed, gold, fame, titles (every nation whose rank is not
 * `none`), discoveries reported, battles won.
 * RPG segment: the nemesis list (top 3 captains by wins), the deepest
 * grudge (lowest negative stance), the most loyal veteran (officer with
 * `sea_days ≥ 90` and the highest loyalty) and the background bio line.
 * The mode title swaps to `ending.retired_title` when a retired save was
 * just loaded; the `ending.continue` button returns to the title.
 */
import { useEffect, useState } from "react";
import rawBackgrounds from "../../../data/backgrounds.json";
import type { L10nString } from "../i18n";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { GameSnapshot } from "../state/types";
import type { CaptainStateExtras } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Footer, Frame } from "../kit";
import { Label } from "./common";
import { navigate } from "../app/router";
import { getEndingRetiredMode } from "./SaveSlot";
import "./Ending.css";

const SCREEN: ScreenId = "ending";

const NEMESIS_SLOTS = 3;
const VETERAN_SEA_DAYS = 90;

interface CaptainRaw {
  id: string;
  name: L10nString;
  tier: number;
}

interface BackgroundRaw {
  id: string;
  bio: L10nString;
}

const BACKGROUNDS = new Map(
  (rawBackgrounds as { backgrounds: BackgroundRaw[] }).backgrounds.map((entry) => [entry.id, entry]),
);

function byId(a: { id: string }, b: { id: string }): number {
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

export function EndingScreen() {
  const contextState = useGameState().state;
  const client = useGameClient();
  const { locale, t, tKey, fmt } = useI18n();
  const [fetched, setFetched] = useState<GameSnapshot | null>(null);
  const [captains, setCaptains] = useState<Map<string, CaptainRaw> | null>(null);
  const summaryMode = getEndingRetiredMode();

  // The captain canon is a 1 MB tool-owned roster used by this bookend only;
  // load it as a lazy chunk when the ending actually opens.
  useEffect(() => {
    let alive = true;
    void import("../../../data/captains.json").then((module) => {
      if (!alive) return;
      const raw = (module.default ?? module) as { captains: CaptainRaw[] };
      setCaptains(new Map(raw.captains.map((entry) => [entry.id, entry])));
    });
    return () => {
      alive = false;
    };
  }, []);

  // A load routes here right after `POST /api/load`; fetch the restored run
  // directly so the summary never renders a pre-load snapshot.
  useEffect(() => {
    let alive = true;
    void client
      .getState()
      .then((snapshot) => {
        if (alive) setFetched(snapshot);
      })
      .catch(() => {
        // Fall back to the context snapshot.
      });
    return () => {
      alive = false;
    };
  }, [client]);

  const state = fetched ?? contextState;

  const titles = Object.entries(state.titles)
    .filter(([, rank]) => rank && rank !== "none")
    .map(([nationId, rank]) => `${t(content.nationName(nationId))} ${tKey(`rank.${rank}`)}`);
  const titlesText = titles.length > 0 ? titles.join(" · ") : tKey("char.none");

  const gold = new Intl.NumberFormat(locale === "zh" ? "zh-CN" : "en-US").format(state.gold);

  const nemeses = Object.entries(state.captain_states)
    .map(([id, entry]) => ({
      id,
      wins: (entry as typeof entry & CaptainStateExtras).wins ?? 0,
    }))
    .filter((entry) => entry.wins > 0)
    .sort((a, b) => (b.wins !== a.wins ? b.wins - a.wins : byId(a, b)))
    .slice(0, NEMESIS_SLOTS);

  const grudge = Object.entries(state.captain_states)
    .map(([id, entry]) => ({
      id,
      stance: (entry as typeof entry & CaptainStateExtras).stance ?? 0,
    }))
    .filter((entry) => !(entry.stance >= 0))
    .sort((a, b) => (a.stance !== b.stance ? a.stance - b.stance : byId(a, b)))[0];

  const veteran = state.player.officers
    .map((id) => {
      const entry = state.officer_states[id];
      return { id, seaDays: entry?.sea_days ?? 0, loyalty: entry?.loyalty ?? 0 };
    })
    .filter((entry) => entry.seaDays >= VETERAN_SEA_DAYS)
    .sort((a, b) => (b.loyalty !== a.loyalty ? b.loyalty - a.loyalty : byId(a, b)))[0];

  const captainName = (id: string): string => {
    const card = captains?.get(id);
    return card ? t(card.name) : id;
  };

  const rpgRows: Array<{ text: string; dim?: boolean }> = [];
  rpgRows.push({ text: tKey("ending.rpg.nemesis_title") });
  if (nemeses.length === 0) {
    rpgRows.push({ text: tKey("ui.empty"), dim: true });
  } else {
    for (const nemesis of nemeses) {
      const card = captains?.get(nemesis.id);
      rpgRows.push({
        text: fmt("ending.rpg.nemesis_row", {
          name: captainName(nemesis.id),
          tier: (state.captain_states[nemesis.id] as CaptainStateExtras).tier_now ?? card?.tier ?? 1,
          stance: (state.captain_states[nemesis.id] as CaptainStateExtras).stance ?? 0,
        }),
      });
    }
  }
  rpgRows.push(
    grudge
      ? { text: fmt("ending.rpg.grudge", { name: captainName(grudge.id) }) }
      : { text: tKey("ui.empty"), dim: true },
  );
  rpgRows.push(
    veteran
      ? { text: fmt("ending.rpg.veteran", { name: t(content.officerName(veteran.id)), days: veteran.seaDays }) }
      : { text: tKey("ui.empty"), dim: true },
  );
  const background = BACKGROUNDS.get(state.player.background_id);
  rpgRows.push(
    background
      ? { text: `${tKey("ending.rpg.bio")} ${t(background.bio)}` }
      : { text: tKey("ui.empty"), dim: true },
  );

  return (
    <div className="sa-screen ending" data-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />

      <div className="sa-fill-center ending__layer">
        <Frame
          titleKey={summaryMode ? "ending.retired_title" : "ending.title"}
          className="ending__window"
          scroll
        >
          <Label
            textKey={summaryMode ? "ending.retired_title" : "title.subtitle"}
            tone="dim"
            align="center"
          />

          <div className="ending__rows">
            <Label textKey="ending.days" values={{ days: state.day }} />
            <Label textKey="ending.gold" values={{ gold }} />
            <Label textKey="ending.fame" values={{ fame: state.fame }} />
            <Label textValue={fmt("ending.titles", { titles: titlesText })} wrap />
            <Label textKey="ending.discoveries" values={{ count: state.discoveries_reported.length }} />
            <Label textKey="ending.battles" values={{ count: state.battles_won }} />
          </div>

          <div className="ending__rpg">
            {rpgRows.map((row, index) => (
              <div key={index} className={`sa-cell${row.dim ? " sa-label--dim" : ""}`}>
                {row.text}
              </div>
            ))}
          </div>

          <div className="ending__footer">
            <Footer
              buttons={[
                <Button
                  key="continue"
                  textKey="ending.continue"
                  kind="primary"
                  onClick={() => navigate("title")}
                />,
              ]}
            />
          </div>
        </Frame>
      </div>
    </div>
  );
}
