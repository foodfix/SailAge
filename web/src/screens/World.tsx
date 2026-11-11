/**
 * S3 — the sailing screen (docs/80-UI-UX.md §4.5; docs/20-WORLD-AND-SAILING.md
 * §4.1–§4.3, §4.11).
 *
 * A pure renderer over the authoritative tick stream (`90-*` §0.3): the canvas
 * draws the world pyramid + fleet/markers, the HUD binds the `world` rows of
 * data/ui_layout.json, and every key becomes a frozen intent. The only client
 * math is presentation arithmetic (sums, calendar readout, supply days per the
 * locked §4.10 formula); no movement or economy rule lives here.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useGameClient } from "../client/context";
import type { TickFrame } from "../client/types";
import { content, useI18n, type L10nValue } from "../i18n";
import { Box, CANVAS_TILES, Element, type ScreenId } from "../layout";
import {
  MinimapCanvas,
  MONTH_DAYS,
  MORALE_TIERS,
  nearestKnownPort,
  RATION_SIZE,
  SUPPLY_GOOD_DAYS,
  SUPPLY_WARN_DAYS,
  useWorldInput,
  WorldCanvas,
  YEAR_MONTHS,
  ZOOM_NEAR,
  ZOOM_WIDE,
} from "../canvas/world";
import type { Vec2, WorldScene } from "../canvas/world";
import type { Direction8, GameSnapshot } from "../state/types";
import { fixtureSailing } from "../state/fixture";
import { navigate } from "../app/router";
import { ButtonEl, LabelEl, PanelEl } from "./common";
import type { LabelTone } from "./common";
import type { ToastTone } from "../kit";

const SCREEN: ScreenId = "world";

const WIND_GLYPHS: Record<Direction8, string> = {
  N: "↑",
  NE: "↗",
  E: "→",
  SE: "↘",
  S: "↓",
  SW: "↙",
  W: "←",
  NW: "↖",
};

/** The HUD's first paint before the first tick frame lands. */
function initialTick(snapshot: GameSnapshot): TickFrame {
  return {
    type: "tick",
    day: snapshot.day,
    clock_min: fixtureSailing.clock_min,
    position: { ...snapshot.world.position },
    heading: snapshot.world.heading,
    sail_trim: snapshot.world.sail_trim,
    wind_dir: snapshot.world.wind_dir,
    weather: snapshot.world.weather,
    speed: fixtureSailing.speed,
    gold: snapshot.gold,
    morale: snapshot.morale,
    autopilot: null,
    contact_hint: "",
  };
}

interface ToastState {
  key: string;
  values?: Record<string, L10nValue>;
  tone?: ToastTone;
}

function clockText(clockMin: number): string {
  const minutes = ((Math.round(clockMin) % 1440) + 1440) % 1440;
  const hh = String(Math.floor(minutes / 60)).padStart(2, "0");
  const mm = String(minutes % 60).padStart(2, "0");
  return `${hh}:${mm}`;
}

/** §4.15 calendar: 30-day months, 12-month years (day 1 = Year 1 Month 1). */
function calendarOf(day: number): { year: number; month: number } {
  const cycle = MONTH_DAYS * YEAR_MONTHS;
  const offset = (((day - 1) % cycle) + cycle) % cycle;
  return { year: Math.floor((day - 1) / cycle) + 1, month: Math.floor(offset / MONTH_DAYS) + 1 };
}

function supplyTone(days: number): LabelTone {
  if (days >= SUPPLY_GOOD_DAYS) return "good";
  if (days >= SUPPLY_WARN_DAYS) return "warn";
  return "bad";
}

