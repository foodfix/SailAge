#!/usr/bin/env python3
"""SailAge model studio — local web UI so the user can re-roll
model-generated art themselves: edit prompts, re-roll, accept.

Single-page vanilla HTML/JS/CSS frontend + JSON API over stdlib
http.server (ThreadingHTTPServer). Generation jobs run ONE at a time in a
background worker thread (~40 s each) fed by a FIFO queue.

Services (localhost): thenoise :8001 (/edit, the image model) and ComfyUI
:8000 (rembg). This server binds 127.0.0.1:8010 — no auth, local tool.

The --repo argument points at the MAIN SailAge repo: drafts/, progress.json,
report.json and validate_data.py are read from there, and the studio cache
(model_raw/studio/** — gitignored) is written there too. Canonical
gen//snapped/ are NEVER written; only tools/model_studio/** is committed.

API:
  GET  /                     single-page UI
  GET  /api/jobs             registry + studio state merged (+flagged list)
  POST /api/reroll           {job, prompt?, seed?} — persists prompt, queues
  POST /api/accept           {job} — marks the current result accepted
  POST /api/prompt           {job, prompt} — persist a prompt edit alone
  GET  /api/status           worker state, queue, current job
  GET  /thumb/<kind>/<job>   draft | raw | snapped PNG (cache-busting ?v=)

Launch:
  python3 tools/model_studio/server.py --port 8010 --repo /home/weidong/repo/SailAge
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import chain  # noqa: E402  (model_studio.chain — worktree copy)

WWW = os.path.join(_HERE, "www")
JOB_RE = re.compile(r"^[a-z0-9_]+$")
MIRROR_OF = {"e": "w", "ne": "nw", "se": "sw"}  # doc f6c00bb: mirror-derived
FAMILIES = ("hull", "icon", "terrain")
STORES = ("prompts.json", "state.json", "accepted.json")


def log(msg: str) -> None:
    print(f"[studio {time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Studio:
    """Registry + persisted studio state + the single generation worker."""

    def __init__(self, repo: str):
        self.repo = repo
        self.lock = threading.RLock()
        self.queue: list[dict] = []          # pending reroll orders
        self.current: dict | None = None     # running job info
        self.qcond = threading.Condition(self.lock)
        self.load_driver()

    # -- paths ----------------------------------------------------------
    def raw(self) -> str:
        return os.path.join(self.repo, "tools", "ui_art", "model_raw")

    def studio(self) -> str:
        return os.path.join(self.raw(), "studio")

    def _json_path(self, name: str) -> str:
        return os.path.join(self.studio(), name)

    # -- atomic json stores ---------------------------------------------
    def _read_json(self, path: str, default):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return default

    def _write_json(self, path: str, data) -> None:
        chain.atomic_write(path, json.dumps(data, indent=1).encode("utf-8"))

    def load_driver(self) -> None:
        chain.init(self.repo)
        self.driver = chain.load_driver(self.repo)
        self.report = self._read_json(
            os.path.join(self.raw(), "report.json"), {})

    def prompts(self) -> dict:
        return self._read_json(self._json_path("prompts.json"), {})

    def state(self) -> dict:
        return self._read_json(self._json_path("state.json"),
                               {"jobs": {}, "updated_at": None})

    def accepted(self) -> dict:
        return self._read_json(self._json_path("accepted.json"), {})

    def save_prompts(self, data: dict) -> None:
        self._write_json(self._json_path("prompts.json"), data)

    def save_state(self, data: dict) -> None:
        data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        self._write_json(self._json_path("state.json"), data)

    def save_accepted(self, data: dict) -> None:
        self._write_json(self._json_path("accepted.json"), data)

    # -- registry ---------------------------------------------------------
    def registry(self) -> list[dict]:
        """Enumerate jobs from the store's drafts/ and merge canonical +
        studio state. Rebuilt per /api/jobs call (cheap; the other agents
        may rewrite progress/report concurrently)."""
        drafts_dir = os.path.join(self.raw(), "drafts")
        prog = self._read_json(os.path.join(self.raw(), "progress.json"),
                               {}).get("jobs", {})
        report = self._read_json(os.path.join(self.raw(), "report.json"), {})
        band_tbl = report.get("band_table", {})
        with self.lock:
            prompts = self.prompts()
            state = self.state().get("jobs", {})
            accepted = self.accepted()
        jobs = []
        for fname in sorted(os.listdir(drafts_dir)):
            if not fname.endswith(".png"):
                continue
            job_id = fname[:-4]
            if not JOB_RE.match(job_id):
                continue
            fam, subject, direction = chain.parse_job(job_id)
            canon = prog.get(job_id, {})
            studio_rec = state.get(job_id, {})
            metrics = studio_rec.get("metrics") or canon.get("metrics")

            tier = self.driver["TIER"].get(subject) if fam == "hull" else None
            band_info, in_band = None, None
            if fam == "hull" and direction in ("e", "w"):
                m_band = (metrics or {}).get("band")
                if m_band:
                    band_info, in_band = m_band.get("band"), \
                        m_band.get("in_band")
                else:
                    for d in band_tbl.get(subject, {}).get("dirs", []):
                        if d["dir"] == direction:
                            band_info = d  # report fallback
                            in_band = d.get("in_band")
                            break
            pennant_ok = None
            if fam == "hull":
                if metrics and "pennant_present" in metrics:
                    pennant_ok = bool(metrics["pennant_present"])
                else:
                    pennant_ok = job_id not in report.get("pennant",
                                                          {}).get(
                                                              "absent_ids", [])
            flagged = False
            if fam == "hull":
                flagged = ((direction in ("e", "w") and in_band is False)
                           or pennant_ok is False)

            dirs_for = {
                "draft": [os.path.join(self.raw(), "drafts")],
                "raw": [os.path.join(self.studio(), "gen"),
                        os.path.join(self.raw(), "gen")],
                "snapped": [os.path.join(self.studio(), "snapped"),
                            os.path.join(self.raw(), "snapped")],
            }
            thumbs = {}
            for kind, dirs in dirs_for.items():
                for d in dirs:
                    p = os.path.join(d, job_id + ".png")
                    if os.path.exists(p):
                        thumbs[kind] = {"v": int(os.path.getmtime(p) * 1000)}
                        break

            eff_prompt = prompts.get(job_id) or chain.default_prompt(
                job_id, self.repo)
            jobs.append({
                "id": job_id,
                "family": fam,
                "subject": subject,
                "dir": direction,
                "tier": tier,
                "label": (f"T{tier} · {subject} · {direction}"
                          if fam == "hull" else
                          (f"icon · {subject}" if fam == "icon"
                           else f"terrain · {subject}")),
                "mirror_of": MIRROR_OF.get(direction) if fam == "hull"
                else None,
                "band": ({"band": band_info if isinstance(band_info, list)
                          else (band_info or {}).get("band"),
                          "long_axis_px":
                              metrics.get("band", {}).get("long_axis_px")
                              if metrics and "band" in metrics
                              else band_info.get("long_axis")
                              if isinstance(band_info, dict) else None,
                          "in_band": in_band}
                         if fam == "hull" and direction in ("e", "w")
                         else None),
                "pennant_ok": pennant_ok,
                "flagged": flagged,
                "accepted": accepted.get(job_id),
                "prompt": eff_prompt,
                "custom_prompt": job_id in prompts,
                "seed": studio_rec.get("seed", canon.get("seed")),
                "canonical_seed": chain.canonical_seed(job_id, self.repo),
                "status": studio_rec.get("status", canon.get("status")),
                "status_source": "studio" if studio_rec else "canonical",
                "metrics": metrics,
                "seconds": studio_rec.get("seconds", canon.get("seconds")),
                "error": studio_rec.get("error"),
                "thumbs": thumbs,
            })
        counts = {f: sum(1 for j in jobs if j["family"] == f)
                  for f in FAMILIES}
        flagged_ids = [j["id"] for j in jobs if j["flagged"]]
        return jobs, counts, flagged_ids

    # -- worker -----------------------------------------------------------
    def start_worker(self) -> None:
        th = threading.Thread(target=self._worker, name="studio-worker",
                              daemon=True)
        th.start()

    def enqueue(self, job_id: str, prompt: str | None, seed: int | None) -> int:
        with self.lock:
            if prompt:
                prompts = self.prompts()
                prompts[job_id] = prompt
                self.save_prompts(prompts)
            self.queue.append({"job": job_id, "seed": seed})
            pos = len(self.queue)
            self.qcond.notify_all()
        log(f"queued {job_id} (position {pos})")
        return pos

    def _worker(self) -> None:
        while True:
            with self.lock:
                while not self.queue:
                    self.qcond.wait()
                order = self.queue.pop(0)
                job_id = order["job"]
                prompt = self.prompts().get(job_id) \
                    or chain.default_prompt(job_id, self.repo)
                seed = order["seed"] if order["seed"] is not None \
                    else chain.random_seed()
                self.current = {"job": job_id, "prompt": prompt,
                                "seed": seed, "stage": "starting",
                                "started_epoch": time.time()}
            log(f"generating {job_id} seed={seed}")
            rec = {"prompt": prompt, "seed": seed, "status": "running",
                   "started_at": time.strftime("%H:%M:%S")}
            try:
                def stage(name: str) -> None:
                    with self.lock:
                        if self.current and self.current["job"] == job_id:
                            self.current["stage"] = name

                result = chain.run_job(job_id, prompt, seed, on_stage=stage)
                rec.update(result)
                fam, subject, direction = chain.parse_job(job_id)
                metrics = rec.get("metrics") or {}
                band = metrics.get("band")
                if fam == "hull" and direction in ("e", "w") and band \
                        and not band.get("in_band"):
                    rec["status"] = "band-fail"
                else:
                    rec["status"] = "done"
            except Exception as exc:  # noqa: BLE001 — surface in the UI
                rec["status"] = "error"
                rec["error"] = f"{type(exc).__name__}: {exc}"
                log(f"FAILED {job_id}: {exc}")
            with self.lock:
                self.current = None
                st = self.state()
                st.setdefault("jobs", {})[job_id] = rec
                self.save_state(st)
            log(f"finished {job_id}: {rec['status']} "
                f"({rec.get('seconds', '?')}s)")


class Handler(BaseHTTPRequestHandler):
    studio: Studio = None  # injected in main()
    server_version = "SailAgeModelStudio/1.0"

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):  # stdout request log
        log(f"{self.address_string()} {fmt % args}")

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj, indent=1).encode("utf-8"),
                   "application/json; charset=utf-8")

    def _payload(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 1 << 20:
            return {}
        try:
            data = json.loads(self.rfile.read(n))
            return data if isinstance(data, dict) else {}
        except ValueError:
            return {}

    def _static(self, rel: str, ctype: str) -> None:
        path = os.path.join(WWW, rel)
        if not os.path.isfile(path):
            self._json(404, {"error": "not found"})
            return
        with open(path, "rb") as fh:
            self._send(200, fh.read(), ctype)

    # -- routes -----------------------------------------------------------
    def do_GET(self):  # noqa: N802 — stdlib naming
        path = urllib.request.urlparse(self.path).path
        try:
            if path in ("/", "/index.html"):
                self._static("index.html", "text/html; charset=utf-8")
            elif path == "/studio.js":
                self._static("studio.js",
                             "application/javascript; charset=utf-8")
            elif path == "/studio.css":
                self._static("studio.css", "text/css; charset=utf-8")
            elif path == "/favicon.ico":
                self._send(204, b"", "image/x-icon")
            elif path == "/api/jobs":
                jobs, counts, flagged = self.studio.registry()
                with self.studio.lock:
                    cur = dict(self.studio.current) if self.studio.current \
                        else None
                    queue = [o["job"] for o in self.studio.queue]
                self._json(200, {"jobs": jobs, "counts": counts,
                                 "flagged": flagged, "queue": queue,
                                 "current": cur})
            elif path == "/api/status":
                with self.studio.lock:
                    cur = dict(self.studio.current) if self.studio.current \
                        else None
                    queue = [o["job"] for o in self.studio.queue]
                self._json(200, {"worker": "busy" if cur else "idle",
                                 "current": cur, "queue": queue,
                                 "repo": self.studio.repo})
            elif path.startswith("/thumb/"):
                self._thumb(path)
            else:
                self._json(404, {"error": "not found"})
        except BrokenPipeError:
            pass
        except Exception as exc:  # noqa: BLE001 — per-request guard
            log(f"GET {path} failed: {type(exc).__name__}: {exc}")
            self._json(500, {"error": str(exc)})

    def _thumb(self, path: str) -> None:
        # /thumb/<kind>/<job>.png  (draft | raw | snapped; raw prefers the
        # studio reroll, snapped falls back to the canonical store)
        m = re.match(r"^/thumb/(draft|raw|snapped)/([a-z0-9_]+)\.png$",
                     path)
        if not m:
            self._json(404, {"error": "bad thumb path"})
            return
        kind, job_id = m.group(1), m.group(2)
        if kind == "draft":
            candidates = [chain.canonical_path("drafts", job_id)]
        elif kind == "raw":
            candidates = [chain.studio_path("gen", job_id),
                          chain.canonical_path("gen", job_id)]
        else:
            candidates = [chain.studio_path("snapped", job_id),
                          chain.canonical_path("snapped", job_id)]
        for p in candidates:
            if os.path.isfile(p):
                with open(p, "rb") as fh:
                    self._send(200, fh.read(), "image/png")
                return
        self._json(404, {"error": f"no {kind} thumb for {job_id}"})

    def do_POST(self):  # noqa: N802 — stdlib naming
        path = urllib.request.urlparse(self.path).path
        try:
            data = self._payload()
            if path == "/api/reroll":
                self._reroll(data)
            elif path == "/api/accept":
                self._accept(data)
            elif path == "/api/prompt":
                self._prompt(data)
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:  # noqa: BLE001 — per-request guard
            log(f"POST {path} failed: {type(exc).__name__}: {exc}")
            self._json(500, {"error": str(exc)})

    def _job_ok(self, job_id: str) -> bool:
        return bool(job_id and JOB_RE.match(job_id) and os.path.isfile(
            chain.canonical_path("drafts", job_id)))

    def _reroll(self, data: dict) -> None:
        job_id = data.get("job", "")
        if not self._job_ok(job_id):
            self._json(404, {"error": f"unknown job {job_id!r}"})
            return
        prompt = data.get("prompt")
        seed = data.get("seed")
        if seed is not None and not isinstance(seed, int):
            try:
                seed = int(str(seed).strip())
            except ValueError:
                seed = None
        if prompt is not None:
            prompt = str(prompt).strip() or None
        pos = self.studio.enqueue(job_id, prompt, seed)
        self._json(202, {"ok": True, "queued": job_id, "position": pos})

    def _prompt(self, data: dict) -> None:
        job_id = data.get("job", "")
        prompt = str(data.get("prompt") or "").strip()
        if not self._job_ok(job_id):
            self._json(404, {"error": f"unknown job {job_id!r}"})
            return
        with self.studio.lock:
            prompts = self.studio.prompts()
            if prompt:
                prompts[job_id] = prompt
            else:
                prompts.pop(job_id, None)  # empty -> back to canonical
            self.studio.save_prompts(prompts)
        self._json(200, {"ok": True, "job": job_id, "custom": bool(prompt)})

    def _accept(self, data: dict) -> None:
        job_id = data.get("job", "")
        if not self._job_ok(job_id):
            self._json(404, {"error": f"unknown job {job_id!r}"})
            return
        st = None
        with self.studio.lock:
            st = self.studio.state().get("jobs", {}).get(job_id)
            acc = self.studio.accepted()
            source = ("studio" if os.path.isfile(
                chain.studio_path("gen", job_id)) else "canonical")
            acc[job_id] = {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "source": source,
                "seed": (st or {}).get("seed"),
                "prompt": (st or {}).get("prompt"),
            }
            self.studio.save_accepted(acc)
        log(f"accepted {job_id} ({source})")
        self._json(200, {"ok": True, "job": job_id, "accepted":
                         acc[job_id]})


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description="SailAge model studio")
    ap.add_argument("--port", type=int, default=8010)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--repo", default="/home/weidong/repo/SailAge",
                    help="MAIN repo root (drafts/progress/report inputs "
                         "+ studio cache)")
    args = ap.parse_args(argv)

    studio = Studio(args.repo)
    Handler.studio = studio
    studio.start_worker()

    jobs, counts, flagged = studio.registry()
    log(f"registry: {len(jobs)} jobs {counts}; flagged={len(flagged)}")
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    log(f"listening on http://{args.host}:{args.port} (repo={args.repo})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("bye")


if __name__ == "__main__":
    main()
