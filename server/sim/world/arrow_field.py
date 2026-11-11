"""server.sim.world.arrow_field — the S3 wind/current arrow-field sampler (M1).

Python port of ``scripts/world/arrow_field.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract: docs/80-UI-UX.md §4.8 item 10 —
"**S3 arrow-field spec.** pure sampler ``scripts/world/arrow_field.gd``:
stride 4×4 tiles over the visible window + apron, water cells only; wind
arrow = the month's ``prevailing_for(cell, month)`` (the Phase-6 wind-region
raster, ``10-*`` §6.5); current arrow = the decoded, reversal-applied
current vector (``20-*`` §4.16) → 8-bucket per the table above; colors wind
``TEXT`` / current ``COAST_SEA`` (the sprite pins). Toggled by ``W``/``C``
keys on S3 (session-local, default off …) and re-sampled on month change."
(The oracle's docstring cites it as "§4.8.10" — the same item, numbered 10
inside §4.8 since the 2026-11-04 amendment.) The heading table is §4.8 item
6 (the ``60-*`` §4.3a bucket order); the rotation map is the 2026-11-07
top-down hull-token amendment.

Pure sampler: no nodes, no GameState, no rendering, **no RNG**. It samples
the decoded ocean layers on a world-anchored lattice over a tile window and
returns plain descriptors; the world scene owned toggles, re-sample triggers
and drawing, and the web era's canvas renderer owns them now. Ocean lookups
delegate to :class:`server.sim.world.raster.OceanLayers` (the single owner
of the §6.5 decode and the §4.16 reversal flip at lookup); this module never
decodes a raster itself.

Descriptor shape (the M4 canvas contract — one per sampled cell and kind)::

    {"cell": (x, y),       # ints, x wrapped into [0, grid_width)
     "kind": "wind" | "current",
     "dir_id": "e" | "ne" | "n" | "nw" | "w" | "sw" | "s" | "se" | "",
     "variable": bool}     # True only on a VAR wind cell ("dir_id": "")

The list is sorted by ``(y, x, kind)`` with ``"current" < "wind"`` at equal
cells (a stable, decode-deterministic order). ``dir_id`` follows §4.8 item
6: heading8 bucket 0 = east, increasing counterclockwise in the mathematical
frame (screen y-down: ``(1,−1)`` = NE, ``(0,−1)`` = N …) → the eight ids
above. The same table drives the runtime rotation of the north hull token
(``DIR_ROTATION_DEGREES``) — one source for both, so a rotation can never
disagree with a sampled arrow.

Differences from the oracle, all failure-mode only: the GDScript tested
``ocean.decode_ok`` / ``currents_decoded`` / ``currents_ok`` flags because
its loader could hand back a partially decoded object. Here
:class:`~server.sim.world.raster.OceanLayers` raises ``RasterError`` at
construction on any artifact violation (the shipped rasters are
validator-gated), so an object that exists is fully decoded and ``None`` is
the only unavailable case. The caller passes the decoded instance exactly
as it passes the loader.
"""

from __future__ import annotations

import math
from collections.abc import Callable
from typing import Final, Literal, Protocol, TypedDict

__all__ = [
    "STRIDE",
    "APRON_TILES",
    "DIR_IDS",
    "HEADING_TOKENS",
    "HEADING_RAYS",
    "DIR_ROTATION_DEGREES",
    "ArrowEntry",
    "Cell",
    "OceanSource",
    "dir_id_of_bucket",
    "bucket_of_compass",
    "dir_id_of_compass",
    "dir_id_of_heading",
    "rotation_degrees_of_dir",
    "bucket_of_vector",
    "sample",
    "floor_div",
]

#: One tile-space cell (``(x, y)``, the ``Vector2i`` the oracle used).
Cell = tuple[int, int]

#: The per-cell descriptor the canvas renderer consumes (M4 contract).
ArrowEntry = TypedDict("ArrowEntry", {
    "cell": Cell,
    "kind": Literal["wind", "current"],
    "dir_id": str,
    "variable": bool,
})


