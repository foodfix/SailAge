/**
 * The officers roster (docs/80-UI-UX.md §4.6.2) — the intel window's 官员
 * tab: the employed table + the detail page, with the tavern's employable
 * offers appended while in port.
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
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Button, Toast } from "../kit";
import {
  ButtonEl,
  LabelEl,
  peopleAction,
  StandaloneFrame,
  useFetchedView,
  useToastState,
} from "./common";
import { CharacterCard } from "./CharacterCard";
import rawPosts from "../../../data/officer_posts.json";

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
    const statValues = statKeys.map((key) => {
      const source = mode === "attributes" ? row.officer.attributes : row.officer.skills;
      return Number(source[key] ?? 0);
    });
    return (
      <>
        <Box rect={{ x: 0, y: 0, w: 6, h: 1 }}>
          <span className="sa-cell">{t(row.officer.name)}</span>
        </Box>
        <Box rect={{ x: 6, y: 0, w: 5, h: 1 }}>
          <span className="sa-cell sa-label--accent">
            {row.employed
              ? postText(row.postId, row.shipId, tKey)
              : tKey("tavern.recruit")}
          </span>
        </Box>
        <Box rect={{ x: 11, y: 0, w: 2, h: 1 }}>
          <span className="sa-cell sa-label--right">
            {row.employed ? row.loyalty : ""}
          </span>
        </Box>
        <Box rect={{ x: 13, y: 0, w: 4, h: 1 }}>
          <span className="sa-cell">
            {fmt("tavern.wage", { price: row.wage })}
          </span>
        </Box>
        <Box rect={{ x: 17, y: 0, w: 15, h: 1 }}>
          <div className="sa-row">
            {statValues.map((value, index) => (
              <div className="sa-row__cell" key={statKeys[index]}>
                <span className="sa-cell sa-label--right">{value}</span>
              </div>
            ))}
          </div>
        </Box>
      </>
    );
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

  const table = (
    <>
      <LabelEl
        screen={SCREEN}
        id="slots"
        textKey="officers.slots"
        values={{ used: employed.length, max: OFFICER_MAX, wage: totalWage }}
      />
      <LabelEl
        screen={SCREEN}
        id="mode_note"
        textKey="officers.readonly_sea"
        tone="warn"
        hidden={atPort}
      />
      <LabelEl
        screen={SCREEN}
        id="result"
        textValue={toast ? (toast.values ? fmt(toast.messageKey, toast.values) : tKey(toast.messageKey)) : ""}
        tone={toast?.tone === "bad" ? "bad" : "accent"}
        hidden={!toast}
      />
      <ButtonEl
        screen={SCREEN}
        id="toggles.attributes"
        textKey="char.stats"
        kind={mode === "attributes" ? "primary" : "default"}
        onClick={() => setMode("attributes")}
      />
      <ButtonEl
        screen={SCREEN}
        id="toggles.skills"
        textKey="char.card.skills"
        kind={mode === "skills" ? "primary" : "default"}
        onClick={() => setMode("skills")}
      />
      <Element screen={SCREEN} id="table_viewport" className="sa-scroll">
        <ListRows
          screen={SCREEN}
          listId="roster"
          count={allRows.length + 1}
          renderRow={(index) => {
            if (index === 0) {
              return (
                <div className="sa-row">
                  <div className="sa-row__cell">
                    <span className="sa-cell sa-label--heading">{tKey("intel.officers.name")}</span>
                  </div>
                  <div className="sa-row__cell">
                    <span className="sa-cell sa-label--heading">{tKey("officer.post.idle")}</span>
                  </div>
                  <div className="sa-row__cell">
                    <span className="sa-cell sa-label--heading">{tKey("char.card.loyalty").replace("{amount}", "").trim()}</span>
                  </div>
                  <div className="sa-row__cell">
                    <span className="sa-cell sa-label--heading">{tKey("intel.officers.wage")}</span>
                  </div>
                  <div className="sa-row__cell">
                    <span className="sa-cell sa-label--heading">
                      {statKeys
                        .map((key) => tKey(mode === "attributes" ? `char.attr.${key}` : `skill.${key}`))
                        .join(" · ")}
                    </span>
                  </div>
                </div>
              );
            }
            const row = allRows[index - 1];
            if (!row) return null;
            return (
              <div
                className="sa-card-button"
                role="button"
                tabIndex={0}
                onClick={() => selectRow(row.id, !row.employed)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") selectRow(row.id, !row.employed);
                }}
              >
                {rowCells(row)}
              </div>
            );
          }}
        />
      </Element>
      <LabelEl screen={SCREEN} id="table_empty" textKey="char.no_officers" hidden={allRows.length > 0} />
      <LabelEl screen={SCREEN} id="table_empty_hint" textKey="officers.empty_hint" tone="dim" hidden={allRows.length > 0} />
    </>
  );

  const detail = (
    <>
      <Element screen={SCREEN} id="detail">
        <LabelEl
          screen={SCREEN}
          id="detail.line"
          parent="detail"
          textValue={
            detailOfficer
              ? `${postText(detailRun?.post_id ?? "", detailRun?.ship_id ?? undefined, tKey)} · ${fmt("tavern.wage", {
                  price: Math.round(detailOfficer.wage_daily * Number(detailRun?.wage_mult ?? 1)),
                })} · ${fmt("officers.recruited_at", {
                  port: detailOfficer.recruit_ports.length > 0
                    ? t(content.portName(detailOfficer.recruit_ports[0]))
                    : tKey("char.none"),
                })}`
              : ""
          }
        />
        <Element screen={SCREEN} id="detail.card_host" parent="detail" className="sa-scroll">
          {selected ? <CharacterCard kind="officer" personId={selected} statBlocks /> : null}
        </Element>
        <Box rect={{ x: 4, y: 7, w: 28, h: 2 }}>
          <div className="sa-row">
            <div className="sa-row__cell">
              <Button
                textKey="char.action.talk"
                disabled={!selected || employableSelected || Boolean(talkReason)}
                titleKey={talkReason ? "char.action.cooldown" : undefined}
                fill
                onClick={() => selected && doAction("talk", selected)}
              />
            </div>
            <div className="sa-row__cell">
              <Button
                textKey="char.action.gift"
                disabled={!selected || employableSelected || Boolean(giftReason)}
                titleKey={giftReason ? "char.action.cooldown" : undefined}
                fill
                onClick={() => selected && doAction("gift", selected)}
              />
            </div>
            <div className="sa-row__cell">
              <Button textKey="char.action.train" disabled titleKey="ui.not_available" fill />
            </div>
            <div className="sa-row__cell">
              <Button
                textKey="char.action.appoint"
                disabled={!selected || employableSelected || !atPort}
                titleKey={atPort ? undefined : "officers.readonly_sea"}
                fill
                onClick={() => setAppointOpen(true)}
              />
            </div>
            <div className="sa-row__cell">
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
              <div className="sa-row__cell">
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
            <div className="sa-row__cell">
              <Button textKey="ui.back" fill onClick={() => setSelected(null)} />
            </div>
          </div>
        </Box>
        <Element screen={SCREEN} id="detail.back" parent="detail" hidden />
      </Element>
      {appointOpen && selected ? (
        <Box rect={{ x: 0, y: 0, w: 32, h: 9 }} skin="panel">
          <div className="sa-cell sa-label--heading">{tKey("char.action.appoint")}</div>
          <Box rect={{ x: 1, y: 1, w: 30, h: 7 }} className="sa-scroll">
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
                    onClick={() => {
                      void peopleAction(client, "appoint", {
                        officer_id: selected,
                        post_id: post.post_id,
                        ship_id: ship.ship_type_id,
                      }).then((result) => {
                        if (!result.ok) showToast(result.error.msg, undefined, "bad");
                        else setAppointOpen(false);
                      });
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
                  onClick={() => {
                    void peopleAction(client, "appoint", {
                      officer_id: selected,
                      post_id: post.post_id,
                    }).then((result) => {
                      if (!result.ok) showToast(result.error.msg, undefined, "bad");
                      else setAppointOpen(false);
                    });
                  }}
                />
              );
            })}
            <Button
              textKey="officer.post.to_idle"
              onClick={() => {
                if (!selected) return;
                void peopleAction(client, "appoint", {
                  officer_id: selected,
                  post_id: "",
                }).then((result) => {
                  if (!result.ok) showToast(result.error.msg, undefined, "bad");
                  else setAppointOpen(false);
                });
              }}
            />
          </Box>
          <Box rect={{ x: 28, y: 7, w: 4, h: 2 }}>
            <Button textKey="ui.cancel" fill onClick={() => setAppointOpen(false)} />
          </Box>
        </Box>
      ) : null}
      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );

  const body = selected ? detail : table;

  return embedded ? body : <StandaloneFrame>{body}</StandaloneFrame>;
}
