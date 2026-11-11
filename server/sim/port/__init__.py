"""server.sim.port — the port-domain systems (M1).

Lands with M1, one module per Godot engine module under ``scripts/port/``
(90-ARCHITECTURE.md §0.2):

    trade.py        the trade engine — price formulas, tranche repricing,
                    buy/sell quantity maths, listing rule, tariff hooks
                    (trade_engine.gd + the economy.gd walk half).
    economy.py      stock state, the flow tick, demand-event rotation
                    (economy.gd — in flight, another M1 wave).
    allegiance.py   port allegiance, ledgers, permits, tariffs
                    (allegiance.gd — in flight, another M1 wave).
    shipyard.py, palace.py, inn.py, tavern.py  (later M1 waves).
"""
