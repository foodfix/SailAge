/**
 * S20 creation — the locked two-step new-game flow (docs/80-UI-UX.md
 * §4.13, §4.9.1; docs/50-* §4.1 steps 1–6).
 *
 *   ① background — the six `data/backgrounds.json` cards (name / bio /
 *     composed bonus line; each grants one attribute +3 and one skill +5).
 *   ② free points — attributes +5 total, skills +3 total, per-item cap +3,
 *     all points must be spent; the spread shortcut spends attributes +1
 *     each and the first three skills +1 each.
 *
 * The composition (§4.9.1): one centered window over the scene whose title
 * band names the active step; the body swaps the background-card grid for
 * the stepper list (attribute header, five attribute rows, skill header,
 * eight skill rows, the spread/cancel pair, the must-spend hint and the
 * three pinned preview lines) with the back/confirm footer beneath.
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
import type { ScreenId } from "./ids";
import { Button, Footer, Frame, Toast } from "../kit";
import { Label, useToastState } from "./common";
import { navigate } from "../app/router";
import { takePendingNation } from "./NationalitySelect";
import "./Creation.css";

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
    key: AttrKey | SkillKey,
    isAttr: boolean,
    alloc: Record<string, number>,
    remainingForKind: number,
    base: number,
  ) => {
    const spent = alloc[key] ?? 0;
    const atCap = spent >= ITEM_CAP;
    const canAdd = !atCap && remainingForKind > 0;
    return (
      <div key={key} className="creation__stat">
        <Label
          className="creation__stat_name"
          textKey={isAttr ? `attr.${key}` : `skill.${key}`}
        />
        <Label className="creation__stat_value" textValue={String(base)} align="right" />
        <Button
          textKey="creation.stepper.sub"
          compact
          disabled={spent <= 0}
          onClick={() =>
            updateAlloc(isAttr, alloc, key, -1, remainingForKind, setAttrAlloc, setSkillAlloc)
          }
        />
        <Button
          textKey="creation.stepper.add"
          compact
          disabled={!canAdd}
          titleKey={atCap ? "creation.cap_reached" : undefined}
          onClick={() =>
            updateAlloc(isAttr, alloc, key, 1, remainingForKind, setAttrAlloc, setSkillAlloc)
          }
        />
      </div>
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
    <div className="sa-screen creation" data-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />

      <div className="sa-fill-center creation__layer">
        <Frame
          titleKey={step === 1 ? "creation.step.background" : "creation.step.points"}
          className="creation__window"
          scroll
        >
          <Label
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

          {step === 1 ? (
            <div className="creation__cards">
              {BACKGROUNDS.map((entry) => (
                <Button
                  key={entry.id}
                  fill
                  kind={backgroundId === entry.id ? "primary" : "default"}
                  onClick={() => setBackgroundId(entry.id)}
                >
                  <span className="sa-button__stack">
                    <Label text={entry.name} heading />
                    <Label textValue={t(entry.bio)} tone="dim" />
                    <Label textValue={bonusLine(entry, tKey, fmt)} />
                  </span>
                </Button>
              ))}
            </div>
          ) : (
            <>
              <Label
                className="creation__header"
                textKey="creation.points.attributes"
                values={{ count: remainingAttr }}
                heading
              />
              {ATTRS.map((key) =>
                stepStat(key, true, attrAlloc, remainingAttr, attrValue(key, attrAlloc)),
              )}

              <Label
                className="creation__header"
                textKey="creation.points.skills"
                values={{ count: remainingSkill }}
                heading
              />
              {SKILLS.map((key) =>
                stepStat(key, false, skillAlloc, remainingSkill, skillValue(key, skillAlloc)),
              )}

              <div className="creation__spread">
                <Button
                  textKey="creation.spread"
                  onClick={() => {
                    const attrs: Record<string, number> = {};
                    for (const key of ATTRS) attrs[key] = 1;
                    const skills: Record<string, number> = {};
                    for (const key of SKILLS.slice(0, 3)) skills[key] = 1;
                    setAttrAlloc(attrs);
                    setSkillAlloc(skills);
                  }}
                />
                <Button
                  textKey="ui.cancel"
                  kind="quiet"
                  onClick={() => {
                    setAttrAlloc({});
                    setSkillAlloc({});
                  }}
                />
              </div>

              {remaining > 0 ? (
                <Label className="creation__hint" textKey="creation.points.must_spend" tone="warn" />
              ) : null}

              <Label
                className="creation__preview"
                textValue={previewLine(
                  "creation.preview.sighting",
                  String(basePreview.sighting),
                  String(draftPreview.sighting),
                )}
                tone="dim"
              />
              <Label
                className="creation__preview"
                textValue={previewLine(
                  "creation.preview.speed",
                  percent(basePreview.speed),
                  percent(draftPreview.speed),
                )}
                tone="dim"
              />
              <Label
                className="creation__preview"
                textValue={previewLine(
                  "creation.preview.duel",
                  String(basePreview.duel),
                  String(draftPreview.duel),
                )}
                tone="dim"
              />
            </>
          )}

          <div className="creation__footer">
            <Footer
              buttons={[
                <Button
                  key="back"
                  textKey="ui.back"
                  onClick={() => (step === 1 ? navigate("nationality_select") : setStep(1))}
                />,
                <Button
                  key="confirm"
                  textKey={step === 1 ? "creation.next" : "creation.confirm"}
                  kind="primary"
                  disabled={(step === 2 && remaining > 0) || submitting}
                  onClick={() => (step === 1 ? setStep(2) : submit())}
                />,
              ]}
            />
          </div>
        </Frame>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
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
