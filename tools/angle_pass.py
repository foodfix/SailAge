#!/usr/bin/env python3
"""Angle pass — the multi-angle ship token pipeline, stage 2.

Drives the committed ComfyUI workflow
``tools/ui_art/workflows/ship_multi_angle.json`` over the hi-res side
views from ``tools/sideview_pass.py`` (stage 1): upload the side view to
ComfyUI :8000 ``/upload/image``, patch the LoadImage node + per-ship save
prefixes, POST ``/prompt``, poll ``/history``, fetch every SaveImage
output via ``/view``. Writes raw model output gitignored to
``model_raw/angles/<ship>/<dir>.png`` (dir id = the save prefix's last
path segment) plus an ``angles.json`` manifest (input, prompt_id, per-dir
files, seconds). The w/e pair stays the untouched side view + its ingest
h-flip; the four generated dirs are n/s/nw/sw. Raw output is never
committed (90-* §9.2).

Usage:
  python3 tools/angle_pass.py run [ship ...]   # default: all 16
  python3 tools/angle_pass.py status
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
import uuid

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "model_studio"))
sys.path.insert(0, os.path.join(REPO, "tools"))

import chain  # noqa: E402 — the validated rembg/key/snap chain (snap trial)
COMFY = "http://127.0.0.1:8000"
WORKFLOW = os.path.join(REPO, "tools", "ui_art", "workflows",
                        "ship_multi_angle.json")
SIDEVIEWS = os.path.join(REPO, "tools", "ui_art", "model_raw", "sideviews")
OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw", "angles")
MANIFEST = os.path.join(OUT_DIR, "angles.json")
CLIENT_ID = "sailage-anglepass"
POLL_S, POLL_MAX = 2, 450


def _ships() -> list[str]:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        return [s["id"] for s in json.load(fh)["ship_types"]]


def _multipart(fields: dict, fname: str, content: bytes) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = []
    for key, val in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; "
                     f'name="{key}"\r\n\r\n{val}\r\n')
    head = "".join(parts).encode("utf-8") + (
        f"--{boundary}\r\nContent-Disposition: form-data; "
        f'name="image"; filename="{fname}"\r\n'
        f"Content-Type: image/png\r\n\r\n").encode("utf-8")
    return head + content + f"\r\n--{boundary}--".encode("utf-8"), boundary


def _atomic(path: str, data: bytes) -> None:
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


def run_ship(ship: str, wf: dict) -> dict:
    with open(os.path.join(SIDEVIEWS, f"{ship}_side.png"), "rb") as fh:
        side_bytes = fh.read()
    # upload the side view into ComfyUI's input dir
    fname = f"{ship}_side_{uuid.uuid4().hex[:8]}.png"
    body, boundary = _multipart(
        {"overwrite": "true", "type": "input", "subfolder": ""},
        fname, side_bytes)
    req = urllib.request.Request(
        f"{COMFY}/upload/image", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        uploaded = json.loads(resp.read())["name"]

    # patch the graph: input image + per-ship save prefixes
    load_nodes = [k for k, n in wf.items() if n["class_type"] == "LoadImage"]
    assert len(load_nodes) == 1, f"expected one LoadImage, got {load_nodes}"
    wf[load_nodes[0]]["inputs"]["image"] = uploaded
    save_nodes = {}  # dir id -> node key
    for k, n in wf.items():
        if n["class_type"] == "SaveImage":
            dir_id = n["inputs"]["filename_prefix"].rpartition("/")[2]
            n["inputs"]["filename_prefix"] = f"sailage/{ship}/{dir_id}"
            save_nodes[dir_id] = k
    assert set(save_nodes) == {"n", "s", "nw", "sw"}, sorted(save_nodes)

    body = json.dumps({"prompt": wf, "client_id": CLIENT_ID}).encode("utf-8")
    req = urllib.request.Request(
        f"{COMFY}/prompt", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        prompt_id = json.loads(resp.read())["prompt_id"]

    t0 = time.time()
    outputs = None
    for _ in range(POLL_MAX // POLL_S):
        time.sleep(POLL_S)
        with urllib.request.urlopen(f"{COMFY}/history/{prompt_id}",
                                    timeout=30) as resp:
            hist = json.loads(resp.read())
        if prompt_id in hist:
            entry = hist[prompt_id]
            outputs = entry.get("outputs", {})
            if all(node in outputs for node in save_nodes.values()):
                break
            if entry.get("status", {}).get("completed"):
                raise RuntimeError(f"{ship}: prompt completed but outputs "
                                   f"missing: {sorted(outputs)}")
    else:
        raise RuntimeError(f"{ship}: timed out after {POLL_MAX}s")

    rec = {"input": f"sideviews/{ship}_side.png", "uploaded": uploaded,
           "prompt_id": prompt_id, "dirs": {}, "seconds": None}
    for dir_id, node in save_nodes.items():
        im = outputs[node]["images"][0]
        url = (f"{COMFY}/view?filename={urllib.request.quote(im['filename'])}"
               f"&subfolder={urllib.request.quote(im['subfolder'])}"
               f"&type={urllib.request.quote(im['type'])}")
        with urllib.request.urlopen(url, timeout=120) as resp:
            png = resp.read()
        if png[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError(f"{ship}/{dir_id}: /view returned a non-PNG")
        dest = os.path.join(OUT_DIR, ship, f"{dir_id}.png")
        _atomic(dest, png)
        rec["dirs"][dir_id] = {"file": f"angles/{ship}/{dir_id}.png",
                               "bytes": len(png)}
    rec["seconds"] = round(time.time() - t0, 1)
    return rec


def run(ships: list[str]) -> None:
    with open(WORKFLOW, encoding="utf-8") as fh:
        wf_template = json.load(fh)
    manifest: dict = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    for i, ship in enumerate(ships, 1):
        src = os.path.join(SIDEVIEWS, f"{ship}_side.png")
        if not os.path.isfile(src):
            raise SystemExit(f"missing side view: {src} — run sideview_pass first")
        print(f"[angle {i}/{len(ships)}] {ship}", flush=True)
        wf = json.loads(json.dumps(wf_template))  # deep copy per ship
        rec = run_ship(ship, wf)
        manifest[ship] = rec
        _atomic(MANIFEST, json.dumps(manifest, indent=1,
                                     ensure_ascii=False).encode("utf-8"))
        sizes = {d: r["bytes"] for d, r in rec["dirs"].items()}
        print(f"    {rec['seconds']}s prompt_id={rec['prompt_id']} {sizes}",
              flush=True)
    print(f"[angle] manifest -> {MANIFEST}", flush=True)


def snap_ship(ship: str) -> None:
    """Trial tokenize (stage 2.5, nothing canonical): per angle output ->
    chain.rembbg (ComfyUI) -> key_green -> chain.snap (512 majority vote
    -> 64 logical grid -> hull-block quantize + pennant-source snap) ->
    model_raw/angles/<ship>/snapped/<dir>.png (64x64). The side view is
    snapped too as the trial w and gets the tier long-axis band gate
    (G13_TIER_BANDS); n/s/nw/sw get fit + masthead-pennant metrics only
    (the band is an e/w-only gate, 80-* §4.8.7)."""
    chain.init(REPO)
    block = sorted(chain.validate_data.BLOCK_HULL)
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        tiers = {s["id"]: s.get("tier") for s in
                 json.load(fh)["ship_types"]}
    band = chain.validate_data.G13_TIER_BANDS[tiers[ship]]
    jobs = [(d, os.path.join(OUT_DIR, ship, f"{d}.png"), False)
            for d in ("n", "s", "nw", "sw")]
    jobs.append(("w", os.path.join(SIDEVIEWS, f"{ship}_side.png"), True))
    for dir_id, src, is_w in jobs:
        with open(src, "rb") as fh:
            raw = fh.read()
        debg = chain.key_green_bytes(chain.rembg(raw, f"{ship}_{dir_id}"))
        grid, m = chain.snap(debg, block,
                             band=band if is_w else None, pennant_snap=True)
        dest = os.path.join(OUT_DIR, ship, "snapped", f"{dir_id}.png")
        _atomic(dest, chain.encode_png(64, 64, grid))
        line = (f"{dir_id}: opaque={m['opaque_pct']}% bbox={m['bbox']} "
                f"fit={m['fit_inside_64']} pennant={m['pennant_present']} "
                f"(red px {m['pennant_red_px']})")
        if "band" in m:
            line += (f" band={m['band']['long_axis_px']}px in_band="
                     f"{m['band']['in_band']}")
        print(line, flush=True)


def status() -> None:
    if not os.path.exists(MANIFEST):
        print("no manifest yet")
        return
    with open(MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for ship, rec in m.items():
        print(f"{ship:18s} {rec['seconds']:>6}s dirs="
              f"{sorted(rec['dirs'])} prompt_id={rec['prompt_id']}")
    print(f"{len(m)} ships")


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "run":
        run(sys.argv[2:] or _ships())
    elif cmd == "snap":
        for ship in (sys.argv[2:] or _ships()):
            print(f"[snap {ship}]", flush=True)
            snap_ship(ship)
    elif cmd == "status":
        status()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
