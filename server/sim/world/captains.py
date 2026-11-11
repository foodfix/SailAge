"""server.sim.world.captains — the named-captain canon layer (M1).

Python port of ``scripts/world/captains.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:

  * docs/60-COMBAT.md §4.11.15 + §4.11.11.4 — the lifecycle machine
    ``active → defeated → returning(return_day = day + 60) → active``
    (captains never die), the tier drift (−1 crushed defeat / +1 captain
    win, clamp 1–3), the nemesis rule (a pirate/privateer returning at
    ``stance ≤ −3`` comes back as a nemesis hunter) and the stance/familiarity
    deltas shared with the hail and the battle hooks;
  * docs/10-DATA-SCHEMA.md §4.11 — the closed canon ``data/captains.json``
    (save-independent, read-only) and §4.15 — the ``captain_states`` save
    shape (exactly the 8 keys; full entries **only for met captains**);
  * docs/90-ARCHITECTURE.md §0/§5.4 — pure logic, no scene code.

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics read/mutate ``GameState.captain_states``; here that dict
is injected as the first argument of every stateful function. Reads of an
unmet captain return throwaway defaults and create nothing — :func:`ensure`
is the only creator. The ``deployed`` bookkeeping key is a **runtime-only
extra** beyond the §4.15 shape and must never be persisted
(:func:`release` / :func:`reset_deployments` erase it again so an idle
entry matches the save shape exactly).

Seeded determinism: **no RNG anywhere** — ``speed_jitter`` and every other
value is a pure function of ids and day (verified at port time by grep;
the GDScript header pins the same).

Cross-module seams (callers, not owned here):
  * ``server.sim.world.npc_fleets`` (the ecology port, other ownership)
    calls :func:`deploy` / :func:`release` / :func:`is_spawnable` /
    :func:`day_tick` / :func:`is_nemesis` / :func:`speed_jitter`;
  * the battle-rewards port applies :func:`defeat` / :func:`win` /
    :func:`adjust_stance` at its aftermath seams;
  * the tavern/inn facility engines (already landed) funnel their port-side
    交好 befriend / 受限谈话 through :func:`adjust_stance` /
    :func:`add_familiarity` with the shared :data:`STANCE_BEFRIEND` — their
    once-per-visit guard bookkeeping stays theirs (the deferral notes in
    ``server/sim/port/tavern.py`` / ``inn.py`` point here).
"""

from __future__ import annotations

from typing import Any, Final

from server.sim.data import DataStore

__all__ = [
    "RETURN_QUEUE_DAYS",
    "STATUS_ACTIVE",
    "STATUS_DEFEATED",
    "STATUS_RETURNING",
    "TIER_MIN",
    "TIER_MAX",
    "STANCE_MIN",
    "STANCE_MAX",
    "STANCE_BEFRIEND",
    "STANCE_INTIMIDATE_WIN",
    "STANCE_INTIMIDATE_FAIL",
    "STANCE_NEMESIS_DEFEAT",
    "STANCE_ATTACK_NONHOSTILE",
    "NEMESIS_STANCE",
    "NEMESIS_ROLES",
    "FAMILIARITY_MIN",
    "FAMILIARITY_MAX",
    "FAMILIARITY_TIERS",
    "SPEED_JITTER_MAX",
    "captain",
    "canon_list",
    "state",
    "ensure",
    "deploy",
    "release",
    "reset_deployments",
    "is_deployed",
    "defeat",
    "win",
    "day_tick",
    "is_spawnable",
    "is_nemesis",
    "stance",
    "adjust_stance",
    "familiarity",
    "add_familiarity",
    "familiarity_tier",
    "dossier_seen",
    "mark_dossier_seen",
    "speed_jitter",
]

# --- Lifecycle constants (docs/60-* §4.11.15, locked) ------------------------

#: The return queue: a defeated captain comes back ``day + 60``.
RETURN_QUEUE_DAYS: Final[int] = 60

#: Status values (docs/10-* §4.15). The module's machine parks on
#: ``returning`` only — ``defeated`` is the instantaneous pre-booking reading
#: at the removal funnel, never a stored resting state.
STATUS_ACTIVE: Final[str] = "active"
STATUS_DEFEATED: Final[str] = "defeated"
STATUS_RETURNING: Final[str] = "returning"

