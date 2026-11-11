/**
 * S2 nationality select (docs/80-UI-UX.md §4.1, §4.2; docs/50-* §4.1
 * step 1). The six cards come from `data/nations.json` in file order
 * (Portugal, Spain, England, Holland, Ottoman, Italy — the fixed order);
 * every value shown (name, description, start port/ship/gold) is data.
 *
 * Every `nationality_select` element row is rendered:
 * `background`, `title`, `prompt`, `cards` + `cards.<id>` and its
 * `.flag` / `.name` / `.desc` / `.package` parts, `world_label`, `back`,
 * `confirm`.
 *
 * Confirm only records the chosen nation for the creation screen (the
 * Phase-8 two-step handoff) — the server's `new_game` stays authoritative
 * and runs on S20's confirm.
 */
import { useState } from "react";
import rawNations from "../../../data/nations.json";
import type { L10nString } from "../i18n";
import { content, useI18n } from "../i18n";
import { Element, type ScreenId } from "../layout";
import { ButtonEl, LabelEl, PanelEl } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "nationality_select";

interface NationRaw {
  id: string;
  name: L10nString;
  description?: L10nString;
  start_port_id: string;
  start_ship_type_id: string;
  start_gold: number;
}

const NATIONS = (rawNations as { nations: NationRaw[] }).nations;

/**
 * The authored card id rows (data/ui_layout.json `nationality_select`).
 * Kept as literal strings: the layout-coverage gate is a static source
 * check, and the cards themselves are data-ordered at render time.
 */
const CARD_IDS: Record<
  string,
  { card: string; flag: string; name: string; desc: string; package: string }
> = {
  portugal: {
    card: "cards.portugal",
    flag: "cards.portugal.flag",
    name: "cards.portugal.name",
    desc: "cards.portugal.desc",
    package: "cards.portugal.package",
  },
  spain: {
    card: "cards.spain",
    flag: "cards.spain.flag",
    name: "cards.spain.name",
    desc: "cards.spain.desc",
    package: "cards.spain.package",
  },
  england: {
    card: "cards.england",
    flag: "cards.england.flag",
    name: "cards.england.name",
    desc: "cards.england.desc",
    package: "cards.england.package",
  },
  holland: {
    card: "cards.holland",
    flag: "cards.holland.flag",
    name: "cards.holland.name",
    desc: "cards.holland.desc",
    package: "cards.holland.package",
  },
  ottoman: {
    card: "cards.ottoman",
    flag: "cards.ottoman.flag",
    name: "cards.ottoman.name",
    desc: "cards.ottoman.desc",
    package: "cards.ottoman.package",
  },
  italy: {
    card: "cards.italy",
    flag: "cards.italy.flag",
    name: "cards.italy.name",
    desc: "cards.italy.desc",
    package: "cards.italy.package",
  },
};

/* The S2 → S20 handoff (the Godot `Creation.pending_nation_id` static). */
let pendingNationId = "";

export function setPendingNation(nationId: string): void {
  pendingNationId = nationId;
}

/** Reads and clears the handoff exactly once (S20's `_ready` rule). */
export function takePendingNation(): string {
  const nation = pendingNationId;
  pendingNationId = "";
  return nation;
}

export function NationalitySelectScreen() {
  const { locale, t, tKey, fmt } = useI18n();
  const [selected, setSelected] = useState(NATIONS[0]?.id ?? "");

  const packageText = (nation: NationRaw): string => {
    const port = t(content.portName(nation.start_port_id));
    const ship = t(content.shipName(nation.start_ship_type_id));
    const gold = new Intl.NumberFormat(locale === "zh" ? "zh-CN" : "en-US").format(
      nation.start_gold,
    );
    return [
      tKey("nation.start_package"),
      fmt("nation.start_port", { port }),
      fmt("nation.start_ship", { ship }),
      fmt("nation.start_gold", { gold }),
    ].join(" · ");
  };

  return (
    <>
      <PanelEl screen={SCREEN} id="background" skin="backdrop" />
      <LabelEl screen={SCREEN} id="title" textKey="nation.select_title" title align="center" />
      <LabelEl screen={SCREEN} id="prompt" textKey="nation.select_prompt" tone="dim" align="center" />

      <Element screen={SCREEN} id="cards">
        {NATIONS.map((nation) => {
          const ids = CARD_IDS[nation.id];
          if (!ids) return null;
          return (
            <Element
              key={nation.id}
              screen={SCREEN}
              id={ids.card}
              parent="cards"
              as="button"
              skin={selected === nation.id ? "button_focus" : "panel"}
              className="sa-card-button"
              onClick={() => setSelected(nation.id)}
            >
              <Element screen={SCREEN} id={ids.flag} parent={ids.card}>
                <span className={`sa-nation-swatch sa-nation-swatch--${nation.id}`} aria-hidden="true" />
              </Element>
              <LabelEl screen={SCREEN} id={ids.name} parent={ids.card} text={nation.name} heading />
              <LabelEl
                screen={SCREEN}
                id={ids.desc}
                parent={ids.card}
                textValue={nation.description ? t(nation.description) : ""}
                tone={selected === nation.id ? "default" : "dim"}
              />
              <LabelEl
                screen={SCREEN}
                id={ids.package}
                parent={ids.card}
                textValue={packageText(nation)}
                tone="dim"
              />
            </Element>
          );
        })}
      </Element>

      <LabelEl screen={SCREEN} id="world_label" textKey="nation.world" tone="dim" />
      <ButtonEl screen={SCREEN} id="back" textKey="ui.back" onClick={() => navigate("title")} />
      <ButtonEl
        screen={SCREEN}
        id="confirm"
        textKey="nation.confirm"
        kind="primary"
        onClick={() => {
          if (!selected) return;
          setPendingNation(selected);
          navigate("creation");
        }}
      />
    </>
  );
}
