"""server.save — save v1: profile dir + round-trip (M2 deliverable).

Frozen contract (90-ARCHITECTURE.md §0.5): files live under the profile
dir ~/.sailage/ (SAILAGE_HOME env override — the test seam), slots
~/.sailage/saves/save_{1..3}.json; ``save_version`` == 1 (the web era
restarts the counter) and any other version is refused — no migration
chain, the §8.2 discipline verbatim. The payload shape is the §8.1
save block (the M1-ported state) plus ``saved_at``/``phase``.
M0 status: empty shell — the implementation lands in M2.
"""