class OceanSource(Protocol):
    """The two decoded-ocean lookups the sampler reads (the Python
    :class:`~server.sim.world.raster.OceanLayers` signatures: per-axis
    integers, not ``Vector2i``)."""

    def prevailing_for(self, x: int, y: int, month: int) -> str:
        """§4.14 wind-FROM token (``N`` … ``NW`` / ``VAR``) at (x, y)."""
        ...

    def current_vector_at(self, x: int, y: int,
                          month: int = -1) -> tuple[float, float]:
        """§4.16 flow vector (unit compass × strength 1–3) at (x, y)."""
        ...


#: Lattice stride in tiles (§4.8 item 10 "stride 4×4 tiles").
STRIDE: Final[int] = 4
#: Tiles of apron beyond the visible window on every side (one stride band
#: plus one, so a step never shows the field's edge before the re-sample).
APRON_TILES: Final[int] = 8

#: §4.8 item 6 dir ids in heading8-bucket order (bucket 0 = east first).
DIR_IDS: Final[tuple[str, ...]] = ("e", "ne", "n", "nw", "w", "sw", "s", "se")
#: The compass token of each bucket — the ``20-*`` §4.4 id set in the SAME
#: bucket order (``60-*`` §4.3a ``HEADING_TOKENS``).
HEADING_TOKENS: Final[tuple[str, ...]] = (
    "E", "NE", "N", "NW", "W", "SW", "S", "SE")

#: The nearest-compass-ray dot rays, bucket order (the §4.3a integer table,
#: kept for the float-vector bucketing below).
HEADING_RAYS: Final[tuple[tuple[float, float], ...]] = (
    (1.0, 0.0), (1.0, -1.0), (0.0, -1.0), (-1.0, -1.0),
    (-1.0, 0.0), (-1.0, 1.0), (0.0, 1.0), (1.0, 1.0),
)

#: The top-down rotation map (80-* §4.8 2026-11-07 amendment, pinned):
#: dir id → clockwise degrees in screen y-down. The north hull token
#: (``hull_{ship}``, bow up) rotates to this angle to face ``dir_id``;
#: the renderer rotates with the NEAREST filter, so pixels stay crisp.
#: Unknown id → 0 (north) — callers gate on ``dir_id_of_heading`` first
#: anyway.
DIR_ROTATION_DEGREES: Final[dict[str, float]] = {
    "n": 0.0, "ne": 45.0, "e": 90.0, "se": 135.0,
    "s": 180.0, "sw": 225.0, "w": 270.0, "nw": 315.0,
}


def dir_id_of_bucket(bucket: int) -> str:
    """The dir id of a heading8 bucket ("" out of range)."""
    if bucket < 0 or bucket >= len(DIR_IDS):
        return ""
    return DIR_IDS[bucket]


def bucket_of_compass(token: str) -> int:
    """The heading8 bucket of a compass token (-1 outside the §4.4 domain)."""
    return HEADING_TOKENS.index(token) if token in HEADING_TOKENS else -1


def dir_id_of_compass(token: str) -> str:
    """The dir id of a compass token ("" outside the domain) — the §4.8
    item 6 row."""
    return dir_id_of_bucket(bucket_of_compass(token))


def dir_id_of_heading(heading: str) -> str:
    """The dir id of a persisted 8-dir heading (``world.heading`` values,
    guard-read by the caller) — "" when the heading is outside the 8-dir
    domain."""
    return dir_id_of_compass(heading.upper())


def rotation_degrees_of_dir(dir_id: str) -> float:
    """Clockwise screen rotation (degrees) that faces ``dir_id``; 0.0 for
    an unknown id (north), per :data:`DIR_ROTATION_DEGREES`."""
    return float(DIR_ROTATION_DEGREES.get(dir_id, 0.0))


def bucket_of_vector(vector: tuple[float, float]) -> int:
    """§4.3a heading8 bucket of a tile-space vector: nearest compass ray by
    the integer rule's cos² comparison (axis rays score 2·dot² to normalize
    the ray length; a positive dot required). Deterministic, never
    ``atan2``.

    Returns -1 for the zero vector (no heading — the caller skips the cell),
    mirroring ``BattleSim.heading8_of``'s "vel = (0,0) keeps the last
    heading".
    """
    if vector == (0.0, 0.0):
        return -1
    best = -1
    best_score = -1.0
    for bucket, ray in enumerate(HEADING_RAYS):
        dot = vector[0] * ray[0] + vector[1] * ray[1]
        if dot <= 0.0:
            continue
        axis = ray[0] == 0.0 or ray[1] == 0.0
        score = 2.0 * dot * dot if axis else dot * dot
        if score > best_score:
            best_score = score
            best = bucket
    return best


