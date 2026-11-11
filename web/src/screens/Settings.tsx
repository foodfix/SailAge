/**
 * S19 — the Settings modal (docs/80-UI-UX.md §4.6.3; the §4.6.3 S19 rows).
 *
 * One panel, two mounts (the S1 title entry, pre-game, and the S4 hub footer,
 * mid-run). Rows:
 *  · **language** — live: the I18n store flips every string and the shell
 *    forwards `POST /api/locale` (§0.3 `locale` intent is the WS twin);
 *  · **sea traffic** (`npc_preset`), **input mode** and **current mode**
 *    (`control_prefs`) — these are GameState fields, but the frozen §0.4
 *    inventory has **no action verb** for them and the §0.3 intent table has
 *    no settings intent. They render the authoritative value and the row is
 *    disabled with the `ui.not_available` reason (reported: the missing verbs
 *    are `settings/npc_preset`, `settings/input_mode`, `settings/current_mode`);
 *  · **debug overlays** — session-only, client-side (§4.6 symbol contract;
 *    never persisted), so it is live;
 *  · **save** (S4 mount only) and **return to main menu** (S4 mount only,
 *    confirm-first, §4.6.3/§4.7).
 *
 * Esc / Close returns to the hub (§4.2 edge). The route defaults to `port`
 * when docked, `world` at sea (the S4/S3 landings, same rule as the Chart).
 */
import { useCallback, useEffect, useState } from "react";
import { navigate } from "../app/router";
import { useI18n } from "../i18n";
import { Element, type ScreenId } from "../layout";
import { useGameState } from "../state/context";
import { useGameClient } from "../client/context";
import { setDebugOverlays, useChartView } from "../canvas/chart";
import { ConfirmDialog } from "./Confirm";
import { ButtonEl, LabelEl, PanelEl } from "./common";

const SCREEN: ScreenId = "settings";

/** The five §4.6.3 sea-traffic presets (`npc_config.json`'s locked set). */
const PRESETS = [
  { id: "deserted", element: "presets.deserted" },
  { id: "low", element: "presets.low" },
  { id: "normal", element: "presets.normal" },
  { id: "high", element: "presets.high" },
  { id: "extreme", element: "presets.extreme" },
] as const;

/** The §4.6.3 input-mode row (`control_prefs.input_mode`). */
const INPUT_MODES = [
  { id: "step", element: "settings.input.step" },
  { id: "helm", element: "settings.input.helm" },
] as const;

/** The §4.6.3 current-mode row (`control_prefs.current_mode`). */
const CURRENT_MODES = [
  { id: "modifier", element: "settings.current.modifier" },
  { id: "drift", element: "settings.current.drift" },
] as const;

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

  return (
    <div className="sa-screen" data-settings-screen="settings">
      <Element screen={SCREEN} id="dim" className="sa-dim" />

      <PanelEl screen={SCREEN} id="panel">
        <LabelEl screen={SCREEN} id="panel.title" parent="panel" textKey="settings.title" title />

        <LabelEl
          screen={SCREEN}
          id="panel.density_label"
          parent="panel"
          textKey="settings.density"
          heading
        />
        <Element screen={SCREEN} id="panel.presets" parent="panel">
          {PRESETS.map((entry) => (
            <ButtonEl
              key={entry.id}
              screen={SCREEN}
              id={entry.element}
              parent="panel.presets"
              textKey={`settings.density.${entry.id}`}
              kind={preset === entry.id ? "primary" : "default"}
              onClick={() => applyPreset(entry.id)}
            />
          ))}
        </Element>
        <LabelEl
          screen={SCREEN}
          id="panel.current"
          parent="panel"
          textValue={fmt("settings.density.current", {
            preset: tKey(`settings.density.${preset}`),
          })}
        />
        <LabelEl
          screen={SCREEN}
          id="panel.hint"
          parent="panel"
          textKey="settings.density.hint"
          tone="dim"
        />

        <LabelEl
          screen={SCREEN}
          id="panel.input_label"
          parent="panel"
          textKey="settings.input.mode"
        />
        <Element screen={SCREEN} id="panel.input_buttons" parent="panel">
          {INPUT_MODES.map((entry) => (
            <ButtonEl
              key={entry.id}
              screen={SCREEN}
              id={entry.element}
              parent="panel.input_buttons"
              textKey={`settings.input.${entry.id}`}
              kind={inputMode === entry.id ? "primary" : "default"}
              onClick={() => applyInputMode(entry.id)}
            />
          ))}
        </Element>
        <LabelEl
          screen={SCREEN}
          id="panel.input_current"
          parent="panel"
          textValue={fmt("settings.input.current", {
            mode: tKey(`settings.input.${inputMode}`),
          })}
          tone="dim"
        />

        <LabelEl
          screen={SCREEN}
          id="panel.current_mode_label"
          parent="panel"
          textKey="settings.current.mode"
        />
        <Element screen={SCREEN} id="panel.current_mode_buttons" parent="panel">
          {CURRENT_MODES.map((entry) => (
            <ButtonEl
              key={entry.id}
              screen={SCREEN}
              id={entry.element}
              parent="panel.current_mode_buttons"
              textKey={`settings.current.${entry.id}`}
              kind={currentMode === entry.id ? "primary" : "default"}
              onClick={() => applyCurrentMode(entry.id)}
            />
          ))}
        </Element>
        <LabelEl
          screen={SCREEN}
          id="panel.current_mode_current"
          parent="panel"
          textValue={fmt("settings.current.current", {
            mode: tKey(`settings.current.${currentMode}`),
          })}
          tone="dim"
        />

        <LabelEl
          screen={SCREEN}
          id="panel.debug_label"
          parent="panel"
          textKey="settings.debug.overlays"
        />
        <ButtonEl
          screen={SCREEN}
          id="panel.debug_button"
          parent="panel"
          textKey={flags.debugOverlays ? "settings.debug.on" : "settings.debug.off"}
          kind={flags.debugOverlays ? "primary" : "default"}
          onClick={() => setDebugOverlays(!flags.debugOverlays)}
        />
        <LabelEl
          screen={SCREEN}
          id="panel.debug_hint"
          parent="panel"
          textKey="settings.debug.session_hint"
          tone="dim"
        />

        <LabelEl
          screen={SCREEN}
          id="panel.locale_label"
          parent="panel"
          textKey="settings.locale"
        />
        <ButtonEl
          screen={SCREEN}
          id="panel.locale_button"
          parent="panel"
          textKey="ui.language_toggle"
          onClick={() => setLocale(locale === "zh" ? "en" : "zh")}
        />

        <ButtonEl
          screen={SCREEN}
          id="panel.save_button"
          parent="panel"
          textKey="ui.save.title"
          hidden={!docked}
          onClick={() => navigate("save_slot")}
        />
        <ButtonEl
          screen={SCREEN}
          id="panel.return_button"
          parent="panel"
          textKey="settings.return_menu"
          hidden={!docked}
          onClick={() => setConfirmReturn(true)}
        />
        <ButtonEl
          screen={SCREEN}
          id="panel.close"
          parent="panel"
          textKey="settings.close"
          onClick={close}
        />
      </PanelEl>

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
