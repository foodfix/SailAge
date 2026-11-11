/**
 * S6 shipyard — the UW2 framed table windows (80-* §4.9.1): a toolbar row
 * (back / title / gold), the catalog window and the fleet window (each
 * ship a tall zebra row with its stats, repair controls and equipment
 * offers), plus the player-equipment summary side plate.
 *
 * The stock list, the §4.7.12 row states, prices, block reasons, repair
 * costs and the equipment offers are the server projection's
 * (`GET /api/view/shipyard`, 90-* §0.4).
 */
import { useState } from "react";
import { content, useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { EquipmentSlotRow, FleetRow, ShipCatalogRow } from "../state/views";
import type { ScreenId } from "./ids";
import { Button, Field, Frame, Icon, Row, Toast } from "../kit";
import { Label, useScreenView, useToastState, ViewFallback } from "./common";
import { navigate } from "../app/router";
import "./ShipyardScreen.css";

const SCREEN: ScreenId = "shipyard";

function roleKey(role: string | undefined): string {
  return role === "war" ? "shipyard.role.war" : role === "trade" ? "shipyard.role.trade" : "shipyard.role.coastal";
}

export function ShipyardScreen() {
  const { state } = useGameState();
  const { view, status } = useScreenView("shipyard");
  const { t, tKey, fmt } = useI18n();
  const client = useGameClient();
  const { toast, showToast, clearToast } = useToastState();
  const [repair, setRepair] = useState<Record<number, string>>({});

  if (!view) return <ViewFallback status={status} />;

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
    showToast("shipyard.repaired", { points, amount: points * row.repairCostPerPoint }, "good");
  };

  const slotFor = (slots: EquipmentSlotRow[] | undefined, slot: string, shipIndex: number) =>
    slots?.find((entry) => entry.slot === slot && entry.shipIndex === shipIndex);

  const equipmentRow = (slot: "weapon" | "armor", row: EquipmentSlotRow | undefined) => {
    const slotKey = slot === "weapon" ? "shipyard.slot.weapon" : "shipyard.slot.armor";
    return (
      <div key={slot} className="shipyard__equip">
        <div className="shipyard__slot">
          <Label textKey={slotKey} />
          <Label
            className="shipyard__slot_worn"
            textValue={row?.worn ? t(content.equipmentName(row.worn)) : tKey("char.none")}
            tone="dim"
          />
          <Button
            compact
            textKey="shipyard.unequip"
            disabled={!row?.worn}
            onClick={() => void client.shipyard.unequip(-1, slot)}
          />
        </div>
        <div className="shipyard__offers">
          {(row?.items ?? []).slice(0, 4).map((item) => (
            <Button
              key={item.equipmentId}
              compact
              text={fmt("shipyard.price", { price: item.price })}
              kind={item.canBuy ? "primary" : "default"}
              disabled={!item.canBuy}
              titleKey={item.reasonKey ?? item.noteKey}
              onClick={() => void client.shipyard.equip(-1, slot, item.equipmentId)}
            />
          ))}
        </div>
      </div>
    );
  };

  const shipEquipmentRows = (row: FleetRow) =>
    (["figurehead", "sail"] as const).map((slot) => {
      const equip = slotFor(view.equipmentSlots, slot, row.index);
      return (
        <div key={slot} className="shipyard__ship_slot">
          <div className="shipyard__ship_line">
            <Label
              className="sa-grow"
              textValue={`${tKey(slot === "figurehead" ? "shipyard.slot.figurehead" : "shipyard.slot.sail")}: ${
                equip?.worn ? t(content.equipmentName(equip.worn)) : tKey("char.none")
              }`}
              tone="dim"
            />
            <Button
              compact
              textKey="shipyard.unequip"
              disabled={!equip?.worn}
              onClick={() => void client.shipyard.unequip(row.index, slot)}
            />
          </div>
          <div className="shipyard__offers">
            {(equip?.items ?? []).slice(0, 3).map((item) => (
              <Button
                key={item.equipmentId}
                compact
                text={fmt("shipyard.price", { price: item.price })}
                kind={item.canBuy ? "primary" : "default"}
                disabled={!item.canBuy}
                titleKey={item.reasonKey ?? item.noteKey}
                onClick={() => void client.shipyard.equip(row.index, slot, item.equipmentId)}
              />
            ))}
          </div>
        </div>
      );
    });

  const catalogRow = (row: ShipCatalogRow) => {
    const ship = content.shipType(row.shipTypeId);
    const note = row.noteKey
      ? fmt(row.noteKey, row.noteValues ?? {})
      : row.requirementKey && row.requirementValues
        ? fmt(row.requirementKey, row.requirementValues)
        : undefined;
    return (
      <Row
        key={row.shipTypeId}
        height={104}
        cols={[
          <div className="shipyard__entry">
            <div className="shipyard__entry_line">
              <span className="shipyard__icon">
                <Icon id={`hull_${row.shipTypeId}`} />
              </span>
              <div className="sa-cell sa-grow">{t(content.shipName(row.shipTypeId))}</div>
              <div className="sa-cell sa-cell--right">{fmt("shipyard.price", { price: row.price })}</div>
            </div>
            <div className="sa-cell">
              {ship
                ? [
                    fmt("shipyard.durability", { durability: ship.durability }),
                    fmt("shipyard.crew_minmax", { crew: ship.crew_min, max: ship.crew_max }),
                    fmt("shipyard.capacity_stat", { capacity: ship.capacity }),
                    fmt("shipyard.speed_stat", { speed: ship.speed }),
                  ].join("  ")
                : ""}
            </div>
            <div className="shipyard__entry_line">
              <div className="sa-cell sa-grow">{note ?? tKey(roleKey(ship?.role))}</div>
              <Button
                compact
                textKey="shipyard.buy"
                kind="primary"
                disabled={!row.canBuy}
                titleKey={row.requirementKey}
                onClick={() => buy(row)}
              />
            </div>
          </div>,
        ]}
      />
    );
  };

  const fleetRow = (row: FleetRow) => {
    const ship = content.shipType(row.shipTypeId);
    return (
      <Row
        key={row.index}
        height={360}
        cols={[
          <div className="shipyard__ship">
            <div className="shipyard__ship_line">
              <span className="shipyard__icon">
                <Icon id={`hull_${row.shipTypeId}`} />
              </span>
              <div className="sa-cell sa-label--heading sa-grow">
                {`${fmt("fleet.ship_n", { amount: row.index + 1 })}${
                  row.index === 0 ? `  ·  ${tKey("fleet.flagship")}` : ""
                }`}
              </div>
            </div>
            <div className="sa-cell">
              {fmt("fleet.stat.durability", { current: row.durability, max: row.maxDurability })}
            </div>
            <div className="sa-cell">
              {fmt("fleet.stat.cargo", {
                used: row.cargoUsed,
                capacity: row.cargoCapacity,
                free: row.cargoFree,
              })}
            </div>
            <div className="sa-cell">
              {`${fmt("shipyard.crew_stat", { crew: row.crew, max: row.crewMax })}  ${fmt("fleet.stat.guns", {
                cannons: row.cannons,
                slots: row.slots,
              })}`}
            </div>
            <div className="sa-cell">{tKey(roleKey(ship?.role))}</div>
            <div className="shipyard__ship_line">
              <span className="shipyard__field">
                <Field
                  value={repair[row.index] ?? "1"}
                  onChange={(value) => setRepair((prev) => ({ ...prev, [row.index]: value }))}
                  ariaLabelKey="shipyard.repair_points"
                  maxLength={3}
                />
              </span>
              <div className="sa-cell sa-label--dim sa-grow">
                {fmt("shipyard.repair_cost", { amount: row.repairCostPerPoint })}
              </div>
              <Button
                compact
                textKey="shipyard.repair"
                disabled={!row.canRepair}
                titleKey={row.repairReasonKey}
                onClick={() => repairShip(row)}
              />
              <Button
                compact
                textKey="shipyard.sell"
                kind="danger"
                disabled={!row.canSell}
                titleKey={row.sellReasonKey ?? (row.canSell ? undefined : "shipyard.no_sell_flagship")}
                onClick={() => void client.shipyard.sell(row.index)}
              />
            </div>
            {shipEquipmentRows(row)}
          </div>,
        ]}
      />
    );
  };

  return (
    <div className="sa-screen shipyard" data-screen={SCREEN}>
      <div className="shipyard__page sa-col">
        <div className="shipyard__header sa-plate">
          <div className="shipyard__header_line">
            <Button textKey="ui.back" onClick={() => navigate("port")} />
            <Label textKey="shipyard.title" values={{ port: portName }} title />
            <div className="sa-grow" />
            <Label textKey="ui.gold_amount" values={{ gold: state.gold }} />
          </div>
        </div>

        <div className="shipyard__content sa-rowline sa-grow">
          <div className="shipyard__main sa-col">
            <Frame titleKey="shipyard.catalog" scroll className="shipyard__catalog">
              <div className="sa-table">
                {view.catalog.map((row) => catalogRow(row))}
              </div>
            </Frame>
            <Frame titleKey="fleet.title" scroll className="shipyard__fleet">
              <div className="sa-table">
                {view.fleet.map((row) => fleetRow(row))}
              </div>
            </Frame>
          </div>

          <div className="shipyard__aside sa-plate">
            <Label textKey="shipyard.equipment" heading />
            {equipmentRow("weapon", slotFor(view.equipmentSlots, "weapon", -1))}
            {equipmentRow("armor", slotFor(view.equipmentSlots, "armor", -1))}
          </div>
        </div>
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
