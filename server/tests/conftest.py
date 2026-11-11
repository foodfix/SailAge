"""Pytest path bootstrap: put the repo root on sys.path.

Lets ``pytest server/tests`` resolve ``server.*`` (and ``tools.*``) imports
regardless of the invocation cwd — every M1+ parity suite relies on it.
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
