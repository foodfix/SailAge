/**
 * S19 — the Settings modal (docs/80-UI-UX.md §4.6.3; the §4.9.1
 * composition: a centred parchment window over the dim layer, one field
 * row per setting).
 *
 * One panel, two mounts (the S1 title entry, pre-game, and the S4 hub footer,
 * mid-run). Rows:
 *  · **language** — live: the I18n store flips every string and the shell
 *    forwards `POST /api/locale` (§0.3 `locale` intent is the WS twin);
 *  · **sea traffic** (`npc_preset`), **input mode** and **current mode**
 *    (`control_prefs`) — live through the frozen §0.4 `settings/*` verbs; the
 *    server is authoritative and the next `state` frame re-renders the
 *    current-value labels;
 *  · **debug overlays** — session-only, client-side (§4.6 symbol contract;
 *    never persisted), so it is live;
 *  · **save** and **return to main menu** (confirm-first, §4.6.3/§4.7) —
 *    docked mounts only; the pre-game / at-sea mounts omit both rows.
 *
 * Esc / Close returns to the hub (§4.2 edge). The route defaults to `port`
 * when docked, `world` at sea (the S4/S3 landings, same rule as the Chart).
 */
import { useCallback, useEffect, useState } from "react";
import { navigate } from "../app/router";
import { useI18n } from "../i18n";
import { useGameState } from "../state/context";
import { useGameClient } from "../client/context";
import { setDebugOverlays, useChartView } from "../canvas/chart";
import { Button, FieldRow, Frame } from "../kit";
import { Label } from "./common";
import { ConfirmDialog } from "./Confirm";
import type { ScreenId } from "./ids";
import "./Settings.css";

const SCREEN: ScreenId = "settings";

/** The five §4.6.3 sea-traffic presets (`npc_config.json`'s locked set). */
const PRESETS = ["deserted", "low", "normal", "high", "extreme"] as const;

/** The §4.6.3 input-mode row (`control_prefs.input_mode`). */
const INPUT_MODES = ["step", "helm"] as const;

/** The §4.6.3 current-mode row (`control_prefs.current_mode`). */
const CURRENT_MODES = ["modifier", "drift"] as const;

export function SettingsScreen() {
  const { state } = useGameState();
  const { locale, setLocale, tKey, fmt } = useI18n();
  const flags = useChartView();
  const [confirmReturn, setConfirmReturn] = useState(false);

  const docked = state.current_port !== null;
  const close = useCallback(() => {
    navigate(docked ? "port" : "world");
  }, [docked]);

  useEffect(() => {
    if (confirmReturn) return; // the confirm dialog owns Esc/Enter while open
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close, confirmReturn]);

  const client = useGameClient();
  const preset = state.npc_preset;
  const inputMode = state.control_prefs.input_mode;
  const currentMode = state.control_prefs.current_mode;
  // §4.6.3: the three GameState rows are live through the frozen
  // `settings/*` verbs (§0.4); the server is authoritative and the next
  // `state` frame re-renders the current-value labels.
  const applyPreset = useCallback((next: string) => {
    void client.action("settings", "npc_preset", { preset: next });
  }, [client]);
  const applyInputMode = useCallback((next: string) => {
    void client.action("settings", "input_mode", { mode: next });
  }, [client]);
  const applyCurrentMode = useCallback((next: string) => {
    void client.action("settings", "current_mode", { mode: next });
  }, [client]);

  /** The native select/option control on the recessed field plate (§4.9.1). */
  const select = (
    labelKey: string,
    value: string,
    ids: readonly string[],
    keyPrefix: string,
    apply: (next: string) => void,
  ) => (
    <FieldRow labelKey={labelKey}>
      <label className="sa-field">
        <select
          className="sa-field__input"
          aria-label={tKey(labelKey)}
          value={value}
          onChange={(event) => apply(event.target.value)}
        >
          {ids.map((id) => (
            <option key={id} value={id}>
              {tKey(`${keyPrefix}.${id}`)}
            </option>
          ))}
        </select>
      </label>
    </FieldRow>
  );

  return (
    <div className="sa-screen settings" data-screen={SCREEN}>
      <div className="settings__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center settings__layer">
        <Frame titleKey="settings.title" className="settings__window" scroll>
          <div className="settings__stack">
            {select("settings.density", preset, PRESETS, "settings.density", applyPreset)}
            <Label
              textValue={fmt("settings.density.current", {
                preset: tKey(`settings.density.${preset}`),
              })}
              tone="dim"
            />
            <Label textKey="settings.density.hint" tone="dim" wrap />

            {select("settings.input.mode", inputMode, INPUT_MODES, "settings.input", applyInputMode)}
            <Label
              textValue={fmt("settings.input.current", {
                mode: tKey(`settings.input.${inputMode}`),
              })}
              tone="dim"
            />

            {select(
              "settings.current.mode",
              currentMode,
              CURRENT_MODES,
              "settings.current",
              applyCurrentMode,
            )}
            <Label
              textValue={fmt("settings.current.current", {
                mode: tKey(`settings.current.${currentMode}`),
              })}
              tone="dim"
            />

            <FieldRow labelKey="settings.debug.overlays">
              <Button
                textKey={flags.debugOverlays ? "settings.debug.on" : "settings.debug.off"}
                kind={flags.debugOverlays ? "primary" : "default"}
                onClick={() => setDebugOverlays(!flags.debugOverlays)}
              />
            </FieldRow>
            <Label textKey="settings.debug.session_hint" tone="dim" wrap />

            <FieldRow labelKey="settings.locale">
              <Button
                textKey="ui.language_toggle"
                onClick={() => setLocale(locale === "zh" ? "en" : "zh")}
              />
            </FieldRow>

            <div className="settings__actions">
              {docked ? (
                <Button fill textKey="ui.save.title" onClick={() => navigate("save_slot")} />
              ) : null}
              {docked ? (
                <Button fill textKey="settings.return_menu" onClick={() => setConfirmReturn(true)} />
              ) : null}
              <Button fill textKey="settings.close" onClick={close} />
            </div>
          </div>
        </Frame>
      </div>

      {confirmReturn ? (
        <ConfirmDialog
          request={{
            messageKey: "settings.return_menu.confirm",
            destructive: true,
          }}
          onConfirm={() => {
            setConfirmReturn(false);
            navigate("title");
          }}
          onCancel={() => setConfirmReturn(false)}
        />
      ) : null}
    </div>
  );
}
