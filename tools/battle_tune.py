#!/usr/bin/env python3
"""battle_tune.py — offline θ tuning for the §4.9c T3 one-ply lookahead.

W5-B (IMPLEMENT-Phase9.md decision 16, correction 11): a stdlib-only CEM
over subprocess headless-Godot battles run by
`tools/battle_tune_runner.gd/.tscn` (TUNE_JOB / TUNE_OUT). The tool NEVER
writes game data: the learned integers land doc-first through the master's
named θ-finalization task (docs/60-COMBAT.md §4.9c amendment first, then the
`ai_search.gd` const sync).

Stages (§4.9c archetype → kind map, docs/10-* §4.10 rows):
  balanced    navy / patrol / tournament            · 50 generations · init σ 5
  aggressive  pirate / privateer                    · 20 generations · init σ 3
  cautious    treasure / trader / coaster / courier · 20 generations · init σ 3

Stage 1 inits at the §4.9c doc prior {10, 4, 2, 3, −5, −6, −2, −4, 2}; the
stage-2 fine-tunes init at θ_balanced's learned mean. Population 32 · elite
8 · per-generation evaluation on a rotating 16-seed window of the stage's 64
train seeds (gen g uses train[(g·16 + k) mod 64]) · every (candidate, seed)
runs SIDE-SWAPPED — θ as enemy AND θ as player — versus the free T2; the
pair's merged result scores the candidate: win = 1, stall/draw = 0.5,
loss = 0, averaged over the swap. Integer CEM: candidates evolve as floats
(per-dim bounds [−10, 10]); battles evaluate round(θ) — the classic
integer-CEM trick that keeps the population's floats evolving.

Sampling RNG: random.Random(--sampling-seed, default 179), re-derived
deterministically per (stage, generation) as
`(sampling_seed·1000003 + stage_ordinal·7919 + gen·104729) mod 2³¹` so a
fixed seed ⇒ bit-identical runs AND mid-stage resumption (W5-D pins the
reproducibility contract).

The frozen seed table `tools/battle_tune_seeds.json` (64 train + 64
validate) is built ONCE by `--build-seeds` with random.Random(20261104); a
rebuild must be byte-identical (asserted, in-process and against the
committed file).

Gates (reported, master-owned):
  convergence        final per-dim σ_max ≤ init σ / 2 (5 → 2.5, 3 → 1.5)
  learning-gain      learned θ validation score ≥ prior θ + 5 pp (vs free T2)
  validation droop   train final elite mean − validation score ≤ 2 pp
  perturbation       ±20 % per-dim re-score mean droop ≤ 3 pp
  distinctness       aggressive vs cautious: mean engagement distance gap
                     ≥ 1 cell AND flee-rate gap ≥ 10 pp (validation battles)
"""

import argparse
import concurrent.futures
import json
import os
import random
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SEEDS_PATH = REPO / "tools" / "battle_tune_seeds.json"
REPORT_PATH = REPO / "tools" / "battle_tune_report.md"
DEFAULT_STATE_PATH = REPO / "tools" / "battle_tune_state.json"

# The §4.9c doc-first prior (60-COMBAT.md; ai_search.gd THETA_* consts —
# the consts are the runtime's only θ source; this tool only reports).
PRIOR = [10, 4, 2, 3, -5, -6, -2, -4, 2]
N_DIMS = 9
DIM_LO, DIM_HI = -10.0, 10.0
SIGMA_FLOOR = 0.2          # tool knob: CEM σ never collapses below this
POPULATION = 32
ELITE = 8
EVAL_SEEDS = 16
STAGE_GENERATIONS = {"balanced": 50, "aggressive": 20, "cautious": 20}
STAGE_SIGMA_INIT = {"balanced": 5.0, "aggressive": 3.0, "cautious": 3.0}
STAGE_ORDINAL = {"balanced": 0, "aggressive": 1, "cautious": 2}
STAGE_KINDS = {
    "balanced": ["navy", "patrol", "tournament"],
    "aggressive": ["pirate", "privateer"],
    "cautious": ["treasure", "trader", "coaster", "courier"],
}
# The AiFleet._ship_count bands per kind (§4.11.3 step 1 + §4.11.11.2/.4 —
# mirrored here for the frozen table; the runner asserts every composed
# fleet lands inside its kind's band).
KIND_BANDS = {
    "pirate": [1, 3], "navy": [2, 4], "patrol": [2, 4], "privateer": [2, 4],
    "tournament": [1, 3], "treasure": [4, 6], "trader": [1, 3],
    "coaster": [1, 3], "courier": [1, 3],
}
WEATHERS = ["calm", "fair", "strong", "storm"]           # sailing_sim WEATHER_OUTCOMES
COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]   # sailing_sim COMPASS_DIRS
TRAIN_N = 64
VALIDATE_N = 64
SEED_BUILD_SEED = 20261104
SEED_BASE = 2718281
SEED_STEP = 8191
DEFAULT_FLEET_SPEC = {"hulls": {"brigantine": 2}}

# Stage-2 seam: the cautious stage's baseline side carries the §4.9a hunter
# row (navy — correction 8) instead of the fleeing cautious row. With the
# engine-default baseline both cautious-stage seats flee-always
# (aggression < 25 on BOTH sides) and every battle is a no-contact stall —
# no gradient, no behavior contrast. The hunter baseline gives swap A its
# real objective (evade the T2 hunter). Recorded in the report.
NAVY_ROW = {
    "kind": "navy", "archetype": "balanced", "aggression": 60,
    "preferred_range": 3, "flee_below_hp_pct": 15, "focus": "flagship",
    "courage_mod": 0, "formation": "line_ahead", "ai_level": 0,  # forced T2
}
BASELINE_PROFILE_OVERRIDE = {"cautious": NAVY_ROW}

GATE_LEARN_GAIN = 0.05     # ≥ +5 pp vs prior on validation
GATE_DROOP = 0.02          # validation droop ≤ 2 pp
GATE_PERTURB = 0.03        # ±20 % perturbation mean droop ≤ 3 pp
GATE_DIST_GAP = 1.0        # mean engagement distance gap ≥ 1 cell
GATE_FLEE_GAP = 0.10       # flee-rate gap ≥ 10 pp

