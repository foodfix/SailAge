/**
 * The unified character card (docs/80-UI-UX.md §4.12.1 — locked layout).
 *
 * One renderer for every Person: the player, an employed officer, or an NPC
 * captain. The identity pin is literal: the same person renders the same
 * data from the intel captain tab, the dossier, the officer detail page and
 * the rigged picker. IDENTIFY = FULL REVEAL — no number is familiarity-gated
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
import type { ReactNode } from "react";
import { content, useI18n } from "../i18n";
import type { L10nString } from "../i18n";
import { useGameState } from "../state/context";
import type { GameSnapshot } from "../state/types";
import type { PersonKind } from "../state/views";
import { Box, Element, ListRows, tile, type ScreenId } from "../layout";
import { Button, Icon, ValueBar } from "../kit";
import { Box as RectBox } from "../layout";
import rawCaptains from "../../../data/captains.json";
import rawGates from "../../../data/skill_gates.json";

const SCREEN: ScreenId = "character_card";

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

function portraitCloth(kind: PersonKind, data: CharacterCardProps): string {
  if (kind === "player") return "pp_cloth_player";
  if (kind === "officer") {
    const officer = data.personId ? officerCanon(data.personId) : undefined;
    return `pp_cloth_${officer ? "player" : "trader"}`;
  }
  const canon = data.personId ? captainCanon(data.personId) : undefined;
  return `pp_cloth_${canon?.role ?? "trader"}`;
}

/** One registered row whose authored ui_layout rect overlaps a sibling. */
function FixedEl({
  id,
  rect,
  hidden,
  children,
}: {
  id: string;
  rect: { x: number; y: number; w: number; h: number };
  hidden?: boolean;
  children?: ReactNode;
}) {
  return (
    <div
      className="sa-el"
      data-element-id={id}
      data-screen={SCREEN}
      hidden={hidden}
      style={{
        left: tile(rect.x),
        top: tile(rect.y),
        width: tile(rect.w),
        height: tile(rect.h),
      }}
    >
      {children}
    </div>
  );
}