def sample(center_cell: Cell, view_tiles: Cell, month: int,
           ocean: OceanSource | None,
           is_water: Callable[[Cell], bool] | None,
           grid_width: int, grid_height: int) -> list[ArrowEntry]:
    """Samples the field over the window centred on ``center_cell``
    (``view_tiles`` is the viewport size in tiles).

    Entries are :data:`ArrowEntry` dicts (see the module docstring), ``cell``
    wrapped into ``[0, grid_width) × [0, grid_height)``, sorted by
    ``(y, x, kind)`` — deterministic for a fixed decode. ``ocean`` is the
    decoded :class:`~server.sim.world.raster.OceanLayers` instance (its
    lookups answer their documented defaults on any failure); ``is_water``
    is the water predicate (the loader's passability, injected to keep this
    module pure) — ``None`` samples **no** cell, exactly like the oracle's
    invalid-callable guard. ``month`` outside 1..12 samples the lookups'
    ``VAR`` fallbacks (the caller passes the real calendar month).
    """
    if grid_width <= 0 or grid_height <= 0:
        return []
    half_x = int(math.ceil(float(view_tiles[0]) * 0.5)) + APRON_TILES
    half_y = int(math.ceil(float(view_tiles[1]) * 0.5)) + APRON_TILES
    # Anchor the lattice at multiples of the stride so the sampled cells are
    # world-anchored (the same tiles re-sample wherever the camera sits).
    first_x = floor_div(center_cell[0] - half_x, STRIDE) * STRIDE
    first_y = max(
        floor_div(center_cell[1] - half_y, STRIDE) * STRIDE, 0)
    last_x = center_cell[0] + half_x
    last_y = min(center_cell[1] + half_y, grid_height - 1)
    out: list[ArrowEntry] = []
    y = first_y
    while y <= last_y:
        x = first_x
        while x <= last_x:
            cell = (x % grid_width, y)
            if is_water is not None and bool(is_water(cell)):
                _wind_entry(out, cell, month, ocean)
                _current_entry(out, cell, month, ocean)
            x += STRIDE
        y += STRIDE
    out.sort(key=lambda entry: (entry["cell"][1], entry["cell"][0],
                                entry["kind"]))
    return out


def _wind_entry(out: list[ArrowEntry], cell: Cell, month: int,
                ocean: OceanSource | None) -> None:
    """A wind descriptor: the month's ``prevailing_for`` token → dir id; a
    ``VAR`` cell carries ``variable = True`` and no dir id (the chart's
    distinctive glyph rule)."""
    if ocean is None:
        return
    token = str(ocean.prevailing_for(cell[0], cell[1], month))
    if token == "VAR":
        out.append({"cell": cell, "kind": "wind", "dir_id": "",
                    "variable": True})
        return
    dir_id = dir_id_of_compass(token)
    if not dir_id:
        return
    out.append({"cell": cell, "kind": "wind", "dir_id": dir_id,
                "variable": False})


def _current_entry(out: list[ArrowEntry], cell: Cell, month: int,
                   ocean: OceanSource | None) -> None:
    """A current descriptor: the decoded, REVERSAL-APPLIED vector bucketed
    to the §4.8 item 6 dir ids (a no-current cell contributes nothing)."""
    if ocean is None:
        return
    vector = ocean.current_vector_at(cell[0], cell[1], month)
    bucket = bucket_of_vector((float(vector[0]), float(vector[1])))
    if bucket < 0:
        return
    dir_id = dir_id_of_bucket(bucket)
    if not dir_id:
        return
    out.append({"cell": cell, "kind": "current", "dir_id": dir_id,
                "variable": False})


def floor_div(value: int, divisor: int) -> int:
    """Floor division exactly as the oracle writes it: truncate ``value /
    divisor`` toward zero, then step down once when the remainder is
    nonzero and the signs differ (the GDScript integer ``/`` + ``%`` pair).
    """
    quotient = abs(value) // abs(divisor)
    if (value < 0) != (divisor < 0):
        quotient = -quotient
    if value % divisor != 0 and ((value < 0) != (divisor < 0)):
        quotient -= 1
    return quotient
