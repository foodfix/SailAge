/**
 * The static data imports. The JSON files under data/ remain the single
 * source of truth (AGENTS.md data-first rule); Vite compiles them into the
 * bundle at build time and serves them from disk in dev. The configurable
 * fetch path lives in loader.ts for the M2 server build.
 */
import rawUiStrings from "../../../data/ui_strings.json";
import rawGoods from "../../../data/goods.json";
import rawShipTypes from "../../../data/ship_types.json";
import rawPorts from "../../../data/ports.json";
import rawNations from "../../../data/nations.json";
import rawOfficers from "../../../data/officers.json";
import rawEquipment from "../../../data/equipment.json";
import rawFacilityHours from "../../../data/facility_hours.json";
import rawDiscoveries from "../../../data/discoveries.json";
import type { L10nString } from "./types";

export type UiStrings = Record<string, L10nString>;

const uiRaw = rawUiStrings as Record<string, unknown>;
export const uiStrings: UiStrings = Object.fromEntries(
  Object.entries(uiRaw).filter(([key]) => key !== "version"),
) as UiStrings;

export interface DefWithName {
  id: string;
  name: L10nString;
}

export interface GoodDef extends DefWithName {
  category: string;
  base_price: number;
  unit_size: number;
  staple?: boolean;
}

export interface ShipTypeDef extends DefWithName {
  class: string;
  role: string;
  tier: number;
  base_price: number;
  durability: number;
  capacity: number;
  speed: number;
  crew_min: number;
  crew_max: number;
  armament_slots: number;
}

export interface PortDef extends DefWithName {
  nation_id: string;
  dev: number;
  produces: string[];
  demands: string[];
  facilities: Record<string, number | string[]>;
  flavor?: L10nString;
}

export interface NationDef extends DefWithName {
  capital_port_id: string;
  color: string;
}

export interface OfficerDef extends DefWithName {
  nation_id: string;
  legend: boolean;
  main_skill: string;
  attributes: Record<string, number>;
  skills: Record<string, number>;
  wage_daily: number;
  recruit_ports: string[];
}

export interface EquipmentDef extends DefWithName {
  slot: string;
  modifiers: Record<string, number>;
  price: number;
  tier: number;
}

export interface DiscoveryDef extends DefWithName {
  category: string;
  lat: number;
  lon: number;
  fame: number;
  report_reward_gold: number;
  region_hint: L10nString;
}

type Named = { id: string; name: L10nString };

function indexById<T extends Named>(file: unknown, key: string): Map<string, T> {
  const bag = (file as Record<string, unknown>)[key];
  return new Map(((bag as T[] | undefined) ?? []).map((entry) => [entry.id, entry]));
}

export const goods = indexById<GoodDef>(rawGoods, "goods");
export const shipTypes = indexById<ShipTypeDef>(rawShipTypes, "ship_types");
export const ports = indexById<PortDef>(rawPorts, "ports");
export const nations = indexById<NationDef>(rawNations, "nations");
export const officers = indexById<OfficerDef>(rawOfficers, "officers");
export const equipment = indexById<EquipmentDef>(rawEquipment, "equipment");
export const discoveries = indexById<DiscoveryDef>(rawDiscoveries, "discoveries");

export interface FacilityHours {
  default: Record<string, string | string[]>;
  overrides: Record<string, unknown>;
}
export const facilityHours = rawFacilityHours as FacilityHours;

/**
 * Resolve a content name. A missing id is a data bug: log it and render
 * the id in angle brackets (the same loud-never-silent discipline as the
 * ui_strings contract). Content names are rendered through t().
 */
function label(map: Map<string, Named>, id: string, kind: string): L10nString {
  const entry = map.get(id);
  if (!entry) {
    console.error(`I18n: unknown ${kind} id '${id}'`);
    return { zh: `<${id}>`, en: `<${id}>` };
  }
  return entry.name;
}

export const content = {
  portName: (id: string) => label(ports, id, "port"),
  goodName: (id: string) => label(goods, id, "good"),
  shipName: (id: string) => label(shipTypes, id, "ship_type"),
  nationName: (id: string) => label(nations, id, "nation"),
  officerName: (id: string) => label(officers, id, "officer"),
  equipmentName: (id: string) => label(equipment, id, "equipment"),
  discoveryName: (id: string) => label(discoveries, id, "discovery"),
  good: (id: string) => goods.get(id),
  shipType: (id: string) => shipTypes.get(id),
  port: (id: string) => ports.get(id),
  nation: (id: string) => nations.get(id),
  officer: (id: string) => officers.get(id),
  equipmentDef: (id: string) => equipment.get(id),
  discovery: (id: string) => discoveries.get(id),
};