SWAP_SCORE = {"theta": 1.0, "none": 0.5, "baseline": 0.0}
BATTLE_JOB_TIMEOUT_S = 120.0


# --- CLI ----------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Offline θ CEM for the §4.9c T3 (W5-B). Stdlib only.")
    parser.add_argument("--build-seeds", action="store_true",
                        help="build the frozen 64+64 seed table (byte-identical assert)")
    parser.add_argument("--stage", default="all",
                        choices=["balanced", "aggressive", "cautious", "all"])
    parser.add_argument("--generations", type=int, default=None,
                        help="generations per stage (default: 50/20/20 per stage)")
    parser.add_argument("--samples", type=int, default=POPULATION,
                        help="CEM population size per generation (default 32)")
    parser.add_argument("--seeds", type=int, default=EVAL_SEEDS,
                        help="train seeds per candidate evaluation window (default 16); "
                             "also sizes the --perturb re-score subset")
    parser.add_argument("--sampling-seed", type=int, default=179,
                        help="CEM sampling RNG seed (default 179; fixed ⇒ bit-identical)")
    parser.add_argument("--quick", action="store_true",
                        help="= --generations 4 --samples 8 --seeds 8")
    parser.add_argument("--validate", action="store_true",
                        help="learned θ vs prior + vs free T2 on the 64 validation seeds "
                             "(side-swapped) for the selected stages")
    parser.add_argument("--perturb", action="store_true",
                        help="±20 %% per-dim perturbation re-score (droop ≤ 3 pp gate)")
    parser.add_argument("--report", action="store_true",
                        help="write tools/battle_tune_report.md from the state")
    parser.add_argument("--state", default=str(DEFAULT_STATE_PATH),
                        help="state file (default tools/battle_tune_state.json)")
    parser.add_argument("--workers", type=int, default=4,
                        help="concurrent headless Godot jobs (default 4; results are "
                             "per-battle deterministic — parallelism is wall-clock only)")
    parser.add_argument("--chunk", type=int, default=48,
                        help="battles per Godot invocation (default 48)")
    args = parser.parse_args(argv)
    if args.quick:
        args.generations = 4
        args.samples = 8
        args.seeds = 8
    # Training intent: --quick, --generations, an explicit --stage, or NO
    # action flags at all (the plain `python3 tools/battle_tune.py` full run).
    # A bare `--report` (optionally --validate/--perturb) renders/evaluates
    # the existing state and never extends training.
    argv_list = list(sys.argv[1:] if argv is None else argv)
    stage_explicit = any(a == "--stage" or a.startswith("--stage=")
                         for a in argv_list)
    args.train = (args.quick or args.generations is not None or stage_explicit
                  or not (args.validate or args.perturb or args.report))
    return args


# --- The frozen seed table ----------------------------------------------------

def build_seed_doc():
    """One deterministic pass with random.Random(20261104).

    Per seed, sampled IN THIS ORDER: day ∈ 1..300, contact x ∈ 60..4260
    (wrap-aware world band), contact y ∈ 40..2120, weather ∈ 4, wind_dir ∈ 8,
    current strength ∈ 0..3, current dir ∈ 8 (needed for the §4.3a current
    modifier to bite at strength > 0), then per stage the rotated kind and a
    band-sample of the enemy ship count (informational — composition is
    compose_enemy's own §4.11.3 roll; the runner asserts the actual count
    lands inside the kind's band)."""
    rng = random.Random(SEED_BUILD_SEED)
    seeds = []
    for i in range(TRAIN_N + VALIDATE_N):
        entry = {
            "index": i,
            "seed": SEED_BASE + i * SEED_STEP,
            "train": i < TRAIN_N,
            "day": rng.randint(1, 300),
            "contact": [rng.randint(60, 4260), rng.randint(40, 2120)],
            "weather": WEATHERS[rng.randrange(len(WEATHERS))],
            "wind_dir": COMPASS[rng.randrange(len(COMPASS))],
            "current": {
                "dir": COMPASS[rng.randrange(len(COMPASS))],
                "strength": rng.randint(0, 3),
            },
            "kinds": {},
            "enemy_count": {},
        }
        for stage in ("balanced", "aggressive", "cautious"):
            kinds = STAGE_KINDS[stage]
            kind = kinds[i % len(kinds)]
            entry["kinds"][stage] = kind
            lo, hi = KIND_BANDS[kind]
            entry["enemy_count"][stage] = rng.randint(lo, hi)
        seeds.append(entry)
    return {
        "schema": "sailage.battle_tune_seeds/1",
        "build_seed": SEED_BUILD_SEED,
        "seed_formula": "seed_i = 2718281 + index * 8191",
        "counts": {"train": TRAIN_N, "validate": VALIDATE_N},
        "stage_kinds": STAGE_KINDS,
        "kind_bands": KIND_BANDS,
        "sample_order": ["day", "contact.x", "contact.y", "weather",
                         "wind_dir", "current.dir", "current.strength",
                         "enemy_count[balanced,aggressive,cautious]"],
        "notes": [
            "FROZEN table (IMPLEMENT-Phase9 decision 16, W5-B): built once by",
            "`python3 tools/battle_tune.py --build-seeds` with",
            "random.Random(20261104); a rebuild must be byte-identical (asserted).",
            "The enemy_count field is the band sample; the runner's actual",
            "compose_enemy count is asserted against kind_bands instead.",
            "current.dir is an extension beyond the slot spec's strength field:",
            "without it the §4.3a current modifier never bites at strength > 0.",
        ],
        "seeds": seeds,
    }


