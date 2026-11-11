/**
 * Save / load slot dialog (docs/80-UI-UX.md §4.6, §4.7; docs/90-* §0.4).
 *
 * One modal, two modes:
 *   * **save** — S4-hosted only in spirit: the rows are disabled with the
 *     `ui.cant_save_here` hint whenever the run is not docked; a non-empty
 *     slot asks the local overwrite confirm first;
 *   * **load** — the title's Load edge (always available); picking a valid
 *     row loads it and routes to the ending (retired), the port (docked)
 *     or the world (at sea).
 *
 * Every `save_slot` element row is rendered (`dim`, `panel` + its title /
 * prompt / slots viewport / slots content / cancel), plus the `slots` list
 * block. The confirm is the local fallback (M6-b owns the `confirm`
 * screen; this dialog never depends on it).
 */
import { useEffect, useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { SaveSlot as SaveSlotRow } from "../client/types";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Button, Frame, Toast } from "../kit";
import { ButtonEl, LabelEl, useToastState } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "save_slot";
const SLOT_COUNT = 3;

export type SaveSlotMode = "save" | "load";

let pendingMode: SaveSlotMode | null = null;
let endingRetiredMode = false;

/** The routing seam the host screens call (nav graph §4.2). */
export function openSaveSlot(mode: SaveSlotMode): void {
  pendingMode = mode;
  navigate("save_slot");
}

/**
 * Tells the ending screen that a retired save was just loaded (the oracle's
 * summary mode: `ending.retired_title` instead of the fresh-retirement title).
 * The flag is read (not consumed) so a StrictMode double render cannot flip
 * the mode; the title mount and every load reset it.
 */
export function setEndingRetiredMode(value: boolean): void {
  endingRetiredMode = value;
}

export function getEndingRetiredMode(): boolean {
  return endingRetiredMode;
}

/**
 * A direct deep link (`#/save_slot`, the dev index) has no caller. Default
 * to Save when the run is docked (the only legal write point) and Load
 * otherwise, so both modes stay reachable before M6-b's settings Save row
 * lands.
 */
function takeMode(fallback: SaveSlotMode): SaveSlotMode {
  const mode = pendingMode ?? fallback;
  pendingMode = null;
  return mode;
}

function emptyRow(slot: number): SaveSlotRow {
  return { slot, day: 0, nation_id: "", port_id: "", gold: 0, saved_at: 0 };
}

