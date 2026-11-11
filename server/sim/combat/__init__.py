"""server.sim.combat — the sea-battle layer (M1).

Python port of ``scripts/combat/`` (the frozen parity oracle until the M6
cutover): the Phase-9 velocity-physics battle core
(:mod:`server.sim.combat.battle_sim`), the enemy composition + T2 AI
(:mod:`server.sim.combat.ai_fleet`), and the §4.12.4 aftermath steps 2/3
(:mod:`server.sim.combat.battle_result` /
:mod:`server.sim.combat.battle_rewards`).

Normative source: docs/60-COMBAT.md (§4.2–§4.7 the Phase-9 battle model,
§4.11 the pinned numbers, §4.12 the module interfaces). The T3 lookahead
(``ai_search``) and the fleet-command order generator (``fleet_commander``)
are sibling modules of the same wave and land against the interfaces this
package exposes.
"""