def cmd_build_seeds(_args):
    text = json.dumps(build_seed_doc(), indent=1, sort_keys=True) + "\n"
    assert text == json.dumps(build_seed_doc(), indent=1, sort_keys=True) + "\n", \
        "in-process rebuild differs — the builder is not deterministic"
    if SEEDS_PATH.exists():
        existing = SEEDS_PATH.read_text()
        if existing == text:
            print(f"seeds: {SEEDS_PATH.name} rebuild byte-identical "
                  f"({TRAIN_N}+{VALIDATE_N} seeds) — table stays frozen")
            return 0
        raise SystemExit("seeds: committed table differs from the rebuild — "
                         "the frozen table must never drift")
    SEEDS_PATH.write_text(text)
    print(f"seeds: wrote {SEEDS_PATH} ({TRAIN_N}+{VALIDATE_N} seeds)")
    return 0


def load_seeds():
    if not SEEDS_PATH.exists():
        raise SystemExit("seeds: tools/battle_tune_seeds.json missing — "
                         "run --build-seeds first (the table is committed)")
    doc = json.loads(SEEDS_PATH.read_text())
    train = [s for s in doc["seeds"] if s["train"]]
    validate = [s for s in doc["seeds"] if not s["train"]]
    assert len(train) == TRAIN_N and len(validate) == VALIDATE_N, "seed table shape"
    return doc, train, validate


# --- Battle dispatch (subprocess headless Godot) ------------------------------

_print_lock = threading.Lock()


def _progress(msg):
    with _print_lock:
        print(msg, flush=True)


def _run_job(chunk, chunk_tag, godot, tmpdir, repo):
    job_path = tmpdir / f"job_{chunk_tag}.json"
    out_path = tmpdir / f"out_{chunk_tag}.json"
    job = {"battles": chunk, "out_path": str(out_path)}
    job_path.write_text(json.dumps(job))
    env = dict(os.environ)
    env["TUNE_JOB"] = str(job_path)
    env["TUNE_OUT"] = str(out_path)
    timeout = BATTLE_JOB_TIMEOUT_S + 60.0 * len(chunk)
    started = time.monotonic()
    try:
        proc = subprocess.run(
            [godot, "--headless", "res://tools/battle_tune_runner.tscn"],
            cwd=str(repo), env=env, capture_output=True, text=True,
            timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"job {chunk_tag} timed out after {timeout:.0f}s")
    elapsed = time.monotonic() - started
    if proc.returncode != 0:
        tail = "\n".join((proc.stderr or proc.stdout or "").strip().splitlines()[-12:])
        raise RuntimeError(f"job {chunk_tag} exited {proc.returncode}\n{tail}")
    log = (proc.stdout or "") + (proc.stderr or "")
    if "SCRIPT ERROR" in log:
        tail = "\n".join(log.strip().splitlines()[-12:])
        raise RuntimeError(f"job {chunk_tag} logged a SCRIPT ERROR\n{tail}")
    payload = json.loads(out_path.read_text())
    if int(payload.get("ran", -1)) != len(chunk):
        raise RuntimeError(f"job {chunk_tag}: ran {payload.get('ran')} "
                           f"!= expected {len(chunk)}")
    if not payload.get("reproducible", False):
        raise RuntimeError(f"job {chunk_tag}: reproducibility probe FAILED")
    if not payload.get("band_ok", False):
        raise RuntimeError(f"job {chunk_tag}: enemy band assertion FAILED")
    try:
        job_path.unlink()
        out_path.unlink()
    except OSError:
        pass
    _progress(f"  [{chunk_tag}] {len(chunk)} battles in {elapsed:.1f}s "
              f"({elapsed / max(len(chunk), 1):.2f} s/battle)")
    return {
        "records": payload["results"],
        "battles": len(chunk),
        "seconds": elapsed,
        "decisions": int(payload.get("decisions", 0)),
        "illegal": int(payload.get("illegal", 0)),
        "reproducible": bool(payload.get("reproducible", False)),
    }


def run_battles(battles, args, godot, tmpdir, label):
    """Chunked, worker-pooled dispatch. Returns (records, measure) where
    measure carries battles/seconds/decisions/illegal/reproducible sums."""
    if not battles:
        return [], {"battles": 0, "seconds": 0.0, "decisions": 0,
                    "illegal": 0, "reproducible": True}
    chunks = [battles[i:i + args.chunk] for i in range(0, len(battles), args.chunk)]
    results = [None] * len(chunks)
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(_run_job, chunk, f"{label}_{k:04d}", godot, tmpdir, REPO):
                k for k, chunk in enumerate(chunks)
        }
        for future in concurrent.futures.as_completed(futures):
            results[futures[future]] = future.result()
    records = [r for chunk in results for r in chunk["records"]]
    measure = {
        "battles": sum(c["battles"] for c in results),
        "seconds": sum(c["seconds"] for c in results),
        "decisions": sum(c["decisions"] for c in results),
        "illegal": sum(c["illegal"] for c in results),
        "reproducible": all(c["reproducible"] for c in results),
    }
    _progress(f"  {label}: {measure['battles']} battles, "
              f"{measure['seconds']:.1f}s busy, "
              f"{time.monotonic() - started:.1f}s wall "
              f"({measure['seconds'] / max(measure['battles'], 1):.2f} s/battle)")
    return records, measure


def battle_spec(entry, stage, theta_side, theta_ints, baseline_profile):
    kind = entry["kinds"][stage]
    return {
        "seed": int(entry["seed"]),
        "enemy_kind": kind,
        "day": int(entry["day"]),
        "fleet_spec": DEFAULT_FLEET_SPEC,
        "contact": {"x": int(entry["contact"][0]), "y": int(entry["contact"][1])},
        "weather": entry["weather"],
        "wind_dir": entry["wind_dir"],
        "current": {"dir": entry["current"]["dir"],
                    "strength": int(entry["current"]["strength"])},
        "theta_side": theta_side,
        "theta": [int(v) for v in theta_ints],
        "archetype": stage,
        "baseline_side_profile": baseline_profile,
        "enemy_band": KIND_BANDS[kind],
    }


