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
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import chain  # noqa: E402  (model_studio.chain — worktree copy)

WWW = os.path.join(_HERE, "www")
JOB_RE = re.compile(r"^[a-z0-9_]+$")
MIRROR_OF = {"e": "w", "ne": "nw", "se": "sw"}  # doc f6c00bb: mirror-derived
FAMILIES = ("pxship", "hull", "sheet", "icon", "iconsheet", "terrain")
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
        self._thumb_cache: "OrderedDict[str, bytes]" = OrderedDict()
        self.last_warnings: list[str] = []   # registry skip/degrade notes
        self._icon_groups_cache: dict[str, list[str]] = {}
        self._icon_groups_at: float = 0.0
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
    # -- thumbnails -------------------------------------------------------
    def _px_entry(self, label, prompts, state, accepted):
        """One pixellab ship card (the §4.8 2026-11-06 ship family):
        8 native rotations, ship-as-drawn — no band/pennant gates (all
        retired). The card's strip thumbs are per-dir (snapped preferred,
        raw rotation fallback); provenance rides the tool manifest
        (object_id/seed/description)."""
        job_id = f"px_{label}"
        manifest = chain.px_manifest().get(label) or {}
        studio_rec = state.get(job_id, {}) or {}
        # per-dir strip thumbs: {dir: mtime-version}; snapped wins over the
        # raw rotation (the snapped set is what ships)
        mod = chain._px_mod()
        rot_to_dir = mod.DIR_MAP  # rotation file stem -> heading8 dir id
        rotations = []
        for d in chain.px_dirs(label):
            v = 0
            for rot, dir_id in rot_to_dir.items():
                if dir_id != d:
                    continue
                for sub in ("snapped", ""):
                    p = os.path.join(chain.px_dir(), label, sub,
                                     f"{rot}.png")
                    if os.path.isfile(p):
                        v = int(os.path.getmtime(p) * 1000)
                        break
                break
            rotations.append({"dir": d, "v": v})
        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt")
                           or manifest.get("description"))
        if stored_original:
            original_prompt = stored_original
            original_source = (studio_rec.get("original_prompt_source")
                               or "manifest")
        else:
            original_prompt = chain.px_default_prompt(label)
            original_source = "canonical"
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
            "id": job_id,
            "family": "pxship",
            "subject": label,
            "ship": chain.px_ship_of(label),
            "dir": None,
            "rotations": rotations,
            "object_id": manifest.get("object_id"),
            "tier": None,
            "label": f"{label} · {len(rotations)}/8 rotations · "
                     f"~$0.05/roll",
            "mirror_of": None,
            "band": None,
            "pennant_ok": None,
            "flagged": False,
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": eff_prompt,
            "original_prompt": original_prompt,
            "original_prompt_source": original_source,
            "custom_prompt": job_id in prompts,
            "seed": studio_rec.get("seed", manifest.get("seed")),
            "canonical_seed": manifest.get("seed"),
            "status": studio_rec.get("status",
                                     "canonical" if manifest else None),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": None,
            "seconds": studio_rec.get("seconds"),
            "error": studio_rec.get("error"),
            "thumbs": {},
        }

    def _sheet_entry(self, job_id, subject, prog, prompts, state, accepted,
                     seed_map):
        """Per-hull 5-cell sheet job card (batch-refactor shape). The
        progress/ledger key is `hull_<hull>`; the driver crops per-dir
        snapped files under the legacy canonical paths. The band-gated
        cell is `w` — the card's band/pennant/flag ride it, and the
        snapped thumbnail shows the w crop (representative cell)."""
        prog_key = f"hull_{subject}"
        canon = prog.get(prog_key, {}) or {}
        studio_rec = state.get(job_id, {}) or {}
        try:
            per_dir = (studio_rec.get("per_dir") or canon.get("per_dir")
                       or {}) or {}
            wmet = (per_dir.get("w") or {}).get("metrics") or {}
        except Exception:  # noqa: BLE001 — progress shape mid-refactor
            per_dir, wmet = {}, {}
        try:
            tier = self.driver["TIER"].get(subject)
        except Exception:  # noqa: BLE001
            tier = None
        in_band = (wmet.get("band") or {}).get("in_band") \
            if wmet.get("band") else None
        pennant_ok = wmet.get("pennant_present")
        flagged = (in_band is False) or (pennant_ok is False)

        thumbs = {}
        for kind in ("draft", "raw", "snapped"):
            for path, mirrored in self.thumb_candidates(kind, job_id):
                if os.path.isfile(path):
                    thumbs[kind] = {"v": int(os.path.getmtime(path) * 1000)}
                    break

        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt"))
        if stored_original:
            original_prompt = stored_original
            original_source = (studio_rec.get("original_prompt_source")
                               or "exact")
        else:
            original_prompt, original_source = chain.reconstruct_original(
                job_id, self.repo, rec=canon or None)
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
            "id": job_id,
            "family": "sheet",
            "subject": subject,
            "dir": None,
            "tier": tier,
            "label": f"sheet · {subject} · 5 views",
            "mirror_of": None,
            "band": ({"band": (wmet.get("band") or {}).get("band"),
                      "long_axis_px":
                          (wmet.get("band") or {}).get("long_axis_px"),
                      "in_band": in_band}
                     if wmet.get("band") else None),
            "pennant_ok": pennant_ok,
            "flagged": flagged,
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": eff_prompt,
            "original_prompt": original_prompt,
            "original_prompt_source": original_source,
            "custom_prompt": job_id in prompts,
            "seed": studio_rec.get("seed", canon.get("seed")),
            "canonical_seed": seed_map.get(job_id),
            "status": studio_rec.get("status", canon.get("status")),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": wmet or None,
            "seconds": studio_rec.get("seconds", canon.get("seconds")),
            "error": studio_rec.get("error"),
            "thumbs": thumbs,
        }

    def _icon_groups(self) -> dict[str, list[str]]:
        """Group -> icon ids (chain's replication of the driver's
        icon_group_definitions), cached 60 s (manifests drift mid-flight)."""
        now = time.time()
        if self._icon_groups_at and now - self._icon_groups_at < 60:
            return self._icon_groups_cache
        try:
            self._icon_groups_cache = dict(chain.icon_group_definitions(
                self.repo))
        except Exception as exc:  # noqa: BLE001 — degraded listing
            log(f"icon group definitions failed: {exc}")
            self._icon_groups_cache = {}
        self._icon_groups_at = now
        return self._icon_groups_cache

    def _iconsheet_entry(self, job_id, subject, prog, prompts, state,
                         accepted, seed_map):
        """Icon GROUP sheet card (12 families). Progress/ledger key is
        `icons_<group>`; the driver (and the studio chain) write per-icon
        canonical snapped files, so the snapped thumb shows the group's
        first icon crop."""
        prog_key = f"icons_{subject}"
        canon = prog.get(prog_key, {}) or {}
        studio_rec = state.get(job_id, {}) or {}
        ids = self._icon_groups().get(subject) or []
        n = len(ids) or len(canon.get("ids") or [])
        thumbs = {}
        for kind in ("draft", "raw", "snapped"):
            for path, _mirrored in self.thumb_candidates(kind, job_id):
                if os.path.isfile(path):
                    thumbs[kind] = {"v": int(os.path.getmtime(path) * 1000)}
                    break
        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt"))
        if stored_original:
            original_prompt = stored_original
            original_source = (studio_rec.get("original_prompt_source")
                               or "exact")
        else:
            original_prompt, original_source = chain.reconstruct_original(
                job_id, self.repo, rec=canon or None)
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
            "id": job_id,
            "family": "iconsheet",
            "subject": subject,
            "dir": None,
            "tier": None,
            "label": f"ICON SHEET · {subject} · {n} icons",
            "mirror_of": None,
            "band": None,
            "pennant_ok": None,
            "flagged": False,
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": eff_prompt,
            "original_prompt": original_prompt,
            "original_prompt_source": original_source,
            "custom_prompt": job_id in prompts,
            "seed": studio_rec.get("seed", canon.get("seed")),
            "canonical_seed": seed_map.get(job_id),
            "status": studio_rec.get("status", canon.get("status")),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": None,
            "seconds": studio_rec.get("seconds", canon.get("seconds")),
            "error": studio_rec.get("error"),
            "thumbs": thumbs,
        }

    def thumb_candidates(self, kind: str, job_id: str):
        """Ordered (path, mirrored_base) candidates for one thumb slot.
        `mirrored_base` set => serve that file horizontally flipped (the
        ingestion's mirror_x) when the job's own file is missing — e/ne/se
        files can disappear whenever the 5-dir canonical round prunes the
        store; terrain has no snapped artifact (its gen sheet IS the
        artifact). Never 404 on a listed job's thumbs."""
        fam, subject, direction = chain.parse_job(job_id)
        raw, st = self.raw(), self.studio()
        if fam == "iconsheet":
            # group card: draft = sheet draft, raw = generated sheet,
            # snapped = the group's first icon crop (representative)
            first = (self._icon_groups().get(subject) or [""])[0]
            out = []
            if kind == "draft":
                out.append((os.path.join(raw, "drafts", job_id + ".png"),
                            None))
            elif kind == "raw":
                out.append((os.path.join(st, "gen", job_id + ".png"), None))
                out.append((os.path.join(raw, "gen", job_id + ".png"), None))
            elif kind == "snapped" and first:
                out.append((os.path.join(st, "snapped",
                                         f"icon_{first}.png"), None))
                out.append((os.path.join(raw, "snapped",
                                         f"icon_{first}.png"), None))
            return out
        if fam == "sheet":
            # sheet card: draft = the 5-cell reference sheet, raw = the
            # generated sheet, snapped = the band-gated w crop (the
            # representative cell; the other 4 crops live at their legacy
            # per-dir paths)
            out = []
            if kind == "draft":
                out.append((os.path.join(raw, "drafts", job_id + ".png"),
                            None))
            elif kind == "raw":
                out.append((os.path.join(st, "gen", job_id + ".png"), None))
                out.append((os.path.join(raw, "gen",
                                         f"hull_{subject}_sheet.png"), None))
            elif kind == "snapped":
                out.append((os.path.join(st, "snapped",
                                         f"hull_{subject}_w.png"), None))
                out.append((os.path.join(raw, "snapped",
                                         f"hull_{subject}_w.png"), None))
            return out
        mirror_of = MIRROR_OF.get(direction) if fam == "hull" else None
        out = []
        if kind == "draft":
            out.append((os.path.join(raw, "drafts", job_id + ".png"), None))
            if mirror_of:
                out.append((os.path.join(raw, "drafts",
                                         f"hull_{subject}_{mirror_of}.png"),
                            mirror_of))
        elif kind == "raw":
            out.append((os.path.join(st, "gen", job_id + ".png"), None))
            out.append((os.path.join(raw, "gen", job_id + ".png"), None))
            if mirror_of:
                out.append((os.path.join(st, "gen",
                                         f"hull_{subject}_{mirror_of}.png"),
                            mirror_of))
                out.append((os.path.join(raw, "gen",
                                         f"hull_{subject}_{mirror_of}.png"),
                            mirror_of))
        elif kind == "snapped":
            out.append((os.path.join(st, "snapped", job_id + ".png"), None))
            out.append((os.path.join(raw, "snapped", job_id + ".png"), None))
            if mirror_of:
                out.append((os.path.join(st, "snapped",
                                         f"hull_{subject}_{mirror_of}.png"),
                            mirror_of))
                out.append((os.path.join(raw, "snapped",
                                         f"hull_{subject}_{mirror_of}.png"),
                            mirror_of))
            if fam == "terrain":
                # the normalized 1024x512 gen sheet is the terrain artifact
                out.append((os.path.join(st, "gen", job_id + ".png"), None))
                out.append((os.path.join(raw, "gen", job_id + ".png"), None))
        return out

    def _thumb_cache_get(self, key: str):
        with self.lock:
            data = self._thumb_cache.get(key)
            if data is not None:
                self._thumb_cache.move_to_end(key)
            return data

    def _thumb_cache_put(self, key: str, data: bytes) -> None:
        with self.lock:
            self._thumb_cache[key] = data
            while len(self._thumb_cache) > 600:  # bounded; PNG thumbs only
                self._thumb_cache.popitem(last=False)

    def px_dir_thumb(self, label: str, dir_id: str):
        """(bytes | None) — one strip cell for a pixellab ship: the
        snapped token preferred, the raw rotation fallback, shared thumb
        cache (path|mtime key — cache busts itself on re-roll)."""
        mod = chain._px_mod()
        rot = next((r for r, d in mod.DIR_MAP.items() if d == dir_id), None)
        if rot is None:
            return None
        base = os.path.join(chain.px_dir(), label)
        for name in (os.path.join("snapped", f"{dir_id}.png"),
                     f"{rot}.png"):
            p = os.path.join(base, name)
            if not os.path.isfile(p):
                continue
            key = f"{p}|{os.path.getmtime(p)}"
            data = self._thumb_cache_get(key)
            if data is None:
                with open(p, "rb") as fh:
                    data = fh.read()
                self._thumb_cache_put(key, data)
            return data
        return None

    def thumb_bytes(self, kind: str, job_id: str):
        """(bytes, mirrored_base | None, direct: bool) — flips through the
        in-memory cache keyed by source path+mtime so browser bursts don't
        re-decode/re-encode mirrored PNGs."""
        try:
            candidates = self.thumb_candidates(kind, job_id)
        except KeyError:
            return None, None, False
        direct_seen = False
        for path, mirrored in candidates:
            if not os.path.isfile(path):
                continue
            if mirrored is None:
                direct_seen = True
            mtime = os.path.getmtime(path)
            key = f"{path}|{mtime}|{'flip' if mirrored else 'raw'}"
            data = self._thumb_cache_get(key)
            if data is None:
                with open(path, "rb") as fh:
                    data = fh.read()
                if mirrored:
                    try:
                        data = chain.flip_x(data)
                    except Exception as exc:  # noqa: BLE001 — next candidate
                        log(f"flip failed for {path}: {exc}")
                        continue
                self._thumb_cache_put(key, data)
            return data, mirrored, direct_seen
        return None, None, False

    # -- registry ---------------------------------------------------------
    def _seed_map(self) -> dict:
        """canonical seed per job, computed in ONE pass (manifests read
        once instead of per job). Tolerant to torn manifest reads."""
        try:
            d = self.driver
            icons_dir = os.path.join(self.repo, "tools", "ui_art", "icons")
            manifests = {}
            if os.path.isdir(icons_dir):
                for path in sorted(os.listdir(icons_dir)):
                    if not path.endswith(".json"):
                        continue
                    try:
                        with open(os.path.join(icons_dir, path),
                                  encoding="utf-8") as fh:
                            doc = json.load(fh)
                    except (OSError, ValueError):
                        continue
                    sprites = doc if isinstance(doc, list) \
                        else doc.get("sprites", [])
                    for s in sprites:
                        manifests[s["id"]] = s
            ids = [i for i in d["ICON_PRIORITY"] if i in manifests]
            ids += [i for i in sorted(manifests) if i not in set(ids)]
            order = ([f"hull_{h}_{dr}" for h in d["HULLS"]
                      for dr in d["DIRS"]]
                     + [f"terrain_{k}" for k in d["TERRAIN_KEYS"]]
                     + [f"icon_{i}" for i in ids[:129]])
            return {job: 1000 + i for i, job in enumerate(order)}
        except Exception as exc:  # noqa: BLE001 — informational only
            log(f"seed map failed: {exc}")
            return {}

    def registry(self) -> list[dict]:
        """Enumerate jobs from the store's drafts/ and merge canonical +
        studio state. NEVER raises: per-job guard wraps entry AND fallback
        construction — an unparseable job id (driver mid-refactor shapes)
        is skipped with a warning, never a 500."""
        warnings: list[str] = []
        drafts_dir = os.path.join(self.raw(), "drafts")
        prog = self._read_json(os.path.join(self.raw(), "progress.json"),
                               {}).get("jobs", {})
        report = self._read_json(os.path.join(self.raw(), "report.json"), {})
        with self.lock:
            prompts = self.prompts()
            state = self.state().get("jobs", {})
            accepted = self.accepted()
        seed_map = self._seed_map()
        jobs = []
        # The pixellab ship family leads the registry (§4.8 2026-11-06);
        # fleet labels only (≥1 snapped rotation — trial dirs stay hidden).
        for label in chain.px_fleet_labels():
            try:
                jobs.append(self._px_entry(label, prompts, state, accepted))
            except Exception as exc:  # noqa: BLE001 — degrade, never die
                warnings.append(f"px_{label}: {type(exc).__name__}: {exc}")
                log(f"registry SKIP px_{label}: {warnings[-1]}")
        try:
            draft_names = sorted(os.listdir(drafts_dir))
        except OSError as exc:
            log(f"drafts dir unreadable: {exc}")
            draft_names = []
        for fname in draft_names:
            if not fname.endswith(".png"):
                continue
            job_id = fname[:-4]
            if not JOB_RE.match(job_id):
                continue
            try:
                fam = chain.parse_job(job_id)[0]
            except KeyError:
                fam = None
            if fam in ("hull", "sheet"):
                # the classic ship jobs are HIDDEN entirely (user
                # direction, 2026-11-06): their retired local chain must
                # not be re-rollable or visible
                continue
            try:
                jobs.append(self._job_entry(job_id, prog, report, prompts,
                                            state, accepted, seed_map))
            except Exception as exc:  # noqa: BLE001 — degrade, don't die
                reason = f"{type(exc).__name__}: {exc}"
                # even the fallback card must never raise
                try:
                    fallback = {
                        "id": job_id, "family": job_id.split("_", 1)[0],
                        "subject": None, "dir": None, "tier": None,
                        "label": job_id, "mirror_of": None, "band": None,
                        "pennant_ok": None, "flagged": False,
                        "accepted": accepted.get(job_id),
                        "prompt": chain.default_prompt(job_id, self.repo),
                        "original_prompt": "",
                        "original_prompt_source": "default",
                        "custom_prompt": job_id in prompts, "seed": None,
                        "canonical_seed": seed_map.get(job_id),
                        "status": None, "status_source": "canonical",
                        "ingest": None, "metrics": None, "seconds": None,
                        "error": None, "thumbs": {},
                    }
                    jobs.append(fallback)
                except Exception as exc2:  # noqa: BLE001 — skip + warn
                    warnings.append(f"{job_id}: {reason} "
                                    f"(fallback also failed: {exc2})")
                    log(f"registry SKIP {job_id}: {warnings[-1]}")
                    continue
                log(f"registry entry {job_id} degraded: {reason}")
        self.last_warnings = warnings
        # backfill: persist each legacy job's original prompt ONCE, so the
        # edit base stays stable across driver drift and "↺ original" is
        # byte-identical. Exact originals are already in state.json (written
        # by the worker); reconstructed ones are stored as reconstructed.
        missing = {}
        for j in jobs:
            if j.get("original_prompt_source") == "default":
                continue  # never pin fallback wording; it upgrades once the
                          # driver parses again
            if not j.get("original_prompt"):
                continue
            st_rec = state.get(j["id"]) or {}
            if not (st_rec.get("original_prompt")
                    or st_rec.get("prompt")):
                missing[j["id"]] = {
                    "original_prompt": j["original_prompt"],
                    "original_prompt_source": j["original_prompt_source"],
                }
        if missing:
            with self.lock:
                st = self.state()
                for job_id, add in missing.items():
                    rec = st.setdefault("jobs", {}).setdefault(job_id, {})
                    rec.setdefault("original_prompt",
                                   add["original_prompt"])
                    rec.setdefault("original_prompt_source",
                                   add["original_prompt_source"])
                self.save_state(st)
            log(f"backfilled original prompts for {len(missing)} job(s)")
        counts = {f: sum(1 for j in jobs if j["family"] == f)
                  for f in FAMILIES}
        counts["ingame"] = sum(1 for j in jobs
                               if (j.get("ingest") or {}).get("state")
                               == "in-game")
        counts["legacy"] = sum(1 for j in jobs if j.get("superseded"))
        # supersede marker: when a hull has a sheet job, its legacy
        # per-direction jobs are retired (re-rolling them would run the
        # retired per-dir path and shadow the sheet pipeline's canonical
        # outputs). Listed with the marker for transparency; the UI hides
        # them from re-rollable tabs and the API refuses re-roll/accept.
        sheet_subjects = {j["subject"] for j in jobs
                          if j["family"] == "sheet" and j.get("subject")}
        for j in jobs:
            if j["family"] == "hull" and j.get("subject") in sheet_subjects:
                j["superseded"] = True
                j["superseded_by"] = f"sheet_{j['subject']}"
        flagged_ids = [j["id"] for j in jobs if j["flagged"]]
        return jobs, counts, flagged_ids

    def _job_entry(self, job_id, prog, report, prompts, state, accepted,
                   seed_map):
        fam, subject, direction = chain.parse_job(job_id)
        if fam == "sheet":
            return self._sheet_entry(job_id, subject, prog, prompts, state,
                                     accepted, seed_map)
        if fam == "iconsheet":
            return self._iconsheet_entry(job_id, subject, prog, prompts,
                                         state, accepted, seed_map)
        canon = prog.get(job_id, {})
        studio_rec = state.get(job_id, {})
        metrics = studio_rec.get("metrics") or canon.get("metrics")
        band_tbl = report.get("band_table", {})

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

        thumbs = {}
        for kind in ("draft", "raw", "snapped"):
            for path, mirrored in self.thumb_candidates(kind, job_id):
                if mirrored is None and os.path.isfile(path):
                    thumbs[kind] = {"v": int(os.path.getmtime(path) * 1000)}
                    break
                if mirrored is not None and os.path.isfile(path):
                    thumbs[kind] = {"v": int(os.path.getmtime(path) * 1000),
                                    "mirrored": mirrored}
                    break

        # original prompt: EXACT when the studio generated it (worker writes
        # original_prompt + source "exact"); else the backfilled
        # reconstruction (source stored with it); legacy state recs that
        # only carry the old `prompt` field hold the exact wording too
        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt"))
        if stored_original:
            original_prompt = stored_original
            if studio_rec.get("original_prompt_source"):
                original_source = studio_rec["original_prompt_source"]
            else:
                # legacy worker recs stored the EXACT sent wording in
                # `prompt` (original_prompt key did not exist yet)
                original_source = "exact"
        else:
            original_prompt, original_source = chain.reconstruct_original(
                job_id, self.repo, rec=canon or None)
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
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
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": eff_prompt,
            "original_prompt": original_prompt,
            "original_prompt_source": original_source,
            "custom_prompt": job_id in prompts,
            "seed": studio_rec.get("seed", canon.get("seed")),
            "canonical_seed": seed_map.get(job_id),
            "status": studio_rec.get("status", canon.get("status")),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": metrics,
            "seconds": studio_rec.get("seconds", canon.get("seconds")),
            "error": studio_rec.get("error"),
            "thumbs": thumbs,
        }

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
            self.queue.append({"type": "generate", "job": job_id,
                               "seed": seed})
            pos = len(self.queue)
            self.qcond.notify_all()
        log(f"queued {job_id} (position {pos})")
        return pos

    def enqueue_ingest(self, job_id: str) -> int:
        """Queue the accept→ingest build run (worker FIFO, shared with
        generation — one heavy job at a time)."""
        with self.lock:
            self.queue.append({"type": "ingest", "job": job_id})
            pos = len(self.queue)
            self.qcond.notify_all()
        log(f"queued ingest {job_id} (position {pos})")
        return pos

    def _set_ingest_state(self, job_id: str, ing: dict) -> None:
        with self.lock:
            st = self.state()
            rec = st.setdefault("jobs", {}).setdefault(job_id, {})
            rec["ingest"] = ing
            self.save_state(st)
            acc = self.accepted()
            if job_id in acc:
                acc[job_id]["ingest"] = ing.get("state")
                if ing.get("accepted_at"):
                    acc[job_id]["accepted_at"] = ing["accepted_at"]
                self.save_accepted(acc)

    INGEST_TIMEOUT_S = 420   # the full ladder is ~1–2 min; margin for cold runs
    REJECT_RE = re.compile(r"^\s*REJECT (\S+): (\S+) — (.*)$", re.M)

    def _ingest_order(self, order: dict) -> None:
        """Accept→game: the canonical snapped dir is the ingestion input;
        run build_ui_art --import-ships (idempotent full-ladder re-run) and
        surface in-game ✓ / REJECTED:<reason> per job."""
        try:
            fam = chain.parse_job(order["job"])[0]
        except KeyError:
            fam = None
        if fam == "pxship":
            self._px_ingest_order(order)
            return
        job_id = order["job"]
        with self.lock:
            self.current = {"type": "ingest", "job": job_id,
                            "stage": "build-ladder",
                            "started_epoch": time.time()}
        log(f"ingesting {job_id} -> build_ui_art --import-ships")
        self._set_ingest_state(job_id, {"state": "running",
                                        "started_at": time.strftime(
                                            "%H:%M:%S")})
        t0 = time.time()
        try:
            fam_probe = chain.parse_job(job_id)[0]
        except KeyError:
            fam_probe = ""
        if fam_probe == "iconsheet":
            # --import-icons: multiple source dirs, later dirs win per id —
            # the studio reroll crops land in studio/snapped and win over
            # the batch round's canonical snaps
            cmd = [sys.executable, os.path.join(self.repo, "tools",
                                                "build_ui_art.py"),
                   "--import-icons", os.path.join(self.raw(), "snapped"),
                   os.path.join(self.studio(), "snapped")]
        else:
            cmd = [sys.executable, os.path.join(self.repo, "tools",
                                                "build_ui_art.py"),
                   "--import-ships", os.path.join(self.raw(), "snapped")]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=self.INGEST_TIMEOUT_S,
                                  cwd=self.repo)
            out = (proc.stdout or "") + "\n" + (proc.stderr or "")
            rejects = {m.group(1): (m.group(2), m.group(3).strip())
                       for m in self.REJECT_RE.finditer(out)}
            ledger = self._read_json(
                os.path.join(self.repo, "tools", "ui_art",
                             "ingest_ledger.json"), {})
            tokens = ledger.get("tokens") or {}
            icons_led = ledger.get("icons") or {}
            fam, subject, direction = chain.parse_job(job_id)
            ids: list[str] = []
            gate_job, via = job_id, ""
            if fam == "iconsheet":
                ids = self.studio._icon_groups().get(subject) or []
            elif fam == "sheet":
                gate_job = f"hull_{subject}_w"   # the banded base cell
                via = " (via w base cell)"
            elif direction and MIRROR_OF.get(direction):
                base_dir = MIRROR_OF.get(direction)
                gate_job = f"hull_{subject}_{base_dir}"
                via = f" (via {base_dir} base)"
            tail = out.strip()[-700:]
            if proc.returncode != 0:
                ing = {"state": "error", "exit_code": proc.returncode,
                       "reason": f"build failed (exit {proc.returncode}): "
                                 f"{tail[-300:]}",
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            elif fam == "iconsheet":
                # per-icon gate results (ledger section `icons{}` per id)
                per_icon, rejected_n, ok_n = {}, 0, 0
                for iid in ids:
                    rid = f"icon_{iid}"
                    if rid in rejects:
                        rsn, dtl = rejects[rid]
                        per_icon[iid] = f"rejected: {rsn} — {dtl}"
                        rejected_n += 1
                    elif rid in icons_led:
                        per_icon[iid] = "in game"
                        ok_n += 1
                    else:
                        per_icon[iid] = "not ingested"
                if rejected_n:
                    first = "; ".join(v for v in per_icon.values()
                                      if v.startswith("rejected"))[:300]
                    ing = {"state": "rejected", "exit_code": 0,
                           "reason": f"{rejected_n}/{len(ids)} icons "
                                     f"rejected: {first}",
                           "per_icon": per_icon, "log_tail": tail,
                           "seconds": round(time.time() - t0, 1)}
                elif ids and ok_n == len(ids):
                    ing = {"state": "in-game", "exit_code": 0,
                           "reason": f"all {ok_n} icons ingested",
                           "per_icon": per_icon, "log_tail": tail,
                           "seconds": round(time.time() - t0, 1)}
                else:
                    ing = {"state": "error", "exit_code": proc.returncode,
                           "reason": "no icons ingested and no REJECT "
                                     "lines — unexpected ingest output",
                           "per_icon": per_icon, "log_tail": tail,
                           "seconds": round(time.time() - t0, 1)}
            elif gate_job in rejects:
                reason, detail = rejects[gate_job]
                ing = {"state": "rejected", "exit_code": 0,
                       "reason": f"{reason}{via}", "detail": detail,
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            elif gate_job in tokens:
                tok = tokens[gate_job]
                ing = {"state": "in-game", "exit_code": 0,
                       "accepted_at": tok.get("accepted_at"),
                       "snapped_sha": tok.get("snapped_sha"),
                       "via": via or None, "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            else:
                ing = {"state": "error", "exit_code": proc.returncode,
                       "reason": "no ledger entry and no REJECT line — "
                                 "unexpected ingest output",
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
        except subprocess.TimeoutExpired:
            ing = {"state": "error",
                   "reason": f"build timed out after "
                             f"{self.INGEST_TIMEOUT_S}s"}
        except Exception as exc:  # noqa: BLE001 — surface in the UI
            ing = {"state": "error",
                   "reason": f"{type(exc).__name__}: {exc}"}
        ing["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        self._set_ingest_state(job_id, ing)
        with self.lock:
            self.current = None
        log(f"ingest {job_id}: {ing['state']}"
            + (f" ({ing.get('reason')})" if ing.get("reason") else ""))

    def _px_ingest_order(self, order: dict) -> None:
        """Accept→game for a pixellab ship (§4.8 2026-11-06): stage the
        WHOLE fleet's snapped rotations — a partial stage would revoke
        every other ship's ledger tokens (run_ship_ingest prunes
        non-live ids) — then run build_ui_art --import-ships-pixellab
        <stage> (raw mode). Gate: this ship's 8 hull_{ship}_{dir} tokens
        in the ledger with pennant 'raw'."""
        job_id = order["job"]
        label = job_id[len("px_"):]
        ship = chain.px_ship_of(label)
        with self.lock:
            self.current = {"type": "ingest", "job": job_id,
                            "stage": "staging",
                            "started_epoch": time.time()}
        log(f"ingesting {job_id} -> build_ui_art --import-ships-pixellab")
        self._set_ingest_state(job_id, {"state": "running",
                                        "started_at": time.strftime(
                                            "%H:%M:%S")})
        t0 = time.time()
        stage_dir = os.path.join(self.studio(), "px_stage")
        dir_order = ("n", "ne", "e", "se", "s", "sw", "w", "nw")
        try:
            staged, missing = 0, []
            shutil.rmtree(stage_dir, ignore_errors=True)
            os.makedirs(stage_dir, exist_ok=True)
            for lab in chain.px_fleet_labels():
                s = chain.px_ship_of(lab)
                for d in chain.px_dirs(lab):
                    src = os.path.join(chain.px_dir(), lab, "snapped",
                                       f"{d}.png")
                    if not os.path.isfile(src):
                        missing.append(f"{lab}/{d}")
                        continue
                    shutil.copyfile(
                        src, os.path.join(stage_dir, f"hull_{s}_{d}.png"))
                    staged += 1
            if missing:
                raise RuntimeError(f"missing snapped rotations: "
                                   f"{missing[:8]}")
            with self.lock:
                if self.current:
                    self.current["stage"] = "build-ladder"
            cmd = [sys.executable,
                   os.path.join(self.repo, "tools", "build_ui_art.py"),
                   "--import-ships-pixellab", stage_dir]
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=self.INGEST_TIMEOUT_S,
                                  cwd=self.repo)
            out = (proc.stdout or "") + "\n" + (proc.stderr or "")
            ledger = self._read_json(
                os.path.join(self.repo, "tools", "ui_art",
                             "ingest_ledger.json"), {})
            tokens = ledger.get("tokens") or {}
            tail = out.strip()[-700:]
            if proc.returncode != 0:
                ing = {"state": "error", "exit_code": proc.returncode,
                       "reason": f"build failed (exit {proc.returncode}): "
                                 f"{tail[-300:]}",
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            else:
                got = [d for d in dir_order
                       if f"hull_{ship}_{d}" in tokens]
                raw_ok = all((tokens.get(f"hull_{ship}_{d}") or {})
                             .get("pennant") == "raw" for d in got)
                if len(got) == 8 and raw_ok:
                    ing = {"state": "in-game", "exit_code": 0,
                           "reason": f"8/8 raw tokens ({staged} staged)",
                           "accepted_at": (tokens.get(f"hull_{ship}_n")
                                           or {}).get("accepted_at"),
                           "log_tail": tail,
                           "seconds": round(time.time() - t0, 1)}
                else:
                    ing = {"state": "error", "exit_code": 0,
                           "reason": f"only {len(got)}/8 tokens landed "
                                     f"(pennant raw: {raw_ok})",
                           "log_tail": tail,
                           "seconds": round(time.time() - t0, 1)}
        except subprocess.TimeoutExpired:
            ing = {"state": "error",
                   "reason": f"build timed out after "
                             f"{self.INGEST_TIMEOUT_S}s"}
        except Exception as exc:  # noqa: BLE001 — surface in the UI
            ing = {"state": "error",
                   "reason": f"{type(exc).__name__}: {exc}"}
        ing["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        self._set_ingest_state(job_id, ing)
        if ing.get("state") == "in-game":
            # the import re-lands the WHOLE grid — stamp the other ship
            # cards in-game too (their bytes are unchanged; idempotent)
            with self.lock:
                st = self.state()
                for lab in chain.px_fleet_labels():
                    other = f"px_{lab}"
                    if other == job_id:
                        continue
                    rec = st.setdefault("jobs", {}).setdefault(other, {})
                    oing = rec.get("ingest") or {}
                    if oing.get("state") != "in-game":
                        rec["ingest"] = {**oing, "state": "in-game",
                                         "reason": "fleet grid re-import "
                                                   "(idempotent)"}
                self.save_state(st)
        with self.lock:
            self.current = None
        log(f"ingest {job_id}: {ing['state']}"
            + (f" ({ing.get('reason')})" if ing.get("reason") else ""))

    def _worker(self) -> None:
        while True:
            with self.lock:
                while not self.queue:
                    self.qcond.wait()
                order = self.queue.pop(0)
            if order.get("type") == "ingest":
                self._ingest_order(order)
                continue
            self._generate_order(order)

    def _generate_order(self, order: dict) -> None:
            job_id = order["job"]
            prompt = self.prompts().get(job_id)
            if not prompt:
                st = self.state().get("jobs", {}).get(job_id) or {}
                prompt = (st.get("original_prompt")
                          or st.get("prompt"))  # exact original wins
            if not prompt:
                prompt = chain.default_prompt(job_id, self.repo)
            seed = order["seed"] if order["seed"] is not None \
                else chain.random_seed()
            with self.lock:
                self.current = {"type": "generate", "job": job_id,
                                "prompt": prompt, "seed": seed,
                                "stage": "starting",
                                "started_epoch": time.time()}
            log(f"generating {job_id} seed={seed} prompt={prompt!r}")
            rec = {"prompt": prompt, "original_prompt": prompt,
                   "original_prompt_source": "exact", "seed": seed,
                   "status": "running",
                   "started_at": time.strftime("%H:%M:%S")}
            try:
                def stage(name: str) -> None:
                    with self.lock:
                        if self.current and self.current["job"] == job_id:
                            self.current["stage"] = name

                fam, subject, direction = None, None, None
                try:
                    fam, subject, direction = chain.parse_job(job_id)
                except KeyError:
                    pass
                if fam == "pxship":
                    # pixellab ship family: in-process tool call (the
                    # description is free text; the envelope stays pinned)
                    result = chain.px_generate(job_id[len("px_"):], prompt,
                                               seed, on_stage=stage)
                    rec.update(result)
                    rec["status"] = result.get("status", "done")
                else:
                    result = chain.run_job(job_id, prompt, seed,
                                           on_stage=stage)
                    rec.update(result)
                    metrics = rec.get("metrics") or {}
                    band = metrics.get("band")
                    if fam == "hull" and direction in ("e", "w") \
                            and band and not band.get("in_band"):
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
        if self.command != "HEAD":
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
                try:
                    jobs, counts, flagged = self.studio.registry()
                except Exception as exc:  # noqa: BLE001 — never 500
                    log(f"registry failed (degraded response): "
                        f"{type(exc).__name__}: {exc}")
                    jobs, counts, flagged = [], {}, []
                    self.studio.last_warnings = [f"registry: {exc}"]
                with self.studio.lock:
                    cur = dict(self.studio.current) if self.studio.current \
                        else None
                    queue = [o["job"] for o in self.studio.queue]
                self._json(200, {"jobs": jobs, "counts": counts,
                                 "flagged": flagged, "queue": queue,
                                 "current": cur,
                                 "warnings":
                                     list(self.studio.last_warnings)})
            elif path == "/api/status":
                with self.studio.lock:
                    cur = dict(self.studio.current) if self.studio.current \
                        else None
                    queue = [o["job"] for o in self.studio.queue]
                self._json(200, {"worker": "busy" if cur else "idle",
                                 "current": cur, "queue": queue,
                                 "repo": self.studio.repo,
                                 "driver": chain.driver_status(),
                                 "registry":
                                     {"warnings":
                                      list(self.studio.last_warnings)}})
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
        # studio reroll, snapped falls back to the canonical store; a hull
        # mirror dir (e/ne/se) whose file is gone serves its w/nw/sw base
        # flipped; terrain snapped falls back to its gen sheet — never 404
        # on a listed job)
        # /thumb/px/<label>/<dir>.png — the pixellab strip: the snapped
        # token (what ships) preferred, the raw rotation as fallback
        mp = re.match(r"^/thumb/px/([a-z0-9_]+)/(n|ne|e|se|s|sw|w|nw)\.png$",
                      path)
        if mp:
            data = self.studio.px_dir_thumb(mp.group(1), mp.group(2))
            if data is None:
                self._json(404, {"error": f"no px thumb for "
                                          f"{mp.group(1)}/{mp.group(2)}"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        m = re.match(r"^/thumb/(draft|raw|snapped)/([a-z0-9_]+)\.png$",
                     path)
        if not m:
            self._json(404, {"error": "bad thumb path"})
            return
        kind, job_id = m.group(1), m.group(2)
        data, mirrored, _direct = self.studio.thumb_bytes(kind, job_id)
        if data is None:
            self._json(404, {"error": f"no {kind} thumb for {job_id}"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if mirrored:
            self.send_header("X-Mirrored", mirrored)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):  # noqa: N802 — headers-only GET (no more 501 pages)
        self.do_GET()

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
        if job_id.startswith("px_") and JOB_RE.match(job_id):
            return chain.px_exists(job_id[len("px_"):])
        return bool(job_id and JOB_RE.match(job_id) and os.path.isfile(
            chain.canonical_path("drafts", job_id)))

    def _supersede_guard(self, job_id: str) -> bool:
        """True (and answers 409) when the job is a superseded legacy
        per-direction card — re-roll/accept would run the retired path and
        shadow the sheet pipeline's canonical outputs."""
        jobs, _c, _f = self.studio.registry()
        me = next((j for j in jobs if j["id"] == job_id), None)
        if me and me.get("superseded"):
            self._json(409, {
                "error": f"{job_id} is superseded by {me.get('superseded_by')} "
                         f"— re-roll the sheet card instead",
                "superseded_by": me.get("superseded_by"),
            })
            return True
        return False

    def _reroll(self, data: dict) -> None:
        job_id = data.get("job", "")
        if not self._job_ok(job_id):
            self._json(404, {"error": f"unknown job {job_id!r}"})
            return
        if self._supersede_guard(job_id):
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
        if self._supersede_guard(job_id):
            return
        fam, subject, direction = chain.parse_job(job_id)
        with self.studio.lock:
            st = self.studio.state().get("jobs", {}).get(job_id)
            acc = self.studio.accepted()
            if fam == "pxship":
                # the pixellab store IS the ingestion input (snapped/ under
                # the label dir) — nothing to place
                source = "pixellab"
                ingest_state = "queued"
            else:
                source = ("studio" if os.path.isfile(
                    chain.studio_path("snapped", job_id)) else "canonical")
                ingest_state = ("queued" if fam in ("hull", "sheet",
                                                    "iconsheet")
                                else "game-flow-pending")
            acc[job_id] = {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "source": source,
                "seed": (st or {}).get("seed"),
                "prompt": (st or {}).get("prompt"),
                "ingest": ingest_state,
            }
            # Accept = 一键进游戏: the canonical snapped file is the
            # ingestion input — atomically place the accepted art there.
            # (Icon/terrain ingestion surfaces land later; acceptance only.)
            if fam == "hull":
                studio_snap = chain.studio_path("snapped", job_id)
                canon_snap = chain.canonical_path("snapped", job_id)
                src = studio_snap if os.path.isfile(studio_snap) \
                    else canon_snap
                copied = False
                if os.path.isfile(src) and \
                        os.path.abspath(src) != os.path.abspath(canon_snap):
                    os.makedirs(os.path.dirname(canon_snap), exist_ok=True)
                    tmp = canon_snap + ".ingest-tmp"
                    shutil.copyfile(src, tmp)
                    with open(tmp, "rb") as fh:
                        os.fsync(fh.fileno())
                    os.replace(tmp, canon_snap)  # atomic on same fs
                    copied = True
                if os.path.isfile(canon_snap):
                    with open(canon_snap, "rb") as fh:
                        acc[job_id]["snap_sha"] = hashlib.sha256(
                            fh.read()).hexdigest()
                acc[job_id]["snap_copied"] = copied
                st_ = self.studio.state()
                rec = st_.setdefault("jobs", {}).setdefault(job_id, {})
                rec["ingest"] = {"state": "queued",
                                 "queued_at": acc[job_id]["at"]}
                self.studio.save_state(st_)
            elif fam == "sheet":
                # sheet jobs: the driver crops per-dir snapped files under
                # the canonical paths itself; the studio's own reroll crops
                # live at the legacy studio per-dir paths — copy any that
                # exist (atomic, per file), then one ingest run gates them.
                copied, copied_n = False, 0
                sheet_dirs = (self.studio.driver.get("SHEET_DIRS")
                              or chain.EMBEDDED_DRIVER["SHEET_DIRS"])
                for dir_ in sheet_dirs:
                    src = chain.studio_path("snapped",
                                            f"hull_{subject}_{dir_}")
                    dst = chain.canonical_path("snapped",
                                               f"hull_{subject}_{dir_}")
                    if os.path.isfile(src):
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        tmp = dst + ".ingest-tmp"
                        shutil.copyfile(src, tmp)
                        with open(tmp, "rb") as fh:
                            os.fsync(fh.fileno())
                        os.replace(tmp, dst)
                        copied = True
                        copied_n += 1
                w_canon = chain.canonical_path("snapped",
                                               f"hull_{subject}_w")
                if os.path.isfile(w_canon):
                    with open(w_canon, "rb") as fh:
                        acc[job_id]["snap_sha"] = hashlib.sha256(
                            fh.read()).hexdigest()
                acc[job_id]["snap_copied"] = copied
                acc[job_id]["snap_copies"] = copied_n
                st_ = self.studio.state()
                rec = st_.setdefault("jobs", {}).setdefault(job_id, {})
                rec["ingest"] = {"state": "queued",
                                 "queued_at": acc[job_id]["at"]}
                self.studio.save_state(st_)
            elif fam == "iconsheet":
                # the studio chain writes per-icon canonical snapped files
                # at generation time; accept = record the group + one
                # --import-icons run over both source dirs
                ids = self.studio._icon_groups().get(subject) or []
                acc[job_id]["group_ids"] = ids
                st_ = self.studio.state()
                rec = st_.setdefault("jobs", {}).setdefault(job_id, {})
                rec["ingest"] = {"state": "queued",
                                 "queued_at": acc[job_id]["at"]}
                self.studio.save_state(st_)
            elif fam == "pxship":
                # pixellab ships: the store's snapped/ dir IS the ingestion
                # input — record the label's provenance and queue the raw
                # import (the whole grid re-lands, idempotent)
                manifest = chain.px_manifest().get(subject) or {}
                acc[job_id]["object_id"] = manifest.get("object_id")
                st_ = self.studio.state()
                rec = st_.setdefault("jobs", {}).setdefault(job_id, {})
                rec["ingest"] = {"state": "queued",
                                 "queued_at": acc[job_id]["at"]}
                self.studio.save_state(st_)
            self.studio.save_accepted(acc)
        if fam in ("hull", "sheet", "iconsheet", "pxship"):
            self.studio.enqueue_ingest(job_id)
        log(f"accepted {job_id} ({source}, ingest={ingest_state})")
        self._json(200, {"ok": True, "job": job_id, "accepted":
                         acc[job_id],
                         "ingest": {"state": ingest_state},
                         "note": ("restart the game to see it — the token "
                                  "runtime loads data artifacts, no import "
                                  "refresh needed"
                                  if fam in ("hull", "sheet", "iconsheet",
                                             "pxship")
                                  else "accepted (game flow pending)")})


class StudioHTTPServer(ThreadingHTTPServer):
    """daemon_threads (ThreadingHTTPServer default) + a real accept backlog:
    the TCPServer default of 5 drops connections when a browser bursts ~500
    <img> requests — the intermittently-broken-thumbnail mechanism."""
    daemon_threads = True
    request_queue_size = 128


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
    Handler.protocol_version = "HTTP/1.1"  # keep-alive; Content-Length always sent
    studio.start_worker()

    try:
        jobs, counts, flagged = studio.registry()
        log(f"registry: {len(jobs)} jobs {counts}; flagged={len(flagged)}; "
            f"warnings={len(studio.last_warnings)}")
    except Exception as exc:  # noqa: BLE001 — the API must always come up
        log(f"boot registry failed (serving degraded): "
            f"{type(exc).__name__}: {exc}")
    httpd = StudioHTTPServer((args.host, args.port), Handler)
    log(f"listening on http://{args.host}:{args.port} (repo={args.repo})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("bye")


if __name__ == "__main__":
    main()
