/**
 * S20 creation — the locked two-step new-game flow (docs/80-UI-UX.md
 * §4.13; docs/50-* §4.1 steps 1–6).
 *
 *   ① background — the six `data/backgrounds.json` cards (name / bio /
 *     composed bonus line; each grants one attribute +3 and one skill +5).
 *   ② free points — attributes +5 total, skills +3 total, per-item cap +3,
 *     all points must be spent; the spread shortcut spends attributes +1
 *     each and the first three skills +1 each.
 *
 * Every `creation` element row of data/ui_layout.json is rendered (both
 * step groups; the inactive one is `hidden`).
 *
 * The screen owns the pinned UI arithmetic only (pool remaining / per-item
 * cap / button disabling). The alloc dicts are collected and submitted to
 * `POST /api/new_game`; the server validates and authors the run block.
 * The live preview is the §4.13 pinned closed form (sighting 48+nav/12,
 * speed seamanship/300 capped at +30%, duel swordplay+courage/20).
 */
import { useState } from "react";
import rawNations from "../../../data/nations.json";
import rawBackgrounds from "../../../data/backgrounds.json";
import type { L10nString } from "../i18n";
import { useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { Box, Element, type ScreenId } from "../layout";
import { Button, Toast } from "../kit";
import { ButtonEl, LabelEl, PanelEl, useToastState } from "./common";
import { navigate } from "../app/router";
import { takePendingNation } from "./NationalitySelect";

const SCREEN: ScreenId = "creation";

const ATTRS = ["constitution", "intellect", "charisma", "courage", "luck"] as const;
const SKILLS = [
  "seamanship",
  "navigation",
  "swordplay",
  "gunnery",
  "appraisal",
  "negotiation",
  "cartography",
  "rumour",
] as const;

type AttrKey = (typeof ATTRS)[number];
type SkillKey = (typeof SKILLS)[number];

const ATTR_TOTAL = 5;
const SKILL_TOTAL = 3;
const ITEM_CAP = 3;

const BASE_ATTRIBUTE = 10;
const NATION_BONUS = 5;

const SIGHTING_BASE = 48;
const SIGHTING_NAV_DIVISOR = 12;
const SPEED_DIVISOR = 300;
const SPEED_CAP = 0.3;
const DUEL_COURAGE_DIVISOR = 20;

interface NationRaw {
  id: string;
  bonus_attribute: AttrKey;
  bonus_skill: SkillKey;
}

interface BackgroundRaw {
  id: string;
  name: L10nString;
  bio: L10nString;
  attribute_bonus: Partial<Record<AttrKey, number>>;
  skill_bonus: Partial<Record<SkillKey, number>>;
}

const NATIONS = (rawNations as { nations: NationRaw[] }).nations;
const BACKGROUNDS = (rawBackgrounds as { backgrounds: BackgroundRaw[] }).backgrounds;

interface StepperIds {
  row: string;
  name: string;
  value: string;
  sub: string;
  add: string;
}

/** The authored stepper ids (data/ui_layout.json `creation.points.*`). */
const ATTR_IDS: Record<AttrKey, StepperIds> = {
  constitution: {
    row: "points.attrs.constitution",
    name: "points.attrs.constitution.name",
    value: "points.attrs.constitution.value",
    sub: "points.attrs.constitution.sub",
    add: "points.attrs.constitution.add",
  },
  intellect: {
    row: "points.attrs.intellect",
    name: "points.attrs.intellect.name",
    value: "points.attrs.intellect.value",
    sub: "points.attrs.intellect.sub",
    add: "points.attrs.intellect.add",
  },
  charisma: {
    row: "points.attrs.charisma",
    name: "points.attrs.charisma.name",
    value: "points.attrs.charisma.value",
    sub: "points.attrs.charisma.sub",
    add: "points.attrs.charisma.add",
  },
  courage: {
    row: "points.attrs.courage",
    name: "points.attrs.courage.name",
    value: "points.attrs.courage.value",
    sub: "points.attrs.courage.sub",
    add: "points.attrs.courage.add",
  },
  luck: {
    row: "points.attrs.luck",
    name: "points.attrs.luck.name",
    value: "points.attrs.luck.value",
    sub: "points.attrs.luck.sub",
    add: "points.attrs.luck.add",
  },
};

const SKILL_IDS: Record<SkillKey, StepperIds> = {
  seamanship: {
    row: "points.skills.seamanship",
    name: "points.skills.seamanship.name",
    value: "points.skills.seamanship.value",
    sub: "points.skills.seamanship.sub",
    add: "points.skills.seamanship.add",
  },
  navigation: {
    row: "points.skills.navigation",
    name: "points.skills.navigation.name",
    value: "points.skills.navigation.value",
    sub: "points.skills.navigation.sub",
    add: "points.skills.navigation.add",
  },
  swordplay: {
    row: "points.skills.swordplay",
    name: "points.skills.swordplay.name",
    value: "points.skills.swordplay.value",
    sub: "points.skills.swordplay.sub",
    add: "points.skills.swordplay.add",
  },
  gunnery: {
    row: "points.skills.gunnery",
    name: "points.skills.gunnery.name",
    value: "points.skills.gunnery.value",
    sub: "points.skills.gunnery.sub",
    add: "points.skills.gunnery.add",
  },
  appraisal: {
    row: "points.skills.appraisal",
    name: "points.skills.appraisal.name",
    value: "points.skills.appraisal.value",
    sub: "points.skills.appraisal.sub",
    add: "points.skills.appraisal.add",
  },
  negotiation: {
    row: "points.skills.negotiation",
    name: "points.skills.negotiation.name",
    value: "points.skills.negotiation.value",
    sub: "points.skills.negotiation.sub",
    add: "points.skills.negotiation.add",
  },
  cartography: {
    row: "points.skills.cartography",
    name: "points.skills.cartography.name",
    value: "points.skills.cartography.value",
    sub: "points.skills.cartography.sub",
    add: "points.skills.cartography.add",
  },
  rumour: {
    row: "points.skills.rumour",
    name: "points.skills.rumour.name",
    value: "points.skills.rumour.value",
    sub: "points.skills.rumour.sub",
    add: "points.skills.rumour.add",
  },
};

interface BackgroundIds {
  card: string;
  name: string;
  bio: string;
  bonus: string;
}

/** The authored background-card ids (data/ui_layout.json `creation.cards`). */
const BACKGROUND_IDS: Record<string, BackgroundIds> = {
  background_deckhand: {
    card: "cards.background_deckhand",
    name: "cards.background_deckhand.name",
    bio: "cards.background_deckhand.bio",
    bonus: "cards.background_deckhand.bonus",
  },
  background_navy_cadet: {
    card: "cards.background_navy_cadet",
    name: "cards.background_navy_cadet.name",
    bio: "cards.background_navy_cadet.bio",
    bonus: "cards.background_navy_cadet.bonus",
  },
  background_merchant_apprentice: {
    card: "cards.background_merchant_apprentice",
    name: "cards.background_merchant_apprentice.name",
    bio: "cards.background_merchant_apprentice.bio",
    bonus: "cards.background_merchant_apprentice.bonus",
  },
  background_cartographer_apprentice: {
    card: "cards.background_cartographer_apprentice",
    name: "cards.background_cartographer_apprentice.name",
    bio: "cards.background_cartographer_apprentice.bio",
    bonus: "cards.background_cartographer_apprentice.bonus",
  },
  background_tavern_errand: {
    card: "cards.background_tavern_errand",
    name: "cards.background_tavern_errand.name",
    bio: "cards.background_tavern_errand.bio",
    bonus: "cards.background_tavern_errand.bonus",
  },
  background_fencing_student: {
    card: "cards.background_fencing_student",
    name: "cards.background_fencing_student.name",
    bio: "cards.background_fencing_student.bio",
    bonus: "cards.background_fencing_student.bonus",
  },
};

function sumAlloc(alloc: Record<string, number>): number {
  return Object.values(alloc).reduce((total, value) => total + Math.max(0, value), 0);
}

function cleanAlloc(alloc: Record<string, number>): Record<string, number> {
  return Object.fromEntries(Object.entries(alloc).filter(([, value]) => value > 0));
}

function percent(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

export function CreationScreen() {
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();

  // The S2 handoff is consumed once; a direct open falls back to the first
  // nation (the oracle's never-nation-less rule).
  const [nationId] = useState(() => takePendingNation() || NATIONS[0]?.id || "");
  const [backgroundId, setBackgroundId] = useState(BACKGROUNDS[0]?.id ?? "");
  const [step, setStep] = useState<1 | 2>(1);
  const [attrAlloc, setAttrAlloc] = useState<Record<string, number>>({});
  const [skillAlloc, setSkillAlloc] = useState<Record<string, number>>({});
  const [submitting, setSubmitting] = useState(false);

  const nation = NATIONS.find((entry) => entry.id === nationId) ?? NATIONS[0];
  const background = BACKGROUNDS.find((entry) => entry.id === backgroundId) ?? BACKGROUNDS[0];

  const remainingAttr = ATTR_TOTAL - sumAlloc(attrAlloc);
  const remainingSkill = SKILL_TOTAL - sumAlloc(skillAlloc);
  const remaining = remainingAttr + remainingSkill;

  const attrValue = (key: AttrKey, alloc: Record<string, number>): number =>
    BASE_ATTRIBUTE +
    (nation?.bonus_attribute === key ? NATION_BONUS : 0) +
    (background?.attribute_bonus[key] ?? 0) +
    (alloc[key] ?? 0);

  const skillValue = (key: SkillKey, alloc: Record<string, number>): number =>
    (nation?.bonus_skill === key ? NATION_BONUS : 0) +
    (background?.skill_bonus[key] ?? 0) +
    (alloc[key] ?? 0);

  const preview = (allocAttr: Record<string, number>, allocSkill: Record<string, number>) => {
    const navigation = skillValue("navigation", allocSkill);
    const seamanship = skillValue("seamanship", allocSkill);
    const swordplay = skillValue("swordplay", allocSkill);
    const courage = attrValue("courage", allocAttr);
    const sighting = SIGHTING_BASE + Math.floor(navigation / SIGHTING_NAV_DIVISOR);
    const speed = Math.min(SPEED_CAP, Math.max(0, seamanship / SPEED_DIVISOR));
    const duel = swordplay + Math.floor(courage / DUEL_COURAGE_DIVISOR);
    return { sighting, speed, duel };
  };

  const basePreview = preview({}, {});
  const draftPreview = preview(attrAlloc, skillAlloc);

  const stepStat = (
    ids: StepperIds,
    key: AttrKey | SkillKey,
    isAttr: boolean,
    alloc: Record<string, number>,
    remainingForKind: number,
    base: number,
  ) => {
    const rowId = ids.row;
    const spent = alloc[key] ?? 0;
    const atCap = spent >= ITEM_CAP;
    const canAdd = !atCap && remainingForKind > 0;
    return (
      <Element key={key} screen={SCREEN} id={rowId} parent="points">
        <LabelEl
          screen={SCREEN}
          id={ids.name}
          parent={rowId}
          textKey={isAttr ? `attr.${key}` : `skill.${key}`}
        />
        <LabelEl screen={SCREEN} id={ids.value} parent={rowId} textValue={String(base)} align="right" />
        <ButtonEl
          screen={SCREEN}
          id={ids.sub}
          parent={rowId}
          textKey="creation.stepper.sub"
          disabled={spent <= 0}
          onClick={() =>
            updateAlloc(isAttr, alloc, key, -1, remainingForKind, setAttrAlloc, setSkillAlloc)
          }
        />
        <ButtonEl
          screen={SCREEN}
          id={ids.add}
          parent={rowId}
          textKey="creation.stepper.add"
          disabled={!canAdd}
          titleKey={atCap ? "creation.cap_reached" : undefined}
          onClick={() =>
            updateAlloc(isAttr, alloc, key, 1, remainingForKind, setAttrAlloc, setSkillAlloc)
          }
        />
      </Element>
    );
  };

  const previewLine = (labelKey: string, base: string, value: string): string =>
    `${tKey(labelKey)} ${fmt("creation.preview.base_value", { base, value })}`;

  const submit = () => {
    if (remaining > 0 || submitting) return;
    setSubmitting(true);
    void client
      .newGame({
        nation_id: nationId,
        background_id: backgroundId,
        attr_alloc: cleanAlloc(attrAlloc),
        skill_alloc: cleanAlloc(skillAlloc),
      })
      .then((result) => {
        if (result.ok) {
          navigate("port");
        } else {
          showToast(result.error.msg || "error.bad_request", undefined, "bad");
        }
      })
      .finally(() => setSubmitting(false));
  };

  return (
    <>
      <PanelEl screen={SCREEN} id="background" skin="backdrop" />
      <LabelEl
        screen={SCREEN}
        id="title"
        textKey={step === 1 ? "creation.step.background" : "creation.step.points"}
        title
        align="center"
      />
      <LabelEl
        screen={SCREEN}
        id="prompt"
        textValue={
          step === 1
            ? background
              ? t(background.bio)
              : ""
            : fmt("creation.points.left", { count: remaining })
        }
        tone="dim"
        align="center"
      />

      <Element screen={SCREEN} id="cards" hidden={step !== 1}>
        {BACKGROUNDS.map((entry) => {
          const ids = BACKGROUND_IDS[entry.id];
          if (!ids) return null;
          return (
            <Element
              key={entry.id}
              screen={SCREEN}
              id={ids.card}
              parent="cards"
              as="button"
              skin={backgroundId === entry.id ? "button_focus" : "panel"}
              className="sa-card-button"
              onClick={() => setBackgroundId(entry.id)}
            >
              <LabelEl screen={SCREEN} id={ids.name} parent={ids.card} text={entry.name} heading />
              <LabelEl
                screen={SCREEN}
                id={ids.bio}
                parent={ids.card}
                textValue={t(entry.bio)}
                tone="dim"
              />
              <LabelEl
                screen={SCREEN}
                id={ids.bonus}
                parent={ids.card}
                textValue={bonusLine(entry, tKey, fmt)}
              />
            </Element>
          );
        })}
      </Element>

      <Element screen={SCREEN} id="points" hidden={step !== 2}>
        <LabelEl
          screen={SCREEN}
          id="points.attr_header"
          parent="points"
          textKey="creation.points.attributes"
          values={{ count: remainingAttr }}
          heading
        />
        <LabelEl
          screen={SCREEN}
          id="points.skill_header"
          parent="points"
          textKey="creation.points.skills"
          values={{ count: remainingSkill }}
          heading
        />

        {ATTRS.map((key) =>
          stepStat(ATTR_IDS[key], key, true, attrAlloc, remainingAttr, attrValue(key, attrAlloc)),
        )}
        {SKILLS.map((key) =>
          stepStat(SKILL_IDS[key], key, false, skillAlloc, remainingSkill, skillValue(key, skillAlloc)),
        )}

        <Element screen={SCREEN} id="points.spread" parent="points">
          <Box rect={{ x: 0, y: 0, w: 3, h: 2 }}>
            <Button
              textKey="creation.spread"
              fill
              onClick={() => {
                const attrs: Record<string, number> = {};
                for (const key of ATTRS) attrs[key] = 1;
                const skills: Record<string, number> = {};
                for (const key of SKILLS.slice(0, 3)) skills[key] = 1;
                setAttrAlloc(attrs);
                setSkillAlloc(skills);
              }}
            />
          </Box>
          <Box rect={{ x: 3, y: 0, w: 3, h: 2 }}>
            <Button
              textKey="ui.cancel"
              kind="quiet"
              fill
              onClick={() => {
                setAttrAlloc({});
                setSkillAlloc({});
              }}
            />
          </Box>
        </Element>

        <LabelEl
          screen={SCREEN}
          id="points.spend_hint"
          parent="points"
          textKey="creation.points.must_spend"
          tone="warn"
          hidden={remaining <= 0}
        />

        <LabelEl
          screen={SCREEN}
          id="points.preview.sighting"
          parent="points"
          textValue={previewLine(
            "creation.preview.sighting",
            String(basePreview.sighting),
            String(draftPreview.sighting),
          )}
          tone="dim"
        />
        <LabelEl
          screen={SCREEN}
          id="points.preview.speed"
          parent="points"
          textValue={previewLine(
            "creation.preview.speed",
            percent(basePreview.speed),
            percent(draftPreview.speed),
          )}
          tone="dim"
        />
        <LabelEl
          screen={SCREEN}
          id="points.preview.duel"
          parent="points"
          textValue={previewLine(
            "creation.preview.duel",
            String(basePreview.duel),
            String(draftPreview.duel),
          )}
          tone="dim"
        />
      </Element>

      <ButtonEl
        screen={SCREEN}
        id="back"
        textKey="ui.back"
        onClick={() => (step === 1 ? navigate("nationality_select") : setStep(1))}
      />
      <ButtonEl
        screen={SCREEN}
        id="confirm"
        textKey={step === 1 ? "creation.next" : "creation.confirm"}
        kind="primary"
        disabled={(step === 2 && remaining > 0) || submitting}
        onClick={() => (step === 1 ? setStep(2) : submit())}
      />

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}

/** One stepper click: + refuses beyond the per-item cap / empty pool. */
function updateAlloc(
  isAttr: boolean,
  alloc: Record<string, number>,
  key: string,
  delta: number,
  remaining: number,
  setAttr: (next: Record<string, number>) => void,
  setSkill: (next: Record<string, number>) => void,
): void {
  const current = Math.max(0, alloc[key] ?? 0);
  if (delta > 0 && (current >= ITEM_CAP || remaining <= 0)) return;
  if (delta < 0 && current <= 0) return;
  const next = { ...alloc, [key]: current + delta };
  if (next[key] <= 0) delete next[key];
  (isAttr ? setAttr : setSkill)(next);
}

/** "体魄+3/操船+5" — the L10nString supplies only the frame. */
function bonusLine(
  background: BackgroundRaw,
  tKey: (key: string) => string,
  fmt: (key: string, values: Record<string, string | number>) => string,
): string {
  const attrKey = Object.keys(background.attribute_bonus)[0] ?? "";
  const skillKey = Object.keys(background.skill_bonus)[0] ?? "";
  return fmt("creation.bonus_line", {
    attr: attrKey ? tKey(`attr.${attrKey}`) : "",
    attr_n: background.attribute_bonus[attrKey as AttrKey] ?? 0,
    skill: skillKey ? tKey(`skill.${skillKey}`) : "",
    skill_n: background.skill_bonus[skillKey as SkillKey] ?? 0,
  });
}