def candidate_battles(candidates, entries, stage, baseline_profile):
    """Side-swapped CRN: every (candidate, seed) runs twice (θ as enemy AND θ
    as player). Battle order is deterministic: candidate-major, seed, swap."""
    battles = []
    keys = []
    for j, theta in enumerate(candidates):
        theta_ints = [clamp_dim(round(v)) for v in theta]
        for e_idx, entry in enumerate(entries):
            for swap in ("enemy", "player"):
                battles.append(battle_spec(entry, stage, swap, theta_ints,
                                           baseline_profile))
                keys.append((j, e_idx, swap))
    return battles, keys


def score_records(records, keys, n_candidates, n_entries):
    scores = [[None, None] for _ in range(n_candidates * n_entries)]
    for record, (j, e_idx, swap) in zip(records, keys):
        slot = scores[j * n_entries + e_idx]
        slot[0 if swap == "enemy" else 1] = SWAP_SCORE[record["winner_side"]]
    per_candidate = []
    for j in range(n_candidates):
        pairs = scores[j * n_entries:(j + 1) * n_entries]
        assert all(a is not None and b is not None for a, b in pairs), \
            f"candidate {j}: missing swap half"
        per_candidate.append(sum((a + b) / 2.0 for a, b in pairs) / len(pairs))
    return per_candidate


# --- The CEM ------------------------------------------------------------------

def clamp_dim(value):
    return max(DIM_LO, min(DIM_HI, float(value)))


def theta_ints(mean):
    return [int(max(DIM_LO, min(DIM_HI, round(v)))) for v in mean]


def gen_rng(sampling_seed, stage, gen):
    return random.Random((sampling_seed * 1000003
                          + STAGE_ORDINAL[stage] * 7919
                          + gen * 104729) % (2 ** 31))


def init_mean_for(stage, state):
    if stage == "balanced":
        return [float(v) for v in PRIOR]
    base = state["stages"].get("balanced")
    if not base or "mean" not in base:
        raise SystemExit(f"stage {stage}: θ_balanced has not trained — "
                         "run --stage balanced (or --stage all) first")
    return [float(v) for v in base["mean"]]


