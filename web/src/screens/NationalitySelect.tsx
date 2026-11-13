/**
 * S2 nationality select (docs/80-UI-UX.md §4.1, §4.2, §4.9.1; docs/50-*
 * §4.1 step 1). The six cards come from `data/nations.json` in file order
 * (Portugal, Spain, England, Holland, Ottoman, Italy — the fixed order);
 * every value shown (name, description, start port/ship/gold) is data.
 *
 * The composition (§4.9.1): the sea scene backdrop with one centered wide
 * window — the `nation.select_title` band, the prompt line, the nation
 * cards as a 3×2 grid of stacked buttons (flag swatch + name + description
 * + starting package; the selected card carries the primary treatment),
 * the `nation.world` line and the back/confirm footer.
 *
 * Confirm only records the chosen nation for the creation screen (the
 * Phase-8 two-step handoff) — the server's `new_game` stays authoritative
 * and runs on S20's confirm.
 */
import { useState } from "react";
import rawNations from "../../../data/nations.json";
import type { L10nString } from "../i18n";
import { content, useI18n } from "../i18n";
import type { ScreenId } from "./ids";
import { Button, Footer, Frame } from "../kit";
import { Label } from "./common";
import { navigate } from "../app/router";
import "./NationalitySelect.css";

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
    <div className="sa-screen nationality_select" data-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />

      <div className="sa-fill-center nat__layer">
        <Frame titleKey="nation.select_title" className="nat__window">
          <Label textKey="nation.select_prompt" tone="dim" align="center" />

          <div className="nat__cards">
            {NATIONS.map((nation) => (
              <Button
                key={nation.id}
                fill
                kind={selected === nation.id ? "primary" : "default"}
                onClick={() => setSelected(nation.id)}
              >
                <span className="sa-button__stack">
                  <span className="nat__flag" aria-hidden="true">
                    <span className={`sa-nation-swatch sa-nation-swatch--${nation.id}`} />
                  </span>
                  <Label text={nation.name} heading />
                  <Label
                    textValue={nation.description ? t(nation.description) : ""}
                    tone={selected === nation.id ? "default" : "dim"}
                    align="center"
                    wrap
                  />
                  <Label textValue={packageText(nation)} tone="dim" align="center" wrap />
                </span>
              </Button>
            ))}
          </div>

          <Label className="nat__world" textKey="nation.world" tone="dim" align="center" />

          <div className="nat__footer">
            <Footer
              buttons={[
                <Button key="back" textKey="ui.back" onClick={() => navigate("title")} />,
                <Button
                  key="confirm"
                  textKey="nation.confirm"
                  kind="primary"
                  onClick={() => {
                    if (!selected) return;
                    setPendingNation(selected);
                    navigate("creation");
                  }}
                />,
              ]}
            />
          </div>
        </Frame>
      </div>
    </div>
  );
}
