#!/usr/bin/env python3
"""PixelLab waterline VFX generation pass — build-time SaaS backend.

v6 mode (2026-11-08 per-ship wake revision, the shipping path): exactly
16 `POST /v2/vfx` calls — ONE per ship type — each built around that
ship's OWN north token (the wake hugs the hull silhouette it ships
with). Raw output lands gitignored under
`tools/ui_art/model_raw/pixellab_vfx/v6/<ship>/` (spritesheet + frame
JSON + game-pack zip + response.json carrying
`effect_id`/`conversation` for discounted change-calls); raw model
output is never committed (90-* §9.2). The key is read from
PIXELLAB_API_KEY or the gitignored tools/pixellab_config.json — never
stored in files.

Usage:
  python3 tools/pixellab_vfx_pass.py v6-run [ship ...]  # default: all 16
                                                        # ship types
  python3 tools/pixellab_vfx_pass.py v6-status
  python3 tools/pixellab_vfx_pass.py v6-fetch <ship> …  # re-download, no
                                                        #  re-generation
  python3 tools/pixellab_vfx_pass.py v5-run [size ...]  # the superseded
  python3 tools/pixellab_vfx_pass.py v5-status          # per-size family
  python3 tools/pixellab_vfx_pass.py v5-fetch <size> …
  python3 tools/pixellab_vfx_pass.py v4-run [size ...]  # the retired
  python3 tools/pixellab_vfx_pass.py v4-status          # two-layer family

Legacy per-dir mode (SUPERSEDED by the v4 top-down revision — kept only
for history/re-download of the v3 raws):
  python3 tools/pixellab_vfx_pass.py run [dir ...]  # default: all 8
  python3 tools/pixellab_vfx_pass.py status
  python3 tools/pixellab_vfx_pass.py fetch <dir> …
"""
from __future__ import annotations

import base64
import glob as _glob
import hashlib
import json
import os
import sys
import time
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
API = "https://api.pixellab.ai/v2"
OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw", "pixellab_vfx")
V4_OUT_DIR = os.path.join(OUT_DIR, "v4")
V5_OUT_DIR = os.path.join(OUT_DIR, "v5")
V6_OUT_DIR = os.path.join(OUT_DIR, "v6")
MANIFEST = os.path.join(OUT_DIR, "pixellab_vfx.json")
SPRITE_FMT = "assets/ui/tokens/hull_galleass_{}.png"  # the reference hull
POLL_S, POLL_MAX = 5, 600

# heading8 dir ids (60-* §4.3a) ↔ the hull token files. The 8 dirs of the
# waterline family; the VFX call runs once per dir.
DIRS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")

# v4 pins (80-* §4.8 top-down VFX revision, 2026-11-07): one north family
# per ship size; the representative hull per size drives the effect.
SIZES = (32, 48, 64)
SIZE_SPRITE = {32: "hull_latin", 48: "hull_caravel", 64: "hull_galleass"}

# v6 pins (80-* §4.8 per-ship wake revision, 2026-11-08): one north wake
# sheet PER SHIP TYPE — exactly 16 /v2/vfx calls — with the sprite being
# that ship's OWN north token, so the wake hugs the hull silhouette it
# ships with. The ids match `data/ship_types.json` (the group-13 audit
# cross-checks the ingest against the data file; this tuple is the call
# plan, not the schema).
SHIPS = ("latin", "sloop", "caravel", "galley", "brigantine", "nao",
         "carrack", "galleon", "galiot", "galleass", "fluyt", "junk",
         "dhow", "pinnace", "caravela_redonda", "xebec")


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

