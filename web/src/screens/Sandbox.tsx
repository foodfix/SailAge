/**
 * S21 naval-battle sandbox (docs/80-UI-UX.md §4.7.16; the M7 kit
 * composition per 80-* §4.9.1) — a ZERO-WRITE proving ground reached from
 * the title screen.
 *
 * The DOM chrome is a stack of kit windows over the sea backdrop: the
 * player panel (captain stats row + one-line ship rows), the enemy panel
 * (profile row + ship rows, hidden while compose is armed) and the
 * conditions strip (encounter conditions + the four verbs). Fields are
 * `FieldRow` compositions; the per-ship editors keep their `data-field` /
 * `data-sandbox-row` identity hooks.
 *
 * The editor is a pure local fixture: it never calls an HTTP action or a WS
 * intent, never touches `GameState`, and never writes the save. `开战` builds
 * a local encounter and renders the existing S10 canvas (`BattleCanvas`)
 * read-only; `Esc` returns to the title.
 *
 * Reported gap: the server exposes no sandbox encounter seam (the §4.12.4
 * zero-write fixture contract exists in `server.sim.combat.battle_sim`, but
 * no endpoint drives it), so the preview is a static deployment snapshot,
 * not a simulated battle.
 */
import { useEffect, useMemo, useState } from "react";
import { content, useI18n } from "../i18n";
import { shipTypes } from "../i18n/strings";
import { useGameState } from "../state/context";
import type { ScreenId } from "./ids";
import { Button, Field, FieldRow, Footer, Frame, Toast } from "../kit";
import { Label, useToastState } from "./common";
import { BattleCanvas, toBattleView } from "../canvas/battle";
import type { BattleShipFrame, BattleTickFrame } from "../client/types";
import type { Direction8, Weather } from "../state/types";
import { navigate } from "../app/router";
import rawEquipment from "../../../data/equipment.json";
import "./Sandbox.css";

const SCREEN: ScreenId = "sandbox";
const MINUS = String.fromCharCode(0x2212);
const PLUS = String.fromCharCode(0x2b);

type SeedMode = "fixed" | "random" | "auto";
type Deployment = "standard" | "tournament";

interface SandboxShip {
  ship_type_id: string;
  cannons: number;
  crew: number;
  durability: number;
  equipment: { figurehead: string; sail: string };
  captain_id: string;
}

interface SandboxConfig {
  player: {
    stats: Record<string, number | string>;
    morale: number;
    ships: SandboxShip[];
  };
  enemy: {
    kind: string;
    ai_level: number;
    archetype: string;
    formation: string;
    morale: number;
    compose: boolean;
    ships: SandboxShip[];
  };
  conditions: {
    day: number;
    seed_mode: SeedMode;
    seed: number;
    weather: Weather;
    wind_dir: Direction8;
    current: { dir: Direction8; strength: number };
    deployment: Deployment;
  };
}

interface EquipmentDef {
  id: string;
  slot: string;
  name: { zh: string; en: string };
}

const EQUIPMENT = (rawEquipment as { equipment: EquipmentDef[] }).equipment;
const SHIP_TYPE_IDS = [...shipTypes.keys()];
const KIND_KEYS = [
  "pirate", "navy", "patrol", "privateer", "trader", "coaster", "courier",
  "treasure", "tournament",
] as const;
const FORMATIONS = ["swarm", "line_ahead", "screen", "column"] as const;
const DIRECTIONS: Direction8[] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
const WEATHERS: Weather[] = ["calm", "fair", "strong", "storm"];
const ATTRS = ["constitution", "intellect", "charisma", "courage", "luck"] as const;

