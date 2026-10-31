#!/usr/bin/env python3
"""Phase-5 canonical test-suite gate runner (docs/90-* §13).

Discovers tools/test_*.tscn, runs them headless with bounded time,
classifies GREEN / RED / ZOMBIE / HANG, and profiles every run (wall +
child CPU) so a gate never needs a second profiling pass. Stdlib only.

Exit codes: 0 all green · 1 RED present · 2 ZOMBIE/HANG present.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

# --- pinned constants (docs/90-* §13) ---------------------------------------
# Task J: the fleet-ecology and Phase-2/3 acceptance suites also write
# user://saves/ (SaveSystem round trips), so they join the serial-save set.
SERIAL_SAVE_SET = (
    "test_save", "test_save_v5", "test_world_e2e",
    "test_npc_fleets", "test_phase2_acceptance", "test_phase3_acceptance",
    # Task L: test_aliveness round-trips save slot 3 through save/load.
    "test_aliveness",
)
DEFAULT_TIMEOUT_S = 300.0
DEFAULT_JOBS = 8
POLL_S = 2.0            # log/CPU sample cadence
STUCK_IDLE_S = 6.0      # zero log growth + < STUCK_CPU_S child CPU ⇒ stuck
STUCK_CPU_S = 0.05
SLOW_WALL_MS = 30_000

MARKER_RE = re.compile(r"ALL PASS \(|checks FAILED")
LOAD_ERR_RE = re.compile(
    r"SCRIPT ERROR|Failed to load script|Failed loading|Failed to load resource",
    re.IGNORECASE,
)
PROFILE_RE = re.compile(r"^\s*PROFILE\s+(\S+)\s+(\d+)\s*$", re.M)


def child_cpu_s() -> float:
    import resource

    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    return float(ru.ru_utime) + float(ru.ru_stime)


def proc_cpu_s(pid: int) -> float:
    """Per-process CPU (utime+stime) from /proc — exact for the stuck
    detector, unlike the process-global RUSAGE_CHILDREN counter which is
    noisy under parallel jobs. Falls back to the global counter."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            fields = fh.read().rsplit(b")", 1)[1].split()
        ticks = int(fields[11]) + int(fields[12])  # utime, stime
        return ticks / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, IndexError):
        return child_cpu_s()


def classify(exit_code: int, log_text: str, timed_out: bool, stuck: bool) -> str:
    has_marker = bool(MARKER_RE.search(log_text))
    load_err = bool(LOAD_ERR_RE.search(log_text))
    if stuck and load_err and not has_marker:
        return "ZOMBIE"
    if (timed_out or stuck) and not has_marker:
        return "HANG"
    if exit_code == 0 and has_marker:
        return "GREEN"
    return "RED"


def run_one(name: str, repo: Path, log_dir: Path, timeout_s: float) -> dict:
    log_path = log_dir / f"{name}.log"
    cmd = ["godot", "--headless", f"res://tools/{name}.tscn"]
    started = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        cwd=str(repo),
        stdout=open(log_path, "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True,  # own process group ⇒ clean kill
    )
    cpu0 = proc_cpu_s(proc.pid)
    timed_out = False
    stuck = False
    last_size = -1
    last_cpu = cpu0
    cpu_final = cpu0  # last live sample — /proc is gone once the proc reaps
    idle_since: float | None = None
    reaped_rusage = None
    while True:
        waited = os.wait4(proc.pid, os.WNOHANG)
        if waited[0] == proc.pid:
            reaped_rusage = waited[2]
            proc.returncode = os.waitstatus_to_exitcode(waited[1])
            break
        if time.monotonic() - started >= timeout_s:
            timed_out = True
            break
        # stuck detection (§13): no log growth AND no per-process CPU
        # advance (exact via /proc, unlike the process-global rusage
        # counter which is noisy under parallel jobs)
        try:
            size = log_path.stat().st_size
        except OSError:
            size = last_size
        cpu = proc_cpu_s(proc.pid)
        grew = size != last_size or cpu - last_cpu >= STUCK_CPU_S
        last_size, last_cpu = size, cpu
        cpu_final = cpu
        if grew:
            idle_since = None
        elif idle_since is None:
            idle_since = time.monotonic()
        elif time.monotonic() - idle_since >= STUCK_IDLE_S:
            stuck = True
            break
        time.sleep(POLL_S)
    if reaped_rusage is None and proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        try:
            waited = os.wait4(proc.pid, 0)
            reaped_rusage = waited[2]
            proc.returncode = os.waitstatus_to_exitcode(waited[1])
        except ChildProcessError:
            proc.wait()
    wall_ms = int((time.monotonic() - started) * 1000)
    if reaped_rusage is not None:
        # exact per-child CPU from the kernel at reap time
        cpu_ms = int((reaped_rusage.ru_utime + reaped_rusage.ru_stime) * 1000)
    else:
        cpu_ms = int(max(cpu_final - cpu0, 0.0) * 1000)
    log_text = log_path.read_text(errors="replace")
    kind = classify(proc.returncode, log_text, timed_out, stuck)
    return {
        "suite": name,
        "class": kind,
        "exit": proc.returncode,
        "wall_ms": wall_ms,
        "cpu_ms": cpu_ms,
        "slow": wall_ms > SLOW_WALL_MS,
        "profiles": {k: int(v) for k, v in PROFILE_RE.findall(log_text)},
        "log": str(log_path),
        "detail": ("timeout" if timed_out else "stuck-idle") if kind in ("ZOMBIE", "HANG") else "",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("-j", "--jobs", type=int, default=DEFAULT_JOBS)
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    ap.add_argument("--out", default="", help="optional JSON report path")
    ap.add_argument("--log-dir", default="/tmp/opencode/test_logs")
    ap.add_argument("--only", default="",
                    help="run suites whose name contains this substring")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    suites = sorted(p.stem for p in (repo / "tools").glob("test_*.tscn"))
    if args.only:
        suites = [s for s in suites if args.only in s]
    if not suites:
        print("no suites found under", repo / "tools")
        return 2
    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    for old in log_dir.glob("*.log"):
        old.unlink()

    serial = [s for s in suites if s in SERIAL_SAVE_SET]
    parallel = [s for s in suites if s not in SERIAL_SAVE_SET]
    results: list[dict] = []
    t0 = time.monotonic()
    for name in serial:
        results.append(run_one(name, repo, log_dir, args.timeout))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_one, n, repo, log_dir, args.timeout): n for n in parallel}
        for fut in concurrent.futures.as_completed(futures):
            results.append(fut.result())
    results.sort(key=lambda r: -r["wall_ms"])

    red = [r for r in results if r["class"] == "RED"]
    stuck = [r for r in results if r["class"] in ("ZOMBIE", "HANG")]
    print(f"\n{'suite':<28} {'class':<7} {'wall':>8} {'cpu':>8}  flags")
    for r in results:
        flags = " slow" if r["slow"] else ""
        flags += f" {r['detail']}" if r["detail"] else ""
        prof = " ".join(f"{k}={v}ms" for k, v in r["profiles"].items())
        if prof:
            flags += f" | {prof}"
        print(f"{r['suite']:<28} {r['class']:<7} {r['wall_ms']:>7}ms {r['cpu_ms']:>7}ms {flags}")
    print(f"\n{len(results)} suites in {time.monotonic() - t0:.1f}s · "
          f"green={sum(1 for r in results if r['class'] == 'GREEN')} "
          f"red={len(red)} zombie/hang={len(stuck)} · logs: {log_dir}")
    if args.out:
        Path(args.out).write_text(json.dumps(results, indent=2))
    if stuck:
        return 2
    if red:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
