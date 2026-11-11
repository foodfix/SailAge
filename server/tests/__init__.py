"""server.tests — pytest parity suites (M1–M2 deliverables).

M1 ports the pinned contracts of the 79 GDScript test files
(tools/test_*.gd, 67.7k lines) as pytest suites here — port the
guarantee, not the method (AGENTS.md test discipline). M2 adds the API
contract tests and the save round-trip test. Run: ``pytest server/tests``
from the repo root (pytest==9.2.0, server/requirements.txt).
M0 status: empty package.
"""
