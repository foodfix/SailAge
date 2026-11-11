"""server.sim.rng — bit-exact port of Godot 4.7's ``RandomNumberGenerator``.

This is the parity-critical PRNG of the whole migration: the GDScript
runtime (weather rolls, mutiny, ecology seeding, combat) seeds
``RandomNumberGenerator`` and its tests assert exact outcomes, so the M5
golden traces depend on this module reproducing Godot's byte-exact
streams. Ported from the upstream oracle sources at tag ``4.7-stable``
(core/math/random_pcg.h, core/math/random_pcg.cpp,
core/math/random_number_generator.h, thirdparty/misc/pcg.h,
thirdparty/misc/pcg.cpp) and validated against live
``godot --headless --script`` probes of the pinned toolchain
Godot v4.7.stable.official.5b4e0cb0f (truth tables captured 2026-11-11;
``server/tests/test_rng.py`` asserts those constants verbatim).

Semantics pinned against the live oracle (every claim below is exercised
by a captured constant in the test suite):

* ``seed =`` runs ``pcg32_srandom_r(initstate=seed, initseq=PCG_DEFAULT_INC_64)``
  (state = 0, inc = ``(initseq << 1) | 1``, one warm-up draw, ``+= initstate``,
  one more warm-up draw). The setter accepts any Python int and wraps to
  uint64, exactly like the GDScript int64 -> uint64 marshalling, so
  ``seed = -1`` and ``seed = 2**64 - 1`` are the same stream.
* ``randi()`` is the raw PCG32 XSH-RR output (uint32; Python int in
  ``[0, 2**32)``), one stream step per call.
* ``randi_range(a, b)`` is ``RandomPCG::random(int, int)``: equal bounds
  return immediately *without consuming a draw*; bounds are MIN/MAX
  normalised (reversed arguments draw once and land in the same span);
  ``diff == 2**32 - 1`` falls back to a raw draw; otherwise it is
  ``pcg32_boundedrand_r(diff + 1) + min`` — the threshold-rejection scheme
  (``threshold = (-bound) % bound`` in uint32, redraw while ``r < threshold``,
  then ``r % bound``). Plain modulo agrees with this except inside the
  rejection zone (e.g. for bound 100 that is ``r < 96``), which the tests
  pin through a forced state.
* ``randf()`` is RandomPCG 4.7's ``ldexp`` float scheme, two stream steps:
  draw a ``proto_exp_offset``; if it is 0 return ``0.0`` after that single
  step; else ``ldexp((float)(rand() | 0x80000001), -32 - CLZ32(proto))``.
  The ``(float)`` cast is IEEE round-to-nearest-even to a 24-bit mantissa
  (emulated here in integer arithmetic — the value always has bit 31 set,
  so its float32 granularity is exactly ``2**8``), and the ``ldexp`` is an
  exact power-of-two scaling inside float32 normal range. The result is the
  float64 widening of a float32, i.e. Godot's ``real_t`` behaviour, and it
  lies in ``[0, 1)`` (the "(inclusive)" in the upstream docs is stale for
  this implementation).
* ``state`` get/set is the raw 64-bit LCG state; the setter replaces it
  without touching ``current_seed``. Getters expose the signed int64 view
  (uint64 wrapped), matching what GDScript captures — M5 trace files store
  those numbers verbatim, and a saved negative state restores the
  identical stream.

API surface census of the GDScript runtime (``scripts/`` + ``autoload/``):
``.seed =`` (24 sites), ``randi_range(a, b)`` (36), ``.randf()`` (11),
``.state`` get/set (5 — ai_search save/restore, battle_sim duel
transcript, duel probe) — plus ``.randi()`` ported here as the primitive
underneath everything (no direct GDScript call sites). Upstream surface
NOT ported because the runtime never calls it: ``randf_range``, ``randfn``,
``rand_weighted``, and ``randomize()`` as an API (the constructor still
randomizes, mirroring upstream). The ``set_weather_seed`` /
``set_mutiny_seed`` helpers (sailing_sim.gd:787/822) are literally
``rng.seed = v`` — no extra machinery needed on this side.

Unlike Godot 3 and early 4.x, the 4.7 constructor randomizes
(``RandomNumberGenerator() { randbase.randomize(); }``) with time-based
entropy, so *unseeded instances are not reproducible* — parity suites
must seed explicitly. This port mixes CPython's per-process salted
``str`` hash with object identity for the equivalent process-unique
entropy (``rng.py`` imports nothing, per the stdlib-only rule). The
upstream ``DEFAULT_SEED`` constant is kept for structural fidelity even
though no ``RandomNumberGenerator`` path can observe it on 4.7.
"""

