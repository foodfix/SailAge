#!/usr/bin/env python3
"""PixelLab waterline VFX generation pass — build-time SaaS backend.

One `POST /v2/vfx` call per direction (8 total): an animated waterline
effect (hull-side foam + bow splash + stern wake) made AROUND the shared
galleass hull token (the largest silhouette, 80-* §4.8 2026-11-07), with
`game_pack` giving the behind/in-front layered sheets the runtime
sandwich draws. Raw output lands gitignored under
`tools/ui_art/model_raw/pixellab_vfx/<dir>/` (spritesheet + frame JSON +
game-pack zip + response.json carrying `effect_id`/`conversation` for
discounted change-calls); raw model output is never committed (90-*
§9.2). The key is read from PIXELLAB_API_KEY or the gitignored
tools/pixellab_config.json — never stored in files.

Usage:
  python3 tools/pixellab_vfx_pass.py run [dir ...]  # default: all 8
  python3 tools/pixellab_vfx_pass.py status         # manifest summary
  python3 tools/pixellab_vfx_pass.py fetch <dir> …  # re-download, no
                                                    #  re-generation
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import time
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
API = "https://api.pixellab.ai/v2"
OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw", "pixellab_vfx")
MANIFEST = os.path.join(OUT_DIR, "pixellab_vfx.json")
SPRITE_FMT = "assets/ui/tokens/hull_galleass_{}.png"  # the reference hull
POLL_S, POLL_MAX = 5, 600

# heading8 dir ids (60-* §4.3a) ↔ the hull token files. The 8 dirs of the
# waterline family; the VFX call runs once per dir.
DIRS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")

# Pinned verbatim (80-* §4.8 2026-11-07 amendment; user-approved wording).
# The foam tone is the palette FOAM value #dff0f4; the behind/in-front
# split instruction is what makes game_pack deliver the sandwich layers.
DESCRIPTION = (
    "Ocean waterline effect around this top-down pixel-art sailing ship "
    "sprite, 8-frame looping animation: white foam breaking along both "
    "sides of the wooden hull, a small splash at the bow, and a short "
    "white wake ribbon trailing from the stern. Behind the ship: the "
    "wake ribbon and faint outward water ripples. In front of the ship: "
    "the foam band washing over the lower hull edges, so the ship looks "
    "half-submerged in the sea. Water and foam only — never cover the "
    "sails, deck, masts, rigging, or the red pennant. Style: crisp "
    "16-bit pixel art, flat color, matching the ship sprite; foam reads "
    "as light cyan-white #dff0f4 over open sea, transparent background "
    "everywhere water is not drawn. Effect may extend a few pixels "
    "beyond the 64x64 sprite for the wake and ripples. Calm seas: "
    "gentle, slow, subtle.")


def _key() -> str:
    """API key: env PIXELLAB_API_KEY wins; else the gitignored config
    tools/pixellab_config.json ({"api_key": "..."})."""
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


def _download(url: str) -> bytes:
    # The result file links are presigned and need no auth.
    with urllib.request.urlopen(url, timeout=120) as resp:
        return resp.read()


def _manifest_path(out_root: str) -> str:
    return os.path.join(out_root, "pixellab_vfx.json")


def _load_manifest(out_root: str) -> dict:
    p = _manifest_path(out_root)
    if os.path.exists(p):
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    return {}


def _save_manifest(m: dict, out_root: str) -> None:
    os.makedirs(out_root, exist_ok=True)
    with open(_manifest_path(out_root), "w", encoding="utf-8") as fh:
        json.dump(m, fh, indent=1, sort_keys=True)
        fh.write("\n")


def _sprite_path(dir_id: str) -> str:
    p = os.path.join(REPO, SPRITE_FMT.format(dir_id))
    if not os.path.exists(p):
        raise SystemExit(f"reference sprite missing: {p}")
    return p


def _anchor_in_sprite(dir_id: str, pack_zip: str) -> dict:
    """The effect's anchor ("feet") expressed INSIDE the 64x64 token box:
    locate the composited sprite in the whole-with-sprite sheet by exact
    opaque-pixel template match. The sprite may stick out of the clip
    frame (the trim is the EFFECT's extent), so the search runs on a
    sprite-size-padded canvas and allows negative offsets; the result is
    clamped to the 64 box with a flagged fallback when impossible (the
    trial landed at ~26% and visually correct; sub-15% or out-of-box
    flags the direction for manual review). Returns
    {"x", "y", "match_rate", "method"} for the manifest."""
    import io  # noqa: PLC0415
    import zipfile  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415

    sprite = Image.open(_sprite_path(dir_id)).convert("RGBA")
    sw, sh = sprite.size
    with zipfile.ZipFile(pack_zip) as zf:
        manifest = json.loads(zf.read("manifest.json"))
        clip = next(c for c in manifest["clips"]
                    if c["name"] == "whole-with-sprite")
        fw, fh = clip["frame"]["w"], clip["frame"]["h"]
        sheet = Image.open(zf.open(clip["sheets"][0]["file"])).convert(
            "RGBA")
    frame0 = sheet.crop((0, 0, fw, fh))
    # padded canvas: the sprite may hang off any frame edge
    pad = Image.new("RGBA", (fw + 2 * sw, fh + 2 * sh))
    pad.paste(frame0, (sw, sh))
    sp_px, pd_px = sprite.load(), pad.load()
    sp_opaque = [(x, y, sp_px[x, y])
                 for y in range(sh) for x in range(sw) if sp_px[x, y][3] > 0]
    best_hit, best_xy = 0, (0, 0)
    for oy in range(-sh + 1, fh + sh):
        for ox in range(-sw + 1, fw + sw):
            hit = 0
            for (x, y, c) in sp_opaque:
                px, py = ox + x + sw, oy + y + sh
                if 0 <= px < pad.width and 0 <= py < pad.height \
                        and pd_px[px, py] == c:
                    hit += 1
            if hit > best_hit:
                best_hit, best_xy = hit, (ox, oy)
    # sprite top-left in CANVAS coords = (anchor + clip_offset) + S, and
    # the feet point IS the anchor, so feet_in_sprite = -(clip_offset + S)
    # — the canvas anchor cancels (the pack README: frame at anchor+offset).
    off = clip["offset"]
    ax = -(off["x"] + best_xy[0])
    ay = -(off["y"] + best_xy[1])
    rate = best_hit / max(len(sp_opaque), 1)
    if not (0 <= ax <= 64 and 0 <= ay <= 64) or rate < 0.15:
        # flagged fallback: feet = token bbox bottom-center
        bx = sprite.getbbox()
        return {"x": (bx[0] + bx[2]) // 2, "y": bx[3],
                "match_rate": round(rate, 3),
                "frame_bbox": {"x": best_xy[0], "y": best_xy[1],
                               "w": fw, "h": fh},
                "method": "bbox-fallback"}
    return {"x": ax, "y": ay, "match_rate": round(rate, 3),
            "frame_bbox": {"x": best_xy[0], "y": best_xy[1],
                           "w": fw, "h": fh},
            "method": "template-match"}


def run_dir(dir_id: str, artist: str = "lite", name: str | None = None,
            desc_path: str | None = None,
            out_root: str = OUT_DIR, expect_quote: int | None = None) -> dict:
    """One POST /v2/vfx + poll + raw download for one direction.
    artist/name/description/out_root are the variant knobs (the 2026-11-07
    v2 lite/pro A/B): name defaults to waterline-<dir>, the description to
    the pinned v1 constant, out_root to the v1 raw dir."""
    description = DESCRIPTION
    if desc_path:
        with open(desc_path, encoding="utf-8") as fh:
            description = fh.read()
        print(f"[vfx {dir_id}] description: {len(description)} chars "
              f"sha256={hashlib.sha256(description.encode('utf-8'))
                    .hexdigest()[:16]}…", flush=True)
    payload_name = name or f"waterline-{dir_id}"
    with open(_sprite_path(dir_id), "rb") as fh:
        sprite_b64 = base64.b64encode(fh.read()).decode("ascii")
    payload = {
        "description": description,
        "sprite": {"base64": sprite_b64, "format": "png"},
        "artist": artist,
        "name": payload_name,
        "game_pack": True,
    }
    print(f"[vfx {dir_id}/{artist}] POST /v2/vfx ...", flush=True)
    created = _post("/vfx", payload)
    job_id = created["background_job_id"]
    print(f"    job={job_id} quote={created.get('quoted_generations')}",
          flush=True)
    if expect_quote is not None \
            and created.get("quoted_generations") != expect_quote:
        manifest = _load_manifest(out_root)
        manifest[dir_id] = {"background_job_id": job_id,
                            "artist": artist, "name": payload_name,
                            "quoted_generations":
                                created.get("quoted_generations"),
                            "status": "quote-guard-tripped"}
        _save_manifest(manifest, out_root)
        raise SystemExit(
            f"quote guard: expected {expect_quote}, server quoted "
            f"{created.get('quoted_generations')} — job {job_id} was "
            "submitted and will deliver on its own; fetch it later with "
            "the fetch command, and STOP before any further calls")
    manifest = _load_manifest(out_root)
    manifest[dir_id] = {
        "background_job_id": job_id,
        "artist": artist,
        "name": payload_name,
        "quoted_generations": created.get("quoted_generations"),
        "description_sha256": hashlib.sha256(
            description.encode("utf-8")).hexdigest(),
        "sprite_sha256": hashlib.sha256(
            open(_sprite_path(dir_id), "rb").read()).hexdigest(),
        "status": "submitted",
    }
    _save_manifest(manifest, out_root)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        manifest[dir_id]["status"] = str(job.get("status", "timeout"))
        _save_manifest(manifest, out_root)
        raise RuntimeError(
            f"{dir_id}: job {job_id} status={job.get('status')!r} "
            f"(last: {json.dumps(job)[:300]})")

    result = job.get("last_response") or {}
    dest = os.path.join(out_root, dir_id)
    os.makedirs(dest, exist_ok=True)
    saved = {}
    for fname, url in (result.get("files") or {}).items():
        data = _download(url)
        path = os.path.join(dest, fname)
        with open(path, "wb") as fh:
            fh.write(data)
        saved[fname] = len(data)
        print(f"    saved {fname} ({len(data)} B)", flush=True)
    with open(os.path.join(dest, "response.json"), "w",
              encoding="utf-8") as fh:
        json.dump(result, fh, indent=1, sort_keys=True)
    manifest[dir_id].update({
        "effect_id": result.get("effect_id"),
        "status": "completed",
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()),
        "canvas": result.get("canvas"),
        "frames": result.get("frames"),
        "fps": result.get("fps"),
        "loop": result.get("loop"),
        "anchor": result.get("anchor"),
    })
    # The runtime placement anchor: the effect's feet point inside the
    # 64x64 token box (anchor_sprite), computed from the pack's
    # whole-with-sprite composition. Recomputed on every generation.
    pack_zip = os.path.join(dest, f"{payload_name}-game.zip")
    if os.path.exists(pack_zip):
        manifest[dir_id]["anchor_sprite"] = _anchor_in_sprite(dir_id,
                                                              pack_zip)
    _save_manifest(manifest, out_root)
    print(f"[vfx {dir_id}/{artist}] done: effect_id="
          f"{result.get('effect_id')} canvas={result.get('canvas')} "
          f"frames={result.get('frames')} fps={result.get('fps')}",
          flush=True)
    return manifest[dir_id]


def fetch_dir(dir_id: str, out_root: str = OUT_DIR) -> None:
    """Re-download the completed result from its stored links — never a
    new generation (the presigned links expire; on 403 re-run nothing:
    the effect lives in My effects under its effect_id)."""
    resp_path = os.path.join(out_root, dir_id, "response.json")
    if not os.path.exists(resp_path):
        raise SystemExit(f"no response.json for {dir_id} — run it first")
    with open(resp_path, encoding="utf-8") as fh:
        result = json.load(fh)
    dest = os.path.join(out_root, dir_id)
    os.makedirs(dest, exist_ok=True)
    for name, url in (result.get("files") or {}).items():
        data = _download(url)
        with open(os.path.join(dest, name), "wb") as fh:
            fh.write(data)
        print(f"[vfx {dir_id}] re-fetched {name} ({len(data)} B)",
              flush=True)


def main() -> None:
    import argparse  # noqa: PLC0415
    ap = argparse.ArgumentParser(
        description="PixelLab waterline VFX pass (80-* §4.8 2026-11-07)")
    ap.add_argument("cmd", choices=("run", "status", "fetch"))
    ap.add_argument("dirs", nargs="*", help=f"dir ids, subset of {DIRS}")
    ap.add_argument("--artist", choices=("lite", "pro"), default="lite",
                    help="VFX artist tier (default lite)")
    ap.add_argument("--name", help="effect name (default waterline-<dir>)")
    ap.add_argument("--desc-file",
                    help="read the description from this file instead of "
                         "the pinned v1 constant")
    ap.add_argument("--raw", default=OUT_DIR,
                    help=f"raw output root (default {OUT_DIR})")
    ap.add_argument("--expect-quote", type=int,
                    help="abort BEFORE spending if the POST's quote "
                         "differs (the guard: the quote is in the 202 "
                         "response, checked immediately)")
    args = ap.parse_args()
    if args.cmd == "status":
        m = _load_manifest(args.raw)
        for d in DIRS:
            rec = m.get(d)
            if rec is None:
                print(f"{d:3s} —")
            else:
                print(f"{d:3s} {rec.get('status', '?'):10s} "
                      f"artist={rec.get('artist')} "
                      f"effect={rec.get('effect_id')} "
                      f"quote={rec.get('quoted_generations')} "
                      f"canvas={rec.get('canvas')} frames="
                      f"{rec.get('frames')} fps={rec.get('fps')}")
        return
    dirs = [d for d in args.dirs if d in DIRS]
    unknown = [d for d in args.dirs if d not in DIRS]
    if unknown:
        raise SystemExit(f"unknown dir ids: {unknown} (valid: {DIRS})")
    if not dirs:
        dirs = list(DIRS)
    failed = []
    for d in dirs:
        try:
            if args.cmd == "run":
                rec = run_dir(d, artist=args.artist, name=args.name,
                              desc_path=args.desc_file, out_root=args.raw,
                              expect_quote=args.expect_quote)
            else:
                fetch_dir(d, out_root=args.raw)
        except Exception as exc:  # noqa: BLE001 — keep the batch going
            print(f"[vfx {d}] FAILED: {exc}", flush=True)
            failed.append(d)
    if failed:
        raise SystemExit(f"failed dirs: {failed}")


if __name__ == "__main__":
    main()