# v4 description of record: the v3 template verbatim with the two pinned
# substitutions — the overhead opening clause and {MOTION} fixed to the
# single north value (the runtime rotation turns the whole sandwich, so
# only the north family ever exists). Everything else stays as shipped.
V4_DESCRIPTION = (
    "Waterline VFX around this straight top-down (directly from above) "
    "16-bit pixel-art sailing ship sprite, 8-frame looping animation. "
    "The ship is sailing north (up on screen). In front of the sprite: "
    "translucent deep-blue sea water covers the lower half of the "
    "wooden hull — the ship visibly sits low in the sea — with a broken "
    "white foam ridge running along the ship's waterline ON the hull "
    "planks, plus white spray arcing forward from the bow. Behind the "
    "sprite: a foam wake fanning out behind the stern, tapering into "
    "dots, small foam scallops hugging both hull sides. STRICTLY "
    "FORBIDDEN: circular or elliptical ripple rings or any closed loops "
    "around the ship; water touches only the hull sides, bow and stern. "
    "Foam #dff0f4 over dark sea blues; never cover sails, deck, masts "
    "or the red pennant; transparent background. Style: crisp 16-bit "
    "pixel art, flat color, matching the ship sprite. Calm seas: "
    "gentle, slow, subtle.")

# v5 description of record (80-* §4.8 single-layer revision, 2026-11-07,
# pinned verbatim — the natural-language revision: the foam is described,
# not hexed; nothing is asked to go IN FRONT of the sprite, so the
# effect is wake-only and the pack's behind sheet carries all of it).
V5_DESCRIPTION = (
    "Waterline VFX for this straight top-down (directly from above) "
    "16-bit pixel-art sailing ship sprite, 8-frame looping animation. "
    "The ship is sailing north (up on screen). The effect is drawn "
    "ONLY of open sea, never over any part of the ship: a foam wake "
    "fanning out behind the stern and tapering into dots, small foam "
    "scallops hugging both hull sides, a thin foam line at the bow, "
    "and gentle ripples spreading around the hull. The effect layer "
    "renders under the sprite in the game — the hull silhouette area "
    "stays completely clean: no foam, water or spray touching the "
    "decks, sails, masts, rigging or the red pennant. STRICTLY "
    "FORBIDDEN: circular or elliptical ripple rings or any closed "
    "loops around the ship. Pale bluish-white foam over deep blue sea "
    "water. Transparent background everywhere the effect is not "
    "drawn. Style: crisp 16-bit pixel art, flat color, matching the "
    "ship sprite. Calm seas: gentle, slow, subtle. The 8 frames loop "
    "seamlessly.")


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


def _anchor_in_sprite(sprite_path: str, pack_zip: str, box: int = 64) -> dict:
    """The effect's anchor ("feet") expressed INSIDE the sprite's token
    box (box = the token canvas size, 32/48/64): locate the composited
    sprite in the whole-with-sprite sheet by exact opaque-pixel template
    match. The sprite may stick out of the clip frame (the trim is the
    EFFECT's extent), so the search runs on a sprite-size-padded canvas
    and allows negative offsets; the result is clamped to the box with a
    flagged fallback when impossible (the trial landed at ~26% and
    visually correct; sub-15% or out-of-box flags the direction for
    manual review). Returns {"x", "y", "match_rate", "method"} for the
    manifest."""
    import io  # noqa: PLC0415
    import zipfile  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415

    sprite = Image.open(sprite_path).convert("RGBA")
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
    if not (0 <= ax <= box and 0 <= ay <= box) or rate < 0.15:
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
    # sprite's token box (anchor_sprite), computed from the pack's
    # whole-with-sprite composition. Recomputed on every generation.
    pack_zip = os.path.join(dest, f"{payload_name}-game.zip")
    if os.path.exists(pack_zip):
        manifest[dir_id]["anchor_sprite"] = _anchor_in_sprite(
            _sprite_path(dir_id), pack_zip)
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


def _v4_sprite_path(size: int) -> str:
    """The representative NORTH token per size (pinned at SIZE_SPRITE),
    read from the shipped tokens dir — run this only AFTER the hull
    ingest."""
    if size not in SIZE_SPRITE:
        raise SystemExit(f"unknown size {size} (valid: {SIZES})")
    p = os.path.join(REPO, "assets", "ui", "tokens",
                     f"{SIZE_SPRITE[size]}.png")
    if not os.path.exists(p):
        raise SystemExit(f"representative north token missing: {p} — "
                         f"generate + ingest the hulls first")
    return p