def run_stage(stage, args, train, state, godot, tmpdir):
    st = state["stages"].setdefault(stage, {})
    target_gens = args.generations or STAGE_GENERATIONS[stage]
    samples = args.samples
    elite = max(2, samples // 4)
    n_eval = min(args.seeds, TRAIN_N)
    st.setdefault("curve", [])
    st.setdefault("config", {})
    st["config"] = {
        "generations": target_gens, "samples": samples, "elite": elite,
        "eval_seeds": n_eval, "sigma_init": STAGE_SIGMA_INIT[stage],
        "sampling_seed": args.sampling_seed,
    }
    if "mean" not in st:
        st["mean"] = init_mean_for(stage, state)
        st["sigma"] = [STAGE_SIGMA_INIT[stage]] * N_DIMS
    baseline_profile = BASELINE_PROFILE_OVERRIDE.get(stage)
    if st["curve"]:
        st["theta_learned"] = theta_ints(st["mean"])
        st["train_score_final"] = st["curve"][-1]["elite_mean"]
    if len(st["curve"]) >= target_gens:
        _progress(f"stage {stage}: {len(st['curve'])} generations already "
                  f"recorded — skipping (state resume)")
        return
    print(f"stage {stage}: gens {len(st['curve'])}..{target_gens - 1} · "
          f"population {samples} · elite {elite} · eval seeds {n_eval} · "
          f"σ init {STAGE_SIGMA_INIT[stage]} · baseline profile "
          f"{'navy-row override' if baseline_profile else 'engine default'}",
          flush=True)
    for gen in range(len(st["curve"]), target_gens):
        rng = gen_rng(args.sampling_seed, stage, gen)
        candidates = []
        for _ in range(samples):
            candidate = [clamp_dim(st["mean"][d]
                                   + rng.gauss(0.0, st["sigma"][d]))
                         for d in range(N_DIMS)]
            candidates.append(candidate)
        window = [(gen * n_eval + k) % TRAIN_N for k in range(n_eval)]
        entries = [train[i] for i in window]
        battles, keys = candidate_battles(candidates, entries, stage,
                                          baseline_profile)
        records, measure = run_battles(battles, args, godot, tmpdir,
                                       f"{stage}_g{gen:03d}")
        per_candidate = score_records(records, keys, samples, n_eval)
        order = sorted(range(samples), key=lambda j: (-per_candidate[j], j))
        elite_idx = order[:elite]
        new_mean = []
        new_sigma = []
        for d in range(N_DIMS):
            column = [candidates[j][d] for j in elite_idx]
            mu = sum(column) / elite
            var = sum((v - mu) ** 2 for v in column) / elite
            new_mean.append(mu)
            new_sigma.append(max(var ** 0.5, SIGMA_FLOOR))
        st["mean"] = new_mean
        st["sigma"] = new_sigma
        st["curve"].append({
            "gen": gen,
            "window": [window[0], window[-1]],
            "elite_mean": per_candidate[elite_idx[0]],
            "best": per_candidate[order[0]],
            "mean_score": sum(per_candidate) / samples,
            "sigma_mean": sum(new_sigma) / N_DIMS,
            "sigma_max": max(new_sigma),
            "theta_best": theta_ints(candidates[elite_idx[0]]),
        })
        state["battles_expected"] = state.get("battles_expected", 0) + len(battles)
        state["battles_ran"] = state.get("battles_ran", 0) + measure["battles"]
        state["decisions"] = state.get("decisions", 0) + measure["decisions"]
        state["illegal"] = state.get("illegal", 0) + measure["illegal"]
        state["measure_seconds"] = state.get("measure_seconds", 0.0) + measure["seconds"]
        state["reproducible"] = state.get("reproducible", True) and measure["reproducible"]
        save_state(args, state)
        point = st["curve"][-1]
        print(f"  gen {gen:3d} · elite mean {point['elite_mean']:.3f} · "
              f"best {point['best']:.3f} · pop mean {point['mean_score']:.3f} · "
              f"σ mean {point['sigma_mean']:.2f} σ max {point['sigma_max']:.2f} · "
              f"θ* {point['theta_best']}", flush=True)
    st["theta_learned"] = theta_ints(st["mean"])
    st["train_score_final"] = st["curve"][-1]["elite_mean"]
    save_state(args, state)


# --- Validation & perturbation -------------------------------------------------

def theta_score_runs(theta, entries, stage, args, state, godot, tmpdir,
                     label, baseline_profile):
    battles, keys = candidate_battles([[float(v) for v in theta]], entries,
                                      stage, baseline_profile)
    records, measure = run_battles(battles, args, godot, tmpdir, label)
    per_candidate = score_records(records, keys, 1, len(entries))
    state["battles_expected"] = state.get("battles_expected", 0) + len(battles)
    state["battles_ran"] = state.get("battles_ran", 0) + measure["battles"]
    state["decisions"] = state.get("decisions", 0) + measure["decisions"]
    state["illegal"] = state.get("illegal", 0) + measure["illegal"]
    state["measure_seconds"] = state.get("measure_seconds", 0.0) + measure["seconds"]
    state["reproducible"] = state.get("reproducible", True) and measure["reproducible"]
    save_state(args, state)
    return per_candidate[0], records, measure


def behavior_metrics(records):
    n = max(len(records), 1)
    volleys = sum(r["cannon_volleys"] for r in records)
    return {
        "battles": len(records),
        "mean_engagement_distance": sum(r["engagement_distance_mean"]
                                        for r in records) / n,
        "flee_rate": sum(1 for r in records if r["fled"]) / n,
        "boarding_rate": sum(r["boardings"] for r in records) / n,
        "grape_share": (sum(r["grape_shots"] for r in records) / volleys)
        if volleys else 0.0,
        "mean_rounds": sum(r["rounds"] for r in records) / n,
        "stall_rate": sum(1 for r in records if r["stall"]) / n,
        "theta_avg_ms": sum(r["theta_avg_ms"] for r in records) / n,
        "theta_max_ms": max([r["theta_max_ms"] for r in records] or [0.0]),
        "wins": sum(1 for r in records if r["winner_side"] == "theta"),
        "draws": sum(1 for r in records if r["winner_side"] == "none"),
        "losses": sum(1 for r in records if r["winner_side"] == "baseline"),
    }


def run_validate(stage, args, validate, state, godot, tmpdir):
    st = state["stages"].get(stage)
    if not st or "theta_learned" not in st:
        raise SystemExit(f"--validate: stage {stage} has no learned θ — train first")
    baseline_profile = BASELINE_PROFILE_OVERRIDE.get(stage)
    val = state["validation"].setdefault(stage, {})
    learned_score, learned_records, _ = theta_score_runs(
        st["theta_learned"], validate, stage, args, state, godot, tmpdir,
        f"validate_{stage}_learned", baseline_profile)
    prior_score, _prior_records, _ = theta_score_runs(
        PRIOR, validate, stage, args, state, godot, tmpdir,
        f"validate_{stage}_prior", baseline_profile)
    val["learned"] = {
        "theta": st["theta_learned"],
        "score": learned_score,
        "behavior": behavior_metrics(learned_records),
    }
    val["prior"] = {"theta": list(PRIOR), "score": prior_score}
    val["gain_pp"] = (learned_score - prior_score) * 100.0
    val["droop_pp"] = (st.get("train_score_final", learned_score)
                       - learned_score) * 100.0
    save_state(args, state)
    print(f"validate {stage}: learned {learned_score:.3f} · "
          f"prior {prior_score:.3f} · gain {val['gain_pp']:+.1f} pp · "
          f"droop {val['droop_pp']:+.1f} pp", flush=True)


def run_perturb(stage, args, validate, state, godot, tmpdir):
    st = state["stages"].get(stage)
    if not st or "theta_learned" not in st:
        raise SystemExit(f"--perturb: stage {stage} has no learned θ — train first")
    base_theta = st["theta_learned"]
    subset = validate[:min(args.seeds, VALIDATE_N)]
    baseline_profile = BASELINE_PROFILE_OVERRIDE.get(stage)
    per = state["perturb"].setdefault(stage, {})
    base_score, _records, _ = theta_score_runs(
        base_theta, subset, stage, args, state, godot, tmpdir,
        f"perturb_{stage}_base", baseline_profile)
    runs = []
    for dim in range(N_DIMS):
        for sign in (+1, -1):
            theta = list(base_theta)
            theta[dim] = int(max(DIM_LO, min(DIM_HI,
                                             round(base_theta[dim] * (1.0 + sign * 0.20)))))
            score, _records, _ = theta_score_runs(
                theta, subset, stage, args, state, godot, tmpdir,
                f"perturb_{stage}_d{dim}{'p' if sign > 0 else 'm'}",
                baseline_profile)
            runs.append({"dim": dim, "sign": "plus" if sign > 0 else "minus",
                         "theta": theta, "score": score,
                         "drop_pp": (base_score - score) * 100.0})
    drops = [r["drop_pp"] for r in runs]
    per.update({
        "subset": len(subset),
        "unperturbed": base_score,
        "runs": runs,
        "mean_drop_pp": sum(drops) / len(drops),
        "max_drop_pp": max(drops),
    })
    save_state(args, state)
    print(f"perturb {stage}: unperturbed {base_score:.3f} · mean drop "
          f"{per['mean_drop_pp']:.1f} pp · max {per['max_drop_pp']:.1f} pp",
          flush=True)


# --- Gates ---------------------------------------------------------------------

def gate_table(state):
    rows = []
    for stage in ("balanced", "aggressive", "cautious"):
        st = state["stages"].get(stage, {})
        cfg = st.get("config", {})
        curve = st.get("curve", [])
        if curve:
            sigma_init = cfg.get("sigma_init", STAGE_SIGMA_INIT[stage])
            sigma_max = curve[-1]["sigma_max"]
            threshold = sigma_init / 2.0
            rows.append((
                f"convergence · {stage}",
                f"final σ_max ≤ {threshold:.1f}",
                f"σ_max {sigma_max:.2f}",
                "PASS" if sigma_max <= threshold else "WATCH",
            ))
        val = state["validation"].get(stage, {})
        if val:
            gain = val.get("gain_pp", 0.0)
            rows.append((
                f"learning-gain · {stage}",
                "≥ +5.0 pp vs prior (validation)",
                f"{gain:+.1f} pp",
                "PASS" if gain >= GATE_LEARN_GAIN * 100 else "FAIL",
            ))
            droop = val.get("droop_pp", 0.0)
            rows.append((
                f"validation droop · {stage}",
                "≤ 2.0 pp",
                f"{droop:+.1f} pp",
                "PASS" if droop <= GATE_DROOP * 100 else "FAIL",
            ))
        per = state["perturb"].get(stage, {})
        if per:
            drop = per.get("mean_drop_pp", 0.0)
            rows.append((
                f"perturbation · {stage}",
                "mean droop ≤ 3.0 pp (±20 % per dim)",
                f"{drop:.1f} pp (max {per.get('max_drop_pp', 0.0):.1f})",
                "PASS" if drop <= GATE_PERTURB * 100 else "FAIL",
            ))
    aggr = state["validation"].get("aggressive", {}).get("learned", {}).get("behavior")
    caut = state["validation"].get("cautious", {}).get("learned", {}).get("behavior")
    if aggr and caut:
        dist_gap = abs(aggr["mean_engagement_distance"]
                       - caut["mean_engagement_distance"])
        flee_gap = abs(aggr["flee_rate"] - caut["flee_rate"]) * 100.0
        dist_ok = dist_gap >= GATE_DIST_GAP
        flee_ok = flee_gap >= GATE_FLEE_GAP * 100
        rows.append((
            "distinctness · aggressive vs cautious",
            "distance gap ≥ 1 cell AND flee gap ≥ 10 pp",
            f"{dist_gap:.2f} cells · {flee_gap:.1f} pp",
            "PASS" if dist_ok and flee_ok else "FAIL",
        ))
    return rows


# --- Report ---------------------------------------------------------------------

def fmt_theta(theta):
    return "{" + ", ".join(str(int(v)) for v in theta) + "}"


def write_report(args, state):
    stages = [s for s in ("balanced", "aggressive", "cautious")
              if state["stages"].get(s, {}).get("curve")]
    cfg = state.get("config", {})
    full_defaults = (cfg.get("generations_override") is None
                     and cfg.get("samples", POPULATION) == POPULATION
                     and cfg.get("eval_seeds", EVAL_SEEDS) == EVAL_SEEDS)
    if full_defaults:
        marker = "RUN: full"
    else:
        gens = (state["stages"].get("balanced", {}).get("config", {})
                .get("generations"))
        gens = gens if gens is not None else "50/20/20"
        marker = (f"RUN: reduced (--generations {gens} "
                  f"--samples {cfg.get('samples', POPULATION)} "
                  f"--seeds {cfg.get('eval_seeds', EVAL_SEEDS)})")
    out = []
    out.append("# battle_tune report (tool-owned)")
    out.append("")
    out.append(f"**{marker}**")
    out.append("")
    out.append(f"- generated by `python3 tools/battle_tune.py "
               f"--stage {args.stage}{' --quick' if args.quick else ''} "
               f"--validate --perturb --report` (W5-B, decision 16)")
    out.append(f"- sampling seed {args.sampling_seed} · population "
               f"{args.samples} · elite {max(2, args.samples // 4)} · "
               f"eval window {args.seeds} train seeds/generation (rotating) · "
               f"integer CEM on bounds [−10, 10] · side-swapped CRN vs the "
               f"free T2 (win 1 / draw 0.5 / loss 0)")
    out.append("- frozen seed table `tools/battle_tune_seeds.json` "
               "(random.Random(20261104), 64 train + 64 validate)")
    out.append("- baseline profile: engine-default kind row on "
               "balanced/aggressive; the §4.9a hunter row (navy, forced "
               "ai_level 0) on cautious — see Findings.")
    out.append("")
    for stage in stages:
        st = state["stages"][stage]
        out.append(f"## Stage {stage} — θ_{stage}")
        out.append("")
        if st.get("theta_learned") is not None:
            out.append(f"Final integer θ: `{fmt_theta(st['theta_learned'])}`")
        else:
            out.append("Final integer θ: _not finalized_")
        out.append("")
        out.append("### training curve (per-generation elite mean winrate)")
        out.append("")
        out.append("| gen | window | elite mean | best | pop mean | σ mean | σ max | θ* |")
        out.append("|---|---|---|---|---|---|---|---|")
        for point in st["curve"]:
            out.append(
                "| {gen} | {w0:02d}..{w1:02d} | {elite_mean:.3f} | {best:.3f} "
                "| {mean_score:.3f} | {sigma_mean:.2f} | {sigma_max:.2f} | `{t}` |".format(
                    t=fmt_theta(point["theta_best"]), **{
                        "gen": point["gen"],
                        "w0": point["window"][0], "w1": point["window"][1],
                        "elite_mean": point["elite_mean"], "best": point["best"],
                        "mean_score": point["mean_score"],
                        "sigma_mean": point["sigma_mean"],
                        "sigma_max": point["sigma_max"]}))
        out.append("")
        out.append(f"σ-shrink: init {st['config']['sigma_init']} → final "
                   f"σ_max {st['curve'][-1]['sigma_max']:.2f} "
                   f"(σ mean {st['curve'][-1]['sigma_mean']:.2f}); "
                   f"learned mean (floats) `[{', '.join(f'{v:.2f}' for v in st['mean'])}]`.")
        out.append("")
    if stages:
        out.append("## θ_learned vs θ_prior vs T2 — train/validation 对照")
        out.append("")
        out.append("Scores are side-swapped winrates vs the FREE T2 (win 1 / "
                   "draw 0.5 / loss 0); the T2 reference line is 0.500 by "
                   "definition. Train = the final generation's elite mean "
                   "(rotating train windows); validation = the full 64-seed "
                   "validation table, both swaps.")
        out.append("")
        out.append("| stage | θ_learned | θ_prior | train elite mean | validation learned | validation prior | gain vs prior | droop |")
        out.append("|---|---|---|---|---|---|---|---|")
        for stage in stages:
            st = state["stages"][stage]
            val = state["validation"].get(stage, {})
            out.append("| {} | `{}` | `{}` | {:.3f} | {} | {} | {} | {} |".format(
                stage,
                fmt_theta(st.get("theta_learned", PRIOR)),
                fmt_theta(PRIOR),
                st.get("train_score_final", 0.0),
                f"{val['learned']['score']:.3f}" if val else "—",
                f"{val['prior']['score']:.3f}" if val else "—",
                f"{val['gain_pp']:+.1f} pp" if val else "—",
                f"{val['droop_pp']:+.1f} pp" if val else "—"))
        out.append("")
    behs = [(s, state["validation"].get(s, {}).get("learned", {}).get("behavior"))
            for s in ("balanced", "aggressive", "cautious")]
    if any(b for _, b in behs):
        out.append("## Behavior metrics (validation, learned θ vs free T2)")
        out.append("")
        out.append("| stage | mean engagement distance | flee rate | boarding "
                   "rate | grape share | mean rounds | stall rate | θ decision "
                   "avg/max ms | wins/draws/losses |")
        out.append("|---|---|---|---|---|---|---|---|---|")
        for stage, beh in behs:
            if not beh:
                continue
            out.append("| {} | {:.2f} cells | {:.1f}% | {:.2f}/battle | {:.1f}% "
                       "| {:.1f} | {:.1f}% | {:.1f} / {:.1f} | {}/{}/{} |".format(
                           stage,
                           beh["mean_engagement_distance"], beh["flee_rate"] * 100,
                           beh["boarding_rate"], beh["grape_share"] * 100,
                           beh["mean_rounds"], beh["stall_rate"] * 100,
                           beh["theta_avg_ms"], beh["theta_max_ms"],
                           beh["wins"], beh["draws"], beh["losses"]))
        out.append("")
        out.append("Formation-hold: **not applicable** — the tune loop drives "
                   "the free T3 (no §4.9b orders), so no station term exists "
                   "to hold.")
        out.append("")
    if state["perturb"]:
        out.append("## Perturbation (±20 % per dim, validation subset × both swaps)")
        out.append("")
        out.append("| stage | subset | unperturbed | mean score | mean drop | max drop | verdict |")
        out.append("|---|---|---|---|---|---|---|")
        for stage, per in state["perturb"].items():
            runs = per.get("runs", [])
            mean_score = sum(r["score"] for r in runs) / len(runs) if runs else 0.0
            drop = per.get("mean_drop_pp", 0.0)
            out.append(f"| {stage} | {per.get('subset', 0)} seeds | "
                       f"{per.get('unperturbed', 0.0):.3f} | {mean_score:.3f} | "
                       f"{drop:.1f} pp | {per.get('max_drop_pp', 0.0):.1f} pp | "
                       f"{'PASS' if drop <= GATE_PERTURB * 100 else 'FAIL'} |")
        out.append("")
        worst = {}
        for stage, per in state["perturb"].items():
            run = max(per.get("runs", []), key=lambda r: r["drop_pp"])
            worst[stage] = run
        for stage, run in worst.items():
            out.append(f"- {stage}: worst single-dim perturbation d{run['dim'] + 1}"
                       f"({run['sign']}) → θ={fmt_theta(run['theta'])}, "
                       f"drop {run['drop_pp']:.1f} pp.")
        out.append("")
    rows = gate_table(state)
    if rows:
        out.append("## Gates")
        out.append("")
        out.append("| gate | threshold | measured | verdict |")
        out.append("|---|---|---|---|")
        for name, threshold, measured, verdict in rows:
            out.append(f"| {name} | {threshold} | {measured} | **{verdict}** |")
        out.append("")
    expected = state.get("battles_expected", 0)
    ran = state.get("battles_ran", 0)
    decisions = state.get("decisions", 0)
    illegal = state.get("illegal", 0)
    legal = 100.0 if decisions == 0 else 100.0 * (decisions - illegal) / decisions
    seconds = state.get("measure_seconds", 0.0)
    per_battle = seconds / max(ran, 1)
    out.append("## 核对行")
    out.append("")
    out.append(f"- battles run == expected: **{ran} == {expected}** "
               f"{'✓' if ran == expected else '✗ MISMATCH'}")
    out.append(f"- legal actions: {legal:.2f}% ({illegal} illegal / "
               f"{decisions} decisions) — "
               f"{'✓ 100%' if illegal == 0 else '✗ BREACH'}")
    out.append(f"- reproducibility: {'✓ PASS' if state.get('reproducible', False) else '✗ FAIL'}"
               " — every Godot job re-ran its first battle twice and asserted "
               "byte-identical structured logs; the sampling RNG is derived "
               "per (stage, generation) from --sampling-seed, so two runs with "
               "the same seed produce identical state-curve sections")
    out.append(f"- per-battle cost (measured): {per_battle:.2f} s/battle busy "
               f"({seconds:.0f}s busy across {ran} battles)")
    out.append("")
    out.append(projection_block(state, per_battle, args.workers))
    out.append(findings_block(state))
    REPORT_PATH.write_text("\n".join(out) + "\n")
    print(f"report: wrote {REPORT_PATH}")


def projection_block(state, per_battle, workers=4):
    trained = sum(len(state["stages"].get(s, {}).get("curve", []))
                  for s in ("balanced", "aggressive", "cautious"))
    full_gens = sum(STAGE_GENERATIONS.values())
    full_train = full_gens * POPULATION * EVAL_SEEDS * 2
    remaining_gens = max(full_gens - trained, 0)
    remaining_train = remaining_gens * POPULATION * EVAL_SEEDS * 2
    # validation: learned + prior per stage = 2 θ sets × 64 seeds × 2 swaps
    remaining_val = sum(2 for s in ("balanced", "aggressive", "cautious")
                        if not state["validation"].get(s)) * VALIDATE_N * 2
    remaining_pert = sum(1 for s in ("balanced", "aggressive", "cautious")
                         if not state["perturb"].get(s)) * (N_DIMS * 2 + 1) \
        * min(EVAL_SEEDS, VALIDATE_N) * 2
    per_battle_busy = per_battle
    wall_full = full_train * per_battle_busy / workers
    wall_remaining = (remaining_train + remaining_val + remaining_pert) \
        * per_battle_busy / workers
    lines = [
        "## Full-run projection",
        "",
        f"- measured cost: **{per_battle_busy:.2f} s/battle busy** "
        f"(≈{1.0 / max(per_battle_busy / workers, 1e-9):.0f} battles/s wall at "
        f"{workers} workers) — battles/second from the smoke run",
        f"- the full two-stage schedule (50+20+20 gens × 32 candidates × "
        f"16 seeds × 2 swaps) = **{full_train:,} battles** ≈ "
        f"**{wall_full / 3600:.1f} h wall** "
        f"({full_train * per_battle_busy / 3600:.1f} h busy)",
        f"- remaining from the current state ({trained} gens recorded): "
        f"{remaining_train + remaining_val + remaining_pert:,} battles ≈ "
        f"**{wall_remaining / 3600:.1f} h wall** "
        f"(train {remaining_train:,} · validation {remaining_val:,} · "
        f"perturbation {remaining_pert:,})",
        f"- budget verdict (wall clock, {workers} workers): "
        + ("**within the ~3 h budget — launchable in the background**"
           if wall_full <= 3 * 3600 else
           "**over the ~3 h budget — the master schedules the long run**"),
        "",
    ]
    return "\n".join(lines)


def findings_block(state):
    lines = [
        "## Findings & deviations (recorded, master-owned)",
        "",
        "- **Never writes game data** (correction 11): the learned integers "
        "land doc-first through the master's θ-finalization task (§4.9c "
        "amendment, then `ai_search.gd` const sync). This report is the "
        "tool's only output besides its state file.",
        "- **θ-seat flee gate** (runner seam, documented in "
        "`battle_tune_runner.gd`): gate ① is enemy-seat-only (§4.8a "
        "correction 5 — player ships never auto-strike); gate ② for the T3 "
        "seat uses the hp% + morale clauses, and the `aggression < 25` "
        "clause stays on the T2 baseline seat. Rationale: every shipped "
        "`ai_level = 1` row already carries aggression ≥ 60 (clause inert "
        "for T3), and an always-on flee would pre-empt the search on every "
        "turn, leaving θ unobservable in the cautious stage.",
        "- **Cautious-stage baseline profile**: the job's "
        "`baseline_side_profile` seam carries the navy hunter row (forced "
        "`ai_level: 0`) on the cautious stage. With the engine-default row "
        "on BOTH seats, every cautious battle is a no-contact stall "
        "(both sides flee-always) — no gradient, no behavior contrast. "
        "Swap B of the pair still rewards catching the runner; the merged "
        "objective therefore leans fight-y — read the distinctness gate "
        "with that in mind.",
        "- The frozen table's `enemy_count` field is the band sample; the "
        "runner asserts the actual `compose_enemy` count against "
        "`kind_bands` instead (the §4.11.3 roll owns composition).",
        "- `current.dir` was sampled beyond the slot spec's strength field "
        "so the §4.3a current modifier actually bites at strength > 0 "
        "(strength alone with an empty dir is a no-op in the engine).",
        "- The baseline T2 is assembled from `AiFleet.decide`'s own static "
        "helpers (nothing copied) because the plain call dispatches into T3 "
        "for every `ai_level = 1` kind and is enemy-brained (it would "
        "self-target from the player seat).",
    ]
    val = state["validation"]
    if val:
        for stage in ("balanced", "aggressive", "cautious"):
            beh = val.get(stage, {}).get("learned", {}).get("behavior")
            if beh and beh["stall_rate"] >= 0.5:
                lines.append(
                    f"- **WATCH · {stage}**: stall rate {beh['stall_rate'] * 100:.0f}% "
                    "on validation — the stage's fitness is "
                    "dilation-dominated (draws), so θ movement is weakly "
                    "rewarded; treat the learning-gate verdict accordingly.")
    return "\n".join(lines)


# --- State ----------------------------------------------------------------------

def save_state(args, state):
    state.setdefault("config", {})
    state["config"] = {
        "sampling_seed": args.sampling_seed,
        "samples": args.samples,
        "eval_seeds": args.seeds,
        "generations_override": args.generations,
        "quick": bool(args.quick),
    }
    path = Path(args.state)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True) + "\n")
    tmp.replace(path)


