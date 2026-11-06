#!/usr/bin/env python3
"""PixelLab hull-token generation pass — build-time SaaS backend.

One `create-object-pro-flash` call per ship: native 64×64 pixel-art render
(view "low top-down" = the §4.8 oblique elevated convention) + 8 rotations.
Raw PNGs land gitignored under model_raw/pixellab/<ship>/ plus a manifest;
raw model output is never committed (90-* §9.2). The key is read from the
PIXELLAB_API_KEY environment variable only — never stored in files.

Usage:
  python3 tools/pixellab_pass.py run [ship ...]   # default: all 16
  python3 tools/pixellab_pass.py status
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
API = "https://api.pixellab.ai/v2"
OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw", "pixellab")
MANIFEST = os.path.join(OUT_DIR, "pixellab.json")
DIRS = ("north", "north-east", "north-west", "south", "south-east",
        "south-west", "east", "west")
POLL_S, POLL_MAX = 5, 600

# Per-ship visual descriptors (identity payload). Derived from the
# deterministic manifest rig strings (hulls.json) + §4.8 craft vocabulary.
# Pinned per the concrete-numbers rule; amendment = edit here + docs.
_SUFFIX = (" wooden sailing ship, dense multi-strake hull planking, "
           "billowed sails with folded shading, thin rigging ropes, "
           "small red pennant at the mainmast top, visible deck planking "
           "with stern cabin, bowsprit at the bow, game sprite, "
           "transparent background.")
# Trial 2 (2026-11-06, user direction): full §4.8.6 craft vocabulary —
# candidate for the pinned descriptor set, pending sheet-59 verdict.
_DESCRIPTORS: dict[str, str] = {
    "brigantine":
        "Brigantine sailing ship, two masts with square sails, long low "
        "hull of warm brown wood, multi-strake planking bands in several "
        "wood tones, dark gunwale, gold trim line along the sheer, "
        "gunport row with tiny dark ports, stern cabin with small lit "
        "windows, square sails billowed with three folded shading bands "
        "and one bright highlight arc each, thin dark rigging ropes to "
        "bowsprit and hull, small red pennant at the mainmast top, deck "
        "planking and deck structures visible from above, dark 1-pixel "
        "silhouette outline, rich 16-bit game pixel art, transparent "
        "background.",
}
# Optional view override for view trials (default: high top-down — the
# trial-4 winner, user direction 2026-11-06). No style image, ever.
VIEW = os.environ.get("PIXELLAB_VIEW", "high top-down")
# Shared craft+style suffix (pinned verbatim, 80-* §4.8 2026-11-06): one
# wording for all 16 ships = the style-consistency anchor. Identity comes
# from the per-ship prefix (name + rig); NO style_image is ever sent.
_STYLE_SUFFIX = (
    ", wooden sailing ship with dense multi-strake planking bands in "
    "several wood tones, dark gunwale, gold trim line along the sheer, "
    "gunport row with tiny dark ports, stern cabin with small lit "
    "windows, sails billowed with three folded shading bands and one "
    "bright highlight arc each, thin dark rigging ropes to bowsprit and "
    "hull, small red pennant at the mainmast top, deck planking and "
    "deck structures visible from above, retro 16-bit sailing ship "
    "sprite in the style of classic 1990s naval adventure games like "
    "Uncharted Waters 2 / New Horizons, dark 1-pixel silhouette "
    "outline, transparent background.")


def _desc(ship: str) -> str:
    if ship in _DESCRIPTORS:
        return _DESCRIPTORS[ship]
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        types = {s["id"]: s for s in json.load(fh)["ship_types"]}
    with open(os.path.join(REPO, "tools", "ui_art", "hulls", "rig.json"),
              encoding="utf-8") as fh:
        rigs = json.load(fh)["hulls"]
    if isinstance(rigs, list):
        h = next((e for e in rigs if e.get("id") == ship), {})
    else:
        h = rigs.get(ship, {})
    rig = h.get("rig", "sailing rig")
    name = types.get(ship, {}).get("name", {}).get("en", ship)
    return f"{name} sailing ship, {rig}{_STYLE_SUFFIX}"


def _ships() -> list[str]:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        return [s["id"] for s in json.load(fh)["ship_types"]]


def _key() -> str:
    """API key: env PIXELLAB_API_KEY wins; else the gitignored config
    tools/pixellab_config.json ({"api_key": "..."}), so any agent or
    process in this repo picks the key up without env setup."""
    k = os.environ.get("PIXELLAB_API_KEY")
    if k:
        return k
    cfg = os.path.join(REPO, "tools", "pixellab_config.json")
    if os.path.exists(cfg):
        with open(cfg, encoding="utf-8") as fh:
            k = json.load(fh).get("api_key")
        if k:
            return k
    raise SystemExit("PIXELLAB_API_KEY not set and no "
                     "tools/pixellab_config.json")


def _post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}", data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {_key()}",
                 "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def _get(path: str, binary: bool = False):
    req = urllib.request.Request(
        f"{API}{path}", headers={"Authorization": f"Bearer {_key()}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
    return raw if binary else json.loads(raw)


def _save_spritesheet(object_id: str, dest_dir: str) -> dict:
    """Cut the 8 rotations out of the object spritesheet ZIP (the
    rotation_urls presigned links 403 after expiry)."""
    import io  # noqa: PLC0415
    import zipfile  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415
    raw = _get(f"/objects/{object_id}/spritesheet", binary=True)
    zf = zipfile.ZipFile(io.BytesIO(raw))
    layout = json.loads(zf.read([n for n in zf.namelist()
                                 if n.endswith(".json")][0]))
    sheet_png = [n for n in zf.namelist() if n.endswith(".png")][0]
    sheet = Image.open(io.BytesIO(zf.read(sheet_png))).convert("RGBA")
    sp = layout["spritesheet"]
    cw, ch = sp["cell_size"]["width"], sp["cell_size"]["height"]
    order = []
    for row in sp["rows"]:
        order.extend(row["directions"])
    saved = {}
    for i, dir_name in enumerate(order):
        cx, cy = (i % sp["columns"]) * cw, (i // sp["columns"]) * ch
        cell = sheet.crop((cx, cy, cx + cw, cy + ch))
        buf = io.BytesIO()
        cell.save(buf, "PNG")
        png = buf.getvalue()
        with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
            fh.write(png)
        saved[dir_name] = len(png)
    return saved


def _save_rotations(urls: dict, dest_dir: str) -> dict:
    saved = {}
    for dir_name in DIRS:
        url = urls.get(dir_name)
        if not url:
            raise RuntimeError(f"no rotation url for {dir_name}: "
                               f"{sorted(urls)}")
        png = _download(url)
        with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
            fh.write(png)
        saved[dir_name] = len(png)
    return saved


def run_ship(ship: str, label: str | None = None) -> dict:
    payload = {
        "description": _desc(ship),
        "name": ship,
        "image_size": {"width": 64, "height": 64},
        "n_directions": 8,
        "view": VIEW,
        "seed": 91000,
    }
    print(f"[pixellab {ship}] POST create-object-pro-flash ...", flush=True)
    created = _post("/create-object-pro-flash", payload)
    job_id, object_id = created["background_job_id"], created["object_id"]
    usage = created.get("usage") or {}
    print(f"    job={job_id} object={object_id} "
          f"usage={json.dumps(usage)}", flush=True)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        raise RuntimeError(f"{ship}: job {job_id} status="
                           f"{job.get('status')!r} (last: {json.dumps(job)[:300]})")

    dest = label or ship
    dest_dir = os.path.join(OUT_DIR, dest)
    os.makedirs(dest_dir, exist_ok=True)
    obj = _get(f"/objects/{object_id}")
    try:
        saved = _save_rotations(obj["rotation_urls"], dest_dir)
    except (urllib.error.HTTPError, RuntimeError) as e:
        print(f"    rotation_urls failed ({e}); spritesheet fallback",
              flush=True)
        saved = _save_spritesheet(object_id, dest_dir)
    rec = {"object_id": object_id, "job_id": job_id,
           "description": payload["description"], "seed": payload["seed"],
           "view": payload["view"], "bytes": saved,
           "job_status": job.get("status"),
           "ship": ship, "label": dest,
           "object_response": obj}
    return rec


def _download(url: str) -> bytes:
    """Rotation URLs 403 without auth on some accounts — retry with the
    bearer header before giving up."""
    try:
        with urllib.request.urlopen(url, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        if e.code != 403:
            raise
    key = _key()
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def fetch_ship(ship: str, object_id: str | None = None) -> dict:
    """Re-download a completed object's 8 rotations (no new generation).
    Tries the stored rotation_urls (auth-retried), falls back to the
    spritesheet ZIP + layout JSON. Bootstraps the manifest entry from the
    object API when a previous run died before persisting it."""
    try:
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except FileNotFoundError:
        manifest = {}
    rec = manifest.get(ship) or {"object_id": object_id}
    object_id = rec["object_id"]
    if object_id is None:
        raise SystemExit(f"{ship}: no manifest entry and no object_id arg")
    obj = _get(f"/objects/{object_id}")
    rec.setdefault("object_id", object_id)
    rec.setdefault("description", obj.get("prompt"))
    rec.setdefault("view", obj.get("view"))
    rec["object_response"] = obj
    urls = obj.get("rotation_urls") or rec.get("rotation_urls") or {}
    dest_dir = os.path.join(OUT_DIR, ship)
    os.makedirs(dest_dir, exist_ok=True)
    saved = {}
    try:
        if not urls:
            raise RuntimeError("no rotation urls")
        for dir_name in DIRS:
            url = urls.get(dir_name)
            if not url:
                raise RuntimeError(f"{ship}: no rotation url for {dir_name}")
            png = _download(url)
            with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
                fh.write(png)
            saved[dir_name] = len(png)
    except (urllib.error.HTTPError, RuntimeError) as e:
        print(f"    rotation_urls failed ({e}); spritesheet fallback",
              flush=True)
        saved = {}
        raw = _get(f"/objects/{object_id}/spritesheet", binary=True)
        import io  # noqa: PLC0415
        import zipfile  # noqa: PLC0415
        zf = zipfile.ZipFile(io.BytesIO(raw))
        layout = json.loads(zf.read([n for n in zf.namelist()
                                     if n.endswith(".json")][0]))
        sheet_png = [n for n in zf.namelist() if n.endswith(".png")][0]
        from PIL import Image  # noqa: PLC0415
        sheet = Image.open(io.BytesIO(zf.read(sheet_png))).convert("RGBA")
        # layout: spritesheet.cell_size (w/h), columns, rows[].directions
        # (dir name per column, left to right) — cut each 64x64 cell.
        sp = layout["spritesheet"]
        cw, ch = sp["cell_size"]["width"], sp["cell_size"]["height"]
        order = []
        for row in sp["rows"]:
            order.extend(row["directions"])
        for i, dir_name in enumerate(order):
            cx, cy = (i % sp["columns"]) * cw, (i // sp["columns"]) * ch
            cell = sheet.crop((cx, cy, cx + cw, cy + ch))
            buf = io.BytesIO()
            cell.save(buf, "PNG")
            png = buf.getvalue()
            with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
                fh.write(png)
            saved[dir_name] = len(png)
        rec["spritesheet_fallback"] = True
    rec["bytes"] = saved
    manifest[ship] = rec
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)
    print(f"[pixellab fetch] {ship}: {len(saved)} dirs saved "
          f"(object {object_id})", flush=True)
    return rec


# ---- snap (option B, user direction 2026-11-06): pennant-only recolor.
# Everything else ships raw 1:1 — no resize, no band gate, no palette
# quantize (gates = pennant + fit). The masthead's dominant red cluster
# (incl. its shading variants, channel-sum Δ≤90, mirrors build_ui_art's
# _pennant_snap radius) lands exactly on PENNANT_SOURCE so the ×7 owner
# remap hits. Raw rotations are never modified.
PENNANT_SOURCE = "#b3191f"
MASTHEAD_TOP_FRAC = 0.45   # masthead region = top 45% of the bbox
MASTHEAD_MIN_PX = 3        # ≥3 source-red px in the masthead region
RED_MIN_R = 150            # flag reds are bright; dark maroon rooftops
RED_MAX_GB = 110           # fail this and stay untouched
DIR_MAP = {  # pixellab rotation name -> our heading8 dir id
    "north": "n", "north-east": "ne", "north-west": "nw",
    "south": "s", "south-east": "se", "south-west": "sw",
    "east": "e", "west": "w",
}


def _pennant_cluster(px, w, h, x0, y0, x1, y1):
    """Dominant red-dominant color + its px count in the masthead region."""
    from collections import Counter  # noqa: PLC0415
    cut = y0 + int(MASTHEAD_TOP_FRAC * (y1 - y0 + 1) + 0.5)
    cnt = Counter()
    for y in range(y0, min(cut, y1 + 1)):
        for x in range(x0, x1 + 1):
            r, g, b, a = px[x, y]
            if a > 0 and r >= RED_MIN_R and g <= RED_MAX_GB and b <= RED_MAX_GB \
                    and r > g and r > b:
                cnt[(r, g, b)] += 1
    return cnt.most_common(1)[0] if cnt else (None, 0)


def snap_ship(ship: str) -> None:
    """Pennant-only recolor of the on-disk RAW rotations (never modified)
    into <ship>/snapped/<dir_id>.png. Gates: pennant px ≥ 3, fit."""
    from PIL import Image  # noqa: PLC0415
    src_dir = os.path.join(OUT_DIR, ship)
    dst_dir = os.path.join(src_dir, "snapped")
    os.makedirs(dst_dir, exist_ok=True)
    sr = (int(PENNANT_SOURCE[1:3], 16), int(PENNANT_SOURCE[3:5], 16),
          int(PENNANT_SOURCE[5:7], 16))
    worst = 999
    for rot, dir_id in DIR_MAP.items():
        path = os.path.join(src_dir, f"{rot}.png")
        img = Image.open(path).convert("RGBA")
        px = img.load()
        w, h = img.size
        xs, ys = [], []
        for y in range(h):
            for x in range(w):
                if px[x, y][3] > 0:
                    xs.append(x)
                    ys.append(y)
        if not xs:
            print(f"  {ship}/{rot}: EMPTY — skipped", flush=True)
            continue
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        dom, _cnt = _pennant_cluster(px, w, h, x0, y0, x1, y1)
        n = 0
        if dom is not None:
            cut = y0 + int(MASTHEAD_TOP_FRAC * (y1 - y0 + 1) + 0.5)
            for y in range(y0, min(cut, y1 + 1)):
                for x in range(x0, x1 + 1):
                    r, g, b, a = px[x, y]
                    if a > 0 and r > g and r > b \
                            and abs(r - dom[0]) + abs(g - dom[1]) \
                            + abs(b - dom[2]) <= 90:
                        px[x, y] = (*sr, 255)
                        n += 1
        fit = x0 >= 0 and y0 >= 0 and x1 < w and y1 < h
        ok = n >= MASTHEAD_MIN_PX and fit
        worst = min(worst, n)
        img.save(os.path.join(dst_dir, f"{dir_id}.png"), "PNG")
        print(f"  {ship}/{rot} -> {dir_id}: pennant_px={n} "
              f"{'OK' if ok else 'FAIL'} fit={fit}", flush=True)
    return worst


def _pennant_fleet(ships: list[str]) -> None:
    for ship in ships:
        print(f"[snap {ship}]", flush=True)
        snap_ship(ship)


def run(ships: list[str]) -> None:
    manifest: dict = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    for i, entry in enumerate(ships, 1):
        ship, _, label = entry.partition("=")
        rec = run_ship(ship, label or None)
        manifest[label or ship] = rec
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(MANIFEST, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=1, ensure_ascii=False)
        print(f"[pixellab {i}/{len(ships)}] {entry} saved "
              f"{len(rec['bytes'])} dirs", flush=True)
    print(f"[pixellab] manifest -> {MANIFEST}", flush=True)


def status() -> None:
    if not os.path.exists(MANIFEST):
        print("no manifest yet")
        return
    with open(MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for ship, e in m.items():
        print(f"{ship:18s} dirs={len(e['bytes'])} seed={e['seed']} "
              f"object={e['object_id'][:12]}…")
    print(f"{len(m)} ships")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "run":
        run(sys.argv[2:] or _ships())
    elif cmd == "snap":
        _pennant_fleet(sys.argv[2:] or _ships())
    elif cmd == "fetch":
        fetch_ship(sys.argv[2],
                   sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        status()
