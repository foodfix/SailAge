/**
 * The unified character card (docs/80-UI-UX.md §4.12.1 — locked layout; the
 * §4.9.1 composition). One renderer for every Person: the player, an
 * employed officer, or an NPC captain. The card is a flow column: the
 * portrait+name identity header, the attribute/skill tables (with the
 * §4.12.2 allocation steppers for the player), the personality/appearance
 * chips, the relations lines and the career lines. The standalone route
 * hosts the same column in a centered parchment window (`StandaloneFrame`).
 *
 * The identity pin is literal: the same person renders the same data from
 * the intel captain tab, the dossier, the officer detail page and the
 * rigged picker. IDENTIFY = FULL REVEAL — no number is familiarity-gated
 * (only the dossier career log is; §4.11.3).
 *
 * Server contract (reported, not patched): `GET /api/view/character_card`
 * does not exist yet, so the card assembles its *display* from the
 * authoritative `state` (player/officer/captain blocks) plus the static
 * canon records (`data/officers.json`, `data/captains.json`). The missing
 * projection is the §4.5.3 effective-value split (base + in-post
 * contribution), the usage-growth threshold, the XP-to-next-level read and
 * the wage multiplier. The card shows the stored values and marks the gap;
 * it computes no rule.
 */
import { useMemo, useState } from "react";
import { content, useI18n } from "../i18n";
import type { L10nString } from "../i18n";
import { useGameState } from "../state/context";
import { useGameClient } from "../client/context";
import type { GameSnapshot } from "../state/types";
import type { PersonKind } from "../state/views";
import { Button, Footer, Icon, Row, ValueBar } from "../kit";
import { Label, StandaloneFrame } from "./common";
import rawCaptains from "../../../data/captains.json";
import rawGates from "../../../data/skill_gates.json";
import "./CharacterCard.css";

export const ATTRIBUTE_KEYS = [
  "constitution",
  "intellect",
  "charisma",
  "courage",
  "luck",
] as const;

export const PLAYER_SKILL_KEYS = [
  "seamanship",
  "navigation",
  "swordplay",
  "gunnery",
  "appraisal",
  "negotiation",
  "cartography",
  "rumour",
] as const;

export const OFFICER_SKILL_KEYS = ["medicine", "carpentry", "cooking"] as const;

interface CanonPerson {
  id: string;
  name: L10nString;
  nation_id: string;
  role?: string;
  tier?: number;
  level?: number;
  main_skill?: string;
  attributes: Record<string, number>;
  skills: Record<string, number>;
  personality?: string[];
  appearance?: Record<string, string>;
  home_port?: string;
  wage_daily?: number;
  recruit_ports?: string[];
}

interface GateDef {
  feature_id: string;
  name: L10nString;
  stat_or_skill: string;
  threshold: number;
  reason: L10nString;
}

const CAPTAINS = new Map(
  ((rawCaptains as { captains: CanonPerson[] }).captains).map((card) => [card.id, card]),
);
const GATES = (rawGates as { skill_gates: GateDef[] }).skill_gates;

function officerCanon(id: string): CanonPerson | undefined {
  return content.officer(id) as unknown as CanonPerson | undefined;
}

export function captainCanon(id: string): CanonPerson | undefined {
  return CAPTAINS.get(id);
}

export interface CharacterCardProps {
  kind: PersonKind;
  personId?: string;
  /** Player card: render the §4.12.2 allocation steppers. */
  alloc?: boolean;
  /** The officer detail page opt-out (amended 2026-11-03). */
  statBlocks?: boolean;
  /** Standalone route host (`#/character_card`). */
  standalone?: boolean;
}

interface CardData {
  kind: PersonKind;
  personId: string;
  name: L10nString;
  nationId: string;
  roleKey: string;
  tier: number;
  level: number;
  mainSkill: string;
  loyalty: number;
  postId: string;
  stance: number;
  familiarity: number;
  wins: number;
  defeats: number;
  status: "active" | "returning";
  returnDay: number;
  xp: number;
  nextXp: number;
  allocPending: number;
  attributes: Record<string, number>;
  skills: Record<string, number>;
  skillKeys: string[];
  grayed: string[];
  uses: Record<string, number>;
  personality: string[];
  appearance: Record<string, string>;
}