def run_size(size: int, artist: str = "pro", name: str | None = None,
             desc_path: str | None = None, out_root: str = V4_OUT_DIR,
             expect_quote: int | None = None,
             default_description: str = V4_DESCRIPTION,
             default_name_fmt: str = "waterline-v4-north-{size}-pro") -> dict:
    """One POST /v2/vfx + poll + raw download for one ship size (v4:
    north only — the runtime rotation turns the whole sandwich). The
    envelope stays the pinned four fields + game_pack. `default_description`
    / `default_name_fmt` are the v4/v5 knobs (v5 = the single-layer wake)."""
    description = default_description
    if desc_path:
        with open(desc_path, encoding="utf-8") as fh:
            description = fh.read()
        print(f"[v4 {size}] description: {len(description)} chars "
              f"sha256={hashlib.sha256(description.encode('utf-8'))
                    .hexdigest()[:16]}…", flush=True)
    sprite_path = _v4_sprite_path(size)
    payload_name = name or default_name_fmt.format(size=size)
    with open(sprite_path, "rb") as fh:
        sprite_b64 = base64.b64encode(fh.read()).decode("ascii")
    payload = {
        "description": description,
        "sprite": {"base64": sprite_b64, "format": "png"},
        "artist": artist,
        "name": payload_name,
        "game_pack": True,
    }
    print(f"[v4 {size}/{artist}] POST /v2/vfx "
          f"(sprite {SIZE_SPRITE[size]}) ...", flush=True)
    created = _post("/vfx", payload)
    job_id = created["background_job_id"]
    print(f"    job={job_id} quote={created.get('quoted_generations')}",
          flush=True)
    key = str(size)
    if expect_quote is not None \
            and created.get("quoted_generations") != expect_quote:
        manifest = _load_manifest(out_root)
        manifest[key] = {"background_job_id": job_id,
                         "artist": artist, "name": payload_name,
                         "size": size,
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
    manifest[key] = {
        "background_job_id": job_id,
        "artist": artist,
        "name": payload_name,
        "size": size,
        "sprite": SIZE_SPRITE[size],
        "quoted_generations": created.get("quoted_generations"),
        "description_sha256": hashlib.sha256(
            description.encode("utf-8")).hexdigest(),
        "sprite_sha256": hashlib.sha256(
            open(sprite_path, "rb").read()).hexdigest(),
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
        manifest[key]["status"] = str(job.get("status", "timeout"))
        _save_manifest(manifest, out_root)
        raise RuntimeError(
            f"size {size}: job {job_id} status={job.get('status')!r} "
            f"(last: {json.dumps(job)[:300]})")

    result = job.get("last_response") or {}
    dest = os.path.join(out_root, key)
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
    manifest[key].update({
        "effect_id": result.get("effect_id"),
        "status": "completed",
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()),
        "canvas": result.get("canvas"),
        "frames": result.get("frames"),
        "fps": result.get("fps"),
        "loop": result.get("loop"),
        "anchor": result.get("anchor"),
    })
    pack_zip = os.path.join(dest, f"{payload_name}-game.zip")
    if os.path.exists(pack_zip):
        manifest[key]["anchor_sprite"] = _anchor_in_sprite(
            sprite_path, pack_zip, box=size)
    _save_manifest(manifest, out_root)
    print(f"[v4 {size}/{artist}] done: effect_id="
          f"{result.get('effect_id')} canvas={result.get('canvas')} "
          f"frames={result.get('frames')} fps={result.get('fps')}",
          flush=True)
    return manifest[key]


def fetch_size(size: int, out_root: str = V4_OUT_DIR) -> None:
    """Re-download the completed result from its stored links — never a
    new generation."""
    key = str(size)
    resp_path = os.path.join(out_root, key, "response.json")
    if not os.path.exists(resp_path):
        raise SystemExit(f"no response.json for size {size} — run it first")
    with open(resp_path, encoding="utf-8") as fh:
        result = json.load(fh)
    dest = os.path.join(out_root, key)
    os.makedirs(dest, exist_ok=True)
    for name, url in (result.get("files") or {}).items():
        data = _download(url)
        with open(os.path.join(dest, name), "wb") as fh:
            fh.write(data)
        print(f"[v4 {size}] re-fetched {name} ({len(data)} B)",
              flush=True)


def _ship_sprite_path(ship: str) -> str:
    """The ship's OWN north token (the v6 pin): run this only AFTER the
    hull ingest."""
    if ship not in SHIPS:
        raise SystemExit(f"unknown ship {ship!r} (valid: {SHIPS})")
    p = os.path.join(REPO, "assets", "ui", "tokens", f"hull_{ship}.png")
    if not os.path.exists(p):
        raise SystemExit(f"north token missing: {p} — generate + ingest "
                         "the hulls first")
    return p


def _ship_box(ship: str) -> int:
    """The token canvas side (the anchor box) read straight from the
    token PNG's IHDR — 32/48/64 per the tier table, no PIL needed."""
    with open(_ship_sprite_path(ship), "rb") as fh:
        head = fh.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"not a PNG: {ship}")
    return int.from_bytes(head[16:20], "big")


