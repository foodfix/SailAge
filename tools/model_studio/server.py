#!/usr/bin/env python3
"""SailAge model studio — local web UI so the user can re-roll
model-generated art themselves: edit prompts, re-roll, accept.

Single-page vanilla HTML/JS/CSS frontend + JSON API over stdlib
http.server (ThreadingHTTPServer). Generation jobs run ONE at a time in a
background worker thread (~40 s each) fed by a FIFO queue.

Services (localhost): thenoise :8001 (/edit, the image model) and ComfyUI
:8000 (rembg). This server binds 127.0.0.1:8010 — no auth, local tool.

The --repo argument points at the MAIN SailAge repo: the canonical raw
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
  GET  /api/layout/file      the committed data/ui_layout.json (v2 doc,
                             +mtime, verdict)
  POST /api/layout/commit    {layout} — the FULL v2 document; serialize
                             (10-* §4.23 bytes), validate in a full
                             tools/validate_data.py pass over a staged
                             tree, write ONLY on pass (single writer)
  GET  /thumb/<kind>/<job>   draft | raw | snapped PNG (cache-busting ?v=)
  GET  /thumb/td/<l>/<deg>   top-down rotation previews (NEAREST)
  GET  /thumb/fx/<ship>/<kind>  wake previews: anim.gif | comp.png | shipped.png
  GET  /thumb/<kind>/chrome_<family>.png  chrome strip/mock previews

Launch:
  python3 tools/model_studio/server.py --port 8010 --repo /home/weidong/repo/SailAge
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
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
FAMILIES = ("topdown", "fx", "coast", "chrome", "icons", "glyphs")
# draft-file prefixes that are NEVER listed (the retired ship families —
# 2026-11-07 user direction — and the hidden terrain texture chain)
HIDDEN_PREFIXES = ("hull_", "sheet_", "terrain_", "px_")

# The top-down rotation preview table (80-* §4.8 2026-11-07, pinned):
# dir id → clockwise degrees in screen y-down — mirrors the runtime
# ArrowField.DIR_ROTATION_DEGREES map.
TD_ROTATIONS = (("n", 0), ("ne", 45), ("e", 90), ("se", 135),
                ("s", 180), ("sw", 225), ("w", 270), ("nw", 315))
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
        self.layout_valid: bool | None = None  # last commit-gate verdict
        self.layout_gate = threading.Lock()    # one commit at a time
        chain.init(repo)
        self.report = self._read_json(
            os.path.join(self.raw(), "report.json"), {})

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

    # -- layout (Phase 11 W5-D; the Phase-12 v2 doc — 10-* §4.23, --------
    # 80-* §4.8.9) ---------------------------------------------------------
    # The studio is the SINGLE WRITER of data/ui_layout.json: the game
    # and its bridge never touch the filesystem. The session document is
    # the FULL v2 layout {version: 2, screens: {<screen>: {elements,
    # lists}}}. Every commit is gated behind a full tools/validate_data.py
    # pass (run as a subprocess over a staged SAILAGE_DATA_ROOT tree), so
    # the real file is written ONLY on validator exit 0.
    LAYOUT_TIMEOUT_S = 240   # full validator pass ≈ 26 s; spec bound < 30 s

    def layout_path(self) -> str:
        return os.path.join(self.repo, "data", "ui_layout.json")

    def layout_file(self) -> dict:
        """GET /api/layout/file — the committed v2 layout document text,
        its mtime, and the last in-session commit-gate verdict. NEVER
        raises: a missing file degrades to the {content: null} shape."""
        path = self.layout_path()
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
            mtime = os.path.getmtime(path)
        except OSError:
            return {"content": None, "mtime": None,
                    "valid": self.layout_valid}
        return {"content": text, "mtime": mtime, "valid": self.layout_valid}

    def commit_layout(self, doc: dict) -> dict:
        """POST /api/layout/commit — serialize EXACTLY per §4.23 (sorted
        keys, 2-space indent, trailing newline), gate the candidate
        behind the full validator pass, write ONLY on exit 0. Returns
        {ok: True, bytes: n} or {ok: False, error: text} — never raises,
        never a 500 (the registry-never-raises rule)."""
        try:
            text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
        except (TypeError, ValueError) as exc:
            return {"ok": False, "error": f"serialize failed: "
                                          f"{type(exc).__name__}: {exc}"}
        with self.layout_gate:  # one commit at a time (the file write + gate)
            verdict = self._validate_layout_text(text)
            if not verdict["ok"]:
                self.layout_valid = False
                log(f"layout commit REJECTED: {verdict['error'][:200]}")
                return {"ok": False, "error": verdict["error"]}
            data = text.encode("utf-8")
            try:
                chain.atomic_write(self.layout_path(), data)
            except OSError as exc:
                self.layout_valid = False
                return {"ok": False, "error": f"write failed: "
                                              f"{type(exc).__name__}: {exc}"}
        self.layout_valid = True
        log(f"layout committed: {len(data)} bytes, "
            f"{len(doc.get('screens', {}))} screen(s) — validator gate passed")
        return {"ok": True, "bytes": len(data)}

    def _validate_layout_text(self, text: str) -> dict:
        """One full tools/validate_data.py pass over a STAGED tree whose
        data/ is the real repo's data with the CANDIDATE ui_layout.json —
        the validator's own staged-sim protocol (SAILAGE_DATA_ROOT, the
        --data-root resolution point). Groups 8/13 read tools/ + assets/
        from the staged tree (the builder preference + ART_ROOT), so
        both are symlinked read-only. The real file is NEVER touched
        here; the staged tree is discarded whatever the outcome."""
        real_data = os.path.join(self.repo, "data")
        if not os.path.isdir(real_data):
            return {"ok": False, "error": f"repo data/ not found: "
                                          f"{real_data}"}
        try:
            with tempfile.TemporaryDirectory(
                    prefix="studio_layout_gate_") as tmp:
                staged = os.path.join(tmp, "data")
                os.mkdir(staged)
                for name in os.listdir(real_data):
                    if name == "ui_layout.json":
                        continue  # the candidate replaces this one
                    os.symlink(os.path.join(real_data, name),
                               os.path.join(staged, name))
                with open(os.path.join(staged, "ui_layout.json"), "w",
                          encoding="utf-8") as fh:
                    fh.write(text)
                os.symlink(os.path.join(self.repo, "tools"),
                           os.path.join(tmp, "tools"))
                assets = os.path.join(self.repo, "assets")
                if os.path.isdir(assets):
                    os.symlink(assets, os.path.join(tmp, "assets"))
                env = dict(os.environ)
                env["SAILAGE_DATA_ROOT"] = tmp
                proc = subprocess.run(
                    [sys.executable,
                     os.path.join(self.repo, "tools", "validate_data.py")],
                    capture_output=True, text=True,
                    timeout=self.LAYOUT_TIMEOUT_S,
                    cwd=self.repo, env=env)
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": f"validator timed out after "
                                          f"{self.LAYOUT_TIMEOUT_S}s"}
        except OSError as exc:
            return {"ok": False, "error": f"gate staging failed: "
                                          f"{type(exc).__name__}: {exc}"}
        if proc.returncode == 0:
            return {"ok": True}
        out = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
        fail_line = next((ln for ln in out.splitlines()
                          if ln.startswith("FAIL")), None)
        error = fail_line or (out[-500:] if out else
                              f"validator exited {proc.returncode}")
        return {"ok": False, "error": error}

    # -- registry ---------------------------------------------------------
    # -- thumbnails -------------------------------------------------------
    def _fx_entry(self, ship, prompts, state, accepted):
        """One wake VFX card (§4.8 2026-11-08 per-ship revision): ONE
        north wake sheet per SHIP TYPE, rendered UNDER the hull.
        Provenance = the staged manifest (a pending studio re-roll) or
        the committed fx ledger (what the game ships). No seed — the
        /v2/vfx envelope has none; the card shows the quote instead."""
        ship = str(ship)
        job_id = f"fx_{ship}"
        staged = chain.fx_stage_manifest().get(ship) or {}
        studio_rec = state.get(job_id, {}) or {}
        ledger = self._read_json(
            os.path.join(self.repo, "tools", "assets", "pixellab_raw",
                         "pixellab_vfx_ledger.json"), {})
        shipped = (ledger.get("ships", {}).get(ship) or {})
        quote = (staged.get("quoted_generations")
                 or shipped.get("quoted_generations") or 10)
        thumbs = {}
        if chain.fx_shipped_pack(ship):
            thumbs["shipped"] = {"v": int(os.path.getmtime(
                os.path.join(self.repo, "assets", "ui", "fx",
                             "fx_waterline.json")) * 1000)}
        staged_pack = chain.fx_stage_pack(ship)
        if staged_pack:
            v = int(os.path.getmtime(chain.fx_stage_manifest_path())
                    * 1000)
            thumbs["comp"] = {"v": v}
            if staged_pack.get("gif"):
                thumbs["anim"] = {"v": v}
        original_prompt = chain.fx_default_prompt()
        eff_prompt = prompts.get(job_id) or original_prompt
        label = f"wake {ship}"
        if staged:
            label += " · staged re-roll pending accept"
        return {
            "id": job_id,
            "family": "fx",
            "subject": ship,
            "size": None,
            "ship": ship,
            "dir": None,
            "tier": None,
            "label": label + f" · ~{quote} gens/roll",
            "mirror_of": None,
            "band": None,
            "pennant_ok": None,
            "flagged": False,
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": eff_prompt,
            "original_prompt": original_prompt,
            "original_prompt_source": "canonical (the pinned v5 "
                                     "description of record)",
            "custom_prompt": job_id in prompts,
            "seed": None,
            "canonical_seed": None,
            "quote": quote,
            "effect_id": staged.get("effect_id")
                or shipped.get("effect_id"),
            "pending": bool(staged),
            "status": studio_rec.get("status",
                                     "staged — accept to ingest"
                                     if staged else
                                     ("canonical" if shipped else None)),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": None,
            "seconds": studio_rec.get("seconds"),
            "error": studio_rec.get("error"),
            "thumbs": thumbs,
        }

    def _td_entry(self, label, prompts, state, accepted) -> dict:
        """One top-down ship card (§4.8 2026-11-07): ONE north token per
        ship, tier-sized canvas, ship-as-drawn; the strip previews the 8
        runtime rotations (PIL NEAREST) around that one token."""
        job_id = f"td_{label}"
        manifest = chain.td_manifest().get(label) or {}
        studio_rec = state.get(job_id, {}) or {}
        p = chain.td_north_path(label)
        v = int(os.path.getmtime(p) * 1000) if os.path.isfile(p) else 0
        rotations = [{"dir": d, "deg": deg, "v": v}
                     for d, deg in TD_ROTATIONS]
        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt")
                           or manifest.get("description"))
        if stored_original:
            original_prompt = stored_original
            original_source = (studio_rec.get("original_prompt_source")
                               or "manifest")
        else:
            original_prompt = chain.td_default_prompt(label)
            # Bare template = composer AND manifest both failed — tag it
            # "default" so the backfill never pins fallback wording (same
            # contract as the icon family; it upgrades on a later scan).
            original_source = ("default"
                               if original_prompt ==
                               chain.td_fallback_prompt(label)
                               else "canonical")
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
            "id": job_id,
            "family": "topdown",
            "subject": label,
            "ship": chain.td_ship_of(label),
            "dir": None,
            "rotations": rotations,
            "size": manifest.get("size"),
            "tier": None,
            "label": f"{label} · {manifest.get('size', '?')}px north · "
                     f"~$0.008/roll",
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

    def _icon_id_entry(self, icon_id, prompts, state, accepted) -> dict:
        """One prompt-only icon card (§4.8 2026-11-08 studio
        modernization): ONE card per id, raw 64x64 in → quantized-64
        hero out. Thumbs: snapped = the canonical raw (the shipped
        pixels' source); raw = the staged re-roll when one is pending."""
        job_id = f"ic_{icon_id}"
        manifest = chain.icon_manifest().get(icon_id) or {}
        studio_rec = state.get(job_id, {}) or {}
        staged = os.path.isfile(chain.icon_stage_path(icon_id))
        thumbs = {}
        if os.path.isfile(chain.icon_raw_path(icon_id)):
            thumbs["snapped"] = {"v": int(os.path.getmtime(
                chain.icon_raw_path(icon_id)) * 1000)}
        if staged:
            thumbs["raw"] = {"v": int(os.path.getmtime(
                chain.icon_stage_path(icon_id)) * 1000)}
        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt")
                           or manifest.get("description"))
        original_prompt = stored_original or chain.icon_default_prompt(
            icon_id)
        original_source = ("manifest" if manifest.get("description")
                           else "default")
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
            "id": job_id,
            "family": "icons",
            "subject": icon_id,
            "dir": None,
            "tier": None,
            "label": f"ICON · {icon_id} · 64px · ~$0.008/roll",
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
                                     "re-rolled — pending accept" if staged
                                     else "canonical"),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": None,
            "seconds": studio_rec.get("seconds"),
            "error": studio_rec.get("error"),
            "thumbs": thumbs,
        }

    def _glyph_id_entry(self, glyph_id, prompts, state, accepted) -> dict:
        """One prompt-only glyph card — the icon envelope against the
        frozen MARKER_SUFFIX / FACILITY_SUFFIX; the card label carries
        the family."""
        job_id = f"gl_{glyph_id}"
        manifest = chain.glyph_manifest().get(glyph_id) or {}
        studio_rec = state.get(job_id, {}) or {}
        staged = os.path.isfile(chain.glyph_stage_path(glyph_id))
        thumbs = {}
        if os.path.isfile(chain.glyph_raw_path(glyph_id)):
            thumbs["snapped"] = {"v": int(os.path.getmtime(
                chain.glyph_raw_path(glyph_id)) * 1000)}
        if staged:
            thumbs["raw"] = {"v": int(os.path.getmtime(
                chain.glyph_stage_path(glyph_id)) * 1000)}
        fam_name = "MARKER" if glyph_id.startswith("marker_") \
            else "FACILITY"
        fam_stripped = (glyph_id[len("marker_"):]
                        if glyph_id.startswith("marker_")
                        else glyph_id[len("facility_"):])
        stored_original = (studio_rec.get("original_prompt")
                           or studio_rec.get("prompt")
                           or manifest.get("description"))
        original_prompt = stored_original or chain.glyph_default_prompt(
            glyph_id)
        original_source = ("manifest" if manifest.get("description")
                           else "default")
        eff_prompt = prompts.get(job_id) or original_prompt
        return {
            "id": job_id,
            "family": "glyphs",
            "subject": glyph_id,
            "dir": None,
            "tier": None,
            "label": f"{fam_name} · {fam_stripped} · 64px · "
                     f"~$0.008/roll",
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
                                     "re-rolled — pending accept" if staged
                                     else "canonical"),
            "status_source": "studio" if studio_rec else "canonical",
            "ingest": studio_rec.get("ingest"),
            "metrics": None,
            "seconds": studio_rec.get("seconds"),
            "error": studio_rec.get("error"),
            "thumbs": thumbs,
        }

    def _coast_entry(self, prompts, state, accepted) -> dict:
        """The coast tileset card (§4.8 2026-11-06): ONE card per tileset.
        draft = the shipped ledger strip; raw = the pending re-roll strip;
        snapped = the wang mock preview (a live map crop rendered with the
        pending tiles). Prompt = the free-text style clause appended to
        all three vendored descriptions; seed = the tileset seed."""
        job_id = chain.COAST_CARD_ID
        led = chain.coast_ledger()
        defaults = chain.coast_defaults()
        pending = chain.coast_pending_path()
        tileset_id = led["pixellab"]["tileset_id"]
        st = state.get(job_id, {})
        thumbs = {"draft": {"v": int(os.path.getmtime(
            chain.coast_ledger_path()) * 1000)}}
        pending_id = None
        if pending:
            m = re.search(r"tileset_coastline_([0-9a-f-]+)\.json$",
                          os.path.basename(pending))
            pending_id = m.group(1) if m else None
            v = int(os.path.getmtime(pending) * 1000)
            thumbs["raw"] = {"v": v}
            thumbs["snapped"] = {"v": v}
        return {
            "id": job_id,
            "family": "coast",
            "subject": "coastline tileset",
            "label": f"coast · {tileset_id[:8]} · seed "
                     f"{led['pixellab']['seed']}",
            "tileset_id": tileset_id,
            "pending": bool(pending),
            "pending_tileset_id": pending_id,
            "mirror_of": None,
            "band": None,
            "pennant_ok": None,
            "flagged": False,
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": prompts.get(job_id),
            "original_prompt": None,
            "original_prompt_source": "none (style clause on vendored "
                                     "wording)",
            "custom_prompt": job_id in prompts,
            "seed": st.get("seed", defaults["seed"]),
            "canonical_seed": defaults["seed"],
            "status": st.get("status", "re-rolled — pending accept"
                             if pending else "canonical"),
            "status_source": "studio" if st else "canonical",
            "ingest": None,
            "metrics": None,
            "seconds": st.get("seconds"),
            "error": st.get("error"),
            "thumbs": thumbs,
        }

    def _chrome_entry(self, family, prompts, state, accepted) -> dict:
        """One chrome tileset card (§4.8 2026-11-08; the evening revision
        re-sourced the button families to the light `click` plate and
        retired the chestnut set): frame (parchment panel plate) /
        click (light parchment click plate), ONE card per
        family. draft = the canonical vendored strip; raw = the pending
        re-roll strip; snapped = the nine-patch mock preview (the pending
        tiles when one is staged, else the canonical tiles). Prompt = the
        free-text style clause appended to all three pinned descriptions;
        seed = the tileset seed."""
        job_id = chain.chrome_card_id(family)
        defaults = chain.chrome_defaults(family)
        pending = chain.chrome_pending_path(family)
        tid = defaults["tileset_id"]
        st = state.get(job_id, {})
        trio = chain.chrome_canonical_trio(family)
        thumbs = {}
        canon_v = int(os.path.getmtime(trio[".json"]) * 1000) \
            if trio and os.path.isfile(trio[".json"]) else None
        if canon_v is not None:
            thumbs["draft"] = {"v": canon_v}
            if not pending:
                thumbs["snapped"] = {"v": canon_v}
        pending_id = None
        if pending:
            m = re.search(rf"tileset_chrome_{family}_([0-9a-f-]+)\.json$",
                          os.path.basename(pending))
            pending_id = m.group(1) if m else None
            v = int(os.path.getmtime(pending) * 1000)
            thumbs["raw"] = {"v": v}
            thumbs["snapped"] = {"v": v}
        return {
            "id": job_id,
            "family": "chrome",
            "subject": f"{family} tileset",
            "label": f"chrome {family} · {(tid or '?')[:8]} · seed "
                     f"{defaults['seed']}",
            "tileset_id": tid,
            "pending": bool(pending),
            "pending_tileset_id": pending_id,
            "mirror_of": None,
            "band": None,
            "pennant_ok": None,
            "flagged": False,
            "superseded": False,
            "superseded_by": None,
            "accepted": accepted.get(job_id),
            "prompt": prompts.get(job_id),
            "original_prompt": None,
            "original_prompt_source": "none (style clause on the pinned "
                                     "CHROME_TILESETS wording)",
            "custom_prompt": job_id in prompts,
            "seed": st.get("seed", defaults["seed"]),
            "canonical_seed": defaults["seed"],
            "status": st.get("status", "re-rolled — pending accept"
                             if pending else "canonical"),
            "status_source": "studio" if st else "canonical",
            "ingest": None,
            "metrics": None,
            "seconds": st.get("seconds"),
            "error": st.get("error"),
            "thumbs": thumbs,
        }

    def thumb_candidates(self, kind: str, job_id: str):
        """Ordered file candidates for one thumb slot. Never 404 on a
        listed job's thumbs."""
        fam, _subject, _direction = chain.parse_job(job_id)
        if fam == "icons" and job_id.startswith("ic_"):
            # prompt-only icon card: snapped = the canonical raw (the
            # shipped pixels' source); raw = the staged re-roll
            iid = job_id[len("ic_"):]
            out = []
            if kind == "raw":
                out.append((chain.icon_stage_path(iid), None))
                out.append((os.path.join(chain.icon_stage_root(), iid,
                                         "icon.png"), None))
            elif kind == "snapped":
                out.append((chain.icon_raw_path(iid), None))
            return out
        if fam == "glyphs" and job_id.startswith("gl_"):
            gid = job_id[len("gl_"):]
            out = []
            if kind == "raw":
                out.append((chain.glyph_stage_path(gid), None))
                out.append((os.path.join(chain.glyph_stage_root(), gid,
                                         "icon.png"), None))
            elif kind == "snapped":
                out.append((chain.glyph_raw_path(gid), None))
            return out
        # unknown/retired family (the icon/icon-sheet/terrain machinery
        # is removed): no thumbs
        return []


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

    def td_rotation_thumb(self, label: str, deg: int):
        """(bytes | None) — the top-down card's rotation preview: the
        snapped north token rotated by the pinned heading degrees with
        PIL NEAREST (the same resampling family the game pins). Cached by
        path|mtime|deg."""
        p = chain.td_north_path(label)
        if not os.path.isfile(p):
            return None
        key = f"{p}|{os.path.getmtime(p)}|rot{deg}"
        data = self._thumb_cache_get(key)
        if data is None:
            try:
                from io import BytesIO  # noqa: PLC0415
                from PIL import Image  # noqa: PLC0415
                img = Image.open(p).convert("RGBA")
                rot = img.rotate(-deg, resample=Image.NEAREST,
                                 expand=False)  # screen y-down: clockwise
                buf = BytesIO()
                rot.save(buf, "PNG")
                data = buf.getvalue()
            except Exception as exc:  # noqa: BLE001 — never kill a request
                log(f"td rotation preview failed for {label}@{deg}°: {exc}")
                return None
            self._thumb_cache_put(key, data)
        return data

    def coast_thumb(self, kind: str) -> bytes | None:
        """The coast card thumbnails: draft = the shipped 16-tile strip
        (vendored result), raw = the pending re-roll strip, snapped = the
        wang mock preview (a live world crop rendered with the pending
        tiles — or the shipped tiles when nothing is pending)."""
        led = chain.coast_ledger()
        shipped = os.path.join(chain.coast_repo_raw_dir(),
                               os.path.basename(led.get("source") or ""))
        pending = chain.coast_pending_path()
        source = pending if (kind in ("raw", "snapped") and pending) \
            else shipped
        if not os.path.isfile(source):
            return None
        key = (kind, source, int(os.path.getmtime(source) * 1000))
        hit = self._thumb_cache_get(("coast",) + key)
        if hit is not None:
            return hit
        with open(source, encoding="utf-8") as fh:
            result = json.load(fh)
        if kind == "snapped":
            data = chain.coast_mock_png(result)
        else:
            data = chain.coast_strip_png(result)
        self._thumb_cache_put(("coast",) + key, data)
        return data

    def chrome_thumb(self, kind: str, family: str) -> bytes | None:
        """The chrome card thumbnails: draft = the canonical vendored
        strip, raw = the pending re-roll strip, snapped = the nine-patch
        mock preview (the pending tiles when one is staged, else the
        canonical tiles). Cached by source+mtime like the other thumbs."""
        trio = chain.chrome_canonical_trio(family)
        pending = chain.chrome_pending_path(family)
        canon = trio.get(".json") if trio else None
        if kind == "draft":
            source = canon
        elif kind == "raw":
            source = pending
        else:  # snapped — the mock: pending tiles when staged, else canon
            source = pending if pending else canon
        if not source or not os.path.isfile(source):
            return None
        key = ("chrome", family, kind, source,
               int(os.path.getmtime(source) * 1000))
        hit = self._thumb_cache_get(key)
        if hit is not None:
            return hit
        with open(source, encoding="utf-8") as fh:
            result = json.load(fh)
        try:
            if kind == "snapped":
                data = chain.chrome_mock_png(result, family)
            else:
                data = chain.chrome_strip_png(result)
        except Exception as exc:  # noqa: BLE001 — never kill a request
            log(f"chrome thumb failed for {family}/{kind}: {exc}")
            return None
        self._thumb_cache_put(key, data)
        return data

    def fx_thumb(self, ship: str, kind: str):
        """(bytes, content_type | None) — the wake card's previews:
        anim = the staged re-roll's API gif; comp = the staged pack's
        frame 0 under the ship's north token; shipped = the same
        composite from the committed assets (what the game shows now).
        Cached by source+mtime like the other thumbs."""
        if kind == "anim":
            gif = (chain.fx_stage_pack(ship) or {}).get("gif")
            if not gif or not os.path.isfile(gif):
                return None, None
            key = f"{gif}|{os.path.getmtime(gif)}"
            data = self._thumb_cache_get(key)
            if data is None:
                with open(gif, "rb") as fh:
                    data = fh.read()
                self._thumb_cache_put(key, data)
            return data, "image/gif"
        pack = (chain.fx_stage_pack(ship) if kind == "comp"
                else chain.fx_shipped_pack(ship))
        if not pack:
            return None, None
        src = (chain.fx_stage_manifest_path() if kind == "comp"
               else os.path.join(self.repo, "assets", "ui", "fx",
                                 "fx_waterline.json"))
        key = f"fx{ship}|{kind}|{os.path.getmtime(src)}"
        data = self._thumb_cache_get(key)
        if data is None:
            try:
                data = chain.fx_composite_png(ship, pack)
            except Exception as exc:  # noqa: BLE001 — never kill a request
                log(f"fx composite failed for {ship}/{kind}: {exc}")
                return None, None
            self._thumb_cache_put(key, data)
        return data, "image/png"

    def thumb_bytes(self, kind: str, job_id: str):
        """(bytes, None, served: bool) — file bytes through the in-memory
        cache keyed by source path+mtime, so browser bursts don't re-read
        the store."""
        try:
            candidates = self.thumb_candidates(kind, job_id)
        except KeyError:
            return None, None, False
        for path, _mirrored in candidates:
            if not os.path.isfile(path):
                continue
            mtime = os.path.getmtime(path)
            key = f"{path}|{mtime}"
            data = self._thumb_cache_get(key)
            if data is None:
                with open(path, "rb") as fh:
                    data = fh.read()
                self._thumb_cache_put(key, data)
            return data, None, True
        return None, None, False

    # -- registry ---------------------------------------------------------
    def registry(self) -> list[dict]:
        """Enumerate the pixellab family cards and merge canonical +
        studio state. NEVER raises: per-job guard wraps each entry — a
        failing card is skipped with a warning, never a 500."""
        warnings: list[str] = []
        report = self._read_json(os.path.join(self.raw(), "report.json"), {})
        with self.lock:
            prompts = self.prompts()
            state = self.state().get("jobs", {})
            accepted = self.accepted()
        jobs = []
        # The top-down ship family leads the registry (§4.8 2026-11-07);
        # fleet labels only (≥1 snapped north token).
        for label in chain.td_fleet_labels():
            try:
                jobs.append(self._td_entry(label, prompts, state, accepted))
            except Exception as exc:  # noqa: BLE001 — degrade, never die
                warnings.append(f"td_{label}: {type(exc).__name__}: {exc}")
                log(f"registry SKIP td_{label}: {warnings[-1]}")
        # The wake VFX cards follow (§4.8 2026-11-08 per-ship revision):
        # one per ship type.
        for ship in chain.FX_SHIPS:
            try:
                jobs.append(self._fx_entry(ship, prompts, state, accepted))
            except Exception as exc:  # noqa: BLE001 — degrade, never die
                warnings.append(f"fx_{ship}: {type(exc).__name__}: {exc}")
                log(f"registry SKIP fx_{ship}: {warnings[-1]}")
        # The coast tileset card (§4.8 2026-11-06 — one card per tileset)
        try:
            jobs.append(self._coast_entry(prompts, state, accepted))
        except Exception as exc:  # noqa: BLE001 — degrade, never die
            warnings.append(f"coast: {type(exc).__name__}: {exc}")
            log(f"registry SKIP coast: {warnings[-1]}")
        # The chrome tileset cards (§4.8 2026-11-08, one per family):
        # frame (parchment panel plate) + click (the light parchment
        # click plate — the 2026-11-08 evening revision; the chestnut
        # set is retired)
        for fam in chain.CHROME_FAMILIES:
            try:
                jobs.append(self._chrome_entry(fam, prompts, state,
                                               accepted))
            except Exception as exc:  # noqa: BLE001 — degrade, never die
                warnings.append(f"chrome_{fam}: {type(exc).__name__}: {exc}")
                log(f"registry SKIP chrome_{fam}: {warnings[-1]}")
        # The prompt-only icon family (§4.8 2026-11-08): one card per id
        # (the doc-first guard list enumerates them — no drafts).
        for iid in chain.icon_ids():
            try:
                jobs.append(self._icon_id_entry(iid, prompts, state,
                                                accepted))
            except Exception as exc:  # noqa: BLE001 — degrade, never die
                warnings.append(f"ic_{iid}: {type(exc).__name__}: {exc}")
                log(f"registry SKIP ic_{iid}: {warnings[-1]}")
        # The glyph family: 6 markers + 6 facility tokens, same envelope.
        for gid in chain.glyph_ids():
            try:
                jobs.append(self._glyph_id_entry(gid, prompts, state,
                                                 accepted))
            except Exception as exc:  # noqa: BLE001 — degrade, never die
                warnings.append(f"gl_{gid}: {type(exc).__name__}: {exc}")
                log(f"registry SKIP gl_{gid}: {warnings[-1]}")
        self.last_warnings = warnings
        # backfill: persist each card's original prompt ONCE, so the edit
        # base stays stable and "↺ original" is byte-identical. Exact
        # originals are already in state.json (written by the worker).
        missing = {}
        for j in jobs:
            if j.get("original_prompt_source") == "default":
                continue  # never pin fallback wording
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
        flagged_ids = [j["id"] for j in jobs if j["flagged"]]
        return jobs, counts, flagged_ids

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

    def _generate_coast(self, order: dict) -> None:
        """The coast tileset re-roll (§4.8 2026-11-06): one corner-tileset
        call; the prompt is the free-text style clause appended to all
        three vendored descriptions; the result stays in the studio cache
        until Accept stages it into the vendored store + rebuild."""
        job_id = chain.COAST_CARD_ID
        style = order.get("prompt")
        seed = order["seed"] if order.get("seed") is not None \
            else chain.coast_defaults()["seed"]
        with self.lock:
            self.current = {"type": "generate", "job": job_id,
                            "prompt": style, "seed": seed,
                            "stage": "posting",
                            "started_epoch": time.time()}
        log(f"generating coast tileset seed={seed} style={style!r}")
        rec = {"prompt": style, "seed": seed, "status": "running",
               "started_at": time.strftime("%H:%M:%S")}
        try:
            def stage(name: str) -> None:
                with self.lock:
                    if self.current and self.current["job"] == job_id:
                        self.current["stage"] = name
            started = time.time()
            out = chain.coast_reroll(seed=seed, style=style,
                                     poll_status=stage)
            rec.update({
                "status": "done",
                "tileset_id": out["tileset_id"],
                "studio_path": out["studio_path"],
                "seconds": round(time.time() - started, 1),
                "finished_at": time.strftime("%H:%M:%S"),
            })
            log(f"coast re-roll done: tileset {out['tileset_id']} "
                f"({rec['seconds']}s)")
        except Exception as exc:  # noqa: BLE001 — named failure in state
            rec.update({"status": "error", "error": f"{type(exc).__name__}: "
                                                      f"{exc}"})
            log(f"coast re-roll FAILED: {rec['error']}")
        with self.lock:
            st = self.state()
            st.setdefault("jobs", {})[job_id] = rec
            self.save_state(st)
            self.current = None

    def _generate_chrome(self, order: dict) -> None:
        """The chrome tileset re-roll (§4.8 2026-11-08): one
        create-tileset call per family; the prompt is the free-text style
        clause appended to all three pinned descriptions; the result
        stays in the studio cache until Accept stages the trio into the
        vendored store + re-runs the ingest."""
        family = order["job"][len(chain.CHROME_CARD_PREFIX):]
        job_id = chain.chrome_card_id(family)
        style = order.get("prompt")
        seed = order["seed"] if order.get("seed") is not None \
            else chain.chrome_defaults(family)["seed"]
        with self.lock:
            self.current = {"type": "generate", "job": job_id,
                            "prompt": style, "seed": seed,
                            "stage": "posting",
                            "started_epoch": time.time()}
        log(f"generating chrome {family} tileset seed={seed} "
            f"style={style!r}")
        rec = {"prompt": style, "seed": seed, "status": "running",
               "started_at": time.strftime("%H:%M:%S")}
        try:
            def stage(name: str) -> None:
                with self.lock:
                    if self.current and self.current["job"] == job_id:
                        self.current["stage"] = name
            started = time.time()
            out = chain.chrome_reroll(family, seed=seed, style=style,
                                      poll_status=stage)
            rec.update({
                "status": "done",
                "tileset_id": out["tileset_id"],
                "studio_path": out["studio_path"],
                "seconds": round(time.time() - started, 1),
                "finished_at": time.strftime("%H:%M:%S"),
            })
            log(f"chrome {family} re-roll done: tileset "
                f"{out['tileset_id']} ({rec['seconds']}s)")
        except Exception as exc:  # noqa: BLE001 — named failure in state
            rec.update({"status": "error", "error": f"{type(exc).__name__}: "
                                                      f"{exc}"})
            log(f"chrome {family} re-roll FAILED: {rec['error']}")
        with self.lock:
            st = self.state()
            st.setdefault("jobs", {})[job_id] = rec
            self.save_state(st)
            self.current = None

    def _ingest_order(self, order: dict) -> None:
        """Accept→game: the canonical snapped dir is the ingestion input;
        run build_ui_art --import-ships (idempotent full-ladder re-run) and
        surface in-game ✓ / REJECTED:<reason> per job."""
        try:
            fam = chain.parse_job(order["job"])[0]
        except KeyError:
            fam = None
        if fam == "topdown":
            self._td_ingest_order(order)
            return
        if fam == "fx":
            self._fx_ingest_order(order)
            return
        if fam in ("icons", "glyphs"):
            self._pixellab_id_ingest_order(order, fam)
            return
    def _pixellab_id_ingest_order(self, order: dict, fam: str) -> None:
        """Accept→game for the ic_/gl_ cards (§4.8 2026-11-08): a staged
        re-roll moves into the canonical pixellab raw store first (the
        coast/fx staging contract), then build_ui_art --import-icons /
        --import-glyphs re-lands the WHOLE family (idempotent — the
        union ingest). Gate: the id's ledger record + the shipped hero
        file (assets/ui/icons64/<id>.png; markers64/tokens64 <bare>.png
        for glyphs)."""
        job_id = order["job"]
        with self.lock:
            self.current = {"type": "ingest", "job": job_id,
                            "stage": "stage-swap",
                            "started_epoch": time.time()}
        self._set_ingest_state(job_id, {"state": "running",
                                        "started_at": time.strftime(
                                            "%H:%M:%S")})
        t0 = time.time()
        try:
            if fam == "icons":
                iid = job_id[len("ic_"):]
                if os.path.isfile(chain.icon_stage_path(iid)):
                    chain.icon_accept_stage(iid)
                cmd = [sys.executable,
                       os.path.join(self.repo, "tools", "build_ui_art.py"),
                       "--import-icons", chain.icon_raw_dir()]
                ledger_fam, ledger_key = "icons", iid
                hero = os.path.join(self.repo, "assets", "ui", "icons64",
                                    f"{iid}.png")
            else:
                gid = job_id[len("gl_"):]
                if os.path.isfile(chain.glyph_stage_path(gid)):
                    chain.glyph_accept_stage(gid)
                cmd = [sys.executable,
                       os.path.join(self.repo, "tools", "build_ui_art.py"),
                       "--import-glyphs", chain.glyph_raw_dir()]
                bare = (gid[len("marker_"):] if gid.startswith("marker_")
                        else gid[len("facility_"):])
                ledger_fam, ledger_key = (
                    "markers" if gid.startswith("marker_")
                    else "facility"), gid
                hero_dir = ("markers64" if gid.startswith("marker_")
                            else "tokens64")
                hero = os.path.join(self.repo, "assets", "ui", hero_dir,
                                    f"{bare}.png")
            with self.lock:
                if self.current:
                    self.current["stage"] = "build-ladder"
            log(f"ingesting {job_id} -> {cmd[-2]} {cmd[-1]}")
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=self.INGEST_TIMEOUT_S,
                                  cwd=self.repo)
            out = (proc.stdout or "") + "\n" + (proc.stderr or "")
            tail = out.strip()[-700:]
            ledger = self._read_json(
                os.path.join(self.repo, "tools", "ui_art",
                             "ingest_ledger.json"), {})
            rec = (ledger.get(ledger_fam) or {}).get(ledger_key) or {}
            ok = proc.returncode == 0 and bool(rec) \
                and os.path.isfile(hero)
            if ok:
                ing = {"state": "in-game", "exit_code": 0,
                       "reason": (f"{ledger_key} landed "
                                  f"({rec.get('size')}px, seed "
                                  f"{rec.get('seed')})"),
                       "accepted_at": rec.get("accepted_at"),
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            else:
                rej = next((r for r in ledger.get("rejected", [])
                            if r.get("job") == ledger_key), None)
                ing = {"state": "error",
                       "exit_code": proc.returncode,
                       "reason": (f"{ledger_key} did not land "
                                  f"(ledgered: {bool(rec)}, hero: "
                                  f"{os.path.isfile(hero)})")
                                  + (f" — {rej.get('reason')}: "
                                     f"{rej.get('detail')}" if rej else "")
                                  + (f" (exit {proc.returncode}): "
                                     f"{tail[-200:]}" if proc.returncode
                                     else ""),
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
            # the import re-lands the WHOLE family — stamp the sibling
            # cards in-game too (their bytes are unchanged; idempotent)
            with self.lock:
                st = self.state()
                siblings = [f"ic_{i}" for i in chain.icon_ids()] \
                    if fam == "icons" \
                    else [f"gl_{g}" for g in chain.glyph_ids()]
                for other in siblings:
                    if other == job_id:
                        continue
                    oth = st.setdefault("jobs", {}).setdefault(other, {})
                    oi = (oth.setdefault("ingest", {})
                          if isinstance(oth.get("ingest"), dict)
                          else oth.setdefault("ingest", {}))
                    if oi.get("state") != "in-game":
                        oi.update({"state": "in-game",
                                   "reason": "family re-land (idempotent)",
                                   "finished_at": ing["finished_at"]})
                self.save_state(st)
            log(f"ingest {job_id}: in-game (family re-landed)")

    def _td_ingest_order(self, order: dict) -> None:
        """Accept→game for a top-down ship (§4.8 2026-11-07): the
        pixellab_topdown store IS the ingestion input (its layout is
        `<ship>/snapped/north.png` + the manifest — what
        run_ship_ingest_north walks; a flat hull_<ship>.png stage would
        match NOTHING and the build would silently fall back to the
        generated tokens). Pre-check fleet completeness (a gap would
        revoke that ship's ledger token and fall back to generated art),
        then run build_ui_art --import-ships-north <raw_root>. The whole
        fleet re-lands. Gate: this ship's `hull_<ship>` ledger token
        with pennant 'raw'."""
        job_id = order["job"]
        label = job_id[len("td_"):]
        ship = chain.td_ship_of(label)
        with self.lock:
            self.current = {"type": "ingest", "job": job_id,
                            "stage": "pre-check",
                            "started_epoch": time.time()}
        log(f"ingesting {job_id} -> build_ui_art --import-ships-north")
        self._set_ingest_state(job_id, {"state": "running",
                                        "started_at": time.strftime(
                                            "%H:%M:%S")})
        t0 = time.time()
        raw_root = os.path.join(self.raw(), "pixellab_topdown")
        try:
            if not os.path.isfile(chain.td_north_path(label)):
                raise RuntimeError(f"{label} has no snapped north token "
                                   f"— re-roll first")
            fleet = chain.td_fleet_labels()
            if label not in fleet:
                fleet.append(label)
            missing = [lab for lab in fleet
                       if not os.path.isfile(chain.td_north_path(lab))]
            if missing:
                raise RuntimeError(f"missing snapped north tokens: "
                                   f"{missing[:8]}")
            with self.lock:
                if self.current:
                    self.current["stage"] = "build-ladder"
            cmd = [sys.executable,
                   os.path.join(self.repo, "tools", "build_ui_art.py"),
                   "--import-ships-north", raw_root]
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
                rec = tokens.get(f"hull_{ship}") or {}
                ok = rec.get("pennant") == "raw"
                if ok:
                    ing = {"state": "in-game", "exit_code": 0,
                           "reason": f"raw north token "
                                     f"({rec.get('size')}px, "
                                     f"{len(tokens)} fleet tokens)",
                           "accepted_at": rec.get("accepted_at"),
                           "log_tail": tail,
                           "seconds": round(time.time() - t0, 1)}
                else:
                    rej = next((r for r in ledger.get("rejected", [])
                                if r.get("job") == f"hull_{ship}"), None)
                    ing = {"state": "error", "exit_code": 0,
                           "reason": f"hull_{ship} did not land "
                                     f"(pennant raw: {bool(rec)})"
                                     + (f" — {rej.get('reason')}: "
                                        f"{rej.get('detail')}" if rej
                                        else ""),
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
            # the import re-lands the WHOLE fleet — stamp the other ship
            # cards in-game too (their bytes are unchanged; idempotent)
            with self.lock:
                st = self.state()
                for lab in chain.td_fleet_labels():
                    other = f"td_{lab}"
                    if other == job_id:
                        continue
                    oth = st.setdefault("jobs", {}).setdefault(other, {})
                    oi = (oth.setdefault("ingest", {})
                          if isinstance(oth.get("ingest"), dict)
                          else oth.setdefault("ingest", {}))
                    if oi.get("state") != "in-game":
                        oi.update({"state": "in-game",
                                   "reason": "fleet re-land (idempotent)",
                                   "finished_at": ing["finished_at"]})
                self.save_state(st)
        with self.lock:
            self.current = None
        log(f"ingest {job_id}: {ing['state']}"
            + (f" ({ing.get('reason')})" if ing.get("reason") else ""))

    def _fx_ingest_order(self, order: dict) -> None:
        """Accept→game for a wake ship (§4.8 2026-11-08 per-ship
        revision): stage the re-rolled ship into the canonical raw store
        (model_raw/pixellab_vfx/v6/), then run
        build_ui_art --import-fx-pixellab — ALL 16 ships re-land
        (idempotent), so the other wake cards stamp in-game too. Gate:
        the ship's record (sheet sha256 + effect_id) in the committed fx
        ledger."""
        job_id = order["job"]
        ship = job_id[len("fx_"):]
        with self.lock:
            self.current = {"type": "ingest", "job": job_id,
                            "stage": "staging",
                            "started_epoch": time.time()}
        log(f"ingesting {job_id} -> build_ui_art --import-fx-pixellab")
        self._set_ingest_state(job_id, {"state": "running",
                                        "started_at": time.strftime(
                                            "%H:%M:%S")})
        t0 = time.time()
        try:
            chain.fx_accept_stage(ship)
            with self.lock:
                if self.current:
                    self.current["stage"] = "build-ladder"
            cmd = [sys.executable,
                   os.path.join(self.repo, "tools", "build_ui_art.py"),
                   "--import-fx-pixellab"]
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=self.INGEST_TIMEOUT_S,
                                  cwd=self.repo)
            out = (proc.stdout or "") + "\n" + (proc.stderr or "")
            ledger = self._read_json(
                os.path.join(self.repo, "tools", "assets", "pixellab_raw",
                             "pixellab_vfx_ledger.json"), {})
            rec = (ledger.get("ships") or {}).get(ship) or {}
            tail = out.strip()[-700:]
            ok = (proc.returncode == 0 and rec.get("sheet_sha256")
                  and rec.get("effect_id"))
            if ok:
                ing = {"state": "in-game", "exit_code": 0,
                       "reason": f"wake sheet landed "
                                 f"(effect {str(rec.get('effect_id'))[:8]}…)",
                       "accepted_at": rec.get("accepted_at"),
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            elif proc.returncode != 0:
                ing = {"state": "error", "exit_code": proc.returncode,
                       "reason": f"build failed (exit {proc.returncode}): "
                                 f"{tail[-300:]}",
                       "log_tail": tail,
                       "seconds": round(time.time() - t0, 1)}
            else:
                ing = {"state": "error", "exit_code": 0,
                       "reason": f"fx {ship} did not land in the ledger",
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
            # the import re-lands ALL ships — stamp the other wake cards
            # in-game too (their bytes are unchanged; idempotent)
            with self.lock:
                st = self.state()
                for other_ship in chain.FX_SHIPS:
                    other = f"fx_{other_ship}"
                    if other == job_id:
                        continue
                    oth = st.setdefault("jobs", {}).setdefault(other, {})
                    oi = (oth.setdefault("ingest", {})
                          if isinstance(oth.get("ingest"), dict)
                          else oth.setdefault("ingest", {}))
                    if oi.get("state") != "in-game":
                        oi.update({"state": "in-game",
                                   "reason": "fx family re-land "
                                             "(idempotent)",
                                   "finished_at": ing["finished_at"]})
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
            if job_id == chain.COAST_CARD_ID:
                self._generate_coast(order)
                return
            if job_id.startswith(chain.CHROME_CARD_PREFIX) \
                    and job_id[len(chain.CHROME_CARD_PREFIX):] \
                    in chain.CHROME_FAMILIES:
                self._generate_chrome(order)
                return
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
                if fam == "topdown":
                    # top-down ship family: in-process tool call (the
                    # description is free text; the envelope stays pinned)
                    result = chain.td_generate(job_id[len("td_"):], prompt,
                                               seed, on_stage=stage)
                    rec.update(result)
                    rec["status"] = result.get("status", "done")
                elif fam == "fx":
                    # wake VFX family: in-process tool call (the
                    # description is free text; the envelope has no seed)
                    result = chain.fx_generate(int(job_id[len("fx_"):]),
                                               prompt)
                    rec.update(result)
                    rec["status"] = result.get("status", "done")
                elif fam == "icons":
                    # prompt-only icon family: in-process tool call, both
                    # stages land in the STAGING store (the fx contract —
                    # a discarded re-roll never touches the canonical raw)
                    result = chain.icon_generate(job_id[len("ic_"):],
                                                 prompt, seed,
                                                 on_stage=stage)
                    rec.update(result)
                    rec["status"] = result.get("status", "done")
                elif fam == "glyphs":
                    result = chain.glyph_generate(job_id[len("gl_"):],
                                                  prompt, seed,
                                                  on_stage=stage)
                    rec.update(result)
                    rec["status"] = result.get("status", "done")
                else:
                    raise RuntimeError(f"unknown job shape {job_id!r} "
                                       f"(the legacy icon chain is gone)")
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
                                 "registry":
                                     {"warnings":
                                      list(self.studio.last_warnings)}})
            elif path == "/api/layout/file":
                info = self.studio.layout_file()  # never raises
                if info.get("content") is None:
                    self._json(404, info)  # the {content:null} shape
                else:
                    self._json(200, info)
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
        # /thumb/td/<label>/<deg>.png — the top-down strip: the snapped
        # north token rotated by the pinned heading degrees (NEAREST)
        mp = re.match(r"^/thumb/td/([a-z0-9_]+)/(\d+)\.png$", path)
        if mp:
            data = self.studio.td_rotation_thumb(mp.group(1),
                                                 int(mp.group(2)))
            if data is None:
                self._json(404, {"error": f"no td thumb for "
                                          f"{mp.group(1)}@{mp.group(2)}°"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        # /thumb/fx/<ship>/<kind> — the wake card: anim.gif (staged API
        # gif), comp.png (staged wake under the ship), shipped.png (the
        # committed family — what the game shows now)
        mf = re.match(r"^/thumb/fx/([a-z_]+)/(anim|comp|shipped)\."
                      r"(?:gif|png)$", path)
        if mf:
            ship, kind = mf.group(1), mf.group(2)
            if ship not in chain.FX_SHIPS:
                self._json(404, {"error": f"unknown fx ship {ship}"})
                return
            data, ctype = self.studio.fx_thumb(ship, kind)
            if data is None:
                self._json(404, {"error": f"no fx {kind} thumb for "
                                          f"{ship}"})
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype or "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        m = re.match(r"^/thumb/(draft|raw|snapped)/([a-z0-9_]+)\.png$",
                     path)
        mc = re.match(r"^/thumb/(draft|raw|snapped)/coast\.png$", path)
        mch = re.match(r"^/thumb/(draft|raw|snapped)/chrome_"
                       r"(" + "|".join(chain.CHROME_FAMILIES) + r")\.png$",
                       path)
        if mc:
            data = self.studio.coast_thumb(mc.group(1))
            if data is None:
                self._json(404, {"error": f"no coast thumb for "
                                            f"{mc.group(1)}"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        if mch:
            data = self.studio.chrome_thumb(mch.group(1), mch.group(2))
            if data is None:
                self._json(404, {"error": f"no chrome thumb for "
                                          f"{mch.group(2)} "
                                          f"({mch.group(1)})"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
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
            elif path == "/api/layout/commit":
                self._layout_commit(data)
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:  # noqa: BLE001 — per-request guard
            log(f"POST {path} failed: {type(exc).__name__}: {exc}")
            self._json(500, {"error": str(exc)})

    def _job_ok(self, job_id: str) -> bool:
        if job_id == chain.COAST_CARD_ID:
            return True
        if job_id.startswith(chain.CHROME_CARD_PREFIX) \
                and JOB_RE.match(job_id):
            return job_id[len(chain.CHROME_CARD_PREFIX):] \
                in chain.CHROME_FAMILIES
        if job_id.startswith(HIDDEN_PREFIXES):
            return False  # the retired ship families + hidden terrain
        if job_id.startswith("fx_") and JOB_RE.match(job_id):
            return job_id[len("fx_"):] in chain.FX_SHIPS
        if job_id.startswith("td_") and JOB_RE.match(job_id):
            return chain.td_exists(job_id[len("td_"):])
        if job_id.startswith("ic_") and JOB_RE.match(job_id):
            return job_id[len("ic_"):] in chain.icon_ids()
        if job_id.startswith("gl_") and JOB_RE.match(job_id):
            return job_id[len("gl_"):] in chain.glyph_ids()
        return False  # unknown shape — the legacy drafts store is gone

    def _accept_coast(self) -> None:
        """Accept the pending coast re-roll: stage the vendored trio into
        tools/assets/pixellab_raw/, repoint build_terrain_pixellab.py's
        pinned SOURCE_JSON, and run the rebuild (the game tokens + ledger
        regenerate from the new raw). Git add/commit stays with the
        user — this is a repo change, not a cache write."""
        pending = chain.coast_pending_path()
        if not pending:
            self._json(409, {"error": "no pending coast re-roll to accept"})
            return
        with open(pending, encoding="utf-8") as fh:
            doc = json.load(fh)
        tid = doc["tileset_id"]
        raw_dir = chain.coast_repo_raw_dir()
        files = {
            f"tileset_coastline_{tid}.json": doc["result"],
            f"tileset_coastline_{tid}_request.json": doc["payload"],
            f"tileset_coastline_{tid}_submit.json": {
                "usage": None, "background_job_id": doc["job_id"],
                "tileset_id": tid, "status": "completed",
            },
        }
        for fname, payload in files.items():
            chain.atomic_write(os.path.join(raw_dir, fname),
                               json.dumps(payload, indent=1,
                                          ensure_ascii=False)
                               .encode("utf-8"))
        bp = os.path.join(chain.repo, "tools", "build_terrain_pixellab.py")
        with open(bp, encoding="utf-8") as fh:
            bp_text = fh.read()
        new_text, n = re.subn(
            r'tileset_coastline_[0-9a-f-]+\.json',
            f"tileset_coastline_{tid}.json", bp_text)
        if n == 0:
            self._json(500, {"error": "SOURCE_JSON pin not found in "
                                       "build_terrain_pixellab.py"})
            return
        chain.atomic_write(bp, new_text.encode("utf-8"))
        proc = subprocess.run([sys.executable, bp], capture_output=True,
                              text=True, timeout=300)
        if proc.returncode != 0:
            self._json(500, {"error": "build_terrain_pixellab FAILED",
                             "stderr": proc.stderr[-800:]})
            return
        with self.lock:
            st = self.state()
            rec = st.setdefault("jobs", {}).setdefault(
                chain.COAST_CARD_ID, {})
            rec["status"] = "accepted"
            rec["accepted_tileset_id"] = tid
            self.save_state(st)
            acc = self.accepted()
            acc[chain.COAST_CARD_ID] = {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "source": "studio",
                "seed": rec.get("seed"),
                "tileset_id": tid,
            }
            self.save_accepted(acc)
        log(f"coast tileset accepted: {tid} (builder rebuilt tokens+ledger)")
        self._json(200, {"ok": True, "job": chain.COAST_CARD_ID,
                         "tileset_id": tid})

    def _accept_chrome(self, family: str) -> None:
        """Accept the pending chrome re-roll (§4.8 2026-11-08): copy the
        staged trio into tools/assets/pixellab_raw/ under its canonical
        name, DELETE the previous canonical trio for the family (the
        ingest requires exactly ONE tileset_chrome_<family>_*.json —
        _chrome_find_tileset), re-run build_ui_art
        --import-chrome-pixellab (the 18 derived singles + chrome{}
        ledger regenerate from the new raw), and gate on the fresh
        chrome{} section listing the new tileset id. Git add/commit
        stays with the user — this is a repo change, not a cache
        write."""
        job_id = chain.chrome_card_id(family)
        pending = chain.chrome_pending_path(family)
        if not pending:
            self._json(409, {"error": f"no pending chrome {family} "
                                      "re-roll to accept"})
            return
        m = re.search(rf"tileset_chrome_{family}_([0-9a-f-]+)\.json$",
                      os.path.basename(pending))
        if not m:
            self._json(500, {"error": "staged trio has a malformed name"})
            return
        tid = m.group(1)
        base = pending[:-len(".json")]
        staged = {"": pending, "_request": f"{base}_request.json",
                  "_submit": f"{base}_submit.json"}
        for path in staged.values():
            if not os.path.isfile(path):
                self._json(500, {"error": f"staged trio file missing: "
                                          f"{os.path.basename(path)}"})
                return
        raw_dir = chain.chrome_raw_dir()
        try:
            # stage-swap: the new trio lands first, then every older trio
            # file for the family is deleted (copy-first keeps exactly one
            # trio in place for the builder). The tid is PARSED out of each
            # name — a substring test would eat the new trio's own
            # _request/_submit siblings (they carry "_<tid>_request.json",
            # which never contains "_<tid>.json").
            prefix = f"tileset_chrome_{family}_"
            for ext, path in staged.items():
                with open(path, "rb") as fh:
                    chain.atomic_write(
                        os.path.join(raw_dir, f"{prefix}{tid}{ext}.json"),
                        fh.read())
            for name in sorted(os.listdir(raw_dir)):
                if not name.startswith(prefix) or not name.endswith(".json"):
                    continue
                stem = name[len(prefix):-len(".json")]
                for suffix in ("_request", "_submit"):
                    if stem.endswith(suffix):
                        stem = stem[:-len(suffix)]
                        break
                if stem != tid:
                    os.remove(os.path.join(raw_dir, name))
        except Exception as exc:  # noqa: BLE001 — surface in the UI
            self._json(500, {"error": f"chrome stage-swap failed: "
                                      f"{type(exc).__name__}: {exc}"})
            return
        proc = subprocess.run(
            [sys.executable,
             os.path.join(self.studio.repo, "tools", "build_ui_art.py"),
             "--import-chrome-pixellab"],
            capture_output=True, text=True, timeout=300,
            cwd=self.studio.repo)
        tail = ((proc.stdout or "") + "\n" + (proc.stderr or "")
                ).strip()[-700:]
        if proc.returncode != 0:
            self._json(500, {"error": "build_ui_art "
                                      "--import-chrome-pixellab FAILED",
                             "stderr": tail[-800:]})
            return
        # gate: the fresh chrome{} ledger section lists the new tileset id
        ledger = self.studio._read_json(
            os.path.join(self.studio.repo, "tools", "ui_art",
                         "ingest_ledger.json"), {})
        rec = ((ledger.get("chrome") or {}).get("tilesets") or {}) \
            .get(family) or {}
        if rec.get("tileset_id") != tid:
            self._json(500, {"error": f"chrome gate failed: ledger lists "
                                      f"{family}="
                                      f"{rec.get('tileset_id')!r}, "
                                      f"expected {tid!r}",
                             "log_tail": tail})
            return
        with self.studio.lock:
            st = self.studio.state()
            srec = st.setdefault("jobs", {}).setdefault(job_id, {})
            srec["status"] = "accepted"
            srec["accepted_tileset_id"] = tid
            self.studio.save_state(st)
            acc = self.studio.accepted()
            acc[job_id] = {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "source": "studio",
                "seed": srec.get("seed"),
                "tileset_id": tid,
            }
            self.studio.save_accepted(acc)
        log(f"chrome {family} tileset accepted: {tid} (ingest re-landed "
            f"the chrome singles)")
        self._json(200, {"ok": True, "job": job_id, "tileset_id": tid})

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

    def _layout_commit(self, data: dict) -> None:
        """POST /api/layout/commit — the session document is the FULL v2
        layout {version: 2, screens: {<screen>: {elements, lists}}}
        (10-* §4.23; the browser session starts from the committed file,
        so edits compose); the server never merges. A cheap v2-shape
        check runs BEFORE the ~30 s gate so a v1-shaped or partial body
        fails fast with a named error; the validator remains the
        authority. Always 200: the gate verdict rides the body, never
        a 500."""
        layout = data.get("layout")
        if layout is None:
            self._json(200, {"ok": False,
                             "error": "missing 'layout' — the full v2 "
                                      "document "
                                      "{version: 2, screens: {…}}"})
            return
        if not isinstance(layout, dict):
            self._json(200, {"ok": False,
                             "error": "'layout' must be the v2 document "
                                      "object "
                                      "{version: 2, screens: {…}}"})
            return
        if layout.get("version") != 2 or not isinstance(
                layout.get("screens"), dict):
            self._json(200, {"ok": False,
                             "error": "'layout' must be v2-shaped "
                                      "{version: 2, screens: {…}} — a "
                                      "v1 screen map is not accepted "
                                      "(10-* §4.23)"})
            return
        self._json(200, self.studio.commit_layout(layout))

    def _accept(self, data: dict) -> None:
        job_id = data.get("job", "")
        if job_id == chain.COAST_CARD_ID:
            self._accept_coast()
            return
        if job_id.startswith(chain.CHROME_CARD_PREFIX) \
                and job_id[len(chain.CHROME_CARD_PREFIX):] \
                in chain.CHROME_FAMILIES:
            self._accept_chrome(job_id[len(chain.CHROME_CARD_PREFIX):])
            return
        if not self._job_ok(job_id):
            self._json(404, {"error": f"unknown job {job_id!r}"})
        fam, subject, _direction = chain.parse_job(job_id)
        with self.studio.lock:
            st = self.studio.state().get("jobs", {}).get(job_id)
            acc = self.studio.accepted()
            if fam in ("topdown", "fx", "icons", "glyphs"):
                # the pixellab store IS the ingestion input (the td
                # snapped/ dir; the staged fx dir on accept) — nothing to
                # place here, the ingest order does the staging
                source = "pixellab"
                ingest_state = "queued"
            else:
                raise RuntimeError(f"unknown job shape {job_id!r} "
                                   f"(the legacy icon chain is gone)")
            acc[job_id] = {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "source": source,
                "seed": (st or {}).get("seed"),
                "prompt": (st or {}).get("prompt"),
                "ingest": ingest_state,
            }
            if fam == "topdown":
                # record the label's provenance and queue the raw import
                # (the whole fleet re-lands, idempotent)
                manifest = chain.td_manifest().get(subject) or {}
                acc[job_id]["job_id"] = manifest.get("job_id")
                st_ = self.studio.state()
                rec = st_.setdefault("jobs", {}).setdefault(job_id, {})
                rec["ingest"] = {"state": "queued",
                                 "queued_at": acc[job_id]["at"]}
                self.studio.save_state(st_)
            elif fam == "fx":
                # record the staged re-roll's provenance (the staged
                # manifest record becomes the ingest input) and queue the
                # fx import (all 16 ships re-land, idempotent)
                manifest = chain.fx_stage_manifest().get(subject) or {}
                acc[job_id]["effect_id"] = manifest.get("effect_id")
                acc[job_id]["pending"] = bool(manifest)
                st_ = self.studio.state()
                rec = st_.setdefault("jobs", {}).setdefault(job_id, {})
                rec["ingest"] = {"state": "queued",
                                 "queued_at": acc[job_id]["at"]}
                self.studio.save_state(st_)
            self.studio.save_accepted(acc)
        if fam in ("topdown", "fx", "icons", "glyphs"):
            self.studio.enqueue_ingest(job_id)
        log(f"accepted {job_id} ({source}, ingest={ingest_state})")
        self._json(200, {"ok": True, "job": job_id, "accepted":
                         acc[job_id],
                         "ingest": {"state": ingest_state},
                         "note": ("restart the game to see it — the token "
                                  "runtime loads data artifacts, no import "
                                  "refresh needed"
                                  if fam in ("topdown", "fx", "icons",
                                             "glyphs")
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
                    help="MAIN repo root (canonical raw store inputs "
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