function pickInt(source: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (!source || typeof source !== "object") return out;
  for (const [key, value] of Object.entries(source as Record<string, unknown>)) {
    out[key] = Number(value ?? 0);
  }
  return out;
}

function buildCard(kind: PersonKind, personId: string, state: GameSnapshot): CardData | null {
  const base: CardData = {
    kind,
    personId,
    name: { zh: "", en: "" },
    nationId: "",
    roleKey: "char.none",
    tier: 0,
    level: 0,
    mainSkill: "",
    loyalty: -1,
    postId: "",
    stance: 0,
    familiarity: 0,
    wins: 0,
    defeats: 0,
    status: "active",
    returnDay: 0,
    xp: -1,
    nextXp: -1,
    allocPending: 0,
    attributes: {},
    skills: {},
    skillKeys: [...PLAYER_SKILL_KEYS],
    grayed: [...OFFICER_SKILL_KEYS],
    uses: {},
    personality: [],
    appearance: {},
  };

  if (kind === "player") {
    const player = state.player;
    return {
      ...base,
      name: { zh: "", en: "" },
      nationId: player.nation_id,
      roleKey: "char.title",
      level: player.level,
      attributes: pickInt(player.attributes),
      skills: { ...pickInt(player.skills), medicine: 0, carpentry: 0, cooking: 0 },
      skillKeys: [...PLAYER_SKILL_KEYS, ...OFFICER_SKILL_KEYS],
      uses: pickInt(player.skill_counters),
      xp: player.xp,
      allocPending: player.alloc_pending,
    };
  }

  if (kind === "officer") {
    const canon = officerCanon(personId);
    if (!canon) return null;
    const row = state.officer_states[personId];
    return {
      ...base,
      name: canon.name,
      nationId: canon.nation_id,
      roleKey: `skill.${canon.main_skill ?? ""}`,
      mainSkill: canon.main_skill ?? "",
      attributes: pickInt(canon.attributes),
      skills: pickInt(canon.skills),
      skillKeys: [...PLAYER_SKILL_KEYS, ...OFFICER_SKILL_KEYS],
      grayed: [...OFFICER_SKILL_KEYS],
      personality: canon.personality ?? [],
      appearance: canon.appearance ?? {},
      loyalty: row?.loyalty ?? 50,
      postId: row?.post_id ?? "",
      defeats: row?.defeats ?? 0,
    };
  }

  const canon = captainCanon(personId);
  if (!canon) return null;
  const row = state.captain_states[personId] as
    | {
        tier_now?: number;
        stance?: number;
        familiarity?: number;
        wins?: number;
        defeats?: number;
        status?: string;
        return_day?: number;
      }
    | undefined;
  return {
    ...base,
    name: canon.name,
    nationId: canon.nation_id,
    roleKey: canon.role ? `captain.role.${canon.role}` : "char.none",
    tier: row?.tier_now ?? canon.tier ?? 1,
    level: canon.level ?? 1,
    attributes: pickInt(canon.attributes),
    skills: pickInt(canon.skills),
    skillKeys: [...PLAYER_SKILL_KEYS],
    grayed: [],
    personality: canon.personality ?? [],
    appearance: canon.appearance ?? {},
    stance: row?.stance ?? 0,
    familiarity: row?.familiarity ?? 0,
    wins: row?.wins ?? 0,
    defeats: row?.defeats ?? 0,
    status: row?.status === "returning" ? "returning" : "active",
    returnDay: row?.return_day ?? 0,
  };
}

function barTier(value: number): "good" | "warn" | "bad" {
  if (value >= 60) return "good";
  if (value >= 30) return "warn";
  return "bad";
}

function portraitCloth(kind: PersonKind, personId: string): string {
  if (kind === "player") return "pp_cloth_player";
  if (kind === "officer") {
    const officer = personId ? officerCanon(personId) : undefined;
    return `pp_cloth_${officer ? "player" : "trader"}`;
  }
  const canon = personId ? captainCanon(personId) : undefined;
  return `pp_cloth_${canon?.role ?? "trader"}`;
}