__all__ = ["GodotRng", "DEFAULT_SEED", "PCG_DEFAULT_INC_64"]

_MASK64 = (1 << 64) - 1
_MASK32 = (1 << 32) - 1

#: ``PCG_DEFAULT_MULT_64`` — the PCG32 LCG multiplier (pcg.cpp).
_PCG_MULT = 6364136223846793005

#: ``PCG_DEFAULT_INC_64`` — the fixed PCG sequence constant (pcg.h).
PCG_DEFAULT_INC_64 = 1442695040888963407

#: The actual LCG increment: every standard instance stores
#: ``inc = (PCG_DEFAULT_INC_64 << 1) | 1`` after seeding, and
#: ``pcg32_random_r`` ORs 1 again (a no-op) on every step.
_INC_STATE = ((PCG_DEFAULT_INC_64 << 1) | 1) & _MASK64

#: ``RandomPCG::DEFAULT_SEED`` (random_pcg.h, 4.7) — the seed a bare
#: RandomPCG holds before ``RandomNumberGenerator()`` randomizes it.
#: Unobservable through Godot's scripting API on 4.7; kept for fidelity.
DEFAULT_SEED = 12047754176567800795


def _u64(value: int) -> int:
    """Wrap any Python int to the uint64 the C++ marshalling would hold."""
    return value & _MASK64


def _i64(value: int) -> int:
    """The signed int64 view of a uint64 (GDScript ``int`` parity)."""
    value = _u64(value)
    return value - (1 << 64) if value >= (1 << 63) else value


def _i32(value: int) -> int:
    """int64 -> int32 wrap, as the GDScript-to-C++ ``int`` binding does."""
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value >= (1 << 31) else value


def _clz32(value: int) -> int:
    """Count leading zeros of a nonzero uint32 (``CLZ32``/``__builtin_clz``)."""
    return 32 - value.bit_length()


