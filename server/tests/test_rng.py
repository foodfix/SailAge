"""server.tests.test_rng — parity suite for ``server.sim.rng`` (M1).

Ground truth: Godot v4.7.stable.official.5b4e0cb0f, captured from live
``godot --headless --script`` SceneTree probes on 2026-11-11 (full
provenance and the ported algorithm live in ``server/sim/rng.py``).
Every assert below is a captured constant — the truth tables verbatim,
never a Monte-Carlo re-derivation (AGENTS.md test discipline).

The default-seed behaviour is intentionally NOT pinned as a sequence:
the 4.7 constructor randomizes with time entropy (verified across
processes), so unseeded instances are unreproducible by design — test 12
pins exactly that mechanism instead.
"""

from server.sim.rng import DEFAULT_SEED, PCG_DEFAULT_INC_64, GodotRng

# --- oracle truth tables: re-seed then draw (2026-11-11) -----------------

RANDI_TABLE: dict[int, list[int]] = {
    0: [881477183, 1327520283, 692503688, 2153658078, 2046399657, 3080186220],
    1: [1811587497, 683407368, 2033395789, 2375931748, 2873319489, 2189615729],
    42: [492690617, 1919685028, 3561993920, 683038915, 1183706632, 413921556],
    2147483647: [1924446889, 2323148905, 3859470875, 1474652133, 2328690204, 2449687118],
    -1: [3188254867, 2145477612, 307487198, 1603862789, 1479293180, 1654900319],
}

# Exact float64 values (the float64 widening of Godot's float32 randf;
# digits are the oracle's %.20f prints, sufficient to round-trip exactly).
RANDF_TABLE: dict[int, list[float]] = {
    0: [0.20227184891700744629, 0.12535940110683441162, 0.35858085751533508301,
        0.16886615753173828125, 0.85928440093994140625, 0.47205230593681335449],
    1: [0.32955908775329589844, 0.27659484744071960449, 0.50980961322784423828,
        0.74202167987823486328, 0.52387040853500366211, 0.04745360463857650757],
    42: [0.11837019026279449463, 0.65903240442276000977, 0.29818680882453918457,
         0.03759671002626419067, 0.75990653038024902344, 0.16013947129249572754],
    2147483647: [0.27045011520385742188, 0.84334421157836914062, 0.57036221027374267578,
                 0.30832573771476745605, 0.49203884601593017578, 0.99613565206527709961],
}

RANDI_RANGE_1_100_TABLE: dict[int, list[int]] = {
    0: [84, 84, 89, 79, 58, 21],
    1: [98, 69, 90, 49, 90, 30],
    42: [18, 29, 21, 16, 33, 57],
    2147483647: [90, 6, 76, 34, 5, 19],
}

RANDI_RANGE_0_7_TABLE: dict[int, list[int]] = {
    0: [7, 3, 0, 6],
    1: [1, 0, 5, 4],
    42: [1, 4, 0, 3],
    2147483647: [1, 1, 3, 5],
}

# --- forced-state oracle probes (state setter -> exact continuation) -----

#: seed 42 + two randi() -> state (pins LCG advancement).
STATE_AFTER_TWO_RANDI_SEED_42 = 7483708920899584422
#: Setting that state and drawing must continue with table entries 3 and 4.
STATE_42_CONTINUATION = [3561993920, 683038915]

#: seed 0: after one randf() the stream sits at raw[2] — randf advances the
#: SAME stream as randi (two steps), pinned through the shared table.
SEED0_RANDF_THEN_RANDI = [692503688, 2153658078, 2046399657]
#: Signed int64 capture of seed 0's state after one randf() (u64 >= 2^63);
#: restoring it must reproduce the stream exactly.
SEED0_STATE_AFTER_RANDF = -7412313549763278476

#: Forced proto_exp_offset == 0: state 19088743's next PCG output is 0, so
#: randf() returns 0.0 after exactly ONE stream step (live probed).
PROTO0_SET_STATE = 19088743
PROTO0_STATE_AFTER = 6292224445253897914
PROTO0_NEXT_RANDI = 4164588392

#: Forced pcg32_boundedrand_r rejection: state 1073741824's next output is
#: 8 < 96 (the threshold for bound 100), so randi_range(0, 99) rejects it
#: and draws again — two steps, return value from the second draw.
REJECTION_SET_STATE = 1073741824
REJECTION_RR_VALUE = 66
REJECTION_STATE_AFTER = 920911127595604370
REJECTION_NEXT_RANDI = 3430649783


def test_seeded_randi_sequences() -> None:
    """``.seed =`` + ``randi()`` — the captured tables, verbatim."""
    for seed, expected in RANDI_TABLE.items():
        rng = GodotRng(seed=seed)
        got = [rng.randi() for _ in range(6)]
        assert got == expected, f"seed {seed}: {got}"
        assert all(0 <= v <= 4294967295 for v in got)


def test_seeded_randf_sequences() -> None:
    """``.seed =`` + ``randf()`` — exact float64 values, bit-for-bit."""
    for seed, expected in RANDF_TABLE.items():
        rng = GodotRng(seed=seed)
        got = [rng.randf() for _ in range(6)]
        assert got == expected, f"seed {seed}: {got}"


def test_randf_bounds() -> None:
    """randf() is [0, 1) — 0.0 reachable (forced), 1.0 not (bit 31 always set)."""
    for seed in RANDF_TABLE:
        rng = GodotRng(seed=seed)
        for _ in range(6):
            assert 0.0 <= rng.randf() < 1.0