export function CharacterCard({
  kind,
  personId = "",
  alloc = false,
  statBlocks = true,
  standalone = false,
}: CharacterCardProps) {
  const { state } = useGameState();
  const client = useGameClient();
  const { t, tKey, fmt } = useI18n();
  const data = useMemo(() => buildCard(kind, personId, state), [kind, personId, state]);
  const [draft, setDraft] = useState<Record<string, number>>({});

  if (!data) {
    return <div className="sa-cell" data-character-card="missing">{tKey("ui.not_available")}</div>;
  }

  const statTip = (key: string): string => tKey(`char.attr.${key}.desc`);
  const gateLines = (key: string, value: number): string[] =>
    GATES.filter((gate) => gate.stat_or_skill === key).map((gate) => {
      const stateKey = value >= gate.threshold ? "gate.unlocked" : "gate.locked";
      return `${t(gate.name)} · ${fmt("gate.requires", {
        stat: tKey(`skill.${key}`),
        n: gate.threshold,
      })} · ${tKey(stateKey)} (${value}/${gate.threshold})`;
    });
  const skillTip = (key: string): string => {
    const base = data.mainSkill && key === data.mainSkill
      ? Number(data.skills[key] ?? 0)
      : Number(data.skills[key] ?? 0);
    const lines = [
      fmt("char.card.tip.base", { base }),
      fmt("char.card.tip.effective", { total: base }),
      ...gateLines(key, base),
    ];
    return [tKey(`skill.${key}.desc`), ...lines].join("\n");
  };

  const attributeRows = ATTRIBUTE_KEYS.map((key) => {
    const value = Number(data.attributes[key] ?? 0);
    return (
      <Row key={key} cols={[
        <span className="sa-cell" title={statTip(key)}>
          {tKey(`char.attr.${key}`)}
        </span>,
        <div className="sa-cell" title={statTip(key)}>
          <ValueBar value={value} max={100} tier={barTier(value)} />
        </div>,
        <span className="sa-cell sa-cell--right" title={statTip(key)}>
          {value}
        </span>,
        ...(alloc && kind === "player" ? [
          <Button
            key={`${key}_plus`}
            text={String.fromCharCode(0x2b)}
            kind="quiet"
            disabled={data.allocPending <= 0 || value + (draft[key] ?? 0) >= 100}
            titleKey="char.points_pending"
            fill
            onClick={() =>
              setDraft((current) => ({ ...current, [key]: (current[key] ?? 0) + 1 }))
            }
          />,
        ] : []),
      ]} />
    );
  });

  const skillRows = data.skillKeys.map((key) => {
    const value = Number(data.skills[key] ?? 0);
    const grayed = data.grayed.includes(key);
    const signature = data.mainSkill !== "" && data.mainSkill === key;
    const tone = value <= 0 || grayed ? " sa-label--dim" : signature ? " sa-label--accent" : "";
    const tip = skillTip(key);
    return (
      <Row key={key} cols={[
        <span className={`sa-cell${tone}`} title={tip}>
          {tKey(`skill.${key}`)}
        </span>,
        <div className="sa-cell" title={tip}>
          <ValueBar value={value} max={100} tier={signature ? "warn" : "good"} />
        </div>,
        <span className="sa-cell sa-cell--right" title={tip}>
          {value}
        </span>,
        ...(kind === "player" && !grayed ? [
          <span key={`${key}_uses`} className="sa-cell sa-label--dim" title={tip}>
            {Number(data.uses[key] ?? 0)}
          </span>,
        ] : []),
      ]} />
    );
  });

  const appearance = ["face", "beard", "eyes", "hair"]
    .map((axis) => {
      const value = data.appearance[axis];
      return value ? tKey(`char.appearance.${axis}.${value}`) : "";
    })
    .filter((part) => part !== "")
    .join(" · ");

  const personality = data.personality
    .map((tag) => tKey(`char.personality.${tag}`))
    .join(" · ");

  const cloth = portraitCloth(kind, personId);
  const portraitSprites = [
    "pp_base",
    `pp_face_${data.appearance.face ?? "lean"}`,
    `pp_hair_${data.appearance.hair ?? "brown"}`,
    `pp_eyes_${data.appearance.eyes ?? "grey"}`,
    `pp_beard_${data.appearance.beard ?? "clean"}`,
    cloth,
  ];

  const card = (
    <div className="card" data-character-card={kind}>
      <div className="card__identity">
        <div className="card__portrait" aria-hidden="true">
          {portraitSprites.map((sprite) => (
            <Icon key={sprite} id={sprite} />
          ))}
        </div>
        <div className="card__flag" aria-hidden="true">
          <span className={`sa-nation-swatch sa-nation-swatch--${data.nationId}`} />
        </div>
        <div className="card__names">
          <Label textValue={kind === "player" ? tKey("char.title") : t(data.name)} heading />
          <Label textValue={tKey(data.roleKey)} tone="dim" />
        </div>
        {kind === "npc" ? (
          <div className="card__tier">
            <span className="sa-badge">{data.tier}</span>
          </div>
        ) : null}
        {data.level > 0 ? (
          <Label
            className="card__level"
            textValue={fmt("char.level", { level: data.level })}
            align="right"
          />
        ) : null}
      </div>

      {statBlocks ? (
        <div className="card__stats">
          <div className="card__stat_col">
            <Label textKey="char.card.attributes" heading />
            <div className="sa-table card__attr_table">
              {attributeRows}
            </div>
          </div>
          <div className="card__stat_col">
            <Label textKey="char.card.skills" heading />
            <div className="sa-table card__skill_table">
              {skillRows}
            </div>
          </div>
        </div>
      ) : null}

      <div className="card__tags">
        {personality !== "" ? (
          <span className="sa-chip">
            <Label textValue={fmt("char.personality_line", { tags: personality })} />
          </span>
        ) : null}
        {appearance !== "" ? (
          <span className="sa-chip">
            <Label textValue={fmt("char.appearance.sentence", { parts: appearance })} tone="dim" />
          </span>
        ) : null}
      </div>

      <Label textKey="char.card.relations" heading />
      <div className="card__lines">
        {kind === "officer" ? (
          <>
            <Label textValue={fmt("char.card.loyalty", { amount: data.loyalty })} />
            <Label
              tone="dim"
              textValue={data.postId ? tKey(`officer.post.${data.postId}`) : tKey("officer.post.idle")}
            />
          </>
        ) : null}
        {kind === "npc" ? (
          <>
            <Label textValue={fmt("char.rep_value", { amount: data.stance })} />
            <Label tone="dim" textValue={`${tKey("dossier.familiarity")}: ${data.familiarity}`} />
          </>
        ) : null}
        {kind === "player" ? <Label tone="dim" textKey="char.none" /> : null}
      </div>

      <Label textKey="char.card.career" heading />
      <div className="card__lines">
        {kind === "npc" ? (
          <>
            <Label
              textValue={`${fmt("char.card.wins", { amount: data.wins })} · ${fmt("char.card.defeats", { amount: data.defeats })}`}
            />
            {data.status === "returning" ? (
              <Label tone="dim" textValue={fmt("char.card.return_day", { day: data.returnDay })} />
            ) : null}
          </>
        ) : null}
        {kind === "player" ? (
          <>
            <Label textValue={fmt("char.xp", { xp: data.xp })} />
            <Label tone="dim" textKey="ui.not_available" />
          </>
        ) : null}
        {kind === "officer" ? <Label tone="dim" textKey="ui.empty" /> : null}
      </div>

      {alloc && kind === "player" ? (
        <div className="card__alloc">
          <Label textKey="char.points_pending" />
          <Label
            tone="dim"
            textValue={fmt("creation.points.left", { count: data.allocPending })}
          />
          <Label
            tone="dim"
            textValue={fmt("creation.points.attributes", {
              count: Object.values(draft).reduce((a, b) => a + b, 0),
            })}
          />
          <Footer buttons={[
            <Button
              key="alloc_confirm"
              textKey="ui.confirm"
              kind="primary"
              disabled={Object.keys(draft).length === 0}
              onClick={() => {
                void client
                  .action("people", "allocate", { draft })
                  .then((result) => {
                    if (result.ok) setDraft({});
                  });
              }}
              fill
            />,
            <Button key="alloc_cancel" textKey="ui.cancel" onClick={() => setDraft({})} fill />,
          ]} />
        </div>
      ) : null}
    </div>
  );

  if (!standalone) return card;

  return (
    <StandaloneFrame scroll className="card__standalone">
      {card}
    </StandaloneFrame>
  );
}