export function WorldScreen() {
  const client = useGameClient();
  const { locale, t, tKey, fmt } = useI18n();
  const [snapshot, setSnapshot] = useState<GameSnapshot>(fixtureSailing.snapshot);
  const [tick, setTick] = useState<TickFrame>(() => initialTick(fixtureSailing.snapshot));
  const [zoom, setZoom] = useState(ZOOM_NEAR);
  const [toast, setToast] = useState<ToastState | null>(null);

  useEffect(
    () =>
      client.connect({
        onFrame: (frame) => {
          if (frame.type === "tick") setTick(frame);
          else if (frame.type === "state") setSnapshot(frame);
        },
      }),
    [client],
  );

  const scene = useMemo<WorldScene>(() => {
    // M2 rides the §4.5.2 marker projection on `npc_fleets`; until then the
    // fixture scenario supplies the same rows.
    const markers =
      snapshot.npc_fleets.length > 0
        ? (snapshot.npc_fleets as unknown as WorldScene["npcMarkers"])
        : fixtureSailing.view.npc_markers;
    return { snapshot, npcMarkers: markers };
  }, [snapshot]);

  const onDock = useCallback(() => navigate("port"), []);
  const onToggleZoom = useCallback(
    () => setZoom((current) => (current === ZOOM_NEAR ? ZOOM_WIDE : ZOOM_NEAR)),
    [],
  );
  const onSailTo = useCallback(
    (cell: Vec2) => client.send({ type: "sail_to", x: cell.x, y: cell.y }),
    [client],
  );

  useWorldInput({ client, snapshot, trim: tick.sail_trim, onDock, onToggleZoom });

  // Dock announcement + the §4.5 intel seam (the shared window lands in M6).
  useEffect(() => {
    const portId = snapshot.current_port;
    if (!portId) return;
    setToast({ key: "world.enter_port", values: { port: content.portName(portId) }, tone: "good" });
  }, [snapshot.current_port]);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(null), 2600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const fleet = useMemo(() => {
    let crew = 0;
    let crewMax = 0;
    let provisions = 0;
    let water = 0;
    let cargo = 0;
    let capacity = 0;
    for (const ship of snapshot.fleet) {
      const def = content.shipType(ship.ship_type_id);
      crew += ship.crew;
      crewMax += def?.crew_max ?? 0;
      capacity += def?.capacity ?? 0;
      provisions += ship.provisions;
      water += ship.water;
      cargo += ship.provisions + ship.water;
      for (const qty of Object.values(ship.cargo)) cargo += qty;
    }
    const need = crew > 0 ? Math.ceil(crew / RATION_SIZE) : 0;
    const provisionsDays = need > 0 ? Math.floor(provisions / need) : 0;
    const waterDays = need > 0 ? Math.floor(water / need) : 0;
    return { crew, crewMax, provisions, water, cargo, capacity, provisionsDays, waterDays };
  }, [snapshot.fleet]);

  const moraleTier = MORALE_TIERS.find((entry) => tick.morale >= entry.min)?.tier ?? "mutinous";
  const moraleTone: LabelTone = tick.morale < 20 ? "bad" : tick.morale < 40 ? "warn" : "good";
  const trimmed = tick.sail_trim !== "normal";
  const areaId = snapshot.current_port ?? nearestKnownPort(tick.position, snapshot.known_ports);
  const areaText = areaId ? t(content.portName(areaId)) : tKey("world.open_sea");
  const goldText = new Intl.NumberFormat(locale === "zh" ? "zh-CN" : "en-US").format(tick.gold);
  const dayTime = fmt("world.day_time", { day: tick.day, time: clockText(tick.clock_min) });
  const calendarParts = calendarOf(tick.day);
  const calendar = fmt("world.calendar.year_month", { y: calendarParts.year, m: calendarParts.month });
  const gold = fmt("world.gold", { gold: goldText });
  const morale = `${fmt("world.morale", { amount: tick.morale })} (${tKey(`world.morale.${moraleTier}`)})`;
  const supplyNoun = fmt("world.provisions", { amount: "" }).trim();
  const provisionsLine = fmt("fleet.stat.supply", {
    kind: supplyNoun,
    amount: fleet.provisions,
    days: fleet.provisionsDays,
  });
  const waterNoun = fmt("world.water", { amount: "" }).trim();
  const waterLine = fmt("fleet.stat.supply", {
    kind: waterNoun,
    amount: fleet.water,
    days: fleet.waterDays,
  });
  const crewLine = fmt("world.crew", { crew: fleet.crew, max: fleet.crewMax });
  const cargoLine = fmt("world.cargo", { amount: fleet.cargo, capacity: fleet.capacity });
  const speedLine = fmt("world.speed", { speed: tick.speed.toFixed(1) });
  const trimLine = fmt("world.trim.chip", { state: tKey(`world.trim.${tick.sail_trim}`) });
  const weather = tKey(`world.weather.${tick.weather}`);
  const wind = `${tKey("world.wind.label")} ${WIND_GLYPHS[tick.wind_dir]}`;

  return (
    <div className="sa-screen" data-world-screen="world">
      <Box rect={{ x: 0, y: 0, w: CANVAS_TILES.w, h: CANVAS_TILES.h }}>
        <WorldCanvas scene={scene} tick={tick} zoom={zoom} locale={locale} onSailTo={onSailTo} />
      </Box>

      <PanelEl screen={SCREEN} id="top_bar" skin="panel" />
      <Element screen={SCREEN} id="hud">
        <LabelEl screen={SCREEN} id="hud.day" parent="hud" textValue={dayTime} title />
        <LabelEl screen={SCREEN} id="hud.calendar" parent="hud" textValue={calendar} />
        <LabelEl screen={SCREEN} id="hud.gold" parent="hud" textValue={gold} />
        <LabelEl screen={SCREEN} id="hud.morale" parent="hud" textValue={morale} tone={moraleTone} />
        <LabelEl screen={SCREEN} id="hud.area" parent="hud" textValue={areaText} />
        <ButtonEl
          screen={SCREEN}
          id="hud.intel"
          parent="hud"
          textKey="ui.intel"
          onClick={() => navigate("intel_window")}
        />
      </Element>

      <PanelEl screen={SCREEN} id="bottom_bar" skin="panel" />
      <Element screen={SCREEN} id="status">
        <LabelEl
          screen={SCREEN}
          id="status.provisions"
          parent="status"
          textValue={provisionsLine}
          tone={supplyTone(fleet.provisionsDays)}
        />
        <LabelEl
          screen={SCREEN}
          id="status.water"
          parent="status"
          textValue={waterLine}
          tone={supplyTone(fleet.waterDays)}
        />
        <LabelEl screen={SCREEN} id="status.crew" parent="status" textValue={crewLine} />
        <LabelEl screen={SCREEN} id="status.cargo" parent="status" textValue={cargoLine} />
        <LabelEl screen={SCREEN} id="status.speed" parent="status" textValue={speedLine} />
        <LabelEl
          screen={SCREEN}
          id="status.trim"
          parent="status"
          textValue={trimLine}
          tone={trimmed ? "accent" : "default"}
        />
      </Element>

      <Element screen={SCREEN} id="minimap">
        <MinimapCanvas snapshot={snapshot} tick={tick} />
      </Element>
      <LabelEl screen={SCREEN} id="minimap_title" textKey="world.minimap" tone="accent" />

      <LabelEl
        screen={SCREEN}
        id="weather"
        textValue={weather}
        tone={tick.weather === "storm" ? "bad" : tick.weather === "strong" ? "warn" : "accent"}
      />
      <LabelEl screen={SCREEN} id="wind" textValue={wind} tone="accent" />
      {/* Current indicator: §4.5 shows it only on a current tile; the frozen
          tick frame carries no current vector yet (M2 contract note). */}
      <LabelEl screen={SCREEN} id="current" textKey="world.current.label" tone="accent" hidden />

      <LabelEl screen={SCREEN} id="explore_hint" textKey="discovery.something_near" hidden />
      <ButtonEl screen={SCREEN} id="explore" textKey="discovery.explore" hidden />

      <PanelEl screen={SCREEN} id="toast" skin="panel" hidden={!toast}>
        <LabelEl
          screen={SCREEN}
          id="toast.label"
          parent="toast"
          textValue={toast ? fmt(toast.key, toast.values ?? {}) : ""}
        />
      </PanelEl>
    </div>
  );
}
