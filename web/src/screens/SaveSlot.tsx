/**
 * Save / load slot dialog (docs/80-UI-UX.md §4.6, §4.7, §4.9.1; docs/90-*
 * §0.4).
 *
 * One modal, two modes:
 *   * **save** — S4-hosted only in spirit: the rows are disabled with the
 *     `ui.cant_save_here` hint whenever the run is not docked; a non-empty
 *     slot asks the local overwrite confirm first;
 *   * **load** — the title's Load edge (always available); picking a valid
 *     row loads it and routes to the ending (retired), the port (docked)
 *     or the world (at sea).
 *
 * The composition (§4.9.1): a full-canvas dim layer carrying one centered
 * window — the mode title band, the prompt line, the `.sa-table` of three
 * slots (slot number / day·nation·gold / timestamp columns with a compact
 * load-or-save button per row) and the cancel footer. The overwrite
 * confirm is the local fallback (M6-b owns the `confirm` screen; this
 * dialog never depends on it), mounted as a second centered window over
 * the layer.
 */
import { useEffect, useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { SaveSlot as SaveSlotRow } from "../client/types";
import type { ScreenId } from "./ids";
import { Button, Footer, Frame, Row, Toast } from "../kit";
import { Label, useToastState } from "./common";
import { navigate } from "../app/router";
import "./SaveSlot.css";

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

  const summaryText = (entry: SaveSlotRow): string => {
    if (!loaded) return tKey("connection.connecting");
    if (isEmpty(entry)) return tKey("ui.empty");
    const nation = entry.nation_id ? t(content.nationName(entry.nation_id)) : tKey("char.none");
    return fmt("ui.day_nation_gold", {
      day: entry.day,
      nation,
      gold: entry.gold,
    });
  };

  const stampText = (entry: SaveSlotRow): string => {
    const stamp =
      entry.saved_at > 0
        ? new Intl.DateTimeFormat(locale, { dateStyle: "short", timeStyle: "short" }).format(
            new Date(entry.saved_at * 1000),
          )
        : "-";
    return fmt("ui.timestamp", { amount: stamp });
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
    <div className="sa-screen save_slot" data-screen={SCREEN}>
      <div className="save_slot__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center save_slot__layer">
        <Frame
          titleKey={mode === "save" ? "ui.save.title" : "ui.load.title"}
          className="save_slot__window"
        >
          <Label
            textKey={
              mode === "save" && !inPort
                ? "ui.cant_save_here"
                : mode === "save"
                  ? "ui.save.select_slot"
                  : "ui.load.select_slot"
            }
            tone={mode === "save" && !inPort ? "warn" : "dim"}
          />

          <div className="sa-table save_slot__table">
            {rows.map((entry) => {
              const empty = isEmpty(entry);
              const disabled =
                busy || !loaded || (mode === "load" && empty) || (mode === "save" && !inPort);
              return (
                <Row
                  key={entry.slot}
                  cols={[
                    <Label key="slot" textValue={fmt("ui.slot_n", { slot: entry.slot })} />,
                    <Label key="summary" textValue={summaryText(entry)} />,
                    <Label key="stamp" textValue={stampText(entry)} />,
                    <Button
                      key="action"
                      compact
                      textKey={mode === "save" ? "ui.save.title" : "ui.load.title"}
                      disabled={disabled}
                      onClick={() => choose(entry)}
                    />,
                  ]}
                />
              );
            })}
          </div>

          <div className="save_slot__footer">
            <Footer buttons={[<Button key="cancel" textKey="ui.cancel" onClick={cancel} />]} />
          </div>
        </Frame>
      </div>

      {confirmSlot !== null ? (
        <div className="sa-fill-center save_slot__confirm">
          <Frame titleKey="ui.confirm_title" className="save_slot__confirm_window">
            <div className="sa-cell">{fmt("ui.overwrite_confirm", { slot: confirmSlot })}</div>
            <div className="save_slot__confirm_footer">
              <Footer
                buttons={[
                  <Button key="cancel" textKey="ui.cancel" onClick={() => setConfirmSlot(null)} />,
                  <Button
                    key="confirm"
                    textKey="ui.confirm"
                    kind="danger"
                    onClick={() => void doSave(confirmSlot)}
                  />,
                ]}
              />
            </div>
          </Frame>
        </div>
      ) : null}

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
