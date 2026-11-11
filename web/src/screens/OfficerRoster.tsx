/**
 * The officers roster (docs/80-UI-UX.md §4.6.2; the §4.9.1 composition) —
 * the intel window's 官员 tab and the standalone route: the employed table
 * (kit zebra table: name · post · loyalty · wage + the switchable stat
 * columns) + the detail page (the §4.12 card, the post·wage·recruit-port
 * line and the fixed action row), with the tavern's employable offers
 * appended while in port and the appoint post-picker over its own dim.
 *
 * Missing server projection (reported): `GET /api/view/officer_roster`
 * should carry the wage multiplier, cooldown gates, post prereqs and the
 * employable rows already gated. The screen derives the *display* from the
 * authoritative `officer_states`, `data/officers.json` and the `tavern`
 * projection; actions go through the frozen `people:*` / `tavern:dismiss`
 * verbs. The `train` action has no server verb yet and renders disabled.
 */
import { useEffect, useMemo, useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { RecruitRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Footer, Frame, Row, Toast } from "../kit";
import { Label, StandaloneFrame, peopleAction, useFetchedView, useToastState } from "./common";
import { CharacterCard } from "./CharacterCard";
import rawPosts from "../../../data/officer_posts.json";
import "./OfficerRoster.css";

const SCREEN: ScreenId = "officer_roster";
const OFFICER_MAX = 12;

interface OfficerCanon {
  id: string;
  name: { zh: string; en: string };
  nation_id: string;
  main_skill: string;
  attributes: Record<string, number>;
  skills: Record<string, number>;
  wage_daily: number;
  recruit_ports: string[];
}

interface PostDef {
  post_id: string;
  slot_type: string;
  prereq: Record<string, number>;
}

const POSTS = (rawPosts as unknown as { officer_posts: PostDef[] }).officer_posts;

function canon(id: string): OfficerCanon | undefined {
  return content.officer(id) as unknown as OfficerCanon | undefined;
}

function postText(
  postId: string,
  shipId: string | undefined,
  tKey: (key: string) => string,
): string {
  if (!postId) return tKey("officer.post.idle");
  const label = tKey(`officer.post.${postId}`);
  return postId === "captain" && shipId ? `${label} · ${shipId}` : label;
}

export function OfficerRoster({ embedded = false }: { embedded?: boolean }) {
  const { state } = useGameState();
  const { view: tavern } = useFetchedView("tavern");
  const client = useGameClient();
  const { t, tKey, fmt } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const [mode, setMode] = useState<"attributes" | "skills">("attributes");
  const [selected, setSelected] = useState<string | null>(null);
  const [employableSelected, setEmployableSelected] = useState(false);
  const [appointOpen, setAppointOpen] = useState(false);
  const atPort = state.current_port !== null;

  useEffect(() => {
    setAppointOpen(false);
  }, [selected]);

  const employed = useMemo(
    () => [...state.player.officers].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),
    [state.player.officers],
  );
  const offers = tavern?.recruitable ?? [];
  const totalWage = employed.reduce((sum, id) => {
    const officer = canon(id);
    const mult = Number(state.officer_states[id]?.wage_mult ?? 1);
    return sum + Math.round(Number(officer?.wage_daily ?? 0) * mult);
  }, 0);

  const employeeRows = employed
    .map((id) => {
      const officer = canon(id);
      if (!officer) return null;
      const run = state.officer_states[id];
      return {
        id,
        officer,
        loyalty: Number(run?.loyalty ?? 50),
        postId: run?.post_id ?? "",
        shipId: run?.ship_id ?? "",
        wage: Math.round(officer.wage_daily * Number(run?.wage_mult ?? 1)),
        employed: true,
      };
    })
    .filter((row): row is NonNullable<typeof row> => row !== null);

  const offerRows = offers
    .map((offer: RecruitRow) => {
      const officer = canon(offer.officerId);
      if (!officer) return null;
      return {
        id: offer.officerId,
        officer,
        loyalty: 50,
        postId: "",
        shipId: "",
        wage: offer.wage,
        employed: false,
      };
    })
    .filter((row): row is NonNullable<typeof row> => row !== null);

  const allRows = [...employeeRows, ...offerRows];
  const statKeys = mode === "attributes"
    ? ["constitution", "intellect", "charisma", "courage", "luck"]
    : [
        "seamanship", "navigation", "swordplay", "gunnery", "appraisal",
        "negotiation", "cartography", "rumour", "medicine", "carpentry", "cooking",
      ];

  const rowCells = (row: (typeof allRows)[number]) => {
    const source = mode === "attributes" ? row.officer.attributes : row.officer.skills;
    const statCells = statKeys.map((key) => (
      <span key={key} className="sa-cell sa-cell--right">{Number(source[key] ?? 0)}</span>
    ));
    return [
      <div className="sa-cell">{t(row.officer.name)}</div>,
      <div className="sa-cell sa-label--accent">
        {row.employed
          ? postText(row.postId, row.shipId, tKey)
          : tKey("tavern.recruit")}
      </div>,
      <div className="sa-cell sa-cell--right">
        {row.employed ? row.loyalty : ""}
      </div>,
      <div className="sa-cell">
        {fmt("tavern.wage", { price: row.wage })}
      </div>,
      ...statCells,
    ];
  };

  const selectRow = (id: string, isEmployable: boolean) => {
    setSelected(id);
    setEmployableSelected(isEmployable);
  };

  const detailOfficer = selected ? canon(selected) : undefined;
  const detailRun = selected ? state.officer_states[selected] : undefined;
  const talkCd = Number(detailRun?.talk_cd_day ?? 0);
  const giftCd = Number(detailRun?.gift_cd_day ?? 0);
  const talkReason = talkCd > state.day
    ? fmt("char.action.cooldown", { days: talkCd - state.day })
    : "";
  const giftReason = giftCd > state.day
    ? fmt("char.action.cooldown", { days: giftCd - state.day })
    : "";

  const postMet = (post: PostDef): boolean =>
    Object.entries(post.prereq).every(([key, required]) => {
      const skills = detailOfficer?.skills ?? {};
      const attributes = detailOfficer?.attributes ?? {};
      return Number(skills[key] ?? attributes[key] ?? 0) >= required;
    });

  const doAction = (
    verb: "talk" | "gift" | "dismiss" | "recruit",
    officerId: string,
  ) => {
    const body = verb === "talk" || verb === "gift"
      ? peopleAction(client, verb, { officer_id: officerId })
      : verb === "dismiss"
        ? client.tavern.dismiss(officerId)
        : client.tavern.recruit(officerId);
    void body.then((result) => {
      if (!result.ok) showToast(result.error.msg, undefined, "bad");
      else if (verb === "recruit") showToast("tavern.recruited", { name: content.officerName(officerId) }, "good");
    });
  };

  const appoint = (
    body: Record<string, unknown>,
    onOk: () => void,
  ) => {
    void peopleAction(client, "appoint", body).then((result) => {
      if (!result.ok) showToast(result.error.msg, undefined, "bad");
      else onOk();
    });
  };

  const table = (
    <div className="roster__body" data-screen={SCREEN}>
      <Label
        textKey="officers.slots"
        values={{ used: employed.length, max: OFFICER_MAX, wage: totalWage }}
      />
      {atPort ? null : <Label textKey="officers.readonly_sea" tone="warn" />}
      {toast ? (
        <Label
          textValue={toast.values ? fmt(toast.messageKey, toast.values) : tKey(toast.messageKey)}
          tone={toast.tone === "bad" ? "bad" : "accent"}
        />
      ) : null}
      <div className="roster__toggles">
        <Button
          textKey="char.stats"
          kind={mode === "attributes" ? "primary" : "default"}
          onClick={() => setMode("attributes")}
        />
        <Button
          textKey="char.card.skills"
          kind={mode === "skills" ? "primary" : "default"}
          onClick={() => setMode("skills")}
        />
      </div>
      <div className="sa-scroll roster__table_wrap">
        <div className="sa-table roster__table">
          <Row
            head
            cols={[
              <div className="sa-cell">{tKey("intel.officers.name")}</div>,
              <div className="sa-cell">{tKey("officer.post.idle")}</div>,
              <div className="sa-cell">{tKey("char.card.loyalty").replace("{amount}", "").trim()}</div>,
              <div className="sa-cell">{tKey("intel.officers.wage")}</div>,
              ...statKeys.map((key) => (
                <div key={key} className="sa-cell sa-cell--right">
                  {tKey(mode === "attributes" ? `char.attr.${key}` : `skill.${key}`)}
                </div>
              )),
            ]}
          />
          {allRows.map((row) => (
            <Row
              key={row.id}
              selected={selected === row.id}
              onClick={() => selectRow(row.id, !row.employed)}
              cols={rowCells(row)}
            />
          ))}
        </div>
      </div>
      {allRows.length === 0 ? (
        <>
          <Label textKey="char.no_officers" />
          <Label textKey="officers.empty_hint" tone="dim" />
        </>
      ) : null}
    </div>
  );

  const detail = (
    <div className="roster__body" data-screen={SCREEN}>
      {detailOfficer ? (
        <Label
          textValue={`${postText(detailRun?.post_id ?? "", detailRun?.ship_id ?? undefined, tKey)} · ${fmt("tavern.wage", {
            price: Math.round(detailOfficer.wage_daily * Number(detailRun?.wage_mult ?? 1)),
          })} · ${fmt("officers.recruited_at", {
            port: detailOfficer.recruit_ports.length > 0
              ? t(content.portName(detailOfficer.recruit_ports[0]))
              : tKey("char.none"),
          })}`}
        />
      ) : null}
      <div className="sa-scroll roster__card">
        {selected ? <CharacterCard kind="officer" personId={selected} statBlocks /> : null}
      </div>
      <div className="roster__actions">
        <div className="roster__action">
          <Button
            textKey="char.action.talk"
            disabled={!selected || employableSelected || Boolean(talkReason)}
            titleKey={talkReason ? "char.action.cooldown" : undefined}
            fill
            onClick={() => selected && doAction("talk", selected)}
          />
        </div>
        <div className="roster__action">
          <Button
            textKey="char.action.gift"
            disabled={!selected || employableSelected || Boolean(giftReason)}
            titleKey={giftReason ? "char.action.cooldown" : undefined}
            fill
            onClick={() => selected && doAction("gift", selected)}
          />
        </div>
        <div className="roster__action">
          <Button textKey="char.action.train" disabled titleKey="ui.not_available" fill />
        </div>
        <div className="roster__action">
          <Button
            textKey="char.action.appoint"
            disabled={!selected || employableSelected || !atPort}
            titleKey={atPort ? undefined : "officers.readonly_sea"}
            fill
            onClick={() => setAppointOpen(true)}
          />
        </div>
        <div className="roster__action">
          <Button
            textKey="officers.dismiss"
            disabled={!selected || employableSelected || !atPort}
            titleKey={atPort ? undefined : "officers.readonly_sea"}
            fill
            onClick={() => {
              if (!selected) return;
              const message = fmt("officers.dismiss.confirm", {
                name: content.officerName(selected),
              });
              if (typeof window !== "undefined" && !window.confirm(message)) return;
              doAction("dismiss", selected);
              setSelected(null);
            }}
          />
        </div>
        {employableSelected && selected ? (
          <div className="roster__action">
            <Button
              textKey="tavern.recruit"
              kind="primary"
              fill
              onClick={() => {
                doAction("recruit", selected);
                setSelected(null);
              }}
            />
          </div>
        ) : null}
        <div className="roster__action">
          <Button textKey="ui.back" fill onClick={() => setSelected(null)} />
        </div>
      </div>

      {appointOpen && selected ? (
        <div className="roster__overlay">
          <div className="roster__overlay_dim sa-dim" aria-hidden="true" />
          <div className="sa-fill-center roster__overlay_center">
            <Frame titleKey="char.action.appoint" scroll className="roster__appoint">
              <div className="roster__appoint_stack">
                {POSTS.map((post) => {
                  const met = postMet(post);
                  const label = tKey(`officer.post.${post.post_id}`);
                  if (post.post_id === "captain") {
                    return state.fleet.map((ship, index) => (
                      <Button
                        key={`${post.post_id}_${index}`}
                        text={`${label} · ${t(content.shipName(ship.ship_type_id))}`}
                        disabled={!met}
                        titleKey={met ? undefined : "officer.post.prereq_unmet"}
                        fill
                        onClick={() => {
                          appoint(
                            {
                              officer_id: selected,
                              post_id: post.post_id,
                              ship_id: ship.ship_type_id,
                            },
                            () => setAppointOpen(false),
                          );
                        }}
                      />
                    ));
                  }
                  return (
                    <Button
                      key={post.post_id}
                      text={label}
                      disabled={!met}
                      titleKey={met ? undefined : "officer.post.prereq_unmet"}
                      fill
                      onClick={() => {
                        appoint(
                          { officer_id: selected, post_id: post.post_id },
                          () => setAppointOpen(false),
                        );
                      }}
                    />
                  );
                })}
                <Button
                  textKey="officer.post.to_idle"
                  fill
                  onClick={() => {
                    if (!selected) return;
                    appoint(
                      { officer_id: selected, post_id: "" },
                      () => setAppointOpen(false),
                    );
                  }}
                />
                <Footer buttons={[
                  <Button key="appoint_cancel" textKey="ui.cancel" onClick={() => setAppointOpen(false)} />,
                ]} />
              </div>
            </Frame>
          </div>
        </div>
      ) : null}

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );

  const body = selected ? detail : table;

  return embedded ? body : <StandaloneFrame className="roster__window">{body}</StandaloneFrame>;
}
