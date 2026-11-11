"""server.sim — the ported game systems (M1 deliverable).

M1 ports every Godot-era system to Python here, one module per Godot
engine module, with pytest parity suites under server/tests porting the
pinned contracts of the 79 GDScript test files (port the guarantee, not
the method):

    world/      sailing_sim, map_loader (world.png decode), ocean_layers,
                sail_path, npc_fleets, npc_intel, captains, interactions,
                hail_options, autopilot
    port/       trade_engine, economy, allegiance, shipyard_engine,
                palace_engine
    combat/     battle_sim, ai_fleet, fleet_commander, ai_search (θ verbatim)
    quests/     quest_gen, bounty, tournament
    player/     character, skills, fame
    state.py    the GameState equivalent (90-* §5.4 field list)
    data.py     the DataLoader equivalent (data/*.json → typed dicts)

M0 status: empty package — modules land with M1.
"""