#: Tier drift bounds (clamp 1–3; −1 crushed defeat / +1 captain win).
TIER_MIN: Final[int] = 1
TIER_MAX: Final[int] = 3

# --- Stance constants (docs/60-* §4.11.15; the deltas the hail and the
# --- battle hooks share — pin consumers to these, never literals) ------------

#: Stance scale: −10 … +10, starts 0.
STANCE_MIN: Final[int] = -10
STANCE_MAX: Final[int] = 10

#: Hail → befriend: +1 (once per captain per day).
STANCE_BEFRIEND: Final[int] = 1

#: Player wins an intimidation attempt against this captain: −1.
STANCE_INTIMIDATE_WIN: Final[int] = -1

#: Player's intimidation failed: −2.
STANCE_INTIMIDATE_FAIL: Final[int] = -2

#: The PLAYER defeats a nemesis captain (stance ≤ −3): the grudge deepens
#: even in death/retreat — the battle hooks apply this EXTRA shift on top of
#: nothing else. Piracy fame/reputation funnels stay with their owners; this
#: is personal.
STANCE_NEMESIS_DEFEAT: Final[int] = -2

#: Piracy: attacking a non-hostile fleet (the −20 rep/fame funnel is the
#: battle hooks'/hail's; this is the captain's personal grudge).
STANCE_ATTACK_NONHOSTILE: Final[int] = -1

#: A pirate/privateer at stance ≤ −3 returns as a nemesis hunter.
NEMESIS_STANCE: Final[int] = -3

#: The roles that can become nemeses (docs/60-* §4.11.15).
NEMESIS_ROLES: Final[tuple[str, ...]] = ("pirate", "privateer")

# --- Familiarity constants (docs/80-* dossier §4.11.3) -----------------------

FAMILIARITY_MIN: Final[int] = 0
FAMILIARITY_MAX: Final[int] = 99

#: Career-log unlock thresholds: tier 1 at ≥ 3, tier 2 at ≥ 6, tier 3 at ≥ 10.
FAMILIARITY_TIERS: Final[tuple[int, ...]] = (3, 6, 10)

# --- Speed jitter (docs/60-* §4.11.15: a fleet's ±10% captain speed cap) -----

#: ``speed_jitter(id)`` ∈ [−0.10, +0.10], quantized to 1/1000 steps over an
#: odd 201-bucket ladder (symmetric, ends inclusive) — a stable hash of the
#: captain id so a fleet's jitter is reproducible without RNG state.
SPEED_JITTER_MAX: Final[float] = 0.10
_JITTER_STEPS: Final[int] = 201


# --- Canon access (docs/10-* §4.11) ------------------------------------------

def captain(store: DataStore, id: str) -> dict[str, Any]:
    """A canon card by id (read-only). ``{}`` when unknown."""
    return store.get_captain(id)


def canon_list(store: DataStore) -> list[Any]:
    """The whole closed roster (the loaded ``captains`` list, read-only)."""
    return store.captains_list


# --- State (docs/10-* §4.15) --------------------------------------------------

def _default_state(canon: dict[str, Any]) -> dict[str, Any]:
    """The §4.15 defaults for ``captain_states[id]`` — exactly the 8 save
    keys, ``tier_now`` seeded from the canon card (1 when the card is
    unknown). A fresh dict every call: mutating the returned default of an
    unmet captain must never affect anything."""
    return {
        "status": STATUS_ACTIVE,
        "return_day": 0,
        "tier_now": max(TIER_MIN, min(int(canon.get("tier", TIER_MIN)),
                                      TIER_MAX)),
        "stance": 0,
        "familiarity": 0,
        "dossier_seen": False,
        "defeats": 0,
        "wins": 0,
    }


def state(captain_states: dict[str, Any], store: DataStore,
          id: str) -> dict[str, Any]:
    """The captain's run state. A met captain's LIVE entry is returned
    (mutate it freely — it is the stored dict); an unmet captain's defaults
    are a throwaway copy, and nothing is created by a read (full entries
    exist only for met captains, docs/10-* §4.15)."""
    entry = captain_states.get(id)
    if isinstance(entry, dict):
        return entry
    return _default_state(store.get_captain(id))


