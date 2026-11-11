"""server.sim.world — the world-domain systems (M1).

Lands with M1, one module per Godot engine module (90-ARCHITECTURE.md §0.2):

    raster.py      the world-raster decode + lookup layer — world.png
                   passability, the harbor-pair table, the §6.5 ocean
                   rasters (wind/currents + reversal flip at lookup), the
                   §6.7 land-distance decode and the §4.18 ice-polygon
                   check (the map_loader.gd + ocean_layers.gd port).
    sailing_sim.py movement/weather/day cadence (20-*).
    sail_path.py   the two-stage A* (20-* §4.2).
    npc_fleets.py, captains.py, interactions.py, autopilot.py  (Phase 5–8).
"""