def load_state(args):
    path = Path(args.state)
    if path.exists():
        return json.loads(path.read_text())
    return {"stages": {}, "validation": {}, "perturb": {}}


def main(argv=None):
    args = parse_args(argv)
    if args.build_seeds:
        return cmd_build_seeds(args)
    state = load_state(args)
    _doc, train, validate = load_seeds()
    stages = ("balanced", "aggressive", "cautious") if args.stage == "all" \
        else (args.stage,)
    need_godot = args.train or args.validate or args.perturb
    godot = None
    tmpdir = None
    if need_godot:
        godot = os.environ.get("GODOT_BIN") or shutil.which("godot")
        if not godot:
            raise SystemExit("godot binary not found (set GODOT_BIN)")
        tmproot = Path(os.environ.get("TUNE_TMP", "/tmp/opencode"))
        tmpdir = tmproot / "battle_tune"
        tmpdir.mkdir(parents=True, exist_ok=True)
    if args.train:
        for stage in stages:
            run_stage(stage, args, train, state, godot, tmpdir)
    if args.validate:
        for stage in stages:
            run_validate(stage, args, validate, state, godot, tmpdir)
    if args.perturb:
        for stage in stages:
            run_perturb(stage, args, validate, state, godot, tmpdir)
    if args.report:
        write_report(args, state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