def ensure(captain_states: dict[str, Any], store: DataStore,
           id: str) -> dict[str, Any]:
    """Creates the state entry on first touch (idempotent) and returns it."""
    entry = captain_states.get(id)
    if not isinstance(entry, dict):
        entry = _default_state(store.get_captain(id))
        captain_states[id] = entry
    return entry


# --- Deployment bookkeeping (runtime-only; never persisted) ------------------

def deploy(captain_states: dict[str, Any], store: DataStore, id: str) -> None:
    """Marks the captain as sailing on exactly one live fleet (the ecology's
    spawn draw calls this). Creates the entry lazily — the ``deployed`` flag
    is the runtime-only extra key beyond the §4.15 save shape."""
    ensure(captain_states, store, id)["deployed"] = True


def release(captain_states: dict[str, Any], id: str) -> None:
    """Clears the deployment flag (a fleet gone without a player defeat —
    budget shrink, any non-battle removal): the captain is immediately
    spawnable again. Erases the key so an idle entry matches the save shape
    exactly; an untouched captain is a no-op (no phantom entry)."""
    entry = captain_states.get(id)
    if isinstance(entry, dict):
        entry.pop("deployed", None)


def reset_deployments(captain_states: dict[str, Any]) -> None:
    """Per-run transient reset (the ecology's contract: ``initial_fill`` and
    the suites call it on a fresh sim — the deployment set is runtime-only
    and a new run re-deploys from scratch). Erases every ``deployed`` flag;
    touches nothing else (statuses/stance/familiarity survive — only a
    new_game resets those)."""
    for entry in captain_states.values():
        if isinstance(entry, dict):
            entry.pop("deployed", None)


def _state_no_store(captain_states: dict[str, Any], id: str) -> dict[str, Any]:
    """The state read where no canon lookup is needed. Equivalent to
    :func:`state` for every field it reads (stance/familiarity/dossier/
    deployed all default on an unmet captain) without touching the store."""
    entry = captain_states.get(id)
    return entry if isinstance(entry, dict) else {}


def is_deployed(captain_states: dict[str, Any], id: str) -> bool:
    return bool(_state_no_store(captain_states, id).get("deployed", False))


# --- Lifecycle (docs/60-* §4.11.15: the return queue + tier drift) -----------

def defeat(captain_states: dict[str, Any], store: DataStore, id: str,
           day: int, crushed: bool = False) -> dict[str, Any]:
    """A defeat at the removal funnel: onto the return queue
    (``return_day = day + 60``), the defeat counter climbs, the deployment
    clears (the fleet is gone), and a crushing defeat drifts the tier −1
    (clamp 1–3). Returns the updated state."""
    st = ensure(captain_states, store, id)
    st["status"] = STATUS_RETURNING
    st["return_day"] = int(day) + RETURN_QUEUE_DAYS
    st["defeats"] = int(st.get("defeats", 0)) + 1
    st["deployed"] = False
    if crushed:
        st["tier_now"] = max(TIER_MIN, min(
            int(st.get("tier_now", TIER_MIN)) - 1, TIER_MAX))
    return st


def win(captain_states: dict[str, Any], store: DataStore, id: str,
        day: int) -> dict[str, Any]:
    """The captain's WIN against the player (an AI victory at the funnel):
    the win counter climbs and the tier drifts +1 (clamp 1–3). ``day`` is
    accepted for seam parity with the battle hooks' call signature (the
    oracle ignores it too)."""
    st = ensure(captain_states, store, id)
    st["wins"] = int(st.get("wins", 0)) + 1
    st["tier_now"] = max(TIER_MIN, min(
        int(st.get("tier_now", TIER_MIN)) + 1, TIER_MAX))
    return st


def day_tick(captain_states: dict[str, Any], day: int) -> None:
    """The daily walk over the return queue: every ``returning`` captain
    whose day has come returns to ``active`` under its own name (the roster
    is closed — names are never reused; the drifted tier keeps its value).
    Pure bookkeeping — spawning stays the ecology port's."""
    for entry in captain_states.values():
        if not isinstance(entry, dict):
            continue
        if str(entry.get("status", "")) == STATUS_RETURNING \
                and int(day) >= int(entry.get("return_day", 0)):
            entry["status"] = STATUS_ACTIVE
            entry["return_day"] = 0


