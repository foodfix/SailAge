/**
 * S6 shipyard — catalog, fleet list, ship equipment and repair/refit/sell.
 * Every `shipyard` element row is rendered; `catalog` and `fleet` are the
 * declared list blocks.
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { FleetRow, ShipCatalogRow } from "../state/types";
import { Box, Element, ListRows, type ScreenId } from "../layout";
import { Field, Icon, Toast, Button } from "../kit";
import { ButtonEl, IconBox, LabelEl, PanelEl, useToastState } from "./common";
import { navigate } from "../app/router";

const SCREEN: ScreenId = "shipyard";

function roleKey(role: string | undefined): string {
  return role === "war" ? "shipyard.role.war" : role === "trade" ? "shipyard.role.trade" : "shipyard.role.coastal";
}

export function ShipyardScreen() {
  const { state, views } = useGameState();
  const view = views.shipyard;
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [repair, setRepair] = useState<Record<number, string>>({});

  const portName = t(content.portName(view.portId));

  const buy = (row: ShipCatalogRow) => {
    if (!row.canBuy) return;
    void client.shipyard.buy(row.shipTypeId);
    showToast("shipyard.bought", { ship: content.shipName(row.shipTypeId) }, "good");
  };

  const repairShip = (row: FleetRow) => {
    const points = Number.parseInt(repair[row.index] ?? "1", 10);
    if (!Number.isFinite(points) || points <= 0) {
      showToast("shipyard.invalid_points", undefined, "bad");
      return;
    }
    void client.shipyard.repair(row.index, points);
    showToast("shipyard.repaired", {
      points,
      amount: points * row.repairCostPerPoint,
    }, "good");
  };

  const equipmentRow = (slot: "weapon" | "armor", elementId: string, id: string | undefined) => {
    const slotKey = slot === "weapon" ? "shipyard.slot.weapon" : "shipyard.slot.armor";
    return (
      <Element key={slot} screen={SCREEN} id={elementId} parent="player_equip.rows">
        <Box rect={{ x: 0, y: 0, w: 8, h: 1 }}>
          <span className="sa-cell">{tKey(slotKey)}</span>
        </Box>
        <Box rect={{ x: 8, y: 0, w: 13, h: 1 }}>
          <span className="sa-cell">{id ? t(content.equipmentName(id)) : tKey("char.none")}</span>
        </Box>
        <Box rect={{ x: 21, y: 0, w: 6, h: 1 }}>
          <Button
            textKey="shipyard.unequip"
            disabled={!id}
            fill
            onClick={() => void client.shipyard.unequip(-1, slot)}
          />
        </Box>
      </Element>
    );
  };

  const catalogRow = (row: ShipCatalogRow) => {
    const ship = content.shipType(row.shipTypeId);
    return (
      <>
        <IconBox rect={{ x: 0, y: 0, w: 3, h: 3 }} id={`hull_${row.shipTypeId}`} />
        <Box rect={{ x: 3, y: 0, w: 14, h: 1 }}>
          <span className="sa-cell">{t(content.shipName(row.shipTypeId))}</span>
        </Box>
        <Box rect={{ x: 17, y: 0, w: 10, h: 1 }}>
          <span className="sa-cell sa-label--right">{fmt("shipyard.price", { price: row.price })}</span>
        </Box>
        <Box rect={{ x: 3, y: 1, w: 24, h: 1 }}>
          <span className="sa-cell">
            {ship
              ? [
                  fmt("shipyard.durability", { durability: ship.durability }),
                  fmt("shipyard.crew_minmax", { crew: ship.crew_min, max: ship.crew_max }),
                  fmt("shipyard.capacity_stat", { capacity: ship.capacity }),
                  fmt("shipyard.speed_stat", { speed: ship.speed }),
                ].join("  ")
              : ""}
          </span>
        </Box>
        <Box rect={{ x: 3, y: 2, w: 14, h: 1 }}>
          <span className="sa-cell">{tKey(roleKey(ship?.role))}</span>
        </Box>
        <Box rect={{ x: 17, y: 2, w: 10, h: 1 }}>
          <Button
            textKey="shipyard.buy"
            kind="primary"
            disabled={!row.canBuy}
            titleKey={row.requirementKey}
            fill
            onClick={() => buy(row)}
          />
        </Box>
      </>
    );
  };

  const fleetRow = (row: FleetRow) => {
    const ship = content.shipType(row.shipTypeId);
    return (
      <>
        <Box rect={{ x: 0, y: 0, w: 27, h: 1 }}>
          <span className="sa-cell sa-label--heading">
            {fmt("fleet.ship_n", { amount: row.index + 1 })}
            {row.index === 0 ? `  ·  ${tKey("fleet.flagship")}` : ""}
          </span>
        </Box>
        <Box rect={{ x: 1, y: 1, w: 5, h: 4 }}>
          <Icon id={`hull_${row.shipTypeId}`} />
        </Box>
        <Box rect={{ x: 7, y: 1, w: 19, h: 1 }}>
          <span className="sa-cell">
            {fmt("fleet.stat.durability", { current: row.durability, max: row.maxDurability })}
          </span>
        </Box>
        <Box rect={{ x: 7, y: 2, w: 19, h: 1 }}>
          <span className="sa-cell">
            {fmt("fleet.stat.cargo", {
              used: row.cargoUsed,
              capacity: row.cargoCapacity,
              free: row.cargoFree,
            })}
          </span>
        </Box>
        <Box rect={{ x: 7, y: 3, w: 19, h: 1 }}>
          <span className="sa-cell">
            {fmt("shipyard.crew_stat", { crew: row.crew, max: row.crewMax })}
            {"  "}
            {fmt("fleet.stat.guns", { cannons: row.cannons, slots: row.slots })}
          </span>
        </Box>
        <Box rect={{ x: 1, y: 6, w: 20, h: 1 }}>
          <span className="sa-cell">{tKey(roleKey(ship?.role))}</span>
        </Box>
        <Box rect={{ x: 1, y: 8, w: 3, h: 2 }}>
          <Field
            value={repair[row.index] ?? "1"}
            onChange={(value) => setRepair((prev) => ({ ...prev, [row.index]: value }))}
            ariaLabelKey="shipyard.repair_points"
            maxLength={3}
          />
        </Box>
        <Box rect={{ x: 4, y: 9, w: 10, h: 1 }}>
          <span className="sa-cell sa-label--dim">
            {fmt("shipyard.repair_cost", {
              amount: (Number.parseInt(repair[row.index] ?? "1", 10) || 0) * row.repairCostPerPoint,
            })}
          </span>
        </Box>
        <Box rect={{ x: 14, y: 8, w: 6, h: 2 }}>
          <Button
            textKey="shipyard.repair"
            disabled={!row.canRepair}
            fill
            onClick={() => repairShip(row)}
          />
        </Box>
        <Box rect={{ x: 20, y: 8, w: 6, h: 2 }}>
          <Button
            textKey="shipyard.sell"
            kind="danger"
            disabled={!row.canSell}
            titleKey={row.canSell ? undefined : "shipyard.no_sell_flagship"}
            fill
            onClick={() => void client.shipyard.sell(row.index)}
          />
        </Box>
      </>
    );
  };

  return (
    <>
      <PanelEl screen={SCREEN} id="background" />

      <Element screen={SCREEN} id="header">
        <LabelEl
          screen={SCREEN}
          id="header.title"
          parent="header"
          textKey="shipyard.title"
          values={{ port: portName }}
          title
        />
        <LabelEl
          screen={SCREEN}
          id="header.gold"
          parent="header"
          textKey="ui.gold_amount"
          values={{ gold: state.gold }}
          align="right"
        />
        <ButtonEl
          screen={SCREEN}
          id="header.back"
          parent="header"
          textKey="ui.back"
          onClick={() => navigate("port")}
        />
      </Element>

      <PanelEl screen={SCREEN} id="catalog_panel">
        <LabelEl screen={SCREEN} id="catalog_title" parent="catalog_panel" textKey="shipyard.catalog" heading />
        <Element screen={SCREEN} id="catalog_scroll" parent="catalog_panel" className="sa-scroll">
          <ListRows screen={SCREEN} listId="catalog" count={view.catalog.length} renderRow={(i) => catalogRow(view.catalog[i])} />
        </Element>
      </PanelEl>

      <PanelEl screen={SCREEN} id="fleet_panel">
        <LabelEl screen={SCREEN} id="fleet_title" parent="fleet_panel" textKey="fleet.title" heading />
        <Element screen={SCREEN} id="player_equip" parent="fleet_panel">
          <LabelEl screen={SCREEN} id="player_equip.title" parent="player_equip" textKey="shipyard.equipment" heading />
          <Element screen={SCREEN} id="player_equip.rows" parent="player_equip">
            {equipmentRow("weapon", "equip.player.weapon", view.equipment.weapon)}
            {equipmentRow("armor", "equip.player.armor", view.equipment.armor)}
          </Element>
        </Element>
        <Element screen={SCREEN} id="fleet_scroll" parent="fleet_panel" className="sa-scroll">
          <ListRows screen={SCREEN} listId="fleet" count={view.fleet.length} renderRow={(i) => fleetRow(view.fleet[i])} />
        </Element>
      </PanelEl>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