class GodotRng:
    """Bit-exact Godot 4.7 ``RandomNumberGenerator`` (RandomPCG/PCG32).

    ``GodotRng()`` mirrors the upstream constructor: it randomizes (the
    4.7 engine constructor calls ``randbase.randomize()``), so pass
    ``seed=`` — or set ``.seed`` afterwards — for a reproducible stream.
    """

    __slots__ = ("_pcg_state", "_inc", "_current_seed")

    def __init__(self, seed: int | None = None) -> None:
        self._inc = _INC_STATE
        if seed is None:
            self.randomize()
        else:
            self.seed = seed

    # -- seed property (RandomNumberGenerator::set_seed / get_seed) -------

    @property
    def seed(self) -> int:
        """The seed the current stream was started from (signed int64 view)."""
        return _i64(self._current_seed)

    @seed.setter
    def seed(self, value: int) -> None:
        self._current_seed = _u64(value)
        self._reseed(self._current_seed)

    # -- state property (RandomNumberGenerator::set_state / get_state) ----

    @property
    def state(self) -> int:
        """The raw 64-bit LCG state (signed int64 view; see module doc)."""
        return _i64(self._pcg_state)

    @state.setter
    def state(self, value: int) -> None:
        # Replaces only pcg.state; current_seed is deliberately untouched
        # (upstream set_state behaviour — a state-restored stream keeps
        # reporting the seed it was originally started from).
        self._pcg_state = _u64(value)

    # -- public draws ------------------------------------------------------

    def randomize(self) -> None:
        """Reseed from process-unique entropy (upstream ``randomize()``).

        Godot mixes wall clock + monotonic microseconds; here we mix
        CPython's per-process salted ``str`` hash with an object address
        (both unpredictable per process) — same purpose, no imports.
        """
        self.seed = hash(str(id(self))) ^ id(GodotRng)

    def randi(self) -> int:
        """One raw PCG32 XSH-RR draw, ``0 <= result < 2**32``."""
        return self._rand()

    def randi_range(self, from_: int, to_: int) -> int:
        """Uniform integer in ``[from_, to]`` — ``RandomPCG::random(int, int)``.

        Godot's binding narrows the GDScript int64 arguments to C++
        ``int`` (int32 wrap); that wrap is emulated so out-of-range
        arguments behave exactly like the runtime does.
        """
        p_from = _i32(from_)
        p_to = _i32(to_)
        if p_from == p_to:
            return p_from
        lo = min(p_from, p_to)
        hi = max(p_from, p_to)
        diff = (hi - lo) & _MASK32
        if diff == _MASK32:
            # Can't add 1 to max uint32_t for an inclusive range: raw draw.
            return self._rand() + lo
        return self._bounded(diff + 1) + lo

    def randf(self) -> float:
        """Float in ``[0, 1)`` — RandomPCG 4.7's ``ldexp`` float32 scheme.

        Two stream steps (one when the proto exponent draw is 0 and the
        result is exactly ``0.0``). The returned float is the float64
        widening of a float32, matching Godot's ``real_t``.
        """
        proto_exp_offset = self._rand()
        if proto_exp_offset == 0:
            return 0.0
        return self._float32_ldexp(self._rand() | 0x80000001, proto_exp_offset)

    # -- internals (random_pcg.h / pcg.cpp verbatim) -----------------------

    def _rand(self) -> int:
        """``pcg32_random_r`` — advance the LCG, output XSH-RR."""
        oldstate = self._pcg_state
        self._pcg_state = (_PCG_MULT * oldstate + self._inc) & _MASK64
        xorshifted = (((oldstate >> 18) ^ oldstate) >> 27) & _MASK32
        rot = (oldstate >> 59) & 31
        return ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & _MASK32

    def _bounded(self, bound: int) -> int:
        """``pcg32_boundedrand_r`` — threshold rejection, then modulo."""
        # uint32 arithmetic: threshold = (-bound) % bound == (2**32 - bound) % bound
        threshold = ((_MASK32 + 1) - bound) % bound
        while True:
            r = self._rand()
            if r >= threshold:
                return r % bound

    def _reseed(self, initstate: int) -> None:
        """``pcg32_srandom_r`` with the instance's fixed ``inc``."""
        state = 0
        state, _ = self._step(state)
        state = (state + initstate) & _MASK64
        self._pcg_state, _ = self._step(state)

    def _step(self, state: int) -> tuple[int, int]:
        """One LCG step from an explicit state (state, output) — no mutation."""
        newstate = (_PCG_MULT * state + self._inc) & _MASK64
        xorshifted = (((state >> 18) ^ state) >> 27) & _MASK32
        rot = (state >> 59) & 31
        return newstate, ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & _MASK32

    @staticmethod
    def _float32_ldexp(significand: int, proto_exp_offset: int) -> float:
        """``ldexp((float)(x | 0x80000001), -32 - CLZ32(proto))`` — exact.

        ``significand`` already has bit 31 set, so its float32 value is the
        integer rounded to a multiple of ``2**8`` (round-to-nearest-even on
        the quotient). The scaling by ``2**e`` with ``e in [-32, -63]``
        keeps a 24-bit mantissa well inside float32 normal range, so the
        whole computation is exact and the float64 result is bit-identical
        to Godot's widened ``real_t``.
        """
        quotient, remainder = divmod(significand, 256)
        if remainder > 128 or (remainder == 128 and (quotient & 1)):
            quotient += 1
        return (quotient * 256) * 2.0 ** (-32 - _clz32(proto_exp_offset))