def is_spawnable(captain_states: dict[str, Any], store: DataStore, id: str,
                 day: int) -> bool:
    """Spawn eligibility (the ecology's draw gate): the canon card exists,
    the captain is not mid-return-queue and not already sailing on a live
    fleet. ``day`` mirrors the oracle signature (the gate reads the status,
    not the day)."""
    if not store.get_captain(id):
        return False
    if is_deployed(captain_states, id):
        return False
    return str(state(captain_states, store, id)
               .get("status", STATUS_ACTIVE)) == STATUS_ACTIVE


# --- Nemesis (docs/60-* §4.11.15) ---------------------------------------------

def is_nemesis(captain_states: dict[str, Any], store: DataStore,
               id: str) -> bool:
    """True when this captain returns as a nemesis hunter: a pirate/
    privateer whose stance sank to ≤ −3 (the role gate is the canon card's;
    an unknown id is never a nemesis). The hunter behavior itself is the
    ecology port's — this is the flag it reacts to."""
    if int(_state_no_store(captain_states, id).get("stance", 0)) > NEMESIS_STANCE:
        return False
    return str(store.get_captain(id).get("role", "")) in NEMESIS_ROLES


# --- Stance --------------------------------------------------------------------

def stance(captain_states: dict[str, Any], id: str) -> int:
    return int(_state_no_store(captain_states, id).get("stance", 0))


def adjust_stance(captain_states: dict[str, Any], store: DataStore, id: str,
                  delta: int) -> int:
    """Applies a clamped stance delta (one of the STANCE_* constants at
    every call site) and returns the new value."""
    st = ensure(captain_states, store, id)
    st["stance"] = max(STANCE_MIN, min(int(st.get("stance", 0)) + delta,
                                       STANCE_MAX))
    return int(st["stance"])


# --- Familiarity ----------------------------------------------------------------

def familiarity(captain_states: dict[str, Any], id: str) -> int:
    return int(_state_no_store(captain_states, id).get("familiarity", 0))


def add_familiarity(captain_states: dict[str, Any], store: DataStore,
                    id: str, amount: int = 1) -> int:
    """Adds a clamped familiarity amount (default +1: one
    sighting/interaction) and returns the new value."""
    st = ensure(captain_states, store, id)
    st["familiarity"] = max(FAMILIARITY_MIN, min(
        int(st.get("familiarity", 0)) + amount, FAMILIARITY_MAX))
    return int(st["familiarity"])


def familiarity_tier(captain_states: dict[str, Any], id: str) -> int:
    """The dossier career-log tier: 0 (< 3) / 1 (≥ 3) / 2 (≥ 6) / 3 (≥ 10)."""
    value = familiarity(captain_states, id)
    return sum(1 for threshold in FAMILIARITY_TIERS if value >= threshold)


# --- Dossier flag ---------------------------------------------------------------

def dossier_seen(captain_states: dict[str, Any], id: str) -> bool:
    return bool(_state_no_store(captain_states, id).get("dossier_seen", False))


def mark_dossier_seen(captain_states: dict[str, Any], store: DataStore,
                      id: str) -> None:
    ensure(captain_states, store, id)["dossier_seen"] = True


# --- Speed jitter (docs/60-* §4.11.15) -----------------------------------------

def _godot_string_hash(text: str) -> int:
    """Bit-exact Godot 4.7 ``String.hash()``: djb2 over the UTF-32 code
    points, uint32 wraparound (``hash = hash * 33 + c`` seeded at 5381).
    Verified against live ``godot --headless`` probes of the pinned
    toolchain (Godot v4.7.stable.official.5b4e0cb0f): the probe ids —
    ``pirate_edward_bloodhand`` → 503144810, ``""`` → 5381, ``a`` → 177670,
    ``航海者`` → 230622187 — reproduce exactly (test-pinned)."""
    value = 5381
    for char in text:
        value = ((value << 5) + value + ord(char)) & 0xFFFFFFFF
    return value


def speed_jitter(id: str) -> float:
    """A stable per-captain speed factor ∈ [−0.10, +0.10]: a pure hash of
    the captain id (no RNG, no state), quantized to 1/1000 — the same fleet
    always jitters the same way, on every reload, without seeding anything."""
    bucket = _godot_string_hash(id) % _JITTER_STEPS  # 0 … 200
    half = _JITTER_STEPS // 2  # 100
    return (float(bucket - half) / float(half)) * SPEED_JITTER_MAX