export function SaveSlotScreen() {
  const { state } = useGameState();
  const client = useGameClient();
  const { locale, t, tKey, fmt } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const [mode] = useState<SaveSlotMode>(() =>
    takeMode(state.day > 0 && state.current_port ? "save" : "load"),
  );
  const [saves, setSaves] = useState<SaveSlotRow[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [confirmSlot, setConfirmSlot] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);

  const inPort = Boolean(state.current_port);
  const canSave = mode === "save" && inPort;

  const refresh = async (): Promise<void> => {
    try {
      const response = await client.getSaves();
      setSaves(response.saves);
      setLoaded(true);
    } catch {
      showToast("error.network", undefined, "bad");
    }
  };

  useEffect(() => {
    void refresh();
    // One read on open; the dialog re-reads after a write.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client]);

  const rows = Array.from({ length: SLOT_COUNT }, (_, index) => {
    const slot = index + 1;
    return saves.find((entry) => entry.slot === slot) ?? emptyRow(slot);
  });

  const isEmpty = (entry: SaveSlotRow): boolean => !(entry.day > 0 || Boolean(entry.nation_id));

  const rowText = (entry: SaveSlotRow): string => {
    const slotLabel = fmt("ui.slot_n", { slot: entry.slot });
    if (!loaded) return `${slotLabel} — ${tKey("connection.connecting")}`;
    if (isEmpty(entry)) return `${slotLabel} — ${tKey("ui.empty")}`;
    const nation = entry.nation_id ? t(content.nationName(entry.nation_id)) : tKey("char.none");
    const summary = fmt("ui.day_nation_gold", {
      day: entry.day,
      nation,
      gold: entry.gold,
    });
    const stamp =
      entry.saved_at > 0
        ? new Intl.DateTimeFormat(locale, { dateStyle: "short", timeStyle: "short" }).format(
            new Date(entry.saved_at * 1000),
          )
        : "-";
    return `${slotLabel} — ${summary} — ${fmt("ui.timestamp", { amount: stamp })}`;
  };

  const doSave = async (slot: number): Promise<void> => {
    if (!canSave || busy) return;
    setBusy(true);
    try {
      const result = await client.save(slot);
      if (result.ok) {
        await refresh();
        showToast("ui.saved_slot", { slot }, "good");
      } else {
        showToast(result.error.msg || "ui.save_failed", undefined, "bad");
      }
    } finally {
      setBusy(false);
      setConfirmSlot(null);
    }
  };

  const doLoad = async (slot: number): Promise<void> => {
    if (busy) return;
    setBusy(true);
    setEndingRetiredMode(false);
    try {
      const result = await client.load(slot);
      if (!result.ok) {
        showToast(result.error.msg || "ui.load_failed", undefined, "bad");
        return;
      }
      const snapshot = await client.getState();
      if (snapshot.retired) {
        setEndingRetiredMode(true);
        navigate("ending");
      } else if (snapshot.current_port) navigate("port");
      else navigate("world");
    } catch {
      showToast("ui.load_failed", undefined, "bad");
    } finally {
      setBusy(false);
    }
  };

  const choose = (entry: SaveSlotRow): void => {
    if (mode === "save") {
      if (!inPort) {
        showToast("ui.cant_save_here", undefined, "bad");
        return;
      }
      if (!isEmpty(entry)) setConfirmSlot(entry.slot);
      else void doSave(entry.slot);
      return;
    }
    if (!isEmpty(entry)) void doLoad(entry.slot);
  };

  const cancel = (): void => {
    if (state.day > 0) navigate(state.current_port ? "port" : "world");
    else navigate("title");
  };

  return (
    <>
      <Element screen={SCREEN} id="dim" className="sa-dim" />
      <Element screen={SCREEN} id="panel" parent="dim" skin="panel">
        <LabelEl
          screen={SCREEN}
          id="panel.title"
          parent="panel"
          textKey={mode === "save" ? "ui.save.title" : "ui.load.title"}
          title
        />
        <LabelEl
          screen={SCREEN}
          id="panel.prompt"
          parent="panel"
          textKey={
            mode === "save" && !inPort
              ? "ui.cant_save_here"
              : mode === "save"
                ? "ui.save.select_slot"
                : "ui.load.select_slot"
          }
          tone={mode === "save" && !inPort ? "warn" : "dim"}
        />

        <Element screen={SCREEN} id="panel.slots_viewport" parent="panel" className="sa-scroll">
          <Element screen={SCREEN} id="panel.slots" parent="panel.slots_viewport">
            <ListRows
              screen={SCREEN}
              listId="slots"
              count={rows.length}
              renderRow={(index) => {
                const entry = rows[index];
                const empty = isEmpty(entry);
                const disabled =
                  busy || !loaded || (mode === "load" && empty) || (mode === "save" && !inPort);
                return (
                  <Button
                    text={rowText(entry)}
                    fill
                    disabled={disabled}
                    onClick={() => choose(entry)}
                  />
                );
              }}
            />
          </Element>
        </Element>

        <ButtonEl
          screen={SCREEN}
          id="panel.cancel"
          parent="panel"
          textKey="ui.cancel"
          onClick={cancel}
        />
      </Element>

      {confirmSlot !== null ? (
        <Box rect={{ x: 0, y: 0, w: 60, h: 34 }}>
          <Box rect={{ x: 22, y: 12, w: 15, h: 10 }}>
            <Frame titleKey="ui.confirm_title">
              <div className="sa-cell">{fmt("ui.overwrite_confirm", { slot: confirmSlot })}</div>
              <div className="sa-footer">
                <Button textKey="ui.cancel" onClick={() => setConfirmSlot(null)} />
                <Button
                  textKey="ui.confirm"
                  kind="danger"
                  onClick={() => void doSave(confirmSlot)}
                />
              </div>
            </Frame>
          </Box>
        </Box>
      ) : null}

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
