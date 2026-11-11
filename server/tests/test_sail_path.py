"""Parity tests for ``server.sim.world.sail_path`` (click-to-sail pathing).

Port of the pathing pins in the frozen GDScript harness
``tools/test_movement.gd`` (``_test_sail_path_module``,
``_test_corner_cut_impossible``, ``_test_dateline_click``) — the guarantee,
not the method: closed expectations on small hand-built grids, the pinned
seam cases, the no-corner-cut rule, and the no-path contract. The one
real-world observation block re-uses the tile coordinates pinned by the
GDScript tests with an inline passability lambda (the GDScript oracle
asserted those exact cells are open water on the shipped artifact; the
raster layer is intentionally NOT read here — the module is pure).

Run: ``pytest server/tests/test_sail_path.py -q`` from the repo root.
"""

from __future__ import annotations

import math

from server.sim.world.sail_path import (
    BUDGET_MS,
    NEAR_REGION_TILES,
    REGION_MARGIN,
    STAGE_BAD_MAP,
    STAGE_FULL,
    STAGE_NEAR,
    STAGE_NO_PATH,
    STAGE_SAME_CELL,
    WORLD_HEIGHT,
    WORLD_WIDTH,
    PathDiag,
    _full_region,
    _illegal_steps,
    find_path,
    is_step_legal,
    local_to_world,
    short_dx,
    world_to_local,
)

SQRT2 = math.sqrt(2.0)

WATER = "W"
LAND = "#"


def passable_from_rows(rows: list[str]):
    """Inject a predicate from hand-built rows (``#`` = land, else water)."""
    height = len(rows)
    width = len(rows[0])
    assert all(len(row) == width for row in rows)

    def passable(x: int, y: int) -> bool:
        return rows[y][x] != LAND

    return passable, width, height


def walk_cost(start: tuple[int, int], path: list[tuple[int, int]],
              width: int = WORLD_WIDTH) -> float:
    """Closed walk cost (start → path → goal) under the pinned model:
    straights 1.0, diagonals √2 — one expression, so comparisons against
    closed forms are exact."""
    straights = 0
    diagonals = 0
    cursor = start
    for cell in path:
        dx = abs(short_dx(cursor[0], cell[0], width))
        dy = abs(cell[1] - cursor[1])
        assert dx <= 1 and dy <= 1, f"not a unit step: {cursor} -> {cell}"
        if dx == 1 and dy == 1:
            diagonals += 1
        else:
            straights += 1
        cursor = cell
    return straights + diagonals * SQRT2


def seam_crossings(path: list[tuple[int, int]], width: int = WORLD_WIDTH,
                   ) -> int:
    """How often the path crosses x = width-1 ↔ x = 0 (either direction)."""
    crossings = 0
    for index in range(1, len(path)):
        ax, _ay = path[index - 1]
        bx, _by = path[index]
        if (ax, bx) == (width - 1, 0) or (ax, bx) == (0, width - 1):
            crossings += 1
    return crossings


def assert_legal_walk(passable, width: int, height: int, start, goal, path):
    """The oracle's corner-cut proof: every step is a legal §4.2 step."""
    assert path, "expected a path"
    assert path[0] != start, "the path excludes the start cell"
    assert path[-1] == goal, "the path ends exactly on the goal"
    cursor = start
    for step in path:
        assert is_step_legal(passable, width, height, cursor, step), (
            f"illegal step {cursor} -> {step}")
        cursor = step
    assert not _illegal_steps(passable, width, height, [start, *path])


# --- pinned constants -------------------------------------------------------

def test_locked_constants():
    """§6.1 grid constants + §4.2 architecture constants, verbatim."""
    assert WORLD_WIDTH == 4320
    assert WORLD_HEIGHT == 2160
    assert REGION_MARGIN == 24
    assert NEAR_REGION_TILES == 256
    assert BUDGET_MS == 1000.0


# --- the seam rule: short_dx -------------------------------------------------