def test_seeded_randi_range_sequences() -> None:
    """``randi_range`` — modulo + threshold rejection over four seeds."""
    for seed in RANDI_TABLE:
        if seed not in RANDI_RANGE_1_100_TABLE:
            continue
        rng = GodotRng(seed=seed)
        got = [rng.randi_range(1, 100) for _ in range(6)]
        assert got == RANDI_RANGE_1_100_TABLE[seed], f"seed {seed}: {got}"
        rng = GodotRng(seed=seed)
        got = [rng.randi_range(0, 7) for _ in range(4)]
        assert got == RANDI_RANGE_0_7_TABLE[seed], f"seed {seed}: {got}"


def test_randi_range_bounds_inclusive_both_ends() -> None:
    """Both endpoints are producible: seed 0's (0, 7) table contains 7 AND 0."""
    table = RANDI_RANGE_0_7_TABLE[0]
    assert 7 in table and 0 in table


def test_equal_bounds_return_without_drawing() -> None:
    """``randi_range(0, 0)`` / ``(5, 5)`` return the bound and consume nothing."""
    rng = GodotRng(seed=7)
    before = rng.state
    assert rng.randi_range(0, 0) == 0
    assert rng.randi_range(5, 5) == 5
    assert rng.state == before
    # Same `if (p_from == p_to) return p_from;` line of random_pcg.cpp for
    # negative bounds (structural: the early return is before any draw).
    assert GodotRng(seed=0).randi_range(-1, -1) == -1
    # ...and the next real draws match the live probe for seed 7.
    assert [rng.randi_range(1, 6), rng.randi_range(1, 6)] == [6, 2]


def test_reversed_args_normalize() -> None:
    """``randi_range(99, 0)`` draws once via MIN/MAX: seed 0 -> 83."""
    rng = GodotRng(seed=0)
    assert rng.randi_range(99, 0) == 83
    # Exactly one draw: same state as seed 0 after one randi().
    assert rng.state == -675965370631573687


def test_bounded_rejection_branch() -> None:
    """Forced state exercises pcg32_boundedrand_r's threshold rejection.

    State 1073741824's next output is 8, below the bound-100 threshold
    (96): the draw is dropped, the second is accepted — two stream steps.
    """
    rng = GodotRng(seed=0)
    rng.state = REJECTION_SET_STATE
    assert rng.randi_range(0, 99) == REJECTION_RR_VALUE
    assert rng.state == REJECTION_STATE_AFTER
    assert rng.randi() == REJECTION_NEXT_RANDI


def test_randf_proto_zero_returns_exactly_zero() -> None:
    """Forced proto_exp_offset == 0: randf() == 0.0 after ONE stream step."""
    rng = GodotRng(seed=0)
    rng.state = PROTO0_SET_STATE
    assert rng.randf() == 0.0
    assert rng.state == PROTO0_STATE_AFTER
    assert rng.randi() == PROTO0_NEXT_RANDI


def test_state_pin_after_two_randi() -> None:
    """seed 42 + two randi() -> the captured state (LCG advancement pin)."""
    rng = GodotRng(seed=42)
    rng.randi()
    rng.randi()
    assert rng.state == STATE_AFTER_TWO_RANDI_SEED_42


def test_randf_and_randi_share_one_stream() -> None:
    """seed 0: one randf(), then randi values = the raw stream offset by two."""
    rng = GodotRng(seed=0)
    first = rng.randf()
    assert first == RANDF_TABLE[0][0]
    assert [rng.randi() for _ in range(3)] == SEED0_RANDF_THEN_RANDI


def test_state_get_set_round_trip() -> None:
    """state restores the stream exactly, including the signed int64 view."""
    rng = GodotRng(seed=42)
    rng.randi()
    rng.randi()
    captured = rng.state
    assert captured == STATE_AFTER_TWO_RANDI_SEED_42
    resumed = GodotRng(seed=42)
    resumed.state = captured
    assert [resumed.randi() for _ in range(2)] == STATE_42_CONTINUATION
    # Negative encodings (u64 >= 2^63) round-trip byte-identically.
    rng = GodotRng(seed=0)
    rng.state = SEED0_STATE_AFTER_RANDF
    assert rng.state == SEED0_STATE_AFTER_RANDF
    assert rng.randi() == SEED0_RANDF_THEN_RANDI[0]


def test_seed_property_round_trip() -> None:
    """Getter returns exactly what was set (int64 view); setter reseeds."""
    rng = GodotRng(seed=42)
    rng.randi()
    rng.randi()
    rng.seed = 42
    assert rng.seed == 42
    assert rng.randi() == RANDI_TABLE[42][0]
    neg = GodotRng(seed=-1)
    assert neg.seed == -1
    assert [neg.randi() for _ in range(6)] == RANDI_TABLE[-1]


def test_two_streams_do_not_interfere() -> None:
    """Interleaved streams each reproduce their solo pinned sequence."""
    a = GodotRng(seed=0)
    b = GodotRng(seed=42)
    for i in range(6):
        assert a.randi() == RANDI_TABLE[0][i]
        assert b.randi() == RANDI_TABLE[42][i]
    assert RANDI_TABLE[0] != RANDI_TABLE[42]


def test_default_constructor_randomizes() -> None:
    """The 4.7 constructor randomizes: unseeded instances differ (by design).

    No sequence is pinned here — Godot seeds it from per-process entropy
    (time-based upstream; salted-hash + object-id here). Parity suites of
    the ported systems must always seed explicitly, exactly like the
    GDScript tests do via ``set_weather_seed``/``set_mutiny_seed``.
    """
    a = GodotRng()
    b = GodotRng()
    assert a.seed != b.seed
    assert a.randi() != b.randi()


def test_upstream_constants() -> None:
    """The ported upstream constants, asserted verbatim."""
    assert PCG_DEFAULT_INC_64 == 1442695040888963407
    assert DEFAULT_SEED == 12047754176567800795