export function CharacterCard({
  kind,
  personId = "",
  alloc = false,
  statBlocks = true,
  standalone = false,
}: CharacterCardProps) {
  const { state } = useGameState();
  const { t, tKey, fmt } = useI18n();
  const data = useMemo(() => buildCard(kind, personId, state), [kind, personId, state]);
  const [draft, setDraft] = useState<Record<string, number>>({});

  if (!data) {
    return (
      <RectBox rect={{ x: 0, y: 0, w: 15, h: 4 }}>
        <div className="sa-cell">{tKey("ui.not_available")}</div>
      </RectBox>
    );
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
      <div key={key} data-row={key}>
        <Box rect={{ x: 0, y: 0, w: 5, h: 1 }}>
          <span className="sa-cell" title={statTip(key)}>
            {tKey(`char.attr.${key}`)}
          </span>
        </Box>
        <Box rect={{ x: 5, y: 0, w: 6, h: 1 }}>
          <div className="sa-cell" title={statTip(key)}>
            <ValueBar value={value} max={100} tier={barTier(value)} />
          </div>
        </Box>
        <Box rect={{ x: 11, y: 0, w: 1, h: 1 }}>
          <span className="sa-cell sa-label--right" title={statTip(key)}>
            {value}
          </span>
        </Box>
        {alloc && kind === "player" ? (
          <Box rect={{ x: 12, y: 0, w: 2, h: 1 }}>
            <Button
              text={String.fromCharCode(0x2b)}
              kind="quiet"
              disabled={data.allocPending <= 0 || value + (draft[key] ?? 0) >= 100}
              titleKey="char.points_pending"
              fill
              onClick={() =>
                setDraft((current) => ({ ...current, [key]: (current[key] ?? 0) + 1 }))
              }
            />
          </Box>
        ) : null}
      </div>
    );
  });

  const skillRows = data.skillKeys.map((key) => {
    const value = Number(data.skills[key] ?? 0);
    const grayed = data.grayed.includes(key);
    const signature = data.mainSkill !== "" && data.mainSkill === key;
    const tone = value <= 0 || grayed ? "dim" : signature ? "accent" : "default";
    return (
      <div key={key} data-row={key}>
        <Box rect={{ x: 0, y: 0, w: 4, h: 1 }}>
          <span className={`sa-cell${tone === "dim" ? " sa-label--dim" : tone === "accent" ? " sa-label--accent" : ""}`} title={skillTip(key)}>
            {tKey(`skill.${key}`)}
          </span>
        </Box>
        <Box rect={{ x: 4, y: 0, w: 6, h: 1 }}>
          <div className="sa-cell" title={skillTip(key)}>
            <ValueBar value={value} max={100} tier={signature ? "warn" : "good"} />
          </div>
        </Box>
        <Box rect={{ x: 10, y: 0, w: 2, h: 1 }}>
          <span className="sa-cell sa-label--right" title={skillTip(key)}>
            {value}
          </span>
        </Box>
        {kind === "player" && !grayed ? (
          <Box rect={{ x: 12, y: 0, w: 3, h: 1 }}>
            <span className="sa-cell sa-label--dim" title={skillTip(key)}>
              {Number(data.uses[key] ?? 0)}
            </span>
          </Box>
        ) : null}
      </div>
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

  const cloth = portraitCloth(kind, { kind, personId });

  const card = (
    <div
      className="sa-list-content"
      style={{ width: tile(15), height: tile(34) }}
      data-character-card={kind}
    >
      <Element screen={SCREEN} id="identity">
        <Element screen={SCREEN} id="identity.portrait" parent="identity">
          {["pp_base", `pp_face_${data.appearance.face ?? "lean"}`, `pp_hair_${data.appearance.hair ?? "brown"}`, `pp_eyes_${data.appearance.eyes ?? "grey"}`, `pp_beard_${data.appearance.beard ?? "clean"}`, cloth].map(
            (sprite) => (
              <Box key={sprite} rect={{ x: 0, y: 0, w: 3, h: 3 }}>
                <Icon id={sprite} />
              </Box>
            ),
          )}
        </Element>
        <Element screen={SCREEN} id="identity.flag" parent="identity">
          <span className={`sa-nation-swatch sa-nation-swatch--${data.nationId}`} aria-hidden="true" />
        </Element>
        <Element screen={SCREEN} id="identity.names" parent="identity">
          <Element screen={SCREEN} id="identity.names.name" parent="identity.names">
            <div className="sa-cell sa-label--heading">
              {kind === "player" ? tKey("char.title") : t(data.name)}
            </div>
          </Element>
          <Element screen={SCREEN} id="identity.names.role" parent="identity.names">
            <div className="sa-cell sa-label--dim">{tKey(data.roleKey)}</div>
          </Element>
        </Element>
        <Element screen={SCREEN} id="identity.tier_badge" parent="identity" hidden={kind !== "npc"}>
          <span className="sa-badge">{data.tier}</span>
        </Element>
        <Element screen={SCREEN} id="identity.level" parent="identity" hidden={data.level <= 0}>
          <div className="sa-cell sa-label--right">
            {fmt("char.level", { level: data.level })}
          </div>
        </Element>
      </Element>

      <Element screen={SCREEN} id="stat_columns" hidden={!statBlocks}>
        <Element screen={SCREEN} id="stat_columns.attribute_column" parent="stat_columns">
          <Element
            screen={SCREEN}
            id="stat_columns.attribute_column.header"
            parent="stat_columns.attribute_column"
          >
            <div className="sa-cell sa-label--heading">{tKey("char.card.attributes")}</div>
          </Element>
          <Element
            screen={SCREEN}
            id="stat_columns.attribute_column.attributes"
            parent="stat_columns.attribute_column"
          >
            <ListRows
              screen={SCREEN}
              listId="attributes"
              count={attributeRows.length}
              renderRow={(index) => attributeRows[index]}
            />
          </Element>
        </Element>
        <Element screen={SCREEN} id="stat_columns.skill_column" parent="stat_columns">
          <Element
            screen={SCREEN}
            id="stat_columns.skill_column.header"
            parent="stat_columns.skill_column"
          >
            <div className="sa-cell sa-label--heading">{tKey("char.card.skills")}</div>
          </Element>
          <Element
            screen={SCREEN}
            id="stat_columns.skill_column.skills"
            parent="stat_columns.skill_column"
          >
            <ListRows
              screen={SCREEN}
              listId="skills"
              count={skillRows.length}
              renderRow={(index) => skillRows[index]}
            />
          </Element>
        </Element>
      </Element>

      <Element screen={SCREEN} id="tags">
        <Element screen={SCREEN} id="tags.personality" parent="tags">
          <div className="sa-cell">
            {personality
              ? fmt("char.personality_line", { tags: personality })
              : ""}
          </div>
        </Element>
        <Element screen={SCREEN} id="tags.appearance" parent="tags">
          <div className="sa-cell sa-label--dim">
            {appearance ? fmt("char.appearance.sentence", { parts: appearance }) : ""}
          </div>
        </Element>
      </Element>

      <Element screen={SCREEN} id="relations.header">
        <div className="sa-cell sa-label--heading">{tKey("char.card.relations")}</div>
      </Element>
      <Element screen={SCREEN} id="relations">
        <FixedEl id="relations.loyalty" rect={{ x: 0, y: 0, w: 15, h: 1 }} hidden={kind !== "officer"}>
          <div className="sa-cell">
            {fmt("char.card.loyalty", { amount: data.loyalty })}
          </div>
        </FixedEl>
        <FixedEl id="relations.post" rect={{ x: 0, y: 1, w: 15, h: 1 }} hidden={kind !== "officer"}>
          <div className="sa-cell sa-label--dim">
            {data.postId ? tKey(`officer.post.${data.postId}`) : tKey("officer.post.idle")}
          </div>
        </FixedEl>
        <FixedEl id="relations.stance" rect={{ x: 0, y: 0, w: 15, h: 1 }} hidden={kind !== "npc"}>
          <div className="sa-cell">
            {fmt("char.rep_value", { amount: data.stance })}
          </div>
        </FixedEl>
        <FixedEl id="relations.tier" rect={{ x: 0, y: 1, w: 15, h: 1 }} hidden={kind !== "npc"}>
          <div className="sa-cell sa-label--dim">
            {`${tKey("dossier.familiarity")}: ${data.familiarity}`}
          </div>
        </FixedEl>
        <FixedEl id="relations.empty" rect={{ x: 0, y: 0, w: 15, h: 1 }} hidden={kind !== "player"}>
          <div className="sa-cell sa-label--dim">{tKey("char.none")}</div>
        </FixedEl>
      </Element>

      <Element screen={SCREEN} id="career.header">
        <div className="sa-cell sa-label--heading">{tKey("char.card.career")}</div>
      </Element>
      <Element screen={SCREEN} id="career">
        <Element screen={SCREEN} id="career.record" parent="career" hidden={kind !== "npc"}>
          <div className="sa-cell">
            {`${fmt("char.card.wins", { amount: data.wins })} · ${fmt("char.card.defeats", { amount: data.defeats })}`}
          </div>
        </Element>
        <Element screen={SCREEN} id="career.returning" parent="career" hidden={kind !== "npc" || data.status !== "returning"}>
          <div className="sa-cell sa-label--dim">
            {fmt("char.card.return_day", { day: data.returnDay })}
          </div>
        </Element>
        <FixedEl id="career.xp" rect={{ x: 0, y: 0, w: 15, h: 1 }} hidden={kind !== "player"}>
          <div className="sa-cell">{fmt("char.xp", { xp: data.xp })}</div>
        </FixedEl>
        <FixedEl id="career.next" rect={{ x: 0, y: 1, w: 15, h: 1 }} hidden={kind !== "player"}>
          <div className="sa-cell sa-label--dim">{tKey("ui.not_available")}</div>
        </FixedEl>
        <FixedEl id="career.empty" rect={{ x: 0, y: 0, w: 15, h: 1 }} hidden={kind === "npc" || kind === "player"}>
          <div className="sa-cell sa-label--dim">{tKey("ui.empty")}</div>
        </FixedEl>
      </Element>

      <Element screen={SCREEN} id="allocation" hidden={!alloc || kind !== "player"}>
        <Element screen={SCREEN} id="allocation.pending" parent="allocation">
          <div className="sa-cell">{tKey("char.points_pending")}</div>
        </Element>
        <Element screen={SCREEN} id="allocation.left" parent="allocation">
          <div className="sa-cell sa-label--dim">
            {fmt("creation.points.left", { count: data.allocPending })}
          </div>
        </Element>
        <Element screen={SCREEN} id="allocation.clamp_note" parent="allocation">
          <div className="sa-cell sa-label--dim">
            {fmt("creation.points.attributes", { count: Object.values(draft).reduce((a, b) => a + b, 0) })}
          </div>
        </Element>
        <Element screen={SCREEN} id="allocation.buttons" parent="allocation">
          <Element screen={SCREEN} id="allocation.confirm" parent="allocation.buttons">
            <Button textKey="ui.confirm" kind="primary" disabled titleKey="ui.not_available" fill />
          </Element>
          <Element screen={SCREEN} id="allocation.cancel" parent="allocation.buttons">
            <Button textKey="ui.cancel" onClick={() => setDraft({})} fill />
          </Element>
        </Element>
      </Element>
    </div>
  );

  if (!standalone) return card;

  return (
    <div className="sa-screen">
      <Box rect={{ x: 0, y: 0, w: 60, h: 33.75 }} skin="backdrop" />
      <Box rect={{ x: 22, y: 1, w: 15, h: 32.75 }} className="sa-scroll">
        {card}
      </Box>
    </div>
  );
}
