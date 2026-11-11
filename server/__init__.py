"""SailAge server package — the web-era simulator + API (90-ARCHITECTURE.md §0).

This package is THE sim: every game rule lives here in Python under
pytest (M1), exposed through the FastAPI shell (M2) and rendered by the
web/ SPA. The Godot runtime (scenes/ scripts/ autoload/) is the frozen
parity oracle until the M6 cutover — never a dependency of this package.

Frozen numbers live in 90-ARCHITECTURE.md §0.5 (SIM_TICK_HZ = 10,
WS_BROADCAST_HZ = 10, bind 127.0.0.1:8000, SAVE_VERSION = 1, profile dir
~/.sailage/ with the SAILAGE_HOME override). Amend the doc first, then
the code — never the reverse.
"""

__version__ = "0.0.0+m0"