def run_ship(ship: str, artist: str = "pro", name: str | None = None,
             desc_path: str | None = None, out_root: str = V6_OUT_DIR,
             expect_quote: int | None = None,
             default_description: str = V5_DESCRIPTION,
             default_name_fmt: str = "waterline-v6-north-{ship}-pro") -> dict:
    """One POST /v2/vfx + poll + raw download for one ship TYPE (v6: the
    sprite is that ship's own north token — the per-ship wake revision).
    The envelope stays the pinned four fields + game_pack; the
    description is the v5 template verbatim (unchanged this round)."""
    description = default_description
    if desc_path:
        with open(desc_path, encoding="utf-8") as fh:
            description = fh.read()
        print(f"[v6 {ship}] description: {len(description)} chars "
              f"sha256={hashlib.sha256(description.encode('utf-8'))
                    .hexdigest()[:16]}…", flush=True)
    sprite_path = _ship_sprite_path(ship)
    box = _ship_box(ship)
    payload_name = name or default_name_fmt.format(ship=ship)
    with open(sprite_path, "rb") as fh:
        sprite_b64 = base64.b64encode(fh.read()).decode("ascii")
    payload = {
        "description": description,
        "sprite": {"base64": sprite_b64, "format": "png"},
        "artist": artist,
        "name": payload_name,
        "game_pack": True,
    }
    print(f"[v6 {ship}/{artist}] POST /v2/vfx (token {box}px) ...",
          flush=True)
    created = _post("/vfx", payload)
    job_id = created["background_job_id"]
    print(f"    job={job_id} quote={created.get('quoted_generations')}",
          flush=True)
    if expect_quote is not None \
            and created.get("quoted_generations") != expect_quote:
        manifest = _load_manifest(out_root)
        manifest[ship] = {"background_job_id": job_id,
                          "artist": artist, "name": payload_name,
                          "ship": ship, "size": box,
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
    manifest[ship] = {
        "background_job_id": job_id,
        "artist": artist,
        "name": payload_name,
        "ship": ship,
        "size": box,
        "sprite": f"hull_{ship}",
        "quoted_generations": created.get("quoted_generations"),
        "description_sha256": hashlib.sha256(
            description.encode("utf-8")).hexdigest(),
        "sprite_sha256": hashlib.sha256(
            open(sprite_path, "rb").read()).hexdigest(),
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
        manifest[ship]["status"] = str(job.get("status", "timeout"))
        _save_manifest(manifest, out_root)
        raise RuntimeError(
            f"ship {ship}: job {job_id} status={job.get('status')!r} "
            f"(last: {json.dumps(job)[:300]})")

    result = job.get("last_response") or {}
    dest = os.path.join(out_root, ship)
    os.makedirs(dest, exist_ok=True)
    for fname, url in (result.get("files") or {}).items():
        data = _download(url)
        with open(os.path.join(dest, fname), "wb") as fh:
            fh.write(data)
        print(f"    saved {fname} ({len(data)} B)", flush=True)
    with open(os.path.join(dest, "response.json"), "w",
              encoding="utf-8") as fh:
        json.dump(result, fh, indent=1, sort_keys=True)
    manifest[ship].update({
        "effect_id": result.get("effect_id"),
        "status": "completed",
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()),
        "canvas": result.get("canvas"),
        "frames": result.get("frames"),
        "fps": result.get("fps"),
        "loop": result.get("loop"),
        "anchor": result.get("anchor"),
    })
    pack_zips = sorted(_glob.glob(os.path.join(dest, "*-game.zip")))
    if pack_zips:
        manifest[ship]["anchor_sprite"] = _anchor_in_sprite(
            sprite_path, pack_zips[0], box=box)
    _save_manifest(manifest, out_root)
    print(f"[v6 {ship}/{artist}] done: effect_id="
          f"{result.get('effect_id')} canvas={result.get('canvas')} "
          f"frames={result.get('frames')} fps={result.get('fps')}",
          flush=True)
    return manifest[ship]


def fetch_ship(ship: str, out_root: str = V6_OUT_DIR) -> None:
    """Re-download the completed result from its stored links — never a
    new generation."""
    if ship not in SHIPS:
        raise SystemExit(f"unknown ship {ship!r} (valid: {SHIPS})")
    resp_path = os.path.join(out_root, ship, "response.json")
    if not os.path.exists(resp_path):
        raise SystemExit(f"no response.json for {ship} — run it first")
    with open(resp_path, encoding="utf-8") as fh:
        result = json.load(fh)
    dest = os.path.join(out_root, ship)
    os.makedirs(dest, exist_ok=True)
    for name, url in (result.get("files") or {}).items():
        data = _download(url)
        with open(os.path.join(dest, name), "wb") as fh:
            fh.write(data)
        print(f"[v6 {ship}] re-fetched {name} ({len(data)} B)",
              flush=True)



def main() -> None:
    import argparse  # noqa: PLC0415
    ap = argparse.ArgumentParser(
        description="PixelLab waterline VFX pass (80-* §4.8 2026-11-07)")
    ap.add_argument("cmd",
                    choices=("run", "status", "fetch",
                             "v4-run", "v4-status", "v4-fetch",
                             "v5-run", "v5-status", "v5-fetch",
                             "v6-run", "v6-status", "v6-fetch"))
    ap.add_argument("targets", nargs="*",
                    help=f"dir ids, subset of {DIRS} (legacy) — or ship "
                         f"sizes, subset of {SIZES} (v4/v5) — or ship "
                         f"types, subset of {SHIPS} (v6)")
    ap.add_argument("--artist", choices=("lite", "pro"), default=None,
                    help="VFX artist tier (default: lite legacy, pro v4)")
    ap.add_argument("--name", help="effect name "
                                   "(default waterline-<dir> / "
                                   "waterline-v4-north-<size>-pro)")
    ap.add_argument("--desc-file",
                    help="read the description from this file instead of "
                         "the pinned constant (v1 or v4)")
    ap.add_argument("--raw", default=None,
                    help=f"raw output root (default: {OUT_DIR} legacy, "
                         f"{V4_OUT_DIR} v4, {V5_OUT_DIR} v5, "
                         f"{V6_OUT_DIR} v6)")
    ap.add_argument("--expect-quote", type=int,
                    help="abort BEFORE spending if the POST's quote "
                         "differs (the guard: the quote is in the 202 "
                         "response, checked immediately)")
    args = ap.parse_args()
    v4 = args.cmd.startswith("v4")
    v5 = args.cmd.startswith("v5")
    v6 = args.cmd.startswith("v6")
    raw = args.raw or (V6_OUT_DIR if v6 else V5_OUT_DIR if v5 else
                       V4_OUT_DIR if v4 else OUT_DIR)
    artist = args.artist or ("pro" if (v4 or v5 or v6) else "lite")
    if args.cmd == "status":
        m = _load_manifest(raw)
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
    if args.cmd in ("v4-status", "v5-status"):
        m = _load_manifest(raw)
        for s in SIZES:
            rec = m.get(str(s))
            if rec is None:
                print(f"{s:3d} —")
            else:
                print(f"{s:3d} {rec.get('status', '?'):10s} "
                      f"artist={rec.get('artist')} "
                      f"sprite={rec.get('sprite')} "
                      f"effect={rec.get('effect_id')} "
                      f"quote={rec.get('quoted_generations')} "
                      f"canvas={rec.get('canvas')} frames="
                      f"{rec.get('frames')} fps={rec.get('fps')} "
                      f"anchor={rec.get('anchor_sprite')}")
        return
    if args.cmd == "v6-status":
        m = _load_manifest(raw)
        for ship in SHIPS:
            rec = m.get(ship)
            if rec is None:
                print(f"{ship:18s} —")
            else:
                print(f"{ship:18s} {rec.get('status', '?'):10s} "
                      f"artist={rec.get('artist')} "
                      f"sprite={rec.get('sprite')} "
                      f"effect={rec.get('effect_id')} "
                      f"quote={rec.get('quoted_generations')} "
                      f"canvas={rec.get('canvas')} frames="
                      f"{rec.get('frames')} fps={rec.get('fps')} "
                      f"anchor={rec.get('anchor_sprite')}")
        return
    if args.cmd.startswith("v4") or args.cmd.startswith("v5"):
        want = []
        for t in args.targets:
            if t not in [str(s) for s in SIZES]:
                raise SystemExit(f"unknown size {t!r} (valid: {SIZES})")
            want.append(int(t))
        if not want:
            want = list(SIZES)
        failed = []
        for s in want:
            try:
                if args.cmd == "v4-run":
                    run_size(s, artist=artist,
                             name=args.name, desc_path=args.desc_file,
                             out_root=raw, expect_quote=args.expect_quote)
                elif args.cmd == "v5-run":
                    run_size(s, artist=artist, name=args.name,
                             desc_path=args.desc_file, out_root=raw,
                             expect_quote=args.expect_quote,
                             default_description=V5_DESCRIPTION,
                             default_name_fmt="waterline-v5-north-{size}-pro")
                else:
                    fetch_size(s, out_root=raw)
            except Exception as exc:  # noqa: BLE001 — keep the batch going
                print(f"[vfx {s}] FAILED: {exc}", flush=True)
                failed.append(s)
        if failed:
            raise SystemExit(f"failed sizes: {failed}")
        return
    if args.cmd.startswith("v6"):
        want = [t for t in args.targets if t in SHIPS]
        unknown = [t for t in args.targets if t not in SHIPS]
        if unknown:
            raise SystemExit(f"unknown ship ids: {unknown} (valid: {SHIPS})")
        if not want:
            want = list(SHIPS)
        failed = []
        for ship in want:
            try:
                if args.cmd == "v6-run":
                    run_ship(ship, artist=artist, name=args.name,
                             desc_path=args.desc_file, out_root=raw,
                             expect_quote=args.expect_quote)
                else:
                    fetch_ship(ship, out_root=raw)
            except Exception as exc:  # noqa: BLE001 — keep the batch going
                print(f"[vfx {ship}] FAILED: {exc}", flush=True)
                failed.append(ship)
        if failed:
            raise SystemExit(f"failed ships: {failed}")
        return

    dirs = [d for d in args.targets if d in DIRS]
    unknown = [d for d in args.targets if d not in DIRS]
    if unknown:
        raise SystemExit(f"unknown dir ids: {unknown} (valid: {DIRS})")
    if not dirs:
        dirs = list(DIRS)
    failed = []
    for d in dirs:
        try:
            if args.cmd == "run":
                rec = run_dir(d, artist=artist, name=args.name,
                              desc_path=args.desc_file, out_root=raw,
                              expect_quote=args.expect_quote)
            else:
                fetch_dir(d, out_root=raw)
        except Exception as exc:  # noqa: BLE001 — keep the batch going
            print(f"[vfx {d}] FAILED: {exc}", flush=True)
            failed.append(d)
    if failed:
        raise SystemExit(f"failed dirs: {failed}")


if __name__ == "__main__":
    main()