export function Sandbox() {
  const { state } = useGameState();
  const { t, tKey } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const [preview, setPreview] = useState(false);

  const defaultConfig = useMemo<SandboxConfig>(() => {
    // The sandbox opens from the title, where the server snapshot is the
    // no-run shell (`player` = `{}` — no attributes/equipment block, an
    // empty fleet). Every read below tolerates that shape and falls back
    // to the editor's own blanks; a live run seeds the real fleet instead.
    const ships = (state.fleet ?? []).slice(0, 5).map((ship) => ({
      ship_type_id: ship.ship_type_id,
      cannons: ship.cannons,
      crew: ship.crew,
      durability: ship.durability,
      equipment: { ...ship.equipment },
      captain_id: "",
    }));
    return {
      player: {
        stats: {
          ...(state.player?.attributes ?? {}),
          weapon: state.player?.equipment?.weapon ?? "",
          armor: state.player?.equipment?.armor ?? "",
        },
        morale: state.morale,
        ships: ships.length > 0 ? ships : [blankShip("caravel")],
      },
      enemy: {
        kind: "pirate",
        ai_level: 1,
        archetype: "aggressive",
        formation: "swarm",
        morale: 50,
        compose: false,
        ships: [blankShip("sloop")],
      },
      conditions: {
        day: state.day,
        seed_mode: "fixed",
        seed: 1,
        weather: state.world.weather,
        wind_dir: state.world.wind_dir,
        current: { dir: state.world.wind_dir, strength: 0 },
        deployment: "standard",
      },
    };
  }, [state]);

  const [config, setConfig] = useState<SandboxConfig>(defaultConfig);
  useEffect(() => setConfig(defaultConfig), [defaultConfig]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      navigate("title");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const update = (mutator: (draft: SandboxConfig) => void) => {
    setConfig((current) => {
      const draft = JSON.parse(JSON.stringify(current)) as SandboxConfig;
      mutator(draft);
      return draft;
    });
  };

  const randomShipFields = (ship: SandboxShip): SandboxShip => {
    const def = content.shipType(ship.ship_type_id);
    const slots = def?.armament_slots ?? 0;
    const crewMin = def?.crew_min ?? 0;
    const crewMax = def?.crew_max ?? crewMin;
    const pick = (slot: string): string => {
      const pool = EQUIPMENT.filter((item) => item.slot === slot);
      if (pool.length === 0 || Math.random() < 0.5) return "";
      return pool[Math.floor(Math.random() * pool.length)].id;
    };
    return {
      ...ship,
      cannons: Math.floor(Math.random() * (slots + 1)),
      crew: crewMin + Math.floor(Math.random() * Math.max(1, crewMax - crewMin + 1)),
      durability: 1 + Math.floor(Math.random() * Math.max(1, def?.durability ?? 1)),
      equipment: { figurehead: pick("figurehead"), sail: pick("sail") },
    };
  };

  const randomize = () => {
    update((draft) => {
      for (const key of ATTRS) draft.player.stats[key] = Math.floor(Math.random() * 101);
      draft.player.morale = Math.floor(Math.random() * 101);
      draft.enemy.morale = Math.floor(Math.random() * 101);
      draft.enemy.ai_level = Math.random() < 0.5 ? 0 : 1;
      draft.enemy.archetype = ["aggressive", "balanced", "cautious"][Math.floor(Math.random() * 3)];
      draft.enemy.formation = FORMATIONS[Math.floor(Math.random() * FORMATIONS.length)];
      draft.conditions.day = 1 + Math.floor(Math.random() * 360);
      draft.conditions.weather = WEATHERS[Math.floor(Math.random() * WEATHERS.length)];
      draft.conditions.wind_dir = DIRECTIONS[Math.floor(Math.random() * DIRECTIONS.length)];
      draft.conditions.current.dir = DIRECTIONS[Math.floor(Math.random() * DIRECTIONS.length)];
      draft.conditions.current.strength = Math.floor(Math.random() * 4);
      draft.player.ships = draft.player.ships.map(randomShipFields);
      draft.enemy.ships = draft.enemy.ships.map(randomShipFields);
    });
  };

  const exportJson = () => {
    const payload = {
      version: 1,
      kind: "sailage_sandbox",
      player: config.player,
      enemy: config.enemy,
      conditions: config.conditions,
    };
    const text = JSON.stringify(payload);
    const clipboard = navigator.clipboard;
    if (clipboard) {
      void clipboard.writeText(text).then(
        () => showToast("sandbox.export.ok", undefined, "good"),
        () => window.prompt(tKey("sandbox.export"), text),
      );
    } else {
      window.prompt(tKey("sandbox.export"), text);
    }
  };

  const importJson = () => {
    const text = window.prompt(tKey("sandbox.import"));
    if (!text) return;
    try {
      const parsed = JSON.parse(text) as {
        version?: number;
        kind?: string;
        player?: SandboxConfig["player"];
        enemy?: SandboxConfig["enemy"];
        conditions?: SandboxConfig["conditions"];
      };
      if (parsed.version !== 1 || parsed.kind !== "sailage_sandbox"
        || !parsed.player || !parsed.enemy || !parsed.conditions) {
        showToast("sandbox.import.invalid", undefined, "bad");
        return;
      }
      setConfig({
        player: parsed.player,
        enemy: parsed.enemy,
        conditions: parsed.conditions,
      });
      showToast("sandbox.import.ok", undefined, "good");
    } catch {
      showToast("sandbox.import.invalid", undefined, "bad");
    }
  };

  const start = () => {
    update((draft) => {
      if (draft.enemy.compose) {
        draft.enemy.ships = [
          blankShip("brigantine"),
          blankShip("sloop"),
          blankShip("brigantine"),
        ];
      }
    });
    setPreview(true);
  };

  const frame = useMemo<BattleTickFrame>(() => {
    const ships: BattleShipFrame[] = [];
    config.player.ships.forEach((ship, index) => {
      ships.push({
        id: `player_${index}`,
        side: "player",
        kind: ship.ship_type_id,
        position: { x: 10, y: 12 + index * 2 },
        velocity: { x: 1, y: 0 },
        heading8: "E",
        hull: ship.durability,
        crew: ship.crew,
        morale: config.player.morale,
        reload: { port: 1, starboard: 1 },
      });
    });
    config.enemy.ships.forEach((ship, index) => {
      ships.push({
        id: `enemy_${index}`,
        side: "enemy",
        kind: ship.ship_type_id,
        position: { x: 37, y: 12 + index * 2 },
        velocity: { x: -1, y: 0 },
        heading8: "W",
        hull: ship.durability,
        crew: ship.crew,
        morale: config.enemy.morale,
        reload: { port: 1, starboard: 1 },
      });
    });
    return {
      type: "battle_tick",
      round: 1,
      phase: "player",
      ships,
      wind: { dir: config.conditions.wind_dir, strength: 2 },
      weather: config.conditions.weather,
      orders_due: false,
    };
  }, [config]);

  const view = useMemo(() => toBattleView(frame), [frame]);

  const shipRow = (side: "player" | "enemy", index: number, ship: SandboxShip) => {
    const prefix = `${side}_rows.${index}`;
    const def = content.shipType(ship.ship_type_id);
    const setShip = (mutator: (target: SandboxShip) => void) =>
      update((draft) => {
        const list = side === "player" ? draft.player.ships : draft.enemy.ships;
        const target = list[index];
        if (target) mutator(target);
      });
    const equipment = (slot: string) => EQUIPMENT.filter((item) => item.slot === slot);
    return (
      <div key={prefix} className="sandbox__shiprow" data-sandbox-row={prefix}>
        <span className="sa-badge sandbox__shipnum">{String(index + 1)}</span>
        <SelectField
          id={`${prefix}.type`}
          labelKey="sandbox.ship.type"
          hasLabel={false}
          value={ship.ship_type_id}
          options={SHIP_TYPE_IDS.map((id) => ({ value: id, label: t(content.shipName(id)) }))}
          onChange={(value) =>
            setShip((target) => {
              target.ship_type_id = value;
              target.durability = Math.max(1, content.shipType(value)?.durability ?? 1);
              target.cannons = Math.min(target.cannons, content.shipType(value)?.armament_slots ?? 0);
              target.crew = Math.min(target.crew, content.shipType(value)?.crew_max ?? 0);
            })
          }
        />
        <NumberField
          id={`${prefix}.cannons`}
          labelKey="sandbox.ship.cannons"
          value={ship.cannons}
          max={def?.armament_slots ?? 0}
          onChange={(value) => setShip((target) => { target.cannons = value; })}
        />
        <NumberField
          id={`${prefix}.crew`}
          labelKey="sandbox.ship.crew"
          value={ship.crew}
          max={def?.crew_max ?? ship.crew}
          onChange={(value) => setShip((target) => { target.crew = value; })}
        />
        <NumberField
          id={`${prefix}.durability`}
          labelKey="sandbox.ship.durability"
          value={ship.durability}
          min={1}
          max={def?.durability ?? ship.durability}
          onChange={(value) => setShip((target) => { target.durability = value; })}
        />
        <TextField
          id={`${prefix}.captain`}
          labelKey="sandbox.ship.captain"
          value={ship.captain_id}
          onChange={(value) => setShip((target) => { target.captain_id = value; })}
        />
        <SelectField
          id={`${prefix}.figurehead`}
          labelKey="sandbox.ship.figurehead"
          value={ship.equipment.figurehead}
          options={[{ value: "", label: tKey("char.none") }, ...equipment("figurehead").map((item) => ({ value: item.id, label: t(item.name) }))]}
          onChange={(value) => setShip((target) => { target.equipment.figurehead = value; })}
        />
        <SelectField
          id={`${prefix}.sail`}
          labelKey="sandbox.ship.sail"
          value={ship.equipment.sail}
          options={[{ value: "", label: tKey("char.none") }, ...equipment("sail").map((item) => ({ value: item.id, label: t(item.name) }))]}
          onChange={(value) => setShip((target) => { target.equipment.sail = value; })}
        />
      </div>
    );
  };

  return (
    <div className="sa-screen sandbox" data-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />
      <div className="sandbox__head sa-plate">
        <div className="sandbox__head_names">
          <Label textKey="sandbox.title" title />
          <Label textKey="sandbox.zero_write" tone="warn" />
        </div>
        <Label textKey="sandbox.back" tone="dim" />
      </div>

      <div className="sandbox__actions">
        <Button textKey="sandbox.start" kind="primary" onClick={start} />
        <Button textKey="sandbox.random_all" onClick={randomize} />
        <Button textKey="sandbox.import" onClick={importJson} />
        <Button textKey="sandbox.export" onClick={exportJson} />
      </div>

      {preview ? (
        <div className="sandbox__field sa-grow">
          <BattleCanvas
            scene={{ view, selectedId: null, targetId: null, aiInstant: false }}
            fitSignal={0}
            onSelect={() => undefined}
          />
        </div>
      ) : (
        <div className="sandbox__editor sa-grow sa-scroll">
          <Frame titleKey="sandbox.player" className="sandbox__panel">
            <div className="sandbox__panel_body">
              <div className="sandbox__grid sandbox__stats">
                {ATTRS.map((key) => (
                  <NumberField
                    key={key}
                    id={`player_panel.stats_row.${key}`}
                    labelKey={`char.attr.${key}`}
                    value={Number(config.player.stats[key] ?? 0)}
                    max={100}
                    onChange={(value) => update((draft) => { draft.player.stats[key] = value; })}
                  />
                ))}
                <SelectField
                  id="player_panel.stats_row.weapon"
                  labelKey="shipyard.slot.weapon"
                  value={String(config.player.stats.weapon ?? "")}
                  options={[{ value: "", label: tKey("char.none") }, ...EQUIPMENT.filter((item) => item.slot === "weapon").map((item) => ({ value: item.id, label: t(item.name) }))]}
                  onChange={(value) => update((draft) => { draft.player.stats.weapon = value; })}
                />
                <SelectField
                  id="player_panel.stats_row.armor"
                  labelKey="shipyard.slot.armor"
                  value={String(config.player.stats.armor ?? "")}
                  options={[{ value: "", label: tKey("char.none") }, ...EQUIPMENT.filter((item) => item.slot === "armor").map((item) => ({ value: item.id, label: t(item.name) }))]}
                  onChange={(value) => update((draft) => { draft.player.stats.armor = value; })}
                />
                <NumberField
                  id="player_panel.stats_row.morale"
                  labelKey="sandbox.morale.short"
                  value={config.player.morale}
                  max={100}
                  onChange={(value) => update((draft) => { draft.player.morale = value; })}
                />
                <Button
                  text={PLUS}
                  compact
                  onClick={() => update((draft) => {
                    if (draft.player.ships.length >= 5) {
                      showToast("sandbox.ship.max", undefined, "bad");
                      return;
                    }
                    draft.player.ships.push(blankShip("sloop"));
                  })}
                />
                <Button
                  text={MINUS}
                  compact
                  onClick={() => update((draft) => {
                    if (draft.player.ships.length > 1) draft.player.ships.pop();
                  })}
                />
              </div>
              <div className="sandbox__rows">
                {config.player.ships.map((ship, index) => shipRow("player", index, ship))}
              </div>
            </div>
          </Frame>

          <Frame titleKey="sandbox.enemy" className="sandbox__panel">
            <div className="sandbox__panel_body">
              <div className="sandbox__grid sandbox__profile">
                <SelectField
                  id="enemy_panel.profile_row.kind"
                  labelKey="sandbox.enemy.kind"
                  value={config.enemy.kind}
                  options={KIND_KEYS.map((kind) => ({ value: kind, label: tKey(`sandbox.kind.${kind}`) }))}
                  onChange={(value) => update((draft) => { draft.enemy.kind = value; })}
                />
                <Button
                  textKey="sandbox.enemy.compose"
                  kind={config.enemy.compose ? "primary" : "default"}
                  onClick={() => update((draft) => { draft.enemy.compose = !draft.enemy.compose; })}
                />
                <TextField
                  id="enemy_panel.profile_row.flagship"
                  labelKey="sandbox.enemy.flagship"
                  value={config.enemy.ships[0]?.captain_id ?? ""}
                  onChange={(value) => update((draft) => {
                    if (draft.enemy.ships[0]) draft.enemy.ships[0].captain_id = value;
                  })}
                />
                <SelectField
                  id="enemy_panel.profile_row.ai_level"
                  labelKey="sandbox.ai_level"
                  value={String(config.enemy.ai_level)}
                  options={[
                    { value: "0", label: tKey("sandbox.ai_level.t2") },
                    { value: "1", label: tKey("sandbox.ai_level.t3") },
                  ]}
                  onChange={(value) => update((draft) => { draft.enemy.ai_level = Number(value); })}
                />
                <SelectField
                  id="enemy_panel.profile_row.archetype"
                  labelKey="sandbox.archetype"
                  value={config.enemy.archetype}
                  options={["aggressive", "balanced", "cautious"].map((kind) => ({ value: kind, label: tKey(`sandbox.archetype.${kind}`) }))}
                  onChange={(value) => update((draft) => { draft.enemy.archetype = value; })}
                />
                <SelectField
                  id="enemy_panel.profile_row.formation"
                  labelKey="sandbox.formation"
                  value={config.enemy.formation}
                  options={FORMATIONS.map((formation) => ({ value: formation, label: tKey(`battle.formation.${formation}`) }))}
                  onChange={(value) => update((draft) => { draft.enemy.formation = value; })}
                />
                <NumberField
                  id="enemy_panel.profile_row.morale"
                  labelKey="sandbox.morale.enemy"
                  value={config.enemy.morale}
                  max={100}
                  onChange={(value) => update((draft) => { draft.enemy.morale = value; })}
                />
                <Button
                  text={PLUS}
                  compact
                  onClick={() => update((draft) => {
                    if (draft.enemy.ships.length >= 5) {
                      showToast("sandbox.ship.max", undefined, "bad");
                      return;
                    }
                    draft.enemy.ships.push(blankShip("sloop"));
                  })}
                />
                <Button
                  text={MINUS}
                  compact
                  onClick={() => update((draft) => {
                    if (draft.enemy.ships.length > 1) draft.enemy.ships.pop();
                  })}
                />
              </div>
              {!config.enemy.compose ? (
                <div className="sandbox__rows">
                  {config.enemy.ships.map((ship, index) => shipRow("enemy", index, ship))}
                </div>
              ) : null}
            </div>
          </Frame>

          <Frame className="sandbox__panel">
            <div className="sandbox__panel_body">
              <div className="sandbox__grid sandbox__conditions">
                <NumberField
                  id="conditions_panel.grid.day"
                  labelKey="sandbox.day"
                  value={config.conditions.day}
                  min={1}
                  max={3600}
                  onChange={(value) => update((draft) => { draft.conditions.day = value; })}
                />
                <SelectField
                  id="conditions_panel.grid.seed_mode"
                  labelKey="sandbox.seed"
                  value={config.conditions.seed_mode}
                  options={(["fixed", "random", "auto"] as SeedMode[]).map((mode) => ({ value: mode, label: tKey(`sandbox.seed.${mode}`) }))}
                  onChange={(value) => update((draft) => { draft.conditions.seed_mode = value as SeedMode; })}
                />
                <TextField
                  id="conditions_panel.grid.seed_value"
                  labelKey="sandbox.seed"
                  hasLabel={false}
                  value={String(config.conditions.seed)}
                  onChange={(value) => update((draft) => { draft.conditions.seed = Number(value.replace(/[^0-9]/g, "")) || 0; })}
                />
                <SelectField
                  id="conditions_panel.grid.weather"
                  labelKey="sandbox.weather"
                  value={config.conditions.weather}
                  options={WEATHERS.map((weather) => ({ value: weather, label: tKey(`world.weather.${weather}`) }))}
                  onChange={(value) => update((draft) => { draft.conditions.weather = value as Weather; })}
                />
                <SelectField
                  id="conditions_panel.grid.wind_dir"
                  labelKey="sandbox.wind_dir"
                  value={config.conditions.wind_dir}
                  options={DIRECTIONS.map((dir) => ({ value: dir, label: tKey(`sandbox.dir.${dir}`) }))}
                  onChange={(value) => update((draft) => { draft.conditions.wind_dir = value as Direction8; })}
                />
                <SelectField
                  id="conditions_panel.grid.current"
                  labelKey="sandbox.current"
                  value={config.conditions.current.dir}
                  options={DIRECTIONS.map((dir) => ({ value: dir, label: tKey(`sandbox.dir.${dir}`) }))}
                  onChange={(value) => update((draft) => { draft.conditions.current.dir = value as Direction8; })}
                />
                <NumberField
                  id="conditions_panel.grid.current_strength"
                  labelKey="sandbox.current.strength"
                  value={config.conditions.current.strength}
                  max={3}
                  onChange={(value) => update((draft) => { draft.conditions.current.strength = value; })}
                />
                <SelectField
                  id="conditions_panel.grid.deployment"
                  labelKey="sandbox.deployment"
                  value={config.conditions.deployment}
                  options={(["standard", "tournament"] as Deployment[]).map((deployment) => ({ value: deployment, label: tKey(`sandbox.deployment.${deployment}`) }))}
                  onChange={(value) => update((draft) => { draft.conditions.deployment = value as Deployment; })}
                />
              </div>
              <Footer
                buttons={[
                  <Button key="start" textKey="sandbox.start" kind="primary" onClick={start} />,
                  <Button key="random" textKey="sandbox.random_all" onClick={randomize} />,
                  <Button key="import" textKey="sandbox.import" onClick={importJson} />,
                  <Button key="export" textKey="sandbox.export" onClick={exportJson} />,
                ]}
              />
            </div>
          </Frame>
        </div>
      )}

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}

function blankShip(shipTypeId: string): SandboxShip {
  const def = content.shipType(shipTypeId);
  return {
    ship_type_id: shipTypeId,
    cannons: Math.min(4, def?.armament_slots ?? 0),
    crew: Math.min(def?.crew_max ?? 1, Math.max(def?.crew_min ?? 0, 1)),
    durability: def?.durability ?? 1,
    equipment: { figurehead: "", sail: "" },
    captain_id: "",
  };
}

/* --- Editor field shells -------------------------------------------------- */
/* Each keeps its layout-era identity (`data-field`) and clamping; the label
   rides the kit FieldRow (or is dropped where the old editor dropped it). */

function NumberField({
  id,
  labelKey,
  value,
  min = 0,
  max,
  hasLabel = true,
  onChange,
}: {
  id: string;
  labelKey: string;
  value: number;
  min?: number;
  max: number;
  hasLabel?: boolean;
  onChange: (value: number) => void;
}) {
  const control = (
    <Field
      value={String(value)}
      ariaLabelKey={labelKey}
      onChange={(text) => {
        const parsed = Number(text.replace(/[^0-9]/g, ""));
        onChange(Math.max(min, Math.min(max, Number.isFinite(parsed) ? parsed : min)));
      }}
    />
  );
  return (
    <div data-field={id} className="sandbox__cell">
      {hasLabel ? <FieldRow labelKey={labelKey}>{control}</FieldRow> : control}
    </div>
  );
}

function TextField({
  id,
  labelKey,
  value,
  hasLabel = true,
  onChange,
}: {
  id: string;
  labelKey: string;
  value: string;
  hasLabel?: boolean;
  onChange: (value: string) => void;
}) {
  const control = <Field value={value} ariaLabelKey={labelKey} onChange={onChange} />;
  return (
    <div data-field={id} className="sandbox__cell">
      {hasLabel ? <FieldRow labelKey={labelKey}>{control}</FieldRow> : control}
    </div>
  );
}

function SelectField({
  id,
  labelKey,
  value,
  options,
  hasLabel = true,
  onChange,
}: {
  id: string;
  labelKey: string;
  value: string;
  options: { value: string; label: string }[];
  hasLabel?: boolean;
  onChange: (value: string) => void;
}) {
  const { tKey } = useI18n();
  const control = (
    <label className="sa-field">
      <select
        className="sa-field__input"
        aria-label={tKey(labelKey)}
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  );
  return (
    <div data-field={id} className="sandbox__cell">
      {hasLabel ? <FieldRow labelKey={labelKey}>{control}</FieldRow> : control}
    </div>
  );
}