def test_short_dx_seam_rule():
    """The GDScript pins: short way round, half-turn ties stay positive."""
    assert short_dx(2100, 50, 2160) == 110
    assert short_dx(50, 2100, 2160) == -110
    assert short_dx(0, 1080, 2160) == 1080  # ties do not flip
    # The locked width: 4200 -> 50 is the 170-tile short way (§11).
    assert short_dx(4200, 50) == 170
    assert short_dx(50, 4200) == -170
    assert short_dx(0, 2160) == 2160
    # The long way is the negative-signed remainder.
    assert short_dx(2100, 50) == -2050
    # Closed property: to == from + dx (mod width) and |dx| <= width // 2.
    for width in (16, 2160, 4320):
        for frm in range(0, width, max(1, width // 16)):
            dx = short_dx(frm, 50, width)
            assert (frm + dx) % width == 50 % width
            assert abs(dx) <= width // 2


def test_full_region_contains_half_turn_targets():
    """The half-turn edge stays inside the region (an off-by-one there would
    strand exactly the half-turn queries) — the GDScript pins."""
    half = _full_region(2160, 1080, 1080)
    assert half == (-1079, 0, 2160, 1080)
    assert half[0] <= 0 <= half[0] + half[2] - 1  # the fleet (local x = 0)
    assert half[0] <= 1080 <= half[0] + half[2] - 1  # the half-turn target
    wrapped = _full_region(2160, 1080, -1080)
    assert wrapped == (-1080, 0, 2160, 1080)
    assert wrapped[0] <= -1080 <= wrapped[0] + wrapped[2] - 1
    # The locked width: dx = ±2160 both land inside after the one-tile nudge.
    east = _full_region(WORLD_WIDTH, WORLD_HEIGHT, 2160)
    assert east == (-2159, 0, 4320, 2160)
    assert east[0] <= 0 and east[0] + east[2] - 1 >= 2160
    west = _full_region(WORLD_WIDTH, WORLD_HEIGHT, -2160)
    assert west == (-2160, 0, 4320, 2160)
    assert west[0] <= -2160 <= west[0] + west[2] - 1


def test_local_frame_round_trip():
    """local_to_world / world_to_local invert across the seam (GDScript pin)."""
    assert local_to_world((2100, 7), (60, 7), 2160) == (0, 7)
    assert world_to_local((2100, 7), (0, 7), 2160) == (60, 7)
    for world_cell in ((50, 8), (0, 3), (2159, 9), (2101, 100)):
        local = world_to_local((2100, 0), world_cell, 2160)
        assert local_to_world((2100, 0), local, 2160) == world_cell


# --- is_step_legal: the §4.2 single-step rule ---------------------------------

def test_is_step_legal_eight_directions_and_bounds():
    passable = lambda x, y: True  # noqa: E731 — open water everywhere
    w, h = WORLD_WIDTH, WORLD_HEIGHT
    for step in ((1, 0), (-1, 0), (0, 1), (0, -1),
                 (1, 1), (1, -1), (-1, 1), (-1, -1)):
        assert is_step_legal(passable, w, h, (100, 100),
                             (100 + step[0], 100 + step[1]))
    assert not is_step_legal(passable, w, h, (100, 100), (100, 100))
    assert not is_step_legal(passable, w, h, (100, 100), (102, 100))
    assert not is_step_legal(passable, w, h, (100, 100), (100, 98))
    assert not is_step_legal(passable, w, h, (100, 100), (100, -1))
    assert not is_step_legal(passable, w, h, (100, 100), (100, h))
    # Wrap-aware seam steps are legal single steps (§9).
    assert is_step_legal(passable, w, h, (0, 500), (w - 1, 500))
    assert is_step_legal(passable, w, h, (w - 1, 500), (0, 500))


def test_is_step_legal_rejects_corner_cut():
    """The real corner on the shipped artifact (GDScript CORNER_FROM/TO):
    (693,636) -> (692,635) diagonal with (692,636) water but (693,635) land.
    Mirrored inline; the validator also flags a doctored path using it."""
    def corner_map(x: int, y: int) -> bool:
        return not (x == 693 and y == 635)

    w, h = WORLD_WIDTH, WORLD_HEIGHT
    assert corner_map(692, 636)  # the one existing orthogonal
    assert not corner_map(693, 635)  # the missing one
    assert not is_step_legal(corner_map, w, h, (693, 636), (692, 635))
    assert not is_step_legal(corner_map, w, h, (692, 635), (693, 636))
    # The straight route through (692,636) is legal.
    assert is_step_legal(corner_map, w, h, (693, 636), (692, 636))
    assert is_step_legal(corner_map, w, h, (692, 636), (692, 635))
    # The doctored two-cell path cannot leave the validator (GDScript pin).
    assert _illegal_steps(corner_map, w, h, [(693, 636), (692, 635)])
    assert not _illegal_steps(corner_map, w, h,
                              [(693, 636), (692, 636), (692, 635)])


# --- open-water closed shapes -------------------------------------------------

def test_open_water_diagonal_shortest_path_closed_shape():
    """All-water 12×12, |dx| ≤ width//2 so the short way does not flip:
    (3,3) -> (9,9) is exactly the main diagonal, cost 6√2."""
    passable, width, height = passable_from_rows([WATER * 12] * 12)
    path = find_path(passable, width, height, (3, 3), (9, 9))
    assert path == [(i, i) for i in range(4, 10)]
    assert walk_cost((3, 3), path, width) == 6 * SQRT2
    assert_legal_walk(passable, width, height, (3, 3), (9, 9), path)


def test_open_water_straight_row_closed_shape():
    """16-wide row, dx = width//2 exactly (ties do not flip): the closed
    route is the 8-step eastward straight row."""
    passable, width, height = passable_from_rows([WATER * 16] * 3)
    path = find_path(passable, width, height, (3, 1), (11, 1))
    assert path == [(x, 1) for x in range(4, 12)]
    assert walk_cost((3, 1), path, width) == 8.0
    assert_legal_walk(passable, width, height, (3, 1), (11, 1), path)


def test_open_water_near_click_real_coordinates():
    """The GDScript near click: OPEN_CELL (1400,640) -> +(9,6) — the
    regional stage answers it and the path ends exactly on the clicked
    tile. The shipped artifact's variables band around these cells is open
    water (the oracle asserted a legal walk and stage near); mirrored
    inline as the injected predicate."""
    passable = lambda x, y: True  # noqa: E731
    diag = PathDiag()
    path = find_path(passable, WORLD_WIDTH, WORLD_HEIGHT,
                     (1400, 640), (1409, 646), diag=diag)
    assert diag.stage == STAGE_NEAR
    assert diag.region == (-24, 616, 58, 55)
    assert len(path) == 9  # Chebyshev max(9, 6)
    assert path[-1] == (1409, 646)
    assert walk_cost((1400, 640), path) == 3 + 6 * SQRT2  # 3 straights + 6 diagonals
    assert_legal_walk(passable, WORLD_WIDTH, WORLD_HEIGHT,
                      (1400, 640), (1409, 646), path)


def test_margin_option_shapes_the_near_region():
    """opts.margin exists for the tests (GDScript parity)."""
    passable = lambda x, y: True  # noqa: E731
    diag = PathDiag()
    path = find_path(passable, WORLD_WIDTH, WORLD_HEIGHT,
                     (1400, 640), (1409, 646), margin=0, diag=diag)
    assert diag.stage == STAGE_NEAR
    assert diag.region == (0, 640, 10, 7)
    assert len(path) == 9 and path[-1] == (1409, 646)


# --- wall gaps and corner forcing ---------------------------------------------

def test_wall_with_gap_routes_through_the_gap():
    """Column x=4 is land everywhere except the gap at y=2: the route is
    the straight row through the gap (closed shape)."""
    rows = [
        WATER * 4 + LAND + WATER * 4,
        WATER * 4 + LAND + WATER * 4,
        WATER * 9,
        WATER * 4 + LAND + WATER * 4,
        WATER * 4 + LAND + WATER * 4,
    ]
    passable, width, height = passable_from_rows(rows)
    path = find_path(passable, width, height, (2, 2), (6, 2))
    assert path == [(3, 2), (4, 2), (5, 2), (6, 2)]
    assert walk_cost((2, 2), path, width) == 4.0
    assert_legal_walk(passable, width, height, (2, 2), (6, 2), path)


def test_corner_cut_is_never_taken():
    """The classic single-corner fixture: the diagonal shortcut is blocked
    (one orthogonal is land), the route takes two straights instead."""
    rows = [
        "..",  # (0,0) water, (1,0) goal
        ".#",  # (0,1) start, (1,1) land
    ]
    passable, width, height = passable_from_rows(rows)
    path = find_path(passable, width, height, (0, 1), (1, 0))
    assert path == [(0, 0), (1, 0)]
    assert walk_cost((0, 1), path, width) == 2.0
    assert_legal_walk(passable, width, height, (0, 1), (1, 0), path)


def test_corner_cut_wide_fixture_takes_the_long_leg():
    """Width 9 so the short way cannot flip across the seam: (1,1) land
    blocks both diagonals; the route takes three straights."""
    rows = [
        WATER * 9,
        WATER + LAND + WATER * 7,
    ]
    passable, width, height = passable_from_rows(rows)
    path = find_path(passable, width, height, (0, 0), (2, 1))
    assert path == [(1, 0), (2, 0), (2, 1)]
    assert walk_cost((0, 0), path, width) == 3.0
    assert_legal_walk(passable, width, height, (0, 0), (2, 1), path)


def test_legal_diagonal_next_to_a_wall_is_taken():
    """With both orthogonals open the diagonal IS taken (cost 1 + √2 beats
    two straights) even though a land cell sits one tile away."""
    rows = [
        LAND + WATER * 8,
        WATER * 9,
        WATER * 9,
    ]
    passable, width, height = passable_from_rows(rows)
    path = find_path(passable, width, height, (0, 1), (2, 2))
    assert len(path) == 2
    assert path[-1] == (2, 2)
    assert walk_cost((0, 1), path, width) == 1.0 + SQRT2
    diagonals = 0
    cursor = (0, 1)
    for step in path:
        dx = abs(short_dx(cursor[0], step[0], width))
        dy = abs(step[1] - cursor[1])
        if dx == 1 and dy == 1:
            diagonals += 1
            assert is_step_legal(passable, width, height, cursor, step)
        cursor = step
    assert diagonals == 1
    assert_legal_walk(passable, width, height, (0, 1), (2, 2), path)


def test_real_corner_coordinates_route_around_without_cutting():
    """The real corner fixture searched for a path: the goal is the diagonal
    step that must NOT be taken ((693,635) is land); the route goes round
    through (692,636) instead — closed shape."""
    def corner_map(x: int, y: int) -> bool:
        return not (x == 693 and y == 635)

    path = find_path(corner_map, WORLD_WIDTH, WORLD_HEIGHT,
                     (693, 636), (692, 635))
    assert path == [(692, 636), (692, 635)]
    assert walk_cost((693, 636), path) == 2.0
    assert_legal_walk(corner_map, WORLD_WIDTH, WORLD_HEIGHT,
                      (693, 636), (692, 635), path)


# --- longitude wrap ------------------------------------------------------------

def test_seam_short_way_synthetic():
    """16-wide world, land wall at x=8: from (14,2) to (2,2) the westward
    band is walled off, so the short way is the 4-step eastward route
    crossing the 15 -> 0 seam exactly once."""
    rows = [WATER * 8 + LAND + WATER * 7 for _ in range(5)]
    passable, width, height = passable_from_rows(rows)
    diag = PathDiag()
    path = find_path(passable, width, height, (14, 2), (2, 2), diag=diag)
    assert diag.stage == STAGE_NEAR
    assert path == [(15, 2), (0, 2), (1, 2), (2, 2)]
    assert seam_crossings(path, width) == 1
    assert walk_cost((14, 2), path, width) == 4.0
    assert_legal_walk(passable, width, height, (14, 2), (2, 2), path)


def test_half_turn_query_is_answered():
    """dx = width/2 exactly: ties do not flip — the target sits at the
    positive half-turn offset and the closed route is the 8-step straight
    row to it (the region only contains the fleet mid-ring, so the search
    answers in-frame; the goal cell sits mid-row, no seam crossing)."""
    passable = lambda x, y: True  # noqa: E731
    width, height = 16, 5
    diag = PathDiag()
    path = find_path(passable, width, height, (2, 2), (10, 2), diag=diag)
    assert diag.stage == STAGE_NEAR
    assert path == [(x, 2) for x in range(3, 11)]
    assert walk_cost((2, 2), path, width) == 8.0
    assert seam_crossings(path, width) == 0


# --- the pinned real-world dateline cases ---------------------------------------

def test_dateline_click_short_way_oracle_case():
    """The §11 edge case, verbatim coordinates from tools/test_movement.gd:
    fleet at x = 4200 clicking x = 50 — |Δx| = 4,150 > 2,160, so the short
    way is the 170-step route across the 4319 -> 0 seam, never the 4,150-
    step way round. The Pacific band at these cells is open water on the
    shipped artifact (the oracle asserted both endpoints passable and a
    fully legal walk); mirrored inline as the injected predicate."""
    passable = lambda x, y: True  # noqa: E731
    diag = PathDiag()
    path = find_path(passable, WORLD_WIDTH, WORLD_HEIGHT,
                     (4200, 500), (50, 500), diag=diag)
    assert diag.stage == STAGE_NEAR
    assert len(path) == 170
    assert path[0] == (4201, 500)
    assert path[-1] == (50, 500)
    assert seam_crossings(path) == 1
    assert (4319, 500) in path and (0, 500) in path
    assert walk_cost((4200, 500), path) == 170.0
    assert_legal_walk(passable, WORLD_WIDTH, WORLD_HEIGHT,
                      (4200, 500), (50, 500), path)


def test_dateline_click_mirror_eastward():
    """The mirrored pinned case: fleet at x = 50 clicking x = 4200 is the
    short −170, crossing 0 -> 4319 exactly once."""
    passable = lambda x, y: True  # noqa: E731
    path = find_path(passable, WORLD_WIDTH, WORLD_HEIGHT,
                     (50, 500), (4200, 500))
    assert len(path) == 170
    assert path[0] == (49, 500)
    assert path[-1] == (4200, 500)
    assert seam_crossings(path) == 1
    assert (0, 500) in path and (4319, 500) in path
    assert_legal_walk(passable, WORLD_WIDTH, WORLD_HEIGHT,
                      (50, 500), (4200, 500), path)


def test_dateline_same_row_across_the_seam():
    """A target on the same row directly across the seam: (4315,500) ->
    (5,500) is exactly the 10-step straight row with one crossing."""
    passable = lambda x, y: True  # noqa: E731
    path = find_path(passable, WORLD_WIDTH, WORLD_HEIGHT,
                     (4315, 500), (5, 500))
    assert path == [(4316, 500), (4317, 500), (4318, 500), (4319, 500),
                    (0, 500), (1, 500), (2, 500), (3, 500), (4, 500),
                    (5, 500)]
    assert seam_crossings(path) == 1


# --- the two-stage architecture --------------------------------------------------

def test_full_region_stage_when_near_disabled():
    """opts.near_tiles = 0 skips the near stage: the full-region query
    answers the same closed route and tags full_region."""
    passable = lambda x, y: True  # noqa: E731
    width, height = 64, 8
    diag = PathDiag()
    path = find_path(passable, width, height, (4, 4), (20, 4),
                     near_tiles=0, diag=diag)
    assert diag.stage == STAGE_FULL
    assert path == [(x, 4) for x in range(5, 21)]
    assert walk_cost((4, 4), path, width) == 16.0


def test_full_region_half_turn_nudged_region():
    """dx = width/2 with the near stage off: the nudged full region answers
    the half-turn query with the in-frame 32-step straight row (the ring's
    cut edge makes the opposite direction unreachable in-frame)."""
    passable = lambda x, y: True  # noqa: E731
    width, height = 64, 8
    diag = PathDiag()
    path = find_path(passable, width, height, (0, 2), (32, 2),
                     near_tiles=0, diag=diag)
    assert diag.stage == STAGE_FULL
    assert path == [(x, 2) for x in range(1, 33)]
    assert walk_cost((0, 2), path, width) == 32.0


def test_near_failure_falls_through_to_full_region():
    """A water click the near box cannot answer: the land band (full near-
    region height) blocks both stub corridors inside the near region; the
    route detours ABOVE the band — outside the near box, inside the full
    frame. Closed length: 24 + 1 + 25 + 70 + 25 + 25 = 170 steps, tagged
    full_region (never a silent no_path)."""
    band_x = range(126, 195)
    band_y = range(26, 75)

    def passable(x: int, y: int) -> bool:
        if x in band_x and y in band_y:
            # Two dead-end stub corridors: start-side (126..150, 50) and
            # goal-side (170..194, 50); the rest of the band is land.
            return y == 50 and (126 <= x <= 150 or 170 <= x <= 194)
        return True

    width, height = 300, 100
    diag = PathDiag()
    path = find_path(passable, width, height, (150, 50), (170, 50), diag=diag)
    assert diag.stage == STAGE_FULL
    assert len(path) == 170
    assert path[-1] == (170, 50)
    assert_legal_walk(passable, width, height, (150, 50), (170, 50), path)


# --- the no-path contract ---------------------------------------------------------

def test_split_basin_unreachable_returns_empty_no_path():
    """The GDScript synthetic: 16×5, water split into two basins by land
    columns at x = 0 and x = 8 (the wrap 15 -> 0 cannot join them) —
    a legal water click with no route returns [] and reports no_path."""
    rows = [LAND + WATER * 7 + LAND + WATER * 7 for _ in range(5)]
    passable, width, height = passable_from_rows(rows)
    diag = PathDiag()
    assert find_path(passable, width, height, (2, 2), (13, 2),
                     diag=diag) == []
    assert diag.stage == STAGE_NO_PATH


def test_impassable_and_offgrid_endpoints_return_empty():
    blocked = {(6, 6)}

    def passable(x: int, y: int) -> bool:
        return (x, y) not in blocked

    width, height = 32, 32
    diag = PathDiag()
    assert find_path(passable, width, height, (5, 5), (6, 6),
                     diag=diag) == []  # a click on land
    assert diag.stage == STAGE_NO_PATH
    assert find_path(passable, width, height, (6, 6), (7, 6)) == []
    assert find_path(passable, width, height, (5, 5), (5, -1)) == []
    assert find_path(passable, width, height, (5, 5), (5, height)) == []


def test_walled_pocket_unreachable():
    rows = [
        ".....",
        ".###.",
        ".#.#.",
        ".###.",
        ".....",
    ]
    passable, width, height = passable_from_rows(rows)
    diag = PathDiag()
    assert find_path(passable, width, height, (2, 2), (0, 0),
                     diag=diag) == []
    assert diag.stage == STAGE_NO_PATH


def test_same_cell_returns_empty():
    passable = lambda x, y: True  # noqa: E731
    diag = PathDiag()
    assert find_path(passable, WORLD_WIDTH, WORLD_HEIGHT, (5, 5), (5, 5),
                     diag=diag) == []
    assert diag.stage == STAGE_SAME_CELL
    # The same cell after wrapping is still the same cell.
    assert find_path(passable, WORLD_WIDTH, WORLD_HEIGHT,
                     (0, 5), (WORLD_WIDTH, 5)) == []


def test_degenerate_map_returns_empty():
    passable = lambda x, y: True  # noqa: E731
    diag = PathDiag()
    assert find_path(passable, 0, 10, (0, 0), (1, 0), diag=diag) == []
    assert diag.stage == STAGE_BAD_MAP
    assert find_path(passable, 10, 0, (0, 0), (1, 0)) == []
    assert find_path(passable, -4, 10, (0, 0), (1, 0)) == []


# --- purity ------------------------------------------------------------------------

def test_find_path_is_deterministic_and_mutation_free():
    """find_path is pure logic: no fixture mutation, no drift between calls
    (the GDScript pin: it never moves the fleet or touches the clock).
    Fixture: (1,1) land blocks every diagonal between (0,0) and (2,2), so
    the optimum is four straights at cost 4.0 (shape-tied, cost-closed)."""
    rows = [
        WATER * 9,
        WATER + LAND + WATER * 7,
        WATER * 9,
    ]
    passable, width, height = passable_from_rows(rows)
    snapshot = tuple(rows)
    first = find_path(passable, width, height, (0, 0), (2, 2))
    second = find_path(passable, width, height, (0, 0), (2, 2))
    assert first == second
    assert snapshot == tuple(rows)
    assert walk_cost((0, 0), first, width) == 4.0
